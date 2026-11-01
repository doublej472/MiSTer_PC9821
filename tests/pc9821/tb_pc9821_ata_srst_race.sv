// tb_pc9821_ata_srst_race - an SRST write colliding with the one-shot block_done
// completion pulse must not wedge the drive in X_DRAIN.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// An SRST write to 0x074C landing in the same clk_sys cycle as the one-shot block_done completion pulse must not wedge the drive: the drain/prefetch/X_WAIT_BLOCK/X_WAIT_WRITE handlers run before the task-file write handler and retire the pulse, so the SRST arm's block_in_flight test sees the pre-consumption state and parks in X_DRAIN to wait for a completion that never recurs. The collision is driven in every consuming state - X_DRAIN, X_WAIT_WRITE, X_PIO_READ with a prefetch in flight, X_WAIT_BLOCK with sectors_left 1 and > 1, and against the SRST deassert write - and after the pair's deassert the drive must reach X_IDLE with BSY clear and the post-diagnostic signature within a bounded number of cycles, then still accept the next command.
//
// A guest write to 0x074C (SRST) landing in the SAME clk_sys cycle as the one-shot
// `block_done` pulse retires that completion in the SAME cycle the SRST arm parks the
// transfer in X_DRAIN: the drain/prefetch/X_WAIT_BLOCK/X_WAIT_WRITE handlers run BEFORE
// the task-file write handler and eat the pulse, `block_in_flight` is computed from the
// pre-consumption state, and X_DRAIN then waits for a block_done that never recurs -
// permanent BSY (0x80), every command ignored, until hard reset. This bench drives that
// exact collision in each of the consuming states (X_DRAIN, X_WAIT_WRITE,
// X_PIO_READ+prefetch_busy, X_WAIT_BLOCK with sectors_left 1 and > 1) and asserts the
// drive returns to X_IDLE with BSY clear within a bounded number of cycles after the
// SRST pair's deassert - and then still accepts the next command.
//
// WHY IT IS MACHINE BEHAVIOUR: the trigger is exactly the guest-timeout/SRST path the
// X_DRAIN machinery exists for. BANK3's IDE ROM soft-resets with `out 0x74C,0x06` /
// `out 0x74C,0x00` while a transfer can be in flight; a drive that hangs on that pair is
// dead for the rest of the session - ATA allows a command to complete or abort, never to
// wedge.
//
// THE SAME-CYCLE MEANS ONE POSEDGE: the task drives io_wr and block_done so both are
// stable across the SAME clk posedge the DUT samples, which is the collision window.
//
// SIGNAL OWNERSHIP (why no two procedural blocks write one variable at one negedge):
// the adapter's negedge block only LATCHES requests (ad_busy/ad_reqs); the tasks own
// block_done/io_* and clear ad_busy exactly one negedge BEFORE the completion's posedge,
// so a fresh request the completion handler issues (the X_WAIT_BLOCK re-prefetch) can
// only be latched at a later negedge the tasks do not touch ad_busy on.

module tb_pc9821_ata_srst_race;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg        io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [ 7:0] io_din = 0;
  wire [ 7:0] io_dout;
  wire        block_read, block_write;
  wire [31:0] block_lba;
  reg         block_done = 0, block_error = 0, block_buf_we = 0;
  reg  [ 7:0] block_buf_addr = 0;
  reg  [15:0] block_buf_data = 0;
  reg  [ 7:0] block_rd_addr = 0;
  wire [15:0] block_rd_data;
  wire        irq;
  wire [ 7:0] dbg_state;
  wire [31:0] dbg_cmd;

  integer errors = 0;
  integer n;
  reg [7:0] value;

  // ==== DUT ====
  pc9821_ata dut (
      // The channel's slave (device 1): no image, so the master answers for DEV=1 as before.

      .clk(clk),
      .rst_n(rst_n),
      .io_rd(io_rd),
      .io_wr(io_wr),
      .io_addr(io_addr),
      .io_din(io_din),
      .io_dout(io_dout),
      .mounted(1'b1),
      .readonly(1'b0),
      // The same capacity tb_pc9821_ata_blockwait uses (1000 / 136 = 7 cylinders).
      .capacity(32'd1000),
      .block_read(block_read),
      .block_write(block_write),
      .block_lba(block_lba),
      .block_done(block_done),
      .block_error(block_error),
      .block_buf_we(block_buf_we),
      .block_buf_addr(block_buf_addr),
      .block_buf_data(block_buf_data),
      .block_rd_addr(block_rd_addr),
      .block_rd_data(block_rd_data),
      .irq(irq),
      .dbg_state(dbg_state),
      .dbg_cmd(dbg_cmd)
  );

  task fail(input [8*160-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task write_byte(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr;
      io_din  = data;
      io_wr   = 1;
      @(posedge clk);
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  task read_byte(input [15:0] addr, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr;
      io_rd   = 1;
      #1 data = io_dout;
      @(posedge clk);
      @(negedge clk);
      io_rd = 0;
    end
  endtask

  // ==== the block adapter, under the bench's full control ====
  // pc9821_block_io accepts one request and answers with one one-cycle `block_done`
  // pulse. Here NOTHING completes on its own: every completion is fired by a task, so
  // each collision lands on the cycle the scenario picked. The negedge block only
  // latches requests (see SIGNAL OWNERSHIP above).
  reg     ad_busy = 0;
  integer ad_reqs = 0;

  always @(negedge clk) begin
    if (!ad_busy && (block_read || block_write)) begin
      ad_busy = 1;
      ad_reqs = ad_reqs + 1;
    end
  end

  // Fire the in-flight completion with NO other bus activity in the cycle.
  task fire_done;
    begin
      @(negedge clk);
      block_done = 1;
      ad_busy    = 0;
      @(negedge clk);
      block_done = 0;
    end
  endtask

  // THE COLLISION: a task-file write to 0x074C (`data`) and the in-flight
  // completion's block_done pulse, both stable across the same clk posedge.
  task ctrl_write_with_done(input [7:0] data);
    begin
      @(negedge clk);
      io_addr    = 16'h074C;
      io_din     = data;
      io_wr      = 1;
      block_done = 1;
      ad_busy    = 0;
      @(posedge clk);
      @(negedge clk);
      io_wr      = 0;
      block_done = 0;
    end
  endtask

  task read_sectors_lba(input [7:0] count, input [7:0] lba_low);
    begin
      write_byte(16'h0644, count);
      write_byte(16'h0646, lba_low);
      write_byte(16'h0648, 8'h00);
      write_byte(16'h064A, 8'h00);
      write_byte(16'h064C, 8'hE0);
      write_byte(16'h064E, 8'h20);
    end
  endtask

  // Drain one presented sector: 256 word reads (0x640 lo, 0x641 hi advances).
  task drain_sector;
    integer w;
    begin
      for (w = 0; w < 256; w = w + 1) begin
        read_byte(16'h0640, value);
        read_byte(16'h0641, value);
      end
    end
  endtask

  // A fresh hard reset between scenarios, so one wedge is reported by name and does
  // not swallow every scenario after it (a BSY drive ignores all command writes).
  task reset_drive;
    begin
      @(negedge clk);
      rst_n = 0;
      repeat (4) @(negedge clk);
      rst_n = 1;
      repeat (4) @(negedge clk);
      ad_busy = 0;
      ad_reqs = 0;
      write_byte(16'h0432, 8'h00);
      if (dut.status_reg !== 8'h50) fail("reset_drive: not READY at scenario start");
    end
  endtask

  // THE VERDICT of every scenario: after the SRST pair's deassert the drive must reach
  // X_IDLE with BSY clear and the post-diagnostic signature (READY|DSC, error 0x01)
  // within a bounded number of cycles - and then accept and issue the next command.
  //
  // THE SIGNATURE'S WARRANT: error 0x01 is the ATA-1 DIAGNOSTIC
  // SIGNATURE - after a reset (including the post-SRST reset) device 0 reports 0x01 in
  // the error register = "device 0 passed its self-test" (ATA-1 X3T10/2008D, EXECUTE
  // DEVICE DIAGNOSTIC / the reset device-0 signature; the same value tb_pc9821_ata_regs
  // checks at power-on). WAIVED DIVERGENCE (hierarchy note): NP2kai's drvreset
  // (cbus/ideio.c:356-374) does not model the signature - a named gap in the primary
  // reference; it is printed below instead of asserted bare.
  task expect_recovered(input [8*80-1:0] what);
    begin
      n = 0;
      while ((dut.xfer_state !== 3'd0 || dut.status_reg[7]) && n < 300) begin
        @(negedge clk);
        n = n + 1;
      end
      if (dut.xfer_state !== 3'd0) fail({what, ": stayed out of X_IDLE (X_DRAIN wedge)"});
      if (dut.status_reg[7])      fail({what, ": BSY never cleared (permanent wedge)"});
      if (dut.status_reg !== 8'h50) fail({what, ": no READY|DSC after the SRST pair"});
      // ATA-1's post-reset device-0 signature (see the warrant above). The waived
      // NP2kai gap is printed so the divergence stays named, not silent.
      $display("WAIVED %0s: error_reg=0x01 asserts the ATA-1 device-0 diagnostic signature; NP2kai drvreset does not model it", what);
      if (dut.error_reg !== 8'h01)  fail({what, ": no ATA-1 device-0 diagnostic signature"});
      // A wedged drive also ignores every command (the BSY guard): prove the next
      // one reaches the block engine.
      ad_reqs = 0;
      read_sectors_lba(8'h01, 8'h01);
      repeat (4) @(negedge clk);
      if (ad_reqs != 1) fail({what, ": the drive ignored the command after recovery"});
    end
  endtask

  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    while (dut.current_cylinders !== 16'd7) @(negedge clk);
    repeat (4) @(negedge clk);
    write_byte(16'h0432, 8'h00);

    // ---------------------------------------------------------------
    // 1. X_DRAIN + block_done + SRST set, in one cycle.
    //    A transfer is abandoned by SRST pair #1 (the adapter is still serving it, so
    //    the drive parks in X_DRAIN); pair #2's SET write lands in the same cycle as
    //    the abandoned transfer's completion. The drain handler retires the
    //    completion, but the SRST arm sees the pre-consumption X_DRAIN state and
    //    re-enters X_DRAIN with NOTHING in flight.
    // ---------------------------------------------------------------
    read_sectors_lba(8'h01, 8'h10);
    repeat (3) @(negedge clk);
    if (ad_reqs != 1) fail("S1 setup: the READ never reached the block adapter");
    write_byte(16'h074C, 8'h06);
    write_byte(16'h074C, 8'h00);
    if (dut.xfer_state !== 3'd6) fail("S1 setup: SRST with a transfer in flight did not park in X_DRAIN");
    if (!dut.status_reg[7])      fail("S1 setup: X_DRAIN must hold BSY until the adapter finishes");
    ctrl_write_with_done(8'h06);
    write_byte(16'h074C, 8'h00);
    expect_recovered("S1 X_DRAIN+done+SRST");

    // ---------------------------------------------------------------
    // 2. X_WAIT_WRITE + block_done + SRST set. The write completion is consumed by
    //    the X_WAIT_WRITE handler (writes issue no follow-up request) and the SRST
    //    arm parks in X_DRAIN anyway.
    // ---------------------------------------------------------------
    reset_drive;
    write_byte(16'h0644, 8'h01);
    write_byte(16'h0646, 8'h20);
    write_byte(16'h0648, 8'h00);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'h30);        // WRITE SECTORS, one sector
    for (n = 0; n < 256; n = n + 1) begin
      write_byte(16'h0640, n[7:0]);
      write_byte(16'h0641, 8'h5A);
    end
    repeat (3) @(negedge clk);
    if (dut.xfer_state !== 3'd5) fail("S2 setup: the sector commit did not reach X_WAIT_WRITE");
    ctrl_write_with_done(8'h06);
    write_byte(16'h074C, 8'h00);
    expect_recovered("S2 X_WAIT_WRITE+done+SRST");

    // ---------------------------------------------------------------
    // 3. X_PIO_READ + prefetch_busy + block_done + SRST set. The prefetch latch
    //    consumes the read-ahead completion; the SRST arm sees prefetch_busy
    //    (pre-consumption) and parks in X_DRAIN.
    // ---------------------------------------------------------------
    reset_drive;
    read_sectors_lba(8'h02, 8'h30);     // two sectors: a prefetch is issued
    fire_done;                          // fetch #1 lands: X_PIO_READ + prefetch #2
    repeat (3) @(negedge clk);
    if (dut.xfer_state !== 3'd3)    fail("S3 setup: first fetch did not present in X_PIO_READ");
    if (dut.prefetch_busy !== 1'b1) fail("S3 setup: no read-ahead was left in flight");
    ctrl_write_with_done(8'h06);        // prefetch #2's completion == the SRST write
    write_byte(16'h074C, 8'h00);
    expect_recovered("S3 X_PIO_READ+prefetch+done+SRST");

    // ---------------------------------------------------------------
    // 4a. X_WAIT_BLOCK + block_done + SRST set, sectors_left == 1. The X_WAIT_BLOCK
    //     handler consumes the completion and (sectors_left == 1) issues NO follow-up
    //     request; the SRST arm parks in X_DRAIN with nothing in flight.
    // ---------------------------------------------------------------
    reset_drive;
    read_sectors_lba(8'h02, 8'h40);
    fire_done;                          // fetch #1 presents, prefetch #2 issued
    drain_sector;                       // guest drains sector 0 while #2 is in flight
    repeat (3) @(negedge clk);
    if (dut.xfer_state !== 3'd1) fail("S4a setup: last word with the fetch in flight did not wait in X_WAIT_BLOCK");
    if (dut.sectors_left !== 9'd1) fail("S4a setup: expected sectors_left == 1");
    ctrl_write_with_done(8'h06);
    write_byte(16'h074C, 8'h00);
    expect_recovered("S4a X_WAIT_BLOCK(1)+done+SRST");

    // ---------------------------------------------------------------
    // 4b. X_WAIT_BLOCK + block_done + SRST set, sectors_left > 1. Here the handler
    //     re-issues a prefetch whose completion legitimately releases the drain:
    //     the drive must park in X_DRAIN and recover when THAT lands (the sub-case
    //     the current RTL already gets right; pinned so the fix cannot break it).
    // ---------------------------------------------------------------
    reset_drive;
    read_sectors_lba(8'h03, 8'h50);
    fire_done;
    drain_sector;
    repeat (3) @(negedge clk);
    if (dut.xfer_state !== 3'd1) fail("S4b setup: expected X_WAIT_BLOCK");
    if (dut.sectors_left !== 9'd2) fail("S4b setup: expected sectors_left == 2");
    ctrl_write_with_done(8'h06);
    write_byte(16'h074C, 8'h00);
    if (ad_reqs != 3) fail("S4b: the re-prefetch of the > 1 sub-case was not issued");
    fire_done;                          // the fresh prefetch completes: releases the drain
    expect_recovered("S4b X_WAIT_BLOCK(2)+done+SRST");

    // ---------------------------------------------------------------
    // 5. The mirror arm: block_done colliding with the SRST DEASSERT write while
    //    parked in X_DRAIN. The drain handler retires the completion; the deassert
    //    arm must not re-park on the pre-consumption state either.
    // ---------------------------------------------------------------
    reset_drive;
    read_sectors_lba(8'h01, 8'h60);
    repeat (3) @(negedge clk);
    write_byte(16'h074C, 8'h06);
    if (dut.xfer_state !== 3'd6) fail("S5 setup: expected X_DRAIN");
    ctrl_write_with_done(8'h00);        // DEASSERT write == the completion
    expect_recovered("S5 X_DRAIN+done+SRST deassert");

    // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_ATA_SRST_RACE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_SRST_RACE: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_ATA_SRST_RACE: TIMEOUT");
  end

endmodule

// tb_pc9821_ata_cmd_race - a COMMAND write landing in the SAME clk_sys cycle as
// the `block_done` completion that clears BSY must not vanish against the stale
// transfer state.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// A0x64E COMMAND write landing in the SAME clk as the block_done completion that retires the old transfer must not vanish against the stale transfer state: the dispatch guard reads pre-update BSY/xfer_state, so post-fix the dispatch takes over against the POST-retire device exactly as if the completion had been observed a cycle earlier (the serialized NP2kai order), while a command write in a NON-completing transfer cycle is still ignored. The retiring handler's read-ahead re-issue is folded out of the takeover so the adapter serves exactly the requests the surviving transfers own.
//
// The 0x64E dispatch guard reads `status_reg[7]`/`xfer_state` - pre-update
// values - so a command write colliding with the very completion that retires
// the old transfer was judged against the STALE transfer state and silently
// rejected (counted only in dbg_cmd_cnt): the command byte vanished. A guest
// pacing on interrupts rather than polling BSY could lose a command outright.
// After the fix the dispatch takes over against the POST-retire device when the
// completion is retired in the same clk (`block_done_retire_now`), exactly as if
// the completion had been observed one cycle earlier - the same serialized order
// NP2kai's software model always sees. The retiring handler's read-ahead
// re-issue is folded out of the takeover (`command_takeover`) so the adapter
// serves the NEW transfer's request rather than an orphaned prefetch whose
// completion would then land on the new transfer's state.
//
// The collision is driven with xfer_state == X_WAIT_BLOCK (the confirm case) and
// a0x64E IDENTIFY (0xEC) write: the IDENTIFY data must replace the retiring
// transfer's presentation. FAIL-FIRST: pre-fix 0x640 keeps returning the fetched
// sector's buffer and xfer_state stays X_PIO_READ.
//
// THE SAME-CYCLE MEANS ONE POSEDGE: the task drives io_wr and block_done so
// both are stable across the SAME clk posedge the DUT samples.

module tb_pc9821_ata_cmd_race;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg        io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg  [7:0] io_din = 0;
  wire [ 7:0] io_dout;
  wire        block_read, block_write;
  wire [31:0] block_lba;
  reg         block_done = 0, block_error = 0;
  reg         block_buf_we = 0;
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

  // ==== CHECKS ====
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
  reg     ad_busy = 0;
  integer ad_reqs = 0;

  always @(negedge clk) begin
    if (!ad_busy && (block_read || block_write)) begin
      ad_busy = 1;
      ad_reqs = ad_reqs + 1;
    end
  end

  task fire_done;
    begin
      @(negedge clk);
      block_done = 1;
      ad_busy    = 0;
      @(negedge clk);
      block_done = 0;
    end
  endtask

  // THE COLLISION: a task-file COMMAND write to 0x064E (`data`) and the
  // transfer's block_done completion, both stable across the same clk posedge.
  task cmd_write_with_done(input [7:0] data);
    begin
      @(negedge clk);
      io_addr    = 16'h064E;
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

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    while (dut.current_cylinders !== 16'd7) @(negedge clk);
    repeat (4) @(negedge clk);
    write_byte(16'h0432, 8'h00);

    // ---------------------------------------------------------------
    // S1 (FAIL FIRST). The X_WAIT_BLOCK confirm case: the sector fetch's
    // completion lands in the exact clk the guest writes IDENTIFY (0xEC). The
    // guard sees the pre-update X_WAIT_BLOCK state and used to drop the byte.
    // Post-fix the dispatch executes against the post-retire device: IDENTIFY
    // data replaces the presentation (word 0 low byte = 0x4A at 0x640) and the
    // retiring handler's prefetch re-issue is suppressed (the adapter must
    // report exactly one MORE request in total: the old transfer's first fetch
    // plus nothing else - the takeover issues no request for IDENTIFY).
    // ---------------------------------------------------------------
    read_sectors_lba(8'h02, 8'h10);
    repeat (3) @(negedge clk);
    if (ad_reqs != 1) fail("S1 setup: the READ never reached the block adapter");
    if (dut.xfer_state !== 3'd1) fail("S1 setup: expected X_WAIT_BLOCK");
    cmd_write_with_done(8'hEC);            // THE COLLISION
    @(negedge clk);
    if (dut.xfer_state !== 3'd2)
      fail("S1: the IDENTIFY command write was dropped against the stale transfer state");
    read_byte(16'h0640, value);
    if (value !== 8'h4A)
      fail("S1: 0x640 does not present the IDENTIFY word (command byte vanished)");
    if (ad_reqs != 1)
      fail("S1: the takeover let the retiring handler's read-ahead re-issue out");

    // ---------------------------------------------------------------
    // S2. A command write in a NON-completing transfer cycle is still ignored
    // (real hardware ignores a command write while BSY): the guard's original
    // behaviour must not widen.
    // ---------------------------------------------------------------
    reset_drive;
    read_sectors_lba(8'h02, 8'h30);
    repeat (3) @(negedge clk);
    write_byte(16'h064E, 8'hEC);           // mid X_WAIT_BLOCK, no completion
    @(negedge clk);
    if (dut.xfer_state !== 3'd1)
      fail("S2: a command write mid-transfer must still be ignored while BSY");
    fire_done;                             // the transfer completes normally
    repeat (3) @(negedge clk);
    if (dut.xfer_state !== 3'd3)
      fail("S2: the ignored command left the transfer unable to present its sector");

    // ---------------------------------------------------------------
    // S3. The serialized order still works end to end: a completion observed,
    // THEN a command write - and the drive still answers the IDENTIFY and the
    // next READ SECTORS.
    // ---------------------------------------------------------------
    reset_drive;
    read_sectors_lba(8'h01, 8'h50);
    repeat (3) @(negedge clk);
    fire_done;
    repeat (3) @(negedge clk);
    drain_sector;                          // the sector retires to X_IDLE
    if (dut.xfer_state !== 3'd0) fail("S3 setup: the drained transfer did not retire");
    write_byte(16'h064E, 8'hEC);
    repeat (2) @(negedge clk);
    if (dut.xfer_state !== 3'd2) fail("S3: IDENTIFY after a normal completion failed");
    read_byte(16'h0640, value);
    if (value !== 8'h4A) fail("S3: IDENTIFY word 0 wrong after the race fix");
    reset_drive;
    read_sectors_lba(8'h01, 8'h70);
    repeat (3) @(negedge clk);
    if (ad_reqs != 1) fail("S3: READ SECTORS after the takeover path did not issue");

    // ==== VERDICT ====
    // A failing run must exit non-zero: $fatal rather than a bare FAIL line and a
    // $finish, which returns from the process with status 0.
    if (errors == 0) begin
      $display("TB_PC9821_ATA_CMD_RACE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_CMD_RACE: FAIL (%0d errors)", errors);
  end

endmodule

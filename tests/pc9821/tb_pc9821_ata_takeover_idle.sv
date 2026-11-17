// tb_pc9821_ata_takeover_idle - a non-data command that takes over a retiring transfer leaves
// the drive idle, not wedged in the transfer's DRQ state.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_TAKEOVER_IDLE: a NON-DATA command (RECALIBRATE 0x10, SET FEATURES 0xEF) written to 0x064E in the same clk as a block_done completion that would enter a DRQ phase - a READ's sector fetch (X_WAIT_BLOCK), its read-ahead while the guest drains (X_PIO_READ), and a non-final WRITE sector (X_WAIT_WRITE) - takes over the drive the way NP2kai's serialized model does (cbus/ideio.c ideio_o64e dispatches the command against the drive whatever transfer it was in, and RECALIBRATE/SET FEATURES end with `drv->status = IDESTAT_DRDY | IDESTAT_DSC` and no data phase): status reads 0x50 with DRQ clear AND the drive accepts the next command (an IDENTIFY presents word 0 = 0x044A), instead of the retiring transfer's DRQ state standing under a non-DRQ status so every later command is ignored until SRST.
//
// ---- where the expectation comes from ----
//   NP2kai cbus/ideio.c ideio_o64e -> cmdabort/setidentify/... : every command is dispatched
//     against the drive; `case 0x10:` (recalibrate) sets `drv->status = IDESTAT_DRDY |
//     IDESTAT_DSC` and raises the interrupt, with no data phase, and SET FEATURES (0xEF) the
//     same; the next command byte is dispatched in turn.
//   tb_pc9821_ata_cmd_race pins the takeover for a command that sets its own transfer
//   state (IDENTIFY); this bench covers the commands that do not.
// FAIL-FIRST: before the fix the retiring completion's X_PIO_READ / X_PIO_WRITE stood under the
// command's 0x50 status: DRQ clear, so 0x641 could not drain it, and the IDENTIFY that followed
// was ignored (xfer_state != X_IDLE) - the drive was wedged until a soft reset.

module tb_pc9821_ata_takeover_idle;

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

  reg [7:0] value_hi;
  task expect_idle_then_identify(input [8*24-1:0] tag);
    begin
      repeat (2) @(negedge clk);
      read_byte(16'h064E, value);
      if (value !== 8'h50) begin $display("%0s: status 0x%02x after the takeover", tag, value); fail("takeover status is not 0x50"); end
      if (dut.xfer_state !== 3'd0) begin $display("%0s: xfer_state %0d", tag, dut.xfer_state); fail("takeover left the drive in a transfer state"); end
      write_byte(16'h064E, 8'hEC);
      repeat (2) @(negedge clk);
      // word 0 = 0x044A, the Xe10's (docs/probes/IDE.TXT:74): both bytes of the word
      read_byte(16'h0640, value);
      read_byte(16'h0641, value_hi);
      if (value !== 8'h4A || value_hi !== 8'h04) begin
        $display("%0s: IDENTIFY word0 0x%02x%02x", tag, value_hi, value);
        fail("the next command (IDENTIFY) was not accepted (word 0 is not 0x044A)");
      end
      else $display("ok  %0s", tag);
    end
  endtask

  task write_sectors_lba(input [7:0] count, input [7:0] lba_low);
    begin
      write_byte(16'h0644, count);
      write_byte(16'h0646, lba_low);
      write_byte(16'h0648, 8'h00);
      write_byte(16'h064A, 8'h00);
      write_byte(16'h064C, 8'hE0);
      write_byte(16'h064E, 8'h30);
    end
  endtask

  task fill_sector;
    integer w;
    begin
      for (w = 0; w < 256; w = w + 1) begin
        write_byte(16'h0640, w[7:0]);
        write_byte(16'h0641, 8'h00);
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

    // T1: X_WAIT_BLOCK -> RECALIBRATE in the completion clk.
    read_sectors_lba(8'h02, 8'h10);
    repeat (3) @(negedge clk);
    if (dut.xfer_state !== 3'd1) fail("T1 setup: expected X_WAIT_BLOCK");
    cmd_write_with_done(8'h10);
    expect_idle_then_identify("T1 wait_block+0x10");

    // T2: X_WAIT_BLOCK -> SET FEATURES in the completion clk.
    reset_drive;
    write_byte(16'h0642, 8'h03);
    read_sectors_lba(8'h02, 8'h20);
    repeat (3) @(negedge clk);
    cmd_write_with_done(8'hEF);
    expect_idle_then_identify("T2 wait_block+0xEF");

    // T3: X_PIO_READ with the read-ahead in flight -> RECALIBRATE as it lands.
    reset_drive;
    read_sectors_lba(8'h03, 8'h30);
    repeat (3) @(negedge clk);
    fire_done;                            // sector 1 presented, read-ahead issued
    repeat (3) @(negedge clk);
    if (dut.xfer_state !== 3'd3 || !dut.prefetch_busy) fail("T3 setup: expected X_PIO_READ with a read-ahead");
    cmd_write_with_done(8'h10);
    expect_idle_then_identify("T3 pio_read+0x10");

    // T4: X_WAIT_WRITE, not the last sector -> RECALIBRATE as it completes.
    reset_drive;
    write_sectors_lba(8'h02, 8'h40);
    repeat (3) @(negedge clk);
    fill_sector;
    repeat (3) @(negedge clk);
    if (dut.xfer_state !== 3'd5) fail("T4 setup: expected X_WAIT_WRITE (a non-final sector committing)");
    cmd_write_with_done(8'h10);
    expect_idle_then_identify("T4 wait_write+0x10");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ATA_TAKEOVER_IDLE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_TAKEOVER_IDLE: FAIL (%0d errors)", errors);
  end

  // A DUT that never answers (a wait above that never ends) fails with a verdict here rather
  // than hanging until the runner's outer timeout. Far above the bench's own run time.
  initial begin
    #10_000_000;
    $fatal(1, "TB_PC9821_ATA_TAKEOVER_IDLE: TIMEOUT");
  end

endmodule

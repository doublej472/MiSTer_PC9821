// tb_pc9821_ata_err_sticky - STATUS.ERR survives an ERROR read and a device/head write.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_ERR_STICKY: STATUS.ERR is sticky on the hard disk the way the Xe10 shows it: after an aborted command (DEVICE RESET 0x08 on the ATA disk: status 0x51, ERROR 0x04) neither a read of the ERROR register (0x0642) nor a device/head write (0x064C = 0xA0) changes STATUS - both still read 0x51 - and the next command (IDENTIFY) then clears it to its own DRQ status 0x58, replaying the ideprobe DIAG-then-IRQ sequence whose capture reads 'after 0x08 status = 51 ; after 0x08 ERROR(0642) = 04' followed by 'pre/final status = 51 58'.
//
// ---- where the expectation comes from ----
//   docs/probes/IDE.TXT:343 "after 0x08 status = 51 ; after 0x08 ERROR(0642) = 04" and
//   IDE.TXT:349 "pre/final status = 51 58". tools/hwprobe/ideprobe/ideprobe.s: sec_diag ends
//   with `in al, dx` from 0x0642 (/* ERROR register */); sec_irq then does `out 0x064C,0xA0`,
//   `in 0x064E` -> irq_pre (0x51), then IDENTIFY -> irq_final (0x58). Nothing else touches the
//   drive in between, so on the machine neither the ERROR read nor the 0x064C write clears ERR.
//   The capture outranks NP2kai ideio_i642 (`drv->status &= ~IDESTAT_ERR;`), which the RTL
//   followed; NP2kai ideio_o64c itself leaves status alone, as the capture does. This core's
//   ATAPI drive already keeps ERR across an ERROR read for the same capture-backed reason.
// FAIL-FIRST: before the fix the ERROR read cleared ERR (0x51 -> 0x50) and the 0x064C write
// rewrote STATUS to 0x50.

module tb_pc9821_ata_err_sticky;

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

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    while (dut.current_cylinders !== 16'd7) @(negedge clk);
    repeat (4) @(negedge clk);
    write_byte(16'h0432, 8'h00);

    // sec_diag (DEVICE RESET part)
    write_byte(16'h064C, 8'hA0);
    write_byte(16'h064E, 8'h08);
    repeat (3) @(negedge clk);
    read_byte(16'h064E, value);
    if (value !== 8'h51) begin $display("after 0x08 status %02x", value); fail("0x08 status is not the machine's 0x51"); end
    read_byte(16'h0642, value);
    if (value !== 8'h04) begin $display("after 0x08 ERROR %02x", value); fail("0x08 ERROR is not 0x04"); end
    read_byte(16'h074C, value);
    if (value !== 8'h51) begin $display("ALTSTATUS after ERROR read %02x", value); fail("the ERROR read cleared STATUS.ERR"); end

    // sec_irq: device/head write, then the status read the capture calls 'pre'
    write_byte(16'h064C, 8'hA0);
    read_byte(16'h064E, value);
    if (value !== 8'h51) begin $display("pre status %02x", value); fail("the 0x064C write changed STATUS (machine: pre = 51)"); end

    // the next command clears it: IDENTIFY presents data, 'final' = 0x58
    write_byte(16'h064E, 8'hEC);
    repeat (3) @(negedge clk);
    read_byte(16'h064E, value);
    if (value !== 8'h58) begin $display("final status %02x", value); fail("IDENTIFY's status is not the machine's 0x58"); end

    // The 0x064C write alone (no ERROR read before it): drain IDENTIFY, abort again.
    for (n = 0; n < 256; n = n + 1) begin
      read_byte(16'h0640, value);
      read_byte(16'h0641, value);
    end
    write_byte(16'h064E, 8'h08);
    repeat (3) @(negedge clk);
    write_byte(16'h064C, 8'hA0);
    read_byte(16'h074C, value);
    if (value !== 8'h51) begin $display("ALTSTATUS after 0x064C %02x", value); fail("the 0x064C write alone changed STATUS"); end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ATA_ERR_STICKY: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_ERR_STICKY: FAIL (%0d errors)", errors);
  end

  // A DUT that never answers (a wait above that never ends) fails with a verdict here rather
  // than hanging until the runner's outer timeout. Far above the bench's own run time.
  initial begin
    #10_000_000;
    $fatal(1, "TB_PC9821_ATA_ERR_STICKY: TIMEOUT");
  end

endmodule

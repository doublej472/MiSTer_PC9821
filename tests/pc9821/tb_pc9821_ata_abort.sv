`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_ABORT:
// A read-ahead that ERRORs while the FSM waits in X_WAIT_BLOCK truly abandons the block transfer: `abort_command` clears `prefetch_busy`, so `block_in_flight` goes false and the very next SRST (the authentic ROM's own `out 0x74C,0x06` pair) returns the drive to READY instead of parking it in X_DRAIN with BSY set forever. On the current RTL the abort leaves `prefetch_busy` set, `block_in_flight` stays true, and the SRST sets BSY and never clears it -- a dead drive from one adapter error.
//
// ---- the bench's own account of where the expectation comes from ----
//
// This exists because the defect below is reachable from the authentic ROM and is a
// permanent wedge, not a timing figure. The path: a multi-sector READ issues a read-ahead
// (prefetch_busy = 1) while the guest drains; if the guest reaches the sector's last word
// before that fetch lands, the FSM waits in X_WAIT_BLOCK; if the adapter then reports the
// fetch as an error, `abort_command` runs -- and it set X_IDLE without clearing
// prefetch_busy. `block_in_flight` (pc9821_ata.sv) is true while prefetch_busy, so the
// SRST the ROM issues routinely takes the X_DRAIN arm and waits for a `block_done` no
// request will ever produce. Status stays 0x80 and every later command is ignored.
//
// The ATA's own range check only tests a command's FIRST LBA, so an image end, an eject
// mid-transfer or a malformed HPS stream all reach this arm; the one-line fix mirrors
// begin_block_read.
//
// WHAT IS ASSERTED:
//   1. after the errored read-ahead is consumed, the transfer is really over:
//      xfer_state = X_IDLE, prefetch_busy = 0 and block_in_flight = 0;
//   2. an SRST (`0x74C <- 0x04`) after that leaves BSY CLEAR and the FSM in X_IDLE, and
//      the SRST's falling edge re-establishes the post-diagnostic signature
//      (ERROR = 0x01, READY status) -- the same answer a drive that was never wedged gives.

module tb_pc9821_ata_abort;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  reg mounted = 1, readonly = 0;
  reg [31:0] capacity = 32'd100000;
  wire block_read, block_write;
  wire [31:0] block_lba;
  reg block_done = 0, block_error = 0, block_buf_we = 0;
  reg [7:0] block_buf_addr = 0;
  reg [15:0] block_buf_data = 0;
  reg [7:0] block_rd_addr = 0;
  wire [15:0] block_rd_data;
  wire irq;
  wire [7:0] dbg_state;
  wire [31:0] dbg_cmd;

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
      .mounted(mounted),
      .readonly(readonly),
      .capacity(capacity),
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

  integer errors = 0;
  integer n, w;
  reg [7:0] value;
  reg [15:0] word_value;
  reg [7:0] status;
  integer cycles = 0;
  always @(posedge clk) cycles = cycles + 1;

  task fail(input [8*128-1:0] message);
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

  // One PIO word: low byte at 0x640, high byte at 0x641. No class gap here -- this bench
  // wants the guest at the sector's last word before the (deliberately held) fetch lands.
  task read_pio_word(output [15:0] data);
    reg [7:0] lo, hi;
    begin
      read_byte(16'h0640, lo);
      read_byte(16'h0641, hi);
      data = {hi, lo};
    end
  endtask

  task wait_drq;
    begin
      n = 0;
      while (!dut.status_reg[3] && n < 200000) begin
        @(posedge clk);
        n = n + 1;
      end
      if (!dut.status_reg[3]) fail("ATA DRQ timeout");
    end
  endtask

  // Sector byte N is LBA[7:0] XOR N[7:0]; word i is {LBA ^ (2i+1), LBA ^ (2i)}, the map
  // tb_pc9821_ata / tb_pc9821_ata_readahead use, so wrong data is a mismatch not a pass.
  function [15:0] sector_word_for(input [31:0] lba, input [7:0] index);
    begin
      sector_word_for = {
          lba[7:0] ^ {index[6:0], 1'b1},
          lba[7:0] ^ {index[6:0], 1'b0}
      };
    end
  endfunction

  // ==== STIMULUS ====
  // The block adapter. Request 1 (sector 0) streams normally; request 2 is the read-ahead,
  // which this adapter latches but NEVER streams -- the stimulus decides when it reports
  // the error, after it has seen the FSM reach X_WAIT_BLOCK.
  reg        ad_active = 0;
  reg        ad_err = 0;
  reg [31:0] ad_lba = 0;
  integer    ad_index = 0;
  integer    ad_reqs = 0;
  reg        ra_error = 0;   // a one-cycle errored completion at the next negedge

  always @(negedge clk) begin
    block_done   = 0;
    block_error  = 0;
    block_buf_we = 0;
    if (ra_error) begin
      // The read-ahead's completion, with the error the adapter reported.
      block_done  = 1;
      block_error = 1;
      ra_error    = 0;
      ad_active   = 0;
    end else if (!ad_active) begin
      if (block_read && ad_reqs == 0) begin
        ad_active = 1; ad_lba = block_lba; ad_index = 0; ad_err = 0; ad_reqs = 1;
      end else if (block_read && ad_reqs == 1) begin
        ad_active = 1; ad_lba = block_lba; ad_index = 0; ad_err = 1; ad_reqs = 2;
      end
    end else if (!ad_err) begin
      block_buf_we   = 1;
      block_buf_addr = ad_index[7:0];
      block_buf_data = sector_word_for(ad_lba, ad_index[7:0]);
      if (ad_index == 255) begin
        ad_active = 0;
        block_done = 1;
      end else ad_index = ad_index + 1;
    end
  end

  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;

    // Wait for the capacity-derived cylinder count, then select the interface's bank.
    while (dut.current_cylinders !== 16'd735) @(negedge clk);
    write_byte(16'h0432, 8'h00);

    // A TWO-sector LBA28 READ SECTORS: the count is what makes the FSM issue a read-ahead
    // after the first sector, which is the state this bench needs prefetch_busy set in.
    write_byte(16'h0644, 8'h02);
    write_byte(16'h0646, 8'h00);
    write_byte(16'h0648, 8'h10);
    write_byte(16'h064A, 8'h00);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h064E, 8'h20);
    if (dut.status_reg !== 8'h80) fail("READ did not enter BSY");

    // Sector 0 arrives, the guest drains it, and the read-ahead for sector 1 is held.
    wait_drq();
    for (w = 0; w < 256; w = w + 1) read_pio_word(word_value);

    // The last word should have parked the FSM waiting for the in-flight read-ahead.
    if (dut.xfer_state !== 3'd1)
      fail("the FSM did not reach X_WAIT_BLOCK (the read-ahead landed during the drain)");
    if (!dut.prefetch_busy)
      fail("prefetch_busy was not set when X_WAIT_BLOCK was entered");

    // The adapter reports the held read-ahead as an error -> abort_command.
    ra_error = 1;
    n = 0;
    while (dut.xfer_state !== 3'd0 && n < 200) begin
      @(posedge clk);
      n = n + 1;
    end
    repeat (4) @(posedge clk);

    // 1. the transfer is really over -- this is the line the current RTL fails.
    if (dut.xfer_state !== 3'd0) fail("the abort did not return the FSM to X_IDLE");
    if (dut.prefetch_busy) fail("the abort left prefetch_busy set (block_in_flight stays true)");
    if (dut.block_in_flight) fail("block_in_flight is still true after the abort");

    // 2. the ROM's own SRST pair must return the drive, not park it in X_DRAIN.
    write_byte(16'h074C, 8'h04);
    repeat (8) @(posedge clk);
    if (dut.status_reg[7]) begin
      $display("FAIL: SRST left BSY set (status=0x%02x, xfer_state=%0d)",
               dut.status_reg, dut.xfer_state);
      errors = errors + 1;
    end
    if (dut.xfer_state != 3'd0) begin
      $display("FAIL: SRST did not leave X_IDLE (xfer_state=%0d, block_in_flight=%0b)",
               dut.xfer_state, dut.block_in_flight);
      errors = errors + 1;
    end
    write_byte(16'h074C, 8'h00);
    repeat (8) @(posedge clk);
    if (dut.status_reg !== 8'h50)
      $display("NOTE: post-SRST status is 0x%02x, expected 0x50", dut.status_reg);
    if (dut.status_reg[7]) fail("the drive is still BSY after the full SRST pair");
    if (dut.error_reg !== 8'h01)
      $display("NOTE: post-SRST ERROR is 0x%02x, expected the 0x01 diagnostic", dut.error_reg);

    $display("ABORT: reqs=%0d ra_errored=1 final_status=0x%02x xfer_state=%0d",
             ad_reqs, dut.status_reg, dut.xfer_state);

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ATA_ABORT: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_ABORT: FAIL (%0d errors)", errors);
  end

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_ATA_ABORT: TIMEOUT");
  end

endmodule

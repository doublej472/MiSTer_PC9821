`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// The 0x0433 aux status is the SOURCE-IDENTIFICATION port, not an IRQ-pending flag: it answers bit 1 (0x02) = "the selected bank has a connected device" and 0x00 otherwise, exactly as NP2kai's ideio_i433. The old arm answered QEMU's irq_levels form (bit 0 = pending IRQ), which had both the bit position and the meaning wrong: a driver identifying the interface read an IRQ sample as a connection answer.
//
// The 0x0433 aux status is the SOURCE-IDENTIFICATION port, not an IRQ-pending
// flag: it answers bit 1 (0x02) = "the selected bank has a connected device" and
// 0x00 otherwise, exactly as NP2kai's ideio_i433. The
// old arm answered QEMU's irq_levels form (bit 0 = pending IRQ), which had both
// the bit position and the meaning wrong: a driver identifying the interface
// read an IRQ sample as a connection answer.
//
// ---- the bench's own account of where each expectation comes from ----
//
//  NP2kai ideio_i433 (cbus/ideio.c:660-675):
//      ret = (ideio.bank[bank] & 0x1) ? 0x2 : 0x0;
//      if (ret == 0x2 && ideio.dev[1] both empty) ret = 0;
//  The bank byte is the 0x0432 latch (bank[1]) and its bit 0 selects the unit,
//  so bit 1 = "the selected bank has a connected device" - cleared when the
//  unit has no drive at all. This model's selected bank is channel_reg[0] and
//  its connected device is the mounted image, so the arm is
//  `device_present ? 0x02 : 0x00`. The machine's idle capture (probes/PROBE.TXT
//  `0432=00 0433=00`, at its EMPTY bank 0 - its CF card is in the CD connector)
//  pins the 0x00 at an empty bank; this core's empty bank is bank 1 (the fixed layout,
//  the hard disk on bank 0); the P5 confirm-method
//  (probe with an IRQ pending AND with/without a drive) is still owed on real
//  hardware, but the reference settles the SEMANTICS this bench pins: the
//  answer must not move with the IRQ line at all.
//  [source: NP2kai cbus/ideio.c, the primary register reference]
//
// FAIL-FIRST: on the pre-fix tree step (b) reads 0x01 (the IRQ flag) where the
// connect flag answers 0x02, and step (c) drops to 0x00 once the status read
// acknowledges the interrupt.

module tb_pc9821_readback_ata;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  reg mounted = 1, readonly = 0;
  reg [31:0] capacity = 32'd1000;
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

      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .mounted(mounted), .readonly(readonly), .capacity(capacity),
      .block_read(block_read), .block_write(block_write), .block_lba(block_lba),
      .block_done(block_done), .block_error(block_error),
      .block_buf_we(block_buf_we), .block_buf_addr(block_buf_addr),
      .block_buf_data(block_buf_data),
      .block_rd_addr(block_rd_addr), .block_rd_data(block_rd_data),
      .irq(irq), .dbg_state(dbg_state), .dbg_cmd(dbg_cmd));

  integer errors = 0, cases = 0;

  // ==== CHECKS ====
  task write_byte(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_din = data; io_wr = 1;
      @(posedge clk);
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  task read_byte(input [15:0] addr, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_rd = 1;
      #1 data = io_dout;
      @(posedge clk);
      @(negedge clk);
      io_rd = 0;
    end
  endtask

  task expect_port(input [15:0] addr, input [7:0] expected,
                   input [8*60-1:0] what);
    reg [7:0] got;
    begin
      cases = cases + 1;
      read_byte(addr, got);
      if (got !== expected) begin
        $display("MISMATCH %0s: port %04x expected %02x got %02x", what, addr, expected, got);
        errors = errors + 1;
      end
      else $display("ok       %0s = %02x", what, got);
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    // (a) Bank 0x01 selects a unit with no interface (no CD in this bench): 0x00, the
    // machine's idle capture at its empty bank (`0432=00 0433=00`, probes/PROBE.TXT).
    write_byte(16'h0432, 8'h01);
    expect_port(16'h0433, 8'h00, "a the empty bank reports no connected device (machine 00)");

    // (b) Bank 0x00 selects the hard disk with the image mounted:
    // bit 1 set - and NOTHING ELSE: the port is not an IRQ flag.
    write_byte(16'h0432, 8'h00);
    expect_port(16'h0433, 8'h02, "b the selected bank has a connected device");

    // ...even with an IRQ pending. IDENTIFY raises it (and DRQ); the old arm
    // answered 0x01 here - the P5 semantic clash.
    write_byte(16'h064E, 8'hEC);          // IDENTIFY DEVICE
    repeat (200) @(posedge clk);
    if (irq !== 1'b1) begin
      $display("MISMATCH IDENTIFY did not raise the IRQ, so the test below is vacuous");
      errors = errors + 1;
    end
    expect_port(16'h0433, 8'h02, "b ...with an IRQ pending, the answer is still the connect flag");

    // (c) A status read acknowledges the IRQ (the ATA model's INTRQ clear); the
    // connect flag must not move with it (the old arm dropped to 0x00 here).
    begin : ack_status
      reg [7:0] st;
      read_byte(16'h064E, st);   // the ack; its value is tb_pc9821_ata_regs's
    end
    if (irq !== 1'b0) begin
      $display("MISMATCH the status read did not clear the IRQ");
      errors = errors + 1;
    end
    expect_port(16'h0433, 8'h02, "c ...and 0x0433 is unmoved by the ack");

    // (d) With the image unmounted there is no connected device: NP2kai's
    // "dev[1] empty" override forces the answer to 0x00 even though the bank
    // bit is set.
    mounted = 0;
    expect_port(16'h0433, 8'h00, "d no drive connected reports 0x00");
    mounted = 1;
    expect_port(16'h0433, 8'h02, "d ...and remounting restores the flag");

    // The neighbours are untouched by the fix.
    expect_port(16'h0435, 8'h00, "0x0435 stays 0x00");

    // ==== VERDICT ====
    $display("NOTE readback_ata: %0d cases, %0d mismatched, sim %0t", cases, errors, $time);
    if (errors == 0) begin
      $display("TB_PC9821_READBACK_ATA: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_READBACK_ATA: FAIL (%0d of %0d cases)", errors, cases);
  end

  initial begin
    #4_000_000;
    $fatal(1, "TB_PC9821_READBACK_ATA: TIMEOUT");
  end

endmodule

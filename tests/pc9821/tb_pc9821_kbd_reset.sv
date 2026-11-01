// tb_pc9821_kbd_reset - the 8251 command register's bit-3 keyboard reset.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_KBD_RESET:
// The 8251 command register's bit 3 resets the keyboard on its 1-to-0 transition: the receive status, the IRQ, the pending command responses and the queued key bytes are all discarded, which is the transition the ITF's own POST performs and which NP2kai implements as keyboard_resetsignal().
//
// ---- the bench's own account of where this expectation comes from ----
// [source 1: the firmware dump, BANK4.BIN]
// The authentic ITF writes the 8251 command register 0x43 in an init sequence
// whose last three steps are:
//
//     BANK4@0x04BEA   mov al,0x3A   out 0x43,al    0x3A = 0011_1010
//     BANK4@0x04BF6   mov al,0x32   out 0x43,al    0x32 = 0011_0010
//     BANK4@0x04C02   mov al,0x16   out 0x43,al
//
// 0x3A and 0x32 differ in EXACTLY ONE BIT, bit 3. There is no other reason to
// write both: everything else the command register carries (TxEN, RxE, RTS, ER)
// is identical across the pair. The firmware is generating a 1-to-0 transition
// on bit 3 deliberately, and on a plain 8251 bit 3 is SBRK -- "send break" --
// which is meaningless in a keyboard controller. The same three-step sequence
// appears at BANK4@0x04BDF.., BANK4@0x06709.., BANK7@0x067B5.. and
// BIOS.ROM@0x167B5.., so it is not an artefact of one code path.
//
// [source 2: NP2kai io/serial.c, the reference this module's header cites]
//     static void IOOUTCALL keyboard_o43(UINT port, REG8 dat) {
//         if ((!(dat & 0x08)) && (keybrd.cmd & 0x08)) keyboard_resetsignal();
//         if (dat & 0x10) keybrd.status &= ~(0x38);
//         keybrd.cmd = dat;
//     }
// and keyboard_resetsignal() clears: the pending event, keybrd.cmd, keybrd.status
// and BOTH byte queues (keybrd.ctrls control responses, keybrd.buffers keys).
// Note that keybrd.cmd = dat happens AFTER the reset, so the new command byte's
// enables survive -- the reset discards what the RECEIVE side is holding, not
// the enables the caller is about to set.
//
// [source 3: what the machine was measured to answer]
// the machine's probe results records 0x0043 as 0x85 on the real machine,
// and the capture in docs/probes/MEMSW.TXT line 73 carries it. That is the
// status register's fixed part: 0x85 = TxRDY | TxE | DSR with RxRDY clear, which
// this module produces as `status_reg | 8'h85`. The probe's own note in the same
// capture lists 0x0041 as a CONSUME-ON-READ port that was never sampled, so the
// data port's idle value has no machine evidence either way.
//
// ---- why this is the test the subsystem was missing ----
// The existing tb_pc9821_kbd.sv never writes a command byte with bit 3 set, so
// the whole behaviour is untested, and its LUT sweep compares the translation
// ROM against the function that built it -- a tautology that would pass with any
// table at all. A guest that performs the firmware's own init sequence leaves
// this core holding a receive status and queued bytes that the reference
// discards, and the next key the guest reads can therefore be a byte the reset
// was supposed to have thrown away.

module tb_pc9821_kbd_reset;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg [10:0] ps2_key = 0;

  // ==== DUT ====
  pc9821_kbd dut (
      .clk(clk),
      .rst_n(rst_n),
      .cs(cs),
      .a0(a0),
      .wr(wr),
      .rd(rd),
      .din(din),
      .dout(dout),
      .irq(irq),
      .ps2_key(ps2_key),
      .bios_setup(1'b0)
  );

  integer errors = 0;
  integer timeout_count;
  reg [7:0] value;
  reg toggle = 0;

  // ==== CHECKS ====

  task fail(input [8*110-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task write_port(input control_port, input [7:0] data);
    begin
      @(negedge clk);
      a0  = control_port;
      din = data;
      cs  = 1;
      wr  = 1;
      @(posedge clk);
      @(negedge clk);
      cs = 0;
      wr = 0;
    end
  endtask

  task send_key(input pressed, input extended, input [7:0] code);
    begin
      @(negedge clk);
      toggle  = ~toggle;
      ps2_key = {toggle, pressed, extended, code};
      @(posedge clk);
      @(negedge clk);
    end
  endtask

  task read_byte(input [7:0] expected);
    begin
      timeout_count = 0;
      while (!irq && timeout_count < 40) begin
        @(posedge clk);
        timeout_count = timeout_count + 1;
      end
      if (!irq) begin
        fail("no receive IRQ: the byte never arrived");
      end else begin
        @(negedge clk);
        a0 = 0;
        cs = 1;
        rd = 1;
        #1 value = dout;
        if (value !== expected) begin
          $display("FAIL: keyboard byte got %02x want %02x", value, expected);
          errors = errors + 1;
        end
        @(posedge clk);
        @(negedge clk);
        cs = 0;
        rd = 0;
        #1;
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;

    // The firmware's own init: mode byte, then the command that enables RX/TX.
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);
    if (!dut.rx_enabled || !dut.tx_enabled) fail("8251 command did not enable RX/TX");

    // One key delivered and NOT read, so RXRDY and the IRQ are still asserted,
    // then three more that queue behind it.
    send_key(1'b1, 1'b0, 8'h15);   // Q -> delivered, RXRDY stays set
    send_key(1'b1, 1'b0, 8'h1D);   // W -> queued
    send_key(1'b1, 1'b0, 8'h24);   // E -> queued
    send_key(1'b1, 1'b0, 8'h1C);   // A -> queued
    if (!dut.status_reg[1]) fail("RXRDY is not set after a delivered byte");
    if (!irq)              fail("IRQ is not asserted after a delivered byte");
    // The translation ROM's read is registered, so the last queued key's event lands
    // one clk_sys after its send_key. One settle cycle lets the pipeline drain before the count.
    // RE-PINNED 1 -> 2 cycles by T6:
    // the dedup table's read is registered too now, so the DECISION is one clk deeper; the
    // bytes and their order are unchanged, only the clk the event lands on.
    @(posedge clk); @(posedge clk); #1;
    if (dut.fifo_cnt !== 5'd3) begin
      $display("FAIL: expected 3 queued bytes, found %0d", dut.fifo_cnt);
      errors = errors + 1;
    end

    // THE TRANSITION. 0x3A has bit 3 set; 0x32 clears it. They differ in no
    // other bit, which is why the firmware writes both.
    write_port(1'b1, 8'h3A);
    if (!dut.status_reg[1]) fail("RXRDY cleared by a bit-3 write that does not transition");
    write_port(1'b1, 8'h32);

    // Everything the receive side was holding must be gone.
    if (dut.status_reg[1])  fail("RXRDY survived the bit-3 1-to-0 transition: the status must be discarded");
    if (irq)                fail("IRQ survived the bit-3 1-to-0 transition");
    if (dut.fifo_cnt !== 5'd0) begin
      $display("FAIL: %0d queued bytes survived the bit-3 transition (NP2kai discards the record of this: BUFFERS)",
               dut.fifo_cnt);
      errors = errors + 1;
    end

    // And the NEXT key is the next key -- not a stale byte the reset should
    // have discarded. This is the guest-visible consequence.
    write_port(1'b1, 8'h05);       // re-enable RX/TX: the reset does not
    send_key(1'b1, 1'b0, 8'h76);   // Esc
    read_byte(8'h00);              // NEC make code for Escape

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_RESET: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_RESET: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000;
    $fatal(1, "TB_PC9821_KBD_RESET: TIMEOUT");
  end

endmodule

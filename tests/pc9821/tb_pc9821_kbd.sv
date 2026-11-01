// tb_pc9821_kbd - focused MiSTer Set-2, uPD8251, command, and FIFO checks.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_KBD:
// MiSTer Set-2 keyboard input, the uPD8251 interface, keyboard commands and the FIFO, including NP2kai keyboard_ctrl()'s control-queue clear: a command sent while an unread command response is pending DISCARDS it (keybrd.ctrls = 0 on the leading FA/FC), so the ITF's back-to-back 0x00-then-0x9F identity burst reads FA A0 80 and its stage-0x27 probe sets the 0x0481 bit-6 extended-keyboard flag.


module tb_pc9821_kbd;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg [10:0] ps2_key = 0;
  reg        bios_setup = 0;

  // ==== DUT ====
  pc9821_kbd #(
      // The presentation pace is shrunk so the bench's back-to-back keys and reads
      // stay inside read_byte's budget; the real tick is SYS_CLOCK_HZ / 1280.
      .XFER_TICK_CYCLES(26'd8),
      // Shrink the HELP hold window so the bench can observe its release.
      .HELP_HOLD_CYCLES(28'd2000)
  ) dut (
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
      .bios_setup(bios_setup)
  );

  integer errors = 0;
  integer timeout_count;
  reg [7:0] value;
  reg toggle = 0;
  // ==== STIMULUS ====

  task fail(input [8*96-1:0] message);
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

  task wait_irq;
    begin
      timeout_count = 0;
      while (!irq && timeout_count < 40) begin
        @(posedge clk);
        timeout_count = timeout_count + 1;
      end
      if (!irq) fail("keyboard receive IRQ timeout");
    end
  endtask

  task read_byte(input [7:0] expected);
    begin
      wait_irq();
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
      if (irq) fail("data read did not clear IRQ");
    end
  endtask
  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;
    if (dout !== 8'hFF) fail("reset data latch is not FF");
    a0 = 1;
    #1;
    if (dout !== 8'h85) fail("NP2kai reset status is not 85");

    // Asynchronous mode then TX/RX enable, RTS released.
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);
    if (!dut.rx_enabled || !dut.tx_enabled || dut.rts) fail("8251 command did not enable RX/TX");

    // MiSTer Set-2 A make/break -> PC-98 1D/9D.
    send_key(1'b1, 1'b0, 8'h1C);
    read_byte(8'h1D);
    send_key(1'b0, 1'b0, 8'h1C);
    read_byte(8'h9D);

    // E0 Set-2 Up make/break -> PC-98 3A/BA.
    send_key(1'b1, 1'b1, 8'h75);
    read_byte(8'h3A);
    send_key(1'b0, 1'b1, 8'h75);
    read_byte(8'hBA);

    // The yen/backslash key in the US layout (the default). Set-2 0x5D is the backslash key
    // on a US keyboard, and on the PC-98 the yen key, PC-98 key
    // 0x0D -- whose BIOS translation (BANK7@0x632B index 0x0D) is 0x5C, '\'.
    // Without this the DOS prompt has no path separator at all (no `CD \`, no
    // `COPY A:\*.* C:`), which is the first defect a user meets.
    send_key(1'b1, 1'b0, 8'h5D);
    read_byte(8'h0D);
    send_key(1'b0, 1'b0, 8'h5D);
    read_byte(8'h8D);

    // F1 -> NEC F1 0x62 (NP2kai lrcnv106 F1->0x62): the old F1->HELP
    // remap left NEC F1 unreachable. HELP keeps its two other routes: End
    // (E0 0x69 -> 0x3F, the raw key number the ITF's POST reads to enter SETUP,
    // BANK4@0x4C3F) and the OSD bios_setup injector below.
    send_key(1'b1, 1'b0, 8'h05);
    read_byte(8'h62);
    send_key(1'b0, 1'b0, 8'h05);
    read_byte(8'hE2);

    // Lock keys report their resulting state on press and nothing on release.
    send_key(1'b1, 1'b0, 8'h58);
    read_byte(8'h71);
    send_key(1'b0, 1'b0, 8'h58);
    repeat (4) @(posedge clk);
    if (irq) fail("CAPS release unexpectedly queued a byte");

    // NP2kai/QEMU keyboard commands: identity, unknown reject, and LED query.
    write_port(1'b0, 8'h96);
    read_byte(8'hFA);
    read_byte(8'hA0);
    read_byte(8'h83);

    write_port(1'b0, 8'h55);
    read_byte(8'hFC);

    // The ITF's identity burst (BANK4@0x1988-0x1992): command 0x00, then command 0x9F,
    // back to back WITH NO READ IN BETWEEN. NP2kai's keyboard_ctrl() clears its control
    // queue (keybrd.ctrls = 0) when it queues the leading 0xFA/0xFC, so the 0x00's 0xFC
    // reply is DISCARDED and the guest reads FA A0 80 -- the exact sequence the ITF's
    // BANK4@0x1992-0x19C9 checks, whose 0x80 sets 0x0481 bit 6 ("PC-9801-119 extended
    // keyboard present"). FAIL-FIRST: with the delivered-but-unread reply kept, this read
    // back 0xFC first and the stage-0x27 `or [0x481],0x40` never ran.
    write_port(1'b0, 8'h00);
    write_port(1'b0, 8'h9F);
    read_byte(8'hFA);
    read_byte(8'hA0);
    read_byte(8'h80);

    write_port(1'b0, 8'h9D);
    read_byte(8'hFA);
    write_port(1'b0, 8'h60);
    read_byte(8'hFA);
    read_byte(8'h74);  // 0x70 | CAPS

    send_key(1'b1, 1'b0, 8'h58);
    read_byte(8'hF1);
    send_key(1'b0, 1'b0, 8'h58);
    repeat (4) @(posedge clk);
    if (irq) fail("second CAPS release unexpectedly queued a byte");

    // The 8251 command bits must NOT gate reception. NP2kai's
    // keyboard_callback (io/serial.c) delivers a key whenever the previously
    // delivered byte has been read, with no RxE or RTS condition, and the
    // PC-98 BIOS asserts RTS in its command byte. Requiring !rts here was a
    // real bug: the display worked but the boot menu ignored every keystroke.
    write_port(1'b1, 8'h21);  // TxEN + RTS asserted, RxE clear
    send_key(1'b1, 1'b0, 8'h15);  // Q
    // read_byte waits for the receive IRQ and fails with a timeout, so this is
    // the regression test: with the old gate the byte never arrived.
    read_byte(8'h10);  // NEC make code for Q
    write_port(1'b1, 8'h05);  // TxEN + RxE

    // One enqueue concurrent with one dequeue must leave the count unchanged.
    send_key(1'b1, 1'b0, 8'h1D);  // W, delivered immediately
    toggle  = ~toggle;
    ps2_key = {toggle, 1'b1, 1'b0, 8'h24};  // E, queued
    @(posedge clk);
    #1;
    read_byte(8'h11);  // NEC make code for W
    read_byte(8'h12);  // NEC make code for E

    // Fill the receiver to capacity by never reading it: the byte already
    // delivered keeps RxRDY set, so further keys queue. The event after the
    // last queued byte is dropped and sets the overrun flag rather than
    // wrapping the FIFO.
    write_port(1'b1, 8'h05);
    send_key(1'b1, 1'b0, 8'h76);  // Esc: delivered immediately, RxRDY stays set
    send_key(1'b1, 1'b0, 8'h75);  // so everything after it queues
    send_key(1'b1, 1'b0, 8'h16);
    send_key(1'b1, 1'b0, 8'h1E);
    send_key(1'b1, 1'b0, 8'h26);
    send_key(1'b1, 1'b0, 8'h25);
    send_key(1'b1, 1'b0, 8'h2E);
    send_key(1'b1, 1'b0, 8'h36);
    send_key(1'b1, 1'b0, 8'h3D);
    send_key(1'b1, 1'b0, 8'h3E);
    send_key(1'b1, 1'b0, 8'h46);
    send_key(1'b1, 1'b0, 8'h45);
    send_key(1'b1, 1'b0, 8'h05);
    send_key(1'b1, 1'b0, 8'h06);
    send_key(1'b1, 1'b0, 8'h04);
    send_key(1'b1, 1'b0, 8'h0C);
    send_key(1'b1, 1'b0, 8'h03);
    // The translation ROM's read is registered, so the last key's event lands one
    // clk_sys after its send_key. One settle cycle lets the pipeline drain before the count.
    // RE-PINNED 1 -> 2 cycles by T6:
    // the dedup table's read is registered too now, so the DECISION is one clk deeper; the
    // bytes and their order are unchanged, only the clk the event lands on.
    @(posedge clk); @(posedge clk); #1;
    if (dut.fifo_cnt !== 5'd16) fail("FIFO did not reach capacity 16");
    send_key(1'b1, 1'b0, 8'h0B);  // F6: overflow attempt
    @(posedge clk); @(posedge clk); #1;   // ...and the same two cycles for the dropped event's overrun
    a0 = 1;
    #1;
    if (!(dout & 8'h10) || dut.fifo_cnt !== 5'd16) fail("FIFO overflow was not contained/reported");

    // ---- The 8251 bit-3 keyboard reset, and the half-written command it must abandon.
    //
    // No other check in this tree writes a control byte with bit 3 set, which is why a
    // firmware sequence that hinges on it went unimplemented for so long. The ITF
    // performs exactly this transition during POST -- BANK4@0x04BEA writes 0x3A and
    // BANK4@0x04BF6 writes 0x32, and the two differ in bit 3 ALONE -- and NP2kai reads
    // the 1-to-0 edge as a keyboard reset (io/serial.c keyboard_o43 / keyboard_resetsignal).
    //
    // The reset discards the receive side: what the guest has not yet read is gone, as are
    // any queued control responses.
    write_port(1'b1, 8'h3A);  // bit 3 set
    write_port(1'b1, 8'h32);  // bit 3 clear -> RESET
    if (dut.fifo_cnt !== 5'd0) fail("keyboard reset did not discard the queued bytes");
    a0 = 1;
    #1;
    if (dout & 8'h02) fail("keyboard reset left RXRDY set");
    if (irq) fail("keyboard reset left the receive IRQ asserted");

    // ...and it must also abandon a command that was waiting for its parameter.
    //
    // NP2kai's keyboard_resetsignal() calls keystat_ctrlreset(), whose first act is
    // `keyctrl.reqparam = 0`. Without the same clear here, cmd_pending survives the reset
    // and the NEXT command byte is eaten as the PARAMETER of the stale opcode instead of
    // being decoded -- the guest gets the wrong answer and the command it meant to send
    // never happens.
    //
    // The observable: 0x9D is a two-byte command, so it leaves cmd_pending set. Send it,
    // then reset BEFORE the parameter, then send 0x9F -- the identity probe this firmware
    // set actually runs (BANK4@0x1992). With cmd_pending stale, 0x9F is consumed as 0x9D's
    // parameter and answered 0xFC. Cleared, 0x9F is decoded and answers FA A0 80.
    write_port(1'b1, 8'h05);  // TxEN + RxE, so 0x41 is a keyboard COMMAND port again
    write_port(1'b0, 8'h9D);  // two-byte command: cmd_pending <- 1
    read_byte(8'hFA);         // its ACK, drained so the next read is unambiguous
    write_port(1'b1, 8'h3A);  // bit 3 set
    write_port(1'b1, 8'h32);  // bit 3 clear -> RESET abandons the half-written command
    write_port(1'b1, 8'h05);  // TxEN + RxE restored, as NP2kai assigns cmd = dat last
    write_port(1'b0, 8'h9F);  // the identity probe must be DECODED as a command
    read_byte(8'hFA);
    read_byte(8'hA0);
    read_byte(8'h80);

    // ---- The translation ROM, against an INDEPENDENT reference ----
    // This used to compare kbd_lut[] against dut.translate() -- but the ROM is
    // INITIALISED from translate(), so the comparison could not fail: it proved the
    // initial block ran, not that the table was right.
    // The full 512-entry table has no specification source -- NP2kai takes PC-98
    // codes directly and carries no PS/2 mapping -- so the entries
    // asserted here are the ones with an external anchor, each of which the
    // event-path checks above also pin against the guest-visible byte: the ITF's
    // own POST key (End -> 0x3F, BANK4@0x4C3F) and NP2kai's lrcnv106 (F1 ->
    // 0x62), the BIOS's yen translation
    // (BANK7@0x632B[0x0D] = 0x5C, so Set-2 0x5D -> PC-98 0x0D), and the keys whose
    // NEC number appears a few lines above. A wrong entry fails here; the count
    // stays as the table's size property either way.
    begin : kbd_lut
      integer sw_i;
      integer mapped_cnt;
      integer mapped_jis;
      // The ROM is {jis, extended, set2}: entries 0..511 are the US layout (the default,
      // layout_jis = 0, which this bench leaves unconnected-low), 512..1023 the JIS one.
      mapped_cnt = 0;
      mapped_jis = 0;
      for (sw_i = 0; sw_i < 512; sw_i = sw_i + 1) begin
        if (dut.kbd_lut[sw_i] !== 8'hFF) mapped_cnt = mapped_cnt + 1;
        if (dut.kbd_lut[512 + sw_i] !== 8'hFF) mapped_jis = mapped_jis + 1;
      end
      if (dut.kbd_lut[9'h01C] !== 8'h1D) fail("kbd_lut: Set-2 0x1C (A) is not NEC 0x1D");
      if (dut.kbd_lut[9'h076] !== 8'h00) fail("kbd_lut: Set-2 0x76 (Esc) is not NEC 0x00");
      if (dut.kbd_lut[9'h005] !== 8'h62) fail("kbd_lut: F1 is not NEC 0x62 (NP2kai lrcnv106)");
      if (dut.kbd_lut[9'h169] !== 8'h3F) fail("kbd_lut: End is not NEC 0x3F (the ITF's SETUP key)");
      if (dut.kbd_lut[9'h05D] !== 8'h0D) fail("kbd_lut: Set-2 0x5D (US backslash) is not NEC 0x0D");
      if (dut.kbd_lut[10'h25D] !== 8'h28) fail("kbd_lut: JIS Set-2 0x5D (]) is not NEC 0x28 (NP2kai sdlcnv106)");
      if (dut.kbd_lut[9'h058] !== 8'h71) fail("kbd_lut: Caps Lock is not NEC 0x71");
      if (dut.kbd_lut[9'h015] !== 8'h10) fail("kbd_lut: Set-2 0x15 (Q) is not NEC 0x10");
      if (dut.kbd_lut[9'h175] !== 8'h3A) fail("kbd_lut: E0 0x75 (Up) is not NEC 0x3A");
      // Round 3's remaps and newly decoded keys (NP2kai sdlcnv106).
      if (dut.kbd_lut[9'h011] !== 8'h51) fail("kbd_lut: LAlt is not NEC 0x51 (NFER)");
      if (dut.kbd_lut[9'h111] !== 8'h35) fail("kbd_lut: RAlt is not NEC 0x35 (XFER)");
      if (dut.kbd_lut[9'h059] !== 8'h70) fail("kbd_lut: RShift is not NEC 0x70 (SHIFT)");
      if (dut.kbd_lut[9'h114] !== 8'h73) fail("kbd_lut: RCtrl is not NEC 0x73 (GRPH)");
      if (dut.kbd_lut[9'h051] !== 8'h33) fail("kbd_lut: Set-2 0x51 (RO) is not NEC 0x33");
      if (dut.kbd_lut[9'h06A] !== 8'h0D) fail("kbd_lut: Set-2 0x6A (Yen) is not NEC 0x0D");
      $display("KBD_LUT: %0d mapped keys (US), %0d (JIS); the cited entries match the firmware/BIOS",
               mapped_cnt, mapped_jis);
      // 110 = the 99 anchored entries, the JIS RO/Yen and the 102nd key, the three Windows
      // keys, the US ` key (@), the JIS conversion keys (katakana/hiragana, henkan,
      // muhenkan), F11/F12 as VF1/VF2 and NumLock/ScrollLock as keypad = and ,. The JIS half
      // is one fewer: its half/full-width key (set-2 0x0E) maps to nothing (NP2kai sdlcnv106
      // has no GRAVE row). F11 must never be STOP again (tb_pc9821_kbd_stop).
      if (mapped_cnt != 110) begin
        $display("FAIL: expected 110 mapped keys (US), found %0d", mapped_cnt);
        errors = errors + 1;
      end
      if (mapped_jis != 109) begin
        $display("FAIL: expected 109 mapped keys (JIS), found %0d", mapped_jis);
        errors = errors + 1;
      end
    end

    // ER clears overrun without enabling RX.
    write_port(1'b1, 8'h11);
    a0 = 1;
    #1;
    if (dout & 8'h10) fail("8251 error reset did not clear overrun");

    // ---- OSD "Enter BIOS setup (hold HELP)": the guest sees HELP HELD, not a tap,
    //      and the OPTION IS SAMPLED AT MACHINE RESET ONLY:
    //      a mid-run OSD flip must do NOTHING to the running machine.
    //
    // The hold is armed from reset: make 0x3F, and a RE-MAKE after the guest's own
    // bit-3 keyboard reset (the held key survives the ITF's 8251 re-init, which flushes
    // the receive side -- NP2kai keystat_resendstat, io/serial.c), then one break 0xBF
    // after HELP_HOLD_CYCLES. Assert the guest-visible bytes, not module internals.
    ps2_key = 0;
    bios_setup = 1'b0;
    @(negedge clk);
    rst_n = 0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;
    // Configure the 8251 with the option OFF (0x5E then 0x05; their bit-3 1->0
    // transition is the ITF's keyboard reset), then flip the option ON mid-run:
    // nothing may be injected. FAIL-FIRST: on the live-apply wiring this flip
    // starts the hold immediately and the check below fires.
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);
    bios_setup = 1'b1;
    repeat (40) @(posedge clk);
    if (irq) fail("a mid-run Enter-BIOS-setup flip injected HELP into the running machine");
    bios_setup = 1'b0;

    // The hold itself, armed at a reset like every other DIP value.
    bios_setup = 1'b1;
    @(negedge clk);
    rst_n = 0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);
    repeat (4) @(posedge clk);   // let the first make reach the FIFO
    // The ITF's POST re-init now flushes the receive side, discarding that first
    // make; the held key is re-announced and must be what the poll reads.
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);
    read_byte(8'h3F);            // the re-announced make: the key is HELD, not a tap
    repeat (2500) @(posedge clk); // > the bench's HELP_HOLD_CYCLES (2000)
    read_byte(8'hBF);            // ...then the single break that releases HELP
    // The hold is over: a later keyboard reset must NOT re-announce HELP.
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);
    repeat (20) @(posedge clk);
    if (irq) fail("expired HELP hold re-announced a make on keyboard reset");
    bios_setup = 1'b0;
    $display("KBD_HELP: injected HELP held and re-announced (3F/BF) reached the guest");
  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_KBD: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_KBD: FAIL (%0d errors)", errors);
  end

  initial begin
    #50_000_000;
    $fatal(1, "TB_PC9821_KBD: TIMEOUT");
  end

endmodule

// tb_pc9821_kbd_stop — the STOP phantom: what the HOST stream can put in the guest's
// key stream, from Main_MiSTer's bytes through the hps_io normalizer to pc9821_kbd.
//
// ==== WHAT THIS PROVES ====
// No host stream puts a STOP make (0x60) in the guest's key stream unless the user pressed the one key NP2kai maps to STOP (Pause): an F11 tap must reach the guest as VF1 (0x52/0xD2) and a NumLock tap (the non-extended set-2 0x77) as keypad = (0x4D/0xCD), never as STOP, and the framework's normalized Pause token (Main_MiSTer sends the E1 14 77 E1 F0 14 F0 77 make sequence at key RELEASE with no break, user_io.cpp "pause does not have a break code"; hps_io normalizes it to one {pressed,extended,0x77} event, sys/hps_io.sv:309) must reach the guest as the NP2kai tap pair 0x60 make + 0xE0 break and then SILENCE - no stuck STOP make and no typematic flood of a key that can never break.
//
// The host side of this bench is the REAL chain, not an idealized one:
//
//  * Main_MiSTer user_io.cpp send_keycode() emits ONE keyboard transaction per
//    key event - [E0] [F0] code in the generic branch - and for Pause
//    ("(code & 0xff) == 0xE1") it sends the raw PS/2 make sequence
//    { 0xe1, 0x14, 0x77, 0xe1, 0xf0, 0x14, 0xf0, 0x77 } when `press != 1`,
//    i.e. on the key RELEASE and its autorepeat, because "pause does not have
//    a break code". A Pause tap therefore produces exactly ONE such
//    transaction and NO break event ever follows it.
//  * sys/hps_io.sv's cmd-5 keyboard path clears ps2_key_raw at the command
//    byte (:346), shifts each data byte into the 32-bit window (:383) and
//    emits ONE ps2_key event at transaction end (:306-309): code = the last
//    byte, pressed = (window[15:8] != F0), extended = (window[15:8] or
//    [23:16] == E0), with the special cases - and the Pause one is
//    `if(ps2_key_raw == 'hF014F077) ps2_key[9:0] <= 'h377; // pause  pressed`
//    (pressed, extended, code 0x77). hps_io has NO Pause-release case.
//
// So the {extended, 0x77} "Pause pressed" token is make-only by host contract,
// and pc9821_kbd translates it to the STOP make 0x60. NP2kai's guest stream
// for a Pause TAP is a make+break pair: sdl/kbtrans.c {RETROK_PAUSE, 0x60}
// feeds keystat.c keystat_send, which sends the make byte on the down event
// and the break byte (code|0x80) on the up event. The expected guest stream
// for the one-token host event is therefore 0x60, 0xE0 and then nothing -
// and nothing typematic, because a released key stops repeating
// (keystat.c keyrepeat_proc returns while the repeat buffer is empty).
//
// FAIL-FIRST: on the pre-fix pc9821_kbd the F11 tap delivers 0x60/0xE0 (a full
// phantom STOP tap from an ordinary function key NP2kai maps to nothing) and
// the Pause tap delivers a 0x60 make with NO break that the typematic engine
// then repeats as 0xE0/0x60 pairs forever - sections 1/2/4 fail by name. On
// the current tree those are fixed, but the tap's break is a single pending
// bit and the dedup bypass (`wq_down`) is not tap-gated, so two back-to-back
// Pause tokens drop the second tap - section 6 fails by name ("got 1 makes /
// 1 breaks, want 2 / 2") and passes after both are fixed.

`timescale 1ns / 1ps

module tb_pc9821_kbd_stop;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg [10:0] ps2_key = 0;

  // ==== DUT ====
  pc9821_kbd #(
      // The STOP tap's break is presented one (shrunk) transfer tick after its make,
      // inside read_byte_within's 12-clk bound (the real tick is SYS_CLOCK_HZ / 1280).
      .XFER_TICK_CYCLES(26'd8),
      // The typematic window is shrunk so "silence" can be proven over several
      // repeat periods instead of real-time seconds. Values do not matter for
      // the tap: the fixed stream must contain NO repeat byte at all.
      .REPEAT_DELAY(26'd30),
      .REPEAT_INTERVAL(26'd20)
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
      .bios_setup(1'b0)
  );

  integer errors = 0;
  integer timeout_count;
  integer i;
  integer n_makes, n_breaks;
  reg [7:0] value;
  reg toggle = 0;

  // The host's cmd-5 keyboard byte stream for one key EVENT (one transaction):
  // bytes are shifted into the hps_io window, and one ps2_key event fires at
  // the transaction end - sys/hps_io.sv:258-310 verbatim in little-sv form.
  reg [7:0] tx_bytes [0:15];
  integer   tx_count;
  reg [31:0] ps2_key_raw;

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

  // One Main_MiSTer UIO_KEYBOARD transaction: the hps_io window is cleared at
  // the command byte (hps_io.sv:346), the data bytes shift in (:383), and one
  // event is emitted at transaction end (:306-309 with the three overrides).
  task host_event;
    begin
      ps2_key_raw = 32'd0;
      for (i = 0; i < tx_count; i = i + 1) begin
        ps2_key_raw = {ps2_key_raw[23:0], tx_bytes[i]};
      end
      @(negedge clk);
      toggle  = ~toggle;
      ps2_key = {toggle, (ps2_key_raw[15:8] != 8'hf0),
                 ((ps2_key_raw[15:8] != 8'hf0) ? (ps2_key_raw[15:8] == 8'he0)
                                               : (ps2_key_raw[23:16] == 8'he0)),
                 ps2_key_raw[7:0]};
      if (ps2_key_raw == 32'hE012E07C) ps2_key[9:0] = 10'h37C;
      if (ps2_key_raw == 32'h7CE0F012) ps2_key[9:0] = 10'h17C;
      if (ps2_key_raw == 32'hF014F077) ps2_key[9:0] = 10'h377;
      @(posedge clk);
      @(negedge clk);
    end
  endtask

  // Main_MiSTer's generic branch: [E0] [F0] code (user_io.cpp send_keycode).
  task host_key(input pressed, input extended, input [7:0] code);
    begin
      tx_count = 0;
      if (extended) begin
        tx_bytes[0] = 8'hE0;
        tx_count = 1;
      end
      if (!pressed) begin
        tx_bytes[tx_count] = 8'hF0;
        tx_count = tx_count + 1;
      end
      tx_bytes[tx_count] = code;
      tx_count = tx_count + 1;
      host_event();
    end
  endtask

  // Main_MiSTer's Pause branch (user_io.cpp: the c[] sequence at key release).
  task host_pause_tap;
    begin
      tx_bytes[0] = 8'hE1; tx_bytes[1] = 8'h14; tx_bytes[2] = 8'h77; tx_bytes[3] = 8'hE1;
      tx_bytes[4] = 8'hF0; tx_bytes[5] = 8'h14; tx_bytes[6] = 8'hF0; tx_bytes[7] = 8'h77;
      tx_count = 8;
      host_event();
    end
  endtask

  // Two normalized Pause tokens with NO idle cycle between them - the hps_io
  // output for two back-to-back Pause transactions (each normalizes to one
  // {pressed, extended, 0x77} token). This is the tightest spacing the host
  // chain can present, and it is what makes the tap's pending-break bookkeeping
  // observable: a single-bit pending flag drops the second break here.
  task host_pause_tap_tight_pair;
    begin
      @(negedge clk);
      toggle = ~toggle;
      ps2_key = {toggle, 1'b1, 1'b1, 8'h77};
      @(posedge clk);
      @(negedge clk);
      toggle = ~toggle;
      ps2_key = {toggle, 1'b1, 1'b1, 8'h77};
      @(posedge clk);
      @(negedge clk);
    end
  endtask

  // Read one guest byte, failing if none arrives within `budget` clks. The
  // budget is what separates "the tap's own break" from "a typematic break
  // that arrives a repeat-delay later".
  task read_byte_within(input [7:0] expected, input integer budget);
    begin
      timeout_count = 0;
      while (!irq && timeout_count < budget) begin
        @(posedge clk);
        timeout_count = timeout_count + 1;
      end
      if (!irq) begin
        $display("FAIL: keyboard byte %02x never arrived within %0d clk @ %0t",
                 expected, budget, $time);
        errors = errors + 1;
      end else begin
        @(negedge clk);
        a0 = 0;
        cs = 1;
        rd = 1;
        #1 value = dout;
        if (value !== expected) begin
          $display("FAIL: keyboard byte got %02x want %02x @ %0t", value, expected, $time);
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

  // The guest sees NOTHING: no request, no RXRDY, for `cycles` clks. This is
  // where the pre-fix typematic flood of a stuck STOP key is caught.
  task expect_silent(input integer cycles, input [8*48-1:0] who);
    begin
      for (i = 0; i < cycles; i = i + 1) begin
        @(posedge clk);
        #1;
        if (irq || dut.status_reg[1]) begin
          $display("FAIL: %0s produced a byte the stream must not contain (rx=%02x) @ %0t",
                   who, dut.rx_latch, $time);
          errors = errors + 1;
          @(negedge clk);
          a0 = 0;
          cs = 1;
          rd = 1;
          @(posedge clk);
          @(negedge clk);
          cs = 0;
          rd = 0;
        end
      end
    end
  endtask

  // ==== STIMULUS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;
    // The firmware's own init: mode byte, then TxEN+RxE+RTS.
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);

    // ---- 1. F11 and NumLock are not STOP. ----
    // NP2kai's SDL tables map host F11 to no PC-98 key (sdl/kbtrans.c lrcnv101/lrcnv106
    // carry RETROK_F1..F10 and no RETROK_F11 row); NP2kai wx/kbtrans.cpp labels it "VF1"
    // (keystat.tbl 0x52), which is what the core gives it. qemu-pc98's set-1 table maps
    // F11 (0x57) to 0x60 as physical correspondence - secondary. Before the STOP fix F11
    // delivered 0x60/0xE0: a whole phantom STOP tap from an ordinary function key (Set-2
    // 0x78 sitting one code off the normalized Pause token's 0x77). NumLock is the other
    // neighbour: the NON-extended set-2 0x77 (Main_MiSTer ev2ps2 KEY_NUMLOCK), which the
    // core gives keypad = (keystat.tbl 0x4d); only the extended 0x77 token is Pause.
    host_key(1'b1, 1'b0, 8'h78);   // F11 make
    read_byte_within(8'h52, 40);   // VF1, not STOP
    host_key(1'b0, 1'b0, 8'h78);   // F11 break
    read_byte_within(8'hD2, 40);
    expect_silent(16, "F11 tap");
    host_key(1'b1, 1'b0, 8'h77);   // NumLock make
    read_byte_within(8'h4D, 40);   // keypad =, not STOP
    host_key(1'b0, 1'b0, 8'h77);   // NumLock break
    read_byte_within(8'hCD, 40);
    expect_silent(16, "NumLock tap");

    // ---- 2. The normalized Pause token is a TAP: make then break. ----
    // One host event (the make sequence, sent at key release with no break);
    // the guest must see the NP2kai tap pair 0x60, 0xE0.
    host_pause_tap();
    read_byte_within(8'h60, 40);   // the STOP make
    read_byte_within(8'hE0, 12);   // the STOP break - IMMEDIATE, not typematic

    // ---- 3. ...and then silence: the tap key is not stuck down. ----
    // A stuck STOP make leaves key_down set and STOP typematic-repeatable
    // (NP2kai keystat.tbl kbexflag row 0x60 is 0 = repeatable), so the
    // pre-fix module re-emits 0xE0/0x60 pairs every repeat interval forever -
    // the flood that makes any later poll see "the STOP key has been pressed".
    // Three repeat periods must pass with nothing at all.
    expect_silent(3 * 30 + 3 * 20, "the Pause tap's aftermath");

    // ---- 4. A second Pause tap still works (the tap is not a one-shot). ----
    host_pause_tap();
    read_byte_within(8'h60, 40);
    read_byte_within(8'hE0, 12);
    expect_silent(3 * 30 + 3 * 20, "the second Pause tap's aftermath");

    // ---- 5. Control: an ordinary key is unchanged. ----
    host_key(1'b1, 1'b0, 8'h1C);   // A make -> NEC 0x1D
    read_byte_within(8'h1D, 40);
    host_key(1'b0, 1'b0, 8'h1C);   // A break -> NEC 0x9D
    read_byte_within(8'h9D, 40);
    expect_silent(16, "A key aftermath");

    // ---- 6. Two normalized Pause tokens back-to-back: each is one STOP tap. ----
    // Each tap owes its own break; two makes landing before the first break
    // enqueues owe TWO breaks. A single-bit pending flag loses the second break
    // and leaves its make unbroken - a STOP make reaching the guest with no
    // release. NP2kai's stream for two Pause taps is a make+break pair each
    // (keystat_send: make on down, code|0x80 on up): two makes and two breaks,
    // net clear. This section FAILS on the pre-fix tree, which drops the second
    // tap outright (the dedup bypass reads STOP as still down for one cycle).
    host_pause_tap_tight_pair();
    n_makes = 0;
    n_breaks = 0;
    for (i = 0; i < 4; i = i + 1) begin
      timeout_count = 0;
      while (!irq && timeout_count < 60) begin
        @(posedge clk);
        timeout_count = timeout_count + 1;
      end
      if (!irq) begin
        $display("FAIL: tight pair: only %0d of 4 STOP bytes arrived @ %0t", i, $time);
        errors = errors + 1;
        i = 4;
      end else begin
        @(negedge clk);
        a0 = 0;
        cs = 1;
        rd = 1;
        #1 value = dout;
        @(posedge clk);
        @(negedge clk);
        cs = 0;
        rd = 0;
        #1;
        if (value == 8'h60)      n_makes = n_makes + 1;
        else if (value == 8'hE0) n_breaks = n_breaks + 1;
        else begin
          $display("FAIL: tight pair produced %02x (not a STOP make/break) @ %0t", value, $time);
          errors = errors + 1;
        end
      end
    end
    if (n_makes != 2 || n_breaks != 2) begin
      $display("FAIL: tight pair: got %0d makes / %0d breaks, want 2 / 2 @ %0t",
               n_makes, n_breaks, $time);
      errors = errors + 1;
    end
    expect_silent(3 * 30 + 3 * 20, "the tight-pair aftermath");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_STOP: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_STOP: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000;
    $fatal(1, "TB_PC9821_KBD_STOP: TIMEOUT");
  end

endmodule

// tb_pc9821_kbd_layout - the host keyboard layout (OSD "Keyboard": US / JIS): the four keys
// whose symbol differs between a US and a JIS keyboard, the JIS-only and spare keys, and a
// layout change while a layout key is held.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// In the JIS layout the JIS ] key (set-2 0x5D) gives the PC-98 ] key 0x28, @ (0x54) gives 0x1A, [ (0x5B) gives 0x1B and half/full-width (0x0E) gives nothing (NP2kai sdlcnv106); in the US layout [ gives 0x1B, ] gives 0x28, \ gives the YEN key 0x0D and ` gives 0x1A (NP2 winkbd.cpp key106[] by US virtual key); in both, KEY_YEN gives 0x0D, KEY_RO and KEY_102ND give 0x33, muhenkan/henkan give NFER/XFER, katakana/hiragana toggles KANA, F11/F12 give VF1/VF2 and NumLock/ScrollLock give keypad = and keypad ,; and a layout key held across a layout change breaks as the key it made, its re-sent make stays silent, and the next press uses the new layout.
//
// ---- where the expected bytes come from ----
// The PC-98 key numbers: NP2kai keystat.tbl (0x0d "\" YEN, 0x1a "@", 0x1b "[", 0x28 "]",
// 0x33 "_", 0x35 XFER, 0x4d "[=]", 0x4f "[,]", 0x51 NFER, 0x52 VF1, 0x53 VF2, 0x72 KANA).
// JIS: NP2kai sdl/kbtrans.c sdlcnv106 (SDL_SCANCODE_BACKSLASH -> 0x28, LEFTBRACKET -> 0x1a,
// RIGHTBRACKET -> 0x1b, INTERNATIONAL3 (yen) -> 0x0d, INTERNATIONAL1 (ro) -> 0x33, no GRAVE
// row); the conversion keys: NP2kai x/gtk2/gtk_keyboard.c xkeyconv_misc (MUHE 0x51, HENK
// 0x35, HIRA/KATA 0x72) and qemu-pc98 at_set1_to_pc98 (set-1 0x7B -> 0x51, 0x79 -> 0x35).
// US: NP2 windows/winkbd.cpp key106[] indexed by the US virtual key (0xDB `[` -> 0x1b, 0xDD
// `]` -> 0x28, 0xDC `\` -> 0x0d, 0xC0 `` ` `` -> 0x1a, 0xE2 102nd -> 0x33).
// The set-2 codes: Main_MiSTer input.cpp ev2ps2[] (KEY_GRAVE 0x0e, KEY_LEFTBRACE 0x54,
// KEY_RIGHTBRACE 0x5b, KEY_BACKSLASH 0x5d, KEY_102ND 0x61, KEY_RO 0x51, KEY_KATAKANA 0x13,
// KEY_HENKAN 0x64, KEY_MUHENKAN 0x67, KEY_YEN 0x6a, KEY_F11 0x78, KEY_F12 0x07, KEY_NUMLOCK
// 0x77, KEY_SCROLLLOCK 0x7e).
// The spare-key placements (F11/F12 -> VF1/VF2, NumLock/ScrollLock -> keypad = / ,) are this
// core's design, recorded in pc9821_kbd.sv translate() with the references that motivate them;
// the bench pins the design so a later edit cannot drop a key silently.
//
// FAIL-FIRST: before the layout option every row below that gives 0x28, 0x1B on the US [, the
// conversion keys and the spare keys failed (no set-2 code reached 0x28; 0x54 gave 0x1A; 0x13,
// 0x64, 0x67, 0x77, 0x7E gave nothing; F11 nothing; F12 COPY), and without the held-layout
// record the mid-press flip breaks 0x9B for a 0x28 make and leaves ] down in the guest.

`default_nettype none

module tb_pc9821_kbd_layout;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, a0 = 0, wr = 0, rd = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg [10:0] ps2_key = 0;
  reg        layout_jis = 0;

  // ==== DUT ====
  // A short byte-presentation tick keeps back-to-back keys inside read_byte's budget
  // (tb_pc9821_kbd_pace pins the real rate); the typematic delay stays at its real value,
  // far outside this bench's window, so a held key emits nothing by itself.
  pc9821_kbd #(.XFER_TICK_CYCLES(26'd8)) dut (
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
      .bios_setup(1'b0),
      .layout_jis(layout_jis)
  );

  integer errors = 0;
  integer timeout_count;
  reg [7:0] value;
  reg toggle = 0;

  // ==== STIMULUS ====

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

  task read_byte(input [7:0] expected, input [8*48-1:0] who);
    begin
      timeout_count = 0;
      while (!irq && timeout_count < 40) begin
        @(posedge clk);
        timeout_count = timeout_count + 1;
      end
      if (!irq) begin
        $display("FAIL: %0s: got nothing, wanted %02x", who, expected);
        errors = errors + 1;
      end else begin
        @(negedge clk);
        a0 = 0;
        cs = 1;
        rd = 1;
        #1 value = dout;
        if (value !== expected) begin
          $display("FAIL: %0s: got %02x want %02x", who, value, expected);
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

  task expect_silent(input [8*48-1:0] who);
    begin
      repeat (12) @(posedge clk);
      if (irq) begin
        @(negedge clk);
        a0 = 0;
        cs = 1;
        rd = 1;
        #1 value = dout;
        $display("FAIL: %0s produced %02x, the reference expects nothing", who, value);
        errors = errors + 1;
        @(posedge clk);
        @(negedge clk);
        cs = 0;
        rd = 0;
      end
    end
  endtask

  // One tap: make then break, each byte checked (0xFF = the key must give nothing).
  task tap(input extended, input [7:0] code, input [7:0] nec, input [8*48-1:0] who);
    begin
      send_key(1'b1, extended, code);
      if (nec == 8'hFF) expect_silent(who); else read_byte(nec, who);
      send_key(1'b0, extended, code);
      if (nec == 8'hFF) expect_silent(who); else read_byte(nec | 8'h80, who);
    end
  endtask

  // ==== CHECKS ====
  integer pass;
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;
    write_port(1'b1, 8'h5E);   // the firmware's own init: mode byte, then TxEN+RxE+RTS
    write_port(1'b1, 8'h05);

    // ---- 1. The four layout keys, in each layout. ----
    layout_jis = 1'b1;
    tap(1'b0, 8'h5d, 8'h28, "JIS ] (0x5D)");
    tap(1'b0, 8'h54, 8'h1a, "JIS @ (0x54)");
    tap(1'b0, 8'h5b, 8'h1b, "JIS [ (0x5B)");
    tap(1'b0, 8'h0e, 8'hff, "JIS half/full-width (0x0E)");
    layout_jis = 1'b0;
    tap(1'b0, 8'h5d, 8'h0d, "US \\ (0x5D)");
    tap(1'b0, 8'h54, 8'h1b, "US [ (0x54)");
    tap(1'b0, 8'h5b, 8'h28, "US ] (0x5B)");
    tap(1'b0, 8'h0e, 8'h1a, "US ` (0x0E)");

    // ---- 2. The keys both layouts share, checked in both. ----
    for (pass = 0; pass < 2; pass = pass + 1) begin
      layout_jis = pass[0];
      tap(1'b0, 8'h6a, 8'h0d, "KEY_YEN (0x6A)");
      tap(1'b0, 8'h51, 8'h33, "KEY_RO (0x51)");
      tap(1'b0, 8'h61, 8'h33, "KEY_102ND (0x61)");
      tap(1'b0, 8'h67, 8'h51, "muhenkan (0x67) -> NFER");
      tap(1'b0, 8'h64, 8'h35, "henkan (0x64) -> XFER");
      tap(1'b0, 8'h78, 8'h52, "F11 (0x78) -> VF1");
      tap(1'b0, 8'h07, 8'h53, "F12 (0x07) -> VF2");
      tap(1'b0, 8'h77, 8'h4d, "NumLock (0x77) -> keypad =");
      tap(1'b0, 8'h7e, 8'h4f, "ScrollLock (0x7E) -> keypad ,");
      tap(1'b1, 8'h77, 8'h60, "Pause (E0 0x77) -> STOP");
      // katakana/hiragana is the KANA lock: make on the press that turns it on, nothing on
      // release, break on the press that turns it off (as the Menu key's KANA does).
      send_key(1'b1, 1'b0, 8'h13);  read_byte(8'h72, "katakana/hiragana -> KANA on");
      send_key(1'b0, 1'b0, 8'h13);  expect_silent("katakana/hiragana release");
      send_key(1'b1, 1'b0, 8'h13);  read_byte(8'hf2, "katakana/hiragana -> KANA off");
      send_key(1'b0, 1'b0, 8'h13);  expect_silent("katakana/hiragana release");
    end

    // ---- 3. A layout key held across a layout change breaks as the key it made. ----
    // US ] down (0x28), the OSD flips to JIS, the host re-sends the make (Main_MiSTer passes
    // the autorepeat through with PS2WE) - silent, the key is already down - then the release
    // breaks 0x28. A fresh press after it is read in the new layout (JIS [ = 0x1B).
    layout_jis = 1'b0;
    send_key(1'b1, 1'b0, 8'h5b);  read_byte(8'h28, "US ] held");
    layout_jis = 1'b1;
    repeat (4) @(posedge clk);
    send_key(1'b1, 1'b0, 8'h5b);  expect_silent("the held US ]'s re-sent make after a flip");
    send_key(1'b0, 1'b0, 8'h5b);  read_byte(8'ha8, "the held US ]'s break after a flip");
    tap(1'b0, 8'h5b, 8'h1b, "the same key after the flip (JIS [)");
    // ...and the other way: JIS ] down (0x28), flip to US, release breaks 0x28, not YEN.
    send_key(1'b1, 1'b0, 8'h5d);  read_byte(8'h28, "JIS ] held");
    layout_jis = 1'b0;
    repeat (4) @(posedge clk);
    send_key(1'b0, 1'b0, 8'h5d);  read_byte(8'ha8, "the held JIS ]'s break after a flip");
    tap(1'b0, 8'h5d, 8'h0d, "the same key after the flip (US \\)");
    // A key that gives nothing in JIS (half/full-width) held across a flip to US releases
    // silently: it made nothing, so it breaks nothing.
    layout_jis = 1'b1;
    send_key(1'b1, 1'b0, 8'h0e);  expect_silent("JIS half/full-width held");
    layout_jis = 1'b0;
    repeat (4) @(posedge clk);
    send_key(1'b0, 1'b0, 8'h0e);  expect_silent("its release after a flip to US");
    tap(1'b0, 8'h0e, 8'h1a, "the same key after the flip (US `)");
    // Two layout keys, one held across the flip and one pressed after it: each uses its own.
    layout_jis = 1'b0;
    send_key(1'b1, 1'b0, 8'h54);  read_byte(8'h1b, "US [ held");
    layout_jis = 1'b1;
    repeat (4) @(posedge clk);
    send_key(1'b1, 1'b0, 8'h5d);  read_byte(8'h28, "JIS ] pressed after the flip");
    send_key(1'b0, 1'b0, 8'h54);  read_byte(8'h9b, "the held US ['s break");
    send_key(1'b0, 1'b0, 8'h5d);  read_byte(8'ha8, "JIS ]'s break");
    // A flip landing in the same clk as the press: the make and its break still agree.
    @(negedge clk);
    toggle = ~toggle;
    ps2_key = {toggle, 1'b1, 1'b0, 8'h5b};
    layout_jis = 1'b0;
    @(posedge clk);
    @(negedge clk);
    layout_jis = 1'b1;
    read_byte(8'h28, "a press in the flip's clk (US ])");
    send_key(1'b0, 1'b0, 8'h5b);  read_byte(8'ha8, "its break");
    // A release one clk after its press, with the flip in between: the press has not reached
    // the record when the release is read, so the record's bypass must supply it.
    layout_jis = 1'b0;
    @(negedge clk);
    toggle = ~toggle;
    ps2_key = {toggle, 1'b1, 1'b0, 8'h5b};          // US ] make
    @(negedge clk);
    toggle = ~toggle;
    ps2_key = {toggle, 1'b0, 1'b0, 8'h5b};          // its break, one clk later...
    layout_jis = 1'b1;                              // ...as the layout flips
    read_byte(8'h28, "a make one clk before its break");
    read_byte(8'ha8, "the break one clk after its make");
    expect_silent("nothing after the back-to-back pair");

    // ---- 4. The module reset forgets a held layout key. ----
    layout_jis = 1'b0;
    send_key(1'b1, 1'b0, 8'h5b);  read_byte(8'h28, "US ] held into a reset");
    @(negedge clk);
    rst_n = 0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);
    layout_jis = 1'b1;
    send_key(1'b0, 1'b0, 8'h5b);  expect_silent("a release of a key held across the reset");
    tap(1'b0, 8'h5b, 8'h1b, "the key after the reset (JIS [)");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_LAYOUT: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_LAYOUT: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_KBD_LAYOUT: TIMEOUT");
  end

endmodule

`default_nettype wire

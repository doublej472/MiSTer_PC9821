// tb_pc9821_kbd_codes — every Set-2 key the controller maps, its make/break
// byte, the modifier keys and the command/LED status, against NP2kai.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// Every Set-2 key the controller maps reaches the guest as the right make and break byte, the modifier keys (SHIFT/CTRL/GRPH/KANA/NFER/XFER) pass through in the order pressed, a re-sent make of an already-held key emits no second byte, and the 0x9D LED query and 0x43 status report what NP2kai reports. The Round-3 remaps (LAlt->NFER, RAlt->XFER, RCtrl->GRPH) and the newly decoded RO/Yen/PrintScreen/Win/Menu keys are asserted and the 0x96 ID byte is 0x83; both Shift keys reach NEC 0x70; KANA (NEC 0x72) is bound to the Menu/Application key and its toggle is driven alongside CAPS; read in the JIS layout (NP2kai sdlcnv106 is a JIS 106-key map), the JIS ] key (set-2 0x5D) reaches the PC-98 ] key 0x28, and the per-key count (99 agree, 1 wrong value, 9 controller-only, 2 unmapped, 2 mapped by neither) is pinned.
//
// Every Set-2 key the controller maps reaches the guest as the right make and break byte, the modifier keys (SHIFT/CTRL/GRPH/KANA/NFER/XFER) pass through in the order pressed, a re-sent make of an already-held key emits no second byte (the locking keys included: one toggle per PHYSICAL press, M2), and the 0x9D LED query and 0x43 status report what NP2kai reports. The Round-3 remaps (LAlt->NFER, RAlt->XFER, RCtrl->GRPH) and the newly decoded RO/Yen/PrintScreen/Win/Menu keys are asserted and the 0x96 ID byte is 0x83; both Shift keys reach NEC 0x70; KANA (NEC 0x72) is bound to the Menu/Application key and its toggle is driven alongside CAPS; read in the JIS layout (NP2kai sdlcnv106 is a JIS 106-key map), the JIS ] key (set-2 0x5D) reaches the PC-98 ] key 0x28, and the per-key count (99 agree, 1 wrong value, 9 controller-only, 2 unmapped, 2 mapped by neither) is pinned.
//
// ---- where the expected bytes come from ----
// [source 1: NP2kai, the primary reference] NP2kai/sdl/kbtrans.c sdlcnv106 is
// the 106-key PHYSICAL map (SDL scancodes, i.e. USB usage positions, to PC-98
// keys); NP2kai/keystat.tbl names each PC-98 code. NP2kai maps a host
// scancode, not a symbol, so it is the correct reference for a controller that
// receives raw Set-2 from hps_io.
//
// [source 2: qemu-pc98, secondary] qemu-pc98/hw/input/pc98-kbd.c at_set1_to_pc98
// is the same physical correspondence expressed in AT Set-1; the CSV in
// qemu-pc98/subprojects/keycodemapdb links Set-1 and Set-2 through the USB
// usage position, which is how each expected byte below was derived.
//
// [source 3: the BIOS dump] bios/xe10/BANK7.BIN @0x632B is the ITF's key to
// ASCII table; [0x0D] = 0x5C '\' and [0x28] = 0x5D ']': the JIS ] key gives 0x28 here,
// and the US layout routes the US backslash key to the yen key 0x0D, the path separator
// (tb_pc9821_kbd_layout).

`default_nettype none

module tb_pc9821_kbd_codes;

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
  // Shrink the byte-presentation tick so back-to-back keys stay inside read_byte's
  // budget (the real tick is SYS_CLOCK_HZ / 1280; tb_pc9821_kbd_pace pins the rate).
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
      .bios_setup(bios_setup),
      // The JIS layout: NP2kai sdlcnv106, this bench's reference, is a JIS 106-key map.
      // tb_pc9821_kbd_layout covers the US layout's four keys against NP2 winkbd.cpp.
      .layout_jis(1'b1)
  );

  integer errors = 0;
  integer timeout_count;
  reg [7:0] value;
  reg toggle = 0;

  task fail(input [8*110-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

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

  task read_byte(input [7:0] expected);
    begin
      timeout_count = 0;
      while (!irq && timeout_count < 40) begin
        @(posedge clk);
        timeout_count = timeout_count + 1;
      end
      if (!irq) begin
        $display("FAIL: no receive IRQ: got nothing, wanted %02x", expected);
        errors = errors + 1;
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

  // A key NP2kai maps but the controller does not must produce NOTHING. This is
  // how the unmapped half of the conformance finding is pinned.
  task expect_silent(input [8*40-1:0] who);
    begin
      repeat (6) @(posedge clk);
      if (irq) begin
        $display("FAIL: %0s produced a byte the reference does not expect here", who);
        errors = errors + 1;
        a0 = 0;
        cs = 1;
        rd = 1;
        @(posedge clk);
        @(negedge clk);
        cs = 0;
        rd = 0;
      end
    end
  endtask

  // ==== CHECKS ====

  // Every Set-2 code the DUT's translate() maps, with the PC-98 make byte it
  // must produce and NP2kai's value for the same physical key (0xff = NP2kai
  // maps no PC-98 key there). The 0x71/0x72 rows are the two locking keys
  // (CAPS, KANA) and are exercised by their own toggle check below: 0x71 is Caps Lock
  // (Set-2 0x58) and 0x72 is KANA, bound to the Menu/Application key (E0 0x2F) by W1
  // as a deliberate override of NP2kai's APP 0x79 (the row's case_np2 stays
  // 0x79, so it counts as one wrong-value divergence).
  localparam integer KBD_CASES = 111;
  reg [7:0] case_set2 [0:KBD_CASES-1];
  reg       case_ext  [0:KBD_CASES-1];
  reg [7:0] case_nec  [0:KBD_CASES-1];
  reg [7:0] case_np2  [0:KBD_CASES-1];
  initial begin
    case_set2[ 0] = 8'h01; case_ext[ 0] = 1'b0; case_nec[ 0] = 8'h6a; case_np2[ 0] = 8'h6a;
    case_set2[ 1] = 8'h03; case_ext[ 1] = 1'b0; case_nec[ 1] = 8'h66; case_np2[ 1] = 8'h66;
    case_set2[ 2] = 8'h04; case_ext[ 2] = 1'b0; case_nec[ 2] = 8'h64; case_np2[ 2] = 8'h64;
    case_set2[ 3] = 8'h05; case_ext[ 3] = 1'b0; case_nec[ 3] = 8'h62; case_np2[ 3] = 8'h62;
    case_set2[ 4] = 8'h06; case_ext[ 4] = 1'b0; case_nec[ 4] = 8'h63; case_np2[ 4] = 8'h63;
    case_set2[ 5] = 8'h07; case_ext[ 5] = 1'b0; case_nec[ 5] = 8'h53; case_np2[ 5] = 8'hff;
    case_set2[ 6] = 8'h09; case_ext[ 6] = 1'b0; case_nec[ 6] = 8'h6b; case_np2[ 6] = 8'h6b;
    case_set2[ 7] = 8'h0a; case_ext[ 7] = 1'b0; case_nec[ 7] = 8'h69; case_np2[ 7] = 8'h69;
    case_set2[ 8] = 8'h0b; case_ext[ 8] = 1'b0; case_nec[ 8] = 8'h67; case_np2[ 8] = 8'h67;
    case_set2[ 9] = 8'h0c; case_ext[ 9] = 1'b0; case_nec[ 9] = 8'h65; case_np2[ 9] = 8'h65;
    case_set2[10] = 8'h0d; case_ext[10] = 1'b0; case_nec[10] = 8'h0f; case_np2[10] = 8'h0f;
    case_set2[11] = 8'h11; case_ext[11] = 1'b0; case_nec[11] = 8'h51; case_np2[11] = 8'h51;
    case_set2[12] = 8'h12; case_ext[12] = 1'b0; case_nec[12] = 8'h70; case_np2[12] = 8'h70;
    case_set2[13] = 8'h14; case_ext[13] = 1'b0; case_nec[13] = 8'h74; case_np2[13] = 8'h74;
    case_set2[14] = 8'h15; case_ext[14] = 1'b0; case_nec[14] = 8'h10; case_np2[14] = 8'h10;
    case_set2[15] = 8'h16; case_ext[15] = 1'b0; case_nec[15] = 8'h01; case_np2[15] = 8'h01;
    case_set2[16] = 8'h1a; case_ext[16] = 1'b0; case_nec[16] = 8'h29; case_np2[16] = 8'h29;
    case_set2[17] = 8'h1b; case_ext[17] = 1'b0; case_nec[17] = 8'h1e; case_np2[17] = 8'h1e;
    case_set2[18] = 8'h1c; case_ext[18] = 1'b0; case_nec[18] = 8'h1d; case_np2[18] = 8'h1d;
    case_set2[19] = 8'h1d; case_ext[19] = 1'b0; case_nec[19] = 8'h11; case_np2[19] = 8'h11;
    case_set2[20] = 8'h1e; case_ext[20] = 1'b0; case_nec[20] = 8'h02; case_np2[20] = 8'h02;
    case_set2[21] = 8'h21; case_ext[21] = 1'b0; case_nec[21] = 8'h2b; case_np2[21] = 8'h2b;
    case_set2[22] = 8'h22; case_ext[22] = 1'b0; case_nec[22] = 8'h2a; case_np2[22] = 8'h2a;
    case_set2[23] = 8'h23; case_ext[23] = 1'b0; case_nec[23] = 8'h1f; case_np2[23] = 8'h1f;
    case_set2[24] = 8'h24; case_ext[24] = 1'b0; case_nec[24] = 8'h12; case_np2[24] = 8'h12;
    case_set2[25] = 8'h25; case_ext[25] = 1'b0; case_nec[25] = 8'h04; case_np2[25] = 8'h04;
    case_set2[26] = 8'h26; case_ext[26] = 1'b0; case_nec[26] = 8'h03; case_np2[26] = 8'h03;
    case_set2[27] = 8'h29; case_ext[27] = 1'b0; case_nec[27] = 8'h34; case_np2[27] = 8'h34;
    case_set2[28] = 8'h2a; case_ext[28] = 1'b0; case_nec[28] = 8'h2c; case_np2[28] = 8'h2c;
    case_set2[29] = 8'h2b; case_ext[29] = 1'b0; case_nec[29] = 8'h20; case_np2[29] = 8'h20;
    case_set2[30] = 8'h2c; case_ext[30] = 1'b0; case_nec[30] = 8'h14; case_np2[30] = 8'h14;
    case_set2[31] = 8'h2d; case_ext[31] = 1'b0; case_nec[31] = 8'h13; case_np2[31] = 8'h13;
    case_set2[32] = 8'h2e; case_ext[32] = 1'b0; case_nec[32] = 8'h05; case_np2[32] = 8'h05;
    case_set2[33] = 8'h31; case_ext[33] = 1'b0; case_nec[33] = 8'h2e; case_np2[33] = 8'h2e;
    case_set2[34] = 8'h32; case_ext[34] = 1'b0; case_nec[34] = 8'h2d; case_np2[34] = 8'h2d;
    case_set2[35] = 8'h33; case_ext[35] = 1'b0; case_nec[35] = 8'h22; case_np2[35] = 8'h22;
    case_set2[36] = 8'h34; case_ext[36] = 1'b0; case_nec[36] = 8'h21; case_np2[36] = 8'h21;
    case_set2[37] = 8'h35; case_ext[37] = 1'b0; case_nec[37] = 8'h15; case_np2[37] = 8'h15;
    case_set2[38] = 8'h36; case_ext[38] = 1'b0; case_nec[38] = 8'h06; case_np2[38] = 8'h06;
    case_set2[39] = 8'h3a; case_ext[39] = 1'b0; case_nec[39] = 8'h2f; case_np2[39] = 8'h2f;
    case_set2[40] = 8'h3b; case_ext[40] = 1'b0; case_nec[40] = 8'h23; case_np2[40] = 8'h23;
    case_set2[41] = 8'h3c; case_ext[41] = 1'b0; case_nec[41] = 8'h16; case_np2[41] = 8'h16;
    case_set2[42] = 8'h3d; case_ext[42] = 1'b0; case_nec[42] = 8'h07; case_np2[42] = 8'h07;
    case_set2[43] = 8'h3e; case_ext[43] = 1'b0; case_nec[43] = 8'h08; case_np2[43] = 8'h08;
    case_set2[44] = 8'h41; case_ext[44] = 1'b0; case_nec[44] = 8'h30; case_np2[44] = 8'h30;
    case_set2[45] = 8'h42; case_ext[45] = 1'b0; case_nec[45] = 8'h24; case_np2[45] = 8'h24;
    case_set2[46] = 8'h43; case_ext[46] = 1'b0; case_nec[46] = 8'h17; case_np2[46] = 8'h17;
    case_set2[47] = 8'h44; case_ext[47] = 1'b0; case_nec[47] = 8'h18; case_np2[47] = 8'h18;
    case_set2[48] = 8'h45; case_ext[48] = 1'b0; case_nec[48] = 8'h0a; case_np2[48] = 8'h0a;
    case_set2[49] = 8'h46; case_ext[49] = 1'b0; case_nec[49] = 8'h09; case_np2[49] = 8'h09;
    case_set2[50] = 8'h49; case_ext[50] = 1'b0; case_nec[50] = 8'h31; case_np2[50] = 8'h31;
    case_set2[51] = 8'h4a; case_ext[51] = 1'b0; case_nec[51] = 8'h32; case_np2[51] = 8'h32;
    case_set2[52] = 8'h4b; case_ext[52] = 1'b0; case_nec[52] = 8'h25; case_np2[52] = 8'h25;
    case_set2[53] = 8'h4c; case_ext[53] = 1'b0; case_nec[53] = 8'h26; case_np2[53] = 8'h26;
    case_set2[54] = 8'h4d; case_ext[54] = 1'b0; case_nec[54] = 8'h19; case_np2[54] = 8'h19;
    case_set2[55] = 8'h4e; case_ext[55] = 1'b0; case_nec[55] = 8'h0b; case_np2[55] = 8'h0b;
    case_set2[56] = 8'h52; case_ext[56] = 1'b0; case_nec[56] = 8'h27; case_np2[56] = 8'h27;
    case_set2[57] = 8'h54; case_ext[57] = 1'b0; case_nec[57] = 8'h1a; case_np2[57] = 8'h1a;
    case_set2[58] = 8'h55; case_ext[58] = 1'b0; case_nec[58] = 8'h0c; case_np2[58] = 8'h0c;
    case_set2[59] = 8'h58; case_ext[59] = 1'b0; case_nec[59] = 8'h71; case_np2[59] = 8'h71;
    case_set2[60] = 8'h59; case_ext[60] = 1'b0; case_nec[60] = 8'h70; case_np2[60] = 8'h70;
    // RShift: NP2kai's kbtrans.c yields key 0x7D, but its default kbdtype (<2) folds that
    // onto 0x70 in keystat_down and the BIOS shift byte is written only for keys 0x70-0x74,
    // so 0x70 is the byte NP2kai actually puts on the wire and the only one the guest reads.
    case_set2[61] = 8'h5a; case_ext[61] = 1'b0; case_nec[61] = 8'h1c; case_np2[61] = 8'h1c;
    case_set2[62] = 8'h5b; case_ext[62] = 1'b0; case_nec[62] = 8'h1b; case_np2[62] = 8'h1b;
    case_set2[63] = 8'h5d; case_ext[63] = 1'b0; case_nec[63] = 8'h28; case_np2[63] = 8'h28;
    case_set2[64] = 8'h61; case_ext[64] = 1'b0; case_nec[64] = 8'h33; case_np2[64] = 8'hff;
    case_set2[65] = 8'h66; case_ext[65] = 1'b0; case_nec[65] = 8'h0e; case_np2[65] = 8'h0e;
    case_set2[66] = 8'h69; case_ext[66] = 1'b0; case_nec[66] = 8'h4a; case_np2[66] = 8'h4a;
    case_set2[67] = 8'h6b; case_ext[67] = 1'b0; case_nec[67] = 8'h46; case_np2[67] = 8'h46;
    case_set2[68] = 8'h6c; case_ext[68] = 1'b0; case_nec[68] = 8'h42; case_np2[68] = 8'h42;
    case_set2[69] = 8'h70; case_ext[69] = 1'b0; case_nec[69] = 8'h4e; case_np2[69] = 8'h4e;
    case_set2[70] = 8'h71; case_ext[70] = 1'b0; case_nec[70] = 8'h50; case_np2[70] = 8'h50;
    case_set2[71] = 8'h72; case_ext[71] = 1'b0; case_nec[71] = 8'h4b; case_np2[71] = 8'h4b;
    case_set2[72] = 8'h73; case_ext[72] = 1'b0; case_nec[72] = 8'h47; case_np2[72] = 8'h47;
    case_set2[73] = 8'h74; case_ext[73] = 1'b0; case_nec[73] = 8'h48; case_np2[73] = 8'h48;
    case_set2[74] = 8'h75; case_ext[74] = 1'b0; case_nec[74] = 8'h43; case_np2[74] = 8'h43;
    case_set2[75] = 8'h76; case_ext[75] = 1'b0; case_nec[75] = 8'h00; case_np2[75] = 8'h00;
    // F11: VF1 (NP2kai keystat.tbl 0x52; wx/kbtrans.cpp labels WXK_F11 "VF1"), a key
    // NP2kai's SDL table leaves unmapped (case_np2 0xff). It used to answer 0x60 (STOP) -
    // the phantom-STOP source tb_pc9821_kbd_stop fails-first on - and must never again.
    case_set2[76] = 8'h78; case_ext[76] = 1'b0; case_nec[76] = 8'h52; case_np2[76] = 8'hff;
    case_set2[77] = 8'h79; case_ext[77] = 1'b0; case_nec[77] = 8'h49; case_np2[77] = 8'h49;
    case_set2[78] = 8'h7a; case_ext[78] = 1'b0; case_nec[78] = 8'h4c; case_np2[78] = 8'h4c;
    case_set2[79] = 8'h7b; case_ext[79] = 1'b0; case_nec[79] = 8'h40; case_np2[79] = 8'h40;
    case_set2[80] = 8'h7c; case_ext[80] = 1'b0; case_nec[80] = 8'h45; case_np2[80] = 8'h45;
    case_set2[81] = 8'h7d; case_ext[81] = 1'b0; case_nec[81] = 8'h44; case_np2[81] = 8'h44;
    case_set2[82] = 8'h83; case_ext[82] = 1'b0; case_nec[82] = 8'h68; case_np2[82] = 8'h68;
    case_set2[83] = 8'h11; case_ext[83] = 1'b1; case_nec[83] = 8'h35; case_np2[83] = 8'h35;
    case_set2[84] = 8'h14; case_ext[84] = 1'b1; case_nec[84] = 8'h73; case_np2[84] = 8'h73;
    case_set2[85] = 8'h4a; case_ext[85] = 1'b1; case_nec[85] = 8'h41; case_np2[85] = 8'h41;
    case_set2[86] = 8'h5a; case_ext[86] = 1'b1; case_nec[86] = 8'h1c; case_np2[86] = 8'h1c;
    case_set2[87] = 8'h69; case_ext[87] = 1'b1; case_nec[87] = 8'h3f; case_np2[87] = 8'h3f;
    case_set2[88] = 8'h6b; case_ext[88] = 1'b1; case_nec[88] = 8'h3b; case_np2[88] = 8'h3b;
    case_set2[89] = 8'h6c; case_ext[89] = 1'b1; case_nec[89] = 8'h3e; case_np2[89] = 8'h3e;
    case_set2[90] = 8'h70; case_ext[90] = 1'b1; case_nec[90] = 8'h38; case_np2[90] = 8'h38;
    case_set2[91] = 8'h71; case_ext[91] = 1'b1; case_nec[91] = 8'h39; case_np2[91] = 8'h39;
    case_set2[92] = 8'h72; case_ext[92] = 1'b1; case_nec[92] = 8'h3d; case_np2[92] = 8'h3d;
    case_set2[93] = 8'h74; case_ext[93] = 1'b1; case_nec[93] = 8'h3c; case_np2[93] = 8'h3c;
    case_set2[94] = 8'h75; case_ext[94] = 1'b1; case_nec[94] = 8'h3a; case_np2[94] = 8'h3a;
    case_set2[95] = 8'h77; case_ext[95] = 1'b1; case_nec[95] = 8'h60; case_np2[95] = 8'h60;
    case_set2[96] = 8'h7a; case_ext[96] = 1'b1; case_nec[96] = 8'h37; case_np2[96] = 8'h37;
    case_set2[97] = 8'h7c; case_ext[97] = 1'b1; case_nec[97] = 8'h61; case_np2[97] = 8'hff;
    case_set2[98] = 8'h7d; case_ext[98] = 1'b1; case_nec[98] = 8'h36; case_np2[98] = 8'h36;
    // The keys NP2kai's 106-key table reaches and the controller now decodes too
    // (RO, Yen, Win, Win, Menu).
    case_set2[ 99] = 8'h51; case_ext[ 99] = 1'b0; case_nec[ 99] = 8'h33; case_np2[ 99] = 8'h33;
    case_set2[100] = 8'h6a; case_ext[100] = 1'b0; case_nec[100] = 8'h0d; case_np2[100] = 8'h0d;
    // Set-2 0x7F is no key: Main_MiSTer's ev2ps2[] sends it for nothing (PrintScreen reaches
    // the core as hps_io's normalized E0 0x7C, row 97). Mapped by neither.
    case_set2[101] = 8'h7f; case_ext[101] = 1'b0; case_nec[101] = 8'hff; case_np2[101] = 8'hff;
    case_set2[102] = 8'h1f; case_ext[102] = 1'b1; case_nec[102] = 8'h77; case_np2[102] = 8'h77;
    case_set2[103] = 8'h27; case_ext[103] = 1'b1; case_nec[103] = 8'h78; case_np2[103] = 8'h78;
    case_set2[104] = 8'h2f; case_ext[104] = 1'b1; case_nec[104] = 8'h72; case_np2[104] = 8'h79;
    // The JIS half/full-width key (Main KEY_GRAVE/KEY_ZENKAKU -> 0x0e): NP2kai sdlcnv106 has
    // no GRAVE row and neither does the JIS layout (the US layout gives @ there).
    case_set2[105] = 8'h0e; case_ext[105] = 1'b0; case_nec[105] = 8'hff; case_np2[105] = 8'hff;
    // The JIS conversion keys (Main KEY_KATAKANA/HENKAN/MUHENKAN -> 0x13/0x64/0x67). NP2kai's
    // SDL table has no row for them (case_np2 0xff, controller-only); its X11 table maps them
    // to KANA/XFER/NFER (x/gtk2/gtk_keyboard.c xkeyconv_misc HIRA/HENK/MUHE), as here.
    case_set2[106] = 8'h13; case_ext[106] = 1'b0; case_nec[106] = 8'h72; case_np2[106] = 8'hff;
    case_set2[107] = 8'h64; case_ext[107] = 1'b0; case_nec[107] = 8'h35; case_np2[107] = 8'hff;
    case_set2[108] = 8'h67; case_ext[108] = 1'b0; case_nec[108] = 8'h51; case_np2[108] = 8'hff;
    // NumLock/ScrollLock -> keypad = / keypad , (keystat.tbl 0x4d/0x4f), the spare host keys
    // the core gives the two PC-98 keypad keys a PC keypad lacks; NP2kai maps neither.
    case_set2[109] = 8'h77; case_ext[109] = 1'b0; case_nec[109] = 8'h4d; case_np2[109] = 8'hff;
    case_set2[110] = 8'h7e; case_ext[110] = 1'b0; case_nec[110] = 8'h4f; case_np2[110] = 8'hff;
  end

  // NP2kai maps these two Set-2 keys; the controller maps neither (they are the
  // numeric-keypad '=' and ',' positions, which this controller's table leaves out).
  // {extended, set2, np2 code}: KP=, KP,.
  localparam integer MISSING = 2;
  reg [16:0] missing [0:MISSING-1];
  initial begin
    missing[0] = {1'b0, 8'h0f, 8'h4d};
    missing[1] = {1'b0, 8'h6d, 8'h4f};
  end

  integer i;
  integer ref_match;
  integer ref_div;
  integer ref_extra;
  integer ref_none;
  integer ref_missing;
  integer cmd_div;

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    #1;
    // The firmware's own init: mode byte, then TxEN+RxE+RTS.
    write_port(1'b1, 8'h5E);
    write_port(1'b1, 8'h05);

    // ---- 1. Every mapped key: make byte, then break byte. ----
    ref_match = 0;
    ref_div   = 0;
    ref_extra = 0;
    ref_none  = 0;
    for (i = 0; i < KBD_CASES; i = i + 1) begin
      if (case_nec[i] == 8'hff) begin
        // neither side maps this key (0x7F, JIS 0x0E): it must produce NOTHING at all
        send_key(1'b1, case_ext[i], case_set2[i]);
        expect_silent("a key neither side maps");
        send_key(1'b0, case_ext[i], case_set2[i]);
        expect_silent("the break of a key neither side maps");
        ref_none = ref_none + 1;
        continue;
      end
      if (case_nec[i] == 8'h71 || case_nec[i] == 8'h72) begin
        // locking keys toggle on make and report nothing on release, so they
        // are exercised by the toggle check below rather than here
        if (case_np2[i] == 8'hff) ref_extra = ref_extra + 1;
        else if (case_np2[i] == case_nec[i]) ref_match = ref_match + 1;
        else begin
          ref_div = ref_div + 1;
          $display("KBD_REF: set2=%02x ext=%d: controller -> %02x, NP2kai -> %02x",
                   case_set2[i], case_ext[i], case_nec[i], case_np2[i]);
        end
        continue;
      end
      send_key(1'b1, case_ext[i], case_set2[i]);
      read_byte(case_nec[i]);
      send_key(1'b0, case_ext[i], case_set2[i]);
      read_byte(case_nec[i] | 8'h80);
      if (case_np2[i] == 8'hff) ref_extra = ref_extra + 1;
      else if (case_np2[i] == case_nec[i]) ref_match = ref_match + 1;
      else begin
        ref_div = ref_div + 1;
        $display("KBD_REF: set2=%02x ext=%d: controller -> %02x, NP2kai -> %02x",
                 case_set2[i], case_ext[i], case_nec[i], case_np2[i]);
      end
    end

    // ---- 2. NP2kai keys the controller does not map at all. ----
    ref_missing = 0;
    for (i = 0; i < MISSING; i = i + 1) begin
      send_key(1'b1, missing[i][16], missing[i][15:8]);
      expect_silent("an unmapped NP2kai key");
      send_key(1'b0, missing[i][16], missing[i][15:8]);
      expect_silent("the break of an unmapped NP2kai key");
      $display("KBD_REF: set2=%02x ext=%d: NP2kai -> %02x, controller maps nothing",
               missing[i][15:8], missing[i][16], missing[i][7:0]);
      ref_missing = ref_missing + 1;
    end

    // The count is the finding: pin it so a later fix cannot silently change
    // either the bench or the report without failing here.
    if (ref_match !== 99) begin
      $display("FAIL: expected 99 NP2kai agreements, got %0d", ref_match);
      errors = errors + 1;
    end
    if (ref_div !== 1) begin
      $display("FAIL: expected 1 NP2kai value divergence (Menu -> KANA), got %0d", ref_div);
      errors = errors + 1;
    end
    if (ref_extra !== 9) begin
      $display("FAIL: expected 9 controller-only keys, got %0d", ref_extra);
      errors = errors + 1;
    end
    if (ref_none !== 2) begin
      $display("FAIL: expected 2 keys mapped by neither side (0x7F, JIS 0x0E), got %0d", ref_none);
      errors = errors + 1;
    end
    if (ref_missing !== MISSING) begin
      $display("FAIL: expected %0d unmapped NP2kai keys, got %0d", MISSING, ref_missing);
      errors = errors + 1;
    end
    $display("KBD_REF: 99 agree, 1 wrong value, %0d controller-only, %0d unmapped by controller, %0d mapped by neither",
             ref_extra, ref_missing, ref_none);

    // ---- 3. Modifier combinations reach the guest in the order pressed. ----
    // The controller holds no modifier state: SHIFT/CTRL/GRPH are ordinary
    // keys, and the guest sees them as make/break around the key. LShift
    // (Set-2 0x12) and RShift (0x59) both reach SHIFT 0x70; LAlt (0x11) ->
    // NFER 0x51 as NP2kai maps it.
    send_key(1'b1, 1'b0, 8'h12);  read_byte(8'h70);   // LShift
    send_key(1'b1, 1'b0, 8'h1c);  read_byte(8'h1d);   // A
    send_key(1'b0, 1'b0, 8'h1c);  read_byte(8'h9d);   // A break
    send_key(1'b1, 1'b0, 8'h14);  read_byte(8'h74);   // LCtrl
    send_key(1'b1, 1'b0, 8'h11);  read_byte(8'h51);   // LAlt -> NFER
    send_key(1'b1, 1'b0, 8'h24);  read_byte(8'h12);   // E with three modifiers held
    send_key(1'b0, 1'b0, 8'h24);  read_byte(8'h92);
    send_key(1'b0, 1'b0, 8'h11);  read_byte(8'hD1);   // LAlt/NFER break
    send_key(1'b0, 1'b0, 8'h14);  read_byte(8'hf4);
    send_key(1'b0, 1'b0, 8'h12);  read_byte(8'hf0);
    // ...and the key after all that is still the key.
    send_key(1'b1, 1'b0, 8'h2e);  read_byte(8'h05);   // 5
    send_key(1'b0, 1'b0, 8'h2e);  read_byte(8'h85);

    // ---- 4. A re-sent make of a held key is not a second byte. ----
    // hps_io sends one edge per press; a repeated edge for a key already down must not
    // emit another make. (The typematic repeat the keyboard MCU owes the guest is
    // tb_pc9821_kbd_repeat.sv's subject; it is far outside this bench's window.)
    send_key(1'b1, 1'b0, 8'h1d);  read_byte(8'h11);   // W make
    send_key(1'b1, 1'b0, 8'h1d);                      // W held: another make edge
    expect_silent("a re-sent make of a held key");
    send_key(1'b0, 1'b0, 8'h1d);  read_byte(8'h91);   // ...then one break
    send_key(1'b1, 1'b0, 8'h1d);  read_byte(8'h11);   // and a fresh press works
    send_key(1'b0, 1'b0, 8'h1d);  read_byte(8'h91);

    // ---- 5. Locking keys: CAPS toggles, release is silent. ----
    // NP2kai reaches the same make/break-alternating shape through its
    // mechanical-lock path (cnvnewcode maps the 0x79/0x7a latch codes to
    // 0x71/0x72, which then toggle in keystat_down).
    send_key(1'b1, 1'b0, 8'h58);  read_byte(8'h71);   // CAPS on -> make
    // M2: a duplicate make of the HELD lock (a USB re-delivery/resync replay)
    // must not re-toggle or emit a spurious lock byte -- one toggle per press.
    send_key(1'b1, 1'b0, 8'h58);
    expect_silent("a duplicate CAPS make");
    send_key(1'b0, 1'b0, 8'h58);                      // release: silent
    expect_silent("a CAPS release");
    send_key(1'b1, 1'b0, 8'h58);  read_byte(8'hf1);   // CAPS off -> break
    send_key(1'b0, 1'b0, 8'h58);
    expect_silent("a CAPS release");

    // KANA (NEC 0x72) is the other locking key; W1 bound it to the Menu/Application key
    // (E0 0x2F), so this is its first host-reachable toggle. Same shape as CAPS: make on
    // the press that turns it on, nothing on release, break on the press that turns it off.
    send_key(1'b1, 1'b1, 8'h2f);  read_byte(8'h72);   // KANA on -> make
    send_key(1'b1, 1'b1, 8'h2f);                      // M2: duplicate make stays silent
    expect_silent("a duplicate KANA make");
    send_key(1'b0, 1'b1, 8'h2f);                      // release: silent
    expect_silent("a KANA release");
    send_key(1'b1, 1'b1, 8'h2f);  read_byte(8'hf2);   // KANA off -> break
    send_key(1'b0, 1'b1, 8'h2f);
    expect_silent("a KANA release");

    // ---- 6. The 0x9D LED query, the status register, and the commands NP2kai
    // answers differently. No 0x48/0x49 port exists in the PC-98 keyboard
    // controller; the nearest meaning is keypad 6 (0x48) and keypad + (0x49),
    // covered by the mapping loop above.
    cmd_div = 0;
    write_port(1'b0, 8'h9d);  read_byte(8'hfa);       // two-byte command ack
    write_port(1'b0, 8'h60);  read_byte(8'hfa);
    read_byte(8'h70);                                  // both locks off
    send_key(1'b1, 1'b0, 8'h58);  read_byte(8'h71);   // CAPS on
    write_port(1'b0, 8'h9d);  read_byte(8'hfa);
    write_port(1'b0, 8'h60);  read_byte(8'hfa);
    read_byte(8'h74);                                  // CAPS bit 2 set
    send_key(1'b0, 1'b0, 8'h58);
    send_key(1'b1, 1'b0, 8'h58);  read_byte(8'hf1);   // CAPS off
    send_key(1'b0, 1'b0, 8'h58);
    // 0x96 keyboard ID: NP2kai returns FA A0 83 (keystat_ctrlsend), which the
    // controller now answers.
    write_port(1'b0, 8'h96);  read_byte(8'hfa); read_byte(8'ha0); read_byte(8'h83);
    $display("KBD_REF: 0x96 -> FA A0 83, NP2kai -> FA A0 83");
    // 0x99 is unknown to NP2kai (0xFC) but answered FA FB here.
    write_port(1'b0, 8'h99);  read_byte(8'hfa); read_byte(8'hfb);
    $display("KBD_REF: 0x99 -> FA FB, NP2kai treats 0x99 as unknown -> 0xFC");
    cmd_div = cmd_div + 1;
    // A 0x9D parameter that is neither 0x60 nor 0x7x is silent in NP2kai and
    // QEMU, and now silent here too (the old 0xFC was a divergence).
    write_port(1'b0, 8'h9d);  read_byte(8'hfa);
    write_port(1'b0, 8'h50);
    expect_silent("0x9D param 0x50 (NP2kai/QEMU answer nothing)");
    if (cmd_div !== 1) begin
      $display("FAIL: expected 1 NP2kai command divergence, got %0d", cmd_div);
      errors = errors + 1;
    end
    // 0x9F identity probe: both references answer FA A0 80.
    write_port(1'b0, 8'h9f);  read_byte(8'hfa); read_byte(8'ha0); read_byte(8'h80);
    a0 = 1;
    #1; value = dout;
    if (value !== 8'h85) begin
      $display("FAIL: 0x43 status is %02x, NP2kai returns status|0x85", value);
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_KBD_CODES: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_KBD_CODES: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_KBD_CODES: TIMEOUT");
  end

endmodule

`default_nettype wire

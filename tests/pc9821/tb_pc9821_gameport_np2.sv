`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GAMEPORT_NP2: an INDEPENDENT differential of the game port against NP2kai cbus/board118.c, the PRIMARY reference, and NOT against the module's own bench: the -118's eight addresses 0x1480-0x1487 and no neighbour, the byte's bits 4..7 = A/B/X/Y active low and bits 0/1 the two axis one-shots, and the whole byte again against a direct port of ao486's joystick.v read expression (with this core's one-term disable-mask correction), which is where the module's fields come from. In every single-stick configuration NP2kai can model, the byte is BIT-FOR-BIT its board118.c:341 transform of the pad, at power-up, the instant after a trigger, and after the axes have run out. It records, one named DIVERGENCE line each, the four remaining places the core and NP2kai disagree - the axis one-shot length (IBM 22..1022 ticks against NP2kai's own clkmax/1430 ~= 0.7 ms), the live second-stick bits 2/3 and 6/7 the OSD default leaves enabled, the no-pad 0xF0 where NP2kai answers 0xFF, and the pad's 3rd/4th buttons not merged onto OPNA register 0x0E's two switch lines - and none of them is asserted, because none is an RTL defect. The fifth divergence, a disabled stick 1's buttons 3/4 leaking in 4-button mode, WAS a latent RTL defect: it is FIXED in pc9821_gameport and case 5d now asserts the disabled stick reads absent.
//
// ---- the references, and the exact transform ----
// NP2kai cbus/board118.c:816-822 attaches gameport_o1480/gameport_i1480 to 0x1480..0x1487
// and no other port; :333-367 is the trigger, :369-458 the sample, and :341 is the byte
//   ((joyflag >> 2) & 0x30) | ((joyflag << 2) & 0xc0) | 0x0f
// with the pad's own joymng byte (sdl/joymng.c, JOY1BTN default {1,2,5,6}) putting A at
// joyflag bit 6, B at 7, X at 4 and Y at 5 -- so the transform lands A,B,X,Y on read bits
// 4..7 in order, and the trigger sets bits 0..3 to 1 (:341's `| 0x0f`). NP2kai clears only
// bits 0/1, by elapsed time against a per-direction threshold (:429-446): UP/LEFT -> near
// zero (clkmax/100), DOWN/RIGHT -> near full (clkmax - clkmax/100), otherwise clkmax/2, with
// clkmax = baseclock*maxmultiple/1430 ~= 0.7 ms (:395,:407). It returns 0xFF outright with
// no joystick available (:383-386), and its untriggered power-up gameport_joyflag is 0x00
// (:312), so an untriggered read has bits 0..3 = 0.
//
// The module under test is driven as a single stick exactly the way z486_mister.sv drives it:
// joystick_0[3:0] = up/down/left/right, [4]/[5]/[6]/[7] = A/B/X/Y (ao486.sv:755-790).

`default_nettype none

module tb_pc9821_gameport_np2;
  reg clk = 0;
  always #10 clk = ~clk;        // 50 MHz, the rate the module's parameters assume

  // ==== DUT ====
  // The card's claim, decoded the way pc9821_system decodes it.
  reg  [15:0] addr = 16'd0;
  wire gameport_cs;
  pc9821_device_select #(.GAMEPORT_118(1)) select_dut (.addr(addr), .gameport_cs(gameport_cs));

  // The device bus strobes, one clk each exactly as pc9821_iobus's S_BYTE issues them.
  reg         reset = 1;
  reg         io_wr = 0, io_rd = 0;
  wire [7:0]  io_dout;
  wire [5:0]  switch_lines;
  reg  [1:0]  dis = 2'b00, mode = 2'd0, timed = 2'd0;
  reg  [13:0] dig_1 = 14'd0, dig_2 = 14'd0;
  reg  [15:0] ana_1 = 16'd0, ana_2 = 16'd0;

  pc9821_gameport #(.SYS_CLOCK_HZ(50_000_000)) dut (
    .clk(clk), .reset(reset),
    .io_wr(io_wr), .io_rd(io_rd), .io_dout(io_dout),
    .dis(dis), .mode(mode), .timed(timed),
    .dig_1(dig_1), .dig_2(dig_2), .ana_1(ana_1), .ana_2(ana_2),
    .switch_lines(switch_lines)
  );

  integer errors = 0;         // a required check failed
  integer divergences = 0;    // an NP2kai disagreement, reported and NOT asserted
  integer checks = 0;

  // NP2kai's game-port constants, in 1.1 us ticks: clkmax = baseclock*maxmultiple/1430.
  // At 66 MHz that is 46154 CPU clk = 699 us = 636 ticks; MGN2 = clkmax/100.
  localparam integer NP2_CLKMAX = 636;
  localparam integer NP2_MGN2   = NP2_CLKMAX / 100;         // 6
  localparam integer NP2_MID    = NP2_CLKMAX / 2;           // 318
  localparam integer NP2_FAR    = NP2_CLKMAX - NP2_MGN2;    // 630

  // ==== STIMULUS ====
  task automatic fail(input [8*96-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic diverge(input [8*200-1:0] message);
    begin
      $display("DIVERGENCE: %0s", message);
      divergences = divergences + 1;
    end
  endtask

  // A trigger: settle the shared discharge rotator on the current position for a full four
  // clk (the module keeps ONE chain time-shared over four axes), then one io_wr.
  task automatic trigger;
    begin
      repeat (4) @(posedge clk);
      @(negedge clk); io_wr = 1'b1;
      @(posedge clk); #1;
      io_wr = 1'b0;
    end
  endtask

  task automatic sample(output [7:0] b);
    begin
      #1; b = io_dout;
    end
  endtask

  // Wait until all four one-shots have run out.
  task automatic discharge;
    integer guard;
    begin
      guard = 0;
      while (((io_dout & 8'h0F) != 8'd0) && guard < 400_000) begin
        guard = guard + 1;
        @(posedge clk);
      end
    end
  endtask

  // A direct port of ao486's read expression, with the one-term disable-mask correction
  // this core carries: in 4-button mode bits 6/7 are stick 1's, so the
  // mask there follows dis[0] and not ao486's dis[1]. Over an idle (all-zero) axis state
  // the byte is a pure function of the fields, so this checks the WHOLE byte function.
  task automatic ao486_byte(input [1:0] d, m, input [7:0] d1, d2,
                            input [3:0] ax, output [7:0] b);
    reg [7:0] but;
    reg [7:0] msk;
    begin
      but[7] = ~(m == 2'd1 ? d1[7] : d2[5]);
      but[6] = ~(m == 2'd1 ? d1[6] : d2[4]);
      but[5] = ~d1[5];
      but[4] = ~d1[4];
      msk = 8'd0;
      if ((m == 2'd1) ? d[0] : d[1]) msk[7:6] = 2'b11;
      if (d[0]) msk[5:4] = 2'b11;
      if (d[1]) msk[3:2] = 2'b11;
      if (d[0]) msk[1:0] = 2'b11;
      b = (m == 2'd3) ? 8'hFF : ({but[7:4], ax} | msk);
    end
  endtask

  // NP2kai's transform of a pad byte, SETTLED (its one-read decide latency ignored): the
  // buttons from the live joyflag, the low nibble 0x0f after any trigger (:341) with bits
  // 0/1 cleared once elapsed has passed that axis's threshold (:420-457).
  function automatic [7:0] np2_joyflag(input up, down, left, right,
                                       input b1, b2, b3, b4);
    begin
      np2_joyflag = 8'hFF;
      if (up)    np2_joyflag[0] = 1'b0;
      if (down)  np2_joyflag[1] = 1'b0;
      if (left)  np2_joyflag[2] = 1'b0;
      if (right) np2_joyflag[3] = 1'b0;
      if (b3)    np2_joyflag[4] = 1'b0;   // X
      if (b4)    np2_joyflag[5] = 1'b0;   // Y
      if (b1)    np2_joyflag[6] = 1'b0;   // A
      if (b2)    np2_joyflag[7] = 1'b0;   // B
    end
  endfunction

  function automatic [7:0] np2_read(input [7:0] jf, jf_base, input integer elapsed,
                                    input triggered);
    reg [7:0] r;
    integer tx, ty;
    begin
      r = ((jf >> 2) & 8'h30) | ((jf << 2) & 8'hC0) |
          (triggered ? 8'h0F : 8'h00);
      tx = NP2_MID; ty = NP2_MID;
      if (jf_base[0] == 1'b0) ty = NP2_MGN2;   // UP
      if (jf_base[1] == 1'b0) ty = NP2_FAR;    // DOWN
      if (jf_base[2] == 1'b0) tx = NP2_MGN2;   // LEFT
      if (jf_base[3] == 1'b0) tx = NP2_FAR;    // RIGHT
      if (elapsed >= tx) r[0] = 1'b0;
      if (elapsed >= ty) r[1] = 1'b0;
      np2_read = r;
    end
  endfunction

  // dig_1 bits: 0 R, 1 L, 2 D, 3 U, 4 A, 5 B, 6 X, 7 Y.
  function automatic [7:0] np2_pad(input [7:0] d1);
    begin
      np2_pad = np2_joyflag(d1[3], d1[2], d1[1], d1[0], d1[4], d1[5], d1[6], d1[7]);
    end
  endfunction

  integer i, m, d;
  integer tx_lo, tx_hi, tx_mid;
  reg [7:0] got, want, want_idle;
  reg [15:0] pa;

  // ==== CHECKS ====
  initial begin
    repeat (8) @(negedge clk);
    reset = 1'b0;
    repeat (8) @(negedge clk);

    // ---- 1. the card's claim: exactly 0x1480-0x1487 and no neighbour ----------------
    // board118.c:816-822 attaches both handlers to all eight addresses and nothing else.
    checks = checks + 1;
    for (pa = 16'h1470; pa <= 16'h1490; pa = pa + 16'd1) begin
      addr = pa; #1;
      if (gameport_cs !== ((pa >= 16'h1480) && (pa <= 16'h1487))) begin
        fail("the game port's claim on 0x1480-0x1487 is wrong at this address");
      end
    end

    // ---- 2. the whole byte function against ao486's expression (corrected mask) -----
    // The module's fields are ao486's; an idle axis state (no trigger) makes the byte a pure
    // function of {dis, mode, dig_1, dig_2}, which this sweeps 16k times. The mask it
    // compares against carries this core's one-term fix: a disabled stick 1 masks 6/7 too.
    for (d = 0; d < 4; d = d + 1) begin
      for (m = 0; m < 4; m = m + 1) begin
        for (i = 0; i < 256; i = i + 1) begin
          dis = d[1:0]; mode = m[1:0];
          dig_1 = {6'd0, i[7:0]};
          dig_2 = {6'd0, i[7:0]};
          #1;
          ao486_byte(dis, mode, dig_1[7:0], dig_2[7:0], 4'd0, want);
          if (io_dout !== want) begin
            $display("FAIL: byte dis=%b mode=%0d dig_1=%02x dig_2=%02x: got %02x, ao486 joystick.v read expression wants %02x",
                     dis, mode, dig_1[7:0], dig_2[7:0], io_dout, want);
            errors = errors + 1;
          end
        end
      end
    end
    checks = checks + 1;
    dis = 2'b00; mode = 2'd0; dig_1 = 14'd0; dig_2 = 14'd0;
    repeat (4) @(posedge clk);

    // ---- 3. NP2kai's single-stick byte, bit for bit ---------------------------------
    // One stick, no second: stick 2 idle, so the core's bits 2/3 and 6/7 are NP2kai's. In
    // 4-button mode bits 6/7 carry stick 1's X/Y, which is where NP2kai puts them too.
    mode = 2'd1; dis = 2'b00; dig_2 = 14'd0; timed = 2'd0;

    // 3a. untriggered: NP2kai's power-up low nibble is 0 (:312); no trigger has run, so the
    // core's four counters are all 0. Every combination of the pad's eight bits.
    for (i = 0; i < 256; i = i + 1) begin
      dig_1 = {6'd0, i[7:0]};
      repeat (4) @(posedge clk);
      checks = checks + 1;
      sample(got);
      want_idle = np2_read(np2_pad(i[7:0]), np2_pad(i[7:0]), 0, 1'b0);
      if (got !== want_idle) begin
        $display("FAIL: NP2kai single-stick untriggered dig_1=%02x: got %02x, board118.c wants %02x",
                 i[7:0], got, want_idle);
        errors = errors + 1;
      end
    end

    // 3b. the instant after a trigger every one of bits 0..3 is 1 (:341's `| 0x0f`). Each
    // trigger reloads all four counters, so no discharge is needed between combinations.
    for (i = 0; i < 256; i = i + 1) begin
      dig_1 = {6'd0, i[7:0]};
      trigger;
      checks = checks + 1;
      got = io_dout;
      want = np2_read(np2_pad(i[7:0]), np2_pad(i[7:0]), 0, 1'b1);
      if (got !== want) begin
        $display("FAIL: NP2kai single-stick just-triggered dig_1=%02x: got %02x, board118.c wants %02x",
                 i[7:0], got, want);
        errors = errors + 1;
      end
    end

    // 3b'. the DEFAULT OSD shape, 2 buttons and both sticks: a 2-button pad's A/B land in
    // bits 4/5 and nothing else is pressed, which is the byte every game actually reads.
    mode = 2'd0;
    for (i = 0; i < 4; i = i + 1) begin
      dig_1 = {8'd0, i[1:0], 4'd0};
      trigger;
      checks = checks + 1;
      got = io_dout;
      want = np2_read(np2_pad(dig_1[7:0]), np2_pad(dig_1[7:0]), 0, 1'b1);
      if (got !== want) begin
        $display("FAIL: NP2kai 2-button default dig_1=%02x: got %02x, board118.c wants %02x",
                 dig_1[7:0], got, want);
        errors = errors + 1;
      end
    end
    mode = 2'd1; dig_1 = 14'd0; discharge;

    // 3c. after the axes run out: bits 0/1 clear. A representative set, because each one
    // costs a full discharge; the direction bits set NP2kai's threshold (:429-446).
    begin : after_discharge
      integer k;
      integer combo [0:7];
      combo[0] = 8'h00; combo[1] = 8'h01; combo[2] = 8'h02; combo[3] = 8'h04;
      combo[4] = 8'h08; combo[5] = 8'h0F; combo[6] = 8'hF0; combo[7] = 8'hFF;
      for (k = 0; k < 8; k = k + 1) begin
        dig_1 = {6'd0, combo[k][7:0]};
        trigger;
        discharge;
        checks = checks + 1;
        got = io_dout;
        want = np2_read(np2_pad(combo[k][7:0]), np2_pad(combo[k][7:0]), 100000, 1'b1);
        if ((got & 8'h03) !== (want & 8'h03)) begin
          $display("FAIL: NP2kai single-stick after discharge dig_1=%02x: got %02x, board118.c wants %02x",
                   combo[k][7:0], got, want);
          errors = errors + 1;
        end
      end
    end
    dig_1 = 14'd0; discharge;

    // ---- 4. the OPNA register 0x0E's six switch lines -------------------------------
    // fmboard.c:54-90 fmboard_getjoy's order: up, down, left, right, button 1, button 2,
    // active low. With a 2-button pad (X and Y released) every switch agrees.
    dis = 2'b00; mode = 2'd0; dig_2 = 14'd0;
    checks = checks + 1;
    for (i = 0; i < 16; i = i + 1) begin
      dig_1[3:0] = i[3:0];
      dig_1[7:4] = 4'd0;
      #1;
      want = {2'b11, ~{dig_1[5], dig_1[4], dig_1[0], dig_1[1], dig_1[2], dig_1[3]}};
      if (switch_lines !== want[5:0]) begin
        $display("FAIL: OPNA 0x0E switches for dirs=%b: got %06b, fmboard_getjoy wants %06b",
                 i[3:0], switch_lines, want[5:0]);
        errors = errors + 1;
      end
    end
    dig_1 = 14'd0; #1;

    // ---- 5. the DIVERGENCES, reported and not asserted ------------------------------
    // They are the places the core and NP2kai genuinely answer differently; none is an RTL
    // defect, so a fix would be a decision rather than a repair.

    // 5a. the axis one-shot's length. NP2kai's full scale is clkmax ~= 0.7 ms and its near
    // end clkmax/100 ~= 7 us; this core's is the IBM formula 24.2 us..1.124 ms. A game that
    // measures the axis reads a longer number here than on NP2kai.
    dis = 2'b00; mode = 2'd0; dig_2 = 14'd0; ana_1 = 16'd0; timed = 2'd0;
    dig_1 = 14'b0000_0000_0000_0010;    // left: X near end
    repeat (4) @(posedge clk);
    trigger;
    begin : near_measure
      integer c;
      c = 0;
      while (((io_dout & 8'h01) != 8'd0) && c < 400_000) begin
        c = c + 1; @(posedge clk);
      end
      tx_lo = c;
    end
    dig_1 = 14'd0;                      // centre
    repeat (4) @(posedge clk);
    trigger;
    begin : mid_measure
      integer c;
      c = 0;
      while (((io_dout & 8'h01) != 8'd0) && c < 400_000) begin
        c = c + 1; @(posedge clk);
      end
      tx_mid = c;
    end
    dig_1 = 14'b0000_0000_0000_0001;    // right: X far end
    repeat (4) @(posedge clk);
    trigger;
    begin : far_measure
      integer c;
      c = 0;
      while (((io_dout & 8'h01) != 8'd0) && c < 400_000) begin
        c = c + 1; @(posedge clk);
      end
      tx_hi = c;
    end
    checks = checks + 1;
    if (tx_lo >= NP2_MGN2 * 55)
      diverge("axis one-shot, near end: core clears after 22 ticks (24.2 us, IBM 24.2+0.011R); NP2kai board118.c:407 clkmax/1430*50 gives clkmax/100 = 7 us");
    if (tx_mid >= NP2_MID * 55)
      diverge("axis one-shot, centre: core clears after 524 ticks (576 us); NP2kai board118.c:429 clkmax/2 = 350 us");
    if (tx_hi >= NP2_FAR * 55)
      diverge("axis one-shot, far end: core clears after 1022 ticks (1124 us); NP2kai board118.c:407 clkmax = 700 us");
    dig_1 = 14'd0;
    discharge;

    // 5b. the second stick. The OSD declares no joystick entry, so joystick_dis is 0 and
    // BOTH sticks are enabled (pc9821_gameport.sv:33, `dis = 2'b00 (both sticks present)`): bits 2/3 are stick 2's live axes, which
    // run down, where NP2kai - which models one pad - latches 2/3 to 1 and never clears them.
    dis = 2'b00; mode = 2'd0; dig_1 = 14'd0; dig_2 = 14'd0;
    trigger;
    discharge;
    checks = checks + 1;
    if ((io_dout & 8'h0C) !== 8'h0C)
      diverge("second stick, bits 2/3 after discharge: core reads stick 2's discharged axes as 0; NP2kai board118.c:341 leaves bits 2/3 at 1 (it models one pad)");

    // 5c. no joystick. NP2kai returns 0xFF whenever joymng_available() is 0 (:383-386);
    // the core's equivalent is a per-stick disable, which the OSD cannot reach, so with
    // nothing plugged in the core answers an enabled but idle stick.
    reset = 1'b1; repeat (4) @(negedge clk); reset = 1'b0; repeat (4) @(negedge clk);
    dis = 2'b00;
    checks = checks + 1;
    if (io_dout !== 8'hFF)
      diverge("no joystick: core's default dis=2'b00 answers an idle enabled stick; NP2kai board118.c:383-386 answers 0xFF with no joystick available");

    // 5d. a disabled stick in 4-button mode. FIXED: dis=2'b01 disables
    // stick 1, and in 4-button mode bits 6/7 are stick 1's buttons 3/4, so the mask now
    // covers them and the disabled stick reads absent. On the pre-fix RTL this diverge
    // fired (bit 6 read 0); it must not now.
    dis = 2'b01; mode = 2'd1; dig_1 = 14'b0000_0000_0100_0000; dig_2 = 14'd0; #1;
    checks = checks + 1;
    if (io_dout[6] !== 1'b1)
      diverge("disabled stick 1, 4-button mode: its button 3 (dig_1[6]) still shows in bit 6; the module's contract and NP2kai's 0xFF say a disabled stick is absent");

    // 5e. the OPNA register 0x0E with a 4-button pad. fmboard_getjoy composes the rapid and
    // non-rapid lines of each button (`ret &= ((ret >> 2) | ~0x30)`, sound/fmboard.c:82), so
    // the pad's 3rd/4th buttons merge onto its two button lines; this core carries only A/B.
    dis = 2'b00; mode = 2'd1; dig_1 = 14'b0000_0000_0100_0000; dig_2 = 14'd0; #1;
    checks = checks + 1;
    if (switch_lines[4] !== 1'b0)
      diverge("OPNA 0x0E button 1 with only the pad's X held: core reads released (it carries only A/B); NP2kai sound/fmboard.c:54-82 merges X onto button 1 and reads pressed");

    // ==== VERDICT ====
    $display("TB_PC9821_GAMEPORT_NP2: checks=%0d errors=%0d divergences=%0d",
             checks, errors, divergences);
    if (errors == 0) begin
      $display("TB_PC9821_GAMEPORT_NP2: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GAMEPORT_NP2: FAIL (%0d errors)", errors);
  end

  // A bench that stops making progress names itself instead of hanging the runner.
  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_GAMEPORT_NP2: TIMEOUT");
  end

endmodule

`default_nettype wire

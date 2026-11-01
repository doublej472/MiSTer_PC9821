// tb_pc9821_audio_out_sat - the 48 kHz stage's FIR clamp saturates to the rail of the true sum.
//
// ==== WHAT THIS PROVES ====
// The 48 kHz output stage's FIR clamp saturates toward the sign of the TRUE sum (the meaning of saturation: ymfm's clamp16, ymfm_opn.cpp:1410-1414, and NP2kai's _saturation_s16 junction): on every stage-B (19-tap) and stage-C (247-tap polyphase) run of pc9821_audio_out, the 16-bit output equals floor(acc / 2^17) clamped to [-32768, +32767], so an accumulator above the positive range gives exactly +32767 and one below the negative range exactly -32768 (the pre-fix engine picked the rail from bit 32, which on an overflow is the inverted sign, and turned a +32767 overshoot into -32768), over a full-scale square, a half-to-full-scale square and the Policenauts CD track-3 plateau (54 disc samples around track-3 sample 3668679, L = 32767, at 44.1 kHz on the 2.4576 MHz grid, three 44.1/48 kHz phases) with the right channel the negation of the left; and an input held inside [+16384, +32767] (or its negation) never yields an output of the opposite sign at stage B, stage C or AUDIO_L/R (the shipped tables bound the output above +4485 for such an input).
//
// ==== DUT ====
// pc9821_audio_out (src/pc9821/audio/pc9821_audio_out.sv with the pc9821_audio_cic4 and the
// two pc9821_audio_fir_engine instances it holds). The bench reads each engine's accumulator
// and done strobe hierarchically: the accumulator IS the true sum, because it is exact
// (tools/check_fir_acc_bound.py: |acc| <= 32768 * sum|coef| < 2^33 for every stage and phase,
// inside the 34-bit register), so the expected output is a function of the sum alone, never of
// the RTL's clamp.
//
// ==== CHECKS ====
// CHK-1 on every stage-B and stage-C done, both channels: out == clamp16(acc >>> 17), which
//       makes acc > 2^32 - 1 -> exactly +32767 and acc < -2^32 -> exactly -32768.
// CHK-2 while the left input has stayed inside [+16384, +32767] (right: its negation) for at
//       least SETTLE strobes (stage C's 247 taps at 307.2 kHz span 1976 strobes), no stage-B,
//       stage-C or AUDIO_L output is negative and no right output is positive. The bound, from
//       the shipped tables: stage B's output >= 16384*sum(h+) - 32767*sum|h-| = +14175, and
//       stage C's (worst phase) >= +4485, so a sign flip is a clamp fault, not the filter.
// CHK-3 non-vacuity: the positive overflow (acc > 2^32 - 1) and the negative one
//       (acc < -2^32) were each reached at stage B and at stage C, and the disc plateau by
//       itself overflowed stage B and stage C positively.
//
// ==== VERDICT ====
// PASS when every run's output is its sum's saturation and no sign flipped; FAIL names the
// stage, channel, accumulator and output of the first offence.
//
`timescale 1ns/1ps
module tb_pc9821_audio_out_sat;
  reg clk = 0;
  always #5 clk = ~clk;

  reg               valid = 0;
  reg signed [15:0] in_l = 0, in_r = 0;
  wire signed [15:0] out_l, out_r;

  pc9821_audio_out dut (.clk(clk), .valid(valid), .in_l(in_l), .in_r(in_r), .out_l(out_l), .out_r(out_r));

  // The two engines' sums, done strobes and outputs.
  wire               b_done = dut.u_fir_b.done;
  wire signed [33:0] b_acc_l = dut.u_fir_b.acc_l, b_acc_r = dut.u_fir_b.acc_r;
  wire signed [15:0] b_l = dut.u_fir_b.out_l, b_r = dut.u_fir_b.out_r;
  wire               c_done = dut.u_fir_c.done;
  wire signed [33:0] c_acc_l = dut.u_fir_c.acc_l, c_acc_r = dut.u_fir_c.acc_r;
  wire signed [15:0] c_l = dut.u_fir_c.out_l, c_r = dut.u_fir_c.out_r;

  // Policenauts CD, track 3 (LBA 186817), left channel, track-3 samples 3668645 .. 3668698:
  // the plateau's 32767 is entry 34 (sample 3668679). Raw 16-bit disc PCM.
  localparam integer NDISC = 54;
  localparam integer DISC [0:NDISC-1] = '{
    16758, 18642, 20776, 20338, 18981, 19254, 22575, 23797, 24339, 24174,
    23700, 23267, 20889, 20059, 19521, 18866, 18084, 19312, 20199, 21045,
    22941, 23694, 24816, 25748, 27587, 29872, 32469, 32722, 32684, 32704,
    32659, 32732, 32297, 32339, 32767, 32584, 32701, 31737, 31369, 31418,
    31109, 29700, 29735, 29444, 27733, 24623, 22930, 23399, 22535, 21159,
    19557, 18130, 16955, 16640
  };
  localparam integer RAMP   = 128;    // disc-rate samples of ramp each side of the excerpt
  localparam integer SETTLE = 4000;   // strobes inside the band before CHK-2 applies
  localparam integer FLOOR  = 16384;

  integer errors = 0, phase = 0, e1 = 0, e2 = 0;
  integer b_pos = 0, b_neg = 0, c_pos = 0, c_neg = 0, disc_b = 0, disc_c = 0;
  integer inband = 0;                 // consecutive strobes the input has been in the band
  reg     sign_on = 0;                // CHK-2 armed (the phase holds the input in the band)

  function automatic signed [15:0] sat16(input signed [33:0] a);
    reg signed [33:0] q;
    begin
      q = a >>> 17;
      if (q > 34'sd32767)       sat16 = 16'sh7FFF;
      else if (q < -34'sd32768) sat16 = 16'sh8000;
      else                      sat16 = q[15:0];
    end
  endfunction

  task automatic chk1(input [8*8-1:0] st, input integer ch, input signed [33:0] a, input signed [15:0] y);
    begin
      if (y !== sat16(a)) begin
        errors = errors + 1;
        e1 = e1 + 1;
        if (errors <= 10)
          $display("FAIL CHK-1 phase %0d stage %0s ch %0d: acc %0d -> out %0d, saturation of the sum is %0d",
                   phase, st, ch, a, y, sat16(a));
      end
    end
  endtask

  task automatic chk2(input [8*8-1:0] st, input signed [15:0] yl, input signed [15:0] yr);
    begin
      if (sign_on && inband >= SETTLE && (yl < 0 || yr > 0)) begin
        errors = errors + 1;
        e2 = e2 + 1;
        if (errors <= 10)
          $display("FAIL CHK-2 phase %0d %0s: input inside the band of one sign gave out %0d/%0d",
                   phase, st, yl, yr);
      end
    end
  endtask

  localparam signed [33:0] POSLIM = 34'sd4294967295;    //  2^32 - 1
  localparam signed [33:0] NEGLIM = -34'sd4294967296;   // -2^32

  always @(posedge clk) begin
    if (b_done) begin
      chk1("B", 0, b_acc_l, b_l);
      chk1("B", 1, b_acc_r, b_r);
      chk2("B", b_l, b_r);
      if (b_acc_l > POSLIM || b_acc_r > POSLIM) begin b_pos = b_pos + 1; if (phase == 2) disc_b = disc_b + 1; end
      if (b_acc_l < NEGLIM || b_acc_r < NEGLIM) b_neg = b_neg + 1;
    end
    if (c_done) begin
      chk1("C", 0, c_acc_l, c_l);
      chk1("C", 1, c_acc_r, c_r);
      chk2("C", c_l, c_r);
      if (c_acc_l > POSLIM || c_acc_r > POSLIM) begin c_pos = c_pos + 1; if (phase == 2) disc_c = disc_c + 1; end
      if (c_acc_l < NEGLIM || c_acc_r < NEGLIM) c_neg = c_neg + 1;
    end
    chk2("AUDIO", out_l, out_r);
  end

  // One mixer strobe per 10 clk, as z486_mister.sv's audio_volume_valid; the right channel is
  // the left negated (-32768 for a left -32768 is out of range, so it saturates to +32767).
  task automatic strobe(input signed [15:0] l);
    begin
      repeat (9) @(posedge clk);
      in_l  <= l;
      in_r  <= (l == 16'sh8000) ? 16'sh7FFF : -l;
      valid <= 1'b1;
      if (l >= FLOOR) inband = inband + 1; else inband = 0;
      @(posedge clk);
      valid <= 1'b0;
    end
  endtask

  // A 44.1 kHz disc-rate sequence on the 2.4576 MHz grid: a phase accumulator advancing
  // 44 100 per strobe and wrapping at 2 457 600, as the CD-DA source steps its sample.
  integer nco = 0, si = 0, k = 0, rep = 0;
  function automatic integer seq(input integer i);
    begin
      if (i < RAMP)              seq = FLOOR + ((DISC[0] - FLOOR) * i) / RAMP;
      else if (i < RAMP + NDISC) seq = DISC[i - RAMP];
      else if (i < 2*RAMP + NDISC) seq = DISC[NDISC-1] + ((FLOOR - DISC[NDISC-1]) * (i - RAMP - NDISC)) / RAMP;
      else                       seq = FLOOR;
    end
  endfunction

  initial begin
    // Phase 1: a full-scale square, -32768 <-> +32767, 1229 strobes per half period (1 kHz).
    phase = 1;
    for (rep = 0; rep < 16; rep = rep + 1)
      for (k = 0; k < 1229; k = k + 1) strobe(rep[0] ? 16'sh8000 : 16'sh7FFF);

    // Settle inside the band, then arm CHK-2.
    phase = 2;
    for (k = 0; k < SETTLE + 2000; k = k + 1) strobe(16'(FLOOR));
    sign_on = 1;
    // Phase 2: the disc plateau, at three 44.1/48 kHz phase offsets.
    for (rep = 0; rep < 3; rep = rep + 1) begin
      nco = (rep * 2457600) / 3;
      si  = 0;
      while (si < 2*RAMP + NDISC + 40) begin
        strobe(16'(seq(si)));
        nco = nco + 44100;
        if (nco >= 2457600) begin nco = nco - 2457600; si = si + 1; end
      end
    end

    // Phase 3: a half-to-full-scale square, +16384 <-> +32767, still inside the band.
    phase = 3;
    for (rep = 0; rep < 16; rep = rep + 1)
      for (k = 0; k < 1229; k = k + 1) strobe(rep[0] ? 16'(FLOOR) : 16'sh7FFF);
    for (k = 0; k < 2000; k = k + 1) strobe(16'(FLOOR));

    $display("overflows: B +%0d -%0d, C +%0d -%0d; disc plateau B +%0d C +%0d; CHK-1 offences %0d, CHK-2 offences %0d",
             b_pos, b_neg, c_pos, c_neg, disc_b, disc_c, e1, e2);
    if (b_pos == 0 || b_neg == 0 || c_pos == 0 || c_neg == 0) begin
      errors = errors + 1;
      $display("FAIL CHK-3 an overflow direction was never reached at stage B or C");
    end
    if (disc_b == 0 || disc_c == 0) begin
      errors = errors + 1;
      $display("FAIL CHK-3 the disc plateau did not overflow stage B and stage C");
    end
    if (errors == 0) begin
      $display("TB_PC9821_AUDIO_OUT_SAT: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_AUDIO_OUT_SAT: FAIL (%0d errors)", errors);
  end

  initial begin
    #(10 * 10 * 200000);
    $fatal(1, "TB_PC9821_AUDIO_OUT_SAT: TIMEOUT");
  end
endmodule

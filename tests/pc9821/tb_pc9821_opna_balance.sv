`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The SSG-vs-drums BALANCE at the -86 board's sum, the one gain stage the die cannot speak for (the die stops at its pins: the SSG leaves on analog pin 27 as `o_analog = volume_lut[vol_a/b/c]`, fmopna_impl.c:2438-2441, while FM+ADPCM leave as the YM3016 DAC word, so the ratio between the two paths is the BOARD's analog trim). The real machine is the authority and the PAIRED SNDTEST captures settle it: the WITHIN-SIDE ratio SSG(max)/FM(max), measured on each segment's own steady-state plateau, reads XE10+PMD -8.79 dB, XE10 no-PMD -8.79 dB and this core -3.03 dB (SEG 07 over SEG 01; tools/sndtest_balance.py, output docs/probes/SNDTEST-balance-2026-09-25.txt), and the frequency sweeps' own pairing in the same files agrees to 0.05 dB. So 5.76 dB of SSG leg was hot and the join became psg * 33/16 = the psg << 2 baseline (PC88MiSTer.vhd:2505-2513 / pc98-opna.c:372) times the measured board trim 33/64 (pc9821_opna.sv's SSG_JOIN_NUM/SSG_JOIN_SHIFT). tb_pc9821_opna_sndtest_balance is the RATIO's fail-first, replaying exactly those two SEG 07/SEG 01 register programs; THIS bench keeps the same join's invariant side against the die's drum law: one max channel joins at (1023 * 33) >> 4 = 2109 unipolar, AC-COUPLES zero-mean to ~+-1054.5 with the analytic droop peak ~1075 (C7C1 law declared by tb_pc9821_opna_ssg_level), pinned in the band +-1040..+-1110 (analytic peak +-3%). CHK-4 pins the balance ratio against the die's per-drum maximum 15,352 (((2047<<4)*15)>>5 & ~3; fmopna_impl.c:2681/:2745/:5364-5366 == ymfm_adpcm.cpp:223-243): SSG_ch:drum_max amplitude ratio x10000 in 1354..1446 (= -17.38..-16.79 dB, derived from the same peak band as CHK-2). No die-exact value moves: the drum-hit/program-bed balance still matches the machine to 0.0 +/- 0.3 dB paired.
//
// The SSG-vs-drums BALANCE at the -86 board's sum, i.e. the one gain stage the
// die cannot speak for (the die stops at its pins: the SSG leaves on the analog
// pin 27 as `o_analog = volume_lut[vol_a/b/c]`, fmopna_impl.c:2438-2441, while
// FM+ADPCM leave as the YM3016 DAC word - the ratio between those two paths is
// the BOARD's analog trim). The real-machine recordings are the authority for
// that trim, and the PAIRED SNDTEST captures settle it: the WITHIN-SIDE
// ratio SSG(max)/FM(max) - measured on each segment's own steady-state plateau -
// reads XE10+PMD -8.79 dB, XE10 no-PMD -8.79 dB and THIS CORE -3.03 dB (SEG 07
// over SEG 01; tools/sndtest_balance.py, output
// docs/probes/SNDTEST-balance-2026-09-25.txt), and the frequency sweeps' own
// pairing in the same files agrees to 0.05 dB. So 5.76 dB of SSG leg was hot and
// the join became the psg<<2 baseline times the measured board trim 33/64
// (pc9821_opna.sv's SSG_JOIN_NUM/SSG_JOIN_SHIFT).
// tb_pc9821_opna_sndtest_balance is the fail-first for that RATIO, replaying
// exactly those two SNDTEST segments; THIS bench keeps the invariant side of the
// same join, characterized against the die's drum law:
//
//   a drum-balance analysis of a recording of the real NEC Xe10 vs a recording
//   of this core (the recordings are not committed):
//   * the drum-hit/program-bed balance matches the machine to 0.0 +/- 0.3 dB
//     paired (per class: BD +0.00, SD/TOM -0.03) - the die-exact drum/FM side
//     needs no trim, and this bench does not trim it.
//   * the SSG-vs-drum ratio moves with the SSG leg by the same 5.76 dB. Nothing
//     here re-baselines the die's drum law, and the drum-hit/program-bed check
//     below is unchanged by the trim.
//
// ---- where every expected number comes from (never this repo's RTL) ----
// [per-channel unit] jt49_exp.v's LUT peaks at 1023 for a level-15 channel
//     (upstream-identical file; die table top is 1.0, fmopna_impl.c:2430-2436).
// [the join] psg * 33/16 = (psg << 2) * 33/64: upstream PC-88's board-mix
//     BASELINE psg << 2 (PC88MiSTer.vhd:2505 `psg_snd => sndPSG(13 downto 2)`,
//     :2509-2513) times the -86 board's SSG:FM summing ratio, MEASURED from the
//     paired SNDTEST captures (the within-side SSG(max)/FM(max) is XE10+PMD
//     -8.79 dB, XE10 no-PMD -8.79 dB, this core -3.03 dB before the trim;
//     tb_pc9821_opna_sndtest_balance is its fail-first). qemu's closed ratio
//     agrees on the baseline: SSG_ch:FM_op = 8,160:8,192 over our FM op
//     +/-4,096 (pc98-opna.c:372 `PSG_calc << 1` vs emu2149 `voltbl<<4`; die op
//     unit `(op & 0x1fff) >> 1`, fmopna_impl.c:5347) -> 4,080/ch. One max
//     channel at the join is (1023 * 33) >> 4 = 2,109 unipolar.
// [the coupling cap + droop - ANALYTIC, not measured from our RTL] the SSG
//     joins AC-coupled (C7C1 1-pole high-pass y[n]=x[n]-x[n-1]+a*y[n-1],
//     a=1-2^-14 at 499.2 kHz, the law tb_pc9821_opna_ssg_level declares):
//     a 0..A square's steady-state peak is A/(1+a^640) (half period 640 SSG
//     samples at tone period 0x140), so 2109/1.9617 ~= 1075. The BAND is that
//     peak with +-3% tolerance - start-up residual e^-5 after the 5-tau
//     settle, the exp() truncation in a^640, peak-sample landing - giving
//     peak in [1040,1110].
// [the die's drum law, the other arm of the ratio] one maxed drum puts
//     +15,352 into the junction: die `tl = (((rss_params & 0x1f) | 0x20) +
//     rss_tl_l + 1) ^ 63` (:2681), `rss_sample_shift` (:2745), `<< 2` tail
//     (:5364-5366), i.e. (((2047<<4)*15)>>5) & ~3 == ymfm
//     adpcm_a_channel::output (ymfm_adpcm.cpp:223-243). The BALANCE this
//     bench pins is therefore SSG_ch : die-drum-max = 2,109 : 15,352 =
//     20*log10 0.13738 = -17.24 dB at full register scale; in the peak form
//     (2*peak) the analytic centre is 1400 x10000 = -17.08 dB and the band is
//     x10000 1354..1446 (-17.38..-16.79 dB), DERIVED from the same peak band
//     as CHK-2 (2*REF_CH_LO..2*REF_CH_HI), so CHK-2 and CHK-4 accept and
//     reject identically. (Earlier miscomputed figures of -9.08 and
//     -11.47 dB were corrected.)
// [deliberately NOT expected sources] ymfm's s_amplitudes[31]=16,382/ch
//     (rung 5, and its MixTo1 2/3 is a software mix knob; its per-channel
//     0.333-of-rail weight is 6.4-7.5 dB above the machine's measured
//     0.14-0.16, 20*log10(0.333/0.14..0.16))
//     and NP2kai's vol_ssg absolutes (demoted by the evidence ranking:
//     upstream PC-88 is the FM/SSG baseline over NP2kai, and the REAL MACHINE
//     captures outrank both for the board-level trim).
//
// ---- checks (the join's characterization + the die invariants) ------------
// CHK-1 non-vacuous silence: nothing programmed -> exactly 0.
// CHK-2 one max SSG channel is zero-mean and peaks inside the band
//       +-1040..+-1110 (analytic centre +-1075) - the join + droop law.
// CHK-3 three max channels stay linear in the count: peak in 3x the
//       one-channel band (the join is a pure gain, no count compression).
// CHK-4 the BALANCE RATIO against the die's drum law (the invariant anchor):
//       (2*peak)*10000/15352 must land in 1354..1446 (-17.38..-16.79 dB) -
//       the band DERIVED from CHK-2's peak band so the two cannot disagree.
//       The invariants verified at both trim scales hold here too:
//       zero-mean DC block, die drum max 15,352, and the overflow bounds
//       (join 0..6,329 inside the 18-bit signed DC-block path).
//
// ==== DUT ====
// pc9821_opna at its own host port (the wrapper's board mix is the unit under
// test: the join scale lives there, and the die stops at the pins).

module tb_pc9821_opna_balance;
  localparam integer SYS_CLOCK_HZ = 50_000_000;
  reg clk = 0;
  always #10 clk = ~clk;

  reg        reset = 1;
  reg [15:0] io_addr = 16'h0188;
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_din = 8'h00;
  wire [7:0] io_dout;
  wire       io_rd_wait, irq;
  wire signed [19:0] snd_l, snd_r;
  reg  [5:0] joystick = 6'b111111;

  pc9821_opna #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd),
    .io_din(io_din), .io_dout(io_dout), .io_rd_wait(io_rd_wait),
    .extend(1'b0),
    .joystick(joystick),
    .snd_l(snd_l), .snd_r(snd_r),
    .irq(irq),
    .rhythm_we(1'b0), .rhythm_waddr(12'd0), .rhythm_wdata(16'd0)
  );

  integer errors = 0;

  // ==== CHECKS ====
  task automatic fail(input [8*170-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // The same host-port write the games use (rec98 master.lib soundio.asm:52-56),
  // spaced like tb_pc9821_opna_ssg_level (the board write queue's drain).
  task automatic sound_o(input [7:0] reg_index, input [7:0] data);
    begin
      @(negedge clk); io_addr = 16'h0188; io_din = reg_index; io_wr = 1'b1;
      @(negedge clk); io_wr = 1'b0; io_din = 8'h00;
      repeat (3200) @(posedge clk);
      @(negedge clk); io_addr = 16'h018A; io_din = data; io_wr = 1'b1;
      @(negedge clk); io_wr = 1'b0; io_din = 8'h00;
      repeat (3200) @(posedge clk);
    end
  endtask

  task automatic run_cen(input integer ncens);
    integer cnt;
    begin
      cnt = 0;
      while (cnt < ncens) begin
        @(posedge clk);
        if (dut.cen) cnt = cnt + 1;
      end
    end
  endtask

  task automatic measure_cen(input integer ncens, output integer vmax, output integer vmin,
                             output integer vsum);
    integer cnt;
    begin
      vmax = -1_000_000; vmin = 1_000_000; vsum = 0; cnt = 0;
      while (cnt < ncens) begin
        @(posedge clk);
        if (dut.cen) begin
          cnt  = cnt + 1;
          vsum = vsum + snd_l;
          if (snd_l > vmax) vmax = snd_l;
          if (snd_l < vmin) vmin = snd_l;
        end
      end
    end
  endtask

  // The reference values (header derivations). One max channel joins at
  // (1023 * 33) >> 4 = 2109 unipolar; the coupling cap centres it at 1054.5 and
  // the analytic droop A/(1+a^640), a = 1-2^-14, peaks it at ~1075. The BAND is
  // that peak with +-3% tolerance (start-up residual e^-5 after the 5-tau
  // settle, exp() truncation in a^640, peak-sample landing): [1040,1110].
  // DIE_DRUM_MAX is the die's per-drum junction maximum (((2047<<4)*15)>>5 &
  // ~3; fmopna_impl.c:2681/:2745/:5364-5366 == ymfm_adpcm.cpp:223-243).
  localparam integer REF_CH        = 1054;      // ((1023 * 33) >> 4)/2, zero-mean half
  localparam integer REF_PEAK      = 1075;      // analytic: 2109/(1+a^640)
  localparam integer REF_CH_LO     = 1040;      // analytic peak -3%, rounded out
  localparam integer REF_CH_HI     = 1110;      // analytic peak +3%, rounded out
  localparam integer REF_THREE     = 3162;      // 3 * REF_CH
  localparam integer REF_THREE_LO  = 3 * REF_CH_LO;   // 3120
  localparam integer REF_THREE_HI  = 3 * REF_CH_HI;   // 3330
  localparam integer DIE_DRUM_MAX  = 15352;
  // Balance ratio (2*peak)*10000/DIE_DRUM_MAX: analytic centre 1400
  // (-17.08 dB); the band is DERIVED from the CHK-2 peak band
  // (2*REF_CH_LO..2*REF_CH_HI): 1354..1446 = -17.38..-16.79 dB, so CHK-2 and
  // CHK-4 accept and reject identically.
  localparam integer BAL_X10000_LO = 1354;
  localparam integer BAL_X10000_HI = 1446;

  localparam integer TONE_PERIOD_CEN = 20480;   // 64 * 320 (period reg 0x140)
  localparam integer SSG_TAU_CEN   = 262144;    // 2^14 SSG samples * 16 cen/sample
  localparam integer SETTLE_CEN    = 5 * SSG_TAU_CEN;
  localparam integer MEASURE_CEN   = 16 * TONE_PERIOD_CEN;

  integer one_max, one_min, one_sum, three_max, three_min, three_sum;
  integer bal_x10000;
  real    observed_db;

  initial begin
    repeat (40) @(posedge clk);
    @(negedge clk); reset = 0;
    repeat (2000) @(posedge clk);

    // ---- CHK-1: silence before any programming ---------------------------
    measure_cen(50_000, one_max, one_min, one_sum);
    if (one_max !== 0 || one_min !== 0)
      fail("the board output is not 0 with nothing programmed: the balance checks would be measuring something else");

    // ---- stimulus: one in-phase square per channel, noise off --------------
    sound_o(8'h07, 8'h38);     // tone A/B/C on, noise off
    sound_o(8'h00, 8'h40);     // A period = 0x140
    sound_o(8'h01, 8'h01);
    sound_o(8'h02, 8'h40);     // B period = 0x140
    sound_o(8'h03, 8'h01);
    sound_o(8'h04, 8'h40);     // C period = 0x140
    sound_o(8'h05, 8'h01);
    sound_o(8'h08, 8'h0F);     // A level 15 (die table top) - ONE channel
    sound_o(8'h09, 8'h00);
    sound_o(8'h0A, 8'h00);

    run_cen(SETTLE_CEN);
    measure_cen(MEASURE_CEN, one_max, one_min, one_sum);

    // ---- CHK-2: one max channel inside the join's band ---------------------
    if (one_sum < -64 * MEASURE_CEN || one_sum > 64 * MEASURE_CEN)
      fail("one max SSG channel is not zero-mean at the mix join (the coupling cap's DC removal)");
    if (one_max < REF_CH_LO || one_max > REF_CH_HI || one_min > -REF_CH_LO || one_min < -REF_CH_HI) begin
      observed_db = 20.0 * $ln((one_max < 1 ? 1.0 : one_max * 1.0) / REF_PEAK) / $ln(10.0);
      $display("FAIL: one max SSG channel peaks %0d..%0d, band +-%0d..+-%0d (centre +-%0d)",
               one_max, one_min, REF_CH_LO, REF_CH_HI, REF_PEAK);
      $display("      observed join is %0.2f dB vs the analytic centre; the band is the psg * 15/8 join's characterization",
               observed_db);
      fail("CHK-2 SSG join is outside the characterization band (psg * 33/16 = baseline x the measured board trim 33/64)");
    end

    // ---- CHK-3: three max channels, linear in the count -------------------
    sound_o(8'h09, 8'h0F);
    sound_o(8'h0A, 8'h0F);
    run_cen(SETTLE_CEN);
    measure_cen(MEASURE_CEN, three_max, three_min, three_sum);

    if (three_sum < -64 * MEASURE_CEN || three_sum > 64 * MEASURE_CEN)
      fail("three max SSG channels are not zero-mean at the mix join");
    if (three_max < REF_THREE_LO || three_max > REF_THREE_HI)
      fail("CHK-3 three max channels are not 3x the one-channel band: the join is not a pure per-channel gain");

    // ---- CHK-4: the BALANCE RATIO against the die's drum law --------------
    // Amplitude ratio (2*peak) : DIE_DRUM_MAX, scaled x10000 (NOT dB); the dB
    // line next to it is computed, not the ratio mislabelled.
    bal_x10000 = (2 * one_max * 10000) / DIE_DRUM_MAX;
    observed_db = 20.0 * $ln((2.0 * one_max) / DIE_DRUM_MAX) / $ln(10.0);
    $display("  SSG_ch : die-drum-max amplitude ratio = %0d/10000 (%0.2f dB); target band %0d..%0d (-17.38..-16.79 dB)",
             bal_x10000, observed_db, BAL_X10000_LO, BAL_X10000_HI);
    if (bal_x10000 < BAL_X10000_LO || bal_x10000 > BAL_X10000_HI)
      fail("CHK-4 drum-hit level vs SSG level is outside the balance derived from the join (band = the psg * 33/16 characterization)");

    // ==== VERDICT ====
    $display("  one channel: mean=%0d peak=%0d floor=%0d (analytic centre +-%0d, band +-%0d..+-%0d)",
             one_sum / MEASURE_CEN, one_max, one_min, REF_PEAK, REF_CH_LO, REF_CH_HI);
    $display("  three channels: mean=%0d peak=%0d floor=%0d (3x band +-%0d..+-%0d)",
             three_sum / MEASURE_CEN, three_max, three_min, REF_THREE_LO, REF_THREE_HI);
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_BALANCE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_BALANCE: FAIL (%0d errors)", errors);
  end

  initial begin
    #600_000_000;
    $fatal(1, "TB_PC9821_OPNA_BALANCE: TIMEOUT");
  end

endmodule

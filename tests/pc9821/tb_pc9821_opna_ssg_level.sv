`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The SSG joins the -86 card's mix AC-COUPLED (zero-mean), not DC-coupled: the real board takes the YM2608's SSG off pin 27 (a YM2149-style unipolar output carrying a ~2 V DC offset, which jt49 models), passes it through the series coupling capacitor C7C1, and only then sums it equally into the YM3016 FM/DAC L/R (the PC-9801-86 board design). A series cap is a 1-pole high-pass y[n]=x[n]-x[n-1]+a*y[n-1], a=1-2^-14, clocked at the SSG sample rate (499.2 kHz = cen/16). This bench is the fail-first for that DC block: BEFORE the DC block the unipolar term has mean ~= +1054 (one full-scale channel is a 0..2109 square at the join scale) and never goes negative; AFTER the DC block it is zero-mean and peaks near +-2109/2 = +-1054.5. The join scale is psg * 33/16 = (psg << 2) * 33/64 - the upstream PC-88 board mix BASELINE (PC88MiSTer.vhd:2505-2513) times the -86 board's SSG:FM summing ratio, MEASURED from the paired SNDTEST captures on each segment's own steady-state plateau (the within-side SSG(max)/FM(max) is XE10+PMD -8.79 dB, XE10 no-PMD -8.79 dB and this core -3.03 dB before the trim; tb_pc9821_opna_sndtest_balance is that ratio's fail-first, and pc9821_opna.sv's SSG_JOIN_NUM/SSG_JOIN_SHIFT carry the derivation) - and the per-channel unit is jt49_exp.v's LUT peak 1023 (upstream-identical file); the coupling cap's analytic droop (2109/(1+a^640) ~= 1075, period register 0x140 -> half period 640 SSG samples) lands in the checks' band +-1040..+-1110 (analytic peak +-3%). ymfm's s_amplitudes and NP2kai's vol_ssg absolutes are deliberately unused (their FM operator units do not close; NP2kai's absolute SSG path is demoted below the captures).
//
// The SSG joins the -86 card's mix AC-COUPLED (zero-mean), not DC-coupled: the
// real board takes the YM2608's SSG off pin 27 - a YM2149-style unipolar output
// carrying a ~2 V DC offset, which jt49 models - and passes it through the series
// coupling capacitor C7C1 BEFORE summing it equally into the YM3016 FM/DAC L/R
// (the PC-9801-86 board design). A series cap is a 1-pole high-pass:
//
//     y[n] = x[n] - x[n-1] + a*y[n-1],  a = 1 - 2^-14
//
// clocked at the SSG sample rate (499.2 kHz = 7.9872 MHz / 16). This bench is the
// fail-first for that DC block: BEFORE the DC block the unipolar term has mean
// ~= +1054 (a full-scale channel's square wave is 0..2109 at the join scale) and
// never goes negative; AFTER the DC block the same square wave is zero-mean with
// peak ~= +-2109/2 = +-1054.5 (the coupling cap removes the DC, so a symmetric
// square wave becomes centred at half its unipolar peak).
//
// ---- the bench's own account of where every expected number comes from ----
// [the join scale] psg * 33/16 = (psg << 2) * 33/64: upstream PC-88's board-mix
//     BASELINE at psg << 2 (PC88MiSTer.vhd:2505 `psg_snd => sndPSG(13 downto 2)`
//     with :2509-2513 `sndPSG(15:14)<="00"; sndPSG(1:0)<="00"; sndL <= sndFML +
//     sndPSG`; jt12_top.v's own combined output says << 3, but it is UNUSED
//     upstream, wraps at 16 bits, and PC88's board mix overrides it) TIMES the
//     -86 board's SSG:FM summing ratio, MEASURED from the paired SNDTEST
//     captures on each segment's own steady-state plateau. The within-side ratio
//     SSG(max)/FM(max) is XE10+PMD -8.79 dB, XE10 no-PMD -8.79 dB and this core
//     -3.03 dB (SEG 07 over SEG 01; tools/sndtest_balance.py, output
//     docs/probes/SNDTEST-balance-2026-09-25.txt), and the frequency sweeps' own
//     pairing in the same files agrees to 0.05 dB. So 5.76 dB of SSG leg was
//     hot; 33/16 = 2.0625 is -5.756 dB off the baseline and is what
//     pc9821_opna.sv's SSG_JOIN_NUM/SSG_JOIN_SHIFT carry, with the derivation
//     and citations next to them. tb_pc9821_opna_sndtest_balance is the
//     fail-first for the RATIO; this bench characterizes the JOIN SCALE that
//     ratio is built on.
// [the per-channel unit] jt49_exp.v's LUT (upstream-identical file) peaks at
//     1023 for a max-level channel (comp=0, din=31), so one channel at the join
//     scale is (1023 * 33) >> 4 = 2109 unipolar.
// [the coupling cap] a series capacitor has zero DC gain: a 50%-duty square wave
//     that is 0..2109 unipolar becomes a zero-mean square centred on its mean, i.e.
//     +-(2109/2) = +-1054.5. The 1-pole high-pass adds the expected droop: with the
//     SSG sample rate 499.2 kHz and a = 1-2^-14 (fc = fs*2^-14/2pi ~= 4.85 Hz, the
//     exact -86 cap value being unpublished), a tone whose half period is 640 SSG
//     samples (period register 0x140 = 320; jt49_div toggles every period cen16,
//     and cen16 = cen/32) peaks at 2109/(1 + a^640) ~= 1075 - the coupling-cap
//     droop, not a new scale. The zero-mean and sign facts are the assertions; the
//     peak is pinned to the band +-1040..+-1110 = the analytic droop peak with
//     +-3% tolerance (start-up residual e^-5 after the 5-tau settle, the exp()
//     truncation in a^640, peak-sample landing).
// [what is deliberately NOT used] ymfm's s_amplitudes[31]=16382/ch absolute
//     (its FM operator unit at the rshift=1 output does not close) and NP2kai's
//     vol_ssg absolutes (48*vol_ssg = 6144 bipolar; its absolute SSG gain path
//     is demoted per the evidence ranking).
//
// ---- checks ----
// CHK-1 the stimulus is not vacuous: with every level at 0 the board output is
//       EXACTLY 0 (no FM is programmed, so the SSG is the only contributor).
// CHK-2 one channel at level 15 is ZERO-MEAN at the mix join (|mean| <= 64 over
//       whole tone periods) and peaks near +-2109/2 = +-1054.5 (droop ~1075) -
//       it goes NEGATIVE. The pre-DC-block unipolar term fails all three
//       (mean ~= +1054, peak 2109, floor 0 at the join scale).
// CHK-3 three in-phase channels at level 15 are ZERO-MEAN and peak near
//       3 * 1054 = +-3162 (the per-channel unit is not scaled by the count).
//
// ==== DUT ====
// pc9821_opna at its own host port, as every board-level opna bench drives it (the
// I/O-bus routing is tb_pc9821_opna's). NOT the chip alone: the level under test is
// the WRAPPER's mix (the AC-COUPLED join-scale SSG term - psg * 33/16) against the chip's own 10-bit table.

module tb_pc9821_opna_ssg_level;
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
  task automatic fail(input [8*150-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // The games' own register write (rec98 libs/master.lib/soundio.asm:52-56), with the
  // WRQ spacing tb_pc9821_sound_sum uses: the board's buffer delivers a write every
  // 216 cen for FM-class registers, so a host burst faster than that would fill it.
  // SSG writes take the short path, but the spacing is kept uniform here.
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

  // Run the clock for a number of the chip's 7.9872 MHz enables (`cen`), so a
  // settle/measure window is an exact count of the chip's own time base rather
  // than a non-integer number of DDS periods.
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

  // Peak/max, floor/min and sum over an exact number of `cen` pulses, sampled once
  // per cen (snd_l is constant between SSG samples, which are 16 cen apart, so a
  // once-per-cen sample is uniform and whole-tone-period sums are exact).
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

  // The reference values and windowing, named once so every check below reads the
  // same numbers. jt49_exp.v's LUT peak 1023/ch (upstream-identical file) x the
  // SSG join psg * 33/16 (the PC88 board baseline psg << 2 times the measured
  // board trim; pc9821_opna.sv's SSG_JOIN_NUM/SSG_JOIN_SHIFT carry it with its
  // derivation) = 2109
  // unipolar per channel; the
  // coupling cap centres that at (1023 * 33) >> 4 / 2 = 1054.5. The tone period register 0x140 = 320
  // gives a full square-wave period of 64*320 = 20480 cen (jt49_div toggles every
  // period cen16, cen16 = cen/32 - see the header), and the 1-pole pole 2^-14 has a
  // 16384-SSG-sample time constant (5 tau below drives the start-up DC step down to
  // < 1% of a full-scale channel).
  localparam integer REF_CH        = 1054;      // ((1023 * 33) >> 4) / 2, zero-mean
  localparam integer REF_THREE     = 3162;      // 3 * REF_CH
  localparam integer REF_PEAK      = 1075;      // analytic: 2109/(1 + a^640)
  localparam integer REF_PEAK_LO   = 1040;      // analytic peak -3%, rounded out
  localparam integer REF_PEAK_HI   = 1110;      // analytic peak +3%, rounded out
  localparam integer REF_THREE_LO  = 3 * REF_PEAK_LO;   // 3120
  localparam integer REF_THREE_HI  = 3 * REF_PEAK_HI;   // 3330
  localparam integer TONE_PERIOD_CEN = 20480;   // 64 * 320 (period reg 0x140)
  localparam integer SSG_TAU_CEN   = 262144;    // 2^14 SSG samples * 16 cen/sample
  localparam integer SETTLE_CEN    = 5 * SSG_TAU_CEN;
  localparam integer MEASURE_CEN   = 16 * TONE_PERIOD_CEN;

  integer one_max, one_min, one_sum, three_max, three_min, three_sum;

  initial begin
    repeat (40) @(posedge clk);
    @(negedge clk); reset = 0;
    repeat (2000) @(posedge clk);    // the glue's reset stretcher, 16 clk&cen

    // ---- CHK-1: silence before any SSG programming ------------------------
    // Nothing has been keyed: no FM, no rhythm ROM image is loaded (rhythm_we is tied
    // off, and the ROM reads as zeros), so the board output must be EXACTLY zero.
    measure_cen(50_000, one_max, one_min, one_sum);
    if (one_max !== 0 || one_min !== 0)
      fail("the board output is not 0 with nothing programmed: the level checks below would be measuring something else");

    // ---- the stimulus: tones only (0x38 = all three noise sources disabled, the
    //      same mixer tb_pc9821_sound_sum's ssg_max uses), one shared period so the
    //      three channels stay in phase and their sum reaches its true peak ------
    sound_o(8'h07, 8'h38);     // tone A/B/C on, noise off
    sound_o(8'h00, 8'h40);     // A period = 0x140
    sound_o(8'h01, 8'h01);
    sound_o(8'h02, 8'h40);     // B period = 0x140
    sound_o(8'h03, 8'h01);
    sound_o(8'h04, 8'h40);     // C period = 0x140
    sound_o(8'h05, 8'h01);
    sound_o(8'h08, 8'h0F);     // A level 15, no envelope  <- ONE channel at max
    sound_o(8'h09, 8'h00);
    sound_o(8'h0A, 8'h00);

    run_cen(SETTLE_CEN);       // let the DC-blocker's start-up transient die out
    measure_cen(MEASURE_CEN, one_max, one_min, one_sum);

    // ---- CHK-2: one channel at max is zero-mean at the mix join ------------
    // The coupling cap removes the 0..2109 square's DC (mean 1054.5), so the
    // join is centred on 0 and peaks at half the unipolar peak (2109/2, with
    // the 1-pole droop taking it to ~1075). The pre-DC-block unipolar term fails
    // here: mean ~= +1054, peak 2109, floor 0 (never negative).
    if (one_sum < -64 * MEASURE_CEN || one_sum > 64 * MEASURE_CEN)
      fail("one max SSG channel is not zero-mean at the mix join: the DC-coupled (unipolar) term is still present");
    if (one_max < REF_PEAK_LO || one_max > REF_PEAK_HI)
      fail("one max SSG channel peak is outside +-1040..+-1110 (the join scale's characterization; centre ~1075)");
    if (one_min > -REF_PEAK_LO || one_min < -REF_PEAK_HI)
      fail("one max SSG channel does not swing negative into -1040..-1110");

    // ---- CHK-3: three channels at max are zero-mean and ~3x one ------------
    sound_o(8'h09, 8'h0F);
    sound_o(8'h0A, 8'h0F);
    run_cen(SETTLE_CEN);
    measure_cen(MEASURE_CEN, three_max, three_min, three_sum);

    if (three_sum < -64 * MEASURE_CEN || three_sum > 64 * MEASURE_CEN)
      fail("three max SSG channels are not zero-mean at the mix join");
    if (three_max < REF_THREE_LO || three_max > REF_THREE_HI)
      fail("three max SSG channels do not peak near 3*1054 = +3162 within the 3x band");
    if (three_min > -REF_THREE_LO || three_min < -REF_THREE_HI)
      fail("three max SSG channels do not swing negative into the 3x band");

    // ==== VERDICT ====
    $display("  SSG level: one channel mean=%0d peak=%0d floor=%0d (expected mean 0, peak/floor ~= +/-%0d)",
             one_sum / MEASURE_CEN, one_max, one_min, REF_CH);
    $display("             three channels mean=%0d peak=%0d floor=%0d (expected mean 0, peak/floor ~= +/-%0d)",
             three_sum / MEASURE_CEN, three_max, three_min, REF_THREE);
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_SSG_LEVEL: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_SSG_LEVEL: FAIL (%0d errors)", errors);
  end

  initial begin
    #600_000_000;
    $fatal(1, "TB_PC9821_OPNA_SSG_LEVEL: TIMEOUT");
  end

endmodule

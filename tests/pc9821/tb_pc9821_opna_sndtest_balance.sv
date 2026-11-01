`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The SSG-vs-FM level BALANCE at the -86 board's sum against the PAIRED SNDTEST captures - the fail-first for the measured board trim (the die stops at its pins: the SSG leaves on the analog pin 27 as `o_analog = volume_lut[vol_a/b/c]`, fmopna_impl.c:2438-2441, while FM+ADPCM leave as the YM3016 DAC word, so the two paths' ratio is the BOARD's analog summing network and is in no chip model). The WITHIN-SIDE ratio SSG(max)/FM(max) is immune to the two recorders' unrelated gains; measured on each segment's own STEADY-STATE plateau (tools/sndtest_balance.py, output docs/probes/SNDTEST-balance-2026-09-25.txt; an earlier transcript-timed aligner's windows are SUPERSEDED: they were off by one segment) it is XE10+PMD -8.79 dB, XE10 no-PMD -8.79 dB, and this core -3.03 dB, with the frequency sweeps' own SSG/FM pairing in the same files agreeing to 0.05 dB - so 5.76 dB of SSG leg was hot and the JOIN is the psg<<2 baseline times the measured board trim 33/64 (pc9821_opna.sv's SSG_JOIN_NUM/SSG_JOIN_SHIFT). The bench replays SEG 01's FM register program (one sine at TL 0x00, 440.104 Hz) and SEG 07's SSG program (one tone at volume 15, 439.437 Hz) verbatim, measures each leg's steady RMS at the board output, and requires the amplitude ratio x10000 to land in 3239..4077 (-9.79..-7.79 dB) around the capture's -8.79 dB; it also checks the board is silent unprogrammed, that the FM arm really swings (not a drift), and that the FM release is finished before the SSG arm is measured so the residual cannot inflate the ratio. The machine's own SSG sweep is flat within 0.35 dB from 100 Hz to 4 kHz and its FM sweep within 0.1 dB to 2 kHz, its SSG square arrives with its 3rd harmonic at -9.5 dB (the ideal -9.54), and the FM at 440 Hz is a sine below 1 kHz, so the analog capture chain cannot have materially distorted the ratio.
//
// The banner line above is the manifest claim VERBATIM - ONE line, because
// tools/check_tests.py compares the two with whitespace collapsed and treats the
// per-line `//` as literal text (tb_pc9821_gvram_decouple.sv is the exemplar).
//
// WHY THE EXPECTED NUMBER COMES FROM tools/sndtest_balance.py AND NOT FROM
// a transcript-timed aligner (retired). The aligner's per-segment WINDOW is not a gain window:
// `dur_ms` is the whole segment slot, hold plus the 0.5 s of written silence that
// closes it (the transcript's own ENDSEG note: "the delta covers the hold PLUS the
// 0.5 s of written silence that closes it: a 1.500 s hold reads ~614400 ticks, not
// 460800"), so a window-RMS mixes signal with silence and reads LOW by a different
// amount per segment. On top of that the aligner's anchor - "the program's first
// significant sound" - is SEG 01's FM tone and not SEG 00's start marker, because
// sndtest.s leaves `sg_vol` at its `.byte 0` initializer: `sec_marker` (called
// first) never writes it, the first write is in `sec_ssg_vol`, so the MARK's
// "double beep at 2971.4 Hz, vol=15" is written out as SSG channel A level 0 and
// never sounds. Measured: the 2971.4 Hz band never exceeds -60 dBFS in the first
// 12 s of ANY of the three recordings, and the XE10's SEG 01 window (5.78-7.62 s)
// lands entirely inside the real SEG 02 plateau (6.26-7.76 s). Both mechanisms
// read the first cut's machine ratio as -9.70 dB instead of -8.79.
//
// This bench's own module-side measurement is the cross-check that settles it: with
// the OLD join it reads -2.99 dB, against the corrected capture's -3.03 for this
// core - i.e. the capture and the RTL agree to 0.04 dB on this side, where the
// superseded table claimed -3.20.

// ==== DUT ====
// pc9821_opna at its own host port: the wrapper's board mix is the unit under
// test (the join scale lives there, and the die stops at the pins).

// ==== STIMULUS ====
// SNDTEST SEG 01's and SEG 07's register programs, replayed write for write from
// docs/probes/SNDTEST-xe10.TXT, with the probe's own `fm_on`/`ssg_on` last so the
// key-on and the mixer enable hold. Each leg is given its own settle and measured
// over a whole number of the chip's 7.9872 MHz enables.

// ==== CHECKS ====
// CHK-1 non-vacuous silence: nothing programmed -> exactly 0.
// CHK-2 the FM arm is alive: the keyed FM channel swings both ways and its RMS
//       is a real tone, not a drift (the block-0 trap tb_pc9821_opna names).
// CHK-3 the FM release is complete before the SSG arm is measured, so the
//       residual FM cannot inflate the ratio.
// CHK-4 THE RATIO: SSG(max) RMS / FM(max) RMS, amplitude ratio x10000, must
//       land in 3239..4077 (-9.79..-7.79 dB) around the capture's -8.79 dB.

// ==== VERDICT ====
// PASS iff CHK-1..CHK-4 all hold; the four checks are reported with their measured
// values first so a failure is attributable without re-running.

module tb_pc9821_opna_sndtest_balance;
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

  task automatic fail(input [8*200-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // The games' host-port write (rec98 libs/master.lib/soundio.asm:52 (WAITREADY macro)
  // is the board's ready poll; the select-then-data pair below is the same strobe),
  // spaced like
  // tb_pc9821_opna_ssg_level so the board write queue's drain is not the test.
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

  // Steady RMS of the board output (what SNDTEST's segments are measured with:
  // per-segment RMS in dBFS).
  real    sumsq;
  reg signed [63:0] sq;    // the 64-bit product context (see the note below)
  integer cnt;
  integer swing_lo, swing_hi;
  // sq is assigned through a 64-bit LHS on purpose: a bare `snd_l * snd_l`
  // reaches the real accumulator at the operands' own 20-bit width and wraps
  // (that produced a NaN RMS the first time this bench ran), so the product is
  // taken in a 64-bit context first. 100 ms is 798,720 samples of at most
  // 2^26, i.e. 1.3e13 - far inside the 64-bit range.
  task automatic measure_rms(input integer ncens, output real rms);
    begin
      sumsq = 0.0; cnt = 0;
      swing_lo = 1_000_000; swing_hi = -1_000_000;
      while (cnt < ncens) begin
        @(posedge clk);
        if (dut.cen) begin
          cnt   = cnt + 1;
          sq    = snd_l * snd_l;
          sumsq = sumsq + sq;
          if (snd_l < swing_lo) swing_lo = snd_l;
          if (snd_l > swing_hi) swing_hi = snd_l;
        end
      end
      rms = $sqrt(sumsq / cnt);
    end
  endtask

  task automatic measure_peak(input integer ncens, output integer vabsmax);
    begin
      cnt = 0; vabsmax = 0;
      while (cnt < ncens) begin
        @(posedge clk);
        if (dut.cen) begin
          cnt = cnt + 1;
          if (snd_l > vabsmax) vabsmax = snd_l;
          if (-snd_l > vabsmax) vabsmax = -snd_l;
        end
      end
    end
  endtask

  // The capture target: both machine sessions' SSG(max)/FM(max) = -8.79 dB,
  // band +/-1 dB.
  localparam real    TARGET_DB     = -8.79;
  localparam integer RATIO_X10000_LO = 3239;   // 10^(-9.79/20) x 10000
  localparam integer RATIO_X10000_HI = 4077;   // 10^(-7.79/20) x 10000

  localparam integer FM_SETTLE_CEN    = 798_720;   // 100 ms at the 7.9872 MHz enable
  localparam integer MEASURE_CEN      = 798_720;   // 100 ms -> ~44 tone periods
  localparam integer SSG_TAU_CEN      = 262_144;   // 2^14 SSG samples x 16 cen/sample
  localparam integer SSG_SETTLE_CEN   = 5 * SSG_TAU_CEN;
  localparam integer FM_OFF_SETTLE_CEN = 5 * SSG_TAU_CEN;

  real    fm_rms, ssg_rms, ratio_db, observed_db;
  integer ratio_x10000, fm_absmax, resid_absmax;
  integer fm_lo, fm_hi;

  initial begin
    repeat (40) @(posedge clk);
    @(negedge clk); reset = 0;
    repeat (2000) @(posedge clk);

    // ---- CHK-1: silence before any programming --------------------------
    fm_absmax = 0; measure_peak(50_000, fm_absmax);
    if (fm_absmax !== 0)
      fail("the board output is not 0 with nothing programmed: the ratio checks would be measuring something else");

    // ---- FM arm: SNDTEST SEG 01, verbatim (the transcript's write order),
    //      with the probe's fm_on (0x28 <- 0xF0) last so the key-on holds.
    sound_o(8'h22, 8'h00);   // LFO off
    sound_o(8'h27, 8'h00);   // both timers stopped, flags cleared
    sound_o(8'h28, 8'h00);   // key off before programming
    sound_o(8'h30, 8'h01);   // DT=0, MULTI=1
    sound_o(8'h34, 8'h01);
    sound_o(8'h38, 8'h01);
    sound_o(8'h3C, 8'h01);
    sound_o(8'h40, 8'h00);   // slot 1 TL=0 (atten +0.000 dB, the printed header)
    sound_o(8'h44, 8'h7F);   // slots 2-4 silent
    sound_o(8'h48, 8'h7F);
    sound_o(8'h4C, 8'h7F);
    sound_o(8'h50, 8'h1F);   // AR=31
    sound_o(8'h54, 8'h1F);
    sound_o(8'h58, 8'h1F);
    sound_o(8'h5C, 8'h1F);
    sound_o(8'h60, 8'h00);   // DR=0
    sound_o(8'h64, 8'h00);
    sound_o(8'h68, 8'h00);
    sound_o(8'h6C, 8'h00);
    sound_o(8'h70, 8'h00);   // SR=0
    sound_o(8'h74, 8'h00);
    sound_o(8'h78, 8'h00);
    sound_o(8'h7C, 8'h00);
    sound_o(8'h80, 8'h0F);   // SL=0, RR=15
    sound_o(8'h84, 8'h0F);
    sound_o(8'h88, 8'h0F);
    sound_o(8'h8C, 8'h0F);
    sound_o(8'h90, 8'h00);   // SSG-EG off
    sound_o(8'h94, 8'h00);
    sound_o(8'h98, 8'h00);
    sound_o(8'h9C, 8'h00);
    sound_o(8'hB0, 8'h07);   // FB=0, ALG=7
    sound_o(8'hB4, 8'hC0);   // both outputs on, AMS=PMS=0
    sound_o(8'hA0, 8'h08);   // F-NUM low, then high, then low again
    sound_o(8'hA4, 8'h2A);   // block 5, fnum 0x208 = 440.104 Hz at MULTI 1
    sound_o(8'hA0, 8'h08);
    sound_o(8'h28, 8'hF0);   // key on channel 1, all four slots (the probe's fm_on)

    run_cen(FM_SETTLE_CEN);
    measure_rms(MEASURE_CEN, fm_rms);
    fm_lo = swing_lo; fm_hi = swing_hi;

    // ---- CHK-2: the FM arm is a tone, not a drift -----------------------
    $display("  FM (SEG 01): rms=%0.1f swing %0d..%0d", fm_rms, fm_lo, fm_hi);
    if (fm_rms < 100.0)
      fail("the keyed FM channel is silent: the ratio's FM arm has no level");
    if (fm_lo >= 0 || fm_hi <= 0)
      fail("the keyed FM channel does not swing both ways: it is drifting, not sounding");

    // ---- key the FM off (the probe's fm_off) and let the release finish ---
    sound_o(8'h28, 8'h00);
    run_cen(FM_OFF_SETTLE_CEN);
    resid_absmax = 0; measure_peak(MEASURE_CEN, resid_absmax);
    $display("  FM release residual: max |snd_l| = %0d", resid_absmax);

    // ---- CHK-3: no FM residue can contaminate the SSG arm ---------------
    if (resid_absmax > 64)
      fail("the FM release is not complete before the SSG arm is measured: the ratio's denominators would be inflated");

    // ---- SSG arm: SNDTEST SEG 07, verbatim, ending at the probe's ssg_on
    //      (reg 7 <- 0xBE = tone A enabled, ports as the reset seed 0xBF).
    sound_o(8'h07, 8'hBF);
    sound_o(8'h00, 8'h1C);   // channel A tone period low
    sound_o(8'h01, 8'h01);   // channel A tone period high (TP 0x11C -> 439.437 Hz)
    sound_o(8'h02, 8'h00);   // B period 0, disabled in the mixer
    sound_o(8'h03, 8'h00);
    sound_o(8'h04, 8'h00);   // C period 0, disabled in the mixer
    sound_o(8'h05, 8'h00);
    sound_o(8'h06, 8'h1F);   // noise period (mixer bit 3 clear = noise off)
    sound_o(8'h08, 8'h0F);   // channel A level 15 (the die table top)
    sound_o(8'h09, 8'h00);
    sound_o(8'h0A, 8'h00);
    sound_o(8'h07, 8'hBE);   // tone A into the mixer (the probe's ssg_on)

    run_cen(SSG_SETTLE_CEN);
    measure_rms(MEASURE_CEN, ssg_rms);
    $display("  SSG (SEG 07): rms=%0.1f swing %0d..%0d", ssg_rms, swing_lo, swing_hi);

    // ---- CHK-4: the capture's SSG(max)/FM(max) ratio --------------------
    observed_db = 20.0 * $ln(ssg_rms / fm_rms) / $ln(10.0);
    ratio_x10000 = (ssg_rms * 10000.0 / fm_rms);
    $display("  SSG max : FM max amplitude ratio = %0d/10000 (%0.2f dB); capture target %0.2f dB, band %0d..%0d (-9.79..-7.79 dB)",
             ratio_x10000, observed_db, TARGET_DB, RATIO_X10000_LO, RATIO_X10000_HI);
    if (ratio_x10000 < RATIO_X10000_LO || ratio_x10000 > RATIO_X10000_HI)
      fail("CHK-4 the core's SSG-vs-FM balance is outside the paired SNDTEST captures' -8.79 dB +/-1 dB");

    // ==== VERDICT ====
    $display("  FM rms=%0.1f, SSG rms=%0.1f, ratio %0d/10000 (%0.2f dB), target %0.2f dB",
             fm_rms, ssg_rms, ratio_x10000, observed_db, TARGET_DB);
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_SNDTEST_BALANCE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_SNDTEST_BALANCE: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "TB_PC9821_OPNA_SNDTEST_BALANCE: TIMEOUT");
  end

endmodule

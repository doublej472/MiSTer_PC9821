// tb_pc9821_audio_out_alias - the 48 kHz stage's anti-alias filter, measured against the
// pre-fix output stage in the same run.
//
// ==== WHAT THIS PROVES ====
// A 45 kHz tone carried on the mixer's 2.4576 MHz grid - above the 48 kHz presentation's 24 kHz Nyquist, so it MUST be removed and not folded - comes out of the pre-fix output stage (a bare register loaded on audio_volume_valid, the stage it replaced) folded onto 3 kHz at the tone's own level, and comes out of pc9821_audio_out at <= -60 dB relative: the bare-latch arm measures the fold at about 0 dB (the fold is real and the stimulus is non-vacuous) while the filtered arm's 5/32 polyphase prototype holds a 28 kHz stopband at -100 dB by design, so the aliasing that a bare strobe cannot avoid is removed instead of folded - and an in-band 3 kHz tone at the same drive on the right channel passes at 0 dB +-0.5 dB, so the stopband cannot be met by a stage that attenuates everything; and swept tones hold the rest of the filter plan pc9821_audio_out.sv's header states: one stopband tone in each stage's fold region (30 kHz for C, 300 kHz for B, 617.4 kHz and 1216.8 kHz for A's 614.4 kHz multiples) folds in at <= -80 dB relative to its drive (the 16-bit output's measurement floor here is about -85 to -90 dB, above the -100.7 dB design figure), and seven passband points from 100 Hz to 20 kHz pass at 0 dB +-0.15 dB (the design flatness is 0.071 dB).
//
// ==== DUT ====
// pc9821_audio_out (src/pc9821/audio/pc9821_audio_out.sv) in parallel with the PRE-FIX
// output stage (a bare register loaded on the mixer strobe), on one stimulus.
//
// ==== CHECKS ====
// CHK-1 the tone is really there: the bare arm's folded content is within 6 dB of the
//       drive amplitude, so the stimulus is not silently empty.
// CHK-2 the fold is at or below -60 dB of the drive in the filtered arm.
// CHK-3 the filtered arm did not pass the out-of-band tone as itself.
// CHK-4 the filtered arm PASSES the band: a 3 kHz tone at the same drive on the RIGHT
//       channel comes out at 0 dB +-0.5 dB (the module's design flatness is 0.071 dB over
//       0-20 kHz, pc9821_audio_out.sv's header). Without it CHK-2 is satisfied by a filter
//       that attenuates everything - a muted or gutted stage passed (a planted
//       mutation: half the C prototype zeroed still met -60 dB).
// CHK-5 a stopband tone in each stage's fold region (C 30 kHz, B 300 kHz, A 617.4 kHz and
//       1216.8 kHz), summed onto the left channel, folds in at <= -80 dB of its drive.
// CHK-6 seven passband tones (100 Hz - 20 kHz) on the right channel pass at 0 dB +-0.15 dB.
//
// ==== VERDICT ====
// PASS when the bare arm shows the fold and the filtered arm does not; FAIL naming which
// arm moved.
//
`timescale 1ns/1ps
module tb_pc9821_audio_out_alias;

  localparam integer NSAMP = 4800;          // 0.1 s at 48 kHz -> 10 Hz bins
  localparam real    FOLD  = 3000.0;

  reg clk = 0;
  always #5 clk = ~clk;

  reg                valid = 0;
  reg  signed [15:0] in_l = 0, in_r = 0;
  wire signed [15:0] out_l, out_r;

  pc9821_audio_out dut (
      .clk(clk), .valid(valid), .in_l(in_l), .in_r(in_r),
      .out_l(out_l), .out_r(out_r)
  );

  // The pre-fix output stage, verbatim: one register loaded on the mixer's strobe.
  reg signed [15:0] naive = 0;
  always @(posedge clk) if (valid) naive <= in_l;

  integer errors = 0;
  task fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ---- stimulus: a 45 kHz tone on the 2.4576 MHz service grid --------------------------
  localparam real DRIVE = 12000.0;
  integer vcnt = 0, seq = 0;
  real phase = 0.0;
  // $sin, not a truncated series: the series' odd harmonics of the 3 kHz drive land on the
  // swept passband points (its fifth is 15 kHz) and those of 45 kHz on stopband folds.
  function integer isin(input real x);
    begin
      isin = $rtoi($sin(x) * DRIVE);
    end
  endfunction

  // ---- the swept tones, summed onto the two channels at a lower drive -----------------
  // LEFT: one stopband tone in each stage's fold region (pc9821_audio_out.sv's filter
  // plan), each landing on its own output bin: C's 28 kHz+ (30 kHz -> 18 kHz), B's
  // 287.2-307.2 kHz (300 kHz -> 12 kHz), A's +-20 kHz around 614.4 kHz (617.4 kHz -> 6.6 kHz)
  // and around 1228.8 kHz (1216.8 kHz -> 16.8 kHz). RIGHT: the passband 0-20 kHz at seven
  // points. Every frequency is a multiple of 10 Hz, the window's bin spacing.
  localparam integer NSW = 4, NPB = 7;
  localparam real    SW_DRIVE = 3000.0;     // each stopband tone (left)
  localparam real    PB_DRIVE = 1500.0;     // each passband tone (right)
  real sw_f [0:NSW-1];
  real sw_fold [0:NSW-1];
  real pb_f [0:NPB-1];
  initial begin
    sw_f[0] = 30000.0;   sw_fold[0] = 18000.0;
    sw_f[1] = 300000.0;  sw_fold[1] = 12000.0;
    sw_f[2] = 617400.0;  sw_fold[2] = 6600.0;
    sw_f[3] = 1216800.0; sw_fold[3] = 16800.0;
    pb_f[0] = 100.0;  pb_f[1] = 1000.0;  pb_f[2] = 5000.0;  pb_f[3] = 10000.0;
    pb_f[4] = 15000.0; pb_f[5] = 19000.0; pb_f[6] = 20000.0;
  end
  // $sin, not the polynomial above: a truncated series puts harmonics of the drive into the
  // very bins the sweep measures (5 kHz's third lands on 15 kHz).
  function integer isin_a(input real x, input real amp);
    begin
      isin_a = $rtoi($sin(x) * amp);
    end
  endfunction
  function integer sweep_l(input integer k);
    integer j;
    begin
      sweep_l = 0;
      for (j = 0; j < NSW; j = j + 1)
        sweep_l = sweep_l + isin_a(2.0 * 3.141592653589793 * sw_f[j] * k / 2457600.0, SW_DRIVE);
    end
  endfunction
  function integer sweep_r(input integer k);
    integer j;
    begin
      sweep_r = 0;
      for (j = 0; j < NPB; j = j + 1)
        sweep_r = sweep_r + isin_a(2.0 * 3.141592653589793 * pb_f[j] * k / 2457600.0, PB_DRIVE);
    end
  endfunction

  always @(posedge clk) begin
    vcnt <= (vcnt == 9) ? 0 : vcnt + 1;
    valid <= (vcnt == 9);
    if (vcnt == 9) begin
      seq <= seq + 1;
      phase = 2.0 * 3.141592653589793 * 45000.0 * seq / 2457600.0;
      in_l <= isin(phase) + sweep_l(seq);
      in_r <= isin(2.0 * 3.141592653589793 * FOLD * seq / 2457600.0) + sweep_r(seq);
    end
  end

  // ---- Goertzel over the presentation grid, on both arms ------------------------------
  integer out_div = 0, n = 0;
  real    acc_filtered_re, acc_filtered_im, acc_bare_re, acc_bare_im, acc_dc;
  real    acc_pass_re, acc_pass_im;
  real    win_sum;
  real    sw_re [0:NSW-1], sw_im [0:NSW-1], pb_re [0:NPB-1], pb_im [0:NPB-1];
  integer settling = 0;

  always @(posedge clk) begin
    out_div = out_div + 1;
    if (out_div == 512) begin
      out_div = 0;
      settling = settling + 1;
      if (settling > 960) begin                 // skip 0.02 s of pipeline settling
        if (n < NSAMP) begin
          begin
            real w, th, xs, xn;
            w  = $sin(3.141592653589793 * n / NSAMP);
            w  = w * w;                          // Hann
            th = 2.0 * 3.141592653589793 * FOLD * n / 48000.0;
            xs = $itor(out_l);
            xn = $itor(naive);
            acc_filtered_re = acc_filtered_re + xs * w * $cos(th);
            acc_filtered_im = acc_filtered_im - xs * w * $sin(th);
            acc_bare_re     = acc_bare_re + xn * w * $cos(th);
            acc_bare_im     = acc_bare_im - xn * w * $sin(th);
            acc_dc          = acc_dc + xs;
            acc_pass_re     = acc_pass_re + $itor(out_r) * w * $cos(th);
            acc_pass_im     = acc_pass_im - $itor(out_r) * w * $sin(th);
            win_sum         = win_sum + w;
            begin
              integer j;
              real thj;
              for (j = 0; j < NSW; j = j + 1) begin
                thj = 2.0 * 3.141592653589793 * sw_fold[j] * n / 48000.0;
                sw_re[j] = sw_re[j] + xs * w * $cos(thj);
                sw_im[j] = sw_im[j] - xs * w * $sin(thj);
              end
              for (j = 0; j < NPB; j = j + 1) begin
                thj = 2.0 * 3.141592653589793 * pb_f[j] * n / 48000.0;
                pb_re[j] = pb_re[j] + $itor(out_r) * w * $cos(thj);
                pb_im[j] = pb_im[j] - $itor(out_r) * w * $sin(thj);
              end
            end
          end
          n = n + 1;
        end
      end
    end
  end

  initial begin
    acc_filtered_re = 0.0; acc_filtered_im = 0.0;
    acc_bare_re = 0.0; acc_bare_im = 0.0; acc_dc = 0.0; win_sum = 0.0;
    acc_pass_re = 0.0; acc_pass_im = 0.0;
    begin
      integer j;
      for (j = 0; j < NSW; j = j + 1) begin sw_re[j] = 0.0; sw_im[j] = 0.0; end
      for (j = 0; j < NPB; j = j + 1) begin pb_re[j] = 0.0; pb_im[j] = 0.0; end
    end
    // enough clk for settling (0.02 s of presentation grid) + the window
    #(10 * 2 * (512 * (960 + NSAMP + 8)));
    begin
      real mag_f, mag_b, rel_f, rel_b, dc, mag_p, rel_p;
      mag_f = 2.0 * $sqrt(acc_filtered_re*acc_filtered_re + acc_filtered_im*acc_filtered_im) / win_sum;
      mag_b = 2.0 * $sqrt(acc_bare_re*acc_bare_re + acc_bare_im*acc_bare_im) / win_sum;
      dc    = acc_dc / win_sum;
      mag_p = 2.0 * $sqrt(acc_pass_re*acc_pass_re + acc_pass_im*acc_pass_im) / win_sum;
      rel_p = 20.0 * $log10(mag_p / DRIVE + 1.0e-12);
      rel_b = 20.0 * $log10(mag_b / DRIVE);
      rel_f = 20.0 * $log10(mag_f / DRIVE);
      $display("tone 45 kHz on the grid, drive %.1f (-8.7 dBFS), fold lands at %.0f Hz:", DRIVE, FOLD);
      $display("  bare pre-fix latch : %0.1f dB relative to the drive (abs %.1f)", rel_b, mag_b);
      $display("  pc9821_audio_out  : %0.1f dB relative to the drive (abs %.1f)", rel_f, mag_f);
      $display("  filtered DC offset : %0.1f LSB", dc);
      $display("  in-band 3 kHz (R)  : %0.2f dB relative to the drive (abs %.1f)", rel_p, mag_p);

      if (!(rel_b > -6.0))
        fail("CHK-1 the bare-latch arm did not show the fold: stimulus or fold is wrong");
      if (!(rel_f <= -60.0))
        fail("CHK-2 the filtered arm folded the 45 kHz tone into the passband");
      if (!(mag_f < 200.0))
        fail("CHK-3 the filtered arm passed the out-of-band tone as itself");
      if (!(rel_p > -0.5 && rel_p < 0.5))
        fail("CHK-4 the filtered arm does not pass an in-band 3 kHz tone at 0 dB +-0.5 dB");
      begin
        integer j;
        real m, r;
        for (j = 0; j < NSW; j = j + 1) begin
          m = 2.0 * $sqrt(sw_re[j]*sw_re[j] + sw_im[j]*sw_im[j]) / win_sum;
          r = 20.0 * $log10(m / SW_DRIVE + 1.0e-12);
          $display("  stopband %0.0f Hz -> fold at %0.0f Hz: %0.1f dB", sw_f[j], sw_fold[j], r);
          if (!(r <= -80.0))
          begin
            $display("FAIL: CHK-5 the stopband tone %0.0f Hz folds into %0.0f Hz at %0.1f dB (want <= -80 dB)",
                     sw_f[j], sw_fold[j], r);
            errors = errors + 1;
          end
        end
        for (j = 0; j < NPB; j = j + 1) begin
          m = 2.0 * $sqrt(pb_re[j]*pb_re[j] + pb_im[j]*pb_im[j]) / win_sum;
          r = 20.0 * $log10(m / PB_DRIVE + 1.0e-12);
          $display("  passband %0.0f Hz: %0.3f dB", pb_f[j], r);
          if (!(r > -0.15 && r < 0.15))
          begin
            $display("FAIL: CHK-6 the passband tone %0.0f Hz comes out at %0.3f dB (want 0 dB +-0.15 dB)",
                     pb_f[j], r);
            errors = errors + 1;
          end
        end
      end
    end
    if (errors == 0) begin
      $display("TB_PC9821_AUDIO_OUT_ALIAS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_AUDIO_OUT_ALIAS: FAIL (%0d errors)", errors);
  end

initial begin
    #(10 * 2 * (512 * (960 + 4800 + 2000)));
    $fatal(1, "TB_PC9821_AUDIO_OUT_ALIAS: TIMEOUT");
  end

endmodule

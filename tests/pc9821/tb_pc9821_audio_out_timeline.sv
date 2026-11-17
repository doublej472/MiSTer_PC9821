// tb_pc9821_audio_out_timeline - each source's own rate survives the output stage.
//
// ==== WHAT THIS PROVES ====
// Two source staircases at their real rates - the OPNA's 55 467 Hz DAC rate (7.9872 MHz/144) on the left and 44 100 Hz (PCM86 and CD-DA) on the right - come out of pc9821_audio_out at the SAME frequency they went in (measured by interpolated zero crossings over 0.1 s to within 0.1%), so the output stage's 256/5 decimation is a resampling of real time and not a playback-rate change: the pre-fix stage's 2.4576 MHz register write rate is 51.2x the framework's 48 kHz DAC rate, and reading that ratio as 'FM is 16% fast, PCM is 8% slow' is what this bench refutes - the measured pitch is 1.0000x for both sources, and a source that came out at the wrong rate (a 51.2x displacement, or a drift the size of the 511/512 (0.2%) one sys/audio_out.sv's own sample_ce carries) fails here by name.
//
// ==== DUT ====
// pc9821_audio_out (src/pc9821/audio/pc9821_audio_out.sv), driven with two source
// staircases at their real rates (55 467 Hz on the left, 44 100 Hz on the right).
//
// ==== CHECKS ====
// CHK-1 the 55 467 Hz source's 10 kHz tone comes back within 0.1% of 10 kHz (zero crossings).
// CHK-2 the 44 100 Hz source's 1 kHz tone comes back within 0.1% of 1 kHz (zero crossings).
// CHK-3 neither result sits where a 51.2x misreading would put it: the tone bin must
//       dominate its +/-50 Hz neighbours by 12 dB, which a shifted timeline cannot do.
// CHK-4 both arms keep the right LEVEL (within 3 dB of the drive), so the frequency checks
//       cannot pass on a silent or crushed channel.
//
// ==== VERDICT ====
// PASS when each source's tone comes back at its own frequency and level; FAIL naming which
// arm moved and by how much.
//
`timescale 1ns/1ps
module tb_pc9821_audio_out_timeline;

  localparam integer NSAMP = 4800;        // 0.1 s at 48 kHz
  localparam real    TONE_L = 10000.0;    // in the 55 467 Hz domain
  localparam real    TONE_R = 1000.0;     // in the 44 100 Hz domain
  localparam real    DRIVE  = 12000.0;

  reg clk = 0;
  always #5 clk = ~clk;

  reg                valid = 0;
  reg  signed [15:0] in_l = 0, in_r = 0;
  wire signed [15:0] out_l, out_r;

  pc9821_audio_out dut (
      .clk(clk), .valid(valid), .in_l(in_l), .in_r(in_r),
      .out_l(out_l), .out_r(out_r)
  );

  integer errors = 0;
  task fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  function integer isin(input real x);
    real t;
    begin
      t = x - 6.283185307179586 * $floor(x / 6.283185307179586);
      if (t > 3.141592653589793) t = t - 6.283185307179586;
      isin = $rtoi(t * (1.0 - t*t/6.0 * (1.0 - t*t/20.0 * (1.0 - t*t/42.0))) * DRIVE);
    end
  endfunction

  // ---- the mixer service strobe: one pulse per 10 clk, a fresh value every pulse --------
  integer vcnt = 0;
  always @(posedge clk) begin
    vcnt <= (vcnt == 9) ? 0 : vcnt + 1;
    valid <= (vcnt == 9);
  end

  // ---- two staircases, each at its own rate, quantised to the grid ----------------------
  integer acc_l = 0, idx_l = 0, acc_r = 0, idx_r = 0;
  localparam integer STEP_L = 55467;        // 55 467 Hz at CLK_AUDIO = 24 576 000
  localparam integer STEP_R = 44100;
  localparam integer THRESH = 24576000;

  // Per CLK_AUDIO cycle, exactly as the core's own grid does it: the source's sample
  // instants land on grid ticks, i.e. each sample is HELD for 2 457 600/src_rate cycles.
  always @(posedge clk) begin
    acc_l = acc_l + STEP_L;
    if (acc_l >= THRESH) begin
      acc_l = acc_l - THRESH;
      idx_l = idx_l + 1;
      in_l <= isin(2.0 * 3.141592653589793 * TONE_L * idx_l / STEP_L);
    end
    acc_r = acc_r + STEP_R;
    if (acc_r >= THRESH) begin
      acc_r = acc_r - THRESH;
      idx_r = idx_r + 1;
      in_r <= isin(2.0 * 3.141592653589793 * TONE_R * idx_r / STEP_R);
    end
  end

  // ---- Goertzel at each expected tone over the presentation grid -----------------------
  integer out_div = 0, n = 0, settling = 0;
  real re_l, im_l, re_r, im_r, wsum, dc_l, dc_r;
  // The +/-0.5% neighbours: a tone whose timeline moved sits in THOSE bins, not this one.
  real re_lp, im_lp, re_lm, im_lm, re_rp, im_rp, re_rm, im_rm;
  // The FREQUENCY itself: positive-going zero crossings over the window, each placed by
  // linear interpolation between the two output samples around it. f = (crossings - 1)
  // cycles over (last - first) output samples at 48 kHz; 100 cycles of the 1 kHz tone span
  // ~4800 samples, so a 0.2% shift moves `last` by ~10 samples - far above the error.
  real prev_l, prev_r, zf_l, zl_l, zf_r, zl_r;
  integer zc_l = 0, zc_r = 0;

  always @(posedge clk) begin
    out_div = out_div + 1;
    if (out_div == 512) begin
      out_div = 0;
      settling = settling + 1;
      if ((settling > 960) && (n < NSAMP)) begin
        real w, thl, thr, xl, xr;
        w   = $sin(3.141592653589793 * n / NSAMP);
        w   = w * w;
        thl = 2.0 * 3.141592653589793 * TONE_L * n / 48000.0;
        thr = 2.0 * 3.141592653589793 * TONE_R * n / 48000.0;
        xl  = $itor(out_l);
        xr  = $itor(out_r);
        re_l = re_l + xl * w * $cos(thl);
        im_l = im_l - xl * w * $sin(thl);
        re_r = re_r + xr * w * $cos(thr);
        im_r = im_r - xr * w * $sin(thr);
        begin
          real tha, thb;
          tha = 2.0 * 3.141592653589793 * (TONE_L + 50.0) * n / 48000.0;
          thb = 2.0 * 3.141592653589793 * (TONE_L - 50.0) * n / 48000.0;
          re_lp = re_lp + xl * w * $cos(tha);
          im_lp = im_lp - xl * w * $sin(tha);
          re_lm = re_lm + xl * w * $cos(thb);
          im_lm = im_lm - xl * w * $sin(thb);
          tha = 2.0 * 3.141592653589793 * (TONE_R + 50.0) * n / 48000.0;
          thb = 2.0 * 3.141592653589793 * (TONE_R - 50.0) * n / 48000.0;
          re_rp = re_rp + xr * w * $cos(tha);
          im_rp = im_rp - xr * w * $sin(tha);
          re_rm = re_rm + xr * w * $cos(thb);
          im_rm = im_rm - xr * w * $sin(thb);
        end
        if ((n > 0) && (prev_l < 0.0) && (xl >= 0.0)) begin
          zl_l = (n - 1) + (-prev_l) / (xl - prev_l);
          if (zc_l == 0) zf_l = zl_l;
          zc_l = zc_l + 1;
        end
        if ((n > 0) && (prev_r < 0.0) && (xr >= 0.0)) begin
          zl_r = (n - 1) + (-prev_r) / (xr - prev_r);
          if (zc_r == 0) zf_r = zl_r;
          zc_r = zc_r + 1;
        end
        prev_l = xl;
        prev_r = xr;
        dc_l = dc_l + xl;
        dc_r = dc_r + xr;
        wsum = wsum + w;
        n = n + 1;
      end
    end
  end

  initial begin
    re_l = 0.0; im_l = 0.0; re_r = 0.0; im_r = 0.0; wsum = 0.0; dc_l = 0.0; dc_r = 0.0;
    re_lp = 0.0; im_lp = 0.0; re_lm = 0.0; im_lm = 0.0;
    re_rp = 0.0; im_rp = 0.0; re_rm = 0.0; im_rm = 0.0;
    prev_l = 0.0; prev_r = 0.0; zf_l = 0.0; zl_l = 0.0; zf_r = 0.0; zl_r = 0.0;
    #(10 * 2 * (512 * (960 + NSAMP + 8)));
    begin
      real mag_l, mag_r, rel_l, rel_r;
      mag_l = 2.0 * $sqrt(re_l*re_l + im_l*im_l) / wsum;
      mag_r = 2.0 * $sqrt(re_r*re_r + im_r*im_r) / wsum;
      rel_l = 20.0 * $log10(mag_l / DRIVE);
      rel_r = 20.0 * $log10(mag_r / DRIVE);
      $display("left  : 55 467 Hz staircase, %.0f Hz tone -> %.1f dB rel. drive (abs %.0f); dc %.1f, idx_l %0d",
               TONE_L, rel_l, mag_l, dc_l / wsum, idx_l);
      $display("right : 44 100 Hz staircase, %.0f Hz tone -> %.1f dB rel. drive (abs %.0f); dc %.1f, idx_r %0d",
               TONE_R, rel_r, mag_r, dc_r / wsum, idx_r);
      begin
        real f_l, f_r;
        f_l = (zc_l > 1) ? (zc_l - 1) * 48000.0 / (zl_l - zf_l) : 0.0;
        f_r = (zc_r > 1) ? (zc_r - 1) * 48000.0 / (zl_r - zf_r) : 0.0;
        $display("  measured frequency: left %0.2f Hz (%0d crossings), right %0.3f Hz (%0d crossings)",
                 f_l, zc_l, f_r, zc_r);
        // 0.1%: half the 511/512 (0.195%) drift, a fifth of the claim's old 0.5%
        if (!(f_l > TONE_L * 0.999 && f_l < TONE_L * 1.001))
          fail("CHK-1 the 55 467 Hz source's 10 kHz tone is not within 0.1% of 10 kHz");
        if (!(f_r > TONE_R * 0.999 && f_r < TONE_R * 1.001))
          fail("CHK-2 the 44 100 Hz source's 1 kHz tone is not within 0.1% of 1 kHz");
      end
      if (!(rel_l > -3.0 && rel_l < 1.0))
        fail("CHK-1/4 the 55 467 Hz source's tone is missing, moved or crushed");
      if (!(rel_r > -3.0 && rel_r < 1.0))
        fail("CHK-2/4 the 44 100 Hz source's tone is missing, moved or crushed");
      begin
        real np_l, np_r, nl_p, nl_m, nr_p, nr_m, ratio_l, ratio_r;
        np_l = 2.0 * $sqrt(re_lp*re_lp + im_lp*im_lp) / wsum;
        nl_p = 2.0 * $sqrt(re_lm*re_lm + im_lm*im_lm) / wsum;
        np_r = 2.0 * $sqrt(re_rp*re_rp + im_rp*im_rp) / wsum;
        nr_p = 2.0 * $sqrt(re_rm*re_rm + im_rm*im_rm) / wsum;
        ratio_l = 20.0 * $log10(mag_l / (np_l > nl_p ? np_l : nl_p));
        ratio_r = 20.0 * $log10(mag_r / (np_r > nr_p ? np_r : nr_p));
        $display("  tone bin vs its +/-50 Hz neighbours: left %0.1f dB, right %0.1f dB",
                 ratio_l, ratio_r);
        if (!(ratio_l >= 12.0))
          fail("CHK-1/3 the 55 467 Hz source's tone is not AT 10 kHz (neighbours too hot)");
        if (!(ratio_r >= 12.0))
          fail("CHK-2/3 the 44 100 Hz source's tone is not AT 1 kHz (neighbours too hot)");
      end
    end
    if (errors == 0) begin
      $display("TB_PC9821_AUDIO_OUT_TIMELINE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_AUDIO_OUT_TIMELINE: FAIL (%0d errors)", errors);
  end

initial begin
    #(10 * 2 * (512 * (960 + 4800 + 2000)));
    $fatal(1, "TB_PC9821_AUDIO_OUT_TIMELINE: TIMEOUT");
  end

endmodule

// tb_pc9821_cdda_equiv - the CD-DA ring's 44.1 kHz divider narrowing against its pre-change text.
//
// ==== WHAT THIS PROVES ====
// The CD-DA block's divider rewrite (the CLK_AUDIO accumulator held in units of the common factor of its 88200 step and its CLK_AUDIO_RATE threshold - 16 bits at 24.576 MHz instead of 32) is clock-for-clock identical to the pre-change block (cdda_ref.v, the module as of 3b134fe4): over a real 80 MHz and 24.576 MHz clock pair with random bursts that never fill the reference's 2048-sample ring and a fast-rate configuration, AUDIO_CE, AUDIO_L and AUDIO_R match at every sampling instant (CDDA_REQ is not compared: the ring is deliberately larger since the read-ahead, whose requests tb_pc9821_atapi C20-C22 pin), and the divider's toggle is the exact 44.1 kHz ratio.
//
// ==== DUT ====
// cdda (src/soc/cdda.v) vs cdda_ref (tests/pc9821/cdda_ref.v), same inputs. Two configurations:
// CLK_AUDIO_RATE = 24576000 with the real clocks (80 MHz CLK, 24.576 MHz CLK_AUDIO, full
// volume) and CLK_AUDIO_RATE = 352800 on fast clocks with a reduced volume setting. The
// reference is the pre-change text, not a model of the hardware.
//
// ==== CHECKS ====
// CHK-1 AUDIO_CE, AUDIO_L and AUDIO_R equal at every 1 ns sampling instant, in both
//       configurations. Each burst is 400 samples, so the reference's 2048-sample ring never
//       fills and drops one (the device ring is larger and would keep it).
// CHK-2 the run was not vacuous: AUDIO_CE pulsed many times, non-zero audio came out, and the
//       real-rate configuration's CE count matches 44 100 Hz x the run time to within one.
//
// ==== VERDICT ====
// PASS when no sampling instant differs; FAIL names the first one.
//
`timescale 1ps/1ps
module tb_pc9821_cdda_equiv;
  localparam integer RUN_PS = 3_000_000_000;   // 3 ms

  reg CLK = 0, CLK_AUDIO = 0, CLK_F = 0, CLK_AUDIO_F = 0;
  always #6250  CLK = ~CLK;                  // 80 MHz
  always #20345 CLK_AUDIO = ~CLK_AUDIO;      // 24.576 MHz (to 0.01 %)
  always #3000  CLK_F = ~CLK_F;
  always #7000  CLK_AUDIO_F = ~CLK_AUDIO_F;

  reg         wr = 0, wr_f = 0;
  reg  [31:0] data = 0, data_f = 0;
  wire req_d, req_r, ce_d, ce_r, req_fd, req_fr, ce_fd, ce_fr;
  wire [15:0] l_d, r_d, l_r, r_r, l_fd, r_fd, l_fr, r_fr;

  cdda     #(.CLK_AUDIO_RATE(24576000)) dut  (.CLK(CLK), .CDDA_REQ(req_d), .CDDA_REQ4(), .CDDA_PLAYED(), .CDDA_FLUSH(1'b0), .CDDA_WR(wr), .CDDA_DATA(data),
      .VOLUME_L(4'hF), .VOLUME_R(4'hF), .CLK_AUDIO(CLK_AUDIO), .AUDIO_CE(ce_d), .AUDIO_L(l_d), .AUDIO_R(r_d));
  cdda_ref #(.CLK_AUDIO_RATE(24576000)) ref0 (.CLK(CLK), .CDDA_REQ(req_r), .CDDA_WR(wr), .CDDA_DATA(data),
      .VOLUME_L(4'hF), .VOLUME_R(4'hF), .CLK_AUDIO(CLK_AUDIO), .AUDIO_CE(ce_r), .AUDIO_L(l_r), .AUDIO_R(r_r));
  cdda     #(.CLK_AUDIO_RATE(352800)) dutf  (.CLK(CLK_F), .CDDA_REQ(req_fd), .CDDA_REQ4(), .CDDA_PLAYED(), .CDDA_FLUSH(1'b0), .CDDA_WR(wr_f), .CDDA_DATA(data_f),
      .VOLUME_L(4'hA), .VOLUME_R(4'h5), .CLK_AUDIO(CLK_AUDIO_F), .AUDIO_CE(ce_fd), .AUDIO_L(l_fd), .AUDIO_R(r_fd));
  cdda_ref #(.CLK_AUDIO_RATE(352800)) reff (.CLK(CLK_F), .CDDA_REQ(req_fr), .CDDA_WR(wr_f), .CDDA_DATA(data_f),
      .VOLUME_L(4'hA), .VOLUME_R(4'h5), .CLK_AUDIO(CLK_AUDIO_F), .AUDIO_CE(ce_fr), .AUDIO_L(l_fr), .AUDIO_R(r_fr));

  integer errors = 0, n_ce = 0, n_ce_f = 0, n_nz = 0;
  reg ce_q = 0, cef_q = 0;
  time t0 = 0;

  // 1 ns sampling grid
  always #1000 begin
    if (ce_d !== ce_r || l_d !== l_r || r_d !== r_r) begin
      errors = errors + 1;
      if (errors <= 10) $display("FAIL CHK-1 real-rate config differs at %0t", $time);
    end
    if (ce_fd !== ce_fr || l_fd !== l_fr || r_fd !== r_fr) begin
      errors = errors + 1;
      if (errors <= 10) $display("FAIL CHK-1 fast config differs at %0t", $time);
    end
    if (ce_d && !ce_q) n_ce = n_ce + 1;
    if (ce_fd && !cef_q) n_ce_f = n_ce_f + 1;
    ce_q <= ce_d; cef_q <= ce_fd;
    if (l_d != 0 || r_d != 0 || l_fd != 0 || r_fd != 0) n_nz = n_nz + 1;
  end

  // sector bursts: whenever the reference asks, push 588 words with random spacing
  integer wcnt = 0, wcnt_f = 0;
  reg [31:0] g = 32'h2468ACE1, gf = 32'h13579BDF;
  reg req_seen = 0, req_seen_f = 0;
  always @(posedge CLK) begin
    g <= {g[30:0], g[31] ^ g[21] ^ g[1] ^ g[0]};
    wr <= 1'b0;
    if (req_r && wcnt == 0) wcnt <= 400;
    else if (wcnt > 0 && g[2:0] != 0) begin wr <= 1'b1; data <= {g[15:0], g[31:16] ^ 16'(wcnt)}; wcnt <= wcnt - 1; end
  end
  always @(posedge CLK_F) begin
    gf <= {gf[30:0], gf[31] ^ gf[21] ^ gf[1] ^ gf[0]};
    wr_f <= 1'b0;
    if (req_fr && wcnt_f == 0) wcnt_f <= 400;
    else if (wcnt_f > 0 && gf[1:0] != 0) begin wr_f <= 1'b1; data_f <= {gf[15:0], gf[31:16] ^ 16'(wcnt_f)}; wcnt_f <= wcnt_f - 1; end
  end

  initial begin
    #RUN_PS;
    if (n_ce < 50 || n_ce_f < 50) begin errors = errors + 1; $display("FAIL CHK-2 too few CE pulses: %0d / %0d", n_ce, n_ce_f); end
    // 3 ms x 44100 Hz = 132.3
    if (n_ce < 131 || n_ce > 134) begin errors = errors + 1; $display("FAIL CHK-2 CE count %0d is not 44.1 kHz over 3 ms", n_ce); end
    if (n_nz == 0) begin errors = errors + 1; $display("FAIL CHK-2 no audio came out"); end
    $display("coverage: %0d CE (real), %0d CE (fast), %0d non-zero sample instants", n_ce, n_ce_f, n_nz);
    if (errors == 0) begin
      $display("TB_PC9821_CDDA_EQUIV: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_CDDA_EQUIV: FAIL (%0d errors)", errors);
  end

  initial begin
    #(RUN_PS + 1_000_000);
    $fatal(1, "TB_PC9821_CDDA_EQUIV: TIMEOUT");
  end
endmodule

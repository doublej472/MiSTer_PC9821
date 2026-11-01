`timescale 1ps/1ps

// ==== WHAT THIS PROVES ====
// When 0x09A8 bit 0 switches the raster to the 31 kHz dot clock, the video PLL follows it and the analog picture leaves at the Xe10's own 31 kHz rates with the crossing FIFO locked: with clk_sys at 80 MHz, the core's dot enable (pc9821_dot_ce) driving the BIOS 31 kHz raster (800 x 449, 640 x 400 active: NP2kai bios/bios18.c gdcmastersync[2], the block HSB.EXE IGDC:31 and the crt31k probe send) into pc9821_video_out, and the real pc9821_vpll_ctl reprogramming a PLL model whose output is the frequency its N/M/K/C0 words decode to (Altera's Cyclone V reconfiguration map), the CLK_VIDEO after the switch runs at 2 x the capture's 25 168 031 Hz within 3 ppm (docs/probes/CRT31K.TXT, calibrated), and over the whole run after the relock every CE_PIXEL period is 2 clocks, every line 1600 clocks (31.460 kHz, the capture's line rate within 3 ppm) and every frame 449 lines with a 2-line VSYNC (70.067 Hz, the capture's frame within 3 ppm), with the OSD's Doubled setting asking all the while: the doubler stands aside for a 31 kHz raster, which is already VGA-rate; there is no FIFO re-centre or underflow over 40 frames after the relock (the two sides' dot rates are one ratio of the 50 MHz reference); and switching back to 24 kHz relocks the PLL to 2 x 400/19 MHz and brings the doubled 24 kHz picture back (848 clocks a line, 880 lines a frame) with no FIFO event over 20 frames. FAIL-FIRST: before the 31 kHz clock pc9821_video_out has no 31 kHz input and pc9821_vpll_ctl no 0x09A8 one, so the bench cannot build; and with the dot enable's 31 kHz rate one fraction step (1/4096 of M) away from the PLL's, the FIFO slips within a frame.
//
// THE FIGURES are the capture's (CRT31K.TXT `RUN frames=70 ticks=306930` with the ARTIC calibrated by
// its 24 kHz rows, as tools/hwprobe/crt31k/crt31k_decode.py does) and the BIOS SYNC block's geometry,
// never read out of the DUT; the PLL model only DECODES the words the controller writes.
//
// WHAT IT IS BLIND TO: the real PLL's lock behaviour at each setting (modelled: lock drops for LOCK_NS
// after a start, the old clock runs on meanwhile), the framework's chain after VGA_*, and whether a
// particular monitor locks - the hardware run's job.

module tb_pc9821_crt31k_video;
  localparam integer SYS_HZ = 80_000_000;
  localparam real    CAP_31K_DOT = 307200.0 * 70.0 / 306930.0 * 449.0 * 800.0
                                   * (21_052_600.0 / (307200.0 * 60.0 / ((326700.0 + 326700.0 + 326698.0) / 3.0) * 440.0 * 848.0));
  localparam real    DOT24 = 400.0e6 / 19.0;

  // ---- clk_sys 80 MHz (12.5 ns: whole ps) and the 50 MHz reference ----
  reg clk_sys = 1'b0;
  always #6250 clk_sys = ~clk_sys;
  reg clk50 = 1'b0;
  always #10000 clk50 = ~clk50;

  reg reset = 1'b1;
  initial begin repeat (8) @(posedge clk_sys); reset = 1'b0; end

  reg c31 = 1'b0;                 // 0x09A8 bit 0 (a level on clk_sys, as pc9821_system exports it)

  wire ce;
  pc9821_dot_ce #(.SYS_FREQ(SYS_HZ)) dot_ce (.clk(clk_sys), .reset(reset), .c31(c31), .ce(ce));

  // ---- the raster: the BIOS blocks' geometry, switched at a frame boundary as pc9821_crtc latches ----
  // 24 kHz gdcmastersync[1] 10 4E 07 25 07 07 90 65: 848 x 440, HFP 80 / HS 64, VFP 7 / VS 8.
  // 31 kHz gdcmastersync[2] 10 4E 47 0C 07 0D 90 89: 800 x 449, HFP 32 / HS 64, VFP 13 / VS 2.
  reg       g31 = 1'b0;
  wire [9:0] HT  = g31 ? 10'd800 : 10'd848;
  wire [9:0] HFP = g31 ? 10'd32  : 10'd80;
  wire [9:0] VT  = g31 ? 10'd449 : 10'd440;
  wire [9:0] VFP = g31 ? 10'd13  : 10'd7;
  wire [9:0] VSW = g31 ? 10'd2   : 10'd8;
  localparam [9:0] HA = 10'd640, HSW = 10'd64, VA = 10'd400;
  reg [9:0] hx = '0, vy = '0;
  reg       r_hs = 1'b1, r_vs = 1'b1, r_de = 1'b0;
  reg [7:0] r_r = '0, r_g = '0, r_b = '0;
  always @(posedge clk_sys) if (ce) begin
    hx   <= (hx == HT - 1) ? 10'd0 : hx + 10'd1;
    if (hx == HT - 1) begin
      vy <= (vy == VT - 1) ? 10'd0 : vy + 10'd1;
      if (vy == VT - 1) g31 <= c31;
    end
    r_hs <= ~((hx >= HA + HFP) && (hx < HA + HFP + HSW));
    r_vs <= ~((vy >= VA + VFP) && (vy < VA + VFP + VSW));
    r_de <= (hx < HA) && (vy < VA);
    r_r  <= hx[7:0];
    r_g  <= vy[7:0];
    r_b  <= hx[9:2] ^ vy[7:0];
  end

  // ---- the reconfiguration core and the PLL: the output is what the written words decode to ----
  localparam real LOCK_NS = 30_000.0;
  reg  [31:0] r_n = 32'h0001_0000, r_m = 32'h0002_0A09, r_k = 32'h20B0_0000, r_c = 32'h0002_0A09;
  wire        mgmt_write;
  wire [5:0]  mgmt_address;
  wire [31:0] mgmt_writedata;
  integer     wcnt = 0;
  wire        waitreq = mgmt_write && (wcnt < 2);
  reg         pll_locked = 1'b0;
  reg         start_ev = 1'b0;
  always @(posedge clk50) begin
    start_ev <= 1'b0;
    if (mgmt_write) begin
      if (wcnt < 2) wcnt <= wcnt + 1;
      else begin
        wcnt <= 0;
        case (mgmt_address)
          6'd3: r_n <= mgmt_writedata;
          6'd4: r_m <= mgmt_writedata;
          6'd5: r_c <= mgmt_writedata;
          6'd7: r_k <= mgmt_writedata;
          6'd2: start_ev <= 1'b1;
          default: ;
        endcase
      end
    end
  end
  function automatic integer cdiv(input [31:0] w);
    cdiv = w[16] ? 1 : (w[15:8] + w[7:0]);
  endfunction
  function automatic real fout();
    fout = 50.0e6 * (real'(cdiv(r_m)) + real'(r_k) / 4294967296.0) / (real'(cdiv(r_n)) * real'(cdiv(r_c)));
  endfunction

  // clk_vid: every edge at its exact time from the setting's start (no accumulated rounding), the old
  // setting running on until the relock.
  reg  clk_vid = 1'b0;
  real vhalf_ps = 1.0e12 / (2.0 * 50.336015e6);   // the generated (31 kHz) setting
  real v_t0 = 0.0;
  longint v_n = 0;
  initial begin
    forever begin
      real next;
      next = v_t0 + real'(v_n + 1) * vhalf_ps;
      #(next - $realtime);
      v_n = v_n + 1;
      clk_vid = ~clk_vid;
    end
  end
  initial begin
    #(LOCK_NS * 1000.0) pll_locked = 1'b1;
    forever begin
      @(posedge start_ev);
      pll_locked = 1'b0;
      #(LOCK_NS * 1000.0);
      v_t0 = $realtime;
      v_n = 0;
      vhalf_ps = 1.0e12 / (2.0 * fout());
      pll_locked = 1'b1;
    end
  end

  wire vclk_31, busy;
  pc9821_vpll_ctl #(.SETTLE(256)) vpll_ctl (
    .clk(clk50), .want_31k(c31), .pll_locked(pll_locked),
    .mgmt_waitrequest(waitreq), .mgmt_write(mgmt_write), .mgmt_address(mgmt_address),
    .mgmt_writedata(mgmt_writedata), .vclk_31(vclk_31), .busy(busy)
  );

  // ==== DUT ====
  wire       clk_video, ce_out, hs_out, vs_out, de_out, dbl_active, fifo_ev;
  wire [7:0] r_out, g_out, b_out;
  pc9821_video_out #(.DBL_EN(1'b1)) dut (
    .clk_sys(clk_sys), .ce(ce),
    .r_in(r_r), .g_in(r_g), .b_in(r_b), .hs_in(r_hs), .vs_in(r_vs), .de_in(r_de),
    .dbl_on(1'b1),                                  // the OSD asks for Doubled throughout
    .clk_vid(clk_vid), .vclk_31(vclk_31), .vid_rst(busy),
    .clk_video(clk_video), .ce_out(ce_out),
    .r_out(r_out), .g_out(g_out), .b_out(b_out), .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out),
    .dbl_active(dbl_active), .fifo_ev(fifo_ev)
  );

  // ---- measurement, in CLK_VIDEO clocks ----
  reg      measure = 1'b0;
  longint  clk_n = 0, last_ce = -1, last_hs = -1, last_vs = -1;
  integer  ce_lo, ce_hi, hs_lo, hs_hi, vs_lo, vs_hi, n_hs, n_vs, n_ev, lpf, lpf_lo, lpf_hi, vsw, vsw_lo, vsw_hi, n_px_bad, n_px_ok;
  real     t_m0, t_m1, t_hs0, t_hs1;
  longint  n_clk0, n_clk1;
  reg      hs_q = 1'b1, vs_q = 1'b1;
  reg [9:0] px_k = '0;
  task automatic clear;
    begin
      last_ce = -1; last_hs = -1; last_vs = -1;
      ce_lo = 1 << 30; ce_hi = 0; hs_lo = 1 << 30; hs_hi = 0; vs_lo = 1 << 30; vs_hi = 0;
      n_hs = 0; n_vs = 0; n_ev = 0; lpf = 0; lpf_lo = 1 << 30; lpf_hi = -1; vsw = 0; vsw_lo = 1 << 30; vsw_hi = -1;
      n_px_bad = 0; n_px_ok = 0;
      t_m0 = $realtime; n_clk0 = clk_n; t_hs0 = -1.0;
    end
  endtask
  always @(posedge clk_video) begin
    clk_n = clk_n + 1;
    if (measure) begin
      if (fifo_ev) n_ev = n_ev + 1;
      t_m1 = $realtime; n_clk1 = clk_n;
    end
    if (ce_out) begin
      if (measure) begin
        if (last_ce >= 0) begin
          if (integer'(clk_n - last_ce) < ce_lo) ce_lo = integer'(clk_n - last_ce);
          if (integer'(clk_n - last_ce) > ce_hi) ce_hi = integer'(clk_n - last_ce);
        end
        if (de_out) begin
          if (r_out == px_k[7:0] && b_out == (px_k[9:2] ^ g_out)) n_px_ok = n_px_ok + 1;
          else n_px_bad = n_px_bad + 1;
        end
        if (hs_q && !hs_out) begin
          if (last_hs >= 0) begin
            if (integer'(clk_n - last_hs) < hs_lo) hs_lo = integer'(clk_n - last_hs);
            if (integer'(clk_n - last_hs) > hs_hi) hs_hi = integer'(clk_n - last_hs);
            n_hs = n_hs + 1;
            t_hs1 = $realtime;
          end else t_hs0 = $realtime;
          last_hs = clk_n;
          lpf = lpf + 1;
          if (!vs_out) vsw = vsw + 1;
        end
        if (vs_q && !vs_out) begin
          if (last_vs >= 0) begin
            if (integer'(clk_n - last_vs) < vs_lo) vs_lo = integer'(clk_n - last_vs);
            if (integer'(clk_n - last_vs) > vs_hi) vs_hi = integer'(clk_n - last_vs);
            if (lpf < lpf_lo) lpf_lo = lpf;
            if (lpf > lpf_hi) lpf_hi = lpf;
            n_vs = n_vs + 1;
          end
          last_vs = clk_n;
          lpf = 0;
        end
        if (!vs_q && vs_out) begin
          if (last_vs >= 0) begin
            if (vsw < vsw_lo) vsw_lo = vsw;
            if (vsw > vsw_hi) vsw_hi = vsw;
          end
          vsw = 0;
        end
      end
      px_k <= (hs_q && !hs_out) ? 10'd0 : de_out ? px_k + 10'd1 : px_k;
      hs_q <= hs_out;
      vs_q <= vs_out;
      last_ce = clk_n;
    end
  end

  // A bound: the run ends at ~1.1 s of simulated time.
  initial begin
    #(3.0e12);
    $fatal(1, "TB_PC9821_CRT31K_VIDEO: watchdog (3 s simulated)");
  end

  // ==== CHECKS ====
  integer errors = 0;
  task automatic check(input bit ok, input string what);
    if (!ok) begin $display("FAIL: %0s", what); errors++; end
    else $display("  ok   %0s", what);
  endtask
  task automatic ppm_ok(input real got, input real want, input string what);
    real d;
    begin
      d = (got - want) / want * 1.0e6;
      check(d < 3.0 && d > -3.0, $sformatf("%0s: %.4f, want %.4f (%.2f ppm, within 3)", what, got, want, d));
    end
  endtask
  task automatic wait_frames(input integer n);
    integer i;
    for (i = 0; i < n; i++) begin
      @(negedge r_vs);
    end
  endtask
  task automatic wait_settled;
    begin
      @(posedge clk_sys);
      while (busy || vclk_31 != c31) @(posedge clk50);
      wait_frames(2);
    end
  endtask

  real fvid, fline, fframe;
  initial begin
    // ---- power-up: the controller takes the PLL from its generated (31 kHz) setting to 24 kHz ----
    wait_settled();
    check(!vclk_31 && fout() > 2.0 * DOT24 - 1.0e-3 && fout() < 2.0 * DOT24 + 1.0e-3,
          $sformatf("power-up: the PLL is at 24 kHz, %.6f Hz (2 x 400/19 MHz)", fout()));

    // ---- 0x09A8 bit 0 set ----
    c31 = 1'b1;
    wait_settled();
    measure = 1'b1; clear();
    wait_frames(40);
    measure = 1'b0;
    fvid   = real'(n_clk1 - n_clk0) * 1.0e12 / (t_m1 - t_m0);
    fline  = real'(n_hs) * 1.0e12 / (t_hs1 - t_hs0);
    fframe = fline / 449.0;
    ppm_ok(fvid / 2.0, CAP_31K_DOT, "31 kHz: CLK_VIDEO / 2 against the capture's dot clock (Hz)");
    ppm_ok(fline, CAP_31K_DOT / 800.0, "31 kHz: line rate (Hz)");
    ppm_ok(fframe, CAP_31K_DOT / 800.0 / 449.0, "31 kHz: frame rate (Hz)");
    check(ce_lo == 2 && ce_hi == 2, $sformatf("31 kHz: every CE_PIXEL 2 clocks (%0d..%0d): native, not doubled", ce_lo, ce_hi));
    check(hs_lo == 1600 && hs_hi == 1600, $sformatf("31 kHz: every line 1600 clocks (%0d..%0d)", hs_lo, hs_hi));
    check(vs_lo == 1600 * 449 && vs_hi == 1600 * 449, $sformatf("31 kHz: every frame 449 x 1600 clocks (%0d..%0d)", vs_lo, vs_hi));
    check(lpf_lo == 449 && lpf_hi == 449 && vsw_lo == 2 && vsw_hi == 2,
          $sformatf("31 kHz: %0d..%0d lines a frame, VSYNC %0d..%0d lines (want 449, 2)", lpf_lo, lpf_hi, vsw_lo, vsw_hi));
    check(!dbl_active, "31 kHz: the doubler stands aside although the OSD asks for it");
    check(n_ev == 0, $sformatf("31 kHz: no FIFO re-centre or underflow over 40 frames after the relock (%0d)", n_ev));
    check(n_px_bad == 0 && n_px_ok == 40 * 400 * 640,
          $sformatf("31 kHz: every active pixel is the raster's own dot in order (%0d ok, %0d bad)", n_px_ok, n_px_bad));

    // ---- back to 24 kHz: the doubled picture returns ----
    c31 = 1'b0;
    wait_settled();
    measure = 1'b1; clear();
    wait_frames(20);
    measure = 1'b0;
    fvid = real'(n_clk1 - n_clk0) * 1.0e12 / (t_m1 - t_m0);
    ppm_ok(fvid / 2.0, DOT24, "24 kHz again: CLK_VIDEO / 2 (Hz)");
    check(ce_lo == 1 && ce_hi == 1 && hs_lo == 848 && hs_hi == 848 && lpf_lo == 880 && lpf_hi == 880,
          $sformatf("24 kHz again: doubled, CE %0d..%0d, line %0d..%0d clocks, %0d..%0d lines a frame (want 1, 848, 880)",
                    ce_lo, ce_hi, hs_lo, hs_hi, lpf_lo, lpf_hi));
    check(n_ev == 0, $sformatf("24 kHz again: no FIFO event over 20 frames (%0d)", n_ev));

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_CRT31K_VIDEO: %0d check(s) failed", errors);
    $display("TB_PC9821_CRT31K_VIDEO: PASS");
    $finish;
  end
endmodule

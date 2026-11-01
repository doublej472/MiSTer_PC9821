`timescale 1ps/1ps

// ==== WHAT THIS PROVES ====
// The analog video leaves the core on an exact dot-locked video clock with a CONSTANT pixel period and a CONSTANT line and frame period in every analog mode, at every clk_sys: with clk_sys at 80, 100 and 120 MHz (three lanes in one simulation) and the core's own dot enable (pc9821_dot_ce) driving a 848 x 440 raster (640 x 400 active, the default SYNC block's geometry) into pc9821_video_out, the CLK_VIDEO it hands the framework runs at 2 x 400/19 MHz (period 23 750 ps) and over three whole frames after the output has settled every CE_PIXEL period, every hsync period and every vsync period is one and the same number of video clocks: native 2 clocks a pixel and 1696 a line (848 x 47.5 ns = 40.28 us, 24.83 kHz), doubled 1 clock a pixel and 848 a line (49.66 kHz), each frame 440 x 1696 = 746 240 native clocks (56.42 Hz) whatever the mode; and in every mode every active pixel is the raster's own dot in order (none dropped, repeated or reordered across the crossing); and over a LONG doubled run (100 frames, at each clk_sys) there is no FIFO re-centre or underflow, every frame is exactly 880 lines x 848 clocks with a 3-LINE VSYNC (the doubled picture's compatibility pulse: the replayed 16-line one lost sync on a VGA monitor under composite sync; FAIL-FIRST on the 16-line output), every VSYNC edge lands on an HSYNC leading edge, every VS-delimited frame holds exactly 800 DE lines (what the framework's scaler frames on, sys/ascal.vhd), and DE is never high inside HSYNC or VSYNC. The figures are the dot clock's (400/19 MHz = 50 MHz x 8/19, docs/pc9821-port-status.md "Pixel clock and the video pipeline") and the raster's, never read out of the DUT. FAIL-FIRST: on the fractional-enable design (CLK_VIDEO = clk_sys, CE_PIXEL a 24-bit accumulator carry) the video clock is clk_sys and every pixel period takes two values (3 or 4 clocks at 80 MHz), so the clock, pixel and line checks all fail.
//
// WHY. A VGA monitor's horizontal PLL locks to the hsync period and its pixel sampling sees the DAC
// update on every CE_PIXEL; when either moves by a clk_sys period line to line, the picture shimmers
// and a picky monitor drops sync. sys_top's analog port runs on CLK_VIDEO
// and samples on CE_PIXEL directly (sys/sys_top.v vga_out on clk_vid), so a constant period in
// CLK_VIDEO clocks at an exact CLK_VIDEO is what the DAC then shows.
//
// WHAT IT IS BLIND TO: the real PLL (modelled here as an ideal clock), the framework's own chain
// after VGA_* (video_cleaner/gamma registers add constant delay only), and whether a particular
// monitor locks - an eye check on a real monitor.

module tb_pc9821_video_clk_lane #(
  parameter integer SYS_HZ = 80_000_000,
  parameter integer LANE   = 0
) (
  input  wire       run_dbl,     // the mode the lane is asked for (bench-wide sequence)
  input  wire       measure,     // high while the window is open
  output reg [31:0] n_ce_lo, n_ce_hi, n_hs_lo, n_hs_hi, n_vs_lo, n_vs_hi,
  output reg [31:0] n_hs_cnt, n_vs_cnt,
  output reg [31:0] vclk_ps,
  output reg [31:0] n_px_bad, n_px_ok
);
  // ---- clk_sys: every edge at its exact time rounded to the ps, so the rate has no drift ----
  // (edge n at n x 1e12 / (2 x SYS_HZ) ps; an accumulated rounded half-period drifts 1e-7 and slips
  // the crossing FIFO a dot in about a hundred frames - a bench artefact, not the design's)
  reg clk_sys = 1'b0;
  longint edge_n = 0;
  initial begin
    forever begin
      longint now_ps, next_ps;
      now_ps  = (edge_n * 64'd500_000_000 + (SYS_HZ / 1000) / 2) / (SYS_HZ / 1000);
      edge_n  = edge_n + 1;
      next_ps = (edge_n * 64'd500_000_000 + (SYS_HZ / 1000) / 2) / (SYS_HZ / 1000);
      #(next_ps - now_ps) clk_sys = ~clk_sys;
    end
  end

  reg reset = 1'b1;
  initial begin repeat (8) @(posedge clk_sys); reset = 1'b0; end

  wire ce;
  pc9821_dot_ce #(.SYS_FREQ(SYS_HZ)) dot_ce (.clk(clk_sys), .reset(reset), .c31(1'b0), .ce(ce));

  // ---- the raster: 848 x 440, 640 x 400 active, syncs active low, advancing one dot per ce ----
  localparam integer HT = 848, HA = 640, HFP = 80, HSW = 64;   // the default block's uPD7220 porches
  localparam integer VT = 440, VA = 400, VFP = 7, VSW = 8;
  reg [9:0] hx = '0, vy = '0;
  reg       r_hs = 1'b1, r_vs = 1'b1, r_de = 1'b0;
  reg [7:0] r_r = '0, r_g = '0, r_b = '0;
  // (r_hs/r_vs are registered from this dot's hx/vy, so the line count as of the last hsync leading
  // edge is vy before the sync's first dot and vy + 1 from it on)
  wire [9:0] vy_hs = (hx < HA + HFP) ? vy : ((vy == VT - 1) ? 10'd0 : vy + 10'd1);
  always @(posedge clk_sys) if (ce) begin
    hx   <= (hx == HT - 1) ? 10'd0 : hx + 10'd1;
    if (hx == HT - 1) vy <= (vy == VT - 1) ? 10'd0 : vy + 10'd1;
    r_hs <= ~((hx >= HA + HFP) && (hx < HA + HFP + HSW));
    // VSYNC moves on the HSYNC leading edge, as pc9821_crtc's VSYNC pin does (the uPD7220's).
    r_vs <= ~((vy_hs >= VA + VFP) && (vy_hs < VA + VFP + VSW));
    r_de <= (hx < HA) && (vy < VA);
    r_r  <= hx[7:0];
    r_g  <= vy[7:0];
    r_b  <= hx[9:2] ^ vy[7:0];
  end

  // ---- the video PLL model: 800/19 MHz (2 x the dot rate), an ideal clock ----
  reg clk_vid = 1'b0;
  reg vid_rst = 1'b1;
  always #11_875 clk_vid = ~clk_vid;
  initial begin
    repeat (20) @(posedge clk_vid);
    vid_rst = 1'b0;
  end

  wire       clk_video, ce_out, hs_out, vs_out, de_out, dbl_active;
  wire [7:0] r_out, g_out, b_out;
  // ==== DUT ====
  pc9821_video_out #(.DBL_EN(1'b1)) dut (
    .clk_sys(clk_sys), .ce(ce),
    .r_in(r_r), .g_in(r_g), .b_in(r_b), .hs_in(r_hs), .vs_in(r_vs), .de_in(r_de),
    .dbl_on(run_dbl),
    .clk_vid(clk_vid), .vclk_31(1'b0), .vid_rst(vid_rst),
    .clk_video(clk_video), .ce_out(ce_out),
    .r_out(r_out), .g_out(g_out), .b_out(b_out), .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out),
    .dbl_active(dbl_active)
  );

  // ---- the long-run integrity counters (read hierarchically by the top) ----
  // FIFO events (a re-centre or an underflow), VS edges not on an HS leading edge, DE during HS or
  // VS, lines per frame and VS width in lines (min/max over the window).
  integer n_fifo_ev = 0, n_vs_off = 0, n_de_sync = 0, lpf_lo = 0, lpf_hi = 0, vsw_lo = 0, vsw_hi = 0;
  integer lpf_cnt = 0, vsw_cnt = 0, n_frames = 0;
  longint vs_off_ref = -1;
  integer dlpf_cnt = 0, dlpf_lo = 0, dlpf_hi = 0;
  reg     de_q2 = 1'b0;
  reg     prim_q = 1'b0;
  always @(posedge clk_vid) begin
    prim_q <= dut.primed;
    if (measure && (dut.recentre || (prim_q && !dut.primed))) n_fifo_ev = n_fifo_ev + 1;
  end

  // ---- measurement, in clocks of the CLK_VIDEO the module hands the framework ----
  longint   clk_n = 0, last_ce = -1, last_hs = -1, last_vs = -1;
  reg       hs_q = 1'b1, vs_q = 1'b1;
  reg [9:0] px_k = '0;
  realtime  t_last = 0;
  always @(posedge clk_video) begin
    clk_n <= clk_n + 1;
    vclk_ps <= 32'($realtime - t_last);
    t_last  <= $realtime;
    if (ce_out) begin
      hs_q <= hs_out;
      vs_q <= vs_out;
      if (measure) begin
        if (last_ce >= 0) begin
          if (32'(clk_n - last_ce) < n_ce_lo) n_ce_lo <= 32'(clk_n - last_ce);
          if (32'(clk_n - last_ce) > n_ce_hi) n_ce_hi <= 32'(clk_n - last_ce);
        end
        // Content (native and doubled): the k-th DE pixel of a line is raster column k, and its blue
        // is the raster's {x[9:2] ^ y}: a dropped, repeated or reordered dot breaks it.
        if (de_out) begin
          if (r_out == px_k[7:0] && b_out == (px_k[9:2] ^ g_out)) n_px_ok <= n_px_ok + 1;
          else n_px_bad <= n_px_bad + 1;
        end
        if (hs_q && !hs_out) begin
          if (last_hs >= 0) begin
            if (32'(clk_n - last_hs) < n_hs_lo) n_hs_lo <= 32'(clk_n - last_hs);
            if (32'(clk_n - last_hs) > n_hs_hi) n_hs_hi <= 32'(clk_n - last_hs);
            n_hs_cnt <= n_hs_cnt + 1;
          end
          last_hs <= clk_n;
        end
        if (de_out && (!hs_out || !vs_out)) n_de_sync = n_de_sync + 1;
        // Every VS edge (either way) lands on an HS leading edge.
        if (vs_q != vs_out && !(hs_q && !hs_out)) n_vs_off = n_vs_off + 1;
        if (hs_q && !hs_out) begin
          lpf_cnt = lpf_cnt + 1;
          if (!vs_out) vsw_cnt = vsw_cnt + 1;
        end
        // What the framework's scaler frames on (sys/ascal.vhd: a frame starts at the VS edge, the
        // first DE after it is line 0, i_vimax = the DE lines that follow): DE rising edges between
        // VS leading edges.
        if (de_out && !de_q2) dlpf_cnt = dlpf_cnt + 1;
        de_q2 = de_out;
        if (vs_q && !vs_out) begin
          if (last_vs >= 0) begin
            if (lpf_cnt < lpf_lo) lpf_lo = lpf_cnt;
            if (lpf_cnt > lpf_hi) lpf_hi = lpf_cnt;
            if (dlpf_cnt < dlpf_lo) dlpf_lo = dlpf_cnt;
            if (dlpf_cnt > dlpf_hi) dlpf_hi = dlpf_cnt;
            n_frames = n_frames + 1;
          end
          lpf_cnt = 0;
          dlpf_cnt = 0;
        end
        if (!vs_q && vs_out) begin
          if (last_vs >= 0) begin
            if (vsw_cnt < vsw_lo) vsw_lo = vsw_cnt;
            if (vsw_cnt > vsw_hi) vsw_hi = vsw_cnt;
          end
          vsw_cnt = 0;
        end
        if (vs_q && !vs_out) begin
          if (last_vs >= 0) begin
            if (32'(clk_n - last_vs) < n_vs_lo) n_vs_lo <= 32'(clk_n - last_vs);
            if (32'(clk_n - last_vs) > n_vs_hi) n_vs_hi <= 32'(clk_n - last_vs);
            n_vs_cnt <= n_vs_cnt + 1;
          end
          last_vs <= clk_n;
        end
      end
      last_ce <= clk_n;
      px_k <= (hs_q && !hs_out) ? 10'd0 : de_out ? px_k + 10'd1 : px_k;
    end
    if (!measure) begin
      last_ce <= -1; last_hs <= -1; last_vs <= -1;
      n_ce_lo <= 32'hFFFF_FFFF; n_ce_hi <= 0;
      n_hs_lo <= 32'hFFFF_FFFF; n_hs_hi <= 0;
      n_vs_lo <= 32'hFFFF_FFFF; n_vs_hi <= 0;
      n_hs_cnt <= 0; n_vs_cnt <= 0;
      n_px_bad <= 0; n_px_ok <= 0;
      n_fifo_ev = 0; n_vs_off = 0; n_de_sync = 0; n_frames = 0; vs_off_ref = -1;
      dlpf_cnt = 0; dlpf_lo = 1 << 30; dlpf_hi = -1;
      lpf_lo = 1 << 30; lpf_hi = -1; vsw_lo = 1 << 30; vsw_hi = -1; lpf_cnt = 0; vsw_cnt = 0;
    end
  end
endmodule

module tb_pc9821_video_clk;
  reg run_dbl = 1'b0, measure = 1'b0;
  wire [31:0] ce_lo [3], ce_hi [3], hs_lo [3], hs_hi [3], vs_lo [3], vs_hi [3], hs_n [3], vs_n [3], vps [3], pbad [3], pok [3];

  tb_pc9821_video_clk_lane #(.SYS_HZ(80_000_000),  .LANE(0)) l80  (run_dbl, measure,
    ce_lo[0], ce_hi[0], hs_lo[0], hs_hi[0], vs_lo[0], vs_hi[0], hs_n[0], vs_n[0], vps[0], pbad[0], pok[0]);
  tb_pc9821_video_clk_lane #(.SYS_HZ(100_000_000), .LANE(1)) l100 (run_dbl, measure,
    ce_lo[1], ce_hi[1], hs_lo[1], hs_hi[1], vs_lo[1], vs_hi[1], hs_n[1], vs_n[1], vps[1], pbad[1], pok[1]);
  tb_pc9821_video_clk_lane #(.SYS_HZ(120_000_000), .LANE(2)) l120 (run_dbl, measure,
    ce_lo[2], ce_hi[2], hs_lo[2], hs_hi[2], vs_lo[2], vs_hi[2], hs_n[2], vs_n[2], vps[2], pbad[2], pok[2]);

  // One frame of the raster: 848 x 440 dots of 47.5 ns (19/400 us) = 17.7232 ms.
  localparam longint FRAME_PS = 64'd848 * 64'd440 * 64'd47_500;
  integer fails = 0;
  integer sys_mhz [3] = '{80, 100, 120};

  // ==== CHECKS ====
  task automatic check_mode(input string name, input integer vclk_exp_ps, input integer ce_n,
                            input integer hs_n_exp, input integer vs_n_exp, input integer lines);
    for (int i = 0; i < 3; i++) begin
      $display("  %s @ clk_sys %0d MHz: video clock %0d ps, CE %0d..%0d, hsync %0d..%0d (%0d lines), vsync %0d..%0d (%0d frames), %0d/%0d pixels right",
               name, sys_mhz[i], vps[i], ce_lo[i], ce_hi[i], hs_lo[i], hs_hi[i], hs_n[i], vs_lo[i], vs_hi[i], vs_n[i], pok[i], pok[i] + pbad[i]);
      if (vps[i] != 32'(vclk_exp_ps)) begin
        $display("FAIL %s @ %0d MHz: the video clock is %0d ps, expected %0d ps", name, sys_mhz[i], vps[i], vclk_exp_ps);
        fails++;
      end
      if (ce_lo[i] != 32'(ce_n) || ce_hi[i] != 32'(ce_n)) begin
        $display("FAIL %s @ %0d MHz: the pixel period is %0d..%0d video clocks, expected exactly %0d",
                 name, sys_mhz[i], ce_lo[i], ce_hi[i], ce_n);
        fails++;
      end
      if (hs_lo[i] != 32'(hs_n_exp) || hs_hi[i] != 32'(hs_n_exp) || hs_n[i] < 32'(lines)) begin
        $display("FAIL %s @ %0d MHz: the line period is %0d..%0d video clocks over %0d lines, expected exactly %0d over at least %0d",
                 name, sys_mhz[i], hs_lo[i], hs_hi[i], hs_n[i], hs_n_exp, lines);
        fails++;
      end
      if (pbad[i] != 0 || pok[i] < 32'(lines / 2 * 640)) begin
        $display("FAIL %s @ %0d MHz: %0d active pixels are not the raster's, %0d are", name, sys_mhz[i], pbad[i], pok[i]);
        fails++;
      end
      if (vs_lo[i] != 32'(vs_n_exp) || vs_hi[i] != 32'(vs_n_exp) || vs_n[i] < 2) begin
        $display("FAIL %s @ %0d MHz: the frame period is %0d..%0d video clocks over %0d frames, expected exactly %0d",
                 name, sys_mhz[i], vs_lo[i], vs_hi[i], vs_n[i], vs_n_exp);
        fails++;
      end
    end
  endtask

  // The doubled picture over a long run: no FIFO event, every frame 2 x 440 lines with a 3-line
  // VSYNC, every VS edge on an HS leading edge, and no DE inside HS or VS.
  task automatic check_long(input integer i, input integer fifo_ev, input integer vs_off, input integer de_sync,
                            input integer lpf_lo, input integer lpf_hi, input integer vsw_lo, input integer vsw_hi,
                            input integer frames);
    $display("  long doubled @ %0d MHz: %0d frames, %0d..%0d lines a frame, VSYNC %0d..%0d lines, %0d FIFO events, %0d VS edges off an HS leading edge, %0d DE samples inside HS/VS",
             sys_mhz[i], frames, lpf_lo, lpf_hi, vsw_lo, vsw_hi, fifo_ev, vs_off, de_sync);
    if (frames < 99 || lpf_lo != 880 || lpf_hi != 880 || vsw_lo != 3 || vsw_hi != 3 ||
        fifo_ev != 0 || vs_off != 0 || de_sync != 0) begin
      $display("FAIL long doubled @ %0d MHz", sys_mhz[i]);
      fails++;
    end
  endtask

  task automatic run_mode(input bit dbl);
    measure = 1'b0;
    run_dbl = dbl;
    #(FRAME_PS * 3);         // settle: the FIFO prime, a whole frame of the mode
    measure = 1'b1;
    #(FRAME_PS * 3 + FRAME_PS / 10);
    measure = 1'b0;
    #1000;
  endtask

  initial begin
    // Native: 2 video clocks a dot at 2 x 400/19 MHz.
    run_mode(1'b0);
    check_mode("native", 23_750, 2, 2 * 848, 2 * 848 * 440, 1200);
    // Doubled: every video clock is a pixel; two lines per GDC line.
    run_mode(1'b1);
    check_mode("doubled", 23_750, 1, 848, 2 * 848 * 440, 2400);
    // ---- the long run: 100 frames of the doubled picture ----
    measure = 1'b0;
    run_dbl = 1'b1;
    #(FRAME_PS * 3);
    measure = 1'b1;
    #(FRAME_PS * 100 + FRAME_PS / 10);
    measure = 1'b0;
    $display("  scaler framing (DE lines between VS leading edges): 80 MHz %0d..%0d, 100 MHz %0d..%0d, 120 MHz %0d..%0d",
             l80.dlpf_lo, l80.dlpf_hi, l100.dlpf_lo, l100.dlpf_hi, l120.dlpf_lo, l120.dlpf_hi);
    if (l80.dlpf_lo != 800 || l80.dlpf_hi != 800 || l100.dlpf_lo != 800 || l100.dlpf_hi != 800 ||
        l120.dlpf_lo != 800 || l120.dlpf_hi != 800) begin
      $display("FAIL: the doubled picture is not 800 DE lines in every VS-delimited frame");
      fails++;
    end
    check_long(0, l80.n_fifo_ev,  l80.n_vs_off,  l80.n_de_sync,  l80.lpf_lo,  l80.lpf_hi,  l80.vsw_lo,  l80.vsw_hi,  l80.n_frames);
    check_long(1, l100.n_fifo_ev, l100.n_vs_off, l100.n_de_sync, l100.lpf_lo, l100.lpf_hi, l100.vsw_lo, l100.vsw_hi, l100.n_frames);
    check_long(2, l120.n_fifo_ev, l120.n_vs_off, l120.n_de_sync, l120.lpf_lo, l120.lpf_hi, l120.vsw_lo, l120.vsw_hi, l120.n_frames);
    check_mode("doubled, 100 frames", 23_750, 1, 848, 2 * 848 * 440, 100 * 880);
    // ==== VERDICT ====
    if (fails != 0) $fatal(1, "TB_PC9821_VIDEO_CLK: %0d check(s) failed", fails);
    $display("TB_PC9821_VIDEO_CLK: PASS");
    $finish;
  end
endmodule

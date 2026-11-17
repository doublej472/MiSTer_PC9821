`timescale 1ns / 1ps

// tb_pc9821_raster_hold — the raster runs through a held reset and a pack load, and the guest still starts on a restarted raster.
//
// ==== WHAT THIS PROVES ====
// With the reset path as the top and pc9821_system wire it (reset_req through pc9821_reset_align, the three-stage synchroniser, a reset-copy stage, pc9821_raster_reseed, the real pc9821_dot_ce at 90 MHz and pc9821_crtc on its defsyncm24 raster, its configuration held by `reset || !cpu_run_crtc`), a core load (the reset request held for 12 frames from power-up while the pack loads, cpu_run_ld rising at an arbitrary dot), 12 keyboard-style holds of 1..6 frames, 12 OSD-style one-clock pulses and 4 second pack loads (cpu_run_ld falling and rising again) at arbitrary raster positions leave every frame the framework's resolution detector closes (sys/hps_io.sv video_calc: the first DE line's width and the DE lines outside VSYNC) at 640 x 400 and every frame's length within 10 clocks of the first (the low-latency HDMI PLL, sys/pll_hdmi_adj.vhd, steers from each frame's length), with one resolution report in all (the first); and on the guest's first clock out of every machine reset the position counter is at 0,0 and the dot accumulator at 0, and on cpu_run's rise and the clock after it the counter is at 0,0 - the restart a reset held the raster in (NP2kai pccore_reset). With the counter held through the reset (the wiring before this fix) a held reset stops the raster and closes a long frame, and with cpu_run not held to the frame end a pack load cuts one: both fail here.
//
// Expected values: the defsyncm24 block (NP2kai io/gdc.c:42) is 640 active dots in an 848-dot line and
// 400 active lines in a 440-line frame; the dot enable is 400/19 MHz from 90 MHz (pc9821_dot_ce),
// so a frame is 848 x 440 x 90 / (400/19) = 1 595 088 clocks give or take one.

module tb_pc9821_raster_hold;

  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;

  // ==== THE RESET PATH (z486_mister.sv + pc9821_system.sv) ====
  reg  req = 1'b0;          // reset_req
  reg  platform = 1'b1;     // reset_async (power-up)
  wire wrap, go, waiting;
  reg [2:0] sync_r = 3'b111;   // the top's reset synchroniser
  pc9821_reset_align #(.TIMEOUT(4_000_000)) align (.clk(clk_sys), .req(req), .wrap(wrap), .active(sync_r[1]), .go(go), .waiting(waiting));
  always @(posedge clk_sys or posedge platform)
    if (platform) sync_r <= 3'b111;
    else          sync_r <= go ? 3'b111 : {sync_r[1:0], 1'b0};
  wire reset = sync_r[2];
  reg  rst_q = 1'b1;        // pc9821_reset_tree: one register per block
  always @(posedge clk_sys) rst_q <= reset;

  reg  cpu_run_ld = 1'b0;   // the loader's cpu_run
  wire cpu_run, cpu_run_crtc, reseed_cnt, reseed_dot;
  pc9821_raster_reseed reseed (
    .clk(clk_sys), .reset(reset), .rst_q(rst_q), .cpu_run_ld(cpu_run_ld), .frame_end(wrap),
    .cpu_run(cpu_run), .cpu_run_crtc(cpu_run_crtc), .reseed_cnt(reseed_cnt), .reseed_dot(reseed_dot)
  );
  wire pixel_ce;
  pc9821_dot_ce #(.SYS_FREQ(90_000_000)) dot_ce (.clk(clk_sys), .reset(reseed_dot), .c31(1'b0), .ce(pixel_ce));

  // ==== DUT ====
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_addr = 8'h60, io_din = 0;
  wire [7:0] io_dout;
  wire hs_out, vs_out, de_out;
  pc9821_crtc crtc (
    .clk_sys(clk_sys), .rst_n_sys(!(rst_q || !cpu_run_crtc)), .rst_n_vid(!reseed_cnt), .pixel_ce(pixel_ce),
    .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
    .o_frame_end(wrap), .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
  );

  // ==== CHECKS ====
  // THE FRAMEWORK'S DETECTOR (video_calc's ce_pix block, syncs made active high)
  wire vs = !vs_out;
  reg  old_vs = 0, old_de = 0, calch = 0;
  integer hcnt = 0, vcnt = 0, frames = 0, bad = 0, p_h = -1, p_v = -1, resto = 0, nres = 0;
  longint unsigned cyc = 0, f_start = 0, f_len = 0, f_nom = 0;
  integer mislen = 0, f_lo = 1 << 30, f_hi = 0;
  always @(posedge clk_sys) cyc <= cyc + 1;
  always @(posedge clk_sys) if (pixel_ce) begin
    old_vs <= vs;
    old_de <= de_out;
    if (!vs && !old_de && de_out) vcnt = vcnt + 1;
    if (calch && de_out) hcnt = hcnt + 1;
    if (old_de && !de_out) calch <= 1'b0;
    if (old_vs && !vs) begin
      frames = frames + 1;
      f_len = cyc - f_start;
      f_start = cyc;
      if (frames == 3) f_nom = f_len;
      if (frames > 2 && (hcnt != 640 || vcnt != 400)) begin
        bad = bad + 1;
        $display("FRAME %0d differs: %0d x %0d", frames, hcnt, vcnt);
      end
      if (frames > 3) begin
        if (integer'(f_len) < f_lo) f_lo = integer'(f_len);
        if (integer'(f_len) > f_hi) f_hi = integer'(f_len);
        if (f_len + 10 < f_nom || f_len > f_nom + 10) begin
          mislen = mislen + 1;
          $display("FRAME %0d length %0d, the first %0d", frames, f_len, f_nom);
        end
      end
      if (hcnt != 0 && vcnt != 0) begin
        if (resto != 0) resto = resto + 1;
        if (hcnt != p_h || vcnt != p_v) resto = 1;
        if (resto == 15) begin nres = nres + 1; resto = 0; end
        p_h = hcnt; p_v = vcnt;
      end
      hcnt = 0; vcnt = 0;
      calch <= 1'b1;
    end
  end
  // THE GUEST'S START: the first clock out of each machine reset, cpu_run's rise and the clock after
  reg rst_q_d = 1'b1, run_d1 = 1'b0, run_d2 = 1'b0;
  integer starts = 0, runs = 0, start_bad = 0;
  always @(posedge clk_sys) begin
    rst_q_d <= rst_q;
    run_d1  <= cpu_run;
    run_d2  <= run_d1;
    if (rst_q_d && !rst_q && !platform) begin
      starts = starts + 1;
      if (crtc.hdot != 0 || crtc.vline != 0 || dot_ce.acc != 0) begin
        start_bad = start_bad + 1;
        $display("RESET RELEASE %0d: counter %0d,%0d acc %0d", starts, crtc.hdot, crtc.vline, dot_ce.acc);
      end
    end
    if (run_d1 && !run_d2) begin
      runs = runs + 1;
      if (crtc.hdot != 0 || crtc.vline != 0) begin
        start_bad = start_bad + 1;
        $display("CPU_RUN RISE %0d: counter %0d,%0d one clock after", runs, crtc.hdot, crtc.vline);
      end
    end
  end

  // ==== STIMULUS ====
  localparam integer FRAME_CLK = 1_595_088;
  integer i, k, seed = 32'h5eed_0003;
  task automatic wait_rand(input integer lo);
    repeat (lo + ($urandom(seed) % FRAME_CLK)) @(posedge clk_sys);
    seed = seed + 1;
  endtask
  initial begin
    // the core load: the platform reset, then Main_MiSTer's reset bit held while the pack loads
    req = 1'b1;
    repeat (20) @(posedge clk_sys);
    platform = 1'b0;
    repeat (6 * FRAME_CLK + 12345) @(posedge clk_sys);
    cpu_run_ld = 1'b1;                                   // the pack has landed
    repeat (6 * FRAME_CLK + 777) @(posedge clk_sys);
    req = 1'b0;                                          // Main releases the reset bit
    repeat (3 * FRAME_CLK) @(posedge clk_sys);
    for (i = 0; i < 28; i = i + 1) begin
      wait_rand(1000);
      k = i % 7;
      if (k < 3) begin                                   // a held request (the keyboard combo)
        req = 1'b1;
        repeat (FRAME_CLK * (1 + i % 6) + 333 * i) @(posedge clk_sys);
        req = 1'b0;
      end else if (k < 6) begin                          // the OSD's one-clock pulse
        req = 1'b1;
        @(posedge clk_sys);
        req = 1'b0;
      end else begin                                     // a second pack load
        cpu_run_ld = 1'b0;
        repeat (FRAME_CLK / 3 + 4321 * i) @(posedge clk_sys);
        cpu_run_ld = 1'b1;
      end
      repeat (3 * FRAME_CLK) @(posedge clk_sys);
    end
    repeat (20 * FRAME_CLK) @(posedge clk_sys);
    $display("frames=%0d differing=%0d mislength=%0d (length %0d..%0d, first %0d) reports=%0d resets=%0d cpu_run_rises=%0d start_bad=%0d",
             frames, bad, mislen, f_lo, f_hi, f_nom, nres, starts, runs, start_bad);
    // ==== VERDICT ====
    if (bad == 0 && mislen == 0 && nres == 1 && start_bad == 0 && starts == 24 + 1 && runs == 1 + 4) begin
      $display("TB_PC9821_RASTER_HOLD: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_RASTER_HOLD: FAIL");
  end

  initial begin
    #6_000_000_000;
    $fatal(1, "TB_PC9821_RASTER_HOLD: TIMEOUT");
  end

endmodule

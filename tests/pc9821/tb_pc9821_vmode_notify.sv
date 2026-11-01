`timescale 1ps/1ps

// ==== WHAT THIS PROVES ====
// A guest switch between the 24 kHz and the 31 kHz raster makes the framework re-report the video mode on the native path, where both rasters are 640 x 400 active: with pc9821_video_out (doubler built, the OSD at Native) carrying the BIOS 24 kHz raster (848 x 440, NP2kai bios/bios18.c gdcmastersync[1]) and then the 31 kHz one (800 x 449, gdcmastersync[2]) into the framework's own video_calc (sys/hps_io.sv, its new_vmode fed from video_out's vmode_31), with the video side flushed for the relock in the vertical blank as pc9821_vpll_ctl does, so that no active line is lost and the active count (hcnt 640 pixels on the first line, vcnt 400 lines) is the same in both modes, every switch (24 to 31 kHz and back) bumps vid_nres by exactly one and re-takes vid_fclks as the new frame's length in video clocks (800 x 449 x 2 = 718 400 at 31 kHz, 848 x 440 x 2 = 746 240 at 24 kHz), and 20 steady frames in one mode bump it by none. FAIL-FIRST: with new_vmode tied to 0 (the top level's old wiring) the active count is all video_calc compares, so no switch is reported and vid_fclks keeps the 24 kHz frame's 746 240 after the switch to 31 kHz.
//
// WHY. Main_MiSTer takes the core's frame timing from video_calc (vid_fclks and the new-resolution
// counter vid_nres, read over the HPS bus) and tunes the HDMI output to it (vsync_adjust); a 70 Hz
// core left reported as 56 Hz drops or judders frames.
//
// THE FIGURES are the BIOS SYNC blocks' geometry (the same blocks tb_pc9821_crt31k_video drives) and
// hps_io's own counting rule (sys/hps_io.sv:957 `old_vmode != new_vmode`, and the report after the
// 15-frame timeout), never read out of the DUT.
//
// WHAT IT IS BLIND TO: the video PLL's frequency change (clk_vid is one fixed clock here, equal to
// clk_sys, so the crossing FIFO cannot drift; tb_pc9821_crt31k_video covers the relock) and what
// Main_MiSTer does with the report.

module tb_pc9821_vmode_notify;
  // ---- clk_sys and clk_vid: the same 40 MHz, a quarter period apart; the dot every 2nd clock ----
  reg clk_sys = 1'b0;
  always #12500 clk_sys = ~clk_sys;
  reg clk_vid = 1'b0;
  initial begin #6250; forever #12500 clk_vid = ~clk_vid; end
  reg clk_100 = 1'b0;
  always #5000 clk_100 = ~clk_100;

  reg ce = 1'b0;
  always @(posedge clk_sys) ce <= ~ce;

  // ---- the raster, switched at a frame boundary as pc9821_crtc latches a SYNC block ----
  // 24 kHz gdcmastersync[1]: 848 x 440, HFP 80 / HS 64, VFP 7 / VS 8.
  // 31 kHz gdcmastersync[2]: 800 x 449, HFP 32 / HS 64, VFP 13 / VS 2.
  reg       c31 = 1'b0;                 // what the guest asked for (0x09A8 bit 0)
  reg       g31 = 1'b0;                 // what the raster is running
  wire [9:0] HT  = g31 ? 10'd800 : 10'd848;
  wire [9:0] HFP = g31 ? 10'd32  : 10'd80;
  wire [9:0] VT  = g31 ? 10'd449 : 10'd440;
  wire [9:0] VFP = g31 ? 10'd13  : 10'd7;
  wire [9:0] VSW = g31 ? 10'd2   : 10'd8;
  localparam [9:0] HA = 10'd640, HSW = 10'd64, VA = 10'd400;
  reg [9:0] hx = '0, vy = '0;
  reg       r_hs = 1'b1, r_vs = 1'b1, r_de = 1'b0;
  always @(posedge clk_sys) if (ce) begin
    hx   <= (hx == HT - 1) ? 10'd0 : hx + 10'd1;
    if (hx == HT - 1) begin
      vy <= (vy == VT - 1) ? 10'd0 : vy + 10'd1;
      if (vy == VT - 1) g31 <= c31;
    end
    r_hs <= ~((hx >= HA + HFP) && (hx < HA + HFP + HSW));
    r_vs <= ~((vy >= VA + VFP) && (vy < VA + VFP + VSW));
    r_de <= (hx < HA) && (vy < VA);
  end

  // ---- the relock as the video side sees it: vclk_31 and busy move together (pc9821_vpll_ctl) ----
  reg vclk_31 = 1'b0, busy = 1'b0;

  // ==== DUT ====
  wire       ce_out, hs_out, vs_out, de_out, dbl_active, fifo_ev, vmode_31;
  wire [7:0] r_out, g_out, b_out;
  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_video_out #(.DBL_EN(1'b1)) dut (
    .clk_sys(clk_sys), .ce(ce),
    .r_in(hx[7:0]), .g_in(vy[7:0]), .b_in(8'd0), .hs_in(r_hs), .vs_in(r_vs), .de_in(r_de),
    .dbl_on(1'b0),                                  // the OSD at Native
    .clk_vid(clk_vid), .vclk_31(vclk_31), .vid_rst(busy),
    .clk_video(), .ce_out(ce_out),
    .r_out(r_out), .g_out(g_out), .b_out(b_out), .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out),
    .dbl_active(dbl_active), .vmode_31(vmode_31), .fifo_ev(fifo_ev)
  );

  // ---- the framework's measurement, as hps_io instantiates it (clk_vid = CLK_VIDEO) ----
  // sys_top hands it the syncs after its polarity fixers (sys/sys_top.v:1707 `sync_fix sync_v(clk_vid,
  // vs_emu, vs_fix);`), which turn them active HIGH; the core's are active low (pc9821_crtc), so they
  // are inverted here.
  video_calc vc (
    .clk_100(clk_100), .clk_vid(clk_vid), .clk_sys(clk_sys),
    .ce_pix(ce_out), .de(de_out), .hs(~hs_out), .vs(~vs_out), .vs_hdmi(1'b1), .f1(1'b0),
    .new_vmode(vmode_31), .video_rotated(1'b0),
    .par_num(5'd0), .dout()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  initial begin
    #(4.0e12);
    $fatal(1, "TB_PC9821_VMODE_NOTIFY: watchdog (4 s simulated)");
  end

  // ==== CHECKS ====
  integer errors = 0;
  task automatic check(input bit ok, input string what);
    if (!ok) begin $display("FAIL: %0s", what); errors++; end
    else $display("  ok   %0s", what);
  endtask
  task automatic wait_frames(input integer n);
    integer i;
    for (i = 0; i < n; i++) @(negedge r_vs);
  endtask
  // The switch: the guest's write, then the relock's flush two lines into the back porch after the
  // current frame's VSYNC (no active line lost), vclk_31 moving with busy, and the raster taking
  // the new block at its next frame boundary.
  task automatic switch_to(input bit to31);
    integer i;
    begin
      @(negedge r_vs);
      @(posedge r_vs);
      repeat (2) @(negedge r_hs);
      @(posedge clk_sys);
      c31 = to31;
      vclk_31 = to31;
      busy = 1'b1;
      for (i = 0; i < 2 * 848 * 2; i++) @(posedge clk_sys);
      busy = 1'b0;
    end
  endtask

  integer nres0;
  initial begin
    // ---- power-up at 24 kHz: the first report (15 frames' timeout), then 20 steady frames ----
    wait_frames(25);
    nres0 = vc.vid_nres;
    check(nres0 >= 1, $sformatf("power-up: the framework has reported the 24 kHz mode (vid_nres %0d)", nres0));
    check(vc.vid_hcnt == 640 && vc.vid_vcnt == 400 && vc.vid_fclks == 848 * 440 * 2,
          $sformatf("24 kHz: hcnt %0d vcnt %0d fclks %0d (want 640, 400, 746240)",
                    vc.vid_hcnt, vc.vid_vcnt, vc.vid_fclks));
    wait_frames(20);
    check(vc.vid_nres == nres0, $sformatf("24 kHz: 20 steady frames report nothing (vid_nres %0d -> %0d)", nres0, vc.vid_nres));

    // ---- to 31 kHz ----
    switch_to(1'b1);
    wait_frames(20);
    check(!dbl_active, "31 kHz: native (the doubler is not running)");
    check(vc.vid_hcnt == 640 && vc.vid_vcnt == 400,
          $sformatf("31 kHz: the active area is unchanged (hcnt %0d vcnt %0d)", vc.vid_hcnt, vc.vid_vcnt));
    check(vc.vid_nres == nres0 + 1, $sformatf("31 kHz: the switch is reported once (vid_nres %0d -> %0d)", nres0, vc.vid_nres));
    check(vc.vid_fclks == 800 * 449 * 2, $sformatf("31 kHz: fclks %0d (want 718400)", vc.vid_fclks));
    wait_frames(20);
    check(vc.vid_nres == nres0 + 1, $sformatf("31 kHz: 20 steady frames report nothing (vid_nres %0d)", vc.vid_nres));

    // ---- back to 24 kHz ----
    switch_to(1'b0);
    wait_frames(20);
    check(vc.vid_hcnt == 640 && vc.vid_vcnt == 400,
          $sformatf("24 kHz again: the active area is unchanged (hcnt %0d vcnt %0d)", vc.vid_hcnt, vc.vid_vcnt));
    check(vc.vid_nres == nres0 + 2, $sformatf("24 kHz again: the switch is reported once (vid_nres %0d)", vc.vid_nres));
    check(vc.vid_fclks == 848 * 440 * 2, $sformatf("24 kHz again: fclks %0d (want 746240)", vc.vid_fclks));

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_VMODE_NOTIFY: %0d check(s) failed", errors);
    $display("TB_PC9821_VMODE_NOTIFY: PASS");
    $finish;
  end
endmodule

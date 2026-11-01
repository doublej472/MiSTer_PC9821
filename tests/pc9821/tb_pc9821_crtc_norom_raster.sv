`timescale 1ns / 1ps

// tb_pc9821_crtc_norom_raster — the power-on raster runs with the CPU held (`rst_n_sys = 0`).
//
// ==== WHAT THIS PROVES ====
// With the system reset half asserted (rst_n_sys = 0, the state while cpu_run is low because no firmware pack has loaded) and only the raster position counter's own reset released (rst_n_vid = !reset), the CRTC still emits the machine's power-on defsyncm24 raster - hs_out pulses once per line for 64 dots and vs_out once per frame for 8 lines, 848 dots and 440 lines to the frame (NP2kai io/gdc.c:42) - so the framework measures a nonzero mode and the analog OSD, which is drawn in the core's own timing, can be placed to load a ROM with no pack, while the GDC reset status the ITF polls is unchanged (o_stat_blank stays 1 and o_stat_vsync stays 0, the status flops remaining on rst_n_sys).
//
// Expected values from the reference: NP2kai's defsyncm24 block {10 4e 07 25 07 07 90 65}
// (io/gdc.c:42) gives 848x440 total / 640x400 active, HFP 80, HSYNC 64 and HBP 64 dots (the
// uPD7220 field map, MAME upd7220.cpp:1243-1246), VFP 7 and an 8-line VSYNC pulse rising on vline
// 407 (the same arithmetic tb_pc9821_gdc_sync_raster transcribes). Before the fix the raster
// counter resets on rst_n_sys, so with rst_n_sys = 0 hs_out/vs_out never toggle and this fails.

module tb_pc9821_crtc_norom_raster;

  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;

  // The state tested: the machine reset released, but the firmware pack not loaded, so
  // rst_n_sys is held low for the whole run. rst_n_vid (the counter's own reset) is released.
  reg rst_n_sys = 0;
  reg rst_n_vid = 0;

  reg        io_wr = 0;
  reg        io_rd = 0;
  reg  [7:0] io_addr = 8'h60;
  reg  [7:0] io_din = 0;
  wire [7:0] io_dout;

  // ==== DUT ====
  wire hs_out, vs_out, de_out, o_stat_blank, o_stat_vsync;
  pc9821_crtc dut (
      .clk_sys(clk_sys),
      .rst_n_sys(rst_n_sys),
      .rst_n_vid(rst_n_vid),
      .pixel_ce(1'b1),
      .io_wr(io_wr),
      .io_rd(io_rd),
      .io_addr(io_addr),
      .io_din(io_din),
      .io_dout(io_dout),
      .o_stat_blank(o_stat_blank),
      .o_stat_vsync(o_stat_vsync),
      .hs_out(hs_out),
      .vs_out(vs_out),
      .de_out(de_out)
  );

  // ==== CHECKS ====
  integer errors = 0;
  integer i;
  integer found;
  integer hs_edges, vs_edges, de_edges;
  integer hs_low, vs_low;
  integer stat_bad;
  reg prev_hs, prev_vs, prev_de;

  localparam integer HTOTAL     = 848;   // defsyncm24: 8 * x, x = 106
  localparam integer VTOTAL     = 440;   // defsyncm24: y
  localparam integer HSYNC_DOTS = 64;    // HSYNC_W, the block's hs field
  localparam integer VSYNC_LINES= 8;     // VSYNC_W, the block's vs field
  localparam integer FRAME_DOTS = HTOTAL * VTOTAL;

  initial begin
    // The counter's own reset released; rst_n_sys stays 0 for the whole run.
    repeat (8) @(negedge clk_sys);
    rst_n_vid = 1'b1;

    // Align on the end of a VSYNC pulse (bounded, so the no-raster case fails with a
    // diagnostic rather than only through the watchdog), then count exactly two whole frames.
    found = 0;
    prev_vs = vs_out;
    for (i = 0; i < 2 * FRAME_DOTS && !found; i = i + 1) begin
      @(negedge clk_sys);
      if (vs_out === 1'b1 && prev_vs === 1'b0) found = 1;
      prev_vs = vs_out;
    end
    prev_hs = hs_out; prev_vs = vs_out; prev_de = de_out;
    hs_edges = 0; vs_edges = 0; de_edges = 0;
    hs_low = 0; vs_low = 0; stat_bad = 0;
    for (i = 0; i < 2 * FRAME_DOTS; i = i + 1) begin
      @(negedge clk_sys);
      if (hs_out != prev_hs) hs_edges = hs_edges + 1;
      if (vs_out != prev_vs) vs_edges = vs_edges + 1;
      if (de_out != prev_de) de_edges = de_edges + 1;
      if (!hs_out) hs_low = hs_low + 1;   // hs_out is negative polarity
      if (!vs_out) vs_low = vs_low + 1;
      if (o_stat_blank !== 1'b1 || o_stat_vsync !== 1'b0) stat_bad = stat_bad + 1;
      prev_hs = hs_out; prev_vs = vs_out; prev_de = de_out;
    end

    $display("aligned %0d; hs edges %0d low %0d (want ~%0d); vs edges %0d low %0d (want ~%0d); de edges %0d; status_bad %0d",
             found, hs_edges, hs_low, 2 * VTOTAL * HSYNC_DOTS,
             vs_edges, vs_low, 2 * VSYNC_LINES * HTOTAL,
             de_edges, stat_bad);

    // The raster runs at all: both syncs toggle over the two frames. Before the fix they are
    // constant (hs_edges == vs_edges == 0) and no VSYNC pulse completes at all.
    if (!found) begin
      $display("FAIL: vs_out never completed a VSYNC pulse within two frames with rst_n_sys=0 (no raster)");
      errors = errors + 1;
    end
    if (hs_edges == 0) begin
      $display("FAIL: hs_out never toggled over two frames with rst_n_sys=0 (no raster)");
      errors = errors + 1;
    end
    if (vs_edges == 0) begin
      $display("FAIL: vs_out never toggled over two frames with rst_n_sys=0 (no raster)");
      errors = errors + 1;
    end
    // The defsyncm24 geometry: hs_out low 64 dots a line (880 lines), vs_out low 8 lines a
    // frame (2 frames). Allow one line of alignment slack.
    if (hs_low < 2 * VTOTAL * HSYNC_DOTS - 2 * HSYNC_DOTS ||
        hs_low > 2 * VTOTAL * HSYNC_DOTS + 2 * HSYNC_DOTS) begin
      $display("FAIL: hs_out low %0d dots over two frames, want %0d (64 dots x 880 lines)",
               hs_low, 2 * VTOTAL * HSYNC_DOTS);
      errors = errors + 1;
    end
    if (vs_low < 2 * VSYNC_LINES * HTOTAL - HTOTAL ||
        vs_low > 2 * VSYNC_LINES * HTOTAL + HTOTAL) begin
      $display("FAIL: vs_out low %0d dots over two frames, want %0d (8 lines x 848 dots x 2)",
               vs_low, 2 * VSYNC_LINES * HTOTAL);
      errors = errors + 1;
    end
    // The display enable moves with the raster too.
    if (de_edges == 0) begin
      $display("FAIL: de_out never toggled over two frames with rst_n_sys=0");
      errors = errors + 1;
    end
    // The GDC reset status is UNCHANGED: the status flops stay on rst_n_sys.
    if (o_stat_blank !== 1'b1) begin
      $display("FAIL: o_stat_blank is not 1 with rst_n_sys=0");
      errors = errors + 1;
    end
    if (o_stat_vsync !== 1'b0) begin
      $display("FAIL: o_stat_vsync is not 0 with rst_n_sys=0");
      errors = errors + 1;
    end
    if (stat_bad != 0) begin
      $display("FAIL: o_stat_blank/o_stat_vsync moved off the reset status %0d times", stat_bad);
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CRTC_NOROM_RASTER: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_CRTC_NOROM_RASTER: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_CRTC_NOROM_RASTER: TIMEOUT");
  end

endmodule

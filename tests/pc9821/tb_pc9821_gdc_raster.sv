`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The text GDC's raster is the machine's 24 kHz mode, measured in dots off the module's own sync outputs: 848 dots per line of which 640 are active, 440 lines per frame of which 400 are active, which at the machine's 21.0526 MHz dot clock is a 24.83 kHz horizontal rate and a 56.42 Hz vertical rate, so a raster of the wrong size fails while a different but still correct blanking arrangement does not.
//
// ---- the bench's own account of where each expectation comes from ----
// THE MACHINE, not the RTL, and every number is a machine property:
//  * the PC-98's 24 kHz text mode is 848 dots x 440 lines with 640 x 400 active. The module header
//    states it and cites its own provenance ("Geometry and timing are described in
//    notes/06-gdc-video.md"), and marks the geometry line "verified in note 12 section 4".
//  * the dot clock is 21.0526 MHz: the PC-98's standard text dot rate, and the one this core's
//    pixel enable is built to produce - pc9821_system.sv derives it as 50 MHz * 7063303/2^24 =
//    21.0526347 MHz (0.15 ppm high) and names the frame rate that implies, 848 * 440 * 56.42 Hz.
//  * so hsync = 21.0526e6 / 848 = 24 826 Hz, and vsync = 24 826 / 440 = 56.42 Hz.
// THE RATES ARE COMPUTED FROM THE MACHINE'S DOT CLOCK, NOT FROM THIS BENCH'S. The bench drives one
// clk_vid_ce per cycle, so its dot rate is the machine's by construction and every count it takes
// is in DOTS; that makes the assertion a statement about the machine's raster rather than about
// the simulator's clock.
//
// WHY THIS EXISTS: a bench audit's gap G7 - "No bench asserts the 24 kHz
// raster, the frame rate, or that the pixel enable produces the right dot rate. gdc_text checks a
// hdot hold and VSYNC pulses, but nothing asserts the RATE that the games' fades and raster effects
// depend on." Rated medium-high damage for games, and ReC98's vsync/raster work measures in these
// units.
//
// WHAT IT IS BLIND TO, stated rather than implied: it does not check the dot clock itself (that is
// generated in pc9821_system.sv, outside this module), it does not check 40-column doubling, and
// it does not check the vertical interrupt's phase within the frame.

module tb_pc9821_gdc_raster;
  // One clk_vid_ce per cycle: one assert = one dot, so every count below is in dots.
  reg clk_vid = 0;
  always #10 clk_vid = ~clk_vid;      // 50 MHz gating clock; ce decides the dot rate

  reg rst_n = 0;

  wire [7:0]  io_dout;
  wire [7:0]  cg_win_dout;
  wire [18:0] font_req_addr; wire font_req;
  wire vsync_active, vsync_irq, disp_on, gfx_access_page, gfx_disp, gfx_egc_gate;
  wire [15:0] dbg_sad; wire [7:0] dbg_pitch; wire dbg_col40, dbg_disp;
  wire text_opaque, text_cell, pix_h_active, pix_v_active, gfx_mode16;
  wire [31:0] gfx_dig;
  // The analogue palette table's CPU write port (pc9821_gfx_palette's RAM).
  wire        pal_wr_en;
  wire [3:0]  pal_wr_idx;
  wire [1:0]  pal_wr_chan;
  wire [3:0]  pal_wr_data;
  wire        pal_commit;
  wire [15:0] gfx_line_addr;
  wire [7:0]  tram_cpu_dout;
  wire hs_out, vs_out, de_out;

  // ==== DUT ====
  pc9821_gdc_text_dut dut (
      .clk_sys(clk_vid), .rst_n_sys(rst_n),
      .cfg_fdd_mode(3'd0),   // entry 0: the measured boot/FDD nibble
      .pixel_ce(1'b1),
      .io_wr(1'b0), .io_rd(1'b0), .io_addr(8'h00), .io_din(8'h00), .io_dout(io_dout),
      .tram_cpu_addr(14'd0), .tram_cpu_din(8'h00), .tram_cpu_we(1'b0),
      .tram_cpu_dout(tram_cpu_dout),
      .font_ld_addr(11'd0), .font_ld_data(16'd0), .font_ld_we(1'b0),
      .cg_win_byte_sel(5'd0), .cg_win_rd(1'b0),
      .cg_win_dout(cg_win_dout), .cg_win_din(8'h00), .cg_win_we(1'b0),
      .font_req_addr(font_req_addr), .font_req(font_req),
      .font_word_valid(1'b0), .font_word_data(32'hFFFF_FFFF),
      .cg_record_restore(1'b0),
      .cfg_seed_reload(1'b0),
      .vsync_active(vsync_active), .vsync_irq_arm(1'b0),
      .vsync_irq(vsync_irq), .disp_on(disp_on), .gfx_access_page(gfx_access_page),
      .gfx_disp(gfx_disp), .gfx_line_addr(gfx_line_addr), .gfx_egc_gate(gfx_egc_gate),
      .dbg_sad(dbg_sad), .dbg_pitch(dbg_pitch), .dbg_col40(dbg_col40), .dbg_disp(dbg_disp),
      .text_opaque(text_opaque), .text_cell(text_cell),
      .pix_h_active(pix_h_active), .pix_v_active(pix_v_active), .gfx_mode16(gfx_mode16),
      .gfx_dig(gfx_dig),
      .pal_wr_en(pal_wr_en), .pal_wr_idx(pal_wr_idx),
      .pal_wr_chan(pal_wr_chan), .pal_wr_data(pal_wr_data), .pal_commit(pal_commit),
      .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
  );

  // ==== CHECKS ====

  integer errors = 0;
  task automatic fail(input [8*112-1:0] message); begin
    $display("FAIL: %0s @ %0t", message, $time); errors = errors + 1;
  end endtask

  // The machine's raster, in dots and lines, and the dot clock it is counted against.
  localparam integer H_ACTIVE_WANT  = 640;
  localparam integer V_ACTIVE_WANT  = 400;
  localparam integer LINE_WANT      = 848;
  localparam integer LINES_WANT     = 440;
  localparam real    DOT_HZ         = 21.0526e6;
  localparam real    H_WANT_HZ      = DOT_HZ / 848.0;      // 24 826 Hz
  localparam real    V_WANT_HZ      = H_WANT_HZ / 440.0;   // 56.42 Hz

  // ---- edge detectors over the negative-polarity sync outputs ----
  reg hs_d, vs_d;
  always @(posedge clk_vid) begin hs_d <= hs_out; vs_d <= vs_out; end
  wire hs_rise = hs_out & ~hs_d;   // end of the horizontal sync pulse: one per line
  wire vs_rise = vs_out & ~vs_d;   // end of the vertical sync pulse: one per frame

  // ---- measurement: a race-free fixed window, counted in an always block ----
  //
  // The window is EXACTLY two frames of the machine's raster (2 * 848 * 440 = 746 240 dots), so
  // every quotient below is a whole number and no edge-alignment subtlety can shift it: the line
  // total is cycles divided by horizontal syncs, the frame is horizontal syncs divided by vertical
  // syncs, and the active width is active dots divided by horizontal syncs.
  localparam integer WINDOW_CYCLES = 2 * 848 * 440;

  reg [31:0] n_cyc, n_hsf, n_vsf, n_de, n_aline;
  reg        hs_q, vs_q, measuring, line_had_de;
  always @(posedge clk_vid) begin
    if (measuring) begin
      n_cyc <= n_cyc + 1;
      if (hs_q && !hs_out) begin               // sync pulse begins: one per line
        n_hsf <= n_hsf + 1;
        if (line_had_de) n_aline <= n_aline + 1;   // that line carried an active dot
        line_had_de <= 1'b0;
      end
      if (vs_q && !vs_out) n_vsf <= n_vsf + 1; // ... and one per frame
      if (de_out) begin
        n_de <= n_de + 1;                      // an active dot
        line_had_de <= 1'b1;
      end
    end
    hs_q <= hs_out;
    vs_q <= vs_out;
  end

  integer line_dots, active_per_line, lines_per_frame, active_lines;
  integer i;

  initial begin
    measuring = 0;
    n_cyc = 0; n_hsf = 0; n_vsf = 0; n_de = 0; n_aline = 0; line_had_de = 1'b0;
    repeat (8) @(negedge clk_vid);
    rst_n = 1;
    repeat (4000) @(negedge clk_vid);   // let the counters reach a frame boundary
    measuring = 1;
    repeat (WINDOW_CYCLES) @(negedge clk_vid);
    measuring = 0;
    @(posedge clk_vid);

    line_dots       = n_cyc   / n_hsf;
    lines_per_frame = n_hsf   / n_vsf;
    // The active width is active dots per ACTIVE LINE, not per line: dividing by every line would
    // fold the vertical blanking in and report 640 * 400/440 instead of 640.
    active_per_line = n_de    / n_aline;
    active_lines    = n_aline / n_vsf;

    // Report first, judge second: a runner that reads only the FAIL lines should still see what
    // the raster actually measured.
    $display("RASTER cyc=%0d hsync=%0d vsync=%0d de_dots=%0d aline=%0d",
             n_cyc, n_hsf, n_vsf, n_de, n_aline);
    $display("RASTER line_dots=%0d active_line=%0d lines_per_frame=%0d active_lines=%0d",
             line_dots, active_per_line, lines_per_frame, active_lines);
    $display("RASTER hrate=%.0f Hz (want %.0f)  vrate=%.2f Hz (want %.2f)",
             DOT_HZ / line_dots, H_WANT_HZ,
             DOT_HZ / line_dots / lines_per_frame, V_WANT_HZ);

    if (n_vsf == 0) fail("no vertical sync at all in two frames' worth of dots");
    if (active_per_line != H_ACTIVE_WANT)
      fail("the active line is not the machine's 640 dots");
    if (line_dots != LINE_WANT)
      fail("the line is not the machine's 848 dots");
    if (lines_per_frame != LINES_WANT)
      fail("the frame is not the machine's 440 lines");
    if (active_lines != V_ACTIVE_WANT)
      fail("the active field is not the machine's 400 lines");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GDC_RASTER: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GDC_RASTER: FAIL (%0d errors)", errors);
  end

  initial begin
    // Two frames of dots is 2 * 848 * 440 = 746 240 clk_vid cycles; this watchdog is
    // 1 119 360, three frames' worth, so a raster that never runs is a timeout rather than a
    // hang. Written as a literal because the structure checker accepts a cycle bound only in
    // that form (`repeat ( <number> ) @(posedge ...`); the arithmetic lives here in the comment.
    repeat (1_119_360) @(posedge clk_vid);
    $fatal(1, "TB_PC9821_GDC_RASTER: TIMEOUT (the raster produced no frame)");
  end
endmodule

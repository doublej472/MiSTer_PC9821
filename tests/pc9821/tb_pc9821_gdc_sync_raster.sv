`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The GDC's SYNC command OWNS the raster: the eight-parameter sync block a guest programs through 0x62/0x60 decides the line length, the active width, every porch and the frame length exactly as NP2kai's gdc_updateclock() derives them (io/gdc.c:370-444, the only reference that derives a raster - qemu-pc98 latches the same bytes and then syncs on a fixed 18 ms), and the machine's power-on block still gives the measured default. The expectations are NP2kai's, computed in the bench from the block bytes by a transcription of gdc_updateclock(), never read out of the DUT; the DUT is measured only through its own sync outputs and raster counters (dots per line, lines per frame, active dots per line, active lines, the dot the hsync pulse starts on, the hsync width, the vline the vsync pulse rises on and its width in lines). Five cases: the default block {10 4e 07 25 07 07 90 65} -> 848x440 total with 640x400 active, front porch 80, hsync 64 and back porch 64 dots (the uPD7220's field map, MAME upd7220.cpp:1243-1246 - NP2kai only sums those fields into the line), VFP 7, an 8-line VSYNC pulse rising on vline 407, VBP 25, 56.42 Hz; defsyncm15 written on a 24 kHz machine -> x = 112 characters = 896 dots and the raw 260-line frame CLAMPED to the machine's 400-line minimum; a hand-built 550-line block (lf 480, vs 10, vfp 20, vbp 40) whose pulse rises on vline 500 at 45.1 Hz; and TXTMODE /D's AW 64 and AW 78 blocks (C/R 0x3E and 0x4C), whose lines run 720 and 832 dots (66.45 Hz / 29.24 kHz and 57.51 Hz / 25.30 kHz) as on the real Xe10 (docs/probes/KIT2-XE10-TXTMODE.TXT:36 `ticks=000120F1` and :27 `ticks=00014DE4` against the default's :9 `ticks=0001544F` = 848 dots), the 24 kHz x floor being the machine's 90, not NP2kai's gdcclk[1] minx 100. The default's pulse width is the block's vs field because the machine's own 2M-sample status histogram measures bit 5 high for 36 385 of 2 097 152 samples = 1.735 % = 8 of 440 lines once its loop's x1.048 duty bias is divided out (the factor its bit 6 carries against the 208/848 horizontal blank), where the '2.8 % = 12 lines' the tree used to carry divided the same count by 1 310 720 instead of the capture's own 2^21. FAIL-FIRST: before the kit-2 change case 4's line is clamped to 800 dots; on the pre-change tree cases 2 and 3 cannot move the raster at all, case 1's pulse is 12 lines wide and case 2's line never leaves 848; and on the tree before 2026-10-15 the default's hsync started at dot 768 (HFP 128) and was 56 dots wide, a 24-dot back porch; and the VSYNC pin moved 128 dots after the HSYNC leading edge (at the first active dot), where the uPD7220 moves it WITH the HSYNC leading edge (MAME upd7220.cpp update_vsync_timer) - every VSYNC-pin edge is now checked to land on an HSYNC-pin leading edge.
//
// The GDC's SYNC command OWNS the raster. The eight-parameter sync block a guest programs
// through 0x62 (command) / 0x60 (parameters) decides the line length, the active width, every
// porch and the frame length, exactly as NP2kai's gdc_updateclock() derives them (io/gdc.c:
// 370-444 - the only reference that derives a raster at all: qemu-pc98 latches the same eight
// bytes in gdc_cmd_sync and then syncs every frame on a fixed 18 ms, hw/display/pc98-vga.c:
// 291-298, :748-756) - and the machine's power-on block still gives the measured default.
//
// THE EXPECTED VALUES ARE NP2KAI'S, computed HERE from the block bytes by the transcription in
// np2_sync_geometry() below and never read out of the DUT. The DUT is measured only through its
// own sync outputs and raster counters: dots per line (HTOTAL), lines per frame (VTOTAL), active
// dots per line (HACTIVE), active lines (VACTIVE), the dot the hsync pulse starts on (HACTIVE +
// HFP), the hsync width (HSYNC_W), the vline the vsync pulse rises on (VACTIVE + VFP) and its
// width in lines (VSYNC_W).
//
// THE CASES:
//  1. the DEFAULT, before any SYNC has been written: NP2kai's defsyncm24 (io/gdc.c:42), the
//     block gdc_biosreset installs on a 24 kHz machine, {10 4e 07 25 07 07 90 65} ->
//     848x440 total with 640x400 active, a 128-dot front porch, a 56-dot hsync, VFP 7, a
//     VSYNC pulse 8 lines wide rising on vline 407, VBP 25, i.e. 24.83 kHz and 56.42 Hz.
//     The pulse WIDTH is the block's vs field: the machine's own 2M-sample status histogram
//     counts bit 5 high in 36 385 of 2 097 152 samples = 1.735 % (docs/probes/GDC.TXT), which
//     is 8 of 440 lines once its sampling loop's x1.048 duty bias is divided out - the same
//     factor its bit 6 carries against the horizontal blank (23.4 % measured vs the 208/848 =
//     24.53 % modelled) - so the machine agrees with vs = 8, and the "2.8 % = 12 lines" this
//     tree carried divided the same count by 1 310 720 instead of the 2 097 152 the capture's
//     own always-set bit 2 counts.
//  2. defsyncm15 (io/gdc.c:43), the 15 kHz machine's block, written on THIS 24 kHz machine:
//     x = 112 characters (896 dots, so the LINE is programmable too) and the raw y = 260 is
//     below the machine's monitor range, so it clamps to 400 lines - the frame rate follows the
//     CLAMPED y, and the active count stays the block's lf (NP2kai's proportional rescale,
//     io/gdc.c:419-430, is deliberately not modelled: see pc9821_crtc's geometry section).
//  3. a hand-built block with every vertical field off its default - lf 480, vs 10, vfp 20,
//     vbp 40 -> y = 550 lines, the pulse rising on vline 500 and 45.1 Hz - so the frame period
//     follows y = lf + vs + vfp + vbp and not any constant, and the pulse width follows the
//     block's vs field rather than a fixed value.
//
// FAIL-FIRST: on the pre-change tree (HTOTAL/VTOTAL/VSYNC_W hardcoded 848/440/12) cases 2 and 3
// cannot move the raster at all, case 1's pulse is 12 lines wide, and case 2's line length never
// leaves 848.
//
// WHAT IT IS BLIND TO, stated rather than implied: it does not check the dot clock itself
// (pc9821_system's PIXEL_CE does not depend on the sync block, and this bench drives pixel_ce
// directly), and it does not check what the guest SEES at the new rate - the VSYNC IRQ's phase
// within the frame is tb_pc9821_gdc_text's, and the display windows are the video benches'.

module tb_pc9821_gdc_sync_raster;
  // One pixel_ce per cycle: one cycle = one dot, so every count below is in DOTS and the rates
  // are the machine's dot clock (21.0526 MHz) over those counts.
  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;   // 100 MHz gating clock; pixel_ce decides the dot rate

  reg rst_n = 0;

  reg        io_wr = 1'b0;
  reg        io_rd = 1'b0;
  reg [7:0]  io_addr = 8'h00;
  reg [7:0]  io_din  = 8'h00;
  wire [7:0] io_dout;
  reg [13:0] tram_cpu_addr = 14'd0;
  reg [7:0]  tram_cpu_din  = 8'h00;
  reg        tram_cpu_we   = 1'b0;
  wire [7:0] tram_cpu_dout;
  reg [17:0] font_ld_addr = 18'd0;
  reg [15:0] font_ld_data = 16'd0;
  reg        font_ld_we   = 1'b0;
  wire [7:0]  cg_win_dout;
  wire  [4:0] cg_win_byte_sel = 5'd0;
  wire        cg_win_rd = 1'b0;
  wire        cg_win_we = 1'b0;
  wire  [7:0] cg_win_din = 8'h00;
  wire        cg_win_byte_hold;
  wire [18:0] font_req_addr;
  wire        font_req;
  wire        cg_rd_hold;
  wire        font_word_valid = 1'b0;
  wire [31:0] font_word_data = 32'hFFFF_FFFF;
  wire        cg_record_restore = 1'b0;
  wire  [6:0] cfg_ram_mib = 7'd0;
  wire        cfg_seed_en = 1'b0;
  wire        vsync_active, vsync_edge, vsync_irq, disp_on, gfx_access_page;
  wire        gfx_disp, gfx_egc_gate;
  wire [15:0] dbg_sad, dbg_wk_skips;
  wire  [7:0] dbg_pitch;
  wire        dbg_col40, dbg_disp;
  wire        text_opaque, text_cell;
  wire [11:0] text_colour;
  wire [9:0]  pix_dot;
  wire        pix_h_active, pix_v_active, gfx_odd_line, gfx_mode16;
  wire [31:0] gfx_dig;
  wire        pal_wr_en;
  wire  [3:0] pal_wr_idx, pal_wr_data;
  wire  [1:0] pal_wr_chan;
  wire        hs_out, vs_out, de_out;
  // The VSYNC IRQ (port 0x64's arm latch): this bench HOLDS the arm input high through each
  // measurement, which is what the guest's handler achieves by re-arming on every interrupt
  // (OP.COM does `out 0x64` at CS:039A), so
  // exactly one pulse per frame is the contract at WHATEVER frame length the block programs.
  reg         vsync_irq_arm = 1'b0;
  reg         vsync_irq_seen = 1'b0;
  always @(posedge clk_sys) if (vsync_irq) vsync_irq_seen <= 1'b1;

  // ==== DUT ====
  pc9821_gdc_text_dut dut (
      .clk_sys(clk_sys), .rst_n_sys(rst_n), .pixel_ce(1'b1),
      .cfg_fdd_mode(3'd0),   // entry 0: the measured boot/FDD nibble
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
      .tram_cpu_addr(tram_cpu_addr), .tram_cpu_din(tram_cpu_din),
      .tram_cpu_we(tram_cpu_we), .tram_cpu_dout(tram_cpu_dout),
      .font_ld_addr(font_ld_addr), .font_ld_data(font_ld_data), .font_ld_we(font_ld_we),
      .cg_win_byte_sel(cg_win_byte_sel), .cg_win_rd(cg_win_rd),
      .cg_win_dout(cg_win_dout), .cg_win_din(cg_win_din), .cg_win_we(cg_win_we),
      .cg_win_byte_hold(cg_win_byte_hold),
      .font_req_addr(font_req_addr), .font_req(font_req),
      .font_word_valid(font_word_valid), .font_word_data(font_word_data),
      .cg_rd_hold(cg_rd_hold),
      .cg_record_restore(cg_record_restore),
      .cfg_seed_reload(1'b0),
      .cfg_ram_mib(cfg_ram_mib), .cfg_seed_en(cfg_seed_en),
      .vsync_active(vsync_active), .vsync_edge(vsync_edge),
      .vsync_irq_arm(vsync_irq_arm), .vsync_irq(vsync_irq),
      .disp_on(disp_on), .gfx_access_page(gfx_access_page),
      .gfx_disp(gfx_disp), .gfx_egc_gate(gfx_egc_gate), .gfx_line_addr(),
      .dbg_sad(dbg_sad), .dbg_pitch(dbg_pitch), .dbg_col40(dbg_col40), .dbg_disp(dbg_disp),
      .dbg_wk_skips(dbg_wk_skips),
      .text_opaque(text_opaque), .text_cell(text_cell), .text_colour(text_colour),
      .pix_dot(pix_dot), .pix_h_active(pix_h_active), .pix_v_active(pix_v_active),
      .gfx_odd_line(gfx_odd_line),
      .gfx_mode16(gfx_mode16), .gfx_dig(gfx_dig),
      .pal_wr_en(pal_wr_en), .pal_wr_idx(pal_wr_idx),
      .pal_wr_chan(pal_wr_chan), .pal_wr_data(pal_wr_data),
      .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
  );

  // ==== NP2kai's gdc_updateclock(), transcribed (io/gdc.c:370-444) ====
  // sb[] is the block being checked: the eight parameter bytes in arrival order, so sb[2] is the
  // LOW byte of word(sb[2..3]) and sb[6] the low byte of word(sb[6..7]) - NP2kai's
  // LOADINTELWORD(para + GDC_SYNC + 2) over a parameter RAM that starts at GDC_SYNC = 0.
  reg [7:0] sb [0:7];
  integer g_cr, g_hs, g_hfp, g_vs, g_vfp, g_lf, g_vbp;   // the fields, NP2kai's names
  integer g_x_raw, g_y_raw, g_x, g_y;                    // the roots and their clamp
  integer g_htotal, g_vtotal, g_hact, g_vact;            // the geometry this bench expects
  integer g_hfp_d, g_hs_d, g_hs_start, g_vfp_e, g_v_rise, g_vs_w;

  // The 24 kHz machine's gdcclk[1] (io/gdc.c:34): minx, maxx, miny, maxy. The Xe10 is strapped
  // to this entry - its GDC clock select never moves the raster - and the 15 kHz and 31 kHz
  // entries are other machines' monitors. EXCEPT minx: the real Xe10 runs x = 90 (AW 64) as a
  // 720-dot line (docs/probes/KIT2-XE10-TXTMODE.TXT:36 `FRAME 16 VSYNC ticks=000120F1
  // lines=01B8`; case 4 below), where gdcclk[1]'s 100 would hold it at 800, so the floor is 90.
  localparam integer CLK_MINX = 90, CLK_MAXX = 112;
  localparam integer CLK_MINY = 400, CLK_MAXY = 575;

  // ==== CHECKS ====
  task automatic np2_sync_geometry;
    integer tmp, tmp2, vfbs;
    begin
      g_cr  = sb[1] + 2;                        // cr = para[1] + 2
      tmp   = sb[2] | (sb[3] << 8);             // tmp = word(para[2..3])
      g_hs  = tmp & 5'h1f;                      // hs = tmp & 0x1f
      g_vs  = (tmp >> 5) & 5'h1f;               // vs = (tmp >> 5) & 0x1f
      g_hfp = (tmp >> 10) + (sb[4] & 6'h3f);    // hfp = tmp >> 10, plus para[4] & 0x3f
      g_vfp = sb[5] & 6'h3f;                    // vfp = para[5] & 0x3f
      tmp2  = sb[6] | (sb[7] << 8);             // tmp2 = word(para[6..7])
      g_lf  = ((tmp2 - 1) & 10'h3ff) + 1;       // lf = ((tmp2 - 1) & 0x3ff) + 1
      g_vbp = tmp2 >> 10;                       // vbp = tmp2 >> 10
      g_x_raw = g_cr + g_hs + g_hfp + 3;        // x = cr + hs + hfp + 3 (3 = the h back porch)
      vfbs    = g_vs + g_vfp + g_vbp;           // if (!vfbs) vfbs = 1
      if (vfbs == 0) vfbs = 1;
      g_y_raw = g_lf + vfbs;                    // y = lf + vfbs
      g_x = (g_x_raw < CLK_MINX) ? CLK_MINX : (g_x_raw > CLK_MAXX) ? CLK_MAXX : g_x_raw;
      g_y = (g_y_raw < CLK_MINY) ? CLK_MINY : (g_y_raw > CLK_MAXY) ? CLK_MAXY : g_y_raw;
      // The widths this bench measures, as the block states them. VACTIVE is the block's lf and
      // the pulse is the block's vs: every case below is checked to FIT (see case_guard), so the
      // clamp's own active-count saturation is not in play.
      g_htotal  = 8 * g_x;
      g_vtotal  = g_y;
      g_hact    = 8 * g_cr;
      g_vact    = g_lf;
      // The porches are the uPD7220's (MAME upd7220.cpp:1243-1246 `m_hfp = (m_pr[4] >> 2) + 1`,
      // `m_hs = (m_pr[3] & 0x1f) + 1`, `m_hbp = (m_pr[5] & 0x3f) + 1`): NP2kai only sums the fields.
      g_hfp_d   = 8 * ((tmp >> 10) + 1);
      g_hs_d    = 8 * (g_hs + 1);
      g_hs_start = g_hact + g_hfp_d;
      g_vfp_e   = g_vfp;
      g_v_rise  = g_vact + g_vfp_e;
      g_vs_w    = g_vs;
    end
  endtask

  // The block has to be one whose own geometry fits the frame (so the expectation above needs no
  // saturation): this is a precondition of the case, asserted rather than assumed.
  task automatic case_guard(input string name);
    begin
      if (g_lf > g_vtotal - 1) begin
        $display("FAIL %0s: block's lf %0d does not fit its %0d-line frame", name, g_lf, g_vtotal);
        errors = errors + 1;
      end
      if (g_vfp_e + g_vs_w > g_vtotal - g_lf) begin
        $display("FAIL %0s: block's vfp %0d + vs %0d exceed its %0d-line blanking",
                 name, g_vfp_e, g_vs_w, g_vtotal - g_lf);
        errors = errors + 1;
      end
      if (g_hact + g_hfp_d + g_hs_d > g_htotal) begin
        $display("FAIL %0s: block's porches exceed its %0d-dot line", name, g_htotal);
        errors = errors + 1;
      end
    end
  endtask

  integer errors = 0;
  integer k;

  // ==== DUT-side measurement ====
  wire in_hs = dut.u_crtc.in_hsync;
  wire in_vs = dut.u_crtc.in_vsync;

  reg hs_q, vs_q, in_hs_d, in_vs_d, line_had_de, meas;
  reg [9:0] rise_vline, hs_start_dot;
  // The PINS: every edge of the VSYNC pin must land on an HSYNC-pin leading edge (the uPD7220 moves
  // VSYNC at x = 0 of its line, where its HSYNC begins: MAME upd7220.cpp update_vsync_timer
  // `time_until_pos(next_y, 0)`, update_hsync_timer `next_x = state ? m_hs * horiz_mult : 0`).
  reg        pin_hs_q = 1'b1, pin_vs_q = 1'b1;
  integer    n_pin_vs_edges = 0, n_pin_vs_off = 0;
  always @(posedge clk_sys) begin
    pin_hs_q <= hs_out;
    pin_vs_q <= vs_out;
    if (meas && (pin_vs_q != vs_out)) begin
      n_pin_vs_edges = n_pin_vs_edges + 1;
      if (!(pin_hs_q && !hs_out)) n_pin_vs_off = n_pin_vs_off + 1;
    end
  end
  reg [31:0] n_cyc, n_hs, n_vs, n_de, n_aline, n_hsdots, n_pulse, n_irq;
  always @(posedge clk_sys) begin
    if (meas) begin
      n_cyc <= n_cyc + 1;
      if (vsync_irq) n_irq <= n_irq + 1;
      if (in_hs) n_hsdots <= n_hsdots + 1;
      if (in_hs && !hs_q) begin                 // the pulse begins: one per line
        n_hs <= n_hs + 1;
        if (line_had_de) n_aline <= n_aline + 1;  // that line carried an active dot
        line_had_de <= 1'b0;
        if (in_vs) n_pulse <= n_pulse + 1;        // ... and this line is inside the vsync pulse
      end
      if (in_vs && !vs_q) n_vs <= n_vs + 1;     // one per frame
      if (de_out) begin
        n_de <= n_de + 1;
        line_had_de <= 1'b1;
      end
    end
    hs_q <= in_hs;
    vs_q <= in_vs;
    if (in_vs && !in_vs_d) rise_vline <= dut.u_crtc.vline;
    if (in_hs && !in_hs_d) hs_start_dot <= dut.u_crtc.hdot;
    in_vs_d <= in_vs;
    in_hs_d <= in_hs;
  end

  task automatic fail(input string message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic expect_eq(input integer got, input integer want, input string what);
    begin
      if (got !== want) begin
        $display("FAIL: %0s = %0d, want %0d", what, got, want);
        errors = errors + 1;
      end
    end
  endtask

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum;
      io_din  = data;
      io_wr   = 1'b1;
      @(negedge clk_sys);
      io_wr   = 1'b0;
    end
  endtask

  // The guest's SYNC transaction: the command byte on 0x62, then the block's eight bytes on
  // 0x60 in arrival order (NP2kai gdc_work stores each into para[ptr++], io/gdc.c:341-345).
  // The enable bit 0x0F sets is the SYNC_ON form.
  task automatic write_sync;
    begin
      write_io(8'h62, 8'h0F);
      for (k = 0; k < 8; k = k + 1) write_io(8'h60, sb[k]);
    end
  endtask

  // Park on a frame boundary: after the vsync pulse has risen, the raster's own wrap to
  // vline 0 / hdot 0 is the window's origin (already latched, so the following negedge is inside
  // that cycle and the counter below counts this frame's dots from the next one).
  task automatic wait_frame;
    begin
      wait (in_vs);
      wait (dut.u_crtc.vline == 10'd0 && dut.u_crtc.hdot == 10'd0);
      @(negedge clk_sys);
    end
  endtask

  task automatic measure_and_check(input string name);
    integer line_dots, lines_frame, act_dots, act_lines, hs_w, pulse_lines;
    begin
      @(negedge clk_sys);
      n_cyc = 0; n_hs = 0; n_vs = 0; n_de = 0; n_aline = 0; n_hsdots = 0; n_pulse = 0; n_irq = 0;
      n_pin_vs_edges = 0; n_pin_vs_off = 0;
      line_had_de = 1'b0;
      meas = 1'b1;
      // EXACTLY one frame of the EXPECTED raster, so every quotient below is a whole number.
      repeat (g_htotal * g_vtotal) @(negedge clk_sys);
      meas = 1'b0;
      @(posedge clk_sys);

      line_dots   = (n_hs   != 0) ? (n_cyc   / n_hs)   : 0;
      lines_frame = (n_vs   != 0) ? (n_hs    / n_vs)   : 0;
      act_dots    = (n_aline != 0) ? (n_de   / n_aline) : 0;
      act_lines   = (n_vs   != 0) ? (n_aline / n_vs)   : 0;
      hs_w        = (n_hs   != 0) ? (n_hsdots / n_hs)  : 0;
      pulse_lines = (n_vs   != 0) ? (n_pulse / n_vs)   : 0;

      // Report first, judge second: a runner that reads only the FAIL lines still sees what the
      // raster actually measured. The block, its NP2kai roots and both sets of widths, DUT vs
      // reference.
      $display("SYNC %-22s block=%02x %02x %02x %02x %02x %02x %02x %02x",
               name, sb[0], sb[1], sb[2], sb[3], sb[4], sb[5], sb[6], sb[7]);
      $display("SYNC   NP2kai fields: cr=%0d hs=%0d vs=%0d hfp=%0d vfp=%0d lf=%0d vbp=%0d -> x=%0d(%0d) y=%0d(%0d)",
               g_cr, g_hs, g_vs, g_hfp, g_vfp, g_lf, g_vbp, g_x, g_x_raw, g_y, g_y_raw);
      $display("SYNC   DUT: %0dx%0d total, %0dx%0d act  hs at %0d w %0d  vs rise %0d w %0d",
               line_dots, lines_frame, act_dots, act_lines, hs_start_dot, hs_w, rise_vline, pulse_lines);
      $display("SYNC   ref: %0dx%0d total, %0dx%0d act  hs at %0d w %0d  vs rise %0d w %0d",
               g_htotal, g_vtotal, g_hact, g_vact, g_hs_start, g_hs_d, g_v_rise, g_vs_w);
      $display("SYNC   rate: %.2f Hz (%.2f kHz line)  @ 21.0526 MHz / %0d dots / %0d lines",
               21.0526e6 / (line_dots * lines_frame), 21.0526e6 / line_dots / 1000.0,
               line_dots, lines_frame);
      $display("SYNC   armed VSYNC IRQ pulses in one frame: %0d", n_irq);

      if (n_vs == 0) fail("no vertical sync in a frame's worth of dots");
      expect_eq(line_dots,   g_htotal,  "line dots (HTOTAL)");
      expect_eq(lines_frame, g_vtotal,  "lines per frame (VTOTAL)");
      expect_eq(act_dots,    g_hact,    "active dots per line (HACTIVE)");
      expect_eq(act_lines,   g_vact,    "active lines (VACTIVE)");
      expect_eq(hs_start_dot, g_hs_start, "hsync start dot (HACTIVE + HFP)");
      expect_eq(hs_w,        g_hs_d,    "hsync width (HSYNC_W)");
      expect_eq(n_pin_vs_off, 0, "VSYNC-pin edges not on an HSYNC-pin leading edge");
      if (n_pin_vs_edges < 2) fail("no VSYNC-pin edges measured");
      // The back porch: the hsync's end to the line's end, MAME's m_hbp = (para[4] & 0x3f) + 1 characters.
      expect_eq(line_dots - hs_start_dot - hs_w, g_htotal - g_hact - g_hfp_d - g_hs_d, "hsync end to line end (HBP)");
      expect_eq(rise_vline,  g_v_rise,  "vsync rise vline (VACTIVE + VFP)");
      expect_eq(pulse_lines, g_vs_w,    "vsync width in lines (VSYNC_W)");
      // One pulse per frame at THIS frame length: the 0x64 latch re-armed every frame (the arm
      // input is held high here, which is what the guest's own re-arm achieves).
      expect_eq(n_irq, 1, "armed VSYNC IRQ pulses in one frame");
    end
  endtask

  task automatic run_case(input string name, input integer issue_sync);
    begin
      if (issue_sync) begin
        write_sync;
        // The block is copied into the raster domain at a frame boundary (pc9821_crtc's
        // v_sync), so give it three frames: one to land, one to be measured from.
        wait_frame;
        wait_frame;
        wait_frame;
      end else wait_frame;
      np2_sync_geometry;
      case_guard(name);
      measure_and_check(name);
    end
  endtask

  initial begin
    meas = 1'b0;
    n_cyc = 0; n_hs = 0; n_vs = 0; n_de = 0; n_aline = 0; n_hsdots = 0; n_pulse = 0; n_irq = 0;
    hs_q = 1'b0; vs_q = 1'b0; in_hs_d = 1'b0; in_vs_d = 1'b0; line_had_de = 1'b0;
    rise_vline = 10'd0; hs_start_dot = 10'd0;

    repeat (8) @(negedge clk_sys);
    rst_n = 1'b1;
    repeat (2000) @(negedge clk_sys);
    vsync_irq_arm = 1'b1;   // the guest's handler re-arms every frame (see above)

    // ---- case 1: the DEFAULT, before any SYNC is written ----
    // NP2kai's defsyncm24 (io/gdc.c:42). The raster is the machine's 24 kHz mode: 848 dots per
    // line of which 640 are active, 440 lines per frame of which 400 are active, the vsync pulse
    // 8 lines wide rising on vline 407 (VACTIVE + VFP; docs/probes/FLIP.TXT puts the edge there).
    sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h07; sb[3] = 8'h25;
    sb[4] = 8'h07; sb[5] = 8'h07; sb[6] = 8'h90; sb[7] = 8'h65;
    run_case("default (no SYNC)", 0);
    // The fields the block states, asserted where the block is spelled out: the supervisor's
    // decomposition of the default's 40-line blank, and its roots.
    np2_sync_geometry;
    expect_eq(g_cr, 80, "default cr");        expect_eq(g_hs, 7,  "default hs");
    expect_eq(g_vs, 8,  "default vs");        expect_eq(g_hfp, 16, "default hfp");
    expect_eq(g_vfp, 7, "default vfp");       expect_eq(g_lf, 400, "default lf");
    expect_eq(g_vbp, 25, "default vbp");
    expect_eq(g_vs + g_vfp + g_vbp, 40, "default blanking (VS + VFP + VBP)");
    expect_eq(g_x, 106, "default x");         expect_eq(g_y, 440, "default y");
    expect_eq(g_y_raw, 440, "default y is not clamped");
    expect_eq(g_x_raw, 106, "default x is not clamped");

    // ---- case 2: defsyncm15 on a 24 kHz machine ----
    // NP2kai's defsyncm15 (io/gdc.c:43): cr 80, hs 7, vs 8, hfp 9+13, vfp 15, lf 200, vbp 37 ->
    // x = 112 characters = 896 dots (inside the 24 kHz monitor's 100..112), raw y = 260 lines
    // which is BELOW its 400-line minimum, so y clamps to 400.
    sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h07; sb[3] = 8'h25;
    sb[4] = 8'h0d; sb[5] = 8'h0f; sb[6] = 8'hc8; sb[7] = 8'h94;
    run_case("defsyncm15 (clamped y)", 1);
    np2_sync_geometry;
    expect_eq(g_x_raw, 112, "defsyncm15 x is inside the range");
    expect_eq(g_y_raw, 260, "defsyncm15 raw y");
    expect_eq(g_y, 400, "defsyncm15 y clamps to the 24 kHz minimum");

    // ---- case 3: a hand-built 550-line block ----
    // lf 480 (0x1e0), vs 10, vfp 20 (0x14), vbp 40 -> y = 480 + 10 + 20 + 40 = 550 lines, the
    // pulse rising on vline 500 with the hsync fixed at the default's 128/56. The block words:
    // tmp = hs 7 | vs 10 << 5 | hfp2 9 << 10 = 0x2547 -> {47, 25}; tmp2 = lf 480 | vbp 40 << 10
    // = 0xa1e0 -> {e0, a1}.
    sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h47; sb[3] = 8'h25;
    sb[4] = 8'h07; sb[5] = 8'h14; sb[6] = 8'he0; sb[7] = 8'hA1;
    run_case("hand-built 550 lines", 1);
    np2_sync_geometry;
    expect_eq(g_vs, 10, "550-block vs");
    expect_eq(g_vfp, 20, "550-block vfp");
    expect_eq(g_lf, 480, "550-block lf");
    expect_eq(g_y, 550, "550-block y");
    expect_eq(g_v_rise, 500, "550-block vsync rise vline");
    expect_eq(g_htotal, 848, "550-block htotal is the default's");

    // ---- cases 4 and 5: TXTMODE /D's AW 64 and AW 78 blocks, as the real Xe10 ran them ----
    // The default block with C/R 0x3E (AW 64: x = 64 + 26 = 90) and 0x4C (AW 78: x = 104). The
    // machine's 16-frame times against its own default's (docs/probes/KIT2-XE10-TXTMODE.TXT:9
    // `FRAME 16 VSYNC ticks=0001544F lines=01B8`, 848 dots): :36 `FRAME 16 VSYNC ticks=000120F1
    // lines=01B8` is 848 x 0x120F1 / 0x1544F = 720.0 dots (29.24 kHz / 66.46 Hz on the OSSC) and
    // :27 `FRAME 16 VSYNC ticks=00014DE4 lines=01B8` 832.0 dots: the line shortens by the
    // missing words, with no 800-dot floor.
    sb[0] = 8'h10; sb[1] = 8'h3e; sb[2] = 8'h07; sb[3] = 8'h25;
    sb[4] = 8'h07; sb[5] = 8'h07; sb[6] = 8'h90; sb[7] = 8'h65;
    run_case("TXTMODE P4 AW 64", 1);
    np2_sync_geometry;
    expect_eq(g_x_raw, 90, "AW 64 block x");
    expect_eq(g_htotal, (848 * 'h120F1 + 'h1544F / 2) / 'h1544F,
              "AW 64 line: the Xe10's 720 dots (KIT2-XE10-TXTMODE.TXT:36 vs :9)");
    sb[1] = 8'h4c;
    run_case("TXTMODE P3 AW 78", 1);
    np2_sync_geometry;
    expect_eq(g_htotal, (848 * 'h14DE4 + 'h1544F / 2) / 'h1544F,
              "AW 78 line: the Xe10's 832 dots (KIT2-XE10-TXTMODE.TXT:27 vs :9)");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GDC_SYNC_RASTER: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GDC_SYNC_RASTER: FAIL (%0d errors)", errors);
  end

  initial begin
    // Five cases, each with a few frames of settling plus one measured frame; the longest is
    // case 3's 550 lines x 848 dots = 466 400 dots, so ~6 M cycles is generous. Written as a
    // literal because the structure checker accepts a cycle bound only in that form
    // (`repeat ( <number> ) @(posedge ...`).
    repeat (9_000_000) @(posedge clk_sys);
    $fatal(1, "TB_PC9821_GDC_SYNC_RASTER: TIMEOUT (the raster produced no frame)");
  end
endmodule

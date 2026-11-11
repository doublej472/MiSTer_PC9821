`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The analog line doubler (pc9821_line_doubler) sends every GDC line twice at twice the GDC's line rate, at the guest's own frame rate, for whatever raster the guest's SYNC block programs: driven by the real pc9821_crtc with the dot enable on every other clock and the doubled enable on every clock, the doubled output's line period is HALF the input's (HTOTAL clocks against 2 x HTOTAL), its frame is 2 x VTOTAL lines with 2 x VACTIVE active lines of HACTIVE dots, its hsync is HSYNC_W samples and its vsync 2 x VSYNC_W lines, and output active lines 2k and 2k+1 both carry exactly input active line k's pixels (a per-line checksum over position and colour) - every figure computed in the bench from the SYNC block bytes by tb_pc9821_gdc_sync_raster's transcription of NP2kai's gdc_updateclock() (io/gdc.c:370-444), never read out of the DUT. Three blocks: the default defsyncm24 (848x440, 640x400 -> 49.66 kHz, 880 lines, 56.42 Hz), defsyncm15 (an 896-dot line) and a hand-built 550-line block; and with the runtime enable off the output is the input itself (2 x HTOTAL clocks a line, VTOTAL lines). FAIL-FIRST: with the doubler absent (the input passed through) every doubled figure is off by two, and a doubler that replays two different lines fails the content check.
//
// WHY THESE FIGURES. A doubled raster for a VGA monitor is the GDC's raster with every line sent twice in
// the time of one: the line rate doubles, the frame rate (lines x line period) does not, and the content
// of each line pair is the source line. The expectations follow from the SYNC block alone.
//
// WHAT IT IS BLIND TO: the analog levels and whether a given monitor accepts 49.66 kHz at 56.42 Hz
// (that is an eye check on a real monitor), and the framework's path from VGA_* to the pins.

module tb_pc9821_line_doubler;
  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;

  // The dot enable on every other clock, the doubled enable on every clock: every dot is a ce2.
  reg pix_ce = 1'b0;
  always @(posedge clk_sys) pix_ce <= ~pix_ce;
  wire ce2 = 1'b1;

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
      .clk_sys(clk_sys), .rst_n_sys(rst_n), .pixel_ce(pix_ce),
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
  // entries are other machines' monitors. minx is the machine's 90, not gdcclk[1]'s 100: the
  // real Xe10 runs an AW 64 block (x = 90) as a 720-dot line (docs/probes/KIT2-XE10-TXTMODE.TXT:36
  // `FRAME 16 VSYNC ticks=000120F1 lines=01B8`; tb_pc9821_gdc_sync_raster). No block here is below 100.
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


  // ==== the pixels: a free-running LFSR on the dot enable, so every line differs ====
  reg [23:0] lfsr = 24'h5A5A5A;
  always @(posedge clk_sys) if (pix_ce) lfsr <= {lfsr[22:0], lfsr[23] ^ lfsr[22] ^ lfsr[21] ^ lfsr[16]};

  reg dbl_en = 1'b1;
  wire [7:0] o_r, o_g, o_b;
  wire       o_hs, o_vs, o_de, o_ce, o_dbl;
  pc9821_line_doubler dbl (
      .clk(clk_sys), .en(dbl_en), .ce(pix_ce), .ce2(ce2),
      .r_in(lfsr[23:16]), .g_in(lfsr[15:8]), .b_in(lfsr[7:0]),
      .hs_in(hs_out), .vs_in(vs_out), .de_in(de_out),
      .r_out(o_r), .g_out(o_g), .b_out(o_b), .hs_out(o_hs), .vs_out(o_vs), .de_out(o_de),
      .ce_out(o_ce), .doubling(o_dbl)
  );

  integer errors = 0;
  integer k;

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

  task automatic write_sync;
    begin
      write_io(8'h62, 8'h0F);
      for (k = 0; k < 8; k = k + 1) write_io(8'h60, sb[k]);
    end
  endtask

  // ==== input side: per active line, a checksum of (position, colour) ====
  reg [31:0] in_sum [0:1023];
  reg [31:0] isum;
  reg        i_hs_q, i_vs_q, i_line_de;
  integer    i_ka, i_dot;
  always @(posedge clk_sys) if (pix_ce) begin
    i_hs_q <= hs_out;
    i_vs_q <= vs_out;
    if (i_vs_q && !vs_out) i_ka = 0;
    if (i_hs_q && !hs_out) begin
      if (i_line_de) begin in_sum[i_ka % 1024] <= isum; i_ka = i_ka + 1; end
      isum <= 32'd0; i_line_de <= 1'b0; i_dot = 0;
    end else begin
      if (de_out) begin
        isum <= isum * 32'd31 + {lfsr ^ 24'(i_dot), 8'h00};
        i_line_de <= 1'b1;
      end
      i_dot = i_dot + 1;
    end
  end

  // ==== output side, on the output enable ====
  reg        o_hs_q, o_vs_q, o_line_de, meas;
  reg [31:0] osum;
  integer    o_m, o_dot, n_clk, n_hsf, n_vsf, n_de, n_aline, n_hsw, n_vsl, n_content_bad, n_content_ok;
  always @(posedge clk_sys) begin
    if (meas) n_clk = n_clk + 1;
    if (o_ce) begin
      o_hs_q <= o_hs;
      o_vs_q <= o_vs;
      if (meas && !o_hs) n_hsw = n_hsw + 1;
      if (o_vs_q && !o_vs) begin
        if (meas) n_vsf = n_vsf + 1;
        o_m = 0;
      end
      if (o_hs_q && !o_hs) begin
        if (meas) begin
          n_hsf = n_hsf + 1;
          if (!o_vs) n_vsl = n_vsl + 1;
        end
        if (o_line_de) begin
          if (meas && o_dbl) begin
            if (osum !== in_sum[(o_m / 2) % 1024]) begin
              if (n_content_bad < 4)
                $display("FAIL: output active line %0d differs from input active line %0d", o_m, o_m / 2);
              n_content_bad = n_content_bad + 1;
            end else n_content_ok = n_content_ok + 1;
          end
          if (meas) n_aline = n_aline + 1;
          o_m = o_m + 1;
        end
        osum <= 32'd0; o_line_de <= 1'b0; o_dot = 0;
      end else begin
        if (o_de) begin
          osum <= osum * 32'd31 + {{o_r, o_g, o_b} ^ 24'(o_dot), 8'h00};
          o_line_de <= 1'b1;
          if (meas) n_de = n_de + 1;
        end
        o_dot = o_dot + 1;
      end
    end
  end

  task automatic wait_frame;
    begin
      wait (!vs_out);
      wait (vs_out);
      @(negedge clk_sys);
    end
  endtask

  // Measure exactly two input frames (2 x HTOTAL x VTOTAL dots = 4 x that many clocks), starting on
  // an output vsync leading edge so every count is whole.
  task automatic measure(input string name, input integer doubled);
    integer frames, period, lines, act_dots, act_lines, hs_w, vs_l, want_period, want_lines;
    begin
      wait (o_vs_q && !o_vs && o_ce);
      @(negedge clk_sys);
      n_clk = 0; n_hsf = 0; n_vsf = 0; n_de = 0; n_aline = 0; n_hsw = 0; n_vsl = 0;
      n_content_bad = 0; n_content_ok = 0;
      meas = 1'b1;
      repeat (2 * 2 * g_htotal * g_vtotal) @(negedge clk_sys);
      meas = 1'b0;
      frames    = 2;
      period    = (n_hsf != 0) ? n_clk / n_hsf : 0;
      lines     = n_hsf / frames;
      act_lines = n_aline / frames;
      act_dots  = (n_aline != 0) ? n_de / n_aline : 0;
      hs_w      = (n_hsf != 0) ? n_hsw / n_hsf : 0;
      vs_l      = n_vsl / frames;
      want_period = doubled ? g_htotal : 2 * g_htotal;   // clocks per output line (input: 2 x HTOTAL)
      want_lines  = doubled ? 2 * g_vtotal : g_vtotal;
      $display("DBL %-24s %s: %0d clk/line (in %0d) %0d lines %0dx%0d act hs %0d vs %0d lines, %0d vsyncs, content ok %0d bad %0d",
               name, doubled ? "doubled" : "native ", period, 2 * g_htotal, lines, act_dots, act_lines,
               hs_w, vs_l, n_vsf, n_content_ok, n_content_bad);
      $display("DBL   rate: %.3f kHz line, %.3f Hz frame at a 21.0526 MHz dot clock",
               21.0526e6 * 2.0 / period / 1000.0, 21.0526e6 * 2.0 / (period * lines));
      expect_eq(n_vsf, frames, {name, ": vsync leading edges in two frames"});
      expect_eq(period, want_period, {name, ": clocks per output line"});
      expect_eq(lines, want_lines, {name, ": output lines per frame"});
      expect_eq(act_lines, doubled ? 2 * g_vact : g_vact, {name, ": active output lines per frame"});
      expect_eq(act_dots, g_hact, {name, ": active samples per output line"});
      expect_eq(hs_w, g_hs_d, {name, ": hsync width in output samples"});
      expect_eq(vs_l, doubled ? 2 * g_vs_w : g_vs_w, {name, ": vsync width in output lines"});
      if (doubled) begin
        expect_eq(n_content_bad, 0, {name, ": output line pairs that differ from their input line"});
        expect_eq(n_content_ok, 2 * 2 * g_vact, {name, ": output lines checked against their input line"});
      end
    end
  endtask

  task automatic run_case(input string name, input integer issue_sync);
    begin
      if (issue_sync) begin
        write_sync;
        wait_frame; wait_frame; wait_frame;
      end else wait_frame;
      np2_sync_geometry;
      dbl_en = 1'b1;
      wait_frame; wait_frame;
      measure(name, 1);
    end
  endtask

  initial begin
    meas = 1'b0;
    n_clk = 0; n_hsf = 0; n_vsf = 0; n_de = 0; n_aline = 0; n_hsw = 0; n_vsl = 0;
    n_content_bad = 0; n_content_ok = 0; o_m = 0; o_dot = 0; i_ka = 0; i_dot = 0;
    o_hs_q = 1'b1; o_vs_q = 1'b1; o_line_de = 1'b0; osum = 0; isum = 0;
    i_hs_q = 1'b1; i_vs_q = 1'b1; i_line_de = 1'b0;
    repeat (8) @(negedge clk_sys);
    rst_n = 1'b1;
    repeat (2000) @(negedge clk_sys);

    // ---- case 1: the default block (defsyncm24, io/gdc.c:42): 848x440, 640x400 ----
    sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h07; sb[3] = 8'h25;
    sb[4] = 8'h07; sb[5] = 8'h07; sb[6] = 8'h90; sb[7] = 8'h65;
    run_case("default (no SYNC)", 0);
    expect_eq(g_htotal, 848, "default HTOTAL"); expect_eq(g_vtotal, 440, "default VTOTAL");
    // The same raster with the runtime enable off: the input itself.
    dbl_en = 1'b0;
    wait_frame; wait_frame;
    measure("default, enable off", 0);

    // ---- case 2: defsyncm15 (io/gdc.c:43) on the 24 kHz machine: an 896-dot line ----
    sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h07; sb[3] = 8'h25;
    sb[4] = 8'h0d; sb[5] = 8'h0f; sb[6] = 8'hc8; sb[7] = 8'h94;
    run_case("defsyncm15 (896 dots)", 1);
    expect_eq(g_htotal, 896, "defsyncm15 HTOTAL");

    // ---- case 3: the hand-built 550-line block (lf 480, vs 10, vfp 20, vbp 40) ----
    sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h47; sb[3] = 8'h25;
    sb[4] = 8'h07; sb[5] = 8'h14; sb[6] = 8'he0; sb[7] = 8'hA1;
    run_case("hand-built 550 lines", 1);
    expect_eq(g_vtotal, 550, "550-block VTOTAL");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_LINE_DOUBLER: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_LINE_DOUBLER: FAIL (%0d errors)", errors);
  end

  initial begin
    repeat (60_000_000) @(posedge clk_sys);
    $fatal(1, "TB_PC9821_LINE_DOUBLER: TIMEOUT");
  end
endmodule

`timescale 1ps/1ps

// ==== WHAT THIS PROVES ====
// The analog output recovers within one output frame when the guest reprograms the master GDC mid-frame: with clk_sys 80 MHz, the core's dot enable and the real pc9821_crtc feeding pc9821_video_out (native and doubled), a SYNC block written in the middle of a frame - the 550-line block (lf 480), defsyncm15 (an 896-dot line) and back to the default - and a GDC RESET command with the default block leave, from the SECOND output frame after the write on, every line exactly the new length (native 2 x HTOTAL, doubled HTOTAL video clocks - HTOTAL from the block by NP2kai's gdc_updateclock() transcription), every VSYNC edge on an HSYNC leading edge, no DE inside HSYNC or VSYNC, and no crossing-FIFO event; what the transition frame carried is printed. FAIL-FIRST: it passes on the current design, so it is proven able to fail by recorded mutants of the crossing FIFO's recovery and the doubler's line resynchronisation.
//
// WHAT IT IS BLIND TO: the graphics plane (text-only raster), the real PLL's relock time (modelled as a
// reset window), and what a monitor makes of the transition frame - only that it does not stick.

module tb_pc9821_video_reprogram;
  reg clk_sys = 0;
  always #6250 clk_sys = ~clk_sys;   // 80 MHz
  wire pix_ce;
  reg  dce_rst = 1'b1;
  pc9821_dot_ce #(.SYS_FREQ(80_000_000)) dot_ce (.clk(clk_sys), .reset(dce_rst), .ce(pix_ce));

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
  wire        pal_wr_en, pal_commit;
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
      .pal_wr_chan(pal_wr_chan), .pal_wr_data(pal_wr_data), .pal_commit(pal_commit),
      .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
  );


  // ---- the video PLL model: 800/19 MHz (2 x the dot rate), an ideal clock ----
  reg  run_dbl = 1'b0;
  reg  clk_vid = 1'b0, vid_rst = 1'b1;
  always #11_875 clk_vid = ~clk_vid;
  initial begin
    repeat (20) @(posedge clk_vid);
    vid_rst = 1'b0;
  end

  wire       v_ce, v_hs, v_vs, v_de, v_dbl, v_ev;
  wire [7:0] v_r, v_g, v_b;
  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_video_out #(.DBL_EN(1'b1)) vout (
    .clk_sys(clk_sys), .ce(pix_ce),
    .r_in({8{text_opaque}}), .g_in(8'h40), .b_in(8'h20), .hs_in(hs_out), .vs_in(vs_out), .de_in(de_out),
    .dbl_on(run_dbl),
    .clk_vid(clk_vid), .vclk_31(1'b0), .vid_rst(vid_rst),   // this bench is the 24 kHz converter
    .clk_video(), .ce_out(v_ce),
    .r_out(v_r), .g_out(v_g), .b_out(v_b), .hs_out(v_hs), .vs_out(v_vs), .de_out(v_de),
    .dbl_active(v_dbl), .fifo_ev(v_ev)
  );
  /* verilator lint_on PINCONNECTEMPTY */

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
  // entries are other machines' monitors.
  localparam integer CLK_MINX = 100, CLK_MAXX = 112;
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

  integer k;
  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum; io_din = data; io_wr = 1'b1;
      @(negedge clk_sys);
      io_wr = 1'b0;
    end
  endtask
  task automatic write_block(input [7:0] cmd);
    begin
      write_io(8'h62, cmd);
      for (k = 0; k < 8; k = k + 1) write_io(8'h60, sb[k]);
    end
  endtask

  // ==== CHECKS: per output frame, in clocks of the video clock ====
  reg     q_hs = 1'b1, q_vs = 1'b1;
  longint vclk_n = 0, last_hs = -1;
  integer f_lo, f_hi, f_lines, f_vsoff, f_desync, f_ev, f_vsw;
  integer frames = 0;
  integer errors = 0;
  integer cur_lo, cur_hi, cur_lines, cur_vsoff, cur_desync, cur_ev;
  initial begin cur_lo = 1 << 30; cur_hi = 0; cur_lines = 0; cur_vsoff = 0; cur_desync = 0; cur_ev = 0; end
  always @(posedge clk_vid) begin
    vclk_n <= vclk_n + 1;
    if (v_ev) cur_ev = cur_ev + 1;
    if (v_ce) begin
      q_hs <= v_hs; q_vs <= v_vs;
      if (v_de && (!v_hs || !v_vs)) cur_desync = cur_desync + 1;
      if (q_vs != v_vs && !(q_hs && !v_hs)) cur_vsoff = cur_vsoff + 1;
      if (q_hs && !v_hs) begin
        if (last_hs >= 0) begin
          if (vclk_n - last_hs < cur_lo) cur_lo = int'(vclk_n - last_hs);
          if (vclk_n - last_hs > cur_hi) cur_hi = int'(vclk_n - last_hs);
        end
        last_hs <= vclk_n;
        cur_lines = cur_lines + 1;
      end
      if (q_vs && !v_vs) begin
        f_lo = cur_lo; f_hi = cur_hi; f_lines = cur_lines; f_vsoff = cur_vsoff; f_desync = cur_desync; f_ev = cur_ev;
        frames = frames + 1;
        cur_lo = 1 << 30; cur_hi = 0; cur_lines = 0; cur_vsoff = 0; cur_desync = 0; cur_ev = 0;
      end
    end
  end

  task automatic wait_out_frames(input integer n);
    integer f0;
    begin
      f0 = frames;
      wait (frames >= f0 + n);
    end
  endtask

  // After a change: report the transition frame, then require the next frame clean.
  task automatic check_after(input string name, input integer clk_per_dot);
    integer want;
    begin
      np2_sync_geometry;
      want = clk_per_dot * g_htotal;
      wait_out_frames(1);
      $display("  %-34s transition frame: lines %0d..%0d clocks x %0d, %0d VS edges off HS, %0d DE in sync, %0d FIFO events",
               name, f_lo, f_hi, f_lines, f_vsoff, f_desync, f_ev);
      wait_out_frames(1);
      wait_out_frames(1);
      $display("  %-34s clean frame:      lines %0d..%0d clocks x %0d (want %0d), %0d VS edges off HS, %0d DE in sync, %0d FIFO events",
               name, f_lo, f_hi, f_lines, want, f_vsoff, f_desync, f_ev);
      if (f_lo != want || f_hi != want || f_vsoff != 0 || f_desync != 0 || f_ev != 0) begin
        $display("FAIL %0s: the output is not clean one frame after the change", name);
        errors = errors + 1;
      end
    end
  endtask

  task automatic set_block(input [7:0] b0, b1, b2, b3, b4, b5, b6, b7);
    begin
      sb[0] = b0; sb[1] = b1; sb[2] = b2; sb[3] = b3; sb[4] = b4; sb[5] = b5; sb[6] = b6; sb[7] = b7;
    end
  endtask

  task automatic run_mode(input string mode, input bit dbl, input integer cpd);
    begin
      run_dbl = dbl;
      set_block(8'h10, 8'h4e, 8'h07, 8'h25, 8'h07, 8'h07, 8'h90, 8'h65);
      wait_out_frames(4);
      // mid-frame: wait for the middle of an output frame, then write
      wait_out_frames(1);
      repeat (300000) @(negedge clk_sys);
      set_block(8'h10, 8'h4e, 8'h47, 8'h25, 8'h07, 8'h14, 8'he0, 8'hA1);   // the 550-line block (lf 480)
      write_block(8'h0F);
      check_after({mode, " SYNC -> 550 lines"}, cpd);
      repeat (300000) @(negedge clk_sys);
      set_block(8'h10, 8'h4e, 8'h07, 8'h25, 8'h0d, 8'h0f, 8'hc8, 8'h94);   // defsyncm15: 896 dots
      write_block(8'h0F);
      check_after({mode, " SYNC -> 896 dots"}, cpd);
      repeat (300000) @(negedge clk_sys);
      set_block(8'h10, 8'h4e, 8'h07, 8'h25, 8'h07, 8'h07, 8'h90, 8'h65);   // GDC RESET with the default
      write_block(8'h00);
      write_block(8'h0F);
      check_after({mode, " RESET + default SYNC"}, cpd);
    end
  endtask

  initial begin
    repeat (8) @(negedge clk_sys);
    dce_rst = 1'b0;
    rst_n = 1'b1;
    repeat (2000) @(negedge clk_sys);
    run_mode("native",  1'b0, 2);
    run_mode("doubled", 1'b1, 1);
    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_VIDEO_REPROGRAM: FAIL (%0d errors)", errors);
    $display("TB_PC9821_VIDEO_REPROGRAM: PASS");
    $finish;
  end
endmodule

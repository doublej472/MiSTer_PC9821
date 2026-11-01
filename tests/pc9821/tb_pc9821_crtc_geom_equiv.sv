`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The CRTC's registered raster geometry (V1-a: the clamped totals registered from the SYNC block as it arrives on the frame-boundary edge the copy of the block uses, and every derived compare operand - HACTIVE, the HSYNC/VSYNC bounds, the frame-end/walk-slot bounds - registered every clk_sys from them, one clk_sys behind, so every raster compare reads a register) is cycle-for-cycle identical to the pre-change module (pc9821_crtc_ref.sv, the module as of ad9ed84c): over tens of frames of random, default-perturbed and clamp-extreme SYNC blocks (every field at zero and at its maximum, cr past the line, lf of 0/1/1024, an all-zero blanking), with the block's last byte landing one cycle before, ON and one cycle after the frame-boundary edge, random command/MODE/CRTC/palette/text-RAM traffic, irregular pixel_ce, and machine resets mid-frame, right after a SYNC write and on the frame-boundary edge, every one of the module's 57 outputs (hs/vs/de, o_htotal/o_vtotal/o_vbp, the frame and snapshot strobes, the vsync IRQ and status bits, the text fetch and render ports, the palette ports, io_dout) matches on every clk_sys cycle - with the text-modes lane's three stated exceptions: the stimulus keeps the CRTC render registers, CSRFORM's LR and the PRAM partition lengths at their power-on values (the domain where the text line sequencer IS the old 16-line grid; beyond it tb_pc9821_text_modes holds NP2kai's maketext), the kanji row cache's bank NAME (jc_rd_bank) is not compared, and the text fetch/render ports are compared on active lines below 511 (a taller frame now fetches rows 32-35 instead of truncating them).

// The reference is the pre-change TEXT, not a model of the hardware: this bench proves the
// restructure did not change behaviour. The raster's hardware behaviour itself is pinned by
// tb_pc9821_gdc_sync_raster (NP2kai's field map) and tb_pc9821_gdc_text; the geometry function
// alone is proven equal for EVERY block by tools/equiv/crtc_geom.sv and its one-clk lag harmless
// by tools/equiv/crtc_geom_lag.sv (tools/check_micro_equiv.py).

// ==== DUT ====
// pc9821_crtc vs pc9821_crtc_ref, every input shared.
module tb_pc9821_crtc_geom_equiv;
  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;
  reg        rst_n_sys = 0, pixel_ce = 1;
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_addr = 8'h60, io_din = 8'h00;
  reg [13:0] tram_cpu_addr = 0;
  reg  [7:0] tram_cpu_din = 0;
  reg        tram_cpu_we = 0;
  reg  [2:0] cfg_fdd_mode = 0;
  reg        wk_tr_read = 0;
  reg [13:0] wk_tr_addr = 0;
  reg [15:0] ank_word = 0;
  reg [31:0] jc_rd_q = 0;
  reg  [7:0] cg_ram_vid_q = 0;
  reg        vsync_irq_arm = 0;

  wire [7:0] d_io_dout, r_io_dout;
  wire [10:0] d_gdc_ff2_state, r_gdc_ff2_state;
  wire [7:0] d_tram_cpu_dout, r_tram_cpu_dout;
  wire [7:0] d_o_tram_vid_q, r_o_tram_vid_q;
  wire [10:0] d_ank_rd_addr, r_ank_rd_addr;
  wire [1:0] d_jc_rd_bank, r_jc_rd_bank;
  wire [6:0] d_jc_rd_cell, r_jc_rd_cell;
  wire [1:0] d_jc_rd_word, r_jc_rd_word;
  wire [12:0] d_cg_ram_vid_addr, r_cg_ram_vid_addr;
  wire [7:0] d_o_v_pitch, r_o_v_pitch;
  wire d_o_v_col40, r_o_v_col40;
  wire [15:0] d_o_v_sad, r_o_v_sad;
  wire d_o_v_row0_stale, r_o_v_row0_stale;
  wire [9:0] d_o_vline, r_o_vline;
  wire [9:0] d_o_hdot, r_o_hdot;
  wire [9:0] d_o_htotal, r_o_htotal;
  wire [9:0] d_o_vtotal, r_o_vtotal;
  wire [5:0] d_o_vbp, r_o_vbp;
  wire d_o_frame_end, r_o_frame_end;
  wire d_o_cfg_snap, r_o_cfg_snap;
  wire d_o_cfg_pending, r_o_cfg_pending;
  wire d_o_display_page, r_o_display_page;
  wire d_o_stat_blank, r_o_stat_blank;
  wire d_o_stat_vsync, r_o_stat_vsync;
  wire d_vsync_active, r_vsync_active;
  wire d_vsync_edge, r_vsync_edge;
  wire d_vsync_irq, r_vsync_irq;
  wire d_disp_on, r_disp_on;
  wire d_gfx_access_page, r_gfx_access_page;
  wire d_gfx_egc_gate, r_gfx_egc_gate;
  wire [15:0] d_dbg_sad, r_dbg_sad;
  wire [7:0] d_dbg_pitch, r_dbg_pitch;
  wire d_dbg_col40, r_dbg_col40;
  wire d_dbg_disp, r_dbg_disp;
  wire d_text_opaque, r_text_opaque;
  wire d_text_cell, r_text_cell;
  wire [11:0] d_text_colour, r_text_colour;
  wire [9:0] d_pix_dot, r_pix_dot;
  wire d_pix_h_active, r_pix_h_active;
  wire d_pix_v_active, r_pix_v_active;
  wire d_gfx_odd_line, r_gfx_odd_line;
  wire d_gfx_mode16, r_gfx_mode16;
  wire [31:0] d_gfx_dig, r_gfx_dig;
  wire d_pal_wr_en, r_pal_wr_en;
  wire [3:0] d_pal_wr_idx, r_pal_wr_idx;
  wire [1:0] d_pal_wr_chan, r_pal_wr_chan;
  wire [3:0] d_pal_wr_data, r_pal_wr_data;
  wire d_pal_commit, r_pal_commit;
  wire d_pal256_wr_en, r_pal256_wr_en;
  wire [7:0] d_pal256_wr_idx, r_pal256_wr_idx;
  wire [1:0] d_pal256_wr_chan, r_pal256_wr_chan;
  wire [7:0] d_pal256_wr_data, r_pal256_wr_data;
  wire d_gfx_pegc_256, r_gfx_pegc_256;
  wire d_gfx_pegc_256e, r_gfx_pegc_256e;
  wire d_hs_out, r_hs_out;
  wire d_vs_out, r_vs_out;
  wire d_de_out, r_de_out;

  pc9821_crtc dut (
      .crt31k(1'b0),   // 0x09A8 bit 0 clear: the 24 kHz monitor range
      .gfx_win_on(1'b0),   // no slave window: the master's lines alone (the reference's shape)
      .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .rst_n_vid(rst_n_sys), .pixel_ce(pixel_ce), .io_wr(io_wr),
      .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din),
      .tram_cpu_addr(tram_cpu_addr), .tram_cpu_din(tram_cpu_din), .tram_cpu_we(tram_cpu_we),
      .cfg_fdd_mode(cfg_fdd_mode), .wk_tr_read(wk_tr_read), .wk_tr_addr(wk_tr_addr),
      .ank_word(ank_word), .jc_rd_q(jc_rd_q), .cg_ram_vid_q(cg_ram_vid_q),
      .vsync_irq_arm(vsync_irq_arm), .io_dout(d_io_dout), .gdc_ff2_state(d_gdc_ff2_state),
      .tram_cpu_dout(d_tram_cpu_dout), .o_tram_vid_q(d_o_tram_vid_q),
      .ank_rd_addr(d_ank_rd_addr), .jc_rd_bank(d_jc_rd_bank), .jc_rd_cell(d_jc_rd_cell),
      .jc_rd_word(d_jc_rd_word), .cg_ram_vid_addr(d_cg_ram_vid_addr), .o_v_pitch(d_o_v_pitch),
      .o_v_col40(d_o_v_col40), .o_v_sad(d_o_v_sad), .o_v_row0_stale(d_o_v_row0_stale),
      .o_vline(d_o_vline), .o_hdot(d_o_hdot), .o_htotal(d_o_htotal), .o_vtotal(d_o_vtotal),
      .o_vbp(d_o_vbp), .o_frame_end(d_o_frame_end), .o_cfg_snap(d_o_cfg_snap),
      .o_cfg_pending(d_o_cfg_pending), .o_display_page(d_o_display_page),
      .o_stat_blank(d_o_stat_blank), .o_stat_vsync(d_o_stat_vsync),
      .vsync_active(d_vsync_active), .vsync_edge(d_vsync_edge), .vsync_irq(d_vsync_irq),
      .disp_on(d_disp_on), .gfx_access_page(d_gfx_access_page), .gfx_egc_gate(d_gfx_egc_gate),
      .dbg_sad(d_dbg_sad), .dbg_pitch(d_dbg_pitch), .dbg_col40(d_dbg_col40),
      .dbg_disp(d_dbg_disp), .text_opaque(d_text_opaque), .text_cell(d_text_cell),
      .text_colour(d_text_colour), .pix_dot(d_pix_dot), .pix_h_active(d_pix_h_active),
      .pix_v_active(d_pix_v_active), .gfx_odd_line(d_gfx_odd_line), .gfx_mode16(d_gfx_mode16),
      .gfx_dig(d_gfx_dig), .pal_wr_en(d_pal_wr_en), .pal_wr_idx(d_pal_wr_idx),
      .pal_wr_chan(d_pal_wr_chan), .pal_wr_data(d_pal_wr_data), .pal_commit(d_pal_commit),
      .pal256_wr_en(d_pal256_wr_en), .pal256_wr_idx(d_pal256_wr_idx),
      .pal256_wr_chan(d_pal256_wr_chan), .pal256_wr_data(d_pal256_wr_data),
      .gfx_pegc_256(d_gfx_pegc_256), .gfx_pegc_256e(d_gfx_pegc_256e), .hs_out(d_hs_out),
      .vs_out(d_vs_out), .de_out(d_de_out));
  pc9821_crtc_ref ref0 (
      .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .pixel_ce(pixel_ce), .io_wr(io_wr),
      .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din),
      .tram_cpu_addr(tram_cpu_addr), .tram_cpu_din(tram_cpu_din), .tram_cpu_we(tram_cpu_we),
      .cfg_fdd_mode(cfg_fdd_mode), .wk_tr_read(wk_tr_read), .wk_tr_addr(wk_tr_addr),
      .ank_word(ank_word), .jc_rd_q(jc_rd_q), .cg_ram_vid_q(cg_ram_vid_q),
      .vsync_irq_arm(vsync_irq_arm), .io_dout(r_io_dout), .gdc_ff2_state(r_gdc_ff2_state),
      .tram_cpu_dout(r_tram_cpu_dout), .o_tram_vid_q(r_o_tram_vid_q),
      .ank_rd_addr(r_ank_rd_addr), .jc_rd_bank(r_jc_rd_bank), .jc_rd_cell(r_jc_rd_cell),
      .jc_rd_word(r_jc_rd_word), .cg_ram_vid_addr(r_cg_ram_vid_addr), .o_v_pitch(r_o_v_pitch),
      .o_v_col40(r_o_v_col40), .o_v_sad(r_o_v_sad), .o_v_row0_stale(r_o_v_row0_stale),
      .o_vline(r_o_vline), .o_hdot(r_o_hdot), .o_htotal(r_o_htotal), .o_vtotal(r_o_vtotal),
      .o_vbp(r_o_vbp), .o_frame_end(r_o_frame_end), .o_cfg_snap(r_o_cfg_snap),
      .o_cfg_pending(r_o_cfg_pending), .o_display_page(r_o_display_page),
      .o_stat_blank(r_o_stat_blank), .o_stat_vsync(r_o_stat_vsync),
      .vsync_active(r_vsync_active), .vsync_edge(r_vsync_edge), .vsync_irq(r_vsync_irq),
      .disp_on(r_disp_on), .gfx_access_page(r_gfx_access_page), .gfx_egc_gate(r_gfx_egc_gate),
      .dbg_sad(r_dbg_sad), .dbg_pitch(r_dbg_pitch), .dbg_col40(r_dbg_col40),
      .dbg_disp(r_dbg_disp), .text_opaque(r_text_opaque), .text_cell(r_text_cell),
      .text_colour(r_text_colour), .pix_dot(r_pix_dot), .pix_h_active(r_pix_h_active),
      .pix_v_active(r_pix_v_active), .gfx_odd_line(r_gfx_odd_line), .gfx_mode16(r_gfx_mode16),
      .gfx_dig(r_gfx_dig), .pal_wr_en(r_pal_wr_en), .pal_wr_idx(r_pal_wr_idx),
      .pal_wr_chan(r_pal_wr_chan), .pal_wr_data(r_pal_wr_data), .pal_commit(r_pal_commit),
      .pal256_wr_en(r_pal256_wr_en), .pal256_wr_idx(r_pal256_wr_idx),
      .pal256_wr_chan(r_pal256_wr_chan), .pal256_wr_data(r_pal256_wr_data),
      .gfx_pegc_256(r_gfx_pegc_256), .gfx_pegc_256e(r_gfx_pegc_256e), .hs_out(r_hs_out),
      .vs_out(r_vs_out), .de_out(r_de_out));

  // THE TEXT-MODES CHANGE: the reference decodes the text plane's rows as a
  // fixed 16-line grid of one partition, which is the line sequencer's behaviour for the
  // power-on CRTC registers, LR = 15 and a zero partition length - so the stimulus below keeps
  // exactly those (the CRTC ports are written their power-on values, and the command stream's
  // CSRFORM and PRAM commands are replaced, like SYNC's). What the sequencer adds beyond that
  // domain is tb_pc9821_text_modes's, against NP2kai's maketext. jc_rd_bank is left out of the
  // compare: the kanji row cache's banks are now numbered by a mod-3 count of row reloads
  // instead of (row == 0) ? 2 : row[0] - a different NAME for the same three banks, held
  // coherent with the walker by pc9821_cg's bank assertion and the kanji benches.
  // ...and the text fetch/render family is compared on the reference's ACTIVE lines below line
  // 511 only: on a blanked line those ports are read addresses no fetch consumes, and the
  // sequencer leaves them at its own run-on state rather than at vline; at line 511 and below
  // a frame taller than 512 lines now fetches rows 32-35 instead of truncating them onto rows
  // 0-3 (the known limitation the six-bit row index retires).
  // A tall frame's last fetched cell is still in the render registers at the next frame's
  // first cell (its prefetch is not the wrap cell when HACTIVE runs past 640), so the first two
  // cells of line 0 after such a frame are left out too.
  reg tall_prev = 1'b0;
  always @(posedge clk_sys)
    if (r_pix_v_active && r_o_vline >= 10'd511) tall_prev <= 1'b1;
    else if (r_o_vline == 10'd0 && r_o_hdot == 10'd16) tall_prev <= 1'b0;
  wire fetch_cmp = r_pix_v_active && (r_o_vline < 10'd511) &&
                   !(tall_prev && r_o_vline == 10'd0 && r_o_hdot < 10'd16);
  wire [7:0] dm_o_tram_vid_q = fetch_cmp ? d_o_tram_vid_q : 8'd0;
  wire [7:0] rm_o_tram_vid_q = fetch_cmp ? r_o_tram_vid_q : 8'd0;
  wire [10:0] dm_ank_rd_addr = fetch_cmp ? d_ank_rd_addr : 11'd0;
  wire [10:0] rm_ank_rd_addr = fetch_cmp ? r_ank_rd_addr : 11'd0;
  wire [6:0] dm_jc_rd_cell = fetch_cmp ? d_jc_rd_cell : 7'd0;
  wire [6:0] rm_jc_rd_cell = fetch_cmp ? r_jc_rd_cell : 7'd0;
  wire [1:0] dm_jc_rd_word = fetch_cmp ? d_jc_rd_word : 2'd0;
  wire [1:0] rm_jc_rd_word = fetch_cmp ? r_jc_rd_word : 2'd0;
  wire [12:0] dm_cg_ram_vid_addr = fetch_cmp ? d_cg_ram_vid_addr : 13'd0;
  wire [12:0] rm_cg_ram_vid_addr = fetch_cmp ? r_cg_ram_vid_addr : 13'd0;
  wire [0:0] dm_text_opaque = fetch_cmp ? d_text_opaque : 1'd0;
  wire [0:0] rm_text_opaque = fetch_cmp ? r_text_opaque : 1'd0;
  wire [0:0] dm_text_cell = fetch_cmp ? d_text_cell : 1'd0;
  wire [0:0] rm_text_cell = fetch_cmp ? r_text_cell : 1'd0;
  wire [11:0] dm_text_colour = fetch_cmp ? d_text_colour : 12'd0;
  wire [11:0] rm_text_colour = fetch_cmp ? r_text_colour : 12'd0;
  localparam integer OW = 276;
  wire [OW-1:0] d_all = {d_io_dout, d_gdc_ff2_state, d_tram_cpu_dout, dm_o_tram_vid_q, dm_ank_rd_addr, 2'b00 /* jc_rd_bank: see the note */, dm_jc_rd_cell, dm_jc_rd_word, dm_cg_ram_vid_addr, d_o_v_pitch, d_o_v_col40, d_o_v_sad, d_o_v_row0_stale, d_o_vline, d_o_hdot, d_o_htotal, d_o_vtotal, d_o_vbp, d_o_frame_end, d_o_cfg_snap, d_o_cfg_pending, d_o_display_page, d_o_stat_blank, d_o_stat_vsync, d_vsync_active, d_vsync_edge, d_vsync_irq, d_disp_on, d_gfx_access_page, d_gfx_egc_gate, d_dbg_sad, d_dbg_pitch, d_dbg_col40, d_dbg_disp, dm_text_opaque, dm_text_cell, dm_text_colour, d_pix_dot, d_pix_h_active, d_pix_v_active, d_gfx_odd_line, d_gfx_mode16, d_gfx_dig, d_pal_wr_en, d_pal_wr_idx, d_pal_wr_chan, d_pal_wr_data, d_pal_commit, d_pal256_wr_en, d_pal256_wr_idx, d_pal256_wr_chan, d_pal256_wr_data, d_gfx_pegc_256, d_gfx_pegc_256e, 1'b0 /* hs_out: see below */, 1'b0 /* vs_out: see below */, d_de_out};
  wire [OW-1:0] r_all = {r_io_dout, r_gdc_ff2_state, r_tram_cpu_dout, rm_o_tram_vid_q, rm_ank_rd_addr, 2'b00 /* jc_rd_bank: see the note */, rm_jc_rd_cell, rm_jc_rd_word, rm_cg_ram_vid_addr, r_o_v_pitch, r_o_v_col40, r_o_v_sad, r_o_v_row0_stale, r_o_vline, r_o_hdot, r_o_htotal, r_o_vtotal, r_o_vbp, r_o_frame_end, r_o_cfg_snap, r_o_cfg_pending, r_o_display_page, r_o_stat_blank, r_o_stat_vsync, r_vsync_active, r_vsync_edge, r_vsync_irq, r_disp_on, r_gfx_access_page, r_gfx_egc_gate, r_dbg_sad, r_dbg_pitch, r_dbg_col40, r_dbg_disp, rm_text_opaque, rm_text_cell, rm_text_colour, r_pix_dot, r_pix_h_active, r_pix_v_active, r_gfx_odd_line, r_gfx_mode16, r_gfx_dig, r_pal_wr_en, r_pal_wr_idx, r_pal_wr_chan, r_pal_wr_data, r_pal_commit, r_pal256_wr_en, r_pal256_wr_idx, r_pal256_wr_chan, r_pal256_wr_data, r_gfx_pegc_256, r_gfx_pegc_256e, 1'b0 /* hs_out: see below */, 1'b0 /* vs_out: see below */, r_de_out};

  // hs_out is OUT of the equivalence since 2026-10-15: the horizontal porches moved deliberately
  // to the uPD7220 field map (HFP 8*(hfp+1), HS 8*(hs+1), the back porch the rest; MAME
  // upd7220.cpp:1243-1246), so the hsync sits where the reference's NP2kai-sum split did not put it.
  // Its new position is pinned against the SYNC block by tb_pc9821_gdc_sync_raster. vs_out likewise
  // (2026-10-16): the PIN's VSYNC now moves on the HSYNC leading edge (MAME update_vsync_timer), also
  // pinned there; the internal vsync (status bit 5, the IRQ) stays in the comparison. Every other
  // output (hblank/status bit 6, vsync, DE, the counters) stays cycle-identical here.
  // ==== CHECKS ====
  integer errors = 0, cycles = 0, frames = 0, hs_edges = 0, vs_edges = 0;
  integer syncs = 0, edge_lands = 0, resets = 0, clamp_blocks = 0;
  integer seed = 12345;
  reg hs_d = 1, vs_d = 1;
  // Compared just before every rising edge: the registers' values and every combinational
  // output of the inputs the bench drove at the falling edge - from the first reset edge on
  // (before it neither module's registers hold a defined value: the pre-change module's
  // copy of the block and the new geometry register are both unreset, so their power-up
  // decode differs for the one simulated cycle before reset, as no guest can see).
  reg seen_reset = 0;
  always @(posedge clk_sys) begin
    cycles = cycles + 1;
    if (!rst_n_sys) seen_reset <= 1;
    if (seen_reset && d_all !== r_all) begin
      errors = errors + 1;
      if (errors <= 10)
        $display("MISMATCH cycle %0d at line %0d dot %0d: dut^ref %h (hs %b/%b vs %b/%b de %b/%b fe %b/%b htot %0d/%0d vtot %0d/%0d)",
                 cycles, r_o_vline, r_o_hdot, d_all ^ r_all, d_hs_out, r_hs_out, d_vs_out, r_vs_out, d_de_out, r_de_out,
                 d_o_frame_end, r_o_frame_end, d_o_htotal, r_o_htotal, d_o_vtotal, r_o_vtotal);
    end
    if (rst_n_sys && pixel_ce && r_o_frame_end) frames = frames + 1;
    hs_d <= r_hs_out; vs_d <= r_vs_out;
    if (hs_d && !r_hs_out) hs_edges = hs_edges + 1;
    if (vs_d && !r_vs_out) vs_edges = vs_edges + 1;
  end

  // Background inputs, re-drawn at every falling edge: the font/CG/walker data, the text-RAM
  // CPU port, the IRQ arm and (in the gap phases) the dot enable.
  integer ce_mode = 0;   // 0: every cycle, 1: random 3 of 4, 2: random 1 of 2
  always @(negedge clk_sys) begin
    ank_word     <= $random(seed);
    jc_rd_q      <= $random(seed);
    cg_ram_vid_q <= $random(seed);
    wk_tr_read   <= (($random(seed) & 63) == 0);
    wk_tr_addr   <= $random(seed);
    tram_cpu_we  <= (($random(seed) & 31) == 0);
    tram_cpu_addr <= $random(seed);
    tram_cpu_din <= $random(seed);
    if (($random(seed) & 1023) == 0) vsync_irq_arm <= ~vsync_irq_arm;
    pixel_ce <= (ce_mode == 0) ? 1'b1 : (ce_mode == 1) ? (($random(seed) & 3) != 0)
                                                       : (($random(seed) & 1) != 0);
  end

  // One I/O write in the cycle after the next falling edge.
  task automatic wr(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk_sys); io_addr = a; io_din = d; io_wr = 1;
      @(negedge clk_sys); io_wr = 0;
    end
  endtask
  task automatic rd(input [7:0] a);
    begin
      @(negedge clk_sys); io_addr = a; io_rd = 1;
      @(negedge clk_sys); io_rd = 0;
    end
  endtask

  reg [7:0] blk [0:7];
  // A block of class k: 0 random, 1 the default with one field perturbed, 2 clamp extremes.
  task automatic make_block(input integer k);
    integer f;
    begin
      blk[0] = 8'h10; blk[1] = 8'h4e; blk[2] = 8'h07; blk[3] = 8'h25;
      blk[4] = 8'h07; blk[5] = 8'h07; blk[6] = 8'h90; blk[7] = 8'h65;
      if (k == 0) begin
        for (f = 0; f < 8; f = f + 1) blk[f] = $random(seed);
      end else if (k == 1) begin
        f = 1 + ({$random(seed)} % 7);
        blk[f] = blk[f] ^ (8'h01 << ({$random(seed)} % 8));
      end else begin
        clamp_blocks = clamp_blocks + 1;
        case ({$random(seed)} % 6)
          0: begin blk[1] = 8'hFF; end                                  // cr past the line
          1: begin blk[2] = 8'h00; blk[3] = 8'h00; blk[4] = 8'h00;       // hs = vs = hfp = 0
                   blk[5] = 8'h00; blk[7] = blk[7] & 8'h03; end          // and vfp = vbp = 0
          2: begin blk[6] = 8'h00; blk[7] = 8'h00; end                   // lf = 1024, vbp 0
          3: begin blk[6] = 8'h01; blk[7] = 8'hFC; end                   // lf = 1, vbp max
          4: begin blk[2] = 8'hFF; blk[3] = 8'hFF; blk[4] = 8'hFF;       // every field at max
                   blk[5] = 8'hFF; blk[6] = 8'hFF; blk[7] = 8'hFF; end
          default: begin blk[1] = 8'h00; blk[6] = 8'h40; blk[7] = 8'h02; end  // narrow, 576 lf
        endcase
      end
    end
  endtask

  // The SYNC command and its eight bytes. land: 0 anywhere; 1/2/3 = the last byte one cycle
  // before, ON, or one cycle after the frame-boundary edge (the cycle frame_end && pixel_ce).
  task automatic sync_block(input integer land);
    integer i, g;
    begin
      wr(8'h62, ($random(seed) & 1) ? 8'h0F : 8'h0E);
      for (i = 0; i < 7; i = i + 1) begin
        wr(8'h60, blk[i]);
        for (g = {$random(seed)} % 4; g > 0; g = g - 1) @(negedge clk_sys);
      end
      if (land == 0) wr(8'h60, blk[7]);
      else begin
        // Find the edge (frame_end is a function of the registers, pixel_ce the bench's).
        @(negedge clk_sys);
        while (!(r_o_frame_end && pixel_ce)) @(negedge clk_sys);
        if (land == 1) begin
          // the edge is NOW: write in the cycle before is no longer possible, so wait for the
          // next frame's edge one dot earlier - the cycle whose hdot is HTOTAL-2
          @(negedge clk_sys);
          while (!(r_o_vline == r_o_vtotal - 10'd1 && r_o_hdot == r_o_htotal - 10'd2)) @(negedge clk_sys);
          io_addr = 8'h60; io_din = blk[7]; io_wr = 1;
          @(negedge clk_sys); io_wr = 0;
        end else if (land == 2) begin
          io_addr = 8'h60; io_din = blk[7]; io_wr = 1;
          @(negedge clk_sys); io_wr = 0;
        end else begin
          @(negedge clk_sys);
          io_addr = 8'h60; io_din = blk[7]; io_wr = 1;
          @(negedge clk_sys); io_wr = 0;
        end
        edge_lands = edge_lands + 1;
      end
      syncs = syncs + 1;
    end
  endtask

  // Unrelated register traffic between blocks: MODE FF1/FF2, the CRTC registers, the
  // palette/page ports, GDC commands (START/STOP/PITCH/CSRFORM/RESET...), and reads.
  localparam integer NPORTS = 18;
  reg [7:0] ports [0:NPORTS-1];
  initial begin
    ports[0] = 8'h62; ports[1] = 8'h60; ports[2] = 8'h64; ports[3] = 8'h68; ports[4] = 8'h6A;
    ports[5] = 8'h6E; ports[6] = 8'h70; ports[7] = 8'h72; ports[8] = 8'h74; ports[9] = 8'h76;
    ports[10] = 8'h78; ports[11] = 8'h7A; ports[12] = 8'h7C; ports[13] = 8'hA4;
    ports[14] = 8'hA6; ports[15] = 8'hA8; ports[16] = 8'hAA; ports[17] = 8'hAC;
  end
  task automatic noise(input integer n);
    integer i; reg [7:0] p, d;
    begin
      for (i = 0; i < n; i = i + 1) begin
        p = ports[{$random(seed)} % NPORTS];
        d = $random(seed);
        // keep the command port's stream mostly to commands the CRTC takes (not SYNC: the
        // blocks are written by sync_block so their landing is controlled)
        if (p == 8'h62 && (d == 8'h0E || d == 8'h0F)) d = 8'h0D;
        // ...and not CSRFORM (its first byte is the GDC's LR) or a PRAM command (the partition
        // lengths): the reference has neither (see the note at the compare).
        if (p == 8'h62 && (d == 8'h4B || d[7:4] == 4'h7)) d = 8'h0D;
        // The CRTC render registers take their power-on values (RDBACK.TXT:82-87).
        if (p == 8'h70 || p == 8'h76 || p == 8'h78 || p == 8'h7A) d = 8'h00;
        if (p == 8'h72) d = 8'h0F;
        if (p == 8'h74) d = 8'h10;
        if (($random(seed) & 3) == 0) rd(p); else wr(p, d);
        repeat ({$random(seed)} % 200) @(negedge clk_sys);
      end
    end
  endtask

  task automatic wait_frames(input integer n);
    integer f0;
    begin
      f0 = frames;
      while (frames < f0 + n) @(negedge clk_sys);
    end
  endtask

  task automatic pulse_reset(input integer n);
    begin
      @(negedge clk_sys); rst_n_sys = 0;
      repeat (n) @(negedge clk_sys);
      rst_n_sys = 1;
      resets = resets + 1;
    end
  endtask

  // ==== VERDICT ====
  integer phase;
  initial begin
    repeat (8) @(negedge clk_sys);
    rst_n_sys = 1;
    wr(8'h62, 8'h0D);                       // START
    wr(8'h68, 8'h0F);                       // MODE FF1 display on
    for (phase = 0; phase < 36; phase = phase + 1) begin
      ce_mode = (phase % 6 == 5) ? 1 + (phase / 6) % 2 : 0;
      make_block(phase % 3);
      noise(4);
      sync_block(phase % 4);
      noise(4);
      case (phase % 9)
        2: begin wait_frames(1); repeat ({$random(seed)} % 300000) @(negedge clk_sys); pulse_reset(3); end
        4: begin make_block(0); sync_block(0); pulse_reset(2); end   // reset right after a block
        7: begin
             // a reset ON the frame-boundary edge
             @(negedge clk_sys);
             while (!(r_o_frame_end && pixel_ce)) @(negedge clk_sys);
             rst_n_sys = 0; @(negedge clk_sys); rst_n_sys = 1; resets = resets + 1;
           end
        default: ;
      endcase
      wait_frames(1);
    end
    if (frames < 30 || syncs < 36 || edge_lands < 20 || resets < 8 || clamp_blocks < 10 ||
        hs_edges < 10000 || vs_edges < 30)
      $fatal(1, "TB_PC9821_CRTC_GEOM_EQUIV: coverage short: frames %0d syncs %0d edge-lands %0d resets %0d clamp %0d hs %0d vs %0d",
             frames, syncs, edge_lands, resets, clamp_blocks, hs_edges, vs_edges);
    if (errors != 0) $fatal(1, "TB_PC9821_CRTC_GEOM_EQUIV: %0d mismatching cycles of %0d", errors, cycles);
    $display("TB_PC9821_CRTC_GEOM_EQUIV: PASS");
    $display("NOTE crtc_geom_equiv: %0d cycles, %0d frames, %0d blocks (%0d at the edge, %0d clamp), %0d resets, %0d hs / %0d vs pulses, identical",
             cycles, frames, syncs, edge_lands, clamp_blocks, resets, hs_edges, vs_edges);
    $finish;
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "TB_PC9821_CRTC_GEOM_EQUIV: timeout");
  end
endmodule

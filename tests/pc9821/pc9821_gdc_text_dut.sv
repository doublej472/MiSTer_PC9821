// Test harness: the three text-video modules composed with the port list the unit
// benches already drive (pc9821_gdc_text was split into pc9821_crtc +
// pc9821_gdc2 + pc9821_cg). The core instantiates the three directly in
// pc9821_system; this file exists only so a bench keeps one DUT with one clock,
// exactly as it had before the split. It is TEST-ONLY and is not part of the
// shipped design.
//
// The legacy clk_vid/rst_n_vid ports are gone: there is one clock (clk_sys) gated
// by pixel_ce, so a bench drives pixel_ce where it drove clk_vid_ce.
`default_nettype none

module pc9821_gdc_text_dut (
    input wire clk_sys,
    input wire rst_n_sys,
    input wire pixel_ce,

    input  wire       io_wr,
    input  wire       io_rd,
    input  wire [7:0] io_addr,
    input  wire [7:0] io_din,
    output wire [7:0] io_dout,

    input  wire [13:0] tram_cpu_addr,
    input  wire [ 7:0] tram_cpu_din,
    input  wire        tram_cpu_we,
    output wire [ 7:0] tram_cpu_dout,

    // The ONE OSD hardware-switch field (the `P1` DIP Switch page), passed straight through
    // to pc9821_crtc as a LIST POSITION: in the core it is status[42:40], and a bench that
    // does not drive it leaves it at entry 0 - the measured machine. The base memory
    // (0xA3FEA bits 2:0) is hardcoded to 640 KB inside pc9821_crtc, not passed through.
    input wire [2:0] cfg_fdd_mode,

    // The OSD Machine field (P1O[31:28], a LIST POSITION) for the software-DIP record's
    // model table: 0 = Xe10, 1 = Xe. Undriven = 0 = the measured machine, the same
    // convention as the two fields above.
    input wire [3:0] bios_set,

    input wire [17:0] font_ld_addr,
    input wire [15:0] font_ld_data,
    input wire        font_ld_we,

    input  wire  [4:0] cg_win_byte_sel,
    input  wire        cg_win_rd,
    output wire  [7:0] cg_win_dout,
    input  wire  [7:0] cg_win_din,
    input  wire        cg_win_we,
    output wire        cg_win_byte_hold,

    output wire  [18:0] font_req_addr,
    output wire         font_req,
    input  wire         font_word_valid,
    input  wire  [31:0] font_word_data,
    output wire         cg_rd_hold,

    input  wire        cg_record_restore,

    output wire vsync_active,
    output wire vsync_edge,
    input  wire vsync_irq_arm,
    output wire vsync_irq,

    output wire disp_on,
    output wire gfx_access_page,
    output wire gfx_disp,
    output wire [15:0] gfx_line_addr,
    // The PACKED walk's own page bit (SCROLL start word bit 14): the 256-colour
    // scanout's flip register (pc9821_gdc2's gfx_walk_page).
    output wire gfx_walk_page,
    output wire gfx_egc_gate,

    input  wire  [6:0] cfg_ram_mib,
    input  wire        cfg_seed_en,
    input  wire        cfg_seed_reload,

    output wire [15:0] dbg_sad,
    output wire  [7:0] dbg_pitch,
    output wire        dbg_col40,
    output wire        dbg_disp,
    output wire [15:0] dbg_wk_skips,

    output wire        text_opaque,
    output wire        text_cell,
    output wire [11:0] text_colour,

    output wire [9:0]  pix_dot,
    output wire        pix_h_active,
    output wire        pix_v_active,
    output wire        gfx_odd_line,

    output wire        gfx_mode16,
    output wire [31:0] gfx_dig,
    output wire        pal_wr_en,
    output wire [3:0]  pal_wr_idx,
    output wire [1:0]  pal_wr_chan,
    output wire [3:0]  pal_wr_data,
    output wire        pal_commit,

    output wire       hs_out,
    output wire       vs_out,
    output wire       de_out
);

  wire [10:0] crtc_ank_rd_addr;
  wire [15:0] cg_ank_word;
  wire [1:0]  crtc_jc_rd_bank;
  wire [6:0]  crtc_jc_rd_cell;
  wire [1:0]  crtc_jc_rd_word;
  wire [31:0] cg_jc_rd_q;
  wire [12:0] crtc_cg_ram_vid_addr;
  wire [7:0]  cg_cg_ram_vid_q;
  wire        cg_wk_tr_read;
  wire [13:0] cg_wk_tr_addr;
  wire [7:0]  crtc_tram_vid_q;
  wire [7:0]  crtc_o_v_pitch;
  wire        crtc_o_v_col40;
  wire [15:0] crtc_o_v_sad;
  wire        crtc_o_wk_go;
  wire [9:0]  crtc_o_wk_k;
  wire [1:0]  crtc_o_wk_bank;
  wire [9:0]  crtc_o_vline;
  wire [9:0]  crtc_o_hdot;
  wire [9:0]  crtc_o_htotal;
  wire [9:0]  crtc_o_vtotal;
  wire [5:0]  crtc_o_vbp;
  wire        gfx_grph_on;   // START && the window, the compositor's enable; benches read it hierarchically
  wire        gfx_win_off;   // the slave SYNC window gate; benches read it hierarchically
  wire        crtc_o_frame_end, crtc_o_cfg_snap, crtc_o_cfg_pending, crtc_o_display_page;
  wire        crtc_o_stat_blank, crtc_o_stat_vsync;
  wire [7:0]  crtc_io_dout, cg_io_dout, gdc2_io_dout;
  // The PEGC palette-write port and view select (pegc-scope-REPORT.md 4 row 5),
  // parked: this bench drives the I/O ports, not the palette's write port.
  wire        pal256_wr_en;
  wire  [7:0] pal256_wr_idx, pal256_wr_data;
  wire  [1:0] pal256_wr_chan;
  wire        gfx_pegc_256;
  wire [10:0] gdc_ff2_state;   // [7]/[8] are the GDC clock bits pc9821_gdc2's gdc_5m takes

  pc9821_crtc u_crtc (
      .crt31k(1'b0),   // 0x09A8 bit 0 clear: the 24 kHz monitor range
      .gfx_win_on(gfx_grph_on),   // as pc9821_system wires it
      .cfg_fdd_mode(cfg_fdd_mode),
      .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .rst_n_vid(rst_n_sys), .pixel_ce(pixel_ce),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(crtc_io_dout),
      .tram_cpu_addr(tram_cpu_addr), .tram_cpu_din(tram_cpu_din),
      .tram_cpu_we(tram_cpu_we), .tram_cpu_dout(tram_cpu_dout),
      .wk_tr_read(cg_wk_tr_read), .wk_tr_addr(cg_wk_tr_addr),
      .o_tram_vid_q(crtc_tram_vid_q),
      .ank_rd_addr(crtc_ank_rd_addr), .ank_word(cg_ank_word),
      .jc_rd_bank(crtc_jc_rd_bank), .jc_rd_cell(crtc_jc_rd_cell),
      .jc_rd_word(crtc_jc_rd_word), .jc_rd_q(cg_jc_rd_q),
      .cg_ram_vid_addr(crtc_cg_ram_vid_addr), .cg_ram_vid_q(cg_cg_ram_vid_q),
      .o_v_pitch(crtc_o_v_pitch), .o_v_col40(crtc_o_v_col40),
      .o_v_sad(crtc_o_v_sad), .o_v_row0_stale(), .o_wk_go(crtc_o_wk_go),
      .o_wk_k(crtc_o_wk_k), .o_wk_bank(crtc_o_wk_bank),
      .o_vline(crtc_o_vline), .o_hdot(crtc_o_hdot),
      .o_htotal(crtc_o_htotal), .o_vtotal(crtc_o_vtotal), .o_vbp(crtc_o_vbp),
      .o_frame_end(crtc_o_frame_end), .o_cfg_snap(crtc_o_cfg_snap),
      .o_cfg_pending(crtc_o_cfg_pending),
      .o_display_page(crtc_o_display_page), .o_stat_blank(crtc_o_stat_blank),
      .o_stat_vsync(crtc_o_stat_vsync),
      .vsync_active(vsync_active), .vsync_edge(vsync_edge),
      .vsync_irq_arm(vsync_irq_arm), .vsync_irq(vsync_irq),
      .disp_on(disp_on), .gfx_access_page(gfx_access_page),
      .gfx_egc_gate(gfx_egc_gate),
      .dbg_sad(dbg_sad), .dbg_pitch(dbg_pitch),
      .dbg_col40(dbg_col40), .dbg_disp(dbg_disp),
      .text_opaque(text_opaque), .text_cell(text_cell),
      .text_colour(text_colour),
      .pix_dot(pix_dot), .pix_h_active(pix_h_active),
      .pix_v_active(pix_v_active),
      .gfx_odd_line(gfx_odd_line),
      .gfx_mode16(gfx_mode16), .gfx_dig(gfx_dig),
      .pal_wr_en(pal_wr_en), .pal_wr_idx(pal_wr_idx),
      .pal_wr_chan(pal_wr_chan), .pal_wr_data(pal_wr_data),
      .pal_commit(pal_commit),
    .pal256_wr_en(pal256_wr_en), .pal256_wr_idx(pal256_wr_idx),
    .pal256_wr_chan(pal256_wr_chan), .pal256_wr_data(pal256_wr_data),
    .gfx_pegc_256(gfx_pegc_256), .gdc_ff2_state(gdc_ff2_state),
      .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
  );

  pc9821_gdc2 u_gdc2 (
      .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .pixel_ce(pixel_ce),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(gdc2_io_dout),
      .frame_end(crtc_o_frame_end), .cfg_snap(crtc_o_cfg_snap),
      .cfg_pending(crtc_o_cfg_pending),
      .vline(crtc_o_vline), .vtotal(crtc_o_vtotal), .m_vbp(crtc_o_vbp),
      .display_page(crtc_o_display_page),
      .stat_blank(crtc_o_stat_blank), .stat_vsync(crtc_o_stat_vsync),
      .gfx_line_addr(gfx_line_addr), .gfx_walk_page(gfx_walk_page),
      .gfx_disp(gfx_disp), .gfx_win_off(gfx_win_off),
      .gfx_grph_on(gfx_grph_on), .pegc_256(gfx_pegc_256),
      .gdc_5m(gdc_ff2_state[7] && gdc_ff2_state[8])   // as pc9821_system wires it
  );

  pc9821_cg u_cg (
      .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .pixel_ce(pixel_ce),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din),
      .io_dout(cg_io_dout),
      .cg_win_byte_sel(cg_win_byte_sel), .cg_win_rd(cg_win_rd),
      .cg_win_dout(cg_win_dout), .cg_win_din(cg_win_din), .cg_win_we(cg_win_we),
      .cg_win_byte_hold(cg_win_byte_hold),
      .font_req_addr(font_req_addr), .font_req(font_req),
      .font_word_valid(font_word_valid), .font_word_data(font_word_data),
      .cg_rd_hold(cg_rd_hold),
      .font_ld_addr(font_ld_addr), .font_ld_data(font_ld_data),
      .font_ld_we(font_ld_we),
      .cg_record_restore(cg_record_restore),
      .bios_set(bios_set),
      .cfg_ram_mib(cfg_ram_mib), .cfg_seed_en(cfg_seed_en),
      .cfg_seed_reload(cfg_seed_reload),
      .ank_rd_addr(crtc_ank_rd_addr), .ank_word(cg_ank_word),
      .jc_rd_bank(crtc_jc_rd_bank), .jc_rd_cell(crtc_jc_rd_cell),
      .jc_rd_word(crtc_jc_rd_word), .jc_rd_q(cg_jc_rd_q),
      .cg_ram_vid_addr(crtc_cg_ram_vid_addr), .cg_ram_vid_q(cg_cg_ram_vid_q),
      .tram_vid_q(crtc_tram_vid_q),
      .v_pitch(crtc_o_v_pitch), .v_col40(crtc_o_v_col40),
      .v_sad(crtc_o_v_sad),
      .wk_go(crtc_o_wk_go), .wk_k(crtc_o_wk_k), .wk_bank_in(crtc_o_wk_bank),
      .hdot(crtc_o_hdot),
      .wk_tr_read(cg_wk_tr_read), .wk_tr_addr(cg_wk_tr_addr),
      .dbg_wk_skips(dbg_wk_skips)
  );

  assign io_dout =
      ((io_addr == 8'hA0) || (io_addr == 8'hA2)) ? gdc2_io_dout :
      ((io_addr == 8'hA1) || (io_addr == 8'hA3) ||
       (io_addr == 8'hA5) || (io_addr == 8'hA9)) ? cg_io_dout :
      crtc_io_dout;

endmodule

`default_nettype wire

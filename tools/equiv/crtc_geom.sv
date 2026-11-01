// SPAN: src/pc9821/video/pc9821_crtc.sv | localparam [9:0] CLK_MINX | // The roots (registered on the frame-boundary edge
// PLANT: hfp_f   = {1'b0, b3[7:2]} + 7'd1; => hfp_f   = {1'b0, b3[7:2]} + {1'b0, b4[5:0]};
// PLANT: hs_on_n = g[G_HS_ON +: 10] => hs_on_n = g[G_HS_OFF +: 10]
// PLANT: vactive + vfp + vsync_w, vactive + vfp, => vactive + vfp + vsync_w, vactive + vsync_w,
// PLANT: lfmax     = y - 10'd1; => lfmax     = y - 10'd2;
// PLANT: hactive + hfp, htotal - 10'd1}; => hactive + hfp, htotal - 10'd2};
// PLANT: y_raw = {1'b0, crtc_lf(b6, b7)} + {4'b0000, vfbs}; => y_raw = {1'b0, crtc_lf(b6, b7)} + {4'b0000, vfbs0};
// Combinational proof for pc9821_crtc's registered geometry (V1-a): for EVERY eight-byte SYNC
// block and every (hdot, vline), each compare the raster makes against crtc_d(crtc_x, crtc_y,
// crtc_lf) of the block
// - the REAL function, pasted from the source by the SPAN line above - equals the compare the
// pre-change module made against its combinational field map of the frame-boundary copy of the
// same block (the old text below, from pc9821_crtc.sv at ad9ed84c, v_sync[k] -> bk and the old
// seam's s_lf_r/s_y_r -> their arriving-block decode, which they equalled at every cycle).
module m(input [7:0] b0, b1, b2, b3, b4, b5, b6, b7, input [9:0] hdot, vline, input c31,
         output mismatch);
  // SPAN-HERE
  // ---- the pre-change wiring (ad9ed84c), verbatim but for the renames above ----
  wire [15:0] s_tmp    = {b3, b2};
  wire [15:0] s_n_tmp2 = {b7, b6};
  wire [9:0]  s_cr    = {2'b00, b1} + 10'd2;
  wire [4:0]  s_hs_f  = s_tmp[4:0];
  wire [6:0]  s_hfp_f = {1'b0, s_tmp[15:10]} + {1'b0, b4[5:0]};
  wire [4:0]  s_vs_f  = s_tmp[9:5];
  wire [5:0]  s_vfp_f = b5[5:0];
  wire [4:0]  s_n_vs_f  = s_tmp[9:5];
  wire [5:0]  s_n_vfp_f = b5[5:0];
  wire [5:0]  s_n_vbp_f = s_n_tmp2[15:10];
  wire [9:0]  s_n_lfm1 = s_n_tmp2[9:0] - 10'd1;
  wire [10:0] s_n_lf   = {1'b0, s_n_lfm1} + 11'd1;
  wire [8:0]  s_hfbs  = {4'b0000, s_hs_f} + {2'b00, s_hfp_f} + HBP_CH;
  wire [9:0]  s_x_raw = s_cr + {1'b0, s_hfbs};
  // (the 31 kHz range: the pre-change clamp with the monitor range's two x limits selected)
  wire [9:0]  s_minx  = c31 ? CLK31_MINX : CLK_MINX;
  wire [9:0]  s_maxx  = c31 ? CLK31_MAXX : CLK_MAXX;
  wire [7:0]  s_x     = (s_x_raw < s_minx) ? s_minx[7:0]
                      : (s_x_raw > s_maxx) ? s_maxx[7:0] : s_x_raw[7:0];
  wire [7:0]  s_n_vfbs0 = {3'b000, s_n_vs_f} + {2'b00, s_n_vfp_f} + {2'b00, s_n_vbp_f};
  wire [7:0]  s_n_vfbs  = (s_n_vfbs0 == 8'd0) ? 8'd1 : s_n_vfbs0;
  wire [11:0] s_n_y_raw = {1'b0, s_n_lf} + {4'b0000, s_n_vfbs};
  wire [9:0]  s_n_y     = (s_n_y_raw < {2'b00, CLK_MINY}) ? CLK_MINY
                        : (s_n_y_raw > {2'b00, CLK_MAXY}) ? CLK_MAXY : s_n_y_raw[9:0];
  wire [10:0] s_lf_r = s_n_lf;
  wire  [9:0] s_y_r  = s_n_y;
  wire [9:0] HTOTAL   = s_x * 10'd8;
  wire [9:0] VTOTAL   = s_y_r;
  wire [12:0] s_hact8  = {s_cr, 3'b000};
  wire [9:0]  s_hactmax= HTOTAL - 10'd8;
  wire [9:0]  HACTIVE  = (s_hact8 > {3'b000, s_hactmax}) ? s_hactmax : s_hact8[9:0];
  wire [9:0]  s_hblank = HTOTAL - HACTIVE;
  // The horizontal PORCHES follow the uPD7220 field map since 2026-10-15 (3a86167e: MAME
  // upd7220.cpp:1243-1246 `m_hs = (m_pr[3] & 0x1f) + 1`, `m_hfp = (m_pr[4] >> 2) + 1`): the front
  // porch is hfp2 + 1 characters and the sync hs + 1 (the line total above still sums NP2kai's
  // fields). Only these two operands of the pre-change text are re-specified; every compare stays.
  wire [6:0]  s_hfp_p  = {1'b0, s_tmp[15:10]} + 7'd1;
  wire [5:0]  s_hs_p   = {1'b0, s_hs_f} + 6'd1;
  wire [9:0]  s_hfp8   = {s_hfp_p, 3'b000};
  wire [9:0]  s_hs8    = {1'b0, s_hs_p, 3'b000};
  wire [9:0]  HFP      = (s_hfp8 <= (s_hblank - 10'd8)) ? s_hfp8 : (s_hblank - 10'd8);
  wire [9:0]  HSYNC_W  = (s_hs8 == 10'd0) ? HSYNC_MIN
                       : (s_hs8 <= (s_hblank - HFP)) ? s_hs8 : (s_hblank - HFP);
  wire [9:0]  s_lfmax  = VTOTAL - 10'd1;
  wire [9:0]  VACTIVE  = (s_lf_r > {1'b0, s_lfmax}) ? s_lfmax : s_lf_r[9:0];
  wire [9:0]  s_vblank = VTOTAL - VACTIVE;
  wire [9:0]  s_vfp10  = {4'b0000, s_vfp_f};
  wire [9:0] VFP      = (s_vfp10 > (s_vblank - 10'd1)) ? (s_vblank - 10'd1) : s_vfp10;
  wire [9:0]  s_vs10   = {5'b00000, s_vs_f};
  wire [9:0]  s_vs_room= s_vblank - VFP;
  wire [9:0]  VSYNC_W  = (s_vs10 == 10'd0) ? VSYNC_MIN
                       : (s_vs10 > s_vs_room) ? s_vs_room : s_vs10;
  wire o_in_hsync = (hdot >= HACTIVE + HFP) && (hdot < HACTIVE + HFP + HSYNC_W);
  wire o_in_vsync = (vline >= VACTIVE + VFP) && (vline < VACTIVE + VFP + VSYNC_W);
  wire o_h_active = (hdot < HACTIVE);
  wire o_v_active = (vline < VACTIVE);
  wire o_frame_end = (vline == VTOTAL - 1) && (hdot == HTOTAL - 1);
  wire [9:0] o_wk_slot = (VTOTAL - 10'd1) & 10'h3F0;
  wire o_wk_cfg_snap = (vline == o_wk_slot - 10'd1) && (hdot == HTOTAL - 1);
  wire o_line_end = (hdot == HTOTAL - 1);
  wire o_row0_clr = (vline == o_wk_slot) && (hdot == HTOTAL - 1);
  wire o_f_wrap = (vline == VACTIVE - 10'd1);
  wire o_feed_odd = vline[0] ^ ((vline + 10'd2 >= VTOTAL) && VTOTAL[0]);
  wire o_at_line_tick = (hdot == HTOTAL - 10'd1);
  wire [5:0] o_vbp = b7[7:2];

  // ---- the registered form: the same consumers against the REAL functions of the block ----
  wire [7:0]  n_x  = crtc_x(c31, b1, b2, b3, b4);
  wire [9:0]  n_vtotal = crtc_y(b2, b3, b5, b6, b7);
  wire [10:0] n_lf = crtc_lf(b6, b7);
  wire [9:0]  n_hact = crtc_hact(n_x, b1);
  wire [9:0]  n_vact = crtc_vact(n_vtotal, n_lf);
  wire [G_W-1:0] g = crtc_d(n_x, n_vtotal, n_hact, n_vact, b2, b3, b4, b5);
  wire [9:0] n_htotal = {n_x, 3'b000};
  wire [9:0] hs_on_n = g[G_HS_ON +: 10];
  wire n_in_hsync = (hdot >= hs_on_n) && (hdot < g[G_HS_OFF +: 10]);
  wire n_in_vsync = (vline >= g[G_VS_ON +: 10]) && (vline < g[G_VS_OFF +: 10]);
  wire n_h_active = (hdot < n_hact);
  wire n_v_active = (vline < n_vact);
  wire n_frame_end = (vline == g[G_VTOT_M1 +: 10]) && (hdot == g[G_HTOT_M1 +: 10]);
  wire n_wk_cfg_snap = (vline == g[G_WK_SNAP +: 10]) && (hdot == g[G_HTOT_M1 +: 10]);
  wire n_line_end = (hdot == g[G_HTOT_M1 +: 10]);
  wire n_row0_clr = (vline == g[G_WK_SLOT +: 10]) && (hdot == g[G_HTOT_M1 +: 10]);
  wire n_f_wrap = (vline == g[G_VACT_M1 +: 10]);
  wire n_feed_odd = vline[0] ^ ((vline + 10'd2 >= n_vtotal) && n_vtotal[0]);
  wire n_at_line_tick = (hdot == g[G_HTOT_M1 +: 10]);
  // the roots' own values equal the old frame-boundary decode (s_lf_r / s_y_r)
  wire roots_bad = (n_lf != s_n_lf) || (n_vtotal != s_n_y);

  assign mismatch =
      (o_in_hsync != n_in_hsync) || (o_in_vsync != n_in_vsync) ||
      (o_h_active != n_h_active) || (o_v_active != n_v_active) ||
      (o_frame_end != n_frame_end) || (o_wk_cfg_snap != n_wk_cfg_snap) ||
      (o_line_end != n_line_end) || (o_row0_clr != n_row0_clr) || (o_f_wrap != n_f_wrap) ||
      (o_feed_odd != n_feed_odd) || (o_at_line_tick != n_at_line_tick) ||
      (HTOTAL != n_htotal) || (VTOTAL != n_vtotal) || roots_bad ||            // o_htotal / o_vtotal
      (HACTIVE != n_hact) || (VACTIVE != n_vact) ||
      (VFP != g[G_VFP +: 10]) || (VSYNC_W != g[G_VSYNC_W +: 10]);   // the userdisk dump (o_vbp is v_sync[7][7:2] in both)
endmodule

// SPAN: src/pc9821/video/pc9821_crtc.sv | localparam [9:0] CLK_MINX | // The roots (registered on the frame-boundary edge
// PLANT: wire [9:0] dot = 10'd0; => wire [9:0] dot = 10'd16;
// Combinational proof for pc9821_crtc's one-clk lag of geom_d (V1-a): geom_d holds crtc_d() of
// the PREVIOUS roots for exactly one clk_sys after the frame-boundary edge, where hdot = vline
// = 0. For ANY two blocks (a = the geometry before the edge, b = after), every compare on a
// LAGGED operand whose result leaves the module at (hdot, vline) = (0, 0) - the HSYNC/VSYNC
// pulses, the frame and line ends, the walk-slot strobes (the active window reads the
// edge-registered HACTIVE/VACTIVE and does not lag)
// - is the same under crtc_d(a) as under crtc_d(b). (f_wrap_r's sample there is re-taken at the
// next dot and read only at the line's last cell; see pc9821_crtc.)
module m(input [7:0] a1, a2, a3, a4, a5, a6, a7, input [7:0] b1, b2, b3, b4, b5, b6, b7,
         input ca, cb,   // 0x09A8 bit 0 on each side of the edge (the 31 kHz range)
         output mismatch);
  // SPAN-HERE
  wire [9:0] dot = 10'd0;    // hdot = vline = 0 (the plant moves it to where the lag WOULD show)
  wire [7:0] xa = crtc_x(ca, a1, a2, a3, a4);
  wire [9:0] ya = crtc_y(a2, a3, a5, a6, a7);
  wire [G_W-1:0] ga = crtc_d(xa, ya, crtc_hact(xa, a1), crtc_vact(ya, crtc_lf(a6, a7)),
                             a2, a3, a4, a5);
  wire [7:0] xb = crtc_x(cb, b1, b2, b3, b4);
  wire [9:0] yb = crtc_y(b2, b3, b5, b6, b7);
  wire [G_W-1:0] gb = crtc_d(xb, yb, crtc_hact(xb, b1), crtc_vact(yb, crtc_lf(b6, b7)),
                             b2, b3, b4, b5);
  function automatic [5:0] obs(input [G_W-1:0] g, input [9:0] h, input [9:0] v);
    obs = {(h >= g[G_HS_ON +: 10]) && (h < g[G_HS_OFF +: 10]),         // in_hsync
           (v >= g[G_VS_ON +: 10]) && (v < g[G_VS_OFF +: 10]),         // in_vsync
           (v == g[G_VTOT_M1 +: 10]) && (h == g[G_HTOT_M1 +: 10]),     // frame_end
           (v == g[G_WK_SNAP +: 10]) && (h == g[G_HTOT_M1 +: 10]),     // wk_cfg_snap
           (v == g[G_WK_SLOT +: 10]) && (h == g[G_HTOT_M1 +: 10]),     // row-0 stale clear
           (h == g[G_HTOT_M1 +: 10])};                                 // line end / line tick
  endfunction
  assign mismatch = obs(ga, dot, dot) != obs(gb, dot, dot);
endmodule

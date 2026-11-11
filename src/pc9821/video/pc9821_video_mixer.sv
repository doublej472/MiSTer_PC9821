// PC-9821 video mixer: the text plane over the graphics plane, and the RGB the
// framework sees - the end of the pixel pipeline
//   gvram line buffer -> plane fold -> graphics palette -> RGB
//   pc9821_gdc_text (text_opaque/cell/colour) -> compositor mux -> {R,G,B}
//
// D4 is one two-way priority mux, and it is a rule SELECT rather than hard-wired because
// NP2kai's rule is a model and not a measurement; the arms are named at the
// mux. A palette write, analogue or digital, reaches the next dot (pc9821_gfx_palette: a
// raster split shows); the mode arrives as pc9821_crtc's frame snapshot. The
// raster is fixed at 848x440 / 640x400 for every GDC clock.
//
// The palette's analogue lookup is an ASYNCHRONOUS read of a flop table, so it stays
// combinational and NOTHING in this datapath moves: the fold's column and dot are the
// current dot's, and the compositor needs no delay. The 16-colour table's CPU write port
// runs on the same clk_sys.

`default_nettype none

module pc9821_video_mixer (
    // The palette's write clock and the PEGC arm's delay. clk_sys and clk_vid are the same
    // net at the top level.
    input  wire        clk,

    input  wire [9:0]  dot_x,        // hdot: 0..847 within the line
    input  wire        h_active,     // dot_x < 640
    input  wire        v_active,     // line < 400

    // Text plane. No "no text here is black" wire: a colour and two flags, so a
    // transparent dot shows graphics instead of painting black over it.
    input  wire        text_opaque,  // a lit text dot under the NP2kai p_2 rule
    input  wire        text_cell,    // the cell is visible (attribute bit 0)
    input  wire [11:0] text_colour,  // {R,G,B} nibbles, the fixed 8-colour table

    // Graphics plane source: the gvram line-buffer read port.
    input  wire [31:0] line_data,    // one four-plane column word per 8 dots, MSB first
    input  wire        line_ready,   // a complete line is in the displayed buffer
    input  wire        line_sel,     // which buffer pc9821_gvram considers displayed
    output wire [6:0]  line_rd_addr, // column 0..79 being read
    output wire        line_rd_sel,

    // Graphics palette: the mode's frame-coherent snapshot and the live digital bytes from
    // pc9821_gdc_text, and the analogue table's CPU write port, which that module owns
    // (0xA8 selects the entry there; 0xAA/0xAC/0xAE arrive here as channel 0/1/2).
    input  wire        pal_mode16,   // 1 = 16-colour analogue, 0 = 8-colour digital
    input  wire [31:0] pal_dig,      // {0xA8, 0xAA, 0xAC, 0xAE}
    input  wire        pal_wr_en,
    input  wire [3:0]  pal_wr_idx,
    input  wire [1:0]  pal_wr_chan,  // 0 = G, 1 = R, 2 = B
    input  wire [3:0]  pal_wr_data,

    // PEGC 256-colour: the fold is bypassed; packed_idx is already a
    // palette index for the 256-entry table. `pegc_256` is the 0x6A dat 0x21
    // select (pc9821_crtc's mode2_256col): it picks the 256-colour arm, takes
    // the 200-line interleave gate off the graphics arm (the references do not
    // interleave packed display: qemu pc98-vga.c:4422-4438 is a straight 640x400
    // copy, MAME pc9821.cpp:100-123 walks rows directly) and delays the TEXT arm
    // by the one clk_sys the registered 256-colour palette read takes, so the
    // composited picture moves uniformly while the 16-colour path moves not at
    // all.
    input  wire        pegc_256,
    input  wire        fold_bypass,
    input  wire [7:0]  packed_idx,
    // The 256-colour palette's CPU write port (pc9821_crtc's widened 0xA8/0xAA/
    // 0xAC/0xAE decode: the unmasked index and the full byte, NP2kai io/gdc.c).
    input  wire        pal256_wr_en,
    input  wire [7:0]  pal256_wr_idx,
    input  wire [1:0]  pal256_wr_chan,
    input  wire [7:0]  pal256_wr_data,

    // Compositor rule and graphics display enable.
    input  wire [1:0]  comp_rule,
    input  wire        grph_disp,    // GDC2 START/STOP; R7 supplies it
    // The 200-line interleave's odd display line (MODE FF1 bit 4 and the line odd):
    // text over black, graphics hidden whatever the rule - NP2kai's p_2i paints the odd
    // line of each pair as `(q[x] >> 4) + NP2PAL_TEXT` with the graphics plane absent
    // (vram/sdraw.mcr:199-243; the interleave row is selected on `gdc.mode1 & 0x10`,
    // vram/scrndraw.c:227). pc9821_crtc's gfx_odd_line drives it.
    input  wire        gfx_odd_line,

    output wire [7:0]  r_out,
    output wire [7:0]  g_out,
    output wire [7:0]  b_out
);

  // The line buffer's data port is REGISTERED - valid one clk_sys after the address - and a dot
  // is 50/21.0526 = 2.375 clk_sys, so presenting column c for the WHOLE of column c leaves the
  // read settled before the dot enable samples ANY of its eight dots, the first included. Parking
  // at 0 outside the active dots is also what the line boundary needs: HBLANK (208 dots) is far
  // longer than the read latency, so the ping-pong swap has settled before the next line's first
  // dot.
  wire [6:0] col = dot_x[9:3];
  assign line_rd_addr = h_active ? col : 7'd0;
  assign line_rd_sel  = line_sel;

  wire [3:0] fold_idx;
  pc9821_plane_fold u_fold (
      .column(line_data),
      .dot(dot_x[2:0]),
      .idx(fold_idx)
  );

  wire [7:0] pal_idx = fold_bypass ? packed_idx : {4'b0, fold_idx};

  wire [11:0] grph_colour;
  wire [23:0] grph_colour256;
  pc9821_gfx_palette u_palette (
      .clk(clk),
      .idx(pal_idx),
      .mode16(pal_mode16),
      .dig(pal_dig),
      .we(pal_wr_en), .widx(pal_wr_idx), .wchan(pal_wr_chan), .wdata(pal_wr_data),
      .colour(grph_colour),
      .p256_we(pal256_wr_en), .p256_widx(pal256_wr_idx),
      .p256_wchan(pal256_wr_chan), .p256_wdata(pal256_wr_data),
      .idx256(packed_idx), .colour256(grph_colour256)
  );

  // ---- the PEGC arm: the one-dot text delay and the mode muxes ----
  // The 256-colour palette read is REGISTERED (its table cannot be read
  // asynchronously - pc9821_gfx_palette's header), so this arm's graphics dot is
  // one clk_sys behind the 16-colour arm's combinational one. The text arm takes
  // the SAME delay in 256-colour mode ONLY (three registers + a mode mux), so
  // text and graphics move together and the capture-pinned 16-colour path does
  // not move at all.
  reg        text_opaque_d, text_cell_d;
  reg [11:0] text_colour_d;
  always @(posedge clk) begin
    text_opaque_d <= text_opaque;
    text_cell_d   <= text_cell;
    text_colour_d <= text_colour;
  end
  wire        text_opaque_m = pegc_256 ? text_opaque_d : text_opaque;
  wire        text_cell_m   = pegc_256 ? text_cell_d   : text_cell;
  wire [11:0] text_colour_m = pegc_256 ? text_colour_d : text_colour;

  // ---- the compositor: one two-way priority mux ----
  // 00 = NP2kai p_2 (default), a glyph-covered dot takes the attribute colour;
  // 01 = cell-opaque; 10 = text-only, graphics never composited. On the 200-line
  // interleave's odd line (gfx_odd_line) the graphics arm is off in every rule and a
  // transparent text dot shows black (NP2kai p_2i over the NP2PAL_TEXT block, whose
  // entry 0 is degpal1[0] = black - vram/palettes.c:339-352) - but ONLY in
  // 16-colour modes; the packed display is not interleaved (the references above).
  wire       text_wins  = comp_rule[0] ? text_cell_m : text_opaque_m;
  wire       grph_shown = grph_disp && line_ready && !comp_rule[1] &&
                          !(gfx_odd_line && !pegc_256);
  // 4-bit to 8-bit by nibble replication ({n,n}), not a linear scale: NP2kai
  // `pal_makeskiptable`, and the same rule the text path used on its way out. The
  // replication happens BEFORE the compositor (24-bit arms), which is
  // bit-identical to an output-stage replication for the 16-colour path and
  // lets the 256-colour arm carry FULL bytes (NP2kai's pal_make9821 renders them
  // verbatim; the DAC width is capture-pending).
  wire [23:0] grph_rgb = pegc_256 ? grph_colour256 :
                         {grph_colour[11:8], grph_colour[11:8],
                          grph_colour[7:4],  grph_colour[7:4],
                          grph_colour[3:0],  grph_colour[3:0]};
  wire [23:0] text_rgb = {text_colour_m[11:8], text_colour_m[11:8],
                          text_colour_m[7:4],  text_colour_m[7:4],
                          text_colour_m[3:0],  text_colour_m[3:0]};
  wire [23:0] grph_px   = grph_shown ? grph_rgb : 24'h000000;
  wire [23:0] px        = text_wins ? text_rgb : grph_px;

  assign r_out = (h_active && v_active) ? px[23:16] : 8'h00;
  assign g_out = (h_active && v_active) ? px[15:8]  : 8'h00;
  assign b_out = (h_active && v_active) ? px[7:0]   : 8'h00;

endmodule

`default_nettype wire

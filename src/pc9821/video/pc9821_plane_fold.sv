// PC-9821 GVRAM plane fold: four plane bits of one dot -> one 4-bit palette index.
//
// GVRAM is four planes - 0 = blue (0xA8000), 1 = red (0xB0000), 2 = green
// (0xB8000), 3 = intensity (0xE0000) - and the index is {E,G,R,B} in bits 3..0.
// The input is one column word off the scanout's line buffer in that lane order,
// one byte per plane, MSB first, which is the convention the text path uses for
// its glyph row, so the two serialisers agree dot for dot.
//
// The fold is kept whole and alone - plane order and dot select, no palette, no
// compositor - so PEGC's 256-colour packed mode can bypass it at the palette's
// address input in pc9821_video_mixer rather than needing a second datapath.
// The plane windows are NP2kai's (i386c/cpumem.h:26-29 `#define VRAM_B 0x0a8000` ...
// `VRAM_E 0x0e0000`).

`default_nettype none

module pc9821_plane_fold (
    // One four-plane column word: {E,G,R,B} in bytes 3..0, MSB first.
    input  wire [31:0] column,
    // Which dot of the column, 0..7. 0 is the byte's bit 7.
    input  wire [2:0]  dot,
    // The palette index: {E,G,R,B} in bits 3..0.
    output wire [3:0]  idx
);

  assign idx[3] = column[8*3 + 7 - dot];   // plane 3, intensity
  assign idx[2] = column[8*2 + 7 - dot];   // plane 2, green
  assign idx[1] = column[8*1 + 7 - dot];   // plane 1, red
  assign idx[0] = column[8*0 + 7 - dot];   // plane 0, blue

endmodule

`default_nettype wire

// PC-9821 graphics palette: palette index and colour mode -> the RGB the picture is
// painted with.
//
// The ANALOGUE table (the CPU's 0xA8 index / 0xAA green / 0xAC red / 0xAE blue registers,
// 16 entries x 12 bits) is ONE table: the CPU writes it and the scanout reads it, so a write
// reaches the next dot painted with that entry - the raster palette split games make (a VSYNC
// handler writes one table, a PIT one-shot another at a chosen line). The references draw such
// a write from the next line (MAME src/mame/nec/pc9801.cpp pc9801rs_a0_w calls
// `m_screen->update_partial(m_screen->vpos())`, "lemmings raster effects") or the next line
// pair (NP2kai vram/scrndraw.c rasterdraw, from the frame-clock events io/gdc.c
// gdc_setanalogpal logs); both are a renderer's quantisation of a register file feeding the
// DAC. The real Xe10's DAC takes a write at once, mid-line: XE10T /RASTER's TOGGLE phase
// (docs/probes/XE10T-XE10-RASTER.TXT:27 `P RASTER TOGGLE frames=283`) filmed dashes about one
// `out` long (~7.8 dots), staggered from line to line, inside the toggled band.
// tb_pc9821_raster_palette asserts the lines both references agree on. (An earlier form kept a
// live table and copied it into this one at the frame boundary, which showed a whole frame in
// the table written last in the vertical blank.)
//
// The read is ASYNCHRONOUS, so no dot of the pixel path moves, and the table is 192 flops: an
// asynchronous read is refused by every block type with a defined read-during-write
// (`Info (276007) ... uninferred due to asynchronous read logic` with no attribute, `276009
// ... unsupported read-during-write behavior` with `ramstyle = "MLAB"`); `"MLAB, no_rw_check"`
// infers, at the price of an undefined dot in a write's own cycle (trade T50,
// docs/trade-candidates.md). A CPU write is a whole nibble of one entry; the dot that reads
// that entry in the write's own cycle sees the old value and the next dot the new one.
//
// The digital bytes stay in pc9821_crtc and arrive here LIVE: the machine's 8-colour palette
// also takes each write at once (the same /RASTER film, DTOGGLE phase,
// docs/probes/XE10T-XE10-RASTER.TXT:28 `P RASTER DTOGGLE frames=283`), where both references
// apply them to a whole frame (NP2kai draws a raster split in 16-colour analogue mode only,
// `(gdc.analog & 3) != 1` takes the plain draw in vram/scrndraw.c, and MAME's digital write in
// pc9801_v.cpp sets the pens with no partial update). The mode latch is still pc9821_crtc's
// frame-coherent snapshot. Owns the READ only; separate from pc9821_plane_fold so PEGC's packed mode can
// bypass the fold. Output is {R,G,B} nibbles. Derivation: corrections

`default_nettype none

module pc9821_gfx_palette (
    // clk_sys and clk_vid are the same net at the top level (pc9821_system), so one clock
    // port serves the CPU write ports and the registered 256-colour read.
    input  wire        clk,
    // The index: the plane fold {E,G,R,B}, or {G,R,B} in digital mode. Eight bits to
    // match the packed PEGC path in pc9821_video_mixer; only the low nibble resolves
    // here. The analogue read is asynchronous, so it is THIS dot's index.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [7:0]  idx,
    /* verilator lint_on UNUSEDSIGNAL */
    // 1 = 16-colour analogue, 0 = 8-colour digital (mode latch 2 bit 0), snapshot.
    input  wire        mode16,
    // The four digital bytes as written, {0xA8, 0xAA, 0xAC, 0xAE}, live (a write shows at the next dot).
    input  wire [31:0] dig,
    // The analogue table's CPU write port: 0xA8 selected the entry (widx), 0xAA/0xAC/0xAE
    // write G/R/B into it, so one write carries one channel. It lands in the displayed
    // table at once (see the header). widx is
    // palnum & 15 (NP2kai gdc_setanalogpal(gdc.palnum & 15), io/gdc.c:862): the 0xA8
    // register is a FULL 8-bit palnum; the read mirror in pc9821_crtc
    // also takes the MASKED palnum & 15 (PEGC's 256-colour palette is out of scope, so
    // the mirror is 16 entries like this table).
    input  wire        we,
    input  wire [3:0]  widx,
    input  wire [1:0]  wchan,       // 0 = G (0xAA), 1 = R (0xAC), 2 = B (0xAE)
    input  wire [3:0]  wdata,
    // {R,G,B} nibbles for the selected entry.
    output wire [11:0] colour,

    // ---- the PEGC 256-colour table ----
    // A SECOND store, not a widening of disp: the references keep the 256-colour
    // palette beside the 16-colour one (MAME m_pegc.r/g/b[256] beside m_analog16;
    // NP2kai anareg[16*3 + palnum*4 + c] beside anareg[palnum*3+c]). Three 256x8
    // M10K byte lanes with a REGISTERED dot-path read - the async form is not
    // deployable (the 276007 refusal, measured again at 2,264 ALMs standalone)
    // - and FULL bytes per channel, because NP2kai
    // renders them verbatim (`pal_make9821`: `p[i].p.g = pal[i*4+0]`, vram/palettes.c).
    // The registered read delays this arm by the one clk_sys the text arm takes
    // beside it (pc9821_video_mixer's mode mux), so the picture moves uniformly
    // and the 16-colour path does not move at all.
    input  wire        p256_we,
    input  wire [7:0]  p256_widx,     // the UNMASKED 0xA8 index
    input  wire [1:0]  p256_wchan,    // 0 = G, 1 = R, 2 = B
    input  wire [7:0]  p256_wdata,    // the FULL byte (NP2kai stores it verbatim)
    input  wire [7:0]  idx256,        // the packed pixel's palette index
    output reg  [23:0] colour256      // registered: {R,G,B} full bytes
);

  // THE PEGC 256-COLOUR STORE: the lane form that infers (whole-byte writes into
  // byte lanes; a 256x24 word written byte-wise refuses every block type and the
  // register form measures 4,258 ALMs).
  (* ramstyle = "M10K" *) reg [7:0] pal256_g [0:255];
  (* ramstyle = "M10K" *) reg [7:0] pal256_r [0:255];
  (* ramstyle = "M10K" *) reg [7:0] pal256_b [0:255];

  integer p256_i;
  initial begin
    // Zero-seeded (NP2kai's gdc_reset zeroes the store); the read register is
    // left to its own clocked assignment's zero power-up (a non-default value on
    // the register that captures a memory read is what refuses the inference).
    for (p256_i = 0; p256_i < 256; p256_i = p256_i + 1) begin
      pal256_g[p256_i] = 8'h00;
      pal256_r[p256_i] = 8'h00;
      pal256_b[p256_i] = 8'h00;
    end
    colour256 = 24'h000000;
  end

  // The write port: one whole byte into the lane its channel names.
  always @(posedge clk) begin
    if (p256_we) begin
      if (p256_wchan == 2'd0)      pal256_g[p256_widx] <= p256_wdata;
      else if (p256_wchan == 2'd1) pal256_r[p256_widx] <= p256_wdata;
      else                         pal256_b[p256_widx] <= p256_wdata;
    end
  end

  // The dot-path read, REGISTERED and in its own always block (a read and a write
  // of the same RAM in one block reads as an asynchronous port and the memory
  // never infers).
  always @(posedge clk) begin
    colour256 <= {pal256_r[idx256], pal256_g[idx256], pal256_b[idx256]};
  end

  // The analogue table: 16 x 12, written by the CPU and read asynchronously by the scanout
  // (see the header for why it stays flops).
  reg [11:0] disp [0:15];

  // The NEC 16-colour power-on table (itf.rom 0x042F; the source packs {G,R,B} and this
  // table is {R,G,B}, so entry 2 is red and entry 4 green), so the first frame already shows
  // it.
  //
  // A case function, not an unpacked localparam array: Quartus 17.0.2 rejects an aggregate
  // parameter ("parameter with complex/aggregate value must have a type").
  function [11:0] pal_power_on(input [3:0] e);
    case (e)
      4'd0:  pal_power_on = 12'h000;
      4'd1:  pal_power_on = 12'h007;
      4'd2:  pal_power_on = 12'h700;
      4'd3:  pal_power_on = 12'h707;
      4'd4:  pal_power_on = 12'h070;
      4'd5:  pal_power_on = 12'h077;
      4'd6:  pal_power_on = 12'h770;
      4'd7:  pal_power_on = 12'h777;
      4'd8:  pal_power_on = 12'h444;
      4'd9:  pal_power_on = 12'h00F;
      4'd10: pal_power_on = 12'hF00;
      4'd11: pal_power_on = 12'hF0F;
      4'd12: pal_power_on = 12'h0F0;
      4'd13: pal_power_on = 12'h0FF;
      4'd14: pal_power_on = 12'hFF0;
      default: pal_power_on = 12'hFFF;
    endcase
  endfunction

  integer i;
  initial begin
    for (i = 0; i < 16; i = i + 1) disp[i] = pal_power_on(i[3:0]);
  end

  // The CPU write port: one WHOLE nibble of one entry, the channel's. wchan is 0/1/2 by
  // construction (pc9821_crtc's pal_wr_chan: 22->G, 23->R, else B), and the `else` writes
  // blue for wchan == 3. One writer, one write per cycle: the strobe `we` is consumed here
  // and nowhere else.
  always @(posedge clk) begin
    if (we) begin
      if (wchan == 2'd0)      disp[widx][7:4]  <= wdata;   // 0xAA green
      else if (wchan == 2'd1) disp[widx][11:8] <= wdata;   // 0xAC red
      else                    disp[widx][3:0]  <= wdata;   // 0xAE blue
    end
  end

  // ---- the digital (8-colour) table ----
  // Four bytes of per-bit colour: R = bit 5, G = bit 6, B = bit 4, written as
  // `(byte & mask) ? F : 0` with a SINGLE-BIT mask (a multi-bit condition is true when
  // NON-ZERO, not when bit 0 is set - probed, not assumed). entry 0 = 0xAE, 1 = 0xAA,
  // 2 = 0xAC, 3 = 0xA8; entries 0..3 take each register's high nibble and 4..7 its low,
  // so {G,R,B} indexes them directly. The 3-bit select ignores idx[3]: in 8-colour mode
  // the intensity bit is not a colour.
  wire [7:0] d0 = dig[7:0];    // 0xAE
  wire [7:0] d1 = dig[23:16];  // 0xAA
  wire [7:0] d2 = dig[15:8];   // 0xAC
  wire [7:0] d3 = dig[31:24];  // 0xA8
  /* verilator lint_off WIDTHTRUNC */
  wire [11:0] digpal [0:7];
  assign digpal[0] = { (d0 & 8'h20) ? 4'hF : 4'h0,
                       (d0 & 8'h40) ? 4'hF : 4'h0,
                       (d0 & 8'h10) ? 4'hF : 4'h0 };
  assign digpal[1] = { (d1 & 8'h20) ? 4'hF : 4'h0,
                       (d1 & 8'h40) ? 4'hF : 4'h0,
                       (d1 & 8'h10) ? 4'hF : 4'h0 };
  assign digpal[2] = { (d2 & 8'h20) ? 4'hF : 4'h0,
                       (d2 & 8'h40) ? 4'hF : 4'h0,
                       (d2 & 8'h10) ? 4'hF : 4'h0 };
  assign digpal[3] = { (d3 & 8'h20) ? 4'hF : 4'h0,
                       (d3 & 8'h40) ? 4'hF : 4'h0,
                       (d3 & 8'h10) ? 4'hF : 4'h0 };
  assign digpal[4] = { (d0 & 8'h02) ? 4'hF : 4'h0,
                       (d0 & 8'h04) ? 4'hF : 4'h0,
                       (d0 & 8'h01) ? 4'hF : 4'h0 };
  assign digpal[5] = { (d1 & 8'h02) ? 4'hF : 4'h0,
                       (d1 & 8'h04) ? 4'hF : 4'h0,
                       (d1 & 8'h01) ? 4'hF : 4'h0 };
  assign digpal[6] = { (d2 & 8'h02) ? 4'hF : 4'h0,
                       (d2 & 8'h04) ? 4'hF : 4'h0,
                       (d2 & 8'h01) ? 4'hF : 4'h0 };
  assign digpal[7] = { (d3 & 8'h02) ? 4'hF : 4'h0,
                       (d3 & 8'h04) ? 4'hF : 4'h0,
                       (d3 & 8'h01) ? 4'hF : 4'h0 };
  /* verilator lint_on WIDTHTRUNC */

  // The lookup is COMBINATIONAL: the analogue table is flops read asynchronously and the
  // digital decode is logic. No dot of the pixel path moves (see the header).
  assign colour = mode16 ? disp[idx[3:0]] : digpal[idx[2:0]];

endmodule

`default_nettype wire

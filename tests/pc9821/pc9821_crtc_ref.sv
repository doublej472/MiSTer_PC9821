// TEST REFERENCE: pc9821_crtc as of ad9ed84c (before the V1-a registered geometry), renamed. Never edited; the lockstep bench tb_pc9821_crtc_geom_equiv proves the shipped module against it.
// PC-9821 CRTC: the 24 kHz text raster, the text-cell fetch/render and the pixel outputs.
// It owns the raster counters and their measured geometry, the
// text RAM and the fetch pipeline, the render registers and pixel generator, the cursor and
// blink counters, the CPU-side video register decode and the configuration snapshot handshake.
//
// One clock. clk_sys gated by pixel_ce, which IS the dot enable: there is no second video
// clock. The graphics display-address decode is pc9821_gdc2's; the glyph path is
// pc9821_cg's.
//
// Fetch pipeline per cell (CELLW = 8 dots in 80-col, 16 in 40-col):
//   CELLW-5: TRAM read code lo (NEXT cell)   CELLW-4: latch, read code hi
//   CELLW-3: latch hi, read attribute        CELLW-2: latch attr, read font
//   CELLW-1: latch font row + render regs (cell_end)
//   dots 0..CELLW-1 of the next cell: combinational render; cell 0 of line 0's first
//   frame is blank.

`default_nettype none

module pc9821_crtc_ref (
    input wire clk_sys,
    input wire rst_n_sys,
    input wire pixel_ce,       // the dot enable (one clk_sys per pixel shown)

    // I/O port interface (from pc98_iobus; addr = port address [7:0])
    input  wire       io_wr,
    // The one-cycle read strobe. The parameter read-back queue at 0x62 pops on
    // it (NP2kai gdc_i62 decrements snd and advances ptr per read, io/gdc.c:684),
    // so exactly one byte leaves per CPU read - the same pattern pc9821_cg's
    // io_rd already uses.
    input  wire       io_rd,
    input  wire [7:0] io_addr,
    input  wire [7:0] io_din,
    output wire [7:0] io_dout,
    // The 0x9A0 extended-video index/query state (NP2kai gdc_i9a0, io/gdc.c:969-
    // 1030): the bits its query table reads, packed for pc9821_iobus, which owns
    // the port and the ff2 index latch. Layout:
    //   [0] mode1[1]  [1] mode1[4]  [2] mode1[7]     [3] mode2[0] (16-colour)
    //   [4] mode2[2] (EGC ext)     [5] mode2[3] (reg write enable)
    //   [6] display PLAZMA (the FF2 dat 0x40/0x41 bit this core keeps as
    //       mode2_textshift)       [7] gdc.clock[0]  [8] gdc.clock[1]
    //   [9] analog 256 (GDCANALOG_256)             [10] analog 256E
    output wire [10:0] gdc_ff2_state,

    // TRAM CPU port (memory bridge; 0xA0000-0xA3FFF)
    input  wire [13:0] tram_cpu_addr,
    input  wire [ 7:0] tram_cpu_din,
    input  wire        tram_cpu_we,
    output wire [ 7:0] tram_cpu_dout,

    // ---- the ONE HARDWARE-switch field the OSD still owns (the `P1` DIP Switch page) ---
    // THIS CARRIES A LIST POSITION, NOT A VALUE, and the decode below is deliberately at the
    // point of use: an undriven input must mean ENTRY 0 - the measured machine - exactly as
    // it does for the machine-ID and GDC-clock straps (bios_set 0 = the Xe10 strap,
    // gdc_clock_5m 0 = 2.5 MHz). pc9821_osd's list contracts are for the positions the top
    // level owns; this one travels one port further, so its contract lives with the store.
    //
    // THE CELL. cfg_fdd_mode is the high nibble of the memory-switch cell 0xA3FF2. The cell
    // is the board's physical switch, not a preference: no code in the whole ROM set ever
    // writes the FIELD (only the dormant PCI bank's `and byte [es:0x3ff2],0x0F` touches the
    // LOW nibble, outside the field), the authentic firmware only reads it, so this port is
    // what makes the snapshot a choice. THE FIELD APPLIES ONLY AT MACHINE RESET: it is
    // latched on the same `rst_n_sys` strobe the GDC-clock and machine-ID straps use, and a
    // mid-run change is re-read at the next reset only (tb_pc9821_msw_switch). At entry 0 the
    // cell is seeded with the byte the INIT_BYTES literal below already carries (0x01), so a
    // card with no config file is bit-identical.
    //
    // THE BASE MEMORY (0xA3FEA bits 2:0) IS NO LONGER A PORT: the real Xe10 has no
    // SETUP/DIP option that changes the conventional memory size (its SETUP menu carries no
    // such item, and NP2kai
    // takes the value from the memory-switch cell, not from a guest setting), so it is
    // HARDCODED to the measured 640 KB code (MSW_BASEM_CODE) and the 0xA3FEA seed is always
    // the measured 0x0C.
    input  wire [2:0] cfg_fdd_mode,

    // ---- The row-cache walker's borrowed TRAM port (pc9821_cg drives it) ----
    input  wire        wk_tr_read,
    input  wire [13:0] wk_tr_addr,
    output wire [ 7:0] o_tram_vid_q,

    // ---- The scanout's view into pc9821_cg ----
    // The ANK scanout word address, and the word back.
    output wire [10:0] ank_rd_addr,
    input  wire [15:0] ank_word,
    // The JIS row cache's read coordinates (packed inside pc9821_cg).
    output wire [1:0]  jc_rd_bank,
    output wire [6:0]  jc_rd_cell,
    output wire [1:0]  jc_rd_word,
    input  wire [31:0] jc_rd_q,
    // The gaiji store's scanout read address, and the byte back.
    output wire [12:0] cg_ram_vid_addr,
    input  wire [7:0]  cg_ram_vid_q,

    // ---- Raster and configuration the row-cache walker needs ----
    output wire [7:0]  o_v_pitch,
    output wire        o_v_col40,
    output wire [15:0] o_v_sad,
    output wire        o_v_row0_stale,
    output wire [9:0]  o_vline,
    output wire [9:0]  o_hdot,
    // The guest-programmed geometry itself: HTOTAL in dots (pc9821_system's GVRAM line tick
    // is the last dot of the line) and VTOTAL in lines (pc9821_gdc2 wraps its display-line
    // decode at the frame end). Both are the SYNC block's, see the geometry section below.
    output wire [9:0]  o_htotal,
    output wire [9:0]  o_vtotal,
    // The displayed SYNC block's VBP, byte 7 >> 2: pc9821_gdc2 places the slave's graphics
    // window relative to it - NP2kai dispsync_renewalvertical's text_vbp.
    output wire [5:0]  o_vbp,

    // ---- Raster handshake to pc9821_gdc2 ----
    output wire o_frame_end,     // the last dot of the frame
    output wire o_cfg_snap,      // frame_end && the configuration-dirty bit
    output wire o_cfg_pending,   // that dirty bit alone: a snapshot WILL fire at this frame's end
    output wire o_display_page,  // port 0xA4's register
    output wire o_stat_blank,    // ~de_ff[1]: the 0xA0/0xA2 status bit 6
    output wire o_stat_vsync,    // vs_sync_ff[1]: the 0xA0/0xA2 status bit 5

    // vsync state shared with pc9821_gdc2 (status bit5 at 0xA0)
    output wire vsync_active,
    // ONE clk_sys pulse at the rising edge of the VSYNC pulse (vline 407, VACTIVE + VFP).
    output wire vsync_edge,
    input  wire vsync_irq_arm,
    output wire vsync_irq,

    // display enabled: the MODE FF1 DISP bit (mode1[7]) alone.
    output wire disp_on,
    // Graphics CPU access page (port 0xA6), exported because it offsets the GVRAM window.
    output wire gfx_access_page,
    // The EGC's gate: the extended-mode bit (FF2 num 2, mode2_egc).
    output wire gfx_egc_gate,

    // Bring-up telemetry: the display window the guest programmed.
    output wire [15:0] dbg_sad,
    output wire  [7:0] dbg_pitch,
    output wire        dbg_col40,
    output wire        dbg_disp,

    // ---- the text plane, as the compositor needs it ----
    output wire        text_opaque,
    output wire        text_cell,
    output wire [11:0] text_colour,

    // ---- pixel-timing view for the mixer ----
    output wire [9:0]  pix_dot,
    output wire        pix_h_active,
    output wire        pix_v_active,
    // The 200-line interleave's odd display line: text over black (see v_mode1_200).
    output wire        gfx_odd_line,

    // ---- graphics palette snapshot ----
    output wire        gfx_mode16,
    output wire [31:0] gfx_dig,
    output wire        pal_wr_en,
    output wire [3:0]  pal_wr_idx,
    output wire [1:0]  pal_wr_chan,
    output wire [3:0]  pal_wr_data,
    output wire        pal_commit,
    // The PEGC 256-colour palette's CPU write port (row 5): the UNMASKED 8-bit
    // 0xA8 index and FULL-byte channel writes, mode-gated on mode2_256col (NP2kai
    // gdc_oaa/oac/oae write `anareg[(16*3) + palnum*4 + c] = dat` under
    // GDCANALOG_256, io/gdc.c:852-904 - checked FIRST, so 256 wins over 16).
    output wire        pal256_wr_en,
    output wire [7:0]  pal256_wr_idx,
    output wire [1:0]  pal256_wr_chan,
    output wire [7:0]  pal256_wr_data,

    // ---- the PEGC view state ----
    // mode2_256col (FF2 num 0x10 / the 0x9A0 query's index 0x0A) is the PEGC select:
    // while it is set the 0xE0000 window is the PEGC register file, the two packed
    // windows replace the planar ones and the dot path takes the 256-colour arm
    // (NP2kai gdc_analogext sets GDCANALOG_256 + VOPBIT_VGA on the same 0x6A 0x21
    // write; MAME pc9821_video_ff_w selects m_pegc_mmio_view there). mode2_256e
    // (dat 0x68/0x69) is MAME's VRAM-boundary f/f: bit 0 set forces the packed
    // display page to 0 (pc9821.cpp:98 `BIT(m_ex_video_ff[0x68 >> 1], 0) ? 0 :
    // m_vram_disp * 0x40000`) - it is consumed by the packed scanout (row 3).
    output wire        gfx_pegc_256,
    output wire        gfx_pegc_256e,

    output wire       hs_out,  // negative polarity
    output wire       vs_out,  // negative polarity
    output wire       de_out
);

  // ---------------------------------------------------------------
  // GEOMETRY: THE MASTER GDC'S SYNC BLOCK, so the raster the guest programs IS the raster
  // this module counts on. The GDC's SYNC command (0x0E off / 0x0F on) carries EIGHT
  // parameter bytes into the master GDC's sync parameter RAM (NP2kai io/gdc_cmd.tbl:24-25),
  // and the line length, the active width, every porch and the frame length are a pure
  // function of those eight bytes. NP2kai is the reference for the arithmetic:
  // io/gdc.c:370-444 gdc_updateclock() is the only reference that derives anything (qemu-pc98
  // latches the same eight bytes in gdc_cmd_sync and then syncs every frame on a FIXED 18 ms
  // period, hw/display/pc98-vga.c:291-298 and :748-756). The PORCH ORDER is MAME's uPD7220
  // model (upd7220.cpp:347-358, :428-429), which the pulse comments below pin.
  //
  // THE FIELD MAP (para[] = the eight parameter bytes in arrival order; NP2kai's own names):
  //   cr   = para[1] + 2                     active characters -> HACTIVE = 8*cr
  //   tmp  = word(para[2..3])                para[2] is the LOW byte
  //     hs   = tmp & 0x1f                    h sync width      -> HSYNC_W = 8*hs
  //     vs   = (tmp >> 5) & 0x1f             v sync width      -> VSYNC_W = vs
  //     hfp2 = tmp >> 10                     h front porch     the two hfp fields sum
  //   para[4] & 0x3f                         the rest of the h front porch -> HFP = 8*(hfp2+that)
  //   para[5] & 0x3f                         v front porch     -> VFP
  //   tmp2 = word(para[6..7])
  //     lf   = ((tmp2 - 1) & 0x3ff) + 1      active lines      -> VACTIVE
  //     vbp  = tmp2 >> 10                    v back porch: whatever blanking is left
  // and NP2kai's own sums make the two totals:
  //   x = cr + hs + hfp2 + (para[4] & 0x3f) + 3   characters -> HTOTAL = 8*x
  //   y = lf + vs + (para[5] & 0x3f) + vbp        lines      -> VTOTAL = y
  // (the constant 3 is NP2kai's horizontal back porch, and y is 1 line when all four of its
  // blanking fields are zero: `if (!vfbs) vfbs = 1`). x and y are then CLAMPED into the
  // 24 kHz machine's monitor range - gdcclk[1] (io/gdc.c:34) is THIS machine's entry: the
  // character clock 21052600/8 with minx 100, maxx 112, miny 400, maxy 575. The GDC clock
  // select (0x6A nums 0x41/0x42) never moves the raster (measured on the machine), and gdcclk[0] (15.98 kHz) and the
  // SUPPORT_CRT31KHZ entry belong to other machines' monitors.
  // ONE DIVERGENCE, stated: where the clamp bites, NP2kai also rescales cr/lf by the clamp
  // ratio to keep the emulator's picture in proportion (io/gdc.c:419-430). That divide is not
  // modelled: the active counts are taken from the block and the blanking absorbs the clamp.
  // Inside the range (every block but an out-of-range program) the two are the same picture,
  // and the case cannot be measured on hardware, where a 24 kHz monitor does not lock to a
  // 260-line raster at all.
  //
  // THE DEFAULT IS NP2kai's defsyncm24 (io/gdc.c:42), the block gdc_biosreset copies into the
  // master GDC's parameter RAM on a 24 kHz machine (io/gdc.c:1080-1086):
  // {10 4e 07 25 07 07 90 65} -> cr 80, hs 7, vs 8, hfp 9+7, vfp 7, lf 400, vbp 25, so
  // x = 106 characters = 848 dots and y = 440 lines: 640 active dots in an 848-dot line and
  // 400 active lines in a 440-line frame, i.e. 24.83 kHz lines and 56.42 Hz frames at the
  // 21.0526 MHz dot clock, with porches 128/56/24 and 7/8/25 and the VSYNC pulse rising on
  // vline 407 = VACTIVE + VFP (docs/probes/FLIP.TXT).
  //
  // THE PULSE WIDTH IS THE vs FIELD, and the machine's own capture says so: the 2M-sample
  // 0x60 histogram counts bit 5 high in 36 385 of 2 097 152 samples = 1.735 %, which is 8 of
  // the 440 lines once its sampling loop's x1.048 duty bias is divided out - the bias the
  // same capture's bit 6 shows against the horizontal blank (23.4 % measured, 208/848 =
  // 24.53 % modelled) - so the machine's VSYNC pulse IS the block's vs = 8 lines, as MAME's
  // m_vs (upd7220.cpp:1236) and NP2kai's own expression both derive. The 12-line pulse this
  // file used to hardcode came from a "2.8 %" of the SAME count over a divisor of 1 310 720
  // instead of the 2 097 152 its own always-set bit 2 (0x200000 samples) prints; that
  // mis-derivation is corrected here (docs/probes/GDC.TXT).
  // ---------------------------------------------------------------
  // gdcclk[1]'s range (see above), in characters and lines, and NP2kai's own h back porch.
  localparam [9:0] CLK_MINX = 10'd100, CLK_MAXX = 10'd112;
  localparam [9:0] CLK_MINY = 10'd400, CLK_MAXY = 10'd575;
  localparam [8:0] HBP_CH   = 9'd3;
  // A sync pulse always LANDS somewhere: a zero-width hsync or vsync would silence the edge
  // the framework's scaler and the 0x64 VSYNC latch count on, and both references drive one
  // output per line/frame whatever the field says. One character and one line.
  localparam [9:0] HSYNC_MIN = 10'd8, VSYNC_MIN = 10'd1;

  // The block as it arrives (sync_live) and the copy the raster runs on (v_sync). The copy is
  // latched at the frame boundary like this module's other configuration registers, so an
  // eight-byte SYNC lands as a whole; NP2kai recomputes the geometry once per displayed frame
  // - drawscreen() calls gdc_updateclock(), io/gdc.c:1488 - so a mid-frame SYNC takes effect
  // at the next frame boundary there too.
  reg [7:0] sync_live[0:7];
  reg [7:0] v_sync[0:7];

  // ---- NP2kai's fields ----
  /* verilator lint_off UNUSEDSIGNAL */   // para[0] (the block's sync-format byte, which
  // gdc_updateclock() never reads) and the arriving block's unused horizontal fields: the
  // fields below are all read.
  wire [15:0] s_tmp    = {v_sync[3], v_sync[2]};        // word(para[2..3])
  wire [15:0] s_n_tmp  = {sync_live[3], sync_live[2]};  // ...as it ARRIVES
  wire [15:0] s_n_tmp2 = {sync_live[7], sync_live[6]};  // word(para[6..7]) as it arrives
  /* verilator lint_on UNUSEDSIGNAL */
  wire [9:0]  s_cr    = {2'b00, v_sync[1]} + 10'd2;
  wire [4:0]  s_hs_f  = s_tmp[4:0];
  wire [6:0]  s_hfp_f = {1'b0, s_tmp[15:10]} + {1'b0, v_sync[4][5:0]};
  wire [4:0]  s_vs_f  = s_tmp[9:5];
  wire [5:0]  s_vfp_f = v_sync[5][5:0];
  // The VERTICAL fields are taken from the block AS IT ARRIVES (the s_n_ form): their only
  // consumer is the frame-boundary root copy below, which samples them on the exact edge
  // the v_sync copy runs, so the roots land bit-identical with v_sync at every cycle (the
  // timing seam, spelled out at the copy). The porches keep the v_sync-domain s_vs_f/
  // s_vfp_f directly; both domains carry the same frame-boundary copy at every dot.
  wire [4:0]  s_n_vs_f  = s_n_tmp[9:5];
  wire [5:0]  s_n_vfp_f = sync_live[5][5:0];
  wire [5:0]  s_n_vbp_f = s_n_tmp2[15:10];
  // ((tmp2 - 1) & 0x3ff) + 1 is the low ten bits of tmp2 minus one, plus one.
  wire [9:0]  s_n_lfm1 = s_n_tmp2[9:0] - 10'd1;
  wire [10:0] s_n_lf   = {1'b0, s_n_lfm1} + 11'd1;

  // ---- NP2kai's roots, then the clamp ----
  wire [8:0]  s_hfbs  = {4'b0000, s_hs_f} + {2'b00, s_hfp_f} + HBP_CH;
  wire [9:0]  s_x_raw = s_cr + {1'b0, s_hfbs};
  wire [7:0]  s_x     = (s_x_raw < CLK_MINX) ? CLK_MINX[7:0]
                      : (s_x_raw > CLK_MAXX) ? CLK_MAXX[7:0] : s_x_raw[7:0];
  wire [7:0]  s_n_vfbs0 = {3'b000, s_n_vs_f} + {2'b00, s_n_vfp_f} + {2'b00, s_n_vbp_f};
  wire [7:0]  s_n_vfbs  = (s_n_vfbs0 == 8'd0) ? 8'd1 : s_n_vfbs0;
  wire [11:0] s_n_y_raw = {1'b0, s_n_lf} + {4'b0000, s_n_vfbs};
  wire [9:0]  s_n_y     = (s_n_y_raw < {2'b00, CLK_MINY}) ? CLK_MINY
                        : (s_n_y_raw > {2'b00, CLK_MAXY}) ? CLK_MAXY : s_n_y_raw[9:0];

  // ---- THE VERTICAL ROOTS: the frame-boundary copy is the TIMING SEAM ----
  // The fitted lightoc build's worst path ran v_sync[2][5] (s_vs_f[0]) through the vertical
  // decode, the fetch walker's row wrap and the row*pitch multiply into the TRAM port-B
  // address register (23.388 ns across 16 levels). The vertical decode now ENDS in s_lf_r/
  // s_y_r and the multiply ends in f_rowbase_r (the fetch section), leaving register-to-
  // register paths only.
  //
  // WHY THIS IS NOT A BEHAVIOUR CHANGE (the refactor-equivalence contract pinned cycle-
  // exactly by tests/pc9821/tb_pc9821_tram_addr_equiv.sv): s_lf_r/s_y_r are loaded from
  // the block as it ARRIVES (the s_n_ wires above) on the exact edge the v_sync copy runs
  // BESIDE them in the block below - so they equal the s_lf/s_y decode of v_sync at EVERY
  // cycle: v_sync only ever moves on that same edge from that same pre-edge sync_live (a
  // parameter write landing ON the edge is in neither), both reset to the default block,
  // and nothing else writes either. The geometry every consumer reads - this module's
  // counters and porches, the fetch walker's row wrap, pc9821_gdc2's wrapped display line
  // through o_vtotal, and the odd-line feed_odd/at_line_tick expression - is therefore ONE
  // value at ONE time, bit-identical to the pre-seam wiring at every dot: no next-frame
  // value early, no stale one late (the frame-boundary snapshot semantics are untouched).
  // A registered copy must NEVER feed only SOME of those consumers: a live/registered mix
  // would break the feed_odd = gdc2 v_oline[0] identity the odd-sync-parity fix proves
  // (cross-lane contract), which is why these registers ARE VTOTAL/VACTIVE's source.
  reg [10:0] s_lf_r;   // s_lf, the block's lf
  reg  [9:0] s_y_r;    // s_y, the clamped y = VTOTAL

  // ---- the geometry this module counts on ----
  wire [9:0] HTOTAL   = s_x * 10'd8;     // 8*x characters: 800..896 dots (a multiply by a
                                         // constant is a shift, and it keeps the width honest)
  wire [9:0] VTOTAL   = s_y_r;           // 400..575 lines (the seam's copy: see s_y_r)
  // The active window always leaves blanking to hold its own sync (x = cr + at least 3
  // characters, so for a block whose cr is inside its line this is cr exactly - and it is
  // clamped INTO the frame), and the pulse fits inside what is left.
  wire [12:0] s_hact8  = {s_cr, 3'b000};
  wire [9:0]  s_hactmax= HTOTAL - 10'd8;
  wire [9:0]  HACTIVE  = (s_hact8 > {3'b000, s_hactmax}) ? s_hactmax : s_hact8[9:0];
  wire [9:0]  s_hblank = HTOTAL - HACTIVE;                        // >= 8 dots
  wire [9:0]  s_hfp8   = {s_hfp_f, 3'b000};
  wire [9:0]  s_hs8    = {2'b00, s_hs_f, 3'b000};
  wire [9:0]  HFP      = (s_hfp8 <= (s_hblank - 10'd8)) ? s_hfp8 : (s_hblank - 10'd8);
  wire [9:0]  HSYNC_W  = (s_hs8 == 10'd0) ? HSYNC_MIN
                       : (s_hs8 <= (s_hblank - HFP)) ? s_hs8 : (s_hblank - HFP);
  wire [9:0]  s_lfmax  = VTOTAL - 10'd1;
  wire [9:0]  VACTIVE  = (s_lf_r > {1'b0, s_lfmax}) ? s_lfmax : s_lf_r[9:0];
  wire [9:0]  s_vblank = VTOTAL - VACTIVE;                        // >= 1 line
  wire [9:0]  s_vfp10  = {4'b0000, s_vfp_f};
  wire [9:0]  VFP      = (s_vfp10 > (s_vblank - 10'd1)) ? (s_vblank - 10'd1) : s_vfp10;
  wire [9:0]  s_vs10   = {5'b00000, s_vs_f};
  wire [9:0]  s_vs_room= s_vblank - VFP;                          // >= 1 line
  wire [9:0]  VSYNC_W  = (s_vs10 == 10'd0) ? VSYNC_MIN
                       : (s_vs10 > s_vs_room) ? s_vs_room : s_vs10;

  // ---------------------------------------------------------------
  // Video timing counters
  // ---------------------------------------------------------------
  reg [9:0] hdot;
  reg [9:0] vline;
  wire in_hsync = (hdot >= HACTIVE + HFP) && (hdot < HACTIVE + HFP + HSYNC_W);
  // The VSYNC PULSE. This is the GDC's vertical sync output: VFP lines of front porch after the
  // last active line, then VSYNC_W lines of sync, then the back porch that is left. The split is
  // MAME's uPD7220 model to the line - `update_vsync_timer` drives the output active at
  // y = m_vbp + m_al + m_vfp with the screen's visible top at m_vbp (upd7220.cpp:347-358,
  // :428-429) - and the width is the block's vs field (see the SYNC block above). The vblank IRQ
  // is raised on THIS pulse's rising edge (see vsync_irq), so with the default block the guest's
  // drawing window after the interrupt is vline 407 to the next frame's vline 0 = 33 lines.
  wire in_vsync = (vline >= VACTIVE + VFP) && (vline < VACTIVE + VFP + VSYNC_W);
  wire h_active = (hdot < HACTIVE);
  wire v_active = (vline < VACTIVE);
  wire frame_end = (vline == VTOTAL - 1) && (hdot == HTOTAL - 1);
  // The last walk slot of the vertical blanking interval, where the walker's own display-start
  // inputs are copied ahead of the walk trigger in the next slot (vline 432 for the default
  // 440-line frame). Row 0's cache is filled a whole frame before it is drawn, so the walker
  // re-walks row 0 in that slot with this frame's display start rather than the previous
  // frame's. The walk slots are the vline[3:0] == 0 grid, so the last one inside the frame is
  // VTOTAL-1 rounded down to that grid. The rest of the configuration, and the scanout itself,
  // still commits at frame_end below.
  wire [9:0] wk_slot = (VTOTAL - 10'd1) & 10'h3F0;
  wire wk_cfg_snap = (vline == wk_slot - 10'd1) && (hdot == HTOTAL - 1);

  // The raster half's copy of the sync block: unconditional at the frame boundary, like
  // v_mode1_200 below - the geometry is not one of the registers the scanout snapshot carries.
  // The vertical roots' copy (s_lf_r/s_y_r) runs in this SAME block so it samples the same
  // pre-edge sync_live on the same edge - see the timing seam above.
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      v_sync[0] <= 8'h10; v_sync[1] <= 8'h4e; v_sync[2] <= 8'h07; v_sync[3] <= 8'h25;
      v_sync[4] <= 8'h07; v_sync[5] <= 8'h07; v_sync[6] <= 8'h90; v_sync[7] <= 8'h65;
      s_lf_r <= 11'd400;   // defsyncm24's lf
      s_y_r  <= 10'd440;   // ...and its y
    end else if (pixel_ce && frame_end) begin
      v_sync[0] <= sync_live[0]; v_sync[1] <= sync_live[1];
      v_sync[2] <= sync_live[2]; v_sync[3] <= sync_live[3];
      v_sync[4] <= sync_live[4]; v_sync[5] <= sync_live[5];
      v_sync[6] <= sync_live[6]; v_sync[7] <= sync_live[7];
      s_lf_r <= s_n_lf;
      s_y_r  <= s_n_y;
    end
  end

  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      hdot  <= 10'd0;
      vline <= 10'd0;
    end else if (pixel_ce && frame_end) begin
      hdot  <= 10'd0;
      vline <= 10'd0;
    end else if (pixel_ce && hdot == HTOTAL - 1) begin
      hdot  <= 10'd0;
      vline <= vline + 10'd1;
    end else if (pixel_ce) hdot <= hdot + 10'd1;
  end

  // ---------------------------------------------------------------
  // CPU-side state
  // ---------------------------------------------------------------
  reg [7:0] mode1;  // MODE FF1
  // 0x6E is WRITE-ONLY on this machine: the probe captures (docs/probes/) record it
  // reading back 0xFF, and the read path below answers 0xFF rather than a latch.
  reg [7:0] crtc_pl, crtc_bl, crtc_cl, crtc_ssl, crtc_sur, crtc_sdr;
  // The GRCG's mode (0x7C) and tile (0x7E) registers live in pc9821_grcg: they
  // act on *GVRAM*, not on the text plane. This module keeps no copy of them -
  // 0x7C is write-only and its guest read is open bus 0xFF (RDBACK.TXT:152).
  reg [7:0] pitch;  // words per line
  // The text GDC's parameter RAM: screen 0's display start only, {sad_lo, sad_hi}. The
  // four-screen form has no reader past screen 0 - screens 1-3 and every length field are
  // written by the 0x70/0x74/0x78/0x7C PRAM commands and read back by nothing (the GDC's
  // PRAM has no read port in the RTL or in NP2kai), so they are not kept.
  reg [7:0] pram_scr[0:1];
  reg [7:0] csr_ead[0:1];  // CSRW cursor address
  // CSRW's THIRD byte, the address bits 16+. It is not dropped after all: the
  // CSRR command (0xE0) answers it masked to 2 bits as parameter byte 2
  // (NP2kai gdc_work fills para[GDC_CSRR+2] = para[GDC_CSRW+2] & 3, io/gdc.c:327-337).
  reg [7:0] csr_ead2;
  reg [7:0] csr_form[0:2];  // CSRFORM params
  reg cmd_active;
  reg [7:0] cur_cmd;
  reg [2:0] param_cnt;
  reg sync_pending;
  reg [2:0] sync_cnt;
  reg gdc_start;  // GDC1 character display started

  // MODE FF2 bits 1 (the FF2 num-1 latch) and GDCANALOG_256E (the FF2 dat
  // 0x68/0x69 form), and the two GDC clock-select bits (dat 0x82/0x83 and
  // 0x84/0x85). NP2kai toggles all of these unconditionally (its gdc_o6a bit
  // form and dat cases, io/gdc.c:501-603) and reads them back through the 0x6A
  // register (bit 1) and the 0x9A0 query table. Nothing else consumes them.
  reg mode2_ff2b1;
  reg mode2_256e;
  reg [1:0] gdc_clock;

  // The parameter read-back queue (NP2kai's snd/para pair): commands with
  // `indatas` load it (gdc_cmd.tbl rows 0xC0 LPEN = 3 bytes and 0xE0 CSRR = 5),
  // a read of 0x62 pops one byte, and any new command replaces it (gdc_work's
  // `item->snd = gdc_cmd[data].indatas`). CSRR answers {CSRW0, CSRW1, CSRW2&3,
  // 0, 0}; LPEN answers para[GDC_LPEN..2] = para[29..31] (io/gdc_cmd.h:34,38:
  // GDC_CSRFORM = 9, GDC_LPEN = 29 - the old "== 29" claim was false). No
  // command writes those slots (no gdc_cmd.tbl row stores to pos 29) and
  // gdc_reset zero-fills them (io/gdc.c:1160), so LPEN answers 00 00 00 - NOT
  // the CSRFORM bytes this module keeps for the cursor.
  reg [7:0] gdc_snd[0:4];
  reg [2:0] gdc_snd_cnt;
  reg [2:0] gdc_snd_ptr;
  // The read-data register: the pop loads the returned byte here, because every
  // GDC-block read is captured one cycle after the strobe (device_rd_wait in
  // pc9821_system) - the byte the CPU receives must survive the advance.
  reg [7:0] gdc_snd_q;

  reg [7:0] dig_a8, dig_aa, dig_ac, dig_ae;  // digital palette port bytes

  // Graphics page selection (ReC98 page_show/page_access): 0xA4 chooses the page
  // the display scans out, 0xA6 the page the CPU's A8000/E0000 window shows.
  reg        display_page;
  reg        access_page;

  reg       mode2_16color;
  reg       mode2_egc;        // FF2 num 2:  EGC extended mode latch
  reg       mode2_wren;       // FF2 num 3:  EGC/PEGC register write enable
  /* verilator lint_off UNUSEDSIGNAL */  // latched but unconsumed: PEGC 256-colour and
  // 31 kHz text shift are unimplemented. Kept - the guest's write records that it asked.
  reg       mode2_256col;     // FF2 num 0x10: 256-colour / PEGC select
  reg       mode2_textshift;  // FF2 num 0x20: text shift (31 kHz CRT)
  /* verilator lint_on UNUSEDSIGNAL */
  // The 0xA8 palette-index register: the FULL byte, round-trip. NP2kai stores `dat`
  // unmasked in gdc.palnum (io/gdc.c:841) and gdc_ia8 returns it verbatim (:913-919),
  // so `out 0xA8,0xAB / in 0xA8` reads 0xAB - the register is architecturally 8 bits
  // (the PEGC 256-colour palette indexes through it, gdc.c:854). The old 4-bit
  // register answered 0x0B. Who consumes it, exactly as NP2kai splits
  // it: the DAC takes palnum & 15 (gdc.c:862 gdc_setanalogpal) and the read mirror
  // below takes the MASKED palnum & 15 (the PEGC 256-colour mirror is out of scope).
  reg [7:0] pal_sel;
  // The analogue table's READ MIRROR: three FULL 8-bit channel bytes per entry
  // ({B, R, G} = write bytes 0xAE/0xAC/0xAA), kept so a CPU read of
  // 0xAA/0xAC/0xAE answers the whole byte the guest wrote. NP2kai stores the
  // full byte in gdc.anareg and reads it back verbatim (io/gdc.c:860-953); the
  // old mirror kept only io_din[3:0] and answered 0x0F where the guest wrote
  // 0xFF. The PIXEL table still takes the
  // low nibble (pal_wr_data): the 16-colour DAC is 4 bits wide and the visual is
  // right - only the readback shape was wrong. IMMEDIATE semantics like the
  // registers it replaces; one 24-bit output register is its read port.
  // 16 entries, indexed by palnum & 15: the Xe10's own 16-colour analogue palette.
  // NP2kai's 256-entry anareg[palnum*3+c] mirror is the PEGC's
  // 256-colour palette, which is out of scope here - reverted for area (the 256-entry
  // register array cost ~6 Kbit of logic on a ~99%-full device).
  //
  // THE MIRROR IS THREE 16x8 BYTE LANES, one per channel, not one 16x24 array written in
  // byte pieces. Measured with tools/res_exp_map.py: a 16x24 word written one byte at a
  // time does not infer at all - no block type accepts a byte-granular write into a word -
  // and stays in logic at 206-211 combinational ALUTs plus the 384 registers, while the
  // same 384 bits as three byte-wide lanes with whole-byte writes are 3 ALUTs and three
  // RAM rows. The fit's own mux census prices the single array's read port
  // (`pc9821_crtc:u_crtc|pal_rd_q[12]`, a 16:1 x 24-bit mux, `map.rpt` section 60) at
  // 240 LEs of standing area the restructurer could not touch.
  // A lane is 16 words x 8 bits, so the geometry is legal for both a Cyclone V M10K block
  // and an MLAB; M10K is the one that is free here, because a block RAM's read and write
  // registers live inside the block, while an MLAB is a LAB's ALMs reconfigured (10 ALMs).
  // LABs are this device's binding resource, M10K is not.
  (* ramstyle = "M10K" *) reg [7:0] pal_g[0:15];
  (* ramstyle = "M10K" *) reg [7:0] pal_r[0:15];
  (* ramstyle = "M10K" *) reg [7:0] pal_b[0:15];
  // The read port is the registered read the single array always had (one clk_sys from the
  // lane's address to the byte), so the CPU readback's one-cycle latency is unchanged; the
  // three bytes re-join combinationally, which is all the read decode ever needed.
  reg [7:0] pal_g_q, pal_r_q, pal_b_q;
  wire [23:0] pal_rd_q = {pal_b_q, pal_r_q, pal_g_q};

  // The command parameter counts (NP2kai gdc_cmd.tbl's `outdatas` column). SYNC is in
  // the table as eight bytes (rows 0x0e/0x0f) even though its capture runs on
  // sync_pending/sync_cnt rather than cmd_active, so the count is stated here where the
  // other commands' counts live.
  function [3:0] cmd_params(input [7:0] c);
    case (c)
      8'h06:                      cmd_params = 4'd1;  // ZOOM (latched, ignored)
      8'h47:                      cmd_params = 4'd1;  // PITCH
      8'h49:                      cmd_params = 4'd3;  // CSRW (kasumi sends 3rd byte 0)
      8'h4B:                      cmd_params = 4'd3;  // CSRFORM
      8'h0E, 8'h0F:               cmd_params = 4'd8;  // SYNC off/on: the sync block
      8'h70, 8'h74, 8'h78, 8'h7C: cmd_params = 4'd4;  // PRAM (4 bytes)
      default:                    cmd_params = 4'd0;
    endcase
  endfunction

  // ---- the port encoder (#4, the #3 recipe) ----
  // Every I/O address this module decodes gets ONE 5-bit code here; the write `case` below
  // and the read mux then compare a 5-bit code each instead of re-decoding the eight
  // address bits twice. PC_NONE is the undecoded case, and the read mux answers it (like
  // the two write-only ports) 0xFF.
  localparam [4:0] PC_NONE = 5'd31;
  function automatic [4:0] port_code(input [7:0] a);
    case (a)
      8'h60:   port_code = 5'd0;    // GDC1 parameter
      8'h62:   port_code = 5'd1;    // GDC1 command
      8'h64:   port_code = 5'd2;    // VSYNC IRQ arm
      8'h68:   port_code = 5'd3;    // MODE FF1
      8'h6A:   port_code = 5'd4;    // MODE FF2
      8'h6E:   port_code = 5'd5;    // write-only (reads 0xFF)
      8'h70:   port_code = 5'd6;
      8'h72:   port_code = 5'd7;
      8'h74:   port_code = 5'd8;
      8'h76:   port_code = 5'd9;
      8'h78:   port_code = 5'd10;
      8'h7A:   port_code = 5'd11;
      8'h7C:   port_code = 5'd12;   // GRCG mode, WRITE-ONLY: the byte read is open bus FF (RDBACK.TXT:152)
      // 0xA0/0xA2 are pc9821_gdc2's, 0xA1/0xA3/0xA5/0xA9 are pc9821_cg's; this module
      // does not decode them.
      8'hA4:   port_code = 5'd17;   // graphics display page
      8'hA6:   port_code = 5'd19;   // graphics access page
      8'hA8:   port_code = 5'd20;
      8'hAA:   port_code = 5'd22;
      8'hAC:   port_code = 5'd23;
      8'hAE:   port_code = 5'd24;
      default: port_code = PC_NONE;
    endcase
  endfunction
  wire [4:0] pc = port_code(io_addr);

  integer i;
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      mode1    <= 8'h98;   // FONTSEL|200LINE|DISP power-on (verified)
      gdc_start <= 1'b0;   // GDC stopped until BIOS issues BCTRL/START
      crtc_pl  <= 8'h00;   // 400-25 boot row (verified)
      crtc_bl  <= 8'h0F;
      crtc_cl  <= 8'h10;
      crtc_ssl <= 8'h00;
      crtc_sur <= 8'h00;   // measured 0x78 = 0x00 (was 0x01)
      crtc_sdr <= 8'h00;
      pitch    <= 8'd80;
      cmd_active <= 1'b0;
      sync_pending <= 1'b0;
      sync_cnt  <= 3'd0;
      param_cnt <= 3'd0;
      dig_a8 <= 8'h37;     // verified power-on digital palette
      dig_aa <= 8'h15;
      dig_ac <= 8'h26;
      dig_ae <= 8'h04;
      mode2_16color <= 1'b0;
      mode2_egc <= 1'b0;
      mode2_wren <= 1'b0;
      mode2_256col <= 1'b0;
      mode2_textshift <= 1'b0;
      mode2_ff2b1 <= 1'b0;
      mode2_256e <= 1'b0;
      gdc_clock <= 2'b00;   // NP2kai gdc_biosreset: gdc.clock = 0 (io/gdc.c:1121)
      pal_sel <= 8'd0;
      display_page <= 1'b0;
      access_page  <= 1'b0;
      csr_ead[0] <= 8'h00;
      csr_ead[1] <= 8'h00;
      csr_ead2 <= 8'h00;
      csr_form[0] <= 8'h0F; // boot cursor disabled (verified)
      csr_form[1] <= 8'hC0;  // NP2kai's power-on CSRFORM[1] (io/gdc.c:1084)
      csr_form[2] <= 8'h7B;
      gdc_snd_cnt <= 3'd0;   // nothing pending: 0x62 answers 0xFF
      gdc_snd_ptr <= 3'd0;
      gdc_snd_q   <= 8'hFF;
      // The master GDC's power-on SYNC block: NP2kai's defsyncm24 (io/gdc.c:42), the block
      // gdc_biosreset copies in on a 24 kHz machine (:1080-1086). The native BIOS never
      // issues SYNC itself - no `out 62h,0Fh` in the Xe10's BANK0-7 - so these eight bytes
      // ARE the machine's default raster until a guest programs another one.
      sync_live[0] <= 8'h10; sync_live[1] <= 8'h4e;
      sync_live[2] <= 8'h07; sync_live[3] <= 8'h25;
      sync_live[4] <= 8'h07; sync_live[5] <= 8'h07;
      sync_live[6] <= 8'h90; sync_live[7] <= 8'h65;
      for (i = 0; i < 2; i = i + 1) pram_scr[i] <= 8'h00;
    end else begin
      // The parameter read-back queue's pop: exactly one byte per CPU read of
      // 0x62 (NP2kai gdc_i62, io/gdc.c:684-692). The returned byte is loaded
      // into the read-data register because the GDC block's reads are captured
      // one cycle after this strobe.
      if (io_rd && (pc == 5'd1)) begin
        if (gdc_snd_cnt != 3'd0) begin
          gdc_snd_q   <= gdc_snd[gdc_snd_ptr];
          gdc_snd_ptr <= gdc_snd_ptr + 3'd1;
          gdc_snd_cnt <= gdc_snd_cnt - 3'd1;
        end else gdc_snd_q <= 8'hFF;
      end
    if (io_wr) begin
      case (pc)
        5'd0: begin  // GDC1 parameter port
          if (sync_pending) begin
            // The SYNC block's eight bytes, in arrival order (NP2kai gdc_work stores each
            // parameter byte into para[ptr++] as it arrives, io/gdc.c:341-345).
            sync_live[sync_cnt] <= io_din;
            if (sync_cnt == 3'd7) begin
              sync_pending <= 1'b0;
              sync_cnt <= 3'd0;
            end else sync_cnt <= sync_cnt + 3'd1;
          end else if (cmd_active) begin
            // Each parameter byte lands in its register AS IT ARRIVES - the model both
            // references implement (NP2kai gdc_work writes para[ptr++] per byte; QEMU
            // calls gdc_cmd_csrw/gdc_cmd_csrform per byte). The authentic BIOS sends only
            // TWO CSRW bytes and ONE CSRFORM byte (BANK6@0x49cf, BANK7@0x6a45), so applying
            // at completion never latches either and the text cursor stays dead.
            // The command count stays 3; the extra CSRW byte (address bit 16+) is
            // kept in csr_ead2 because CSRR answers it (see its declaration).
            if ((cur_cmd == 8'h49) && (param_cnt[1:0] < 2'd2)) begin
              csr_ead[param_cnt[0]] <= io_din;   // ead = p0 | p1<<8 (QEMU gdc_cmd_csrw)
            end
            if ((cur_cmd == 8'h49) && (param_cnt[1:0] == 2'd2)) begin
              csr_ead2 <= io_din;
            end
            if (cur_cmd == 8'h4B) begin
              case (param_cnt[1:0])
                2'd0:    csr_form[0] <= io_din;
                2'd1:    csr_form[1] <= io_din;
                default: csr_form[2] <= io_din;
              endcase
            end
            // PRAM: a single indexed write of screen 0's {sad_lo, sad_hi}.
            // Commands 0x70/0x74/0x78/0x7C select screens 0/1/2/3 via {cur_cmd[3:2]}, and
            // param_cnt is 0..3 (cmd_params == 4, C5). Only screen 0's first two
            // bytes reach the scanout, so the rest are accepted and dropped: the command
            // still consumes its four parameter bytes, which is what the firmware's
            // transaction (BANK7@0x69ac-0x69d4) and the 0x70 spin_one_frame cases need.
            if ((cur_cmd == 8'h70) && (param_cnt[1:0] < 2'd2)) begin
              pram_scr[param_cnt[0]] <= io_din;
            end
            if (param_cnt + 3'd1 == cmd_params(cur_cmd)) begin
              cmd_active <= 1'b0;
              param_cnt  <= 3'd0;
              // PITCH is a one-parameter command, so this is its only parameter.
              if (cur_cmd == 8'h47) pitch <= {io_din[7:1], 1'b0};  // odd bit dropped (NP2kai maketext.c:194)
            end else param_cnt <= param_cnt + 3'd1;
          end
        end
        5'd1: begin  // GDC1 command port
          cur_cmd <= io_din;
          // Every command REPLACES the parameter read-back queue (NP2kai
          // gdc_work: `item->snd = gdc_cmd[data].indatas`, io/gdc.c:327). The
          // two producers are gdc_cmd.tbl's rows with indatas: 0xE0 CSRR answers
          // five bytes {CSRW0, CSRW1, CSRW2&3, 0, 0} (io/gdc.c:328-337) and
          // 0xC0 LPEN three (gdc_cmd.tbl:214) - para[29..31], the never-written
          // light-pen slots, zero since gdc_reset (io/gdc.c:1160).
          gdc_snd_ptr <= 3'd0;
          case (io_din)
            8'hE0: begin
              gdc_snd[0] <= csr_ead[0];
              gdc_snd[1] <= csr_ead[1];
              gdc_snd[2] <= csr_ead2 & 8'h03;
              gdc_snd[3] <= 8'h00;
              gdc_snd[4] <= 8'h00;
              gdc_snd_cnt <= 3'd5;
            end
            8'hC0: begin
              // para[29..31]: no command writes the LPEN slots, so they hold
              // gdc_reset's zeros whatever CSRFORM holds (io/gdc.c:1160).
              gdc_snd[0] <= 8'h00;
              gdc_snd[1] <= 8'h00;
              gdc_snd[2] <= 8'h00;
              gdc_snd_cnt <= 3'd3;
            end
            default: gdc_snd_cnt <= 3'd0;
          endcase
          // EVERY command byte ends an unfinished SYNC block: NP2kai gdc_work reloads
          // `item->ptr`/`item->rcv` from the new command's gdc_cmd.tbl row (io/gdc.c), so a
          // SYNC cut short by the next command takes no more bytes - its parameters must
          // not swallow the next command's (they would rewrite the raster geometry).
          // ONE assignment per command write (R2): armed by 0x0E/0x0F, cleared by the rest.
          sync_pending <= (io_din == 8'h0E) || (io_din == 8'h0F);
          sync_cnt     <= 3'd0;
          if (io_din == 8'h0E || io_din == 8'h0F) begin  // SYNC off/on
            cmd_active   <= 1'b0;
            gdc_start    <= io_din[0];  // 0x0F on / 0x0E off
          end else if (io_din == 8'h0D || io_din == 8'h6B) begin
            gdc_start  <= 1'b1;  // BCTRL on / START
            cmd_active <= 1'b0;
          end else if (io_din == 8'h0C || io_din == 8'h05) begin
            gdc_start  <= 1'b0;  // BCTRL off / STOP
            cmd_active <= 1'b0;
          end else if (io_din == 8'h00) begin
            // RESET, a NAMED NO-OP rather than the default arm. The Dec85
            // datasheet's RESET clears the GDC's FIFO and blanks the display; this core models
            // neither, and blanking here would be a visible change with no reference to check it
            // against. The divergence is deliberate and its one observable contract is kept:
            // RESET takes NO parameter byte, so it must not arm the parameter capture.
            cmd_active <= 1'b0;
          end else if (cmd_params(io_din) != 4'd0) begin
            cmd_active <= 1'b1;
            param_cnt  <= 3'd0;
          end else begin
            cmd_active <= 1'b0;  // 0-parameter commands
          end
        end
        5'd3: begin  // MODE FF1: bit = (dat>>1)&7, on = dat&1
          // NP2kai drops a write whose bits 4-7 are set: the register is a bit number and
          // value pair, so only the low nibble is meaningful (io/gdc.c:485).
          if (io_din[7:4] == 4'h0) begin
            if (io_din[0]) mode1 <= mode1 | (8'h01 << io_din[3:1]);
            else mode1 <= mode1 & ~(8'h01 << io_din[3:1]);
          end
        end
        5'd4: begin  // MODE FF2: num = (dat>>1)&0x7f, on = dat&1
          case ((io_din >> 1) & 8'h7F)
            // num 0: 8-colour (digital) vs 16-colour (analogue) select.
            8'h00: mode2_16color <= io_din[0];
            // num 1: mode2 bit 1. It moves no pixel in any reference, but a guest
            // RMW of 0x6A must round-trip it (NP2kai returns the live gdc.mode2,
            // io/gdc.c:703).
            8'h01: mode2_ff2b1 <= io_din[0];
            // num 3: the EGC/PEGC register write enable. A real guard, not decoration:
            // the firmware always brackets the bits below with it (master.lib EGC_ON;
            // BANK6@0xFFD4F-0xFFD87), and QEMU takes num 2 only while it is set.
            8'h03: mode2_wren <= io_din[0];
            // num 2: EGC extended mode. The EGC's real gate is THIS bit AND the GRCG's
            // CG mode, 0x7C bit 7 - not 0x9A0 bit 2 (ReC98 egc.hpp:58-64; QEMU
            // pc98-vga.c:2465/2559; NP2kai io/gdc.c:534-541 all agree). The GRCG CG mode
            // is decoded in pc9821_grcg, so the EGC gate must be taken from there.
            8'h02: if (mode2_wren) mode2_egc <= io_din[0];
            // num 0x10 (256-colour) and num 0x20 (text shift) are real firmware traffic
            // (BANK4@0xFD6D8-0xFD6E2, BANK6@0xFFD4F-0xFFD87).
            // num 0x10's writes (FF2 dat 0x20/0x21) are NP2kai's GDCANALOG_256
            // setters (gdc_analogext, gated on mode2 bit 3 exactly as here), so the
            // 0x9A0 query's index 0x0A reports this bit. num 0x20's (dat 0x40/0x41)
            // are NP2kai's GDCDISP_PLAZMA setters, and dat 0x80/0x81 (num 0x40) move
            // the SAME bit there (io/gdc.c:572-581), so the query's index 0x05
            // reports it too - UNGUARDED: NP2kai's dat switch tests `gdc.mode2 & 0x08`
            // for 0x20/0x21 only, and MAME pc9821_video_ff_w protects dat 4/5 alone.
            8'h10: if (mode2_wren) mode2_256col <= io_din[0];
            8'h20, 8'h40: mode2_textshift <= io_din[0];
            // num 0x34 (dat 0x68/0x69) is GDCANALOG_256E and nums 0x41/0x42
            // (dat 0x82/0x83 and 0x84/0x85) the two gdc.clock bits - NP2kai's
            // gdc_o6a dat cases toggle all three unconditionally and the 0x9A0
            // query reads them (io/gdc.c:563-603, 996-1013). Nothing else consumes
            // them here.
            8'h34: mode2_256e <= io_din[0];
            8'h41: gdc_clock[0] <= io_din[0];
            8'h42: gdc_clock[1] <= io_din[0];
            default: ;
          endcase
        end
        // The six CRTC render registers, stored FIVE bits wide: NP2kai's crtc_o70
        // does `dat &= 0x1f` before storing any of pl/bl/cl/ssl/sur/sdr
        // (io/crtc.c:10-17), so `out 70h,0FFh` reads back 0x1F there and the
        // sur/sdr/pl fields carry no bits above 4.
        5'd6:    crtc_pl  <= io_din & 8'h1F;
        5'd7:    crtc_bl  <= io_din & 8'h1F;
        5'd8:    crtc_cl  <= io_din & 8'h1F;
        5'd9:    crtc_ssl <= io_din & 8'h1F;
        5'd10:   crtc_sur <= io_din & 8'h1F;
        5'd11:   crtc_sdr <= io_din & 8'h1F;
        // 0x7C/0x7E are the GRCG's mode and tile registers; pc9821_grcg owns them and
        // this module answers neither read (0x7C's guest read is open bus 0xFF).
        5'd17:   display_page <= io_din[0];  // graphics display page
        5'd19:   access_page  <= io_din[0];  // graphics CPU access page
        // 0xA8 is the palette INDEX register: the full byte in analogue modes
        // (NP2kai gdc_oa8 `gdc.palnum = dat`, io/gdc.c:841), degpal[3] in digital.
        5'd20:   if (mode2_16color || mode2_256col) pal_sel <= io_din;
 else dig_a8 <= io_din;
        // PC-98 analogue palette order is A8=index, AA=green, AC=red,
        // AE=blue (master.lib/rec98, NP2kai and QEMU agree). In 16-colour mode these
        // writes leave this module on pal_wr_* (below) and land in the palette's
        // displayed table, and the same bytes land in the read mirror's lanes
        // (pal_g/pal_r/pal_b) for the readback; only the 8-colour digital
        // bytes are latched from here.
        5'd22:   if (!mode2_16color && !mode2_256col) dig_aa <= io_din;   // 0xAA, G
        5'd23:   if (!mode2_16color && !mode2_256col) dig_ac <= io_din;   // 0xAC, R
        5'd24:   if (!mode2_16color && !mode2_256col) dig_ae <= io_din;   // 0xAE, B
        default: ;
      endcase
      end
    end
  end

  // vsync, blanking and the data-ready line resampled into clk_sys for status reads. The
  // bit duties are measured on the real machine with a 2M-sample histogram: bit 2 always
  // set, bit 5 ~2.7% (VSYNC), bit 6 ~23.4% (the horizontal blank, 208/848: docs/probes/TIME.TXT
  // `high 1.7% of the time and bit6 23.4%`; NP2kai io/gdc.c gdc_i60 `if ((remain % gdc.rasterclock) < gdc.hsyncclock)`
  // raises it once per LINE, vertical-blank lines included; its phase in the line is unmeasured, todo item 23),
  // bit 0 ~50%. Driving bit 6
  // from the real blanking and bit 0 from a DOT-rate toggle makes every guest poll end.
  //
  // BIT 0'S RATE: the toggle is clocked by `pixel_ce` - the PIXEL_HZ-derived dot enable - and
  // NOT by clk_sys, because a clk_sys count is not a time (AGENTS.md's rates rule: raising
  // clk_sys must not move a guest-visible time). Before this the bit
  // toggled every clk_sys, so its period halved at 100 MHz (tb_pc9821_sysclk_invariance pins
  // the fix). THE REAL PERIOD IS UNMEASURED and this choice is not evidence for it: the
  // machine capture measures the DUTY alone (docs/probes/GDC.TXT's 2^21-sample histogram at
  // 0x60 has bit 0 set in exactly half its samples), no reference gives the data-ready rate,
  // and the period a real uPD7220 holds it at is unknown - so the dot rate is a stand-in that
  // is at least profile-invariant and of the right order (the DR line is a display signal).
    // Reset state: vs_sync_ff/de_ff are the rest of the stat_dr family
    // and reset to 00/00, so the first two GDC status reads after a reset return the reset
    // raster's BLANK (bit 6 = ~de_ff[1]) / NO-VSYNC (bit 5) values the probe measured instead
    // of X - the ITF polls this port early. stat_dr is the documented self-fed toggle (`stat_dr
    // <= ~stat_dr`, no reset): its power-up seed resolves the X-lock its
    // inversion would otherwise lock in 4-state sim, and it free-runs from there (bit 0 is
    // ~50 % either way). The two resample chains sample live inputs and self-correct in two clocks.
    /* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
    reg [1:0] vs_sync_ff = 2'b00;
    reg [1:0] de_ff = 2'b00;
    reg       stat_dr = 1'b0;
    /* verilator lint_on PROCASSINIT */
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      vs_sync_ff <= 2'b00;
      de_ff      <= 2'b00;
    end else begin
      vs_sync_ff[0] <= in_vsync;
      vs_sync_ff[1] <= vs_sync_ff[0];
      de_ff[0] <= h_active;   // bit 6 is the per-line horizontal blank (see above)
      de_ff[1] <= de_ff[0];
    end
    if (pixel_ce) stat_dr <= ~stat_dr;   // the DOT rate, so clk_sys cannot move it (see above)
  end
  assign o_stat_blank = ~de_ff[1];
  assign o_stat_vsync = vs_sync_ff[1];

  // ---------------------------------------------------------------
  // Configuration snapshot at the frame boundary
  // The scanout needs a coherent snapshot of the configuration registers, so it copies
  // them at a frame end rather than mid-frame. The pixel enable gates the same clk_sys, so
  // this is not a clock crossing; the protocol bounds the copy to one frame of staleness. A
  // write announces itself on the NEXT clk_sys cycle (cfg_data_d) so the registers are stable
  // when cfg_dirty rises, the video side copies at a frame boundary and acknowledges, and
  // only then does clk_sys drop it; a racing write is re-copied.
  // ---------------------------------------------------------------
  reg       cfg_data_d;    // write strobe delayed one cycle
  reg       cfg_dirty;     // a configuration change is waiting to be copied
  reg       cfg_ack;       // copy acknowledgement, driven from the raster domain
  reg [1:0] cfg_ack_sync;  // ...synchronised back into clk_sys
  reg       cfg_ack_seen;
  wire      cfg_ack_edge = cfg_ack_sync[1] != cfg_ack_seen;
  // The write epoch the acknowledgement is qualified with (see the clear rule).
  reg [7:0] cfg_epoch;       // one count per configuration write
  reg [7:0] cfg_epoch_snap;  // ...as of the copy's own clock edge (raster block below)

  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      cfg_data_d   <= 1'b0;
      cfg_dirty    <= 1'b1;   // force the power-on snapshot at the first frame
      cfg_ack_sync <= 2'b00;
      cfg_ack_seen <= 1'b0;
      cfg_epoch    <= 8'd0;
    end else begin
      cfg_data_d <= io_wr;
      // A new write wins over a simultaneous acknowledgement so nothing is lost.
      if (cfg_data_d)   cfg_dirty <= 1'b1;
      // ...and an acknowledgement must not clear a write the copy did not take.
      // The frame_end copy samples the registers with non-blocking assignments,
      // so a write landing on (or the clk before) the copy's edge is NOT in that
      // copy; its announce then arrives after the announce this ack belongs to
      // and the unqualified clear dropped it until some later write re-dirtied
      // the flag (the window pc9821_gdc2:172-177 admits). Every write moves
      // cfg_epoch on the same edge its data moves, the copy snapshots the epoch
      // at its own edge, and the ack clears only when the two agree: a write the
      // copy missed keeps cfg_dirty set and is re-copied at the NEXT frame end
      // (deferred, not lost).
      else if (cfg_ack_edge && (cfg_epoch == cfg_epoch_snap)) cfg_dirty <= 1'b0;
      if (io_wr) cfg_epoch <= cfg_epoch + 8'd1;
      cfg_ack_sync <= {cfg_ack_sync[0], cfg_ack};
      cfg_ack_seen <= cfg_ack_sync[1];
    end
  end

  // Armed VSYNC IRQ delivery (port 0x64 one-shot latch).
  // Touhou's INT 0Ah handler (ReC98 vsync.cpp) rearms 0x64 after the PIC
  // EOI, so exactly one request is raised per armed frame. Unarmed frames
  // produce no request at all.
  wire vsync_rise = vs_sync_ff[0] & ~vs_sync_ff[1];
  reg vsync_irq_armed;
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      vsync_irq_armed <= 1'b0;
    end else begin
      if (vsync_irq_arm) vsync_irq_armed <= 1'b1;
      else if (vsync_rise && vsync_irq_armed) vsync_irq_armed <= 1'b0;
    end
  end
  assign vsync_irq = vsync_rise & vsync_irq_armed;

  // ---------------------------------------------------------------
  // TRAM BRAM 16 KB (CPU port and scanout/walker port, same clk_sys)
  // ---------------------------------------------------------------
  wire [ 7:0] tram_vid_q;
  wire [13:0] tram_vid_addr;
  assign o_tram_vid_q = tram_vid_q;
  // The text VRAM and the hardware memory switches are their own owner (graphics
  // end-state step 3, piece 1): pc9821_text_mem carries the TRAM, the switch cells,
  // the MODE FF1 bit-6 write gate and the reset seed. The CRTC provides only the CPU
  // port, the scanout's read address and the FF1 bit.
  pc9821_text_mem u_text_mem (
      .clk          (clk_sys),
      .rst_n        (rst_n_sys),
      .pixel_ce     (pixel_ce),
      .cpu_addr     (tram_cpu_addr),
      .cpu_din      (tram_cpu_din),
      .cpu_we       (tram_cpu_we),
      .cpu_dout     (tram_cpu_dout),
      .vid_addr     (tram_vid_addr),
      .vid_q        (tram_vid_q),
      .mode1_bit6   (mode1[6]),
      .cfg_fdd_mode (cfg_fdd_mode)
  );

  // ---------------------------------------------------------------
  // Display register copies in the raster domain (re-sampled at frame end)
  // ---------------------------------------------------------------
  reg v_disp, v_col40, v_mode16;
  reg v_mode1_sg;   // mode1 bit 0 (simplified-graph): the bit-4 vertical line's enable
  reg [7:0] v_pitch;
  reg [7:0] v_sad_lo, v_sad_hi;
  reg v_row0_stale;  // row 0's cache was filled with the previous frame's display start
  // The DIGITAL palette's frame-boundary snapshot. The analogue table is not here any
  // more (#2): it is pc9821_gfx_palette's ping-pong MLAB, and what stays in this
  // module is the 0xA8 index and the read mirror. The 0xAA = green / 0xAC = red /
  // 0xAE = blue order is applied at the write (pal_wr_chan) and at the read.
  reg [7:0] v_dig_a8, v_dig_aa, v_dig_ac, v_dig_ae;
  reg [7:0] v_csrform[0:2];
  reg [7:0] v_csread[0:1];

  // The raster half of the configuration handshake: a two-flop synchroniser for the
  // dirty flag, plus the copy acknowledgement returned to clk_sys. Both start at
  // zero so clk_sys's power-on cfg_dirty=1 produces exactly one frame-boundary
  // snapshot of the reset configuration.
  reg [1:0] cfg_dirty_sync;
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      cfg_dirty_sync <= 2'b00;
      cfg_ack        <= 1'b0;
      v_disp <= 1'b0;
      v_col40 <= 1'b0;
      v_mode1_sg <= 1'b0;
      v_mode16 <= 1'b0;  // off: GDC stopped
      v_pitch <= 8'd80;
      v_sad_lo <= 8'h00;
      v_sad_hi <= 8'h00;
      v_csrform[0] <= 8'h0F;
      v_csrform[1] <= 8'hC0;   // NP2kai's power-on CSRFORM[1] (io/gdc.c:1084)
      v_csrform[2] <= 8'h7B;
      v_csread[0] <= 8'h00;
      v_csread[1] <= 8'h00;
      v_dig_a8 <= 8'hFF;
      v_dig_aa <= 8'hFF;
      v_dig_ac <= 8'hFF;
      v_dig_ae <= 8'hFF;
      v_row0_stale <= 1'b0;
      cfg_epoch_snap <= 8'd0;
    end else if (pixel_ce) begin
      // Two-flop synchroniser for the configuration-dirty flag. The copy below
      // only runs when the fully synchronised bit is set, so the configuration
      // registers have been stable for at least two dot clocks.
      cfg_dirty_sync <= {cfg_dirty_sync[0], cfg_dirty};
      // Row 0's cache is filled a whole frame before the frame that draws it (the walker's
      // row-24 fill), but the scanout's display start commits at frame_end (vline 439), one
      // scanline before row 0 is drawn - so a change would reach row 0 a frame late. This EARLY
      // copy of the walker's own address inputs, at the last walk slot (vline 431), lets the
      // vline-432 re-walk below use the frame's display start. It is deliberately NOT a move of
      // the snapshot: the frame_end block below still writes these same registers, so the next
      // frame's scanout sees the frame_end value and the graphics/CSRFORM timing is untouched
      // A write later than vline 431 (vblank lines 432-439) is not seen by
      // this copy and leaves row 0 one frame stale - the residual records; the VSYNC-wait
      // SCROLL the machine actually issues lands at vline 407-419, well before it.
      if (wk_cfg_snap && cfg_dirty_sync[1]) begin
        if ((v_sad_lo != pram_scr[0]) || (v_sad_hi != pram_scr[1]) ||
            (v_pitch != pitch) || (v_col40 != mode1[2]))
          v_row0_stale <= 1'b1;
        v_sad_lo <= pram_scr[0];
        v_sad_hi <= pram_scr[1];
        v_pitch  <= pitch;
        v_col40  <= mode1[2];
      end
      if (frame_end && cfg_dirty_sync[1]) begin
        v_disp <= mode1[7] && gdc_start;
        v_col40 <= mode1[2];
        v_mode1_sg <= mode1[0];
        v_mode16 <= mode2_16color;
        v_pitch <= pitch;
        v_sad_lo <= pram_scr[0];
        v_sad_hi <= pram_scr[1];
        v_csrform[0] <= csr_form[0];
        v_csrform[1] <= csr_form[1];
        v_csrform[2] <= csr_form[2];
        v_csread[0] <= csr_ead[0];
        v_csread[1] <= csr_ead[1];
        v_dig_a8 <= dig_a8;
        v_dig_aa <= dig_aa;
        v_dig_ac <= dig_ac;
        v_dig_ae <= dig_ae;
        // The write epoch as of THIS edge: the ack this copy raises may only
        // clear cfg_dirty while no write has moved past it (see the clear rule).
        cfg_epoch_snap <= cfg_epoch;
        cfg_ack <= ~cfg_ack;
      end
      // The vline-432 walk trigger has read the flag by the end of that scanline.
      if ((vline == wk_slot) && (hdot == HTOTAL - 1)) v_row0_stale <= 1'b0;
    end
  end

  assign o_frame_end    = frame_end;
  assign o_cfg_snap     = frame_end && cfg_dirty_sync[1];
  // The pending level on its own, for the two raster lines the scanout's +2 fetch latches
  // BEFORE the copy above runs (see pc9821_gdc2's wrap-row mux): their decode must see the
  // value the copy will install, and this is the bit that says the copy will fire.
  assign o_cfg_pending  = cfg_dirty_sync[1];
  assign o_display_page = display_page;
  assign o_v_pitch      = v_pitch;
  assign o_v_col40      = v_col40;
  assign o_v_sad        = {v_sad_hi, v_sad_lo};
  assign o_v_row0_stale = v_row0_stale;
  assign o_vline        = vline;
  assign o_hdot         = hdot;
  assign o_htotal       = HTOTAL;
  assign o_vtotal       = VTOTAL;
  assign o_vbp          = v_sync[7][7:2];

  // ---------------------------------------------------------------
  // Text fetch pipeline
  // ---------------------------------------------------------------
  wire txt_on = h_active && v_active && v_disp;
  wire [9:0] adot = hdot;
  wire f_lo_d = v_col40 ? (adot[3:0] == 4'd11) : (adot[2:0] == 3'd3);
  wire f_hi_d = v_col40 ? (adot[3:0] == 4'd12) : (adot[2:0] == 3'd4);
  wire f_at_d = v_col40 ? (adot[3:0] == 4'd13) : (adot[2:0] == 3'd5);
  wire f_fo_d = v_col40 ? (adot[3:0] == 4'd14) : (adot[2:0] == 3'd6);
  wire cell_end = v_col40 ? (adot[3:0] == 4'd15) : (adot[2:0] == 3'd7);
  wire fetch_lo = txt_on && f_lo_d;
  wire fetch_hi = txt_on && f_hi_d;
  wire fetch_at = txt_on && f_at_d;
  wire fetch_fo = txt_on && f_fo_d;
  wire cell_done = txt_on && cell_end;

  // next-cell coordinates for the fetch (cell after the one on screen)
  wire last_cell = v_col40 ? (adot[9:4] == 6'd39) : (adot[9:3] == 7'd79);
  wire [5:0] f_c40 = last_cell ? 6'd0 : (adot[9:4] + 6'd1);
  wire [6:0] f_c80 = last_cell ? 7'd0 : (adot[9:3] + 7'd1);
  // ---- THE ROW WRAP FLAG, ONE DOT EARLY (the timing seam, part 2) ----
  // f_line's wrap select reads this register instead of comparing vline against
  // VACTIVE - 10'd1 combinationally, so the multiply below is fed from registers. f_wrap_r
  // is that compare sampled one dot early, and it is bit-identical to it at every dot that
  // CONSUMES it: f_line only consults it when last_cell (the line's last active cell - dots
  // 632..639 in 80-column, 624..639 in 40-column) and there it was sampled earlier in the
  // SAME line, where vline and VACTIVE are constant; at the dots where it lags (dot 0 of
  // every line, where vline moves) last_cell is false and f_line takes vline either way.
  // f_line is therefore bit-identical at EVERY cycle (tb_pc9821_tram_addr_equiv's
  // wordidx-consume and capture-r-raster assertions).
  reg f_wrap_r;
  always @(posedge clk_sys) begin
    if (!rst_n_sys) f_wrap_r <= 1'b0;   // vline 0 never wraps for a VACTIVE >= 2 raster
    else if (pixel_ce) f_wrap_r <= (vline == VACTIVE - 10'd1);
  end
  /* verilator lint_off UNUSEDSIGNAL */   // f_line[9] has no reader: the fetch splits it into
  // the char row [8:4] and the font raster row [3:0]. KNOWN LIMITATION
  // (NOT fixed here): VACTIVE is min(lf, VTOTAL - 1) and VTOTAL is clamped to 575 lines, so a
  // guest SYNC block can make 574 lines active - text rows 0..35, not the default block's 0..24.
  // f_row (5 bits) then TRUNCATES rows 32..35 onto rows 0..3, so a >512-line frame fetches the
  // wrong TRAM row (pc9821_cg.sv's walker row is 5 bits too). The bank rule (row==0) ? 2 :
  // row[0] still separates ADJACENT rows, so the fix is a 6-bit f_row/wk_row - it moves the TRAM
  // addressing and belongs with the geometry decision, not with this timing seam. The value
  // still has to be TEN bits: vline runs to VTOTAL-1 = 574 now.
  wire [9:0] f_line = last_cell ? (f_wrap_r ? 10'd0 : vline + 10'd1) : vline;
  /* verilator lint_on UNUSEDSIGNAL */
  // vline is a scanline: char row = vline[8:4] (400 lines: rows 0..24),
  // font raster row = vline[3:0]. The fetch pipeline runs per scanline and
  // prefetches the next cell in raster order (same char row for col<79,
  // next char row after the wrap).
  wire [4:0] f_row = f_line[8:4];
  wire [3:0] f_raster = f_line[3:0];

  // TRAM word index of fetched cell: sad + row*pitch + cell(80) / +2*cell(40). The fetch
  // address uses its LOW12 (both planes hold 4096 words); bits 15:12 are the pre-mask
  // display-start tap tb_pc9821_gdc_text reads to prove a 0x1000-word start is in effect.
  wire [15:0] f_sad = {v_sad_hi, v_sad_lo};
  // ---- THE ROW BASE, ONE DOT EARLY (the timing seam, part 3) ----
  // f_row * v_pitch registered on pixel_ce: the multiply leaves the per-fetch path (what
  // remains is one adder pair and the mux below). f_row and v_pitch only move at dots that
  // are 0 mod 8 (80-column) / 0 mod 16 (40-column): a line's first dot (vline moves on the
  // HTOTAL-1 edge), the last cell's first dot (632 / 624, where f_line switches to the next
  // line) and dot 640 (where it switches back) - and the dots that CONSUME f_wordidx are
  // never those: the fetch arms sit at dots 3/4/5 of a cell (11/12/13 in 40-column) and the
  // render captures at cell_done (dot 7 / 15). The registered product therefore equals the
  // combinational one at every consuming dot, and tram_vid_addr is bit-identical at EVERY
  // cycle: at all other dots the mux selects the walker arm or the default and f_wordidx
  // never reaches the port (tb_pc9821_tram_addr_equiv's walker-arm-priority and
  // wordidx-consume). Registering tram_vid_addr ITSELF is forbidden: the walker arm must
  // stay combinational so its address is on the port during the dot that presents it.
  reg [15:0] f_rowbase_r;
  always @(posedge clk_sys) begin
    if (!rst_n_sys) f_rowbase_r <= 16'h0000;   // row 0's base is 0 * v_pitch
    else if (pixel_ce) f_rowbase_r <= {11'd0, f_row} * {8'd0, v_pitch};
  end
  /* verilator lint_off UNUSEDSIGNAL */
  wire [15:0] f_wordidx = v_col40
	? (f_rowbase_r + {9'd0, f_c40, 1'b0} + f_sad)
	: (f_rowbase_r + {9'd0, f_c80}        + f_sad);
  /* verilator lint_on UNUSEDSIGNAL */

  // TRAM scanout address mux (1-cycle reads). Code bytes of word w are at TRAM byte
  // addresses 2w (lo) and 2w+1 (hi); the attribute byte is 0x2000 + 2w =
  // {1'b1, w[11:0], 1'b0} (verified: kasumi crt_fill pokebs every 2 bytes at +0x2000).
  // Both planes hold 4096 words, so BOTH word indices are 12 bits: the code plane is
  // the TRAM's low 8 KiB and NP2kai masks the same word index LOW12 for both
  // (vram/maketext.c:315 the cell loop, :321 the per-line pitch, :247 0xa0000 + w*2 and
  // :279 0xa2000 + w*2). Keeping 13 bits on the code arm reads the ATTRIBUTE plane as
  // the code for any word at or above 0x1000, which a display start above ~2100 words
  // or a pitch above ~168 reaches (tb_pc9821_gdc_text's display-start case).
  // The walker borrows this port on dot 0 (wk_tr_read, a port pc9821_cg drives); the
  // scanout drives it on its own fetch dots, so the two never collide (the walker captures
  // at dot 1, the scanout at dots 4/5/6). The walker's address is COMBINATIONAL from its
  // state so it is on the port DURING dot 0 - a registered one would arrive a dot late and
  // read the scanout's default.
  assign tram_vid_addr =
	  wk_tr_read ? wk_tr_addr
	: fetch_lo ?  {1'b0, f_wordidx[11:0], 1'b0}
	: fetch_hi ?  {1'b0, f_wordidx[11:0], 1'b1}
	: fetch_at ?  {1'b1, f_wordidx[11:0], 1'b0}
	: 14'h0000;

  // fetch latches (data available one cycle after the address is set)
  reg [7:0] code_lo_r, code_hi_r, attr_r;
  reg r_valid;

  // Font address: presented combinationally during fetch_fo, like the TRAM addresses.
  // The read port is enabled only on pixel_ce, so the word for the dot that presented this
  // address is on ank_word at the cell_done edge; the byte select is registered with the
  // address because the address returns to 0 on the following dot while the gated read is
  // still in flight.
  // A cell whose code low byte is 0x56/0x57 is a user-CG (gaiji) code: its glyph comes
  // from the writable cg_ram, not the ANK table, and the two halves of the 16-dot glyph
  // are the two cells of the pair. 0xA5 bit 5 has nothing to do with the scanout - QEMU
  // pc98-vga.c:4315-4320 and NP2kai vram/maketext.c:283-294 toggle a positional half and
  // clear it for any non-gaiji code - so the first cell takes +0 (left) and the second
  // +0x800 (right). The ver0.78 rows 0x09-0x0B draw their half-width glyph from the
  // row cache (below); none of the row-cache classes read cg_ram.
  wire        f_two_byte = |code_hi_r;
  wire        f_gaiji    = f_two_byte &&
                           (((code_lo_r & 8'h7F) == 8'h56) ||
                            ((code_lo_r & 8'h7F) == 8'h57));
  // The render's ver0.78 test is the MASKED low byte, exactly maketext.c:281 (`kc &= 0x7f`).
  wire        f_ver078   = (code_lo_r[6:0] >= 7'h09) && (code_lo_r[6:0] < 7'h0c);
  // The row-cache classes (NP2kai maketext.c:278-296): every two-byte non-gaiji cell
  // draws from the block at (kc & 0x7f7f) << 4. The kanji pair consumes two cells (below);
  // the ver0.78 rows draw the slot's LEFT half ALONE in one cell (`kanji2nd` stays clear
  // for kc 0x09-0x0B, maketext.c:292-294) - the half-width glyphs of the NEC extension
  // rows, which this module drew as NOTHING.
  wire        f_jis      = f_two_byte && !f_gaiji && !f_ver078;   // the PAIR-consuming class
  wire        f_jis_any  = f_two_byte && !f_gaiji;   // ...plus the ver0.78 singles
  // The gaiji half is POSITIONAL, not code bit 7: on the Xe10, KTDEMO's lone [0xD6,'A'] then
  // [0x56,'B'][0xD6,'B'] draws A-left, B-right, B-left (docs/probes/KTDEMO-XE10.jpg).
  reg         f_half;      // positional half of the gaiji cell being fetched
  reg         f_jis2nd;    // the cell being fetched is the RIGHT half of a kanji pair
  reg         f_jis_ok;    // the pair's glyph is inside the stored grid

  // ---- the JIS kanji pair ----
  /* verilator lint_off WIDTHEXPAND */   // the glyph address arithmetic is value-bounded
  // ku = the JIS ROW, carried in the code's LOW byte; ten = the column, in the HIGH byte. The
  // walker inside pc9821_cg owns the glyph ADDRESS (the font is in SDRAM now); the scanout only
  // needs to know whether the fetched cell is a JIS glyph inside the grid, so that the row cache
  // and the ANK store can be told apart.
  wire [7:0]  f_ku_i  = {1'b0, code_lo_r[6:0]} - 8'h01;   // ku - 0x21
  wire        f_row_in = (f_ku_i < 92);   // JIS_ROWS
  // The right half reuses the pair's own row and column and IGNORES its own TRAM code, which
  // is what NP2kai's kanji2nd arm does (bitmap[x] = lastbitp + 0x800). The carried right-half
  // flag must NOT survive the line wrap: last_cell's fetch is the NEXT line's column 0, and
  // both references reset the pair per line (NP2kai maketext.c declares kanji2nd inside the
  // line loop, QEMU pc98-vga.c likewise), so the flag the ADDRESS uses is AND NOT last_cell.
  // Without it, a kanji code in a line's last cell made the next line's column 0 draw that
  // glyph's RIGHT half - the wrong glyph, at a cell the machine draws as a fresh character.
  wire        f_pair2nd = f_jis2nd && !last_cell;
  // The gaiji twin of the mask above: last_cell's fetch is the next
  // line's column 0 and NP2kai resets gaiji1st per line (maketext.c:238,
  // declared inside the line loop), so a carried positional half must not
  // survive the line wrap either - the wrap cell is a fresh LEFT half and its
  // own right half is the next column.
  wire        f_half_here = f_half && !last_cell;
  wire        f_jis_here = f_pair2nd ? f_jis_ok : (f_row_in && f_jis_any);
  // f_jis2nd ADVANCES on fetch_fo, so f_jis_here must be sampled in that same cycle: read at
  // cell_done it would describe the next cell instead of this one. f_pair2nd_r takes the same
  // two-stage path so r_jis_2nd describes the same cell r_font does.
  reg         f_jis_here_r;
  reg         f_pair2nd_r;

  // THE ANK arm reads the code's own row out of the ANK store; a JIS cell reads the row
  // cache instead. `ank_rd_addr` is therefore only ever the ANK word.
  assign ank_rd_addr = fetch_fo ? {code_lo_r, f_raster[3:1]} : {11{1'b0}};
  /* verilator lint_on WIDTHEXPAND */

  // The pair state advances once per fetched cell and describes the cell being fetched, so
  // the flag it leaves is for the cell AFTER that one. last_cell's fetch is the next line's
  // column 0: with f_pair2nd zero there, that cell is evaluated as a fresh left cell, and the
  // cell after it becomes its right half - so a pair neither spans a line nor is dropped at
  // one.
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      f_jis2nd <= 1'b0; f_jis_ok <= 1'b0;
      f_jis_here_r <= 1'b0;
      f_pair2nd_r  <= 1'b0;
    end else if (pixel_ce && fetch_fo) begin
      f_jis_here_r <= f_jis_here;
      f_pair2nd_r  <= f_pair2nd;   // both describe the cell addressed at THIS dot
      if (f_jis && f_row_in && !f_pair2nd) begin
        f_jis2nd <= 1'b1;        // this cell is a left half; the next is its right half
        f_jis_ok  <= 1'b1;
      end else begin
        f_jis2nd <= 1'b0;
        f_jis_ok  <= 1'b0;
      end
    end
  end

  // The JIS row cache's read coordinates, packed inside pc9821_cg. Three banks: row 0 takes
  // bank 2 and every other row its parity (bank = (row == 0) ? 2 : row[0]), so the walker's
  // NEXT row and the scanout's current row are never the same bank.
  assign jc_rd_bank = (f_row == 5'd0) ? 2'd2 : {1'b0, f_row[0]};
  assign jc_rd_cell = v_col40 ? {1'b0, f_c40} : f_c80;
  assign jc_rd_word = f_raster[3:2];

  // The byte for the fetched cell: the ANK store's word and the row cache's dword are both
  // on their outputs at cell_end, and the registered class and raster select between them.
  // The cache holds 4 bytes per dword (raster rows 4k..4k+3), so the ANK byte index is
  // raster[1:0] within the dword.
  reg [1:0] font_byte_sel_r;
  reg       font_jis_cls_r;
  reg       font_lsb_r;
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      font_lsb_r <= 1'b0; font_byte_sel_r <= 2'd0; font_jis_cls_r <= 1'b0;
    end else if (pixel_ce && fetch_fo) begin
      font_lsb_r      <= f_raster[0];
      font_byte_sel_r <= f_raster[1:0];
      font_jis_cls_r  <= f_jis_here;
    end
  end
  wire [7:0] jis_vid_byte = jc_rd_q[{font_byte_sel_r, 3'b000} +: 8];
  wire [7:0] ank_vid_byte = font_lsb_r ? ank_word[15:8] : ank_word[7:0];
  wire [7:0] font_vid_q   = font_jis_cls_r ? jis_vid_byte : ank_vid_byte;
  // SIMPLE GRAPHICS: with MODE FF1 bit 0 set, an ANK cell whose attribute has bit 4
  // (TXTATR_BG) draws its CODE as a 2x4 block pattern instead of the ANK glyph (NP2kai
  // maketext.c's ANK arm, `if ((curx[x] & TXTATR_BG) && (gdc.mode1 & 1)) bitmap[x] += 0x1000`:
  // the 8x16 character-graph bank). font/font.c:39 font_setchargraph builds that bank: glyph
  // row r is 0xF0 when code bit r >> 2 is set, OR 0x0F when code bit 4 + (r >> 2) is set, and
  // code 0xF2's first two rows are cleared (the NEC patch). So it is generated here from the
  // code and the row - no ROM. The kanji pair's right cell is not an ANK cell (maketext.c
  // takes its kanji2nd branch first), and the two-byte codes' own SG arm (`bitmap += 8`, the
  // cell doubled) is not modelled.
  wire [1:0] f_sg_q    = f_raster[3:2];
  wire [7:0] f_sg_byte = ((code_lo_r == 8'hF2) && (f_raster[3:1] == 3'd0)) ? 8'h00 :
                         {{4{code_lo_r[{1'b0, f_sg_q}]}}, {4{code_lo_r[{1'b1, f_sg_q}]}}};
  wire       f_sg      = v_mode1_sg && attr_r[4] && (code_hi_r == 8'h00) && !f_pair2nd_r;

  // gaiji store scanout port: the same 13-bit index as the CPU write port, with the
  // code-register fields replaced by the fetched cell and the positional half.
  // Registered on pixel_ce, so the byte for the address presented on fetch_fo is on
  // cg_ram_vid_q at the cell_done edge exactly like ank_word.
  assign cg_ram_vid_addr = {code_hi_r[6:0], code_lo_r[0], f_half_here, f_raster};

  // render registers (latched at cell_end, stable during next cell)
  /* verilator lint_off UNUSEDSIGNAL */  // bits 15:12 are the display-start tap above; the cursor compare masks to 12 bits
  reg [15:0] r_wordidx;
  /* verilator lint_on UNUSEDSIGNAL */
  reg [ 3:0] r_raster;
  reg [ 7:0] r_code_hi;
  reg [ 7:0] r_code_lo;
  /* verilator lint_off UNUSEDSIGNAL */  // only r_attr[7:5] are the colour index (colour_idx)
  reg [ 7:0] r_attr;
  /* verilator lint_on UNUSEDSIGNAL */
  reg [ 7:0] r_font;
  reg        r_jis_ok;     // the rendered cell is a JIS kanji whose glyph is in the store
  reg        r_jis_2nd;    // the rendered cell is a kanji pair's RIGHT half
  reg        r_gaiji_2nd;  // ...or a same-code gaiji pair's RIGHT half
  // The previous fetched cell's class and code: the pair-coherence test for
  // r_gaiji_2nd below (NP2kai maketext.c:274-277 propagates the cursor across a
  // gaiji pair only when the two cells carry the same code).
  reg        p_gaiji;
  reg [7:0]  p_code_lo;
  reg [7:0]  p_code_hi;

  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      r_valid <= 1'b0;
      code_lo_r <= 8'h00;
      code_hi_r <= 8'h00;
      attr_r    <= 8'h00;
      r_wordidx <= 16'h0;
      r_raster <= 4'd0;
      r_code_hi <= 8'h00;
      r_code_lo <= 8'h00;
      r_attr   <= 8'h00;
      r_font <= 8'h00;
      r_jis_ok <= 1'b0;
      r_jis_2nd <= 1'b0;
      r_gaiji_2nd <= 1'b0;
      p_gaiji <= 1'b0;
      p_code_lo <= 8'h00;
      p_code_hi <= 8'h00;
      f_half <= 1'b0;
    end else if (pixel_ce) begin
      // The read port is enabled only on pixel_ce, so the byte for the dot that
      // presented the address is on tram_vid_q one dot later. The condition therefore
      // names the FOLLOWING dot: fetch_hi carries mem[{w,0}], fetch_at mem[{w,1}], and
      // fetch_fo the attribute at 0x2000+2w.
      if (fetch_hi) code_lo_r <= tram_vid_q;  // dot 3's addr -> code low
      if (fetch_at) code_hi_r <= tram_vid_q;  // dot 4's addr -> code high
      if (fetch_fo) attr_r    <= tram_vid_q;  // dot 5's addr -> attribute
      if (cell_done) begin
        // dot 6's addr -> glyph row, from whichever store the gate selected
        r_font    <= f_gaiji ? cg_ram_vid_q : f_sg ? f_sg_byte : font_vid_q;
        r_jis_ok  <= f_jis_here_r;
        r_jis_2nd <= f_pair2nd_r;
        // F5: the rendered cell is the right half of a gaiji pair with the SAME
        // code as the left half (the previous fetched cell, p_*). NP2kai marks
        // the left cell of any 16-dot pair for cursor propagation - kanji
        // (maketext.c:258) and gaiji with matching code (maketext.c:274-277) -
        // and csr_pair below extends the cursor on that mark.
        r_gaiji_2nd <= f_gaiji && f_half_here && p_gaiji &&
                       ((code_lo_r & 8'h7F) == (p_code_lo & 8'h7F)) &&
                       ((code_hi_r & 8'h7F) == (p_code_hi & 8'h7F));
        p_gaiji   <= f_gaiji;
        p_code_lo <= code_lo_r;
        p_code_hi <= code_hi_r;
        r_wordidx <= f_wordidx;
        r_raster  <= f_raster;
        r_code_hi <= code_hi_r;
        r_code_lo <= code_lo_r;
        r_attr    <= attr_r;
        r_valid   <= 1'b1;
        // Positional half for the NEXT gaiji cell; every other cell clears it,
        // which is the reference's `gaiji1st = 0` on a non-gaiji code. The
        // cleared value is f_half_here (F4): a wrap cell is a fresh left half.
        f_half    <= f_gaiji & ~f_half_here;
      end
    end
  end

  // ---------------------------------------------------------------
  // Pixel generation (combinational from latched render regs)
  // ---------------------------------------------------------------
  wire       render_on = r_valid && txt_on;
  wire [2:0] px80 = adot[2:0];  // 80-col pixel 0..7
  wire [2:0] px40 = adot[3:1];  // 40-col glyph bit 0..7
  wire       glyph_bit = v_col40 ? r_font[~px40] : r_font[~px80];
  // One-byte codes draw an ANK glyph; codes whose LOW byte is 0x56/0x57 draw
  // from the user-CG array (the same gate the 0xA9 write path uses); the two-byte
  // row-cache classes - the JIS kanji pair and the ver0.78 half-width rows - draw
  // from the row cache as r_jis_ok records.
  wire       ank_ok   = (r_code_hi == 8'h00);
  wire       gaiji_ok = (|r_code_hi) &&
                        (((r_code_lo & 8'h7F) == 8'h56) ||
                         ((r_code_lo & 8'h7F) == 8'h57));
  // The row-cache cells draw from the cache exactly as the ANK do; r_jis_ok is false for
  // a row the grid does not hold (ku above 0x7C), which keeps those cells blank rather
  // than showing a wrapped address's glyph. It covers the kanji left cells, the ver0.78
  // half-width rows (maketext.c:280-296), and the pair's right cell, whose
  // own code is ignored (maketext.c:254 `if (kanji2nd)` comes first). That right cell
  // carries no code of its own on the machine (the ITF's TEXTDISP.X86 leaves it at the
  // cleared 0x0020, and NP2kai/QEMU ignore it), so it usually arrives here as the ANK
  // class with r_font already holding the JIS half - the ANK arm above is what draws it.
  wire       jis_ok   = (|r_code_hi) && !gaiji_ok && r_jis_ok;
  wire       glyph_on = (ank_ok || gaiji_ok || jis_ok) && glyph_bit;

  // Attribute decode (ReactOS sdk/.../pc98/video.h, ReC98, QEMU ATTR_COL):
  //   bit0 visible  bit1 blink  bit2 reverse  bit3 underline  bit4 vertical line
  //   colour 0xE0 = {G=0x80, R=0x40, B=0x20}; index {G,R,B} == attr[7:5] selects the
  //   standard 8-colour table (0 black .. 7 white).
  wire [2:0] colour_idx = r_attr[7:5];
  wire       reverse = r_attr[2];
  wire       blink = r_attr[1];
  wire       underline = r_attr[3];
  wire       vl_attr = r_attr[4];

  // ---- THE BLINK DIVIDER: ONE COUNT FOR THE CHARACTER BLINK AND THE CURSOR ----
  // NP2kai advances ONE count for both blink consumers, once per `timing` drawscreen() calls
  // (i.e. frames):
  //   timing = ((LOADINTELWORD(para + GDC_CSRFORM + 1)) >> 5) & 0x3e;
  //   if (!timing) timing = 0x40;                            (pccore.c:1476-1479)
  // `>> 5 & 0x3e` is exactly the FIVE-bit CSRFORM field {csr_form[2][2:0], csr_form[1][7:6]}
  // DOUBLED, with a zero field meaning 64 (pccore.c:1481-1484). The two consumers of that one
  // count are `blinkdisp = (count & 3) ? 1 : 0`, which blanks a blinkable cell's glyph on the
  // one count in four whose low bits are zero (vram/maketext.c:117, applied at :308-312), and
  // the cursor's `curdisp = count & 1` (vram/maketext.c:92). Reading csr_form[1][7:6] alone is
  // the field's LOW two bits: it reports 64 frames where the machine's boot CSRFORM makes it
  // 24. The power-on CSRFORM (csr_form[1] = 0xC0, csr_form[2] = 0x7B; NP2kai io/gdc.c:1084)
  // makes the field 15, so cur_timing is 30: a count every 30 frames, a 30-frame dark phase
  // and a 120-frame blink (0.53 s dark / 1.6 s lit) at the machine's 56.42 Hz raster.
  wire [4:0] csr_blink_field = {v_csrform[2][2:0], v_csrform[1][7:6]};
  wire [6:0] cur_timing = |csr_blink_field ? {1'b0, csr_blink_field, 1'b0} : 7'd64;
  reg  [6:0] cur_div;
  // cur_phase is that count's parity, the cursor VISIBLE while it is 0 (the power-on phase the
  // old frame_cnt[5] gate used).
  reg        cur_phase;
  // The CHARACTER BLINK's count is frame_cnt[5:4] (the duty test below), so this register is
  // stepped by 16: bits [5:4] run 0,1,2,3 and wrap, which IS NP2kai's `count & 3`. Advancing it
  // once per cur_timing frames is what the old every-frame step was missing - it blinked 16 of
  // every 64 frames regardless of the CSRFORM field.
  reg  [5:0] frame_cnt;
  always @(posedge clk_sys)
    if (!rst_n_sys) begin
      cur_div   <= 7'd0;
      cur_phase <= 1'b0;
      frame_cnt <= 6'd0;
    end else if (pixel_ce && frame_end) begin
      if (cur_div + 7'd1 >= cur_timing) begin
        cur_div   <= 7'd0;
        cur_phase <= ~cur_phase;
        frame_cnt <= frame_cnt + 6'd16;
      end else cur_div <= cur_div + 7'd1;
    end
  // The blink blanks the glyph on ONE count in four (NP2kai vram/maketext.c:117), so a
  // blinkable cell is visible 3/4 of the blink cycle.
  wire blink_off = blink && (frame_cnt[5:4] == 2'b00);

  // cursor (verified decode: cs[0]&0x80 enable, cs[1]&0x20 non-blink,
  // top=cs[1]&0x1f, bottom=cs[2]>>3; address in display words)
  // cs[1] bit 5 SET is what both references call NON-BLINK: NP2kai forces
  // `curdisp = 1` on it (vram/maketext.c:99-101), QEMU ORs it into the visible
  // condition (pc98-vga.c:1353). With it clear the cursor toggles on the blink
  // phase (cur_phase). csr_blink=1 therefore means "the cursor is visible now".
  wire csr_enable = v_csrform[0][7];
  wire csr_blink = v_csrform[1][5] || !cur_phase;
  wire [4:0] csr_top = v_csrform[1][4:0];
  wire [4:0] csr_bot = v_csrform[2][7:3];
  wire [15:0] csr_word = {v_csread[1], v_csread[0]};
  wire        csr_row_ok = ({2'b0, r_raster} >= {1'b0, csr_top}) &&
                           ({2'b0, r_raster} <= {1'b0, csr_bot});
  // The compare uses the 12-bit TRAM word index, not the 16-bit register: NP2kai's edi is
  // LOW12, so a CSRW at or above 0x1000 can never match a cell (vram/maketext.c:244).
  wire        csr_own  = csr_enable && csr_blink &&
                         ({4'b0, r_wordidx[11:0]} == csr_word) && csr_row_ok;
  // NP2kai propagates the cursor to the pair's right cell: the left cell flags 0x80 and
  // maketext then sets bit 8 on cell+1 (vram/maketext.c:337). That mark is on the left cell
  // of ANY 16-dot pair - kanji (maketext.c:258) and gaiji with matching code
  // (maketext.c:274-277) - so both r_jis_2nd and r_gaiji_2nd count.
  wire [11:0] csr_prev = r_wordidx[11:0] - (v_col40 ? 12'd2 : 12'd1);
  wire        csr_pair = csr_enable && csr_blink && (r_jis_2nd || r_gaiji_2nd) &&
                         ({4'b0, csr_prev} == csr_word) && csr_row_ok;
  wire        csr_here = csr_own || csr_pair;

  wire ul_on = underline && (r_raster == 4'd15);
  // The underline and the bit-4 vertical line are LINE OVERLAYS: NP2kai accumulates them
  // in line_effect and paints them after the visible test has cleared bitmap
  // (vram/maketext.c:306 vs :375/:395), so neither is gated on attribute bit 0. The vertical
  // line sits at the glyph's pattern bit 3 - pixel 4 of the 8-dot cell - which is the column
  // BOTH references select: NP2kai ORs into byte 4 of the cell (vram/maketext.c:395,
  // maketext40 q+4/q+12) and QEMU ORs 0x08 into the pattern, whose bit 3 lights dest[4]
  // (pc98-vga.c:4349). It runs while mode1 bit 0 (simplified-graph) is clear. The dot is
  // chosen by px80 for both column modes on purpose: in 40-col px80 steps 0..7 twice, so the
  // line lands at dots 4 and 12, exactly NP2kai's maketext40 pair.
  wire vl_on = vl_attr && !v_mode1_sg && (px80 == 3'd4);
  // The cell's video is the glyph DATA first, and both TXTATR_ST (bit 0) and the
  // character blink-off phase blank the DATA itself - maketext.c:325-331 zeroes
  // `bitmap[x]` outside TXTATR_ST and on a blinkable cell's off phase. Reverse
  // and the cursor then TOGGLE the cell video (maketext.c:336-337 sets
  // `color[cur_line] |= 256` regardless of TXTATR_ST and blinkdisp, and
  // text_table[256+m] = text_table[m ^ 0x80] is a reverse toggle), so the cursor
  // is a solid inverted block on an invisible or blink-blanked cell (blank
  // inverted = solid) and stays visible through the blink phases.
  // The line overlays run outside all of it.
  wire glyph_data = glyph_on && r_attr[0] && !blink_off;
  wire pix_on = (glyph_data ^ reverse ^ csr_here) || ul_on || vl_on;

  // Text colour is NOT the graphics palette. Both references give the text plane a fixed
  // 8-entry table built from the three attribute colour bits and use it in every palette
  // mode (QEMU pc98-vga.c:4214-4218, used at :4597/:4611/:4624; NP2kai pal_makeskiptable,
  // vram/palettes.c:93-108, installed by pal_maketext). 0xA8/AA/AC/AE and the digital bytes
  // drive the GRAPHICS palette only. colour_idx is {G = bit2, R = bit1, B = bit0}.
  wire [11:0] colour = {colour_idx[1] ? 4'hF : 4'h0,
                        colour_idx[2] ? 4'hF : 4'h0,
                        colour_idx[0] ? 4'hF : 4'h0};

  // The text plane leaves this module as a COLOUR and two OPACITY flags, never
  // as a black-filled RGB. pc9821_video_mixer composes them with the graphics
  // plane and drives the framework's r/g/b. blink_off's blanking is folded into
  // glyph_data above (F3), so the overlays and the cursor are not blanked by it.
  assign text_colour = colour;
  assign text_opaque = render_on && pix_on;
  // The cell-opaque arm of the compositor rule: the whole cell is opaque when its
  // attribute bit 0 (visible) is set, whatever the glyph is doing. Blink is not applied
  // here because this arm is about the CELL; it is an unmeasured alternative, so it keeps
  // its own meaning rather than borrowing the glyph rule's.
  assign text_cell   = render_on && r_attr[0];

  // MODE FF1 bit 4 splits the 200-line display into the graphics/text INTERLEAVE:
  // graphics are fetched and displayed on EVEN display lines only and ODD lines carry
  // text over black. NP2kai fetches a display line only
  // `if ((!(mg.liney & 1)) || (!(gdc.mode1 & 0x10)))` (vram/makegrph.c:155) and its
  // p_2i draw paints the odd line of each pair as `(q[x] >> 4) + NP2PAL_TEXT` with the
  // graphics plane absent (vram/sdraw.mcr:199-243; the interleave row is selected by
  // `sdrawfn += 4` on `gdc.mode1 & 0x10`, vram/scrndraw.c:227). The GDC line REPEAT is
  // unchanged by this: with lr = 2 the same GDC line is still PRESENTED on both raster
  // lines of a pair (makegrph.c:176-180 advances vad every lr display lines whatever the
  // fetch skip does), but the odd raster line shows no graphics.
  //
  // The flag is latched at the frame boundary like the slave CSRFORM line repeat
  // (pc9821_gdc2's v_lr2): a single field with no multi-register coherence to preserve.
  // The power-on value is MODE FF1's own (8'h98 = FONTSEL|200LINE|DISP, verified).
  reg v_mode1_200;
  always @(posedge clk_sys) begin
    if (!rst_n_sys) v_mode1_200 <= 1'b1;
    else if (pixel_ce && frame_end) v_mode1_200 <= mode1[4];
  end

  // Pixel-timing view and the graphics palette snapshot for pc9821_video_mixer.
  assign pix_dot      = adot;
  assign pix_h_active = h_active;
  assign pix_v_active = v_active;
  // The odd interleave line. ONE wire, TWO sample points, and the +2 scanout pipeline
  // makes them want DIFFERENT parities whenever the frame wrap flips one: the line tick
  // (the last dot of raster line L) FEEDS display line (L + 2) mod VTOTAL
  // (tb_pc9821_video_frame pins the pipeline depth, pc9821_gdc2's v_oline the wrap),
  // while the pixels showing at raster line L ARE display line L. +2 preserves parity
  // only while it does not wrap: the two end-of-frame ticks subtract VTOTAL, which for
  // an ODD VTOTAL (any odd y = lf + vs + vfp + vbp the SYNC block admits inside the
  // 24 kHz clamp - 441 is the 440-line default plus one back-porch line) FLIPS it: the
  // tick on line VTOTAL-2 feeds display line 0 and the tick on line VTOTAL-1 feeds
  // line 1. So each sample point reads the parity of the display line IT is about -
  // NP2kai keys both the fetch skip and the odd-line draw on mg.liney, the display line
  // (vram/makegrph.c:155; vram/sdraw.mcr:199-243 p_2i) - and the tick's value is muxed
  // in on the last dot alone, outside the active window pc9821_video_mixer reads in.
  // Keyed on vline[0] at the tick instead, the gate skips display line 0's fetch at the
  // top of every odd-VTOTAL frame and wastes the fetch of hidden line 1
  // (tb_pc9821_interleave_odd_vtotal). One caveat kept: pc9821_gvram_scan's DISP-rise
  // re-arm also samples this wire mid-line, where it still reads vline[0]; that recovery
  // path is unchanged and mis-keys only if a DISP rise lands on one of the two wrap
  // rasters of an odd-VTOTAL frame.
  // The wrap subtracts VTOTAL from (vline + 2), which flips the sum's parity exactly
  // when VTOTAL is odd - the whole flip in one bit.
  wire feed_odd = vline[0] ^ ((vline + 10'd2 >= VTOTAL) && VTOTAL[0]);
  wire at_line_tick = (hdot == HTOTAL - 10'd1);
  assign gfx_odd_line = v_mode1_200 && (at_line_tick ? feed_odd : vline[0]);
  assign gfx_mode16   = v_mode16;
  assign gfx_dig      = {v_dig_a8, v_dig_aa, v_dig_ac, v_dig_ae};
  // The analogue table's CPU write port, and its read mirror (see the declarations).
  // 256-colour writes go to the PEGC mirror below instead (NP2kai checks GDCANALOG_256
  // first in gdc_oaa/oac/oae); the 16-colour DAC port and its masked index are
  // unchanged, so the capture-pinned 16-colour path cannot move.
  assign pal_wr_en   = io_wr && mode2_16color && !mode2_256col &&
                       (pc == 5'd22 || pc == 5'd23 || pc == 5'd24);
  // The DISPLAYED entry takes palnum & 15 (NP2kai gdc_setanalogpal(gdc.palnum & 15),
  // io/gdc.c:862) while the mirror write below keeps the full index.
  assign pal_wr_idx  = pal_sel[3:0];
  assign pal_wr_chan = (pc == 5'd22) ? 2'd0 : (pc == 5'd23) ? 2'd1 : 2'd2;
  assign pal_wr_data = io_din[3:0];
  assign pal_commit  = frame_end;
  assign gfx_pegc_256  = mode2_256col;
  assign gfx_pegc_256e = mode2_256e;
  // THE PEGC 256-COLOUR READ MIRROR (row 5). Three 256x8 M10K byte lanes, the
  // shape measured free at both depths (pm256_lanes: 2 ALMs + 3 M10K at 16
  // entries and at 256 alike - the register form this replaces is 4,258 ALMs /
  // 6,144 flops). It is NP2kai's anareg[16*3 +
  // palnum*4 + c]: the unmasked 8-bit index and the FULL written byte, read back
  // verbatim (gdc_iaa/iac/iae, io/gdc.c:922-954). THE READ-BACK DIVERGENCE,
  // recorded not guessed: MAME returns 0 for these ports in 256-colour mode
  // (pc9821_a0_r's `256 color mode [xx] R` arm); the hierarchy default is NP2kai
  // and the machine has not been measured on this row (capture-pending).
  assign pal256_wr_en   = io_wr && mode2_256col &&
                          (pc == 5'd22 || pc == 5'd23 || pc == 5'd24);
  assign pal256_wr_idx  = pal_sel;                 // the UNMASKED 0xA8 byte
  assign pal256_wr_chan = (pc == 5'd22) ? 2'd0 : (pc == 5'd23) ? 2'd1 : 2'd2;
  assign pal256_wr_data = io_din;                  // the FULL byte

  (* ramstyle = "M10K" *) reg [7:0] pal256_g [0:255];
  (* ramstyle = "M10K" *) reg [7:0] pal256_r [0:255];
  (* ramstyle = "M10K" *) reg [7:0] pal256_b [0:255];
  reg [7:0] pal256_g_q, pal256_r_q, pal256_b_q;
  wire [23:0] pal256_rd_q = {pal256_b_q, pal256_r_q, pal256_g_q};
  integer pal256_i;
  initial begin
    // Zero-seeded (NP2kai's gdc_reset zeroes anareg) so a 4-state sim never
    // answers X; the READ REGISTERS seed ALL-ZERO for the same reason the 16
    // lanes' do (a non-default power-up on a memory's output register makes
    // Quartus refuse the inference).
    for (pal256_i = 0; pal256_i < 256; pal256_i = pal256_i + 1) begin
      pal256_g[pal256_i] = 8'h00;
      pal256_r[pal256_i] = 8'h00;
      pal256_b[pal256_i] = 8'h00;
    end
    pal256_g_q = 8'h00;
    pal256_r_q = 8'h00;
    pal256_b_q = 8'h00;
  end
  always @(posedge clk_sys) begin
    // One WHOLE byte into the lane its channel names (the write-enable-per-lane
    // shape that infers), at the unmasked 8-bit index.
    if (pal256_wr_en && pal256_wr_chan == 2'd0) pal256_g[pal_sel] <= io_din;
    if (pal256_wr_en && pal256_wr_chan == 2'd1) pal256_r[pal_sel] <= io_din;
    if (pal256_wr_en && pal256_wr_chan == 2'd2) pal256_b[pal_sel] <= io_din;
  end
  // The lane read port: one clk_sys, the same shape as the 16-entry mirror's.
  always @(posedge clk_sys) begin
    pal256_g_q <= pal256_g[pal_sel];
    pal256_r_q <= pal256_r[pal_sel];
    pal256_b_q <= pal256_b[pal_sel];
  end
  // POWER-UP DETERMINISM FOR THE READ MIRROR. The three lane RAMs are
  // written only by guest I/O, so with no seed a 4-state simulation answers X on the
  // 0xAA/0xAC/0xAE reads forever. The seed is the same NEC 16-colour
  // power-on table (itf.rom 0x042F, {R,G,B}) that pc9821_gfx_palette's `pal_power_on` starts
  // its live table with, so a CPU read answers what the screen shows before the first guest
  // write. The table is written down in both files because the mirror and the displayed table
  // are separate memories on opposite sides of the frame-coherent copy. The three read
  // registers are seeded ALL-ZERO for the reason its own comment gives.
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
  integer pal_i;
  reg [11:0] po;
  // The read mirror is 16 entries: the Xe10's own 16-colour analogue palette indexed
  // by palnum & 15 (the DAC and pc9821_gfx_palette take the same masked index). The
  // unmasked 256-entry anareg[palnum*3+c] mirror NP2kai models (io/gdc.c:860/:928) is
  // the PEGC's 256-colour palette, out of scope here (reverted for area).
  initial begin
    for (pal_i = 0; pal_i < 16; pal_i = pal_i + 1) begin
      po = pal_power_on(pal_i[3:0]);
      // One FULL BYTE per lane (green, red, blue), zero-extending the RGB444 power-on
      // value exactly as the single 24-bit array's implicit assignment always did
      // (deliberate no-behaviour-change lint fix); the seed's purpose is only that the
      // read-back is never X. {12'h0, po} was byte [7:0] = po[7:0],
      // byte [15:8] = {4'h0, po[11:8]}, byte [23:16] = 8'h00, split here byte for byte.
      pal_g[pal_i] = po[7:0];
      // `po` is 12 bits wide, so po[15:8] is illegal (Quartus 10232, Verilator
      // SELRANGE); the extended word's red byte is 4'h0 + po[11:8].
      pal_r[pal_i] = {4'h0, po[11:8]};
      pal_b[pal_i] = 8'h00;
    end
    // ALL-ZERO, deliberately: a block RAM's output register powers up to zero anyway, and
    // a NON-DEFAULT power-up value on the register that captures a memory read is what
    // makes Quartus refuse to infer the memory at all (measured: `8'hFF`
    // blocks inference, `8'h00` does not).
    pal_g_q = 8'h00;
    pal_r_q = 8'h00;
    pal_b_q = 8'h00;
  end
  always @(posedge clk_sys) begin
    // The 16-colour write: one WHOLE byte into the lane its channel names, at
    // palnum & 15 (the DAC and the mirror share the masked index; PEGC is out of scope).
    // A lane write is only enabled by its own channel, which is the whole-byte shape
    // that infers; a byte-granular write into a 24-bit word does not.
    if (pal_wr_en && pal_wr_chan == 2'd0) pal_g[pal_sel[3:0]] <= io_din;   // 0xAA green
    if (pal_wr_en && pal_wr_chan == 2'd1) pal_r[pal_sel[3:0]] <= io_din;   // 0xAC red
    if (pal_wr_en && pal_wr_chan == 2'd2) pal_b[pal_sel[3:0]] <= io_din;   // 0xAE blue
  end
  // The lane read port: one clk_sys, the same latency the single array's registered read
  // had, so nothing on the readback path moves.
  always @(posedge clk_sys) begin
    pal_g_q <= pal_g[pal_sel[3:0]];
    pal_r_q <= pal_r[pal_sel[3:0]];
    pal_b_q <= pal_b[pal_sel[3:0]];
  end

  assign dbg_sad   = {v_sad_hi, v_sad_lo};
  assign dbg_pitch = v_pitch;
  assign dbg_col40 = v_col40;
  assign dbg_disp  = v_disp;

  assign hs_out = ~in_hsync;
  assign vs_out = ~in_vsync;
  assign de_out = h_active && v_active;
  // Export the SYNCHRONISED vsync: its consumers (the PIC's rising-edge detector for IRQ2
  // and the 0xA0 status bit) live in clk_sys, and a signal crossing into an edge detector can
  // metastablise into a spurious or missed IRQ2 (sec.3).
  assign vsync_active = vs_sync_ff[1];
  // The frame boundary the vblank IRQ rises on: the same edge-versus-level detector
  // vsync_irq uses, exported so a capture can time the guest's drawing pass from the edge it wakes
  // on rather than from a frame counter. One clk_sys wide.
  assign vsync_edge = vsync_rise;
  // v_disp (mode1[7] && the text GDC's START) drives the text plane only. The
  // scanout fetch's enable is the DISP bit by itself: NP2kai gates the graphics plane
  // on `gdc.mode1 & 0x80` independently of the text GDC's START (vram/scrndraw.c:188-
  // 200) and QEMU gates on mode1[DISP] alone (pc98-vga.c:4495), so a guest that
  // starts only the graphics GDC must still scan out.
  assign disp_on = mode1[7];
  assign gfx_access_page = access_page;
  assign gfx_egc_gate = mode2_egc;

  // ---------------------------------------------------------------
  // CPU-side port reads. This module answers only its own addresses; pc9821_system
  // muxes it with pc9821_gdc2's and pc9821_cg's.
  // ---------------------------------------------------------------
  reg [7:0] io_dout_r;
  always @(*) begin
    case (pc)
      5'd0:  io_dout_r = {1'b0, ~de_ff[1], vs_sync_ff[1], 2'b00, 1'b1, 1'b0, stat_dr};
      // 0x62 is the parameter read-back: the head of the send queue, or 0xFF
      // with nothing pending (NP2kai gdc_i62, io/gdc.c:684). The pop is in the
      // sequential block; gdc_snd_q is the byte the pop returns.
      5'd1:  io_dout_r = gdc_snd_q;
      5'd3:  io_dout_r = mode1;
      // 0x6E is write-only on this machine, so do not answer a latch.
      5'd5:  io_dout_r = 8'hFF;
      5'd6:  io_dout_r = crtc_pl;
      5'd7:  io_dout_r = crtc_bl;
      5'd8:  io_dout_r = crtc_cl;
      5'd9:  io_dout_r = crtc_ssl;
      5'd10: io_dout_r = crtc_sur;
      5'd11: io_dout_r = crtc_sdr;
      // 0x7C's BYTE READ IS OPEN BUS 0xFF: the port is WRITE-ONLY, and the machine
      // outranks NP2kai's live grcg.modereg (io/crtc.c:46-50).
      // probes/RDBACK.TXT:152 wrote a byte a live register could not miss and read open
      // bus anyway: `port=007C before=FF wrote=5A after=FF back=FF`. That also refutes
      // this arm's earlier reading of one as-found byte ("the write-only model also gives
      // 0xFF when modereg holds 0xFF"): 0x5A is not 0xFF. The GRCG's mode still reaches
      // its consumers as a signal (pc9821_grcg owns it; the EGC gate takes it directly),
      // so nothing but the guest read moves. The 16-bit `in ax,7Ch` FOLD is unchanged
      // (pc9821_iobus's term7c_hi forces lane 1 to 0x00), but the word read's LOW lane
      // follows this byte read, so `in ax,7Ch` moves from 0x00<mode> to 0x00FF; the word
      // form was never machine-measured (TODO item 42).
      5'd12: io_dout_r = 8'hFF;
      // NP2kai gdc_i6a returns gdc.mode2 itself, so a set bit reads back (io/gdc.c:703),
      // bit 1 included (P6: the FF2 num-1 latch round-trips).
      5'd4:  io_dout_r = {4'b0000, mode2_wren, mode2_egc, mode2_ff2b1, mode2_16color};
      // NP2kai gdc_ia8 returns gdc.palnum VERBATIM in analogue modes (io/gdc.c:913-919):
      // out 0xA8,0xAB / in 0xA8 reads 0xAB, not 0x0B. The ANALOGUE path is
      // untouched: the machine capture that settles the DIGITAL path below ran in
      // DIGITAL mode (probes/RDBACK.TXT:147 mode bytes FF1/FF2 = 18/00).
      // The DIGITAL bytes read back MASKED with 0x77 (bits 0-2 + 4-6; bit 3 undefined,
      // bit 7 unused): probes/RDBACK.TXT:148-151 `port=00A8 before=37 wrote=AB after=23`,
      // `00AA/AC/AE wrote=FF after=77`. Both software models answer the raw byte
      // (NP2kai gdc_ia8/iaa/iac/iae, io/gdc.c:913-954), so the capture is the sole source.
      // The mask is applied at the READ PORT only: the capture proves the read, and the
      // digital display decode (pc9821_gfx_palette's digpal) uses bits 0-2 and 4-6 alone,
      // so whether the hardware's stored byte is masked too is unobservable here.
      5'd20: io_dout_r = (mode2_16color || mode2_256col) ? pal_sel : (dig_a8 & 8'h77);
      // NP2kai gdc_iaa/iac/iae return the full 8-bit written byte (io/gdc.c:922-954):
      // write 0xFF, read 0xFF. The old nibble shape answered 0x0F. Analogue only; the
      // digital bytes carry the machine's 0x77 mask (see 5'd20 above).
      // In 256-colour mode the PEGC mirror answers the FULL byte at the unmasked
      // index (NP2kai gdc_iaa/iac/iae; MAME returns 0 - the recorded divergence).
      5'd22: io_dout_r = mode2_256col ? pal256_rd_q[7:0]  :
                         mode2_16color ? pal_rd_q[7:0]   : (dig_aa & 8'h77);   // 0xAA = G
      5'd23: io_dout_r = mode2_256col ? pal256_rd_q[15:8] :
                         mode2_16color ? pal_rd_q[15:8]  : (dig_ac & 8'h77);   // 0xAC = R
      5'd24: io_dout_r = mode2_256col ? pal256_rd_q[23:16]:
                         mode2_16color ? pal_rd_q[23:16] : (dig_ae & 8'h77);   // 0xAE = B
      5'd17: io_dout_r = {7'b0, display_page};
      5'd19: io_dout_r = {7'b0, access_page};
      // 0x64 is a CONSTANT 0x1F: the probe read 0x1F there, but it had written 0x1F first,
      // so a latch and a constant are indistinguishable from that capture. It does not
      // matter - the firmware writes 0x64 once (BANK7 0x6267) and never reads it in any
      // form, so no boot path observes it.
      5'd2:  io_dout_r = 8'h1F;
      default: io_dout_r = 8'hFF;
    endcase
  end
  assign io_dout = io_dout_r;

  // The 0x9A0 query state (see the port comment for the layout).
  assign gdc_ff2_state = {mode2_256e, mode2_256col, gdc_clock[1], gdc_clock[0],
                          mode2_textshift, mode2_wren, mode2_egc, mode2_16color,
                          mode1[7], mode1[4], mode1[1]};

endmodule

`default_nettype wire

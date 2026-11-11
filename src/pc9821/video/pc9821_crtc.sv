// PC-9821 CRTC: the 24 kHz text raster, the text-cell fetch/render and the pixel outputs.
// It owns the raster counters and their measured geometry, the
// text RAM and the fetch pipeline, the text line sequencer (which character row and which line
// of it each raster line shows: the GDC's LR and display partitions, the CRTC's PL/BL/CL/SSL/
// SUR/SDR - 20/25/30-line text, split screens and smooth scrolling), the render registers and
// pixel generator, the cursor and blink counters, the CPU-side video register decode and the
// configuration snapshot handshake.
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

module pc9821_crtc (
    input wire clk_sys,
    input wire rst_n_sys,
    // The RASTER POSITION COUNTER's own reset, freed from `rst_n_sys` (which is
    // `!(reset || !cpu_run)`): pc9821_system drives this from `!reset` (`wire rst_n_vid =
    // !(reset || cpu_run_rise);`, with a one-cycle
    // re-seed when cpu_run rises, so the phase a guest then sees is unchanged), so the
    // power-on defsyncm24 raster runs as soon as the core is out of reset, pack or no pack.
    // The analog OSD is drawn in the core's own timing (sys_top.v vga_osd), so with
    // no firmware pack the framework otherwise measures a 0x0 mode, the analog OSD
    // cannot be placed, and a ROM cannot be loaded from that OSD. EVERY OTHER block
    // in this module (the status flops, the scanout, the geometry) stays on
    // `rst_n_sys`, so this changes no guest-visible value: with `!cpu_run` no guest
    // can be running. See docs/policies.md's rule that the raster comes from the GDC's own
    // SYNC parameters (the defsyncm24 reset values).
    input wire rst_n_vid,
    input wire pixel_ce,       // the dot enable (one clk_sys per pixel shown)
    // The SLAVE is displaying the current raster line: its START latch is on and the line is in
    // its graphics window (pc9821_gdc2's gfx_grph_on: at or below grph_vbp and above grphymax).
    // The picture's height is the TALLER of the two GDCs'
    // windows - NP2kai dispsync_renewalvertical `scrnymax = MAX(grphymax, textymax)` - so a
    // slave window that runs past the master's active lines extends the displayed area (the
    // text plane stays inside the master's). The BIOS 640x480 mode needs it: INT 18h AH=30h
    // with BH=0x31 (25 rows; the Win95 PC-9821 256-colour driver's call, PEGCV8.DRV seg 2
    // @0x0B0D) programs the master with AL 475 (19-line rows) and the slave with AL 480 (NP2kai
    // bios/bios18.c gdcmastersync[4] `0xdb,0x95` / gdcslavesync[1] `0xe0,0x95`; the Xe10
    // firmware's own rows at BANK3@0x1F8E and 0x1E2D carry the same bytes). NP2kai takes the
    // MAX whether or not the slave was started; a slave that was never STARTed puts nothing on
    // the screen, so here it extends nothing (a text-only block keeps the master's lines).
    // THE START TERM IS KEPT DELIBERATELY, against NP2kai: dispsync_renewalvertical (vram/dispsync.c)
    // reads only gdc.s.para[GDC_SYNC] and has no START term, but that is the emulator's surface
    // arithmetic, and qemu-pc98 and MAME model no per-GDC picture height at all, so no reference
    // evidences the real pair raising DE on lines only a stopped slave's window covers. The two
    // readings differ only in lines that are black either way on the analog output (graphics off,
    // the master's text over), and dropping the term would stretch every master-only reprogram
    // (a SYNC written while the slave keeps its power-on 400-line window) to the slave's height
    // on the HDMI scaler: tb_pc9821_gdc_sync_raster and tb_pc9821_line_doubler pin the master's
    // lines for that case. A hardware capture cannot tell them apart from a monitor either.
    input wire gfx_win_on,
    // 0x09A8 bit 0 (pc9821_iobus): the 31 kHz dot clock is running, so the 31 kHz monitor range
    // clamps the raster (the geometry section). Sampled at the frame boundary with the block.
    input wire crt31k,

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
    // THE BASE MEMORY (0xA3FEA bits 2:0) IS NOT A PORT: the real Xe10 has no
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
    // The start word of the partition the walker's next row is in (partition 0's is the
    // display-start snapshot, as it always was), and the walk request itself: go on the row's
    // first line, the row's index in its partition and the cache bank to fill.
    output wire [15:0] o_v_sad,
    output wire        o_v_row0_stale,
    output wire        o_wk_go,
    output wire [9:0]  o_wk_k,
    output wire [1:0]  o_wk_bank,
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
    // mode2_egc's NEXT state, exported so pc9821_system's pc9821_egc_mem_gate can register the
    // EGC x GRCG memory gate from BOTH sources' next state (a true pipeline relocate: the register
    // is cycle-identical to the combinational AND, and the crtc-launched GVRAM cone is cut;
    // docs/timing.md). This is the register's OWN next-state expression below,
    // not a copy of it.
    output wire gfx_egc_gate_nx,

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
  //     hs   = tmp & 0x1f                    h sync width      -> HSYNC_W = 8*(hs+1)  (MAME m_hs)
  //     vs   = (tmp >> 5) & 0x1f             v sync width      -> VSYNC_W = vs
  //     hfp2 = tmp >> 10                     h front porch     -> HFP = 8*(hfp2+1)    (MAME m_hfp)
  //   para[4] & 0x3f                         h back porch      -> HBP = 8*(that+1)    (MAME m_hbp)
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
  // character clock 21052600/8 with minx 100, maxx 112, miny 400, maxy 575 - EXCEPT THE x
  // FLOOR, WHICH THE MACHINE SETS LOWER: the real Xe10 runs a SYNC block with AW 64 (C/R 0x3E,
  // x = 64 + 26 = 90) as a 720-dot line, 29.24 kHz / 66.46 Hz on the OSSC
  // (docs/probes/KIT2-XE10-TXTMODE.TXT:36 `FRAME 16 VSYNC ticks=000120F1 lines=01B8`, against
  // the default's :9 `ticks=0001544F`: 848 x 0x120F1 / 0x1544F = 720.0 dots), where NP2kai's
  // minx 100 would hold it at 800. So minx is 90, the lowest x the machine was seen to run; a
  // block below it is not measured and stays clamped there (todo item 85). The GDC clock
  // select (0x6A nums 0x41/0x42) never moves the raster (measured on the machine), and gdcclk[0]
  // (15.98 kHz) belongs to other machines' monitors. WHILE 0x09A8 BIT 0 IS SET (crt31k) the dot
  // clock is the separate 31 kHz oscillator (pc9821_vclk_pkg, docs/probes/CRT31K.TXT) and the range
  // is NP2kai's SUPPORT_CRT31KHZ entry gdcclk[2] (io/gdc.c:36 `{25260000 / 8, 100 - 8, 100 + 8,
  // 400, 575}`): minx 92, maxx 108, miny 400, maxy 575 - selected by the same bit in
  // gdc_updateclock (io/gdc.c:402-404 `if (gdc.display & (1 << GDCDISP_31)) clk = gdcclk + 2`).
  // Only its range is taken: its 25.26 MHz clock is the capture's divergence. The capture's
  // 800 x 449 block (x 100, y 449) and the BIOS 640 x 480 block (NP2kai bios/bios18.c
  // gdcmastersync[3..5]: x 100, y 525) sit inside both ranges, so the capture cannot test the
  // limits themselves.
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
  // 21.0526 MHz dot clock, with porches (front/sync/back) 80/64/64 and 7/8/25 and the VSYNC pulse rising on
  // vline 407 = VACTIVE + VFP (docs/probes/FLIP.TXT).
  //
  // THE PULSE WIDTH IS THE vs FIELD, and the machine's own capture says so: the 2M-sample
  // 0x60 histogram counts bit 5 high in 36 385 of 2 097 152 samples = 1.735 %, which is 8 of
  // the 440 lines once its sampling loop's x1.048 duty bias is divided out - the bias the
  // same capture's bit 6 shows against the horizontal blank (23.4 % measured, 208/848 =
  // 24.53 % modelled) - so the machine's VSYNC pulse IS the block's vs = 8 lines, as MAME's
  // m_vs (upd7220.cpp:1236) and NP2kai's own expression both derive. A 12-line pulse would
  // come from a "2.8 %" of the SAME count over a divisor of 1 310 720 instead of the
  // 2 097 152 its own always-set bit 2 (0x200000 samples) prints - a mis-derivation
  // (docs/probes/GDC.TXT).
  // ---------------------------------------------------------------
  // gdcclk[1]'s range (see above), in characters and lines, and NP2kai's own h back porch; the
  // x floor is the machine's measured 90 (KIT2-XE10-TXTMODE.TXT:36, above), not gdcclk[1]'s 100.
  localparam [9:0] CLK_MINX = 10'd90, CLK_MAXX = 10'd112;
  localparam [9:0] CLK_MINY = 10'd400, CLK_MAXY = 10'd575;
  localparam [9:0] CLK31_MINX = 10'd92, CLK31_MAXX = 10'd108;   // gdcclk[2]; y as gdcclk[1]
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

  // ---- THE GEOMETRY, IN TWO REGISTERED HALVES (V1-a, a timing seam) ----
  // NP2kai's field map, its roots and the clamp, then the porch fits, are four functions of
  // the eight parameter bytes (b0..b7 = para[0..7]):
  //   crtc_x/y/lf, crtc_hact/vact the ROOTS: the clamped character and line totals and the
  //                              active window (HACTIVE, VACTIVE). Evaluated on the block AS IT
  //                              ARRIVES and registered (s_x_r/s_y_r/s_ha_r/s_va_r) on the edge
  //                              the v_sync copy runs, from the same pre-edge sync_live, so
  //                              they equal the same functions of v_sync at EVERY cycle.
  //   crtc_d                     the DERIVED compare operands (HACTIVE+HFP, +HSYNC_W,
  //                              VACTIVE+VFP, +VSYNC_W, the "- 1" bounds,
  //                              the walk slot), registered EVERY clk_sys from the roots and
  //                              v_sync (geom_d). So every raster compare reads registers; the
  //                              old single path ran v_sync through the field map, the clamp,
  //                              the porch fits and the sums into HSYNC/VSYNC (16 levels).
  // geom_d lags its inputs by ONE clk_sys, and its inputs move only on the frame-boundary edge
  // (and reset, which loads both halves with the default block's values together). So geom_d
  // can differ from crtc_d(the roots) only in the ONE clk_sys right after that edge, when
  // hdot = vline = 0. Every compare made there has the same answer for ANY two geometries:
  // HS_ON >= 16 and VS_ON >= VACTIVE >= 1 (no pulse at dot 0 / line 0), and HTOT_M1 >= 719,
  // VTOT_M1 >= 399, WK_SNAP >= 383 (no line
  // end, frame end or walk slot) - tools/equiv/crtc_geom_lag.sv proves exactly that for every
  // pair of blocks. The one compare against VACT_M1 sampled there is the text line sequencer's
  // restart test (vline == VACT_M1 at a line's first dot); vline = 0 can equal VACT_M1 only
  // for a one-line picture (lf = 1), the one block whose lag cycle could pick a restart. Every
  // OUTPUT therefore equals a direct combinational decode's at every cycle:
  // tb_pc9821_crtc_geom_equiv pins that against a reference copy, and tools/equiv/crtc_geom.sv
  // proves the functions equal to the direct wiring for every block. HTOTAL/VTOTAL/HACTIVE/
  // VACTIVE themselves are roots (8*x, y and the active window), so o_htotal/o_vtotal,
  // feed_odd, the active window and the fetch walker read edge-registered values equal to the
  // direct decode at every cycle.
  //
  // THE FIELD MAP AND CLAMP (unchanged; see the block comment above).
  /* verilator lint_off UNUSEDSIGNAL */   // each function takes whole parameter bytes and reads
  // only the fields NP2kai's map puts in them (b0, the sync-format byte, is never read).
  function automatic [7:0] crtc_x;
    input       c31;
    input [7:0] b1, b2, b3, b4;
    reg  [9:0] cr; reg [4:0] hs_f; reg [6:0] hfp_f; reg [8:0] hfbs; reg [9:0] x_raw;
    reg  [9:0] minx, maxx;
    begin
      minx  = c31 ? CLK31_MINX : CLK_MINX;
      maxx  = c31 ? CLK31_MAXX : CLK_MAXX;
      cr    = {2'b00, b1} + 10'd2;
      hs_f  = b2[4:0];
      hfp_f = {1'b0, b3[7:2]} + {1'b0, b4[5:0]};
      hfbs  = {4'b0000, hs_f} + {2'b00, hfp_f} + HBP_CH;
      x_raw = cr + {1'b0, hfbs};
      crtc_x = (x_raw < minx) ? minx[7:0]
             : (x_raw > maxx) ? maxx[7:0] : x_raw[7:0];
    end
  endfunction
  // ((tmp2 - 1) & 0x3ff) + 1 is the low ten bits of tmp2 minus one, plus one.
  function automatic [10:0] crtc_lf;
    input [7:0] b6, b7;
    reg [9:0] lfm1;
    begin
      lfm1    = {b7[1:0], b6} - 10'd1;
      crtc_lf = {1'b0, lfm1} + 11'd1;
    end
  endfunction
  function automatic [9:0] crtc_y;
    input [7:0] b2, b3, b5, b6, b7;
    reg [4:0] vs_f; reg [5:0] vfp_f, vbp_f; reg [7:0] vfbs0, vfbs; reg [11:0] y_raw;
    begin
      vs_f  = {b3[1:0], b2[7:5]};
      vfp_f = b5[5:0];
      vbp_f = b7[7:2];
      vfbs0 = {3'b000, vs_f} + {2'b00, vfp_f} + {2'b00, vbp_f};
      vfbs  = (vfbs0 == 8'd0) ? 8'd1 : vfbs0;
      y_raw = {1'b0, crtc_lf(b6, b7)} + {4'b0000, vfbs};
      crtc_y = (y_raw < {2'b00, CLK_MINY}) ? CLK_MINY
             : (y_raw > {2'b00, CLK_MAXY}) ? CLK_MAXY : y_raw[9:0];
    end
  endfunction
  // The active window always leaves blanking to hold its own sync (x = cr + at least 3
  // characters, so for a block whose cr is inside its line this is cr exactly - and it is
  // clamped INTO the frame). HACTIVE and VACTIVE are ROOTS too (edge-registered, so equal to
  // the direct decode at every cycle like HTOTAL/VTOTAL - the four values the odd-sync-parity
  // contract names, tb_pc9821_tram_addr_equiv's geom-shared-bit-identity).
  function automatic [9:0] crtc_hact;
    input [7:0] x; input [7:0] b1;
    reg [12:0] hact8; reg [9:0] hactmax;
    begin
      hact8     = {({2'b00, b1} + 10'd2), 3'b000};
      hactmax   = (x * 10'd8) - 10'd8;
      crtc_hact = (hact8 > {3'b000, hactmax}) ? hactmax : hact8[9:0];
    end
  endfunction
  // The text fetch's last cell: the last whole cell of HACTIVE (8 dots in 80 columns, 16 in 40),
  // capped at column 79 / 39. Below 80 columns it is the GDC's own line end: the real Xe10 draws
  // an AW 78 or AW 64 line's first cell from the next row's word, not the cell past the line
  // (KIT2-XE10-TXTMODE.TXT P3/P4, filmed). Above 80 the cap keeps the old wrap cell - no capture
  // has a line wider than 80 (the row cache holds 80 cells; todo item 85).
  function automatic [6:0] crtc_lc80;
    input [9:0] hact;
    crtc_lc80 = (hact[9:3] > 7'd80) ? 7'd79 : (hact[9:3] - 7'd1);
  endfunction
  function automatic [5:0] crtc_lc40;
    input [9:0] hact;
    crtc_lc40 = (hact[9:4] > 6'd40) ? 6'd39 : (hact[9:4] - 6'd1);
  endfunction
  function automatic [9:0] crtc_vact;
    input [9:0] y; input [10:0] lf;
    reg [9:0] lfmax;
    begin
      lfmax     = y - 10'd1;
      crtc_vact = (lf > {1'b0, lfmax}) ? lfmax : lf[9:0];
    end
  endfunction
  // THE DERIVED OPERANDS, from the roots (x, y, HACTIVE, VACTIVE) and the porch fields. Field layout, low to
  // high, every field 10 bits:
  localparam integer G_HTOT_M1 = 0,  G_HS_ON = 10,   G_HS_OFF = 20,  G_VTOT_M1 = 30,
                     G_VACT_M1 = 40, G_VS_ON = 50,   G_VS_OFF = 60,  G_WK_SLOT = 70,
                     G_WK_SNAP = 80, G_VFP = 90,     G_VSYNC_W = 100, G_W = 110;
  function automatic [G_W-1:0] crtc_d;
    input [7:0] x; input [9:0] y; input [9:0] hactive; input [9:0] vactive;
    input [7:0] b2, b3, b4, b5;
    reg [5:0] hs_f; reg [6:0] hfp_f; reg [4:0] vs_f; reg [5:0] vfp_f;
    reg [9:0] htotal, vtotal, hblank, hfp8, hs8, hfp, hsync_w;
    reg [9:0] vblank, vfp10, vfp, vs10, vs_room, vsync_w, wk_slot;
    begin
      // THE HORIZONTAL PORCHES ARE THE uPD7220's (MAME upd7220.cpp:1243-1246: `m_hs = (m_pr[3] &
      // 0x1f) + 1`, `m_hfp = (m_pr[4] >> 2) + 1`, `m_hbp = (m_pr[5] & 0x3f) + 1`, in characters;
      // MAME's m_pr[n] is this file's para[n-1]): HSYNC_W = 8*(hs+1), HFP = 8*(hfp2+1), and the back
      // porch is the rest, 8*((para[4] & 0x3f)+1) when the totals are not clamped. NP2kai only sums
      // the same three fields (+3, its three "+1"s) into the line total and never places a porch,
      // so the split is MAME's. Taking para[4] as more FRONT porch would give the default block
      // HFP 128 / HS 56 / HBP 24 dots instead of 80 / 64 / 64: the same blanking and line, but
      // the hsync 40 dots late, which puts the analog picture far left on a monitor (seen on the
      // doubled output). Only hs_out depends on it (no guest-visible bit reads hsync).
      hs_f    = {1'b0, b2[4:0]} + 6'd1;
      hfp_f   = {1'b0, b3[7:2]} + 7'd1;
      vs_f    = {b3[1:0], b2[7:5]};
      vfp_f   = b5[5:0];
      // HTOTAL = 8*x characters: 720..896 dots (720..896 at 24 kHz, 736..864 at 31 kHz); VTOTAL = y: 400..575 lines; the pulse fits
      // inside the blanking the active window leaves.
      htotal  = x * 10'd8;
      vtotal  = y;
      hblank  = htotal - hactive;                                     // >= 8 dots
      hfp8    = {hfp_f, 3'b000};
      hs8     = {1'b0, hs_f, 3'b000};
      hfp     = (hfp8 <= (hblank - 10'd8)) ? hfp8 : (hblank - 10'd8);
      hsync_w = (hs8 == 10'd0) ? HSYNC_MIN
              : (hs8 <= (hblank - hfp)) ? hs8 : (hblank - hfp);
      vblank  = vtotal - vactive;                                     // >= 1 line
      vfp10   = {4'b0000, vfp_f};
      vfp     = (vfp10 > (vblank - 10'd1)) ? (vblank - 10'd1) : vfp10;
      vs10    = {5'b00000, vs_f};
      vs_room = vblank - vfp;                                         // >= 1 line
      vsync_w = (vs10 == 10'd0) ? VSYNC_MIN
              : (vs10 > vs_room) ? vs_room : vs10;
      wk_slot = (vtotal - 10'd1) & 10'h3F0;
      // Each operand is the 10-bit value its consumer compared against before (the pulses'
      // bounds were 10-bit sums in a 10-bit compare; the "- 1" bounds are exact because
      // HTOTAL >= 720 and VTOTAL >= 400 never wrap).
      crtc_d = {vsync_w, vfp, wk_slot - 10'd1, wk_slot,
                vactive + vfp + vsync_w, vactive + vfp, vactive - 10'd1,
                vtotal - 10'd1,
                hactive + hfp + hsync_w, hactive + hfp, htotal - 10'd1};
    end
  endfunction

  /* verilator lint_on UNUSEDSIGNAL */

  // The roots (registered on the frame-boundary edge with v_sync, below).
  reg  [7:0] s_x_r;    // the clamped x: HTOTAL = 8*x
  reg  [9:0] s_y_r;    // the clamped y = VTOTAL
  reg  [9:0] s_ha_r;   // HACTIVE
  reg  [9:0] s_va_r;   // VACTIVE
  // The last cell of the line the GDC reads (80- and 40-column), from HACTIVE: the text fetch's
  // wrap cell (see last_cell). Roots like HACTIVE, so the fetch compares a register.
  reg  [6:0] s_lc80_r;
  reg  [5:0] s_lc40_r;
  // The derived operands (registered every clk_sys, below).
  reg [G_W-1:0] geom_d;
  wire [9:0] HTOTAL   = s_x_r * 10'd8;            // 720..896 dots (8*x: a shift)
  wire [9:0] VTOTAL   = s_y_r;                    // 400..575 lines
  wire [9:0] HTOT_M1  = geom_d[G_HTOT_M1 +: 10];
  wire [9:0] HACTIVE  = s_ha_r;
  wire [9:0] HS_ON    = geom_d[G_HS_ON   +: 10];   // HACTIVE + HFP
  wire [9:0] HS_OFF   = geom_d[G_HS_OFF  +: 10];   // HACTIVE + HFP + HSYNC_W
  wire [9:0] VTOT_M1  = geom_d[G_VTOT_M1 +: 10];
  wire [9:0] VACTIVE  = s_va_r;
  wire [9:0] VACT_M1  = geom_d[G_VACT_M1 +: 10];
  wire [9:0] VS_ON    = geom_d[G_VS_ON   +: 10];   // VACTIVE + VFP
  wire [9:0] VS_OFF   = geom_d[G_VS_OFF  +: 10];   // VACTIVE + VFP + VSYNC_W
  wire [9:0] wk_slot  = geom_d[G_WK_SLOT +: 10];
  wire [9:0] WK_SNAP  = geom_d[G_WK_SNAP +: 10];   // wk_slot - 1
  /* verilator lint_off UNUSEDSIGNAL */            // diagnosis only (tb_pc9821_userdisk's dump)
  wire [9:0] VFP      = geom_d[G_VFP     +: 10];
  wire [9:0] VSYNC_W  = geom_d[G_VSYNC_W +: 10];
  /* verilator lint_on UNUSEDSIGNAL */
  wire [5:0] VBP      = v_sync[7][7:2];           // the block's vbp field (o_vbp)

  // ---------------------------------------------------------------
  // Video timing counters
  // ---------------------------------------------------------------
  reg [9:0] hdot;
  reg [9:0] vline;
  wire in_hsync = (hdot >= HS_ON) && (hdot < HS_OFF);
  // The VSYNC PULSE. This is the GDC's vertical sync output: VFP lines of front porch after the
  // last active line, then VSYNC_W lines of sync, then the back porch that is left. The split is
  // MAME's uPD7220 model to the line - `update_vsync_timer` drives the output active at
  // y = m_vbp + m_al + m_vfp with the screen's visible top at m_vbp (upd7220.cpp:347-358,
  // :428-429) - and the width is the block's vs field (see the SYNC block above). The vblank IRQ
  // is raised on THIS pulse's rising edge (see vsync_irq), so with the default block the guest's
  // drawing window after the interrupt is vline 407 to the next frame's vline 0 = 33 lines.
  wire in_vsync = (vline >= VS_ON) && (vline < VS_OFF);
  wire h_active = (hdot < HACTIVE);
  wire v_active = (vline < VACTIVE);
  // The DISPLAYED lines: the master's active lines, or the slave's graphics window (see
  // gfx_win_on) - never into the master's VSYNC, which stays where its block puts it.
  wire v_disp_any = v_active || (gfx_win_on && (vline < VS_ON));
  wire frame_end = (vline == VTOT_M1) && (hdot == HTOT_M1);
  // The last walk slot of the vertical blanking interval, where the walker's own display-start
  // inputs are copied ahead of the walk trigger in the next slot (vline 432 for the default
  // 440-line frame). Row 0's cache is filled a whole frame before it is drawn, so the walker
  // re-walks row 0 in that slot with this frame's display start rather than the previous
  // frame's. The walk slots are the vline[3:0] == 0 grid, so the last one inside the frame is
  // VTOTAL-1 rounded down to that grid. The rest of the configuration, and the scanout itself,
  // still commits at frame_end below.
  wire wk_cfg_snap = (vline == WK_SNAP) && (hdot == HTOT_M1);

  // The raster half's copy of the sync block and its roots: unconditional at the frame
  // boundary, like v_mode1_200 below - the geometry is not one of the registers the scanout
  // snapshot carries. The roots run in this SAME block so they sample the same pre-edge
  // sync_live on the same edge (see the two-halves note above).
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      v_sync[0] <= 8'h10; v_sync[1] <= 8'h4e; v_sync[2] <= 8'h07; v_sync[3] <= 8'h25;
      v_sync[4] <= 8'h07; v_sync[5] <= 8'h07; v_sync[6] <= 8'h90; v_sync[7] <= 8'h65;
      s_x_r  <= 8'd106;    // defsyncm24's x
      s_y_r  <= 10'd440;   // ...its y
      s_ha_r <= 10'd640;   // ...its HACTIVE (8*cr)
      s_va_r <= 10'd400;   // ...and its VACTIVE (lf)
      s_lc80_r <= 7'd79;   // ...and its last cells (80 columns, 40 columns)
      s_lc40_r <= 6'd39;
    end else if (pixel_ce && frame_end) begin
      v_sync[0] <= sync_live[0]; v_sync[1] <= sync_live[1];
      v_sync[2] <= sync_live[2]; v_sync[3] <= sync_live[3];
      v_sync[4] <= sync_live[4]; v_sync[5] <= sync_live[5];
      v_sync[6] <= sync_live[6]; v_sync[7] <= sync_live[7];
      s_x_r  <= crtc_x(crt31k, sync_live[1], sync_live[2], sync_live[3], sync_live[4]);
      s_y_r  <= crtc_y(sync_live[2], sync_live[3], sync_live[5], sync_live[6], sync_live[7]);
      s_ha_r <= crtc_hact(crtc_x(crt31k, sync_live[1], sync_live[2], sync_live[3], sync_live[4]),
                          sync_live[1]);
      s_va_r <= crtc_vact(crtc_y(sync_live[2], sync_live[3], sync_live[5], sync_live[6],
                                 sync_live[7]), crtc_lf(sync_live[6], sync_live[7]));
      s_lc80_r <= crtc_lc80(crtc_hact(crtc_x(crt31k, sync_live[1], sync_live[2], sync_live[3],
                                             sync_live[4]), sync_live[1]));
      s_lc40_r <= crtc_lc40(crtc_hact(crtc_x(crt31k, sync_live[1], sync_live[2], sync_live[3],
                                             sync_live[4]), sync_live[1]));
    end
  end
  // The derived operands, every clk_sys from the roots (one clk_sys behind them; see above).
  // The reset value is the default block's, loaded with the roots' own.
  always @(posedge clk_sys) begin
    if (!rst_n_sys)
      geom_d <= crtc_d(8'd106, 10'd440, 10'd640, 10'd400, 8'h07, 8'h25, 8'h07, 8'h07);
    else
      geom_d <= crtc_d(s_x_r, s_y_r, s_ha_r, s_va_r, v_sync[2], v_sync[3], v_sync[4], v_sync[5]);
  end

  // The raster position counter is the ONE block reset by `rst_n_vid` (i.e. `!reset`, not
  // `!(reset || !cpu_run)`): it must walk the defsyncm24 geometry before the firmware pack
  // loads, so the machine emits a valid raster for the analog OSD with no ROM. geom_d and
  // the sync roots above stay held by `rst_n_sys` at the default block, so the counter walks
  // exactly that geometry; the status flops below stay on `rst_n_sys` so the reset status is
  // unchanged.
  always @(posedge clk_sys) begin
    if (!rst_n_vid) begin
      hdot  <= 10'd0;
      vline <= 10'd0;
    end else if (pixel_ce && frame_end) begin
      hdot  <= 10'd0;
      vline <= 10'd0;
    end else if (pixel_ce && hdot == HTOT_M1) begin
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
  // The text GDC's parameter RAM: the four display partitions (NP2kai GDC_SCROLL + GDC_TEXTW,
  // sixteen bytes, io/gdc_cmd.h:35-36 `GDC_SCROLL = (GDC_CSRFORM+3)`). Command 0x70+n writes
  // para[GDC_SCROLL+n] onward, up to the sixteenth byte (io/gdc_cmd.tbl:129-144
  // `{GDC_SCROLL+0, 16, 0, 1}, // 70 CMD_SCROLL` ... `{GDC_TEXTW+7, 1, 0, 1}, // 7f`), and
  // maketext reads partition i's four bytes at offset 4i (vram/maketext.c:416-418
  // `esi = LOW12(LOADINTELWORD(gdc.m.para + GDC_SCROLL + scrp))`): the start word is LOW12 of
  // bytes 0-1 and the line count LOW14 of bytes 2-3 shifted right by four. Only those fields
  // are kept: partition 0's start stays the two whole bytes it always was (the scanout's
  // display-start snapshot and its pre-mask tap read them), the rest are the fields alone.
  // The GDC's PRAM has no read port (NP2kai has none either), so nothing else is stored.
  reg [7:0]  pram_scr[0:1];
  reg [9:0]  pram_len0;                          // partition 0's line count
  reg [11:0] pram_sad1, pram_sad2, pram_sad3;    // partitions 1-3: LOW12 start word
  reg [9:0]  pram_len1, pram_len2, pram_len3;    // ...and line count
  reg [3:0]  pram_ptr;                           // the next PRAM byte a parameter writes
  reg        pram_act;                           // a PRAM command is taking parameter bytes
  reg [7:0] csr_ead[0:1];  // CSRW cursor address
  // CSRW's THIRD byte, the address bits 16+. It is not dropped after all: the
  // CSRR command (0xE0) answers it masked to 2 bits as parameter byte 2
  // (NP2kai gdc_work fills para[GDC_CSRR+2] = para[GDC_CSRW+2] & 3, io/gdc.c:327-337).
  reg [7:0] csr_ead2;
  reg [7:0] csr_form[0:2];  // CSRFORM params
  reg cmd_active;
  // The command in hand, as the class the parameter path and the read-back need (the byte itself
  // is read nowhere else): 0 PITCH (0x47), 1 CSRW (0x49), 2 CSRFORM (0x4B), 3 0x06, 4 CSRR (0xE0),
  // 5 any other.
  reg [2:0] cur_k;
  reg [2:0] param_cnt;
  reg sync_pending;
  reg [2:0] sync_cnt;
  reg gdc_start;  // GDC1 character display started

  // GDCANALOG_256E (the FF2 dat 0x68/0x69 form) and the two GDC clock-select bits (dat
  // 0x82/0x83 and 0x84/0x85). NP2kai toggles them unconditionally (its gdc_o6a dat cases,
  // io/gdc.c:501-603) and reads them back through the 0x9A0 query table. Nothing else
  // consumes them. (FF2 num 1 stores nothing: its only reader was the 0x6A read-back, and
  // the machine's 0x6A reads 00, see the read arm.)
  reg mode2_256e;
  reg [1:0] gdc_clock;

  // The parameter read-back queue (NP2kai's snd/para pair): commands with
  // `indatas` load it (gdc_cmd.tbl rows 0xC0 LPEN = 3 bytes and 0xE0 CSRR = 5),
  // a read of 0x62 pops one byte, and any new command replaces it (gdc_work's
  // `item->snd = gdc_cmd[data].indatas`). CSRR answers {CSRW0, CSRW1, CSRW2&3,
  // 0, 0}; LPEN answers para[GDC_LPEN..2] = para[29..31] (io/gdc_cmd.h:34,38:
  // GDC_CSRFORM = 9, GDC_LPEN = 29). No
  // command writes those slots (no gdc_cmd.tbl row stores to pos 29) and
  // gdc_reset zero-fills them (io/gdc.c:1160), so LPEN answers 00 00 00 - NOT
  // the CSRFORM bytes this module keeps for the cursor.
  // The queue is not stored: 0xE0's answer is {CSRW0, CSRW1, CSRW2 & 3, 0, 0} of the LIVE cursor
  // registers, which cannot move while it is pending (the CSRW parameters land only under
  // cmd_active, which 0xE0 clears, and the next command - the only way back to cmd_active -
  // replaces the queue), and 0xC0's is three zeros. gdc_snd_head is the byte the next pop returns.
  reg [2:0] gdc_snd_cnt;
  reg [2:0] gdc_snd_ptr;
  wire [7:0] gdc_snd_head;
  assign gdc_snd_head = (cur_k != 3'd4)        ? 8'h00 :
                        (gdc_snd_ptr == 3'd0) ? csr_ead[0] :
                        (gdc_snd_ptr == 3'd1) ? csr_ead[1] :
                        (gdc_snd_ptr == 3'd2) ? (csr_ead2 & 8'h03) : 8'h00;
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
  reg       mode2_256col;     // FF2 num 0x10: 256-colour / PEGC select
  // FF2 num 0x20/0x40: text shift (31 kHz CRT). Read back only, through the 0x9A0 query's
  // index 0x05 (gdc_ff2_state[6]); the text shift itself is not implemented.
  reg       mode2_textshift;
  // The 0xA8 palette-index register: the FULL byte, round-trip. NP2kai stores `dat`
  // unmasked in gdc.palnum (io/gdc.c:841) and gdc_ia8 returns it verbatim (:913-919),
  // so `out 0xA8,0xAB / in 0xA8` reads 0xAB - the register is architecturally 8 bits
  // (the PEGC 256-colour palette indexes through it, gdc.c:854); a 4-bit register
  // would answer 0x0B. Who consumes it, exactly as NP2kai splits
  // it: the DAC takes palnum & 15 (gdc.c:862 gdc_setanalogpal) and the read mirror
  // below takes the MASKED palnum & 15 (the PEGC 256-colour mirror is out of scope).
  reg [7:0] pal_sel;
  // The analogue table's READ MIRROR: three 4-bit channel nibbles per entry
  // ({B, R, G} = write bytes 0xAE/0xAC/0xAA, low nibble kept), so a CPU read of
  // 0xAA/0xAC/0xAE answers {4'b0, nibble}. THE CAPTURE IS THE SOURCE:
  // docs/probes/PEGCRD-XE10.TXT, the measured Xe10 in 16-colour analogue mode, reads
  // `16  ENTRY=02 WROTE_R=FF G=00 B=7F READ_R=0F G=00 B=0F` and
  // `ENTRY=01 WROTE_R=12 G=34 B=56 READ_R=02 G=04 B=06`: the upper four bits read 0.
  // NP2kai io/gdc.c gdc_iaa/iac/iae (`gdc.anareg[...]`) answers the whole written
  // byte; that is the recorded divergence, the capture outranks it.
  // The PEGC 256-colour read keeps its own full-byte mirror (pal256_*), also from that capture.
  // The nibble is what the 16-colour DAC and pc9821_gfx_palette keep (pal_wr_data), so
  // the mirror holds exactly the live table's bits. IMMEDIATE semantics like the
  // registers it replaces; one 12-bit output register is its read port.
  // 16 entries, indexed by palnum & 15: the Xe10's own 16-colour analogue palette.
  // NP2kai's 256-entry anareg[palnum*3+c] mirror is the PEGC's 256-colour palette,
  // which is out of scope here - left out for area (a 256-entry register array costs
  // ~6 Kbit of logic on a ~99%-full device).
  //
  // THE MIRROR IS THREE 16x4 NIBBLE LANES (measured below as 16x8 byte lanes, before the
  // capture narrowed them), one per channel, not one 16x24 array written in
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
  (* ramstyle = "M10K" *) reg [3:0] pal_g[0:15];
  (* ramstyle = "M10K" *) reg [3:0] pal_r[0:15];
  (* ramstyle = "M10K" *) reg [3:0] pal_b[0:15];
  // The read port is the registered read the single array always had (one clk_sys from the
  // lane's address to the byte), so the CPU readback's one-cycle latency is unchanged; the
  // three bytes re-join combinationally, which is all the read decode ever needed.
  reg [3:0] pal_g_q, pal_r_q, pal_b_q;
  wire [11:0] pal_rd_q = {pal_b_q, pal_r_q, pal_g_q};

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
      // PRAM (0x70-0x7F) takes 16 - n bytes and runs on pram_act/pram_ptr, not this count.
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

  // The mode2_egc register's NEXT state. `mode2_egc_wr` is the FF2 num-2 write decode
  // (0x6A, dat bit0 = on, num = (dat>>1)&0x7F == 2), and this is the single next-state
  // expression the register AND the exported
  // gfx_egc_gate_nx both read. The reset term matches the register's own `!rst_n_sys` clear
  // (mode2_wren resets to 0, so the arm could not fire during reset anyway).
  wire mode2_egc_wr = io_wr && (pc == 5'd4) && (((io_din >> 1) & 8'h7F) == 8'h02);
  wire mode2_egc_nx = (!rst_n_sys) ? 1'b0 : ((mode2_egc_wr && mode2_wren) ? io_din[0] : mode2_egc);
  assign gfx_egc_gate_nx = mode2_egc_nx;

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
      // gdc_reset zero-fills para (io/gdc.c), so every partition's line count is 0 - which
      // maketext's `if (!(--scroll))` never reaches inside a frame: one partition.
      pram_len0 <= 10'd0;
      pram_sad1 <= 12'd0; pram_sad2 <= 12'd0; pram_sad3 <= 12'd0;
      pram_len1 <= 10'd0; pram_len2 <= 10'd0; pram_len3 <= 10'd0;
      pram_ptr  <= 4'd0;
      pram_act  <= 1'b0;
    end else begin
      // The parameter read-back queue's pop: exactly one byte per CPU read of
      // 0x62 (NP2kai gdc_i62, io/gdc.c:684-692). The returned byte is loaded
      // into the read-data register because the GDC block's reads are captured
      // one cycle after this strobe.
      if (io_rd && (pc == 5'd1)) begin
        if (gdc_snd_cnt != 3'd0) begin
          gdc_snd_q   <= gdc_snd_head;
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
            // THE C/R BYTE (the second, AW - 2) ALSO LOADS THE TEXT PITCH on the real Xe10, for
            // SYNC 0x0F and the display-off 0x0E alike, and a later PITCH command overrides it
            // (docs/probes/KIT2-XE10-TXTMODE.TXT, filmed: P1 `OUT C0F P10 P4E ...` with no PITCH
            // shears the rows 2 cells each = pitch 78, P3 `P4C` 4 cells = pitch 76, P4 `P3E` 18
            // cells = pitch 62, P5 `OUT C0E P10 P4E ... C0D` 2 cells, P6 `OUT C47 P50 C0F P10
            // P4E ...` 2 cells - the SYNC wins - and P2/P7, PITCH 0x50 after the block, none).
            // MAME (upd7220.cpp, pitch = AW) and NP2kai (SYNC leaves the pitch) both differ; the
            // machine outranks them. The byte is stored as PITCH stores it (the odd bit dropped,
            // NP2kai maketext.c:194): every C/R the capture used is even, and it is one register.
            if (sync_cnt == 3'd1) pitch <= {io_din[7:1], 1'b0};
            if (sync_cnt == 3'd7) begin
              sync_pending <= 1'b0;
              sync_cnt <= 3'd0;
            end else sync_cnt <= sync_cnt + 3'd1;
          end else if (pram_act) begin
            // One PRAM byte at pram_ptr, then the pointer moves on; the sixteenth byte ends
            // the command (gdc_work stores para[ptr++] while rcv counts 16 - n down,
            // io/gdc.c:340-345 `item->para[item->ptr] = data;`). Each byte lands as it arrives.
            case (pram_ptr)
              4'd0:  pram_scr[0]       <= io_din;
              4'd1:  pram_scr[1]       <= io_din;
              4'd2:  pram_len0[3:0]    <= io_din[7:4];
              4'd3:  pram_len0[9:4]    <= io_din[5:0];
              4'd4:  pram_sad1[7:0]    <= io_din;
              4'd5:  pram_sad1[11:8]   <= io_din[3:0];
              4'd6:  pram_len1[3:0]    <= io_din[7:4];
              4'd7:  pram_len1[9:4]    <= io_din[5:0];
              4'd8:  pram_sad2[7:0]    <= io_din;
              4'd9:  pram_sad2[11:8]   <= io_din[3:0];
              4'd10: pram_len2[3:0]    <= io_din[7:4];
              4'd11: pram_len2[9:4]    <= io_din[5:0];
              4'd12: pram_sad3[7:0]    <= io_din;
              4'd13: pram_sad3[11:8]   <= io_din[3:0];
              4'd14: pram_len3[3:0]    <= io_din[7:4];
              default: pram_len3[9:4]  <= io_din[5:0];
            endcase
            pram_ptr <= pram_ptr + 4'd1;
            if (pram_ptr == 4'd15) pram_act <= 1'b0;
          end else if (cmd_active) begin
            // Each parameter byte lands in its register AS IT ARRIVES - the model both
            // references implement (NP2kai gdc_work writes para[ptr++] per byte; QEMU
            // calls gdc_cmd_csrw/gdc_cmd_csrform per byte). The authentic BIOS sends only
            // TWO CSRW bytes and ONE CSRFORM byte (BANK6@0x49cf, BANK7@0x6a45), so applying
            // at completion never latches either and the text cursor stays dead.
            // The command count stays 3; the extra CSRW byte (address bit 16+) is
            // kept in csr_ead2 because CSRR answers it (see its declaration).
            if ((cur_k == 3'd1) && (param_cnt[1:0] < 2'd2)) begin
              csr_ead[param_cnt[0]] <= io_din;   // ead = p0 | p1<<8 (QEMU gdc_cmd_csrw)
            end
            if ((cur_k == 3'd1) && (param_cnt[1:0] == 2'd2)) begin
              csr_ead2 <= io_din;
            end
            if (cur_k == 3'd2) begin
              case (param_cnt[1:0])
                2'd0:    csr_form[0] <= io_din;
                2'd1:    csr_form[1] <= io_din;
                default: csr_form[2] <= io_din;
              endcase
            end
            if (param_cnt + 3'd1 == ((cur_k == 3'd1 || cur_k == 3'd2) ? 3'd3 : 3'd1)) begin
              cmd_active <= 1'b0;
              param_cnt  <= 3'd0;
              // PITCH is a one-parameter command, so this is its only parameter.
              if (cur_k == 3'd0) pitch <= {io_din[7:1], 1'b0};  // odd bit dropped (NP2kai maketext.c:194)
            end else param_cnt <= param_cnt + 3'd1;
          end
        end
        5'd1: begin  // GDC1 command port
          cur_k <= (io_din == 8'h47) ? 3'd0 : (io_din == 8'h49) ? 3'd1 : (io_din == 8'h4B) ? 3'd2 :
                   (io_din == 8'h06) ? 3'd3 : (io_din == 8'hE0) ? 3'd4 : 3'd5;
          // Every command REPLACES the parameter read-back queue (NP2kai
          // gdc_work: `item->snd = gdc_cmd[data].indatas`, io/gdc.c:327). The
          // two producers are gdc_cmd.tbl's rows with indatas: 0xE0 CSRR answers
          // five bytes {CSRW0, CSRW1, CSRW2&3, 0, 0} (io/gdc.c:328-337) and
          // 0xC0 LPEN three (gdc_cmd.tbl:214) - para[29..31], the never-written
          // light-pen slots, zero since gdc_reset (io/gdc.c:1160).
          gdc_snd_ptr <= 3'd0;
          case (io_din)
            8'hE0: begin
              gdc_snd_cnt <= 3'd5;
            end
            8'hC0: begin
              // para[29..31]: no command writes the LPEN slots, so they hold
              // gdc_reset's zeros whatever CSRFORM holds (io/gdc.c:1160).
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
          // The same reload for PRAM: 0x70+n arms the byte pointer at n, every other command
          // disarms it (gdc_work `item->ptr = gdc_cmd[data].pos;`, io/gdc.c:324).
          pram_act     <= (io_din[7:4] == 4'h7);
          pram_ptr     <= io_din[3:0];
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
            // num 1: mode2 bit 1. It moves no pixel in any reference, and with 0x6A
            // reading 00 on the machine (see the read arm) nothing reads it back.
            // num 3: the EGC/PEGC register write enable. A real guard, not decoration:
            // the firmware always brackets the bits below with it (master.lib EGC_ON;
            // BANK6@0xFFD4F-0xFFD87), and QEMU takes num 2 only while it is set.
            8'h03: mode2_wren <= io_din[0];
            // num 2: EGC extended mode. The EGC's real gate is THIS bit AND the GRCG's
            // CG mode, 0x7C bit 7 - not 0x9A0 bit 2 (ReC98 egc.hpp:58-64; QEMU
            // pc98-vga.c:2465/2559; NP2kai io/gdc.c:534-541 all agree). The GRCG CG mode
            // is decoded in pc9821_grcg, so the EGC gate must be taken from there.
            8'h02: mode2_egc <= mode2_egc_nx;
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
  // bit duties are measured on the real machine with a 2M-sample histogram (docs/probes/GDC.TXT,
  // port 0060 over 0x200000 samples): bit 2 always set, bit 5 ~1.7% (VSYNC, `bit05
  // count=00008E21`), bit 6 ~23.4% (the horizontal blank, 208/848, `bit06 count=00077C8D`;
  // docs/probes/TIME.TXT `high 1.7% of the time and bit6 23.4%`). NP2kai io/gdc.c gdc_i60
  // `if ((remain % gdc.rasterclock) < gdc.hsyncclock)` raises bit 6 once per LINE, vertical-blank
  // lines included, but for cr/x of it (`gdc.hsyncclock = (gdc.rasterclock * cr) / x;`, about 75%
  // with the default SYNC), which the probe's 23.4% refutes; its phase in the line is unmeasured,
  // todo item 23. Bit 0 ~50%. Driving bit 6
  // from the real blanking and bit 0 from a DOT-rate toggle makes every guest poll end.
  //
  // BIT 0'S RATE: the toggle is clocked by `pixel_ce` - the PIXEL_HZ-derived dot enable - and
  // NOT by clk_sys, because a clk_sys count is not a time (AGENTS.md's rates rule: raising
  // clk_sys must not move a guest-visible time); a per-clk_sys toggle would halve its period
  // at 100 MHz (tb_pc9821_sysclk_invariance pins this). THE REAL PERIOD IS UNMEASURED and this choice is not evidence for it: the
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
  // Two bits are enough: the snapshot is taken on the copy edge and compared on cfg_ack_edge, a
  // fixed three clk_sys later (cfg_ack -> two synchroniser flops -> cfg_ack_seen), so at most
  // three writes lie between them and the count's difference is 0..3 - equal mod 4 iff equal.
  reg [1:0] cfg_epoch;       // one count per configuration write (mod 4)
  reg [1:0] cfg_epoch_snap;  // ...as of the copy's own clock edge (raster block below)

  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      cfg_data_d   <= 1'b0;
      cfg_dirty    <= 1'b1;   // force the power-on snapshot at the first frame
      cfg_ack_sync <= 2'b00;
      cfg_ack_seen <= 1'b0;
      cfg_epoch    <= 2'd0;
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
      if (io_wr) cfg_epoch <= cfg_epoch + 2'd1;
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
      v_row0_stale <= 1'b0;
      cfg_epoch_snap <= 2'd0;
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
        // The write epoch as of THIS edge: the ack this copy raises may only
        // clear cfg_dirty while no write has moved past it (see the clear rule).
        cfg_epoch_snap <= cfg_epoch;
        cfg_ack <= ~cfg_ack;
      end
      // The vline-432 walk trigger has read the flag by the end of that scanline.
      if ((vline == wk_slot) && (hdot == HTOT_M1)) v_row0_stale <= 1'b0;
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
  assign o_v_row0_stale = v_row0_stale;
  assign o_vline        = vline;
  assign o_hdot         = hdot;
  assign o_htotal       = HTOTAL;
  assign o_vtotal       = VTOTAL;
  assign o_vbp          = VBP;

  // ---------------------------------------------------------------
  // THE TEXT LINE SEQUENCER: which character row, which font line, for every raster line
  // ---------------------------------------------------------------
  // The text plane is two chips. The master GDC walks the TRAM a character row at a time: it
  // starts each display partition at that partition's start word, and every LR+1 lines (LR =
  // CSRFORM byte 0's low five bits) it advances the row address by the pitch; after a
  // partition's line count it moves to the next partition. The CRTC (0x70-0x7A) owns the line
  // INSIDE the row: PL/BL give the row's first line and its length, CL how many of them show
  // glyph rows, and SSL/SUR/SDR the smooth-scroll region. NP2kai's maketext() is the reference
  // and this block is its per-line loop transcribed (vram/maketext.c:162-435), one loop
  // iteration per clk_sys while it runs; the variables keep NP2kai's names in the comments:
  //   TEXT_LR  = CSRFORM & 0x1f                      (:163 `TEXT_LR = gdc.m.para[GDC_CSRFORM] & 0x1f;`)
  //   topline  = PL >= 16 ? PL - 32 : PL             (:172-177) - PL as a 5-bit SIGNED value
  //   lines    = PL >= 16 ? BL + 1 : BL + 1 - PL, +32 when <= 0 (:174-181) - kept as lines - 1
  //   TEXT_CL  = min(CL, 16)                         (:169-171)
  //   SUR == 0 : wait2 = SSL, TEXT_SDR = SDR + 1     (:186-189)
  //   SUR != 0 : TEXT_SUR = 32 - SUR, TEXT_SDR = -1  (:168, :191)
  // and each loop pass (one raster line OUT when wait2 is 0, a silent pass otherwise):
  //   A  if (!wait1) { if (LRcnt-- == 0) { LRcnt = TEXT_LR; reloadline = TRUE; } } else wait1--;  (:209-217)
  //   B  if (reloadline) { the row address = esi; esi += pitch; }                                  (:218-322)
  //   C  if (!TEXT_SDR && nowline >= topline + ssl) { nowline = topline; TEXT_SDR--; wait1 = ssl; } (:324-328)
  //   D  if (!wait2) { draw line y from (row, nowline); if (!--scroll) next partition, reload }    (:330-420)
  //      else wait2--;
  //   E  nowline++; if (TEXT_SDR && nowline >= lines) { nowline = topline; TEXT_SDR--;
  //        if (++linecnt == TEXT_SUR) { wait2 = ssl; TEXT_SDR = sdr + 1; } }                      (:426-434)
  // The row address is not accumulated: a row is named by its partition and its index k in it,
  // and the fetch forms SAD[p] + k*pitch with the multiply it already had - so partition 0 keeps
  // the scanout's frame-coherent display-start snapshot (v_sad) exactly as before.
  //
  // DEFAULT-MODE IDENTITY. With the CRTC's power-on/DOS registers (PL 0, BL 0x0F, CL 0x10, SSL/
  // SUR/SDR 0: docs/probes/RDBACK.TXT:82-87 `0070=00` ... `007A=00`), LR = 15 and a zero line
  // count, line y is row y>>4, font line y&15, partition 0 - the decode this replaced - so the
  // 25-line picture and every fetch address are unchanged.
  //
  // WHEN IT RUNS. Each run produces ONE output line's state (the n_* registers) and starts on
  // the first dot of a raster line: during line L it computes line L+1, which the fetch reads at
  // L's last cell (the next line's column-0 prefetch) and which becomes the current line (c_*)
  // at L's last dot. The frame restarts the loop (NP2kai draws a frame per maketext call) at
  // the first dot of line VACTIVE-1, so the column-0 prefetch of line 0 has a state, and again
  // at the first dot of the frame's last line, VTOTAL-1, from the registers as they stand then:
  // a vertical-blank write (the VSYNC IRQ fires at vline VACTIVE+VFP) reaches the very next
  // frame. The CRTC registers, LR and the line counts are read LIVE (the CRTC chip has no frame
  // latch); NP2kai samples them once per drawn frame, so a write landing mid-picture moves the
  // rest of that frame here and only the next one there - the recorded divergence (todo item 128).
  //
  // THE 3-BANK KANJI ROW CACHE. pc9821_cg fills the cache bank of the NEXT character row while
  // the current one is drawn, so this block also says, for every line that starts a row, which
  // row comes next (pr_*): the next LR reload in this partition, the next partition when its
  // line count runs out first, or the next frame's first row when the picture ends first. A
  // row's bank is a mod-3 count of reloads (e_ord), so the bank being drawn and the bank being
  // filled always differ, whatever the row heights; the frame's first row takes the bank that
  // follows the last row's (fb), so the fill made during the last row is the one row 0 reads.
  // What this prediction cannot see (a row cut short by smooth-scroll's silent passes, or a row
  // shorter than the walk) draws its kanji from the wrong row - an ANK cell never uses the cache.
  wire [4:0] t_lr   = csr_form[0][4:0];                          // TEXT_LR
  wire [6:0] t_top  = {{2{crtc_pl[4]}}, crtc_pl[4:0]};            // topline, signed
  wire [4:0] t_lnm1 = crtc_pl[4] ? crtc_bl[4:0] : (crtc_bl[4:0] - crtc_pl[4:0]);  // lines - 1
  wire [4:0] t_cl   = crtc_cl[4] ? 5'd16 : crtc_cl[4:0];         // TEXT_CL (CL > 16 -> 16)
  wire [4:0] t_ssl  = crtc_ssl[4:0];
  wire       t_sur0 = (crtc_sur[4:0] == 5'd0);
  wire [4:0] t_surn = 5'd0 - crtc_sur[4:0];                      // TEXT_SUR = 32 - SUR
  wire [5:0] t_sdr1 = {1'b0, crtc_sdr[4:0]} + 6'd1;              // sdr + 1

  function automatic [1:0] ord_inc(input [1:0] o);
    ord_inc = (o == 2'd2) ? 2'd0 : (o + 2'd1);
  endfunction
  function automatic [1:0] ord_dec(input [1:0] o);
    ord_dec = (o == 2'd0) ? 2'd2 : (o - 2'd1);
  endfunction
  function automatic [9:0] len_of(input [1:0] p, input [9:0] l0, input [9:0] l1,
                                  input [9:0] l2, input [9:0] l3);
    case (p)
      2'd0: len_of = l0;
      2'd1: len_of = l1;
      2'd2: len_of = l2;
      default: len_of = l3;
    endcase
  endfunction

  // The loop state (NP2kai's locals).
  reg [4:0] e_lr;     // LRcnt
  reg [4:0] e_w1;     // wait1
  reg [4:0] e_w2;     // wait2
  reg       e_rl;     // reloadline (a partition switch's)
  reg [6:0] e_now;    // nowline, signed
  reg       e_sdrn;   // TEXT_SDR < 0
  reg [5:0] e_sdr;    // TEXT_SDR when >= 0
  reg [5:0] e_lc;     // linecnt, saturating (TEXT_SUR <= 31)
  reg [1:0] e_p;      // scrp / 4: the partition the GDC is in
  reg [9:0] e_scr;    // scroll: lines left in the partition
  reg [9:0] e_kn;     // the row index the next reload takes
  reg [9:0] e_k;      // the row being drawn: its index in its partition...
  reg [1:0] e_rp;     // ...its partition
  reg [1:0] e_ord;    // ...and its cache bank (reloads mod 3)
  reg       e_new;    // the row has not drawn a line yet
  reg       e_busy;   // a run is in progress
  reg       e_r0;     // this run started from the frame's first pass
  reg [1:0] fb;       // the bank the frame's first row takes
  // The produced line (n_*) and the line on screen (c_*).
  reg [9:0] n_k, c_k;
  reg [1:0] n_rp, c_rp;
  reg [6:0] n_now, c_now;
  reg [1:0] n_ord, c_ord;
  reg       n_new, c_new;
  // The row after the one a produced line belongs to (read on a row's first line).
  reg [9:0] pr_k;
  reg [1:0] pr_p, pr_bank;

  // ---- one loop pass, A..E, as next-state expressions ----
  wire       a_cnt  = (e_w1 == 5'd0);
  wire       a_rl   = a_cnt && (e_lr == 5'd0);
  wire [4:0] a_lr   = !a_cnt ? e_lr : a_rl ? t_lr : (e_lr - 5'd1);
  wire [4:0] a_w1   = a_cnt ? 5'd0 : (e_w1 - 5'd1);
  wire       b_rl   = e_rl || a_rl;
  wire [9:0] b_k    = b_rl ? e_kn : e_k;
  wire [9:0] b_kn   = b_rl ? (e_kn + 10'd1) : e_kn;
  wire [1:0] b_rp   = b_rl ? e_p : e_rp;
  wire [1:0] b_ord  = b_rl ? ord_inc(e_ord) : e_ord;
  wire       b_new  = e_new || b_rl;
  wire       sdr_z  = !e_sdrn && (e_sdr == 6'd0);                // TEXT_SDR == 0
  wire [6:0] top_ssl = t_top + {2'b00, t_ssl};
  wire       c_hit  = sdr_z && ($signed(e_now) >= $signed(top_ssl));
  wire [6:0] c_nowv = c_hit ? t_top : e_now;
  wire       c_sdrn = e_sdrn || c_hit;                           // TEXT_SDR-- from 0 is -1
  wire [4:0] c_w1   = c_hit ? t_ssl : a_w1;
  wire       d_out  = (e_w2 == 5'd0);
  wire [9:0] d_dec  = e_scr - 10'd1;
  wire       d_sw   = d_out && (d_dec == 10'd0);                 // `if (!(--scroll))`
  wire [1:0] d_p    = d_sw ? (e_p + 2'd1) : e_p;
  wire [9:0] d_scr  = !d_out ? e_scr
                    : d_sw ? len_of(e_p + 2'd1, pram_len0, pram_len1, pram_len2, pram_len3)
                    : d_dec;
  wire [9:0] d_kn   = d_sw ? 10'd0 : b_kn;                        // esi = the new start word
  wire [4:0] d_w2   = d_out ? 5'd0 : (e_w2 - 5'd1);
  wire [6:0] x_inc  = c_nowv + 7'd1;                             // nowline++
  wire       x_wrap = (c_sdrn || (e_sdr != 6'd0)) &&
                      ($signed(x_inc) > $signed({2'b00, t_lnm1}));
  wire [5:0] x_lci  = (e_lc == 6'd63) ? 6'd63 : (e_lc + 6'd1);
  wire       x_sur  = x_wrap && !t_sur0 && (x_lci == {1'b0, t_surn});
  wire [6:0] x_now  = x_wrap ? t_top : x_inc;
  wire [5:0] x_lc   = x_wrap ? x_lci : e_lc;
  wire       x_sdrn = x_sur ? 1'b0 : c_sdrn;
  wire [5:0] x_sdr  = x_sur ? t_sdr1 : (x_wrap && !c_sdrn) ? (e_sdr - 6'd1) : e_sdr;
  wire [4:0] x_w2   = x_sur ? t_ssl : d_w2;

  // ---- the next row, for the cache walker (only read on a row's first line) ----
  // The next LR reload is c_w1 + a_lr + 1 passes away; the partition's own reload is d_scr + 1
  // outputs away (it lands on the pass after the count runs out); and the picture has `rem`
  // more lines. Ties go the way the loop resolves them: a partition switch and an LR reload on
  // the same pass are ONE reload at the new partition's start (D's esi overrides B's).
  wire [5:0] n_lrm1 = {1'b0, c_w1} + {1'b0, a_lr};
  wire [9:0] e_y    = e_r0 ? 10'd0 : (vline + 10'd1);
  wire [9:0] rem    = VACT_M1 - e_y;
  wire       nx_sw  = d_sw || (d_scr <= {4'd0, n_lrm1});
  wire       nx_fr  = d_sw ? (rem == 10'd0)
                           : ((rem <= {4'd0, n_lrm1}) && (rem <= d_scr));

  // The run starts ONE clk_sys after the line's first dot: the walker samples pr_* on that dot's
  // edge, and the restart test reads geom_d after its one-clk_sys lag behind a frame-boundary
  // geometry change (a one-line picture's VACT_M1 = 0 would otherwise restart line 0's run).
  reg  e_start;
  always @(posedge clk_sys)
    if (!rst_n_sys) e_start <= 1'b0;
    else            e_start <= pixel_ce && (hdot == 10'd0);
  wire e_frame = (vline == VACT_M1) || (vline == VTOT_M1);
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      // The state the loop is in after drawing line 0 of the power-on frame, the default
      // registers': row 0 reloaded (LRcnt = 15), nowline 1, a zero line count wrapped to 1023.
      e_lr <= 5'd15; e_w1 <= 5'd0; e_w2 <= 5'd0; e_rl <= 1'b0;
      e_now <= 7'd1; e_sdrn <= 1'b0; e_sdr <= 6'd1; e_lc <= 6'd0;
      e_p <= 2'd0; e_scr <= 10'h3FF; e_kn <= 10'd1; e_k <= 10'd0; e_rp <= 2'd0;
      e_ord <= 2'd0; e_new <= 1'b0; e_busy <= 1'b0; e_r0 <= 1'b0; fb <= 2'd0;
      n_k <= 10'd0; n_rp <= 2'd0; n_now <= 7'd1; n_ord <= 2'd0; n_new <= 1'b0;
      pr_k <= 10'd1; pr_p <= 2'd0; pr_bank <= 2'd1;
    end else if (e_start) begin
      // A run starts. On the frame's two restart lines the loop's locals are re-initialised
      // (maketext.c:183-206); the run itself begins on the next clk_sys.
      e_busy <= 1'b1;
      e_r0   <= e_frame;
      if (e_frame) begin
        e_lr <= 5'd0; e_w1 <= 5'd0; e_rl <= 1'b0;
        e_w2 <= t_sur0 ? t_ssl : 5'd0;
        e_now <= t_top; e_sdrn <= !t_sur0; e_sdr <= t_sdr1; e_lc <= 6'd0;
        e_p <= 2'd0; e_scr <= pram_len0; e_kn <= 10'd0; e_k <= 10'd0; e_rp <= 2'd0;
        e_ord <= ord_dec(fb); e_new <= 1'b0;
      end
    end else if (e_busy) begin
      // One loop pass. Every register is written once, from the A..E expressions above.
      e_lr <= a_lr; e_w1 <= c_w1; e_w2 <= x_w2; e_rl <= d_sw;
      e_now <= x_now; e_sdrn <= x_sdrn; e_sdr <= x_sdr; e_lc <= x_lc;
      e_p <= d_p; e_scr <= d_scr; e_kn <= d_kn; e_k <= b_k; e_rp <= b_rp; e_ord <= b_ord;
      e_new <= b_new && !d_out;
      e_busy <= !d_out;
      if (d_out) begin
        n_k <= b_k; n_rp <= b_rp; n_now <= c_nowv; n_ord <= b_ord; n_new <= b_new;
        pr_k    <= nx_fr ? 10'd0 : nx_sw ? 10'd0 : b_kn;
        pr_p    <= nx_fr ? 2'd0 : nx_sw ? (e_p + 2'd1) : e_p;
        pr_bank <= ord_inc(b_ord);
        if (b_new && nx_fr) fb <= ord_inc(b_ord);
      end
    end
  end
  // The produced line becomes the line on screen at the raster line's last dot.
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      c_k <= 10'd0; c_rp <= 2'd0; c_now <= 7'd0; c_ord <= 2'd0; c_new <= 1'b1;
    end else if (pixel_ce && (hdot == HTOT_M1)) begin
      c_k <= n_k; c_rp <= n_rp; c_now <= n_now; c_ord <= n_ord; c_new <= n_new;
    end
  end
`ifdef VERILATOR
  // R8: a run ends inside its line (at most 32 silent passes and one drawn one), so the next
  // start never finds it busy.
  always @(posedge clk_sys)
    if (rst_n_sys && e_start && e_busy)
      $error("pc9821_crtc: the text line sequencer was still running at the next line's start");
`endif

  // The start word of partition p (partition 0's is the scanout's frame-coherent snapshot).
  function automatic [15:0] sad_of(input [1:0] p, input [15:0] s0, input [11:0] s1,
                                   input [11:0] s2, input [11:0] s3);
    case (p)
      2'd0: sad_of = s0;
      2'd1: sad_of = {4'h0, s1};
      2'd2: sad_of = {4'h0, s2};
      default: sad_of = {4'h0, s3};
    endcase
  endfunction

  // ---- the cache walker's request (pc9821_cg latches it on a walk's first dot) ----
  // A row's first line asks for the row after it; the vline-432 slot re-walks row 0 with the
  // frame's own display start when the configuration moved after row 0 was filled.
  wire stale_slot = v_row0_stale && (vline == wk_slot);
  assign o_wk_go   = stale_slot || (c_new && v_active);
  assign o_wk_k    = stale_slot ? 10'd0 : pr_k;
  assign o_wk_bank = stale_slot ? fb : pr_bank;
  assign o_v_sad   = (stale_slot || (pr_p == 2'd0)) ? {v_sad_hi, v_sad_lo}
                   : sad_of(pr_p, 16'h0000, pram_sad1, pram_sad2, pram_sad3);

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
  // The LINE's last cell, where the fetch takes the next line's column 0: HACTIVE's last whole
  // cell (s_lc80_r/s_lc40_r, capped at 79/39), not a fixed column 79. With a SYNC block narrower
  // than 80 cells a fixed 79 is never reached, so the prefetch past the line's end (cell AW) was
  // left in the render registers and drawn as the next line's first cell - the core's screenshots
  // of TXTMODE P3/P4 (AW 78/64) showed it; the machine draws the row's own first word there.
  wire last_cell = v_col40 ? (adot[9:4] == s_lc40_r) : (adot[9:3] == s_lc80_r);
  wire [5:0] f_c40 = last_cell ? 6'd0 : (adot[9:4] + 6'd1);
  wire [6:0] f_c80 = last_cell ? 7'd0 : (adot[9:3] + 7'd1);
  // ---- THE FETCHED LINE: the line sequencer's state for this line, or the next one ----
  // The fetch pipeline prefetches the next cell in raster order, so last_cell's fetch is the
  // NEXT raster line's column 0 and reads the sequencer's produced line (n_*); every other
  // fetch reads the line on screen (c_*). (No vline-derived coordinates are needed: the
  // sequencer's line VACTIVE-1 restart already makes n_* the frame's first line at the
  // picture's last line.) The row index is TEN bits, one row per line of the tallest frame:
  // NP2kai steps the row address with no row limit (maketext.c:321 `esi = LOW12(esi +
  // pitch);`), so 2-line rows on 400 lines (200 rows) or LR 5 (67 rows) must not wrap onto
  // row 0; nowline is seven bits signed: a 20-line row runs -2..17.
  wire [9:0] f_k      = last_cell ? n_k   : c_k;
  wire [1:0] f_rp     = last_cell ? n_rp  : c_rp;
  wire [6:0] f_now    = last_cell ? n_now : c_now;
  wire [1:0] f_ord    = last_cell ? n_ord : c_ord;
  wire [3:0] f_raster = f_now[3:0];          // fntline & 0x0f (maketext.c:358-361)

  // TRAM word index of fetched cell: SAD[partition] + k*pitch + cell(80) / +2*cell(40). The
  // fetch address uses its LOW12 (both planes hold 4096 words; maketext.c:196/:416 `LOW12`);
  // bits 15:12 are partition 0's pre-mask display-start tap tb_pc9821_gdc_text reads to prove a
  // 0x1000-word start is in effect.
  wire [15:0] f_sad = sad_of(f_rp, {v_sad_hi, v_sad_lo}, pram_sad1, pram_sad2, pram_sad3);
  // ---- THE ROW BASE, ONE DOT EARLY (the timing seam, part 3) ----
  // f_k * v_pitch registered on pixel_ce: the multiply leaves the per-fetch path (what remains
  // is one adder pair and the mux below; the start word is added there, as it was before the
  // text line sequencer - the shape the multiply keeps to the DSP block it always mapped to). f_k/f_rp and v_pitch/v_sad
  // only move at a line's first dot (the c_* copy and the snapshots land on the HTOTAL-1
  // edge), the last cell's first dot (8 x s_lc80_r / 16 x s_lc40_r, 632 / 624 on an 80-cell
  // line, where the n_* side is selected) and the next cell's first dot (where it switches
  // back) - n_* itself is written in the line's first few dots, long before last_cell - and
  // the dots that CONSUME f_wordidx are
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
    else if (pixel_ce) f_rowbase_r <= {6'd0, f_k} * {8'd0, v_pitch};
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
  // rows.
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
  // walker inside pc9821_cg owns the glyph ADDRESS (the font is in SDRAM); the scanout only
  // needs to know whether the fetched cell is a JIS glyph inside the grid, so that the row cache
  // and the ANK store can be told apart.
  wire [7:0]  f_ku_i  = {1'b0, code_lo_r[6:0]} - 8'h01;   // ku - 0x21
  // The grid is rows ku 0x21-0x7C and columns ten 0x20-0x7F (FONT.ROM's 0x60 cells per row); a
  // column below 0x20 has no slot and draws blank, as both references' all-zero grid outside
  // the loaded range does (NP2kai font/fontv98.c v98knjcpy `for (j=0x20; j<0x80; j++)`, QEMU
  // pc98-vga.c kanji_copy the same). Without the column test the walker's dump offset wraps
  // it into a later row: the 0x0120 a game clears its text plane with drew JIS 0x4241.
  wire        f_row_in = (f_ku_i < 92) && (code_hi_r[6:0] >= 7'h20);   // JIS_ROWS, ten >= 0x20
  // The right half reuses the pair's own row and column and IGNORES its own TRAM code, which
  // is what NP2kai's kanji2nd arm does (bitmap[x] = lastbitp + 0x800). The carried right-half
  // flag must NOT survive the line wrap: last_cell's fetch is the NEXT line's column 0, and
  // both references reset the pair per line (NP2kai maketext.c declares kanji2nd inside the
  // line loop, QEMU pc98-vga.c likewise), so the flag the ADDRESS uses is AND NOT last_cell.
  // Without it, a kanji code in a line's last cell would make the next line's column 0 draw
  // that glyph's RIGHT half - the wrong glyph, at a cell the machine draws as a fresh character.
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
      // A code outside the grid still consumes its right cell: NP2kai sets kanji2nd for every
      // non-gaiji two-byte code but the ver0.78 rows whatever the grid holds (vram/maketext.c
      // :291-294), QEMU likewise (pc98-vga.c `if (lo2 < 0x09 || lo2 >= 0x0c) kanji2nd = 1`), and
      // both then draw that pair from their all-zero slot - a BLANK pair (f_jis_ok clear,
      // r_blank_2nd below), whatever code the right cell carries.
      if (f_jis && !f_pair2nd) begin
        f_jis2nd <= 1'b1;        // this cell is a left half; the next is its right half
        f_jis_ok  <= f_row_in;
      end else begin
        f_jis2nd <= 1'b0;
        f_jis_ok  <= 1'b0;
      end
    end
  end

  // The JIS row cache's read coordinates, packed inside pc9821_cg. Three banks, numbered by the
  // line sequencer's mod-3 count of the GDC's row reloads (ord_inc), carried across the frame
  // boundary (fb): a row draws from the bank its fill was made in, and the walker is always sent
  // to the bank after the one on screen, so the two are never the same bank (cg's assertion).
  assign jc_rd_bank = f_ord;   // the row's mod-3 bank, the one its fill was made in (above)
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
  reg [ 2:0] r_nowh;       // nowline's sign and high bits: {r_nowh, r_raster} is nowline
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
      r_nowh   <= 3'd0;
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
        r_nowh    <= f_now[6:4];
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
  // a row or column the grid does not hold (ku above 0x7C, ten below 0x20), which keeps those cells blank rather
  // than showing a wrapped address's glyph. It covers the kanji left cells, the ver0.78
  // half-width rows (maketext.c:280-296), and the pair's right cell, whose
  // own code is ignored (maketext.c:254 `if (kanji2nd)` comes first). That right cell
  // carries no code of its own on the machine (the ITF's TEXTDISP.X86 leaves it at the
  // cleared 0x0020, and NP2kai/QEMU ignore it), so it usually arrives here as the ANK
  // class with r_font already holding the JIS half - the ANK arm above is what draws it.
  wire       jis_ok   = (|r_code_hi) && !gaiji_ok && r_jis_ok;
  // The right cell of a pair whose code is outside the grid draws nothing of its own (see
  // f_jis_ok): r_jis_2nd with r_jis_ok clear is exactly that cell, since an in-grid pair's
  // right cell always carries r_jis_ok.
  wire       r_blank_2nd = r_jis_2nd && !r_jis_ok;
  wire       glyph_on = (ank_ok || gaiji_ok || jis_ok) && glyph_bit && !r_blank_2nd;

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
  // cur_phase is that count's parity, the cursor VISIBLE while it is 0 (the power-on phase).
  reg        cur_phase;
  // The CHARACTER BLINK's count is frame_cnt[5:4] (the duty test below), so this register is
  // stepped by 16: bits [5:4] run 0,1,2,3 and wrap, which IS NP2kai's `count & 3`. Advancing it
  // once per cur_timing frames is what makes the blink follow the CSRFORM field; an every-frame
  // step would blink 16 of every 64 frames regardless of it.
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
  // The cursor's line test is on nowline, the CRTC's line inside the row, not the font line:
  // `if ((nowline >= (CSRFORM+1 & 0x1f)) && (nowline <= (CSRFORM+2 >> 3)))` (maketext.c:334-335),
  // so a negative nowline (a 20-line row's two leading blank lines) is never inside it.
  wire [6:0]  r_now      = {r_nowh, r_raster};
  wire        csr_row_ok = !r_now[6] &&
                           (r_now[5:0] >= {1'b0, csr_top}) &&
                           (r_now[5:0] <= {1'b0, csr_bot});
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

  // The underline is on the row's LAST line, `(nowline + 1) == lines` (maketext.c:375-376) -
  // line 15 of the 16-line row, line 17 of a 20-line row's -2..17.
  wire ul_on = underline && (r_now == {2'b00, t_lnm1});
  // A glyph line is drawn only for 0 <= nowline < TEXT_CL; every other line of the row draws the
  // cell's colour with no pattern - `text_table[color[x]]`, so reverse and the cursor still
  // fill it (maketext.c:348-374).
  wire glyph_line = !r_now[6] && (r_now[5:0] < {1'b0, t_cl});
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
  // inverted = solid) and stays visible through the blink phases. The line overlays run outside all of it.
  wire glyph_data = glyph_on && r_attr[0] && !blink_off && glyph_line;
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
  assign pix_v_active = v_disp_any;
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
  wire at_line_tick = (hdot == HTOT_M1);
  assign gfx_odd_line = v_mode1_200 && (at_line_tick ? feed_odd : vline[0]);
  assign gfx_mode16   = v_mode16;
  // The DIGITAL palette bytes go out LIVE, not as a frame-boundary snapshot: the real Xe10's
  // 8-colour palette takes each write at once, like its analogue DAC. XE10T /RASTER's DTOGGLE
  // phase (docs/probes/XE10T-XE10-RASTER.TXT:28 `P RASTER DTOGGLE frames=283 to=0 target=1800`,
  // 1024 `out 0xAE` writes toggling digital entry 0 between blue and black over ~9.4 lines,
  // each `out` ~7.8 dots long) filmed staggered blue/black dashes inside every line of the
  // band, the same picture as the analogue TOGGLE phase, where a per-frame latch shows one
  // colour for the whole frame (both references draw the digital bytes per frame: NP2kai
  // vram/scrndraw.c, MAME pc9801_v.cpp; the machine outranks them). A write lands in dig_* on
  // its io_wr edge, as an analogue write lands in pc9821_gfx_palette's table, so the next dot
  // shows it (tb_pc9821_raster_palette).
  assign gfx_dig      = {dig_a8, dig_aa, dig_ac, dig_ae};
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
  // the PEGC's 256-colour palette, out of scope here (left out for area).
  initial begin
    for (pal_i = 0; pal_i < 16; pal_i = pal_i + 1) begin
      po = pal_power_on(pal_i[3:0]);
      // One nibble per lane, split by channel from the {R,G,B} power-on word (the same
      // order pc9821_gfx_palette's live table seeds; a byte-wide seed would put {G,B} in
      // the green lane, so an unwritten entry's green read-back would carry its blue
      // nibble); the seed's purpose is that the read-back is never X and
      // equals what the screen shows before the first guest write.
      pal_g[pal_i] = po[7:4];
      pal_r[pal_i] = po[11:8];
      pal_b[pal_i] = po[3:0];
    end
    // ALL-ZERO, deliberately: a block RAM's output register powers up to zero anyway, and
    // a NON-DEFAULT power-up value on the register that captures a memory read is what
    // makes Quartus refuse to infer the memory at all (measured: `8'hFF`
    // blocks inference, `8'h00` does not).
    pal_g_q = 4'h0;
    pal_r_q = 4'h0;
    pal_b_q = 4'h0;
  end
  always @(posedge clk_sys) begin
    // The 16-colour write: the low nibble (pal_wr_data, what the DAC keeps) into the lane
    // its channel names, at palnum & 15. A lane write is only enabled by its own channel,
    // which is the whole-lane shape that infers; a sub-word write into a wide word does not.
    if (pal_wr_en && pal_wr_chan == 2'd0) pal_g[pal_sel[3:0]] <= pal_wr_data;   // 0xAA green
    if (pal_wr_en && pal_wr_chan == 2'd1) pal_r[pal_sel[3:0]] <= pal_wr_data;   // 0xAC red
    if (pal_wr_en && pal_wr_chan == 2'd2) pal_b[pal_sel[3:0]] <= pal_wr_data;   // 0xAE blue
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
  // THE VSYNC PIN CHANGES ON THE HSYNC LEADING EDGE. The uPD7220 starts each scan line with its
  // HSYNC (MAME upd7220.cpp update_hsync_timer `next_x = state ? m_hs * horiz_mult : 0` - the pulse
  // occupies x = 0..HS) and moves VSYNC at x = 0 of its line (update_vsync_timer
  // `screen().time_until_pos(next_y, 0)`), so on the pin VSYNC switches together with an HSYNC
  // leading edge. This raster numbers its lines from the first active dot instead, which put the
  // pin's VSYNC edge HS + HBP dots after the hsync (128 dots for the default block): mid-line, and
  // in the line-doubled picture at a line's active start, where sys_top's composite sync then
  // flips mid-line. The pin is therefore taken from the line count as of the last HSYNC leading
  // edge (vline + 1 from HS_ON on). in_vsync itself - the status bit, the vblank IRQ and their
  // capture-pinned phase (vline 407) - is unchanged.
  wire [9:0] vline_hs = (hdot < HS_ON) ? vline : (vline == VTOT_M1) ? 10'd0 : vline + 10'd1;
  wire in_vsync_pin = (vline_hs >= VS_ON) && (vline_hs < VS_OFF);
  assign vs_out = ~in_vsync_pin;
  assign de_out = h_active && v_disp_any;
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
      // 0x68: the mode flip-flops, bit 7 (DISP) reading 0 although it is set. The Xe10 reads
      // 0x18 at the DOS prompt after the ITF's `mov al,0x0F / out 0x68,al` (BANK4@0x24C0)
      // turned the display on (docs/probes/PORTS.TXT, MEMSW.TXT, XE10CFG-XE10-CFGWR.TXT
      // `MODE68 before/after-0C 18 18`), while FF6 reads back as written
      // (XE10CFG-XE10-P6INIT.TXT `MODE68 before/after-0D/after-0C 18 58 18`). NP2kai's gdc_i68
      // returns the whole byte (0x98); the captures overrule it. With the display off the bit
      // reads 0 as well: docs/probes/KIT1-XE10-CFGWR.TXT:11
      // `MODE68OFF before/after-0E/after-0E-20ms/after-0F 18 18 18 18`.
      5'd3:  io_dout_r = {1'b0, mode1[6:0]};
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
      // bus anyway: `port=007C before=FF wrote=5A after=FF back=FF` (0x5A is not 0xFF, so
      // no live register is behind the read). The GRCG's mode still reaches
      // its consumers as a signal (pc9821_grcg owns it; the EGC gate takes it directly),
      // so only the guest read is open bus. The 16-bit `in ax,7Ch` FOLD
      // (pc9821_iobus's word-read termination fills lane 1 with 0xFF) and this LOW lane make
      // `in ax,7Ch` read 0xFFFF, the Xe10's value
      // (docs/probes/XE10T-XE10-AUDIT.TXT W007C `w1=FFFF`).
      5'd12: io_dout_r = 8'hFF;
      // 0x6A READS 00 on the machine, in the 16-colour and the 256-colour state alike:
      // docs/probes/KIT1-XE10-PEGCRD.TXT:3 `MODE 6A=00 9A0_04=01` (16 colours) and
      // KIT1-XE10-PEGCRD.TXT:14 `MODE 6A=00 9A0_04=00 9A0_07=00 9A0_08=01 9A0_0A=01` (256
      // colours), as docs/probes/PEGCRD-XE10.TXT reads it too. NP2kai gdc_i6a returns
      // gdc.mode2 (io/gdc.c:703); the capture outranks it. The mode bits still reach the
      // 0x9A0 query (gdc_ff2_state) and the display.
      5'd4:  io_dout_r = 8'h00;
      // NP2kai gdc_ia8 returns gdc.palnum VERBATIM in analogue modes (io/gdc.c:913-919):
      // out 0xA8,0xAB / in 0xA8 reads 0xAB, not 0x0B. This is the ANALOGUE path: the
      // machine capture that settles the DIGITAL path below ran in
      // DIGITAL mode (probes/RDBACK.TXT:147 mode bytes FF1/FF2 = 18/00).
      // The DIGITAL bytes read back MASKED with 0x77 (bits 0-2 + 4-6; bit 3 undefined,
      // bit 7 unused): probes/RDBACK.TXT:148-151 `port=00A8 before=37 wrote=AB after=23`,
      // `00AA/AC/AE wrote=FF after=77`. Both software models answer the raw byte
      // (NP2kai gdc_ia8/iaa/iac/iae, io/gdc.c:913-954), so the capture is the sole source.
      // The mask is applied at the READ PORT only: the capture proves the read, and the
      // digital display decode (pc9821_gfx_palette's digpal) uses bits 0-2 and 4-6 alone,
      // so whether the hardware's stored byte is masked too is unobservable here.
      5'd20: io_dout_r = (mode2_16color || mode2_256col) ? pal_sel : (dig_a8 & 8'h77);
      // 16-colour analogue: the LOW NIBBLE only, upper four bits 0 (docs/probes/PEGCRD-XE10.TXT
      // `WROTE_R=FF G=00 B=7F READ_R=0F G=00 B=0F`). NP2kai io/gdc.c gdc_iaa/iac/iae
      // returns the full written byte; the capture outranks it. The digital bytes carry
      // the machine's 0x77 mask (see 5'd20 above).
      // In 256-colour mode the PEGC mirror answers the FULL byte at the unmasked
      // index (NP2kai gdc_iaa/iac/iae; MAME returns 0 - the recorded divergence).
      5'd22: io_dout_r = mode2_256col ? pal256_rd_q[7:0]  :
                         mode2_16color ? {4'b0, pal_rd_q[3:0]}   : (dig_aa & 8'h77);   // 0xAA = G
      5'd23: io_dout_r = mode2_256col ? pal256_rd_q[15:8] :
                         mode2_16color ? {4'b0, pal_rd_q[7:4]}  : (dig_ac & 8'h77);   // 0xAC = R
      5'd24: io_dout_r = mode2_256col ? pal256_rd_q[23:16]:
                         mode2_16color ? {4'b0, pal_rd_q[11:8]} : (dig_ae & 8'h77);   // 0xAE = B
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

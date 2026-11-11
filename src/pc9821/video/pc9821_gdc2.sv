// PC-9821 GDC2 (the graphics GDC) display-address generator.
//
// The slave GDC's SCROLL parameter block, its START/STOP display latch, and the byte
// address of the raster line being scanned (gfx_line_addr) that pc9821_gvram_scan's
// line fetch consumes: the part of the GDC that the graphics scanout asks about. The
// raster and the text render are pc9821_crtc's, and the glyph path is pc9821_cg's.
//
// One clock: clk_sys gated by pixel_ce, the same enable the raster counts on. There is
// no second video clock.
`default_nettype none

module pc9821_gdc2 #(
    // clk_sys in Hz: the fixed-rate pace enables below derive real time from it.
    parameter integer SYS_FREQ = 50_000_000,
    // THE DRAW PACING, a COMPILE-TIME choice (build_profile.py's --gdc-write-pace and
    // --gdc-fig-pace write it into z486_mister.sv, pc9821_system passes it down; no runtime
    // mux). 0 = today's engine: a WRITE walks at clk_sys/GVRAM speed, a figure step takes
    // FIG_PACE + 1 dot clocks. N = each WRITE unit / each figure step takes N ns of real time
    // at any clk_sys (pc9821_gdc2_pace below). The Xe10's 2.5 MHz GDC takes 1.40 us for both:
    // GDCTIME WDAT_N0001 26176 and WDAT_N0257 907235 mean milli-ticks of the 2.4576 MHz PIT,
    // (907235 - 26176) / 256 = 3442 per word, and LINE_N1025 3551470 / LINE_N2049 7078352,
    // (7078352 - 3551470) / 1024 = 3444 per dot (docs/probes/gdc-conformance/xe10-2.5MHz/
    // GDCTIME.CSV), 1.4005 and 1.4014 us: 3.5 cycles of the 2.5 MHz GDC clock, 1400 ns. With
    // the parameter 0 the paced branch const-folds away.
    parameter integer WRITE_PACE_NS = 0,
    parameter integer FIG_PACE_NS = 0
) (
    input wire clk_sys,
    input wire rst_n_sys,
    input wire pixel_ce,

    // The device bus. 0xA0 is the parameter port, 0xA2 the command port.
    input  wire       io_wr,
    // The one-cycle read strobe: 0xA2's parameter read-back queue pops on it
    // (NP2kai gdc_ia2, io/gdc.c:813-820) - exactly one byte per CPU read.
    input  wire       io_rd,
    input  wire [7:0] io_addr,
    input  wire [7:0] io_din,
    output wire [7:0] io_dout,

    // Raster handshake from pc9821_crtc.
    input wire        frame_end,     // the last dot of the frame
    input wire        cfg_snap,      // frame_end && the configuration-dirty bit
    input wire        cfg_pending,   // that dirty bit alone: a snapshot WILL fire at this frame's end
    input wire [9:0]  vline,
    // The frame length the raster is running: the wrapped display-line decode below turns
    // into the next frame's rows 0/1 at this many lines.
    input wire [9:0]  vtotal,
    // The MASTER's displayed VBP, pc9821_crtc's SYNC byte 7 >> 2: the slave's window is
    // relative to it - NP2kai dispsync_renewalvertical.
    input wire [5:0]  m_vbp,
    input wire        display_page,  // port 0xA4's register
    // The PEGC 256-colour select (pc9821_crtc's mode2_256col): the packed display walks
    // its partitions as NP2kai's makegrphex does (see the walker below).
    input wire        pegc_256,
    // The GDC clock is 5 MHz: BOTH FF2 clock bits set (0x6A dat 0x83 and 0x85, pc9821_crtc's
    // gdc_clock == 2'b11). NP2kai's packed walk steps PITCH words there and 2 x PITCH at
    // 2.5 MHz (vram/makegrex.c:287-291 `if (!(gdc.clock & 0x80)) mg.pitch <<= 1;`; its 0x80
    // flag follows `gdc.clock == 0x03` at the frame, pccore.c:1550-1551).
    input wire        gdc_5m,
    input wire        stat_blank,    // ~de_ff[1]: status bit 6
    input wire        stat_vsync,    // vs_sync_ff[1]: status bit 5

    // GDC2 SCROLL display start: the GVRAM byte address of the raster line being
    // scanned now. Bit 15 is the 0xA4 display page, bits 14:0 the offset the graphics
    // GDC's display address counter has reached (the planar walk: makegrph's LOW15).
    output wire [15:0] gfx_line_addr,
    // The PACKED walk's own page bit - SCROLL start word bit 14 doubled into the
    // walk's bit 15 (NP2kai's packed arm LOW16(vad << 1), vram/makegrex.c:199; MAME's
    // `& 0xffff` walk, pc9821.cpp:112). The packed 256-colour scanout folds it with the
    // 0xA4 term; the planar scanout must NOT see it (its walk is 15-bit and wraps
    // inside the displayed page). Latched with the SCROLL block at cfg_snap, so the
    // packed page swaps at the frame boundary - the machine's "full frames" swap.
    output wire        gfx_walk_page,
    // Graphics display enable: the slave GDC's own START/STOP latch, which the
    // compositor's grph_disp input needs. Encoding in gdc2_grph_start below.
    output wire        gfx_disp,
    // The raster line is outside the graphics window the slave's SYNC sets - above grph_vbp
    // or at/below grphymax: the compositor shows no graphics there, NP2kai's black lines.
    output wire        gfx_win_off,
    // The compositor's graphics enable: the START/STOP latch AND the slave SYNC's window,
    // in BOTH display modes. NP2kai's packed scan (vram/makegrex.c makegrphex) starts at
    // `mg.liney = dsync.grph_vbp` and stops at `if (mg.liney >= dsync.grphymax)` exactly
    // like the planar one, and dispsync_renewalvertical blanks outside that window for
    // both (MAME applies no window and is outranked).
    output wire        gfx_grph_on,

    // ---- The WRITE engine's GVRAM visits (the GDC2 WRITE slice) ----
    // The route the draw takes is LATCHED at the command (NP2kai gdcpset_prepare picks
    // its pset functions once per draw, io/gdc_pset.c:117-137), from these two gates:
    // `egc_mem_gate` is the EGC's dispatch gate (its enable ANDed with the GRCG's
    // mode bit 7 - pc9821_system's gdc_egc_mem_gate, NP2kai VOPBIT_EGC && VOPBIT_GRCG)
    // and `grcg_cg_gate` is that same mode bit 7 alone, which NP2kai reads as
    // gdcwithgrcg's 0x8 bit (`grcg.gdcwithgrcg = (dat >> 4) & 0x0c`, so bit 3 of it is
    // the mode register's bit 7, io/crtc.c:28) and dispatches withtdw/withrmw on.
    input  wire        egc_mem_gate,
    input  wire        grcg_cg_gate,
    // The CPU's access page (port 0xA6): a draw goes to the page the CPU sees
    // (NP2kai gdcpset_prepare/gdcsub_write take `gdcs.access` as the VRAM half),
    // latched at the command so a mid-draw 0xA6 switch cannot split a draw.
    input  wire        access_page,
    // One store/read visit at a time on pc9821_gvram_share's GDC side: `mem_valid`
    // holds until `mem_ready`; a read's datum answers later on `mem_resp`/`mem_rdata`
    // (the responder contract: the strobe never shares the ready's cycle). The
    // operands are the CPU plane-window shape - {page, plane lane, plane byte offset,
    // dword lanes} - so the GRCG/EGC store paths and the plain lane walk treat a GDC
    // visit exactly as they treat the CPU access of the same shape.
    output reg         mem_valid,
    input  wire        mem_ready,
    output reg         mem_write,
    output reg         mem_route_egc,
    output reg         mem_route_grcg,
    output reg         mem_page,
    output reg  [1:0]  mem_plane,
    output reg  [14:0] mem_offset,
    output reg  [31:0] mem_din,
    output reg  [3:0]  mem_be,
    input  wire        mem_resp,
    input  wire [31:0] mem_rdata
);

  // ---------------------------------------------------------------
  // GDC2 (the graphics GDC) SCROLL: a SECOND chip with its own parameter RAM, which
  // is why it is not pram_scr. 0xA0 is its parameter port, 0xA2 its command port.
  // Its SCROLL block is 16 bytes - four partitions of {start word, {im, lines x 16}}
  // (NP2kai io/gdc_cmd.h GDC_SCROLL = 12, io/gdc_cmd.tbl row 0x70 `{GDC_SCROLL+0, 16, 0, 1}`).
  // The last eight are also TEXTW's: 0x78+k writes para[GDC_TEXTW + k] = para[GDC_SCROLL + 8 +
  // k] (gdc_cmd.h `GDC_TEXTW = (GDC_SCROLL+8)`, gdc_cmd.tbl rows 0x78-0x7F), which is where
  // partitions 3 and 4 live - the firmware's own mode set clears them with 0x78 and eight
  // zeros. ALL FOUR partitions are displayed: NP2kai's makegrph walks 1, 2, 3, 4 and back to 1
  // until the screen is full, so a game whose partitions 1 and 2 add up to less than the
  // display shows partition 3 below them (the Policenauts report).
  // ---------------------------------------------------------------
  reg [7:0] gdc2_scr[0:15];
  reg [3:0] gdc2_ptr;   // next block byte; 0x70+k starts at k (0..15)
  reg [4:0] gdc2_left;  // parameter bytes the command still owes (16 - k), 0 = none
  // The slave CSRFORM's line repeat lr-1, captured from 0xA2 <- 0x4B + its ONE 0xA0 byte
  // (the firmware's own transaction, BANK6@0x787e-0x788c); lr-1 = 1 is the 200-line
  // display's line DOUBLING - the same GDC line presented on two raster lines. The odd
  // raster line of the pair shows TEXT ONLY when MODE FF1 bit 4 is set (the interleave
  // split is pc9821_gvram_scan's fetch skip and pc9821_video_mixer's gate, NP2kai
  // vram/makegrph.c:155 / vram/sdraw.mcr:199-243); the address step below is unchanged.
  reg [4:0] gdc2_lr;
  // GDC2 graphics display, the slave chip's half of one mechanism. NP2kai keeps one
  // display flag per GDC driven from one command space (io/gdc.c:268 picks textdisp for
  // the master and grphdisp for the slave), so the slave's latch takes the same four
  // bytes: 0x0D/0x6B set it, 0x0C/0x05 clear it, and the SYNC pair 0x0F/0x0E follows
  // their own bit 0. Reset leaves display OFF, so a guest that never issues START sees
  // the black-where-graphics-would-be picture.
  reg       gdc2_grph_start;
  // The slave's OWN SYNC block: the eight parameter bytes SYNC_ON/OFF takes on 0xA0 after
  // the command on 0xA2 (io/gdc_cmd.tbl:24-25). The raster's timing is the MASTER's block's
  // (NP2kai gdc_updateclock() reads gdc.m.para, io/gdc.c:383-391), but the slave's block is
  // NOT inert: its VBP and AL set the graphics plane's vertical window. A slave SYNC byte marks
  // the graphics screen dirty (io/gdc_cmd.tbl gdc_dirtyflag[1]: GDCSCRN_EXT, AL also ALLDRAW2),
  // which runs dispsync_renewalvertical() (pccore.c:1529-1533): grph_vbp = the slave's VBP minus
  // the master's (0 if the master's is larger) and grphymax = ((AL - 1) & 0x3ff) + 1 + grph_vbp
  // (vram/dispsync.c), and makegrph draws the walk from screen line grph_vbp up to grphymax
  // (vram/makegrph.c:363 `mg.liney = dsync.grph_vbp`, :169 `>= dsync.grphymax`), the lines
  // outside it black (dispsync.c ZeroMemory of np2_vram above grph_vbp and below grphymax).
  // So bytes 6/7 (AL and VBP) are kept; the others have no consumer here. The eight bytes must
  // also NOT be executed as commands: without the capture below, a byte >= 0x70 starts a SCROLL
  // and a 0x49/0x4B byte arms a CSRW/CSRFORM capture, so a guest's graphics-GDC sync block would
  // silently reprogram the scanout's display address.
  // The power-on values are the firmware's slave block's (`90 65`: AL 400, VBP 25, the master's
  // own), so the window is the whole display until a guest moves it.
  reg [9:0] gdc2_sal;
  reg [5:0] gdc2_svbp;
  reg       gdc2_sync_pend;
  reg [2:0] gdc2_sync_cnt;

  // The slave's CSRW parameter block, captured so CSRR can answer it (NP2kai's
  // gdc.s.para layout): 0xE0 CSRR answers {CSRW0, CSRW1, CSRW2&3, 0, 0}. The
  // CSRFORM block (para[9..11]) is deliberately NOT kept: nothing reads it back,
  // only byte 0's low five bits have a consumer (the line repeat above), and
  // 0xC0 LPEN does NOT answer it - LPEN is para[GDC_LPEN..2] = para[29..31]
  // (io/gdc_cmd.h:34,38: GDC_CSRFORM = 9, GDC_LPEN = 29), slots no command writes (no gdc_cmd.tbl row stores
  // to pos 29) which gdc_reset zero-fills (io/gdc.c:1160): 00 00 00.
  reg [7:0] gdc2_csrw[0:2];
  // The armed parameter capture (a command arms one block; a new command discards it,
  // NP2kai gdc_work taking the command branch first). RCV_VECTW/RCV_CODE/RCV_MASK are
  // the GDC2 WRITE slice: VECTW (0x4C) keeps eleven bytes (io/gdc_cmd.tbl row 0x4c), MASK
  // (0x4A) two, and the WRITE family's data bytes land in GDC_CODE - NP2kai's
  // `item->ptr = GDC_CODE; item->rcv = 2/1/0` in the `(data & 0x60) == 0x20` arm
  // (io/gdc.c gdc_work).
  // RCV_PITCH is PITCH (0x47): one byte (io/gdc_cmd.tbl row 0x47, pos GDC_PITCH).
  localparam [2:0] RCV_NONE = 3'd0, RCV_CSRW = 3'd1, RCV_CSRFORM = 3'd2,
                   RCV_VECTW = 3'd3, RCV_CODE = 3'd4, RCV_MASK = 3'd5,
                   RCV_ZOOM = 3'd6, RCV_PITCH = 3'd7;
  reg [3:0] gdc2_recv_left;  // parameter bytes the armed block still owes (0..11)
  // The PITCH command's byte (gdc.s.para[GDC_PITCH]); its reset value is NP2kai
  // gdc_biosreset's `gdc.s.para[GDC_PITCH] = 40` (io/gdc.c:1107). Both display walks read it.
  reg [7:0] gdc2_pitch;
  reg [2:0] gdc2_recv_tgt;   // which block
  reg [3:0] gdc2_recv_ptr;
  // The slave's parameter read-back queue (gdc.s.snd/para): loaded by gdc_cmd.tbl's
  // two indatas rows (0xE0 = 5 bytes, 0xC0 = 3), replaced by any new command
  // (gdc_work, io/gdc.c:327), popped one byte per 0x62... per 0xA2 read. gdc2_snd_q
  // is the read-data register: GDC-block reads are captured one cycle after the
  // strobe (device_rd_wait), so the returned byte must survive the advance.
  reg [7:0] gdc2_snd[0:4];
  reg [2:0] gdc2_snd_cnt;
  reg [2:0] gdc2_snd_ptr;
  reg [7:0] gdc2_snd_q;

  // ---- The WRITE family's parameter state (the GDC2 WRITE slice) ----
  // A command byte in 0x20..0x3F is a WRITE-family transfer (NP2kai gdc_work's
  // `(data & 0x60) == 0x20` arm): its low bits are the transfer width and the ROP, its
  // data bytes land in GDC_CODE, and the command byte itself is kept at GDC_WRITE (the
  // ROP source, `item->para[GDC_WRITE] = data`). Execution fires when the LAST data byte
  // lands and `(cmd & 0xe4) == 0x20` - exactly NP2kai's `(!(item->rcv)) &&
  // (((item->cmd) & 0xe4) == 0x20)` term, so the 0x08-width commands (which take no
  // data byte) never execute and the 0x24-bit commands never do either.
  reg [7:0] gdc2_wcmd;
  reg [7:0] gdc2_code[0:1];  // the write data (the WDAT register), raw parameter bytes
  reg [7:0] gdc2_vect[0:10]; // VECTW's eleven parameter bytes
  reg [7:0] gdc2_mask[0:1];  // MASK's two parameter bytes
  // The WRITE trigger below (`draw_fire_w`) is combinational and consumed in this
  // module's one sequential block alone, so the one-shot's set and clear cannot collide
  // by source order (the single-cycle event discipline R1/R2). A trigger only ever finds
  // the engine empty: while a job is queued or walking the parser is held and later bytes
  // wait in the command FIFO (cf_hold_w below), so no job is dropped and none overtakes.

  // ---- The WRITE engine's job (the GDC2 WRITE slice) ----
  // The job is SNAPSHOTTED at the trigger into `pend` (the parse's registers are free
  // to move afterwards - a later MASK/CSRW/VECTW must not retarget a draw already
  // queued), and the engine drains `pend` into its working registers. The plane is the
  // CSRW block's bits 15:14 through NP2kai's gdcplaneseg[] = {VRAM_E, VRAM_B, VRAM_R,
  // VRAM_G} (io/gdc_sub.c), so in the plane-lane order the GVRAM uses (0 = B at
  // 0xA8000, 1 = R, 2 = G, 3 = E) the map is GDC plane n -> lane n-1 (mod 4).
  localparam [2:0] D_IDLE = 3'd0, D_RD = 3'd1, D_RDW = 3'd2,
                   D_WR = 3'd3, D_NEXT = 3'd4,
                   D_FSTEP = 3'd5, D_FADV = 3'd6,   // the figure engine's step and advance
                   D_WPACE = 3'd7;   // a paced WRITE unit waits out its period (WRITE_PACE_NS)
  reg [2:0]  d_state;
  reg [15:0] d_left;      // units still to paint AFTER the current one: VECTW[1..2], i.e. NP2kai's leng - 1
                          // (leng is 1..65536; counting it down to 0 instead of 1 saves the +1 and a bit)
                          // A FIGURE counts its steps here too (see the figure engine below).
  reg [15:0] d_waddr;     // CSRW's low 16 bits: {plane, word}. A WRITE keeps the plane; a figure carries into it
  reg  [1:0] d_rop;       // the command byte's low two bits
  reg  [2:0] d_ope;       // VECTW byte 0's low three bits: the direction (vectdir[]); a figure's turning direction
  reg [15:0] d_color;     // INTERNAL-domain write pattern; a figure's rotating line pattern
  reg [15:0] d_mask;      // INTERNAL-domain write mask (the dot positions painted)
  reg        d_route_egc, d_route_grcg;   // LATCHED at the trigger (gdcpset_prepare)
  // The queued job, byte-exact snapshots of the parse's registers at the trigger -
  // only the bits the decode reads (the rest of each byte has no consumer here).
  reg  [3:0] pend_wctl;   // {wcmd[4:3], wcmd[1:0]}: the width and the ROP
  reg        pend_wg;     // CSRW byte 2 bit 3: CURS.WG
  reg  [7:0] pend_code0, pend_code1;
  reg  [7:0] pend_csrw0, pend_csrw1;
  reg  [7:0] pend_mask0, pend_mask1;
  reg  [2:0] pend_dir;    // VECTW byte 0's direction
  reg  [7:0] pend_vect1, pend_vect2;
  reg        pend_egc, pend_grcg, pend_page;
  reg        pend_valid;

  // ---- The figure engine (FIGS/FIGD/GCHRD: dot, line, arc, rectangle, character) ----
  // The oracle is the Xe10's own conformance capture (docs/probes/gdc-conformance/
  // xe10-2.5MHz): GDCDRAW's dot, 288 canonical and 12 raw-DDA lines and the rectangles,
  // GDCGCHR's 512 one-hot characters, area fills, zoom, slant and PRAM rows, GDCROP's
  // FIGD ROP/pattern rows. The step rules below reproduce every one of those rows (pixels
  // AND the cursor the CURD read-back reports); they are MAME upd7220.cpp's draw_line,
  // draw_rectangle, draw_char and next_pixel, which the capture confirms. NP2kai's
  // gdcsub_vectl divides (d1 * i) / dc and ignores D and D2, which the machine REFUTES:
  // GDCDRAW RAW_DDA_00 and RAW_DDA_01 differ only in D (-7 / -1) and the Xe10 draws
  // different pixels. Where the capture is silent the order is NP2kai (one dot for a
  // plain FIGD - gdcsub_vectp; four rectangle sides whatever DC - gdcsub_vectr; the
  // pattern advancing once per plotted dot - gdcpset; the VECTW reset after the draw -
  // gdc_vectreset) and then the uPD7220 datasheet's parameter set (the arc, below).
  //
  // The engine walks ONE STEP per visit, the WRITE engine's own visit protocol, and paces
  // each step to the device: a step takes FIG_PACE + 1 dot clocks of pixel_ce, which follows
  // the raster's dot clock and so the video mode, not the GDC clock: 14 dot clocks are 0.665 us
  // at the 24 kHz 21.0526 MHz dot and 0.556 us at the 31 kHz 25.168 MHz one. The Xe10 draws a
  // dot per 1.40 us at its 2.5 MHz GDC clock
  // (GDCTIME LINE_N1025/LINE_N2049: (7069000 - 3542000) / 1024 = 3444 milli-ticks of the
  // 2.4576 MHz PIT per dot) and NP2kai charges 0.72 us per dot (gdc_sub.c
  // calc_gdcslavewait: `clk *= 27648; ... clk /= 15625;` base clocks), so the engine is at
  // least as fast as either - the 5 MHz chip included - and its busy time is a dot-clock
  // count, never a clk_sys count.
  localparam [3:0] FIG_PACE = 4'd13;
  localparam [2:0] T_DOT = 3'd0, T_LINE = 3'd1, T_ARC = 3'd2, T_RECT = 3'd3, T_CHAR = 3'd4;
  reg        fig_pend;    // FIGD/GCHRD parsed, the engine not yet started
  reg        fig_gc;      // ...and it was GCHRD (0x68)
  reg        d_fig;       // the engine is drawing a figure
  reg  [2:0] f_type;
  reg        f_slant;     // FIGS P1 bit 7 (SL): the slanted character's turns
  reg [13:0] f_d;         // line D / arc decision / character rows still to draw
  reg [13:0] f_d1;        // line and arc D1 / rectangle side A
  reg [13:0] f_d2;        // line and arc D2 / rectangle side B / character width
  reg [13:0] f_dm;        // arc: steps still to skip before the first plotted dot (DM)
  reg  [1:0] f_side;      // rectangle: the side being drawn
  reg        f_sstart;    // rectangle: this step is a side's first (the corner turn)
  reg  [3:0] f_zd, f_zdc; // character: the dot and pass repeats (ZOOM)
  reg  [2:0] f_row;       // character: the PRAM row (i & 7)
  reg        f_par;       // character: the pass parity (odd passes walk back)
  reg  [3:0] f_pace;
  // GCHRD's zoom: ZOOM (0x46) takes one parameter byte whose low nibble is the
  // graphics-character magnification - 1 (NP2kai gdc_cmd.tbl row 0x46 `{GDC_ZOOM, 1, 0, 1}`
  // and gdc_sub.c `multiple = (gdc.s.para[GDC_ZOOM] & 15) + 1`; GDCGCHR ZOOM_01..ZOOM_16).
  reg  [3:0] gdc2_zoom;

  // ---- The command FIFO (the uPD7220's 16-entry FIFO) ----
  // While a draw (a WRITE or a figure) is queued or running, the chip keeps taking command
  // and parameter bytes into its FIFO and executes them after the draw: the Xe10 reads the
  // status as 0x0C all through a draw (GDCFIFO DRAW_BURST - FIFO EMPTY and DRAWING both
  // set), so a guest does not wait before writing its next CSRW/FIGS/FIGD/WDAT. The bytes
  // written while the engine holds the parser are queued here IN ORDER and replayed through
  // the same parser afterwards, one every other clk_sys, so each command sees the cursor
  // the draw before it left (NP2kai gdc_work runs each WRITE to completion before it parses
  // the next byte, io/gdc.c:347-349 `if ((!(item->rcv)) && (id == GDCWORK_SLAVE) &&`). With
  // no draw in flight nothing is queued and every byte reaches the parser in its own cycle.
  (* ramstyle = "M10K" *) reg [8:0] cf_mem [0:15];   // {0xA2 command, byte}
  reg  [8:0] cf_q;        // the popped entry (the memory's read register: no reset)
  reg  [3:0] cf_wp, cf_rp;
  reg  [4:0] cf_cnt;
  reg        cf_pop_v;    // cf_q holds a popped entry the parser takes this cycle

  // The GDC's bit order is the uPD7220's: bit 0 of a word is the LEFTMOST pixel, so a
  // GDC word read by the CPU arrives with each byte's bits reversed. Machine-pinned:
  // GDCCURS's MASK rows (docs/probes/gdc-conformance/xe10-2.5MHz/GDCCURS.CSV -
  // `MASK_0001 ... mask-gdc=0001 expected-cpu=0080`, `MASK_8000 ... 8000 expected-cpu=0100`)
  // and the WDAT rows' `internal-mask`/`cpu-mask` columns. NP2kai's gdcsub_write stores
  // its word unreversed and is REFUTED here; the capture wins (evidence hierarchy).
  function automatic [7:0] rev8(input [7:0] b);
    begin
      rev8 = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
    end
  endfunction
  function automatic [15:0] rev16(input [15:0] w);
    begin
      rev16 = {rev8(w[15:8]), rev8(w[7:0])};
    end
  endfunction

  // The unit's word, exactly the machine's WDAT_WORD rows (STRICT; the same table the
  // FIGD_ROP DOT rows give per dot, io/gdc_pset.c's psettbl): replace paints the masked
  // bits with the pattern's (clearing where the pattern bit is 0 - `W_0_FFFF_0000_0001`
  // lands FF7F), complement xors them (`W_1_0000_0001_0001` -> 0080), clear CLEARS the
  // masked bits where the pattern bit is 1 (`W_2_FFFF_0001_A55A` -> 5AA5), set sets them
  // (`W_3_0000_0001_A55A` -> A55A). NP2kai's gdcsub_write case 0x02 is old & (data &
  // mask) and is REFUTED by the W_2 rows; the machine wins.
  function automatic [15:0] gdc_rop16(input [1:0] op, input [15:0] old,
                                      input [15:0] col, input [15:0] msk);
    reg [15:0] paint;
    begin
      paint = col & msk;
      case (op)
        2'd0:    gdc_rop16 = (old & ~msk) | paint;
        2'd1:    gdc_rop16 = old ^ paint;
        2'd2:    gdc_rop16 = old & ~paint;
        default: gdc_rop16 = old | paint;
      endcase
    end
  endfunction

  // The WRITE trigger: the LAST data byte of a WRITE-family command that will execute
  // (NP2kai gdc_work: `(!(item->rcv)) && (((item->cmd) & 0xe4) == 0x20)` after a data
  // byte, so the 8'h08-width and 0x24-bit commands never fire). Combinational, consumed
  // in this block alone - the one-shot's set and clear are the same assignment.
  // The parser's byte: the bus write itself (bypass), or the FIFO's popped entry. The two
  // never coincide: a bypass needs the FIFO empty with no pop in flight (cf_busy_w).
  // The hold: a figure armed or drawing, or a WRITE job queued or walking. A command that
  // does not depend on the draw (SCROLL, PITCH, START) waits behind it as on the chip,
  // whose FIFO executes in order; NP2kai runs such a command at once but holds DRAWING
  // for its own 0.72 us per unit (io/gdc_sub.c calc_gdcslavewait `clk *= 27648;`), and the
  // core's clk_sys-rate walk ends well inside either figure.
  wire cf_hold_w = fig_pend || d_fig || pend_valid || (d_state != D_IDLE);
  wire cf_busy_w = (cf_cnt != 5'd0) || cf_pop_v;
  wire wr_gdc_w  = io_wr && ((io_addr == 8'hA0) || (io_addr == 8'hA2));
  wire byp_w     = wr_gdc_w && !cf_hold_w && !cf_busy_w;
  // A byte arriving while the FIFO is full is lost, as on the chip (status bit 1 says FULL).
  wire cf_push_w = wr_gdc_w && !byp_w && (cf_cnt != 5'd16);
  // One pop every other cycle, never while held: the cycle after a pop the parser takes
  // the byte, and a FIGD/GCHRD it takes has raised the hold before the next pop could issue.
  wire cf_pop_w  = !cf_hold_w && (cf_cnt != 5'd0) && !cf_pop_v;
  // The popped byte waits out a guest 0xA2 read in the same cycle: that read pops the
  // read-back queue a command byte would reload, and the read is the earlier event
  // (the byte was queued behind the draw). So the two never share a cycle (R4).
  wire cf_take_w = cf_pop_v && !(io_rd && (io_addr == 8'hA2));
  wire       p_cmd = byp_w ? (io_addr == 8'hA2) : (cf_take_w && cf_q[8]);
  wire       p_par = byp_w ? (io_addr == 8'hA0) : (cf_take_w && !cf_q[8]);
  wire [7:0] p_din = byp_w ? io_din : cf_q[7:0];

  wire draw_fire_w = p_par && !gdc2_sync_pend &&
                     (gdc2_recv_tgt == RCV_CODE) && (gdc2_recv_left == 4'd1) &&
                     ((gdc2_wcmd & 8'hE4) == 8'h20);

  // The QUEUED job's decode (the engine loads these, so the parse's registers are free
  // to move once the snapshot is taken). The width decode is NP2kai gdcsub_write's
  // `switch(gdc.s.cmd & 0x18)`: 8'h00 is the word, 8'h10 the low byte (mask 0x00FF),
  // 8'h18 the high byte (mask 0xFF00, and the byte is para[GDC_CODE] - the FIRST one
  // written - shifted up). The pattern is the WDAT word with CURS.WG set (GDCWG's
  // "7220A-direct" rows) and the 7220's bit-0 replication of it with WG clear
  // ("7220-bit0-replicate", GDCWG's WG0 rows); WG is bit 3 of CSRW's third byte -
  // the suite's raw CURD byte 3 reads F8 with WG=1 and F0 with it clear (GDCCURS,
  // GDCWG) and the ITF writes 0x08 there (BANK4@0xFA73D).
  wire [15:0] pend_data_w = (pend_wctl[3:2] == 2'b00) ? {pend_code1, pend_code0} :
                            (pend_wctl[3:2] == 2'b11) ? {pend_code0, 8'h00} :
                            {8'h00, pend_code0};
  wire [15:0] pend_mask_w = (pend_wctl[3:2] == 2'b11) ? {pend_mask1, pend_mask0} & 16'hFF00 :
                            (pend_wctl[3:2] == 2'b10) ? {pend_mask1, pend_mask0} & 16'h00FF :
                            {pend_mask1, pend_mask0};
  wire [15:0] pend_col_w = pend_wg ? pend_data_w :
                           (pend_code0[0] ? 16'hFFFF : 16'h0000);
  wire [15:0] pend_msk_w = pend_mask_w;
  wire        pend_plain_w = !pend_egc && !pend_grcg;
  // The plain path merges (reads the old word first) except a full-mask replace, which
  // writes its pattern outright; the GRCG and EGC routes never merge here - the tile
  // merge is the GRCG's own (its RMW arm) and the EGC's its own ROP (withegc).
  wire        pend_need_rd_w = pend_plain_w &&
                               !((pend_wctl[1:0] == 2'd00) && (pend_msk_w == 16'hFFFF));
  wire  [3:0] pend_be_w = pend_csrw0[0] ? 4'b1100 : 4'b0011;
  wire [31:0] pend_din_w = pend_csrw0[0] ? {rev16(pend_col_w & pend_msk_w), 16'h0000}
                                         : {16'h0000, rev16(pend_col_w & pend_msk_w)};

  // The engine's live decode. The visit's word lanes follow the dword-lane rule the
  // CPU's own accesses use (byte lane k at plane offset {offset[14:2], k}): a word at
  // word address W sits at byte offset 2W, i.e. lanes 0/1 for even W and 2/3 for odd.
  // The GDC's own arithmetic is INTERNAL-domain and rev16 flips at the VRAM boundary
  // (the ROP commutes with the bit permutation, so the two are equivalent - but the
  // dot ADVANCE below is a shift, which only works in the internal numbering).
  wire d_plain_w = !d_route_egc && !d_route_grcg;
  wire d_need_rd_w = d_plain_w && !((d_rop == 2'd00) && (d_mask == 16'hFFFF));
  // A figure paints its dot with the pattern's current bit, all ones or all zeros through
  // the one-hot cursor mask (MAME upd7220.cpp get_pattern `((m_pattern >> (cycle & 0xf))
  // & 1) * 0xffff` into write_vram; the Xe10's FIGD_ROP rows are this word ROP).
  wire [15:0] d_col_w = d_fig ? {16{d_color[0]}} : d_color;
  wire [3:0]  d_be_w = d_waddr[0] ? 4'b1100 : 4'b0011;
  wire [31:0] d_din_w = d_waddr[0] ? {rev16(d_col_w & d_mask), 16'h0000}
                                   : {16'h0000, rev16(d_col_w & d_mask)};
  // The plain path's merge read, ROPped in the cycle its datum answers (no d_old
  // register: the strobe's datum is consumed exactly once, by this wire's capture).
  wire [15:0] d_rd_i = rev16(d_waddr[0] ? mem_rdata[31:16] : mem_rdata[15:0]);
  wire [15:0] d_res_i = gdc_rop16(d_rop, d_rd_i, d_col_w, d_mask);
  wire [31:0] d_din_merge_w = d_waddr[0] ? {rev16(d_res_i), 16'h0000}
                                         : {16'h0000, rev16(d_res_i)};
  // The engine takes the job when idle; `pend_valid` is written once per cycle below.
  wire d_load_w = pend_valid && (d_state == D_IDLE);

  // The slave GDC's PITCH as the figure-drawing WRITE path uses it: 40 words, one 640-dot
  // line, a constant (40 is the reset value - NP2kai io/gdc.c:1107 `gdc.s.para[GDC_PITCH] =
  // 40;`). The DISPLAY walks (planar and packed) read the guest's PITCH command instead
  // (gdc2_pitch below): the firmware's 5 MHz tables send PITCH 80 with the clock at 5 MHz
  // (BANK3@0x1E40 `a1 47 50`, its row opening `68 21 01 83 85` at 0x1E25), NP2kai's BIOS
  // 5 MHz mode set does the same and sets the SCROLL im bit (bios/bios18.c:483-487
  // `gdc.s.para[GDC_PITCH] = 80;` .. `gdc.s.para[GDC_SCROLL+3] = 0x40;`), and the Win95
  // PC-9821 256-colour driver sends PITCH 0x80 (PEGCV8.DRV seg 2 @0x0B2D `out 0xa2,0x47` /
  // `out 0xa0,0x80`). The planar address step per display line is PITCH selected by the
  // SCROLL length word's "im" bit (bit 14), which is the display-address increment select
  // and is PER PARTITION: im clear doubles the pitch, im set uses it as programmed, and the
  // result is masked to an even byte (NP2kai vram/makegrph.c:147-151 `pitch =
  // gdc.s.para[GDC_PITCH]; if (!(remain & (1 << 14))) pitch <<= 1; pitch &= 0xfe;`,
  // read from `para[GDC_SCROLL + gpos + 2]`; MAME upd7220.cpp:611/624 `*im =
  // BIT(m_ra[index * 4 + 3], 6)` and pc9821.cpp:103-106 `pitch << (im ^ 1)` - the two
  // references agree on both the bit and its effect).
  //
  // So the stride is whatever the GUEST programs, which is the authentic path: the games
  // build im from BIOS work-area 0000:054D bit 2 - clear is 2.5 MHz, set is 5 MHz
  // (rec98/th01/hardware/scrollup.cpp:22-27, libs/master.lib/graph_400line.asm) - and
  // this machine's own state is that bit clear, where the im bit is 0, PITCH is 40 and the
  // step is 2 x 40 = 80 bytes; the 5 MHz state (PITCH 80, im = 1) is the same 80 bytes. A
  // 5 MHz im = 1 partition walked with the reset PITCH 40 instead steps 40 bytes, half a
  // line, and shows each 640-dot line's halves side by side (a 640x400 16-colour driver's
  // desktop doubled).
  localparam [7:0] GDC2_PITCH    = 8'd40;
  // The FOUR partitions' fields, decoded per partition k from para[GDC_SCROLL + 4k ..]
  // (NP2kai vram/makegrph.c grphput_*: `vad = LOADINTELWORD(gdc.s.para + GDC_SCROLL + gpos +
  // 0); vad = LOW15(vad << 1); remain = LOADINTELWORD(... + gpos + 2)`, gpos = 0, 4, 8, 12).
  // start = LOW16(start word << 1): bit 14 of the start word becomes bit 15 of the walk and is
  // the PACKED display page (NP2kai's packed arm `vad = LOW16(vad << 1)`, vram/makegrex.c:199);
  // the word's bit 15 is discarded, and the planar walk takes [14:0] only (makegrph.c LOW15).
  // lines = LOW14(length word) >> 4, bits 13:4 of the LENGTH word, so its bit 14 - the "im"
  // address-increment select - is not count (makegrph.c `remain = LOW14(remain) >> 4`); it picks
  // the partition's step: im clear doubles the pitch, im set uses it (makegrph.c
  // `if (!(remain & (1 << 14))) pitch <<= 1;`). At im = 0 every step is the machine's 2 x PITCH.
  wire [15:0] g_start_w [0:3];
  wire [9:0]  g_lines_w [0:3];
  wire [3:0]  g_im_w;
  genvar gp;
  generate for (gp = 0; gp < 4; gp = gp + 1) begin : g_part
    assign g_start_w[gp] = {gdc2_scr[4*gp+1][6:0], gdc2_scr[4*gp], 1'b0};
    assign g_lines_w[gp] = {gdc2_scr[4*gp+3][5:0], gdc2_scr[4*gp+2][7:4]};
    assign g_im_w[gp]    = gdc2_scr[4*gp+3][6];
  end endgenerate

  // ---- The cursor advance after each painted unit (the GDC2 WRITE slice) ----
  // The machine's WRITE walks ONE DOT along the VECTW direction per unit: the dot
  // position (the mask) steps one dot for each x component of the direction and the
  // word address steps +/-PITCH for each y component. This is the machine's own
  // capture and it REFUTES NP2kai's gdcsub_write linear `adrs + 2` step: WDAT_STEP's
  // `STEP_DC00_D0` paints word 0x0800 and leaves the cursor at 0x0828 (dir 0 =
  // vectdir[0] = {0,+1}, one row = 40 words down), `STEP_DC00_D2` leaves the word and
  // advances the dot M0080->M0100 (dir 2 = {+1,0}), `STEP_DC01_D1` paints (0x0800, D7)
  // and (0x0828, D8) and ends at D9 (dir 1 = {+1,+1}), `STEP_DC01_D3` paints
  // (0x0800, D7) and (0x07D8, D8) (dir 3 = {+1,-1}) - the four directions the vectdir
  // table names (io/gdc_sub.c vectdir[0..7] = {0,1},{1,1},{1,0},{1,-1},{0,-1},{-1,-1},
  // {-1,0},{-1,1}). Those rows are the suite's INFO class (it claims no model) but they
  // are the machine's OBSERVED pixels and win over NP2kai per the evidence hierarchy;
  // a WDAT-STEP slice would re-derive them formally.
  // A figure steps in the direction its own rule picks this step (f_eff_w, below).
  wire  [2:0] f_eff_w;
  wire  [2:0] adv_dir_w = d_fig ? f_eff_w : d_ope;
  wire        adv_xp_w = (adv_dir_w == 3'd1) || (adv_dir_w == 3'd2) || (adv_dir_w == 3'd3);
  wire        adv_xm_w = (adv_dir_w == 3'd5) || (adv_dir_w == 3'd6) || (adv_dir_w == 3'd7);
  wire        adv_yp_w = (adv_dir_w == 3'd0) || (adv_dir_w == 3'd1) || (adv_dir_w == 3'd7);
  wire        adv_ym_w = (adv_dir_w == 3'd3) || (adv_dir_w == 3'd4) || (adv_dir_w == 3'd5);
  // The dot step in the INTERNAL numbering (bit 0 = the leftmost pixel): +x shifts the
  // mask one dot up, wrapping into the neighbouring word's opposite end at the word's
  // edge - the same fold the unit walk's wrap gives (NP2kai's `(adrs + 2) & 0x7ffe`).
  wire        adv_wrap_p_w = adv_xp_w && d_mask[15];
  wire        adv_wrap_m_w = adv_xm_w && d_mask[0];
  wire [15:0] adv_mask_w = adv_xp_w ? (d_mask[15] ? 16'h0001 : {d_mask[14:0], 1'b0}) :
                           adv_xm_w ? (d_mask[0]  ? 16'h8000 : {1'b0, d_mask[15:1]}) :
                           d_mask;
  wire [15:0] adv_pitch_w = {8'd0, GDC2_PITCH};
  // ONE adder: the row step (+/-PITCH) and the word-edge wrap (+/-1) are summed first, so the
  // address takes a single carry chain (the two-adder form added them in series).
  wire [15:0] adv_delta_w = (adv_yp_w ? adv_pitch_w :
                             adv_ym_w ? (16'd0 - adv_pitch_w) : 16'd0) +
                            (adv_wrap_p_w ? 16'd1 :
                             adv_wrap_m_w ? (16'd0 - 16'd1) : 16'd0);
  wire [15:0] adv_sum_w   = d_waddr + adv_delta_w;
  // A WRITE wraps inside its plane (the pre-figure engine's 14-bit walk, unchanged); a FIGURE
  // carries into the plane bits: the Xe10's runaway rectangles (GDCDRAW RECT_1x1_D*, D = 0,
  // 16384-dot sides) change exactly the R-plane word counts (2944, 12324, ...) a 16-bit
  // {plane, word} walk predicts, and a plane-local wrap does not.
  wire [15:0] adv_waddr_w = d_fig ? adv_sum_w : {d_waddr[15:14], adv_sum_w[13:0]};
  // The cursor write-back: the machine advances CSRW's EAD and the MASK register (the
  // CURD rows read both back after a draw), so the NEXT command starts from the
  // advanced cursor. No guest CSRW/MASK write can meet it: the parser is held from the
  // trigger to the walk's end (cf_hold_w), so the write-back has the two registers to
  // itself - the R8 assertion `(p_cmd || p_par) && cf_hold_w` below pins that.

  // ---- The figure engine's decode ----
  // FIGD (0x6C) / GCHRD (0x68) arm the engine; it starts when the WRITE engine is idle and
  // holds no job, so a WRITE issued before the figure lands first (the FIFO's order).
  wire p_fig_w   = p_cmd && ((p_din == 8'h6C) || (p_din == 8'h68));
  wire f_start_w = fig_pend && (d_state == D_IDLE) && !pend_valid;
  // FIGS P1 is {SL, R, A, GC, L, DIR[2:0]} (uPD7220; MAME upd7220.cpp COMMAND_FIGS
  // `m_figure_type = (m_pr[1] & 0xf8) >> 3`). GCHRD with GC draws the character; any
  // other combination draws ONE figure, the first of line, arc, rectangle in NP2kai
  // vectdraw's test order (io/gdc.c:211-225 `if (vect->ope & 0x08) ... 0x20 ... 0x40`;
  // NP2kai draws every flagged figure in turn, a combination no capture or guest uses),
  // and no flag at all is the single dot (gdcsub_vectp).
  wire [7:0]  v0_w = gdc2_vect[0];
  wire [2:0]  f_ntype_w = (fig_gc && v0_w[4]) ? T_CHAR :
                          v0_w[3] ? T_LINE : v0_w[5] ? T_ARC : v0_w[6] ? T_RECT : T_DOT;
  wire [13:0] v_dc_w = {gdc2_vect[2][5:0], gdc2_vect[1]};
  wire [13:0] v_d_w  = {gdc2_vect[4][5:0], gdc2_vect[3]};
  wire [13:0] v_d2_w = {gdc2_vect[6][5:0], gdc2_vect[5]};
  wire [13:0] v_d1_w = {gdc2_vect[8][5:0], gdc2_vect[7]};
  wire [13:0] v_dm_w = {gdc2_vect[10][5:0], gdc2_vect[9]};

  // ---- One step's rules (applied at D_FADV when the pace allows) ----
  // LINE (MAME draw_line, the capture's 300 line rows): the octant's axial step when D < 0
  // and then D += D1, else the diagonal step and D += D2; an even octant's axial step is the
  // octant itself, an odd octant's the next one. ARC: the same octant rule, radius r = D + 1
  // (the datasheet's parameter set: DC = r sin(phi), D = r - 1, D2 = 2(r - 1), D1 = -1,
  // DM = r sin(theta); MAME draw_arc `d = m_figs.m_d + 1`), run as the midpoint circle with
  // D1 and D2 starting at those values - axial while D > 0 with D += D1 - 2, else diagonal
  // with D += D2 + D1 - 2 and D2 -= 2; D1 -= 2 every step. It plots round(r - sqrt(r^2 - i^2))
  // at every step i: exactly the circle NP2kai's gdcsub_vectc tabulates (gdc_rt[],
  // `1 - sqrt(1 - x^2)`), where NP2kai's 4096-entry table misrounds a dot on most radii and
  // takes r = D (one less; its own BIOS sends D = r - 1, bios18.c `GBCIR) - 1`). NO arc
  // capture exists (GDCDRAW's ARC rows ERRORed on the Xe10): item 126.
  wire        f_axial_w = (f_type == T_LINE) ? f_d[13] : (!f_d[13] && (f_d != 14'd0));
  wire  [2:0] f_ldir_w  = d_ope + {2'd0, d_ope[0] ? f_axial_w : !f_axial_w};
  wire [13:0] f_d1m_w   = f_d1 - 14'd2;
  wire [13:0] f_dsum_w  = f_d + ((f_type == T_LINE) ? (f_axial_w ? f_d1 : f_d2) : f_d1m_w) +
                          (((f_type == T_ARC) && !f_axial_w) ? f_d2 : 14'd0);
  // RECTANGLE (MAME draw_rectangle, the capture's RECT rows): sides of D, D2, D, D2 dots,
  // each side's first step turning +90 degrees (DIR + 2) - four sides whatever DC (NP2kai
  // gdcsub_vectr). A zero side length is 16384 dots: the 14-bit count wraps (RECT_1x1_*'s
  // runaway sweeps are that length).
  // CHARACTER (MAME draw_char, the capture's GCHR rows): DC + 1 rows of the PRAM pattern
  // RA15, RA14, ... RA8, RA15 ... (one row byte each, `m_ra[15 - (i & 7)]`), each row a pass
  // of D dots, every dot and every pass repeated ZOOM + 1 times, the passes walking back and
  // forth: at a pass end the step turns by +2 (slanted +1) on even passes and -2 (slanted -3)
  // on odd ones, and the next pass runs the opposite way (DIR + 4) reading its row byte
  // from the other end.
  wire        f_zd_end_w   = (f_zd == gdc2_zoom);
  wire        f_pix_last_w = (d_left[13:0] == 14'd1);
  wire        f_pass_end_w = f_zd_end_w && f_pix_last_w;
  wire  [2:0] f_c0_w = f_par ? (f_slant ? 3'd5 : 3'd6) : (f_slant ? 3'd1 : 3'd2);
  assign f_eff_w = ((f_type == T_LINE) || (f_type == T_ARC)) ? f_ldir_w :
                   (f_type == T_RECT) ? (f_sstart ? d_ope + 3'd2 : d_ope) :
                   ((f_type == T_CHAR) && f_pass_end_w) ? d_ope + f_c0_w :
                   d_ope;
  // The next pass's row byte (the same row again while its ZOOM repeats last), read the
  // other way round on an odd pass.
  wire  [2:0] f_nrow_w = (f_zdc == gdc2_zoom) ? f_row + 3'd1 : f_row;
  wire  [7:0] f_rb_w   = gdc2_scr[4'd15 - {1'b0, f_nrow_w}];
  wire [15:0] f_rpat_w = f_par ? {f_rb_w, f_rb_w} : {rev8(f_rb_w), rev8(f_rb_w)};
  // The figure's last step.
  wire        f_last_w = (f_type == T_DOT) ||
                         (((f_type == T_LINE) || (f_type == T_ARC)) && (d_left[13:0] == 14'd0)) ||
                         ((f_type == T_RECT) && f_pix_last_w && (f_side == 2'd3)) ||
                         ((f_type == T_CHAR) && f_pass_end_w && f_zd_end_w &&
                          (f_zdc == gdc2_zoom) && (f_d == 14'd0));
  // Does this step paint? An arc paints from step DM on; a 0 pattern bit paints only on the
  // plain path's REPLACE (it clears the dot) - the other ROPs and the GRCG/EGC routes do
  // nothing for it (NP2kai psettbl `{_nop, _complemnt}` ... and gdcpset_prepare's
  // `func[0] = _nop`; the Xe10's FIGD_PATTERN rows).
  wire        f_plot_w  = !((f_type == T_ARC) && (f_dm != 14'd0));
  wire        f_visit_w = f_plot_w && (d_color[0] || (d_plain_w && (d_rop == 2'd0)));
  // ---- The draw pacing (WRITE_PACE_NS / FIG_PACE_NS; 0 = not built) ----
  // Each paced kind has its own fixed-rate enable, restarted when its job starts, so a job's
  // k-th period ends k x PACE_NS after the start at any clk_sys (the busy time is the
  // device's, never a clk_sys count). The enable is a RATE, like pixel_ce, not an event:
  // the engine looks at it only while it waits (D_WPACE, D_FADV), and a period that ends
  // while a visit is still in flight is simply not the end of that unit. A restart can only
  // come with the engine idle (d_load_w and f_start_w need D_IDLE), where nothing waits on
  // the enable, and it suppresses that cycle's enable by definition (no unit is pending).
  localparam W_PACED = (WRITE_PACE_NS != 0);
  localparam F_PACED = (FIG_PACE_NS != 0);
  wire w_pace_ce, f_pace_ce;
  generate if (W_PACED) begin : g_wpace
    pc9821_gdc2_pace #(.SYS_FREQ(SYS_FREQ), .PERIOD_NS(WRITE_PACE_NS)) u_wpace (
        .clk_sys(clk_sys), .restart(d_load_w), .ce(w_pace_ce));
  end else begin : g_wnopace
    assign w_pace_ce = 1'b0;
  end endgenerate
  generate if (F_PACED) begin : g_fpace
    pc9821_gdc2_pace #(.SYS_FREQ(SYS_FREQ), .PERIOD_NS(FIG_PACE_NS)) u_fpace (
        .clk_sys(clk_sys), .restart(f_start_w), .ce(f_pace_ce));
  end else begin : g_fnopace
    assign f_pace_ce = 1'b0;
  end endgenerate

  // A step advances ON a dot clock, FIG_PACE dot clocks after the previous one advanced:
  // FIG_PACE + 1 dot clocks a step at any clk_sys. Paced (FIG_PACE_NS), it advances on the
  // figure's pace enable instead: step k ends k x FIG_PACE_NS after the start.
  wire        f_adv_go_w = (d_state == D_FADV) &&
                           (F_PACED ? f_pace_ce : ((f_pace == 4'd0) && pixel_ce));
  // A WRITE unit ends when its store has been accepted (unpaced), or, paced, on the WRITE pace
  // enable after that (D_WPACE): unit k ends k x WRITE_PACE_NS after the job's start, so
  // DRAWING (status bit 3) stays set N x WRITE_PACE_NS for an N-unit WRITE and the bytes
  // written behind it wait that long in the command FIFO (bit 1 FULL becomes reachable).
  wire        d_wr_done_w = (d_state == D_WR) && mem_ready && !d_fig;
  wire        d_unit_end_w = W_PACED ? ((d_state == D_WPACE) && w_pace_ce) : d_wr_done_w;

  integer i;
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      gdc2_ptr <= 4'd0;
      gdc2_left <= 5'd0;
      gdc2_lr <= 5'd0;      // lr = 1, one stride per raster line (the firmware's power-on PITCH)
      gdc2_grph_start <= 1'b0;   // graphics display off until GDC2 says START
      gdc2_recv_left <= 4'd0;
      gdc2_recv_tgt <= RCV_NONE;
      gdc2_pitch <= 8'd40;
      gdc2_recv_ptr <= 4'd0;
      gdc2_snd_cnt <= 3'd0;
      gdc2_snd_ptr <= 3'd0;
      gdc2_snd_q   <= 8'hFF;   // nothing pending: 0xA2 answers 0xFF (machine: `05 04 ff`)
      gdc2_sync_pend <= 1'b0;
      gdc2_sync_cnt  <= 3'd0;
      gdc2_sal       <= 10'h190;
      gdc2_svbp      <= 6'd25;
      gdc2_wcmd <= 8'h00;
      for (i = 0; i < 16; i = i + 1) gdc2_scr[i] <= 8'h00;
      for (i = 0; i < 3; i = i + 1) gdc2_csrw[i] <= 8'h00;
      for (i = 0; i < 2; i = i + 1) begin
        gdc2_code[i] <= 8'h00;
        gdc2_mask[i] <= 8'h00;
      end
      for (i = 0; i < 11; i = i + 1) gdc2_vect[i] <= 8'h00;
      pend_valid <= 1'b0;
      pend_wctl <= 4'd0;
      pend_wg <= 1'b0;
      pend_code0 <= 8'h00;
      pend_code1 <= 8'h00;
      pend_csrw0 <= 8'h00;
      pend_csrw1 <= 8'h00;
      pend_mask0 <= 8'h00;
      pend_mask1 <= 8'h00;
      pend_dir <= 3'd0;
      pend_vect1 <= 8'h00;
      pend_vect2 <= 8'h00;
      pend_egc <= 1'b0;
      pend_grcg <= 1'b0;
      pend_page <= 1'b0;
      d_state <= D_IDLE;
      d_left <= 16'd0;
      d_waddr <= 16'd0;
      d_rop <= 2'd0;
      d_ope <= 3'd0;
      d_color <= 16'd0;
      d_mask <= 16'd0;
      d_route_egc <= 1'b0;
      d_route_grcg <= 1'b0;
      mem_valid <= 1'b0;
      mem_write <= 1'b0;
      mem_route_egc <= 1'b0;
      mem_route_grcg <= 1'b0;
      mem_page <= 1'b0;
      mem_plane <= 2'd0;
      mem_offset <= 15'd0;
      mem_din <= 32'd0;
      mem_be <= 4'd0;
      gdc2_zoom <= 4'd0;
      fig_pend <= 1'b0;
      fig_gc <= 1'b0;
      d_fig <= 1'b0;
      f_type <= T_DOT;
      f_slant <= 1'b0;
      f_d <= 14'd0;
      f_d1 <= 14'd0;
      f_d2 <= 14'd0;
      f_dm <= 14'd0;
      f_side <= 2'd0;
      f_sstart <= 1'b0;
      f_zd <= 4'd0;
      f_zdc <= 4'd0;
      f_row <= 3'd0;
      f_par <= 1'b0;
      f_pace <= 4'd0;
      cf_wp <= 4'd0;
      cf_rp <= 4'd0;
      cf_cnt <= 5'd0;
      cf_pop_v <= 1'b0;
    end else begin
      // The parameter read-back pop (NP2kai gdc_ia2: `if (gdc.s.snd) { snd--;
      // return para[ptr++]; } return 0xff;`, io/gdc.c:813-820). One byte per read.
      if (io_rd && (io_addr == 8'hA2)) begin
        if (gdc2_snd_cnt != 3'd0) begin
          gdc2_snd_q   <= gdc2_snd[gdc2_snd_ptr];
          gdc2_snd_ptr <= gdc2_snd_ptr + 3'd1;
          gdc2_snd_cnt <= gdc2_snd_cnt - 3'd1;
        end else gdc2_snd_q <= 8'hFF;
      end
    if (p_cmd) begin
      // GDC2 command port SCROLL (0x70..0x77): the low nibble is the byte of the
      // parameter block the command starts at, so 0x70 writes all sixteen bytes and
      // 0x74 the last twelve (gdc_cmd.tbl).
      // Nothing is "executed": the scanout reads the block continuously (NP2kai
      // vram/makegrph.c:145-148 reads gdc.s.para[] every line), so bytes take effect as
      // they reach the parser - there is deliberately no completion event to wait for.
      // Every command ALSO replaces the parameter read-back queue (NP2kai gdc_work:
      // `item->snd = gdc_cmd[data].indatas`, io/gdc.c:327): 0xE0 CSRR answers the Xe10's five
      // bytes {EAD, 0xF0|..., MASK} (below) and 0xC0 LPEN the three light-pen
      // slots para[29..31] (gdc_cmd.tbl:214) - never written, so gdc_reset's
      // zeros (io/gdc.c:1160), NOT the CSRFORM bytes (GDC_CSRFORM = 9,
      // GDC_LPEN = 29, io/gdc_cmd.h:34,38).
      gdc2_snd_ptr <= 3'd0;
      case (p_din)
        8'hE0: begin
          gdc2_snd[0] <= gdc2_csrw[0];
          gdc2_snd[1] <= gdc2_csrw[1];
          // The Xe10's five CURD bytes are {EAD[7:0], EAD[15:8], 0xF0 | WG<<3 | EAD[17:16],
          // MASK[7:0], MASK[15:8]} (docs/probes/gdc-conformance/xe10-2.5MHz/GDCCURS.CSV
          // raw_curd `00-00-F0-01-00`, GDCWG.CSV `28-88-F8-FF-FF` with WG set); NP2kai
          // gdc.c:328-337 answers {CSRW0, CSRW1, CSRW2 & 3, 0, 0} and is refuted.
          gdc2_snd[2] <= {4'hF, gdc2_csrw[2][3], 1'b0, gdc2_csrw[2][1:0]};
          gdc2_snd[3] <= gdc2_mask[0];
          gdc2_snd[4] <= gdc2_mask[1];
          gdc2_snd_cnt <= 3'd5;
        end
        8'hC0: begin
          gdc2_snd[0] <= 8'h00;   // para[29]: never written, zero since gdc_reset
          gdc2_snd[1] <= 8'h00;   // para[30] (io/gdc.c:1160)
          gdc2_snd[2] <= 8'h00;   // para[31]
          gdc2_snd_cnt <= 3'd3;
        end
        default: gdc2_snd_cnt <= 3'd0;
      endcase
      // EVERY command byte - SCROLL/TEXTW included - ends an unfinished SYNC block
      // (NP2kai gdc_work reloads ptr/rcv from the new command's row, io/gdc.c), so a
      // cut-short SYNC cannot swallow the next command's parameters into AL/VBP. One
      // assignment per command write (R2): armed by 0x0E/0x0F, cleared by the rest.
      gdc2_sync_pend <= (p_din == 8'h0F) || (p_din == 8'h0E);
      gdc2_sync_cnt  <= 3'd0;
      if (p_din[7:4] == 4'h7) begin
        // SCROLL 0x70-0x77 and TEXTW 0x78-0x7F: one 16-byte parameter RAM (gdc_cmd.tbl
        // rows 0x70-0x7F: pos GDC_SCROLL + k, 16 - k bytes)
        gdc2_ptr  <= p_din[3:0];
        gdc2_left <= 5'd16 - {1'b0, p_din[3:0]};
        gdc2_recv_left <= 4'd0;   // a SCROLL command discards a pending parameter count
      end else begin
        // The display commands, deliberately the SAME bytes the text GDC takes on
        // 0x62: the slave's half of one mechanism (NP2kai io/gdc_cmd.h CMD_START =
        // 0x0d, CMD_STOP = 0x0c, CMD_SYNC_ON = 0x0f, CMD_SYNC_OFF = 0x0e).
        // SYNC_ON/OFF take EIGHT parameter bytes (io/gdc_cmd.tbl:24-25), captured on
        // 0xA0 below and dropped: the raster is the master's block's (see
        // gdc2_sync_pend).
        if (p_din == 8'h0D || p_din == 8'h6B) begin
          gdc2_grph_start <= 1'b1;   // START / BCTRL on
        end else if (p_din == 8'h0C || p_din == 8'h05) begin
          gdc2_grph_start <= 1'b0;   // STOP / BCTRL off
        end else if (p_din == 8'h0F || p_din == 8'h0E) begin
          gdc2_grph_start <= p_din[0];   // SYNC on (0x0F) / off (0x0E)
        end
        // The rest of the command space has no display customer. A command byte
        // discards an unfulfilled parameter count (NP2kai's gdc_work takes the
        // command branch first), so the next 0xA0 byte cannot be misread.
        // 0x49 CSRW and 0x4B CSRFORM are the exceptions: their parameter bytes
        // are consumed here - CSRW's three are kept for CSRR, and CSRFORM's FIRST
        // byte is also the display line step (the firmware sends one byte,
        // BANK6@0x787e-0x788c); NP2kai takes three and the rest of the count is
        // discarded by the next command exactly as here.
        if (p_din == 8'h49) begin
          gdc2_recv_tgt  <= RCV_CSRW;
          gdc2_recv_left <= 4'd3;
          gdc2_recv_ptr  <= 4'd0;
        end else if (p_din == 8'h4B) begin
          gdc2_recv_tgt  <= RCV_CSRFORM;
          gdc2_recv_left <= 4'd3;
          gdc2_recv_ptr  <= 4'd0;
        end else if (p_din == 8'h4C) begin
          // VECTW (FIGS): eleven parameter bytes (io/gdc_cmd.tbl row 0x4c): P1
          // {SL, R, A, GC, L, DIR}, then DC, D, D2, D1, DM as 14-bit words. The WRITE
          // command walks bytes 1-2 as its unit count (NP2kai gdcsub_write's
          // `leng = LOADINTELWORD(gdc.s.para + GDC_VECTW + 1) + 1`); the figure
          // engine takes them all.
          gdc2_recv_tgt  <= RCV_VECTW;
          gdc2_recv_left <= 4'd11;
          gdc2_recv_ptr  <= 4'd0;
        end else if (p_din == 8'h47) begin
          // PITCH: one parameter byte (io/gdc_cmd.tbl row 0x47), the packed walk's stride.
          gdc2_recv_tgt  <= RCV_PITCH;
          gdc2_recv_left <= 4'd1;
          gdc2_recv_ptr  <= 4'd0;
        end else if (p_din == 8'h4A) begin
          // MASK: two parameter bytes, the write mask the WRITE command paints
          // through (io/gdc_cmd.tbl row 0x4a, NP2kai gdcsub_write's GDC_MASK).
          gdc2_recv_tgt  <= RCV_MASK;
          gdc2_recv_left <= 4'd2;
          gdc2_recv_ptr  <= 4'd0;
        end else if (p_din == 8'h46) begin
          // ZOOM: one parameter byte, the GCHRD magnification in its low nibble.
          gdc2_recv_tgt  <= RCV_ZOOM;
          gdc2_recv_left <= 4'd1;
          gdc2_recv_ptr  <= 4'd0;
        end else if ((p_din & 8'h60) == 8'h20) begin
          // The WRITE family (NP2kai gdc_work's `(data & 0x60) == 0x20` arm): the
          // command byte keeps the ROP in its low two bits and the transfer width
          // in bits 4:3, and its data bytes go to GDC_CODE. The 8'h08 width takes
          // no data byte (and never executes - NP2kai's rcv = 0 arm never reaches
          // its gdcsub_write call), 8'h00 takes two, the byte widths one.
          gdc2_wcmd      <= p_din;
          gdc2_recv_tgt  <= RCV_CODE;
          gdc2_recv_ptr  <= 4'd0;
          case (p_din & 8'h18)
            8'h00:   gdc2_recv_left <= 4'd2;
            8'h08:   gdc2_recv_left <= 4'd0;
            default: gdc2_recv_left <= 4'd1;
          endcase
        end else gdc2_recv_left <= 4'd0;
        gdc2_left <= 5'd0;
      end
    end else if (p_par) begin
      if (gdc2_sync_pend) begin
        // The slave's SYNC block byte: AL and VBP are kept (see gdc2_sal), the rest consumed.
        if (gdc2_sync_cnt == 3'd6) gdc2_sal[7:0] <= p_din;
        if (gdc2_sync_cnt == 3'd7) begin
          gdc2_sal[9:8] <= p_din[1:0];
          gdc2_svbp     <= p_din[7:2];
          gdc2_sync_pend <= 1'b0;
          gdc2_sync_cnt  <= 3'd0;
        end else gdc2_sync_cnt <= gdc2_sync_cnt + 3'd1;
      end else if (gdc2_recv_left != 4'd0) begin
        case (gdc2_recv_tgt)
          RCV_CSRW: begin
            gdc2_csrw[gdc2_recv_ptr[1:0]] <= p_din;
            // The third byte's dAD (bits 7:4) loads the mask with its one-hot dot
            // (uPD7220 CURS; the Xe10's DOT_DAD00..15 rows start each dot at the
            // CURS dAD and read MASK = 1 << dAD back, GDCCURS CURS_MASK/MASK_ORDER).
            if (gdc2_recv_ptr[1:0] == 2'd2) begin
              gdc2_mask[0] <= (p_din[7] == 1'b0) ? (8'h01 << p_din[6:4]) : 8'h00;
              gdc2_mask[1] <= (p_din[7] == 1'b1) ? (8'h01 << p_din[6:4]) : 8'h00;
            end
          end
          RCV_CSRFORM: if (gdc2_recv_ptr == 4'd0)
                         gdc2_lr <= p_din[4:0];   // CSRFORM[4:0] = lr-1 (NP2kai vram/makegrph.c:362)
          RCV_VECTW:   gdc2_vect[gdc2_recv_ptr[3:0]] <= p_din;
          RCV_CODE:    gdc2_code[gdc2_recv_ptr[0]] <= p_din;
          RCV_MASK:    gdc2_mask[gdc2_recv_ptr[0]] <= p_din;
          RCV_ZOOM:    gdc2_zoom <= p_din[3:0];
          RCV_PITCH:   gdc2_pitch <= p_din;
          default: ;
        endcase
        gdc2_recv_ptr  <= gdc2_recv_ptr + 4'd1;
        gdc2_recv_left <= gdc2_recv_left - 4'd1;
      end else if (gdc2_left != 5'd0) begin
        gdc2_scr[gdc2_ptr] <= p_din;
        gdc2_ptr  <= gdc2_ptr + 4'd1;   // wraps at 16 with gdc2_left at 0
        gdc2_left <= gdc2_left - 5'd1;
      end
    end

    // ---------------------------------------------------------------
    // The WRITE engine (the GDC2 WRITE slice). One writer per register: each of
    // pend_valid, the job registers and the visit registers is assigned in
    // exactly one arm of this block per cycle (the single-cycle event discipline R1/R2;
    // the trigger's set and clear are one assignment each, never two arms racing).
    //
    // The job is SNAPSHOTTED at the trigger - the parse's registers are free to move
    // afterwards, so a later MASK/CSRW/VECTW cannot retarget a draw already queued.
    // A trigger finds the slot empty and the engine idle (the parser is held while a job
    // is queued or walking, so later bytes wait in the command FIFO), so the fill and the
    // drain never share a cycle - the R8 assertion below pins it.
    // ---------------------------------------------------------------
    if (draw_fire_w) begin
      pend_wctl  <= {gdc2_wcmd[4:3], gdc2_wcmd[1:0]};
      pend_wg    <= gdc2_csrw[2][3];
      pend_code0 <= (gdc2_recv_ptr[0] == 1'b0) ? p_din : gdc2_code[0];
      pend_code1 <= (gdc2_recv_ptr[0] == 1'b0) ? gdc2_code[1] : p_din;
      pend_csrw0 <= gdc2_csrw[0];
      pend_csrw1 <= gdc2_csrw[1];
      pend_mask0 <= gdc2_mask[0];
      pend_mask1 <= gdc2_mask[1];
      pend_dir   <= gdc2_vect[0][2:0];
      pend_vect1 <= gdc2_vect[1];
      pend_vect2 <= gdc2_vect[2];
      // The route is LATCHED here, exactly gdcpset_prepare's once-per-draw dispatch
      // (io/gdc_pset.c:117-137): EGC first (its gate already ANDs the GRCG's bit 7),
      // then the GRCG's tile path, then the plain ROP path.
      pend_egc   <= egc_mem_gate;
      pend_grcg  <= grcg_cg_gate;
      pend_page  <= access_page;
      pend_valid <= 1'b1;
    end else if (d_load_w) begin
      pend_valid <= 1'b0;
    end

    // The command FIFO's pointers and count: push and pop in one cycle are one merged
    // update (R4), never two assignments.
    if (cf_push_w) cf_wp <= cf_wp + 4'd1;
    if (cf_pop_w)  cf_rp <= cf_rp + 4'd1;
    cf_cnt   <= cf_cnt + {4'd0, cf_push_w} - {4'd0, cf_pop_w};
    cf_pop_v <= cf_pop_w || (cf_pop_v && !cf_take_w);
    // FIGD/GCHRD arm the engine; the start consumes the arm. The two cannot coincide: an
    // armed figure holds the parser, so no command reaches it until the start (R3).
    fig_pend <= p_fig_w || (fig_pend && !f_start_w);
    if (p_fig_w) fig_gc <= (p_din == 8'h68);
    // The pace: a step advances on the dot clock FIG_PACE dot clocks after the last advance
    // (or the start), so the busy time is the device's, not clk_sys's.
    f_pace <= (f_start_w || f_adv_go_w) ? FIG_PACE :
              (pixel_ce && (f_pace != 4'd0)) ? f_pace - 4'd1 : f_pace;


    case (d_state)
      D_IDLE: if (d_load_w) begin
        d_rop        <= pend_wctl[1:0];
        d_ope        <= pend_dir;
        d_color      <= pend_col_w;
        d_mask       <= pend_msk_w;
        d_waddr      <= {pend_csrw1, pend_csrw0};
        d_route_egc  <= pend_egc;
        d_route_grcg <= pend_grcg;
        d_left       <= {pend_vect2, pend_vect1};   // NP2kai's leng - 1
        mem_valid      <= 1'b1;
        mem_write      <= !pend_need_rd_w;
        mem_route_egc  <= pend_egc;
        mem_route_grcg <= pend_grcg;
        mem_page       <= pend_page;
        mem_plane      <= pend_csrw1[7:6] - 2'd1;   // GDC plane n -> lane n-1 (mod 4)
        mem_offset     <= {pend_csrw1[5:0], pend_csrw0, 1'b0};
        mem_be         <= pend_be_w;
        mem_din        <= pend_need_rd_w ? 32'd0 : pend_din_w;
        d_state      <= pend_need_rd_w ? D_RD : D_WR;
      end else if (f_start_w) begin
        // The figure start: the engine's working registers load from the parameter RAM as it
        // stands (nothing has changed it since the FIGD: the parser is held), and the FIGS
        // block returns to its defaults - DC 0, D 8, D2 8, D1 and DM all ones - exactly NP2kai's
        // gdc_vectreset after every vectdraw/textdraw (io/gdc.c:185-197). P1 is kept.
        d_fig        <= 1'b1;
        f_type       <= f_ntype_w;
        f_slant      <= v0_w[7];
        d_ope        <= v0_w[2:0];
        d_rop        <= gdc2_wcmd[1:0];   // NP2kai vectdraw `ope = gdc.s.para[GDC_WRITE]`
        d_waddr      <= {gdc2_csrw[1], gdc2_csrw[0]};
        d_mask       <= {gdc2_mask[1], gdc2_mask[0]};
        // FIGD's line pattern is PRAM bytes 8-9 (NP2kai vectdraw `textw =
        // LOADINTELWORD(gdc.s.para + GDC_TEXTW)`; the Xe10's LINE_A53C rows), GCHRD's first
        // row RA15 doubled (textdraw `textw = gdc.s.para[GDC_TEXTW + 7]`; draw_char's
        // `m_ra[15 - (i & 7)]` at i = 0).
        d_color      <= fig_gc ? {gdc2_scr[15], gdc2_scr[15]} : {gdc2_scr[9], gdc2_scr[8]};
        d_route_egc  <= egc_mem_gate;     // gdcpset_prepare's once-per-draw route
        d_route_grcg <= grcg_cg_gate;
        mem_route_egc  <= egc_mem_gate;
        mem_route_grcg <= grcg_cg_gate;
        mem_page       <= access_page;
        d_left <= {2'd0, ((f_ntype_w == T_RECT) || (f_ntype_w == T_CHAR)) ? v_d_w :
                         (f_ntype_w == T_DOT) ? 14'd0 : v_dc_w};
        f_d    <= (f_ntype_w == T_CHAR) ? v_dc_w : v_d_w;
        // The arc's D1 and D2 start at their datasheet values from D alone (-1 and
        // 2(r - 1) = 2D), as MAME's draw_arc and NP2kai's gdcsub_vectc both draw from D
        // alone: NP2kai's own BIOS sends D2 = (r - 1) >> 1 (bios18.c `data >>= 1;
        // STOREINTELWORD(vect.D2, data)`), which a D2-driven walk would turn into a spiral.
        f_d1   <= (f_ntype_w == T_RECT) ? v_d_w : (f_ntype_w == T_ARC) ? 14'h3FFF : v_d1_w;
        f_d2   <= (f_ntype_w == T_CHAR) ? v_d_w :
                  (f_ntype_w == T_ARC) ? {v_d_w[12:0], 1'b0} : v_d2_w;
        f_dm   <= v_dm_w;
        f_side <= 2'd0;
        f_sstart <= 1'b0;
        f_zd   <= 4'd0;
        f_zdc  <= 4'd0;
        f_row  <= 3'd0;
        f_par  <= 1'b0;
        gdc2_vect[1]  <= 8'h00;
        gdc2_vect[2]  <= 8'h00;
        gdc2_vect[3]  <= 8'h08;
        gdc2_vect[4]  <= 8'h00;
        gdc2_vect[5]  <= 8'h08;
        gdc2_vect[6]  <= 8'h00;
        gdc2_vect[7]  <= 8'hFF;
        gdc2_vect[8]  <= 8'hFF;
        gdc2_vect[9]  <= 8'hFF;
        gdc2_vect[10] <= 8'hFF;
        d_state      <= D_FSTEP;
      end
      // A read visit: `mem_valid` holds to `mem_ready`, and the datum answers later on
      // `mem_resp` (the responder contract: never the ready's own cycle).
      D_RD: if (mem_ready) begin
        mem_valid <= 1'b0;
        d_state   <= D_RDW;
      end
      D_RDW: if (mem_resp) begin
        mem_valid <= 1'b1;
        mem_write <= 1'b1;
        mem_be    <= d_be_w;
        mem_din   <= d_din_merge_w;
        d_state   <= D_WR;
      end
      // D_WPACE shares the unit's end with D_WR: unpaced the end is the store's acceptance
      // (d_unit_end_w is d_wr_done_w and D_WPACE is never entered); paced, the acceptance
      // moves to D_WPACE and the end is the pace enable there. One arm, so each register has
      // one assignment per cycle (R1/R2).
      D_WR, D_WPACE: if ((d_state == D_WR) && mem_ready && d_fig) begin
        mem_valid <= 1'b0;
        d_state   <= D_FADV;
      end else if (d_wr_done_w && !d_unit_end_w) begin
        mem_valid <= 1'b0;
        d_state   <= D_WPACE;
      end else if (d_unit_end_w) begin
        mem_valid <= 1'b0;
        // Every painted unit advances the cursor one dot along the direction (the
        // advance block above), the last one included - the machine's CURD readback
        // shows it advanced after a one-unit draw (STEP_DC00_*).
        if (d_left == 16'd0) begin
          d_state <= D_IDLE;
          gdc2_csrw[0] <= adv_waddr_w[7:0];
          gdc2_csrw[1] <= {gdc2_csrw[1][7:6], adv_waddr_w[13:8]};
          gdc2_mask[0] <= adv_mask_w[7:0];
          gdc2_mask[1] <= adv_mask_w[15:8];
        end else begin
          d_left  <= d_left - 16'd1;
          d_waddr <= adv_waddr_w;
          d_mask  <= adv_mask_w;
          d_state <= D_NEXT;
        end
      end
      // One clk_sys of mem_valid low between visits: the EGC's cpu port takes its
      // accept gap from the CPU stream and its S_HOLD bubble assumes one between
      // accesses (pc9821_egc.sv R6/R8), so a GDC stream must give it too. The NEXT
      // unit's visit is presented at the cursor the advance left (d_waddr was already
      // stepped in D_WR's done arm).
      D_NEXT: begin
        mem_valid  <= 1'b1;
        mem_write  <= !d_need_rd_w;
        mem_be     <= d_be_w;
        mem_din    <= d_need_rd_w ? 32'd0 : d_din_w;
        mem_offset <= {d_waddr[13:0], 1'b0};
        d_state    <= d_need_rd_w ? D_RD : D_WR;
      end
      // A figure step: one visit for a painted dot (the same protocol as a WRITE unit), or
      // none, then the advance.
      D_FSTEP: if (f_visit_w) begin
        mem_valid  <= 1'b1;
        mem_write  <= !d_need_rd_w;
        mem_be     <= d_be_w;
        mem_din    <= d_need_rd_w ? 32'd0 : d_din_w;
        mem_plane  <= d_waddr[15:14] - 2'd1;   // GDC plane n -> lane n-1 (mod 4)
        mem_offset <= {d_waddr[13:0], 1'b0};
        d_state    <= d_need_rd_w ? D_RD : D_WR;
      end else d_state <= D_FADV;
      // The advance, once the pace allows: the cursor moves (the last step's too - the
      // Xe10's CURD reads the cursor one step past the figure's last dot) and the figure's
      // own counters step.
      D_FADV: if (f_adv_go_w) begin
        d_waddr <= adv_waddr_w;
        d_mask  <= adv_mask_w;
        case (f_type)
          T_LINE: begin
            f_d    <= f_dsum_w;
            d_left <= d_left - 16'd1;
            d_color <= {d_color[0], d_color[15:1]};
          end
          T_ARC: begin
            f_d  <= f_dsum_w;
            f_d1 <= f_d1m_w;
            if (!f_axial_w) f_d2 <= f_d2 - 14'd2;
            if (f_plot_w) d_color <= {d_color[0], d_color[15:1]};
            else          f_dm <= f_dm - 14'd1;
            d_left <= d_left - 16'd1;
          end
          T_RECT: begin
            d_color  <= {d_color[0], d_color[15:1]};
            if (f_sstart) d_ope <= d_ope + 3'd2;
            f_sstart <= f_pix_last_w;
            if (f_pix_last_w) begin
              f_side <= f_side + 2'd1;
              d_left <= {2'd0, f_side[0] ? f_d1 : f_d2};
            end else d_left <= d_left - 16'd1;
          end
          T_CHAR: begin
            if (!f_zd_end_w) f_zd <= f_zd + 4'd1;
            else if (!f_pix_last_w) begin
              f_zd    <= 4'd0;
              d_left  <= d_left - 16'd1;
              d_color <= {d_color[0], d_color[15:1]};
            end else begin
              f_zd    <= 4'd0;
              d_left  <= {2'd0, f_d2};
              d_ope   <= d_ope + 3'd4;
              f_par   <= !f_par;
              d_color <= f_rpat_w;
              if (f_zdc != gdc2_zoom) f_zdc <= f_zdc + 4'd1;
              else begin
                f_zdc <= 4'd0;
                f_row <= f_row + 3'd1;
                f_d   <= f_d - 14'd1;
              end
            end
          end
          default: ;
        endcase
        if (f_last_w) begin
          d_fig   <= 1'b0;
          d_state <= D_IDLE;
          // The cursor write-back, as the WRITE's (the parser is held while the
          // figure draws, so no guest write meets it).
          gdc2_csrw[0] <= adv_waddr_w[7:0];
          gdc2_csrw[1] <= adv_waddr_w[15:8];
          gdc2_mask[0] <= adv_mask_w[7:0];
          gdc2_mask[1] <= adv_mask_w[15:8];
        end else d_state <= D_FSTEP;
      end
      default: d_state <= D_IDLE;
    endcase
    end
  end

  // The command FIFO's storage: a plain synchronous-read memory with no reset on its read
  // register, so it builds as block RAM (a 16 x 9 array). A push never meets a pop at one
  // address: a push needs a free slot, so the write pointer equals the read pointer only
  // when the FIFO is empty, and a pop needs it nonempty.
  always @(posedge clk_sys) begin
    if (cf_push_w) cf_mem[cf_wp] <= {(io_addr == 8'hA2), io_din};
    if (cf_pop_w)  cf_q <= cf_mem[cf_rp];
  end

`ifndef SYNTHESIS
  // The contract (R8): one parser source per cycle; the FIFO-sourced byte never meets the
  // guest's read-back pop; the figure arm and its start never share a cycle; nothing reaches
  // the parser while a draw holds it (so the start's VECTW reset and the cursor
  // write-back have the registers to themselves); a WRITE trigger finds the engine empty
  // (so no job is dropped or overtaken).
  always @(posedge clk_sys) if (rst_n_sys) begin
    if (byp_w && cf_pop_v)
      $fatal(1, "pc9821_gdc2: a bus byte and a FIFO byte reached the parser together");
    if (cf_take_w && io_rd && (io_addr == 8'hA2))
      $fatal(1, "pc9821_gdc2: a FIFO command met a read-back pop");
    if (p_fig_w && f_start_w)
      $fatal(1, "pc9821_gdc2: a figure was armed in its own start cycle");
    if ((p_cmd || p_par) && cf_hold_w)
      $fatal(1, "pc9821_gdc2: the parser took a byte while a draw held it");
    if (draw_fire_w && (pend_valid || (d_state != D_IDLE)))
      $fatal(1, "pc9821_gdc2: a WRITE fired while a job was queued or walking");
    if (d_load_w && f_start_w)
      $fatal(1, "pc9821_gdc2: a WRITE job and a figure started together");
  end
`endif

  // ---------------------------------------------------------------
  // Graphics display address: NP2kai's partition walk (vram/makegrph.c makegrph +
  // grphput_*), one raster line at a time. From the frame's first line: partition 1's start,
  // its length and the line repeat; after each raster line `remain--`, and when it reaches 0 the
  // NEXT partition loads (1 -> 2 -> 3 -> 4 -> 1 ..., makegrph's `while(1)` over gpos 0/4/8/12 -
  // partitions 3 and 4 are para[GDC_SCROLL + 8..15], the TEXTW slots, gdc_cmd.h `GDC_TEXTW =
  // GDC_SCROLL + 8`); otherwise `mul--`, and every lr-th line the address steps by the
  // partition's pitch. A zero length never expires (NP2kai's 32-bit `remain--` from 0 wraps;
  // here the 10-bit count needs 1,023 more lines than the longest frame to come back to 1).
  // The walk is LOW15 for the planar scanout and LOW16 for the packed one (gfx_walk_page).
  //
  // The address is that of DECODE line v_oline = the raster line + the scanout's two-line
  // pipeline (pc9821_gvram's tick -> fetch -> display swap owns that depth): the tick at the end
  // of raster line L latches the address of display line L+2. So the next frame's walk STARTS
  // when the decode line wraps to 0, at raster line VTOTAL-2 - the raster's own frame length,
  // which the SYNC block programs (pc9821_crtc's o_vtotal), not a constant.
  //
  // The configuration is copied into the display registers (v_*) at that same point when one
  // is pending, so the frame's walk - its rows 0 and 1 included - runs from one configuration,
  // and a SCROLL written mid-frame takes effect at the next frame as a whole (NP2kai renders a
  // frame from the parameter RAM as it stands, never half of one). pc9821_crtc's frame_end
  // snapshot copies again, so a write in the frame's last two lines is not lost either: it
  // reaches the walk from the frame's row 2 on (a race the guest's VSYNC-paced writes do not run).
  // ---------------------------------------------------------------
  localparam [9:0] SCANOUT_LINE_LATENCY = 10'd2;
  wire [9:0] v_oline_next = vline + SCANOUT_LINE_LATENCY;
  wire        v_wrap     = (v_oline_next >= vtotal);   // the decode is producing rows 0/1
  reg         v_wrap_d;
  wire        w_start    = v_wrap && !v_wrap_d;          // the decode line wrapped to row 0
  wire        snap_now   = (w_start && cfg_pending) || (pixel_ce && cfg_snap);
  // The decode line; in the wrapped rows it is 0 or 1 (vline + 2 - VTOTAL), so no subtractor.
  wire [9:0]  v_oline    = v_wrap ? {9'd0, (v_oline_next != vtotal)} : v_oline_next;

  // The slave SYNC's vertical window (NP2kai vram/dispsync.c dispsync_renewalvertical): the
  // walk's line 0 is display line grph_vbp and the graphics end at grphymax. Latched with the
  // frame's other configuration when the decode line wraps to row 0, so a frame has one window.
  reg  [5:0]  v_gvbp;     // grph_vbp: the slave's VBP minus the master's, 0 if it is smaller
  reg  [10:0] v_gymax;    // grphymax: ((AL - 1) & 0x3ff) + 1 + grph_vbp
  wire [5:0]  n_gvbp  = (gdc2_svbp > m_vbp) ? gdc2_svbp - m_vbp : 6'd0;
  wire [9:0]  n_al_m1 = gdc2_sal - 10'd1;
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      v_gvbp  <= 6'd0;
      v_gymax <= 11'd400;
    end else if (w_start) begin
      v_gvbp  <= n_gvbp;
      v_gymax <= {1'b0, n_al_m1} + 11'd1 + {5'd0, n_gvbp};
    end
  end
  assign gfx_win_off = (vline < {4'd0, v_gvbp}) || ({1'b0, vline} >= v_gymax);

  reg [15:0] v_gstart1, v_gstart2, v_gstart3, v_gstart4;
  reg [9:0]  v_glines1, v_glines2, v_glines3, v_glines4;   // raster lines; 0 = never expires
  reg [3:0]  v_gim;         // each partition's im bit: its step is PITCH at 1, 2 x PITCH at 0
  // THE PACKED WALK'S STRIDE, in 8-byte units: NP2kai makegrphex (vram/makegrex.c:286-291)
  // `mg.pitch = gdc.s.para[GDC_PITCH]; if (!(gdc.clock & 0x80)) mg.pitch <<= 1;
  // mg.pitch &= 0xfe;` - PITCH at 5 MHz, 2 x PITCH at 2.5 MHz, masked to an even BYTE (a
  // 2.5 MHz PITCH of 0x80 is a stride of 0). The SCROLL "im" bit is NOT read there (it is
  // the planar arm's select). The machine's defaults (PITCH 40, 2.5 MHz) give 80 units =
  // 640 bytes; the firmware's 640x480 table (PITCH 80 at 5 MHz) the same 640; the Win95
  // driver's PITCH 0x80 at 5 MHz 1024 bytes - its frame stride (PEGCV8.DRV's 640x480 mode
  // row `31 00 01 00 04 01 80 00` at seg 2 @0x0BCC: bytes 3-4 a 0x0400-byte pitch; the PITCH
  // byte it sends is seg 2 @0x0B37 `mov al,0x80`). MAME
  // steps `pitch << (im ^ 1)` (pc9821.cpp:103-106) and is outranked. Latched at the frame
  // boundary with the line repeat: NP2kai renders a frame from one PITCH.
  reg [7:0]  v_pstride;
  // THE PLANAR WALK'S PITCH: the guest's PITCH byte as it stands at the frame boundary
  // (makegrph.c:147 `pitch = gdc.s.para[GDC_PITCH];`, one PITCH per rendered frame); each
  // partition's im bit then picks PITCH or 2 x PITCH (w_gstep).
  reg [7:0]  v_gpitch;
  reg [4:0]  v_lr2;         // slave CSRFORM[4:0] = lr-1, so lr = 1..32 raster lines per
                            // GDC line (makegrph.c:362 `mg.lr = (gdc.s.para[GDC_CSRFORM] &
                            // 0x1f) + 1`); lr = 2 is the 640x200 doubling - the ADDRESS step
                            // only: in the 200-line interleave (MODE FF1 bit 4) the odd raster
                            // line displays text over black (gfx_odd_line)
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      v_gstart1 <= 16'd0; v_gstart2 <= 16'd0; v_gstart3 <= 16'd0; v_gstart4 <= 16'd0;
      v_glines1 <= 10'd0; v_glines2 <= 10'd0; v_glines3 <= 10'd0; v_glines4 <= 10'd0;
      v_gim <= 4'd0;        // the power-on SCROLL block is the machine's im = 0
      v_lr2 <= 5'd0;        // the captured CSRFORM reset: lr = 1, one stride per raster line
      v_pstride <= 8'd80;   // PITCH 40 at 2.5 MHz (the reset values above)
      v_gpitch  <= 8'd40;   // gdc2_pitch's reset value
    end else begin
      // The CSRFORM line repeat is a single field with no multi-register coherence to
      // preserve, so it needs only a frame-boundary latch, not the cfg_dirty handshake.
      if (w_start || (pixel_ce && frame_end)) v_lr2 <= gdc2_lr;
      if (w_start || (pixel_ce && frame_end))
        v_pstride <= (gdc_5m ? gdc2_pitch : {gdc2_pitch[6:0], 1'b0}) & 8'hFE;
      if (w_start || (pixel_ce && frame_end)) v_gpitch <= gdc2_pitch;
      if (snap_now) begin
        v_gstart1 <= g_start_w[0]; v_gstart2 <= g_start_w[1];
        v_gstart3 <= g_start_w[2]; v_gstart4 <= g_start_w[3];
        v_glines1 <= g_lines_w[0]; v_glines2 <= g_lines_w[1];
        v_glines3 <= g_lines_w[2]; v_glines4 <= g_lines_w[3];
        v_gim <= g_im_w;
      end
    end
  end

  reg  [1:0]  w_part;     // the partition of the line w_vad addresses, 0..3
  reg  [9:0]  w_remain;   // NP2kai's remain: raster lines left in the partition
  reg  [4:0]  w_mulc;     // NP2kai's mul - 1: raster lines left before the next step
  reg  [15:0] w_vad;      // NP2kai's vad, 16 bits (the packed walk's page is bit 15)
  reg         w_ph;       // the raster line's parity when the walker last stepped
  reg         w_nz;       // the raster line was not line 0 when the walker last looked
  // The next partition's fields, and this one's step.
  // THE PACKED (256-colour) WALK differs in three ways, all NP2kai vram/makegrex.c's: its
  // stride is v_pstride (the guest's PITCH and the GDC clock, not the im bit), and
  // makegrphex loops `grphput(&mg, 0)` / `grphput(&mg, 4)` only - partition 2 returns to
  // partition 1, the TEXTW slots are never a display partition - and grphput_all steps
  // `vad = LOW16(vad + mg.pitch)` on EVERY raster line, never reading the CSRFORM line
  // repeat (MAME pc9821.cpp's packed draw has no repeat either). w_pk2 is the 2 -> 1 wrap,
  // w_lr the repeat the walk runs on.
  wire        w_pk2    = pegc_256 && (w_part == 2'd1);
  wire [4:0]  w_lr     = pegc_256 ? 5'd0 : v_lr2;
  wire [15:0] w_nstart = w_pk2 ? v_gstart1 :
                         (w_part == 2'd0) ? v_gstart2 : (w_part == 2'd1) ? v_gstart3 :
                         (w_part == 2'd2) ? v_gstart4 : v_gstart1;
  wire [9:0]  w_nlines = w_pk2 ? v_glines1 :
                         (w_part == 2'd0) ? v_glines2 : (w_part == 2'd1) ? v_glines3 :
                         (w_part == 2'd2) ? v_glines4 : v_glines1;
  wire [7:0]  w_gstep  = (v_gim[w_part] ? v_gpitch : {v_gpitch[6:0], 1'b0}) & 8'hFE;
  wire [15:0] w_pitch  = pegc_256 ? {8'd0, v_pstride} : {8'd0, w_gstep};
  // One step of the walk to the next line (NP2kai's per-line tail).
  wire        w_s_next = (w_remain == 10'd1);
  wire [15:0] w_s_vad  = w_s_next ? w_nstart :
                         (w_mulc == 5'd0) ? w_vad + w_pitch : w_vad;
  // The raster advanced a line and the walker has not stepped for it yet.
  // The parity alone misses the frame wrap of an ODD frame (VTOTAL-1 and 0 are both even):
  // the BIOS 31 kHz blocks are 449 and 525 lines (NP2kai bios/bios18.c gdcmastersync[2..5]),
  // and the walk then held one line across the wrap and showed every line below row 1 one
  // raster line late. The wrap is the step into line 0 from any other line.
  wire        w_lag    = (vline[0] != w_ph) || ((vline == 10'd0) && w_nz);
  // ...and the decode line is past the window's first line: above grph_vbp the walk waits
  // at its line 0 (makegrph starts at mg.liney = grph_vbp).
  wire        w_adv    = w_lag && (v_oline > {4'd0, v_gvbp});
  // Row 0's address, in the cycle the walk restarts.
  wire [15:0] w_i_vad  = snap_now ? g_start_w[0] : v_gstart1;
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      v_wrap_d <= 1'b0;
      w_part <= 2'd0; w_remain <= 10'd0; w_mulc <= 5'd0; w_vad <= 16'd0; w_ph <= 1'b0; w_nz <= 1'b0;
    end else begin
      v_wrap_d <= v_wrap;
      w_ph     <= vline[0];
      w_nz     <= (vline != 10'd0);
      if (w_start) begin
        w_part   <= 2'd0;
        w_vad    <= w_i_vad;
        w_remain <= snap_now ? g_lines_w[0] : v_glines1;
        w_mulc   <= pegc_256 ? 5'd0 : gdc2_lr;
      end else if (w_adv) begin
        w_vad <= w_s_vad;
        if (w_s_next) begin
          w_part   <= w_pk2 ? 2'd0 : w_part + 2'd1;
          w_remain <= w_nlines;
          w_mulc   <= w_lr;
        end else begin
          w_remain <= w_remain - 10'd1;
          w_mulc   <= (w_mulc == 5'd0) ? w_lr : w_mulc - 5'd1;
        end
      end
    end
  end

  // The decode line's address: the walker's, or - in the clk_sys the raster advanced and the
  // walker's update has not landed yet - the restart value or the step being taken.
  wire [15:0] v_gline = w_start ? w_i_vad : w_adv ? w_s_vad : w_vad;
  assign gfx_line_addr = {display_page, v_gline[14:0]};
  assign gfx_walk_page = v_gline[15];
  assign gfx_disp = gdc2_grph_start;
  assign gfx_grph_on = gdc2_grph_start && !gfx_win_off;

  // ---------------------------------------------------------------
  // The 0xA0 status read and the 0xA2 parameter read-back. 0x60 and 0xA0 answer the
  // same byte: bit 2 set is "the FIFO is empty", bit 5 is VSYNC, bit 6 the blank
  // interval. BIT 0 IS NOT SHARED: the 0x60 arm's is pc9821_crtc's stat_dr toggle
  // (the machine's bit 0 moves there), while 0xA0's is READ-BACK DATA AVAILABLE -
  // the queue nonempty (NP2kai gdc_ia0 `if (gdc.s.snd) ret |= 0x01;`,
  // io/gdc.c:764-765). The 2M-sample histogram's dead bit 0 at 0xA0
  // (docs/probes/GDC.TXT) does not refute that: the probe
  // never arms a slave read-back (tools/hwprobe/probe2/probe2.s:1684-1730 (`sec_gdc:`) samples
  // the bare status port), so the queue is empty all capture and "hardwired 0" is
  // indistinguishable from "empty". 0xA2 is NOT a second status byte: it pops the slave's parameter
  // read-back queue and answers 0xFF with nothing pending (NP2kai gdc_ia2,
  // io/gdc.c:813-820) - the machine agrees (probes/PROBE.TXT `GDC status 60 A0 A2:
  // 05 04 ff`, i.e. 0xA2 = 0xFF while 0xA0 carried the status).
  // ---------------------------------------------------------------
  // Bit 2 (FIFO empty) is the same queue's complement: the Xe10 read the slave status as 0x04
  // with nothing queued and 0x01 after arming a read-back (docs/probes/RDBACK.TXT:172
  // `00A0 status before arm = 04 ; after 0xE0 arm = 01`; `after 0xC0 arm = 01`).
  // Bit 3 is DRAWING: a WRITE or a figure in the engine, queued or armed - the Xe10 reads
  // 0x0C through a draw and 0x04 after it (GDCFIFO DRAW_BURST/POST_DRAW). Bit 1 is the
  // command FIFO full, and bit 2 also needs that FIFO empty (a byte queued behind a draw).
  wire       gdc2_drawing = (d_state != D_IDLE) || pend_valid || fig_pend;
  wire [7:0] gdc2_status = {1'b0, stat_blank, stat_vsync, 1'b0, gdc2_drawing,
                            (gdc2_snd_cnt == 3'd0) && !cf_busy_w, (cf_cnt == 5'd16),
                            (gdc2_snd_cnt != 3'd0)};   // bit 0: read-back data available
  assign io_dout = (io_addr == 8'hA0) ? gdc2_status :
                   (io_addr == 8'hA2) ? gdc2_snd_q  : 8'hFF;

endmodule

// A fixed-rate enable for pc9821_gdc2's draw pacing: one clk_sys cycle in every PERIOD_NS ns of
// real time, as an exact ratio at any clk_sys (ce fires NUM times every DEN clocks, NUM/DEN =
// 1e9 / (PERIOD_NS x SYS_FREQ), reduced: 1/126 for 1400 ns at the shipped 90 MHz, 1/70 at
// 50 MHz). `restart` (a job's start) zeroes the accumulator, so the k-th enable after it falls
// k x PERIOD_NS later, to within one clk_sys. It lives in this file because it is pc9821_gdc2's
// private half (built only when a pace is set).
/* verilator lint_off DECLFILENAME */
module pc9821_gdc2_pace #(
    parameter integer SYS_FREQ = 50_000_000,
    parameter integer PERIOD_NS = 1400
) (
    input  wire clk_sys,
    input  wire restart,
    output wire ce
);
  function automatic longint gcd(input longint a, input longint b);
    longint x, y, t;
    x = a;
    y = b;
    while (y != 0) begin
      t = x % y;
      x = y;
      y = t;
    end
    return x;
  endfunction

  localparam longint NUM_RAW = 64'd1_000_000_000;
  localparam longint DEN_RAW = longint'(PERIOD_NS) * longint'(SYS_FREQ);
  localparam longint G       = gcd(NUM_RAW, DEN_RAW);
  localparam longint NUM     = NUM_RAW / G;
  localparam longint DEN     = DEN_RAW / G;
  localparam integer W       = $clog2(DEN + NUM + 1);

  // The period must be longer than one clk_sys. The guard is an instance of a module that does
  // not exist, so such a configuration fails elaboration in every tool (as pc9821_dot_ce's).
  generate if (NUM >= DEN) begin : g_too_fast
    pc9821_gdc2_pace_period_needs_more_than_one_clk_sys too_fast ();
  end endgenerate

  reg  [W-1:0] acc = '0;
  wire [W-1:0] sum = acc + W'(NUM);
  assign ce = !restart && (sum >= W'(DEN));
  always @(posedge clk_sys)
    acc <= restart ? '0 : ce ? sum - W'(DEN) : sum;
endmodule
/* verilator lint_on DECLFILENAME */

`default_nettype wire

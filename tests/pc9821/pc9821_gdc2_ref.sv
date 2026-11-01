// TEST REFERENCE: pc9821_gdc2 as of 3b134fe4 (before the area-video pass), renamed. Never edited, except that the 0xA0 status bit-2 behaviour change (FIFO empty clears while read-back data is queued, docs/probes/RDBACK.TXT:172) is mirrored from the shipped module so the pair stays equivalent, so are the two figure-engine changes the WRITE slice can see - CSRW's third byte loads the mask with its dAD one-hot (the Xe10's GDCCURS MASK_THEN_CURS rows) and the 0xA0 status bit 3 reads DRAWING while the engine holds a job -, and so is the walker's odd-frame wrap step (w_nz) and the packed walk's stride (the PITCH command 0x47 kept, stepped as NP2kai vram/makegrex.c:286-291 from PITCH and the gdc_5m clock input instead of the SCROLL im bit while pegc_256), and the planar walk's step from the same PITCH byte and the SCROLL im bit (NP2kai vram/makegrph.c:147-151) instead of a constant 40; the lockstep bench tb_pc9821_gdc2_equiv proves the shipped module against it.
// PC-9821 GDC2 (the graphics GDC) display-address generator.
//
// The slave GDC's SCROLL parameter block, its START/STOP display latch, and the byte
// address of the raster line being scanned (gfx_line_addr) that pc9821_gvram_scan's
// line fetch consumes. It is the part of the old pc9821_gdc_text that the graphics
// scanout asks about; the raster and the text render are pc9821_crtc's now, and the
// glyph path is pc9821_cg's.
//
// One clock: clk_sys gated by pixel_ce, the same enable the raster counts on. There is
// no second video clock.
`default_nettype none

module pc9821_gdc2_ref (
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
    input wire        gdc_5m,        // mirrored: the packed stride's clock select
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
  // (io/gdc_cmd.h:34,38: GDC_CSRFORM = 9, GDC_LPEN = 29 - the old "share slots
  // 29-31" claim was false), slots no command writes (no gdc_cmd.tbl row stores
  // to pos 29) which gdc_reset zero-fills (io/gdc.c:1160): 00 00 00.
  reg [7:0] gdc2_csrw[0:2];
  // The armed parameter capture (a command arms one block; a new command discards it,
  // NP2kai gdc_work taking the command branch first). RCV_VECTW/RCV_CODE/RCV_MASK are
  // the GDC2 WRITE slice: VECTW (0x4C) keeps eleven bytes (io/gdc_cmd.tbl row 0x4c), MASK
  // (0x4A) two, and the WRITE family's data bytes land in GDC_CODE - NP2kai's
  // `item->ptr = GDC_CODE; item->rcv = 2/1/0` in the `(data & 0x60) == 0x20` arm
  // (io/gdc.c gdc_work).
  localparam [2:0] RCV_NONE = 3'd0, RCV_CSRW = 3'd1, RCV_CSRFORM = 3'd2,
                   RCV_VECTW = 3'd3, RCV_CODE = 3'd4, RCV_MASK = 3'd5,
                   RCV_PITCH = 3'd6;   // mirrored
  reg [7:0] gdc2_pitch;               // mirrored
  reg [3:0] gdc2_recv_left;  // parameter bytes the armed block still owes (0..11)
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
  // by source order (the single-cycle event discipline R1/R2). `draw_drops` counts the
  // jobs dropped for want of a queue: a WRITE completing while a draw is still walking
  // snapshots its job into the engine's pending slot, and a THIRD in flight is the
  // command FIFO this slice does not model (the conformance capture's FIFO_TURN/STATE rows).
  reg [3:0]  draw_drops;   // bench-visible telemetry, not guest-visible

  // ---- The WRITE engine's job (the GDC2 WRITE slice) ----
  // The job is SNAPSHOTTED at the trigger into `pend` (the parse's registers are free
  // to move afterwards - a later MASK/CSRW/VECTW must not retarget a draw already
  // queued), and the engine drains `pend` into its working registers. The plane is the
  // CSRW block's bits 15:14 through NP2kai's gdcplaneseg[] = {VRAM_E, VRAM_B, VRAM_R,
  // VRAM_G} (io/gdc_sub.c), so in the plane-lane order the GVRAM uses (0 = B at
  // 0xA8000, 1 = R, 2 = G, 3 = E) the map is GDC plane n -> lane n-1 (mod 4).
  localparam [2:0] D_IDLE = 3'd0, D_RD = 3'd1, D_RDW = 3'd2,
                   D_WR = 3'd3, D_NEXT = 3'd4;
  reg [2:0]  d_state;
  reg [16:0] d_left;      // units still to paint: VECTW[1..2] + 1, NP2kai's leng
  reg [13:0] d_waddr;     // the word in the plane: CSRW's low 14 bits
  reg  [1:0] d_rop;       // the command byte's low two bits
  reg  [2:0] d_ope;       // VECTW byte 0's low three bits: the direction (vectdir[])
  reg [15:0] d_color;     // INTERNAL-domain write pattern
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
  wire draw_fire_w = io_wr && (io_addr == 8'hA0) && !gdc2_sync_pend &&
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
  wire [3:0]  d_be_w = d_waddr[0] ? 4'b1100 : 4'b0011;
  wire [31:0] d_din_w = d_waddr[0] ? {rev16(d_color & d_mask), 16'h0000}
                                   : {16'h0000, rev16(d_color & d_mask)};
  // The plain path's merge read, ROPped in the cycle its datum answers (no d_old
  // register: the strobe's datum is consumed exactly once, by this wire's capture).
  wire [15:0] d_rd_i = rev16(d_waddr[0] ? mem_rdata[31:16] : mem_rdata[15:0]);
  wire [15:0] d_res_i = gdc_rop16(d_rop, d_rd_i, d_color, d_mask);
  wire [31:0] d_din_merge_w = d_waddr[0] ? {rev16(d_res_i), 16'h0000}
                                         : {16'h0000, rev16(d_res_i)};
  // The engine takes the job when idle; `pend_valid` is written once per cycle below.
  wire d_load_w = pend_valid && (d_state == D_IDLE);

  // The slave GDC's PITCH: 40 words, one 640-dot line, and a constant because nothing in
  // the target changes it (no 0x47 reaches 0xA2; 40 is the chip's reset value - NP2kai
  // io/gdc.c:1107). The address step per display line is the SCROLL length word's "im"
  // bit (bit 14), which is the display-address increment select and is PER PARTITION:
  // im clear doubles the pitch, im set uses it as programmed (NP2kai
  // vram/makegrph.c:146-148 `if (!(remain & (1 << 14))) pitch <<= 1; pitch &= 0xfe;`,
  // read from `para[GDC_SCROLL + gpos + 2]`; MAME upd7220.cpp:611/624 `*im =
  // BIT(m_ra[index * 4 + 3], 6)` and pc9821.cpp:103-106 `pitch << (im ^ 1)` - the two
  // references agree on both the bit and its effect).
  //
  // So the stride is whatever the GUEST programs, which is the authentic path: the games
  // build im from BIOS work-area 0000:054D bit 2 - clear is 2.5 MHz, set is 5 MHz
  // (rec98/th01/hardware/scrollup.cpp:22-27, libs/master.lib/graph_400line.asm) - and
  // this machine's own state is that bit clear, where the im bit is 0 and the step is
  // 2 x PITCH. The doubling is therefore this machine's DEFAULT, not a hard-wired
  // constant: a guest that programs im = 1 (a 5 MHz machine) gets PITCH.
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
  wire        adv_xp_w = (d_ope == 3'd1) || (d_ope == 3'd2) || (d_ope == 3'd3);
  wire        adv_xm_w = (d_ope == 3'd5) || (d_ope == 3'd6) || (d_ope == 3'd7);
  wire        adv_yp_w = (d_ope == 3'd0) || (d_ope == 3'd1) || (d_ope == 3'd7);
  wire        adv_ym_w = (d_ope == 3'd3) || (d_ope == 3'd4) || (d_ope == 3'd5);
  // The dot step in the INTERNAL numbering (bit 0 = the leftmost pixel): +x shifts the
  // mask one dot up, wrapping into the neighbouring word's opposite end at the word's
  // edge - the same fold the unit walk's wrap gives (NP2kai's `(adrs + 2) & 0x7ffe`).
  wire        adv_wrap_p_w = adv_xp_w && d_mask[15];
  wire        adv_wrap_m_w = adv_xm_w && d_mask[0];
  wire [15:0] adv_mask_w = adv_xp_w ? (d_mask[15] ? 16'h0001 : {d_mask[14:0], 1'b0}) :
                           adv_xm_w ? (d_mask[0]  ? 16'h8000 : {1'b0, d_mask[15:1]}) :
                           d_mask;
  wire [13:0] adv_pitch_w = {6'd0, GDC2_PITCH};
  wire [13:0] adv_waddr_w = (adv_yp_w ? d_waddr + adv_pitch_w :
                             adv_ym_w ? d_waddr - adv_pitch_w : d_waddr) +
                            (adv_wrap_p_w ? 14'd1 :
                             adv_wrap_m_w ? (14'd0 - 14'd1) : 14'd0);
  // The cursor write-back: the machine advances CSRW's EAD and the MASK register (the
  // CURD rows read both back after a draw), so the NEXT command starts from the
  // advanced cursor. A guest CSRW/MASK parameter write during the draw (or landing in
  // the SAME clk_sys as the final advance - `wb_*_w` below) WINS: it is the later
  // intent, and the draw leaves that register alone. Named here rather than resolved
  // by assignment order (the single-cycle event discipline R2/R3); the same-cycle
  // guard is the combinational term because the sticky flag cannot see its own cycle.
  reg  d_csrw_touch, d_mask_touch;
  wire wb_csrw_w = io_wr && (io_addr == 8'hA0) && !gdc2_sync_pend &&
                   (gdc2_recv_tgt == RCV_CSRW) && (gdc2_recv_left != 4'd0);
  wire wb_mask_w = io_wr && (io_addr == 8'hA0) && !gdc2_sync_pend && (gdc2_recv_left != 4'd0) &&
                   ((gdc2_recv_tgt == RCV_MASK) ||
                    ((gdc2_recv_tgt == RCV_CSRW) && (gdc2_recv_ptr[1:0] == 2'd2)));   // mirrored

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
      draw_drops <= 4'd0;
      d_csrw_touch <= 1'b0;
      d_mask_touch <= 1'b0;
      d_state <= D_IDLE;
      d_left <= 17'd0;
      d_waddr <= 14'd0;
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
    if (io_wr && (io_addr == 8'hA2)) begin
      // GDC2 command port SCROLL (0x70..0x77): the low nibble is the byte of the
      // parameter block the command starts at, so 0x70 writes all sixteen bytes and
      // 0x74 the last twelve (gdc_cmd.tbl).
      // Nothing is "executed": the scanout reads the block continuously (NP2kai
      // vram/makegrph.c:145-148 reads gdc.s.para[] every line), so bytes take effect as
      // they arrive - there is deliberately no completion event to wait for, which is
      // also why the FIFO-empty bit below never has to go clear.
      // Every command ALSO replaces the parameter read-back queue (NP2kai gdc_work:
      // `item->snd = gdc_cmd[data].indatas`, io/gdc.c:327): 0xE0 CSRR answers five
      // bytes {CSRW0, CSRW1, CSRW2&3, 0, 0} and 0xC0 LPEN the three light-pen
      // slots para[29..31] (gdc_cmd.tbl:214) - never written, so gdc_reset's
      // zeros (io/gdc.c:1160), NOT the CSRFORM bytes (GDC_CSRFORM = 9,
      // GDC_LPEN = 29, io/gdc_cmd.h:34,38).
      gdc2_snd_ptr <= 3'd0;
      case (io_din)
        8'hE0: begin
          gdc2_snd[0] <= gdc2_csrw[0];
          gdc2_snd[1] <= gdc2_csrw[1];
          // The Xe10's CURD (GDCCURS.CSV raw_curd, GDCWG.CSV WG row): see pc9821_gdc2.sv.
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
      gdc2_sync_pend <= (io_din == 8'h0F) || (io_din == 8'h0E);
      gdc2_sync_cnt  <= 3'd0;
      if (io_din[7:4] == 4'h7) begin
        // SCROLL 0x70-0x77 and TEXTW 0x78-0x7F: one 16-byte parameter RAM (gdc_cmd.tbl
        // rows 0x70-0x7F: pos GDC_SCROLL + k, 16 - k bytes)
        gdc2_ptr  <= io_din[3:0];
        gdc2_left <= 5'd16 - {1'b0, io_din[3:0]};
        gdc2_recv_left <= 4'd0;   // a SCROLL command discards a pending parameter count
      end else begin
        // The display commands, deliberately the SAME bytes the text GDC takes on
        // 0x62: the slave's half of one mechanism (NP2kai io/gdc_cmd.h CMD_START =
        // 0x0d, CMD_STOP = 0x0c, CMD_SYNC_ON = 0x0f, CMD_SYNC_OFF = 0x0e).
        // SYNC_ON/OFF take EIGHT parameter bytes (io/gdc_cmd.tbl:24-25), captured on
        // 0xA0 below and dropped: the raster is the master's block's (see
        // gdc2_sync_pend).
        if (io_din == 8'h0D || io_din == 8'h6B) begin
          gdc2_grph_start <= 1'b1;   // START / BCTRL on
        end else if (io_din == 8'h0C || io_din == 8'h05) begin
          gdc2_grph_start <= 1'b0;   // STOP / BCTRL off
        end else if (io_din == 8'h0F || io_din == 8'h0E) begin
          gdc2_grph_start <= io_din[0];   // SYNC on (0x0F) / off (0x0E)
        end
        // The rest of the command space has no display customer. A command byte
        // discards an unfulfilled parameter count (NP2kai's gdc_work takes the
        // command branch first), so the next 0xA0 byte cannot be misread.
        // 0x49 CSRW and 0x4B CSRFORM are the exceptions: their parameter bytes
        // are consumed here - CSRW's three are kept for CSRR, and CSRFORM's FIRST
        // byte is also the display line step (the firmware sends one byte,
        // BANK6@0x787e-0x788c); NP2kai takes three and the rest of the count is
        // discarded by the next command exactly as here.
        if (io_din == 8'h49) begin
          gdc2_recv_tgt  <= RCV_CSRW;
          gdc2_recv_left <= 4'd3;
          gdc2_recv_ptr  <= 4'd0;
        end else if (io_din == 8'h4B) begin
          gdc2_recv_tgt  <= RCV_CSRFORM;
          gdc2_recv_left <= 4'd3;
          gdc2_recv_ptr  <= 4'd0;
        end else if (io_din == 8'h4C) begin
          // VECTW: eleven parameter bytes (io/gdc_cmd.tbl row 0x4c). Only the
          // second and third have a consumer in this slice - they are the unit
          // count the WRITE command walks (NP2kai gdcsub_write's
          // `leng = LOADINTELWORD(gdc.s.para + GDC_VECTW + 1) + 1`).
          gdc2_recv_tgt  <= RCV_VECTW;
          gdc2_recv_left <= 4'd11;
          gdc2_recv_ptr  <= 4'd0;
        end else if (io_din == 8'h47) begin   // mirrored: PITCH, one byte
          gdc2_recv_tgt  <= RCV_PITCH;
          gdc2_recv_left <= 4'd1;
          gdc2_recv_ptr  <= 4'd0;
        end else if (io_din == 8'h4A) begin
          // MASK: two parameter bytes, the write mask the WRITE command paints
          // through (io/gdc_cmd.tbl row 0x4a, NP2kai gdcsub_write's GDC_MASK).
          gdc2_recv_tgt  <= RCV_MASK;
          gdc2_recv_left <= 4'd2;
          gdc2_recv_ptr  <= 4'd0;
        end else if ((io_din & 8'h60) == 8'h20) begin
          // The WRITE family (NP2kai gdc_work's `(data & 0x60) == 0x20` arm): the
          // command byte keeps the ROP in its low two bits and the transfer width
          // in bits 4:3, and its data bytes go to GDC_CODE. The 8'h08 width takes
          // no data byte (and never executes - NP2kai's rcv = 0 arm never reaches
          // its gdcsub_write call), 8'h00 takes two, the byte widths one.
          gdc2_wcmd      <= io_din;
          gdc2_recv_tgt  <= RCV_CODE;
          gdc2_recv_ptr  <= 4'd0;
          case (io_din & 8'h18)
            8'h00:   gdc2_recv_left <= 4'd2;
            8'h08:   gdc2_recv_left <= 4'd0;
            default: gdc2_recv_left <= 4'd1;
          endcase
        end else gdc2_recv_left <= 4'd0;
        gdc2_left <= 5'd0;
      end
    end else if (io_wr && (io_addr == 8'hA0)) begin
      if (gdc2_sync_pend) begin
        // The slave's SYNC block byte: AL and VBP are kept (see gdc2_sal), the rest consumed.
        if (gdc2_sync_cnt == 3'd6) gdc2_sal[7:0] <= io_din;
        if (gdc2_sync_cnt == 3'd7) begin
          gdc2_sal[9:8] <= io_din[1:0];
          gdc2_svbp     <= io_din[7:2];
          gdc2_sync_pend <= 1'b0;
          gdc2_sync_cnt  <= 3'd0;
        end else gdc2_sync_cnt <= gdc2_sync_cnt + 3'd1;
      end else if (gdc2_recv_left != 4'd0) begin
        case (gdc2_recv_tgt)
          RCV_CSRW: begin   // mirrored: the third byte's dAD loads the one-hot mask
            gdc2_csrw[gdc2_recv_ptr[1:0]] <= io_din;
            if (gdc2_recv_ptr[1:0] == 2'd2) begin
              gdc2_mask[0] <= (io_din[7] == 1'b0) ? (8'h01 << io_din[6:4]) : 8'h00;
              gdc2_mask[1] <= (io_din[7] == 1'b1) ? (8'h01 << io_din[6:4]) : 8'h00;
            end
          end
          RCV_CSRFORM: if (gdc2_recv_ptr == 4'd0)
                         gdc2_lr <= io_din[4:0];   // CSRFORM[4:0] = lr-1 (NP2kai vram/makegrph.c:362)
          RCV_VECTW:   gdc2_vect[gdc2_recv_ptr[3:0]] <= io_din;
          RCV_CODE:    gdc2_code[gdc2_recv_ptr[0]] <= io_din;
          RCV_MASK:    gdc2_mask[gdc2_recv_ptr[0]] <= io_din;
          RCV_PITCH:   gdc2_pitch <= io_din;   // mirrored
          default: ;
        endcase
        gdc2_recv_ptr  <= gdc2_recv_ptr + 4'd1;
        gdc2_recv_left <= gdc2_recv_left - 4'd1;
      end else if (gdc2_left != 5'd0) begin
        gdc2_scr[gdc2_ptr] <= io_din;
        gdc2_ptr  <= gdc2_ptr + 4'd1;   // wraps at 16 with gdc2_left at 0
        gdc2_left <= gdc2_left - 5'd1;
      end
    end

    // ---------------------------------------------------------------
    // The WRITE engine (the GDC2 WRITE slice). One writer per register: each of
    // pend_valid/draw_drops, the job registers and the visit registers is assigned in
    // exactly one arm of this block per cycle (the single-cycle event discipline R1/R2;
    // the trigger's set and clear are one assignment each, never two arms racing).
    //
    // The job is SNAPSHOTTED at the trigger - the parse's registers are free to move
    // afterwards, so a later MASK/CSRW/VECTW cannot retarget a draw already queued.
    // The fill wins over a same-cycle drain (`!pend_valid || d_load_w`), so a job is
    // never dropped while a slot frees in that very cycle. A THIRD draw in flight is
    // the command FIFO this slice does not model (the conformance capture's FIFO_TURN/STATE rows) and
    // is dropped into `draw_drops`, which the bench reads over a hierarchical name.
    // ---------------------------------------------------------------
    if (draw_fire_w && (!pend_valid || d_load_w)) begin
      pend_wctl  <= {gdc2_wcmd[4:3], gdc2_wcmd[1:0]};
      pend_wg    <= gdc2_csrw[2][3];
      pend_code0 <= (gdc2_recv_ptr[0] == 1'b0) ? io_din : gdc2_code[0];
      pend_code1 <= (gdc2_recv_ptr[0] == 1'b0) ? gdc2_code[1] : io_din;
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
    end else if (draw_fire_w) begin
      draw_drops <= draw_drops + 4'd1;
    end
    // The cursor write-back's touch flags: set by any guest cursor write, cleared when
    // a job is taken. ONE assignment each per cycle (R1/R2), so the load's clear and a
    // same-cycle guest write cannot collide by source order - the write wins.
    d_csrw_touch <= wb_csrw_w || (d_csrw_touch && !d_load_w);
    d_mask_touch <= wb_mask_w || (d_mask_touch && !d_load_w);

    case (d_state)
      D_IDLE: if (d_load_w) begin
        d_rop        <= pend_wctl[1:0];
        d_ope        <= pend_dir;
        d_color      <= pend_col_w;
        d_mask       <= pend_msk_w;
        d_waddr      <= {pend_csrw1[5:0], pend_csrw0};
        d_route_egc  <= pend_egc;
        d_route_grcg <= pend_grcg;
        d_left       <= {1'b0, pend_vect2, pend_vect1} + 17'd1;   // NP2kai's leng
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
      D_WR: if (mem_ready) begin
        mem_valid <= 1'b0;
        // Every painted unit advances the cursor one dot along the direction (the
        // advance block above), the last one included - the machine's CURD readback
        // shows it advanced after a one-unit draw (STEP_DC00_*).
        if (d_left == 17'd1) begin
          d_state <= D_IDLE;
          if (!d_csrw_touch && !wb_csrw_w) begin
            gdc2_csrw[0] <= adv_waddr_w[7:0];
            gdc2_csrw[1] <= {gdc2_csrw[1][7:6], adv_waddr_w[13:8]};
          end
          if (!d_mask_touch && !wb_mask_w) begin
            gdc2_mask[0] <= adv_mask_w[7:0];
            gdc2_mask[1] <= adv_mask_w[15:8];
          end
        end else begin
          d_left  <= d_left - 17'd1;
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
        mem_offset <= {d_waddr, 1'b0};
        d_state    <= d_need_rd_w ? D_RD : D_WR;
      end
      default: d_state <= D_IDLE;
    endcase
    end
  end

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
  reg [7:0]  v_pstride;     // mirrored
  reg [7:0]  v_gpitch;      // mirrored (the planar walk's PITCH)
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
      v_pstride <= 8'd80;   // mirrored
      v_gpitch  <= 8'd40;   // mirrored
    end else begin
      // The CSRFORM line repeat is a single field with no multi-register coherence to
      // preserve, so it needs only a frame-boundary latch, not the cfg_dirty handshake.
      if (w_start || (pixel_ce && frame_end)) v_lr2 <= gdc2_lr;
      if (w_start || (pixel_ce && frame_end))   // mirrored
        v_pstride <= (gdc_5m ? gdc2_pitch : {gdc2_pitch[6:0], 1'b0}) & 8'hFE;
      if (w_start || (pixel_ce && frame_end)) v_gpitch <= gdc2_pitch;   // mirrored
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
  reg         w_nz;       // the raster line was not line 0 when the walker last looked   // mirrored
  // The next partition's fields, and this one's step.
  // THE PACKED (256-colour) WALK differs in two ways, both NP2kai vram/makegrex.c's:
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
  wire [7:0]  w_gstep  = (v_gim[w_part] ? v_gpitch : {v_gpitch[6:0], 1'b0}) & 8'hFE;   // mirrored
  wire [15:0] w_pitch  = pegc_256 ? {8'd0, v_pstride} : {8'd0, w_gstep};   // mirrored
  // One step of the walk to the next line (NP2kai's per-line tail).
  wire        w_s_next = (w_remain == 10'd1);
  wire [15:0] w_s_vad  = w_s_next ? w_nstart :
                         (w_mulc == 5'd0) ? w_vad + w_pitch : w_vad;
  // The raster advanced a line and the walker has not stepped for it yet.
  wire        w_lag    = (vline[0] != w_ph) || ((vline == 10'd0) && w_nz);   // mirrored
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
  // 05 04 ff`, i.e. 0xA2 = 0xFF while 0xA0 carried the status), which is what
  // is the defect this fixes.
  // ---------------------------------------------------------------
  wire [7:0] gdc2_status = {1'b0, stat_blank, stat_vsync, 1'b0,
                            (d_state != D_IDLE) || pend_valid,   // mirrored: DRAWING
                            (gdc2_snd_cnt == 3'd0), 1'b0,
                            (gdc2_snd_cnt != 3'd0)};   // bit 0: read-back data available
  assign io_dout = (io_addr == 8'hA0) ? gdc2_status :
                   (io_addr == 8'hA2) ? gdc2_snd_q  : 8'hFF;

endmodule

`default_nettype wire

// PC-9821 PEGC packed scanout: the 256-colour line fetch, ping-pong line buffer
// and byte select.
//
// The scanout is a SIBLING of pc9821_gvram_scan (the planar fetch), not a
// widening of it: the planar path is capture-pinned and dot-timed, so the packed
// fetch keeps its own module, its own buffer and its own requester. What it
// shares is the raster's own view: the line tick, the GDC's line base and the
// mixer's column read address. The line is 640 bytes = 160 dwords, fetched as
// SDRAM bursts on the FOURTH requester (row 6), 2 x 160-dword ping-pong buffers
// in 2 M10K.
//
// ADDRESSING (the references agree): the packed byte base is the planar line
// base with the page folded in and shifted by three - {page, GDC line base[14:0],
// 3'b000} (MAME pc9821.cpp:104-113 `(...) << 3` over the GDC's area partition;
// qemu pc98-vga.c:4426-4437 walks 640 bytes per row from the page base). THE PAGE
// IS TWO TERMS, and the flip register the 256-colour games double-buffer through
// is the FIRST one:
//   scan_walk_page - the GDC2 SCROLL start word's bit 14, doubled into the walk's
//     bit 15 (pc9821_gdc2's gfx_walk_page). NP2kai's packed arm walks
//     `LOW16(vad << 1)` over the full 512 KiB with the page in that bit
//     (vram/makegrex.c:199), MAME keeps it through `& 0xffff` and names the flip
//     register in its flashb note ("double buffering at SAD $38fc and $fffc",
//     pc9821.cpp:108-113), and the uPD7220 loads the SAD "at the start of the
//     display scanning process" - so the swap is a FRAME-BOUNDARY swap (the
//     machine's full frames at the game's composite rate), carried here already
//     latched by pc9821_gdc2's cfg_snap copy.
//   the 0xA4 display-page term (XORed onto the same bit: MAME adds
//     `m_vram_disp * 0x40000` to the walked address, pc9821.cpp:98,112), forced to
//     0 while the FF2 dat-0x68 VRAM boundary f/f is set (MAME pc9821.cpp:98
//     `BIT(m_ex_video_ff[0x68 >> 1], 0) ? 0 : m_vram_disp * 0x40000`; qemu forces
//     the page 0 in its 480-line arm the same way - the latch is FF2 dat 0x68,
//     NP2kai's GDCANALOG_256E, and MAME's use of it is the one that moves the
//     display). NP2kai's packed arm drops the
//     0xA4 term entirely (makegrex.c:292 takes the `gdc.analog & 4` arm whatever
//     `page` holds) and its NON-packed arm drops the walk's bit 15 (LOW15) - the
//     recorded divergence is exactly that bit: this core keeps it in both arms so
//     an SAD-bit-14 flip moves the display whatever the 256E latch holds, which is
//     what the machine does (a real Xe10 shows full frames under DOOM's flip).
// There is NO 200-line interleave here: the references copy
// packed rows directly (qemu 4422-4438, MAME 100-123), so gfx_odd_line is not
// even a port.
//
// BYTE SELECT: one dword covers four dots, the buffer's read is REGISTERED, and the
// byte is picked combinationally from the settled word by dot[1:0] (byte 0 = the
// group's leftmost dot, which is NP2kai's order: `vramex + vc*8 + 0..7` lands at the
// surface row's bytes 0..7 in order, vram/makegrex.c). The dword address is NOT the
// current dot's: it is presented for the dot the NEXT pixel enable will select, i.e.
// one clk EARLY at every 4-dot group boundary (`line_rd_dot`), because the 256-colour
// palette's read is REGISTERED (its table cannot be read asynchronously - the block
// types refuse it, measured at 2,264 ALMs) and so the pixel's index has to be on the
// palette's input one clk before the sample. Without that, the first cycle of a group
// still holds the PREVIOUS group's dword while the lane is the new dot's, and every dot
// that OPENS a group (one pixel in four, plus the first active dot of every line through
// the blank region) then displays the byte FOUR DOTS to the left - 160 of a line's 640
// dots (tb_pc9821_pegc_scan_dot measures 0).
//
// The register that captures the buffer read carries NO reset: a reset on that
// register makes Quartus refuse the inference and build the buffer out of flops
// (the 11,233-ALM trap pc9821_gfx_palette's header records). The value is
// applied on the wire instead.
//
// THE FETCH AND THE POSTED STORE ROUTE. The packed stores are posted
// (pc9821_pegc_storebuf: accept in one clk, combine, drain eagerly), and the fetch
// reads the SAME peg_base region on the fourth requester, so the two can overlap.
// THEY ARE MEASURED NOT TO OVERLAP HARMFULLY at the deployed timing: a store
// accepted before a line tick is already in SDRAM by the time this fetch's first
// response beat lands (tb_pc9821_pegc_store_rate's store-to-scanout legs: 0 stale
// bytes for both a second partial dword and eight queued partial stores), because
// the buffer's residency is one hold window (1 us) plus one drain while the FSM's
// first burst is ~50-100 clk_sys behind its tick. Holding each burst until the
// buffer reports empty would be COHERENT BY CONSTRUCTION - and starves the scanout
// under a store stream (10 response beats in 4 raster lines, measured), so the
// display would lose lines instead. The reference
// (NP2kai vram/makegrex.c reads vramex directly) has no such lag to model; the
// measured one is below the fetch's own resolution, so the fetch is left ungated.

`default_nettype none

module pc9821_pegc_scan (
    input  wire        clk,
    input  wire        reset,

    // The raster's view (the same ports pc9821_gvram_scan takes).
    input  wire        scan_enable,     // the packed fetch runs only in 256-colour mode
    input  wire        scan_line_tick,  // one pulse per raster line
    input  wire        scan_page,       // the 0xA4 display page
    input  wire        page_force_zero, // the FF2 dat-0x68 VRAM-boundary f/f
    input  wire        scan_walk_page,  // the GDC2 SCROLL walk's own page bit (gfx_walk_page)
    input  wire [14:0] scan_line_base,  // the GDC's line base (plane bytes)
    input  wire [6:0]  line_rd_addr,    // column 0..79 of the displayed line
    input  wire        line_rd_sel,
    input  wire [2:0]  dot_in_col,      // dot 0..7 within the column
    // The video-domain dot enable: it is HIGH during the clk_sys cycle the raster's dot
    // counter advances at the end of (pc9821_system's pixel_ce - the same signal the
    // framework latches its pixels on). It is what makes the one-clk-early address above
    // possible: the dot the next enable selects is the current one plus this.
    input  wire        dot_ce,
    // The raster's horizontal display window (pc9821_crtc's h_active). The COLUMN the
    // caller presents is pinned to 0 while the window is closed (pc9821_video_mixer:
    // `line_rd_addr = h_active ? col : 0`), so the early column carry is only real inside
    // it: at the blank->display boundary the next dot is column 0's dot 0, not column
    // 80's, and carrying there reads the wrong dword for the line's first active dot.
    input  wire        line_rd_act,
    output wire [7:0]  packed_idx,      // the palette index for THIS dot
    output wire        line_sel,
    output wire        line_ready,

    // Where the 512 KiB packed store lives (pc9821_memory_subsystem's peg_base).
    input  wire [31:0] peg_base,

    // The fourth SDRAM requester (row 6): read-only, burst fetches.
    output wire [31:0] mem_addr,
    output wire        mem_valid,
    output wire        mem_write,
    output wire  [3:0] mem_be,
    output wire  [7:0] mem_burstcount,
    output wire [31:0] mem_din,
    input  wire        mem_ready,
    input  wire [31:0] mem_dout,
    input  wire        mem_resp_valid
);

  // 640 bytes = 160 dwords per line, two buffers (2 M10K).
  localparam [8:0] LINE_WORDS = 9'd160;
  // A comfortable burst: 16 bursts of 10 dwords per line, well inside the
  // controller's 15-dword cap (split_sdram_backend clamps above it).
  localparam [3:0] BURST_LEN  = 4'd10;

  reg [31:0] lbuf [0:511];

  // ---- the fetch FSM: the pc9821_gvram_scan shape over SDRAM bursts ----
  // One burst in flight at a time. A line tick that lands while a burst is still
  // draining DEFERS the restart until the beats are consumed (a 10-beat burst is
  // ~20 clk_sdram, a fraction of the 2014-clk_sys line), so the response
  // accounting can never see two bursts' beats interleaved.
  reg  [8:0]  fetch_w;        // next dword of the line to request
  reg         fetch_active;
  reg  [18:0] line_base_q;    // packed byte base of the line being fetched
  reg  [18:0] line_base_next; // the deferred restart's base
  reg         restart_pend;   // a tick asked for a restart the burst has not earned
  reg         req_inflight;   // a burst is outstanding
  reg  [3:0]  beats_left;     // its remaining response beats
  reg  [8:0]  wr_idx;         // next dword of the line to fill
  reg         wr_sel;         // the buffer being filled (never line_sel_r)
  reg         line_sel_r;
  reg         line_ready_r;
  reg         scan_tick_d;
  reg         scan_enable_d;

  // The line tick is taken as an EDGE (the pc9821_gvram_scan reason: a level
  // wider than one clk_sys would toggle the ping-pong once per clk it is high).
  wire scan_tick = scan_line_tick & ~scan_tick_d;
  wire scan_arm  = scan_enable & ~scan_enable_d;

  wire burst_idle = !req_inflight && (beats_left == 4'd0);
  // The previous line's fill is done exactly when no fetch of it is still active
  // (the gvram_scan `fill_complete` rule: hold and repeat the previous line
  // rather than ever blending one).
  wire prev_done = !fetch_active;
  // EVERY LIVE BURST IS THE FULL BURST_LEN, so there is no burst_words subtractor:
  // fetch_w is ALWAYS a multiple of BURST_LEN. Reset/restart write it to 0
  // (`fetch_w <= 9'd0;`); its only other write adds BURST_LEN (`fetch_w <= fetch_w +
  // {5'd0, BURST_LEN};`); and a request is live only while `fetch_w < LINE_WORDS`. LINE_WORDS
  // = 160 = 16 x BURST_LEN exactly, so the values a live request can hold are
  // 0, 10, ..., 150 - each leaves at least one full burst (160 - 150 = 10 =
  // BURST_LEN), so a min() `((LINE_WORDS - fetch_w) > BURST_LEN) ?
  // BURST_LEN : (LINE_WORDS - fetch_w)` would never take its second arm and its 9-bit
  // subtract/compare/mux would be dead on the SDRAM request path; the burst is BURST_LEN. (A LINE_WORDS that did
  // not divide evenly would break this - keep the encoding 16 x 10.) Cycle-identical:
  // the request, its burstcount and its beat count are the same at every clk.
  // The packed byte base: {page, scan_line_base} << 3 (MAME's `(...) << 3`,
  // pc9821.cpp:104-113). The page bit is the walk's own (SCROLL bit 14, already the
  // frame-boundary-latched value) XOR the 0xA4 term MAME adds (pc9821.cpp:98,112).
  wire [18:0] line_base_new = {scan_walk_page ^ (page_force_zero ? 1'b0 : scan_page),
                               scan_line_base, 3'b000};
  // THE REQUEST HANDSHAKE IS NEVER CUT. A request, once presented, keeps its valid and its
  // payload until the controller's ready (the sdram_sync_bridge contract: the controller
  // samples the payload on the cycle it takes the request). So a line boundary that lands
  // while a request is presented does not restart under it: it is deferred (restart_pend)
  // until that request is taken and its burst drains, and while a restart is pending no NEW
  // request is presented (req_held keeps only the one already on the port). A restart in the
  // cycle a request was taken would also lose the taken burst's place: its beats would fill
  // the new line from column 0 and fetch_w would add its step to the previous line's count. In the
  // normal frame the line's fetch is done before the next tick (no request is presented),
  // so this changes nothing there; it binds only on an overrun or a raster reprogram.
  wire req_open = fetch_active && (fetch_w < LINE_WORDS) && !req_inflight;
  reg  req_held;              // a request was presented and not taken last cycle
  assign mem_valid      = req_open && (!restart_pend || req_held);
  wire restart_now = (scan_tick || scan_arm || restart_pend) && burst_idle && !mem_valid;

  assign mem_addr       = peg_base + {13'd0, line_base_q} + {21'd0, fetch_w, 2'b00};
  assign mem_write      = 1'b0;
  assign mem_be         = 4'hF;
  assign mem_burstcount = {4'd0, BURST_LEN};
  assign mem_din        = 32'd0;

  always @(posedge clk) begin
    if (reset) begin
      fetch_w       <= 9'd0;
      fetch_active  <= 1'b0;
      line_base_q   <= 19'd0;
      line_base_next <= 19'd0;
      restart_pend  <= 1'b0;
      req_inflight  <= 1'b0;
      beats_left    <= 4'd0;
      wr_idx        <= 9'd0;
      wr_sel        <= 1'b0;
      line_sel_r    <= 1'b0;
      line_ready_r  <= 1'b0;
      scan_tick_d   <= 1'b0;
      scan_enable_d <= 1'b0;
      req_held      <= 1'b0;
    end else begin
      req_held      <= mem_valid && !mem_ready;
      scan_tick_d   <= scan_line_tick;
      scan_enable_d <= scan_enable;

      if (!scan_enable) line_ready_r <= 1'b0;

      // The line boundary owns the buffer swap and the column reset (the
      // gvram_scan rule): swap only when the fill completed, hold otherwise.
      if (restart_now) begin
        if (prev_done) begin
          line_sel_r <= ~line_sel_r;
          wr_sel     <= line_sel_r;
        end
        line_base_q  <= restart_pend && !(scan_tick || scan_arm) ? line_base_next
                                                                : line_base_new;
        fetch_w      <= 9'd0;
        wr_idx       <= 9'd0;
        fetch_active <= scan_enable;
        restart_pend <= 1'b0;
      end else if (scan_tick || scan_arm) begin
        // the outstanding burst has not drained: defer, keep its beats accounted
        restart_pend   <= 1'b1;
        line_base_next <= line_base_new;
      end

      if (mem_valid && mem_ready) begin
        fetch_w      <= fetch_w + {5'd0, BURST_LEN};
        req_inflight <= 1'b1;
        beats_left   <= BURST_LEN;
      end
      if (mem_resp_valid && (beats_left != 4'd0)) begin
        // A response beat always belongs to the line being filled: the restart
        // waits for burst_idle, so no beat of the old line can outlive it.
        lbuf[{wr_sel, wr_idx[7:0]}] <= mem_dout;
        wr_idx <= wr_idx + 9'd1;
        if ((beats_left == 4'd1) && (wr_idx == LINE_WORDS - 9'd1)) begin
          fetch_active <= 1'b0;
          line_ready_r <= 1'b1;
        end
        if (beats_left == 4'd1) req_inflight <= 1'b0;
        beats_left <= beats_left - 4'd1;
      end
    end
  end

  // ---- the buffer's read port: its own always block, no reset (see the header) ----
  // The dot the NEXT pixel enable will select: the current dot, plus one when this cycle
  // ends on an enable. (An 8-dot column is 2 x 4-dot groups, so a group opens exactly when
  // the current dot's low two bits are 3: at dot 3 -> 4 (the group's second dword) and at
  // dot 7 -> the next column's dot 0.)
  wire        grp_adv = dot_ce && (dot_in_col[1:0] == 2'd3);
  wire        dot2_rd = grp_adv ? ~dot_in_col[2] : dot_in_col[2];
  wire        col_adv = grp_adv && (dot_in_col == 3'd7) && line_rd_act;
  wire [6:0]  col_rd  = line_rd_addr + (col_adv ? 7'd1 : 7'd0);
  wire [8:0]  rd_addr = {line_rd_sel, col_rd, dot2_rd};
  reg [31:0] rd_d;
  always @(posedge clk) begin
    rd_d <= lbuf[rd_addr];
  end
  assign packed_idx = rd_d[dot_in_col[1:0]*8 +: 8];
  assign line_sel   = line_sel_r;
  assign line_ready = line_ready_r;

endmodule

`default_nettype wire

// The CPU byte-window responder for the two 0xA0000-range windows: text RAM
// (0xA0000-0xA3FFF, a 16 KiB byte-wide dual-port RAM the GDC also scans) and the
// memory-mapped CG byte window (0xA4000-0xA4FFF, a 32-byte repeating view of the glyph
// the CG registers select).
//
// ONE SEQUENCER, TWO ROUTES. The two windows need the SAME byte-walk machine:
// S_IDLE/S_READ_ISSUE/S_READ_WAIT/S_READ_CAPTURE/S_WRITE/S_WRITE_COMMIT/S_RESP/S_HOLD
// (plus S_DMA_WAIT/S_DMA_CAPTURE, the text RAM's DMA read, and S_DMA_CG_ISSUE/WAIT/CAPTURE, the
// CG window's, thirteen states in all), the same
// base_addr/write_data/write_be/byte_index/read_data[31:0]/line_request register set, the same
// walk bound (`last_byte`: byte 15 on a cache-line read, byte 3 on a DWORD), and the
// same accept-then-respond split (the responder contract in pc9821_memory_subsystem.sv:
// assert ready, then resp_valid a cycle LATER, or z486's direct path never clears its
// in-flight flag). They differ only in the backend (a 14-bit TRAM byte port vs the GDC's
// 5-bit byte position) and in the TRAM attribute half's read gate.
//
// A CACHE-LINE READ IS FOUR WORD BEATS, NOT A 128-BIT REGISTER: the word the L1
// consumes is complete every four bytes of the walk, so the responder accepts the line read
// at the walk's start (the CPU is stalled on the fill's beat counter) and pulses
// cpu_line_word_valid as each word lands, holding only the 32-bit word it is building. The
// four beats therefore stream THROUGH the walk instead of following it, and the fill
// completes four clk_sys earlier than an assemble-then-split form would. The L1 gathers beat N
// into line word N (src/z486/l1_icache.sv's patch_line_word(..., fill_count, ...)), so word N
// IS the dword at base + 4N: the byte order is the walk's own.
//
// WHY SHARING THEM IS LEGAL, AND IT IS A PLATFORM ARGUMENT RATHER THAN A FIDELITY ONE.
// Both NP2kai (mem/memtram.c) and qemu-pc98 (hw/display/pc98-vga.c) treat the two windows
// as independent paths, so nothing in the references says they share hardware. What makes
// the share safe is that THIS MACHINE'S routing never has them in flight together: the
// memory map's route selects are one-hot (`route_cg` is the CG window's select, and
// pc9821_memory_subsystem's route-overlap check fatal-errors on tram_select && cg_win_select),
// each route's cpu_valid is its own select, and the z486 memory bus carries one request at a
// time. This is the argument that landed pc9821_block_share's one adapter for the disk and the
// floppy (T9) and one engine for the two floppy drives (T17b), with the easier corollary that
// NOTHING here is per-device state that must survive a request: base_addr, write_data,
// byte_index and the 32-bit word under construction (read_data) are all just the request in
// flight. If either window
// ever needs state of its own, this module is the wrong shape and the two must split.
// Priced module-alone, one shared sequencer is -123 ALMs / -110 ALUTs / -217 registers
// against two copies.
//
// WHAT EACH ROUTE'S BEHAVIOUR COMES FROM:
//   * The TRAM attribute half (0xA2000-0xA3FFF) is EVEN-ONLY: NP2kai memtram_wr8/wr16 gate on
//     `!(address & 1)` (mem/memtram.c:82-99, 130-161), and the machine's own poke/read agrees --
//     the VRAM probe (docs/probes/VRAM.TXT, row `A2000`) wrote
//     `00 FF 55 AA` and read back `00 FF 55 FF`. So an odd attribute byte takes no store AND
//     reads back 0xFF. The machine's read-back outranks NP2kai here, whose memtram_rd8
//     (mem/memtram.c:13-17) models only the store half.
//   * The CG window's byte position is {page = offset[0], row = offset[4:1]}, so the view
//     repeats every 32 bytes (qemu cgwindow_set_addr/readb/writeb; NP2kai memtram.c:23-29).
//     The machine corroborates the page bit: docs/probes/VRAM.TXT reads A4000..A400F as
//     8F 00 8F 00 ... -- a different PAGE at bit 0, not a neighbouring byte.
//   * `byte_sel` stays COMBINATIONAL, exactly as pc9821_cg_window had it: the position is a
//     function of the request's own base and byte index, so registering it would only widen the
//     port's waveform in cycles where the consumer does not act on it (pc9821_cg uses
//     cg_win_byte_sel only behind cg_rd_win/cg_wr_win). It also removes one level from the
//     cpu_dout/cpu_line_word route mux in pc9821_memory_subsystem.

`default_nettype none

module pc9821_window_responder #(
    parameter integer SYS_CLOCK_HZ = 50_000_000
) (
    input wire clk,
    input wire reset,
    // OSD I/O timing = Xe10 (status[79], pc9821_gvram_arb's timing_xe10) and the graphics GDC's
    // scan window (pc9821_gvram_arb's gfx_scan_on): the text RAM's CPU access period below. Both
    // are levels, registered here; Fast (0) keeps the walk's own pace exactly as before.
    input wire timing_xe10,
    input wire gfx_scan_on,
    // The Xe10 table's display-mode column (pc9821_memory_subsystem's xe10_mode: 0 = 24 kHz,
    // 1 = 31 kHz, 2 = 31 kHz with the 256-colour display on, 3 = 24 kHz with it on), registered
    // here; Xe10 only.
    input wire [1:0] xe10_mode,

    // 0 = the TRAM route (0xA0000-0xA3FFF), 1 = the CG byte-window route (0xA4000-0xA4FFF).
    // In the design this is the memory map's one-hot route select, held for the life of the
    // request (see the exclusivity note above).
    input  wire        route_cg,

    // CPU-side memory request (already decoded to one of the two windows).
    /* verilator lint_off UNUSEDSIGNAL */   // the D1 port is 4-byte aligned, so cpu_addr[1:0] are don't-care
    input  wire [13:0] cpu_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [31:0] cpu_din,
    input  wire [3:0]  cpu_be,
    input  wire        cpu_line_read,
    input  wire        cpu_valid,
    input  wire        cpu_write,
    output wire [31:0] cpu_dout,
    // The line read's current word (the dword at base + 4*word), valid on cpu_line_word_valid.
    output wire [31:0] cpu_line_word,
    output reg         cpu_ready,
    output reg         cpu_resp_valid,
    output reg         cpu_line_word_valid,

    // TRAM backend: the byte-wide port the GDC's dual-port RAM owns.
    // THE uPD71071's BUS-MASTER BYTE INTO THE TEXT RAM (0xA0000-0xA3FFF). The DMA is a bus
    // master on the CPU's own memory map: NP2kai stores a port-to-memory byte with
    // MEMP_WRITE8 (mem/dmax86.c `MEMP_WRITE8(ch->adrs.d, ch->proc.inproc());`), and
    // memp_write8 sends an address at or above CPU_MEMWRITEMAX (0xA0000, i386c/cpumem.h)
    // through the CPU's handler table, whose 0xA0000 slot is memtram_wr8 (mem/memtram.c):
    // the character half takes every byte, the attribute half only its even bytes. MAME's
    // pc9801.cpp dma_write_byte writes through the program space the same way. A floppy IPL
    // that reads a sector to A000:1000 and jumps there then executes that sector. One byte per
    // request (dma_addr is its byte address, dma_din the byte); dma_ready is the accept and,
    // for a read, dma_resp_valid comes two cycles later with the byte in dma_dout. It is served
    // from S_IDLE, so it never interleaves with a CPU walk, and it goes first when both wait
    // (a CPU request holds its valid until its ready).
    // THE SAME BYTE INTO THE CG WINDOW (0xA4000-0xA4FFF): with dma_route_cg set (the
    // subsystem's registered DMA class, held for the request's life) the byte takes the CG
    // byte port at the position a CPU byte at that address takes ({offset[0], offset[4:1]}),
    // because the machine sends it there: docs/probes/DMAROUTE-XE10.TXT case G1 (DMA = CPU,
    // both views D - the window's odd bytes A4001+2i and port 0xA9 lines 0-15 hold the
    // transferred bytes after a DMA run exactly as after a CPU run). NP2kai's handler slot for
    // 0xA4000 is memtram_wr8 (mem/memtram.c), the CPU's own. A store pulses byte_we in the cycle
    // after the accept; a read pulses byte_rd, waits out byte_hold as a CPU read does, and answers
    // with the port's byte.
    input  wire        dma_route_cg,
    input  wire        dma_valid,
    input  wire        dma_write,
    input  wire [13:0] dma_addr,
    input  wire  [7:0] dma_din,
    output reg         dma_ready,
    output reg         dma_resp_valid,
    output reg   [7:0] dma_dout,

    output reg  [13:0] tram_addr,
    output reg   [7:0] tram_din,
    output reg         tram_we,
    input  wire  [7:0] tram_dout,

    // CG-window byte port. byte_sel is COMBINATIONAL (see the header): it is the byte
    // POSITION -- {page, row} of the 32-byte repeating view -- and the GDC's class table owns
    // which store and address that position names, because that table also serves port 0xA9
    // and one definition of it is what keeps the two views agreeing.
    output wire  [4:0] byte_sel,
    output reg         byte_rd,    // read strobe: the answer is one cycle later
    input  wire  [7:0] byte_dout,
    // The byte is not valid while this is set: the GDC holds it high while the code's SDRAM
    // glyph burst is in flight, so a JIS read waits for ITS code rather than returning the
    // previous one. Every other class answers immediately, and an undriven input is 0 (no hold).
    input  wire        byte_hold,
    output reg   [7:0] byte_din,
    output reg         byte_we
);
  import pc9821_xe10_timing_pkg::*;

  localparam S_IDLE = 4'd0, S_READ_ISSUE = 4'd1, S_READ_WAIT = 4'd2,
             S_READ_CAPTURE = 4'd3, S_WRITE = 4'd4,
             S_WRITE_COMMIT = 4'd5, S_HOLD = 4'd6, S_RESP = 4'd7,
             S_DMA_WAIT = 4'd8, S_DMA_CAPTURE = 4'd9,
             S_DMA_CG_ISSUE = 4'd10, S_DMA_CG_WAIT = 4'd11, S_DMA_CG_CAPTURE = 4'd12,
             S_LATW = 4'd13;   // Xe10: a word read's data is in, its response waits out the hold

  reg [3:0] state;
  reg [13:2] base_addr;   // the transfer's dword-aligned base (its low two bits are always 0)
  reg [31:0] write_data;
  reg [3:0]  write_be;
  // The transfer is 16 bytes on a line read and 4 otherwise (line_request), so byte_index is
  // 0..15 and the last byte is a compare against that bound, not against a stored count.
  reg [3:0]  byte_index;
  // The CURRENT WORD: bytes 0..3 of a DWORD read, and bytes 4N..4N+3 of a line read while word N
  // is being gathered. One register serves both - a dword read's response IS the line read's
  // beat word - so a line read needs no second accumulator (and no 128-bit one).
  reg [31:0] read_data;
  assign cpu_line_word = read_data;
  // A word read assembles bytes 0..3 of read_data (byte_index 0..3), its last byte on the edge
  // that raises cpu_ready, so the word the CPU gets IS read_data by the response cycle and a
  // separate 32-bit cpu_dout register would be a duplicate. It is only consumed behind
  // cpu_resp_valid (pc9821_memory_subsystem's response mux); after a line read it holds that
  // line's LAST word, which nothing consumes (the beats are strobed as they complete).
  assign cpu_dout = read_data;
  reg line_request;
  // The ROUTE OF THE ACCESS IN FLIGHT, latched at its start. Every walk state reads it, never the
  // live `route_cg`: in Xe10 a text store is POSTED (its ready is its accept), so the CPU's NEXT
  // request - possibly to the CG window - is presented while this walk still runs, and the live
  // select then names that request, not this one. In Fast the CPU holds its request until the
  // walk's ready, so the latch equals the live select for the whole walk.
  reg route_cg_q;
  wire walk_cg = route_cg_q;
  // This store's ready was its accept (Xe10 on the text route): the walk's end must not pulse it
  // again, or z486 would take that second ready for its next request's accept.
  reg posted_q;

  // base_addr is lane-aligned on the transfer's base and byte_index walks lanes from it, so
  // this is the byte the backend is asked for. For the CG route cpu_addr[13:12] are zero
  // (the window is 0xA4000-0xA4FFF, a 0x4000 offset into the 0xA0000 page), so the 14-bit sum
  // equals pc9821_cg_window's 13-bit off_sum and its {off_sum[0], off_sum[4:1]} position
  // exactly.
  // The sum never carries: a line's base is 16-aligned (byte_index 0..15) and a word's is
  // 4-aligned (byte_index 0..3), so the add is an OR of the disjoint bits.
  wire [13:0] indexed_addr = {base_addr[13:4], base_addr[3:2] | byte_index[3:2], byte_index[1:0]};

  // The attribute half of the text plane (0xA2000-0xA3FFF) is EVEN-ONLY (header's reference
  // note). The code plane (0xA0000-0xA1FFF) is full-width; the memory-switch cell's write gate
  // is the CRTC's, beside the BRAM. base_addr is 16-byte aligned, so neither a DWORD nor a
  // cache line can straddle 0x2000/0x3FFF in a way that would make the plane ambiguous
  // mid-transfer.
  wire attr_half_byte = (indexed_addr >= 14'h2000) && indexed_addr[0];
  // The CG window's byte position: a permutation of the offset's low five bits, not the bits
  // themselves (header's reference note).
  assign byte_sel = {indexed_addr[0], indexed_addr[4:1]};

  // Every enabled lane is offered to the backend. The TRAM route drops an odd attribute byte
  // (it reads back 0xFF regardless); the CG route offers every enabled lane and the GDC
  // discards the reference's dummy page.
  wire current_write_enabled = write_be[byte_index[1:0]] &&
                               (walk_cg ? 1'b1 : !attr_half_byte);
  // The lane a read returns: 0xFF for an odd TRAM attribute byte, the backend's byte otherwise.
  // The lane's own address is available while the answer is captured (byte_index is held across
  // S_READ_ISSUE/S_READ_WAIT/S_READ_CAPTURE), so the test is per byte of the transfer.
  wire [7:0] read_lane = walk_cg ? byte_dout
                                 : (attr_half_byte ? 8'hFF : tram_dout);
  wire last_byte = line_request ? (byte_index == 4'hF) : (byte_index[1:0] == 2'b11);
  // memtram_wr8's attribute rule for the DMA byte: an odd byte at or above 0xA2000 is dropped,
  // and memtram_rd8 answers the CPU's own 0xFF there (the read_lane rule above).
  wire dma_attr_odd = dma_addr[13] && dma_addr[0];
  reg  dma_rd_odd;

  // ---- THE TEXT RAM'S XE10 PRICING (timing_xe10 only; the CG window and the DMA are not paced) ----
  // Every CPU access to the text RAM is priced from the ONE generated class table
  // (pc9821_xe10_timing_pkg, tools/xe10_classes.csv: the rows' captures are cited there and
  // tools/check_xe10_table.py re-derives them). The class is the direction, the WIDTH (one 16-bit
  // word, or two: enables in both halves of the dword, as a dword or a word at dword offset 1; a
  // line read is two words: z486 presents it with all four enables, R8 below), the raster (on a graphics line, gfx_scan_q: the graphics GDC's
  // fetch slows the text RAM as it does the GVRAM, and the off-screen and on-screen rows read the
  // same, XE10X /RDLAT XCR against XCRS/XARS) and the display mode (mode_q: 24 kHz, 31 kHz,
  // 31 kHz with the 256-colour display on, 24 kHz with it on).
  // THE TWO SHAPES (XE10X /RDLAT, docs/probes/XE10X-XE10-RDLAT1.TXT, every class swept with 0..64
  // nops between accesses):
  //   * a READ is LATENCY-shaped: the CPU's work after it ADDS (XCR_24V 646.1 ns at nop 0, 1300.2
  //     at nop 64, :274-280; hidden_frac 0.02-0.09 in every mode), so its RESPONSE is held to the
  //     table's net time after the request, less the core CPU's own cycles around the port
  //     (XE10_MEM_CPU_CYC): the core's unpaced text read costs 232.1-233.6 ns net = 21 clk_sys at
  //     90 MHz (docs/probes/core/XE10X-CORE-h6-85942c3c-s3-FAST-RDLAT1.TXT:72-78, XCR_24O) and this
  //     port answers it in 13 under the same condition, work between reads
  //     (tb_pc9821_xe10_latency's Fast pin `.F_RD64(13)`; the back-to-back 14 includes the port's
  //     own turnaround edge), so 21 - 13 = 8 are the CPU's - the GVRAM's 8 too
  //     (pc9821_gvram_arb's XE10 TABLE). The rate-shaped period this replaces hid the work instead
  //     (docs/probes/core/XE10X-CORE-h6-85942c3c-s3-XE10-RDLAT1.TXT:274-280: 651.7 -> 972.0);
  //   * a STORE is RATE-shaped on the machine (hidden_frac 0.81-0.87, XCW/XCWS/XAWS in every mode):
  //     the work between stores hides in the store's period. So in Xe10 a text store is POSTED - its
  //     ready is its accept, the byte walk completes behind the CPU, exactly as the GVRAM's
  //     decoupled store - and the next access starts no sooner than the table's period after it.
  //     The un-posted store this replaces exposed the walk to the CPU (MIXED, hidden_frac 0.22-0.40;
  //     839.2 ns at nop 64 against the machine's 685.1, the RDLAT1 XCW rows). Fast keeps the
  //     un-posted walk exactly.
  // A word across a dword boundary is two accesses (the MISAL2 `_3` rows are 1.93-1.95 x the `_0`
  // ones), priced one class each.
  // The two-word store is BIMODAL like the GVRAM's plain one (pc9821_gvram_arb.sv): XCW_1_V reads
  // 198.7 (docs/probes/XE10W-XE10-MIS2RUN1.TXT:386 `pit=249/250/257`) where XAW_1_V reads 282.9;
  // the period is the upper mode.
  localparam integer XE10_MEM_CPU_CYC = 8;   // the CPU's share of a read (see above)
  // The port's own cycles around the read's hold, from the first rising edge that samples the
  // request to the one that samples the response strobe: the hold is armed at the start (the
  // S_IDLE accept, that same edge), the ready follows the edge it runs out (S_LATW), the response
  // strobe one after that (S_RESP). A hold of N intervals answers N + 2 after the request;
  // tb_pc9821_xe10_latency pins that to the table's time less the CPU's share. A read presented in
  // the cycle the previous strobe is seen waits one more edge (S_HOLD), the port's own turnaround,
  // as the Fast read shows (14 clk_sys back to back, 13 with work between).
  localparam integer XE10_RD_PORT_TX = 2;
  // The widest load is the table's widest text entry (the generator's max over the rows), each
  // entry converted here by the table's rule (pc9821_xe10_timing_pkg): the nearest clk_sys.
  localparam [63:0]  TX_MAX  = (64'(SYS_CLOCK_HZ) * 64'(XE10_TX_MAX_NS_X10) + 64'd5_000_000_000) /
                               64'd10_000_000_000;
  localparam integer TX_BITS = ($clog2(TX_MAX + 1) < 1) ? 1 : $clog2(TX_MAX + 1);
  reg  timing_xe10_q, gfx_scan_q;
  reg  [1:0] mode_q;
  reg  [TX_BITS-1:0] tx_left;          // idle intervals before the next CPU text access may start
  wire tx_busy = (tx_left != {TX_BITS{1'b0}});
  // THE CURRENT ROW per class (0 read 1w, 1 read 2w, 2 store 1w, 3 store 2w), registered from the
  // quasi-static mode and raster levels: the load the start cycle writes into tx_left. A store's
  // is its period less one (start to start is then the period, or the walk if longer); a read's
  // the table time less the CPU's share and the port's cycles, floored at 0.
  wire [2:0] tx_sel = {mode_q, 1'b0} + {2'b00, gfx_scan_q};   // 2 * mode + phase
  wire [4*TX_BITS-1:0] tx_ld;
  genvar tc;
  generate
    for (tc = 0; tc < 4; tc = tc + 1) begin : g_tx_row
      localparam integer BASE = XE10_TX_RD_1W + XE10_PER_CLASS * tc;
      localparam integer SUBI = (tc < 2) ? (XE10_MEM_CPU_CYC + XE10_RD_PORT_TX) : 1;
      localparam [63:0]  SUB  = 64'(SUBI);
      wire [XE10_PER_CLASS*16-1:0] e;
      genvar te;
      for (te = 0; te < XE10_PER_CLASS; te = te + 1) begin : g_e
        localparam [63:0] C = (64'(SYS_CLOCK_HZ) * {48'd0, XE10_NS_X10[16 * (BASE + te) +: 16]} + 64'd5_000_000_000) / 64'd10_000_000_000;
        assign e[16 * te +: 16] = 16'((C > SUB) ? (C - SUB) : 64'd0);
      end
      reg [TX_BITS-1:0] ld;
      always @(posedge clk) ld <= TX_BITS'(e[16 * tx_sel +: 16]);
      assign tx_ld[TX_BITS * tc +: TX_BITS] = ld;
    end
  endgenerate
  // No line-read term: z486's line reads are its cache fills alone, an uncached I-fetch included
  // (src/z486/bus_unit.sv:301 `assign line_read  = ext_valid_r`), each with enables 1111 (src/z486/
  // l1_cache.sv:1105 `mem_be_r <= 4'hF;`, l1_icache.sv:144 `assign mem_be = 4'hF;`): two-word. R8 below.
  wire tx_2w   = (|cpu_be[1:0]) && (|cpu_be[3:2]);
  wire [TX_BITS-1:0] tx_load = tx_ld[TX_BITS * {cpu_write, tx_2w} +: TX_BITS];
  // A CPU request starts in S_IDLE only when the period has run out (Xe10 on the text route).
  wire cpu_start_ok = !(timing_xe10_q && !route_cg && tx_busy);
  // Xe10 on the text route: the access being started is priced (and, a store, posted).
  wire tx_priced    = timing_xe10_q && !route_cg;
  // The read in flight waits for its hold (the walk's own route, latched at its start).
  wire rd_hold      = timing_xe10_q && !walk_cg && tx_busy;

  always @(posedge clk) begin
    if (reset) begin
      timing_xe10_q <= 1'b0;
      gfx_scan_q    <= 1'b0;
      mode_q        <= 2'd0;
      tx_left       <= {TX_BITS{1'b0}};
    end else begin
      timing_xe10_q <= timing_xe10;
      gfx_scan_q    <= gfx_scan_on;
      mode_q        <= xe10_mode;
      // The start cycle loads the class's hold; it counts down every cycle, DMA bytes included.
      if (state == S_IDLE && !dma_valid && cpu_valid && cpu_start_ok && tx_priced)
        tx_left <= tx_load;
      else if (tx_busy)
        tx_left <= tx_left - 1'b1;
    end
  end

  always @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;
      base_addr <= 12'd0;
      write_data <= 32'd0;
      write_be <= 4'd0;
      byte_index <= 4'd0;
      read_data <= 32'd0;
      line_request <= 1'b0;
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
      cpu_line_word_valid <= 1'b0;
      dma_ready <= 1'b0;
      dma_resp_valid <= 1'b0;
      dma_dout <= 8'd0;
      dma_rd_odd <= 1'b0;
      tram_addr <= 14'd0;
      tram_din <= 8'd0;
      tram_we <= 1'b0;
      byte_rd <= 1'b0;
      byte_din <= 8'd0;
      byte_we <= 1'b0;
      route_cg_q <= 1'b0;
      posted_q <= 1'b0;
    end else begin
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
      cpu_line_word_valid <= 1'b0;
      dma_ready <= 1'b0;
      dma_resp_valid <= 1'b0;
      tram_we <= 1'b0;
      byte_rd <= 1'b0;
      byte_we <= 1'b0;

      case (state)
        S_IDLE: if (dma_valid && dma_route_cg) begin
          // One DMA byte into the CG window: its position is the CPU walk's own byte_sel of
          // {base_addr, byte_index} = dma_addr (byte_index[3:2] zero, so indexed_addr is the
          // address itself). A store's strobe is registered with that position; a read issues next.
          base_addr  <= dma_addr[13:2];
          byte_index <= {2'b00, dma_addr[1:0]};
          byte_din   <= dma_din;
          byte_we    <= dma_write;
          dma_ready  <= 1'b1;
          state <= dma_write ? S_HOLD : S_DMA_CG_ISSUE;
        end else if (dma_valid) begin
          // One DMA byte: the write commits this cycle and the accept follows (S_HOLD lets the
          // engine drop its request before IDLE looks again); a read issues its address,
          // accepts, and answers from the RAM's registered port.
          tram_addr <= dma_addr;
          tram_din  <= dma_din;
          tram_we   <= dma_write && !dma_attr_odd;
          dma_ready <= 1'b1;
          dma_rd_odd <= dma_attr_odd;
          state <= dma_write ? S_HOLD : S_DMA_WAIT;
        end else if (cpu_valid && cpu_start_ok) begin
          base_addr <= cpu_line_read ? {cpu_addr[13:4], 2'b00}
                                     : cpu_addr[13:2];
          write_data <= cpu_din;
          write_be <= cpu_be;
          byte_index <= 4'd0;
          // read_data is NOT cleared here: a read writes every byte it answers with (a word
          // read bytes 0..3, a line read every word it beats out) before that response, and a
          // write does not touch it. Every beat is strobed on the edge after its fourth byte
          // lands, so the beat word is complete and stable when cpu_line_word_valid is high.
          line_request <= cpu_line_read;
          route_cg_q <= route_cg;
          // XE10: a text store is POSTED - ready now (the next cycle), the walk behind the CPU.
          posted_q <= cpu_write && tx_priced;
          if (cpu_write && tx_priced) cpu_ready <= 1'b1;
          // A LINE READ IS ACCEPTED AT THE WALK'S START: the CPU's fill is a four-beat
          // counter loaded at the accept, and the beats stream through the walk below, so the
          // request is ready one cycle after it is presented instead of after the last byte.
          // A word read keeps the accept at its last byte (see S_READ_CAPTURE).
          if (cpu_line_read) cpu_ready <= 1'b1;
          state <= cpu_write ? S_WRITE : S_READ_ISSUE;
        end

        S_READ_ISSUE: begin
          if (walk_cg) byte_rd <= 1'b1;
          else          tram_addr <= indexed_addr;
          state <= S_READ_WAIT;
        end

        // The TRAM answers in one cycle (tram_dout changes after the edge which samples
        // tram_addr). A JIS glyph burst holds the CG byte: the class table has already held the
        // position and the GDC's own registered read answers in the same two-cycle cadence the
        // strobe set up, unless byte_hold says its code is still in flight.
        S_READ_WAIT: if (walk_cg ? !byte_hold : 1'b1) state <= S_READ_CAPTURE;

        S_READ_CAPTURE: begin
          read_data[{byte_index[1:0], 3'b000} +: 8] <= read_lane;
          if (line_request && (byte_index[1:0] == 2'd3)) begin
            // word N's fourth byte lands on this edge, so read_data holds the whole word in the
            // next cycle - the cycle this strobe is high. Back-to-back strobes are impossible
            // (each word is four byte reads), which is what lets one 32-bit register carry every
            // beat without a queue.
            cpu_line_word_valid <= 1'b1;
          end
          if (last_byte) begin
            // Accept (cpu_ready) and deliver (cpu_resp_valid) in SEPARATE cycles: z486's
            // direct read path registers the accept and clears its in-flight flag on the
            // response, so a same-cycle response wedges the CPU. Matches the open-bus responder.
            // A line read was accepted at the walk's start and has beaten all four words out.
            // XE10: a word read's accept waits out its latency hold in S_LATW (the data is in).
            if (!line_request && rd_hold) state <= S_LATW;
            else begin
              if (!line_request) cpu_ready <= 1'b1;
              state <= S_RESP;
            end
          end else begin
            byte_index <= byte_index + 4'd1;
            state <= S_READ_ISSUE;
          end
        end

        // XE10's read latency: the word is in read_data; the accept (and the response a cycle
        // after it, in S_RESP) waits until the hold its start loaded runs out. `rd_hold` is a
        // LEVEL (the counter's non-zero state under Xe10), so a reset or a flip to Fast releases it.
        S_LATW: if (!rd_hold) begin
          cpu_ready <= 1'b1;
          state <= S_RESP;
        end

        S_RESP: begin
          if (!line_request) cpu_resp_valid <= 1'b1;
          state <= S_HOLD;
        end

        S_WRITE: begin
          if (current_write_enabled) begin
            if (walk_cg) begin
              byte_din <= write_data[{byte_index[1:0], 3'b000} +: 8];
              byte_we  <= 1'b1;
            end else begin
              tram_addr <= indexed_addr;
              tram_din  <= write_data[{byte_index[1:0], 3'b000} +: 8];
              tram_we   <= 1'b1;
            end
            state <= S_WRITE_COMMIT;
          end else if (last_byte) begin
            if (!posted_q) cpu_ready <= 1'b1;
            state <= S_HOLD;
          end else begin
            byte_index <= byte_index + 4'd1;
          end
        end

        // The backend samples the registered strobe/address/data on this edge.
        S_WRITE_COMMIT: begin
          if (last_byte) begin
            if (!posted_q) cpu_ready <= 1'b1;
            state <= S_HOLD;
          end else begin
            byte_index <= byte_index + 4'd1;
            state <= S_WRITE;
          end
        end

        // A DMA read: the address issued in S_IDLE, and the RAM's registered port answers it
        // here, one cycle later.
        S_DMA_WAIT: state <= S_DMA_CAPTURE;

        S_DMA_CAPTURE: begin
          dma_dout <= dma_rd_odd ? 8'hFF : tram_dout;
          dma_resp_valid <= 1'b1;
          state <= S_HOLD;
        end

        // A DMA read of the CG window: the CPU read's three steps (S_READ_ISSUE/WAIT/CAPTURE),
        // the byte_hold wait included.
        S_DMA_CG_ISSUE: begin
          byte_rd <= 1'b1;
          state <= S_DMA_CG_WAIT;
        end
        S_DMA_CG_WAIT: if (!byte_hold) state <= S_DMA_CG_CAPTURE;
        S_DMA_CG_CAPTURE: begin
          dma_dout <= byte_dout;
          dma_resp_valid <= 1'b1;
          state <= S_HOLD;
        end

        // One cycle only: the accept (a store) or the response (a read) was delivered in the
        // previous cycle. It must NOT wait for cpu_valid to deassert -- a pipelined CPU need
        // not present one request per valid, and two back-to-back accesses to this route with
        // valid held would deadlock here. See pc9821_memory_subsystem.sv's responder contract.
        S_HOLD: state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end

  // synthesis translate_off
  // R8: a line read carries all four byte enables (tx_2w above has no line-read term).
  always @(posedge clk)
    if (!reset && cpu_valid && cpu_line_read && (cpu_be != 4'hF))
      $error("pc9821_window_responder: a line read with byte enables %b (z486 presents 1111)", cpu_be);
  // synthesis translate_on

endmodule

`default_nettype wire

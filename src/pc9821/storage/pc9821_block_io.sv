// MiSTer image/block adapter for pc9821_ata (read and write).
//
// hps_io pulses img_mounted when an image changes and streams block data while sd_ack is
// asserted. This module latches image metadata and converts that level handshake into one
// request / one completion pulse towards the drive.
//
// Direction of the block payload differs by operation:
//   read  : the host writes block data into a buffer, 256 words per sector streamed in on
//           sd_buff_wr / sd_buff_addr / sd_buff_dout, so this module counts and
//           bounds-checks them. One request is answered with ONE sector (its words stream
//           straight through to the drive's sector buffer); behind it the adapter may
//           fetch MORE sectors into the read-ahead window below.
//   write : the host reads one sector out of the drive's buffer, addressing it with
//           sd_buff_addr and sampling sd_buff_din. Writes are always one block
//           (sd_blk_cnt = 0): the drive buffer holds one sector, so a multi-block write
//           would stream N*512 bytes out of a one-sector buffer and corrupt the image.
//
// READ-AHEAD WINDOW. The HPS round trip (sd_rd -> sd_ack -> the word stream -> done) has a
// large fixed per-handshake cost (measured at up to ~4600 clk_sys per 512-byte
// handshake), and one handshake per sector caps a streaming read below the PIO drain rate.
// hps_io's block protocol carries up to 32 blocks (16 KiB) per handshake over sd_blk_cnt,
// so this adapter keeps a BURST_SECTORS-sector window cache: on a read miss that CONTINUES
// a run of sequential read requests (the third contiguous request onward) it fetches up to
// BURST_SECTORS sectors in ONE handshake, serves the requested sector as its slot-0 words
// stream through (the pass-through the single-block path always had) and lands the rest in
// the window. The drive's sector read-ahead then hits the window without a round trip, and
// the per-handshake latency amortises over the whole burst. A read outside a run keeps the
// exact single-block handshake it always had, so no wait ever gets LONGER: random reads
// pay the latency they always paid, and a burst's tail runs in the background behind the
// sector that was already served.
//
// The request contract with pc9821_ata is unchanged: one req_read/req_write pulse in, one
// req_done pulse out with req_error, and a request pulse while a serve is owed is ignored
// ("neither latched nor queued") as it always was. What IS accepted now is a request that
// arrives while only a burst's background tail is still streaming - its sector usually
// lands in the window during that tail and is served from the cache.
//
// THE WINDOW BELONGS TO ONE IMAGE, AND `req_window` SAYS WHICH REQUESTS ARE ITS. There is one
// window and therefore one owner: it cannot be filling itself with image A's blocks and image
// B's at the same time (one RAM holds one set of sectors, and both media start at block 0 and
// read forward, so their LBAs overlap). So a request carries whether it is for the image the
// window's blocks came from, and a request that is not is served as the single block it asks
// for: it neither hits the window, nor fills it, nor replaces its base/total/mask, nor moves
// its run. That is what lets a window SURVIVE a hand-over to another image. Were the shared
// adapter's metadata load (img_mounted) the window flush, an access to the disk's other
// device would throw the disk's read-ahead away and the disk would pay two single-block
// fetches to earn every run again (docs/trade-candidates.md T19; measured in
// tb_pc9821_block_hostcost's interleaved pattern). The tag is a POLICY input and not a rule
// this module derives, because only the caller knows which image its request is for; the
// caller also decides what invalidates the window and drives `win_flush` for that.
//
// The caller's side of that contract, for this core: the window serves the HARD DISK's image.
// pc9821_block_share drives `req_window` for the disk's requests and not for the floppy's, and
// asserts `win_flush` when the disk's slot is mounted or ejected - the only event that
// replaces the image the window's blocks came from. A mount of a floppy slot does not touch
// it. The floppy is served one block per handshake (docs/trade-candidates.md T7/T8: wall clock
// on the floppy is accepted for area, and the FDC delivers the medium at its own rate - a multi-block
// handshake it cannot use is what costs the disk its window).
//
// A window kept across a hand-over is not a stale sector answered: a slot is only COMPLETE once
// its 256th word has arrived, the mask is cleared on every flush, and the tag keeps a request
// for another image from being answered here at all.

`default_nettype none

module pc9821_block_io #(
    // Sectors per multi-block read handshake, 1..8 (the window cache is this many sectors
    // of 256 words). 8 amortises the measured ~4600-clk handshake to ~575 clk/sector while
    // keeping the burst tail (the background part after the served sector) under ~1.8 us
    // at one word per clk_sys.
    parameter BURST_SECTORS = 8,
    // 1: the instantiator never presents a request while this engine is busy (pc9821_block_share
    // holds its arbiter in ARB_HELD until `busy` falls, and a request leaves only ARB_REQ), so a
    // request never finds a background fetch in flight and the S_WAIT deferral - its latched
    // request, second window test and second fetch-start source - is never entered and is not
    // built. A request that breaks the contract is a simulation error. 0 (the default, the
    // engine's standalone benches): the deferral is built.
    parameter SERIAL_REQ = 0
) (
    input wire clk,
    input wire rst_n,

    input  wire        img_mounted,
    input  wire        img_readonly,
    input  wire [63:0] img_size,
    // The image the window's blocks came from has been REPLACED, so every slot it holds must
    // stop answering (a block of the old image at that LBA is not the block the guest asked
    // for). This is separate from `img_mounted` above, which only loads the metadata: a
    // hand-over to another device loads the engine with ITS image and must leave the window
    // alone (this module's header). For a standalone owner, wiring this to `img_mounted`
    // reproduces the mount-flushes-the-window behaviour this module always had.
    input  wire        win_flush,
    output reg         mounted,
    output wire        readonly,
    output reg  [31:0] capacity,

    input  wire        req_read,
    input  wire        req_write,
    input  wire [31:0] req_lba,
    // Is this request for the image the read-ahead window's blocks came from? Held with the
    // request (see this module's header), and latched with it at the accept edge so a deferred
    // fetch carries the width and the window access its own request earned.
    input  wire        req_window,
    output reg         req_done,
    output reg         req_error,

    // Read path: host -> drive sector buffer.
    output wire        buf_we,
    output wire [ 7:0] buf_addr,
    output wire [15:0] buf_data,

    // Write path: drive sector buffer -> host.
    output wire [ 7:0] buf_rd_addr,
    input  wire [15:0] buf_rd_data,

    output reg  [31:0] sd_lba,
    output wire [ 5:0] sd_blk_cnt,
    output reg         sd_rd,
    output reg         sd_wr,
    input  wire        sd_ack,
    input  wire        sd_buff_wr,
    input  wire [12:0] sd_buff_addr,
    input  wire [15:0] sd_buff_dout,
    output wire [15:0] sd_buff_din,

    output wire busy,

    // The cycles the LAST COMPLETED request occupied the adapter, from accepting the
    // request to pulsing its completion - the interval the guest waits behind. For a
    // request served by a host fetch this is the HPS block round trip (sd_rd -> sd_ack ->
    // the word stream -> req_done) that no bench can model and no other instrument in this
    // tree sees; for a window-cache hit it is the short replay. It is held until the next
    // request completes (a live gauge), saturating rather than wrapping, and a request the
    // core rejects before issuing never touches it. Published as the watchdog record's HP
    // field (pc9821_watchdog_msg.sv).
    output reg [31:0] dbg_hps_cycles
);

// The window cache below is EIGHT slots wide in hardware: the slot index is the
// word index's top three bits (`sd_buff_addr[10:8]`, 8 sectors x 256 words = 16 KiB per
// handshake) and both the completion mask and the cache are addressed with it. A wider
// window is not merely unsized here, it is WRONG: at BURST_SECTORS = 16 the word index
// wraps at 2048 and slot k-8 aliases slot k, marking a slot the fetch never wrote as
// COMPLETE -- so a window hit replays ANOTHER sector's data to the guest. That is silent
// read corruption, not a hang, which is why widening the window has to fail loudly here
// (same guard shape as src/memory/sdram.v's frequency check).
  generate
    if (BURST_SECTORS > 8) begin : gen_burst_width_check
      initial
        $error("pc9821_block_io: BURST_SECTORS=%0d > 8 -- the slot decode is three bits (sd_buff_addr[10:8]), so a wider window would alias slot k-8 onto slot k and replay ANOTHER sector's data to the guest",
               BURST_SECTORS);
    end
  endgenerate

  // The serve state: the one request owed a completion.
  localparam [1:0] S_NONE = 2'd0, S_WAIT = 2'd1, S_STREAM = 2'd2, S_REPLAY = 2'd3;
  // The host-fetch engine, independent of the serve state: a burst's tail streams in the
  // background after the served sector's completion. F_REQ waits for the host's
  // acknowledge, F_ACKED for its drop at the end of the transfer - the exact two-phase
  // handshake this module always had.
  localparam [1:0] F_IDLE = 2'd0, F_REQ = 2'd1, F_ACKED = 2'd2;

  reg  [1:0]  serve_st;
  reg  [31:0] req_lba_q;
  reg         req_is_write;
  reg  [5:0]  req_blocks;      // blocks the host will carry for this request's fetch
  reg  [31:0] hps_count;

  reg  [1:0]  fetch_st;
  reg         fetch_write;     // in-flight transfer is a block write
  reg  [4:0]  fetch_total;     // blocks this transfer carries (1 = single sector)
  reg  [12:0] words_received;
  reg         transfer_error;

  // ==== the read-ahead window cache ====
  // BURST_SECTORS sectors of 256 words, slot k holding sd_lba + k of the last fetch.
  // win_mask marks the slots whose 256 words have all arrived; only COMPLETE sectors are
  // ever served, so a truncated or errored transfer can never leak partial data.
  (* ramstyle = "M10K, no_rw_check" *) reg [15:0] cache_ram[0:BURST_SECTORS*256-1];
  reg [31:0] win_base;
  reg [4:0]  win_total;                 // slots the last/current fetch covers
  // The mask is exactly as wide as the window while its INDEX is the HOST's three-bit slot
  // field (sd_buff_addr[10:8], the top of the word index), which is why every access to it
  // below carries a WIDTHTRUNC waiver: the index is wider than the vector, and the bits the
  // vector lacks are the ones a legal access cannot set -- a hit requires win_off < win_total
  // with win_total never above BURST_SECTORS, and a slot is only written when the word address
  // that names it is below fetch_span <= BURST_SECTORS*256. Widening the mask to the host's
  // eight slots instead measures 18 ALMs on pc9821_fdd_media's one-sector window, so the
  // waivers are the cheaper of the two honest forms.
  reg [BURST_SECTORS-1:0] win_mask;
  // The cache's own index has to follow the parameter, because the array does: a one-sector
  // window is 256 words deep and takes the word address ALONE, while a wider one takes the
  // host's (slot, word) pair. WIN_ADDR_BITS is exactly the array's own address width, and both
  // indexes below are selects of that width rather than wider expressions -- at
  // BURST_SECTORS = 1 the discarded bits are the host's slot field, which a legal word address
  // cannot set, because valid_buffer_word requires sd_buff_addr < fetch_span <= 256 there.
  localparam integer WIN_ADDR_BITS = $clog2(BURST_SECTORS * 256);
  // The replay's address is built at the HOST's (slot, word) width and then cut to the cache's
  // own, so at BURST_SECTORS = 1 the cut discards the slot field -- which only slot 0 can ever
  // set, because a hit requires win_off < win_total and win_total never exceeds the parameter.
  // The discarded bits are the PARAMETER's, not a signal nobody reads, so the linter's
  // unused-bits warning is waived here with that reason rather than silenced at the flag.
  /* verilator lint_off UNUSEDSIGNAL */
  wire [10:0] win_rd_idx_full = {rp_slot, rp_addr[7:0]};
  /* verilator lint_on UNUSEDSIGNAL */

  // The stream-detection run over READ requests. A WRITE does not touch it: the run records
  // where a sequential READ stream had reached (`run_next`) and how much confidence it has
  // earned (`run_len`), and a write between two reads says nothing about whether the reads
  // continue - the swap-file pattern (write a 4 KB page, read the next) is exactly that, and
  // before this the page writes reset the run so EVERY page's read paid the two single-block
  // fetches that earn it (tb_pc9821_block_hostcost measures 3 handshakes per 8-sector page
  // read against 1). A read that does not continue the run still resets it below. The run
  // belongs to the WINDOW's image (req_window): a request for another image must not move it.
  reg  [31:0] run_next;                 // the LBA that would continue the read run
  reg  [7:0]  run_len;

  // Whether the request in hand is the window's own (`req_window`, latched at the accept
  // edge), and whether the fetch now in flight is one that fills the window. A fetch that
  // does not leaves every window register where the window's owner left it.
  reg         req_window_q;
  reg         fetch_win;

  wire fetch_active = (fetch_st != F_IDLE);
  wire req_owed     = (serve_st != S_NONE);

  // A burst fetch is started only for a read that continues a run of sequential reads
  // (this being at least the third contiguous request): a lone random read - FAT and
  // directory traffic - keeps the exact single-block handshake it always had, so its wait
  // cannot grow by the burst tail. A request the window is not for never bursts: it is served
  // the one block it asked for, which is what leaves the window's owner's read-ahead intact.
  wire [7:0]  run_len_next  = (req_window && (req_lba == run_next)) ? (run_len + 8'd1) : 8'd1;
  wire [4:0]  burst_want    = (req_window && (run_len_next >= 8'd3)) ? BURST_SECTORS[4:0] : 5'd1;
  // One subtraction serves both the room and the past-the-image test below: req_lba >= capacity
  // exactly when capacity - req_lba borrows or is zero.
  wire [32:0] room33        = {1'b0, capacity} - {1'b0, req_lba};
  wire [31:0] room          = room33[31:0];
  wire        req_past_end  = room33[32] || (room33[31:0] == 32'd0);
  wire [4:0]  burst_blocks  = (room < {27'd0, burst_want}) ? room[4:0] : burst_want;

  // The window hit tests (combinational at the accept edge so a miss issues its fetch in
  // the same cycle the request is accepted, exactly as the single-block path always did).
  // Both are qualified by the request's tag: the window holds ONE image's blocks, and the
  // other image's blocks carry the same LBA numbers, so an unqualified test would serve one
  // medium out of the other's cache.
  wire [31:0] win_off     = req_lba - win_base;
  /* verilator lint_off WIDTHTRUNC */   // the mask is as wide as the WINDOW and the index is
  // the host's three-bit slot field; see the mask's declaration for why the extra index bits
  // cannot be set on an access that reaches the mask at all.
  wire        win_hit_now = req_window && (win_off < {27'd0, win_total}) &&
                            win_mask[win_off[2:0]] && !req_write;
  wire [31:0] win_off_q = req_lba_q - win_base;
  wire        win_hit_q = req_window_q && (win_off_q < {27'd0, win_total}) &&
                          win_mask[win_off_q[2:0]] && !req_is_write;
  /* verilator lint_on WIDTHTRUNC */

  // A write to an unmounted or read-only image, or any request past the image, is rejected
  // before any host transaction starts, so the drive reports a clean abort instead of a
  // half-finished block.
  wire req_reject = !mounted || req_past_end || (req_write && readonly);

  // The transfer's word span: one handshake carries fetch_total sectors of 256 words. The
  // single-block case reduces to this module's original checks word for word.
  wire [12:0] fetch_span = {fetch_total, 8'd00};
  // A word is THIS engine's only while its own slot is acknowledged. hps_io serves one slot at a
  // time over ONE word bus shared by every slot (sd_buff_wr/addr/dout); `sd_ack` is per slot
  // (sys/hps_io.sv:331 "sd_ack <= disk[VD:0]") and is the only thing that says whose words
  // they are. Counting any word while the request merely waited in F_REQ took another slot's
  // transfer as this sector: with the CD-ROM's CD-DA streaming on slot 4, the disk's sectors
  // arrived as CD audio (Policenauts' intro). pc9821_atapi
  // gates its own stream the same way (e_word).
  wire stream_word = fetch_active && sd_ack && !fetch_write && sd_buff_wr;
  wire valid_buffer_word = stream_word && (sd_buff_addr < fetch_span);
  wire current_buffer_error = stream_word &&
      ((sd_buff_addr >= fetch_span) || (words_received == fetch_span));
  wire all_words_received = (words_received == fetch_span) ||
                            (valid_buffer_word && words_received == (fetch_span - 13'd1));

  // The window replay engine (one process with the fetch/serve FSM below, so its
  // registers have a single driver): one synchronous cache read per cycle, pipelined so
  // the (address, data) pair presented to the drive's fill port stays aligned: word i is
  // read one cycle and emitted beside its own index the next.
  reg        rp_run;
  reg  [2:0] rp_slot;
  reg  [8:0] rp_addr;           // word being fetched out of the cache
  reg        replay_out_valid;
  reg  [7:0] replay_out_addr;
  reg [15:0] cache_q;

  // When the replay's last word has landed at the drive's fill port.
  wire replay_last = replay_out_valid && (replay_out_addr == 8'd255);
  // When the served sector (the transfer's slot 0) has received its 256th word.
  wire slot0_done = valid_buffer_word && (words_received == 13'd255);
  // The completion edge this module always had: the host drops sd_ack at the end of the
  // transfer, and the single-block and write requests complete right there. A multi-block
  // transfer completes its REQUEST earlier (slot 0, below); this edge then only retires
  // the fetch engine.
  wire fetch_ack_done = fetch_active && (fetch_st == F_ACKED) && !sd_ack;

  wire eject = img_mounted && (img_size < 64'd512);
  // A replacement of the image under a write the host has not acknowledged (the F_REQ arm).
  // pc9821_block_share only forwards a mount to the engine for the slot it is serving, and its
  // own metadata load (ARB_META) happens while the engine is idle, so in F_REQ this is a mount
  // of the very image the write is for.
  wire wr_withdraw = img_mounted && !eject && fetch_write && (fetch_st == F_REQ);

  // The serve pass-through: the requested sector is the transfer's slot 0 and its words go
  // straight to the drive's fill port as they arrive. A burst's tail (slot 1..) must NOT
  // reach buf_we - the drive may be draining with its prefetch owed, and stray words would
  // overwrite its fill buffer - so tail words only fill the window cache.
  wire serve_stream = (serve_st == S_STREAM) && !fetch_write;
  assign buf_we   = serve_stream ? stream_word : ((serve_st == S_REPLAY) && replay_out_valid);
  assign buf_addr = (serve_st == S_REPLAY) ? replay_out_addr : sd_buff_addr[7:0];
  assign buf_data = (serve_st == S_REPLAY) ? cache_q : sd_buff_dout;

  // Write direction: present the drive's buffer at whatever address the host asks for.
  // The drive muxes its read port to this address while it waits for a block write.
  assign buf_rd_addr = sd_buff_addr[7:0];
  assign sd_buff_din = buf_rd_data;

  // The host's transfer width (blocks-1) for the presented handshake, sampled by the ARM
  // from the hps_io status word at request pickup: multi-block for burst reads,
  // single-block for everything else.
  reg [5:0] sd_blk_cnt_r;
  assign sd_blk_cnt = sd_blk_cnt_r;

  assign busy = req_owed || fetch_active;
`ifdef VERILATOR
  always @(posedge clk)
    if (SERIAL_REQ && rst_n && (req_read || req_write) && busy)
      $error("pc9821_block_io: SERIAL_REQ engine got a request while busy (serve %0d, fetch %0d)",
             serve_st, fetch_st);
`endif

  // Mount state deliberately survives rst_n. The single-cycle img_mounted
  // pulse arrives before the guest ROM pack has finished loading, and the
  // host keeps the image mounted across OSD resets without ever re-sending
  // it, so clearing the state on reset would strand the guest with no disk.
  // The initial value matches the FPGA power-up state; only an eject
  // (img_mounted with a sub-sector size) clears it afterwards.
  // readonly's power-up 1 sits on an internal register: Quartus ignores a power-up value on an
  // output port (docs/policies.md, the power-up rule).
  /* verilator lint_off PROCASSINIT */  // the power-up value, kept by Quartus on an internal register
  reg readonly_r = 1'b1;
  /* verilator lint_on PROCASSINIT */
  assign readonly = readonly_r;
  initial begin
    mounted  = 1'b0;
    capacity = 32'd0;
  end

  always @(posedge clk) begin
    if (img_mounted) begin
      mounted  <= (img_size >= 64'd512);
      readonly_r <= img_readonly;
      capacity <= (|img_size[63:41]) ? 32'hFFFFFFFF : img_size[40:9];
    end
  end

  // Present a read handshake carrying `blocks` sectors from `lba` and bind the request's
  // serve to its slot-0 stream. `use_win` is whether this fetch is the window's own: a fetch
  // that is not streams its one block straight through and leaves the window - its base,
  // total, mask and cached words - exactly as the window's owner left them.
  task automatic start_read_fetch(input [31:0] lba, input [5:0] blocks, input use_win);
    begin
      fetch_st       <= F_REQ;
      fetch_write    <= 1'b0;
      fetch_total    <= blocks[4:0];
      fetch_win      <= use_win;
      sd_lba         <= lba;
      sd_rd          <= 1'b1;
      sd_wr          <= 1'b0;
      sd_blk_cnt_r   <= blocks - 6'd1;
      words_received <= 13'd0;
      transfer_error <= 1'b0;
      if (use_win) begin
        win_base     <= lba;
        win_total    <= blocks[4:0];
        win_mask     <= {BURST_SECTORS{1'b0}};
      end
      serve_st       <= S_STREAM;
    end
  endtask

  task automatic start_write_fetch(input [31:0] lba);
    begin
      fetch_st       <= F_REQ;
      fetch_write    <= 1'b1;
      fetch_total    <= 5'd1;
      fetch_win      <= 1'b0;
      sd_lba         <= lba;
      sd_rd          <= 1'b0;
      sd_wr          <= 1'b1;
      sd_blk_cnt_r   <= 6'd0;
      words_received <= 13'd0;
      transfer_error <= 1'b0;
      // A write drains the drive's buffer; no window is read or filled, and the window the
      // owner filled is DROPPED: the sector being written may be one of its cached blocks.
      win_total      <= 5'd0;
      win_mask       <= {BURST_SECTORS{1'b0}};
      serve_st       <= S_STREAM;
    end
  endtask

  // The single completion pulse per request, whichever edge fires first. All four shapes
  // close the serve exactly once (serve_st goes S_NONE in the same edge).
  task automatic complete(input err);
    begin
      req_done        <= 1'b1;
      req_error       <= err;
      serve_st        <= S_NONE;
      dbg_hps_cycles  <= hps_count;
    end
  endtask

  always @(posedge clk) begin
    if (!rst_n) begin
      serve_st     <= S_NONE;
      req_lba_q    <= 32'd0;
      req_is_write <= 1'b0;
      req_blocks   <= 6'd0;
      req_done     <= 1'b0;
      req_error    <= 1'b0;
      fetch_st     <= F_IDLE;
      fetch_write  <= 1'b0;
      fetch_total  <= 5'd1;
      sd_lba       <= 32'd0;
      sd_rd        <= 1'b0;
      sd_wr        <= 1'b0;
      sd_blk_cnt_r <= 6'd0;
      words_received <= 13'd0;
      transfer_error <= 1'b0;
      win_base     <= 32'd0;
      win_total    <= 5'd0;
      win_mask     <= {BURST_SECTORS{1'b0}};
      run_next     <= 32'd0;
      run_len      <= 8'd0;
      req_window_q <= 1'b0;
      fetch_win    <= 1'b0;
      rp_run           <= 1'b0;
      rp_slot          <= 3'd0;
      rp_addr          <= 9'd0;
      replay_out_valid <= 1'b0;
      replay_out_addr  <= 8'd0;
      cache_q          <= 16'd0;
      hps_count      <= 32'd0;
      dbg_hps_cycles <= 32'd0;
    end else begin
      req_done  <= 1'b0;
      req_error <= 1'b0;

      // The replay pipeline.
      if (eject) begin
        rp_run           <= 1'b0;
        replay_out_valid <= 1'b0;
      end else begin
        cache_q <= cache_ram[win_rd_idx_full[WIN_ADDR_BITS-1:0]];
        if (rp_run) begin
          replay_out_valid <= 1'b1;
          replay_out_addr  <= rp_addr[7:0];
          if (rp_addr == 9'd255) rp_run <= 1'b0;
          else rp_addr <= rp_addr + 9'd1;
        end else replay_out_valid <= 1'b0;
      end

      // The request-to-done gauge: count while a request is owed a completion, latch the
      // total as its completion pulses, hold it until the next one lands. Saturating,
      // because a count that wrapped would read as a fast transfer exactly when it was
      // the slowest. A rejected request never reaches S_WAIT and never touches it.
      if (req_owed)
        hps_count <= (hps_count == 32'hFFFFFFFF) ? hps_count : hps_count + 32'd1;
      else
        hps_count <= 32'd0;

      // The word stream: count and bounds-check exactly as this module always has. A
      // valid word also lands in its window slot, and a slot's last word marks it
      // complete; only complete slots are ever served.
      if (stream_word) begin
        if ((sd_buff_addr >= fetch_span) || (words_received == fetch_span))
          transfer_error <= 1'b1;
        else
          words_received <= words_received + 13'd1;
      end
      if (valid_buffer_word && fetch_win) begin
        cache_ram[sd_buff_addr[WIN_ADDR_BITS-1:0]] <= sd_buff_dout;
        /* verilator lint_off WIDTHTRUNC */   // same reason as the mask's declaration: a
        // valid_buffer_word's slot field is inside the mask by construction.
        if (sd_buff_addr[7:0] == 8'd255)
          win_mask[sd_buff_addr[10:8]] <= 1'b1;
        /* verilator lint_on WIDTHTRUNC */
      end

      if (win_flush) begin
        // The image the window's blocks came from has been REPLACED: every slot it holds must
        // stop answering, because the same LBA now names different bytes. The metadata LOAD
        // (img_mounted) deliberately does not do this: a hand-over loads the engine with the
        // incoming owner's image, and flushing the window there would throw the other image's
        // read-ahead away on every access (T19 - tb_pc9821_block_hostcost's interleaved
        // pattern measured 24 disk handshakes per 32 sectors against 6 with no floppy).
        win_mask  <= {BURST_SECTORS{1'b0}};
        win_total <= 5'd0;
      end

      if (eject) begin
        // Eject: kill any transfer and abort the owed request exactly once. A request a
        // burst's early completion already served is closed (S_NONE) and gets no second
        // pulse; the background tail dies with the window.
        fetch_st       <= F_IDLE;
        sd_rd          <= 1'b0;
        sd_wr          <= 1'b0;
        words_received <= 13'd0;
        transfer_error <= 1'b0;
        rp_run         <= 1'b0;
        if (req_owed) complete(1'b1);
        // A request PRESENTED in this same cycle is ANSWERED, never dropped. This is the one
        // cycle in which the acceptance block below cannot run, so a requester that handed its
        // request over here would otherwise wait for a completion no edge can ever produce: the
        // disk holds BSY in X_WAIT_BLOCK (pc9821_ata.sv:700 (xfer_state <= X_WAIT_BLOCK;)) and
        // never sees its block_done, and the floppy holds `rbusy` so it never asks again
        // (pc9821_fdd_media.sv:1018 "if (bwant && !rbusy && !blk_req_rd) begin") - a silent hang,
        // not the visible abort every other eject alignment produces. The medium the request was
        // for is gone, so the answer is that same error. (A pulse while a serve is owed is still
        // neither latched nor queued: the branch above already owns that completion.)
        else if (req_read || req_write) complete(1'b1);
      end else begin
        // ==== the host-fetch engine ====
        case (fetch_st)
          F_IDLE: begin
            sd_rd <= 1'b0;
            sd_wr <= 1'b0;
          end
          F_REQ: begin
            // the handshake is presented until the host acknowledges it
            if (sd_ack) begin
              sd_rd <= 1'b0;
              sd_wr <= 1'b0;
              fetch_st <= F_ACKED;
            end else if (wr_withdraw) begin
              // A WRITE the host has not acknowledged yet, against an image that has just been
              // REPLACED (a mount that is not an eject): withdrawn and answered with an error.
              // hps_io names the request by slot, so the ARM would serve it into the NEW image -
              // a block of the old disk written over the new one. Before the acknowledge it can
              // still be taken back; after it, the ARM is serving it and no mount can interleave
              // (one ARM thread), so it lands where it was issued. A read needs no withdraw: its
              // owner discards a fetch that straddles its own mount (pc9821_fdd_media's bstale,
              // the disk's platform reset).
              sd_wr    <= 1'b0;
              fetch_st <= F_IDLE;
              if (req_owed) complete(1'b1);
            end
          end
          default: begin
            // F_ACKED: the words stream while sd_ack is high; the request side owns the
            // completion (below). The fetch engine retires at the ack fall.
            if (!sd_ack) begin
              fetch_st <= F_IDLE;
              words_received <= 13'd0;
              transfer_error <= 1'b0;
            end
          end
        endcase

        // ==== request completion: one pulse per request ====
        if (req_owed) begin
          if ((serve_st == S_STREAM) && (fetch_total > 5'd1) && slot0_done)
            // A multi-block fetch completes its request when the SERVED sector (slot 0)
            // has its 256 words; the rest of the burst keeps filling the window in the
            // background. This is the pass-through completion the drive expects right
            // after the sector's last word, latency amortised away from it.
            complete(transfer_error || current_buffer_error);
          else if ((serve_st == S_STREAM) && fetch_ack_done)
            // The original single-block contract: complete at the ack fall with the
            // transfer's validation verdict.
            complete(fetch_write ? 1'b0 :
                     (transfer_error || current_buffer_error || !all_words_received));
          else if ((serve_st == S_REPLAY) && replay_last)
            complete(1'b0);
        end

        // ==== serve start for a request that is owed but waiting ====
        // A request accepted while a burst's background tail streams (its serve already
        // completed) waits here: served from the window the moment its slot completes, or
        // given its own handshake once the engine is free.
        if (!SERIAL_REQ && (serve_st == S_WAIT)) begin
          if (win_hit_q) begin
            serve_st <= S_REPLAY;
            rp_slot  <= win_off_q[2:0];
            rp_addr  <= 9'd0;
            rp_run   <= 1'b1;
          end else if (!fetch_active) begin
            if (req_is_write) start_write_fetch(req_lba_q);
            else start_read_fetch(req_lba_q, req_blocks, req_window_q);
          end
        end

        // ==== request acceptance ====
        // Exactly one serve at a time (the drive's contract): a pulse while a serve is
        // owed is neither latched nor queued, as it always was. A pulse during a burst's
        // background tail is accepted (no serve is owed then).
        if ((req_read || req_write) && (serve_st == S_NONE)) begin
          if (req_reject) begin
            req_done  <= 1'b1;
            req_error <= 1'b1;
          end else begin
            req_lba_q    <= req_lba;
            req_is_write <= req_write;
            req_window_q <= req_window;
            // The READ stream's run is updated by reads alone (see run_next's declaration):
            // a write only breaks its own batching, never the read run's continuity, and a
            // request for another image is not part of this run at all. The burst width is
            // decided here so a deferred fetch carries the width its request earned.
            if (req_write) begin
              req_blocks <= 6'd1;
            end else begin
              // one block unless the window is the request's: burst_want is 1 otherwise
              req_blocks <= {1'd0, burst_blocks};
              if (req_window) begin
                run_len  <= run_len_next;
                run_next <= req_lba + 32'd1;
              end
            end
            // A hit is served from the window immediately; a miss takes the handshake
            // now (the common case, one cycle with the request) or waits for the engine.
            if (win_hit_now) begin
              serve_st <= S_REPLAY;
              rp_slot  <= win_off[2:0];
              rp_addr  <= 9'd0;
              rp_run   <= 1'b1;
            end else if (SERIAL_REQ || !fetch_active) begin
              if (req_write) start_write_fetch(req_lba);
              else start_read_fetch(req_lba, {1'd0, burst_blocks}, req_window);
            end else begin
              serve_st <= S_WAIT;
            end
          end
        end
      end
    end
  end

endmodule

`default_nettype wire

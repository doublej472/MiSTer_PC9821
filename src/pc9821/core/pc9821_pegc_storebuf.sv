// THE PEGC POSTED STORE BUFFER (trade-candidates T21), draining through the G3 GATHER-RMW
// SESSION (src/memory/sdram.v).
//
// The packed/aperture PEGC stores were UN-POSTED: the CPU waited the full
// clock-crossing round trip per store, strictly one at a time (~150-170 ns per byte
// store, ~6 MB/s measured by tb_pc9821_pegc_store_rate on the un-buffered path),
// where the planar route accepts in 1 clk. This buffer posts those stores on the
// mapper's backend route inside pc9821_memory_subsystem:
//
//   1. ACCEPT in 1 clk_sys (merge into a held entry, or allocate), so the CPU
//      never waits the round trip for a PEGC store.
//   2. MERGE any store whose dword a held entry already covers into that entry
//      (later lanes win), wherever the entry sits - not only the tail - so two
//      entries never hold one dword and a drain session cannot write it twice.
//      The one exception is an entry the drain has already COMMITTED (see rule 6):
//      that payload is frozen, so the store allocates a fresh entry instead and
//      drains after it in FIFO order - later lanes still win, nothing is lost.
//   3. DRAIN either as a PAIR (port 0's two-dword write, sdram.v WRITE_BURST /
//      ef_wr_burst: two adjacent FULL entries leave as one burstcount-2 request,
//      the pair's second word on mem_din_hi -> split_sdram_backend's din0_hi), or
//      as a GATHER-RMW SESSION: up to GATHER_K same-row entries leave as ONE
//      request (gath0 + burstcount = the entry count, entries 1.. on
//      mem_gath_extra), which the controller services as one ACT, one half read
//      per half any entry's be touches with some but not all of its bytes, one DQ
//      turnaround, one merged half write per touched half, and one precharge. A
//      full entry writes its halves directly (no read), so mixed groups ride one
//      session. GATHER_K stores that fall in one 2 KiB SDRAM row cost one session
//      of ~2*K+10 instead of GATHER_K full read-modify-write transactions (~16 clk
//      each) (the rate model's G_K shape, K=3-4 = 1.3-1.65x the
//      14.44 MB/s frame need on the stride-640 column shape).
//   4. DRAIN-BEFORE-READ: a request on the same PEGC route that is not itself
//      postable (a read) is held until the buffer is EMPTY, so it cannot read
//      behind buffered bytes. THE SCANOUT IS SUCH A READER: the packed scanout
//      fetches the SAME peg_base region on the SDRAM fourth requester, but it is NOT
//      a request of this buffer and its burst cannot be gated on an empty queue: that
//      starves the scanout under a store stream (measured in
//      tb_pc9821_pegc_store_rate), and its residency is short enough to be below
//      the fetch's own first-beat latency anyway (the same bench's
//      store-to-scanout legs measure 0 stale bytes). Non-PEGC requests (the RAM side
//      of a blit) pass freely: only the peg_window/pegc_packed arms translate into
//      the peg_base region this buffer holds (peg_base = pack_base + PACK_BYTES +
//      0x80000, and every other map arm lands at or below fw_shadow_base = +0x58000
//      or inside the pack itself), so an un-matched request cannot alias a buffered
//      dword. Ordering is by the backend itself: a request accepted after a drain
//      write executes after it (the controller serves accepts in order, one in flight
//      per port), so accept order is visibility order.
//   5. BOUNDED RESIDENCY (the horizontal-stripe class: a write-combining buffer
//      invisible to the scanout shows as horizontal stripes). EVERY entry's age runs
//      from its OWN allocation and never stops or restarts on a merge:
//      a drain session fires at the latest when its oldest entry is HOLD_CYCLES
//      old, so no dirty dword lives past one hold window (the subsystem derives
//      HOLD_CYCLES from SYS_CLOCK_HZ, 1 us) plus one drain session, however hard
//      the store stream pushes. A combining stream therefore cannot freeze the
//      window open again.
//   6. FROZEN PRESENTATION: once a drain goes on the
//      backend its payload is FROZEN - the entries it carries are COMMITTED at its
//      first presentation cycle (the merge in rule 2 refuses them), so no store can
//      merge into a presented dword and vanish when the drain pops it. The pair's
//      second word is exactly that case (mem_din_hi is entry rp2), which is how a
//      posted store was lost. The source and the pair decision freeze with it
//      (pres_* from the first cycle), because the bridge crosses the payload bare
//      and latches it at the controller's accept.
//   7. THE DRAIN BATCHES, and the batch is bounded: a session fires when GATHER_K
//      same-row entries are held, when the next entry is a different row (the
//      group cannot grow), when the oldest entry ages out (rule 5), or when a
//      request is blocked (the buffer filled, or a PEGC read waits). Waiting for
//      the group is what turns the column stream - 3.2 stores per 2 KiB row at
//      stride 640 - into sessions of 3-4 instead of one session per byte.
//
// The CPU-side handshake is the mapper's mem_* arm (valid held until ready); the
// backend side is the map slot of pc9821_memory_subsystem's port-0 mux. Reads are
// NOT touched: a passthrough read's response comes back on the shared mem_dout /
// mem_resp_valid path exactly as before. Requests are held on the backend until
// its one-cycle ready (the controller's accept, through sdram_sync_bridge), and once presented a request's
// payload -- source, pair decision and all -- is frozen until that ack.
`default_nettype none

module pc9821_pegc_storebuf #(
    // Every entry's combining/drain window, in clk_sys cycles. The subsystem
    // derives it from SYS_CLOCK_HZ (1 us), so the residency bound is a time and
    // not a cycle count that moves with the build profile.
    parameter integer HOLD_CYCLES = 50,
    // The gather session's entry count: how many same-row entries one drain
    // request carries (1..4: the head window). Must never exceed the controller's GATHER_K.
    parameter integer GATHER_K = 4
) (
    input  wire        clk,
    input  wire        reset,

    // CPU side: the mapper's backend request (its mem_* arm).
    input  wire        in_valid,
    input  wire        in_write,
    input  wire [31:0] in_addr,
    input  wire [31:0] in_din,
    input  wire  [3:0] in_be,
    input  wire  [7:0] in_burstcount,
    // 1 = this request took the PEGC packed/aperture arm (peg_window ||
    // pegc_packed): postable when it is a one-dword store, and drain-before-read
    // when it is not. Everything else passes through untouched.
    input  wire        in_peg_route,
    output wire        in_ready,
    // The subsystem's response-queue back-pressure (rt_full): a passthrough
    // request is not presented to the backend while it is set.
    input  wire        in_rd_block,
    // The SDRAM geometry (the controller's own sdram_size): the row a gather
    // session must share is {chip, bank, row}, which is addr[26:11] on the 512-
    // column (2 KiB row) geometries and addr[24:10] on the 256-column one. The
    // grouping here is a refinement of that key and sdram.v asserts the contract
    // from the crossed payload.
    /* verilator lint_off UNUSEDSIGNAL */   // bit 0 splits 32/64 MB; the row key needs only [1]
    input  wire  [1:0] sdram_size,
    /* verilator lint_on UNUSEDSIGNAL */

    // Backend side: the map slot of the port-0 request mux. mem_din_hi is the
    // pair's second dword (port 0's two-word write); mem_gath qualifies a gather
    // session, whose entry 0 is mem_addr/mem_din/mem_be and whose entries 1.. are
    // mem_gath_extra[(j-1)*63 +: 63] = {addr[26:0], din[31:0], be[3:0]}.
    output wire [31:0] mem_addr,
    output wire [31:0] mem_din,
    output wire [31:0] mem_din_hi,
    output wire  [3:0] mem_be,
    output wire  [7:0] mem_burstcount,
    output wire        mem_valid,
    output wire        mem_write,
    output wire        mem_gath,
    output wire [440:0] mem_gath_extra,
    input  wire        mem_ready,   // the slot's accept (already owner-qualified)

    // 1 while any accepted store is still buffered (not yet handed to the
    // backend). An accepted drain write is ordered before every later access, so
    // this is exactly "dirty data the backend has not taken".
    output wire        busy
);

  localparam integer DEPTH = 8;      // dwords of store buffer (4-8 per T21)
  localparam integer AGE_W = $clog2(HOLD_CYCLES + 1);   // the age saturates at HOLD_CYCLES
  localparam integer GENT_W = 27 + 32 + 4;   // {addr, din, be} per extra gather entry

  // THE ENTRIES KEEP ONLY THE LOW 17 BITS OF THE DWORD ADDRESS (byte address [18:2]); bits [26:19]
  // are ONE register, `hi_r`, shared by every held entry. A postable store is a store on the PEGC
  // route (peg_window || pegc_packed), and pc9821_memory_map maps both arms to
  // {peg_hi, peg_base[19], offset[18:0]} with peg_base a constant of the build (0x80000-aligned:
  // pack_base + PACK_BYTES + 0x80000), so every postable address lies in the same 512 KiB window
  // and bits [26:19] cannot differ between stores. Holding them once drops 8 bits per entry, the
  // narrower match compares and the narrower pair/row facts (module-alone, tools/res_exp_map.py:
  // 723 -> 659 ALMs, 602 -> 538 registers). The invariant is asserted below (VERILATOR) and
  // proven against the full-width buffer by tools/check_storebuf_head_inv.py at a fixed window.
  reg  [16:0] ent_addr [0:DEPTH-1];  // dword address [18:2] of the byte address (the window offset)
  reg   [7:0] hi_r;                  // byte address [26:19]: the window, the same for every entry
  reg  [31:0] ent_data [0:DEPTH-1];
  reg   [3:0] ent_be   [0:DEPTH-1];
  reg [AGE_W-1:0] ent_age [0:DEPTH-1];  // clk_sys cycles since THIS entry was allocated
  reg   [2:0] wp, rp;
  reg   [3:0] count;
  reg         pres_locked;           // a request is presented, payload frozen
  reg         pres_pass;             // ... and it is the passthrough source
  reg         pres_pair;             // ... and it is a two-dword drain
  reg   [3:0] pres_n;                // ... and it carries this many entries
  reg         hold_force_r;          // a blocked request forces the drain out
  // THE HEAD FACTS, REGISTERED AT THE ALLOCATION (docs/timing.md C5-head). The drain decision read
  // the queue's head through the bank/rotate window and THEN compared it: pair_ok's 25-bit
  // `win_addr[1] == win_addr[0] + 1` and grp_run's per-slot rowkey compares sat behind
  // rp -> bank read -> rotate, in series with grp_complete -> drain_pres -> the merge window ->
  // the entry writes (the rp-headed C5 paths). An entry's address never changes while it is held
  // (a merge writes data and enables only), so each fact about the pair (e, e+1) is decided when
  // e+1 is allocated, against the newest held dword (`last_addr` = ent_addr[wp-1]), and read
  // through rp as one bit. Equal to the window compares whenever both entries are held
  // (tools/check_storebuf_head_inv.py proves it by induction over this module).
  reg  [16:0] last_addr;             // the newest allocation's dword: ent_addr[wp-1] while count > 0
  reg  [DEPTH-1:0] nx_adj;           // entry e+1 holds the dword after entry e's
  reg  [DEPTH-1:0] nx_row_lg;        // ... and the same SDRAM row, 512-column geometry (da[24:9])
  reg  [DEPTH-1:0] nx_row_sm;        // ... and the same SDRAM row, 256-column geometry (da[22:8])


  // ---- the head window: entries rp .. rp+NB-1, read through a banked structure ----
  // Every consumer of the queue's head (the row key, the pair test, the presented payload and
  // the gather extras) reads entries rp+j, j < GATHER_K, so the read is a WINDOW of NB
  // consecutive circular entries. Entry e lives in bank e % NB; a window of NB consecutive
  // entries holds exactly one entry from each bank, so each bank is read ONCE (a position
  // select, 2:1 at NB=4) and window slot j is the rotation of the bank reads by rp % NB.
  // That replaces one 8:1 read mux per (slot, bit) with a shared 2:1 per bank plus a 4:1 rotate
  // per slot, the same entries in the same order.
  localparam integer NB   = 4;
  localparam integer NBL  = 2;
  generate
    if (GATHER_K > NB) begin : gen_k_check
      initial $error("pc9821_pegc_storebuf: GATHER_K=%0d exceeds the %0d-entry head window (the controller's GATHER_K is 4)", GATHER_K, NB);
    end
  endgenerate
  wire [NBL-1:0] rpb = rp[NBL-1:0];
  reg  [16:0] bk_addr [0:NB-1];
  reg  [31:0] bk_data [0:NB-1];
  reg   [3:0] bk_be   [0:NB-1];
  always @* begin : bank_read
    integer b;
    reg bpos;
    for (b = 0; b < NB; b = b + 1) begin
      // the bank's entry inside the window: position rp[2] flips for banks below rp % NB
      bpos = rp[2] ^ (b[NBL-1:0] < rpb);
      bk_addr[b] = bpos ? ent_addr[(b + NB)] : ent_addr[b];
      bk_data[b] = bpos ? ent_data[(b + NB)] : ent_data[b];
      bk_be[b]   = bpos ? ent_be[(b + NB)]   : ent_be[b];
    end
  end
  reg  [16:0] win_addr [0:NB-1];
  reg  [31:0] win_data [0:NB-1];
  reg   [3:0] win_be   [0:NB-1];
  always @* begin : win_rot
    integer j;
    reg [NBL-1:0] bsel;
    for (j = 0; j < NB; j = j + 1) begin
      bsel = rpb + NBL'(j);
      win_addr[j] = bk_addr[bsel];
      win_data[j] = bk_data[bsel];
      win_be[j]   = bk_be[bsel];
    end
  end

  // A postable request is a one-dword PEGC store. (The CPU's stores are
  // burstcount 1; a wider write on this route is not postable and passes.)
  wire postable  = in_peg_route && in_write && (in_burstcount[7:1] == 7'd0);
  // Drain-before-read: a non-postable PEGC request waits for the buffer to empty.
  wire peg_stall = in_peg_route && !postable && (count != 4'd0);

  // ---- the row key: the physical row a gather session may span ----
  // {chip, bank, row} exactly as sdram.v's rc_base computes it, minus the chip
  // term at the 512-column geometries where addr[26:11] already carries it (and
  // is a REFINEMENT at 64 MB, where addr[26] aliases: splitting there is safe).
  /* verilator lint_off UNUSEDSIGNAL */   // da's column/upper bits are not part of the row
  function [15:0] rowkey(input [16:0] da);
    begin
      rowkey = sdram_size[1] ? {8'd0, da[16:9]} : {7'd0, da[16:8]};
    end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- the drain group: the FIFO prefix of up to GATHER_K same-row entries ----
  // Same-row-as-entry-0 along a prefix is same-row-as-the-previous-entry at each step (row
  // equality is transitive), so the run steps on the registered pair facts: slot gi joins when
  // entries rp+gi-1 and rp+gi share the row (nx_row), exactly `rowkey(win_addr[gi]) == rk` for
  // every slot the prefix reaches.
  wire [DEPTH-1:0] nx_row = sdram_size[1] ? nx_row_lg : nx_row_sm;
  reg  [3:0] grp_run;
  always @* begin : grp_sel
    integer gi;
    grp_run = 4'd0;
    for (gi = 0; gi < GATHER_K; gi = gi + 1)
      if ((gi < count) && (grp_run == 4'(gi)) && ((gi == 0) || nx_row[3'(rp + 3'(gi - 1))]))
        grp_run = 4'(gi + 1);
  end

  // The pair drain: two adjacent FULL entries, exactly the shape port 0's
  // two-word write carries (its be applies to both dwords). Adjacency is the registered fact
  // (`win_addr[1] == win_addr[0] + 1` while both are held).
  wire pair_ok = (count >= 4'd2) && (win_be[0] == 4'hF) && (win_be[1] == 4'hF) && nx_adj[rp];

  // ---- the batch window (rule 7): when the group is complete ----
  wire age_out = (ent_age[rp] >= AGE_W'(HOLD_CYCLES));
  wire grp_complete = pair_ok || (grp_run == 4'(GATHER_K)) || (count > grp_run) ||
                      age_out || hold_force_r;
  wire drain_ready = (count != 4'd0) && grp_complete;

  // ---- the frozen presentation (rule 6) ----
  // The presenting drain COMMITS its entries at its first cycle; the merge in
  // rule 2 refuses them until the accept pops them. The commit window is
  // combinational for that first cycle and the lock covers every cycle after it,
  // so the payload cannot move from the cycle mem_valid first rises - which is
  // the cycle the bridge may launch it on.
  wire pass_req   = in_valid && !postable && !peg_stall && !in_rd_block;
  // The response-queue withdrawal (a WITHDRAWAL, not a payload move): when rt_full
  // rises before a presented passthrough read is launched, the request comes off
  // the bus exactly as the pre-buffer map did (mem_valid was `map_valid && !rt_full`),
  // and is re-presented when a response beat frees a queue slot. The window is
  // provably pre-launch: a push (the only way rt_full rises) happens at a read
  // ACCEPT, the bridge holds one request in flight per port and suppresses its
  // launch on the ack cycle, so a request presented while another one's ack is due
  // cannot have been launched before the withdrawal.
  wire pass_withdrawn = pres_locked && pres_pass && in_rd_block;
  wire use_pass   = pres_locked ? pres_pass : pass_req;
  wire drain_pres = pres_locked ? !pres_pass : (!pass_req && drain_ready);
  wire pair_now   = pres_locked ? pres_pair : (pair_ok && !pass_req);
  wire [3:0] n_now = pres_locked ? pres_n
                                 : (pair_ok && !pass_req) ? 4'd2
                                   : (pass_req ? 4'd0 : grp_run);
  // The committed entries: [rp, rp+pres_n) of the circular queue.
  wire [3:0] pres_cnt = drain_pres ? n_now : 4'd0;

  // Rule 2's merge target: the held entry whose dword the store touches. There is
  // at most one (rule 2 merges, never duplicates), and a match inside the commit
  // window is refused - that store allocates instead (see the rule). The match is kept
  // ONE-HOT: each entry writes its own bytes (below), so no binary index and no read-back
  // mux of the matched entry is needed.
  // The match is read ONLY under a post (post_accept, and the commit check), and a post is
  // `postable`, which makes pass_req 0: so its commit window is pres_cnt with pass_req = 0
  // (`post_cnt`), which keeps the CPU request's own valid/route decode (pass_req's inputs) out of
  // the window test. Equal to pres_cnt in every cycle the match is read.
  wire       post_drain = pres_locked ? !pres_pass : drain_ready;
  wire [3:0] post_n     = pres_locked ? pres_n : (pair_ok ? 4'd2 : grp_run);
  wire [3:0] post_cnt   = post_drain ? post_n : 4'd0;
  reg  [DEPTH-1:0] match_hit;
  reg              match_ok;
  always @* begin : post_match
    integer mi;
    reg [2:0] off;
    match_hit = {DEPTH{1'b0}};
    for (mi = 0; mi < DEPTH; mi = mi + 1) begin
      off = 3'(mi) - rp;                       // position in the circular queue
      match_hit[mi] = (ent_addr[mi] == in_addr[18:2]) && ({1'b0, off} >= post_cnt) &&
                      ({1'b0, off} < count);
    end
    match_ok = |match_hit;
  end

  wire can_combine = match_ok;
  wire can_alloc   = (count < 4'(DEPTH));
  assign busy = (count != 4'd0);

  // THE ACCEPT IS THE MUX-LEVEL ONE (mem_valid && mem_ready), the same event
  // pc9821_memory_subsystem pushes its response-route queue on - the buffer's
  // bookkeeping and the queue's must never see different accepts. It cannot be
  // mis-attributed: the bridge's ready is the ack of the ONE request in flight on
  // the port, the presented source is frozen from its first cycle (the lock
  // below), and a new presentation starts the cycle after the previous accept,
  // never inside the one-cycle ack window of another request.
  wire mem_accept   = mem_valid && mem_ready;
  wire drain_accept = mem_accept && !use_pass;
  wire post_accept  = in_valid && postable && can_alloc;

  // C5-A (docs/timing.md): the DEEP combine
  // decision (`can_combine = |match_hit`, the 25-bit equality OR) drives ONLY the final select of
  // count, wp and the pair facts, never an adder or a wide compare. Form the shallow candidates
  // first - the drained count, the un-incremented wp, the new pair facts - and let alloc_now pick
  // at the register D. Value- and cycle-identical to an `if (post_accept && !can_combine)` form
  // (tools/check_seq_equiv.py proves every register and output equal).
  wire alloc_now = post_accept && !can_combine;
  wire [3:0] cnt_dec  = drain_accept ? n_now : 4'd0;
  wire [3:0] cnt_base = count - cnt_dec;

  // in_ready IS the CPU's memory ready (it reaches z486 through z_ready, which fans out
  // into the prefetcher, the microcode entry ROM and both L1s), so it is built from the
  // SHORTEST form of each arm - never from the drain-group decision (grp_run's rowkey
  // chain, pair_ok's add/compare, match_ok's window test), which cost the base fit its
  // clk_sys closure (324 failing endpoints through here).
  // * postable: accepted iff a slot is free. A store that could only COMBINE (buffer
  //   full) waits one drain instead; match_ok still chooses combine-vs-allocate below,
  //   so the data written is identical - only that rare stall differs.
  // * passthrough: mem_ready && use_pass && !pass_withdrawn, bit-equal to
  //   mem_accept && use_pass (use_pass implies pres_locked || pass_req, which makes
  //   mem_valid exactly !pass_withdrawn), without drain_ready in the cone.
  assign in_ready = postable ? can_alloc
                             : (mem_ready && use_pass && !pass_withdrawn);

  assign mem_addr      = use_pass ? in_addr : {5'd0, hi_r, win_addr[0], 2'b00};
  assign mem_din       = use_pass ? in_din  : win_data[0];
  assign mem_din_hi    = win_data[1];
  assign mem_be        = use_pass ? in_be   : win_be[0];
  assign mem_gath      = !use_pass && !pair_now;
  assign mem_burstcount = use_pass ? in_burstcount
                          : pair_now ? 8'd2
                            : mem_gath ? {4'd0, n_now} : 8'd1;
  assign mem_write     = use_pass ? in_write : 1'b1;
  assign mem_valid     = pass_withdrawn ? 1'b0 :
                         (pres_locked || pass_req || drain_ready);

  // The gather payload: entries 1.. of the presented group. At GATHER_K < 8 the
  // upper slots are read by no request and fold out.
  reg [440:0] gextra;
  always @* begin : gath_pack
    integer ej;
    gextra = 441'd0;
    for (ej = 1; ej < NB; ej = ej + 1)
      gextra[(ej-1)*GENT_W +: GENT_W] = {{hi_r, win_addr[ej], 2'b00}, win_data[ej], win_be[ej]};
  end
  assign mem_gath_extra = gextra;

  // A blocked request forces the drain out (registered, so no request field
  // combinationally reaches in_ready through the window): the CPU stalled on a
  // full buffer, or a PEGC read is waiting for the drain.
  wire block_now = (in_valid && postable && !can_alloc) ||
                   (in_valid && in_peg_route && !postable && (count != 4'd0));

  integer i;
  always @(posedge clk) begin
    if (reset) begin
      wp <= 3'd0; rp <= 3'd0; count <= 4'd0;
      pres_locked <= 1'b0; pres_pass <= 1'b0; pres_pair <= 1'b0; pres_n <= 4'd0;
      hold_force_r <= 1'b0;
      for (i = 0; i < DEPTH; i = i + 1) ent_age[i] <= {AGE_W{1'b0}};
    end else begin
      hold_force_r <= block_now;

      // The presentation lock: set when a request first goes on the bus, so the
      // SOURCE and the payload cannot move before its accept; cleared at the
      // accept or at a response-queue withdrawal (see pass_withdrawn above).
      if (mem_accept) begin
        pres_locked <= 1'b0;
      end else if (pass_withdrawn) begin
        pres_locked <= 1'b0;
      end else if (mem_valid && !pres_locked) begin
        pres_locked <= 1'b1;
        pres_pass   <= pass_req;
        pres_pair   <= pair_now;
        pres_n      <= n_now;
      end

      if (drain_accept) rp <= rp + n_now[2:0];

      // The post: a combine writes the store's enabled bytes into the matched entry (later lanes
      // win; an unenabled lane keeps its byte), an allocation writes the whole dword and its
      // enables into the slot at wp. Per entry and per lane, so the data path has no read-back.
      // THE SLOT AT wp IS WRITTEN ON EVERY POST (docs/timing.md C5-free), not only on an
      // allocation: a post needs can_alloc, so wp is a FREE slot, and a free slot's contents are
      // read by nothing that matters (the merge window, the run and the pair test stop at count,
      // the age at rp is read only while count != 0, and the payload's entries beyond the drain's
      // own are ignored by the controller), while the allocation writes all of it. So the slot's
      // write enables do not wait for the merge decision (can_combine, the 25-bit match OR);
      // only wp, count and the pair facts do, and they read it only as the final
      // select (alloc_now) with their adders/compares computed shallow. tools/check_storebuf_head_inv.py
      // proves the held entries, the control state and every output the controller reads unchanged.
      if (post_accept) begin
        ent_addr[wp] <= in_addr[18:2];
        hi_r         <= in_addr[26:19];   // equal to the held entries' (see the entries' note)
      end
      // C5-A: alloc_now only SELECTS; the increment/compares are shallow candidates off the match cone.
      wp           <= alloc_now ? (wp + 3'd1) : wp;
      // the pair (wp-1, wp)'s facts, against the newest held dword (meaningless, and never
      // read, when the buffer was empty: entry wp-1 is then not held)
      nx_adj[3'(wp - 3'd1)]    <= alloc_now ? ({1'b0, in_addr[18:2]} == ({1'b0, last_addr} + 18'd1)) : nx_adj[3'(wp - 3'd1)];   // 18 bits: the window's last dword and its first are NOT adjacent
      nx_row_lg[3'(wp - 3'd1)] <= alloc_now ? (in_addr[18:11] == last_addr[16:9]) : nx_row_lg[3'(wp - 3'd1)];
      nx_row_sm[3'(wp - 3'd1)] <= alloc_now ? (in_addr[18:10] == last_addr[16:8]) : nx_row_sm[3'(wp - 3'd1)];
      last_addr    <= alloc_now ? in_addr[18:2] : last_addr;
      for (i = 0; i < DEPTH; i = i + 1) begin
        if (post_accept && (3'(i) == wp)) begin
          ent_data[i] <= in_din;
          ent_be[i]   <= in_be;
        end else if (post_accept && match_hit[i]) begin
          if (in_be[0]) ent_data[i][7:0]   <= in_din[7:0];
          if (in_be[1]) ent_data[i][15:8]  <= in_din[15:8];
          if (in_be[2]) ent_data[i][23:16] <= in_din[23:16];
          if (in_be[3]) ent_data[i][31:24] <= in_din[31:24];
          ent_be[i] <= ent_be[i] | in_be;
        end
      end

      // Every entry's age runs from its OWN allocation and only that resets it
      // (rule 5, for every entry, not only the tail):
      // merging into an entry does not restart its window, so a stream that keeps
      // hitting one dword cannot hold it for as long as the stream lasts.
      for (i = 0; i < DEPTH; i = i + 1) begin
        if (post_accept && (3'(i) == wp))
          ent_age[i] <= {AGE_W{1'b0}};
        else if (ent_age[i] != AGE_W'(HOLD_CYCLES))
          ent_age[i] <= ent_age[i] + 1'b1;
      end

      count <= alloc_now ? (cnt_base + 4'd1) : cnt_base;
    end
  end

  // The response-queue withdrawal comment lives with pass_withdrawn above.

`ifdef VERILATOR
  // The entries keep byte address [18:2] and share [26:19]: a postable store must lie below 128 MiB
  // (the SDRAM's ceiling) and in the same 512 KiB window as every store still buffered (see hi_r).
  always @(posedge clk) begin
    if (!reset && in_valid && postable && (in_addr[31:27] != 5'd0))
      $fatal(1, "pc9821_pegc_storebuf: a postable store at %08h is beyond the 128 MiB the entries hold", in_addr);
    if (!reset && in_valid && postable && (count != 4'd0) && (in_addr[26:19] != hi_r))
      $fatal(1, "pc9821_pegc_storebuf: a postable store at %08h is outside the 512 KiB window of the buffered stores (%02h)", in_addr, hi_r);
  end
  // A burstcount-2 write is the PAIR DRAIN's shape (its second word is this
  // buffer's mem_din_hi); a passthrough write asking for one would take the
  // controller's two-word path with 32'd0 as its second dword.
  always @(posedge clk) begin
    if (!reset && mem_accept && mem_write && pres_pass && (mem_burstcount == 8'd2))
      $fatal(1, "pc9821_pegc_storebuf: a passthrough write presented burstcount 2 -- only the pair drain may ask for the two-word write");
    if (!reset && drain_accept && pair_now &&
        ({1'b0, win_addr[1]} != ({1'b0, win_addr[0]} + 18'd1)))
      $fatal(1, "pc9821_pegc_storebuf: a pair drain left non-adjacent dwords");
    if (!reset && drain_accept && mem_gath && (n_now > 4'(GATHER_K)))
      $fatal(1, "pc9821_pegc_storebuf: a gather drain carried %0d entries over GATHER_K=%0d", n_now, GATHER_K);
    // Rule 6's second line: a merge into a committed entry would move the frozen
    // payload (or lose the store at the pop). The commit window refuses it in RTL;
    // this asserts the refusal held.
    if (!reset && post_accept && can_combine) begin : chk_merge
      integer ci;
      for (ci = 0; ci < DEPTH; ci = ci + 1)
        if (match_hit[ci] && (({1'b0, 3'(ci)} - {1'b0, rp}) < pres_cnt))
          $fatal(1, "pc9821_pegc_storebuf: a store merged into presented entry %0d (window %0d) -- the drain payload is not frozen",
                 ci, pres_cnt);
      if ($countones(match_hit) > 1)
        $fatal(1, "pc9821_pegc_storebuf: a store matched two held entries -- rule 2 allows one dword per entry");
    end
  end
`endif

endmodule

`default_nettype wire

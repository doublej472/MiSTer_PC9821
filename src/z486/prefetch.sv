//
// Prefetcher
// 32-byte prefetch queue feeding the K1Q decode window and the K2Q literal window
//
`include "z486_platform.svh"
`Z486_NO_RETIME
module prefetch
    import z486_pkg::*;
(
    input             clk,
    input             reset_n,

    // Queue read interface to the decoder (two cursors, one pop point)
    output     [63:0] k1q,        // registered raw window at the D1 cursor
    output     [63:0] k1q_early,  // speculative window for synchronous entry ROM
    output     [5:0]  k1q_avail,      // bytes fetched beyond the D1 cursor
    output     [5:0]  k1q_avail_raw,  //   = min(k1q_avail_raw, k1q_avail_lim): the
    output     [5:0]  k1q_avail_lim,  //   buffered bytes and the CS-limit bound
    input      [3:0]  k1p_adv,        // D1 cursor advance this cycle (0-11: a
                                     //   prefix, or the instruction rest at handoff)
    input      [3:0]  k1p_preread_adv,// structural advance independent of D2 availability
    input      [3:0]  k1p_adv_u,      // the advance if D1 steps (availability aside)
    input             k1p_step_ok,    // k1p_preread_adv == (k1p_step_ok ? k1p_adv_u : 0)
    input             k1p_commit_u,   // k1p_adv == (k1p_commit_u ? k1p_adv_u : 0)
    output     [31:0] k2q,       // 4 bytes at pop_cursor + k2p_off
    output     [5:0]  k2q_avail,     // bytes fetched beyond that point
    input      [4:0]  k2p_off,       // literal offset from the pop cursor
    output            q_full,
    input             pop_now,       // one instruction completed D2
    input      [4:0]  pop_len,       // its full byte length (registered source)

    // Flush from microcode
    input             q_flush,
    input      [31:0] pf_flush_addr, // LINEAR address

    // Toggle interface to paging unit
    output reg        pf_req_toggle,
    output reg [31:0] pf_linear_addr,
    output reg        pf_redirect_queued,
    input             pf_ack_toggle,
    input      [127:0] pf_rdata,
    input             pf_nocache,    // this line is not cacheable (PTE.PCD or CR0.CD)
    input             pf_fault,      // page fault response for this fetch
    // The paging unit declined a speculative target fetch (no TLB hit, or the
    // page is not cacheable RAM): the ack carries no data and no fault.
    input             pf_refused,
    // The outstanding request is a speculative target fetch. It drops when a
    // flush adopts the fetch as the real post-flush fill.
    output            pf_spec,
    input      [2:0]  pf_fault_code,
    input      [31:0] pf_fault_addr,
    input             fetch_blocked, // decoder needs bytes beyond buffered data
    output reg        ifetch_fault,  // registered one-shot architectural fault
    output     [2:0]  ifetch_fault_code,
    output     [31:0] ifetch_fault_addr,
    // Bytes from the pop cursor (EIP) through the CS limit, saturated at 63:
    // decode never sees a byte beyond the limit, and an instruction that needs
    // one takes #GP(0) once it is the oldest unissued instruction.
    input      [5:0]  fetch_limit_rem,
    output reg        ifetch_limit_fault, // registered one-shot #GP(0)

    // Control
    input             pf_suspend,    // external suspend (e.g. page fault handler active)
    input             halt_speculative, // decode queue holds a taken JMP/CALL: stop fetching past it

    input             spec_req,
    input      [31:0] spec_linear,
    input      [31:0] spec_lin_a,    // spec_linear == spec_lin_a + spec_lin_b (the
    input      [31:0] spec_lin_b,    // segment base and the target offset)
    input             spec_owner,    // the currently-executing instruction is the
                                     // one that requested the buffered/in-flight
                                     // spec fetch: its taken-flush address equals
                                     // the spec target BY CONSTRUCTION (same
                                     // adder inputs), so no address compare
    input             spec_store_valid,
    input      [11:4] spec_store_line, // page-offset line bits of the store
    input             spec_store_cross, // the store's last byte is in the next line
    input             spec_global_kill
);

// 32-byte prefetch queue (8 x 32-bit words).  Cache fills write up to four
// queue words at once.  After a branch into the middle of a cache line, the
// first fill drops words before the target address and starts decoding at the
// requested byte offset.
reg [31:0] prefetch_queue [7:0];
reg [3:0]  pf_rptr;                  // Pop cursor word (0-7) with wraparound bit
reg [3:0]  pf_wptr;                  // Write pointer (0-7) with wraparound bit
reg [1:0]  pf_byte_offset;           // Pop cursor byte offset within dword (0-3)
reg [3:0]  k1p_word;                  // D1 cursor word, >= pop cursor
reg [1:0]  k1p_boff;                  // D1 cursor byte offset
reg [1:0]  pf_fetch_word_start;      // First word to keep from next fetched line
reg        pf_suspended;             // Prefetch suspended (page fault until flush)
reg        pf_fault_reported;        // retained fault has been sent to the core
reg        pf_limit_reported;        // CS-limit fault has been sent to the core
reg [2:0]  pf_fault_code_r;
reg [31:0] pf_fault_addr_r;
reg        pf_drop_inflight;         // Drop next prefetch result (flush during in-flight)
reg [31:0] pf_fetch_addr;            // Next LINEAR cache-line address to prefetch

reg         spec_pend;               // latched request waiting for the port
reg  [31:0] spec_pend_addr;          // requested target (full: line + in-line offset)
reg  [31:4] spec_addr;               // line address of the in-flight/buffered fetch
reg  [3:0]  spec_off;                // target's in-line offset, latched at launch:
                                     //   drives the flush-hit seed placement from
                                     //   REGISTERS (pf_flush_addr arrives too late)
reg         spec_inflight;           // the outstanding paging request is the spec fetch
reg         spec_valid;              // spec_line holds the line at spec_addr
reg         spec_adopted_r;          // post-flush fill is an adopted spec line: buffer it too
reg         spec_poison;             // a store/snoop occurred since the fetch started
reg [127:0] spec_line;
// Victim entry: the previously buffered target line, kept when a new spec
// request replaces it, so two branches in one loop (a not-taken exit test and
// the back edge) do not evict each other's target every iteration.
reg         spec_b_valid;
reg  [31:4] spec_b_addr;
reg [127:0] spec_b_line;

// Normal 386 self-modifying code performs a frontend-flushing branch after
// the store. Keep the buffered target coherent for that branch without
// discarding it for unrelated data stores. Global events remain conservative.
// Only the page-offset bits are compared: they are untranslated, so a store
// through any linear alias of the buffered line's physical page matches (an
// unrelated store with the same offset merely costs a refetch).
// A store that crosses into the next line writes both (the wrap from line
// 0xFF to 0x00 is the next page's first line, by page offset as well).
wire [11:4] spec_store_line2 = spec_store_line + 8'd1;
wire spec_store_hit = spec_store_valid &&
                      ((spec_addr[11:4] == spec_store_line) ||
                       (spec_store_cross && (spec_addr[11:4] == spec_store_line2)));
wire spec_kill = spec_global_kill || spec_store_hit;
wire spec_b_store_hit = spec_store_valid &&
                        ((spec_b_addr[11:4] == spec_store_line) ||
                         (spec_store_cross && (spec_b_addr[11:4] == spec_store_line2)));

// synthesis translate_off
bit TRACE_FLUSH_EN;
initial TRACE_FLUSH_EN = $test$plusargs("trace_flush");
// Sim-only: the queue powers up X.  k1q is reset to 0, but k2q
// (combinational over the queue) would be X until the first fill.  Hardware
// defines the queue via reset+fill before any decode; zero it here so sim
// matches.
initial for (int k = 0; k < 8; k++) prefetch_queue[k] = 32'h0;
// synthesis translate_on

function automatic [2:0] ptr_idx(input [3:0] ptr);
    begin
        ptr_idx = ptr[2:0];
    end
endfunction

wire [3:0] pf_word_count = pf_wptr - pf_rptr; // 0..8 valid queue words
wire       q_empty = (pf_word_count == 4'd0);
wire [5:0] pf_byte_count = q_empty ? 6'd0 :
                           ({2'b00, pf_word_count} << 2) - {4'b0000, pf_byte_offset};
assign q_full = (pf_word_count == 4'd8);

// D1 cursor byte availability.  The cursor may legitimately sit BEYOND the
// write pointer (a skeleton handoff advances it past literal bytes that are
// still being fetched), so derive it as pop-relative lead vs the buffered
// byte count and clamp at zero.
wire [3:0] k1p_lead_words = k1p_word - pf_rptr;
wire [6:0] k1p_lead = {1'b0, k1p_lead_words, 2'b00} + {5'b00000, k1p_boff} -
                     {5'b00000, pf_byte_offset};
wire [7:0] k1q_avail_s = {2'b00, pf_byte_count} - {1'b0, k1p_lead};
assign k1q_avail_raw = k1q_avail_s[7] ? 6'd0 : k1q_avail_s[5:0];
// The CS limit bounds both decode windows (Intel486 PRM: an instruction any
// byte of which lies beyond the code-segment limit raises #GP(0); in real
// mode the limit is 0FFFFh and the fault is interrupt 13).
wire [7:0] k1_lim_s = {2'b00, fetch_limit_rem} - {1'b0, k1p_lead};
wire [5:0] k1_lim   = k1_lim_s[7] ? 6'd0 : k1_lim_s[5:0];
assign k1q_avail = (k1q_avail_raw > k1_lim) ? k1_lim : k1q_avail_raw;
assign k1q_avail_lim = k1_lim;

// D2 literal window: pop_cursor + k2p_off, over REGISTERED queue words.
wire [5:0] k2p_sum  = {4'b0000, pf_byte_offset} + {1'b0, k2p_off};
wire [3:0] k2p_word = pf_rptr + {1'b0, k2p_sum[4:2]};
wire [31:0] k2p_word_cur = prefetch_queue[ptr_idx(k2p_word)];
wire [31:0] k2p_word_nxt = prefetch_queue[ptr_idx(k2p_word + 4'd1)];
assign k2q =
    k2p_sum[1:0] == 2'd0 ? k2p_word_cur :
    k2p_sum[1:0] == 2'd1 ? {k2p_word_nxt[7:0],  k2p_word_cur[31:8]} :
    k2p_sum[1:0] == 2'd2 ? {k2p_word_nxt[15:0], k2p_word_cur[31:16]} :
                           {k2p_word_nxt[23:0], k2p_word_cur[31:24]};
wire [6:0] k2q_avail_s = {1'b0, pf_byte_count} - {2'b00, k2p_off};
wire [5:0] k2q_avail_raw = k2q_avail_s[6] ? 6'd0 : k2q_avail_s[5:0];
wire [6:0] k2_lim_s = {1'b0, fetch_limit_rem} - {2'b00, k2p_off};
wire [5:0] k2_lim   = k2_lim_s[6] ? 6'd0 : k2_lim_s[5:0];
assign k2q_avail = (k2q_avail_raw > k2_lim) ? k2_lim : k2q_avail_raw;
// Every byte up to the limit is buffered: a blocked decode then needs a byte
// beyond it.  The limit check precedes paging, so this also keeps a retained
// prefetch page fault on a line past the limit from being reported.
wire limit_reached = (pf_byte_count >= fetch_limit_rem);

wire pf_inflight = (pf_req_toggle != pf_ack_toggle);

reg pf_ack_prev;
wire pf_ack_edge = (pf_ack_toggle != pf_ack_prev);

wire [2:0] fetch_write_words = 3'd4 - {1'b0, pf_fetch_word_start};
// A spec-fetch response goes to the spec buffer, never the queue.
wire good_ack = pf_ack_edge && !pf_drop_inflight && !pf_fault && !pf_refused && !spec_inflight;
assign pf_spec = spec_inflight;
wire [4:0] pf_words_after_ack =
    {1'b0, pf_word_count} + (good_ack ? {2'b00, fetch_write_words} : 5'd0);
wire pf_has_line_space = (pf_words_after_ack <= 5'd4);

wire pf_can_fetch = pf_has_line_space && !pf_suspended && !pf_suspend &&
                    !q_flush && !pf_inflight && !halt_speculative;
wire pf_can_fetch_after_flush = q_flush && !pf_suspend && !pf_inflight;

// Fetches may run ahead of execution, so a sequential prefetch fault is not an
// exception until decode actually needs bytes from the faulted line.
assign ifetch_fault_code = pf_fault_code_r;
assign ifetch_fault_addr = pf_fault_addr_r;

// (a + b)[31:4] == k without the sum's carry chain. If the sum's bits below
// bit i equal k's, the carry into bit i is maj(a, b, a^b^k) at bit i-1 =
// (a & b) | ((a | b) & ~k); so the sum equals k iff every bit's a^b^k equals
// that carry, and bit 4 takes the real carry out of the low nibble.
// tests/equiv/spec_line_eq.v proves it for every input.
function automatic logic sum_line_eq(input logic [31:0] a, input logic [31:0] b,
                                     input logic [31:4] k);
    logic [4:0]  low;
    logic [31:4] cin;
    begin
        low = {1'b0, a[3:0]} + {1'b0, b[3:0]};
        cin[4] = low[4];
        cin[31:5] = (a[30:4] & b[30:4]) | ((a[30:4] | b[30:4]) & ~k[30:4]);
        sum_line_eq = ((a[31:4] ^ b[31:4] ^ k) == cin);
    end
endfunction

// The target-line compares take the two addends, so the match decisions (and
// the victim swap's 157-wide enable) do not wait for spec_linear's adder.
wire spec_addr_hit   = sum_line_eq(spec_lin_a, spec_lin_b, spec_addr);
wire spec_b_addr_hit = sum_line_eq(spec_lin_a, spec_lin_b, spec_b_addr);
// synthesis translate_off
always @(posedge clk)
    if (reset_n && spec_req && (spec_linear !== spec_lin_a + spec_lin_b))
        $fatal(1, "prefetch: spec_linear %h is not spec_lin_a %h + spec_lin_b %h",
               spec_linear, spec_lin_a, spec_lin_b);
// synthesis translate_on

wire spec_match_now = spec_req && spec_valid && !spec_poison && !spec_inflight &&
                      spec_addr_hit;
// A request that hits the victim entry swaps it into the active buffer
// instead of fetching. Skip the swap in a cycle with any store or global
// kill, so a stale victim line can never become active.
wire spec_b_match = spec_req && !spec_match_now && spec_b_valid &&
                    !spec_inflight && !spec_pend &&
                    !spec_store_valid && !spec_global_kill &&
                    spec_b_addr_hit;
// A request for the line already in flight (an older branch's target in the
// same line) re-owns that fetch, as spec_match_now re-owns a buffered line.
wire spec_inflight_match = spec_req && spec_inflight && !spec_poison && !spec_pend &&
                           spec_addr_hit;
wire spec_want   = ((spec_req && !spec_match_now && !spec_b_match && !spec_inflight_match) ||
                    spec_pend);
wire spec_launch = spec_want && !pf_inflight && !q_flush && !pf_suspend &&
                   !pf_redirect_queued && !pf_drop_inflight;
wire spec_line_match   = spec_valid && !spec_poison && spec_owner;
wire spec_adopt        = spec_inflight && !spec_poison && !pf_ack_edge && spec_owner;
wire spec_data_now     = spec_inflight && !spec_poison && pf_ack_edge && !pf_fault && !pf_refused &&
                         spec_owner;
wire spec_flush_hit    = q_flush && (spec_line_match || spec_data_now);
// synthesis translate_off
// Ownership stands in for an address compare: prove it on every adopted flush.
always @(posedge clk)
    if (reset_n && q_flush && (spec_flush_hit || spec_adopt) &&
        ((spec_addr != pf_flush_addr[31:4]) || (spec_off != pf_flush_addr[3:0])))
        $fatal(1, "SPEC OWNER MISMATCH: line %07x off %x flush %08x",
               spec_addr, spec_off, pf_flush_addr);
// synthesis translate_on
// K1PJ (US5293592): the byte where code begins after a jump, returned with
// the refilled line. The buffered target line supplies its latched offset.
wire [1:0] k1pj_boff = spec_flush_hit ? spec_off[1:0] : pf_flush_addr[1:0];
wire [1:0] flush_word = spec_flush_hit ? spec_off[3:2] : pf_flush_addr[3:2];
// An unaligned seed starts from an empty queue; this delta moves every cursor
// onto the seed word's slot.
wire [3:0] seed_delta = {pf_wptr[3:2], pf_fetch_addr[3:2]} - pf_wptr;
wire [127:0] spec_hit_line = spec_data_now ? pf_rdata : spec_line;

function automatic [31:0] line_word(input [127:0] line, input [1:0] word);
    begin
        line_word = line[{word, 5'b0} +: 32];
    end
endfunction

// Next-state of the queue head, mirroring the update priority of the
// registered always_ff below: pop, then fill, then flush, then the
// unaligned-seed case at fetch launch.
wire fill_commit = good_ack && !q_flush;
wire seed_now = pf_can_fetch && !good_ack && q_empty &&
                (pf_fetch_addr[3:0] != 4'h0);
// One pop per instruction: the advance amount is a REGISTERED value
// (skel.length from the decoder), up to 15 bytes + offset 3 -> 5 bits.
wire [5:0] byte_advance = {4'b0000, pf_byte_offset} + {1'b0, pop_len};
// D1 cursor advance: a prefix byte or the instruction rest at handoff.
wire [3:0] k1p_sum = {2'b00, k1p_boff} + k1p_adv;
wire [3:0] k1p_preread_sum = {2'b00, k1p_boff} + k1p_preread_adv;

logic [255:0] queue_nf;         // next queue without a flush: the fill only
logic [255:0] queue_fl;         // next queue on a flush that hits the buffered line
always_comb begin
    for (int k = 0; k < 8; k++) begin
        queue_nf[32*k +: 32] = prefetch_queue[k];
        queue_fl[32*k +: 32] = prefetch_queue[k];
    end
    if (good_ack)
        for (int j = 0; j < 4; j++)
            if (2'(j) >= pf_fetch_word_start)
                queue_nf[{pf_wptr[2], 2'(j), 5'b0} +: 32] = line_word(pf_rdata, 2'(j));
    for (int j = 0; j < 4; j++)
        if (2'(j) >= spec_off[3:2])
            queue_fl[32*j +: 32] = line_word(spec_hit_line, 2'(j));
end

// The stepped window is formed from the step's size alone (k1p_adv_u: the
// opcode and the length tables), and the decoder's byte-availability verdict
// (k1p_step_ok / k1p_commit_u) picks it or the held window last, so the
// pf pointers -> k1q_avail -> d1_struct_ready path ends at that pick instead
// of running through the cursor adder and the window mux. A seed (empty
// queue: nothing is in view, so D1 takes no step) rebases the cursor as
// before. tests/equiv/kpre_window_split.v proves both windows equal to the
// k1p_preread_adv / k1p_adv forms; the reference fuses below hold them.
logic [3:0] k1p_u_word;
logic [1:0] k1p_u_boff;
wire  [3:0] k1p_u_sum = {2'b00, k1p_boff} + k1p_adv_u;
always_comb begin
    k1p_u_word = k1p_word + {2'b00, k1p_u_sum[3:2]};
    k1p_u_boff = k1p_u_sum[1:0];
    if (seed_now) begin
        k1p_u_word = k1p_word + seed_delta;
        k1p_u_boff = pf_fetch_addr[1:0];
    end
end
logic [3:0]  rptr_next;
logic [3:0]  wptr_next;
logic [1:0]  byte_offset_next;
logic [3:0]  k1p_word_next;
logic [1:0]  k1p_boff_next;
logic [31:0] queue_next [7:0];

always_comb begin
    rptr_next = pf_rptr;
    wptr_next = pf_wptr;
    byte_offset_next = pf_byte_offset;
    // The committed D1 cursor follows the same pick as k1q_next: the stepped
    // cursor (k1p_u_word/boff, the seed rebase included) when D1 commits its
    // step, else the held one - the late k1p_adv (D2's issue, q_flush) no
    // longer runs through the cursor adder. tests/equiv/kadv_cursor.v proves
    // it equal to k1p_word + (k1p_boff + k1p_adv) and the seed rebase.
    k1p_word_next = (seed_now || k1p_commit_u) ? k1p_u_word : k1p_word;
    k1p_boff_next = (seed_now || k1p_commit_u) ? k1p_u_boff : k1p_boff;
    // The queue words come from the two next-queue views above: the fill
    // without a flush, the seeded target line on a flush that hits it.
    for (int k = 0; k < 8; k++)
        queue_next[k] = q_flush ? (spec_flush_hit ? queue_fl[32*k +: 32] : prefetch_queue[k])
                                : queue_nf[32*k +: 32];

    if (pop_now) begin
        byte_offset_next = byte_advance[1:0];
        rptr_next = pf_rptr + byte_advance[5:2];
    end

    // Queue slots are aligned to line words: line word j always lands in
    // slot {half, j}. After a flush the pointers start at the target's word
    // within the line (see below), so a fill needs no per-slot word mux.
    if (fill_commit)
        wptr_next = pf_wptr + {1'b0, fetch_write_words};

    if (q_flush) begin
        rptr_next = {2'b00, flush_word};
        wptr_next = {2'b00, flush_word};
        byte_offset_next = k1pj_boff;
        k1p_word_next = {2'b00, flush_word};
        k1p_boff_next = k1pj_boff;
        // A hit seeds the queue from the buffered target line (queue_fl):
        // all placement selects come from the LATCHED spec_off.
        if (spec_flush_hit)
            wptr_next = 4'd4;
    end

    if (seed_now) begin
        // The queue is empty: rebase the pointers onto the seed word so the
        // aligned fill places it at the pop cursor.
        rptr_next = pf_rptr + seed_delta;
        wptr_next = pf_wptr + seed_delta;
        byte_offset_next = pf_fetch_addr[1:0];
    end
end

// synthesis translate_off
// The committed cursor against its adder form (k1p_word + (k1p_boff + k1p_adv),
// the flush origin, the seed rebase), which the window references build on.
logic [3:0] ref_k1p_word_next;
logic [1:0] ref_k1p_boff_next;
always_comb begin
    ref_k1p_word_next = k1p_word + {2'b00, k1p_sum[3:2]};
    ref_k1p_boff_next = k1p_sum[1:0];
    if (q_flush) begin
        ref_k1p_word_next = {2'b00, flush_word};
        ref_k1p_boff_next = k1pj_boff;
    end
    if (seed_now) begin
        ref_k1p_word_next = ref_k1p_word_next + seed_delta;
        ref_k1p_boff_next = pf_fetch_addr[1:0];
    end
end
always @(posedge clk)
    if (reset_n && ((k1p_word_next !== ref_k1p_word_next) || (k1p_boff_next !== ref_k1p_boff_next)))
        $fatal(1, "PF: D1 cursor %0d.%0d is not the adder form %0d.%0d (adv=%0d commit=%b seed=%b)",
               k1p_word_next, k1p_boff_next, ref_k1p_word_next, ref_k1p_boff_next,
               k1p_adv, k1p_commit_u, seed_now);
reg PF_CUR = 1'b0;
initial if ($test$plusargs("pf_cur")) PF_CUR = 1'b1;
always @(posedge clk) begin
    if (PF_CUR && (pop_now || (k1p_adv != 4'd0) || q_flush || fill_commit))
        $display("%0t PFCUR pop=%b len=%0d adv=%0d flush=%b fill=%b | rptr=%0d.%0d wptr=%0d d1=%0d.%0d cnt=%0d d1av=%0d litoff=%0d litav=%0d",
                 $time, pop_now, pop_len, k1p_adv, q_flush, fill_commit,
                 pf_rptr, pf_byte_offset, pf_wptr, k1p_word, k1p_boff,
                 pf_byte_count, k1q_avail, k2p_off, k2q_avail);
    if (reset_n && pop_now && ({1'b0, pf_byte_count} < {2'b00, pop_len}))
        $fatal(1, "PF: pop_now for %0d bytes with only %0d buffered (rptr=%0d.%0d wptr=%0d d1=%0d.%0d flush=%b)",
               pop_len, pf_byte_count, pf_rptr, pf_byte_offset, pf_wptr,
               k1p_word, k1p_boff, q_flush);
end
// synthesis translate_on

// synthesis translate_off
reg PF_EVT = 1'b0;
initial if ($test$plusargs("pf_evt")) PF_EVT = 1'b1;
always @(posedge clk) if (PF_EVT) begin
    if (q_flush)
        $display("%0t PF flush addr=%08x hit=%b adopt=%b datanow=%b specv=%b specinfl=%b pfinfl=%b ack=%b off=%h",
                 $time, pf_flush_addr, spec_flush_hit, spec_adopt, spec_data_now,
                 spec_valid, spec_inflight, pf_inflight, pf_ack_edge, spec_off);
    if (fill_commit)
        $display("%0t PF fill wptr=%h ws=%h data0=%08x (fetch=%08x)",
                 $time, pf_wptr, pf_fetch_word_start, pf_rdata[31:0], pf_fetch_addr);
    if (spec_req)
        $display("%0t PF specreq lin=%08x match=%b (specaddr=%07x0 v=%b)",
                 $time, spec_linear, spec_match_now, spec_addr, spec_valid);
    if (spec_launch)
        $display("%0t PF speclaunch tgt=%08x", $time,
                 (spec_req && !q_flush) ? spec_linear : spec_pend_addr);
    if (pf_ack_edge)
        $display("%0t PF ack drop=%b fault=%b specinfl=%b adopted=%b data0=%08x",
                 $time, pf_drop_inflight, pf_fault, spec_inflight, spec_adopted_r, pf_rdata[31:0]);
end
// synthesis translate_on

// If D2 backpressure blocks a structural handoff, the D1 cursor holds. Build
// that hold window without the late k1p_adv/i_issue cursor adder; the already
// required preread window below supplies the advancing case. The late control
// path therefore ends at one 64-bit select instead of traversing an add and
// byte aligner.
//
// q_flush is decided late (a taken Jcc's forwarded flags), so the D1 windows
// are formed for both outcomes and q_flush picks one last. Without a flush the
// queue takes only the fill; with one it is the buffered target line seeded
// at the latched spec_off. A flush that misses the buffered line empties the
// queue, so its window is unused until the refill rewrites it, and the flush
// view need not follow pf_flush_addr there.
function automatic [63:0] d1_window(input logic [255:0] q,   // queue, slot k at [32k +: 32]
                                    input logic [3:0] word,
                                    input logic [1:0] boff);
    logic [31:0] cur, nxt, nd2;
    begin
        cur = q[{ptr_idx(word), 5'b0} +: 32];
        nxt = q[{ptr_idx(word + 4'd1), 5'b0} +: 32];
        nd2 = q[{ptr_idx(word + 4'd2), 5'b0} +: 32];
        d1_window = boff == 2'd0 ? {nxt, cur} :
                    boff == 2'd1 ? {nd2[7:0], nxt, cur[31:8]} :
                    boff == 2'd2 ? {nd2[15:0], nxt, cur[31:16]} :
                                   {nd2[23:0], nxt, cur[31:24]};
    end
endfunction


wire [63:0] k1q_hold_next  = d1_window(queue_nf, k1p_word, k1p_boff);
wire [63:0] k1q_flush_next = d1_window(queue_fl, {2'b00, spec_off[3:2]}, spec_off[1:0]);

// Run the entry-table cursor from structural decode alone. If the real D1
// cursor is held by D2, the decoder keeps the prior table output; therefore
// this address never needs issue, VIPT, paging, or execution readiness.
wire [63:0] k1q_step_nf = d1_window(queue_nf, k1p_u_word, k1p_u_boff);
wire [63:0] k1q_preread_nf = (seed_now || k1p_step_ok) ? k1q_step_nf : k1q_hold_next;
wire [63:0] k1q_preread_next = q_flush ? k1q_flush_next : k1q_preread_nf;
// The entry ROM reads only the window's first byte. On a flush that byte is
// always the target line's byte at spec_off (the window's first word is slot
// spec_off[3:2], which queue_fl always seeds from the line), so it is formed
// from both line candidates and the late spec_data_now (an icache hit's
// pf_ack_edge) picks it last, instead of selecting 128 line bits before the
// queue_fl seed, the word and byte aligners. tests/equiv/flush_byte0_late.v
// proves it equal to k1q_flush_next[7:0] for every input.
wire [7:0] flush_byte0_ack  = pf_rdata[{spec_off, 3'b000} +: 8];
wire [7:0] flush_byte0_held = spec_line[{spec_off, 3'b000} +: 8];
wire [7:0] k1q_flush_byte0  = spec_data_now ? flush_byte0_ack : flush_byte0_held;
assign k1q_early = {k1q_preread_next[63:8],
                    q_flush ? k1q_flush_byte0 : k1q_preread_nf[7:0]};

// q_flush gives both cursor views the same redirected origin. Otherwise the
// real cursor advances exactly when structural preread and committed advance
// agree (k1p_commit_u); disagreement means D2 held the handoff.
wire [63:0] k1q_next = q_flush ? k1q_flush_next :
                       (seed_now || k1p_commit_u) ? k1q_step_nf : k1q_hold_next;
// synthesis translate_off
// The split's premise: a seed cycle (empty queue) has no D1 step.
always @(posedge clk)
    if (reset_n && seed_now && (k1p_step_ok || (k1p_adv != 4'd0) || (k1p_preread_adv != 4'd0)))
        $fatal(1, "PF: D1 steps in a seed cycle (ok=%b adv=%0d pre=%0d)",
               k1p_step_ok, k1p_adv, k1p_preread_adv);
// synthesis translate_on

// synthesis translate_off
wire [31:0] k1p_reference_word_cur = queue_next[ptr_idx(k1p_word_next)];
wire [31:0] k1p_reference_word_nxt = queue_next[ptr_idx(k1p_word_next + 4'd1)];
wire [31:0] k1p_reference_word_2nd = queue_next[ptr_idx(k1p_word_next + 4'd2)];
wire [63:0] k1q_reference =
    k1p_boff_next == 2'd0 ? {k1p_reference_word_nxt,
                             k1p_reference_word_cur} :
    k1p_boff_next == 2'd1 ? {k1p_reference_word_2nd[7:0],
                             k1p_reference_word_nxt,
                             k1p_reference_word_cur[31:8]} :
    k1p_boff_next == 2'd2 ? {k1p_reference_word_2nd[15:0],
                             k1p_reference_word_nxt,
                             k1p_reference_word_cur[31:16]} :
                           {k1p_reference_word_2nd[23:0],
                             k1p_reference_word_nxt,
                             k1p_reference_word_cur[31:24]};
// The pre-split early window: the preread cursor (flush leg included) over
// the full next queue.
logic [3:0] ref_preread_word;
logic [1:0] ref_preread_boff;
always_comb begin
    ref_preread_word = k1p_word + {2'b00, k1p_preread_sum[3:2]};
    ref_preread_boff = k1p_preread_sum[1:0];
    if (q_flush) begin
        ref_preread_word = {2'b00, flush_word};
        ref_preread_boff = k1pj_boff;
    end else if (seed_now) begin
        ref_preread_word = ref_preread_word + seed_delta;
        ref_preread_boff = pf_fetch_addr[1:0];
    end
end
logic [255:0] queue_next_packed;
always_comb for (int k = 0; k < 8; k++) queue_next_packed[32*k +: 32] = queue_next[k];
wire [63:0] k1q_early_reference = d1_window(queue_next_packed, ref_preread_word, ref_preread_boff);
// A flush that misses the buffered line leaves an empty queue: no window is
// read until the refill, so only that case may differ.
wire k1q_window_dont_care = q_flush && !spec_flush_hit;
always_ff @(posedge clk) begin
    if (reset_n && !k1q_window_dont_care && (k1q_next !== k1q_reference))
        $fatal(1, "PF D1 WINDOW MISMATCH: selected=%h reference=%h",
               k1q_next, k1q_reference);
    if (reset_n && !k1q_window_dont_care && (k1q_early !== k1q_early_reference))
        $fatal(1, "PF D1 EARLY WINDOW MISMATCH: selected=%h reference=%h",
               k1q_early, k1q_early_reference);
    if (reset_n && k1q_window_dont_care && (wptr_next != rptr_next))
        $fatal(1, "PF: a flush missing the buffered line left queue words (rptr %0d wptr %0d)",
               rptr_next, wptr_next);
end
// synthesis translate_on

// Keep the queue/decoder boundary physical. Quartus retiming this register
// turns an icache response into a same-cycle cache -> aligner -> D1 PLA path.
`Z486_KEEP reg [63:0] k1q_r;
assign k1q = k1q_r;

always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        pf_rptr <= 4'h0;
        pf_wptr <= 4'h0;
        pf_byte_offset <= 2'h0;
        k1p_word <= 4'h0;
        k1p_boff <= 2'h0;
        pf_fetch_word_start <= 2'h0;
        pf_suspended <= 1'b0;
        ifetch_fault <= 1'b0;
        pf_fault_reported <= 1'b0;
        ifetch_limit_fault <= 1'b0;
        pf_limit_reported <= 1'b0;
        pf_fault_code_r <= 3'b000;
        pf_fault_addr_r <= 32'h0;
        pf_drop_inflight <= 1'b0;
        pf_fetch_addr <= 32'hFFFF_FFF0;  // Reset vector, cache-line aligned
        pf_req_toggle <= 1'b0;
        pf_linear_addr <= 32'h0;
        pf_redirect_queued <= 1'b0;
        pf_ack_prev <= 1'b0;
        k1q_r <= 64'h0;
        spec_pend <= 1'b0;
        spec_inflight <= 1'b0;
        spec_valid <= 1'b0;
        spec_adopted_r <= 1'b0;
        spec_poison <= 1'b0;
        spec_pend_addr <= '0;
        spec_addr <= '0;
        spec_off <= '0;
        spec_b_valid <= 1'b0;
        spec_b_addr <= '0;
    end else begin
        pf_ack_prev <= pf_ack_toggle;
        ifetch_fault <= 1'b0;
        ifetch_limit_fault <= 1'b0;

        pf_rptr <= rptr_next;
        pf_wptr <= wptr_next;
        pf_byte_offset <= byte_offset_next;
        k1p_word <= k1p_word_next;
        k1p_boff <= k1p_boff_next;
        k1q_r <= k1q_next;
        for (int k = 0; k < 8; k++)
            prefetch_queue[k] <= queue_next[k];

        if (q_flush) begin
            pf_fetch_addr <= {pf_flush_addr[31:4], 4'b0000};
            pf_fetch_word_start <= pf_flush_addr[3:2];
            pf_linear_addr <= {pf_flush_addr[31:4], 4'b0000};
            pf_suspended <= 1'b0;
            pf_fault_reported <= 1'b0;
            pf_limit_reported <= 1'b0;
            if (spec_flush_hit) begin
                // Target line already buffered (or arriving right now): the
                // queue was seeded combinationally; continue sequentially.
                pf_fetch_addr <= {pf_flush_addr[31:4], 4'b0000} + 32'd16;
                pf_fetch_word_start <= 2'd0;
                pf_linear_addr <= {pf_flush_addr[31:4], 4'b0000} + 32'd16;
                if (pf_inflight && !pf_ack_edge && !spec_inflight) begin
                    pf_drop_inflight <= 1'b1;
                    pf_redirect_queued <= 1'b1;
                    pf_req_toggle <= pf_ack_toggle;
                end
            end else if (spec_adopt) begin
                // The spec fetch for exactly this target is still in flight:
                // adopt it as the post-flush fill (no drop, no new request).
            end else if (pf_inflight && !pf_ack_edge && !spec_inflight) begin
                // Queue the redirect request behind the current prefetch.  When
                // the old line completes, paging can immediately launch this
                // target request instead of waiting for prefetch to toggle in
                // the following cycle.
                pf_drop_inflight <= 1'b1;
                pf_redirect_queued <= 1'b1;
                pf_req_toggle <= pf_ack_toggle;
            end
            spec_pend <= 1'b0;
            if (spec_adopt || (spec_inflight && pf_ack_edge))
                spec_inflight <= 1'b0;
            spec_adopted_r <= spec_adopt;
            if (spec_data_now) begin
                // Ack in the flush cycle itself: seed consumed it; buffer too.
                // The branch-target buffer is a cache: never retain a line
                // from a non-cacheable fetch.
                spec_line  <= pf_rdata;
                spec_valid <= !pf_nocache;
            end
            spec_poison <= 1'b0;
            // A flush that bypasses an in-flight spec fetch invalidates its
            // context (CR3/CS may change before the late response lands).
            if (spec_inflight && !spec_adopt && !pf_ack_edge)
                spec_poison <= 1'b1;
            // synthesis translate_off
            if (TRACE_FLUSH_EN)
                $display("BIU FLUSH: pf_flush_addr=%08x word_start=%d byte_offset=%d",
                         pf_flush_addr, pf_flush_addr[3:2], pf_flush_addr[1:0]);
            // synthesis translate_on
        end

        if (pf_ack_edge && !q_flush) begin
            spec_adopted_r <= 1'b0;
            if (spec_inflight) begin
                // Speculative target line: buffer it; a fault only drops the
                // buffer (never suspends - the fetch may be down a wrong path).
                spec_inflight <= 1'b0;
                spec_line <= pf_rdata;
                spec_valid <= !pf_fault && !pf_refused && !spec_poison && !pf_nocache;
            end else if (spec_adopted_r && !pf_drop_inflight && !pf_fault && !pf_refused) begin
                // Adopted post-flush fill arriving: it fills the queue as
                // usual (fill_commit), AND populates the buffer for the
                // loop's next iteration (re-own via spec_match_now, no
                // refetch).  Faults/drops fall through to the branch below.
                spec_line  <= pf_rdata;
                spec_valid <= !spec_poison && !pf_nocache;
                pf_fetch_addr <= pf_fetch_addr + 32'd16;
                pf_fetch_word_start <= 2'd0;
            end else if (pf_drop_inflight || pf_fault || pf_refused) begin
                // A refused adopted fetch (pf_refused) leaves pf_fetch_addr at
                // the target line: pf_can_fetch re-requests it as a real fetch.
                pf_drop_inflight <= 1'b0;
                pf_redirect_queued <= 1'b0;
                if (pf_fault && !pf_drop_inflight) begin
                    pf_suspended <= 1'b1;
                    pf_fault_code_r <= pf_fault_code;
                    pf_fault_addr_r <= pf_fault_addr;
                end
            end else begin
                pf_fetch_addr <= pf_fetch_addr + 32'd16;
                pf_fetch_word_start <= 2'd0;
            end
        end

        if (pf_suspended && !pf_fault_reported && fetch_blocked && !q_flush &&
            !limit_reached) begin
            ifetch_fault <= 1'b1;
            pf_fault_reported <= 1'b1;
        end
        if (limit_reached && !pf_limit_reported && fetch_blocked && !q_flush) begin
            ifetch_limit_fault <= 1'b1;
            pf_limit_reported <= 1'b1;
        end

        if (spec_req && !q_flush) begin
            if (spec_match_now || spec_inflight_match) begin
                // Buffered or in-flight line holds this target: re-own, no refetch.
                spec_off <= spec_linear[3:0];
            end else if (spec_b_match) begin
                // The victim holds this target: swap the two entries.
                spec_off <= spec_linear[3:0];
                spec_addr <= spec_b_addr;
                spec_line <= spec_b_line;
                spec_valid <= 1'b1;
                spec_poison <= 1'b0;
                spec_b_addr <= spec_addr;
                spec_b_line <= spec_line;
                spec_b_valid <= spec_valid && !spec_poison;
            end else begin
                // Keep the line being replaced as the victim - unless a store
                // or a global kill lands on it in this same cycle: spec_kill
                // below clears only the ACTIVE slot, so a victim copied here
                // would keep the pre-store bytes and a later swap would run
                // them (tests/programs/smc_spec_demote_rm).
                if (spec_valid && !spec_poison && !spec_inflight) begin
                    spec_b_addr <= spec_addr;
                    spec_b_line <= spec_line;
                    spec_b_valid <= !spec_kill;
                end
                spec_pend <= 1'b1;
                spec_pend_addr <= spec_linear;
                spec_valid <= 1'b0;
                if (spec_inflight)
                    spec_poison <= 1'b1;
            end
        end

        // Store commit / external snoop: the buffered (or in-flight) target
        // line may be stale; poison it (386 jump-must-refetch semantics).
        // A pending (not yet launched) request will fetch fresh data.
        if (spec_global_kill || spec_b_store_hit)
            spec_b_valid <= 1'b0;
        if (spec_kill) begin
            spec_valid <= 1'b0;
            spec_adopted_r <= 1'b0;
            if (spec_inflight)
                spec_poison <= 1'b1;
        end

        if (spec_launch) begin
            automatic logic [31:0] tgt = (spec_req && !q_flush) ? spec_linear : spec_pend_addr;
            pf_req_toggle <= ~pf_req_toggle;
            pf_linear_addr <= {tgt[31:4], 4'b0000};
            spec_addr      <= tgt[31:4];
            spec_off       <= tgt[3:0];
            spec_valid <= 1'b0;
            // A store committing in this very cycle may still race the icache
            // read: keep the poison.
            spec_poison <= spec_kill;
            spec_inflight <= 1'b1;
            spec_pend <= 1'b0;
        end else if (pf_can_fetch_after_flush || pf_can_fetch) begin
            pf_req_toggle <= ~pf_req_toggle;
            if (pf_can_fetch_after_flush) begin
                // On a spec-hit flush the target line is already in the queue:
                // the post-flush fetch continues at the NEXT line.
                pf_linear_addr <= {pf_flush_addr[31:4], 4'b0000} +
                                  (spec_flush_hit ? 32'd16 : 32'd0);
            end else if (good_ack) begin
                pf_linear_addr <= pf_fetch_addr + 32'd16;
            end else begin
                pf_linear_addr <= {pf_fetch_addr[31:4], 4'b0000};
                if (q_empty && pf_fetch_addr[3:0] != 4'h0) begin
                    pf_fetch_word_start <= pf_fetch_addr[3:2];
                    pf_fetch_addr <= {pf_fetch_addr[31:4], 4'b0000};
                end
            end
        end
    end
end

endmodule

//
// L1 Instruction Cache
// Read-only physically indexed, physically tagged instruction cache
//
`include "z486_platform.svh"
module l1_icache #(
    // 8KB icache (128 sets x 4 ways x 16 B); use SET_BITS=8 for 16KB.
    parameter integer SET_BITS = 7
) (
    input         clk,
    input         reset,

    // CPU side — physical read request/response.
    input  [31:0] cpu_addr,
    output [127:0] cpu_line,
    input         cpu_valid,
    output        cpu_ready,
    output        cpu_resp_valid,

    // Memory side.
    output [31:0] mem_addr,
    input  [31:0] mem_dout,
    input [127:0] mem_line_dout,
    output  [3:0] mem_be,
    output  [7:0] mem_burstcount,
    input         mem_busy,
    output        mem_valid,
    input         mem_ready,
    input         mem_resp_valid,
    input         mem_line_resp_valid,

    // CPU stores patch matching cached words; external DMA writes only
    // invalidate. Separate addresses keep DMA out of the hit-response cone.
    input  [31:0] patch_addr,
    input  [31:0] patch_data,
    input   [3:0] patch_be,
    input         patch_valid,
    input  [31:0] invalidate_addr,
    input         invalidate_valid,
    // A CPU store patch exists but cannot be presented on patch_* because an
    // invalidate owns the port (its address is not visible here): every
    // lookup is treated as a conflict until it is delivered.
    input         patch_held,

    // Native whole-L1 invalidate.  flush_req is a one-cycle request (a held
    // level is also accepted: one walk per release); flush_busy is high for the
    // walk and flush_done pulses once when it completes.
    input         flush_req,
    output        flush_busy,
    output        flush_done,

    input         cache_enable,
    // NO_ALLOC fill: answer the fetch but do not install a line, so an
    // unmapped/uncached window never evicts or aliases a cacheable line.
    input         cpu_no_alloc,
    // 486 non-cacheable fetch (PTE.PCD or CR0.CD): a valid line still
    // answers, but a miss is not allocated.
    input         cpu_no_fill
);

localparam integer WORD_OFFSET_BITS = 2;
localparam integer BYTE_OFFSET_BITS = 2;
localparam integer LINE_OFFSET_BITS = WORD_OFFSET_BITS + BYTE_OFFSET_BITS;
localparam integer NUM_SETS = 1 << SET_BITS;
localparam integer PHYS_ADDR_BITS = `Z486_L1_PHYS_ADDR_BITS; // default tag reach: 128 MiB
localparam integer TAG_BITS = PHYS_ADDR_BITS - LINE_OFFSET_BITS - SET_BITS;
localparam integer SET_LSB = LINE_OFFSET_BITS;
localparam integer SET_MSB = SET_LSB + SET_BITS - 1;
localparam integer TAG_LSB = SET_MSB + 1;
localparam integer TAG_MSB = PHYS_ADDR_BITS - 1;
localparam integer TAG_RAM_BITS = (TAG_BITS < 16) ? 16 : (TAG_BITS + 1);
localparam integer TAG_VALID_BIT = TAG_BITS;
localparam [SET_BITS-1:0] LAST_SET = SET_BITS'(NUM_SETS - 1);
localparam integer PATCHQ_DEPTH = 3;
localparam integer PATCHQ_IDX_BITS = 2;
localparam [PATCHQ_IDX_BITS-1:0] PATCHQ_LAST_IDX = 2'd2;
localparam integer SET_DW_LSB = SET_LSB - BYTE_OFFSET_BITS;
localparam integer SET_DW_MSB = SET_MSB - BYTE_OFFSET_BITS;
localparam integer TAG_DW_LSB = TAG_LSB - BYTE_OFFSET_BITS;
localparam integer TAG_DW_MSB = TAG_MSB - BYTE_OFFSET_BITS;

// synthesis translate_off
initial begin
    if (SET_BITS < 1 || SET_BITS > 8 || PHYS_ADDR_BITS > 32 ||
        PHYS_ADDR_BITS <= LINE_OFFSET_BITS + SET_BITS)
        $fatal(1, "Invalid L1 I-cache index/tag width (VIPT indexes must stay in page offset)");
end
// synthesis translate_on

wire [TAG_BITS-1:0] cpu_tag = cpu_addr[TAG_MSB:TAG_LSB];
wire [SET_BITS-1:0] cpu_set = cpu_addr[SET_MSB:SET_LSB];
wire [TAG_BITS-1:0] patch_tag = patch_addr[TAG_MSB:TAG_LSB];
wire [SET_BITS-1:0] patch_set = patch_addr[SET_MSB:SET_LSB];
wire [WORD_OFFSET_BITS-1:0] patch_word = patch_addr[LINE_OFFSET_BITS-1:BYTE_OFFSET_BITS];
// The prefetcher consumes whole 16-byte lines, so an uncacheable fetch reads
// the full line like a fill and delivers it without installing it.
wire cpu_uncacheable = !cache_enable;
reg  fill_uncached_r;                  // the current fill must not install

`Z486_BLOCK_RAM reg [TAG_RAM_BITS-1:0] tag_way0 [0:NUM_SETS-1];
`Z486_BLOCK_RAM reg [TAG_RAM_BITS-1:0] tag_way1 [0:NUM_SETS-1];
`Z486_BLOCK_RAM reg [TAG_RAM_BITS-1:0] tag_way2 [0:NUM_SETS-1];
`Z486_BLOCK_RAM reg [TAG_RAM_BITS-1:0] tag_way3 [0:NUM_SETS-1];
reg [2:0] plru_set [0:NUM_SETS-1];

`Z486_BLOCK_RAM reg [127:0] data_way0 [0:NUM_SETS-1];
`Z486_BLOCK_RAM reg [127:0] data_way1 [0:NUM_SETS-1];
`Z486_BLOCK_RAM reg [127:0] data_way2 [0:NUM_SETS-1];
`Z486_BLOCK_RAM reg [127:0] data_way3 [0:NUM_SETS-1];

// Register each complete tag word as one RAM read.  Keeping the valid bit in
// the otherwise unused tag-RAM bit removes four 256-bit register arrays while
// preserving the existing synchronous CPU lookup boundary.
reg [TAG_RAM_BITS-1:0] rd_tag_entry0_r, rd_tag_entry1_r;
reg [TAG_RAM_BITS-1:0] rd_tag_entry2_r, rd_tag_entry3_r;
reg [TAG_RAM_BITS-1:0] snoop_tag_entry0_r, snoop_tag_entry1_r;
reg [TAG_RAM_BITS-1:0] snoop_tag_entry2_r, snoop_tag_entry3_r;
wire [TAG_BITS-1:0] rd_tag0_r = rd_tag_entry0_r[TAG_BITS-1:0];
wire [TAG_BITS-1:0] rd_tag1_r = rd_tag_entry1_r[TAG_BITS-1:0];
wire [TAG_BITS-1:0] rd_tag2_r = rd_tag_entry2_r[TAG_BITS-1:0];
wire [TAG_BITS-1:0] rd_tag3_r = rd_tag_entry3_r[TAG_BITS-1:0];
wire rd_valid0_r = rd_tag_entry0_r[TAG_VALID_BIT];
wire rd_valid1_r = rd_tag_entry1_r[TAG_VALID_BIT];
wire rd_valid2_r = rd_tag_entry2_r[TAG_VALID_BIT];
wire rd_valid3_r = rd_tag_entry3_r[TAG_VALID_BIT];
reg [127:0] rd_line0_r, rd_line1_r, rd_line2_r, rd_line3_r;
reg [2:0] rd_plru_r;

reg        req_valid_r;
reg [31:0] req_addr_r;
reg        req_uncacheable_r;
reg        req_no_alloc_r;
reg        req_no_fill_r;
reg [TAG_BITS-1:0] req_tag_r;
reg        req_snoop_conflict_r;   // the request's tag read raced a snoop's tag clear
reg [SET_BITS-1:0] req_set_r;

reg        mem_valid_r;
reg [31:0] mem_addr_r;
reg  [7:0] mem_burstcount_r;

assign mem_valid = mem_valid_r;
assign mem_addr = mem_addr_r;
assign mem_be = 4'hF;
assign mem_burstcount = mem_burstcount_r;

localparam [2:0] S_RESET_INIT  = 3'd0;
localparam [2:0] S_IDLE        = 3'd1;
localparam [2:0] S_LOOKUP      = 3'd2;
localparam [2:0] S_FILL        = 3'd3;

reg [2:0] state;
reg [SET_BITS-1:0] init_set;
reg [TAG_BITS-1:0] snoop_tag_r;
reg [SET_BITS-1:0] snoop_set_r;
reg [WORD_OFFSET_BITS-1:0] snoop_word_r;
reg [29:0] snoop_addr_dw_r;
reg [31:0] snoop_data_r;
reg [3:0] snoop_be_r;
reg snoop_patch_r;
reg snoop_valid_r;
reg [29:0] patchq_addr [0:PATCHQ_DEPTH-1];
reg [31:0] patchq_data [0:PATCHQ_DEPTH-1];
reg  [3:0] patchq_be   [0:PATCHQ_DEPTH-1];
reg        patchq_valid[0:PATCHQ_DEPTH-1];
reg [PATCHQ_IDX_BITS-1:0] patchq_head;
reg [WORD_OFFSET_BITS-1:0] fill_count;
reg [SET_BITS-1:0] fill_set;
reg [TAG_BITS-1:0] fill_tag;
reg [1:0] fill_way;
reg [127:0] fill_line;
reg [2:0] fill_plru_r;
reg fill_requested;
// A snoop clear owns the shared way write port for its cycle, so the fill
// install waits (fill_tag_wait_r) rather than being dropped as a miss.
reg fill_tag_wait_r;
// A snoop that cleared this fill's line, held for the rest of the fill so the
// tag write cannot reinstate it (the live and registered snoops alone miss it).
reg fill_line_snooped_r;

// Whole-L1 invalidate state; see l1_cache.sv for the contract.  The request is
// consumed once (a held level is re-armed only after it is released), and
// flush_block holds new fetches off from the cycle it is observed.
//
// The sweep is an INDEPENDENT walk over the sets, not a service of the
// fill/lookup FSM: a fill in flight can be blocked indefinitely behind an
// unrelated bus transaction, and the platform that asked for the flush may be
// holding that very transaction until the flush completes.  Waiting for the
// cache to fall idle would deadlock the machine, so instead any fill in flight
// is marked (fill_killed_r) and cannot install after the sweep; the sweep then
// runs concurrently with it and always completes in SETS+2 cycles.  The sweep
// clears only the tag/valid arrays: the PLRU is replacement state, and giving
// it a second write address would cost the block-RAM inference for plru_set.
reg  flush_req_seen_r;
reg  flush_pending_r;
reg  flush_busy_r;
reg  flush_done_r;
reg  [SET_BITS-1:0] flush_set_r;
reg  fill_killed_r;
wire flush_req_new = flush_req & ~flush_req_seen_r;
wire flush_block = flush_req_new | flush_pending_r | flush_busy_r;

assign flush_busy = flush_busy_r;
assign flush_done = flush_done_r;

reg resp_valid_r;
reg ready_r;

assign cpu_ready = ready_r && !flush_block;

function automatic [1:0] way_encode(input [3:0] hit_vec);
begin
    way_encode = hit_vec[0] ? 2'd0 :
                 hit_vec[1] ? 2'd1 :
                 hit_vec[2] ? 2'd2 : 2'd3;
end
endfunction

function automatic [127:0] way_line_mux(
    input [1:0] way,
    input [127:0] data0,
    input [127:0] data1,
    input [127:0] data2,
    input [127:0] data3
);
begin
    case (way)
        2'd0: way_line_mux = data0;
        2'd1: way_line_mux = data1;
        2'd2: way_line_mux = data2;
        default: way_line_mux = data3;
    endcase
end
endfunction

// select_word removed: the single-word read path is dead (superseded by the
// 128-bit cpu_line output).

function automatic [127:0] patch_line_word(input [127:0] line, input [1:0] word, input [31:0] data);
begin
    patch_line_word = line;
    patch_line_word[{word, 5'b0} +: 32] = data;
end
endfunction

function automatic [31:0] be_mask(input [3:0] be);
begin
    be_mask = {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
end
endfunction

function automatic [31:0] merge32(input [31:0] old_data, input [31:0] new_data, input [3:0] be);
    automatic reg [31:0] mask;
begin
    mask = be_mask(be);
    merge32 = (old_data & ~mask) | (new_data & mask);
end
endfunction

function automatic [127:0] patch_line_word_be(
    input [127:0] line,
    input [1:0] word,
    input [31:0] data,
    input [3:0] be
);
begin
    patch_line_word_be = line;
    patch_line_word_be[{word, 5'b0} +: 32] =
        merge32(line[{word, 5'b0} +: 32], data, be);
end
endfunction

function automatic [PATCHQ_IDX_BITS-1:0] patchq_next_idx(input [PATCHQ_IDX_BITS-1:0] idx);
begin
    patchq_next_idx = (idx == PATCHQ_LAST_IDX) ? {PATCHQ_IDX_BITS{1'b0}} : (idx + 1'b1);
end
endfunction

function automatic logic line_match_dw(
    input [29:0] addr_dw,
    input [TAG_BITS-1:0] tag,
    input [SET_BITS-1:0] set
);
begin
    line_match_dw = (addr_dw[TAG_DW_MSB:TAG_DW_LSB] == tag) &&
                    (addr_dw[SET_DW_MSB:SET_DW_LSB] == set);
end
endfunction

function automatic logic word_match_dw(
    input [29:0] addr_dw,
    input [TAG_BITS-1:0] tag,
    input [SET_BITS-1:0] set,
    input [WORD_OFFSET_BITS-1:0] word
);
begin
    word_match_dw = line_match_dw(addr_dw, tag, set) &&
                    (addr_dw[WORD_OFFSET_BITS-1:0] == word);
end
endfunction

function automatic [2:0] plru_update(input [2:0] plru, input [1:0] way);
begin
    case (way)
        2'd0: plru_update = {plru[2], 1'b1, 1'b1};
        2'd1: plru_update = {plru[2], 1'b0, 1'b1};
        2'd2: plru_update = {1'b1, plru[1], 1'b0};
        default: plru_update = {1'b0, plru[1], 1'b0};
    endcase
end
endfunction

function automatic [1:0] plru_victim(input [2:0] plru);
begin
    if (!plru[0])
        plru_victim = plru[1] ? 2'd1 : 2'd0;
    else
        plru_victim = plru[2] ? 2'd3 : 2'd2;
end
endfunction

wire [3:0] lookup_hit_vec = {
    rd_valid3_r && (rd_tag3_r == req_tag_r),
    rd_valid2_r && (rd_tag2_r == req_tag_r),
    rd_valid1_r && (rd_tag1_r == req_tag_r),
    rd_valid0_r && (rd_tag0_r == req_tag_r)
};
wire lookup_hit = |lookup_hit_vec;
wire [1:0] lookup_way = way_encode(lookup_hit_vec);
wire [127:0] lookup_way_line = way_line_mux(lookup_way, rd_line0_r, rd_line1_r, rd_line2_r, rd_line3_r);
// A CPU store can arrive after the synchronous RAM lookup captured a valid
// line, so reject that live collision. External DMA invalidation is held and
// reaches the registered snoop before the pending DMA write can commit; keeping
// it out of this hit cone avoids a system-to-prefetch timing path.
wire lookup_snoop_conflict = req_snoop_conflict_r ||
    (snoop_valid_r && (snoop_tag_r == req_tag_r) && (snoop_set_r == req_set_r)) ||
    (patch_valid && (patch_tag == req_tag_r) && (patch_set == req_set_r)) ||
    patch_held;
wire lookup_hit_usable = lookup_hit && !lookup_snoop_conflict;
wire can_accept_cpu = (state == S_IDLE) && !reset;
wire accept_cpu = cpu_valid && cpu_ready && can_accept_cpu;
// The sweep starts one cycle after the request is observed, when ready_r has
// already been forced low so no fetch can be accepted in the same cycle.  It
// waits only for the internal reset walk, which never touches the bus.
wire flush_launch = (flush_req_new | flush_pending_r) &&
                    (state != S_RESET_INIT) && !reset;
wire lookup_read_hit_now = (state == S_LOOKUP) && req_valid_r &&
                           !req_uncacheable_r && !req_no_alloc_r &&
                           lookup_hit_usable;
logic [PATCHQ_DEPTH-1:0] patchq_snoop_match;
logic patchq_snoop_hit;
logic [31:0] fill_word_next;
logic [127:0] fill_line_base;
logic [127:0] fill_line_next;
logic [127:0] wide_line_next;

always_comb begin
    patchq_snoop_match = {PATCHQ_DEPTH{1'b0}};
    for (int p = 0; p < PATCHQ_DEPTH; p++)
        patchq_snoop_match[p] = patchq_valid[p] && !flush_launch &&
                                patchq_addr[p] == snoop_addr_dw_r;
    patchq_snoop_hit = |patchq_snoop_match;
end

always_comb begin
    fill_word_next = mem_dout;
    for (int p = 0; p < PATCHQ_DEPTH; p++) begin
        if (patchq_valid[p] && word_match_dw(patchq_addr[p], fill_tag, fill_set, fill_count))
            fill_word_next = merge32(fill_word_next, patchq_data[p], patchq_be[p]);
    end
    if (snoop_valid_r && snoop_patch_r && word_match_dw(snoop_addr_dw_r, fill_tag, fill_set, fill_count))
        fill_word_next = merge32(fill_word_next, snoop_data_r, snoop_be_r);
    if (patch_valid && word_match_dw(patch_addr[31:2], fill_tag, fill_set, fill_count))
        fill_word_next = merge32(fill_word_next, patch_data, patch_be);

    fill_line_base = fill_line;
    if (snoop_valid_r && snoop_patch_r && line_match_dw(snoop_addr_dw_r, fill_tag, fill_set))
        fill_line_base = patch_line_word_be(fill_line_base, snoop_word_r, snoop_data_r, snoop_be_r);
    if (patch_valid && line_match_dw(patch_addr[31:2], fill_tag, fill_set))
        fill_line_base = patch_line_word_be(fill_line_base, patch_word, patch_data, patch_be);
    fill_line_next = patch_line_word(fill_line_base, fill_count, fill_word_next);

    // A native DDR backend returns the complete line in one cycle. Apply the
    // same pending self-modifying-code patches that the legacy DWORD path
    // applies one beat at a time.
    wide_line_next = mem_line_dout;
    for (int p = 0; p < PATCHQ_DEPTH; p++) begin
        if (patchq_valid[p] && line_match_dw(patchq_addr[p], fill_tag, fill_set))
            wide_line_next = patch_line_word_be(wide_line_next,
                patchq_addr[p][WORD_OFFSET_BITS-1:0], patchq_data[p], patchq_be[p]);
    end
    if (snoop_valid_r && snoop_patch_r &&
        line_match_dw(snoop_addr_dw_r, fill_tag, fill_set))
        wide_line_next = patch_line_word_be(wide_line_next, snoop_word_r,
                                             snoop_data_r, snoop_be_r);
    if (patch_valid && line_match_dw(patch_addr[31:2], fill_tag, fill_set))
        wide_line_next = patch_line_word_be(wide_line_next, patch_word,
                                             patch_data, patch_be);
end

// A fill's response (resp_valid_r, the cycle after its last beat) returns
// fill_line: the response edge wrote it with the same value a separate line_r
// copy used to take, and nothing writes fill_line again before a new miss
// enters S_FILL. Every reader samples cpu_line only with cpu_resp_valid
// (paging_unit's pf_rdata: "the prefetcher samples pf_rdata only on an ack
// edge", which is a completion cycle for every ack that carries data).
// The line select is the registered resp_valid_r instead of lookup_read_hit_now
// (a tag compare, the snoop conflict and the state: fo ~150 in front of 128
// line bits, the fitted req_addr_r -> lookup_read_hit_now -> cpu_line ->
// prefetch queue -> k1q_r / entry-ROM path).  resp_valid_r is set only on an
// S_FILL edge (to S_IDLE or held in S_FILL) and cleared on every other, so it
// is never set in S_LOOKUP: whenever cpu_resp_valid holds, this select picks
// the same line as lookup_read_hit_now would (fused below), and cpu_line is
// read only with cpu_resp_valid (z486.sv fuses the prefetcher's consumers).
assign cpu_line = resp_valid_r ? fill_line : lookup_way_line;
assign cpu_resp_valid = lookup_read_hit_now || resp_valid_r;
// synthesis translate_off
always @(posedge clk)
    if (!reset && resp_valid_r && (state == S_LOOKUP))
        $fatal(1, "l1_icache: a fill response in S_LOOKUP (cpu_line select contract)");
// synthesis translate_on

wire tag_reset_write = (state == S_RESET_INIT);
// The flush sweep yields to a registered snoop, whose clear writes a different
// index through the same way RAMs: it re-issues that set one cycle later.
wire flush_sweep_w = flush_busy_r && !snoop_valid_r;
// The three tag-clear owners (the internal reset walk, a tag-matched snoop and
// the flush sweep) share one address expression, so a way RAM needs only a
// fill-vs-clear address select instead of one mux input per owner.
wire [SET_BITS-1:0] tag_clear_set_now = tag_reset_write ? init_set :
                                        flush_sweep_w ? flush_set_r : snoop_set_r;
wire fill_last_beat = mem_line_resp_valid ||
                      (mem_resp_valid &&
                       fill_count == {WORD_OFFSET_BITS{1'b1}});
// A snoop clear owns the shared way write port this cycle, so the install is
// deferred (fill_tag_wait_r) rather than racing the clear; and a deferred
// install must not start while the snoop is still live.
wire tag_fill_write = (state == S_FILL) && !snoop_valid_r &&
                      (fill_tag_wait_r || fill_last_beat);
wire [TAG_RAM_BITS-1:0] tag_fill_entry =
    {{(TAG_RAM_BITS-TAG_BITS-1){1'b0}}, 1'b1, fill_tag};
wire snoop_capture = invalidate_valid || patch_valid;
wire [SET_BITS-1:0] snoop_capture_set = invalidate_valid ?
                                              invalidate_addr[SET_MSB:SET_LSB] :
                                              patch_set;
wire [TAG_BITS-1:0] snoop_capture_tag = invalidate_valid ?
                                              invalidate_addr[TAG_MSB:TAG_LSB] :
                                              patch_tag;
wire live_snoop_fill_conflict = snoop_capture &&
                                (snoop_capture_set == fill_set) &&
                                (snoop_capture_tag == fill_tag);
// The tag read is held after the event. Only the registered event cycle may
// clear a way, or a later refill of that way would be cleared again.
wire tag_snoop_match0 = snoop_valid_r && snoop_tag_entry0_r[TAG_VALID_BIT] &&
                        (snoop_tag_entry0_r[TAG_BITS-1:0] == snoop_tag_r);
wire tag_snoop_match1 = snoop_valid_r && snoop_tag_entry1_r[TAG_VALID_BIT] &&
                        (snoop_tag_entry1_r[TAG_BITS-1:0] == snoop_tag_r);
wire tag_snoop_match2 = snoop_valid_r && snoop_tag_entry2_r[TAG_VALID_BIT] &&
                        (snoop_tag_entry2_r[TAG_BITS-1:0] == snoop_tag_r);
wire tag_snoop_match3 = snoop_valid_r && snoop_tag_entry3_r[TAG_VALID_BIT] &&
                        (snoop_tag_entry3_r[TAG_BITS-1:0] == snoop_tag_r);
wire registered_snoop_fill_conflict = snoop_valid_r &&
                                      (snoop_set_r == fill_set) &&
                                      (snoop_tag_r == fill_tag);
// A snoop that clears the line this fill is installing.  A tag-matched clear
// is the only kind here (there is no set-wide external invalidate).
wire snoop_clears_fill_line = registered_snoop_fill_conflict;
// A snoop owns the tag port while the completed fill waits. Data and tag
// install together after the event; a snoop of the fill's own line instead
// leaves it uncached for the remainder of that fill.  A fill for a disabled
// cache (fill_uncached_r) or a no-allocate fetch delivers without installing.
wire fill_install_allowed = !fill_uncached_r && !req_no_alloc_r && !req_no_fill_r &&
                            !live_snoop_fill_conflict &&
                            !registered_snoop_fill_conflict &&
                            !fill_line_snooped_r && !fill_killed_r;
wire data_fill_write = tag_fill_write && fill_install_allowed;
// A deferred install writes the line gathered at the last beat, not the stale
// bus inputs still present on the following cycle.
logic [127:0] fill_install_line;
assign fill_install_line = fill_tag_wait_r ? fill_line :
                           mem_line_resp_valid ? wide_line_next : fill_line_next;


always_ff @(posedge clk) begin
    if (accept_cpu) begin
        rd_tag_entry0_r <= tag_way0[cpu_set];
        rd_tag_entry1_r <= tag_way1[cpu_set];
        rd_tag_entry2_r <= tag_way2[cpu_set];
        rd_tag_entry3_r <= tag_way3[cpu_set];
        rd_line0_r <= data_way0[cpu_set];
        rd_line1_r <= data_way1[cpu_set];
        rd_line2_r <= data_way2[cpu_set];
        rd_line3_r <= data_way3[cpu_set];
        rd_plru_r <= plru_set[cpu_set];
    end

    // Keep each data RAM's synchronous read and write in the same process.
    // Vivado otherwise implements the 4 x 256 x 128-bit instruction cache as
    // flip-flops instead of inferring simple dual-port block RAMs.
    if (data_fill_write) begin
        case (fill_way)
            2'd0: data_way0[fill_set] <= fill_install_line;
            2'd1: data_way1[fill_set] <= fill_install_line;
            2'd2: data_way2[fill_set] <= fill_install_line;
            default: data_way3[fill_set] <= fill_install_line;
        endcase
    end

    // The second synchronous tag read is launched from the live snoop input
    // while its address and payload are registered.  Its result is therefore
    // aligned with snoop_valid_r on the following lookup cycle, when the
    // existing conflict mask already prevents a stale CPU hit.
    if (snoop_capture) begin
        snoop_tag_entry0_r <= tag_way0[snoop_capture_set];
        snoop_tag_entry1_r <= tag_way1[snoop_capture_set];
        snoop_tag_entry2_r <= tag_way2[snoop_capture_set];
        snoop_tag_entry3_r <= tag_way3[snoop_capture_set];
    end

    // One write process per tag array preserves M10K inference. A fill waits
    // out the registered snoop, including a same-way/different-set collision.
    if (tag_reset_write) begin
        tag_way0[init_set] <= '0;
        tag_way1[init_set] <= '0;
        tag_way2[init_set] <= '0;
        tag_way3[init_set] <= '0;
    end else begin
        if (tag_fill_write && fill_install_allowed && (fill_way == 2'd0))
            tag_way0[fill_set] <= tag_fill_entry;
        else if (flush_sweep_w || tag_snoop_match0)
            tag_way0[tag_clear_set_now] <= '0;
        if (tag_fill_write && fill_install_allowed && (fill_way == 2'd1))
            tag_way1[fill_set] <= tag_fill_entry;
        else if (flush_sweep_w || tag_snoop_match1)
            tag_way1[tag_clear_set_now] <= '0;
        if (tag_fill_write && fill_install_allowed && (fill_way == 2'd2))
            tag_way2[fill_set] <= tag_fill_entry;
        else if (flush_sweep_w || tag_snoop_match2)
            tag_way2[tag_clear_set_now] <= '0;
        if (tag_fill_write && fill_install_allowed && (fill_way == 2'd3))
            tag_way3[fill_set] <= tag_fill_entry;
        else if (flush_sweep_w || tag_snoop_match3)
            tag_way3[tag_clear_set_now] <= '0;
    end
end

always_ff @(posedge clk) begin
    if (reset) begin
        state <= S_RESET_INIT;
        init_set <= {SET_BITS{1'b0}};
        req_valid_r <= 1'b0;
        req_snoop_conflict_r <= 1'b0;
        fill_uncached_r <= 1'b0;
        ready_r <= 1'b0;
        resp_valid_r <= 1'b0;
        mem_valid_r <= 1'b0;
        mem_addr_r <= 32'h0;
        mem_burstcount_r <= 8'h0;
        fill_line <= 128'h0;
        fill_requested <= 1'b0;
        fill_tag_wait_r <= 1'b0;
        fill_line_snooped_r <= 1'b0;
        fill_killed_r <= 1'b0;
        snoop_tag_r <= {TAG_BITS{1'b0}};
        snoop_set_r <= {SET_BITS{1'b0}};
        snoop_word_r <= {WORD_OFFSET_BITS{1'b0}};
        snoop_addr_dw_r <= 30'h0;
        snoop_data_r <= 32'h0;
        snoop_be_r <= 4'h0;
        snoop_patch_r <= 1'b0;
        snoop_valid_r <= 1'b0;
        patchq_head <= {PATCHQ_IDX_BITS{1'b0}};
        for (integer p = 0; p < PATCHQ_DEPTH; p = p + 1)
            patchq_valid[p] <= 1'b0;
        flush_req_seen_r <= 1'b0;
        flush_pending_r <= 1'b0;
    end else begin
        ready_r <= (state == S_IDLE) && !flush_block;
        resp_valid_r <= 1'b0;
        flush_req_seen_r <= flush_req;
        if (flush_launch)
            flush_pending_r <= 1'b0;
        else if (flush_req_new)
            flush_pending_r <= 1'b1;
        snoop_valid_r <= invalidate_valid || patch_valid;
        if (invalidate_valid) begin
            snoop_tag_r <= invalidate_addr[TAG_MSB:TAG_LSB];
            snoop_set_r <= invalidate_addr[SET_MSB:SET_LSB];
            snoop_word_r <= invalidate_addr[LINE_OFFSET_BITS-1:BYTE_OFFSET_BITS];
            snoop_addr_dw_r <= invalidate_addr[31:2];
            snoop_data_r <= 32'h0;
            snoop_be_r <= 4'h0;
            snoop_patch_r <= 1'b0;
        end else if (patch_valid) begin
            snoop_tag_r <= patch_tag;
            snoop_set_r <= patch_set;
            snoop_word_r <= patch_word;
            snoop_addr_dw_r <= patch_addr[31:2];
            snoop_data_r <= patch_data;
            snoop_be_r <= patch_be;
            snoop_patch_r <= 1'b1;
        end

        if (mem_valid_r && mem_ready)
            mem_valid_r <= 1'b0;

        // A snoop that clears the line being filled is remembered for the rest
        // of the fill, so the deferred install cannot reinstate it.  A fill in
        // flight when a flush is armed is remembered the same way: the sweep
        // runs concurrently with it, so the install must be suppressed rather
        // than waited out.  Both marks stick until the fill ends.
        if (state != S_FILL) begin
            fill_line_snooped_r <= 1'b0;
            fill_killed_r <= 1'b0;
        end else begin
            if (snoop_clears_fill_line)
                fill_line_snooped_r <= 1'b1;
            if (flush_req_new || flush_pending_r || flush_busy_r)
                fill_killed_r <= 1'b1;
        end

        // The patch queue covers stores that a fill in flight read memory
        // ahead of.  A whole-L1 flush is launched only once the posted stores
        // have drained (cache_unit's CF_DRAIN) and it cancels every fill in
        // flight, so no older entry can still be needed - and keeping one
        // would merge stale CPU bytes over memory written by DMA before the
        // flush.  Retire them at the sweep start; a patch registered in this
        // very cycle is a younger store and is allocated fresh below.
        if (flush_launch)
            for (int p = 0; p < PATCHQ_DEPTH; p++)
                patchq_valid[p] <= 1'b0;

        if (snoop_valid_r) begin
            // CPU stores can race ahead of an instruction-cache line fill.
            // Keep the recent data-bearing snoops so a later fill of the same
            // physical line returns self-modified code after a branch flush.
            if (snoop_patch_r) begin
                for (int p = 0; p < PATCHQ_DEPTH; p++) begin
                    if (patchq_snoop_match[p]) begin
                        patchq_data[p] <= merge32(patchq_data[p], snoop_data_r, snoop_be_r);
                        patchq_be[p] <= patchq_be[p] | snoop_be_r;
                    end
                end
                if (!patchq_snoop_hit) begin
                    patchq_valid[patchq_head] <= 1'b1;
                    patchq_addr[patchq_head] <= snoop_addr_dw_r;
                    patchq_data[patchq_head] <= snoop_data_r;
                    patchq_be[patchq_head] <= snoop_be_r;
                    patchq_head <= patchq_next_idx(patchq_head);
                end
            end else begin
                for (int p = 0; p < PATCHQ_DEPTH; p++) begin
                    if (patchq_valid[p] && line_match_dw(patchq_addr[p], snoop_tag_r, snoop_set_r))
                        patchq_valid[p] <= 1'b0;
                end
            end

        end

        case (state)
            S_RESET_INIT: begin
                plru_set[init_set] <= 3'b000;
                if (init_set == LAST_SET) begin
                    state <= S_IDLE;
                    ready_r <= 1'b1;
                end else begin
                    init_set <= init_set + 1'b1;
                end
            end

            S_IDLE: begin
                if (accept_cpu) begin
                    ready_r <= 1'b0;
                    req_valid_r <= 1'b1;
                    req_addr_r <= cpu_addr;
                    req_uncacheable_r <= cpu_uncacheable;
                    req_no_alloc_r <= cpu_no_alloc;
                    req_no_fill_r <= cpu_no_fill;
                    req_tag_r <= cpu_tag;
                    // A matching snoop clears its tag on this edge, while this
                    // request reads the old one.
                    req_snoop_conflict_r <= snoop_valid_r && (snoop_tag_r == cpu_tag) &&
                                            (snoop_set_r == cpu_set);
                    req_set_r <= cpu_set;
                    state <= S_LOOKUP;
                end
            end

            S_LOOKUP: begin
                req_valid_r <= 1'b0;

                // A disabled cache (req_uncacheable_r) or a no-allocate fetch
                // (req_no_alloc_r) never hits: it reads the whole line as a
                // pass-through fill that is delivered but not installed.
                if (lookup_hit_usable && !req_uncacheable_r && !req_no_alloc_r) begin
                    plru_set[req_set_r] <= plru_update(rd_plru_r, lookup_way);
                    state <= S_IDLE;
                    ready_r <= 1'b1;
                end else begin
                    fill_set <= req_set_r;
                    fill_tag <= req_tag_r;
                    fill_way <= plru_victim(rd_plru_r);
                    fill_plru_r <= rd_plru_r;
                    fill_count <= {WORD_OFFSET_BITS{1'b0}};
                    fill_line <= 128'h0;
                    fill_requested <= 1'b0;
                    fill_uncached_r <= req_uncacheable_r;
                    state <= S_FILL;
                end
            end

            S_FILL: begin
                if (!fill_requested && !mem_valid_r && !mem_busy) begin
                    mem_valid_r <= 1'b1;
                    mem_addr_r <= {req_addr_r[31:4], 4'b0000};
                    mem_burstcount_r <= 8'd4;
                    fill_requested <= 1'b1;
                end

                if (fill_tag_wait_r) begin
                    // The line is gathered; only the shared-way install is
                    // left.  Still S_FILL, so ready stays low and no lookup
                    // can see the victim tag paired with the new data.
                    if (!snoop_valid_r) begin
                        if (fill_install_allowed)
                            plru_set[fill_set] <= plru_update(fill_plru_r, fill_way);
                        fill_tag_wait_r <= 1'b0;
                        state <= S_IDLE;
                        ready_r <= 1'b1;
                    end
                end else if (mem_line_resp_valid) begin
                    fill_line <= wide_line_next;
                    resp_valid_r <= 1'b1;
                    // A snoop clear owns the way write port this cycle; defer
                    // the install instead of dropping the line.
                    if (snoop_valid_r) begin
                        fill_tag_wait_r <= 1'b1;
                    end else begin
                        if (fill_install_allowed)
                            plru_set[fill_set] <= plru_update(fill_plru_r, fill_way);
                        state <= S_IDLE;
                        ready_r <= 1'b1;
                    end
                end else if (mem_resp_valid) begin
                    fill_line <= fill_line_next;

                    if (fill_count == {WORD_OFFSET_BITS{1'b1}}) begin
                        resp_valid_r <= 1'b1;
                        // Only the tag-RAM fill write sets valid for fill_way.
                        // Do not restore any other way from the fill-start
                        // snapshot: a snoop during this fill must survive.
                        if (snoop_valid_r) begin
                            fill_tag_wait_r <= 1'b1;
                        end else begin
                            if (fill_install_allowed)
                                plru_set[fill_set] <= plru_update(fill_plru_r, fill_way);
                            state <= S_IDLE;
                            ready_r <= 1'b1;
                        end
                    end else begin
                        fill_count <= fill_count + 1'b1;
                    end
                end
            end

            default: state <= S_IDLE;
        endcase

        // Hold cpu_ready low for the whole flush window.  The state-transition
        // arms above restore readiness for their next state; a request must
        // never see a ready cache while a walk is pending.
        if (flush_block)
            ready_r <= 1'b0;
    end
end

//=============================================================================
// Whole-L1 sweep
//=============================================================================
// One set per cycle, independent of the fill/lookup FSM, so the flush completes
// even while a fill is blocked on the bus.  A registered snoop's clear writes a
// different index through the same way RAMs, so the sweep yields that cycle and
// re-issues the same set; the reset walk clears everything and never touches
// the bus, so the sweep may simply wait for it.
always_ff @(posedge clk) begin
    if (reset) begin
        flush_busy_r <= 1'b0;
        flush_done_r <= 1'b0;
        flush_set_r  <= {SET_BITS{1'b0}};
    end else begin
        flush_done_r <= 1'b0;
        if (!flush_busy_r) begin
            if (flush_launch) begin
                flush_busy_r <= 1'b1;
                flush_set_r  <= {SET_BITS{1'b0}};
            end
        end else if (!snoop_valid_r) begin
            if (flush_set_r == LAST_SET) begin
                flush_busy_r <= 1'b0;
                flush_done_r <= 1'b1;
            end else begin
                flush_set_r <= flush_set_r + 1'b1;
            end
        end
    end
end

endmodule

//
// L1 Data Cache
// Physically indexed, physically tagged data cache with a store queue
//
`include "z486_platform.svh"
module l1_cache #(
    // Four ways, 16 bytes per line. SET_BITS=7 gives the default 8KB data
    // cache (128 sets x 4 ways x 16 B); use 8 for 16KB.
    parameter integer SET_BITS = 7,
    parameter PROTECT_UMA_ROM = 0
) (
    input         clk,
    input         reset,

    // CPU side — physical address request/response.
    input  [31:0] cpu_addr,    // physical byte address; the cache indexes off the
                               // page-offset bits [11:2] (translation-invariant,
                               // so available without the TLB result) and tags off
                               // [31:12], exactly like l1_icache
    input  [11:0] cpu_preread_offset, // untranslated low address for RAM preread
    input         cpu_preread_priority,// demand intent owns preread over VIPT probe
    input  [31:0] cpu_din,
    output [31:0] cpu_dout,
    input   [3:0] cpu_be,
    input         cpu_valid,
    input         cpu_write,
    // A read that may hit but must not allocate on a miss: a PCD page or
    // CR0.CD=1.  The miss is one exact-size bus read behind every older store.
    input         cpu_uncacheable,
    // CR0.NW=1: a write that hits updates only the L1 (no write-through).
    input         cache_nw,
    // Locked read: never answered by a valid line; one bus read behind every
    // older store (a 486 locked read cycle).
    input         cpu_force_bus,
    output        cpu_ready,      // a read may be presented (registered)
    output        cpu_wr_ready,   // a write may be presented (registered)
    output        cpu_resp_valid,
    output        stores_drained,
    // A posted store (queued, or enqueuing from S_LOOKUP) lies in this line:
    // the I-cache must not read the line from memory ahead of it.
    input  [31:4] storeq_probe_line,
    output        storeq_line_hit,

    // Accepted CPU stores are registered before S_LOOKUP.  Export that
    // registered payload for the instruction-cache coherence patch.
    output [31:0] store_patch_addr,
    output [31:0] store_patch_data,
    output  [3:0] store_patch_be,
    // The coherence patch consumer cannot take a store this cycle; holds off
    // a store accepted behind another store's S_LOOKUP.
    input         store_patch_busy,
    output        store_patch_valid,

    // Side-effect-free hardwired-load path. D2 selects the RAM word; EX
    // supplies the physical tag exactly one cycle later. The cache does not
    // retain request ownership and a miss retries through the CPU interface.
    input  [11:0] vipt_probe_offset,
    input         vipt_probe_valid,
    output        vipt_probe_ready,
    output        vipt_probe_accepted,
    output        vipt_probe_direct_accepted,
    input  [31:0] vipt_resolve_phys_addr,
    // vipt_resolve_phys_addr = vipt_resolve_use_tlb ? vipt_resolve_tlb_phys
    //                                               : vipt_resolve_alt_phys
    // (data_access fuses it): the tag compare takes each arm and the select last.
    input  [31:0] vipt_resolve_tlb_phys,
    input  [31:0] vipt_resolve_alt_phys,
    input         vipt_resolve_use_tlb,
    input         vipt_resolve_valid,
    output [31:0] vipt_resolve_data,
    output        vipt_resolve_hit,

    // Memory side.
    output [31:0] mem_addr,
    output [31:0] mem_din,
    input  [31:0] mem_dout,
    input [127:0] mem_line_dout,
    output  [3:0] mem_be,
    output  [7:0] mem_burstcount,
    input         mem_busy,
    output        mem_valid,
    output        mem_write,
    input         mem_ready,
    input         mem_resp_valid,
    input         mem_line_resp_valid,

    // Physical-address snoop.  The first implementation invalidates a whole
    // set; this is conservative and keeps snoop matching off the read hit path.
    input  [31:0] snoop_addr,
    input         snoop_valid,

    // Native whole-L1 invalidate.  flush_req is a one-cycle request (a held
    // level is also accepted: one walk per release); flush_busy is high for the
    // walk and flush_done pulses once when it completes.
    input         flush_req,
    output        flush_busy,
    output        flush_done,

    input         cache_enable
);

localparam integer WORD_OFFSET_BITS = 2;
localparam integer BYTE_OFFSET_BITS = 2;
localparam integer LINE_OFFSET_BITS = WORD_OFFSET_BITS + BYTE_OFFSET_BITS;
localparam integer NUM_SETS = 1 << SET_BITS;
localparam integer BRAM_ADDR_BITS = SET_BITS + WORD_OFFSET_BITS;
localparam integer PHYS_ADDR_BITS = `Z486_L1_PHYS_ADDR_BITS; // default tag reach: 128 MiB
localparam integer TAG_BITS = PHYS_ADDR_BITS - LINE_OFFSET_BITS - SET_BITS;
localparam integer SET_LSB = LINE_OFFSET_BITS;
localparam integer SET_MSB = SET_LSB + SET_BITS - 1;
localparam integer TAG_LSB = SET_MSB + 1;
localparam integer TAG_MSB = PHYS_ADDR_BITS - 1;
localparam integer TAG_RAM_BITS = (TAG_BITS < 16) ? 16 : (TAG_BITS + 1);
localparam integer TAG_VALID_BIT = TAG_BITS;
localparam integer STOREQ_DEPTH = `ifdef STOREQ_DEPTH_OVERRIDE `STOREQ_DEPTH_OVERRIDE `else 4 `endif;
localparam integer STOREQ_IDX_BITS = $clog2(STOREQ_DEPTH);
localparam integer STOREQ_CNT_BITS = $clog2(STOREQ_DEPTH + 1);
localparam [STOREQ_CNT_BITS-1:0] STOREQ_DEPTH_VALUE = STOREQ_CNT_BITS'(STOREQ_DEPTH);
localparam [STOREQ_IDX_BITS-1:0] STOREQ_LAST_IDX = STOREQ_IDX_BITS'(STOREQ_DEPTH - 1);
localparam [SET_BITS-1:0] LAST_SET = SET_BITS'(NUM_SETS - 1);

// synthesis translate_off
initial begin
    if (SET_BITS < 1 || SET_BITS > 8 || PHYS_ADDR_BITS > 32 ||
        PHYS_ADDR_BITS <= LINE_OFFSET_BITS + SET_BITS)
        $fatal(1, "Invalid L1 D-cache index/tag width (VIPT indexes must stay in page offset)");
end
// synthesis translate_on

// Address decomposition. Include the complete physical tag so larger SDRAM
// configurations cannot alias cache lines at 32MB boundaries.
wire [TAG_BITS-1:0] cpu_tag = cpu_addr[TAG_MSB:TAG_LSB];
// Set/word array index from the physical address page-offset bits
// (cpu_addr[11:2], translation-invariant -- available without the TLB result).
wire [SET_BITS-1:0] cpu_set = cpu_addr[SET_MSB:SET_LSB];
wire [WORD_OFFSET_BITS-1:0] cpu_word = cpu_addr[LINE_OFFSET_BITS-1:BYTE_OFFSET_BITS];
wire [BRAM_ADDR_BITS-1:0] cpu_bram_addr = {cpu_set, cpu_word};
wire [SET_BITS-1:0] cpu_preread_set =
    cpu_preread_offset[SET_MSB:SET_LSB];
wire [WORD_OFFSET_BITS-1:0] cpu_preread_word =
    cpu_preread_offset[LINE_OFFSET_BITS-1:BYTE_OFFSET_BITS];
wire [SET_BITS-1:0] vipt_probe_set = vipt_probe_offset[SET_MSB:SET_LSB];
wire [WORD_OFFSET_BITS-1:0] vipt_probe_word =
    vipt_probe_offset[LINE_OFFSET_BITS-1:BYTE_OFFSET_BITS];
wire [SET_BITS-1:0] snoop_set = snoop_addr[SET_MSB:SET_LSB];
// A locked read takes the uncacheable miss path; its preread masks every way
// (rd_invalidated_r) so the lookup never hits, at no cost to the hit cone.
wire request_uncacheable = !cache_enable || cpu_uncacheable || cpu_force_bus;
`ifdef VERILATOR
// Simulation harness switch: a loaded snapshot whose BIOS keeps state in its
// shadow (SeaBIOS runs interrupt handlers on a stack at 0xE0000-0xEFFFF)
// needs the UMA ROM window writable.
reg sim_uma_rom_writable /* verilator public_flat_rw */ = 1'b0;
`else
wire sim_uma_rom_writable = 1'b0;
`endif
// Decode the full address: a partial compare also protects the 32MB aliases
// (0x20C0000-0x20FFFFF, ...) and silently drops writes to that RAM.
wire cpu_protect_write = PROTECT_UMA_ROM && !sim_uma_rom_writable && cpu_write &&
                         (cpu_addr[31:18] == 14'h0003);

// Tag/data storage.
// Keep validity in the otherwise under-filled tag RAM word. This removes four
// asynchronously indexed 256-bit register arrays from the preread address
// path without changing the synchronous lookup boundary.
`Z486_BLOCK_RAM reg [TAG_RAM_BITS-1:0] tag_way0 [0:NUM_SETS-1];
`Z486_BLOCK_RAM reg [TAG_RAM_BITS-1:0] tag_way1 [0:NUM_SETS-1];
`Z486_BLOCK_RAM reg [TAG_RAM_BITS-1:0] tag_way2 [0:NUM_SETS-1];
`Z486_BLOCK_RAM reg [TAG_RAM_BITS-1:0] tag_way3 [0:NUM_SETS-1];
reg [2:0] plru_set [0:NUM_SETS-1];

`Z486_BLOCK_RAM reg [31:0] data_way0 [0:(NUM_SETS << WORD_OFFSET_BITS)-1];
`Z486_BLOCK_RAM reg [31:0] data_way1 [0:(NUM_SETS << WORD_OFFSET_BITS)-1];
`Z486_BLOCK_RAM reg [31:0] data_way2 [0:(NUM_SETS << WORD_OFFSET_BITS)-1];
`Z486_BLOCK_RAM reg [31:0] data_way3 [0:(NUM_SETS << WORD_OFFSET_BITS)-1];

// Synchronous cache read result for the request accepted in the previous cycle.
// Register each complete tag word as one RAM read; Quartus 17 otherwise treats
// separate tag and valid slices as independent read ports and implements the
// arrays in logic.
reg [TAG_RAM_BITS-1:0] rd_tag_entry0_r, rd_tag_entry1_r;
reg [TAG_RAM_BITS-1:0] rd_tag_entry2_r, rd_tag_entry3_r;
// Ways whose tag was captured on an edge that also cleared their set.  The tag
// RAM read is synchronous and returns the OLD entry, so without this the very
// next lookup can hit a line that this clear just invalidated.
reg [3:0] rd_invalidated_r;
wire [TAG_BITS-1:0] rd_tag0_r = rd_tag_entry0_r[TAG_BITS-1:0];
wire [TAG_BITS-1:0] rd_tag1_r = rd_tag_entry1_r[TAG_BITS-1:0];
wire [TAG_BITS-1:0] rd_tag2_r = rd_tag_entry2_r[TAG_BITS-1:0];
wire [TAG_BITS-1:0] rd_tag3_r = rd_tag_entry3_r[TAG_BITS-1:0];
wire rd_valid0_r = rd_tag_entry0_r[TAG_VALID_BIT];
wire rd_valid1_r = rd_tag_entry1_r[TAG_VALID_BIT];
wire rd_valid2_r = rd_tag_entry2_r[TAG_VALID_BIT];
wire rd_valid3_r = rd_tag_entry3_r[TAG_VALID_BIT];
reg [31:0] rd_data0_r, rd_data1_r, rd_data2_r, rd_data3_r;
reg [2:0] rd_plru_r;

// Accepted request register.
reg        req_valid_r;
reg [31:0] req_addr_r;
reg [31:0] req_din_r;
reg  [3:0] req_be_r;
reg        req_write_r;
reg        req_uncacheable_r;
reg        req_nw_r;            // CR0.NW sampled with the request
reg        nw_hit_r;            // S_NW_WRITE: the NW store hit (stays cache-only)
reg        req_protect_write_r;
reg [TAG_BITS-1:0] req_tag_r;
reg [SET_BITS-1:0] req_set_r;
reg [WORD_OFFSET_BITS-1:0] req_word_r;

// Write-through store queue.
reg [29:0] storeq_addr [0:STOREQ_DEPTH-1];
reg [31:0] storeq_data [0:STOREQ_DEPTH-1];
reg  [3:0] storeq_be   [0:STOREQ_DEPTH-1];
reg        storeq_valid[0:STOREQ_DEPTH-1];
reg [STOREQ_IDX_BITS-1:0] storeq_head;
reg [STOREQ_IDX_BITS-1:0] storeq_tail;
reg [STOREQ_CNT_BITS-1:0] storeq_count;
reg        storeq_draining;
logic      storeq_line_hit_c;

wire storeq_full = (storeq_count == STOREQ_DEPTH_VALUE);
wire storeq_empty = (storeq_count == {STOREQ_CNT_BITS{1'b0}});
wire storeq_can_accept = !storeq_full || (storeq_draining && mem_ready);
// Device transactions are serializing.  The memory fabric uses this status to
// keep I/O and other direct accesses behind every older posted store.
assign stores_drained = storeq_empty && !storeq_draining &&
                        !(req_valid_r && req_write_r && !req_protect_write_r) &&
                        (state != S_NW_WRITE);

// Memory-side registers.
reg        mem_valid_r;
reg        mem_write_r;
reg [31:0] mem_addr_r;
reg [31:0] mem_din_r;
reg  [3:0] mem_be_r;
reg  [7:0] mem_burstcount_r;

assign mem_valid = mem_valid_r;
assign mem_write = mem_write_r;
assign mem_addr = mem_addr_r;
assign mem_din = mem_din_r;
assign mem_be = mem_be_r;
assign mem_burstcount = mem_burstcount_r;

// Cache FSM.
localparam [2:0] S_RESET_INIT  = 3'd0;
localparam [2:0] S_IDLE        = 3'd1;
localparam [2:0] S_LOOKUP      = 3'd2;
localparam [2:0] S_FILL        = 3'd3;
localparam [2:0] S_BYPASS_WAIT = 3'd4;
localparam [2:0] S_NW_WRITE    = 3'd5;  // NW=1 store: enqueue only a miss

reg [2:0] state;
// A posted store in the line the I-cache is about to read from memory (the
// queue, or the store enqueuing from S_LOOKUP). Memory does not hold it yet,
// and the I$ patch queue only remembers the last three patches, so the fill
// must wait for the drain (tests/programs/hz_patchq_overrun).
always_comb begin
    storeq_line_hit_c = (state == S_LOOKUP) && req_valid_r && req_write_r &&
                        !req_protect_write_r &&
                        (req_addr_r[31:4] == storeq_probe_line);
    for (int k = 0; k < STOREQ_DEPTH; k++)
        if (storeq_valid[k] && (storeq_addr[k][29:2] == storeq_probe_line))
            storeq_line_hit_c = 1'b1;
end
assign storeq_line_hit = storeq_line_hit_c;
reg [SET_BITS-1:0] init_set;
reg [SET_BITS-1:0] snoop_set_r;
reg snoop_valid_r;
reg [WORD_OFFSET_BITS-1:0] fill_count;
reg [WORD_OFFSET_BITS-1:0] fill_target_word;
reg [SET_BITS-1:0] fill_set;
reg [TAG_BITS-1:0] fill_tag;
reg [1:0] fill_way;
reg [2:0] fill_plru_r;
reg fill_requested;
reg fill_target_returned;
reg [127:0] wide_fill_line;
reg wide_fill_install;
// The last data beat can complete while a snoop owns the tag write port.
// Keep the cache in S_FILL until the tag can install; no lookup may observe
// the old victim tag paired with the newly written data in the meantime.
reg fill_tag_wait_r;

reg [31:0] dout_r;
reg resp_valid_r;
reg ready_r;

// Whole-L1 invalidate state.  A request is consumed once (a held level is
// re-armed only after it is released), and flush_block holds new requests off
// from the cycle it is first observed.
//
// The sweep is an INDEPENDENT walk over the sets, not a service of the fill
// FSM: a fill in flight can be blocked indefinitely behind an unrelated bus
// transaction, and the platform that asked for the flush may be holding that
// very transaction until the flush completes.  Waiting for the cache to fall
// idle would deadlock the machine, so instead any fill in flight is marked
// (fill_killed_r) and cannot install after the sweep; the sweep then runs
// concurrently with it and always completes in SETS+2 cycles.
reg  flush_req_seen_r;
reg  flush_pending_r;
reg  flush_busy_r;
reg  flush_done_r;
reg  [SET_BITS-1:0] flush_set_r;
reg  fill_killed_r;
// A registered snoop cleared this fill's whole set; hold it for the rest of the
// fill so the tag install cannot reinstate the line (mirrors the I$'s
// fill_line_snooped_r).
reg  fill_set_snooped_r;
// Same-cycle form: the fill install and the snoop clear share the way write
// port, so an install of this set must be blocked in the registered cycle as well as after
// (fill_set_snooped_r keeps it blocked for the rest of the fill).
wire fill_set_snooped_now = (state == S_FILL) && snoop_valid_r &&
                            (snoop_set_r == fill_set);
wire flush_req_new = flush_req & ~flush_req_seen_r;
wire flush_block = flush_req_new | flush_pending_r | flush_busy_r;

assign flush_busy = flush_busy_r;
assign flush_done = flush_done_r;

assign cpu_ready = ready_r && !flush_block;
assign store_patch_addr = req_addr_r;
assign store_patch_data = req_din_r;
assign store_patch_be = req_be_r;
assign store_patch_valid = (state == S_LOOKUP) && req_valid_r &&
                           req_write_r && !req_protect_write_r;

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

function automatic [127:0] forward_storeq_line_slot(
    input [127:0] value,
    input         slot_live,
    input  [29:0] slot_addr,
    input  [31:0] slot_data,
    input   [3:0] slot_be,
    input  [27:0] line_addr
);
    automatic reg [127:0] result;
begin
    result = value;
    if (slot_live && slot_addr[29:2] == line_addr)
        result[{slot_addr[1:0], 5'b0} +: 32] =
            merge32(result[{slot_addr[1:0], 5'b0} +: 32], slot_data, slot_be);
    forward_storeq_line_slot = result;
end
endfunction


function automatic [STOREQ_IDX_BITS-1:0] storeq_next_idx(input [STOREQ_IDX_BITS-1:0] idx);
begin
    storeq_next_idx = (idx == STOREQ_LAST_IDX) ? {STOREQ_IDX_BITS{1'b0}} : (idx + 1'b1);
end
endfunction

// Slot holding the k-th oldest entry.
// Physical slot p's age (0 = oldest = tail) is (p - tail) mod depth; the slot is
// live in the overlay when its age is below the count.
function automatic logic sq_slot_live(input [STOREQ_IDX_BITS-1:0] tail,
                                      input [STOREQ_CNT_BITS-1:0] count, input integer p);
    integer age;
begin
    age = p - tail;
    if (age < 0) age = age + STOREQ_DEPTH;
    sq_slot_live = age < count;
end
endfunction

// The store-queue overlay from per-slot hits: per byte lane, the youngest
// hitting slot whose byte enable covers it (slot q is younger than p when its
// age is larger), and the lanes any hit covers.  Returns {be, data}; data lanes
// outside be are zero.
function automatic [35:0] sq_overlay_pick(input [STOREQ_DEPTH-1:0] hit,
                                          input [STOREQ_IDX_BITS-1:0] tail,
                                          input [32*STOREQ_DEPTH-1:0] data,
                                          input [4*STOREQ_DEPTH-1:0] be);
    logic [31:0] d;
    logic [3:0]  bo;
    logic        cov_p, younger_cov;
    integer      ap, aq;
begin
    d = 32'd0;
    bo = 4'd0;
    for (int b = 0; b < 4; b++) begin
        for (int p = 0; p < STOREQ_DEPTH; p++) begin
            ap = p - tail; if (ap < 0) ap = ap + STOREQ_DEPTH;
            cov_p = hit[p] && be[p*4 + b];
            younger_cov = 1'b0;
            for (int q = 0; q < STOREQ_DEPTH; q++) begin
                aq = q - tail; if (aq < 0) aq = aq + STOREQ_DEPTH;
                if ((aq > ap) && hit[q] && be[q*4 + b])
                    younger_cov = 1'b1;
            end
            if (cov_p && !younger_cov)
                d[b*8 +: 8] = d[b*8 +: 8] | data[p*32 + b*8 +: 8];
            bo[b] = bo[b] | cov_p;
        end
    end
    sq_overlay_pick = {bo, d};
end
endfunction

// A way's tag against the resolve address, compared on each of its two arms
// with the arm select last: (tag == (sel ? t : a)) = sel ? tag == t : tag == a.
function automatic logic vipt_tag_eq_split(input logic sel, input [TAG_BITS-1:0] tag,
                                           input [TAG_BITS-1:0] t, input [TAG_BITS-1:0] a);
    vipt_tag_eq_split = sel ? (tag == t) : (tag == a);
endfunction

function automatic [STOREQ_IDX_BITS-1:0] storeq_age_idx(
    input [STOREQ_IDX_BITS-1:0] tail, input integer k);
    integer i;
begin
    i = tail + k;
    storeq_age_idx = STOREQ_IDX_BITS'((i >= STOREQ_DEPTH) ? i - STOREQ_DEPTH : i);
end
endfunction

function automatic [STOREQ_IDX_BITS-1:0] storeq_prev_idx(input [STOREQ_IDX_BITS-1:0] idx);
begin
    storeq_prev_idx = (idx == {STOREQ_IDX_BITS{1'b0}}) ? STOREQ_LAST_IDX : (idx - 1'b1);
end
endfunction

function automatic [1:0] way_encode(input [3:0] hit_vec);
begin
    way_encode = hit_vec[0] ? 2'd0 :
                 hit_vec[1] ? 2'd1 :
                 hit_vec[2] ? 2'd2 : 2'd3;
end
endfunction

function automatic [31:0] way_data_mux(
    input [1:0] way,
    input [31:0] data0,
    input [31:0] data1,
    input [31:0] data2,
    input [31:0] data3
);
begin
    case (way)
        2'd0: way_data_mux = data0;
        2'd1: way_data_mux = data1;
        2'd2: way_data_mux = data2;
        default: way_data_mux = data3;
    endcase
end
endfunction

// The registered store patch is applied to its own way's RAM read before the
// way mux, so the hit way selects among already patched words instead of the
// patch decision waiting on the encoded hit way (pmatch: the patch is valid
// and names this dword). Equal to (pmatch && pway == way) ? pdata
// : way_data_mux(way, ...) for every input (tests/equiv/way_patch_pick.v).
function automatic [31:0] way_patch_pick(
    input [1:0] way,
    input [31:0] data0,
    input [31:0] data1,
    input [31:0] data2,
    input [31:0] data3,
    input pmatch,
    input [1:0] pway,
    input [31:0] pdata
);
begin
    way_patch_pick = way_data_mux(way,
        (pmatch && pway == 2'd0) ? pdata : data0,
        (pmatch && pway == 2'd1) ? pdata : data1,
        (pmatch && pway == 2'd2) ? pdata : data2,
        (pmatch && pway == 2'd3) ? pdata : data3);
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
    rd_valid3_r && !rd_invalidated_r[3] && (rd_tag3_r == req_tag_r),
    rd_valid2_r && !rd_invalidated_r[2] && (rd_tag2_r == req_tag_r),
    rd_valid1_r && !rd_invalidated_r[1] && (rd_tag1_r == req_tag_r),
    rd_valid0_r && !rd_invalidated_r[0] && (rd_tag0_r == req_tag_r)
};
// A registered snoop clears the whole set in this cycle, but the synchronous
// RAM lookup captured its tag a cycle earlier, so that hit is stale.  Reject it
// (the I$ already does this in l1_icache.sv): the demand misses, refetches, and
// the external write is observed instead of the pre-snoop line.
wire lookup_snoop_conflict = snoop_valid_r && (snoop_set_r == req_set_r);
wire lookup_hit = |lookup_hit_vec && !lookup_snoop_conflict;
wire [1:0] lookup_way = way_encode(lookup_hit_vec);
wire [31:0] lookup_way_ram_data = way_data_mux(lookup_way, rd_data0_r, rd_data1_r, rd_data2_r, rd_data3_r);
// A read may preread its dword in the cycle a store patches the data RAM (a
// pipelined store, or a VIPT probe below). When both name the same dword and
// way, take the registered patch value rather than the RAM read that raced it;
// a read that came after the patch merges the same bytes harmlessly.
reg         patch_fwd_valid_r;
reg  [1:0]  patch_fwd_way_r;
reg  [31:0] patch_fwd_data_r;
reg  [SET_BITS+WORD_OFFSET_BITS-1:0] patch_fwd_addr_r;
wire patch_fwd_match = patch_fwd_valid_r && (patch_fwd_addr_r == {req_set_r, req_word_r});
wire patch_fwd_hit = patch_fwd_match && (patch_fwd_way_r == lookup_way);
wire [31:0] lookup_way_data = way_patch_pick(lookup_way, rd_data0_r, rd_data1_r,
    rd_data2_r, rd_data3_r, patch_fwd_match, patch_fwd_way_r, patch_fwd_data_r);
wire [TAG_BITS-1:0] vipt_resolve_tag =
    vipt_resolve_phys_addr[TAG_MSB:TAG_LSB];
// The tag compare against each arm of the resolve address, the VIPT TLB hit
// (vipt_resolve_use_tlb) selecting the result: the TLB M10K's physical page is
// compared in parallel with the TLB's own tag compare instead of after it (the
// fitted vipt_tlb q -> vipt_hit (fo ~32) -> resolve address -> tag compare ->
// vipt_hit_vec -> vipt_load_ex_hit -> d2_ready path).  Equal to the compare
// against vipt_resolve_tag (tests/equiv/vipt_tag_split.v; fused below).
wire [TAG_BITS-1:0] vipt_resolve_tag_tlb = vipt_resolve_tlb_phys[TAG_MSB:TAG_LSB];
wire [TAG_BITS-1:0] vipt_resolve_tag_alt = vipt_resolve_alt_phys[TAG_MSB:TAG_LSB];
wire [3:0] vipt_hit_vec = {
    rd_valid3_r && !rd_invalidated_r[3] &&
        vipt_tag_eq_split(vipt_resolve_use_tlb, rd_tag3_r, vipt_resolve_tag_tlb, vipt_resolve_tag_alt),
    rd_valid2_r && !rd_invalidated_r[2] &&
        vipt_tag_eq_split(vipt_resolve_use_tlb, rd_tag2_r, vipt_resolve_tag_tlb, vipt_resolve_tag_alt),
    rd_valid1_r && !rd_invalidated_r[1] &&
        vipt_tag_eq_split(vipt_resolve_use_tlb, rd_tag1_r, vipt_resolve_tag_tlb, vipt_resolve_tag_alt),
    rd_valid0_r && !rd_invalidated_r[0] &&
        vipt_tag_eq_split(vipt_resolve_use_tlb, rd_tag0_r, vipt_resolve_tag_tlb, vipt_resolve_tag_alt)
};
// synthesis translate_off
always @(posedge clk)
    if (!reset && vipt_resolve_valid &&
        (vipt_resolve_phys_addr !== (vipt_resolve_use_tlb ? vipt_resolve_tlb_phys
                                                          : vipt_resolve_alt_phys)))
        $fatal(1, "l1_cache: the VIPT resolve arms disagree with vipt_resolve_phys_addr");
// synthesis translate_on
wire [1:0] vipt_hit_way = way_encode(vipt_hit_vec);
wire [31:0] vipt_way_ram_data = way_data_mux(
    vipt_hit_way, rd_data0_r, rd_data1_r, rd_data2_r, rd_data3_r);
// A probe may preread in the cycle a store patches the same dword (the probe
// shares the read port with a store's S_LOOKUP). Take the registered patch
// value over the RAM read that raced it; set/word bits are page-offset bits.
wire vipt_patch_fwd_match = patch_fwd_valid_r &&
    (patch_fwd_addr_r == vipt_resolve_phys_addr[SET_MSB:BYTE_OFFSET_BITS]);
wire vipt_patch_fwd_hit = vipt_patch_fwd_match && (patch_fwd_way_r == vipt_hit_way);
wire [31:0] vipt_way_data = way_patch_pick(vipt_hit_way, rd_data0_r, rd_data1_r,
    rd_data2_r, rd_data3_r, vipt_patch_fwd_match, patch_fwd_way_r, patch_fwd_data_r);
// A younger VIPT lookup may share the preread used to capture an older store
// to the same word. The store reaches S_LOOKUP while that younger request
// finalizes, so forward its registered bytes over the RAM's old data.
wire vipt_lookup_store_match = (state == S_LOOKUP) && req_valid_r &&
    req_write_r && !req_protect_write_r &&
    (req_addr_r[31:2] == vipt_resolve_phys_addr[31:2]);
assign vipt_resolve_data = vipt_lookup_store_match
                         ? merge32(vipt_way_data, req_din_r, req_be_r)
                         : vipt_way_data;
assign vipt_resolve_hit = vipt_resolve_valid && cache_enable && !flush_block &&
                          (vipt_resolve_phys_addr[31:17] != 15'h5) &&
                          !(snoop_valid_r && (snoop_set_r ==
                            vipt_resolve_phys_addr[SET_MSB:SET_LSB])) &&
                          (|vipt_hit_vec);
wire [BRAM_ADDR_BITS-1:0] req_bram_addr = {req_set_r, req_word_r};
wire can_accept_cpu = (state == S_IDLE) && !reset &&
    (!cpu_write || (!store_patch_busy && (cpu_protect_write || storeq_can_accept)));
wire ready_when_idle = !reset && !flush_block && storeq_can_accept;
// Store pipelining, like the i486 write buffer taking one store per clock:
// while a store enqueues in S_LOOKUP, accept the next store and preread its
// set on the free RAM read port. lookup_wr_room_r holds the queue capacity for
// that store, computed when the current store was accepted. The opening is
// registered state only: requesters see it through cpu_wr_ready without any
// address, TLB or request-type term.
// The walk starts one cycle after the request is observed, when ready_r has
// already been forced low: a low ready_r means no demand request can be
// accepted this cycle, and it also disables the preread/probe arms, so the
// launch cannot collide with an accept or a VIPT probe resolve.  Testing
// ready_r (a register) instead of accept_cpu keeps the request-classification
// cone behind cpu_valid out of this decision.
wire flush_launch = (flush_req_new | flush_pending_r) &&
                    (state != S_RESET_INIT) && !reset;
reg  lookup_wr_room_r;
// CR0.NW=1 stores never pipeline: lookup_wr_room_r is cleared for them.
wire lookup_store_busy = (state == S_LOOKUP) && req_valid_r &&
                         req_write_r && !req_protect_write_r;
wire lookup_wr_open = lookup_store_busy && lookup_wr_room_r &&
                      !store_patch_busy && !flush_block;
// The one-entry downstream patch slot can stay stranded across idle cycles.
// Hold ALL stores, not just the pipelined LOOKUP opening, until it can drain.
assign cpu_wr_ready = (cpu_ready && !store_patch_busy) || lookup_wr_open;
wire lookup_wr_accept = cpu_valid && cpu_write && lookup_wr_open;
wire accept_cpu = (cpu_valid && cpu_ready && can_accept_cpu) || lookup_wr_accept;
logic [31:0] lookup_forward_data;
logic [31:0] fill_word_data;
logic [31:0] bypass_forward_data;
logic [127:0] wide_line_data;
// An uncacheable (PCD/CD) read still hits a valid line: only a miss bypasses.
wire lookup_read_hit_now = (state == S_LOOKUP) && req_valid_r &&
                           !req_write_r && lookup_hit;

assign cpu_dout = lookup_read_hit_now ? lookup_forward_data : dout_r;
assign cpu_resp_valid = lookup_read_hit_now || resp_valid_r;

// Uncacheable reads cannot bypass posted stores.  Besides preserving normal
// memory ordering, VGA reads depend on all earlier planar writes being visible.
// Keep draining while such a read waits, then reserve the memory port once the
// queue is empty.
wire drain_block_state = (state == S_RESET_INIT) || (state == S_FILL) ||
                         (state == S_BYPASS_WAIT) ||
                         ((state == S_LOOKUP) && !req_protect_write_r && !req_write_r &&
                          !req_uncacheable_r && !lookup_hit);
wire drain_issue_now = !storeq_empty && !storeq_draining && !mem_valid_r &&
                       !mem_busy && !drain_block_state;

wire [STOREQ_IDX_BITS-1:0] storeq_prev = storeq_prev_idx(storeq_head);
wire storeq_merge_lookup = !storeq_empty && storeq_valid[storeq_prev] &&
                           (storeq_addr[storeq_prev] == req_addr_r[31:2]) &&
                           !req_uncacheable_r &&
                           !(storeq_prev == storeq_tail && storeq_draining);
// The S_LOOKUP write merging into the very entry the drain is launching
// this cycle: fold the incoming bytes into the launch latch too.
wire storeq_merge_wr_now = (state == S_LOOKUP) && req_write_r &&
                           !req_protect_write_r && !req_nw_r && storeq_merge_lookup;
wire drain_merge_now = storeq_merge_wr_now && (storeq_prev == storeq_tail);
// Store-queue count after this cycle's enqueue, including a simultaneously
// completing drain.  Drives the post-write ready_r so a full queue is seen
// immediately despite the one-cycle-late enqueue.
wire storeq_dequeuing = storeq_draining && mem_ready;
wire [STOREQ_CNT_BITS-1:0] storeq_count_wr_next =
     storeq_merge_lookup ? (storeq_dequeuing ? storeq_count - 1'b1 : storeq_count)
                         : (storeq_dequeuing ? storeq_count : storeq_count + 1'b1);

// The queued stores' overlay on the word being read: the youngest matching store's
// bytes per lane, and which lanes any store covers. A lookup reads in S_LOOKUP
// and a fill word merges in S_FILL, so one overlay (word taken from the request
// or from the fill beat by state) serves both instead of a compare and a merge
// chain per reader.
wire [1:0] sq_fwd_word = (state == S_FILL) ? fill_count : req_addr_r[3:2];
logic [31:0] sq_ov_data;
logic [3:0]  sq_ov_be;
// The overlay in physical-slot order: each slot's address is compared with the
// word directly (no tail-rotated mux in front of the 30-bit compare), its age
// guard (k < storeq_count, k = the slot's age) and the youngest-wins
// precedence are functions of the registered tail and count only, and each
// byte lane takes the one winning slot's byte (an AND-OR, not a chain of
// merges).  The fitted path was storeq_tail -> tail + k -> slot mux -> address
// compare -> four chained merges -> normal_rdata -> OPR_R.  Equal to the
// age-ordered chain (kept below as the reference, fused) for every input:
// tests/equiv/sq_overlay_phys.v pastes sq_overlay_pick and sq_slot_live.
logic [STOREQ_DEPTH-1:0] sq_slot_hit;
logic [32*STOREQ_DEPTH-1:0] sq_data_flat;
logic [4*STOREQ_DEPTH-1:0]  sq_be_flat;
always_comb begin
    for (int p = 0; p < STOREQ_DEPTH; p++) begin
        sq_data_flat[p*32 +: 32] = storeq_data[p];
        sq_be_flat[p*4 +: 4]     = storeq_be[p];
    end
    for (int p = 0; p < STOREQ_DEPTH; p++)
        sq_slot_hit[p] = sq_slot_live(storeq_tail, storeq_count, p) && storeq_valid[p] &&
                         (storeq_addr[p] == {req_addr_r[31:4], sq_fwd_word});
    {sq_ov_be, sq_ov_data} = sq_overlay_pick(sq_slot_hit, storeq_tail, sq_data_flat, sq_be_flat);
end
// synthesis translate_off
logic [31:0] sq_ov_data_ref;
logic [3:0]  sq_ov_be_ref;
always_comb begin
    sq_ov_data_ref = 32'd0;
    sq_ov_be_ref   = 4'd0;
    // Oldest to youngest, so the youngest matching store's bytes win.
    for (int k = 0; k < STOREQ_DEPTH; k++) begin
        if (k < storeq_count &&
            storeq_valid[storeq_age_idx(storeq_tail, k)] &&
            storeq_addr[storeq_age_idx(storeq_tail, k)] == {req_addr_r[31:4], sq_fwd_word}) begin
            sq_ov_data_ref = merge32(sq_ov_data_ref, storeq_data[storeq_age_idx(storeq_tail, k)],
                                     storeq_be[storeq_age_idx(storeq_tail, k)]);
            sq_ov_be_ref   = sq_ov_be_ref | storeq_be[storeq_age_idx(storeq_tail, k)];
        end
    end
end
always @(posedge clk)
    if (!reset && ((sq_ov_be !== sq_ov_be_ref) || (sq_ov_data !== sq_ov_data_ref)))
        $fatal(1, "l1_cache: physical-slot store-queue overlay %h/%h != age chain %h/%h",
               sq_ov_be, sq_ov_data, sq_ov_be_ref, sq_ov_data_ref);
// synthesis translate_on

always_comb begin
    lookup_forward_data = merge32(lookup_way_data, sq_ov_data, sq_ov_be);
    fill_word_data = merge32(mem_dout, sq_ov_data, sq_ov_be);
    // The uncached read needs no store-queue forwarding: S_LOOKUP launches it only with the
    // queue empty and not draining (`storeq_empty && !storeq_draining`), and the queue is
    // filled only in S_LOOKUP and S_NW_WRITE, so it is still empty for the whole of
    // S_BYPASS_WAIT and every slot's `k < storeq_count` guard is false. Asserted below.
    bypass_forward_data = mem_dout;
    wide_line_data = mem_line_dout;

    // Oldest to youngest, so the youngest matching store's bytes win.
    for (int k = 0; k < STOREQ_DEPTH; k++) begin
        if (k < storeq_count) begin
            wide_line_data = forward_storeq_line_slot(wide_line_data, storeq_valid[storeq_age_idx(storeq_tail, k)], storeq_addr[storeq_age_idx(storeq_tail, k)], storeq_data[storeq_age_idx(storeq_tail, k)], storeq_be[storeq_age_idx(storeq_tail, k)], req_addr_r[31:4]);
        end
    end
end

// Preread runs on every ready idle cycle, with no cpu_valid/TLB gating: when
// no request is accepted the preread results are garbage that S_LOOKUP never
// sees (it is only entered on accept_cpu).  This keeps the TLB-hit cone off
// the wide rd_*_r register enables.
wire idle_preread = (state == S_IDLE) && cpu_ready;
// The store-pipelining preread, likewise ungated by the late accept.
wire lookup_wr_preread = lookup_wr_open;
// A posted store patches at most one data way during S_LOOKUP.  The inferred
// cache RAMs have an independent read port, so a VIPT lookup can preread the
// next load in that cycle, in the store's set too: a read that races the patch
// takes the registered patch value (vipt_patch_fwd_hit). Store hits change no
// tag, and a probe that misses falls back to the paging path, which chooses
// any victim from current PLRU state.
wire store_lookup_preread = (state == S_LOOKUP) && req_valid_r &&
                            req_write_r && !req_protect_write_r && !flush_block;
// Store hits patch the cache before it can accept another probe; store misses
// have no matching line, and later fills are patched before the tag is valid.
// Capacity is a registered-state fact. Demand arbitration must not feed back
// through D2 issue; a denied speculative probe is replayed by the CPU.
assign vipt_probe_ready = idle_preread || store_lookup_preread;
wire vipt_probe_fire = vipt_probe_valid &&
                       (idle_preread || store_lookup_preread) &&
                       !cpu_preread_priority;
// When an accepted demand store owns the preread RAM at the same page offset,
// its RAM address is also the exact VIPT lookup address. Share that read
// instead of rejecting and replaying the younger instruction. Demand reads
// retain exclusive priority and the existing replay contract.
// The store must be ACCEPTED in this cycle: the shared read predates its
// bytes, which vipt_lookup_store_match merges only once it is in S_LOOKUP. A
// store held off here (a busy I$ patch slot, a full queue) would otherwise
// leave the probe resolving the pre-store value
// (tests/programs/hz_vipt_share_unposted). The acceptance term reaches only
// the CPU's probed-flag flops, not D2 issue.
wire vipt_probe_share = vipt_probe_valid && cpu_preread_priority &&
                        idle_preread && cpu_write &&
                        cpu_valid && cpu_ready && can_accept_cpu &&
                        (vipt_probe_set == cpu_preread_set) &&
                        (vipt_probe_word == cpu_preread_word);
assign vipt_probe_accepted = vipt_probe_fire || vipt_probe_share;
// Replay is mutually exclusive with a demand request and therefore cannot
// use the address-qualified sharing arm.  Expose the direct acceptance fact
// so its EX capture does not inherit the paging preread address cone.
assign vipt_probe_direct_accepted = vipt_probe_fire;
wire [SET_BITS-1:0] preread_set =
    vipt_probe_fire ? vipt_probe_set : cpu_preread_set;
wire [WORD_OFFSET_BITS-1:0] preread_word =
    vipt_probe_fire ? vipt_probe_word : cpu_preread_word;
wire [BRAM_ADDR_BITS-1:0] preread_bram_addr = {preread_set, preread_word};
// A store that hits patches the line even while the cache is disabled, so the
// cache stays coherent and can be re-enabled without a flush.
wire data_store_write = (state == S_LOOKUP) && req_valid_r && req_write_r &&
                        !req_protect_write_r && lookup_hit;
wire data_fill_write = (state == S_FILL) && !fill_tag_wait_r && !fill_killed_r &&
                       !fill_set_snooped_r && !fill_set_snooped_now &&
                       (mem_resp_valid || wide_fill_install);
wire [1:0] data_write_way = data_store_write ? lookup_way : fill_way;

always_ff @(posedge clk) begin
    if (reset)
        patch_fwd_valid_r <= 1'b0;
    else
        patch_fwd_valid_r <= data_store_write;
    patch_fwd_way_r <= lookup_way;
    patch_fwd_addr_r <= {req_set_r, req_word_r};
    patch_fwd_data_r <= merge32(lookup_way_data, req_din_r, req_be_r);
end

// synthesis translate_off
// A valid demand request always owns the preread, so a pipelined store never
// shares the RAM read port with a VIPT probe.
always @(posedge clk)
    if (!reset && lookup_wr_accept && !cpu_preread_priority)
        $fatal(1, "L1 pipelined store accepted without preread priority");
// The per-way patch pick equals the patch decision taken after the way mux.
always @(posedge clk)
    if (!reset && ((lookup_way_data != (patch_fwd_hit ? patch_fwd_data_r : lookup_way_ram_data)) ||
                   (vipt_way_data != (vipt_patch_fwd_hit ? patch_fwd_data_r : vipt_way_ram_data))))
        $fatal(1, "L1 WAY-PATCH FUSE MISMATCH: lookup=%08x vipt=%08x", lookup_way_data, vipt_way_data);
// synthesis translate_on
wire [BRAM_ADDR_BITS-1:0] data_write_addr = data_store_write ?
                                            req_bram_addr :
                                            {fill_set, fill_count};
wire [31:0] data_write_value = data_store_write ?
                               merge32(lookup_way_data, req_din_r, req_be_r) :
                               wide_fill_install ?
                               wide_fill_line[{fill_count, 5'b0} +: 32] :
                               fill_word_data;

// Keep each tag array in one conventional synchronous-read/synchronous-write
// process. Quartus 17 will not infer a block RAM when the packed valid bit is
// written from the snoop, reset-init, and fill branches of the cache FSM.
wire tag_fill_write = (state == S_FILL) && !snoop_valid_r && !fill_killed_r &&
                      !fill_set_snooped_r && !fill_set_snooped_now &&
                      (fill_tag_wait_r || ((mem_resp_valid || wide_fill_install) &&
                       (fill_count == {WORD_OFFSET_BITS{1'b1}})));
// A snoop to ANY set owns all four way write ports. If a fill completes on
// that edge, defer its tag install, not the snoop: otherwise the fill's way
// retains a stale valid tag in the snooped set. The sweep also yields to a
// snoop; a flushed fill is killed, so it cannot fight the sweep's clear.
wire flush_sweep_w = flush_busy_r && !snoop_valid_r;
wire tag_clear_all = (state == S_RESET_INIT) || snoop_valid_r || flush_sweep_w;
wire [SET_BITS-1:0] tag_clear_set = (state == S_RESET_INIT) ? init_set :
                                    snoop_valid_r ? snoop_set_r : flush_set_r;
wire [TAG_RAM_BITS-1:0] tag_fill_entry =
    {{(TAG_RAM_BITS-TAG_BITS-1){1'b0}}, 1'b1, fill_tag};
wire tag_fill_way0 = tag_fill_write && (fill_way == 2'd0);
wire tag_fill_way1 = tag_fill_write && (fill_way == 2'd1);
wire tag_fill_way2 = tag_fill_write && (fill_way == 2'd2);
wire tag_fill_way3 = tag_fill_write && (fill_way == 2'd3);
// The set-wide clear against the preread set, compared per candidate and
// picked by vipt_probe_fire last, so the CPU set (the issuing EA's page-offset
// bits) reaches rd_invalidated_r through one compare instead of through the
// preread_set select that also drives every RAM address.
// tests/equiv/preread_clear_pick.v proves it equal to
// tag_clear_all && (tag_clear_set == preread_set).
wire preread_clear_hit = tag_clear_all &&
                         (vipt_probe_fire ? (tag_clear_set == vipt_probe_set)
                                          : (tag_clear_set == cpu_preread_set));

always_ff @(posedge clk) begin
    if (idle_preread || lookup_wr_preread || vipt_probe_fire) begin
        rd_tag_entry0_r <= tag_way0[preread_set];
        rd_tag_entry1_r <= tag_way1[preread_set];
        rd_tag_entry2_r <= tag_way2[preread_set];
        rd_tag_entry3_r <= tag_way3[preread_set];
        rd_data0_r <= data_way0[preread_bram_addr];
        rd_data1_r <= data_way1[preread_bram_addr];
        rd_data2_r <= data_way2[preread_bram_addr];
        rd_data3_r <= data_way3[preread_bram_addr];
        rd_plru_r <= plru_set[preread_set];
        // The clear is set-wide, so a read launched on the same edge returns
        // valid entries for every way of that set.  Mask them next cycle.
        rd_invalidated_r <= (preread_clear_hit ||
                             (idle_preread && !vipt_probe_fire && cpu_force_bus))
                            ? 4'b1111 : 4'b0000;
    end

    // A single process for both ports is recognized as simple dual-port RAM
    // by Vivado and Quartus. The former split-process task form mapped the
    // cache storage to registers in Vivado.
    if (data_store_write || data_fill_write) begin
        case (data_write_way)
            2'd0: data_way0[data_write_addr] <= data_write_value;
            2'd1: data_way1[data_write_addr] <= data_write_value;
            2'd2: data_way2[data_write_addr] <= data_write_value;
            default: data_way3[data_write_addr] <= data_write_value;
        endcase
    end

    if (tag_clear_all || tag_fill_way0)
        tag_way0[tag_fill_way0 ? fill_set : tag_clear_set] <=
            tag_fill_way0 ? tag_fill_entry : '0;
    if (tag_clear_all || tag_fill_way1)
        tag_way1[tag_fill_way1 ? fill_set : tag_clear_set] <=
            tag_fill_way1 ? tag_fill_entry : '0;
    if (tag_clear_all || tag_fill_way2)
        tag_way2[tag_fill_way2 ? fill_set : tag_clear_set] <=
            tag_fill_way2 ? tag_fill_entry : '0;
    if (tag_clear_all || tag_fill_way3)
        tag_way3[tag_fill_way3 ? fill_set : tag_clear_set] <=
            tag_fill_way3 ? tag_fill_entry : '0;
end

always_ff @(posedge clk) begin
    if (reset) begin
        state <= S_RESET_INIT;
        init_set <= {SET_BITS{1'b0}};
        req_valid_r <= 1'b0;
        ready_r <= 1'b0;
        resp_valid_r <= 1'b0;
        dout_r <= 32'h0;
        mem_valid_r <= 1'b0;
        mem_write_r <= 1'b0;
        mem_addr_r <= 32'h0;
        mem_din_r <= 32'h0;
        mem_be_r <= 4'h0;
        mem_burstcount_r <= 8'h0;
        storeq_head <= {STOREQ_IDX_BITS{1'b0}};
        storeq_tail <= {STOREQ_IDX_BITS{1'b0}};
        storeq_count <= {STOREQ_CNT_BITS{1'b0}};
        storeq_draining <= 1'b0;
        lookup_wr_room_r <= 1'b0;
        fill_requested <= 1'b0;
        fill_target_returned <= 1'b0;
        wide_fill_line <= 128'd0;
        wide_fill_install <= 1'b0;
        fill_tag_wait_r <= 1'b0;
        fill_killed_r <= 1'b0;
        snoop_set_r <= {SET_BITS{1'b0}};
        snoop_valid_r <= 1'b0;
        fill_set_snooped_r <= 1'b0;
        for (integer i = 0; i < STOREQ_DEPTH; i = i + 1)
            storeq_valid[i] <= 1'b0;
        flush_req_seen_r <= 1'b0;
        flush_pending_r <= 1'b0;
    end else begin
        ready_r <= (state == S_IDLE) && ready_when_idle;
        resp_valid_r <= 1'b0;
        flush_req_seen_r <= flush_req;
        if (flush_launch)
            flush_pending_r <= 1'b0;
        else if (flush_req_new)
            flush_pending_r <= 1'b1;
        snoop_valid_r <= snoop_valid;
        if (snoop_valid)
            snoop_set_r <= snoop_set;

        if (mem_valid_r && mem_ready)
            mem_valid_r <= 1'b0;

        // A fill in flight when a flush is armed must not install after the
        // sweep: the sweep runs concurrently with it (it may be blocked on the
        // bus), so the install is suppressed rather than waited out.  The mark
        // sticks until the fill ends.
        if (state != S_FILL) begin
            fill_killed_r <= 1'b0;
            fill_set_snooped_r <= 1'b0;
        end else begin
            // A snoop clears the whole set; any fill in that set is invalid.
            // The mark sticks until the fill ends so a later word of the same
            // fill cannot reinstate the tag either.
            if (snoop_valid_r && (snoop_set_r == fill_set))
                fill_set_snooped_r <= 1'b1;
            if (flush_req_new || flush_pending_r || flush_busy_r)
                fill_killed_r <= 1'b1;
        end

        if (storeq_draining && mem_ready) begin
            storeq_valid[storeq_tail] <= 1'b0;
            storeq_tail <= storeq_next_idx(storeq_tail);
            storeq_count <= storeq_count - 1'b1;
            storeq_draining <= 1'b0;
        end

        // FSM-independent store-queue drain launch (see drain_issue_now).
        if (drain_issue_now) begin
            mem_valid_r <= 1'b1;
            mem_write_r <= 1'b1;
            mem_addr_r <= {storeq_addr[storeq_tail], 2'b00};
            // A same-cycle merge into this very entry (drain_merge_now) must
            // reach memory: latch the merged data/be, matching what the
            // storeq entry itself is updated to this cycle.
            mem_din_r <= drain_merge_now
                       ? merge32(storeq_data[storeq_tail], req_din_r, req_be_r)
                       : storeq_data[storeq_tail];
            mem_be_r <= drain_merge_now ? (storeq_be[storeq_tail] | req_be_r)
                                        : storeq_be[storeq_tail];
            mem_burstcount_r <= 8'd1;
            storeq_draining <= 1'b1;
        end

        case (state)
            S_RESET_INIT: begin
                plru_set[init_set] <= 3'b000;
                if (init_set == LAST_SET) begin
                    state <= S_IDLE;
                    ready_r <= ready_when_idle;
                end else begin
                    init_set <= init_set + 1'b1;
                end
            end

            S_IDLE: begin
                // Wide request captures run on every ready cycle, with no
                // cpu_valid/TLB gating: garbage is captured when nothing is
                // accepted, but S_LOOKUP (the only consumer) is entered on
                // accept_cpu alone.  Keeps the TLB cone off these enables.
                if (ready_r) begin
                    req_addr_r <= cpu_addr;
                    req_din_r <= cpu_din;
                    req_be_r <= cpu_be;
                    req_write_r <= cpu_write;
                    req_uncacheable_r <= request_uncacheable;
                    req_nw_r <= cache_nw;
                    req_protect_write_r <= cpu_protect_write;
                    req_tag_r <= cpu_tag;
                    req_set_r <= cpu_set;
                    req_word_r <= cpu_word;
                end
                if (accept_cpu) begin
                    ready_r <= 1'b0;
                    req_valid_r <= 1'b1;
                    state <= S_LOOKUP;
                end
                lookup_wr_room_r <= (storeq_count <= STOREQ_CNT_BITS'(STOREQ_DEPTH - 2)) &&
                                    !cache_nw;
            end

            S_LOOKUP: begin
                req_valid_r <= 1'b0;

                if (req_protect_write_r) begin
                    state <= S_IDLE;
                    ready_r <= ready_when_idle;
                end else if (req_write_r && req_nw_r) begin
                    // CR0.NW=1: a hit is written to the line above
                    // (data_store_write) and never reaches memory; only a
                    // miss is queued, one cycle later from registered state.
                    if (lookup_hit)
                        plru_set[req_set_r] <= plru_update(rd_plru_r, lookup_way);
                    nw_hit_r <= lookup_hit;
                    state <= S_NW_WRITE;
                end else if (req_write_r) begin
                    // Store-queue enqueue, moved here from the accept cycle so
                    // its enables come from registered request state instead of
                    // the TLB-gated accept.  All inputs are req_*_r registers.
                    if (storeq_merge_lookup) begin
                        // Same-DWORD coalescing: fold into the newest entry.
                        storeq_data[storeq_prev] <= merge32(storeq_data[storeq_prev], req_din_r, req_be_r);
                        storeq_be[storeq_prev] <= storeq_be[storeq_prev] | req_be_r;
                    end else begin
                        storeq_addr[storeq_head] <= req_addr_r[31:2];
                        storeq_data[storeq_head] <= req_din_r;
                        storeq_be[storeq_head] <= req_be_r;
                        storeq_valid[storeq_head] <= 1'b1;
                        storeq_head <= storeq_next_idx(storeq_head);
                    end
                    storeq_count <= storeq_count_wr_next;
                    if (lookup_hit && !req_uncacheable_r) begin
                        plru_set[req_set_r] <= plru_update(rd_plru_r, lookup_way);
                    end
                    // Capture the pipelined store like S_IDLE does: on the
                    // registered opening, not on the TLB-qualified accept.
                    if (lookup_wr_open) begin
                        req_addr_r <= cpu_addr;
                        req_din_r <= cpu_din;
                        req_be_r <= cpu_be;
                        req_write_r <= cpu_write;
                        req_uncacheable_r <= request_uncacheable;
                        req_nw_r <= cache_nw;
                        req_protect_write_r <= cpu_protect_write;
                        req_tag_r <= cpu_tag;
                        req_set_r <= cpu_set;
                        req_word_r <= cpu_word;
                    end
                    lookup_wr_room_r <= (storeq_count_wr_next <=
                                         STOREQ_CNT_BITS'(STOREQ_DEPTH - 2)) &&
                                        !cache_nw;
                    if (lookup_wr_accept) begin
                        req_valid_r <= 1'b1;
                        ready_r <= 1'b0;
                    end else begin
                        state <= S_IDLE;
                        ready_r <= (storeq_count_wr_next != STOREQ_DEPTH_VALUE);
                    end
                end else if (lookup_hit) begin
                    plru_set[req_set_r] <= plru_update(rd_plru_r, lookup_way);
                    state <= S_IDLE;
                    ready_r <= ready_when_idle;
                end else if (req_uncacheable_r) begin
                    if (storeq_empty && !storeq_draining && !mem_valid_r && !mem_busy) begin
                        mem_valid_r <= 1'b1;
                        mem_write_r <= 1'b0;
                        mem_addr_r <= req_addr_r;
                        mem_din_r <= 32'h0;
                        mem_be_r <= req_be_r;
                        mem_burstcount_r <= 8'd1;
                        state <= S_BYPASS_WAIT;
                    end
                end else begin
                    fill_set <= req_set_r;
                    fill_tag <= req_tag_r;
                    fill_way <= plru_victim(rd_plru_r);
                    fill_plru_r <= rd_plru_r;
                    fill_count <= {WORD_OFFSET_BITS{1'b0}};
                    fill_target_word <= req_word_r;
                    fill_requested <= 1'b0;
                    fill_target_returned <= 1'b0;
                    wide_fill_install <= 1'b0;
                    fill_tag_wait_r <= 1'b0;
                    state <= S_FILL;
                end
            end

            S_FILL: begin
                if (!fill_requested && !mem_valid_r && !mem_busy) begin
                    mem_valid_r <= 1'b1;
                    mem_write_r <= 1'b0;
                    mem_addr_r <= {req_addr_r[31:4], 4'b0000};
                    mem_din_r <= 32'h0;
                    mem_be_r <= 4'hF;
                    mem_burstcount_r <= 8'd4;
                    fill_requested <= 1'b1;
                end

                if (fill_tag_wait_r) begin
                    if (!snoop_valid_r) begin
                        if (tag_fill_write)
                            plru_set[fill_set] <= plru_update(fill_plru_r, fill_way);
                        fill_tag_wait_r <= 1'b0;
                        state <= S_IDLE;
                        ready_r <= ready_when_idle;
                    end
                end else if (wide_fill_install) begin
                    if (fill_count == {WORD_OFFSET_BITS{1'b1}}) begin
                        wide_fill_install <= 1'b0;
                        if (snoop_valid_r) begin
                            fill_tag_wait_r <= 1'b1;
                        end else begin
                            if (tag_fill_write)
                                plru_set[fill_set] <= plru_update(fill_plru_r, fill_way);
                            state <= S_IDLE;
                            ready_r <= ready_when_idle;
                        end
                    end
                    fill_count <= fill_count + 1'b1;
                end else if (mem_line_resp_valid) begin
                    wide_fill_line <= wide_line_data;
                    wide_fill_install <= 1'b1;
                    dout_r <= wide_line_data[{fill_target_word, 5'b0} +: 32];
                    resp_valid_r <= 1'b1;
                    fill_target_returned <= 1'b1;
                end else if (mem_resp_valid) begin
                    if (fill_count == fill_target_word && !fill_target_returned) begin
                        dout_r <= fill_word_data;
                        resp_valid_r <= 1'b1;
                        fill_target_returned <= 1'b1;
                    end

                    if (fill_count == {WORD_OFFSET_BITS{1'b1}}) begin
                        if (snoop_valid_r) begin
                            fill_tag_wait_r <= 1'b1;
                        end else begin
                            if (tag_fill_write)
                                plru_set[fill_set] <= plru_update(fill_plru_r, fill_way);
                            state <= S_IDLE;
                            ready_r <= ready_when_idle;
                        end
                    end
                    fill_count <= fill_count + 1'b1;
                end
            end

            S_NW_WRITE: begin
                // The store was accepted with queue capacity reserved, and
                // nothing else enqueues before it.  No coalescing here.
                if (!nw_hit_r) begin
                    storeq_addr[storeq_head] <= req_addr_r[31:2];
                    storeq_data[storeq_head] <= req_din_r;
                    storeq_be[storeq_head] <= req_be_r;
                    storeq_valid[storeq_head] <= 1'b1;
                    storeq_head <= storeq_next_idx(storeq_head);
                    storeq_count <= storeq_dequeuing ? storeq_count
                                                     : storeq_count + 1'b1;
                    ready_r <= !flush_block &&
                               ((storeq_dequeuing ? storeq_count
                                                  : storeq_count + 1'b1) !=
                                STOREQ_DEPTH_VALUE);
                end else begin
                    ready_r <= ready_when_idle;
                end
                state <= S_IDLE;
            end

            S_BYPASS_WAIT: begin
                // synthesis translate_off
                if (!storeq_empty)
                    $fatal(1, "l1_cache: store queue not empty during an uncached read");
                // synthesis translate_on
                if (mem_resp_valid) begin
                    dout_r <= bypass_forward_data;
                    resp_valid_r <= 1'b1;
                    state <= S_IDLE;
                    ready_r <= ready_when_idle;
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
// One set per cycle, independent of the fill FSM, so the flush completes even
// while a fill is blocked on the bus.  A registered snoop's clear writes a
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

// synthesis translate_off
reg vipt_probe_share_r = 1'b0;
always_ff @(posedge clk) vipt_probe_share_r <= !reset && vipt_probe_share;
always_ff @(posedge clk) begin
    if (!reset && state != S_RESET_INIT && cpu_valid && !cpu_ready && !(state == S_IDLE))
        ;
    // A VIPT probe sharing an accepted store's preread resolves while that
    // registered store is in S_LOOKUP. vipt_lookup_store_match forwards the
    // store payload over the preread result, so this is an intentional second
    // legal finalize state rather than a cache ownership collision. A
    // protected (ROM-window) store leaves S_LOOKUP without touching the RAM
    // and is not forwarded, so the probe reads the unchanged data.
    // A resolve that used a shared preread must find that store in S_LOOKUP,
    // where vipt_lookup_store_match merges its bytes over the older read.
    if (!reset && vipt_resolve_valid && vipt_probe_share_r &&
        !(state == S_LOOKUP && req_valid_r && req_write_r))
        $fatal(1, "VIPT resolve of a shared preread without its store in S_LOOKUP");
    if (!reset && vipt_resolve_valid && state != S_IDLE &&
        !(state == S_LOOKUP && req_valid_r && req_write_r) &&
        !(state == S_NW_WRITE))
        $fatal(1, "VIPT resolve while cache is not idle");
end
// synthesis translate_on

endmodule

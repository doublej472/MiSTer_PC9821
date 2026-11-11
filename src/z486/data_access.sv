//
// Data Access Pipeline
// Direct loads, microcode reads, RMW and direct stores through the L1 probe port and sidecar TLB
//
`include "z486_platform.svh"
`default_nettype none
module data_access
    import z486_pkg::*;
(
    // Clock and reset
    input  logic                    clk,
    input  logic                    reset_n,
    // L1 data cache: probe/resolve port and direct store port
    input  logic                    dcache_vipt_probe_accepted,
    input  logic                    dcache_vipt_probe_direct_accepted,
    input  logic                    dcache_vipt_probe_ready,
    input  logic [31:0]             dcache_vipt_resolve_data,
    input  logic                    dcache_vipt_resolve_hit,
    input  logic                    dcache_wr_ready,
    // Any template memory-map window enabled (z486_cache_map_pkg).  The posted
    // store path below then has to classify the store instead of assuming the
    // hard-coded PC/AT map.
    input  logic                    memmap_windows,
    // With windows: the sidecar page's posted-store verdict (z486.sv, from the
    // compile-time template): the page is cacheable RAM now.
    input  logic                    memmap_post_ok,
    output logic [19:0]             sidecar_page,
    input  logic                    fast_store_accepted,
    output logic [11:0]             dcache_vipt_probe_offset,
    output logic                    dcache_vipt_probe_valid,
    output logic [31:0]             dcache_vipt_resolve_phys_addr,
    // dcache_vipt_resolve_phys_addr's two arms and the late select between them
    // (the VIPT TLB hit), so the D-cache tag compare runs on both arms in
    // parallel with the TLB's own compare (l1_cache vipt_hit_vec).
    output logic [31:0]             dcache_vipt_resolve_tlb_phys,
    output logic [31:0]             dcache_vipt_resolve_alt_phys,
    output logic                    dcache_vipt_resolve_use_tlb,
    output logic                    dcache_vipt_resolve_valid,
    output logic [3:0]              fast_store_be,
    output logic                    fast_store_valid,
    output logic [31:0]             fast_store_wdata,
    output logic [31:0]             rmw_fast_phys_r,
    output logic [31:0]             st_phys,
    output logic                    st_route,
    output logic                    st_take,
    // Paging unit and sidecar TLB
    input  logic [31:0]             CR0,
    input  logic                    mem_accepted,
    input  logic                    mem_servicing,
    input  logic                    paging_demand_idle,
    input  logic [1:0]              pg_cpl,
    input  logic                    vipt_tlb_dirty,
    input  logic                    vipt_tlb_hit,
    input  logic                    vipt_tlb_is_vga_mem,
    input  logic [31:0]             vipt_tlb_phys_addr,
    input  logic [31:0]             vipt_tlb_phys_hit_form,
    input  logic [31:0]             vipt_tlb_phys_miss_form,
    input  logic                    vipt_tlb_user,
    input  logic                    vipt_tlb_writable,
    output logic                    sidecar_bg_pre,
    output logic                    st_tlb_pre,
    output logic [1:0]              ucrd_cpl_r,
    output logic                    ucrd_hit,
    output logic [31:0]             ucrd_linear_r,
    output logic                    ucrd_phys_ok_r,
    output logic [31:0]             ucrd_phys_r,
    output logic                    ucrd_route_pre,
    output logic [1:0]              ucrd_size_r,
    output logic                    ucrd_slow_req_r,
    output logic                    ucrd_slow_submit,
    output logic                    ucrd_slow_wait_r,     // missed: in paging
    output logic                    ucrd_take,            // a microcode read probes now
    output logic                    ucrd_x87_r,
    output hardwired_load_payload_t vipt_load_slow_r,
    output logic [31:0]             vipt_probe_linear,
    output logic                    vipt_slow_addr_owned,
    output logic                    vipt_slow_phys_ok_r,
    output logic [31:0]             vipt_slow_phys_r,
    output logic                    vipt_slow_submit,
    output logic [1:0]              dir_access_size,
    output logic                    vipt_slow_seg_trigger,
    output logic                    vipt_load_slow_ssf_r,
    // Address and segmentation units
    input  logic                    ds_flat,
    input  logic [31:0]             ind_linear,
    input  logic                    ind_linear_valid,
    input  logic [31:0]             issue_ind_linear,
    input  logic [1:0]              issue_ind_linear_low,
    input  logic [31:0]             issue_load_linear,
    input  logic [1:0]              issue_load_low,
    input  logic [31:0]             issue_mem_linear,
    input  logic                    pe,
    input  logic                    vm,
    input  logic                    seg_gp_fault,
    input  logic                    dir_seg_fault,
    input  logic                    dir_rmw_fault,
    input  logic                    ss_segment_fault,
    input  logic                    ss_flat32,
    input  logic [5:0]              seg_readable,     // per segment: a read needs no microcode check
    // Data unit: load writeback and operands
    input  logic [31:0]             forwarded_esp,
    input  logic [31:0]             mem_wdata,
    input  logic [31:0]             OPR_R,
    input  logic [31:0]             SIGMA,
    output logic                    direct_wb_retire,
    output logic                    fast_opr_commit,
    output logic [31:0]             fast_opr_data,
    output logic                    vipt_load_alu_dst_capture,
    output logic [31:0]             vipt_load_alu_dst_capture_data,
    output logic [2:0]              vipt_load_alu_dst_capture_dst,
    output logic [1:0]              vipt_load_alu_dst_capture_size,
    output logic [4:0]              vipt_load_wb_alu_op_r,
    output logic [31:0]             vipt_load_wb_data,
    output logic [7:0]              vipt_load_wb_dst_onehot_r,
    output logic [2:0]              vipt_load_wb_dst_r,
    output logic                    vipt_load_wb_is_alu_r,
    output logic [1:0]              vipt_load_wb_size_r,
    output logic [31:0]             vipt_load_wb_target_r,
    output logic                    vipt_load_wb_valid_r,
    // The write-back's byte-normalized GPR one-hot, gated by its valid:
    // = vipt_load_wb_valid_r ? 8'h01 << norm(dst, size) : 0, every cycle.
    output logic [7:0]              vipt_load_wb_wmask_r,
    // The write-back's forwarding-view hits per GPR byte, [r*4 + b]: valid, not
    // an M3 ALU result, register r = norm(dst, size), byte b in its lanes
    // (gpr_write_merge hitv3), registered with the write-back.
    output logic [31:0]             vipt_load_wb_view_hit_r,
    // The write-back's AH lane select for gpr_write_merge's pv3f:
    // (vipt_load_wb_size_r == 0) && vipt_load_wb_dst_r[2], loaded on exactly
    // the edges vipt_load_wb_dst_r/_size_r are, from the same sources, so it
    // equals that decode every cycle (tests/equiv/producer_ah_reg.v).
    output logic                    vipt_load_wb_ah_r,
    // D2 instruction and issue
    input  logic                    d2_vipt_ea_hazard,
    // An older deferred memory token owns this load's destination and its
    // optimistic read already missed (mem_opt_wait), so OPR_R is stale until the
    // fill returns: route the younger direct load through the slow path.
    input  logic                    vipt_load_ex_token_pending,
    input  logic [31:0]             EIP,
    input  logic                    hardwired_off,
    input  dec_entry_t              i_bus,
    input  logic                    i_issue,
    input  logic                    single_step,
    // Alignment checking or a debug breakpoint needs every data access on
    // the microcode path: hold the direct load and RMW pipelines off.
    input  logic                    direct_hold,
    input  logic                    locked_insn,      // the executing instruction locks the bus
    output logic                    d2_plain_load_overlap_ready,
    output logic                    d2_vipt_candidate,
    output logic                    d2_vipt_load,
    output logic                    d2_vipt_pipe_ready,
    output logic                    d2_vipt_pop,
    output logic                    d2_vipt_ret,
    output logic                    d2_vipt_rmw,
    output logic                    d2_vipt_rmw_candidate,
    output logic                    vipt_issue_load,
    // Microsequencer and core control
    input  logic                    any_fault,
    input  logic                    gp_fault_trigger,
    input  dec_entry_t              i_ex,
    input  logic                    i_first,
    input  logic                    i_rni_delay,
    input  logic                    interrupt_entry,
    input  logic [1:0]              mem_eff_size,
    input  logic                    mem_is_io,
    input  logic                    mem_op_eligible,
    input  logic                    q_flush,
    input  logic                    stall,
    input  logic                    stall_invlpg,
    input  logic                    stall_wio,
    input  logic                    stall_x87_direct,
    input  logic                    uc_active,
    input  logic                    rmw_fallback_release,
    input  logic [5:0]              uc_buscode,
    input  logic                    uc_busreq,
    input  logic                    uc_data_busreq,
    input  logic                    uc_exec,
    input  logic                    uc_is_check_write,
    input  logic                    uc_is_mem_busop,
    input  logic                    uc_is_write,
    input  logic                    uc_p_pure_dly,
    input  logic                    uc_bus_or_dly,      // this uop is a bus op or a DLY (uc[38])
    input  logic                    x87_direct_mem_req,
    output logic                    pop_direct_r,
    output logic                    rd_fast_finish,
    output logic                    rd_fast_valid_r,
    output logic                    ret_redirect,
    output logic                    rmw_fallback_delay_r,
    output logic                    rmw_fast_active_r,
    output logic                    stall_fast_store,
    output logic                    stall_rmw_probe,
    output logic                    stall_ucrd,
    output logic                    vipt_load_ex_probed_r,
    output hardwired_load_token_t   vipt_load_ex_r,
    output logic                    vipt_load_exec_block,
    output hardwired_load_token_t   vipt_load_replay_r,
    output logic                    vipt_load_slow_busy,
    output logic                    vipt_load_slow_wait_r
);

wire        vipt_load_ex_hit;
reg        vipt_load_wb_ret_r;         // the retiring load is a RET
wire [31:0] d2_ret_esp;                // the RET's ESP after its pop (and imm16)
wire       d2_vipt_alu;                // ALU register,memory via registered VIPT data
wire       d2_vipt_older_store;         // Current EX uop must enter paging before a younger load
wire [2:0] d2_vipt_dst;
wire [7:0] d2_vipt_dst_onehot;
wire [1:0] d2_vipt_mem_size;
wire [1:0] d2_vipt_write_size;
hardwired_load_result_t d2_vipt_result_kind;
reg        vipt_load_slow_req_r;
reg        vipt_load_slow_segf_r;
assign     ret_redirect = vipt_load_wb_valid_r && vipt_load_wb_ret_r;
reg [31:0] vipt_load_wb_data_r;
reg        vipt_load_overlap_r;        // Plain-load successor owns EX while load completes
// A direct load that crosses a dword boundary inside one 16-byte line (a word
// at byte 3, a dword at byte 1..3 of its dword) reads its two dwords on the
// probe/resolve pipeline, as the i486 runs a misaligned cache hit as two
// cache cycles (Intel i486 Microprocessor data book, instruction timing
// assumptions: misaligned operands add 3 clocks) instead of taking paging's
// crossing path (about 8.5 clocks more).  The first resolve keeps the low
// dword and steps the token's word address; the EX re-probe reads the next
// dword, and its resolve completes the load from both.  The limit and every
// translation term are the first resolve's: both dwords sit in one line, so
// in one page.  A second resolve that misses falls back to paging with the
// original address.
reg        vipt_x2_r;                  // EX token waits for its second dword
reg [31:0] vipt_x2_lo_r;               // the first dword
assign vipt_load_slow_busy = vipt_load_slow_req_r || vipt_load_slow_wait_r;
wire       vipt_load_busy = vipt_load_ex_r.valid || vipt_load_replay_r.valid ||
                            vipt_load_slow_busy || vipt_load_wb_valid_r;
wire       vipt_load_retire;

// Microcode reads on the probe/resolve pipeline: the set is preread in the RD
// cycle and translation and tag finalize the next (the L1 contract), so no
// live TLB lookup sits in the RD cycle. A miss goes to paging's registered
// path.
reg        ucrd_valid_r;               // probed last cycle; resolves now
// A bus read updates OPR_R no earlier than the routine's next bus or DLY
// uop, and the microcode relies on it: LD_DESCRIPTOR reads the second
// descriptor dword while the uops before its DLY still use the first. A hit
// resolving under any other uop holds its data and commits at that next bus
// or DLY uop (or at the end of the instruction); a bus uop that finds it held
// waits one cycle, as it would wait for the slow path's read (upstream 3b27dd0).
reg        ucrd_held_r;
reg [31:0] ucrd_held_data_r;
// A first-uStep or x87 read stops every uop after a miss (its DLY may fold
// the RNI), as does a read whose DLY passed the resolve cycle. Otherwise a
// missed read in a routine is a bus read in flight: only bus and DLY uops,
// and the instruction's delay slot, wait for OPR_R.
reg        ucrd_strict_r;
// The linear page of the last microcode read that missed the L1.  A read
// past the first uStep (or a first-uStep read that is not its EA read, the
// only kind that probed before) skips the probe on that page and enters
// paging directly: a device window (VRAM, the PC-98 template's uncached
// classes) never hits, and a cold page streams through paging's line fill,
// so probing first would only add the probe/resolve cycles to every element
// of a REP MOVS/LODS over it.  Any probe that hits that physical page (a direct
// load, a first-uStep EA read) shows the page is cached again and clears the
// entry.  Only a hint: either path is correct.
reg        ucrd_nohit_valid_r;
reg [19:0] ucrd_nohit_page_r;
reg [19:0] ucrd_nohit_phys_r;          // its physical page: a later L1 hit there clears it
wire       ucrd_old_class = i_first && i_ex.ind_is_ea;
wire       ucrd_nohit_skip = !ucrd_old_class && ucrd_nohit_valid_r &&
                             (ind_linear[31:12] == ucrd_nohit_page_r);
wire       ucrd_miss_busy = ucrd_slow_req_r || ucrd_slow_wait_r;
// In the resolve cycle a uop with side effects runs only when the read's
// translation was already known good in the RD cycle (the sidecar held its
// page), so no fault can follow; a bus operation always waits, keeping
// memory order behind a possible miss. After a miss every uop waits until
// OPR_R is written.
reg        ucrd_tlbok_r;               // the read's translation was known good
// A pure DLY may pass the resolve cycle only when the read cannot leave the
// fast path's translation (known good): after a TLB miss it waits like any
// uop, or a DLY that folds its instruction's RNI (MOV r,m) retires and the
// delay slot copies a stale OPR_R before the slow path returns or faults.
assign stall_ucrd = (ucrd_valid_r && (!ucrd_tlbok_r || (!uc_p_pure_dly && uc_busreq))) ||
                        (ucrd_held_r && uc_bus_or_dly && !uc_p_pure_dly) ||
                        (ucrd_miss_busy && (ucrd_strict_r || uc_bus_or_dly || i_rni_delay));
wire       ucrd_busy = ucrd_valid_r || ucrd_held_r || ucrd_miss_busy;
reg        rd_fast_probed_r;            // D2 preread was accepted
reg [31:0] rd_fast_linear_r;
reg [1:0]  rd_fast_size_r;
reg [1:0]  rd_fast_lane_r;
reg [1:0]  rmw_fast_size_r;
reg [1:0]  rmw_fast_lane_r;
// Direct store port into the L1, shared by WR_FAST and first-uStep stores
// translated in D2 (the sidecar TLB prereads the store's address at issue, so
// the WR cycle has a registered translation and needs no paging cycle).
reg        sidecar_valid_r;            // the sidecar holds a translation for
reg [19:0] sidecar_page_r;             //   this linear page
wire [3:0] st_be;
wire [31:0] st_wdata;
wire       rmw_store_valid = rmw_fast_active_r && i_rni_delay;
wire       rmw_store_accepted = rmw_store_valid && fast_store_accepted;
assign fast_store_valid = rmw_store_valid || st_take;
assign fast_store_be = st_take ? st_be : calc_be(rmw_fast_size_r, rmw_fast_lane_r);
assign fast_store_wdata = st_take ? st_wdata : (SIGMA << {rmw_fast_lane_r, 3'b000});
assign stall_fast_store = rmw_store_valid && !fast_store_accepted;
// A qualified RMW whose D2 preread was denied (for example by an older store
// still in L1 lookup in the same set) holds its overlay entry uStep and
// replays the preread from the registered linear address, instead of taking
// the full original-routine fallback. The select terms are registered.
assign stall_rmw_probe = rd_fast_valid_r && !rd_fast_probed_r && i_first;
assign direct_wb_retire = vipt_load_retire;

function automatic [31:0] format_hardwired_load(
    input [31:0] raw,
    input [1:0] lane,
    input [1:0] mem_size,
    input hardwired_load_result_t result_kind
);
    logic [31:0] shifted;
    begin
        shifted = raw >> {lane, 3'b000};
        case (mem_size)
            2'd0: begin
                case (result_kind)
                    LOAD_RESULT_SIGN_EXTEND:
                        format_hardwired_load = {{24{shifted[7]}}, shifted[7:0]};
                    default:
                        format_hardwired_load = {24'd0, shifted[7:0]};
                endcase
            end
            2'd1: begin
                case (result_kind)
                    LOAD_RESULT_SIGN_EXTEND:
                        format_hardwired_load = {{16{shifted[15]}}, shifted[15:0]};
                    default:
                        format_hardwired_load = {16'd0, shifted[15:0]};
                endcase
            end
            default: format_hardwired_load = shifted;
        endcase
    end
endfunction

assign vipt_load_wb_data = vipt_load_wb_data_r;

// The EX token's load data: its first dword (a crossing token's kept low
// dword) under the resolving dword, shifted down from its byte lane.  A
// contained access needs no byte above the resolving dword, so the upper
// half's content is masked away by its size.
wire [31:0] vipt_ex_raw = vipt_x2_r ? vipt_x2_lo_r : dcache_vipt_resolve_data;
wire [63:0] vipt_ex_pair = {dcache_vipt_resolve_data, vipt_ex_raw};
wire [31:0] vipt_ex_word = vipt_ex_pair[{vipt_load_ex_r.lane, 3'b000} +: 32];

// An occupied EX stage may accept only another direct load. If the older load
// misses, the accepted younger token moves to the replay slot on this edge.
assign d2_vipt_pipe_ready = d2_vipt_candidate &&
                                dcache_vipt_probe_ready &&
                                vipt_load_ex_probed_r &&
                                !vipt_load_replay_r.valid &&
                                !vipt_load_slow_busy && !single_step;
// Once a plain load has finalized as a hit, its successor may enter EX on the
// same edge. Data operands consume the following WB value through forwarding;
// an EA dependency is held by d2_vipt_ea_hazard for exactly one hit cycle.
// Misses retain the precise slow-path interlock.
assign d2_plain_load_overlap_ready = vipt_load_ex_r.valid &&
                                vipt_load_ex_probed_r &&
                                vipt_load_ex_hit &&
                                !vipt_load_ex_r.is_alu && !vipt_load_ex_r.is_ret &&
                                !d2_vipt_candidate &&
                                !d2_vipt_ea_hazard &&
                                !vipt_load_replay_r.valid &&
                                !vipt_load_slow_busy && !single_step;

// The GPR one-hot a write-back of (dst, size) writes (data_unit load_wb_widx).
function automatic [7:0] wb_wmask_of(input [2:0] dst, input [1:0] size);
    wb_wmask_of = 8'h01 << ((size == 2'd0) ? {1'b0, dst[1:0]} : dst);
endfunction

// gpr_write_merge's producer-3 view hit for every GPR byte, from the fields
// the write-back registers take (dst_norm(3), be_of_size and !wb_is_alu).
function automatic [31:0] wb_view_hit_of(input [2:0] dst, input [1:0] size, input is_alu);
    logic [2:0] r;
    logic [3:0] be;
    begin
        r  = (size == 2'd0) ? {1'b0, dst[1:0]} : dst;
        be = (size == 2'd0) ? (dst[2] ? 4'h2 : 4'h1) : (size == 2'd1) ? 4'h3 : 4'hF;
        wb_view_hit_of = is_alu ? 32'h0 : ({28'h0, be} << {r, 2'b00});
    end
endfunction

// synthesis translate_off
wire [2:0] vipt_load_wb_norm_dst = (vipt_load_wb_size_r == 2'd0)
                                  ? {1'b0, vipt_load_wb_dst_r[1:0]}
                                  : vipt_load_wb_dst_r;
// synthesis translate_on

wire       vipt_load_overlap_wb = vipt_load_overlap_r &&
                     vipt_load_wb_valid_r && !vipt_load_ex_r.valid &&
                     !vipt_load_replay_r.valid && !vipt_load_slow_busy;
assign vipt_load_exec_block = vipt_load_busy && !vipt_load_overlap_wb;

// The direct load pipeline admits a younger D2 probe while the older token
// resolves in EX. A miss transfers the older token to normal paging and saves
// the already-consumed younger token in one replay slot.
wire vipt_page_enabled = CR0[31];
wire vipt_user_ok = (pg_cpl != 2'd3) || vipt_tlb_user;
wire vipt_translation_ok = !vipt_page_enabled ||
                           (vipt_tlb_hit && vipt_user_ok);
wire [31:0] vipt_resolve_linear = rd_fast_valid_r
                                ? rd_fast_linear_r
                                : ucrd_valid_r
                                ? ucrd_linear_r
                                : vipt_load_ex_r.linear_addr;
wire [31:0] vipt_resolve_phys = vipt_page_enabled
                              ? vipt_tlb_phys_addr : vipt_resolve_linear;
wire vipt_load_ex_contained =
    (vipt_load_ex_r.mem_size == 2'd0) ||
    ((vipt_load_ex_r.mem_size == 2'd1) &&
     (vipt_load_ex_r.lane != 2'd3)) ||
    ((vipt_load_ex_r.mem_size == 2'd2) &&
     (vipt_load_ex_r.lane == 2'd0));
// A crossing token's second resolve no longer owns IND/seg_sel (a younger
// load may have issued beside its first); its limit verdict was the first's.
wire vipt_load_ex_segf = vipt_load_ex_r.valid && !vipt_x2_r && dir_seg_fault;
// Within one line: the second dword is the next word of the same line.
wire vipt_load_ex_inline = (vipt_load_ex_r.linear_addr[3:2] != 2'b11) &&
                           !vipt_load_ex_r.is_ret;
assign vipt_load_ex_hit = vipt_load_ex_r.valid && vipt_load_ex_probed_r &&
                          (vipt_load_ex_contained || vipt_x2_r) &&
                          vipt_translation_ok &&
                          !vipt_tlb_is_vga_mem && !vipt_load_ex_segf &&
                          !vipt_load_ex_token_pending &&
                          dcache_vipt_resolve_hit;
// The first resolve of a crossing load: every hit term but containment.
wire vipt_x2_go = vipt_load_ex_r.valid && vipt_load_ex_probed_r && !vipt_x2_r &&
                  !vipt_load_ex_contained && vipt_load_ex_inline &&
                  vipt_translation_ok &&
                  !vipt_tlb_is_vga_mem && !vipt_load_ex_segf &&
                  !vipt_load_ex_token_pending &&
                  dcache_vipt_resolve_hit;
// Capture the destination operand from every registered EX token,
// independently of translation, segmentation, and cache outcome. Plain loads
// use it for byte/word merge forwarding; M3 uses it as the private ALU
// destination. This speculative state has no architectural side effect;
// fault/miss handling gates the later valid/commit token.
wire vipt_load_alu_dst_capture_fast = vipt_load_ex_r.valid &&
                                      vipt_load_ex_probed_r;
wire vipt_load_alu_dst_capture_slow = vipt_load_slow_wait_r &&
                                      !mem_servicing;
assign vipt_load_alu_dst_capture = vipt_load_alu_dst_capture_fast ||
                                 vipt_load_alu_dst_capture_slow;
assign vipt_load_alu_dst_capture_dst =
    vipt_load_alu_dst_capture_fast ? vipt_load_ex_r.dst
                                   : vipt_load_slow_r.dst;
assign vipt_load_alu_dst_capture_size =
    vipt_load_alu_dst_capture_fast ? vipt_load_ex_r.write_size
                                   : vipt_load_slow_r.write_size;
assign vipt_load_alu_dst_capture_data =
    vipt_load_alu_dst_capture_fast
        ? format_hardwired_load(vipt_ex_word, 2'd0,
                               vipt_load_ex_r.mem_size,
                               vipt_load_ex_r.result_kind)
        : format_hardwired_load(OPR_R, 2'd0,
                               vipt_load_slow_r.mem_size,
                               vipt_load_slow_r.result_kind);
// A token whose D2 probe was rejected (an older store owned the RAM read
// port that cycle) probes again from EX at once, instead of through the
// replay slot a cycle later. No younger load is in D2 issue beside an
// unprobed EX token, so it has the probe port.
// A crossing token's second probe is the same re-probe; the younger load that
// issued beside its first resolve waits in the replay slot behind it.
wire ex_reprobe = vipt_load_ex_r.valid && !vipt_load_ex_probed_r &&
                  (!vipt_load_replay_r.valid || vipt_x2_r) && !vipt_load_slow_busy &&
                  !mem_servicing && dcache_vipt_probe_ready;
wire vipt_replay_try = vipt_load_replay_r.valid &&
                       !vipt_load_ex_r.valid && !vipt_load_slow_busy &&
                       !mem_servicing &&
                       dcache_vipt_probe_ready;
assign vipt_issue_load = i_issue && d2_vipt_load;
always_ff @(posedge clk) begin
    if (!reset_n || q_flush || any_fault)
        pop_direct_r <= 1'b0;
    else if (i_issue)
        pop_direct_r <= d2_vipt_load && d2_vipt_pop;
end
wire rd_fast_issue = i_issue &&
                     (i_bus.ucode_action == RECIPE_ACTION_RMW_FAST);
wire vipt_issue_rmw = rd_fast_issue && d2_vipt_rmw;
wire vipt_issue_store_wait = vipt_issue_load && d2_vipt_older_store;
// The older load replay has priority; neither replay can coincide with a D2
// issue probe because the replaying instruction still owns EX.
wire rmw_replay_try = stall_rmw_probe && !vipt_replay_try &&
                      !vipt_load_ex_r.valid && !vipt_load_slow_busy &&
                      !mem_servicing && dcache_vipt_probe_ready;
assign vipt_probe_linear = ex_reprobe
                              ? vipt_load_ex_r.linear_addr
                              : vipt_replay_try
                              ? vipt_load_replay_r.linear_addr
                              : stall_rmw_probe
                              ? rd_fast_linear_r
                              : ucrd_route_pre
                              ? ind_linear
                              : issue_load_linear;

assign dcache_vipt_probe_valid = vipt_issue_load || vipt_issue_rmw || ex_reprobe ||
                                 vipt_replay_try || rmw_replay_try || ucrd_take;
assign dcache_vipt_probe_offset = vipt_probe_linear[11:0];
// The sidecar TLB translates the next access in advance, as the i486 TLB
// translates in the access's own clock: an EA instruction that does not
// probe at issue prereads its first address; any other free cycle prereads
// the page of the current ind_linear (not while RD_FAST still needs its own
// translation). A write whose page the sidecar holds can post in its own
// cycle.
assign st_tlb_pre = i_issue && i_bus.ind_is_ea && !d2_vipt_load && !vipt_issue_rmw &&
                    !ex_reprobe && !vipt_replay_try && !rmw_replay_try && !ucrd_take;
assign sidecar_bg_pre = !dcache_vipt_probe_valid && !st_tlb_pre && !rd_fast_valid_r;
always_ff @(posedge clk) begin
    if (!reset_n) begin
        sidecar_valid_r <= 1'b0;
        sidecar_page_r <= 20'd0;
    end else if (st_tlb_pre) begin
        sidecar_valid_r <= 1'b1;
        sidecar_page_r <= issue_mem_linear[31:12];
    end else if (dcache_vipt_probe_valid) begin
        // Every probe request prereads the sidecar TLB, accepted by the L1 or
        // not: a rejected probe's translation is still correct for its page,
        // and the L1's acceptance (an address compare) stays off this enable.
        sidecar_valid_r <= 1'b1;
        sidecar_page_r <= vipt_probe_linear[31:12];
    end else if (sidecar_bg_pre) begin
        sidecar_valid_r <= 1'b1;
        sidecar_page_r <= ind_linear[31:12];
    end
end
// The microcode read's privilege is the one registered with it.
wire ucrd_translation_ok = !vipt_page_enabled ||
                           (vipt_tlb_hit && ((ucrd_cpl_r != 2'd3) || vipt_tlb_user));
assign dcache_vipt_resolve_valid = (((vipt_load_ex_r.valid &&
                                      vipt_load_ex_probed_r &&
                                      !vipt_load_ex_segf) ||
                                     (rd_fast_valid_r &&
                                      rd_fast_probed_r && !dir_rmw_fault)) &&
                                    vipt_translation_ok &&
                                    !vipt_tlb_is_vga_mem) ||
                                   (ucrd_valid_r && ucrd_translation_ok &&
                                    !vipt_tlb_is_vga_mem);
assign ucrd_hit = ucrd_valid_r && ucrd_translation_ok && !vipt_tlb_is_vga_mem &&
                dcache_vipt_resolve_hit;
assign dcache_vipt_resolve_phys_addr = vipt_resolve_phys;
// vipt_resolve_phys = page_en ? (tlb_hit ? hit_form : miss_form) : linear
//                   = (page_en && tlb_hit) ? hit_form : (page_en ? miss_form : linear)
assign dcache_vipt_resolve_tlb_phys = vipt_tlb_phys_hit_form;
assign dcache_vipt_resolve_alt_phys = vipt_page_enabled ? vipt_tlb_phys_miss_form
                                                        : vipt_resolve_linear;
assign dcache_vipt_resolve_use_tlb  = vipt_page_enabled && vipt_tlb_hit;
// synthesis translate_off
always @(posedge clk)
    if (reset_n && ((vipt_tlb_phys_addr !== (vipt_tlb_hit ? vipt_tlb_phys_hit_form
                                                          : vipt_tlb_phys_miss_form)) ||
                    (vipt_resolve_phys !== (dcache_vipt_resolve_use_tlb
                                            ? dcache_vipt_resolve_tlb_phys
                                            : dcache_vipt_resolve_alt_phys))))
        $fatal(1, "data_access: the VIPT resolve address arms disagree with the address");
// synthesis translate_on

// A synthetic RNI is required only when the direct pipeline drains. Interior
// load boundaries are represented by their D2 issue and WB commit tokens.
assign vipt_load_retire = vipt_load_wb_valid_r && !vipt_load_overlap_r &&
                          !vipt_load_ex_r.valid &&
                          !vipt_load_replay_r.valid &&
                          !vipt_load_slow_busy;

// The write-back token's valid, write mask and view hits with the kill
// (q_flush || any_fault || interrupt_entry) applied last, as a synchronous
// clear over the next value formed without it: q_flush is the taken-branch
// decision (flags forward -> condition -> q_flush, fan-out ~580) and reached
// these flops through the whole token update. Same next state as the single
// always_ff below had (a later assignment wins: the kill over the slow
// completion over the EX hit); tests/equiv/wb_kill_last.v proves it.
wire vipt_wb_ex_done   = vipt_load_ex_r.valid && vipt_load_ex_probed_r &&
                         vipt_load_ex_hit && !any_fault;
wire vipt_wb_slow_done = vipt_load_slow_wait_r && !mem_servicing;
wire vipt_wb_kill      = q_flush || any_fault || interrupt_entry;
`Z486_KEEP_COMB wire        vipt_wb_valid_nk = vipt_wb_slow_done || vipt_wb_ex_done;
`Z486_KEEP_COMB wire [7:0]  vipt_wb_wmask_nk =
    vipt_wb_slow_done ? wb_wmask_of(vipt_load_slow_r.dst, vipt_load_slow_r.write_size) :
    vipt_wb_ex_done   ? wb_wmask_of(vipt_load_ex_r.dst, vipt_load_ex_r.write_size) : 8'd0;
`Z486_KEEP_COMB wire [31:0] vipt_wb_view_hit_nk =
    vipt_wb_slow_done ? wb_view_hit_of(vipt_load_slow_r.dst, vipt_load_slow_r.write_size,
                                       vipt_load_slow_r.is_alu) :
    vipt_wb_ex_done   ? wb_view_hit_of(vipt_load_ex_r.dst, vipt_load_ex_r.write_size,
                                       vipt_load_ex_r.is_alu) : 32'd0;
always_ff @(posedge clk) begin
    if (!reset_n || vipt_wb_kill) begin
        vipt_load_wb_valid_r <= 1'b0;
        vipt_load_wb_wmask_r <= 8'd0;
        vipt_load_wb_view_hit_r <= 32'd0;
    end else begin
        vipt_load_wb_valid_r <= vipt_wb_valid_nk;
        vipt_load_wb_wmask_r <= vipt_wb_wmask_nk;
        vipt_load_wb_view_hit_r <= vipt_wb_view_hit_nk;
    end
end

always_ff @(posedge clk) begin
    if (!reset_n) begin
        vipt_load_ex_r <= '0;
        vipt_load_replay_r <= '0;
        vipt_load_slow_r <= '0;
        vipt_load_slow_req_r <= 1'b0;
        vipt_load_slow_segf_r <= 1'b0;
        vipt_load_slow_ssf_r <= 1'b0;
        vipt_load_slow_wait_r <= 1'b0;
        vipt_slow_phys_ok_r <= 1'b0;
        vipt_slow_phys_r <= 32'd0;
        vipt_load_ex_probed_r <= 1'b0;
        vipt_load_wb_data_r <= 32'd0;
        vipt_load_wb_ret_r <= 1'b0;
        vipt_load_wb_target_r <= 32'd0;
        vipt_load_wb_dst_r <= 3'd0;
        vipt_load_wb_dst_onehot_r <= 8'd0;
        vipt_load_wb_size_r <= 2'd2;
        vipt_load_wb_ah_r <= 1'b0;
        vipt_load_wb_is_alu_r <= 1'b0;
        vipt_load_wb_alu_op_r <= 5'd0;
        vipt_load_overlap_r <= 1'b0;
        vipt_x2_r <= 1'b0;
        vipt_x2_lo_r <= 32'd0;
    end else begin
        if (vipt_load_wb_valid_r)
            vipt_load_overlap_r <= 1'b0;
        if (i_issue && d2_plain_load_overlap_ready)
            vipt_load_overlap_r <= 1'b1;

        // The miss's payload and translation are consumed only with a slow
        // request; captured whenever a token resolves (no slow request is
        // pending then) so the fault cone does not reach their enables.
        if (vipt_load_ex_r.valid && !vipt_load_slow_busy) begin
            // A crossing token's second resolve carries the next word.
            vipt_load_slow_r.linear_addr <= vipt_x2_r
                ? {vipt_load_ex_r.linear_addr[31:4],
                   vipt_load_ex_r.linear_addr[3:2] - 2'd1,
                   vipt_load_ex_r.linear_addr[1:0]}
                : vipt_load_ex_r.linear_addr;
            vipt_load_slow_r.restart_eip <= vipt_load_ex_r.restart_eip;
            vipt_load_slow_r.dst <= vipt_load_ex_r.dst;
            vipt_load_slow_r.dst_onehot <= vipt_load_ex_r.dst_onehot;
            vipt_load_slow_r.mem_size <= vipt_load_ex_r.mem_size;
            vipt_load_slow_r.lane <= vipt_load_ex_r.lane;
            vipt_load_slow_r.write_size <= vipt_load_ex_r.write_size;
            vipt_load_slow_r.result_kind <= vipt_load_ex_r.result_kind;
            vipt_load_slow_r.is_alu <= vipt_load_ex_r.is_alu;
            vipt_load_slow_r.alu_op <= vipt_load_ex_r.alu_op;
            vipt_load_slow_r.restore_esp <= vipt_load_ex_r.restore_esp;
            vipt_load_slow_r.esp_restore <= vipt_load_ex_r.esp_restore;
            vipt_load_slow_r.is_ret <= vipt_load_ex_r.is_ret;
            vipt_load_slow_r.ret_esp <= vipt_load_ex_r.ret_esp;
        end
        if (vipt_load_ex_r.valid) begin
            vipt_slow_phys_ok_r <= vipt_load_ex_probed_r && vipt_load_ex_contained &&
                                   vipt_translation_ok && !vipt_tlb_is_vga_mem &&
                                   !vipt_load_ex_segf;
            vipt_slow_phys_r <= vipt_resolve_phys;
        end

        // The EX slot normally advances or empties every cycle.
        vipt_load_ex_r.valid <= 1'b0;
        vipt_load_ex_probed_r <= 1'b0;
        vipt_x2_r <= 1'b0;

        if (vipt_replay_try && dcache_vipt_probe_direct_accepted) begin
            vipt_load_ex_r <= vipt_load_replay_r;
            vipt_load_ex_probed_r <= 1'b1;
            vipt_load_replay_r.valid <= 1'b0;
        end

        if (vipt_load_ex_r.valid) begin
            if (!vipt_load_ex_probed_r) begin
                if (ex_reprobe && dcache_vipt_probe_direct_accepted) begin
                    vipt_load_ex_r.valid <= 1'b1;
                    vipt_load_ex_probed_r <= 1'b1;
                    vipt_x2_r <= vipt_x2_r;
                end else if (vipt_x2_r) begin
                    // Its younger load may hold the replay slot: wait in EX.
                    vipt_load_ex_r.valid <= 1'b1;
                    vipt_x2_r <= 1'b1;
                end else begin
                    vipt_load_replay_r <= vipt_load_ex_r;
                end
            end else if (vipt_load_ex_hit && !any_fault) begin
                // A RET writes its new ESP through the load port and keeps
                // the loaded target for the redirect.
                vipt_load_wb_data_r <= vipt_load_ex_r.is_ret ? vipt_load_ex_r.ret_esp
                                     : format_hardwired_load(
                    vipt_ex_word, 2'd0,
                    vipt_load_ex_r.mem_size, vipt_load_ex_r.result_kind);
                vipt_load_wb_ret_r <= vipt_load_ex_r.is_ret;
                vipt_load_wb_target_r <= dcache_vipt_resolve_data;
                vipt_load_wb_dst_r <= vipt_load_ex_r.dst;
                vipt_load_wb_dst_onehot_r <= vipt_load_ex_r.dst_onehot;
                vipt_load_wb_size_r <= vipt_load_ex_r.write_size;
                vipt_load_wb_ah_r <= (vipt_load_ex_r.write_size == 2'd0) &&
                                     vipt_load_ex_r.dst[2];
                vipt_load_wb_is_alu_r <= vipt_load_ex_r.is_alu;
                vipt_load_wb_alu_op_r <= vipt_load_ex_r.alu_op;
            end else if (vipt_x2_go && !any_fault) begin
                vipt_load_ex_r.valid <= 1'b1;
                vipt_x2_r <= 1'b1;
                vipt_x2_lo_r <= dcache_vipt_resolve_data;
                vipt_load_ex_r.linear_addr[3:2] <= vipt_load_ex_r.linear_addr[3:2] + 2'd1;
            end else if (!any_fault) begin
                vipt_load_slow_req_r <= 1'b1;
                // The EX stage is the only cycle IND/seg_sel belong to a direct
                // token, so record its limit verdict and deliver it from here.
                vipt_load_slow_segf_r <= vipt_load_ex_segf;
                vipt_load_slow_ssf_r <= ss_segment_fault;
            end
        end

        if (vipt_issue_load) begin
            if (vipt_load_ex_r.valid && !vipt_load_ex_hit) begin
                vipt_load_replay_r.valid <= 1'b1;
                vipt_load_replay_r.linear_addr <= issue_load_linear;
                vipt_load_replay_r.restart_eip <= EIP;
                vipt_load_replay_r.dst <= d2_vipt_dst;
                vipt_load_replay_r.dst_onehot <= d2_vipt_dst_onehot;
                vipt_load_replay_r.mem_size <= d2_vipt_mem_size;
                vipt_load_replay_r.lane <= issue_load_low;
                vipt_load_replay_r.write_size <= d2_vipt_write_size;
                vipt_load_replay_r.result_kind <= d2_vipt_result_kind;
                vipt_load_replay_r.is_alu <= d2_vipt_alu;
                vipt_load_replay_r.alu_op <= i_bus.decoded_alu_op;
                vipt_load_replay_r.restore_esp <= d2_vipt_pop;
                vipt_load_replay_r.esp_restore <= forwarded_esp;
                vipt_load_replay_r.is_ret <= d2_vipt_ret;
                vipt_load_replay_r.ret_esp <= d2_ret_esp;
            end else begin
                vipt_load_ex_r.valid <= 1'b1;
                vipt_load_ex_probed_r <= dcache_vipt_probe_accepted &&
                                          !vipt_issue_store_wait;
                vipt_load_ex_r.linear_addr <= issue_load_linear;
                vipt_load_ex_r.restart_eip <= EIP;
                vipt_load_ex_r.dst <= d2_vipt_dst;
                vipt_load_ex_r.dst_onehot <= d2_vipt_dst_onehot;
                vipt_load_ex_r.mem_size <= d2_vipt_mem_size;
                vipt_load_ex_r.lane <= issue_load_low;
                vipt_load_ex_r.write_size <= d2_vipt_write_size;
                vipt_load_ex_r.result_kind <= d2_vipt_result_kind;
                vipt_load_ex_r.is_alu <= d2_vipt_alu;
                vipt_load_ex_r.alu_op <= i_bus.decoded_alu_op;
                vipt_load_ex_r.restore_esp <= d2_vipt_pop;
                vipt_load_ex_r.esp_restore <= forwarded_esp;
                vipt_load_ex_r.is_ret <= d2_vipt_ret;
                vipt_load_ex_r.ret_esp <= d2_ret_esp;
            end
        end

        // Each requester owns only the acceptance of the request it submitted.
        if (vipt_slow_submit && mem_accepted) begin
            vipt_load_slow_req_r <= 1'b0;
            vipt_load_slow_wait_r <= 1'b1;
        end
        // Paging assembles crossing reads in OPR_R.  Wait until its ownership
        // drops rather than treating the first fragment as a completed load.
        if (vipt_load_slow_wait_r && !mem_servicing) begin
            vipt_load_slow_wait_r <= 1'b0;
            vipt_load_wb_data_r <= vipt_load_slow_r.is_ret ? vipt_load_slow_r.ret_esp
                                 : format_hardwired_load(
                OPR_R, 2'd0, vipt_load_slow_r.mem_size,
                vipt_load_slow_r.result_kind);
            vipt_load_wb_ret_r <= vipt_load_slow_r.is_ret;
            vipt_load_wb_target_r <= OPR_R;
            vipt_load_wb_dst_r <= vipt_load_slow_r.dst;
            vipt_load_wb_dst_onehot_r <= vipt_load_slow_r.dst_onehot;
            vipt_load_wb_size_r <= vipt_load_slow_r.write_size;
            vipt_load_wb_ah_r <= (vipt_load_slow_r.write_size == 2'd0) &&
                                 vipt_load_slow_r.dst[2];
            vipt_load_wb_is_alu_r <= vipt_load_slow_r.is_alu;
            vipt_load_wb_alu_op_r <= vipt_load_slow_r.alu_op;
        end

        if (q_flush || any_fault || interrupt_entry) begin
            vipt_load_ex_r.valid <= 1'b0;
            vipt_x2_r <= 1'b0;
            vipt_load_replay_r.valid <= 1'b0;
            vipt_load_slow_req_r <= 1'b0;
            vipt_load_slow_wait_r <= 1'b0;
            vipt_load_ex_probed_r <= 1'b0;
            vipt_load_overlap_r <= 1'b0;
        end
    end
end

// synthesis translate_off
always_ff @(posedge clk) begin
    if (reset_n && ex_reprobe && (vipt_issue_load || vipt_issue_rmw))
        $fatal(1, "D2 issue probe beside an EX re-probe");
    if (reset_n && i_issue && d2_vipt_load && !dcache_vipt_probe_ready)
        $fatal(1, "VIPT load issued without an accepted D2 preread");
    if (reset_n && vipt_issue_load && vipt_load_ex_r.valid &&
        !vipt_load_ex_hit && vipt_load_replay_r.valid)
        $fatal(1, "VIPT replay token overflow");
    if (reset_n && vipt_load_wb_valid_r &&
        (vipt_load_wb_dst_onehot_r !== (8'h01 << vipt_load_wb_norm_dst)))
        $fatal(1, "VIPT WB destination mask mismatch");
    if (reset_n && (vipt_load_wb_wmask_r !==
                    (vipt_load_wb_valid_r ? wb_wmask_of(vipt_load_wb_dst_r, vipt_load_wb_size_r)
                                          : 8'h00)))
        $fatal(1, "VIPT WB write mask %b is not the valid write-back's", vipt_load_wb_wmask_r);
    if (reset_n && (vipt_load_wb_view_hit_r !==
                    (vipt_load_wb_valid_r ? wb_view_hit_of(vipt_load_wb_dst_r, vipt_load_wb_size_r,
                                                           vipt_load_wb_is_alu_r)
                                          : 32'h0)))
        $fatal(1, "VIPT WB view hits %h are not the valid write-back's", vipt_load_wb_view_hit_r);
    if (reset_n && (vipt_load_wb_ah_r !==
                    ((vipt_load_wb_size_r == 2'd0) && vipt_load_wb_dst_r[2])))
        $fatal(1, "VIPT WB AH select %b is not the write-back's", vipt_load_wb_ah_r);
end
// synthesis translate_on

// synthesis translate_off
// The preread registers in the L1 are reloaded on every idle cycle, so an
// RMW's resolve is only valid the cycle after its OWN accepted probe. A
// finish with a probed flag set but no such probe the cycle before would
// consume another access's preread.
reg rd_fast_own_probe_q;
always_ff @(posedge clk) begin
    rd_fast_own_probe_q <= reset_n && !q_flush && !any_fault &&
        ((vipt_issue_rmw && dcache_vipt_probe_accepted) ||
         (rmw_replay_try && dcache_vipt_probe_direct_accepted));
    if (reset_n && rd_fast_finish && rd_fast_probed_r && !rd_fast_own_probe_q)
        $fatal(1, "RMW FIRST-USTEP FINISH WITHOUT ITS OWN PROBE");
end
// synthesis translate_on

// RD_FAST finalizes the D2 preread in the overlay entry uStep. A hit commits
// the formatted operand to normal OPR_R and retains only the write-qualified
// physical identity. A reject has no architectural side effect and redirects
// to the untouched original routine.
wire rd_fast_contained =
    (rd_fast_size_r == 2'd0) ||
    ((rd_fast_size_r == 2'd1) && (rd_fast_lane_r != 2'd3)) ||
    ((rd_fast_size_r == 2'd2) && (rd_fast_lane_r == 2'd0));
wire rd_fast_page_write_ok = !vipt_page_enabled ||
    (vipt_tlb_hit && vipt_user_ok && vipt_tlb_dirty &&
     (vipt_tlb_writable || ((pg_cpl != 2'd3) && !CR0[16])));
wire rd_fast_hit = rd_fast_valid_r && rd_fast_probed_r &&
                   rd_fast_contained && rd_fast_page_write_ok &&
                   !vipt_tlb_is_vga_mem && !dir_rmw_fault &&
                   dcache_vipt_resolve_hit;
assign rd_fast_finish = rd_fast_valid_r && i_first && uc_exec;
// A microcode read hit writes OPR_R as paging does for a single access: the
// operand shifted down from its byte lane and zero-extended from its size.
wire [31:0] ucrd_hit_data = format_hardwired_load(dcache_vipt_resolve_data, ucrd_linear_r[1:0],
                                                  ucrd_size_r, LOAD_RESULT_COPY);
wire        ucrd_hit_hold = ucrd_hit && !ucrd_x87_r && !uc_bus_or_dly && !i_rni_delay;
wire        ucrd_held_commit = ucrd_held_r &&
    (uc_bus_or_dly || i_rni_delay || !uc_active || q_flush || any_fault || interrupt_entry);
assign fast_opr_commit = (rd_fast_finish && rd_fast_hit) || (ucrd_hit && !ucrd_hit_hold) ||
                         ucrd_held_commit;
assign fast_opr_data = ucrd_held_r ? ucrd_held_data_r
                     : ucrd_valid_r ? ucrd_hit_data
                     : format_hardwired_load(dcache_vipt_resolve_data, rd_fast_lane_r,
                                             rd_fast_size_r, LOAD_RESULT_COPY);
always_ff @(posedge clk) begin
    if (!reset_n) begin
        rd_fast_valid_r <= 1'b0;
        rd_fast_probed_r <= 1'b0;
        rd_fast_linear_r <= 32'd0;
        rd_fast_size_r <= 2'd0;
        rd_fast_lane_r <= 2'd0;
        rmw_fast_active_r <= 1'b0;
        rmw_fast_phys_r <= 32'd0;
        rmw_fast_size_r <= 2'd0;
        rmw_fast_lane_r <= 2'd0;
        rmw_fallback_delay_r <= 1'b0;
    end else begin
        if (rd_fast_issue) begin
            rd_fast_valid_r <= 1'b1;
            rd_fast_probed_r <= d2_vipt_rmw &&
                                dcache_vipt_probe_accepted;
            rd_fast_linear_r <= issue_ind_linear;
            rd_fast_size_r <= i_bus.operand_size;
            rd_fast_lane_r <= issue_ind_linear_low;
        end
        if (rmw_replay_try && dcache_vipt_probe_direct_accepted)
            rd_fast_probed_r <= 1'b1;

        if (rd_fast_finish) begin
            rd_fast_valid_r <= 1'b0;
            rd_fast_probed_r <= 1'b0;
            if (rd_fast_hit) begin
                rmw_fast_active_r <= 1'b1;
                rmw_fast_phys_r <= vipt_resolve_phys;
                rmw_fast_size_r <= rd_fast_size_r;
                rmw_fast_lane_r <= rd_fast_lane_r;
            end else begin
                rmw_fallback_delay_r <= 1'b1;
            end
        end

        // Keep the overlay inert while its registered rejection redirects the
        // two-stage ROM pipeline. z486 releases the token once the target
        // word sits in both ROM stages and the ROM advances, steering port A
        // to the following word on that edge, so the target executes exactly
        // once after this token is cleared.
        if (rmw_fallback_release)
            rmw_fallback_delay_r <= 1'b0;

        if (rmw_store_accepted)
            rmw_fast_active_r <= 1'b0;

        if (q_flush || any_fault || interrupt_entry) begin
            rd_fast_valid_r <= 1'b0;
            rd_fast_probed_r <= 1'b0;
            rmw_fast_active_r <= 1'b0;
            rmw_fallback_delay_r <= 1'b0;
        end
    end
end

// A pending microcode-read miss is always older than a pending direct-load
// miss (a microcode read does not start behind one), so it enters paging
// first: their OPR_R results must arrive in program order.
assign      vipt_slow_submit = vipt_load_slow_req_r && !mem_servicing &&
                               !ucrd_slow_req_r && !vipt_load_slow_segf_r;
// The slow token is the oldest: deliver its recorded verdict without a bus op.
assign      vipt_slow_seg_trigger = vipt_load_slow_req_r && !mem_servicing &&
                                    !ucrd_slow_req_r && vipt_load_slow_segf_r;
// The direct token's access width for the ungated segment verdict.
assign dir_access_size = rd_fast_valid_r
    ? (rd_fast_size_r == 2'd0 ? 2'd0 : rd_fast_size_r == 2'd1 ? 2'd1 : 2'd3)
    : (vipt_load_ex_r.mem_size == 2'd0 ? 2'd0 :
       vipt_load_ex_r.mem_size == 2'd1 ? 2'd1 : 2'd3);
// A fallback token owns stable registered address metadata as soon as it is
// pending.  Present that address to the live TLB while an older request drains;
// submission remains idle-gated above.  This keeps mem_servicing out of the
// live-TLB/cache-address cone without changing request ordering.
assign vipt_slow_addr_owned = vipt_load_slow_req_r;
// A cacheable, non-crossing microcode read from any uStep (or x87 direct
// operand read) with paging idle probes the cache instead of entering paging;
// a missed one enters paging from its token (upstream 3b27dd0; it was the
// first-uStep EA read only).
// A locked read (LOCK prefix, XCHG with memory, and the microcode's locked
// descriptor/TSS read RD_OPR_WORD, z486.sv lock_read_uop) must read memory, so
// it never takes the cache-probing microcode-read path.
wire        ucrd_uc_read = uc_data_busreq && uc_is_mem_busop &&
    !uc_is_write && !uc_is_check_write && !mem_is_io && !locked_insn &&
    (uc_buscode != BUSOP_RD_IND) && (uc_buscode != BUSOP_RD_OPR_WORD) &&
    !ucrd_nohit_skip && !x87_direct_mem_req;
wire [1:0]  ucrd_size_now = x87_direct_mem_req ? 2'd2 : mem_eff_size;
assign ucrd_route_pre = !hardwired_off && mem_op_eligible && (ucrd_uc_read || x87_direct_mem_req) &&
    ind_linear_valid && !vipt_load_slow_req_r && !ucrd_valid_r && !ucrd_held_r &&
    !ucrd_miss_busy && paging_demand_idle &&
    !access_crosses_dword(ucrd_size_now, ind_linear[1:0]) &&
    dcache_vipt_probe_ready && !ex_reprobe;
// A held microcode uop must not probe twice; an x87 direct read is issued
// while x87 holds the pipeline and marks itself issued on acceptance.
assign ucrd_take = ucrd_route_pre && !gp_fault_trigger && (x87_direct_mem_req || !stall);
// A write whose page the sidecar holds posts through the direct store port
// when that translation permits it (present, writable at this privilege,
// dirty, not the VGA aperture) and the L1 takes a store now; otherwise it
// enters paging.
wire        st_route_pre = !hardwired_off && mem_op_eligible && uc_data_busreq && uc_is_mem_busop &&
    uc_is_write && !uc_is_check_write && !mem_is_io &&
    sidecar_valid_r && (sidecar_page_r == ind_linear[31:12]) && ind_linear_valid &&
    !access_crosses_dword(mem_eff_size, ind_linear[1:0]) &&
    paging_demand_idle && !ucrd_busy && !vipt_load_slow_req_r &&
    !rmw_store_valid && dcache_wr_ready;
wire        st_user = (pg_cpl == 2'd3);
wire        st_tlb_ok = vipt_tlb_hit && !vipt_tlb_is_vga_mem && (!st_user || vipt_tlb_user) &&
                        vipt_tlb_dirty && (vipt_tlb_writable || (!st_user && !CR0[16]));
// A template window can put an uncached class anywhere, and a store to such a
// window must not post into the D-cache's store queue: the queue merges stores
// to one dword and drains behind the bus unit's VGA-ordered direct reads, so a
// device would see fewer, later writes.  With windows the post is gated by the
// sidecar page's verdict instead, which z486.sv derives from the compile-time
// template (the physical page is cacheable RAM: the sidecar entry's PFN paged, the
// linear page unpaged); every other store takes the classifying demand path.
// The page is sidecar_page_r, which st_route_pre requires to be ind_linear's.
// With no window the hard-coded map is exact.
wire        st_postable = memmap_windows
    ? (memmap_post_ok && (!vipt_page_enabled || st_tlb_ok))
    : (vipt_page_enabled ? st_tlb_ok : (ind_linear[31:17] != 15'h5));
assign sidecar_page = sidecar_page_r;
assign st_route = st_route_pre && st_postable;
assign st_take = st_route && !gp_fault_trigger &&
                 !(stall_wio || stall_x87_direct || stall_invlpg || stall_rmw_probe || stall_ucrd);
assign st_phys = vipt_page_enabled ? {vipt_tlb_phys_addr[31:12], ind_linear[11:0]} : ind_linear;
assign st_be = calc_be(mem_eff_size, ind_linear[1:0]);
assign st_wdata = shift_write_data(mem_wdata, mem_eff_size, ind_linear[1:0]);
assign ucrd_slow_submit = ucrd_slow_req_r && !mem_servicing;


// Microcode read token: probe in the RD cycle, resolve the next. A miss
// (TLB, permission, VGA aperture, cache) enters paging from the token, which
// writes OPR_R; every uop waits until it does.
always_ff @(posedge clk) begin
    if (!reset_n) begin
        ucrd_valid_r <= 1'b0;
        ucrd_tlbok_r <= 1'b0;
        ucrd_linear_r <= 32'd0;
        ucrd_size_r <= 2'd0;
        ucrd_cpl_r <= 2'd0;
        ucrd_x87_r <= 1'b0;
        ucrd_phys_ok_r <= 1'b0;
        ucrd_phys_r <= 32'd0;
        ucrd_slow_req_r <= 1'b0;
        ucrd_slow_wait_r <= 1'b0;
        ucrd_held_r <= 1'b0;
        ucrd_held_data_r <= 32'd0;
        ucrd_strict_r <= 1'b0;
        ucrd_nohit_valid_r <= 1'b0;
        ucrd_nohit_page_r <= 20'd0;
        ucrd_nohit_phys_r <= 20'd0;
    end else begin
        if (dcache_vipt_resolve_valid && dcache_vipt_resolve_hit &&
            (vipt_resolve_phys[31:12] == ucrd_nohit_phys_r))
            ucrd_nohit_valid_r <= 1'b0;
        ucrd_valid_r <= ucrd_take;
        if (ucrd_held_commit)
            ucrd_held_r <= 1'b0;
        if (ucrd_hit_hold) begin
            ucrd_held_r <= 1'b1;
            ucrd_held_data_r <= ucrd_hit_data;
        end
        ucrd_tlbok_r <= ucrd_take && sidecar_valid_r &&
                        (sidecar_page_r == ind_linear[31:12]) && !vipt_tlb_is_vga_mem &&
                        (!vipt_page_enabled ||
                         (vipt_tlb_hit && ((pg_cpl != 2'd3) || vipt_tlb_user)));
        if (ucrd_take) begin
            ucrd_linear_r <= ind_linear;
            ucrd_size_r <= ucrd_size_now;
            ucrd_cpl_r <= pg_cpl;
            ucrd_x87_r <= x87_direct_mem_req;
            ucrd_strict_r <= i_first || x87_direct_mem_req;
        end
        if (ucrd_valid_r && !ucrd_hit) begin
            ucrd_slow_req_r <= 1'b1;
            ucrd_nohit_valid_r <= 1'b1;
            ucrd_nohit_page_r <= ucrd_linear_r[31:12];
            ucrd_nohit_phys_r <= vipt_resolve_phys[31:12];
            // A DLY that passed the resolve cycle leaves its wait to the
            // uops after it.
            if (uc_bus_or_dly)
                ucrd_strict_r <= 1'b1;
            ucrd_phys_ok_r <= ucrd_translation_ok && !vipt_tlb_is_vga_mem;
            ucrd_phys_r <= vipt_resolve_phys;
        end
        if (ucrd_slow_submit && mem_accepted) begin
            ucrd_slow_req_r <= 1'b0;
            ucrd_slow_wait_r <= 1'b1;
        end
        if (ucrd_slow_wait_r && !mem_servicing)
            ucrd_slow_wait_r <= 1'b0;
        if (q_flush || any_fault || interrupt_entry) begin
            ucrd_valid_r <= 1'b0;
            ucrd_slow_req_r <= 1'b0;
            ucrd_slow_wait_r <= 1'b0;
        end
    end
end

// synthesis translate_off
always @(posedge clk)
    if (reset_n && ucrd_take && !dcache_vipt_probe_accepted)
        $fatal(1, "microcode read probe not accepted");
// synthesis translate_on

// Direct register loads share one token after D2.  MOVZX/MOVSX use SRCREG as
// their architectural destination in the original microcode; plain MOV uses
// DSTREG and may name AH/CH/DH/BH.  Crossing operands are admitted here so EX
// can transfer their registered address and metadata to normal paging.
// Both address sizes are eligible: address_unit has already masked a16 offsets
// and added the selected segment base before issue. Complex base+index+disp
// forms retain their separate D2 partial-sum cycle.
// A write uop and its D2 successor can overlap on the edge where paging first
// captures the write.  The store may still need a dirty-bit page walk, so it
// is not yet visible to the cache's store queue.  Accept the younger load token
// but discard that edge's speculative preread, then replay it only after paging
// releases the older request.  The load retains VIPT while cache/store-queue
// ordering sees the accepted store before the replayed lookup.
assign d2_vipt_older_store = uc_active && uc_is_write;
wire d2_vipt_plain_mov = !i_bus.has_0f &&
                         ((i_bus.opcode == 8'h8A) ||
                          (i_bus.opcode == 8'h8B));
wire d2_vipt_movx = i_bus.has_0f && i_bus.data32 &&
                    ((i_bus.opcode == 8'hB6) ||
                     (i_bus.opcode == 8'hB7) ||
                     (i_bus.opcode == 8'hBE) ||
                     (i_bus.opcode == 8'hBF));
assign d2_vipt_alu = i_bus.vipt_alu;
assign d2_vipt_dst = d2_vipt_ret ? 3'd4 :
                     d2_vipt_movx ? i_bus.src_reg_sel : i_bus.dst_reg_sel;
assign d2_vipt_mem_size = d2_vipt_ret ? 2'd2 :
                          d2_vipt_movx ? i_bus.source_size : i_bus.operand_size;
assign d2_vipt_write_size = (d2_vipt_movx || d2_vipt_ret) ? 2'd2
                                                          : i_bus.operand_size;
wire [2:0] d2_vipt_dst_wide = (d2_vipt_write_size == 2'd0)
                            ? {1'b0, d2_vipt_dst[1:0]} : d2_vipt_dst;
assign d2_vipt_dst_onehot = 8'h01 << d2_vipt_dst_wide;
assign d2_vipt_result_kind = !d2_vipt_movx ? LOAD_RESULT_COPY :
    (i_bus.opcode[3] ? LOAD_RESULT_SIGN_EXTEND : LOAD_RESULT_ZERO_EXTEND);
// MOV AL/eAX,moffs shares MOV r,m's recipe; its address is the immediate.
// A ModR/M load has an earlier AGU cycle in which IND takes the ordinary
// segment-limit check; a moffs literal reaches IND on the edge that launches
// the direct token. So only a flat DS (protected mode, page-granular,
// 4 GB limit, not expand-down), where no contained access can violate the
// limit, takes the direct path; others keep the ROM path's precise check.
wire d2_vipt_moffs = !i_bus.has_0f && i_bus.has_moffs &&
                     ((i_bus.opcode == 8'hA0) || (i_bus.opcode == 8'hA1)) &&
                     pe && (i_bus.mem_seg == SEG_DS) && ds_flat;
// POP r is a direct load at the stack address. Its first ROM word still
// executes for its ESP write (its read is suppressed); like moffs, the
// address reaches IND on the token's launch edge, so only a flat 32-bit SS
// takes this path. POP ESP keeps the ROM path.
assign d2_vipt_pop = !i_bus.has_0f && (i_bus.opcode[7:3] == 5'b01011) &&
                   (i_bus.opcode[2:0] != 3'd4) && i_bus.stack_op &&
                   pe && ss_flat32;
// A 32-bit near RET is a direct load of its target: on writeback the load
// port writes ESP (ESP + 4 + imm16) and the target redirects the front end,
// as the hardware branch uStep does; its ROM words do not execute.
wire d2_flat_ss32 = pe && ss_flat32;
assign d2_vipt_ret = !i_bus.has_0f && ((i_bus.opcode == 8'hC3) || (i_bus.opcode == 8'hC2)) &&
                     i_bus.data32 && i_bus.stack_op && d2_flat_ss32;
assign d2_ret_esp = forwarded_esp + 32'd4 +
                    ((i_bus.opcode == 8'hC2) ? {16'd0, i_bus.immediate[15:0]} : 32'd0);
// A direct access skips the microcode's segment check; one whose segment is
// not readable (a null selector) takes the ROM path, which faults.
wire d2_seg_readable = !pe || vm || (i_bus.mem_seg < 4'd6 && seg_readable[i_bus.mem_seg[2:0]]);
assign d2_vipt_candidate = d2_seg_readable && !hardwired_off &&
                           (i_bus.rep_lock == PREFIX_NOREPLOCK) &&
                           (((d2_vipt_plain_mov || d2_vipt_movx || d2_vipt_alu) &&
                             i_bus.has_modrm && (i_bus.modrm[7:6] != 2'b11) &&
                             !i_bus.has_moffs && !i_bus.stack_op) ||
                            d2_vipt_moffs || d2_vipt_pop || d2_vipt_ret) &&
                           !single_step && !direct_hold;
// A direct load or RMW waits while an older microcode read resolves or misses:
// its own miss must not reach paging (and OPR_R) ahead of the older read.
assign d2_vipt_load = d2_vipt_candidate && dcache_vipt_probe_ready && !ucrd_route_pre && !ucrd_busy &&
                      !vipt_load_replay_r.valid && !vipt_load_slow_busy &&
                      !rmw_fast_active_r;
wire d2_vipt_rmw_opcode = ((i_bus.opcode == 8'hF6) ||
                            (i_bus.opcode == 8'hF7))
                         ? ((i_bus.modrm[5:3] == 3'b010) ||
                            (i_bus.modrm[5:3] == 3'b011))
                         : (((i_bus.opcode == 8'hFE) ||
                             (i_bus.opcode == 8'hFF)) &&
                            ((i_bus.modrm[5:3] == 3'b000) ||
                             (i_bus.modrm[5:3] == 3'b001)));
assign d2_vipt_rmw_candidate = d2_seg_readable && !hardwired_off &&
                           (i_bus.ucode_action == RECIPE_ACTION_RMW_FAST) &&
                           (((i_bus.opcode == 8'hF6) ||
                             (i_bus.opcode == 8'hF7) ||
                             (i_bus.opcode == 8'hFE) ||
                             (i_bus.opcode == 8'hFF))
                                ? d2_vipt_rmw_opcode : 1'b1) &&
                           (i_bus.rep_lock == PREFIX_NOREPLOCK) &&
                           i_bus.has_modrm &&
                           (i_bus.modrm[7:6] != 2'b11) &&
                           !i_bus.has_moffs && !i_bus.stack_op &&
                           !single_step && !direct_hold;
assign d2_vipt_rmw = d2_vipt_rmw_candidate &&
                     dcache_vipt_probe_ready && !ucrd_route_pre && !ucrd_busy &&
                     !vipt_load_replay_r.valid && !vipt_load_slow_busy &&
                     // The retiring WR_FAST owns the demand preread, but a
                     // same-word successor can share it.  Admit the successor
                     // on the acceptance edge so N/N+1/N+2 is truly a
                     // three-cycle first-to-first sequence; backpressure still
                     // keeps the younger instruction out of EX.
                     (!rmw_fast_active_r || rmw_store_accepted) &&
                     !mem_servicing;

endmodule
`default_nettype wire

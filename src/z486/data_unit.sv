//
// Data Unit
// Register file, ALU, shifter, multiply/divide, flags and result forwarding
//
`include "z486_platform.svh"
module data_unit
    import z486_pkg::*;
(
    // Clock and reset
    input  logic        clk,
    input  logic        reset_n,

    // Microsequencer: current microword fields and E-stage enables
    input  logic        exec,                   // Execute the current micro-op
    input  logic        shift_exec,             // Execute registered shift control
    input  logic        pipeline_advance,        // Advance deferred flag state
    input  logic        repeat_active,
    input  logic [6:0]  aluop,
    input  logic [4:0]  alu_operation,
    input  logic        update_arch_flags,
    input  logic        update_carry,
    input  logic [6:0]  dest,
    input  logic [5:0]  source_field,
    input  logic [5:0]  source_live,             // Timing-selected live source field
    input  logic [5:0]  alu_source,
    input  logic [5:0]  alu_source_live,          // Timing-selected live ALU source
    input  logic        fpu_f8,
    input  logic [6:0]  shift_aluop,             // ROM-early ALU/jump field for shifter
    input  logic [1:0]  shift_sigma_sel,         // Registered barrel SIGMA selector
    input  logic [3:0]  shift_source_class,      // Predecoded shifter source class
    input  logic [1:0]  shift2_source,           // Predecoded SHIFT2 source
    input  logic        shift_is_shift2,         // Registered ROM SHIFT2 decode
    input  logic        shift_use_captured,      // Registered ROM decode: shifter uses its captured operand
    input  logic        shift2_capture_ce,       // Advance q_mem -> q operand capture
    input  logic        shift2_next_valid,       // q_mem word is SHIFT2
    input  logic [1:0]  shift2_next_source,      // q_mem SHIFT2 source class
    input  logic        shift_uc_carry,          // BSR loop needs carry immediately

    // Event control: instruction lifecycle, faults and interrupt delivery
    input  logic        instr_start,            // First cycle of a new instruction
    input  logic        uc_active,
    input  logic        halted,
    input  logic        ifetch_page_fault,
    input  logic        interrupt_entry,
    input  logic        any_fault,
    input  logic        clear_rf,
    input  logic        fault_set_rf,     // fault delivery: the pushed FLAGS image carries RF=1
    input  logic        gate_detect,
    output logic        flags_backup_active,

    // Decoder: EX and D2 instruction, operand sizes, stack-operation class (ispval)
    input  dec_entry_t  instr,
    input  dec_entry_t  next_instr,              // D2 instruction for setup lookahead
    input  logic [1:0]  op_size,
    input  logic        op_size_is0,             // op_size == 0, registered beside it
    input  logic        op_size_is1,             // op_size == 1, registered beside it
    input  logic [1:0]  srcreg_size,
    input  logic [1:0]  op_size_src,             // Source-mux operand size
    input  logic [1:0]  srcreg_size_src,          // Source-mux register size
    input  logic        is_dword,
    input  logic        is_signed_mul,
    input  logic        stack_op,
    input  logic        stack_dir,
    input  logic        stack_data32,
    input  logic        stack32,

    // Hardwired control: recipe state and deferred recipe commits
    input  logic        recipe_rni,               // Current recipe uStep contains RNI
    input  recipe_state_t recipe_state,           // Latched hardwired recipe
    input  logic        recipe_commit_cancel,     // Cancel deferred recipe commit
    output recipe_pending_write_t recipe_shift_write, // Deferred shift GPR commit
    output logic [31:0] recipe_shift_data,          // Deferred shift result
    output recipe_pending_write_t recipe_memory_write, // Deferred load GPR commit

    // Load pipeline: registered VIPT load write-back into the register file
    input  logic        load_wb_valid,             // Registered VIPT load WB
    input  logic        load_issue,                // A direct load issues (it writes back later)
    input  logic        load_pipe_flush,           // In-flight direct loads are dropped
    input  logic [2:0]  load_wb_dst,
    input  logic [1:0]  load_wb_size,
    input  logic [7:0]  load_wb_wmask,             // load_wb_valid ? 8'h01 << load_wb_widx : 0, registered
    input  logic [31:0] load_wb_view_hit,          // its forwarding-view hits per GPR byte, registered
    input  logic        load_wb_ah,                 // its AH lane select (producer-3 pv3f), registered
    input  logic [31:0] load_wb_data,
    input  logic        load_wb_is_alu,          // Registered memory operand feeds shared ALU
    input  logic [4:0]  load_wb_alu_op,
    input  logic        load_alu_dst_capture,    // Capture destination GPR at EX/WB boundary
    input  logic [2:0]  load_alu_dst_capture_dst,
    input  logic [1:0]  load_alu_dst_capture_size,
    input  logic [31:0] load_alu_dst_capture_data,
    input  logic        opr_fast_commit,        // A younger fast read replaces OPR_R

    // Shorters (US5142635): bypasses around the register file
    input  gpr_forward_t dly_gpr_forward,        // RNI-delay GPR bypass
    input  logic [31:0] dly_gpr_lanes,           // its GPR byte lanes [r*4 + b], registered
    input  logic [7:0]  dly_gpr_onehot,          // 8'h01 << its dst, registered
    output logic [31:0] eflags_fwd,               // Current-cycle flag forwarding
    output logic        branch_condition_true,    // Selected forwarded Jcc condition

    // Segmentation: I-bus base/index reads and address registers
    input  gpr_ref_t    ea_base,                 // Address-unit base GPR reference
    input  gpr_ref_t    ea_index,                // Address-unit index GPR reference
    output logic [31:0] ea_base_value,            // Base GPR value for address unit
    output logic [31:0] ea_index_value,           // Index GPR value for address unit
    input  logic [31:0] forwarded_esp,            // ESP including pending stack update
    output logic [7:0]  pend_write_mask,          // GPRs a late producer writes on this edge
    input  logic        x87_reg_commit,           // a direct register-form x87 op records FIP/FCS/FOP
    input  logic        x87_store_commit,         // a direct m32 store records FIP/FCS:FOP/operand
    input  logic [31:0] ind,
    input  logic [31:0] ea,

    // Segmentation and protection: selectors, descriptor and protection sources
    input  logic [15:0] es,
    input  logic [15:0] cs,
    input  logic [15:0] ss,
    input  logic [15:0] ds,
    input  logic [15:0] fs,
    input  logic [15:0] gs,
    input  logic [15:0] ldtr,
    input  logic [15:0] tr,
    input  logic [2:0]  seg_reg_sel,
    input  logic [31:0] desc_raw_hi,
    input  logic [31:0] slctr,
    input  logic [31:0] protun,
    input  logic        pe,
    input  logic [1:0]  cpl,
    output logic [31:0] protection_source_value, // Source value for protection unit
    output logic        protection_source_low16_nonzero,
    output logic [15:0] cs_source_value,          // Source value for CS updates

    // Cache and bus unit: memory operand in (R bus) and write data out
    input  logic [31:0] opr_r,
    output logic [31:0] opr_w,
    output logic [31:0] memory_write_source_value, // Narrow source mux for WR W

    // Control registers and restart state read as microcode sources
    input  logic [31:0] eip,
    input  logic [31:0] cr0,
    input  logic [31:0] cr2,
    input  logic [31:0] dr6,
    input  logic [31:0] dr7,
    input  logic [31:0] tmpeip,
    input  logic [31:0] tmpesp,

    // Register file, internal registers and flags (datapath state)
    output logic [31:0] eax,
    output logic [31:0] ecx,
    output logic [31:0] edx,
    output logic [31:0] ebx,
    output logic [31:0] esp,
    output logic [31:0] ebp,
    output logic [31:0] esi,
    output logic [31:0] edi,
    output logic [31:0] tmpc,
    output logic [31:0] tmpg,
    output logic [31:0] countr,
    output logic [31:0] eflags,
    output logic [31:0] uc_flags,
    output logic [31:0] flags_backup,

    // E-stage results
    output logic [31:0] sigma,
    output logic [31:0] alu_result,
    output logic [31:0] shift_result,
    output logic [31:0] muldiv_result,
    output logic        div_overflow,
    output logic        div_overflow_cond,
    output logic [31:0] alu_src,
    output logic [31:0] alu_src_hold,             // Registered ALU source operand
    output logic [31:0] source_value_live,        // Selected microcode source value
    output logic [31:0] alu_source_value_live,    // Selected ALU-source value
    output logic [31:0] dest_value,
    output logic        dbg_recipe_mem_killed,
    output logic        dbg_recipe_shift_killed
);

logic [31:0] alu_dst;
logic [31:0] alu_flags;
logic        alu_zsp_update;
logic [31:0] load_wb_commit_data;
logic        load_wb_alu_exec;
logic        load_wb_alu_commit;
logic [31:0] load_wb_alu_result;
logic [31:0] load_wb_alu_flags;
logic [31:0] load_wb_dst_base_r;

logic [31:0] tmpb, tmpd, tmpe, tmpf, tmph;
logic [31:0] csopcd, fsveip, oproff;
logic [2:0] src_reg_sel_r;           // EX-local copies of issued GPR selectors
logic [2:0] dst_reg_sel_r;
logic [2:0] recipe_shift_widx;       // Byte-normalized deferred-shift GPR
logic [7:0] recipe_memory_dst_onehot;// Byte-normalized deferred-load GPR
logic [1:0] recipe_memory_mode;      // Byte-low/high, word, or dword merge
// Deferred tokens stay valid until pipeline_advance and recommit every stalled
// cycle, which is what delivers late OPR_R data (e.g. POP). Once a younger
// producer has written the token's register, or a younger fast read has
// replaced OPR_R, a recommit would overwrite newer state: "mov eax,[upper]; and
// eax,[ebp-12]" kept the MOV value, and a following "inc [ebp-8]" leaked into
// EAX. Hazard and EA-invalidation logic still see .valid; only commit and
// forwarding stop. Suppressing such a write is safe by construction: a younger
// write to the same bytes already made the older value architecturally dead.
logic       recipe_memory_killed;
logic [31:0] recipe_memory_hit_r;       // producer 1's merge hits, see mem_hit_of
logic [31:0] recipe_shift_hit_r;        // producer 0's merge hits, see shift_hit_of
logic [7:0]  recipe_shift_wmask_r;      // its pend_write_mask one-hot
logic        recipe_shift_ah_r;         // its AH lane select, see shift_ah_of
logic       recipe_shift_killed;
assign dbg_recipe_mem_killed   = recipe_memory_killed;
assign dbg_recipe_shift_killed = recipe_shift_killed;

always_ff @(posedge clk) begin
    if (!reset_n) begin
        src_reg_sel_r <= 3'd0;
        dst_reg_sel_r <= 3'd0;
    end else if (instr_start) begin
        src_reg_sel_r <= next_instr.src_reg_sel;
        dst_reg_sel_r <= next_instr.dst_reg_sel;
    end
end

logic [31:0] shift_setup_result;
logic [1:0]  shift_data_size;
logic [1:0]  shift1_size;            // the shifter's captured SHIFT1 size
logic        shift_count_nonzero;
logic        shift_bit_test_cf;

logic        muldiv_sigma_write;
logic [31:0] muldiv_sigma_value;
logic        muldiv_tmpb_write;
logic [31:0] muldiv_tmpb_value;
logic        muldiv_counter_early_exit;
logic        muldiv_quotient_zero;
logic [5:0]  muldiv_div_flags;
logic        muldiv_flag_overflow;

logic sh_flags_commit;
logic sh_flags_we_zsp;
logic sh_flags_we_of;
logic sh_flags_cf;
logic sh_flags_of;
logic sh_flags_zf;
logic sh_flags_sf;
logic sh_flags_pf;

logic [31:0] shift2_capture_value;

logic        flag2_eflags_p;
logic        flag2_ucflags_p;
logic [31:0] flag2_result_r;
logic        flag2_cf_r;
logic        flag2_af_r;
logic        flag2_of_r;
logic        flag2_zsp_r;
logic [1:0]  flag2_size_r;
logic        clear_if_pending;

//=============================================================================
// Operand selection and EA forwarding
//=============================================================================

function automatic logic [31:0] read_gpr_value(
    input logic [2:0] reg_sel,
    input logic [1:0] size
);
    case (size)
        2'd0: begin
            case (reg_sel)
                3'd0: read_gpr_value = {24'd0, eax[7:0]};
                3'd1: read_gpr_value = {24'd0, ecx[7:0]};
                3'd2: read_gpr_value = {24'd0, edx[7:0]};
                3'd3: read_gpr_value = {24'd0, ebx[7:0]};
                3'd4: read_gpr_value = {24'd0, eax[15:8]};
                3'd5: read_gpr_value = {24'd0, ecx[15:8]};
                3'd6: read_gpr_value = {24'd0, edx[15:8]};
                3'd7: read_gpr_value = {24'd0, ebx[15:8]};
            endcase
        end
        2'd1: begin
            case (reg_sel)
                3'd0: read_gpr_value = {16'd0, eax[15:0]};
                3'd1: read_gpr_value = {16'd0, ecx[15:0]};
                3'd2: read_gpr_value = {16'd0, edx[15:0]};
                3'd3: read_gpr_value = {16'd0, ebx[15:0]};
                3'd4: read_gpr_value = {16'd0, esp[15:0]};
                3'd5: read_gpr_value = {16'd0, ebp[15:0]};
                3'd6: read_gpr_value = {16'd0, esi[15:0]};
                3'd7: read_gpr_value = {16'd0, edi[15:0]};
            endcase
        end
        default: begin
            case (reg_sel)
                3'd0: read_gpr_value = eax;
                3'd1: read_gpr_value = ecx;
                3'd2: read_gpr_value = edx;
                3'd3: read_gpr_value = ebx;
                3'd4: read_gpr_value = esp;
                3'd5: read_gpr_value = ebp;
                3'd6: read_gpr_value = esi;
                3'd7: read_gpr_value = edi;
            endcase
        end
    endcase
endfunction

// EA_FWD_* now lives in z486_pkg so gpr_write_merge shares the encoding.

// Form the plain-load architectural value once at WB.  The destination's
// prior full-width value was captured from the EX token one cycle earlier, so
// byte/word merging does not select the GPR bank from the live WB destination
// on the timing-critical successor-EA path.

wire [2:0] load_wb_widx = (load_wb_size == 2'd0)
                         ? {1'b0, load_wb_dst[1:0]} : load_wb_dst;

// Pending GPR writes: the i486's single writeback path with its E->D2 and
// WB->E bypasses. Every late producer names its byte-normalized destination
// as a one-hot; two forwarded register views are formed once from them and
// every reader indexes a view, instead of each read comparing every producer.
//   EX view  (operand reads)  plain-load WB data, then the ROM load commit
//   EA view  (D2 base/index)  delay-slot write, else deferred shift, else
//                             plain-load WB data
//   capture view (direct-load destination base) the EX view, then a deferred
//                             shift, then the delay-slot write, each merged
//                             at its width: the capture edge is the edge these
//                             commits land on
// A plain load's WB value is already merged with its destination's prior
// value; an M3 ALU result is not forwarded (its readers are interlocked).
wire [7:0] pend_shift_mask = recipe_shift_wmask_r;   // registered, see shift_hit_of
wire [7:0] pend_dly_mask   = dly_gpr_forward.valid ? dly_gpr_onehot : 8'h00;
// synthesis translate_off
always @(posedge clk)
    if (reset_n && dly_gpr_forward.valid &&
        ((dly_gpr_onehot !== (8'h01 << dly_gpr_forward.dst)) ||
         (dly_gpr_lanes !== ({28'h0, gpr_lanes_of_mode(dly_gpr_forward.mode)} <<
                             {(dly_gpr_forward.mode <= EA_FWD_BHI) ? {1'b0, dly_gpr_forward.dst[1:0]}
                                                                    : dly_gpr_forward.dst, 2'b00}))))
        $fatal(1, "data_unit: the delay-slot lanes/one-hot disagree with its descriptor");
// synthesis translate_on

// Producer arbitration.  Every deferred or in-flight register producer is
// merged once, in architectural age order, by gpr_write_merge, and both the
// register commit and the forwarding views are built from that single answer.
// Pattern P1 in docs/hazard-survey.md: an older deferred token used to win the
// forwarding views while the commit awarded the same bytes to the younger
// write-back, so a consumer could read a value the register never received.
//
// Views differ only in VISIBILITY, never in order:
//   EX view  (operand reads)  sees the memory token and the write-back
//   EA view  (D2 base/index)  sees the shift token, write-back and bypass; a D2
//                             consumer of a still-pending load is interlocked
//                             rather than bypassed, so it must not see the
//                             memory token's stale OPR_R
//   capture view (direct-load base) the EX set plus the shift token and bypass
wire [31:0] gpr_ex_view [0:7];
wire [31:0] gpr_ea_view [0:7];       // the full EA view, left to the benches (see ea_sel_a/b)
wire [31:0] gpr_capture_view [0:7];

wire        pr_shift_valid = recipe_shift_write.valid && !recipe_shift_killed;
wire        pr_mem_valid   = recipe_memory_write.valid && !recipe_memory_killed;
// The interrupt-entry writeback slot is the same write as the memory token: it
// retires OPR_R for the hardwired load whose RNI the interrupt displaced.
wire        pr_rom_valid   = interrupt_entry && recipe_rni && recipe_state.hardwired &&
                             (recipe_state.commit_sel == RECIPE_COMMIT_MEM);

// The three recipe commits retire at the RNI cycle.  They are consolidated into
// gpr_write_merge for the *register-file write* only, not as forwarding
// producers: the original separate write_gpr pulses are gone, so the pulse
// decode and lane mask are computed once, in the same age-ordered module as
// every other producer, and applied by a second merged write after the deferred
// producers and the ordinary EX writes.  Their relative order
// (stos < sigsrc < esp) and their enable conditions are exactly the original
// assignment order and guards of the register file - note the REP STOS count is
// deliberately *not* gated by recipe_commit_cancel, because a faulting store
// must still publish the remaining count so the REP restarts from the right
// element.
//
// They are deliberately hidden from the three forwarding views (the vis_* bits
// 7:5 stay clear below).  A recipe commit is the instruction's own retiring
// write: the only reader that can sample it in the commit cycle is that same
// instruction's microcode, which must see the pre-commit value.  A younger
// instruction's D2 EA latch is served by the register file on the next cycle or
// by the delay-slot bypass, never by these pulses.  Forwarding them was tried
// and is correct, but it puts the pulse decode on the EA/ALU forwarding cone
// and costs ~2.4 ns of setup slack; see the fit table in docs/hazard-survey.md.
wire pr_stos_valid = exec && !instr.has_0f &&
                     ((instr.opcode == 8'hAA) || (instr.opcode == 8'hAB)) &&
                     // F2 STOS repeats exactly like F3 (the microcode loop
                     // is shared), so both publish the restartable count.
                     ((instr.rep_lock == PREFIX_REP) ||
                      (instr.rep_lock == PREFIX_REPNE)) &&
                     (dest == DEST_eDI) && (source_field == SRC_SIGMA);
wire pr_sigsrc_valid = exec && recipe_rni && !recipe_commit_cancel &&
                       (recipe_state.commit_sel == RECIPE_COMMIT_SIGSRC);
wire pr_esp_valid = exec && recipe_rni && !recipe_commit_cancel &&
                    (recipe_state.commit_sel == RECIPE_COMMIT_ESP);

logic [255:0] pr_commit_value, pr_commit_wmask, pr_ex_value, pr_ea_value, pr_cap_value;
logic [255:0] pr_pulse_value, pr_pulse_wmask;
// The capture view's two selected-register reads (gpr_merge cap_a/cap_b).
wire [2:0]  load_capture_widx;
wire [31:0] load_capture_base;
wire [31:0] cap_src_value;
wire [31:0] ea_base_sel_value;
wire [31:0] ea_index_sel_value;
// The EX view of the dynamically selected registers (gpr_merge ex_*): the
// DSTREG and SRCREG registers and their byte-pair registers ({0, sel[1:0]},
// whose bytes 0/1 are AL..BL / AH..BH), and the IRF register countr[2:0].
wire [31:0] ex_dst_full, ex_dst_byte, ex_src_full, ex_src_byte, ex_irf_full;

// gpr_write_merge's producer-2 (ROM slot) AH lane select: op_size_is0 is the
// registered op_size == 0 decode (z486 op_size_dec_reg.v) and dst_reg_sel_r is
// the registered destination, so pv2's size compare is already off the merge
// cone.  A dedicated flop for the single AND
// was rejected: op_size_du and dst_reg_sel_r are written on independent edges
// (z486's i_issue/uc_exec and this module's instr_start), so one flop cannot
// track both without a new port, and the remaining AND is one LUT.
wire ah_rom = op_size_is0 && dst_reg_sel_r[2];

gpr_write_merge gpr_merge (
    .cur({edi, esi, ebp, esp, ebx, edx, ecx, eax}),

    .v_shift(pr_shift_valid),
    .hit_shift(recipe_shift_hit_r),
    .ah_shift(recipe_shift_ah_r),
    .dst_shift(recipe_shift_write.dst),
    .size_shift(recipe_shift_write.size),
    .data_shift(recipe_shift_data),

    .v_mem(pr_mem_valid),
    .hit_mem(recipe_memory_hit_r),
    .dst_mem(recipe_memory_write.dst),
    .mode_mem(recipe_memory_mode),
    .data_mem(opr_r),

    .v_rom(pr_rom_valid),
    .dst_rom(dst_reg_sel_r),
    .size_rom(op_size),
    .ah_rom(ah_rom),
    .data_rom(opr_r),

    .v_wb(load_wb_valid),
    .dst_wb(load_wb_dst),
    .size_wb(load_wb_size),
    .wb_is_alu(load_wb_is_alu),
    .data_wb(load_wb_commit_data),
    // The views forward producer 3 only when !load_wb_is_alu, where
    // load_wb_commit_data is load_wb_data: the M3 ALU stays off the views.
    .fwd_wb(load_wb_data),
    .hitv3_wb(load_wb_view_hit),
    .ah_wb(load_wb_ah),

    .v_dly(dly_gpr_forward.valid),
    .lanes_dly(dly_gpr_lanes),
    .dst_dly(dly_gpr_forward.dst),
    .mode_dly(dly_gpr_forward.mode),
    .data_dly(dly_gpr_forward.data),

    .v_stos(pr_stos_valid),
    .size_stos(instr.addr32 ? 2'd2 : 2'd1),
    .data_stos(countr),

    .v_sigsrc(pr_sigsrc_valid),
    .dst_sigsrc(src_reg_sel_r),
    .size_sigsrc(aluop == ALUJMP_BITS32 ? 2'd2 : 2'd1),
    .data_sigsrc(sigma),

    .v_esp(pr_esp_valid),
    .data_esp(sigma),

    // Recipe commits stay out of the forwarding views (bits 7:5 clear in all
    // three).  They retire at the RNI edge and are never sampled by a younger
    // consumer in that cycle, so forwarding them buys no correctness and puts
    // their decode on the EA/ALU cone (~2.4 ns of setup slack); the register
    // file still commits them through pulse_value/pulse_wmask below.
    .vis_ex(8'b0000_1010),      // mem, wb
    .vis_ea(8'b0001_1001),      // shift, wb, dly
    .vis_cap(8'b0001_1011),     // shift, mem, wb, dly

    .commit_value(pr_commit_value),
    .commit_wmask(pr_commit_wmask),
    .pulse_value(pr_pulse_value),
    .pulse_wmask(pr_pulse_wmask),
    .ex_value(pr_ex_value),
    .ea_value(pr_ea_value),
    .cap_value(pr_cap_value),
    // The two capture readers each select ONE register first (see
    // read_gpr_capture and load_capture_base below), so they take the
    // select-first ports and pr_cap_value is left to the bench.
    .cap_sel_a(op_size == 2'd0 ? {1'b0, src_reg_sel_r[1:0]} : src_reg_sel_r),
    .cap_sel_b(load_capture_widx),
    .cap_a_value(cap_src_value),
    .cap_b_value(load_capture_base),
    // The D2 base and index reads each select ONE register first, so the
    // full EA view (pr_ea_value) is left to the bench and synthesis drops it.
    .ea_sel_a(ea_base.index),
    .ea_sel_b(ea_index.index),
    .ea_a_value(ea_base_sel_value),
    .ea_b_value(ea_index_sel_value),
    // The dynamic EX operand reads each select their register first (see
    // read_gpr_fmt below): DSTREG full/byte-pair, SRCREG full/byte-pair, IRF.
    .ex_sel_a(dst_reg_sel_r),
    .ex_sel_b({1'b0, dst_reg_sel_r[1:0]}),
    .ex_sel_c(src_reg_sel_r),
    .ex_sel_d({1'b0, src_reg_sel_r[1:0]}),
    .ex_sel_e(countr[2:0]),
    .ex_a_value(ex_dst_full),
    .ex_b_value(ex_dst_byte),
    .ex_c_value(ex_src_full),
    .ex_d_value(ex_src_byte),
    .ex_e_value(ex_irf_full)
);

// synthesis translate_off
// Hazard-inventory monitor (A7, +monitor_hazards): a delay-slot bypass and a
// live deferred token or load write-back naming one architectural register
// in the same cycle.  Not an assertion: the merge order may make it legal.
function automatic [2:0] a7_reg(input [2:0] dst, input [1:0] mode);
    a7_reg = (mode == 2'd0 || mode == 2'd1) ? {1'b0, dst[1:0]} : dst;
endfunction
bit monitor_hazards;
initial monitor_hazards = $test$plusargs("monitor_hazards");
always @(posedge clk)
    if (reset_n && monitor_hazards && dly_gpr_forward.valid &&
        ((pr_mem_valid && a7_reg(recipe_memory_write.dst, recipe_memory_mode) ==
                          a7_reg(dly_gpr_forward.dst, dly_gpr_forward.mode)) ||
         (pr_shift_valid && recipe_shift_write.dst == dly_gpr_forward.dst) ||
         (load_wb_valid && load_wb_dst == dly_gpr_forward.dst)))
        $display("HAZARD A7: delay-slot bypass and token/WB on register %0d",
                 dly_gpr_forward.dst);
// synthesis translate_on


genvar gv;
generate
for (gv = 0; gv < 8; gv++) begin : g_view
    assign gpr_ex_view[gv]      = pr_ex_value[gv*32 +: 32];
    assign gpr_ea_view[gv]      = pr_ea_value[gv*32 +: 32];
    assign gpr_capture_view[gv] = pr_cap_value[gv*32 +: 32];
end
endgenerate

// The same read with the SIZE applied last: both register views are indexed by
// reg_sel alone and the size only picks among the formatted results.  For the
// shifter's operand the size is shift_data_size, a late, high-fan-out select
// (the fitted microcode q_shift_source_class_r -> use_captured_source ->
// data_size -> gpr_ex_view index -> shifter -> sigma clk_sys cone); indexing by
// it put that select in FRONT of the 8:1 view mux.  Bit-identical to
// read_gpr_load_forwarded for every input.
function automatic logic [31:0] read_gpr_load_forwarded_late(
    input logic [2:0] reg_sel,
    input logic [1:0] size
);
    logic [31:0] byte_src, full_src;
    logic [7:0]  byte_val;
    begin
        byte_src = gpr_ex_view[{1'b0, reg_sel[1:0]}];
        full_src = gpr_ex_view[reg_sel];
        byte_val = reg_sel[2] ? byte_src[15:8] : byte_src[7:0];
        read_gpr_load_forwarded_late = (size == 2'd0) ? {24'd0, byte_val} :
                                       (size == 2'd1) ? {16'd0, full_src[15:0]} :
                                                        full_src;
    end
endfunction

// read_gpr_load_forwarded_late at op_size, with the size compares taken from
// z486's registered decode (op_size_is0/is1 == op_size == 0/1 in every cycle):
// the fitted op_size_du (fo ~400) -> Equal -> the shifter/ALU operand mux
// paths lose the compare LUT and its routing hop. tests/equiv/
// op_size_dec_reg.v proves the registered decode equal to the compare by
// induction over z486's load edges; a translate_off fuse checks it every cycle.
function automatic logic [31:0] read_gpr_load_forwarded_op(input logic [2:0] reg_sel);
    logic [31:0] byte_src, full_src;
    logic [7:0]  byte_val;
    begin
        byte_src = gpr_ex_view[{1'b0, reg_sel[1:0]}];
        full_src = gpr_ex_view[reg_sel];
        byte_val = reg_sel[2] ? byte_src[15:8] : byte_src[7:0];
        read_gpr_load_forwarded_op = op_size_is0 ? {24'd0, byte_val} :
                                     op_size_is1 ? {16'd0, full_src[15:0]} :
                                                   full_src;
    end
endfunction
// synthesis translate_off
always @(posedge clk)
    if (reset_n && ((op_size_is0 !== (op_size == 2'd0)) || (op_size_is1 !== (op_size == 2'd1))))
        $fatal(1, "data_unit: op_size decode %b%b disagrees with op_size %0d",
               op_size_is0, op_size_is1, op_size);
// synthesis translate_on

// An EX operand read, formatted to its size: the read with the size applied
// last (read_gpr_load_forwarded_late), for every caller. The sizes the callers
// pass (op_size, op_size_src, srcreg_size_src, shift_data_size) are
// high-fan-out registers and the shifter's size select; indexing the 8:1 view
// by the size put them in FRONT of the view mux (the fitted op_size_du /
// q_shift_use_captured_r -> data_size -> view index -> shifter ->
// flags_value_r / sigma cone). tests/equiv/shift_src_late.v proves the
// late form equal to the size-indexed one for every input.
function automatic logic [31:0] read_gpr_load_forwarded(
    input logic [2:0] reg_sel,
    input logic [1:0] size
);
    read_gpr_load_forwarded = read_gpr_load_forwarded_late(reg_sel, size);
endfunction

// read_gpr_load_forwarded_late / _op for a register whose EX view was selected
// first (gpr_merge ex_*): full = view[reg_sel], bsrc = view[{0, reg_sel[1:0]}],
// hi = reg_sel[2].  The same format, so read_gpr_fmt(view[sel],
// view[{0,sel[1:0]}], sel[2], size) == read_gpr_load_forwarded_late(sel, size)
// (tests/equiv/ex_select_fmt.v; the selected values are fused against the view).
function automatic logic [31:0] read_gpr_fmt(input logic [31:0] full, input logic [31:0] bsrc,
                                             input logic hi, input logic [1:0] size);
    logic [7:0] byte_val;
    begin
        byte_val = hi ? bsrc[15:8] : bsrc[7:0];
        read_gpr_fmt = (size == 2'd0) ? {24'd0, byte_val} :
                       (size == 2'd1) ? {16'd0, full[15:0]} :
                                        full;
    end
endfunction
function automatic logic [31:0] read_gpr_fmt_op(input logic [31:0] full, input logic [31:0] bsrc,
                                                input logic hi);
    logic [7:0] byte_val;
    begin
        byte_val = hi ? bsrc[15:8] : bsrc[7:0];
        read_gpr_fmt_op = op_size_is0 ? {24'd0, byte_val} :
                          op_size_is1 ? {16'd0, full[15:0]} :
                                        full;
    end
endfunction
// synthesis translate_off
always @(posedge clk)
    if (reset_n && ((ex_dst_full !== gpr_ex_view[dst_reg_sel_r]) ||
                    (ex_dst_byte !== gpr_ex_view[{1'b0, dst_reg_sel_r[1:0]}]) ||
                    (ex_src_full !== gpr_ex_view[src_reg_sel_r]) ||
                    (ex_src_byte !== gpr_ex_view[{1'b0, src_reg_sel_r[1:0]}]) ||
                    (ex_irf_full !== gpr_ex_view[countr[2:0]])))
        $fatal(1, "data_unit: a selected EX read disagrees with the EX view");
// synthesis translate_on


// Every late GPR write landing on this edge (any direct-load WB included).
// The write-back's term is data_access's registered one-hot (loaded on the
// edges load_wb_valid/dst/size are), so the size compare and the index decode
// are not in front of the D2 split-EA wait and the issue decision.
assign pend_write_mask = pend_dly_mask | pend_shift_mask | load_wb_wmask;
// synthesis translate_off
always @(posedge clk)
    if (reset_n && (load_wb_wmask !== (load_wb_valid ? (8'h01 << load_wb_widx) : 8'h00)))
        $fatal(1, "data_unit: load_wb_wmask %b is not the write-back's one-hot", load_wb_wmask);
// synthesis translate_on

// A shift operand captured one cycle ahead (SHIFT2 SRCREG): a deferred shift
// or delay-slot write landing on the capture edge must be seen, as for a
// partial load's merge base.
function automatic logic [31:0] read_gpr_capture(
    input logic [2:0] reg_sel,
    input logic [1:0] size
);
    logic [31:0] merged;
    begin
        // The register is selected by gpr_merge's cap_sel_a port; the one
        // caller passes (src_reg_sel_r, op_size), the same operands as that port.
        merged = cap_src_value;
        if (size == 2'd0)
            read_gpr_capture = reg_sel[2] ? {24'd0, merged[15:8]}
                                          : {24'd0, merged[7:0]};
        else if (size == 2'd1)
            read_gpr_capture = {16'd0, merged[15:0]};
        else
            read_gpr_capture = merged;
    end
endfunction

// Every direct load captures its destination's prior value before cache data
// enters WB; a byte or word load merges into it. Older writes may still land
// on this capture edge (a chained load's WB, a ROM load, a deferred shift, a
// delay-slot write), so the base comes from the capture view. M3 uses the same
// value as its private ALU destination.
assign load_capture_widx = (load_alu_dst_capture_size == 2'd0)
                             ? {1'b0, load_alu_dst_capture_dst[1:0]}
                             : load_alu_dst_capture_dst;
// load_capture_base is gpr_merge's cap_b_value (selected by load_capture_widx).

always_ff @(posedge clk) begin
    if (!reset_n) begin
        load_wb_dst_base_r <= 32'd0;
    end else if (load_alu_dst_capture) begin
        load_wb_dst_base_r <= load_capture_base;
    end
end

function automatic logic [31:0] read_alu_source(input logic [5:0] field);
    case (field)
        ALUSRC_EAX: read_alu_source = read_gpr_load_forwarded(3'd0, 2'd2);
        ALUSRC_ECX: read_alu_source = read_gpr_load_forwarded(3'd1, 2'd2);
        ALUSRC_EDX: read_alu_source = read_gpr_load_forwarded(3'd2, 2'd2);
        ALUSRC_EBX: read_alu_source = read_gpr_load_forwarded(3'd3, 2'd2);
        ALUSRC_ESP: read_alu_source = read_gpr_load_forwarded(3'd4, 2'd2);
        ALUSRC_EBP: read_alu_source = read_gpr_load_forwarded(3'd5, 2'd2);
        ALUSRC_ESI: read_alu_source = read_gpr_load_forwarded(3'd6, 2'd2);
        ALUSRC_EDI: read_alu_source = read_gpr_load_forwarded(3'd7, 2'd2);
        ALUSRC_IMM8: read_alu_source = instr.has_modrm ? instr.immediate : instr.displacement;
        ALUSRC_IMM: read_alu_source = instr.immediate;
        ALUSRC_CONST_100: read_alu_source = 32'h100;
        ALUSRC_TMPB: read_alu_source = tmpb;
        ALUSRC_TMPC: read_alu_source = tmpc;
        ALUSRC_TMPD: read_alu_source = tmpd;
        ALUSRC_CONST_200: read_alu_source = 32'h200;
        ALUSRC_OPR_R: read_alu_source = opr_r;
        ALUSRC_TMPG: read_alu_source = tmpg;
        ALUSRC_TMPH: read_alu_source = slctr;
        ALUSRC_PROTUN: read_alu_source = protun;
        ALUSRC_ALLONES: read_alu_source = 32'hffff_ffff;
        ALUSRC_EFLAGS_PUSH: read_alu_source = 32'hfffc_ffff;
        ALUSRC_FLAGS_MASK: read_alu_source = 32'h0007_7fd7;
        ALUSRC_CONST_4000: read_alu_source = 32'h4000;
        ALUSRC_CONST_N200: read_alu_source = 32'hffff_fdff;
        ALUSRC_CONST_8: read_alu_source = 32'd8;
        ALUSRC_CONST_40: read_alu_source = 32'h40;
        ALUSRC_CONST_F0000: read_alu_source = 32'h000f_0000;
        ALUSRC_CONST_0D: read_alu_source = 32'h0d;
        ALUSRC_CONST_5D: read_alu_source = 32'h5d;
        ALUSRC_SIGMA: read_alu_source = sigma;
        ALUSRC_CONST_FC: read_alu_source = 32'h8000_00fc;
        ALUSRC_CONST_1: read_alu_source = 32'd1;
        ALUSRC_CONST_2: read_alu_source = 32'd2;
        ALUSRC_CONST_16: read_alu_source = 32'd16;
        ALUSRC_CONST_3: read_alu_source = 32'd3;
        ALUSRC_CONST_4: read_alu_source = 32'd4;
        ALUSRC_CONST_6: read_alu_source = 32'd6;
        ALUSRC_CONST_7: read_alu_source = 32'd7;
        ALUSRC_CONST_0F: read_alu_source = 32'h0f;
        ALUSRC_CONST_65: read_alu_source = 32'h65;
        ALUSRC_CONST_1F: read_alu_source = 32'h1f;
        ALUSRC_CONST_FFFF0000: read_alu_source = 32'hffff_0000;
        ALUSRC_CONST_60: read_alu_source = 32'h60;
        ALUSRC_CONST_7FF: read_alu_source = 32'h7ff;
        ALUSRC_CONST_9: read_alu_source = 32'd9;
        ALUSRC_CONST_29: read_alu_source = 32'h29;
        ALUSRC_CONST_70: read_alu_source = 32'h70;
        ALUSRC_CONST_73: read_alu_source = 32'h73;
        ALUSRC_CONST_1FF: read_alu_source = 32'h1ff;
        ALUSRC_CONST_8200: read_alu_source = 32'h8200;
        ALUSRC_CONST_71: read_alu_source = 32'h47;
        ALUSRC_CONST_NEG1: read_alu_source = 32'hffff_ffff;
        ALUSRC_CONST_NEG2: read_alu_source = 32'hffff_fffe;
        ALUSRC_CONST_NEG4: read_alu_source = 32'hffff_fffc;
        ALUSRC_MASK16: read_alu_source = 32'h0000_ffff;
        ALUSRC_CONST_0: read_alu_source = 32'd0;
        ALUSRC_WORDSZ: read_alu_source = is_dword ? 32'd4 :
                                         op_size == 2'd0 ? 32'd1 : 32'd2;
        ALUSRC_NEGWSZ: read_alu_source = is_dword ? 32'hffff_fffc :
                                         op_size == 2'd0 ? 32'hffff_ffff :
                                                           32'hffff_fffe;
        ALUSRC_INCREM: read_alu_source = eflags[10] ?
            (op_size == 2'd0 ? 32'hffff_ffff :
             op_size == 2'd1 ? 32'hffff_fffe : 32'hffff_fffc) :
            (op_size == 2'd0 ? 32'd1 : op_size == 2'd1 ? 32'd2 : 32'd4);
        ALUSRC_BITS_V: read_alu_source = op_size == 2'd0 ? 32'd7 :
                                          op_size == 2'd2 ? 32'd31 : 32'd15;
        ALUSRC_DSTREG: read_alu_source = read_gpr_fmt_op(ex_dst_full, ex_dst_byte, dst_reg_sel_r[2]);
        ALUSRC_SRCREG: read_alu_source = read_gpr_fmt_op(ex_src_full, ex_src_byte, src_reg_sel_r[2]);
        ALUSRC_ZERO: read_alu_source = 32'd0;
        default: read_alu_source = 32'd0;
    endcase
endfunction

function automatic logic [31:0] read_source(input logic [5:0] field);
    case (field)
        SRC_EAX: read_source = read_gpr_load_forwarded(3'd0, 2'd2);
        SRC_ECX: read_source = read_gpr_load_forwarded(3'd1, 2'd2);
        SRC_EDX: read_source = read_gpr_load_forwarded(3'd2, 2'd2);
        SRC_ESP: read_source = read_gpr_load_forwarded(3'd4, 2'd2);
        SRC_EBP: read_source = read_gpr_load_forwarded(3'd5, 2'd2);
        SRC_ESI: read_source = read_gpr_load_forwarded(3'd6, 2'd2);
        SRC_EDI: read_source = read_gpr_load_forwarded(3'd7, 2'd2);
        SRC_EIP: read_source = eip;
        SRC_EFLAGS: read_source = eflags;
        SRC_CR0: read_source = cr0;
        SRC_CR2: read_source = cr2;
        SRC_TMPB: read_source = tmpb;
        SRC_TMPC: read_source = tmpc;
        SRC_TMPD: read_source = tmpd;
        SRC_TMPE: read_source = tmpe;
        SRC_TMPF: read_source = tmpf;
        SRC_FLAGSB: read_source = flags_backup;
        SRC_TMPG: read_source = tmpg;
        SRC_TMPH: read_source = tmph;
        SRC_TMP_TR: read_source = slctr;
        SRC_COUNTR: read_source = countr;
        SRC_PROTUN: read_source = protun;
        SRC_TMPeIP: read_source = tmpeip;
        // The whole saved ESP: a fault restores it (89A) whatever the code size.
        SRC_TMPeSP: read_source = tmpesp;
        SRC_DR6: read_source = dr6;
        SRC_DR7: read_source = dr7;
        SRC_CSOPCD: read_source = csopcd;
        SRC_OPROFF: read_source = oproff;
        // MDTMP is factored beside this generic mux below. Keeping its
        // registered mul/div result out of this large source tree shortens
        // the common quotient/product-to-GPR writeback path.
        SRC_MDTMP: read_source = 32'd0;
        SRC_SIGMA: read_source = sigma;
        SRC_IMM: read_source = instr.immediate;
        SRC_ES: read_source = {16'd0, es};
        SRC_CS: read_source = {16'd0, cs};
        SRC_SS: read_source = {16'd0, ss};
        SRC_DS: read_source = {16'd0, ds};
        SRC_FS: read_source = {16'd0, fs};
        SRC_GS: read_source = {16'd0, gs};
        SRC_LDTR: read_source = {16'd0, ldtr};
        SRC_TR: read_source = {16'd0, tr};
        SRC_SLCTR: read_source = {16'd0, slctr[15:3], 3'b000};
        // Width-sensitive GPR sources are factored beside this generic mux.
        SRC_eAX_AL: read_source = 32'd0;
        SRC_eDX_AH: read_source = 32'd0;
        SRC_OPR_R: read_source = opr_r;
        SRC_IRF2: read_source = ind;
        SRC_EA: read_source = ea;
        SRC_eCX: read_source = read_gpr_load_forwarded(3'd1, 2'd2);
        SRC_IRF: read_source = 32'd0;
        SRC_USTEP_SEG_INDEX: read_source = {24'd0, 5'b10100, seg_reg_sel};
        SRC_FOP: read_source = {21'd0, instr.fop};
        SRC_SEGREG: begin
            case (seg_reg_sel)
                3'd0: read_source = {16'd0, es};
                3'd1: read_source = {16'd0, cs};
                3'd2: read_source = {16'd0, ss};
                3'd3: read_source = {16'd0, ds};
                3'd4: read_source = {16'd0, fs};
                3'd5: read_source = {16'd0, gs};
                default: read_source = 32'd0;
            endcase
        end
        SRC_DSTREG: read_source = 32'd0;
        SRC_SRCREG: read_source = 32'd0;
        SRC_NEG1: read_source = 32'hffff_ffff;
        default: read_source = 32'd0;
    endcase
endfunction

function automatic logic source_is_factored_gpr(input logic [5:0] field);
    case (field)
        SRC_eAX_AL, SRC_eDX_AH, SRC_IRF, SRC_DSTREG, SRC_SRCREG:
            source_is_factored_gpr = 1'b1;
        default: source_is_factored_gpr = 1'b0;
    endcase
endfunction

// These five sources share the byte/word/dword register formatter. Keeping
// them beside the generic microcode source mux prevents op_size from crossing
// the full source tree before descriptor and architectural writeback.
function automatic logic [31:0] read_factored_gpr_source(
    input logic [5:0] field
);
    case (field)
        SRC_eAX_AL: read_factored_gpr_source = read_gpr_load_forwarded(
            3'd0, op_size_src);
        SRC_eDX_AH: read_factored_gpr_source = read_gpr_load_forwarded(
            op_size_src == 2'd0 ? 3'd4 : 3'd2, op_size_src);
        // The IRF read is a word or dword (never the byte arm), so the full
        // register stands in for the byte-pair source.
        SRC_IRF: read_factored_gpr_source = read_gpr_fmt(
            ex_irf_full, ex_irf_full, countr[2], op_size_src == 2'd2 ? 2'd2 : 2'd1);
        SRC_DSTREG: read_factored_gpr_source = read_gpr_fmt(
            ex_dst_full, ex_dst_byte, dst_reg_sel_r[2], srcreg_size_src);
        SRC_SRCREG: read_factored_gpr_source = read_gpr_fmt(
            ex_src_full, ex_src_byte, src_reg_sel_r[2], op_size_src);
        default: read_factored_gpr_source = 32'd0;
    endcase
endfunction

// Dedicated protection and CS readers keep the full generic source mux off
// their timing-sensitive consumers while reusing the local GPR read ports.
function automatic logic [31:0] read_protection_source(
    input logic [5:0] field,
    input logic [31:0] generic_value
);
    case (field)
        SRC_ZERO:    read_protection_source = 32'd0;
        SRC_NEG1:    read_protection_source = 32'hffff_ffff;
        SRC_CR0:     read_protection_source = cr0;
        SRC_TMPH:    read_protection_source = tmph;
        SRC_TMP_TR:  read_protection_source = slctr;
        SRC_COUNTR:  read_protection_source = countr;
        SRC_PROTUN:  read_protection_source = protun;
        SRC_SIGMA:   read_protection_source = sigma;
        SRC_CS:      read_protection_source = {16'd0, cs};
        SRC_OPR_R:   read_protection_source = opr_r;
        SRC_IRF2:    read_protection_source = ind;
        SRC_TMPE:    read_protection_source = tmpe;
        SRC_DSTREG:  read_protection_source = read_gpr_value(dst_reg_sel_r,
                                                              srcreg_size);
        SRC_SRCREG:  read_protection_source = read_gpr_value(src_reg_sel_r,
                                                              op_size);
        default:     read_protection_source = generic_value;
    endcase
endfunction

function automatic logic [15:0] read_cs_source(
    input logic [5:0] field,
    input logic [31:0] generic_value
);
    case (field)
        SRC_SIGMA:  read_cs_source = sigma[15:0];
        SRC_TMPH:   read_cs_source = tmph[15:0];
        SRC_OPR_R:  read_cs_source = opr_r[15:0];
        SRC_PROTUN: read_cs_source = protun[15:0];
        default:    read_cs_source = generic_value[15:0];
    endcase
endfunction

// WR W uses a small, fixed subset of the microcode source field. Keep the
// generic source mux off the write-data path into paging and the cache.
function automatic logic [31:0] read_memory_write_source(input logic [5:0] field);
    case (field)
        SRC_TMPB:   read_memory_write_source = tmpb;
        SRC_CR0:    read_memory_write_source = cr0;
        SRC_IMM:    read_memory_write_source = instr.immediate;
        SRC_FOP:    read_memory_write_source = {21'd0, instr.fop};
        SRC_PROTUN: read_memory_write_source = protun;
        SRC_SIGMA:  read_memory_write_source = sigma;
        SRC_ES:     read_memory_write_source = {16'd0, es};
        SRC_CS:     read_memory_write_source = {16'd0, cs};
        SRC_SS:     read_memory_write_source = {16'd0, ss};
        SRC_DS:     read_memory_write_source = {16'd0, ds};
        SRC_FS:     read_memory_write_source = {16'd0, fs};
        SRC_GS:     read_memory_write_source = {16'd0, gs};
        SRC_LDTR:   read_memory_write_source = {16'd0, ldtr};
        SRC_TR:     read_memory_write_source = {16'd0, tr};
        SRC_SEGREG: begin
            case (seg_reg_sel)
                3'd0: read_memory_write_source = {16'd0, es};
                3'd1: read_memory_write_source = {16'd0, cs};
                3'd2: read_memory_write_source = {16'd0, ss};
                3'd3: read_memory_write_source = {16'd0, ds};
                3'd4: read_memory_write_source = {16'd0, fs};
                3'd5: read_memory_write_source = {16'd0, gs};
                default: read_memory_write_source = 32'd0;
            endcase
        end
        SRC_IRF: read_memory_write_source = read_gpr_fmt(
            ex_irf_full, ex_irf_full, countr[2], op_size_src == 2'd2 ? 2'd2 : 2'd1);
        default: read_memory_write_source = 32'd0;
    endcase
endfunction

always_comb begin
    source_value_live = source_live == SRC_MDTMP ? muldiv_result :
                        source_is_factored_gpr(source_live)
                      ? read_factored_gpr_source(source_live)
                      : read_source(source_live);
    memory_write_source_value = read_memory_write_source(source_live);
    alu_source_value_live = read_alu_source(alu_source_live);
    // source_field is a timing replica of source_live (both load from the
    // same ROM word on the same enable), so one source tree serves both.
    alu_dst = source_value_live;
    dest_value = alu_dst;
    // alu_source is a timing replica of alu_source_live (same ROM field,
    // same load enable), so the ALU source shares the live tree.
    alu_src = fpu_f8 ? 32'h8000_00f8 : alu_source_value_live;
    protection_source_value = read_protection_source(source_live,
                                                     source_value_live);
    protection_source_low16_nonzero = |protection_source_value[15:0];
    cs_source_value = read_cs_source(source_live, source_value_live);
    ea_base_value = ea_base.valid ? ea_base_sel_value : 32'd0;
    ea_index_value = ea_index.valid ? ea_index_sel_value : 32'd0;
end

// synthesis translate_off
// Each narrow arm must match read_source for its field (DSTREG/SRCREG are
// intentionally factored and excluded).
localparam int PROTECTION_EQUIV_COUNT = 12;
localparam logic [5:0] PROTECTION_EQUIV_FIELDS [PROTECTION_EQUIV_COUNT] = '{
    SRC_ZERO, SRC_NEG1, SRC_CR0, SRC_TMPH, SRC_TMP_TR, SRC_COUNTR,
    SRC_PROTUN, SRC_SIGMA, SRC_CS, SRC_OPR_R, SRC_IRF2, SRC_TMPE
};
always @(posedge clk) begin
    if (reset_n) begin
        for (int i = 0; i < PROTECTION_EQUIV_COUNT; i++) begin
            if (read_protection_source(PROTECTION_EQUIV_FIELDS[i],
                                       read_source(PROTECTION_EQUIV_FIELDS[i])) !==
                read_source(PROTECTION_EQUIV_FIELDS[i]))
                $fatal(1, "PROTECTION SOURCE MUX MISMATCH: field=%0d narrow=%08x generic=%08x",
                       PROTECTION_EQUIV_FIELDS[i],
                       read_protection_source(PROTECTION_EQUIV_FIELDS[i],
                                              read_source(PROTECTION_EQUIV_FIELDS[i])),
                       read_source(PROTECTION_EQUIV_FIELDS[i]));
        end
    end
end
// synthesis translate_on

//=============================================================================
// Internal registers and architectural GPR writeback
//=============================================================================

always_ff @(posedge clk) begin
    if (!reset_n) begin
        tmpb   <= 32'd0;
        tmpc   <= 32'd0;
        tmpd   <= 32'd0;
        tmpe   <= 32'd0;
        tmpf   <= 32'd0;
        tmpg   <= 32'd0;
        tmph   <= 32'd0;
        csopcd <= 32'd0;
        fsveip <= 32'd0;
        oproff <= 32'd0;
        opr_w  <= 32'd0;
    end else if (exec) begin
        case (dest)
            DEST_TMPB:   tmpb   <= dest_value;
            DEST_TMPC:   tmpc   <= dest_value;
            DEST_TMPD:   tmpd   <= dest_value;
            DEST_TMPE:   tmpe   <= dest_value;
            DEST_TMPF:   tmpf   <= dest_value;
            DEST_TMPG:   tmpg   <= dest_value;
            DEST_TMPH:   tmph   <= dest_value;
            DEST_CSOPCD: csopcd <= dest_value;
            DEST_FSVeIP: fsveip <= dest_value;
            DEST_OPROFF: oproff <= dest_value;
            DEST_OPR_W:  opr_w  <= dest_value;
            default: ;
        endcase

        if (aluop == ALUJMP_PTSELE && !gate_detect)
            tmph <= alu_dst;

        // The 4CE/4CF/4D0 moves of the original routine, for a register-form
        // x87 instruction that posted its command directly.
        if (x87_reg_commit) begin
            fsveip <= tmpeip;
            csopcd <= {16'd0, cs};
            tmpf   <= {21'd0, instr.fop};
        end
        // The store routine's moves: CSOPCD = FOP << 16 | CS (53D/555/557),
        // OPROFF = the operand offset (53E/575), FSVeIP (56E), TMPF (56A).
        if (x87_store_commit) begin
            fsveip <= tmpeip;
            csopcd <= {5'd0, instr.fop, cs};
            oproff <= ind;
            tmpf   <= {21'd0, instr.fop};
        end

        if (gate_detect) begin
            tmpb <= desc_raw_hi;
            tmph <= {16'd0, tmpc[31:16]};
            tmpg <= {desc_raw_hi[31:16], tmpc[15:0]};
        end

        if (muldiv_tmpb_write)
            tmpb <= muldiv_tmpb_value;
    end
end

task automatic write_gpr(
    input logic [2:0] reg_sel,
    input logic [31:0] value,
    input logic [1:0] size
);
    case (size)
        2'd0: begin
            case (reg_sel)
                3'd0: eax[7:0]    <= value[7:0];
                3'd1: ecx[7:0]    <= value[7:0];
                3'd2: edx[7:0]    <= value[7:0];
                3'd3: ebx[7:0]    <= value[7:0];
                3'd4: eax[15:8]   <= value[7:0];
                3'd5: ecx[15:8]   <= value[7:0];
                3'd6: edx[15:8]   <= value[7:0];
                3'd7: ebx[15:8]   <= value[7:0];
            endcase
        end
        2'd1: begin
            case (reg_sel)
                3'd0: eax[15:0]     <= value[15:0];
                3'd1: ecx[15:0]     <= value[15:0];
                3'd2: edx[15:0]     <= value[15:0];
                3'd3: ebx[15:0]     <= value[15:0];
                3'd4: esp[15:0]     <= value[15:0];
                3'd5: ebp[15:0]     <= value[15:0];
                3'd6: esi[15:0]     <= value[15:0];
                3'd7: edi[15:0]     <= value[15:0];
            endcase
        end
        2'd2: begin
            case (reg_sel)
                3'd0: eax     <= value;
                3'd1: ecx <= value;
                3'd2: edx     <= value;
                3'd3: ebx     <= value;
                3'd4: esp     <= value;
                3'd5: ebp     <= value;
                3'd6: esi     <= value;
                3'd7: edi     <= value;
            endcase
        end
        default: ;
    endcase
endtask

// A younger producer writing the same bytes as a still-valid deferred token
// retires the token's commit (and its forwarding) for the rest of the stall.
function automatic [3:0] gpr_lanes_of_mode(input [1:0] mode);
    gpr_lanes_of_mode = (mode == EA_FWD_BLO) ? 4'h1 : (mode == EA_FWD_BHI) ? 4'h2 :
                        (mode == EA_FWD_W)   ? 4'h3 : 4'hF;
endfunction
// The memory token's (producer 1's) merge hit per GPR byte [r*4 + b]:
// (recipe_memory_write.valid && !recipe_memory_killed) ? its lanes at register
// dst_norm(1) : 0, registered on the edges those registers change so the
// valid/killed AND and the register/lane decode are not in front of the
// views (C4x: recipe_memory_killed -> hit1 -> ex_value). Loaded with the
// token at pipeline_advance, cleared by the kill events below, held
// otherwise; tests/equiv/mem_hit_reg.v proves it equal every cycle.
function automatic [31:0] mem_hit_of(input [2:0] dst, input [1:0] mode);
    logic [2:0] r;
    logic [3:0] be;
    begin
        r  = ((mode == EA_FWD_BLO) || (mode == EA_FWD_BHI)) ? {1'b0, dst[1:0]} : dst;
        be = (mode == EA_FWD_BLO) ? 4'h1 : (mode == EA_FWD_BHI) ? 4'h2 :
             (mode == EA_FWD_W)   ? 4'h3 : 4'hF;
        mem_hit_of = {28'h0, be} << {r, 2'b00};
    end
endfunction
wire [1:0] recipe_memory_mode_next = (op_size == 2'd0)
                                   ? (dst_reg_sel_r[2] ? EA_FWD_BHI : EA_FWD_BLO)
                                   : (op_size == 2'd1 ? EA_FWD_W : EA_FWD_D);
wire       recipe_memory_kill = (load_wb_valid && !recipe_commit_cancel &&
                                 recipe_memory_dst_onehot[load_wb_widx]) || opr_fast_commit;
always_ff @(posedge clk) begin
    if (!reset_n)
        recipe_memory_hit_r <= 32'h0;
    else if (pipeline_advance)
        recipe_memory_hit_r <= (recipe_rni && exec && instr_start && !recipe_commit_cancel &&
                                (recipe_state.commit_sel == RECIPE_COMMIT_MEM))
                             ? mem_hit_of(dst_reg_sel_r, recipe_memory_mode_next) : 32'h0;
    else if (recipe_memory_kill)
        recipe_memory_hit_r <= 32'h0;
end
// synthesis translate_off
always @(posedge clk)
    if (reset_n && (recipe_memory_hit_r !==
                    (pr_mem_valid ? mem_hit_of(recipe_memory_write.dst, recipe_memory_mode) : 32'h0)))
        $fatal(1, "data_unit: memory-token hits %h disagree with the token", recipe_memory_hit_r);
// synthesis translate_on

// The same for the deferred shift (producer 0): its merge hits per GPR byte
// and its pend_write_mask one-hot, (recipe_shift_write.valid &&
// !recipe_shift_killed) ? ... : 0, registered on the edges those registers
// change (tests/equiv/shift_hit_reg.v).
function automatic [31:0] shift_hit_of(input [2:0] dst, input [1:0] size);
    logic [2:0] r;
    logic [3:0] be;
    begin
        r  = (size == 2'd0) ? {1'b0, dst[1:0]} : dst;
        be = (size == 2'd0) ? (dst[2] ? 4'h2 : 4'h1) : (size == 2'd1) ? 4'h3 : 4'hF;
        shift_hit_of = {28'h0, be} << {r, 2'b00};
    end
endfunction
// Producer 0's AH lane select (gpr_write_merge lane_of's `ah`): the shift
// token's lane 1 is data[7:0] for a byte write to AH.
function automatic logic shift_ah_of(input logic [2:0] dst, input logic [1:0] size);
    shift_ah_of = (size == 2'd0) && dst[2];
endfunction
wire       recipe_shift_kill = load_wb_valid && !recipe_commit_cancel &&
                               (recipe_shift_widx == load_wb_widx);
wire       recipe_shift_load = recipe_rni && exec && !recipe_commit_cancel &&
                               (recipe_state.commit_sel == RECIPE_COMMIT_SHIFT);
always_ff @(posedge clk) begin
    if (!reset_n) begin
        recipe_shift_hit_r   <= 32'h0;
        recipe_shift_wmask_r <= 8'h0;
        recipe_shift_ah_r    <= 1'b0;
    end else if (pipeline_advance) begin
        recipe_shift_hit_r   <= recipe_shift_load ? shift_hit_of(dst_reg_sel_r, op_size) : 32'h0;
        recipe_shift_wmask_r <= recipe_shift_load
                              ? (8'h01 << ((op_size == 2'd0) ? {1'b0, dst_reg_sel_r[1:0]}
                                                             : dst_reg_sel_r))
                              : 8'h0;
        recipe_shift_ah_r    <= recipe_shift_load ? shift_ah_of(dst_reg_sel_r, op_size) : 1'b0;
    end else if (recipe_shift_kill) begin
        recipe_shift_hit_r   <= 32'h0;
        recipe_shift_wmask_r <= 8'h0;
        recipe_shift_ah_r    <= 1'b0;
    end
end
// synthesis translate_off
always @(posedge clk)
    if (reset_n && ((recipe_shift_hit_r !==
                     (pr_shift_valid ? shift_hit_of(recipe_shift_write.dst, recipe_shift_write.size) : 32'h0)) ||
                    (recipe_shift_wmask_r !==
                     (pr_shift_valid ? (8'h01 << recipe_shift_widx) : 8'h00)) ||
                    (recipe_shift_ah_r !==
                     (pr_shift_valid
                      ? shift_ah_of(recipe_shift_write.dst, recipe_shift_write.size) : 1'b0))))
        $fatal(1, "data_unit: shift-token hits %h / mask %b / AH %b disagree with the token",
               recipe_shift_hit_r, recipe_shift_wmask_r, recipe_shift_ah_r);
// synthesis translate_on

// opr_fast_commit needs no destination: once OPR_R is replaced, the token's
// only data source is gone, so any later recommit would write foreign data.
always_ff @(posedge clk) begin
    if (!reset_n) begin
        recipe_memory_killed <= 1'b0;
        recipe_shift_killed <= 1'b0;
    end else if (!pipeline_advance) begin
        if (recipe_memory_kill)
            recipe_memory_killed <= 1'b1;
        if (recipe_shift_kill)
            recipe_shift_killed <= 1'b1;
    end else begin
        recipe_memory_killed <= 1'b0;
        recipe_shift_killed <= 1'b0;
    end
end

// Commit the merged producer arbitration: exactly the byte lanes the winning
// producers own, taken from the same value the forwarding views are built from.
task automatic commit_merged(input logic [255:0] value, input logic [255:0] wmask);
    for (int r = 0; r < 8; r++) begin
        automatic logic [31:0] rv = value[r*32 +: 32];
        automatic logic [31:0] rm = wmask[r*32 +: 32];
        case (r)
            3'd0: begin
                if (rm[0])  eax[7:0]   <= rv[7:0];
                if (rm[8]) eax[15:8]  <= rv[15:8];
                if (rm[16]) eax[23:16] <= rv[23:16];
                if (rm[24]) eax[31:24] <= rv[31:24];
            end
            3'd1: begin
                if (rm[0])  ecx[7:0]   <= rv[7:0];
                if (rm[8]) ecx[15:8]  <= rv[15:8];
                if (rm[16]) ecx[23:16] <= rv[23:16];
                if (rm[24]) ecx[31:24] <= rv[31:24];
            end
            3'd2: begin
                if (rm[0])  edx[7:0]   <= rv[7:0];
                if (rm[8]) edx[15:8]  <= rv[15:8];
                if (rm[16]) edx[23:16] <= rv[23:16];
                if (rm[24]) edx[31:24] <= rv[31:24];
            end
            3'd3: begin
                if (rm[0])  ebx[7:0]   <= rv[7:0];
                if (rm[8]) ebx[15:8]  <= rv[15:8];
                if (rm[16]) ebx[23:16] <= rv[23:16];
                if (rm[24]) ebx[31:24] <= rv[31:24];
            end
            3'd4: begin
                if (rm[0])  esp[7:0]   <= rv[7:0];
                if (rm[8]) esp[15:8]  <= rv[15:8];
                if (rm[16]) esp[23:16] <= rv[23:16];
                if (rm[24]) esp[31:24] <= rv[31:24];
            end
            3'd5: begin
                if (rm[0])  ebp[7:0]   <= rv[7:0];
                if (rm[8]) ebp[15:8]  <= rv[15:8];
                if (rm[16]) ebp[23:16] <= rv[23:16];
                if (rm[24]) ebp[31:24] <= rv[31:24];
            end
            3'd6: begin
                if (rm[0])  esi[7:0]   <= rv[7:0];
                if (rm[8]) esi[15:8]  <= rv[15:8];
                if (rm[16]) esi[23:16] <= rv[23:16];
                if (rm[24]) esi[31:24] <= rv[31:24];
            end
            default: begin
                if (rm[0])  edi[7:0]   <= rv[7:0];
                if (rm[8]) edi[15:8]  <= rv[15:8];
                if (rm[16]) edi[23:16] <= rv[23:16];
                if (rm[24]) edi[31:24] <= rv[31:24];
            end
        endcase
    end
endtask

// Deferred recipe commits are Data Unit writeback state. Chain control observes
// the compact pending descriptors for dependency checks and D2 forwarding.
always_ff @(posedge clk) begin
    if (!reset_n) begin
        recipe_shift_write <= '0;
        recipe_shift_widx <= 3'd0;
        recipe_memory_write <= '0;
        recipe_memory_dst_onehot <= 8'd0;
        recipe_memory_mode <= EA_FWD_D;
    end else if (pipeline_advance) begin
        recipe_memory_write.valid <= recipe_rni && exec && instr_start &&
                                   !recipe_commit_cancel &&
                                   (recipe_state.commit_sel == RECIPE_COMMIT_MEM);
        if (recipe_rni && exec && instr_start &&
            (recipe_state.commit_sel == RECIPE_COMMIT_MEM)) begin
            recipe_memory_write.dst <= dst_reg_sel_r;
            recipe_memory_write.size <= op_size;
            recipe_memory_dst_onehot <= 8'b1 << ((op_size == 2'd0)
                                               ? {1'b0, dst_reg_sel_r[1:0]}
                                               : dst_reg_sel_r);
            recipe_memory_mode <= recipe_memory_mode_next;
        end

        recipe_shift_write.valid <= recipe_shift_load;
        if (recipe_rni && exec &&
            (recipe_state.commit_sel == RECIPE_COMMIT_SHIFT)) begin
            recipe_shift_write.dst <= dst_reg_sel_r;
            recipe_shift_write.size <= op_size;
            recipe_shift_widx <= (op_size == 2'd0)
                               ? {1'b0, dst_reg_sel_r[1:0]}
                               : dst_reg_sel_r;
            recipe_shift_data <= shift_result;
        end
    end
end

// synthesis translate_off
// Deferred-writer checks. Lane = {valid, normalized_reg[2:0], byte_enable[3:0]}.
// A successor load may overlap an older memory or shift token: the younger load
// wins by assignment order. A stalled shift must then stay suppressed.
logic du_shift_load_kill_due;
always_ff @(posedge clk) begin
    du_shift_load_kill_due <= reset_n && !recipe_commit_cancel &&
        recipe_shift_write.valid && !recipe_shift_killed && load_wb_valid &&
        (recipe_shift_widx == load_wb_widx) && !pipeline_advance;
    if (reset_n && du_shift_load_kill_due && !recipe_shift_killed)
        $fatal(1, "Deferred shift remained live after younger load writeback");
end
function automatic logic [3:0] du_lane_be(input logic [2:0] sel,
                                         input logic [1:0] size);
    du_lane_be = (size == 2'd0) ? (sel[2] ? 4'b0010 : 4'b0001)
               : (size == 2'd1) ? 4'b0011
               :                  4'b1111;
endfunction

function automatic logic [2:0] du_lane_reg(input logic [2:0] sel,
                                           input logic [1:0] size);
    du_lane_reg = (size == 2'd0) ? {1'b0, sel[1:0]} : sel;
endfunction

// Reports "1" when two {valid, reg, be} lanes overlap on a byte.
function automatic logic du_lane_overlap(input logic [7:0] a,
                                         input logic [7:0] b);
    du_lane_overlap = a[7] && b[7] && (a[6:4] == b[6:4]) &&
                      (|(a[3:0] & b[3:0]));
endfunction

always_ff @(posedge clk) begin
    if (reset_n && recipe_shift_write.valid &&
        (recipe_shift_widx !== ((recipe_shift_write.size == 2'd0)
                              ? {1'b0, recipe_shift_write.dst[1:0]}
                              : recipe_shift_write.dst)))
        $fatal(1, "Deferred shift normalized destination mismatch");
end

// A shift token and a memory token must never target overlapping bytes of one
// register: they are independent deferred producers with no age ordering
// between them, so an overlap could not be resolved by assignment order.
always_ff @(posedge clk) begin
    logic [7:0] shift_lane, mem_lane;
    if (reset_n && !recipe_commit_cancel) begin
        shift_lane = recipe_shift_write.valid && !recipe_shift_killed
            ? {1'b1, recipe_shift_widx,
               du_lane_be(recipe_shift_write.dst, recipe_shift_write.size)}
            : 8'h00;
        mem_lane = recipe_memory_write.valid && !recipe_memory_killed
            ? {1'b1, du_lane_reg(recipe_memory_write.dst,
                                 recipe_memory_write.size),
               du_lane_be(recipe_memory_write.dst, recipe_memory_write.size)}
            : 8'h00;

        if (du_lane_overlap(shift_lane, mem_lane))
            $fatal(1, "DUP GPR WRITER shift/mem reg %0d", mem_lane[6:4]);
    end
end
// synthesis translate_on

// The microcode destination's architectural register write, decoded once into
// one register selector, size and value so the register file has a single
// write port to merge (a destination names at most one register).
logic        gpr_wr_en;
logic [2:0]  gpr_wr_sel;
logic [1:0]  gpr_wr_size;
logic [31:0] gpr_wr_data;
always_comb begin
    gpr_wr_en   = 1'b1;
    gpr_wr_sel  = 3'd0;
    gpr_wr_size = 2'd2;
    gpr_wr_data = dest_value;
    case (dest)
        DEST_EAX:    gpr_wr_sel = 3'd0;
        DEST_EDX:    gpr_wr_sel = 3'd2;
        DEST_ESP:    gpr_wr_sel = 3'd4;
        DEST_eSP: begin
            gpr_wr_sel = 3'd4;
            if (!(pe && stack32))
                gpr_wr_size = 2'd1;
        end
        DEST_EBP:    gpr_wr_sel = 3'd5;
        DEST_DSTREG: begin gpr_wr_sel = dst_reg_sel_r; gpr_wr_size = op_size; end
        DEST_SRCREG: begin gpr_wr_sel = src_reg_sel_r; gpr_wr_size = op_size; end
        DEST_AX:     begin gpr_wr_sel = 3'd0; gpr_wr_size = 2'd1; end
        DEST_BP:     begin gpr_wr_sel = 3'd5; gpr_wr_size = 2'd1; end
        DEST_eAX_AL: begin gpr_wr_sel = 3'd0; gpr_wr_size = op_size; end
        DEST_eDX_AH: begin gpr_wr_sel = (op_size == 2'd0) ? 3'd4 : 3'd2;
                           gpr_wr_size = op_size; end
        DEST_eCX:    begin gpr_wr_sel = 3'd1; gpr_wr_size = instr.addr32 ? 2'd2 : 2'd1; end
        DEST_eSI:    begin gpr_wr_sel = 3'd6; gpr_wr_size = instr.addr32 ? 2'd2 : 2'd1; end
        DEST_eDI:    begin gpr_wr_sel = 3'd7; gpr_wr_size = instr.addr32 ? 2'd2 : 2'd1; end
        DEST_AL:     begin gpr_wr_sel = 3'd0; gpr_wr_size = 2'd0; end
        DEST_AH:     begin gpr_wr_sel = 3'd4; gpr_wr_size = 2'd0; end
        DEST_USTEP_BSWAP: begin
            gpr_wr_sel  = src_reg_sel_r;
            gpr_wr_data = {dest_value[7:0], dest_value[15:8],
                           dest_value[23:16], dest_value[31:24]};
        end
        // The ALU result lands in the recipe's destination register.
        DEST_USTEP_ALU: begin
            gpr_wr_en   = recipe_state.hardwired && !recipe_commit_cancel;
            gpr_wr_sel  = dst_reg_sel_r;
            gpr_wr_size = op_size;
            gpr_wr_data = alu_result;
        end
        // POPA/POPAD discard the popped ESP slot (their eSP words set the
        // pointer); a task switch's IRF loads do write ESP.
        DEST_IRF: begin
            gpr_wr_en   = irf_writes_gpr(countr, instr.has_0f, instr.opcode);
            gpr_wr_sel  = countr[2:0];
            gpr_wr_size = is_dword ? 2'd2 : 2'd1;
        end
        default:     gpr_wr_en = 1'b0;
    endcase
end

// All GPR producers retain their original ordering. Later assignments are
// younger and therefore win when two producers target the same register.
always_ff @(posedge clk) begin
    if (!reset_n) begin
        eax     <= 32'd0;
        ecx     <= 32'd0;
        // 486SX-class signature (family 4 / model 2, no FPU/CPUID): the old
        // 0x0303 was a 386 ID.  PC-98 firmware dispatches on this at reset.
        edx     <= 32'h0000_0420;
        ebx     <= 32'd0;
        esp     <= 32'd0;
        ebp     <= 32'd0;
        esi     <= 32'd0;
        edi     <= 32'd0;
    end else begin
        // One merged write for every deferred/in-flight producer, in canonical
        // age order (gpr_write_merge).  A fault cancels the deferred commits.
        if (!recipe_commit_cancel)
            commit_merged(pr_commit_value, pr_commit_wmask);

        if (exec) begin
            if (gpr_wr_en)
                write_gpr(gpr_wr_sel, gpr_wr_data, gpr_wr_size);

            // REP STOS records its restartable count only after the element
            // store has cleared DLY. The loop can then bypass its redundant
            // COUNTR->eCX word without exposing a decremented count on a
            // faulting store.
            //
            // The three recipe commits (REP STOS count, SIGSRC, ESP) are merged
            // here rather than written one at a time: gpr_write_merge has
            // already arbitrated them, so this single write keeps the register
            // file on the one canonical age order.  They are not forwarded to
            // the views (see the vis_* comment at the merge instantiation).
            if (exec)
                commit_merged(pr_pulse_value, pr_pulse_wmask);

        end
    end
end

//=============================================================================
// Arithmetic state and flags
//=============================================================================

// Arithmetic state is retired beside its producer so result selection does
// not cross the top-level module boundary.
wire flag2_class_uc = (aluop == ALUJMP_ALU)    || (aluop == ALUJMP_INCDEC) ||
                      (aluop == ALUJMP_CMPTST) || (aluop == ALUJMP_AND)    ||
                      (aluop == ALUJMP_OR)     || (aluop == ALUJMP_XOR)    ||
                      (aluop == ALUJMP_ADD)    || (aluop == ALUJMP_ADC)    ||
                      (aluop == ALUJMP_SUB)    || (aluop == ALUJMP_CMP)    ||
                      (aluop == ALUJMP_AAAAAS) || (aluop == ALUJMP_DAADAS);

wire flag2_zf = flag2_size_r == 2'd0 ? flag2_result_r[7:0] == 8'd0 :
                flag2_size_r == 2'd1 ? flag2_result_r[15:0] == 16'd0 :
                                            flag2_result_r == 32'd0;
wire flag2_sf = flag2_size_r == 2'd0 ? flag2_result_r[7] :
                flag2_size_r == 2'd1 ? flag2_result_r[15] :
                                            flag2_result_r[31];
wire flag2_pf = ~^flag2_result_r[7:0];

// A push or pop moves ESP by the operand size, down or up.
wire [31:0] stack_step = stack_dir ? {29'd0, stack_data32, ~stack_data32, 1'b0}
                                   : {29'h1FFF_FFFF, stack_data32 ? 2'b10 : 2'b11, 1'b0};
wire [31:0] stack_sum = forwarded_esp + stack_step;

always_ff @(posedge clk) begin
    if (!reset_n) begin
        sigma <= 32'd0;
    end else begin
        if (instr_start && stack_op) begin
            // ESP +/- the operand size as one signed add: the low 16 bits of the
            // 32-bit sum are the 16-bit stack pointer's wrapped result, so a
            // 16-bit stack only keeps the upper half of ESP.
            sigma <= stack32 ? stack_sum : {forwarded_esp[31:16], stack_sum[15:0]};
        end else if (gate_detect) begin
            sigma <= {16'd0, tmpc[31:16]};
        end else if (exec) begin
            if (shift_sigma_sel == 2'd1)
                sigma <= shift_setup_result;
            else if (shift_sigma_sel == 2'd2)
                sigma <= shift_result;
            else case (aluop)
                ALUJMP_ALU,
                ALUJMP_INCDEC,
                ALUJMP_IMCS,
                ALUJMP_SZ_EXT,
                ALUJMP_AND,
                ALUJMP_OR,
                ALUJMP_XOR,
                ALUJMP_SIGN,
                ALUJMP_ADD,
                ALUJMP_ADC,
                ALUJMP_SUB,
                ALUJMP_CMP,
                ALUJMP_PASS,
                ALUJMP_PASS2,
                ALUJMP_AAAAAS,
                ALUJMP_DAADAS,
                ALUJMP_SERECO: sigma <= alu_result;

                ALUJMP_IMUL3,
                ALUJMP_IMUL4,
                ALUJMP_SZ_EX2,
                ALUJMP_DIV5,
                ALUJMP_PREDIV,
                ALUJMP_IDIV1,
                ALUJMP_IDIV2,
                ALUJMP_DIV7:
                    if (muldiv_sigma_write)
                        sigma <= muldiv_sigma_value;
                default: ;
            endcase
        end

        // Fault handling has final priority over a current arithmetic result.
        if (any_fault)
            sigma <= 32'd0;
    end
end

// Branch control consumes only the selected condition, not the full forwarded
// flags bus. Evaluate it beside the forwarding mux so a just-retired shift or
// ALU result crosses the module boundary as one bit on the redirect path.
assign branch_condition_true = condition_true(instr.branch_condition,
                                              eflags_fwd);

// 486 MOV CR0: NW=1 with CD=0 is an invalid cache mode.  The original MOV
// CRn routine already rejects PG=1 with PE=0 by testing COUNTR == 1 (its
// {PG,PE} pair) and taking #GP(0) before CR0 is written; route this case the
// same way.  TMPB holds the new value from the routine's first word.
wire cr0_cache_mode_reject = instr.has_0f && (instr.opcode == 8'h22) &&
                             (instr.modrm[5:3] == 3'd0) &&
                             tmpb[29] && !tmpb[30];

always_ff @(posedge clk) begin
    if (!reset_n) begin
        countr <= 32'd0;
    end else if (interrupt_entry) begin
        countr[4:0] <= 5'd0;
    end else if (gate_detect) begin
        countr <= {16'd0, tmpc[31:16]};
    end else if (muldiv_counter_early_exit) begin
        countr[4:0] <= 5'd0;
    end else if (exec) begin
        if (aluop == ALUJMP_LDCNTR)
            countr <= alu_source[5] ? {26'd0, alu_source_value_live[5:0]}
                                    : alu_source_value_live;
        else if (aluop == ALUJMP_DECNTR)
            countr <= countr - 32'd1;
        else if (dest == DEST_COUNT5)
            countr <= {27'd0, dest_value[4:0]};
        else if (dest == DEST_COUNTR)
            countr <= cr0_cache_mode_reject ? 32'd1 : dest_value;
        else if (repeat_active &&
                 (aluop == ALUJMP_DIV7 || aluop == ALUJMP_IMUL3 ||
                  aluop == ALUJMP_IMUL4 || aluop == ALUJMP_PREDIV))
            countr[4:0] <= countr[4:0] - 5'd1;
    end
end

always_ff @(posedge clk) begin
    if (instr_start && !halted &&
        (next_instr.rel_branch_kind == REL_BRANCH_JCC)) begin
        if (next_instr.branch_rel8)
            alu_src_hold <= {{24{next_instr.displacement[7]}},
                             next_instr.displacement[7:0]};
        else
            alu_src_hold <= next_instr.displacement;
    end else if (!((instr.rel_branch_kind == REL_BRANCH_JCC) && uc_active)) begin
        alu_src_hold <= alu_src;
    end
end

always_ff @(posedge clk) begin
    if (!reset_n) begin
        flag2_eflags_p  <= 1'b0;
        flag2_ucflags_p <= 1'b0;
    end else begin
        flag2_eflags_p  <= (exec && update_arch_flags) || load_wb_alu_commit;
        flag2_ucflags_p <= (exec && flag2_class_uc) || load_wb_alu_commit;
        if ((exec && flag2_class_uc) || load_wb_alu_commit) begin
            flag2_result_r <= load_wb_alu_commit ? load_wb_alu_result
                                                 : alu_result;
            flag2_cf_r     <= load_wb_alu_commit ? load_wb_alu_flags[0]
                                                 : alu_flags[0];
            flag2_af_r     <= load_wb_alu_commit ? load_wb_alu_flags[4]
                                                 : alu_flags[4];
            flag2_of_r     <= load_wb_alu_commit ? load_wb_alu_flags[11]
                                                 : alu_flags[11];
            flag2_zsp_r    <= load_wb_alu_commit ? 1'b1 : alu_zsp_update;
            flag2_size_r   <= load_wb_alu_commit ? load_wb_size : op_size;
        end
    end
end

always_comb begin
    if (sh_flags_commit) begin
        eflags_fwd = {eflags[31:12],
                      sh_flags_we_of ? sh_flags_of : eflags[11],
                      eflags[10:8],
                      sh_flags_we_zsp ? sh_flags_sf : eflags[7],
                      sh_flags_we_zsp ? sh_flags_zf : eflags[6],
                      eflags[5:3],
                      sh_flags_we_zsp ? sh_flags_pf : eflags[2],
                      eflags[1], sh_flags_cf};
    end else if (flag2_eflags_p) begin
        eflags_fwd = {eflags[31:12], flag2_of_r, eflags[10:8],
                      flag2_zsp_r ? flag2_sf : eflags[7],
                      flag2_zsp_r ? flag2_zf : eflags[6],
                      eflags[5], flag2_af_r, eflags[3],
                      flag2_zsp_r ? flag2_pf : eflags[2],
                      eflags[1], flag2_cf_r};
    end else begin
        eflags_fwd = eflags;
    end

end

always_ff @(posedge clk) begin
    if (!reset_n) begin
        uc_flags <= 32'h0000_0002;
    end else begin
        if (instr_start)
            uc_flags <= {eflags[31:17], eflags[16] && !clear_rf, eflags[15:0]};
        if (flag2_ucflags_p) begin
            uc_flags[0]  <= flag2_cf_r;
            uc_flags[4]  <= flag2_af_r;
            uc_flags[11] <= flag2_of_r;
            if (flag2_zsp_r) begin
                uc_flags[2] <= flag2_pf;
                uc_flags[6] <= flag2_zf;
                uc_flags[7] <= flag2_sf;
            end
        end
        if (sh_flags_commit) begin
            uc_flags[0] <= sh_flags_cf;
            if (sh_flags_we_zsp) begin
                uc_flags[2] <= sh_flags_pf;
                uc_flags[6] <= sh_flags_zf;
                uc_flags[7] <= sh_flags_sf;
            end
            if (sh_flags_we_of)
                uc_flags[11] <= sh_flags_of;
        end
        if (!instr_start && exec) begin
            case (aluop)
                ALUJMP_BITTST: uc_flags[0] <= shift_bit_test_cf;
                default: ;
            endcase
        end
        if (!instr_start && exec && shift_uc_carry)
            uc_flags[0] <= op_size == 2'd0 ? tmpb[7] :
                           op_size == 2'd1 ? tmpb[15] : tmpb[31];
    end
end

always_ff @(posedge clk) begin
    if (!reset_n) begin
        eflags <= 32'h0000_0002;
        clear_if_pending <= 1'b0;
    end else begin
        if (instr_start && !halted)
            clear_if_pending <= 1'b0;

        if (flag2_eflags_p) begin
            eflags[0]  <= flag2_cf_r;
            eflags[1]  <= 1'b1;
            eflags[4]  <= flag2_af_r;
            eflags[11] <= flag2_of_r;
            if (flag2_zsp_r) begin
                eflags[2] <= flag2_pf;
                eflags[6] <= flag2_zf;
                eflags[7] <= flag2_sf;
            end
        end

        if (sh_flags_commit) begin
            eflags[0] <= sh_flags_cf;
            if (sh_flags_we_zsp) begin
                eflags[2] <= sh_flags_pf;
                eflags[6] <= sh_flags_zf;
                eflags[7] <= sh_flags_sf;
            end
            if (sh_flags_we_of)
                eflags[11] <= sh_flags_of;
        end

        if (exec) begin
            case (aluop)
                ALUJMP_FLGOPS: begin
                    case (instr.flag_op)
                        FLAG_OP_CMC: eflags[0]  <= ~eflags[0];
                        FLAG_OP_CLC: eflags[0]  <= 1'b0;
                        FLAG_OP_STC: eflags[0]  <= 1'b1;
                        FLAG_OP_CLI: eflags[9]  <= 1'b0;
                        FLAG_OP_STI: eflags[9]  <= 1'b1;
                        FLAG_OP_CLD: eflags[10] <= 1'b0;
                        FLAG_OP_STD: eflags[10] <= 1'b1;
                        default: ;
                    endcase
                end
                ALUJMP_BITTST: eflags[0] <= shift_bit_test_cf;
                ALUJMP_DIV5: begin
                    // Unsigned DIV leaves the last divide step's flags, as
                    // the 386 does; IDIV and AAM keep the older behaviour.
                    if (instr.div_quotient_zf)
                        {eflags[11], eflags[7], eflags[6], eflags[4], eflags[2], eflags[0]} <=
                            muldiv_div_flags;
                    else
                        eflags[0] <= 1'b0;
                end
                ALUJMP_CLZF: eflags[6] <= 1'b0;
                ALUJMP_SEZF: eflags[6] <= 1'b1;
                ALUJMP_CLI: clear_if_pending <= 1'b1;
                ALUJMP_CLT: begin
                    eflags[8] <= 1'b0;
                    if (clear_if_pending)
                        eflags[9] <= 1'b0;
                    clear_if_pending <= 1'b0;
                end
                ALUJMP_SHIFT2: ;
                ALUJMP_SHIFT: ;
                ALUJMP_USTEP_AAD_SHIFT: eflags[0] <= 1'b0;
                ALUJMP_SZ_EX2,
                ALUJMP_USTEP_IMUL_FLAGS,
                ALUJMP_IMCS: begin
                    eflags[0]  <= muldiv_flag_overflow;
                    eflags[11] <= muldiv_flag_overflow;
                end
                default: ;
            endcase

            if (dest == DEST_FLAGSL)
                eflags[7:0] <= (dest_value[7:0] & 8'hD5) | 8'h02;

            if (dest == DEST_FLAGS) begin
                // POPFD's microcode forces BITS16 before FLAGS writeback;
                // retain the decoded width for the 486-only AC bit.
                if (instr.data32)
                    eflags[18] <= dest_value[18];

                if (pe) begin
                    eflags[7:0]   <= (dest_value[7:0] & 8'hD5) | 8'h02;
                    eflags[8]     <= dest_value[8];
                    eflags[9]     <= cpl <= eflags[13:12] ?
                                     dest_value[9] : eflags[9];
                    eflags[11:10] <= dest_value[11:10];
                    eflags[13:12] <= cpl == 2'b00 ?
                                     dest_value[13:12] : eflags[13:12];
                    eflags[14]    <= dest_value[14];
                    if (is_dword && cpl == 2'b00) begin
                        eflags[16] <= dest_value[16];
                        eflags[17] <= dest_value[17];
                    end
                end else begin
                    eflags[15:0] <= (dest_value[15:0] & 16'h7FD5) | 16'h0002;
                end
            end

            if (dest == DEST_EFLAGS)
                eflags <= (dest_value & 32'h0007_7fd5) | 32'h0000_0002;
        end

        if (clear_rf)
            eflags[16] <= 1'b0;
    end
end

// An instruction can issue in its predecessor's last exec cycle, whose flag
// writes land at that edge. Take the backup again one cycle later.
logic flags_backup_refresh;

// A direct ALU load (ALU r, m) commits its flags at writeback, which can come
// after its successor has started and taken its backup. Count the direct
// loads issued before the executing instruction that have not written back;
// a flag commit from one of those is older, and its flags are merged into the
// backup (a fault in the successor must restore them, not the stale ones).
logic [1:0] loads_pending;          // issued, not yet written back
logic [1:0] older_loads_pending;    // of those, issued before the current instruction
logic       flag2_older_p;          // flag2 holds an older load's flag commit
always_ff @(posedge clk) begin
    if (!reset_n || load_pipe_flush) begin
        loads_pending <= 2'd0;
        older_loads_pending <= 2'd0;
        flag2_older_p <= 1'b0;
    end else begin
        loads_pending <= loads_pending + {1'b0, load_issue} -
                         {1'b0, load_wb_valid && (loads_pending != 2'd0)};
        flag2_older_p <= load_wb_alu_commit && (older_loads_pending != 2'd0);
        if (instr_start)
            older_loads_pending <= loads_pending -
                                   {1'b0, load_wb_valid && (loads_pending != 2'd0)};
        else if (load_wb_valid && (older_loads_pending != 2'd0))
            older_loads_pending <= older_loads_pending - 2'd1;
    end
end

always_ff @(posedge clk) begin
    flags_backup_refresh <= reset_n && instr_start && !halted && !interrupt_entry;
    if (!reset_n) begin
        flags_backup_refresh <= 1'b0;
        flags_backup_active <= 1'b0;
        flags_backup <= 32'd0;
    end else if (ifetch_page_fault) begin
        flags_backup_active <= 1'b1;
        flags_backup <= eflags;
    end else if (interrupt_entry) begin
        flags_backup_active <= 1'b0;
    end else if (instr_start && !halted) begin
        flags_backup_active <= 1'b1;
        // The issue edge also clears RF for the instruction that just
        // completed (clear_rf); the new instruction's backup must see it.
        // A REPE/REPNE CMPS/SCAS keeps this image across its elements: a
        // fault on a later element pushes the flags from before the
        // instruction (Intel SDM vol. 2, REP/REPE/REPZ/REPNE/REPNZ: "the
        // EFLAGS value is restored to the state prior to the execution of
        // the instruction"; a real Am486DX4 does so, CPUSUITE-XE10-triage
        // tri_rep_flags), while ECX and the index registers stay committed.
        flags_backup <= {eflags_fwd[31:17], eflags_fwd[16] && !clear_rf,
                         eflags_fwd[15:0]};
    end else if (flags_backup_refresh) begin
        flags_backup <= eflags_fwd;
    end else if (flag2_older_p && flags_backup_active) begin
        flags_backup[0]  <= flag2_cf_r;
        flags_backup[4]  <= flag2_af_r;
        flags_backup[11] <= flag2_of_r;
        if (flag2_zsp_r) begin
            flags_backup[2] <= flag2_pf;
            flags_backup[6] <= flag2_zf;
            flags_backup[7] <= flag2_sf;
        end
    end else if (exec && aluop == ALUJMP_FLGSBA) begin
        if (!flags_backup_active) begin
            flags_backup_active <= 1'b1;
            flags_backup <= eflags;
        end
    end else if (exec && dest == DEST_FLAGSB) begin
        // Words combining FLGSBA with FLAGSB <- EFLAGS (the instruction-start
        // backup idiom) take the branch above.  The words reaching here load
        // FLAGSB on purpose -- the task switch's new-task image at 788/789,
        // after which a fault belongs to the new task -- so always write.
        flags_backup <= dest_value;
    end else if (fault_set_rf) begin
        // Fault-class delivery: the CROM sets EFLAGS.RF (MASK16 + 1) before
        // it pushes the FLAGSB image; a 486 pushes RF=1 for every fault so
        // the restarted instruction does not re-trigger its code breakpoint.
        // A debug exception is the exception: it pushes RF=0 (see z486.sv,
        // fault_set_rf), and its handler sets RF in the frame itself.
        flags_backup[16] <= 1'b1;
    end
end

//=============================================================================
// Arithmetic engines
//=============================================================================

// Direct register-memory ALU operations execute after the registered VIPT
// result boundary.  Keep their seven-operation add/logic datapath separate
// from the microcode ALU: sharing it creates a combinational loop through the
// WB-to-successor GPR bypass, and qualifying computation with fault state drags
// the divide-overflow cone onto every load result.  Faults gate commit below;
// they need not gate this side-effect-free calculation.
assign load_wb_alu_exec = load_wb_valid && load_wb_is_alu;
assign load_wb_alu_commit = load_wb_alu_exec && !recipe_commit_cancel;

wire [31:0] load_wb_alu_dst = (load_wb_size == 2'd0)
    ? (load_wb_dst[2] ? {24'd0, load_wb_dst_base_r[15:8]}
                      : {24'd0, load_wb_dst_base_r[7:0]})
    : (load_wb_size == 2'd1) ? {16'd0, load_wb_dst_base_r[15:0]}
                             : load_wb_dst_base_r;
logic [31:0] load_wb_add_a;
logic [31:0] load_wb_add_b;
logic        load_wb_add_cin;
logic        load_wb_arith;
logic        load_wb_sub;
logic [31:0] load_wb_logic_result;

always_comb begin
    load_wb_add_a = load_wb_alu_dst;
    load_wb_add_b = load_wb_data;
    load_wb_add_cin = 1'b0;
    load_wb_arith = 1'b0;
    load_wb_sub = 1'b0;
    load_wb_logic_result = load_wb_alu_dst;

    case (load_wb_alu_op)
        ALU_ADD: load_wb_arith = 1'b1;
        ALU_ADC: begin
            load_wb_arith = 1'b1;
            load_wb_add_cin = eflags_fwd[0];
        end
        ALU_SUBT: begin
            load_wb_arith = 1'b1;
            load_wb_sub = 1'b1;
            load_wb_add_b = ~load_wb_data;
            load_wb_add_cin = 1'b1;
        end
        ALU_SBB: begin
            load_wb_arith = 1'b1;
            load_wb_sub = 1'b1;
            load_wb_add_b = ~load_wb_data;
            load_wb_add_cin = ~eflags_fwd[0];
        end
        ALU_AND: load_wb_logic_result = load_wb_alu_dst & load_wb_data;
        ALU_OR:  load_wb_logic_result = load_wb_alu_dst | load_wb_data;
        ALU_XOR: load_wb_logic_result = load_wb_alu_dst ^ load_wb_data;
        default: ;
    endcase
end

wire [32:0] load_wb_sum33 = {1'b0, load_wb_add_a} +
                            {1'b0, load_wb_add_b} +
                            {32'd0, load_wb_add_cin};
wire [8:0] load_wb_sum8 = {1'b0, load_wb_add_a[7:0]} +
                          {1'b0, load_wb_add_b[7:0]} +
                          {8'd0, load_wb_add_cin};
wire [16:0] load_wb_sum16 = {1'b0, load_wb_add_a[15:0]} +
                            {1'b0, load_wb_add_b[15:0]} +
                            {16'd0, load_wb_add_cin};
assign load_wb_alu_result = load_wb_arith ? load_wb_sum33[31:0]
                                          : load_wb_logic_result;

wire load_wb_result_sign = load_wb_size == 2'd0
                         ? load_wb_alu_result[7]
                         : load_wb_size == 2'd1
                         ? load_wb_alu_result[15] : load_wb_alu_result[31];
wire load_wb_dst_sign = load_wb_size == 2'd0
                      ? load_wb_alu_dst[7]
                      : load_wb_size == 2'd1
                      ? load_wb_alu_dst[15] : load_wb_alu_dst[31];
wire load_wb_src_sign = load_wb_size == 2'd0
                      ? load_wb_data[7]
                      : load_wb_size == 2'd1
                      ? load_wb_data[15] : load_wb_data[31];
wire load_wb_carry = load_wb_size == 2'd0 ? load_wb_sum8[8] :
                     load_wb_size == 2'd1 ? load_wb_sum16[16] :
                                            load_wb_sum33[32];
wire load_wb_overflow = load_wb_arith &&
    (load_wb_sub
        ? ((load_wb_dst_sign ^ load_wb_src_sign) &
           (load_wb_dst_sign ^ load_wb_result_sign))
        : (~(load_wb_dst_sign ^ load_wb_src_sign) &
           (load_wb_dst_sign ^ load_wb_result_sign)));
wire load_wb_aux_carry = load_wb_arith &&
    (load_wb_alu_dst[4] ^ load_wb_data[4] ^ load_wb_alu_result[4]);
wire load_wb_zero = load_wb_size == 2'd0
                  ? load_wb_alu_result[7:0] == 8'd0
                  : load_wb_size == 2'd1
                  ? load_wb_alu_result[15:0] == 16'd0
                  : load_wb_alu_result == 32'd0;
wire load_wb_parity = ~^load_wb_alu_result[7:0];

always_comb begin
    load_wb_alu_flags = eflags_fwd;
    load_wb_alu_flags[11] = load_wb_overflow;
    load_wb_alu_flags[7] = load_wb_result_sign;
    load_wb_alu_flags[6] = load_wb_zero;
    load_wb_alu_flags[4] = load_wb_aux_carry;
    load_wb_alu_flags[2] = load_wb_parity;
    load_wb_alu_flags[0] = load_wb_arith
                         ? (load_wb_sub ? ~load_wb_carry : load_wb_carry)
                         : 1'b0;
end

assign load_wb_commit_data = load_wb_is_alu ? load_wb_alu_result
                                            : load_wb_data;

// Capture the operand for a q_mem SHIFT2 word or the two SRCREG SHIFT words.
// A predecessor may update the selected temporary or SIGMA on this same edge,
// so forward that exact value. SRCREG uses the existing load-WB bypass and the
// architectural operand width; its preceding LDBSRU records that width.
always_comb begin
    case (shift2_next_source)
        2'd0: shift2_capture_value = (exec && dest == DEST_TMPC)
                                    ? dest_value : tmpc;
        2'd1: shift2_capture_value = (exec && dest == DEST_TMPE)
                                    ? dest_value : tmpe;
        2'd2: shift2_capture_value = (exec && aluop == ALUJMP_SHIFT1)
                                    ? shift_setup_result : sigma;
        2'd3: shift2_capture_value = read_gpr_capture(src_reg_sel_r, op_size);
        default: shift2_capture_value = 32'd0;
    endcase
end

`ifdef Z486_USE_ALTERA_ALU
alu_alt alu_inst (
`else
alu alu_inst (
`endif
    .op(alu_operation),
    .src(alu_src),
    .dst(alu_dst),
    .op_size(op_size),
    .flags(eflags_fwd),
    .update_carry(update_carry),
    .result(alu_result),
    .flags_out(alu_flags),
    .zsp_update(alu_zsp_update)
);

shifter shifter_inst (
    .clk(clk),
    .reset_n(reset_n),
    .exec(shift_exec),
    .aluop(aluop),
    .shift_aluop(shift_aluop),
    .source_field(source_field),
    .source_class(shift_source_class),
    .shift2_source(shift2_source),
    .is_shift2(shift_is_shift2),
    .use_captured(shift_use_captured),
    .capture_ce(shift2_capture_ce),
    .capture_valid(shift2_next_valid),
    .capture_value(shift2_capture_value),
    .alu_source(alu_source),
    .instr_start(instr_start),
    .instr_is_shxd_next(next_instr.shift_is_double),
    .carry_in(eflags_fwd[0]),
    .shift_right(instr.shift_right),
    .shift_operation(instr.shift_operation),
    .op_size(op_size),
    .alu_dst(alu_dst),
    .alu_src(alu_src),
    .gpr_src_op_size(read_gpr_fmt_op(ex_src_full, ex_src_byte, src_reg_sel_r[2])),
    .gpr_dst_op_size(read_gpr_fmt_op(ex_dst_full, ex_dst_byte, dst_reg_sel_r[2])),
    .gpr_dst_s1_size(read_gpr_fmt(ex_dst_full, ex_dst_byte, dst_reg_sel_r[2], shift1_size)),
    .gpr_src_s1_size(read_gpr_fmt(ex_src_full, ex_src_byte, src_reg_sel_r[2], shift1_size)),
    .shift1_size_o(shift1_size),
    .immediate(instr.immediate),
    .ecx(read_gpr_load_forwarded(3'd1, 2'd2)),
    .sigma(sigma),
    .tmpb(tmpb),
    .tmpc(tmpc),
    .tmpd(tmpd),
    .tmpe(tmpe),
    .opr_r(opr_r),
    .countr(countr),
    .data_size(shift_data_size),
    .result(shift_result),
    .setup_result(shift_setup_result),
    .bit_test_cf(shift_bit_test_cf),
    .count_nonzero(shift_count_nonzero),
    .flags_commit(sh_flags_commit),
    .flags_we_zsp(sh_flags_we_zsp),
    .flags_we_of(sh_flags_we_of),
    .flags_cf(sh_flags_cf),
    .flags_of(sh_flags_of),
    .flags_zf(sh_flags_zf),
    .flags_sf(sh_flags_sf),
    .flags_pf(sh_flags_pf)
);

mul_div mul_div_inst (
    .clk(clk),
    .reset_n(reset_n),
    .exec(exec),
    .instr_start(instr_start),
    .repeat_active(repeat_active),
    .aluop(aluop),
    .dest(dest),
    .op_size(op_size),
    .is_signed_mul(is_signed_mul),
    .sigma(sigma),
    .tmpb(tmpb),
    .tmpd(tmpd),
    .dest_value(dest_value),
    .gate_detect(gate_detect),
    .desc_raw_hi(desc_raw_hi),
    .result(muldiv_result),
    .sigma_write(muldiv_sigma_write),
    .sigma_value(muldiv_sigma_value),
    .tmpb_write(muldiv_tmpb_write),
    .tmpb_value(muldiv_tmpb_value),
    .counter_early_exit(muldiv_counter_early_exit),
    .div_overflow(div_overflow),
    .div_overflow_cond(div_overflow_cond),
    .div_quotient_zero(muldiv_quotient_zero),
    .div_flags(muldiv_div_flags),
    .mul_flag_overflow(muldiv_flag_overflow)
);

endmodule

//
// Microsequencer
// Two-port microcode ROM pipeline, micro-address sequencing and redirects
//
`include "z486_platform.svh"
module microsequencer
    import z486_pkg::*;
(
    // Clock and reset
    input  logic        clk,
    input  logic        reset_n,

    // D2 -> EX issue: the first word comes from port B (pb_slot)
    input  logic        i_issue,              // D2 transfers its instruction to EX
    input  logic        pb_slot,              // port B supplies the next executing word
    output logic [11:0] issue_entry,          // entry of the instruction issuing now
    output logic [2:0]  d2_kind,              // recipe kind of the issuing first word

    // ROM port A (EX): the sequencer's address and ROM pipeline
    input  logic        rom_base_ce,          // ROM pipeline clock-enable (not stalled)
    output logic        rom_q_ce,             // ROM output-register clock-enable
    input  logic        q_hold,               // a fault or boundary event holds the ROM output
    input  logic        seq_advance,          // step to the next sequential word
    output logic [11:0] uaddr,                // registered port-A address
    output logic [11:0] uaddr_next,           // arbitrated next port-A address
    output logic [11:0] uc_addr,              // address of the executing micro-op
    output logic [11:0] uc_addr_mem,          // address in the ROM memory stage

    // ROM port B (D2): the skeleton's first word, read when it loads (latches 35)
    input  logic        pb_load,              // the skeleton loads: read its entry word
    input  logic [11:0] pb_load_entry,        //   at this entry point
    input  logic        pb_kill,              // a boundary event drops the resident word
    output logic        pb_valid,             // port B holds the skeleton's first word

    // Execution control (event control and the execution core)
    input  logic        q_flush,              // front-end redirect
    input  logic        stall,
    input  logic        uc_exec,              // the current micro-op takes effect
    input  logic        repeat_active,        // REP iteration holds the word
    input  logic        macro_active,         // a macro instruction owns EX
    input  logic        instr_eip_written,    // the instruction already wrote EIP
    input  logic        any_fault,
    input  logic        page_fault,

    // Micro-branch conditions and redirect sources
    input  seq_condition_t conditions,       // precomputed micro-branch conditions
    input  logic        pe,
    input  logic        vm,
    input  logic        cpl_nonzero,
    input  logic        prot_redirect_prev,   // protection redirect delay-slot state
    input  logic        prot_redirect_valid,
    input  logic [11:0] prot_redirect_target,
    input  logic        recipe_redirect_valid,
    input  logic [11:0] recipe_redirect_target,
    input  logic        set_rpl_redirect,
    input  logic        div_redirect_valid,
    input  logic [11:0] div_redirect_target,
    input  logic        gate_redirect,
    // The redirect conditions without uc_exec: each *_valid above is
    // uc_exec && its condition (the recipe's also ORs recipe_redirect_hold),
    // fused below.  The port-A address takes uc_exec in its last select.
    input  logic        prot_redirect_cond,
    input  logic        recipe_redirect_cond,
    input  logic        recipe_redirect_hold,
    input  logic        div_redirect_cond,
    input  logic        gate_redirect_cond,
    input  seq_redirect_t fault_redirect,     // highest-priority fault target
    input  seq_redirect_t boundary_redirect,  // interrupt/reset boundary target

    // End of instruction: RNI, synthetic RNIs and the delay slot
    input  logic        jcc_fold_active,      // a folded Jcc supplies a synthetic RNI
    input  logic        branch_ustep_rni,     // a hardwired branch supplies a synthetic RNI
    input  logic        load_wb_retire,       // a direct-load hit supplies a synthetic RNI
    output logic        i_rni,                // the executing word ends the instruction
    output logic        i_rni_delay,          // the RNI delay slot is executing
    output logic        i_rni_delay_ea,       // low-fanout copy for the D2 EA bypass
    output logic        jump_taken_prev,      // micro-jump delay-slot state
    output logic        pref_suppress_prev,   // taken conditional PREF suppression

    // Microinstruction to the units: the ROM output register (port A's word, or
    // port B's at issue) and its predecoded fields
    output logic [50:0] uc,
    output logic [50:0] uc_next,              // the word that becomes uc next cycle
    output logic [1:0]  uc_next_shift2_source,  // uc_next's SHIFT2 source class (port select last)
    output logic        uc_next_shift_captures, // uc_next captures a shift operand (port select last)
    output logic [6:0]  uc_next_dest_a,       // port A's destination field (uc_next[30:24] when !pb_slot)
    output logic [6:0]  uc_next_dest_b,       // port B's destination field (uc_next[30:24] when pb_slot)
    output logic [5:0]  uc_source_shift,
    output logic [3:0]  uc_shift_source_class,
    output logic [1:0]  uc_shift2_source,
    output logic        uc_is_shift2,
    output logic        uc_shift_use_captured,
    output logic        uc_shift_uc_carry,
    output logic [5:0]  uc_alu_src_shift,
    output logic [6:0]  uc_aluop_shift,
    output logic [1:0]  uc_shift_sigma_sel,
    output logic [6:0]  uc_alu_op_sel,
    output logic [2:0]  uc_dly_source,
    output logic [8:0]  uc_mem_ctrl,
    output logic [8:0]  uc_ind_ctrl,
    output logic        uc_fpu_f8,
    output logic        uc_force_word,
    output logic        uc_ctl_pref
);

logic        pb_valid_r;           // port B holds the skeleton's first word
logic [11:0] pb_entry_r;           //   read at this entry point
`Z486_KEEP logic i_rni_delay_ea_r;

assign i_rni_delay_ea = i_rni_delay_ea_r;
logic [11:0] return_stack [0:3];
logic [1:0]  return_sp;

wire [5:0] uc_alu_src = uc[36:31];
wire [5:0] uc_source = uc[23:18];
wire [6:0] uc_aluop = uc[17:11];
wire [2:0] uc_opcode = uc[10:8];
wire [11:0] uc_ljump_target = {uc_source, uc_alu_src};
wire [11:0] return_target = return_stack[return_sp - 2'd1];
wire reljump_cond = !repeat_active &&
                    reljump_condition(uc_aluop, conditions) &&
                    !prot_redirect_prev &&
                    !jcc_fold_active && !branch_ustep_rni;
wire reljump_taken = uc_exec && reljump_cond;
wire pref_suppress_taken = reljump_taken &&
    (uc_aluop == ALUJMP_JNcond || uc_aluop == ALUJMP_JCNTNZ ||
     uc_aluop == ALUJMP_JCNT1 || uc_aluop == ALUJMP_LOOPnE);
wire normal_jump_taken = reljump_taken || prot_redirect_valid ||
    recipe_redirect_valid || (uc_exec && (
    (uc_aluop == ALUJMP_LJMPP && pe && !vm) ||
    (uc_aluop == ALUJMP_LJMPNP && pe && cpl_nonzero) ||
    (uc_aluop == ALUJMP_LJMP86 && vm) ||
    (uc_aluop == ALUJMP_LCALL) ||
    ((uc_aluop == ALUJMP_LJUMP) && !prot_redirect_prev)));
wire flow_call = uc_exec && (uc_aluop == ALUJMP_LCALL);
wire flow_return = uc_exec && (uc_aluop == ALUJMP_RETURN);
wire rni_base = (((uc_opcode == 3'b000) || (uc_opcode == 3'b010)) &&
                 !jump_taken_prev) ||
                ((uc_opcode == 3'b001) && jump_taken_prev);
assign i_rni = rni_base || jcc_fold_active || branch_ustep_rni ||
               load_wb_retire;

// uaddr_next's terms above the port-B continuation: reset, the boundary
// event, a fault (the arm is only selected when one of them is valid).
function automatic logic [11:0] uaddr_next_hi(input logic rst_n, input logic bnd_v,
                                              input logic [11:0] bnd_t,
                                              input logic [11:0] flt_t);
    uaddr_next_hi = !rst_n ? 12'h000 : bnd_v ? bnd_t : flt_t;
endfunction
// The last level of uaddr_next: the two late selects over the three arms.
function automatic logic [11:0] uaddr_next_pick(input logic pb, input logic adv,
                                                input logic [11:0] arm_pb,
                                                input logic [11:0] arm_step,
                                                input logic [11:0] arm_hold);
    uaddr_next_pick = pb ? arm_pb : adv ? arm_step : arm_hold;
endfunction

// The EX redirect as a function of the execute enable and the uc_exec-free
// redirect conditions, in the priority the RTL always had (later wins):
// relative jump, the long-jump/call/return word, protection, recipe, SET_RPL,
// divide, call gate; and, with ex low, a recipe rejection held from an
// earlier overlay word (recipe_redirect_hold).  uc_exec reaches it from the
// stall cone (D$ ready -> stall_fast_store -> uc_exec, fo ~300), so the ROM
// address forms it for both values and picks with uc_exec last.
function automatic seq_redirect_t exec_redirect_of(
    input logic        ex,
    input logic        rel_c,
    input logic [6:0]  aluop,
    input logic [11:0] rel_target,
    input logic        vm_i,
    input logic        pe_i,
    input logic        cpl_nz,
    input logic        prot_prev,
    input logic [11:0] ljump_target,
    input logic [11:0] ret_target,
    input logic        prot_c,
    input logic [11:0] prot_t,
    input logic        rec_c,
    input logic        rec_hold,
    input logic [11:0] rec_t,
    input logic        set_rpl,
    input logic        div_c,
    input logic [11:0] div_t,
    input logic        gate_c
);
    seq_redirect_t r;
    r = '0;
    if (ex) begin
        if (rel_c) begin
            r.valid = 1'b1;
            r.target = rel_target;
        end
        case (aluop)
            ALUJMP_LJMP86: if (vm_i) begin
                r.valid = 1'b1;
                r.target = ljump_target;
            end
            ALUJMP_LJMPP: if (pe_i && !vm_i) begin
                r.valid = 1'b1;
                r.target = ljump_target;
            end
            ALUJMP_LJMPNP: if (pe_i && cpl_nz) begin
                r.valid = 1'b1;
                r.target = ljump_target;
            end
            ALUJMP_LCALL: begin
                r.valid = 1'b1;
                r.target = ljump_target;
            end
            ALUJMP_LJUMP: if (!prot_prev) begin
                r.valid = 1'b1;
                r.target = ljump_target;
            end
            ALUJMP_RETURN: begin
                r.valid = 1'b1;
                r.target = ret_target;
            end
            default: ;
        endcase
        if (prot_c) begin
            r.valid = 1'b1;
            r.target = prot_t;
        end
        if (rec_c || rec_hold) begin
            r.valid = 1'b1;
            r.target = rec_t;
        end
        if (set_rpl) begin
            r.valid = 1'b1;
            r.target = UADDR_MORE_PRIVILEGE;
        end
        if (div_c) begin
            r.valid = 1'b1;
            r.target = div_t;
        end
        if (gate_c) begin
            r.valid = 1'b1;
            r.target = UADDR_CALL_GATE_386;
        end
    end else if (rec_hold) begin
        // Recipe rejection may be registered after its speculative overlay
        // word has executed. It owns no architectural micro-op in that cycle,
        // so it redirects the ROM while uc_exec remains suppressed. This keeps
        // the VIPT/TLB result out of the same-cycle ROM-address cone.
        r.valid = 1'b1;
        r.target = rec_t;
    end
    exec_redirect_of = r;
endfunction

wire [11:0] reljump_target = uc_addr + 12'd1 + {{6{uc_alu_src[5]}}, uc_alu_src};
seq_redirect_t exec_redirect_x1;
seq_redirect_t exec_redirect_x0;
seq_redirect_t exec_redirect;
assign exec_redirect_x1 = exec_redirect_of(1'b1, reljump_cond, uc_aluop, reljump_target,
    vm, pe, cpl_nonzero, prot_redirect_prev, uc_ljump_target, return_target,
    prot_redirect_cond, prot_redirect_target, recipe_redirect_cond, recipe_redirect_hold,
    recipe_redirect_target, set_rpl_redirect, div_redirect_cond, div_redirect_target,
    gate_redirect_cond);
assign exec_redirect_x0 = exec_redirect_of(1'b0, reljump_cond, uc_aluop, reljump_target,
    vm, pe, cpl_nonzero, prot_redirect_prev, uc_ljump_target, return_target,
    prot_redirect_cond, prot_redirect_target, recipe_redirect_cond, recipe_redirect_hold,
    recipe_redirect_target, set_rpl_redirect, div_redirect_cond, div_redirect_target,
    gate_redirect_cond);
assign exec_redirect = uc_exec ? exec_redirect_x1 : exec_redirect_x0;

wire rom_addr_ce = rom_base_ce;
assign rom_q_ce = rom_base_ce && !q_hold;

// synthesis translate_off
// The pre-split EX redirect (the valid inputs, each uc_exec && its condition),
// and the premises that make the cofactored form equal to it.
seq_redirect_t exec_redirect_reference;
always_comb begin
    exec_redirect_reference = '0;

    if (uc_exec) begin
        if (reljump_taken) begin
            exec_redirect_reference.valid = 1'b1;
            exec_redirect_reference.target = uc_addr + 12'd1 +
                                   {{6{uc_alu_src[5]}}, uc_alu_src};
        end

        case (uc_aluop)
            ALUJMP_LJMP86: if (vm) begin
                exec_redirect_reference.valid = 1'b1;
                exec_redirect_reference.target = uc_ljump_target;
            end
            ALUJMP_LJMPP: if (pe && !vm) begin
                exec_redirect_reference.valid = 1'b1;
                exec_redirect_reference.target = uc_ljump_target;
            end
            ALUJMP_LJMPNP: if (pe && cpl_nonzero) begin
                exec_redirect_reference.valid = 1'b1;
                exec_redirect_reference.target = uc_ljump_target;
            end
            ALUJMP_LCALL: begin
                exec_redirect_reference.valid = 1'b1;
                exec_redirect_reference.target = uc_ljump_target;
            end
            ALUJMP_LJUMP: if (!prot_redirect_prev) begin
                exec_redirect_reference.valid = 1'b1;
                exec_redirect_reference.target = uc_ljump_target;
            end
            ALUJMP_RETURN: begin
                exec_redirect_reference.valid = 1'b1;
                exec_redirect_reference.target = return_target;
            end
            default: ;
        endcase

        if (prot_redirect_valid) begin
            exec_redirect_reference.valid = 1'b1;
            exec_redirect_reference.target = prot_redirect_target;
        end
        if (recipe_redirect_valid) begin
            exec_redirect_reference.valid = 1'b1;
            exec_redirect_reference.target = recipe_redirect_target;
        end
        if (set_rpl_redirect) begin
            exec_redirect_reference.valid = 1'b1;
            exec_redirect_reference.target = UADDR_MORE_PRIVILEGE;
        end
        if (div_redirect_valid) begin
            exec_redirect_reference.valid = 1'b1;
            exec_redirect_reference.target = div_redirect_target;
        end
        if (gate_redirect) begin
            exec_redirect_reference.valid = 1'b1;
            exec_redirect_reference.target = UADDR_CALL_GATE_386;
        end
    end
    if (recipe_redirect_valid && !uc_exec) begin
        exec_redirect_reference.valid = 1'b1;
        exec_redirect_reference.target = recipe_redirect_target;
    end
end
always @(posedge clk)
    if (reset_n) begin
        if ((prot_redirect_valid !== (uc_exec && prot_redirect_cond)) ||
            (recipe_redirect_valid !== ((uc_exec && recipe_redirect_cond) || recipe_redirect_hold)) ||
            (div_redirect_valid !== (uc_exec && div_redirect_cond)) ||
            (gate_redirect !== (uc_exec && gate_redirect_cond)))
            $fatal(1, "microsequencer: a redirect valid is not uc_exec && its condition (prot %b/%b recipe %b/%b/%b div %b/%b gate %b/%b)",
                   prot_redirect_valid, prot_redirect_cond, recipe_redirect_valid,
                   recipe_redirect_cond, recipe_redirect_hold, div_redirect_valid,
                   div_redirect_cond, gate_redirect, gate_redirect_cond);
        if (exec_redirect !== exec_redirect_reference)
            $fatal(1, "microsequencer: cofactored exec_redirect %b/%03x != reference %b/%03x",
                   exec_redirect.valid, exec_redirect.target,
                   exec_redirect_reference.valid, exec_redirect_reference.target);
    end
// synthesis translate_on

// The next port-A address, in priority order (lowest first): hold, the
// sequential step (seq_advance), an EX redirect, the port-B continuation
// (pb_slot: an instruction issuing from port B continues at its next word),
// a fault, the boundary event, reset (uaddr_next_reference below).
// seq_advance and pb_slot are the D2 issue decision, the latest terms on the
// ROM address (vipt hit -> d2_ready -> seq_advance and pb_issue -> pb_slot ->
// rom_addr -> the M10K address register).  They are cofactored out: the three
// arms below are formed from every other term, and the two late selects pick
// among them in the last LUT level.  tests/equiv/uaddr_next_cofactor.v proves
// the form equal to the priority chain for every input (shipped text).
wire        uaddr_hi_v = !reset_n || boundary_redirect.valid || fault_redirect.valid;
wire [11:0] uaddr_hi   = uaddr_next_hi(reset_n, boundary_redirect.valid, boundary_redirect.target,
                                       fault_redirect.target);
// The hold and step arms are formed for both uc_exec values (exec_redirect_x1
// / _x0) and uc_exec picks each, so uc_exec meets the address one select
// before seq_advance / pb_slot (tests/equiv/uaddr_exec_cofactor.v).
`Z486_KEEP_COMB wire [11:0] uaddr_arm_hold_x1 = uaddr_hi_v ? uaddr_hi :
                                                exec_redirect_x1.valid ? exec_redirect_x1.target : uaddr;
`Z486_KEEP_COMB wire [11:0] uaddr_arm_hold_x0 = uaddr_hi_v ? uaddr_hi :
                                                exec_redirect_x0.valid ? exec_redirect_x0.target : uaddr;
`Z486_KEEP_COMB wire [11:0] uaddr_arm_step_x1 = uaddr_hi_v ? uaddr_hi :
                                                exec_redirect_x1.valid ? exec_redirect_x1.target : uaddr + 12'd1;
`Z486_KEEP_COMB wire [11:0] uaddr_arm_step_x0 = uaddr_hi_v ? uaddr_hi :
                                                exec_redirect_x0.valid ? exec_redirect_x0.target : uaddr + 12'd1;
wire [11:0] uaddr_arm_hold = uc_exec ? uaddr_arm_hold_x1 : uaddr_arm_hold_x0;
wire [11:0] uaddr_arm_step = uc_exec ? uaddr_arm_step_x1 : uaddr_arm_step_x0;
`Z486_KEEP_COMB wire [11:0] uaddr_arm_pb   = uaddr_hi_v ? uaddr_hi : pb_entry_r + 12'd1;
assign uaddr_next = uaddr_next_pick(pb_slot, seq_advance,
                                    uaddr_arm_pb, uaddr_arm_step, uaddr_arm_hold);
// synthesis translate_off
logic [11:0] uaddr_next_reference;
always_comb begin
    uaddr_next_reference = uaddr;
    if (seq_advance)
        uaddr_next_reference = uaddr + 12'd1;
    if (exec_redirect.valid)
        uaddr_next_reference = exec_redirect.target;
    if (pb_slot)
        uaddr_next_reference = pb_entry_r + 12'd1;
    if (fault_redirect.valid)
        uaddr_next_reference = fault_redirect.target;
    if (boundary_redirect.valid)
        uaddr_next_reference = boundary_redirect.target;
    if (!reset_n)
        uaddr_next_reference = 12'h000;
end
always @(posedge clk)
    if (reset_n && (uaddr_next !== uaddr_next_reference))
        $fatal(1, "microsequencer: cofactored uaddr_next %03x != priority chain %03x",
               uaddr_next, uaddr_next_reference);
// synthesis translate_on

wire [11:0] rom_addr = uaddr_next;
wire [50:0] rom_q;
wire [50:0] rom_q_early;
wire [2:0]  rom_kind_early;
wire [2:0]  rom_kind_b;

// Port B tracks the skeleton: its address register loads with the skeleton,
// so the word is resident while the instruction waits in D2. An issue from
// port B (US5293592 latches 35: the decoder supplies the first line) needs
// no port-A launch; port A continues at the following word. Every issue
// takes port B's word (pb_slot).
always_ff @(posedge clk) begin
    if (!reset_n || q_flush || pb_kill)
        pb_valid_r <= 1'b0;
    else if (pb_load)
        pb_valid_r <= 1'b1;
    else if (i_issue)
        pb_valid_r <= 1'b0;
    if (pb_load)
        pb_entry_r <= pb_load_entry;
end
assign pb_valid = pb_valid_r;
assign issue_entry = pb_entry_r;

ucode_rom microcode_rom_inst (
    // Clock
    .clk(clk),
    // Port A (EX): the sequencer's address; its word feeds the output register
    .addr_ce(rom_addr_ce),
    .addr(rom_addr),
    .q_kind_early(rom_kind_early),
    // Port B (D2): the D2 skeleton's first word, read when the skeleton loads
    .addr_b_ce(pb_load),
    .addr_b(pb_load_entry),
    .q_kind_b(rom_kind_b),
    // Output register: loads port A's word, or port B's at issue (q_sel_b), with predecode
    .q_ce(rom_q_ce),
    .q_sel_b(pb_slot),
    .q_early(rom_q_early),
    .q_early_shift2_source(uc_next_shift2_source),
    .q_early_shift_captures(uc_next_shift_captures),
    .q_dest_a(uc_next_dest_a),
    .q_dest_b(uc_next_dest_b),
    .q(rom_q),
    .q_shift_source(uc_source_shift),
    .q_shift_source_class(uc_shift_source_class),
    .q_shift2_source(uc_shift2_source),
    .q_is_shift2(uc_is_shift2),
    .q_shift_use_captured(uc_shift_use_captured),
    .q_shift_uc_carry(uc_shift_uc_carry),
    .q_shift_alu_src(uc_alu_src_shift),
    .q_shift_aluop(uc_aluop_shift),
    .q_shift_sigma_sel(uc_shift_sigma_sel),
    .q_alu_op_sel(uc_alu_op_sel),
    .q_dly_source(uc_dly_source),
    .q_mem_ctrl(uc_mem_ctrl),
    .q_ind_ctrl(uc_ind_ctrl),
    .q_fpu_f8(uc_fpu_f8)
);

assign uc = rom_q;
assign uc_next = rom_q_early;
assign d2_kind = rom_kind_b;

// synthesis translate_off
always @(posedge clk)
    if (reset_n && i_issue && !pb_slot)
        $fatal(1, "an issue without port B's first word");
// synthesis translate_on

// Sequencer state updates retain the original in-block priority. RNI delay
// cancellation is last so a page fault cannot expose a stale delay slot.
always_ff @(posedge clk) begin
    if (!reset_n) begin
        uaddr <= 12'h000;
        uc_addr_mem <= 12'h000;
        uc_addr <= 12'h000;
        return_sp <= 2'd0;
        i_rni_delay <= 1'b0;
        i_rni_delay_ea_r <= 1'b0;
        jump_taken_prev <= 1'b0;
        pref_suppress_prev <= 1'b0;
        uc_ctl_pref <= 1'b0;
        uc_force_word <= 1'b0;
    end else begin
        uaddr <= uaddr_next;

        if (rom_addr_ce)
            uc_addr_mem <= rom_addr;
        if (rom_q_ce) begin
            uc_addr <= pb_slot ? pb_entry_r : uc_addr_mem;
            // The m80 store tail executes after a dword-stride loop, but its
            // immutable `wr W` word writes only the final two bytes.
            uc_force_word <= uc_addr_mem == UADDR_FPU_STORE_TAIL;
            uc_ctl_pref <= (rom_q_early[5:0] == BUSOP_PREF);
        end

        if (i_rni_delay && !stall && !page_fault)
            i_rni_delay <= 1'b0;
        if (i_rni_delay_ea_r && !stall && !page_fault)
            i_rni_delay_ea_r <= 1'b0;
        if ((uc_exec || load_wb_retire) && i_rni && macro_active &&
            (!instr_eip_written || (uc_addr == UADDR_RPTI_RNI)) &&
            !any_fault && !i_issue && !i_rni_delay) begin // no re-arm while armed
            i_rni_delay <= 1'b1;
            i_rni_delay_ea_r <= 1'b1;
        end
        if (page_fault) begin
            i_rni_delay <= 1'b0;
            i_rni_delay_ea_r <= 1'b0;
        end

        if (uc_exec) begin
            jump_taken_prev <= normal_jump_taken;
            pref_suppress_prev <= pref_suppress_taken;
        end

        if (flow_call) begin
            return_stack[return_sp] <= uaddr + 12'd1;
            return_sp <= return_sp + 2'd1;
        end else if (flow_return) begin
            return_sp <= return_sp - 2'd1;
        end
        if (gate_redirect) begin
            return_stack[return_sp] <= uc_addr;
            return_sp <= return_sp + 2'd1;
        end
    end
end

function automatic logic reljump_condition(
    input logic [6:0] aluop,
    input seq_condition_t c
);
    case (aluop)
        ALUJMP_JNcond: reljump_condition = c.jncond;
        ALUJMP_JCNTZ: reljump_condition = c.count_zero;
        ALUJMP_JCNTNZ: reljump_condition = c.count_nonzero;
        ALUJMP_JCNZNI: reljump_condition = c.count_nonzero && c.no_interrupt;
        ALUJMP_JCT4N1: reljump_condition = c.count_low_not_one;
        ALUJMP_JCNTN1: reljump_condition = c.count_not_one;
        ALUJMP_JCNT1: reljump_condition = c.count_one;
        ALUJMP_LOOPnE: reljump_condition = c.loopne;
        ALUJMP_JG: reljump_condition = c.greater;
        ALUJMP_JNC: reljump_condition = c.no_carry;
        ALUJMP_JNO: reljump_condition = c.no_overflow;
        ALUJMP_JPEREQ: reljump_condition = c.pereq_inactive;
        ALUJMP_JNFLGB: reljump_condition = c.flags_backup_inactive;
        ALUJMP_JTSSAF: reljump_condition = c.tss_access;
        ALUJMP_JINTSW: reljump_condition = !c.interrupt_hw;
        ALUJMP_JMISC1: reljump_condition = c.misc1;
        ALUJMP_JEXTFT: reljump_condition = c.external_event;
        ALUJMP_JSTSKL: reljump_condition = !c.misc1 && !c.interrupt_hw;
        ALUJMP_JNTSKS: reljump_condition = c.task_unsaved;
        ALUJMP_JMISC2: reljump_condition = c.misc2;
        ALUJMP_JNERRC: reljump_condition = c.no_error_code;
        ALUJMP_JNOFLT: reljump_condition = c.no_fault;
        ALUJMP_JREP: reljump_condition = c.rep_fault;
        ALUJMP_JNT: reljump_condition = c.nested_task;
        ALUJMP_JIO_OK: reljump_condition = c.io_ok;
        ALUJMP_JMP: reljump_condition = 1'b1;
        ALUJMP_JNOINT: reljump_condition = c.no_interrupt;
        ALUJMP_JNBUSY: reljump_condition = c.x87_not_busy;
        ALUJMP_JBUSY: reljump_condition = c.x87_error;
        ALUJMP_JICEWT: reljump_condition = 1'b0;
        ALUJMP_J16BIT: reljump_condition = c.task_16bit;
        ALUJMP_JDESCA: reljump_condition = c.desc_accessed;
        ALUJMP_JTSSLIM: reljump_condition = c.tss_limit_short;
        default: reljump_condition = 1'b0;
    endcase
endfunction

endmodule

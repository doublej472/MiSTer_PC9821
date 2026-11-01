//
// Address Unit
// Effective and linear address formation for D2 issue and the microcode IND sequence
//
`include "z486_platform.svh"
module address_unit
    import z486_pkg::*;
(
    input  logic        clk,
    input  logic        reset_n,
    input  logic        instr_issue,           // Latch the next architectural address
    input  dec_entry_t  instr,
    input  logic        d2_start,            // Latch D2 base/index selection
    input  ea_dec_t     d2_ea,               // Predecoded D2 address recipe
    input  logic        split_ea_prepare,     // Capture base + scaled index
    input  logic        split_ea_use,         // Finish a three-term EA in D2b
    input  logic [2:0]  split_ea_adjust,      // Post-POP ESP correction in D2a
    input  logic [31:0] displacement,
    output gpr_ref_t    ea_base,             // GPR read request to data unit
    output gpr_ref_t    ea_index,            // Second GPR read request to data unit
    input  logic [31:0] ea_base_value,
    input  logic [31:0] ea_index_value,
    input  logic        branch_relative,     // EA is a relative branch target
    input  logic [31:0] branch_target_eip,   // D2-computed relative target
    input  logic [31:0] forwarded_esp,       // ESP including prior delay-slot write
    input  logic        ss_stack32,
    input  logic [31:0] issue_seg_base,      // D2 segment base, independent of seg command feedback
    input  logic        issue_eff_mask,      // D2 address mask, independent of seg command feedback

    input  logic        exec,                // Execute a microcode IND operation
    input  logic        exec_addr32,
    input  logic [5:0]  alu_source,
    input  logic [8:0]  ind_ctrl,            // Registered compact IND controls
    input  logic [31:0] source_value,
    input  logic [31:0] alu_value,
    input  logic [31:0] alu_value_hold,
    input  logic        jcc_word,            // Executing Jcc's IN=+ word: add the held displacement
    input  logic        pe,
    input  logic        is_dword,
    input  logic        descsw_mode,
    input  logic        cs_stack32,

    input  logic [3:0]  seg_cmd,             // Segment command paired with this cycle
    input  logic [3:0]  seg_sel,             // Segment selected by segmentation unit
    input  logic [31:0] seg_base_pending,    // Base for current relocation
    input  logic        eff_mask_pending,    // 32-bit effective-offset enable
    input  logic [31:0] lar_result,
    input  logic [31:0] llim_result,
    input  logic [31:0] lbas_result,
    input  logic [2:0]  fault_code,
    input  logic [31:0] fault_addr,
    input  logic [31:0] cr3,

    output logic [31:0] ind,
    output logic [31:0] ind_delta,
    output logic        ind_delta_dword,   // ind_delta is +4 or -4, registered with it
    output logic [31:0] ind_linear,          // Registered relocated IND
    output logic        ind_linear_valid,    // Relocation matches current IND
    output logic [31:0] ea,
    output logic [31:0] issue_ea,              // Combinational D2 effective address
    output logic [31:0] issue_linear,          // Combinational D2 relocated address
    output logic [1:0]  issue_linear_low,      // Low address bits without full relocation
    output logic [31:0] issue_mem_linear       // The issuing instruction's memory address (stack, moffs or ModR/M)
);

logic [1:0] ea_scale_r;
logic       ea_is_16bit_r;
logic       ea_scale_to_base_r;
logic [31:0] ea_partial_r;
logic [31:0] issue_ind_r;
logic [31:0] exec_ind_r;
logic        ind_owner_issue_r;
logic [31:0] issue_linear_r;
logic [31:0] exec_linear_r;
logic        linear_owner_issue_r;

wire [3:0] ind_op = ind_ctrl[3:0];
wire       ind_source_irf2 = ind_ctrl[4];
wire [2:0] ind_dest_class = ind_ctrl[7:5];
wire       ind_stssaf = ind_ctrl[8];

localparam [3:0] INDOP_PLUS_ALU  = 4'd1;
localparam [3:0] INDOP_ALU2      = 4'd2;
localparam [3:0] INDOP_SRC       = 4'd3;
localparam [3:0] INDOP_PLUS      = 4'd4;
localparam [3:0] INDOP_IN_PLUS_D = 4'd5;
localparam [3:0] INDOP_LAR       = 4'd6;
localparam [3:0] INDOP_LLIM      = 4'd7;
localparam [3:0] INDOP_LBAS      = 4'd8;
localparam [3:0] INDOP_LPCR      = 4'd9;

localparam [2:0] INDDEST_DESSTK = 3'd1;
localparam [2:0] INDDEST_DESCOD = 3'd2;
localparam [2:0] INDDEST_DESSEG = 3'd3;
localparam [2:0] INDDEST_PFERRC = 3'd4;
localparam [2:0] INDDEST_LATTTF = 3'd5;
localparam [2:0] INDDEST_PDBR   = 3'd6;

// Keep D2 and microcode address updates on independent register inputs. This
// prevents D2 admission from selecting through the much wider execution IND
// update mux while preserving issue priority on simultaneous boundaries.
assign ind = ind_owner_issue_r ? issue_ind_r : exec_ind_r;
assign ind_linear = linear_owner_issue_r ? issue_linear_r : exec_linear_r;

//=============================================================================
// D2 effective-address formation
//=============================================================================

function automatic logic [2:0] onehot_idx(input logic [7:0] onehot);
    onehot_idx = onehot[1] ? 3'd1 : onehot[2] ? 3'd2 :
                 onehot[3] ? 3'd3 : onehot[4] ? 3'd4 :
                 onehot[5] ? 3'd5 : onehot[6] ? 3'd6 :
                 onehot[7] ? 3'd7 : 3'd0;
endfunction

// Relocation as a 3:2 carry-save stage. Folding the segment base into the EA
// sum removes one 32-bit carry chain from the linear path at zero cycles:
//   a + b + s == (a^b^s) + (((a&b)|(b&s)|(a&s)) << 1)   (mod 2^32)
// is exact for every operand, and the final carry-propagate adder is the one
// the second '+' used to be. ea_offset_full still forms effective_addr in
// parallel; POP-LIN FUSE below checks the fused relocation every issuing cycle.
function automatic logic [31:0] relocate_csa32(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [31:0] s
);
    automatic logic [31:0] carry;
    carry = (a & b) | (b & s) | (a & s);
    relocate_csa32 = (a ^ b ^ s) + {carry[30:0], 1'b0};
endfunction

wire [63:0] ea_terms = ea_scale_operands(
    ea_base_value, ea_index_value, ea_scale_r, ea_scale_to_base_r);
wire [31:0] ea_term_a_live = ea_terms[63:32];
wire [31:0] ea_term_b_live = ea_terms[31:0];
// A simple EA has at most two live terms. Select them before the adder so the
// split does not leave a base+index+displacement cone in the normal D2 path.
wire        ea_simple_two_regs = ea_base.valid && ea_index.valid &&
                                 !ea_scale_to_base_r;
wire [31:0] ea_simple_a = ea_base.valid ? ea_term_a_live : ea_term_b_live;
wire [31:0] ea_simple_b = ea_simple_two_regs ? ea_term_b_live : displacement;
wire [31:0] ea_add_a = split_ea_use ? ea_partial_r : ea_simple_a;
wire [31:0] ea_add_b = split_ea_use ? displacement : ea_simple_b;
wire [31:0] ea_offset_full = ea_add_a + ea_add_b;
wire [31:0] effective_addr = ea_is_16bit_r
                           ? {16'd0, ea_offset_full[15:0]} : ea_offset_full;
wire [31:0] linear32 = relocate_csa32(ea_add_a, ea_add_b, issue_seg_base);
// The 16-bit arm cannot be folded: it wraps (a + b) at 16 bits BEFORE the
// segment base is added, so the base sees only that add's carry, not the
// three-term sum's; it keeps its own shallow 16-bit add.
wire [31:0] linear16 = {16'd0, ea_offset_full[15:0]} + issue_seg_base;
// Below bit 16 the two arms are one sum: linear16's low half is
// ((a + b) mod 2^16 + s) mod 2^16 == (a + b + s) mod 2^16, linear32's low
// half. So the low half (the D-cache set index and the in-page offset) always
// comes from the folded sum and only the high half selects between the arms;
// the 16-bit arm's serial add is left to the page bits.
// tests/equiv/addr_csa_low16.v proves it equal to the two-arm select.
wire        effective_linear16 = ea_is_16bit_r || !issue_eff_mask;
wire [31:0] effective_linear = {effective_linear16 ? linear16[31:16] : linear32[31:16],
                                linear32[15:0]};
// Alignment participates in same-cycle VIPT admission. It depends only on the
// low address bits, so keep both full-width EA and relocation adders out of it.
wire [3:0] issue_linear_low_sum = {2'b0, ea_add_a[1:0]} +
                                  {2'b0, ea_add_b[1:0]} +
                                  {2'b0, issue_seg_base[1:0]};
assign issue_ea = effective_addr;
assign issue_linear = effective_linear;
assign issue_linear_low = issue_linear_low_sum[1:0];

always_ff @(posedge clk) begin
    if (!reset_n)
        ea_partial_r <= 32'd0;
    else if (split_ea_prepare)
        ea_partial_r <= ea_term_a_live + ea_term_b_live + split_ea_adjust;
end

always_ff @(posedge clk) begin
    if (d2_start) begin
        ea_base.valid <= |d2_ea.base_sel;
        ea_base.index <= onehot_idx(d2_ea.base_sel);
        ea_index.valid <= |d2_ea.index_sel;
        ea_index.index <= onehot_idx(d2_ea.index_sel);
        ea_scale_r <= d2_ea.scale;
        ea_is_16bit_r <= d2_ea.is16;
        ea_scale_to_base_r <= d2_ea.s2b;
    end
end

// synthesis translate_off
// Prove the fused linear adder against the architectural relocate operation.
always @(posedge clk)
    if (reset_n && instr_issue && instr.has_modrm && !instr.stack_op &&
        !instr.has_moffs &&
        (effective_linear !==
         ((issue_eff_mask ? effective_addr :
                               {16'd0, effective_addr[15:0]}) +
          issue_seg_base)))
        $fatal(1,
               "POP-LIN FUSE MISMATCH: fused=%08x ref=%08x ea=%08x seg=%08x",
               effective_linear,
               (issue_eff_mask ? effective_addr :
                                    {16'd0, effective_addr[15:0]}) +
                   issue_seg_base,
               effective_addr, issue_seg_base);
// synthesis translate_on

//=============================================================================
// Relocation helpers and microcode IND updates
//=============================================================================

function automatic logic [31:0] relocate(input logic [31:0] offset);
    relocate = (eff_mask_pending ? offset : {16'd0, offset[15:0]}) +
               seg_base_pending;
endfunction

// Issue-time relocation bypasses the generic SEG_CMD next-state cone. The
// segmentation unit still receives INIT_SEG and commits identical state.
function automatic logic [31:0] relocate_issue(input logic [31:0] offset);
    relocate_issue = (issue_eff_mask ? offset : {16'd0, offset[15:0]}) +
                     issue_seg_base;
endfunction

// Preserve the dedicated microcode relocation cone used before extraction.
`Z486_KEEP wire [31:0] seg_base_pending_exec = seg_base_pending;

function automatic logic [31:0] relocate_exec(input logic [31:0] offset);
    relocate_exec = (eff_mask_pending ? offset : {16'd0, offset[15:0]}) +
                    seg_base_pending_exec;
endfunction

// Keep the IND update and segment relocation in the FPGA's fused adder.
function automatic logic [31:0] relocate_add2(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic        mask16
);
    relocate_add2 = mask16
                  ? ({16'd0, a[15:0] + b[15:0]} + seg_base_pending_exec)
                  : (a + b + seg_base_pending_exec);
endfunction

logic        exec_linear_write;
logic        exec_linear_three_term;
logic        exec_linear_mask16;
logic [31:0] exec_linear_source;
logic [31:0] exec_linear_a;
logic [31:0] exec_linear_b;
always_comb begin
    exec_linear_write = (seg_cmd == SEG_CMD_DESCSW) ||
                        (ind_stssaf && seg_sel == SEG_SS);
    exec_linear_three_term = 1'b0;
    exec_linear_mask16 = !eff_mask_pending;
    exec_linear_source = ind;
    exec_linear_a = ind;
    exec_linear_b = 32'd0;

    case (ind_op)
        INDOP_PLUS_ALU: begin
            exec_linear_a = ind_source_irf2 ? ind : source_value;
            exec_linear_b = jcc_word ? alu_value_hold : alu_value;
            if (ind_dest_class == INDDEST_DESSTK)
                exec_linear_mask16 = !pe || !ss_stack32;
            else if (ind_dest_class == INDDEST_DESCOD)
                exec_linear_mask16 = !is_dword;
            else if (ind_dest_class == INDDEST_DESSEG)
                exec_linear_mask16 = !exec_addr32;
            exec_linear_write = 1'b1;
            exec_linear_three_term = 1'b1;
        end
        INDOP_ALU2: begin
            exec_linear_write = 1'b1;
            exec_linear_source = alu_value;
        end
        INDOP_SRC: begin
            exec_linear_write = 1'b1;
            exec_linear_source = source_value;
            if (ind_dest_class == INDDEST_DESSTK && (!pe || !ss_stack32))
                exec_linear_source = {16'd0, source_value[15:0]};
            else if (ind_dest_class == INDDEST_DESCOD && !is_dword)
                exec_linear_source = {16'd0, source_value[15:0]};
        end
        INDOP_PLUS: begin
            exec_linear_write = 1'b1;
            exec_linear_three_term = 1'b1;
            exec_linear_a = ind;
            exec_linear_b = alu_value;
        end
        INDOP_IN_PLUS_D: begin
            exec_linear_write = 1'b1;
            exec_linear_three_term = 1'b1;
            exec_linear_a = ind;
            exec_linear_b = ind_delta;
        end
        default: ;
    endcase
end

// The IND two-term sum of INDOP_PLUS_ALU / INDOP_PLUS / INDOP_IN_PLUS_D: the
// same operand pair exec_linear's three-term relocation adds (selected above
// by ind_op), so the IND update needs one adder, not one per op.
wire [31:0] exec_ind_sum = exec_linear_a + exec_linear_b;

// Execution owns a separate relocation register. Updating this shadow in a
// simultaneous issue cycle is harmless because linear_owner_issue_r selects
// the newly issued address; removing issue priority here breaks the D2-to-EX
// control path without adding a pipeline stage.
always_ff @(posedge clk) begin
    if (!reset_n)
        exec_linear_r <= 32'd0;
    else if (exec && exec_linear_write) begin
        if (exec_linear_three_term)
            exec_linear_r <= relocate_add2(exec_linear_a, exec_linear_b,
                                            exec_linear_mask16);
        else
            exec_linear_r <= relocate_exec(exec_linear_source);
    end
end

always_ff @(posedge clk) begin
    if (instr_issue)
        ea <= branch_relative ? branch_target_eip : effective_addr;
end

// The execution IND value is a shadow while a simultaneous D2 issue owns the
// architectural output. Let it update independently so D2 admission and its
// segment-fault qualification do not select through the execution update mux.
// Ownership below still gives the newly issued instruction priority.
always_ff @(posedge clk) begin
    if (!reset_n) begin
        exec_ind_r <= 32'd0;
    end else if (exec) begin
        automatic logic mask16 = !eff_mask_pending;

        case (ind_op)
            INDOP_PLUS_ALU: begin
                automatic logic [31:0] next_ind;
                if (ind_dest_class == INDDEST_DESSTK)
                    mask16 = !pe || !ss_stack32;
                else if (ind_dest_class == INDDEST_DESCOD)
                    mask16 = !is_dword;
                else if (ind_dest_class == INDDEST_DESSEG)
                    mask16 = !exec_addr32;
                next_ind = exec_ind_sum;
                if (mask16 && (ind_dest_class == INDDEST_DESSTK ||
                               ind_dest_class == INDDEST_DESCOD ||
                               ind_dest_class == INDDEST_DESSEG))
                    next_ind = {16'd0, next_ind[15:0]};
                exec_ind_r <= next_ind;
            end
            INDOP_ALU2: exec_ind_r <= alu_value;
            INDOP_SRC: begin
                automatic logic [31:0] next_ind = source_value;
                if (ind_dest_class == INDDEST_DESSTK && (!pe || !ss_stack32))
                    next_ind = {16'd0, next_ind[15:0]};
                else if (ind_dest_class == INDDEST_DESCOD && !is_dword)
                    next_ind = {16'd0, next_ind[15:0]};
                exec_ind_r <= next_ind;
            end
            INDOP_PLUS: begin
                automatic logic [31:0] next_ind = exec_ind_sum;
                if (!pe && !exec_addr32)
                    next_ind = {16'd0, next_ind[15:0]};
                exec_ind_r <= next_ind;
            end
            INDOP_IN_PLUS_D: begin
                automatic logic [31:0] next_ind = exec_ind_sum;
                if (!pe ? !exec_addr32
                        : !(descsw_mode ? cs_stack32 : ss_stack32))
                    next_ind = {16'd0, next_ind[15:0]};
                exec_ind_r <= next_ind;
            end
            INDOP_LAR:  exec_ind_r <= lar_result;
            INDOP_LLIM: exec_ind_r <= llim_result;
            INDOP_LBAS: exec_ind_r <= lbas_result;
            INDOP_LPCR: begin
                case (ind_dest_class)
                    INDDEST_PFERRC: exec_ind_r <= {29'd0, fault_code};
                    INDDEST_LATTTF: exec_ind_r <= fault_addr;
                    INDDEST_PDBR:   exec_ind_r <= cr3;
                    default: ;
                endcase
            end
            default: ;
        endcase
    end
end

// The address an issuing instruction's first memory access uses: the
// forwarded ESP for a stack operation, the immediate for moffs, else the
// ModR/M effective address. The issue edge captures exactly this value.
// A push's pre-decrement is one 32-bit subtract: a 16-bit stack keeps its low
// half, which is the wrapped SP.
wire [31:0] issue_stack_dec = forwarded_esp - (instr.data32 ? 32'd4 : 32'd2);
wire [31:0] issue_stack_offset = instr.stack_dir
    ? (ss_stack32 ? forwarded_esp : {16'd0, forwarded_esp[15:0]})
    : (ss_stack32 ? issue_stack_dec : {16'd0, issue_stack_dec[15:0]});
assign issue_mem_linear = (instr.stack_op || instr.has_moffs)
                        ? relocate_issue(instr.stack_op ? issue_stack_offset : instr.immediate)
                        : effective_linear;

// z486.sv sizes a RD W/WR W access by |IND_DELTA| == 4; the compare is formed
// on the value as it is written, beside ind_delta, so the 32-bit compare is
// not in front of mem_eff_size -> the paging request (tests/equiv/
// ind_delta_dword.v; a translate_off fuse holds it every cycle).
function automatic logic is_dword_stride(input logic [31:0] v);
    is_dword_stride = (v == 32'd4) || (v == -32'd4);
endfunction
// synthesis translate_off
always @(posedge clk)
    if (reset_n && (ind_delta_dword !== is_dword_stride(ind_delta)))
        $fatal(1, "address_unit: ind_delta_dword %b disagrees with ind_delta %h", ind_delta_dword, ind_delta);
// synthesis translate_on

always_ff @(posedge clk) begin
    if (!reset_n) begin
        issue_ind_r <= 32'd0;
        ind_owner_issue_r <= 1'b0;
        ind_delta <= 32'd4;
        ind_delta_dword <= 1'b1;
        issue_linear_r <= 32'd0;
        linear_owner_issue_r <= 1'b0;
        ind_linear_valid <= 1'b0;
    end else if (instr_issue) begin
        linear_owner_issue_r <= 1'b1;
        ind_linear_valid <= 1'b0;
        ind_delta <= !instr.stack_op ? 32'd2 :
                     !instr.stack_dir ? (instr.data32 ? -32'd4 : -32'd2) :
                                        (instr.data32 ? 32'd4 : 32'd2);
        ind_delta_dword <= instr.stack_op && instr.data32;
        if (instr.stack_op) begin
            issue_ind_r <= issue_stack_offset;
            ind_owner_issue_r <= 1'b1;
            issue_linear_r <= issue_mem_linear;
            ind_linear_valid <= 1'b1;
        end else if (instr.has_moffs) begin
            issue_ind_r <= instr.addr32 ? instr.immediate
                                        : {16'd0, instr.immediate[15:0]};
            ind_owner_issue_r <= 1'b1;
            issue_linear_r <= issue_mem_linear;
            ind_linear_valid <= 1'b1;
        end else if (instr.has_modrm) begin
            issue_ind_r <= effective_addr;
            ind_owner_issue_r <= 1'b1;
            issue_linear_r <= issue_mem_linear;
            ind_linear_valid <= 1'b1;
        end
    end else if (exec) begin
        case (ind_op)
            INDOP_PLUS_ALU: begin
                automatic logic [31:0] operand2;
                operand2 = jcc_word ? alu_value_hold : alu_value;
                if (alu_source != ALUSRC_ZERO) begin
                    ind_delta <= operand2;
                    ind_delta_dword <= is_dword_stride(operand2);
                end
                ind_owner_issue_r <= 1'b0;
                ind_linear_valid <= 1'b1;
            end
            INDOP_ALU2: begin
                ind_owner_issue_r <= 1'b0;
                ind_linear_valid <= 1'b1;
            end
            INDOP_SRC: begin
                ind_owner_issue_r <= 1'b0;
                ind_linear_valid <= 1'b1;
            end
            INDOP_PLUS: begin
                ind_owner_issue_r <= 1'b0;
                ind_linear_valid <= 1'b1;
                if (alu_source != ALUSRC_ZERO) begin
                    ind_delta <= alu_value;
                    ind_delta_dword <= is_dword_stride(alu_value);
                end
            end
            INDOP_IN_PLUS_D: begin
                ind_owner_issue_r <= 1'b0;
                ind_linear_valid <= 1'b1;
            end
            INDOP_LAR: begin
                ind_owner_issue_r <= 1'b0;
                ind_linear_valid <= 1'b0;
            end
            INDOP_LLIM: begin
                ind_owner_issue_r <= 1'b0;
                ind_linear_valid <= 1'b0;
            end
            INDOP_LBAS: begin
                ind_owner_issue_r <= 1'b0;
                ind_linear_valid <= 1'b0;
            end
            INDOP_LPCR: begin
                case (ind_dest_class)
                    INDDEST_PFERRC: begin
                        ind_owner_issue_r <= 1'b0;
                    end
                    INDDEST_LATTTF: begin
                        ind_owner_issue_r <= 1'b0;
                    end
                    INDDEST_PDBR: begin
                        ind_owner_issue_r <= 1'b0;
                    end
                    default: ;
                endcase
                ind_linear_valid <= 1'b0;
            end
            default: ;
        endcase

        if (exec_linear_write)
            linear_owner_issue_r <= 1'b0;
    end
end

endmodule

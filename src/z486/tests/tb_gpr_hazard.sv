`timescale 1ns/1ns
`include "z486_platform.svh"
// GPR hazard survey bench (Data Unit).
//
// Every case here pits an OLDER deferred producer against a YOUNGER one on the
// same register and asks whether the arbitration awards the write to the
// younger producer.  The commit path was fixed first (tb_load_waw); this bench
// extends the same question to the combinational forwarding views and to the
// other late producers, so the whole class is visible in one place.  A reported
// HAZARD means the core's own arbitration answer depends on which path a
// consumer happens to use.

module tb_gpr_hazard;
    localparam [31:0] OLD_VALUE = 32'hAAAA_AAAA;
    localparam [31:0] NEW_VALUE = 32'h0000_BEEF;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic test_done = 1'b0;
    logic test_failed = 1'b0;

    logic reset_n;

    logic exec;
    logic shift_exec;
    logic instr_start;
    logic halted;
    logic ifetch_page_fault;
    logic interrupt_entry;
    logic repeat_active;
    logic clear_rf;
    logic pipeline_advance;
    logic stack_op;
    logic stack_dir;
    logic stack_data32;
    logic stack32;
    logic gate_detect;
    logic any_fault;
    logic uc_active;
    logic recipe_rni;
    z486_pkg::recipe_state_t recipe_state;
    logic hardwired_off;
    logic recipe_commit_cancel;
    logic load_wb_valid;
    logic [2:0] load_wb_dst;
    logic [1:0] load_wb_size;
    logic [31:0] load_wb_data;
    logic load_wb_is_alu;
    logic [4:0] load_wb_alu_op;
    logic load_alu_dst_capture;
    logic [2:0] load_alu_dst_capture_dst;
    logic [1:0] load_alu_dst_capture_size;
    logic [31:0] load_alu_dst_capture_data;
    logic [6:0] aluop;
    logic [4:0] alu_operation;
    logic [6:0] shift_aluop;
    logic [1:0] shift_sigma_sel;
    logic [6:0] dest;
    logic [5:0] source_field;
    logic [5:0] source_live;
    logic [5:0] alu_source;
    logic [5:0] alu_source_live;
    logic fpu_f8;
    logic [3:0] shift_source_class;
    logic [1:0] shift2_source;
    logic shift_is_shift2;
    logic shift2_capture_ce;
    logic shift2_next_valid;
    logic [1:0] shift2_next_source;
    logic shift_uc_carry;
    logic [1:0] op_size;
    logic [1:0] srcreg_size;
    logic [1:0] op_size_src;
    logic [1:0] srcreg_size_src;
    logic update_arch_flags;
    logic update_carry;
    z486_pkg::dec_entry_t instr;
    z486_pkg::dec_entry_t next_instr;
    logic pe;
    logic [1:0] cpl;
    logic is_dword;
    logic is_signed_mul;
    logic [31:0] eip;
    logic [31:0] cr0;
    logic [31:0] cr2;
    logic [31:0] tmpeip;
    logic [31:0] tmpesp;
    logic [31:0] dr6;
    logic [31:0] dr7;
    logic [31:0] slctr;
    logic [31:0] protun;
    logic [31:0] ind;
    logic [31:0] ea;
    logic [15:0] es;
    logic [15:0] cs;
    logic [15:0] ss;
    logic [15:0] ds;
    logic [15:0] fs;
    logic [15:0] gs;
    logic [15:0] ldtr;
    logic [15:0] tr;
    logic [2:0] seg_reg_sel;
    logic [31:0] forwarded_esp;
    logic [31:0] desc_raw_hi;
    logic [31:0] opr_r;
    z486_pkg::gpr_ref_t ea_base;
    z486_pkg::gpr_ref_t ea_index;
    z486_pkg::gpr_forward_t dly_gpr_forward;
    logic [7:0] pend_write_mask;
    logic opr_fast_commit;
    logic [31:0] shift_data_latched;

    wire [31:0] sigma;
    wire [31:0] countr;
    wire [31:0] alu_src_hold;
    wire [31:0] source_value_live;
    wire [31:0] memory_write_source_value;
    wire [31:0] alu_source_value_live;
    wire [31:0] dest_value;
    wire [31:0] alu_src;
    wire [31:0] eax;
    wire [31:0] ecx;
    wire [31:0] edx;
    wire [31:0] ebx;
    wire [31:0] esp;
    wire [31:0] ebp;
    wire [31:0] esi;
    wire [31:0] edi;
    wire [31:0] tmpc;
    wire [31:0] tmpg;
    wire [31:0] opr_w;
    wire [31:0] protection_source_value;
    wire protection_source_low16_nonzero;
    wire [15:0] cs_source_value;
    wire [31:0] ea_base_value;
    wire [31:0] ea_index_value;
    wire [31:0] eflags;
    wire [31:0] uc_flags;
    wire [31:0] flags_backup;
    wire flags_backup_active;
    wire [31:0] eflags_fwd;
    wire branch_condition_true;
    z486_pkg::recipe_pending_write_t recipe_shift_write;
    wire [31:0] recipe_shift_data;
    z486_pkg::recipe_pending_write_t recipe_memory_write;
    wire [31:0] muldiv_result;
    wire div_overflow;
    wire [31:0] alu_result;
    wire [31:0] shift_result;

    // The caller registers producer 3's view hits with the write-back
    // (data_access vipt_load_wb_view_hit_r); the bench forms them from its stimulus.
    function automatic [31:0] wb_view_hit_of(input v, input [2:0] dst, input [1:0] size, input is_alu);
        logic [2:0] r;
        logic [3:0] be;
        begin
            r  = (size == 2'd0) ? {1'b0, dst[1:0]} : dst;
            be = (size == 2'd0) ? (dst[2] ? 4'h2 : 4'h1) : (size == 2'd1) ? 4'h3 : 4'hF;
            wb_view_hit_of = (v && !is_alu) ? ({28'h0, be} << {r, 2'b00}) : 32'h0;
        end
    endfunction

    // The delay-slot write's lanes, which z486 registers with its descriptor
    // (dly_gpr_lanes_pre_r); EA_FWD_BLO/BHI/W/D are 0/1/2/3.
    function automatic [31:0] dly_lanes_of(input [2:0] dst, input [1:0] mode);
        logic [2:0] r;
        logic [3:0] be;
        begin
            r  = (mode <= 2'd1) ? {1'b0, dst[1:0]} : dst;
            be = (mode == 2'd0) ? 4'h1 : (mode == 2'd1) ? 4'h2 : (mode == 2'd2) ? 4'h3 : 4'hF;
            dly_lanes_of = {28'h0, be} << {r, 2'b00};
        end
    endfunction

    data_unit dut (
        .clk(clk),
        .reset_n(reset_n),
        .exec(exec),
        .shift_exec(shift_exec),
        .instr_start(instr_start),
        .halted(halted),
        .ifetch_page_fault(ifetch_page_fault),
        .interrupt_entry(interrupt_entry),
        .repeat_active(repeat_active),
        .clear_rf(clear_rf),
        .pipeline_advance(pipeline_advance),
        .stack_op(stack_op),
        .stack_dir(stack_dir),
        .stack_data32(stack_data32),
        .stack32(stack32),
        .gate_detect(gate_detect),
        .any_fault(any_fault),
        .uc_active(uc_active),
        .recipe_rni(recipe_rni),
        .recipe_state(recipe_state),
        .load_issue(1'b0),
        .load_pipe_flush(1'b0),
        .recipe_commit_cancel(recipe_commit_cancel),
        .load_wb_valid(load_wb_valid),
        .load_wb_dst(load_wb_dst),
        .load_wb_size(load_wb_size),
        // data_access registers this one-hot with the write-back (vipt_load_wb_wmask_r).
        .load_wb_wmask(load_wb_valid ? (8'h01 << ((load_wb_size == 2'd0)
                                                  ? {1'b0, load_wb_dst[1:0]}
                                                  : load_wb_dst)) : 8'h00),
        .load_wb_view_hit(wb_view_hit_of(load_wb_valid, load_wb_dst, load_wb_size, load_wb_is_alu)),
        // data_access registers the AH lane select beside the write-back's
        // dst/size (vipt_load_wb_ah_r), so it is the decode every cycle.
        .load_wb_ah((load_wb_size == 2'd0) && load_wb_dst[2]),
        .load_wb_data(load_wb_data),
        .load_wb_is_alu(load_wb_is_alu),
        .load_wb_alu_op(load_wb_alu_op),
        .load_alu_dst_capture(load_alu_dst_capture),
        .load_alu_dst_capture_dst(load_alu_dst_capture_dst),
        .load_alu_dst_capture_size(load_alu_dst_capture_size),
        .load_alu_dst_capture_data(load_alu_dst_capture_data),
        .aluop(aluop),
        .alu_operation(alu_operation),
        .shift_aluop(shift_aluop),
        .shift_sigma_sel(shift_sigma_sel),
        .dest(dest),
        .source_field(source_field),
        .source_live(source_live),
        .alu_source(alu_source),
        .alu_source_live(alu_source_live),
        .fpu_f8(fpu_f8),
        .shift_source_class(shift_source_class),
        .shift2_source(shift2_source),
        .shift_is_shift2(shift_is_shift2),
        .shift_use_captured(shift_is_shift2 ||
                            ((aluop == z486_pkg::ALUJMP_SHIFT) && (shift_source_class == 4'd3))),
        .shift2_capture_ce(shift2_capture_ce),
        .shift2_next_valid(shift2_next_valid),
        .shift2_next_source(shift2_next_source),
        .shift_uc_carry(shift_uc_carry),
        .op_size(op_size),
        .op_size_is0(op_size == 2'd0),
        .op_size_is1(op_size == 2'd1),
        .srcreg_size(srcreg_size),
        .op_size_src(op_size_src),
        .srcreg_size_src(srcreg_size_src),
        .update_arch_flags(update_arch_flags),
        .update_carry(update_carry),
        .instr(instr),
        .next_instr(next_instr),
        .pe(pe),
        .cpl(cpl),
        .is_dword(is_dword),
        .is_signed_mul(is_signed_mul),
        .eip(eip),
        .cr0(cr0),
        .cr2(cr2),
        .tmpeip(tmpeip),
        .tmpesp(tmpesp),
        .dr6(dr6),
        .dr7(dr7),
        .slctr(slctr),
        .protun(protun),
        .ind(ind),
        .ea(ea),
        .es(es),
        .cs(cs),
        .ss(ss),
        .ds(ds),
        .fs(fs),
        .gs(gs),
        .ldtr(ldtr),
        .tr(tr),
        .seg_reg_sel(seg_reg_sel),
        .forwarded_esp(forwarded_esp),
        .desc_raw_hi(desc_raw_hi),
        .opr_r(opr_r),
        .ea_base(ea_base),
        .ea_index(ea_index),
        .dly_gpr_forward(dly_gpr_forward),
        .dly_gpr_lanes(dly_lanes_of(dly_gpr_forward.dst, dly_gpr_forward.mode)),
        .dly_gpr_onehot(8'h01 << dly_gpr_forward.dst),
        .sigma(sigma),
        .countr(countr),
        .alu_src_hold(alu_src_hold),
        .source_value_live(source_value_live),
        .memory_write_source_value(memory_write_source_value),
        .alu_source_value_live(alu_source_value_live),
        .pend_write_mask(pend_write_mask),
        .opr_fast_commit(opr_fast_commit),
        .x87_reg_commit(1'b0),
        .x87_store_commit(1'b0),
        .dest_value(dest_value),
        .alu_src(alu_src),
        .eax(eax),
        .ecx(ecx),
        .edx(edx),
        .ebx(ebx),
        .esp(esp),
        .ebp(ebp),
        .esi(esi),
        .edi(edi),
        .tmpc(tmpc),
        .tmpg(tmpg),
        .opr_w(opr_w),
        .protection_source_value(protection_source_value),
        .protection_source_low16_nonzero(protection_source_low16_nonzero),
        .cs_source_value(cs_source_value),
        .ea_base_value(ea_base_value),
        .ea_index_value(ea_index_value),
        .eflags(eflags),
        .uc_flags(uc_flags),
        .flags_backup(flags_backup),
        .flags_backup_active(flags_backup_active),
        .eflags_fwd(eflags_fwd),
        .branch_condition_true(branch_condition_true),
        .recipe_shift_write(recipe_shift_write),
        .recipe_shift_data(recipe_shift_data),
        .recipe_memory_write(recipe_memory_write),
        .muldiv_result(muldiv_result),
        .div_overflow(div_overflow),
        .alu_result(alu_result),
        .shift_result(shift_result)
    );

    task automatic idle_inputs();
        begin
            exec = 1'b0;
            shift_exec = 1'b0;
            instr_start = 1'b0;
            halted = 1'b0;
            ifetch_page_fault = 1'b0;
            interrupt_entry = 1'b0;
            repeat_active = 1'b0;
            clear_rf = 1'b0;
            pipeline_advance = 1'b0;
            stack_op = 1'b0;
            stack_dir = 1'b0;
            stack_data32 = 1'b0;
            stack32 = 1'b0;
            gate_detect = 1'b0;
            any_fault = 1'b0;
            uc_active = 1'b1;
            recipe_rni = 1'b0;
            recipe_state = '0;
            hardwired_off = 1'b0;
            recipe_commit_cancel = 1'b0;
            load_wb_valid = 1'b0;
            load_wb_dst = 3'd0;
            load_wb_size = 2'd2;
            load_wb_data = 32'd0;
            load_wb_is_alu = 1'b0;
            load_wb_alu_op = 5'd0;
            load_alu_dst_capture = 1'b0;
            load_alu_dst_capture_dst = 3'd0;
            load_alu_dst_capture_size = 2'd2;
            load_alu_dst_capture_data = 32'd0;
            opr_fast_commit = 1'b0;
            opr_r = 32'd0;
            dest = 7'h7E;   // no EX GPR write
            op_size = 2'd2;
        end
    endtask

    // Priming helper: capture the younger ALU load's GPR base = 0.
    task automatic prime_alu_base();
        begin
            load_alu_dst_capture = 1'b1;
            load_alu_dst_capture_dst = 3'd0;
            load_alu_dst_capture_size = 2'd2;
            load_alu_dst_capture_data = 32'd0;
        end
    endtask

    // Retire an older hardwired MOV load through RECIPE_COMMIT_MEM.
    task automatic commit_old_token(input logic [2:0] reg_sel,
                                    input logic [1:0] size,
                                    input logic [31:0] old_value);
        begin
            exec = 1'b0;
            instr_start = 1'b1;
            recipe_rni = 1'b0;
            pipeline_advance = 1'b0;
            next_instr = '0;
            next_instr.dst_reg_sel = reg_sel;
            op_size = size;
            @(posedge clk);
            #1;

            exec = 1'b1;
            instr_start = 1'b1;
            recipe_rni = 1'b1;
            pipeline_advance = 1'b1;
            recipe_state = '0;
            recipe_state.hardwired = 1'b1;
            recipe_state.commit_sel = z486_pkg::RECIPE_COMMIT_MEM;
            next_instr = '0;
            next_instr.dst_reg_sel = reg_sel;
            op_size = size;
            opr_r = old_value;
        end
    endtask

    // Retire a younger direct load through load_wb in the same edge.
    task automatic commit_young_load(input logic [2:0] reg_sel,
                                     input logic [1:0] size,
                                     input logic [31:0] data);
        begin
            load_wb_valid = 1'b1;
            load_wb_dst = reg_sel;
            load_wb_size = size;
            load_wb_data = data;
            load_wb_is_alu = 1'b1;
            load_wb_alu_op = z486_pkg::ALU_ADD;
        end
    endtask

    integer hazard_count = 0;
    initial begin
        idle_inputs();
        recipe_state = '0;
        instr = '0;
        next_instr = '0;
        ea_base = '0;
        ea_index = '0;
        dly_gpr_forward = '0;
        reset_n = 1'b0;
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        @(negedge clk);

        // ------------------------------------------------------------------
        // H1/H2: with an older deferred MEM token AND the younger direct-load
        // write-back both targeting EAX, every view used for forwarding must
        // present the YOUNGER value (the commit path does since the
        // write-back order fix).  A view that still favours the token is the
        // same age-order defect, just in the combinational path.
        // ------------------------------------------------------------------
        prime_alu_base();
        commit_old_token(3'd0, 2'd2, OLD_VALUE);
        @(posedge clk);
        #1;
        idle_inputs();
        opr_r = OLD_VALUE;                 // the token's (older) data source
        commit_young_load(3'd0, 2'd2, NEW_VALUE);
        load_wb_is_alu = 1'b0;             // a plain load write-back, not an M3 result
        #1;
        $display("H1 ex_view      : %08x %s", dut.gpr_ex_view[0],
                 (dut.gpr_ex_view[0] === NEW_VALUE) ? "OK (younger)" : "HAZARD (older token wins)");
        $display("H2 capture_view : %08x %s", dut.gpr_capture_view[0],
                 (dut.gpr_capture_view[0] === NEW_VALUE) ? "OK (younger)" : "HAZARD (older token wins)");
        if (dut.gpr_ex_view[0] !== NEW_VALUE) hazard_count = hazard_count + 1;
        if (dut.gpr_capture_view[0] !== NEW_VALUE) hazard_count = hazard_count + 1;
        @(posedge clk);
        #1;
        $display("H0 commit       : %08x %s", eax,
                 (eax === NEW_VALUE) ? "OK (younger)" : "HAZARD (older token wins)");
        if (eax !== NEW_VALUE) hazard_count = hazard_count + 1;

        // ------------------------------------------------------------------
        // H3: the EA view has no deferred-load term at all, so a D2 consumer
        // that reads the token's register gets the stale GPR rather than the
        // pending load value.  Correctness then depends entirely on the D2
        // interlock stalling such a reader.  Report the raw view.
        // ------------------------------------------------------------------
        idle_inputs();
        reset_n = 1'b0;
        repeat (2) @(posedge clk);
        reset_n = 1'b1;
        @(negedge clk);
        prime_alu_base();
        commit_old_token(3'd0, 2'd2, OLD_VALUE);
        @(posedge clk);
        #1;
        idle_inputs();
        opr_r = OLD_VALUE;
        ea_base.valid = 1'b1;
        ea_base.index = 3'd0;
        #1;
        $display("H3 ea_view      : %08x (token value %08x) %s", dut.gpr_ea_view[0], OLD_VALUE,
                 (dut.gpr_ea_view[0] === OLD_VALUE) ? "forwards token" : "does NOT forward the deferred load");

        // ------------------------------------------------------------------
        // H4: the interrupt-entry ROM-slot write commits after the token in
        // the same cycle.  It writes OPR_R to the token's own destination, so
        // the two agree and there is nothing to arbitrate.
        // ------------------------------------------------------------------
        idle_inputs();
        reset_n = 1'b0;
        repeat (2) @(posedge clk);
        reset_n = 1'b1;
        @(negedge clk);
        prime_alu_base();
        commit_old_token(3'd0, 2'd2, OLD_VALUE);
        @(posedge clk);
        #1;
        idle_inputs();
        opr_r = OLD_VALUE;
        interrupt_entry = 1'b1;
        recipe_rni = 1'b1;
        recipe_state = '0;
        recipe_state.hardwired = 1'b1;
        recipe_state.commit_sel = z486_pkg::RECIPE_COMMIT_MEM;
        op_size = 2'd2;
        @(posedge clk);
        #1;
        $display("H4 intr rom slot: %08x %s", eax,
                 (eax === OLD_VALUE) ? "OK (token and ROM slot agree)" : "HAZARD (mismatch)");
        if (eax !== OLD_VALUE) hazard_count = hazard_count + 1;

        // ------------------------------------------------------------------
        // H5: boundary probe, not a hardware-reachable case.  An EX GPR write
        // is a held level while the pipeline stalls, so a token can never
        // outlive it in the core; this shows what the arbitration alone does.
        // ------------------------------------------------------------------
        idle_inputs();
        reset_n = 1'b0;
        repeat (2) @(posedge clk);
        reset_n = 1'b1;
        @(negedge clk);
        prime_alu_base();
        commit_old_token(3'd0, 2'd2, OLD_VALUE);
        @(posedge clk);
        #1;
        idle_inputs();
        opr_r = OLD_VALUE;
        exec = 1'b1;
        dest = z486_pkg::DEST_EAX;
        op_size = 2'd2;
        source_live = z486_pkg::SRC_EIP;
        source_field = z486_pkg::SRC_EIP;
        eip = 32'h1234_5678;
        @(posedge clk);
        #1;
        idle_inputs();
        opr_r = 32'h5A5A_5A5A;
        @(posedge clk);
        #1;
        $display("H5 ex write vs token (unit-only probe): %08x %s", eax,
                 (eax === 32'h1234_5678) ? "kept the EX write"
                                         : "token recommitted over a younger EX write");

        $display("");
        if (hazard_count == 0) begin
            $display("GPR HAZARD SURVEY: no hazards observed");
            test_failed = 1'b0;
        end else begin
            $display("GPR HAZARD SURVEY: %0d hazard(s) observed", hazard_count);
            test_failed = 1'b1;
        end
        test_done = 1'b1;
        $finish;
    end

    initial begin
        repeat (4000) @(posedge clk);
        $display("GPR HAZARD SURVEY FAIL timeout");
        test_failed = 1'b1;
        test_done = 1'b1;
        $finish;
    end
endmodule

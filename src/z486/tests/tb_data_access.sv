// Unit pin for the stale-OPR_R route rule. Deliberately inject the older
// deferred-token condition; this proves the fallback contract, not that a
// particular instruction sequence reaches the window in the integrated CPU.
`timescale 1ns/1ns
module tb_data_access;
    import z486_pkg::*;
    logic clk = '0;
    logic reset_n = '0;
    logic dcache_vipt_probe_accepted = '0;
    logic dcache_vipt_probe_direct_accepted = '0;
    logic dcache_vipt_probe_ready = '0;
    logic [31:0] dcache_vipt_resolve_data = '0;
    logic dcache_vipt_resolve_hit = '0;
    logic dcache_wr_ready = '0;
    logic memmap_windows = '0;
    logic fast_store_accepted = '0;
    logic [31:0] CR0 = '0;
    logic mem_accepted = '0;
    logic mem_servicing = '0;
    logic paging_demand_idle = '0;
    logic [1:0] pg_cpl = '0;
    logic vipt_tlb_dirty = '0;
    logic vipt_tlb_hit = '0;
    logic vipt_tlb_is_vga_mem = '0;
    logic [31:0] vipt_tlb_phys_addr = '0;
    logic vipt_tlb_user = '0;
    logic vipt_tlb_writable = '0;
    logic ds_flat = '0;
    logic [31:0] ind_linear = '0;
    logic ind_linear_valid = '0;
    logic [31:0] issue_ind_linear = '0;
    logic [1:0] issue_ind_linear_low = '0;
    logic [31:0] issue_load_linear = '0;
    logic [1:0] issue_load_low = '0;
    logic [31:0] issue_mem_linear = '0;
    logic pe = '0;
    logic seg_gp_fault = '0;
    logic dir_seg_fault = '0;
    logic dir_rmw_fault = '0;
    logic ss_segment_fault = '0;
    logic ss_flat32 = '0;
    logic [31:0] forwarded_esp = '0;
    logic [31:0] mem_wdata = '0;
    logic [31:0] OPR_R = '0;
    logic [31:0] SIGMA = '0;
    logic d2_vipt_ea_hazard = '0;
    logic vipt_load_ex_token_pending = '0;
    logic [31:0] EIP = '0;
    logic hardwired_off = '0;
    dec_entry_t i_bus = '0;
    logic i_issue = '0;
    logic single_step = '0;
    logic any_fault = '0;
    logic gp_fault_trigger = '0;
    dec_entry_t i_ex = '0;
    logic i_first = '0;
    logic i_rni_delay = '0;
    logic interrupt_entry = '0;
    logic [1:0] mem_eff_size = '0;
    logic mem_is_io = '0;
    logic mem_op_eligible = '0;
    logic q_flush = '0;
    logic stall = '0;
    logic stall_invlpg = '0;
    logic stall_wio = '0;
    logic stall_x87_direct = '0;
    logic uc_active = '0;
    logic        rmw_fallback_release = 1'b0;
    logic [5:0] uc_buscode = '0;
    logic uc_busreq = '0;
    logic uc_data_busreq = '0;
    logic uc_exec = '0;
    logic uc_is_check_write = '0;
    logic uc_is_mem_busop = '0;
    logic uc_is_write = '0;
    logic uc_p_pure_dly = '0;
    logic x87_direct_mem_req = '0;
    always #5 clk = ~clk;
    data_access dut (
        .clk(clk),
        .reset_n(reset_n),
        .dcache_vipt_probe_accepted(dcache_vipt_probe_accepted),
        .dcache_vipt_probe_direct_accepted(dcache_vipt_probe_direct_accepted),
        .dcache_vipt_probe_ready(dcache_vipt_probe_ready),
        .dcache_vipt_resolve_data(dcache_vipt_resolve_data),
        .dcache_vipt_resolve_hit(dcache_vipt_resolve_hit),
        .dcache_wr_ready(dcache_wr_ready),
        .memmap_windows(memmap_windows),
        .fast_store_accepted(fast_store_accepted),
        .CR0(CR0),
        .mem_accepted(mem_accepted),
        .mem_servicing(mem_servicing),
        .paging_demand_idle(paging_demand_idle),
        .pg_cpl(pg_cpl),
        .vipt_tlb_dirty(vipt_tlb_dirty),
        .vipt_tlb_hit(vipt_tlb_hit),
        .vipt_tlb_is_vga_mem(vipt_tlb_is_vga_mem),
        .vipt_tlb_phys_addr(vipt_tlb_phys_addr), .vipt_tlb_phys_hit_form(vipt_tlb_phys_addr), .vipt_tlb_phys_miss_form(vipt_tlb_phys_addr),
        .vipt_tlb_user(vipt_tlb_user),
        .vipt_tlb_writable(vipt_tlb_writable),
        .ds_flat(ds_flat),
        .ind_linear(ind_linear),
        .ind_linear_valid(ind_linear_valid),
        .issue_ind_linear(issue_ind_linear),
        .issue_ind_linear_low(issue_ind_linear_low),
        .issue_load_linear(issue_load_linear),
        .issue_load_low(issue_load_low),
        .issue_mem_linear(issue_mem_linear),
        .pe(pe),
        .seg_gp_fault(seg_gp_fault),
        .dir_seg_fault(dir_seg_fault),
        .dir_rmw_fault(dir_rmw_fault),
        .ss_segment_fault(ss_segment_fault),
        .ss_flat32(ss_flat32),
        .forwarded_esp(forwarded_esp),
        .mem_wdata(mem_wdata),
        .OPR_R(OPR_R),
        .SIGMA(SIGMA),
        .d2_vipt_ea_hazard(d2_vipt_ea_hazard),
        .vipt_load_ex_token_pending(vipt_load_ex_token_pending),
        .EIP(EIP),
        .hardwired_off(hardwired_off),
        .i_bus(i_bus),
        .i_issue(i_issue),
        .single_step(single_step),
        .any_fault(any_fault),
        .gp_fault_trigger(gp_fault_trigger),
        .i_ex(i_ex),
        .i_first(i_first),
        .i_rni_delay(i_rni_delay),
        .interrupt_entry(interrupt_entry),
        .mem_eff_size(mem_eff_size),
        .mem_is_io(mem_is_io),
        .mem_op_eligible(mem_op_eligible),
        .q_flush(q_flush),
        .stall(stall),
        .stall_invlpg(stall_invlpg),
        .stall_wio(stall_wio),
        .stall_x87_direct(stall_x87_direct),
        .uc_active(uc_active),
        .rmw_fallback_release(rmw_fallback_release),
        .uc_buscode(uc_buscode),
        .uc_busreq(uc_busreq),
        .uc_data_busreq(uc_data_busreq),
        .uc_exec(uc_exec),
        .uc_is_check_write(uc_is_check_write),
        .uc_is_mem_busop(uc_is_mem_busop),
        .uc_is_write(uc_is_write),
        .uc_p_pure_dly(uc_p_pure_dly),
        .x87_direct_mem_req(x87_direct_mem_req),
        .dcache_vipt_probe_offset(),
        .dcache_vipt_probe_valid(),
        .dcache_vipt_resolve_phys_addr(),
        .dcache_vipt_resolve_valid(),
        .fast_store_be(),
        .fast_store_valid(),
        .fast_store_wdata(),
        .rmw_fast_phys_r(),
        .st_phys(),
        .st_route(),
        .st_take(),
        .sidecar_bg_pre(),
        .st_tlb_pre(),
        .ucrd_cpl_r(),
        .ucrd_hit(),
        .ucrd_linear_r(),
        .ucrd_phys_ok_r(),
        .ucrd_phys_r(),
        .ucrd_route_pre(),
        .ucrd_size_r(),
        .ucrd_slow_req_r(),
        .ucrd_slow_submit(),
        .ucrd_x87_r(),
        .vipt_load_slow_r(),
        .vipt_probe_linear(),
        .vipt_slow_addr_owned(),
        .vipt_slow_phys_ok_r(),
        .vipt_slow_phys_r(),
        .vipt_slow_submit(),
        .dir_access_size(),
        .vipt_slow_seg_trigger(),
        .vipt_load_slow_ssf_r(),
        .direct_wb_retire(),
        .fast_opr_commit(),
        .fast_opr_data(),
        .vipt_load_alu_dst_capture(),
        .vipt_load_alu_dst_capture_data(),
        .vipt_load_alu_dst_capture_dst(),
        .vipt_load_alu_dst_capture_size(),
        .vipt_load_wb_alu_op_r(),
        .vipt_load_wb_data(),
        .vipt_load_wb_dst_onehot_r(),
        .vipt_load_wb_dst_r(),
        .vipt_load_wb_is_alu_r(),
        .vipt_load_wb_size_r(),
        .vipt_load_wb_target_r(),
        .vipt_load_wb_valid_r(),
        .d2_plain_load_overlap_ready(),
        .d2_vipt_candidate(),
        .d2_vipt_load(),
        .d2_vipt_pipe_ready(),
        .d2_vipt_pop(),
        .d2_vipt_ret(),
        .d2_vipt_rmw(),
        .d2_vipt_rmw_candidate(),
        .vipt_issue_load(),
        .pop_direct_r(),
        .rd_fast_finish(),
        .rd_fast_valid_r(),
        .ret_redirect(),
        .rmw_fallback_delay_r(),
        .rmw_fast_active_r(),
        .stall_fast_store(),
        .stall_rmw_probe(),
        .stall_ucrd(),
        .vipt_load_ex_probed_r(),
        .vipt_load_ex_r(),
        .vipt_load_exec_block(),
        .vipt_load_replay_r(),
        .vipt_load_slow_busy(),
        .vipt_load_slow_wait_r()
    );

    task automatic launch(input bit pending);
        reset_n = 0;
        i_issue = 0;
        repeat (3) @(negedge clk);
        reset_n = 1;
        i_bus = '0;
        i_bus.opcode = 8'h8b;
        i_bus.has_modrm = 1;
        i_bus.modrm = 8'h00;
        i_bus.operand_size = 2'd2;
        i_bus.dst_reg_sel = 0;
        dcache_vipt_probe_ready = 1;
        dcache_vipt_probe_accepted = 1;
        dcache_vipt_probe_direct_accepted = 1;
        dcache_vipt_resolve_hit = 1;
        dcache_vipt_resolve_data = 32'habcd_1234;
        paging_demand_idle = 1;
        vipt_load_ex_token_pending = pending;
        issue_load_linear = 32'h40;
        ind_linear = 32'h40;
        OPR_R = 32'hdead_beef;
        mem_servicing = 0;
        mem_accepted = 0;
        i_issue = 1;
        @(negedge clk);
        i_issue = 0;
        if (!dut.vipt_load_ex_r.valid)
            $fatal(1, "data_access bench did not launch an EX token");
    endtask

    initial begin
        fork begin repeat (200) @(posedge clk); $fatal(1, "data_access timeout"); end join_none
        launch(0);
        if (!dut.vipt_load_ex_hit) $fatal(1, "control hit did not finalize");
        @(negedge clk);
        if (!dut.vipt_load_wb_valid_r || dut.vipt_load_wb_data != 32'habcd_1234)
            $fatal(1, "control writeback mismatch");

        launch(1);
        mem_servicing = 1;  // the older demand still owns OPR_R
        #1;
        if (dut.vipt_load_ex_hit) $fatal(1, "stale token incorrectly finalized a hit");
        @(negedge clk);
        if (dut.vipt_load_wb_valid_r || !dut.vipt_load_slow_req_r)
            $fatal(1, "stale token did not enter the slow path");
        repeat (2) begin
            if (dut.vipt_slow_submit) $fatal(1, "younger load overtook older demand");
            @(negedge clk);
        end
        OPR_R = 32'h1234_5678; // older demand completes
        mem_servicing = 0;
        #1;
        if (!dut.vipt_slow_submit) $fatal(1, "slow token never submitted");
        mem_accepted = 1;
        @(negedge clk);
        mem_accepted = 0;
        mem_servicing = 1;
        repeat (2) @(negedge clk);
        OPR_R = 32'h5555_aaaa; // younger demand completes
        mem_servicing = 0;
        @(negedge clk);
        if (!dut.vipt_load_wb_valid_r || dut.vipt_load_wb_data != 32'h5555_aaaa)
            $fatal(1, "slow writeback used foreign OPR_R data");
        $display("DATA ACCESS TEST PASS");
        $finish;
    end
endmodule

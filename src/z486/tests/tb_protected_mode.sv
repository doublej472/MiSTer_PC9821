`timescale 1ns/1ns


/* verilator lint_off SYNCASYNCNET */

`include "z486_pc98_preset.svh"

module tb_protected_mode #(
    parameter ENABLE_X87 = 0,
    parameter MEM_SIZE = 1 << 19,
    parameter DCACHE_SET_BITS = 7,
    // Compile the actual PC-98 preset, not a run-time approximation. Used by
    // test-pc98-map to execute/modify code in DIRECT and NO_ALLOC aliases.
    parameter PC98_MAP = 0,
    // Answer a cache-line fill request (burstcount==4 from an L1) with one
    // 16-byte line_resp_valid beat instead of four narrow resp_valid DWORDs.
    // Upstream tied line_din/line_resp_valid low, so the whole-line fill path -
    // and the optimistic-miss (mem_opt_wait) path behind it - had no CPU-level
    // coverage at all.  LINE_FILL=0 restores the narrow-only model for A/B.
    parameter LINE_FILL = 1
);
    // Segment cache array indices (from z486_pkg)
    localparam SEG_ES = 0, SEG_CS = 1, SEG_SS = 2, SEG_DS = 3;
    localparam SEG_FS = 4, SEG_GS = 5, SEG_IDT = 6, SEG_TR = 8, SEG_GDT = 10;
    // Clock and reset
    reg clk = 0;
    always #5 clk <= ~clk;  // 100 MHz clock

    reg reset_n = 0;

    // Test control
    int max_cycles = 10_000_000;
    int cycle = 0;
    bit stop_on_hlt = 1'b1;

    // CPU bus interface (32-bit, ready/valid)
    wire [31:2] addr;       // 4-byte aligned address
    wire [3:0]  be;         // Byte enables
    wire [7:0]  burstcount;
    wire [31:0] dout;       // Data output from CPU
    wire        valid, write, io;
    reg  [31:0] din;        // Data input to CPU
    reg         ready;
    reg         resp_valid;
    // Whole-line fill response (the core asserts line_read for a 4-DWORD L1 read)
    wire        line_read;
    reg         line_resp_valid = 1'b0;
    reg [127:0] line_din = 128'd0;
    bit         line_fill_en = 1'b1;
    reg         intr = 0;
    reg         nmi = 0;
    wire        inta;
    wire        triple_fault_reset;
    wire        bus_lock;
    // Audit: +xdma_snoop pulses the external-invalidate port with the
    // external master's write (a 486 EADS# cycle).
    reg  [31:0] xdma_snoop_addr = 32'h0;
    reg         xdma_snoop_valid = 1'b0;
    bit win0_unmapped = 1'b0;
    initial win0_unmapped = $test$plusargs("win0_unmapped");
    // +cpu_speed=N selects the CPU throttle (0 = full speed): cpu_throttle.sv
    // gates the CPU's clock, and everything on the bus side of the CPU runs on
    // the ungated clk.  clk is 85 MHz for the throttle's purposes (TB_CLOCK_KHZ).
    localparam int TB_CLOCK_KHZ = 85000;
    bit [3:0] cpu_speed_sel = 4'd0;
    initial begin
        int speed;
        if ($value$plusargs("cpu_speed=%d", speed))
            cpu_speed_sel = speed[3:0];
    end
    wire cpu_ce;   // bus_ce: the CPU gets the clock edge that ends this cycle
    wire cclk;     // the CPU's gated clock
    cpu_throttle #(.CLOCK_RATE_KHZ(TB_CLOCK_KHZ)) throttle (
        .clk(clk), .reset_n(reset_n), .speed_sel(cpu_speed_sel), .cpu_ce(cpu_ce));
    cpu_clk_gate cpu_gate (.clk(clk), .ena(cpu_ce), .gclk(cclk));
    initial begin
        #1;
        if (cpu_speed_sel != 0)
            $display("[TB] throttle: speed %0d = %0d kHz of %0d kHz",
                     cpu_speed_sel, throttle.rate_khz(cpu_speed_sel), TB_CLOCK_KHZ);
    end
    wire zw_fire, zw_line_fire;
    wire [127:0] zw_line_data;
    wire [31:0] zw_data;
    // The platform's pulse inputs reach the CPU only on its enabled edges.
    wire resp_valid_h, line_resp_valid_h, snoop_valid_h, resp_stall, line_stall, snoop_stall;
    cpu_pulse_hold hold_resp (.clk(clk), .reset_n(reset_n), .bus_ce(cpu_ce),
        .pulse_i(resp_valid | zw_fire), .pulse_o(resp_valid_h), .stall(resp_stall));
    cpu_pulse_hold hold_line (.clk(clk), .reset_n(reset_n), .bus_ce(cpu_ce),
        .pulse_i(line_resp_valid | zw_line_fire), .pulse_o(line_resp_valid_h), .stall(line_stall));
    cpu_pulse_hold hold_snoop (.clk(clk), .reset_n(reset_n), .bus_ce(cpu_ce),
        .pulse_i(xdma_snoop_valid), .pulse_o(snoop_valid_h), .stall(snoop_stall));
    wire resp_backpressure = resp_stall | line_stall;
    // +signal_delay_scale=N stretches the 0xEC signal delay: a program that
    // places an interrupt N clocks into an instruction sequence needs N times
    // the clocks when the throttle makes every instruction N times longer.
    int signal_delay_scale = 1;
    initial void'($value$plusargs("signal_delay_scale=%d", signal_delay_scale));

    // Instantiate the z486 CPU
    z486 #(
        .ENABLE_X87(ENABLE_X87),
        .DCACHE_SET_BITS(DCACHE_SET_BITS),
        .A20_MASK_OFF(PC98_MAP ? `Z486_PC98_A20_MASK_OFF : 32'hffef_ffff),
        .VGA_ENABLE(PC98_MAP),
        .VGA_PRE_WRAP(!PC98_MAP),
        .APERTURE_ENABLE(PC98_MAP),
        .ALIAS_ENABLE(PC98_MAP),
        .WIN0_ENABLE(PC98_MAP),
        .NO_ALLOC_ENABLE(PC98_MAP),
        .RAM_BOUND_ENABLE(PC98_MAP)
    ) dut (
        .clk(cclk),
        .reset_n(reset_n),
        .addr(addr),
        .be(be),
        .burstcount(burstcount),
        .line_read(line_read),
        .din(zw_fire ? zw_data : din),
        .line_din(zw_line_fire ? zw_line_data : line_din),
        .dout(dout),
        .valid(valid),
        .write(write),
        .io(io),
        .ready(ready),
        .resp_valid(resp_valid_h),
        .line_resp_valid(line_resp_valid_h),
        .intr(intr),
        .nmi(nmi),
        .inta(inta),
        .snoop_addr(xdma_snoop_addr),
        .snoop_valid(snoop_valid_h),
        .cache_flush(cache_flush_platform),
        .cache_flush_busy(cache_flush_busy),
        .cache_flush_done(cache_flush_done),
        .a20_enable(tb_a20),
        .win0_unmapped(win0_unmapped),
        .ram_cache_top(PC98_MAP ? MEM_SIZE : 32'hffff_ffff),
        .fast_off_req(1'b0),
        .cache_off_req(1'b0),
        .x87_off_req(1'b0),
        .single_step(1'b0), // Continuous execution
        .dbg_CS(),
        .dbg_EIP(),
        .dbg_pe(),
        .dbg_vm(),
        .dbg_x87_state(),
        .triple_fault_reset(triple_fault_reset),
        .lock(bus_lock)
    );

`include "m0_profile.svh"

    // The regular tests use 512KB. Snapshot replay overrides this parameter
    // with the captured physical-memory size.
    reg [7:0] mem [0:MEM_SIZE-1];
    // +spec_check (the branch-target buffer oracle, near the end of this file)
    bit          spec_check_en;
    int unsigned spec_checked = 0, spec_skipped = 0;
    initial spec_check_en = $test$plusargs("spec_check");
    // The A20 input, driven by I/O writes (0xF0 = mask, 0xF4 = unmask), and two
    // counts of memory writes by bus address, read back with IN: writes with
    // address bit 21 set (0xD0), and writes with bit 20 set while A20 was
    // masked (0xD4). The memory model wraps at MEM_SIZE, so data alone cannot
    // show which address a masked write was driven to; the bus address can.
    reg        tb_a20 = 1'b1;
    reg [31:0] a20_bit21_writes = 32'd0;
    reg [31:0] a20_masked_bit20_writes = 32'd0;

    // Instrument the feature itself: an ordinary-map binary must not make a
    // PC-98 test green, and a NO_ALLOC fetch must never install a line.
    longint direct_code_writes = 0;
    longint no_alloc_code_fills = 0;
    // LOCK#: memory cycles accepted while it is asserted.
    longint locked_reads = 0;
    longint locked_writes = 0;
    longint locked_inta = 0;
    longint unlocked_inta = 0;
    always @(posedge cclk) begin
        if (reset_n && bus_lock && valid && ready && !io) begin
            if (write) locked_writes <= locked_writes + 1;
            else       locked_reads <= locked_reads + 1;
        end
    end
    initial begin
        if ($test$plusargs("expect_pc98_map") && !PC98_MAP)
            $fatal(1, "PC-98 map test requires -GPC98_MAP=1");
    end
    always @(posedge cclk) begin
        if (reset_n) begin
            if (dut.memory_inst.bus_unit_inst.icache_direct_inval)
                direct_code_writes <= direct_code_writes + 1;
            if (dut.memory_inst.cache_unit_inst.icache_inst.fill_last_beat &&
                dut.memory_inst.cache_unit_inst.icache_inst.state == 3'd3 &&
                dut.memory_inst.cache_unit_inst.icache_inst.req_no_alloc_r)
                no_alloc_code_fills <= no_alloc_code_fills + 1;
            if (dut.memory_inst.cache_unit_inst.icache_inst.req_no_alloc_r &&
                dut.memory_inst.cache_unit_inst.icache_inst.data_fill_write)
                $fatal(1, "NO_ALLOC code installed an I-cache line");
        end
    end

    // Instruction counting
    wire instruction_boundary = dut.uc_is_rni && dut.uc_active;
    // The current instruction ran the HLTS bus cycle (it really halted).
    reg hlt_halted = 1'b0;
    always @(posedge cclk) begin
        if (dut.i_issue && !dut.stall)
            hlt_halted <= 1'b0;
        else if (dut.uc_exec && dut.uc_buscode == 6'h3C)   // BUSOP_HLTS
            hlt_halted <= 1'b1;
    end
    reg prev_instruction_boundary = 0;
    longint instruction_count = 0;
    longint x87_command_count = 0;
    longint x87_direct_load_count = 0;
    longint x87_control_busy_cycles = 0;
    longint x87_executor_busy_cycles = 0;
    longint x87_wait_stall_cycles = 0;
    longint x87_fop_count [0:2047];
    longint x87_direct_load_fop_count [0:2047];
    longint x87_exec_start_count [0:15];
    longint x87_exec_busy_count [0:15];
    longint cpu_entry_count [0:4095];
    longint cpu_entry_cycles [0:4095];
    longint cpu_entry_mem_stall [0:4095];
    longint cpu_entry_x87_stall [0:4095];
    longint cpu_entry_frontend_wait [0:4095];
    longint cpu_opcode_count [0:255];
    longint cpu_opcode_cycles [0:255];
    longint cpu_hardwired_count [0:1];
    longint cpu_hardwired_cycles [0:1];
    longint cpu_commit_count [0:7];
    longint cpu_commit_cycles [0:7];
    longint cpu_stall_cycles [0:9];
    longint cpu_load_chain [0:11];
    longint cpu_load_intervals [0:16];
    longint cpu_load_issue [0:7];
    longint cpu_load_result [0:7];
    longint cpu_load_successor [0:1][0:3];
    longint cpu_load_path_interval [0:2][0:16];
    longint cpu_load_path_successor_count [0:2][0:3];
    longint cpu_load_path_successor_cycles [0:2][0:3];
    longint cpu_load_form_count [0:2][0:1][0:2][0:2][0:3];
    longint cpu_load_form_cycles [0:2][0:1][0:2][0:2][0:3];
    longint cpu_load_next_entry_count [0:2][0:4095];
    longint cpu_load_next_entry_cycles [0:2][0:4095];
    longint cpu_branch_result [0:7];
    longint cpu_rep_elements [0:4];
    longint cpu_x87_wait_reason [0:7];
    longint cpu_store_intervals [0:16];
    longint cpu_store_states [0:9];
    longint cpu_store_next_entry [0:4095];
    longint cpu_store_next_opcode [0:255];
    longint cpu_store_next_entry_gap [0:4095][0:3];
    longint cpu_store_next_opcode_gap [0:255][0:3];
    longint cpu_current_start;
    logic [11:0] cpu_current_entry;
    logic [7:0] cpu_current_opcode;
    logic cpu_current_hardwired;
    logic [2:0] cpu_current_commit;
    logic [7:0] cpu_current_load_dst_mask;
    logic cpu_current_load_direct;
    logic [1:0] cpu_current_load_path;
    logic cpu_current_load_addr32;

    // Prefetch walks spanning a CR3 write; +expect_stale_walk requires one.
    reg         walk_cr3_stale_r_d = 1'b0;
    longint     stale_walk_events = 0;

    always @(posedge cclk) begin
        if (!reset_n) begin
            walk_cr3_stale_r_d <= 1'b0;
            stale_walk_events <= 0;
        end else begin
            walk_cr3_stale_r_d <= dut.paging_inst.walk_cr3_stale_r;
            if (!walk_cr3_stale_r_d && dut.paging_inst.walk_cr3_stale_r &&
                (dut.dbg.mem.pg_state == 4'd10))  // PG_PF_WALKING, via the dbg tap
                stale_walk_events <= stale_walk_events + 1;
        end
    end
    logic [1:0] cpu_current_load_size;
    logic [1:0] cpu_current_load_ea_class;
    logic [1:0] cpu_current_load_alignment;
    logic cpu_profile_active;
    event load_snapshot_x87_state;

    // Snapshot-only CPU profiler. Attribute issue-to-issue time to the older
    // instruction and separately count mutually exclusive pipeline states.
    always @(posedge cclk) begin
        if (reset_n && $test$plusargs("profile_cpu")) begin
            if (cpu_profile_active && (cpu_current_entry == 12'h013)) begin
                if (dut.i_issue)
                    cpu_store_states[0] += 1;
                else if (dut.stall_mem)
                    cpu_store_states[1] += 1;
                else if (dut.stall_wio || dut.stall_x87_direct)
                    cpu_store_states[2] += 1;
                else if (1'b0)
                    cpu_store_states[3] += 1;
                else if (1'b0)
                    cpu_store_states[4] += 1;
                else if (!dut.pb_valid)
                    cpu_store_states[5] += 1;
                else if (!dut.d2_ready)
                    cpu_store_states[6] += 1;
                else if (dut.hardwired_control_inst.recipe_state.slot_has_work)
                    cpu_store_states[7] += 1;
                else if (!dut.uc_active)
                    cpu_store_states[8] += 1;
                else
                    cpu_store_states[9] += 1;
            end

            if (dut.i_issue) begin
                if (cpu_profile_active) begin
                    cpu_entry_cycles[cpu_current_entry] += cycle - cpu_current_start;
                    cpu_opcode_cycles[cpu_current_opcode] += cycle - cpu_current_start;
                    cpu_hardwired_cycles[cpu_current_hardwired] += cycle - cpu_current_start;
                    cpu_commit_cycles[cpu_current_commit] += cycle - cpu_current_start;
                    if (cpu_current_entry == 12'h019) begin
                        automatic logic load_data_dependency;
                        automatic logic load_ea_dependency;
                        automatic int load_dependency;
                        automatic int load_interval;
                        if ((cycle - cpu_current_start) >= 16)
                            cpu_load_intervals[16] += 1;
                        else
                            cpu_load_intervals[cycle - cpu_current_start] += 1;
                        load_interval = (cycle - cpu_current_start) >= 16
                                      ? 16 : cycle - cpu_current_start;
                        load_data_dependency =
                            |(cpu_current_load_dst_mask &
                              dut.i_bus.recipe_gpr_read_mask);
                        load_ea_dependency =
                            |(cpu_current_load_dst_mask &
                              (dut.i_bus.ea_base_onehot |
                               dut.i_bus.ea_index_onehot));
                        cpu_load_successor[cpu_current_load_direct]
                            [{load_ea_dependency, load_data_dependency}] += 1;
                        load_dependency = {load_ea_dependency,
                                           load_data_dependency};
                        cpu_load_path_interval[cpu_current_load_path]
                                              [load_interval] += 1;
                        cpu_load_path_successor_count[cpu_current_load_path]
                                                     [load_dependency] += 1;
                        cpu_load_path_successor_cycles[cpu_current_load_path]
                                                      [load_dependency] +=
                            cycle - cpu_current_start;
                        cpu_load_form_count[cpu_current_load_path]
                            [cpu_current_load_addr32][cpu_current_load_size]
                            [cpu_current_load_ea_class]
                            [cpu_current_load_alignment] += 1;
                        cpu_load_form_cycles[cpu_current_load_path]
                            [cpu_current_load_addr32][cpu_current_load_size]
                            [cpu_current_load_ea_class]
                            [cpu_current_load_alignment] +=
                                cycle - cpu_current_start;
                        cpu_load_next_entry_count[cpu_current_load_path]
                                                 [dut.i_bus.entry_point] += 1;
                        cpu_load_next_entry_cycles[cpu_current_load_path]
                                                  [dut.i_bus.entry_point] +=
                            cycle - cpu_current_start;
                    end
                    if (cpu_current_entry == 12'h013) begin
                        automatic int store_gap;
                        if ((cycle - cpu_current_start) >= 16)
                            cpu_store_intervals[16] += 1;
                        else
                            cpu_store_intervals[cycle - cpu_current_start] += 1;
                        store_gap = (cycle - cpu_current_start) >= 3
                                  ? 3 : cycle - cpu_current_start;
                        cpu_store_next_entry[dut.i_bus.entry_point] += 1;
                        cpu_store_next_opcode[dut.i_bus.opcode] += 1;
                        cpu_store_next_entry_gap[dut.i_bus.entry_point][store_gap] += 1;
                        cpu_store_next_opcode_gap[dut.i_bus.opcode][store_gap] += 1;
                    end
                end
                cpu_current_start = cycle;
                cpu_current_entry = dut.i_bus.entry_point;
                cpu_current_opcode = dut.i_bus.opcode;
                cpu_current_hardwired = dut.d2_recipe.hardwired;
                cpu_current_commit = dut.d2_recipe.commit_sel;
                cpu_current_load_dst_mask =
                    8'h01 << ((dut.i_bus.operand_size == 2'd0)
                            ? {1'b0, dut.i_bus.dst_reg_sel[1:0]}
                            : dut.i_bus.dst_reg_sel);
                cpu_current_load_direct = dut.d2_vipt_load;
                cpu_entry_count[dut.i_bus.entry_point] += 1;
                cpu_opcode_count[dut.i_bus.opcode] += 1;
                cpu_hardwired_count[dut.d2_recipe.hardwired] += 1;
                cpu_commit_count[dut.d2_recipe.commit_sel] += 1;
                cpu_profile_active = 1'b1;

                if (dut.i_bus.entry_point == 12'h019) begin
                    automatic int load_bytes;
                    automatic int load_terms;
                    cpu_load_issue[0] += 1;
                    if (dut.d2_vipt_candidate)
                        cpu_load_issue[1] += 1;
                    if (dut.d2_vipt_load)
                        cpu_load_issue[2] += 1;
                    if (!dut.i_bus.addr32)
                        cpu_load_issue[3] += 1;
                    if (dut.i_bus.ea_complex)
                        cpu_load_issue[4] += 1;
                    if (dut.i_bus.rep_lock != z486_pkg::PREFIX_NOREPLOCK)
                        cpu_load_issue[5] += 1;
                    if (dut.d2_vipt_candidate && !dut.dcache_vipt_probe_ready)
                        cpu_load_issue[6] += 1;
                    if (dut.d2_vipt_candidate && dut.data_access_inst.d2_vipt_older_store)
                        cpu_load_issue[7] += 1;
                    cpu_current_load_path = dut.d2_vipt_load ? 2'd0 :
                        dut.d2_recipe.hardwired ? 2'd1 : 2'd2;
                    cpu_current_load_addr32 = dut.i_bus.addr32;
                    cpu_current_load_size = dut.data_access_inst.d2_vipt_mem_size;
                    load_terms = (|dut.i_bus.ea_base_onehot) +
                                 (|dut.i_bus.ea_index_onehot) +
                                 (dut.i_bus.displacement != 32'd0);
                    cpu_current_load_ea_class = dut.i_bus.ea_complex ? 2'd2 :
                                                (load_terms >= 2) ? 2'd1 : 2'd0;
                    load_bytes = 1 << dut.data_access_inst.d2_vipt_mem_size;
                    if (({1'b0, dut.issue_ind_linear[11:0]} + load_bytes) > 4096)
                        cpu_current_load_alignment = 2'd3;
                    else if (({1'b0, dut.issue_ind_linear[3:0]} + load_bytes) > 16)
                        cpu_current_load_alignment = 2'd2;
                    else if ((dut.issue_ind_linear & (load_bytes - 1)) != 0)
                        cpu_current_load_alignment = 2'd1;
                    else
                        cpu_current_load_alignment = 2'd0;
                end

                if (dut.i_bus.entry_point == 12'h065) begin
                    cpu_branch_result[0] += 1;
                    if (dut.pf_spec_req)
                        cpu_branch_result[1] += 1;
                end
            end

            if (dut.vipt_load_ex_r.valid && dut.vipt_load_ex_probed_r) begin
                cpu_load_result[0] += 1;
                if (dut.data_access_inst.vipt_load_ex_hit)
                    cpu_load_result[1] += 1;
                else if (!dut.data_access_inst.vipt_load_ex_contained)
                    cpu_load_result[2] += 1;
                else if (!dut.data_access_inst.vipt_translation_ok)
                    cpu_load_result[3] += 1;
                else if (dut.vipt_tlb_is_vga_mem)
                    cpu_load_result[4] += 1;
                else if (dut.seg_gp_fault)
                    cpu_load_result[5] += 1;
                else
                    cpu_load_result[6] += 1;
            end
            if (dut.data_access_inst.vipt_load_slow_req_r && dut.mem_accepted)
                cpu_load_result[7] += 1;

            if (dut.jcc_fold_active && dut.uc_exec)
                cpu_branch_result[2] += 1;
            if (dut.branch_ustep_exec) begin
                if (dut.branch_ustep_redirect)
                    cpu_branch_result[3] += 1;
                else
                    cpu_branch_result[4] += 1;
            end
            if (dut.q_flush && dut.pf_spec_owner_r) begin
                if (dut.prefetch_inst.spec_line_match)
                    cpu_branch_result[5] += 1;
                else if (dut.prefetch_inst.spec_data_now)
                    cpu_branch_result[6] += 1;
                else
                    cpu_branch_result[7] += 1;
            end

            // Count completed REP elements at the architectural memory
            // handshake. This is stable across memory latency and DLY holds.
            if (dut.mem_accepted) begin
                if ((cpu_current_entry == 12'h1f8) &&
                    ((dut.uc_addr == 12'h1ff) || (dut.uc_addr == 12'h203)))
                    cpu_rep_elements[0] += 1;
                if ((cpu_current_entry == 12'h218) &&
                    (dut.uc_addr == 12'h222))
                    cpu_rep_elements[1] += 1;
                if ((cpu_current_entry == 12'h235) &&
                    (dut.uc_addr == 12'h23d))
                    cpu_rep_elements[2] += 1;
                if ((cpu_current_entry == 12'h24e) &&
                    (dut.uc_addr == 12'h252))
                    cpu_rep_elements[3] += 1;
                if ((cpu_current_entry == 12'h263) &&
                    (dut.uc_addr == 12'h267))
                    cpu_rep_elements[4] += 1;
            end

            cpu_stall_cycles[0] += dut.stall_mem;
            cpu_stall_cycles[1] += !dut.stall_mem && dut.stall_wio;
            cpu_stall_cycles[2] += !dut.stall_mem && !dut.stall_wio && 1'b0;
            cpu_stall_cycles[3] += !dut.stall_mem && !dut.stall_wio &&
                                   !1'b0 && dut.stall_x87_direct;
            cpu_stall_cycles[4] += !dut.stall && 1'b0;
            cpu_stall_cycles[5] += !dut.stall && !1'b0 &&
                                   !dut.uc_active && dut.decq_empty && !dut.pb_valid;
            cpu_stall_cycles[6] += !dut.stall && !1'b0 &&
                                   !dut.uc_active && !(dut.decq_empty && !dut.pb_valid);
            cpu_stall_cycles[7] += dut.decoder_fetch_blocked;
            cpu_stall_cycles[8] += dut.mem_servicing;
            cpu_stall_cycles[9] += dut.q_flush;
            if (cpu_profile_active) begin
                cpu_entry_mem_stall[cpu_current_entry] += dut.stall_mem;
                cpu_entry_x87_stall[cpu_current_entry] += dut.stall_x87_direct;
                cpu_entry_frontend_wait[cpu_current_entry] +=
                    !dut.stall && !1'b0 && !dut.uc_active;
            end

            // Classify the cycle where a hardwired load can preload and chain its
            // successor. This is intentionally hierarchical: it is snapshot
            // profiling instrumentation, not part of the synthesized core.
            if (dut.hardwired_control_inst.recipe_state.hardwired &&
                (dut.hardwired_control_inst.recipe_state.commit_sel ==
                 z486_pkg::RECIPE_COMMIT_MEM) &&
                dut.hardwired_control_inst.uc_exec && dut.hardwired_control_inst.uc_next_rni &&
                !dut.hardwired_control_inst.i_issue) begin
                cpu_load_chain[0] += 1;
                if (dut.hardwired_control_inst.pb_issue)
                    cpu_load_chain[1] += 1;
                else if (dut.hardwired_control_inst.decq_empty)
                    cpu_load_chain[2] += 1;
                else if (!dut.hardwired_control_inst.d2_push)
                    cpu_load_chain[3] += 1;
                else if (!dut.hardwired_control_inst.issue_recipe.hardwired)
                    cpu_load_chain[4] += 1;
                else if (dut.hardwired_control_inst.issue_recipe.reads_flags &&
                         dut.hardwired_control_inst.recipe_state.writes_flags &&
                         !dut.hardwired_control_inst.issue_recipe.jcc)
                    cpu_load_chain[5] += 1;
                else if (dut.hardwired_control_inst.issue_recipe.uses_ea &&
                         dut.hardwired_control_inst.ea2_conflict)
                    cpu_load_chain[6] += 1;
                else if (dut.hardwired_control_inst.loaduse_conflict)
                    cpu_load_chain[7] += 1;
                else if (dut.hardwired_control_inst.mem_confN)
                    cpu_load_chain[8] += 1;
                else if (dut.hardwired_control_inst.shift_confN)
                    cpu_load_chain[9] += 1;
                else if (!dut.hardwired_control_inst.head_issue_safe)
                    cpu_load_chain[10] += 1;
                else
                    cpu_load_chain[11] += 1;
            end
        end
    end

    generate
    if (ENABLE_X87) begin : gen_snapshot_x87_counters
        logic x87_event_window_active = 1'b0;
        longint x87_event_window_start = 0;
        logic [10:0] x87_event_window_fop = 11'h0;
        logic [11:0] x87_event_window_entry = 12'h0;
        longint x87_event_window_mem = 0;
        longint x87_event_window_port = 0;
        longint x87_event_window_guest_mem = 0;
        longint x87_event_window_wio = 0;
        longint x87_event_window_direct = 0;
        longint x87_event_window_frontend = 0;

        always @(posedge cclk) begin
            if (reset_n) begin
                if ($test$plusargs("profile_x87_events")) begin
                    if (dut.i_issue) begin
                        if (x87_event_window_active)
                            $display("X87_EVENT WINDOW %0d %0d %0d %03x %03x %0d %0d %0d %0d %0d %0d",
                                     x87_event_window_start, cycle,
                                     cycle - x87_event_window_start,
                                     x87_event_window_fop,
                                     x87_event_window_entry,
                                     x87_event_window_mem,
                                     x87_event_window_port,
                                     x87_event_window_guest_mem,
                                     x87_event_window_wio,
                                     x87_event_window_direct,
                                     x87_event_window_frontend);
                        x87_event_window_active =
                            (dut.i_bus.opcode >= 8'hd8) &&
                            (dut.i_bus.opcode <= 8'hdf);
                        x87_event_window_start = cycle;
                        x87_event_window_fop = dut.i_bus.fop;
                        x87_event_window_entry = dut.i_bus.entry_point;
                        x87_event_window_mem = 0;
                        x87_event_window_port = 0;
                        x87_event_window_guest_mem = 0;
                        x87_event_window_wio = 0;
                        x87_event_window_direct = 0;
                        x87_event_window_frontend = 0;
                        if (x87_event_window_active)
                            $display("X87_EVENT ISSUE %0d %0d %02x %03x %03x %04x %0d",
                                     cycle, instruction_count,
                                     dut.i_bus.opcode, dut.i_bus.fop,
                                     dut.i_bus.entry_point,
                                     dut.x87.gen_x87.control.control_word,
                                     dut.x87.gen_x87.control.top);
                    end else if (x87_event_window_active) begin
                        x87_event_window_mem += dut.stall_mem;
                        x87_event_window_port +=
                            dut.stall_mem &&
                            ((dut.x87.gen_x87.bridge.state != 0) ||
                             dut.dcache_req_is_x87);
                        x87_event_window_guest_mem +=
                            dut.stall_mem &&
                            (dut.x87.gen_x87.bridge.state == 0) &&
                            !dut.dcache_req_is_x87;
                        x87_event_window_wio += dut.stall_wio;
                        x87_event_window_direct += dut.stall_x87_direct;
                        x87_event_window_frontend +=
                            !dut.stall && !1'b0 &&
                            !dut.uc_active;
                    end
                    if (dut.x87.gen_x87.cmd_valid &&
                        dut.x87.gen_x87.cmd_ready)
                        $display("X87_EVENT ACCEPT %0d protocol %03x",
                                 cycle, dut.x87.gen_x87.cmd_fop);
                    if (dut.x87.direct_valid && dut.x87.direct_ready)
                        $display("X87_EVENT ACCEPT %0d direct %03x",
                                 cycle, dut.i.fop);
                    if (dut.x87.gen_x87.control.v2_exec_start)
                        $display("X87_EVENT EXEC_START %0d %0d %0d %03x %0d %0d %0d",
                                 cycle,
                                 dut.x87.gen_x87.control.v2_exec_op,
                                 dut.x87.gen_x87.control.v2_exec_owner,
                                 dut.x87.gen_x87.control.last_fop,
                                 dut.x87.gen_x87.control.top,
                                 dut.x87.gen_x87.control.arith_dest_index,
                                 dut.x87.gen_x87.control.control_word[9:8]);
                    if (dut.x87.gen_x87.control.v2_exec_done)
                        $display("X87_EVENT EXEC_DONE %0d %0d %0d %03x",
                                 cycle,
                                 dut.x87.gen_x87.control.v2_exec_op,
                                 dut.x87.gen_x87.control.v2_exec_owner,
                                 dut.x87.gen_x87.control.last_fop);
                end
                if (dut.x87.gen_x87.cmd_valid && dut.x87.gen_x87.cmd_ready) begin
                    x87_command_count <= x87_command_count + 1;
                    x87_fop_count[dut.x87.gen_x87.cmd_fop] <=
                        x87_fop_count[dut.x87.gen_x87.cmd_fop] + 1;
                end
                if (dut.x87.direct_valid && dut.x87.direct_ready) begin
                    x87_direct_load_count <= x87_direct_load_count + 1;
                    x87_direct_load_fop_count[dut.i.fop] <=
                        x87_direct_load_fop_count[dut.i.fop] + 1;
                end
                if (!dut.x87_busy_n)
                    x87_control_busy_cycles <= x87_control_busy_cycles + 1;
                if (dut.x87.gen_x87.control.executor.busy)
                    x87_executor_busy_cycles <= x87_executor_busy_cycles + 1;
                if (dut.x87.gen_x87.control.v2_exec_start)
                    x87_exec_start_count[dut.x87.gen_x87.control.v2_exec_op] <=
                        x87_exec_start_count[dut.x87.gen_x87.control.v2_exec_op] + 1;
                if (dut.x87.gen_x87.control.executor.busy)
                    x87_exec_busy_count[dut.x87.gen_x87.control.v2_exec_op] <=
                        x87_exec_busy_count[dut.x87.gen_x87.control.v2_exec_op] + 1;
                if (dut.stall_wio)
                    x87_wait_stall_cycles <= x87_wait_stall_cycles + 1;
                if ($test$plusargs("profile_cpu")) begin
                    if (dut.stall_x87_direct) begin
                        cpu_x87_wait_reason[0] += 1;
                        if (!dut.x87.direct_issued_r)
                            cpu_x87_wait_reason[1] += 1;
                        else if (!dut.x87.direct_data_valid_r)
                            cpu_x87_wait_reason[2] += 1;
                        else if (!dut.x87.direct_ready)
                            cpu_x87_wait_reason[3] += 1;
                    end
                    if (dut.stall_wio) begin
                        cpu_x87_wait_reason[4] += 1;
                        if (!dut.x87_busy_n)
                            cpu_x87_wait_reason[5] += 1;
                        if (dut.x87.gen_x87.control.executor.busy)
                            cpu_x87_wait_reason[6] += 1;
                        if (dut.x87.gen_x87.control.direct_m32_pending)
                            cpu_x87_wait_reason[7] += 1;
                    end
                end
            end
        end
    end
    endgenerate

    generate
    if (ENABLE_X87) begin : gen_snapshot_x87_init
        always @(load_snapshot_x87_state) begin
            dut.x87.gen_x87.control.control_word = x87_control_arg;
            dut.x87.gen_x87.control.status_flags = x87_status_arg;
            dut.x87.gen_x87.control.top = x87_top_arg;
            dut.x87.gen_x87.control.tag_word = x87_tag_arg;
            dut.x87.gen_x87.control.stack_mem.mem[0] = x87_fpr_arg[0];
            dut.x87.gen_x87.control.stack_mem.mem[1] = x87_fpr_arg[1];
            dut.x87.gen_x87.control.stack_mem.mem[2] = x87_fpr_arg[2];
            dut.x87.gen_x87.control.stack_mem.mem[3] = x87_fpr_arg[3];
            dut.x87.gen_x87.control.stack_mem.mem[4] = x87_fpr_arg[4];
            dut.x87.gen_x87.control.stack_mem.mem[5] = x87_fpr_arg[5];
            dut.x87.gen_x87.control.stack_mem.mem[6] = x87_fpr_arg[6];
            dut.x87.gen_x87.control.stack_mem.mem[7] = x87_fpr_arg[7];
        end
    end
    endgenerate

    // The 386-gate path clears the gate-width flag before common stack setup.
    reg cmisc2_executed = 1'b0;
    always @(posedge cclk) begin
        if (!reset_n) begin
            cmisc2_executed <= 1'b0;
        end else begin
            if (cmisc2_executed && dut.misc2_flag)
                $fatal(1, "CMISC2 failed to clear misc2_flag");
            cmisc2_executed <= dut.uc_exec && (dut.uc_aluop == 7'h3C);
        end
    end

    // Test result tracking
    reg [7:0] test_status = 8'h00;  // 0x00=running, 0x01=pass, 0xFF=fail
    reg [31:0] test_data = 32'h0;
    reg test_done = 0;
    longint vipt_ea_interlock_cycles = 0;
    longint vipt_store_wait_issues = 0;
    longint vipt_store_replays = 0;
    reg vipt_store_replay_pending = 0;
    // Stores posted through the direct store port (data_access st_take), and
    // the share of them while paging was off.
    longint posted_stores = 0;
    longint posted_stores_unpaged = 0;
    always @(posedge cclk)
        if (reset_n && dut.st_take) begin
            posted_stores <= posted_stores + 1;
            if (!dut.CR0[31])
                posted_stores_unpaged <= posted_stores_unpaged + 1;
        end

    // A load-to-AGI regression must both exercise the dependency and prevent
    // the dependent instruction from issuing while its EA input is pending.
    always @(posedge cclk) begin
        if (reset_n && dut.d2_vipt_ea_hazard)
            vipt_ea_interlock_cycles <= vipt_ea_interlock_cycles + 1;
        if (reset_n && dut.i_issue && dut.d2_vipt_ea_hazard)
            $fatal(1, "VIPT load-to-EA consumer issued before writeback");
        if (!reset_n || dut.q_flush || dut.any_fault) begin
            vipt_store_replay_pending <= 1'b0;
        end else if (dut.data_access_inst.vipt_issue_store_wait) begin
            vipt_store_wait_issues <= vipt_store_wait_issues + 1;
            vipt_store_replay_pending <= 1'b1;
        end else if (vipt_store_replay_pending && dut.data_access_inst.vipt_replay_try &&
                     dut.dcache_vipt_probe_accepted) begin
            vipt_store_replays <= vipt_store_replays + 1;
            vipt_store_replay_pending <= 1'b0;
        end
    end

    // Hardware interrupt emulation
    reg [7:0] intr_vector = 8'h20;     // Vector to return on INTA
    int unsigned fuzz_irq_period = 0;  // +fuzz_irq_period=N: random INTR
    initial void'($value$plusargs("fuzz_irq_period=%d", fuzz_irq_period));
    reg       intr_request = 0;        // Pending INTR request from signal port
    reg       nmi_request = 0;         // Pending NMI request from signal port
    int       intr_delay = 0;          // Cycles to delay before asserting intr/nmi
    int       signal_delay_cycles = 50;// Configurable cycle delay for signal trigger
    int       signal_delay_instr = 0;  // Optional retired-instruction delay for trigger
    int       intr_instr_remaining = 0;
    int       nmi_instr_remaining = 0;
    reg       intr_hardwired_load_arm = 0;
    int       nmi_pulse_cycles = 1;    // NMI high width in cycles (for deterministic edge delivery)
    int       nmi_hold_count = 0;
    reg       inta_first = 0;          // Track first vs second INTA pair
    // A PIC whose INTR goes low at the acknowledge and comes back almost at once:
    // the 8259 drops INT when the acked IRQ enters service and raises it again
    // as soon as a request of higher priority than the in-service one arrives,
    // which can be any number of clocks later - including fewer than one CPU
    // clock period when the CPU is throttled (the gated clock skips the edges
    // in between), or none at all.  +intr_rerequest=N makes the next N second
    // INTA cycles drop INTR for only +intr_regap=G platform cycles (G=0: INTR
    // stays asserted through the acknowledge) and then raise it again; a 486
    // samples INTR as a level at every instruction boundary, so each of those
    // requests must be acknowledged in its turn.
    int unsigned intr_rerequest = 0;
    int unsigned intr_regap = 0;
    int unsigned intr_regap_count = 0;
    // +intr_drop_delay=D: a slow PIC - INTR stays asserted for D platform
    // cycles after the second INTA before it drops (the stale level of the
    // request just acknowledged, which must not be taken a second time).
    int unsigned intr_drop_delay = 0;
    int unsigned intr_drop_count = 0;
    initial begin
        void'($value$plusargs("intr_drop_delay=%d", intr_drop_delay));
        void'($value$plusargs("intr_rerequest=%d", intr_rerequest));
        void'($value$plusargs("intr_regap=%d", intr_regap));
    end
    reg       inta_resp_pending = 0;
    reg [31:0] inta_resp_data = 32'h0;

    // Configurable memory latency (default 1 cycle, +mem_latency=N for more)
    int mem_latency = 1;
    int rd_wait_count = 0;
    reg [31:0] rd_byte_addr = 32'h0;
    reg [7:0] rd_remaining = 8'd0;
    reg [7:0] rd_index = 8'd0;
    reg rd_io_pending = 1'b0;
    // Whole-line fill: one pending 16-byte beat, held off by mem_latency.
    int  line_wait_count = 0;
    reg [31:0] line_byte_addr = 32'h0;
    wire line_pending = (line_wait_count != 0);
    // A line response and a narrow burst never overlap: rd_busy blocks a new
    // request until the pending beat has been delivered.
    wire rd_busy = (rd_wait_count != 0) || (rd_remaining != 0) ||
                   inta_resp_pending || line_pending;

    // Platform cache-flush and DMA model (PC-98 IOBus analog).
    //   0xC0: write requests the native whole-L1 flush (cache_flush) and the
    //         testbench reports the request-to-done latency; a read returns
    //         bit0 = 1 once the last requested flush has completed.
    //   0xC4: write latches the physical address of an external write.
    //   0xC8: write performs that external write directly into the RAM model,
    //         behind the caches and with NO snoop: the CPU must not observe it
    //         until a cache flush.
    //   0xCC: write N schedules an asynchronous platform flush N cycles later
    //         (as a DMA terminal count would raise it, independent of the
    //         program) and holds the external bus not-ready from the write
    //         for +async_stall=W cycles (default 60), so the flush's drain of
    //         the posted stores lasts a while.
    reg         cache_flush_req = 1'b0;
    int         async_flush_in = 0;
    int         async_stall = 0;
    int         async_stall_len = 60;
    initial void'($value$plusargs("async_stall=%d", async_stall_len));
    wire        cache_flush_busy;
    wire        cache_flush_done;
    reg  [31:0] dma_poke_addr = 32'h0;
    longint     platform_flushes = 0;
    longint     platform_flush_cycles = 0;
    longint     platform_flush_start = 0;
    longint     platform_dma_pokes = 0;
    reg         flush_complete = 1'b0;
    // +zero_wait: a single-beat (non-line) demand read is answered in the SAME
    // cycle valid rises: ready (already high) and the data beat both arrive on
    // the CPU edge that accepts the request.  z486's bus contract allows this
    // (tb_mem_resp MODE_SAME); the default model only answers a cycle later.
    bit zero_wait_en = 1'b0;
    initial zero_wait_en = $test$plusargs("zero_wait");
    wire zw_ok = zero_wait_en && reset_n && valid && ready && cpu_ce && !write &&
                 !inta && !rd_busy && !resp_backpressure && (async_stall <= 1);
    assign zw_line_fire = zw_ok && !io && LINE_FILL && line_fill_en && line_read;
    // Narrow reads: the first beat (the only one of a single-beat read) is
    // answered in the accept cycle; any further beats follow as usual.
    assign zw_fire = zw_ok && !zw_line_fire;
    reg [127:0] zw_line_r;
    assign zw_line_data = zw_line_r;
    always_comb begin
        reg [31:0] lb;
        lb = {addr, 2'b00};
        if (lb >= MEM_SIZE) lb = lb & (MEM_SIZE - 1);
        for (int i = 0; i < 16; i++)
            zw_line_r[i*8 +: 8] = mem[(lb + i) & (MEM_SIZE - 1)];
    end
    reg [31:0] zw_data_r;
    assign zw_data = zw_data_r;
    always_comb begin
        reg [31:0] a;
        a = {addr, 2'b00};
        if (io)
            zw_data_r = (a[15:0] == 16'h00FC) ? cycle :
                      (a[15:0] == 16'h00C0) ? {31'h0, flush_complete} :
                      (a[15:0] == 16'h00D0) ? a20_bit21_writes :
                      (a[15:0] == 16'h00D4) ? a20_masked_bit20_writes :
                      32'hFFFFFFFF;
        else begin
            if (a >= MEM_SIZE) a = a & (MEM_SIZE - 1);
            zw_data_r = {mem[a+3], mem[a+2], mem[a+1], mem[a+0]};
        end
    end

    // Count the issued native-flush instruction words (the INVD/WBINVD entry).
    longint     cache_flush_insn_count = 0;
    always @(posedge cclk)
        if (reset_n && dut.uc_active && (dut.uc_addr == z486_pkg::UADDR_INVD))
            cache_flush_insn_count <= cache_flush_insn_count + 1;

    // Latency from the flush going busy to done, which covers the posted-store
    // drain plus both set walks.  cache_flush_busy rises for the platform
    // input and for INVD/WBINVD alike.
    reg         cache_flush_busy_r = 1'b0;
    always @(posedge cclk) begin
        if (reset_n) begin
            cache_flush_busy_r <= cache_flush_busy;
            if (cache_flush_busy && !cache_flush_busy_r)
                platform_flush_start <= cycle;
            if (cache_flush_req)
                flush_complete <= 1'b0;
            if (cache_flush_done) begin
                platform_flushes <= platform_flushes + 1;
                if (platform_flush_start != 0)
                    platform_flush_cycles <= cycle - platform_flush_start;
                flush_complete <= 1'b1;
            end
        end
    end

    // ---- Optional platform flush stress ------------------------------------
    // +cache_flush_stress drives the platform cache_flush input autonomously as
    // repeated requests held for a long, LFSR-randomized window with randomized
    // release gaps.  A held request spans its own done, so an INVD/WBINVD can
    // begin in the window after a platform done while the platform level is
    // still high.  A held request only needs to be released once to re-arm, so
    // a dropped instruction request would stall the CPU on cache_flush_done and
    // the run would time out.
    localparam [15:0] FLUSH_STRESS_HOLD = 16'd700;
    reg        flush_stress_en = 1'b0;
    reg        flush_stress_level = 1'b0;
    reg [15:0] flush_stress_timer = 16'd0;
    reg [15:0] flush_stress_lfsr = 16'hC0DE;
    longint    flush_overlap_cycles = 0;

    initial flush_stress_en = $test$plusargs("cache_flush_stress");

    wire cache_flush_platform = flush_stress_en ? flush_stress_level : cache_flush_req;

    always @(posedge cclk) begin
        if (!reset_n) begin
            flush_stress_level <= 1'b0;
            flush_stress_timer <= 16'd0;
            flush_stress_lfsr <= 16'hC0DE;
        end else if (flush_stress_en) begin
            flush_stress_lfsr <= {flush_stress_lfsr[14:0],
                                  flush_stress_lfsr[15] ^ flush_stress_lfsr[13] ^
                                  flush_stress_lfsr[12] ^ flush_stress_lfsr[10]};
            if (flush_stress_timer == 16'd0) begin
                flush_stress_level <= ~flush_stress_level;
                // Going high: hold long.  Going low: a short randomized gap.
                flush_stress_timer <= flush_stress_level
                    ? ({10'd0, flush_stress_lfsr[5:0]} + 16'd1)
                    : FLUSH_STRESS_HOLD;
            end else begin
                flush_stress_timer <= flush_stress_timer - 16'd1;
            end
        end
    end

    // Cycles in which a held platform request overlaps the INVD/WBINVD routine;
    // +expect_flush_overlap requires at least one, so the test cannot pass
    // without actually creating the overlap it is meant to cover.
    always @(posedge cclk)
        if (reset_n && flush_stress_en && cache_flush_platform &&
            dut.uc_active && (dut.uc_addr == z486_pkg::UADDR_INVD))
            flush_overlap_cycles <= flush_overlap_cycles + 1;

    // ---- Audit: lock-honouring external bus master (DMA-like) -------------
    // +xdma_trig=<hex> arms on the +xdma_trig_n=<n>'th (default 1) memory read
    // accepted at that dword address; +xdma_delay=<n> cycles later, once no
    // read is outstanding and (unless +xdma_ignore_lock) LOCK# is low, it
    // writes +xdma_data=<hex> under +xdma_be=<hex> to +xdma_addr=<hex> straight
    // into RAM (no snoop), as a DMA write between two CPU cycles would.
    bit         xdma_en = 1'b0;
    bit         xdma_ignore_lock = 1'b0;
    reg  [31:0] xdma_trig = 32'h0, xdma_addr = 32'h0, xdma_data = 32'h0;
    reg  [31:0] xdma_be_arg = 32'hF;
    int         xdma_trig_n = 1, xdma_delay = 0, xdma_seen = 0;
    bit         xdma_armed = 1'b0, xdma_done = 1'b0;
    int         xdma_arm_cycle = 0;
    longint     xdma_lock_wait = 0;
    initial begin
        xdma_en = $value$plusargs("xdma_trig=%h", xdma_trig);
        void'($value$plusargs("xdma_addr=%h", xdma_addr));
        void'($value$plusargs("xdma_data=%h", xdma_data));
        void'($value$plusargs("xdma_be=%h", xdma_be_arg));
        void'($value$plusargs("xdma_trig_n=%d", xdma_trig_n));
        void'($value$plusargs("xdma_delay=%d", xdma_delay));
        xdma_ignore_lock = $test$plusargs("xdma_ignore_lock");
    end
    // +count_rd=<hex>/+expect_rd_count=<n>: memory reads accepted on the bus at
    // that dword address must number exactly n (one per RMW on a 486).
    reg  [31:0] count_rd_addr = 32'h0;
    bit         count_rd_en = 1'b0;
    int         expect_rd_count = -1;
    longint     rd_count_seen = 0;
    initial begin
        count_rd_en = $value$plusargs("count_rd=%h", count_rd_addr);
        void'($value$plusargs("expect_rd_count=%d", expect_rd_count));
    end
    always @(posedge cclk)
        if (reset_n && count_rd_en && valid && ready && !rd_busy && !write && !io &&
            ({addr, 2'b00} == {count_rd_addr[31:2], 2'b00}))
            rd_count_seen <= rd_count_seen + 1;
    // +watch_lo=<hex>/+watch_hi=<hex>/+expect_watch_reads=<n>: bus memory reads
    // whose byte range overlaps [lo, hi] (inclusive) must number exactly n. A
    // read is a single-beat read, a burst of burstcount DWORDs or a 16-byte
    // line fill. Stores and I/O are not counted.
    reg  [31:0] watch_lo = 32'h0, watch_hi = 32'h0;
    bit         watch_en = 1'b0;
    int         expect_watch_reads = -1;
    longint     watch_seen = 0;
    reg  [31:0] watch_first = 32'h0;
    initial begin
        watch_en = $value$plusargs("watch_lo=%h", watch_lo) &&
                   $value$plusargs("watch_hi=%h", watch_hi);
        void'($value$plusargs("expect_watch_reads=%d", expect_watch_reads));
    end
    wire [31:0] watch_rd_base = {addr, 2'b00};
    wire [31:0] watch_rd_len  = (LINE_FILL && line_fill_en && line_read) ? 32'd16
                                                                         : {22'd0, burstcount, 2'b00};
    always @(posedge clk)
        if (reset_n && watch_en && valid && ready && !rd_busy && !write && !io &&
            (watch_rd_base <= watch_hi) &&
            ((watch_rd_base + watch_rd_len - 32'd1) >= watch_lo)) begin
            if (watch_seen == 0) watch_first <= watch_rd_base;
            watch_seen <= watch_seen + 1;
        end
    // +max_lock_run=<n>: fail a PASS if LOCK# was ever held for more than n
    // consecutive cycles (an over-long lock holds every other master off).
    int         max_lock_run = 0;
    int         lock_run = 0, lock_run_max = 0;
    initial void'($value$plusargs("max_lock_run=%d", max_lock_run));
    always @(posedge cclk) if (reset_n) begin
        lock_run <= bus_lock ? lock_run + 1 : 0;
        if (bus_lock && (lock_run + 1 > lock_run_max)) lock_run_max <= lock_run + 1;
    end
    // +trace_lock: every LOCK# edge and every bus cycle accepted while high.
    reg bus_lock_q = 1'b0;
    always @(posedge cclk) if (reset_n && $test$plusargs("trace_lock")) begin
        bus_lock_q <= bus_lock;
        if (bus_lock != bus_lock_q)
            $display("LOCK# %0d @cycle %0d eip=%08x uc=%03h", bus_lock, cycle, dut.EIP, dut.uc_addr);
        if (dut.dcache_req_valid && dut.dcache_req_accepted)
            $display("DREQ %s @%08x locked=%0d uc=%03h cycle=%0d", dut.dcache_req_write ? "WR" : "RD",
                     dut.dcache_req_phys_addr_raw, dut.dcache_req_is_locked, dut.uc_addr, cycle);
        if (valid && ready && !rd_busy)
            $display("BUS %s%s @%08x be=%b lock=%0d cycle=%0d", io ? "IO" : "MEM",
                     write ? "WR" : "RD", {addr, 2'b00}, be, bus_lock, cycle);
    end

    // Memory behavior with configurable latency (ready/valid protocol)
    // Note: din is held stable (not cleared) to allow paging unit to sample it
    // when pg_mem_ready is asserted (which has 1-cycle delay from bus ready)
    always @(posedge clk) begin
        // A platform flush request is a one-cycle pulse; the 0xC0 write handler
        // below re-asserts this assignment for the request cycle, and the cache
        // unit latches it internally for the walk.
        // (held until the CPU's next enabled edge, where it samples the level)
        if (cpu_ce) cache_flush_req <= 1'b0;
        xdma_snoop_valid <= 1'b0;
        if (async_flush_in > 1)
            async_flush_in <= async_flush_in - 1;
        else if (async_flush_in == 1) begin
            async_flush_in <= 0;
            cache_flush_req <= 1'b1;
            if ($test$plusargs("trace_io"))
                $display("PLATFORM: asynchronous cache flush requested, bus stall remaining %0d",
                         async_stall);
        end
        if (async_stall > 0)
            async_stall <= async_stall - 1;
        if (intr_drop_count > 0) begin
            intr_drop_count <= intr_drop_count - 1;
            if (intr_drop_count == 1)
                intr <= 1'b0;
        end
        if (intr_regap_count > 0) begin
            intr_regap_count <= intr_regap_count - 1;
            if (intr_regap_count == 1)
                intr <= 1'b1;
        end
        if (xdma_en && reset_n && !xdma_done) begin
            if (!xdma_armed && valid && ready && !rd_busy && cpu_ce && !write && !io && !inta &&
                ({addr, 2'b00} == {xdma_trig[31:2], 2'b00})) begin
                xdma_seen <= xdma_seen + 1;
                if (xdma_seen + 1 == xdma_trig_n) begin
                    xdma_armed <= 1'b1;
                    xdma_arm_cycle <= cycle;
                end
            end
            if (xdma_armed && !rd_busy && (cycle - xdma_arm_cycle) > xdma_delay) begin
                if (bus_lock && !xdma_ignore_lock) begin
                    xdma_lock_wait <= xdma_lock_wait + 1;
                end else begin
                    if (xdma_be_arg[0]) mem[xdma_addr+0] <= xdma_data[7:0];
                    if (xdma_be_arg[1]) mem[xdma_addr+1] <= xdma_data[15:8];
                    if (xdma_be_arg[2]) mem[xdma_addr+2] <= xdma_data[23:16];
                    if (xdma_be_arg[3]) mem[xdma_addr+3] <= xdma_data[31:24];
                    xdma_done <= 1'b1;
                    if ($test$plusargs("xdma_snoop")) begin
                        xdma_snoop_addr <= xdma_addr;
                        xdma_snoop_valid <= 1'b1;
                    end
                    $display("XDMA write @%08x be=%x data=%08x cycle=%0d (armed %0d, waited %0d locked cycles, lock=%0d)",
                             xdma_addr, xdma_be_arg[3:0], xdma_data, cycle, xdma_arm_cycle,
                             xdma_lock_wait, bus_lock);
                end
            end
        end
        if (ENABLE_X87 && reset_n && valid && io &&
            (dut.i.opcode >= 8'hd8) && (dut.i.opcode <= 8'hdf))
            $fatal(1, "x87 transaction escaped to external I/O: addr=%08x write=%b",
                   {addr, 2'b00}, write);

        ready <= !rd_busy && (async_stall <= 1);
        resp_valid <= 1'b0;
        line_resp_valid <= 1'b0;
        // Don't clear din - hold it stable for page walker timing

        // Pending whole-line fill: one 16-byte beat, then done.  The core's
        // S_FILL captures line_din on this pulse and installs all four words.
        if (resp_backpressure) begin
            // A response is waiting for the CPU's next enabled edge: present
            // nothing new until it is consumed (cpu_pulse_hold's contract).
        end else if (line_pending) begin
            if (line_wait_count == 1) begin
                reg [127:0] lv;
                reg [31:0]  lbase;
                lbase = line_byte_addr;
                if (lbase >= MEM_SIZE) lbase = lbase & (MEM_SIZE - 1);
                for (int i = 0; i < 16; i++)
                    lv[i*8 +: 8] = mem[(lbase + i) & (MEM_SIZE - 1)];
                line_din        <= lv;
                line_resp_valid <= 1'b1;
                line_wait_count <= 0;
                if ($test$plusargs("trace_mem"))
                    $display("MEM LINE RESP @%08x = %032x", line_byte_addr, lv);
            end else begin
                line_wait_count <= line_wait_count - 1;
            end
        end else if (inta_resp_pending) begin
            // Narrow path: latency countdown, then one DWORD per cycle.
            resp_valid <= 1'b1;
            din <= inta_resp_data;
            inta_resp_pending <= 1'b0;
        end else if (rd_wait_count != 0) begin
            rd_wait_count <= rd_wait_count - 1;
        end else if (rd_remaining != 8'd0) begin
            reg [31:0] byte_addr;
            byte_addr = rd_byte_addr + {22'd0, rd_index, 2'b00};
            if (byte_addr >= MEM_SIZE)
                byte_addr = byte_addr & (MEM_SIZE - 1);

            resp_valid <= 1'b1;
            if (rd_io_pending) begin
                din <= (rd_byte_addr[15:0] == 16'h00FC) ? cycle :
                       (rd_byte_addr[15:0] == 16'h00D0) ? a20_bit21_writes :
                       (rd_byte_addr[15:0] == 16'h00D4) ? a20_masked_bit20_writes :
                       32'hFFFFFFFF;
            end else begin
                din <= {mem[byte_addr+3], mem[byte_addr+2],
                        mem[byte_addr+1], mem[byte_addr+0]};

                if ($test$plusargs("trace_mem"))
                    $display("MEM RESP @%08x = %08x",
                             byte_addr,
                             {mem[byte_addr+3], mem[byte_addr+2],
                              mem[byte_addr+1], mem[byte_addr+0]});
            end

            rd_index <= rd_index + 8'd1;
            rd_remaining <= rd_remaining - 8'd1;
        end

        if (valid && ready && !rd_busy && cpu_ce) begin
            // Coprocessor cycles use reserved 32-bit I/O addresses. The normal
            // I/O trace intentionally truncates to programmed 16-bit ports,
            // which would alias these transactions with test-control ports.
            if ($test$plusargs("trace_x87") && io && addr[31]) begin
                if (write)
                    $display("X87 REQ eip=%08x uc=%03h addr=%08x WR be=%x data=%08x",
                             dut.EIP, dut.uc_addr, {addr, 2'b00}, be, dout);
                else
                    $display("X87 REQ eip=%08x uc=%03h addr=%08x RD be=%x data=ffffffff",
                             dut.EIP, dut.uc_addr, {addr, 2'b00}, be);
            end

            if (inta) begin
                // INTA bus cycle handling.  Both cycles of the pair are locked.
                if (bus_lock) locked_inta <= locked_inta + 1;
                else          unlocked_inta <= unlocked_inta + 1;
                ready <= 1'b0;
                inta_resp_pending <= 1'b1;
                if (!inta_first) begin
                    inta_first <= 1'b1;
                    inta_resp_data <= 32'h0;
                    if ($test$plusargs("trace_io"))
                        $display("INTA cycle 1 (dummy)");
                end else begin
                    inta_first <= 1'b0;
                    inta_resp_data <= {24'h0, intr_vector};
                    if (intr_rerequest > 0) begin
                        intr_rerequest <= intr_rerequest - 1;
                        if (intr_regap > 0) begin
                            intr <= 1'b0;
                            intr_regap_count <= intr_regap;
                        end
                        if ($test$plusargs("trace_io"))
                            $display("[TB] INTR re-requested %0d platform cycles after the acknowledge",
                                     intr_regap);
                    end else if (intr_drop_delay > 0)
                        intr_drop_count <= intr_drop_delay;
                    else
                        intr <= 1'b0;
                    if ($test$plusargs("trace_io"))
                        $display("INTA cycle 2: vector=0x%02X", intr_vector);
                end
            end else if (zw_line_fire) begin
                // +zero_wait: the whole line is presented this cycle (zw_line_fire).
                ready <= 1'b1;
            end else if (LINE_FILL && line_fill_en && line_read && !write && !io) begin
                // Whole-line fill request from an L1: answer with one 16-byte
                // beat.  Deliberately does NOT start the narrow burst, so the
                // core must complete the fill from line_din alone.
                line_byte_addr  <= {addr, 2'b00};
                line_wait_count <= (mem_latency <= 1) ? 1 : mem_latency;
                ready           <= 1'b0;
                if ($test$plusargs("trace_mem"))
                    $display("MEM LINE RD @%08x count=%0d", {addr, 2'b00}, burstcount);
            end else if (!write) begin
                // Read
                reg [7:0] burst_len;
                // +zero_wait: beat 0 was presented combinationally (zw_fire)
                bit fast;
                fast = (mem_latency <= 1) || zw_fire;
                burst_len = io ? 8'd1 : burstcount;
                rd_byte_addr <= {addr, 2'b00};
                rd_index <= fast ? 8'd1 : 8'd0;
                rd_wait_count <= fast ? 0 : (mem_latency - 1);
                rd_io_pending <= io;

                if (!io) begin
                    reg [31:0] byte_addr;
                    byte_addr = {addr, 2'b00};

                    if (byte_addr >= MEM_SIZE)
                        byte_addr = byte_addr & (MEM_SIZE - 1);

                    if ($test$plusargs("trace_mem"))
                        $display("MEM RD @%08x count=%0d first=%08x", byte_addr, burstcount,
                                 {mem[byte_addr+3], mem[byte_addr+2],
                                  mem[byte_addr+1], mem[byte_addr+0]});
                    if (mem_latency <= 1 && !zw_fire) begin
                        resp_valid <= 1'b1;
                        din <= {mem[byte_addr+3], mem[byte_addr+2],
                                mem[byte_addr+1], mem[byte_addr+0]};
                    end
                end else if (mem_latency <= 1 && !zw_fire) begin
                    // Port 0xFC reads the testbench cycle counter so directed
                    // programs can assert instruction intervals.
                    resp_valid <= 1'b1;
                    din <= ({addr[15:2], 2'b00} == 16'h00FC) ? cycle :
                           ({addr[15:2], 2'b00} == 16'h00C0) ? {31'h0, flush_complete} :
                           ({addr[15:2], 2'b00} == 16'h00D0) ? a20_bit21_writes :
                           ({addr[15:2], 2'b00} == 16'h00D4) ? a20_masked_bit20_writes :
                           32'hFFFFFFFF;
                end
                rd_remaining <= (fast && burst_len > 8'd1) ?
                                (burst_len - 8'd1) : (zw_fire ? 8'd0 : burst_len);
                ready <= (fast && burst_len <= 8'd1);
            end else begin
                // Write
                ready <= 1'b1;
                if (io) begin
                // I/O writes - check result ports
                reg [15:0] port;
                port = {addr[15:2], 2'b00};

                // Status port (0xE0) - test result
                if (port == 16'h00E0) begin
                    test_status <= dout[7:0];
                    if (dout[7:0] == 8'h01) begin
                        if (($test$plusargs("expect_vipt_ea_interlock") &&
                             (vipt_ea_interlock_cycles == 0)) ||
                            ($test$plusargs("expect_vipt_store_replay") &&
                             ((vipt_store_wait_issues == 0) ||
                              (vipt_store_replays == 0))) ||
                            ($test$plusargs("expect_store_post") &&
                             (posted_stores == 0)) ||
                            ($test$plusargs("expect_store_post_unpaged") &&
                             (posted_stores_unpaged == 0)) ||
                            ($test$plusargs("expect_cache_flush_insn") &&
                             (cache_flush_insn_count == 0)) ||
                            ($test$plusargs("expect_platform_flush") &&
                             ((platform_flushes == 0) ||
                              (platform_dma_pokes == 0))) ||
                            ($test$plusargs("expect_flush_overlap") &&
                             (flush_overlap_cycles == 0)) ||
                            ($test$plusargs("expect_stale_walk") &&
                             (stale_walk_events == 0)) ||
                            ($test$plusargs("expect_direct_code") &&
                             (direct_code_writes == 0)) ||
                            ($test$plusargs("expect_no_alloc_code") &&
                             (no_alloc_code_fills < 2)) ||
                            ($test$plusargs("expect_xdma") && !xdma_done) ||
                            ((max_lock_run != 0) && (lock_run_max > max_lock_run)) ||
                            (count_rd_en && (expect_rd_count >= 0) &&
                             (rd_count_seen != expect_rd_count)) ||
                            (watch_en && (expect_watch_reads >= 0) &&
                             (watch_seen != expect_watch_reads)) ||
                            ($test$plusargs("expect_lock") &&
                             ((locked_reads == 0) || (locked_writes == 0) ||
                              bus_lock)) ||
                            ($test$plusargs("expect_inta_lock") &&
                             ((locked_inta < 2) || (unlocked_inta != 0)))) begin
                            test_status <= 8'hFF;
                            $display("");
                            $display("========================================");
                            $display("  TEST FAILED!");
                            if ($test$plusargs("expect_cache_flush_insn")) begin
                                $display("  INVD/WBINVD routine (UADDR_INVD) never executed");
                                $display("  INVD/WBINVD words issued: %0d", cache_flush_insn_count);
                            end else if ($test$plusargs("expect_flush_overlap"))
                                $display("  No platform level overlapped an INVD/WBINVD");
                            else if ($test$plusargs("expect_platform_flush"))
                                $display("  Platform flush/DMA poke was not exercised");
                            else if (watch_en && (expect_watch_reads >= 0) &&
                                     (watch_seen != expect_watch_reads))
                                $display("  %0d bus reads in [%08x,%08x], first at %08x (expected %0d)",
                                         watch_seen, watch_lo, watch_hi, watch_first,
                                         expect_watch_reads);
                            else if (count_rd_en && (expect_rd_count >= 0) &&
                                     (rd_count_seen != expect_rd_count))
                                $display("  %0d bus reads of %08x (expected %0d)",
                                         rd_count_seen, count_rd_addr, expect_rd_count);
                            else if ((max_lock_run != 0) && (lock_run_max > max_lock_run))
                                $display("  LOCK# held %0d consecutive cycles (limit %0d)",
                                         lock_run_max, max_lock_run);
                            else if ($test$plusargs("expect_xdma") && !xdma_done)
                                $display("  external master write never happened");
                            else if ($test$plusargs("expect_inta_lock"))
                                $display("  INTA cycles locked/unlocked %0d/%0d",
                                         locked_inta, unlocked_inta);
                            else if ($test$plusargs("expect_lock"))
                                $display("  LOCK# reads/writes %0d/%0d, still asserted %0b",
                                         locked_reads, locked_writes, bus_lock);
                            else if ($test$plusargs("expect_stale_walk") &&
                                (stale_walk_events == 0))
                                $display("  no prefetch walk spanned a CR3 write");
                            else if (vipt_ea_interlock_cycles == 0)
                                $display("  VIPT load-to-EA interlock was not exercised");
                            else
                                $display("  VIPT older-store replay was not exercised");
                            $display("========================================");
                            test_done <= 1;
                        end else begin
                            // +dump_mem=file +dump_lo=hex +dump_hi=hex: write memory
                            // [lo, hi) as hex bytes. The status write is I/O, which
                            // waits for posted stores, so memory is final here.
                            begin
                                string dump_file;
                                int unsigned dump_lo, dump_hi;
                                int fd;
                                if ($value$plusargs("dump_mem=%s", dump_file) &&
                                    $value$plusargs("dump_lo=%h", dump_lo) &&
                                    $value$plusargs("dump_hi=%h", dump_hi)) begin
                                    fd = $fopen(dump_file, "w");
                                    for (int unsigned a = dump_lo; a < dump_hi && a < MEM_SIZE; a++)
                                        $fwrite(fd, "%02x\n", mem[a]);
                                    $fclose(fd);
                                end
                            end
                            $display("");
                            $display("========================================");
                            $display("  TEST PASSED!");
                            $display("  Total cycles: %0d", cycle);
                            $display("  Total instructions: %0d", instruction_count);
                            // +arch_digest: a hash of final memory, for
                            // tests/test_throttle_invariance.py (the status
                            // write is I/O, so posted stores have drained).
                            if ($test$plusargs("arch_digest")) begin
                                longint unsigned digest;
                                digest = 64'hcbf29ce484222325;
                                for (int unsigned a = 0; a < MEM_SIZE; a++)
                                    digest = (digest ^ {56'd0, mem[a]}) * 64'h00000100000001b3;
                                $display("ARCH_DIGEST memhash=%016x", digest);
                            end
                            if (spec_check_en)
                                $display("  SPEC CHECK: %0d seeded flushes checked, %0d skipped",
                                         spec_checked, spec_skipped);
                            if ($test$plusargs("expect_lock"))
                                $display("  LOCK# reads/writes: %0d/%0d",
                                         locked_reads, locked_writes);
                            if ($test$plusargs("expect_vipt_ea_interlock"))
                                $display("  VIPT EA interlock cycles: %0d",
                                         vipt_ea_interlock_cycles);
                            if ($test$plusargs("expect_vipt_store_replay"))
                                $display("  VIPT store waits/replays: %0d/%0d",
                                         vipt_store_wait_issues,
                                         vipt_store_replays);
                            if ($test$plusargs("expect_store_post") ||
                                $test$plusargs("expect_store_post_unpaged") ||
                                $test$plusargs("trace_io"))
                                $display("  Posted stores: %0d (%0d unpaged)",
                                         posted_stores, posted_stores_unpaged);
                            if (platform_flushes != 0)
                                $display("  Flushes: %0d, last busy-to-done %0d cycles",
                                         platform_flushes, platform_flush_cycles);
                            if (cache_flush_insn_count != 0)
                                $display("  INVD/WBINVD words issued: %0d",
                                         cache_flush_insn_count);
                            if (flush_overlap_cycles != 0)
                                $display("  Platform level / INVD overlap cycles: %0d",
                                         flush_overlap_cycles);
                            $display("========================================");
                            test_done <= 1;
                        end
                    end else if (dout[7:0] == 8'hFF) begin
                        $display("");
                        $display("========================================");
                        $display("  TEST FAILED!");
                        $display("  Failure data: 0x%08X", test_data);
                        $display("  Total cycles: %0d", cycle);
                        $display("  CS:EIP: %04X:%08X", dut.CS, dut.EIP);
                        $display("========================================");
                        test_done <= 1;
                    end
                end

                // Platform flush request (0xC0): request the native whole-L1
                // flush through the top-level cache_flush input.  The level is
                // held until the fabric pulses done and is released after it.
                if (port == 16'h00C0) begin
                    cache_flush_req <= 1'b1;
                    if ($test$plusargs("trace_io"))
                        $display("PLATFORM: cache flush requested");
                end

                // Asynchronous platform flush (0xCC): fires dout cycles from
                // now; the external bus is held busy from this write.
                if (port == 16'h00CC) begin
                    async_flush_in <= dout;
                    async_stall <= async_stall_len;
                end

                // External-write address (0xC4)
                if (port == 16'h00C4)
                    dma_poke_addr <= dout;

                // External write data (0xC8): DMA into the RAM model, behind
                // the caches and with no snoop.
                if (port == 16'h00C8) begin
                    reg [31:0] poke;
                    poke = dma_poke_addr;
                    if (poke + 4 <= MEM_SIZE) begin
                        if (be[0]) mem[poke+0] <= dout[7:0];
                        if (be[1]) mem[poke+1] <= dout[15:8];
                        if (be[2]) mem[poke+2] <= dout[23:16];
                        if (be[3]) mem[poke+3] <= dout[31:24];
                    end
                    platform_dma_pokes <= platform_dma_pokes + 1;
                    if ($test$plusargs("trace_io"))
                        $display("PLATFORM DMA WRITE @%08x = %08x be=%b (no snoop)",
                                 poke, dout, be);
                end

                if (port == 16'h00F0) tb_a20 <= 1'b0;
                if (port == 16'h00F4) tb_a20 <= 1'b1;

                // Data port (0xE4) - debug/verification data
                if (port == 16'h00E4) begin
                    test_data <= dout;
                    if ($test$plusargs("trace_io"))
                        $display("TEST DATA: 0x%08X", dout);
                end

                // Signal port (0xE8) - trigger hardware interrupts
                // 1 = assert INTR after short delay
                // 2 = pulse NMI after short delay
                // 3 = assert INTR while IF=0 (masked test)
                // 4 = assert INTR during the next hardwired absolute load,
                //     so it becomes pending at the load's retirement boundary
                if (port == 16'h00E8) begin
                    if (dout[7:0] == 8'h01 || dout[7:0] == 8'h03) begin
                        if (signal_delay_instr > 0) begin
                            intr_instr_remaining <= signal_delay_instr;
                            intr_request <= 1'b1;
                        end else begin
                            intr_request <= 1'b1;
                            intr_delay <= signal_delay_cycles;
                        end
                        if ($test$plusargs("trace_io"))
                            $display("SIGNAL: INTR requested (mode=%0d, cyc=%0d, instr=%0d)",
                                     dout[7:0], signal_delay_cycles, signal_delay_instr);
                    end
                    if (dout[7:0] == 8'h02) begin
                        if (signal_delay_instr > 0) begin
                            nmi_instr_remaining <= signal_delay_instr;
                            nmi_request <= 1'b1;
                        end else begin
                            nmi_request <= 1'b1;
                            intr_delay <= signal_delay_cycles;
                        end
                        if ($test$plusargs("trace_io"))
                            $display("SIGNAL: NMI requested (cyc=%0d, instr=%0d)",
                                     signal_delay_cycles, signal_delay_instr);
                    end
                    if (dout[7:0] == 8'h04) begin
                        intr_hardwired_load_arm <= 1'b1;
                        if ($test$plusargs("trace_io"))
                            $display("SIGNAL: INTR armed for hardwired load boundary");
                    end
                end

                // Signal delay (0xEC) - low 16 bits are cycle delay
                if (port == 16'h00EC) begin
                    signal_delay_cycles <= dout[15:0] * signal_delay_scale;
                    if ($test$plusargs("trace_io"))
                        $display("SIGNAL CFG: cycle delay=%0d (x%0d)", dout[15:0],
                                 signal_delay_scale);
                end

                // Signal instruction delay (0xF0) - low 16 bits are retired instruction delay
                // 0 means use cycle delay mode.
                if (port == 16'h00F0) begin
                    signal_delay_instr <= dout[15:0];
                    if ($test$plusargs("trace_io"))
                        $display("SIGNAL CFG: instruction delay=%0d", dout[15:0]);
                end

                // Signal vector (0xF4) - low 8 bits are INTR vector
                if (port == 16'h00F4) begin
                    intr_vector <= dout[7:0];
                    if ($test$plusargs("trace_io"))
                        $display("SIGNAL CFG: INTR vector=0x%02X", dout[7:0]);
                end

                // NMI pulse width (0xF8) - low 16 bits = cycles to keep nmi asserted
                if (port == 16'h00F8) begin
                    if (dout[15:0] == 0)
                        nmi_pulse_cycles <= 1;
                    else
                        nmi_pulse_cycles <= dout[15:0];
                    if ($test$plusargs("trace_io"))
                        $display("SIGNAL CFG: NMI pulse cycles=%0d",
                                 (dout[15:0] == 0) ? 1 : dout[15:0]);
                end

                if ($test$plusargs("trace_io"))
                    $display("IO WR port=%04x data=%08x", port, dout);
            end else begin
                // Memory writes
                reg [31:0] byte_addr;
                byte_addr = {addr, 2'b00};
                if (byte_addr[21]) a20_bit21_writes <= a20_bit21_writes + 1;
                if (byte_addr[20] && !tb_a20)
                    a20_masked_bit20_writes <= a20_masked_bit20_writes + 1;

                if (byte_addr < MEM_SIZE) begin
                    if (be[0]) mem[byte_addr+0] <= dout[7:0];
                    if (be[1]) mem[byte_addr+1] <= dout[15:8];
                    if (be[2]) mem[byte_addr+2] <= dout[23:16];
                    if (be[3]) mem[byte_addr+3] <= dout[31:24];
                end

                if ($test$plusargs("trace_mem"))
                    $display("MEM WR @%08x be=%b data=%08x uc=%03h mem_wdata=%08h src=%02h",
                             byte_addr, be, dout, dut.uc_addr, dut.mem_wdata, dut.uc_source);
            end
        end
    end
    end

    // Configuration from plusargs
    string memfile, raw_memfile;
    integer raw_mem_fd, raw_mem_bytes;
    int eip_arg;
    int cr0_arg, cr2_arg, cr3_arg;
    int code_phys_base;  // Physical address where code is loaded (for prefetch)
    int start_protected; // 1: force protected-mode entry state, 0: start in real mode
    int d_init;          // Initial default operand size flag
    bit snapshot_mode;
    bit stop_eip_valid;
    int stop_eip, stop_cs;
    int stop_occurrence, stop_match_count;
    int checksum_count;
    int checksum_start [0:3];
    int checksum_bytes [0:3];

    logic [31:0] init_eax, init_ebx, init_ecx, init_edx;
    logic [31:0] init_esi, init_edi, init_ebp, init_esp, init_eflags;
    logic [15:0] init_ldtr, init_tr;
    logic [31:0] init_gdt_base, init_idt_base;
    logic [19:0] init_gdt_limit, init_idt_limit;
    logic [31:0] ldt_base, tr_base;
    logic [19:0] ldt_limit, tr_limit;
    logic [15:0] ldt_flags, tr_flags;

    logic [15:0] x87_control_arg, x87_status_arg, x87_tag_arg;
    logic [2:0]  x87_top_arg;
    logic [79:0] x87_fpr_arg [0:7];

    // Initial visible segment selectors
    int init_cs, init_ds, init_ss, init_es, init_fs, init_gs;

    // Segment descriptor cache values from plusargs
    int cs_base, cs_limit, cs_flags;
    int ds_base, ds_limit, ds_flags;
    int ss_base, ss_limit, ss_flags;
    int es_base, es_limit, es_flags;
    int fs_base, fs_limit, fs_flags;
    int gs_base, gs_limit, gs_flags;

    // Build seg_desc_t from flags
    // flags[15:12] = type, flags[11] = S, flags[10:9] = DPL, flags[8] = P,
    // flags[7] = D_B, flags[6] = G, flags[5] = A
    function automatic z486_pkg::seg_desc_t build_seg_desc(
        input [31:0] base, input [19:0] limit, input [15:0] flags
    );
        z486_pkg::seg_desc_t desc;
        desc.base       = base;
        desc.limit      = limit;
        desc.seg_type   = flags[15:12];
        desc.S          = flags[11];
        desc.DPL        = flags[10:9];
        desc.P          = flags[8];
        desc.D_B        = flags[7];
        desc.G          = flags[6];
        desc.A          = flags[5];
        return desc;
    endfunction

    // Default protected mode descriptor flags:
    // type=0010 (data RW), S=1, DPL=0, P=1, D_B=1 (32-bit), G=1 (4K), A=1
    localparam DEFAULT_DATA_FLAGS = 16'h21E0;  // Data RW, S=1, DPL=0, P=1, D_B=1, G=1, A=1
    localparam DEFAULT_CODE_FLAGS = 16'hA1E0;  // Code RX, S=1, DPL=0, P=1, D_B=1, G=1, A=1
    // Real-mode: D_B=0 (16-bit), G=0 (byte granularity), P=1, A=0
    // flags: type[15:12] S[11] DPL[10:9] P[8] D_B[7] G[6] A[5]
    localparam RM_DATA_FLAGS = 16'h2900;       // type=0010(RW), S=1, DPL=0, P=1, D_B=0, G=0
    localparam RM_CODE_FLAGS = 16'hA900;       // type=1010(RX), S=1, DPL=0, P=1, D_B=0, G=0

    initial begin
        // Snapshot RAM is already complete, so avoid clearing a 64MB array
        // before loading it. Small instruction tests retain the hex path.
        if ($value$plusargs("raw_mem=%s", raw_memfile)) begin
            raw_mem_fd = $fopen(raw_memfile, "rb");
            if (!raw_mem_fd) begin
                $display("[TB] ERROR: Could not open raw memory %s", raw_memfile);
                $finish;
            end
            raw_mem_bytes = $fread(mem, raw_mem_fd);
            $fclose(raw_mem_fd);
            if (raw_mem_bytes != MEM_SIZE) begin
                $display("[TB] ERROR: Raw memory size %0d, expected %0d",
                         raw_mem_bytes, MEM_SIZE);
                $finish;
            end
            $display("[TB] Loaded %0d raw memory bytes from %s",
                     raw_mem_bytes, raw_memfile);
        end else if ($value$plusargs("mem=%s", memfile)) begin
            for (int i = 0; i < MEM_SIZE; i++)
                mem[i] = 8'h00;
            $readmemh(memfile, mem);
            $display("[TB] Loaded memory from %s", memfile);
        end else begin
            $display("[TB] ERROR: No memory file specified (+mem= or +raw_mem=)");
            $finish;
        end

        snapshot_mode = $test$plusargs("snapshot");
        for (int i = 0; i < 2048; i++)
            x87_fop_count[i] = 0;
        for (int i = 0; i < 2048; i++)
            x87_direct_load_fop_count[i] = 0;
        for (int i = 0; i < 16; i++) begin
            x87_exec_start_count[i] = 0;
            x87_exec_busy_count[i] = 0;
        end
        for (int i = 0; i < 4096; i++) begin
            cpu_entry_count[i] = 0;
            cpu_entry_cycles[i] = 0;
            cpu_entry_mem_stall[i] = 0;
            cpu_entry_x87_stall[i] = 0;
            cpu_entry_frontend_wait[i] = 0;
            cpu_store_next_entry[i] = 0;
            for (int j = 0; j < 4; j++)
                cpu_store_next_entry_gap[i][j] = 0;
        end
        for (int i = 0; i < 256; i++) begin
            cpu_opcode_count[i] = 0;
            cpu_opcode_cycles[i] = 0;
            cpu_store_next_opcode[i] = 0;
            for (int j = 0; j < 4; j++)
                cpu_store_next_opcode_gap[i][j] = 0;
        end
        for (int i = 0; i < 2; i++) begin
            cpu_hardwired_count[i] = 0;
            cpu_hardwired_cycles[i] = 0;
        end
        for (int i = 0; i < 8; i++) begin
            cpu_commit_count[i] = 0;
            cpu_commit_cycles[i] = 0;
        end
        for (int i = 0; i < 10; i++)
            cpu_stall_cycles[i] = 0;
        for (int i = 0; i < 12; i++)
            cpu_load_chain[i] = 0;
        for (int i = 0; i < 17; i++)
            cpu_load_intervals[i] = 0;
        for (int i = 0; i < 8; i++) begin
            cpu_load_issue[i] = 0;
            cpu_load_result[i] = 0;
            cpu_branch_result[i] = 0;
            cpu_x87_wait_reason[i] = 0;
        end
        for (int i = 0; i < 2; i++)
            for (int j = 0; j < 4; j++)
                cpu_load_successor[i][j] = 0;
        for (int path = 0; path < 3; path++) begin
            for (int interval = 0; interval < 17; interval++)
                cpu_load_path_interval[path][interval] = 0;
            for (int dependency = 0; dependency < 4; dependency++) begin
                cpu_load_path_successor_count[path][dependency] = 0;
                cpu_load_path_successor_cycles[path][dependency] = 0;
            end
            for (int entry = 0; entry < 4096; entry++) begin
                cpu_load_next_entry_count[path][entry] = 0;
                cpu_load_next_entry_cycles[path][entry] = 0;
            end
            for (int addr32 = 0; addr32 < 2; addr32++)
                for (int size = 0; size < 3; size++)
                    for (int ea_class = 0; ea_class < 3; ea_class++)
                        for (int alignment = 0; alignment < 4; alignment++) begin
                            cpu_load_form_count[path][addr32][size]
                                               [ea_class][alignment] = 0;
                            cpu_load_form_cycles[path][addr32][size]
                                                [ea_class][alignment] = 0;
                        end
        end
        for (int i = 0; i < 5; i++)
            cpu_rep_elements[i] = 0;
        for (int i = 0; i < 17; i++)
            cpu_store_intervals[i] = 0;
        for (int i = 0; i < 10; i++)
            cpu_store_states[i] = 0;
        cpu_current_start = 0;
        cpu_current_entry = 0;
        cpu_current_opcode = 0;
        cpu_current_hardwired = 0;
        cpu_current_commit = 0;
        cpu_current_load_dst_mask = 0;
        cpu_current_load_direct = 0;
        cpu_current_load_path = 0;
        cpu_current_load_addr32 = 0;
        cpu_current_load_size = 0;
        cpu_current_load_ea_class = 0;
        cpu_current_load_alignment = 0;
        cpu_profile_active = 0;

        // Get max cycles
        if ($value$plusargs("cycles=%d", max_cycles))
            $display("[TB] Max cycles: %0d", max_cycles);
        if ($value$plusargs("mem_latency=%d", mem_latency))
            $display("[TB] Memory latency: %0d cycles", mem_latency);
        // A/B switch: +no_line_fill restores the narrow-only (upstream) model.
        if ($test$plusargs("no_line_fill")) begin
            line_fill_en = 1'b0;
            $display("[TB] Whole-line fill: DISABLED (narrow-only model)");
        end else if (LINE_FILL)
            $display("[TB] Whole-line fill: ENABLED (16-byte line_resp_valid)");
        if ($test$plusargs("continue_on_hlt"))
            stop_on_hlt = 1'b0;

        // Get initial EIP (default 0)
        if (!$value$plusargs("eip=%d", eip_arg)) eip_arg = 0;

        // Get control registers
        if (!$value$plusargs("cr0=%d", cr0_arg)) cr0_arg = 32'h80000001;  // PE=1, PG=1
        if (!$value$plusargs("cr2=%d", cr2_arg)) cr2_arg = 32'h00000000;
        if (!$value$plusargs("cr3=%d", cr3_arg)) cr3_arg = 32'h00000000;  // Page dir at 0

        // Get physical address where code is loaded (prefetch bypasses paging)
        if (!$value$plusargs("code_phys_base=%d", code_phys_base)) code_phys_base = 32'h00010000;

        // Start mode (default protected for backward compatibility)
        if (!$value$plusargs("start_protected=%d", start_protected)) start_protected = 1;

        // Get segment descriptor parameters
        // CS
        if (!$value$plusargs("cs_base=%d", cs_base)) cs_base = 32'h10000000;
        if (!$value$plusargs("cs_limit=%d", cs_limit)) cs_limit = 20'hFFFFF;
        if (!$value$plusargs("cs_flags=%d", cs_flags)) cs_flags = DEFAULT_CODE_FLAGS;
        // DS
        if (!$value$plusargs("ds_base=%d", ds_base)) ds_base = 32'h20000000;
        if (!$value$plusargs("ds_limit=%d", ds_limit)) ds_limit = 20'hFFFFF;
        if (!$value$plusargs("ds_flags=%d", ds_flags)) ds_flags = DEFAULT_DATA_FLAGS;
        // SS
        if (!$value$plusargs("ss_base=%d", ss_base)) ss_base = 32'h30000000;
        if (!$value$plusargs("ss_limit=%d", ss_limit)) ss_limit = 20'hFFFFF;
        if (!$value$plusargs("ss_flags=%d", ss_flags)) ss_flags = DEFAULT_DATA_FLAGS;
        // ES
        if (!$value$plusargs("es_base=%d", es_base)) es_base = 32'h00000000;
        if (!$value$plusargs("es_limit=%d", es_limit)) es_limit = 20'hFFFFF;
        if (!$value$plusargs("es_flags=%d", es_flags)) es_flags = DEFAULT_DATA_FLAGS;
        // FS
        if (!$value$plusargs("fs_base=%d", fs_base)) fs_base = 32'h00000000;
        if (!$value$plusargs("fs_limit=%d", fs_limit)) fs_limit = 20'hFFFFF;
        if (!$value$plusargs("fs_flags=%d", fs_flags)) fs_flags = DEFAULT_DATA_FLAGS;
        // GS
        if (!$value$plusargs("gs_base=%d", gs_base)) gs_base = 32'h00000000;
        if (!$value$plusargs("gs_limit=%d", gs_limit)) gs_limit = 20'hFFFFF;
        if (!$value$plusargs("gs_flags=%d", gs_flags)) gs_flags = DEFAULT_DATA_FLAGS;

        // Real-mode: override segment descriptors to 16-bit mode
        if (!start_protected) begin
            if (!$value$plusargs("cs_base=%d", cs_base)) cs_base = code_phys_base;
            if (!$value$plusargs("ds_base=%d", ds_base)) ds_base = 32'h00000000;
            if (!$value$plusargs("ss_base=%d", ss_base)) ss_base = 32'h00000000;
            if (!$value$plusargs("cs_limit=%d", cs_limit)) cs_limit = 20'h0FFFF;
            if (!$value$plusargs("ds_limit=%d", ds_limit)) ds_limit = 20'h0FFFF;
            if (!$value$plusargs("ss_limit=%d", ss_limit)) ss_limit = 20'h0FFFF;
            if (!$value$plusargs("es_limit=%d", es_limit)) es_limit = 20'h0FFFF;
            if (!$value$plusargs("fs_limit=%d", fs_limit)) fs_limit = 20'h0FFFF;
            if (!$value$plusargs("gs_limit=%d", gs_limit)) gs_limit = 20'h0FFFF;
            if (!$value$plusargs("cs_flags=%d", cs_flags)) cs_flags = RM_CODE_FLAGS;
            if (!$value$plusargs("ds_flags=%d", ds_flags)) ds_flags = RM_DATA_FLAGS;
            if (!$value$plusargs("ss_flags=%d", ss_flags)) ss_flags = RM_DATA_FLAGS;
            if (!$value$plusargs("es_flags=%d", es_flags)) es_flags = RM_DATA_FLAGS;
            if (!$value$plusargs("fs_flags=%d", fs_flags)) fs_flags = RM_DATA_FLAGS;
            if (!$value$plusargs("gs_flags=%d", gs_flags)) gs_flags = RM_DATA_FLAGS;
        end

        // Initial segment selectors:
        // - protected start defaults to canonical GDT selectors
        // - real-mode start defaults to CS derived from code physical address
        if (!$value$plusargs("init_cs=%d", init_cs))
            init_cs = start_protected ? 16'h0008 : ((code_phys_base >> 4) & 16'hFFFF);
        if (!$value$plusargs("init_ds=%d", init_ds))
            init_ds = start_protected ? 16'h0010 : 16'h0000;
        if (!$value$plusargs("init_ss=%d", init_ss))
            init_ss = start_protected ? 16'h0018 : 16'h0000;
        if (!$value$plusargs("init_es=%d", init_es))
            init_es = start_protected ? 16'h0020 : 16'h0000;
        if (!$value$plusargs("init_fs=%d", init_fs))
            init_fs = start_protected ? 16'h0028 : 16'h0000;
        if (!$value$plusargs("init_gs=%d", init_gs))
            init_gs = start_protected ? 16'h0030 : 16'h0000;

        // Initial default operand-size mode
        if (!$value$plusargs("d_init=%d", d_init))
            d_init = start_protected ? 1 : 0;

        init_eax = 0; init_ebx = 0; init_ecx = 0; init_edx = 0;
        init_esi = 0; init_edi = 0; init_ebp = 0; init_esp = 32'h0000ff00;
        init_eflags = 32'h00000002;
        void'($value$plusargs("init_eax=%h", init_eax));
        void'($value$plusargs("init_ebx=%h", init_ebx));
        void'($value$plusargs("init_ecx=%h", init_ecx));
        void'($value$plusargs("init_edx=%h", init_edx));
        void'($value$plusargs("init_esi=%h", init_esi));
        void'($value$plusargs("init_edi=%h", init_edi));
        void'($value$plusargs("init_ebp=%h", init_ebp));
        void'($value$plusargs("init_esp=%h", init_esp));
        void'($value$plusargs("init_eflags=%h", init_eflags));

        init_ldtr = 0; init_tr = 0;
        init_gdt_base = 0; init_gdt_limit = 20'h003ff;
        init_idt_base = 0; init_idt_limit = 20'h003ff;
        ldt_base = 0; ldt_limit = 0; ldt_flags = 0;
        tr_base = 0; tr_limit = 0; tr_flags = 0;
        void'($value$plusargs("init_ldtr=%h", init_ldtr));
        void'($value$plusargs("init_tr=%h", init_tr));
        void'($value$plusargs("gdt_base=%h", init_gdt_base));
        void'($value$plusargs("gdt_limit=%h", init_gdt_limit));
        void'($value$plusargs("idt_base=%h", init_idt_base));
        void'($value$plusargs("idt_limit=%h", init_idt_limit));
        void'($value$plusargs("ldt_base=%h", ldt_base));
        void'($value$plusargs("ldt_limit=%h", ldt_limit));
        void'($value$plusargs("ldt_flags=%h", ldt_flags));
        void'($value$plusargs("tr_base=%h", tr_base));
        void'($value$plusargs("tr_limit=%h", tr_limit));
        void'($value$plusargs("tr_flags=%h", tr_flags));

        stop_eip_valid = $value$plusargs("stop_eip=%h", stop_eip);
        if (!$value$plusargs("stop_cs=%h", stop_cs)) stop_cs = init_cs;
        if (!$value$plusargs("stop_occurrence=%d", stop_occurrence)) stop_occurrence = 1;
        if (stop_occurrence < 1) stop_occurrence = 1;
        stop_match_count = 0;
        if (!$value$plusargs("checksum_count=%d", checksum_count)) begin
            checksum_count = 1;
            if (!$value$plusargs("checksum_start=%h", checksum_start[0])) checksum_start[0] = 0;
            if (!$value$plusargs("checksum_bytes=%h", checksum_bytes[0])) checksum_bytes[0] = 0;
        end else begin
            if (checksum_count < 1) checksum_count = 1;
            if (checksum_count > 4) checksum_count = 4;
            for (int i = 0; i < 4; i++) begin
                checksum_start[i] = 0;
                checksum_bytes[i] = 0;
            end
            void'($value$plusargs("checksum0_start=%h", checksum_start[0]));
            void'($value$plusargs("checksum0_bytes=%h", checksum_bytes[0]));
            void'($value$plusargs("checksum1_start=%h", checksum_start[1]));
            void'($value$plusargs("checksum1_bytes=%h", checksum_bytes[1]));
            void'($value$plusargs("checksum2_start=%h", checksum_start[2]));
            void'($value$plusargs("checksum2_bytes=%h", checksum_bytes[2]));
            void'($value$plusargs("checksum3_start=%h", checksum_start[3]));
            void'($value$plusargs("checksum3_bytes=%h", checksum_bytes[3]));
        end

        x87_control_arg = 16'h037f; x87_status_arg = 0;
        x87_tag_arg = 16'hffff; x87_top_arg = 0;
        for (int i = 0; i < 8; i++) x87_fpr_arg[i] = 0;
        void'($value$plusargs("x87_control=%h", x87_control_arg));
        void'($value$plusargs("x87_status=%h", x87_status_arg));
        void'($value$plusargs("x87_tag=%h", x87_tag_arg));
        void'($value$plusargs("x87_top=%h", x87_top_arg));
        void'($value$plusargs("x87_fpr0=%h", x87_fpr_arg[0]));
        void'($value$plusargs("x87_fpr1=%h", x87_fpr_arg[1]));
        void'($value$plusargs("x87_fpr2=%h", x87_fpr_arg[2]));
        void'($value$plusargs("x87_fpr3=%h", x87_fpr_arg[3]));
        void'($value$plusargs("x87_fpr4=%h", x87_fpr_arg[4]));
        void'($value$plusargs("x87_fpr5=%h", x87_fpr_arg[5]));
        void'($value$plusargs("x87_fpr6=%h", x87_fpr_arg[6]));
        void'($value$plusargs("x87_fpr7=%h", x87_fpr_arg[7]));

        $display("[TB] Configuration:");
        $display("[TB]   mode=%s", start_protected ? "protected-start" : "real-start");
        $display("[TB]   EIP=0x%08X CR0=0x%08X CR3=0x%08X", eip_arg, cr0_arg, cr3_arg);
        $display("[TB]   selectors: CS=%04X DS=%04X SS=%04X ES=%04X FS=%04X GS=%04X",
                 init_cs[15:0], init_ds[15:0], init_ss[15:0], init_es[15:0], init_fs[15:0], init_gs[15:0]);
        $display("[TB]   CS: base=0x%08X limit=0x%05X flags=0x%04X", cs_base, cs_limit, cs_flags);
        $display("[TB]   DS: base=0x%08X limit=0x%05X flags=0x%04X", ds_base, ds_limit, ds_flags);
        $display("[TB]   SS: base=0x%08X limit=0x%05X flags=0x%04X", ss_base, ss_limit, ss_flags);

        // Reset sequence
        #20;
        reset_n = 0;
        #10;

        #50;
        reset_n = 1;
        #1;

        // Initialize CPU state immediately after reset release, before the next
        // clock edge. Write the compact hidden-descriptor bank directly.
        dut.CS = init_cs[15:0];
        dut.DS = init_ds[15:0];
        dut.SS = init_ss[15:0];
        dut.ES = init_es[15:0];
        dut.FS = init_fs[15:0];
        dut.GS = init_gs[15:0];
        dut.LDTR = init_ldtr;
        dut.TR = init_tr;

        dut.EIP = eip_arg;

        dut.seg_unit.desc_cache[1] = build_seg_desc(cs_base, cs_limit[19:0], cs_flags);
        dut.seg_unit.desc_cache[3] = build_seg_desc(ds_base, ds_limit[19:0], ds_flags);
        dut.seg_unit.desc_cache[2] = build_seg_desc(ss_base, ss_limit[19:0], ss_flags);
        dut.seg_unit.desc_cache[0] = build_seg_desc(es_base, es_limit[19:0], es_flags);
        dut.seg_unit.desc_cache[4] = build_seg_desc(fs_base, fs_limit[19:0], fs_flags);
        dut.seg_unit.desc_cache[5] = build_seg_desc(gs_base, gs_limit[19:0], gs_flags);
        dut.seg_unit.desc_cache[6] = build_seg_desc(tr_base, tr_limit, tr_flags);
        dut.seg_unit.desc_cache[7] = build_seg_desc(ldt_base, ldt_limit, ldt_flags);
        dut.seg_unit.gdt_base = init_gdt_base;
        dut.seg_unit.gdt_limit = init_gdt_limit;
        dut.seg_unit.idt_base = init_idt_base;
        dut.seg_unit.idt_limit = init_idt_limit;
        dut.seg_unit.desc_cache[1].D_B = d_init[0];

        // Snapshot restore supplies architectural linear state. Ordinary tests
        // retain their existing direct physical-code initialization.
        dut.prefetch_inst.pf_fetch_addr = snapshot_mode ?
                                           cs_base + eip_arg :
                                           code_phys_base + eip_arg;

        // General registers = 0
        dut.EAX = init_eax;
        dut.ECX = init_ecx;
        dut.EDX = init_edx;
        dut.EBX = init_ebx;
        dut.ESP = init_esp;
        dut.EBP = init_ebp;
        dut.ESI = init_esi;
        dut.EDI = init_edi;

        // Flags and control
        dut.EFLAGS = init_eflags;
        dut.CR0 = cr0_arg;
        dut.CR2 = cr2_arg;
        dut.CR3 = cr3_arg;

        if (snapshot_mode)
            -> load_snapshot_x87_state;

        $display("[TB] CPU reset complete, starting execution");
        $display("");
    end

    // Real time, in clk cycles (what the guest reads back on port 0xFC).
    always @(posedge clk) if (reset_n) cycle <= cycle + 1;

    // Main test loop (CPU time: the bench's interrupt and NMI placement counts
    // the CPU's own clock edges, so a cycle-placed interrupt keeps its place in
    // the instruction stream at every throttle setting)
    always @(posedge cclk) begin
        if (reset_n) begin
            if (triple_fault_reset && $test$plusargs("expect_triple_fault")) begin
                $display("");
                $display("========================================");
                $display("  TEST PASSED! Triple-fault reset requested.");
                $display("  Total cycles: %0d", cycle);
                $display("========================================");
                #50;
                $finish;
            end

            // Count architectural issue transfers. RNI can remain asserted on
            // adjacent boundaries, so edge-counting it undercounts throughput.
            prev_instruction_boundary <= instruction_boundary;
            if (dut.i_issue)
                instruction_count <= instruction_count + 1;

            // EIP still names the matching instruction on i_issue.  Counting
            // occurrences permits stable loop/body boundaries as well as a
            // traditional first return-address stop.
            if (stop_eip_valid && dut.i_issue &&
                (dut.CS == stop_cs[15:0]) && (dut.EIP == stop_eip)) begin
                if ((stop_match_count + 1) < stop_occurrence) begin
                    stop_match_count <= stop_match_count + 1;
                end else begin
                    longint unsigned checksum [0:3];
                    // Stores still in the D-cache write path at the stop are
                    // part of the architectural state: overlay them, oldest
                    // first, so the hash does not depend on drain timing.
                    logic [7:0] pend [int unsigned];
                    begin
                        int unsigned depth, k, slot;
                        depth = $size(dut.memory_inst.cache_unit_inst.dcache_inst.storeq_valid);
                        for (k = 0; k < depth; k++) begin
                            slot = (dut.memory_inst.cache_unit_inst.dcache_inst.storeq_tail + k) % depth;
                            if (dut.memory_inst.cache_unit_inst.dcache_inst.storeq_valid[slot])
                                for (int b = 0; b < 4; b++)
                                    if (dut.memory_inst.cache_unit_inst.dcache_inst.storeq_be[slot][b])
                                        pend[{dut.memory_inst.cache_unit_inst.dcache_inst.storeq_addr[slot], 2'b00} + b] =
                                            dut.memory_inst.cache_unit_inst.dcache_inst.storeq_data[slot][8*b +: 8];
                        end
                        // An accepted store still in lookup (S_LOOKUP = 2) is younger.
                        if (dut.memory_inst.cache_unit_inst.dcache_inst.state == 3'd2 &&
                            dut.memory_inst.cache_unit_inst.dcache_inst.req_valid_r &&
                            dut.memory_inst.cache_unit_inst.dcache_inst.req_write_r &&
                            !dut.memory_inst.cache_unit_inst.dcache_inst.req_protect_write_r)
                            for (int b = 0; b < 4; b++)
                                if (dut.memory_inst.cache_unit_inst.dcache_inst.req_be_r[b])
                                    pend[{dut.memory_inst.cache_unit_inst.dcache_inst.req_addr_r[31:2], 2'b00} + b] =
                                        dut.memory_inst.cache_unit_inst.dcache_inst.req_din_r[8*b +: 8];
                        // An older instruction's store presented on this very edge is youngest.
                        if (dut.memory_inst.cache_unit_inst.dcache_cpu_req &&
                            dut.memory_inst.cache_unit_inst.dcache_cpu_write)
                            for (int b = 0; b < 4; b++)
                                if (dut.memory_inst.cache_unit_inst.dcache_cpu_be[b])
                                    pend[{dut.memory_inst.cache_unit_inst.dcache_cpu_addr[31:2], 2'b00} + b] =
                                        dut.memory_inst.cache_unit_inst.dcache_cpu_wdata[8*b +: 8];
                    end
                    for (int range_index = 0; range_index < checksum_count; range_index++) begin
                        checksum[range_index] = 64'hcbf29ce484222325;
                        for (int i = 0; i < checksum_bytes[range_index]; i++) begin
                            if ((checksum_start[range_index] + i) < MEM_SIZE) begin
                                int unsigned a;
                                a = checksum_start[range_index] + i;
                                checksum[range_index] = checksum[range_index] ^
                                                        (pend.exists(a) ? pend[a] : mem[a]);
                                checksum[range_index] = checksum[range_index] *
                                                        64'h00000100000001b3;
                            end
                        end
                    end
                    begin
                        string dump_file;
                        int fd;
                        if ($value$plusargs("dump_low_mem=%s", dump_file)) begin
                            fd = $fopen(dump_file, "w");
                            for (int unsigned a = 0; a < 32'h000a0000; a++)
                                $fwrite(fd, "%02x\n", pend.exists(a) ? pend[a] : mem[a]);
                            $fclose(fd);
                        end
                    end
                    $display("");
                    $display("========================================");
                    $display("  SNAPSHOT COMPLETE");
                    $display("  Stop occurrence: %0d", stop_occurrence);
                    $display("  Total cycles: %0d", cycle);
                    $display("  Total instructions: %0d", instruction_count);
                    $display("  CPI: %f", instruction_count ?
                             real'(cycle) / real'(instruction_count) : 0.0);
                    $display("  x87 commands: %0d", x87_command_count);
                    $display("  x87 direct loads: %0d", x87_direct_load_count);
                    $display("  x87 control busy cycles: %0d", x87_control_busy_cycles);
                    $display("  x87 executor busy cycles: %0d", x87_executor_busy_cycles);
                    $display("  x87 WAIT stall cycles: %0d", x87_wait_stall_cycles);
                    if ($test$plusargs("profile_x87")) begin
                    for (int i = 0; i < 2048; i++) begin
                        if (x87_fop_count[i] != 0)
                            $display("X87_FOP protocol %03x %0d", i, x87_fop_count[i]);
                        if (x87_direct_load_fop_count[i] != 0)
                            $display("X87_FOP direct-load %03x %0d", i,
                                     x87_direct_load_fop_count[i]);
                    end
                    for (int i = 0; i < 16; i++) begin
                        if (x87_exec_start_count[i] != 0)
                            $display("X87_EXEC %0d %0d %0d", i,
                                     x87_exec_start_count[i],
                                     x87_exec_busy_count[i]);
                    end
                end
                    if ($test$plusargs("profile_cpu")) begin
                    for (int i = 0; i < 4096; i++) begin
                        if (cpu_entry_count[i] != 0)
                            $display("CPU_ENTRY %03x %0d %0d %0d %0d %0d", i,
                                     cpu_entry_count[i], cpu_entry_cycles[i],
                                     cpu_entry_mem_stall[i], cpu_entry_x87_stall[i],
                                     cpu_entry_frontend_wait[i]);
                    end
                    for (int i = 0; i < 256; i++) begin
                        if (cpu_opcode_count[i] != 0)
                            $display("CPU_OPCODE %02x %0d %0d", i,
                                     cpu_opcode_count[i], cpu_opcode_cycles[i]);
                    end
                    for (int i = 0; i < 2; i++)
                        $display("CPU_HARDWIRED %0d %0d %0d", i,
                                 cpu_hardwired_count[i], cpu_hardwired_cycles[i]);
                    for (int i = 0; i < 8; i++) begin
                        if (cpu_commit_count[i] != 0)
                            $display("CPU_COMMIT %0d %0d %0d", i,
                                     cpu_commit_count[i], cpu_commit_cycles[i]);
                    end
                    for (int i = 0; i < 10; i++)
                        $display("CPU_STATE %0d %0d", i, cpu_stall_cycles[i]);
                    for (int i = 0; i < 12; i++)
                        $display("CPU_LOAD_CHAIN %0d %0d", i,
                                 cpu_load_chain[i]);
                    for (int i = 0; i < 17; i++)
                        $display("CPU_LOAD_INTERVAL %0d %0d", i,
                                 cpu_load_intervals[i]);
                    for (int i = 0; i < 8; i++) begin
                        $display("CPU_LOAD_ISSUE %0d %0d", i,
                                 cpu_load_issue[i]);
                        $display("CPU_LOAD_RESULT %0d %0d", i,
                                 cpu_load_result[i]);
                        $display("CPU_BRANCH_RESULT %0d %0d", i,
                                 cpu_branch_result[i]);
                        $display("CPU_X87_WAIT_REASON %0d %0d", i,
                                 cpu_x87_wait_reason[i]);
                    end
                    for (int i = 0; i < 2; i++)
                        for (int j = 0; j < 4; j++)
                            $display("CPU_LOAD_SUCCESSOR %0d %0d %0d", i, j,
                                     cpu_load_successor[i][j]);
                    for (int path = 0; path < 3; path++) begin
                        for (int interval = 0; interval < 17; interval++) begin
                            if (cpu_load_path_interval[path][interval] != 0)
                                $display("CPU_LOAD_PATH_INTERVAL %0d %0d %0d",
                                         path, interval,
                                         cpu_load_path_interval[path][interval]);
                        end
                        for (int dependency = 0; dependency < 4; dependency++) begin
                            if (cpu_load_path_successor_count[path][dependency] != 0)
                                $display("CPU_LOAD_PATH_SUCCESSOR %0d %0d %0d %0d",
                                         path, dependency,
                                         cpu_load_path_successor_count[path][dependency],
                                         cpu_load_path_successor_cycles[path][dependency]);
                        end
                        for (int entry = 0; entry < 4096; entry++) begin
                            if (cpu_load_next_entry_count[path][entry] != 0)
                                $display("CPU_LOAD_NEXT_ENTRY %0d %03x %0d %0d",
                                         path, entry,
                                         cpu_load_next_entry_count[path][entry],
                                         cpu_load_next_entry_cycles[path][entry]);
                        end
                        for (int addr32 = 0; addr32 < 2; addr32++)
                            for (int size = 0; size < 3; size++)
                                for (int ea_class = 0; ea_class < 3; ea_class++)
                                    for (int alignment = 0; alignment < 4;
                                         alignment++) begin
                                        if (cpu_load_form_count[path][addr32][size]
                                                               [ea_class][alignment] != 0)
                                            $display("CPU_LOAD_FORM %0d %0d %0d %0d %0d %0d %0d",
                                                path, addr32, size, ea_class,
                                                alignment,
                                                cpu_load_form_count[path][addr32][size]
                                                                   [ea_class][alignment],
                                                cpu_load_form_cycles[path][addr32][size]
                                                                    [ea_class][alignment]);
                                    end
                    end
                    for (int i = 0; i < 5; i++)
                        $display("CPU_REP_ELEMENTS %0d %0d", i,
                                 cpu_rep_elements[i]);
                    for (int i = 0; i < 17; i++)
                        $display("CPU_STORE_INTERVAL %0d %0d", i,
                                 cpu_store_intervals[i]);
                    for (int i = 0; i < 10; i++)
                        $display("CPU_STORE_STATE %0d %0d", i,
                                 cpu_store_states[i]);
                    for (int i = 0; i < 4096; i++) begin
                        if (cpu_store_next_entry[i] != 0)
                            $display("CPU_STORE_NEXT_ENTRY %03x %0d %0d %0d %0d",
                                     i, cpu_store_next_entry[i],
                                     cpu_store_next_entry_gap[i][1],
                                     cpu_store_next_entry_gap[i][2],
                                     cpu_store_next_entry_gap[i][3]);
                    end
                    for (int i = 0; i < 256; i++) begin
                        if (cpu_store_next_opcode[i] != 0)
                            $display("CPU_STORE_NEXT_OPCODE %02x %0d %0d %0d %0d",
                                     i, cpu_store_next_opcode[i],
                                     cpu_store_next_opcode_gap[i][1],
                                     cpu_store_next_opcode_gap[i][2],
                                     cpu_store_next_opcode_gap[i][3]);
                    end
                end
                    for (int range_index = 0; range_index < checksum_count; range_index++)
                        $display("  FNV64[%08x+%08x]: %016x",
                                 checksum_start[range_index], checksum_bytes[range_index],
                                 checksum[range_index]);
                    $display("  CS:EIP: %04X:%08X", dut.CS, dut.EIP);
                    $display("========================================");
                    #50;
                    $finish;
                end
            end

            // Test completed
            if (test_done) begin
                #50;
                $finish;
            end

            // Timeout
            if (cycle >= max_cycles) begin
                $display("");
                $display("========================================");
                $display("  TIMEOUT after %0d cycles", max_cycles);
                $display("  Test status: 0x%02X", test_status);
                $display("  Test data: 0x%08X", test_data);
                $display("  Instructions: %0d", instruction_count);
                $display("  CS:EIP: %04X:%08X", dut.CS, dut.EIP);
                $display("========================================");
                $finish;
            end

            // Fuzzing: +fuzz_irq_period=N raises INTR at random, about once
            // every N cycles while none is pending; INTA clears it as usual.
            if (fuzz_irq_period > 0 && !intr && !inta_first &&
                ($urandom % fuzz_irq_period) == 0)
                intr <= 1'b1;

            // Hardware interrupt signal generation
            // The load's first cycle, executed from the ROM or as a direct load
            // (whose ROM word does not execute).
            if (intr_hardwired_load_arm && dut.i_first && !dut.stall &&
                (dut.uc_addr == 12'h019) && dut.recipe_state.hardwired &&
                (dut.recipe_state.commit_sel == z486_pkg::RECIPE_COMMIT_MEM) &&
                dut.d2_vipt_candidate) begin
                intr_hardwired_load_arm <= 1'b0;
                intr <= 1'b1;
                if ($test$plusargs("trace_io"))
                    $display("[TB] INTR asserted during hardwired load at cycle %0d",
                             cycle);
            end

            if (intr_delay > 0) begin
                intr_delay <= intr_delay - 1;
                if (intr_delay == 1) begin
                    if (intr_request) begin
                        intr <= 1'b1;
                        intr_request <= 1'b0;
                        if ($test$plusargs("trace_io"))
                            $display("[TB] INTR asserted at cycle %0d", cycle);
                    end
                    if (nmi_request) begin
                        nmi <= 1'b1;
                        nmi_hold_count <= nmi_pulse_cycles;
                        nmi_request <= 1'b0;
                        if ($test$plusargs("trace_io"))
                            $display("[TB] NMI asserted at cycle %0d", cycle);
                    end
                end
            end

            // Deterministic trigger mode: count retired instructions.
            // This is useful for shadow-window tests (STI/MOV SS).
            if (instruction_boundary && !prev_instruction_boundary) begin
                if (intr_request && intr_instr_remaining > 0) begin
                    intr_instr_remaining <= intr_instr_remaining - 1;
                    if (intr_instr_remaining == 1) begin
                        intr <= 1'b1;
                        intr_request <= 1'b0;
                        if ($test$plusargs("trace_io"))
                            $display("[TB] INTR asserted at retired-instr=%0d (cycle %0d)",
                                     instruction_count + 1, cycle);
                    end
                end
                if (nmi_request && nmi_instr_remaining > 0) begin
                    nmi_instr_remaining <= nmi_instr_remaining - 1;
                    if (nmi_instr_remaining == 1) begin
                        nmi <= 1'b1;
                        nmi_hold_count <= nmi_pulse_cycles;
                        nmi_request <= 1'b0;
                        if ($test$plusargs("trace_io"))
                            $display("[TB] NMI asserted at retired-instr=%0d (cycle %0d)",
                                     instruction_count + 1, cycle);
                    end
                end
            end
            if (nmi_hold_count > 0) begin
                nmi_hold_count <= nmi_hold_count - 1;
                if (nmi_hold_count == 1)
                    nmi <= 1'b0;
            end

            // Check for HLT (can be disabled for HLT-wakeup interrupt tests)
            // Only an HLT that reached the halt bus cycle ends the test: one
            // above CPL 0 raises #GP instead (still F4 at its boundary).
            if (stop_on_hlt && dut.i.opcode == 8'hF4 && instruction_boundary && !prev_instruction_boundary &&
                hlt_halted) begin
                $display("");
                $display("========================================");
                $display("  HLT EXECUTED");
                $display("  Test status: 0x%02X", test_status);
                $display("  Test data: 0x%08X", test_data);
                $display("  Cycle: %0d", cycle);
                $display("  CS:EIP: %04X:%08X", dut.CS, dut.EIP);
                $display("========================================");
                #100;
                $finish;
            end

            // Optional progress
            if ($test$plusargs("progress") && (cycle % 1000000 == 0))
                $display("Progress: cycle=%0d instr=%0d", cycle, instruction_count);

            // Trace instructions
            // One line per D2 -> EX issue: cycle, EIP after the issue, ROM entry.
            if ($test$plusargs("trace_issue") && dut.i_issue && !dut.stall)
                $display("ISSUE %0d %08X %03X", cycle, dut.EIP, dut.issue_entry);
            // Architectural state as each instruction issues (reference
            // co-simulation): the data unit's capture view merges every GPR
            // write landing on this edge, eflags_fwd the pending flags.
            if ($test$plusargs("trace_state") && dut.i_issue && !dut.stall)
                $display("ST %0d %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X",
                         cycle, dut.EIP,
                         dut.data_unit_inst.gpr_capture_view[0], dut.data_unit_inst.gpr_capture_view[1],
                         dut.data_unit_inst.gpr_capture_view[2], dut.data_unit_inst.gpr_capture_view[3],
                         dut.forwarded_esp,
                         dut.data_unit_inst.gpr_capture_view[5], dut.data_unit_inst.gpr_capture_view[6],
                         dut.data_unit_inst.gpr_capture_view[7], dut.eflags_fwd);
            if ($test$plusargs("trace_instr") && instruction_boundary && !prev_instruction_boundary)
                $display("INSTR[%0d]: CS:EIP=%04X:%08X IR=%02X EAX=%08X",
                         instruction_count, dut.CS, dut.EIP, dut.i.opcode, dut.EAX);

            // Trace microcode execution
            if ($test$plusargs("trace_ucode") && !dut.stall)
                $display("UCODE pc=%03h dest=%02h src=%02h bus=%02h aluop=%02h SIGMA=%08h ESP=%08h IND=%08h CS=%04h wdata=%08h",
                         dut.uc_addr, dut.uc_dest, dut.uc_source, dut.uc_buscode, dut.uc_aluop,
                         dut.SIGMA, dut.ESP, dut.IND, dut.CS, dut.mem_wdata);

            // Trace paging
            if ($test$plusargs("trace_paging") && dut.mem_req_upcoming)
                $display("PAGING: linear=%08X servicing=%0d", dut.ind_linear, dut.mem_servicing);
        end
    end

    // +spec_check: an oracle for the prefetcher's branch-target buffer. When a
    // flush is seeded from a buffered line (spec_flush_hit), the bytes it
    // supplies from the target offset on must equal memory at the line's
    // CURRENT translation (CR3 tables in bench memory, the A20 mask). Skipped
    // while a store may still be outside memory (D-cache queue or lookup busy,
    // paging servicing a request), so a mismatch is a stale line, not a lag.
    // A program that edits a PTE without invalidating it may legitimately
    // trip it; the hazard fuzzers always invalidate.
    function automatic [31:0] tbm32(input [31:0] a);
        tbm32 = {mem[(a + 3) & (MEM_SIZE - 1)], mem[(a + 2) & (MEM_SIZE - 1)],
                 mem[(a + 1) & (MEM_SIZE - 1)], mem[a & (MEM_SIZE - 1)]};
    endfunction
    // An unsnooped platform write (port 0xC8 poke) is legally invisible to the
    // CPU's copies until the next platform flush completes; a snoop lands a
    // cycle late in the buffer. Neither is checked.
    reg [31:0] spec_pokes_seen = 0;
    bit        spec_ext_pending = 1'b0;
    always @(posedge cclk) begin
        if (platform_dma_pokes != spec_pokes_seen) begin
            spec_pokes_seen <= platform_dma_pokes;
            spec_ext_pending <= 1'b1;
        end else if (dut.memory_inst.cache_unit_inst.cache_flush_done_r)
            spec_ext_pending <= 1'b0;
    end
    always @(posedge cclk) if (spec_check_en && reset_n && dut.prefetch_inst.spec_flush_hit) begin : spec_oracle
        logic [31:0] lin, phys, pde, pte;
        logic [127:0] line;
        logic ok;
        lin = {dut.prefetch_inst.spec_addr, 4'h0};
        ok = 1'b1;
        phys = lin;
        if (dut.CR0[31]) begin
            pde = tbm32({dut.CR3[31:12], 12'h0} + {20'h0, lin[31:22], 2'b00});
            pte = tbm32({pde[31:12], 12'h0} + {20'h0, lin[21:12], 2'b00});
            ok = pde[0] && pte[0];
            phys = {pte[31:12], lin[11:0]};
        end
        if (!tb_a20)
            phys = phys & (PC98_MAP ? `Z486_PC98_A20_MASK_OFF : 32'hffef_ffff);
        if (!ok || dut.mem_servicing || spec_ext_pending || snoop_valid_h ||
            dut.pf_snoop_kill_r ||
            (dut.memory_inst.cache_unit_inst.dcache_inst.storeq_count != 0) ||
            (dut.memory_inst.cache_unit_inst.dcache_inst.state != 3'd1)) begin   // S_IDLE
            spec_skipped++;
        end else begin
            spec_checked++;
            line = dut.prefetch_inst.spec_hit_line;
            for (int b = 0; b < 16; b++)
                if (b >= dut.prefetch_inst.spec_off &&
                    line[8*b +: 8] !== mem[(phys + b) & (MEM_SIZE - 1)])
                    $fatal(1, "SPEC STALE: line %08x (phys %08x) byte %0d buffer %02x memory %02x",
                           lin, phys, b, line[8*b +: 8], mem[(phys + b) & (MEM_SIZE - 1)]);
        end
    end

endmodule

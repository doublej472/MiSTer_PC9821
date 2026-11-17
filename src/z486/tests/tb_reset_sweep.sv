`timescale 1ns/1ns

// Sweeps reset_n low for one cycle at every offset through a short program:
// i_first/fault_suppress_delay_slot/any_fault_r were never reset, so each pulse
// must still restart cleanly from the reset vector and reach the program end.
module tb_reset_sweep(
    // Set by the bench when the sweep has finished; the C++ main polls it,
    // and returns non-zero unless sweep_pass is set with it.  ($fatal cannot
    // carry the verdict here: sim_main_reset_sweep.cpp ignores the sim-only
    // checks a mid-instruction reset trips.)
    output reg sweep_done,
    output reg sweep_pass
);
    import z486_pkg::*;

    localparam integer MEM_SIZE  = 1 << 20;   // 1 MiB, reset vector 0xFFFF0 fits
    localparam integer RUN_LIMIT = 20000;     // per-offset completion budget

    reg clk = 0;
    always #5 clk = ~clk;

    reg reset_n = 0;

    wire [31:2] addr;
    wire [3:0]  be;
    wire [7:0]  burstcount;
    wire        line_read;
    reg  [31:0] din;
    wire [31:0] dout;
    wire        valid, write, io;
    reg         ready;
    reg         resp_valid;
    wire        inta;
    wire        triple_fault_reset;

    z486 dut (
        .clk(clk),
        .reset_n(reset_n),
        .device_mmio_enable(1'b0),
        .device_mmio_base(32'h0),
        .win0_unmapped(1'b0),
        .ram_cache_top(32'hffff_ffff),
        .addr(addr),
        .be(be),
        .burstcount(burstcount),
        .line_read(line_read),
        .din(din),
        .line_din(128'd0),
        .dout(dout),
        .valid(valid),
        .write(write),
        .io(io),
        .ready(ready),
        .resp_valid(resp_valid),
        .line_resp_valid(1'b0),
        .intr(1'b0),
        .nmi(1'b0),
        .inta(inta),
        .snoop_addr(32'h0),
        .snoop_valid(1'b0),
        .cache_flush(1'b0),
        .cache_flush_busy(),
        .cache_flush_done(),
        .a20_enable(1'b1),
        .fast_off_req(1'b0),
        .cache_off_req(1'b0),
        .x87_off_req(1'b0),
        .single_step(1'b0),
        .dbg_CS(),
        .dbg_EIP(),
        .dbg_CS_base(),
        .dbg_pe(),
        .dbg_vm(),
        .dbg_x87_state(),
        .triple_fault_reset(triple_fault_reset)
    );

    // Memory model (single-cycle ready/valid, one dword per resp_valid beat).
    reg [7:0]  mem [0:MEM_SIZE-1];

    reg [7:0]  rd_remaining = 8'd0;
    reg [31:0] rd_byte_addr = 32'h0;
    reg [7:0]  rd_index = 8'd0;
    wire rd_busy = (rd_remaining != 8'd0);

    reg marker_seen = 1'b0;
    reg [31:0] marker_value = 32'h0;

    always @(posedge clk) begin
        ready <= !rd_busy;
        resp_valid <= 1'b0;

        if (rd_remaining != 8'd0) begin
            reg [31:0] byte_addr;
            byte_addr = rd_byte_addr + {22'd0, rd_index, 2'b00};
            if (byte_addr >= MEM_SIZE)
                byte_addr = byte_addr & (MEM_SIZE - 1);
            resp_valid <= 1'b1;
            din <= {mem[byte_addr+3], mem[byte_addr+2],
                    mem[byte_addr+1], mem[byte_addr+0]};
            rd_index <= rd_index + 8'd1;
            rd_remaining <= rd_remaining - 8'd1;
        end

        if (valid && ready && !rd_busy) begin
            if (!write) begin
                reg [7:0]  burst_len;
                reg [31:0] byte_addr;
                burst_len = io ? 8'd1 : burstcount;
                byte_addr = {addr, 2'b00};
                if (byte_addr >= MEM_SIZE)
                    byte_addr = byte_addr & (MEM_SIZE - 1);
                rd_byte_addr <= byte_addr;
                rd_index <= 8'd1;
                resp_valid <= 1'b1;
                din <= io ? 32'hFFFF_FFFF
                          : {mem[byte_addr+3], mem[byte_addr+2],
                             mem[byte_addr+1], mem[byte_addr+0]};
                rd_remaining <= (burst_len <= 8'd1) ? 8'd0 : (burst_len - 8'd1);
                ready <= 1'b0;
            end else begin
                reg [31:0] byte_addr;
                byte_addr = {addr, 2'b00};
                ready <= 1'b1;
                if (byte_addr >= MEM_SIZE)
                    byte_addr = byte_addr & (MEM_SIZE - 1);
                if (be[0]) mem[byte_addr+0] <= dout[7:0];
                if (be[1]) mem[byte_addr+1] <= dout[15:8];
                if (be[2]) mem[byte_addr+2] <= dout[23:16];
                if (be[3]) mem[byte_addr+3] <= dout[31:24];
                // Program completion marker: the final store to linear 0x0500.
                if (!io && (byte_addr == 32'h0000_0500)) begin
                    marker_seen  <= 1'b1;
                    marker_value <= dout;
                end
            end
        end
    end

    // ---- Program image ----------------------------------------------------
    // Reset stub at the reset vector 0xFFFFFFF0 (masked into this 1 MiB RAM as
    // 0xFFFF0): far jump to 0x0000:0x1000.
    // Main program at 0x1000: counted loop, marker store, HLT.
    task automatic load_program();
        for (int i = 0; i < MEM_SIZE; i++)
            mem[i] = 8'h00;
        // jmp 0000:1000
        mem[20'hFFFF0] = 8'hEA;
        mem[20'hFFFF1] = 8'h00;
        mem[20'hFFFF2] = 8'h10;
        mem[20'hFFFF3] = 8'h00;
        mem[20'hFFFF4] = 8'h00;
        // mov ax, 0xBEEF
        mem[20'h01000] = 8'hB8; mem[20'h01001] = 8'hEF; mem[20'h01002] = 8'hBE;
        // mov bx, 0x1234
        mem[20'h01003] = 8'hBB; mem[20'h01004] = 8'h34; mem[20'h01005] = 8'h12;
        // mov cx, 0x0010
        mem[20'h01006] = 8'hB9; mem[20'h01007] = 8'h10; mem[20'h01008] = 8'h00;
        // loop: add ax, bx
        mem[20'h01009] = 8'h01; mem[20'h0100A] = 8'hD8;
        // sub ax, 1
        mem[20'h0100B] = 8'h2D; mem[20'h0100C] = 8'h01; mem[20'h0100D] = 8'h00;
        // dec cx
        mem[20'h0100E] = 8'h49;
        // jnz loop
        mem[20'h0100F] = 8'h75; mem[20'h01010] = 8'hF8;
        // mov [0x0500], ax
        mem[20'h01011] = 8'hA3; mem[20'h01012] = 8'h00; mem[20'h01013] = 8'h05;
        // hlt
        mem[20'h01014] = 8'hF4;
        // jmp $
        mem[20'h01015] = 8'hEB; mem[20'h01016] = 8'hFE;
    endtask

    task automatic tick();
        @(posedge clk);
        #1;
    endtask

    task automatic finish_sweep(input integer fails, input integer checked,
                                input integer clean);
        $display("");
        $display("  Reset-domain gap observation (holds through the reset cycle):");
        $display("    i_first:                    %0d/%0d high at reset, held through reset",
                 ifirst_held, ifirst_high);
        $display("    fault_suppress_delay_slot:  %0d/%0d high at reset, held through reset",
                 fsup_held, fsup_high);
        $display("    any_fault_r:                %0d/%0d high at reset, held through reset",
                 anyf_held, anyf_high);
        $display("  Swept offsets 1..%0d (%0d landed mid-program)", clean + 8, checked);
        $display("========================================");
        sweep_pass = fails == 0;
        if (fails == 0)
            $display("  TB_RESET_SWEEP: PASS - every mid-instruction reset restarted and completed correctly");
        else
            $display("  TB_RESET_SWEEP: FAIL - %0d offset(s) misbehaved", fails);
        $display("========================================");
        sweep_done = 1'b1;
    endtask

    // Direct evidence of the reset-domain gap: the three registers are not in
    // any reset clause, so when they are high at the reset edge they hold their
    // value instead of clearing. Count the holds across the sweep.
    integer ifirst_high, ifirst_held;
    integer fsup_high, fsup_held;
    integer anyf_high, anyf_held;
    logic   pre_ifirst, pre_fsup, pre_anyf;

    integer clean_len;
    integer offset;
    integer ran;
    integer mid_program_checks;
    integer fail_count;
    integer post_reset_len;
    logic   pre_marker;
    logic   completed;
    logic   value_ok;
    logic [15:0] expected_marker;

    initial begin
        sweep_done = 1'b0;
        sweep_pass = 1'b0;
        load_program();
        ready = 1'b1;
        resp_valid = 1'b0;
        din = 32'h0;

        $display("");
        $display("========================================");
        $display("  Reset-at-cycle sweep");
        $display("========================================");

        // Power-on reset.
        reset_n = 1'b0;
        repeat (10) tick();
        reset_n = 1'b1;

        // Measure the clean program length and its result value.
        marker_seen = 1'b0;
        clean_len = 0;
        while (!marker_seen && clean_len < RUN_LIMIT) begin
            tick();
            clean_len = clean_len + 1;
        end
        if (!marker_seen) begin
            $display("  CLEAN RUN FAILED to reach the program end within %0d cycles",
                     RUN_LIMIT);
            $display("  TB_RESET_SWEEP: FAIL");
            sweep_done = 1'b1;
        end else begin
            expected_marker = marker_value[15:0];
            $display("  Clean program length: %0d cycles, marker=0x%04X",
                     clean_len, expected_marker);

            fail_count = 0;
            mid_program_checks = 0;
            ifirst_high = 0; ifirst_held = 0;
            fsup_high = 0;   fsup_held = 0;
            anyf_high = 0;   anyf_held = 0;

            for (offset = 1; offset <= clean_len + 8; offset = offset + 1) begin
                // Fresh start.
                reset_n = 1'b0;
                repeat (10) tick();
                reset_n = 1'b1;
                marker_seen = 1'b0;

                // Run up to the chosen offset.
                for (ran = 0; ran < offset; ran = ran + 1)
                    tick();
                pre_marker = marker_seen;

                // Sample the three unreset registers just before the pulse.
                pre_ifirst = dut.i_first;
                pre_fsup   = dut.fault_suppress_delay_slot;
                pre_anyf   = dut.any_fault_r;

                // One-cycle reset at this offset, mid-program.
                reset_n = 1'b0;
                // Clear the marker so the post-reset run must earn it again.
                mem[20'h00500] = 8'h00;
                mem[20'h00501] = 8'h00;
                marker_seen = 1'b0;
                tick();
                // Still reset_n=0 here. A reset-domain register would read 0;
                // these keep their pre-reset value.
                if (pre_ifirst) begin
                    ifirst_high = ifirst_high + 1;
                    if (dut.i_first) ifirst_held = ifirst_held + 1;
                end
                if (pre_fsup) begin
                    fsup_high = fsup_high + 1;
                    if (dut.fault_suppress_delay_slot) fsup_held = fsup_held + 1;
                end
                if (pre_anyf) begin
                    anyf_high = anyf_high + 1;
                    if (dut.any_fault_r) anyf_held = anyf_held + 1;
                end
                reset_n = 1'b1;

                completed = 1'b0;
                for (post_reset_len = 0;
                     (post_reset_len < RUN_LIMIT) && !completed;
                     post_reset_len = post_reset_len + 1) begin
                    tick();
                    if (marker_seen)
                        completed = 1'b1;
                end

                if (!completed) begin
                    fail_count = fail_count + 1;
                    $display("  RESET @cycle %0d: did NOT reach the program end ",
                             offset);
                end else if (!pre_marker) begin
                    mid_program_checks = mid_program_checks + 1;
                    value_ok = ({mem[20'h00501], mem[20'h00500]} === expected_marker);
                    if (!value_ok) begin
                        fail_count = fail_count + 1;
                        $display("  RESET @cycle %0d: completed but WRONG value 0x%04X (want 0x%04X)",
                                 offset, {mem[20'h00501], mem[20'h00500]},
                                 expected_marker);
                    end
                end
            end

            finish_sweep(fail_count, mid_program_checks, clean_len);
        end
    end

endmodule

// Full-core PC-98 memory-map test: directed real-mode programs read, write and
// fetch from each enabled window and check the external port for a 4-beat line
// fill (cacheable) / single-beat direct access (DIRECT / NO_ALLOC).
`timescale 1ns/1ns
`include "z486_pc98_preset.svh"

module tb_pc98_map;
    // 32 MiB backing store; the model decodes only the low 25 address bits.
    localparam integer MEM_SIZE = 1 << 25;
    localparam [31:0]  MEM_MASK = MEM_SIZE - 1;

    // One target address per enabled window (all 16-byte line aligned).
    localparam [31:0] A_RAM      = 32'h0000_2000;  // ordinary cacheable RAM
    localparam [31:0] A_APERTURE = 32'h000A_0000;  // A0000-FFFFF device aperture (+ VGA window)
    localparam [31:0] A_ALIAS0   = 32'h00F0_0000;  // alias window 0
    localparam [31:0] A_HIRAM    = 32'h0100_0000;  // extended RAM at 16 MiB (cacheable)
    localparam [31:0] A_RAM96    = 32'h05FF_FFF0;  // last line below 96 MiB (cacheable)
    localparam [31:0] A_NOALLOC  = `Z486_PC98_NO_ALLOC_BOUND;  // at the no-allocate bound
    localparam [31:0] A_ALIAS1   = 32'hFFF0_0000;  // alias window 1 (above the bound)
    localparam [31:0] A_WIN0     = 32'h0008_0000;  // window 0 (unmapped -> no-alloc)
    localparam [31:0] A_ALIAS2   = 32'hFFFF_8000;  // alias window 2 (above the bound)

    // Store / RMW targets; the RMW sits one DWORD after the store.
    localparam [31:0] W_RAM = A_RAM;
    localparam [31:0] W_AP  = A_APERTURE;
    localparam [31:0] W_AL0 = A_ALIAS0;
    localparam [31:0] W_HR  = A_HIRAM;
    localparam [31:0] W_R96 = A_RAM96;
    localparam [31:0] W_NA  = 32'h0800_1000;
    localparam [31:0] W_AL1 = A_ALIAS1;
    localparam [31:0] W_W0  = A_WIN0;
    localparam [31:0] W_AL2 = A_ALIAS2;

    // Runtime win0_unmapped toggle lines, all inside 0x80000-0x9FFFF.
    localparam [31:0] W0_OFF1 = 32'h0008_0040;
    localparam [31:0] W0_ON   = 32'h0008_0050;
    localparam [31:0] W0_OFF2 = 32'h0008_0060;

    // A20 wrap phase: raw 0x0010_5000 masks to 0x0000_5000 when A20 is off.
    localparam [31:0] A20_RAW  = 32'h0010_5000;
    localparam [31:0] A20_WRAP = 32'h0000_5000;

    // Self-modifying-code phase: a code buffer and a marker word, both inside
    // the A0000-FFFFF DIRECT aperture above the VGA window (BFFFF).
    localparam [31:0] SMC_CODE = 32'h000C_0000;
    localparam [31:0] SMC_MARK = 32'h000C_0800;
    localparam integer SMC_MARK_OFF = 32'h000C_0800;

    // Snoop-train phase: two more DIRECT-aperture code lines, one marker target
    // per routine (cacheable low RAM so the routines' own marker stores take the
    // cached path).  Each routine starts at line+2 so the imm32 it is patched
    // through lands at line+8, a naturally aligned dword: the bench watches the
    // patch stores by bus address, and memory.sv forwards that address to the
    // I-cache unchanged.
    localparam [31:0] DWL_LINE_A = 32'h000C_1000;
    localparam [31:0] DWL_LINE_B = 32'h000C_1100;
    localparam [31:0] DWL_ENTRY_A = DWL_LINE_A + 2;
    localparam [31:0] DWL_ENTRY_B = DWL_LINE_B + 2;
    localparam [31:0] DWL_IMM_A  = DWL_LINE_A + 8;
    localparam [31:0] DWL_IMM_B  = DWL_LINE_B + 8;
    localparam [31:0] DWL_MARK_A = 32'h0000_1000;
    localparam [31:0] DWL_MARK_B = 32'h0000_1010;
    // Port the program writes to arm the external snoop train, and the address
    // the train snoops (never fetched or loaded, and in a different I$-set than
    // the two patched lines).
    localparam [31:0] IO_SNOOP_ARM = 32'h0000_00E0;
    localparam [31:0] SNOOP_LINE   = 32'h0040_0F00;
    // Expiry of the train, in cycles from the arming port write.  It must outlast
    // the whole patch sequence on the unfixed logic (where the second store is
    // accepted inside the train and ends it early) and it is the only way out on
    // the fixed logic, where the second store waits for the snoop to drop.
    localparam integer SNOOP_TRAIN_MAX = 400;

    // Instruction-fetch targets and their backing-store offsets.
    localparam [31:0] IF_NA = 32'h0800_3000;
    localparam [31:0] IF_W0 = 32'h0008_2000;
    localparam [31:0] IF_HR = 32'h0100_3000;
    localparam integer IF_NA_OFF = 32'h0000_3000;
    localparam integer IF_HR_OFF = 32'h0100_3000;
    localparam integer IF_W0_OFF = 32'h0008_2000;

    // I/O ports the bench decodes to drive the runtime window controls.
    localparam [31:0] IO_A20_OFF = 32'h0000_00F0;
    localparam [31:0] IO_A20_ON  = 32'h0000_00F4;
    localparam [31:0] IO_WIN0_UM = 32'h0000_00F8;
    localparam [31:0] IO_WIN0_M  = 32'h0000_00FC;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset_n = 1'b0;

    // External bus.
    wire [31:2] addr;
    wire  [3:0] be;
    wire  [7:0] burstcount;
    wire [31:0] dout;
    wire        valid, write, io, line_read;
    reg  [31:0] din = 32'h0;
    reg         model_ready = 1'b0;
    integer     write_wait = 0;
    integer     write_wait_count = 0;
    initial void'($value$plusargs("write_wait=%d", write_wait));
    wire        ready = model_ready &&
                        (!(valid && write && !io) || write_wait_count >= write_wait);
    always @(posedge clk) begin
        if (!reset_n || !valid || (valid && ready))
            write_wait_count <= 0;
        else if (write && !io)
            write_wait_count <= write_wait_count + 1;
    end

    // One invalidate in the first bus-valid cycle, independent of acceptance.
    reg expect_direct_inval = 1'b0;
    always @(posedge clk) begin
        if (!reset_n)
            expect_direct_inval <= 1'b0;
        else begin
            if (dut.memory_inst.bus_unit_inst.icache_direct_inval !==
                expect_direct_inval)
                $fatal(1, "DIRECT invalidate not a launch pulse (ready=%b)", ready);
            expect_direct_inval <= !dut.memory_inst.bus_unit_inst.ext_valid_r &&
                                   dut.memory_inst.bus_unit_inst.ext_direct_launch &&
                                   dut.memory_inst.bus_unit_inst.dcache_req_direct_inval;
        end
    end
    reg         resp_valid = 1'b0;
    wire        inta;

    // Window 0 starts unmapped; A20 starts enabled.
    reg win0_unmapped = 1'b1;
    reg a20_enable = 1'b1;

    // External snoop train (phase 9).  The program arms it with an OUT; the
    // train then stays asserted until the second DIRECT-window patch write is
    // accepted or the window expires.  A held snoop is what strands the first
    // direct-write invalidate in memory.sv's one-entry pending slot.
    reg         snoop_valid = 1'b0;
    reg  [31:0] snoop_addr  = SNOOP_LINE;
    integer     snoop_hold  = 0;
    integer     snoop_len   = 0;   // length of the last completed train
    // Phase-9 observations.
    integer snoop_a_in_train = 0;  // patch write to line A accepted during the train
    integer snoop_b_in_train = 0;  // ... and to line B (unfixed logic only)
    integer snoop_held_cycles = 0; // cycles the queued invalidate was stranded

    z486 #(
        `Z486_PC98_MAP_PARAMS
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .device_mmio_enable(1'b0),
        .device_mmio_base(32'h0),
        .win0_unmapped(win0_unmapped),
        .ram_cache_top(32'hffff_ffff),
        .addr(addr),
        .be(be),
        .burstcount(burstcount),
        .line_read(line_read),
        .din(din),
        .line_din(128'd0),
        .dout(dout),
        .valid(valid),
        .ready(ready),
        .write(write),
        .io(io),
        .resp_valid(resp_valid),
        .line_resp_valid(1'b0),
        .intr(1'b0),
        .nmi(1'b0),
        .inta(inta),
        .snoop_addr(snoop_addr),
        .snoop_valid(snoop_valid),
        .cache_flush(1'b0),
        .cache_flush_busy(),
        .cache_flush_done(),
        .a20_enable(a20_enable),
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
        .triple_fault_reset()
    );

    reg [7:0] mem [0:MEM_SIZE-1];
    integer prog_pc = 0;

    // Per-target line-fill vs single-beat counts on the external port.
    integer ram_fill_n = 0, ram_single_n = 0;
    integer ap_fill_n = 0,  ap_single_n = 0;
    integer al_fill_n = 0,  al_single_n = 0;
    integer na_fill_n = 0,  na_single_n = 0;
    integer hr_fill_n = 0,  hr_single_n = 0;
    integer r96_fill_n = 0, r96_single_n = 0;
    integer al1_fill_n = 0, al1_single_n = 0;
    integer w0_fill_n = 0,  w0_single_n = 0;
    integer al2_fill_n = 0, al2_single_n = 0;
    // Store / RMW write counts per window.
    integer wr_ram = 0, wr_ap = 0, wr_al0 = 0, wr_hr = 0, wr_r96 = 0;
    integer wr_na = 0, wr_al1 = 0, wr_w0 = 0, wr_al2 = 0;
    // Fast (RMW) store acceptance counts.
    integer fs_ram = 0, fs_hr = 0, fs_r96 = 0, fs_other = 0;
    integer ps_ram = 0, ps_hr = 0, ps_r96 = 0, ps_other = 0;
    // win0_unmapped runtime toggle phase.
    integer w0off1_single_n = 0, w0off1_fill_n = 0;
    integer w0on_fill_n = 0, w0on_single_n = 0;
    integer w0off2_single_n = 0, w0off2_fill_n = 0;
    // A20 wrap phase.
    integer a20on_fill_n = 0, a20on_single_n = 0;
    integer a20off_fill_n = 0, a20off_single_n = 0;
    // Instruction-fetch phases.
    integer ifna_fill_n = 0, ifna_single_n = 0;
    integer ifw0_fill_n = 0, ifw0_single_n = 0;
    integer ifhr_fill_n = 0, ifhr_single_n = 0;
    // Snoop-train phase: aperture line fills for the two patched code lines.
    integer dwla_fill_n = 0, dwla_single_n = 0;
    integer dwlb_fill_n = 0, dwlb_single_n = 0;

    always @(posedge clk) begin
        if (reset_n && valid && ready) begin
            if (write) begin
                case ({addr, 2'b00})
                    W_RAM:      wr_ram <= wr_ram + 1;
                    W_RAM + 4:  wr_ram <= wr_ram + 1;
                    W_AP:       wr_ap <= wr_ap + 1;
                    W_AP + 4:   wr_ap <= wr_ap + 1;
                    W_AL0:      wr_al0 <= wr_al0 + 1;
                    W_AL0 + 4:  wr_al0 <= wr_al0 + 1;
                    W_HR:       wr_hr <= wr_hr + 1;
                    W_HR + 4:   wr_hr <= wr_hr + 1;
                    W_R96:      wr_r96 <= wr_r96 + 1;
                    W_R96 + 4:  wr_r96 <= wr_r96 + 1;
                    W_NA:       wr_na <= wr_na + 1;
                    W_NA + 4:   wr_na <= wr_na + 1;
                    W_AL1:      wr_al1 <= wr_al1 + 1;
                    W_AL1 + 4:  wr_al1 <= wr_al1 + 1;
                    W_W0:       wr_w0 <= wr_w0 + 1;
                    W_W0 + 4:   wr_w0 <= wr_w0 + 1;
                    W_AL2:      wr_al2 <= wr_al2 + 1;
                    W_AL2 + 4:  wr_al2 <= wr_al2 + 1;
                    default: ;
                endcase
            end else begin
                case ({addr, 2'b00})
                    A_RAM:      if (line_read) ram_fill_n <= ram_fill_n + 1;
                                else         ram_single_n <= ram_single_n + 1;
                    A_APERTURE: if (line_read) ap_fill_n <= ap_fill_n + 1;
                                else         ap_single_n <= ap_single_n + 1;
                    A_ALIAS0:   if (line_read) al_fill_n <= al_fill_n + 1;
                                else         al_single_n <= al_single_n + 1;
                    A_NOALLOC:  if (line_read) na_fill_n <= na_fill_n + 1;
                                else         na_single_n <= na_single_n + 1;
                    A_HIRAM:    if (line_read) hr_fill_n <= hr_fill_n + 1;
                                else         hr_single_n <= hr_single_n + 1;
                    A_RAM96:    if (line_read) r96_fill_n <= r96_fill_n + 1;
                                else         r96_single_n <= r96_single_n + 1;
                    A_ALIAS1:   if (line_read) al1_fill_n <= al1_fill_n + 1;
                                else         al1_single_n <= al1_single_n + 1;
                    A_WIN0:     if (line_read) w0_fill_n <= w0_fill_n + 1;
                                else         w0_single_n <= w0_single_n + 1;
                    A_ALIAS2:   if (line_read) al2_fill_n <= al2_fill_n + 1;
                                else         al2_single_n <= al2_single_n + 1;
                    W0_OFF1:    if (line_read) w0off1_fill_n <= w0off1_fill_n + 1;
                                else         w0off1_single_n <= w0off1_single_n + 1;
                    W0_ON:      if (line_read) w0on_fill_n <= w0on_fill_n + 1;
                                else         w0on_single_n <= w0on_single_n + 1;
                    W0_OFF2:    if (line_read) w0off2_fill_n <= w0off2_fill_n + 1;
                                else         w0off2_single_n <= w0off2_single_n + 1;
                    A20_RAW:    if (line_read) a20on_fill_n <= a20on_fill_n + 1;
                                else         a20on_single_n <= a20on_single_n + 1;
                    A20_WRAP:   if (line_read) a20off_fill_n <= a20off_fill_n + 1;
                                else         a20off_single_n <= a20off_single_n + 1;
                    IF_NA:      if (line_read) ifna_fill_n <= ifna_fill_n + 1;
                                else         ifna_single_n <= ifna_single_n + 1;
                    IF_W0:      if (line_read) ifw0_fill_n <= ifw0_fill_n + 1;
                                else         ifw0_single_n <= ifw0_single_n + 1;
                    IF_HR:      if (line_read) ifhr_fill_n <= ifhr_fill_n + 1;
                                else         ifhr_single_n <= ifhr_single_n + 1;
                    DWL_LINE_A: if (line_read) dwla_fill_n <= dwla_fill_n + 1;
                                else         dwla_single_n <= dwla_single_n + 1;
                    DWL_LINE_B: if (line_read) dwlb_fill_n <= dwlb_fill_n + 1;
                                else         dwlb_single_n <= dwlb_single_n + 1;
                    default: ;
                endcase
            end
        end
    end

    // Snoop-train generator for phase 9.  Arming the port asserts snoop_valid on
    // the following cycle for at least the whole patch sequence; the train ends
    // early once the second patch write is accepted (which only happens while
    // the snoop holds the invalidate port, i.e. on the unfixed logic).
    always @(posedge clk) begin
        if (!reset_n) begin
            snoop_hold <= 0;
            snoop_valid <= 1'b0;
        end else begin
            if (valid && ready && write && io && ({addr, 2'b00} == IO_SNOOP_ARM))
                snoop_hold <= SNOOP_TRAIN_MAX;
            else if (snoop_valid && valid && ready && write && !io &&
                     ({addr, 2'b00} == DWL_IMM_B))
                snoop_hold <= 0;
            else if (snoop_hold > 0)
                snoop_hold <= snoop_hold - 1;
            snoop_valid <= (snoop_hold > 0);
            if (snoop_valid)
                snoop_len <= snoop_len + 1;
            if (snoop_valid && valid && ready && write && !io &&
                ({addr, 2'b00} == DWL_IMM_A))
                snoop_a_in_train <= snoop_a_in_train + 1;
            if (snoop_valid && valid && ready && write && !io &&
                ({addr, 2'b00} == DWL_IMM_B))
                snoop_b_in_train <= snoop_b_in_train + 1;
            if (dut.memory_inst.bus_unit_inst.icache_direct_inval_held)
                snoop_held_cycles <= snoop_held_cycles + 1;
        end
    end

    // Track the direct store port by physical address: the cached RMW's write
    // (fs_*, at rmw_fast_phys_r) and a posted plain store (ps_*, data_access
    // st_take at st_phys) - the two sources of fast_store_valid.
    always @(posedge clk) begin
        if (reset_n && dut.fast_store_valid && dut.st_take) begin
            case (dut.st_phys)
                W_RAM:   ps_ram <= ps_ram + 1;
                W_HR:    ps_hr <= ps_hr + 1;
                W_R96:   ps_r96 <= ps_r96 + 1;
                default: ps_other <= ps_other + 1;
            endcase
        end else if (reset_n && dut.fast_store_valid) begin
            case (dut.rmw_fast_phys_r)
                W_RAM + 4: fs_ram <= fs_ram + 1;
                W_HR + 4:  fs_hr <= fs_hr + 1;
                W_R96 + 4: fs_r96 <= fs_r96 + 1;
                default:   fs_other <= fs_other + 1;
            endcase
        end
    end

    // Runtime window controls: directed programs write these decoded I/O ports.
    always @(posedge clk) begin
        if (reset_n && valid && ready && write && io) begin
            case ({addr, 2'b00})
                IO_A20_OFF: a20_enable <= 1'b0;
                IO_A20_ON:  a20_enable <= 1'b1;
                IO_WIN0_UM: win0_unmapped <= 1'b1;
                IO_WIN0_M:  win0_unmapped <= 1'b0;
                default: ;
            endcase
        end
    end

    // External memory model (mirrors tb_z486): single-cycle ready when idle.
    reg         read_active = 1'b0;
    reg  [31:0] read_base = 32'h0;
    reg  [7:0]  read_remaining = 8'd0;
    reg  [7:0]  read_index = 8'd0;

    always @(posedge clk) begin
        if (!reset_n) begin
            model_ready <= 1'b0;
            resp_valid <= 1'b0;
            read_active <= 1'b0;
            read_remaining <= 8'd0;
            read_index <= 8'd0;
        end else begin
        model_ready <= !read_active;
        resp_valid <= 1'b0;
        din <= 32'h0;

        if (read_active) begin
            resp_valid <= 1'b1;
            din <= {mem[(read_base + {22'h0, read_index, 2'b00} + 3) & MEM_MASK],
                    mem[(read_base + {22'h0, read_index, 2'b00} + 2) & MEM_MASK],
                    mem[(read_base + {22'h0, read_index, 2'b00} + 1) & MEM_MASK],
                    mem[(read_base + {22'h0, read_index, 2'b00} + 0) & MEM_MASK]};
            read_index <= read_index + 8'd1;
            read_remaining <= read_remaining - 8'd1;
            if (read_remaining == 8'd1)
                read_active <= 1'b0;
        end

        if (valid && ready && !read_active) begin
            if (!write) begin
                if (io) begin
                    resp_valid <= 1'b1;
                    din <= 32'hFFFF_FFFF;
                end else begin
                    reg [31:0] byte_addr;
                    reg  [7:0] burst_len;
                    byte_addr = {addr, 2'b00} & MEM_MASK;
                    burst_len = (burstcount == 8'd0) ? 8'd1 : burstcount;
                    resp_valid <= 1'b1;
                    din <= {mem[byte_addr + 3], mem[byte_addr + 2],
                            mem[byte_addr + 1], mem[byte_addr + 0]};
                    model_ready <= (burst_len <= 8'd1);
                    read_active <= (burst_len > 8'd1);
                    read_base <= byte_addr;
                    read_remaining <= (burst_len > 8'd1) ? (burst_len - 8'd1) : 8'd0;
                    read_index <= 8'd1;
                end
            end else if (!io) begin
                reg [31:0] byte_addr;
                byte_addr = {addr, 2'b00} & MEM_MASK;
                if (be[0]) mem[byte_addr+0] <= dout[7:0];
                if (be[1]) mem[byte_addr+1] <= dout[15:8];
                if (be[2]) mem[byte_addr+2] <= dout[23:16];
                if (be[3]) mem[byte_addr+3] <= dout[31:24];
            end
        end
        end
    end

    // Program builders; all memory references are absolute moffs32.
    task automatic emit_load_eax(input [31:0] target);
        begin
            mem[prog_pc+0] = 8'h8b;
            mem[prog_pc+1] = 8'h05;
            mem[prog_pc+2] = target[7:0];
            mem[prog_pc+3] = target[15:8];
            mem[prog_pc+4] = target[23:16];
            mem[prog_pc+5] = target[31:24];
            prog_pc = prog_pc + 6;
        end
    endtask

    // mov dword [moffs32], eax
    task automatic emit_store_eax(input [31:0] target);
        begin
            mem[prog_pc+0] = 8'h89;
            mem[prog_pc+1] = 8'h05;
            mem[prog_pc+2] = target[7:0];
            mem[prog_pc+3] = target[15:8];
            mem[prog_pc+4] = target[23:16];
            mem[prog_pc+5] = target[31:24];
            prog_pc = prog_pc + 6;
        end
    endtask

    // add dword [moffs32], eax  (the RMW_FAST m-r overlay)
    task automatic emit_add_mem_eax(input [31:0] target);
        begin
            mem[prog_pc+0] = 8'h01;
            mem[prog_pc+1] = 8'h05;
            mem[prog_pc+2] = target[7:0];
            mem[prog_pc+3] = target[15:8];
            mem[prog_pc+4] = target[23:16];
            mem[prog_pc+5] = target[31:24];
            prog_pc = prog_pc + 6;
        end
    endtask

    // inc dword [moffs32]  (the RMW_FAST unary overlay)
    task automatic emit_inc_mem(input [31:0] target);
        begin
            mem[prog_pc+0] = 8'hff;
            mem[prog_pc+1] = 8'h05;
            mem[prog_pc+2] = target[7:0];
            mem[prog_pc+3] = target[15:8];
            mem[prog_pc+4] = target[23:16];
            mem[prog_pc+5] = target[31:24];
            prog_pc = prog_pc + 6;
        end
    endtask

    // out imm8, al
    task automatic emit_out_al(input [7:0] port);
        begin
            mem[prog_pc+0] = 8'hE6;
            mem[prog_pc+1] = port;
            prog_pc = prog_pc + 2;
        end
    endtask

    task automatic emit_nop;
        begin
            mem[prog_pc] = 8'h90;
            prog_pc = prog_pc + 1;
        end
    endtask

    task automatic emit_hlt;
        begin
            mem[prog_pc] = 8'hF4;
            prog_pc = prog_pc + 1;
        end
    endtask

    // Position-independent fetch loop: mov ecx,n; dec ecx; jnz back; hlt.
    task automatic emit_fetch_block(input integer off, input integer n);
        begin
            mem[off+0] = 8'hB9;
            mem[off+1] = n[7:0];
            mem[off+2] = n[15:8];
            mem[off+3] = n[23:16];
            mem[off+4] = n[31:24];
            mem[off+5] = 8'h49;   // dec ecx
            mem[off+6] = 8'h75;   // jnz -3
            mem[off+7] = 8'hFD;
            mem[off+8] = 8'hF4;   // hlt
        end
    endtask

    // mov dword [moffs32], imm32
    task automatic emit_store_imm(input [31:0] target, input [31:0] imm);
        begin
            mem[prog_pc+0] = 8'hC7;
            mem[prog_pc+1] = 8'h05;
            mem[prog_pc+2] = target[7:0];
            mem[prog_pc+3] = target[15:8];
            mem[prog_pc+4] = target[23:16];
            mem[prog_pc+5] = target[31:24];
            mem[prog_pc+6] = imm[7:0];
            mem[prog_pc+7] = imm[15:8];
            mem[prog_pc+8] = imm[23:16];
            mem[prog_pc+9] = imm[31:24];
            prog_pc = prog_pc + 10;
        end
    endtask

    // call rel32
    task automatic emit_call_rel32(input [31:0] target);
        reg [31:0] rel;
        begin
            rel = target - (prog_pc + 5);
            mem[prog_pc+0] = 8'hE8;
            mem[prog_pc+1] = rel[7:0];
            mem[prog_pc+2] = rel[15:8];
            mem[prog_pc+3] = rel[23:16];
            mem[prog_pc+4] = rel[31:24];
            prog_pc = prog_pc + 5;
        end
    endtask

    // Pre-load the DIRECT-window routine
    //   mov dword [mark], imm32   (C7 05 <mark32> <imm32>)
    //   ret                       (C3)
    // at line+2 of a 16-byte aperture line.  The whole line is written so a
    // later aligned one-dword store to line+8 (the imm32) is the only change the
    // I-cache can miss, and the line holds no other instruction bytes the test
    // depends on.
    task automatic load_dwl_routine(input [31:0] line, input [31:0] mark,
                                    input [31:0] imm);
        begin
            for (integer n = 0; n < 16; n = n + 1)
                mem[line + n] = 8'h00;
            mem[line + 2]  = 8'hC7;
            mem[line + 3]  = 8'h05;
            mem[line + 4]  = mark[7:0];
            mem[line + 5]  = mark[15:8];
            mem[line + 6]  = mark[23:16];
            mem[line + 7]  = mark[31:24];
            mem[line + 8]  = imm[7:0];
            mem[line + 9]  = imm[15:8];
            mem[line + 10] = imm[23:16];
            mem[line + 11] = imm[31:24];
            mem[line + 12] = 8'hC3;
        end
    endtask

    // Have the running program write the 11-byte routine
    //   mov dword [SMC_MARK], imm   (C7 05 <mark> <imm>)
    //   ret                         (C3)
    // into the DIRECT code buffer at 'target' using three dword stores.
    task automatic emit_smc_program(input [31:0] target, input [31:0] imm);
        begin
            emit_store_imm(target + 0, {SMC_MARK[15:8], SMC_MARK[7:0], 8'h05, 8'hC7});
            emit_store_imm(target + 4, {imm[15:8], imm[7:0], SMC_MARK[31:24], SMC_MARK[23:16]});
            emit_store_imm(target + 8, {8'h00, 8'hC3, imm[31:24], imm[23:16]});
        end
    endtask

    // Directed run: reset into real mode with flat segments, then wait for HLT.
    integer errors = 0;
    reg [31:0] smc_mark;
    reg [31:0] dwl_mark_a;
    reg [31:0] dwl_mark_b;

    z486_pkg::seg_desc_t cs_desc;
    z486_pkg::seg_desc_t ds_desc;

    task automatic core_reset(input [31:0] start_eip);
        begin
            reset_n = 1'b0;
            #30;

            // 32-bit flat code segment so a program can run from any physical
            // address, including the extended-RAM and NO_ALLOC fetch targets.
            cs_desc = z486_pkg::seg_desc_real_mode_code(16'h0000);
            cs_desc.D_B = 1'b1;
            cs_desc.limit = 20'hfffff;
            cs_desc.G = 1'b1;
            force dut.seg_unit.seg_init_cs = cs_desc;
            // Flat data segment: base 0, 4 GiB limit (G=1).
            ds_desc = z486_pkg::seg_desc_real_mode(16'h0000);
            ds_desc.limit = 20'hfffff;
            ds_desc.G = 1'b1;
            force dut.seg_unit.seg_init_ds = ds_desc;
            force dut.seg_unit.seg_init_es = z486_pkg::seg_desc_real_mode(16'h0000);
            force dut.seg_unit.seg_init_ss = z486_pkg::seg_desc_real_mode(16'h0000);
            force dut.seg_unit.seg_init_fs = z486_pkg::seg_desc_real_mode(16'h0000);
            force dut.seg_unit.seg_init_gs = z486_pkg::seg_desc_real_mode(16'h0000);
            force dut.CR0 = 32'h0;
            force dut.CS = 16'h0000;
            force dut.DS = 16'h0000;
            force dut.ES = 16'h0000;
            force dut.SS = 16'h0000;
            force dut.EIP = start_eip;
            force dut.prefetch_inst.pf_fetch_addr = start_eip;

            #50;
            reset_n = 1'b1;
            release dut.CR0;
            release dut.CS;
            release dut.DS;
            release dut.ES;
            release dut.SS;
            release dut.EIP;
            release dut.prefetch_inst.pf_fetch_addr;
            release dut.seg_unit.seg_init_cs;
            release dut.seg_unit.seg_init_ds;
            release dut.seg_unit.seg_init_es;
            release dut.seg_unit.seg_init_ss;
            release dut.seg_unit.seg_init_fs;
            release dut.seg_unit.seg_init_gs;
        end
    endtask

    task automatic run_to_hlt(input string name);
        integer c;
        begin
            c = 0;
            while (c < 40000 && !dut.stall_wio) begin
                @(posedge clk);
                c = c + 1;
            end
            if (c >= 40000) begin
                $display("PC98 MAP TEST FAIL: %s timeout (halted=%b)", name, dut.stall_wio);
                $fatal(1);
            end
            $display("PHASE_CYCLES %s: %0d", name, c);
            // Drain posted stores before sampling the transaction counters.
            c = 0;
            while (c < 500 && !dut.memory_inst.dcache_stores_drained) begin
                @(posedge clk);
                c = c + 1;
            end
            repeat (20) @(posedge clk);
        end
    endtask

    task automatic clear_counts;
        begin
            ram_fill_n = 0; ram_single_n = 0;
            ap_fill_n = 0;  ap_single_n = 0;
            al_fill_n = 0;  al_single_n = 0;
            na_fill_n = 0;  na_single_n = 0;
            hr_fill_n = 0;  hr_single_n = 0;
            r96_fill_n = 0; r96_single_n = 0;
            al1_fill_n = 0; al1_single_n = 0;
            w0_fill_n = 0;  w0_single_n = 0;
            al2_fill_n = 0; al2_single_n = 0;
            wr_ram = 0; wr_ap = 0; wr_al0 = 0; wr_hr = 0; wr_r96 = 0;
            wr_na = 0; wr_al1 = 0; wr_w0 = 0; wr_al2 = 0;
            fs_ram = 0; fs_hr = 0; fs_r96 = 0; fs_other = 0;
            ps_ram = 0; ps_hr = 0; ps_r96 = 0; ps_other = 0;
            w0off1_single_n = 0; w0off1_fill_n = 0;
            w0on_fill_n = 0; w0on_single_n = 0;
            w0off2_single_n = 0; w0off2_fill_n = 0;
            a20on_fill_n = 0; a20on_single_n = 0;
            a20off_fill_n = 0; a20off_single_n = 0;
            ifna_fill_n = 0; ifna_single_n = 0;
            ifw0_fill_n = 0; ifw0_single_n = 0;
            ifhr_fill_n = 0; ifhr_single_n = 0;
            dwla_fill_n = 0; dwla_single_n = 0;
            dwlb_fill_n = 0; dwlb_single_n = 0;
            snoop_len = 0;
            snoop_a_in_train = 0;
            snoop_b_in_train = 0;
            snoop_held_cycles = 0;
        end
    endtask

    task automatic check_int(input string name, input integer got, input integer want);
        begin
            if (got !== want) begin
                $display("FAIL %s: got %0d want %0d", name, got, want);
                errors = errors + 1;
            end else
                $display("ok   %s", name);
        end
    endtask

    task automatic check_ge(input string name, input integer got, input integer want);
        begin
            if (got < want) begin
                $display("FAIL %s: got %0d want >= %0d", name, got, want);
                errors = errors + 1;
            end else
                $display("ok   %s", name);
        end
    endtask

    initial begin
        for (integer n = 0; n < MEM_SIZE; n = n + 1)
            mem[n] = 8'h0;

        // Phase 1: data loads from every enabled window.
        clear_counts();
        prog_pc = 0;
        emit_load_eax(A_RAM);
        emit_load_eax(A_RAM);
        emit_load_eax(A_APERTURE);
        emit_load_eax(A_ALIAS0);
        emit_load_eax(A_HIRAM);
        emit_load_eax(A_HIRAM);
        emit_load_eax(A_RAM96);
        emit_load_eax(A_RAM96);
        emit_load_eax(A_NOALLOC);
        emit_load_eax(A_NOALLOC);
        emit_load_eax(A_ALIAS1);
        emit_load_eax(A_WIN0);
        emit_load_eax(A_ALIAS2);
        emit_hlt();
        core_reset(32'h0);
        run_to_hlt("data loads");

        $display("txn counts: ram f=%0d s=%0d | ap f=%0d s=%0d | alias f=%0d s=%0d | na f=%0d s=%0d | win0 f=%0d s=%0d",
                 ram_fill_n, ram_single_n, ap_fill_n, ap_single_n, al_fill_n, al_single_n,
                 na_fill_n, na_single_n, w0_fill_n, w0_single_n);
        $display("txn counts: hiram f=%0d s=%0d | ram96 f=%0d s=%0d | alias1 f=%0d s=%0d | alias2 f=%0d s=%0d",
                 hr_fill_n, hr_single_n, r96_fill_n, r96_single_n, al1_fill_n, al1_single_n,
                 al2_fill_n, al2_single_n);

        $display("--- cacheable RAM (0x%08x) ---", A_RAM);
        check_int("RAM read installs exactly one line (4-beat fill)", ram_fill_n, 1);
        check_int("RAM second read hits (no more bus traffic)", ram_single_n + ram_fill_n, 1);

        $display("--- A0000-FFFFF aperture (0x%08x) ---", A_APERTURE);
        check_int("aperture read is a single-beat direct access", ap_single_n, 1);
        check_int("aperture read installs no line", ap_fill_n, 0);

        $display("--- alias window 0 (0x%08x) ---", A_ALIAS0);
        check_int("alias read is a single-beat direct access", al_single_n, 1);
        check_int("alias read installs no line", al_fill_n, 0);

        $display("--- extended RAM at 16 MiB (0x%08x) ---", A_HIRAM);
        check_int("16 MiB RAM read installs exactly one line", hr_fill_n, 1);
        check_int("16 MiB RAM second read hits", hr_single_n + hr_fill_n, 1);

        $display("--- extended RAM below 96 MiB (0x%08x) ---", A_RAM96);
        check_int("96 MiB RAM read installs exactly one line", r96_fill_n, 1);
        check_int("96 MiB RAM second read hits", r96_single_n + r96_fill_n, 1);

        $display("--- no-allocate bound (0x%08x) ---", A_NOALLOC);
        check_int("both no-allocate reads take the bus", na_single_n, 2);
        check_int("no-allocate read installs no line", na_fill_n, 0);

        $display("--- alias window 1 above the bound (0x%08x) ---", A_ALIAS1);
        check_int("alias1 read is a single-beat access", al1_single_n, 1);
        check_int("alias1 read installs no line", al1_fill_n, 0);

        $display("--- alias window 2 (0x%08x) ---", A_ALIAS2);
        check_int("alias2 read is a single-beat access", al2_single_n, 1);
        check_int("alias2 read installs no line", al2_fill_n, 0);

        $display("--- window 0 while unmapped (0x%08x) ---", A_WIN0);
        check_int("unmapped window 0 is a single-beat direct access", w0_single_n, 1);
        check_int("unmapped window 0 installs no line", w0_fill_n, 0);

        // Phase 2: stores and fast read-modify-write stores into every window.
        clear_counts();
        win0_unmapped = 1'b1;
        a20_enable = 1'b1;
        prog_pc = 0;
        // Warm the cacheable lines so their RMW can take the fast overlay.
        emit_load_eax(W_RAM);
        emit_load_eax(W_HR);
        emit_load_eax(W_R96);
        // A plain store and a fast RMW per window, one DWORD apart.
        emit_store_eax(W_RAM);   emit_nop; emit_nop; emit_nop; emit_nop; emit_add_mem_eax(W_RAM + 4);
        emit_store_eax(W_AP);    emit_nop; emit_nop; emit_nop; emit_nop; emit_inc_mem(W_AP + 4);
        emit_store_eax(W_AL0);   emit_nop; emit_nop; emit_nop; emit_nop; emit_add_mem_eax(W_AL0 + 4);
        emit_store_eax(W_HR);    emit_nop; emit_nop; emit_nop; emit_nop; emit_inc_mem(W_HR + 4);
        emit_store_eax(W_R96);   emit_nop; emit_nop; emit_nop; emit_nop; emit_add_mem_eax(W_R96 + 4);
        emit_store_eax(W_NA);    emit_nop; emit_nop; emit_nop; emit_nop; emit_inc_mem(W_NA + 4);
        emit_store_eax(W_AL1);   emit_nop; emit_nop; emit_nop; emit_nop; emit_add_mem_eax(W_AL1 + 4);
        emit_store_eax(W_W0);    emit_nop; emit_nop; emit_nop; emit_nop; emit_inc_mem(W_W0 + 4);
        emit_store_eax(W_AL2);   emit_nop; emit_nop; emit_nop; emit_nop; emit_add_mem_eax(W_AL2 + 4);
        emit_hlt();
        core_reset(32'h0);
        run_to_hlt("stores and RMW");

        $display("txn writes: ram=%0d ap=%0d al0=%0d hr=%0d r96=%0d na=%0d al1=%0d w0=%0d al2=%0d",
                 wr_ram, wr_ap, wr_al0, wr_hr, wr_r96, wr_na, wr_al1, wr_w0, wr_al2);
        check_int("RAM store+RMW writes", wr_ram, 2);
        check_int("aperture store+RMW writes", wr_ap, 2);
        check_int("alias0 store+RMW writes", wr_al0, 2);
        check_int("16 MiB RAM store+RMW writes", wr_hr, 2);
        check_int("96 MiB RAM store+RMW writes", wr_r96, 2);
        check_int("no-allocate store+RMW writes", wr_na, 2);
        check_int("alias1 store+RMW writes", wr_al1, 2);
        check_int("window 0 store+RMW writes", wr_w0, 2);
        check_int("alias2 store+RMW writes", wr_al2, 2);
        $display("fast (RMW) stores: ram=%0d hr=%0d r96=%0d other=%0d",
                 fs_ram, fs_hr, fs_r96, fs_other);
        check_int("cacheable RAM RMW takes the fast store path", fs_ram, 1);
        check_int("16 MiB RAM RMW takes the fast store path", fs_hr, 1);
        check_int("96 MiB RAM RMW takes the fast store path", fs_r96, 1);
        check_int("no uncached window takes the fast store path", fs_other, 0);
        // A plain store posts exactly where the template says the page is
        // cacheable RAM (this bench leaves ram_cache_top open); no store to a
        // device window, to window 0 while it is unmapped or past the
        // no-allocate bound posts.
        $display("posted stores: ram=%0d hr=%0d r96=%0d other=%0d",
                 ps_ram, ps_hr, ps_r96, ps_other);
        check_int("cacheable RAM store posts", ps_ram, 1);
        check_int("16 MiB RAM store posts", ps_hr, 1);
        check_int("96 MiB RAM store posts", ps_r96, 1);
        check_int("no uncached window store posts", ps_other, 0);

        // Phase 3: runtime toggling of win0_unmapped.
        clear_counts();
        win0_unmapped = 1'b1;
        prog_pc = 0;
        emit_load_eax(W0_OFF1);       // unmapped: single-beat direct
        emit_out_al(8'hFC);           // win0_unmapped = 0
        emit_load_eax(W0_ON);         // mapped: cacheable line fill
        emit_out_al(8'hF8);           // win0_unmapped = 1
        emit_load_eax(W0_OFF2);       // unmapped again: single-beat direct
        emit_hlt();
        core_reset(32'h0);
        run_to_hlt("win0 runtime toggle");

        $display("win0 toggle: off1 single=%0d on fill=%0d off2 single=%0d",
                 w0off1_single_n, w0on_fill_n, w0off2_single_n);
        check_int("unmapped window 0 read is a single-beat direct access", w0off1_single_n, 1);
        check_int("unmapped window 0 read installs no line", w0off1_fill_n, 0);
        check_int("mapped window 0 read installs a line", w0on_fill_n, 1);
        check_int("mapped window 0 read is not a direct access", w0on_single_n, 0);
        check_int("re-unmapped window 0 read is a single-beat direct access", w0off2_single_n, 1);
        check_int("re-unmapped window 0 read installs no line", w0off2_fill_n, 0);

        // Phase 4: A20-off wrap of a full-core data access.
        clear_counts();
        a20_enable = 1'b1;
        prog_pc = 0;
        emit_load_eax(A20_RAW);        // A20 on: fill at 0x0010_5000
        emit_out_al(8'hF0);            // A20 off
        emit_load_eax(A20_RAW);        // masked: fill at 0x0000_5000
        emit_out_al(8'hF4);            // A20 on again
        emit_hlt();
        core_reset(32'h0);
        run_to_hlt("A20 wrap");

        $display("A20 wrap: raw fill=%0d wrapped fill=%0d", a20on_fill_n, a20off_fill_n);
        check_int("A20-on read accesses the raw address", a20on_fill_n, 1);
        check_int("A20-on read is a cacheable line fill", a20on_single_n, 0);
        check_int("A20-off read wraps to the low 20 bits", a20off_fill_n, 1);
        check_int("A20-off wrapped read is a cacheable line fill", a20off_single_n, 0);

        // Phase 5: instruction fetch from NO_ALLOC (pass-through, no install).
        clear_counts();
        win0_unmapped = 1'b1;
        a20_enable = 1'b1;
        emit_fetch_block(IF_NA_OFF, 4);
        core_reset(IF_NA);
        run_to_hlt("ifetch NO_ALLOC");
        $display("ifetch NO_ALLOC: fill=%0d single=%0d", ifna_fill_n, ifna_single_n);
        check_ge("NO_ALLOC code refills on every fetch", ifna_fill_n, 2);
        check_int("NO_ALLOC code fetch is always a full line", ifna_single_n, 0);

        // Phase 6: instruction fetch from unmapped window 0.
        clear_counts();
        win0_unmapped = 1'b1;
        emit_fetch_block(IF_W0_OFF, 4);
        core_reset(IF_W0);
        run_to_hlt("ifetch window 0");
        $display("ifetch window 0: fill=%0d single=%0d", ifw0_fill_n, ifw0_single_n);
        check_ge("unmapped window 0 code refills on every fetch", ifw0_fill_n, 2);
        check_int("unmapped window 0 code fetch is always a full line", ifw0_single_n, 0);

        // Phase 7: instruction fetch from extended RAM stays cached.
        clear_counts();
        emit_fetch_block(IF_HR_OFF, 4);
        core_reset(IF_HR);
        run_to_hlt("ifetch extended RAM");
        $display("ifetch extended RAM: fill=%0d single=%0d", ifhr_fill_n, ifhr_single_n);
        check_int("extended RAM code installs exactly one line", ifhr_fill_n, 1);
        check_int("extended RAM code never bypasses the cache", ifhr_single_n, 0);

        // Phase 8: self-modifying code in a DIRECT aperture window.  A CPU
        // store to the aperture bypasses the D-cache, so the instruction-cache
        // line holding the modified code must be invalidated (the write may be
        // ignored by the device, so the next fetch must re-read the aperture).
        clear_counts();
        prog_pc = 0;
        emit_smc_program(SMC_CODE, 32'h0000_00A1);   // version 1 marker
        emit_call_rel32(SMC_CODE);                   // execute version 1
        emit_smc_program(SMC_CODE, 32'h1122_3344);   // overwrite with version 2
        emit_call_rel32(SMC_CODE);                   // must execute version 2
        emit_hlt();
        core_reset(32'h0);
        run_to_hlt("direct-window SMC");
        smc_mark = {mem[SMC_MARK_OFF+3], mem[SMC_MARK_OFF+2],
                    mem[SMC_MARK_OFF+1], mem[SMC_MARK_OFF+0]};
        $display("direct SMC marker: %08x", smc_mark);
        check_int("direct-window self-modifying code runs the new bytes",
                  smc_mark, 32'h1122_3344);

        // Phase 9: a multi-cycle external snoop train overlapping TWO
        // DIRECT-window stores to I$-resident aperture code lines.  The I-cache
        // invalidate port carries one address per cycle and the snoop takes it,
        // so the first store's invalidate has to wait in memory.sv's pending
        // slot.  The second store must not overwrite that slot, and both lines
        // must miss on the next fetch, i.e. both routines must run the patched
        // immediate of the routine their line holds.
        clear_counts();
        win0_unmapped = 1'b1;
        a20_enable = 1'b1;
        load_dwl_routine(DWL_LINE_A, DWL_MARK_A, 32'hAAAA_1111);
        load_dwl_routine(DWL_LINE_B, DWL_MARK_B, 32'hBBBB_1111);
        prog_pc = 0;
        emit_load_eax(DWL_MARK_A);    // warm the marker lines so the routines'
        emit_load_eax(DWL_MARK_B);    // own marker stores are cached stores
        emit_call_rel32(DWL_ENTRY_A);  // install both code lines in the I$
        emit_call_rel32(DWL_ENTRY_B);
        emit_out_al(IO_SNOOP_ARM[7:0]);            // arm the snoop train
        emit_store_imm(DWL_IMM_A, 32'hAAAA_2222);  // DIRECT store into line A
        emit_store_imm(DWL_IMM_B, 32'hBBBB_2222);  // DIRECT store into line B
        emit_call_rel32(DWL_ENTRY_A);  // line A must miss and re-read
        emit_call_rel32(DWL_ENTRY_B);  // line B must miss and re-read
        emit_hlt();
        core_reset(32'h0);
        run_to_hlt("direct-window snoop train");

        dwl_mark_a = {mem[DWL_MARK_A+3], mem[DWL_MARK_A+2],
                      mem[DWL_MARK_A+1], mem[DWL_MARK_A+0]};
        dwl_mark_b = {mem[DWL_MARK_B+3], mem[DWL_MARK_B+2],
                      mem[DWL_MARK_B+1], mem[DWL_MARK_B+0]};
        $display("snoop train: %0d cycles | line fills A=%0d B=%0d | store in train A=%0d B=%0d | stranded=%0d",
                 snoop_len, dwla_fill_n, dwlb_fill_n, snoop_a_in_train,
                 snoop_b_in_train, snoop_held_cycles);
        check_int("first DIRECT-window store was accepted during the snoop train",
                  snoop_a_in_train, 1);
        check_ge("the first direct-write invalidate was stranded behind the snoop",
                 snoop_held_cycles, 1);
        check_int("the second DIRECT-window store waited for the snoop to release the port",
                  snoop_b_in_train, 0);
        check_int("first I$-resident DIRECT line misses after its patch",
                  dwla_fill_n, 2);
        check_int("second I$-resident DIRECT line misses after its patch",
                  dwlb_fill_n, 2);
        check_int("first DIRECT line ran the patched bytes",
                  dwl_mark_a, 32'hAAAA_2222);
        check_int("second DIRECT line ran the patched bytes",
                  dwl_mark_b, 32'hBBBB_2222);

        if (errors == 0) begin
            $display("PC98 MAP TEST PASS");
            $finish;
        end else begin
            $display("PC98 MAP TEST FAIL: %0d errors", errors);
            $fatal(1);
        end
    end
endmodule

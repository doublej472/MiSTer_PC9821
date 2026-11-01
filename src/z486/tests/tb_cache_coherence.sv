`timescale 1ns/1ns

// ==== WHAT THIS PROVES ====
// I-cache coherence with committed CPU stores and with DMA, at the memory.sv
// boundary (the real cache_unit/bus_unit/L1 stack over a behavioral RAM).  A
// 486 executes the modified code after a jump, so an instruction-line read
// issued AFTER a D-cache store has been accepted must return that store's
// bytes, and one issued after a whole-L1 flush must return memory.
//
//   CASE 1  I$ fill vs older undrained stores plus three younger stores (the
//           store queue drains the oldest first).
//   CASE 2  I$ lookup HIT while the store's patch is stranded in cache_unit's
//           one-entry slot behind a held external invalidate (DMA snoop).
//   CASE 3  as 2, with the fetch's lookup in the cycle the patch is stranded.
//   CASE 4  as 2, but the I$ line is not resident (the store drains before
//           the fill reads memory).
//   CASE 5  a snooped DMA write clears the I$ patch-queue entry of an older
//           CPU store to the same line.
//   CASE 6  a whole-L1 (platform) flush retires the I$ patch queue: a CPU
//           store's bytes must not be merged over DMA data written after it.
// Each case prints PASS/FAIL; the bench fails if any case fails.
module tb_cache_coherence;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg reset_n = 1'b0;

    reg         dcache_req_valid = 1'b0;
    reg  [31:0] dcache_req_phys_addr_raw = 32'h0;
    reg         dcache_req_write = 1'b0;
    reg   [3:0] dcache_req_be = 4'hF;
    reg  [31:0] dcache_req_wdata = 32'h0;
    wire        dcache_req_accepted;
    wire        dcache_req_complete;
    wire        dcache_read_complete;
    wire [31:0] dcache_rdata;

    reg         icache_req_valid = 1'b0;
    reg  [31:0] icache_req_addr = 32'h0;
    wire        icache_req_accepted;
    wire        icache_req_complete;
    wire [127:0] icache_rdata;

    wire [31:2] addr;
    wire  [3:0] be;
    wire  [7:0] burstcount;
    reg  [31:0] din = 32'h0;
    wire [31:0] dout;
    wire        valid;
    wire        ready;
    wire        write;
    wire        io;
    reg         resp_valid = 1'b0;
    wire        inta;
    reg [31:0]  snoop_addr = 0;
    reg         snoop_valid = 0;
    reg         cache_flush = 0;
    wire        cache_flush_done;

    memory #(
        .DCACHE_SET_BITS(3),
        .ICACHE_SET_BITS(3)
    ) dut (
        .clk(clk), .reset_n(reset_n), .a20_enable(1'b1),
        .device_mmio_enable(1'b0), .device_mmio_base(32'h0),
        .win0_unmapped(1'b0), .ram_cache_top(32'hffff_ffff),
        .cache_flush(cache_flush), .cache_flush_insn(1'b0),
        .cache_flush_busy(), .cache_flush_done(cache_flush_done),
        .dcache_req_valid(dcache_req_valid),
        .dcache_req_phys_addr_raw(dcache_req_phys_addr_raw),
        .dcache_req_preread_offset(dcache_req_phys_addr_raw[11:0]),
        .dcache_req_preread_priority(dcache_req_valid),
        .dcache_req_write(dcache_req_write), .dcache_req_be(dcache_req_be),
        .dcache_req_wdata(dcache_req_wdata), .dcache_direct_wdata(dcache_req_wdata),
        .dcache_req_is_io(1'b0), .dcache_req_is_inta(1'b0), .dcache_req_is_x87(1'b0),
        .dcache_req_is_vga_mem(1'b0), .dcache_req_is_pcd(1'b0),
        .dcache_req_is_locked(1'b0), .dcache_stores_drained_out(),
        .cache_enable(1'b1), .x87_off(1'b0), .cache_cd(1'b0), .cache_nw(1'b0),
        .bus_locked(1'b0),
        .dcache_req_accepted(dcache_req_accepted),
        .dcache_req_complete(dcache_req_complete),
        .dcache_read_complete(dcache_read_complete),
        .dcache_rdata(dcache_rdata),
        .fast_store_valid(1'b0), .fast_store_phys_addr_raw(32'd0),
        .fast_store_be(4'd0), .fast_store_wdata(32'd0), .fast_store_accepted(),
        .dcache_wr_ready(),
        .dcache_vipt_probe_valid(1'b0), .dcache_vipt_probe_offset(12'h000),
        .dcache_vipt_probe_ready(), .dcache_vipt_probe_accepted(),
        .dcache_vipt_probe_direct_accepted(),
        .dcache_vipt_resolve_valid(1'b0), .dcache_vipt_resolve_phys_addr_raw(32'h0), .dcache_vipt_resolve_tlb_phys_raw(32'h0), .dcache_vipt_resolve_alt_phys_raw(32'h0), .dcache_vipt_resolve_use_tlb(1'b0),
        .dcache_vipt_resolve_hit(), .dcache_vipt_resolve_data(),
        .x87_req_selected(), .x87_req_accepted(1'b0), .x87_req_complete(1'b0),
        .x87_read_complete(1'b0), .x87_rdata(32'h0),
        .icache_req_valid(icache_req_valid),
        .icache_req_phys_addr_raw(icache_req_addr), .icache_req_is_pcd(1'b0), .icache_req_spec_ok(),
        .icache_req_accepted(icache_req_accepted),
        .icache_req_complete(icache_req_complete),
        .icache_rdata(icache_rdata),
        .snoop_addr(snoop_addr), .snoop_valid(snoop_valid),
        .addr(addr), .be(be), .burstcount(burstcount), .line_read(),
        .din(din), .line_din(128'd0), .dout(dout), .valid(valid), .ready(ready),
        .write(write), .io(io), .resp_valid(resp_valid), .line_resp_valid(1'b0),
        .inta(inta)
    );

    // ---------------- behavioral RAM (narrow beats) ----------------
    reg [31:0] ram [0:16383];          // 64 KiB
    integer    rd_lat = 2;             // cycles from accept to first beat
    reg        rd_active = 1'b0;
    reg [31:0] rd_addr;
    reg [7:0]  rd_left;
    integer    rd_wait;
    assign ready = !rd_active;
    always @(posedge clk) begin
        resp_valid <= 1'b0;
        if (valid && ready) begin
            if (write) begin
                if (be[0]) ram[addr[15:2]][7:0]   <= dout[7:0];
                if (be[1]) ram[addr[15:2]][15:8]  <= dout[15:8];
                if (be[2]) ram[addr[15:2]][23:16] <= dout[23:16];
                if (be[3]) ram[addr[15:2]][31:24] <= dout[31:24];
            end else begin
                rd_active <= 1'b1;
                rd_addr <= {addr, 2'b00};
                rd_left <= burstcount;
                rd_wait <= rd_lat;
            end
        end else if (rd_active) begin
            if (rd_wait > 0) rd_wait <= rd_wait - 1;
            else begin
                resp_valid <= 1'b1;
                din <= ram[rd_addr[15:2]];
                rd_addr <= rd_addr + 4;
                rd_left <= rd_left - 1;
                if (rd_left == 1) rd_active <= 1'b0;
            end
        end
    end

    integer fails = 0;

    task automatic do_reset;
        reset_n = 0;
        repeat (5) @(negedge clk);
        reset_n = 1;
        repeat (20) @(negedge clk);
    endtask

    task automatic dstore(input [31:0] a, input [31:0] d);
        dcache_req_phys_addr_raw = a;
        dcache_req_wdata = d;
        dcache_req_write = 1;
        dcache_req_be = 4'hF;
        dcache_req_valid = 1;
        #1; while (!dcache_req_accepted) begin @(negedge clk); #1; end
        @(negedge clk);
        dcache_req_valid = 0;
        dcache_req_write = 0;
    endtask

    // Present an I-line request; returns the line.
    task automatic iread(input [31:0] a, output [127:0] line);
        icache_req_addr = a;
        icache_req_valid = 1;
        #1; while (!icache_req_accepted) begin @(negedge clk); #1; end
        @(negedge clk);
        // accepted on the preceding edge; drop valid now
        icache_req_valid = 0;
        while (!icache_req_complete) @(negedge clk);
        line = icache_rdata;
    endtask

    task automatic check(input integer c, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            $display("CASE %0d FAIL: I-line word0 = %08x, expected %08x", c, got, exp);
            fails = fails + 1;
        end else
            $display("CASE %0d PASS: I-line word0 = %08x", c, got);
    endtask

    reg [127:0] line;
    initial begin
        fork begin repeat (5000) @(posedge clk); $display("TIMEOUT"); $fatal(1); end join_none
        for (int i = 0; i < 16384; i++) ram[i] = 32'h1111_1111;

        // ---------------- CASE 1 ----------------
        do_reset();
        rd_lat = 30;
        // I$ fill of an unrelated line keeps the bus busy (icache_read_pending
        // holds every store-queue drain off).
        icache_req_addr = 32'h5000; icache_req_valid = 1;
        #1; while (!icache_req_accepted) begin @(negedge clk); #1; end
        @(negedge clk);
        icache_req_valid = 0;
        while (!dut.bus_unit_inst.icache_read_pending) @(negedge clk);
        // A: new code at 0x4000; B/C/D: three unrelated data stores.
        dstore(32'h4000, 32'hAAAA_AAAA);
        dstore(32'h7000, 32'h0000_0001);
        dstore(32'h7010, 32'h0000_0002);
        dstore(32'h7020, 32'h0000_0003);
        // A D-cache load miss blocks the drain (S_LOOKUP miss / S_FILL).
        dcache_req_phys_addr_raw = 32'h6000; dcache_req_write = 0; dcache_req_valid = 1;
        #1; while (!dcache_req_accepted) begin @(negedge clk); #1; end
        @(negedge clk);
        dcache_req_valid = 0;
        // The jump to the new code: fetch its line.
        iread(32'h4000, line);
        check(1, line[31:0], 32'hAAAA_AAAA);
        while (!dut.dcache_stores_drained_out) @(negedge clk);
        if (ram[32'h4000 >> 2] !== 32'hAAAA_AAAA) begin
            $display("CASE 1 FAIL: the store never reached RAM");
            fails = fails + 1;
        end

        // ---------------- CASE 2 ----------------
        do_reset();
        rd_lat = 2;
        for (int i = 0; i < 16384; i++) ram[i] = 32'h1111_1111;
        iread(32'h4000, line);                 // line resident in the I$
        repeat (3) @(negedge clk);
        dstore(32'h4000, 32'hBBBB_BBBB);       // committed store to the code
        // An unrelated DMA write snoop rises in the store's S_LOOKUP cycle
        // and is held (a DMA burst): the patch is stranded in the slot.
        snoop_addr = 32'h9000; snoop_valid = 1;
        #1;
        if (!dut.cache_unit_inst.dcache_store_patch_valid) begin
            $display("CASE 2 FAIL: setup - the snoop missed the store's patch cycle");
            fails = fails + 1;
        end
        repeat (2) @(negedge clk);
        iread(32'h4000, line);                 // jump to the modified code
        // The response was presented with the snoop still held; keep it held
        // across the consuming edge so the result does not race the release.
        @(negedge clk);
        check(2, line[31:0], 32'hBBBB_BBBB);
        snoop_valid = 0;
        repeat (5) @(negedge clk);

        // ---------------- CASE 3 ----------------
        // As 2, but the fetch is accepted together with the store, so its
        // lookup falls in the very cycle the snoop strands the patch: the
        // patch is not yet in the slot, and must still block the hit.
        do_reset();
        rd_lat = 2;
        for (int i = 0; i < 16384; i++) ram[i] = 32'h1111_1111;
        iread(32'h4000, line);                 // line resident in the I$
        repeat (3) @(negedge clk);
        dcache_req_phys_addr_raw = 32'h4000;
        dcache_req_wdata = 32'h6666_6666;
        dcache_req_write = 1;
        dcache_req_be = 4'hF;
        dcache_req_valid = 1;
        icache_req_addr = 32'h4000;
        icache_req_valid = 1;
        #1;
        if (!dcache_req_accepted || !icache_req_accepted) begin
            $display("CASE 3 FAIL: setup - store and fetch not accepted together");
            fails = fails + 1;
        end
        @(negedge clk);
        dcache_req_valid = 0;
        dcache_req_write = 0;
        icache_req_valid = 0;
        snoop_addr = 32'h9000; snoop_valid = 1; // held from the patch cycle
        #1;
        if (!dut.cache_unit_inst.dcache_store_patch_valid) begin
            $display("CASE 3 FAIL: setup - the snoop missed the store's patch cycle");
            fails = fails + 1;
        end
        while (!icache_req_complete) @(negedge clk);
        line = icache_rdata;
        @(negedge clk);
        check(3, line[31:0], 32'h6666_6666);
        snoop_valid = 0;
        repeat (5) @(negedge clk);

        // ---------------- CASE 4 ----------------
        do_reset();
        for (int i = 0; i < 16384; i++) ram[i] = 32'h1111_1111;
        rd_lat = 2;
        dstore(32'h4400, 32'hCCCC_CCCC);       // line 0x4400 not in the I$
        snoop_addr = 32'h9000; snoop_valid = 1; // held DMA snoop strands the patch
        iread(32'h4400, line);
        @(negedge clk);
        check(4, line[31:0], 32'hCCCC_CCCC);
        snoop_valid = 0;
        repeat (5) @(negedge clk);

        // ---------------- CASE 5 ----------------
        // A CPU store, then a snooped DMA write to the same word: the snoop
        // clears the store's patch-queue entry, so the fetch returns the DMA data.
        do_reset();
        for (int i = 0; i < 16384; i++) ram[i] = 32'h1111_1111;
        dstore(32'h4c00, 32'hDDDD_DDDD);
        while (!dut.dcache_stores_drained_out) @(negedge clk);
        repeat (4) @(negedge clk);
        ram[32'h4c00 >> 2] = 32'hEEEE_EEEE;
        snoop_addr = 32'h4c00; snoop_valid = 1;
        @(negedge clk);
        snoop_valid = 0;
        repeat (4) @(negedge clk);
        iread(32'h4c00, line);
        check(5, line[31:0], 32'hEEEE_EEEE);

        // ---------------- CASE 6 ----------------
        // The PC-98 platform keeps coherence with DMA by a whole-L1 flush (its
        // snoop input is tied off).  A CPU store leaves a copy in the I$'s
        // 3-entry patch queue; DMA then rewrites that memory (no snoop) and the
        // platform flushes both L1s.  A later fetch must see the DMA data.
        do_reset();
        for (int i = 0; i < 16384; i++) ram[i] = 32'h1111_1111;
        dstore(32'h4800, 32'hDDDD_DDDD);       // e.g. CPU clears/prepares a buffer
        while (!dut.dcache_stores_drained_out) @(negedge clk);
        repeat (4) @(negedge clk);
        ram[32'h4800 >> 2] = 32'hEEEE_EEEE;    // disk DMA loads new code, no snoop
        cache_flush = 1;                        // platform flush on DMA completion
        while (!cache_flush_done) @(negedge clk);
        @(negedge clk);
        cache_flush = 0;
        repeat (4) @(negedge clk);
        iread(32'h4800, line);                  // jump into the loaded code
        check(6, line[31:0], 32'hEEEE_EEEE);

        if (fails != 0) begin
            $display("tb_cache_coherence: %0d case(s) FAILED", fails);
            $fatal(1);
        end
        $display("tb_cache_coherence PASS");
        $finish;
    end
endmodule

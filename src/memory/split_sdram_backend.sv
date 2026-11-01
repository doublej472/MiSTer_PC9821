// The MiSTer SDRAM backend: the machine's four requesters onto the memory controller.
//
// z486_mister.sv instantiates this as the guest's memory backend. The controller serves four
// requesters ROUND-ROBIN: mem0 the guest memory port (the CPU, the DMA engine, the PEGC posted
// store buffer's drains and the ROM loader, muxed in pc9821_memory_subsystem), mem1 the
// font/glyph reader, mem2 the 86-PCM sample buffer, mem3 the PEGC 256-colour packed scanout's
// line fetch (pc9821_pegc_scan, through pc9821_memory_subsystem's pmem_*; z486_mister.sv's
// guest_mem3_*), the port sdram.v's scanout deadline protects. The ROM loader has no port
// of its own: it shares mem0 and owns it (loader_owns) from a download until rom_ready. The name's
// "split" is historical: the controller runs on clk_sys, one clock.
`default_nettype none

module split_sdram_backend #(
    parameter FREQ = 50_000_000,
    parameter ADQM = 1'b0,
    parameter FAST_GRADE = 1'b1,
    // G3 gather sessions: the most entries one request carries. The PEGC store
    // buffer's own GATHER_K must agree (z486_mister.sv passes both from one value).
    parameter integer GATHER_K = 4,
    parameter DQ_IN_DDIO = 1'b0,   // sdram.v's DQ read-capture cell (its parameter note)
    parameter OUT_DDIO = 1'b0,     // sdram.v's output-register cells (its parameter note)
    parameter integer DBG_CL = 0,        // sdram.v's measurement overrides (its parameter note)
    parameter integer DBG_TRCD_TRP = 0
) (
    // The requesters' clk_sys, which is ALSO the controller's and its PHY's clock: the SDRAM
    // runs on clk_sys in every build, so FREQ is clk_sys's rate and there is no clock-domain
    // crossing.
    input         clk,
    input         reset,
    input         refresh_allowed,
    input  [1:0]  sdram_size,
    output        busy,

    input         mem0_valid,
    output        mem0_ready,
    input         mem0_write,
    /* verilator lint_off UNUSEDSIGNAL */   // bits [31:27] are above the 27-bit device address
    input  [31:0] mem0_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  [31:0] mem0_din,
    // The two-word write's second dword (port 0's WRITE_BURST path, sdram.v's
    // din0_hi). The PEGC posted store buffer (pc9821_pegc_storebuf) is the caller:
    // two adjacent full dwords leave as one burstcount-2 write.
    input  [31:0] mem0_din_hi,
    // Port 0's G3 gather-RMW session request (sdram.v's header): mem0_gath qualifies a
    // write of mem0_burstcount (1..GATHER_K) same-row partial stores, entry 0 on
    // mem0_addr/mem0_din/mem0_be and entries 1.. on mem0_gath_extra
    // ({addr[26:0], din[31:0], be[3:0]} per entry).
    input         mem0_gath,
    input  [440:0] mem0_gath_extra,
    output [31:0] mem0_dout,
    output        mem0_resp_valid,
    input   [3:0] mem0_be,
    input   [7:0] mem0_burstcount,

    // Font/glyph reader: one 8-dword burst per 32-byte glyph block, driven by
    // pc9821_memory_subsystem's font arm. The ROM loader is NOT here; it shares mem0.
    input         mem1_valid,
    output        mem1_ready,
    input         mem1_write,
    /* verilator lint_off UNUSEDSIGNAL */   // same: the 32-bit port carries a 27-bit address
    input  [31:0] mem1_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  [31:0] mem1_din,
    output [31:0] mem1_dout,
    output        mem1_resp_valid,
    input   [3:0] mem1_be,
    input   [7:0] mem1_burstcount,

    // THIRD requester: the memory controller has four ports, and this design used two until the
    // 86-PCM sample buffer moved out of block RAM (src/pcm86/pc9821_pcm86_buf.sv). Wired here
    // rather than tied off; the controller's own arbiter serves its requesters ROUND-ROBIN (the
    // controller's fourth port was tied idle in the removed clock-domain bridge).
    input         mem2_valid,
    output        mem2_ready,
    input         mem2_write,
    /* verilator lint_off UNUSEDSIGNAL */   // same 27-bit device address, low two bits ignored
    input  [31:0] mem2_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  [31:0] mem2_din,
    output [31:0] mem2_dout,
    output        mem2_resp_valid,
    input   [3:0] mem2_be,
    input   [7:0] mem2_burstcount,

    // FOURTH requester: the PEGC packed scanout's line fetch. The controller serves four requesters
    // round-robin; this port was
    // tied idle in the (since removed) clock-domain bridge until that lane wired it.
    input         mem3_valid,
    output        mem3_ready,
    input         mem3_write,
    /* verilator lint_off UNUSEDSIGNAL */   // same 27-bit device address, low two bits ignored
    input  [31:0] mem3_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  [31:0] mem3_din,
    output [31:0] mem3_dout,
    output        mem3_resp_valid,
    input   [3:0] mem3_be,
    input   [7:0] mem3_burstcount,

    inout  [15:0] sdram_dq,
    output [12:0] sdram_a,
    output  [1:0] sdram_ba,
    output  [1:0] sdram_dqm,
    output        sdram_nwe,
    output        sdram_nras,
    output        sdram_ncas,
    output        sdram_ncs,
    output        sdram_cke
);

/* verilator lint_off PINCONNECTEMPTY */   // burst_done is deliberately not exposed by the
                                          // bridge; this machine has no consumer for it
// The controller on clk_sys plus port 0's hold (sdram_sync_bridge).
sdram_sync_bridge #(
    .FREQ(FREQ),
    .ADQM(ADQM),
    .FAST_GRADE(FAST_GRADE),
    .GATHER_K(GATHER_K),
    .DQ_IN_DDIO(DQ_IN_DDIO),
    .OUT_DDIO(OUT_DDIO),
    .DBG_CL(DBG_CL),
    .DBG_TRCD_TRP(DBG_TRCD_TRP)
) memory (
    .clk(clk),
    .resetn(~reset),
    .refresh_allowed(refresh_allowed),
    .busy(busy),
    .sdram_size(sdram_size),
    .valid0(mem0_valid),
    .ready0(mem0_ready),
    .wr0(mem0_write),
    .addr0(mem0_addr[26:0]),
    .din0(mem0_din),
    .din0_hi(mem0_din_hi),
    .gath0(mem0_gath),
    .gath0_extra(mem0_gath_extra),
    .dout0(mem0_dout),
    .resp_valid0(mem0_resp_valid),
    .be0(mem0_be),
    .burst_cnt0(mem0_burstcount > 8'd15 ? 4'd15 : mem0_burstcount[3:0]),
    .valid1(mem1_valid),
    .ready1(mem1_ready),
    .wr1(mem1_write),
    .addr1(mem1_addr[26:0]),
    .din1(mem1_din),
    .dout1(mem1_dout),
    .resp_valid1(mem1_resp_valid),
    .be1(mem1_be),
    .burst_cnt1(mem1_burstcount > 8'd15 ? 4'd15 : mem1_burstcount[3:0]),
    .valid2(mem2_valid),
    .ready2(mem2_ready),
    .wr2(mem2_write),
    .addr2(mem2_addr[26:0]),
    .din2(mem2_din),
    .dout2(mem2_dout),
    .resp_valid2(mem2_resp_valid),
    .be2(mem2_be),
    .burst_cnt2(mem2_burstcount > 8'd15 ? 4'd15 : mem2_burstcount[3:0]),
    .valid3(mem3_valid),
    .ready3(mem3_ready),
    .wr3(mem3_write),
    .addr3(mem3_addr[26:0]),
    .din3(mem3_din),
    .dout3(mem3_dout),
    .resp_valid3(mem3_resp_valid),
    .be3(mem3_be),
    .burst_cnt3(mem3_burstcount > 8'd15 ? 4'd15 : mem3_burstcount[3:0]),
    .SDRAM_DQ(sdram_dq),
    .SDRAM_A(sdram_a),
    .SDRAM_DQM(sdram_dqm),
    .SDRAM_BA(sdram_ba),
    .SDRAM_nWE(sdram_nwe),
    .SDRAM_nRAS(sdram_nras),
    .SDRAM_nCAS(sdram_ncas),
    .SDRAM_nCS(sdram_ncs),
    .SDRAM_CKE(sdram_cke)
);
/* verilator lint_on PINCONNECTEMPTY */

// CALLER CONTRACT: burstcount is 8 bits here and 4 at the controller, and a wider count truncates
// SILENTLY. The controller caps a read burst at 15 dwords and defines burst_cnt == 0 as ONE, so a
// caller asking for 16 got 16[3:0] == 0, was answered with a single word, and -- counting resp_valid
// pulses -- WAITED FOREVER. burst_done, the signal that would report the burst finishing, is
// deliberately unwired above, so nothing there can catch it. Two defences now, because a burst is a
// contract and a silent truncation is the hardest kind to find: the port CLAMPS a count above 15 to
// the cap so the built design answers something, and the simulation-only assertion below still
// fails loudly, since a clamp is the wrong COUNT and must not be allowed to pass for the right one.
// No live caller reaches the cap today (z486's L1 caches ask for 4 and 1, the font reader for 8,
// the ROM loader and PCM buffer for 1), so the clamp is defence against a future caller.
`ifdef VERILATOR
// Ports 1-3 only: port 0's pair is legitimate (its second word is mem0_din_hi).
wire [3:1] wr_two  = {mem3_write && (mem3_burstcount == 8'd2),
                      mem2_write && (mem2_burstcount == 8'd2),
                      mem1_write && (mem1_burstcount == 8'd2)};
always @(posedge clk) begin
    if (mem0_valid && (mem0_burstcount > 8'd15))
        $fatal(1, "split_sdram_backend: mem0_burstcount=%0d exceeds the controller's maximum of 15; it would be truncated silently and the caller would wait forever", mem0_burstcount);
    if (mem1_valid && (mem1_burstcount > 8'd15))
        $fatal(1, "split_sdram_backend: mem1_burstcount=%0d exceeds the controller's maximum of 15; it would be truncated silently and the caller would wait forever", mem1_burstcount);
    if (mem2_valid && (mem2_burstcount > 8'd15))
        $fatal(1, "split_sdram_backend: mem2_burstcount=%0d exceeds the controller's maximum of 15; it would be truncated silently and the caller would wait forever", mem2_burstcount);
    if (mem3_valid && (mem3_burstcount > 8'd15))
        $fatal(1, "split_sdram_backend: mem3_burstcount=%0d exceeds the controller's maximum of 15; it would be truncated silently and the caller would wait forever", mem3_burstcount);
    // THE TWO-WORD WRITE BELONGS TO PORT 0 ONLY, and port 0 now has a real caller
    // (pc9821_pegc_storebuf's pair drain carries its second word on mem0_din_hi). A
    // count of 2 on ports 1-3 is still a contract error rather than a burst: those
    // ports have no upper payload word at all, so such a write would silently store
    // four zero bytes at addr+4. What must not happen is a NON-port-0 caller reaching
    // the controller's pair path without a payload; port 0 is covered by
    // tb_pc9821_sdram_wburst and tb_pc9821_pegc_store_rate.
    if (|(wr_two[3:1] & {mem3_valid, mem2_valid, mem1_valid}))
        $fatal(1, "split_sdram_backend: port %0d issued a write with burstcount 2, but only port 0 has an upper payload word (din0_hi) -- the second dword would be written as zero",
               wr_two[3] ? 3 : wr_two[2] ? 2 : 1);
end
`endif

endmodule

`default_nettype wire

// The CPU-throttle bus bridge between the gated z486 and the clk_sys platform. The contract it
// meets is stated in pc9821_cpu_clk.sv's header (src/z486/docs/throttle.md).

// The bus bridge. `c_*` is the CPU side (gated domain), `p_*` the platform side (clk_sys).
module pc9821_cpu_bus_bridge (
    input  wire        clk,
    input  wire        reset_n,         // the CPU's reset (cpu_reset_n): empties the response FIFO
    input  wire        cpu_ce,          // the CPU gets the edge ending this cycle

    // request: the CPU's valid/inta levels and the platform's view of them
    input  wire        c_valid,
    input  wire        c_inta,
    output wire        p_valid,         // low while an accept waits for the CPU's edge
    output wire        p_inta,
    // accept: the platform's ready, held for the CPU
    input  wire        p_ready,
    output wire        c_ready,
    // response: one beat per CPU edge, buffered when the CPU is not clocked
    input  wire        p_resp_valid,
    input  wire [31:0] p_din,
    output wire        c_resp_valid,
    output wire [31:0] c_din,

    // the whole-L1 flush: a one-cycle platform pulse held for the CPU; the platform's busy
    // view covers the waiting pulse, and the CPU's one-CPU-cycle done is sampled once
    input  wire        p_flush_req,
    output wire        c_flush_req,
    input  wire        c_flush_busy,
    output wire        p_flush_busy,
    input  wire        c_flush_done,
    output wire        p_flush_done,

    // the DMA-side external snoop (the 486's EADS#): a one-cycle platform pulse with its
    // physical address, held for the CPU's next enabled edge (pc9821_cpu_clk.sv:13-15, "snoop_valid with its address").
    // p_snoop_busy is the hold's occupancy: the platform must not present a second DMA
    // WRITE while it is high (pc9821_system's DMA-write back-pressure).
    input  wire        p_snoop_valid,
    input  wire [31:0] p_snoop_addr,
    output wire        c_snoop_valid,
    output wire [31:0] c_snoop_addr,
    output wire        p_snoop_busy,

    // one-CPU-cycle output pulses, sampled once (under cpu_ce)
    input  wire        c_triple_fault,
    output wire        p_triple_fault,
    input  wire [2:0]  c_dbg_pulse,     // dbg_issue, dbg_gate_read, dbg_page_fault
    output wire [2:0]  p_dbg_pulse
);

// ---- the accept ----
// A responder's ready in a non-enabled cycle completes the transfer on the platform side; the
// CPU takes it at its next enabled edge. Until then the platform must not see the request
// again (it would serve it twice), so p_valid/p_inta drop and the CPU's ready is held.
// NOT cleared by the CPU's reset: an accept can be the CPU's own reset request (`out 0xF0`,
// a triple fault's re-entry), and the reset reaches the CPU only at its next edge
// (cpu_throttle forces its enable one cycle after reset_n falls, and the gate's staged cpu_ce
// follows one cycle later: pc9821_cpu_clk.sv), so clearing the hold on the
// reset would show the platform the CPU's still-raised valid again - the request served
// twice (pc9821_iobus's R6/R8 assertion caught exactly that at 1 MHz). The edge clears it.
reg acc_pend;
always @(posedge clk) begin
    if (cpu_ce)                  acc_pend <= 1'b0;
    else if (p_valid && p_ready) acc_pend <= 1'b1;
end
assign p_valid = c_valid && !acc_pend;
assign p_inta  = c_inta  && !acc_pend;
assign c_ready = p_ready || acc_pend;

// ---- the response ----
// z486 holds one read outstanding (src/z486/z486.sv's bus contract) and counts its beats at
// its own edges, so it does not present the next read before it has taken every beat of this
// one: at most `burstcount` (4, a line fill; line_read is unused here) beats can wait. A beat
// is buffered only when the CPU cannot take it this cycle or older beats are waiting, so with
// cpu_ce constant 1 the FIFO stays empty and c_resp_valid/c_din are p_resp_valid/p_din.
//
// A beat may reach the CPU on the same edge as a held accept: from the CPU's side that is a
// zero-wait accept with its data in the accept cycle, which z486's bus contract allows
// (including a paging demand read completed in its PG_MEM_TLB accept cycle), so no beat is
// held back.
reg [31:0] fifo_q [0:3];
reg [1:0]  rd_ptr, wr_ptr;
reg [2:0]  count;
wire       fifo_empty = (count == 3'd0);
wire       push = p_resp_valid && (!cpu_ce || !fifo_empty);
wire       pop  = cpu_ce && !fifo_empty;
always @(posedge clk) begin
    if (push) fifo_q[wr_ptr] <= p_din;
end
always @(posedge clk) begin
    if (!reset_n) begin
        rd_ptr <= 2'd0;
        wr_ptr <= 2'd0;
        count  <= 3'd0;
    end else begin
        if (push) wr_ptr <= wr_ptr + 2'd1;
        if (pop)  rd_ptr <= rd_ptr + 2'd1;
        count <= count + {2'd0, push} - {2'd0, pop};
    end
end
assign c_resp_valid = fifo_empty ? p_resp_valid : 1'b1;
assign c_din        = fifo_empty ? p_din : fifo_q[rd_ptr];

// ---- the flush request ----
// The fork's cpu_pulse_hold, inlined so the platform can see the waiting pulse: pc9821_iobus
// launches a flush only while none is committed (flush_start || cache_flush_busy), and the
// CPU's busy rises only at the edge that takes the request, so the pulse waiting for that edge
// must count as busy or a second launch could slip in between.
// Like the accept, it is cleared by the CPU's edge, not by its reset: a CPU in reset at that
// edge ignores the request exactly as the ungated CPU does.
reg flush_pend;
always @(posedge clk) flush_pend <= c_flush_req & ~cpu_ce;
assign c_flush_req  = p_flush_req | flush_pend;
assign p_flush_busy = c_flush_busy | flush_pend;
assign p_flush_done = c_flush_done & cpu_ce;

// ---- the DMA-side external snoop (EADS#) ----
// The uPD71071's accepted write raises a one-clk_sys pulse OUTSIDE the gated CPU domain.
// z486 samples snoop_valid on posedge cpu_clk (l1_cache.sv:928 `snoop_valid_r <=
// snoop_valid;`), so a pulse that lands in a cpu_ce=0 cycle has no ending edge and is
// lost (an under-invalidation). Hold the pulse (and its address)
// for the CPU the way the flush request is held, so every accepted write is captured
// exactly once, on an enabled edge, with the address of the byte it invalidates. The
// address is presented from the live pulse while it is high (a write accepted ON an
// enabled edge carries that write's address) and from the latch while it waits.
//
// BACK-PRESSURE. ONE snoop can wait: a second accepted write would replace
// the waiting address (the mux above takes the live pulse over the latch), silently
// losing the first invalidate. The hold is therefore visible to the platform as
// p_snoop_busy, and pc9821_system refuses to PRESENT or ACCEPT the next DMA write byte
// while it is high (snoop writes only - a DMA read is never snooped). The uPD71071's
// mem_req is a level held through S_MEM until mem_ready, so the byte waits, it is not
// dropped; the cost is at most one CPU clock period per write byte, which is the same
// pacing a real 486's EADS# imposes (one invalidate per CPU clock). A pacing argument
// from the FDC's data rate alone would not hold for the 0x13 software-request register,
// which can drive an unmasked channel at bus rate.
// The simulation check below stays as a backstop: with the back-pressure it is
// unreachable unless the gating itself breaks.
reg        snoop_pend;
reg [31:0] snoop_addr_q;
always @(posedge clk) begin
    if (cpu_ce)              snoop_pend <= 1'b0;
    else if (p_snoop_valid) begin
        snoop_pend   <= 1'b1;
        snoop_addr_q <= p_snoop_addr;
    end
end
assign c_snoop_valid = p_snoop_valid | snoop_pend;
assign c_snoop_addr  = p_snoop_valid ? p_snoop_addr : snoop_addr_q;
assign p_snoop_busy  = snoop_pend;

// ---- the one-CPU-cycle output pulses ----
assign p_triple_fault = c_triple_fault & cpu_ce;
assign p_dbg_pulse    = c_dbg_pulse & {3{cpu_ce}};

// synthesis translate_off
always @(posedge clk) begin
    if (reset_n && push && !pop && count == 3'd4)
        $fatal(1, "pc9821_cpu_bus_bridge: a fifth response beat while four wait for the CPU (more than one read's beats outstanding)");
    if (p_flush_req && flush_pend)
        $fatal(1, "pc9821_cpu_bus_bridge: a flush request while the previous one still waits for the CPU");
    if (p_snoop_valid && snoop_pend)
        $fatal(1, "pc9821_cpu_bus_bridge: a DMA snoop while the previous one still waits for the CPU (the platform accepted two writes inside one disabled run - the DMA-write back-pressure failed)");
end
// synthesis translate_on

endmodule

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The 86-PCM block's irq WIRE is NP2kai's interrupt QUERY, not the raw latched flag: with the IRQ enable (0xA468 bit 5) clear the wire is LOW even while the pending flag is latched, because pcm86gen_intrq returns FALSE the moment !(fifo & 0x20) (sound/pcm86c.c:472-475) and 0xA468 bit 4's read is that same query (cbus/pcm86io.c:299-308). The reported defect sequence is asserted exactly: a pending interrupt, then a 0xA468 write of 0x90 (bit 5 clear, bit 4 SET so the latch survives, cbus/pcm86io.c:114-121), drops the wire low for the whole masked window while bit 4 reads 0 as before; and the re-enable (0xB0) brings the query TRUE again off the still-latched flag (sound/pcm86c.c:476-479), so the wire produces ONE FRESH RISING EDGE - which is what the core's edge-latched PIC needs (ir_set = ir_in & ~ir_prev, pc9821_pic.sv:168) and what a wire driven by the latched flag alone cannot do (it stays high through the mask and eats the re-enable's edge). The enable-gate AND (latched flag OR live fifo level) shape is NP2kai's query exactly (pcm86gen_intrq, sound/pcm86c.c:465-490). FAIL-FIRST: IRQMASK_WIRE_FOLLOWS_QUERY_WHILE_MASKED and the IRQMASK_REENABLE_* checks fail against the pre-fix wire. When the query is genuinely FALSE on both sides (flag cleared above the threshold, cbus/pcm86io.c:114-126) a mask/unmask pair must produce NO edge (IRQMASK_NO_EDGE_WHEN_QUERY_FALSE). And the live-level half must raise the wire with NO arming write: with irq_arm consumed by one fire and the flag cleared, a threshold raise (not a data write) must raise the wire EXACTLY once off the live level alone (IRQMASK_NOARM_LIVE_LEVEL_*; FAIL-FIRST: the pre-fix flag-only wire has no source for that edge and produces zero), while the latched flag alone holds the wire when the level goes false again (sound/pcm86c.c:476-479).
//
// The 86-PCM block's irq WIRE is NP2kai's interrupt QUERY, not the raw latched
// flag: with the IRQ enable (0xA468 bit 5) clear the wire is LOW even while the
// pending flag is latched, because pcm86gen_intrq returns FALSE the moment
// !(fifo & 0x20) (sound/pcm86c.c:472-475) - and 0xA468 bit 4's read is that
// same query (cbus/pcm86io.c:299-308). The reported defect sequence is asserted
// exactly: a pending interrupt, then a 0xA468 write of 0x90 (bit 5 clear, bit 4
// SET so the latch survives, cbus/pcm86io.c:114-121), drops the wire low for
// the whole masked window while bit 4 reads 0 as before; and the re-enable
// (0xB0) brings the query TRUE again off the still-latched flag
// (sound/pcm86c.c:476-479), so the wire produces ONE FRESH RISING EDGE - which
// is what the core's edge-latched PIC needs (ir_set = ir_in & ~ir_prev,
// pc9821_pic.sv:168) and what a wire driven by the latched flag alone cannot
// do (it stays high through the mask and eats the re-enable's edge). The
// enable-gate AND (latched flag OR live fifo level) shape is NP2kai's query
// exactly (pcm86gen_intrq, sound/pcm86c.c:465-490). FAIL-FIRST:
// IRQMASK_WIRE_FOLLOWS_QUERY_WHILE_MASKED and the IRQMASK_REENABLE_* checks fail
// against the pre-fix wire. When the query is genuinely FALSE on both sides
// (flag cleared above the threshold, cbus/pcm86io.c:114-126) a mask/unmask pair
// must produce NO edge (IRQMASK_NO_EDGE_WHEN_QUERY_FALSE). And the live-level
// half must raise the wire with NO arming write: with irq_arm consumed by one
// fire and the flag cleared, a threshold raise (not a data write) must raise
// the wire EXACTLY once off the live level alone (IRQMASK_NOARM_LIVE_LEVEL_*;
// FAIL-FIRST: the pre-fix flag-only wire has no source for that edge and
// produces zero), while the latched flag alone holds the wire when the level
// goes false again (sound/pcm86c.c:476-479).

module tb_pc9821_pcm86_irqmask;

  // 50 MHz, matching the core's SYS_FREQ (tb_pc9821_pcm86_bufrst's harness).
  localparam integer CLK_HZ = 50_000_000;

  reg clk = 0;
  always #10 clk = ~clk;          // 20 ns period = 50 MHz

  reg         reset = 1;
  reg  [15:0] io_addr = 0;
  reg         io_wr = 0, io_rd = 0;
  reg  [7:0]  io_din = 0;
  wire [7:0]  io_dout;
  wire        io_rd_wait;
  wire        io_wr_wait;
  wire signed [15:0] snd_l, snd_r;
  wire        irq;
  wire [15:0] dbg_count;

  // The sample buffer's SDRAM side (src/pcm86/pc9821_pcm86_buf.sv): the third
  // port of the memory controller, which the bench stands in for.
  wire        sdram_valid, sdram_ready, sdram_write, sdram_resp_valid;
  wire [31:0] sdram_addr, sdram_din, sdram_dout;
  wire  [3:0] sdram_be;
  wire  [7:0] sdram_burstcount;
  pcm86_sdram_model u_sdram (
    .clk(clk), .reset(reset),
    .valid(sdram_valid), .ready(sdram_ready), .write(sdram_write),
    .addr(sdram_addr), .din(sdram_din), .dout(sdram_dout),
    .resp_valid(sdram_resp_valid), .be(sdram_be)
  );

  // ==== DUT ====
  pc9821_pcm86 #(.SYS_CLOCK_HZ(CLK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd), .io_din(io_din),
    .io_dout(io_dout), .io_rd_wait(io_rd_wait), .io_wr_wait(io_wr_wait),
    .snd_l(snd_l), .snd_r(snd_r),
    .irq(irq),
    .dbg_count(dbg_count),
    .buf_base(32'd0),
    .sdram_valid(sdram_valid), .sdram_ready(sdram_ready), .sdram_write(sdram_write),
    .sdram_addr(sdram_addr), .sdram_din(sdram_din), .sdram_dout(sdram_dout),
    .sdram_resp_valid(sdram_resp_valid), .sdram_be(sdram_be),
    .sdram_burstcount(sdram_burstcount)
  );

  integer errors = 0;

  // ==== CHECKS ====
  task automatic fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // One device write. io_wr is high across exactly one posedge, which is the
  // cycle the block samples.
  task automatic wr(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = portnum; io_din = data; io_wr = 1'b1;
      @(posedge clk);
      #1 io_wr = 1'b0;
      @(negedge clk);
    end
  endtask

  // Reads are answered from registers on the address alone (io_rd_wait is
  // tied low), so sampling io_dout after the address settles is the read.
  task automatic rd(input [15:0] portnum, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = portnum; io_rd = 1'b1;
      #1 data = io_dout;
      @(negedge clk);
      io_rd = 1'b0;
    end
  endtask

  // ---- the IRQ wire monitor -----------------------------------------------
  // The wire is the interrupt the edge-latched PIC consumes (pc9821_pic.sv:168
  // ir_set = ir_in & ~ir_prev), so the bench counts RISING EDGES, falling
  // edges, and high cycles inside a stimulus-opened mask window. The
  // discipline that keeps both sides race-free: this monitor acts ONLY at
  // posedges, while the stimulus drives the ports, opens/closes mask_window
  // and reads these counters ONLY at negedges - every repeat(N)-then-assert
  // block below re-aligns to a negedge first.
  localparam [15:0] P_FIFO = 16'h0A468;
  localparam [15:0] P_DAC  = 16'h0A46A;
  localparam [15:0] P_DATA = 16'h0A46C;

  reg     irq_q = 1'b0;
  reg     mask_window = 1'b0;
  integer irq_rises = 0, irq_falls = 0, masked_high = 0;
  always @(posedge clk) begin
    if (irq && !irq_q) irq_rises = irq_rises + 1;
    if (!irq && irq_q) irq_falls = irq_falls + 1;
    // masked_high is PER WINDOW: zero while the window is shut (the stimulus
    // opens it at a negedge, after the masking write has settled), so it counts
    // only cycles the wire is high INSIDE the current window.
    if (!mask_window) masked_high = 0;
    else if (irq)     masked_high = masked_high + 1;
    irq_q <= irq;
  end

  integer n;
  integer r0, f0;
  reg [7:0] rb;

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (50) @(posedge clk);

    // ---- 1. raise a pending interrupt ------------------------------------
    // Fill past the reset threshold (fifosize = 0x80) with the IRQ disabled so
    // nothing can latch, then enable and clear once above the threshold - the
    // query is FALSE here on both references (pcm86gen_intrq: enable gate then
    // flag-OR-level, all false). Then move the threshold above the count
    // (0xA46A = 0x02 -> (2 + 1) << 7 = 0x180, count 200 <= 384) and the query
    // goes TRUE: NP2kai's live-level term latches irqflag (pcm86c.c:480-486)
    // and the wire must rise ONCE.
    wr(P_FIFO, 8'h00);                     // IRQ disabled, rate 0
    for (n = 0; n < 200; n = n + 1) wr(P_DATA, n[7:0]);
    wr(P_FIFO, 8'hA0);                     // enable (bit 5) + clear (bit 4 low)
    rd(P_FIFO, rb);
    if (rb !== 8'hA0)
      fail("IRQMASK_QUERY_FALSE_ABOVE_THRESHOLD: 0xA468 did not read the query 0");
    if (irq !== 1'b0)
      fail("IRQMASK_QUERY_FALSE_ABOVE_THRESHOLD: the irq wire is high with the query false");
    r0 = irq_rises;
    wr(P_DAC, 8'h02);                      // threshold 0x180: now count <= fifosize
    repeat (10) @(posedge clk);
    @(negedge clk);
    if (irq !== 1'b1)
      fail("IRQMASK_PENDING_RAISES_WIRE: the irq wire is low with the query true");
    rd(P_FIFO, rb);
    if (rb !== 8'hB0)
      fail("IRQMASK_PENDING_RAISES_WIRE: 0xA468 did not read the query 1 in bit 4");
    if (irq_rises - r0 != 1)
      fail("IRQMASK_PENDING_RAISES_WIRE: the query going true must raise the wire ONCE");

    // ---- 2. the reported defect: 0x90 masks, 0xB0 re-edges ---------------
    // 0x90: bit 5 clear (disable) with bit 4 SET, so the pending flag is NOT
    // cleared (pcm86_oa468 clears irqflag only when !(val & 0x10),
    // cbus/pcm86io.c:114-121). NP2kai's query is nonetheless FALSE while the
    // enable is clear (pcm86c.c:472-475), and 0xA468 bit 4 reads that query
    // (cbus/pcm86io.c:303-307) - so the read is 0x80 = 0x90 & ~0x10 and the
    // WIRE must follow the query low for the whole masked window. The pre-fix
    // `assign irq = irq_pending` keeps the wire HIGH here (the flag is
    // deliberately still latched) - this assertion is the FAIL-FIRST.
    r0 = irq_rises;
    f0 = irq_falls;
    wr(P_FIFO, 8'h90);                     // disable (bit 5 clear), latch kept
    if (irq !== 1'b0)
      fail("IRQMASK_WIRE_FOLLOWS_QUERY_WHILE_MASKED: the irq wire did not follow the query low");
    rd(P_FIFO, rb);
    if (rb !== 8'h80)
      fail("IRQMASK_READ_STILL_MASKED: 0xA468 bit 4 read 1 with the IRQ enable clear");
    mask_window = 1'b1;                    // open after the masking write settles
    repeat (100) @(posedge clk);           // hold the masked window open
    @(negedge clk);
    if (irq !== 1'b0)
      fail("IRQMASK_WIRE_LOW_FOR_WHOLE_MASK_WINDOW: the irq wire rose inside the masked window");
    if (masked_high != 0)
      fail("IRQMASK_WIRE_LOW_FOR_WHOLE_MASK_WINDOW: the irq wire was high inside the masked window");

    // Re-enable with 0xB0 (bit 5 set, bit 4 set = no clear): the latch still
    // holds (sound/pcm86c.c:476-479 answers TRUE off pcm86->irqflag), so the
    // query goes TRUE AGAIN - the wire must produce exactly ONE fresh rising
    // edge. The edge-latched PIC needs that edge (ir_set = ir_in & ~ir_prev,
    // pc9821_pic.sv:168): a wire stuck high through the mask makes the
    // re-enable invisible to the interrupt controller.
    wr(P_FIFO, 8'hB0);                     // re-enable, latch kept
    if (irq !== 1'b1)
      fail("IRQMASK_REENABLE_RESUMES_QUERY: the irq wire did not return high on re-enable");
    rd(P_FIFO, rb);
    if (rb !== 8'hB0)
      fail("IRQMASK_REENABLE_RESUMES_QUERY: 0xA468 bit 4 did not read the query 1 again");
    repeat (20) @(posedge clk);
    @(negedge clk);
    mask_window = 1'b0;                    // close at a negedge (no monitor race)
    if (irq_rises - r0 != 1)
      fail("IRQMASK_REENABLE_FRESH_EDGE: mask+re-enable must give exactly ONE new rising edge");
    if (irq_falls - f0 != 1)
      fail("IRQMASK_REENABLE_FRESH_EDGE: mask+re-enable must give exactly ONE falling edge");

    // ---- 3. no spurious edge when the query is false on both sides --------
    // Refill above the threshold (count ~600 > 0x180) and clear the flag there:
    // the clear sticks (pcm86_oa468 clears irqflag and the virbuf <= fifosize
    // force does not re-latch above the threshold, cbus/pcm86io.c:114-126), so
    // the query is FALSE before, during and after a mask/unmask pair and the
    // wire must not move: an edge-latched PIC would latch that spurious edge.
    for (n = 0; n < 400; n = n + 1) wr(P_DATA, n[7:0]);
    wr(P_FIFO, 8'hA0);                     // clear (bit 4 low), enable kept
    repeat (10) @(posedge clk);
    if (irq !== 1'b0)
      fail("IRQMASK_CLEAR_ABOVE_THRESHOLD_DROPS_WIRE: the irq wire is high with the query false");
    rd(P_FIFO, rb);
    if (rb !== 8'hA0)
      fail("IRQMASK_CLEAR_ABOVE_THRESHOLD_DROPS_WIRE: 0xA468 did not read the query 0");
    r0 = irq_rises;
    f0 = irq_falls;
    mask_window = 1'b1;
    wr(P_FIFO, 8'h90);
    wr(P_FIFO, 8'hB0);
    repeat (20) @(posedge clk);
    @(negedge clk);
    if (irq !== 1'b0)
      fail("IRQMASK_NO_EDGE_WHEN_QUERY_FALSE: the irq wire moved with the query false");
    if (irq_rises - r0 != 0)
      fail("IRQMASK_NO_EDGE_WHEN_QUERY_FALSE: mask/unmask raised a spurious rising edge");
    if (irq_falls - f0 != 0)
      fail("IRQMASK_NO_EDGE_WHEN_QUERY_FALSE: mask/unmask raised a spurious falling edge");
    if (masked_high != 0)
      fail("IRQMASK_NO_EDGE_WHEN_QUERY_FALSE: the irq wire was high inside the quiet window");
    mask_window = 1'b0;                    // close at a negedge (no monitor race)

    // ---- 4. the live level raises the wire with NO arming write ----------
    // Every rise above went through irq_set, whose fire is what latches
    // irq_pending - so a wire driven by the latched flag alone could pass all
    // of it. The live-level half of the query must raise the wire with NO data
    // write at all: pcm86gen_intrq answers TRUE (and latches irqflag) off
    // `virbuf <= fifosize` alone (sound/pcm86c.c:480-486), so with irq_arm
    // consumed and irq_pending clear, bringing the level true raises the wire
    // EXACTLY once - the pre-fix `assign irq = irq_pending` has no source for
    // that edge and produces ZERO (IRQMASK_NOARM_* is the fail-first).
    //
    // 4a. consume the arm with one real fire: raise the threshold above the
    // count (0xA46A = 0x04 -> (4 + 1) << 7 = 0x280 = 640 > count ~590), so the
    // level goes true WITH the arm still set and irq_set fires once
    // (irq_pending <- 1, irq_arm <- 0).
    r0 = irq_rises;
    wr(P_DAC, 8'h04);
    repeat (10) @(posedge clk);
    @(negedge clk);
    if (irq !== 1'b1)
      fail("IRQMASK_ARM_CONSUMED_BY_FIRE: the armed fire did not raise the wire");
    if (irq_rises - r0 != 1)
      fail("IRQMASK_ARM_CONSUMED_BY_FIRE: the armed fire must raise the wire ONCE");
    if (dut.irq_arm !== 1'b0 || dut.irq_pending !== 1'b1)
      fail("IRQMASK_ARM_CONSUMED_BY_FIRE: the fire did not consume the arm into the flag");

    // 4b. shrink the threshold below the count (0xA46A = 0x02 -> 0x180): the
    // level goes false but the LATCHED flag keeps the query TRUE
    // (sound/pcm86c.c:476-479) - no edge either way.
    r0 = irq_rises;
    f0 = irq_falls;
    wr(P_DAC, 8'h02);
    repeat (10) @(posedge clk);
    @(negedge clk);
    if (irq !== 1'b1)
      fail("IRQMASK_LATCHED_FLAG_HOLDS_QUERY: the latched flag stopped holding the wire");
    if (irq_rises - r0 != 0 || irq_falls - f0 != 0)
      fail("IRQMASK_LATCHED_FLAG_HOLDS_QUERY: a level-only move changed the wire");

    // 4c. clear the flag at the now-false level (0xA468 = 0xA0: bit 4 clear;
    // the re-assert cannot fire above the threshold, cbus/pcm86io.c:114-126):
    // the query goes FALSE and the clear STICKS. The state is exactly the
    // precondition: enable=1, irq_pending=0, irq_arm=0, level false.
    r0 = irq_rises;
    f0 = irq_falls;
    wr(P_FIFO, 8'hA0);
    repeat (10) @(posedge clk);
    @(negedge clk);
    if (irq !== 1'b0)
      fail("IRQMASK_CLEAR_SETS_NOARM_PRECONDITION: the clear left the wire high");
    if (irq_falls - f0 != 1 || irq_rises - r0 != 0)
      fail("IRQMASK_CLEAR_SETS_NOARM_PRECONDITION: the clear must give exactly ONE falling edge");
    rd(P_FIFO, rb);
    if (rb !== 8'hA0)
      fail("IRQMASK_CLEAR_SETS_NOARM_PRECONDITION: 0xA468 did not read the query 0");
    if (dut.irq_arm !== 1'b0 || dut.irq_pending !== 1'b0)
      fail("IRQMASK_CLEAR_SETS_NOARM_PRECONDITION: the arm/pending precondition is not met");

    // 4d. THE PURE NO-ARM RISE: raise the threshold above the count again
    // (0xA46A = 0x04 -> 0x280) - a threshold write is NOT a data write, so
    // irq_set cannot fire (the arm was consumed) and nothing latches. The live
    // level alone must raise the wire EXACTLY once and bit 4 must read that
    // same query 1.
    r0 = irq_rises;
    f0 = irq_falls;
    wr(P_DAC, 8'h04);
    repeat (10) @(posedge clk);
    @(negedge clk);
    if (irq !== 1'b1)
      fail("IRQMASK_NOARM_LIVE_LEVEL_RISES_WIRE: the live level did not raise the wire with no arm");
    rd(P_FIFO, rb);
    if (rb !== 8'hB0)
      fail("IRQMASK_NOARM_LIVE_LEVEL_RISES_WIRE: bit 4 did not read the live-level query 1");
    if (irq_rises - r0 != 1)
      fail("IRQMASK_NOARM_LIVE_LEVEL_EXACTLY_ONE_RISE: the no-arm rise must be EXACTLY ONE edge");
    if (irq_falls - f0 != 0)
      fail("IRQMASK_NOARM_LIVE_LEVEL_EXACTLY_ONE_RISE: the no-arm level move changed the wire twice");
    if (dut.irq_arm !== 1'b0 || dut.irq_pending !== 1'b0)
      fail("IRQMASK_NOARM_LIVE_LEVEL_EXACTLY_ONE_RISE: the rise was not the pure live-level term");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PCM86_IRQMASK: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PCM86_IRQMASK: FAIL (%0d errors)", errors);
  end

  initial begin
    #10_000_000;
    $fatal(1, "TB_PC9821_PCM86_IRQMASK: TIMEOUT");
  end

endmodule

// pcm86_sdram_model: the SDRAM third-port handshake and a 32 KiB byte store, for the PCM86
// benches. The buffer moved out of block RAM (src/pcm86/pc9821_pcm86_buf.sv), so each bench
// supplies the SDRAM side. The real controller answers a read after its CAS latency; this
// answers after one wait cycle, which is enough to exercise the request/valid handshake.
module pcm86_sdram_model (
  input  wire        clk, reset,
  input  wire        valid,
  output reg         ready,
  input  wire        write,
  input  wire [31:0] addr,
  input  wire [31:0] din,
  output reg  [31:0] dout,
  output reg         resp_valid,
  input  wire  [3:0] be
);
  reg [7:0]  mem [0:32767];
  reg [1:0]  st;
  reg [31:0] lat_addr;
  reg        lat_wr;
  integer    i;
  wire [14:0] wbase = {lat_addr[14:2], 2'b00};
  always @(posedge clk) begin
    ready      <= 1'b0;
    resp_valid <= 1'b0;
    if (reset) begin
      st <= 2'd0;
      for (i = 0; i < 32768; i = i + 1) mem[i] <= 8'h00;
    end else case (st)
      2'd0: if (valid) begin
              ready    <= 1'b1;
              lat_addr <= addr;
              lat_wr   <= write;
              st       <= 2'd1;
            end
      2'd1: begin
              if (lat_wr) begin
                if (be[0]) mem[wbase]     <= din[7:0];
                if (be[1]) mem[wbase + 1] <= din[15:8];
                if (be[2]) mem[wbase + 2] <= din[23:16];
                if (be[3]) mem[wbase + 3] <= din[31:24];
                st <= 2'd0;
              end else begin
                dout <= {mem[wbase + 3], mem[wbase + 2], mem[wbase + 1], mem[wbase]};
                st   <= 2'd2;
              end
            end
      default: begin
              resp_valid <= 1'b1;
              st         <= 2'd0;
            end
    endcase
  end
endmodule

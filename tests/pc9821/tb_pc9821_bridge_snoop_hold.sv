`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_BRIDGE_SNOOP_HOLD: pc9821_cpu_bus_bridge hands the CPU every DMA snoop exactly once, with its own address, from the REGISTERED hold alone: c_snoop_valid and c_snoop_addr never follow p_snoop_valid/p_snoop_addr in the cycle they arrive (the platform's dma_ready cone ends at the hold, not at the CPU's caches), a write accepted in a cycle whose edge is the CPU's (cpu_ce=1) is held and taken at the CPU's NEXT enabled edge instead of being lost, and one accepted at a disabled edge is taken at the first enabled edge after it; p_snoop_busy is high exactly while a snoop waits, and the DMA side that honours it never offers a second write over a waiting one. Swept at full speed (cpu_ce=1 every cycle: every write is taken one clk_sys after it lands) and at three throttled cadences (one enabled edge in 2, 7 and 49 clk_sys), with writes landing on every phase of the cadence.
//
// The CPU side is modelled as z486 samples it (l1_cache.sv:928 `snoop_valid_r <= snoop_valid;`
// on the gated cpu_clk): a snoop is TAKEN at the end of a cycle with cpu_ce=1 and c_snoop_valid
// high, with the c_snoop_addr of that cycle. Each taken snoop must be the oldest outstanding write,
// in order, with its address, taken at the first enabled edge AFTER the cycle it was accepted in
// (owner decision 2026-11-13: the invalidate is one clk_sys later at full speed, or the next CPU
// edge after the write; docs/trade-candidates.md T87); none may be taken twice, and none may be
// left at the end.
//
// FAIL-FIRST: the bridge before this change presented the live pulse (c_snoop_valid =
// p_snoop_valid | snoop_pend), so the "never in the arrival cycle" check fails on its first write;
// the half-fix that drives the CPU from the hold but keeps the old always-block (the hold set only
// at a disabled edge) never sets the hold for a write that lands on an enabled edge, and the
// full-speed sweep fails with that snoop never taken (tests/pc9821/mutations.json).

`default_nettype none

module tb_pc9821_bridge_snoop_hold;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset_n = 0;
  reg cpu_ce = 1;
  reg p_snoop_valid = 0;
  reg [31:0] p_snoop_addr = 0;
  wire c_snoop_valid, p_snoop_busy;
  wire [31:0] c_snoop_addr;

  // ==== DUT ====
  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_cpu_bus_bridge dut (
      .clk(clk), .reset_n(reset_n), .cpu_ce(cpu_ce),
      .c_valid(1'b0), .c_inta(1'b0), .p_valid(), .p_inta(), .p_ready(1'b0), .c_ready(),
      .p_resp_valid(1'b0), .p_din(32'd0), .c_resp_valid(), .c_din(),
      .p_flush_req(1'b0), .c_flush_req(), .c_flush_busy(1'b0), .p_flush_busy(),
      .c_flush_done(1'b0), .p_flush_done(),
      .p_snoop_valid(p_snoop_valid), .p_snoop_addr(p_snoop_addr),
      .c_snoop_valid(c_snoop_valid), .c_snoop_addr(c_snoop_addr), .p_snoop_busy(p_snoop_busy),
      .c_triple_fault(1'b0), .p_triple_fault(), .c_dbg_pulse(3'd0), .p_dbg_pulse());
  /* verilator lint_on PINCONNECTEMPTY */

  // ==== CHECKS ====
  // the outstanding writes, in order: address and the cycle each was accepted in
  reg  [31:0] q_addr [0:15];
  integer     q_cyc  [0:15];
  integer qh = 0, qt = 0, cyc = 0, taken = 0, errors = 0, sent = 0;
  integer last_en = -1;   // the most recent enabled edge's cycle

  task automatic fail(input [8*96-1:0] what);
    begin
      errors = errors + 1;
      if (errors < 8) $display("FAIL cyc %0d: %0s", cyc, what);
    end
  endtask

  always @(posedge clk) if (reset_n) begin
    // the CPU's sample at this edge (the end of cycle `cyc`)
    if (cpu_ce && c_snoop_valid) begin
      if (qh == qt) fail("a snoop taken with no write outstanding (taken twice?)");
      else begin
        if (c_snoop_addr !== q_addr[qh[3:0]]) fail("a snoop taken with the wrong address");
        if (q_cyc[qh[3:0]] >= cyc) fail("a snoop taken in the cycle its write arrived (not from the hold)");
        if (last_en > q_cyc[qh[3:0]]) fail("a snoop not taken at the first enabled edge after its write");
        qh = qh + 1; taken = taken + 1;
      end
    end
    if (p_snoop_valid) begin
      q_addr[qt[3:0]] = p_snoop_addr; q_cyc[qt[3:0]] = cyc; qt = qt + 1; sent = sent + 1;
    end
    if (cpu_ce) last_en = cyc;
  end

  // inside the cycle: the busy flag is exactly "a snoop waits" (the CPU side's independence of the
  // arriving pulse is checked where the stimulus drives it, below)
  always @(negedge clk) if (reset_n) begin
    #2;
    if (p_snoop_busy !== (qh != qt)) fail("p_snoop_busy is not 'a snoop waits'");
  end

  // ==== STIMULUS ====
  // one sweep: cpu_ce high one cycle in PERIOD, writes offered at every phase of it
  task automatic sweep(input integer period, input integer n_writes);
    integer k, ph, w;
    reg pre_v; reg [31:0] pre_a;
    begin
      w = 0; ph = 0;
      for (k = 0; k < n_writes * (period + 3) * 3 && w < n_writes; k = k + 1) begin
        @(negedge clk);
        cpu_ce = (ph == period - 1) || (period == 1);
        // offer a write whenever the hold is free and the pseudo-random phase says so; it lands
        // on enabled and disabled cycles alike
        if (!p_snoop_busy && (($urandom % 3) != 0)) begin
          // the CPU side must not follow the pulse in its own cycle: sampled just before the pulse
          // is driven and just after
          pre_v = c_snoop_valid; pre_a = c_snoop_addr;
          p_snoop_valid = 1; p_snoop_addr = 32'h0010_0000 + 32'(sent * 4 + period);
          #1;
          if (c_snoop_valid !== pre_v || c_snoop_addr !== pre_a)
            fail("c_snoop_valid/c_snoop_addr follow p_snoop_valid in its own cycle");
          w = w + 1;
        end else p_snoop_valid = 0;
        ph = (ph + 1) % period;
        cyc = cyc + 1;
      end
      @(negedge clk); p_snoop_valid = 0;
      // drain: the hold is taken at the next enabled edge
      for (k = 0; k < 2 * period + 2; k = k + 1) begin
        cpu_ce = (ph == period - 1) || (period == 1);
        ph = (ph + 1) % period;
        cyc = cyc + 1;
        @(negedge clk);
      end
      if (qh != qt) fail("a snoop left untaken after the sweep");
      $display("sweep period %0d: %0d writes, %0d taken so far", period, n_writes, taken);
    end
  endtask

  // ==== VERDICT ====
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk); reset_n = 1;
    sweep(1, 400);    // full speed: every edge is the CPU's
    sweep(2, 300);
    sweep(7, 200);
    sweep(49, 60);
    if (taken != sent) fail("taken count differs from the writes sent");
    if (taken < 900) fail("too few writes exercised");
    if (errors != 0) $fatal(1, "TB_PC9821_BRIDGE_SNOOP_HOLD: FAIL (%0d errors)", errors);
    $display("%0d snoops, every one taken once, in order, from the hold", taken);
    $display("TB_PC9821_BRIDGE_SNOOP_HOLD: PASS");
    $finish;
  end
endmodule

`default_nettype wire

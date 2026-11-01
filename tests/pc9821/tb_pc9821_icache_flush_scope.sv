`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ICACHE_FLUSH_SCOPE:
// The I$ half of the cache-flush migration is what the rewritten leaf still owns: its NATIVE whole-L1 flush clears EVERY line whatever the tag - a line whose tag matches nothing in the swept range, and the 0xFFFF8000 fw_high alias of the banked ROM window, are the cases a set-local clear leaves behind - because the rewritten l1_icache's EXTERNAL invalidate is TAG-MATCHED ONLY (its own comment: there is no set-wide external invalidate) and the PC-98 platform stopped sweeping when it moved to this native port; the D$->I$ STORE PATCH path stays TAG-MATCHED - a same-set neighbour keeps its line - and the patched line's refill carries the patched bytes out of the leaf's own patch queue; and the lookup-vs-patch one-cycle race (src/z486/docs/coherency-audit.md C9) cannot answer a stale hit: a fetch accepted on the snoop's registered cycle lands its tag capture on the clear's commit edge, and the response must refetch (or already carry the patched word) rather than return the pre-clear line. Refills are measured at the backend's accept count, not read out of the FSM. FAIL-FIRST by mutant: (a)/(d) fail against a set-local clear and (c) against a tree without the race guard.
//
// WHY THIS EXISTS, AND WHAT MOVED. The bench was written when the platform swept the I$ with a
// line-by-line EXTERNAL invalidate and the leaf's clear was set-wide behind a parameter. The
// 2026-10-03 fork rebase settled both the other way: the EXTERNAL invalidate is TAG-MATCHED
// ONLY (l1_icache.sv says so in the comment above its clear: "A tag-matched clear is the only
// kind here (there is no set-wide external invalidate)"), and the SET-WIDE mechanism is the
// leaf's NATIVE whole-L1 flush - which is what pc9821_system now drives and what the old
// pc9821_cache_flush sweeper was retired in favour of (src/z486/docs/platform-integration.md,
// src/z486/docs/coherency-audit.md). So the old legs (a) and (d), which swept with the external
// port and demanded the whole I$ die, were asking for a mechanism the fork deliberately
// removed; they now drive the native flush and assert the same scope property on it, which is
// the property that matters to the platform: the line CLEARED must not be a tag neighbour of
// the address that cleared it.
//
// The D$->I$ store patch leg is the other half and it survives, re-pointed: the leaf now takes
// patch_addr/patch_data/patch_be/patch_valid (cache_unit relays them; src/z486/docs/coherency-audit.md
// C9) instead of the retired D$-store-queue snoop pair, and it queues the patched bytes in its
// OWN patchq so the refill carries them. Only the matching line is touched, so a same-set
// neighbour keeps its line - the tag-matched half that (b) pins.
//
// WHY IT IS NOT REDUNDANT WITH THE FLUSH: a set-local or tag-matched clear passes every "the
// line I named is gone" check and fails (a) and (d), because those name a line the clearing
// address does not match. That is the mutant this bench kills.
//
// A refill is OBSERVED on the backend's accept count, so "hit" and "miss" are measured at the
// memory port, not read out of the FSM.


`default_nettype none

module tb_pc9821_icache_flush_scope;

  localparam integer SET_BITS = 5;      // pc9821_system.sv's ICACHE_SET_BITS

  reg clk = 1'b0, reset = 1'b1;
  always #5 clk = ~clk;

  // ==== DUT ====
  reg  [31:0] i_cpu_addr = 32'd0;
  reg         i_cpu_valid = 1'b0;
  wire [127:0] i_cpu_line;
  wire        i_cpu_ready, i_cpu_resp_valid;
  wire [31:0] i_mem_addr, i_mem_dout;
  wire  [3:0] i_mem_be;
  wire  [7:0] i_mem_burst;
  wire        i_mem_valid, i_mem_ready, i_mem_resp_valid, i_mem_line_resp_valid;
  wire        i_mem_busy;

  // The D$->I$ store patch (cache_unit relays it) and the external invalidate, which the
  // rewritten leaf treats as TAG-MATCHED. `inv_addr`/`inv_valid` therefore no longer carry a
  // whole-cache sweep; the sweep is the native flush below.
  reg  [31:0] patch_addr = 32'd0;
  reg  [31:0] patch_data = 32'd0;
  reg   [3:0] patch_be   = 4'h0;
  reg         patch_valid = 1'b0;
  reg  [31:0] inv_addr = 32'd0;
  reg         inv_valid = 1'b0;
  reg         flush_start = 1'b0;
  wire        flush_busy, flush_done;

  l1_icache #(.SET_BITS(SET_BITS)) icache (
    .clk(clk), .reset(reset),
    .cpu_addr(i_cpu_addr), .cpu_line(i_cpu_line), .cpu_valid(i_cpu_valid),
    .cpu_ready(i_cpu_ready), .cpu_resp_valid(i_cpu_resp_valid),
    .cpu_no_alloc(1'b0),
    .mem_addr(i_mem_addr), .mem_dout(i_mem_dout), .mem_line_dout(128'd0),
    .mem_be(i_mem_be), .mem_burstcount(i_mem_burst), .mem_busy(i_mem_busy),
    .mem_valid(i_mem_valid), .mem_ready(i_mem_ready),
    .mem_resp_valid(i_mem_resp_valid), .mem_line_resp_valid(i_mem_line_resp_valid),
    .patch_addr(patch_addr), .patch_data(patch_data), .patch_be(patch_be),
    .patch_valid(patch_valid),
    .invalidate_addr(inv_addr), .invalidate_valid(inv_valid),
    .flush_req(flush_start), .flush_busy(flush_busy), .flush_done(flush_done),
    .cache_enable(1'b1)
  );

  // A dword backend: one accept pulse, one response beat per burst dword, no line response.
  wire [31:0] mem_accepts, mem_beats;
  sdram_backend_model #(
    .ACCEPT_TO_RESP(0), .WRITE_BUSY(0), .LINE_RESP(0), .WORDS_LOG2(16)
  ) i_mem (
    .clk(clk), .reset(reset),
    .valid(i_mem_valid), .ready(i_mem_ready), .write(1'b0),
    .addr(i_mem_addr), .din(32'd0), .din_hi(32'd0), .be(i_mem_be),
    .burstcount(i_mem_burst),
    .dout(i_mem_dout), .resp_valid(i_mem_resp_valid),
    .line_dout(), .line_resp_valid(i_mem_line_resp_valid),
    .busy(i_mem_busy), .accepts(mem_accepts), .beats(mem_beats)
  );

  integer errors = 0;
  integer checks = 0;
  integer coff;
  reg [31:0] acc_mark;

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_ICACHE_FLUSH_SCOPE: FAIL (watchdog, the run did not finish)");
  end

  task automatic settle(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) @(negedge clk);
    end
  endtask

  // One fetch. A refill is measured as a backend accept during the fetch; a hit is not.
  task automatic fetch(input [31:0] a, output refilled, output [127:0] line);
    integer g;
    begin
      g = 0;
      while (!i_cpu_ready && g < 500) begin @(negedge clk); g = g + 1; end
      if (!i_cpu_ready) $fatal(1, "the I$ never became ready for %08x", a);
      acc_mark = mem_accepts;
      i_cpu_addr = a; i_cpu_valid = 1'b1;
      @(negedge clk);
      i_cpu_valid = 1'b0;
      g = 0;
      while (!i_cpu_resp_valid && g < 2000) begin @(negedge clk); g = g + 1; end
      if (!i_cpu_resp_valid) $fatal(1, "an I$ fetch of %08x never produced a response", a);
      line = i_cpu_line;
      refilled = (mem_accepts != acc_mark);
      settle(3);
    end
  endtask

  task automatic expect_miss(input [31:0] a, input [8*140-1:0] tag);
    reg refilled;
    reg [127:0] line;
    begin
      fetch(a, refilled, line);
      checks = checks + 1;
      if (!refilled) begin
        $display("FAIL %0s: %08x HIT after it must have been invalidated", tag, a);
        errors = errors + 1;
      end
    end
  endtask

  task automatic expect_hit(input [31:0] a, input [8*140-1:0] tag);
    reg refilled;
    reg [127:0] line;
    begin
      fetch(a, refilled, line);
      checks = checks + 1;
      if (refilled) begin
        $display("FAIL %0s: %08x refilled but must still HIT", tag, a);
        errors = errors + 1;
      end
    end
  endtask

  // The platform's NATIVE whole-L1 flush: one request, the leaf walks every set, done at the end
  // (l1_icache's flush_req/flush_busy/flush_done). This is the SET-WIDE mechanism now - the
  // external invalidate beside it is tag-matched only - and it is what pc9821_system drives
  // since the pc9821_cache_flush sweeper was retired.
  task automatic flush_all();
    integer g;
    begin
      @(negedge clk);
      flush_start = 1'b1;
      @(negedge clk);
      flush_start = 1'b0;
      g = 0;
      while (!flush_done && g < 200000) begin @(posedge clk); g = g + 1; end
      if (!flush_done) $fatal(1, "the I$ native flush never finished");
      settle(4);
    end
  endtask

  // The CPU store patch: what cache_unit relays from the D$'s store. patch_valid/data/be reach
  // the TAG-MATCHED line - it is cleared so the next fetch refills, and the bytes are queued in
  // the leaf's OWN patchq so that refill carries them (src/z486/docs/coherency-audit.md C9). The retired
  // form pulsed a D$-store-queue snoop pair and held the data in the store queue instead.
  task automatic store_patch(input [31:0] a, input [31:0] data);
    begin
      patch_addr = a; patch_data = data; patch_be = 4'hF; patch_valid = 1'b1;
      @(negedge clk);
      patch_valid = 1'b0; patch_be = 4'h0;
      settle(3);
    end
  endtask

  reg        refilled;
  reg [127:0] line;

  // ==== CHECKS ====
  initial begin
    settle(4);
    reset = 1'b0;
    settle(20);

    // ------------------------------------------------------------------
    // (a) cpu-int F2: the 0x043F=0xA0 pass (base 0, 2048 lines) must clear
    //     the WHOLE I$. A line whose tag matches nothing in 0x00000-0x07FFF
    //     is the case a tag-matched invalidator leaves behind.
    // ------------------------------------------------------------------
    $display("NOTE icache_flush_scope: --- (a) the 0xA0 whole-cache pass ---");
    fetch(32'h0002_0000, refilled, line);              // warm 0x20000 (miss -> fill)
    expect_hit(32'h0002_0000, "(a) warm line hits");
    flush_all();                                       // the native whole-L1 walk
    expect_miss(32'h0002_0000, "(a) 0x20000 cleared by the native flush");
    // The matched half is the control: a line INSIDE the swept range dies too,
    // so (a) cannot pass by the invalidation never reaching the cache at all.
    fetch(32'h0000_1000, refilled, line);
    flush_all();
    expect_miss(32'h0000_1000, "(a) 0x1000 (in range) cleared");

    // ------------------------------------------------------------------
    // (b) The SMC patch path stays TAG-MATCHED (the fix's other half): a
    //     patch to one line patches/invalidates that line only - a same-set
    //     neighbour keeps its line - and the refetched line carries the
    //     patched bytes.
    // ------------------------------------------------------------------
    $display("NOTE icache_flush_scope: --- (b) the store patch stays tag-matched ---");
    fetch(32'h0003_0000, refilled, line);              // set 0, tag A
    fetch(32'h0005_0000, refilled, line);              // set 0, tag B (a neighbour)
    expect_hit(32'h0005_0000, "(b) neighbour warms");
    store_patch(32'h0003_0004, 32'hA5A5_5A5A);
    expect_hit(32'h0005_0000, "(b) neighbour survives the patch");
    fetch(32'h0003_0000, refilled, line);              // must refetch, merged
    checks = checks + 1;
    if (!refilled) begin
      $display("FAIL (b): the patched line 0x30000 still HIT");
      errors = errors + 1;
    end
    checks = checks + 1;
    if (line[32 +: 32] !== 32'hA5A5_5A5A) begin
      $display("FAIL (b): refetched word 1 is %08x, want a5a55a5a", line[32 +: 32]);
      errors = errors + 1;
    end

    // ------------------------------------------------------------------
    // (c) cpu-int F3 / src/z486/docs/coherency-audit.md C9: THE LOOKUP-VS-PATCH RACE, SWEPT OVER ITS
    //     ALIGNMENT. The D$->I$ patch and the I$ fetch are independent, so the lead between them
    //     is arbitrary; the retired single-alignment leg pinned one (the fetch accepted on the
    //     clear's commit edge) and the rewrite's own experiment showed that leg is the case the
    //     rewritten leaf's guard does NOT cover, so this walks the lead instead of assuming it.
    //     A response is correct if it refilled, or if it already carries the patched word; a
    //     stale pre-patch word with no backend traffic is the failure. L sits in set 1, clear of
    //     (b)'s set-0 churn.
    // ------------------------------------------------------------------
    $display("NOTE icache_flush_scope: --- (c) the lookup-vs-patch race, swept over its lead ---");
    for (coff = 0; coff <= 4; coff = coff + 1) begin : lead_sweep
      fetch(32'h0006_0010, refilled, line);            // re-warm for this lead
      expect_hit(32'h0006_0010, "(c) 0x60010 warms");
      while (!i_cpu_ready) @(negedge clk);
      settle(2);
      @(negedge clk);
      patch_addr = 32'h0006_0010; patch_data = 32'h5A5A_A5A5;
      patch_be = 4'hF; patch_valid = 1'b1;
      @(negedge clk);
      patch_valid = 1'b0; patch_be = 4'h0;
      repeat (coff) @(negedge clk);
      acc_mark = mem_accepts;
      i_cpu_addr = 32'h0006_0010; i_cpu_valid = 1'b1;
      @(negedge clk);
      i_cpu_valid = 1'b0;
      begin : race_wait
        integer g;
        g = 0;
        while (!i_cpu_resp_valid && g < 2000) begin @(negedge clk); g = g + 1; end
        if (!i_cpu_resp_valid)
          $fatal(1, "the raced fetch of 0x60010 never responded (lead %0d)", coff);
      end
      checks = checks + 1;
      if ((mem_accepts == acc_mark) && (i_cpu_line[0 +: 32] !== 32'h5A5A_A5A5)) begin
        $display("FAIL (c) lead %0d: stale hit (word 0 = %08x, no refill)",
                 coff, i_cpu_line[0 +: 32]);
        errors = errors + 1;
      end
      settle(4);
    end

    // ------------------------------------------------------------------
    // (d) memmap F2 (I$ half): the bank-flip sweep covers 0xF8000-0xFFFFF;
    //     the SAME window's high alias at 0xFFFF8000 must lose its lines too.
    //     The line sits in set 2, clear of (b)/(c)'s churn.
    // ------------------------------------------------------------------
    $display("NOTE icache_flush_scope: --- (d) the fw_high alias after a bank flip ---");
    fetch(32'hFFFF_8020, refilled, line);              // warm the alias line (set 2)
    expect_hit(32'hFFFF_8020, "(d) 0xFFFF8020 warms");
    flush_all();                                       // the native walk reaches the alias too
    expect_miss(32'hFFFF_8020, "(d) 0xFFFF8020 cleared with the bank window");

    $display("TB_PC9821_ICACHE_FLUSH_SCOPE: %0d scope check(s), %0d mismatch(es)",
             checks, errors);
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ICACHE_FLUSH_SCOPE: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_ICACHE_FLUSH_SCOPE: FAIL (%0d errors)", errors);
  end

endmodule

`default_nettype wire

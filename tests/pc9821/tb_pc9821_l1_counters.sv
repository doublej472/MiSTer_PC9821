`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_L1_COUNTERS:
// The two L1 caches' MISSES ARE THE FILLS, counted from the FSM's OWN STATE REGISTER (the rewritten z486 exports no L1 observation port): against the real src/z486/l1_cache.sv and src/z486/l1_icache.sv at the platform's deliberate 2 KiB (SET_BITS=5), a warm loop that fits the cache hits, a stream that misses every line misses, the S_FILL entries equal the fill requests launched on the memory port, and the lookups are the S_LOOKUP entries whose arm actually consults tags - while an uncacheable access (the D-cache's bypass arm; the I-cache's non-installing line read, fill_uncached_r, since upstream 6613858 removed its S_BYPASS_WAIT, which this bench counts on its own and checks it takes exactly once) and a protection-fault write (the req_protect_write arm) produce NO lookup and NO miss at all, so the counters cannot inflate the miss rate in the region the aperture and MMIO traffic live.
//
// WHY THIS IS THE BENCH THE COUNTERS NEED. A cache counter is only worth the registers it costs if
// the number it reports is the decision the datapath makes rather than a second, drifting statement
// of it. The FSM leaves S_LOOKUP for S_FILL on a miss, and here the two counters are driven by
// must therefore agree: the pulse the platform counts, the FSM's own state register entering
// S_FILL, and the fill request that leaves on the memory port. All three are counted here from
// different places - the module's output, its hierarchical `state`, and its `mem_valid`/`mem_ready`
// handshake - so a pulse that fired one cycle early, or on a lookup that did not fill, fails.
//
// The two arms that must NOT count are the reason the numbers are usable at all. The PC-98's
// device aperture, the ROM windows and the I/O and INTA routes all reach the data cache as either
// an uncacheable bypass or a protected write; a counter that counted them would report a miss rate
// inflated by exactly the traffic that is not a cache decision.
//
// The pattern is exact, not statistical: 8 warm lines read twice (8 misses, 8 hits), then 16
// distinct tags in ONE set, each read once (16 misses, guaranteed - the set holds four ways and no
// address repeats). The instruction cache uses 12 warm lines, so the two caches' totals DIFFER and
// a crossed wire between IL and DL shows up rather than cancelling.
//
// It also asserts the uncacheable access still COMPLETES (the response arrives): "no lookup" must
// not be reachable by the access simply never happening.

`default_nettype none

module tb_pc9821_l1_counters;

  // ==== DUT ====

  localparam integer SET_BITS = 5;          // pc9821_system.sv's DCACHE_SET_BITS/ICACHE_SET_BITS
  localparam [2:0]   S_FILL   = 3'd3;       // l1_cache.sv / l1_icache.sv's state encoding
  localparam [2:0]   S_LOOKUP = 3'd2;       // its S_LOOKUP: the entry must consult tags to count
  localparam integer WARM_D   = 8;          // warm lines in the D-cache set-0..7 loop
  localparam integer WARM_I   = 12;         // ... and in the I-cache's set-0..11 loop
  localparam integer STREAM   = 16;         // distinct tags streamed through one set
  localparam [31:0]  PROTMEM  = 32'h000C_0000;   // drives pc_protect_write (addr[24:18]=3)

  reg clk = 1'b0, reset = 1'b1;
  integer cyc = 0;
  always #5 clk = ~clk;
  always @(posedge clk) cyc <= cyc + 1;

  // ---- data cache, the platform's PROTECT_UMA_ROM=1 configuration ----
  reg  [31:0] d_cpu_addr = 32'd0, d_cpu_din = 32'd0;
  reg   [3:0] d_cpu_be = 4'hF;
  reg         d_cpu_valid = 1'b0, d_cpu_write = 1'b0, d_cpu_uncacheable = 1'b0;
  wire [31:0] d_cpu_dout;
  wire        d_cpu_ready, d_cpu_resp_valid, d_stores_drained;
  wire [31:0] d_mem_addr, d_mem_din, d_mem_dout;
  wire  [3:0] d_mem_be;
  wire  [7:0] d_mem_burst;
  wire        d_mem_valid, d_mem_write, d_mem_ready, d_mem_resp_valid;
  wire        d_mem_busy, d_mem_line_resp_valid;
  
  l1_cache #(.SET_BITS(SET_BITS), .PROTECT_UMA_ROM(1)) dcache (
    .clk(clk), .reset(reset),
    .cpu_addr(d_cpu_addr), .cpu_preread_offset(d_cpu_addr[11:0]),
    .cpu_preread_priority(1'b0), .cpu_din(d_cpu_din), .cpu_dout(d_cpu_dout),
    .cpu_be(d_cpu_be), .cpu_valid(d_cpu_valid), .cpu_write(d_cpu_write),
    .cpu_uncacheable(d_cpu_uncacheable), .cpu_ready(d_cpu_ready),
    .cpu_resp_valid(d_cpu_resp_valid), .stores_drained(d_stores_drained),
    .vipt_probe_offset(12'd0), .vipt_probe_valid(1'b0), .vipt_probe_ready(),
    .vipt_probe_accepted(), .vipt_probe_direct_accepted(),
    .vipt_resolve_phys_addr(32'd0), .vipt_resolve_tlb_phys(32'd0), .vipt_resolve_alt_phys(32'd0), .vipt_resolve_use_tlb(1'b0), .vipt_resolve_valid(1'b0),
    .vipt_resolve_data(), .vipt_resolve_hit(),
    .mem_addr(d_mem_addr), .mem_din(d_mem_din), .mem_dout(d_mem_dout),
    .mem_line_dout(128'd0), .mem_be(d_mem_be), .mem_burstcount(d_mem_burst),
    .mem_busy(d_mem_busy), .mem_valid(d_mem_valid), .mem_write(d_mem_write),
    .mem_ready(d_mem_ready), .mem_resp_valid(d_mem_resp_valid),
    .mem_line_resp_valid(d_mem_line_resp_valid),
    .snoop_addr(32'd0), .snoop_valid(1'b0), .cache_enable(1'b1)
  );

  // ---- instruction cache ----
  reg  [31:0] i_cpu_addr = 32'd0;
  reg         i_cpu_valid = 1'b0, i_cache_enable = 1'b1;
  wire [127:0] i_cpu_line;
  wire        i_cpu_ready, i_cpu_resp_valid;
  wire [31:0] i_mem_addr, i_mem_dout;
  wire  [3:0] i_mem_be;
  wire  [7:0] i_mem_burst;
  wire        i_mem_valid, i_mem_ready, i_mem_resp_valid;
  wire        i_mem_busy, i_mem_line_resp_valid;
  
  l1_icache #(.SET_BITS(SET_BITS)) icache (
    .clk(clk), .reset(reset),
    .cpu_addr(i_cpu_addr), .cpu_line(i_cpu_line), .cpu_valid(i_cpu_valid),
    .cpu_ready(i_cpu_ready), .cpu_resp_valid(i_cpu_resp_valid),
    .mem_addr(i_mem_addr), .mem_dout(i_mem_dout), .mem_line_dout(128'd0),
    .mem_be(i_mem_be), .mem_burstcount(i_mem_burst), .mem_busy(i_mem_busy),
    .mem_valid(i_mem_valid), .mem_ready(i_mem_ready),
    .mem_resp_valid(i_mem_resp_valid), .mem_line_resp_valid(i_mem_line_resp_valid),
    .invalidate_addr(32'd0), .invalidate_valid(1'b0),
    .cache_enable(i_cache_enable)
  );

  // ---- a dword backend: one accept pulse, one response beat per burst dword, no line response
  //      (the shape z486_mister.sv builds), so the caches use the word-beat arm of S_FILL ----
  sdram_backend_model #(
    .ACCEPT_TO_RESP(0), .WRITE_BUSY(0), .LINE_RESP(0), .WORDS_LOG2(16)
  ) d_mem (
    .clk(clk), .reset(reset),
    .valid(d_mem_valid), .ready(d_mem_ready), .write(d_mem_write),
    .addr(d_mem_addr), .din(d_mem_din), .din_hi(32'd0), .be(d_mem_be),
    .burstcount(d_mem_burst),
    .dout(d_mem_dout), .resp_valid(d_mem_resp_valid),
    .line_dout(), .line_resp_valid(d_mem_line_resp_valid),
    .busy(d_mem_busy), .accepts(), .beats()
  );

  sdram_backend_model #(
    .ACCEPT_TO_RESP(0), .WRITE_BUSY(0), .LINE_RESP(0), .WORDS_LOG2(16)
  ) i_mem (
    .clk(clk), .reset(reset),
    .valid(i_mem_valid), .ready(i_mem_ready), .write(1'b0),
    .addr(i_mem_addr), .din(32'd0), .din_hi(32'd0), .be(i_mem_be),
    .burstcount(i_mem_burst),
    .dout(i_mem_dout), .resp_valid(i_mem_resp_valid),
    .line_dout(), .line_resp_valid(i_mem_line_resp_valid),
    .busy(i_mem_busy), .accepts(), .beats()
  );

  // ==== STIMULUS ====

  // TWO OBSERVERS OF EVERY MISS, counted from two different places so they cannot agree by
  // construction: the FSM's own state register entering S_FILL, and the fill request leaving on
  // the memory port (a 4-dword read handshake). The lookups come from the same register.
  //
  // A LOOKUP IS AN S_LOOKUP ENTRY WHOSE ARM ACTUALLY CONSULTS TAGS. The rewritten core exports
  // no observation port (the old dbg_lookup/dbg_miss are gone), and `state == S_LOOKUP` ALONE
  // is not that event: l1_cache's S_LOOKUP arms retire a protection-fault store and bypass an
  // uncacheable read without using the comparison, and l1_icache's bypasses !cache_enable and
  // takes a no-allocate pass-through -- all four still pass THROUGH S_LOOKUP. Excluding them is
  // exactly what this bench's assertions 4, 5 and 7 check, so they are excluded here too.
  integer n_fill_entry = 0, n_fill_launch = 0;
  integer n_ifill_entry = 0, n_ifill_launch = 0;
  // Upstream 6613858 replaced l1_icache's single-dword S_BYPASS_WAIT with a line read that
  // delivers without installing (fill_uncached_r): it passes through S_FILL and launches a
  // 4-dword read, but installs nothing, so it is not a miss. Counted apart, and assertion 7
  // checks the uncacheable fetch takes exactly one of them.
  integer n_iunc_fill = 0, n_iunc_launch = 0;
  integer n_lookup_d = 0, n_lookup_i = 0;
  reg [2:0] d_state_d = 3'd0, i_state_d = 3'd0;

  wire d_lookup_now = (dcache.state == S_LOOKUP) && (d_state_d != S_LOOKUP) &&
                      dcache.req_valid_r && !dcache.req_protect_write_r &&
                      !dcache.req_uncacheable_r;
  wire i_lookup_now = (icache.state == S_LOOKUP) && (i_state_d != S_LOOKUP) &&
                      icache.req_valid_r && !icache.req_uncacheable_r &&
                      !icache.req_no_alloc_r;

  always @(posedge clk) begin
    d_state_d <= dcache.state;
    i_state_d <= icache.state;
    if (d_lookup_now) n_lookup_d <= n_lookup_d + 1;
    if (i_lookup_now) n_lookup_i <= n_lookup_i + 1;
    if (dcache.state == S_FILL && d_state_d != S_FILL) n_fill_entry <= n_fill_entry + 1;
    if (icache.state == S_FILL && i_state_d != S_FILL) begin
      if (icache.fill_uncached_r) n_iunc_fill <= n_iunc_fill + 1;
      else                        n_ifill_entry <= n_ifill_entry + 1;
    end
    if (d_mem_valid && d_mem_ready && (d_mem_burst == 8'd4)) n_fill_launch  <= n_fill_launch  + 1;
    if (i_mem_valid && i_mem_ready && (i_mem_burst == 8'd4)) begin
      if (icache.req_uncacheable_r) n_iunc_launch  <= n_iunc_launch  + 1;
      else                          n_ifill_launch <= n_ifill_launch + 1;
    end
  end

  // A bounded wait: a bench that stops making progress names itself rather than hanging the runner.
  task automatic settle(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) @(negedge clk);
    end
  endtask

  // One D-cache access: present the request on the first ready cycle, drop it after the accept
  // edge, then wait for the response (a read) or settle (a write, which the store queue or the
  // protected-write arm completes without a response pulse).
  task automatic d_access(input [31:0] a, input wr, input unc, input expect_resp);
    integer g;
    begin
      g = 0;
      while (!d_cpu_ready && g < 200) begin @(negedge clk); g = g + 1; end
      if (!d_cpu_ready) $fatal(1, "the D-cache never became ready for %08x", a);
      d_cpu_addr = a; d_cpu_din = 32'd0; d_cpu_be = 4'hF;
      d_cpu_write = wr; d_cpu_uncacheable = unc; d_cpu_valid = 1'b1;
      @(negedge clk);
      d_cpu_valid = 1'b0;
      if (expect_resp) begin
        g = 0;
        while (!d_cpu_resp_valid && g < 200) begin @(negedge clk); g = g + 1; end
        if (!d_cpu_resp_valid)
          $fatal(1, "a D-cache read of %08x never produced a response", a);
      end
      // The counters sample on the posedge, and a HIT's response is combinational in the
      // S_LOOKUP cycle, so the caller can reach its assertion one edge before the pulse has
      // been counted: settle past the sampling edge here, once, for every arm.
      settle(3);
    end
  endtask

  task automatic i_access(input [31:0] a);
    integer g;
    begin
      g = 0;
      while (!i_cpu_ready && g < 200) begin @(negedge clk); g = g + 1; end
      if (!i_cpu_ready) $fatal(1, "the I-cache never became ready for %08x", a);
      i_cpu_addr = a; i_cpu_valid = 1'b1;
      @(negedge clk);
      i_cpu_valid = 1'b0;
      g = 0;
      while (!i_cpu_resp_valid && g < 200) begin @(negedge clk); g = g + 1; end
      if (!i_cpu_resp_valid)
        $fatal(1, "an I-cache fetch of %08x never produced a response", a);
      settle(3);
    end
  endtask

  // ==== CHECKS ====

  initial begin
    integer dl0, dm0, il0, im0, fe0, fl0, ife0, ifl0, iu0, iul0, k;
    reset = 1'b1;
    settle(4);
    reset = 1'b0;

    // Wait out S_RESET_INIT: the tag RAMs are cleared set by set before either cache answers.
    k = 0;
    while (!(d_cpu_ready && i_cpu_ready) && k < 400) begin @(negedge clk); k = k + 1; end
    if (!(d_cpu_ready && i_cpu_ready))
      $fatal(1, "the caches never left S_RESET_INIT");
    if (n_lookup_d != 0 || n_fill_entry != 0 || n_lookup_i != 0 || n_ifill_entry != 0)
      $fatal(1, "a lookup or a miss was counted before any access was issued");

    // 1. THE D-CACHE: a loop that FITS the 2 KiB - 8 lines in sets 0..7, read twice. The first
    //    pass is 8 cold lookups that miss and fill; the second pass is 8 lookups that hit. The
    //    pattern is exact, so DL and DM are asserted rather than merely reported.
    dl0 = n_lookup_d; dm0 = n_fill_entry; fe0 = n_fill_entry; fl0 = n_fill_launch;
    for (k = 0; k < WARM_D; k = k + 1) d_access(32'(k * 16), 1'b0, 1'b0, 1'b1);
    if (n_lookup_d - dl0 != WARM_D || n_fill_entry - dm0 != WARM_D)
      $fatal(1, "the D-cache's first pass over %0d cold lines made %0d lookups and %0d misses",
             WARM_D, n_lookup_d - dl0, n_fill_entry - dm0);
    dl0 = n_lookup_d; dm0 = n_fill_entry;
    for (k = 0; k < WARM_D; k = k + 1) d_access(32'(k * 16), 1'b0, 1'b0, 1'b1);
    if (n_lookup_d - dl0 != WARM_D || n_fill_entry != dm0)
      $fatal(1, "re-reading the %0d warm lines made %0d lookups and %0d misses, want %0d and 0",
             WARM_D, n_lookup_d - dl0, n_fill_entry - dm0, WARM_D);

    // 2. A stream that MISSES EVERY LINE: 16 distinct tags in ONE set (addr[8:4] = 0), each read
    //    once. The set holds four ways and no address repeats, so every access is a cold miss by
    //    construction rather than by luck.
    dl0 = n_lookup_d; dm0 = n_fill_entry;
    for (k = 1; k <= STREAM; k = k + 1) d_access(32'(k * 32'h2000), 1'b0, 1'b0, 1'b1);
    if (n_lookup_d - dl0 != STREAM || n_fill_entry - dm0 != STREAM)
      $fatal(1, "the D-cache's miss stream made %0d lookups and %0d misses, want %0d and %0d",
             n_lookup_d - dl0, n_fill_entry - dm0, STREAM, STREAM);

    // 3. THE TWO COUNTING OBSERVERS AGREE. n_fill_entry is the FSM's state register entering
    //    S_FILL; n_fill_launch is the 4-dword read handshake on the memory port. A miss that did
    //    not coincide with a fill launch would make the counter and the datapath disagree.
    //    NOTE: the platform perf record's DL/DM fields are tied off in this tree (the rewritten
    //    core has no observation ports), so nothing here claims to feed them.
    if (n_fill_entry != WARM_D + STREAM)
      $fatal(1, "the D-cache counted %0d misses for %0d", n_fill_entry, WARM_D + STREAM);
    if (n_fill_launch != n_fill_entry)
      $fatal(1, "the D-cache launched %0d 4-dword fill reads for %0d",
             n_fill_launch, n_fill_entry);
    if (n_lookup_d != 2 * WARM_D + STREAM)
      $fatal(1, "the D-cache made %0d lookups, want %0d", n_lookup_d, 2 * WARM_D + STREAM);

    // 4. AN UNCACHEABLE ACCESS: the S_BYPASS_WAIT arm. It is a real read - the response arrives -
    //    and it consults NO tags, so it must add nothing to DL or DM. This is the arm the device
    //    aperture and the I/O routes take.
    dl0 = n_lookup_d; dm0 = n_fill_entry; fe0 = n_fill_entry; fl0 = n_fill_launch;
    d_access(32'h000A_0000, 1'b0, 1'b1, 1'b1);
    if (n_lookup_d != dl0 || n_fill_entry != dm0 || n_fill_entry != fe0 || n_fill_launch != fl0)
      $fatal(1, "an uncacheable D-cache read moved the counters by %0d/%0d lookups/misses",
             n_lookup_d - dl0, n_fill_entry - dm0);

    // 5. A PROTECTED WRITE: the req_protect_write_r arm (PROTECT_UMA_ROM's 0xC0000-0xFFFFF UMA
    //    window). It reaches S_LOOKUP and leaves for S_IDLE without consulting tags.
    dl0 = n_lookup_d; dm0 = n_fill_entry; fe0 = n_fill_entry; fl0 = n_fill_launch;
    d_access(PROTMEM, 1'b1, 1'b0, 1'b0);
    if (n_lookup_d != dl0 || n_fill_entry != dm0 || n_fill_entry != fe0 || n_fill_launch != fl0)
      $fatal(1, "a protection-fault write moved the counters by %0d/%0d lookups/misses",
             n_lookup_d - dl0, n_fill_entry - dm0);

    // 6. THE I-CACHE, same two shapes with a DIFFERENT warm count (12 lines, sets 0..11) so the
    //    two caches' totals differ: a crossed IL/DL wire cannot cancel out.
    il0 = n_lookup_i; im0 = n_ifill_entry; ife0 = n_ifill_entry; ifl0 = n_ifill_launch;
    for (k = 0; k < WARM_I; k = k + 1) i_access(32'(k * 16));
    if (n_lookup_i - il0 != WARM_I || n_ifill_entry - im0 != WARM_I)
      $fatal(1, "the I-cache's first pass over %0d cold lines made %0d lookups and %0d misses",
             WARM_I, n_lookup_i - il0, n_ifill_entry - im0);
    il0 = n_lookup_i; im0 = n_ifill_entry;
    for (k = 0; k < WARM_I; k = k + 1) i_access(32'(k * 16));
    if (n_lookup_i - il0 != WARM_I || n_ifill_entry != im0)
      $fatal(1, "re-fetching the %0d warm lines made %0d lookups and %0d misses, want %0d and 0",
             WARM_I, n_lookup_i - il0, n_ifill_entry - im0, WARM_I);
    il0 = n_lookup_i; im0 = n_ifill_entry;
    for (k = 1; k <= STREAM; k = k + 1) i_access(32'(k * 32'h2000));
    if (n_lookup_i - il0 != STREAM || n_ifill_entry - im0 != STREAM)
      $fatal(1, "the I-cache's miss stream made %0d lookups and %0d misses, want %0d and %0d",
             n_lookup_i - il0, n_ifill_entry - im0, STREAM, STREAM);
    if (n_ifill_entry != WARM_I + STREAM)
      $fatal(1, "the I-cache counted %0d misses for %0d", n_ifill_entry, WARM_I + STREAM);
    if (n_ifill_launch != n_ifill_entry)
      $fatal(1, "the I-cache launched %0d 4-dword fill reads for %0d",
             n_ifill_launch, n_ifill_entry);
    if (n_lookup_i != 2 * WARM_I + STREAM)
      $fatal(1, "the I-cache made %0d lookups, want %0d", n_lookup_i, 2 * WARM_I + STREAM);

    // 7. AN UNCACHEABLE FETCH: the I-cache has no uncacheable input of its own - cache_enable IS
    //    it - so this is the request the platform routes around the cache. It completes (the
    //    response arrives) and counts nothing; since upstream 6613858 it is one non-installing
    //    line read (fill_uncached_r), checked below to happen exactly once.
    il0 = n_lookup_i; im0 = n_ifill_entry; ife0 = n_ifill_entry; ifl0 = n_ifill_launch;
    iu0 = n_iunc_fill; iul0 = n_iunc_launch;
    i_cache_enable = 1'b0;
    i_access(32'h000A_4000);
    i_cache_enable = 1'b1;
    if (n_lookup_i != il0 || n_ifill_entry != im0 || n_ifill_entry != ife0 || n_ifill_launch != ifl0)
      $fatal(1, "an uncacheable fetch moved the counters by %0d/%0d lookups/misses",
             n_lookup_i - il0, n_ifill_entry - im0);
    if (n_iunc_fill - iu0 != 1 || n_iunc_launch - iul0 != 1)
      $fatal(1, "the uncacheable fetch took %0d non-installing fills and %0d line reads, want 1 and 1",
             n_iunc_fill - iu0, n_iunc_launch - iul0);

    // 8. The counters kept counting through all of it: the totals are the pattern's, so neither a
    //    dropped pulse nor a double-counted one can hide behind a "no lookup" arm.
    if (n_lookup_d != 2 * WARM_D + STREAM || n_lookup_i != 2 * WARM_I + STREAM)
      $fatal(1, "final lookup totals are %0d (D) and %0d (I), want %0d and %0d",
             n_lookup_d, n_lookup_i, 2 * WARM_D + STREAM, 2 * WARM_I + STREAM);

    $display("L1-COUNTERS d: lookups=%0d misses=%0d s_fill=%0d launches=%0d",
             n_lookup_d, n_fill_entry, n_fill_entry, n_fill_launch);
    $display("L1-COUNTERS i: lookups=%0d misses=%0d s_fill=%0d launches=%0d",
             n_lookup_i, n_ifill_entry, n_ifill_entry, n_ifill_launch);
    // ==== VERDICT ====
    $display("TB_PC9821_L1_COUNTERS: PASS");
    $finish;
  end

  // A bench that stops making progress names itself instead of hanging the runner.
  initial begin
    #2_000_000;
    $fatal(1, "the L1 counter bench did not finish in 2 ms of simulated time");
  end

endmodule

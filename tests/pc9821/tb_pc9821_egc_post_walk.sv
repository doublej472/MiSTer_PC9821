`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_EGC_POST_WALK: the EGC's POSTED writes land by value through the REAL pc9821_gvram (tests/pc9821/pc9821_gvram_dut.sv, on-chip plane store): a 32-bit EGC 0x3100 put after a partial store to its destination word must land the source on every word of the destination dword on all four planes (it failed, words 0x1001/0x1002 never written, before the GVRAM's per-word fallback walk latched its base word), and a 16-bit EGC write followed at once by an EGC READ presented behind the posted write must land both destination bytes (0x1100/0x1101) on all four planes. The fallback walk (pc9821_gvram_arb's m_mode) both scenarios were written for no longer takes the EGC (it serves the plain and GRCG owners, and the write-combining buffer whose dirty hold forced it is gone), so the walk witnesses, gated to each EGC write's own interval and to a WRITE walk, are printed, not asserted: this pins the posted EGC write's data, not the walk or its m_write latch.
//
// HISTORY. The second scenario was written to pin the walk's DIRECTION latch (m_write): a 16-bit
// EGC write whose two-column burst fell back to the per-word walk, with a READ presented behind it
// while the walk drained; a walk that read the client's LIVE `cc_write` took the READ arm for its
// second word (FAIL-FIRST when written, on ef_wr = cc_write). Its walk and race witnesses were
// never gated to the write and were satisfied by the plane_word read-backs' own read walks. Gated
// to each EGC write's interval they read zero: the EGC is not a walk client any more, so both
// scenarios are data checks on the posted EGC write, and the witnesses are printed only.

`default_nettype none

module tb_pc9821_egc_post_walk;
  localparam integer FREQ     = 50_000_000;
  localparam integer CYCLE_NS = 20;

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg reset = 1;

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  localparam [31:0] GVRAM_BASE = 32'h0300_0000;

  // ==== DUT ====
  // ==== DUT ====
  reg  [31:0] gvram_base = GVRAM_BASE;
  reg         access_page = 1'b0;
  reg  [1:0]  win_plane = 2'd0;
  reg [14:0]  win_offset = 15'd0;
  reg [31:0]  cpu_din = 32'd0;
  reg  [3:0]  cpu_be = 4'hF;
  reg         cpu_line_read = 1'b0;
  reg         cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0]  cpu_dout;
  wire [31:0] cpu_line_word;
  wire         cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  reg        grcg_we = 1'b0;
  reg  [7:0] grcg_addr = 8'd0, grcg_din = 8'd0;

  reg        egc_gate = 1'b0;
  reg [15:0] egc_access = 16'hFFF0, egc_fgbg = 16'h00FF, egc_ope = 16'h3100,
             egc_fg = 16'd0, egc_mask = 16'hFFFF, egc_bg = 16'd0,
             egc_sft = 16'd0, egc_leng = 16'd0;
  reg        egc_shift_we = 1'b0;

  reg        scan_enable = 1'b0, scan_line_tick = 1'b0, scan_page = 1'b0;
  reg [14:0] scan_line_base = 15'd0;
  reg  [6:0] line_rd_addr = 7'd0;
  reg        line_rd_sel = 1'b0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;


  pc9821_gvram_dut dut (
      .clk(clk), .reset(reset),
      .access_page(access_page),
      .win_plane(win_plane), .win_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .egc_gate(egc_gate), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
      .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask),
      .egc_bg(egc_bg), .egc_sft(egc_sft), .egc_leng(egc_leng),
      .egc_shift_we(egc_shift_we),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));

  // ---- The real controller, at the built configuration, against the chip model ----

  

  

  integer errors = 0;
  task automatic fail(input [8*200-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  // A CPU plane-window op, the shape z486 presents: dword-aligned, the lane in cpu_be. `pg`
  // chooses the access page (port 0xA6), so page 1 is the source and page 0 the destination.
  task automatic plane_op(input pg, input [1:0] plane, input [14:0] off, input [31:0] din,
                          input [3:0] be, input wr, input egc, output [31:0] dout);
    begin
      @(negedge clk);
      access_page = pg;
      egc_gate   = egc;
      win_plane  = plane;
      win_offset = off;
      cpu_din    = din;
      cpu_be     = be;
      cpu_write  = wr;
      cpu_valid  = 1'b1;
      while (!cpu_ready) @(negedge clk);
      // Released at the ready edge (z486's shape, src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`),
      // before the pipelined produce's response cycle - held into it, the S_IDLE accept
      // takes the request twice. Read values are unchanged (EGCREAD.CSV / the machine vectors).
      // `egc_gate` is the machine's EGC arming level (0x6A num 2 AND 0x7C bit 7), not a per-access
      // signal: it is held through the response and released after it.
      // The negedge below is the old release's own wait, kept so the +1 stays in the cadence.
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
      if (!wr) begin
        while (!cpu_resp_valid) @(negedge clk);
        #1; dout = cpu_dout;
      end else dout = 32'd0;
      @(negedge clk);
      egc_gate = 1'b0;
      while (dut.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
      repeat (2) @(posedge clk);
    end
  endtask

  // Seed one plane byte of one word; off names the word (be selects which word of the dword).
  task automatic seed_byte(input page, input [1:0] plane, input [14:0] off, input [7:0] v);
    reg [31:0] d;
    begin
      plane_op(page, plane, off, {4{v}}, 4'h1 << off[1:0], 1'b1, 1'b0, d);
    end
  endtask

  // A full-dword plane read: byte lane k of `d` is that plane's byte of word (off & ~3) + k.
  task automatic plane_word(input [1:0] plane, input [14:0] off, output [31:0] d);
    begin
      plane_op(1'b0, plane, off, 32'd0, 4'hF, 1'b0, 1'b0, d);
    end
  endtask

  // One PARTIAL byte store (it once left the word DIRTY in the write-combining buffer, which is
  // gone; it stays as the scenario's shape).
  task automatic dirty_store(input [1:0] plane, input [14:0] off, input [7:0] v);
    reg [31:0] d;
    begin
      plane_op(1'b0, plane, off, {4{v}}, 4'h1 << off[1:0], 1'b1, 1'b0, d);
    end
  endtask

  // A raster line tick (the buffer drain it once was has nothing left to drain).
  task automatic flush_wcb;
    begin
      @(negedge clk);
      scan_line_tick = 1'b1;
      @(negedge clk);
      scan_line_tick = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  // Destination word (0x1000+k) plane p must carry this after a correct 0x3100 put. The source
  // is UNIFORM per plane (a 32-bit put's pattern register ends on the access's LAST unit, so a
  // per-word source cannot be a word-for-word expectation); the destination is seeded to a
  // DISTINCT value so a word the write never reaches is still detected.
  function automatic [7:0] src_byte(input integer p);
    src_byte = 8'hA0 + p;
  endfunction
  function automatic [7:0] dst_seed(input integer p);
    dst_seed = 8'h50 + p;
  endfunction

  integer s, k, mism;
  integer mism2;
  // The witnesses count ONLY inside `win_on`, the interval from the EGC write's presentation to
  // the end of the access behind it, and only a WRITE walk (the walk's latched direction m_write):
  // a plain multi-lane read also walks (cs == C_MWAIT -> the m_mode walk with cc_write low), so
  // ungated counters were satisfied by the plane_word read-backs themselves.
  reg win_on = 1'b0;
  // A witness that the direction scenario really took the per-word fallback walk
  // (pc9821_gvram_arb's m_mode) as a WRITE walk: a change that made its burst legal would turn
  // it into a plain burst that passes for the wrong reason.
  integer walk_cycles = 0, walk_before = 0;
  always @(posedge clk) if (win_on && dut.u_arb.m_mode && dut.u_arb.m_write) walk_cycles = walk_cycles + 1;
  // ...and that the race really happens: the client's LIVE write flag (cc_write) drops for the
  // read behind the write while that write walk still runs. A read presented only after the walk
  // drained would test nothing.
  integer race_cycles = 0;
  always @(posedge clk)
    if (win_on && dut.u_arb.m_mode && dut.u_arb.m_write && !dut.u_arb.cc_write) race_cycles = race_cycles + 1;
  reg [31:0] d0;

  // ==== CHECKS ====
  initial begin
    reset  = 1'b1;
    repeat (8) @(posedge clk);
    s = 0;
    repeat (20) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);


    // ---- Seed page 1's source dword at 0x1000 (uniform per plane) and page 0's destination
    //      dword to a DISTINCT value, so a word the EGC write never reaches is still detected.
    //      Every word of the destination must take the source value. ----
    for (k = 0; k < 4; k = k + 1) begin
      for (s = 0; s < 4; s = s + 1) begin
        seed_byte(1'b1, s[1:0], 15'h1000 + k[14:0], src_byte(s));
        seed_byte(1'b0, s[1:0], 15'h1000 + k[14:0], dst_seed(s));
      end
    end
    flush_wcb();

    // ---- EGC 0x3100 setup and the 32-bit READ half (loads the pattern register). ----
    egc_access = 16'hFFF0;
    egc_fgbg   = 16'h00FF;
    egc_ope    = 16'h3100;
    egc_mask   = 16'hFFFF;
    @(negedge clk); egc_sft = 16'h0000; egc_leng = 16'h000F; egc_shift_we = 1'b1;
    @(negedge clk); egc_shift_we = 1'b0;
    begin : read_half
      reg [31:0] d;
      // A PLOAD_R (RL_MEMREAD) read latches the SELECTED PAT plane only - "Normal PLOAD_R loads
      // the selected PAT plane only.  Four-plane PAT setup uses four selected reads" (the
      // PC98_EGC_CONFORMANCE v1.3 README; its RD02_PAT_S0..S3 rows, replayed by
      // tb_pc9821_egc_compare section 3), where NP2kai latches all four from one read. So the
      // 0x4A2 read-plane selector walks 0..3 over the same source address.
      for (s = 0; s < 4; s = s + 1) begin
        egc_fgbg = {6'h00, s[1:0], 6'h00, s[1:0]};
        @(negedge clk);
        plane_op(1'b1, 2'd0, 15'h1000, 32'd0, 4'hF, 1'b0, 1'b1, d);
      end
      egc_fgbg = 16'h00FF;
    end

    // ---- Dirty the destination word (page 0, plane 0, offset 0x1000) so the EGC's write
    //      burst is not legal as one request and falls back to the per-word walk. ----
    dirty_store(2'd0, 15'h1000, 8'h5A);

    // ---- The 32-bit EGC WRITE half: two 16-bit units. Unit 0's burst sees the dirty hold. ----
    begin : write_half
      reg [31:0] d;
      win_on = 1'b1;
      plane_op(1'b0, 2'd0, 15'h1000, 32'h0, 4'hF, 1'b1, 1'b1, d);
      win_on = 1'b0;
    end
    flush_wcb();
    repeat (20) @(posedge clk);

    // (The 32-bit scenario no longer reaches the walk: the write-combining buffer whose dirty
    // hold sent it there is gone, so the posted 32-bit put is an ordinary burst now. Measured
    // here, not asserted; its by-value check below still pins that every word lands.)
    $display("NOTE egc_post_walk: the 32-bit scenario's write spent %0d cycles in a write walk", walk_cycles - walk_before);
    // ---- Read the destination dword back, per plane, and check it BY VALUE. ----
    mism = 0;
    for (s = 0; s < 4; s = s + 1) begin
      plane_word(s[1:0], 15'h1000, d0);
      for (k = 0; k < 4; k = k + 1)
        if (d0[8*k +: 8] !== src_byte(s)) begin
          mism = mism + 1;
          $display("FAIL egc_post_walk: dest word 0x%04x plane %0d = 0x%02x, expected 0x%02x",
                   15'h1000 + k, s, d0[8*k +: 8], src_byte(s));
        end
    end

    if (mism != 0)
      fail("the posted 32-bit EGC put did not land every word of the destination dword");
    else
      $display("NOTE egc_post_walk: the posted 32-bit EGC put landed every word of the dword");

    // ==== THE WALK'S DIRECTION IS LATCHED AT THE ACCEPT (the m_write fix) ====
    // A 16-bit EGC write whose two-column burst is not legal (the destination word is DIRTY)
    // falls back to the per-word walk. The EGC advances on the ACCEPT, so it completes this
    // 16-bit access and can present the NEXT access - a READ - while the walk is still draining.
    // The walk must keep WRITING both of its words: a walk that reads the client's LIVE
    // `cc_write` sees it drop to 0 for that read and takes the READ arm for its second word,
    // which then never reaches SDRAM. (The 32-bit scenario above holds cc_write high through
    // both units, so it cannot see this.)
    mism2 = 0;
    walk_before = walk_cycles;
    race_cycles = 0;
    // Dirty ONLY the destination's SECOND word (0x1101). The burst covers [0x1100, 0x1101], so
    // its dirty hold still sends the pair down the fallback walk - but word 0 (0x1100, never
    // written) MISSES the buffer and takes the slow B_WB arm, which is the window the read needs.
    for (s = 0; s < 4; s = s + 1) begin
      seed_byte(1'b1, s[1:0], 15'h1100, src_byte(s));
      seed_byte(1'b1, s[1:0], 15'h1101, src_byte(s));
      seed_byte(1'b0, s[1:0], 15'h1101, dst_seed(s));
    end
    flush_wcb();

    // Load the pattern register with a 16-bit READ of the source.
    plane_op(1'b1, 2'd0, 15'h1100, 32'd0, 4'h3, 1'b0, 1'b1, d0);
    // Dirty the destination's second word so the write's two-column burst is not legal.
    dirty_store(2'd0, 15'h1101, 8'h5A);

    // The 16-bit EGC WRITE: hold the bus only until cpu_ready, then present the READ.
    @(negedge clk);
    win_on      = 1'b1;
    access_page = 1'b0;
    egc_gate    = 1'b1;
    win_plane   = 2'd0;
    win_offset  = 15'h1100;
    cpu_din     = 32'd0;
    cpu_be      = 4'h3;
    cpu_write   = 1'b1;
    cpu_valid   = 1'b1;
    while (!cpu_ready) @(negedge clk);
    // Let the EGC return to S_IDLE (it needs one cpu_valid-low cycle), then present a READ so it
    // drops cl_write (cc_write) while the fallback walk is still in flight.
    cpu_valid = 1'b0;
    cpu_write = 1'b0;
    cpu_be    = 4'h0;
    @(negedge clk);
    win_offset = 15'h1100;
    cpu_be     = 4'h3;
    cpu_write  = 1'b0;
    cpu_valid  = 1'b1;
    k = 0;
    while (!cpu_ready && (k < 4000)) begin @(negedge clk); k = k + 1; end
    if (!cpu_ready) fail("walk direction: the read behind the posted write never completed");
    // Released at the ready edge (z486's shape, src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`),
    // before the pipelined produce's response cycle (see plane_op): held into it, the S_IDLE
    // accept takes the request twice (R6/R8). `egc_gate` is the arming level and stays.
    cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
    k = 0;
    while (!cpu_resp_valid && (k < 4000)) begin @(negedge clk); k = k + 1; end
    if (!cpu_resp_valid) fail("walk direction: the read behind the posted write never returned data");
    @(negedge clk);
    egc_gate = 1'b0;
    while (dut.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
    while (dut.u_arb.m_mode) @(negedge clk);
    win_on = 1'b0;
    flush_wcb();
    repeat (20) @(posedge clk);

    for (s = 0; s < 4; s = s + 1) begin
      plane_word(s[1:0], 15'h1100, d0);
      for (k = 0; k < 2; k = k + 1)
        if (d0[8*k +: 8] !== src_byte(s)) begin
          mism2 = mism2 + 1;
          $display("FAIL egc_post_walk direction: word 0x%04x plane %0d byte %0d = 0x%02x, expected 0x%02x",
                   15'h1100 + k, s, k, d0[8*k +: 8], src_byte(s));
        end
    end
    // The EGC is no longer a walk client: the arbiter's walk takes the plain and GRCG owners
    // only (pc9821_gvram_arb.sv:673 `cc_lane_many = (cc_owns_plain && c_many && !c_line_mode) ||`),
    // so this scenario's write cannot reach m_mode and the two witnesses are printed, not
    // asserted. Ungated, they used to pass on the plane_word read-backs' own (read) walks.
    $display("NOTE egc_post_walk: the 16-bit scenario's write spent %0d cycle(s) in a write walk, %0d with the live write flag low (the EGC does not walk)",
             walk_cycles - walk_before, race_cycles);
    if (mism2 != 0)
      fail("the 16-bit posted EGC write with a read presented behind it did not land both bytes by value");
    else
      $display("NOTE egc_post_walk: the 16-bit posted EGC write landed both bytes with a read presented behind it");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_EGC_POST_WALK: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_EGC_POST_WALK: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_EGC_POST_WALK: FAIL");
    end
  end

  initial begin
    #60_000_000;
    $fatal(1, "TB_PC9821_EGC_POST_WALK: TIMEOUT");
  end

endmodule

`default_nettype wire

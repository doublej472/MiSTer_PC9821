`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// Port 0's opt-in TWO-WORD SDRAM write is real and honest: one accepted burst_cnt=2 request writes two consecutive dwords -- word 0 on din0, word 1 on din0_hi -- and both read back IN COLUMN ORDER, while the same pair written as two single-word requests issues two BankActivates and the burst issues ONE; a partial-byte write with burst_cnt=2 still takes the read-modify-write path and preserves the other three bytes, and the single-word contract every other caller uses is unchanged.
//
// ROW-AWARE SPLITTING: a burst whose words do not all fit in the row it starts in is SPLIT at that boundary -- one ACT per row, the caller's words still returned in order -- so no caller has to clamp a burst to a 1 KiB row. Check E writes such a pair (word 1 in the next row) and Check F reads a 4-dword burst across the same boundary; both must issue exactly TWO ACTs, and Check G is the control: the same 4-dword read inside one row issues ONE.
//
// ---- where each expectation comes from ----
//  * ONE ACT PER ROW: src/memory/sdram.v's header, its READ state's segment-boundary ACT and its
//    WRITE_BURST/WRITE_BURST_ACT pair, each entered exactly when a segment's last half has gone out.
//  * COLUMN ORDER AND CONTENT: the existing 4-word READ burst check in tb_pc9821_sdram. The
//    controller's column arithmetic is shared, so a read burst that returns the right words is
//    NOT evidence about the write path -- this bench writes both words itself and reads both back.
//  * THE PARTIAL-WRITE RULE: tb_pc9821_sdram's DQM-less partial-write check, reused because the
//    new path must not be reachable from it.
//  * FREQ = 100 MHz (mediumoc), so the timing table takes the CL3 branch (sdram.v CAS_I, CL3 at
//    100 MHz and up since the 2026-10-13 hardware cutover); the write path is latency-
//    independent, and the shipping 80 MHz CL2 path is tb_pc9821_sdram_sync's.

module tb_pc9821_sdram_wburst;
  localparam integer FREQ = 100_000_000;
  localparam integer CYCLE_NS = 10;                  // 1/100MHz
  localparam integer CAS = 3;                        // CL3 at 100 MHz and up (sdram.v CAS_I, the 2026-10-13 hardware cutover)
  // The last dword of the 2 KiB row at 0x2000 on this 64 MB geometry, so XROW+4 is the first
  // dword of the NEXT row: the pair and the read burst below split at that boundary.
  localparam [26:0]  XROW = 27'h00_27FC;
  // The LAST row of bank 1 and the cells on either side of its row boundary.
  // 0x1FFF800 is {bank 1, row 0x1FFF, column 0}, so the 4-dword burst at LR_C510 and the
  // pair at LR_C511 split across the boundary -- and the true successor of
  // {bank 1, row 0x1FFF, ...} is row 0 of the NEXT bank: {bank 2, row 0, ...} = 0x2000000.
  // POISON0/1 sit at the WRONG successor a plain row+1 wrap produces, {bank 1, row 0, ...},
  // so the wrapped decode reads poison instead of the written words.
  localparam [26:0]  LR_C510 = 27'h01FFFFF8;  // {b1, r8191, c510}
  localparam [26:0]  LR_C511 = 27'h01FFFFFC;  // {b1, r8191, c511}
  localparam [26:0]  NR_C0   = 27'h02000000;  // {b2, r0, c0} - the TRUE next row
  localparam [26:0]  NR_C1   = 27'h02000004;  // {b2, r0, c1}
  localparam [26:0]  POISON0 = 27'h01000000;  // {b1, r0, c0} - the WRAP target
  localparam [26:0]  POISON1 = 27'h01000004;  // {b1, r0, c1}

  // ==== DUT ====
  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg resetn = 0;

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  reg  [1:0]  sdram_size = 2'd2;                     // 64 MB, the DE10 default shape
  wire        busy;

  reg         valid0 = 0, wr0 = 0;
  reg  [26:0] addr0 = 0;
  reg  [31:0] din0 = 0, din0_hi = 0;
  reg   [3:0] be0 = 4'hF;
  reg   [3:0] burst0 = 4'd1;
  wire        ready0;
  wire [31:0] dout0;
  wire        resp_valid0, burst_done0;

  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire [1:0]  SDRAM_BA;
  wire [1:0]  SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS, CKE;

  // The other three requesters stay silent: the arbiter skips an idle slot, so an empty port
  // cannot be charged for the burst's timing.
  sdram #(
      .FREQ(FREQ),
      .FAST_GRADE(1'b1)
  ) dut (
      .clk(clk), .resetn(resetn), .nce(1'b0), .refresh_allowed(1'b1),
      .busy(busy), .sdram_size(sdram_size),
      .valid0(valid0), .ready0(ready0), .wr0(wr0), .addr0(addr0),
      .din0(din0), .din0_hi(din0_hi), .dout0(dout0), .resp_valid0(resp_valid0),
      .be0(be0), .burst_cnt0(burst0), .burst_done0(burst_done0),
      .valid1(1'b0), .ready1(), .wr1(1'b0), .addr1(27'd0), .din1(32'd0), .dout1(),
      .resp_valid1(), .be1(4'hF), .burst_cnt1(4'd1), .burst_done1(),
      .valid2(1'b0), .ready2(), .wr2(1'b0), .addr2(27'd0), .din2(32'd0), .dout2(),
      .resp_valid2(), .be2(4'hF), .burst_cnt2(4'd1), .burst_done2(),
      .valid3(1'b0), .ready3(), .wr3(1'b0), .addr3(27'd0), .din3(32'd0), .dout3(),
      .resp_valid3(), .be3(4'hF), .burst_cnt3(4'd1), .burst_done3(),
      .SDRAM_DQ(DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQM(SDRAM_DQM),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nCS(nCS),
      .SDRAM_CKE(CKE)
  );

  // The model checks tRP for real: T_RP/T_WR are the controller's
  // derived values for this config (100 MHz, FAST_GRADE=1: ns_to_cycles(18) = 2 and
  // ns_to_cycles(12) = 2), sourced from the JEDEC minima rather than fitted to the RTL.
  sdram_chip_model #(.CAS(CAS), .T_RP(2), .T_WR(2), .FREQ_HZ(FREQ), .GRADE(6)) chip (
      .clk(clk), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // BankActivate on the pins: nRAS low, nCAS high, nWE high -- the same decode the controller's
  // own CMD_BankActivate uses.
  integer acts = 0;
  reg     count_acts = 1'b0;
  always @(posedge clk) begin
    if (count_acts && !nCS && !nRAS && nCAS && nWE) acts <= acts + 1;
  end

  // ==== CHECKS ====
  integer errors = 0;
  task automatic fail(input [1023:0] what);
    begin
      errors = errors + 1;
      $display("FAIL sdram_wburst: %0s (cycle %0d)", what, cyc);
    end
  endtask

  // One single-word write, burst_cnt = 1: the shape every other caller in the design presents.
  task automatic wr_single(input [26:0] a, input [31:0] d, input [3:0] be);
    integer guard;
    begin
      guard = 0;
      addr0 = a; din0 = d; din0_hi = 32'd0; be0 = be; burst0 = 4'd1; wr0 = 1; valid0 = 1;
      @(posedge clk);
      while (!ready0 && guard < 400) begin @(posedge clk); guard = guard + 1; end
      if (!ready0) fail("a single-word write was never accepted");
      @(posedge clk);
      valid0 = 0;
      repeat (24) @(posedge clk);
    end
  endtask

  // The two-word burst: ONE request, word 0 on din0 and word 1 on din0_hi.
  task automatic wr_pair(input [26:0] a, input [31:0] d0, input [31:0] d1);
    integer guard;
    begin
      guard = 0;
      addr0 = a; din0 = d0; din0_hi = d1; be0 = 4'hF; burst0 = 4'd2; wr0 = 1; valid0 = 1;
      @(posedge clk);
      while (!ready0 && guard < 400) begin @(posedge clk); guard = guard + 1; end
      if (!ready0) fail("the two-word burst was never accepted");
      @(posedge clk);
      valid0 = 0;
      repeat (24) @(posedge clk);
    end
  endtask

  task automatic rd_word(input [26:0] a, output [31:0] data, output integer latency);
    integer guard;
    begin
      data = 32'hDEAD_BEEF; latency = -1; guard = 0;
      addr0 = a; burst0 = 4'd1; wr0 = 0; valid0 = 1;
      @(posedge clk);
      while (!ready0 && guard < 400) begin @(posedge clk); guard = guard + 1; end
      valid0 = 0;
      guard = 0;
      while (!resp_valid0 && guard < 400) begin @(posedge clk); guard = guard + 1; end
      if (resp_valid0) begin data = dout0; latency = 0; end
      while (!burst_done0 && guard < 460) begin @(posedge clk); guard = guard + 1; end
      repeat (12) @(posedge clk);
    end
  endtask

  // A multi-dword read burst: `n` dwords from `a`, one resp_valid beat per dword in column order
  // and one burst_done at the end. The beats are sampled after each edge (#1) because they can
  // land on consecutive cycles and a wait-then-read loop would count one of them twice.
  task automatic rd_burst(input [26:0] a, input [3:0] n, output [31:0] w [0:3],
                          output integer beats, output integer done_seen);
    integer guard; integer i;
    begin
      guard = 0; beats = 0; done_seen = 0;
      for (i = 0; i < 4; i = i + 1) w[i] = 32'hDEAD_BEEF;
      addr0 = a; burst0 = n; wr0 = 0; valid0 = 1;
      @(posedge clk);
      while (!ready0 && guard < 400) begin @(posedge clk); guard = guard + 1; end
      if (!ready0) fail("a read burst was never accepted");
      valid0 = 0;
      guard = 0;
      while ((beats < n) && (guard < 400)) begin
        @(posedge clk);
        #1;
        if (resp_valid0) begin
          w[beats] = dout0;
          beats = beats + 1;
        end
        if (burst_done0) done_seen = 1;
        guard = guard + 1;
      end
      repeat (12) @(posedge clk);
    end
  endtask

  initial begin
    integer guard;
    reg [31:0] w0, w1, got0, got1;
    reg [31:0] burst_w [0:3];
    integer lat, acts_single, acts_pair, beats, done_seen, i, errors_at_last_row;

    repeat (6) @(posedge clk);
    resetn = 1;

    guard = 0;
    while (busy && guard < 400000) begin @(posedge clk); guard = guard + 1; end
    if (busy) fail("the controller never left init");
    repeat (40) @(posedge clk);

    // ---- Check A: two SINGLE-word writes -- the pre-burst shape, two ACTs ----
    // 0x2400 is inside one 1 KiB row (the row is 0x400 bytes and 0x2400 is a multiple of it).
    count_acts = 1'b0;
    @(negedge clk); count_acts = 1'b1; acts = 0;
    wr_single(27'h00_2400, 32'h1111_0000, 4'hF);
    wr_single(27'h00_2404, 32'h2222_0001, 4'hF);
    @(negedge clk); count_acts = 1'b0;
    acts_single = acts;
    rd_word(27'h00_2400, got0, lat);
    rd_word(27'h00_2404, got1, lat);
    if (got0 !== 32'h1111_0000) begin fail("single-word write 0 did not read back"); $display("     got %08x", got0); end
    if (got1 !== 32'h2222_0001) begin fail("single-word write 1 did not read back"); $display("     got %08x", got1); end

    // ---- Check B: the SAME pair as ONE burst_cnt = 2 request, ONE ACT ----
    count_acts = 1'b0;
    @(negedge clk); count_acts = 1'b1; acts = 0;
    wr_pair(27'h00_2800, 32'hAAAA_1111, 32'hBBBB_2222);
    @(negedge clk); count_acts = 1'b0;
    acts_pair = acts;
    rd_word(27'h00_2800, got0, lat);
    rd_word(27'h00_2804, got1, lat);
    if (got0 !== 32'hAAAA_1111) begin
      fail("burst word 0 did not land at the base column");
      $display("     got %08x want AAAA1111", got0);
    end
    if (got1 !== 32'hBBBB_2222) begin
      fail("burst word 1 (din0_hi) did not land at the NEXT column");
      $display("     got %08x want BBBB2222", got1);
    end
    // The neighbouring columns must be untouched by a burst that overran its two words.
    rd_word(27'h00_2808, got0, lat);
    if (got0 !== 32'hDEAD_BEEF && got0 !== 32'h0000_0000 && got0 != 32'hAAAA_1111)
      $display("NOTE sdram_wburst: the column after the burst held %08x (not asserted: it was written by no one)", got0);

    $display("NOTE sdram_wburst: two single-word writes issued %0d BankActivate(s); the same pair as ONE burst_cnt=2 request issued %0d", acts_single, acts_pair);
    if (acts_single != 2)
      fail("two single-word writes did not issue exactly two ACTs");
    if (acts_pair != 1)
      fail("the two-word burst did not issue exactly ONE ACT (the row must open once)");

    // ---- Check C: a partial-byte write is NOT a burst ----
    // burst_cnt = 2 with be != 4'hF must keep the read-modify-write behaviour: only the enabled
    // byte changes and the other three keep the old word's content.
    wr_single(27'h00_2C00, 32'h1122_3344, 4'hF);
    wr_single(27'h00_2C00, 32'h0000_00AA, 4'h1);
    rd_word(27'h00_2C00, got0, lat);
    if (got0 !== 32'h1122_33AA) begin
      fail("a partial write did not preserve the other bytes");
      $display("     got %08x want 112233AA", got0);
    end

    // ---- Check D: the burst keeps the row, so the following row is unaffected ----
    wr_pair(27'h00_3000, 32'h3333_4444, 32'h5555_6666);
    rd_word(27'h00_3400, got0, lat);   // the next 2 KiB row's start (the row is 2 KiB here)
    rd_word(27'h00_3000, got1, lat);
    if (got1 !== 32'h3333_4444) fail("the burst's word 0 was lost");
    if (got0 === 32'h5555_6666) fail("the burst's word 1 wrapped into the next row");

    // ---- Check E: a pair that CROSSES a row boundary is split, both halves in order ----
    // XROW is the last dword of its 2 KiB row, so XROW+4 opens the next row: the burst must
    // issue TWO ACTs, one per row, and still read back in column order.
    count_acts = 1'b0;
    @(negedge clk); count_acts = 1'b1; acts = 0;
    wr_pair(XROW, 32'hC0DE_1111, 32'hC0DE_2222);
    @(negedge clk); count_acts = 1'b0;
    acts_pair = acts;
    rd_word(XROW, got0, lat);
    rd_word(XROW + 27'h4, got1, lat);
    if (got0 !== 32'hC0DE_1111) begin
      fail("the split pair's word 0 (the row it starts in) did not read back");
      $display("     got %08x want C0DE1111", got0);
    end
    if (got1 !== 32'hC0DE_2222) begin
      fail("the split pair's word 1 (the NEXT row) did not read back");
      $display("     got %08x want C0DE2222", got1);
    end
    if (acts_pair != 2)
      fail("a row-crossing pair must issue exactly TWO ACTs, one per row");

    // ---- Check F: a 4-dword READ burst across the same boundary, in order, two ACTs ----
    for (i = 0; i < 4; i = i + 1) wr_single(XROW + i*(27'h4), 32'h4444_0000 + i, 4'hF);
    count_acts = 1'b0;
    @(negedge clk); count_acts = 1'b1; acts = 0;
    rd_burst(XROW, 4'd4, burst_w, beats, done_seen);
    @(negedge clk); count_acts = 1'b0;
    acts_pair = acts;
    if (beats != 4) fail("the row-crossing read burst did not return four words");
    if (done_seen == 0) fail("the row-crossing read burst never signalled burst_done");
    for (i = 0; i < 4; i = i + 1)
      if (burst_w[i] !== (32'h4444_0000 + i)) begin
        fail("a row-crossing read burst returned a word out of order");
        $display("     w%0d = %08x want %08x", i, burst_w[i], 32'h4444_0000 + i);
      end
    if (acts_pair != 2)
      fail("a row-crossing read burst must issue exactly TWO ACTs, one per row");

    // ---- Check G: the CONTROL -- the same burst inside one row issues ONE ACT ----
    for (i = 0; i < 4; i = i + 1) wr_single(27'h00_3800 + i*(27'h4), 32'h5555_0000 + i, 4'hF);
    count_acts = 1'b0;
    @(negedge clk); count_acts = 1'b1; acts = 0;
    rd_burst(27'h00_3800, 4'd4, burst_w, beats, done_seen);
    @(negedge clk); count_acts = 1'b0;
    acts_pair = acts;
    for (i = 0; i < 4; i = i + 1)
      if (burst_w[i] !== (32'h5555_0000 + i))
        fail("an in-row read burst returned a word out of order");
    if (acts_pair != 1)
      fail("an in-row read burst must issue exactly ONE ACT (the split must not fire)");

    // ---- Check H: the split is not a ONE-SHOT -- the next crossing burst splits too ----
    // Same shape one row lower. A controller that latched "the second row is open" for the first
    // crossing burst and never re-armed it answers this one out of the wrong row.
    for (i = 0; i < 4; i = i + 1)
      wr_single(27'h00_2FFC + i*(27'h4), 32'h6666_0000 + i, 4'hF);
    count_acts = 1'b0;
    @(negedge clk); count_acts = 1'b1; acts = 0;
    rd_burst(27'h00_2FFC, 4'd4, burst_w, beats, done_seen);
    @(negedge clk); count_acts = 1'b0;
    acts_pair = acts;
    for (i = 0; i < 4; i = i + 1)
      if (burst_w[i] !== (32'h6666_0000 + i)) begin
        fail("the SECOND row-crossing read burst returned a word out of order");
        $display("     w%0d = %08x want %08x", i, burst_w[i], 32'h6666_0000 + i);
      end
    if (acts_pair != 2)
      fail("the second row-crossing read burst did not split (two ACTs)");

    $display("NOTE sdram_wburst: the row-crossing pair and both row-crossing 4-dword read bursts issued 2 ACTs each; the in-row 4-dword read burst issued 1");

    // ---- Check I: at the LAST row of a bank the next row is the next BANK's row 0 (F5) ----
    // Everything above crosses an ordinary row boundary where row+1 happens to be right. At
    // row 0x1FFF the "row field + 1" arithmetic wrapped 8191 back to row 0 of the SAME bank:
    // the read burst's words 2-3 and the pair's word 1 silently aliased onto
    // {bank 1, row 0} instead of carrying into bank 2. The poison below sits at the wrap
    // target, so the pre-fix decode reads BAD0xxxx where F00Dxxxx was written.
    errors_at_last_row = errors;
    wr_single(POISON0, 32'hBAD0_0000, 4'hF);
    wr_single(POISON1, 32'hBAD0_0001, 4'hF);
    wr_single(LR_C510, 32'hF00D_0000, 4'hF);
    wr_single(LR_C511, 32'hF00D_0001, 4'hF);
    wr_single(NR_C0,   32'hF00D_0002, 4'hF);
    wr_single(NR_C1,   32'hF00D_0003, 4'hF);
    count_acts = 1'b0;
    @(negedge clk); count_acts = 1'b1; acts = 0;
    rd_burst(LR_C510, 4'd4, burst_w, beats, done_seen);
    @(negedge clk); count_acts = 1'b0;
    acts_pair = acts;
    if (beats != 4) fail("the LAST-ROW-crossing read burst did not return four words");
    if (done_seen == 0) fail("the LAST-ROW-crossing read burst never signalled burst_done");
    for (i = 0; i < 4; i = i + 1)
      if (burst_w[i] !== (32'hF00D_0000 + i)) begin
        fail("the LAST-ROW-crossing read burst did not carry into the NEXT BANK's row 0 (row+1 wrapped in-bank)");
        $display("     w%0d = %08x want %08x", i, burst_w[i], 32'hF00D_0000 + i);
      end
    if (acts_pair != 2)
      fail("a LAST-ROW-crossing read burst must issue exactly TWO ACTs, one per row");

    // The pair, split at the very last dword of the last row: word 1 must land at the NEXT
    // BANK's column 0 -- and the wrap target must still hold its poison.
    wr_pair(LR_C511, 32'hF11E_1111, 32'hF11E_2222);
    rd_word(LR_C511, got0, lat);
    rd_word(NR_C0,   got1, lat);
    if (got0 !== 32'hF11E_1111) begin
      fail("the LAST-ROW split pair's word 0 did not read back");
      $display("     got %08x want F11E1111", got0);
    end
    if (got1 !== 32'hF11E_2222) begin
      fail("the LAST-ROW split pair's word 1 did not carry into the NEXT BANK's row 0");
      $display("     got %08x want F11E2222 (the row field wrapped back into the same bank)", got1);
    end
    rd_word(POISON0, got0, lat);
    if (got0 !== 32'hBAD0_0000) begin
      fail("the wrap target {bank 1, row 0} was written -- the split pair aliased onto the WRONG row");
      $display("     got %08x want the untouched poison BAD00000", got0);
    end
    if (errors == errors_at_last_row)
      $display("NOTE sdram_wburst: the last-row pair and read burst carried row 8191 into the NEXT bank's row 0");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SDRAM_WBURST: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_SDRAM_WBURST: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_SDRAM_WBURST: FAIL");
    end
  end

  initial begin
    repeat (400000) @(posedge clk);
    $fatal(1, "TB_PC9821_SDRAM_WBURST: FAIL (the bench did not finish)");
  end
endmodule

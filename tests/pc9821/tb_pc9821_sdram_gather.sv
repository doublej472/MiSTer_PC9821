`timescale 1ns/1ps
`include "sdram_sync_bench.svh"   // the SDRAM bench clock: the controller on clk_sys

// ==== WHAT THIS PROVES ====
// TB_PC9821_SDRAM_GATHER: one accepted G3 gather-RMW request carries up to GATHER_K same-row partial PEGC stores and the REAL src/memory/sdram.v services it as ONE session - one BankActivate, one length-1 half READ per half any entry's be touches with some but not all of its bytes, one merged half WRITE per touched half with auto-precharge on the LAST write alone (one precharge for the whole session) - where the same stores as single requests cost one ACT-plus-re-ACT read-modify-write each: K byte stores in one row issue exactly 1 ACT and K READ and K WRITE commands (counted on the SDRAM pins), a mixed group writes full halves directly (a be=1111 entry and a be=1100 entry issue NO reads and take 3 WRITEs between them) and merges only the partial one, every stored byte lands byte-exact with the dword's other lanes preserved (the read-merge writes the untouched bytes back), a 1-entry session keeps the shape at K=1 (1 ACT, 1 READ, 1 WRITE - the single-RMW path's intermediate re-ACT is gone), and a read issued behind a gather sees every entry of it (accept order is visibility order). The session runs through the REAL sdram_sync_bridge (the controller on clk_sys) at the deployed settings (FAST_GRADE=0) against sdram_chip_model, whose tRP/tWR discipline checks hold the auto-precharge sequencing. FAIL-FIRST: before G3 this request shape did not exist - a stride-640 packed column store was one full controller read-modify-write transaction per byte (5.83 MB/s measured in tb_pc9821_pegc_store_rate) and there was no gath0 port to ask for a session with.

// ==== DUT ====
// sdram_sync_bridge (the controller on clk_sys, as every build runs it) over the
// real src/memory/sdram.v against sdram_chip_model on port 0, at a 50 MHz clk_sys
// (`TB_SDRAM_FREQ, sdram_sync_bench.svh). The gather request is the port-0 shape G3 adds: gath0
// qualifying a write of burst_cnt0 (1..GATHER_K) same-row entries, entry 0 on
// addr0/din0/be0 and entries 1.. on gath0_extra ({addr[26:0], din[31:0], be[3:0]}
// per entry). Ports 1-3 stay silent so no other requester is charged for the
// session's timing.

module tb_pc9821_sdram_gather;
  localparam integer CAS = 2;                        // CAS_I = 2 below 100 MHz
  localparam integer GK = 4;                         // the session size under test
  localparam integer GENT_W = 27 + 32 + 4;

  // ==== DUT ====
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;                     // 50 MHz: requesters, controller and pins
  wire clk = clk_sys;                                // the pin monitors' clock: the controller's
  reg reset = 1;
  reg resetn = 0;

  reg         valid0 = 0, wr0 = 0, gath0 = 0;
  reg  [26:0] addr0 = 0;
  reg  [31:0] din0 = 0;
  reg   [3:0] be0 = 4'hF;
  reg   [3:0] burst0 = 4'd1;
  reg [440:0] gath0_extra = 441'd0;
  wire        ready0;
  wire [31:0] dout0;
  wire        resp_valid0;

  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire  [1:0] SDRAM_BA, SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS, CKE;
  wire        busy;

  sdram_sync_bridge #(
      .FREQ(`TB_SDRAM_FREQ), .FAST_GRADE(1'b0), .GATHER_K(GK)
  ) backend (
      .clk(clk_sys), .resetn(resetn),
      .refresh_allowed(1'b1), .busy(busy), .sdram_size(2'd2),
      .valid0(valid0), .ready0(ready0), .wr0(wr0), .addr0(addr0),
      .din0(din0), .din0_hi(32'd0), .gath0(gath0), .gath0_extra(gath0_extra),
      .dout0(dout0), .resp_valid0(resp_valid0),
      .be0(be0), .burst_cnt0(burst0),
      .valid1(1'b0), .ready1(), .wr1(1'b0), .addr1(27'd0), .din1(32'd0),
      .dout1(), .resp_valid1(), .be1(4'd0), .burst_cnt1(4'd0),
      .valid2(1'b0), .ready2(), .wr2(1'b0), .addr2(27'd0), .din2(32'd0),
      .dout2(), .resp_valid2(), .be2(4'd0), .burst_cnt2(4'd0),
      .valid3(1'b0), .ready3(), .wr3(1'b0), .addr3(27'd0), .din3(32'd0),
      .dout3(), .resp_valid3(), .be3(4'd0), .burst_cnt3(4'd0),
      .SDRAM_DQ(DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQM(SDRAM_DQM), .SDRAM_BA(SDRAM_BA),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nCS(nCS),
      .SDRAM_CKE(CKE)
  );

  // The chip model checks tRP/tWR for real (the controller's derived values for this
  // config: FAST_GRADE=0 gives ns_to_cycles(20) = 2 and ns_to_cycles(15) = 2).
  sdram_chip_model #(.CAS(CAS), .T_RP(`TB_CHIP_TRP), .T_WR(`TB_CHIP_TWR),
                   .FREQ_HZ(`TB_SDRAM_FREQ), .GRADE(7)) chip (
      .clk(clk_sys), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // Bound: a stream that never completes is a FAIL, not a stall.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_SDRAM_GATHER: FAIL watchdog (the run did not finish)");
  end

  // ==== CHECKS ====
  integer errors = 0;

  // The pin-level command count, armed around one request's lifetime: ACT/READ/WRITE
  // on the pins (the same decodes sdram.v's own CMD_* constants select), plus which
  // write carried auto-precharge (A[10]) - a session precharges ONCE, on its last
  // write, and a second ACT inside one session is the shape this bench exists to
  // rule out.
  integer c_act = 0, c_rd = 0, c_wr = 0, c_wr_ap = 0;
  reg     count_on = 0;
  always @(posedge clk) begin
    if (count_on && !nCS) begin
      if (!nRAS && nCAS && nWE) c_act <= c_act + 1;
      if (nRAS && !nCAS && nWE) c_rd  <= c_rd + 1;
      if (nRAS && !nCAS && !nWE) begin
        c_wr <= c_wr + 1;
        if (SDRAM_A[10]) c_wr_ap <= c_wr_ap + 1;
      end
    end
  end

  // Clear while disarmed (the counter block drives the same integers), then arm
  // around exactly one request's lifetime.
  task automatic counts_start;
    begin
      count_on = 1'b0;
      @(negedge clk);
      c_act = 0; c_rd = 0; c_wr = 0; c_wr_ap = 0;
      count_on = 1'b1;
    end
  endtask
  task automatic counts_stop;
    begin
      @(negedge clk);
      count_on = 1'b0;
    end
  endtask

  task automatic fail(input [1023:0] what);
    begin
      errors = errors + 1;
      $display("FAIL sdram_gather: %0s", what);
    end
  endtask

  // Build one gather request's extra payload: entry j (1..) is {addr, din, be}.
  function automatic [440:0] pack_extras(
      input [26:0] a1, input [31:0] d1, input [3:0] b1,
      input [26:0] a2, input [31:0] d2, input [3:0] b2,
      input [26:0] a3, input [31:0] d3, input [3:0] b3);
    reg [440:0] x;
    begin
      x = 441'd0;
      x[0*GENT_W +: GENT_W] = {a1, d1, b1};
      x[1*GENT_W +: GENT_W] = {a2, d2, b2};
      x[2*GENT_W +: GENT_W] = {a3, d3, b3};
      pack_extras = x;
    end
  endfunction

  // One gather request: hold until the accept, then leave the request line.
  task automatic gath_req(
      input integer n,
      input [26:0] a0, input [31:0] d0, input [3:0] b0,
      input [440:0] extras);
    integer guard;
    begin
      @(negedge clk_sys);
      addr0 = a0; din0 = d0; be0 = b0; burst0 = 4'(n);
      gath0 = 1'b1; gath0_extra = extras; wr0 = 1'b1; valid0 = 1'b1;
      guard = 0;
      @(posedge clk_sys);
      while (!ready0 && guard < 2000) begin @(posedge clk_sys); guard = guard + 1; end
      if (!ready0) $fatal(1, "TB_PC9821_SDRAM_GATHER: no accept for a gather of %0d", n);
      @(negedge clk_sys);
      valid0 = 1'b0; gath0 = 1'b0; wr0 = 1'b0;
    end
  endtask

  // One ordinary single-dword write (the shape every other caller presents).
  task automatic wr_single(input [26:0] a, input [31:0] d, input [3:0] b);
    integer guard;
    begin
      @(negedge clk_sys);
      addr0 = a; din0 = d; be0 = b; burst0 = 4'd1;
      gath0 = 1'b0; wr0 = 1'b1; valid0 = 1'b1;
      guard = 0;
      @(posedge clk_sys);
      while (!ready0 && guard < 2000) begin @(posedge clk_sys); guard = guard + 1; end
      if (!ready0) $fatal(1, "TB_PC9821_SDRAM_GATHER: no accept for a write");
      @(negedge clk_sys);
      valid0 = 1'b0; wr0 = 1'b0;
    end
  endtask

  // One dword read, through the same port: the ordering leg's reader.
  task automatic rd32(input [26:0] a, output [31:0] d);
    integer guard;
    begin
      @(negedge clk_sys);
      addr0 = a; be0 = 4'hF; burst0 = 4'd1; gath0 = 1'b0; wr0 = 1'b0; valid0 = 1'b1;
      guard = 0;
      @(posedge clk_sys);
      while (!ready0 && guard < 2000) begin @(posedge clk_sys); guard = guard + 1; end
      if (!ready0) $fatal(1, "TB_PC9821_SDRAM_GATHER: no accept for a read");
      @(negedge clk_sys);
      valid0 = 1'b0;
      guard = 0;
      while (!resp_valid0 && guard < 2000) begin @(negedge clk_sys); guard = guard + 1; end
      if (!resp_valid0) $fatal(1, "TB_PC9821_SDRAM_GATHER: no response for a read");
      d = dout0;
      @(negedge clk_sys);
    end
  endtask

  task automatic expect_dword(input [26:0] a, input [31:0] want, input [1023:0] what);
    reg [31:0] got;
    begin
      rd32(a, got);
      if (got !== want) begin
        errors = errors + 1;
        $display("FAIL sdram_gather: %0s at %06x: got %08x want %08x", what, a, got, want);
      end
    end
  endtask

  // Three same-row columns and one in another row (64 MB geometry: 512 dword
  // columns per 2 KiB row, so {row 8, ...} is one row and {row 16, ...} another).
  localparam [26:0] A0 = 27'h000_1000;               // {row 8, col 0}
  localparam [26:0] A1 = 27'h000_1024;               // {row 8, col 265}
  localparam [26:0] A2 = 27'h000_1040;               // {row 8, col 272}
  localparam [26:0] A3 = 27'h000_1080;               // {row 8, col 288}
  localparam [26:0] A4 = 27'h000_10C0;               // {row 8, col 320}: the stranger

  reg [31:0] rd;

  initial begin
    @(negedge clk_sys);
    reset = 0; resetn = 1;
    repeat (30000) @(posedge clk_sys);               // past the controller's 200 us JEDEC init

    // ---- A: three same-row BYTE stores, one session ----
    // Entry j writes byte lane j+1 of its own dword; every other lane starts at 0 and
    // must stay 0 (the read-merge writes the untouched bytes back). The pins must
    // show ONE BankActivate, THREE half READs and THREE merged half WRITEs, with the
    // auto-precharge on the last write alone.
    counts_start;
    gath_req(3, A0, 32'h0000_00A1, 4'h1,
             pack_extras(A1, 32'h0000_B200, 4'h2, A2, 32'h00C3_0000, 4'h4, 27'd0, 32'd0, 4'h0));
    // Let the session run to its exit before taking the counts.
    repeat (40) @(posedge clk_sys);
    counts_stop;
    if (c_act != 1)          fail("check A: a 3-entry byte session issued more than one ACT");
    if (c_rd != 3)           fail("check A: a 3-entry byte session issued != 3 half READs");
    if (c_wr != 3)           fail("check A: a 3-entry byte session issued != 3 merged half WRITEs");
    if (c_wr_ap != 1)        fail("check A: the session's auto-precharge count != 1");
    expect_dword(A0, 32'h0000_00A1, "check A entry 0");
    expect_dword(A1, 32'h0000_B200, "check A entry 1");
    expect_dword(A2, 32'h00C3_0000, "check A entry 2");

    // ---- B: a MIXED group - full dword, byte, full half ----
    // The full dword writes its two halves directly and the full half writes its one:
    // between them THREE WRITEs and NO reads; only the byte entry reads its half.
    // The byte entry merges over check A's 0000_B200, so its other lane survives.
    counts_start;
    gath_req(3, A0, 32'hDEAD_BEEF, 4'hF,
             pack_extras(A1, 32'h0000_0044, 4'h1, A2, 32'hCAFE_0000, 4'hC, 27'd0, 32'd0, 4'h0));
    repeat (40) @(posedge clk_sys);
    counts_stop;
    if (c_act != 1)          fail("check B: a mixed session issued more than one ACT");
    if (c_rd != 1)           fail("check B: a mixed session read more than its one partial half");
    if (c_wr != 4)           fail("check B: a mixed session issued != 4 half WRITEs (2+1+1)");
    if (c_wr_ap != 1)        fail("check B: the session's auto-precharge count != 1");
    expect_dword(A0, 32'hDEAD_BEEF, "check B full entry");
    expect_dword(A1, 32'h0000_B244, "check B byte entry (check A's other lane survives)");
    expect_dword(A2, 32'hCAFE_0000, "check B half entry");

    // ---- C: the MERGE is real - pre-existing lanes survive ----
    // Preload a pattern with an ordinary write, then store one byte over it in a
    // session with a stranger dword in the same row.
    wr_single(A3, 32'h1122_3344, 4'hF);
    gath_req(2, A3, 32'h0000_00EE, 4'h1,
             pack_extras(A4, 32'h0000_0055, 4'h1, 27'd0, 32'd0, 4'h0, 27'd0, 32'd0, 4'h0));
    repeat (40) @(posedge clk_sys);
    expect_dword(A3, 32'h1122_33EE, "check C merge (the other three lanes must survive)");
    expect_dword(A4, 32'h0000_0055, "check C stranger");

    // ---- D: the 1-entry session (the column stream's leftover shape) ----
    // One ACT, one half read, one merged half write: the single-RMW path's
    // intermediate precharge/re-ACT is gone even at K=1.
    counts_start;
    gath_req(1, A2, 32'h0000_0077, 4'h1, 441'd0);
    repeat (40) @(posedge clk_sys);
    counts_stop;
    if (c_act != 1)          fail("check D: a 1-entry session issued more than one ACT");
    if (c_rd != 1)           fail("check D: a 1-entry session issued != 1 half READ");
    if (c_wr != 1)           fail("check D: a 1-entry session issued != 1 merged half WRITE");
    if (c_wr_ap != 1)        fail("check D: the session's auto-precharge count != 1");
    expect_dword(A2, 32'hCAFE_0077, "check D merge into the half entry");

    // ---- E: a read issued BEHIND a gather sees every entry of it ----
    // Accept order is visibility order (the controller serves one request at a
    // time): the read below is accepted after the gather and must see all of it.
    gath_req(2, A0, 32'h0000_0011, 4'h1,
             pack_extras(A1, 32'h0000_0022, 4'h1, 27'd0, 32'd0, 4'h0, 27'd0, 32'd0, 4'h0));
    expect_dword(A0, 32'hDEAD_BE11, "check E first entry (read behind the gather)");
    expect_dword(A1, 32'h0000_B222, "check E second entry (read behind the gather)");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SDRAM_GATHER: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_SDRAM_GATHER: FAIL (%0d errors)", errors);
  end

endmodule

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// Column-address cone (S4a) is value-identical in its shipped combinational form: on the pins every length-1 READ's (bank,row,half-column) follows the request's cells in order -- a same-row 4-dword read visits halves col0*2..col0*2+7 in that row, a read crossing a row boundary finishes the first row's tail then restarts at half 0 of the next row, and the last row of a bank carries into the next bank's row 0 -- so {rd_col_base,1'b0}+rd_issued in segment 1 and rd_issued-rd_seg_halfs after the split reproduce the old {rd_col_base + dw, rd_issued[0]} exactly.
//
// ---- where each expectation comes from ----
//  * THE COLUMN SEQUENCE IS PROTOCOL GEOMETRY, not the RTL's own formula: the
//    controller issues length-1 CAS reads, so a burst's cells are the request's
//    dwords in increasing column order, restarting at column 0 when the burst
//    crosses into the next row (and, at row 8191 of a bank, into the next bank's
//    row 0). The chip model's (bank,row,column) key makes a wrong
//    column read the wrong cell, so the readback below is the reference.
//  * THE OLD FORMULA:
//    within a row segment col16 = {rd_col_base + (rd_issued>>1), rd_issued[0]},
//    i.e. the segment's cells in order; segment 2 starts at 0 because the split
//    set rd_col_base=0. The shipped form is the arithmetic identity
//    {rd_col_base,1'b0}+rd_issued (segment 1) and rd_issued-rd_seg_halfs (segment 2,
//    since rd_seg_halfs is even).
//  * FREQ = 100 MHz (mediumoc), so the timing table takes the CL3 branch (sdram.v CAS_I,
//    CL3 at 100 MHz and up since the 2026-10-13 hardware cutover); the column arithmetic is
//    latency-independent, and the shipping 80 MHz CL2 path is tb_pc9821_sdram_sync's.
//  * A wrong segment-1 base or segment-2 offset moves the CAS column and reads a
//    different cell, so this bench -- and the readback benches beside it -- fail on
//    any such mutation.

module tb_pc9821_sdram_col16;
  localparam integer FREQ = 100_000_000;
  localparam integer CYCLE_NS = 10;                  // 1/100MHz
  localparam integer CAS = 3;                        // CL3 at 100 MHz and up (sdram.v CAS_I, the 2026-10-13 hardware cutover)

  // 64 MB geometry (the DE10 default shape): bank addr[25:24], row addr[23:11],
  // column addr[10:2]. All three bursts below sit in bank 0/1 so row+1 is right
  // except where the last-row carry is the point.
  localparam [26:0] SAME = 27'h0000_2400;  // {b0, r4, c256}: 4 dwords stay in row 4
  localparam [26:0] XROW = 27'h0000_27FC;  // {b0, r4, c511}: 4 dwords cross into row 5
  localparam [26:0] LR511 = 27'h01FF_FFFC; // {b1, r8191, c511}: crosses into {b2, r0}

  // ==== DUT ====
  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg resetn = 0;

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  reg  [1:0]  sdram_size = 2'd2;                     // 64 MB
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

  sdram_chip_model #(.CAS(CAS), .T_RP(2), .T_WR(2), .FREQ_HZ(FREQ), .GRADE(6)) chip (
      .clk(clk), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // BankActivate / READ on the pins (CMD_BankActivate = 3'b011, CMD_Read = 3'b101).
  wire is_act  = !nCS && !nRAS &&  nCAS &&  nWE;
  wire is_read = !nCS &&  nRAS && !nCAS &&  nWE;

  // The row a bank has open, latched from its ACT; and the READ-CAS capture.
  reg  [12:0] open_row [0:3];
  reg         cap_en = 0;
  integer     nseq = 0;
  reg  [12:0] seq_row  [0:15];
  reg   [1:0] seq_bank [0:15];
  reg   [9:0] seq_col  [0:15];       // 64MB: half-column = A[9:0] (A[10] is auto-precharge)

  always @(posedge clk) begin
    if (is_act) open_row[SDRAM_BA] <= SDRAM_A;
    if (is_read && cap_en) begin
      seq_row[nseq]  <= open_row[SDRAM_BA];
      seq_bank[nseq] <= SDRAM_BA;
      seq_col[nseq]  <= SDRAM_A[9:0];
      nseq           <= nseq + 1;
    end
  end

  // ==== CHECKS ====
  integer errors = 0;
  task automatic fail(input [1023:0] what);
    begin
      errors = errors + 1;
      $display("FAIL sdram_col16: %0s (cycle %0d)", what, cyc);
    end
  endtask

  task automatic wr_single(input [26:0] a, input [31:0] d);
    integer guard;
    begin
      guard = 0;
      addr0 = a; din0 = d; din0_hi = 32'd0; be0 = 4'hF; burst0 = 4'd1; wr0 = 1; valid0 = 1;
      @(posedge clk);
      while (!ready0 && guard < 400) begin @(posedge clk); guard = guard + 1; end
      if (!ready0) fail("a single-word write was never accepted");
      @(posedge clk);
      valid0 = 0;
      repeat (24) @(posedge clk);
    end
  endtask

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

  // Compare the captured sequence to the request's cells in order.
  task automatic chk_cell(input integer idx, input [1:0] eb, input [12:0] er,
                          input [9:0] ec, input [1023:0] what);
    begin
      if (seq_bank[idx] !== eb || seq_row[idx] !== er || seq_col[idx] !== ec) begin
        fail(what);
        $display("     read %0d: b%0d r%0d half %0d  want b%0d r%0d half %0d",
                 idx, seq_bank[idx], seq_row[idx], seq_col[idx], eb, er, ec);
      end
    end
  endtask

  initial begin
    integer guard, i, n, beats, done_seen;
    reg [31:0] bw [0:3];

    repeat (6) @(posedge clk);
    resetn = 1;

    guard = 0;
    while (busy && guard < 400000) begin @(posedge clk); guard = guard + 1; end
    if (busy) fail("the controller never left init");
    repeat (40) @(posedge clk);

    // ---- Check A: a 4-dword read that stays in one row ----
    // {b0,r4,c256}: cells c256..c259 -> halves 512..519, one bank/row throughout.
    for (i = 0; i < 4; i = i + 1) wr_single(SAME + 4*i, 32'hA000_0000 + i);
    nseq = 0;
    @(negedge clk); cap_en = 1;
    rd_burst(SAME, 4'd4, bw, beats, done_seen);
    @(negedge clk); cap_en = 0;
    n = nseq;
    if (n != 8) fail("a same-row 4-dword read did not issue eight length-1 CAS reads");
    for (i = 0; i < 8; i = i + 1)
      chk_cell(i, 2'd0, 13'd4, 10'd512 + i, "the same-row burst's column order is wrong");
    for (i = 0; i < 4; i = i + 1)
      if (bw[i] !== (32'hA000_0000 + i)) begin
        fail("the same-row burst read back the wrong cell (review the column sequence)");
        $display("     w%0d = %08x want %08x", i, bw[i], 32'hA000_0000 + i);
      end
    if (done_seen == 0) fail("the same-row burst never signalled burst_done");

    // ---- Check B: a 4-dword read that crosses the row boundary ----
    // {b0,r4,c511}: cells c511(row4),c0..c2(row5) -> halves 1022,1023 then 0..5.
    wr_single(XROW,      32'hB000_0000);
    wr_single(XROW + 4,  32'hB000_0001);   // {b0,r5,c0}
    wr_single(XROW + 8,  32'hB000_0002);   // {b0,r5,c1}
    wr_single(XROW + 12, 32'hB000_0003);   // {b0,r5,c2}
    nseq = 0;
    @(negedge clk); cap_en = 1;
    rd_burst(XROW, 4'd4, bw, beats, done_seen);
    @(negedge clk); cap_en = 0;
    n = nseq;
    if (n != 8) fail("a row-crossing 4-dword read did not issue eight length-1 CAS reads");
    chk_cell(0, 2'd0, 13'd4, 10'd1022, "the crossing burst's first row did not start at c511");
    chk_cell(1, 2'd0, 13'd4, 10'd1023, "the crossing burst's first row did not finish at c511");
    for (i = 0; i < 6; i = i + 1)
      chk_cell(2 + i, 2'd0, 13'd5, 10'(i), "the crossing burst did not restart at half 0 of the next row");
    for (i = 0; i < 4; i = i + 1)
      if (bw[i] !== (32'hB000_0000 + i)) begin
        fail("the crossing burst read back the wrong cell (review the segment offset)");
        $display("     w%0d = %08x want %08x", i, bw[i], 32'hB000_0000 + i);
      end
    if (done_seen == 0) fail("the crossing burst never signalled burst_done");

    // ---- Check C: the LAST row of a bank crosses into the NEXT bank's row 0 ----
    // {b1,r8191,c511}: halves 1022,1023 in b1, then b2 r0 halves 0..5.
    wr_single(LR511,      32'hC000_0000);
    wr_single(LR511 + 4,  32'hC000_0001);   // {b2,r0,c0}
    wr_single(LR511 + 8,  32'hC000_0002);   // {b2,r0,c1}
    wr_single(LR511 + 12, 32'hC000_0003);   // {b2,r0,c2}
    nseq = 0;
    @(negedge clk); cap_en = 1;
    rd_burst(LR511, 4'd4, bw, beats, done_seen);
    @(negedge clk); cap_en = 0;
    n = nseq;
    if (n != 8) fail("a last-row 4-dword read did not issue eight length-1 CAS reads");
    chk_cell(0, 2'd1, 13'd8191, 10'd1022, "the last-row burst did not start in bank 1's last row");
    chk_cell(1, 2'd1, 13'd8191, 10'd1023, "the last-row burst did not finish bank 1's last row");
    for (i = 0; i < 6; i = i + 1)
      chk_cell(2 + i, 2'd2, 13'd0, 10'(i), "the last-row burst did not carry into bank 2's row 0");
    for (i = 0; i < 4; i = i + 1)
      if (bw[i] !== (32'hC000_0000 + i)) begin
        fail("the last-row burst read back the wrong cell (review the bank carry)");
        $display("     w%0d = %08x want %08x", i, bw[i], 32'hC000_0000 + i);
      end
    if (done_seen == 0) fail("the last-row burst never signalled burst_done");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SDRAM_COL16: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_SDRAM_COL16: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_SDRAM_COL16: FAIL");
    end
  end

  initial begin
    repeat (400000) @(posedge clk);
    $fatal(1, "TB_PC9821_SDRAM_COL16: FAIL (the bench did not finish)");
  end
endmodule

`timescale 1ns/1ps
// tb_sdram_pin_equiv: src/memory/sdram.v against an earlier revision of itself, pin for pin.
// Built and run by tools/check_sdram_pin_equiv.py, which writes the earlier revision as
// sdram_ref (`git show REV:src/memory/sdram.v`, module renamed) - this is an equivalence harness
// for zero-cycle rewrites of the controller, not a conformance bench: its expected value is the
// earlier controller's own pin sequence.
//
// Two controllers run side by side from ONE stimulus, each against its own chip model(s). On
// every clk cycle after reset it asserts both drive IDENTICAL pins (A, BA, DQM, nCS, nRAS, nCAS,
// nWE, CKE and the DQ bus, Z included) and identical requester outputs (ready, resp_valid,
// burst_done, dout of all four ports, busy). The requesters follow the NEW controller's ready,
// so a divergence fails on its first cycle.
//
// Traffic (all in a small window so reads return written data): port 0 random GATHER writes
// (1..4 same-row entries, random columns and byte enables), single writes, two-word writes and
// 1..8-dword read bursts; ports 1..3 random single reads/writes. One address in eight sits in the
// last columns of its row, so read bursts and two-word writes split across rows (the second ACT,
// the row+1 carry into the next bank and, on a 128 MB module, chip). The run spans many refresh
// intervals; PE_NCE holds nce high for random stretches (the x2 wrapper's gate). Configuration
// by defines: PE_ADQM, PE_FREQ, PE_SIZE (sdram_size), PE_NCE. With ADQM=0 every byte enable is
// non-zero: that path does not pad an empty gather (only ADQM=1 does), so its row would stay open.
module tb_sdram_pin_equiv;
`ifndef PE_ADQM
`define PE_ADQM 1'b1
`endif
`ifndef PE_FREQ
`define PE_FREQ 90_000_000
`endif
`ifndef PE_SIZE
`define PE_SIZE 2'd3
`endif
`ifndef PE_NCE
`define PE_NCE 0
`endif
  localparam integer FREQ = `PE_FREQ;
  localparam integer GENT_W = 63;
  localparam integer N_CYC = 400_000;
  localparam real    HALF = 500_000_000.0 / FREQ;
  reg clk = 0; always #(HALF) clk = ~clk;
  reg resetn = 0;
  reg nce = 0;

  reg  [3:0]  valid = 0, wr = 0;
  reg  [26:0] addr [4];
  reg  [31:0] din  [4];
  reg  [31:0] dhi = 0;
  reg  [3:0]  be   [4];
  reg  [3:0]  bc   [4];
  reg         gath0 = 0;
  reg  [440:0] gx = 0;

  integer errors = 0, checks = 0, gaths = 0, writes = 0, reads = 0, splits = 0, refs = 0, cyc = 0;

`define SIDE(MOD, S) \
  wire [3:0]  rdy_``S, rv_``S, bd_``S; \
  wire [31:0] do_``S [4]; \
  wire [15:0] DQ_``S; wire [12:0] A_``S; wire [1:0] BA_``S, DM_``S; \
  wire nWE_``S, nRAS_``S, nCAS_``S, nCS_``S, CKE_``S, busy_``S; \
  MOD #(.FREQ(FREQ), .ADQM(`PE_ADQM), .FAST_GRADE(1'b0), .GATHER_K(4), .DQ_IN_DDIO(1'b0), \
        .OUT_DDIO(1'b1)) S ( \
      .SDRAM_DQ(DQ_``S), .SDRAM_A(A_``S), .SDRAM_DQM(DM_``S), .SDRAM_BA(BA_``S), \
      .SDRAM_nWE(nWE_``S), .SDRAM_nRAS(nRAS_``S), .SDRAM_nCAS(nCAS_``S), \
      .SDRAM_nCS(nCS_``S), .SDRAM_CKE(CKE_``S), .clk(clk), .resetn(resetn), .nce(nce), \
      .refresh_allowed(1'b1), .busy(busy_``S), .sdram_size(`PE_SIZE), \
      .valid0(valid[0]), .ready0(rdy_``S[0]), .wr0(wr[0]), .addr0(addr[0]), .din0(din[0]), \
      .din0_hi(dhi), .gath0(gath0), .gath0_extra(gx), .dout0(do_``S[0]), .be0(be[0]), \
      .resp_valid0(rv_``S[0]), .burst_cnt0(bc[0]), .burst_done0(bd_``S[0]), \
      .valid1(valid[1]), .ready1(rdy_``S[1]), .wr1(wr[1]), .addr1(addr[1]), .din1(din[1]), \
      .dout1(do_``S[1]), .be1(be[1]), .resp_valid1(rv_``S[1]), .burst_cnt1(bc[1]), .burst_done1(bd_``S[1]), \
      .valid2(valid[2]), .ready2(rdy_``S[2]), .wr2(wr[2]), .addr2(addr[2]), .din2(din[2]), \
      .dout2(do_``S[2]), .be2(be[2]), .resp_valid2(rv_``S[2]), .burst_cnt2(bc[2]), .burst_done2(bd_``S[2]), \
      .valid3(valid[3]), .ready3(rdy_``S[3]), .wr3(wr[3]), .addr3(addr[3]), .din3(din[3]), \
      .dout3(do_``S[3]), .be3(be[3]), .resp_valid3(rv_``S[3]), .burst_cnt3(bc[3]), .burst_done3(bd_``S[3])); \
  sdram_chip_model #(.CAS(2), .FREQ_HZ(FREQ), .GRADE(7), .CHIP_SEL(0)) chip0_``S (.clk(clk), .DQ(DQ_``S), \
      .A(A_``S), .BA(BA_``S), .nRAS(nRAS_``S), .nCAS(nCAS_``S), .nWE(nWE_``S), .nCS(nCS_``S)); \
  sdram_chip_model #(.CAS(2), .FREQ_HZ(FREQ), .GRADE(7), .CHIP_SEL(1)) chip1_``S (.clk(clk), .DQ(DQ_``S), \
      .A(A_``S), .BA(BA_``S), .nRAS(nRAS_``S), .nCAS(nCAS_``S), .nWE(nWE_``S), .nCS(nCS_``S));

  `SIDE(sdram, dn)
  `SIDE(sdram_ref, dr)

  always @(negedge clk) if (resetn) begin
    checks = checks + 1;
    if ({A_dn, BA_dn, DM_dn, nWE_dn, nRAS_dn, nCAS_dn, nCS_dn, CKE_dn} !==
        {A_dr, BA_dr, DM_dr, nWE_dr, nRAS_dr, nCAS_dr, nCS_dr, CKE_dr} || DQ_dn !== DQ_dr) begin
      errors = errors + 1;
      if (errors < 10)
        $display("PIN MISMATCH cyc %0d: A %h/%h BA %h/%h DQM %b/%b DQ %h/%h {ras,cas,we,cs} %b/%b",
                 cyc, A_dn, A_dr, BA_dn, BA_dr, DM_dn, DM_dr, DQ_dn, DQ_dr,
                 {nRAS_dn, nCAS_dn, nWE_dn, nCS_dn}, {nRAS_dr, nCAS_dr, nWE_dr, nCS_dr});
    end
    if ({rdy_dn, rv_dn, bd_dn, busy_dn} !== {rdy_dr, rv_dr, bd_dr, busy_dr} ||
        do_dn[0] !== do_dr[0] || do_dn[1] !== do_dr[1] || do_dn[2] !== do_dr[2] || do_dn[3] !== do_dr[3]) begin
      errors = errors + 1;
      if (errors < 10) $display("PORT MISMATCH cyc %0d", cyc);
    end
    if (!nRAS_dn && !nCAS_dn && nWE_dn) refs = refs + 1;
  end

  // Random stimulus: a request is held until ready, then a random gap.
  integer gap [4];
  task automatic new_req(input integer p);
    integer k, n, kind;
    reg [26:0] row; reg [8:0] col; reg [3:0] b;
    begin
      // 2 chips x 2 banks x 4 rows (large geometry: bank addr[25:24], row addr[23:11])
      row = {1'($urandom & 1), 1'b0, 1'($urandom & 1), 13'($urandom % 4), 11'd0};
      col = (($urandom % 8) == 0) ? 9'(508 + ($urandom % 4)) : 9'($urandom % 32);
      kind = $urandom % 10;
      wr[p] = 0; bc[p] = 4'd1; be[p] = 4'hF; din[p] = $urandom; addr[p] = row | {16'd0, col, 2'b00};
      if (p == 0) begin gath0 = 0; dhi = $urandom; end
      if (col >= 9'd508) splits = splits + 1;
      if (p == 0 && kind < 4) begin                       // gather write, 1..4 same-row entries
        n = 1 + ($urandom % 4);
        col = 9'($urandom % 32); addr[0] = row | {16'd0, col, 2'b00};
        gath0 = 1; wr[0] = 1; bc[0] = 4'(n);
        b = 4'($urandom); if (!`PE_ADQM && b == 4'h0) b = 4'h1; be[0] = b;
        gx = 0;
        for (k = 1; k < 4; k = k + 1) begin
          b = 4'($urandom); if (!`PE_ADQM && b == 4'h0) b = 4'h8;
          gx[(k-1)*GENT_W +: GENT_W] = {row | {16'd0, 9'($urandom % 32), 2'b00}, 32'($urandom), b};
        end
        gaths = gaths + 1;
      end else if (kind < 7) begin                        // single (port 0: or two-word) write
        wr[p] = 1; be[p] = 4'($urandom); if (!`PE_ADQM && be[p] == 4'h0) be[p] = 4'hF;
        if (p == 0 && kind >= 5) begin bc[0] = 4'd2; be[0] = 4'hF; end
        writes = writes + 1;
      end else begin                                      // read, port 0 bursts
        bc[p] = (p == 0) ? 4'(1 + ($urandom % 8)) : 4'd1;
        reads = reads + 1;
      end
      valid[p] = 1;
    end
  endtask

  integer nce_left = 0;
  initial begin
    for (int i = 0; i < 4; i++) begin addr[i] = 0; din[i] = 0; be[i] = 4'hF; bc[i] = 4'd1; gap[i] = 3 + i; end
    repeat (20) @(posedge clk);
    resetn = 1;
    // Wait out the controller's 200 us init before traffic (the init sequence is compared too).
    repeat (FREQ / 4000) @(posedge clk);
    for (cyc = 0; cyc < N_CYC; cyc++) begin
      @(posedge clk); #1;
      if (`PE_NCE) begin
        if (nce_left != 0) nce_left = nce_left - 1;
        else if (($urandom % 64) == 0) nce_left = 1 + ($urandom % 20);
        nce = (nce_left != 0);
      end
      for (int p = 0; p < 4; p++) begin
        if (valid[p] && rdy_dn[p]) begin
          valid[p] = 0;   // the payload (gath0 included) holds until the next request
          gap[p] = $urandom % 12;
        end else if (!valid[p]) begin
          if (gap[p] == 0) new_req(p); else gap[p] = gap[p] - 1;
        end
      end
    end
    $display("ADQM=%0d FREQ=%0d SIZE=%0d NCE=%0d checks=%0d errors=%0d gathers=%0d writes=%0d reads=%0d splits=%0d refreshes=%0d",
             `PE_ADQM, FREQ, `PE_SIZE, `PE_NCE, checks, errors, gaths, writes, reads, splits, refs);
    if (errors != 0 || gaths < 1000 || splits < 1000 || refs < 50) $fatal(1, "TB_SDRAM_PIN_EQUIV: FAIL");
    $display("TB_SDRAM_PIN_EQUIV: PASS");
    $finish;
  end
endmodule

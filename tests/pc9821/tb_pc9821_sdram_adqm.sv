`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SDRAM_ADQM: with ADQM=1 (the MiSTer 128MB XSDS wiring: the chips' DQML/DQMH are tied to A11/A12) a partial store is ONE masked WRITE that changes exactly the enabled bytes and leaves the disabled bytes at their stored value for EVERY byte-enable pattern - no read-modify-write - and the mask on A[12:11] does not alias a row whose own A11/A12 differ, so masked stores and the DQM-less RMW path produce byte-identical memory. EVERY CYCLE the ADQM DUT's SDRAM_DQM pins equal its SDRAM_A[12:11], the wiring they had before the DQM twin register (sdram.v dqm_a, dtm-cure), so the twin is pin-identical to it.
//
// ---- where each expectation comes from ----
// This bench does NOT derive its expected values from the RTL under test. The expected
// memory is a software model of a masked write: byte i takes the new data iff be[i], else
// it keeps the value a preceding full-dword store put there. That model is the datasheet
// behaviour of DQM (active high: 1 = mask), and it is the same result the already-tested
// RMW path must produce - so the two paths are equivalent by both matching one model.
//
//  1. MASKED WRITES CHANGE EXACTLY THE ENABLED BYTES. A full-dword store establishes all
//     four bytes; a masked store then writes a new dword; the read-back must equal the
//     software model per byte. [source: docs/sdram-dqm-wiring.md section 3; the XSDS
//     schematic tying DQML/DQMH to A11/A12]
//
//  2. THE MASK ON A[12:11] DOES NOT ALIAS A ROW. A[12:11] are row bits during ACT and the
//     byte mask during a WRITE. Four addresses whose row A11/A12 differ must each keep
//     their own dword through a masked write to one of them. [same source]
//
// The FAIL-FIRST property is recorded by the lane: with the mask placement removed (the
// WRITE command driving 00 on A[12:11]) but ADQM still selecting the masked arm, check 1
// fails on the first partial pattern - the RTL would write the whole half and smash the
// disabled bytes.

module tb_pc9821_sdram_adqm;
  localparam integer FREQ = 50_000_000;
  localparam integer CYCLE_NS = 20;
  localparam integer CAS = 2;
  localparam integer T_RP = 1;
  localparam integer T_WR = 1;

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg resetn = 0;

  reg         valid0 = 0, wr0 = 0;
  reg  [26:0] addr0 = 0;
  reg  [31:0] din0 = 0;
  reg  [3:0]  be0 = 4'hF;
  reg  [3:0]  burst_cnt0 = 4'd1;
  wire [31:0] dout0;
  wire        ready0, resp_valid0, burst_done0, busy;
  reg  [1:0]  sdram_size = 2'd3;             // 128 MB, the XSDS shape
  wire [15:0] DQ;
  wire [12:0] SA;
  wire [1:0]  SBA, SDQM;
  wire        nWE, nRAS, nCAS, nCS, CKE;

  // The reference DUT: the unchanged DQM-less RMW path (ADQM=0), driven with identical
  // stimulus so the two paths' read-backs can be compared byte for byte.
  reg         valid0_r = 0, wr0_r = 0;
  reg  [26:0] addr0_r = 0;
  reg  [31:0] din0_r = 0;
  reg  [3:0]  be0_r = 4'hF;
  reg  [3:0]  burst_cnt0_r = 4'd1;
  wire [31:0] dout0_r;
  wire        ready0_r, resp_valid0_r, burst_done0_r, busy_r;
  wire [15:0] DQ_r;
  wire [12:0] SA_r;
  wire [1:0]  SBA_r, SDQM_r;
  wire        nWE_r, nRAS_r, nCAS_r, nCS_r, CKE_r;

  // ==== DUT ====
  sdram #(
      .FREQ(FREQ),
      .ADQM(1'b1),          // the MiSTer standard: the byte mask rides A[12:11]
      .FAST_GRADE(1'b1)
  ) dut (
      .clk(clk), .resetn(resetn), .nce(1'b0), .refresh_allowed(1'b1),
      .busy(busy), .sdram_size(sdram_size),
      .valid0(valid0), .ready0(ready0), .wr0(wr0), .addr0(addr0), .din0(din0),
      .din0_hi(32'd0),
      .dout0(dout0), .resp_valid0(resp_valid0), .be0(be0), .burst_cnt0(burst_cnt0),
      .burst_done0(burst_done0),
      .valid1(1'b0), .ready1(), .wr1(1'b0), .addr1(27'd0), .din1(32'd0), .dout1(),
      .resp_valid1(), .be1(4'd0), .burst_cnt1(4'd0), .burst_done1(),
      .valid2(1'b0), .ready2(), .wr2(1'b0), .addr2(27'd0), .din2(32'd0), .dout2(),
      .resp_valid2(), .be2(4'd0), .burst_cnt2(4'd0), .burst_done2(),
      .valid3(1'b0), .ready3(), .wr3(1'b0), .addr3(27'd0), .din3(32'd0), .dout3(),
      .resp_valid3(), .be3(4'd0), .burst_cnt3(4'd0), .burst_done3(),
      .SDRAM_DQ(DQ), .SDRAM_A(SA), .SDRAM_BA(SBA), .SDRAM_DQM(SDQM),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nCS(nCS),
      .SDRAM_CKE(CKE)
  );

  // The chip model now ties the chip's DQM to A[11]/A[12] and applies the mask (see its
  // header), so a masked WRITE that arrives with the wrong pins is caught by the content.
  sdram_chip_model #(.CAS(CAS), .T_RP(T_RP), .T_WR(T_WR), .FREQ_HZ(FREQ), .GRADE(6)) chip (
      .clk(clk), .DQ(DQ), .A(SA), .BA(SBA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  sdram #(
      .FREQ(FREQ),
      .ADQM(1'b0),          // the DQM-less reference: partial stores read-modify-write
      .FAST_GRADE(1'b1)
  ) dut_r (
      .clk(clk), .resetn(resetn), .nce(1'b0), .refresh_allowed(1'b1),
      .busy(busy_r), .sdram_size(sdram_size),
      .valid0(valid0_r), .ready0(ready0_r), .wr0(wr0_r), .addr0(addr0_r), .din0(din0_r),
      .din0_hi(32'd0),
      .dout0(dout0_r), .resp_valid0(resp_valid0_r), .be0(be0_r), .burst_cnt0(burst_cnt0_r),
      .burst_done0(burst_done0_r),
      .valid1(1'b0), .ready1(), .wr1(1'b0), .addr1(27'd0), .din1(32'd0), .dout1(),
      .resp_valid1(), .be1(4'd0), .burst_cnt1(4'd0), .burst_done1(),
      .valid2(1'b0), .ready2(), .wr2(1'b0), .addr2(27'd0), .din2(32'd0), .dout2(),
      .resp_valid2(), .be2(4'd0), .burst_cnt2(4'd0), .burst_done2(),
      .valid3(1'b0), .ready3(), .wr3(1'b0), .addr3(27'd0), .din3(32'd0), .dout3(),
      .resp_valid3(), .be3(4'd0), .burst_cnt3(4'd0), .burst_done3(),
      .SDRAM_DQ(DQ_r), .SDRAM_A(SA_r), .SDRAM_BA(SBA_r), .SDRAM_DQM(SDQM_r),
      .SDRAM_nWE(nWE_r), .SDRAM_nRAS(nRAS_r), .SDRAM_nCAS(nCAS_r), .SDRAM_nCS(nCS_r),
      .SDRAM_CKE(CKE_r)
  );

  sdram_chip_model #(.CAS(CAS), .T_RP(T_RP), .T_WR(T_WR), .FREQ_HZ(FREQ), .GRADE(6)) chip_r (
      .clk(clk), .DQ(DQ_r), .A(SA_r), .BA(SBA_r),
      .nRAS(nRAS_r), .nCAS(nCAS_r), .nWE(nWE_r), .nCS(nCS_r)
  );

  // ==== CHECKS ====
  integer errors = 0;
  task automatic fail(input [1023:0] what);
    begin
      errors = errors + 1;
      $display("FAIL adqm: %0s", what);
    end
  endtask

  // ==== THE DQM PINS (dtm-cure) ====
  // Before the DQM twin, SDRAM_DQM was wired to a[12:11], i.e. to SDRAM_A[12:11]. The twin
  // (sdram.v dqm_a) must keep the pins exactly that on every cycle from power-up on, and the
  // masked WRITEs below are where A[12:11] carries something other than a row bit.
  integer dqm_cycles = 0, dqm_diffs = 0;
  always @(posedge clk) begin
    dqm_cycles = dqm_cycles + 1;
    if (SDQM !== SA[12:11]) begin
      if (dqm_diffs < 4)
        $display("FAIL adqm: SDRAM_DQM %b != SDRAM_A[12:11] %b at %0t", SDQM, SA[12:11], $time);
      dqm_diffs = dqm_diffs + 1;
    end
  end

  // One whole write on port 0, and let the controller return to idle.
  task automatic do_write(input [26:0] a, input [31:0] d, input [3:0] be);
    integer g;
    begin
      g = 0;
      addr0 = a; din0 = d; be0 = be; wr0 = 1; valid0 = 1;
      while (!ready0 && g < 400) begin @(posedge clk); g = g + 1; end
      if (!ready0) fail("a write was never accepted");
      @(posedge clk);
      valid0 = 0; wr0 = 0;
      g = 0;
      while (busy && g < 400) begin @(posedge clk); g = g + 1; end
      repeat (8) @(posedge clk);
    end
  endtask

  // One whole single-word read on port 0, watched inside the task.
  task automatic read_word(input [26:0] a, output [31:0] d);
    integer g;
    begin
      d = 32'hDEAD_BEEF;
      addr0 = a; burst_cnt0 = 4'd1; wr0 = 0; valid0 = 1; g = 0;
      while (!ready0 && g < 400) begin @(posedge clk); g = g + 1; end
      if (!ready0) fail("a read was never accepted");
      valid0 = 0; g = 0;
      while (!resp_valid0 && g < 400) begin @(posedge clk); g = g + 1; end
      if (resp_valid0) d = dout0;
      g = 0;
      while (!burst_done0 && g < 400) begin @(posedge clk); g = g + 1; end
      repeat (8) @(posedge clk);
    end
  endtask

  task automatic do_write_r(input [26:0] a, input [31:0] d, input [3:0] be);
    integer g;
    begin
      g = 0;
      addr0_r = a; din0_r = d; be0_r = be; wr0_r = 1; valid0_r = 1;
      while (!ready0_r && g < 400) begin @(posedge clk); g = g + 1; end
      if (!ready0_r) fail("a reference write was never accepted");
      @(posedge clk);
      valid0_r = 0; wr0_r = 0;
      g = 0;
      while (busy_r && g < 400) begin @(posedge clk); g = g + 1; end
      repeat (8) @(posedge clk);
    end
  endtask

  task automatic read_word_r(input [26:0] a, output [31:0] d);
    integer g;
    begin
      d = 32'hDEAD_BEEF;
      addr0_r = a; burst_cnt0_r = 4'd1; wr0_r = 0; valid0_r = 1; g = 0;
      while (!ready0_r && g < 400) begin @(posedge clk); g = g + 1; end
      if (!ready0_r) fail("a reference read was never accepted");
      valid0_r = 0; g = 0;
      while (!resp_valid0_r && g < 400) begin @(posedge clk); g = g + 1; end
      if (resp_valid0_r) d = dout0_r;
      g = 0;
      while (!burst_done0_r && g < 400) begin @(posedge clk); g = g + 1; end
      repeat (8) @(posedge clk);
    end
  endtask

  // The software model of a masked store: byte i takes `nw` iff be[i], else keeps `orig`.
  function automatic [31:0] mask_model(input [31:0] orig, input [31:0] nw, input [3:0] be);
    integer b;
    begin
      mask_model = orig;
      for (b = 0; b < 4; b = b + 1)
        if (be[b]) mask_model[b*8 +: 8] = nw[b*8 +: 8];
    end
  endfunction

  integer k, b;
  reg [3:0]  bes [1:15];
  reg [26:0] base;
  reg [31:0] orig, nw, got, got_r, exp;
  reg [31:0] w_a, w_b, w_c, w_d, g_b, g_c, g_d;

  initial begin
    // 15 non-empty byte-enable patterns.
    for (k = 1; k <= 15; k = k + 1) bes[k] = k[3:0];

    repeat (6) @(posedge clk);
    resetn = 1;
    begin : init_wait
      integer g = 0;
      while (busy && g < 200000) begin @(posedge clk); g = g + 1; end
      if (busy) fail("the controller never left init");
    end
    repeat (20) @(posedge clk);

    // ---- Check 1: every pattern changes exactly its enabled bytes ----
    base = 27'h0001_0000;
    for (k = 1; k <= 15; k = k + 1) begin : pat
      orig = 32'hAABB_CCDD;
      nw   = 32'h1122_3344;
      do_write(base + k, orig, 4'hF);        // establish all four bytes
      do_write(base + k, nw, bes[k]);        // masked store
      read_word(base + k, got);
      do_write_r(base + k, orig, 4'hF);      // the RMW reference, identical stimulus
      do_write_r(base + k, nw, bes[k]);
      read_word_r(base + k, got_r);
      exp = mask_model(orig, nw, bes[k]);
      if (got !== exp) begin
        $display("     be=%b: read %h want %h", bes[k], got, exp);
        fail("a masked store did not change exactly its enabled bytes");
      end
      if (got_r !== exp) begin
        $display("     be=%b: RMW read %h want %h", bes[k], got_r, exp);
        fail("the RMW reference did not match the masked-write model");
      end
      if (got !== got_r) begin
        $display("     be=%b: ADQM %h != RMW %h", bes[k], got, got_r);
        fail("masked stores and the RMW path produced DIFFERENT memory");
      end
    end
    $display("NOTE adqm: 15 byte-enable patterns masked correctly through one WRITE each");

    // ---- Check 2: the A[12:11] mask does not alias a row ----
    // Four addresses whose row bits A[12:11] (addr_buf[23:22]) differ.
    w_a = 32'h1111_0001; w_b = 32'h2222_0002;
    w_c = 32'h3333_0003; w_d = 32'h4444_0004;
    base = 27'h0002_0000;
    do_write(base,                      w_a, 4'hF);   // A11/A12 = 00
    do_write(base | (27'd1 << 22),      w_b, 4'hF);   // A11
    do_write(base | (27'd1 << 23),      w_c, 4'hF);   // A12
    do_write(base | (27'd3 << 22),      w_d, 4'hF);   // A11 and A12
    // A masked store to the first row must not disturb the other three.
    do_write(base, 32'hAAAA_5555, 4'h1);
    read_word(base, got);
    exp = mask_model(w_a, 32'hAAAA_5555, 4'h1);
    if (got !== exp) begin
      $display("     masked row 0 read %h want %h", got, exp);
      fail("a masked store to row A11/A12=00 was wrong");
    end
    read_word(base | (27'd1 << 22), g_b);
    read_word(base | (27'd1 << 23), g_c);
    read_word(base | (27'd3 << 22), g_d);
    if (g_b !== w_b || g_c !== w_c || g_d !== w_d) begin
      $display("     A11=%h(want %h) A12=%h(want %h) A11+A12=%h(want %h)", g_b, w_b, g_c, w_c, g_d, w_d);
      fail("the byte mask on A[12:11] aliased or corrupted a row whose own A11/A12 differ");
    end
    $display("NOTE adqm: masked stores leave rows with differing A11/A12 intact");

    if (dqm_diffs != 0) fail("SDRAM_DQM differed from SDRAM_A[12:11] (the DQM twin is not pin-identical)");
    else $display("NOTE adqm: SDRAM_DQM == SDRAM_A[12:11] on all %0d cycles", dqm_cycles);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SDRAM_ADQM: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_SDRAM_ADQM: FAIL with %0d error(s)", errors);
    end
  end
endmodule

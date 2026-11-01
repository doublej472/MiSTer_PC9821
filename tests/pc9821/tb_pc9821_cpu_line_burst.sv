`timescale 1ns/1ps
`include "sdram_sync_bench.svh"   // the SDRAM bench clock: the controller on clk_sys

// ==== WHAT THIS PROVES ====
// What the CPU's cache-line fill ACTUALLY issues: the real z486 L1 data cache (src/z486/l1_cache.sv), through the real SDRAM bridge (the controller on clk_sys) and the real src/memory/sdram.v controller against the chip model, fills its 16-byte line as ONE 4-dword BURST -- a single request carrying burst_cnt=4, accepted as ONE SDRAM transaction (one BankActivate, one auto-precharged row), returning all four dwords correctly -- where the same 16 bytes read as four single-word requests is FOUR accepted transactions. The fill is therefore already the authentic 486 burst and already the minimum number of SDRAM slots, so the earlier 'already batched, nothing left' is pinned here rather than asserted, and the premise -- that the fill might be several shorter requests -- is refuted by measurement.
//
// ---- where each expectation comes from ----
//  * ONE REQUEST, burst_cnt = 4: src/z486/l1_cache.sv's S_FILL arm sets mem_addr line-aligned
//    and mem_burstcount = 4 for a demand miss; the L1 line is 16 bytes = 4 dwords.
//  * ONE TRANSACTION: src/memory/sdram.v's READ state issues 2*burst_cnt halfword CAS reads in
//    ONE burst off ONE BankActivate, auto-precharging the last. The bridge hands the request to
//    the controller on the same clock and returns one resp_valid beat per dword.
//  * THE PLATFORM PRESERVES IT: pc9821_memory_map.sv passes cpu_burstcount straight to
//    mem_burstcount (and cpu_line_read to mem_line_read), and split_sdram_backend forwards it to
//    the controller, so the L1's 4 is the number the controller sees.
//  * FREQ = clk_sys (`TB_SDRAM_FREQ, sdram_sync_bench.svh): the controller runs on clk_sys in
//    every build, and the timing table takes the CAS_I = 2 branch the design uses (below 100 MHz).

`default_nettype none

module tb_pc9821_cpu_line_burst;
  localparam integer SYS_NS   = 20;      // 50 MHz clk_sys
  localparam integer CAS      = 2;       // CAS_I = 2 below 100 MHz
  // One single transaction retires well inside this; a fixed settle is used instead of a
  // busy-based wait that could sample before busy rises.
  localparam integer SETTLE   = 40;

  // ==== DUT ====
  reg clk_sys = 0;
  always #(SYS_NS/2) clk_sys = ~clk_sys;

  reg reset  = 1;      // active high: the L1 cache
  reg resetn = 0;      // active low: the backend

  integer cyc = 0;
  always @(posedge clk_sys) cyc <= cyc + 1;

  // The fill's memory-side port is muxed so the bench can preload the line and later issue the
  // reference serialized reads itself, through the SAME backend the fill uses.
  reg        tb_drive = 1'b0;
  reg        tb_valid = 1'b0, tb_write = 1'b0;
  reg [26:0] tb_addr = 27'd0;
  reg [31:0] tb_din = 32'd0;
  reg  [3:0] tb_be = 4'hF;
  reg  [3:0] tb_burst = 4'd1;

  // CPU side of the real L1 data cache.
  reg  [31:0] cpu_addr = 32'd0, cpu_din = 32'd0;
  reg   [3:0] cpu_be = 4'hF;
  reg         cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid, stores_drained;

  wire [31:0] cache_addr, cache_din;
  wire  [3:0] cache_be;
  wire  [7:0] cache_burst;
  wire        cache_valid, cache_write;

  wire [31:0] p0_addr, p0_din;
  wire  [3:0] p0_be;
  wire  [7:0] p0_burst;
  wire        p0_valid, p0_write;
  wire        p0_ready;
  wire [31:0] p0_dout;
  wire        p0_resp_valid;
  wire        busy;

  assign p0_valid = tb_drive ? tb_valid : cache_valid;
  assign p0_write = tb_drive ? tb_write : cache_write;
  assign p0_addr  = tb_drive ? {5'd0, tb_addr} : cache_addr;
  assign p0_din   = tb_drive ? tb_din : cache_din;
  assign p0_be    = tb_drive ? tb_be : cache_be;
  assign p0_burst = tb_drive ? {4'd0, tb_burst} : cache_burst;

  l1_cache #(.SET_BITS(3)) cache (
      .clk(clk_sys), .reset(reset),
      .cpu_addr(cpu_addr), .cpu_preread_offset(cpu_addr[11:0]),
      .cpu_preread_priority(cpu_valid), .cpu_din(cpu_din), .cpu_dout(cpu_dout),
      .cpu_be(cpu_be), .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_uncacheable(1'b0), .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .stores_drained(stores_drained),
      .vipt_probe_offset(12'd0), .vipt_probe_valid(1'b0), .vipt_probe_ready(),
      .vipt_probe_accepted(), .vipt_probe_direct_accepted(),
      .vipt_resolve_phys_addr(32'd0), .vipt_resolve_tlb_phys(32'd0), .vipt_resolve_alt_phys(32'd0), .vipt_resolve_use_tlb(1'b0), .vipt_resolve_valid(1'b0),
      .vipt_resolve_data(), .vipt_resolve_hit(),
      .mem_addr(cache_addr), .mem_din(cache_din), .mem_dout(p0_dout),
      .mem_line_dout(128'd0), .mem_be(cache_be), .mem_burstcount(cache_burst),
      .mem_busy(busy), .mem_valid(cache_valid), .mem_write(cache_write),
      .mem_ready(p0_ready), .mem_resp_valid(p0_resp_valid),
      .mem_line_resp_valid(1'b0),
      .snoop_addr(32'd0), .snoop_valid(1'b0), .cache_enable(1'b1)
  );

  // The backend is the REAL controller behind the REAL bridge, on clk_sys: one port-0 request is
  // accepted once and the controller serves it as one burst.
  reg  [1:0] sdram_size = 2'd2;    // 64 MB, the DE10 default shape
  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire [1:0]  SDRAM_BA, SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS, CKE;

  sdram_sync_bridge #(.FREQ(`TB_SDRAM_FREQ), .FAST_GRADE(1'b0)) backend (
      .clk(clk_sys), .resetn(resetn),
      .refresh_allowed(1'b1), .busy(busy), .sdram_size(sdram_size),
      .valid0(p0_valid), .ready0(p0_ready), .wr0(p0_write), .addr0(p0_addr[26:0]),
      .din0(p0_din), .din0_hi(32'd0), .dout0(p0_dout), .resp_valid0(p0_resp_valid),
      .be0(p0_be), .burst_cnt0(p0_burst[3:0]),
      .valid1(1'b0), .ready1(), .wr1(1'b0), .addr1(27'd0), .din1(32'd0),
      .dout1(), .resp_valid1(), .be1(4'hF), .burst_cnt1(4'd1),
      .valid2(1'b0), .ready2(), .wr2(1'b0), .addr2(27'd0), .din2(32'd0),
      .dout2(), .resp_valid2(), .be2(4'hF), .burst_cnt2(4'd1),
      .SDRAM_DQ(DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQM(SDRAM_DQM),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nCS(nCS),
      .SDRAM_CKE(CKE)
  );

  sdram_chip_model #(.CAS(CAS), .T_RP(`TB_CHIP_TRP), .T_WR(`TB_CHIP_TWR)) chip (
      .clk(clk_sys), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // Port-0 ACCEPTS and response BEATS, counted on clk_sys. `ready` is a one-cycle registered
  // pulse (the bridge's ack), so counting it is race-free where `valid & ready` is not: the
  // requester deasserts valid on the ready edge and the two processes can be ordered either way.
  // `clr` zeroes both at a phase boundary so each phase's count is exact.
  integer accepts = 0, beats = 0;
  reg [7:0] last_burst = 8'd0;
  reg       clr = 1'b0;
  always @(posedge clk_sys) begin
    if (clr) begin
      accepts <= 0;
      beats   <= 0;
    end else begin
      if (p0_ready) begin
        accepts <= accepts + 1;
        last_burst <= p0_burst;
      end
      if (p0_resp_valid) beats <= beats + 1;
    end
  end

  // ==== CHECKS ====
  integer errors = 0;
  task automatic fail(input [1023:0] what);
    begin
      errors = errors + 1;
      $display("FAIL cpu_line_burst: %0s (cycle %0d)", what, cyc);
    end
  endtask

  // Zero the phase counters between clocks so the clear samples cleanly on the next posedge.
  task automatic zero_counts;
    begin
      @(negedge clk_sys);
      clr = 1'b1;
      @(negedge clk_sys);
      clr = 1'b0;
      @(negedge clk_sys);
    end
  endtask

  // Wait out the controller's power-on JEDEC sequence.
  task automatic wait_init;
    integer g;
    begin
      g = 0;
      while (busy && g < 40000) begin @(posedge clk_sys); g = g + 1; end
    end
  endtask

  // One single-word write through the bridge: the shape a serialized access presents.
  task automatic tb_write_word(input [26:0] a, input [31:0] d);
    begin
      @(negedge clk_sys);
      tb_drive = 1'b1; tb_valid = 1'b1; tb_write = 1'b1;
      tb_addr = a; tb_din = d; tb_be = 4'hF; tb_burst = 4'd1;
      @(posedge clk_sys);
      while (!p0_ready) @(posedge clk_sys);
      @(negedge clk_sys);
      tb_valid = 1'b0; tb_write = 1'b0;
      repeat (SETTLE) @(posedge clk_sys);
    end
  endtask

  task automatic tb_read_word(input [26:0] a, output [31:0] d);
    begin
      @(negedge clk_sys);
      tb_drive = 1'b1; tb_valid = 1'b1; tb_write = 1'b0;
      tb_addr = a; tb_be = 4'hF; tb_burst = 4'd1;
      @(posedge clk_sys);
      while (!p0_ready) @(posedge clk_sys);
      @(negedge clk_sys);
      tb_valid = 1'b0;
      while (!p0_resp_valid) @(posedge clk_sys);
      d = p0_dout;
      repeat (SETTLE) @(posedge clk_sys);
    end
  endtask

  task automatic cache_read(input [31:0] addr, input [31:0] expected);
    begin
      do @(negedge clk_sys); while (!cpu_ready);
      cpu_addr = addr; cpu_be = 4'hF; cpu_din = 32'd0;
      cpu_write = 1'b0; cpu_valid = 1'b1;
      @(negedge clk_sys);
      cpu_valid = 1'b0;
      if (!cpu_resp_valid) do @(negedge clk_sys); while (!cpu_resp_valid);
      if (cpu_dout !== expected) begin
        fail("a CPU line-fill read returned the wrong dword");
        $display("     addr=%08x got %08x want %08x", addr, cpu_dout, expected);
      end
    end
  endtask

  initial begin
    integer ref_accepts, fill_accepts, fill2_accepts;
    integer b1;
    reg [31:0] got;

    repeat (4) @(posedge clk_sys);
    reset  = 1'b0;
    resetn = 1'b1;
    repeat (60) @(posedge clk_sys);      // let the L1 finish its reset-init sweep
    repeat (30000) @(posedge clk_sys);   // 600 us: past the controller's 200 us JEDEC init
    wait_init;

    // ---- Preload one 16-byte line (line 0x40) through the bridge ----
    tb_write_word(27'h000_0040, 32'h4433_2211);
    tb_write_word(27'h000_0044, 32'h8877_6655);
    tb_write_word(27'h000_0048, 32'hCCBB_AA99);
    tb_write_word(27'h000_004C, 32'h00FF_EEDD);

    // ---- Reference: the SAME 16 bytes as FOUR single-word reads ----
    zero_counts;
    tb_read_word(27'h000_0040, got);
    if (got !== 32'h4433_2211) fail("reference read of 0x40 was wrong");
    tb_read_word(27'h000_0044, got);
    if (got !== 32'h8877_6655) fail("reference read of 0x44 was wrong");
    tb_read_word(27'h000_0048, got);
    if (got !== 32'hCCBB_AA99) fail("reference read of 0x48 was wrong");
    tb_read_word(27'h000_004C, got);
    if (got !== 32'h00FF_EEDD) fail("reference read of 0x4C was wrong");
    repeat (8) @(posedge clk_sys);
    ref_accepts = accepts;

    // ---- The L1 demand miss: ONE 4-dword burst ----
    tb_drive = 1'b0;
    repeat (SETTLE) @(posedge clk_sys);
    zero_counts;
    cache_read(32'h0000_0040, 32'h4433_2211);   // miss + line fill
    // The other three dwords of the SAME line must now hit, issuing no transaction.
    cache_read(32'h0000_0044, 32'h8877_6655);
    cache_read(32'h0000_0048, 32'hCCBB_AA99);
    cache_read(32'h0000_004C, 32'h00FF_EEDD);
    repeat (8) @(posedge clk_sys);
    fill_accepts = accepts;
    b1 = beats;

    // ---- A SECOND, different line: a fresh fill is again exactly one burst ----
    tb_drive = 1'b1;
    repeat (SETTLE) @(posedge clk_sys);
    tb_write_word(27'h000_0080, 32'h1122_3344);
    tb_write_word(27'h000_0084, 32'h5566_7788);
    tb_write_word(27'h000_0088, 32'h99AA_BBCC);
    tb_write_word(27'h000_008C, 32'hDDEE_FF00);
    tb_drive = 1'b0;
    repeat (SETTLE) @(posedge clk_sys);
    zero_counts;
    cache_read(32'h0000_008C, 32'hDDEE_FF00);   // miss at the LAST dword of the line
    repeat (8) @(posedge clk_sys);
    fill2_accepts = accepts;

    // ==== VERDICT ====
    $display("NOTE cpu_line_burst: reference 4 single-word reads = %0d port-0 accepts; the SAME 16 bytes as ONE L1 line fill = %0d accept (burst_cnt=%0d), %0d response beats",
             ref_accepts, fill_accepts, last_burst, b1);
    $display("NOTE cpu_line_burst: the second line's fill (miss at the LAST dword) = %0d accept", fill2_accepts);

    if (ref_accepts != 4)
      fail("four single-word reads did not issue exactly four accepts (the reference is wrong)");
    if (fill_accepts != 1)
      fail("the L1 line fill did not issue exactly ONE SDRAM transaction");
    if (last_burst != 8'd4)
      fail("the L1 line fill's request did not carry burst_cnt = 4");
    if (b1 != 4)
      fail("the L1 line fill did not return exactly four response beats");
    if (fill2_accepts != 1)
      fail("a second line's fill was not exactly one transaction");

    if (errors == 0) begin
      $display("TB_PC9821_CPU_LINE_BURST: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_CPU_LINE_BURST: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_CPU_LINE_BURST: FAIL");
    end
  end

  // Watchdog: the bench must finish. 400k clk_sys = 8 ms, well past the 200 us init.
  initial begin
    repeat (400000) @(posedge clk_sys);
    $fatal(1, "TB_PC9821_CPU_LINE_BURST: FAIL (the bench did not finish)");
  end
endmodule

`timescale 1ns/1ps
`include "sdram_sync_bench.svh"   // the SDRAM bench clock: the controller on clk_sys

// ==== WHAT THIS PROVES ====
// TB_PC9821_PEGC_SCAN_WRAP: a packed (256-colour) scanout line that starts within 640 bytes of the end of the 512 KiB PEGC store wraps to offset 0 of the store, as NP2kai's packed walk does (vram/makegrex.c grphput_all: the 8-byte column counter wraps at 16 bits, `vc = LOW16(vc + 1);`, over `vramex + (vc * 8)`), so the line's byte n is store byte (line base + n) mod 0x80000 - at line starts 32, 8, 16, 400 (a burst that ends exactly at the end), 328 (the cut in the middle of the line) and 624 (the cut in the last burst) bytes before the end, through the REAL pc9821_pegc_scan, sdram_sync_bridge and src/memory/sdram.v on port 3 - and no port-3 request ever runs past the end of the store: the burst that would cross it is cut at the end and its remainder fetched from offset 0, and the line that ends exactly at the end is fetched with no cut. FAIL-FIRST: before the wrap the fetch read the SDRAM past peg_base + 0x80000 (the bench fills it with the complement of the wrapped bytes), so every wrapped byte mismatched and the straddling bursts ran past the end.
//
// THE REFERENCE. NP2kai builds a packed line in grphput_all/grphput_indirty
// (vram/makegrex.c): `vc = vad;` then per 8-byte column `p[0] = *(UINT32 *)(vramex + (vc * 8) + 0);`,
// `p[1] = *(UINT32 *)(vramex + (vc * 8) + 4);`, `vc = LOW16(vc + 1);`, eighty columns
// (TEXTXMAX * 2 dwords) per line. vramex is the 512 KiB store and vc counts its 8-byte units in 16
// bits, so the walk wraps from the store's last unit to unit 0. The expected byte here is that
// walk's byte: store[(L + n) mod 0x80000] for the line start L (pc9821_pegc_scan's line_base_q,
// {page, GDC line base[14:0], 3'b000}) and dot n. There is no real-hardware capture of a wrapping
// line; NP2kai is the strongest reference that covers it (MAME's packed walk keeps the same
// 16-bit wrap through `& 0xffff`, pc9821.cpp:104-113).
//
// THE STORE. The last and first 1 KiB of the store are preloaded with a byte pattern of the
// store offset, and the 1 KiB PAST the end (peg_base + 0x80000, the SDRAM an unwrapped fetch
// reads) with that pattern's complement at the wrapped offset, so a byte read past the end can
// never pass for the wrapped one.

// ==== DUT ====
module tb_pc9821_pegc_scan_wrap;

  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;      // 50 MHz: the requesters AND the SDRAM controller
  reg reset = 1;
  reg resetn = 0;

  // ---- the scan side ----
  reg        scan_enable = 0, scan_line_tick = 0;
  reg        scan_page = 0, page_force_zero = 0, scan_walk_page = 0;
  reg [14:0] scan_line_base = 0;
  reg  [6:0] line_rd_addr = 0;
  reg        line_rd_sel = 0;
  reg  [2:0] dot_in_col = 0;
  wire [7:0] packed_idx;
  wire       line_sel, line_ready;
  localparam [31:0] PEG_BASE = 32'h0200_0000;

  // ---- the memory side: port 3 for the fetch, port 0 for the preload ----
  wire [31:0] p3_addr, p3_din;
  wire  [3:0] p3_be;
  wire  [7:0] p3_burst;
  wire        p3_valid, p3_write;
  wire        p3_ready, p3_resp_valid;
  wire [31:0] p3_dout;

  reg  [31:0] p0_addr = 0, p0_din = 0;
  reg   [3:0] p0_be = 4'hF;
  reg   [7:0] p0_burst = 8'd1;
  reg         p0_valid = 0, p0_write = 1;
  wire        p0_ready;
  wire [31:0] p0_dout;
  wire        p0_resp_valid;

  pc9821_pegc_scan dut (
      .clk(clk_sys), .reset(reset),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .page_force_zero(page_force_zero),
      .scan_walk_page(scan_walk_page),
      .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .dot_in_col(dot_in_col), .dot_ce(1'b0), .line_rd_act(1'b1),   // walked by hand here
      .packed_idx(packed_idx), .line_sel(line_sel), .line_ready(line_ready),
      .peg_base(PEG_BASE),
      .mem_addr(p3_addr), .mem_valid(p3_valid), .mem_write(p3_write),
      .mem_be(p3_be), .mem_burstcount(p3_burst), .mem_din(p3_din),
      .mem_ready(p3_ready), .mem_dout(p3_dout), .mem_resp_valid(p3_resp_valid)
  );

  wire busy;
  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire  [1:0] SDRAM_BA, SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS, CKE;
  sdram_sync_bridge #(.FREQ(`TB_SDRAM_FREQ), .FAST_GRADE(1'b0)) backend (
      .clk(clk_sys), .resetn(resetn),
      .refresh_allowed(1'b1), .busy(busy), .sdram_size(2'd2),
      .valid0(p0_valid), .ready0(p0_ready), .wr0(p0_write), .addr0(p0_addr[26:0]),
      .din0(p0_din), .din0_hi(32'd0), .dout0(p0_dout), .resp_valid0(p0_resp_valid),
      .be0(p0_be), .burst_cnt0(p0_burst[3:0]),
      .valid1(1'b0), .ready1(), .wr1(1'b0), .addr1(27'd0), .din1(32'd0),
      .dout1(), .resp_valid1(), .be1(4'd0), .burst_cnt1(4'd0),
      .valid2(1'b0), .ready2(), .wr2(1'b0), .addr2(27'd0), .din2(32'd0),
      .dout2(), .resp_valid2(), .be2(4'd0), .burst_cnt2(4'd0),
      .valid3(p3_valid), .ready3(p3_ready), .wr3(p3_write), .addr3(p3_addr[26:0]),
      .din3(p3_din), .dout3(p3_dout), .resp_valid3(p3_resp_valid),
      .be3(p3_be), .burst_cnt3(p3_burst[3:0]),
      .SDRAM_DQ(DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQM(SDRAM_DQM), .SDRAM_BA(SDRAM_BA),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nCS(nCS),
      .SDRAM_CKE(CKE)
  );

  sdram_chip_model #(.T_RP(`TB_CHIP_TRP), .T_WR(`TB_CHIP_TWR)) chip (
      .clk(clk_sys), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nWE(nWE), .nRAS(nRAS), .nCAS(nCAS), .nCS(nCS)
  );

  integer errors = 0;
  integer k;
  // The request monitor's own counters (an always block below increments them, so they take
  // their zero in the CHECKS block, not from a declaration initialiser).
  integer cut_reqs;
  integer bound_errs;

  // Bound: a fetch that never completes is a FAIL, not a stall.
  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_PEGC_SCAN_WRAP: FAIL watchdog (the run did not finish)");
  end

  // ==== STIMULUS ====
  task automatic port0_store(input [31:0] a, input [31:0] d);
    integer g;
    begin
      @(negedge clk_sys);
      p0_addr = a; p0_din = d; p0_be = 4'hF; p0_write = 1; p0_valid = 1;
      g = 0; while (!p0_ready && g < 2000) begin @(negedge clk_sys); g = g + 1; end
      if (!p0_ready) $fatal(1, "TB_PC9821_PEGC_SCAN_WRAP: no accept for preload %08x", a);
      @(negedge clk_sys); p0_valid = 0;
      repeat (2) @(negedge clk_sys);
    end
  endtask


  // The store's byte at offset o (19 bits), and the bytes past its end.
  function automatic [7:0] store_byte(input [18:0] o);
    begin
      store_byte = 8'h5A ^ o[7:0] ^ o[15:8] ^ {o[18:16], 5'b0};
    end
  endfunction
  function automatic [31:0] store_dword(input [18:0] o);
    begin
      store_dword = {store_byte(o + 19'd3), store_byte(o + 19'd2),
                     store_byte(o + 19'd1), store_byte(o)};
    end
  endfunction

  // Every port-3 request the controller takes stays inside the store.
  always @(posedge clk_sys) begin
    if (!reset && p3_valid && p3_ready) begin
      if (p3_addr < PEG_BASE ||
          (p3_addr - PEG_BASE) + 32'(p3_burst) * 32'd4 > 32'h0008_0000) begin
        $display("FAIL port-3 request %08x x%0d runs past the 512 KiB store (end %08x)",
                 p3_addr, p3_burst, PEG_BASE + 32'h0008_0000);
        bound_errs = bound_errs + 1;
      end
      // A burst shorter than the full 10 dwords is a wrap cut: it ends exactly at the end of
      // the store, or it is the remainder and starts at offset 0. Nothing else is shortened.
      if (p3_burst != 8'd10) begin
        cut_reqs = cut_reqs + 1;
        if (!((p3_addr - PEG_BASE) + 32'(p3_burst) * 32'd4 == 32'h0008_0000 ||
              p3_addr == PEG_BASE)) begin
          $display("FAIL port-3 request %08x x%0d is short but neither ends at the end nor starts at 0",
                   p3_addr, p3_burst);
          bound_errs = bound_errs + 1;
        end
      end
    end
  end

  // One fetched line at {page, base} << 3 (the scanout bench's fetch_line).
  task automatic fetch_line(input page, input [14:0] base);
    integer g;
    begin
      // Align to a negedge first so the dropped enable spans a whole posedge (the walk
      // returns just after one): that clears line_ready, and the wait below then waits for
      // THIS fetch rather than returning on the previous line's flag.
      @(negedge clk_sys);
      scan_enable = 1'b0;
      @(negedge clk_sys);
      scan_page = page; scan_line_base = base; page_force_zero = 1'b0; scan_walk_page = 1'b0;
      scan_enable = 1'b1;
      @(negedge clk_sys);
      scan_line_tick = 1'b1;
      @(negedge clk_sys);
      scan_line_tick = 1'b0;
      g = 0;
      while (!line_ready && g < 4000) begin @(negedge clk_sys); g = g + 1; end
      if (!line_ready) $fatal(1, "TB_PC9821_PEGC_SCAN_WRAP: a line never became ready");
    end
  endtask

  // The line the mixer shows, byte for byte: NP2kai's walk from L, modulo the store.
  task automatic walk_wrap(input [18:0] L, input [8*24-1:0] what);
    integer n;
    integer bad;
    reg [18:0] o;
    begin
      bad = 0;
      line_rd_sel = line_sel;
      for (n = 0; n < 640; n = n + 1) begin
        @(negedge clk_sys);
        line_rd_addr = 7'(n / 8);
        dot_in_col = 3'(n % 8);
        @(posedge clk_sys);
        #1;
        o = L + 19'(n);              // 19 bits: wraps at 0x80000 as LOW16(vc + 1) * 8 does
        if (packed_idx !== store_byte(o)) begin
          if (bad < 4)
            $display("FAIL %0s: byte %0d (store %05x) packed_idx=%02x want %02x",
                     what, n, o, packed_idx, store_byte(o));
          bad = bad + 1;
        end
      end
      if (bad != 0) begin
        $display("FAIL %0s: %0d of 640 bytes differ from NP2kai's wrapped walk", what, bad);
        errors = errors + 1;
      end else
        $display("  %0s: line at store %05x matches the wrapped walk", what, L);
    end
  endtask

  // One leg: the line at store offset L = {page, base, 000}, fetched twice so the ping-pong
  // shows it at the seam (the scanout bench's convention), then walked.
  task automatic leg(input [18:0] L, input [8*24-1:0] what);
    begin
      fetch_line(L[18], L[17:3]);
      fetch_line(L[18], L[17:3]);
      walk_wrap(L, what);
    end
  endtask

  // ==== CHECKS ====
  initial begin
    cut_reqs = 0;
    bound_errs = 0;
    @(negedge clk_sys);
    reset = 0; resetn = 1;
    repeat (4) @(posedge clk_sys);
    repeat (30000) @(posedge clk_sys);   // 600 us: past the controller's 200 us JEDEC init

    for (k = 0; k < 256; k = k + 1) begin
      port0_store(PEG_BASE + 32'h0007_FC00 + 32'(k * 4), store_dword(19'h7FC00 + 19'(k * 4)));
      port0_store(PEG_BASE + 32'(k * 4), store_dword(19'(k * 4)));
      port0_store(PEG_BASE + 32'h0008_0000 + 32'(k * 4), ~store_dword(19'(k * 4)));
    end

    leg(19'h7FD80, "ends at the end (no cut)");
    leg(19'h7FFE0, "32 bytes before the end");
    leg(19'h7FFF8, "8 bytes before the end");
    leg(19'h7FFF0, "16 bytes before the end");
    leg(19'h7FE70, "400 bytes: exact fit");
    leg(19'h7FEB8, "328 bytes: mid-line cut");
    leg(19'h7FD90, "624 bytes: last burst");
    // The five cut legs (32/8/16/328/624 bytes) each cut one burst per completed fetch, a cut
    // and its remainder, and every leg fetches twice: at least 20 short requests. (A fetch
    // re-armed by this bench's enable edge and then by its tick can start a line twice, so a
    // cut in the first bursts may be issued once more; the monitor above holds every short
    // request to the cut's shape.) A wrap that never cut would leave this at 0.
    if (cut_reqs < 20) begin
      $display("FAIL %0d port-3 requests were wrap cuts, want at least 20 (5 legs x 2 fetches x cut + remainder)", cut_reqs);
      errors = errors + 1;
    end

    if (bound_errs != 0) begin
      $display("FAIL %0d port-3 requests ran past the end of the store", bound_errs);
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PEGC_SCAN_WRAP: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_PEGC_SCAN_WRAP: FAIL (%0d errors)", errors);
  end

endmodule

`timescale 1ns/1ps
`include "sdram_sync_bench.svh"   // the SDRAM bench clock: the controller on clk_sys

// ==== WHAT THIS PROVES ====
// TB_PC9821_PEGC_SCANOUT: the packed scanout fetches one 640-byte display line per raster line as SDRAM bursts on the fourth requester - 160 dwords from {display page, GDC line base[14:0], 3'b000} at peg_base (MAME pc9821.cpp:104-113's `(...) << 3` line addressing over the GDC's area partition, qemu pc98-vga.c:4426-4437's 640-byte pitch) - and serves the mixer's column walk byte-for-byte in dot order (one dword for its four dots, the byte picked by dot[1:0]), with the display page forced to 0 while the FF2 dat-0x68 VRAM-boundary f/f is set (MAME pc9821.cpp:98) and reachable at +0x40000 without it, ping-pong buffers so the displayed line survives while the next is fetched, and NO 200-line interleave (the references copy packed rows directly: qemu 4422-4438, MAME 100-123). The walk is repeated at TEN line-base alignments that put the line start at every position around a 512-dword row end - including the start where the 10-dword burst exactly fits the row - so the controller's mid-line row SPLIT and the packed page/base arithmetic are walked, not just one aligned case: a second segment read from the wrong row, an off-by-one column or a wrong-page read is a byte the walk cannot match. The packed page is TWO terms (pc9821_pegc_scan's line_base_new): the SCROLL walk's own page bit - the GDC2 start word's bit 14, gfx_walk_page - XOR the 0xA4 term MAME adds (pc9821.cpp:98,112), with the FF2 dat-0x68 f/f zeroing the 0xA4 TERM only (NP2kai's packed arm drops the 0xA4 term and its non-packed arm drops the walk bit - the recorded divergence); the page-flip legs pin that composition in all four term combinations. FAIL-FIRST: with the walk bit dropped (the pre-fix page term) the walk-1 fetch reads page 0 and every flip leg mismatches its tag. FAIL-FIRST: before pc9821_pegc_scan existed the mixer seam had no packed_idx at all. The run goes through the REAL sdram_sync_bridge (the controller on clk_sys) and the REAL src/memory/sdram.v on PORT 3, so the row-6 fourth-requester wiring is in the path. A line tick that lands while a port-3 request is presented and not yet taken defers the restart until that request is taken and its burst drains (the sdram_sync_bridge contract: valid and payload held to ready), and the next line is then fetched whole - FAIL-FIRST: the restart moved the address under the held request and the seam showed the wrong line.

// ==== DUT ====
// pc9821_pegc_scan alone on the memory side, behind the real SDRAM bridge and
// the real controller against sdram_chip_model. Ports 0-2 are idle except port 0,
// which the bench uses to preload the store (the same route a packed-window CPU
// write would take). The expected bytes are the preload pattern itself - the
// bench never asks the DUT what it fetched, only whether the byte that comes out
// of the read port is the byte that went into the store.

module tb_pc9821_pegc_scanout;

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
  reg [14:0] sw_base;
  reg  [7:0] sw_tag;

  // Bound: a fetch that never completes is a FAIL, not a stall.
  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_PEGC_SCANOUT: FAIL watchdog (the run did not finish)");
  end

  // ==== STIMULUS ====
  // The preload pattern: the byte at (tag, dword d, lane l) is a value where a
  // byte from the wrong dword, the wrong lane or the wrong line cannot be
  // confused for the right one. `tag` names WHICH preloaded line (two lines at
  // two display pages carry different patterns).
  function automatic [7:0] line_byte(input tag, input [8:0] d, input [1:0] lane);
    begin
      line_byte = 8'h40 ^ d[7:0] ^ {lane, 6'b0} ^ (tag ? 8'hA5 : 8'h00);
    end
  endfunction
  function automatic [31:0] line_dword(input tag, input [8:0] d);
    begin
      line_dword = {line_byte(tag, d, 2'd3), line_byte(tag, d, 2'd2),
                    line_byte(tag, d, 2'd1), line_byte(tag, d, 2'd0)};
    end
  endfunction

  task automatic port0_store(input [31:0] a, input [31:0] d);
    integer g;
    begin
      @(negedge clk_sys);
      p0_addr = a; p0_din = d; p0_be = 4'hF; p0_write = 1; p0_valid = 1;
      g = 0; while (!p0_ready && g < 2000) begin @(negedge clk_sys); g = g + 1; end
      if (!p0_ready) $fatal(1, "TB_PC9821_PEGC_SCANOUT: no accept for preload %08x", a);
      @(negedge clk_sys); p0_valid = 0;
      repeat (2) @(negedge clk_sys);
    end
  endtask

  // Preload one 640-byte line of `tag` at {page, base} << 3.
  task automatic preload_line(input tag, input page, input [14:0] base);
    integer k;
    reg [18:0] off;
    begin
      off = {page, base, 3'b000};
      for (k = 0; k < 160; k = k + 1)
        port0_store(PEG_BASE + {13'd0, off} + 32'(k * 4), line_dword(tag, 9'(k)));
    end
  endtask

  // One fetched line: drop the enable (clears line_ready - the gvram_scan rule),
  // set the base/page/force, re-arm and tick, and wait for the line to fill. The
  // FETCH here is real: 160 dwords over the fourth requester behind the real
  // SDRAM bridge and the real controller.
  task automatic fetch_line(input page, input [14:0] base, input force_zero,
                            input walk_page);
    integer g;
    begin
      scan_enable = 1'b0;
      @(negedge clk_sys);
      scan_page = page; scan_line_base = base; page_force_zero = force_zero;
      scan_walk_page = walk_page;
      scan_enable = 1'b1;
      @(negedge clk_sys);
      scan_line_tick = 1'b1;
      @(negedge clk_sys);
      scan_line_tick = 1'b0;
      g = 0;
      while (!line_ready && g < 4000) begin @(negedge clk_sys); g = g + 1; end
      if (!line_ready) $fatal(1, "TB_PC9821_PEGC_SCANOUT: a line never became ready");
    end
  endtask

  // Read the line the MIXER would show, byte for byte, at the mixer seam. The
  // mixer drives line_rd_sel = line_sel (pc9821_video_mixer.sv:94, `assign line_rd_sel  = line_sel;`) and walks the
  // column address + dot-within-column; that is exactly this walk. Because the
  // ping-pong displays the PREVIOUSLY fetched buffer (the gvram_scan display
  // pipeline), the line visible here is the one fetched BEFORE the last
  // fetch_line - so the checks below read the seam after each fetch and compare
  // against that fetch's predecessor.
  task automatic walk_line(input tag);
    integer n;
    begin
      line_rd_sel = line_sel;            // the mixer's own convention
      for (n = 0; n < 640; n = n + 1) begin
        @(negedge clk_sys);
        line_rd_addr = 7'(n / 8);        // column 0..79 (8 bytes / 2 dwords each)
        dot_in_col = 3'(n % 8);          // dot-within-column picks dword+byte
        @(posedge clk_sys);              // the registered buffer read settles
        #1;
        if (packed_idx !== line_byte(tag, 9'(n / 4), n[1:0])) begin
          $display("FAIL byte %0d: packed_idx=%02x want %02x", n, packed_idx,
                   line_byte(tag, 9'(n / 4), n[1:0]));
          errors = errors + 1;
        end
      end
    end
  endtask

  reg sel0, sel1, sel2, sel3;

  // ---- the ALIGNMENT SWEEP (the row-crossing probe) ----
  // A 640-byte line is 160 dwords and the controller's rows are 512 dwords, so a
  // line STARTING within 10 dwords of its row's end makes the fetch's burst cross
  // the row boundary: the controller splits that burst (the second ACT opens the
  // next row) and the port-3 response beats must still land in the line buffer in
  // order. A line start exactly at the boundary (10 dwords left) must NOT split.
  // peg_base is dword-row aligned (PEG_BASE = 0x0200_0000, 512-dword aligned), so
  // the start column is (base * 2) mod 512 and the probe picks bases on each side
  // of it. Each line carries its own tag, so a segment read from the WRONG row is
  // a value the walk cannot match.
  function automatic [7:0] sweep_byte(input [7:0] tag, input [8:0] d, input [1:0] lane);
    begin
      sweep_byte = 8'h20 ^ tag ^ d[7:0] ^ {lane, 6'b0};
    end
  endfunction
  function automatic [31:0] sweep_dword(input [7:0] tag, input [8:0] d);
    begin
      sweep_dword = {sweep_byte(tag, d, 2'd3), sweep_byte(tag, d, 2'd2),
                     sweep_byte(tag, d, 2'd1), sweep_byte(tag, d, 2'd0)};
    end
  endfunction
  task automatic preload_sweep(input [7:0] tag, input [14:0] base);
    integer k;
    begin
      for (k = 0; k < 160; k = k + 1)
        port0_store(PEG_BASE + ({13'd0, base, 3'b000}) + 32'(k * 4), sweep_dword(tag, 9'(k)));
    end
  endtask
  task automatic walk_sweep(input [7:0] tag);
    integer n;
    begin
      line_rd_sel = line_sel;
      for (n = 0; n < 640; n = n + 1) begin
        @(negedge clk_sys);
        line_rd_addr = 7'(n / 8);
        dot_in_col = 3'(n % 8);
        @(posedge clk_sys);
        #1;
        if (packed_idx !== sweep_byte(tag, 9'(n / 4), n[1:0])) begin
          $display("FAIL sweep byte %0d (tag %02x): packed_idx=%02x want %02x",
                   n, tag, packed_idx, sweep_byte(tag, 9'(n / 4), n[1:0]));
          errors = errors + 1;
        end
      end
    end
  endtask

  // ==== CHECKS ====
  initial begin
    @(negedge clk_sys);
    reset = 0; resetn = 1;
    repeat (4) @(posedge clk_sys);
    repeat (30000) @(posedge clk_sys);   // 600 us: past the controller's 200 us JEDEC init

    // Two preloaded lines at two display pages, distinct patterns:
    //   addr_A = {page 0, base 0x123, 000} = +0x918     -> tag 0 (PA)
    //   addr_B = {page 1, base 0x123, 000} = +0x40918   -> tag 1 (PB)
    preload_line(1'b0, 1'b0, 15'h0123);
    preload_line(1'b1, 1'b1, 15'h0123);

    // The display pipeline (gvram_scan ping-pong): each fetch_line's swap exposes
    // the PREVIOUSLY fetched buffer at the mixer seam (line_rd_sel = line_sel).
    //   fetch0 (page0)      -> fills a buffer;   seam not yet meaningful
    //   fetch1 (page1)      -> seam shows fetch0 (page0 = PA)   [page-0 addressing]
    //   fetch2 (page1,frc1) -> seam shows fetch1 (page1 = PB)   [page-1 addressing]
    //   fetch3 (page1)      -> seam shows fetch2 (forced = PA)  [force-zero -> page 0]
    fetch_line(1'b0, 15'h0123, 1'b0, 1'b0);
    sel0 = line_sel;
    fetch_line(1'b1, 15'h0123, 1'b0, 1'b0);
    sel1 = line_sel;
    walk_line(1'b0);                       // PA: {page 0, base}<<3 + byte order
    fetch_line(1'b1, 15'h0123, 1'b1, 1'b0);
    sel2 = line_sel;
    walk_line(1'b1);                       // PB: {page 1, base}<<3 = +0x40000
    fetch_line(1'b1, 15'h0123, 1'b0, 1'b0);
    sel3 = line_sel;
    walk_line(1'b0);                       // PA: force_zero forced the page to 0

    // ---- the alignment sweep: every line start that puts the fetch's row offset
    // inside the last 9 dwords of a 512-dword row, plus the exact 10-dword fit, plus
    // the two halves of the base's own wrap. base mod 256 sets the start column
    // (col = (base * 2) mod 512), so these bases reach col 500/502/504/510/0/256...
    for (k = 0; k < 10; k = k + 1) begin
      case (k)
        0: sw_base = 15'h0000;            // col 0: no crossing
        1: sw_base = 15'h00FA;            // col 500: burst 1 crosses
        2: sw_base = 15'h00FB;            // col 502: the 10-dword burst FITS exactly
        3: sw_base = 15'h00FC;            // col 504: burst 0 crosses
        4: sw_base = 15'h00FF;            // col 510: burst 0 crosses, 2 dwords left
        5: sw_base = 15'h01FA;            // base+256: col 500 again, other half of the store
        6: sw_base = 15'h01FC;            // base+256: col 504 again
        7: sw_base = 15'h0123;            // the addressing legs' own base (col 70)
        8: sw_base = 15'h7000;            // high base: col 4096 mod 512 = 0
        default: sw_base = 15'h7FFF;      // the top of the GDC counter (col 510)
      endcase
      sw_tag = 8'h80 + 8'(k * 11);
      preload_sweep(sw_tag, sw_base);
      fetch_line(1'b0, sw_base, 1'b0, 1'b0);
      fetch_line(1'b0, sw_base, 1'b0, 1'b0);
      walk_sweep(sw_tag);
    end

    // ---- the packed page flip: the SCROLL walk's own page bit (gfx_walk_page) ----
    // The 256-colour games double-buffer through the GDC2 SCROLL start word's bit 14:
    // NP2kai's packed arm walks `LOW16(vad << 1)` with the page in the walk's bit 15
    // (vram/makegrex.c:199), MAME keeps it through `& 0xffff` and names the flip
    // register ("double buffering at SAD $38fc and $fffc", pc9821.cpp:108-113), and the
    // machine swaps at the frame boundary (the uPD7220 reads the SAD "at the start of the
    // display scanning process"; the real Xe10 shows full frames under DOOM's flip).
    // The same 512 KiB window is walked at {walk_page ^ (force ? 0 : page), base}<<3:
    // MAME adds `m_vram_disp * 0x40000` to the walked address (pc9821.cpp:98,112) and
    // zeroes that TERM - not the walk bit - at the FF2 dat-0x68 f/f (pc9821.cpp:98).
    // FAIL-FIRST: with scan_walk_page dropped (the pre-fix page term) the walk-1
    // fetch reads page 0 and every walk_page leg below mismatches its tag.
    preload_line(1'b0, 1'b0, 15'h0200);   // tag 0 pattern at page 0, base 0x200
    preload_line(1'b1, 1'b1, 15'h0200);   // tag 1 pattern at page 1, same base
    fetch_line(1'b0, 15'h0200, 1'b0, 1'b0);   // walk 0 -> page 0
    fetch_line(1'b0, 15'h0200, 1'b0, 1'b1);   // walk 1 -> page 1 (the SAD flip)
    walk_line(1'b0);                          // seam shows the walk-0 fetch: page 0
    fetch_line(1'b0, 15'h0200, 1'b0, 1'b1);
    walk_line(1'b1);                          // seam shows the walk-1 fetch: page 1
    fetch_line(1'b1, 15'h0200, 1'b0, 1'b1);   // 0xA4=1 XOR walk 1 -> page 0
    walk_line(1'b1);                          // ...the page-1 fetch before it
    fetch_line(1'b1, 15'h0200, 1'b0, 1'b1);
    walk_line(1'b0);                          // seam shows the XOR leg: page 0
    fetch_line(1'b1, 15'h0200, 1'b1, 1'b1);   // force zeroes the 0xA4 term only -> page 1
    walk_line(1'b0);                          // ...the XOR leg before it: page 0
    fetch_line(1'b0, 15'h0200, 1'b0, 1'b0);
    walk_line(1'b1);                          // seam shows the force leg: page 1

    // ---- ping-pong: the displayed buffer flips per fetched line, so the line
    // just shown survives while the next is fetched (never blended). ----
    if (!((sel0 !== sel1) && (sel1 !== sel2) && (sel2 !== sel3))) begin
      $display("FAIL ping-pong: line_sel did not flip every fetch (%b %b %b %b)",
               sel0, sel1, sel2, sel3);
      errors = errors + 1;
    end

    // ---- a line tick that lands while a request is PRESENTED and not yet taken ----
    // The SDRAM bridge's contract (sdram_sync_bridge: "the controller samples it on the
    // cycle it takes the request"): a requester holds valid AND its payload until ready.
    // A tick in that window must not restart the fetch under the presented request; the
    // restart is deferred until the request is taken and its burst drains, and the new
    // line is then fetched whole. A raster reprogram or an overrun line puts a tick there
    // (the 640x480 frame at 90 MHz did, during the mode set).
    // FAIL-FIRST: the pre-fix restart moved mem_addr under the held valid, and the seam
    // showed the wrong line (byte 0 0x4a where Q's is 0xe5).
    preload_line(1'b0, 1'b0, 15'h0300);   // P: tag 0 at page 0, base 0x300
    preload_line(1'b1, 1'b1, 15'h0300);   // Q: tag 1 at page 1, same base
    scan_enable = 1'b0;
    @(negedge clk_sys);
    scan_page = 1'b0; scan_line_base = 15'h0300; page_force_zero = 1'b0; scan_walk_page = 1'b0;
    scan_enable = 1'b1;
    @(negedge clk_sys);
    scan_line_tick = 1'b1;
    @(negedge clk_sys);
    scan_line_tick = 1'b0;
    // Past P's first burst, find a presented request the controller has not taken.
    begin : held_tick
      integer g;
      g = 0;
      while (!(p3_valid && !p3_ready && dut.fetch_w != 9'd0) && g < 4000) begin
        @(negedge clk_sys); g = g + 1;
      end
      if (!(p3_valid && !p3_ready))
        $fatal(1, "TB_PC9821_PEGC_SCANOUT: never saw a held port-3 request to tick under");
      scan_page = 1'b1;                     // the next line is Q
      scan_line_tick = 1'b1;
      @(negedge clk_sys);
      scan_line_tick = 1'b0;
      g = 0;
      while (!line_ready && g < 8000) begin @(negedge clk_sys); g = g + 1; end
      if (!line_ready) $fatal(1, "TB_PC9821_PEGC_SCANOUT: the deferred restart never filled its line");
    end
    // P never completed, so the restart did not swap; Q filled the buffer behind the seam.
    // One more fetch swaps it to the seam.
    fetch_line(1'b0, 15'h0300, 1'b0, 1'b0);
    walk_line(1'b1);                        // the seam shows Q, whole

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PEGC_SCANOUT: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_PEGC_SCANOUT: FAIL (%0d errors)", errors);
  end


endmodule

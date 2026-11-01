`timescale 1ns/1ps
`include "sdram_sync_bench.svh"   // the SDRAM bench clock: the controller on clk_sys

// ==== WHAT THIS PROVES ====
// TB_PC9821_PEGC_STORE_RATE: the PEGC posted store buffer sustains the packed-store rates the DOOM path needs (trade-candidates T21 / T23): a back-to-back byte store stream (rep movsb's shape: one byte lane per dword address, walking the lanes) and a dword store stream, driven through the real pc9821_pegc_storebuf onto the REAL sdram_sync_bridge (the controller on clk_sys at the shipping 90 MHz) at the deployed settings (ADQM=1, FAST_GRADE=0) and the REAL src/memory/sdram.v against sdram_chip_model on port 0 while the packed scanout line fetch runs on port 3 the whole time, sustain at least 25 MB/s of byte stores and at least the 14.44 MB/s frame need in dword stores into SDRAM (the 55 MB/s dword budget, set for the 50/100 split-clock build, is REPORTED since the SDRAM moved onto clk_sys - trade T36), the byte stream's four neighbouring bytes of a dword collapse into ONE backend write (write transactions <= bytes/4 + 4), the dword stream drains through port 0's TWO-WORD write (din0_hi real data, read back byte-exact), a read issued right behind a store sees the buffered bytes (drain-before-read), and dirty dwords never linger: the buffer reports empty within 2 us of the last store's accept and a scanout line fetched 4 us after stores that fill its first 64 bytes shows the new bytes (P2-6, the horizontal-stripe class). THE COLUMN STREAM IS ASSERTED NOW, not raised: one byte lane per step at stride 640 (the shape a packed-mode game draws its frame with) must sustain at least the RATE MODEL's own floor for the shape - the GD gather-session cost 7+s clk_sdram per session of s byte stores (the G3 7+2s less one per store for the read the mask eliminates) over the stream's run distribution 4,3,3,3,3 stores per 2 KiB SDRAM row, its effective band minus the model allowance, at the CONTROLLER's clock (21.30 MB/s at this bench's 90 MHz same-clock controller and GATHER_K=4, measured 29.92; 11.83 at the 50 MHz clock this bench ran before, 23.66 at the old 100 MHz clk_sdram) and never below the 14.44 MB/s a 640x400 frame at 56.42 Hz needs, because same-row stores now drain as GATHER sessions (up to GATHER_K entries per request: one ACT, NO half reads, one masked half write per touched half with the byte mask on A[12:11], one precharge) instead of one controller read-modify-write per byte; FAIL-FIRST: this leg measured 5.8-6.7 MB/s before G3 and 5.87 MB/s on HEAD's un-posted path. THE SCANOUT'S OWN CAPACITY IS MEASURED THROUGHOUT: with either stream running the packed line fetch still completes inside its raster line (worst 594-604 of the 3627-clk_sys line) and the fourth requester keeps feeding the line buffer at 149-173 response beats per line against 160 owed (at least 128 asserted), so the store stream does NOT starve the packed scanout (an earlier form that gated each burst on the buffer being empty measured 2 beats per line - a held line on the display - and is NOT shipped). RESIDENCY BOUND (FAIL-FIRST): a SKIPPED-TO-SAME-DWORD byte stream driven at one store per clk_sys holds one PARTIAL entry for the whole stream under a window that ages only on idle cycles, so the backend received 0 writes in six hold windows and the fetched line read the replaced dword; every entry's window now ages from its OWN allocation (the 1aacf864 fix generalised) and the same run measures 5 writes in 540 clk_sys, six windows (>= 4 = the bound at HOLD_CYCLES 90, 1 us). FROZEN PRESENTATION (the pair-drain payload freeze): with the backend's accept held off while a pair drain is presented, a store to the pair's SECOND dword posts as its own entry - the presented payload mem_din_hi included does not move, and the store's bytes reach the backend in a later request (pre-fix the merge landed in the presented word and vanished at the drain's pop). FULL-BUFFER COMBINE (FAIL-FIRST): in_ready is count < DEPTH alone, so a store that could only combine into a FULL buffer waits for one drain and then merges (8 backend writes, not 9); the pre-change buffer accepted it at once.

// ==== DUT ====
// The store path is the seam: CPU-side valid/ready store and read ports of this bench
// through pc9821_pegc_storebuf (the posted, byte-combining, pair-draining buffer
// pc9821_memory_subsystem puts on the PEGC route) onto the bridge's port 0 (the same
// route the map slot takes - split_sdram_backend's mem0, whose din0_hi carries the
// pair's second dword). The packed scanout is the real pc9821_pegc_scan on the
// controller's FOURTH requester, and the controller is the real src/memory/sdram.v
// against sdram_chip_model, so the store rate is measured against the same RMW
// (ADQM=1 masked byte stores) and the same round-robin the DOOM path faces.


module tb_pc9821_pegc_store_rate;

  // The gather session size under test: the same value feeds the store buffer's
  // grouping and the controller's engine (the deployed one is z486_mister.sv's
  // GATHER_K). The sweep over 2/3/4/8 builds this bench with -GGK=<n>.
  parameter integer GK = 4;

  // The requesters AND the SDRAM controller run on clk_sys at the SHIPPING clock (build_profile.py
  // base: 90 MHz). The rates this bench asserts are the shipping build's; a 50 MHz controller pays
  // two clocks of the -7 part's 21 ns tRCD/tRP where 90 MHz pays two as well, so a 50 MHz run
  // under-states the machine by the clock ratio. Every clock-derived constant below is its time
  // value at SYS_MHZ.
  localparam integer SYS_MHZ  = 90;
  localparam integer LINE_CLK = 2015 * SYS_MHZ / 50;   // the 40.3 us raster line, in clk_sys
  localparam integer HOLD_CLK = SYS_MHZ;               // the 1 us combining window (pc9821_memory_subsystem's SYS_CLOCK_HZ / 1e6)
  localparam integer RES_CLK  = 6 * HOLD_CLK;          // six hold windows of saturated same-dword stores
  reg clk_sys = 0;
  always #(500.0 / SYS_MHZ) clk_sys = ~clk_sys;
  reg reset = 1;
  reg resetn = 0;

  // ---- the scan side (the tb_pc9821_pegc_scanout harness) ----
  reg        scan_enable = 0, scan_line_tick = 0;
  reg        scan_page = 0, page_force_zero = 0;
  reg [14:0] scan_line_base = 0;
  reg  [6:0] line_rd_addr = 0;
  reg        line_rd_sel = 0;
  reg  [2:0] dot_in_col = 0;
  wire [7:0] packed_idx;
  wire       line_sel, line_ready;
  localparam [31:0] PEG_BASE = 32'h0200_0000;

  // ---- the CPU-side store/read port (this bench plays z486's direct path) ----
  reg  [31:0] s_addr = 0, s_din = 0;
  reg   [3:0] s_be = 0;
  reg         s_write = 0, s_valid = 0;
  wire        s_ready;
  wire [31:0] s_dout;
  wire        s_resp_valid;
  wire        s_busy;        // the store path still holding un-issued dirty dwords

  // ---- the memory side: port 3 for the scanout fetch, port 0 for the store path ----
  wire [31:0] p3_addr, p3_din;
  wire  [3:0] p3_be;
  wire  [7:0] p3_burst;
  wire        p3_valid, p3_write;
  wire        p3_ready, p3_resp_valid;
  wire [31:0] p3_dout;

  wire [31:0] p0_addr, p0_din, p0_din_hi;
  wire  [3:0] p0_be;
  wire  [7:0] p0_burst;
  wire        p0_valid, p0_write;
  wire        p0_gath;
  wire [440:0] p0_gath_extra;
  wire        p0_ready;
  wire [31:0] p0_dout;
  wire        p0_resp_valid;

  pc9821_pegc_scan dut (
      .clk(clk_sys), .reset(reset),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .page_force_zero(page_force_zero),
      .scan_walk_page(1'b0),
      .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .dot_in_col(dot_in_col), .dot_ce(1'b0), .line_rd_act(1'b1),   // dot phase is another bench's subject
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
  sdram_sync_bridge #(.FREQ(SYS_MHZ * 1_000_000), .ADQM(1'b1), .FAST_GRADE(1'b0), .GATHER_K(GK)) backend (
      .clk(clk_sys), .resetn(resetn),
      .refresh_allowed(1'b1), .busy(busy), .sdram_size(2'd2),
      .valid0(p0_valid), .ready0(p0_ready), .wr0(p0_write), .addr0(p0_addr[26:0]),
      .din0(p0_din), .din0_hi(p0_din_hi), .gath0(p0_gath), .gath0_extra(p0_gath_extra),
      .dout0(p0_dout), .resp_valid0(p0_resp_valid),
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

  sdram_chip_model #(.T_RP(2), .T_WR(2), .FREQ_HZ(SYS_MHZ * 1_000_000), .GRADE(7)) chip (
      .clk(clk_sys), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nWE(nWE), .nRAS(nRAS), .nCAS(nCAS), .nCS(nCS)
  );

  // ==== THE STORE-PATH SEAM ====
  // The fixed form: the CPU-side request goes through pc9821_pegc_storebuf - the
  // posted, byte-combining, pair-draining buffer pc9821_memory_subsystem puts on
  // the PEGC route (trade-candidates T21; pegc-perf-REPORT.md P0-1). Every check
  // below is written against the CPU-side ports only, so the same run measured
  // both this form and HEAD's direct (un-posted) path.
  pc9821_pegc_storebuf #(.HOLD_CYCLES(HOLD_CLK), .GATHER_K(GK)) storebuf (
      .clk(clk_sys), .reset(reset),
      .in_valid(s_valid), .in_write(s_write), .in_addr(s_addr), .in_din(s_din),
      .in_be(s_be), .in_burstcount(8'd1),
      .in_peg_route(1'b1),      // this bench drives the PEGC route exclusively
      .in_ready(s_ready),
      .in_rd_block(1'b0),
      .sdram_size(2'd2),        // the bridge's own geometry (64 MB, 2 KiB rows)
      .mem_addr(p0_addr), .mem_din(p0_din), .mem_din_hi(p0_din_hi),
      .mem_be(p0_be), .mem_burstcount(p0_burst),
      .mem_valid(p0_valid), .mem_write(p0_write),
      .mem_gath(p0_gath), .mem_gath_extra(p0_gath_extra),
      .mem_ready(p0_ready),
      .busy(s_busy)
  );
  assign s_dout       = p0_dout;
  assign s_resp_valid = p0_resp_valid;

  // ---- THE FROZEN-PRESENTATION HARNESS (the pair-drain payload freeze) ----
  // A second store buffer on a SCRIPTED backend accept: the freeze shape needs
  // a presented pair drain held open while a store lands on its second dword,
  // and the real bridge accepts within a few cycles. Same module, same GATHER_K;
  // only mem_ready is the bench's to hold.
  reg         fz_valid = 0, fz_write = 0;
  reg  [31:0] fz_addr = 0, fz_din = 0;
  reg   [3:0] fz_be = 0;
  wire        fz_ready, fz_busy;
  wire [31:0] fz_maddr, fz_mdin, fz_mdin_hi;
  wire  [3:0] fz_mbe;
  wire  [7:0] fz_mburst;
  wire        fz_mvalid, fz_mwrite, fz_mgath;
  wire [440:0] fz_mex;
  reg         fz_mready = 0;
  pc9821_pegc_storebuf #(.HOLD_CYCLES(HOLD_CLK), .GATHER_K(GK)) freezebuf (
      .clk(clk_sys), .reset(reset),
      .in_valid(fz_valid), .in_write(fz_write), .in_addr(fz_addr), .in_din(fz_din),
      .in_be(fz_be), .in_burstcount(8'd1),
      .in_peg_route(1'b1),
      .in_ready(fz_ready),
      .in_rd_block(1'b0),
      .sdram_size(2'd2),
      .mem_addr(fz_maddr), .mem_din(fz_mdin), .mem_din_hi(fz_mdin_hi),
      .mem_be(fz_mbe), .mem_burstcount(fz_mburst),
      .mem_valid(fz_mvalid), .mem_write(fz_mwrite),
      .mem_gath(fz_mgath), .mem_gath_extra(fz_mex),
      .mem_ready(fz_mready),
      .busy(fz_busy)
  );

  task automatic fz_store(input [31:0] a, input [31:0] d, input [3:0] b);
    integer g;
    begin
      @(negedge clk_sys);
      fz_addr = a; fz_din = d; fz_be = b; fz_write = 1'b1; fz_valid = 1'b1;
      #1;
      g = 0;
      while (!fz_ready && g < 2000) begin @(negedge clk_sys); #1; g = g + 1; end
      if (!fz_ready) $fatal(1, "TB_PC9821_PEGC_STORE_RATE: the freeze harness refused a store");
      @(negedge clk_sys);
      fz_valid = 1'b0;
    end
  endtask

  integer errors = 0;

  // ---- THE LINE-FETCH DEADLINE INSTRUMENT ----
  // The packed display is committed one raster line ahead by its ping-pong: the scan accepts
  // a line tick, fetches the line, and the DISPLAY swap is deferred (
  // `if (prev_done)` in pc9821_pegc_scan) when the fetch has not finished - so a fetch that
  // misses the line deadline DROPS the line instead of showing a blended one. The raster
  // budget is the bench's own tick interval (LINE_CLK clk_sys = the 40.3 us line this bench and
  // tb_pc9821_gvram_bandwidth use). Count the cycles from the tick to the line's 160th
  // response beat, and report the worst one.
  // The scanout's KEEP-UP count: response beats in a window against 160 per raster line.
  // A fetch that cannot finish inside its line is a dropped/held line on the display, so
  // this is the capacity check for anything that delays the fetch (the store-route gate).
  integer kap_beats = 0;
  integer kap_cycles = 0;
  reg     kap_on = 0;
  always @(posedge clk_sys) begin
    if (reset) kap_on <= 1'b0;
    else if (kap_on) begin
      kap_cycles <= kap_cycles + 1;
      if (p3_resp_valid) kap_beats <= kap_beats + 1;
    end
  end

  integer lat_cycles = 0;
  integer lat_max    = 0;
  integer lat_beats  = 0;
  reg     lat_run    = 0;
  always @(posedge clk_sys) begin
    if (reset) begin
      lat_run <= 1'b0; lat_cycles <= 0; lat_beats <= 0; lat_max <= 0;
    end else begin
      if (scan_line_tick && background_on) begin
        lat_run <= 1'b1; lat_cycles <= 0; lat_beats <= 0;
      end else if (lat_run) begin
        if (p3_resp_valid) lat_beats <= lat_beats + 1;
        if (lat_beats == 159) begin
          lat_run <= 1'b0;
          if (lat_cycles > lat_max) lat_max <= lat_cycles;
        end else lat_cycles <= lat_cycles + 1;
      end
    end
  end

  // Backend write transactions and pair writes, counted at the port-0 accept. A
  // gather drain counts as ONE write accept whatever its entry count (its burst is
  // the entry count, so a 2-entry gather is not a pair).
  integer wr_accepts = 0;
  integer wr_pairs   = 0;
  integer wr_gathers = 0;
  always @(posedge clk_sys) begin
    if (p0_valid && p0_ready && p0_write) begin
      wr_accepts = wr_accepts + 1;
      if (p0_gath) wr_gathers = wr_gathers + 1;
      if ((p0_burst == 8'd2) && !p0_gath) wr_pairs = wr_pairs + 1;
    end
  end

  // Bound: a stream that never completes is a FAIL, not a stall.
  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_PEGC_STORE_RATE: FAIL watchdog (the run did not finish)");
  end

  // ==== STIMULUS ====
  // The byte a store to `a` carries: a value a wrong lane, a wrong dword or a stale
  // buffer read cannot be confused for it.
  function automatic [7:0] pat_byte(input [31:0] a);
    begin
      pat_byte = 8'h5A ^ a[7:0] ^ {a[9:2] & 8'h3F, 2'b00};
    end
  endfunction
  function automatic [31:0] pat_dword(input [31:0] a);
    begin
      pat_dword = {pat_byte(a + 32'd3), pat_byte(a + 32'd2),
                   pat_byte(a + 32'd1), pat_byte(a + 32'd0)};
    end
  endfunction

  // The line region's preload pattern (the tb_pc9821_pegc_scanout one).
  function automatic [7:0] line_byte(input [8:0] d, input [1:0] lane);
    begin
      line_byte = 8'h40 ^ d[7:0] ^ {lane, 6'b0};
    end
  endfunction
  function automatic [31:0] line_dword(input [8:0] d);
    begin
      line_dword = {line_byte(d, 2'd3), line_byte(d, 2'd2),
                    line_byte(d, 2'd1), line_byte(d, 2'd0)};
    end
  endfunction

  // One CPU-side store: present, hold until the accept, return at the NEXT negedge so
  // a caller that loops straight back drives one store per clk_sys at best.
  task automatic cpu_store32(input [31:0] a, input [31:0] d, input [3:0] be);
    integer g;
    begin
      s_addr = a; s_din = d; s_be = be; s_write = 1'b1; s_valid = 1'b1;
      #1;                                   // settle: sample the combinational ready past the delta
      g = 0;
      while (!s_ready && g < 200000) begin @(negedge clk_sys); #1; g = g + 1; end
      if (!s_ready) $fatal(1, "TB_PC9821_PEGC_STORE_RATE: no accept for store %08x", a);
      @(negedge clk_sys);
    end
  endtask

  // ONE CPU-side store, race-free: the payload is driven at a NEGEDGE, held until the
  // accept is SEEN (a posedge where the ready is high - the ready is combinational, so
  // sampling it after the edge is the accept of that edge), then dropped at the next
  // negedge. `cpu_store32` publishes its payload for the accept edge to race (a known
  // trap), which re-posts a store several times and can
  // merge the OLD address with the NEW data - fine for a rate stream, useless for a
  // reordering/coherency probe.
  task automatic store_sync(input [31:0] a, input [31:0] d, input [3:0] be);
    begin
      @(negedge clk_sys);
      s_addr <= a; s_din <= d; s_be <= be; s_write <= 1'b1; s_valid <= 1'b1;
      do @(posedge clk_sys); while (!s_ready);
      @(negedge clk_sys);
      s_valid <= 1'b0;
      @(negedge clk_sys);
    end
  endtask

  // One CPU-side dword read (the RAW check and the stream read-back).
  task automatic cpu_read32(input [31:0] a, output [31:0] d);
    integer g;
    begin
      s_addr = a; s_din = 32'd0; s_be = 4'hF; s_write = 1'b0; s_valid = 1'b1;
      #1;                                   // settle: sample the combinational ready past the delta
      g = 0;
      while (!s_ready && g < 200000) begin @(negedge clk_sys); #1; g = g + 1; end
      if (!s_ready) $fatal(1, "TB_PC9821_PEGC_STORE_RATE: no accept for read %08x", a);
      @(negedge clk_sys);
      s_valid = 1'b0;
      g = 0;
      while (!s_resp_valid && g < 200000) begin @(negedge clk_sys); g = g + 1; end
      if (!s_resp_valid) $fatal(1, "TB_PC9821_PEGC_STORE_RATE: no response for read %08x", a);
      d = s_dout;
      @(negedge clk_sys);
    end
  endtask

  // Regions (byte offsets from PEG_BASE): the background lines at 0..0x27FF, the
  // coherence line at 0x2800, the two streams well away from both. EVERYTHING lies inside the one
  // 512 KiB window the PEGC route maps (peg_window / pegc_packed: {peg_base[31:19], offset[18:0]}),
  // which the store buffer's entries rely on (they share bits [26:19]).
  localparam [31:0] BYTE_BASE  = PEG_BASE + 32'h0004_0000;
  localparam [31:0] DWORD_BASE = PEG_BASE + 32'h0005_0000;
  localparam [31:0] COL_BASE   = PEG_BASE + 32'h0000_8000;   // 256 steps x 640 = 160 KiB: 0x8000..0x2FFFF
  localparam [31:0] FZ_X       = PEG_BASE + 32'h0007_3000;   // the freeze harness's pair
  localparam [31:0] LINE_BASE  = PEG_BASE + 32'h0000_0000;   // {page 0, base} << 3
  localparam [14:0] COHER_BASE = 15'h0500;                   // offset 0x2800 = 10240

  // The byte-span stream: nbytes consecutive byte stores, one lane per dword (the
  // bases are dword-aligned, so be walks 1/2/4/8 with k[1:0]). The rate is measured
  // over the accepts between the first and last store (nbytes-2 of them).
  task automatic byte_stream(input integer nbytes, output real mbps);
    integer k;
    real t0, t1;
    begin
      for (k = 0; k < nbytes; k = k + 1) begin
        cpu_store32(BYTE_BASE + 32'(k), {4{pat_byte(BYTE_BASE + 32'(k))}},
                    4'h1 << k[1:0]);
        if (k == 1) t0 = $realtime;
        if (k == nbytes - 1) t1 = $realtime;
      end
      s_valid = 1'b0;
      mbps = (real'(nbytes - 2) * 1000.0) / (t1 - t0);
    end
  endtask

  // The dword stream: ndwords consecutive aligned dword stores.
  task automatic dword_stream(input integer ndwords, output real mbps);
    integer k;
    real t0, t1;
    begin
      for (k = 0; k < ndwords; k = k + 1) begin
        cpu_store32(DWORD_BASE + 32'(k * 4), pat_dword(DWORD_BASE + 32'(k * 4)), 4'hF);
        if (k == 1) t0 = $realtime;
        if (k == ndwords - 1) t1 = $realtime;
      end
      s_valid = 1'b0;
      mbps = (real'(ndwords - 2) * 4000.0) / (t1 - t0);
    end
  endtask

  // The scanout runs THROUGHOUT the streams: a line fetch on its own port every
  // raster line (40.3 us = LINE_CLK clk_sys), walking 16 non-overlapping lines
  // (640 bytes each: the GDC line base steps 80 per line, base << 3 = byte offset).
  reg background_on = 0;
  integer bg_tick = 0;
  integer bg_line = 0;
  always @(posedge clk_sys) begin
    if (reset) begin
      bg_tick <= 0; bg_line <= 0; scan_line_tick <= 0;
    end else if (background_on) begin
      scan_line_tick <= 1'b0;
      if (bg_tick == LINE_CLK) begin
        bg_tick <= 0;
        bg_line <= bg_line + 1;
        scan_line_tick <= 1'b1;
        scan_line_base <= 15'(((bg_line + 1) & 15) * 80);
        scan_page <= 1'b0;
        page_force_zero <= 1'b0;
      end else bg_tick <= bg_tick + 1;
    end else begin
      bg_tick <= 0;
      scan_line_tick <= 1'b0;
    end
  end

  // One fetched line at the mixer seam (the tb_pc9821_pegc_scanout walk). With
  // use_fill the first 64 bytes must be the coherence fill (8'hE0 + byte index).
  task automatic walk_line(input use_fill);
    integer n;
    reg [7:0] want;
    begin
      line_rd_sel = line_sel;
      for (n = 0; n < 640; n = n + 1) begin
        @(negedge clk_sys);
        line_rd_addr = 7'(n / 8);
        dot_in_col = 3'(n % 8);
        @(posedge clk_sys);
        #1;
        want = ((n < 64) && use_fill) ? (8'hE0 + 8'(n)) : line_byte(9'(n / 4), n[1:0]);
        if (packed_idx !== want) begin
          $display("FAIL seam byte %0d: packed_idx=%02x want %02x", n, packed_idx, want);
          errors = errors + 1;
        end
      end
    end
  endtask

  // One fetched line at the mixer seam, COUNTING the bytes that do not match instead of
  // failing on the first (the coherency probe needs the shape of the mismatch, not just
  // its existence).
  // The coherency leg's expected line: the background pattern, with the line's first
  // `nfill` bytes replaced by 0xE0 (the bytes the leg's byte stores write).
  task automatic walk_line_count(input integer nfill, output integer bad, output integer first_bad);
    integer n;
    reg [7:0] want;
    begin
      bad = 0;
      first_bad = -1;
      line_rd_sel = line_sel;
      for (n = 0; n < 640; n = n + 1) begin
        @(negedge clk_sys);
        line_rd_addr = 7'(n / 8);
        dot_in_col = 3'(n % 8);
        @(posedge clk_sys);
        #1;
        want = (n < nfill) ? 8'hE0 : line_byte(9'(n / 4), n[1:0]);
        if (packed_idx !== want) begin
          bad = bad + 1;
          if (first_bad < 0) first_bad = n;
          if (bad <= 8)
            $display("  stale byte %0d: got %02x want %02x", n, packed_idx, want);
        end
      end
    end
  endtask

  // Fetch one line and return when its buffer is full (the ping-pong swap exposes the
  // PREVIOUSLY fetched buffer at the seam, so callers fetch twice to walk one line).
  task automatic fetch_line(input [14:0] base);
    integer g;
    begin
      scan_enable = 1'b0;
      @(negedge clk_sys);
      scan_line_base = base;
      scan_page = 1'b0;
      page_force_zero = 1'b0;
      scan_enable = 1'b1;
      @(negedge clk_sys);
      scan_line_tick = 1'b1;
      @(negedge clk_sys);
      scan_line_tick = 1'b0;
      g = 0;
      while (!line_ready && g < 8000) begin @(negedge clk_sys); g = g + 1; end
      if (!line_ready) $fatal(1, "TB_PC9821_PEGC_STORE_RATE: a line never became ready");
    end
  endtask

  // THE COLUMN STREAM (DOOM's shape): one byte lane per step, the address walking DOWN a
  // column (stride 640 = the packed line pitch). Every store is dword-aligned lane 0, so
  // no two consecutive stores can share a dword and the buffer's byte-combining cannot
  // fire: the rate is what the GATHER drain gives (stores sharing a 2 KiB SDRAM row leave
  // as one session of up to GATHER_K entries - runs of 4,3,3,3,3 per 16 stores at this
  // stride - instead of one controller read-modify-write each).
  task automatic column_stream(input integer nbytes, output real mbps);
    integer k;
    real t0, t1;
    begin
      for (k = 0; k < nbytes; k = k + 1) begin
        cpu_store32(COL_BASE + 32'(k * 640), {4{pat_byte(COL_BASE + 32'(k * 640))}}, 4'h1);
        if (k == 1) t0 = $realtime;
        if (k == nbytes - 1) t1 = $realtime;
      end
      s_valid = 1'b0;
      mbps = (real'(nbytes - 2) * 1000.0) / (t1 - t0);
    end
  endtask

  // THE COLUMN FLOOR, from the RATE MODEL (never from this tree's RTL):
  // the store-rate model's G3 session cost with the read the ADQM mask
  // eliminates removed - one gather of s byte stores is 7 + s clk_sdram (ACT + s masked
  // half writes + the DQ turn + precharge + accept; the G3 form was 7 + 2s, its extra s
  // being the half reads) - applied to the column stream's own session
  // shape: a stride-640 walk over 2 KiB rows puts 4,3,3,3,3 stores per row per 16
  // (the run distribution), each run partitioned into GATHER_K-sized sessions, and
  // the effective band drops the scanout's share (18.9% worst measured). The 0.93
  // allowance is the gather sweep's: the model's turn constant prices
  // the bus turnaround alone while the merged writes start a capture stage later,
  // so the engine lands within a cycle of the model but not exactly on it.
  // The model counts CONTROLLER cycles, so its MB/s is at the controller's clock: clk_sys since
  // the split-clock removal (it was the 100 MHz clk_sdram, 23.66 MB/s at GATHER_K=4).
  localparam real CTRL_MHZ = SYS_MHZ;
  function real model_col_floor(input integer gk);
    real clk;
    integer ri, left, s, n;
    begin
      clk = 0.0;
      n = 0;
      for (ri = 0; ri < 5; ri = ri + 1) begin
        left = (ri == 0) ? 4 : 3;
        while (left > 0) begin
          s = (gk < left) ? gk : left;
          clk = clk + real'(7 + s);
          n = n + s;
          left = left - s;
        end
      end
      model_col_floor = (CTRL_MHZ / (clk / real'(n))) * (1.0 - 0.189) * 0.93;
    end
  endfunction

  // ==== CHECKS ====
  localparam integer BYTE_BUDGET_X10  = 250;   // 25.0 MB/s byte-span budget
  // The dword budget sits ABOVE the un-posted path's single-write ceiling (this
  // bench measures 44.04 MB/s on HEAD: one backend transaction per store, ~90 ns
  // each) and below the pair drain's (~8 B per ~95 ns, minus the scanout's share).
  localparam integer DWORD_BUDGET_X10 = 550;   // 55.0 MB/s: the 50/100 split-clock budget, REPORTED
  // THE FRAME NEED: 640x400 8bpp = 256,000 bytes per frame at 56.42 Hz.
  localparam real    FRAME_NEED_MBPS  = 14.44;
  localparam integer BYTE_BYTES   = 8192;
  localparam integer DWORD_WORDS  = 4096;
  localparam integer COHER_BYTES  = 64;        // the coherence line's first 64 bytes
  localparam integer COLUMN_BYTES = 256;       // 256 vertical-column byte stores (stride 640)

  real byte_mbps, dword_mbps, col_mbps;
  real col_floor;
  integer w0, w1, p1;
  integer k, j;
  reg [31:0] rd;
  integer drain_cycles;
  integer coher_bad, coher_first;

  initial begin
    @(negedge clk_sys);
    reset = 0; resetn = 1;
    repeat (4) @(posedge clk_sys);
    repeat (600 * SYS_MHZ) @(posedge clk_sys);   // 600 us: past the controller's 200 us JEDEC init

    // ---- MICRO: does a LONE partial (byte) store preserve the dword's other lanes? ----
    // The reference model: a byte store writes ONE byte (NP2kai's vramex is a byte array;
    // this core's planar path writes the same array the CPU writes). The packed path posts
    // the store and the controller has no DQM, so a byte store becomes a read-modify-write
    // over a 16-bit HALF - which must merge, not zero, the lanes it does not write.
    for (k = 0; k < 4; k = k + 1) begin
      cpu_store32(PEG_BASE + 32'h0007_0000 + 32'(k * 16), 32'h1122_3344, 4'hF);
      store_sync(PEG_BASE + 32'h0007_0000 + 32'(k * 16), 32'h0000_00E0, 4'h1);
      cpu_read32(PEG_BASE + 32'h0007_0000 + 32'(k * 16), rd);
      $display("MICRO byte-after-dword %0d: read %08x want 112233e0%s", k, rd,
               (rd === 32'h1122_33E0) ? "" : "   <-- CORRUPTED");
    end
    // ... and a byte store into an address that was never dword-written (zeros).
    store_sync(PEG_BASE + 32'h0007_1000, 32'h0000_00E0, 4'h1);
    cpu_read32(PEG_BASE + 32'h0007_1000, rd);
    $display("MICRO byte into zeros: read %08x want 000000e0%s", rd,
             (rd === 32'h0000_00E0) ? "" : "   <-- CORRUPTED");

    // ---- the background scanout: preload its 16 lines plus the coherence line ----
    for (k = 0; k < 17; k = k + 1) begin
      for (j = 0; j < 160; j = j + 1)
        cpu_store32(LINE_BASE + 32'(k * 640 + j * 4), line_dword(9'(j)), 4'hF);
    end
    s_valid = 1'b0;
    scan_enable = 1'b1;
    background_on = 1'b1;

    // ---- RAW: a read issued right behind a store must see the buffered bytes ----
    cpu_store32(BYTE_BASE - 32'd16, 32'h1122_3344, 4'hF);
    cpu_store32(BYTE_BASE - 32'd12, 32'h5566_7788, 4'hF);
    cpu_read32(BYTE_BASE - 32'd16, rd);
    if (rd !== 32'h1122_3344) begin
      $display("FAIL read-after-write: got %08x want 11223344", rd);
      errors = errors + 1;
    end
    cpu_read32(BYTE_BASE - 32'd12, rd);
    if (rd !== 32'h5566_7788) begin
      $display("FAIL read-after-write: got %08x want 55667788", rd);
      errors = errors + 1;
    end

    // ---- the byte-span stream ----
    w0 = wr_accepts;
    lat_max = 0;
    kap_beats = 0; kap_cycles = 0; kap_on = 1'b1;
    byte_stream(BYTE_BYTES, byte_mbps);
    kap_on = 1'b0;
    $display("MEASURED scanout keep-up under the byte stream: %0d beats, %0d lines' worth expected (%0d beats/line)",
             kap_beats, (kap_cycles / (LINE_CLK + 1)), (kap_beats * (LINE_CLK + 1)) / (kap_cycles == 0 ? 1 : kap_cycles));
    // The fetch must keep the raster fed with the store stream running: a starved scanout
    // is a held/duplicated line on the display. One line is 160 beats per LINE_CLK clk_sys;
    // the threshold is 4/5 of that (the window's arithmetic rounds down by a fraction of
    // a line). The measured figure is ~156-175.
    if ((kap_beats * (LINE_CLK + 1)) < (kap_cycles * 128)) begin
      $display("FAIL scanout keep-up: %0d beats per line (want >= 128) under the byte stream -- the fetch is starved",
               (kap_beats * (LINE_CLK + 1)) / (kap_cycles == 0 ? 1 : kap_cycles));
      errors = errors + 1;
    end
    w1 = wr_accepts;
    $display("MEASURED worst line fetch under the byte stream: %0d clk_sys (raster line %0d), %s",
             lat_max, LINE_CLK, (lat_max > LINE_CLK) ? "MISSES THE DEADLINE" : "inside the line");
    // The packed display is one line ahead: a fetch that does not finish inside its raster
    // line is a held (repeated) line. 0 means no line finished inside the window at all.
    if ((lat_max == 0) || (lat_max > LINE_CLK)) begin
      $display("FAIL line-fetch deadline: worst fetch %0d clk_sys of the %0d-clk_sys raster line", lat_max, LINE_CLK);
      errors = errors + 1;
    end
    $display("MEASURED byte stream: %.2f MB/s, %0d backend writes for %0d bytes",
             byte_mbps, w1 - w0, BYTE_BYTES);
    if ((byte_mbps * 10.0) < real'(BYTE_BUDGET_X10)) begin
      $display("FAIL byte rate %.2f MB/s under the %0d.%0d MB/s budget",
               byte_mbps, BYTE_BUDGET_X10 / 10, BYTE_BUDGET_X10 % 10);
      errors = errors + 1;
    end
    if ((w1 - w0) > ((BYTE_BYTES / 4) + 4)) begin
      $display("FAIL byte-combining: %0d backend writes for %0d bytes (want <= %0d)",
               w1 - w0, BYTE_BYTES, (BYTE_BYTES / 4) + 4);
      errors = errors + 1;
    end

    // ---- the dword stream ----
    w0 = wr_accepts;
    p1 = wr_pairs;
    lat_max = 0;
    kap_beats = 0; kap_cycles = 0; kap_on = 1'b1;
    dword_stream(DWORD_WORDS, dword_mbps);
    kap_on = 1'b0;
    $display("MEASURED scanout keep-up under the dword stream: %0d beats, %0d lines' worth expected (%0d beats/line)",
             kap_beats, (kap_cycles / (LINE_CLK + 1)), (kap_beats * (LINE_CLK + 1)) / (kap_cycles == 0 ? 1 : kap_cycles));
    if ((kap_beats * (LINE_CLK + 1)) < (kap_cycles * 128)) begin
      $display("FAIL scanout keep-up: %0d beats per line (want >= 128) under the dword stream -- the fetch is starved",
               (kap_beats * (LINE_CLK + 1)) / (kap_cycles == 0 ? 1 : kap_cycles));
      errors = errors + 1;
    end
    w1 = wr_accepts;
    $display("MEASURED worst line fetch under the dword stream: %0d clk_sys (raster line %0d), %s",
             lat_max, LINE_CLK, (lat_max > LINE_CLK) ? "MISSES THE DEADLINE" : "inside the line");
    if ((lat_max == 0) || (lat_max > LINE_CLK)) begin
      $display("FAIL line-fetch deadline: worst fetch %0d clk_sys of the %0d-clk_sys raster line", lat_max, LINE_CLK);
      errors = errors + 1;
    end
    $display("MEASURED dword stream: %.2f MB/s, %0d backend writes (%0d pairs) for %0d dwords",
             dword_mbps, w1 - w0, wr_pairs - p1, DWORD_WORDS);
    // The 55 MB/s budget was set against the 100 MHz split-clock controller's pair drain; with
    // the controller on clk_sys it is REPORTED (trade T36), and the
    // machine-derived floor - the packed frame's 14.44 MB/s - is what is asserted.
    $display("MEASURED dword stream against the old %0d.%0d MB/s split-clock budget: %s (reported, not asserted - trade T36)",
             DWORD_BUDGET_X10 / 10, DWORD_BUDGET_X10 % 10,
             ((dword_mbps * 10.0) < real'(DWORD_BUDGET_X10)) ? "BELOW" : "at or above");
    if (dword_mbps < FRAME_NEED_MBPS) begin
      $display("FAIL dword rate %.2f MB/s under the packed frame's %.2f MB/s need",
               dword_mbps, FRAME_NEED_MBPS);
      errors = errors + 1;
    end
    if ((wr_pairs - p1) < (DWORD_WORDS / 4)) begin
      $display("FAIL pair-drain: %0d pair writes for %0d dwords (want >= %0d)",
               wr_pairs - p1, DWORD_WORDS, DWORD_WORDS / 4);
      errors = errors + 1;
    end

    // ---- the column stream: DOOM's vertical-column store shape ----
    // THE FRAME NEED: 640x400 8bpp = 256,000 bytes per frame at 56.42 Hz = 14.44 MB/s.
    // A packed game that draws its
    // frame as vertical columns stores ONE byte lane per step at stride 640: the
    // stores cannot combine per dword, so before G3 every one paid the controller's
    // read-modify-write (5.8-6.7 MB/s measured here - the FAIL-FIRST) and one frame
    // took ~44 ms. The drain now groups same-row stores into GATHER sessions, and
    // the rate is ASSERTED at the rate model's own floor for this shape (at the controller's
    // clock) and at the frame need.
    w0 = wr_accepts;
    column_stream(COLUMN_BYTES, col_mbps);
    w1 = wr_accepts;
    col_floor = model_col_floor(GK);
    $display("MEASURED column stream (stride 640, lane 0): %.2f MB/s, %0d backend writes for %0d bytes; the packed frame needs 14.44 MB/s, so one 256,000-byte frame takes %.1f ms against a 17.7 ms frame",
             col_mbps, w1 - w0, COLUMN_BYTES, 256000.0 / (col_mbps * 1000.0));
    $display("MEASURED column floor from the rate model at GATHER_K=%0d: %.2f MB/s", GK, col_floor);
    if (col_mbps < col_floor) begin
      $display("FAIL column rate %.2f MB/s under the rate model's %.2f MB/s floor at GATHER_K=%0d",
               col_mbps, col_floor, GK);
      errors = errors + 1;
    end
    if (col_mbps < FRAME_NEED_MBPS) begin
      $display("FAIL column rate %.2f MB/s under the packed frame's %.2f MB/s need",
               col_mbps, FRAME_NEED_MBPS);
      errors = errors + 1;
    end

    // ---- read-back: the streams' bytes are byte-exact in SDRAM (dword-aligned
    // probes scattered through both stream regions) ----
    for (k = 0; k < 16; k = k + 1) begin
      cpu_read32(BYTE_BASE + 32'(k * 256), rd);
      if (rd !== pat_dword(BYTE_BASE + 32'(k * 256))) begin
        $display("FAIL byte-stream read-back at %08x: got %08x want %08x",
                 BYTE_BASE + 32'(k * 256), rd, pat_dword(BYTE_BASE + 32'(k * 256)));
        errors = errors + 1;
      end
    end
    for (k = 0; k < 16; k = k + 1) begin
      cpu_read32(DWORD_BASE + 32'(k * 257 * 4), rd);
      if (rd !== pat_dword(DWORD_BASE + 32'(k * 257 * 4))) begin
        $display("FAIL dword-stream read-back at %08x: got %08x want %08x",
                 DWORD_BASE + 32'(k * 257 * 4), rd, pat_dword(DWORD_BASE + 32'(k * 257 * 4)));
        errors = errors + 1;
      end
    end

    // ---- P2-6: dirty dwords never linger ----
    // (a) the store path reports empty within 2 us of the last accept;
    // (b) a scanout line fetched 4 us after stores that fill its first 64 bytes
    //     shows the NEW bytes (the horizontal-stripe class).
    background_on = 1'b0;
    drain_cycles = 0;
    for (k = 0; k < COHER_BYTES; k = k + 1)
      cpu_store32(LINE_BASE + 32'((14'(COHER_BASE) << 3) + 32'(k)),
                  {4{8'hE0 + 8'(k)}}, 4'h1 << k[1:0]);
    s_valid = 1'b0;               // or the held store would re-post past its accept
    while (s_busy && (drain_cycles < 2 * SYS_MHZ)) begin
      @(negedge clk_sys);
      drain_cycles = drain_cycles + 1;
    end
    $display("MEASURED store-path drain: %0d clk_sys after the last accept", drain_cycles);
    if (s_busy) begin
      $display("FAIL drain residency: still busy %0d clk_sys (2 us bound) after the last store",
               drain_cycles);
      errors = errors + 1;
    end
    repeat (4 * SYS_MHZ) @(posedge clk_sys);   // 4 us: the bounded staleness the scanout may see
    fetch_line(COHER_BASE);
    fetch_line(COHER_BASE);
    walk_line(1'b1);

    // ---- THE STORE-TO-SCANOUT VISIBILITY LEG (drain-before-scanout) ----
    // The store path is posted: a store's accept is the BUFFER's accept, and a CPU read
    // right behind it is held until the buffer empties (drain-before-read), so the CPU
    // always sees its own stores. THE SCANOUT IS A READER OF THE SAME ROUTE (the packed
    // fetch reads peg_base on the fourth requester). The reference model is one array both
    // sides touch - NP2kai's `vramex` is plain RAM, the display reads the byte the CPU just
    // wrote with no lag (vram/makegrex.c) - and this core's own planar path has the same
    // zero lag (its scanout reads the M10K array the CPU writes). So a store accepted at T,
    // with a line fetch presented after T, MUST show the new byte.
    //
    // The shape that exposes the gap is the PARTIAL TAIL: a full-dword store drains as soon
    // as the backend is free, but a partial dword is HELD for its combining window
    // (HOLD_CYCLES, 1 us) - longer than a line fetch takes to reach it. So: fill the whole
    // line, WAIT for it to be fully visible (a CPU read-back's own guarantee), then store
    // a few single-byte stores and fetch the line at once. The fetched line must
    // be the settled line plus that one byte: any byte that is not is a byte the display
    // cannot see even though the CPU already can.
    background_on = 1'b0;
    for (k = 0; k < 160; k = k + 1)
      store_sync(LINE_BASE + 32'(((14'(COHER_BASE) + 14'd80) << 3) + 32'(k * 4)),
                 line_dword(9'(k)), 4'hF);
    // The settled state: the buffer is empty and the line is in SDRAM (probe it).
    while (s_busy && (drain_cycles < 4 * SYS_MHZ)) begin
      @(negedge clk_sys);
      drain_cycles = drain_cycles + 1;
    end
    cpu_read32(LINE_BASE + 32'(((14'(COHER_BASE) + 14'd80) << 3)), rd);
    if (rd !== line_dword(9'd0)) begin
      $display("FAIL store-to-scanout setup: the line's first dword reads %08x, want %08x",
               rd, line_dword(9'd0));
      errors = errors + 1;
    end
    // ---- THE RESIDENCY BOUND (a saturated same-dword store stream) ----
    // The buffer's own rule 5: "No dirty dword is ever held past eviction or across a
    // wait: worst-case residency is one hold window plus one drain transaction". A byte
    // stream that keeps hitting the SAME dword is the one shape that can defeat it: every
    // store COMBINES into the tail entry (rule 2), the entry stays PARTIAL (two of four
    // bytes written), so it is held for the combining window - and the window must age
    // from the tail's own allocation. An earlier form aged the tail only on cycles with
    // no accept, so a saturated stream (one store per clk_sys, no idle cycle) froze the
    // window open and the dword was held for as long as the stream lasted.
    //
    // The stream is driven here synchronously (one store per clk_sys, no task: a task's
    // inter-store gap is the idle cycle the old rule needed), and the property is
    // checked where it is observable - at the BACKEND: RES_CLK cycles is six hold windows
    // (HOLD_CYCLES = HOLD_CLK), so the buffer must hand the backend at least a few writes. The
    // scanout cannot see the difference (its own fetch is slower than the window - the
    // leg below measures that), so the port is the right instrument.
    w0 = wr_accepts;
    for (k = 0; k < RES_CLK; k = k + 1) begin
      @(negedge clk_sys);
      s_addr = LINE_BASE + 32'(((14'(COHER_BASE) + 14'd80) << 3));
      s_din  = 32'hE0E0_E0E0;
      s_be   = (k[0] ? 4'h2 : 4'h1);
      s_write = 1'b1;
      s_valid = 1'b1;
    end
    s_valid = 1'b0;
    w1 = wr_accepts;
    $display("MEASURED saturated same-dword stream: %0d backend writes in %0d clk_sys (bound wants >= %0d)",
             w1 - w0, RES_CLK, (RES_CLK / HOLD_CLK) - 2);
    if ((w1 - w0) < ((RES_CLK / HOLD_CLK) - 2)) begin
      $display("FAIL residency bound: a saturated same-dword stream held its entry for %0d clk_sys (%0d writes, want >= %0d) -- the combining window is not a bound",
               (w1 - w0 == 0) ? RES_CLK : 0, w1 - w0, (RES_CLK / HOLD_CLK) - 2);
      errors = errors + 1;
    end
    // The dword is the CPU's now, not the display's problem: the stream's last bytes are
    // settled by the fetch below.
    fetch_line(14'(COHER_BASE) + 14'd80);
    fetch_line(14'(COHER_BASE) + 14'd80);
    fetch_line(14'(COHER_BASE) + 14'd80);
    fetch_line(14'(COHER_BASE) + 14'd80);
    walk_line_count(2, coher_bad, coher_first);
    $display("MEASURED store-to-scanout visibility: %0d stale byte(s) of the line, first at %0d",
             coher_bad, coher_first);
    if (coher_bad != 0) begin
      $display("FAIL store-to-scanout visibility: the stores were ACCEPTED before the line fetch yet %0d byte(s) are invisible to it (first at %0d) -- the scanout reads behind the posted store buffer",
               coher_bad, coher_first);
      errors = errors + 1;
    end

    // ---- THE FROZEN-PRESENTATION LEG (the pair-drain payload freeze) ----
    // The buffer's contract: "once presented a request's payload -- source, pair
    // decision and all -- is frozen until its ack". The pair drain is the shape that
    // broke it: with count == 2 the pair's SECOND word IS the tail entry, and a store
    // to that dword merged into the presented payload (mem_din_hi moved under the
    // bridge) and was then LOST when the drain popped the entry. The rework commits
    // and freezes the presented entries at their first presentation cycle (a store to
    // a committed dword allocates its own entry and drains after), so: hold the
    // scripted accept, land a store on the pair's second dword, and every accepted
    // store's bytes must still reach the backend - the pair's payload unmoved, the
    // store's byte in a later request.
    // Two adjacent FULL dwords present as the pair drain.
    fz_store(FZ_X, 32'h1122_3344, 4'hF);
    fz_store(FZ_X + 32'd4, 32'h5566_7788, 4'hF);
    k = 0;
    while (!(fz_mvalid && !fz_mgath && (fz_mburst == 8'd2)) && (k < 2000)) begin
      @(negedge clk_sys); k = k + 1;
    end
    if (!(fz_mvalid && !fz_mgath && (fz_mburst == 8'd2))) begin
      $display("FAIL pair-drain freeze: two adjacent full dwords never presented as the pair drain");
      errors = errors + 1;
    end
    // The presented pair, recorded with its accept held off.
    begin : fz_freeze
      reg [31:0] pz_a, pz_d, pz_dhi;
      reg  [3:0] pz_be;
      pz_a = fz_maddr; pz_d = fz_mdin; pz_dhi = fz_mdin_hi; pz_be = fz_mbe;
      // A store lands on the pair's SECOND dword while it is presented.
      fz_store(FZ_X + 32'd4, 32'h0000_00EE, 4'h1);
      if ((fz_maddr !== pz_a) || (fz_mdin !== pz_d) || (fz_mdin_hi !== pz_dhi) ||
          (fz_mbe !== pz_be) || (fz_mburst !== 8'd2)) begin
        $display("FAIL pair-drain freeze: the pair drain's payload moved under a store to its second word (din_hi %08x -> %08x)",
                 pz_dhi, fz_mdin_hi);
        errors = errors + 1;
      end
      // Accept the pair; the store's bytes must then reach the backend in a
      // request of their own (they merged into no presented entry).
      @(negedge clk_sys); fz_mready = 1'b1;
      @(negedge clk_sys); fz_mready = 1'b0;
      k = 0;
      while (!(fz_mvalid && fz_mgath && (fz_mburst == 8'd1)) && (k < 2000)) begin
        @(negedge clk_sys); k = k + 1;
      end
      if (!(fz_mvalid && fz_mgath && (fz_mburst == 8'd1) &&
            (fz_maddr === (FZ_X + 32'd4)) && (fz_mdin === 32'h0000_00EE) &&
            (fz_mbe === 4'h1))) begin
        $display("FAIL pair-drain freeze: the store to the pair's second dword never reached the backend on its own (got addr %08x din %08x be %x gath %b burst %0d)",
                 fz_maddr, fz_mdin, fz_mbe, fz_mgath, fz_mburst);
        errors = errors + 1;
      end
      // Drain the rest and leave the harness empty.
      k = 0;
      while (fz_busy && (k < 2000)) begin
        if (fz_mvalid) begin
          @(negedge clk_sys); fz_mready = 1'b1;
          @(negedge clk_sys); fz_mready = 1'b0;
        end else @(negedge clk_sys);
        k = k + 1;
      end
      if (fz_busy) begin
        $display("FAIL pair-drain freeze: the freeze harness never drained");
        errors = errors + 1;
      end
    end
    $display("MEASURED frozen presentation: pair payload unmoved and the store's bytes reached the backend");

    // ---- THE FULL-BUFFER COMBINE LEG (the in_ready contract) ----
    // in_ready is the CPU's memory ready, so it is built from `count < DEPTH` alone and
    // never from the combine match (the match cone
    // cost the base fit its clk_sys closure). The one visible consequence: a store that
    // could only COMBINE into a FULL buffer waits for one drain, then combines - its bytes
    // merge into the held entry (8 backend writes, not 9) exactly as before.
    // FAIL-FIRST: the pre-change buffer accepted that store at once (in_ready = can_combine).
    begin : fz_full
      integer fi, nwr, hit5;
      reg [31:0] fb;
      fb = FZ_X + 32'h0000_4000;
      // Eight partial entries, one per 2 KiB SDRAM row (no gather group, no pair), with
      // the backend accept held off so the buffer stays full.
      for (fi = 0; fi < 8; fi = fi + 1)
        fz_store(fb + 32'h800 * fi, 32'h0000_00A0 + fi, 4'h1);
      // A store that matches entry 5 (not the presented head) with a DIFFERENT lane.
      @(negedge clk_sys);
      fz_addr = fb + 32'h800 * 5; fz_din = 32'h0000_5B00; fz_be = 4'h2;
      fz_write = 1'b1; fz_valid = 1'b1;
      repeat (20) begin
        #1;
        if (fz_ready) begin
          $display("FAIL full-buffer combine: a store was accepted into a FULL buffer before any drain (in_ready must be count < DEPTH only)");
          errors = errors + 1;
        end
        @(negedge clk_sys);
      end
      // One drain frees a slot; the waiting store is then accepted (and combines).
      nwr = 0; hit5 = 0;
      fi = 0;
      while (fz_valid && (fi < 2000)) begin
        if (fz_mvalid && !fz_mready) begin
          fz_mready = 1'b1;
          nwr = nwr + 1;
          if ((fz_maddr === fb + 32'h800 * 5) && (fz_mdin[15:0] === 16'h5BA5) &&
              (fz_mbe === 4'h3)) hit5 = hit5 + 1;
        end else fz_mready = 1'b0;
        #1;
        if (fz_ready) begin @(negedge clk_sys); fz_valid = 1'b0; fz_mready = 1'b0; end
        else @(negedge clk_sys);
        fi = fi + 1;
      end
      if (fz_valid) begin
        $display("FAIL full-buffer combine: the waiting store was never accepted after a drain");
        errors = errors + 1;
        fz_valid = 1'b0;
      end
      // Drain the rest, recording every write.
      fi = 0;
      while (fz_busy && (fi < 4000)) begin
        if (fz_mvalid && !fz_mready) begin
          fz_mready = 1'b1;
          nwr = nwr + 1;
          if ((fz_maddr === fb + 32'h800 * 5) && (fz_mdin[15:0] === 16'h5BA5) &&
              (fz_mbe === 4'h3)) hit5 = hit5 + 1;
        end else fz_mready = 1'b0;
        @(negedge clk_sys);
        fi = fi + 1;
      end
      fz_mready = 1'b0;
      if (fz_busy || (nwr != 8) || (hit5 != 1)) begin
        $display("FAIL full-buffer combine: want 8 backend writes with entry 5 merged to 5BA5/be 3, got %0d writes, %0d merged hits%s",
                 nwr, hit5, fz_busy ? " (never drained)" : "");
        errors = errors + 1;
      end else
        $display("MEASURED full-buffer combine: store waited for one drain, then merged (8 writes, entry 5 = 5BA5)");
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PEGC_STORE_RATE: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_PEGC_STORE_RATE: FAIL (%0d errors)", errors);
  end

endmodule

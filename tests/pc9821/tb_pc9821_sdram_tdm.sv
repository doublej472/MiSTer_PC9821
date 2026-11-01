`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The time-sliced SDRAM schedule holds at 100 MHz: with a saturating z486 cache-line stream on requester 0 (4-dword read bursts and single-dword writes), the font/ROM line on requester 1, the 86-PCM on requester 2, and the GVRAM scanout's 80-dword line fetch on requester 3, the worst scanout line completes inside the 2014 clk_sys budget, the CPU sustains at least its measured 40 MB/s, and the round-robin arbiter gives the scanout a bounded slot (no more than three other accepts between its own) where the fixed priority that stood there could not.
//
// ---- the bench's own account of every number and where it comes from ----
// This is the Stage 1 gate of the TDM schedule study. That study DERIVED the schedule from the
// RTL's own constants and the machine's measured bandwidth and said so: nothing had been built or
// run. This bench is that run. It drives the REAL controller (src/memory/sdram.v) at 100 MHz,
// which is the clock the arithmetic says the schedule needs -- at 50 MHz a 4-way rotation leaves
// the scanout under 5%. What follows is the provenance of each load-bearing number.
//
//  * THE BUDGET: 2014 clk_sys CYCLES PER RASTER LINE. PROVEN from the raster constants
//    (src/pc9821/video/pc9821_gdc_text.sv: VTOTAL 440, 56.42 Hz) -> the line rate is
//    56.42 * 440 = 24,825 Hz and the line time is 40.28 us = 2014 clk_sys cycles at 50 MHz.
//
//  * THE SCANOUT'S SHAPE: 80 FOUR-PLANE DWORDS PER LINE, PACED >= 8 clk_sys APART. PROVEN from
//    pc9821_gvram.sv: `LINE_COLS = 80`, and the fetch FSM loads `scan_pace <= 7` on each issue
//    so a line's 80 requests are issued no faster than one per 8 clk_sys. The bench uses the
//    same 16 bench-cycle (8 clk_sys) pace, so the scanout is not allowed to demand more than
//    the machine's own fetch FSM would.
//
//  * THE CPU'S SHAPE: 4-DWORD READ BURSTS AND SINGLE-DWORD WRITES. A z486 L1 line fill asks for
//    a 4-dword burst (burst_cnt = 4, split_sdram_backend's own contract); a write is one 32-bit
//    word because this controller has no burst write. The stream is SATURATING: valid stays high,
//    so the CPU is always a pending request and the arbiter is never idle because of it.
//
//  * THE OTHER TWO ARE AT THEIR MEASURED RATES, not saturating, because that is what they are:
//    the font fetches 40 dwords a line (~4 MB/s) and the 86-PCM one dword per 44.1 kHz frame
//    (~0.2 MB/s), so neither is a bandwidth competitor.
//
//  * WHY 100 MHz AND NOT 50: sdram.v's own timing table has T_RCD = 2 there, so a single-dword
//    read is a handful of cycles; at 50 MHz the same rotation spans twice as many clk_sys cycles
//    and does not fit the line budget. The bench runs at 100 MHz for exactly that reason.
//    Since the 2026-10-13 CAS cutover (two DE10-Nano boards: CL2 at 100 MHz failed on hardware)
//    sdram.v runs CL3 at 100 MHz, one cycle more per read, and the schedule still holds with
//    room: worst line 935 of 2014 clk_sys and 56.1 MB/s CPU (849 and 61.8 MB/s under the old
//    CL2), so the bench keeps its 100 MHz grid and its model follows the controller to CL3.
//
//  * WHAT THIS DOES NOT PROVE, stated so nobody over-reads it: this bench runs the controller and
//    its four requesters in ONE clock domain. The built design has the consumers on clk_sys (50
//    MHz); clocking the controller at 100 MHz also needs a request/response crossing between the
//    two domains, which is a real cost of this schedule and is OUT of this bench.

module tb_pc9821_sdram_tdm;
  // The controller runs at 100 MHz. FREQ is a PARAMETER, so the timing table follows it.
  localparam integer FREQ = 100_000_000;
  localparam integer CYCLE_NS = 10;                 // 1/100MHz
  localparam integer CAS = 3;                        // CL3 at 100 MHz and up (sdram.v CAS_I, the 2026-10-13 hardware cutover)
  localparam integer LINE_COLS = 80;
  // The raster line budget is 2014 clk_sys (50 MHz) cycles; the bench's grid is 100 MHz, so the
  // same wall-clock budget is twice as many bench cycles.
  localparam integer LINE_BUDGET_SYS = 2014;
  localparam integer LINE_BUDGET = LINE_BUDGET_SYS * 2;   // 4028 bench cycles
  localparam integer CPU_BURST = 4;                  // a cache line
  // The fetch FSM's pace is ">= 8 clk_sys apart"; 16 bench cycles is the same 8 clk_sys at the
  // bench's doubled grid.
  localparam integer SCAN_PACE = 15;                 // reload: 16-cycle period
  localparam integer FONT_GAP = 100;                 // ~40 dwords/line at the real font rate
  localparam integer PCM_GAP = 2268;                 // one 44.1 kHz frame every 2268 cycles
  localparam integer WARMUP_LINES = 20;
  localparam integer MEAS_LINES = 200;
  localparam integer CPU_MIN_MBPS_NUM = 40;          // the measured requirement

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg resetn = 0;
  // Held low until the controller leaves its ~200us init, so no requester's clock starts before
  // the controller can answer. Without it the first line's fetch absorbs the whole init wait and
  // the worst-case number is a measurement artefact.
  reg run = 0;

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ==== DUT ====
  wire        busy;
  reg  [1:0]  sdram_size = 2'd2;                     // 2 = 64MB (the DE10 default shape)

  reg         cpu_valid = 0, cpu_wr = 0;
  reg  [26:0] cpu_addr = 0;
  reg  [31:0] cpu_din = 0;
  reg   [3:0] cpu_be = 4'hF;
  reg   [3:0] cpu_burst = CPU_BURST;
  wire        cpu_ready;
  wire [31:0] cpu_dout;
  wire        cpu_resp_valid, cpu_burst_done;

  reg         font_valid = 0, font_wr = 0;
  reg  [26:0] font_addr = 0;
  reg  [31:0] font_din = 0;
  reg   [3:0] font_be = 4'hF;
  reg   [3:0] font_burst = 4'd1;
  wire        font_ready;
  wire [31:0] font_dout;
  wire        font_resp_valid, font_burst_done;

  reg         pcm_valid = 0, pcm_wr = 0;
  reg  [26:0] pcm_addr = 0;
  reg  [31:0] pcm_din = 0;
  reg   [3:0] pcm_be = 4'hF;
  reg   [3:0] pcm_burst = 4'd1;
  wire        pcm_ready;
  wire [31:0] pcm_dout;
  wire        pcm_resp_valid, pcm_burst_done;

  reg         scan_valid = 0, scan_wr = 0;
  reg  [26:0] scan_addr = 0;
  reg  [31:0] scan_din = 0;
  reg   [3:0] scan_be = 4'hF;
  reg   [3:0] scan_burst = 4'd1;
  wire        scan_ready;
  wire [31:0] scan_dout;
  wire        scan_resp_valid, scan_burst_done;

  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire [1:0]  SDRAM_BA;
  wire [1:0]  SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS, CKE;

  // ADQM = 0 (the default): a partial store is a read-modify-write, the same configuration the
  // sdram bench exercises.
  sdram #(
      .FREQ(FREQ),
      .FAST_GRADE(1'b1)
  ) dut (
      .clk(clk), .resetn(resetn), .nce(1'b0), .refresh_allowed(1'b1),
      .busy(busy), .sdram_size(sdram_size),
      .valid0(cpu_valid), .ready0(cpu_ready), .wr0(cpu_wr), .addr0(cpu_addr),
      .din0(cpu_din),
      .din0_hi(32'd0), .dout0(cpu_dout), .resp_valid0(cpu_resp_valid),
      .be0(cpu_be), .burst_cnt0(cpu_burst), .burst_done0(cpu_burst_done),
      .valid1(font_valid), .ready1(font_ready), .wr1(font_wr), .addr1(font_addr),
      .din1(font_din), .dout1(font_dout), .resp_valid1(font_resp_valid),
      .be1(font_be), .burst_cnt1(font_burst), .burst_done1(font_burst_done),
      .valid2(pcm_valid), .ready2(pcm_ready), .wr2(pcm_wr), .addr2(pcm_addr),
      .din2(pcm_din), .dout2(pcm_dout), .resp_valid2(pcm_resp_valid),
      .be2(pcm_be), .burst_cnt2(pcm_burst), .burst_done2(pcm_burst_done),
      .valid3(scan_valid), .ready3(scan_ready), .wr3(scan_wr), .addr3(scan_addr),
      .din3(scan_din), .dout3(scan_dout), .resp_valid3(scan_resp_valid),
      .be3(scan_be), .burst_cnt3(scan_burst), .burst_done3(scan_burst_done),
      .SDRAM_DQ(DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQM(SDRAM_DQM),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nCS(nCS),
      .SDRAM_CKE(CKE)
  );

  // The AUTO REFRESH gap is held to tREFI = 64 ms / 8192 rows (the AS4C32M16SB datasheet's 8192
  // refreshes per 64 ms) on the pins, under this bench's saturating four-port load.
  sdram_chip_model #(.CAS(CAS), .FREQ_HZ(FREQ), .GRADE(6), .REFRESH_INTERVAL(FREQ / 128_000)) chip (
      .clk(clk), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // ==== CHECKS ====
  integer errors = 0;
  task automatic fail(input [1023:0] what);
    begin
      errors = errors + 1;
      $display("FAIL sdram_tdm: %0s (cycle %0d)", what, cyc);
    end
  endtask

  // ==== THE ARBITER'S PER-PORT RESPONSE CONTRACT ====
  // The round-robin replaces fixed priority, so the guarantee it must keep is per requester:
  // each accepted 1-dword read produces EXACTLY ONE resp_valid on THAT port, and the response
  // is never misrouted. `sat_all` holds all four valid together for a whole window - the
  // arbiter's worst-case rotation load - and the per-port accept/response/burst_done counts
  // must match. `sat_solo` then leaves only port 2 asking: an idle slot is skipped, not held,
  // so a lone requester must be served immediately rather than starved behind three silent ones.
  // `sat_settle` forces every port quiescent for 64 cycles before each window, so a request
  // still in flight from the prior phase cannot be counted against the new window's accepts.
  reg     sat_all   = 1'b0;
  reg     sat_solo  = 1'b0;
  reg     sat_drain = 1'b0;
  reg  [6:0] sat_settle = 7'd64;
  wire    sat_run  = sat_all  && (sat_settle == 7'd0);
  wire    solo_run = sat_solo && (sat_settle == 7'd0);
  integer sat_acc  [0:3];
  integer sat_resp [0:3];
  integer sat_bdone[0:3];
  integer solo_accepts = 0, solo_gap = 0, solo_worst_gap = 0;

  always @(posedge clk) begin
    if (sat_all || sat_solo) begin
      if (sat_settle != 7'd0) sat_settle <= sat_settle - 7'd1;
    end else begin
      sat_settle <= 7'd64;
    end
  end

  always @(posedge clk) begin
    if (sat_run) begin
      if (cpu_ready)       sat_acc[0]   <= sat_acc[0]   + 1;
      if (cpu_resp_valid)  sat_resp[0]  <= sat_resp[0]  + 1;
      if (cpu_burst_done)  sat_bdone[0] <= sat_bdone[0] + 1;
      if (font_ready)      sat_acc[1]   <= sat_acc[1]   + 1;
      if (font_resp_valid) sat_resp[1]  <= sat_resp[1]  + 1;
      if (font_burst_done) sat_bdone[1] <= sat_bdone[1] + 1;
      if (pcm_ready)       sat_acc[2]   <= sat_acc[2]   + 1;
      if (pcm_resp_valid)  sat_resp[2]  <= sat_resp[2]  + 1;
      if (pcm_burst_done)  sat_bdone[2] <= sat_bdone[2] + 1;
      if (scan_ready)      sat_acc[3]   <= sat_acc[3]   + 1;
      if (scan_resp_valid) sat_resp[3]  <= sat_resp[3]  + 1;
      if (scan_burst_done) sat_bdone[3] <= sat_bdone[3] + 1;
    end
  end

  always @(posedge clk) begin
    if (resetn && solo_run) begin
      solo_gap <= solo_gap + 1;
      if (pcm_ready) begin
        solo_accepts <= solo_accepts + 1;
        if (solo_gap > solo_worst_gap) solo_worst_gap <= solo_gap;
        solo_gap <= 0;
      end
    end
  end

  // The "right requester" half of the contract, which a per-port COUNT cannot see: under a
  // fair rotation all four ports accept equally, so a constant misroute leaves the counts
  // matching. The controller serves one request at a time, so no accept can occur between an
  // accept and its responses; every response must therefore name the port whose request was
  // last accepted, and exactly one port may answer in a cycle.
  reg [1:0]  arb_last_acc = 2'd0;
  reg        arb_seen     = 1'b0;
  integer    misroute_violations   = 0;
  integer    multi_resp_violations = 0;
  wire [3:0] any_ready = {scan_ready, pcm_ready, font_ready, cpu_ready};
  wire [3:0] resp_vec  = {scan_resp_valid, pcm_resp_valid, font_resp_valid, cpu_resp_valid};
  wire       any_resp  = |resp_vec;
  wire [1:0] acc_port  = cpu_ready ? 2'd0 : font_ready ? 2'd1 : pcm_ready ? 2'd2 : 2'd3;
  wire [1:0] resp_port = cpu_resp_valid ? 2'd0 : font_resp_valid ? 2'd1 :
                         pcm_resp_valid ? 2'd2 : 2'd3;
  always @(posedge clk) begin
    if (resetn) begin
      if (any_resp) begin
        if (!arb_seen || (resp_port != arb_last_acc))
          misroute_violations <= misroute_violations + 1;
        if (resp_vec != (4'b0001 << resp_port))
          multi_resp_violations <= multi_resp_violations + 1;
      end
      if (|any_ready) begin
        arb_last_acc <= acc_port;
        arb_seen     <= 1'b1;
      end
    end
  end

  // ---- requester 0: the CPU, SATURATING. valid stays high; the controller accepts it whenever
  // it returns to IDLE, so it is always a pending request. Three read bursts then one write, the
  // read-heavy shape a cache-line workload has: a read request moves CPU_BURST dwords, a write
  // moves one (this controller has no burst write).
  integer cpu_accepts = 0;
  integer cpu_dwords  = 0;
  reg [1:0] cpu_phase = 0;
  always @(posedge clk) begin
    if (!resetn) begin
      cpu_valid <= 1'b0;
      cpu_phase <= 2'd0;
    end else if (sat_all || sat_solo) begin
      // arbiter-contract window: settle, then a saturating stream of 1-dword reads
      cpu_valid <= sat_run && !sat_drain;
      cpu_wr    <= 1'b0;
      cpu_burst <= 4'd1;
      if (cpu_ready) cpu_addr <= cpu_addr + 27'd4;
    end else begin
      cpu_valid <= run;
      if (cpu_ready) begin
        cpu_accepts <= cpu_accepts + 1;
        cpu_dwords  <= cpu_dwords + (cpu_wr ? 1 : CPU_BURST);
        cpu_addr    <= cpu_addr + 27'd64;                 // a fresh line each request
        cpu_phase   <= cpu_phase + 2'd1;
        cpu_wr      <= (cpu_phase == 2'd3);               // every 4th is a write
      end
    end
  end

  // ---- requester 1: the font/ROM line, one dword every FONT_GAP cycles.
  integer font_accepts = 0;
  reg [15:0] font_gap = 0;
  always @(posedge clk) begin
    if (!resetn) begin
      font_valid <= 1'b0;
      font_gap   <= 16'd0;
    end else if (sat_all || sat_solo) begin
      font_valid <= sat_run && !sat_drain;
      font_wr    <= 1'b0;
      font_burst <= 4'd1;
      if (font_ready) font_addr <= font_addr + 27'd4;
    end else begin
      if (font_ready) begin
        font_valid   <= 1'b0;
        font_accepts <= font_accepts + 1;
      end
      if (font_gap == 0 && !font_valid && run) begin
        font_valid <= 1'b1;
        font_gap   <= FONT_GAP[15:0];
        font_addr  <= font_addr + 27'd4;
      end else if (font_gap != 0) begin
        font_gap <= font_gap - 16'd1;
      end
    end
  end

  // ---- requester 2: the 86-PCM, one dword per 44.1 kHz frame.
  integer pcm_accepts = 0;
  reg [15:0] pcm_gap = 0;
  always @(posedge clk) begin
    if (!resetn) begin
      pcm_valid <= 1'b0;
      pcm_gap   <= 16'd0;
    end else if (sat_all || sat_solo) begin
      pcm_valid <= (sat_run || solo_run) && !sat_drain;   // port 2 is the SOLO requester
      pcm_wr    <= 1'b0;
      pcm_burst <= 4'd1;
      if (pcm_ready) pcm_addr <= pcm_addr + 27'd4;
    end else begin
      if (pcm_ready) begin
        pcm_valid   <= 1'b0;
        pcm_accepts <= pcm_accepts + 1;
      end
      if (pcm_gap == 0 && !pcm_valid && run) begin
        pcm_valid <= 1'b1;
        pcm_gap   <= PCM_GAP[15:0];
        pcm_wr    <= ~pcm_wr;
        pcm_addr  <= pcm_addr + 27'd4;
      end else if (pcm_gap != 0) begin
        pcm_gap <= pcm_gap - 16'd1;
      end
    end
  end

  // ---- requester 3: the GVRAM scanout's line fetch, modelled on pc9821_gvram.sv's FSM.
  // One 80-dword line, one request per SCAN_PACE+1 cycles, restarted the cycle after the last
  // column's response so the scanout is under continuous load -- the worst case for its own
  // deadline. `scan_outstanding` holds the next issue until the previous dword's response has
  // been recorded, so scan_col_q always names the response's column (the real FSM can overlap
  // them because its pace exceeds the read latency, and so can this: the pace is 16 cycles and a
  // dword's latency is under 10).
  reg [7:0]  scan_col = 0;
  reg [7:0]  scan_col_q = 0;
  reg [3:0]  scan_pace = 0;
  reg        scan_line_active = 0;
  reg        scan_outstanding = 0;
  integer    scan_start_cyc = 0;
  integer    worst_line = 0;
  integer    lines_done = 0;
  integer    scan_accepts = 0;
  always @(posedge clk) begin
    if (!resetn) begin
      scan_valid       <= 1'b0;
      scan_col         <= 8'd0;
      scan_col_q       <= 8'd0;
      scan_pace        <= 4'd0;
      scan_line_active <= 1'b0;
      scan_outstanding <= 1'b0;
    end else if (sat_all || sat_solo) begin
      scan_valid <= sat_run && !sat_drain;
      scan_wr    <= 1'b0;
      scan_burst <= 4'd1;
      if (scan_ready) scan_addr <= scan_addr + 27'd4;
    end else begin
      if (scan_ready) begin
        scan_valid   <= 1'b0;
        scan_accepts <= scan_accepts + 1;
      end

      if (!scan_line_active) begin
        scan_line_active <= run;
        scan_col         <= 8'd0;
        scan_pace        <= 4'd0;
        scan_start_cyc   <= cyc;
      end else if ((scan_col != LINE_COLS) && (scan_pace == 4'd0) && !scan_valid && !scan_outstanding) begin
        scan_valid       <= 1'b1;
        scan_col_q       <= scan_col;
        scan_outstanding <= 1'b1;
        scan_pace        <= SCAN_PACE[3:0];
        scan_col         <= scan_col + 8'd1;
      end else if (scan_pace != 4'd0) begin
        scan_pace <= scan_pace - 4'd1;
      end

      if (scan_resp_valid) begin
        scan_outstanding <= 1'b0;
        if (scan_col_q == LINE_COLS - 8'd1) begin
          if ((cyc - scan_start_cyc) > worst_line) worst_line <= cyc - scan_start_cyc;
          lines_done       <= lines_done + 1;
          scan_line_active <= 1'b0;
        end
      end
    end
  end

  // ---- THE BOUNDED-SLOT PROPERTY, checked rather than asserted by prose: while the scanout holds
  // its request valid, at most THREE accepts of the other requesters may pass before its own. That
  // is the whole difference between a rotation and the fixed priority that stood here -- a fixed
  // priority can leave a low-priority requester waiting through unlimited accepts. Refresh is not
  // an accept and does not count.
  integer scan_wait_accepts = 0;
  integer worst_scan_slots  = 0;
  integer slot_violations   = 0;
  always @(posedge clk) begin
    if (resetn) begin
      if (scan_valid && !scan_ready) begin
        if (cpu_ready || font_ready || pcm_ready)
          scan_wait_accepts <= scan_wait_accepts + 1;
      end
      if (scan_ready) begin
        if (scan_wait_accepts > worst_scan_slots) worst_scan_slots <= scan_wait_accepts;
        if (scan_wait_accepts > 3) slot_violations <= slot_violations + 1;
        scan_wait_accepts <= 0;
      end
    end
  end

  real    cpu_mbps;
  integer cpu_dwords0, cyc0, cpu_dwords1, cyc1;
  integer guard;

  initial begin
    repeat (8) @(posedge clk);
    resetn = 1;

    guard = 0;
    while (busy && guard < 40000) begin
      @(posedge clk);
      guard = guard + 1;
    end
    if (busy) fail("the controller never left init");
    run = 1;

    // Warm up so the measurement window is steady state, not the first line after reset.
    guard = 0;
    while ((lines_done < WARMUP_LINES) && (guard < 4_000_000)) begin
      @(posedge clk);
      guard = guard + 1;
    end
    if (lines_done < WARMUP_LINES) fail("the scanout did not complete its warm-up lines");

    cpu_dwords0 = cpu_dwords;
    cyc0        = cyc;

    guard = 0;
    while ((lines_done < WARMUP_LINES + MEAS_LINES) && (guard < 40_000_000)) begin
      @(posedge clk);
      guard = guard + 1;
    end
    if (lines_done < WARMUP_LINES + MEAS_LINES)
      fail("the scanout did not complete the measurement lines");

    cpu_dwords1 = cpu_dwords;
    cyc1        = cyc;

    if (cyc1 == cyc0)
      cpu_mbps = 0.0;
    else
      cpu_mbps = (cpu_dwords1 - cpu_dwords0) * 4.0 * 100.0 / (cyc1 - cyc0);

    // ---- REPORT: the two numbers Stage 1 exists to produce ----
    $display("NOTE sdram_tdm: %0d lines measured; worst line fetch %0d bench cycles = %0d clk_sys (budget %0d clk_sys, %0d bench cycles)",
             MEAS_LINES, worst_line, worst_line / 2, LINE_BUDGET_SYS, LINE_BUDGET);
    $display("NOTE sdram_tdm: CPU sustained %0.1f MB/s over %0d cycles (%0d dwords); worst scanout slot wait %0d other accept(s)",
             cpu_mbps, cyc1 - cyc0, cpu_dwords1 - cpu_dwords0, worst_scan_slots);
    $display("NOTE sdram_tdm: accepts per requester: cpu=%0d font=%0d pcm=%0d scan=%0d",
             cpu_accepts, font_accepts, pcm_accepts, scan_accepts);

    // ---- THE GATE: this is the verdict the schedule study asked for ----
    if (worst_line > LINE_BUDGET)
      fail("the worst scanout line fetch EXCEEDED the 2014 clk_sys line budget -- the schedule does not hold");
    if (cpu_mbps < CPU_MIN_MBPS_NUM)
      fail("the CPU fell below its measured 40 MB/s -- the schedule does not hold");
    if (slot_violations != 0)
      fail("the scanout waited through more than three other accepts -- the arbiter is not a bounded rotation");
    if (worst_line == 0)
      fail("no scanout line completed: the measurement is vacuous");

    // ---- THE ARBITER'S PER-PORT RESPONSE CONTRACT. All four requesters saturate with 1-dword
    // reads at once and every port's response count must equal its accept count, so a dropped
    // or misrouted resp_valid fails here; then port 2 asks alone and must be served promptly.
    for (integer p = 0; p < 4; p = p + 1) begin
      sat_acc[p] = 0; sat_resp[p] = 0; sat_bdone[p] = 0;
    end
    sat_all = 1'b1;
    repeat (4000) @(posedge clk);
    sat_drain = 1'b1;                 // stop new requests, let the in-flight responses land
    repeat (200) @(posedge clk);
    sat_drain = 1'b0;
    sat_all   = 1'b0;
    for (integer p = 0; p < 4; p = p + 1) begin
      $display("NOTE sdram_tdm arbiter-contract: port %0d accepts=%0d resp=%0d burst_done=%0d",
               p, sat_acc[p], sat_resp[p], sat_bdone[p]);
      if (sat_acc[p] == 0)
        fail("a requester got no slot under all-four saturation: the arbiter is not rotating");
      else if (sat_resp[p] != sat_acc[p])
        fail("a port's resp_valid count does not equal its accept count (a response was dropped or misrouted)");
      else if (sat_bdone[p] != sat_acc[p])
        fail("a port's burst_done count does not equal its accept count");
    end

    solo_accepts = 0; solo_gap = 0; solo_worst_gap = 0;
    sat_solo = 1'b1;
    repeat (4000) @(posedge clk);
    sat_solo = 1'b0;
    repeat (100) @(posedge clk);
    $display("NOTE sdram_tdm arbiter-contract: solo (port 2 only) accepts=%0d worst gap=%0d cycles",
             solo_accepts, solo_worst_gap);
    if (solo_accepts < 40)
      fail("a lone requester was starved while the other three were idle");
    if (solo_worst_gap > 100)
      fail("a lone requester waited unboundedly while the other three were idle");

    $display("NOTE sdram_tdm arbiter-contract: misroute=%0d multi-responder=%0d (both must be 0)",
             misroute_violations, multi_resp_violations);
    if (misroute_violations != 0)
      fail("a response reached a port other than the one whose request was accepted");
    if (multi_resp_violations != 0)
      fail("more than one port answered in a single cycle");

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SDRAM_TDM: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_SDRAM_TDM: FAIL (%0d problems)", errors);
      $fatal(1, "the time-sliced SDRAM schedule did not hold");
    end
  end

  // A watchdog so a hang is a named failure rather than a timeout.
  initial begin
    repeat (60_000_000) @(posedge clk);
    $fatal(1, "TB_PC9821_SDRAM_TDM: FAIL (the bench did not finish -- a request never completed)");
  end
endmodule

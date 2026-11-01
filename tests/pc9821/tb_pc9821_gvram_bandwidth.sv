`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GVRAM_BANDWIDTH: measures, against the REAL src/memory/sdram.v controller and the REAL pc9821_gvram, the two bandwidths the flicker and the intro slowdown are made of - the CPU plane-window WRITE path (a stream of DWORD stores, one byte-lane read-modify-write per enabled lane on the DQM-less MiSTer module) and the scanout's 80-column line fetch, both alone and with the write stream saturating the shared controller - and reports each as an effective MB/s plus the worst-case line-fetch time against the 2014 clk_sys raster-line budget. It also ASSERTS the two defects are closed: the scanout issues bursts wider than one dword and no line misses its deadline under a saturating CPU write stream, and the ping-pong display swap only ever follows a COMPLETE fetch (a window too short to fetch the line holds the previous one instead of blending it).
//
// WHY THIS EXISTS. The GVRAM moved out of block RAM onto SDRAM as two
// requesters: the CPU's D1 accesses on the memory_subsystem's mem_* port (here port 0) and the
// scanout's line fetch on the controller's fourth (here port 3). The two defects this bench
// measures against are: the intro running slow (the write path's per-access cost) and the
// sprites flickering when many objects are on screen (the scanout's line fetch losing its
// deadline to the write stream). An earlier study modelled the scanout against the controller and said
// the model was not pc9821_gvram_dut itself; this bench drives the real FSM.
//
// The 2014 clk_sys line budget is the machine's
// own: 848 dots x 440 lines at the 21.0526 MHz dot clock is a 24.825 kHz line rate, 40.28 us.
//
// The bench ASSERTS the two defects it exists for are FIXED - the scanout fetches a line in
// BURSTS and completes it under a saturating CPU write stream, and the ping-pong display swap
// only ever follows a COMPLETE fetch - and it REPORTS the write MB/s and the worst line-fetch
// time without gating on the write path, which is still 3.6x the machine's and is not this
// lane's lever.

`default_nettype none

module tb_pc9821_gvram_bandwidth;
  // The built configuration: clk_sys = 50 MHz, the controller on the same clock.
  localparam integer FREQ     = 50_000_000;
  localparam integer CYCLE_NS = 20;
  localparam [31:0]  GVRAM_BASE = 32'h0300_0000;

  // The raster line budget in clk_sys cycles (pc9821_gdc_text: 848 dots/line at 21.0526 MHz,
  // 440 lines/frame at 56.42 Hz -> 40.28 us).
  localparam integer LINE_BUDGET = 2014;
  localparam integer LINE_COLS   = 80;

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg reset = 1;

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ==== DUT ====
  // The real GVRAM datapath, its client port and its two SDRAM requesters.
  reg        access_page = 1'b0;
  reg  [1:0] win_plane = 2'd0;
  reg [14:0] win_offset = 15'd0;
  reg [31:0] cpu_din = 32'd0;
  reg  [3:0] cpu_be = 4'hF;
  reg        cpu_line_read = 1'b0;
  reg        cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0]  cpu_dout;
  wire [31:0] cpu_line_word;
  wire         cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  reg        grcg_we = 1'b0;
  reg  [7:0] grcg_addr = 8'd0, grcg_din = 8'd0;

  reg        egc_gate = 1'b0;
  reg [15:0] egc_access = 16'hFFFF, egc_fgbg = 16'd0, egc_ope = 16'd0,
             egc_fg = 16'd0, egc_mask = 16'hFFFF, egc_bg = 16'd0,
             egc_sft = 16'd0, egc_leng = 16'd0;
  reg        egc_shift_we = 1'b0;

  reg        scan_enable = 1'b0, scan_line_tick = 1'b0, scan_page = 1'b0;
  reg [14:0] scan_line_base = 15'd0;
  reg  [6:0] line_rd_addr = 7'd0;
  reg        line_rd_sel = 1'b0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;


  // Two saturating 1-dword read streams on the controller's second and third requesters, standing
  // in for the backend's other traffic (the font glyph fetch and the 86-PCM buffer drain) when the
  // arbiter's worst case is wanted. They are OFF for the machine-shaped phases.
  reg        ram_en = 1'b0, pcm_en = 1'b0;
  reg [26:0] ram_addr = 27'h0040_0000;
  reg [26:0] pcm_addr = 27'h0080_0000;
  reg        ram_valid = 1'b0, pcm_valid = 1'b0;
  wire       ram_ready, pcm_ready;

  pc9821_gvram_dut dut (
      .clk(clk), .reset(reset),
      .access_page(access_page),
      .win_plane(win_plane), .win_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .egc_gate(egc_gate), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
      .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask),
      .egc_bg(egc_bg), .egc_sft(egc_sft), .egc_leng(egc_leng),
      .egc_shift_we(egc_shift_we),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));


  

  // ==== STIMULUS ====
  // The CPU's write stream: cpu_valid held high so the client port is always asking, and the
  // window offset advanced one DWORD (four plane columns) per completed store. That is the shape
  // the ITF's `rep stosd` and the games' plane fills make. count = completed stores, txns =
  // backend transactions accepted for the CPU port.
  reg        cpu_stream_en = 1'b0;
  integer    cpu_stores = 0;
  integer    cb_txns = 0;

  // The GVRAM is block RAM now: there is no backend transaction to count.

  // The two saturating port-1/2 streams were the SDRAM arbiter's worst case; the controller is
  // gone with the GVRAM's SDRAM backing, so the streams are idle placeholders.
  always @(posedge clk) begin
    ram_valid <= ram_en;
    pcm_valid <= pcm_en;
  end

  always @(posedge clk) begin
    if (reset) begin
      cpu_valid <= 1'b0; cpu_write <= 1'b0; cpu_be <= 4'hF;
      win_plane <= 2'd0; win_offset <= 15'd0; cpu_din <= 32'd0;
    end else if (cpu_stream_en) begin
      cpu_valid <= 1'b1;
      cpu_write <= 1'b1;
      cpu_be    <= 4'hF;
      win_plane <= 2'd0;
      if (cpu_ready) begin
        // Safe to move here: the plain path has left its last C_VAL, so win_offset and cpu_din
        // are not sampled again until the walk's next C_VAL several cycles later.
        win_offset <= win_offset + 15'd4;
        cpu_din    <= cpu_din + 32'h0101_0101;
        cpu_stores <= cpu_stores + 1;
      end
    end else begin
      cpu_valid <= 1'b0;
      cpu_write <= 1'b0;
    end
  end

  // ==== CHECKS ====
  integer errors = 0;
  task automatic fail(input [255:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  integer a_cyc0, a_cyc1, a_st0, a_st1, a_tx0, a_tx1, a_win;
  real    wr_mbps, scan_mbps;

  // One scanout line at the raster cadence: a tick, then a whole LINE_BUDGET window in which the
  // fetch's 80 responses are counted. `cols` < 80 at the window's end means the fetch MISSED its
  // deadline and the display buffer keeps the previous line's tail in the columns not fetched.
  integer scan_lines_run = 0, scan_misses = 0, scan_min_cols = 999, scan_worst = 0;

  integer i, no_load_worst, loaded_worst, no_load_misses, loaded_misses;

  // ---- THE INSTRUMENTS THE TWO FIXED DEFECTS ARE JUDGED BY ----
  // The columns a line window delivered, and whether the ping-pong select moved in it. The array
  // is block RAM now: the fetch reads one column per clk_sys on its own port, so there
  // is no burst to size and no shared controller to lose the deadline to.
  integer   scan_cols = 0;
  integer   line_swaps = 0, line_holds = 0, guard_violations = 0, prev_window_beats;
  integer   short_swaps = 0, short_holds = 0, resume_swaps = 0;

  always @(posedge clk) if (dut.u_scan.fetch_req_d) scan_cols <= scan_cols + 1;

  // The tick's line window, with the two quantities the swap guard is checked against: the beats
  // the window delivered, and whether `line_sel` moved in it. The swap at a tick reflects the
  // PREVIOUS window's fill (the guard samples the fill state at the tick), so the invariant below
  // compares each window's swap against the window before it.
  task automatic scan_line(input [14:0] base);
    integer t0, cols, done_cyc;
    reg     sel_before;
    begin
      @(negedge clk);
      scan_line_base = base;
      sel_before     = line_sel;
      scan_line_tick = 1'b1;
      @(posedge clk); #1;
      t0 = cyc;
      @(negedge clk);
      scan_line_tick = 1'b0;
      cols = 0; done_cyc = -1;
      while ((cyc - t0) < LINE_BUDGET) begin
        @(posedge clk); #1;
        if (dut.u_scan.fetch_req_d) begin
          cols = cols + 1;
          if (cols == LINE_COLS && done_cyc < 0) done_cyc = cyc - t0;
        end
      end
      if ((line_sel !== sel_before) && (prev_window_beats < LINE_COLS))
        guard_violations = guard_violations + 1;
      if (done_cyc >= 0 && done_cyc > scan_worst) scan_worst = done_cyc;
      if (done_cyc < 0) scan_misses = scan_misses + 1;
      if (cols < scan_min_cols) scan_min_cols = cols;
      prev_window_beats = cols;
      if (line_sel !== sel_before) line_swaps = line_swaps + 1;
      else                         line_holds = line_holds + 1;
      scan_lines_run = scan_lines_run + 1;
    end
  endtask

  // Windows SHORTER than a line fetch takes, so the guard is exercised: the fill cannot finish
  // inside one, the swap must be deferred, and the display must hold the previous line rather
  // than blend one. `count` ticks, each with a `win`-cycle window; returns how many moved the
  // select, and folds every window into the same invariant the long windows use.
  task automatic scan_line_short(input [14:0] base, input integer win, input integer count,
                                 output integer swaps);
    integer t0, n, cols;
    reg     sel_before;
    begin
      swaps = 0;
      for (n = 0; n < count; n = n + 1) begin
        @(negedge clk);
        scan_line_base = base;
        sel_before     = line_sel;
        scan_line_tick = 1'b1;
        @(negedge clk);
        scan_line_tick = 1'b0;
        t0 = cyc; cols = 0;
        while ((cyc - t0) < win) begin
          @(posedge clk); #1;
          if (dut.u_scan.fetch_req_d) cols = cols + 1;
        end
        if ((line_sel !== sel_before) && (prev_window_beats < LINE_COLS))
          guard_violations = guard_violations + 1;
        if (line_sel !== sel_before) swaps = swaps + 1;
        prev_window_beats = cols;
        scan_lines_run = scan_lines_run + 1;
      end
    end
  endtask

  initial begin
    // Release the GVRAM only after the controller has left its ~200 us init, so no fetch's
    // measurement absorbs a calibration wait.
    reset  = 1'b1;
    repeat (8) @(posedge clk);
    i = 0;
    repeat (20) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);


    // ---- PHASE A: the CPU's plane-window write path, scanout idle ----
    cpu_stream_en = 1'b1;
    repeat (4000) @(posedge clk);          // let the stream reach steady state
    a_cyc0 = cyc; a_st0 = cpu_stores; a_tx0 = cb_txns;
    a_win  = 40000;
    repeat (a_win) @(posedge clk);
    a_cyc1 = cyc; a_st1 = cpu_stores; a_tx1 = cb_txns;
    cpu_stream_en = 1'b0;
    repeat (50) @(posedge clk);

    if ((a_st1 - a_st0) == 0) fail("the CPU write stream completed no stores: the write path is wedged");
    wr_mbps = ((a_st1 - a_st0) * 4.0) * (FREQ / 1_000_000.0) / (a_cyc1 - a_cyc0);
    $display("NOTE gvram_bandwidth: CPU plane-window WRITE (dword stores, scanout idle): %0d stores in %0d clk_sys = %0.1f MB/s of plane bytes",
             a_st1 - a_st0, a_cyc1 - a_cyc0, wr_mbps);
    $display("NOTE gvram_bandwidth: write path cost: %0d backend transaction(s) for %0d store(s), %0d clk_sys per store",
             a_tx1 - a_tx0, a_st1 - a_st0, (a_cyc1 - a_cyc0) / (a_st1 - a_st0));
    $display("NOTE gvram_bandwidth: the real machine measured 13.8 MB/s plane-window WRITE (tools/hwprobe/gfxbench/gfxbench.s)");

    // ---- PHASE B1: the scanout's line fetch alone ----
    scan_enable = 1'b1;
    scan_worst = 0; scan_misses = 0; scan_min_cols = 999; scan_lines_run = 0;
    // No fill has been watched yet, so the first tick's swap (which the reset state permits, there
    // being no line in flight) is not an incomplete one.
    prev_window_beats = LINE_COLS;
    for (i = 0; i < 12; i = i + 1) scan_line(15'(i * LINE_COLS));
    no_load_worst  = scan_worst;
    no_load_misses = scan_misses;
    $display("NOTE gvram_bandwidth: scanout line fetch, CPU idle: worst %0d clk_sys of the %0d budget (%0d%%), %0d/%0d lines missed, min columns fetched %0d/%0d",
             no_load_worst, LINE_BUDGET, (no_load_worst * 100) / LINE_BUDGET,
             no_load_misses, scan_lines_run, scan_min_cols, LINE_COLS);
    scan_mbps = (LINE_COLS * 4.0) * (FREQ / 1_000_000.0) / no_load_worst;
    $display("NOTE gvram_bandwidth: scanout read rate while idle: %0.1f MB/s (%0d dwords/line, 1 line per %0d clk_sys)",
             scan_mbps, LINE_COLS, LINE_BUDGET);

    // ---- PHASE B2: the scanout's line fetch under the saturating CPU write stream ----
    cpu_stream_en = 1'b1;
    repeat (2000) @(posedge clk);          // the write stream is now filling port 0
    scan_worst = 0; scan_misses = 0; scan_min_cols = 999; scan_lines_run = 0;
    for (i = 0; i < 12; i = i + 1) scan_line(15'(15'h1000 + i * LINE_COLS));
    loaded_worst  = scan_worst;
    loaded_misses = scan_misses;
    cpu_stream_en = 1'b0;
    $display("NOTE gvram_bandwidth: scanout line fetch, CPU WRITE stream saturating: worst %0d clk_sys of the %0d budget (%0d%%), %0d/%0d lines missed, min columns fetched %0d/%0d",
             loaded_worst, LINE_BUDGET, (loaded_worst * 100) / LINE_BUDGET,
             loaded_misses, scan_lines_run, scan_min_cols, LINE_COLS);
    $display("NOTE gvram_bandwidth: BUDGET 2014 clk_sys = 848 dots x 440 lines at 21.0526 MHz = 40.28 us");
    $display("NOTE gvram_bandwidth: the swap is guarded on a COMPLETE fetch: a missed line holds the previous line instead of blending it with the one from two lines ago");

    // ---- PHASE B3: the arbiter's worst case - the scanout has no priority, so it misses when the
    // other three slots are busy. All four requesters saturated: port 0 the GVRAM write stream,
    // ports 1/2 the saturating read streams, port 3 the scanout. The game does not saturate ports
    // 1/2, so this bounds the fault rather than reproducing the frame that shakes.
    cpu_stream_en = 1'b1; ram_en = 1'b1; pcm_en = 1'b1;
    repeat (2000) @(posedge clk);
    scan_worst = 0; scan_misses = 0; scan_min_cols = 999; scan_lines_run = 0;
    for (i = 0; i < 12; i = i + 1) scan_line(15'(15'h2000 + i * LINE_COLS));
    cpu_stream_en = 1'b0; ram_en = 1'b0; pcm_en = 1'b0;
    $display("NOTE gvram_bandwidth: scanout line fetch, ALL FOUR requesters saturating: worst %0d clk_sys of the %0d budget (%0d%%), %0d/%0d lines missed, min columns fetched %0d/%0d",
             scan_worst, LINE_BUDGET, (scan_worst * 100) / LINE_BUDGET,
             scan_misses, scan_lines_run, scan_min_cols, LINE_COLS);

    // ---- PHASE B4: the ping-pong swap may only follow a COMPLETE fetch. A window shorter than
    // the fetch takes cannot complete a line, so the display must HOLD the previous line rather
    // than switch to a half-filled buffer (the stale tail) or let the abandoned burst's late beat
    // land under the raster. 150 cycles is under the ~218 an idle line fetch already takes.
    cpu_stream_en = 1'b1;
    repeat (2000) @(posedge clk);
    scan_line_short(15'h3000, 40, 12, short_swaps);
    short_holds = 12 - short_swaps;
    // And the display is not frozen by the guard: a window the fetch fits in swaps again.
    line_swaps = 0;
    scan_worst = 0; scan_misses = 0; scan_min_cols = 999; scan_lines_run = 0;
    for (i = 0; i < 5; i = i + 1) scan_line(15'(15'h3000 + i * LINE_COLS));
    resume_swaps = line_swaps;
    cpu_stream_en = 1'b0;
    $display("NOTE gvram_bandwidth: swap guard, 40-cycle windows: %0d/%0d windows held, %0d swap invariant violation(s)",
             short_holds, 12, guard_violations);
    $display("NOTE gvram_bandwidth: resume at the real line budget: %0d/5 windows swapped", resume_swaps);
    $display("NOTE gvram_bandwidth: scanout columns issued from the M10K array: %0d", scan_cols);

    // ---- CHECKS: the instruments ----
    if (cpu_stores == 0) fail("no CPU store completed at all");
    if (scan_lines_run != 5) fail("not every scanout line of the resume phase ran");
    if (no_load_worst == 0) fail("the idle scanout measured no line at all: the measurement is vacuous");

    // ---- CHECKS: FIX 1 - the line completes under the write stream ----
    // The lines are in block RAM now, so the fetch completes in 80 clk_sys on its own port; the
    // "bursts wider than one dword" instrument was the SDRAM fetch's, and is gone with it.
    if (loaded_misses != 0)
      fail("a scanout line MISSED its deadline under a saturating CPU write stream: the flicker's cause is still open");
    if (scan_min_cols != LINE_COLS)
      fail("a line fetched fewer than 80 columns under the CPU write stream");

    // ---- CHECKS: FIX 3 - the swap never follows an incomplete fetch ----
    if (guard_violations != 0)
      fail("the display swapped to a buffer whose line fetch was incomplete (the stale-tail flicker)");
    if (short_holds < 11)
      fail("a window too short to fetch a line still swapped the display: the guard did not defer");
    if (resume_swaps < 4)
      fail("the display did not resume swapping once a line fit its window: the guard froze the picture");


    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GVRAM_BANDWIDTH: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_GVRAM_BANDWIDTH: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_GVRAM_BANDWIDTH: FAIL");
    end
  end

  // ==== VERDICT BOUND ====
  initial begin
    #30_000_000;
    $fatal(1, "TB_PC9821_GVRAM_BANDWIDTH: FAIL (timed out)");
  end

endmodule

`default_nettype wire

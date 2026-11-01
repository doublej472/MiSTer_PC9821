`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SPRITE_SCENE: models a busy Touhou-frame graphics scene - many EGC 0x3100 sprite put units per frame plus the plain plane-window restores - against the REAL src/memory/sdram.v controller and the REAL pc9821_gvram, and profiles the write path end to end: the EGC units per clk_sys, the GVRAM plane-byte rate in MB/s, the backend transaction mix (the partial-byte RMW the DQM-less module would need, the full-word write-backs, the fill reads), the write-combining buffer's hit rate, and the scanout line fetch's worst latency against the 2014 clk_sys raster budget while the scene saturates the client. It ASSERTS the scene's writes land by value (the EGC 0x3100 read-then-write copies the source plane bytes to the destination, a plain restore reads back), that NO partial-byte write reaches the controller (the buffer's whole point), and that the scanout still meets its deadline under the load.
//
// WHY THIS EXISTS is the profile the claim describes: the instrument that decides whether the
// plain-path client's per-lane C_NEXT/C_VAL/C_WAIT walk, the
// backend's fill/write-back, the EGC's own per-unit latency or the scanout's contention is the
// binding term on a realistic busy scene.
//
`default_nettype none

module tb_pc9821_sprite_scene;
  localparam integer FREQ     = 50_000_000;
  localparam integer CYCLE_NS = 20;
  localparam [31:0]  GVRAM_BASE = 32'h0300_0000;

  localparam integer LINE_BUDGET = 2014;   // 848 dots x 440 lines at 21.0526 MHz
  localparam integer LINE_COLS   = 80;

  // The scene: a frame draws PUTS_PER_FRAME sprites (each an EGC 0x3100 read+write unit) and
  // issues RESTORES_PER_FRAME plain plane-window restores, over FRAMES frames. The numbers are
  // chosen so the scene runs long enough to cross many raster lines, so the scanout contends.
  localparam integer FRAMES             = 64;
  localparam integer PUTS_PER_FRAME     = 16;
  localparam integer RESTORES_PER_FRAME = 64;
  // The HEAVIER scene the flicker report names: the real first level draws more than one
  // sprite put per plane column and it never pauses, so phase D below multiplies the put and
  // restore counts and drops the inter-frame gaps to keep the client + scanout contending the
  // whole time.
  localparam integer HEAVY_PUTS         = 128;
  localparam integer HEAVY_RESTORES     = 512;

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg reset = 1;

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ==== DUT ====
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
  reg [15:0] egc_access = 16'hFFF0, egc_fgbg = 16'h00FF, egc_ope = 16'h3100,
             egc_fg = 16'h0000, egc_mask = 16'hFFFF, egc_bg = 16'h0000,
             egc_sft = 16'h0000, egc_leng = 16'h000F;
  reg        egc_shift_we = 1'b0;

  reg        scan_enable = 1'b0, scan_line_tick = 1'b0, scan_page = 1'b0;
  reg [14:0] scan_line_base = 15'd0;
  reg  [6:0] line_rd_addr = 7'd0;
  reg        line_rd_sel = 1'b0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;


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

  // ---- The real controller, at the built configuration, against the chip model ----

  

  

  // ==== THE PROFILE COUNTERS ====
  // Every metric the profile reports, counted where it happens and not inferred from the
  // workload: the client's accepted accesses, the buffer's coalesced hits, the backend's
  // transaction mix, the plane bytes each side actually commits, and the scanout's line fetch.
  function automatic [3:0] popcount4(input [3:0] v);
    begin
      popcount4 = {3'd0, v[0]} + {3'd0, v[1]} + {3'd0, v[2]} + {3'd0, v[3]};
    end
  endfunction

  integer client_accesses = 0;    // every CPU access the backend accepted (cc_valid & cc_ready)
  integer wcb_hits        = 0;    // the buffer's coalesced hits (a lane merged with NO SDRAM access)
  integer wcb_fills       = 0;    // the buffer's lane misses (a read fill had to fetch the word)
  integer cb_txns         = 0;    // backend transactions the controller accepted
  integer cb_rmw          = 0;    // ... that were PARTIAL-byte writes: the DQM-less RMW
  integer cb_fullwr       = 0;    // ... that were full-word write-backs
  integer cb_reads        = 0;    // ... that were reads (fills / line fetches / through reads)
  integer plane_bytes     = 0;    // plane bytes the GVRAM actually committed
  integer egc_read_units  = 0;
  integer egc_write_units = 0;

  always @(posedge clk) begin
    // The GVRAM is block RAM now: there is no backend transaction and no write-combining
    // buffer, so the cb_/wcb_ counters stay at zero and the split column reads simply.
    if (dut.u_arb.cc_valid && dut.u_arb.cc_ready) client_accesses <= client_accesses + 1;
    // Plane bytes the plain path commits: one byte per enabled lane of the access. The
    // direction is the client's own LATCHED `c_write_q`, not the live `cpu_write`: the core
    // decouples the store, so z486 drops `cpu_write` the cycle the walk accepts the access.
    if (dut.u_arb.cc_plain_ready && dut.u_arb.c_write_q) plane_bytes <= plane_bytes + popcount4(dut.u_arb.cc_lane_be);
    // Plane bytes the EGC commits: one per enabled plane lane of each write request the arbiter
    // accepts, two columns for a burst - observed at the client handshake, not on the engine's
    // internals (this used to read a state number and a private column array, and the state
    // number named the read-response state, so the EGC's bytes were never counted).
    if (dut.u_arb.cc_egc_ready && dut.u_egc.cl_write)
      plane_bytes <= plane_bytes + (dut.u_egc.cl_burst ? 2 : 1) * popcount4(dut.u_egc.cl_wbe);
    // The EGC's own unit count, taken from the EGC's CPU-ready (one pulse per completed unit) and
    // the direction it latched for that unit. It used to read two private state numbers, which is
    // why the sequencer's state renumbering broke it: observe the
    // handshake, not the encoding.
    if (dut.u_egc.cpu_ready) begin
      if (dut.u_egc.unit_write) egc_write_units <= egc_write_units + 1;
      else                    egc_read_units  <= egc_read_units + 1;
    end
  end

  // ---- The scanout: a tick per raster line, and the fetch latency it produces. The DUT owns
  // the ping-pong fetch; this generator only paces the raster and times the line, so the number
  // is the real fetch under the scene's load against the machine's own 2014 clk_sys budget. ----
  integer scan_t0 = 0, scan_beats = 0, scan_lines = 0, scan_misses = 0, scan_worst = 0;
  integer scan_pace = LINE_BUDGET;
  reg     scan_inflight = 0;
  // The per-line flush + fetch-start instruments: how long the write-combining buffer's write-
  // back holds the scanout off (wcb_flushing), and how late into the line the fetch actually
  // fires. These are the two terms the flicker hypothesis blames, so they are measured, not
  // assumed.
  integer flush_t0 = 0, flush_cycles = 0, flush_max = 0;
  integer scan_start_lat = 0, scan_start_worst = 0;
  reg     was_flushing = 0;

  always @(posedge clk) begin
    if (scan_enable) begin
      if (scan_pace == 0) begin
        scan_line_tick <= 1'b1;
        scan_pace      <= LINE_BUDGET;
      end else begin
        scan_line_tick <= 1'b0;
        scan_pace      <= scan_pace - 1;
      end
    end else begin
      scan_line_tick <= 1'b0;
      scan_pace      <= LINE_BUDGET;
    end
  end

  always @(posedge clk) begin
    if (scan_line_tick) begin
      scan_t0       <= cyc;
      scan_beats    <= 0;
      scan_inflight <= 1;
      scan_start_lat <= 0;
    end else if (scan_inflight && dut.u_scan.fetch_req_d) begin
      if (scan_start_lat == 0) scan_start_lat <= cyc - scan_t0;
      // One resp beat per dword; the line's 80 columns are in when this is the 80th.
      if (scan_beats + 1 >= LINE_COLS) begin
        if ((cyc - scan_t0) > scan_worst) scan_worst <= cyc - scan_t0;
        scan_lines    <= scan_lines + 1;
        scan_inflight <= 0;
        if (scan_start_lat > scan_start_worst) scan_start_worst <= scan_start_lat;
      end
      scan_beats <= scan_beats + 1;
    end
    // The deadline is the machine's own: a line not complete within its window MISSED it.
    if (scan_inflight && ((cyc - scan_t0) > LINE_BUDGET)) begin
      scan_misses   <= scan_misses + 1;
      scan_inflight <= 0;
    end
    // The write-combining flush: its duration is the window the scanout is held off.
    if (!was_flushing && 1'b0) begin
      flush_t0 <= cyc;
    end else if (was_flushing && !1'b0) begin
      if ((cyc - flush_t0) > flush_max) flush_max <= cyc - flush_t0;
      flush_cycles <= flush_cycles + (cyc - flush_t0);
    end
    was_flushing <= 1'b0;
  end

  // ==== STIMULUS ====
  integer errors = 0;
  task automatic fail(input [8*160-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  // A plain plane-window store: one lane per enabled byte, the address's low bits ride the
  // enables exactly as z486 presents them. The access page (port 0xA6) selects which of the
  // two 256 KiB pages the four plane windows show.
  task automatic plain_store_pg(input pg, input [1:0] plane, input [14:0] off,
                                input [3:0] be, input [31:0] din);
    begin
      @(negedge clk);
      egc_gate    = 1'b0;
      access_page = pg;
      win_plane   = plane;
      win_offset  = off;
      cpu_be      = be;
      cpu_din     = din;
      cpu_write   = 1'b1;
      cpu_valid   = 1'b1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
      while (dut.u_arb.cs != 3'd0) @(posedge clk);
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic plain_store(input [1:0] plane, input [14:0] off,
                             input [3:0] be, input [31:0] din);
    begin
      plain_store_pg(1'b0, plane, off, be, din);
    end
  endtask

  // A plain plane-window load (the restore's read half): a dword lane per enabled byte, so
  // byte lane k of `d` is the plane's byte at column (off & ~3) + k.
  task automatic plain_load_pg(input pg, input [1:0] plane, input [14:0] off, output [31:0] d);
    begin
      @(negedge clk);
      egc_gate    = 1'b0;
      access_page = pg;
      win_plane   = plane;
      win_offset  = off;
      cpu_be      = 4'hF;
      cpu_write   = 1'b0;
      cpu_valid   = 1'b1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      while (!cpu_resp_valid) begin @(posedge clk); #1; end
      d = cpu_dout;
      @(negedge clk);
      cpu_valid = 1'b0;
      while (dut.u_arb.cs != 3'd0) @(posedge clk);
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic plain_load(input [1:0] plane, input [14:0] off, output [31:0] d);
    begin
      plain_load_pg(1'b0, plane, off, d);
    end
  endtask

  // An EGC 0x3100 unit's READ half: read the source page and latch the pattern register.
  // A PLOAD_R (RL_MEMREAD) read latches the SELECTED PAT plane only - "Normal PLOAD_R loads the
  // selected PAT plane only.  Four-plane PAT setup uses four selected reads" (PC98_EGC_CONFORMANCE
  // v1.3 README; its RD02_PAT_S0..S3 rows, replayed by tb_pc9821_egc_compare section 3) - where
  // NP2kai latches all four from one read. So the 0x4A2 read-plane selector walks 0..3 over the
  // same source word, as the suite's own four-plane PAT setup does; the unit's cost is therefore
  // four reads per write in this model of TH01's copy.
  task automatic egc_read_unit(input [14:0] off);
    begin
      for (integer k = 0; k < 4; k = k + 1) begin
        @(negedge clk);
        egc_gate    = 1'b1;
        access_page = 1'b1;
        win_plane   = 2'd0;
        win_offset  = off;
        egc_fgbg    = {6'h00, k[1:0], 6'h00, k[1:0]};
        cpu_be      = 4'hF;
        cpu_write   = 1'b0;
        cpu_valid   = 1'b1;
        @(posedge clk); #1;
        while (!cpu_ready) begin @(posedge clk); #1; end
        @(negedge clk);
        cpu_valid = 1'b0;
        while (dut.u_egc.state != 4'd0) @(posedge clk);
        repeat (2) @(posedge clk);
      end
      egc_fgbg = 16'h00FF;
    end
  endtask

  // An EGC 0x3100 unit's WRITE half: store the latched pattern to the destination page.
  task automatic egc_write_unit(input [14:0] off);
    begin
      @(negedge clk);
      egc_gate    = 1'b1;
      access_page = 1'b0;
      win_plane   = 2'd0;
      win_offset  = off;
      cpu_be      = 4'hF;
      cpu_din     = 32'h0;
      cpu_write   = 1'b1;
      cpu_valid   = 1'b1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0;
      while (dut.u_egc.state != 4'd0) @(posedge clk);
      repeat (2) @(posedge clk);
    end
  endtask

  // The scene's sprite put: read page 1 at the plane offset, write page 0 at the same offset.
  task automatic sprite_put(input [14:0] off);
    begin
      egc_read_unit(off);
      egc_write_unit(off);
    end
  endtask

  integer i, f, s, c0, c1, mism, vo;
  reg [31:0] rd, d0;
  reg [14:0] off;

  initial begin
    reset  = 1'b1;
    repeat (8) @(posedge clk);
    i = 0;
    repeat (20) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);


    // ---- Seed 64 columns of BOTH pages and all four planes with distinct values, so the EGC
    // copy below has something to move and the destination can be checked by value. Page 1
    // (the source) carries 0xA0+plane; page 0 (the destination) carries 0x50+plane. ----
    for (i = 0; i < 64; i = i + 1) begin
      off = 15'h1000 + i[14:0];
      for (s = 0; s < 4; s = s + 1) begin
        // Lane = off[1:0], so the byte enable names the word the store lands in and the data
        // replicates the byte across the four lanes.
        plain_store_pg(1'b0, s[1:0], off, 4'h1 << off[1:0], {4{8'h50 + s[7:0]}});
        plain_store_pg(1'b1, s[1:0], off, 4'h1 << off[1:0], {4{8'hA0 + s[7:0]}});
      end
    end

    // ============================================================
    // CORRECTNESS FIRST: an EGC 0x3100 put copies the source plane bytes to the destination.
    // The region is clean here (the scene below overwrites it afterwards). The unit is a
    // 16-bit (2-column) copy over the dword at 0x1000, so page 0's columns 0x1000/0x1001 must
    // take the source values and 0x1002/0x1003 must be untouched.
    // ============================================================
    begin : check_copy
      sprite_put(15'h1000);
      mism = 0;
      // The 0x3100 dword copy moves the dword's four columns, so page 0's whole dword at
      // 0x1000 must take the source values.
      for (s = 0; s < 4; s = s + 1) begin
        plain_load_pg(1'b0, s[1:0], 15'h1000, d0);
        if (d0[7:0]   !== (8'hA0 + s[7:0])) mism = mism + 1;
        if (d0[15:8]  !== (8'hA0 + s[7:0])) mism = mism + 1;
        if (d0[23:16] !== (8'hA0 + s[7:0])) mism = mism + 1;
        if (d0[31:24] !== (8'hA0 + s[7:0])) mism = mism + 1;
      end
      if (mism != 0)
        fail("the EGC 0x3100 put did not put the source plane bytes at the destination");
      else
        $display("NOTE sprite_scene: EGC 0x3100 put copies the source dword to the destination (all four planes/columns)");
    end

    // ---- PHASE A: EGC puts alone. Measures the EGC's own unit rate and the write path it
    // drives - the sprite blit. ----
    repeat (200) @(posedge clk);
    client_accesses = 0; wcb_hits = 0; wcb_fills = 0; cb_txns = 0; cb_rmw = 0;
    cb_fullwr = 0; cb_reads = 0; plane_bytes = 0; egc_read_units = 0; egc_write_units = 0;
    c0 = cyc;
    for (i = 0; i < 64; i = i + 1) sprite_put(15'h1000 + i[14:0]);
    c1 = cyc;
    $display("NOTE sprite_scene: A EGC 0x3100 puts alone: %0d read units + %0d write units in %0d clk_sys",
             egc_read_units, egc_write_units, c1 - c0);
    $display("NOTE sprite_scene:   EGC units/cycle = %0.4f (%0d units), plane bytes %0d, %0.1f MB/s",
             (egc_read_units + egc_write_units) * 1.0 / (c1 - c0),
             egc_read_units + egc_write_units, plane_bytes,
             plane_bytes * 1.0 * (FREQ/1_000_000.0) / (c1 - c0));
    $display("NOTE sprite_scene:   client accesses %0d, WCB lane hits %0d / misses %0d (%0d%% hit rate)",
             client_accesses, wcb_hits, wcb_fills,
             ((wcb_hits + wcb_fills) == 0) ? 0 : (wcb_hits * 100) / (wcb_hits + wcb_fills));
    $display("NOTE sprite_scene:   backend: %0d read(s), %0d full-word write(s), %0d RMW (partial) write(s)",
             cb_reads, cb_fullwr, cb_rmw);
    // The EGC 0x3100 put fetches its source dword ONCE (4 column reads) and reuses it
    // for the two 16-bit units. The pre-fix re-read doubled this to ~472; bound it well
    // below that so a reintroduced re-read fails here.
    if (cb_reads > 320)
      fail("the EGC put re-read its source dword (backend reads > 320 for 64 puts)");

    // ---- PHASE B: plain plane-window restores alone. Four planes of one column, 16-bit
    // stores, which is TH01's egc_copy_rect_1_to_0_16 restore shape. ----
    repeat (200) @(posedge clk);
    client_accesses = 0; wcb_hits = 0; wcb_fills = 0; cb_txns = 0; cb_rmw = 0;
    cb_fullwr = 0; cb_reads = 0; plane_bytes = 0;
    c0 = cyc;
    for (i = 0; i < 256; i = i + 1) begin
      off = 15'h2000 + i[14:0];
      for (s = 0; s < 4; s = s + 1)
        plain_store(s[1:0], off, 4'b0011, {4{8'h5A}});
    end
    c1 = cyc;
    $display("NOTE sprite_scene: B plain 16-bit restores alone: %0d plane bytes in %0d clk_sys = %0.1f MB/s",
             plane_bytes, c1 - c0, plane_bytes * 1.0 * (FREQ/1_000_000.0) / (c1 - c0));
    $display("NOTE sprite_scene:   client accesses %0d, WCB lane hits %0d / misses %0d (%0d%% hit rate)",
             client_accesses, wcb_hits, wcb_fills,
             ((wcb_hits + wcb_fills) == 0) ? 0 : (wcb_hits * 100) / (wcb_hits + wcb_fills));
    $display("NOTE sprite_scene:   backend: %0d read(s), %0d full-word write(s), %0d RMW (partial) write(s)",
             cb_reads, cb_fullwr, cb_rmw);

    // ---- PHASE C: the busy scene - puts + restores + the scanout contending ----
    repeat (200) @(posedge clk);
    scan_enable    = 1'b1;
    scan_page      = 1'b0;
    scan_line_base = 15'h1000;
    client_accesses = 0; wcb_hits = 0; wcb_fills = 0; cb_txns = 0; cb_rmw = 0;
    cb_fullwr = 0; cb_reads = 0; plane_bytes = 0; egc_read_units = 0; egc_write_units = 0;
    scan_lines = 0; scan_misses = 0; scan_worst = 0; scan_inflight = 0;
    c0 = cyc;
    for (f = 0; f < FRAMES; f = f + 1) begin
      for (s = 0; s < PUTS_PER_FRAME; s = s + 1) begin
        vo = f * PUTS_PER_FRAME + s;
        sprite_put(15'h1000 + vo[14:0]);
      end
      for (s = 0; s < RESTORES_PER_FRAME; s = s + 1) begin
        vo = f * RESTORES_PER_FRAME + s;
        plain_store(s[1:0], 15'h2000 + vo[14:0], 4'b0011, {4{8'hA5}});
      end
    end
    repeat (4000) @(posedge clk);
    c1 = cyc;
    scan_enable = 1'b0;
    $display("NOTE sprite_scene: C busy scene: %0d frames, %0d EGC units + %0d plane bytes in %0d clk_sys",
             FRAMES, egc_read_units + egc_write_units, plane_bytes, c1 - c0);
    $display("NOTE sprite_scene:   GVRAM plane-write rate = %0.1f MB/s, EGC units/cycle = %0.4f",
             plane_bytes * 1.0 * (FREQ/1_000_000.0) / (c1 - c0),
             (egc_read_units + egc_write_units) * 1.0 / (c1 - c0));
    $display("NOTE sprite_scene:   client accesses %0d, WCB lane hits %0d / misses %0d (%0d%% hit rate)",
             client_accesses, wcb_hits, wcb_fills,
             ((wcb_hits + wcb_fills) == 0) ? 0 : (wcb_hits * 100) / (wcb_hits + wcb_fills));
    $display("NOTE sprite_scene:   backend: %0d read(s), %0d full-word write(s), %0d RMW (partial) write(s)",
             cb_reads, cb_fullwr, cb_rmw);
    $display("NOTE sprite_scene:   scanout: %0d line(s) completed, worst %0d clk_sys of the %0d budget, %0d missed",
             scan_lines, scan_worst, LINE_BUDGET, scan_misses);
    $display("NOTE sprite_scene:   flush: max %0d clk_sys, total %0d clk_sys; scanout fetch-start worst %0d clk_sys",
             flush_max, flush_cycles, scan_start_worst);

    // ---- CORRECTNESS: the last plain restore reads back what the scene wrote ----
    vo = FRAMES * RESTORES_PER_FRAME - 1;
    plain_load(2'd0, 15'h2000 + vo[14:0], rd);
    if ((rd & 32'h0000_00FF) !== 8'hA5)
      fail("a busy-scene plain restore did not read back the byte it stored");

    // ---- PHASE D: the HEAVIER scene - the real first level's sprite load, continuous. The
    // put and restore counts are multiplied and the inter-frame gaps are gone, so the client
    // and the scanout contend the whole time (this is where a missed line would show). ----
    repeat (200) @(posedge clk);
    scan_enable    = 1'b1;
    scan_page      = 1'b0;
    scan_line_base = 15'h1000;
    client_accesses = 0; wcb_hits = 0; wcb_fills = 0; cb_txns = 0; cb_rmw = 0;
    cb_fullwr = 0; cb_reads = 0; plane_bytes = 0; egc_read_units = 0; egc_write_units = 0;
    scan_lines = 0; scan_misses = 0; scan_worst = 0; scan_inflight = 0;
    flush_t0 = 0; flush_cycles = 0; flush_max = 0; scan_start_lat = 0; scan_start_worst = 0;
    c0 = cyc;
    for (f = 0; f < FRAMES; f = f + 1) begin
      for (s = 0; s < HEAVY_PUTS; s = s + 1) begin
        vo = (f * HEAVY_PUTS + s) & 15'h7FFF;
        sprite_put(15'h1000 + vo[14:0]);
      end
      for (s = 0; s < HEAVY_RESTORES; s = s + 1) begin
        vo = (f * HEAVY_RESTORES + s) & 15'h7FFF;
        plain_store(s[1:0], 15'h2000 + vo[14:0], 4'b0011, {4{8'hA5}});
      end
    end
    repeat (4000) @(posedge clk);
    c1 = cyc;
    scan_enable = 1'b0;
    $display("NOTE sprite_scene: D HEAVY scene: %0d puts + %0d restores per frame, %0d frames, %0d plane bytes in %0d clk_sys",
             HEAVY_PUTS, HEAVY_RESTORES, FRAMES, plane_bytes, c1 - c0);
    $display("NOTE sprite_scene:   GVRAM plane-write rate = %0.1f MB/s, EGC units/cycle = %0.4f",
             plane_bytes * 1.0 * (FREQ/1_000_000.0) / (c1 - c0),
             (egc_read_units + egc_write_units) * 1.0 / (c1 - c0));
    $display("NOTE sprite_scene:   backend: %0d read(s), %0d full-word write(s), %0d RMW (partial) write(s)",
             cb_reads, cb_fullwr, cb_rmw);
    $display("NOTE sprite_scene:   scanout: %0d line(s), worst %0d clk_sys of %0d, %0d missed; flush max %0d clk_sys; fetch-start worst %0d clk_sys",
             scan_lines, scan_worst, LINE_BUDGET, scan_misses, flush_max, scan_start_worst);

    // ==== CHECKS ====
    // ---- the profile's instruments ----
    if ((egc_read_units == 0) || (egc_write_units == 0))
      fail("the busy scene completed no EGC unit: the EGC path is wedged");
    if (plane_bytes == 0)
      fail("the busy scene committed no plane byte");
    if (client_accesses == 0)
      fail("the busy scene accepted no client access");

    // The write-combining buffer's whole point: no partial-byte write may reach the DQM-less
    // controller (it would be a read-modify-write). Everything is merged first or written full.
    if (cb_rmw != 0)
      fail("a partial-byte write reached the controller: the write-combining buffer did not merge it");

    // The scanout still meets its deadline under the busy scene.
    if (scan_lines == 0)
      fail("the scanout completed no line while the scene ran");
    if (scan_misses != 0)
      fail("a scanout line missed its deadline under the busy scene");

    $display("NOTE sprite_scene: scanout lines %0d, worst %0d, misses %0d; cb_txns %0d",
             scan_lines, scan_worst, scan_misses, cb_txns);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SPRITE_SCENE: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_SPRITE_SCENE: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_SPRITE_SCENE: FAIL");
    end
  end

  initial begin
    #60_000_000;
    $fatal(1, "TB_PC9821_SPRITE_SCENE: FAIL (timed out)");
  end

endmodule

`default_nettype wire

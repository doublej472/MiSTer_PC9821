`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GFX_SCENE: models a Touhou-style BUSY sprite frame - the per-sprite work TH05 spends under many objects (the GRCG footprint erase, the plane-window sprite draw, and the EGC background restore) - against the REAL src/memory/sdram.v controller and the REAL pc9821_gvram (which OWNS the plain path, the WCB, the GRCG and the EGC), and reports WHERE the cycles go: the per-sprite cost of each shape, the backend transactions it issues, and the split between the client that serializes the four lanes and the SDRAM backend the coalescer already amortised. It also runs the whole scene with the SCANOUT fetching every raster line and asserts no line loses its 2014-clk_sys deadline under that load.
//
// WHY THIS EXISTS. An earlier measurement put the plane-window write at 3.8 MB/s against the machine's 13.8;
// The word-keyed write-combining buffer took the BACKEND cost of a four-plane column from
// 4.00 to 1.25 transactions but left the end-to-end rate at 4.1 MB/s and named the plain path's own
// client as the ceiling (~5.5 MB/s with a FREE backend). An earlier ranking put the client rewrite ("the
// four serialized lanes") as the largest graphics lever but L-effort/H-risk. This bench is the
// instrument that decides WHERE a busy scene actually spends its time, so the lever is chosen from
// a measurement rather than from the backend-only arithmetic.
//
// The 2014 clk_sys line budget is the machine's (848 dots x 440 lines at 21.0526 MHz).

`default_nettype none

module tb_pc9821_gfx_scene;
  localparam integer FREQ     = 50_000_000;
  localparam integer CYCLE_NS = 20;
  localparam [31:0]  GVRAM_BASE = 32'h0300_0000;

  localparam integer LINE_BUDGET = 2014;   // one raster line in clk_sys
  localparam integer FRAME_LINES = 440;    // one frame
  localparam integer LINE_COLS   = 80;     // bytes per plane row
  localparam integer RES_Y       = 400;    // visible raster lines (pc98.h)
  // The sprite: 16x16 dots = 2 plane bytes per row, 16 rows. One 16-bit word per row, which is
  // exactly the unit th01/formats/ptn_main.cpp and ect/egcrect.cpp move.
  localparam integer SPR_ROWS  = 16;
  localparam integer SPRS_PER_BAND = LINE_COLS / 2;   // 40 sprites across a 640-dot row

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

  

  

  // ==== BACKEND TRANSACTION COUNTERS ====
  integer cb_all = 0, cb_wr = 0, cb_rd = 0, cb_fullwr = 0, cb_partialwr = 0;
  // The SCANOUT's own SDRAM port (sb_*), counted apart from the GVRAM client so its share of the
  // read traffic is a measurement, not a guess.
  integer sb_reqs = 0, sb_beats = 0;
  // The GVRAM is block RAM now: there is no backend transaction and no scanout SDRAM
  // port to count, so these counters stay at zero and the traffic columns read as clk_sys alone.

  // ==== EGC UNIT COST (the measure the EGC FSM is judged by) ====
  // One CPU access that the EGC gate owns is one EGC unit. Counting the completed ones by their
  // direction is what makes "clk_sys per unit" a measurement and not a division: phase B issues a
  // 16-bit read unit and a 16-bit write unit per sprite row, and the two do not cost the same
  // (the read walks four D1 columns, the write presents its column pair as one request).
  integer egc_en = 0, egc_cyc = 0, egc_rd_units = 0, egc_wr_units = 0;
  always @(posedge clk) if (egc_en) begin
    egc_cyc <= egc_cyc + 1;
    if (cpu_ready && cpu_write) egc_wr_units <= egc_wr_units + 1;
    else if (cpu_ready)         egc_rd_units <= egc_rd_units + 1;
  end

  // ==== PHASE-B CYCLE SPLIT ====
  // The EGC's own state per cycle, plus the SDRAM controller's. One clk_sys/unit figure is not
  // enough to decide where the blit's cycles go: the same number is produced by a slow memory
  // path, by the CPU's bus cadence, or by the sequencer's own states. Histogrammed every cycle
  // the measured phase holds the EGC, so the three can be told apart.
  integer es_cnt [0:12];
  integer cs_cnt [0:10];
  integer bs_cnt [0:15];   // the GVRAM write-combining buffer / read-cache backend FSM
  integer b_cpu_hand = 0;   // S_IDLE + S_HOLD + S_RESP2: z486's own presentation cadence
  integer b_seq       = 0;   // S_EVAL/S_COMMIT + the four produce states: the sequencer's own work
  integer b_read_wait = 0;   // S_RD_RESP: the read burst's cl_done drain
  integer b_wr_wait   = 0;   // S_WR_B_ACC: the posted write burst's accept
  integer b_ctl_busy  = 0;   // cycles the SDRAM controller is not IDLE, over the phase
  reg     b_meas = 1'b0;
  always @(posedge clk) if (b_meas) begin
    es_cnt[dut.u_egc.state] <= es_cnt[dut.u_egc.state] + 1;
    bs_cnt[dut.u_arb.gstate] <= bs_cnt[dut.u_arb.gstate] + 1;
    case (dut.u_egc.state)
      4'd0, 4'd7, 4'd6: b_cpu_hand  <= b_cpu_hand  + 1;
      // The produce is four states (S_FEED/S_STEP_LO/S_STEP_HI plus the commit, which is
      // S_EVAL for a read and S_COMMIT for a write).
      4'd3, 4'd9, 4'd10, 4'd11, 4'd12: b_seq <= b_seq + 1;
      4'd2:             b_read_wait <= b_read_wait + 1;
      4'd8:             b_wr_wait   <= b_wr_wait   + 1;
      default: ;
    endcase
  end
  task automatic b_split_reset;
    integer k;
    begin
      for (k = 0; k <= 12; k = k + 1) es_cnt[k] = 0;
      for (k = 0; k <= 10; k = k + 1) cs_cnt[k] = 0;
      for (k = 0; k <= 15; k = k + 1) bs_cnt[k] = 0;
      b_cpu_hand = 0; b_seq = 0; b_read_wait = 0; b_wr_wait = 0; b_ctl_busy = 0;
    end
  endtask
  task automatic b_split_report(input [255:0] what);
    begin
      $display("NOTE gfx_scene: %0s EGC state cycles: IDLE=%0d RD_RESP=%0d EVAL=%0d RESP2=%0d HOLD=%0d WR_B_ACC=%0d FEED=%0d STEP_LO=%0d STEP_HI=%0d COMMIT=%0d",
               what, es_cnt[0], es_cnt[2], es_cnt[3], es_cnt[6], es_cnt[7], es_cnt[8],
               es_cnt[9], es_cnt[10], es_cnt[11], es_cnt[12]);
      $display("NOTE gfx_scene: %0s split clk_sys: cpu_cadence=%0d (%.1f/unit) memory_wait=%0d (%.1f/unit) sequencer=%0d (%.1f/unit)",
               what, b_cpu_hand, b_cpu_hand / 1280.0, b_read_wait + b_wr_wait,
               (b_read_wait + b_wr_wait) / 1280.0, b_seq, b_seq / 1280.0);
      $display("NOTE gfx_scene: %0s controller cycles: IDLE=%0d ACT=%0d READ=%0d RMW=%0d WRITE=%0d REFRESH=%0d WBURST=%0d WBURST_ACT=%0d busy=%0d",
               what, cs_cnt[2], cs_cnt[3], cs_cnt[4], cs_cnt[5], cs_cnt[6], cs_cnt[7], cs_cnt[9], cs_cnt[10], b_ctl_busy);
      $display("NOTE gfx_scene: %0s WCB cycles: IDLE=%0d HIT=%0d FILL=%0d FILLR=%0d RSET=%0d RD=%0d RDR=%0d RBC=%0d RCK=%0d WB4=%0d FLUSH=%0d EVICT=%0d",
               what, bs_cnt[0], bs_cnt[1], bs_cnt[6], bs_cnt[7], bs_cnt[8], bs_cnt[9],
               bs_cnt[10], bs_cnt[15], bs_cnt[14], bs_cnt[13], bs_cnt[11], bs_cnt[2] + bs_cnt[3]);
    end
  endtask

  integer errors = 0;
  task automatic fail(input [255:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS: the bus z486 presents (dword-aligned, lane in cpu_be) ====
  // A plain or EGC plane-window access. `egc` selects the owner (the EGC gate); the address is
  // {win_plane, win_offset} exactly as the memory_subsystem decodes it, and the plane byte offset
  // is {win_offset[14:2], lane} with the lane in cpu_be.
  task automatic plane_op(input [1:0] plane, input [14:0] off, input [31:0] din, input [3:0] be,
                          input wr, input egc, output [31:0] dout);
    begin
      @(negedge clk);
      egc_gate   = egc;
      win_plane  = plane;
      win_offset = off;
      cpu_din    = din;
      cpu_be     = be;
      cpu_write  = wr;
      cpu_valid  = 1'b1;
      // The accept is sampled at the NEGEDGE, one sample per cycle: cpu_ready is a one-cycle
      // level (C_RESP / G_RESP / the EGC's S_RESP), so a posedge+1ns sample can step over it.
      while (!cpu_ready) @(negedge clk);
      // z486 clears its request IN the ready cycle (memory.sv's `ext_valid_r` clear on `ready`,
      // src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`), so the request is released here and
      // not one cycle later. Holding it through the next cycle -- which the earlier
      // C_RESP2/C_HOLD tail absorbed unnoticed -- presents a SECOND, identical access to the
      // plain client, whose write arm is now C_IDLE + C_RESP; and since the pipelined produce
      // registers the read response one cycle after the ready (read values unchanged:
      // EGCREAD.CSV / the machine vectors), a read held into its response cycle is taken twice
      // by the EGC's S_IDLE accept (R6/R8). `egc_gate` is the machine's arming level (0x6A num 2
      // AND 0x7C bit 7), not a per-access signal: it is held through the response.
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
      if (!wr) begin
        while (!cpu_resp_valid) @(negedge clk);
        #1; dout = cpu_dout;
        @(negedge clk);
      end else begin
        dout = 32'd0;
      end
      egc_gate = 1'b0;
    end
  endtask

  // A 16-bit plane-window word read/write at plane offset `off` (even), on the plane `plane`.
  task automatic word_rd(input [1:0] plane, input [14:0] off, input egc, output [15:0] v);
    reg [31:0] d;
    begin
      plane_op(plane, off, 32'd0, (off[1] ? 4'b1100 : 4'b0011), 1'b0, egc, d);
      v = off[1] ? d[31:16] : d[15:0];
    end
  endtask
  task automatic word_wr(input [1:0] plane, input [14:0] off, input [15:0] v, input egc);
    reg [31:0] d;
    begin
      d = off[1] ? {v, 16'd0} : {16'd0, v};
      plane_op(plane, off, d, (off[1] ? 4'b1100 : 4'b0011), 1'b1, egc, d);
    end
  endtask

  // The GRCG register port (0x7C mode, 0x7E tiles), as the games write it.
  task automatic grcg_w(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk); grcg_we = 1; grcg_addr = a; grcg_din = d;
      @(negedge clk); grcg_we = 0;
    end
  endtask

  // ==== THE SCENE SHAPES ====
  // Sprite `idx` (0-based) sits in a band grid: 40 across, each 16 rows tall.
  function automatic [14:0] sprite_off(input integer idx, input integer row);
    begin
      sprite_off = 15'((((idx / SPRS_PER_BAND) * SPR_ROWS) + row) * LINE_COLS
                       + ((idx % SPRS_PER_BAND) * 2));
    end
  endfunction

  // ---- Phases F/G: TH05's own tile layer. ----
  // TILE_H/TILE_VRAM_W/TILES_X/TILES_Y/TILE_IMAGE_COUNT and PLAYFIELD_VRAM_LEFT are
  // th02/main/tile/tile.{inc,hpp} and th02/main/playfld.hpp; the atlas geometry is
  // th02/main/tile/tile.hpp's tile_image_vo().
  localparam integer TILE_H = 16, TILE_VRAM_W = 2, TILES_X = 24, TILES_Y = 25;
  localparam integer TILE_IMAGE_COUNT = 100, PLAYFIELD_VRAM_LEFT = 4;

  // The tile atlas: image [id] is a 2-byte-wide column at byte column 72 of a 16-row band, so
  // row [r] of it is TILE_H*LINE_COLS below the image's first row (tile_image_vo).
  function automatic [14:0] tile_atlas_vo(input integer id, input integer r);
    begin
      tile_atlas_vo = 15'((72 + (id / 25) * TILE_VRAM_W
                           + (id % 25) * (TILE_H * LINE_COLS)) + r * LINE_COLS);
    end
  endfunction

  // tiles_render_all() walks the ring from the playfield's bottom band upward, one 16-row tile
  // per 2-byte column (redraw.asm's `sub di, TILE_H*ROW_SIZE - TILE_VRAM_W`).
  function automatic [14:0] tile_dest_vo(input integer trow, input integer tcol, input integer r);
    begin
      tile_dest_vo = 15'(((RES_Y - TILE_H) * LINE_COLS + PLAYFIELD_VRAM_LEFT)
                         - trow * (TILE_H * LINE_COLS) + tcol * TILE_VRAM_W
                         + r * LINE_COLS);
    end
  endfunction

  // (a) The GRCG footprint erase: grcg_setcolor_rmw(0) + one 16-bit word write per row, which the
  // GRCG expands into a full four-plane column (the arms that take the ~5-6 clk_sys full-word path).
  task automatic scene_erase(input integer idx);
    integer row;
    begin
      grcg_w(8'h7C, 8'hC0);
      grcg_w(8'h7E, 8'h00); grcg_w(8'h7E, 8'h00);
      grcg_w(8'h7E, 8'h00); grcg_w(8'h7E, 8'h00);
      for (row = 0; row < SPR_ROWS; row = row + 1)
        word_wr(2'd0, sprite_off(idx, row), 16'hF0F0, 1'b0);
      grcg_w(8'h7C, 8'h00);
    end
  endtask

  // (b) The plane-window sprite draw (ptn_put_quarter_8): the sprite's four planes are read and
  // written back through their own windows with the GRCG off - the PLAIN path, two accesses per
  // plane per row, one column of one plane each.
  task automatic scene_draw(input integer idx);
    integer row, p;
    reg [15:0] w;
    begin
      for (row = 0; row < SPR_ROWS; row = row + 1) begin
        for (p = 0; p < 4; p = p + 1) begin
          word_rd(p[1:0], sprite_off(idx, row), 1'b0, w);
          word_wr(p[1:0], sprite_off(idx, row), w | 16'hF0F0, 1'b0);
        end
      end
    end
  endtask

  // (c) The EGC blit/restore (egc_copy_rect_1_to_0_16): one 16-dot chunk per row, read the source
  // page and write the destination page at the same plane offset, through the EGC.
  task automatic scene_egc_copy(input integer idx, input src_page);
    integer row;
    reg [15:0] w;
    begin
      egc_gate = 1'b1;
      egc_access = 16'hFFF0;
      egc_fgbg   = 16'h00FF;
      egc_ope    = 16'h3100;        // COMPAREREAD | WS_PATREG | RL_MEMREAD
      egc_mask   = 16'hFFFF;
      @(negedge clk); egc_sft = 16'h0000; egc_leng = 16'h000F; egc_shift_we = 1'b1;
      @(negedge clk); egc_shift_we = 1'b0;
      for (row = 0; row < SPR_ROWS; row = row + 1) begin
        access_page = src_page;
        word_rd(2'd0, sprite_off(idx, row), 1'b1, w);
        access_page = 1'b0;
        word_wr(2'd0, sprite_off(idx, row), w, 1'b1);
      end
      egc_gate = 1'b0;
    end
  endtask

  // ==== A SCANOUT LINE, TICKED AT THE RASTER CADENCE, WITH A BEAT COUNT ====
  // The bandwidth bench's session, run CONCURRENTLY with the sprite work so the two share the
  // controller exactly as they do in a game: a sprite frame is only busy because it overlaps the
  // raster.
  integer scan_lines = 0, scan_misses = 0, scan_min_cols = 9999, scan_worst = 0;
  reg     scan_run = 1'b0;
  reg     scan_dup = 1'b0;   // repeat each base twice (the 640x200 GDC doubling)
  integer scene_line = 0;

  // Runs concurrently with the sprite work: one tick per LINE_BUDGET clk_sys (the raster), and the
  // beats the window delivered. A window with fewer than 80 beats is a MISSED line - the scanout
  // lost its deadline to the sprite traffic on the shared controller.
  initial begin : scan_bg
    integer t0, cols, done;
    forever begin
      @(posedge clk);
      if (scan_run) begin
        @(negedge clk);
        scan_line_base = 15'(((scan_dup ? (scene_line >> 1) : scene_line) % 8) * LINE_COLS);
        scan_line_tick = 1'b1;
        @(negedge clk);
        scan_line_tick = 1'b0;
        t0 = cyc; cols = 0; done = -1;
        while ((cyc - t0) < LINE_BUDGET) begin
          @(posedge clk);
          if (dut.u_scan.fetch_req_d) begin
            cols = cols + 1;
            // The cycle the 80th column landed is the line's real fetch time; the window itself
            // is always LINE_BUDGET long, so the window length would be a vacuous "worst".
            if (cols == LINE_COLS && done < 0) done = cyc - t0;
          end
        end
        if (cols < LINE_COLS) scan_misses = scan_misses + 1;
        if (cols < scan_min_cols) scan_min_cols = cols;
        if (done >= 0 && done > scan_worst) scan_worst = done;
        scan_lines = scan_lines + 1;
        scene_line = scene_line + 1;
      end
    end
  end

  // ==== MEASUREMENT ====
  task automatic mark(output integer c, output integer a, output integer wr);
    begin
      c = cyc; a = cb_all; wr = cb_wr;
    end
  endtask

  integer i, n, c0, c1, t0, t1, w0, w1, phase_cyc, phase_txn;
  real    mbps;
  reg [15:0] got;
  integer bad;

  // Sprites per measured phase: enough that the fixed task overhead is small, few enough that the
  // run stays quick. 40 = one full band.
  localparam integer N_SPR = 40;

  initial begin
    reset  = 1'b1;
    repeat (8) @(posedge clk);
    i = 0;
    repeat (20) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);

    $display("NOTE gfx_scene: sprite = 16x16 dots = %0d-plane-byte rows x %0d, %0d sprites per measured phase",
             SPR_ROWS, 2, N_SPR);

    // ---- PHASE A: the plane-window sprite draw (PLAIN path, read + write per plane per row) ----
    mark(c0, t0, w0);
    for (n = 0; n < N_SPR; n = n + 1) scene_draw(n);
    mark(c1, t1, w1);
    phase_cyc = c1 - c0; phase_txn = t1 - t0;
    // Each sprite is 4 planes x 16 rows = 64 16-bit reads + 64 writes = 128 CPU accesses.
    $display("NOTE gfx_scene: A plain sprite draw: %0d sprites in %0d clk_sys = %0d clk_sys/sprite (%0.1f clk_sys per CPU access), %0d backend txn (%0.2f/sprite)",
             N_SPR, phase_cyc, phase_cyc / N_SPR, phase_cyc / (N_SPR * 128.0),
             phase_txn, phase_txn / (N_SPR + 0.0));
    mbps = (N_SPR * 128.0 * 2.0) * (FREQ / 1_000_000.0) / phase_cyc;
    $display("NOTE gfx_scene:   plane bytes moved: %0.1f MB/s (%0d plan bytes per phase)", mbps, N_SPR * 128 * 2);

    // ---- PHASE B: the EGC blit (page 1 -> page 0) ----
    b_split_reset; b_meas = 1'b1;
    egc_en = 1; egc_cyc = 0; egc_rd_units = 0; egc_wr_units = 0;
    mark(c0, t0, w0);
    for (n = 0; n < N_SPR; n = n + 1) scene_egc_copy(n, 1'b1);
    mark(c1, t1, w1);
    b_meas = 1'b0; b_split_report("B");
    egc_en = 0;
    phase_cyc = c1 - c0; phase_txn = t1 - t0;
    // One 16-dot EGC unit per row = 16 units per sprite.
    $display("NOTE gfx_scene: B EGC sprite blit (page1->page0): %0d sprites in %0d clk_sys = %0d clk_sys/sprite (%0.1f clk_sys per EGC unit), %0d backend txn (%0.2f/sprite)",
             N_SPR, phase_cyc, phase_cyc / N_SPR, phase_cyc / (N_SPR * 16.0),
             phase_txn, phase_txn / (N_SPR + 0.0));
    $display("NOTE gfx_scene: B EGC unit cost: %0d clk_sys for %0d units = %0.1f clk_sys/unit (%0d read units + %0d write units)",
             egc_cyc, egc_rd_units + egc_wr_units, egc_cyc / (egc_rd_units + egc_wr_units + 0.0),
             egc_rd_units, egc_wr_units);

    // ---- PHASE C: the EGC background restore (the same copy shape) ----
    b_split_reset; b_meas = 1'b1;
    mark(c0, t0, w0);
    for (n = 0; n < N_SPR; n = n + 1) scene_egc_copy(n, 1'b1);
    mark(c1, t1, w1);
    b_meas = 1'b0; b_split_report("C");
    phase_cyc = c1 - c0;
    $display("NOTE gfx_scene: C EGC background restore: %0d sprites in %0d clk_sys = %0d clk_sys/sprite",
             N_SPR, phase_cyc, phase_cyc / N_SPR);

    // ---- PHASE D: the FULL busy scene (erase + draw + restore) with the SCANOUT running ----
    scene_line   = 0;
    scan_lines   = 0; scan_misses = 0; scan_min_cols = 9999; scan_worst = 0;
    scan_enable  = 1'b1;
    scan_page    = 1'b0;
    scan_run     = 1'b1;
    mark(c0, t0, w0);
    for (n = 0; n < N_SPR; n = n + 1) begin
      scene_erase(n);
      scene_draw(n);
      scene_egc_copy(n, 1'b1);
    end
    mark(c1, t1, w1);
    scan_run    = 1'b0;
    scan_enable = 1'b0;
    phase_cyc = c1 - c0;
    $display("NOTE gfx_scene: D FULL busy scene (erase+draw+restore x %0d, scanout live): %0d clk_sys = %0d clk_sys/sprite, %0d backend txn",
             N_SPR, phase_cyc, phase_cyc / N_SPR, t1 - t0);
    $display("NOTE gfx_scene: D scene cycles as a fraction of one frame: %0d/%0d = %0d%%",
             phase_cyc, FRAME_LINES * LINE_BUDGET, (phase_cyc * 100) / (FRAME_LINES * LINE_BUDGET));
    $display("NOTE gfx_scene: D sprites that fit one frame at this rate: %0d",
             (FRAME_LINES * LINE_BUDGET) / (phase_cyc / N_SPR));
    $display("NOTE gfx_scene: D scanout during the scene: %0d lines, %0d missed, worst line fetch %0d clk_sys of %0d, min beats %0d/80",
             scan_lines, scan_misses, scan_worst, LINE_BUDGET, scan_min_cols);

    // ---- PHASE E: the scanout ALONE, DISTINCT vs DUPLICATE bases ----
    // The scanout's own SDRAM port traffic, counted apart from the GVRAM client. The 640x200
    // mode puts one GDC line on two raster lines, so the base repeats and the line is fetched
    // twice - BY the ping-pong contract (one advance per tick), not by waste. This shows the
    // scanout's share is small and that the apparent 'redundant' fetch is required.
    begin : phase_e
      integer e_t0, e_distinct, e_dup, d_lines, d_misses, d_min, d_worst, d_sbreq, d_sbeat;
      // The end-of-test checks read the D-phase counters: save them across phase E.
      d_lines = scan_lines; d_misses = scan_misses; d_min = scan_min_cols; d_worst = scan_worst;
      d_sbreq = sb_reqs; d_sbeat = sb_beats;
      scan_page = 1'b0;
      scene_line = 0; scan_lines = 0; sb_reqs = 0; sb_beats = 0; scan_dup = 1'b0;
      scan_enable = 1'b1; scan_run = 1'b1;
      e_t0 = cyc;
      while ((scan_lines < 16) && ((cyc - e_t0) < 20 * (LINE_BUDGET + 64))) @(posedge clk);
      scan_run = 1'b0;
      e_distinct = sb_reqs;
      scene_line = 0; scan_lines = 0; sb_reqs = 0; sb_beats = 0; scan_dup = 1'b1;
      scan_run = 1'b1;
      e_t0 = cyc;
      while ((scan_lines < 16) && ((cyc - e_t0) < 20 * (LINE_BUDGET + 64))) @(posedge clk);
      scan_run = 1'b0; scan_dup = 1'b0; scan_enable = 1'b0;
      e_dup = sb_reqs;
      $display("NOTE gfx_scene: E scanout 16 lines DISTINCT bases: %0d SDRAM requests", e_distinct);

      $display("NOTE gfx_scene: E scanout 16 lines DUPLICATE bases: %0d SDRAM requests", e_dup);
      $display("NOTE gfx_scene: E the 640x200 doubling re-fetches the same line: %0d vs %0d req",
                e_dup, e_distinct);

      // NOT an assertion: this is the EVIDENCE for the doubling. The 640x200 mode puts one GDC line
      // on two raster lines, and the ping-pong contract is one buffer advance per line tick
      // (tb_pc9821_gvram), so the second tick's buffer must hold the line too - the re-fetch
      // is by design, not waste. A skip was built and measured; it broke that contract.
      // Put the D-phase counters back: the attribution display and the end checks read them.
      scan_lines = d_lines; scan_misses = d_misses; scan_min_cols = d_min; scan_worst = d_worst;
      sb_reqs = d_sbreq; sb_beats = d_sbeat;
    end

    // ---- ATTRIBUTION: the client vs the backend, from the transaction counts ----
    $display("NOTE gfx_scene: backend write txns %0d (%0d full-word, %0d partial-byte), read txns %0d",
             cb_wr, cb_fullwr, cb_partialwr, cb_rd);
    $display("NOTE gfx_scene: SCANOUT port: %0d requests, %0d beats (%.1f beats/req) over the scene",
             sb_reqs, sb_beats, sb_reqs ? (sb_beats + 0.0) / sb_reqs : 0.0);
    if (cb_partialwr != 0)
      $display("NOTE gfx_scene: NOTE a partial-byte write reached the controller: the WCB issued a read-modify-write");
    else
      $display("NOTE gfx_scene: every GVRAM write reached the controller as ONE full word: the WCB removed the read-modify-write");

    // ---- FUNCTIONAL SANITY: the EGC blit actually copied the source page ----
    // Paint a known pattern on page 1, blit it to page 0, and read page 0 back through the plain
    // path (the coalescer's flush makes the page-0 bytes the blit committed).
    begin : sanity
      integer r, p;
      for (r = 0; r < SPR_ROWS; r = r + 1) begin
        access_page = 1'b1;
        word_wr(2'd0, sprite_off(0, r), 16'hA55A, 1'b0);
        access_page = 1'b0;
        word_wr(2'd0, sprite_off(0, r), 16'h0000, 1'b0);
      end
      scene_egc_copy(0, 1'b1);
      // One raster tick flushes the coalescer so the plain read sees the committed bytes.
      @(negedge clk); scan_enable = 1'b1; scan_line_tick = 1'b1;
      @(negedge clk); scan_line_tick = 1'b0;
      while (1'b0) @(posedge clk);
      scan_enable = 1'b0;
      bad = 0;
      for (r = 0; r < SPR_ROWS; r = r + 1) begin
        access_page = 1'b0;
        word_rd(2'd0, sprite_off(0, r), 1'b0, got);
        if (got !== 16'hA55A) bad = bad + 1;
      end
      if (bad != 0)
        fail("the EGC blit did not copy the source page: the busy-scene restore shape is wrong");
      $display("NOTE gfx_scene: EGC blit copy verified: %0d/%0d rows carry the source pattern", SPR_ROWS - bad, SPR_ROWS);
    end

    // ---- PHASES F/G: the two shapes TH05's TILE layer issues, which the sprite scene above
    // does not cover. F is tiles_render_all(): 600 16-row tiles, each
    // row a 2-byte read at the tile-atlas offset and a 2-byte write at the playfield offset, on
    // the SAME page, through the SAME 0x3100 copy the sprite blit uses. Run twice: pass 2's
    // read cache is what says whether a 100-image atlas (1600 words) stays resident behind the
    // playfield's own writes (write-no-allocate drops the cache's copy of a written word).
    // G is the playfield shake: egc_shift_left()'s 0x28F0 row shift at sft = 2, 24 words per 80-
    // byte row (the playfield is 384 dots wide) over 400 rows, the source read 2 bytes AHEAD of
    // the write. Both are TIMING instruments, not value checks; the value check is the sanity
    // block above.
    begin : th05_tile_shapes
      integer trow, tcol, r, pass, f0, f1, g0, g1, fr0, fr1, gr0, gr1;
      reg [15:0] w;
      // ---- F: tiles_render_all() ----
      egc_gate   = 1'b1;
      egc_access = 16'hFFF0; egc_fgbg = 16'h00FF; egc_ope = 16'h3100; egc_mask = 16'hFFFF;
      @(negedge clk); egc_sft = 16'h0000; egc_leng = 16'h000F; egc_shift_we = 1'b1;
      @(negedge clk); egc_shift_we = 1'b0;
      for (pass = 0; pass < 2; pass = pass + 1) begin
        fr0 = cb_rd;
        f0 = cyc;
        for (trow = 0; trow < TILES_Y; trow = trow + 1)
          for (tcol = 0; tcol < TILES_X; tcol = tcol + 1)
            for (r = 0; r < TILE_H; r = r + 1) begin
              word_rd(2'd0, tile_atlas_vo(((trow * 3) + tcol) % TILE_IMAGE_COUNT, r), 1'b1, w);
              word_wr(2'd0, tile_dest_vo(trow, tcol, r), w, 1'b1);
            end
        f1 = cyc; fr1 = cb_rd;
        $display("NOTE gfx_scene: F%0d tiles_render_all (600 tiles x 16 rows, same page): %0d clk_sys = %0d clk_sys/tile (%0.1f clk_sys per unit), %0d backend reads (%.1f/tile)",
                 pass, f1 - f0, (f1 - f0) / (TILES_Y * TILES_X),
                 (f1 - f0) / (TILES_Y * TILES_X * TILE_H * 2.0), fr1 - fr0,
                 (fr1 - fr0) / (TILES_Y * TILES_X + 0.0));
      end
      egc_gate = 1'b0;
      // ---- G: the playfield shake (egc_shift_left, TH05's double-left is 2 of these) ----
      egc_gate   = 1'b1;
      egc_access = 16'hFFF0; egc_fgbg = 16'h00FF; egc_ope = 16'h28F0; egc_mask = 16'hFFFF;
      @(negedge clk); egc_sft = 16'h0002; egc_leng = 16'h017F; egc_shift_we = 1'b1;
      @(negedge clk); egc_shift_we = 1'b0;
      gr0 = cb_rd;
      g0 = cyc;
      for (r = 0; r < RES_Y; r = r + 1)
        for (tcol = 0; tcol < TILES_X; tcol = tcol + 1) begin
          word_rd(2'd0, 15'(r * LINE_COLS + PLAYFIELD_VRAM_LEFT + tcol * 2), 1'b1, w);
          word_wr(2'd0, 15'(r * LINE_COLS + PLAYFIELD_VRAM_LEFT + tcol * 2 - 2), w, 1'b1);
        end
      g1 = cyc; gr1 = cb_rd;
      $display("NOTE gfx_scene: G playfield shake (0x28F0, sft=2, 400 rows x 24 words): %0d clk_sys = %0d clk_sys/row (%0.1f clk_sys per unit), %0d backend reads",
               g1 - g0, (g1 - g0) / RES_Y, (g1 - g0) / (RES_Y * TILES_X * 2.0), gr1 - gr0);
      egc_gate = 1'b0;
    end

    // ==== CHECKS ====
    // ---- the scene and the deadline ----
    if (scene_line == 0) fail("the scene ran no line at all: the measurement is vacuous");
    if (scan_lines == 0) fail("the scanout ran no line during the scene: the load was not measured");
    if (scan_misses != 0)
      fail("a scanout line MISSED its deadline under the busy-scene load: the flicker's cause is open again");
    if (scan_min_cols != LINE_COLS)
      fail("a scene line fetched fewer than 80 columns");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GFX_SCENE: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_GFX_SCENE: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_GFX_SCENE: FAIL");
    end
  end

  // ==== VERDICT BOUND ====
  initial begin
    #60_000_000;
    $fatal(1, "TB_PC9821_GFX_SCENE: FAIL (timed out)");
  end

endmodule

`default_nettype wire

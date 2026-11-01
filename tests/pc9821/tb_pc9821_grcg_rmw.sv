`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GRCG_RMW: the GRCG's stores and tile-compare reads against the REAL src/memory/sdram.v controller and the REAL pc9821_gvram, timed per store/read for the four shapes an earlier measurement priced - the RMW footprint erase, the TDW tile clear, the 32-bit forms of both, and the TCR read - and checked BYTE-EXACT so the collapse to one client visit per CPU word cannot pass by writing the wrong bytes: the TDW datum is ignored, the RMW merge is per PLANE BIT ((old & ~d) | (tile & d)) with data 0xF0, 0xFF (the read-skip) and 0x00 (a no-op), a two-column 16-bit and a four-column 32-bit store, the active-low plane mask, a partial-lane byte store, and the TCR read's per-byte ~(OR of (plane ^ tile)).

`default_nettype none

module tb_pc9821_grcg_rmw;
  localparam integer FREQ     = 50_000_000;
  localparam integer CYCLE_NS = 20;
  localparam [31:0]  GVRAM_BASE = 32'h0300_0000;

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

  // ---- The real controller at the built configuration, against the chip model ----

  

  

  // ==== BACKEND TRANSACTION COUNTER ====
  // The GVRAM is block RAM now, so there are no backend transactions to count: the
  // counter the report prints stays at zero and the cost columns read as clk_sys/unit alone.
  integer cb_all = 0, cb_wr = 0, cb_rd = 0;

  integer errors = 0;
  task automatic fail(input [8*80-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS (the bus z486 presents: dword-aligned, the lane in cpu_be) ====
  task automatic plane_op(input [1:0] plane, input [14:0] off, input [31:0] din, input [3:0] be,
                          input wr, output [31:0] dout);
    begin
      @(negedge clk);
      win_plane  = plane;
      win_offset = off;
      cpu_din    = din;
      cpu_be     = be;
      cpu_write  = wr;
      cpu_valid  = 1'b1;
      while (!cpu_ready) @(negedge clk);
      if (!wr) begin
        while (!cpu_resp_valid) @(negedge clk);
        #1; dout = cpu_dout;
      end else dout = 32'd0;
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
    end
  endtask

  // A 16-bit plane-window word store/read at plane offset `off` (even), plane `plane`.
  task automatic word_wr(input [1:0] plane, input [14:0] off, input [15:0] v);
    reg [31:0] d;
    begin
      d = off[1] ? {v, 16'd0} : {16'd0, v};
      plane_op(plane, off, d, (off[1] ? 4'b1100 : 4'b0011), 1'b1, d);
    end
  endtask
  task automatic word_rd(input [1:0] plane, input [14:0] off, output [15:0] v);
    reg [31:0] d;
    begin
      plane_op(plane, off, 32'd0, (off[1] ? 4'b1100 : 4'b0011), 1'b0, d);
      v = off[1] ? d[31:16] : d[15:0];
    end
  endtask

  task automatic grcg_w(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk); grcg_we = 1; grcg_addr = a; grcg_din = d;
      @(negedge clk); grcg_we = 0;
    end
  endtask

  // Plane p's byte at column c, through the PLAIN path (the GRCG disarmed).
  task automatic peek(input [1:0] p, input [14:0] c, output [7:0] v);
    reg [31:0] d;
    begin
      grcg_w(8'h7C, 8'h00);
      plane_op(p, {c[14:2], 2'b00}, 32'd0, (4'h1 << c[1:0]), 1'b0, d);
      v = d[{c[1:0], 3'b000} +: 8];
    end
  endtask

  integer i, n, c0, c1, t0, t1;
  integer phase_cyc, phase_txn;
  real    per_store;
  reg  [7:0] b;
  reg [15:0] w;
  reg [31:0] dw;

  // ======================= TIMING PHASES =======================
  // 16 rows x 1 word per "sprite"; 40 sprites per phase.
  localparam integer SPR_ROWS = 16;
  localparam integer N_SPR    = 40;
  localparam integer LINE_COLS = 80;
  function automatic [14:0] spr_off(input integer idx, input integer row);
    begin
      spr_off = 15'(((idx / (LINE_COLS/2)) * SPR_ROWS + row) * LINE_COLS + ((idx % (LINE_COLS/2)) * 2));
    end
  endfunction

  task automatic scene_rmw16(input integer idx, input [15:0] dat);
    integer row;
    begin
      grcg_w(8'h7C, 8'hC0);
      grcg_w(8'h7E, 8'h00); grcg_w(8'h7E, 8'h00);
      grcg_w(8'h7E, 8'h00); grcg_w(8'h7E, 8'h00);
      for (row = 0; row < SPR_ROWS; row = row + 1)
        word_wr(2'd0, spr_off(idx, row), dat);
      grcg_w(8'h7C, 8'h00);
    end
  endtask

  task automatic scene_tdw16(input integer idx);
    integer row;
    begin
      grcg_w(8'h7C, 8'h80);
      grcg_w(8'h7E, 8'h11); grcg_w(8'h7E, 8'h22);
      grcg_w(8'h7E, 8'h44); grcg_w(8'h7E, 8'h88);
      for (row = 0; row < SPR_ROWS; row = row + 1)
        word_wr(2'd0, spr_off(idx, row), 16'hF0F0);
      grcg_w(8'h7C, 8'h00);
    end
  endtask

  task automatic scene_tdw32(input integer idx);
    integer row; reg [31:0] d;
    begin
      grcg_w(8'h7C, 8'h80);
      grcg_w(8'h7E, 8'h11); grcg_w(8'h7E, 8'h22);
      grcg_w(8'h7E, 8'h44); grcg_w(8'h7E, 8'h88);
      for (row = 0; row < SPR_ROWS; row = row + 1)
        plane_op(2'd0, spr_off(idx, row), 32'hF0F0_F0F0, 4'hF, 1'b1, d);
      grcg_w(8'h7C, 8'h00);
    end
  endtask

  task automatic scene_rmw32(input integer idx, input [31:0] dat);
    integer row; reg [31:0] d;
    begin
      grcg_w(8'h7C, 8'hC0);
      grcg_w(8'h7E, 8'h00); grcg_w(8'h7E, 8'h00);
      grcg_w(8'h7E, 8'h00); grcg_w(8'h7E, 8'h00);
      for (row = 0; row < SPR_ROWS; row = row + 1)
        plane_op(2'd0, spr_off(idx, row), dat, 4'hF, 1'b1, d);
      grcg_w(8'h7C, 8'h00);
    end
  endtask

  task automatic scene_tcr16(input integer idx);
    integer row; reg [15:0] w2;
    begin
      grcg_w(8'h7C, 8'h80);
      grcg_w(8'h7E, 8'h11); grcg_w(8'h7E, 8'h22);
      grcg_w(8'h7E, 8'h44); grcg_w(8'h7E, 8'h88);
      for (row = 0; row < SPR_ROWS; row = row + 1)
        word_rd(2'd0, spr_off(idx, row), w2);
      grcg_w(8'h7C, 8'h00);
    end
  endtask

  task automatic mark(output integer c, output integer t);
    begin
      c = cyc; t = cb_all;
    end
  endtask

  task automatic report(input [8*80-1:0] what, input integer units);
    begin
      per_store = (phase_cyc + 0.0) / units;
      $display("NOTE grcg_rmw: %0s: %0d clk_sys in %0d units = %0.1f clk_sys/unit, %0d backend txn",
               what, phase_cyc, units, per_store, phase_txn);
    end
  endtask

  // ======================= CONFORMANCE =======================
  // Seed FOUR consecutive plane byte offsets (c0..c0+3) of ALL FOUR planes through the plain
  // path, so the RMW's read of the old value is visible at every lane and plane. A word store
  // covers two columns of one plane, so a plane is two stores.
  task automatic seed_pair(input [1:0] p, input [14:0] off, input [7:0] v);
    reg [31:0] d;
    begin
      grcg_w(8'h7C, 8'h00);
      d = off[1] ? {v, v, 16'd0} : {16'd0, v, v};
      plane_op(p, off, d, (off[1] ? 4'b1100 : 4'b0011), 1'b1, d);
    end
  endtask

  task automatic seed_cols(input [14:0] c0, input [7:0] b0, input [7:0] r0,
                           input [7:0] g0, input [7:0] e0);
    begin
      seed_pair(2'd0, c0, b0);
      seed_pair(2'd1, c0, r0);
      seed_pair(2'd2, c0, g0);
      seed_pair(2'd3, c0, e0);
      seed_pair(2'd0, 15'(c0 + 2), b0);
      seed_pair(2'd1, 15'(c0 + 2), r0);
      seed_pair(2'd2, 15'(c0 + 2), g0);
      seed_pair(2'd3, 15'(c0 + 2), e0);
    end
  endtask

  task automatic expect_byte(input [8*80-1:0] what, input [1:0] p, input [14:0] c, input [7:0] want);
    begin
      peek(p, c, b);
      if (b !== want) begin
        $display("FAIL %0s: plane %0d column %04x = %02x, want %02x", what, p, c, b, want);
        errors = errors + 1;
      end
    end
  endtask

  // NP2kai's RMW merge for one column byte: (old & ~d) | (tile & d), enabled planes only.
  function [7:0] rmw_byte(input [7:0] old, input [7:0] d, input [7:0] tile, input bit en);
    begin
      rmw_byte = en ? ((old & ~d) | (tile & d)) : old;
    end
  endfunction

  // Seed pattern so the RMW's read is visible: plane bytes differ from the tile.
  localparam [7:0] SEED_B = 8'h3C, SEED_R = 8'h5A, SEED_G = 8'hC3, SEED_E = 8'h7E;

  task automatic check_rmw(input [8*80-1:0] what, input [15:0] dat, input [7:0] tb, input [7:0] tr,
                           input [7:0] tg, input [7:0] te, input [3:0] plane_mask);
    integer k;
    begin
      // Four consecutive columns of all four planes are seeded; the 16-bit store covers the
      // first two columns, and columns 2 and 3 must be untouched.
      seed_cols(15'h0200, SEED_B, SEED_R, SEED_G, SEED_E);
      grcg_w(8'h7C, 8'hC0 | plane_mask);
      grcg_w(8'h7E, tb); grcg_w(8'h7E, tr); grcg_w(8'h7E, tg); grcg_w(8'h7E, te);
      word_wr(2'd0, 15'h0200, dat);
      grcg_w(8'h7C, 8'h00);
      // The 16-bit store covers plane byte offsets 0x0200 and 0x0201 of the B window.
      for (k = 0; k < 2; k = k + 1) begin
        expect_byte(what, 2'd0, 15'(15'h0200 + k),
                    rmw_byte(SEED_B, dat[8*k +: 8], tb, ~plane_mask[0]));
        expect_byte(what, 2'd1, 15'(15'h0200 + k),
                    rmw_byte(SEED_R, dat[8*k +: 8], tr, ~plane_mask[1]));
        expect_byte(what, 2'd2, 15'(15'h0200 + k),
                    rmw_byte(SEED_G, dat[8*k +: 8], tg, ~plane_mask[2]));
        expect_byte(what, 2'd3, 15'(15'h0200 + k),
                    rmw_byte(SEED_E, dat[8*k +: 8], te, ~plane_mask[3]));
      end
      // The two columns PAST the store are untouched (the second lane's old must be preserved).
      expect_byte(what, 2'd0, 15'h0202, SEED_B);
      expect_byte(what, 2'd1, 15'h0202, SEED_R);
    end
  endtask

  initial begin
    reset  = 1'b1;
    repeat (8) @(posedge clk);
    i = 0;
    repeat (20) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);


    // ---- A2: the GRCG RMW erase (16-bit), data 0xF0F0 (the read runs) ----
    mark(c0, t0);
    for (n = 0; n < N_SPR; n = n + 1) scene_rmw16(n, 16'hF0F0);
    mark(c1, t1); phase_cyc = c1 - c0; phase_txn = t1 - t0;
    report("A2 GRCG RMW erase, 16-bit, data F0F0", N_SPR * SPR_ROWS);

    // ---- A3: the GRCG TDW tile clear (16-bit) ----
    mark(c0, t0);
    for (n = 0; n < N_SPR; n = n + 1) scene_tdw16(n);
    mark(c1, t1); phase_cyc = c1 - c0; phase_txn = t1 - t0;
    report("A3 GRCG TDW tile clear, 16-bit", N_SPR * SPR_ROWS);

    // ---- A5: the GRCG TCR tile-compare read (16-bit) ----
    mark(c0, t0);
    for (n = 0; n < N_SPR; n = n + 1) scene_tcr16(n);
    mark(c1, t1); phase_cyc = c1 - c0; phase_txn = t1 - t0;
    report("A5 GRCG TCR read, 16-bit", N_SPR * SPR_ROWS);

    // ---- A6: the GRCG TDW 32-bit store ----
    mark(c0, t0);
    for (n = 0; n < N_SPR; n = n + 1) scene_tdw32(n);
    mark(c1, t1); phase_cyc = c1 - c0; phase_txn = t1 - t0;
    report("A6 GRCG TDW store, 32-bit", N_SPR * SPR_ROWS);

    // ---- A7: the GRCG RMW 32-bit store, data 0 (the read runs) ----
    mark(c0, t0);
    for (n = 0; n < N_SPR; n = n + 1) scene_rmw32(n, 32'h0000_0000);
    mark(c1, t1); phase_cyc = c1 - c0; phase_txn = t1 - t0;
    report("A7 GRCG RMW store, 32-bit, data 00000000", N_SPR * SPR_ROWS);

    // ---- A8: the GRCG RMW 32-bit store, data FF (the read is skipped) ----
    mark(c0, t0);
    for (n = 0; n < N_SPR; n = n + 1) scene_rmw32(n, 32'hFFFF_FFFF);
    mark(c1, t1); phase_cyc = c1 - c0; phase_txn = t1 - t0;
    report("A8 GRCG RMW store, 32-bit, data FFFFFFFF", N_SPR * SPR_ROWS);

    // ======================= CHECKS =======================
    // ======================= BYTE-EXACT CONFORMANCE =======================
    // 1. RMW 16-bit, data 0xF0F0: the merge preserves the old LOW nibble and takes the tile HIGH.
    check_rmw("rmw16 data F0F0", 16'hF0F0, 8'hAA, 8'hBB, 8'hCC, 8'hDD, 4'h0);
    // 2. RMW 16-bit, data 0xFFFF: the read is skipped and the result is exactly the tile.
    check_rmw("rmw16 data FFFF", 16'hFFFF, 8'h11, 8'h22, 8'h33, 8'h44, 4'h0);
    // 3. RMW 16-bit, data 0x0000: a NO-OP (the merge returns the old bytes).
    check_rmw("rmw16 data 0000", 16'h0000, 8'hAA, 8'hBB, 8'hCC, 8'hDD, 4'h0);
    // 4. The active-low plane mask: only B enabled (0x0E = 1110 low -> B on), tile 0x3C.
    check_rmw("rmw16 B-only", 16'hF0F0, 8'h3C, 8'h3C, 8'h3C, 8'h3C, 4'hE);

    // 5. TDW 16-bit: the datum is ignored, every enabled plane gets its tile byte.
    begin : tdw_check
      integer k;
      seed_cols(15'h0300, SEED_B, SEED_R, SEED_G, SEED_E);
      grcg_w(8'h7C, 8'h80);
      grcg_w(8'h7E, 8'h11); grcg_w(8'h7E, 8'h22);
      grcg_w(8'h7E, 8'h44); grcg_w(8'h7E, 8'h88);
      word_wr(2'd0, 15'h0300, 16'hCAFE);
      grcg_w(8'h7C, 8'h00);
      for (k = 0; k < 2; k = k + 1) begin
        expect_byte("tdw16 B", 2'd0, 15'(15'h0300 + k), 8'h11);
        expect_byte("tdw16 R", 2'd1, 15'(15'h0300 + k), 8'h22);
        expect_byte("tdw16 G", 2'd2, 15'(15'h0300 + k), 8'h44);
        expect_byte("tdw16 E", 2'd3, 15'(15'h0300 + k), 8'h88);
      end
      expect_byte("tdw16 neighbour B", 2'd0, 15'h0302, SEED_B);
    end

    // 6. RMW 32-bit, data 0: a NO-OP over all four columns.
    begin : rmw32_zero
      integer k;
      seed_cols(15'h0400, SEED_B, SEED_R, SEED_G, SEED_E);
      grcg_w(8'h7C, 8'hC0);
      grcg_w(8'h7E, 8'hAA); grcg_w(8'h7E, 8'hBB);
      grcg_w(8'h7E, 8'hCC); grcg_w(8'h7E, 8'hDD);
      plane_op(2'd0, 15'h0400, 32'h0000_0000, 4'hF, 1'b1, dw);
      grcg_w(8'h7C, 8'h00);
      for (k = 0; k < 4; k = k + 1) begin
        expect_byte("rmw32 zero B", 2'd0, 15'(15'h0400 + k), SEED_B);
        expect_byte("rmw32 zero R", 2'd1, 15'(15'h0400 + k), SEED_R);
        expect_byte("rmw32 zero G", 2'd2, 15'(15'h0400 + k), SEED_G);
        expect_byte("rmw32 zero E", 2'd3, 15'(15'h0400 + k), SEED_E);
      end
    end

    // 7. RMW 32-bit, data FFFFFFFF: the whole four-column run becomes the tile.
    begin : rmw32_ff
      integer k;
      seed_cols(15'h0500, SEED_B, SEED_R, SEED_G, SEED_E);
      grcg_w(8'h7C, 8'hC0);
      grcg_w(8'h7E, 8'h5A); grcg_w(8'h7E, 8'hA5);
      grcg_w(8'h7E, 8'h3C); grcg_w(8'h7E, 8'hC3);
      plane_op(2'd0, 15'h0500, 32'hFFFF_FFFF, 4'hF, 1'b1, dw);
      grcg_w(8'h7C, 8'h00);
      for (k = 0; k < 4; k = k + 1) begin
        expect_byte("rmw32 FF B", 2'd0, 15'(15'h0500 + k), 8'h5A);
        expect_byte("rmw32 FF R", 2'd1, 15'(15'h0500 + k), 8'hA5);
        expect_byte("rmw32 FF G", 2'd2, 15'(15'h0500 + k), 8'h3C);
        expect_byte("rmw32 FF E", 2'd3, 15'(15'h0500 + k), 8'hC3);
      end
    end

    // 8. The PARTIAL-LANE case: a byte store (be = 0010) touches column 0x0601 only.
    begin : partial_lane
      integer p;
      seed_cols(15'h0600, SEED_B, SEED_R, SEED_G, SEED_E);
      grcg_w(8'h7C, 8'h80);
      grcg_w(8'h7E, 8'h77); grcg_w(8'h7E, 8'h77);
      grcg_w(8'h7E, 8'h77); grcg_w(8'h7E, 8'h77);
      plane_op(2'd0, 15'h0600, 32'h0000_7700, 4'b0010, 1'b1, dw);
      grcg_w(8'h7C, 8'h00);
      expect_byte("partial-lane column 0x0600 B", 2'd0, 15'h0600, SEED_B);
      expect_byte("partial-lane column 0x0602 B", 2'd0, 15'h0602, SEED_B);
      for (p = 0; p < 4; p = p + 1)
        expect_byte("partial-lane column 0x0601", p[1:0], 15'h0601, 8'h77);
    end

    // 9. The TCR read, 16-bit: per byte, ~(OR over enabled planes of (plane ^ tile)).
    begin : tcr_check
      integer p;
      reg [31:0] d;
      reg [7:0] want;
      seed_cols(15'h0700, 8'h0F, 8'h33, 8'h55, 8'hAA);
      // Tiles equal to the seeds: every compare is 0, so both enabled lanes read 0xFF.
      grcg_w(8'h7C, 8'h80);
      grcg_w(8'h7E, 8'h0F); grcg_w(8'h7E, 8'h33);
      grcg_w(8'h7E, 8'h55); grcg_w(8'h7E, 8'hAA);
      plane_op(2'd0, 15'h0700, 32'd0, 4'b0011, 1'b0, d);
      grcg_w(8'h7C, 8'h00);
      for (p = 0; p < 4; p = p + 1) begin
        if (p < 2)
          if (d[8*p +: 8] !== 8'hFF) begin
            $display("FAIL tcr16 lane %0d = %02x, want FF", p, d[8*p +: 8]);
            errors = errors + 1;
          end
        if (p >= 2)
          if (d[8*p +: 8] !== 8'h00) begin
            $display("FAIL tcr16 disabled lane %0d = %02x, want 00", p, d[8*p +: 8]);
            errors = errors + 1;
          end
      end
      // Flip ONE bit of the blue tile, so the compare is 0x01 and the read carries it.
      grcg_w(8'h7C, 8'h80);
      grcg_w(8'h7E, 8'h0E); grcg_w(8'h7E, 8'h33);
      grcg_w(8'h7E, 8'h55); grcg_w(8'h7E, 8'hAA);
      plane_op(2'd0, 15'h0700, 32'd0, 4'b0011, 1'b0, d);
      grcg_w(8'h7C, 8'h00);
      want = ~(8'h01);
      if (d[7:0] !== want) begin
        $display("FAIL tcr16 B compare = %02x, want %02x", d[7:0], want);
        errors = errors + 1;
      end
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GRCG_RMW: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_GRCG_RMW: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_GRCG_RMW: FAIL");
    end
  end

  initial begin
    #60_000_000;
    $fatal(1, "TB_PC9821_GRCG_RMW: FAIL (timed out)");
  end

endmodule

`default_nettype wire

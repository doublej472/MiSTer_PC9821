`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GFX_THROUGHPUT: the GVRAM store path measured where the frame budget feels it - the WALL CLOCK of a BACK-TO-BACK store stream, not a single store's CPU hold (no longer the cost). The stream presents the next CPU store the cycle its predecessor's ready is seen, which is z486's own shape, so what is measured is the array's throughput plus whatever the engine adds around it: `clk_sys per store` printed beside the array's own port-A access count for the same stream. A store that is one clk_sys shorter must not have dropped a lane, so every shape's access count is a FLOOR GUARD and every shape's result is read back byte-exact (the GRCG merge, the TDW tile, the active-low plane mask). The six shapes are TH05's: its per-frame sprite traffic is GRCG RMW (the capture's GT - TDW - reads zero in gameplay), with the 0xFF-datum pair-burst read-skip and the two-column TDW burst as the other arms. FAIL-FIRST: the bounds are this bench's measurement on the pre-change tree plus nothing - a store used to spend one clk_sys being PRESENTED before the walk's first lane, so every shape is 1 clk_sys/store slower there and every bound below fails.
//
// WHY A STREAM AND NOT A HOLD. The core decouples the store's ready from the walk, so a single
// store's CPU hold is 0 and that number cannot move again. The render's cost is the stream: the
// CPU presents the next store while the previous walk drains, and it is not accepted until the
// client's FSM is free, so the pass's wall clock is (stores x per-store throughput). That is the
// number this bench holds, and it is why a one-clk_sys presentation bubble is 17 % of the
// sprite-erase shape.

`default_nettype none

module tb_pc9821_gfx_throughput;
  localparam integer CYCLE_NS = 20;

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg reset = 1;

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

  // ==== THE ARRAY'S PORT A ====
  // One clk_sys with the M10K's port A enabled is one array access. The scanout's port B is off for
  // the whole bench, so every counted enable is a store stream's.
  integer acc_cnt = 0;
  always @(posedge clk) if (dut.gma_en) acc_cnt <= acc_cnt + 1;
  integer cyc_cnt = 0;
  always @(posedge clk) cyc_cnt <= cyc_cnt + 1;

  integer errors = 0;

  task automatic fail(input [8*160-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS ====
  task automatic port_w(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk);
      grcg_addr = a; grcg_din = d; grcg_we = 1;
      @(negedge clk); grcg_we = 0;
    end
  endtask

  task automatic put_tiles(input [7:0] b, input [7:0] r, input [7:0] g, input [7:0] e);
    begin
      port_w(8'h7E, b); port_w(8'h7E, r); port_w(8'h7E, g); port_w(8'h7E, e);
    end
  endtask

  // Every owner back to idle: the array FSM, the GRCG's sequencer, the EGC's produce and the plain
  // client's column walk.
  task automatic drain;
    begin
      // EVERY OWNER IDLE AND THE GVRAM'S OWN ACCEPTANCE PERIOD SPENT. pc9821_gvram_arb's
      // GVRAM_PERIODS makes a GVRAM access cost the machine's per-operation TIME; a stream that
      // began in the middle of the previous operation's period would carry that period into its
      // first interval and mis-price the shape.
      while ((dut.u_arb.gstate != 3'd0) || dut.u_arb.m_mode || (dut.u_arb.cs != 4'd0) ||
             (dut.u_grcg.gstate != 4'd0) || (dut.u_egc.state != 4'd0) ||
             (dut.u_arb.hold_left != 16'd0)) @(posedge clk);
      repeat (2) @(posedge clk);
    end
  endtask

  // A plain (GRCG and EGC disarmed) byte store, to seed a plane.
  task automatic plain_byte(input [1:0] plane, input [14:0] col, input [7:0] v);
    begin
      egc_gate = 0;
      port_w(8'h7C, 8'h00);
      @(negedge clk);
      win_plane = plane; win_offset = {col[14:2], 2'b00};
      cpu_din = {8'h00, 8'h00, 8'h00, v} << {col[1:0], 3'b000};
      cpu_be = (4'h1 << col[1:0]); cpu_write = 1; cpu_valid = 1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk); cpu_valid = 0; cpu_write = 0; cpu_be = 4'hF;
      drain;
    end
  endtask

  // Plane p's byte at column c, through the PLAIN path (the GRCG and EGC disarmed).
  task automatic peek(input [1:0] p, input [14:0] c, output [7:0] v);
    reg [31:0] d;
    begin
      egc_gate = 0;
      port_w(8'h7C, 8'h00);
      @(negedge clk);
      win_plane = p; win_offset = {c[14:2], 2'b00};
      cpu_din = 32'd0; cpu_be = (4'h1 << c[1:0]); cpu_write = 0; cpu_valid = 1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      while (!cpu_resp_valid) @(negedge clk);
      #1; d = cpu_dout;
      @(negedge clk); cpu_valid = 0; cpu_be = 4'hF;
      drain;
      v = d[{c[1:0], 3'b000} +: 8];
    end
  endtask

  // ---- THE MEASUREMENT: the back-to-back STORE STREAM ----
  // `n` stores, each one column apart, the next presented the cycle the previous one's ready is
  // seen (z486's shape: it completes an external store ON the ready and re-presents at once). The
  // CPU's own hold is NOT counted - the decoupled store made it 0, and this bench is about the wall clock the
  // array imposes on the stream, which is what a sprite pass's duration is made of. `accs` is the
  // port-A enables over the whole stream, taken after every owner has drained.
  task automatic stream_store(input integer n, input [1:0] plane, input [14:0] base,
                              input [31:0] din, input [3:0] be,
                              output integer cycles, output integer accs);
    integer k, c0, a0;
    begin
      drain;
      c0 = cyc_cnt; a0 = acc_cnt;
      for (k = 0; k < n; k = k + 1) begin
        @(negedge clk);
        win_plane = plane; win_offset = base + {k[12:0], 2'b00};
        cpu_din = din; cpu_be = be;
        cpu_write = 1; cpu_valid = 1;
        @(posedge clk); #1;
        while (!cpu_ready) begin @(posedge clk); #1; end
      end
      @(negedge clk); cpu_valid = 0; cpu_write = 0; cpu_be = 4'hF;
      drain;
      cycles = cyc_cnt - c0; accs = acc_cnt - a0;
      repeat (2) @(posedge clk);
    end
  endtask

  // ---- THE PATTERNS ----
  localparam [14:0] BASE  = 15'h0800;
  localparam [1:0]  PLANE = 2'd0;
  localparam integer N    = 256;    // stores per stream
  localparam integer SLACK = 16;    // the stream's own fixed overhead (presentation + drain)

  localparam integer NS = 6;
  integer cyc[NS], acc[NS], want_acc[NS], max_cyc[NS];
  reg [8*72-1:0] sname[NS];
  integer k, i, n;
  reg [7:0] bv;

  // The merge the GRCG RMW performs on a plane byte: (old & ~d) | (tile & d), per PLANE BIT.
  function [7:0] rmw(input [7:0] old, input [7:0] d, input [7:0] tile);
    begin
      rmw = (old & ~d) | (tile & d);
    end
  endfunction

  // Seed all four planes of the columns a stream will write, so every shape has something
  // non-trivial to merge and the read-back can tell a dropped lane from a written one.
  task automatic seed_row(input [14:0] base, input integer ncols);
    integer q;
    begin
      for (q = 0; q < ncols; q = q + 1) begin
        plain_byte(2'd0, base + q, 8'h3C);
        plain_byte(2'd1, base + q, 8'h5A);
        plain_byte(2'd2, base + q, 8'hC3);
        plain_byte(2'd3, base + q, 8'h7E);
      end
      drain;
    end
  endtask

  localparam [7:0] T_B = 8'h11, T_R = 8'h22, T_G = 8'h44, T_E = 8'h88;

  task automatic describe;
    begin
      sname[0] = "S1 GRCG RMW 16-bit, all planes, mixed datum";
      sname[1] = "S2 GRCG RMW 32-bit, all planes, mixed datum";
      sname[2] = "S3 GRCG RMW 16-bit, all planes, datum FFFF (pair burst)";
      sname[3] = "S4 GRCG RMW 16-bit, B plane only, datum FFFF";
      sname[4] = "S5 GRCG TDW 32-bit, all planes (pair burst)";
      sname[5] = "S6 GRCG TDW 16-bit, all planes (pair burst)";
      // Array accesses for ONE store: the work itself. A shorter wall clock must not move these.
      want_acc[0] = 4;   // two live lanes, each read then written
      want_acc[1] = 8;   // four live lanes, same
      want_acc[2] = 2;   // one two-word request: the 0xFF datum needs no read
      want_acc[3] = 2;
      want_acc[4] = 4;   // two column pairs, one two-word request each
      want_acc[5] = 2;
      // The per-store bound is the CAPTURE'S, not this bench's best tree. A GRCG store is priced at
      // the machine's own per-operation cost: docs/probes/GFX2.TXT's GRCG_RMW row
      // (4614 - 2952 ns) / 16 stores = 103.9 ns = 5 clk_sys at 50 MHz, which is also the measured
      // presentation-bubble number - so a bound of 6 keeps BOTH floors (the walk's own accesses
      // and the machine's period), and fails on the pre-change tree's 5 (S1), 3 (S3/S4/S6) and
      // 6 (S5) through the period, never through a dropped lane (want_acc above is that guard).
      //
      // ONE PERIOD PER CPU STORE, NOT PER REQUEST. A dword TDW store is served by the GRCG as TWO
      // client requests (two column pairs), but pc9821_gvram_arb arms the period only on the
      // request its capture cycle presents (`grcg_cl_cap || gr_arm_pend`): the second pair is
      // presented with `cl_cap` LOW and the pend already consumed, so it merely WAITS OUT what
      // remains of the first period and the store costs one period plus the second pair's own
      // two-word walk - which is why S5's bound is 8 and not 12 (12 was this bench's measurement
      // under the intermediate model, before that arming rule landed). tb_pc9821_gvram_porta_equiv
      // encodes the same rule (its second pair is at acc + GVRAM_GR_HOLD and the path is next free
      // at +GVRAM_GR_HOLD + 2) and would fail if the second pair re-armed.
      // RE-PINNED (docs/trade-candidates.md T28): the GRCG's presentation is now
      // the REGISTERED one, which takes the route decode off the GVRAM write-enable's clk_sys
      // cone and adds exactly ONE clk_sys to the walk. These two bounds were this bench's own
      // PRE-change measurement, not a machine number (the machine's GRCG_RMW row is 5 clk at
      // 50 MHz, which the stream never met - the walk is what paces it); measured with the arm
      // restored and the presentation deferred: S2 9.01 -> 10.01, S5 9.01 -> 10.01 clk_sys/store,
      // with every array access count unchanged.
      max_cyc[0] = 6;    // GRCG_RMW's own row, 103.9 ns at 50 MHz (unchanged: 6.01 measured)
      max_cyc[1] = 10;   // RE-PINNED for trade T28: the registered presentation adds exactly
                         // one clk_sys to the walk, 9.01 -> 10.01 (the walk, not the
                         // period, paces this shape; access count unchanged at 8)
      max_cyc[2] = 6;    // the pair burst is one request: one period (was 3)
      max_cyc[3] = 6;    // (was 3)
      max_cyc[4] = 10;   // RE-PINNED for trade T28: 8.01 -> 10.01 with the registered presentation
      max_cyc[5] = 6;    // (was 3)
    end
  endtask

  // ==== CHECKS ====
  // THE MEASURED NUMBER IS PRINTED FOR EVERY SHAPE, PASS OR FAIL, so the log carries it and a
  // reader never has to infer it from the bound: `cyc[j]/N` is the stream's per-store clk_sys
  // (the decoupled store made the CPU hold 0, so this is the device's wall clock, not the CPU's).
  task automatic check(input integer j);
    begin
      $display("NOTE gfx_throughput: %0s: %0d.%02d clk_sys/store (%0d for %0d), %0d array accesses/store (bound %0d)",
               sname[j], cyc[j] / N, ((cyc[j] % N) * 100) / N, cyc[j], N, acc[j] / N, max_cyc[j]);
      if (cyc[j] > N * max_cyc[j] + SLACK) begin
        fail({sname[j], " : the stream's wall clock"});
        $display("     %0d clk_sys for %0d stores (bound %0d/store), %0d array accesses",
                 cyc[j], N, max_cyc[j], acc[j]);
      end
      if (acc[j] != N * want_acc[j]) begin
        fail({sname[j], " : array accesses moved (a lane was dropped to go faster)"});
        $display("     %0d accesses, want %0d", acc[j], N * want_acc[j]);
      end
    end
  endtask

  // ==== VERDICT ====
  initial begin
    reset = 1'b1;
    repeat (30) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);
    describe;

    // ---- S1: the sprite FOOTPRINT ERASE - two live byte lanes on a mixed datum, so each lane
    //      reads its old word and writes its merged one. Four accesses is the floor. ----
    seed_row(BASE, 8);
    port_w(8'h7C, 8'hC0); put_tiles(T_B, T_R, T_G, T_E);
    stream_store(N, PLANE, BASE, 32'h0000_5A5A, 4'hF, cyc[0], acc[0]);
    port_w(8'h7C, 8'h00); drain;
    check(0);
    // column BASE is lane 0 and BASE+1 lane 1: both merged, the columns the enables do not cover
    // untouched.
    for (i = 0; i < 2; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== rmw(8'h3C, 8'h5A, T_B)) fail("S1 plane B merge");
      peek(2'd1, BASE + i, bv); if (bv !== rmw(8'h5A, 8'h5A, T_R)) fail("S1 plane R merge");
      peek(2'd2, BASE + i, bv); if (bv !== rmw(8'hC3, 8'h5A, T_G)) fail("S1 plane G merge");
      peek(2'd3, BASE + i, bv); if (bv !== rmw(8'h7E, 8'h5A, T_E)) fail("S1 plane E merge");
    end

    // ---- S2: the same merge over a full dword - eight accesses, the four-lane floor. ----
    seed_row(BASE, 8);
    port_w(8'h7C, 8'hC0); put_tiles(T_B, T_R, T_G, T_E);
    stream_store(N, PLANE, BASE, 32'h5A5A_5A5A, 4'hF, cyc[1], acc[1]);
    port_w(8'h7C, 8'h00); drain;
    check(1);
    for (i = 0; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== rmw(8'h3C, 8'h5A, T_B)) fail("S2 plane B merge");
      peek(2'd3, BASE + i, bv); if (bv !== rmw(8'h7E, 8'h5A, T_E)) fail("S2 plane E merge");
    end

    // ---- S3: the 0xFF-datum pair burst - (old & ~0xFF) | (tile & 0xFF) is the TILE whatever the
    //      old word was, so the pair needs no read and costs one two-word request. ----
    seed_row(BASE, 8);
    port_w(8'h7C, 8'hC0); put_tiles(T_B, T_R, T_G, T_E);
    stream_store(N, PLANE, BASE, 32'h0000_FFFF, 4'hF, cyc[2], acc[2]);
    port_w(8'h7C, 8'h00); drain;
    check(2);
    for (i = 0; i < 2; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== T_B) fail("S3 plane B must take the tile");
      peek(2'd3, BASE + i, bv); if (bv !== T_E) fail("S3 plane E must take the tile");
    end

    // ---- S4: the same pair burst with ONE plane enabled (the active-low mask, 0xE = BLUE). ----
    seed_row(BASE, 8);
    port_w(8'h7C, 8'hCE); put_tiles(T_B, T_R, T_G, T_E);   // 0xCE = RMW, active-LOW 1110: plane B only
    stream_store(N, PLANE, BASE, 32'h0000_FFFF, 4'hF, cyc[3], acc[3]);
    port_w(8'h7C, 8'h00); drain;
    check(3);
    for (i = 0; i < 2; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== T_B) fail("S4 plane B must take the tile");
      peek(2'd1, BASE + i, bv); if (bv !== 8'h5A) fail("S4 a masked-out plane changed");
      peek(2'd3, BASE + i, bv); if (bv !== 8'h7E) fail("S4 a masked-out plane changed");
    end

    // ---- S5/S6: the TDW burst, 32- and 16-bit - the tile is what the guest asked for and the
    //      CPU datum is ignored. ----
    seed_row(BASE, 8);
    port_w(8'h7C, 8'h80); put_tiles(T_B, T_R, T_G, T_E);
    stream_store(N, PLANE, BASE, 32'hDEAD_BEEF, 4'hF, cyc[4], acc[4]);
    port_w(8'h7C, 8'h00); drain;
    check(4);
    for (i = 0; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== T_B) fail("S5 plane B must take the tile");
      peek(2'd3, BASE + i, bv); if (bv !== T_E) fail("S5 plane E must take the tile");
    end

    seed_row(BASE, 8);
    port_w(8'h7C, 8'h80); put_tiles(T_B, T_R, T_G, T_E);
    stream_store(N, PLANE, BASE, 32'h0000_0000, 4'h3, cyc[5], acc[5]);
    port_w(8'h7C, 8'h00); drain;
    check(5);
    for (i = 0; i < 2; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv != T_B) fail("S6 plane B must take the tile");
    end
    for (i = 2; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== 8'h3C) fail("S6 clobbered a column outside the pair");
    end

    // ---- The report is INSIDE check() above, so every shape's measured clk_sys/store prints
    // whether it passes or fails and sits beside the bound it is measured against. ----

    if (errors != 0) begin
      $display("TB_PC9821_GFX_THROUGHPUT: FAIL (%0d checks)", errors);
      $fatal(1);
    end
    $display("TB_PC9821_GFX_THROUGHPUT: PASS");
    $finish;
  end

  initial begin
    #4_000_000;
    $fatal(1, "the throughput bench did not finish in 4 ms of simulated time");
  end

endmodule

`default_nettype wire

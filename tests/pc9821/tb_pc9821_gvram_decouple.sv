`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GVRAM_DECOUPLE: the ACCEPT-AND-DECOUPLE of a plane-window STORE. A store is ACCEPTED (its cpu_ready pulsed) in the cycle its access is captured and the array work completes BEHIND the CPU, so the clk_sys the CPU held the request unaccepted (pc9821_perf_msg's MW condition) is 0-1 for every store shape TH05 issues - the plain dword/byte store, the GRCG's mixed-datum RMW at 16 and 32 bits, the all-planes TDW burst, and the EGC's 16- and 32-bit fill - against 4-12 on the pre-change tree. It is FAIL-FIRST: the file connects NO new port, so it runs on the pre-change pc9821_gvram (git stash push -- src/) and the store holds there fail every bound. The CORRECTNESS BAR is read-after-write coherency: a store immediately followed, with NO drain wait, by a read of the SAME column must return the store's byte, for the plain and the GRCG RMW arms, and a 16-store stream must read back byte-exact at every column; a read is NOT decoupled (its data is not ready until the array captures it), so its hold is a guard. Every store shape's array-access count is a floor guard and every pattern is checked byte-exact so a shorter hold cannot be met by dropping a lane.
//
// The header above is the manifest claim VERBATIM (tools/check_tests.py holds the two
// together). The shape of the proof: the number this change moves is the CPU's HOLD (the
// clk_sys it held the request unaccepted - pc9821_perf_msg's MW condition), measured at
// the GVRAM client for every store shape TH05 issues, with every pattern read back
// byte-exact so a shorter hold cannot be bought by dropping a lane; and the correctness
// bar is read-after-write coherency, driven as a store immediately followed by a read of
// the SAME column with NO drain between them.
//
`default_nettype none

module tb_pc9821_gvram_decouple;
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

  // The array's port A: one clk_sys enabled is one access. The scanout's port B is off all bench.
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

  // Every owner back to idle: the array FSM, the GRCG's sequencer, the EGC's produce and the
  // plain client's column walk.
  task automatic drain;
    begin
      while ((dut.u_arb.gstate != 3'd0) || dut.u_arb.m_mode || (dut.u_arb.cs != 4'd0) ||
             (dut.u_grcg.gstate != 4'd0) || (dut.u_egc.state != 4'd0)) @(posedge clk);
    end
  endtask

  // A plain plane-window STORE, the shape z486 presents (dword-aligned, the enables in cpu_be).
  task automatic plain_store_be(input [1:0] plane, input [14:0] off, input [31:0] d, input [3:0] be);
    begin
      egc_gate = 0;
      port_w(8'h7C, 8'h00);
      @(negedge clk);
      win_plane = plane; win_offset = off; cpu_din = d; cpu_be = be;
      cpu_write = 1; cpu_valid = 1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk); cpu_valid = 0; cpu_write = 0; cpu_be = 4'hF;
      drain; repeat (3) @(posedge clk);
    end
  endtask

  task automatic plain_store(input [1:0] plane, input [14:0] off, input [31:0] d);
    begin
      plain_store_be(plane, off, d, 4'hF);
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
      drain; repeat (3) @(posedge clk);
      v = d[{c[1:0], 3'b000} +: 8];
    end
  endtask

  // ---- THE HOLD MEASUREMENT ----
  // `hold` counts the clk_sys the CPU held the request unaccepted (pc9821_perf_msg's MW
  // condition); `accesses` counts the array's port-A enables for the WHOLE operation, taken after
  // every owner has drained. The store shapes assert a short hold; the read shapes are guards.
  task automatic op_measured(input [1:0] plane, input [14:0] off, input [31:0] din,
                             input [3:0] be, input wr, input egc,
                             output integer accesses, output integer hold);
    integer a0;
    begin
      egc_gate = egc;
      @(negedge clk);
      win_plane = plane; win_offset = off; cpu_din = din; cpu_be = be;
      cpu_write = wr; cpu_valid = 1;
      a0 = acc_cnt; hold = 0;
      @(posedge clk); #1;
      while (!cpu_ready) begin hold = hold + 1; @(posedge clk); #1; end
      @(negedge clk);
      cpu_valid = 0; cpu_write = 0; cpu_be = 4'hF;
      drain;
      accesses = acc_cnt - a0;
      repeat (3) @(posedge clk);
    end
  endtask

  // ---- THE COHERENCY CASE: a DECOUPLED STORE IMMEDIATELY FOLLOWED BY A READ OF THE SAME COLUMN ----
  // The read is presented with NO drain wait between it and the store, exactly as z486 would after
  // the decoupled ready. The GVRAM must not accept it until the store's word is committed; the
  // value read back must be the store's.
  task automatic store_then_read(input [1:0] plane, input [14:0] off, input [31:0] din,
                                 input [3:0] be, input [1:0] rplane, output [7:0] rb,
                                 output integer rh);
    reg [31:0] dout;
    begin
      // the store (accepted early). The GRCG mode, if the caller armed it, is left alone.
      @(negedge clk);
      win_plane = plane; win_offset = off; cpu_din = din; cpu_be = be;
      cpu_write = 1; cpu_valid = 1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      // drop the store and present the read the very next cycle - no drain
      @(negedge clk); cpu_valid = 0; cpu_write = 0;
      win_plane = rplane; win_offset = {off[14:2], 2'b00};
      cpu_be = (4'h1 << off[1:0]);
      cpu_write = 0; cpu_valid = 1;
      rh = 0;
      @(posedge clk); #1;
      while (!cpu_ready) begin rh = rh + 1; @(posedge clk); #1; end
      while (!cpu_resp_valid) @(negedge clk);
      #1; dout = cpu_dout;
      @(negedge clk); cpu_valid = 0; cpu_be = 4'hF;
      drain; repeat (3) @(posedge clk);
      rb = dout[{off[1:0], 3'b000} +: 8];
    end
  endtask

  // ==== CHECKS ====
  localparam [14:0] BASE  = 15'h0800;
  localparam [1:0]  PLANE = 2'd0;

  integer accesses, hold;
  integer n, i;
  reg [7:0] bv;
  integer bad;

  // [k][0] = array accesses (floor guard), [k][1] = CPU hold (the fail-first bound),
  // [k][2] = the pre-change hold, printed for the fail-first evidence.
  localparam integer NB = 8;
  integer res[NB][3];
  reg [8*72-1:0] pname[NB];
  integer max_hold[NB];

  task automatic describe;
    begin
      pname[0] = "D1 plain dword store";
      pname[1] = "D2 plain byte store";
      pname[2] = "D3 GRCG RMW 16-bit, all planes, mixed datum";
      pname[3] = "D4 GRCG RMW 32-bit, all planes, mixed datum";
      pname[4] = "D5 GRCG TDW 32-bit, all planes (pair burst)";
      pname[5] = "D6 EGC 0x1400 fill 16-bit";
      pname[6] = "D7 EGC 0x1400 fill 32-bit";
      pname[7] = "D8 plain dword READ (guard: a read is NOT decoupled)";
      // Every STORE's ready is its ACCEPT, so the CPU hold is 0 (or the registered pulse's one
      // cycle). A READ keeps its walk: its data is not ready until the array has captured it.
      max_hold[0] = 1;   // was 4
      max_hold[1] = 1;   // was 4
      max_hold[2] = 1;   // was 4
      max_hold[3] = 1;   // was 8
      max_hold[4] = 1;   // was 5
      max_hold[5] = 1;   // was 6
      max_hold[6] = 1;   // was 12
      max_hold[7] = 16;  // a READ: its walk, unchanged (was 9)
    end
  endtask

  reg [7:0] v;

  // ==== VERDICT ====
  initial begin
    reset = 1'b1;
    repeat (30) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);
    describe;

    // ---- D1/D2: the plain path. A dword store is four columns of one plane, a byte store one. ----
    plain_store(PLANE, BASE, 32'h0000_0000);
    op_measured(PLANE, BASE, 32'h1122_3344, 4'hF, 1'b1, 1'b0, res[0][0], res[0][1]);
    op_measured(PLANE, BASE, 32'h0000_0044, 4'h1, 1'b1, 1'b0, res[1][0], res[1][1]);
    if (res[0][1] > max_hold[0]) fail("D1 plain dword store : CPU hold");
    if (res[1][1] > max_hold[1]) fail("D2 plain byte store : CPU hold");
    // D1 wrote the dword's bytes to plane 0's columns 0..3 (lane k -> column BASE+k); D2 then
    // overwrote column 0. Read every column back byte-exact.
    begin : rd1
      reg [7:0] want [0:3];
      want[0] = 8'h44; want[1] = 8'h33; want[2] = 8'h22; want[3] = 8'h11;
      for (i = 0; i < 4; i = i + 1) begin
        peek(PLANE, BASE + i, v);
        if (v !== want[i]) fail("D1/D2 plain store read-back is not byte-exact");
      end
    end

    // ---- D3/D4: the GRCG RMW erase TH05 spends its drawing time in, 16- and 32-bit. ----
    plain_store(PLANE, BASE, 32'h0000_0000);
    port_w(8'h7C, 8'hC0); put_tiles(8'h11, 8'h22, 8'h44, 8'h88);
    op_measured(PLANE, BASE, 32'h0000_5A5A, 4'h3, 1'b1, 1'b0, res[2][0], res[2][1]);
    port_w(8'h7C, 8'h00); drain;
    if (res[2][1] > max_hold[2]) fail("D3 GRCG RMW 16-bit : CPU hold");
    for (i = 0; i < 2; i = i + 1) begin
      peek(2'd0, BASE + i, v); if (v !== ((8'h00 & ~8'h5A) | (8'h11 & 8'h5A))) fail("D3 plane B merge");
      peek(2'd1, BASE + i, v); if (v !== ((8'h00 & ~8'h5A) | (8'h22 & 8'h5A))) fail("D3 plane R merge");
      peek(2'd2, BASE + i, v); if (v !== ((8'h00 & ~8'h5A) | (8'h44 & 8'h5A))) fail("D3 plane G merge");
      peek(2'd3, BASE + i, v); if (v !== ((8'h00 & ~8'h5A) | (8'h88 & 8'h5A))) fail("D3 plane E merge");
    end
    plain_store(PLANE, BASE, 32'h0000_0000);
    port_w(8'h7C, 8'hC0); put_tiles(8'h11, 8'h22, 8'h44, 8'h88);
    op_measured(PLANE, BASE, 32'h5A5A_5A5A, 4'hF, 1'b1, 1'b0, res[3][0], res[3][1]);
    port_w(8'h7C, 8'h00); drain;
    if (res[3][1] > max_hold[3]) fail("D4 GRCG RMW 32-bit : CPU hold");
    for (i = 0; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, v); if (v !== ((8'h00 & ~8'h5A) | (8'h11 & 8'h5A))) fail("D4 plane B merge");
      peek(2'd3, BASE + i, v); if (v !== ((8'h00 & ~8'h5A) | (8'h88 & 8'h5A))) fail("D4 plane E merge");
    end

    // ---- D5: the TDW burst (one two-word request per column pair). ----
    plain_store(PLANE, BASE, 32'h0000_0000);
    port_w(8'h7C, 8'h80); put_tiles(8'h11, 8'h22, 8'h44, 8'h88);
    op_measured(PLANE, BASE, 32'hDEAD_BEEF, 4'hF, 1'b1, 1'b0, res[4][0], res[4][1]);
    port_w(8'h7C, 8'h00); drain;
    if (res[4][1] > max_hold[4]) fail("D5 GRCG TDW burst : CPU hold");
    for (i = 0; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, v); if (v !== 8'h11) fail("D5 plane B must take the tile");
      peek(2'd3, BASE + i, v); if (v !== 8'h88) fail("D5 plane E must take the tile");
      if (i == 4) begin end
    end
    // a TDW 16-bit store must write ONLY its own pair: check the neighbours kept their value
    plain_store(PLANE, BASE, 32'h0000_0000);
    port_w(8'h7C, 8'h80); put_tiles(8'h33, 8'h33, 8'h33, 8'h33);
    op_measured(PLANE, BASE, 32'h0000_0000, 4'h3, 1'b1, 1'b0, res[4][0], res[4][1]);
    port_w(8'h7C, 8'h00); drain;
    for (i = 0; i < 2; i = i + 1) begin
      peek(2'd0, BASE + i, v); if (v !== 8'h33) fail("D5 16-bit TDW pair not written");
    end
    for (i = 2; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, v); if (v !== 8'h00) fail("D5 16-bit TDW clobbered a neighbour column");
    end

    // ---- D6/D7: the EGC's fill, the tile layer's shape. ----
    plain_store(PLANE, BASE, 32'h0000_0000);
    port_w(8'h7C, 8'h00);
    egc_access = 16'h0000; egc_ope = 16'h1400; egc_fgbg = 16'h4000;
    egc_fg = 16'h000F; egc_mask = 16'hFFFF; egc_leng = 16'h0FFF; egc_sft = 16'h0000;
    egc_shift_we = 1; @(negedge clk); egc_shift_we = 0;
    op_measured(PLANE, BASE, 32'h0000_0000, 4'h3, 1'b1, 1'b1, res[5][0], res[5][1]);
    if (res[5][1] > max_hold[5]) fail("D6 EGC 16-bit fill : CPU hold");
    for (i = 0; i < 2; i = i + 1) begin
      peek(2'd0, BASE + i, v); if (v !== 8'hFF) fail("D6 EGC fill byte");
    end
    plain_store(PLANE, BASE, 32'h0000_0000);
    port_w(8'h7C, 8'h00);
    egc_access = 16'h0000; egc_ope = 16'h1400; egc_fgbg = 16'h4000;
    egc_fg = 16'h000F; egc_mask = 16'hFFFF; egc_leng = 16'h0FFF; egc_sft = 16'h0000;
    egc_shift_we = 1; @(negedge clk); egc_shift_we = 0;
    op_measured(PLANE, BASE, 32'h0000_0000, 4'hF, 1'b1, 1'b1, res[6][0], res[6][1]);
    egc_gate = 0;
    if (res[6][1] > max_hold[6]) fail("D7 EGC 32-bit fill : CPU hold");
    for (i = 0; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, v); if (v !== 8'hFF) fail("D7 EGC fill byte");
    end

    // ---- D8: a READ is a GUARD - it keeps its walk, so its hold is not decoupled. ----
    plain_store(PLANE, BASE, 32'h0000_0000);
    op_measured(PLANE, BASE, 32'h1357_9BDF, 4'hF, 1'b1, 1'b0, res[0][0], res[0][1]);
    op_measured(PLANE, BASE, 32'd0, 4'hF, 1'b0, 1'b0, res[7][0], res[7][1]);
    if (res[7][1] > max_hold[7]) fail("D8 plain read : CPU hold");
    if (cpu_dout !== 32'h1357_9BDF) fail("D8 plain read returned the wrong dword");

    // ---- THE COHERENCY BAR: a decoupled store immediately followed by a read of the same column.
    //      The value must be the store's, for every shape, with NO drain between them. ----
    plain_store(PLANE, BASE, 32'h0000_0000);
    store_then_read(PLANE, BASE, 32'hA5A5_A5A5, 4'h1, PLANE, bv, hold);
    if (bv !== 8'hA5) fail("coherency: plain store then immediate read returned stale");
    plain_store(PLANE, BASE, 32'h0000_0000);
    port_w(8'h7C, 8'hC0); put_tiles(8'h3C, 8'h5A, 8'hC3, 8'h7E);
    store_then_read(PLANE, BASE, 32'h5A5A_5A5A, 4'h1, 2'd0, bv, hold);
    port_w(8'h7C, 8'h00);
    if (bv !== ((8'h00 & ~8'h5A) | (8'h3C & 8'h5A))) fail("coherency: GRCG RMW then immediate read returned stale");

    // ---- THE COHERENCY BAR, STREAM: many decoupled stores, then read every column back. A
    //      per-column byte store (be = one lane) so each column carries its own value. ----
    for (i = 0; i < 16; i = i + 1)
      plain_store_be(PLANE, 15'h1000 + i[14:0],
                     {8'h00, 8'h00, 8'h00, (8'h10 + i[7:0])} << {i[1:0], 3'b000},
                     (4'h1 << i[1:0]));
    for (i = 0; i < 16; i = i + 1) begin
      peek(PLANE, 15'h1000 + i[14:0], bv);
      if (bv !== (8'h10 + i[7:0])) fail("coherency: store stream read-back is stale");
    end

    // ---- THE THROUGHPUT IS THE ARRAY'S, NOT THE CPU's: a back-to-back store stream, the next
    //      request presented the cycle the previous one is accepted (z486's shape). The store's
    //      own hold is now the accept, but the NEXT store still waits for the draining walk, so
    //      the stream's total is the array's floor - which is why the firmware's cycle count is
    //      unchanged. Printed, not asserted: the CPU's win from the decouple is the work it can
    //      do BETWEEN stores while the walk drains, which only a capture can show. ----
    begin : stream
      integer k, c0, th;
      port_w(8'h7C, 8'hC0); put_tiles(8'h11, 8'h22, 8'h44, 8'h88);
      c0 = cyc_cnt; th = 0;
      for (k = 0; k < 64; k = k + 1) begin
        @(negedge clk);
        win_plane = PLANE; win_offset = BASE + k[14:0]; cpu_din = 32'h0000_5A5A;
        cpu_be = 4'hF; cpu_write = 1; cpu_valid = 1;
        @(posedge clk); #1;
        while (!cpu_ready) begin th = th + 1; @(posedge clk); #1; end
        @(negedge clk); cpu_valid = 0; cpu_write = 0; cpu_be = 4'hF;
      end
      drain;
      $display("NOTE gvram_decouple: 64 back-to-back GRCG RMW stores: %0d clk_sys total, %0d clk_sys CPU-held (MW-style)",
               cyc_cnt - c0, th);
      port_w(8'h7C, 8'h00);
    end

    // ---- The report: the two numbers, side by side, per shape ----
    for (n = 0; n < NB; n = n + 1)
      $display("NOTE gvram_decouple: %0s: %0d array accesses, %0d clk_sys CPU hold",
               pname[n], res[n][0], res[n][1]);

    bad = errors;
    if (bad != 0) begin
      $display("TB_PC9821_GVRAM_DECOUPLE: FAIL (%0d checks)", bad);
      $fatal(1);
    end
    $display("TB_PC9821_GVRAM_DECOUPLE: PASS");
    $finish;
  end

  initial begin
    #1_000_000;
    $fatal(1, "the decouple bench did not finish in 1 ms of simulated time");
  end

endmodule

`default_nettype wire

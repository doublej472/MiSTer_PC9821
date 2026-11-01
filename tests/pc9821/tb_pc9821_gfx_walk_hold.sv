`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GFX_WALK_HOLD: the GVRAM's ONE-VISIT lane walk measured where the CPU feels it - the number of ARRAY ACCESSES the M10K's port A was enabled for and the number of clk_sys the CPU held its request unaccepted (the same condition pc9821_perf_msg's MW counts) - for the eight store shapes TH05 issues through the real pc9821_gvram with the real GRCG inside it. It asserts the floor rather than a model of it: a plain 32-bit plane-window store MUST be 4 accesses (four byte-interleaved words, one write port) and 4 clk_sys, a mixed-datum GRCG RMW MUST be 8 and 10, a single-plane RMW put with a 0xFF datum must NOT pay the read the old whole-mask test charged it (8 accesses before, 4 now), and an RMW store whose datum is 0x00000000 changes nothing so it must issue NO access at all (it cost 8 accesses and an 11-clk_sys hold before the walk was shortened). The access count comes from the array's own port-A enable, and every pattern is checked byte-exact on readback so the count cannot be met by dropping a lane. FAIL-FIRST: it does not connect the walk telemetry, so the same file builds against the pre-change pc9821_gvram and every bound above fails there.
//
// WHY THESE TWO NUMBERS. The diagnosis is that a GVRAM store is a CPU MEMORY transaction
// whose ready waits on the array walk, so the walk's cycles land in the CPU's memory wait (`MW`)
// and the game's frame time follows. Two things can be wrong with such a walk and this bench names
// them separately:
//
//   accesses  the work itself. The array is byte-interleaved, so a 32-bit plane-window store
//             spans FOUR words and one port can only write one per clk_sys: 4 is the floor for a
//             dword store, and nothing may exceed what the shape actually needs. The old read test
//             asked the whole 32-bit merge mask, so a single-plane put or a mixed datum paid a read
//             on every lane (8 accesses), and a GRCG RMW lane whose datum byte is 0x00 has a zero
//             merge mask - no read and no write - yet paid for both.
//   hold      the overhead around the work: the dispatch bubble the accept used to spend issuing
//             nothing, and the tail cycle C_RESP spent holding the CPU one clk_sys after the walk
//             had already completed.
//
// THE BOUNDS ARE FAIL-FIRST. Every `want_acc` and `max_hold` below carries the same bench's
// measurement on the PRE-CHANGE tree in its comment (reproduce with `git stash push -- src/`), and
// ten assertions fail there: P5 (a 32-bit RMW store whose datum is 0x00000000, which changes
// nothing) paid 8 array accesses and an 11-clk_sys hold for no work at all, P6 (a single-plane put
// with a 0xFF datum) paid a read on all four lanes, and every store held the CPU one or two
// clk_sys longer than its walk needs.
//
// IT DOES NOT CONNECT THE WALK TELEMETRY, on purpose: the same file must build and run against the
// pre-change pc9821_gvram, whose ports do not exist, so that "fails before, passes after" is one
// bench rather than two. The pulses themselves are asserted in tb_pc9821_gvram.sv, the bench of the
// module that produces them.
//
// The access count comes from the M10K's port-A enable (dut.gma_en) rather than from a model of the
// FSM, so a walk that issues a redundant access is caught even if its state sequence looks right.
// The scanout reads port B (dut.gmb_en) and is off for the whole bench, so every counted enable is
// the CPU's.

`default_nettype none

module tb_pc9821_gfx_walk_hold;
  localparam integer CYCLE_NS = 20;

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg reset = 1;

  // ==== DUT ====
  // The real pc9821_gvram, with the real GRCG and the real EGC inside it.
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
  // One clk_sys with the M10K's port A enabled is one array access.
  integer acc_cnt = 0;
  always @(posedge clk) if (dut.gma_en) acc_cnt <= acc_cnt + 1;

  integer errors = 0;

  task automatic fail(input [8*160-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS: the bus z486 presents (dword-aligned, the lanes in cpu_be) ====
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

  // FOUR consecutive columns of ALL FOUR planes, one dword store per plane: datum byte k lands in
  // that plane's byte at column base+k.
  task automatic seed_cols(input [14:0] base, input [7:0] b, input [7:0] r,
                           input [7:0] g, input [7:0] e);
    reg [31:0] d;
    begin
      grcg_w(8'h7C, 8'h00);
      d = {b, b, b, b}; plane_op(2'd0, base, d, 4'hF, 1'b1, d);
      d = {r, r, r, r}; plane_op(2'd1, base, d, 4'hF, 1'b1, d);
      d = {g, g, g, g}; plane_op(2'd2, base, d, 4'hF, 1'b1, d);
      d = {e, e, e, e}; plane_op(2'd3, base, d, 4'hF, 1'b1, d);
    end
  endtask

  // ---- THE MEASUREMENT ----
  // One CPU plane-window STORE, measured. `accesses` counts the clk_sys the array's port A was
  // enabled for the WHOLE operation (from the request being presented until every owner has
  // drained - the accept-and-decouple makes a store ACCEPTED at its accept and completed behind the CPU, so the
  // walk is no longer over when the ready comes); `hold` counts the clk_sys the CPU held the
  // request unaccepted, which is the SAME condition pc9821_perf_msg's MW counts (a request
  // outstanding, z_ready low), so both numbers are the ones a capture reports.
  task automatic store_measured(input [1:0] plane, input [14:0] off, input [31:0] din,
                                input [3:0] be, output integer accesses, output integer hold);
    integer a0;
    begin
      // The DEVICE idle (every owner AND the GVRAM's own acceptance period):
      // pc9821_gvram_arb's GVRAM_PERIODS makes a GVRAM access cost the machine's per-operation
      // TIME, which is a THROUGHPUT cost - and this bench measures one operation's own walk. It
      // waits the period out first so the number below is this shape's, not the previous shape's.
      while ((dut.u_egc.state != 4'd0) || (dut.u_arb.gstate != 3'd0) || dut.u_arb.m_mode ||
             (dut.u_arb.cs != 4'd0) || (dut.u_grcg.gstate != 4'd0) ||
             (dut.u_arb.hold_left != 16'd0)) @(posedge clk);
      repeat (2) @(posedge clk);
      @(negedge clk);
      win_plane  = plane;
      win_offset = off;
      cpu_din    = din;
      cpu_be     = be;
      cpu_write  = 1'b1;
      cpu_valid  = 1'b1;
      a0 = acc_cnt;
      hold = 0;
      @(posedge clk); #1;
      while (!cpu_ready) begin
        hold = hold + 1;
        @(posedge clk); #1;
      end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
      // Let every owner return to idle before the access count is read: the array FSM, the EGC's
      // produce, the GRCG's sequencer and the plain client's column walk.
      while ((dut.u_egc.state != 4'd0) || (dut.u_arb.gstate != 3'd0) || dut.u_arb.m_mode ||
             (dut.u_arb.cs != 4'd0) || (dut.u_grcg.gstate != 4'd0)) @(posedge clk);
      accesses = acc_cnt - a0;
      repeat (3) @(posedge clk);
    end
  endtask

  // The same for a READ, so the read arm of the walk is measured too.
  task automatic read_measured(input [1:0] plane, input [14:0] off, input [3:0] be,
                               output integer accesses, output integer hold, output [31:0] dout);
    integer a0;
    begin
      while ((dut.u_egc.state != 4'd0) || (dut.u_arb.gstate != 3'd0) || dut.u_arb.m_mode ||
             (dut.u_arb.cs != 4'd0) || (dut.u_grcg.gstate != 4'd0) ||
             (dut.u_arb.hold_left != 16'd0)) @(posedge clk);
      repeat (2) @(posedge clk);
      @(negedge clk);
      win_plane  = plane;
      win_offset = off;
      cpu_din    = 32'd0;
      cpu_be     = be;
      cpu_write  = 1'b0;
      cpu_valid  = 1'b1;
      a0 = acc_cnt;
      hold = 0;
      @(posedge clk); #1;
      while (!cpu_ready) begin
        hold = hold + 1;
        @(posedge clk); #1;
      end
      accesses = acc_cnt - a0;
      while (!cpu_resp_valid) @(negedge clk);
      #1; dout = cpu_dout;
      @(negedge clk);
      cpu_valid = 1'b0; cpu_be = 4'hF;
    end
  endtask

  // ---- THE PATTERNS ----
  // The store goes through the BLUE window at a dword-aligned offset inside plane 0's page, which
  // is what makes its four bytes the four columns BASE..BASE+3 of every plane.
  localparam [14:0] BASE  = 15'h0800;
  localparam [1:0]  PLANE = 2'd0;

  localparam integer NB = 8;
  integer accesses[NB], hold[NB], want_acc[NB], max_hold[NB];
  reg [8*80-1:0] pname[NB];

  task automatic describe;
    begin
      pname[0]  = "P1 plain dword store, be=1111";
      pname[1]  = "P2 plain word store, be=0011";
      pname[2]  = "P3 plain byte store, be=0001";
      pname[3]  = "P4 GRCG RMW dword, all planes, datum 5A5A5A5A";
      pname[4]  = "P5 GRCG RMW dword, all planes, datum 00000000";
      pname[5]  = "P6 GRCG RMW dword, B plane only, datum FFFFFFFF";
      pname[6]  = "P7 GRCG RMW dword, all planes, datum FFFFFFFF";
      pname[7]  = "P8 GRCG TDW dword, B plane only";
      // Array accesses for ONE CPU store. "was N" is the same bench's measurement on the
      // PRE-CHANGE tree (git stash push -- src/), which is what makes these fail-first.
      want_acc[0] = 4;   // was 4   (the four interleaved words: the floor for a dword store)
      want_acc[1] = 2;   // was 2
      want_acc[2] = 1;   // was 1
      want_acc[3] = 8;   // was 8   (a mixed datum needs every lane's old word: the RMW floor)
      want_acc[4] = 0;   // was 8   (every lane's merge mask is zero: nothing to read, nothing to write)
      want_acc[5] = 4;   // was 8   (a 0xFF datum needs no read; the old test asked the whole mask)
      want_acc[6] = 4;   // was 4   (all planes + a 0xFF datum take the two-word pair burst)
      want_acc[7] = 4;   // was 4   (TDW needs no read)
      // CPU-hold clk_sys for ONE CPU store, the same way.
      max_hold[0] = 4;   // was 6
      max_hold[1] = 2;   // was 4
      max_hold[2] = 1;   // was 3
      max_hold[3] = 10;  // was 11  (a mixed datum keeps its 8 accesses and gains only the bubble)
      max_hold[4] = 3;   // was 11
      max_hold[5] = 6;   // was 11
      max_hold[6] = 8;   // was 8   (the pair-burst arm, which the walk rewrite did not touch)
      max_hold[7] = 6;   // was 7
    end
  endtask

  // ==== CHECKS ====
  // The measured numbers, and the two floors each shape must meet. `want_acc` is EXACT (the array
  // access count is deterministic for a shape); `max_hold` is an upper bound, because it is the
  // walk's own length plus its fixed overhead and nothing may add to it.
  integer n, i, aw, hw;
  reg [7:0]  bv;
  reg [31:0] dw, want_dw;
  integer bad;

  task automatic check(input integer k);
    begin
      if (accesses[k] != want_acc[k]) fail({pname[k], " : array accesses"});
      if (hold[k] > max_hold[k])       fail({pname[k], " : CPU hold"});
    end
  endtask

  // ==== VERDICT ====
  initial begin
    reset = 1'b1;
    repeat (20) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);
    describe;

    // ---- P1: the plain plane-window DWORD store. Four enabled lanes, four interleaved words,
    // one write port: 4 array accesses and a ready on the cycle the walk ends. ----
    grcg_w(8'h7C, 8'h00);
    store_measured(PLANE, BASE, 32'h1122_3344, 4'hF, accesses[0], hold[0]);
    check(0);
    peek(2'd0, BASE + 0, bv); if (bv !== 8'h44) fail("P1 column 0 byte is wrong");
    peek(2'd0, BASE + 1, bv); if (bv !== 8'h33) fail("P1 column 1 byte is wrong");
    peek(2'd0, BASE + 2, bv); if (bv !== 8'h22) fail("P1 column 2 byte is wrong");
    peek(2'd0, BASE + 3, bv); if (bv !== 8'h11) fail("P1 column 3 byte is wrong");

    // ---- The READ arm of the same walk: four lanes, so four accesses, and a lane's read is TWO
    // clk_sys (the issue and the registered capture). It must not have moved. ----
    read_measured(PLANE, BASE, 4'hF, aw, hw, dw);
    $display("NOTE gfx_walk_hold: plain dword READ: %0d array accesses, %0d clk_sys CPU hold, datum 0x%08x",
             aw, hw, dw);
    if (aw != 4) fail("a plain dword read must issue 4 array accesses");
    if (hw > 9)  fail("a plain dword read held the CPU longer than its 4 lanes need");
    if (dw !== 32'h1122_3344) fail("the plain dword read did not return what P1 stored");

    // ---- P2/P3: a word store is two lanes and a byte store is one ----
    store_measured(PLANE, BASE, 32'h0000_3344, 4'h3, accesses[1], hold[1]);
    store_measured(PLANE, BASE, 32'h0000_0044, 4'h1, accesses[2], hold[2]);
    check(1); check(2);

    // ---- P4: the GRCG RMW merge TH05's sprite erase issues, a MIXED datum. Every lane needs its
    // old word, so 8 accesses is the floor and the walk must not exceed it. ----
    seed_cols(BASE, 8'h3C, 8'h5A, 8'hC3, 8'h7E);
    grcg_w(8'h7C, 8'hC0);
    grcg_w(8'h7E, 8'h11); grcg_w(8'h7E, 8'h22);
    grcg_w(8'h7E, 8'h44); grcg_w(8'h7E, 8'h88);
    store_measured(PLANE, BASE, 32'h5A5A_5A5A, 4'hF, accesses[3], hold[3]);
    grcg_w(8'h7C, 8'h00);
    check(3);
    // Byte-exact against NP2kai's merge (old & ~d) | (tile & d), at all four columns and planes.
    for (i = 0; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, bv);
      if (bv !== ((8'h3C & ~8'h5A) | (8'h11 & 8'h5A))) fail("P4 plane B merge");
      peek(2'd1, BASE + i, bv);
      if (bv !== ((8'h5A & ~8'h5A) | (8'h22 & 8'h5A))) fail("P4 plane R merge");
      peek(2'd2, BASE + i, bv);
      if (bv !== ((8'hC3 & ~8'h5A) | (8'h44 & 8'h5A))) fail("P4 plane G merge");
      peek(2'd3, BASE + i, bv);
      if (bv !== ((8'h7E & ~8'h5A) | (8'h88 & 8'h5A))) fail("P4 plane E merge");
    end

    // ---- P5: a datum of 0x00000000 gives EVERY lane a zero merge mask, so the store changes
    // nothing at all. The pre-change tree read and wrote all four lanes for it - 8 array accesses
    // and a 12-clk_sys hold - where the floor is none of either. ----
    seed_cols(BASE, 8'h3C, 8'h5A, 8'hC3, 8'h7E);
    grcg_w(8'h7C, 8'hC0);
    grcg_w(8'h7E, 8'h11); grcg_w(8'h7E, 8'h22);
    grcg_w(8'h7E, 8'h44); grcg_w(8'h7E, 8'h88);
    store_measured(PLANE, BASE, 32'h0000_0000, 4'hF, accesses[4], hold[4]);
    grcg_w(8'h7C, 8'h00);
    check(4);
    for (i = 0; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== 8'h3C) fail("P5 plane B must be untouched");
      peek(2'd1, BASE + i, bv); if (bv !== 8'h5A) fail("P5 plane R must be untouched");
      peek(2'd2, BASE + i, bv); if (bv !== 8'hC3) fail("P5 plane G must be untouched");
      peek(2'd3, BASE + i, bv); if (bv !== 8'h7E) fail("P5 plane E must be untouched");
    end

    // ---- P6: a SINGLE-PLANE put with a 0xFF datum. Four lanes are enabled (the CPU's byte
    // enables), each writing one plane byte from the tile: 4 accesses and no read. The old test
    // asked the whole 32-bit mask (0x000000FF != 0xFFFFFFFF) and read all four lanes first. ----
    seed_cols(BASE, 8'h3C, 8'h5A, 8'hC3, 8'h7E);
    grcg_w(8'h7C, 8'hCE);               // RMW, active-LOW plane enable 1110: BLUE only
    grcg_w(8'h7E, 8'h11); grcg_w(8'h7E, 8'h22);
    grcg_w(8'h7E, 8'h44); grcg_w(8'h7E, 8'h88);
    store_measured(PLANE, BASE, 32'hFFFF_FFFF, 4'hF, accesses[5], hold[5]);
    grcg_w(8'h7C, 8'h00);
    check(5);
    for (i = 0; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== 8'h11) fail("P6 plane B must take the tile byte");
      peek(2'd1, BASE + i, bv); if (bv !== 8'h5A) fail("P6 plane R must be untouched");
      peek(2'd2, BASE + i, bv); if (bv !== 8'hC3) fail("P6 plane G must be untouched");
      peek(2'd3, BASE + i, bv); if (bv !== 8'h7E) fail("P6 plane E must be untouched");
    end

    // ---- P7: the shape that already took the per-column-pair BURST - all planes and a 0xFF
    // datum - so that the walk's numbers above cannot be read as the whole story. ----
    seed_cols(BASE, 8'h3C, 8'h5A, 8'hC3, 8'h7E);
    grcg_w(8'h7C, 8'hC0);
    grcg_w(8'h7E, 8'h11); grcg_w(8'h7E, 8'h22);
    grcg_w(8'h7E, 8'h44); grcg_w(8'h7E, 8'h88);
    store_measured(PLANE, BASE, 32'hFFFF_FFFF, 4'hF, accesses[6], hold[6]);
    check(6);

    // ---- P8: a TDW store over a partial plane mask takes the WALK, not the burst (the burst
    // needs all four planes), and ignores the CPU datum entirely. ----
    seed_cols(BASE, 8'h3C, 8'h5A, 8'hC3, 8'h7E);
    grcg_w(8'h7C, 8'h8E);               // TDW, BLUE only
    grcg_w(8'h7E, 8'h11); grcg_w(8'h7E, 8'h22);
    grcg_w(8'h7E, 8'h44); grcg_w(8'h7E, 8'h88);
    store_measured(PLANE, BASE, 32'hDEAD_BEEF, 4'hF, accesses[7], hold[7]);
    grcg_w(8'h7C, 8'h00);
    check(7);
    for (i = 0; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== 8'h11) fail("P8 plane B must take the tile byte");
      peek(2'd2, BASE + i, bv); if (bv !== 8'hC3) fail("P8 plane G must be untouched");
    end

    // ---- The report: the two numbers, side by side, per store shape ----
    for (n = 0; n < NB; n = n + 1)
      $display("NOTE gfx_walk_hold: %0s: %0d array accesses, %0d clk_sys CPU hold",
               pname[n], accesses[n], hold[n]);

    bad = errors;
    if (bad != 0) begin
      $display("TB_PC9821_GFX_WALK_HOLD: FAIL (%0d checks)", bad);
      $fatal(1);
    end
    $display("TB_PC9821_GFX_WALK_HOLD: PASS");
    $finish;
  end

  initial begin
    #1_000_000;
    $fatal(1, "the walk-hold bench did not finish in 1 ms of simulated time");
  end

endmodule

`default_nettype wire

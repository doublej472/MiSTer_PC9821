`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GFX_ENGINE_HOLD: the GRCG's and the EGC's per-OPERATION cost measured where the CPU feels it - the number of clk_sys the M10K array's port A was ENABLED and the number of clk_sys the CPU held its request unaccepted (the same condition pc9821_perf_msg's MW counts) - for the shapes TH05 issues through the real pc9821_gvram with the real GRCG and EGC inside it. It asserts the FLOOR rather than a model of it: a GRCG RMW store MUST issue one array access per enabled lane and no more, and MUST NOT hold the CPU for a presentation state the array does not need (the GRCG captured the access in G_IDLE and presented it in G_ST) nor for a tail state whose only job is a later ready (a write has no response strobe, so its ready IS its completion). The current path removes both and presents the second pair of a two-pair TDW burst in place: the GRCG hold falls 2 clk_sys on the RMW/walk shapes and 3 on the TDW / 0xFF-datum burst shapes while every access count and every byte readback is unchanged. The EGC shapes are FLOOR GUARDS, not wins: its hold is its produce pipeline plus the array accesses, with no dispatch bubble at the ARRAY to remove, so the design leaves it and registers the number the decoupling lane must move. FAIL-FIRST: the access count comes from the array's own port-A enable and the GRCG shapes hold the CPU 2-3 clk_sys longer on the pre-change tree, so the same file (which connects no new port) fails there.
//
// An earlier change shortened the GVRAM's own one-visit lane walk and measured it in exactly this pair
// (tb_pc9821_gfx_walk_hold.sv). What it left is the same two
// classes of dead cycle ONE LEVEL UP in the engines that own the walk: a DISPATCH cycle (the GRCG
// captured in G_IDLE and presented in G_ST) and a TAIL cycle (G_RESP asserting cpu_ready after the
// walk's cl_done, where a write's ready IS its completion). The engines now remove both, and presents the
// second pair of a two-pair TDW burst in place rather than through a state.
//
// IT DOES NOT CONNECT A NEW PORT, on purpose: the same file must build and run against the
// pre-change pc9821_gvram, so "fails before, passes after" is one bench rather than two. The array
// access count comes from the M10K's port-A enable (dut.gma_en) rather than a model of the FSM, so
// a redundant access is caught even if the state sequence looks right. The scanout's port B is off
// for the whole bench (scan_enable = 0), so every counted enable is a client's.

`default_nettype none

module tb_pc9821_gfx_engine_hold;
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
  // One clk_sys with the M10K's port A enabled is one array access. The scanout's port B is off
  // for the whole bench, so every counted enable is a client's.
  integer acc_cnt = 0;
  always @(posedge clk) if (dut.gma_en) acc_cnt <= acc_cnt + 1;

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

  // EVERY OWNER IDLE, AND THE GVRAM'S OWN ACCEPTANCE PERIOD SPENT. pc9821_gvram_arb's
  // GVRAM_PERIODS makes a GVRAM access cost the machine's per-operation TIME, so "the array FSM is
  // back in G_IDLE" is no longer "the device is done": it will not take the next access until its
  // period has run out, and an operation that drains in the middle of it would carry the
  // previous operation's own walk into the next measurement's window. A drain that waits only for
  // the FSMs is what the pre-latency tree needed; every setup and readback step here spends the
  // period too, so the per-operation numbers stay per-OPERATION.
  task automatic drain;
    begin
      while ((dut.u_egc.state != 4'd0) || (dut.u_arb.gstate != 3'd0) || dut.u_arb.m_mode ||
             (dut.u_arb.cs != 4'd0) || (dut.u_grcg.gstate != 4'd0) ||
             (dut.u_arb.hold_left != 16'd0)) @(posedge clk);
      repeat (2) @(posedge clk);
    end
  endtask

  // A plain (GRCG and EGC disarmed) dword store to seed a column of every plane.
  task automatic plain_store(input [1:0] plane, input [14:0] off, input [31:0] d);
    begin
      egc_gate = 0;
      port_w(8'h7C, 8'h00);
      @(negedge clk);
      win_plane = plane; win_offset = off; cpu_din = d; cpu_be = 4'hF;
      cpu_write = 1; cpu_valid = 1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk); cpu_valid = 0; cpu_write = 0; cpu_be = 4'hF;
      drain;
    end
  endtask

  task automatic seed_cols(input [14:0] base, input [7:0] b, input [7:0] r,
                           input [7:0] g, input [7:0] e);
    begin
      plain_store(2'd0, base, {b, b, b, b});
      plain_store(2'd1, base, {r, r, r, r});
      plain_store(2'd2, base, {g, g, g, g});
      plain_store(2'd3, base, {e, e, e, e});
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

  // ---- THE MEASUREMENT ----
  // One CPU plane-window operation, measured. `accesses` counts every clk_sys the array's port A
  // was enabled from the request being PRESENTED until the engine has drained: the CPU's own hold
  // ends at `ready` (below), but the EGC's write pass is POSTED and keeps writing after
  // it, so the array work of the WHOLE transaction is the honest floor. `hold` counts the clk_sys
  // the CPU held the request unaccepted - the SAME condition pc9821_perf_msg's MW counts - so both
  // numbers are the ones a capture reports.
  task automatic op_measured(input [1:0] plane, input [14:0] off, input [31:0] din,
                             input [3:0] be, input wr,
                             output integer accesses, output integer hold);
    integer a0;
    begin
      drain;   // the device (and its period) idle, so this measurement is THIS operation's
      @(negedge clk);
      win_plane = plane; win_offset = off; cpu_din = din; cpu_be = be;
      cpu_write = wr; cpu_valid = 1;
      a0 = acc_cnt; hold = 0;
      @(posedge clk); #1;
      while (!cpu_ready) begin hold = hold + 1; @(posedge clk); #1; end
      // The CPU's ready has come; the store may still be draining. Release the request the way
      // z486 does and let the engine return to idle before the access count is read. The decouple made
      // the GRCG's and the plain path's stores decoupled too, so the wait covers EVERY owner: the
      // array FSM (gstate/m_mode), the EGC's produce, the GRCG's sequencer and the plain client.
      @(negedge clk);
      cpu_valid = 0; cpu_write = 0; cpu_be = 4'hF;
      while ((dut.u_egc.state != 4'd0) || (dut.u_arb.gstate != 3'd0) || dut.u_arb.m_mode ||
             (dut.u_arb.cs != 4'd0) || (dut.u_grcg.gstate != 4'd0)) @(posedge clk);
      accesses = acc_cnt - a0;
      repeat (3) @(posedge clk);
    end
  endtask

  // ---- THE PATTERNS ----
  localparam [14:0] BASE  = 15'h0800;
  localparam [1:0]  PLANE = 2'd0;

  localparam integer NB = 9;
  integer accesses[NB], hold[NB], want_acc[NB], max_hold[NB];
  reg [8*96-1:0] pname[NB];

  task automatic describe;
    begin
      pname[0] = "G1 GRCG RMW 16-bit, all planes, mixed datum";
      pname[1] = "G2 GRCG RMW 32-bit, all planes, mixed datum";
      pname[2] = "G3 GRCG RMW 32-bit, all planes, datum FFFFFFFF (pair burst)";
      pname[3] = "G4 GRCG TDW 32-bit, all planes (pair burst)";
      pname[4] = "G5 GRCG TCR read 32-bit";
      pname[5] = "E1 EGC 0x1400 fill 16-bit";
      pname[6] = "E2 EGC 0x1400 fill 32-bit";
      pname[7] = "E3 EGC 0x28F0 shifted copy 32-bit";
      pname[8] = "E4 EGC 0x3100 read 32-bit";
      // Array accesses for ONE operation: the work itself, which that change does not touch.
      // "was N" is this bench's measurement on the PRE-CHANGE tree.
      want_acc[0] = 4;   // was 4   (two lanes, each read for its old word then written)
      want_acc[1] = 8;   // was 8   (four lanes, same)
      want_acc[2] = 4;   // was 4   (two full-word pairs, one two-word request each)
      want_acc[3] = 4;   // was 4   (two full-word pairs)
      want_acc[4] = 4;   // was 4   (the enabled columns as one burst)
      want_acc[5] = 2;   // was 2   (the unit's column pair, written as one request)
      want_acc[6] = 4;   // was 4   (two units, one column pair each)
      want_acc[7] = 4;   // was 4
      want_acc[8] = 4;   // was 4   (the covered columns as one burst)
      // CPU-hold clk_sys for ONE operation: the array accesses plus whatever the engine adds.
      // Every GRCG bound is FAIL-FIRST: the pre-change tree's number is in the comment and is
      // 2-3 larger.
      max_hold[0] = 4;   // was 6   (a presentation state and a write tail, both removed)
      max_hold[1] = 8;   // was 10
      max_hold[2] = 5;   // was 8   (plus the second pair presented in place, not through G_TD)
      max_hold[3] = 5;   // was 8
      max_hold[4] = 7;   // was 7   (a READ keeps its accept/response pair of tail states)
      max_hold[5] = 6;   // was 6   (guard: the EGC's hold is not shortened)
      max_hold[6] = 12;  // was 12
      max_hold[7] = 12;  // was 12
      // E4 is the only READ shape, so it is the only row the pipelined produce moves:
      // the read response registers one cycle after the ready, so the CPU hold is +1 (14 -> 15).
      // The values are unchanged (EGCREAD.CSV / the machine vectors) and the +1 stays under the
      // machine's measured read cost (docs/probes/GFX2-rerun.TXT EGC3100SP: 780.3 CLK50 for 16
      // units = 48.75/unit against our ~21), which is the licence for it.
      // egc-serial: the plane-serial engine steps the four planes of each unit in turn (the
      // loop's four steps replace the one-cycle evaluate, and a read's ready now leaves from the
      // last step), +3 for the first unit and +2 for the second: 20 clk_sys for the dword, 400 ns
      // at this bench's 50 MHz, against the machine's 975 ns PER 16-BIT UNIT (GFX2-rerun.TXT above).
      max_hold[8] = 20;  // was 15 (14 before the pipelined produce)
    end
  endtask

  // ==== CHECKS ====
  integer n, i;
  reg [7:0] bv;
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
    repeat (30) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);
    describe;

    // ---- G1: the GRCG RMW merge TH05's sprite erase issues - a MIXED datum, so every enabled
    // lane reads its old word and writes its merged one. Four accesses is the floor. ----
    seed_cols(BASE, 8'h3C, 8'h5A, 8'hC3, 8'h7E);
    port_w(8'h7C, 8'hC0); put_tiles(8'h11, 8'h22, 8'h44, 8'h88);
    op_measured(PLANE, BASE, 32'h0000_5A5A, 4'h3, 1'b1, accesses[0], hold[0]);
    port_w(8'h7C, 8'h00);
    check(0);
    for (i = 0; i < 2; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== ((8'h3C & ~8'h5A) | (8'h11 & 8'h5A))) fail("G1 plane B merge");
      peek(2'd1, BASE + i, bv); if (bv !== ((8'h5A & ~8'h5A) | (8'h22 & 8'h5A))) fail("G1 plane R merge");
      peek(2'd2, BASE + i, bv); if (bv !== ((8'hC3 & ~8'h5A) | (8'h44 & 8'h5A))) fail("G1 plane G merge");
      peek(2'd3, BASE + i, bv); if (bv !== ((8'h7E & ~8'h5A) | (8'h88 & 8'h5A))) fail("G1 plane E merge");
    end
    for (i = 2; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== 8'h3C) fail("G1 column outside the enables changed");
    end

    // ---- G2: the same merge over a full dword, which is the shape master.lib's
    // graph_clear arms TDW for but a RMW erase issues. Eight accesses is the floor. ----
    seed_cols(BASE, 8'h3C, 8'h5A, 8'hC3, 8'h7E);
    port_w(8'h7C, 8'hC0); put_tiles(8'h11, 8'h22, 8'h44, 8'h88);
    op_measured(PLANE, BASE, 32'h5A5A_5A5A, 4'hF, 1'b1, accesses[1], hold[1]);
    port_w(8'h7C, 8'h00);
    check(1);
    for (i = 0; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== ((8'h3C & ~8'h5A) | (8'h11 & 8'h5A))) fail("G2 plane B merge");
      peek(2'd3, BASE + i, bv); if (bv !== ((8'h7E & ~8'h5A) | (8'h88 & 8'h5A))) fail("G2 plane E merge");
    end

    // ---- G3: an all-planes RMW with a 0xFF datum takes the two-word request, one per column
    // pair: two requests, four accesses, and the SECOND pair is presented in place. ----
    seed_cols(BASE, 8'h3C, 8'h5A, 8'hC3, 8'h7E);
    port_w(8'h7C, 8'hC0); put_tiles(8'h11, 8'h22, 8'h44, 8'h88);
    op_measured(PLANE, BASE, 32'hFFFF_FFFF, 4'hF, 1'b1, accesses[2], hold[2]);
    port_w(8'h7C, 8'h00);
    check(2);
    for (i = 0; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== 8'h11) fail("G3 plane B must take the tile byte");
      peek(2'd1, BASE + i, bv); if (bv !== 8'h22) fail("G3 plane R must take the tile byte");
      peek(2'd2, BASE + i, bv); if (bv !== 8'h44) fail("G3 plane G must take the tile byte");
      peek(2'd3, BASE + i, bv); if (bv !== 8'h88) fail("G3 plane E must take the tile byte");
    end

    // ---- G4: a TDW fill, the same burst with the CPU datum ignored. ----
    seed_cols(BASE, 8'h3C, 8'h5A, 8'hC3, 8'h7E);
    port_w(8'h7C, 8'h80); put_tiles(8'h11, 8'h22, 8'h44, 8'h88);
    op_measured(PLANE, BASE, 32'hDEAD_BEEF, 4'hF, 1'b1, accesses[3], hold[3]);
    port_w(8'h7C, 8'h00);
    check(3);
    for (i = 0; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== 8'h11) fail("G4 plane B must take the tile byte");
      peek(2'd3, BASE + i, bv); if (bv !== 8'h88) fail("G4 plane E must take the tile byte");
    end

    // ---- G5: the TCR read, whose accept and response MUST be separate cycles, so this is a
    // GUARD that the store change did not shorten the read's tail. ----
    seed_cols(BASE, 8'h3C, 8'h5A, 8'hC3, 8'h7E);
    port_w(8'h7C, 8'h80); put_tiles(8'h11, 8'h22, 8'h44, 8'h88);
    op_measured(PLANE, BASE, 32'd0, 4'hF, 1'b0, accesses[4], hold[4]);
    port_w(8'h7C, 8'h00);
    check(4);

    // ---- E1-E4: the EGC's shapes. These assert the ARRAY floor and the hold the next lane must
    // move; they are not wins here (see the header). 0x1400 = WS_PATREG | SHIFT_CPU with the
    // foreground quad, a fill that needs no destination fetch; 0x28F0 = a shifted ROP copy;
    // 0x3100 = COMPAREREAD | WS_PATREG | RL_MEMREAD. ----
    plain_store(2'd0, BASE, 32'h0000_0000);
    port_w(8'h7C, 8'h00);
    egc_access = 16'h0000; egc_ope = 16'h1400; egc_fgbg = 16'h4000;
    egc_fg = 16'h000F; egc_mask = 16'hFFFF; egc_leng = 16'h0FFF; egc_sft = 16'h0000;
    egc_shift_we = 1; @(negedge clk); egc_shift_we = 0;
    egc_gate = 1;
    op_measured(PLANE, BASE, 32'h0000_0000, 4'h3, 1'b1, accesses[5], hold[5]);
    check(5);
    for (i = 0; i < 2; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== 8'hFF) fail("E1 plane B fill byte");
      peek(2'd3, BASE + i, bv); if (bv !== 8'hFF) fail("E1 plane E fill byte");
    end

    plain_store(2'd0, BASE, 32'h0000_0000);
    port_w(8'h7C, 8'h00);
    egc_access = 16'h0000; egc_ope = 16'h1400; egc_fgbg = 16'h4000;
    egc_fg = 16'h000F; egc_mask = 16'hFFFF; egc_leng = 16'h0FFF; egc_sft = 16'h0000;
    egc_shift_we = 1; @(negedge clk); egc_shift_we = 0;
    egc_gate = 1;
    op_measured(PLANE, BASE, 32'h0000_0000, 4'hF, 1'b1, accesses[6], hold[6]);
    egc_gate = 0;
    check(6);
    for (i = 0; i < 4; i = i + 1) begin
      peek(2'd0, BASE + i, bv); if (bv !== 8'hFF) fail("E2 plane B fill byte");
    end

    plain_store(2'd0, BASE, 32'h1234_5678);
    port_w(8'h7C, 8'h00);
    egc_access = 16'h0000; egc_ope = 16'h28F0; egc_fgbg = 16'h0000;
    egc_fg = 16'h000F; egc_mask = 16'hFFFF; egc_leng = 16'h0FFF; egc_sft = 16'h0022;
    egc_shift_we = 1; @(negedge clk); egc_shift_we = 0;
    egc_gate = 1;
    op_measured(PLANE, BASE, 32'h0000_0000, 4'hF, 1'b1, accesses[7], hold[7]);
    egc_gate = 0;
    check(7);

    plain_store(2'd0, BASE, 32'hCAFE_BABE);
    port_w(8'h7C, 8'h00);
    egc_access = 16'h0000; egc_ope = 16'h3100; egc_fgbg = 16'h0000;
    egc_mask = 16'hFFFF; egc_leng = 16'h0FFF; egc_sft = 16'h0000;
    egc_shift_we = 1; @(negedge clk); egc_shift_we = 0;
    egc_gate = 1;
    op_measured(PLANE, BASE, 32'd0, 4'hF, 1'b0, accesses[8], hold[8]);
    egc_gate = 0;
    check(8);

    // ---- The report: the two numbers, side by side, per operation ----
    for (n = 0; n < NB; n = n + 1)
      $display("NOTE gfx_engine_hold: %0s: %0d array accesses, %0d clk_sys CPU hold",
               pname[n], accesses[n], hold[n]);

    bad = errors;
    if (bad != 0) begin
      $display("TB_PC9821_GFX_ENGINE_HOLD: FAIL (%0d checks)", bad);
      $fatal(1);
    end
    $display("TB_PC9821_GFX_ENGINE_HOLD: PASS");
    $finish;
  end

  initial begin
    #1_000_000;
    $fatal(1, "the engine-hold bench did not finish in 1 ms of simulated time");
  end

endmodule

`default_nettype wire

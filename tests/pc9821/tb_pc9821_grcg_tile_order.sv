`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GRCG_TILE_ORDER: a GRCG store uses the tile registers in effect when the CPU issued it, never a tile written by a later OUT 0x7E. The GVRAM accepts a decoupled GRCG store only after the previous store's period (GVRAM_GR_HOLD, ns-derived, so more clk_sys at a faster clk_sys), and the guest's next instructions - four OUT 0x7E tile loads in Viper CTR's column RLE (SGS386 0040:0298) - run inside that wait; the walk latched the LIVE tile at the GVRAM accept and wrote the NEXT tile. Expected values: the 486 bus is in order (the OUT follows the store) and NP2kai memtdw/memrmw write grcg.tile at the store. Cases at the 100 MHz bench clock: a TDW byte store, a TDW 16-bit (pair-burst) store and a 16-bit RMW store, each issued right behind another GRCG store and followed at once by a full tile reload, then read back plane by plane; FAILS on the live-tile walk, PASSES with the tile captured with the store.
//
// The header above is the manifest claim VERBATIM (tools/check_tests.py holds the two together).
// The DUT, its port drivers and the plain-path helpers are tb_pc9821_gvram_decouple's.
//
`default_nettype none

module tb_pc9821_grcg_tile_order;
  localparam integer CYCLE_NS = 10;

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

  pc9821_gvram_dut #(.SYS_CLOCK_HZ(100_000_000)) dut (
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


  // ==== CHECKS ====
  localparam [14:0] BASE = 15'h0900;
  reg [7:0] v;
  integer i;

  // A GRCG store presented the way z486 presents it after a decoupled ready: no drain wait.
  task automatic grcg_store(input [14:0] off, input [31:0] d, input [3:0] be);
    begin
      @(negedge clk);
      win_plane = 2'd0; win_offset = off; cpu_din = d; cpu_be = be;
      cpu_write = 1; cpu_valid = 1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk); cpu_valid = 0; cpu_write = 0; cpu_be = 4'hF;
    end
  endtask

  // One tile reload issued the cycle after the store's ready (the OUTSB x4 that follows the
  // game's stosb), one port write per clk_sys.
  task automatic tiles_now(input [7:0] b, input [7:0] r, input [7:0] g, input [7:0] e);
    begin
      grcg_addr = 8'h7E; grcg_din = b; grcg_we = 1; @(negedge clk);
      grcg_din = r; @(negedge clk);
      grcg_din = g; @(negedge clk);
      grcg_din = e; @(negedge clk);
      grcg_we = 0;
    end
  endtask

  // The case: mode M, tile A; store #1 at BASE (arms the GVRAM period), store #2 at col right
  // behind it, then tile B at once. Column col must hold store #2's merge with tile A.
  task automatic run_case(input [7:0] mode, input [14:0] col, input [31:0] d2, input [3:0] be2,
                          input [8*40-1:0] name);
    reg [7:0] ta [0:3];
    reg [7:0] want, dbyte;
    integer p, l;
    begin
      ta[0] = 8'h11; ta[1] = 8'h22; ta[2] = 8'h44; ta[3] = 8'h88;
      for (l = 0; l < 4; l = l + 1) for (p = 0; p < 4; p = p + 1) begin
        plain_store_be(p[1:0], {col[14:2], 2'b00}, 32'h0000_0000, 4'hF);
      end
      port_w(8'h7C, mode); put_tiles(ta[0], ta[1], ta[2], ta[3]);
      grcg_store(BASE, 32'hFFFF_FFFF, 4'h1);   // #1: occupies the GVRAM for its period
      grcg_store(col, d2, be2);                // #2: captured, accepted only after the period
      tiles_now(8'hEE, 8'hDD, 8'hBB, 8'h77);   // tile B, inside that wait
      drain;
      port_w(8'h7C, 8'h00);
      for (l = 0; l < 4; l = l + 1) if (be2[l]) begin
        dbyte = d2[l*8 +: 8];
        for (p = 0; p < 4; p = p + 1) begin
          peek(p[1:0], {col[14:2], l[1:0]}, v);
          want = mode[6] ? (8'h00 & ~dbyte) | (ta[p] & dbyte) : ta[p];
          if (v !== want) begin
            $display("FAIL %0s: plane %0d lane %0d = %02x, want %02x (the tile in effect at the store)",
                     name, p, l, v, want);
            errors = errors + 1;
          end
        end
      end
    end
  endtask

  // ==== VERDICT ====
  initial begin
    reset = 1'b1;
    repeat (30) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);
    run_case(8'h80, BASE + 15'd80, 32'h0000_0080, 4'h1, "TDW byte store (the walk)");
    run_case(8'h80, BASE + 15'd160, 32'h0000_0000, 4'h3, "TDW 16-bit store (pair burst)");
    run_case(8'hC0, BASE + 15'd240, 32'h0000_5AA5, 4'h3, "RMW 16-bit mixed datum (the walk)");
    if (errors != 0) begin
      $display("TB_PC9821_GRCG_TILE_ORDER: FAIL (%0d checks)", errors);
      $fatal(1);
    end
    $display("TB_PC9821_GRCG_TILE_ORDER: PASS");
    $finish;
  end

  initial begin
    #1_000_000;
    $fatal(1, "the tile-order bench did not finish in 1 ms of simulated time");
  end

endmodule

`default_nettype wire

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GVRAM_STORE_ORDER: every decoupled GVRAM store (plain, GRCG, EGC) is executed with the device state in effect when the CPU issued it, and a port write issued after its ready changes only the stores after it. The plain path, the GRCG and the EGC each pulse the store's ready at their CAPTURE while the array takes it later (the ns-derived GVRAM period behind the previous store, or the EGC's produce), so the guest's next OUT lands inside that wait; the store must not read the access page (0xA6), the GRCG mode (0x7C: plane enables, TDW/RMW, the GRCG gate), the EGC gate (0x6A) or the EGC register file (0x4A0-0x4AF) at the later accept. Expected values: the 486 bus is in order (the OUT follows the store) and NP2kai performs each store atomically with the registers of its moment (mem/memvram.c, memtdw/memrmw, mem/memegc.c egc_writebyte). Cases at the 100 MHz bench clock, each store issued right behind another so it waits, and the state changed in the cycle after its ready (and checked to land BEFORE the array accepted it): a plain store vs a 0xA6 page flip; GRCG stores vs a 0xA6 page flip, a plane-enable change, an RMW-to-TDW change and the GRCG turned off; a plain store vs the GRCG and the EGC turned on; an EGC store vs a new register file, a shifter re-arm and the EGC turned off, with the next EGC store taking the new registers.
//
// The header above is the manifest claim VERBATIM (tools/check_tests.py holds the two together).
// The DUT, its port drivers and the plain-path helpers are tb_pc9821_grcg_tile_order's.
//
`default_nettype none

module tb_pc9821_gvram_store_order;
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
  reg [15:0] egc_access = 16'hFFF0, egc_fgbg = 16'h00FF, egc_ope = 16'd0,
             egc_fg = 16'd0, egc_mask = 16'hFFFF, egc_bg = 16'd0,
             egc_sft = 16'd0, egc_leng = 16'h000F;
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

  integer errors = 0;

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

  task automatic drain;
    begin
      while ((dut.u_arb.gstate != 3'd0) || dut.u_arb.m_mode || (dut.u_arb.cs != 4'd0) ||
             (dut.u_grcg.gstate != 4'd0) || (dut.u_egc.state != 4'd0)) @(posedge clk);
      repeat (40) @(posedge clk);   // and every GVRAM period runs out
    end
  endtask

  // Every engine off, the default EGC register file (NP2kai egc_reset), page 0.
  task automatic quiet;
    begin
      @(negedge clk);
      egc_gate = 0; access_page = 0;
      egc_access = 16'hFFF0; egc_fgbg = 16'h00FF; egc_ope = 16'd0; egc_fg = 16'd0;
      egc_mask = 16'hFFFF; egc_bg = 16'd0; egc_sft = 16'd0; egc_leng = 16'h000F;
      port_w(8'h7C, 8'h00);
    end
  endtask

  // A CPU store presented the way z486 presents it after a decoupled ready: no drain wait.
  // The caller has set up the engines.
  task automatic store(input [1:0] plane, input [14:0] off, input [31:0] d, input [3:0] be);
    begin
      @(negedge clk);
      win_plane = plane; win_offset = {off[14:2], 2'b00}; cpu_din = d; cpu_be = be;
      cpu_write = 1; cpu_valid = 1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk); cpu_valid = 0; cpu_write = 0; cpu_be = 4'hF;
    end
  endtask

  // Plane p's byte at column c on page pg, through the PLAIN path (every engine off).
  task automatic peek(input pg, input [1:0] p, input [14:0] c, output [7:0] v);
    reg [31:0] d;
    begin
      quiet;
      @(negedge clk);
      access_page = pg;
      win_plane = p; win_offset = {c[14:2], 2'b00};
      cpu_din = 32'd0; cpu_be = (4'h1 << c[1:0]); cpu_write = 0; cpu_valid = 1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      while (!cpu_resp_valid) @(negedge clk);
      #1; d = cpu_dout;
      @(negedge clk); cpu_valid = 0; cpu_be = 4'hF; access_page = 0;
      drain;
      v = d[{c[1:0], 3'b000} +: 8];
    end
  endtask

  // Zero one column (all four planes) on both pages, plainly.
  task automatic clear_col(input [14:0] c);
    integer p, pg;
    begin
      for (pg = 0; pg < 2; pg = pg + 1) for (p = 0; p < 4; p = p + 1) begin
        quiet;
        @(negedge clk); access_page = pg[0];
        store(p[1:0], c, 32'h0000_0000, 4'hF);
        drain;
      end
      quiet;
    end
  endtask

  task automatic expect_col(input pg, input [14:0] c, input [31:0] want, input [8*48-1:0] name);
    // want = {E,G,R,B}: the byte each plane must hold at column c on page pg
    reg [7:0] v;
    integer p;
    begin
      for (p = 0; p < 4; p = p + 1) begin
        peek(pg, p[1:0], c, v);
        if (v !== want[p*8 +: 8]) begin
          $display("FAIL %0s: page %0d plane %0d col %04x = %02x, want %02x",
                   name, pg, p, c, v, want[p*8 +: 8]);
          errors = errors + 1;
        end
      end
    end
  endtask

  // The state change must land while the store is still waiting for the array, or the case
  // proves nothing: the GRCG's / the plain path's presentation is still held, the EGC's produce
  // still runs.
  task automatic must_wait(input pending, input [8*48-1:0] name);
    begin
      if (!pending) begin
        $display("FAIL %0s: the store was already accepted when the state changed (vacuous case)", name);
        errors = errors + 1;
      end
    end
  endtask

  // ==== CHECKS ====
  localparam [14:0] BASE = 15'h0A00;
  localparam [7:0]  T_B = 8'h11, T_R = 8'h22, T_G = 8'h44, T_E = 8'h88;
  localparam [31:0] TILE = {T_E, T_G, T_R, T_B};

  // (1) A plain store behind a plain store (the 142 ns write period), then OUT 0xA6.
  task automatic case_plain_page;
    localparam [14:0] C = BASE + 15'd4;
    begin
      clear_col(C);
      store(2'd1, BASE, 32'h0000_00FF, 4'h1);
      store(2'd1, C, 32'h0000_005A, 4'h1);
      must_wait(dut.u_arb.c_cl_valid, "plain vs 0xA6");
      access_page = 1'b1;                       // OUT 0xA6,1 right after the ready
      drain;
      expect_col(1'b0, C, {8'h00, 8'h00, 8'h5A, 8'h00}, "plain vs 0xA6 (page 0)");
      expect_col(1'b1, C, 32'h0000_0000, "plain vs 0xA6 (page 1 untouched)");
    end
  endtask

  // A GRCG store behind a GRCG store (the 104 ns GRCG period), then `change`.
  task automatic grcg_pair(input [7:0] mode, input [14:0] c, input [31:0] d, input [3:0] be);
    begin
      port_w(8'h7C, mode); put_tiles(T_B, T_R, T_G, T_E);
      store(2'd0, BASE, 32'hFFFF_FFFF, 4'h1);
      store(2'd0, c, d, be);
    end
  endtask

  // (2) GRCG TDW store, then OUT 0xA6.
  task automatic case_grcg_page;
    localparam [14:0] C = BASE + 15'd8;
    begin
      clear_col(C);
      grcg_pair(8'h80, C, 32'h0000_0000, 4'h1);
      must_wait(dut.u_grcg.cl_valid_r, "GRCG vs 0xA6");
      access_page = 1'b1;
      drain;
      expect_col(1'b0, C, TILE, "GRCG TDW vs 0xA6 (page 0)");
      expect_col(1'b1, C, 32'h0000_0000, "GRCG TDW vs 0xA6 (page 1 untouched)");
    end
  endtask

  // The 0x7C write the CPU issues right after the ready, one clk_sys.
  task automatic out7c_now(input [7:0] m);
    begin
      grcg_addr = 8'h7C; grcg_din = m; grcg_we = 1; @(negedge clk); grcg_we = 0;
    end
  endtask

  // (3) GRCG TDW with planes B,G only (0x8A), then OUT 0x7C,0x80 (all planes).
  task automatic case_grcg_planes;
    localparam [14:0] C = BASE + 15'd12;
    begin
      clear_col(C);
      grcg_pair(8'h8A, C, 32'h0000_0000, 4'h1);
      must_wait(dut.u_grcg.cl_valid_r, "GRCG vs plane enables");
      out7c_now(8'h80);
      drain;
      expect_col(1'b0, C, {8'h00, T_G, 8'h00, T_B}, "GRCG TDW vs 0x7C plane enables");
    end
  endtask

  // (4) GRCG RMW with datum 0x5A, then OUT 0x7C,0x80 (TDW): the store stays RMW.
  task automatic case_grcg_rmw;
    localparam [14:0] C = BASE + 15'd16;
    begin
      clear_col(C);
      grcg_pair(8'hC0, C, 32'h0000_005A, 4'h1);
      must_wait(dut.u_grcg.cl_valid_r, "GRCG RMW vs TDW");
      out7c_now(8'h80);
      drain;
      expect_col(1'b0, C, TILE & {4{8'h5A}}, "GRCG RMW vs 0x7C RMW-to-TDW");
    end
  endtask

  // (5) GRCG TDW, then OUT 0x7C,0x00 (GRCG off): the store is still the GRCG's.
  task automatic case_grcg_off;
    localparam [14:0] C = BASE + 15'd20;
    begin
      clear_col(C);
      grcg_pair(8'h80, C, 32'h0000_0033, 4'h1);
      must_wait(dut.u_grcg.cl_valid_r, "GRCG vs off");
      out7c_now(8'h00);
      drain;
      expect_col(1'b0, C, TILE, "GRCG TDW vs 0x7C GRCG off");
    end
  endtask

  // (6) A plain store waiting, then OUT 0x7C,0x80 (GRCG TDW on): the store stays plain.
  task automatic case_plain_grcg_on;
    localparam [14:0] C = BASE + 15'd24;
    begin
      clear_col(C);
      put_tiles(T_B, T_R, T_G, T_E);    // the pointer is reset again by the 0x7C below
      store(2'd2, BASE, 32'h0000_00FF, 4'h1);
      store(2'd2, C, 32'h0000_0066, 4'h1);
      must_wait(dut.u_arb.c_cl_valid, "plain vs GRCG on");
      out7c_now(8'h80);
      drain;
      expect_col(1'b0, C, {8'h00, 8'h66, 8'h00, 8'h00}, "plain vs 0x7C GRCG on");
    end
  endtask

  // (7) A plain store waiting, then the EGC gate on (OUT 0x6A): the store stays plain.
  task automatic case_plain_egc_on;
    localparam [14:0] C = BASE + 15'd28;
    begin
      clear_col(C);
      egc_ope = 16'h0000; egc_access = 16'hFFF0; egc_mask = 16'hFFFF;
      store(2'd3, BASE, 32'h0000_00FF, 4'h1);
      store(2'd3, C, 32'h0000_0077, 4'h1);
      must_wait(dut.u_arb.c_cl_valid, "plain vs EGC on");
      egc_gate = 1'b1;
      drain;
      expect_col(1'b0, C, {8'h77, 8'h00, 8'h00, 8'h00}, "plain vs 0x6A EGC on");
    end
  endtask

  // (8) EGC byte stores (ope 0x0000, the CPU datum: NP2kai egc_opeb's default arm, mask2 =
  // mask, every enabled plane gets (old & ~mask) | (datum & mask)). Store A with the file
  // {access FFF0, mask 00F0}, then at once a new file {access FFFE, mask 000F, fg/bg/fgbg
  // moved, a 0x4AC re-arm}; store B after it takes the new file. Then store C with the EGC
  // turned off at once (C is a 16-bit unit, the EGC's posted burst): C is still the EGC's, and a plain store D after it is plain.
  task automatic case_egc;
    localparam [14:0] CA = BASE + 15'd32, CB = BASE + 15'd36, CC = BASE + 15'd40,
                      CD = BASE + 15'd44;
    begin
      clear_col(CA); clear_col(CB); clear_col(CC); clear_col(CD);
      @(negedge clk);
      egc_ope = 16'h0000; egc_access = 16'hFFF0; egc_mask = 16'h00F0;
      egc_fgbg = 16'h00FF; egc_fg = 16'h0000; egc_bg = 16'h0000;
      egc_gate = 1'b1;
      store(2'd0, CA, 32'h0000_00A5, 4'h1);
      must_wait(dut.u_egc.state != 4'd0, "EGC vs register file");
      egc_access = 16'hFFFE; egc_mask = 16'h000F; egc_fg = 16'h000F; egc_bg = 16'h0005;
      egc_fgbg = 16'h4000; egc_sft = 16'h0003; egc_leng = 16'h0007; egc_shift_we = 1'b1;
      @(negedge clk); egc_shift_we = 1'b0;
      egc_fgbg = 16'h00FF;   // back to the CPU-datum class for store B (the ope is still 0)
      store(2'd0, CB, 32'h0000_00C3, 4'h1);
      drain;
      @(negedge clk);
      egc_access = 16'hFFF0; egc_mask = 16'hFFFF; egc_sft = 16'h0000; egc_leng = 16'h000F;
      egc_shift_we = 1'b1; @(negedge clk); egc_shift_we = 1'b0;
      store(2'd0, CC, 32'h0000_3C3C, 4'h3);     // a 16-bit unit: the posted two-column burst
      must_wait(dut.u_egc.state != 4'd0, "EGC vs EGC off");
      egc_gate = 1'b0;                          // OUT 0x6A: the EGC off
      store(2'd1, CD, 32'h0000_0099, 4'h1);     // a plain store, issued after the OUT
      drain;
      expect_col(1'b0, CA, {4{8'hA5 & 8'hF0}}, "EGC store A vs a later register file");
      expect_col(1'b0, CB, {8'h00, 8'h00, 8'h00, 8'hC3 & 8'h0F}, "EGC store B takes the new file");
      expect_col(1'b0, CC, {4{8'h3C}}, "EGC store C vs a later 0x6A off");
      expect_col(1'b0, CC + 15'd1, {4{8'h3C}}, "EGC store C (high byte) vs a later 0x6A off");
      expect_col(1'b0, CD, {8'h00, 8'h00, 8'h99, 8'h00}, "plain store D after the 0x6A off");
    end
  endtask

  // ==== VERDICT ====
  initial begin
    reset = 1'b1;
    repeat (30) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);
    case_plain_page;
    case_grcg_page;
    case_grcg_planes;
    case_grcg_rmw;
    case_grcg_off;
    case_plain_grcg_on;
    case_plain_egc_on;
    case_egc;
    if (errors != 0) begin
      $display("TB_PC9821_GVRAM_STORE_ORDER: FAIL (%0d checks)", errors);
      $fatal(1);
    end
    $display("TB_PC9821_GVRAM_STORE_ORDER: PASS");
    $finish;
  end

  initial begin
    #5_000_000;
    $fatal(1, "the store-order bench did not finish in 5 ms of simulated time");
  end

endmodule

`default_nettype wire

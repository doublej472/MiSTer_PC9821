`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_EGC_RESP_OWNER: a GUARD for pc9821_gvram_arb's strobe-routed CPU response (the TB timing cut): an EGC-owned CPU word read, with the CPU holding its request through the ready edge as z486 does (src/z486/bus_unit.sv clears ext_valid_r at the accept edge) and a GDC draw visit already waiting so that pc9821_gvram_share grants it at the earliest legal cycle, is answered on the SAME cycle and with the SAME datum as the same read with no visit behind it - for a plain-store, a GRCG-routed-store and a plain-read visit - and every visit completes; in the EGC strobe's cycle the share still presents the CPU, which is the handshake fact that makes the cut cycle-identical to the old owner mux. Not fail-first: the old mux answers these reads too.
//
// The header above is the manifest claim VERBATIM (tools/check_tests.py holds the two together).
// The shape: a reference EGC read alone (its latency from the accept and its datum), then the same
// read with a GDC visit presented in the read's ready cycle - once as a plain store, once as a
// GRCG-routed store, once as a plain read - each compared against the reference.
`default_nettype none

module tb_pc9821_egc_resp_owner;
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
  reg [15:0] egc_access = 16'hFFF0, egc_fgbg = 16'h00FF, egc_ope = 16'h00F0,
             egc_fg = 16'd0, egc_mask = 16'hFFFF, egc_bg = 16'd0,
             egc_sft = 16'd0, egc_leng = 16'h000F;
  reg        egc_shift_we = 1'b0;

  reg        gdc_mem_valid = 1'b0, gdc_mem_write = 1'b0;
  reg        gdc_mem_route_egc = 1'b0, gdc_mem_route_grcg = 1'b0, gdc_mem_page = 1'b0;
  reg  [1:0] gdc_mem_plane = 2'd0;
  reg [14:0] gdc_mem_offset = 15'd0;
  reg [31:0] gdc_mem_din = 32'd0;
  reg  [3:0] gdc_mem_be = 4'hF;
  wire       gdc_mem_ready, gdc_mem_resp;
  wire [31:0] gdc_mem_rdata;

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
      .gdc_mem_valid(gdc_mem_valid), .gdc_mem_ready(gdc_mem_ready),
      .gdc_mem_write(gdc_mem_write), .gdc_mem_route_egc(gdc_mem_route_egc),
      .gdc_mem_route_grcg(gdc_mem_route_grcg), .gdc_mem_page(gdc_mem_page),
      .gdc_mem_plane(gdc_mem_plane), .gdc_mem_offset(gdc_mem_offset),
      .gdc_mem_din(gdc_mem_din), .gdc_mem_be(gdc_mem_be),
      .gdc_mem_resp(gdc_mem_resp), .gdc_mem_rdata(gdc_mem_rdata),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));

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

  task automatic drain;
    begin
      while ((dut.u_arb.gstate != 3'd0) || dut.u_arb.m_mode || (dut.u_arb.cs != 4'd0) ||
             (dut.u_grcg.gstate != 4'd0) || (dut.u_egc.state != 4'd0) ||
             dut.u_gvr_share.gdc_own_q) @(posedge clk);
      repeat (3) @(posedge clk);
    end
  endtask

  // A plain store, to give the read column a known pattern on every plane.
  task automatic plain_store(input [1:0] plane, input [14:0] off, input [31:0] d);
    begin
      egc_gate = 0;
      @(negedge clk);
      win_plane = plane; win_offset = off; cpu_din = d; cpu_be = 4'hF;
      cpu_write = 1; cpu_valid = 1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk); cpu_valid = 0; cpu_write = 0;
      drain;
    end
  endtask

  // ==== CHECKS ====
  // An EGC word read of `off`. `visit` 0 = none; 1 = a plain GDC store, 2 = a GRCG-routed GDC
  // store, 3 = a plain GDC read, each presented the cycle the CPU drops its accepted read (the
  // first cycle pc9821_gvram_share can grant it). Returns the accept-to-strobe latency (-1 if the
  // strobe never came), the datum, and whether the visit completed.
  task automatic egc_read(input [14:0] off, input integer visit,
                          output integer lat, output [31:0] dat, output reg visit_done);
    integer n;
    reg got, drop_next, cpu_drop;
    begin
      egc_gate = 1;
      @(negedge clk);
      win_plane = 2'd0; win_offset = off; cpu_be = 4'h3; cpu_write = 0; cpu_valid = 1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      // The ready is high in this cycle (T0); the accept edge is the NEXT posedge. z486 holds its
      // request through it (src/z486/bus_unit.sv `if (ready) begin` clears ext_valid_r AT the edge),
      // so cpu_valid drops only after that edge, in the first loop iteration below. The GDC visit
      // is already waiting in T0 (a master may present at any time): the share grants it as soon
      // as cpu_req is low, which is the earliest legal grant.
      @(negedge clk);
      if (visit != 0) begin
        gdc_mem_valid = 1; gdc_mem_write = (visit != 3);
        gdc_mem_route_egc = 0; gdc_mem_route_grcg = (visit == 2);
        gdc_mem_plane = 2'd1; gdc_mem_offset = off + 15'd64; gdc_mem_din = 32'hA5A5_A5A5;
        gdc_mem_be = 4'hF;
      end
      n = 0; got = 0; drop_next = 0; dat = 32'hDEAD_BEEF; visit_done = (visit == 0);
      cpu_drop = 1;
      while (n < 400 && !(got && visit_done && !drop_next)) begin
        @(posedge clk); #1; n = n + 1;
        if (cpu_drop) begin cpu_valid = 0; cpu_drop = 0; end   // after the accept edge
        if (cpu_resp_valid && !got) begin
          got = 1; lat = n; dat = cpu_dout;
          // The handshake argument the routing's identity rests on: in the strobe's cycle the
          // share still presents the CPU (the visit's grant comes later).
          if (dut.u_gvr_share.gdc_own_q) fail("a GDC visit owned the port in the EGC strobe's cycle");
        end
        // the visit holds its request through its ready's cycle and drops it after the edge that
        // takes it, as pc9821_gdc2 does (pc9821_gvram_share R7)
        if (drop_next) begin
          gdc_mem_valid = 0; gdc_mem_write = 0; gdc_mem_route_grcg = 0; drop_next = 0;
        end
        if (gdc_mem_valid && gdc_mem_ready) begin
          drop_next = 1;
          if (visit != 3) visit_done = 1;
        end
        if (visit == 3 && gdc_mem_resp) visit_done = 1;
      end
      if (!got) lat = -1;
      if (!got || !visit_done) begin
        // A stuck cluster cannot be drained (and a visit must not be withdrawn before its ready,
        // pc9821_gvram_share R7): report and stop here.
        $display("FAIL visit %0d: CPU answer %0s, visit %0s after %0d clk", visit,
                 got ? "seen" : "NEVER seen", visit_done ? "completed" : "NOT completed", n);
        $display("TB_PC9821_EGC_RESP_OWNER: FAIL");
        $fatal(1, "TB_PC9821_EGC_RESP_OWNER failed");
      end
      @(negedge clk); gdc_mem_valid = 0; egc_gate = 0;
      drain;
    end
  endtask

  // ==== VERDICT ====
  integer ref_lat, lat;
  reg [31:0] ref_dat, dat;
  reg vdone;
  integer v;

  initial begin
    reset = 1'b1;
    repeat (30) @(posedge clk);
    reset = 1'b0;
    repeat (50) @(posedge clk);   // past the EGC's 32-cycle post-reset ring scrub
    port_w(8'h7C, 8'h00);          // the GRCG off for the CPU's pattern stores
    plain_store(2'd0, 15'h0100, 32'h1234_5678);
    plain_store(2'd1, 15'h0100, 32'h9ABC_DEF0);
    plain_store(2'd2, 15'h0100, 32'h0F1E_2D3C);
    plain_store(2'd3, 15'h0100, 32'h4B5A_6978);
    port_w(8'h7C, 8'h80);          // a GRCG mode for the GRCG-routed visit (TDW)

    egc_read(15'h0100, 0, ref_lat, ref_dat, vdone);
    $display("reference EGC read: strobe %0d clk after the accept, datum %08x", ref_lat, ref_dat);
    if (ref_lat < 0) fail("the reference EGC read was never answered");

    for (v = 1; v <= 3; v = v + 1) begin
      egc_read(15'h0100, v, lat, dat, vdone);
      $display("visit %0d: strobe %0d clk after the accept, datum %08x, visit %0s",
               v, lat, dat, vdone ? "completed" : "NOT completed");
      if (lat < 0) fail("the CPU's EGC read was never answered with a GDC visit granted behind it");
      else if (lat != ref_lat) fail("the EGC answer moved by a GDC visit behind it");
      if (lat >= 0 && dat != ref_dat) fail("the EGC answer's datum changed by a GDC visit behind it");
      if (!vdone) fail("the GDC visit did not complete");
    end

    if (errors != 0) begin
      $display("TB_PC9821_EGC_RESP_OWNER: FAIL (%0d checks)", errors);
      $fatal(1, "TB_PC9821_EGC_RESP_OWNER failed");
    end
    $display("TB_PC9821_EGC_RESP_OWNER: PASS");
    $finish;
  end

  initial begin
    #(2_000_000);
    $fatal(1, "TB_PC9821_EGC_RESP_OWNER did not finish in 2 ms of simulated time");
  end
endmodule

`default_nettype wire

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GVRAM_LINE_PAGE: a CPU line read of a plane window reads all sixteen columns from the page the CPU presented at its accept, even when a GDC draw visit on the OTHER page is granted in the middle of the walk: pc9821_gvram_arb accepts a line read at the walk's start, z486 then drops its request (src/z486/bus_unit.sv clears ext_valid_r at the accept edge), and pc9821_gvram_share admits the waiting visit, whose own page (pc9821_gdc2 latches it per draw) then drives the share's page output while the walk still has columns to read. The sixteen bytes must be the CPU page's and never the visit's page's, the visit must be granted while the walk is in flight (so the case is not vacuous), and the visit's store must still land on its own page once the walk ends. FAIL-FIRST: with the column walk addressing the live access page (`c_cl_addr <= {access_page, c_col}`) the columns after the grant are read from the visit's page.
//
// The header above is the manifest claim VERBATIM (tools/check_tests.py holds the two together).
//
// WHERE THE EXPECTATION COMES FROM. A stated contract, not a capture: a CPU access to a plane
// window addresses the page port 0xA6 selected when the access was presented (NP2kai: an OUT to
// 0xA6 re-points the CPU's plane handlers, io/gdc.c, so every byte of one CPU access comes from
// one page), and a GDC draw's page is the draw's own (pc9821_gdc2 latches it per draw), so a
// draw that runs beside a CPU read can never move the read's page. The pattern bytes differ per
// page, so a column read from the wrong page is named.
`default_nettype none

module tb_pc9821_gvram_line_page;
  reg clk = 0;
  always #10 clk = ~clk;
  reg reset = 1;

  // ==== DUT ====
  reg        access_page = 1'b0;
  reg  [1:0] win_plane = 2'd0;
  reg [14:0] win_offset = 15'd0;
  reg [31:0] cpu_din = 32'd0;
  reg  [3:0] cpu_be = 4'hF;
  reg        cpu_line_read = 1'b0;
  reg        cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  wire        cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  reg        grcg_we = 1'b0;
  reg  [7:0] grcg_addr = 8'd0, grcg_din = 8'd0;

  reg        egc_gate = 1'b0;
  reg [15:0] egc_access = 16'hFFF0, egc_fgbg = 16'h00FF, egc_ope = 16'h0000,
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
  task automatic drain;
    begin
      while ((dut.u_arb.gstate != 3'd0) || dut.u_arb.m_mode || (dut.u_arb.cs != 4'd0) ||
             (dut.u_grcg.gstate != 4'd0) || (dut.u_egc.state != 4'd0) ||
             dut.u_gvr_share.gdc_own_q) @(posedge clk);
      repeat (3) @(posedge clk);
    end
  endtask

  // One plain CPU access, z486's handshake: held until its ready, dropped after the accept
  // edge; a read's datum follows on the response strobe.
  task automatic cpu_op(input pg, input [1:0] pl, input [14:0] off, input wr,
                        input [31:0] din, output [31:0] dout);
    begin
      @(negedge clk);
      access_page = pg; win_plane = pl; win_offset = off; cpu_din = din; cpu_be = 4'hF;
      cpu_write = wr; cpu_line_read = 1'b0; cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0;
      dout = 32'd0;
      if (!wr) begin
        while (!cpu_resp_valid) @(negedge clk);
        #1; dout = cpu_dout;
      end
      drain;
    end
  endtask

  // The byte the pattern puts at (page, plane, column): distinct per page, so a column read
  // from the wrong page is named.
  function automatic [7:0] pat(input pg, input [1:0] pl, input [3:0] col);
    pat = {pg ? 4'hE : 4'h1, 4'h0} + {pl, 2'b00} + {4'h0, col};
  endfunction

  // A line read of (pg, pl, base). `visit` presents a GDC store visit on `vpage` in the
  // line read's ready cycle (the share grants it as soon as the CPU's request falls).
  reg [127:0] line;
  reg         granted_mid_walk;
  task automatic line_read(input pg, input [1:0] pl, input [14:0] base, input visit,
                           input vpage);
    integer k, n;
    reg drop_next, vdone;
    begin
      @(negedge clk);
      access_page = pg; win_plane = pl; win_offset = base; cpu_be = 4'hF; cpu_write = 1'b0;
      cpu_line_read = 1'b1; cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      if (visit) begin
        gdc_mem_valid = 1'b1; gdc_mem_write = 1'b1; gdc_mem_page = vpage;
        gdc_mem_plane = 2'd0; gdc_mem_offset = 15'h1000; gdc_mem_din = 32'h5A5A_5A5A;
        gdc_mem_be = 4'hF; gdc_mem_route_egc = 1'b0; gdc_mem_route_grcg = 1'b0;
      end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_line_read = 1'b0;
      line = 128'd0; k = 0; n = 0; drop_next = 0; vdone = !visit;
      granted_mid_walk = 1'b0;
      while ((k < 4 || !vdone || drop_next) && n < 2000) begin
        @(posedge clk); #1; n = n + 1;
        if (dut.u_gvr_share.gdc_own_q && (dut.u_arb.cs != 4'd0) && dut.u_arb.c_line_mode)
          granted_mid_walk = 1'b1;
        if (cpu_line_word_valid && k < 4) begin
          line[{k[1:0], 5'b00000} +: 32] = cpu_line_word;
          k = k + 1;
        end
        if (drop_next) begin gdc_mem_valid = 1'b0; gdc_mem_write = 1'b0; drop_next = 0; end
        if (gdc_mem_valid && gdc_mem_ready) begin drop_next = 1; vdone = 1; end
      end
      if (k < 4 || !vdone)
        $fatal(1, "TB_PC9821_GVRAM_LINE_PAGE: FAIL (line read beats %0d/4, visit %0s after %0d clk)",
               k, vdone ? "done" : "NOT done", n);
      @(negedge clk); gdc_mem_valid = 1'b0;
      drain;
    end
  endtask

  task automatic check_line(input pg, input [1:0] pl, input [8*80-1:0] tag);
    integer c;
    begin
      for (c = 0; c < 16; c = c + 1)
        if (line[{c[3:0], 3'b000} +: 8] !== pat(pg, pl, c[3:0])) begin
          $display("FAIL %0s: column %0d read %02x, want %02x (page %0d's byte; page %0d's is %02x)",
                   tag, c, line[{c[3:0], 3'b000} +: 8], pat(pg, pl, c[3:0]), pg, !pg,
                   pat(!pg, pl, c[3:0]));
          errors = errors + 1;
        end
    end
  endtask

  // ==== CHECKS ====
  localparam [14:0] BASE = 15'h0400;
  reg [31:0] d;
  integer pgi, w;
  initial begin
    reset = 1'b1;
    repeat (30) @(posedge clk);
    reset = 1'b0;
    repeat (50) @(posedge clk);   // past the EGC's post-reset ring scrub

    // The line's sixteen columns on plane 2 of both pages, and a known word at the visit's
    // target on both pages.
    for (pgi = 0; pgi < 2; pgi = pgi + 1)
      for (w = 0; w < 4; w = w + 1)
        cpu_op(pgi[0], 2'd2, BASE + w * 4, 1'b1,
               {pat(pgi[0], 2'd2, w * 4 + 3), pat(pgi[0], 2'd2, w * 4 + 2),
                pat(pgi[0], 2'd2, w * 4 + 1), pat(pgi[0], 2'd2, w * 4 + 0)}, d);
    cpu_op(1'b0, 2'd0, 15'h1000, 1'b1, 32'h0000_0000, d);
    cpu_op(1'b1, 2'd0, 15'h1000, 1'b1, 32'h0000_0000, d);

    // Controls: each page's line alone reads that page's bytes.
    line_read(1'b0, 2'd2, BASE, 1'b0, 1'b0);
    check_line(1'b0, 2'd2, "control: page 0 line, no visit");
    line_read(1'b1, 2'd2, BASE, 1'b0, 1'b0);
    check_line(1'b1, 2'd2, "control: page 1 line, no visit");

    // The case: a page-0 line read with a page-1 GDC visit granted mid-walk, and the mirror.
    line_read(1'b0, 2'd2, BASE, 1'b1, 1'b1);
    if (!granted_mid_walk) fail("the page-1 visit was not granted during the page-0 line walk (vacuous case)");
    check_line(1'b0, 2'd2, "page 0 line, page 1 visit granted mid-walk");
    cpu_op(1'b1, 2'd0, 15'h1000, 1'b0, 32'd0, d);
    if (d !== 32'h5A5A_5A5A) begin
      $display("FAIL the page-1 visit's store: page 1 plane 0 0x1000 reads %08x, want 5a5a5a5a", d);
      errors = errors + 1;
    end
    cpu_op(1'b0, 2'd0, 15'h1000, 1'b0, 32'd0, d);
    if (d !== 32'h0000_0000) begin
      $display("FAIL the page-1 visit's store reached page 0: plane 0 0x1000 reads %08x, want 00000000", d);
      errors = errors + 1;
    end

    line_read(1'b1, 2'd2, BASE, 1'b1, 1'b0);
    if (!granted_mid_walk) fail("the page-0 visit was not granted during the page-1 line walk (vacuous case)");
    check_line(1'b1, 2'd2, "page 1 line, page 0 visit granted mid-walk");

// ==== VERDICT ====
    if (errors != 0) begin
      $display("TB_PC9821_GVRAM_LINE_PAGE: FAIL (%0d checks)", errors);
      $fatal(1, "TB_PC9821_GVRAM_LINE_PAGE failed");
    end
    $display("TB_PC9821_GVRAM_LINE_PAGE: PASS");
    $finish;
  end

  initial begin
    #(5_000_000);
    $fatal(1, "TB_PC9821_GVRAM_LINE_PAGE did not finish in 5 ms of simulated time");
  end
endmodule

`default_nettype wire

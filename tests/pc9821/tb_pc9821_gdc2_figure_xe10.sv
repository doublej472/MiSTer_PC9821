`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The graphics GDC's figure commands draw what the Xe10 drew: 1,450 rows of the real machine's conformance capture (docs/probes/gdc-conformance/xe10-2.5MHz GDCDRAW, GDCROP and GDCGCHR, re-encoded by tools/gen_gdc_draw_vectors.py) are replayed through pc9821_gdc2 and the real GVRAM (share, arbiter, byte-lane memory) over the 0xA0/0xA2 ports - ROP select, TEXTW pattern, ZOOM, CSRW, FIGS, then FIGD or GCHRD - and every row's GVRAM outcome and cursor are the machine's own: the FIGD dot at all 16 dADs and all 8 directions, 288 canonical and 12 raw-DDA lines (the D/D1/D2 decision walk the machine runs, which refutes NP2kai gdcsub_vectl's division), the A53C line pattern, the rectangles in all 8 directions including the zero-length sides that sweep 16,384 dots and carry into the next plane, the 192 FIGD_ROP and 324 FIGD_PATTERN rows (REPLACE/COMPLEMENT/CLEAR/SET of the pattern's bit through the one-hot cursor mask), and GCHRD's 512 one-hot PRAM-bit rows in all 8 directions, solid area fills from 1x1 to 16x16 and 17x5, ZOOM 1..16, the slanted character in all 8 directions and the PRAM start bytes 0x78-0x7F. A row whose change list is complete must match the whole of GVRAM page 0 word for word (nothing else written, in any plane); a row the suite truncated must match its listed words and its total count of changed R-plane words. The five bytes the CURD read-back answers - {EAD[7:0], EAD[15:8], 0xF0|EAD[17:16], MASK[7:0], MASK[15:8]} - are the machine's own raw_curd after every row, and the 0xA0 status shows DRAWING (bit 3) while the figure runs and clears it when the draw is done.

module tb_pc9821_gdc2_figure_xe10;
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;

  reg rst_n_sys = 0;
  reg io_wr = 0, io_rd = 0;
  reg [7:0] io_addr = 0, io_din = 0;
  wire [7:0] io_dout;
  wire [15:0] gfx_line_addr;
  wire gfx_disp;

  reg grcg_we = 0;
  reg [7:0] grcg_addr = 0, grcg_din = 0;
  wire grcg_expand;

  wire [15:0] egc_access_v = 16'h0000;
  wire [15:0] egc_fgbg_v   = 16'h0000;
  wire [15:0] egc_ope_v    = 16'h0000;
  wire [15:0] egc_fg_v     = 16'hFFFF;
  wire [15:0] egc_mask_v   = 16'hFFFF;
  wire [15:0] egc_bg_v     = 16'h0000;
  wire [15:0] egc_sft_v    = 16'h0000;
  wire [15:0] egc_leng_v   = 16'hFFFF;
  wire        egc_shift_we_v = 1'b0;

  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  wire        cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  wire        gdc_mem_valid, gdc_mem_ready, gdc_mem_write;
  wire        gdc_mem_route_egc, gdc_mem_route_grcg, gdc_mem_page;
  wire [1:0]  gdc_mem_plane;
  wire [14:0] gdc_mem_offset;
  wire [31:0] gdc_mem_din, gdc_mem_rdata;
  wire [3:0]  gdc_mem_be;
  wire        gdc_mem_resp;

  // ==== DUT ====
  pc9821_gdc2 dut_gdc2 (
      .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .pixel_ce(1'b1),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .frame_end(1'b0), .cfg_snap(1'b0), .cfg_pending(1'b0),
      .vline(10'd0), .vtotal(10'd0), .m_vbp(6'd25), .display_page(1'b0),
      .stat_blank(1'b0), .stat_vsync(1'b0),
      .egc_mem_gate(1'b0), .grcg_cg_gate(grcg_expand),
      .access_page(1'b0),
      .mem_valid(gdc_mem_valid), .mem_ready(gdc_mem_ready),
      .mem_write(gdc_mem_write),
      .mem_route_egc(gdc_mem_route_egc), .mem_route_grcg(gdc_mem_route_grcg),
      .mem_page(gdc_mem_page), .mem_plane(gdc_mem_plane),
      .mem_offset(gdc_mem_offset), .mem_din(gdc_mem_din), .mem_be(gdc_mem_be),
      .mem_resp(gdc_mem_resp), .mem_rdata(gdc_mem_rdata),
      .gfx_line_addr(gfx_line_addr), .gfx_disp(gfx_disp), .pegc_256(1'b0)
  );

  pc9821_gvram_dut dut (
      .clk(clk_sys), .reset(!rst_n_sys),
      .access_page(1'b0),
      .win_plane(2'd0), .win_offset(15'd0),
      .cpu_din(32'd0), .cpu_be(4'd0), .cpu_line_read(1'b0),
      .cpu_valid(1'b0), .cpu_write(1'b0),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .grcg_expand(grcg_expand),
      .egc_gate(1'b0),
      .egc_access(egc_access_v), .egc_fgbg(egc_fgbg_v), .egc_ope(egc_ope_v),
      .egc_fg(egc_fg_v), .egc_mask(egc_mask_v), .egc_bg(egc_bg_v),
      .egc_sft(egc_sft_v), .egc_leng(egc_leng_v), .egc_shift_we(egc_shift_we_v),
      .gdc_mem_valid(gdc_mem_valid), .gdc_mem_ready(gdc_mem_ready),
      .gdc_mem_write(gdc_mem_write),
      .gdc_mem_route_egc(gdc_mem_route_egc), .gdc_mem_route_grcg(gdc_mem_route_grcg),
      .gdc_mem_page(gdc_mem_page), .gdc_mem_plane(gdc_mem_plane),
      .gdc_mem_offset(gdc_mem_offset), .gdc_mem_din(gdc_mem_din),
      .gdc_mem_be(gdc_mem_be),
      .gdc_mem_resp(gdc_mem_resp), .gdc_mem_rdata(gdc_mem_rdata),
      .scan_enable(1'b0), .scan_line_tick(1'b0), .scan_page(1'b0),
      .scan_line_base(15'd0), .gfx_odd_line(1'b0),
      .line_rd_addr(7'd0), .line_rd_sel(1'b0)
  );

  // The machine's rows (see tools/gen_gdc_draw_vectors.py for the encoding).
  `include "gdc_draw_xe10_vectors.svh"

  integer errors = 0, checks = 0, rows_done = 0, rows_trunc = 0;

  function [8*16-1:0] id_str(input [127:0] v);
    integer q;
    begin
      for (q = 0; q < 16; q = q + 1)
        id_str[8*q +: 8] = (v[8*q +: 8] == 8'h00) ? 8'h20 : v[8*q +: 8];
    end
  endfunction

  task automatic io_a2(input [7:0] b);
    begin
      @(negedge clk_sys); io_addr = 8'hA2; io_din = b; io_wr = 1'b1;
      @(negedge clk_sys); io_wr = 1'b0;
      @(negedge clk_sys);
    end
  endtask
  task automatic io_a0(input [7:0] b);
    begin
      @(negedge clk_sys); io_addr = 8'hA0; io_din = b; io_wr = 1'b1;
      @(negedge clk_sys); io_wr = 1'b0;
      @(negedge clk_sys);
    end
  endtask
  task automatic io_read(input [7:0] a, output [7:0] d);
    begin
      @(negedge clk_sys); io_addr = a; io_rd = 1'b1;
      @(negedge clk_sys); io_rd = 1'b0;
      @(negedge clk_sys); d = io_dout;
    end
  endtask

  // The GVRAM, straight through the byte-lane arrays (lane L = plane window L: 0 = B,
  // 1 = R, 2 = G, 3 = E; the GDC's plane n is lane n-1 mod 4). A word W of the plane is
  // bytes 2W (low) and 2W+1 (high) of page 0, in the CPU's own bit order.
  function automatic [1:0] lane_of(input [1:0] gdc_plane);
    lane_of = gdc_plane - 2'd1;
  endfunction
  task automatic mem_wr(input [1:0] lane, input [13:0] w, input [15:0] v);
    begin
      case (lane)
        2'd0: begin dut.u_gmem.mem0[{1'b0, w, 1'b0}] = v[7:0]; dut.u_gmem.mem0[{1'b0, w, 1'b1}] = v[15:8]; end
        2'd1: begin dut.u_gmem.mem1[{1'b0, w, 1'b0}] = v[7:0]; dut.u_gmem.mem1[{1'b0, w, 1'b1}] = v[15:8]; end
        2'd2: begin dut.u_gmem.mem2[{1'b0, w, 1'b0}] = v[7:0]; dut.u_gmem.mem2[{1'b0, w, 1'b1}] = v[15:8]; end
        default: begin dut.u_gmem.mem3[{1'b0, w, 1'b0}] = v[7:0]; dut.u_gmem.mem3[{1'b0, w, 1'b1}] = v[15:8]; end
      endcase
    end
  endtask
  function automatic [15:0] mem_rd(input [1:0] lane, input [13:0] w);
    case (lane)
      2'd0: mem_rd = {dut.u_gmem.mem0[{1'b0, w, 1'b1}], dut.u_gmem.mem0[{1'b0, w, 1'b0}]};
      2'd1: mem_rd = {dut.u_gmem.mem1[{1'b0, w, 1'b1}], dut.u_gmem.mem1[{1'b0, w, 1'b0}]};
      2'd2: mem_rd = {dut.u_gmem.mem2[{1'b0, w, 1'b1}], dut.u_gmem.mem2[{1'b0, w, 1'b0}]};
      default: mem_rd = {dut.u_gmem.mem3[{1'b0, w, 1'b1}], dut.u_gmem.mem3[{1'b0, w, 1'b0}]};
    endcase
  endfunction

  // The expected GVRAM (all four lanes of page 0), built from the row's seeds and listed
  // words - the machine's own columns.
  reg [15:0] expv [0:65535];   // index {lane, word}

  // ==== CHECKS ====
  initial begin : replay
    integer r, k, l, w, nch, nseed, choff, sdoff, nchanged, drawing_seen, polls;
    reg [GDX_CFGW-1:0] c;
    reg [7:0] cmd, p1, st, b0, b1, b2, b3, b4, curd_b2;
    reg [13:0] dc, d, d2, d1, dm;
    reg [15:0] ead, curd_ead, curd_mask, n_changed, got, ex;
    reg [3:0] dad, zoom;
    reg [63:0] ra;
    reg [1:0] rop;
    reg complete;
    reg [31:0] e;

    repeat (4) @(negedge clk_sys);
    rst_n_sys = 1;
    repeat (4) @(negedge clk_sys);

    for (r = 0; r < GDX_N; r = r + 1) begin
      c = GDX_CFG[r] >> 8;          // the low byte is the machine's raw CURD byte 2
      curd_b2 = GDX_CFG[r][7:0];
      cmd = c[272:265]; p1 = c[264:257]; dc = c[256:243]; d = c[242:229];
      d2 = c[228:215]; d1 = c[214:201]; dm = c[200:187]; ead = c[186:171];
      dad = c[170:167]; ra = c[166:103]; zoom = c[102:99]; rop = c[98:97];
      n_changed = c[96:81]; complete = c[80];
      choff = c[79:64]; nch = c[63:56]; sdoff = c[55:40]; nseed = c[39:32];
      curd_ead = c[31:16]; curd_mask = c[15:0];

      // ---- the GVRAM before the row: zero, plus the row's seeded old words ----
      for (l = 0; l < 4; l = l + 1)
        for (w = 0; w < 16384; w = w + 1) begin
          mem_wr(l[1:0], w[13:0], 16'h0000);
          expv[{l[1:0], w[13:0]}] = 16'h0000;
        end
      for (k = 0; k < nseed; k = k + 1) begin
        e = GDX_SEED[sdoff + k];
        mem_wr(lane_of(e[31:30]), e[29:16], e[15:0]);
        expv[{lane_of(e[31:30]), e[29:16]}] = e[15:0];
      end
      for (k = 0; k < nch; k = k + 1) begin
        e = GDX_CH[choff + k];
        expv[{lane_of(e[31:30]), e[29:16]}] = e[15:0];
      end

      // ---- the row's program ----
      io_a2(8'h28 | {6'd0, rop});            // the WRITE family's ROP (no data byte)
      io_a2(8'h78);                          // TEXTW: PRAM RA8..RA15
      for (k = 0; k < 8; k = k + 1) io_a0(ra[63 - 8*k -: 8]);
      io_a2(8'h46); io_a0({4'd0, zoom});     // ZOOM
      io_a2(8'h49); io_a0(ead[7:0]); io_a0(ead[15:8]); io_a0({dad, 4'd0});   // CSRW
      io_a2(8'h4C);                          // FIGS
      io_a0(p1);
      io_a0(dc[7:0]); io_a0({2'd0, dc[13:8]});
      io_a0(d[7:0]);  io_a0({2'd0, d[13:8]});
      io_a0(d2[7:0]); io_a0({2'd0, d2[13:8]});
      io_a0(d1[7:0]); io_a0({2'd0, d1[13:8]});
      io_a0(dm[7:0]); io_a0({2'd0, dm[13:8]});
      io_a2(cmd);                            // FIGD / GCHRD

      // ---- the guest's wait: poll 0xA0 until DRAWING (bit 3) clears ----
      drawing_seen = 0; polls = 0;
      io_read(8'hA0, st);
      while (st[3] && polls < 4000000) begin
        drawing_seen = 1; polls = polls + 1;
        io_read(8'hA0, st);
      end
      checks = checks + 1;
      if (!drawing_seen || !st[2]) begin
        $display("MISMATCH %0s: status %02x after the draw (drawing seen %0d)",
                 id_str(GDX_ID[r]), st, drawing_seen);
        errors = errors + 1;
      end

      // The engine's last store is ACCEPTED (posted) when DRAWING drops; the arbiter commits
      // it to the array within one access period. A guest read is ordered behind it by the
      // arbiter itself, but this bench peeks at the array directly, so it lets the period
      // pass (the read period, 478 ns, is the longest: 24 clk_sys here) before looking.
      repeat (64) @(negedge clk_sys);

      // ---- the cursor: CSRR's EAD bytes, and the mask ----
      io_a2(8'hE0);
      io_read(8'hA2, b0);
      io_read(8'hA2, b1);
      io_read(8'hA2, b2);
      io_read(8'hA2, b3);
      io_read(8'hA2, b4);
      checks = checks + 1;
      if (({b1, b0} !== curd_ead) || ({b4, b3} !== curd_mask) || (b2 !== curd_b2) ||
          ({dut_gdc2.gdc2_mask[1], dut_gdc2.gdc2_mask[0]} !== curd_mask)) begin
        $display("MISMATCH %0s: CURD %02x-%02x-%02x-%02x-%02x, machine %02x-%02x-%02x-%02x-%02x", id_str(GDX_ID[r]),
                 b0, b1, b2, b3, b4, curd_ead[7:0], curd_ead[15:8], curd_b2, curd_mask[7:0], curd_mask[15:8]);
        errors = errors + 1;
      end

      // ---- the GVRAM after the row ----
      checks = checks + 1;
      if (complete) begin
        k = 0;
        for (l = 0; l < 4; l = l + 1)
          for (w = 0; w < 16384; w = w + 1) begin
            got = mem_rd(l[1:0], w[13:0]);
            ex = expv[{l[1:0], w[13:0]}];
            if (got !== ex) begin
              if (k < 4)
                $display("MISMATCH %0s: lane %0d word %04x got %04x machine %04x",
                         id_str(GDX_ID[r]), l, w, got, ex);
              k = k + 1;
            end
          end
        if (k != 0) errors = errors + 1;
      end else begin
        rows_trunc = rows_trunc + 1;
        k = 0;
        for (l = 0; l < nch; l = l + 1) begin
          e = GDX_CH[choff + l];
          got = mem_rd(lane_of(e[31:30]), e[29:16]);
          if (got !== e[15:0]) begin
            if (k < 4)
              $display("MISMATCH %0s: listed word %04x got %04x machine %04x",
                       id_str(GDX_ID[r]), e[29:16], got, e[15:0]);
            k = k + 1;
          end
        end
        nchanged = 0;
        for (w = 0; w < 16384; w = w + 1)
          if (mem_rd(2'd1, w[13:0]) !== 16'h0000) nchanged = nchanged + 1;   // plane R
        if (nchanged != n_changed) begin
          $display("MISMATCH %0s: %0d R-plane words changed, machine %0d",
                   id_str(GDX_ID[r]), nchanged, n_changed);
          k = k + 1;
        end
        if (k != 0) errors = errors + 1;
      end
      rows_done = rows_done + 1;
    end

    // ==== VERDICT ====
    $display("NOTE gdc2_figure_xe10: %0d rows (%0d truncated lists), %0d checks, %0d errors",
             rows_done, rows_trunc, checks, errors);
    if (errors == 0 && rows_done == GDX_N) begin
      $display("TB_PC9821_GDC2_FIGURE_XE10: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_GDC2_FIGURE_XE10: FAIL (%0d errors over %0d checks)", errors, checks);
    end
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "TB_PC9821_GDC2_FIGURE_XE10: TIMEOUT");
  end
endmodule

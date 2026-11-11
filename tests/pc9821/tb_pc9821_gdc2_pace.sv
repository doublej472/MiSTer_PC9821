`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The graphics GDC's compile-time draw pacing (pc9821_gdc2 WRITE_PACE_NS / FIG_PACE_NS, build_profile.py --gdc-write-pace / --gdc-fig-pace, 0 = unpaced in every preset) holds the engine to the Xe10's own GDCTIME timing (docs/probes/gdc-conformance/xe10-2.5MHz/GDCTIME.CSV, 2.5 MHz GDC, mean milli-ticks of the 2.4576 MHz PIT): with the pace set, a WDAT of N words (VECTW dir 2, DC = N - 1, MASK FFFF, complement - the WDAT_N rows' own stimulus) keeps 0xA0 status bit 3 DRAWING set so that DRAWING(N) - DRAWING(1) equals the capture's WDAT_N(N) - WDAT_N(1) to within one pace period, and a horizontal FIGD line of N dots (the LINE_N rows) does the same against LINE_N, measured at two clk_sys rates (50 MHz with a 1400 ns pace over the rows up to N = 513, where 1400 ns is within a period of the capture, and the shipped 90 MHz with 1401 ns over every row, WDAT_N0001..N1025 and LINE_N0001..N2049, the least-squares per-unit time of both row sets being 1401.4-1401.5 ns), so the busy time is real time, not a clk_sys count, and the per-unit slope over the whole row set is the capture's to within 2 ns; and bytes written behind a paced 64-word WRITE at one byte per microsecond wait in the 16-entry command FIFO, so status bit 1 FIFO FULL is reached while DRAWING is still set (the chip's FIFO, GDCFIFO DRAW_BURST's status 0x0C through a draw) and the 16 queued bytes replay in order after the draw (the last ZOOM's value lands). FAIL-FIRST: with the pacing compiled out (W_PACED / F_PACED forced to 0, the default build's engine) every DRAWING-time check and the FIFO FULL check fail; the default build's own behaviour is held by tb_pc9821_gdc2_write, tb_pc9821_gdc2_figure (14 dot clocks a step) and tb_pc9821_gdc2_equiv, which instantiate the module with its defaults and are unchanged.

`default_nettype none

// One pc9821_gdc2 with both paces set, on its own clk_sys, with an always-ready GVRAM responder
// (the visit protocol: ready one cycle after valid, a read's datum the cycle after the ready).
module gdc2_pace_rig #(
    parameter integer SYS_HZ = 50_000_000,
    parameter real    HALF_NS = 10.0,
    parameter integer PACE_NS = 1400,
    parameter integer MAX_N = 513
) (
    output reg         done,
    output reg  [31:0] errors,
    output reg  [31:0] checks
);
  // The capture (GDCTIME.CSV mean_milliticks; the 2.4576 MHz PIT). Never our RTL.
  localparam real PIT_HZ = 2_457_600.0;
  localparam integer NW = 12;
  localparam integer NL = 13;
  integer wdat_n  [0:NW-1] = '{1, 2, 3, 5, 9, 17, 33, 65, 129, 257, 513, 1025};
  integer wdat_mt [0:NW-1] = '{26176, 29352, 33176, 39882, 53294, 80823, 135882, 245882,
                               466823, 907235, 1788529, 3553294};
  integer line_n  [0:NL-1] = '{1, 2, 3, 5, 9, 17, 33, 65, 129, 257, 513, 1025, 2049};
  integer line_mt [0:NL-1] = '{25352, 28235, 31941, 38294, 52647, 79764, 134941, 245176,
                               465941, 906588, 1788294, 3551470, 7078352};
  localparam real CLK_NS = 1.0e9 / SYS_HZ;

  reg clk_sys = 0;
  always #(HALF_NS) clk_sys = ~clk_sys;
  reg rst_n_sys = 0;
  reg io_wr = 0, io_rd = 0;
  reg [7:0] io_addr = 8'hA0, io_din = 0;
  wire [7:0] io_dout;

  wire        mem_valid, mem_write, mem_route_egc, mem_route_grcg, mem_page;
  wire [1:0]  mem_plane;
  wire [14:0] mem_offset;
  wire [31:0] mem_din;
  wire [3:0]  mem_be;
  reg         mem_ready = 0, mem_resp = 0;
  always @(posedge clk_sys) begin
    mem_ready <= mem_valid && !mem_ready;
    mem_resp  <= mem_ready && !mem_write;
  end

  // ==== DUT ====
  pc9821_gdc2 #(.SYS_FREQ(SYS_HZ), .WRITE_PACE_NS(PACE_NS), .FIG_PACE_NS(PACE_NS)) dut (
      .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .pixel_ce(1'b1),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
      .frame_end(1'b0), .cfg_snap(1'b0), .cfg_pending(1'b0),
      .vline(10'd0), .vtotal(10'd0), .m_vbp(6'd25), .display_page(1'b0),
      .pegc_256(1'b0), .gdc_5m(1'b0), .stat_blank(1'b0), .stat_vsync(1'b0),
      /* verilator lint_off PINCONNECTEMPTY */
      .gfx_line_addr(), .gfx_walk_page(), .gfx_disp(), .gfx_win_off(), .gfx_grph_on(),
      /* verilator lint_on PINCONNECTEMPTY */
      .egc_mem_gate(1'b0), .grcg_cg_gate(1'b0), .access_page(1'b0),
      .mem_valid(mem_valid), .mem_ready(mem_ready), .mem_write(mem_write),
      .mem_route_egc(mem_route_egc), .mem_route_grcg(mem_route_grcg), .mem_page(mem_page),
      .mem_plane(mem_plane), .mem_offset(mem_offset), .mem_din(mem_din), .mem_be(mem_be),
      .mem_resp(mem_resp), .mem_rdata(32'd0)
  );

  // ==== CHECKS ====
  task automatic check(input bit cond, input [1023:0] what);
    begin
      checks = checks + 1;
      if (!cond) begin
        $display("MISMATCH [%0d MHz, %0d ns] %0s @ %0t", SYS_HZ / 1_000_000, PACE_NS, what, $time);
        errors = errors + 1;
      end
    end
  endtask

  // The status read the guest polls (0xA0; io_dout is the addressed port's byte).
  function automatic [7:0] status;
    status = dut.io_dout;
  endfunction

  task automatic io_w(input [7:0] a, input [7:0] b);
    begin
      @(negedge clk_sys); io_addr = a; io_din = b; io_wr = 1'b1;
      @(negedge clk_sys); io_wr = 1'b0; io_addr = 8'hA0;
      @(negedge clk_sys);
    end
  endtask

  // DRAWING's length from the command's last byte to its fall, in clk_sys cycles.
  task automatic busy_after_last(input [7:0] a, input [7:0] b, output integer cyc);
    begin
      @(negedge clk_sys); io_addr = a; io_din = b; io_wr = 1'b1;
      @(negedge clk_sys); io_wr = 1'b0; io_addr = 8'hA0;
      cyc = 1;
      while (!status()[3] && cyc < 8) begin @(negedge clk_sys); cyc = cyc + 1; end
      cyc = 0;
      while (status()[3]) begin @(negedge clk_sys); cyc = cyc + 1; end
      repeat (8) @(negedge clk_sys);
    end
  endtask

  // A WDAT_N row: CSRW (plane B word 0x0000, WG 1), MASK FFFF, VECTW dir 2 DC = n - 1, then
  // WDAT 0x21 (word, complement) FF FF - the busy time runs from its last byte.
  task automatic wdat_busy(input integer n, output integer cyc);
    integer k;
    begin
      io_w(8'hA2, 8'h49); io_w(8'hA0, 8'h00); io_w(8'hA0, 8'h40); io_w(8'hA0, 8'h08);
      io_w(8'hA2, 8'h4A); io_w(8'hA0, 8'hFF); io_w(8'hA0, 8'hFF);
      io_w(8'hA2, 8'h4C); io_w(8'hA0, 8'h02);
      io_w(8'hA0, (n - 1) & 8'hFF); io_w(8'hA0, ((n - 1) >> 8) & 8'h3F);
      for (k = 0; k < 8; k = k + 1) io_w(8'hA0, 8'h00);
      io_w(8'hA2, 8'h21); io_w(8'hA0, 8'hFF);
      busy_after_last(8'hA0, 8'hFF, cyc);
    end
  endtask

  // A LINE_N row: a horizontal line of n dots (FIGS line, dir 2, DC = n - 1, D = -(n - 1),
  // D2 = -2(n - 1), D1 = 0, DM all ones), SET, then FIGD - the busy time runs from the FIGD.
  task automatic line_busy(input integer n, output integer cyc);
    integer dc, d, d2;
    begin
      dc = n - 1; d = (-(n - 1)) & 14'h3FFF; d2 = (-2 * (n - 1)) & 14'h3FFF;
      io_w(8'hA2, 8'h2B);
      io_w(8'hA2, 8'h49); io_w(8'hA0, 8'h00); io_w(8'hA0, 8'h40); io_w(8'hA0, 8'h00);
      io_w(8'hA2, 8'h4C); io_w(8'hA0, 8'h0A);
      io_w(8'hA0, dc & 8'hFF); io_w(8'hA0, (dc >> 8) & 8'h3F);
      io_w(8'hA0, d & 8'hFF);  io_w(8'hA0, (d >> 8) & 8'h3F);
      io_w(8'hA0, d2 & 8'hFF); io_w(8'hA0, (d2 >> 8) & 8'h3F);
      io_w(8'hA0, 8'h00); io_w(8'hA0, 8'h00);
      io_w(8'hA0, 8'hFF); io_w(8'hA0, 8'h3F);
      busy_after_last(8'hA2, 8'h6C, cyc);
    end
  endtask

  // Every row up to MAX_N: busy(n) - busy(1) against the capture's mean(n) - mean(1), to within
  // one pace period; then the slope over the rows run against the capture's.
  task automatic rows(input bit fig);
    integer i, cnt, cyc, cyc1, cyc_last, n_last;
    real got_ns, exp_ns, cap_slope, got_slope, mt1, mt_last;
    begin
      cnt = fig ? NL : NW;
      cyc1 = 0; cyc_last = 0; n_last = 1; mt1 = 0.0; mt_last = 0.0;
      for (i = 0; i < cnt; i = i + 1) begin
        if ((fig ? line_n[i] : wdat_n[i]) <= MAX_N) begin
          if (fig) line_busy(line_n[i], cyc); else wdat_busy(wdat_n[i], cyc);
          if (i == 0) begin
            cyc1 = cyc;
            mt1 = fig ? line_mt[0] : wdat_mt[0];
            check(cyc * CLK_NS >= PACE_NS && cyc * CLK_NS <= 2 * PACE_NS,
                  fig ? "LINE_N0001: one dot keeps DRAWING one pace period"
                      : "WDAT_N0001: one word keeps DRAWING one pace period");
          end else begin
            got_ns = (cyc - cyc1) * CLK_NS;
            exp_ns = ((fig ? line_mt[i] : wdat_mt[i]) - mt1) / PIT_HZ * 1.0e6;
            $display("  [%0d MHz %0d ns] %s N=%0d: DRAWING +%0.1f ns over N=1, capture +%0.1f ns",
                     SYS_HZ / 1_000_000, PACE_NS, fig ? "LINE" : "WDAT",
                     fig ? line_n[i] : wdat_n[i], got_ns, exp_ns);
            check((got_ns - exp_ns <= PACE_NS) && (exp_ns - got_ns <= PACE_NS),
                  fig ? "LINE_N: DRAWING time within one pace period of the capture"
                      : "WDAT_N: DRAWING time within one pace period of the capture");
            cyc_last = cyc; n_last = fig ? line_n[i] : wdat_n[i];
            mt_last = fig ? line_mt[i] : wdat_mt[i];
          end
        end
      end
      got_slope = (cyc_last - cyc1) * CLK_NS / (n_last - 1);
      cap_slope = (mt_last - mt1) / PIT_HZ * 1.0e6 / (n_last - 1);
      $display("  [%0d MHz %0d ns] %s per unit: %0.2f ns, capture %0.2f ns (N=1..%0d)",
               SYS_HZ / 1_000_000, PACE_NS, fig ? "LINE" : "WDAT", got_slope, cap_slope, n_last);
      check((got_slope - cap_slope <= 2.0) && (cap_slope - got_slope <= 2.0),
            "the per-unit time over the rows is the capture's to within 2 ns");
    end
  endtask

  initial begin
    done = 0; errors = 0; checks = 0;
    repeat (4) @(negedge clk_sys);
    rst_n_sys = 1;
    repeat (4) @(negedge clk_sys);

    $display("CHECK 1 [%0d MHz]: WDAT_N - one word per pace period", SYS_HZ / 1_000_000);
    rows(1'b0);
    $display("CHECK 2 [%0d MHz]: LINE_N - one dot per pace period", SYS_HZ / 1_000_000);
    rows(1'b1);

    // ---- 3: bytes queue behind a paced WRITE until FIFO FULL ----
    // A 64-word WDAT (89.6 us paced), then eight ZOOM commands (16 bytes) at one byte per
    // microsecond: all sixteen wait in the FIFO while DRAWING is set, FULL comes up, and after
    // the draw they replay in order (the last ZOOM's 0x07 lands).
    $display("CHECK 3 [%0d MHz]: the command FIFO fills behind a paced WRITE", SYS_HZ / 1_000_000);
    begin : fifo
      integer k, us;
      bit saw_full_drawing, full_after_16;
      us = SYS_HZ / 1_000_000;
      io_w(8'hA2, 8'h46); io_w(8'hA0, 8'h00);
      io_w(8'hA2, 8'h49); io_w(8'hA0, 8'h00); io_w(8'hA0, 8'h40); io_w(8'hA0, 8'h08);
      io_w(8'hA2, 8'h4A); io_w(8'hA0, 8'hFF); io_w(8'hA0, 8'hFF);
      io_w(8'hA2, 8'h4C); io_w(8'hA0, 8'h02); io_w(8'hA0, 8'd63); io_w(8'hA0, 8'h00);
      for (k = 0; k < 8; k = k + 1) io_w(8'hA0, 8'h00);
      io_w(8'hA2, 8'h21); io_w(8'hA0, 8'hFF); io_w(8'hA0, 8'hFF);
      saw_full_drawing = 0;
      for (k = 0; k < 16; k = k + 1) begin
        repeat (us) @(negedge clk_sys);
        io_w((k[0] == 1'b0) ? 8'hA2 : 8'hA0, (k[0] == 1'b0) ? 8'h46 : {5'd0, k[3:1]});
        if (status()[1] && status()[3]) saw_full_drawing = 1;
      end
      full_after_16 = status()[1] && status()[3] && !status()[2];
      check(full_after_16, "FIFO FULL (bit 1) with DRAWING (bit 3) set after 16 bytes behind the WRITE");
      check(saw_full_drawing, "FULL is seen while the WRITE still draws");
      while (status()[3] || !status()[2]) @(negedge clk_sys);
      repeat (16) @(negedge clk_sys);
      check(!status()[1] && status()[2], "the FIFO drains after the draw (FULL clear, EMPTY set)");
      check(dut.gdc2_zoom == 4'd7, "the queued ZOOMs replay in order (the last one's 7 lands)");
    end

    done = 1;
  end
endmodule


module tb_pc9821_gdc2_pace;
  wire done_a, done_b;
  wire [31:0] err_a, err_b, chk_a, chk_b;

  // 50 MHz (the unit benches' clock) at the round 1400 ns, over the rows it matches.
  gdc2_pace_rig #(.SYS_HZ(50_000_000), .HALF_NS(10.0), .PACE_NS(1400), .MAX_N(513))
      rig_a (.done(done_a), .errors(err_a), .checks(chk_a));
  // The shipped 90 MHz at the capture's fitted 1401 ns, over every row.
  gdc2_pace_rig #(.SYS_HZ(90_000_000), .HALF_NS(5.5556), .PACE_NS(1401), .MAX_N(2049))
      rig_b (.done(done_b), .errors(err_b), .checks(chk_b));

  // ==== VERDICT ====
  initial begin
    wait (done_a && done_b);
    $display("NOTE gdc2_pace: %0d checks, %0d errors", chk_a + chk_b, err_a + err_b);
    if (err_a + err_b == 0) begin
      $display("TB_PC9821_GDC2_PACE: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_GDC2_PACE: FAIL (%0d errors)", err_a + err_b);
    end
  end

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_GDC2_PACE: TIMEOUT");
  end
endmodule

`default_nettype wire

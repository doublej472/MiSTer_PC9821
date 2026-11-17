`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_XE10_LATENCY: with OSD I/O timing = Xe10 every CPU read of the GVRAM (plain and GRCG TCR, one word and two), the text RAM and the PEGC packed bank is LATENCY-shaped as on the real Xe10 (XE10X /RDLAT, docs/probes/XE10X-XE10-RDLAT1.TXT: the CPU work after a read adds to it): the read's response comes the class's net time less the core CPU's own 8 clk_sys after the request at the GVRAM and text-RAM ports (the PEGC packed read is held the net time less the core's own 18-clk_sys unpaced read before it reaches the store buffer), and it comes exactly that late after 8, 32 or 64 clk_sys of work since the last response (back to back, one edge later on the plain and text ports and two on the GRCG's: the port's own turnaround), where the rate-shaped table before it answered sooner the more work there was, and a GVRAM read held that late still hands the CPU the word stored there (word and dword, in every display-mode cell, scan on and off); every GVRAM, text-RAM and PEGC packed store stays or becomes RATE-shaped (a text store and a packed store accepted no sooner than the class's period after the previous one, the text store now posted and its byte walk kept on its own route when the CPU's next request is a CG-window read, so 0 or 8 clk_sys of work between stores hide inside the period); every class is priced by the display-mode column (24 kHz, 31 kHz, 31 kHz with the 256-colour display on) and the raster phase from the generated class table, each expected value cited to its capture row and converted to the nearest clk_sys, at 90 MHz (the base build) and 120 MHz (heavyoc); and with Fast every port time, store spacing and PEGC handshake is EQUAL to the tree before the change (pinned, cycle for cycle). FAIL-FIRST: on the tree before the change every Xe10 read's port time shrinks with the work (a GVRAM word read in the 24 kHz blank answers in 57 clk_sys after no work and 6 after 64 at 90 MHz, against the table's 48), the 31 kHz and 256-colour columns read the 24 kHz rows, the text store is not posted (8 clk_sys of work do not hide) and the PEGC packed path is not paced at all, while every Fast pin passes. The fourth display-mode column, 24P (24 kHz with the 256-colour display on, xe10_mode 3), prices the text read from XE10Y /CELLS's 2P rows (docs/probes/XE10Y-XE10-CELLS.TXT:31 XCR_2PA 759.0 ns net on a graphics line, :143 623.9 off one, :79 and :191 the two-word read 995.8 and 824.2) and every other 24P cell as the 24 column; before it the device clamped mode 3 onto the 31 kHz 256-colour column (705.7).
//
// THE DUTS are the three devices that price CPU accesses from pc9821_xe10_timing_pkg: the GVRAM
// (pc9821_gvram_dut: the arbiter, the GRCG and the array), the text RAM (pc9821_window_responder
// over a one-cycle byte RAM) and the PEGC packed pacer (pc9821_pegc_xe10_pace over an always-ready
// buffer), each at two clocks in one simulation. THE EXPECTED VALUES are the capture's, one row
// per class and display-mode cell with its citation (tools/xe10_classes.csv carries the same rows;
// tools/check_xe10_table.py re-derives them), converted here to the nearest clk_sys. THE CORE'S
// OWN SHARES are measurements of this core, not of the machine, and are named where they are used:
// 8 clk_sys of a read are the CPU's around the port (docs/probes/core/XE10X-CORE-h6-85942c3c-s3-
// FAST-RDLAT1.TXT: the unpaced GVRAM read 14 clk_sys, :34, the text read 21, :78, against the
// ports' 6 and 13 after 64 clk_sys of work, which the Fast pins below hold), and 18 the unpaced
// PEGC packed read's (:114). A PORT TIME is counted from the first rising edge that samples the
// request to the rising edge that samples the response strobe.
// THE FAST PINS were measured on the tree before the Xe10 table (the change leaves Fast alone).
//
// THE SHAPE, as the bench sees it at a port: the driver presents the next access N clk_sys after
// the previous one's response (a read) or ready (a store). A LATENCY read's port time is the same
// for every N; a RATE period would answer sooner as N grows (the period has partly run). A RATE
// store's spacing is the period for small N (the work hides) and N + 2 past the knee.

`default_nettype none

module tb_pc9821_xe10_latency;
  reg clk90 = 1'b0, clk120 = 1'b0;
  always #5.556 clk90 = ~clk90;
  always #4.167 clk120 = ~clk120;
  reg reset = 1'b1;
  initial begin
    repeat (8) @(posedge clk120);
    reset = 1'b0;
  end

  // ==== DUT ====
  wire gd90, gd120, td90, td120, pd90, pd120;
  wire [31:0] ge90, ge120, te90, te120, pe90, pe120;
  // Fast pins, clk_sys, measured on the tree before the Xe10 table:
  //   GVRAM read port time (plain word, plain dword, TCR word, TCR offset-1 word) after no work
  //   and after 64 clk_sys of work (the Fast period is 478 ns, so the first is period-bound).
  xe10_gv_probe #(.HZ(90_000_000),
      .F0_PW(42), .F0_PD(42), .F0_TW(42), .F0_TO(42),
      .F64_PW(6), .F64_PD(10), .F64_TW(6), .F64_TO(6))
    g90 (.clk(clk90), .reset(reset), .done(gd90), .errors(ge90));
  xe10_gv_probe #(.HZ(120_000_000),
      .F0_PW(56), .F0_PD(56), .F0_TW(56), .F0_TO(56),
      .F64_PW(6), .F64_PD(10), .F64_TW(6), .F64_TO(6))
    g120 (.clk(clk120), .reset(reset), .done(gd120), .errors(ge120));
  //   Text RAM: the read's port time, the word store's ready (un-posted: its walk) and the word
  //   store stream's spacing with 0 and 8 clk_sys of work.
  xe10_tx_probe #(.HZ(90_000_000), .F_RD0(14), .F_RD64(13), .F_WRDY(7), .F_WS0(8), .F_WS8(16))
    t90 (.clk(clk90), .reset(reset), .done(td90), .errors(te90));
  xe10_tx_probe #(.HZ(120_000_000), .F_RD0(14), .F_RD64(13), .F_WRDY(7), .F_WS0(8), .F_WS8(16))
    t120 (.clk(clk120), .reset(reset), .done(td120), .errors(te120));
  xe10_pk_probe #(.HZ(90_000_000))  p90  (.clk(clk90),  .reset(reset), .done(pd90),  .errors(pe90));
  xe10_pk_probe #(.HZ(120_000_000)) p120 (.clk(clk120), .reset(reset), .done(pd120), .errors(pe120));

  // ==== CHECKS ====
  // Each probe runs its rows and counts its failures (the probes' `check_eq` tasks).
  // ==== VERDICT ====
  initial begin
    wait (gd90 && gd120 && td90 && td120 && pd90 && pd120);
    #50;
    if (ge90 + ge120 + te90 + te120 + pe90 + pe120 != 0)
      $fatal(1, "TB_PC9821_XE10_LATENCY: FAIL (GVRAM %0d/%0d, text RAM %0d/%0d, PEGC %0d/%0d errors at 90/120 MHz)",
             ge90, ge120, te90, te120, pe90, pe120);
    $display("TB_PC9821_XE10_LATENCY: PASS");
    $finish;
  end
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_XE10_LATENCY: FAIL (did not finish in 20 ms of simulated time)");
  end
endmodule

// ---------------------------------------------------------------------------------------------
// The nearest clk_sys of a capture time (ns x10), half up: the class table's own conversion rule.
// ---------------------------------------------------------------------------------------------
`define XE10_CYC(hz, x10) (((64'(hz) * 64'(x10)) + 64'd5_000_000_000) / 64'd10_000_000_000)

module xe10_gv_probe #(
    parameter integer HZ = 90_000_000,
    parameter integer F0_PW = 0, F0_PD = 0, F0_TW = 0, F0_TO = 0,
    parameter integer F64_PW = 0, F64_PD = 0, F64_TW = 0, F64_TO = 0
) (
    input  wire clk,
    input  wire reset,
    output reg  done,
    output reg [31:0] errors
);
  localparam integer CPU_CYC = 8;   // the core CPU's own cycles around a read (header)
  reg        timing_xe10 = 1'b0, gfx_scan_on = 1'b0;
  reg  [1:0] xe10_mode = 2'd0;
  reg [14:0] win_offset = 15'h0400;
  reg [31:0] cpu_din = 32'h5AA5_C33C;
  reg  [3:0] cpu_be = 4'hF;
  reg        cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0] cpu_dout, cpu_line_word;
  wire        cpu_ready, cpu_resp_valid, cpu_line_word_valid;
  reg        grcg_we = 1'b0;
  reg  [7:0] grcg_addr = 8'd0, grcg_din = 8'd0;
  wire       grcg_expand;
  wire [31:0] line_data;
  wire        line_sel, line_ready;
  pc9821_gvram_dut #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .reset(reset), .access_page(1'b0),
      .timing_xe10(timing_xe10), .gfx_scan_on(gfx_scan_on), .xe10_mode(xe10_mode),
      .win_plane(2'd0), .win_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(1'b0),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din), .grcg_expand(grcg_expand),
      .egc_gate(1'b0), .egc_access(16'hFFFF), .egc_fgbg(16'd0), .egc_ope(16'd0), .egc_fg(16'd0),
      .egc_mask(16'hFFFF), .egc_bg(16'd0), .egc_sft(16'd0), .egc_leng(16'd0), .egc_shift_we(1'b0),
      .scan_enable(1'b0), .scan_line_tick(1'b0), .scan_page(1'b0), .scan_line_base(15'd0),
      .gfx_odd_line(1'b0), .line_rd_addr(7'd0), .line_rd_sel(1'b0),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready),
      .dbg_gfx_stats(), .dbg_walk_start(), .dbg_walk_cycle(), .dbg_egc_txn(), .dbg_egc_unit(),
      .dbg_grcg_store(), .dbg_gr_owned(), .dbg_eg_owned(), .dbg_access_page(), .dbg_scan_page_q());

  // A cycle count that moves on the falling edge, so a rising-edge sample is race-free.
  integer ncyc = 0;
  reg [31:0] last_rd = 32'd0;
  always @(negedge clk) ncyc <= ncyc + 1;

  task automatic grcg_w(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk); grcg_we = 1'b1; grcg_addr = a; grcg_din = d;
      @(negedge clk); grcg_we = 1'b0;
    end
  endtask
  task automatic settle;   // the table's levels are registered twice (mode_q, the current row)
    begin
      cpu_valid = 1'b0;
      while ((dut.u_arb.gstate != 3'd0) || (dut.u_arb.cs != 4'd0) || (dut.u_grcg.gstate != 4'd0) ||
             (dut.u_arb.hold_left != 0)) @(posedge clk);
      repeat (6) @(posedge clk);
    end
  endtask
  // One read presented `n` clk_sys after the previous response; -> its port time (request to
  // response strobe, in rising edges).
  task automatic rd1(input [3:0] be, input integer n, output integer port);
    integer t0;
    begin
      repeat (n) @(posedge clk);
      @(negedge clk);
      cpu_be = be; cpu_write = 1'b0; cpu_valid = 1'b1;
      @(posedge clk); t0 = ncyc;
      while (!cpu_ready) @(posedge clk);
      #1 cpu_valid = 1'b0;
      while (!cpu_resp_valid) @(posedge clk);
      port = ncyc - t0;
      last_rd = cpu_dout;   // the datum the CPU latches on the strobe
    end
  endtask
  // A read stream with `n` clk_sys of work between reads: the steady port time (the 4th read).
  task automatic rd_stream(input [3:0] be, input integer n, output integer port);
    integer k, p;
    begin
      settle;
      for (k = 0; k < 5; k = k + 1) begin
        rd1(be, n, p);
        if (k == 3) port = p;
      end
    end
  endtask
  // A store stream with `n` clk_sys of work after each ready: the steady ready-to-ready spacing.
  task automatic wr_stream(input [3:0] be, input integer n, output integer sp);
    integer k, t, tl;
    begin
      settle;
      tl = 0;
      for (k = 0; k < 6; k = k + 1) begin
        repeat (n) @(posedge clk);
        @(negedge clk);
        cpu_be = be; cpu_write = 1'b1; cpu_valid = 1'b1;
        @(posedge clk);
        while (!cpu_ready) @(posedge clk);
        t = ncyc;
        if (k == 4) sp = t - tl;
        tl = t;
        #1 cpu_valid = 1'b0; cpu_write = 1'b0;
      end
    end
  endtask

  task automatic check_eq(input [8*72-1:0] what, input integer got, input integer want);
    begin
      if (got != want) begin
        $display("  FAIL @%0d MHz GVRAM %0s: %0d clk_sys, want %0d", HZ / 1_000_000, what, got, want);
        errors = errors + 1;
      end else
        $display("  ok   @%0d MHz GVRAM %0s: %0d clk_sys", HZ / 1_000_000, what, got);
    end
  endtask

  integer p0, p8, p32, p64, s0, s4;
  integer dm, ds;
  // A read class in one display-mode cell: the port time is the capture's net less the CPU's
  // share, after 0, 8, 32 and 64 clk_sys of work alike.
  task automatic gv_rd(input [7:0] grcg_mode, input [3:0] be, input [1:0] mode, input scan,
                       input integer x10);
    integer want;
    begin
      grcg_w(8'h7C, grcg_mode);
      timing_xe10 = 1'b1; xe10_mode = mode; gfx_scan_on = scan;
      want = int'(`XE10_CYC(HZ, x10)) - CPU_CYC;
      rd_stream(be, 0, p0);  rd_stream(be, 8, p8);
      rd_stream(be, 32, p32); rd_stream(be, 64, p64);
      $display("  -- grcg %02h be %b mode %0d scan %0d: capture %0d.%0d ns", grcg_mode, be, mode, scan,
               x10 / 10, x10 % 10);
      // back to back the request waits out the port's own turnaround first: one edge for the
      // plain client (C_RESP2), two for the GRCG (G_RESP2, G_HOLD)
      check_eq("read, no work (+ the port's turnaround)", p0, want + ((grcg_mode == 8'h80) ? 2 : 1));
      check_eq("read, 8 clk_sys of work", p8, want);
      check_eq("read, 32 clk_sys of work", p32, want);
      check_eq("read, 64 clk_sys of work", p64, want);
    end
  endtask
  // A store class in one cell: the spacing is the capture's period with 0 and 4 clk_sys of work.
  task automatic gv_wr(input [7:0] grcg_mode, input [3:0] be, input [1:0] mode, input scan,
                       input integer x10);
    integer want;
    begin
      grcg_w(8'h7C, grcg_mode);
      timing_xe10 = 1'b1; xe10_mode = mode; gfx_scan_on = scan;
      want = int'(`XE10_CYC(HZ, x10));
      wr_stream(be, 0, s0); wr_stream(be, 4, s4);
      $display("  -- grcg %02h be %b mode %0d scan %0d: capture %0d.%0d ns", grcg_mode, be, mode, scan,
               x10 / 10, x10 % 10);
      check_eq("store spacing, no work", s0, want);
      check_eq("store spacing, 4 clk_sys of work", s4, want);
    end
  endtask
  task automatic fast_rd(input [8*40-1:0] what, input [7:0] grcg_mode, input [3:0] be,
                         input integer want0, input integer want64);
    begin
      grcg_w(8'h7C, grcg_mode);
      timing_xe10 = 1'b0; xe10_mode = 2'd1; gfx_scan_on = 1'b1;   // Fast reads neither
      rd_stream(be, 0, p0); rd_stream(be, 64, p64);
      check_eq({"Fast ", what, ", no work"}, p0, want0);
      check_eq({"Fast ", what, ", 64 clk_sys of work"}, p64, want64);
    end
  endtask

  initial begin
    done = 1'b0; errors = 0;
    wait (!reset);
    repeat (10) @(posedge clk);
    grcg_w(8'h7E, 8'hFF); grcg_w(8'h7E, 8'h00); grcg_w(8'h7E, 8'hFF); grcg_w(8'h7E, 8'h00);
    //   grcg  be      mode  scan  ns x10   class, capture row
    gv_rd(8'h00, 4'b0011, 2'd0, 1'b0,  6239);  // GV_RD_PLAIN_1W_24V XE10X-XE10-RDLAT1.TXT:230 net
    gv_rd(8'h00, 4'b0011, 2'd0, 1'b1,  6970);  // GV_RD_PLAIN_1W_24A XE10X-XE10-RDLAT1.TXT:130 net
    gv_rd(8'h00, 4'b0011, 2'd1, 1'b0,  5722);  // GV_RD_PLAIN_1W_31V XE10X-XE10-RDLAT1.TXT:432 net
    gv_rd(8'h00, 4'b0011, 2'd1, 1'b1,  6398);  // GV_RD_PLAIN_1W_31A XE10X-XE10-RDLAT1.TXT:332 net
    gv_rd(8'h00, 4'b0011, 2'd2, 1'b0,  5722);  // GV_RD_PLAIN_1W_48V XE10X-XE10-RDLAT1.TXT:432 net (fallback-31)
    gv_rd(8'h00, 4'b0011, 2'd2, 1'b1,  6398);  // GV_RD_PLAIN_1W_48A XE10X-XE10-RDLAT1.TXT:332 net (fallback-31)
    gv_rd(8'h00, 4'b1111, 2'd0, 1'b0,  8226);  // GV_RD_PLAIN_2W_24V XE10X-XE10-RDLAT1.TXT:237 net
    gv_rd(8'h00, 4'b1111, 2'd0, 1'b1,  8973);  // GV_RD_PLAIN_2W_24A XE10X-XE10-RDLAT1.TXT:137 net
    gv_rd(8'h00, 4'b1111, 2'd1, 1'b0,  7415);  // GV_RD_PLAIN_2W_31V XE10X-XE10-RDLAT1.TXT:439 net
    gv_rd(8'h00, 4'b1111, 2'd1, 1'b1,  8234);  // GV_RD_PLAIN_2W_31A XE10X-XE10-RDLAT1.TXT:339 net
    gv_rd(8'h00, 4'b1111, 2'd2, 1'b0,  7415);  // GV_RD_PLAIN_2W_48V XE10X-XE10-RDLAT1.TXT:439 net (fallback-31)
    gv_rd(8'h00, 4'b1111, 2'd2, 1'b1,  8234);  // GV_RD_PLAIN_2W_48A XE10X-XE10-RDLAT1.TXT:339 net (fallback-31)
    gv_rd(8'h80, 4'b0011, 2'd0, 1'b0,  6732);  // GV_RD_TCR_1W_24V XE10X-XE10-RDLAT1.TXT:253 net
    gv_rd(8'h80, 4'b0011, 2'd0, 1'b1,  7574);  // GV_RD_TCR_1W_24A XE10X-XE10-RDLAT1.TXT:153 net
    gv_rd(8'h80, 4'b0011, 2'd1, 1'b0,  6183);  // GV_RD_TCR_1W_31V XE10X-XE10-RDLAT1.TXT:455 net
    gv_rd(8'h80, 4'b0011, 2'd1, 1'b1,  6898);  // GV_RD_TCR_1W_31A XE10X-XE10-RDLAT1.TXT:355 net
    gv_rd(8'h80, 4'b0011, 2'd2, 1'b0,  6183);  // GV_RD_TCR_1W_48V XE10X-XE10-RDLAT1.TXT:455 net (fallback-31)
    gv_rd(8'h80, 4'b0011, 2'd2, 1'b1,  6898);  // GV_RD_TCR_1W_48A XE10X-XE10-RDLAT1.TXT:355 net (fallback-31)
    gv_rd(8'h80, 4'b0110, 2'd0, 1'b0,  9307);  // GV_RD_TCR_2W_24V XE10W-XE10-MIS2RUN1.TXT:374 net
    gv_rd(8'h80, 4'b0110, 2'd0, 1'b1, 10356);  // GV_RD_TCR_2W_24A XE10W-XE10-MIS2RUN1.TXT:269 net
    gv_rd(8'h80, 4'b0110, 2'd1, 1'b0,  8273);  // GV_RD_TCR_2W_31V XE10Y-XE10-CELLS.TXT:337 net
    gv_rd(8'h80, 4'b0110, 2'd1, 1'b1,  9108);  // GV_RD_TCR_2W_31A XE10Y-XE10-CELLS.TXT:257 net
    gv_rd(8'h80, 4'b0110, 2'd2, 1'b0,  8273);  // GV_RD_TCR_2W_48V XE10Y-XE10-CELLS.TXT:337 net (fallback-31)
    gv_rd(8'h80, 4'b0110, 2'd2, 1'b1,  9108);  // GV_RD_TCR_2W_48A XE10Y-XE10-CELLS.TXT:257 net (fallback-31)
    gv_wr(8'h00, 4'b0011, 2'd0, 1'b0,  1426);  // GV_WR_PLAIN_1W_24V XE10T-XE10.TXT:56 pit
    gv_wr(8'h00, 4'b0011, 2'd0, 1'b1,  1653);  // GV_WR_PLAIN_1W_24A XE10V-XE10-MISAL1.TXT:282 pit
    gv_wr(8'h00, 4'b0011, 2'd1, 1'b0,  1462);  // GV_WR_PLAIN_1W_31V XE10X-XE10-RDLAT1.TXT:446 pit
    gv_wr(8'h00, 4'b0011, 2'd1, 1'b1,  1661);  // GV_WR_PLAIN_1W_31A XE10X-XE10-RDLAT1.TXT:346 pit
    gv_wr(8'h00, 4'b0011, 2'd2, 1'b0,  1462);  // GV_WR_PLAIN_1W_48V XE10X-XE10-RDLAT1.TXT:446 pit (fallback-31)
    gv_wr(8'h00, 4'b0011, 2'd2, 1'b1,  1661);  // GV_WR_PLAIN_1W_48A XE10X-XE10-RDLAT1.TXT:346 pit (fallback-31)
    gv_wr(8'h80, 4'b0011, 2'd0, 1'b0,  1678);  // GV_WR_TDW_1W_24V XE10T-XE10.TXT:145 pit
    gv_wr(8'h80, 4'b0011, 2'd0, 1'b1,  1949);  // GV_WR_TDW_1W_24A XE10V-XE10-MISAL1.TXT:251 pair (TDW_W3_A pit / 2)
    gv_wr(8'h80, 4'b0011, 2'd1, 1'b0,  1669);  // GV_WR_TDW_1W_31V XE10X-XE10-RDLAT1.TXT:462 pit
    gv_wr(8'h80, 4'b0011, 2'd1, 1'b1,  1971);  // GV_WR_TDW_1W_31A XE10X-XE10-RDLAT1.TXT:362 pit
    gv_wr(8'h80, 4'b0011, 2'd2, 1'b0,  1669);  // GV_WR_TDW_1W_48V XE10X-XE10-RDLAT1.TXT:462 pit (fallback-31)
    gv_wr(8'h80, 4'b0011, 2'd2, 1'b1,  1971);  // GV_WR_TDW_1W_48A XE10X-XE10-RDLAT1.TXT:362 pit (fallback-31)
    gv_wr(8'hC0, 4'b0011, 2'd0, 1'b0,  2553);  // GV_WR_RMW_1W_24V XE10T-XE10.TXT:141 pit
    gv_wr(8'hC0, 4'b0011, 2'd0, 1'b1,  2995);  // GV_WR_RMW_1W_24A RWIPE-XE10.TXT:16 rwipe
    gv_wr(8'hC0, 4'b0011, 2'd1, 1'b0,  2217);  // GV_WR_RMW_1W_31V XE10X-XE10-RDLAT1.TXT:469 pit
    gv_wr(8'hC0, 4'b0011, 2'd1, 1'b1,  2726);  // GV_WR_RMW_1W_31A XE10X-XE10-RDLAT1.TXT:369 pit
    gv_wr(8'hC0, 4'b0011, 2'd2, 1'b0,  2217);  // GV_WR_RMW_1W_48V XE10X-XE10-RDLAT1.TXT:469 pit (fallback-31)
    gv_wr(8'hC0, 4'b0011, 2'd2, 1'b1,  2726);  // GV_WR_RMW_1W_48A XE10X-XE10-RDLAT1.TXT:369 pit (fallback-31)
    // the 31 kHz two-word store cells kit 3 measured (dword stores, both halves of the dword)
    gv_wr(8'h80, 4'b1111, 2'd1, 1'b0,  1828);  // GV_WR_TDW_2W_31V XE10Y-XE10-CELLS.TXT:361 pit
    gv_wr(8'h80, 4'b1111, 2'd1, 1'b1,  2225);  // GV_WR_TDW_2W_31A XE10Y-XE10-CELLS.TXT:281 pit
    gv_wr(8'h80, 4'b1111, 2'd2, 1'b1,  2225);  // GV_WR_TDW_2W_48A XE10Y-XE10-CELLS.TXT:281 pit (fallback-31)
    gv_wr(8'hC0, 4'b1111, 2'd1, 1'b0,  4236);  // GV_WR_RMW_2W_31V XE10Y-XE10-CELLS.TXT:377 pit
    gv_wr(8'hC0, 4'b1111, 2'd1, 1'b1,  5055);  // GV_WR_RMW_2W_31A XE10Y-XE10-CELLS.TXT:297 pit
    gv_wr(8'hC0, 4'b1111, 2'd2, 1'b0,  4236);  // GV_WR_RMW_2W_48V XE10Y-XE10-CELLS.TXT:377 pit (fallback-31)
    // 24P, the fourth column (24 kHz with the 256-colour display on): the GVRAM is not reachable
    // there on the machine (CELLS: 0xB8000 reads FFFF), so every GVRAM 24P cell is the 24 column's
    gv_rd(8'h00, 4'b0011, 2'd3, 1'b0,  6239);  // GV_RD_PLAIN_1W_24PV XE10X-XE10-RDLAT1.TXT:230 net (fallback-24)
    gv_rd(8'h00, 4'b0011, 2'd3, 1'b1,  6970);  // GV_RD_PLAIN_1W_24PA XE10X-XE10-RDLAT1.TXT:130 net (fallback-24)
    gv_rd(8'h80, 4'b0110, 2'd3, 1'b1, 10356);  // GV_RD_TCR_2W_24PA XE10W-XE10-MIS2RUN1.TXT:269 net (fallback-24)
    gv_wr(8'h00, 4'b0011, 2'd3, 1'b1,  1653);  // GV_WR_PLAIN_1W_24PA XE10V-XE10-MISAL1.TXT:282 pit (fallback-24)
    gv_wr(8'hC0, 4'b0011, 2'd3, 1'b0,  2553);  // GV_WR_RMW_1W_24PV XE10T-XE10.TXT:141 pit (fallback-24)
    // DATA at the late strobe: an Xe10-held read must still hand the CPU the stored word. A plain
    // dword store of cpu_din, then reads in every display-mode cell, scan on and off, after 0 and
    // 64 clk_sys of work: the word read returns its low half and the dword the whole word (what
    // was stored is what is read - the RAM's own contract, not a timing capture).
    grcg_w(8'h7C, 8'h00);
    timing_xe10 = 1'b1; xe10_mode = 2'd0; gfx_scan_on = 1'b0;
    wr_stream(4'b1111, 0, s0);
    for (dm = 0; dm < 4; dm = dm + 1)
      for (ds = 0; ds < 2; ds = ds + 1) begin
        xe10_mode = dm[1:0]; gfx_scan_on = ds[0];
        settle; rd1(4'b0011, 0, p0);
        if (last_rd[15:0] !== cpu_din[15:0]) begin
          $display("  FAIL @%0d MHz GVRAM Xe10 word read (mode %0d scan %0d) returned %04x, stored %04x",
                   HZ / 1_000_000, dm, ds, last_rd[15:0], cpu_din[15:0]);
          errors = errors + 1;
        end
        settle; rd1(4'b1111, 64, p64);
        if (last_rd !== cpu_din) begin
          $display("  FAIL @%0d MHz GVRAM Xe10 dword read (mode %0d scan %0d) returned %08x, stored %08x",
                   HZ / 1_000_000, dm, ds, last_rd, cpu_din);
          errors = errors + 1;
        end
      end
    $display("  data @%0d MHz GVRAM Xe10 reads checked in 8 cells", HZ / 1_000_000);
    // Fast: equal to the tree before the table
    fast_rd("plain word read",    8'h00, 4'b0011, F0_PW, F64_PW);
    fast_rd("plain dword read",   8'h00, 4'b1111, F0_PD, F64_PD);
    fast_rd("TCR word read",      8'h80, 4'b0011, F0_TW, F64_TW);
    fast_rd("TCR offset-1 read",  8'h80, 4'b0110, F0_TO, F64_TO);
    done = 1'b1;
  end
endmodule

module xe10_tx_probe #(
    parameter integer HZ = 90_000_000,
    parameter integer F_RD0 = 0, F_RD64 = 0, F_WRDY = 0, F_WS0 = 0, F_WS8 = 0
) (
    input  wire clk,
    input  wire reset,
    output reg  done,
    output reg [31:0] errors
);
  localparam integer CPU_CYC = 8;
  reg        timing_xe10 = 1'b0, gfx_scan_on = 1'b0, route_cg = 1'b0;
  reg  [1:0] xe10_mode = 2'd0;
  reg [31:0] cpu_din = 32'h2020_2020;
  reg  [3:0] cpu_be = 4'hF;
  reg        cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0] cpu_dout, cpu_line_word;
  wire        cpu_ready, cpu_resp_valid, cpu_line_word_valid;
  wire        dma_ready, dma_resp_valid;
  wire  [7:0] dma_dout;
  wire [13:0] tram_addr;
  wire  [7:0] tram_din, byte_din;
  wire        tram_we, byte_rd, byte_we;
  wire  [4:0] byte_sel;
  reg   [7:0] tram_dout = 8'd0;
  reg   [7:0] ram [0:16383];
  always @(posedge clk) begin
    if (tram_we) ram[tram_addr] <= tram_din;
    tram_dout <= ram[tram_addr];
  end
  pc9821_window_responder #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .reset(reset), .timing_xe10(timing_xe10), .gfx_scan_on(gfx_scan_on),
      .xe10_mode(xe10_mode), .route_cg(route_cg),
      .cpu_addr(14'h1000), .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(1'b0),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write), .cpu_dout(cpu_dout),
      .cpu_line_word(cpu_line_word), .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .dma_route_cg(1'b0), .dma_valid(1'b0), .dma_write(1'b0), .dma_addr(14'd0), .dma_din(8'd0),
      .dma_ready(dma_ready), .dma_resp_valid(dma_resp_valid), .dma_dout(dma_dout),
      .tram_addr(tram_addr), .tram_din(tram_din), .tram_we(tram_we), .tram_dout(tram_dout),
      .byte_sel(byte_sel), .byte_rd(byte_rd), .byte_dout(8'h00), .byte_hold(1'b0),
      .byte_din(byte_din), .byte_we(byte_we));

  integer ncyc = 0;
  always @(negedge clk) ncyc <= ncyc + 1;
  integer cg_we = 0;   // CG byte-port stores seen
  always @(posedge clk) if (byte_we) cg_we <= cg_we + 1;

  task automatic settle;
    begin
      cpu_valid = 1'b0;
      while ((dut.state != 4'd0) || (dut.tx_left != 0)) @(posedge clk);
      repeat (6) @(posedge clk);
    end
  endtask
  task automatic rd1(input [3:0] be, input integer n, output integer port);
    integer t0;
    begin
      repeat (n) @(posedge clk);
      @(negedge clk);
      cpu_be = be; cpu_write = 1'b0; cpu_valid = 1'b1;
      @(posedge clk); t0 = ncyc;
      while (!cpu_ready) @(posedge clk);
      #1 cpu_valid = 1'b0;
      while (!cpu_resp_valid) @(posedge clk);
      port = ncyc - t0;
    end
  endtask
  task automatic rd_stream(input [3:0] be, input integer n, output integer port);
    integer k, p;
    begin
      settle;
      for (k = 0; k < 5; k = k + 1) begin
        rd1(be, n, p);
        if (k == 3) port = p;
      end
    end
  endtask
  // A store stream: the steady ready-to-ready spacing, and the request-to-ready time of a store.
  task automatic wr_stream(input [3:0] be, input integer n, output integer sp, output integer rdy);
    integer k, t, tl, t0;
    begin
      settle;
      tl = 0;
      for (k = 0; k < 6; k = k + 1) begin
        repeat (n) @(posedge clk);
        @(negedge clk);
        cpu_din = 32'h4141_4141 + k; cpu_be = be; cpu_write = 1'b1; cpu_valid = 1'b1;
        @(posedge clk); t0 = ncyc;
        while (!cpu_ready) @(posedge clk);
        t = ncyc;
        if (k == 0) rdy = t - t0;
        if (k == 4) sp = t - tl;
        tl = t;
        #1 cpu_valid = 1'b0; cpu_write = 1'b0;
      end
    end
  endtask
  task automatic check_eq(input [8*72-1:0] what, input integer got, input integer want);
    begin
      if (got != want) begin
        $display("  FAIL @%0d MHz text RAM %0s: %0d clk_sys, want %0d", HZ / 1_000_000, what, got, want);
        errors = errors + 1;
      end else
        $display("  ok   @%0d MHz text RAM %0s: %0d clk_sys", HZ / 1_000_000, what, got);
    end
  endtask

  integer p0, p8, p32, p64, s0, s8, r0, rdat;
  task automatic tx_rd(input [3:0] be, input [1:0] mode, input scan, input integer x10);
    integer want;
    begin
      timing_xe10 = 1'b1; xe10_mode = mode; gfx_scan_on = scan;
      want = int'(`XE10_CYC(HZ, x10)) - CPU_CYC;
      rd_stream(be, 0, p0);  rd_stream(be, 8, p8);
      rd_stream(be, 32, p32); rd_stream(be, 64, p64);
      $display("  -- read be %b mode %0d scan %0d: capture %0d.%0d ns", be, mode, scan, x10 / 10, x10 % 10);
      check_eq("read, no work (+ the port's turnaround, S_HOLD)", p0, want + 1);
      check_eq("read, 8 clk_sys of work", p8, want);
      check_eq("read, 32 clk_sys of work", p32, want);
      check_eq("read, 64 clk_sys of work", p64, want);
    end
  endtask
  // A store class: posted (ready the cycle after the request) and the period with 0 and 8 clk_sys
  // of work between stores.
  task automatic tx_wr(input [3:0] be, input [1:0] mode, input scan, input integer x10);
    integer want;
    begin
      timing_xe10 = 1'b1; xe10_mode = mode; gfx_scan_on = scan;
      want = int'(`XE10_CYC(HZ, x10));
      wr_stream(be, 0, s0, r0); wr_stream(be, 8, s8, r0);
      $display("  -- store be %b mode %0d scan %0d: capture %0d.%0d ns", be, mode, scan, x10 / 10, x10 % 10);
      check_eq("store posted: request to ready", r0, 1);
      check_eq("store spacing, no work", s0, want);
      check_eq("store spacing, 8 clk_sys of work", s8, want);
    end
  endtask

  integer k;
  initial begin
    done = 1'b0; errors = 0;
    wait (!reset);
    repeat (10) @(posedge clk);
    //   be      mode  scan  ns x10   class, capture row
    tx_rd(4'b0011, 2'd0, 1'b0,  6191);  // TX_RD_1W_24V XE10X-XE10-RDLAT1.TXT:274 net
    tx_rd(4'b0011, 2'd0, 1'b1,  6922);  // TX_RD_1W_24A XE10X-XE10-RDLAT1.TXT:174 net
    tx_rd(4'b0011, 2'd1, 1'b0,  5714);  // TX_RD_1W_31V XE10X-XE10-RDLAT1.TXT:476 net
    tx_rd(4'b0011, 2'd1, 1'b1,  6390);  // TX_RD_1W_31A XE10X-XE10-RDLAT1.TXT:376 net
    tx_rd(4'b0011, 2'd2, 1'b0,  5690);  // TX_RD_1W_48V XE10X-XE10-RDLAT1.TXT:591 net
    tx_rd(4'b0011, 2'd2, 1'b1,  7057);  // TX_RD_1W_48A XE10X-XE10-RDLAT1.TXT:535 net
    tx_rd(4'b1111, 2'd0, 1'b0,  8218);  // TX_RD_2W_24V XE10W-XE10-MIS2RUN1.TXT:405 net
    tx_rd(4'b1111, 2'd0, 1'b1,  8981);  // TX_RD_2W_24A XE10W-XE10-MIS2RUN1.TXT:300 net
    tx_rd(4'b1111, 2'd1, 1'b0,  7423);  // TX_RD_2W_31V XE10Y-XE10-CELLS.TXT:401 net
    tx_rd(4'b1111, 2'd1, 1'b1,  8218);  // TX_RD_2W_31A XE10Y-XE10-CELLS.TXT:321 net
    tx_rd(4'b1111, 2'd2, 1'b0,  7423);  // TX_RD_2W_48V XE10Y-XE10-CELLS.TXT:598 net
    tx_rd(4'b1111, 2'd2, 1'b1,  8726);  // TX_RD_2W_48A XE10Y-XE10-CELLS.TXT:550 net
    tx_wr(4'b0011, 2'd0, 1'b0,  1494);  // TX_WR_1W_24V XE10W-XE10-MIS2RUN1.TXT:380 pit
    tx_wr(4'b0011, 2'd0, 1'b1,  1693);  // TX_WR_1W_24A XE10W-XE10-MIS2RUN1.TXT:275 pit
    tx_wr(4'b0011, 2'd1, 1'b0,  1462);  // TX_WR_1W_31V XE10X-XE10-RDLAT1.TXT:483 pit
    tx_wr(4'b0011, 2'd1, 1'b1,  1637);  // TX_WR_1W_31A XE10X-XE10-RDLAT1.TXT:383 pit
    tx_wr(4'b0011, 2'd2, 1'b0,  1351);  // TX_WR_1W_48V XE10X-XE10-RDLAT1.TXT:598 pit
    tx_wr(4'b0011, 2'd2, 1'b1,  1399);  // TX_WR_1W_48A XE10X-XE10-RDLAT1.TXT:542 pit
    tx_wr(4'b0110, 2'd0, 1'b0,  2829);  // TX_WR_2W_24V XE10W-XE10-MIS2RUN1.TXT:413 pit
    tx_wr(4'b0110, 2'd0, 1'b1,  3219);  // TX_WR_2W_24A XE10W-XE10-MIS2RUN1.TXT:281 pit
    tx_wr(4'b0110, 2'd1, 1'b0,  2829);  // TX_WR_2W_31V XE10W-XE10-MIS2RUN1.TXT:413 pit (fallback-24)
    tx_wr(4'b0110, 2'd1, 1'b1,  3219);  // TX_WR_2W_31A XE10W-XE10-MIS2RUN1.TXT:281 pit (fallback-24)
    tx_wr(4'b0110, 2'd2, 1'b0,  2829);  // TX_WR_2W_48V XE10W-XE10-MIS2RUN1.TXT:413 pit (fallback-24)
    tx_wr(4'b0110, 2'd2, 1'b1,  3219);  // TX_WR_2W_48A XE10W-XE10-MIS2RUN1.TXT:281 pit (fallback-24)
    // 24P, the fourth column (24 kHz with the 256-colour display on): the text READS are measured
    // there (XE10Y /CELLS, 2P) and differ from the 24 column on graphics lines; the stores are the
    // 24 column's (tools/xe10_classes.csv's 24P note)
    tx_rd(4'b0011, 2'd3, 1'b0,  6239);  // TX_RD_1W_24PV XE10Y-XE10-CELLS.TXT:143 net
    tx_rd(4'b0011, 2'd3, 1'b1,  7590);  // TX_RD_1W_24PA XE10Y-XE10-CELLS.TXT:31 net
    tx_rd(4'b1111, 2'd3, 1'b0,  8242);  // TX_RD_2W_24PV XE10Y-XE10-CELLS.TXT:191 net
    tx_rd(4'b1111, 2'd3, 1'b1,  9958);  // TX_RD_2W_24PA XE10Y-XE10-CELLS.TXT:79 net
    tx_wr(4'b0011, 2'd3, 1'b0,  1494);  // TX_WR_1W_24PV XE10W-XE10-MIS2RUN1.TXT:380 pit (fallback-24)
    tx_wr(4'b0011, 2'd3, 1'b1,  1693);  // TX_WR_1W_24PA XE10W-XE10-MIS2RUN1.TXT:275 pit (fallback-24)
    tx_wr(4'b0110, 2'd3, 1'b0,  2829);  // TX_WR_2W_24PV XE10W-XE10-MIS2RUN1.TXT:413 pit (fallback-24)
    tx_wr(4'b0110, 2'd3, 1'b1,  3219);  // TX_WR_2W_24PA XE10W-XE10-MIS2RUN1.TXT:281 pit (fallback-24)
    // the posted store landed: the last word of a stream reads back (the walk ran behind the CPU)
    timing_xe10 = 1'b1; xe10_mode = 2'd0; gfx_scan_on = 1'b0;
    wr_stream(4'b1111, 0, s0, r0);
    settle;
    rdat = {ram[14'h1003], ram[14'h1002], ram[14'h1001], ram[14'h1000]};
    check_eq("posted store read-back (0x41414146 = 1)", (rdat == 32'h4141_4146) ? 1 : 0, 1);
    // ... and its walk keeps ITS route: a CG-window read presented the cycle after the posted
    // store's ready (the CPU's next request) must not take the store's bytes on the CG port
    settle;
    @(negedge clk);
    cpu_din = 32'h5A5B_5C5D; cpu_be = 4'hF; cpu_write = 1'b1; cpu_valid = 1'b1;
    @(posedge clk);
    while (!cpu_ready) @(posedge clk);
    #1 cpu_write = 1'b0; route_cg = 1'b1;   // the next request: a CG window read
    @(posedge clk);
    while (!cpu_ready) @(posedge clk);
    #1 cpu_valid = 1'b0;
    while (!cpu_resp_valid) @(posedge clk);
    #1 route_cg = 1'b0;
    settle;
    rdat = {ram[14'h1003], ram[14'h1002], ram[14'h1001], ram[14'h1000]};
    check_eq("posted store then a CG read: the store landed (0x5A5B5C5D = 1)", (rdat == 32'h5A5B_5C5D) ? 1 : 0, 1);
    check_eq("posted store then a CG read: CG port stores", cg_we, 0);
    // Fast: equal to the tree before the table
    timing_xe10 = 1'b0; xe10_mode = 2'd2; gfx_scan_on = 1'b1;
    rd_stream(4'b0011, 0, p0);  check_eq("Fast word read, no work", p0, F_RD0);
    rd_stream(4'b0011, 64, p64); check_eq("Fast word read, 64 clk_sys of work", p64, F_RD64);
    wr_stream(4'b0011, 0, s0, r0);  check_eq("Fast word store: request to ready", r0, F_WRDY);
    check_eq("Fast word store spacing, no work", s0, F_WS0);
    wr_stream(4'b0011, 8, s8, r0);  check_eq("Fast word store spacing, 8 clk_sys of work", s8, F_WS8);
    done = 1'b1;
  end
endmodule

module xe10_pk_probe #(
    parameter integer HZ = 90_000_000
) (
    input  wire clk,
    input  wire reset,
    output reg  done,
    output reg [31:0] errors
);
  localparam integer PK_CYC = 18;   // the core's own unpaced packed read (header)
  reg        timing_xe10 = 1'b0, gfx_scan_on = 1'b0;
  reg  [1:0] xe10_mode = 2'd0;
  reg        in_valid = 1'b0, in_write = 1'b0, in_packed = 1'b1;
  reg        out_ready = 1'b1;
  reg        rdy_toggle = 1'b0;   // the buffer's ready toggling every cycle (the Fast identity run)
  always @(posedge clk) if (rdy_toggle) out_ready <= ~out_ready;
  wire       in_ready, out_valid;
  pc9821_pegc_xe10_pace #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .reset(reset), .timing_xe10(timing_xe10), .gfx_scan_on(gfx_scan_on),
      .xe10_mode(xe10_mode), .in_valid(in_valid), .in_write(in_write), .in_packed(in_packed),
      .in_ready(in_ready), .out_valid(out_valid), .out_ready(out_ready));

  integer ncyc = 0;
  always @(negedge clk) ncyc <= ncyc + 1;
  // Fast and every unpriced request: the stage is a wire - valid and ready pass unchanged.
  reg fast_watch = 1'b0;
  integer ident_err = 0;
  always @(posedge clk)
    if (fast_watch && ((out_valid !== in_valid) || (in_ready !== out_ready))) ident_err <= ident_err + 1;

  task automatic check_eq(input [8*72-1:0] what, input integer got, input integer want);
    begin
      if (got != want) begin
        $display("  FAIL @%0d MHz PEGC %0s: %0d clk_sys, want %0d", HZ / 1_000_000, what, got, want);
        errors = errors + 1;
      end else
        $display("  ok   @%0d MHz PEGC %0s: %0d clk_sys", HZ / 1_000_000, what, got);
    end
  endtask
  // One access presented `n` clk_sys after the previous accept: -> request to accept.
  task automatic acc1(input wr, input integer n, output integer t);
    integer t0;
    begin
      repeat (n) @(posedge clk);
      @(negedge clk);
      in_write = wr; in_valid = 1'b1;
      @(posedge clk); t0 = ncyc;
      while (!in_ready) @(posedge clk);
      t = ncyc - t0;
      #1 in_valid = 1'b0;
    end
  endtask
  task automatic settle;
    begin
      in_valid = 1'b0;
      repeat (80) @(posedge clk);
    end
  endtask
  integer a0, a8, a32, a64, k, t, tl, tt, s0, s4;
  task automatic pk_rd(input [1:0] mode, input scan, input integer x10);
    integer want;
    begin
      timing_xe10 = 1'b1; xe10_mode = mode; gfx_scan_on = scan;
      want = int'(`XE10_CYC(HZ, x10)) - PK_CYC;
      settle; acc1(1'b0, 0, a0); acc1(1'b0, 0, a0);
      settle; acc1(1'b0, 0, a8); acc1(1'b0, 8, a8);
      settle; acc1(1'b0, 0, a64); acc1(1'b0, 64, a64);
      $display("  -- packed read mode %0d scan %0d: capture %0d.%0d ns", mode, scan, x10 / 10, x10 % 10);
      check_eq("packed read held, back to back", a0, want);
      check_eq("packed read held, 8 clk_sys of work", a8, want);
      check_eq("packed read held, 64 clk_sys of work", a64, want);
    end
  endtask
  task automatic st_stream(input integer n, output integer sp);
    begin
      settle;
      tl = 0;
      for (k = 0; k < 6; k = k + 1) begin
        acc1(1'b1, n, tt);
        t = ncyc;
        if (k == 4) sp = t - tl;
        tl = t;
      end
    end
  endtask
  task automatic pk_wr(input [1:0] mode, input scan, input integer x10);
    integer want;
    begin
      timing_xe10 = 1'b1; xe10_mode = mode; gfx_scan_on = scan;
      want = int'(`XE10_CYC(HZ, x10));
      st_stream(0, s0); st_stream(4, s4);
      $display("  -- packed store mode %0d scan %0d: capture %0d.%0d ns", mode, scan, x10 / 10, x10 % 10);
      check_eq("packed store spacing, no work", s0, want);
      check_eq("packed store spacing, 4 clk_sys of work", s4, want);
    end
  endtask

  initial begin
    done = 1'b0; errors = 0;
    wait (!reset);
    repeat (10) @(posedge clk);
    //   mode  scan  ns x10   class, capture row
    pk_rd(2'd0, 1'b0,  6223);  // PK_RD_24V XE10X-XE10-RDLAT1.TXT:316 net
    pk_rd(2'd0, 1'b1,  7614);  // PK_RD_24A XE10X-XE10-RDLAT1.TXT:216 net
    pk_rd(2'd1, 1'b0,  5730);  // PK_RD_31V XE10X-XE10-RDLAT1.TXT:518 net
    pk_rd(2'd1, 1'b1,  7034);  // PK_RD_31A XE10X-XE10-RDLAT1.TXT:418 net
    pk_rd(2'd2, 1'b0,  5730);  // PK_RD_48V XE10X-XE10-RDLAT1.TXT:633 net
    pk_rd(2'd2, 1'b1,  7026);  // PK_RD_48A XE10X-XE10-RDLAT1.TXT:577 net
    pk_wr(2'd0, 1'b0,  1423);  // PK_WR_24V XE10X-XE10-RDLAT1.TXT:323 pit
    pk_wr(2'd0, 1'b1,  1828);  // PK_WR_24A XE10X-XE10-RDLAT1.TXT:223 pit
    pk_wr(2'd1, 1'b0,  1383);  // PK_WR_31V XE10X-XE10-RDLAT1.TXT:525 pit
    pk_wr(2'd1, 1'b1,  1415);  // PK_WR_31A XE10X-XE10-RDLAT1.TXT:425 pit
    pk_wr(2'd2, 1'b0,  1367);  // PK_WR_48V XE10X-XE10-RDLAT1.TXT:640 pit
    pk_wr(2'd2, 1'b1,  1613);  // PK_WR_48A XE10X-XE10-RDLAT1.TXT:584 pit
    // 24P: the 24 column's rows, which XE10X measured with the 256-colour display on
    pk_rd(2'd3, 1'b0,  6223);  // PK_RD_24PV XE10X-XE10-RDLAT1.TXT:316 net (fallback-24)
    pk_rd(2'd3, 1'b1,  7614);  // PK_RD_24PA XE10X-XE10-RDLAT1.TXT:216 net (fallback-24)
    pk_wr(2'd3, 1'b0,  1423);  // PK_WR_24PV XE10X-XE10-RDLAT1.TXT:323 pit (fallback-24)
    pk_wr(2'd3, 1'b1,  1828);  // PK_WR_24PA XE10X-XE10-RDLAT1.TXT:223 pit (fallback-24)
    // Xe10, a request that is not the packed bank (RAM, the 0xF00000 aperture): unpriced
    timing_xe10 = 1'b1; xe10_mode = 2'd0; in_packed = 1'b0; settle;
    fast_watch = 1'b1;
    acc1(1'b0, 0, a0); acc1(1'b1, 0, a0); acc1(1'b1, 0, a0); acc1(1'b0, 3, a0);
    fast_watch = 1'b0; in_packed = 1'b1;
    // Fast: the stage is a wire, cycle for cycle, for packed reads and stores with the buffer's
    // ready toggling
    timing_xe10 = 1'b0; settle;
    fast_watch = 1'b1;
    rdy_toggle = 1'b1;
    for (k = 0; k < 8; k = k + 1) acc1(k[1], k % 3, a0);
    rdy_toggle = 1'b0;
    @(negedge clk) out_ready = 1'b1;
    fast_watch = 1'b0;
    check_eq("Fast and unpriced requests: valid/ready differences from a wire", ident_err, 0);
    done = 1'b1;
  end
endmodule

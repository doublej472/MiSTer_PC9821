`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GVRAM_XE10_STORE: with OSD I/O timing = Xe10 (pc9821_gvram_arb's timing_xe10) a back-to-back GVRAM store stream is accepted at the real Xe10's sustained store period per class - the store's mode (GRCG RMW, GRCG TDW, plain), its width (one 16-bit GVRAM word, or two: a dword, or a word at dword offset 1, byte enables 0110) and the raster (on a graphics line or not) - and with Fast (timing_xe10 = 0) every class keeps the period it had before the field existed. Each shape is a stream in z486's own shape (the next store presented the cycle the previous one's ready is seen), timed accept to accept at 50 MHz, at 90 MHz (the base build's clk_sys) and at 100 MHz, and must sit within one clk_sys of the capture (docs/probes/XE10V-XE10-MISAL1.TXT and -MISAL2.TXT, XE10V /MISAL; ns = PIT counts x 406.9 / n): the GRCG RMW byte and word 299.5 ns on a graphics line (docs/probes/RWIPE-XE10.TXT, the logo wipe's fill) and 255.3 outside (docs/probes/XE10T-XE10.TXT:141 RMWSTOSW), the RMW two-word store 583.3 / 497.5 (MISAL1 RMW_D0_A, XE10T :135 RMW32) and the offset-1 word 580.1 / 493.5 (RMW_W1_A / _V), the TDW word 193.5 / 168.3 (TDW_W0_A, XE10T :145 TDW16), the TDW two-word 247.2 / 210.6 (TDW_D0_A, XE10T :157 TDW32) and offset-1 word 245.2 / 209.4 (TDW_W1_A / _V), the plain word 165.3 / 142 (PLN_W0_A, GVRAM_WR_HOLD), the plain two-word 321.9 / 280.9 (MISAL2 PLN_D0_A, XE10T :68 W32) and offset-1 word 322.3 / 279.7 (MISAL2 PLN_W1_A / _V); and a word across a dword boundary (two accesses, byte enables 1000 then 0001 at the next dword) costs two word periods per word in each mode and raster (RMW_W3_A 600.8 / _V 511.4, TDW_W3_A 389.8 / _V 337.4, PLN_W3_A 333.8 / _V 286.9); and a back-to-back Fast READ stream (each read presented after the previous response) keeps GVRAM_RD_HOLD's 478 ns per class (the plain and GRCG TCR one- and two-word reads; an Xe10 read is latency-shaped and is tb_pc9821_xe10_latency's). In Fast the GRCG RMW and TDW byte and word stores, on any line, read the GRCG period 103.9 ns (docs/probes/GFX2.TXT GRCG_RMW - CTRLGC), the GRCG two-word stores (walk-bound) are never under it, and the plain stores read the plain-write period 142 ns. Every shape's array-access count is asserted equal in the two tables (the walk is untouched, only its spacing moves) and a stored word is read back in both. FAIL-FIRST: on the tree before the MISAL table (the offset-1 word charged one word period, TDW and plain priced the same on a graphics line), the offset-1 rows (RMW 256 against 493.5) and the graphics-line TDW and plain rows (TDW 168 against 193.5) fail, while every Fast row passes; and at 90 MHz, with TDW on a graphics line priced at 194 ns (17 clk_sys, 188.9 ns), the TDW word across a dword on a graphics line reads 377 ns against 389.8 and fails.
//
// The DUT is pc9821_gvram_dut (the five GVRAM pieces) at three clocks in one simulation: the
// sysclk-invariance rule's 50 / 100 MHz pair (a period is a real time, never a clk_sys count) and
// the shipping 90 MHz, whose clk_sys (11.111 ns) is not a whole number of nanoseconds.

`default_nettype none

module tb_pc9821_gvram_xe10_store;
  reg clk50 = 1'b0, clk90 = 1'b0, clk100 = 1'b0;
  always #10    clk50 = ~clk50;
  always #5.556 clk90 = ~clk90;
  always #5     clk100 = ~clk100;
  reg reset = 1'b1;
  initial begin
    repeat (8) @(posedge clk50);
    reset = 1'b0;
  end

  // ==== DUT ====
  wire done50, done90, done100;
  wire [31:0] err50, err90, err100;
  xe10_store_probe #(.HZ(50_000_000),  .PS(20000)) p50  (.clk(clk50),  .reset(reset), .done(done50),  .errors(err50));
  xe10_store_probe #(.HZ(90_000_000),  .PS(11111)) p90  (.clk(clk90),  .reset(reset), .done(done90),  .errors(err90));
  xe10_store_probe #(.HZ(100_000_000), .PS(10000)) p100 (.clk(clk100), .reset(reset), .done(done100), .errors(err100));

  // ==== CHECKS ====
  // Each probe runs every shape and counts its failures (xe10_store_probe's near/floor_/same,
  // below); the verdict reads the three counts.
  // ==== VERDICT ====
  initial begin
    wait (done50 && done90 && done100);
    #50;
    if (err50 != 0 || err90 != 0 || err100 != 0)
      $fatal(1, "TB_PC9821_GVRAM_XE10_STORE: FAIL (%0d errors at 50 MHz, %0d at 90 MHz, %0d at 100 MHz)",
             err50, err90, err100);
    $display("TB_PC9821_GVRAM_XE10_STORE: PASS");
    $finish;
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_GVRAM_XE10_STORE: FAIL (did not finish in 20 ms of simulated time)");
  end
endmodule

module xe10_store_probe #(
    parameter integer HZ = 50_000_000,
    parameter integer PS = 20000       // ps per clk_sys
) (
    input  wire clk,
    input  wire reset,
    output reg  done,
    output reg [31:0] errors
);
  reg        timing_xe10 = 1'b0, gfx_scan_on = 1'b0;
  reg  [1:0] win_plane = 2'd0;
  reg [14:0] win_offset = 15'd0;
  reg [31:0] cpu_din = 32'd0;
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
      .clk(clk), .reset(reset),
      .access_page(1'b0),
      .timing_xe10(timing_xe10), .gfx_scan_on(gfx_scan_on),
      .win_plane(win_plane), .win_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(1'b0),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .grcg_expand(grcg_expand),
      .egc_gate(1'b0), .egc_access(16'hFFFF), .egc_fgbg(16'd0),
      .egc_ope(16'd0), .egc_fg(16'd0), .egc_mask(16'hFFFF),
      .egc_bg(16'd0), .egc_sft(16'd0), .egc_leng(16'd0),
      .egc_shift_we(1'b0),
      .scan_enable(1'b0), .scan_line_tick(1'b0), .scan_page(1'b0),
      .scan_line_base(15'd0), .gfx_odd_line(1'b0),
      .line_rd_addr(7'd0), .line_rd_sel(1'b0),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready),
      .dbg_gfx_stats(), .dbg_walk_start(), .dbg_walk_cycle(),
      .dbg_egc_txn(), .dbg_egc_unit(), .dbg_grcg_store(),
      .dbg_gr_owned(), .dbg_eg_owned(), .dbg_access_page(), .dbg_scan_page_q());

  integer cyc = 0, acc_cnt = 0;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (dut.gma_en) acc_cnt <= acc_cnt + 1;
  end

  task automatic grcg_w(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk); grcg_we = 1'b1; grcg_addr = a; grcg_din = d;
      @(negedge clk); grcg_we = 1'b0;
    end
  endtask

  task automatic drain;
    begin
      cpu_valid = 1'b0; cpu_write = 1'b0;
      while ((dut.u_arb.gstate != 3'd0) || dut.u_arb.m_mode || (dut.u_arb.cs != 4'd0) ||
             (dut.u_grcg.gstate != 4'd0) || (dut.u_arb.hold_left != 0)) @(posedge clk);
      repeat (4) @(posedge clk);
    end
  endtask

  // A stream of `n` stores, each presented the cycle its predecessor's ready is seen. The period
  // is the accept-to-accept spacing over the stream's steady part: (last ready - second ready)
  // / (n - 2), so the first store (never held) is not in it. Each store goes to the next word on
  // the 80-byte pitch; `be` is the access's byte enables at its dword.
  localparam integer N = 34;
  task automatic stream(input [3:0] be, output integer ns_per, output integer accs);
    integer k, t1, tl, a0;
    begin
      drain;
      @(negedge clk);
      a0 = acc_cnt; t1 = 0; tl = 0;
      for (k = 0; k < N; k = k + 1) begin
        win_plane = 2'd0; win_offset = 15'(15'h0400 + k * 80);
        cpu_din = 32'h5AA5_C33C; cpu_be = be; cpu_write = 1'b1; cpu_valid = 1'b1;
        @(posedge clk);
        while (!cpu_ready) @(posedge clk);
        if (k == 1) t1 = cyc;
        tl = cyc;
        #1;
      end
      cpu_valid = 1'b0; cpu_write = 1'b0;
      drain;
      accs = acc_cnt - a0;
      ns_per = ((tl - t1) * PS) / ((N - 2) * 1000);
    end
  endtask

  // A stream of `n` words ACROSS a dword boundary, each as z486 presents it: two accesses, byte
  // enables 1000 at dword d and 0001 at dword d+1, each presented the cycle its predecessor's
  // ready is seen. The period is per WORD (per pair), over the steady part as in `stream`.
  task automatic stream_pair(output integer ns_per, output integer accs);
    integer k, t1, tl, a0;
    begin
      drain;
      @(negedge clk);
      a0 = acc_cnt; t1 = 0; tl = 0;
      for (k = 0; k < 2 * N; k = k + 1) begin
        win_plane = 2'd0; win_offset = 15'(15'h0400 + (k / 2) * 80 + (k % 2) * 4);
        cpu_din = 32'h5AA5_C33C; cpu_be = (k % 2) ? 4'b0001 : 4'b1000;
        cpu_write = 1'b1; cpu_valid = 1'b1;
        @(posedge clk);
        while (!cpu_ready) @(posedge clk);
        if (k == 3) t1 = cyc;
        tl = cyc;
        #1;
      end
      cpu_valid = 1'b0; cpu_write = 1'b0;
      drain;
      accs = acc_cnt - a0;
      ns_per = ((tl - t1) * PS) / ((N - 2) * 1000);
    end
  endtask

  // A stream of `n` READS in z486's shape: the next read is presented after the previous one's
  // response (a read is blocking). The period is the accept-to-accept spacing, as in `stream`.
  task automatic stream_rd(input [3:0] be, output integer ns_per, output integer accs);
    integer k, t1, tl, a0;
    begin
      drain;
      @(negedge clk);
      a0 = acc_cnt; t1 = 0; tl = 0;
      for (k = 0; k < N; k = k + 1) begin
        win_plane = 2'd0; win_offset = 15'(15'h0400 + k * 80);
        cpu_be = be; cpu_write = 1'b0; cpu_valid = 1'b1;
        @(posedge clk);
        while (!cpu_ready) @(posedge clk);
        if (k == 1) t1 = cyc;
        tl = cyc;
        #1; cpu_valid = 1'b0;
        while (!cpu_resp_valid) @(posedge clk);
        #1;
      end
      drain;
      accs = acc_cnt - a0;
      ns_per = ((tl - t1) * PS) / ((N - 2) * 1000);
    end
  endtask

  // One store's word read back through the plain path (GRCG off): no store may be lost.
  task automatic read_word(input [14:0] off, output [31:0] d);
    begin
      drain;
      @(negedge clk);
      win_plane = 2'd0; win_offset = off; cpu_be = 4'hF; cpu_write = 1'b0; cpu_valid = 1'b1;
      @(posedge clk);
      while (!cpu_ready) @(posedge clk);
      #1; cpu_valid = 1'b0;
      while (!cpu_resp_valid) @(posedge clk);
      #1; d = cpu_dout;
      drain;
    end
  endtask

  // within one clk_sys of the capture's ns (the conversion rounds to the nearest clk_sys)
  task automatic near(input [8*64-1:0] what, input integer got, input integer want_x10);
    integer diff;
    begin
      diff = got * 10 - want_x10;
      if (diff < 0) diff = -diff;
      if (diff * 100 > PS) begin
        $display("  FAIL @%0d MHz %0s: %0d ns per store, the capture's %0d.%0d (+-%0d)",
                 HZ / 1_000_000, what, got, want_x10 / 10, want_x10 % 10, PS / 1000);
        errors = errors + 1;
      end else
        $display("  ok   @%0d MHz %0s: %0d ns per store (capture %0d.%0d)",
                 HZ / 1_000_000, what, got, want_x10 / 10, want_x10 % 10);
    end
  endtask

  task automatic floor_(input [8*64-1:0] what, input integer got, input integer want_x10);
    begin
      if (got * 1000 < want_x10 * 100 - PS) begin
        $display("  FAIL @%0d MHz %0s: %0d ns per store, under the period %0d.%0d",
                 HZ / 1_000_000, what, got, want_x10 / 10, want_x10 % 10);
        errors = errors + 1;
      end else
        $display("  ok   @%0d MHz %0s: %0d ns per store (walk-bound, period %0d.%0d)",
                 HZ / 1_000_000, what, got, want_x10 / 10, want_x10 % 10);
    end
  endtask

  task automatic same(input [8*64-1:0] what, input integer a, input integer b);
    begin
      if (a != b) begin
        $display("  FAIL @%0d MHz %0s: %0d array accesses in Xe10 against %0d in Fast",
                 HZ / 1_000_000, what, a, b);
        errors = errors + 1;
      end
    end
  endtask

  // [mode][scan]: the stream's measured ns and access count, per shape
  integer ns_x, acc_x, ns_f, acc_f;
  reg [31:0] rd;

  // Run one shape in both tables (and the given raster state) and assert both.
  task automatic shape(input [8*64-1:0] what, input [7:0] mode, input scan, input [3:0] be,
                       input integer xe10_x10, input integer fast_x10);
    begin
      grcg_w(8'h7C, mode);
      gfx_scan_on = scan;
      timing_xe10 = 1'b1;
      stream(be, ns_x, acc_x);
      near({what, " Xe10"}, ns_x, xe10_x10);
      timing_xe10 = 1'b0;
      stream(be, ns_f, acc_f);
      // A Fast shape whose own walk outlasts its period (the GRCG dword: the RMW's four-lane
      // read-merge-write, the TDW's two-pair burst) runs at the walk, so its row is a FLOOR (the
      // period may never be undercut) rather than an equality; fast_x10 < 0 marks it.
      if (fast_x10 >= 0) near({what, " Fast"}, ns_f, fast_x10);
      else floor_({what, " Fast"}, ns_f, -fast_x10);
      same(what, acc_x, acc_f);
    end
  endtask

  // The same for the word across a dword boundary (`stream_pair`): Xe10 against the capture,
  // Fast at two word periods (each access is one word).
  task automatic pair_shape(input [8*64-1:0] what, input [7:0] mode, input scan,
                            input integer xe10_x10, input integer fast_x10);
    begin
      grcg_w(8'h7C, mode);
      gfx_scan_on = scan;
      timing_xe10 = 1'b1;
      stream_pair(ns_x, acc_x);
      near({what, " Xe10"}, ns_x, xe10_x10);
      timing_xe10 = 1'b0;
      stream_pair(ns_f, acc_f);
      near({what, " Fast"}, ns_f, fast_x10);
      same(what, acc_x, acc_f);
    end
  endtask

  // A read shape in FAST: mode 0x80 makes a GRCG read the TCR compare read, 0x00 a plain plane
  // read. An Xe10 read is LATENCY-shaped (its response is held, not the next accept) and is
  // tb_pc9821_xe10_latency's, which drives the work between reads that shape needs.
  task automatic rd_shape(input [8*64-1:0] what, input [7:0] mode, input scan, input [3:0] be,
                          input integer fast_x10);
    begin
      grcg_w(8'h7C, mode);
      gfx_scan_on = scan;
      timing_xe10 = 1'b0;
      stream_rd(be, ns_f, acc_f);
      near({what, " Fast"}, ns_f, fast_x10);
    end
  endtask

  initial begin
    done = 1'b0; errors = 0;
    wait (!reset);
    repeat (10) @(posedge clk);
    // the GRCG tiles B,R,G,I (any colour: the subject is the period, not the merge)
    grcg_w(8'h7C, 8'hC0);
    grcg_w(8'h7E, 8'hFF); grcg_w(8'h7E, 8'h00); grcg_w(8'h7E, 8'hFF); grcg_w(8'h7E, 8'h00);

    //            what                            mode  scan  be       Xe10   Fast   (ns x10)
    shape("GRCG RMW word, graphics line",         8'hC0, 1'b1, 4'b0011, 2995, 1039);
    shape("GRCG RMW byte, graphics line",         8'hC0, 1'b1, 4'b0001, 2995, 1039);
    shape("GRCG RMW word, blank",                 8'hC0, 1'b0, 4'b0011, 2553, 1039);
    shape("GRCG RMW byte, blank",                 8'hC0, 1'b0, 4'b0001, 2559, 1039);
    shape("GRCG RMW dword, blank",                8'hC0, 1'b0, 4'b1111, 4975, -1039);
    shape("GRCG RMW dword, graphics line",        8'hC0, 1'b1, 4'b1111, 5833, -1039);
    shape("GRCG RMW offset-1 word, blank",        8'hC0, 1'b0, 4'b0110, 4935, -1039);
    shape("GRCG RMW offset-1 word, graphics line",8'hC0, 1'b1, 4'b0110, 5801, -1039);
    shape("GRCG TDW word, blank",                 8'h80, 1'b0, 4'b0011, 1683, 1039);
    shape("GRCG TDW word, graphics line",         8'h80, 1'b1, 4'b0011, 1935, 1039);
    shape("GRCG TDW dword, blank",                8'h80, 1'b0, 4'b1111, 2106, -1039);
    shape("GRCG TDW dword, graphics line",        8'h80, 1'b1, 4'b1111, 2472, -1039);
    shape("GRCG TDW offset-1 word, blank",        8'h80, 1'b0, 4'b0110, 2094, -1039);
    shape("GRCG TDW offset-1 word, graphics line",8'h80, 1'b1, 4'b0110, 2452, -1039);
    shape("plain word, blank",                    8'h00, 1'b0, 4'b0011, 1420, 1420);
    shape("plain word, graphics line",            8'h00, 1'b1, 4'b0011, 1653, 1420);
    shape("plain offset-1 word, blank",           8'h00, 1'b0, 4'b0110, 2797, 1420);
    shape("plain offset-1 word, graphics line",   8'h00, 1'b1, 4'b0110, 3223, 1420);
    shape("plain dword, graphics line",           8'h00, 1'b1, 4'b1111, 3219, 1420);
    // the word across a dword boundary: two word periods (MISAL1 *_W3_A / _W3_V)
    pair_shape("GRCG RMW word across a dword, blank",         8'hC0, 1'b0, 5114, 2078);
    pair_shape("GRCG RMW word across a dword, graphics line", 8'hC0, 1'b1, 6008, 2078);
    pair_shape("GRCG TDW word across a dword, blank",         8'h80, 1'b0, 3374, 2078);
    pair_shape("GRCG TDW word across a dword, graphics line", 8'h80, 1'b1, 3898, 2078);
    pair_shape("plain word across a dword, blank",            8'h00, 1'b0, 2869, 2840);
    pair_shape("plain word across a dword, graphics line",    8'h00, 1'b1, 3338, 2840);
    // reads in Fast keep GVRAM_RD_HOLD (478 ns); the Xe10 reads are tb_pc9821_xe10_latency's
    rd_shape("plain word read, blank",            8'h00, 1'b0, 4'b0011, 4780);
    rd_shape("plain word read, graphics line",    8'h00, 1'b1, 4'b0011, 4780);
    rd_shape("plain offset-1 word read, blank",   8'h00, 1'b0, 4'b0110, 4780);
    rd_shape("plain dword read, graphics line",   8'h00, 1'b1, 4'b1111, 4780);
    rd_shape("GRCG TCR word read, blank",         8'h80, 1'b0, 4'b0011, 4780);
    rd_shape("GRCG TCR word read, graphics line", 8'h80, 1'b1, 4'b0011, 4780);
    rd_shape("GRCG TCR offset-1 read, blank",     8'h80, 1'b0, 4'b0110, 4780);
    rd_shape("GRCG TCR offset-1 read, graphics line", 8'h80, 1'b1, 4'b0110, 4780);
    shape("plain dword, blank",                   8'h00, 1'b0, 4'b1111, 2809, 1420);

    // the plain dword stream's last word is in the array (the GRCG is off from the last shape)
    read_word(15'(15'h0400 + (N - 1) * 80), rd);
    if (rd != 32'h5AA5_C33C) begin
      $display("  FAIL @%0d MHz: the last stored dword reads %08h, not 5AA5C33C", HZ / 1_000_000, rd);
      errors = errors + 1;
    end
    done = 1'b1;
  end
endmodule

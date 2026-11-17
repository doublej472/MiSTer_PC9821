`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_TRAM_XE10_PACE: with OSD I/O timing = Xe10 (pc9821_window_responder's timing_xe10) a back-to-back stream of CPU STORES to the text RAM starts at the real Xe10's period per class - the width (one 16-bit word, or two: a dword or a word at dword offset 1, byte enables 0110) and the raster (on a graphics line or not) - and with Fast (timing_xe10 = 0) the stream keeps the byte walk's own pace exactly, no period: 15 clk_sys per read (the walk and its response), 8 per word or two-word store and 7 per byte store at both clocks, the counts the responder had before the Xe10 field existed (measured by this stream on that tree). Each class is a stream in z486's shape (the next access presented the cycle the previous one's accept is seen; a read waits for its response), timed start to start at 90 MHz (the base build's clk_sys) and at 120 MHz, and must sit within one clk_sys of docs/probes/XE10W-XE10-MIS2RUN1.TXT (XE10W /MISAL2, ns = PIT counts x 406.9 / 512): the word store 169.3 on a graphics line and 149.4 in the blank (XCW_0_A / _V), the two-word store 321.9 / 282.9 (XCW_1_A, XAW_1_V); the Xe10 READS are latency-shaped and are tb_pc9821_xe10_latency's (here a Fast word, offset-1 word and dword read keep the walk's 15 clk_sys, and a LINE READ in z486's I-cache-fill shape - burst 4, byte enables 1111, four beats - its 51 clk_sys in Fast, while in Xe10 its next start waits out the two-word read's hold, the table's 821.8 / 898.1 ns net (XCR_1_V / XCR_1_A) less the core CPU's 8 and the port's 2 clk_sys plus the start cycle (65 / 72 clk_sys at 90 MHz), the responder's line-read term being the enables' own two-word class, z486 presenting every line read with enables 1111, asserted in the responder); and the CG window (route_cg = 1) is never paced (8 clk_sys per word store with Xe10 set). FAIL-FIRST: on the tree before the text RAM's Xe10 period the Xe10 stream runs at the walk's pace (a word store about 90 ns against 149.4) and every Xe10 row fails, while every Fast row passes.
//
// The DUT is pc9821_window_responder at two clocks in one simulation, each with its own
// byte-wide text RAM model (one-cycle registered read port, as the GDC's dual-port RAM).

`default_nettype none

module tb_pc9821_tram_xe10_pace;
  reg clk90 = 1'b0, clk120 = 1'b0;
  always #5.556 clk90 = ~clk90;
  always #4.167 clk120 = ~clk120;
  reg reset = 1'b1;
  initial begin
    repeat (8) @(posedge clk90);
    reset = 1'b0;
  end

  // ==== DUT ====
  wire done90, done120;
  wire [31:0] err90, err120;
  tram_pace_probe #(.HZ(90_000_000),  .PS(11111)) p90  (.clk(clk90),  .reset(reset), .done(done90),  .errors(err90));
  tram_pace_probe #(.HZ(120_000_000), .PS(8333))  p120 (.clk(clk120), .reset(reset), .done(done120), .errors(err120));

  // ==== CHECKS ====
  // Each probe runs every class and counts its failures (tram_pace_probe's near/fast_ok).
  // ==== VERDICT ====
  initial begin
    wait (done90 && done120);
    #50;
    if (err90 != 0 || err120 != 0)
      $fatal(1, "TB_PC9821_TRAM_XE10_PACE: FAIL (%0d errors at 90 MHz, %0d at 120 MHz)", err90, err120);
    $display("TB_PC9821_TRAM_XE10_PACE: PASS");
    $finish;
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_TRAM_XE10_PACE: FAIL (did not finish in 20 ms of simulated time)");
  end
endmodule

module tram_pace_probe #(
    parameter integer HZ = 90_000_000,
    parameter integer PS = 11111        // ps per clk_sys
) (
    input  wire clk,
    input  wire reset,
    output reg  done,
    output reg [31:0] errors
);
  reg        timing_xe10 = 1'b0, gfx_scan_on = 1'b0, route_cg = 1'b0;
  reg [13:0] cpu_addr = 14'd0;
  reg [31:0] cpu_din = 32'd0;
  reg  [3:0] cpu_be = 4'hF;
  reg        cpu_valid = 1'b0, cpu_write = 1'b0, cpu_line_read = 1'b0;
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
      .route_cg(route_cg),
      .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write), .cpu_dout(cpu_dout),
      .cpu_line_word(cpu_line_word), .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .dma_route_cg(1'b0), .dma_valid(1'b0), .dma_write(1'b0), .dma_addr(14'd0), .dma_din(8'd0),
      .dma_ready(dma_ready), .dma_resp_valid(dma_resp_valid), .dma_dout(dma_dout),
      .tram_addr(tram_addr), .tram_din(tram_din), .tram_we(tram_we), .tram_dout(tram_dout),
      .byte_sel(byte_sel), .byte_rd(byte_rd), .byte_dout(8'h00), .byte_hold(1'b0),
      .byte_din(byte_din), .byte_we(byte_we));

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // A stream of N accesses in z486's shape; the period is the start-to-start spacing (the cycle
  // the responder leaves S_IDLE for the access) over the steady part, the first start excluded.
  localparam integer N = 24;
  integer starts [0:1023];
  integer nstart = 0;
  wire start_now = (dut.state == 4'd0) && cpu_valid && dut.cpu_start_ok;
  always @(posedge clk)
    if (start_now && nstart < 1024) begin
      starts[nstart] <= cyc;
      nstart <= nstart + 1;
    end

  task automatic stream(input wr, input [3:0] be, output integer ps_per);
    integer k, n0;
    begin
      repeat (200) @(posedge clk);
      n0 = nstart;
      @(negedge clk);
      for (k = 0; k < N; k = k + 1) begin
        cpu_addr = 14'(14'h1000 + k * 4); cpu_din = 32'h2020_2020; cpu_be = be;
        cpu_write = wr; cpu_valid = 1'b1;
        @(posedge clk);
        while (!cpu_ready) @(posedge clk);
        #1; cpu_valid = 1'b0;
        if (!wr) begin
          while (!cpu_resp_valid) @(posedge clk);
          #1;
        end
      end
      repeat (4) @(posedge clk);
      ps_per = ((starts[n0 + N - 1] - starts[n0 + 1]) * PS) / (N - 2);
    end
  endtask

  // A stream of N LINE READS in z486's shape (an I-cache fill: burst 4, enables 1111, accepted at
  // the walk's start, then four beats on cpu_line_word_valid; the next fill after the last beat).
  task automatic stream_line(output integer ps_per);
    integer k, n0, b;
    begin
      repeat (200) @(posedge clk);
      n0 = nstart;
      @(negedge clk);
      for (k = 0; k < N; k = k + 1) begin
        cpu_addr = 14'(14'h1000 + k * 16); cpu_be = 4'hF;
        cpu_write = 1'b0; cpu_line_read = 1'b1; cpu_valid = 1'b1;
        @(posedge clk);
        while (!cpu_ready) @(posedge clk);
        #1; cpu_valid = 1'b0; cpu_line_read = 1'b0;
        for (b = 0; b < 4; b = b + 1) begin
          while (!cpu_line_word_valid) @(posedge clk);
          @(posedge clk);
        end
        #1;
      end
      repeat (4) @(posedge clk);
      ps_per = ((starts[n0 + N - 1] - starts[n0 + 1]) * PS) / (N - 2);
    end
  endtask

  // within one clk_sys of the capture's ns (the conversion rounds to the nearest clk_sys)
  task automatic near(input [8*48-1:0] what, input integer got_ps, input integer want_x10);
    integer diff;
    begin
      diff = got_ps / 100 - want_x10;
      if (diff < 0) diff = -diff;
      if (diff > PS / 100) begin
        $display("  FAIL @%0d MHz %0s: %0d.%0d ns per access, the capture's %0d.%0d", HZ / 1_000_000,
                 what, got_ps / 1000, (got_ps / 100) % 10, want_x10 / 10, want_x10 % 10);
        errors = errors + 1;
      end else
        $display("  ok   @%0d MHz %0s: %0d.%0d ns per access (capture %0d.%0d)", HZ / 1_000_000,
                 what, got_ps / 1000, (got_ps / 100) % 10, want_x10 / 10, want_x10 % 10);
    end
  endtask

  // Fast: the walk's own pace, EXACTLY the period the responder had before the Xe10 field existed
  // (docs/policies.md: in Fast every text RAM period is exactly what it was before), the same
  // clk_sys count at every clock: 15 for a read (its walk and its response), 8 for a word or a
  // two-word store, 7 for a byte store - each class measured by this stream on the responder of
  // the tree before the field, at 90 and 120 MHz alike.
  task automatic fast_eq(input [8*48-1:0] what, input integer got_ps, input integer want_clk);
    begin
      if (got_ps != want_clk * PS) begin
        $display("  FAIL @%0d MHz %0s Fast: %0d ps per access, not the walk's %0d clk_sys (%0d ps)",
                 HZ / 1_000_000, what, got_ps, want_clk, want_clk * PS);
        errors = errors + 1;
      end else
        $display("  ok   @%0d MHz %0s Fast: %0d clk_sys per access", HZ / 1_000_000, what, want_clk);
    end
  endtask

  integer px, pf;
  // Fast's line read: the 16-byte walk with its four beats, 51 clk_sys start to start (the count
  // the responder had before the Xe10 field, measured by this stream on that tree).
  localparam integer LINE_FAST = 51;
  task automatic cls(input [8*48-1:0] what, input wr, input [3:0] be, input scan,
                     input integer xe10_x10, input integer fast_clk);
    begin
      gfx_scan_on = scan;
      timing_xe10 = 1'b1;
      stream(wr, be, px);
      near(what, px, xe10_x10);
      timing_xe10 = 1'b0;
      stream(wr, be, pf);
      fast_eq(what, pf, fast_clk);
    end
  endtask

  // A Fast-only row: an Xe10 READ is latency-shaped (its response is held, not the next start) and
  // is tb_pc9821_xe10_latency's, which drives the work between reads that shape needs.
  task automatic cls_fast(input [8*48-1:0] what, input wr, input [3:0] be, input integer fast_clk);
    begin
      timing_xe10 = 1'b0;
      stream(wr, be, pf);
      fast_eq(what, pf, fast_clk);
    end
  endtask

  initial begin
    done = 1'b0; errors = 0;
    wait (!reset);
    repeat (10) @(posedge clk);
    //   what                                wr    be       scan  Xe10 (ns x10)  Fast (clk)
    cls_fast("word read",                   1'b0, 4'b0011, 15);
    cls_fast("offset-1 word read",          1'b0, 4'b0110, 15);
    cls_fast("dword read",                  1'b0, 4'b1111, 15);
    cls("word store, blank",                1'b1, 4'b0011, 1'b0, 1494, 8);
    cls("word store, graphics line",        1'b1, 4'b0011, 1'b1, 1693, 8);
    cls("byte store, blank",                1'b1, 4'b0001, 1'b0, 1494, 7);
    cls("offset-1 word store, blank",       1'b1, 4'b0110, 1'b0, 2829, 8);
    cls("offset-1 word store, graphics line",1'b1, 4'b0110, 1'b1, 3219, 8);
    // a line read (an I-cache fill from the text RAM) is the two-word read class, by its enables:
    // its beats stream at the start, so in Xe10 the next start waits out that class's read hold -
    // the table's two-word net (docs/probes/XE10W-XE10-MIS2RUN1.TXT :405 XCR_1_V 821.8 ns, :300
    // XCR_1_A 898.1) to the nearest clk_sys, less the core CPU's 8 and the port's 2 (the
    // responder's XE10 PRICING), plus the start cycle itself. Fast: the walk's own pace exactly.
    gfx_scan_on = 1'b0; timing_xe10 = 1'b1; stream_line(px);
    fast_eq("line read, blank, Xe10", px, int'((64'(HZ) * 64'd8218 + 64'd5_000_000_000) / 64'd10_000_000_000) - 9);
    timing_xe10 = 1'b0; stream_line(pf); fast_eq("line read, blank", pf, LINE_FAST);
    gfx_scan_on = 1'b1; timing_xe10 = 1'b1; stream_line(px);
    fast_eq("line read, graphics line, Xe10", px, int'((64'(HZ) * 64'd8981 + 64'd5_000_000_000) / 64'd10_000_000_000) - 9);
    timing_xe10 = 1'b0; stream_line(pf); fast_eq("line read, graphics line", pf, LINE_FAST);
    // the CG window is never paced, whatever the table
    route_cg = 1'b1;
    gfx_scan_on = 1'b0;
    timing_xe10 = 1'b1;
    stream(1'b1, 4'b0011, px);
    fast_eq("CG window word store (Xe10 set)", px, 8);
    route_cg = 1'b0;
    timing_xe10 = 1'b0;
    done = 1'b1;
  end
endmodule

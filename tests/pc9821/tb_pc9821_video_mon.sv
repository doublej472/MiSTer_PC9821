`timescale 1ns/1ps

// tb_pc9821_video_mon - the analog-picture monitor's UART line measures the raster it is fed.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_VIDEO_MON: The VIDEO_MON_EN monitor (pc9821_video_mon) prints, for a raster of 100-clock lines with a 10-clock hsync, 50-line frames and a 3-line vsync, the line length, hsync width, lines per frame and vsync width the raster has (L0064-0064 H00A-00A F032-032 V03-03), and the vsync leading edge's offset from the last hsync leading edge as clocks since that edge: O000-000 when vsync falls on an hsync leading edge (the core's sync generators move VSYNC on the HSYNC leading edge) and O007-007 when it falls seven clocks after one; the line is decoded off the UART pin.
//
// ---- where each expectation comes from ----
// Every value is the bench's own raster, counted from the stimulus: the line, hsync, frame and
// vsync lengths it drives, and the offset by which it places the vsync fall. The O field's
// definition is the module header's ("the vsync leading edge's offset from the last hsync leading
// edge, clocks"): an edge in the same clock is 0 clocks after it.

`default_nettype none

module tb_pc9821_video_mon;
  localparam integer LINE = 100, HSW = 10, LINES = 50, VSL = 3;
  localparam integer WIN = 30_000;                 // VCLK_HZ: a window of six whole frames
  localparam integer SYS_HZ = 921_600;             // 8 clk_sys clocks per bit at 115200

  reg clk_vid = 1'b0, clk_sys = 1'b0;
  always #5 clk_vid = ~clk_vid;
  always #3.5 clk_sys = ~clk_sys;

  // two rasters: A's vsync falls on an hsync leading edge, B's seven clocks after one
  integer pos = 0;                                 // clock within the frame
  wire [15:0] col = 16'(pos % LINE);
  wire [15:0] lin = 16'(pos / LINE);
  wire hs   = !(col < HSW);
  wire vs_a = !(lin < VSL);
  wire vs_b = !((pos >= 7) && (pos < 7 + VSL * LINE));
  always @(posedge clk_vid) pos <= (pos == LINE * LINES - 1) ? 0 : pos + 1;
  wire tx_a, tx_b;

  // ==== DUT ====
  // NOT COVERED: de and fifo_ev are tied low, so the line's E (FIFO events) and D (DE) fields
  // only ever read their zero (E0000 D0000 below): a stuck or never-counting E/D counter passes
  // this bench. The claim is the L/H/F/V/O fields.
  pc9821_video_mon #(.VCLK_HZ(WIN), .SYS_HZ(SYS_HZ)) mon_a (
    .clk_vid(clk_vid), .ce(1'b1), .hs(hs), .vs(vs_a), .de(1'b0), .fifo_ev(1'b0),
    .clk_sys(clk_sys), .tx(tx_a));
  pc9821_video_mon #(.VCLK_HZ(WIN), .SYS_HZ(SYS_HZ)) mon_b (
    .clk_vid(clk_vid), .ce(1'b1), .hs(hs), .vs(vs_b), .de(1'b0), .fifo_ev(1'b0),
    .clk_sys(clk_sys), .tx(tx_b));

  // ==== STIMULUS ====
  // The UART receivers: 8 clk_sys per bit, sampled mid-bit; each collects lines up to LF.
  localparam integer BIT = SYS_HZ / 115200;
  reg [8*80-1:0] line_a [0:3];
  reg [8*80-1:0] line_b [0:3];
  integer nl_a = 0, nl_b = 0;
  task automatic rx(input integer which);
    reg [7:0] c;
    reg [8*80-1:0] cur;
    integer k;
    begin
      cur = '0;
      forever begin
        if (which == 0) @(negedge tx_a); else @(negedge tx_b);
        repeat (BIT + BIT / 2) @(posedge clk_sys);
        for (k = 0; k < 8; k = k + 1) begin
          c[k] = (which == 0) ? tx_a : tx_b;
          repeat (BIT) @(posedge clk_sys);
        end
        if (c == 8'h0A) begin
          if (which == 0) begin if (nl_a < 4) line_a[nl_a] = cur; nl_a = nl_a + 1; end
          else begin if (nl_b < 4) line_b[nl_b] = cur; nl_b = nl_b + 1; end
          cur = '0;
        end else if (c != 8'h0D) cur = {cur[8*79-1:0], c};
      end
    end
  endtask
  initial rx(0);
  initial rx(1);

  // ==== CHECKS ====
  integer errors = 0;
  function automatic [8*80-1:0] str80(input string s);
    integer i;
    begin
      str80 = '0;
      for (i = 0; i < s.len(); i = i + 1) str80 = {str80[8*79-1:0], s[i]};
    end
  endfunction
  task automatic expect_line(input string name, input [8*80-1:0] got, input string want);
    begin
      if (got !== str80(want)) begin
        errors = errors + 1;
        $display("FAIL: %0s printed \"%0s\", expected \"%0s\"", name, got, want);
      end
    end
  endtask

  initial begin
    // three windows: the first starts mid-raster (no previous edge), the second and third are whole
    wait (nl_a >= 3 && nl_b >= 3);
    expect_line("raster A (vsync on an hsync edge)", line_a[2],
                "VM L0064-0064 H00A-00A F032-032 V03-03 O000-000 N06 E0000 D0000");
    expect_line("raster B (vsync 7 clocks after an hsync edge)", line_b[2],
                "VM L0064-0064 H00A-00A F032-032 V03-03 O007-007 N06 E0000 D0000");

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_VIDEO_MON: FAIL (%0d errors)", errors);
    $display("TB_PC9821_VIDEO_MON: PASS");
    $finish;
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_VIDEO_MON: timeout, %0d / %0d lines received", nl_a, nl_b);
  end
endmodule

`default_nettype wire

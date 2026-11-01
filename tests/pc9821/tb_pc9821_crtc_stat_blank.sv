// tb_pc9821_crtc_stat_blank — GDC status bit 6 is the horizontal blank, once per line.
//
// ==== WHAT THIS PROVES ====
// GDC status bit 6 (port 0x60, mirrored by the graphics GDC's 0xA0) follows the HORIZONTAL blank of every line, vertical-blank lines included: over two whole default frames it is high for 208 of every 848 dots (24.5 %, the machine's capture reads 23.4 % against the 208/848 horizontal blank and not the ~31 % a frame-blank signal gives) and it rises once per line, 440 times a frame, where the previous model held it high for the whole 40-line vertical blank and low across every active line's active dots only.
//
// WHY. docs/probes/TIME.TXT:183 (`high 1.7% of the time and bit6 23.4%`, the machine's own GDC.TXT histogram) pins the duty at the horizontal blank, 208/848 = 24.5 %; a frame blank (~(h_active && v_active)) would read (848*440 - 640*400)/(848*440) = 31.4 %. NP2kai io/gdc.c:631-633 (`if ((remain % gdc.rasterclock) < gdc.hsyncclock) { ret |= 0x40;`) raises it once per raster line, independent of the vertical position, for both gdc_i60 and gdc_ia0. The phase inside the line is NOT measured (todo item 23); this bench pins the duty and the one-edge-per-line shape only.

`timescale 1ns / 1ps

module tb_pc9821_crtc_stat_blank;

  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;
  reg rst_n_sys = 0;

  reg        io_wr = 0;
  reg  [7:0] io_addr = 8'h60;
  reg  [7:0] io_din = 0;
  wire [7:0] io_dout;

  // ==== DUT ====
  pc9821_crtc dut (
      .crt31k(1'b0),   // 0x09A8 bit 0 clear: the 24 kHz monitor range
      .gfx_win_on(1'b0),   // no slave window here
      .clk_sys(clk_sys),
      .rst_n_sys(rst_n_sys),
      .rst_n_vid(rst_n_sys),
      .pixel_ce(1'b1),
      .io_wr(io_wr),
      .io_addr(io_addr),
      .io_din(io_din),
      .io_dout(io_dout)
  );

  integer errors = 0;
  integer total, high, rises, i, vblank_rises, vblank_high, vblank_total;
  reg prev;
  wire [9:0] vline = dut.o_vline;

  // ==== CHECKS ====
  initial begin
    repeat (4) @(negedge clk_sys);
    rst_n_sys = 1;
    // let the first frame settle, then count two whole default frames (848*440 dots each)
    repeat (848 * 440 + 100) @(negedge clk_sys);
    total = 0; high = 0; rises = 0; prev = io_dout[6];
    vblank_rises = 0; vblank_high = 0; vblank_total = 0;
    for (i = 0; i < 2 * 848 * 440; i = i + 1) begin
      @(negedge clk_sys);
      total = total + 1;
      if (io_dout[6]) high = high + 1;
      if (io_dout[6] && !prev) rises = rises + 1;
      if (vline >= 10'd410 && vline < 10'd430) begin
        vblank_total = vblank_total + 1;
        if (io_dout[6]) vblank_high = vblank_high + 1;
        if (io_dout[6] && !prev) vblank_rises = vblank_rises + 1;
      end
      prev = io_dout[6];
    end
    $display("bit6 high %0d of %0d (%0f %%), %0d rises; inside the vertical blank %0d of %0d high, %0d rises",
             high, total, (high * 100.0) / total, rises,
             vblank_high, vblank_total, vblank_rises);
    // 208/848 = 24.53 %; the frame-blank model reads 31.4 %. Accept 23..26 %.
    if (high * 100 < total * 23 || high * 100 > total * 26) begin
      $display("FAIL: bit 6 duty %0d of %0d outside 23..26 %% (the horizontal blank, 208/848)", high, total);
      errors = errors + 1;
    end
    // one rise per line: 440 per frame, 880 over two frames (+-2 for the window edges)
    if (rises < 878 || rises > 882) begin
      $display("FAIL: %0d bit-6 rises over two frames, want 880 (one per line)", rises);
      errors = errors + 1;
    end
    // vertical-blank lines (410..429, 20 lines of 848 dots) still carry the per-line pulse
    if (vblank_rises < 2 * 20 - 2) begin
      $display("FAIL: only %0d bit-6 rises inside the vertical blank, want ~40 (one per line)", vblank_rises);
      errors = errors + 1;
    end
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CRTC_STAT_BLANK: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_CRTC_STAT_BLANK: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_CRTC_STAT_BLANK: TIMEOUT");
  end
endmodule

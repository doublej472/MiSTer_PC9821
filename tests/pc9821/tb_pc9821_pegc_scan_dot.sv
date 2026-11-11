`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PEGC_SCAN_DOT: the packed 256-colour dot path, sampled the way the FRAMEWORK samples it, must put the byte of line offset x on dot x - one packed byte per dot, byte 0 leftmost, NP2kai's own mapping (`vramex + vc*8 + 0..7` lands at the surface row's bytes 0..7 in order, vram/makegrex.c) and the identity this core's planar path already has (its fold takes bit 7-dot of the column's plane byte). The REAL pc9821_pegc_scan and the REAL pc9821_video_mixer run over a machine raster (848-dot lines, the 21.0526 MHz dot enable, h_active = the first 640 dots), the line store's byte k is k & 0xFF so every fetched byte names its own line offset, the palette is loaded with entry v -> {v,v,v} so the sampled red byte IS the index the dot carried, and the sampler latches at sys/scanlines.v's rule (at the pixel enable, the value present during the cycle the enable ends); the run asserts 640 of 640 active dots correct and cannot pass silently (a window that sampled fewer than 600 FAILS). FAIL-FIRST: the 256-colour palette read is REGISTERED (the async form is refused by every block type, measured at 2,264 ALMs), so the pixel's index must be on the palette's input one clk before the sample - and because a dword covers four dots, the dword address must be presented one clk EARLY at every 4-dot group boundary or the group's first cycle still holds the previous group's dword: every dot that OPENS a group then displayed the byte FOUR DOTS to the left, measured at 160 of a line's 640 dots (dots 0, 4, 8, ...: 0->byte 4, 4->byte 0, 8->byte 4) before the fix and 0 after, with the blank->display boundary (the line's first active dot) its second instance.

`default_nettype none

module tb_pc9821_pegc_scan_dot;

  reg clk = 0;
  always #10 clk = ~clk;      // 50 MHz, the core's clk_sys
  reg reset = 1;

  // The core's pixel enable: round(PIXEL_HZ * 2^24 / SYS_FREQ) as pc9821_system computes
  // it (PIXEL_HZ 21.0526 MHz from a 50 MHz clk_sys), so the dot lengths here are the
  // machine's - 2 or 3 clk, in the pattern the real accumulator produces.
  localparam [23:0] PIXEL_CE_INC = 24'd7064080;
  reg  [23:0] ce_acc = 24'd0;
  wire [24:0] ce_sum = {1'b0, ce_acc} + PIXEL_CE_INC;
  wire        pixel_ce = ce_sum[24];
  always @(posedge clk) begin
    if (reset) ce_acc <= 24'd0;
    else       ce_acc <= ce_sum[23:0];
  end

  // The raster's dot counter, exactly as pc9821_crtc builds it: one dot per pixel enable,
  // HTOTAL per line, h_active for the first HACTIVE of them (pc9821_crtc.sv's
  // `h_active = (hdot < HACTIVE)`, with pix_dot = hdot). The machine's power-on SYNC block
  // is 848x440 / 640x400 (pc9821_video_mixer's header), and the enable's phase against the
  // dot boundaries is what this bench is about, so both counters take the same enable.
  localparam integer HTOTAL = 848;
  localparam integer HACTIVE = 640;
  reg [9:0] hdot = 10'd0;
  wire      h_active = (hdot < HACTIVE);
  always @(posedge clk) begin
    if (reset)         hdot <= 10'd0;
    else if (pixel_ce) hdot <= (hdot == (HTOTAL - 1)) ? 10'd0 : (hdot + 10'd1);
  end

  // ==== DUT ====
  // The packed scan on the same port-3 contract the subsystem wires it to. The line
  // store under it is a behavioural stand-in for the SDRAM fetch (whose burst order and
  // content are tb_pc9821_pegc_scanout's subject, not this bench's): every byte of the
  // line is its own offset, so the byte a dot displays names the dot it came from.
  localparam [31:0] PEG_BASE = 32'h0200_0000;
  reg  [31:0] line_mem [0:159];
  integer     m;
  // Each lane is masked to its own byte: an unmasked 32-bit term in the concatenation
  // keeps only the last one (the bench's own trap - it served 0x00000004 for dword 1).
  function automatic [31:0] ramp_dword(input integer d);
    begin
      ramp_dword = {8'((d*4 + 3) & 255), 8'((d*4 + 2) & 255),
                    8'((d*4 + 1) & 255), 8'((d*4 + 0) & 255)};
    end
  endfunction
  initial for (m = 0; m < 160; m = m + 1) line_mem[m] = ramp_dword(m);

  reg         scan_enable = 1'b1;
  reg         scan_line_tick = 1'b0;
  reg         scan_page = 1'b0, page_force_zero = 1'b0;
  reg  [14:0] scan_line_base = 15'd0;
  wire  [7:0] packed_idx;
  wire        peg_line_sel, peg_line_ready;
  wire [31:0] p_addr, p_din;
  wire  [3:0] p_be;
  wire  [7:0] p_burst;
  wire        p_valid, p_write, p_ready, p_resp_valid;
  wire [31:0] p_dout;

  // The mixer's read address, exactly as pc9821_video_mixer drives it:
  // `line_rd_addr = h_active ? dot_x[9:3] : 0`, `line_rd_sel = line_sel`.
  wire  [6:0] rd_col = h_active ? hdot[9:3] : 7'd0;

  pc9821_pegc_scan dut (
      .clk(clk), .reset(reset),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .page_force_zero(page_force_zero),
      .scan_walk_page(1'b0),
      .scan_line_base(scan_line_base),
      .line_rd_addr(rd_col), .line_rd_sel(peg_line_sel),
      .dot_in_col(hdot[2:0]), .dot_ce(pixel_ce), .line_rd_act(h_active),
      .packed_idx(packed_idx), .line_sel(peg_line_sel), .line_ready(peg_line_ready),
      .peg_base(PEG_BASE),
      .mem_addr(p_addr), .mem_valid(p_valid), .mem_write(p_write),
      .mem_be(p_be), .mem_burstcount(p_burst), .mem_din(p_din),
      .mem_ready(p_ready), .mem_dout(p_dout), .mem_resp_valid(p_resp_valid)
  );

  // The line store's READ side: one accept, then one response per beat of the burst.
  reg        ld_busy = 1'b0;
  reg  [8:0] ld_left = 9'd0;
  reg  [8:0] ld_w = 9'd0;
  always @(posedge clk) begin
    if (reset) begin
      ld_busy <= 1'b0; ld_left <= 9'd0; ld_w <= 9'd0;
    end else begin
      if (!ld_busy && p_valid && p_ready) begin
        ld_busy <= 1'b1;
        ld_left <= {1'b0, p_burst};
        ld_w    <= (p_addr - PEG_BASE) >> 2;
      end else if (ld_busy) begin
        ld_w <= ld_w + 9'd1;
        if (ld_left == 9'd1) ld_busy <= 1'b0;
        ld_left <= ld_left - 9'd1;
      end
    end
  end
  assign p_ready      = !ld_busy;
  assign p_resp_valid = ld_busy;
  assign p_dout       = line_mem[ld_w[7:0]];

  // ==== THE MIXER, on its packed arm ====
  // The real pc9821_video_mixer, so the 256-colour palette's REGISTERED read (the whole
  // point of this bench) is in the path. Its table is written to entry v -> {v,v,v}, so
  // the sampled red byte IS the palette index the dot carried.
  wire [7:0]  r_out, g_out, b_out;
  reg  [7:0]  p256_widx = 8'd0;
  reg  [1:0]  p256_wchan = 2'd0;
  reg  [7:0]  p256_wdata = 8'd0;
  reg         p256_we = 1'b0;

  pc9821_video_mixer u_mix (
      .clk(clk),
      .dot_x(hdot), .h_active(h_active), .v_active(1'b1),
      .text_opaque(1'b0), .text_cell(1'b0), .text_colour(12'h000),
      .line_data(32'h0000_0000), .line_ready(peg_line_ready), .line_sel(peg_line_sel),
      .line_rd_addr(), .line_rd_sel(),
      .pal_mode16(1'b1), .pal_dig(32'h0000_0000),
      .pal_wr_en(1'b0), .pal_wr_idx(4'd0), .pal_wr_chan(2'd0), .pal_wr_data(4'd0),
      .pegc_256(1'b1), .fold_bypass(1'b1), .packed_idx(packed_idx),
      .pal256_wr_en(p256_we), .pal256_wr_idx(p256_widx),
      .pal256_wr_chan(p256_wchan), .pal256_wr_data(p256_wdata),
      .comp_rule(2'b00), .grph_disp(1'b1),
      .gfx_odd_line(1'b0),
      .r_out(r_out), .g_out(g_out), .b_out(b_out)
  );

  integer errors = 0;

  // Bound: a bench that never finishes is a FAIL, not a stall.
  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_PEGC_SCAN_DOT: FAIL watchdog (the run did not finish)");
  end

  // The framework's own latch rule (sys/scanlines.v: `always @(posedge clk) if (ce_in)`):
  // at the pixel enable, capture the value present during the cycle the enable ends, and
  // the dot the counter is on during that same cycle.
  reg [7:0]  samp_r = 8'd0;
  reg [9:0]  samp_dot = 10'd0;
  reg        samp_hit = 1'b0;
  reg        samp_arm = 1'b0;
  always @(posedge clk) begin
    if (reset) begin
      samp_hit <= 1'b0;
    end else if (pixel_ce) begin
      samp_r   <= r_out;
      samp_dot <= hdot;
      samp_hit <= samp_arm;
    end else samp_hit <= 1'b0;
  end

  // ==== CHECKS ====
  // The byte of line offset x is the pixel for dot x (NP2kai's mapping: `vramex + vc*8 +
  // 0..7` lands at the surface row's bytes 0..7 in order, byte 0 leftmost), and the ramp
  // makes that byte's VALUE x itself - so the palette index the mixer presents on dot x
  // must be x's low byte, and any shift or reorder shows up as a value that names a
  // different offset. Sampling the whole active window also proves the window was driven:
  // a bench that samples nothing cannot pass.
  integer bad = 0;
  integer first_bad_dot = -1;
  integer samples = 0;
  integer shown = 0;

  always @(posedge clk) begin
    if (!reset && samp_hit && (samp_dot < HACTIVE)) begin
      samples = samples + 1;
      if (samp_r !== samp_dot[7:0]) begin
        bad = bad + 1;
        if (first_bad_dot < 0) first_bad_dot = samp_dot;
        if (shown < 6) begin
          $display("  dot %0d: the palette index presented is %0d (line byte %0d), want %0d",
                   samp_dot, samp_r, samp_r, samp_dot[7:0]);
          shown = shown + 1;
        end
      end
    end
  end

  // ==== STIMULUS ====
  integer k;
  integer guard;
  initial begin
    // The 256-colour table: entry v -> {R,G,B} = {v,v,v} (chan 0 = G, 1 = R, 2 = B, the
    // mixer's own channel order), so the sampled red byte IS the index the dot carried.
    reset = 1'b1;
    @(negedge clk);
    reset = 1'b0;
    repeat (4) @(posedge clk);
    for (k = 0; k < 256; k = k + 1) begin
      p256_widx = 8'(k);
      p256_wchan = 2'd1; p256_wdata = 8'(k); p256_we = 1'b1;   // R
      @(negedge clk);
      p256_wchan = 2'd0;                                       // G
      @(negedge clk);
      p256_wchan = 2'd2;                                       // B
      @(negedge clk);
    end
    p256_we = 1'b0;

    // Two line ticks: the first starts the fetch, the second swaps the ping-pong so the
    // fetched (ramp) line is the displayed one.
    @(negedge clk);
    scan_line_tick = 1'b1;
    @(negedge clk);
    scan_line_tick = 1'b0;
    guard = 0;
    while (!peg_line_ready && guard < 4000) begin @(negedge clk); guard = guard + 1; end
    if (!peg_line_ready) $fatal(1, "TB_PC9821_PEGC_SCAN_DOT: the fetch never completed");
    @(negedge clk);
    scan_line_tick = 1'b1;
    @(negedge clk);
    scan_line_tick = 1'b0;

    // Sample one whole raster line's active dots: wait for the line start (hdot 0), arm the
    // sampler, and hold it until the counter comes back round.
    guard = 0;
    while ((hdot != 10'd0) && guard < 9000) begin @(negedge clk); guard = guard + 1; end
    @(negedge clk);
    samp_arm = 1'b1;
    guard = 0;
    do begin @(negedge clk); guard = guard + 1; end while ((hdot != 10'd0) && guard < 9000);
    samp_arm = 1'b0;
    repeat (4) @(negedge clk);

    // ==== VERDICT ====
    $display("MEASURED packed dot phase: %0d active dots sampled, %0d wrong (first at dot %0d)",
             samples, bad, first_bad_dot);
    if (samples < 600) begin
      $display("FAIL dot phase: only %0d of the line's 640 active dots were sampled", samples);
      $fatal(1, "TB_PC9821_PEGC_SCAN_DOT: FAIL (the sampling window did not run)");
    end
    if (bad != 0) begin
      $display("FAIL dot phase: %0d of %0d active dots carry the wrong line byte -- the packed byte for dot x must be the line's byte x (byte 0 leftmost)",
               bad, samples);
      $fatal(1, "TB_PC9821_PEGC_SCAN_DOT: FAIL (%0d bad dots)", bad);
    end
    $display("TB_PC9821_PEGC_SCAN_DOT: PASS");
    $finish;
  end

endmodule

`default_nettype wire

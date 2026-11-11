`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_VIDEO_SCANOUT:
// A line painted into the plane windows is scanned out as the pixels the raster asks for, at the machine's pixel-enable timing: the REAL pc9821_gvram fetch and its REGISTERED line buffer drive the REAL pc9821_video_mixer, so the read's one-clk latency and the mixer's column sequencer are both in the path, and every active dot's colour must be the fold of the column that dot belongs to -- dot d of column c is bit 7-d of that column's plane bytes -- for all 80 columns and all 8 dots; the sequencer this pins used to prefetch column c+1 on column c's last dot, which served the eighth dot of every column from the NEXT column's word, a static error every 8 pixels that no bench with a combinational line buffer can see.
//
// The two modules are wired exactly as pc9821_system.sv wires them: the mixer owns
// the read address and the buffer select, and the gvram answers line_data from the
// displayed buffer one clk later. This is the seam neither module's own bench covers:
// tb_pc9821_gvram reads line_data with a hand-held address, and tb_pc9821_video_mixer
// drives a combinational line buffer with no read latency at all.

`default_nettype none

module tb_pc9821_video_scanout;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // The system's own pixel enable: 21.0526 MHz from a 50 MHz clk (pc9821_system.sv).
  localparam [23:0] PIXEL_CE_INC = 24'd7063303;
  reg  [23:0] ce_acc = 24'd0;
  wire [24:0] ce_sum = {1'b0, ce_acc} + PIXEL_CE_INC;
  wire        pixel_ce = ce_sum[24];
  always @(posedge clk) begin
    if (reset) ce_acc <= 24'd0;
    else       ce_acc <= ce_sum[23:0];
  end

  // The raster view the mixer is wired to (pc9821_gdc_text's hdot/vline).
  localparam HTOTAL = 848, HACTIVE = 640, VTOTAL = 440, VACTIVE = 400;
  reg [9:0] hdot  = 10'd0;
  reg [8:0] vline = 9'd0;
  reg       rst_raster = 1'b1;
  wire h_active = (hdot < HACTIVE);
  wire v_active = (vline < VACTIVE);
  always @(posedge clk) begin
    if (rst_raster) begin
      hdot  <= 10'd0;
      vline <= 9'd0;
    end else if (pixel_ce) begin
      if (hdot == HTOTAL - 1) begin
        hdot  <= 10'd0;
        vline <= (vline == VTOTAL - 1) ? 9'd0 : vline + 9'd1;
      end else hdot <= hdot + 10'd1;
    end
  end

  // ==== DUT ====
  // The scanout: the four planes and their per-line fetch into the ping-pong line buffer.
  reg  [1:0]  win_plane = 2'd0;
  reg  [14:0] win_offset = 15'd0;
  reg  [31:0] cpu_din = 32'd0;
  reg  [3:0]  cpu_be = 4'hF;
  reg         cpu_line_read = 1'b0, cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0]  cpu_dout;
  wire [31:0] cpu_line_word;
  wire         cpu_ready, cpu_resp_valid, cpu_line_word_valid;
  reg         grcg_we = 1'b0;
  reg  [7:0]  grcg_addr = 8'd0, grcg_din = 8'd0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;
  wire [6:0]  line_rd_addr;
  wire        line_rd_sel;

  localparam [31:0] GVRAM_BASE = 32'h0300_0000;
  // The GVRAM's two SDRAM requesters and the shared store behind them.

  pc9821_gvram_dut u_gvram (
      .clk(clk), .reset(reset),
      .access_page(1'b0),
      .win_plane(win_plane), .win_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .egc_gate(1'b0), .egc_access(16'hFFFF), .egc_fgbg(16'd0), .egc_ope(16'd0),
      .egc_fg(16'd0), .egc_mask(16'hFFFF), .egc_bg(16'd0),
      .egc_sft(16'd0), .egc_leng(16'd0), .egc_shift_we(1'b0),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));

  

  reg        scan_enable    = 1'b0;
  reg        scan_line_tick = 1'b0;
  reg        scan_page      = 1'b0;
  reg [14:0] scan_line_base = 15'd0;

  // The pixel pipeline: fold -> graphics palette -> compositor. Only the graphics
  // arm is exercised, and the analogue table
  // is loaded through its write port so the index is readable off
  // r_out: entry k carries k in its red nibble, so r_out = {k,k}.
  reg         pal_we = 1'b0;
  reg  [3:0]  pal_widx = 4'd0;
  reg  [1:0]  pal_wchan = 2'd0;
  reg  [3:0]  pal_wdata = 4'd0;
  wire [7:0]  r_out, g_out, b_out;
  // The PEGC arm's inputs (pegc-scope-REPORT.md 4 row 4): tied off in the
  // 16-colour benches; tb_pc9821_video_mixer drives them.
  reg        mix_pegc_256 = 1'b0;
  reg        mix_pal256_wr_en = 1'b0;
  reg  [7:0] mix_pal256_wr_idx = 8'd0, mix_pal256_wr_data = 8'd0;
  reg  [1:0] mix_pal256_wr_chan = 2'd0;
  pc9821_video_mixer u_mixer (
      .clk(clk),
      .dot_x(hdot), .h_active(h_active), .v_active(v_active),
      .text_opaque(1'b0), .text_cell(1'b0), .text_colour(12'h000),
      .line_data(line_data), .line_ready(line_ready), .line_sel(line_sel),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .pal_mode16(1'b1), .pal_dig(32'd0),
      .pal_wr_en(pal_we), .pal_wr_idx(pal_widx), .pal_wr_chan(pal_wchan),
      .pal_wr_data(pal_wdata),
      .fold_bypass(1'b0), .packed_idx(8'h00),
    .pegc_256(mix_pegc_256),
    .pal256_wr_en(mix_pal256_wr_en), .pal256_wr_idx(mix_pal256_wr_idx),
    .pal256_wr_chan(mix_pal256_wr_chan), .pal256_wr_data(mix_pal256_wr_data),
      .comp_rule(2'b00), .grph_disp(1'b1),
      .r_out(r_out), .g_out(g_out), .b_out(b_out)
  );

  // Load entry k's red nibble with k through the table's write port: r_out[7:4] then
  // reads the 4-bit index, which is what the raster checks.
  task automatic load_red_table;
    integer t;
    begin
      for (t = 0; t < 16; t = t + 1) begin
        @(negedge clk);
        pal_we = 1'b1; pal_wchan = 2'd1; pal_widx = t[3:0]; pal_wdata = t[3:0];
        @(negedge clk);
        pal_we = 1'b0;
      end
      @(negedge clk);
    end
  endtask

  // ==== STIMULUS ====
  integer errors = 0;

  task automatic fail(input [8*160-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  // A CPU store through a plane window: the plane index and the byte offset
  // inside the plane, exactly what pc9821_memory_map emits.
  task automatic cpu_store(input [1:0] plane, input [14:0] off,
                           input [31:0] data, input [3:0] be);
    begin
      @(negedge clk);
      win_plane  = plane;
      win_offset = off;
      cpu_din    = data;
      cpu_be     = be;
      cpu_write  = 1'b1;
      cpu_valid  = 1'b1;
      @(posedge clk);
      #1;
      while (!cpu_ready) begin
        @(posedge clk);
        #1;
      end
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_write = 1'b0;
      cpu_be    = 4'hF;
      repeat (4) @(posedge clk);
    end
  endtask

  // One plane's byte at one column, byte position and enable taken from the
  // column's own low bits (the datapath's index is {win_offset[14:2], lane}).
  task automatic put_byte(input [1:0] plane, input [14:0] off, input [7:0] val);
    begin
      cpu_store(plane, off, {24'd0, val} << (off[1:0] * 8), 4'b0001 << off[1:0]);
    end
  endtask

  task automatic line_tick(input [14:0] base);
    begin
      scan_line_base = base;
      @(negedge clk);
      scan_line_tick = 1'b1;
      @(negedge clk);
      scan_line_tick = 1'b0;
    end
  endtask

  integer n;

  // The pixel the raster presents for the current hdot, sampled at the pixel
  // enable exactly as the framework samples r_out/g_out/b_out.
  reg        armed = 1'b0;
  integer    seen  = 0;
  task automatic sample_and_check;
    integer c, d;
    begin
      c = hdot[9:3];
      d = hdot[2:0];
      // The line at base 0x2000 carries B byte = column index, R/G/E zero, so the
      // index at dot d of column c is bit (7-d) of c.
      if (r_out[7:4] !== {3'd0, (c[7:0] >> (7 - d)) & 8'd1}) begin
        $display("FAIL column %0d dot %0d: pixel index %0d, the column's word says %0d",
                 c, d, r_out[7:4], (c >> (7 - d)) & 1);
        errors = errors + 1;
      end
      seen = seen + 1;
    end
  endtask

  // ==== CHECKS ====
  initial begin
    // 1. Paint the displayed line's blue bytes at plane offset 0x2000, one per column.
    repeat (4) @(posedge clk);
    reset <= 1'b0;
    repeat (4) @(posedge clk);
    load_red_table;
    for (n = 0; n < 80; n = n + 1)
      put_byte(2'd0, 15'h2000 + n[14:0], n[7:0]);

    // 2. Fetch it into the ping-pong buffer, then move it into the DISPLAYED
    //    buffer: the line presented at a tick is displayed after the NEXT one.
    scan_enable = 1'b1;
    line_tick(15'h2000);
    for (n = 0; n < 2000 && !line_ready; n = n + 1) @(posedge clk);
    if (!line_ready) fail("the 0x2000 line never completed its fetch");
    line_tick(15'h2100);
    for (n = 0; n < 2000 && !line_ready; n = n + 1) @(posedge clk);
    if (!line_ready) fail("the displayed line never became ready");

    // 3. Run one raster line and fold every dot against the column that owns it.
    rst_raster <= 1'b1;
    repeat (3) @(posedge clk);
    rst_raster <= 1'b0;
    armed <= 1'b1;
    while (seen < HACTIVE) @(posedge clk);
    armed <= 1'b0;
    if (seen != HACTIVE)
      fail("the line did not present exactly 640 active dots");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_VIDEO_SCANOUT: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_VIDEO_SCANOUT: FAIL (%0d errors)", errors);
  end

  // The pixel enable is exactly this: the framework latches r_out on the clk edge
  // where pixel_ce is high, and hdot is still the edge's PRE-increment value.
  always @(posedge clk)
    if (!rst_raster && armed && pixel_ce && h_active && v_active)
      sample_and_check;

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_VIDEO_SCANOUT: TIMEOUT");
  end

endmodule

`default_nettype wire

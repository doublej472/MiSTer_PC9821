`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_VIDEO_FRAME:
// The frame-start line origin: with the REAL pc9821_gdc_text driving the line origin and the REAL one-pulse-per-line tick (pc9821_system's gvram_h_count) into the REAL pc9821_gvram ping-pong, and every plane word painted with its picture-line number, the line displayed at raster line k is picture line k for every one of the 400 active lines -- raster line 0 is picture line 0 and not the vertical-blanking origin the un-compensated origin decode latched two raster lines late. The line-buffer fetch delivers a line two raster lines after the tick that requested it (pc9821_gvram), so an origin decoded from the CURRENT raster line draws the blanking origins of the frame's last two lines across the top; this bench is that edge case, and it fails on the tree before the +2 compensation and passes after it (fail-first measured on the pre-fix tree).

`default_nettype none

module tb_pc9821_video_frame;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // The system's pixel enable: 21.0526 MHz from a 50 MHz clk (pc9821_system.sv).
  localparam [23:0] PIXEL_CE_INC = 24'd7063303;
  reg  [23:0] ce_acc = 24'd0;
  wire [24:0] ce_sum = {1'b0, ce_acc} + PIXEL_CE_INC;
  wire        pixel_ce = ce_sum[24];
  always @(posedge clk) begin
    if (reset) ce_acc <= 24'd0;
    else       ce_acc <= ce_sum[23:0];
  end

  localparam VTOTAL = 440, VACTIVE = 400;
  localparam [8:0] LINES = 9'd400;

  // ==== DUT ====
  // The raster GDC, clocked exactly as pc9821_system clocks it: clk_vid = clk_sys gated
  // by the pixel enable (pc9821_system.sv:1240, `The video domain is clk_sys gated by pixel_ce`). It owns the raster and the
  // line origin (gfx_line_addr); every signal below is declared because the (.*) instance
  // matches ports by name, the same shape tb_pc9821_gdc2_scroll.sv uses.
  wire clk_sys    = clk;
  wire clk_vid    = clk;
  wire clk_vid_ce = pixel_ce;
  wire rst_n_sys  = ~reset;
  wire rst_n_vid  = ~reset;
  reg  io_wr = 0, io_rd = 0;
  reg  [7:0] io_addr = 0, io_din = 0;
  wire [7:0] io_dout;
  wire gfx_access_page;
  wire [15:0] gfx_line_addr;
  wire        gfx_walk_page;   // the packed walk's page bit; parked here so (.*) stays complete
  reg  [13:0] tram_cpu_addr = 0;
  reg  [ 7:0] tram_cpu_din = 0;
  reg         tram_cpu_we = 0;
  wire [ 7:0] tram_cpu_dout;
  reg  [17:0] font_ld_addr = 0;
  reg  [15:0] font_ld_data = 0;
  reg         font_ld_we = 0;
  wire  [4:0] cg_win_byte_sel = 5'd0;
  wire        cg_win_rd = 1'b0;
  wire  [7:0] cg_win_dout;
  wire  [7:0] cg_win_din = 8'h00;
  wire        cg_win_we = 1'b0;
  wire [18:0] font_req_addr;
  wire        font_req;
  wire        font_word_valid = 1'b0;
  wire [31:0] font_word_data = 32'h0;
  reg         cg_record_restore = 0;
  reg [3:0] bios_set = 4'd0;   // the record's model field: 0 = Xe10 (entry 0)
  wire        vsync_active;
  reg         vsync_irq_arm = 0;
  wire        vsync_irq;
  wire        vsync_edge;   // the frame boundary the vblank IRQ rises on; parked for (.*)
  wire        disp_on;
  wire        gfx_disp;
  wire        gfx_egc_gate;
  wire  [6:0] cfg_ram_mib = 7'd0;
  wire        cfg_seed_en = 1'b0;
  wire        cfg_seed_reload = 1'b0;
  wire [15:0] dbg_sad;
  wire  [7:0] dbg_pitch;
  wire        dbg_col40, dbg_disp;
  wire [15:0] dbg_wk_skips;   // the walker's skipped-walk counter
  wire        text_opaque, text_cell;
  wire [11:0] text_colour;
  wire  [9:0] pix_dot;
  wire        pix_h_active, pix_v_active;
  wire        gfx_mode16;
  wire [31:0] gfx_dig;
  // The analogue palette table's CPU write port (pc9821_gfx_palette's MLAB).
  wire        pal_wr_en;
  wire [3:0]  pal_wr_idx;
  wire [1:0]  pal_wr_chan;
  wire [3:0]  pal_wr_data;
  wire        hs_out, vs_out, de_out;

  // Mirrors pc9821_system.sv: any write to port 0x64 arms the VSYNC IRQ latch.
  always @* vsync_irq_arm = io_wr && (io_addr == 8'h64);

  wire cg_rd_hold, cg_win_byte_hold;
  // Parked: the 200-line interleave's odd-line output (pc9821_crtc's seam; this bench
  // does not check it - tb_pc9821_interleave_200 does).
  wire gfx_odd_line;
  // The ONE OSD hardware-switch field, as a LIST POSITION at ENTRY 0 - the measured
  // machine's own boot/FDD nibble (0x00). pc9821_crtc decodes and latches it and seeds its
  // TRAM tail at machine reset; it is declared so the wildcard `.*` instance below connects
  // it rather than leaving the port at zero. The base memory is hardcoded to 640 KB inside
  // pc9821_crtc.
  reg [2:0] cfg_fdd_mode = 3'd0;

  pc9821_gdc_text_dut u_gdc (.*);

  // ---- the line tick, as pc9821_system.sv builds it (one clk_sys pulse at the last
  //      dot of the line, from a counter clocked by the pixel enable) ----
  reg  [9:0] gvram_h_count;
  reg        gvram_h_last;
  wire       gvram_at_last = (gvram_h_count == 10'd847);
  always @(posedge clk) begin
    if (reset) begin
      gvram_h_count <= 10'd0;
      gvram_h_last  <= 1'b0;
    end else begin
      gvram_h_last <= gvram_at_last;
      if (pixel_ce) gvram_h_count <= gvram_at_last ? 10'd0 : gvram_h_count + 10'd1;
    end
  end
  wire scan_line_tick = gvram_at_last & ~gvram_h_last;

  // ---- the scanout: the four planes and their per-line fetch into the ping-pong line
  //      buffer, wired to the raster exactly as pc9821_system.sv wires them ----
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
      .scan_enable(gfx_disp), .scan_line_tick(scan_line_tick),
      .scan_page(gfx_line_addr[15]), .scan_line_base(gfx_line_addr[14:0]),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));

  

  // The pixel pipeline's read side: the mixer owns the column address and the buffer
  // select, exactly as pc9821_system wires it. Only the graphics arm is exercised.
  wire [7:0] r_out, g_out, b_out;
  // The PEGC arm's inputs (pegc-scope-REPORT.md 4 row 4): tied off in the
  // 16-colour benches; tb_pc9821_video_mixer drives them.
  reg        mix_pegc_256 = 1'b0;
  reg        mix_pal256_wr_en = 1'b0;
  reg  [7:0] mix_pal256_wr_idx = 8'd0, mix_pal256_wr_data = 8'd0;
  reg  [1:0] mix_pal256_wr_chan = 2'd0;
  pc9821_video_mixer u_mixer (
      .dot_x(pix_dot), .h_active(pix_h_active), .v_active(pix_v_active),
      .text_opaque(text_opaque), .text_cell(text_cell), .text_colour(text_colour),
      .line_data(line_data), .line_ready(line_ready), .line_sel(line_sel),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .clk(clk),
      .pal_mode16(gfx_mode16), .pal_dig(gfx_dig),
      .pal_wr_en(1'b0), .pal_wr_idx(4'd0), .pal_wr_chan(2'd0), .pal_wr_data(4'd0),
      .fold_bypass(1'b0), .packed_idx(8'h00),
    .pegc_256(mix_pegc_256),
    .pal256_wr_en(mix_pal256_wr_en), .pal256_wr_idx(mix_pal256_wr_idx),
    .pal256_wr_chan(mix_pal256_wr_chan), .pal256_wr_data(mix_pal256_wr_data),
      .comp_rule(2'b00), .grph_disp(gfx_disp),
      .r_out(r_out), .g_out(g_out), .b_out(b_out)
  );

  // ==== STIMULUS ====
  integer errors = 0;

  task automatic fail(input [8*160-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = portnum;
      io_din  = data;
      io_wr   = 1'b1;
      @(negedge clk);
      io_wr   = 1'b0;
    end
  endtask

  // A CPU store through a plane window: the plane index and the byte offset inside the
  // plane, exactly what pc9821_memory_map emits.
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

  // One plane's byte at one word offset, byte position and enable taken from the
  // offset's own low bits (the datapath's index is {win_offset[14:2], lane}).
  task automatic put_byte(input [1:0] plane, input [14:0] off, input [7:0] val);
    begin
      cpu_store(plane, off, {24'd0, val} << (off[1:0] * 8), 4'b0001 << off[1:0]);
    end
  endtask

  // Paint picture line L into every column of its 80-word line so ANY word the fetch
  // reads names its own picture line: the column word is {E=0, G=0, R=L[8], B=L[7:0]},
  // which for L < 400 IS the number L. base(L) = L*80 words (SCROLL partition 1 at 0
  // and 400 lines: g_start1 = 0, off1 = L*GDC2_ROW_BYTES = L*80).
  task automatic paint_line(input integer L);
    integer c;
    reg [14:0] off;
    begin
      for (c = 0; c < 80; c = c + 1) begin
        off = (L * 80 + c);
        put_byte(2'd0, off, L[7:0]);        // B lane: the low byte
        put_byte(2'd1, off, {7'd0, L[8]});  // R lane: bit 8
      end
    end
  endtask

  integer k, obs, shown;

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    reset <= 1'b0;
    repeat (4) @(posedge clk);

    // 1. The raster configuration the games run the graphics display in: BCTRL on,
    //    640x400 analogue (mode1[4] = 0, the 200-line flag clear), graphics display on.
    write_io(8'h62, 8'h0D);
    write_io(8'h68, 8'h08);
    write_io(8'h6A, 8'h01);
    write_io(8'hA2, 8'h0D);   // GDC2 START: gfx_disp, the scanout's scan_enable

    // 2. SCROLL: partition 1 start 0 words, 400 lines; partition 2 zero (never taken).
    //    This makes base(L) = L*80 words, the picture's own line order.
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00);   // dp1sta low
    write_io(8'hA0, 8'h00);   // dp1sta high -> display start 0
    write_io(8'hA0, 8'h00);   // dp1lin low
    write_io(8'hA0, 8'h19);   // dp1lin high -> 400 lines
    write_io(8'hA0, 8'h00);   // dp2sta low
    write_io(8'hA0, 8'h00);   // dp2sta high
    write_io(8'hA0, 8'h00);   // dp2lin low
    write_io(8'hA0, 8'h00);   // dp2lin high -> 0 lines (partition 2 disabled)

    // 3. Paint every picture line, every column, with its own line number.
    for (k = 0; k < 400; k = k + 1)
      paint_line(k);

    // 4. Let the pipeline fill and the ping-pong settle over two frames, then check a
    //    whole frame: the line displayed at raster line k must be picture line k.
    //    The boundary is the raster's own frame_end, NOT a frame_cnt change: frame_cnt is the
    //    character blink's count and advances once per CSRFORM `timing` frames,
    //    so it is no longer a frame counter (it can hold for more than one
    //    clk here, pixel_ce is not 1:1).
    while (u_gdc.u_crtc.frame_end) @(negedge clk);
    while (!u_gdc.u_crtc.frame_end) @(negedge clk);
    while (u_gdc.u_crtc.frame_end) @(negedge clk);
    while (!u_gdc.u_crtc.frame_end) @(negedge clk);
    wait (u_gdc.u_crtc.vline == 9'd0);
    shown = 0;
    for (k = 0; k < VACTIVE; k = k + 1) begin
      wait (u_gdc.u_crtc.vline == k[8:0]);
      wait (u_gdc.u_crtc.hdot == 10'd0);
      @(negedge clk);
      // line_data is the displayed buffer's column-0 word {E,G,R,B}; the paint makes
      // that word equal the picture line it belongs to, so the whole word IS k.
      obs = line_data;
      if (obs !== k) begin
        if (shown < 8)
          $display("FAIL raster line %0d col 0: got picture line %0d, want %0d",
                   k, obs, k);
        errors = errors + 1;
        shown = shown + 1;
      end
    end
    if (shown > 8)
      $display("  (%0d lines wrong in total)", shown);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_VIDEO_FRAME: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_VIDEO_FRAME: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog. The paint is ~64000 plane stores and the two settling frames are
  // 2 x 848 x 440 dots, so ~2.5 M cycles of work; 200 ms is ~20 M cycles, 8x headroom.
  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_VIDEO_FRAME: TIMEOUT");
  end

endmodule

`default_nettype wire

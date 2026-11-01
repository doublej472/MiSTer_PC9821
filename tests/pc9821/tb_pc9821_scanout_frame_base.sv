`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The scanout's frame-boundary line bases: a SCROLL write mid-vblank (the machine's own shape - the games write SCROLL under a VSYNC wait at vline 407-419) must move the DISPLAYED raster rows 0, 1 AND 2 of the coming frame together, byte-exact, through the REAL pc9821_gdc_text_dut line origin + the REAL pc9821_gvram ping-pong fetch + the REAL pc9821_video_mixer read port (every GVRAM word carries its own plane offset, so a displayed word names the row it was fetched from). The frame-boundary configuration snapshot (cfg_snap) copies the SCROLL block at the last dot of line 439, but the +2 fetch pipeline latches row 0's base at the line-438 tick and row 1's at the line-439 tick - a full line and 1-2 clk_sys BEFORE that copy - so a decode reading the DISPLAY registers shows the PREVIOUS frame's scroll on exactly those two rows, every frame while the game scrolls: a two-pixel band at the top of the tile background displaced by the per-frame scroll delta. tb_pc9821_gdc2_scroll cannot see it: it samples the decode a frame after the write, when the copy has already landed. Case 2 is the 640x200 shape - the slave CSRFORM line repeat and a SCROLL in the same vblank - where rows 0-1 are one GDC line doubled and must use BOTH the new line repeat and the new start.
//
// The scanout's frame-boundary line bases: a SCROLL write mid-vblank (the machine's own
// shape - the games write SCROLL under a VSYNC wait, landing at vline 407-419) must move
// displayed raster rows 0, 1 AND 2 of the coming frame TOGETHER, byte-exact, through the
// REAL pc9821_gdc_text_dut line origin + the REAL pc9821_gvram ping-pong fetch + the REAL
// pc9821_video_mixer read port (every GVRAM word carries its own plane offset, so a
// displayed word names the row it was fetched from). The frame-boundary configuration
// snapshot (cfg_snap) copies the SCROLL block at the last dot of line 439, but the +2
// fetch pipeline latches row 0's base at the line-438 tick and row 1's at the line-439
// tick - a full line and 1-2 clk_sys BEFORE that copy - so a decode that reads the DISPLAY
// registers shows the PREVIOUS frame's scroll on exactly those two rows, every frame while
// the game scrolls: a two-pixel band at the top of the tile background displaced by the
// per-frame scroll delta. tb_pc9821_gdc2_scroll cannot see it: it samples the decode a
// frame after the write, when the copy has already landed.
//
// Case 2 is the 640x200 shape: the slave CSRFORM line repeat (0x4B + one 0xA0 byte) and a
// SCROLL in the same vblank, where rows 0-1 are one GDC line doubled and must use BOTH the
// new line repeat and the new start.

`default_nettype none

module tb_pc9821_scanout_frame_base;
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

  // ==== DUT ====
  // The raster GDC, clocked exactly as pc9821_system clocks it. It owns the raster, the
  // line origin and the frame-boundary configuration snapshot.
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
  wire        vsync_irq_arm = 1'b0;
  wire        vsync_irq;
  wire        vsync_edge;   // parked for (.*)
  wire        disp_on;
  wire        gfx_disp;
  wire        gfx_egc_gate;
  wire  [6:0] cfg_ram_mib = 7'd0;
  wire        cfg_seed_en = 1'b0;
  wire        cfg_seed_reload = 1'b0;
  wire [15:0] dbg_sad;
  wire  [7:0] dbg_pitch;
  wire        dbg_col40, dbg_disp;
  wire  [7:0] dbg_wk_skips;
  wire        text_opaque, text_cell;
  wire [11:0] text_colour;
  wire  [9:0] pix_dot;
  wire        pix_h_active, pix_v_active;
  wire        gfx_mode16;
  wire [31:0] gfx_dig;
  wire        pal_wr_en;
  wire  [3:0] pal_wr_idx;
  wire  [1:0] pal_wr_chan;
  wire  [3:0] pal_wr_data;
  wire        pal_commit;
  wire        hs_out, vs_out, de_out;

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

  // The line tick, as pc9821_system builds it (one clk_sys pulse at the last dot of the
  // line, from a counter clocked by the pixel enable).
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

  // The scanout: the four planes and their per-line fetch into the ping-pong line
  // buffer, wired to the raster exactly as pc9821_system wires them.
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

  pc9821_gvram_dut u_gvram (
      .clk(clk), .reset(reset),
      .access_page(gfx_access_page),
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

  // The pixel pipeline, the graphics arm only: the mixer is the one reader of the line
  // buffer, exactly as pc9821_system wires it.
  wire [7:0] r_out, g_out, b_out;
  // The PEGC arm's inputs (pegc-scope-REPORT.md 4 row 4): tied off in the
  // 16-colour benches; tb_pc9821_video_mixer drives them.
  reg        mix_pegc_256 = 1'b0;
  reg        mix_pal256_wr_en = 1'b0;
  reg  [7:0] mix_pal256_wr_idx = 8'd0, mix_pal256_wr_data = 8'd0;
  reg  [1:0] mix_pal256_wr_chan = 2'd0;
  pc9821_video_mixer u_mixer (
      .clk(clk), .rst_n(~reset),
      .dot_x(pix_dot), .h_active(pix_h_active), .v_active(pix_v_active),
      .text_opaque(text_opaque), .text_cell(text_cell), .text_colour(text_colour),
      .line_data(line_data), .line_ready(line_ready), .line_sel(line_sel),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .pal_mode16(gfx_mode16), .pal_dig(gfx_dig),
      .pal_wr_en(pal_wr_en), .pal_wr_idx(pal_wr_idx), .pal_wr_chan(pal_wr_chan),
      .pal_wr_data(pal_wr_data), .pal_commit(pal_commit),
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

  // Every GVRAM word carries its own plane offset in the low 15 bits, so a displayed
  // word names the row it was fetched from and a stale row is visible by value.
  function [31:0] enc(input [14:0] off);
    begin
      enc = {17'd0, off};
    end
  endfunction

  task automatic poke_off(input [14:0] off);
    begin
      u_gvram.u_gmem.mem0[off] = enc(off)[ 7: 0];
      u_gvram.u_gmem.mem1[off] = enc(off)[15: 8];
      u_gvram.u_gmem.mem2[off] = enc(off)[23:16];
      u_gvram.u_gmem.mem3[off] = enc(off)[31:24];
    end
  endtask

  // The GDC2 SCROLL transaction: 0xA2 <- 0x70 then the eight parameter bytes at 0xA0,
  // {start1 word, lines1 word, start2 word, lines2 word}. start = the word's low 14 bits
  // doubled (a plane byte offset), lines = the word >> 4. Partition 2 is parked at length
  // zero (never expires), so base(L) = start + L*80.
  //
  // THE ENCODER'S WARRANT (these constants were uncited magic and
  // would mirror a wrong DUT decode silently). The parameter LAYOUT is NP2kai's GDC
  // SCROLL handling: bios/bios18.c:172-205 (bios0x18_0f packs the start word with
  // `t >>= 1` - the doubled-byte-offset inverse - and the length word as
  // `lines * raster`) and vram/makegrex.c:32-35 (the consumer: `vad =
  // para+GDC_SCROLL+gpos`, `remain = LOW14(...) >> 4`, the same low-14-double and
  // word>>4 fields read back out). The eight-byte block shape and the parked second
  // partition are the same GDC SCROLL structure (two {start, lines} partitions).
  task automatic write_scroll(input [14:0] start, input [13:0] lines);
    reg [15:0] sw, lw;
    begin
      sw = {1'b0, start} >> 1;
      lw = {2'd0, lines} << 4;
      write_io(8'hA2, 8'h70);
      write_io(8'hA0, sw[7:0]);
      write_io(8'hA0, sw[15:8]);
      write_io(8'hA0, lw[7:0]);
      write_io(8'hA0, lw[15:8]);
      write_io(8'hA0, 8'h00);
      write_io(8'hA0, 8'h00);
      write_io(8'hA0, 8'h00);
      write_io(8'hA0, 8'h00);
    end
  endtask

  // The displayed line's column word at raster line L (the scanout's own data port),
  // sampled mid-column where the registered read has settled.
  task automatic sample_linecol(input [8:0] L, input [6:0] col, output [31:0] v);
    begin
      wait (u_gdc.u_crtc.vline == L);
      wait (u_gdc.u_crtc.hdot == {col, 3'd4});
      @(negedge clk);
      v = line_data;
    end
  endtask

  task automatic check_row(input [8:0] L, input [6:0] col, input [14:0] exp_off);
    reg [31:0] v;
    begin
      sample_linecol(L, col, v);
      if (v !== enc(exp_off)) begin
        $display("FAIL displayed row %0d col %0d: fetched word %08x (plane offset %0d), expected %08x (offset %0d) - %0s",
                 L, col, v, v[14:0], enc(exp_off), exp_off,
                 (v[14:0] < exp_off) ? "STALE (previous scroll)" : "WRONG ROW");
        errors = errors + 1;
      end
    end
  endtask

  integer i;
  localparam [14:0] NEW1 = 15'd1600;   // 20 rows down: far from the start-0 rows
  localparam [14:0] NEW2 = 15'd3200;   // case 2's start, 40 rows down

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    reset <= 1'b0;
    repeat (4) @(posedge clk);

    // GVRAM words carry their own offset; the pokes go in before the display is enabled
    // so the fetch never sees a half-poked row.
    for (i = 0; i < 4096; i = i + 1) poke_off(i[14:0]);

    // The raster configuration the games run the 640x400 graphics display in.
    // WARRANT: the four bytes are the games' own 640x400 mode-set
    // shape - the machine's GDC2 programming of SYNC/CSRFORM/PITCH/SCROLL as NP2kai
    // keeps it in gdc.m.para[] (io/gdc.c parameter dispatch) and bios18's mode
    // programming (bios/bios18.c) - driven here so the rows below move at the raster
    // pitch (80 words/line) the mode implies. The values were verified against those
    // references this pass; they are no longer uncited.
    write_io(8'h62, 8'h0D);
    write_io(8'h68, 8'h08);
    write_io(8'h6A, 8'h01);
    write_io(8'hA2, 8'h0D);

    // ---------------------------------------------------------------
    // 1. A mid-vblank SCROLL move: rows 0, 1 AND 2 of the coming frame
    //    show the NEW start (rows 0-1 are latched before the frame-end copy).
    //
    //    WARRANTED CLAIM: a SCROLL written in vblank must move
    //    the WHOLE coming frame together - the GDC latches its scroll at the frame
    //    boundary (vsync), the uPD7220/GDC frame-latch semantics NP2kai's
    //    full-repaint model also assumes (GDCSCRN_ALLDRAW2, io/gdc.c:343). Rows
    //    0-2 TOGETHER is that reference-shaped claim and is fail-first for the F7
    //    lost-wakeup class.
    //    CAPTURE-PENDING (named): the EXACT sub-line swap point
    //    (row 0 latched at the line-438 tick and row 1 at the line-439 tick, 1-2
    //    clk_sys before the frame-end cfg_snap copy) is THIS pipeline's own
    //    model - no capture pins which frame a write landing exactly on those
    //    ticks belongs to, and NP2kai cannot arbitrate (it repaints whole frames).
    //    The rows 0/1 expectations below therefore pin the design's frame-latch
    //    contract, not a measured one; the real Xe10 capture (scroll one known
    //    pattern per frame, capture rows 0-2 of the top) is what settles it.
    // ---------------------------------------------------------------
    write_scroll(15'd0, 14'd400);
    repeat (2) begin
      wait (u_gdc.u_crtc.vline == 9'd0);
      wait (u_gdc.u_crtc.vline != 9'd0);
    end

    // The machine's own shape: the guest draws under the VSYNC wait (the IRQ rises at
    // vline 407) and its SCROLL lands in the 407-419 window.
    wait (u_gdc.u_crtc.vline == 9'd410);
    write_scroll(NEW1, 14'd400);

    // The frame that starts after the write: every row 0.. is one scroll step ahead
    // together. Row 0's and row 1's bases were latched at vline 438/439, BEFORE the
    // frame-end snapshot copies the write - the rows the defect leaves behind.
    check_row(9'd0, 7'd0, NEW1 + 15'd0);
    check_row(9'd1, 7'd0, NEW1 + 15'd80);
    check_row(9'd1, 7'd3, NEW1 + 15'd83);
    check_row(9'd2, 7'd0, NEW1 + 15'd160);
    check_row(9'd3, 7'd0, NEW1 + 15'd240);
    check_row(9'd10, 7'd0, NEW1 + 15'd800);

    // A stable frame later: the snapshot persists, rows 0-2 stay at the new start.
    check_row(9'd0, 7'd0, NEW1 + 15'd0);
    check_row(9'd1, 7'd0, NEW1 + 15'd80);
    check_row(9'd2, 7'd0, NEW1 + 15'd160);

    // ---------------------------------------------------------------
    // 2. The 640x200 shape: the slave CSRFORM line repeat and a SCROLL in the same
    //    vblank. Rows 0-1 are GDC line 0 doubled: BOTH the new repeat and the new start.
    // ---------------------------------------------------------------
    wait (u_gdc.u_crtc.vline == 9'd410);
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h01);           // lr-1 = 1: each GDC line on two raster lines
    write_scroll(NEW2, 14'd200);

    check_row(9'd0, 7'd0, NEW2 + 15'd0);
    check_row(9'd1, 7'd0, NEW2 + 15'd0);
    check_row(9'd2, 7'd0, NEW2 + 15'd80);
    check_row(9'd3, 7'd0, NEW2 + 15'd80);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SCANOUT_FRAME_BASE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_SCANOUT_FRAME_BASE: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog. A frame is 848 x 440 dots x 2.375 clk at 10 ns = ~8.9 ms of
  // simulated time, and this bench walks six of them; 100 ms is the sibling GDC
  // bench's ceiling and leaves headroom.
  initial begin
    #100_000_000;
    $fatal(1, "TB_PC9821_SCANOUT_FRAME_BASE: TIMEOUT");
  end

endmodule

`default_nettype wire

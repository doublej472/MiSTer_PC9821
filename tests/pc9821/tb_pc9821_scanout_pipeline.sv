`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The 640x400 16-colour scanout against the machine's own power-on palette: the REAL pc9821_gdc_text's line origin and frame-coherent palette snapshot, the REAL pc9821_gvram ping-pong line buffer and the REAL pc9821_video_mixer, sampled at the framework's own pixel enable through five cases - the four-plane fold to the 4-bit index and its RGB out, the ITF ROM's power-on analogue table (itf.rom 0x042F, where entry 2 is red and entry 4 is green), the 0xA4 display page, the CSRFORM 640x200 line repeat, and the HBLANK/VBLANK border - so every active dot's 8-bit R/G/B must be the reference table entry for that dot's index and a red/green swap in the table the core powers up with shows as a wrong colour rather than a plausible one.
//
// ---- the bench's own account of where each expectation comes from ----
// The whole scanout is in the path, exactly as pc9821_system wires it: gdc_text's
// gfx_line_addr and per-line tick drive pc9821_gvram's fetch and ping-pong, and the
// mixer is the one reader of that buffer, so a line painted into the plane windows is
// sampled at the framework's own pixel enable.
//
// THE POWER-ON ANALOGUE TABLE IS THE FIRMWARE'S OWN, NOT THIS MODULE'S. The ITF ROM's
// palette loop at 0x03FE-0x0418 writes, per entry, `out 0xA8` (index), `out 0xAA` (G),
// `out 0xAC` (R), `out 0xAE` (B) from the 48 bytes at 0x042F, and NP2kai's `defanapal`
// is the same table packed {G,R,B} in bits 11..0 (`gdc_setanalogpalall` passes
// `pal>>8` to p.g and `pal>>4` to p.r). Decoded that way entry 2 is red and entry 4 is
// green, which is what NP2kai's `degpal1[i] = {b=i&1, r=(i>>1)&1, g=(i>>2)&1}` requires
// of the {E,G,R,B} fold: a lone red plane is index 2 and a lone green plane is index 4.
// The QEMU renderer agrees (`pc98-vga.c` puts r at index bit 1 and g at bit 2).
//
// The digital power-on bytes 0xA8/AA/AC/AE = 37/15/26/04 are checked too: they are
// `defdegpal`/`defanapal` in NP2kai (`io/gdc.c:56`) and the pack expands to
// black/blue/red/magenta in the high nibbles and green/cyan/yellow/white in the low.
//
// The line repeat is the slave CSRFORM's `lr-1` (`vram/makegrph.c:362`): lr = 2 holds
// each GDC line for two raster lines. The page is 0xA4 and the border is the raster's
// 640-of-848 / 400-of-440 active window, black outside.
//
// The one reference arm this bench does NOT model is `mode1[4]`'s blank-vs-duplicate
// rule (NP2kai `makegrph.c:155`, QEMU `pc98-vga.c:4475` blank the repeated line when
// it is set); this core keeps the duplicate.

`default_nettype none

module tb_pc9821_scanout_pipeline;
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
  // The raster GDC, clocked exactly as pc9821_system clocks it (clk_vid = clk_sys gated
  // by the pixel enable). It owns the raster, the line origin and the palette snapshot.
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

  localparam [31:0] GVRAM_BASE = 32'h0300_0000;

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

  

  // The pixel pipeline: fold -> graphics palette -> compositor, the graphics arm only. The
  // analogue table's CPU write port comes from pc9821_gdc_text, exactly as pc9821_system
  // wires it.
  wire [7:0] r_out, g_out, b_out;
  // The PEGC arm's inputs (pegc-scope-REPORT.md 4 row 4): tied off in the
  // 16-colour benches; tb_pc9821_video_mixer drives them.
  reg        mix_pegc_256 = 1'b0;
  reg        mix_pal256_wr_en = 1'b0;
  reg  [7:0] mix_pal256_wr_idx = 8'd0, mix_pal256_wr_data = 8'd0;
  reg  [1:0] mix_pal256_wr_chan = 2'd0;
  pc9821_video_mixer u_mixer (
      .clk(clk),
      .dot_x(pix_dot), .h_active(pix_h_active), .v_active(pix_v_active),
      .text_opaque(text_opaque), .text_cell(text_cell), .text_colour(text_colour),
      .line_data(line_data), .line_ready(line_ready), .line_sel(line_sel),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .pal_mode16(gfx_mode16), .pal_dig(gfx_dig),
      .pal_wr_en(pal_wr_en), .pal_wr_idx(pal_wr_idx), .pal_wr_chan(pal_wr_chan),
      .pal_wr_data(pal_wr_data),
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

  // One plane's byte at one word offset (the word's byte lane is the plane index).
  task automatic put_byte(input [1:0] plane, input [14:0] off, input [7:0] val);
    begin
      cpu_store(plane, off, {24'd0, val} << (off[1:0] * 8), 4'b0001 << off[1:0]);
    end
  endtask

  // One four-plane column word = one dot's palette index per plane byte.
  task automatic put_column(input [14:0] w, input [7:0] b, input [7:0] r,
                            input [7:0] g, input [7:0] e);
    begin
      put_byte(2'd0, w, b);
      put_byte(2'd1, w, r);
      put_byte(2'd2, w, g);
      put_byte(2'd3, w, e);
    end
  endtask

  // The power-on analogue table the ITF ROM writes (0x042F, loop 0x03FE-0x0418), as
  // {R,G,B} nibbles. NP2kai's defanapal is the same table packed {G,R,B}.
  function automatic [11:0] itf_entry(input [3:0] i);
    begin
      case (i)
        4'h0: itf_entry = 12'h000;   // black
        4'h1: itf_entry = 12'h007;   // blue       (B is bit 0)
        4'h2: itf_entry = 12'h700;   // red        (R is bit 1, GREEN is bit 2)
        4'h3: itf_entry = 12'h707;   // magenta
        4'h4: itf_entry = 12'h070;   // green      (G alone reaches entry 4)
        4'h5: itf_entry = 12'h077;   // cyan
        4'h6: itf_entry = 12'h770;   // yellow
        4'h7: itf_entry = 12'h777;   // white
        4'h8: itf_entry = 12'h444;   // dark grey
        4'h9: itf_entry = 12'h00F;   // bright blue
        4'hA: itf_entry = 12'hF00;   // bright red
        4'hB: itf_entry = 12'hF0F;   // bright magenta
        4'hC: itf_entry = 12'h0F0;   // bright green
        4'hD: itf_entry = 12'h0FF;   // bright cyan
        4'hE: itf_entry = 12'hFF0;   // bright yellow
        default: itf_entry = 12'hFFF; // bright white
      endcase
    end
  endfunction

  // 4-bit to 8-bit: nibble replication, {n,n} (NP2kai anapal1[i] = i * 0x11).
  function automatic [23:0] expand8(input [11:0] c);
    begin
      expand8 = { {c[11:8], c[11:8]}, {c[7:4], c[7:4]}, {c[3:0], c[3:0]} };
    end
  endfunction

  // Paint line 0's 80 columns with index (c & 0xF) on every dot: plane bit p of the
  // index is that plane's byte, so all eight dots of column c fold alike.
  task automatic paint_index_line0;
    integer c;
    reg [3:0] ix;
    begin
      for (c = 0; c < 80; c = c + 1) begin
        ix = c[3:0];
        put_column(c[14:0], ix[0] ? 8'hFF : 8'h00, ix[1] ? 8'hFF : 8'h00,
                   ix[2] ? 8'hFF : 8'h00, ix[3] ? 8'hFF : 8'h00);
      end
    end
  endtask

  // Capture raster 0's first 16 columns at the pixel enable, where the framework
  // samples. Two frame ends first, so the painted line has been
  // fetched into the displayed buffer.
  reg        armed = 1'b0;
  reg [7:0]  cap_r [0:79];
  reg [7:0]  cap_g [0:79];
  reg [7:0]  cap_b [0:79];
  reg [31:0] cap_word [0:79];
  reg        cap_seen [0:79];
  always @(posedge clk) begin
    if (armed && pixel_ce && pix_h_active && pix_v_active &&
        (u_gdc.u_crtc.vline == 9'd0) && (u_gdc.u_crtc.hdot[2:0] == 3'd0)) begin
      cap_r[u_gdc.u_crtc.hdot[9:3]] <= r_out;
      cap_g[u_gdc.u_crtc.hdot[9:3]] <= g_out;
      cap_b[u_gdc.u_crtc.hdot[9:3]] <= b_out;
      cap_word[u_gdc.u_crtc.hdot[9:3]] <= line_data;
      cap_seen[u_gdc.u_crtc.hdot[9:3]] <= 1'b1;
    end
  end

  // The frame boundary is the raster's own frame_end, NOT a frame_cnt change: frame_cnt is the
  // character blink's count and advances once per CSRFORM `timing` frames,
  // so it is no longer a frame counter.
  task automatic next_frame;
    begin
      while (u_gdc.u_crtc.frame_end) @(negedge clk);
      while (!u_gdc.u_crtc.frame_end) @(negedge clk);
    end
  endtask

  task automatic capture_raster0;
    integer c;
    begin
      for (c = 0; c < 80; c = c + 1) cap_seen[c] = 1'b0;
      next_frame();
      next_frame();
      armed = 1'b1;
      wait (u_gdc.u_crtc.vline == 9'd1);
      armed = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  // One pixel at raster line L, dot D, read where the framework latches it.
  task automatic sample_rgb(input [8:0] L, input [9:0] D,
                            output [7:0] cr, output [7:0] cg, output [7:0] cb);
    begin
      wait (u_gdc.u_crtc.vline == L);
      wait (u_gdc.u_crtc.hdot == D);
      @(negedge clk);
      cr = r_out; cg = g_out; cb = b_out;
    end
  endtask

  // The displayed line's column-0 word at raster line L (the scanout's own data port).
  task automatic sample_linecol0(input [8:0] L, output [31:0] v);
    begin
      wait (u_gdc.u_crtc.vline == L);
      wait (u_gdc.u_crtc.hdot == 10'd0);
      @(negedge clk);
      v = line_data;
    end
  endtask

  integer i, c, g;
  integer bad;
  reg [14:0] wo;
  reg [11:0] want12, got12;
  reg [23:0] want24;
  reg [7:0]  cr, cg, cb;
  reg [31:0] word;

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    reset <= 1'b0;
    repeat (4) @(posedge clk);

    // The raster configuration the games run the 640x400 graphics display in: BCTRL on,
    // 16-colour analogue, the 200-line flag clear, GDC2 START, SCROLL {0, 400} with
    // partition 2 disabled so base(L) = L*80 words.
    write_io(8'h62, 8'h0D);
    write_io(8'h68, 8'h08);
    write_io(8'h6A, 8'h01);
    write_io(8'hA2, 8'h0D);
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h19);
    write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h00);

    // ---------------------------------------------------------------
    // 1. The power-on analogue table the palette's DISPLAYED table holds.
    // ---------------------------------------------------------------
    repeat (12) @(posedge clk);
    next_frame();
    next_frame();
    bad = 0;
    for (i = 0; i < 16; i = i + 1) begin
      got12 = u_mixer.u_palette.disp[i[3:0]];
      want12 = itf_entry(i[3:0]);
      if (got12 !== want12) begin
        $display("FAIL power-on analogue entry %0d: core {R,G,B}=%03x, ITF ROM (itf.rom 0x042F, entry 2 red / entry 4 green) = %03x",
                 i, got12, want12);
        errors = errors + 1;
        bad = bad + 1;
      end
    end
    if (bad != 0)
      $display("  (%0d of 16 power-on analogue entries differ from the ITF ROM table)", bad);

    // The digital power-on bytes are the same firmware table's other half.
    if (gfx_dig !== {8'h37, 8'h15, 8'h26, 8'h04}) begin
      $display("FAIL power-on digital bytes %08x, expected {0xA8,0xAA,0xAC,0xAE}=37152604",
               gfx_dig);
      errors = errors + 1;
    end

    // ---------------------------------------------------------------
    // 2. The pixel stream with the table the core powers up with.
    // ---------------------------------------------------------------
    paint_index_line0();
    capture_raster0();
    bad = 0;
    for (c = 0; c < 16; c = c + 1) begin
      if (!cap_seen[c]) begin
        $display("FAIL raster 0 column %0d was never sampled", c);
        errors = errors + 1;
        bad = bad + 1;
      end else if ({cap_r[c], cap_g[c], cap_b[c]}
                   !== expand8(itf_entry(c[3:0]))) begin
        $display("FAIL raster 0 column %0d (fold index %0d): core RGB %02x%02x%02x, itf.rom 0x042F entry %0d = %03x",
                 c, c[3:0], cap_r[c], cap_g[c], cap_b[c], c[3:0], itf_entry(c[3:0]));
        errors = errors + 1;
        bad = bad + 1;
      end
    end
    if (bad != 0)
      $display("  (%0d of 16 sampled column colours differ from the ITF ROM table)", bad);

    // ---------------------------------------------------------------
    // 3. The same stream once the machine's own table is written.
    // ---------------------------------------------------------------
    // 0xA8 index, 0xAA green, 0xAC red, 0xAE blue, exactly the ITF loop's order, but a
    // value the power-on table does NOT carry - entry k -> R=k, G=15-k, B=k^5 - so the
    // pixels prove the write port, the table and the palette read all
    // carry the table, rather than agreeing with the power-on image by accident.
    for (i = 0; i < 16; i = i + 1) begin
      write_io(8'hA8, i[7:0]);
      write_io(8'hAA, {4'h0, (4'd15 - i[3:0])});
      write_io(8'hAC, {4'h0, i[3:0]});
      write_io(8'hAE, {4'h0, (i[3:0] ^ 4'd5)});
    end
    capture_raster0();
    bad = 0;
    for (c = 0; c < 16; c = c + 1) begin
      want24 = expand8({c[3:0], (4'd15 - c[3:0]), (c[3:0] ^ 4'd5)});
      if ({cap_r[c], cap_g[c], cap_b[c]} !== want24) begin
        $display("FAIL written-table raster 0 column %0d: core RGB %02x%02x%02x, expected %06x",
                 c, cap_r[c], cap_g[c], cap_b[c], want24);
        errors = errors + 1;
        bad = bad + 1;
      end
    end
    if (bad != 0)
      $display("  (%0d written-table colours differ: the fold, the palette write port and the compositor do NOT carry the written table)", bad);

    // Put the MACHINE's own table back, so the sections below keep their ITF-ROM
    // expectations.
    for (i = 0; i < 16; i = i + 1) begin
      write_io(8'hA8, i[7:0]);
      write_io(8'hAA, {4'h0, itf_entry(i[3:0])[7:4]});
      write_io(8'hAC, {4'h0, itf_entry(i[3:0])[11:8]});
      write_io(8'hAE, {4'h0, itf_entry(i[3:0])[3:0]});
    end
    next_frame();
    next_frame();

    // ---------------------------------------------------------------
    // 4. The 0xA4 display page selects which plane pair is scanned out.
    // ---------------------------------------------------------------
    // Page 0 column 0 = index 1 (blue); page 1 column 0 = index 2 (red).
    write_io(8'hA6, 8'h00);
    put_column(15'd0, 8'hFF, 8'h00, 8'h00, 8'h00);
    write_io(8'hA6, 8'h01);
    put_column(15'd0, 8'h00, 8'hFF, 8'h00, 8'h00);
    write_io(8'hA6, 8'h00);

    write_io(8'hA4, 8'h00);
    capture_raster0();
    if ({cap_r[0], cap_g[0], cap_b[0]} !== expand8(itf_entry(4'h1))) begin
      $display("FAIL display page 0 column 0: RGB %02x%02x%02x, expected %06x (index 1, page 0's blue word)",
               cap_r[0], cap_g[0], cap_b[0], expand8(itf_entry(4'h1)));
      errors = errors + 1;
    end

    write_io(8'hA4, 8'h01);
    capture_raster0();
    if ({cap_r[0], cap_g[0], cap_b[0]} !== expand8(itf_entry(4'h2))) begin
      $display("FAIL display page 1 column 0: RGB %02x%02x%02x, expected %06x (index 2, page 1's red word)",
               cap_r[0], cap_g[0], cap_b[0], expand8(itf_entry(4'h2)));
      errors = errors + 1;
    end
    write_io(8'hA4, 8'h00);

    // ---------------------------------------------------------------
    // 5. The border: black outside 640x400, painted inside.
    // ---------------------------------------------------------------
    // Raster 0 still carries the painted line: column 1 folds to index 1 (blue) and
    // column 79 to index 0xF (white), so both ends of the active window are non-black
    // and the first dot past each boundary must be black. The window ends are read from
    // the pixel-enable capture, not a mid-dot probe.
    capture_raster0();
    if (!cap_seen[1]) begin
      $display("FAIL raster 0 column 1 was never sampled");
      errors = errors + 1;
    end else if ({cap_r[1], cap_g[1], cap_b[1]} === 24'h000000) begin
      $display("FAIL raster 0 column 1 is black; it folds to index 1 and must not be");
      errors = errors + 1;
    end
    if (!cap_seen[79]) begin
      $display("FAIL raster 0 column 79 was never sampled");
      errors = errors + 1;
    end else if ({cap_r[79], cap_g[79], cap_b[79]} === 24'h000000) begin
      $display("FAIL raster 0 column 79 is black; it folds to index 0xF (word %08x)",
               cap_word[79]);
      errors = errors + 1;
    end
    sample_rgb(9'd0, 10'd640, cr, cg, cb);
    if ({cr, cg, cb} !== 24'h000000) begin
      $display("FAIL raster 0 dot 640 (HBLANK) = %02x%02x%02x, not black", cr, cg, cb);
      errors = errors + 1;
    end
    sample_rgb(9'd0, 10'd700, cr, cg, cb);
    if ({cr, cg, cb} !== 24'h000000) begin
      $display("FAIL raster 0 dot 700 (HBLANK) = %02x%02x%02x, not black", cr, cg, cb);
      errors = errors + 1;
    end
    sample_rgb(9'd420, 10'd0, cr, cg, cb);
    if ({cr, cg, cb} !== 24'h000000) begin
      $display("FAIL raster 420 (VBLANK) dot 0 = %02x%02x%02x, not black", cr, cg, cb);
      errors = errors + 1;
    end

    // ---------------------------------------------------------------
    // 6. The CSRFORM 640x200 line repeat holds each GDC line for two rasters.
    // ---------------------------------------------------------------
    // Clear mode1[4] first: that is the target games' shape, where the
    // references duplicate the repeated line rather than blanking it.
    write_io(8'h68, 8'h08);
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h01);   // CSRFORM[4:0] = lr-1 = 1, so lr = 2
    for (g = 0; g < 200; g = g + 1)
      for (c = 0; c < 80; c = c + 1) begin
        wo = 15'(g * 80 + c);
        put_byte(2'd0, wo, g[7:0]);
      end
    // Two frame ends for the frame-boundary lr snapshot and the line fetches.
    next_frame();
    next_frame();
    bad = 0;
    for (i = 0; i < 4; i = i + 1) begin
      sample_linecol0({1'b0, i[7:0]}, word);
      if (word !== (i[31:0] >> 1)) begin
        $display("FAIL 640x200 raster %0d column 0: word %0d, expected GDC line %0d",
                 i, word, i >> 1);
        errors = errors + 1;
        bad = bad + 1;
      end
    end
    sample_linecol0(9'd398, word);
    if (word !== 32'd199) begin
      $display("FAIL 640x200 raster 398 column 0: word %0d, expected GDC line 199", word);
      errors = errors + 1;
      bad = bad + 1;
    end
    sample_linecol0(9'd399, word);
    if (word !== 32'd199) begin
      $display("FAIL 640x200 raster 399 column 0: word %0d, expected GDC line 199", word);
      errors = errors + 1;
      bad = bad + 1;
    end
    if (bad != 0)
      $display("  (%0d raster lines did not hold their GDC line twice)", bad);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SCANOUT_PIPELINE: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_SCANOUT_PIPELINE: FAIL (%0d errors)", errors);
  end

  // The paint is line 0's 80 columns and the 200-line program's 200 x 80 stores; the
  // settle waits are a few frames. 300 ms is far past either.
  initial begin
    #300_000_000;
    $fatal(1, "TB_PC9821_SCANOUT_PIPELINE: TIMEOUT");
  end

endmodule

`default_nettype wire

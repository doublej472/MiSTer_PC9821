`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_RASTER_PALETTE: an analogue palette write reaches the raster lines scanned after it, not the next frame: the raster split a game makes (its VSYNC handler writes palette A in the vertical blank, a PIT one-shot writes palette B in the horizontal blank of raster line 105 and palette C in that of line 346, all sixteen entries each time through 0xA8/0xAA/0xAC/0xAE), run on the REAL pc9821_gdc_text, pc9821_gvram line buffer and pc9821_video_mixer for three frames, shows palette A on raster lines 0-104, B on lines 107-345 and C on lines 348-399 at entry 0 and entry 9 in the last frame, as NP2kai draws it (io/gdc.c gdc_setanalogpal logs each write with its frame clock and vram/scrndraw.c rasterdraw applies it from the next line pair) and as MAME does (src/mame/nec/pc9801.cpp pc9801rs_a0_w: update_partial at the write's vpos); the two lines after each write, where the references' line quantisation differs, are not asserted. And an 8-colour DIGITAL palette write reaches the dots after it inside its own line, as the real Xe10 shows it (XE10T /RASTER's DTOGGLE phase, docs/probes/XE10T-XE10-RASTER.TXT:28 `P RASTER DTOGGLE frames=283`, filmed as staggered blue/black dashes about one `out` long), not at the next frame as both references draw it: with 0x6A = 00 and 0xAE written 0x14 at dot 100 and 0x04 at dot 400 of raster line 200 in each of three frames, the last frame's line 200 shows digital entry 0 black at dot 60, blue at dot 300 and black at dot 600.
//
// ---- the bench's own account of where each expectation comes from ----
// THE SHAPE IS A GAME'S. Lemmings' VSYNC handler (int 0Ah) writes its level palette at the
// start of the vertical blank, then arms PIT channel 0 as a one-shot; the timer IRQ writes a
// second palette at raster line ~105 (the briefing) or ~346 (the in-level panel). Logged in
// NP2kai with the raster line of every 0xA8-0xAE access. Both splits are made here in one
// frame, every entry written each time, in the order the ITF ROM's palette loop uses
// (`out 0xA8` index, `out 0xAA` G, `out 0xAC` R, `out 0xAE` B).
//
// WHAT THE REFERENCES DRAW. NP2kai: gdc_setanalogpal (io/gdc.c) records a write made outside
// the vertical blank as an event carrying its time in the frame (`event->clock =
// g_nevent.item[NEVENT_FLAMES].clock - ...`); rasterdraw (vram/scrndraw.c) starts the frame
// from the palette in force at display start (pal_eventclear copies gdc.anapal there) and walks
// the frame in line pairs (`for (y=2; y<maxy; y+=2)`, `clk -= 2 * gdc.rasterclock`), drawing
// the lines before an event's time with the old table and the rest with the event applied. A
// write in the vertical blank (`palevent.vsyncpal = 1`) holds for the whole next frame. MAME
// (src/mame/nec/pc9801.cpp pc9801rs_a0_w) updates the pen and calls
// `m_screen->update_partial(m_screen->vpos())` with the comment "lemmings raster effects":
// one scanline of granularity. So, with the writes in the horizontal blank AFTER line L's
// active dots, both references show the old table on every line before L and the new one
// on every line from L+2; lines L and L+1 are where their quantisation (one line, a line
// pair) differs. The real DAC takes a write at once, mid-line (XE10T /RASTER's TOGGLE phase,
// docs/probes/XE10T-XE10-RASTER.TXT:27 `P RASTER TOGGLE frames=283`); those two lines are
// still not asserted here (the writes land in the horizontal blank, after the line's dots).
//
// The three tables differ in every channel of entries 0 and 9 (A = {R=k, G=3, B=15-k},
// B = {15-k, 12, k}, C = {k^5, 7, k}), so a frame shown in one table where another is due is
// a wrong colour, not a plausible one. Entry 0 is the whole screen (GVRAM is zero) and entry 9
// is column 3 of every line (planes B and E set), so the 4-bit index reaches the table too.

`default_nettype none

module tb_pc9821_raster_palette;
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
  // The analogue palette table's CPU write port.
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

  // A CPU store through a plane window, exactly what pc9821_memory_map emits.
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
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic put_byte(input [1:0] plane, input [14:0] off, input [7:0] val);
    begin
      cpu_store(plane, off, {24'd0, val} << (off[1:0] * 8), 4'b0001 << off[1:0]);
    end
  endtask

  // The three tables, {R,G,B} nibbles for entry k.
  function automatic [11:0] pal_a(input [3:0] k);
    pal_a = {k, 4'd3, 4'd15 - k};
  endfunction
  function automatic [11:0] pal_b(input [3:0] k);
    pal_b = {4'd15 - k, 4'd12, k};
  endfunction
  function automatic [11:0] pal_c(input [3:0] k);
    pal_c = {k ^ 4'd5, 4'd7, k};
  endfunction
  function automatic [11:0] pal_of(input [1:0] which, input [3:0] k);
    pal_of = (which == 2'd0) ? pal_a(k) : (which == 2'd1) ? pal_b(k) : pal_c(k);
  endfunction

  // 4-bit to 8-bit: nibble replication, {n,n} (NP2kai anapal1[i] = i * 0x11).
  function automatic [23:0] expand8(input [11:0] c);
    expand8 = { {c[11:8], c[11:8]}, {c[7:4], c[7:4]}, {c[3:0], c[3:0]} };
  endfunction

  // All sixteen entries, in the ITF palette loop's port order. 64 writes of two clk_sys
  // each: 128 clk_sys, about 27 dots, inside a 208-dot horizontal blank.
  task automatic write_table(input [1:0] which);
    integer k;
    reg [11:0] e;
    begin
      for (k = 0; k < 16; k = k + 1) begin
        e = pal_of(which, k[3:0]);
        write_io(8'hA8, k[7:0]);
        write_io(8'hAA, {4'h0, e[7:4]});
        write_io(8'hAC, {4'h0, e[11:8]});
        write_io(8'hAE, {4'h0, e[3:0]});
      end
    end
  endtask

  // The two split points and the vertical-blank write, by raster position.
  localparam [9:0] SPLIT_B = 10'd105;
  localparam [9:0] SPLIT_C = 10'd346;
  localparam [9:0] VBL     = 10'd400;
  localparam [9:0] HBL     = 10'd640;   // the first dot after the active 640

  task automatic wait_at(input [9:0] line, input [9:0] dot);
    begin
      while (!((u_gdc.u_crtc.vline == line) && (u_gdc.u_crtc.hdot == dot))) @(negedge clk);
    end
  endtask

  // The capture: entry 0's colour at dot 4 (column 0) and entry 9's at dot 28 (column 3) of
  // every active line, where the framework latches a dot. cap_n counts the frame each line
  // was last captured in, so a stale line cannot pass.
  reg [23:0] cap0 [0:399];
  reg [23:0] cap9 [0:399];
  reg [7:0]  cap_f [0:399];
  reg [7:0]  frame_no = 8'd0;
  always @(posedge clk) begin
    if (pixel_ce && pix_h_active && pix_v_active && (u_gdc.u_crtc.vline < 10'd400)) begin
      if (u_gdc.u_crtc.hdot == 10'd4)  cap0[u_gdc.u_crtc.vline[8:0]] <= {r_out, g_out, b_out};
      if (u_gdc.u_crtc.hdot == 10'd28) begin
        cap9[u_gdc.u_crtc.vline[8:0]]  <= {r_out, g_out, b_out};
        cap_f[u_gdc.u_crtc.vline[8:0]] <= frame_no;
      end
    end
    if (pixel_ce && u_gdc.u_crtc.frame_end) frame_no <= frame_no + 8'd1;
  end

  // The digital phase's capture: entry 0's colour at three dots of raster line DLINE (columns
  // 7, 37 and 75), each tagged with the frame it was taken in.
  localparam [9:0] DLINE = 10'd200;
  localparam [9:0] DW_ON = 10'd100;   // the dot the 0xAE = 0x14 write is issued at
  localparam [9:0] DW_OFF = 10'd400;  // the dot the 0xAE = 0x04 write is issued at
  reg [23:0] dcap [0:2];
  reg [7:0]  dcap_f [0:2];
  always @(posedge clk) begin
    if (pixel_ce && pix_h_active && pix_v_active && (u_gdc.u_crtc.vline == DLINE)) begin
      if (u_gdc.u_crtc.hdot == 10'd60)  begin dcap[0] <= {r_out, g_out, b_out}; dcap_f[0] <= frame_no; end
      if (u_gdc.u_crtc.hdot == 10'd300) begin dcap[1] <= {r_out, g_out, b_out}; dcap_f[1] <= frame_no; end
      if (u_gdc.u_crtc.hdot == 10'd600) begin dcap[2] <= {r_out, g_out, b_out}; dcap_f[2] <= frame_no; end
    end
  end

  integer f, l, bad;
  reg [1:0]  due;
  reg [23:0] want0, want9;
  reg [7:0]  last_frame;

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    reset <= 1'b0;
    repeat (4) @(posedge clk);

    // 640x400 16-colour analogue graphics, as tb_pc9821_scanout_pipeline programs it:
    // BCTRL on, 0x6A = 01 (16-colour), GDC2 START, SCROLL {0, 400}.
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

    // Column 3 of every line folds to index 9 (planes B and E); everything else is 0.
    for (l = 0; l < 400; l = l + 1) begin
      put_byte(2'd0, 15'(l * 80 + 3), 8'hFF);
      put_byte(2'd3, 15'(l * 80 + 3), 8'hFF);
    end

    // Three frames of the game's split: A in the vertical blank, B after line 105's active
    // dots, C after line 346's.
    for (f = 0; f < 3; f = f + 1) begin
      wait_at(VBL, 10'd0);
      write_table(2'd0);
      wait_at(SPLIT_B, HBL);
      write_table(2'd1);
      wait_at(SPLIT_C, HBL);
      write_table(2'd2);
    end
    // Let the last frame's lines 347-399 be scanned.
    wait_at(VBL, 10'd0);
    last_frame = cap_f[399];

    bad = 0;
    for (l = 0; l < 400; l = l + 1) begin
      if ((l == int'(SPLIT_B)) || (l == int'(SPLIT_B) + 1) || (l == int'(SPLIT_C)) || (l == int'(SPLIT_C) + 1))
        continue;
      due = (l < SPLIT_B) ? 2'd0 : (l < SPLIT_C) ? 2'd1 : 2'd2;
      want0 = expand8(pal_of(due, 4'd0));
      want9 = expand8(pal_of(due, 4'd9));
      if (cap_f[l] !== last_frame) begin
        $display("FAIL raster line %0d was not captured in the last frame (frame %0d, last %0d)",
                 l, cap_f[l], last_frame);
        bad = bad + 1;
      end else if ((cap0[l] !== want0) || (cap9[l] !== want9)) begin
        if (bad < 12)
          $display("FAIL raster line %0d: entry 0 %06x entry 9 %06x, palette %s due (%06x / %06x; NP2kai rasterdraw / MAME update_partial)",
                   l, cap0[l], cap9[l], (due == 2'd0) ? "A" : (due == 2'd1) ? "B" : "C",
                   want0, want9);
        bad = bad + 1;
      end
    end
    if (bad != 0) begin
      $display("  (%0d of 396 checked raster lines show the wrong palette)", bad);
      errors = errors + bad;
    end

    // ---- the 8-colour DIGITAL palette, the machine's DTOGGLE shape ----
    // 0x6A = 00 selects the digital mode; GVRAM is zero outside column 3, so every captured dot
    // is digital entry 0, whose colour is 0xAE's bits 6-4 ({G,R,B} = bits 6/5/4). In each of
    // three frames 0xAE is written 0x14 (entry 0 blue, entry 4 green - the probe's pair) at dot
    // 100 of line 200 and 0x04 (entry 0 black) at dot 400 of the same line. The real Xe10 shows
    // such a write inside the line it lands in (docs/probes/XE10T-XE10-RASTER.TXT:28
    // `P RASTER DTOGGLE frames=283`, filmed as staggered blue/black dashes about one `out`
    // long), so in the last frame dot 300 of line 200 is blue and dots 60 and 600 black. A
    // frame-latched digital palette shows black at all three (the frame-boundary value is the
    // last write, 0x04); a line-latched one shows black at dot 300 too.
    write_io(8'h6A, 8'h00);
    write_io(8'hAE, 8'h04);
    for (f = 0; f < 3; f = f + 1) begin
      wait_at(DLINE, DW_ON);
      write_io(8'hAE, 8'h14);
      wait_at(DLINE, DW_OFF);
      write_io(8'hAE, 8'h04);
    end
    wait_at(VBL, 10'd0);
    last_frame = dcap_f[2];
    if ((dcap_f[0] !== last_frame) || (dcap_f[1] !== last_frame)) begin
      $display("FAIL digital: line %0d was not captured whole in the last frame (%0d/%0d/%0d)",
               DLINE, dcap_f[0], dcap_f[1], last_frame);
      errors = errors + 1;
    end
    if (dcap[0] !== 24'h000000) begin
      $display("FAIL digital: line %0d dot 60 (before the 0x14 write) is %06x, want black 000000", DLINE, dcap[0]);
      errors = errors + 1;
    end
    if (dcap[1] !== 24'h0000FF) begin
      $display("FAIL digital: line %0d dot 300 (after 0xAE = 0x14 at dot 100) is %06x, want blue 0000FF - the Xe10 shows a digital write inside its line (XE10T-XE10-RASTER.TXT DTOGGLE)", DLINE, dcap[1]);
      errors = errors + 1;
    end
    if (dcap[2] !== 24'h000000) begin
      $display("FAIL digital: line %0d dot 600 (after 0xAE = 0x04 at dot 400) is %06x, want black 000000", DLINE, dcap[2]);
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_RASTER_PALETTE: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_RASTER_PALETTE: FAIL (%0d errors)", errors);
  end

  // 800 plane stores and eight frames at 440 x 848 dots (about 18 ms each): far below 400 ms.
  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_RASTER_PALETTE: TIMEOUT");
  end

endmodule

`default_nettype wire

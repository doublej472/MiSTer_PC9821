`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The 200-line graphics/text interleave as NP2kai renders it, driven as one scene through the REAL pc9821_gdc_text_dut (raster, MODE FF1, text render, GDC2 line origin) + the REAL pc9821_gvram line fetch + the REAL pc9821_video_mixer, wired exactly as pc9821_system wires them: with MODE FF1 bit 4 set, graphics appear on EVEN display lines only and ODD lines carry text only over BLACK - NP2kai fetches a display line only `if ((!(mg.liney & 1)) || (!(gdc.mode1 & 0x10)))` (vram/makegrph.c:155) and its p_2i draw paints the odd line of each pair as `(q[x] >> 4) + NP2PAL_TEXT` with the graphics plane absent (vram/sdraw.mcr:199-243, the interleave row selected on `gdc.mode1 & 0x10`, vram/scrndraw.c:227). The scene is line-uniform so every active dot has one expected colour: a bench-loaded full-block glyph (attr 0xE1 = colour 7 = white, pal_makeskiptable degpal1) on the even text rows, a bench-loaded space on the odd ones, and GVRAM filled so every dot folds to palette index 2 = the power-on table's red (itf.rom 0x042F / defanapal) - expected values from those references, never from our RTL. It also pins the FETCH side (makegrph.c:155): the gvram port-B beat count between line ticks is 0 for the interleave odd line and 80 otherwise (the tick at the end of raster line L feeds display line L+2 - tb_pc9821_video_frame's +2 pipeline - and +2 preserves parity), and pc9821_crtc's gfx_odd_line must equal MODE-FF1-bit-4 && vline[0] at every tick. Case 1 is the 400-line control (bit 4 clear): every line composite, so a fix that hid graphics unconditionally cannot pass. FAIL-FIRST: the space rows' odd lines must read black and the odd ticks must count zero fetches; the pre-fix scanout composites and fetches both raster lines of a doubled GDC line. The file drives the fix's new seam (crtc gfx_odd_line -> gvram/mixer), so it cannot BUILD on the pre-change tree; the fail-first run is this exact file against the fix's interface with the two behaviour terms at their pre-fix form (bit-identical behaviour to the pre-change tree). Not covered: the text plane's own 200-line programming (glyphs are bench-loaded) and the one-frame-pair residual when MODE FF1 bit 4 flips in the ticks that arm rows 0/1.
//
// The 200-line graphics/text interleave as NP2kai renders it. With MODE FF1 bit 4 (the
// FF1 200-line flag, port 0x68) set, graphics appear on EVEN display lines only and ODD
// lines carry TEXT ONLY over BLACK: NP2kai fetches a display line only
// `if ((!(mg.liney & 1)) || (!(gdc.mode1 & 0x10)))` (vram/makegrph.c:155) and its p_2i
// draw paints the odd line of each pair as `SDSETPIXEL(r, (q[x] >> 4) + NP2PAL_TEXT)`
// with the graphics plane absent (vram/sdraw.mcr:199-243; the interleave draw row is
// selected by `sdrawfn += 4` on `gdc.mode1 & 0x10`, vram/scrndraw.c:227). A doubled GDC
// line is therefore NOT two copies of one picture line: the even raster line of the pair
// shows graphics + text and the odd one text over black.
//
// The scene is driven end to end through the REAL modules wired exactly as
// pc9821_system.sv wires them - pc9821_gdc_text_dut (raster, MODE FF1, text render,
// GDC2 line origin) + pc9821_gvram_dut (line fetch + ping-pong buffer) +
// pc9821_video_mixer (fold + palette + compositor) - over a LINE-UNIFORM scene so every
// active dot of every line has one expected colour:
//   - even text rows hold a full-block glyph (the bench loads ANK 'A' as all-on 8x16)
//     with attribute 0xE1 = visible + colour 7: every dot of those lines is WHITE;
//   - odd text rows hold a space (the bench loads ANK ' ' as all-off): every dot is
//     the graphics colour where graphics show and BLACK on a 200-line odd line.
// Expected values, all from NP2kai / the ITF ROM, none from our RTL:
//   white  = the fixed 8-colour text table entry attr[7:5] = 7 = all bits (degal1[7],
//            vram/palettes.c:93-101 pal_makeskiptable) -> 0xFFFFFF by nibble
//            replication (anapal1[i] = i * 0x11, vram/palettes.c:102-106);
//   red    = every GVRAM dot folds to palette index 2 ({E,G,R,B} = 0010, the red
//            plane only) and the power-on analogue table's entry 2 is 12'h700
//            (itf.rom 0x042F = NP2kai defanapal, io/gdc.c:55-56) -> 0x770000;
//   black  = p_2i's `(q[x] >> 4) + NP2PAL_TEXT` with a transparent dot indexes
//            NP2PAL_TEXT entry 0, which pal_maketext fills from degpal1[0] = black
//            (vram/palettes.c:339-352).
// It also pins the FETCH side (makegrph.c:155): the gvram port-B beat count between
// line ticks must be 0 for the interleave odd line and 80 otherwise - the tick at the
// end of raster line L feeds display line L+2 (the +2 pipeline tb_pc9821_video_frame
// pins) and +2 preserves parity - and pc9821_crtc's gfx_odd_line output must agree with
// the rule at every tick. Case 1 is the 400-line control (MODE FF1 bit 4 clear): every
// line is the composite there, so a fix that hid graphics unconditionally cannot pass.
//
// FAIL-FIRST: the space rows of the 200-line case's odd lines must read black and the
// odd ticks must count zero fetches; the pre-fix scanout composites graphics on both
// raster lines of a doubled GDC line and fetches both. NOTE on the fail-first run: this
// file drives the fix's new seam (pc9821_crtc gfx_odd_line -> pc9821_gvram_dut /
// pc9821_video_mixer), so unlike the "connects no new port" benches it cannot BUILD on
// the pre-change tree; the fail-first run is this exact
// file against the fix's interface with the two behaviour terms at their pre-fix form
// (grph_shown without `!gfx_odd_line`, fetch_active without it), which is bit-identical
// behaviour to the pre-change tree.
//
// Not covered here (out of the finding's scope): the text plane's own 200-line
// programming (the glyphs are bench-loaded so the text expectations come from the
// loaded bitmap), and the one-frame-pair residual when MODE FF1 bit 4 flips in the two
// ticks that arm display rows 0/1 (the same class as the accepted cfg-snap residual).

`default_nettype none

module tb_pc9821_interleave_200;
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
  // The raster GDC trio, clocked exactly as pc9821_system clocks it. It owns the raster,
  // MODE FF1, the text render and the GDC2 line origin.
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
  // The fix's seam: MODE FF1 bit 4 + the line's parity, produced by pc9821_crtc and
  // consumed by the line fetch and the compositor exactly as pc9821_system wires them.
  wire        gfx_odd_line;
  wire        gfx_mode16;
  wire [31:0] gfx_dig;
  wire        pal_wr_en;
  wire  [3:0] pal_wr_idx;
  wire  [1:0] pal_wr_chan;
  wire  [3:0] pal_wr_data;
  wire        pal_commit;
  wire        hs_out, vs_out, de_out;

  wire cg_rd_hold, cg_win_byte_hold;
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

  // The scanout: the four planes and their per-line fetch into the ping-pong line buffer.
  reg  [1:0]  win_plane = 2'd0;
  reg  [14:0] win_offset = 15'd0;
  reg  [31:0] cpu_din = 32'd0;
  reg  [3:0]  cpu_be = 4'hF;
  reg         cpu_line_read = 1'b0, cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0]  cpu_dout;
  wire [31:0] cpu_line_word;
  wire         cpu_ready, cpu_resp_valid, cpu_line_word_valid;
  reg          grcg_we = 1'b0;
  reg  [7:0]   grcg_addr = 8'd0, grcg_din = 8'd0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;
  wire [6:0]  line_rd_addr;
  wire        line_rd_sel;

  pc9821_gvram_dut #(.SYS_CLOCK_HZ(100_000_000)) u_gvram (
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
      .gfx_odd_line(gfx_odd_line),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));

  // The pixel pipeline, exactly as pc9821_system wires it.
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
      .gfx_odd_line(gfx_odd_line),
      .r_out(r_out), .g_out(g_out), .b_out(b_out)
  );

  // ==== STIMULUS ====
  integer errors = 0;
  integer i;

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

  task automatic write_tram(input [13:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      tram_cpu_addr = addr;
      tram_cpu_din = data;
      tram_cpu_we = 1;
      @(negedge clk);
      tram_cpu_we = 0;
    end
  endtask

  task automatic write_font(input [17:0] addr, input [15:0] data);
    begin
      @(negedge clk);
      font_ld_addr = addr;
      font_ld_data = data;
      font_ld_we = 1;
      @(negedge clk);
      font_ld_we = 0;
    end
  endtask

  // The GDC2 SCROLL transaction (tb_pc9821_scanout_frame_base's encoder, warranted there
  // against NP2kai bios/bios18.c:172-205 and vram/makegrex.c:32-35).
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

  task automatic spin_frame;
    begin
      while (u_gdc.u_crtc.frame_end) @(negedge clk_sys);
      while (!u_gdc.u_crtc.frame_end) @(negedge clk_sys);
    end
  endtask

  // ---- the expected colours (NP2kai / ITF ROM, never our RTL) ----
  // The power-on analogue table the ITF ROM writes (itf.rom 0x042F = NP2kai defanapal),
  // as {R,G,B} nibbles - tb_pc9821_scanout_pipeline's transcription.
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

  // The scene is LINE UNIFORM: text row = vline >> 4, even rows are the full-block glyph
  // (attribute 0xE1 = colour 7 = white on every dot) and odd rows the space (no lit dot).
  function automatic [23:0] want_rgb(input [8:0] L, input m200);
    begin
      if (!L[4]) want_rgb = 24'hFFFFFF;              // block row: the lit glyph dot wins
      else if (m200 && L[0]) want_rgb = 24'h000000;  // p_2i: odd line = text over black
      else want_rgb = expand8(itf_entry(4'd2));      // graphics index 2 = red
    end
  endfunction

  // ---- the pixel checker: one sample per active dot at the pixel enable ----
  // Sampled at the clk_sys edge where pixel_ce is high, reading hdot/vline/r_out as the
  // pre-edge (current dot) values - tb_pc9821_scanout_pipeline's capture convention.
  integer pix_checked = 0;
  integer pix_errors = 0;
  reg     check_pixels = 1'b0;
  reg     exp_200 = 1'b0;   // MODE FF1 bit 4 as THIS bench programmed it
  reg [23:0] want;
  always @(posedge clk) begin
    if (check_pixels && pixel_ce && pix_h_active && pix_v_active) begin
      pix_checked = pix_checked + 1;
      want = want_rgb(u_gdc.u_crtc.vline, exp_200);
      if ({r_out, g_out, b_out} !== want) begin
        pix_errors = pix_errors + 1;
        if (pix_errors <= 12)
          $display("FAIL pixel vline=%0d hdot=%0d got %02x%02x%02x want %06x (%0s mode, %0s line, %0s row)",
                   u_gdc.u_crtc.vline, u_gdc.u_crtc.hdot, r_out, g_out, b_out, want,
                   exp_200 ? "200" : "400", u_gdc.u_crtc.vline[0] ? "odd" : "even",
                   u_gdc.u_crtc.vline[4] ? "space" : "block");
      end
    end
  end

  // ---- the fetch checker: the gvram port-B beats between line ticks ----
  // The interval after the tick at the end of raster line L is the fetch that FEEDS
  // display line L+2 (tb_pc9821_video_frame's +2 pipeline), so it must be skipped iff
  // that display line is a 200-line interleave odd line - parity(L) = parity(L+2), which
  // is what makes pc9821_crtc's gfx_odd_line (MODE FF1 bit 4 && vline[0]) the right
  // sample at the tick. 80 beats per fetched line (80 four-plane columns, one per
  // clk_sys), 0 for a skipped one.
  integer beats = 0;
  integer fetch_checked = 0;
  integer fetch_errors = 0;
  reg     check_fetches = 1'b0;
  reg [8:0] armed_vline = 9'd0;
  reg       armed_in_window = 1'b0;
  integer exp_beats;
  always @(posedge clk) begin
    if (scan_line_tick) begin
      if (armed_in_window) begin
        fetch_checked = fetch_checked + 1;
        exp_beats = (exp_200 && armed_vline[0]) ? 0 : 80;
        if (beats !== exp_beats) begin
          fetch_errors = fetch_errors + 1;
          if (fetch_errors <= 8)
            $display("FAIL fetch armed at tick vline=%0d: %0d port-B beats, expected %0d (%0s mode)",
                     armed_vline, beats, exp_beats, exp_200 ? "200" : "400");
        end
      end
      // The seam itself: the flag + parity pc9821_crtc produces at the arming tick.
      if (check_fetches && (gfx_odd_line !== (exp_200 && u_gdc.u_crtc.vline[0]))) begin
        fetch_errors = fetch_errors + 1;
        $display("FAIL gfx_odd_line=%b at tick vline=%0d, expected %b (MODE FF1 bit 4 = %b)",
                 gfx_odd_line, u_gdc.u_crtc.vline, exp_200 && u_gdc.u_crtc.vline[0], exp_200);
      end
      armed_vline = u_gdc.u_crtc.vline;
      armed_in_window = check_fetches;
      beats = 0;
    end else if (u_gvram.u_scan.gmb_en) beats = beats + 1;
  end

  // One frame of checking: pixels cover display lines 0..399 exactly (the window runs
  // from vline 439 dot 800 to vline 400) and fetches cover 440 line-tick intervals - the
  // window holds the opening tick (label 439) plus one whole frame of arming ticks
  // (labels 0..438), and each interval's assertion is kept by armed_in_window even when
  // it lands on the closing tick.
  task automatic check_frame;
    begin
      wait (u_gdc.u_crtc.vline == 9'd439 && u_gdc.u_crtc.hdot == 10'd800);
      pix_checked = 0; pix_errors = 0;
      fetch_checked = 0; fetch_errors = 0;
      check_pixels = 1'b1;
      check_fetches = 1'b1;
      wait (u_gdc.u_crtc.vline == 9'd400);
      check_pixels = 1'b0;
      wait (u_gdc.u_crtc.vline == 9'd439 && u_gdc.u_crtc.hdot == 10'd800);
      check_fetches = 1'b0;
      wait (u_gdc.u_crtc.vline == 9'd0);
      if (pix_checked !== 256000)
        fail("pixel checker did not see exactly 400 x 640 active dots");
      if (fetch_checked !== 440)
        fail("fetch checker did not see exactly 440 line-tick intervals");
      errors = errors + pix_errors + fetch_errors;
      if (pix_errors == 0 && fetch_errors == 0)
        $display("  ok: %0d dots and %0d line fetches as expected (%0s mode)",
                 pix_checked, fetch_checked, exp_200 ? "200-line" : "400-line");
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    reset <= 1'b0;
    repeat (4) @(posedge clk);

    // GVRAM: every dot of every column folds to index 2 ({E,G,R,B} = 0010, plane 1 =
    // red only), so a graphics pixel is itf_entry(2) = 12'h700 -> 0x770000 and a leaked
    // one cannot be mistaken for the black background or the white text.
    for (i = 0; i < 32768; i = i + 1) begin
      u_gvram.u_gmem.mem0[i] = 8'h00;   // plane 0 = blue
      u_gvram.u_gmem.mem1[i] = 8'hFF;   // plane 1 = red
      u_gvram.u_gmem.mem2[i] = 8'h00;   // plane 2 = green
      u_gvram.u_gmem.mem3[i] = 8'h00;   // plane 3 = intensity
    end

    // Text: the whole plane is space cells (code 0x20, loaded all-off) EXCEPT the even
    // cell rows, whose code 0x41 ('A', loaded all-on as a full block) draws every dot
    // in attribute 0xE1's colour (visible, colour 7 = white).
    for (i = 0; i < 8; i = i + 1) begin
      write_font(18'h208 + i[17:0], 16'hFFFF);   // ANK 'A' (code * 8 + word)
      write_font(18'h100 + i[17:0], 16'h0000);   // ANK ' '
    end
    for (i = 0; i < 4096; i = i + 1) begin
      write_tram(i[13:0] * 2,           ((i / 80) & 1) ? 8'h20 : 8'h41);
      write_tram(i[13:0] * 2 + 14'd1,   8'h00);
      write_tram(14'h2000 + i[13:0] * 2, 8'hE1);
    end

    // The mode-set shape: text GDC START, analogue palette, GDC2 START, and MODE FF1
    // bit 4 CLEAR = the 400-line display (bit = (dat>>1)&7, on = dat&1; the power-on
    // byte is 0x98 = FONTSEL|200LINE|DISP).
    write_io(8'h62, 8'h0D);
    write_io(8'h6A, 8'h01);
    write_io(8'hA2, 8'h0D);
    write_io(8'h68, 8'h08);
    wait (u_gdc.u_crtc.vline == 9'd410);
    write_scroll(15'd0, 14'd400);

    // Let the text row cache walk and the configuration latch.
    repeat (3) spin_frame;

    // ---------------------------------------------------------------
    // Case 1. 400-line mode (MODE FF1 bit 4 clear): every line is text over
    //         graphics, even and odd alike. The control an unconditional
    //         "hide graphics on odd lines" fix fails.
    // ---------------------------------------------------------------
    exp_200 = 1'b0;
    check_frame;

    // ---------------------------------------------------------------
    // Case 2. 200-line mode (MODE FF1 bit 4 set) with the doubled line repeat
    //         (slave CSRFORM lr-1 = 1) and a 200-line SCROLL: the NP2kai
    //         interleave. Even lines composite, odd lines are text over black,
    //         and the odd line's fetch does not run. THE FAIL-FIRST assertions.
    // ---------------------------------------------------------------
    wait (u_gdc.u_crtc.vline == 9'd410);
    write_io(8'h68, 8'h09);       // FF1 bit 4 SET
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h01);       // lr-1 = 1: each GDC line on two raster lines
    write_scroll(15'd0, 14'd200);
    exp_200 = 1'b1;
    repeat (3) spin_frame;
    check_frame;

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_INTERLEAVE_200: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_INTERLEAVE_200: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: a frame is ~8.9 ms of simulated time and the run is about ten
  // of them plus the TRAM fill; 200 ms leaves headroom (the sibling scanout bench's
  // bound is 100 ms for six frames).
  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_INTERLEAVE_200: TIMEOUT");
  end

endmodule

`default_nettype wire

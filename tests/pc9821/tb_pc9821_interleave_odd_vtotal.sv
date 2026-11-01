`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The 200-line graphics/text interleave on an ODD VTOTAL (441: defsyncm24 with one added back-porch line, y = lf + vs + vfp + vbp per NP2kai io/gdc.c:370-444). NP2kai keys both the fetch skip and the odd-line draw on the DISPLAY LINE parity (vram/makegrph.c:155, vram/sdraw.mcr:199-243 p_2i), but our scanout's tick at the end of raster line L feeds display line (L+2) mod VTOTAL (the +2 pipeline) and the wrap SUBTRACTS the odd VTOTAL, flipping parity at the two end-of-frame ticks: the fetch gate must key on the FEED line's parity or display line 0 loses its fetch and shows the stale ping-pong buffer at the top of every frame. Byte-exact frame over a scene where the loss is unmistakable (all-transparent bench-loaded space text; GVRAM row 0 = ITF blue itf_entry(1), every other row = ITF red itf_entry(2), itf.rom 0x042F = NP2kai defanapal; SCROLL start 0 / lines 0 never expires - makegrex.c:35-51 - with CSRFORM lr-1 = 0 so display line L shows GDC row L (deliberate: the lr = 2 pairing MASKS the loss behind its pair partner's identical row - observed on the pre-fix tree): line 0 must be blue, even lines 2..398 red, odd lines black, the port-B beat count 80 or 0 per tick by the FEED line's parity, and pc9821_crtc's gfx_odd_line must carry the feed parity AT THE TICK. FAIL-FIRST on the pre-fix tree (this file builds and runs unchanged there): the pixel check at vline 0, the wrap-tick beat counts at vline 439/440 and the seam value at those ticks all fire. Expected values from NP2kai and the ITF ROM only; the SYNC arithmetic is tb_pc9821_gdc_sync_raster's np2_sync_geometry, the +2 pipeline tb_pc9821_video_frame's, the even-VTOTAL interleave tb_pc9821_interleave_200's.
//
// The 200-line graphics/text interleave survives an ODD VTOTAL at the frame wrap. The
// interleave rule itself is NP2kai's: with MODE FF1 bit 4 set a display line is fetched
// only `if ((!(mg.liney & 1)) || (!(gdc.mode1 & 0x10)))` (vram/makegrph.c:155) and the
// odd line of each pair is painted as text over BLACK with the graphics plane absent
// (vram/sdraw.mcr:199-243 p_2i; the interleave draw row is selected by `sdrawfn += 4` on
// `gdc.mode1 & 0x10`, vram/scrndraw.c:227). Both halves key on the DISPLAY LINE
// (mg.liney) parity - nothing in NP2kai knows a frame length.
//
// OUR scanout runs two raster lines ahead of the display: the line tick at the end of
// raster line L FEEDS display line (L + 2) mod VTOTAL (the +2 pipeline tb_pc9821_video_frame
// pins; the wrap is pc9821_gdc2's v_oline). For an EVEN VTOTAL the +2 wrap preserves
// parity and one gate value - the showing line's parity - serves both the fetch sample
// (the tick) and the pixel sample (the active dots). For an ODD VTOTAL the wrap
// SUBTRACTS an odd number and FLIPS parity: the tick on line VTOTAL-2 feeds display
// line 0 and the tick on VTOTAL-1 feeds line 1. A guest reaches an odd VTOTAL through
// the master GDC's SYNC block (y = lf + vs + vfp + vbp, NP2kai io/gdc.c:370-444) - one
// extra back-porch line turns the 440-line default into 441 - so the fetch gate must key
// on the parity of the line the tick FEEDS or display line 0 loses its fetch and shows
// the stale ping-pong buffer at the top of every frame.
//
// The scene is engineered so every expectation is a fixed colour and the lost line is
// unmistakable: all text cells are bench-loaded spaces (transparent), GVRAM row 0 folds
// to palette index 1 (blue) and every other row to index 2 (red), and the slave SCROLL
// is start 0 / lines 0 = the partition never expires (our gdc2's g_no_switch; NP2kai
// `remain = 0` wraps through 0xffffffff and runs to the screen end, makegrex.c:35-51),
// with CSRFORM lr-1 = 0 so display line L shows GDC row L exactly as makegrph.c's vad
// advances (every lr display lines, :176-180). lr = 1 is deliberate: with the usual
// lr = 2 the loss is MASKED - display lines 0 and 1 fetch the same GVRAM row, so the
// skipped top-line fetch falls back to a same-row write and reads correct-looking
// pixels (observed on the pre-fix tree). With lr = 1 the stale fallback is display
// line 1's row and reads red where blue belongs. Expected pixels, all from NP2kai /
// the ITF ROM, none from our RTL:
//   odd display line (L[0])  = black   p_2i `(q[x] >> 4) + NP2PAL_TEXT` with a
//                                transparent dot indexes NP2PAL_TEXT entry 0 =
//                                degpal1[0] (vram/palettes.c:485, :350);
//   display line 0 (row 0)   = 0x000077  fold index {E,G,R,B} = 0001 = the red-off
//                                blue plane; itf_entry(1) = 12'h007 (itf.rom 0x042F =
//                                NP2kai defanapal, io/gdc.c:57-59), expanded by nibble
//                                replication (anapal1[i] = i * 0x11, palettes.c:107-111);
//   any even line 2..398     = 0x770000  fold index 0010, itf_entry(2) = 12'h700.
// The stale top line cannot fake 0x000077: every other GVRAM row is red and the pre-fix
// slot's last real write is display line 1's fetch.
//
// It also pins the FETCH side byte-count-exactly (makegrph.c:155): between line ticks the
// gvram port-B beat count must be 0 when the FEED line (armed_vline + 2) mod VTOTAL is
// odd and 80 otherwise, and pc9821_crtc's gfx_odd_line must equal MODE-FF1-bit-4 &&
// that feed-line parity AT THE TICK (and the pixel path, checked by the dot-exact
// comparison, is bit-identical to the showing-line parity it always had).
//
// FAIL-FIRST (this file builds and runs UNCHANGED on the pre-fix tree): the pre-fix gate
// is `v_mode1_200 && vline[0]` sampled at the tick, i.e. the parity of the line ENDING
// rather than of the line FED, so at VTOTAL 441 the tick on line 439 skips display line
// 0's fetch and the tick on line 440 fetches display line 1 that the mixer hides. The
// named failing assertions are the pixel check at vline 0 ("FAIL pixel vline=0 ..."),
// the two wrap-tick beat counts ("FAIL fetch armed at tick vline=439/440 ...") and the
// seam value at those ticks ("FAIL gfx_odd_line=... at tick vline=439 ...").
//
// Not covered (the sibling benches own them): the 400-line control (tb_pc9821_interleave_200
// case 1) and the even-VTOTAL interleave (its case 2), the SYNC block's own arithmetic
// (tb_pc9821_gdc_sync_raster, whose np2_sync_geometry is the warrant for 441 here), the
// +2 pipeline itself (tb_pc9821_video_frame) and the frame-latched rows 0/1 snapshot
// residual (tb_pc9821_scanout_frame_base).

`default_nettype none

module tb_pc9821_interleave_odd_vtotal;
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
  // The raster GDC trio, clocked exactly as pc9821_system clocks it. It owns the raster
  // (and the guest SYNC block this bench programs), MODE FF1, the text render and the
  // GDC2 line origin.
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
  // The interleave seam: MODE FF1 bit 4 + the parity of the display line the SAMPLE
  // POINT is about - the showing line in the active dots, the FED line at the line tick
  // (pc9821_crtc). Consumed by the line fetch and the compositor exactly as
  // pc9821_system wires them.
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

  // ==== THE GUEST GEOMETRY THIS CASE PROGRAMS (NP2kai's names) ====
  // The SYNC block below is defsyncm24 (io/gdc.c:47) with ONE extra back-porch line:
  // para = {10 4e 07 25 07 07 90 69} -> cr 80, hs 7, vs 8, hfp 9+7, vfp 7, lf 400,
  // vbp 26 (tmp2 = 0x6990: lf = ((tmp2-1) & 0x3ff) + 1 = 400, vbp = tmp2 >> 10 = 26),
  // so x = 80+7+16+3 = 106 -> HTOTAL 848 (unchanged) and y = 400+8+7+26 = 441: an ODD
  // frame length inside the 24 kHz clamp's 400..575 (io/gdc.c:34). The whole
  // transcription is warranted in tb_pc9821_gdc_sync_raster's np2_sync_geometry.
  localparam integer B_HTOTAL  = 848;
  localparam integer B_VTOTAL  = 441;
  localparam integer B_VACTIVE = 400;

  // The display line a tick's fetch feeds: the +2 pipeline (the tick at the end of
  // raster line L feeds display line L+2) with the frame wrap, mod the GUEST's VTOTAL.
  function automatic parity_feed(input [9:0] L);
    begin
      parity_feed = (((L + 2) % B_VTOTAL) & 1);
    end
  endfunction

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
  // against NP2kai bios/bios18.c:172-205 and vram/makegrex.c:32-35). lines = 0 is the
  // never-expiring partition 1: our gdc2's g_no_switch_w (g_lines1_w == 0) and NP2kai's
  // `remain = 0` -> 0xffffffff countdown both run the start to the screen end.
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

  // The guest's SYNC transaction: the command byte on 0x62, then the block's eight bytes
  // on 0x60 in arrival order (NP2kai gdc_work stores each into para[ptr++],
  // io/gdc.c:341-345). 0x0F is the SYNC_ON form (tb_pc9821_gdc_sync_raster's encoder).
  task automatic write_sync;
    begin
      write_io(8'h62, 8'h0F);
      write_io(8'h60, 8'h10);
      write_io(8'h60, 8'h4e);
      write_io(8'h60, 8'h07);
      write_io(8'h60, 8'h25);
      write_io(8'h60, 8'h07);
      write_io(8'h60, 8'h07);
      write_io(8'h60, 8'h90);
      write_io(8'h60, 8'h69);
    end
  endtask

  task automatic spin_frame;
    begin
      while (u_gdc.u_crtc.frame_end) @(negedge clk_sys);
      while (!u_gdc.u_crtc.frame_end) @(negedge clk_sys);
    end
  endtask

  // ---- the expected colours (NP2kai / ITF ROM, never our RTL) ----
  // The power-on analogue table the ITF ROM writes (itf.rom 0x042F = NP2kai defanapal,
  // io/gdc.c:57-59), as {R,G,B} nibbles - tb_pc9821_scanout_pipeline's transcription.
  // LAYOUT NOTE: NP2kai decodes a defanapal word as {G,R,B} - (pal>>8)->g, (pal>>4)->r,
  // (pal>>0)->b (io/gdc.c:125-131) - while this table transcribes the SAME colours as
  // {R,G,B} nibbles, so a literal comparison looks shifted: entry 2 reads 0x070 in the
  // defanapal array but 12'h700 here - the same red either way.
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

  // LINE UNIFORM per display line: odd lines are the p_2i black, display line 0 is GVRAM
  // row 0 (blue) and every other even line its row (red) - see the header's scene.
  function automatic [23:0] want_rgb(input [9:0] L);
    begin
      if (L[0])       want_rgb = 24'h000000;          // p_2i: odd line = text over black
      else if (L == 10'd0) want_rgb = expand8(itf_entry(4'd1));  // GVRAM row 0 = blue
      else                 want_rgb = expand8(itf_entry(4'd2));  // every other row = red
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
      want = want_rgb(u_gdc.u_crtc.vline);
      if ({r_out, g_out, b_out} !== want) begin
        pix_errors = pix_errors + 1;
        if (pix_errors <= 12)
          $display("FAIL pixel vline=%0d hdot=%0d got %02x%02x%02x want %06x (%0s mode, %0s line, row %0d)",
                   u_gdc.u_crtc.vline, u_gdc.u_crtc.hdot, r_out, g_out, b_out, want,
                   exp_200 ? "200" : "400", u_gdc.u_crtc.vline[0] ? "odd" : "even",
                   u_gdc.u_crtc.vline);   // lr-1 = 0: display line L IS GVRAM row L
      end
    end
  end

  // ---- the fetch checker: the gvram port-B beats between line ticks ----
  // The interval after the tick at the end of raster line L is the fetch that FEEDS
  // display line (L + 2) % B_VTOTAL (tb_pc9821_video_frame's +2 pipeline), so it must be
  // skipped iff THAT display line is a 200-line interleave odd line (makegrph.c:155).
  // 80 beats per fetched line (80 four-plane columns, one per clk_sys), 0 for a skipped
  // one. The parity is the FEED line's: with B_VTOTAL odd the wrap flips it against
  // armed_vline[0] exactly at the two end-of-frame ticks.
  integer beats = 0;
  integer fetch_checked = 0;
  integer fetch_errors = 0;
  reg     check_fetches = 1'b0;
  reg [9:0] armed_vline = 10'd0;
  reg       armed_in_window = 1'b0;
  integer exp_beats;
  integer feed_L;
  always @(posedge clk) begin
    if (scan_line_tick) begin
      if (armed_in_window) begin
        fetch_checked = fetch_checked + 1;
        feed_L = (armed_vline + 2) % B_VTOTAL;
        exp_beats = (exp_200 && (feed_L & 1)) ? 0 : 80;
        if (beats !== exp_beats) begin
          fetch_errors = fetch_errors + 1;
          if (fetch_errors <= 8)
            $display("FAIL fetch armed at tick vline=%0d: %0d port-B beats, expected %0d (feeds display line %0d, %0s mode)",
                     armed_vline, beats, exp_beats, feed_L, exp_200 ? "200" : "400");
        end
      end
      // The seam itself: at the tick the flag carries the parity of the line the tick
      // FEEDS - (vline + 2) % B_VTOTAL - not of vline (the +2 flips parity at the wrap
      // of an odd VTOTAL).
      if (check_fetches &&
          (gfx_odd_line !== (exp_200 && parity_feed(u_gdc.u_crtc.vline)))) begin
        fetch_errors = fetch_errors + 1;
        $display("FAIL gfx_odd_line=%b at tick vline=%0d (feeds display line %0d), expected %b (MODE FF1 bit 4 = %b)",
                 gfx_odd_line, u_gdc.u_crtc.vline,
                 (u_gdc.u_crtc.vline + 2) % B_VTOTAL,
                 exp_200 && parity_feed(u_gdc.u_crtc.vline), exp_200);
      end
      armed_vline = u_gdc.u_crtc.vline;
      armed_in_window = check_fetches;
      beats = 0;
    end else if (u_gvram.u_scan.gmb_en) beats = beats + 1;
  end

  // One frame of checking: pixels cover display lines 0..399 exactly and fetches cover
  // B_VTOTAL = 441 line-tick intervals - the window holds the opening tick (label
  // VTOTAL-2 = 439, the tick that feeds display line 0) plus one whole frame of arming
  // ticks (labels 440, 0..438), and each interval's assertion is kept by
  // armed_in_window even when it lands on the closing tick.
  task automatic check_frame;
    begin
      wait (u_gdc.u_crtc.vline == 10'd439 && u_gdc.u_crtc.hdot == 10'd800);
      pix_checked = 0; pix_errors = 0;
      fetch_checked = 0; fetch_errors = 0;
      check_pixels = 1'b1;
      check_fetches = 1'b1;
      wait (u_gdc.u_crtc.vline == 10'd400);
      check_pixels = 1'b0;
      wait (u_gdc.u_crtc.vline == 10'd439 && u_gdc.u_crtc.hdot == 10'd800);
      check_fetches = 1'b0;
      wait (u_gdc.u_crtc.vline == 10'd0);
      if (pix_checked !== 256000)
        fail("pixel checker did not see exactly 400 x 640 active dots");
      if (fetch_checked !== 441)
        fail("fetch checker did not see exactly 441 line-tick intervals");
      errors = errors + pix_errors + fetch_errors;
      if (pix_errors == 0 && fetch_errors == 0)
        $display("  ok: %0d dots and %0d line fetches as expected (200-line mode, VTOTAL %0d)",
                 pix_checked, fetch_checked, B_VTOTAL);
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    reset <= 1'b0;
    repeat (4) @(posedge clk);

    // GVRAM: row 0 (plane offsets 0..79 - the fetch reads row r from offsets r*80, the
    // GDC2_ROW_BYTES of one GDC line) folds to index 1 = ITF blue, and EVERYTHING else
    // to index 2 = ITF red. A lost or stale display line 0 cannot read blue: the stale
    // ping-pong slot falls back to display line 1's fetch (row 1 = red) on the pre-fix
    // tree.
    for (i = 0; i < 32768; i = i + 1) begin
      u_gvram.u_gmem.mem0[i] = 8'h00;   // plane 0 = blue
      u_gvram.u_gmem.mem1[i] = 8'hFF;   // plane 1 = red
      u_gvram.u_gmem.mem2[i] = 8'h00;   // plane 2 = green
      u_gvram.u_gmem.mem3[i] = 8'h00;   // plane 3 = intensity
    end
    for (i = 0; i < 80; i = i + 1) begin
      u_gvram.u_gmem.mem0[i] = 8'hFF;   // row 0 = index 1 = blue
      u_gvram.u_gmem.mem1[i] = 8'h00;
    end

    // Text: the whole plane is space cells (code 0x20, loaded all-off) with attribute
    // 0xE1 = visible + colour 7 - a transparent glyph everywhere, so every dot shows
    // the graphics plane or the interleave black. The boot cursor is disabled
    // (csr_form[0] = 0x0F power-on) so nothing lights a text dot.
    for (i = 0; i < 8; i = i + 1)
      write_font(18'h100 + i[17:0], 16'h0000);   // ANK ' '
    for (i = 0; i < 4096; i = i + 1) begin
      write_tram(i[13:0] * 2,           8'h20);
      write_tram(14'h2000 + i[13:0] * 2, 8'hE1);
    end

    // The mode-set shape: the guest's SYNC block FIRST (the odd VTOTAL the case is
    // about; the raster latches it at the next frame boundary), then text GDC START,
    // analogue palette, GDC2 START, MODE FF1 bit 4 SET = the 200-line interleave
    // (bit = (dat>>1)&7, on = dat&1), and the slave CSRFORM lr-1 = 0: one GDC row per
    // display line (the lr = 2 pairing would MASK the lost top-line fetch behind its
    // pair partner's identical row - see the header).
    write_sync;
    write_io(8'h62, 8'h0D);
    write_io(8'h6A, 8'h01);
    write_io(8'hA2, 8'h0D);
    write_io(8'h68, 8'h09);
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h00);
    wait (u_gdc.u_crtc.vline == 10'd410);
    write_scroll(15'd0, 14'd0);
    exp_200 = 1'b1;

    // Let the text row cache walk and the configuration latch.
    repeat (3) spin_frame;

    // ---------------------------------------------------------------
    // The case: 200-line mode on an ODD 441-line frame. Byte-exact: display line 0
    // must be GVRAM row 0's blue (the wrap-tick fetch), even lines 2..398 their rows'
    // red, odd lines black, and the fetch beats must skip exactly the ticks that feed
    // an odd display line. THE FAIL-FIRST assertions.
    // ---------------------------------------------------------------
    check_frame;

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_INTERLEAVE_ODD_VTOTAL: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_INTERLEAVE_ODD_VTOTAL: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: a frame is ~9 ms of simulated time and the run is about seven of
  // them plus the TRAM fill; 250 ms leaves headroom.
  initial begin
    #250_000_000;
    $fatal(1, "TB_PC9821_INTERLEAVE_ODD_VTOTAL: TIMEOUT");
  end

endmodule

`default_nettype wire

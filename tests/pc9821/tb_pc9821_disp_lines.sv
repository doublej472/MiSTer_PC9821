`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The displayed picture height, the text rows and the planar walk of the 31 kHz BIOS blocks follow the GDC SYNC blocks as NP2kai derives them (vram/dispsync.c dispsync_renewalvertical: textymax from the master's lf, grphymax from the slave's lf, `scrnymax = MAX(grphymax, textymax)`), driven through the real pc9821_crtc and pc9821_gdc2 by the guest's own 0x62/0x60 and 0xA2/0xA0 transactions with the bytes of NP2kai bios/bios18.c: (1) the 640x480 25-row block (master 10 4E 4B 0C 03 0B DB 95 = 800 x 525 with lf 475, slave 02 4E 4B 0C 83 06 E0 95 with lf 480) displays 480 lines with the slave SYNCed and STARTed (the taller of the two windows), its VSYNC pulse rising on the master's line 486; (2) the 30-row 640x480 block (master gdcmastersync[5] 10 4E 4B 0C 03 06 E0 95, lf 480, 800 x 525, CSRFORM 0F 00 7B as bios0x18_30 writes it from crtdata[6], the CRTC at its 16-line row defaults) displays 480 lines in 30 text rows of 16 lines, line y being row y>>4 font line y&15, VSYNC rising on line 486; (3) the planar 640x400 31 kHz block (master 10 4E 47 0C 07 0D 90 89 = 800 x 449, slave 02 4E 47 0C 87 0D 90 89) displays 400 lines in a 449-line frame with the walk presenting the address y*80 for every decode line y, including the first lines of the odd-length frame after its wrap, VSYNC rising on line 413. All expected values are computed in the bench from the block bytes by a transcription of NP2kai gdc_updateclock and dispsync_renewalvertical and maketext.c, never read from the DUT. FAIL-FIRST: with the displayed lines limited to the master's window case 1 shows 475 lines where NP2kai shows 480; with the planar walker stepping on the line parity alone, the 449-line frame shows the lines below the wrap one raster line late; with the text row index counted from a 25-row constant the 30-row block stops at row 24.
//
// The expected values are NP2kai's (vram/dispsync.c, vram/maketext.c, io/gdc.c, bios/bios18.c),
// computed in the bench from the block bytes. See the claim above; the cases are numbered 1-3 in CHECKS.

module tb_pc9821_disp_lines;
  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;
  wire clk_vid = clk_sys;
  reg pixel_ce = 1;
  reg rst_n_sys = 0, rst_n_vid = 0;
  reg io_wr = 0;
  reg io_rd = 0;
  reg [7:0] io_addr = 0, io_din = 0;
  wire [7:0] io_dout;
  wire gfx_access_page;
  wire [15:0] gfx_line_addr;
  wire gfx_walk_page;
  reg [13:0] tram_cpu_addr = 0;
  reg [7:0] tram_cpu_din = 0;
  reg tram_cpu_we = 0;
  wire [7:0] tram_cpu_dout;
  reg [10:0] font_ld_addr = 0;
  reg [15:0] font_ld_data = 0;
  reg font_ld_we = 0;
  wire vsync_active, disp_on;
  wire vsync_irq_arm = 1'b0, vsync_irq;
  wire vsync_edge;
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  wire       cfg_seed_reload = 1'b0;
  wire        text_opaque, text_cell;
  wire [11:0] text_colour;
  wire [9:0]  pix_dot;
  wire        pix_h_active, pix_v_active;
  wire        gfx_mode16;
  wire [31:0] gfx_dig;
  wire        pal_wr_en;
  wire [3:0]  pal_wr_idx;
  wire [1:0]  pal_wr_chan;
  wire [3:0]  pal_wr_data;
  wire        pal_commit;
  wire hs_out, vs_out, de_out;
  reg cg_record_restore = 0;
  reg [3:0] bios_set = 4'd0;
  wire [15:0] dbg_sad;
  wire  [7:0] dbg_pitch;
  wire        dbg_col40, dbg_disp;
  wire [15:0] dbg_wk_skips;
  wire  [4:0]  cg_win_byte_sel = 5'd0;
  wire         cg_win_rd       = 1'b0;
  wire         cg_win_we       = 1'b0;
  wire  [7:0]  cg_win_din      = 8'h00;
  wire  [7:0]  cg_win_dout;
  wire  [18:0] font_req_addr;
  wire         font_req;
  wire         font_word_valid = 1'b0;
  wire  [31:0] font_word_data  = 32'h0;
  wire         gfx_egc_gate;
  wire         gfx_disp;
  wire cg_rd_hold, cg_win_byte_hold;
  wire gfx_odd_line;
  reg [2:0] cfg_fdd_mode = 3'd0;

  // ==== DUT ====
  pc9821_gdc_text_dut dut (.*);

  integer errors = 0;

  // ==== NP2kai's arithmetic, transcribed (the expected values come only from here) ====
  // A SYNC block, the eight parameter bytes in arrival order (para[GDC_SYNC + i]).
  reg [7:0] mb [0:7];   // the master's block
  reg [7:0] sb [0:7];   // the slave's block
  integer e_lf_m, e_vbp_m, e_vfp_m, e_vs_m, e_y_m;
  integer e_lf_s, e_vbp_s;
  integer e_textymax, e_grphymax, e_disp;
  integer e_vtotal, e_rise;

  // io/gdc.c gdc_updateclock(): lf = ((word(para[6..7]) - 1) & 0x3ff) + 1, vbp = word >> 10,
  // vfp = para[5] & 0x3f, vs = (word(para[2..3]) >> 5) & 0x1f, y = lf + vs + vfp + vbp
  // (1 when all three are zero), clamped to the 24 kHz range 400..575 (gdcclk[1]).
  task automatic np2_expect;
    integer tmp, tmp2, vfbs, y_raw;
    begin
      tmp  = mb[2] | (mb[3] << 8);
      tmp2 = mb[6] | (mb[7] << 8);
      e_lf_m  = ((tmp2 - 1) & 10'h3ff) + 1;
      e_vbp_m = tmp2 >> 10;
      e_vfp_m = mb[5] & 6'h3f;
      e_vs_m  = (tmp >> 5) & 5'h1f;
      vfbs = e_vs_m + e_vfp_m + e_vbp_m;
      if (vfbs == 0) vfbs = 1;
      y_raw = e_lf_m + vfbs;
      e_y_m = (y_raw < 400) ? 400 : (y_raw > 575) ? 575 : y_raw;
      e_vtotal = e_y_m;
      e_rise = e_lf_m + e_vfp_m;
      tmp2 = sb[6] | (sb[7] << 8);
      e_lf_s  = ((tmp2 - 1) & 10'h3ff) + 1;
      e_vbp_s = tmp2 >> 10;
      // vram/dispsync.c dispsync_renewalvertical(): the smaller back porch is subtracted from
      // both, then textymax = lf_m + text_vbp, grphymax = lf_s + grph_vbp, and the picture
      // is MAX(grphymax, textymax) lines (rounded UP to a multiple of 8 only for the
      // emulator's surface; the lines past the larger window are never drawn).
      e_textymax = e_lf_m + ((e_vbp_m >= e_vbp_s) ? (e_vbp_m - e_vbp_s) : 0);
      e_grphymax = e_lf_s + ((e_vbp_m >= e_vbp_s) ? 0 : (e_vbp_s - e_vbp_m));
      e_disp = (e_grphymax > e_textymax) ? e_grphymax : e_textymax;
    end
  endtask

  // ==== STIMULUS ====
  task automatic fail(input string message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic expect_eq(input integer got, input integer want, input string what);
    begin
      if (got !== want) begin
        $display("FAIL: %0s = %0d, want %0d", what, got, want);
        errors = errors + 1;
      end
    end
  endtask

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum;
      io_din  = data;
      io_wr   = 1'b1;
      @(negedge clk_sys);
      io_wr   = 1'b0;
    end
  endtask

  integer k;
  // The master's SYNC transaction (command 0x0F then eight bytes on 0x60) and the slave's
  // (command 0x0E - SYNC with DE off - then eight bytes on 0xA0).
  task automatic write_master_sync;
    begin
      write_io(8'h62, 8'h0F);
      for (k = 0; k < 8; k = k + 1) write_io(8'h60, mb[k]);
    end
  endtask
  task automatic write_slave_sync;
    begin
      write_io(8'hA2, 8'h0E);
      for (k = 0; k < 8; k = k + 1) write_io(8'hA0, sb[k]);
    end
  endtask

  task automatic next_frame();
    begin
      while (dut.u_crtc.frame_end) @(negedge clk_sys);
      while (!dut.u_crtc.frame_end) @(negedge clk_sys);
      wait (dut.u_crtc.vline == 0);
    end
  endtask

  // ==== DUT-side measurement: one entry per raster line of the recorded frame ====
  reg         rec = 1'b0;
  reg  [9:0]  r_vline;
  reg         r_de   [0:1023];   // a dot of the line carried DE
  reg  [15:0] r_addr [0:1023];   // gfx_line_addr at the line's first dot
  reg  [5:0]  r_k    [0:1023];   // the text row on screen
  reg  [6:0]  r_now  [0:1023];   // its font line
  reg  [9:0]  r_rise;
  reg         in_vs_d;
  integer     r_lines;
  always @(negedge clk_sys) if (rec) begin
    r_vline = dut.u_crtc.vline;
    if (de_out) r_de[r_vline] = 1'b1;
    if (dut.u_crtc.hdot == 10'd0) begin
      r_addr[r_vline] = gfx_line_addr;
      r_k[r_vline]    = dut.u_crtc.c_k;
      r_now[r_vline]  = dut.u_crtc.c_now;
    end
    if (dut.u_crtc.in_vsync && !in_vs_d) r_rise = r_vline;
    in_vs_d = dut.u_crtc.in_vsync;
    r_lines = r_vline + 1;
  end

  task automatic record_frame;
    integer i;
    begin
      for (i = 0; i < 1024; i = i + 1) r_de[i] = 1'b0;
      next_frame();
      rec = 1'b1;
      next_frame();
      rec = 1'b0;
    end
  endtask

  // Program both GDCs and settle: the block reaches the raster at a frame boundary.
  task automatic program_blocks(input slave_start);
    begin
      write_master_sync;
      write_slave_sync;
      if (slave_start) write_io(8'hA2, 8'h0D);
      next_frame(); next_frame(); next_frame();
    end
  endtask

  task automatic set_master(input [7:0] b0, b1, b2, b3, b4, b5, b6, b7);
    begin mb[0]=b0; mb[1]=b1; mb[2]=b2; mb[3]=b3; mb[4]=b4; mb[5]=b5; mb[6]=b6; mb[7]=b7; end
  endtask
  task automatic set_slave(input [7:0] b0, b1, b2, b3, b4, b5, b6, b7);
    begin sb[0]=b0; sb[1]=b1; sb[2]=b2; sb[3]=b3; sb[4]=b4; sb[5]=b5; sb[6]=b6; sb[7]=b7; end
  endtask

  integer y, n_disp;
  task automatic count_and_check_lines(input string name);
    begin
      n_disp = 0;
      for (y = 0; y < 1024; y = y + 1) if (r_de[y]) n_disp = n_disp + 1;
      $display("LINES %-34s displayed %0d (NP2kai MAX(%0d, %0d) = %0d), frame %0d (NP2kai %0d), VSYNC rise %0d (want %0d)",
               name, n_disp, e_textymax, e_grphymax, e_disp, r_lines, e_vtotal, r_rise, e_rise);
      expect_eq(n_disp,  e_disp,   {name, ": displayed lines"});
      expect_eq(r_lines, e_vtotal, {name, ": lines per frame"});
      expect_eq(r_rise,  e_rise,   {name, ": VSYNC rise line"});
      // the displayed lines are the FIRST n lines of the frame, no holes
      for (y = 0; y < e_disp; y = y + 1)
        if (!r_de[y]) begin
          $display("FAIL: %0s: line %0d inside the %0d displayed lines carries no DE", name, y, e_disp);
          errors = errors + 1;
          y = e_disp;
        end
    end
  endtask

  integer bad;
  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk_sys);
    @(negedge clk_sys);
    rst_n_sys = 1;
    rst_n_vid = 1;
    write_io(8'h62, 8'h0D);   // master START
    write_io(8'h6A, 8'h01);   // 16-colour analogue
    write_io(8'h68, 8'h08);   // 640x400 (mode1[4] clear)
    repeat (2000) @(negedge clk_sys);

    // ---- 1. INT 18h AH=30h BH=0x31: 640x480, 25 rows (NP2kai gdcmastersync[4], gdcslavesync[1]) ----
    // The master's lf is 475 (0x1DB) and the slave's 480 (0x1E0); the vbp is 37 on both.
    set_master(8'h10, 8'h4E, 8'h4B, 8'h0C, 8'h03, 8'h0B, 8'hDB, 8'h95);
    set_slave (8'h02, 8'h4E, 8'h4B, 8'h0C, 8'h83, 8'h06, 8'hE0, 8'h95);
    np2_expect;
    expect_eq(e_lf_m, 475, "case 1 master lf (decoded from its bytes)");
    expect_eq(e_lf_s, 480, "case 1 slave lf (decoded from its bytes)");
    expect_eq(e_vtotal, 525, "case 1 frame lines");
    expect_eq(e_disp, 480, "case 1 NP2kai picture height");
    // The slave is SYNCed and STARTed (the driver's state): the picture is the taller window,
    // 480 lines. NP2kai also gives 480 with the slave stopped (dispsync_renewalvertical has no
    // START term), a divergence kept on purpose: see pc9821_crtc's gfx_win_on, and the
    // master-only reprograms tb_pc9821_gdc_sync_raster / tb_pc9821_line_doubler pin.
    program_blocks(1'b1);
    record_frame;
    count_and_check_lines("640x480/25 slave STARTed");
    // ---- 2. INT 18h AH=30h BH=0x32: 640x480, 30 rows (gdcmastersync[5], crtdata[6]) ----
    // bios0x18_30 writes CSRFORM {raster 0x0F, 0, (0x0F << 3) + 3 = 0x7B}, the CRTC's
    // pl/bl/cl = 0/0x0F/0x10 (the registers' power-on values) and zeroes SCROLL.
    set_master(8'h10, 8'h4E, 8'h4B, 8'h0C, 8'h03, 8'h06, 8'hE0, 8'h95);
    set_slave (8'h02, 8'h4E, 8'h4B, 8'h0C, 8'h83, 8'h06, 8'hE0, 8'h95);
    np2_expect;
    expect_eq(e_lf_m, 480, "case 2 master lf");
    expect_eq(e_vtotal, 525, "case 2 frame lines");
    write_io(8'h62, 8'h4B); write_io(8'h60, 8'h0F); write_io(8'h60, 8'h00); write_io(8'h60, 8'h7B);
    write_io(8'h62, 8'h70);
    for (k = 0; k < 4; k = k + 1) write_io(8'h60, 8'h00);
    program_blocks(1'b0);
    record_frame;
    count_and_check_lines("640x480/30 text");
    // maketext.c: LRcnt reloads every TEXT_LR + 1 = 16 lines, so line y is row y >> 4 and its
    // font line (nowline from topline = PL = 0) is y & 15: 30 rows, 480 lines.
    bad = 0;
    for (y = 0; y < 480; y = y + 1)
      if (r_k[y] !== (y >> 4) || r_now[y] !== (y & 15)) begin
        if (bad < 5) $display("FAIL: 30-row text: line %0d is row %0d font line %0d, want row %0d font line %0d",
                              y, r_k[y], r_now[y], y >> 4, y & 15);
        bad = bad + 1;
      end
    if (bad != 0) fail($sformatf("30-row text: %0d of 480 lines name the wrong row or font line", bad));
    expect_eq(r_k[479], 29, "30-row text: the last displayed line's row");

    // ---- 3. the planar 640x400 31 kHz block: 800 x 449 (gdcmastersync[2], gdcslavesync[5]) ----
    set_master(8'h10, 8'h4E, 8'h47, 8'h0C, 8'h07, 8'h0D, 8'h90, 8'h89);
    set_slave (8'h02, 8'h4E, 8'h47, 8'h0C, 8'h87, 8'h0D, 8'h90, 8'h89);
    np2_expect;
    expect_eq(e_lf_m, 400, "case 3 master lf");
    expect_eq(e_vtotal, 449, "case 3 frame lines (400 + vs 2 + vfp 13 + vbp 34)");
    expect_eq(e_rise, 413, "case 3 VSYNC rise (lf + vfp)");
    // the 16-colour 400-line state: CSRFORM line repeat 1, PITCH 40 words, SCROLL 0 / 400 lines
    write_io(8'h62, 8'h4B); write_io(8'h60, 8'h0F); write_io(8'h60, 8'h00); write_io(8'h60, 8'h7B);
    write_io(8'hA2, 8'h4B); write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h01);
    write_io(8'hA2, 8'h47); write_io(8'hA0, 8'h28);
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h19);
    program_blocks(1'b1);
    record_frame;
    count_and_check_lines("planar 640x400/449");
    // makegrph.c grphput_*: the walk starts at the window's first line and steps PITCH
    // (40 words doubled to 80 bytes at im = 0) per line, so decode line ln is ln * 0x50. The
    // line buffer delivers decode line ln two raster lines after the tick that latched it
    // (tb_pc9821_gdc2_scroll check_at_line), so it is on the bus at raster line (ln - 2) mod
    // VTOTAL: decode lines 0 and 1 are read at the TAIL of the previous frame, lines 447 and
    // 448 of an ODD-length frame, past the parity wrap.
    bad = 0;
    for (y = 0; y < 400; y = y + 1) begin
      k = (y >= 2) ? (y - 2) : (y + 449 - 2);
      if (r_addr[k] !== 16'(y * 16'h0050)) begin
        if (bad < 5) $display("FAIL: planar 449: decode line %0d address %04x, want %04x (raster line %0d)",
                              y, r_addr[k], 16'(y * 16'h0050), k);
        bad = bad + 1;
      end
    end
    if (bad != 0) fail($sformatf("planar 449: %0d of 400 decode lines present the wrong address", bad));

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_DISP_LINES: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_DISP_LINES: FAIL (%0d errors)", errors);
  end

  initial begin
    repeat (80_000_000) @(posedge clk_sys);
    $fatal(1, "TB_PC9821_DISP_LINES: TIMEOUT (the raster produced no frame)");
  end
endmodule

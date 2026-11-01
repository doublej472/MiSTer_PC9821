`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GDC_BLINK:
// The text plane's character blink (TXTATR_BL) runs at the CSRFORM-derived RATE, measured in FRAMES at the dot level against NP2kai's own numbers. NP2kai advances ONE blink count for both the character blink and the cursor, once per `timing` drawscreen() calls, where `timing = ((LOADINTELWORD(gdc.m.para + GDC_CSRFORM + 1)) >> 5) & 0x3e; if (!timing) timing = 0x40` - i.e. the five-bit CSRFORM field {cs[2][2:0], cs[1][7:6]} DOUBLED, 64 when that field is zero (pccore.c:1476-1484) - and blanks a blinkable glyph on the one count in four whose low bits are zero (`blinkdisp = (count & 3) ? 1 : 0`, vram/maketext.c:114 applied at :309-312). The DUT's power-on CSRFORM (cs[0] = 0x0F disabled, cs[1] = 0xC0, cs[2] = 0x7B; NP2kai io/gdc.c:1084) makes the field 15, so the measured blink is a 30-frame dark phase, a 90-frame lit phase and a 120-frame period (0.53 s dark / 1.6 s lit at the machine's 56.42 Hz raster); a second CSRFORM (field 1, cs[1] = 0x40, cs[2] = 0x78) must make it a 2-frame dark phase and an 8-frame period, which is what shows the FIELD - not a fixed divider - drives the blink. Every window is a change-to-change frame count of the rendered cell sampled once per frame, so it is exact wherever the forced divider phase lands. FAIL-FIRST: the pre-fix RTL advanced its blink count every frame, so the blink was a 16-frame dark phase in a 64-frame cycle whatever the CSRFORM said (the reference's numbers are 30 in 120).
//
// The NP2kai code the rate comes from, verbatim (the block runs once per `drawscreen()` call):
//
//   tramflag.timing++;
//   timing = ((LOADINTELWORD(gdc.m.para + GDC_CSRFORM + 1)) >> 5) & 0x3e;
//   if (!timing) { timing = 0x40; }                  (pccore.c:1475-1479)
//   if (tramflag.timing >= timing) {
//     tramflag.timing = 0; tramflag.count++; ... }   (pccore.c:1480-1484)
//   ... else if (curx[x] & TXTATR_BL) {              (vram/maketext.c:309-312:
//         tramflag.blink = 1; if (!tramflag.blinkdisp) bitmap[x] = 0; }  the glyph blanked)
//
// WHY THIS IS SEPARATE FROM tb_pc9821_gdc_text_regs: that bench forces the count and samples the
// references' 3:1 DUTY at once; this one pokes the divider and the count ONCE (cur_div = 0,
// frame_cnt = 48 = NP2kai's count 3 - the same white-box forced-phase poke) and then counts the
// REAL frames to each change, so what it pins is `timing` = 2*field frames per count: the RATE in
// frames, which a duty sample cannot see (a measurement costs one period instead of two).
//
// The numbers the FAIL-FIRST sentence names, as the pre-fix bench measured them: the power-on case
// reads 16/48/64 instead of 30/90/120 and the field-1 case is invisible, because frame_cnt advanced
// EVERY frame and blink_off was frame_cnt[5:4] == 0.
//
// ==== DUT ====
// pc9821_gdc_text_dut: the real pc9821_crtc + pc9821_gdc2 + pc9821_cg (the same composition
// tb_pc9821_gdc_text_regs uses), one clock gated by pixel_ce (1 dot per clk_sys here, so a frame
// is 848*440 = 373,120 clk_sys).

module tb_pc9821_gdc_blink;
  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;
  reg pixel_ce = 1;
  reg rst_n_sys = 0, rst_n_vid = 0;

  reg io_wr = 0, io_rd = 0;
  reg [7:0] io_addr = 0, io_din = 0;
  wire [7:0] io_dout;

  reg [13:0] tram_cpu_addr = 0;
  reg [7:0]  tram_cpu_din = 0;
  reg        tram_cpu_we = 0;
  wire [7:0] tram_cpu_dout;

  reg [17:0] font_ld_addr = 0;
  reg [15:0] font_ld_data = 0;
  reg        font_ld_we = 0;

  reg  font_word_valid = 0;
  reg [31:0] font_word_data = 0;

  reg [7:0] cfg_ram_mib = 7'd0;
  reg cfg_seed_en = 1'b0;

  wire text_opaque;

  // ==== DUT ====
  pc9821_gdc_text_dut dut (
      .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .pixel_ce(pixel_ce),
      .cfg_fdd_mode(3'd0),   // entry 0: the measured boot/FDD nibble
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
      .tram_cpu_addr(tram_cpu_addr), .tram_cpu_din(tram_cpu_din), .tram_cpu_we(tram_cpu_we),
      .tram_cpu_dout(tram_cpu_dout),
      .font_ld_addr(font_ld_addr), .font_ld_data(font_ld_data), .font_ld_we(font_ld_we),
      .cg_win_byte_sel(5'd0), .cg_win_rd(1'b0), .cg_win_din(8'h00), .cg_win_we(1'b0),
      .font_word_valid(font_word_valid), .font_word_data(font_word_data),
      .cg_record_restore(1'b0),
      .cfg_seed_reload(1'b0),
      .vsync_irq_arm(1'b0),
      .cfg_ram_mib(cfg_ram_mib), .cfg_seed_en(cfg_seed_en),
      .text_opaque(text_opaque)
  );

  integer errors = 0, cases = 0;

  task automatic check(input [8*56-1:0] name, input [31:0] got, input [31:0] want);
    begin
      cases = cases + 1;
      if (got !== want) begin
        $display("MISMATCH %0s: rtl=%0d np2kai=%0d", name, got, want);
        errors = errors + 1;
      end
      else $display("ok       %0s = %0d", name, got);
    end
  endtask

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys); io_addr = portnum; io_din = data; io_wr = 1;
      @(negedge clk_sys); io_wr = 0;
    end
  endtask

  task automatic write_tram(input [13:0] addr, input [7:0] data);
    begin
      @(negedge clk_sys); tram_cpu_addr = addr; tram_cpu_din = data; tram_cpu_we = 1;
      @(negedge clk_sys); tram_cpu_we = 0;
    end
  endtask

  task automatic write_font(input [17:0] addr, input [15:0] data);
    begin
      @(negedge clk_sys); font_ld_addr = addr; font_ld_data = data; font_ld_we = 1;
      @(negedge clk_sys); font_ld_we = 0;
    end
  endtask

  // One TRAM cell: code low byte at 2w, high byte at 2w+1, attribute at 0x2000+2w.
  task automatic set_word(input [11:0] w, input [7:0] clo, input [7:0] chi, input [7:0] attr);
    begin
      write_tram({1'b0, w, 1'b0},     clo);
      write_tram({1'b0, w, 1'b0} + 1, chi);
      write_tram({1'b1, w, 1'b0},     attr);
    end
  endtask

  task automatic fill_plane(input [7:0] clo, input [7:0] chi, input [7:0] attr);
    integer k;
    begin
      for (k = 0; k < 16'h1000; k = k + 1) set_word(k[11:0], clo, chi, attr);
    end
  endtask

  // The 8x16 ANK table is words code*8 .. code*8+7, one word per two raster rows.
  task automatic load_ank(input [7:0] code, input [15:0] val);
    integer k, w;
    begin
      w = code * 8;
      for (k = 0; k < 8; k = k + 1) write_font(w[17:0] + k[17:0], val);
    end
  endtask

  task automatic gcmd(input [7:0] c); begin write_io(8'h62, c); end endtask
  task automatic gpar(input [7:0] p); begin write_io(8'h60, p); end endtask

  task automatic set_sad(input [15:0] sad);
    begin
      gcmd(8'h70); gpar(sad[7:0]); gpar(sad[15:8]); gpar(8'h00); gpar(8'h00);
    end
  endtask

  task automatic set_pitch(input [7:0] p); begin gcmd(8'h47); gpar(p); end endtask

  // 0x4B CSRFORM: byte0 bit7 enables the cursor, byte1 bit5 is non-blink, byte1[4:0] the top row,
  // byte2[7:3] the bottom row. The blink field is {byte2[2:0], byte1[7:6]}.
  task automatic set_csrform(input [7:0] f0, input [7:0] f1, input [7:0] f2);
    begin
      gcmd(8'h4B); gpar(f0); gpar(f1); gpar(f2);
    end
  endtask

  // Wait two FRAME ENDS, so the scanout's configuration snapshot has copied the CPU writes.
  // frame_end, not a frame_cnt change: frame_cnt is the blink COUNT and advances once per
  // CSRFORM `timing` frames.
  task automatic settle;
    integer f;
    begin
      f = 0;
      while (f < 2) begin
        @(negedge clk_sys);
        if (dut.u_crtc.frame_end) f = f + 1;
      end
    end
  endtask

  // Sample the 8 dots of cell (0,col) at font raster row 15 into a lit mask; consecutive calls
  // are exactly one frame apart (each waits for a FRESH vline 15), which is what makes the frame
  // counts below frame counts.
  task automatic sample_cell_frame(input [5:0] col, output [7:0] m);
    integer k;
    begin
      while (dut.u_crtc.vline == 9'd15) @(negedge clk_sys);
      while (dut.u_crtc.vline != 9'd15) @(negedge clk_sys);
      m = 8'h00;
      for (k = 0; k < 8; k = k + 1) begin
        while (dut.u_crtc.hdot != (col * 8 + k)) @(negedge clk_sys);
        if (text_opaque) m[7-k] = 1'b1;
      end
    end
  endtask

  // The blink's windows IN FRAMES. The divider and the count are forced ONCE (the white-box poke
  // tb_pc9821_gdc_text_regs's forced-phase samplers already use) so a measurement costs ONE
  // period instead of two: cur_div = 0 makes the next count land `timing` frames later and
  // frame_cnt = 48 is NP2kai's count 3, the LAST lit count before the dark one. Every interval
  // reported is then a pure RTL change-to-change frame count - c1..c2 is the dark phase and
  // c2..c3 the lit phase - so the poke does not have to land on a frame boundary.
  task automatic blink_windows(input [5:0] col, input integer want, input integer limit,
                               output integer c1, output integer c2, output integer c3,
                               output integer seen, output [7:0] m1, output [7:0] m2);
    reg [7:0] m, prev;
    integer n;
    begin
      c1 = 0; c2 = 0; c3 = 0; seen = 0;
      sample_cell_frame(col, prev);          // any phase: establishes the "before" mask
      dut.u_crtc.cur_div   = 7'd0;           // a fresh divider ...
      dut.u_crtc.frame_cnt = 6'd48;          // ... at count 3, the last of the three lit counts
      sample_cell_frame(col, prev);          // the forced count's first frame
      if (prev !== 8'hFF) begin
        $display("MISMATCH blink_forced_count3_lit: the forced count 3 frame is not lit (%02x)", prev);
        errors = errors + 1;
      end
      n = 0;
      while ((seen < want) && (n < limit)) begin
        sample_cell_frame(col, m);
        n = n + 1;
        if (m !== prev) begin
          seen = seen + 1;
          if      (seen == 1) begin c1 = n; m1 = m; end
          else if (seen == 2) begin c2 = n; m2 = m; end
          else                c3 = n;
          prev = m;
        end
      end
    end
  endtask

  // ==== CHECKS ====
  initial begin
    integer c1, c2, c3, seen;
    reg [7:0] bm1, bm2;
    repeat (4) @(posedge clk_sys);
    @(negedge clk_sys);
    rst_n_sys = 1;
    rst_n_vid = 1;

    load_ank(8'h42, 16'hFFFF);     // a fully inked ANK cell
    write_io(8'h62, 8'h0D);        // START: v_disp = mode1[7] && gdc_start
    set_sad(16'h0000);
    set_pitch(8'h50);
    // A fully inked ANK cell that BLINKS (attribute 0x03 = visible + bit 1). The cursor is off
    // at the power-on CSRFORM (cs[0] = 0x0F, bit 7 clear), so the rendered mask is the glyph
    // and the blink gate alone.
    fill_plane(8'h42, 8'h00, 8'h03);
    settle;

    // ---- 1. the power-on CSRFORM: a 30-frame dark phase in a 120-frame blink ----
    // NP2kai's power-on CSRFORM is cs[1] = 0xC0, cs[2] = 0x7B (io/gdc.c:1084; the RTL's reset
    // values, pc9821_crtc.sv). Field = {cs[2][2:0]=0b011, cs[1][7:6]=0b11} = 15, so `timing` =
    // 2*15 = 30 frames per count (pccore.c:1476-1484) and the glyph is blanked on the count
    // whose low bits are 0 (maketext.c:114): dark 30, lit 90, period 120 frames. The premise is
    // checked white-box so a wrong CSRFORM decode cannot pass by luck.
    check("blink_boot_csrform_field15", dut.u_crtc.csr_blink_field, 32'd15);
    check("blink_boot_divider_frames",  dut.u_crtc.cur_timing,      32'd30);
    blink_windows(6'd0, 3, 200, c1, c2, c3, seen, bm1, bm2);
    check("blink_boot_changes_seen",    seen,      32'd3);
    check("blink_boot_dark_phase_frames", (c2 - c1), 32'd30);
    check("blink_boot_lit_phase_frames",  (c3 - c2), 32'd90);
    check("blink_boot_period_frames",     (c3 - c1), 32'd120);
    check("blink_boot_dark_mask",         bm1,       32'h00000000);
    check("blink_boot_lit_mask",          bm2,       32'h000000ff);
    $display("NOTE blink_boot: changes at frames %0d/%0d/%0d, masks %02x -> %02x", c1, c2, c3, bm1, bm2);

    // ---- 2. the CSRFORM field IS the rate: field 1 -> a 2-frame count, an 8-frame period ----
    // cs[1] = 0x40 contributes the field's LOW bits (0b01) and cs[2][2:0] = 0 the high ones, so
    // the field is 1, `timing` is 2 frames and the blink is dark 2 / lit 6 / 8 frames period.
    // A character blink wired to any fixed divider (16 frames of 64, or 30) fails here.
    set_csrform(8'h0F, 8'h40, 8'h78);   // cs[0] = 0x0F: the cursor stays disabled
    settle;
    check("blink_field1_csrform_field", dut.u_crtc.csr_blink_field, 32'd1);
    check("blink_field1_divider_frames", dut.u_crtc.cur_timing,     32'd2);
    blink_windows(6'd0, 3, 40, c1, c2, c3, seen, bm1, bm2);
    check("blink_field1_changes_seen",    seen,      32'd3);
    check("blink_field1_dark_phase_frames", (c2 - c1), 32'd2);
    check("blink_field1_lit_phase_frames",  (c3 - c2), 32'd6);
    check("blink_field1_period_frames",     (c3 - c1), 32'd8);

    // ==== VERDICT ====
    $display("NOTE gdc_blink: %0d cases, %0d mismatched, sim %0t", cases, errors, $time);
    if (errors == 0) begin
      $display("TB_PC9821_GDC_BLINK: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GDC_BLINK: FAIL (%0d of %0d cases)", errors, cases);
  end

  initial begin
    #800_000_000;
    $fatal(1, "TB_PC9821_GDC_BLINK: TIMEOUT");
  end

endmodule

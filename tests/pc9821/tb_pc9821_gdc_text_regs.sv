`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// Drives the text GDC's I/O registers (0x60/0x62/0x68/0x6A plus the CSRW/CSRFORM/PITCH/SCROLL commands) and reads the SCANOUT's tile, attribute and cursor state back at the dot level, checking each case against NP2kai's io/gdc.c and vram/maketext.c. It is FAIL-FIRST: the register-semantics deviations recorded against NP2kai - the missing 0x68 high-nibble write gate, the constant 0x6A read-back, the PITCH bit-0 mask, the solid-block cursor instead of NP2kai's inverse-video cursor, the cursor not spanning a double-width cell, the cursor's unmasked 16-bit CSRW compare, the ignored attribute bit 4 vertical line, and the underline gated on the visible bit - each make it fail, one named MISMATCH line per case. Further cases pin three more, each of which the earlier cases could NOT see because a single sample is blind to them: the cursor's non-blink bit is cs[1]&0x20 SET (the cursor is sampled at BOTH blink phases, so the inverted polarity shows), the vertical line sits at the references' pattern bit 3 / pixel 4 (the mask, not just lit/not, so dot 7 fails), and the character blink duty is the references' 3:1 (the blink phase is forced, so 1:1 fails). The 255-cursor-fix additions pin the PARAMETER MODEL itself: the authentic BIOS sends only TWO CSRW bytes and ONE CSRFORM byte (BANK6@0x49cf, BANK7@0x6a45) and both references apply each parameter byte as it arrives, so an apply-at-completion model never latches the cursor address or enable and the text cursor never appears. The 303-cursor-blink additions pin the cursor's blink RATE in FRAMES at the dot level: the machine's boot CSRFORM (cs[1] = 0x00, cs[2] = 0x7B) makes the five-bit field {cs[2][2:0], cs[1][7:6]} 12 and so NP2kai's 24-frame toggle, a 48-frame 1.175 Hz blink at the 56.42 Hz raster; a cs[1] = 0x40 / cs[2] = 0x79 split makes it 5, i.e. 10 frames toggle and 20 frames cycle, so the field's high bits cannot be dropped and its two halves cannot be swapped; and a field of zero is NP2kai's 64, not the fastest rate. Case 19 pins the 0x7C read as the machine's OPEN BUS 0xFF (probe2 /RDBACK wrote 0x5A and read FF anyway, docs/probes/RDBACK.TXT:152) - NP2kai's crtc_i7c returns the live grcg.modereg and is the weaker source, and the input is now driven only to prove the read is NOT the register - and the six CRTC render registers store FIVE bits (NP2kai crtc_o70 dat &= 0x1f) so 0xFF written reads back 0x1F (FAIL-FIRST on both: the old row asserted the register). Its wait for the scanout's configuration snapshot is on FRAME_END, not on a frame_cnt change: frame_cnt is now the character blink's COUNT, advanced once per CSRFORM `timing` frames exactly as the cursor's phase is (both consumers share NP2kai's one `tramflag.count`, pccore.c:1476-1484), and the blink's rate in FRAMES is tb_pc9821_gdc_blink's, which waits the real rate out rather than forcing the phase.
//
// Drives the text GDC's I/O registers (0x60/0x62/0x68/0x6A plus the CSRW/CSRFORM/PITCH/SCROLL commands) and reads the SCANOUT's tile, attribute and cursor state back at the dot level, checking each case against NP2kai's io/gdc.c and vram/maketext.c. It is FAIL-FIRST: the register-semantics deviations an earlier review recorded - the missing 0x68 high-nibble write gate, the constant 0x6A read-back, the PITCH bit-0 mask, the solid-block cursor instead of NP2kai's inverse-video cursor, the cursor not spanning a double-width cell, the cursor's unmasked 16-bit CSRW compare, the ignored attribute bit 4 vertical line, and the underline gated on the visible bit - each make it fail, one named MISMATCH line per case. The later additions pin three more, each of which the earlier cases could NOT see because a single sample is blind to them: the cursor's non-blink bit is cs[1]&0x20 SET (the cursor is sampled at BOTH blink phases, so the inverted polarity shows), the vertical line sits at the references' pattern bit 3 / pixel 4 (the mask, not just lit/not, so dot 7 fails), and the character blink duty is the references' 3:1 (the blink phase is forced, so 1:1 fails). The 255-cursor-fix additions pin the PARAMETER MODEL itself: the authentic BIOS sends only TWO CSRW bytes and ONE CSRFORM byte (BANK6@0x49cf, BANK7@0x6a45) and both references apply each parameter byte as it arrives, so an apply-at-completion model never latches the cursor address or enable and the text cursor never appears. The 303-cursor-blink additions pin the cursor's blink RATE in FRAMES at the dot level: the machine's boot CSRFORM (cs[1] = 0x00, cs[2] = 0x7B) makes the five-bit field {cs[2][2:0], cs[1][7:6]} 12 and so NP2kai's 24-frame toggle, a 48-frame 1.175 Hz blink at the 56.42 Hz raster; a cs[1] = 0x40 / cs[2] = 0x79 split makes it 5, i.e. 10 frames toggle and 20 frames cycle, so the field's high bits cannot be dropped and its two halves cannot be swapped; and a field of zero is NP2kai's 64, not the fastest rate.

module tb_pc9821_gdc_text_regs;
  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;
  wire clk_vid = clk_sys;
  reg pixel_ce = 1;
  reg rst_n_sys = 0, rst_n_vid = 0;

  reg io_wr = 0, io_rd = 0;
  reg [7:0] io_addr = 0, io_din = 0;
  wire [7:0] io_dout;
  reg [13:0] tram_cpu_addr = 0;
  reg [7:0] tram_cpu_din = 0;
  reg tram_cpu_we = 0;
  wire [7:0] tram_cpu_dout;

  reg [17:0] font_ld_addr = 0;
  reg [15:0] font_ld_data = 0;
  reg font_ld_we = 0;

  reg [4:0] cg_win_byte_sel = 0;
  reg cg_win_rd = 0;
  wire [7:0] cg_win_dout;
  reg [7:0] cg_win_din = 0;
  reg cg_win_we = 0;

  wire [18:0] font_req_addr;
  wire font_req;
  reg font_word_valid = 0;
  reg [31:0] font_word_data = 0;

  reg cg_record_restore = 0;
  reg [3:0] bios_set = 4'd0;   // the record's model field: 0 = Xe10 (entry 0)
  wire vsync_active, vsync_irq;
  wire        vsync_edge;   // the frame boundary the vblank IRQ rises on; parked for (.*)
  reg vsync_irq_arm = 0;
  wire disp_on, gfx_access_page, gfx_disp, gfx_egc_gate;
  wire [15:0] gfx_line_addr;
  wire gfx_walk_page;   // the packed walk's page bit; not this bench's subject (parked for (.*))
  wire [6:0] cfg_ram_mib = 7'd0;
  wire cfg_seed_en = 1'b0;
  wire cfg_seed_reload = 1'b0;

  wire [15:0] dbg_sad;
  wire [7:0] dbg_pitch;
  wire dbg_col40, dbg_disp;
  wire [15:0] dbg_wk_skips;   // the walker's skipped-walk counter
  wire text_opaque, text_cell;
  wire [11:0] text_colour;
  wire [9:0] pix_dot;
  wire pix_h_active, pix_v_active;
  wire gfx_mode16;
  wire [31:0] gfx_dig;
  // The analogue palette table's CPU write port (pc9821_gfx_palette's MLAB).
  wire        pal_wr_en;
  wire [3:0]  pal_wr_idx;
  wire [1:0]  pal_wr_chan;
  wire [3:0]  pal_wr_data;
  wire        pal_commit;
  wire hs_out, vs_out, de_out;

  // ==== DUT ====
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

  pc9821_gdc_text_dut dut (.*);

  integer errors = 0, cases = 0;
  reg [7:0] value;
  reg [7:0] mask;

  // ==== STIMULUS ====
  task automatic check(input [8*48-1:0] name, input [15:0] got, input [15:0] want);
    begin
      cases = cases + 1;
      if (got !== want) begin
        $display("MISMATCH %0s: rtl=0x%04x np2kai=0x%04x", name, got, want);
        errors = errors + 1;
      end
      else $display("ok       %0s = 0x%04x", name, got);
    end
  endtask

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys); io_addr = portnum; io_din = data; io_wr = 1;
      @(negedge clk_sys); io_wr = 0;
    end
  endtask

  task automatic read_io(input [7:0] portnum, output [7:0] data);
    begin
      @(negedge clk_sys); io_addr = portnum; #1 data = io_dout;
      @(negedge clk_sys);
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

  // Every cell of the 4096-word plane carries the same code and attribute, so no cell
  // is x and no case depends on where the scanout starts.
  task automatic fill_plane(input [7:0] clo, input [7:0] chi, input [7:0] attr);
    integer k;
    begin
      for (k = 0; k < 16'h1000; k = k + 1) set_word(k[11:0], clo, chi, attr);
    end
  endtask

  // Even words carry one code, odd words another (a two-cell pair).
  task automatic fill_plane_pair(input [7:0] elo, input [7:0] ehi,
                                 input [7:0] olo, input [7:0] ohi, input [7:0] attr);
    integer k;
    begin
      for (k = 0; k < 16'h1000; k = k + 1) begin
        if (!k[0]) set_word(k[11:0], elo, ehi, attr);
        else       set_word(k[11:0], olo, ohi, attr);
      end
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

  // A JIS glyph at the dump's own byte address. The JIS grid is NOT in M10K any more,
  // so loading one must NOT write the font store: an address at or above the 2048-word ANK
  // slice would ALIAS onto it and corrupt an ANK glyph (the bug this bench caught). The one
  // caller passes a BLANK glyph, so the model's SDRAM answers zeros and the walker's cache
  // stays blank - which is exactly what that case wants.
  task automatic load_jis(input [7:0] ku, input [7:0] ten, input [255:0] g);
    begin
      // No store write: see the note above. The arguments are named so the call site reads
      // as the glyph it names.
      /* verilator lint_off UNUSEDSIGNAL */
      if (1'b0 && (|ku || |ten || |g)) ;
      /* verilator lint_on UNUSEDSIGNAL */
    end
  endtask

  task automatic gcmd(input [7:0] c);   begin write_io(8'h62, c); end endtask
  task automatic gpar(input [7:0] p);   begin write_io(8'h60, p); end endtask

  // 0x70 SCROLL: the first two parameter bytes are the display start word (NP2kai
  // io/gdc_cmd.tbl row 0x70 -> GDC_SCROLL, and maketext's `esi = LOW12(para+SCROLL)`).
  task automatic set_sad(input [15:0] sad);
    begin
      gcmd(8'h70); gpar(sad[7:0]); gpar(sad[15:8]); gpar(8'h00); gpar(8'h00);
    end
  endtask

  task automatic set_pitch(input [7:0] p); begin gcmd(8'h47); gpar(p); end endtask

  // 0x49 CSRW: three bytes, {p1,p0} is the cursor word. The full form; the authentic BIOS
  // sends only the first TWO (see set_csrw2).
  task automatic set_csrw(input [15:0] a);
    begin
      gcmd(8'h49); gpar(a[7:0]); gpar(a[15:8]); gpar(8'h00);
    end
  endtask

  // 0x49 CSRW with TWO parameter bytes only, the authentic BIOS's shape (BANK6@0x49cf).
  task automatic set_csrw2(input [15:0] a);
    begin
      gcmd(8'h49); gpar(a[7:0]); gpar(a[15:8]);
    end
  endtask

  // 0x4B CSRFORM: byte0 bit7 enables the cursor, byte1 bit5 is non-blink and byte1[4:0]
  // the top row, byte2[7:3] the bottom row (NP2kai maketext's maketext_curblink).
  task automatic set_cursor(input [7:0] f0, input [7:0] f1, input [7:0] f2);
    begin
      gcmd(8'h4B); gpar(f0); gpar(f1); gpar(f2);
    end
  endtask

  // 0x4B CSRFORM with ONE parameter byte only, the authentic BIOS's shape (BANK7@0x6a33:
  // `mov al,0x4B; out 0x62; mov al,[0x53b]; or al,0x80; out 0x60`): cs[0] with bit 7 set,
  // cs[1]/cs[2] left at the chip's power-on values.
  task automatic set_cursor1(input [7:0] f0);
    begin
      gcmd(8'h4B); gpar(f0);
    end
  endtask

  task automatic cursor_on;  begin set_cursor(8'h8F, 8'h20, 8'h7B); end endtask
  task automatic cursor_off; begin set_cursor(8'h0F, 8'h00, 8'h7B); end endtask

  // Wait n frame ends, so the clk_vid configuration snapshot has copied the CPU writes.
  // The wait is on frame_end itself, not on a frame_cnt CHANGE: frame_cnt is the character
  // blink's count and now advances once per CSRFORM `timing` frames (30 at power-on),
  // so a change-wait would cost 30 frames per call here.
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

  // Sample the 8 dots of one cell at one font raster row into a lit mask. The dot at
  // hdot 8*col+k is glyph bit 7-k (the RTL renders r_font[~adot[2:0]]), so mask[7] is
  // the cell's leftmost dot.
  task automatic sample_cell(input [4:0] row, input [5:0] col, input [3:0] frast,
                             output [7:0] m);
    integer k;
    reg [8:0] tline;
    begin
      tline = row * 16 + frast;
      while (dut.u_crtc.vline != tline) @(negedge clk_sys);
      m = 8'h00;
      for (k = 0; k < 8; k = k + 1) begin
        while (dut.u_crtc.hdot != (col * 8 + k)) @(negedge clk_sys);
        if (text_opaque) m[7-k] = 1'b1;
      end
    end
  endtask

  // The same, with the frame blink count FORCED for the sample. The character blink's phase
  // is frame_cnt[5:4] (its count, the divider advancing it once per CSRFORM `timing` frames);
  // waiting 30 real frames for the other phase would make the bench minutes long, so it is
  // poked white-box just after the sampling row is reached. The sample takes 8 dots of one
  // line, ~19 clk_sys, so the forced value cannot reach the next count (a count is 30 frames
  // of 373,120 dots at the power-on field). The PERIOD in frames is pinned by
  // tb_pc9821_gdc_blink, which waits the real rate out.
  task automatic sample_cell_fc(input [4:0] row, input [5:0] col, input [3:0] frast,
                                input [5:0] fcnt, output [7:0] m);
    integer k;
    reg [8:0] tline;
    begin
      tline = row * 16 + frast;
      // Arrive at the START of a FRESH occurrence of the row: if the previous sample left
      // us mid-line, wait the line out and take the next frame's. Without this the loop
      // below waits for hdot to wrap and samples the following raster line.
      while (dut.u_crtc.vline == tline) @(negedge clk_sys);
      while (dut.u_crtc.vline != tline) @(negedge clk_sys);
      dut.u_crtc.frame_cnt = fcnt;
      #1;                        // settle the forced blink phase into the combinators
      m = 8'h00;
      for (k = 0; k < 8; k = k + 1) begin
        while (dut.u_crtc.hdot != (col * 8 + k)) @(negedge clk_sys);
        if (text_opaque) m[7-k] = 1'b1;
      end
    end
  endtask

  // The same, with the CURSOR's blink phase FORCED. The cursor toggles on cur_phase, which
  // advances once per CSRFORM[1]-selected `timing` frames (NP2kai pccore.c:1476); forcing it
  // samples both phases without waiting the real rate.
  task automatic sample_cell_cp(input [4:0] row, input [5:0] col, input [3:0] frast,
                                input cphase, output [7:0] m);
    integer k;
    reg [8:0] tline;
    begin
      tline = row * 16 + frast;
      while (dut.u_crtc.vline == tline) @(negedge clk_sys);
      while (dut.u_crtc.vline != tline) @(negedge clk_sys);
      dut.u_crtc.cur_phase = cphase;
      #1;
      m = 8'h00;
      for (k = 0; k < 8; k = k + 1) begin
        while (dut.u_crtc.hdot != (col * 8 + k)) @(negedge clk_sys);
        if (text_opaque) m[7-k] = 1'b1;
      end
    end
  endtask

  // Sample cell (0,col) raster 15 at the SAME point of every frame - the fresh-occurrence
  // prologue sample_cell_cp uses - so consecutive calls are exactly one frame apart.
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

  // The cursor's blink period IN FRAMES, read at the dot level: sample one cell once per frame
  // and time its lit-mask changes. The FIRST toggle is seeded by cur_div - the white-box poke
  // style the two forced-phase samplers already use, so a measurement costs one period instead
  // of two - and every interval returned is a LATER one, a pure RTL toggle-to-toggle period:
  // `toggle` is the frame count between changes 1 and 2, `cycle` between 1 and 3 (two
  // same-direction changes, i.e. one visible->hidden->visible blink). m0/m1 are the cell's lit
  // masks before and after the first change, so a case can check the cursor really is the
  // blinking full cell. `limit` bounds the wait, so a cursor that does not blink fails here
  // instead of hanging.
  task automatic cursor_blink_period(input [5:0] col, input integer want,
                                     input integer limit, output integer toggle,
                                     output integer cycle, output integer seen,
                                     output [7:0] m0, output [7:0] m1);
    reg [7:0] m, prev;
    integer n, t1, t2, t3;
    begin
      toggle = 0; cycle = 0; seen = 0; t1 = 0; t2 = 0; t3 = 0;
      sample_cell_frame(col, prev);
      m0 = prev;
      dut.u_crtc.cur_div = 7'd63;         // the next frame_end toggles cur_phase
      n = 0;
      while ((seen < want) && (n < limit)) begin
        sample_cell_frame(col, m);
        n = n + 1;
        if (m !== prev) begin
          seen = seen + 1;
          if (seen == 1) begin t1 = n; m1 = m; end
          else if (seen == 2) t2 = n;
          else t3 = n;
          prev = m;
        end
      end
      if (seen >= 2) toggle = t2 - t1;
      if (seen >= 3) cycle  = t3 - t1;
    end
  endtask

  // ==== CHECKS ====
  initial begin
    integer f;
    integer tgl, cyc, seen;
    reg [7:0] bm0, bm1;
    repeat (4) @(posedge clk_sys);
    @(negedge clk_sys);
    rst_n_sys = 1;
    rst_n_vid = 1;

    load_ank(8'h41, 16'h0000);   // blank ANK cell
    load_ank(8'h42, 16'hFFFF);   // fully inked ANK cell
    write_io(8'h62, 8'h0D);      // START: v_disp = mode1[7] && gdc_start
    set_sad(16'h0000);
    set_pitch(8'h50);
    cursor_off;

    // ---- 1. port 0x68 (MODE FF1) write gate ----
    // NP2kai io/gdc.c gdc_o68 ignores a write whose bits 4-7 are non-zero (the mode bits
    // need only 4 bits: dat = (bit_number << 1) | value). 0x11 is such a write: bit_number
    // 0, value 1. NP2kai leaves mode1 at its reset 0x98; a decoder that ignores the gate
    // sets bit 0 and reads back 0x99.
    read_io(8'h68, value); check("mode1_reset_readback", {8'h00, value}, 16'h0098);
    write_io(8'h68, 8'h11);
    read_io(8'h68, value); check("mode1_high_nibble_write_ignored", {8'h00, value}, 16'h0098);
    write_io(8'h68, 8'h00);   // a well-formed clear of bit 0, restoring 0x98
    read_io(8'h68, value); check("mode1_legal_write_readback", {8'h00, value}, 16'h0098);

    // ---- 2. port 0x6A (MODE FF2) read-back ----
    // NP2kai io/gdc.c gdc_i6a returns gdc.mode2 itself, so a set bit reads back. This
    // core answers a constant 0x00 there (see pc9821_gdc_text's read mux).
    write_io(8'h6A, 8'h01);   // num 0 (16-colour select) ON
    read_io(8'h6A, value); check("mode2_readback_16color_set", {8'h00, value}, 16'h0001);
    write_io(8'h6A, 8'h00);   // num 0 OFF

    // ---- 3. cursor on a blank cell: the one shape both references agree on ----
    fill_plane(8'h41, 8'h00, 8'h01);   // blank glyph, attribute visible
    set_sad(16'h0000); set_pitch(8'h50);
    set_csrw(16'h0000);
    cursor_on;
    settle;
    sample_cell(5'd0, 6'd0, 4'd15, mask);
    check("cursor_blank_cell_block", {8'h00, mask}, 16'h00FF);

    // ---- 4. cursor on an inked cell ----
    // NP2kai's cursor is INVERSE VIDEO: it sets bit 8 of the colour index, and
    // text_table[256+m] = text_table[m ^ 0x80], so ink pixels become background and vice
    // versa. A fully inked cell under the cursor therefore renders all background (0x00).
    // This core ORs csr_here into pix_on and paints a solid block (0xFF).
    fill_plane(8'h42, 8'h00, 8'h01);   // glyph 0xFF, attribute visible
    set_sad(16'h0000); set_pitch(8'h50);
    set_csrw(16'h0000);
    cursor_on;
    settle;
    sample_cell(5'd0, 6'd0, 4'd15, mask);
    check("cursor_inverts_inked_cell", {8'h00, mask}, 16'h0000);

    // ---- 5. cursor spans a double-width (kanji) cell pair ----
    // NP2kai marks the left cell 0x80 when its follower is the pair's right half, and the
    // cursor then sets bit 8 on BOTH cells (maketext: `if (curx[cur_line] & 0x80)
    // color[cur_line+1] |= 256`). A blank pair under the cursor must light both cells.
    fill_plane_pair(8'h10, 8'h21, 8'h20, 8'h00, 8'h01);   // even: JIS ku 0x30 ten 0x21
    load_jis(8'h30, 8'h21, 256'd0);                        // blank glyph, both halves
    set_sad(16'h0000); set_pitch(8'h50);
    set_csrw(16'h0000);
    cursor_on;
    settle;
    sample_cell(5'd0, 6'd0, 4'd15, mask);
    check("cursor_pair_left_cell", {8'h00, mask}, 16'h00FF);
    sample_cell(5'd0, 6'd1, 4'd15, mask);
    check("cursor_pair_right_cell", {8'h00, mask}, 16'h00FF);

    // ---- 6. the cursor word is masked to 12 bits ----
    // NP2kai's maketext compares the cursor against `edi`, which is LOW12 of the display
    // address, so a CSRW at or above 0x1000 can never match any cell. This core compares
    // the full 16-bit r_wordidx against the full 16-bit CSRW, so it lights the cell.
    fill_plane(8'h41, 8'h00, 8'h01);
    set_sad(16'h1000);          // word 0x1000 masks to TRAM word 0 on both references
    set_pitch(8'h50);
    set_csrw(16'h1000);
    cursor_on;
    settle;
    sample_cell(5'd0, 6'd0, 4'd15, mask);
    check("cursor_csrw_12bit_mask", {8'h00, mask}, 16'h0000);

    // ---- 7. display start (the SCROLL command's first word) ----
    // Both references read the text plane from LOW12(sad): a marker at word 0x410 must
    // appear at cell 0 of row 0 when the display start is 0x410.
    fill_plane(8'h41, 8'h00, 8'h01);
    set_word(12'h410, 8'h42, 8'h00, 8'h01);
    set_sad(16'h0410); set_pitch(8'h50); cursor_off;
    settle;
    sample_cell(5'd0, 6'd0, 4'd15, mask);
    check("scroll_sad_display_start", {8'h00, mask}, 16'h00FF);

    // ---- 8. PITCH bit 0 ----
    // NP2kai maketext: `pitch = gdc.m.para[GDC_PITCH] & 0xfe`. A pitch of 0x51 therefore
    // steps 0x50 words per text row, so row 1 cell 0 reads word 0x50 (the marker). This
    // core keeps the odd byte and steps 0x51, so row 1 cell 0 reads the blank word 0x51.
    fill_plane(8'h41, 8'h00, 8'h01);
    set_word(12'h050, 8'h42, 8'h00, 8'h01);
    set_sad(16'h0000); set_pitch(8'h51); cursor_off;
    settle;
    sample_cell(5'd1, 6'd0, 4'd15, mask);
    check("pitch_odd_stride_masked", {8'h00, mask}, 16'h00FF);

    // ---- 9. attribute bit 4: the vertical line, at the references' dot ----
    // NP2kai maketext draws TXTATR_VL (0x10) as a vertical line whenever mode1 bit 0 is
    // clear, on every raster row and independent of the visible bit - and at the glyph's
    // PATTERN BIT 3, pixel 4 of the cell: maketext ORs into byte 4 of the cell
    // (vram/maketext.c:395) and QEMU ORs 0x08 into the pattern, whose bit 3 lights dest[4]
    // (pc98-vga.c:4349). Sample mask[7-k] is dot 8*col+k, so pixel 4 is bit 3: mask 0x08.
    // A cell that lights dot 7 (mask 0x01) is the historical right-edge reading and fails
    // here; so does lighting nothing.
    fill_plane(8'h41, 8'h00, 8'h11);   // blank glyph, visible + bit 4
    set_sad(16'h0000); set_pitch(8'h50); cursor_off;
    settle;
    sample_cell(5'd0, 6'd0, 4'd15, mask);
    check("attr_bit4_vertical_line", {8'h00, mask}, 16'h0008);

    // ---- 11/12. the cursor's non-blink bit is cs[1]&0x20 SET, not clear ----
    // Both references treat bit 5 SET as steady (NP2kai forces curdisp=1,
    // vram/maketext.c:99-101; QEMU ORs it into the visible condition, pc98-vga.c:1353) and
    // bit 5 CLEAR as blinking. The polarity is invisible to a single sample: it only shows
    // when the blink phase changes, which is why the case above never caught it. Sample the
    // same cell at BOTH phases (cur_phase forced).
    fill_plane(8'h41, 8'h00, 8'h01);   // blank glyph, visible, cursor-on-cell
    set_sad(16'h0000); set_pitch(8'h50);
    set_csrw(16'h0000);
    cursor_on;                         // cs[1] bit 5 SET
    settle;
    sample_cell_cp(5'd0, 6'd0, 4'd15, 1'b0, mask);
    check("cursor_nonblink_phase0", {8'h00, mask}, 16'h00FF);
    sample_cell_cp(5'd0, 6'd0, 4'd15, 1'b1, mask);
    check("cursor_nonblink_phase1", {8'h00, mask}, 16'h00FF);
    // bit 5 CLEAR -> the cursor blinks: visible at phase 0, hidden at phase 1.
    set_cursor(8'h8F, 8'h00, 8'h7B);
    settle;
    sample_cell_cp(5'd0, 6'd0, 4'd15, 1'b0, mask);
    check("cursor_blink_phase0",    {8'h00, mask}, 16'h00FF);
    sample_cell_cp(5'd0, 6'd0, 4'd15, 1'b1, mask);
    check("cursor_blink_phase1",    {8'h00, mask}, 16'h0000);

    // ---- 13. the character blink duty is 3:1, not 1:1 ----
    // NP2kai's `blinkdisp = (count & 3) ? 1 : 0` blanks for ONE of every four blink
    // counts (vram/maketext.c:117, used at :296-299), so a blinking cell is visible 3/4 of
    // the cycle. An inked glyph makes the whole cell the mask.
    fill_plane(8'h42, 8'h00, 8'h03);   // glyph 0xFF, visible + blink
    set_sad(16'h0000); set_pitch(8'h50); cursor_off;
    settle;
    sample_cell_fc(5'd0, 6'd0, 4'd15, 6'd0,  mask);   // frame_cnt[5:4]=0 -> blank
    check("blink_duty_off_quarter",  {8'h00, mask}, 16'h0000);
    sample_cell_fc(5'd0, 6'd0, 4'd15, 6'd16, mask);   // frame_cnt[5:4]=1 -> visible
    check("blink_duty_on_3quarter",  {8'h00, mask}, 16'h00FF);
    sample_cell_fc(5'd0, 6'd0, 4'd15, 6'd48, mask);   // frame_cnt[5:4]=3 -> visible
    check("blink_duty_on_late",      {8'h00, mask}, 16'h00FF);

    // ---- 10. the underline overlay and the visible bit ----
    // NP2kai's underline is driven by line_effect, accumulated over the line's attributes
    // before the TXTATR_ST test clears bitmap, so a cell with underline but no visible bit
    // still gets its underline. This core ANDs ul_on with r_attr[0], so it draws nothing.
    fill_plane(8'h41, 8'h00, 8'h08);   // blank glyph, underline only
    set_sad(16'h0000); set_pitch(8'h50); cursor_off;
    settle;
    sample_cell(5'd0, 6'd0, 4'd15, mask);
    check("underline_without_visible_bit", {15'b0, (mask != 8'h00)}, 16'h0001);

    // ---- 14. CSRW with TWO parameters latches the address ----
    // Both references apply each parameter byte as it arrives (NP2kai gdc_work writes
    // para[ptr++]; QEMU calls gdc_cmd_csrw per byte), and the authentic BIOS sends only two
    // CSRW bytes - the cursor word's low then high byte (BANK6@0x49cf-0x49e1). An
    // apply-at-completion model needs three and never latches, so the cursor stays put: this
    // is why the text cursor is dead at the DOS prompt. Park the cursor at word 0 with the
    // full form, then move it to word 3 with two bytes.
    fill_plane(8'h41, 8'h00, 8'h01);   // blank glyph, visible
    set_sad(16'h0000); set_pitch(8'h50);
    set_csrw(16'h0000);
    cursor_on;
    settle;
    sample_cell(5'd0, 6'd0, 4'd15, mask);
    check("csrw_three_param_baseline", {8'h00, mask}, 16'h00FF);
    set_csrw2(16'h0003);               // word 3, two parameter bytes only
    settle;
    sample_cell(5'd0, 6'd0, 4'd15, mask);
    check("csrw_two_param_old_cell",   {8'h00, mask}, 16'h0000);
    sample_cell(5'd0, 6'd3, 4'd15, mask);
    check("csrw_two_param_new_cell",   {8'h00, mask}, 16'h00FF);

    // ---- 15. CSRFORM with ONE parameter enables the cursor ----
    // The authentic BIOS sends one byte - cs[0] with bit 7 set (BANK7@0x6a33-0x6a43) - and
    // leaves cs[1]/cs[2] at the chip's power-on values, so the cursor blinks (bit 5 clear)
    // over the whole cell (bottom 0x7B>>3 = 15). An apply-at-completion model needs three
    // and never latches the enable, so the cursor never appears.
    fill_plane(8'h41, 8'h00, 8'h01);   // blank glyph, visible
    set_sad(16'h0000); set_pitch(8'h50);
    set_csrw(16'h0000);
    cursor_off;                        // cs[0]=0x0F disabled, cs[1]=0, cs[2]=0x7B
    settle;
    sample_cell_cp(5'd0, 6'd0, 4'd15, 1'b0, mask);
    check("csrform_one_param_off",     {8'h00, mask}, 16'h0000);
    set_cursor1(8'h8F);                // cs[0] bit 7 set, one parameter only
    settle;
    sample_cell_cp(5'd0, 6'd0, 4'd15, 1'b0, mask);
    check("csrform_one_param_on_p0",   {8'h00, mask}, 16'h00FF);
    sample_cell_cp(5'd0, 6'd0, 4'd15, 1'b1, mask);
    check("csrform_one_param_on_p1",   {8'h00, mask}, 16'h0000);

    // ---- 16. the cursor's blink period IS the CSRFORM blink FIELD, in frames ----
    // The machine's BOOT CSRFORM: cs[0] = 0x8F (enable, 16 raster lines), cs[1] =
    // 0x00 (blinking, top row 0), cs[2] = 0x7B (bottom row 15, rate bits 0b011). The rate field
    // {cs[2][2:0], cs[1][7:6]} is therefore 0b01100 = 12, which NP2kai doubles to a 24-frame
    // toggle - a 48-frame blink cycle, 1.175 Hz at the machine's 56.42 Hz raster. cs[2][2:0] = 3
    // is what every reference writes (the BIOS's own tables `(raster << 3) | 3`, FreeBSD gdc.c's
    // `12 << 6`, the clean-room QEMU BIOS's `(CRT_RASTER << 3) + 3`), so this is the machine's
    // ordinary rate. Reading cs[1][7:6] ALONE - the field's low two bits - reports 64 frames,
    // the 2.7x-slow cursor measured against a real Xe10.
    fill_plane(8'h41, 8'h00, 8'h01);   // blank glyph, visible
    set_sad(16'h0000); set_pitch(8'h50); set_csrw(16'h0000);
    set_cursor(8'h8F, 8'h00, 8'h7B);
    settle;
    cursor_blink_period(6'd0, 2, 60, tgl, cyc, seen, bm0, bm1);
    check("cursor_blink_boot_cell_pair",     {8'h00, (bm0 ^ bm1)}, 16'h00FF);
    check("cursor_blink_boot_toggle_frames", tgl[15:0], 16'd24);
    $display("NOTE cursor_blink_boot: toggle %0d frames, blink cycle %0d frames", tgl, 2*tgl);

    // ---- 17. the field's HIGH bits are cs[2][2:0], its LOW bits cs[1][7:6] ----
    // cs[1] = 0x40 contributes 0b01 and cs[2] = 0x79 contributes 0b001, so the field is
    // 0b00101 = 5: a 10-frame toggle and a 20-frame blink cycle. Dropping cs[2][2:0] gives 1
    // (2 frames) and swapping the two halves gives 0b01001 = 9 (18 frames), so the case pins
    // both the missing bits and their order.
    set_cursor(8'h8F, 8'h40, 8'h79);
    settle;
    cursor_blink_period(6'd0, 3, 40, tgl, cyc, seen, bm0, bm1);
    check("cursor_blink_field_split_toggle_frames", tgl[15:0], 16'd10);
    check("cursor_blink_field_split_cycle_frames",  cyc[15:0], 16'd20);

    // ---- 18. a blink field of ZERO is NP2kai's 64, not a divider of one ----
    // NP2kai: `timing = ...; if (!timing) timing = 0x40` (pccore.c:1476-1479). The five-bit
    // field is 0 here (cs[1] bits 7:6 and cs[2] bits 2:0 all clear), so the toggle period is 64
    // frames and a zero field must not be read as the fastest rate.
    set_cursor(8'h8F, 8'h00, 8'h78);
    settle;
    check("cursor_blink_field_zero_64", {9'b0, dut.u_crtc.cur_timing}, 16'd64);

    // ---- 19. the 0x7C read, the 5-bit CRTC registers ----
    // 0x7C's GUEST READ IS OPEN BUS 0xFF. This pair of cases used to assert
    // NP2kai's crtc_i7c (io/crtc.c:46-50), i.e. that the read
    // answers the LIVE GRCG mode register. The machine refutes that: probe2
    // /RDBACK wrote 0x5A and read 0xFF anyway
    // (`port=007C before=FF wrote=5A after=FF back=FF`, docs/probes/RDBACK.TXT:152),
    // so the register is write-only and NP2kai is the weaker source here. The
    // GRCG's mode register does not reach the CRTC at all, so the read below
    // can only be the open-bus answer.
    read_io(8'h7C, value);
    check("grcg_mode_readback_open_bus", {8'h00, value}, 16'h00ff);
    // NP2kai's crtc_o70 masks every render register to FIVE bits (`dat &= 0x1f`,
    // io/crtc.c:10-17): 0xFF written reads back 0x1F. FAIL-FIRST: 0xFF before.
    write_io(8'h70, 8'hFF);
    read_io(8'h70, value);
    check("crtc_pl_five_bits", {8'h00, value}, 16'h001f);
    write_io(8'h7A, 8'hFF);
    read_io(8'h7A, value);
    check("crtc_sdr_five_bits", {8'h00, value}, 16'h001f);

    f = 0;  // keep the frame counter tap live for the watchdog trace

    // ==== VERDICT ====
    $display("NOTE gdc_text_regs: %0d cases, %0d mismatched, sim %0t", cases, errors, $time);
    if (errors == 0) begin
      $display("TB_PC9821_GDC_TEXT_REGS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GDC_TEXT_REGS: FAIL (%0d of %0d cases)", errors, cases);
  end

  initial begin
    #800_000_000;
    $fatal(1, "TB_PC9821_GDC_TEXT_REGS: TIMEOUT");
  end

endmodule

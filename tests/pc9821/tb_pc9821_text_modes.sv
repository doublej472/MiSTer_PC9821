`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_TEXT_MODES: the text plane's ROW GEOMETRY follows the master GDC and the CRTC the way NP2kai's maketext() does (vram/maketext.c:162-435, transcribed in this bench as a whole-frame loop over ints): for every active raster line of a frame, the TRAM word the scanout fetches for column 1 is that line's character-row address plus one, the pixel drawn there is the glyph line only while 0 <= nowline < min(CL,16), the underline lights the row's last line (nowline + 1 == lines) and the cursor the lines nowline in [CSRFORM top, bottom], and on each row's first line the kanji row-cache walk asks for exactly the row that is drawn next (its address and a bank that differs from the one on screen and is the one that row is then drawn from) - over the 25-line default, NP2kai's BIOS 400-20 setting (LR 0x13, PL 0x1E, BL 0x11, CL 0x10: 20 rows of 20 lines, two blank lines above and below each 16-line glyph), a 30-row 480-line SYNC block, each CRTC register on its own (PL below 16 starting the row inside the glyph, BL, CL, the GDC LR against a different CRTC row length), smooth scrolling with SUR = 0 (SSL lines eaten at the top, the SDR+1-row region cut) and with an unscrolled SUR band above the region, and 2-, 3- and 4-partition split screens from the full 16-byte PRAM (a partition switch in mid-row, the 0x74 PRAM command's offset, and the wrap from the fourth partition back to the first), rows short enough that the row index passes 63 (LR 5 / BL 5: 67 rows, LR 1 / BL 1: 200 rows on 400 lines, NP2kai's row address accumulating with no row limit, maketext.c:321), and the row-0 re-walk after a mid-frame start-word change reading all 80 cells of row 0 at the new start word although the sequencer's next row has moved to partition 1 by the walk's second line. FAIL-FIRST: the pre-change scanout decoded every line as a fixed 16-line row of one partition (row = vline >> 4) and ignored the CRTC registers and the PRAM lengths, so every case but the 25-line default and the 30-row block (whose 16-line rows the old decode already drew; its walk request did not follow) mismatches there.
//
// THE REFERENCE is NP2kai vram/maketext.c maketext() - `np2_maketext` below is its loop with
// NP2kai's variable names, run once per case for the whole frame, independent of the RTL's
// one-pass-per-clock form - and bios/bios18.c crtdata[] for the BIOS rows. No capture of a 20/30
// line mode or of the CRTC scroll registers exists (docs/probes/RDBACK.TXT:82-87 records the
// DOS values only: PL 00 BL 0F CL 10 SSL/SUR/SDR 00, which case 0 uses).
//
// HOW IT LOOKS. The whole TRAM holds code 0x00FF with attribute 0xF1 (white, visible, bit 4) and
// MODE FF1 bit 0 is set, so every cell draws the simple-graphics block of its code: 0xFF lights
// every dot of every glyph line (NP2kai font.c font_setchargraph), and the font ROM is not
// needed. A glyph line is then a lit dot and a blank line of the row a dark one, so the pixel at
// dot 12 (column 1) shows nowline's class directly.

module tb_pc9821_text_modes;
  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;
  reg pixel_ce = 1;
  reg rst_n_sys = 0;

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
  reg [3:0] bios_set = 4'd0;
  wire vsync_active, vsync_irq, vsync_edge;
  reg vsync_irq_arm = 0;
  wire disp_on, gfx_access_page, gfx_disp, gfx_egc_gate;
  wire [15:0] gfx_line_addr;
  wire gfx_walk_page;
  wire [6:0] cfg_ram_mib = 7'd0;
  wire cfg_seed_en = 1'b0;
  wire cfg_seed_reload = 1'b0;
  wire [15:0] dbg_sad;
  wire [7:0] dbg_pitch;
  wire dbg_col40, dbg_disp;
  wire [15:0] dbg_wk_skips;
  wire text_opaque, text_cell;
  wire [11:0] text_colour;
  wire [9:0] pix_dot;
  wire pix_h_active, pix_v_active;
  wire gfx_mode16;
  wire [31:0] gfx_dig;
  wire        pal_wr_en;
  wire [3:0]  pal_wr_idx;
  wire [1:0]  pal_wr_chan;
  wire [3:0]  pal_wr_data;
  wire        pal_commit;
  wire hs_out, vs_out, de_out;
  wire cg_rd_hold, cg_win_byte_hold;
  wire gfx_odd_line;
  reg [2:0] cfg_fdd_mode = 3'd0;

  // ==== DUT ====
  pc9821_gdc_text_dut dut (.*);

  integer errors = 0, checks = 0;

  // ==== STIMULUS ====
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
  task automatic fill_plane(input [7:0] clo, input [7:0] chi, input [7:0] attr);
    integer k;
    begin
      for (k = 0; k < 16'h1000; k = k + 1) begin
        write_tram({1'b0, k[11:0], 1'b0}, clo);
        write_tram({1'b0, k[11:0], 1'b1}, chi);
        write_tram({1'b1, k[11:0], 1'b0}, attr);
      end
    end
  endtask
  task automatic gcmd(input [7:0] c); begin write_io(8'h62, c); end endtask
  task automatic gpar(input [7:0] p); begin write_io(8'h60, p); end endtask

  // The case's whole configuration.
  integer c_lr, c_pl, c_bl, c_cl, c_ssl, c_sur, c_sdr;
  integer c_sad[0:3], c_len[0:3];
  integer c_lf;                 // the SYNC block's active lines (400 or 480)
  integer c_csr_on, c_csr_word, c_csr_top, c_csr_bot;
  integer c_ul;                 // the attribute's underline bit is set
  integer c_pram_cmd;           // 0x70 (all sixteen bytes) or 0x74 (partitions 1-3 only)

  task automatic defaults;
    integer k;
    begin
      c_lr = 'h0F; c_pl = 0; c_bl = 'h0F; c_cl = 'h10; c_ssl = 0; c_sur = 0; c_sdr = 0;
      for (k = 0; k < 4; k = k + 1) begin c_sad[k] = 0; c_len[k] = 0; end
      c_lf = 400; c_csr_on = 0; c_csr_word = 0; c_csr_top = 0; c_csr_bot = 15; c_ul = 0;
      c_pram_cmd = 'h70;
    end
  endtask

  // Program the GDC and the CRTC with the case.
  integer cur_attr = -1;
  task automatic program_case;
    integer k, w;
    begin
      // The attribute's underline bit (bit 3) follows the case.
      if (cur_attr != (c_ul ? 'hF9 : 'hF1)) begin
        cur_attr = c_ul ? 'hF9 : 'hF1;
        fill_plane(8'hFF, 8'h00, cur_attr[7:0]);
      end
      // SYNC (0x0F): NP2kai's defsyncm24 {10 4e 07 25 07 07 90 65} (io/gdc.c:42), with lf
      // replaced for the 480-line case: lf 480 = 0x1E0 -> bytes 6/7 = E0, (vbp << 2) | 1.
      gcmd(8'h0F);
      gpar(8'h10); gpar(8'h4E); gpar(8'h07); gpar(8'h25); gpar(8'h07); gpar(8'h07);
      gpar(c_lf[7:0]); gpar({6'd25, c_lf[9:8]});
      gcmd(8'h47); gpar(8'd80);                                      // PITCH 80
      // CSRFORM: byte 0 = cursor enable | LR; byte 1 = non-blink (bit 5) | top; byte 2 =
      // bottom << 3 | 3 (the BIOS's own rate bits).
      gcmd(8'h4B);
      gpar({c_csr_on[0], 2'b00, c_lr[4:0]});
      gpar({3'b001, c_csr_top[4:0]});
      gpar({c_csr_bot[4:0], 3'b011});
      gcmd(8'h49); gpar(c_csr_word[7:0]); gpar(c_csr_word[15:8]); gpar(8'h00);   // CSRW
      // PRAM: partition k = {SAD lo, SAD hi, LEN << 4 lo, LEN << 4 hi} (maketext.c:196-198).
      gcmd(c_pram_cmd[7:0]);
      for (k = (c_pram_cmd - 'h70) / 4; k < 4; k = k + 1) begin
        w = c_len[k] << 4;
        gpar(c_sad[k][7:0]); gpar(c_sad[k][15:8]); gpar(w[7:0]); gpar(w[15:8]);
      end
      write_io(8'h70, c_pl[7:0]);  write_io(8'h72, c_bl[7:0]);  write_io(8'h74, c_cl[7:0]);
      write_io(8'h76, c_ssl[7:0]); write_io(8'h78, c_sur[7:0]); write_io(8'h7A, c_sdr[7:0]);
    end
  endtask

  // ==== THE REFERENCE: NP2kai vram/maketext.c maketext(), one frame ====
  integer m_addr [0:575];
  integer m_now  [0:575];
  integer m_new  [0:575];
  integer m_lines, m_cl;
  task automatic np2_maketext(input integer ymax);
    integer TEXT_LR, TEXT_PL, TEXT_BL, TEXT_CL, TEXT_SUR, TEXT_SDR;
    integer topline, lines, nowline, wait2, pitch, esi, scroll, scrp, wait1, LRcnt;
    integer reloadline, linecnt, y, rowaddr, newrow;
    begin
      TEXT_LR  = c_lr;                                   // :163
      TEXT_PL  = c_pl;
      TEXT_BL  = c_bl + 1;
      TEXT_CL  = c_cl;
      TEXT_SUR = c_sur;
      TEXT_SDR = -1;
      if (TEXT_CL > 16) TEXT_CL = 16;                    // :169-171
      if (TEXT_PL >= 16) begin                           // :172-182
        topline = TEXT_PL - 32;
        lines = TEXT_BL;
      end else begin
        topline = TEXT_PL;
        lines = TEXT_BL - topline;
        if (lines <= 0) lines = lines + 32;
      end
      nowline = topline;
      wait2 = 0;                                         // :185-192
      if (TEXT_SUR == 0) begin
        wait2 = c_ssl;
        TEXT_SDR = c_sdr + 1;
      end else TEXT_SUR = 32 - TEXT_SUR;
      pitch = 80 & 'hFE;                                 // :194
      esi = c_sad[0] & 'hFFF;                            // :196-198
      scroll = c_len[0];
      scrp = 0;
      wait1 = 0; LRcnt = 0; reloadline = 0; linecnt = 0;
      rowaddr = 0; newrow = 0;
      y = 0;
      while (y < ymax) begin                             // :208
        if (wait1 == 0) begin                            // :209-217 (LRcnt is a UINT8)
          if (LRcnt == 0) begin LRcnt = TEXT_LR; reloadline = 1; end
          else LRcnt = LRcnt - 1;
        end else wait1 = wait1 - 1;
        if (reloadline) begin                            // :218-322
          reloadline = 0;
          rowaddr = esi;
          newrow = 1;
          esi = (esi + pitch) & 'hFFF;
        end
        if ((TEXT_SDR == 0) && (nowline >= topline + c_ssl)) begin   // :324-328
          nowline = topline;
          TEXT_SDR = TEXT_SDR - 1;
          wait1 = c_ssl;
        end
        if (wait2 == 0) begin                            // :330-420
          m_addr[y] = rowaddr; m_now[y] = nowline; m_new[y] = newrow;
          newrow = 0;
          y = y + 1;
          scroll = scroll - 1;                           // `if (!(--scroll))` (UINT)
          if (scroll == 0) begin
            scrp = (scrp + 1) & 3;
            esi = c_sad[scrp] & 'hFFF;
            scroll = c_len[scrp];
            reloadline = 1;
          end
        end else wait2 = wait2 - 1;                      // :422-424
        nowline = nowline + 1;                           // :426-434
        if ((TEXT_SDR != 0) && (nowline >= lines)) begin
          nowline = topline;
          TEXT_SDR = TEXT_SDR - 1;
          linecnt = linecnt + 1;
          if (linecnt == TEXT_SUR) begin
            wait2 = c_ssl;
            TEXT_SDR = c_sdr + 1;
          end
        end
      end
      m_lines = lines;
      m_cl = TEXT_CL;
    end
  endtask

  // ==== CHECKS ====
  task automatic fail(input [8*40-1:0] name, input integer y, input integer got, input integer want);
    begin
      errors = errors + 1;
      if (errors <= 40)
        $display("MISMATCH %0s line %0d: rtl=%0d np2kai=%0d", name, y, got, want);
    end
  endtask

  // Wait for the given line's given dot (at the falling edge, so the registered state is the
  // cycle's and the combinational outputs are settled).
  task automatic at_dot(input integer y, input integer d);
    begin
      while (!((dut.u_crtc.vline == y[9:0]) && (dut.u_crtc.hdot == d[9:0]))) @(negedge clk_sys);
    end
  endtask

  task automatic check_frame(input [8*40-1:0] name);
    integer y, y2, first, nexta, ymax, wkaddr, pend_bank, have_pend, want_pix, glyph, csr, ul;
    integer case_err;
    begin
      case_err = errors;
      ymax = dut.u_crtc.VACTIVE;
      np2_maketext(ymax);
      first = -1;
      for (y = 0; y < ymax; y = y + 1) if (first < 0 && m_new[y]) first = y;
      // Start on a fresh frame.
      at_dot(ymax, 0);
      have_pend = 0; pend_bank = 0;
      for (y = 0; y < ymax; y = y + 1) begin
        checks = checks + 1;
        // ---- dot 0: the cache walk request ----
        at_dot(y, 0);
        if (m_new[y]) begin
          nexta = -1;
          for (y2 = y + 1; y2 < ymax; y2 = y2 + 1) if (nexta < 0 && m_new[y2]) nexta = m_addr[y2];
          if (nexta < 0) nexta = m_addr[first];        // the next frame's first row
          wkaddr = (dut.u_crtc.o_v_sad + dut.u_crtc.o_wk_k * 80) & 'hFFF;
          if (dut.u_crtc.o_wk_go !== 1'b1) fail({name, " wk_go"}, y, dut.u_crtc.o_wk_go, 1);
          if (wkaddr != nexta) fail({name, " wk_next_row_addr"}, y, wkaddr, nexta);
        end else if (dut.u_crtc.o_wk_go !== 1'b0) fail({name, " wk_go_off_row_start"}, y, 1, 0);
        // ---- dot 3: column 1's code fetch, and the bank the line draws from ----
        at_dot(y, 3);
        if (dut.u_crtc.tram_vid_addr !== {1'b0, m_addr[y][11:0] + 12'd1, 1'b0})
          fail({name, " fetch_word"}, y, dut.u_crtc.tram_vid_addr[12:1], (m_addr[y] + 1) & 'hFFF);
        if (m_new[y]) begin
          if (have_pend && (dut.u_crtc.jc_rd_bank != pend_bank))
            fail({name, " bank_filled_vs_drawn"}, y, dut.u_crtc.jc_rd_bank, pend_bank);
          if (dut.u_crtc.o_wk_bank == dut.u_crtc.jc_rd_bank)
            fail({name, " walk_bank_is_drawn_bank"}, y, dut.u_crtc.o_wk_bank, -1);
          pend_bank = dut.u_crtc.o_wk_bank; have_pend = 1;
        end
        // ---- dot 12: column 1's pixel ----
        at_dot(y, 12);
        glyph = (m_now[y] >= 0) && (m_now[y] < m_cl);                          // :348
        csr = c_csr_on && (((m_addr[y] + 1) & 'hFFF) == c_csr_word) &&
              (m_now[y] >= c_csr_top) && (m_now[y] <= c_csr_bot);              // :334-336
        ul = c_ul && ((m_now[y] + 1) == m_lines);                              // :375-376
        want_pix = (glyph ^ csr) | ul;
        if (text_opaque !== want_pix[0]) fail({name, " pixel"}, y, text_opaque, want_pix);
      end
      // The last row's walk named the next frame's first row: its bank is the one row 0 draws.
      at_dot(0, 3);
      if (have_pend && (dut.u_crtc.jc_rd_bank != pend_bank))
        fail({name, " bank_frame_wrap"}, 0, dut.u_crtc.jc_rd_bank, pend_bank);
      $display("%0s %0s: %0d lines, lines/row %0d, CL %0d, %0d mismatch(es)",
               (errors == case_err) ? "ok      " : "FAILED  ", name, ymax, m_lines, m_cl,
               errors - case_err);
    end
  endtask

  task automatic run_case(input [8*40-1:0] name);
    integer f;
    begin
      program_case;
      // Two frame ends: the GDC's SYNC copy and the scanout snapshot both land at one.
      f = 0;
      while (f < 2) begin
        @(negedge clk_sys);
        if (dut.u_crtc.frame_end && pixel_ce) f = f + 1;
      end
      check_frame(name);
    end
  endtask

  // ---- the row-0 re-walk's TRAM reads (case 16) ----
  // Armed by the case: the walk that starts on the re-walk slot (crtc's stale_slot) is
  // followed to its end, and every TRAM word it reads must be the frame's row 0 at the NEW
  // display start: row 0's address is the start word itself (maketext.c:196-198 `esi =
  // LOW12(...)`), plus the cell (80 columns).
  integer sw_base = 0, sw_reads = 0, sw_bad = 0;
  reg     sw_arm = 0, sw_on = 0;
  always @(posedge clk_sys) begin
    if (sw_on && pixel_ce && dut.u_cg.wk_tr_read) begin
      sw_reads = sw_reads + 1;
      if (dut.u_cg.wk_tr_addr[12:1] !== ((sw_base + dut.u_cg.wk_cell) & 'hFFF)) begin
        if (sw_bad < 4)
          $display("MISMATCH stale row-0 re-walk: cell %0d read word %03h, want %03h",
                   dut.u_cg.wk_cell, dut.u_cg.wk_tr_addr[12:1], (sw_base + dut.u_cg.wk_cell) & 'hFFF);
        sw_bad = sw_bad + 1;
      end
    end
    if (sw_on && (dut.u_cg.wk_state == 3'd0) && (sw_reads > 0)) sw_on = 0;
    if (sw_arm && pixel_ce && dut.u_cg.wk_go && (dut.u_cg.hdot == 10'd0) &&
        (dut.u_cg.wk_state == 3'd0) && dut.u_crtc.stale_slot) begin
      sw_on = 1; sw_arm = 0;
    end
  end

  // ==== VERDICT ====
  initial begin
    repeat (8) @(negedge clk_sys);
    rst_n_sys = 1;
    // The plane is filled by program_case: simple-graphics block 0xFF, white, visible.
    write_io(8'h68, 8'h01);            // MODE FF1 bit 0: simple graphics
    gcmd(8'h0D);                       // START

    // 0. The 25-line default: the CRTC as DOS leaves it (RDBACK.TXT:82-87), LR 15.
    defaults; run_case("25-line default");
    // 1. NP2kai bios18.c crtdata[2] "400-20" {raster 0x13, pl 0x1e, bl 0x11, cl 0x10} and the
    //    400-20 CSRFORM {lr 0x13, cfi 0x9b} (bios18.c:73-75): cursor lines 0..19 of nowline.
    defaults; c_lr = 'h13; c_pl = 'h1E; c_bl = 'h11; c_cl = 'h10;
    c_csr_on = 1; c_csr_word = 81; c_csr_top = 0; c_csr_bot = 'h9B >> 3;
    run_case("20-line BIOS 400-20");
    // 2. 30 rows: a 480-line SYNC block, LR 15, the 25-line CRTC rows (bios18.c's 480-30 row
    //    {0x0f, 0x00, 0x0f, 0x10}), underline on. The fetch and the pixels of rows 25-29 were
    //    already right before this change (16-line rows from vline); what this case adds is the
    //    walk request, which used to wrap to row 0 after row 24.
    defaults; c_lf = 480; c_ul = 1; run_case("30-line 480-line SYNC");
    // 3. PL below 16: nowline starts at PL and the row ends at nowline == lines - 1, with
    //    lines = BL + 1 - PL (maketext.c:177-181) - so PL 2, BL 0x13 runs nowline 2..17, a
    //    16-line row whose last two lines are past the glyph (dark) and carry the underline.
    defaults; c_pl = 2; c_bl = 'h13; c_ul = 1; run_case("PL 2 BL 0x13");
    // 4. BL: an 18-line CRTC row against the GDC's 18-line LR.
    defaults; c_lr = 'h11; c_bl = 'h11; c_ul = 1; run_case("BL 0x11 LR 0x11");
    // 5. CL: only 8 of the 16 glyph lines.
    defaults; c_cl = 8; run_case("CL 8");
    // 6. The GDC's LR and the CRTC's BL are separate counters: LR 15 against a 20-line row.
    defaults; c_bl = 'h13; c_ul = 1; run_case("LR 15 against BL 0x13");
    // 7. Smooth scroll, SUR = 0: SSL 5 lines eaten at the top, rows 0-3 (SDR 3) scrolled.
    defaults; c_ssl = 5; c_sdr = 3; c_ul = 1;
    c_csr_on = 1; c_csr_word = 81; c_csr_top = 2; c_csr_bot = 13;
    run_case("smooth SSL 5 SDR 3");
    // 8. A scroll region below an unscrolled band: SUR 29 (32 - 29 = 3 rows), SDR 5, SSL 7.
    defaults; c_sur = 29; c_ssl = 7; c_sdr = 5; c_ul = 1; run_case("region SUR 29 SDR 5 SSL 7");
    // 9. Smooth scroll in the 20-line mode.
    defaults; c_lr = 'h13; c_pl = 'h1E; c_bl = 'h11; c_ssl = 3; c_sdr = 31; c_ul = 1;
    run_case("20-line SSL 3 SDR 31");
    // 10. Two partitions, switching in mid-row (100 = 6 rows + 4 lines).
    defaults; c_len[0] = 100; c_sad[1] = 'h400; run_case("2 partitions");
    // 11. Three partitions.
    defaults; c_len[0] = 64; c_sad[1] = 'h300; c_len[1] = 96; c_sad[2] = 'h600; c_ul = 1;
    run_case("3 partitions");
    // 12. Four partitions on the 480-line raster, 100 lines each, so line 400 wraps back to
    //     partition 0 (`scrp = (scrp + 4) & 0x0c`, maketext.c:415).
    defaults; c_lf = 480;
    c_sad[0] = 'h000; c_len[0] = 100; c_sad[1] = 'h200; c_len[1] = 100;
    c_sad[2] = 'h400; c_len[2] = 100; c_sad[3] = 'h600; c_len[3] = 100;
    run_case("4 partitions with wrap");
    // 13. PRAM command 0x74 writes from byte 4 on: partition 1 only (gdc_cmd.tbl:133).
    // Partition 0's bytes were written by case 12's 0x70 (start 0, 100 lines); this case's
    // 0x74 must leave them, so the model keeps them too.
    defaults; c_pram_cmd = 'h74; c_len[0] = 100; c_sad[1] = 'h500;
    run_case("PRAM 0x74 offset");
    // 14. Short rows on the 400-line raster: LR 5 / BL 5 (6-line rows) is 67 rows and LR 1 /
    //     BL 1 (2-line rows) 200 rows, so the row index runs past 63. NP2kai steps the row
    //     address by accumulation with no row limit (maketext.c:321 `esi = LOW12(esi +
    //     pitch);`), so row 64 is 64 x 80 words on, not row 0 again. These frames walk all
    //     4096 words, so the start word is ODD: column 1 then always reads an even word and
    //     never one of the memory-switch cells (odd words 0xFF1..0xFFF, 0xA3FE2 + i*4 - NP2kai
    //     bios/biosmem.h MEMB_MSW1..8), whose attribute bytes the plane fill cannot set.
    defaults; c_lr = 5; c_bl = 5; c_cl = 6; c_sad[0] = 1; run_case("LR 5 BL 5: 67 rows");
    defaults; c_lr = 1; c_bl = 1; c_cl = 2; c_ul = 1; c_sad[0] = 1; run_case("LR 1 BL 1: 200 rows");

    // 16. The row-0 re-walk keeps the start word it began with. Partition 0 is one 16-line
    //     row and partition 1 starts at 0x400, so by the line after the re-walk slot the line
    //     sequencer's next row is in partition 1; the start word moves mid-frame (a 0x70 PRAM
    //     write of bytes 0-1), which sets the stale flag and re-walks row 0 at the slot. The
    //     walk spans about 1.5 lines and must read row 0 at the new start for all 80 cells.
    defaults; c_len[0] = 16; c_sad[1] = 'h400; run_case("stale re-walk setup");
    at_dot(100, 0);
    gcmd(8'h70); gpar(8'h01); gpar(8'h02);      // partition 0's start word 0x0201
    sw_base = 'h201; sw_reads = 0; sw_bad = 0; sw_arm = 1;
    at_dot(dut.u_crtc.wk_slot + 3, 0);
    checks = checks + 1;
    if (sw_arm || sw_on) begin
      $display("MISMATCH stale row-0 re-walk: no walk started on the slot, or it did not finish");
      errors = errors + 1;
    end else if (sw_reads != 160) begin
      $display("MISMATCH stale row-0 re-walk: %0d TRAM reads, want 160 (80 cells x 2)", sw_reads);
      errors = errors + 1;
    end
    if (sw_bad != 0) errors = errors + 1;
    $display("%0s stale row-0 re-walk: %0d reads, %0d off the new start word",
             (sw_bad == 0 && sw_reads == 160) ? "ok      " : "FAILED  ", sw_reads, sw_bad);

    $display("NOTE text_modes: %0d lines checked, %0d mismatch(es)", checks, errors);
    if (errors == 0) begin
      $display("TB_PC9821_TEXT_MODES: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_TEXT_MODES: FAIL (%0d mismatches)", errors);
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "TB_PC9821_TEXT_MODES: TIMEOUT");
  end

endmodule

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The graphics GDC's WRITE command executes against the ITF's own GVRAM pattern test: the exact BANK4@0xFA70F stream (GRCG TDW tiles 0x33/0x55, VECTW then CSRW 00 40 08, WRITE FF FF) reads back the tile words 0x3333 at 0xA8000 and 0x5555 at 0xB0000 exactly as the Xe10 does - the test that SETS BIOS work-area 0000:054D bit 6, the FLAMEZAP boot check - and with the GRCG never armed those tile words are ABSENT, so the bit becomes correct because the test genuinely passes and never because it is forced. The write's data path is the machine's own WDAT_WORD/GDCWG rows: the uPD7220's internal bit order lands per-byte bit-reversed in CPU VRAM (GDCCURS's MASK_0001 reads expected-cpu=0080), CURS.WG - bit 3 of CSRW's third byte - selects the WDAT word directly or the 7220's bit-0 replication of it, and the four ROPs paint the mask bits with the pattern exactly as the STRICT capture rows say (W_0_FFFF_0000_0001 lands FF7F, W_2_FFFF_0001_A55A lands 5AA5, which refutes NP2kai gdcsub_write's clear formula; the capture wins) - fifteen capture vectors replayed byte for byte. Multi-unit draws walk ONE DOT along the VECTW direction per unit and advance the cursor, exactly WDAT_STEP's observed pixels (dir 0 paints word 0x0800 and leaves the cursor at 0x0828 = +40 words, dir 1 paints (0x0800,D7) and (0x0828,D8), dir 2 paints D7 then D8 inside word 0x0800, dir 3 paints (0x0800,D7) and (0x07D8,D8); directions 4-7 and the three-unit draws replay the same capture's STEP_DC01_D4..D7 and STEP_DC02_D1..D7 rows), with the cursor write-back readable over CSRR's first two bytes (the raw_curd EAD the machine reports); a second draw queued while the first walks lands its own capture outcome and nothing is dropped, and three WRITEs chained with no CSRW between them while the first still walks run in order on the cursor each one leaves (one 48-row dir-0 column from word 0x0800, every word 0x0001 as WDAT_STEP's rows paint it) with a CURD written behind them answering the advanced cursor 0x8F80, as the uPD7220's FIFO and NP2kai gdc_work's in-order execution (io/gdc.c:347-349) do. The GRCG-RMW and EGC routes carry each unit as ONE store visit on the GVRAM port share - the route latched per draw exactly as NP2kai's gdcpset_prepare latches its pset functions (io/gdc_pset.c:117-137) - and are checked DIFFERENTIALLY against the CPU path's own store of the same word, so no expected pixel is ever derived from this repo's RTL. It does not cover the FIFO/drawing-busy timing (the conformance capture's FIFO_TURN/STATE rows), the CURD read-back's five-byte shape, or the FIGD/line/rect/arc command space.

module tb_pc9821_gdc2_write;
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;   // 50 MHz: the harness's SYS_CLOCK_HZ default

  reg rst_n_sys = 0;
  reg io_wr = 0, io_rd = 0;
  reg [7:0] io_addr = 0, io_din = 0;
  wire [7:0] io_dout;
  wire [15:0] gfx_line_addr;
  wire gfx_disp;

  // The GRCG's register port and gate (pc9821_gvram_dut's own).
  reg grcg_we = 0;
  reg [7:0] grcg_addr = 0, grcg_din = 0;
  wire grcg_expand;

  // The EGC's dispatch gate and register file, straight into the harness the way
  // pc9821_iobus drives them. This bench leaves the registers at their reset values
  // (the EGC route's checks are differential), and raises the gate only in section 7.
  reg        egc_mem_gate_b = 0;
  wire [15:0] egc_access_v = 16'h0000;
  wire [15:0] egc_fgbg_v   = 16'h0000;
  wire [15:0] egc_ope_v    = 16'h0000;
  wire [15:0] egc_fg_v     = 16'hFFFF;
  wire [15:0] egc_mask_v   = 16'hFFFF;
  wire [15:0] egc_bg_v     = 16'h0000;
  wire [15:0] egc_sft_v    = 16'h0000;
  wire [15:0] egc_leng_v   = 16'hFFFF;
  wire       egc_shift_we_v = 1'b0;

  // The CPU plane-window port.
  reg  [1:0]  win_plane = 0;
  reg  [14:0] win_offset = 0;
  reg  [31:0] cpu_din = 0;
  reg  [3:0]  cpu_be = 0;
  reg         cpu_valid = 0, cpu_write = 0, cpu_line_read = 0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  wire        cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  // The GDC draw engine's visit port (pc9821_gdc2's own).
  wire        gdc_mem_valid, gdc_mem_ready, gdc_mem_write;
  wire        gdc_mem_route_egc, gdc_mem_route_grcg, gdc_mem_page;
  wire [1:0]  gdc_mem_plane;
  wire [14:0] gdc_mem_offset;
  wire [31:0] gdc_mem_din, gdc_mem_rdata;
  wire [3:0]  gdc_mem_be;
  wire        gdc_mem_resp;

  integer errors = 0;
  integer checks = 0;

  // ==== DUT ====
  pc9821_gdc2 dut_gdc2 (
      .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .pixel_ce(1'b1),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .frame_end(1'b0), .cfg_snap(1'b0), .cfg_pending(1'b0),
      .vline(10'd0), .vtotal(10'd0), .m_vbp(6'd25), .display_page(1'b0),
      .stat_blank(1'b0), .stat_vsync(1'b0),
      .egc_mem_gate(egc_mem_gate_b), .grcg_cg_gate(grcg_expand),
      .access_page(1'b0),
      .mem_valid(gdc_mem_valid), .mem_ready(gdc_mem_ready),
      .mem_write(gdc_mem_write),
      .mem_route_egc(gdc_mem_route_egc), .mem_route_grcg(gdc_mem_route_grcg),
      .mem_page(gdc_mem_page), .mem_plane(gdc_mem_plane),
      .mem_offset(gdc_mem_offset), .mem_din(gdc_mem_din), .mem_be(gdc_mem_be),
      .mem_resp(gdc_mem_resp), .mem_rdata(gdc_mem_rdata),
      .gfx_line_addr(gfx_line_addr), .gfx_disp(gfx_disp), .pegc_256(1'b0), .gdc_5m(1'b0)
  );

  pc9821_gvram_dut dut (
      .clk(clk_sys), .reset(!rst_n_sys),
      .access_page(1'b0),
      .win_plane(win_plane), .win_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .grcg_expand(grcg_expand),
      .egc_gate(egc_mem_gate_b),
      .egc_access(egc_access_v), .egc_fgbg(egc_fgbg_v), .egc_ope(egc_ope_v),
      .egc_fg(egc_fg_v), .egc_mask(egc_mask_v), .egc_bg(egc_bg_v),
      .egc_sft(egc_sft_v), .egc_leng(egc_leng_v), .egc_shift_we(egc_shift_we_v),
      .gdc_mem_valid(gdc_mem_valid), .gdc_mem_ready(gdc_mem_ready),
      .gdc_mem_write(gdc_mem_write),
      .gdc_mem_route_egc(gdc_mem_route_egc), .gdc_mem_route_grcg(gdc_mem_route_grcg),
      .gdc_mem_page(gdc_mem_page), .gdc_mem_plane(gdc_mem_plane),
      .gdc_mem_offset(gdc_mem_offset), .gdc_mem_din(gdc_mem_din),
      .gdc_mem_be(gdc_mem_be),
      .gdc_mem_resp(gdc_mem_resp), .gdc_mem_rdata(gdc_mem_rdata),
      .scan_enable(1'b0), .scan_line_tick(1'b0), .scan_page(1'b0),
      .scan_line_base(15'd0), .gfx_odd_line(1'b0),
      .line_rd_addr(7'd0), .line_rd_sel(1'b0)
  );

  // ==== STIMULUS ====
  task automatic fail(input [1023:0] what);
    begin
      $display("FAIL: %0s @ %0t", what, $time);
      errors = errors + 1;
    end
  endtask

  task automatic check16(input [15:0] got, input [15:0] exp, input [1023:0] what);
    begin
      checks = checks + 1;
      if (got !== exp) begin
        $display("MISMATCH %0s: got %04x expected %04x @ %0t", what, got, exp, $time);
        errors = errors + 1;
      end
    end
  endtask

  // The device bus writes (0xA2 command, 0xA0 parameter) and the GRCG's own port.
  task automatic io_a2(input [7:0] b);
    begin
      @(negedge clk_sys);
      io_addr = 8'hA2; io_din = b; io_wr = 1'b1;
      @(negedge clk_sys);
      io_wr = 1'b0;
      @(negedge clk_sys);
    end
  endtask
  task automatic io_a0(input [7:0] b);
    begin
      @(negedge clk_sys);
      io_addr = 8'hA0; io_din = b; io_wr = 1'b1;
      @(negedge clk_sys);
      io_wr = 1'b0;
      @(negedge clk_sys);
    end
  endtask
  task automatic grcg_wr(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk_sys);
      grcg_addr = a; grcg_din = d; grcg_we = 1'b1;
      @(negedge clk_sys);
      grcg_we = 1'b0;
      @(negedge clk_sys);
    end
  endtask

  // The CPU's own plane-window word access, in the dword-lane convention the arb
  // walks (byte lane k at plane offset {offset[14:2], k}): a word at byte offset O
  // uses lanes O[1] ? 1100 : 0011 with the word in the matching half.
  task automatic cpu_wr_word(input [1:0] plane, input [14:0] off, input [15:0] data);
    begin
      @(negedge clk_sys);
      win_plane = plane; win_offset = off;
      cpu_be   = off[1] ? 4'b1100 : 4'b0011;
      cpu_din  = off[1] ? {data, 16'h0000} : {16'h0000, data};
      cpu_write = 1'b1; cpu_valid = 1'b1;
      @(negedge clk_sys);
      while (cpu_ready !== 1'b1) @(negedge clk_sys);
      cpu_valid = 1'b0; cpu_write = 1'b0;
      @(negedge clk_sys);
    end
  endtask
  task automatic cpu_rd_word(input [1:0] plane, input [14:0] off, output [15:0] data);
    begin
      @(negedge clk_sys);
      win_plane = plane; win_offset = off;
      cpu_be   = off[1] ? 4'b1100 : 4'b0011;
      cpu_din  = 32'd0;
      cpu_write = 1'b0; cpu_valid = 1'b1;
      @(negedge clk_sys);
      while (cpu_ready !== 1'b1) @(negedge clk_sys);
      cpu_valid = 1'b0;
      @(negedge clk_sys);
      while (cpu_resp_valid !== 1'b1) @(negedge clk_sys);
      data = off[1] ? cpu_dout[31:16] : cpu_dout[15:0];
      @(negedge clk_sys);
    end
  endtask

  // The GDC command shapes this slice executes (NP2kai io/gdc_cmd.tbl): VECTW takes
  // eleven parameter bytes, MASK two, CSRW three, and the WRITE family 0/1/2 data
  // bytes by its width bits.
  task automatic gdc_vectw(input [2:0] dir, input [15:0] dc);
    integer k;
    begin
      io_a2(8'h4C);
      io_a0({5'd0, dir});
      io_a0(dc[7:0]); io_a0(dc[15:8]);
      for (k = 0; k < 8; k = k + 1) io_a0(8'h00);
    end
  endtask
  task automatic gdc_mask(input [15:0] m);
    begin
      io_a2(8'h4A); io_a0(m[7:0]); io_a0(m[15:8]);
    end
  endtask
  task automatic gdc_csrw(input [15:0] ead, input [7:0] b2);
    begin
      // ead's bits 15:14 are the GDC plane (NP2kai gdcplaneseg[] = {E,B,R,G}), its
      // low 14 bits the word in the plane; b2 bit 3 is CURS.WG.
      io_a2(8'h49); io_a0(ead[7:0]); io_a0(ead[15:8]); io_a0(b2);
    end
  endtask
  task automatic gdc_write2(input [7:0] cmd, input [7:0] d0, input [7:0] d1);
    begin
      io_a2(cmd); io_a0(d0); io_a0(d1);
    end
  endtask
  task automatic gdc_write1(input [7:0] cmd, input [7:0] d0);
    begin
      io_a2(cmd); io_a0(d0);
    end
  endtask
  // The engine drains its queue before the next observation.
  task automatic gdc_wait_idle;
    begin
      @(negedge clk_sys);
      while ((dut_gdc2.d_state !== 3'd0) || (dut_gdc2.pend_valid !== 1'b0) ||
             (dut_gdc2.cf_cnt !== 5'd0) || (dut_gdc2.cf_pop_v !== 1'b0))
        @(negedge clk_sys);
      repeat (4) @(negedge clk_sys);
    end
  endtask
  // The CSRR read-back's first two bytes (the raw_curd EAD the machine reports).
  task automatic csrr_ead(output [15:0] ead);
    reg [7:0] b0, b1;
    begin
      io_a2(8'hE0);
      @(negedge clk_sys);
      io_addr = 8'hA2; io_rd = 1'b1;
      @(negedge clk_sys);
      io_rd = 1'b0;
      @(negedge clk_sys);
      b0 = io_dout;
      io_addr = 8'hA2; io_rd = 1'b1;
      @(negedge clk_sys);
      io_rd = 1'b0;
      @(negedge clk_sys);
      b1 = io_dout;
      ead = {b1, b0};
    end
  endtask

  // A WDAT_WORD/GDCWG capture row replayed: seed the old word, program CSRW/MASK/
  // WDAT exactly as the suite's `curd`/column bytes say, read the word back. CSRW goes
  // FIRST: its third byte loads the mask with the dAD one-hot, so a MASK written before
  // it is lost - the machine's MASK_THEN_CURS_* rows (GDCCURS, STRICT) - and the rows
  // whose mask is not a one-hot (MASK_A55A ... ) are the suite's CURS-then-MASK order. The
  // expected value is the CSV's `got` column - the machine's own, never this RTL's.
  task automatic w_case(input [1023:0] name, input [1:0] rop, input wg,
                        input [15:0] old, input [15:0] src, input [15:0] mask,
                        input [15:0] got);
    reg [15:0] w;
    begin
      cpu_wr_word(2'd1, 15'h0100, old);         // plane R at word 0x0080
      gdc_csrw(16'h8080, wg ? 8'h08 : 8'h00);   // plane R, word 0x0080, WG bit
      gdc_mask(mask);
      gdc_write2(8'h20 | {6'd0, rop}, src[7:0], src[15:8]);
      gdc_wait_idle;
      cpu_rd_word(2'd1, 15'h0100, w);
      check16(w, got, name);
    end
  endtask

  // A WDAT_STEP capture row replayed: one draw of dc+1 units from (ead, mask) along
  // `dir`, checking each unit's painted word and the cursor write-back the machine's
  // raw_curd reports. `exp_words` is the changed-words list in the CSV's `changes`.
  task automatic step_case(input [1023:0] name, input [2:0] dir, input [15:0] dc,
                           input [15:0] mask, input [15:0] ead,
                           input integer nwords, input [15:0] exp_off [0:3],
                           input [15:0] exp_val [0:3], input [15:0] exp_ead);
    integer k;
    reg [15:0] w, rd_ead;
    begin
      // Clear the painted region first (the rows are SET on old 0x0000).
      for (k = 0; k < nwords; k = k + 1) cpu_wr_word(2'd1, {exp_off[k][13:0], 1'b0}, 16'h0000);
      gdc_csrw(ead, 8'h00);                     // WG = 0: the 7220 bit-0 replication
      gdc_mask(mask);
      gdc_vectw(dir, dc);
      gdc_write2(8'h23, 8'hFF, 8'hFF);          // rop 3 = SET, WDAT = FFFF
      gdc_wait_idle;
      for (k = 0; k < nwords; k = k + 1) begin
        cpu_rd_word(2'd1, {exp_off[k][13:0], 1'b0}, w);
        check16(w, exp_val[k], name);
      end
      csrr_ead(rd_ead);
      check16(rd_ead, exp_ead, name);
    end
  endtask

  // ==== CHECKS ====
  initial begin
    reg [15:0] w, exp_cpu;
    integer k;

    repeat (4) @(negedge clk_sys);
    rst_n_sys = 1;
    repeat (4) @(negedge clk_sys);

    // ---- Section 1: the ITF's own GVRAM pattern test (BANK4@0xFA70F-0xFA757) ----
    // Expected values: the ITF's own comparison constants (0x3333/0x5555, the words
    // the machine passes its test with - BIOS054D=50 on the Xe10, gdc-clock-REPORT
    // section 4/5) and NP2kai's withtdw (io/gdc_pset.c:51-61: the tile word to every
    // enabled plane per drawn unit). FAIL-FIRST: on the pre-change pc9821_gdc2 no
    // draw executes and both words read 0x0000, so this section fails there.
    $display("CHECK 1: the ITF's VECTW/CSRW/WRITE pattern test (flamezap-egc 7.1)");
    grcg_wr(8'h7C, 8'h80);            // TDW, all four planes (mode bits 3:0 active low)
    grcg_wr(8'h7E, 8'h33);            // tile B
    grcg_wr(8'h7E, 8'h55);            // tile R
    grcg_wr(8'h7E, 8'h00);            // tile G
    grcg_wr(8'h7E, 8'h00);            // tile E
    io_a2(8'h4C); io_a0(8'h00);                      // VECTW + 1 param (BANK4@0xFA723)
    gdc_csrw(16'h4000, 8'h08);                       // CSRW 00 40 08 (BANK4@0xFA72D)
    gdc_write2(8'h20, 8'hFF, 8'hFF);                 // WRITE + FF FF (BANK4@0xFA742)
    gdc_wait_idle;
    grcg_wr(8'h7C, 8'h00);                           // GRCG off (BANK4@0xFA757)
    cpu_rd_word(2'd0, 15'h0000, w);                  // es:0 [0xA800:0] (BANK4@0xFA760)
    check16(w, 16'h3333, "ITF plane-B readback 0x3333");
    cpu_rd_word(2'd1, 15'h0000, w);                  // es:0 [0xB000:0] (BANK4@0xFA76E)
    check16(w, 16'h5555, "ITF plane-R readback 0x5555");

    // ---- Section 2: the ITF's FAIL PATH - no GRCG, the tile words must be absent ----
    // The flamezap fix's second assertion: with the GRCG never armed the same GDC
    // stream must NOT produce 0x3333/0x5555, so bit 6 stays clear exactly when the
    // machine's own test would fail it. (What the words DO hold is capture-pending:
    // the ITF only ever compares against the two tile words.)
    $display("CHECK 2: the ITF fail path - no GRCG, tile words absent");
    cpu_wr_word(2'd0, 15'h0000, 16'h0000);
    cpu_wr_word(2'd1, 15'h0000, 16'h0000);
    io_a2(8'h4C); io_a0(8'h00);
    gdc_csrw(16'h4000, 8'h08);
    gdc_write2(8'h20, 8'hFF, 8'hFF);
    gdc_wait_idle;
    cpu_rd_word(2'd0, 15'h0000, w);
    checks = checks + 1;
    if (w === 16'h3333) fail("fail path: plane-B read 0x3333 with no GRCG");
    cpu_rd_word(2'd1, 15'h0000, w);
    checks = checks + 1;
    if (w === 16'h5555) fail("fail path: plane-R read 0x5555 with no GRCG");

    // ---- Section 3: the machine's WDAT_WORD/GDCWG rows, fifteen vectors ----
    // Every `got` is the CSV column of the row named, docs/probes/gdc-conformance/
    // xe10-2.5MHz/GDCWDAT.CSV (STRICT) and GDCWG.CSV (WG1).
    $display("CHECK 3: the WDAT_WORD/GDCWG capture vectors");
    w_case("W_0_0000_0001_0001", 2'd0, 1'b0, 16'h0000, 16'h0001, 16'h0001, 16'h0080);
    w_case("W_0_FFFF_0000_0001", 2'd0, 1'b0, 16'hFFFF, 16'h0000, 16'h0001, 16'hFF7F);
    w_case("W_0_A55A_0001_0001", 2'd0, 1'b0, 16'hA55A, 16'h0001, 16'h0001, 16'hA5DA);
    w_case("W_0_0000_0001_A55A", 2'd0, 1'b0, 16'h0000, 16'h0001, 16'hA55A, 16'hA55A);
    w_case("W_0_0000_0001_FFFF", 2'd0, 1'b0, 16'h0000, 16'h0001, 16'hFFFF, 16'hFFFF);
    w_case("W_0_0000_0001_8000", 2'd0, 1'b0, 16'h0000, 16'h0001, 16'h8000, 16'h0100);
    w_case("W_0_0000_0000_0001", 2'd0, 1'b0, 16'h0000, 16'h0000, 16'h0001, 16'h0000);
    w_case("W_1_0000_0001_A55A", 2'd1, 1'b0, 16'h0000, 16'h0001, 16'hA55A, 16'hA55A);
    w_case("W_1_0000_0000_0001", 2'd1, 1'b0, 16'h0000, 16'h0000, 16'h0001, 16'h0000);
    w_case("W_2_FFFF_0001_A55A", 2'd2, 1'b0, 16'hFFFF, 16'h0001, 16'hA55A, 16'h5AA5);
    w_case("W_2_FFFF_0001_FFFF", 2'd2, 1'b0, 16'hFFFF, 16'h0001, 16'hFFFF, 16'h0000);
    w_case("W_3_0000_0001_A55A", 2'd3, 1'b0, 16'h0000, 16'h0001, 16'hA55A, 16'hA55A);
    w_case("WG1_R0_O0000_S0001_MFFFF", 2'd0, 1'b1, 16'h0000, 16'h0001, 16'hFFFF, 16'h0080);
    w_case("WG1_R0_O0000_S0001_MA55A", 2'd0, 1'b1, 16'h0000, 16'h0001, 16'hA55A, 16'h0000);
    w_case("WG1_R0_O0000_S0100_MFFFF", 2'd0, 1'b1, 16'h0000, 16'h0100, 16'hFFFF, 16'h8000);

    // ---- Section 4: the WDAT_STEP rows - one dot along the direction per unit ----
    // The painted words and the cursor write-back are the CSV's own `changes` and
    // raw_curd EAD bytes (the machine's OBSERVED pixels; the suite claims no model).
    $display("CHECK 4: the WDAT_STEP advance along the VECTW direction");
    begin : step_rows
      reg [15:0] off0 [0:3];
      reg [15:0] val0 [0:3];
      off0[0] = 16'h0800; val0[0] = 16'h0001;
      step_case("STEP_DC00_D0", 3'd0, 16'h0000, 16'h0080, 16'h8800,
                1, off0, val0, 16'h8828);
      off0[0] = 16'h0800; val0[0] = 16'h0001;
      off0[1] = 16'h0828; val0[1] = 16'h0001;
      step_case("STEP_DC01_D0", 3'd0, 16'h0001, 16'h0080, 16'h8800,
                2, off0, val0, 16'h8850);
      off0[0] = 16'h0800; val0[0] = 16'h0001;
      off0[1] = 16'h0828; val0[1] = 16'h8000;
      step_case("STEP_DC01_D1", 3'd1, 16'h0001, 16'h0080, 16'h8800,
                2, off0, val0, 16'h8850);
      off0[0] = 16'h0800; val0[0] = 16'h8001;
      step_case("STEP_DC01_D2", 3'd2, 16'h0001, 16'h0080, 16'h8800,
                1, off0, val0, 16'h8800);
      off0[0] = 16'h07D8; val0[0] = 16'h8000;
      off0[1] = 16'h0800; val0[1] = 16'h0001;
      step_case("STEP_DC01_D3", 3'd3, 16'h0001, 16'h0080, 16'h8800,
                2, off0, val0, 16'h87B0);
      // Directions 4-7, and the three-unit DC02 rows: the same
      // capture holds them (docs/probes/gdc-conformance/xe10-2.5MHz, the WDAT_STEP rows
      // STEP_DC01_D4..D7 and STEP_DC02_*), and with only directions 0-3 replayed a
      // direction table that stepped dir 6 like dir 7 still passed this bench.
      off0[0] = 16'h07D8; val0[0] = 16'h0001;
      off0[1] = 16'h0800; val0[1] = 16'h0001;
      step_case("STEP_DC01_D4", 3'd4, 16'h0001, 16'h0080, 16'h8800,
                2, off0, val0, 16'h87B0);
      off0[0] = 16'h07D8; val0[0] = 16'h0002;
      off0[1] = 16'h0800; val0[1] = 16'h0001;
      step_case("STEP_DC01_D5", 3'd5, 16'h0001, 16'h0080, 16'h8800,
                2, off0, val0, 16'h87B0);
      off0[0] = 16'h0800; val0[0] = 16'h0003;
      step_case("STEP_DC01_D6", 3'd6, 16'h0001, 16'h0080, 16'h8800,
                1, off0, val0, 16'h8800);
      off0[0] = 16'h0800; val0[0] = 16'h0001;
      off0[1] = 16'h0828; val0[1] = 16'h0002;
      step_case("STEP_DC01_D7", 3'd7, 16'h0001, 16'h0080, 16'h8800,
                2, off0, val0, 16'h8850);
      off0[0] = 16'h0800; val0[0] = 16'h0001;
      off0[1] = 16'h0828; val0[1] = 16'h8000;
      off0[2] = 16'h0850; val0[2] = 16'h4000;
      step_case("STEP_DC02_D1", 3'd1, 16'h0002, 16'h0080, 16'h8800,
                3, off0, val0, 16'h8878);
      off0[0] = 16'h0800; val0[0] = 16'hC001;
      step_case("STEP_DC02_D2", 3'd2, 16'h0002, 16'h0080, 16'h8800,
                1, off0, val0, 16'h8800);
      off0[0] = 16'h07B0; val0[0] = 16'h4000;
      off0[1] = 16'h07D8; val0[1] = 16'h8000;
      off0[2] = 16'h0800; val0[2] = 16'h0001;
      step_case("STEP_DC02_D3", 3'd3, 16'h0002, 16'h0080, 16'h8800,
                3, off0, val0, 16'h8788);
      off0[0] = 16'h07B0; val0[0] = 16'h0001;
      off0[1] = 16'h07D8; val0[1] = 16'h0001;
      off0[2] = 16'h0800; val0[2] = 16'h0001;
      step_case("STEP_DC02_D4", 3'd4, 16'h0002, 16'h0080, 16'h8800,
                3, off0, val0, 16'h8788);
      off0[0] = 16'h07B0; val0[0] = 16'h0004;
      off0[1] = 16'h07D8; val0[1] = 16'h0002;
      off0[2] = 16'h0800; val0[2] = 16'h0001;
      step_case("STEP_DC02_D5", 3'd5, 16'h0002, 16'h0080, 16'h8800,
                3, off0, val0, 16'h8788);
      off0[0] = 16'h0800; val0[0] = 16'h0007;
      step_case("STEP_DC02_D6", 3'd6, 16'h0002, 16'h0080, 16'h8800,
                1, off0, val0, 16'h8800);
      off0[0] = 16'h0800; val0[0] = 16'h0001;
      off0[1] = 16'h0828; val0[1] = 16'h0002;
      off0[2] = 16'h0850; val0[2] = 16'h0004;
      step_case("STEP_DC02_D7", 3'd7, 16'h0002, 16'h0080, 16'h8800,
                3, off0, val0, 16'h8878);
    end

    // ---- Section 5: a second draw queued while the first walks (the one-deep pend) ----
    // Draw B's command bytes follow A's trigger at once, so B's job snapshot lands in
    // the pending slot; both capture outcomes must appear and nothing may be dropped.
    $display("CHECK 5: a draw queued mid-draw lands, and nothing is dropped");
    cpu_wr_word(2'd1, 15'h0100, 16'h0000);   // A's unit 0 (word 0x0080)
    cpu_wr_word(2'd1, 15'h0150, 16'h0000);   // A's unit 1 (word 0x00A8)
    cpu_wr_word(2'd1, 15'h0200, 16'h0000);   // B (word 0x0100)
    gdc_csrw(16'h8080, 8'h00);            // A: plane R word 0x0080, WG 0
    gdc_mask(16'h0080);
    gdc_vectw(3'd1, 16'h0001);            // A: dc=1 dir=1 (the STEP_DC01_D1 shape)
    gdc_write2(8'h23, 8'hFF, 8'hFF);      // A's trigger
    gdc_csrw(16'h8100, 8'h08);            // B: plane R word 0x0100, WG 1
    gdc_mask(16'h0001);                   // B's setup, while A walks
    gdc_write2(8'h20, 8'h01, 8'h00);      // B: W_0_0000_0001_0001's own row
    gdc_wait_idle;
    cpu_rd_word(2'd1, 15'h0100, w);
    check16(w, 16'h0001, "queued A unit 0 (STEP_DC01_D1)");
    cpu_rd_word(2'd1, 15'h0150, w);
    check16(w, 16'h8000, "queued A unit 1 (STEP_DC01_D1)");
    cpu_rd_word(2'd1, 15'h0200, w);
    check16(w, 16'h0080, "queued B (W_0_0000_0001_0001)");

    // ---- Section 6: the GRCG-RMW route, differential against the CPU path ----
    // NP2kai's withrmw (io/gdc_pset.c:63-77) merges (old & ~data) | (tile & data) at
    // the painted bits; the SAME word must land when the CPU stores the paint through
    // the GRCG's own RMW path (which tb_pc9821_grcg_rmw pins to that formula), so the
    // expectation never comes from this RTL's draw engine.
    $display("CHECK 6: the GRCG-RMW route is the CPU path's own merge");
    // The datum 0x00FF is a bit-reversal palindrome (rev16(0x00FF) == 0x00FF), so the
    // CPU path's own store and the GDC's painted word carry the SAME merge mask.
    // Seeds go in with the GRCG OFF - armed, a CPU store is an RMW, not a seed.
    cpu_wr_word(2'd0, 15'h0100, 16'h0F0F);   // seed B
    cpu_wr_word(2'd1, 15'h0100, 16'h0F0F);   // seed R
    cpu_wr_word(2'd0, 15'h0140, 16'h0F0F);
    cpu_wr_word(2'd1, 15'h0140, 16'h0F0F);
    grcg_wr(8'h7C, 8'hC0);                // RMW, all planes
    grcg_wr(8'h7E, 8'hF0);                // tile B = F0F0
    grcg_wr(8'h7E, 8'h0F);                // tile R = 0F0F
    grcg_wr(8'h7E, 8'h00);
    grcg_wr(8'h7E, 8'h00);
    cpu_wr_word(2'd0, 15'h0140, 16'h00FF);   // the CPU path's own RMW of 0x00FF
    cpu_wr_word(2'd1, 15'h0140, 16'h00FF);
    cpu_rd_word(2'd0, 15'h0140, exp_cpu);    // B: the CPU-path result
    begin : rmw_r
      reg [15:0] exp_r;
      cpu_rd_word(2'd1, 15'h0140, exp_r);   // R: the CPU-path result
      // The GDC's own draw of the same paint at word 0x0080.
      gdc_csrw(16'h8080, 8'h08);          // WG 1: the WDAT word IS the paint
      gdc_mask(16'hFFFF);
      gdc_write2(8'h20, 8'hFF, 8'h00);    // WDAT 0x00FF
      gdc_wait_idle;
      grcg_wr(8'h7C, 8'h00);
      cpu_rd_word(2'd0, 15'h0100, w);
      check16(w, exp_cpu, "GRCG-RMW draw == CPU RMW (plane B)");
      cpu_rd_word(2'd1, 15'h0100, w);
      check16(w, exp_r, "GRCG-RMW draw == CPU RMW (plane R)");
    end

    // ---- Section 7: the EGC route, differential against the CPU path ----
    // With the EGC gate raised AND the GRCG armed, the unit must take the EGC path
    // (gdcpset_prepare: EGC first, io/gdc_pset.c:117-137) - the tile words must NOT
    // appear - and the word that lands must equal the CPU's own store of the same
    // datum through that same EGC.
    $display("CHECK 7: the EGC route (route latched per draw, EGC before GRCG)");
    cpu_wr_word(2'd0, 15'h0140, 16'h0000);   // seeds with the GRCG off
    cpu_wr_word(2'd0, 15'h0100, 16'h0000);
    grcg_wr(8'h7C, 8'h80);                // TDW armed: a wrong route would paint tiles
    grcg_wr(8'h7E, 8'hF0);
    grcg_wr(8'h7E, 8'h0F);
    grcg_wr(8'h7E, 8'h00);
    grcg_wr(8'h7E, 8'h00);
    egc_mem_gate_b = 1'b1;
    cpu_wr_word(2'd0, 15'h0140, 16'h5AA5);   // the CPU path's own EGC store
    cpu_rd_word(2'd0, 15'h0140, exp_cpu);
    gdc_csrw(16'h8080, 8'h08);            // WG 1: the WDAT word 5AA5 is the datum
    gdc_mask(16'hFFFF);
    gdc_write2(8'h20, 8'hA5, 8'h5A);
    gdc_wait_idle;
    checks = checks + 1;
    // Both route flags latch (the GRCG's bit 7 is armed here on purpose) and the
    // DISPATCH priority picks the EGC - gdcpset_prepare's EGC-first order - so the
    // assertion is on the EGC flag; the tile words' absence is the outcome check.
    if (dut_gdc2.mem_route_egc !== 1'b1)
      fail("the draw did not latch the EGC route with both gates up");
    cpu_rd_word(2'd0, 15'h0100, w);
    check16(w, exp_cpu, "EGC draw == CPU store through the EGC");
    egc_mem_gate_b = 1'b0;
    grcg_wr(8'h7C, 8'h00);

    // ---- Section 8: WRITEs chained on the advancing cursor, a CURD behind them ----
    // CSRW once, VECTW dir 0 DC 15, then THREE WDATs back to back with no CSRW between
    // them, and a CURD (0xE0) right behind the third - every byte written while the first
    // draw still walks. The chip queues those bytes in its FIFO and runs them in order
    // after the draw (uPD7220), and NP2kai gdc_work runs each WRITE to completion before
    // parsing the next byte (io/gdc.c:347-349 `if ((!(item->rcv)) && (id ==
    // GDCWORK_SLAVE)` .. `gdcsub_write();`), so each WRITE starts on the cursor the last
    // one left. Dir 0 steps one row (+40 words) per unit and the cursor ends one row past
    // the last unit (WDAT_STEP STEP_DC00_D0: word 0x0800, cursor 0x0828; STEP_DC01_D0:
    // cursor 0x0850), so the three draws paint ONE column of 48 rows from word 0x0800,
    // each word reading 0x0001 (mask 0x0080, SET, WG 0 - the STEP rows' own value), and
    // the CURD answers 0x8800 + 48 x 40 = 0x8F80.
    $display("CHECK 8: chained WRITEs run in order on the advanced cursor; CURD waits");
    begin : chain
      reg [15:0] ead8;
      reg        overlap;
      for (k = 0; k < 49; k = k + 1) cpu_wr_word(2'd1, (15'h1000 + 15'd80 * k[14:0]), 16'h0000);
      gdc_csrw(16'h8800, 8'h00);            // plane R word 0x0800, WG 0
      gdc_mask(16'h0080);
      gdc_vectw(3'd0, 16'd15);              // 16 units, one row each
      gdc_write2(8'h23, 8'hFF, 8'hFF);      // draw 1
      gdc_write2(8'h23, 8'hFF, 8'hFF);      // draw 2, no CSRW
      gdc_write2(8'h23, 8'hFF, 8'hFF);      // draw 3, no CSRW
      io_a2(8'hE0);                         // CURD behind them
      // The stimulus must really overlap the walk, or this section proves nothing.
      overlap = (dut_gdc2.d_state !== 3'd0) || (dut_gdc2.pend_valid !== 1'b0);
      checks = checks + 1;
      if (!overlap) fail("chain: the CURD did not land while a draw was still walking");
      gdc_wait_idle;
      @(negedge clk_sys);
      io_addr = 8'hA2; io_rd = 1'b1;
      @(negedge clk_sys);
      io_rd = 1'b0;
      @(negedge clk_sys);
      ead8[7:0] = io_dout;
      io_addr = 8'hA2; io_rd = 1'b1;
      @(negedge clk_sys);
      io_rd = 1'b0;
      @(negedge clk_sys);
      ead8[15:8] = io_dout;
      check16(ead8, 16'h8F80, "chain: CURD during the walk reads the advanced cursor");
      for (k = 0; k < 48; k = k + 1) begin
        cpu_rd_word(2'd1, (15'h1000 + 15'd80 * k[14:0]), w);
        check16(w, 16'h0001, "chain: row painted by the chained WRITEs");
      end
      cpu_rd_word(2'd1, (15'h1000 + 15'd80 * 15'd48), w);
      check16(w, 16'h0000, "chain: the row past the last unit stays clear");
    end

    // ==== VERDICT ====
    $display("NOTE gdc2_write: %0d checks, %0d errors", checks, errors);
    if (errors == 0) begin
      $display("TB_PC9821_GDC2_WRITE: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_GDC2_WRITE: FAIL (%0d errors over %0d checks)", errors, checks);
    end
  end

  // The bound: the engine never stalls a unit longer than the GVRAM's own acceptance
  // period, so this is many times any legitimate run.
  initial begin
    #4_000_000;
    $fatal(1, "TB_PC9821_GDC2_WRITE: TIMEOUT");
  end

endmodule

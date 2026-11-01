`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PEGC_480: the PC-9821 256-colour 640x480 mode the Windows 95 PC-9821 display driver sets displays a packed 640x480x8 frame correctly on the 31 kHz raster: with clk_sys at 90 MHz (the shipped clock), the real pc9821_dot_ce (31 kHz dot clock), pc9821_crtc, pc9821_gdc2, pc9821_pegc_scan behind the real sdram_sync_bridge and src/memory/sdram.v (port 3) and pc9821_video_mixer wired as pc9821_system wires them, programmed through the GDC and mode ports with the firmware's 640x480 rows (INT 18h AH=30h BH=0x31: master SYNC 10 4E 4B 0C 03 0B DB 95 = 800 x 525 with AL 475, slave SYNC 02 4E 4B 0C 83 06 E0 95 = AL 480, slave PITCH 80, SCROLL 00 00 F0 7F, the 5 MHz clock 0x6A 0x83/0x85 - Xe10 BANK3@0x1E25-0x1E4D and 0x1F8E-0x1FA7, the same bytes as NP2kai bios/bios18.c gdcmastersync[4]/gdcslavesync[1]) and then the driver's own sequence (PEGCV8.DRV: 0x6A 07/21/69, slave PITCH 0x80, START), every one of the 307,200 active dots of a whole frame - all 480 lines - is the 256-colour palette entry of the packed byte at line*1024 + dot of the store (NP2kai vram/makegrex.c: the stride is PITCH words of 8 bytes at 5 MHz, `if (!(gdc.clock & 0x80)) mg.pitch <<= 1; mg.pitch &= 0xfe`, and the driver's own 0x0400-byte pitch), the displayed area is 480 lines a frame although the master's block has 475 (NP2kai dispsync_renewalvertical `scrnymax = MAX(grphymax, textymax)`) with the VSYNC still at the master's line 486 and 525 lines a frame, the frame holds while a saturating CPU cache-line stream competes for the SDRAM, and every packed line fetch completes inside the 31 kHz line (800 dots, 2860 clk_sys at 90 MHz), with every port-3 request held, payload unchanged, until the controller takes it (the bridge's contract, which a line tick during the mode set broke at 90 MHz before pc9821_pegc_scan deferred its restart); the read-backs of the state touched answer: the 0x9A0 query bits of the FF2 clock/256/256E latches (pc9821_crtc's gdc_ff2_state) and the slave's 0xA2 after PITCH (0xFF: PITCH queues no read-back, NP2kai gdc_ia2). FAIL-FIRST (each a recorded mutant of the shipped change): with the packed stride taken from the SCROLL im bit over a constant 40-word PITCH (the pre-change walk) 304,832 of the 307,200 dots are wrong, and so with the PITCH byte dropped; with the 5 MHz clock ignored (PITCH 0x80 doubled and masked to a stride of 0) 305,920; with the walker stepping on the line parity alone it misses the wrap of this ODD 525-line frame and shows every line below row 1 one raster line late (305,920 wrong - the 31 kHz 449-line block has the same odd wrap); and with the displayed lines limited to the master's window the frame shows 475 lines (304,000 dots).

`default_nettype none

module tb_pc9821_pegc_480;

  localparam integer SYS_HZ = 90_000_000;
  reg clk = 1'b0;
  always #5.5556 clk = ~clk;            // 90 MHz (to the 1 ps step): the shipped clk_sys, the controller on it
  reg reset = 1'b1;

  // ==== DUT ====
  // The video path, wired as pc9821_system wires it.
  wire pixel_ce;
  pc9821_dot_ce #(.SYS_FREQ(SYS_HZ)) dot_ce (.clk(clk), .reset(reset), .c31(1'b1), .ce(pixel_ce));

  // The device I/O strobe both GDC blocks see (pc9821_system's gdc_cs fan-out).
  reg        io_wr = 1'b0, io_rd = 1'b0;
  reg  [7:0] io_addr = 8'h00, io_din = 8'h00;
  wire [7:0] crtc_io_dout, gdc2_io_dout;

  wire [10:0] gdc_ff2_state;
  wire [9:0]  o_vline, o_hdot, o_htotal, o_vtotal;
  wire [5:0]  o_vbp;
  wire        o_frame_end, o_cfg_snap, o_cfg_pending, o_display_page, o_stat_blank, o_stat_vsync;
  wire        disp_on;
  wire        text_opaque, text_cell;
  wire [11:0] text_colour;
  wire [9:0]  pix_dot;
  wire        pix_h_active, pix_v_active, gfx_odd_line, gfx_mode16;
  wire [31:0] gfx_dig;
  wire        pal_wr_en, pal_commit;
  wire [3:0]  pal_wr_idx, pal_wr_data;
  wire [1:0]  pal_wr_chan;
  wire        pal256_wr_en;
  wire [7:0]  pal256_wr_idx, pal256_wr_data;
  wire [1:0]  pal256_wr_chan;
  wire        pegc_256, pegc_256e;
  wire        hs_out, vs_out, de_out;
  wire [15:0] gfx_line_addr;
  wire        gfx_walk_page, gfx_win_off, gfx_grph_on;

  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_crtc u_crtc (
      .clk_sys(clk), .rst_n_sys(!reset), .rst_n_vid(!reset), .pixel_ce(pixel_ce),
      .crt31k(1'b1), .gfx_win_on(gfx_grph_on),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(crtc_io_dout),
      .gdc_ff2_state(gdc_ff2_state),
      .cfg_fdd_mode(3'd0),
      .tram_cpu_addr(14'd0), .tram_cpu_din(8'h00), .tram_cpu_we(1'b0), .tram_cpu_dout(),
      .wk_tr_read(1'b0), .wk_tr_addr(14'd0), .o_tram_vid_q(),
      .ank_rd_addr(), .ank_word(16'h0000),
      .jc_rd_bank(), .jc_rd_cell(), .jc_rd_word(), .jc_rd_q(32'd0),
      .cg_ram_vid_addr(), .cg_ram_vid_q(8'h00),
      .o_v_pitch(), .o_v_col40(), .o_v_sad(), .o_v_row0_stale(),
      .o_vline(o_vline), .o_hdot(o_hdot), .o_htotal(o_htotal), .o_vtotal(o_vtotal), .o_vbp(o_vbp),
      .o_frame_end(o_frame_end), .o_cfg_snap(o_cfg_snap), .o_cfg_pending(o_cfg_pending),
      .o_display_page(o_display_page), .o_stat_blank(o_stat_blank), .o_stat_vsync(o_stat_vsync),
      .vsync_active(), .vsync_edge(), .vsync_irq_arm(1'b0), .vsync_irq(),
      .disp_on(disp_on), .gfx_access_page(), .gfx_egc_gate(),
      .dbg_sad(), .dbg_pitch(), .dbg_col40(), .dbg_disp(),
      .text_opaque(text_opaque), .text_cell(text_cell), .text_colour(text_colour),
      .pix_dot(pix_dot), .pix_h_active(pix_h_active), .pix_v_active(pix_v_active),
      .gfx_odd_line(gfx_odd_line), .gfx_mode16(gfx_mode16), .gfx_dig(gfx_dig),
      .pal_wr_en(pal_wr_en), .pal_wr_idx(pal_wr_idx), .pal_wr_chan(pal_wr_chan),
      .pal_wr_data(pal_wr_data), .pal_commit(pal_commit),
      .pal256_wr_en(pal256_wr_en), .pal256_wr_idx(pal256_wr_idx),
      .pal256_wr_chan(pal256_wr_chan), .pal256_wr_data(pal256_wr_data),
      .gfx_pegc_256(pegc_256), .gfx_pegc_256e(pegc_256e),
      .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
  );

  pc9821_gdc2 u_gdc2 (
      .clk_sys(clk), .rst_n_sys(!reset), .pixel_ce(pixel_ce),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(gdc2_io_dout),
      .frame_end(o_frame_end), .cfg_snap(o_cfg_snap), .cfg_pending(o_cfg_pending),
      .vline(o_vline), .vtotal(o_vtotal), .m_vbp(o_vbp),
      .display_page(o_display_page), .stat_blank(o_stat_blank), .stat_vsync(o_stat_vsync),
      .egc_mem_gate(1'b0), .grcg_cg_gate(1'b0), .access_page(1'b0),
      .mem_valid(), .mem_ready(1'b0), .mem_write(), .mem_route_egc(), .mem_route_grcg(),
      .mem_page(), .mem_plane(), .mem_offset(), .mem_din(), .mem_be(),
      .mem_resp(1'b0), .mem_rdata(32'd0),
      .gfx_line_addr(gfx_line_addr), .gfx_walk_page(gfx_walk_page),
      .gfx_disp(), .gfx_win_off(gfx_win_off), .gfx_grph_on(gfx_grph_on),
      .pegc_256(pegc_256),
      .gdc_5m(gdc_ff2_state[7] && gdc_ff2_state[8])   // as pc9821_system wires it
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // The line tick: pc9821_system's gvram_h_count / gvram_scan_line_tick, one clk_sys at the
  // leading edge of the line's last dot.
  reg [9:0] h_count = 10'd0;
  reg       h_last = 1'b0;
  wire      at_last = (h_count == (o_htotal - 10'd1));
  always @(posedge clk) begin
    if (reset) begin
      h_count <= 10'd0; h_last <= 1'b0;
    end else begin
      h_last <= at_last;
      if (pixel_ce) h_count <= at_last ? 10'd0 : h_count + 10'd1;
    end
  end
  wire scan_line_tick = at_last & ~h_last;

  // ---- the packed scanout on port 3 ----
  localparam [31:0] PEG_BASE = 32'h0200_0000;
  wire [6:0]  line_rd_addr;
  wire        line_rd_sel;
  wire [7:0]  packed_idx;
  wire        peg_line_sel, peg_line_ready;
  wire [31:0] p3_addr, p3_din, p3_dout;
  wire [3:0]  p3_be;
  wire [7:0]  p3_burst;
  wire        p3_valid, p3_write, p3_ready, p3_resp_valid;

  pc9821_pegc_scan u_scan (
      .clk(clk), .reset(reset),
      .scan_enable(disp_on && pegc_256),
      .scan_line_tick(scan_line_tick),
      .scan_page(gfx_line_addr[15]), .page_force_zero(pegc_256e),
      .scan_walk_page(gfx_walk_page),
      .scan_line_base(gfx_line_addr[14:0]),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .dot_in_col(pix_dot[2:0]), .dot_ce(pixel_ce), .line_rd_act(pix_h_active),
      .packed_idx(packed_idx), .line_sel(peg_line_sel), .line_ready(peg_line_ready),
      .peg_base(PEG_BASE),
      .mem_addr(p3_addr), .mem_valid(p3_valid), .mem_write(p3_write),
      .mem_be(p3_be), .mem_burstcount(p3_burst), .mem_din(p3_din),
      .mem_ready(p3_ready), .mem_dout(p3_dout), .mem_resp_valid(p3_resp_valid)
  );

  wire [7:0] r_out, g_out, b_out;
  pc9821_video_mixer u_mix (
      .clk(clk), .rst_n(!reset),
      .dot_x(pix_dot), .h_active(pix_h_active), .v_active(pix_v_active),
      .gfx_odd_line(gfx_odd_line),
      .text_opaque(text_opaque), .text_cell(text_cell), .text_colour(text_colour),
      .line_data(32'h0000_0000),
      .line_ready(peg_line_ready), .line_sel(peg_line_sel),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .pal_mode16(gfx_mode16), .pal_dig(gfx_dig),
      .pal_wr_en(pal_wr_en), .pal_wr_idx(pal_wr_idx), .pal_wr_chan(pal_wr_chan),
      .pal_wr_data(pal_wr_data), .pal_commit(pal_commit),
      .pegc_256(pegc_256), .fold_bypass(pegc_256), .packed_idx(packed_idx),
      .pal256_wr_en(pal256_wr_en), .pal256_wr_idx(pal256_wr_idx),
      .pal256_wr_chan(pal256_wr_chan), .pal256_wr_data(pal256_wr_data),
      .comp_rule(2'b00), .grph_disp(gfx_grph_on),
      .r_out(r_out), .g_out(g_out), .b_out(b_out)
  );

  // ---- the SDRAM: the real bridge and controller, the deployed settings at 90 MHz ----
  // Port 0 has two drivers, one at a time: the preload task (t_*) and the CPU stream (c_*).
  reg  [31:0] t_addr = 32'd0, t_din = 32'd0;
  reg         t_valid = 1'b0;
  reg  [31:0] c_addr = 32'd0;
  reg         c_valid = 1'b0;
  integer     p0_mode = 0;          // 0 the preload task, 2 the CPU stream
  wire        cpu_on   = (p0_mode == 2);
  wire [31:0] p0_addr  = cpu_on ? c_addr : t_addr;
  wire [31:0] p0_din   = t_din;
  wire  [3:0] p0_be    = 4'hF;
  wire  [3:0] p0_burst = cpu_on ? 4'd4 : 4'd1;
  wire        p0_valid = cpu_on ? c_valid : t_valid;
  wire        p0_write = !cpu_on;
  wire        p0_ready, p0_resp_valid;
  wire [31:0] p0_dout;
  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire  [1:0] SDRAM_BA, SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS, CKE, busy;
  reg         resetn = 1'b0;

  /* verilator lint_off PINCONNECTEMPTY */
  sdram_sync_bridge #(.FREQ(SYS_HZ), .ADQM(1'b1), .FAST_GRADE(1'b0), .GATHER_K(4)) backend (
      .clk(clk), .resetn(resetn),
      .refresh_allowed(1'b1), .busy(busy), .sdram_size(2'd2),
      .valid0(p0_valid), .ready0(p0_ready), .wr0(p0_write), .addr0(p0_addr[26:0]),
      .din0(p0_din), .din0_hi(32'd0), .gath0(1'b0), .gath0_extra(441'd0),
      .dout0(p0_dout), .resp_valid0(p0_resp_valid), .be0(p0_be), .burst_cnt0(p0_burst),
      .valid1(1'b0), .ready1(), .wr1(1'b0), .addr1(27'd0), .din1(32'd0),
      .dout1(), .resp_valid1(), .be1(4'd0), .burst_cnt1(4'd0),
      .valid2(1'b0), .ready2(), .wr2(1'b0), .addr2(27'd0), .din2(32'd0),
      .dout2(), .resp_valid2(), .be2(4'd0), .burst_cnt2(4'd0),
      .valid3(p3_valid), .ready3(p3_ready), .wr3(p3_write), .addr3(p3_addr[26:0]),
      .din3(p3_din), .dout3(p3_dout), .resp_valid3(p3_resp_valid),
      .be3(p3_be), .burst_cnt3(p3_burst[3:0]),
      .SDRAM_DQ(DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQM(SDRAM_DQM), .SDRAM_BA(SDRAM_BA),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nCS(nCS), .SDRAM_CKE(CKE)
  );
  /* verilator lint_on PINCONNECTEMPTY */
  // sdram.v ns_to_cycles at 90 MHz: tRP ceil(20 ns x 0.09) = 2, tWR ceil(15 ns x 0.09) = 2.
  sdram_chip_model #(.CAS(2), .T_RP(2), .T_WR(2)) chip (
      .clk(clk), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // ==== THE EXPECTED FRAME ====
  // The packed byte at (dot x, line y): stored at line*1024 + x (the driver's 0x0400-byte pitch).
  // Every line and every dot carries a different value pattern, so a wrong stride, a wrong
  // line or a shifted dot reads a byte that is not the one expected.
  localparam integer PITCH_BYTES = 1024;
  function automatic [7:0] pix(input integer x, input integer y);
    pix = 8'((x * 5 + y * 37 + (y >> 8) * 101 + (x >> 8) * 13) & 255);
  endfunction
  // The 256-colour palette the bench loads: three different functions of the index, so a
  // channel swap or a wrong entry is a different colour.
  function automatic [7:0] pal_g(input integer i); pal_g = 8'(i); endfunction
  function automatic [7:0] pal_r(input integer i); pal_r = 8'(i) ^ 8'hA5; endfunction
  function automatic [7:0] pal_b(input integer i); pal_b = 8'((i * 7 + 3) & 255); endfunction

  // ==== CHECKS ====
  integer errors = 0;
  task automatic fail(input string what);
    begin
      errors = errors + 1;
      $display("FAIL pegc_480: %0s", what);
    end
  endtask

  initial begin
    #300_000_000;
    $fatal(1, "TB_PC9821_PEGC_480: FAIL watchdog (the run did not finish)");
  end

  // ==== PORT 0: the preload, then a saturating CPU cache-line read stream ====
  // The stream is the z486 L1 line-fill shape (4-dword reads, tb_pc9821_sdram_bw's CPU port),
  // presented back to back, held to its ready, in the first MiB (away from the store).
  integer cpu_accepts = 0;
  always @(posedge clk) begin
    if (!cpu_on) c_valid <= 1'b0;
    else begin
      c_valid <= 1'b1;
      if (c_valid && p0_ready) begin
        cpu_accepts <= cpu_accepts + 1;
        c_addr <= (c_addr + 32'd64) & 32'h000F_FFC0;
      end
    end
  end

  task automatic store(input [31:0] a, input [31:0] d);
    integer g;
    begin
      @(negedge clk);
      t_addr = a; t_din = d; t_valid = 1'b1;
      g = 0;
      while (!p0_ready && g < 100000) begin @(negedge clk); g = g + 1; end   // the first waits out sdram.v's power-up
      if (!p0_ready) $fatal(1, "TB_PC9821_PEGC_480: no accept for the preload store at %08x", a);
      @(negedge clk);
      t_valid = 1'b0;
    end
  endtask

  // ==== THE GUEST'S PORT ACCESSES (the device strobe, then idle) ====
  task automatic out8(input [7:0] port, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = port; io_din = data; io_wr = 1'b1;
      @(negedge clk);
      io_wr = 1'b0;
      repeat (3) @(negedge clk);
    end
  endtask
  task automatic in8(input [7:0] port, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = port; io_rd = 1'b1;
      @(negedge clk);
      io_rd = 1'b0;
      @(negedge clk);   // the device answers on the cycle after the strobe (device_rd_wait)
      data = (port == 8'hA0 || port == 8'hA2) ? gdc2_io_dout : crtc_io_dout;
      repeat (2) @(negedge clk);
    end
  endtask
  task automatic cmd(input [7:0] port, input [7:0] c, input integer n, input [63:0] p);
    integer i;
    begin
      out8(port, c);
      for (i = n - 1; i >= 0; i = i - 1) out8(port - 8'h02, p[i*8 +: 8]);
    end
  endtask

  // ==== THE SAMPLER (the framework's rule: at the pixel enable, the value of the cycle) ====
  reg        sampling = 1'b0;
  integer    samples = 0, bad = 0, shown = 0;
  integer    de_lines = 0, max_y = -1;
  reg        de_seen_line = 1'b0;
  reg [9:0]  last_vline = 10'd0;
  integer    lines_in_frame = 1;      // line 0, the line the window opens on
  integer    vs_line = -1;
  reg        vs_d = 1'b0;
  always @(posedge clk) begin
    if (sampling && pixel_ce) begin
      if (o_vline != last_vline) begin
        if (de_seen_line) de_lines = de_lines + 1;
        de_seen_line = 1'b0;
        last_vline = o_vline;
        lines_in_frame = lines_in_frame + 1;
      end
      if (de_out) de_seen_line = 1'b1;
      // The VSYNC status bit (0xA0 bit 5, the guest's view of the pulse) rises on its line.
      if (!vs_d && o_stat_vsync && vs_line < 0) vs_line = o_vline;
      vs_d = o_stat_vsync;
      if (pix_h_active && pix_v_active) begin
        samples = samples + 1;
        if (int'(o_vline) > max_y) max_y = int'(o_vline);
        if (r_out !== pal_r(pix(pix_dot, o_vline)) || g_out !== pal_g(pix(pix_dot, o_vline)) ||
            b_out !== pal_b(pix(pix_dot, o_vline))) begin
          bad = bad + 1;
          if (shown < 8) begin
            shown = shown + 1;
            $display("  dot %0d line %0d: rgb %02x%02x%02x, want %02x%02x%02x (packed %02x)",
                     pix_dot, o_vline, r_out, g_out, b_out,
                     pal_r(pix(pix_dot, o_vline)), pal_g(pix(pix_dot, o_vline)),
                     pal_b(pix(pix_dot, o_vline)), pix(pix_dot, o_vline));
          end
        end
      end
    end
  end

  // ==== THE FETCH'S LINE TIME: tick to the line's last response beat ====
  integer fetch_start = 0, worst_fetch = 0, fetches = 0, cyc = 0;
  reg     measuring = 1'b0;
  always @(posedge clk) begin
    cyc = cyc + 1;
    if (scan_line_tick) fetch_start = cyc;
    if (measuring && u_scan.fetch_active && p3_resp_valid && (u_scan.beats_left == 4'd1) &&
        (u_scan.wr_idx == 9'd159)) begin
      fetches = fetches + 1;
      if (cyc - fetch_start > worst_fetch) worst_fetch = cyc - fetch_start;
    end
  end
  // The 31 kHz line: 800 dots at 50 MHz x 78347/4096 / 38 (pc9821_vclk_pkg) = 31.787 us.
  localparam integer LINE31_SYS = int'((64'd800 * 38 * 4096 * (SYS_HZ / 1_000_000)) / (64'd50 * 78347));

  integer x, y, i, g;
  reg [7:0] b;
  initial begin
    repeat (8) @(negedge clk);
    reset = 1'b0;
    resetn = 1'b1;
    repeat (200) @(negedge clk);

    // ---- the store: the frame at a 1024-byte pitch, written over the bridge's port 0 ----
    for (y = 0; y < 480; y = y + 1)
      for (x = 0; x < PITCH_BYTES; x = x + 4)
        store(PEG_BASE + 32'(y * PITCH_BYTES + x),
              {pix(x + 3, y), pix(x + 2, y), pix(x + 1, y), pix(x, y)});
    $display("  preload done: 480 lines x %0d bytes", PITCH_BYTES);

    // ---- the mode: INT 18h AH=30h BH=0x31 as the firmware's 640x480 rows program it ----
    out8(8'h68, 8'h0E);                                  // display off (PEGCV8.DRV seg 2 @0x0000)
    out8(8'h6A, 8'h07); out8(8'h6A, 8'h21);              // the PEGC select (write enable, 256)
    out8(8'h6A, 8'h83); out8(8'h6A, 8'h85);              // the 5 MHz GDC clock (the row's `83 85`)
    // master: RESET, VSYNC master, SYNC (the 25-row 480 block: AL 475), PITCH 80, ZOOM, SCROLL
    cmd(8'h62, 8'h00, 0, 64'h0);
    cmd(8'h62, 8'h6F, 0, 64'h0);
    cmd(8'h62, 8'h0F, 8, 64'h10_4E_4B_0C_03_0B_DB_95);
    cmd(8'h62, 8'h4B, 3, 64'h12_00_93);
    cmd(8'h62, 8'h47, 1, 64'h50);
    cmd(8'h62, 8'h46, 1, 64'h00);
    cmd(8'h62, 8'h70, 4, 64'h00_00_F0_3F);
    // slave: RESET, VSYNC slave, SYNC (AL 480), CSRFORM, PITCH 80, ZOOM, SCROLL (im set)
    cmd(8'hA2, 8'h00, 0, 64'h0);
    cmd(8'hA2, 8'h6E, 0, 64'h0);
    cmd(8'hA2, 8'h0E, 8, 64'h02_4E_4B_0C_83_06_E0_95);
    cmd(8'hA2, 8'h4B, 3, 64'h00_00_01);
    cmd(8'hA2, 8'h47, 1, 64'h50);
    cmd(8'hA2, 8'h46, 1, 64'h00);
    cmd(8'hA2, 8'h70, 4, 64'h00_00_F0_7F);
    // ---- PEGCV8.DRV's own sequence after the BIOS call (seg 2 @0x0B11-0x0B43) ----
    out8(8'h6A, 8'h07); out8(8'h6A, 8'h69); out8(8'h6A, 8'h06); out8(8'h6A, 8'h41);
    cmd(8'hA2, 8'h47, 1, 64'h80);                        // PITCH 0x80
    in8(8'hA2, b);
    if (b !== 8'hFF) fail($sformatf("0xA2 after PITCH reads %02x, want FF (PITCH queues no read-back, NP2kai gdc_ia2)", b));
    cmd(8'hA2, 8'h0D, 0, 64'h0);                         // INT 18h AH=40h: graphics START
    // ---- the 256-colour palette (0xA8 index, 0xAA G, 0xAC R, 0xAE B) ----
    for (i = 0; i < 256; i = i + 1) begin
      out8(8'hA8, 8'(i));
      out8(8'hAA, pal_g(i)); out8(8'hAC, pal_r(i)); out8(8'hAE, pal_b(i));
    end
    out8(8'h68, 8'h0F);                                  // display on (seg 2 @0x0054)

    // ---- read-back of the latches the mode set (the 0x9A0 query's bits, pc9821_crtc) ----
    if (gdc_ff2_state[7] !== 1'b1 || gdc_ff2_state[8] !== 1'b1)
      fail($sformatf("the FF2 GDC clock bits read %b%b, want 11 (0x6A 0x83 / 0x85)", gdc_ff2_state[8], gdc_ff2_state[7]));
    if (gdc_ff2_state[9] !== 1'b1) fail("the FF2 256-colour bit reads 0 after 0x6A 0x21");
    if (gdc_ff2_state[10] !== 1'b1) fail("the FF2 256E bit reads 0 after 0x6A 0x69");

    // ---- run: two frames settle the block, then one whole frame is sampled under the CPU load ----
    p0_mode = 2;
    for (g = 0; g < 3; g = g + 1) begin
      @(posedge clk);
      while (!(pixel_ce && o_frame_end)) @(posedge clk);
    end
    measuring = 1'b1;
    @(posedge clk);
    last_vline = o_vline;
    sampling = 1'b1;
    @(posedge clk);
    while (!(pixel_ce && o_frame_end)) @(posedge clk);
    @(posedge clk);
    sampling = 1'b0;
    measuring = 1'b0;
    if (de_seen_line) de_lines = de_lines + 1;
    p0_mode = 0;

    // ==== VERDICT ====
    $display("MEASURED pegc_480: %0d active dots sampled, %0d wrong; %0d displayed lines (last line %0d) in a %0d-line frame (VTOTAL %0d), VSYNC from line %0d",
             samples, bad, de_lines, max_y, lines_in_frame, o_vtotal, vs_line);
    $display("MEASURED pegc_480: %0d line fetches, the slowest %0d clk_sys from its tick (the 31 kHz line is %0d); CPU stream %0d cache-line accepts",
             fetches, worst_fetch, LINE31_SYS, cpu_accepts);
    if (samples != 640 * 480)
      fail($sformatf("%0d active dots in the frame, want 307200 (640 x 480)", samples));
    if (bad != 0) fail($sformatf("%0d of %0d dots are not the palette entry of their packed byte", bad, samples));
    if (de_lines != 480) fail($sformatf("%0d displayed lines, want 480 (the slave's AL 480 over the master's 475)", de_lines));
    if (max_y != 479) fail($sformatf("the last displayed line is %0d, want 479", max_y));
    if (o_vtotal != 10'd525 || lines_in_frame != 525)
      fail($sformatf("the frame is %0d lines (VTOTAL %0d), want 525", lines_in_frame, o_vtotal));
    if (vs_line != 486) fail($sformatf("VSYNC starts at line %0d, want 486 (master AL 475 + VFP 11)", vs_line));
    if (fetches < 480) fail($sformatf("only %0d packed line fetches completed in the frame", fetches));
    if (worst_fetch >= LINE31_SYS) fail($sformatf("a packed line fetch took %0d clk_sys, past the 31 kHz line (%0d)", worst_fetch, LINE31_SYS));
    if (cpu_accepts < 1000) fail("the CPU stream was not served (the contention leg is vacuous)");
    if (errors == 0) begin
      $display("TB_PC9821_PEGC_480: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_PEGC_480: FAIL (%0d problems)", errors);
    end
  end

endmodule

`default_nettype wire

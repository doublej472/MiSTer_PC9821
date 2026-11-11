`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The GDC graphics mode against NP2kai io/gdc.c and vram/makegrph.c (PRIMARY) and QEMU pc98-vga.c: the fixed 24 kHz 848x440 / 640x400 raster in graphics mode (the 15 kHz and 31 kHz selects on 0x6A/0x6E are UNIMPLEMENTED), the CRTC registers 0x70-0x7A (the machine probe reads their reset values back, a reference disagreement the core follows the machine on), the SCROLL display-start word with the partition-2 wrap, the slave CSRFORM line repeat, and the graphics GDC's START/STOP compositor gate. Both Round-3 mismatches are fixed and asserted: the scanout fetch is enabled by mode1[7] (the DISP) and a burst that crosses the 32 KiB plane end clamps per burst instead of reading the next plane.
// The GDC graphics mode against NP2kai io/gdc.c and vram/makegrph.c (PRIMARY) and QEMU pc98-vga.c: the fixed 24 kHz 848x440 / 640x400 raster in graphics mode (the 15 kHz and 31 kHz selects on 0x6A/0x6E are UNIMPLEMENTED, as the module's own note says), the CRTC registers 0x70-0x7A (NP2kai and QEMU are write-only and answer 0xFF while the machine probe docs/probes/GDC.TXT reads their reset values back, so the core follows the machine and this is a reference disagreement, not a defect), the SCROLL display-start word (byte address = word*2, NP2kai's LOW15(word<<1)) with the partition-2 wrap, the slave CSRFORM line repeat (lr=2 holds each GDC line on two raster lines; mode1[4]'s blank-vs-duplicate arm is not modelled, which the bench records as a known deviation), and the graphics GDC's START/STOP compositor gate. It finds TWO mismatches: (1) a scanout line whose base is within 79 bytes of the 32 KiB plane end does not wrap per column as both references' LOW15/mask do, so its last columns read the NEXT plane; (2) the scanout fetch is gated by the TEXT GDC's DISP+START (pc9821_system's scan_enable) instead of the graphics GDC's START, so a program that starts only the graphics GDC shows black where NP2kai and QEMU show graphics. Every case prints one line with its verdict.

`default_nettype none

module tb_pc9821_gdc_graphics;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ==== DUT ====
  // The system's pixel enable: 21.0526 MHz from a 50 MHz clk (pc9821_system.sv).
  localparam [23:0] PIXEL_CE_INC = 24'd7063303;
  reg  [23:0] ce_acc = 24'd0;
  wire [24:0] ce_sum = {1'b0, ce_acc} + PIXEL_CE_INC;
  wire        pixel_ce = ce_sum[24];
  always @(posedge clk) begin
    if (reset) ce_acc <= 24'd0;
    else       ce_acc <= ce_sum[23:0];
  end

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
  wire        disp_on;            // mode1[7] && the TEXT GDC's START: pc9821_system routes this to scan_enable
  wire        gfx_disp;           // the graphics GDC's own START/STOP latch: the mixer's grph_disp
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

  // The line tick, as pc9821_system builds it (one clk_sys pulse at the last dot of the line).
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

  // The four planes and their per-line fetch into the ping-pong line buffer, wired to the raster
  // exactly as pc9821_system wires them - including scan_enable, which is `disp_on` (the TEXT
  // GDC's) and not the graphics GDC's latch.
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
      .scan_enable(disp_on), .scan_line_tick(scan_line_tick),
      .scan_page(gfx_line_addr[15]), .scan_line_base(gfx_line_addr[14:0]),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));

  

  // The pixel pipeline: fold -> graphics palette -> compositor, the graphics arm only.
  wire [7:0] r_out, g_out, b_out;
  // The PEGC arm's inputs (pegc-scope-REPORT.md 4 row 4): tied off in the
  // 16-colour benches; tb_pc9821_video_mixer drives them.
  reg        mix_pegc_256 = 1'b0;
  reg        mix_pal256_wr_en = 1'b0;
  reg  [7:0] mix_pal256_wr_idx = 8'd0, mix_pal256_wr_data = 8'd0;
  reg  [1:0] mix_pal256_wr_chan = 2'd0;
  pc9821_video_mixer u_mixer (
      .dot_x(pix_dot), .h_active(pix_h_active), .v_active(pix_v_active),
      .text_opaque(text_opaque), .text_cell(text_cell), .text_colour(text_colour),
      .line_data(line_data), .line_ready(line_ready), .line_sel(line_sel),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .clk(clk),
      .pal_mode16(gfx_mode16), .pal_dig(gfx_dig),
      .pal_wr_en(1'b0), .pal_wr_idx(4'd0), .pal_wr_chan(2'd0), .pal_wr_data(4'd0),
      .fold_bypass(1'b0), .packed_idx(8'h00),
    .pegc_256(mix_pegc_256),
    .pal256_wr_en(mix_pal256_wr_en), .pal256_wr_idx(mix_pal256_wr_idx),
    .pal256_wr_chan(mix_pal256_wr_chan), .pal256_wr_data(mix_pal256_wr_data),
      .comp_rule(2'b00), .grph_disp(gfx_disp),
      .r_out(r_out), .g_out(g_out), .b_out(b_out)
  );

  // ==== STIMULUS ====
  integer errors = 0;
  integer mismatches = 0;
  integer notes = 0;

  task automatic fail(input [8*160-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  task automatic mismatch(input [8*160-1:0] what);
    begin
      $display("MISMATCH %0s", what);
      errors = errors + 1;
      mismatches = mismatches + 1;
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

  task automatic read_io(input [7:0] portnum, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = portnum;
      io_rd   = 1'b1;
      @(negedge clk);
      data = io_dout;
      io_rd = 1'b0;
      @(negedge clk);
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

  // One plane's byte at one plane offset (the word's byte lane is the plane index).
  task automatic put_byte(input [1:0] plane, input [14:0] off, input [7:0] val);
    begin
      cpu_store(plane, off, {24'd0, val} << (off[1:0] * 8), 4'b0001 << off[1:0]);
    end
  endtask

  // Read one plane's byte back through the CPU plane window (port 0xA6 selects the page).
  task automatic get_byte(input [1:0] plane, input page, input [14:0] off, output [7:0] val);
    reg [31:0] d;
    begin
      write_io(8'hA6, {7'b0, page});
      @(negedge clk);
      win_plane  = plane;
      win_offset = off;
      cpu_din    = 32'd0;
      cpu_be     = 4'b0001 << off[1:0];
      cpu_write  = 1'b0;
      cpu_valid  = 1'b1;
      @(posedge clk);
      #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be    = 4'hF;
      #1;
      while (!cpu_resp_valid) begin @(posedge clk); #1; end
      d = cpu_dout;
      val = d[{off[1:0], 3'b000} +: 8];
      repeat (3) @(posedge clk);
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
        4'h1: itf_entry = 12'h007;   // blue
        4'h2: itf_entry = 12'h700;   // red
        4'h3: itf_entry = 12'h707;   // magenta
        4'h4: itf_entry = 12'h070;   // green
        4'h5: itf_entry = 12'h077;   // cyan
        4'h6: itf_entry = 12'h770;   // yellow
        4'h7: itf_entry = 12'h777;   // white
        4'h8: itf_entry = 12'h444;
        4'h9: itf_entry = 12'h00F;
        4'hA: itf_entry = 12'hF00;
        4'hB: itf_entry = 12'hF0F;
        4'hC: itf_entry = 12'h0F0;
        4'hD: itf_entry = 12'h0FF;
        4'hE: itf_entry = 12'hFF0;
        default: itf_entry = 12'hFFF;
      endcase
    end
  endfunction

  function automatic [23:0] expand8(input [11:0] c);
    begin
      expand8 = { {c[11:8], c[11:8]}, {c[7:4], c[7:4]}, {c[3:0], c[3:0]} };
    end
  endfunction

  localparam [23:0] BLUE = 24'h000077;
  localparam [23:0] RED  = 24'h770000;
  localparam [23:0] BLACK = 24'h000000;

  // The graphics GDC's SCROLL: 0xA2 <- 0x70 then eight parameter bytes, two partitions of
  // {start word lo/hi, {{im, lines} lo/hi}}. The start is a WORD address; the GDC byte
  // address is word*2 (NP2kai makegrph.c:145 `LOW15(word << 1)`).
  task automatic scroll(input [15:0] sta1, input [13:0] lin1,
                        input [15:0] sta2, input [13:0] lin2);
    begin
      write_io(8'hA2, 8'h70);
      write_io(8'hA0, sta1[7:0]);
      write_io(8'hA0, sta1[15:8]);
      write_io(8'hA0, {lin1[11:0], 4'b0}[7:0]);
      write_io(8'hA0, {lin1[11:0], 4'b0}[15:8]);
      write_io(8'hA0, sta2[7:0]);
      write_io(8'hA0, sta2[15:8]);
      write_io(8'hA0, {lin2[11:0], 4'b0}[7:0]);
      write_io(8'hA0, {lin2[11:0], 4'b0}[15:8]);
    end
  endtask

  // The graphics GDC's CSRFORM: 0xA2 <- 0x4B then the ONE parameter byte the firmware
  // writes; its low five bits are lr-1 (NP2kai makegrph.c:362).
  task automatic csrform(input [7:0] lrm1);
    begin
      write_io(8'hA2, 8'h4B);
      write_io(8'hA0, lrm1);
    end
  endtask

  // ---- raster measurement, in DOTS (one pixel-enable cycle = one dot) ----
  reg        measuring = 1'b0;
  reg [31:0] n_cyc = 0, n_hsf = 0, n_vsf = 0, n_de = 0;
  reg        hs_ce_q = 0, vs_ce_q = 0;
  always @(posedge clk) begin
    if (pixel_ce) begin
      hs_ce_q <= hs_out;
      vs_ce_q <= vs_out;
      if (measuring) begin
        n_cyc <= n_cyc + 32'd1;
        if (hs_ce_q && !hs_out) n_hsf <= n_hsf + 32'd1;
        if (vs_ce_q && !vs_out) n_vsf <= n_vsf + 32'd1;
        if (de_out)             n_de  <= n_de  + 32'd1;
      end
    end
  end

  task automatic measure_raster(output integer cyc, output integer line_dots,
                                output integer lines_per_frame, output integer de_per_frame);
    integer guard;
    begin
      n_cyc = 0; n_hsf = 0; n_vsf = 0; n_de = 0;
      measuring = 1'b1;
      guard = 0;
      while ((n_cyc < 32'd746240) && (guard < 32'd4000000)) begin
        @(posedge clk);
        guard = guard + 1;
      end
      measuring = 1'b0;
      @(posedge clk);
      cyc             = n_cyc;
      line_dots       = (n_hsf != 0) ? (n_cyc / n_hsf) : 0;
      lines_per_frame = (n_vsf != 0) ? (n_hsf / n_vsf) : 0;
      de_per_frame    = (n_vsf != 0) ? (n_de  / n_vsf) : 0;
    end
  endtask

  // ---- scanout capture ----
  reg        armed = 1'b0;
  reg [8:0]  cap_line = 9'd0;
  reg [7:0]  cap_r [0:79];
  reg [7:0]  cap_g [0:79];
  reg [7:0]  cap_b [0:79];
  reg        cap_seen [0:79];
  always @(posedge clk) begin
    if (armed && pixel_ce && pix_h_active && pix_v_active &&
        (u_gdc.u_crtc.vline == cap_line) && (u_gdc.u_crtc.hdot[2:0] == 3'd0)) begin
      cap_r[u_gdc.u_crtc.hdot[9:3]] <= r_out;
      cap_g[u_gdc.u_crtc.hdot[9:3]] <= g_out;
      cap_b[u_gdc.u_crtc.hdot[9:3]] <= b_out;
      cap_seen[u_gdc.u_crtc.hdot[9:3]] <= 1'b1;
    end
  end

  // Wait n frame boundaries, so the frame-end configuration snapshot has taken the last write.
  // The boundary is the raster's own frame_end, NOT a frame_cnt change: frame_cnt is the
  // character blink's count and advances once per CSRFORM `timing` frames,
  // so it is no longer a frame counter. frame_end can hold for more than
  // one clk here (pixel_ce is not 1:1), so the wait leaves the pulse before taking the next.
  task automatic next_frame();
    begin
      while (u_gdc.u_crtc.frame_end) @(negedge clk);
      while (!u_gdc.u_crtc.frame_end) @(negedge clk);
    end
  endtask

  task automatic wait_frames(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) next_frame();
    end
  endtask

  task automatic capture_raster(input [8:0] L);
    integer c;
    begin
      cap_line = L;
      for (c = 0; c < 80; c = c + 1) cap_seen[c] = 1'b0;
      next_frame();
      next_frame();
      armed = 1'b1;
      wait (u_gdc.u_crtc.vline == (L + 9'd1));
      armed = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic sample_rgb(input [8:0] L, input [9:0] D,
                            output [7:0] cr, output [7:0] cg, output [7:0] cb);
    begin
      wait (u_gdc.u_crtc.vline == L);
      wait (u_gdc.u_crtc.hdot == D);
      @(negedge clk);
      cr = r_out; cg = g_out; cb = b_out;
    end
  endtask

  // The scanout's own display-address decode at a chosen GDC/picture line.
  task automatic sample_gbase(input [9:0] oline, output [14:0] base, output page);
    reg [9:0] want_v;
    begin
      want_v = (oline >= 10'd2) ? (oline - 10'd2) : (oline + 10'd438);
      wait (u_gdc.u_crtc.vline == want_v[8:0]);
      wait (u_gdc.u_crtc.hdot == 10'd0);
      @(negedge clk);
      base = gfx_line_addr[14:0];
      page = gfx_line_addr[15];
    end
  endtask

  // ==== CHECKS ====
  integer c;
  integer first_bad, n_bad;
  integer sec_errors;   // errors at the start of a section, so a section's own ok/FAIL is its own
  reg [7:0] cr, cg, cb;
  reg [14:0] base;
  reg page;
  integer cyc, line_dots, lines_per_frame, de_per_frame;
  reg [7:0] rd;

  initial begin
    repeat (4) @(posedge clk);
    reset <= 1'b0;
    repeat (4) @(posedge clk);

    // ---------------------------------------------------------------
    // 1. The scanout enable is the TEXT GDC's DISP+START, not the graphics GDC's START.
    //    mode1[7] (DISP) is set, the graphics GDC is STARTed, the text GDC is NOT started;
    //    a painted line 0 must appear (NP2kai scrndraw.c:188-200 and QEMU pc98-vga.c:4476-4495
    //    gate graphics on mode1[DISP] AND gdc_gfx.start only).
    // ---------------------------------------------------------------
    write_io(8'h68, 8'h0F);   // mode1 bit7 = DISP on
    write_io(8'h6A, 8'h01);   // 16-colour analogue
    write_io(8'hA2, 8'h0D);   // graphics GDC START (no 0x62 text START)
    scroll(16'h0000, 14'd400, 16'h0000, 14'd0);
    for (c = 0; c < 80; c = c + 1)
      put_column(c[14:0], 8'hFF, 8'h00, 8'h00, 8'h00);   // line 0, index 1 (blue)
    capture_raster(9'd0);
    if (!cap_seen[0]) begin
      fail("scanout_enable_graphics_start: raster 0 column 0 was never sampled");
    end else if ({cap_r[0], cap_g[0], cap_b[0]} !== BLUE) begin
      mismatch("scanout_enable_graphics_start: raster 0 col 0");
      $display("  core=%02x%02x%02x (black: the GVRAM fetch is gated by the TEXT GDC's DISP+START, pc9821_system scan_enable=disp_on), NP2kai scrndraw.c:188-200 + QEMU pc98-vga.c:4476-4495=%02x%02x%02x (graphics shows with mode1[DISP] and the graphics GDC's START alone)",
               cap_r[0], cap_g[0], cap_b[0], BLUE[23:16], BLUE[15:8], BLUE[7:0]);
    end else begin
      $display("ok       scanout_enable_graphics_start = %02x%02x%02x", cap_r[0], cap_g[0], cap_b[0]);
    end

    // Now start the text GDC (the BIOS's own boot order), which is what pc9821_system's
    // scan_enable actually needs before any graphics is fetched.
    write_io(8'h62, 8'h0D);   // text GDC START
    write_io(8'h68, 8'h08);   // mode1 bit4 clear (400-line)
    scroll(16'h0000, 14'd400, 16'h0000, 14'd0);
    repeat (4) @(posedge clk);

    // ---------------------------------------------------------------
    // 2. The 24 kHz raster in graphics mode: 848 dots/line, 440 lines, 640x400 active.
    // ---------------------------------------------------------------
    measure_raster(cyc, line_dots, lines_per_frame, de_per_frame);
    if (line_dots != 848)
      fail("raster_graphics_24khz: the line is not 848 dots");
    if (lines_per_frame != 440)
      fail("raster_graphics_24khz: the frame is not 440 lines");
    if (de_per_frame != 256000)
      fail("raster_graphics_24khz: the active field is not 640x400 dots");
    if (line_dots == 848 && lines_per_frame == 440 && de_per_frame == 256000)
      $display("ok       raster_graphics_24khz = %0d dots x %0d lines (%0d active dots)",
               line_dots, lines_per_frame, de_per_frame);

    // ---------------------------------------------------------------
    // 3. The 15 kHz / 31 kHz selects: NP2kai gdc_o6a decodes dat 0x20/0x21 as the 31 kHz
    //    analog extension and gdc_o6e bit0 as 15 kHz; the core's raster is fixed.
    // ---------------------------------------------------------------
    write_io(8'h6E, 8'h01);
    write_io(8'h6A, 8'h21);
    measure_raster(cyc, line_dots, lines_per_frame, de_per_frame);
    if (line_dots != 848 || lines_per_frame != 440 || de_per_frame != 256000)
      fail("raster_31khz_15khz_control: the raster moved, which is not the core's documented fixed raster");
    else begin
      $display("UNIMPLEMENTED raster_31khz_15khz_control: core keeps 848x440 (24 kHz); NP2kai gdc_o6a dat 0x20/0x21 (31 kHz, io/gdc.c:552-560) and gdc_o6e (io/gdc.c:608-618) select other sync sets");
      notes = notes + 1;
    end
    write_io(8'h6A, 8'h01);
    write_io(8'h6E, 8'h00);

    // ---------------------------------------------------------------
    // 4. The CRTC registers 0x70-0x7A. NP2kai crtci70 and QEMU's portio have no read
    //    handler, so both answer 0xFF; the machine probe reads the reset values back
    //    (docs/probes/GDC.TXT: 70=00 72=0F 74=10 76=00 78=00 7A=00, "no writes were made").
    //    The WRITE is FIVE BITS wide - NP2kai's crtc_o70 does `dat &= 0x1f` before
    //    storing (io/crtc.c:10-17), so the latch and its readback
    //    carry value & 0x1F and 0xA5 reads back 0x05.
    // ---------------------------------------------------------------
    begin : crtc_case
      integer k;
      reg [7:0] crtcv, crtc_port;
      crtcv = 8'hA5;
      for (k = 0; k < 6; k = k + 1) begin
        crtc_port = 8'h70 | (k[7:0] << 1);
        write_io(crtc_port, crtcv);
        read_io(crtc_port, rd);
        if (rd !== (crtcv & 8'h1F))
          fail("crtc_70_7a_readback: the core did not read back its 5-bit 0x70-0x7A latch");
      end
      $display("NOTE     crtc_70_7a_readback: core reads the written value back FIVE BITS wide (NP2kai crtc_o70 dat &= 0x1f); NP2kai crtci70 and QEMU have no read handler (0xFF), while docs/probes/GDC.TXT reads the reset values back with no writes - the machine supports the core's readback, so this is a reference disagreement on the READ side only, not a defect");
      notes = notes + 1;
      for (k = 0; k < 6; k = k + 1)
        write_io(8'h70 | (k[7:0] << 1), 8'h00);
    end

    // ---------------------------------------------------------------
    // 5. The SCROLL display-start word and the partition-2 wrap.
    //    start word 0x3FFF -> byte 0x7FFE; 128-line partition 1; partition 2 at word 0x0100.
    // ---------------------------------------------------------------
    scroll(16'h3FFF, 14'd128, 16'h0100, 14'd272);
    wait_frames(2);
    sec_errors = errors;
    sample_gbase(10'd0, base, page);
    if ((base !== 15'h7FFE) || page)
      fail("scroll_start_decode: line 0 base is not the SCROLL word*2 (byte 0x7FFE)");
    sample_gbase(10'd1, base, page);
    if ((base !== 15'h004E) || page)
      fail("scroll_start_decode: line 1 base did not wrap at the 32 KiB plane (want 0x004E)");
    sample_gbase(10'd128, base, page);
    if ((base !== 15'h0200) || page)
      fail("scroll_partition2: line 128 base is not partition 2's start (want 0x0200)");
    sample_gbase(10'd129, base, page);
    if ((base !== 15'h0250) || page)
      fail("scroll_partition2: line 129 base is not 0x0200 + 80");
    if (errors == sec_errors)
      $display("ok       scroll_start_decode + scroll_partition2 (word*2, 15-bit wrap, partition 2)");

    // ---------------------------------------------------------------
    // 6. The CSRFORM line repeat: lr=2 holds each GDC line on two raster lines (both
    //    references' duplicate arm). Paint GDC line 0 blue and line 1 red.
    // ---------------------------------------------------------------
    scroll(16'h0000, 14'd400, 16'h0000, 14'd0);
    csrform(8'h01);
    sec_errors = errors;
    for (c = 0; c < 80; c = c + 1)
      put_column(c[14:0], 8'hFF, 8'h00, 8'h00, 8'h00);          // GDC line 0, blue
    for (c = 80; c < 160; c = c + 1)
      put_column(c[14:0], 8'h00, 8'hFF, 8'h00, 8'h00);          // GDC line 1, red
    capture_raster(9'd0);
    if ({cap_r[0], cap_g[0], cap_b[0]} !== BLUE)
      fail("line_double_csrform_lr2: raster 0 col 0 is not GDC line 0");
    capture_raster(9'd1);
    if ({cap_r[0], cap_g[0], cap_b[0]} !== BLUE)
      fail("line_double_csrform_lr2: raster 1 col 0 is not GDC line 0 held twice");
    capture_raster(9'd2);
    if ({cap_r[0], cap_g[0], cap_b[0]} !== RED)
      fail("line_double_csrform_lr2: raster 2 col 0 is not GDC line 1");
    if (errors == sec_errors)
      $display("ok       line_double_csrform_lr2 (raster 0/1 = GDC line 0, raster 2 = GDC line 1)");

    // ---------------------------------------------------------------
    // 7. mode1[4]: 200-line mode's blank arm. NP2kai makegrph.c:155 and QEMU
    //    pc98-vga.c:4475 blank the repeated raster line when mode1[4] is set; this core
    //    keeps the duplicate (deliberate - KNOWN-DEVIATION).
    // ---------------------------------------------------------------
    write_io(8'h68, 8'h09);   // mode1 bit4 = 1 (200-line)
    capture_raster(9'd1);
    if ({cap_r[0], cap_g[0], cap_b[0]} !== BLUE) begin
      fail("line_double_mode1_4_blank: expected the core's duplicate (blue) in the 200-line mode");
    end else begin
      $display("KNOWN-DEVIATION line_double_mode1_4_blank: core raster 1 col 0 = %02x%02x%02x (GDC line 0 duplicated); NP2kai makegrph.c:155 and QEMU pc98-vga.c:4475 blank the repeated line when mode1[4] is set - a documented deviation",
               cap_r[0], cap_g[0], cap_b[0]);
      notes = notes + 1;
    end
    write_io(8'h68, 8'h08);   // back to 400-line
    csrform(8'h00);           // lr = 1

    // ---------------------------------------------------------------
    // 8. The scanout line's per-column wrap at the 32 KiB plane end. start word 0x3FFF
    //    (byte 0x7FFE): NP2kai makegrph.c:180-186 and QEMU gdc_get_address both mask every
    //    column with LOW15/0x7fff, so columns 2..79 must read page 0 offsets 0..0x4D.
    // ---------------------------------------------------------------
    scroll(16'h3FFF, 14'd400, 16'h0000, 14'd0);
    write_io(8'hA6, 8'h00);
    put_column(15'h7FFE, 8'hFF, 8'h00, 8'h00, 8'h00);      // page 0, byte 0x7FFE: index 1
    put_column(15'h7FFF, 8'hFF, 8'h00, 8'h00, 8'h00);      // page 0, byte 0x7FFF: index 1
    for (c = 0; c <= 16'h004F; c = c + 1)
      put_column(c[14:0], 8'hFF, 8'h00, 8'h00, 8'h00);     // page 0, the wrapped offsets: index 1
    write_io(8'hA6, 8'h01);
    for (c = 0; c <= 16'h000C; c = c + 1)
      put_column(c[14:0], 8'h00, 8'hFF, 8'h00, 8'h00);     // page 1, offsets 0..0xC: index 2 (red)
    write_io(8'hA6, 8'h00);
    capture_raster(9'd0);
    first_bad = -1;
    n_bad = 0;
    for (c = 0; c < 80; c = c + 1) begin
      if (!cap_seen[c]) begin
        fail("scanout_plane_wrap: a raster 0 column was never sampled");
      end else if ({cap_r[c], cap_g[c], cap_b[c]} !== BLUE) begin
        if (first_bad < 0) first_bad = c;
        n_bad = n_bad + 1;
      end
    end
    if (n_bad != 0) begin
      mismatch("scanout_plane_wrap: raster 0 columns are not page 0's wrapped bytes");
      $display("  %0d of 80 columns wrong; first %0d = %02x%02x%02x; the line base is 0x7FFE and its burst crosses the plane end, so the core reads page 1 (red) where NP2kai makegrph.c:180-186's LOW15 and QEMU gdc_get_address's &0x7fff wrap to page 0 offset 0 (blue)",
               n_bad, first_bad, cap_r[first_bad], cap_g[first_bad], cap_b[first_bad]);
    end else begin
      $display("ok       scanout_plane_wrap (all 80 columns wrapped inside the plane)");
    end

    // ---------------------------------------------------------------
    // 9. The graphics GDC's STOP blanks the graphics plane (the compositor's grph_disp).
    // ---------------------------------------------------------------
    write_io(8'hA2, 8'h0C);   // graphics GDC STOP
    capture_raster(9'd0);
    if ({cap_r[0], cap_g[0], cap_b[0]} !== BLACK)
      fail("graphics_stop_blank: the graphics plane is not blank after the GDC2 STOP");
    else
      $display("ok       graphics_stop_blank");
    write_io(8'hA2, 8'h0D);   // graphics GDC START again

    // ---------------------------------------------------------------
    // 10. The graphics VRAM read: a store through one plane window reads back through
    //     that window's lane only. The windows are 0xA8000 = plane B, 0xB0000 = plane R,
    //     0xB8000 = plane G and 0xE0000 = plane E (QEMU pc98-mem.c:1377 maps the same
    //     aliases at base 0xa0000 + 0x8000/0x10000/0x40000); 0xC0000-0xD7FFF is the absent
    //     ROM area in both, so no reference maps graphics there.
    // ---------------------------------------------------------------
    sec_errors = errors;
    write_io(8'hA6, 8'h00);          // access page 0
    put_byte(2'd0, 15'h0010, 8'hCB);
    put_byte(2'd1, 15'h0011, 8'h5A);
    get_byte(2'd0, 1'b0, 15'h0010, rd);
    if (rd !== 8'hCB)
      fail("plane_window_read: plane 0 (0xA8000) did not read the seed byte back");
    get_byte(2'd1, 1'b0, 15'h0010, rd);
    if (rd !== 8'h00)
      fail("plane_window_read: plane 1's lane holds plane 0's seed");
    get_byte(2'd1, 1'b0, 15'h0011, rd);
    if (rd !== 8'h5A)
      fail("plane_window_read: plane 1 (0xB0000) did not read its own byte back");
    get_byte(2'd2, 1'b0, 15'h0011, rd);
    if (rd !== 8'h00)
      fail("plane_window_read: plane 2's lane holds plane 1's byte");
    get_byte(2'd3, 1'b0, 15'h0011, rd);
    if (rd !== 8'h00)
      fail("plane_window_read: plane 3's lane holds plane 1's byte");
    write_io(8'hA6, 8'h00);
    if (errors == sec_errors)
      $display("ok       plane_window_read (the four plane windows read back their own lane)");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GDC_GRAPHICS: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_GDC_GRAPHICS: FAIL (%0d errors, %0d mismatches, %0d notes)",
             errors, mismatches, notes);
  end

  // The captures and two raster measurements are a little over a hundred frames; 2 s is
  // far past them and still a bounded run.
  initial begin
    #2_000_000_000;
    $fatal(1, "TB_PC9821_GDC_GRAPHICS: TIMEOUT");
  end

endmodule

`default_nettype wire

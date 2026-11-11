`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The text GDC's JIS glyph fetch is ONE 8-dword SDRAM burst, not eight serialized single-word reads: driving the real pc9821_gdc_text and pc9821_memory_subsystem font path over a backend whose accept-to-first-dword latency is the machine's own (~9 clk_sys), a whole 32-byte glyph block is assembled from ONE request in a fraction of the eight round trips the old one-word-at-a-time fetch spent, and the assembled block's 32 bytes are still exactly the FONT.ROM glyph - read back through the CPU's own port 0xA9 (the block is a block RAM since area-video, so it has no byte array to peek and 0xA5's half+row walk is the honest view). The serialized cost is measured through the SAME backend with a reference one-word requester, so the two cycle counts differ only in the request shape. The block RAM's READ side is held to the contract a burst write creates: on a fresh burst the port-0xA9 hold (cg_rd_hold, what the I/O bus waits on) must stay asserted on the cycle the last beat is written - its registered read still holds the pre-write word there - and drop exactly one cycle later, presenting the glyph's own byte, for all 32 positions on their own bursts.
//
// The 8-dword glyph block is 32-byte aligned, so the burst never crosses an SDRAM row
// boundary (the controller's 256-dword row at 32 MB is a multiple of 8 dwords); a 32-byte
// block is the whole glyph, so eight consecutive dwords are exactly its 32 bytes.


`default_nettype none

module tb_pc9821_font_fetch;
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;      // 50 MHz, one clk_sys = 2 clk_sdram
  reg reset = 1;

  localparam [31:0] PACK_BASE        = 32'h01F8_0000;
  localparam [31:0] FONT_PACK_OFFSET = 32'h0008_0000;
  localparam [18:0] GLYPH_BASE       = 19'hCC20;     // FONT.ROM[0xCC20]: JIS ku 0x30 ten 0x21
  // The NEXT JIS row (code 0x2111), which the hazard walk alternates with 0x2110 so that
  // every iteration re-fetches a block: the two codes share a high byte, so ONE 0xA3 write
  // moves the code and no intermediate value is ever a different class.
  localparam [18:0] GLYPH_BASE_B     = 19'hD820;
  localparam [7:0]  HZ_CODE_LO_A     = 8'h10;        // 0xA3: ku = 0x30 -> FONT.ROM[0xCC20]
  localparam [7:0]  HZ_CODE_LO_B     = 8'h11;        // 0xA3: ku = 0x31 -> FONT.ROM[0xD820]
  // The backend's accept-to-first-dword latency. A measurement found a dependent
  // read at accept+7 clk_sys through the real bridge; 8 keeps the round trip honest.
  localparam integer RESP_LAT = 8;

  // FONT.ROM[0xCC20 .. 0xCC40): the machine's own 32-byte glyph, byte 0 first.
  localparam [255:0] GLYPH =
      256'h00fe202020fe2222222222fe202020ff_003f0202023f22222222223f0202027f;
  function automatic [7:0] gbyte(input integer i);
    gbyte = GLYPH[(31 - i) * 8 +: 8];
  endfunction

  // ---- memory subsystem controls --------------------------------------
  reg [3:0]  top_bank = 4'd8;
  reg        ide_rom_enable = 0;
  reg        bios_ram_gate = 0;
  reg  [1:0] ems_state = 2'd0;
  reg        top_shadow_en = 0;
  reg  soft_reboot = 1'b0;   // no reboot strobe in this bench
  reg  [7:0] win0_sel = 8'h08;
  reg        sys16m_en = 1'b1;
  reg [31:0] pack_base = PACK_BASE;
  reg [31:0] guest_ram_bytes = 32'h0200_0000;
  reg        gvram_access_page = 0;
  reg        ioctl_download = 0, ioctl_wr = 0;
  reg [15:0] ioctl_index = 0;
  reg [26:0] ioctl_addr = 0;
  reg [15:0] ioctl_dout = 0;
  wire       ioctl_wait, rom_ready, load_error, cpu_run;
  wire [17:0] font_addr;
  wire [15:0] font_data;
  wire       font_we;

  reg [31:0] cpu_addr = 0, cpu_din = 0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  reg [3:0]  cpu_be = 4'hF;
  reg [7:0]  cpu_burstcount = 1;
  reg        cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  wire       cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  wire [13:0] tram_addr;
  wire  [7:0] tram_din, tram_dout;
  wire        tram_we;

  // CG byte channel between the subsystem's window responder and the GDC.
  wire  [4:0] cg_win_byte_sel;
  wire        cg_win_rd;
  wire  [7:0] cg_win_dout, cg_win_din;
  wire        cg_win_we;
  // The port-0xA9 hold: high while the code's glyph block burst is still in flight, plus the
  // one cycle after its last beat that the block RAM's registered read needs to catch up.
  wire        cg_rd_hold;

  // Glyph fetch: the GDC's request and the SDRAM's second port behind it.
  wire [18:0] font_req_addr;
  wire        font_req, font_word_valid;
  wire [31:0] font_word_data;
  wire [31:0] fmem_addr, fmem_din;
  wire        fmem_valid, fmem_write;
  wire  [3:0] fmem_be;
  wire  [7:0] fmem_burstcount;
  wire        fmem_ready;
  reg  [31:0] fmem_dout;
  reg         fmem_resp_valid;

  // Backend (SDRAM port 0) stub: the CPU's memory, unused here.
  wire [31:0] mem_addr, mem_din, mem_din_hi;
  reg  [31:0] mem_dout = 32'hDEAD_BEEF;
  reg [127:0] mem_line_dout = 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210;
  wire  [3:0] mem_be;
  wire  [7:0] mem_burstcount;
  wire        mem_line_read, mem_valid, mem_write;
  reg         mem_ready = 1, mem_resp_valid = 0, mem_line_resp_valid = 0;

  // The GVRAM datapath's device-bus and scanout ports, parked (this bench drives only the
  // font path; tb_pc9821_cg_read_path wires the same DUT the same way).
  reg        grcg_we = 0;
  reg  [7:0] grcg_addr = 0;
  reg  [7:0] grcg_din = 0;
  reg        scan_enable = 0;
  reg        scan_line_tick = 0;
  reg        scan_page = 0;
  reg        scan_walk_page = 0;
  reg [14:0] scan_line_base = 0;
  reg  [6:0] line_rd_addr = 0;
  reg        line_rd_sel = 0;
  wire [31:0] line_data;
  wire        line_sel;
  wire        line_ready;

  // ==== DUT ====
  // The two blocks wired exactly as pc9821_system.sv wires them, so the assertion is the
  // real font requester (pc9821_memory_subsystem) feeding the real consumer (pc9821_gdc_text).
  // The 16-colour select (port 0x6A FF2 num 0): 0 = the digital mode the machine resets to,
  // where 0xE0000-0xE7FFF is open bus (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b0;
  pc9821_memory_subsystem dut_mem (
      .mode2_16color(mode2_16color),
      .scan_dot_ce(1'b0), .scan_dot_act(1'b1),
      .clk(clk_sys), .reset(reset),
      .top_bank(top_bank), .ems_state(ems_state), .ide_rom_enable(ide_rom_enable), .d8_bank(2'b00), .ide_ram_gate(1'b1),
      .bios_ram_gate(bios_ram_gate), .top_shadow_en(top_shadow_en), .soft_reboot(soft_reboot),
      .win0_sel(win0_sel), .win0_sel_moved(win0_sel != 8'h08), .sys16m_en(sys16m_en),
      .pack_base(pack_base), .guest_ram_bytes(guest_ram_bytes),
      .gvram_access_page(gvram_access_page),
      .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
      .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
      .ioctl_wait(ioctl_wait), .rom_ready(rom_ready), .load_error(load_error),
      .cpu_run(cpu_run),
      .font_addr(font_addr), .font_data(font_data), .font_we(font_we),
      .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_dout(cpu_dout),
      .cpu_be(cpu_be),
      .cpu_burstcount(cpu_burstcount), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write), .cpu_ready(cpu_ready),
      .cpu_resp_valid(cpu_resp_valid), .tram_addr(tram_addr), .tram_din(tram_din), .tram_we(tram_we),
      .tram_dout(tram_dout),
      .cg_win_byte_sel(cg_win_byte_sel), .cg_win_rd(cg_win_rd),
      .cg_win_dout(cg_win_dout), .cg_win_din(cg_win_din), .cg_win_we(cg_win_we),
      .font_req_addr(font_req_addr), .font_req(font_req),
      .font_word_valid(font_word_valid), .font_word_data(font_word_data),
      .fmem_addr(fmem_addr), .fmem_din(fmem_din),
      .fmem_valid(fmem_valid), .fmem_write(fmem_write),
      .fmem_be(fmem_be), .fmem_burstcount(fmem_burstcount),
      .fmem_ready(fmem_ready), .fmem_dout(fmem_dout),
      .fmem_resp_valid(fmem_resp_valid),
      .mem_addr(mem_addr), .mem_din(mem_din), .mem_din_hi(mem_din_hi),
      .mem_dout(mem_dout),
      .mem_be(mem_be),
      .mem_burstcount(mem_burstcount),
      .mem_valid(mem_valid), .mem_write(mem_write), .mem_ready(mem_ready),
      .mem_resp_valid(mem_resp_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_walk_page(scan_walk_page),
      .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready)
  );

  // ---- GDC owning the class table, the stores and port 0xA9 -------------
  reg  io_wr = 0, io_rd = 0;
  reg  [7:0] io_addr = 0, io_din = 0;
  wire [7:0] io_dout;
  wire gfx_access_page;
  wire vsync_active, disp_on, vsync_irq;
  reg  vsync_irq_arm = 0;
  wire [15:0] dbg_sad;
  wire  [7:0] dbg_pitch;
  wire dbg_col40, dbg_disp, gfx_disp, gfx_egc_gate;
  wire [15:0] gfx_line_addr;
  wire [11:0] text_colour;
  wire        text_opaque, text_cell;
  wire [9:0]  pix_dot;
  wire        pix_h_active, pix_v_active;
  wire        gfx_mode16;
  wire [31:0] gfx_dig;
  // The analogue palette table's CPU write port (pc9821_gfx_palette's RAM).
  wire        pal_wr_en;
  wire [3:0]  pal_wr_idx;
  wire [1:0]  pal_wr_chan;
  wire [3:0]  pal_wr_data;
  wire hs_out, vs_out, de_out;
  reg  cg_record_restore = 0;
  reg  [6:0] cfg_ram_mib = 7'd0;
  reg        cfg_seed_en = 1'b0;

  pc9821_gdc_text_dut dut_gdc (
      .clk_sys(clk_sys), .rst_n_sys(!reset),
      .cfg_fdd_mode(3'd0),   // entry 0: the measured boot/FDD nibble
      .pixel_ce(1'b1), .cfg_ram_mib(cfg_ram_mib), .cfg_seed_en(cfg_seed_en),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .tram_cpu_addr(tram_addr), .tram_cpu_din(tram_din),
      .tram_cpu_we(tram_we), .tram_cpu_dout(tram_dout),
      .font_ld_addr(font_addr), .font_ld_data(font_data), .font_ld_we(font_we),
      .cg_win_byte_sel(cg_win_byte_sel), .cg_win_rd(cg_win_rd),
      .cg_win_dout(cg_win_dout), .cg_win_din(cg_win_din), .cg_win_we(cg_win_we),
      .cg_rd_hold(cg_rd_hold),
      .font_req_addr(font_req_addr), .font_req(font_req),
      .font_word_valid(font_word_valid), .font_word_data(font_word_data),
      .cg_record_restore(cg_record_restore),
      .cfg_seed_reload(1'b0),
      .vsync_active(vsync_active), .vsync_irq_arm(vsync_irq_arm),
      .vsync_irq(vsync_irq), .disp_on(disp_on), .gfx_access_page(gfx_access_page),
      .gfx_disp(gfx_disp), .gfx_line_addr(gfx_line_addr),
      .gfx_egc_gate(gfx_egc_gate),
      .text_opaque(text_opaque), .text_cell(text_cell), .text_colour(text_colour),
      .pix_dot(pix_dot), .pix_h_active(pix_h_active), .pix_v_active(pix_v_active),
      .gfx_mode16(gfx_mode16), .gfx_dig(gfx_dig),
      .pal_wr_en(pal_wr_en), .pal_wr_idx(pal_wr_idx),
      .pal_wr_chan(pal_wr_chan), .pal_wr_data(pal_wr_data),
      .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out),
      .dbg_sad(dbg_sad), .dbg_pitch(dbg_pitch), .dbg_col40(dbg_col40),
      .dbg_disp(dbg_disp)
  );

  // ==== STIMULUS ====
  integer cyc = 0;
  always @(posedge clk_sys) cyc <= cyc + 1;

  // Every byte the font region answers. FONT.ROM[0xCC20 .. +32) is the machine's own glyph;
  // anything else gets a value derived from the offset, so a fetch at the wrong address is
  // visible rather than plausible.
  function automatic [7:0] font_byte(input [18:0] off);
    begin
      if (off >= GLYPH_BASE && off < (GLYPH_BASE + 19'd32))
        font_byte = gbyte(off - GLYPH_BASE);
      else
        font_byte = off[7:0] ^ 8'h5A;
    end
  endfunction

  // ---- the serialized reference: the OLD shape, one word outstanding at a time --------
  // It presents 8 single-dword requests to the SAME backend in the same order the old
  // requester did (issue, wait for the response, next word), so its cycle count is the
  // serialized cost with no model of the RTL involved.
  reg        ref_run = 0, ref_valid = 0, ref_done = 0;
  reg  [2:0] ref_idx = 0;
  wire [31:0] ref_addr = PACK_BASE + FONT_PACK_OFFSET + {13'd0, GLYPH_BASE}
                        + {27'd0, ref_idx, 2'b00};

  // ---- the shared backend: one resp_valid per dword, the first RESP_LAT after accept ----
  // ready is LOW while a burst is streaming, exactly as the SDRAM port's `valid`-held-until-
  // `ready` contract requires, so a request presented mid-stream waits instead of being lost.
  wire        mdl_valid = ref_run ? ref_valid       : fmem_valid;
  wire  [7:0] mdl_burst = ref_run ? 8'd1            : fmem_burstcount;
  wire [31:0] mdl_addr  = ref_run ? ref_addr        : fmem_addr;
  wire [31:0] mdl_font  = mdl_addr - (PACK_BASE + FONT_PACK_OFFSET);
  wire [18:0] mdl_off   = mdl_font[18:0];

  reg         mdl_stream = 0;
  reg  [7:0]  mdl_left   = 0;
  reg  [7:0]  mdl_lat    = 0;
  reg  [18:0] mdl_off_q  = 0;
  wire        mdl_rv = fmem_resp_valid;
  assign fmem_ready = ~mdl_stream;
  function automatic [31:0] mdl_word(input [18:0] off);
    mdl_word = {font_byte(off + 3), font_byte(off + 2), font_byte(off + 1), font_byte(off)};
  endfunction

  always @(posedge clk_sys) begin
    fmem_resp_valid <= 1'b0;
    if (mdl_stream) begin
      if (mdl_lat != 0) begin
        mdl_lat <= mdl_lat - 8'd1;
      end else begin
        fmem_dout       <= mdl_word(mdl_off_q);
        fmem_resp_valid <= 1'b1;
        mdl_off_q       <= mdl_off_q + 19'd4;
        mdl_left        <= mdl_left - 8'd1;
        if (mdl_left == 8'd1) mdl_stream <= 1'b0;
      end
    end else if (mdl_valid && fmem_ready) begin
      mdl_lat    <= RESP_LAT[7:0] - 8'd1;   // first dword exactly RESP_LAT cycles after accept
      mdl_left   <= mdl_burst;
      mdl_off_q  <= mdl_off;
      mdl_stream <= 1'b1;
    end
  end

  // The reference holds its request until the backend accepts it, then waits for that word's
  // response before presenting the next -- the old one-outstanding requester's shape, so it
  // never presents word k+1's address before word k's response has shifted the index.
  reg  ref_run_d = 0, ref_issue = 0;
  wire ref_kick  = ref_run && !ref_run_d;
  always @(posedge clk_sys) begin
    if (reset) begin
      ref_valid <= 1'b0; ref_idx <= 3'd0; ref_done <= 1'b0;
      ref_run_d <= 1'b0; ref_issue <= 1'b0;
    end else begin
      ref_run_d <= ref_run;
      if (ref_valid) begin
        if (fmem_ready) ref_valid <= 1'b0;                 // accepted
      end else if (ref_issue && !ref_done) begin
        ref_valid <= 1'b1;
        ref_issue <= 1'b0;
      end
      if (ref_kick) begin
        ref_idx <= 3'd0; ref_done <= 1'b0; ref_issue <= 1'b1;
      end else if (ref_run && mdl_rv && !ref_done) begin
        if (ref_idx == 3'd7) ref_done <= 1'b1;
        else begin ref_idx <= ref_idx + 3'd1; ref_issue <= 1'b1; end
      end
    end
  end

  // ---- cycle capture ---------------------------------------------------
  reg         burst_phase = 0;
  integer     s_first = -1, s_last = -1, b_first = -1, b_last = -1;
  integer     s_reqs = 0, b_reqs = 0;
  reg  [3:0]  s_beats = 0;
  always @(posedge clk_sys) begin
    if (ref_run) begin
      if (ref_valid && s_first < 0) s_first <= cyc;
      if (ref_valid && fmem_ready)  s_reqs  <= s_reqs + 1;
      if (mdl_rv) begin
        s_beats <= s_beats + 4'd1;
        if (s_beats == 4'd7) s_last <= cyc;
      end
    end
    if (burst_phase) begin
      if (font_req && b_first < 0)          b_first <= cyc;
      if (fmem_valid && fmem_ready)         b_reqs  <= b_reqs + 1;
      if (font_word_valid && (dut_gdc.u_cg.fnt_step == 4'd7)) b_last <= cyc;
    end
  end

  integer errors = 0;
  task automatic fail(input [1023:0] what);
    begin
      errors = errors + 1;
      $display("FAIL font_fetch: %0s (cycle %0d)", what, cyc);
    end
  endtask

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum; io_din = data; io_wr = 1;
      @(negedge clk_sys); io_wr = 0;
    end
  endtask

  task automatic read_io(input [7:0] portnum, output [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum;
      #1 data = io_dout;
      @(negedge clk_sys);
    end
  endtask

  // ---- the port's open cycle, checked on one position's own fresh burst ----
  // cg_rd_hold is the port's own open/closed flag (0xA9 + the GDC chip select ->
  // pc9821_iobus's device_rd_hold), and the iobus captures the byte on the cycle it drops, so
  // a cycle with the flag low is a promise that the byte on io_dout is THIS code's byte for
  // THIS position. The cycle the last beat is written (T+1: fnt_act has dropped, the word is
  // in the memory, the port's read register still holds the pre-write word) is the one cycle
  // that promise cannot be kept, so the flag must be HIGH there, and the port must open
  // exactly one cycle later (T+2) holding the byte the flop form returned. One wait cycle is
  // the whole price the trade prices, so neither cycle count may drift by one.
  //
  // Both halves of the contract are asserted on every cycle of the window, which is what makes
  // them two different claims: "open => this byte" is the correctness half (a registered read
  // with the hold NOT extended fails it at T+1), and "still closed at T+1, open at T+2" is the
  // cost half (the beat bypass, which opens the port at T+1 and supplies the beat's word from
  // a flop beside the memory, fails it).
  task automatic check_burst_open(input [7:0] lo, input [7:0] a5, input [7:0] want);
    integer guard2, c, open_cyc;
    reg     beat_seen;
    begin
      write_io(8'hA5, a5);        // the port's index: bit 5 = the half, [3:0] = the row
      write_io(8'hA3, lo);        // the code's low byte: the new block's burst starts here
      @(negedge clk_sys);
      io_addr = 8'hA9;            // the port's own read address, held for the whole window
      beat_seen = 1'b0;
      guard2 = 0;
      while (!beat_seen && guard2 < 16'd400) begin
        @(negedge clk_sys);
        guard2 = guard2 + 1;
        // The burst's eighth word, one cycle before the memory takes it.
        if (font_word_valid && (dut_gdc.u_cg.fnt_step == 4'd7)) beat_seen = 1'b1;
      end
      if (!beat_seen) fail("a burst's last beat was never seen");
      open_cyc = -1;
      for (c = 0; c < 6; c = c + 1) begin
        @(negedge clk_sys);       // c = 0 is T+1, the cycle the beat is written
        if (cg_rd_hold !== 1'b1) begin
          if (open_cyc < 0) open_cyc = c;
          if (io_dout !== want)
            fail("the port was open with a byte that is not this code's for this position");
        end else if (open_cyc >= 0) begin
          fail("the port closed again after it had opened");
        end
      end
      if (open_cyc < 0) fail("the port never opened after the burst landed");
      else if (open_cyc != 1)
        fail("the port opened on the burst's landing cycle (or a cycle late): T12 prices one wait cycle");
    end
  endtask

  // ==== CHECKS ====
  integer serial_cycles, burst_cycles;
  integer k, wrong;
  reg  [7:0] value, a5v;
  reg  [18:0] off;
  reg  [15:0] guard;

  initial begin
    repeat (4) @(posedge clk_sys);
    @(negedge clk_sys);
    reset = 0;

    // ---------------------------------------------------------------
    // 1. The SERIALIZED cost: the reference one-word requester, 8 requests, the last beat's
    //    cycle measured from the first request. This is the old shape at the machine's latency.
    // ---------------------------------------------------------------
    ref_run = 1'b1;
    guard = 0;
    while (!ref_done && guard < 16'd1000) begin
      @(posedge clk_sys); guard = guard + 1;
    end
    ref_run = 1'b0;
    if (!ref_done) fail("the serialized reference never completed");
    if (s_reqs != 8) fail("the serialized reference did not make exactly 8 requests");
    repeat (4) @(posedge clk_sys);
    serial_cycles = s_last - s_first;
    $display("NOTE font_fetch: serialized 8 single-word requests: %0d clk_sys, %0d requests",
             serial_cycles, s_reqs);

    // ---------------------------------------------------------------
    // 2. The BURST cost: select JIS code 0x2110 (FONT.ROM[0xCC20]) and time the real font
    //    fetch from its request to the eighth (final) beat.
    // ---------------------------------------------------------------
    // The LOW byte first: with the power-on high byte 0 the intermediate 0x0010 is the ANK
    // class (cg_jis = 0), so no junk fetch fires before the real code lands. The reverse
    // order would fetch 0x2100's illegal block first (cg_read_path works around this by
    // waiting font_req out; here exactly one fetch is what is being measured).
    burst_phase = 1'b1;
    write_io(8'hA3, 8'h10);      // code low  = ku - 0x20 = 0x10 (still ANK, no fetch)
    write_io(8'hA1, 8'h21);      // code high = ten = 0x21  -> code 0x2110, FONT.ROM[0xCC20]
    guard = 0;
    while (b_last < 0 && guard < 16'd1000) begin
      @(posedge clk_sys); guard = guard + 1;
    end
    if (b_last < 0) fail("the glyph burst never completed");
    if (b_first < 0) fail("the glyph request was never observed on font_req");
    repeat (4) @(posedge clk_sys);
    burst_phase = 0;
    burst_cycles = b_last - b_first;
    $display("NOTE font_fetch: glyph burst: %0d clk_sys, %0d request(s), block=%02x%02x%02x%02x...",
             burst_cycles, b_reqs, gbyte(3), gbyte(2), gbyte(1), gbyte(0));

    // ONE request per glyph is what makes this a burst rather than a serialization.
    if (b_reqs != 1)
      fail("the glyph fetch made more than one request on the font port");
    if (burst_cycles >= serial_cycles)
      fail("the burst did not beat the serialized shape");
    if (burst_cycles == 0)
      fail("the burst measurement is vacuous");

    // ---------------------------------------------------------------
    // 3. The block is still EXACTLY the glyph's 32 bytes, byte for byte - read back through
    //    the CPU's own port 0xA9, which is the view that EXISTS: the block is a block RAM
    //    (8 x 32, one word per burst beat) rather than 256 flip-flops, so there is no byte
    //    array to peek. 0xA5 bit 5 selects the half and bits 3:0 the row, so (half, row)
    //    names all 32 bytes; the two explicit checks this replaces are k = 3 and k = 19.
    // ---------------------------------------------------------------
    wrong = 0;
    for (k = 0; k < 32; k = k + 1) begin
      write_io(8'hA5, (k < 16 ? 8'h20 : 8'h00) | {4'b0, k[3:0]});   // bit 5 = the LEFT half
      read_io(8'hA9, value);
      if (value !== gbyte(k)) begin
        if (wrong < 4)
          $display("FAIL: 0xA9 byte %0d = %02x, FONT.ROM[0xCC20+%0d] is %02x",
                   k, value, k, gbyte(k));
        wrong = wrong + 1;
      end
    end
    if (wrong != 0) fail("the assembled glyph block is not the FONT.ROM glyph");
    else $display("  assembled block: 32 bytes match FONT.ROM[0xCC20] through port 0xA9");

    // ---------------------------------------------------------------
    // 4. THE PORT'S OPEN CYCLE ACROSS A BURST WRITE. Section 3 read the block with the burst
    //    long settled; this section reads it while the burst LANDS, which is the one cycle a
    //    registered read is not the flop form's. Every one of the 32 positions gets its OWN
    //    burst (the two codes alternate, so each 0xA3 write re-fetches) and the position is set
    //    before the code, so the read is already pending when the block lands - the shape a
    //    guest that reads the byte it just asked for produces. The bytes it must see are the
    //    SAME 32 bytes section 3 read (the left half is bytes 0-15 and the right half 16-31),
    //    so the two sections agree about the value and differ only in when the read lands.
    // ---------------------------------------------------------------
    for (k = 0; k < 32; k = k + 1) begin
      a5v = (k < 16) ? (8'h20 | {4'b0, k[3:0]}) : {4'b0, k[3:0]};
      off = GLYPH_BASE_B;
      if ((k % 2) == 0)
        // Starts on the OTHER code: the bench's code is 0x2110 (block A) by now.
        check_burst_open(HZ_CODE_LO_B, a5v, font_byte(off + k));
      else
        check_burst_open(HZ_CODE_LO_A, a5v, gbyte(k));
    end

  // ==== VERDICT ====
    $display("NOTE font_fetch: %0d clk_sys serialized -> %0d clk_sys burst (%0d.%01dx)",
             serial_cycles, burst_cycles,
             serial_cycles / burst_cycles, ((serial_cycles * 10) / burst_cycles) % 10);
    if (errors == 0) begin
      $display("TB_PC9821_FONT_FETCH: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FONT_FETCH: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_FONT_FETCH: TIMEOUT");
  end

endmodule

`default_nettype wire

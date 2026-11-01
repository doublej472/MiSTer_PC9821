`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FILL_BEAT_UNIFORM: every cache-line fill is FOUR WORD BEATS PRODUCED BY THE ROUTE, IN ORDER, AND A WALKING ROUTE STREAMS THEM THROUGH ITS WALK - for TRAM, the CG window, a GVRAM plane window, the PEGC register file and the absent C0000-D7FFF open bus the four beats at the subsystem's cpu_dout/cpu_resp_valid are diffed word-for-word against the bytes each route is known to hold, a walking route's line read must be accepted within three cycles of the request and its last beat must land inside the walk's own 48 cycles (the pre-P3 assemble-then-split form accepts after the walk and lands at 53, so it fails this while its bytes were identical), the map route is the control (four word beats out of the backend and no line form at all), and the captured fill replayed through the real l1_icache's line arm and beat arm installs byte-identical lines, so the L1 sees the same fill data either way, and the beat arm of the L1 replay is fed the four beats with 1-3-cycle GAPS (a window walk's cadence), so the L1's fill is proved not to need back-to-back beats.
//
// ---- where each expectation comes from ----
//  * THE BEAT ORDER is the caches' own: src/z486/l1_icache.sv's fill gathers beat N into
//    line word N (`patch_line_word(..., fill_count, ...)`), so line word N = the dword at the
//    line base + 4N, which is what each route's byte/column walk builds.
//  * THE ROUTES' EXPECTED BYTES are the bytes each backend holds: the TRAM array, the CG view's
//    own permutation {offset[0], offset[4:1]} (pc9821_window_responder's header: {page, row}),
//    the GVRAM plane bytes the bench stores, the PEGC register file's dword (pc9821_pegc's
//    header: "the same dword four times") and the open bus's 0xFF.
//  * THE ACCEPT AND STREAMING BOUNDS are the structural contract P3 created: a walking route
//    accepts a line read at the walk's start and strobes word N as its fourth byte/column lands.
//    The old form accepted after the walk and strobed once, so the same stimulus fails both.
//  * THE MAP ROUTE is the control: four word beats out of the backend, and no route-side line
//    machinery at all (its backend answers burstcount 4 as four beats).
//  * THE GVRAM PHASE runs with the PEGC view down and the PEGC phase with it up, because
//    pc9821_memory_map gates gvram_window on !pegc_256 and pegc_reg_win on pegc_256
//    (the two windows are never routed together on the machine either).

// ==== DUT ====
module tb_pc9821_fill_beat_uniform;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  reg [3:0] top_bank = 4'd8;
  reg ide_rom_enable = 0;
  reg ide_ram_gate = 1;
  reg bios_ram_gate = 0;
  reg top_shadow_en = 0;
  reg [7:0] win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  reg  sys16m_en = 1'b1;
  reg [31:0] pack_base = 32'h01F8_0000;
  reg [31:0] guest_ram_bytes = 32'h0200_0000;
  reg gvram_access_page = 0;

  reg        grcg_we = 0;
  reg [7:0]  grcg_addr = 0;
  reg [7:0]  grcg_din = 0;
  wire       grcg_expand;
  wire       grcg_expand_nx;   // mode[7]'s next state (opt-video VID-1); unused here


  reg        egc_enable = 0;
  reg [15:0] egc_access = 16'hFFF0;
  reg [15:0] egc_fgbg = 16'h00FF;
  reg [15:0] egc_ope = 16'h0000;
  reg [15:0] egc_fg = 16'h0000;
  reg [15:0] egc_mask = 16'hFFFF;
  reg [15:0] egc_bg = 16'h0000;
  reg [15:0] egc_sft = 16'h0000;
  reg [15:0] egc_leng = 16'h000F;
  reg        egc_shift_we = 1'b0;

  reg        ioctl_download = 0, ioctl_wr = 0;
  reg [15:0] ioctl_index = 0;
  reg [26:0] ioctl_addr = 0;
  reg [15:0] ioctl_dout = 0;
  wire       ioctl_wait, rom_ready, load_error, cpu_run;

  wire [10:0] font_addr;
  wire [15:0] font_data;
  wire        font_we;

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

  reg [31:0] cpu_addr = 0, cpu_din = 0;
  wire [31:0] cpu_dout;
  reg [3:0]  cpu_be = 4'hF;
  reg [7:0]  cpu_burstcount = 8'd1;
  reg        cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  wire       cpu_ready, cpu_resp_valid;

  // TRAM model: the GDC's dual-port byte RAM, registered like tb_pc9821_memory_subsystem's.
  wire [13:0] tram_addr;
  wire [7:0]  tram_din;
  wire        tram_we;
  reg  [7:0]  tram_dout = 0;
  reg  [7:0]  tram [0:16383];
  always @(posedge clk) begin
    if (tram_we) begin
      tram[tram_addr] <= tram_din;
      tram_dout <= tram_din;
    end else tram_dout <= tram[tram_addr];
  end

  // CG window model: the GDC's registered byte read (the answer is one cycle after byte_rd).
  wire [4:0] cg_win_byte_sel;
  wire       cg_win_rd;
  reg  [7:0] cg_win_dout = 0;
  wire [7:0] cg_win_din;
  wire       cg_win_we;
  wire       cg_win_byte_hold = 1'b0;
  reg  [7:0] cg_model [0:31];
  always @(posedge clk) if (cg_win_rd) cg_win_dout <= cg_model[cg_win_byte_sel];

  reg [18:0] font_req_addr = 0;
  reg        font_req = 0;
  wire       font_word_valid;
  wire [31:0] font_word_data;

  wire [31:0] fmem_addr, fmem_din;
  wire        fmem_valid, fmem_write;
  wire  [3:0] fmem_be;
  wire  [7:0] fmem_burstcount;
  reg         fmem_ready = 1, fmem_resp_valid = 0;
  reg  [31:0] fmem_dout = 32'd0;

  // The backend: the REAL response discipline (sdram_backend_model), with no line
  // producer - exactly what z486_mister.sv builds (LINE_RESP=0).
  wire [31:0] mem_addr, mem_din;
  wire  [3:0] mem_be;
  wire  [7:0] mem_burstcount;
  wire        mem_line_read, mem_valid, mem_write;
  wire        mem_ready, mem_resp_valid;
  wire [31:0] mem_dout;
  wire        mem_line_resp_valid;
  wire [127:0] mem_line_dout;
  wire [31:0] mem_din_hi;
  wire [31:0] be_accepts, be_beats;
  sdram_backend_model #(
      .ACCEPT_TO_RESP(5), .WRITE_BUSY(3), .LINE_RESP(0)
  ) be_model (
      .clk(clk), .reset(reset),
      .valid(mem_valid), .ready(mem_ready), .write(mem_write),
      .addr(mem_addr), .din(mem_din), .din_hi(mem_din_hi), .be(mem_be), .burstcount(mem_burstcount), .gath(mem_gath), .gath_extra(mem_gath_extra),
      .dout(mem_dout), .resp_valid(mem_resp_valid),
      .line_dout(mem_line_dout), .line_resp_valid(mem_line_resp_valid),
      .busy(), .accepts(be_accepts), .beats(be_beats)
  );

  wire [31:0] mem3_addr, mem3_din;
  wire  [3:0] mem3_be;
  wire  [7:0] mem3_burstcount;
  wire        mem3_valid, mem3_write;
  reg  [31:0] mem3_dout = 32'h0;
  reg         mem3_ready = 1, mem3_resp_valid = 0;

  wire [1:0] ems_state;
  wire [127:0] dbg_gfx_stats;
  wire dbg_walk_start, dbg_walk_cycle;
  wire dbg_egc_txn, dbg_egc_unit, dbg_grcg_store;
  wire dbg_gr_owned, dbg_eg_owned;
  wire dbg_access_page, dbg_scan_page_q;
  wire gfx_odd_line = 1'b0;
/* verilator lint_off UNUSEDSIGNAL */
  wire        dma_addr_unused = 1'b0;
  wire [31:0] dma_addr = 32'd0;
  wire [1:0]  dma_gvwin = 2'b00;   // the DMAC's plane-window class of dma_addr (idle here)
  wire [31:0] dma_din  = 32'd0;
  wire  [3:0] dma_be   = 4'd0;
  wire        dma_valid = 1'b0;
  wire        dma_write = 1'b0;
  wire        dma_ready, dma_resp_valid;
  wire [31:0] dma_dout;
/* verilator lint_on UNUSEDSIGNAL */
  wire        gdc_mem_valid = 1'b0;
  wire        gdc_mem_write = 1'b0;
  wire        gdc_mem_route_egc = 1'b0;
  wire        gdc_mem_route_grcg = 1'b0;
  wire        gdc_mem_page = 1'b0;
  wire  [1:0] gdc_mem_plane = 2'd0;
  wire [14:0] gdc_mem_offset = 15'd0;
  wire [31:0] gdc_mem_din = 32'd0;
  wire  [3:0] gdc_mem_be = 4'd0;
  wire        gdc_mem_ready;
  wire        gdc_mem_resp;
  wire [31:0] gdc_mem_rdata;
  reg         pegc_256 = 1'b0;
  wire        pegc_256e = 1'b0;
  wire  [2:0] scan_dot = 3'b0;
  // scan_dot_ce/act: the packed scanout added these to the subsystem's port
  // list; this bench runs with the scanout inert (scan_enable=0, pegc_256=0), so
  // the house tie-off (tb_pc9821_egc, tb_pc9821_gvram_fill) is equivalent either
  // way and only exists so `.*` binds.
  wire        scan_dot_ce = 1'b0;
  wire        scan_dot_act = 1'b1;
  wire  [7:0] peg_packed_idx;
  wire        peg_line_sel, peg_line_ready;
  wire [31:0] pmem_addr, pmem_din;
  wire        pmem_valid, pmem_write;
  wire  [3:0] pmem_be;
  wire  [7:0] pmem_burstcount;
  wire        pmem_ready = 1'b1;
  wire [31:0] pmem_dout = 32'b0;
  wire        pmem_resp_valid = 1'b0;

  // The G3 gather session's qualifier/entries and the SDRAM geometry
  // (pc9821_memory_subsystem's ports; (.*) binds them by name).
  wire        mem_gath;
  wire [440:0] mem_gath_extra;
  wire  [1:0] sdram_size = 2'd2;
  // The plain-window client's ownership pulse (pc9821_memory_subsystem's dbg_pw_owned,
  // added 2026-10-03 so the page-coincidence counter covers plain stores too). `.*` needs a
  // matching net here; this bench does not read it.
  wire dbg_pw_owned;

  // 0x063C bank select into the 0xD8000 window: 0 = the IDE option ROM, the reset bank.

  reg  [1:0] d8_bank = 2'b00;

  pc9821_memory_subsystem #(.SYS_CLOCK_HZ(100_000_000)) dut (.*);

  // ==== STIMULUS ====
  integer errors = 0;
  integer tb_cycle = 0;
  always @(posedge clk) tb_cycle = tb_cycle + 1;

  localparam integer BUDGET = 4000;

  // A hard watchdog, so a hang anywhere in the stimulus is a failure not a stall.
  initial begin
    #20_000_000;
    $display("FAIL watchdog: the run did not finish (tb_cycle=%0d)", tb_cycle);
    $fatal(1, "TB_PC9821_FILL_BEAT_UNIFORM: FAIL watchdog");
  end

  task do_reset;
    begin
      reset = 1;
      repeat (8) @(posedge clk);
      reset = 0;
      repeat (4) @(posedge clk);
    end
  endtask

  // Load a minimal pack so rom_ready and cpu_run come up (the subsystem holds the
  // CPU until a pack has loaded), the same shape tb_pc9821_gvram_fill uses.
  task load_rom;
    begin
      ioctl_download = 1;
      ioctl_addr = 27'd0;
      ioctl_dout = 16'hBEEF;
      ioctl_wr = 1;
      @(posedge clk);
      ioctl_wr = 0;
      repeat (2) @(posedge clk);
      ioctl_download = 0;
      repeat (4) @(posedge clk);
      if (!rom_ready || !cpu_run) begin
        $display("FAIL rom: ready=%b run=%b load_error=%b", rom_ready, cpu_run, load_error);
        errors = errors + 1;
      end
    end
  endtask

  // One CPU store, the tb_pc9821_gvram_fill discipline (a store completes on ready) -
  // with the request held through the accept CYCLE's posedge, the valid-hold contract
  // (pc9821_pegc.sv: "the write lands on the accept edge, while the requester still
  // holds the request"; z486 holds ext_*_r until the ready edge). Dropping it at the
  // ready cycle's own negedge mis-times the accept-edge sampling: pc9821_pegc_storebuf's
  // frozen passthrough re-derives mem_write from the live input at the ack, and the
  // response-route queue then counts the store as a read (measured before this fix:
  // rt_wr=3 rt_rd=0 after three stores, the fourth refused forever).
  task automatic cpu_store(input [31:0] a, input [31:0] d, input [3:0] be);
    integer guard;
    begin
      cpu_addr  = a;
      cpu_din   = d;
      cpu_be    = be;
      cpu_write = 1;
      cpu_line_read = 0;
      cpu_burstcount = 8'd1;
      cpu_valid = 1;
      guard = 0;
      while (!cpu_ready && guard < BUDGET) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (!cpu_ready)
        $fatal(1, "TB_PC9821_FILL_BEAT_UNIFORM: FAIL no accept for store %08x", a);
      @(negedge clk);   // past the accept edge, which samples the held request
      cpu_valid = 0;
      cpu_write = 0;
      @(negedge clk);
    end
  endtask

  // One CACHE-LINE READ (burstcount 4 with line_read - the shape memory.sv's line_read
  // term builds) to `addr`, answered by the four word beats the L1 consumes.
  //   beats[0..3]  the word beats at the boundary (what the L1 sees),
  //   acc_cycles   cycles from the request being presented to its accept,
  //   last_cycles  cycles from the request to the fourth beat.
  // Aborts on a timeout, which is also the pre-P3 form's failure on a hang.
  reg  [31:0] beats [0:3];
  integer     beat_n;
  integer     acc_cycles, last_cycles;

  task automatic line_fill(input [31:0] a);
    integer guard;
    begin
      beat_n = 0;
      acc_cycles = 0;
      last_cycles = 0;
      cpu_addr  = a;
      cpu_din   = 32'd0;
      cpu_be    = 4'hF;
      cpu_write = 0;
      cpu_line_read = 1;
      cpu_burstcount = 8'd4;
      cpu_valid = 1;
      guard = 0;
      while (!cpu_ready && guard < BUDGET) begin
        @(negedge clk);
        guard = guard + 1;
        acc_cycles = acc_cycles + 1;
      end
      if (!cpu_ready) $fatal(1, "TB_PC9821_FILL_BEAT_UNIFORM: FAIL no accept for line read %08x", a);
      @(negedge clk);
      cpu_valid = 0;
      cpu_line_read = 0;
      guard = 0;
      while (beat_n < 4 && guard < BUDGET) begin
        if (cpu_resp_valid) begin
          beats[beat_n] = cpu_dout;
          beat_n = beat_n + 1;
          last_cycles = acc_cycles + guard + 1;
        end
        @(negedge clk);
        guard = guard + 1;
      end
      if (beat_n != 4)
        $fatal(1, "TB_PC9821_FILL_BEAT_UNIFORM: FAIL %08x answered with %0d word beats (of 4) - a route that suppresses the word form hangs the L1 fill", a, beat_n);
    end
  endtask

  // ==== CHECKS ====

  // The whole proof, per route: the four beats are the bytes the route is known to hold, byte
  // for byte, and a WALKING route additionally owes P3's streaming contract - accepted within
  // three cycles of the request, last beat no later than the walk's own last byte + 1. The
  // constant routes (open bus, PEGC regs) and the map's backend keep their own cadence, so only
  // their bytes are asserted.
  task automatic check_fill(input [8*12-1:0] name, input [31:0] a,
                            input [31:0] w0, input [31:0] w1,
                            input [31:0] w2, input [31:0] w3,
                            input walking);
    integer g;
    begin
      line_fill(a);
      if (beats[0] !== w0 || beats[1] !== w1 || beats[2] !== w2 || beats[3] !== w3) begin
        $display("FAIL %0s: beats %08x %08x %08x %08x, want %08x %08x %08x %08x",
                 name, beats[0], beats[1], beats[2], beats[3], w0, w1, w2, w3);
        errors = errors + 1;
      end
      if (walking) begin
        // P3's contract: the accept precedes the walk. The pre-P3 form accepted a window line
        // read at the walk's end (48 cycles for TRAM, one GVRAM column period per column).
        if (acc_cycles > 3) begin
          $display("FAIL %0s: a line read was accepted %0d cycles after it was presented - a walking route accepts at the walk's start", name, acc_cycles);
          errors = errors + 1;
        end
        // ... and the beats stream through it: the TRAM walk is 16 three-cycle byte reads, so
        // its last beat lands at cycle 49; the post-walk split form lands at 53.
        if (name == "tram" && (last_cycles < 45 || last_cycles > 49)) begin
          $display("FAIL %0s: the last beat landed %0d cycles after the request, outside the streaming window 45..49 (the walk is 48 cycles; the post-walk split form lands at 53)", name, last_cycles);
          errors = errors + 1;
        end
      end
      // No fifth beat: the fill owes exactly four words.
      g = 0;
      while (g < 12) begin
        if (cpu_resp_valid) begin
          $display("FAIL %0s: a fifth word beat after the four", name);
          errors = errors + 1;
        end
        @(negedge clk);
        g = g + 1;
      end
    end
  endtask

  // ---- the L1 replay: the same captured fill through the real l1_icache TWICE, once as the
  // ---- 128-bit line form and once as the four word beats, and the installed lines diffed. The
  // ---- rewritten leaf has ONE fill datapath (the rebase dropped the BEAT/BOTH/LINE FILL_MODE
  // ---- selector), so the two instances differ only in which response form this bench drives
  // ---- into them - which is exactly the property worth pinning: the datapath must install the
  // ---- same line from either form.
  reg  [31:0] ic_addr = 32'd0;
  reg         ic_valid = 1'b0;
  wire        ic_l_ready, ic_l_resp;
  wire [127:0] ic_l_line;
  wire [31:0] ic_l_maddr;
  wire  [3:0] ic_l_mbe;
  wire  [7:0] ic_l_mburst;
  wire        ic_l_mvalid;
  wire        ic_b_ready, ic_b_resp;
  wire [127:0] ic_b_line;
  wire [31:0] ic_b_maddr;
  wire  [3:0] ic_b_mbe;
  wire  [7:0] ic_b_mburst;
  wire        ic_b_mvalid;

  reg         ic_l_lresp = 1'b0;
  reg [127:0] ic_l_ldata = 128'd0;
  reg         ic_b_resp_v = 1'b0;
  reg  [31:0] ic_b_data = 32'd0;

  l1_icache #(.SET_BITS(4)) ic_line_arm (
      .clk(clk), .reset(reset),
      .cpu_addr(ic_addr), .cpu_line(ic_l_line), .cpu_valid(ic_valid),
      .cpu_no_alloc(1'b0), .cpu_ready(ic_l_ready), .cpu_resp_valid(ic_l_resp),
      .mem_addr(ic_l_maddr), .mem_dout(32'd0), .mem_line_dout(ic_l_ldata),
      .mem_be(ic_l_mbe), .mem_burstcount(ic_l_mburst), .mem_busy(1'b0),
      .mem_valid(ic_l_mvalid), .mem_ready(ic_l_mvalid),
      .mem_resp_valid(1'b0), .mem_line_resp_valid(ic_l_lresp),
      .patch_addr(32'd0), .patch_data(32'd0), .patch_be(4'd0), .patch_valid(1'b0),
      .invalidate_addr(32'd0), .invalidate_valid(1'b0),
      .flush_req(1'b0), .flush_busy(), .flush_done(),
      .cache_enable(1'b1)
  );

  l1_icache #(.SET_BITS(4)) ic_beat_arm (
      .clk(clk), .reset(reset),
      .cpu_addr(ic_addr), .cpu_line(ic_b_line), .cpu_valid(ic_valid),
      .cpu_no_alloc(1'b0), .cpu_ready(ic_b_ready), .cpu_resp_valid(ic_b_resp),
      .mem_addr(ic_b_maddr), .mem_dout(ic_b_data), .mem_line_dout(128'd0),
      .mem_be(ic_b_mbe), .mem_burstcount(ic_b_mburst), .mem_busy(1'b0),
      .mem_valid(ic_b_mvalid), .mem_ready(ic_b_mvalid),
      .mem_resp_valid(ic_b_resp_v), .mem_line_resp_valid(1'b0),
      .patch_addr(32'd0), .patch_data(32'd0), .patch_be(4'd0), .patch_valid(1'b0),
      .invalidate_addr(32'd0), .invalidate_valid(1'b0),
      .flush_req(1'b0), .flush_busy(), .flush_done(),
      .cache_enable(1'b1)
  );

  // Fill both arms from the captured fill: the line arm takes the four captured beats
  // assembled as a 128-bit line (line word N = beat N, the caches' own convention) in one
  // strobe, the beat arm takes the captured beats WITH GAPS (1-3 idle cycles apart, a window
  // walk's cadence, never back-to-back) - the same fill both ways -
  // then each arm answers a read of the filled line and the two answers must be
  // byte-identical: the line form and the beat form are the same fill. (The true expected
  // bytes are asserted against the route's own data in check_fill above; this replay proves
  // the L1 datapath consumes the beat stream into the same line.) The two arms complete on
  // DIFFERENT cycles (the line arm at its strobe, the beat arm at its fourth beat), so each
  // completion is captured as it lands.
  task automatic l1_replay_diff(input [31:0] a);
    integer n, guard;
    reg [127:0] ln, bt;
    reg got_l, got_b;
    begin
      ic_addr = a;
      ic_valid = 1;
      guard = 0;
      while (!(ic_l_ready && ic_b_ready) && guard < BUDGET) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (!(ic_l_ready && ic_b_ready))
        $fatal(1, "TB_PC9821_FILL_BEAT_UNIFORM: FAIL l1 arms did not accept the fill request");
      @(negedge clk);
      ic_valid = 0;
      // Both arms issue their fill request; the bench accepts it in the cycle
      // mem_valid is seen (mem_ready = mem_valid) and delivers the fill right
      // behind the accept - the responders' own accept-then-respond shape.
      guard = 0;
      while (!(ic_l_mvalid && ic_b_mvalid) && guard < BUDGET) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (!(ic_l_mvalid && ic_b_mvalid))
        $fatal(1, "TB_PC9821_FILL_BEAT_UNIFORM: FAIL l1 arms did not launch their fills");
      @(negedge clk);   // the accept cycle ends here; deliver behind it
      got_l = 0; got_b = 0;
      ic_l_ldata = {beats[3], beats[2], beats[1], beats[0]};
      ic_b_data  = beats[0];
      ic_l_lresp = 1'b1;
      ic_b_resp_v = 1'b1;
      @(negedge clk);
      ic_l_lresp = 1'b0;
      if (ic_l_resp) begin ln = ic_l_line; got_l = 1'b1; end
      if (ic_b_resp) begin bt = ic_b_line; got_b = 1'b1; end
      for (n = 1; n < 4; n = n + 1) begin
        // THE BEATS ARE NOT BACK-TO-BACK ON A REAL WINDOW FILL: the route strobes one word per
        // four walk steps, so deliver beat n after n idle cycles. z486's L1 gathers beat N into
        // line word N and needs no adjacency; this drives that (the study names it as the
        // assumption the change rests on).
        ic_b_resp_v = 1'b0;
        repeat (n) @(negedge clk);
        ic_b_data = beats[n];
        ic_b_resp_v = 1'b1;
        @(negedge clk);
        if (ic_l_resp) begin ln = ic_l_line; got_l = 1'b1; end
        if (ic_b_resp) begin bt = ic_b_line; got_b = 1'b1; end
      end
      ic_b_resp_v = 1'b0;
      guard = 0;
      while (!(got_l && got_b) && guard < BUDGET) begin
        @(negedge clk);
        if (ic_l_resp) begin ln = ic_l_line; got_l = 1'b1; end
        if (ic_b_resp) begin bt = ic_b_line; got_b = 1'b1; end
        guard = guard + 1;
      end
      if (!(got_l && got_b))
        $fatal(1, "TB_PC9821_FILL_BEAT_UNIFORM: FAIL l1 arms did not complete their fills (line=%b beat=%b)", got_l, got_b);
      // Past the fill-completion pulses, a hit read-back of the filled line.
      @(negedge clk);
      @(negedge clk);
      ic_addr = a + 32'd4;
      ic_valid = 1;
      got_l = 0; got_b = 0;
      guard = 0;
      while (!(got_l && got_b) && guard < BUDGET) begin
        @(negedge clk);
        if (ic_l_resp) begin ln = ic_l_line; got_l = 1'b1; end
        if (ic_b_resp) begin bt = ic_b_line; got_b = 1'b1; end
        guard = guard + 1;
      end
      ic_valid = 0;
      if (!(got_l && got_b)) begin
        $display("FAIL l1 replay: hit read-back incomplete (line=%b beat=%b)", got_l, got_b);
        errors = errors + 1;
      end
      @(negedge clk);
      if (ln !== bt) begin
        $display("FAIL l1 replay: the line arm installed %032x, the beat arm %032x - the L1 did NOT see the same fill data either way", ln, bt);
        errors = errors + 1;
      end
      if (ln !== {beats[3], beats[2], beats[1], beats[0]}) begin
        $display("FAIL l1 replay: the installed line %032x is not the captured beats %032x",
                 ln, {beats[3], beats[2], beats[1], beats[0]});
        errors = errors + 1;
      end
    end
  endtask

  integer i;
  reg [31:0] g0, g1, g2, g3;

  initial begin
    do_reset;
    load_rom;

    // ---- TRAM (0xA0000): 16 known bytes in the code plane ----
    for (i = 0; i < 16; i = i + 1) tram[i] = 8'h10 + i[7:0];
    check_fill("tram", 32'h000A_0000,
               32'h1312_1110, 32'h1716_1514, 32'h1B1A_1918, 32'h1F1E_1D1C, 1'b1);

    // ---- CG window (0xA4000): byte i of the view is cg_model[{i[0], i[4:1]}] ----
    for (i = 0; i < 32; i = i + 1) cg_model[i] = 8'h40 + i[7:0];
    g0 = 32'h0; g1 = 32'h0; g2 = 32'h0; g3 = 32'h0;
    for (i = 0; i < 16; i = i + 1) begin
      case (i[3:2])
        2'd0: g0[(i%4)*8 +: 8] = cg_model[{i[0], i[4:1]}];
        2'd1: g1[(i%4)*8 +: 8] = cg_model[{i[0], i[4:1]}];
        2'd2: g2[(i%4)*8 +: 8] = cg_model[{i[0], i[4:1]}];
        2'd3: g3[(i%4)*8 +: 8] = cg_model[{i[0], i[4:1]}];
      endcase
    end
    check_fill("cg-window", 32'h000A_4000, g0, g1, g2, g3, 1'b1);

    // ---- GVRAM plane 0 (0xA8000): four dword stores fill the line's four dwords,
    // ---- one column byte per byte lane (pc9821_gvram_arb's plain path) ----
    cpu_store(32'h000A_8000, 32'h4433_2211, 4'hF);
    cpu_store(32'h000A_8004, 32'h8877_6655, 4'hF);
    cpu_store(32'h000A_8008, 32'hCCBB_AA99, 4'hF);
    cpu_store(32'h000A_800C, 32'h00FF_EEDD, 4'hF);
    repeat (16) @(negedge clk);   // the stores' array walks land behind their accepts
    check_fill("gvram", 32'h000A_8000,
               32'h4433_2211, 32'h8877_6655, 32'hCCBB_AA99, 32'h00FF_EEDD, 1'b1);

    // ---- open bus (the absent 0xC0000-0xD7FFF): four all-ones words ----
    check_fill("open-bus", 32'h000C_0000,
               32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 1'b0);

    // ---- the MAP ROUTE control (0x20000, ordinary guest RAM): four word beats
    // ---- out of the backend and NO line form at all (r11 section 4.1) ----
    cpu_store(32'h0002_0000, 32'h1122_3344, 4'hF);
    cpu_store(32'h0002_0004, 32'h5566_7788, 4'hF);
    cpu_store(32'h0002_0008, 32'h99AA_BBCC, 4'hF);
    cpu_store(32'h0002_000C, 32'hDDEE_FF00, 4'hF);
    repeat (8) @(negedge clk);
    check_fill("map-route", 32'h0002_0000,
               32'h1122_3344, 32'h5566_7788, 32'h99AA_BBCC, 32'hDDEE_FF00, 1'b0);

    // ---- PEGC register file (0xE0100), the view up: "the same dword four times"
    // ---- (pc9821_pegc's header), now four beats of that dword. 0xE0100 lane 0
    // ---- stores bit 0 only (NP2kai memvgaio_wr8), so 0x5A55FF01 round-trips.
    pegc_256 = 1'b1;
    repeat (2) @(negedge clk);
    cpu_store(32'h000E_0100, 32'h5A55_FF01, 4'hF);
    check_fill("pegc-regs", 32'h000E_0100,
               32'h5A55_FF01, 32'h5A55_FF01, 32'h5A55_FF01, 32'h5A55_FF01, 1'b0);
    pegc_256 = 1'b0;
    repeat (2) @(negedge clk);

    // ---- THE L1 REPLAY: one captured fill (the TRAM one) both ways through the
    // ---- real l1_icache ----
    line_fill(32'h000A_0000);
    l1_replay_diff(32'h000A_0000);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_FILL_BEAT_UNIFORM: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FILL_BEAT_UNIFORM: FAIL (%0d errors)", errors);
  end

endmodule

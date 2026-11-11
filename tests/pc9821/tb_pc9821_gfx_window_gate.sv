`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GFX_WINDOW_GATE: the GRCG/EGC engines' cpu_valid is gated by PLANE-WINDOW MEMBERSHIP, not only by the mode/direction owner decode. With GRCG mode bit 7 armed (0x7C = 0x80), an ordinary CPU access OUTSIDE the plane windows (a 0x0000_1000 RAM store and a 0x0000_1000 RAM read) must NOT be captured as a GRCG op: no dbg_grcg_store pulse, no grcg_cl_valid, no GVRAM array write (the phantom TDW/RMW walk into (addr & 0x7FFF)), and the read must return the RAM backend's own data (a pattern from a behavioural backend answering 20 clk_sys after the accept) with NO early cpu_resp_valid carrying TCR garbage and exactly ONE response strobe (the pre-fix steal also left a spurious second strobe when the map's real response landed). The same pair runs with the EGC gate on (egc_enable), whose owner decode is a pure direction term: no dbg_egc_txn / egc_cl_valid / busy cycles for a RAM access. The plane-window case is the positive control and must be unchanged: an armed store to 0xA8000 still captures exactly once and lands the tile bytes in the array, and a TCR read of 0xA8000 still answers 0x0000_00FF (the tile-compare match byte) on the engine's own strobe with no backend traffic. FAIL-FIRST: on the pre-fix pc9821_memory_subsystem (the engines' cpu_valid gated by gvram_own_{grcg,egc} alone) sections 1/2/5/6 fail by name; the fix ANDs gvram_select into those two gates and every section passes.
//
// TB_PC9821_GFX_WINDOW_GATE: the GRCG/EGC engines' cpu_valid is gated by PLANE-WINDOW
// MEMBERSHIP, not only by the mode/direction owner decode. With GRCG mode bit 7 armed
// (0x7C = 0x80), an ordinary CPU access OUTSIDE the plane windows (0x0000_1000 RAM) must
// NOT be captured as a GRCG op: the store must produce no dbg_grcg_store pulse and no
// GVRAM array write (the phantom TDW/RMW walk into (addr & 0x7FFF)),
// and the read must come back from the RAM backend and NOT as an early cpu_resp_valid
// carrying TCR garbage (which also left a spurious second strobe when the map's real
// response landed). The same pair is asserted with the EGC gate on (egc_enable): the EGC's
// pure direction decode (cc_owns_egc) must not capture a RAM access either. The
// plane-window case is the POSITIVE control and must be unchanged on both trees: an armed
// store to 0xA8000 still captures (one dbg_grcg_store, tile bytes land in the array) and a
// TCR read of 0xA8000 still answers with the tile-compare byte on its own response strobe.
// FAIL-FIRST: on the pre-fix pc9821_memory_subsystem (the engines' cpu_valid gated by
// gvram_own_* alone) sections 1/2/5/6 fail by name; the fix ANDs gvram_select into those
// two gates and every section passes.

module tb_pc9821_gfx_window_gate;
  // pc9821_memory_subsystem's pack-download hold: no boot-ROM download under the OSD Reset
  // level here (tb_pc9821_boot0_load drives that), so the level is low and the hold unread.
  wire hps_apply_reset = 1'b0;
  wire pack_load_hold;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg [3:0] top_bank = 4'd8;
  reg [1:0] ems_state = 2'd0;
  reg ide_rom_enable = 0;
  reg        ide_ram_gate = 1;
    // 0x1E8E's IDE work-RAM gate: held ON so nothing here sees the gated
    // shape - tb_pc9821_memory_subsystem and tb_pc9821_memory_map pin it.
  reg bios_ram_gate = 0;
  reg top_shadow_en = 0;
  reg  soft_reboot = 1'b0;   // no reboot strobe in this bench
  reg [7:0] win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  reg  sys16m_en = 1'b1;
  reg [31:0] pack_base = 32'h01F8_0000;
  reg [31:0] guest_ram_bytes = 32'h0200_0000;
  reg gvram_access_page = 0;
  reg        egc_enable = 1'b0;
  reg [15:0] egc_access = 16'hFFF0;
  reg [15:0] egc_fgbg = 16'h00FF;
  reg [15:0] egc_ope = 16'h0000;
  reg [15:0] egc_fg = 16'h0000;
  reg [15:0] egc_mask = 16'hFFFF;
  reg [15:0] egc_bg = 16'h0000;
  reg [15:0] egc_sft = 16'h0000;
  reg [15:0] egc_leng = 16'h000F;
  reg        egc_shift_we = 1'b0;
  reg ioctl_download = 0, ioctl_wr = 0;
  reg [15:0] ioctl_index = 0;
  reg [26:0] ioctl_addr = 0;
  reg [15:0] ioctl_dout = 0;
  wire ioctl_wait, rom_ready, load_error, cpu_run;
  wire [17:0] font_addr;
  wire [15:0] font_data;
  wire font_we;

  reg [31:0] cpu_addr = 0, cpu_din = 0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  reg [3:0] cpu_be = 4'hF;
  reg [7:0] cpu_burstcount = 1;
  reg cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  wire cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  wire [13:0] tram_addr;
  wire [7:0] tram_din;
  wire tram_we;
  reg [7:0] tram_dout = 0;
  wire [4:0] cg_win_byte_sel;
  wire cg_win_rd;
  reg [7:0] cg_win_dout = 0;
  wire [7:0] cg_win_din;
  wire cg_win_we;
  reg cg_win_byte_hold = 0;
  reg [18:0] font_req_addr = 0;
  reg font_req = 0;
  wire font_word_valid;
  wire [31:0] font_word_data;
  wire [31:0] fmem_addr, fmem_din;
  wire fmem_valid, fmem_write;
  wire [3:0] fmem_be;
  wire [7:0] fmem_burstcount;
  reg fmem_ready = 1, fmem_resp_valid = 0;
  reg [31:0] fmem_dout = 32'd0;

  wire [31:0] mem_addr, mem_din, mem_din_hi;
  wire [3:0] mem_be;
  wire [7:0] mem_burstcount;
  wire mem_valid, mem_write;
  wire mem_ready = 1'b1;

  // ==== DUT ====
  reg        grcg_we = 0;
  reg  [7:0] grcg_addr = 0;
  reg  [7:0] grcg_din = 0;
  wire       grcg_expand;
  wire       grcg_expand_nx;   // mode[7]'s next state (opt-video VID-1); unused here

  reg        scan_enable = 0;

  reg        gvram_timing_xe10 = 0, gvram_gfx_scan_on = 0;   // OSD I/O timing Fast
  reg        scan_line_tick = 0;
  reg        scan_page = 0;
  reg        scan_walk_page = 0;
  reg [14:0] scan_line_base = 0;
  reg  [6:0] line_rd_addr = 0;
  reg        line_rd_sel = 0;
  wire [31:0] line_data;
  wire        line_sel;
  wire        line_ready;
  wire [127:0] dbg_gfx_stats;
  wire dbg_walk_start, dbg_walk_cycle;
  wire dbg_egc_txn, dbg_egc_unit, dbg_grcg_store;
  wire dbg_gr_owned, dbg_eg_owned;
  wire dbg_access_page, dbg_scan_page_q;

  // ==== THE BEHAVIOURAL BACKEND ====
  // Accepts every request with mem_ready tied high (the shape tb_pc9821_memory_subsystem
  // already pins as one accept per request) and answers a READ RESP_LAT cycles later with
  // a pattern derived from its address, so a response strobe that carries anything else
  // was not this read's data. RESP_LAT is deliberately longer than a GRCG/EGC phantom
  // walk (~4-8 clk_sys): the engine's TCR strobe then arrives BEFORE the real response,
  // which is the ordering the F1 steal needs and what `early_resp` counts.
  localparam integer RESP_LAT = 20;
  function automatic [31:0] ram_pattern(input [31:0] a);
    ram_pattern = 32'hC0DE_0000 | (a & 32'h0000_FFFF);
  endfunction
  reg  [7:0] rd_delay = 8'd0;
  reg  [7:0] rd_beats = 8'd0;
  reg [31:0] rd_addr_q = 32'd0;
  reg [31:0] mem_dout = 32'd0;
  reg        mem_resp_valid = 0;
  always @(posedge clk) begin
    mem_resp_valid <= 1'b0;
    if (rd_beats != 8'd0 && rd_delay == 8'd0) begin
      mem_resp_valid <= 1'b1;
      mem_dout       <= ram_pattern(rd_addr_q);
      rd_addr_q      <= rd_addr_q + 32'd4;
      rd_beats       <= rd_beats - 8'd1;
    end else if (rd_delay != 8'd0) begin
      rd_delay <= rd_delay - 8'd1;
    end else if (mem_valid && mem_ready && !mem_write) begin
      rd_addr_q <= mem_addr;
      rd_beats  <= mem_burstcount;
      rd_delay  <= RESP_LAT[7:0];
    end
  end

  // Tied off: the 200-line interleave's odd-line fetch-skip input (400-line traffic
  // here; tb_pc9821_interleave_200 drives it).
  wire gfx_odd_line = 1'b0;
  // ---- pc9821_memory_subsystem's DMA bus-master port, tied off (see the iobus block) ----
/* verilator lint_off UNUSEDSIGNAL */
  wire        dma_addr_unused = 1'b0;
  wire [31:0] dma_addr = 32'd0;
  wire [31:0] dma_snoop_addr;   // the DMA byte's post-map name, for the external snoop (unused here)
  wire [31:0] dma_addr_nx = 32'd0;   // the DMAC's address load (idle here)
  wire        dma_load    = 1'b0;
  wire [31:0] dma_din  = 32'd0;
  wire [3:0]  dma_be   = 4'd0;
  wire        dma_valid = 1'b0;
  wire        dma_write = 1'b0;
  wire        dma_ready, dma_resp_valid;
  wire [31:0] dma_dout;
/* verilator lint_on UNUSEDSIGNAL */
  // The GDC draw engine's visit (the GDC2 WRITE slice) is not this bench's subject: tied
  // off, so the CPU side permanently owns the GVRAM port share.
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
  // The PEGC view select (pc9821_crtc's mode2_256col, pegc-scope-REPORT.md 4 row 2):
  // 0 = the pre-PEGC decode this bench drives; the PEGC arms are tb_pc9821_memmap_ref's.
  wire pegc_256 = 1'b0;
  // PEGC packed scanout's fourth-requester port (pegc-scope-REPORT.md 4 rows 3/6),
  // tied off: pegc_256 is 0 here, so the packed fetch never runs and the fourth
  // SDRAM requester stays idle (tb_pc9821_pegc_scanout drives this path).
  wire pegc_256e = 1'b0;
  wire [2:0] scan_dot = 3'b0;
  wire [7:0] peg_packed_idx;
  wire peg_line_sel, peg_line_ready;
  wire [31:0] pmem_addr, pmem_din;
  wire pmem_valid, pmem_write;
  wire  [3:0] pmem_be;
  wire  [7:0] pmem_burstcount;
  wire pmem_ready = 1'b1;
  wire [31:0] pmem_dout = 32'b0;
  wire pmem_resp_valid = 1'b0;
  // Not the packed dot phase's subject here: the one-clk-early address is inert
  // (tb_pc9821_pegc_scan_dot owns it).
  wire scan_dot_ce = 1'b0;
  wire scan_dot_act = 1'b1;

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
  // The 16-colour select (port 0x6A FF2 num 0): 0 = the digital mode the machine resets to,
  // where 0xE0000-0xE7FFF is open bus (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b0;

  pc9821_memory_subsystem #(.SYS_CLOCK_HZ(100_000_000)) dut (.*);

  // ==== MONITORS ====
  // Everything a phantom capture leaves behind: the engine's capture pulses, the engine
  // busy/valid levels, the array's port-A writes (the phantom TDW/RMW walk's proof) and
  // every CPU response strobe with the data it carried and whether the map route's own
  // response had already been delivered (`map_resp_seen` is set by mem_resp_valid BEFORE
  // the strobe check runs, so the map's own coincident strobe is not counted early).
  integer errors = 0;
  integer grcg_store_pulses = 0, egc_txn_pulses = 0;
  integer gmem_writes = 0, grcg_cl_cycles = 0, egc_cl_cycles = 0;
  integer grcg_busy_cycles = 0, egc_busy_cycles = 0;
  integer ram_writes = 0, reads_accepted = 0;
  integer resp_count = 0, early_resp = 0;
  reg [31:0] first_resp_data = 32'hDEAD_DEAD;
  reg        map_resp_seen = 0;
  always @(posedge clk) begin
    if (dbg_grcg_store) grcg_store_pulses = grcg_store_pulses + 1;
    if (dbg_egc_txn)    egc_txn_pulses    = egc_txn_pulses    + 1;
    if (dut.u_gmem.a_en && dut.u_gmem.a_we) gmem_writes = gmem_writes + 1;
    if (dut.u_gvram_arb.grcg_cl_valid) grcg_cl_cycles = grcg_cl_cycles + 1;   // the arbiter's rebuilt cl_valid
    if (dut.egc_cl_valid)  egc_cl_cycles  = egc_cl_cycles  + 1;
    if (dut.grcg_dbg_busy) grcg_busy_cycles = grcg_busy_cycles + 1;
    if (dut.egc_dbg_busy)  egc_busy_cycles  = egc_busy_cycles  + 1;
    if (mem_valid && mem_ready &&  mem_write) ram_writes      = ram_writes      + 1;
    if (mem_valid && mem_ready && !mem_write) reads_accepted  = reads_accepted  + 1;
    if (mem_resp_valid) map_resp_seen = 1'b1;
    if (cpu_resp_valid) begin
      if (resp_count == 0) first_resp_data = cpu_dout;
      if (!map_resp_seen) early_resp = early_resp + 1;
      resp_count = resp_count + 1;
    end
  end

  // ==== STIMULUS ====
  integer guard;
  task automatic check_eq(input string what, input integer got, input integer want);
    begin
      if (got !== want) begin
        $display("FAIL %s: got %0d, want %0d", what, got, want);
        errors = errors + 1;
      end
    end
  endtask

  task automatic check_word(input string what, input [31:0] got, input [31:0] want);
    begin
      if (got !== want) begin
        $display("FAIL %s: got %08x, want %08x", what, got, want);
        errors = errors + 1;
      end
    end
  endtask

  // The GVRAM engines and the array walk drained, so a decoupled store from the previous
  // section cannot be counted (or observed) in the next one.
  task automatic gfx_idle;
    begin
      guard = 0;
      while (dut.u_gvram_arb.any_inflight && guard < 400) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (guard >= 400) begin
        $display("FAIL gfx_idle: the GVRAM datapath never drained");
        errors = errors + 1;
      end
    end
  endtask

  task automatic grcg_reg(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk);
      grcg_addr = a;
      grcg_din  = d;
      grcg_we   = 1'b1;
      @(negedge clk);
      grcg_we   = 1'b0;
    end
  endtask

  task automatic send_word(input [26:0] addr, input [15:0] data);
    begin
      while (ioctl_wait) @(negedge clk);
      @(negedge clk);
      ioctl_addr = addr;
      ioctl_dout = data;
      ioctl_wr = 1;
      @(negedge clk);
      ioctl_wr = 0;
    end
  endtask

  // One CPU store. Bounded: a route that never answers fails by name instead of hanging.
  // The ready is sampled after a delta (the selects settle from the address) and cpu_valid
  // is held through the ready cycle and dropped after it, which is z486's own shape.
  task automatic cpu_write_acc(input [31:0] addr, input [31:0] data, input [3:0] be);
    begin
      @(negedge clk);
      cpu_addr       = addr;
      cpu_din        = data;
      cpu_be         = be;
      cpu_write      = 1'b1;
      cpu_line_read  = 1'b0;
      cpu_burstcount = 8'd1;
      cpu_valid      = 1'b1;
      #1;
      guard = 0;
      while (!cpu_ready && guard < 200) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (!cpu_ready) begin
        $display("FAIL write %08x: never accepted", addr);
        errors = errors + 1;
      end
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_write = 1'b0;
      gfx_idle;
      repeat (8) @(negedge clk);   // the decoupled walk's tail, if any
    end
  endtask

  // One CPU read. cpu_valid is dropped after the accept (the responder contract's own
  // shape: accept, then the response on a LATER cycle) and the whole accept->response
  // window plus the backend latency is then watched, so a spurious EXTRA strobe (the map's
  // real response arriving after a phantom engine one) is counted too. The strobe counts
  // and the first strobe's data are left in the globals for the section checks.
  localparam integer READ_WATCH = RESP_LAT + 28;
  task automatic cpu_read_acc(input [31:0] addr, input [3:0] be);
    begin
      gfx_idle;
      @(negedge clk);
      resp_count      = 0;
      early_resp      = 0;
      first_resp_data = 32'hDEAD_DEAD;
      map_resp_seen   = 1'b0;
      cpu_addr       = addr;
      cpu_din        = 32'h0;
      cpu_be         = be;
      cpu_write      = 1'b0;
      cpu_line_read  = 1'b0;
      cpu_burstcount = 8'd1;
      cpu_valid      = 1'b1;
      #1;
      guard = 0;
      while (!cpu_ready && guard < 200) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (!cpu_ready) begin
        $display("FAIL read %08x: never accepted", addr);
        errors = errors + 1;
      end
      @(negedge clk);
      cpu_valid = 1'b0;
      repeat (READ_WATCH) @(negedge clk);
    end
  endtask

  // ==== CHECKS ====
  integer n0, n1, n2, n3, n4, n5;

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;

    // The CPU must be held until the pack has loaded (the harness contract every
    // subsystem bench starts from).
    cpu_valid = 1;
    cpu_addr  = 32'h0000_1000;
    #1;
    if (cpu_run || cpu_ready) begin
      $display("FAIL CPU escaped before ROM load");
      errors = errors + 1;
    end
    cpu_valid = 0;

    ioctl_download = 1;
    send_word(27'd0, 16'hBEEF);
    repeat (2) @(posedge clk);
    ioctl_download = 0;
    repeat (3) @(posedge clk);
    if (!rom_ready || !cpu_run || load_error) begin
      $display("FAIL load/arbitration ready=%b run=%b err=%b", rom_ready, cpu_run, load_error);
      errors = errors + 1;
    end

    // ---- SECTION 1: GRCG armed (0x7C = 0x80), a RAM STORE outside the windows ----
    // The F1 write side: the store must go to the RAM backend and nowhere else. On the
    // pre-fix tree the G_IDLE capture turns it into a phantom TDW walk (a dbg_grcg_store
    // pulse and real GVRAM array writes at (0x1000 & 0x7FFF) = 0x1000).
    $display("section 1: armed GRCG vs a non-window RAM store");
    grcg_reg(8'h7C, 8'h80);
    gfx_idle;
    n0 = grcg_store_pulses; n1 = gmem_writes; n2 = grcg_cl_cycles;
    n3 = grcg_busy_cycles;  n4 = ram_writes;  n5 = reads_accepted;
    cpu_write_acc(32'h0000_1000, 32'h5A5A_5A5A, 4'hF);
    check_eq("S1 the GRCG must not capture a RAM store (dbg_grcg_store pulses)",
             grcg_store_pulses - n0, 0);
    check_eq("S1 no GVRAM array write from a RAM store (phantom TDW/RMW walk)",
             gmem_writes - n1, 0);
    check_eq("S1 no GRCG client request from a RAM store (grcg_cl_valid cycles)",
             grcg_cl_cycles - n2, 0);
    check_eq("S1 the GRCG engine must not engage for a RAM store (busy cycles)",
             grcg_busy_cycles - n3, 0);
    check_eq("S1 the RAM store still reaches the backend exactly once",
             ram_writes - n4, 1);

    // ---- SECTION 2: GRCG armed (0x80, TCR), a RAM READ outside the windows ----
    // The F1 read side: the read must return the BACKEND's data on the map route's own
    // response. On the pre-fix tree the phantom TCR walk answers FIRST with tile-compare
    // garbage (early_resp), the CPU latches that as its RAM data (first_resp_data), and
    // the map's real response then lands as a spurious SECOND cpu_resp_valid (resp_count).
    $display("section 2: armed GRCG (TCR) vs a non-window RAM read");
    n0 = grcg_busy_cycles; n1 = gmem_writes; n2 = reads_accepted;
    cpu_read_acc(32'h0000_1000, 4'hF);
    check_eq("S2 no response before the backend's (the TCR strobe steal)", early_resp, 0);
    check_eq("S2 exactly one response strobe (no spurious extra)", resp_count, 1);
    check_word("S2 the read returns the RAM data, not TCR garbage",
               first_resp_data, ram_pattern(32'h0000_1000));
    check_eq("S2 the GRCG engine must not engage for a RAM read (busy cycles)",
             grcg_busy_cycles - n0, 0);
    check_eq("S2 no GVRAM array access from a RAM read", gmem_writes - n1, 0);
    check_eq("S2 the RAM read reaches the backend exactly once",
             reads_accepted - n2, 1);

    // ---- SECTION 3 (POSITIVE): the same armed GRCG, a WINDOW store ----
    // The gate is window MEMBERSHIP, not an engine disable: 0xA8000 inside the blue
    // plane window must still be captured exactly as before the fix. The tiles are
    // B=0x12, R=0x34, G=0x56, E=0x78 (0x7E writes B,R,G,E in order) and the armed
    // dword TDW store fills offsets 0..3 of every plane with them.
    $display("section 3: armed GRCG vs a plane-window store (positive control)");
    grcg_reg(8'h7C, 8'h80);
    grcg_reg(8'h7E, 8'h12);
    grcg_reg(8'h7E, 8'h34);
    grcg_reg(8'h7E, 8'h56);
    grcg_reg(8'h7E, 8'h78);
    gfx_idle;
    n0 = grcg_store_pulses; n1 = gmem_writes;
    cpu_write_acc(32'h000A_8000, 32'hFFFF_FFFF, 4'hF);
    check_eq("S3 a window store IS still captured (one dbg_grcg_store pulse)",
             grcg_store_pulses - n0, 1);
    if (gmem_writes - n1 < 1) begin
      $display("FAIL S3 the window store's tile bytes never reached the GVRAM array (%0d writes)",
               gmem_writes - n1);
      errors = errors + 1;
    end

    // ---- SECTION 4 (POSITIVE): the same armed GRCG, a WINDOW TCR read ----
    // 0xA8000 offset 0 now holds {E,G,R,B} = the tile word in every plane, so the tile
    // compare matches and the read answers 0xFF (NP2kai TCRRD's ~OR of enabled lanes) on
    // the GRCG's own response strobe, with no backend traffic at all.
    $display("section 4: armed GRCG (TCR) vs a plane-window read (positive control)");
    n0 = reads_accepted; n1 = resp_count;
    cpu_read_acc(32'h000A_8000, 4'b0001);
    check_eq("S4 the window TCR read still answers (exactly one strobe)", resp_count, 1);
    check_word("S4 the window TCR read still returns the tile-compare byte",
               first_resp_data, 32'h0000_00FF);
    check_eq("S4 the window read never touches the RAM backend",
             reads_accepted - n0, 0);

    // ---- SECTION 5: EGC gate on, a RAM STORE outside the windows ----
    // The EGC's owner decode is a pure direction term (cc_owns_egc = egc_gate &&
    // !cpu_line_read): with the gate on, the pre-fix tree hands it EVERY write. Same
    // contract as section 1, for the other engine.
    $display("section 5: EGC gate on vs a non-window RAM store");
    egc_enable = 1'b1;
    repeat (4) @(negedge clk);
    n0 = egc_txn_pulses; n1 = egc_busy_cycles; n2 = gmem_writes;
    n3 = egc_cl_cycles;  n4 = ram_writes;
    cpu_write_acc(32'h0000_1000, 32'h3C3C_3C3C, 4'hF);
    check_eq("S5 the EGC must not capture a RAM store (dbg_egc_txn pulses)",
             egc_txn_pulses - n0, 0);
    check_eq("S5 the EGC engine must not engage for a RAM store (busy cycles)",
             egc_busy_cycles - n1, 0);
    check_eq("S5 no EGC client request from a RAM store (egc_cl_valid cycles)",
             egc_cl_cycles - n3, 0);
    check_eq("S5 no GVRAM array write from a RAM store", gmem_writes - n2, 0);
    check_eq("S5 the RAM store still reaches the backend exactly once",
             ram_writes - n4, 1);

    // ---- SECTION 6: EGC gate on, a RAM READ outside the windows ----
    $display("section 6: EGC gate on vs a non-window RAM read");
    n0 = egc_txn_pulses; n1 = egc_busy_cycles;
    cpu_read_acc(32'h0000_1000, 4'hF);
    check_eq("S6 the EGC must not capture a RAM read (dbg_egc_txn pulses)",
             egc_txn_pulses - n0, 0);
    check_eq("S6 no response before the backend's", early_resp, 0);
    check_eq("S6 exactly one response strobe (no spurious extra)", resp_count, 1);
    check_word("S6 the read returns the RAM data, not engine garbage",
               first_resp_data, ram_pattern(32'h0000_1000));
    check_eq("S6 the EGC engine must not engage for a RAM read (busy cycles)",
             egc_busy_cycles - n1, 0);

    // ---- SECTION 7 (POSITIVE): EGC gate on, a WINDOW store ----
    $display("section 7: EGC gate on vs a plane-window store (positive control)");
    n0 = egc_txn_pulses; n1 = egc_busy_cycles;
    cpu_write_acc(32'h000A_8010, 32'h0000_0000, 4'hF);
    check_eq("S7 a window store IS still handed to the EGC (one dbg_egc_txn pulse)",
             egc_txn_pulses - n0, 1);
    if (egc_busy_cycles - n1 < 1) begin
      $display("FAIL S7 the EGC never engaged for a window store");
      errors = errors + 1;
    end
    egc_enable = 1'b0;

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GFX_WINDOW_GATE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GFX_WINDOW_GATE: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: a bench that blocks on a DUT signal with no bound would hang CI.
  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_GFX_WINDOW_GATE: TIMEOUT");
  end

endmodule

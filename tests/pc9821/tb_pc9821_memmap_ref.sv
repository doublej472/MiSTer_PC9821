`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// Every window the PC-9821 memory map decodes is driven against the reference decode and the RTL's answer is recorded: the first-megabyte RAM, window 0's 0x0461 alias (the identity, the 0x0C absent area and the 0x0E ROM window), the A0000-BFFFF text/CG/plane windows, the 0xD8000 option-ROM window and its 8 KiB byte routing, the 0xC0000-D7FFF absent area and the 0xCC000-0xCFFFF PC-9801-86 SOUND.ROM window carved out of it, the E8000-F7FFF lower BIOS, the F8000-FFFFF banked ROM window (every bank selection plus the 0xFFFF8000 top-of-4G alias), the 0x043F EMS page window, the 0xF00000 PEGC window, the 0x043B system-space split (PEGC VRAM, the F80000-F9FFFF hole, and the FA0000-FFFFFF mirror onto the low routes), the open-bus responder's phases, and window 0's own 0x0A VRAM page; the references are qemu-pc98 hw/i386/pc98-mem.c (the memory map) and NP2kai i386c/cpumem.c + mem/memvram.c + mem/memems.c, with the machine's own probes (docs/probes/WIN.TXT, EMS.TXT) where they disagree. The PEGC 256-colour window arms are driven the same way (pegc-scope-REPORT.md 4 row 2): the packed windows 0xA8000/0xB0000 splice to peg_base + {bank, offset[14:0]} and shadow the EMS overlay entirely, 0xB8000-0xBFFFF is not connected, 0xE0000-0xE7FFF is the register file's byte port under the view, plane mode (0xE0100 bit 0) reads open bus because the engine is ladder rung L3 and is not built, the flat aperture is gated by the register file's [0xE0102] bit 0 (open bus with it clear - the FAIL-FIRST row for that gate), and with the view down the planar arms are unchanged.

// ==== DUT ====
// TWO instances, because the decode is split across them. pc9821_memory_map owns the
// first-megabyte windows (planes, ROM bank, option ROM, absent area, EMS page, PEGC);
// pc9821_memory_subsystem owns the route selects on top of it (text RAM, CG window, the
// registered open-bus responder) and the 0x043B translation. A case that needs a route
// goes to the subsystem; a case about an address the map translates goes to the map.
//
// The backend is sdram_backend_model at its immediate timing (ACCEPT_TO_RESP = 0,
// WRITE_BUSY = 0): it must ANSWER, because the GVRAM route's read-modify-write issues
// backend reads that have to drain or the subsystem's response-route queue overflows. A
// route is classified by which route's WRITE strobe fires (tram_we, cg_win_we, the
// backend's mem_valid, or the open-bus responder's registered cpu_ready), and for a map
// case the map's translated address IS the byte routing.

module tb_pc9821_memmap_ref;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ---- the map's inputs, shared by both instances ----
  reg [3:0]  top_bank = 4'd8;            // 8 = the ITF bank, the reset selection
  reg        ide_rom_enable = 0;
  // The IDE work RAM's 0x1E8E gate, driven ON so the map cases below see the
  // connected work RAM (the gated shape is tb_pc9821_memory_subsystem's).
  reg        ide_ram_gate = 1;
  reg        bios_ram_gate = 0;
  reg        top_shadow_en = 0;
  reg        fw_shadow_dirty = 0;
  reg [31:0] fw_shadow_base = 32'h0215_8000;   // pack_base + PACK_BYTES + 0x58000
  reg  [1:0] ems_state = 2'd0;
  reg [31:0] ems_page_base = 32'h0214_8000;    // pack_base + PACK_BYTES + 0x48000
  reg [7:0]  win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  reg [31:0] pack_base = 32'h0200_0000;
  reg [31:0] guest_ram_bytes = 32'h0200_0000;
  reg        peg_window = 1'b0;
  reg [31:0] peg_base = 32'h0218_0000;         // pack_base + PACK_BYTES + 0x80000

  reg [31:0] cpu_addr = 0;
  reg [31:0] cpu_din = 0;
  reg [3:0]  cpu_be = 4'hF;
  reg [7:0]  cpu_burstcount = 8'd1;
  reg        cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;

  // ---- the PEGC window arms' state (pegc-scope-REPORT.md 4 row 2) ----
  // pegc_256 is the 0x6A dat 0x21 view select (pc9821_crtc's mode2_256col) and is
  // shared with the subsystem instance through `.*`; the map instance takes its
  // own copies of the bank/mode state so its decode can be probed directly (the
  // subsystem's copy lives in its pc9821_pegc register file and is set through
  // the register route, the machine's own flow).
  reg        pegc_256 = 1'b0;
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
  reg        pegc_plane = 1'b0;
  reg [3:0]  pegc_bank_a = 4'd0, pegc_bank_b = 4'd0;

  // ---- map instance I/O ----
  wire        gvram_window;
  wire [1:0]  gvram_win_plane;
  wire [14:0] gvram_win_offset;
  wire        pegc_packed, pegc_reg_win, pegc_nc;
  wire        map_absent_area;
  wire        map_ems_open_bus;
  wire        map_fw_shadow_store;
  wire [31:0] map_cpu_dout, map_mem_addr, map_mem_din;
  wire [3:0]  map_mem_be;
  wire [7:0]  map_mem_burstcount;
  wire        map_mem_line_read, map_mem_valid, map_mem_write;
  wire        map_cpu_ready, map_cpu_resp_valid;

  // ---- subsystem instance: 0x043B and the route selects ----
  reg        sys16m_en = 1'b1;
  reg        gvram_access_page = 0;
  reg        grcg_we = 0;
  reg [7:0]  grcg_addr = 0, grcg_din = 0;
  wire       grcg_expand;
  wire       grcg_expand_nx;   // mode[7]'s next state (opt-video VID-1); unused here

  reg        egc_enable = 0;
  reg [15:0] egc_access = 16'hFFF0, egc_fgbg = 16'h00FF, egc_ope = 16'h0000,
             egc_fg = 16'h0000, egc_mask = 16'hFFFF, egc_bg = 16'h0000,
             egc_sft = 16'h0000, egc_leng = 16'h000F;
  reg        egc_shift_we = 0;
  reg        ioctl_download = 0, ioctl_wr = 0;
  reg [15:0] ioctl_index = 0;
  reg [26:0] ioctl_addr = 0;
  reg [15:0] ioctl_dout = 0;
  wire       ioctl_wait, rom_ready, load_error, cpu_run;
  reg        scan_enable = 0, scan_line_tick = 0, scan_page = 0;
  reg        scan_walk_page = 0;
  reg [14:0] scan_line_base = 0;
  reg  [6:0] line_rd_addr = 0;
  reg        line_rd_sel = 0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;
  wire [17:0] font_addr;
  wire [15:0] font_data;
  wire        font_we;
  reg [18:0] font_req_addr = 0;
  reg        font_req = 0;
  wire       font_word_valid;
  wire [31:0] font_word_data;
  wire [31:0] fmem_addr, fmem_din;
  wire        fmem_valid, fmem_write;
  wire  [3:0] fmem_be;
  wire  [7:0] fmem_burstcount;
  reg         fmem_ready = 0, fmem_resp_valid = 0;
  reg  [31:0] fmem_dout = 0;
  wire [31:0] mem_addr, mem_din, mem_din_hi;
  wire [3:0]  mem_be;
  wire [7:0]  mem_burstcount;
  wire        mem_line_read, mem_valid, mem_write;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;
  wire [31:0] mem_dout;
  wire [127:0] mem_line_dout;
  wire        mem_ready, mem_resp_valid, mem_line_resp_valid;
  wire [13:0] tram_addr;
  wire  [7:0] tram_din;
  wire        tram_we;
  reg   [7:0] tram_dout = 8'h00;
  wire  [4:0] cg_win_byte_sel;
  wire        cg_win_rd;
  wire  [7:0] cg_win_din;
  wire        cg_win_we;
  reg   [7:0] cg_win_dout = 8'h00;
  wire [31:0] mem3_addr, mem3_din;
  wire  [3:0] mem3_be;
  wire  [7:0] mem3_burstcount;
  wire        mem3_valid, mem3_write;
  reg  [31:0] mem3_dout = 32'h0;
  reg         mem3_ready = 1'b1, mem3_resp_valid = 0;

  // The map's own decode. Its cpu_* outputs are separate from the subsystem's so the two
  // instances can share the address regs without sharing a driver.
  pc9821_memory_map map_dut (
      .top_bank(top_bank), .ide_rom_enable(ide_rom_enable), .d8_bank(2'b00),
      .ide_ram_gate(ide_ram_gate),
      .bios_ram_gate(bios_ram_gate), .top_shadow_en(top_shadow_en),
      .fw_shadow_dirty(fw_shadow_dirty), .fw_shadow_base(fw_shadow_base),
      .ems_state(ems_state), .ems_page_base(ems_page_base), .win0_sel(win0_sel), .win0_sel_moved(win0_sel != 8'h08),
      .pack_base(pack_base), .guest_ram_bytes(guest_ram_bytes),
      .peg_window(peg_window), .peg_base(peg_base),
      .pegc_256(pegc_256), .pegc_plane(pegc_plane),
      .pegc_bank_a(pegc_bank_a), .pegc_bank_b(pegc_bank_b),
      .pegc_packed(pegc_packed), .pegc_reg_win(pegc_reg_win),
      .pegc_nc(pegc_nc),
      .gvram_window(gvram_window), .gvram_win_plane(gvram_win_plane),
      .gvram_win_offset(gvram_win_offset),
      .cpu_addr(cpu_addr), .cpu_addr_raw(cpu_addr), .xl_low20(1'b0), .xl_peg(1'b0), .cpu_din(cpu_din), .cpu_dout(map_cpu_dout),
      .cpu_be(cpu_be),
      .cpu_burstcount(cpu_burstcount), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_ready(map_cpu_ready), .cpu_resp_valid(map_cpu_resp_valid),
      .absent_area(map_absent_area), .ems_open_bus(map_ems_open_bus),
      .fw_shadow_store(map_fw_shadow_store),
      .mem_addr(map_mem_addr), .mem_din(map_mem_din), .mem_dout(mem_dout),
      .mem_be(map_mem_be),
      .mem_burstcount(map_mem_burstcount),
      .mem_valid(map_mem_valid), .mem_write(map_mem_write), .mem_ready(mem_ready),
      .mem_resp_valid(mem_resp_valid)
  );

  // The graphics telemetry bus; this bench does not read it, but (.*) needs the name.
  wire [127:0] dbg_gfx_stats;
  wire dbg_walk_start, dbg_walk_cycle;   // the GVRAM's walk pulses, same reason
  wire dbg_egc_txn, dbg_egc_unit, dbg_grcg_store;   // the EGC/GRCG operation pulses, same reason
  // The GRCG's and the EGC's per-cycle ownership pulses; this bench does not count
  // them, but (.*) needs every port named.
  wire dbg_gr_owned, dbg_eg_owned;
  // The page-coincidence probe's two page levels; this bench does not read them,
  // but (.*) needs every port named.
  wire dbg_access_page, dbg_scan_page_q;
  wire cg_win_byte_hold = 1'b0;
  // Tied off: the 200-line interleave's odd-line fetch-skip input (400-line traffic
  // here; tb_pc9821_interleave_200 drives it).
  wire gfx_odd_line = 1'b0;
  // ---- pc9821_memory_subsystem's DMA bus-master port, tied off (see the iobus block) ----
/* verilator lint_off UNUSEDSIGNAL */
  wire        dma_addr_unused = 1'b0;
  wire [31:0] dma_addr = 32'd0;
  wire [1:0]  dma_gvwin = 2'b00;   // the DMAC's plane-window class of dma_addr (idle here)
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

  pc9821_memory_subsystem #(.SYS_CLOCK_HZ(100_000_000)) sys_dut (.*);

  // The backend: sdram_backend_model at the immediate timing, but with real responses --
  // one pulse per read dword, and none for a write -- because the GVRAM route's
  // read-modify-write issues backend READS that must complete or the response-route queue
  // never drains. Storage is modelled, so the model is also a byte sink the probes need
  // not care about.
  wire backend_busy;
  wire [31:0] backend_accepts, backend_beats;
  sdram_backend_model #(
      .ACCEPT_TO_RESP(0), .WRITE_BUSY(0), .LINE_RESP(0), .WORDS_LOG2(24)
  ) backend (
      .clk(clk), .reset(reset),
      .valid(mem_valid), .ready(mem_ready), .write(mem_write), .addr(mem_addr),
      .din(mem_din), .din_hi(mem_din_hi), .be(mem_be), .burstcount(mem_burstcount), .gath(mem_gath), .gath_extra(mem_gath_extra),
      .dout(mem_dout), .resp_valid(mem_resp_valid), .line_dout(mem_line_dout),
      .line_resp_valid(mem_line_resp_valid),
      .busy(backend_busy), .accepts(backend_accepts), .beats(backend_beats));

  // ==== STIMULUS ====
  localparam [2:0] R_BACKEND   = 3'd0,   // the map's backend route: mem_valid, target = mem_addr
                   R_TRAM      = 3'd2,   // the text-RAM bridge
                   R_CG        = 3'd3,   // the CG window
                   R_OPEN      = 3'd4,   // the registered open-bus responder
                   R_NONE      = 3'd5;   // nothing accepted: a hang

  localparam [31:0] PACK_BYTES = 32'h0010_0000;

  integer cases = 0;      // reference cases run
  integer errors = 0;     // the RTL contradicts the reference (the bench FAILS)
  integer diverge = 0;    // references conflict, or the divergence is a known/deliberate gap
  reg [2:0]  probe_route;
  reg [31:0] probe_target;

  task automatic send_word(input [26:0] addr, input [15:0] data);
    begin
      while (ioctl_wait) @(negedge clk);
      @(negedge clk);
      ioctl_addr = addr; ioctl_dout = data; ioctl_wr = 1;
      @(negedge clk); ioctl_wr = 0;
    end
  endtask

  // One request, classified by which route took it. For a WRITE every route's strobe is a
  // port (tram_we / cg_win_we / the backend's mem_valid); for a READ the TRAM and CG
  // bridges raise no strobe this bench can see, so a read is used only where the expected
  // route is the backend or the open-bus responder. The request is held for the whole
  // window because the backend is a state machine that accepts only when idle, so a
  // one-cycle pulse can fall inside another transaction's drain and be missed. The window
  // and the drain wait are both long enough for the POSTED store buffer's batch window
  // (HOLD_CYCLES = 100 at this bench's SYS_CLOCK_HZ): a PEGC store drains as a gather
  // session when its group completes, so it reaches mem_* tens of cycles after its
  // accept, and the NEXT probe must not see the previous one's target.
  task automatic route_probe(input [31:0] a, input wr, output [2:0] route,
                             output [31:0] target);
    integer i;
    reg seen_mem, seen_tram, seen_cg, seen_ready;
    begin
      seen_mem = 0; seen_tram = 0; seen_cg = 0; seen_ready = 0;
      target = 32'hDEAD_BEEF;
      cpu_addr = a; cpu_write = wr; cpu_be = 4'hF; cpu_line_read = 1'b0;
      cpu_valid = 1'b1;
      #1;
      if (mem_valid) begin seen_mem = 1; target = mem_addr; end
      for (i = 0; i < 200; i = i + 1) begin
        @(negedge clk);
        #1;
        if (mem_valid) begin seen_mem = 1; target = mem_addr; end
        if (tram_we) seen_tram = 1;
        if (cg_win_we) seen_cg = 1;
        if (cpu_ready) seen_ready = 1;
      end
      route = seen_tram ? R_TRAM : seen_cg ? R_CG :
              seen_mem ? R_BACKEND : seen_ready ? R_OPEN : R_NONE;
      cpu_valid = 1'b0;
      cpu_write = 1'b0;
      repeat (200) @(negedge clk);   // let the batched drain and the responders drain
    end
  endtask

  // A case the references agree on and the RTL must implement: a mismatch is an ERROR.
  task automatic route_case(input wr, input [31:0] a, input [2:0] want,
                            input [31:0] want_target,
                            input [8*40-1:0] name, input [8*110-1:0] cited);
    reg [2:0] got;
    reg [31:0] tgt;
    begin
      cases = cases + 1;
      route_probe(a, wr, got, tgt);
      if (got != want || (want == R_BACKEND && tgt !== want_target)) begin
        $display("FAIL     %0s: route=%0d target=%08x, want route=%0d target=%08x   [%0s]",
                 name, got, tgt, want, want_target, cited);
        errors = errors + 1;
      end else
        $display("ok       %0s: route=%0d target=%08x   [%0s]", name, got, tgt, cited);
    end
  endtask

  // A case where the references disagree with each other, or where the divergence is a
  // documented gap: recorded, counted, not a failure (the report owns the judgement).
  task automatic route_note(input wr, input [31:0] a, input [2:0] want,
                            input [8*40-1:0] name, input [8*110-1:0] cited);
    reg [2:0] got;
    reg [31:0] tgt;
    begin
      cases = cases + 1;
      route_probe(a, wr, got, tgt);
      if (got != want) begin
        $display("DIVERGE  %0s: rtl route=%0d target=%08x, reference route=%0d   [%0s]",
                 name, got, tgt, want, cited);
        diverge = diverge + 1;
      end else
        $display("ok       %0s: route=%0d target=%08x   [%0s]", name, got, tgt, cited);
    end
  endtask

  // A decode the MAP owns: its translated backend address, its validity, the absent-area
  // decode, and (when the address is a graphics-plane window) the plane and in-plane
  // offset it exports, which is the byte routing the GVRAM route consumes.
  task automatic map_case(input [31:0] a, input [31:0] want_mem, input want_valid,
                          input want_gv, input [1:0] want_plane, input [14:0] want_off,
                          input want_absent,
                          input [8*40-1:0] name, input [8*110-1:0] cited);
    begin
      cases = cases + 1;
      cpu_addr = a; cpu_write = 1'b0; cpu_line_read = 1'b0; cpu_valid = 1'b1;
      #1;
      if (map_mem_addr !== want_mem || map_mem_valid !== want_valid ||
          map_absent_area !== want_absent ||
          (want_gv && (gvram_window !== 1'b1 || gvram_win_plane !== want_plane ||
                       gvram_win_offset !== want_off))) begin
        $display("FAIL     %0s: mem_addr=%08x valid=%b gvram=%b plane=%0d off=%04x absent=%b, want mem_addr=%08x valid=%b gvram=%b plane=%0d off=%04x absent=%b   [%0s]",
                 name, map_mem_addr, map_mem_valid, gvram_window, gvram_win_plane,
                 gvram_win_offset, map_absent_area, want_mem, want_valid, want_gv,
                 want_plane, want_off, want_absent, cited);
        errors = errors + 1;
      end else
        $display("ok       %0s: mem_addr=%08x   [%0s]", name, map_mem_addr, cited);
      cpu_valid = 1'b0;
    end
  endtask

  // A COMPLETE CPU transaction on the subsystem instance - the register file's
  // enable/bank writes are real stores (the machine's own flow), not probes.
  task automatic bus_store(input [31:0] a, input [31:0] d, input [3:0] be);
    integer g;
    begin
      @(negedge clk);
      cpu_addr = a; cpu_din = d; cpu_be = be; cpu_write = 1; cpu_line_read = 0;
      cpu_burstcount = 8'd1; cpu_valid = 1;
      g = 0; while (!cpu_ready && g < 200) begin @(negedge clk); g = g + 1; end
      if (!cpu_ready) $fatal(1, "TB_PC9821_MEMMAP_REF: no accept for write %08x", a);
      @(negedge clk); cpu_valid = 0; cpu_write = 0;
      repeat (4) @(negedge clk);
    end
  endtask

  task automatic bus_read(input [31:0] a, output [31:0] d);
    integer g;
    begin
      @(negedge clk);
      cpu_addr = a; cpu_din = 32'd0; cpu_be = 4'hF; cpu_write = 0; cpu_line_read = 0;
      cpu_burstcount = 8'd1; cpu_valid = 1;
      g = 0; while (!cpu_ready && g < 200) begin @(negedge clk); g = g + 1; end
      if (!cpu_ready) $fatal(1, "TB_PC9821_MEMMAP_REF: no accept for read %08x", a);
      g = 0; while (!cpu_resp_valid && g < 200) begin @(negedge clk); g = g + 1; end
      if (!cpu_resp_valid) $fatal(1, "TB_PC9821_MEMMAP_REF: no response for read %08x", a);
      d = cpu_dout;
      @(negedge clk); cpu_valid = 0;
      repeat (4) @(negedge clk);
    end
  endtask

  // ==== CHECKS ====

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    ioctl_download = 1;
    send_word(27'd0, 16'hBEEF);
    repeat (2) @(posedge clk);
    ioctl_download = 0;
    repeat (4) @(posedge clk);
    if (!cpu_run) begin
      $display("FAIL setup: cpu_run never asserted after the pack download");
      errors = errors + 1;
    end

    // ---- the first-megabyte RAM: an identity map [QEMU ram_base; NP2 memmain] ----
    map_case(32'h0000_0000, 32'h0000_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "RAM 0x000000", "QEMU ram_base / NP2 memfn0 memmain");
    map_case(32'h0007_FFFF, 32'h0007_FFFF, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "RAM 0x07FFFF", "QEMU ram_base / NP2 memfn0 memmain");
    map_case(32'h000A_0000, 32'h000A_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "0xA0000 not a plane", "the plane aperture starts at 0xA8000 (NP2 vacctbl index)");
    map_case(32'h000A_4000, 32'h000A_4000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "0xA4000 not a plane", "the plane aperture starts at 0xA8000 (NP2 vacctbl index)");

    // ---- window 0, 0x0461: the identity and the two firmware windows ----
    win0_sel = 8'h08;
    map_case(32'h0008_0000, 32'h0008_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "win0 0x08 0x80000", "QEMU window-0 ram alias at page 0x08");
    map_case(32'h0009_FFFF, 32'h0009_FFFF, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "win0 0x08 0x9FFFF", "QEMU window-0 ram alias at page 0x08");
    // 0x0461 = 0x0E selects the 0xE0000-0xFFFFF page, and the ITF's own copies prove
    // it: BANK4@0x01D9-0x01FE copies DS=F800->ES=9800 and DS=E800->ES=8800, which land
    // on 0xF8000/0xE8000 only if the window's bias is 0x60000.
    win0_sel = 8'h0E;
    map_case(32'h0009_8000, pack_base + 32'h0000_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "win0 0x0E 0x98000 -> F8000", "FW BANK4@0x01D9 (the ROM window)");
    map_case(32'h0008_8000, pack_base + 32'h0001_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "win0 0x0E 0x88000 -> E8000", "FW BANK4@0x01ED (the lower BIOS)");
    win0_sel = 8'h0C;
    map_case(32'h0008_0000, 32'h000C_0000, 1'b0, 0, 2'd0, 15'd0, 1'b1,
             "win0 0x0C 0x80000 -> C0000", "MEAS WIN.TXT 0461=0C b=FFFF (absent area)");
    // 0x0461 = 0x00: the machine reads 0xFFFF at the window base and discards the store
    // (WIN.TXT 0461=00 b=FFFF a=FFFF, the same as 0x0C/0x0E/0x0F), while this core maps
    // the page to 0x00000-0x1FFFF. The mechanism is unknown and an open
    // question; recorded, not failed.
    begin
      reg [31:0] shown;
      win0_sel = 8'h00;
      cpu_addr = 32'h0008_0000; cpu_write = 1'b0; cpu_valid = 1'b1;
      #1;
      shown = map_mem_addr;
      $display("DIVERGE  win0 0x00 0x80000 -> %08x; MEAS WIN.TXT 0461=00 b=FFFF (reads open bus)   [MEAS vs RTL, OPEN]", shown);
      cpu_valid = 1'b0; cases = cases + 1; diverge = diverge + 1;
      win0_sel = 8'h08;
    end

    // ---- the graphics-plane windows [NP2 memvram.c; QEMU vram_*] ----
    win0_sel = 8'h08;
    map_case(32'h000A_8000, 32'h000A_8000, 1'b1, 1, 2'd0, 15'h0000, 1'b0,
             "A8000 plane B start", "NP2 memvram0 / QEMU vram_a8000");
    map_case(32'h000A_FFFF, 32'h000A_FFFF, 1'b1, 1, 2'd0, 15'h7FFF, 1'b0,
             "AFFFF plane B end", "NP2 memvram0 / QEMU vram_a8000");
    map_case(32'h000B_0000, 32'h000B_0000, 1'b1, 1, 2'd1, 15'h0000, 1'b0,
             "B0000 plane R start", "NP2 memvram0 / QEMU vram_b0000");
    map_case(32'h000B_7FFF, 32'h000B_7FFF, 1'b1, 1, 2'd1, 15'h7FFF, 1'b0,
             "B7FFF plane R end", "NP2 memvram0 / QEMU vram_b0000");
    map_case(32'h000B_8000, 32'h000B_8000, 1'b1, 1, 2'd2, 15'h0000, 1'b0,
             "B8000 plane G start", "NP2 memvram0 / QEMU vram_b0000");
    map_case(32'h000B_FFFF, 32'h000B_FFFF, 1'b1, 1, 2'd2, 15'h7FFF, 1'b0,
             "BFFFF plane G end", "NP2 memvram0 / QEMU vram_b0000");
    map_case(32'h000E_0000, 32'h000E_0000, 1'b1, 1, 2'd3, 15'h0000, 1'b0,
             "E0000 plane I start", "NP2 memvram0 plane 3 / QEMU vram_e0000");
    map_case(32'h000E_7FFF, 32'h000E_7FFF, 1'b1, 1, 2'd3, 15'h7FFF, 1'b0,
             "E7FFF plane I end", "NP2 memvram0 plane 3 / QEMU vram_e0000");

    // ---- the lower BIOS and the banked ROM window [QEMU bios/f8000_rom] ----
    map_case(32'h000E_8000, pack_base + 32'h0001_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "E8000 lower BIOS", "QEMU bios alias rom[OFF_BIOS] = BANK5*0x8000");
    map_case(32'h000F_7FFF, pack_base + 32'h0001_FFFF, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "F7FFF lower BIOS end", "QEMU bios alias 0x18000 at 0xE8000");
    top_bank = 4'd8;
    map_case(32'h000F_8000, pack_base + 32'h0000_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "bank 8 (ITF) start", "QEMU BANK_ITF=4 -> OFF_ITF; reset selection");
    map_case(32'h000F_FFFF, pack_base + 32'h0000_7FFF, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "bank 8 (ITF) end", "QEMU BANK_ITF=4");
    top_bank = 4'd4;
    map_case(32'h000F_8000, pack_base + 32'h0000_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "bank 4 = ITF image", "QEMU BANK_ITF=4");
    top_bank = 4'd9;
    map_case(32'h000F_8000, pack_base + 32'h0002_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "bank 9 = BIOS top", "QEMU BANK_BIOS_TOP=7 (0x043D flips to it)");
    top_bank = 4'd7;
    map_case(32'h000F_8000, pack_base + 32'h0002_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "bank 7 = BIOS top", "QEMU BANK_BIOS_TOP=7 -> OFF_BIOS+0x18000");
    top_bank = 4'd5;
    map_case(32'h000F_8000, pack_base + 32'h0001_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "bank 5 = BIOS first half", "QEMU BANK_BIOS=5");
    top_bank = 4'd6;
    map_case(32'h000F_8000, pack_base + 32'h0001_8000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "bank 6 = BIOS second half", "QEMU bank 6");
    top_bank = 4'd0;
    map_case(32'h000F_8000, pack_base + 32'h0003_1000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "bank 0 = extended ROM 0", "QEMU BANK_PCI=0 -> OFF_PCI; pack 0x31000");
    top_bank = 4'd1;
    map_case(32'h000F_8000, pack_base + 32'h0003_9000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "bank 1 = extended ROM 1", "QEMU BANK_APIC=1; pack 0x39000");
    top_bank = 4'd2;
    map_case(32'h000F_8000, pack_base + 32'h0004_1000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "bank 2 = extended ROM 2", "QEMU BANK_BASIC=2; pack 0x41000");
    top_bank = 4'd3;
    map_case(32'h000F_8000, pack_base + 32'h0007_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "bank 3 = option-ROM slot", "QEMU BANK_IDE=3 -> OFF_IDE=0x18000; pack slot 0x70000");
    // The top-of-4G alias of the window: qemu's top_mirror covers 0xFFFA0000-0xFFFFFFFF.
    top_bank = 4'd8;
    map_case(32'hFFFF_8000, pack_base + 32'h0000_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "0xFFFF8000 top-of-4G alias", "QEMU top_mirror over lowmem[0xA0000..0x100000]");
    map_case(32'hFFFF_FFFF, pack_base + 32'h0000_7FFF, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "0xFFFFFFFF alias top", "QEMU top_mirror");

    // ---- the option-ROM window at 0xD8000: 8 KiB, byte-routed through pack 0x70000 ----
    ide_rom_enable = 1;
    map_case(32'h000D_8000, pack_base + 32'h0007_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "D8000 IDE ROM start", "QEMU ide_rom alias OFF_IDE, 0x2000");
    map_case(32'h000D_9FFF, pack_base + 32'h0007_1FFF, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "D9FFF IDE ROM end (8 KiB)", "QEMU ide_rom 0x2000, not 0x8000");
    ide_rom_enable = 0;
    // 0xDA000-0xDBFFF: identity RAM with the 0x1E8E gate ON (driven above). NP2
    // reads memmain at those addresses (it never disconnects the RAM - its 0x80
    // write is an "ignore", cbus/ideio.c:1485-1490) and qemu's Xa7 (has_pci)
    // backs all of 0xC0000-0xDFFFF with DRAM, so both agree at this gate state;
    // qemu's non-PCI branch gates the 8 KiB on 0x1E8E exactly as this core now
    // does (see the divergence row below for what still differs). 0xDC000-0xDFFFF,
    // the 16 KiB above the work RAM, is ABSENT IN BOTH GATE STATES: the machine
    // reads FF over the whole DA000..DFFFF region with the gate clear
    // (SHADOW.TXT:201-213, ffblocks=000C) and qemu models the rest of the window
    // as rom_empty (NP2's 12 KiB mask is the outlier).
    map_case(32'h000D_A000, 32'h000D_A000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "DA000 IDE work RAM", "NP2 memfn0 memmain / QEMU Xa7 cbus-ram");
    map_case(32'h000D_FFFF, 32'h000D_FFFF, 1'b0, 0, 2'd0, 15'd0, 1'b1,
             "DFFFF work area tail", "MEAS SHADOW.TXT REGION DA000..DFFFF ffblocks=000C / QEMU rom_empty");

    // ---- the absent ROM area 0xC0000-0xD7FFF [MEAS SHADOW.TXT] ----
    map_case(32'h000C_0000, 32'h000C_0000, 1'b0, 0, 2'd0, 15'd0, 1'b1,
             "C0000 absent area", "MEAS SHADOW.TXT REGION C0000..D7FFF reads 0xFF");
    map_case(32'h000C_BFFF, 32'h000C_BFFF, 1'b0, 0, 2'd0, 15'd0, 1'b1,
             "CBFFF absent before SOUND.ROM", "MEAS SHADOW.TXT ffblocks=0028 of blocks=0030");
    // The PC-9801-86's 16 KiB SOUND.ROM window, carved out of the absent
    // area and served read-only from the pack's SOUND.ROM region (pack +0xC6800).
    // The machine answers real code here: SHADOW.TXT:150-199's +C000..+F800 rows
    // match bios/xe10/SOUND.ROM at all eight sampled blocks.
    map_case(32'h000C_C000, pack_base + 32'h000C_6800, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "CC000 SOUND.ROM window start", "MEAS SHADOW.TXT:150 +C000 / SOUND.ROM");
    map_case(32'h000C_FFFF, pack_base + 32'h000C_A7FF, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "CFFFF SOUND.ROM window end (16 KiB)", "SOUND.ROM[0x3FFF]; the 16 KiB window");
    map_case(32'h000D_0000, 32'h000D_0000, 1'b0, 0, 2'd0, 15'd0, 1'b1,
             "D0000 absent after SOUND.ROM", "MEAS SHADOW.TXT ffblocks=0028 of blocks=0030");
    map_case(32'h000D_7FFF, 32'h000D_7FFF, 1'b0, 0, 2'd0, 15'd0, 1'b1,
             "D7FFF absent area end", "MEAS SHADOW.TXT REGION C0000..D7FFF");
    map_case(32'h000D_8000, 32'h000D_8000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "D8000 is not absent", "the option-ROM window overlays it; gate-off shape capture-pending");

    // ---- the EMS page window, 0x043F 0x22 [MEAS EMS.TXT; FW BANK4@0xF82C7] ----
    ems_state = 2'd1;
    map_case(32'h000B_0000, ems_page_base + 32'h0000_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "EMS 0x22 page start", "MEAS EMS.TXT 0x22 = 64 KiB of RAM at 0xB0000");
    map_case(32'h000B_FFFF, ems_page_base + 32'h0000_FFFF, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "EMS 0x22 page end (64 KiB)", "MEAS EMS.TXT 0x22; FW BANK4@0xF8317");
    map_case(32'h001B_0000, 32'h001B_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "EMS is a first-MiB aperture", "the window is 0xB0000, not every 1 MiB alias");
    ems_state = 2'd2;
    map_case(32'h000B_0000, 32'h000B_0000, 1'b0, 0, 2'd0, 15'd0, 1'b0,
             "EMS 0x24 unmapped", "MEAS EMS.TXT 0x24 reads 0xFFFF, stores discarded");
    ems_state = 2'd0;

    // ---- the PEGC extended-VRAM window [QEMU pegc_post; NP2 memvgaf] ----
    peg_window = 1'b1;
    map_case(32'h00F0_0000, peg_base + 32'h0000_0000, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "PEGC window base", "QEMU PEGC_POST_SIZE 0x80000 decoded at 0xF00000");
    map_case(32'h00F7_FFFF, peg_base + 32'h0007_FFFF, 1'b1, 0, 2'd0, 15'd0, 1'b0,
             "PEGC window top", "QEMU pegc_post / NP2 memvgaf over vramex[0x80000]");
    peg_window = 1'b0;

    // ---- the routes: text RAM, the CG window, and the two guest relocations ----
    win0_sel = 8'h08;
    route_case(1'b1, 32'h000A_0000, R_TRAM, 32'h0, "0xA0000 direct",
               "NP2 memtram / QEMU tvram overlay");
    route_case(1'b1, 32'h000A_4000, R_CG, 32'h0, "0xA4000 direct",
               "MEAS PORTS.TXT VRAM / QEMU cgwindow at 0xA4000");
    // Window 0 = 0x0A: qemu enables window 0's vram overlays at that value, so the
    // window's 0x80000-0x87FFF aliases the text VRAM at 0xA0000-0xA7FFF and its 0x84000
    // aliases the same physical address as 0xA4000. The machine agrees that 0x80000 is
    // not the RAM page: WIN.TXT reads b=0800 there rather than the 0x5AA5 marker stored
    // under the identity window, and p/q=FF (the marker is in no low-RAM copy). This
    // core hands the window's text and CG pages straight to the backend (the map's own
    // translation reaches physical 0xA0000/0xA4000, where the subsystem decodes the TRAM
    // and CG routes on the PRE-bias address), while its plane pages do follow the bias.
    win0_sel = 8'h0A;
    route_case(1'b1, 32'h0008_0000, R_TRAM, 32'h0, "win0 0x0A 0x80000 = 0xA0000",
               "QEMU window-0 vram overlays at val 0x0a; MEAS WIN.TXT 0461=0A b=0800");
    route_case(1'b1, 32'h0008_4000, R_TRAM, 32'h0, "win0 0x0A 0x84000 = 0xA4000",
               "QEMU window-0 tvram 0x8000 covers 0xA0000-0xA7FFF, so 0x84000 is on it too");
    win0_sel = 8'h08;
    // 0x0461 = 0x0E aliases the intensity page; the machine answered 0xFFFF there at the
    // DOS prompt (WIN.TXT 0461=0E b=FFFF) because the planar plane is mode-gated, and
    // this core serves it unconditionally. Recorded, not failed.
    $display("DIVERGE  win0 0x0E 0x80000 = 0xE0000: RTL serves plane 3 (see the map cases above); MEAS WIN.TXT 0461=0E b=FFFF (the plane is mode-gated)   [MEAS vs RTL]");
    cases = cases + 1; diverge = diverge + 1;
    // 0xA5000-0xA7FFF: qemu's window-1 tvram overlay covers it (32 KiB from 0xA0000) and
    // the machine decodes nothing there - it reads 0xFF and discards stores
    // (docs/probes/VRAM.TXT:141-142, `A600wrote= 00 FF 55 AA` / `got= FF FF FF FF`, reproduced
    // in VRAM2.TXT:153-154). The core routes it to the registered open-bus responder
    // (pc9821_memory_subsystem.sv's tram_gap), so this note's expectation is met
    // rather than recorded as a divergence (it was a DIVERGE note before the M1 fix).
    // ASSERTED, not noted: the machine's capture decides it (it outranks QEMU), so a
    // regression that routed the tail anywhere else would only have turned this row into
    // an uncounted DIVERGE line.
    route_case(1'b1, 32'h000A_5000, R_OPEN, 32'h0, "0xA5000 (text VRAM tail)",
               "MEAS VRAM.TXT:141-142 nothing decodes there (outranks QEMU window-1 tvram 0x8000)");
    // 0x0463 (window 1 at 0xA0000-0xBFFFF) has NO mapping effect in this core: iobus
    // latches it and the register is not an input of either DUT. qemu maps it (0x0a = the
    // vram overlays, any other value = the RAM page); NP2kai has no such register at all;
    // the machine measured no change at 0xA0000-0xBFFFF for any of the eight values
    // written (WIN.TXT 0463=.. b=0020 throughout, p/q = 0A/0B). Recorded.
    $display("DIVERGE  0x0463 window 1 is latched with no mapping effect   [QEMU mem_apply_window(1) vs MEAS WIN.TXT (no change) vs NP2 (no port)]");
    cases = cases + 1; diverge = diverge + 1;

    // ---- 0x043B: the 15-16 MiB system space and the FA0000-FFFFFF mirror ----
    // The PEGC aperture is gated by the register file's [0xE0102] bit 0 (NP2kai
    // memvgaf; MAME pegc_vram_view), so the machine's own enable flow runs first:
    // open the view, write the register file, close the view. The dword at
    // 0xE0004 sets bank A = 5 / bank B = 3 for the packed-window cases below.
    pegc_256 = 1'b1;
    bus_store(32'h000E_0100, 32'h0001_0000, 4'hF);
    bus_store(32'h000E_0004, 32'h0003_0005, 4'hF);
    pegc_256 = 1'b0;
    sys16m_en = 1'b1;
    route_case(1'b1, 32'h00F0_0000, R_BACKEND, peg_base + 32'h0000_0000,
               "0xF00000 PEGC window", "QEMU pegc_post at 0xf00000 / NP2 memvgaf");
    route_case(1'b1, 32'h00FA_0000, R_TRAM, 32'h0, "0xFA0000 mirror = 0xA0000",
               "QEMU sys16m_mirror / NP2 memsys -> memfn0 memtram");
    route_case(1'b1, 32'h00FA_4000, R_CG, 32'h0, "0xFA4000 mirror = 0xA4000",
               "QEMU sys16m_mirror / NP2 memsys -> the CG window");
    // The mirror's plane pages (0xFA8000/0xFB0000/0xFE0000) are the same map decode the
    // plane cases above assert, reached through the translation, so they are not re-probed
    // here: tb_pc9821_sys16m.sv already drives them. The GVRAM's own route is
    // write-combining, so a single write is not a route observable.
    route_case(1'b0, 32'h00FF_8000, R_BACKEND, pack_base + 32'h0000_0000,
               "0xFF8000 mirror = 0xF8000", "QEMU sys16m_mirror -> the banked ROM window");
    route_case(1'b0, 32'h00F8_0000, R_OPEN, 32'h0, "0xF80000 hole",
               "QEMU has no owner at 0xF80000-0xF9FFFF / NP2 memnc");
    // The PEGC linear VRAM is decoded at BOTH 0x00F00000 and 0xFFF00000: qemu adds the
    // high alias explicitly (pegc_high, and pc98_mem_init's own comment "Real PC-9821
    // hardware decodes the same 512 KiB linear PEGC VRAM at both 0x00f00000 and
    // 0xfff00000") and NP2kai special-cases it in memp_read8 ("address >= 0xfff00000 &&
    // < 0xfff80000 -> memvgaf"). This core decodes only the low one, so the high window
    // reaches the open-bus responder instead of the PEGC store.
    route_case(1'b0, 32'hFFF0_0000, R_BACKEND, peg_base + 32'h0000_0000,
               "0xFFF00000 PEGC high alias",
               "QEMU pegc_high at 0xfff00000 / NP2 memp_read8 memvgaf branch");
    route_case(1'b0, 32'hFFF7_FFFF, R_BACKEND, peg_base + 32'h0007_FFFF,
               "0xFFF7FFFF PEGC high alias top",
               "QEMU pegc_high 0x80000 / NP2 memvgaf");
    route_note(1'b0, 32'hFFFA_0000, R_TRAM, "0xFFFA0000 top mirror",
               "QEMU top_mirror at 0xFFFA0000 / NP2 has no such decode (returns 0xFF)");
    route_note(1'b0, 32'hFFC0_0000, R_OPEN, "0xFC0000 mirror of the absent area",
               "QEMU Xa7 mirrors DRAM / NP2 C0000 is memems / MEAS: the area is absent");
    // With the hole off, 15-16 MiB is ordinary RAM again.
    sys16m_en = 1'b0;
    route_case(1'b1, 32'h00F0_0000, R_BACKEND, 32'h00F0_0000, "0xF00000 with 0x043B off",
               "QEMU ram_f00000 is enabled when sys16m is clear");
    sys16m_en = 1'b1;

    // ---- the open-bus responder's phases, at the configured RAM boundary ----
    guest_ram_bytes = 32'h0100_0000;   // 16 MiB: the boundary the 32 MiB default hides
    begin
      reg seen_ready, seen_resp;
      integer i;
      seen_ready = 0; seen_resp = 0;
      cases = cases + 1;
      cpu_addr = 32'h0100_0000; cpu_write = 1'b0; cpu_line_read = 1'b0; cpu_be = 4'hF;
      cpu_valid = 1'b1;
      #1;
      if (mem_valid) begin
        $display("FAIL     0x1000000 above guest RAM reached the backend: mem_valid=1");
        errors = errors + 1;
      end
      for (i = 0; i < 8; i = i + 1) begin
        @(negedge clk);
        if (cpu_ready && cpu_resp_valid) begin
          $display("FAIL     open bus accepted and answered in one cycle (z486 hazard)");
          errors = errors + 1;
        end
        if (cpu_ready) seen_ready = 1;
        if (cpu_resp_valid) begin
          seen_resp = 1;
          if (cpu_dout !== 32'hFFFF_FFFF) begin
            $display("FAIL     open-bus data %08x, want FFFFFFFF", cpu_dout);
            errors = errors + 1;
          end
        end
        if (i == 0) cpu_valid = 1'b0;
      end
      if (!seen_ready || !seen_resp) begin
        $display("FAIL     open bus delivered accept=%b response=%b", seen_ready, seen_resp);
        errors = errors + 1;
      end else
        $display("ok       open bus 0x1000000 (16 MiB guest): accept and all-ones response in separate cycles   [QEMU unassigned reads 0xFF]");
    end
    guest_ram_bytes = 32'h0200_0000;

    // ---- two reported divergences that are not route cases ----
    // qemu's pc98_mem_init seeds sys16m = 1 (the 16 MB system space present at power-on);
    // this core resets the latch to 0, so 15-16 MiB is RAM until the guest clears bit 2.
    // The ITF clears the bit itself, so the boot path does not see the difference.
    $display("DIVERGE  0x043B reset default: RTL hole OFF; QEMU pc98_mem_init leaves sys16m = 1   [QEMU vs RTL]");
    cases = cases + 1; diverge = diverge + 1;
    // qemu's non-PCI branch made 0xC0000-0xDFFFF rom_empty and gated the 0xD8000 IDE
    // work RAM on 0x1E8E; this core now takes the same 8 KiB gate at 0xDA000-0xDBFFF
    // and the same FF-always rom_empty shape at 0xDC000-0xDFFFF (the machine's own
    // semantics: SHADOWW.TXT:226-231 for the gate, SHADOW.TXT:201-213 for the tail),
    // so what still differs is the fill and the gate's port answer: QEMU's rom_empty
    // carries a 0xCB RETF at each 2 KiB boundary where this core answers plain all
    // ones, and QEMU reads the gate back as 0x80/0x81 and resets it ON where the
    // machine's FE/FF and this core's reset-OFF are the measured ones.
    $display("DIVERGE  0xC0000-0xDFFFF content: RTL all-ones absent area + the 0x1E8E-gated 8 KiB at 0xDA000 + FF-always tail at 0xDC000; QEMU non-PCI = rom_empty (0xFF/0xCB RETF fill) with the same gate but read-back 0x80/0x81 and reset ON   [QEMU non-PCI vs RTL]");
    cases = cases + 1; diverge = diverge + 1;
    // Window 0's alias is judged against the UNBIASED address: with the window at 0x10
    // and a 1 MiB guest, 0x80000 maps to physical 0x100000, above guest RAM, and the RTL
    // issues a backend access there. The reference has no RAM to read, and qemu's own
    // alias is built over its RAM blob, so it is not a clean oracle; recorded with the
    // reachable OSD sizes named (1/2/4/8 MiB can reach above guest RAM through window 0).
    begin
      guest_ram_bytes = 32'h0010_0000;
      win0_sel = 8'h10;
      route_probe(32'h0008_0000, 1'b1, probe_route, probe_target);
      cases = cases + 1; diverge = diverge + 1;
      if (probe_route == R_BACKEND)
        $display("DIVERGE  win0 0x10 0x80000 with a 1 MiB guest: backend access at %08x, above guest RAM   [RTL out_of_range is judged pre-bias]",
                 probe_target);
      else
        $display("ok       win0 0x10 0x80000 above guest RAM: route=%0d   [read as open bus]",
                 probe_route);
      guest_ram_bytes = 32'h0200_0000;
      win0_sel = 8'h08;
    end

    // ==== the PEGC 256-colour window arms (pegc-scope-REPORT.md 4 row 2) ====
    //
    // Fail-first for the 0xE0102 aperture gate: CLEAR the VRAM enable (the
    // register file's reset value is the same clear, and the rows above ran with
    // it set) and 0xF00000 and its high alias are NOT the store - NP2kai
    // memvgaf_rd8 answers 0xFF and memvgaf_wr8 drops the store (mem/memvga.c),
    // MAME disables pegc_vram_view the same way - so both route to the registered
    // open-bus responder. Before the gate landed both reached the backend at
    // peg_base here.
    pegc_256 = 1'b1;
    bus_store(32'h000E_0100, 32'h0000_0000, 4'hF);
    peg_window = 1'b1;
    route_case(1'b1, 32'h00F0_0000, R_OPEN, 32'h0,
               "0xF00000 with [0xE0102] clear",
               "NP2 memvgaf gated on mio2[2] bit 0 / MAME pegc_vram_view");
    route_case(1'b0, 32'hFFF0_0000, R_OPEN, 32'h0,
               "0xFFF00000 with [0xE0102] clear",
               "NP2 memp_read8 -> memvgaf, same gate");
    peg_window = 1'b0;

    // The machine's own enable flow (the ITF's phase-2 block runs exactly this:
    // out 0x6A 07/21/68/06 around the select, then [0xE0102] = 1): re-enable the
    // aperture through the register route and set bank A = 5 / bank B = 3.
    pegc_256 = 1'b1;
    bus_store(32'h000E_0100, 32'h0001_0000, 4'hF);
    bus_store(32'h000E_0004, 32'h0003_0005, 4'hF);
    // The register route itself: 0xE0000 reads the register file's 0x00 answer
    // (NP2kai memvgaio_rd8's default) where open bus would answer FF's, and the
    // banks round-trip (NP2kai mio1; MAME masks the write - recorded, not
    // asserted).
    bus_read(32'h000E_0000, probe_target);
    cases = cases + 1;
    if (probe_target !== 32'h0000_0000) begin
      $display("FAIL     0xE0000 register route: read %08x, want 00000000 (NP2 memvgaio_rd8)",
               probe_target);
      errors = errors + 1;
    end else
      $display("ok       0xE0000 register route answers 0x00   [NP2 memvgaio_rd8 default]");
    bus_read(32'h000E_0004, probe_target);
    cases = cases + 1;
    if (probe_target !== 32'h0003_0005) begin
      $display("FAIL     0xE0004 banks round-trip: read %08x, want 00030005   [NP2 mio1]",
               probe_target);
      errors = errors + 1;
    end else
      $display("ok       0xE0004 banks round-trip 00030005   [NP2 mio1; MEAS PEGC.TXT PPM rows]");

    // The packed windows: physical offset = {bank, offset[14:0]} (NP2kai
    // memvga.c VGARD8 `(mio1[p*2] & 15) << 15`; qemu pc98-vga.c `(bank & 0x0f) *
    // 0x8000`), and they take the ORDINARY backend route. The target check is
    // the bank splice; the route check is that nothing else claims the access.
    route_case(1'b1, 32'h000A_9234, R_BACKEND, peg_base + 32'h0002_9234,
               "0xA9234 packed window A (bank 5)",
               "NP2 memvga.c VGAWR8 (mio1[0]&15)<<15 / QEMU (bank&0xf)*0x8000");
    route_case(1'b1, 32'h000B_0040, R_BACKEND, peg_base + 32'h0001_8040,
               "0xB0040 packed window B (bank 3)",
               "NP2 memvga.c VGAWR8 (mio1[2]&15)<<15 / MAME bank*0x4000 words");
    // The map's own decode of the same arms, checked against its exported
    // predicates (the packed arm is the map's mem_addr; the plane windows must be
    // UNCLAIMED while the view is up - NP2kai's memvga handlers shadow them).
    // The map instance takes the bank state from the bench regs (the subsystem's
    // copy lives in its own register file, set through the store above), so the
    // same values are driven here: bank A = 5, bank B = 3.
    pegc_bank_a = 4'd5; pegc_bank_b = 4'd3;
    cpu_addr = 32'h000A_9234; cpu_write = 1'b0; cpu_valid = 1'b1; #1;
    cases = cases + 1;
    if (!(pegc_packed === 1'b1 && gvram_window === 1'b0 && pegc_reg_win === 1'b0 &&
          pegc_nc === 1'b0 && map_mem_addr === peg_base + 32'h0002_9234)) begin
      $display("FAIL     map decode 0xA9234 in view: packed=%b gv=%b reg=%b nc=%b addr=%08x",
               pegc_packed, gvram_window, pegc_reg_win, pegc_nc, map_mem_addr);
      errors = errors + 1;
    end else
      $display("ok       map decode 0xA9234 in view: packed arm claims, plane arm silent");
    cpu_valid = 1'b0;
    // 0xB8000-0xBFFFF is NOT CONNECTED in 256-colour mode (NP2kai cpumem.c's
    // memnc_* on the 0xB8000 slot), whatever the EMS state says.
    ems_state = 2'd1;
    route_case(1'b1, 32'h000B_8000, R_OPEN, 32'h0,
               "0xB8000 not connected in the view (EMS 0x22 up)",
               "NP2 cpumem.c memnc on 0xB8000 under VOPBIT_VGA");
    // ... and the packed arm shadows the EMS overlay entirely (the same cpumem.c
    // slot install), which is the row-2 priority decision.
    route_case(1'b1, 32'h000B_0040, R_BACKEND, peg_base + 32'h0001_8040,
               "0xB0040 packed shadows the EMS 0x22 page",
               "NP2 cpumem.c installs memvga1 over the EMS slot when VOPBIT_VGA");
    ems_state = 2'd2;
    route_case(1'b1, 32'h000B_0040, R_BACKEND, peg_base + 32'h0001_8040,
               "0xB0040 packed shadows the EMS unmapped state",
               "NP2 cpumem.c: the VGA handlers take the slot in this mode");
    ems_state = 2'd0;

    // Plane mode (0xE0100 bit 0) is ladder rung L3 and is deliberately NOT built:
    // the windows belong to the plane engine there, so they read open bus rather
    // than silently corrupting the packed store. Recorded gap.
    bus_store(32'h000E_0100, 32'h0000_0001, 4'hF);
    route_case(1'b1, 32'h000A_9234, R_OPEN, 32'h0,
               "0xA9234 in plane mode (engine not built)",
               "NP2 pegc_memvgaplane_* is L3; recorded gap, open bus here");
    bus_store(32'h000E_0100, 32'h0000_0000, 4'hF);

    // Control: with the view DOWN the windows are the planar ones again and the
    // packed arm is silent (NP2kai's VOPBIT_VGA install/uninstall).
    pegc_256 = 1'b0;
    cpu_addr = 32'h000A_9234; cpu_write = 1'b0; cpu_valid = 1'b1; #1;
    cases = cases + 1;
    if (!(pegc_packed === 1'b0 && gvram_window === 1'b1)) begin
      $display("FAIL     control: 0xA9234 with the view down must be the planar window (packed=%b gv=%b)",
               pegc_packed, gvram_window);
      errors = errors + 1;
    end else
      $display("ok       control: with the view down 0xA9234 is the planar window again");
    cpu_valid = 1'b0;
    // And with the view down 0xE0000 is the intensity plane again.
    cpu_addr = 32'h000E_0000; cpu_write = 1'b0; cpu_valid = 1'b1; #1;
    cases = cases + 1;
    if (!(pegc_reg_win === 1'b0 && gvram_window === 1'b1)) begin
      $display("FAIL     control: 0xE0000 with the view down must be plane 3 (reg=%b gv=%b)",
               pegc_reg_win, gvram_window);
      errors = errors + 1;
    end else
      $display("ok       control: with the view down 0xE0000 is the intensity plane again");
    cpu_valid = 1'b0;

  // ==== VERDICT ====
    $display("TB_PC9821_MEMMAP_REF: %0d reference cases, %0d mismatches, %0d reported divergences",
             cases, errors, diverge);
    // The divergence report is PINNED: the seven reported rows are each a recorded
    // judgement, so a decode change that adds one (an asserted-agreeing note row turning
    // into a DIVERGE) or removes one must fail here and be re-adjudicated, not scroll by.
    if (diverge != 7) begin
      $display("FAIL     the reported divergences changed: %0d, the adjudicated set is 7", diverge);
      errors = errors + 1;
    end
    if (errors == 0) begin
      $display("TB_PC9821_MEMMAP_REF: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_MEMMAP_REF: FAIL (%0d reference mismatches)", errors);
  end

  // In-bench watchdog: a bench that blocks on a DUT with no bound would hang CI forever.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_MEMMAP_REF: TIMEOUT");
  end

endmodule

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// With the 15-16 MiB system-space window ON (port 0x043B bit 2 cleared, which is the guest's request: reset leaves the window OFF so 15-16 MiB is RAM) the machine puts no SYSTEM RAM at 0xF00000-0xFFFFFF, and the subsystem splits it three ways: 0xFA0000-0xFFFFFF reaches the same route and the same address as the low 0xA0000-0xFFFFF it aliases, 0xF00000-0xF7FFFF is the PEGC's 512 KiB extended VRAM served by the mapper as one ordinary backend access at peg_base = pack_base + PACK_BYTES + 0x80000 - but ONLY with the register file's [0xE0102] bit 0 set (NP2kai memvgaf_rd8/wr8's VRAM-enable gate; the ITF sets it inside its own 0x6A 0x21 bracket before filling), and open bus with it clear - and only 0xF80000-0xF9FFFF reaches NO memory at all; with the window OFF the same addresses are ordinary identity RAM. Both references put the alias base at 0xFA0000 and not at 0xF00000 - qemu-pc98 aliases lowmem[0xa0000..0x100000] at 0xfa0000 (hw/i386/pc98-mem.c sys16m_mirror) and decodes its 512 KiB PEGC POST store (PEGC_POST_SIZE) at 0xf00000, and NP2kai reduces the address by 0xF00000 but selects that path only for address bits 19:17 = 5..7 (i386c/cpumem.c memsys_* vs memvgaf/memnc), its own 512 KiB memvgaf extended VRAM (vramex[0x80000]) covering the rest - so 0xF80000-0xF9FFFF is the part of the hole the ITF subtracts as the 15-16 MiB system-space hole (pc98-mem.c mem_sync_sys16m_workarea, ram[0x401] -= 8).

// ==== DUT ====
// pc9821_memory_subsystem, which owns the translation. It MUST happen ahead of
// the route selects: an aliased read of 0xFA0000 has to reach the text VRAM
// route, not the RAM route, so the bench asserts on the two routes' own request
// outputs (tram_addr / mem_valid / mem_addr) rather than on any internal signal.
//
// The backend is the immediate stub: this bench is about WHICH request the
// subsystem issues for a given CPU address, not about how the memory answers it.

module tb_pc9821_sys16m;
  // pc9821_memory_subsystem's pack-download hold: no boot-ROM download under the OSD Reset
  // level here (tb_pc9821_boot0_load drives that), so the level is low and the hold unread.
  wire hps_apply_reset = 1'b0;
  wire pack_load_hold;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  reg [3:0]  top_bank = 4'd8;
  reg        ide_rom_enable = 0;
  reg        ide_ram_gate = 1;
    // 0x1E8E's IDE work-RAM gate: held ON so nothing here sees the gated
    // shape - tb_pc9821_memory_subsystem and tb_pc9821_memory_map pin it.
  reg        bios_ram_gate = 0;
  reg [7:0]  win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  // 0x043B bit 2, the 15-16 MiB system-space window. ON is the machine's reset
  // value and the value qemu's pc98_mem_reset leaves (`s->sys16m = 1`).
  reg        sys16m_en = 1'b1;
  // ems_state: the 0x043F 0x2x EMS window state. This bench does not exercise EMS, so it is
  // tied to the identity/VRAM state; the port exists because pc9821_memory_subsystem consumes it.
  wire top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  reg  [1:0] ems_state = 2'd0;
  reg [31:0] pack_base = 32'h0200_0000;
  reg [31:0] guest_ram_bytes = 32'h0200_0000;
  reg        gvram_access_page = 0;

  reg        grcg_we = 0;
  reg [7:0]  grcg_addr = 0;
  reg [7:0]  grcg_din = 0;
  wire       grcg_expand;   // the GRCG's CG-mode bit 7, fed back from the subsystem
  wire       grcg_expand_nx;   // mode[7]'s next state (opt-video VID-1); unused here


  // EGC off: this bench is about address translation, not the plane engines.
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

  reg [31:0] cpu_addr = 0, cpu_din = 0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  reg [3:0]  cpu_be = 4'hF;
  reg [7:0]  cpu_burstcount = 8'd1;
  reg        cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  wire       cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  wire [13:0] tram_addr;
  wire [7:0]  tram_din;
  wire        tram_we;
  wire [7:0]  tram_dout;
  reg  [7:0]  tram [0:16383];
  assign tram_dout = tram[tram_addr];

  wire [4:0] cg_win_byte_sel;
  wire       cg_win_rd;
  reg  [7:0] cg_win_dout = 0;
  wire [7:0] cg_win_din;
  wire       cg_win_we;

  reg [18:0] font_req_addr = 0;
  reg        font_req = 0;
  wire       font_word_valid;
  wire [31:0] font_word_data;

  wire [31:0] fmem_addr, fmem_din;
  wire        fmem_valid, fmem_write;
  wire [3:0]  fmem_be;
  wire [7:0]  fmem_burstcount;
  reg         fmem_ready = 1, fmem_resp_valid = 0;
  reg  [31:0] fmem_dout = 32'd0;

  wire [31:0] mem_addr, mem_din;
  wire [3:0]  mem_be;
  wire [7:0]  mem_burstcount;
  wire        mem_line_read, mem_valid, mem_write;
  reg  [31:0] mem_dout = 32'd0;
  reg  [127:0] mem_line_dout = 128'd0;

  // The immediate backend stub: accept straight away, answer the next cycle.
  reg         mem_ready = 1, mem_resp_valid = 0, mem_line_resp_valid = 0;
  // The GVRAM scanout's SDRAM requester. The wildcard instantiation needs every port
  // named; nothing here drives the scanout, so it accepts and never answers.
  wire [31:0] mem3_addr, mem3_din;
  wire  [3:0] mem3_be;
  wire  [7:0] mem3_burstcount;
  wire        mem3_valid, mem3_write;
  reg  [31:0] mem3_dout = 32'h0;
  reg         mem3_ready = 1, mem3_resp_valid = 0;
  always @(posedge clk) begin
    if (reset) mem_resp_valid <= 1'b0;
    else       mem_resp_valid <= mem_valid && !mem_write;
  end

  // The GVRAM write client's two-word payload; this bench's backend ignores it.

  wire [31:0] mem_din_hi;

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

  // The PEGC view select (pc9821_crtc's mode2_256col): opened only for the
  // [0xE0102] write below (the register file lives behind the view), then closed.
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

  integer errors = 0;

  // Set an address and the window state, then let the combinational decode
  // settle. `#1` is enough: every route select in the subsystem is a function of
  // cpu_addr and sys16m_en alone. A probe PRESENTS a request it never completes
  // (the checks read the decode after this returns), so each probe first drains
  // whatever the previous one left in a registered responder's FSM - two
  // responders mid-flight would trip the subsystem's one-request check.
  task automatic drain;
    begin
      cpu_valid = 1'b0; cpu_write = 1'b0;
      repeat (8) @(negedge clk);
    end
  endtask

  task automatic drive_addr(input [31:0] a, input en);
    begin
      drain;
      sys16m_en = en;
      cpu_addr  = a;
      cpu_write = 1'b0;
      cpu_line_read = 1'b0;
      cpu_be    = 4'hF;
      cpu_valid = 1'b1;
      #1;
    end
  endtask

  // The subsystem owns the backend until a pack word lands and rom_ready rises, so
  // cpu_run must be brought up the same way the subsystem's own bench does.
  task automatic send_word(input [26:0] addr, input [15:0] data);
    begin
      while (ioctl_wait) @(negedge clk);
      @(negedge clk);
      ioctl_addr = addr; ioctl_dout = data; ioctl_wr = 1;
      @(negedge clk); ioctl_wr = 0;
    end
  endtask

  // One CPU store: the PEGC register file's [0xE0102] write is the machine's own
  // aperture-enable flow (the ITF's phase-2 block does exactly this inside its
  // 0x6A 0x21 bracket).
  task automatic cpu_store(input [31:0] a, input [31:0] d, input [3:0] be);
    integer g;
    begin
      drain;
      @(negedge clk);
      cpu_addr = a; cpu_din = d; cpu_be = be; cpu_write = 1; cpu_line_read = 0;
      cpu_burstcount = 8'd1; cpu_valid = 1;
      g = 0; while (!cpu_ready && g < 40) begin @(negedge clk); g = g + 1; end
      if (!cpu_ready) $fatal(1, "TB_PC9821_SYS16M: no accept for write %08x", a);
      @(negedge clk); cpu_valid = 0; cpu_write = 0;
    end
  endtask

  reg        ref_mem_valid;
  reg [31:0] ref_mem_addr;

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

    // ================= ROUTE PROBES =================
    // Combinationally valid: every route select is a function of cpu_addr and
    // sys16m_en alone, so one time unit is enough to see which route a CPU address
    // reaches. These say WHICH route; the reads above said WHICH DATA.

    // ==== CHECKS ====
    // CHK-5gate: with [0xE0102] bit 0 CLEAR the aperture is NOT the store - NP2kai's
    // memvgaf_rd8 answers 0xFF and memvgaf_wr8 drops the store (mem/memvga.c), MAME
    // disables pegc_vram_view the same way (pc9821.cpp pegc_mmio_map) - so 0xF00000
    // reaches no backend request (the registered open-bus responder owns it). This
    // check is the gate's fail-first row: before the gate landed the address issued
    // a backend access at peg_base here.
    drive_addr(32'h00F0_0000, 1'b1);
    if (!(mem_valid === 1'b0)) begin
      $display("FAIL CHK-5gate: 0xF00000 with [0xE0102] bit 0 clear must not reach the backend, got mem_valid=%b mem_addr=%08x",
               mem_valid, mem_addr);
      errors = errors + 1;
    end

    // The machine's own enable flow: open the PEGC MMIO view (the 0x6A dat 0x21
    // select), write [0xE0102] = 1 through the register file (byte lane 2 of the
    // dword at 0xE0100), close the view.
    pegc_256 = 1'b1;
    cpu_store(32'h000E_0100, 32'h0001_0000, 4'b0100);
    pegc_256 = 1'b0;

    // CHK-4: WINDOW OFF, 0xF00000 is ordinary identity RAM.
    drive_addr(32'h00F0_0000, 1'b0);
    if (!(mem_valid === 1'b1 && mem_addr === 32'h00F0_0000)) begin
      $display("FAIL CHK-4 window OFF: 0xF00000 should be identity RAM, got mem_valid=%b mem_addr=%08x",
               mem_valid, mem_addr);
      errors = errors + 1;
    end

    // CHK-5: WINDOW ON, 0xF00000 is the PEGC's 512 KiB extended VRAM, served by
    // the mapper as an ordinary backend access at peg_base = pack_base + PACK_BYTES +
    // 0x80000. The ITF's phase-2 test (BANK4@0x1416-0x14B6) fills and verifies 512 KiB here.
    drive_addr(32'h00F0_0000, 1'b1);
    if (!(mem_valid === 1'b1 && mem_addr === 32'h0218_0000 && tram_we === 1'b0 && cg_win_rd === 1'b0)) begin
      $display("FAIL CHK-5 window ON: 0xF00000 is the PEGC extended VRAM at peg_base, got mem_valid=%b mem_addr=%08x want %08x",
               mem_valid, mem_addr, 32'h0218_0000);
      errors = errors + 1;
    end

    // CHK-5b: the top of the 512 KiB window reaches peg_base + 0x7FFFF, so this is the whole
    // window and not a single-address accident.
    drive_addr(32'h00F7_FFFF, 1'b1);
    if (!(mem_valid === 1'b1 && mem_addr === 32'h021F_FFFF)) begin
      $display("FAIL CHK-5b window top: 0xF7FFFF should reach peg_base + 0x7FFFF, got mem_valid=%b mem_addr=%08x",
               mem_valid, mem_addr);
      errors = errors + 1;
    end

    // CHK-5c: 0xF80000-0xF9FFFF is the part of the window that really is the hole - 0x043B
    // puts no owner there - so it still reaches no route.
    drive_addr(32'h00F8_0000, 1'b1);
    if (!(mem_valid === 1'b0 && tram_we === 1'b0 && cg_win_rd === 1'b0)) begin
      $display("FAIL CHK-5c window hole: 0xF80000 must reach no route, got mem_valid=%b tram_we=%b cg_win_rd=%b",
               mem_valid, tram_we, cg_win_rd);
      errors = errors + 1;
    end

    // CHK-5d: ...and the hole is the WHOLE 128 KiB, not just its first 64 KiB block: its
    // last byte 0xF9FFFF reaches no route either (qemu-pc98 pc98-mem.c: nothing is
    // decoded between the 0xf00000 PEGC POST store's 0x80000 and sys16m_mirror's 0xfa0000).
    drive_addr(32'h00F9_FFFF, 1'b1);
    if (!(mem_valid === 1'b0 && tram_we === 1'b0 && cg_win_rd === 1'b0)) begin
      $display("FAIL CHK-5d window hole top: 0xF9FFFF must reach no route, got mem_valid=%b mem_addr=%08x",
               mem_valid, mem_addr);
      errors = errors + 1;
    end

    // CHK-7a: WINDOW ON, the mirror's BASE: 0xFA0000 reaches exactly what 0xA0000 reaches
    // (qemu sys16m_mirror aliases lowmem[0xa0000..] AT 0xfa0000), and is not identity RAM.
    // CHK-7 below only probes the top, which a mirror starting one block late also passes.
    drive_addr(32'h000A_0000, 1'b1);
    ref_mem_addr  = mem_addr;
    ref_mem_valid = mem_valid;
    drive_addr(32'h00FA_0000, 1'b1);
    if (!(mem_valid === ref_mem_valid && (!mem_valid || mem_addr === ref_mem_addr)) ||
        (mem_valid === 1'b1 && mem_addr === 32'h00FA_0000)) begin
      $display("FAIL CHK-7a mirror base: 0xFA0000 must alias 0xA0000, got mem_valid=%b mem_addr=%08x (0xA0000: mem_valid=%b mem_addr=%08x)",
               mem_valid, mem_addr, ref_mem_valid, ref_mem_addr);
      errors = errors + 1;
    end

    // CHK-6: WINDOW OFF, 0xFA0000 is ordinary identity RAM.
    drive_addr(32'h00FA_0000, 1'b0);
    if (!(mem_valid === 1'b1 && mem_addr === 32'h00FA_0000)) begin
      $display("FAIL CHK-6 window OFF: 0xFA0000 should be identity RAM, got mem_valid=%b mem_addr=%08x",
               mem_valid, mem_addr);
      errors = errors + 1;
    end

    // CHK-7: WINDOW ON, the alias covers the whole 384 KiB and not just its base: the top
    // of the range reaches the SAME backend address as the top of the low range it
    // aliases (the firmware ROM window). Controlled: the same pair DIFFERS with the
    // window off, where 0xFFFFFF is identity RAM and 0xFFFFF is still the ROM window,
    // so the agreement above can only come from the translation.
    drive_addr(32'h000F_FFFF, 1'b1);
    ref_mem_addr  = mem_addr;
    ref_mem_valid = mem_valid;
    drive_addr(32'h00FF_FFFF, 1'b1);
    if (!(mem_valid === ref_mem_valid && mem_addr === ref_mem_addr)) begin
      $display("FAIL CHK-7 mirror top: 0xFFFFFF must alias 0xFFFFF, got mem_addr=%08x (want %08x)",
               mem_addr, ref_mem_addr);
      errors = errors + 1;
    end
    drive_addr(32'h000F_FFFF, 1'b0);
    ref_mem_addr = mem_addr;
    drive_addr(32'h00FF_FFFF, 1'b0);
    if (mem_addr === ref_mem_addr) begin
      $display("FAIL CHK-7 control: with the window OFF 0xFFFFFF and 0xFFFFF both read %08x, so the window is not what makes them agree",
               mem_addr);
      errors = errors + 1;
    end

    // CHK-8: the window is not a blanket rule over the 15-16 MiB range's neighbours - an
    // address ABOVE it stays ordinary RAM, so the bench cannot pass by aliasing
    // everything above 0xF00000.
    drive_addr(32'h0010_0000, 1'b1);
    if (!(mem_valid === 1'b1 && mem_addr === 32'h0010_0000)) begin
      $display("FAIL CHK-8 control: 0x1000000 is above the window and must stay identity RAM, got mem_valid=%b mem_addr=%08x",
               mem_valid, mem_addr);
      errors = errors + 1;
    end

    // CHK-9: the PEGC's HIGH alias 0xFFF00000-0xFFF7FFFF is the same 512 KiB extended VRAM
    // WHATEVER 0x043B says. NP2kai decodes it with no 0x043B term (i386c/cpumem.c:805, the
    // `address >= 0xfff00000 && address < 0xfff80000` arm of memp_read8 -> memvgaf_rd8), and
    // MAME maps it inside pegc_vram_view, which only [0xE0102] gates, while its separate
    // m_hole_15M_view covers 0x00F00000-0x00FFFFFF alone (src/mame/nec/pc9821.cpp:684-691).
    // FAIL-FIRST: before the fix the alias required the
    // window ON, so with it OFF 0xFFF00000 reached no backend request at all.
    drive_addr(32'hFFF0_0000, 1'b1);
    if (!(mem_valid === 1'b1 && mem_addr === 32'h0218_0000)) begin
      $display("FAIL CHK-9 high alias, window ON: 0xFFF00000 should reach peg_base, got mem_valid=%b mem_addr=%08x want %08x",
               mem_valid, mem_addr, 32'h0218_0000);
      errors = errors + 1;
    end
    drive_addr(32'hFFF0_0000, 1'b0);
    if (!(mem_valid === 1'b1 && mem_addr === 32'h0218_0000)) begin
      $display("FAIL CHK-9 high alias, window OFF: 0xFFF00000 is the PEGC VRAM regardless of 0x043B, got mem_valid=%b mem_addr=%08x want %08x",
               mem_valid, mem_addr, 32'h0218_0000);
      errors = errors + 1;
    end
    drive_addr(32'hFFF7_FFFF, 1'b0);
    if (!(mem_valid === 1'b1 && mem_addr === 32'h021F_FFFF)) begin
      $display("FAIL CHK-9 high alias top, window OFF: 0xFFF7FFFF should reach peg_base + 0x7FFFF, got mem_valid=%b mem_addr=%08x",
               mem_valid, mem_addr);
      errors = errors + 1;
    end
    // Control: the window OFF still leaves 0xF00000 as RAM (CHK-4), and the byte past the
    // alias (0xFFF80000) is not the VRAM, so the fix cannot pass by widening either side.
    drive_addr(32'hFFF8_0000, 1'b0);
    if (mem_valid === 1'b1 && mem_addr >= 32'h0218_0000 && mem_addr <= 32'h021F_FFFF) begin
      $display("FAIL CHK-9 control: 0xFFF80000 is past the 512 KiB alias but reached the PEGC VRAM at %08x",
               mem_addr);
      errors = errors + 1;
    end
    drive_addr(32'h00F0_0000, 1'b0);
    if (!(mem_valid === 1'b1 && mem_addr === 32'h00F0_0000)) begin
      $display("FAIL CHK-9 control: with the window OFF 0xF00000 must stay identity RAM, got mem_valid=%b mem_addr=%08x",
               mem_valid, mem_addr);
      errors = errors + 1;
    end

    // CHK-10: THE BIOS AT THE TOP OF 4 GiB, IN BOTH A20 ALIASES. The reset fetch is at
    // 0xFFFFFFF0 with A20 masked, and the Xe10's gate clears physical bit 20 only
    // (docs/probes/A20MAP-XE10.TXT: BIT20-ONLY), so the CPU drives 0xFFEFFFF0; MAME maps the
    // IPL bank at 0xFFEE8000-0xFFEFFFFF and 0xFFFE8000-0xFFFFFFFF (pc9821.cpp:688-689). Each
    // must reach the backend address of the low E8000-FFFFF window it aliases.
    begin : chk10
      reg [31:0] lo [0:1];
      reg [31:0] hi [0:3];
      integer k;
      lo[0] = 32'h000F_FFF0;  lo[1] = 32'h000E_8000;
      hi[0] = 32'hFFFF_FFF0;  hi[1] = 32'hFFEF_FFF0;
      hi[2] = 32'hFFFE_8000;  hi[3] = 32'hFFEE_8000;
      for (k = 0; k < 4; k = k + 1) begin
        drive_addr(lo[k / 2], 1'b0);
        ref_mem_addr  = mem_addr;
        ref_mem_valid = mem_valid;
        drive_addr(hi[k], 1'b0);
        if (!(mem_valid === ref_mem_valid && mem_addr === ref_mem_addr)) begin
          $display("FAIL CHK-10 BIOS top alias: %08x must reach %08x's backend address %08x, got mem_valid=%b mem_addr=%08x",
                   hi[k], lo[k / 2], ref_mem_addr, mem_valid, mem_addr);
          errors = errors + 1;
        end
      end
      // Controls: the byte below the window is not the BIOS, and the PEGC high alias keeps
      // its own decode, so the fix cannot pass by aliasing the whole top 2 MiB.
      drive_addr(32'h000E_7FFF, 1'b0);
      ref_mem_addr = mem_addr;
      drive_addr(32'hFFEE_7FFF, 1'b0);
      if (mem_valid === 1'b1 && mem_addr === ref_mem_addr) begin
        $display("FAIL CHK-10 control: 0xFFEE7FFF is below the BIOS window but aliased 0xE7FFF at %08x", mem_addr);
        errors = errors + 1;
      end
      drive_addr(32'hFFF0_0000, 1'b0);
      if (!(mem_valid === 1'b1 && mem_addr === 32'h0218_0000)) begin
        $display("FAIL CHK-10 control: 0xFFF00000 must stay the PEGC high alias, got mem_valid=%b mem_addr=%08x",
                 mem_valid, mem_addr);
        errors = errors + 1;
      end
    end

    cpu_valid = 1'b0;
    $display("  sys16m: window ON aliases 0xFA0000-0xFFFFFF onto 0xA0000-0xFFFFF, serves 0xF00000-0xF7FFFF as PEGC VRAM, and holes 0xF80000-0xF9FFFF; OFF makes them RAM");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SYS16M: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_SYS16M: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    // $fatal, not $finish: $finish exits ZERO, which would report a timeout as a pass.
    $fatal(1, "TB_PC9821_SYS16M: FAIL (timed out)");
  end
endmodule

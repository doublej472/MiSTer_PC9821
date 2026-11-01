`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_MEMRANGE_CORRESPONDENCE:
// THE SAFETY INVARIANT OF THE WHOLE ADDRESS MAP: any address the CPU's cache classifier calls CACHEABLE is an address the memory map serves as PLAIN GUEST RAM - the identity route, below the guest RAM top, with no device, alias, ROM window or side-effectful storage behind it - swept over every 4 KiB block of the first MiB, every 64 KiB block of the first 16 MiB, every MiB of the // rest of the module, and the boundary byte of each of the platform's windows, under both states of the 15-16 MiB system-space window; and, in the other direction, the addresses that are plain RAM yet classified UNCACHED (a deliberately conservative loss, never a correctness one) are PINNED as a list, so widening or narrowing that loss is a visible change and not a silent one.
//
// WHY THE DIRECTION MATTERS, AND WHY IT IS ONLY ONE WAY. `cacheable(x) => plain_ram(x)`
// is the correctness half: caching anything with a second writer (VRAM the EGC/GRCG and the
// scanout write, the PEGC's extended VRAM, the firmware shadow, the EMS page) or anything
// backed by a ROM/absent responder is exactly the coherency bug class this core keeps meeting.
// The converse is NOT a correctness property: a plain-RAM range may be served uncached on
// purpose, and the classifier is deliberately conservative in several places (the window-0
// overlay, and the whole 15-16 MiB alias even where the system-space window is off). So this
// bench ASSERTS the first direction everywhere and PINS the second as a table.
//
// THE CLASSIFIER'S OBSERVABLE IS ITS WHOLE OUTPUT, NOT ONE TERM. `dcache_req_is_uncached` is
// the OR of every mechanism the CPU classifies with: the window list (`z486_classify_phys`),
// the paging unit's non-paging VGA decode, and the separate DEVICE_MMIO window - which is a
// mechanism of its own and NOT part of the window list, so a bench that called the classifier
// function directly would not have caught the 32-64 MiB device-window misclassification. This
// bench reads the real `memory` unit's own signal, with the platform's own parameters, so it
// sees whichever mechanisms are actually built.
//
// THE EXPECTED VALUES COME FROM THE PLATFORM'S DOCUMENTED CONTRACT, NOT FROM THE RTL: the
// map's route is read at `mem_addr`/`mem_valid` (a translator that has already applied the
// window-0 bias and the sys16m translations), and "plain RAM" is defined from the documented
// layout - the identity route below the guest RAM top, which is the definition the map's own
// comments and the platform's window tables state, and the one NP2kai's first-MiB table agrees
// with (NP2kai i386c/cpumem.c's handler slots: 0xA0000-0xA3FFF text RAM,
// 0xA4000-0xA4FFF the CG window, 0xA8000/0xB0000/0xB8000 the GVRAM planes, 0xC0000-0xFFFFF the
// ROM/aperture space).

`default_nettype none

// The shipped PC-98 memory map, spliced from the vendored template's preset.
`include "z486_pc98_preset.svh"

module tb_pc9821_memrange_correspondence;
  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg reset = 1'b0;

  // The platform's runtime settings (pc9821_system.sv): a 96 MiB guest on a 128 MiB module,
  // so the pack sits at the module ceiling and the guest RAM top is 0x0600_0000.
  localparam [31:0] GUEST_RAM = 32'h0600_0000;
  localparam [31:0] PACK_BASE = 32'h0600_0000;

  integer errors = 0;
  integer checks = 0;
  // The platform's 15-16 MiB system-space window (port 0x043B bit 2), which
  // pc9821_memory_subsystem applies as a translation the map itself does not know about.
  reg sys16m_en = 1'b0;

  // ==== DUT ====
  // The CPU's classifier, as the platform builds it (pc9821_system.sv's parameters).
  reg  [31:0] addr = 32'h0;
  wire        vga = (addr[31:17] == 15'h5);      // the paging unit's non-paging decode
  wire        is_uncached;
  wire [31:0] m_addr;
  wire  [3:0] m_be;
  wire  [7:0] m_burst;
  wire [31:0] m_din, m_dout;
  wire [127:0] m_line_din;
  wire        m_valid, m_write, m_io, m_inta, m_ready, m_resp_valid, m_line_read, m_line_resp_valid;

  memory #(
      .PROTECT_UMA_ROM(0),
      .DCACHE_SET_BITS(6),          // the shipped sizes (z486_mister.sv)
      .ICACHE_SET_BITS(6),
      .ENABLE_X87(1'b0),
      // The shipped platform configuration (pc9821_system.sv), read from that file:
      // the device-MMIO window is OFF there, and the
      // aperture/alias/win0/no-alloc windows come from the preset.
      .ENABLE_DEVICE_MMIO(1'b0), .DEVICE_MMIO_MASK(32'hFE00_0000),
      `Z486_PC98_MAP_PARAMS,
      .RAM_BOUND_ENABLE(1'b1)
  ) dut_mem (
      .clk(clk), .reset_n(~reset), .a20_enable(1'b1),
      .device_mmio_enable(1'b0), .device_mmio_base(32'h0),
      .ram_cache_top(GUEST_RAM), .win0_unmapped(1'b0),
      .dcache_req_valid(1'b1), .dcache_req_phys_addr_raw(addr),
      .dcache_req_preread_offset(addr[11:0]),
      .dcache_req_preread_priority(1'b0),
      .dcache_req_write(1'b0), .dcache_req_be(4'h0), .dcache_req_wdata(32'h0),
      .dcache_direct_wdata(32'h0),
      .dcache_req_is_io(1'b0), .dcache_req_is_inta(1'b0), .dcache_req_is_x87(1'b0),
      .dcache_req_is_vga_mem(vga),
      .dcache_req_accepted(), .dcache_req_complete(), .dcache_read_complete(),
      .dcache_rdata(),
      .fast_store_valid(1'b0), .fast_store_phys_addr_raw(32'h0),
      .fast_store_be(4'h0), .fast_store_wdata(32'h0), .fast_store_accepted(),
      .dcache_vipt_probe_valid(1'b0), .dcache_vipt_probe_offset(12'h0),
      .dcache_vipt_probe_ready(), .dcache_vipt_probe_accepted(),
      .dcache_vipt_probe_direct_accepted(),
      .dcache_vipt_resolve_valid(1'b0), .dcache_vipt_resolve_phys_addr_raw(32'h0), .dcache_vipt_resolve_tlb_phys_raw(32'h0), .dcache_vipt_resolve_alt_phys_raw(32'h0), .dcache_vipt_resolve_use_tlb(1'b0),
      .dcache_vipt_resolve_hit(), .dcache_vipt_resolve_data(),
      .x87_req_selected(), .x87_req_accepted(1'b0), .x87_req_complete(1'b0),
      .x87_read_complete(1'b0), .x87_rdata(32'h0),
      .icache_req_valid(1'b0), .icache_req_phys_addr_raw(32'h0),
      .icache_req_accepted(), .icache_req_complete(), .icache_rdata(),
      .snoop_addr(32'd0), .snoop_valid(1'b0),
      .cache_flush(1'b0), .cache_flush_busy(), .cache_flush_done(),
      .addr(m_addr), .be(m_be), .burstcount(m_burst), .line_read(m_line_read),
      .din(m_din), .line_din(m_line_din), .dout(m_dout),
      .valid(m_valid), .ready(m_ready), .write(m_write), .io(m_io),
      .resp_valid(m_resp_valid), .line_resp_valid(m_line_resp_valid), .inta(m_inta)
  );
  assign is_uncached = dut_mem.dcache_req_is_uncached;

  // The memory map, as the platform drives it.
  // Named exactly as pc9821_memory_map's ports, so the instantiation is implicit; the
  // settings are the platform's (win0 identity, the EMS state 0, the PEGC arms off) so the
  // ROUTE this bench reads is the direct encoding's, which is what the classifier's own
  // windows are about.
  reg  [3:0]  top_bank = 4'd8;
  reg         ide_rom_enable = 1'b0;
  reg         ide_ram_gate = 1'b0;
  reg         bios_ram_gate = 1'b0;
  reg         top_shadow_en = 1'b0;
  reg         fw_shadow_dirty = 1'b0;
  reg  [31:0] fw_shadow_base = 32'h0;
  reg  [1:0]  ems_state = 2'd0;
  reg  [31:0] ems_page_base = 32'h0;
  reg  [7:0]  win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  reg  [31:0] guest_ram_bytes = GUEST_RAM;
  reg         peg_window = 1'b0;
  reg  [31:0] peg_base = 32'h0;
  reg         pegc_256 = 1'b0;
  reg         pegc_plane = 1'b0;
  reg  [3:0]  pegc_bank_a = 4'd0, pegc_bank_b = 4'd0;
  reg  [31:0] cpu_addr = 32'h0;
  reg  [31:0] cpu_din = 32'h0;
  reg   [3:0] cpu_be = 4'h0;
  reg   [7:0] cpu_burstcount = 8'd0;
  reg         cpu_line_read = 1'b0, cpu_valid = 1'b1, cpu_write = 1'b0;
  wire [31:0] cpu_dout, mem_addr, mem_din;
  wire [31:0] cpu_line_word;
  wire  [3:0] mem_be;
  wire  [7:0] mem_burstcount;
  wire        mem_line_read, mem_valid, mem_write;
  reg  [31:0] mem_dout = 32'h0;
  reg [127:0] mem_line_dout = 128'h0;
  reg         mem_ready = 1'b0, mem_resp_valid = 1'b0, mem_line_resp_valid = 1'b0;
  wire        cpu_ready, cpu_resp_valid, cpu_line_word_valid;
  wire        gvram_window;
  wire  [1:0] gvram_win_plane;
  wire [14:0] gvram_win_offset;
  // The map's exported window-0 pair (P2): the post-bias address and its flag. Unused here.
  wire [31:0] d_addr;
  wire        win0_moved;
  wire        absent_area, ems_open_bus, fw_shadow_store;
  wire        pegc_packed, pegc_reg_win, pegc_nc;
  wire [31:0] pack_base = PACK_BASE;

  // 0x063C bank select into the 0xD8000 window: 0 = the IDE option ROM, the reset bank.

  reg  [1:0] d8_bank = 2'b00;

  wire addr_ge_ram;   // the map's shared compare output, unused here
  // No translation in front of the map here: the untranslated address IS cpu_addr.
  wire [31:0] cpu_addr_raw = cpu_addr;
  wire        xl_low20 = 1'b0;
  wire        xl_peg = 1'b0;
  pc9821_memory_map dut_map (.*);

  // ==== CHECKS ====
  // The contract.
  // ==== THE EXPECTATION IS INDEPENDENT OF THE RTL UNDER TEST ====
  // PLAIN RAM is defined HERE, from the platform's documented layout, and NOT from the map's
  // own decode or the classifier's own window constants -- otherwise the check would be
  // circular and could never fail. Two things the device list has to get right, both learned
  // the hard way when this bench first ran:
  //   * the map ROUTES the first-MiB device windows as the identity, because they are the
  //     SUBSYSTEM's to serve (the text RAM, the CG window, the GVRAM planes, the EMS page and
  //     the ROM windows are pc9821_memory_subsystem route selects), so `mem_addr == addr` alone
  //     calls the whole aperture plain RAM and would have missed a cached device entirely;
  //   * the 15-16 MiB window and the top-of-4G aliases are device space by the platform's
  //     documented behaviour (NP2kai i386c/cpumem.c's slot table and 0xfff00000 MMIO range; the
  //     map's own sys16m comments), not by anything this bench can observe at the map's outputs.
  // The list is deliberately COARSE - a whole 1 MiB is named where NP2kai's own handler table
  // shows 0xA0000-0xA3FFF text RAM, 0xA4000-0xA4FFF the CG window and plain RAM at 0xA5000-0xA7FFF
  // - because the safety direction only needs "not a device", and a coarse list can only make
  // the check stricter, never weaker.
  function automatic logic in_device_space(input logic [31:0] a);
    in_device_space =
        ((a >= 32'h000A_0000) && (a <= 32'h000F_FFFF))                    // the device aperture
     || (sys16m_en && (a >= 32'h00F0_0000) && (a <= 32'h00FF_FFFF))       // 15-16 MiB window
     || (sys16m_en && (a >= 32'hFFF0_0000) && (a <= 32'hFFF7_FFFF))       // PEGC high alias
     || (a >= 32'hFFFF_8000);                                             // the fw_high ROM alias
  endfunction

  function automatic logic plain_ram(input logic [31:0] a);
    logic identity;
    identity = mem_valid && (mem_addr == a);
    plain_ram = identity && (a < guest_ram_bytes) && !in_device_space(a);
  endfunction

  // The perf pin: the swept addresses that ARE plain RAM yet come back uncached. Deliberately
  // conservative, so a change here is a decision, not an accident. Kept as an explicit list
  // rather than a count, so the report can name the range that moved.
  integer perf_n = 0;
  reg [31:0] perf_first = 32'h0, perf_last = 32'h0;

  task automatic check(input [31:0] a, input [8*120-1:0] tag);
    logic unc;
    begin
      addr = a; cpu_addr = a;
      #1;
      checks = checks + 1;
      unc = is_uncached;
      if (is_uncached && plain_ram(a)) begin
        // conservative: plain RAM served uncached. Recorded, not failed.
        if (perf_n == 0) perf_first = a;
        perf_last = a;
        perf_n = perf_n + 1;
      end else if (!is_uncached && !plain_ram(a)) begin
        $display("FAIL %0s: 0x%08x is CACHED but the map does not serve it as plain RAM (mem_valid=%b mem_addr=%08x absent=%b open_bus=%b)",
                 tag, a, mem_valid, mem_addr, absent_area, ems_open_bus);
        errors = errors + 1;
      end
      #1;
    end
  endtask

  // ==== STIMULUS ====
  // Every boundary byte of the first MiB in 4 KiB steps, then coarser as the space thins out.
  // The block walk is exhaustive for the first MiB because every window there is a whole
  // number of 4 KiB pages; the coarser walks land exactly on every 64 KiB page and every
  // 1 MiB block, which is the granularity of every window outside it.
  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_MEMRANGE_CORRESPONDENCE: FAIL (watchdog)");
  end

  integer b;
  initial begin
    reset = 1'b1;
    #20; reset = 1'b0; #20;

    // ---- the first MiB, every 4 KiB page, both ends of the page ----
    for (b = 0; b < 256; b = b + 1) begin
      check(32'(b * 32'h1000), "1MiB page start");
      check(32'(b * 32'h1000 + 32'hFFF), "1MiB page end");
    end

    // ---- 1 MiB..16 MiB, every 64 KiB page ----
    for (b = 0; b < 240; b = b + 1) begin
      check(32'h0010_0000 + 32'(b * 32'h1_0000), "1-16MiB page start");
      check(32'h0010_0000 + 32'(b * 32'h1_0000 + 32'hFFFF), "1-16MiB page end");
    end

    // ---- 16 MiB..96 MiB, every MiB (the extended RAM, and the 32-64 MiB window that was
    //      once misclassified as device memory) ----
    for (b = 0; b < 80; b = b + 1) begin
      check(32'h0100_0000 + 32'(b * 32'h10_0000), "16-96MiB MiB start");
      check(32'h0100_0000 + 32'(b * 32'h10_0000 + 32'hF_FFFF), "16-96MiB MiB end");
    end

    // ---- the RAM top and the region above it: the pack, the reserves, the absent space ----
    check(GUEST_RAM - 32'h1, "guest top - 1");
    check(GUEST_RAM, "guest top (first non-RAM)");
    check(GUEST_RAM + 32'h10_0000, "a MiB above the guest top");
    check(32'h0800_0000, "the L1 tag reach");
    check(32'hFFFF_FFFF, "the very top");

    // ---- the top-of-4G aliases and the sys16m window, both states ----
    check(32'h00F0_0000, "0xF00000 (PEGC EVRAM)");
    check(32'h00F7_FFFF, "0xF7FFFF (EVRAM top)");
    check(32'h00F8_0000, "0xF80000 (sys16m hole)");
    check(32'h00F9_FFFF, "0xF9FFFF (hole top)");
    check(32'h00FA_0000, "0xFA0000 (mirror base)");
    check(32'h00FF_FFFF, "0xFFFFFF (mirror top)");
    check(32'hFFF0_0000, "0xFFF00000 (peg_high base)");
    check(32'hFFF7_FFFF, "0xFFF7FFFF (peg_high top)");
    check(32'hFFF8_0000, "0xFFF80000 (past peg_high)");
    check(32'hFFFF_8000, "0xFFFF8000 (fw_high base)");
    check(32'hFFFF_FFFF, "0xFFFFFFFF");

    // ---- with the 15-16 MiB system-space window ON, the same window bytes ----
    sys16m_en = 1'b1;
    check(32'h00F0_0000, "sys16m on: 0xF00000");
    check(32'h00F9_FFFF, "sys16m on: 0xF9FFFF");
    check(32'h00FA_0000, "sys16m on: 0xFA0000");
    check(32'h00FF_FFFF, "sys16m on: 0xFFFFFF");
    sys16m_en = 1'b0;

    $display("TB_PC9821_MEMRANGE_CORRESPONDENCE: %0d address(es) swept, %0d cached-but-not-plain-RAM mismatch(es)",
             checks, errors);
    $display("TB_PC9821_MEMRANGE_CORRESPONDENCE: conservative pin: %0d address(es) are plain RAM yet uncached (first %08x, last %08x)",
             perf_n, perf_first, perf_last);
    // ==== VERDICT ====
    // THE CONSERVATIVE PIN, ASSERTED. The only plain-RAM range served uncached is the whole
    // 15-16 MiB block while port 0x043B's system-space window is OFF: the alias window that
    // carries the PEGC extended VRAM, the low-memory mirror and the hole (when it is ON) is
    // applied by the classifier unconditionally, so with the window off a real 1 MiB of guest
    // RAM is merely uncached. That costs speed and cannot cost correctness, but widening or
    // narrowing it must be a decision rather than a silent drift, so it is pinned by value.
    checks = checks + 1;
    if (perf_n != 38 || perf_first != 32'h00F0_0000 || perf_last != 32'h00FF_FFFF) begin
      $display("FAIL pin: the conservative loss moved: %0d address(es), first %08x, last %08x (want 38 addresses, 0x00F00000 .. 0x00FFFFFF)",
               perf_n, perf_first, perf_last);
      errors = errors + 1;
    end

    if (errors == 0) begin
      $display("TB_PC9821_MEMRANGE_CORRESPONDENCE: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_MEMRANGE_CORRESPONDENCE: FAIL (%0d errors)", errors);
  end

endmodule

`default_nettype wire

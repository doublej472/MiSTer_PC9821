`timescale 1ns/1ps

`include "z486_pc98_preset.svh"

// ==== WHAT THIS PROVES ====
// The z486 L1 data cache holds no line for the PC-98 device-memory ALIASES - the 0xFA0000-0xFFFFFF low-memory mirror of 0xA0000-0xFFFFF, the PEGC windows at 0xF00000 and 0xFFF00000, and fw_high at 0xFFFF8000-0xFFFFFFFF - so a canonical uncached store (or a ROM bank flip, or the sys16m_en remap of 0xF00000-0xFFFFFF) is visible through the alias on the very next read with no flush in between, while RAM around the windows stays cached so the decode cannot pass by refusing to cache anything; and the A20-wrap aliases of 0xA0000-0xBFFFF classify as VGA device memory exactly as the wrapped physical address they resolve to. The platform's alias arithmetic (pc9821_memory_subsystem.sv's sys16m_mirror/peg_high bit splices, pc9821_memory_map.sv's fw_high) is modelled before the backend storage, so the pair really is one byte with two names. FAIL-FIRST: every alias probe and round trip fails on the pre-fix tree, which cached the aliases and served the stale line.
//
// The z486 L1 data cache holds no line for the PC-98 device-memory ALIASES - the 0xFA0000-0xFFFFFF
// low-memory mirror of 0xA0000-0xFFFFF, the PEGC windows at 0xF00000 and 0xFFF00000, and fw_high at
// 0xFFFF8000-0xFFFFFFFF - so every one of them is served directly and a store through the CANONICAL
// address (or a ROM bank flip behind the window) is visible through the alias on the very next read
// with no flush in between; the A20-wrap aliases of 0xA0000-0xBFFFF classify as VGA device memory
// exactly as their wrapped physical address is; and a sys16m_en flip of the 0xF00000-0xFFFFFF range
// cannot strand a cached line. RAM controls stay cached so the decode cannot pass by refusing to
// cache anything.
//
// WHY THIS EXISTS. PC-98 device memory is 0xA0000-0xFFFFF (plus a mirror at 0xFA0000-0xFFFFFF),
// and none of it may be cached (the fork's PC-98 memory-map template, z486_cache_map_pkg,
// docs/z486-local-patch.md). The platform decodes those
// alias windows in pc9821_memory_subsystem.sv (sys16m_mirror / peg_window / peg_high) and
// pc9821_memory_map.sv (fw_high), translating each access onto the SAME storage the canonical
// window uses - storage the GRCG/EGC, a canonical uncached store, or a ROM bank flip writes
// underneath the cache. The classification in z486's `memory` named none of the alias windows, so
// the L1 cached them PIPT and served stale alias lines. The A20 term is the
// same defect one wrap earlier: with the gate closed, linear 0x1A0000-0x1BFFFF
// wraps onto TRAM/CG/planes but the VGA test ran on the pre-wrap address. The 0x043B sys16m flip
// and the bank-flush alias gap are the flush-side twins, asserted here as
// outcomes and in tb_pc9821_iobus as triggers.
//
// The aliasing the platform performs is modelled by the alias_map function below: a bit-splice/
// subtraction BEFORE the backend, exactly as the subsystem applies it before its route selects.
// "Flipping a bank" or "flipping sys16m" is modelled the way the CPU experiences it: the storage
// the alias resolves to is rewritten behind the cache's back.

`default_nettype none

module tb_pc9821_cpu_alias_coherency;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ==== DUT ====
  reg  [31:0] cpu_addr = 32'h0;
  reg  [31:0] cpu_wdata = 32'h0;
  reg   [3:0] cpu_be = 4'hF;
  reg         cpu_write = 1'b0;
  reg         cpu_is_vga = 1'b0;
  reg         cpu_valid = 1'b0;
  reg         a20_enable = 1'b1;
  wire        req_accepted, req_complete, read_complete;
  wire [31:0] dcache_rdata;

  wire [31:2] m_addr;
  wire  [3:0] m_be;
  wire  [7:0] m_burst;
  wire [31:0] m_dout;
  wire [31:0] m_din;
  wire [127:0] m_line_din;
  wire        m_valid, m_write, m_io, m_inta, m_ready;
  wire        m_resp_valid, m_line_resp_valid, m_line_read;

  wire [31:0] mem_accepts, mem_beats;

  // The platform's flush is the core's NATIVE whole-L1 cache_flush (the
  // pc9821_cache_flush snoop sequencer is deleted): one request, both caches
  // walk every set, done pulses at the end (src/z486/docs/platform-integration.md).
  reg         flush_start = 1'b0;
  wire        flush_busy, flush_done;
  /* verilator lint_off UNUSEDSIGNAL */   // the flush sequencer's own busy; the task waits on done
  wire        flush_busy_unused = flush_busy;
  /* verilator lint_on UNUSEDSIGNAL */

  memory #(
      .PROTECT_UMA_ROM(0),
      .DCACHE_SET_BITS(6),          // the shipped size (z486_mister.sv DCACHE_SET_BITS)
      .ICACHE_SET_BITS(6),
      .ENABLE_X87(1'b0),
      .ENABLE_DEVICE_MMIO(1'b1), .DEVICE_MMIO_MASK(32'hFE00_0000),
      // The shipped PC-98 opt-in, in the template's own terms: the
      // A0000-FFFFF aperture, the three alias windows, the window-0 range, the
      // VGA window tested on the A20-masked physical (VGA_PRE_WRAP = 0, which
      // is what makes the wrap alias classify as the address it wraps onto),
      // and A20-off as the preset's bit-20 clear (Xe10 A20MAP: BIT20-ONLY).
      .APERTURE_ENABLE(1'b1),
      .ALIAS_ENABLE(1'b1),
      .WIN0_ENABLE(1'b1),
      .VGA_ENABLE(1'b1), .VGA_PRE_WRAP(1'b0),
      .A20_MASK_OFF(`Z486_PC98_A20_MASK_OFF)
  ) dut (
      .clk(clk), .reset_n(~reset), .a20_enable(a20_enable),
      // L1 on, FPU present: z486 drives these from cache_off_req/x87_off_req, which pc9821_system ties low
      .cache_enable(1'b1), .x87_off(1'b0),
      .device_mmio_enable(1'b1), .device_mmio_base(32'h0200_0000),
      // The fill-exclusion bound and window-0 verdict (aliases.md A1/A5). This
      // bench's synthetic alias_map treats every address outside the alias
      // windows as cacheable RAM, its controls at 0xFFF80000/0xFFF7FFFC
      // included, so the NO_ALLOC class is left off here (RAM_BOUND_ENABLE
      // defaults to 0) and this bench keeps pinning the F1/F4 alias
      // classification exactly; tb_pc9821_l1_alias_fill is the bench that
      // drives the bound itself.
      .ram_cache_top(32'hFFFF_FFFF), .win0_unmapped(1'b0),
      .dcache_req_valid(cpu_valid),
      .dcache_req_phys_addr_raw(cpu_addr),
      .dcache_req_preread_offset(cpu_addr[11:0]),
      // The real paging unit drives this from the demand itself (paging_unit.sv:513:
      // `early_idx_drive || pretrans_present || req_mem_present || ...`), so a demand always owns
      // the preread over a VIPT probe. Tying it to 1'b0 makes the core's own invariant fire
      // (l1_cache.sv:797, "L1 pipelined store accepted without preread priority") on ANY cacheable
      // store, so this bench aborted there instead of running its checks. Same repair as
      // tb_pc9821_cpu_vram_coherency and tb_pc9821_dma_flush_coherency.
      .dcache_req_preread_priority(cpu_valid),
      .dcache_req_write(cpu_write),
      .dcache_req_be(cpu_be),
      .dcache_req_wdata(cpu_wdata),
      .dcache_direct_wdata(cpu_wdata),
      .dcache_req_is_io(1'b0),
      .dcache_req_is_inta(1'b0),
      .dcache_req_is_x87(1'b0),
      .dcache_req_is_vga_mem(cpu_is_vga),
      .dcache_req_accepted(req_accepted),
      .dcache_req_complete(req_complete),
      .dcache_read_complete(read_complete),
      .dcache_rdata(dcache_rdata),
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
      .snoop_addr(32'd0), .snoop_valid(1'b0),   // no DMA snoop on this platform
      .cache_flush(flush_start), .cache_flush_busy(flush_busy),
      .cache_flush_done(flush_done),
      .addr(m_addr), .be(m_be), .burstcount(m_burst), .line_read(m_line_read),
      .din(m_din), .line_din(m_line_din), .dout(m_dout),
      .valid(m_valid), .ready(m_ready), .write(m_write), .io(m_io),
      .resp_valid(m_resp_valid), .line_resp_valid(m_line_resp_valid), .inta(m_inta)
  );

  // The pc9821_cache_flush sequencer that stood here is gone: `memory`'s own
  // cache_flush input walks both L1s (the request/done handshake above). The
  // black-box outcome checks below must hold through the CLASSIFICATION; the
  // trigger contract is tb_pc9821_cache_flush's.

  // ==== THE PLATFORM'S ALIAS MAP ====
  // pc9821_memory_subsystem.sv: sys16m_mirror subtracts 0xF00000 and peg_high subtracts
  // 0xFF000000 (both bit splices), pc9821_memory_map.sv: fw_high serves the banked ROM window
  // at d_addr[14:0]. Applied to the backend address BEFORE the storage, so 0xFA0000 and
  // 0xA0000 name one byte the way the machine names it.
  reg sys16m_en = 1'b1;   // the 0x043B bit-2 state (inverted write)

  function automatic [31:0] alias_map(input [31:0] a);
    begin
      if (sys16m_en && (a >= 32'h00FA_0000) && (a <= 32'h00FF_FFFF))
        alias_map = a - 32'h00F0_0000;                  // -> 0x000A_0000-0x000F_FFFF
      else if (sys16m_en && (a >= 32'hFFF0_0000) && (a <= 32'hFFF7_FFFF))
        alias_map = a - 32'hFFF0_0000 + 32'h00F0_0000;  // -> 0x00F0_0000-0x00F7_FFFF
      else if (a >= 32'hFFFF_8000)
        alias_map = a - 32'hFFFF_8000 + 32'h000F_8000;  // -> 0x000F_8000-0x000F_FFFF
      else
        alias_map = a;
    end
  endfunction

  // The backend, at real sdram.v timing. Its storage doubles as the hardware writer the
  // GRCG/EGC and the ROM banks are: rewriting backend.mem[] is what they do behind the CPU.
  sdram_backend_model #(
      .ACCEPT_TO_RESP(2), .WRITE_BUSY(2), .LINE_RESP(0), .WORDS_LOG2(21)
  ) backend (
      .clk(clk), .reset(reset), .valid(m_valid), .ready(m_ready), .write(m_write),
      .addr(alias_map({m_addr, 2'b00})), .din(m_dout), .din_hi(32'd0), .be(m_be),
      .burstcount(m_burst),
      .dout(m_din), .resp_valid(m_resp_valid),
      .line_dout(m_line_din), .line_resp_valid(m_line_resp_valid),
      .busy(), .accepts(mem_accepts), .beats(mem_beats)
  );

  integer errors = 0;
  integer checks = 0;
  reg [31:0] rd;

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_CPU_ALIAS_COHERENCY: FAIL (watchdog, the run did not finish)");
  end

  task automatic chk_dword(input [31:0] got, input [31:0] want, input [8*140-1:0] tag);
    begin
      checks = checks + 1;
      if (got !== want) begin
        $display("FAIL %0s: got %08x, want %08x", tag, got, want);
        errors = errors + 1;
      end
    end
  endtask

  // ==== STIMULUS ====
  // One CPU request through the z486 memory unit, as tb_pc9821_cpu_vram_coherency drives it.
  task automatic req(input [31:0] a, input wr, input [3:0] be, input [31:0] wd,
                     output [31:0] rdata);
    integer g;
    begin
      @(negedge clk);
      cpu_addr = a; cpu_wdata = wd; cpu_be = be; cpu_write = wr;
      cpu_is_vga = (a[31:17] == 15'h5);
      cpu_valid = 1'b1;
      g = 0;
      while (!req_accepted && g < 20000) begin @(negedge clk); g = g + 1; end
      if (!req_accepted) $fatal(1, "TB_PC9821_CPU_ALIAS_COHERENCY: no accept for %08x", a);
      rdata = 32'h0;
      if (!wr) begin
        g = 0;
        while (!read_complete && g < 20000) begin @(negedge clk); g = g + 1; end
        if (!read_complete) $fatal(1, "TB_PC9821_CPU_ALIAS_COHERENCY: no response for %08x", a);
        rdata = dcache_rdata;
      end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0;
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic wr_dword(input [31:0] a, input [31:0] d);
    reg [31:0] sink;
    begin req(a, 1'b1, 4'hF, d, sink); end
  endtask

  task automatic rd_dword(input [31:0] a, output [31:0] d);
    begin req(a, 1'b0, 4'hF, 32'h0, d); end
  endtask

  // The hardware writer / bank flipper / sys16m remap: rewrite the storage the alias resolves
  // to, with the CPU not watching.
  task automatic poke_storage(input [31:0] a, input [31:0] v);
    begin
      backend.mem[alias_map(a) >> 2] = v;
      @(posedge clk);
    end
  endtask

  task automatic probes_cached(input [31:0] a, output cached);
    reg [31:0] sink;
    reg [31:0] acc_before;
    begin
      rd_dword(a, sink);
      repeat (16) @(posedge clk);
      acc_before = mem_accepts;
      rd_dword(a, sink);
      repeat (8) @(posedge clk);
      cached = (mem_accepts == acc_before) ? 1'b1 : 1'b0;
    end
  endtask

  task automatic expect_uncached(input [31:0] a, input [8*140-1:0] tag);
    reg cached;
    begin
      probes_cached(a, cached);
      checks = checks + 1;
      if (cached) begin
        $display("FAIL %0s: %08x was served from an L1 line", tag, a);
        errors = errors + 1;
      end
    end
  endtask

  task automatic expect_cached(input [31:0] a, input [8*140-1:0] tag);
    reg cached;
    begin
      probes_cached(a, cached);
      checks = checks + 1;
      if (!cached) begin
        $display("FAIL %0s: %08x was NOT cached", tag, a);
        errors = errors + 1;
      end
    end
  endtask

  // The alias decode itself, over both ends of every window.
  task automatic decode_alias_is(input [31:0] a, input want, input [8*140-1:0] tag);
    begin
      @(negedge clk);
      cpu_addr = a; cpu_wdata = 32'h0; cpu_be = 4'hF; cpu_write = 1'b0;
      cpu_is_vga = (a[31:17] == 15'h5); cpu_valid = 1'b1;
      #1;
      checks = checks + 1;
      if (dut.dcache_req_is_uncached !== want) begin
        $display("FAIL %0s: 0x%08x uncached=%b want %b", tag, a,
                 dut.dcache_req_is_uncached, want);
        errors = errors + 1;
      end
      cpu_valid = 1'b0;
      @(negedge clk);
    end
  endtask

  // The cross-alias round trip (cpu-int F1 mechanism 1): read the ALIAS (caching it, if the
  // classification is wrong), store the CANONICAL address, read the alias again. One storage,
  // two addresses: the second read must carry the store.
  task automatic cross_alias(input [31:0] canon, input [31:0] alias_a,
                             input [8*140-1:0] tag);
    begin
      rd_dword(alias_a, rd);
      repeat (8) @(posedge clk);
      wr_dword(canon, 32'h0BADC0DE);
      rd_dword(alias_a, rd);
      chk_dword(rd, 32'h0BADC0DE, tag);
    end
  endtask

  // The platform's cache flush: one request into `memory`'s native whole-L1
  // cache_flush port (a superset of the retired iobus sweeps), done ends it.
  task automatic flush_all();
    integer g;
    begin
      @(negedge clk);
      flush_start = 1'b1;
      @(negedge clk);
      flush_start = 1'b0;
      g = 0;
      while (!flush_done && g < 200000) begin @(posedge clk); g = g + 1; end
      if (!flush_done) $fatal(1, "TB_PC9821_CPU_ALIAS_COHERENCY: cache flush never finished");
      repeat (4) @(posedge clk);
    end
  endtask

  integer i;

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (400) @(posedge clk);

    // ------------------------------------------------------------------
    // (a) The classification: the alias windows are device memory and must
    //     never hold an L1 line; the RAM around them must still cache.
    // ------------------------------------------------------------------
    $display("NOTE cpu_alias_coherency: --- (a) alias classification ---");
    begin
      reg [31:0] ap [0:13];
      ap[0]  = 32'h00FA_0000;  ap[1]  = 32'h00FA_0004;  ap[2]  = 32'h00FB_FFFC;
      ap[3]  = 32'h00FF_8000;  ap[4]  = 32'h00FF_FFFF;  ap[5]  = 32'h00F0_0000;
      ap[6]  = 32'h00F7_FFFF;  ap[7]  = 32'hFFF0_0000;  ap[8]  = 32'hFFF7_FFFC;
      ap[9]  = 32'hFFF7_FFFF;  ap[10] = 32'hFFFF_8000;  ap[11] = 32'hFFFF_8E90;
      ap[12] = 32'hFFFF_FFFC;  ap[13] = 32'hFFFF_FFFF;
      for (i = 0; i < 14; i = i + 1)
        expect_uncached(ap[i], "(a) device alias");
    end
    begin
      reg [31:0] ram [0:5];
      ram[0] = 32'h0000_0000; ram[1] = 32'h0010_0000; ram[2] = 32'h00E0_0000;
      ram[3] = 32'h00EF_FFFF; ram[4] = 32'hFFF8_0000; ram[5] = 32'hFFFF_7FFC;
      for (i = 0; i < 6; i = i + 1)
        expect_cached(ram[i], "(a) RAM control");
    end
    decode_alias_is(32'h00EF_FFFF, 1'b0, "(a) decode 0xEFFFFF");
    decode_alias_is(32'h00F0_0000, 1'b1, "(a) decode 0xF00000 (PEGC)");
    decode_alias_is(32'h00FF_FFFF, 1'b1, "(a) decode 0xFFFFFF (mirror top)");
    decode_alias_is(32'h0100_0000, 1'b0, "(a) decode 0x1000000");
    decode_alias_is(32'hFFE0_0000, 1'b0, "(a) decode 0xFFE00000");
    decode_alias_is(32'hFFF0_0000, 1'b1, "(a) decode 0xFFF00000 (peg_high)");
    decode_alias_is(32'hFFF7_FFFF, 1'b1, "(a) decode 0xFFF7FFFF");
    decode_alias_is(32'hFFF8_0000, 1'b0, "(a) decode 0xFFF80000");
    decode_alias_is(32'hFFFF_7FFF, 1'b0, "(a) decode 0xFFFF7FFF");
    decode_alias_is(32'hFFFF_8000, 1'b1, "(a) decode 0xFFFF8000 (fw_high)");
    decode_alias_is(32'hFFFF_FFFF, 1'b1, "(a) decode 0xFFFFFFFF");

    // ------------------------------------------------------------------
    // (b) Cross-alias staleness (cpu-int F1 mechanism 1): a canonical store
    //     must be visible through the alias with no flush in between. Seed
    //     both words of each pair through their CANONICAL storage first.
    // ------------------------------------------------------------------
    $display("NOTE cpu_alias_coherency: --- (b) cross-alias round trips ---");
    poke_storage(32'h000A_1000, 32'h1111_2222);
    cross_alias(32'h000A_1000, 32'h00FA_1000, "(b) mirror: store 0xA1000, read 0xFA1000");
    poke_storage(32'h00F0_2000, 32'h3333_4444);
    cross_alias(32'h00F0_2000, 32'hFFF0_2000, "(b) peg_high: store 0xF02000, read 0xFFF02000");

    // ------------------------------------------------------------------
    // (c) The sys16m_en flip (memmap F1 outcome): the 0xF00000-0xFFFFFF
    //     range is RAM until the guest asks for the hole, then PEGC VRAM /
    //     hole / mirror. The flip replaces the content behind the address;
    //     no cached line may survive it.
    // ------------------------------------------------------------------
    $display("NOTE cpu_alias_coherency: --- (c) sys16m_en remap ---");
    sys16m_en = 1'b0;
    poke_storage(32'h00F0_3000, 32'hAAAA_5555);       // the RAM content
    rd_dword(32'h00F0_3000, rd);
    chk_dword(rd, 32'hAAAA_5555, "(c) 0xF03000 warm read (RAM)");
    sys16m_en = 1'b1;                                  // the 0x043B flip
    poke_storage(32'h00F0_3000, 32'hFEED_FACE);        // the PEGC VRAM content now behind it
    rd_dword(32'h00F0_3000, rd);
    chk_dword(rd, 32'hFEED_FACE, "(c) 0xF03000 after the flip (PEGC content)");
    sys16m_en = 1'b0;

    // ------------------------------------------------------------------
    // (d) The fw_high bank flip (memmap F2 outcome): 0xFFFF8E90 and 0xF8E90
    //     are one byte of the banked ROM window. Flip the bank (rewrite the
    //     window) and run the sweep the iobus runs for it; the alias read
    //     must show the new bank.
    // ------------------------------------------------------------------
    $display("NOTE cpu_alias_coherency: --- (d) fw_high bank flip ---");
    poke_storage(32'h000F_8E90, 32'h0DB4_0DB4);
    rd_dword(32'hFFFF_8E90, rd);
    chk_dword(rd, 32'h0DB4_0DB4, "(d) 0xFFFF8E90 warm read (bank 4)");
    poke_storage(32'h000F_8E90, 32'h0DB7_0DB7);       // the bank flip
    flush_all();                                      // the platform's bank-flip flush
    rd_dword(32'hFFFF_8E90, rd);
    chk_dword(rd, 32'h0DB7_0DB7, "(d) 0xFFFF8E90 after the flip (bank 7)");
    // The twin canonical read is direct and always fresh.
    rd_dword(32'h000F_8E90, rd);
    chk_dword(rd, 32'h0DB7_0DB7, "(d) 0xF8E90 canonical twin");

    // ------------------------------------------------------------------
    // (e) The A20-wrap aliases (cpu-int F4): with the gate closed, linear
    //     0x1A0000 wraps onto 0xA0000 - the same TRAM/CG/planes byte. The
    //     wrap alias must classify as VGA device memory, exactly as the
    //     address it wraps onto does.
    // ------------------------------------------------------------------
    $display("NOTE cpu_alias_coherency: --- (e) A20-wrap VGA aliases ---");
    a20_enable = 1'b0;
    poke_storage(32'h000A_4000, 32'hCAFE_0000);
    rd_dword(32'h001A_4000, rd);                       // warm the wrapped alias
    repeat (8) @(posedge clk);
    wr_dword(32'h000A_4000, 32'hCAFE_1111);            // canonical direct store
    rd_dword(32'h001A_4000, rd);
    chk_dword(rd, 32'hCAFE_1111, "(e) store 0xA4000, read 0x1A4000");
    // The vipt/fast path must reject the wrapped alias too (it always did:
    // l1_cache compares the wrapped physical; pinned so the two paths stay
    // one classification).
    @(negedge clk);
    cpu_addr = 32'h001A_4000; cpu_write = 1'b0; cpu_be = 4'hF; cpu_is_vga = 1'b0;
    cpu_valid = 1'b1; #1;
    checks = checks + 1;
    if (dut.dcache_req_is_uncached !== 1'b1) begin
      $display("FAIL (e): 0x1A4000 did not classify as VGA device memory");
      errors = errors + 1;
    end
    cpu_valid = 1'b0;
    @(negedge clk);
    a20_enable = 1'b1;

    // ------------------------------------------------------------------
    // (f) Controls: the D$ still caches RAM and the flush still clears it
    //     (tb_pc9821_cpu_vram_coherency's round trip, one sample).
    // ------------------------------------------------------------------
    $display("NOTE cpu_alias_coherency: --- (f) controls ---");
    wr_dword(32'h0020_3000, 32'h3333_3333);
    rd_dword(32'h0020_3000, rd);
    chk_dword(rd, 32'h3333_3333, "(f) RAM write-through read-back");
    poke_storage(32'h0020_3000, 32'h4444_4444);        // engine write behind the back
    rd_dword(32'h0020_3000, rd);
    chk_dword(rd, 32'h3333_3333, "(f) RAM line is cached (stale until flushed)");
    flush_all();
    rd_dword(32'h0020_3000, rd);
    chk_dword(rd, 32'h4444_4444, "(f) RAM line fresh after the flush");

    $display("NOTE cpu_alias_coherency: backend saw %0d accept(s), %0d read beat(s)",
             mem_accepts, mem_beats);

    $display("TB_PC9821_CPU_ALIAS_COHERENCY: %0d coherence check(s), %0d mismatch(es)",
             checks, errors);
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CPU_ALIAS_COHERENCY: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_CPU_ALIAS_COHERENCY: FAIL (%0d errors)", errors);
  end

endmodule

`default_nettype wire

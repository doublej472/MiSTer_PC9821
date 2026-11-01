`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_CPU_VRAM_COHERENCY:
// The z486 L1 data cache holds no line for the PC-98 device aperture, so a CPU store to a VRAM-window address reads back byte-exact and a second read still reaches the backend; every aperture address from 0xC0000 to 0xFFFFF, the 0xE0000 intensity window included, is served directly while the RAM addresses below 0xC0000 and the A0000-BFFFF internal VGA aperture are classified the way the machine classifies them; an external writer (the EGC/GRCG, played by a direct write to the backend storage) changing VRAM behind the CPU's back is visible on the CPU's next read, and the platform's whole-L1 cache_flush clears the cached line so the flushed value is what the CPU sees on an address where the L1 really does hold one, with the self-modifying store/scanout-read/re-read round trip byte-exact at every step. The RAM above 32 MiB stays CACHEABLE and NOT device-classified (the platform's device-MMIO window is OFF, its old 32-64 MiB base having been the pack base for a 64 MB module while a 128 MB module lets the OSD's guest size reach 96 MiB, so 32 MiB of real guest RAM sat inside it L1-bypassed, and the runtime no-allocate bound above the guest RAM top already gives the memory-size probe the behaviour the window existed for), pinned by cacheability at 32, 48, just-below-64 and just-past-64 MiB with the dcache_req_is_device_mmio classifier asserted at both ends of the retired range.
//
// WHY THIS EXISTS. The CPU caches by physical address; the machine's VRAM is reached through
// device windows a hardware writer also writes. The fork's memory-map template
// (z486_cache_map_pkg, docs/z486-local-patch.md) declares 0xC0000-0xFFFFF uncached on top of the internal 0xA0000-0xBFFFF aperture, and an earlier analysis names the
// 0xE0000 intensity plane as the reason plane 3 has to stay out of the cache: it is the top bit
// of every 16-colour palette index. Nothing in the tree drove the L1 against that decode; the
// benches that exist check the GVRAM's OWN cache (tb_pc9821_gvram_coherence), not the CPU's.
// This bench drives the REAL z486 `memory` (the patched submodule) and its REAL native
// whole-L1 cache_flush path against a backend at real sdram.v timing.

`default_nettype none

module tb_pc9821_cpu_vram_coherency;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ==== DUT ====
  // CPU-side demand interface (what paging_unit drives). is_vga_mem is the paging unit's
  // non-paging decode: physical A0000-BFFFF. The device aperture is decoded inside `memory`.
  reg  [31:0] cpu_addr = 32'h0;
  reg  [31:0] cpu_wdata = 32'h0;
  reg   [3:0] cpu_be = 4'hF;
  reg         cpu_write = 1'b0;
  reg         cpu_is_vga = 1'b0;
  reg         cpu_valid = 1'b0;
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
  /* verilator lint_off UNUSED */   // the flush sequencer's own busy; the task waits on done
  wire        flush_busy_unused = flush_busy;
  /* verilator lint_on UNUSED */

  memory #(
      .PROTECT_UMA_ROM(0),
      .DCACHE_SET_BITS(6),          // the shipped size (z486_mister.sv DCACHE_SET_BITS)
      .ICACHE_SET_BITS(6),
      .ENABLE_X87(1'b0),
      // DEVICE-MMIO WINDOW: OFF, matching pc9821_system.sv.
      // Its 32-64 MiB base was the PACK BASE FOR A 64 MB SDRAM MODULE, not a property of the
      // machine, and on a 128 MB module the OSD's guest size reaches 96 MiB -- so 32 MiB of
      // real guest RAM sat inside the window and was served L1-bypassed. The runtime
      // no-allocate bound above the guest RAM top already gives the probe behaviour the window
      // was added for. The (b2) leg below is the fail-first proof: with the window ON every
      // probe there is served directly and dcache_req_is_device_mmio is 1.
      .ENABLE_DEVICE_MMIO(1'b0),
      // The shipped PC-98 opt-in, in the template's own terms (see
      // tb_pc9821_cpu_alias_coherency for the per-window reasoning).
      .APERTURE_ENABLE(1'b1),
      .ALIAS_ENABLE(1'b1),
      .WIN0_ENABLE(1'b1),
      .VGA_ENABLE(1'b1), .VGA_PRE_WRAP(1'b0),
      .A20_MASK_OFF(32'h000F_FFFF)
  ) dut (
      .clk(clk), .reset_n(~reset), .a20_enable(1'b1),
      // L1 on, FPU present: z486 drives these from cache_off_req/x87_off_req, which pc9821_system ties low
      .cache_enable(1'b1), .x87_off(1'b0),
      .device_mmio_enable(1'b0), .device_mmio_base(32'h0),
      // The fill-exclusion bound and window-0 verdict (aliases.md A1/A5):
      // disabled here (this bench pins the F1/F4 classification with the
      // pre-bound cache behaviour; tb_pc9821_l1_alias_fill drives the bound).
      .ram_cache_top(32'hFFFF_FFFF), .win0_unmapped(1'b0),
      .dcache_req_valid(cpu_valid),
      .dcache_req_phys_addr_raw(cpu_addr),
      .dcache_req_preread_offset(cpu_addr[11:0]),
      // The real paging unit drives this from the demand itself (paging_unit.sv:
      // `early_idx_drive || pretrans_present || req_mem_present || ...`), so a demand always
      // owns the preread over a VIPT probe. Tying it to 1'b0 makes the core's own invariant
      // fire (l1_cache.sv:797, "L1 pipelined store accepted without preread priority") on ANY
      // cacheable store -- which is why this bench aborted at its FIRST one and never reached
      // its checks on HEAD. Model the rule the stub can express: a presented demand reserves
      // the port. (Same repair as tb_pc9821_dma_flush_coherency's mcpu_valid.)
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
  // cache_flush input walks both L1s (the request/done handshake above).

  // The backend, at real sdram.v timing. Its storage doubles as the "hardware writer" the EGC
  // and GRCG are: writing backend.mem[] directly is what those engines do to VRAM.
  sdram_backend_model #(
      .ACCEPT_TO_RESP(2), .WRITE_BUSY(2), .LINE_RESP(0), .WORDS_LOG2(21)
  ) backend (
      .clk(clk), .reset(reset), .valid(m_valid), .ready(m_ready), .write(m_write),
      .addr({m_addr, 2'b00}), .din(m_dout), .din_hi(32'd0), .be(m_be), .burstcount(m_burst),
      .dout(m_din), .resp_valid(m_resp_valid),
      .line_dout(m_line_din), .line_resp_valid(m_line_resp_valid),
      .busy(), .accepts(mem_accepts), .beats(mem_beats)
  );

  integer errors = 0;
  integer checks = 0;
  reg [31:0] rd;

  // In-bench watchdog: a route that stops answering is a FAIL, not a stall.
  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_CPU_VRAM_COHERENCY: FAIL (watchdog, the run did not finish)");
  end

  task automatic fail(input [8*200-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

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
  // One CPU request through the z486 memory unit. A read completes on the response; a write
  // completes at the accept (the direct path) and is posted on the cache path.
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
      if (!req_accepted) $fatal(1, "TB_PC9821_CPU_VRAM_COHERENCY: no accept for %08x", a);
      rdata = 32'h0;
      if (!wr) begin
        g = 0;
        while (!read_complete && g < 20000) begin @(negedge clk); g = g + 1; end
        if (!read_complete) $fatal(1, "TB_PC9821_CPU_VRAM_COHERENCY: no response for %08x", a);
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

  // The hardware writer: the EGC/GRCG storing VRAM with the CPU not watching. The storage is
  // the backend model's own array, indexed the way the model itself indexes it.
  task automatic hw_write(input [31:0] a, input [31:0] v);
    begin
      backend.mem[a[22:2]] = v;
      @(posedge clk);
    end
  endtask

  // Is this address answered from an L1 line? Read it (filling a line if the decode allows it),
  // then read it again: a hit makes NO backend request, a direct read always does.
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

  // The platform's cache flush: one request into `memory`'s native whole-L1
  // cache_flush port; both caches walk every set - a superset of the retired
  // iobus sweep - and the done pulse ends it.
  task automatic flush_all();
    integer g;
    begin
      @(negedge clk);
      flush_start = 1'b1;
      @(negedge clk);
      flush_start = 1'b0;
      g = 0;
      while (!flush_done && g < 200000) begin @(posedge clk); g = g + 1; end
      if (!flush_done) $fatal(1, "TB_PC9821_CPU_VRAM_COHERENCY: cache flush never finished");
      repeat (4) @(posedge clk);
    end
  endtask

  // An aperture address must NOT come from an L1 line.
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

  // A RAM / control address must be cached, so the aperture tests cannot pass by refusing to
  // cache anything at all.
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

  // The aperture decode itself, exhaustively over the boundaries. The black-box probes above
  // prove the cache behaviour; this proves the comparator that decides it covers the ends.
  task automatic decode_is(input [31:0] a, input want, input [8*140-1:0] tag);
    begin
      @(negedge clk);
      cpu_addr = a; cpu_wdata = 32'h0; cpu_be = 4'hF; cpu_write = 1'b0;
      cpu_is_vga = (a[31:17] == 15'h5); cpu_valid = 1'b1;
      #1;
      checks = checks + 1;
      // The uncached verdict is the aperture OR the template VGA window (the
      // shipped map has both: A0000-BFFFF is VGA, C0000-FFFFF is the aperture),
      // so 0xBFFFF -- in the VGA window but NOT the aperture -- is expected
      // uncached here too, and the aperture's own ends are still discriminated
      // at 0xC0000 and 0x100000.
      if (dut.dcache_req_is_uncached !== (want | (a[31:17] == 15'h5))) begin
        $display("FAIL %0s: 0x%08x uncached=%b want %b", tag, a,
                 dut.dcache_req_is_uncached, want | (a[31:17] == 15'h5));
        errors = errors + 1;
      end
      cpu_valid = 1'b0;
      @(negedge clk);
    end
  endtask

  // The device-MMIO classifier, which the cacheability probes alone cannot see: an address can
  // be classified CACHEABLE and device at once (the window is an independent term), so a change
  // that only moved the no-allocate bound would pass every probe above and still mis-serve RAM.
  // PURELY COMBINATIONAL: dcache_req_is_device_mmio is a function of the address alone (no
  // valid term), and asserting cpu_valid at a CACHEABLE address would start an L1 fill that is
  // abandoned when the pulse ends -- which leaves the L1 mid-fill for the sections below.
  task automatic devmmio_is(input [31:0] a, input want, input [8*140-1:0] tag);
    begin
      cpu_addr = a;
      #1;
      checks = checks + 1;
      if (dut.dcache_req_is_device_mmio !== want) begin
        $display("FAIL %0s: 0x%08x device_mmio=%b want %b", tag, a,
                 dut.dcache_req_is_device_mmio, want);
        errors = errors + 1;
      end
      @(negedge clk);
    end
  endtask

  // A cacheable line the CPU has read, changed behind its back, must come back stale on the
  // cached read and fresh after the flush. The whole-cache claim needs more than set 0: the
  // native walk clears EVERY set of both caches whatever the tag, so a high-tag line is the
  // case a tag-matching invalidator would miss.
  task automatic flush_round_trip(input [31:0] a, input [31:0] v0, input [31:0] v1,
                                  input [8*140-1:0] tag);
    begin
      wr_dword(a, v0);
      rd_dword(a, rd);                       // cache the line
      repeat (8) @(posedge clk);
      hw_write(a, v1);                       // the EGC/GRCG, behind the back
      rd_dword(a, rd);
      checks = checks + 1;
      if (rd !== v0) begin
        $display("FAIL %0s: the L1 did not retain the line (read %08x, want stale %08x)",
                 tag, rd, v0);
        errors = errors + 1;
      end
      flush_all();
      rd_dword(a, rd);
      chk_dword(rd, v1, tag);
    end
  endtask

  integer    i;

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 0;
    // Let the l1_cache's reset sweep clear every set before the first request.
    repeat (400) @(posedge clk);

    // ------------------------------------------------------------------
    // (a) A CPU store to the VRAM window is not cached; the read-back is byte-exact.
    //     0xE0000 is the intensity plane (plane 3, the top palette bit); 0xC0000 is the
    //     aperture base.
    // ------------------------------------------------------------------
    $display("NOTE cpu_vram_coherency: --- (a) aperture store then load ---");
    wr_dword(32'h000E_0000, 32'hA5C3_5A3C);
    rd_dword(32'h000E_0000, rd);
    chk_dword(rd, 32'hA5C3_5A3C, "(a) 0xE0000 dword read-back");
    // Byte-exact, lane by lane, on a word cleared first.
    wr_dword(32'h000C_0000, 32'h0000_0000);
    req(32'h000C_0000, 1'b1, 4'b0001, 32'h0000_0042, rd);
    req(32'h000C_0001, 1'b1, 4'b0010, 32'h0000_5A00, rd);
    req(32'h000C_0002, 1'b1, 4'b0100, 32'h00A50000, rd);
    req(32'h000C_0003, 1'b1, 4'b1000, 32'hC3000000, rd);
    rd_dword(32'h000C_0000, rd);
    chk_dword(rd, 32'hC3A5_5A42, "(a) 0xC0000 four byte-lane stores");
    // The window must still reach the backend, i.e. the store was not L1-retained.
    expect_uncached(32'h000E_0000, "(a) 0xE0000 after a store");

    // ------------------------------------------------------------------
    // (b) The device-aperture region (C0000-FFFFF, the E0000 window included) bypasses the
    //     L1; the RAM controls below it and the internal A0000-BFFFF aperture are classified
    //     as the machine classifies them.
    // ------------------------------------------------------------------
    $display("NOTE cpu_vram_coherency: --- (b) aperture coverage ---");
    begin
      reg [31:0] ap [0:10];
      ap[0] = 32'h000C_0000;  ap[1] = 32'h000C_0004;  ap[2] = 32'h000C_C000;
      ap[3] = 32'h000D_FFFC;  ap[4] = 32'h000E_0000;  ap[5] = 32'h000E_4000;
      ap[6] = 32'h000E_7FFC;  ap[7] = 32'h000E_8000;  ap[8] = 32'h000F_FFFC;
      ap[9] = 32'h000F_FFFF;  ap[10] = 32'h000A_8000;
      for (i = 0; i < 11; i = i + 1)
        expect_uncached(ap[i], "(b) aperture");
    end
    // Controls: RAM the aperture must NOT swallow. If the decode were too wide these would go
    // direct, and the loop above would pass for the wrong reason.
    begin
      reg [31:0] ram [0:4];
      ram[0] = 32'h0000_0000; ram[1] = 32'h0000_0100; ram[2] = 32'h0008_0000;
      ram[3] = 32'h0009_FFFC; ram[4] = 32'h0010_0000;
      for (i = 0; i < 5; i = i + 1)
        expect_cached(ram[i], "(b) RAM control");
    end
    // Controls: the internal A0000-BFFFF VGA aperture (text VRAM/planes) is uncached too.
    begin
      reg [31:0] vga [0:2];
      vga[0] = 32'h000A_0000; vga[1] = 32'h000A_8000; vga[2] = 32'h000B_FFFC;
      for (i = 0; i < 3; i = i + 1)
        expect_uncached(vga[i], "(b) VGA aperture");
    end
    // The decode's own boundaries, so the region is pinned at both ends and not just sampled.
    decode_is(32'h000B_FFFF, 1'b0, "(b) decode 0xBFFFF (VGA top)");
    decode_is(32'h000C_0000, 1'b1, "(b) decode 0xC0000 (aperture base)");
    decode_is(32'h000C_0003, 1'b1, "(b) decode aperture base+3");
    decode_is(32'h000E_0000, 1'b1, "(b) decode 0xE0000 (intensity)");
    decode_is(32'h000E_7FFF, 1'b1, "(b) decode intensity top");
    decode_is(32'h000F_FFFF, 1'b1, "(b) decode 0xFFFFF (aperture top)");
    decode_is(32'h0010_0000, 1'b0, "(b) decode 0x100000 (just past the aperture)");
    decode_is(32'h001C_0000, 1'b0, "(b) decode 0x1C0000");
    decode_is(32'h0100_0000, 1'b0, "(b) decode 0x1000000");
    // ------------------------------------------------------------------
    // (b2) THE RAM ABOVE 32 MiB IS CACHEABLE AND NOT DEVICE-CLASSIFIED.
    //      The platform's device-MMIO window is OFF: its old
    //      32-64 MiB base was the pack base for a 64 MB module, not a property of the machine,
    //      and on a 128 MB module the OSD's guest size reaches 96 MiB, so 32 MiB of REAL guest
    //      RAM sat inside it and was served L1-bypassed. The no-allocation bound at the guest
    //      RAM top already gives that range the memory-size probe's behaviour.
    //      FAIL-FIRST: with the window ON, every expect_cached below is served directly and
    //      devmmio_is reports 1.
    // ------------------------------------------------------------------
    $display("NOTE cpu_vram_coherency: --- (b2) RAM above 32 MiB is cacheable ---");
    begin
      reg [31:0] hi [0:3];
      hi[0] = 32'h0200_0000;   // 32 MiB, the retired window's own base
      hi[1] = 32'h0300_0000;   // 48 MiB, inside it
      hi[2] = 32'h03FF_F000;   // just below the retired window's top
      hi[3] = 32'h0400_0000;   // 64 MiB, just past it
      for (i = 0; i < 4; i = i + 1)
        expect_cached(hi[i], "(b2) RAM above 32 MiB");
    end
    devmmio_is(32'h0200_0000, 1'b0, "(b2) device_mmio at 32 MiB");
    devmmio_is(32'h03FF_FFFF, 1'b0, "(b2) device_mmio below 64 MiB");
    devmmio_is(32'h0400_0000, 1'b0, "(b2) device_mmio past 64 MiB");
    // The PEGC extended VRAM at 0xF00000 is device memory by alias
    // (pc9821_memory_subsystem.sv peg_window) and z486 now classifies the
    // window uncached like the aperture itself: tb_pc9821_cpu_alias_coherency
    // ASSERTS it (with the mirror, peg_high and fw_high aliases); this probe
    // keeps printing the fact at the aperture bench.
    begin
      reg cached;
      probes_cached(32'h00F0_0000, cached);
      $display("NOTE cpu_vram_coherency: PEGC 0xF00000 cached=%b (asserted in cpu_alias_coherency)", cached);
    end

    // ------------------------------------------------------------------
    // (c) The cache flush. An external writer (the EGC/GRCG) changes a word the CPU has
    //     already read, and the flush the platform provides makes it visible.
    //     c1: the aperture (no L1 line, so the write is visible with no flush at all).
    //     c2: a cacheable RAM line, where the L1 really does hold the stale copy.
    // ------------------------------------------------------------------
    $display("NOTE cpu_vram_coherency: --- (c) flush mechanism ---");
    wr_dword(32'h000E_1000, 32'h1111_1111);
    rd_dword(32'h000E_1000, rd);
    chk_dword(rd, 32'h1111_1111, "(c1) 0xE01000 seeded");
    hw_write(32'h000E_1000, 32'h2222_2222);          // the EGC/GRCG writing VRAM behind the back
    rd_dword(32'h000E_1000, rd);
    chk_dword(rd, 32'h2222_2222, "(c1) aperture read after an external write");
    flush_all();
    rd_dword(32'h000E_1000, rd);
    chk_dword(rd, 32'h2222_2222, "(c1) aperture read after the flush");
    // c2: prove the flush is load-bearing. Seed a cacheable line, overwrite the backend behind
    //     the L1's back, require the stale hit, then require the flush to expose the new value.
    //     0x3000 is set 0; 0xFF0 is set 63 (the last set of the shipped 64); 0x104000 is a high
    //     TAG in set 0, which a tag-matching invalidator would leave behind. (The 0xF04000
    //     address this case first used is now device-alias territory:
    //     tb_pc9821_cpu_alias_coherency asserts it uncached.)
    flush_round_trip(32'h0000_3000, 32'h3333_3333, 32'h4444_4444, "(c2) set 0 after the flush");
    flush_round_trip(32'h0000_0FF0, 32'h5555_5555, 32'h6666_6666, "(c2) set 63 after the flush");
    flush_round_trip(32'h0010_4000, 32'h7777_7777, 32'h8888_8888, "(c2) high tag after the flush");

    // ------------------------------------------------------------------
    // (d) Self-modifying round trip: the CPU writes VRAM, the scanout/EGC reads it, then the
    //     CPU re-reads. Every step is byte-exact against the backend storage.
    // ------------------------------------------------------------------
    $display("NOTE cpu_vram_coherency: --- (d) self-modifying round trip ---");
    wr_dword(32'h000E_2000, 32'hDEAD_BEEF);
    checks = checks + 1;
    if (backend.mem[32'h000E_2000 >> 2] !== 32'hDEAD_BEEF) begin
      $display("FAIL (d): the scanout's view at 0xE2000 is %08x, want deadbeef",
               backend.mem[32'h000E_2000 >> 2]);
      errors = errors + 1;
    end
    rd_dword(32'h000E_2000, rd);
    chk_dword(rd, 32'hDEAD_BEEF, "(d) CPU re-read after the store");
    // The EGC/GRCG expands a store into the neighbouring word; the CPU must see it.
    hw_write(32'h000E_2004, 32'hFEED_FACE);
    rd_dword(32'h000E_2004, rd);
    chk_dword(rd, 32'hFEED_FACE, "(d) CPU read of the EGC-expanded neighbour");
    rd_dword(32'h000E_2000, rd);
    chk_dword(rd, 32'hDEAD_BEEF, "(d) CPU re-read of the original word");
    // And byte-exact per lane through the whole path.
    for (i = 0; i < 4; i = i + 1) begin
      req(32'h000E_3000 + i[31:0], 1'b1, (4'b0001 << i), (32'h5A + i) << (8*i), rd);
      checks = checks + 1;
      if (backend.mem[(32'h000E_3000 + i) >> 2][8*i +: 8] !== (8'h5A + i)) begin
        $display("FAIL (d) lane %0d: backend byte %02x, want %02x", i,
                 backend.mem[(32'h000E_3000 + i) >> 2][8*i +: 8], 8'h5A + i);
        errors = errors + 1;
      end
    end
    rd_dword(32'h000E_3000, rd);
    chk_dword(rd, 32'h5D5C_5B5A, "(d) CPU dword of the four byte stores");

    $display("NOTE cpu_vram_coherency: backend saw %0d accept(s), %0d read beat(s)",
             mem_accepts, mem_beats);

    // ==== VERDICT ====
    $display("TB_PC9821_CPU_VRAM_COHERENCY: %0d coherence check(s), %0d mismatch(es)",
             checks, errors);
    if (errors == 0) begin
      $display("TB_PC9821_CPU_VRAM_COHERENCY: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_CPU_VRAM_COHERENCY: FAIL (%0d errors)", errors);
  end

endmodule

`default_nettype wire

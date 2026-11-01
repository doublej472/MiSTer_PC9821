`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DMA_STOREQ_COHERENCY: a CPU store still in the write-through store queue when an external (DMA) write lands in the same line stays coherent on the CPU's next read - the queue forwards the youngest store, the external-writer snoop invalidates the written set, and the final memory holds the CPU's store (it drains after the external write that overtook it) - while a drained cached line is invalidated by the same snoop, so its next read is the external writer's bytes; the pre-T24 whole-L1 walk drained the store queue before invalidating and the per-write snoop does not, so this pins the equivalence that drain used to provide, with expected values from the memory ordering and not from the RTL. It also pins the CR0.NW=1 case: the 486 ignores EADS# while its write-through policy is disabled, so the same snoop is suppressed and the drained cached line survives - a deliberate, reference-backed divergence from the pre-T24 walk, stated as such.
//
// A CPU store that is STILL IN the write-through store queue when an external (DMA)
// write lands in the same line does not leave a stale or torn value on the CPU's next
// read: the store queue forwards the youngest queued store over the line, the D$/I$
// external snoop invalidates the written set, and the final memory holds the CPU's store
// (it drains after the external write that overtook it).
//
// FAIL-FIRST / MUTANT: the second phase (a drained line, then an external write with the
// snoop) is the snoop-necessity leg: tying the injected snoop off leaves the stale cached
// line and the read returns it, so the bench goes red.

`default_nettype none

module tb_pc9821_dma_storeq_coherency;
  reg clk = 0;
  always #5 clk = ~clk;   // 100 MHz
  reg reset = 1;

  // ==== the CPU-side request port (dma_flush_coherency's harness) ====
  reg  [31:0] mcpu_addr = 32'h0;
  reg  [31:0] mcpu_wdata = 32'h0;
  reg   [3:0] mcpu_be = 4'hF;
  reg         mcpu_write = 1'b0;
  reg         mcpu_is_vga = 1'b0;
  reg         mcpu_valid = 1'b0;
  wire        m_req_accepted, m_req_complete, m_read_complete;
  wire [31:0] m_rdata;

  wire [31:2] m_addr;
  wire  [3:0] m_be;
  wire  [7:0] m_burst;
  wire [31:0] m_dout;
  wire [31:0] m_din;
  wire [127:0] m_line_din;
  wire        m_valid, m_write, m_io, m_inta, m_ready;
  wire        m_resp_valid, m_line_resp_valid, m_line_read;
  wire [31:0] mem_accepts, mem_beats;

  // ==== the external-writer snoop (the machine's EADS#), injected directly ====
  reg         f3_snoop = 1'b0;
  reg  [31:0] f3_addr  = 32'h0;
  reg         nw       = 1'b0;   // CR0.NW, driven to pin the EADS# gate
  wire        cf_busy, cf_done;

  // ==== DUT ====
  memory #(
      .PROTECT_UMA_ROM(0),
      .DCACHE_SET_BITS(6),
      .ICACHE_SET_BITS(6),
      .ENABLE_X87(1'b0),
      .ENABLE_DEVICE_MMIO(1'b1), .DEVICE_MMIO_MASK(32'hFE00_0000),
      .APERTURE_ENABLE(1'b1),
      .ALIAS_ENABLE(1'b1),
      .WIN0_ENABLE(1'b1),
      .VGA_ENABLE(1'b1), .VGA_PRE_WRAP(1'b0),
      .A20_MASK_OFF(32'h000F_FFFF)
  ) u_mem (
      .clk(clk), .reset_n(~reset), .a20_enable(1'b1),
      .cache_enable(1'b1), .x87_off(1'b0), .cache_nw(nw),
      .device_mmio_enable(1'b1), .device_mmio_base(32'h0200_0000),
      .ram_cache_top(32'hFFFF_FFFF), .win0_unmapped(1'b0),
      .dcache_req_valid(mcpu_valid),
      .dcache_req_phys_addr_raw(mcpu_addr),
      .dcache_req_preread_offset(mcpu_addr[11:0]),
      .dcache_req_preread_priority(mcpu_valid),
      .dcache_req_write(mcpu_write),
      .dcache_req_be(mcpu_be),
      .dcache_req_wdata(mcpu_wdata),
      .dcache_direct_wdata(mcpu_wdata),
      .dcache_req_is_io(1'b0),
      .dcache_req_is_inta(1'b0),
      .dcache_req_is_x87(1'b0),
      .dcache_req_is_vga_mem(mcpu_is_vga),
      .dcache_req_accepted(m_req_accepted),
      .dcache_req_complete(m_req_complete),
      .dcache_read_complete(m_read_complete),
      .dcache_rdata(m_rdata),
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
      .snoop_addr(f3_addr), .snoop_valid(f3_snoop),
      .cache_flush(1'b0), .cache_flush_busy(cf_busy), .cache_flush_done(cf_done),
      .addr(m_addr), .be(m_be), .burstcount(m_burst), .line_read(m_line_read),
      .din(m_din), .line_din(m_line_din), .dout(m_dout),
      .valid(m_valid), .ready(m_ready), .write(m_write), .io(m_io),
      .resp_valid(m_resp_valid), .line_resp_valid(m_line_resp_valid), .inta(m_inta)
  );

  sdram_backend_model #(
      .ACCEPT_TO_RESP(2), .WRITE_BUSY(2), .LINE_RESP(0), .WORDS_LOG2(21)
  ) backend (
      .clk(clk), .reset(reset), .valid(m_valid), .ready(m_ready), .write(m_write),
      .addr({m_addr, 2'b00}), .din(m_dout), .din_hi(32'd0), .be(m_be), .burstcount(m_burst),
      .dout(m_din), .resp_valid(m_resp_valid),
      .line_dout(m_line_din), .line_resp_valid(m_line_resp_valid),
      .busy(), .accepts(mem_accepts), .beats(mem_beats)
  );

  task automatic mreq(input [31:0] a, input wr, input [3:0] be, input [31:0] wd,
                      output [31:0] rdata);
    integer g;
    begin
      @(negedge clk);
      mcpu_addr = a; mcpu_wdata = wd; mcpu_be = be; mcpu_write = wr;
      mcpu_is_vga = (a[31:17] == 15'h5);
      mcpu_valid = 1'b1;
      g = 0;
      while (!m_req_accepted && g < 20000) begin @(negedge clk); g = g + 1; end
      if (!m_req_accepted) $fatal(1, "TB_PC9821_DMA_STOREQ_COHERENCY: no accept for %08x", a);
      rdata = 32'h0;
      if (!wr) begin
        g = 0;
        while (!m_read_complete && g < 200000) begin @(negedge clk); g = g + 1; end
        if (!m_read_complete) $fatal(1, "TB_PC9821_DMA_STOREQ_COHERENCY: no response for %08x", a);
        rdata = m_rdata;
      end
      @(negedge clk);
      mcpu_valid = 1'b0; mcpu_write = 1'b0;
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic wr_dword(input [31:0] a, input [31:0] d);
    reg [31:0] sink;
    begin mreq(a, 1'b1, 4'hF, d, sink); end
  endtask

  task automatic rd_dword(input [31:0] a, output [31:0] d);
    begin mreq(a, 1'b0, 4'hF, 32'h0, d); end
  endtask

  // A store that does NOT wait for the queue to drain: the D$ accept is the whole
  // handshake (a write completes at the accept), so the store is left queued.
  task automatic store_queued(input [31:0] a, input [31:0] d);
    begin
      @(negedge clk);
      mcpu_addr = a; mcpu_wdata = d; mcpu_be = 4'hF; mcpu_write = 1'b1;
      mcpu_is_vga = (a[31:17] == 15'h5);
      mcpu_valid = 1'b1;
      while (!m_req_accepted) @(negedge clk);
      @(negedge clk);
      mcpu_valid = 1'b0; mcpu_write = 1'b0;
    end
  endtask

  // One external byte-write to a cached line, with the snoop, as the DMA would raise it.
  task automatic dma_write_line(input [31:0] a, input [31:0] d);
    begin
      backend.mem[a[22:2]] = d;
      f3_addr = a;
      f3_snoop = 1'b1;
      @(negedge clk);
      f3_snoop = 1'b0;
      @(negedge clk);
    end
  endtask

  // ==== CHECKS ====
  integer errors = 0;
  integer checks = 0;
  reg [31:0] rdv;

  localparam [31:0] X = 32'h0000_2000;
  localparam [31:0] Y = 32'h0000_3000;
  localparam [31:0] Z = 32'h0000_4000;
  localparam [31:0] STALE_A = 32'hDEAD_BEEF;
  localparam [31:0] V_CPU   = 32'h1122_3344;
  localparam [31:0] V_DMA   = 32'h5566_7788;
  localparam [31:0] STALE_B = 32'hCAFE_BABE;
  localparam [31:0] V_DMA2  = 32'h99AA_BBCC;
  localparam [31:0] STALE_C = 32'h0BAD_F00D;
  localparam [31:0] V_DMA3  = 32'hFEED_FACE;

  task automatic chk(input [31:0] got, input [31:0] want, input [8*96-1:0] tag);
    begin
      checks = checks + 1;
      if (got !== want) begin
        $display("FAIL %0s: got %08x, want %08x", tag, got, want);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    #80_000_000;
    $fatal(1, "TB_PC9821_DMA_STOREQ_COHERENCY: watchdog timeout (no verdict reached)");
  end

  initial begin
    reset = 1;
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // ================================================================ PHASE A
    // a store still in the write-through store queue, overtaken by an external write
    // to the same line: the CPU's next read must be coherent.
    wr_dword(X, STALE_A);
    rd_dword(X, rdv);
    chk(rdv, STALE_A, "phaseA stale cached dword");

    store_queued(X, V_CPU);
    checks = checks + 1;
    if (u_mem.cache_unit_inst.dcache_stores_drained) begin
      $display("FAIL phaseA setup: the store had already drained - the queued-store case proves nothing");
      errors = errors + 1;
    end
    // The external writer overtakes the still-queued store.
    dma_write_line(X, V_DMA);
    // The CPU's next read: the queue forwards the youngest store; the store drains last.
    rd_dword(X, rdv);
    chk(rdv, V_CPU, "phaseA the read after the queued store + external write");
    repeat (200) @(posedge clk);
    checks = checks + 1;
    if (!u_mem.cache_unit_inst.dcache_stores_drained) begin
      $display("FAIL phaseA: the store queue never drained");
      errors = errors + 1;
    end
    checks = checks + 1;
    if (backend.mem[X[22:2]] !== V_CPU) begin
      $display("FAIL phaseA: memory holds %08x, want the CPU store %08x (it drained after the external write)",
               backend.mem[X[22:2]], V_CPU);
      errors = errors + 1;
    end

    // ================================================================ PHASE B
    // a drained line, then an external write with the snoop: the read must be the
    // external writer's value - the snoop-necessity leg (tying the snoop off fails here).
    wr_dword(Y, STALE_B);
    rd_dword(Y, rdv);
    chk(rdv, STALE_B, "phaseB stale cached dword");
    repeat (200) @(posedge clk);
    dma_write_line(Y, V_DMA2);
    rd_dword(Y, rdv);
    chk(rdv, V_DMA2, "phaseB the read after the external write with the snoop");

    // ================================================================ PHASE C
    // With CR0.NW=1 the 486 ignores EADS#, so the same external write does NOT
    // invalidate a cached line and the read is the stale cached value. This pins the
    // intended, reference-backed behaviour; it is a deliberate value change from the
    // pre-T24 walk (which was not gated by NW).
    nw = 1'b0;
    wr_dword(Z, STALE_C);
    rd_dword(Z, rdv);
    chk(rdv, STALE_C, "phaseC stale cached dword (NW=0)");
    repeat (200) @(posedge clk);
    nw = 1'b1;
    dma_write_line(Z, V_DMA3);
    rd_dword(Z, rdv);
    chk(rdv, STALE_C, "phaseC the read with CR0.NW=1 (EADS# ignored, line survives)");
    nw = 1'b0;

    $display("NOTE dma_storeq_coherency: %0d check(s), %0d mismatch(es)", checks, errors);
  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_DMA_STOREQ_COHERENCY: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_DMA_STOREQ_COHERENCY: FAIL (%0d errors)", errors);
    end
  end

endmodule

`default_nettype wire

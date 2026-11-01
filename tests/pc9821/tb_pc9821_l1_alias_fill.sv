`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The z486 L1s hold no line for the platform's unmapped addresses and high alias windows (aliases.md A1/F6): the tags carry phys[26:0] only, so X and X + k*0x0800_0000 share tag+set and one cached line served both encodings - a cached open-bus fill at 0x0800_1000 poisoned (or was poisoned by) the RAM line at 0x0000_1000, and the I-cache's fw_high/peg_high windows at 0xFFFF8000/0xFFF00000 shared lines with 0x07FF8000/0x07F00000. The fix keeps open-bus and the high alias windows OUT of the fill path (ram_cache_top = the end of guest RAM; D served direct, I by a pass-through line fill that installs nothing), so every cached encoding has a unique [26:0] key - the property widened 32-bit tags provide, without growing the tag arrays. FAIL-FIRST: the RAM read-back after an open-bus fill, the twin's read after a cached store, and both directions of the fw_high/peg_high pairs fail on the pre-fix behaviour.
//
// The z486 L1s hold no line for the platform's unmapped addresses and high alias windows,
// so one 27-bit-keyed line can never serve two physical encodings (aliases.md A1/F6).
// The tags carry phys[26:0] only, so X and X + k*0x0800_0000 share tag+set: before the
// fill exclusion a cached open-bus read at 0x0800_1000 filled the line that IS the RAM
// line at 0x0000_1000 (and vice versa), and the instruction cache's fw_high/peg_high
// windows at 0xFFFF8000/0xFFF00000 shared lines with 0x07FF8000/0x07F00000. With
// ram_cache_top = the end of guest RAM, every unmapped/alias encoding is served direct
// (D) or by a pass-through line fill (I) and installs nothing; below the bound every
// encoding has a unique [26:0] key, which is exactly what widened 32-bit tags provide.
//
// FAILS BEFORE (each pair contaminates the twin's line):
//   D:  read 0x0000_1000 after a cached open-bus fill returns FFFF_FFFF, and a read of
//       the twin after a cached store/open-fill returns the wrong storage's datum.
//   I:  a fetch at 0xFFFF8000 serves the line filled through 0x07FF8000 (all F's) and a
//       fetch at 0x07FF8000 serves the fw window's bytes.
// PASSES AFTER: each encoding reads its own storage through every interleaving.

`default_nettype none

// The shipped PC-98 memory map, spliced from the vendored template's preset.
`include "z486_pc98_preset.svh"

// The platform's storage seen by the z486 memory fabric: RAM below 0x0100_0000,
// the fw_high window's own bytes at 0xFFFF_8000+, the PEGC high alias's own bytes at
// 0xFFF0_0000-0xFFF7_FFFF, and open bus (all ones, stores discarded) everywhere else --
// exactly pc9821_memory_subsystem's answer map at the addresses this bench uses.
module l1_alias_backend (
    input  wire        clk,
    input  wire        reset,
    input  wire        valid,
    output reg         ready,
    input  wire        write,
    input  wire [31:2] addr,
    input  wire [31:0] din,
    input  wire  [3:0] be,
    input  wire  [7:0] burstcount,
    output reg  [31:0] dout,
    output reg         resp_valid
);
  reg [31:0] ram [0:16383];        // guest RAM at word index addr[15:2]

  function automatic [31:0] back_word(input [31:0] a);
    begin
      if (a < 32'h0100_0000)          back_word = ram[a[15:2]];
      else if (a >= 32'hFFFF_8000)    back_word = 32'h5A5A_0000 | a[15:0];
      else if (a >= 32'hFFF0_0000)    back_word = 32'hE6A0_0000 | a[15:0];
      else                            back_word = 32'hFFFF_FFFF;
    end
  endfunction

  reg        a_write;
  reg  [7:0] a_left;
  reg [31:0] a_walk;
  reg  [1:0] a_delay;
  reg        busy;

  always @(posedge clk) begin
    if (reset) begin
      ready <= 1'b0; resp_valid <= 1'b0; dout <= 32'd0;
      a_write <= 1'b0; a_left <= 8'd0; a_walk <= 32'd0;
      a_delay <= 2'd0; busy <= 1'b0;
    end else begin
      ready <= 1'b0;
      resp_valid <= 1'b0;
      if (!busy) begin
        if (valid) begin
          ready <= 1'b1;
          busy <= 1'b1;
          a_write <= write;
          a_walk <= {addr, 2'b00};
          a_left <= (burstcount == 8'd0) ? 8'd1 : burstcount;
          a_delay <= 2'd2;
          if (write && ({addr, 2'b00} < 32'h0100_0000)) begin
            if (be[0]) ram[addr[15:2]][7:0]   <= din[7:0];
            if (be[1]) ram[addr[15:2]][15:8]  <= din[15:8];
            if (be[2]) ram[addr[15:2]][23:16] <= din[23:16];
            if (be[3]) ram[addr[15:2]][31:24] <= din[31:24];
          end
        end
      end else if (a_delay != 2'd0) begin
        a_delay <= a_delay - 2'd1;
      end else if (a_write) begin
        busy <= 1'b0;
      end else begin
        dout <= back_word(a_walk);
        resp_valid <= 1'b1;
        a_walk <= a_walk + 32'd4;
        a_left <= a_left - 8'd1;
        if (a_left == 8'd1) busy <= 1'b0;
      end
    end
  end
endmodule

module tb_pc9821_l1_alias_fill;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ==== DUT ====
  // The z486 memory fabric (both L1s), over l1_alias_backend: the platform's storage
  // seen below 0x0100_0000.
  reg  [31:0] cpu_addr = 32'h0;
  reg  [31:0] cpu_wdata = 32'h0;
  reg   [3:0] cpu_be = 4'hF;
  reg         cpu_write = 1'b0;
  reg         cpu_valid = 1'b0;
  reg         a20_enable = 1'b1;
  wire        req_accepted, req_complete, read_complete;
  wire [31:0] dcache_rdata;

  reg  [31:0] if_addr = 32'h0;
  reg         if_valid = 1'b0;
  wire        if_accepted, if_complete;
  wire [127:0] if_line;

  wire [31:2] m_addr;
  wire  [3:0] m_be;
  wire  [7:0] m_burst;
  wire [31:0] m_dout;
  wire [31:0] m_din;
  wire        m_valid, m_write, m_io, m_inta, m_ready, m_resp_valid;
  wire        m_line_read, m_line_resp_valid;

  memory #(
      .PROTECT_UMA_ROM(0),
      .DCACHE_SET_BITS(6),
      .ICACHE_SET_BITS(6),
      .ENABLE_X87(1'b0),
      .ENABLE_DEVICE_MMIO(1'b1), .DEVICE_MMIO_MASK(32'hFE00_0000),
      // The shipped PC-98 map: the A0000-FFFFF aperture, the three alias
      // windows, the window-0 range, the wrapped VGA window (VGA_PRE_WRAP = 0
      // tests the A20-masked physical) and A20-off as a bit-20 clear. The
      // no-allocate bound is the runtime one below, so cacheable RAM is exactly
      // [0, 0x0100_0000) -- this bench's storage model.
      `Z486_PC98_MAP_PARAMS,
      .RAM_BOUND_ENABLE(1'b1)
  ) dut (
      .clk(clk), .reset_n(~reset), .a20_enable(a20_enable),
      .device_mmio_enable(1'b1), .device_mmio_base(32'h0200_0000),
      .ram_cache_top(32'h0100_0000), .win0_unmapped(1'b0),
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
      .dcache_req_is_vga_mem(1'b0),
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
      .icache_req_valid(if_valid), .icache_req_phys_addr_raw(if_addr),
      .icache_req_accepted(if_accepted), .icache_req_complete(if_complete),
      .icache_rdata(if_line),
      .snoop_addr(32'h0), .snoop_valid(1'b0),
      .addr(m_addr), .be(m_be), .burstcount(m_burst), .line_read(m_line_read),
      .din(m_din), .line_din(128'd0), .dout(m_dout),
      .valid(m_valid), .ready(m_ready), .write(m_write), .io(m_io),
      .resp_valid(m_resp_valid), .line_resp_valid(m_line_resp_valid),
      .inta(m_inta)
  );

  l1_alias_backend backend (
      .clk(clk), .reset(reset),
      .valid(m_valid), .ready(m_ready), .write(m_write),
      .addr(m_addr), .din(m_dout), .be(m_be), .burstcount(m_burst),
      .dout(m_din), .resp_valid(m_resp_valid)
  );

  integer errors = 0;
  reg [31:0] rd;
  reg [127:0] ln;

  // ==== CHECKS ====
  task automatic chk(input [31:0] got, input [31:0] want, input [8*120-1:0] tag);
    begin
      if (got !== want) begin
        $display("FAIL %0s: got %08x, want %08x", tag, got, want);
        errors = errors + 1;
      end
    end
  endtask

  task automatic req(input [31:0] a, input wr, input [31:0] wd, output [31:0] rdata);
    integer g;
    begin
      @(negedge clk);
      cpu_addr = a; cpu_wdata = wd; cpu_be = 4'hF; cpu_write = wr;
      cpu_valid = 1'b1;
      g = 0;
      while (!req_accepted && g < 20000) begin @(negedge clk); g = g + 1; end
      if (!req_accepted) $fatal(1, "TB_PC9821_L1_ALIAS_FILL: no accept for %08x", a);
      rdata = 32'h0;
      if (!wr) begin
        g = 0;
        while (!read_complete && g < 20000) begin @(negedge clk); g = g + 1; end
        if (!read_complete) $fatal(1, "TB_PC9821_L1_ALIAS_FILL: no response for %08x", a);
        rdata = dcache_rdata;
      end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0;
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic fetch(input [31:0] a, output [127:0] line);
    integer g;
    begin
      @(negedge clk);
      if_addr = a; if_valid = 1'b1;
      g = 0;
      while (!if_accepted && g < 20000) begin @(negedge clk); g = g + 1; end
      if (!if_accepted) $fatal(1, "TB_PC9821_L1_ALIAS_FILL: no fetch accept for %08x", a);
      // The accept edge is the next posedge: drop valid past it, or the prefetch
      // port accepts the same request twice and every response shifts by one.
      @(negedge clk);
      if_valid = 1'b0;
      g = 0;
      while (!if_complete && g < 20000) begin @(negedge clk); g = g + 1; end
      if (!if_complete) $fatal(1, "TB_PC9821_L1_ALIAS_FILL: no fetch response for %08x", a);
      line = if_line;
      repeat (4) @(posedge clk);
    end
  endtask

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_L1_ALIAS_FILL: TIMEOUT");
  end

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (2) @(posedge clk);

    // ==== A1 D-side, open-bus twin of a RAM line ====
    // The confirm test: store at the RAM encoding, READ through the
    // open-bus twin (which used to fill the shared line with F's), read RAM again.
    req(32'h0000_1000, 1'b1, 32'hAAAA_5555, rd);
    req(32'h0000_1000, 1'b0, 32'h0, rd);
    chk(rd, 32'hAAAA_5555, "D: RAM read-back at 0x00001000");
    req(32'h0800_1000, 1'b0, 32'h0, rd);
    chk(rd, 32'hFFFF_FFFF, "D: open-bus twin at 0x08001000 reads FF");
    req(32'h0000_1000, 1'b0, 32'h0, rd);
    chk(rd, 32'hAAAA_5555, "D: RAM at 0x00001000 after the open-bus fill (A1)");

    // The k=2 twin as well: 0x1000_1000 aliases 0x0000_1000 the same way.
    req(32'h1000_1000, 1'b0, 32'h0, rd);
    chk(rd, 32'hFFFF_FFFF, "D: open-bus twin at 0x10001000 reads FF");
    req(32'h0000_1000, 1'b0, 32'h0, rd);
    chk(rd, 32'hAAAA_5555, "D: RAM at 0x00001000 after the k=2 fill (A1)");

    // ==== A1 D-side, the other direction ====
    // A cached open-bus line carries a cached STORE to its RAM twin's reads.
    req(32'h1000_2000, 1'b0, 32'h0, rd);
    chk(rd, 32'hFFFF_FFFF, "D: open-bus at 0x10002000 reads FF");
    req(32'h0000_2000, 1'b1, 32'h5566_7788, rd);
    req(32'h0000_2000, 1'b0, 32'h0, rd);
    chk(rd, 32'h5566_7788, "D: RAM read-back at 0x00002000");
    req(32'h1000_2000, 1'b0, 32'h0, rd);
    chk(rd, 32'hFFFF_FFFF, "D: open-bus twin at 0x10002000 after the RAM store (A1)");

    // And "the other way: open bus returns RAM data": a store through
    // the open encoding used to land in the shared line and read back at the RAM
    // twin. Seed the RAM twin first so the want value is unambiguous.
    req(32'h0000_3000, 1'b1, 32'h7777_0000, rd);
    req(32'h0800_3000, 1'b0, 32'h0, rd);
    chk(rd, 32'hFFFF_FFFF, "D: open-bus at 0x08003000 reads FF");
    req(32'h0800_3000, 1'b1, 32'h9999_8888, rd);
    req(32'h0000_3000, 1'b0, 32'h0, rd);
    chk(rd, 32'h7777_0000, "D: RAM twin at 0x00003000 after the open-bus store (A1)");

    // ==== A1 I-side, fw_high (0xFFFF8000) vs its 0x07FF8000 twin ====
    fetch(32'h07FF_8000, ln);
    chk(ln[31:0], 32'hFFFF_FFFF, "I: open-bus twin at 0x07FF8000 reads FF");
    fetch(32'hFFFF_8000, ln);
    chk(ln[31:0], 32'h5A5A_8000, "I: fw_high fetch at 0xFFFF8000 after the twin fill (F6)");
    chk(ln[63:32], 32'h5A5A_8004, "I: fw_high fetch word 1 (F6)");

    // ... and the reverse direction: the window's fill must not answer the twin.
    fetch(32'hFFFF_8020, ln);
    chk(ln[31:0], 32'h5A5A_8020, "I: fw_high fetch at 0xFFFF8020");
    fetch(32'h07FF_8020, ln);
    chk(ln[31:0], 32'hFFFF_FFFF, "I: twin at 0x07FF8020 after the fw_high fill (F6)");

    // ==== A1 I-side, peg_high (0xFFF00000) vs its 0x07F00000 twin ====
    fetch(32'h07F0_0010, ln);
    chk(ln[31:0], 32'hFFFF_FFFF, "I: open-bus twin at 0x07F00010 reads FF");
    fetch(32'hFFF0_0010, ln);
    chk(ln[31:0], 32'hE6A0_0010, "I: peg_high fetch at 0xFFF00010 after the twin fill (F6)");

    // ==== Controls: real storage still caches and reads through ====
    fetch(32'h0000_5000, ln);
    chk(ln[31:0], 32'h0000_0000, "I: RAM fetch at 0x00005000 reads its own line");
    req(32'h0000_1000, 1'b0, 32'h0, rd);
    chk(rd, 32'hAAAA_5555, "D: RAM still holds 0x00001000 at the end");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_L1_ALIAS_FILL: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_L1_ALIAS_FILL: FAIL (%0d errors)", errors);
  end
endmodule

`default_nettype wire

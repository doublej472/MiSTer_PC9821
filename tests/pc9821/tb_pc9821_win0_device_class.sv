`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The window-0 overlay at 0x80000-0x9FFFF classifies like its TARGET, not like its own address (aliases.md A5): with 0x0461 = 0x0E the overlay IS the 0xF8000-0xFFFFF banked window, whose canonical encoding is served direct/uncached while the overlay matched none of the device terms and stayed cached over the same storage. A writer behind the cache (a canonical uncached store, a bank flip, the GRCG/EGC) then left the overlay's line stale where the canonical side read fresh. The z486 memory unit takes the platform's win0_unmapped verdict (pc9821_system sets it for EVERY moved window, 0x0461 != 0x08, because a window over plain RAM is also one byte with two names) and the backend models the window-0 bias. FAIL-FIRST: the overlay reads the pre-store bytes after a canonical store, over the banked window and over plain RAM; PASS: both encodings agree, and the verdict-0 identity window still caches.
//
// The window-0 overlay at 0x80000-0x9FFFF classifies like its TARGET, not like its own
// address (aliases.md A5). With 0x0461 = 0x0E the overlay IS the 0xF8000-0xFFFFF banked
// ROM window; the canonical encoding is served direct/uncached (the device aperture) while
// the overlay used to match none of the device terms and stayed RAM-classified -- cached --
// over the same storage. Any writer behind the cache (a canonical uncached store, a ROM
// bank flip, the GRCG/EGC on the plane windows of win0=0x0A) then left the overlay's line
// stale where the canonical encoding read fresh, and a store through the overlay was a
// write-through cache store where the canonical side discards or shadows it.
//
// The z486 `memory` unit is driven the way pc9821_system drives it: win0_unmapped is the
// platform's verdict that the window currently maps over non-RAM storage (pc9821_system's
// win0_unmapped), and the backend's alias_map is the platform's window-0 bias
// (0x80000-0x9FFFF + 0x60000 == 0xF8000-0xFFFFF for 0x0461 = 0x0E).
//
// FAILS BEFORE: the overlay caches the pre-store bytes and reads 11111111 after the
// canonical store wrote 22222222.
// PASSES AFTER: the overlay reads the same fresh bytes the canonical encoding does, while
// a RAM-mapped window (win0_unmapped = 0) still caches.

`default_nettype none

// The shipped PC-98 memory map, spliced from the vendored template's preset.
`include "z486_pc98_preset.svh"

// The platform's answer map at the addresses this bench uses: the banked window's bytes at
// 0xF8000-0xFFFFF (and its win0=0x0E overlay at 0x98000-0x9FFFF, the same storage), plain
// RAM below 0x10000, open bus elsewhere. `accepts` counts backend transactions so the
// control can prove what cached and what did not.
module win0_class_backend (
    input  wire        clk,
    input  wire        reset,
    input  wire        win_ram,    // 1: model 0x0461 = 0x00 (the window over plain RAM 0x08000-0x0FFFF)
    input  wire        valid,
    output reg         ready,
    input  wire        write,
    input  wire [31:2] addr,
    input  wire [31:0] din,
    input  wire  [3:0] be,
    input  wire  [7:0] burstcount,
    output reg  [31:0] dout,
    output reg         resp_valid,
    output reg  [31:0] accepts
);
  reg [31:0] fw_ram [0:8191];     // 0xF8000-0xFFFFF: the banked window's storage
  reg [31:0] ram [0:16383];

  // The platform's window-0 bias (pc9821_memory_map's d_addr): 0x0461 = 0x0E puts
  // 0x98000 on 0xF8000; 0x0461 = 0x00 puts it on plain RAM at 0x08000 (win_ram).
  function automatic [31:0] alias_map(input [31:0] a);
    begin
      if ((a >= 32'h0009_8000) && (a <= 32'h0009_FFFF))
        alias_map = win_ram ? (a - 32'h0009_0000) : (a + 32'h0006_0000);
      else
        alias_map = a;
    end
  endfunction

  function automatic [31:0] back_word(input [31:0] a);
    begin
      if ((a >= 32'h000F_8000) && (a <= 32'h000F_FFFF))
        back_word = fw_ram[a[14:2]];
      else if (a < 32'h0001_0000)
        back_word = ram[a[15:2]];
      else
        back_word = 32'hFFFF_FFFF;
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
      a_delay <= 2'd0; busy <= 1'b0; accepts <= 32'd0;
    end else begin
      ready <= 1'b0;
      resp_valid <= 1'b0;
      if (!busy) begin
        if (valid) begin
          ready <= 1'b1;
          busy <= 1'b1;
          accepts <= accepts + 32'd1;
          a_write <= write;
          a_walk <= alias_map({addr, 2'b00});
          a_left <= (burstcount == 8'd0) ? 8'd1 : burstcount;
          a_delay <= 2'd2;
          if (write) begin : store
            reg [31:0] t;
            t = alias_map({addr, 2'b00});
            if ((t >= 32'h000F_8000) && (t <= 32'h000F_FFFF)) begin
              if (be[0]) fw_ram[t[14:2]][7:0]   <= din[7:0];
              if (be[1]) fw_ram[t[14:2]][15:8]  <= din[15:8];
              if (be[2]) fw_ram[t[14:2]][23:16] <= din[23:16];
              if (be[3]) fw_ram[t[14:2]][31:24] <= din[31:24];
            end else if (t < 32'h0001_0000) begin
              if (be[0]) ram[t[15:2]][7:0]   <= din[7:0];
              if (be[1]) ram[t[15:2]][15:8]  <= din[15:8];
              if (be[2]) ram[t[15:2]][23:16] <= din[23:16];
              if (be[3]) ram[t[15:2]][31:24] <= din[31:24];
            end
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

module tb_pc9821_win0_device_class;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  reg  [31:0] cpu_addr = 32'h0;
  reg  [31:0] cpu_wdata = 32'h0;
  reg   [3:0] cpu_be = 4'hF;
  reg         cpu_write = 1'b0;
  reg         cpu_valid = 1'b0;
  reg         win0_unmapped = 1'b0;
  wire        req_accepted, req_complete, read_complete;
  wire [31:0] dcache_rdata;

  wire [31:2] m_addr;
  wire  [3:0] m_be;
  wire  [7:0] m_burst;
  wire [31:0] m_dout;
  wire [31:0] m_din;
  wire        m_valid, m_write, m_io, m_inta, m_ready, m_resp_valid;
  wire        m_line_read, m_line_resp_valid;

  // ==== DUT ====
  memory #(
      .PROTECT_UMA_ROM(0),
      .DCACHE_SET_BITS(6),
      .ICACHE_SET_BITS(6),
      .ENABLE_X87(1'b0),
      .ENABLE_DEVICE_MMIO(1'b1), .DEVICE_MMIO_MASK(32'hFE00_0000),
      // The shipped PC-98 map (see the preset header) plus the runtime
      // no-allocate bound at this bench's RAM top.
      `Z486_PC98_MAP_PARAMS,
      .RAM_BOUND_ENABLE(1'b1)
  ) dut (
      .clk(clk), .reset_n(~reset), .a20_enable(1'b1),
      // L1 on, FPU present: z486 drives these from cache_off_req/x87_off_req, which pc9821_system ties low
      .cache_enable(1'b1), .x87_off(1'b0),
      .device_mmio_enable(1'b1), .device_mmio_base(32'h0200_0000),
      .ram_cache_top(32'h0100_0000), .win0_unmapped(win0_unmapped),
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
      .icache_req_valid(1'b0), .icache_req_phys_addr_raw(32'h0),
      .icache_req_accepted(), .icache_req_complete(), .icache_rdata(),
      .snoop_addr(32'h0), .snoop_valid(1'b0),
      .addr(m_addr), .be(m_be), .burstcount(m_burst), .line_read(m_line_read),
      .din(m_din), .line_din(128'd0), .dout(m_dout),
      .valid(m_valid), .ready(m_ready), .write(m_write), .io(m_io),
      .resp_valid(m_resp_valid), .line_resp_valid(m_line_resp_valid),
      .inta(m_inta)
  );

  wire [31:0] accepts;
  reg win_ram = 1'b0;
  win0_class_backend backend (
      .clk(clk), .reset(reset), .win_ram(win_ram),
      .valid(m_valid), .ready(m_ready), .write(m_write),
      .addr(m_addr), .din(m_dout), .be(m_be), .burstcount(m_burst),
      .dout(m_din), .resp_valid(m_resp_valid), .accepts(accepts)
  );

  integer errors = 0;
  reg [31:0] rd;

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
      if (!req_accepted) $fatal(1, "TB_PC9821_WIN0_DEVICE_CLASS: no accept for %08x", a);
      rdata = 32'h0;
      if (!wr) begin
        g = 0;
        while (!read_complete && g < 20000) begin @(negedge clk); g = g + 1; end
        if (!read_complete)
          $fatal(1, "TB_PC9821_WIN0_DEVICE_CLASS: no response for %08x", a);
        rdata = dcache_rdata;
      end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0;
      repeat (4) @(posedge clk);
    end
  endtask

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_WIN0_DEVICE_CLASS: TIMEOUT");
  end

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (2) @(posedge clk);

    // ==== The A5 divergence: overlay (cached) vs canonical (uncached) ====
    win0_unmapped = 1'b1;
    req(32'h000F_8000, 1'b1, 32'h1111_1111, rd);          // canonical store
    req(32'h0009_8000, 1'b0, 32'h0, rd);                  // fills the overlay's line
    chk(rd, 32'h1111_1111, "A5: overlay at 0x98000 sees the canonical store");
    req(32'h000F_8000, 1'b1, 32'h2222_2222, rd);          // a writer behind the cache
    req(32'h000F_8000, 1'b0, 32'h0, rd);
    chk(rd, 32'h2222_2222, "A5: canonical 0xF8000 is fresh (uncached)");
    req(32'h0009_8000, 1'b0, 32'h0, rd);
    chk(rd, 32'h2222_2222,
        "A5: overlay at 0x98000 agrees with the canonical encoding after the write");

    // The store-through direction: the overlay's store must land in the window's
    // storage (a write-through cache store did land too, so this is the control).
    req(32'h0009_8000, 1'b1, 32'h3333_3333, rd);
    req(32'h000F_8000, 1'b0, 32'h0, rd);
    chk(rd, 32'h3333_3333, "A5: canonical sees the overlay's store");

    // ==== Control: verdict 0 still caches ====
    // win0_unmapped = 0 (the platform's verdict only for the identity window,
    // 0x0461 = 0x08, i.e. plain RAM at its own address): two reads must reach the
    // backend once, i.e. the classification did not become "uncached everywhere".
    win0_unmapped = 1'b0;
    begin : ram_control
      reg [31:0] a0;
      req(32'h0009_8000, 1'b0, 32'h0, rd);
      a0 = accepts;
      req(32'h0009_8000, 1'b0, 32'h0, rd);
      if (accepts !== a0) begin
        $display("FAIL control: a RAM-mapped overlay did not cache (accepts %0d -> %0d)",
                 a0, accepts);
        errors = errors + 1;
      end
    end

    // ==== A moved window over PLAIN RAM is one byte with two names ====
    // 0x0461 = 0x00 maps 0x98000 onto RAM at 0x08000. The translation is outside the
    // CPU, so the L1 sees two physical addresses for one byte. pc9821_system now
    // classifies EVERY moved window NO_ALLOC (win0_unmapped = 1 for win0_sel != 0x08); the old verdict left a RAM-target window
    // cacheable (0) and the window read below returned the pre-store word.
    // FAILS BEFORE (win0_unmapped = 0 here): "RAM alias" reads 0x5555_5555.
    win0_unmapped = 1'b1;
    win_ram = 1'b1;
    req(32'h0000_8000, 1'b1, 32'h5555_5555, rd);          // canonical store
    req(32'h0009_8000, 1'b0, 32'h0, rd);                  // window read (would fill a line)
    chk(rd, 32'h5555_5555, "RAM alias: window sees the canonical store");
    req(32'h0000_8000, 1'b0, 32'h0, rd);                  // canonical line cached now
    req(32'h0000_8000, 1'b1, 32'h6666_6666, rd);          // canonical store (write-through)
    req(32'h0009_8000, 1'b0, 32'h0, rd);
    chk(rd, 32'h6666_6666,
        "RAM alias: window agrees with the canonical name after a canonical store");
    win_ram = 1'b0;

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_WIN0_DEVICE_CLASS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_WIN0_DEVICE_CLASS: FAIL (%0d errors)", errors);
  end
endmodule

`default_nettype wire

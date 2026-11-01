`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SPRITE: TH01's sprite ERASE / BACKGROUND-RESTORE makes the machine's own bus shape, and the EGC's byte LANE comes from the CPU's BYTE ENABLES, not from the address: z486's address output is 30 bits ("Physical address [31:2]", z486.sv:78) and pc9821_system forms the guest address as {z_addr, 2'b00} (pc9821_system.sv:647,1061), so every access arrives DWORD-ALIGNED with the operand's byte lane carried only in cpu_be (z486_pkg.sv:1169 calc_be). Deriving the EGC's lane from the address's low bits yields 0 for every access, so a 16-bit unit on lanes 2:3 (be = 1100) became a BYTE unit on lane 0: one byte written, the two intended bytes untouched. The two sequences asserted here are the two observed symptoms, driven exactly as th01 uses them (op_01.cpp:257 whiteline_put, th01/hardware/egcrect.cpp:3 egc_copy_rect_1_to_0_16, th01/formats/ptn_main.cpp ptn_put_quarter_8 / ptn_sloppy_unput_quarter_16): the whiteline row is drawn with the GRCG RMW and restored from page 1 by the EGC (the row must come back as the background, not stay white), and a 16x16 sprite is erased, drawn and restored (the footprint must come back as the background, not stay black). Every restoring chunk is a 16-bit access at an even plane offset, so HALF of them (offset & 3 == 2) are on lanes 2:3; the bench checks all 80 bytes of the row in all four planes, and both lane-0:1 and lane-2:3 sprite positions.
// TH01's sprite ERASE / BACKGROUND-RESTORE makes the machine's own bus shape, and the EGC's byte LANE comes from the CPU's BYTE ENABLES, not from the address: z486's address output is 30 bits ("Physical address [31:2]", z486.sv:78) and pc9821_system forms the guest address as {z_addr, 2'b00} (pc9821_system.sv:647,1061), so every access arrives DWORD-ALIGNED with the operand's byte lane carried only in cpu_be (z486_pkg.sv:1169 calc_be). Deriving the EGC's lane from the address's low bits yields 0 for every access, so a 16-bit unit on lanes 2:3 (be = 1100) became a BYTE unit on lane 0: one byte written, the two intended bytes untouched. The two sequences asserted here are the two observed symptoms, driven exactly as th01 uses them (op_01.cpp:257 whiteline_put, th01/hardware/egcrect.cpp:3 egc_copy_rect_1_to_0_16, th01/formats/ptn_main.cpp ptn_put_quarter_8 / ptn_sloppy_unput_quarter_16): the whiteline row is drawn with the GRCG RMW and restored from page 1 by the EGC (the row must come back as the background, not stay white), and a 16x16 sprite is erased, drawn and restored (the footprint must come back as the background, not stay black). Every restoring chunk is a 16-bit access at an even plane offset, so HALF of them (offset & 3 == 2) are on lanes 2:3; the bench checks all 80 bytes of the row in all four planes, and both lane-0:1 and lane-2:3 sprite positions.

module tb_pc9821_sprite;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  localparam [31:0] GUEST_RAM = 32'h0200_0000;
  localparam [31:0] PACK_BASE = GUEST_RAM;                 // == guest_ram_bytes
  // The one place gvram_base is defined: pc9821_memory_subsystem passes
  // pack_base + 1 MiB (the old +0x80000 this bench carried was the same stale
  // constant pc9821_system's GRCG instance had, and it is why neither could
  // ever see a plane).
  localparam [31:0] GVRAM_BASE = PACK_BASE + 32'h0010_0000;
  localparam [31:0] BACKEND_BASE = PACK_BASE;
  // The CPU-side windows: three contiguous 32 KiB planes at A8000/B0000/B8000
  // and the intensity plane at E0000. The access-page register (0xA6) selects
  // WHICH page of all four the window shows -- the CPU address does not change
  // with the page, which is what makes TH01's inter-page copy a same-offset
  // read and write.
  localparam [31:0] WIN_P0 = 32'h000A_8000;
  localparam [31:0] WIN_P1 = 32'h000B_0000;
  localparam [31:0] WIN_P2 = 32'h000B_8000;
  localparam [31:0] WIN_P3 = 32'h000E_0000;
  localparam integer BACKEND_BYTES = 32'h0018_0000;        // pack head .. VRAM end

  reg [3:0]  top_bank = 4'd8;
  reg        ide_rom_enable = 0;
  reg        ide_ram_gate = 1;
    // 0x1E8E's IDE work-RAM gate: held ON so nothing here sees the gated
    // shape - tb_pc9821_memory_subsystem and tb_pc9821_memory_map pin it.
  reg        bios_ram_gate = 0;
  // 0x043F's 0x8 nibble: the writable top-window shadow, reset-cleared. Held off
  // here; the sprite sequences never touch the 0xF8000-0xFFFFF window.
  reg        top_shadow_en = 0;
  reg [7:0]  win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  // 0x043B bit 2, the 15-16 MiB system-space window. The machine's reset value is ON,
  // so these benches drive the same state the card comes up in.
  reg  sys16m_en = 1'b1;
  reg        gvram_access_page = 0;
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
  wire       font_we;

  reg [31:0] cpu_addr = 0, cpu_din = 0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  reg [3:0]  cpu_be = 4'hF;
  reg [7:0]  cpu_burstcount = 8'd1;
  reg        cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  wire       cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  reg [31:0] pack_base = PACK_BASE;
  reg [31:0] guest_ram_bytes = GUEST_RAM;

  wire [13:0] tram_addr;
  wire [7:0]  tram_din;
  wire        tram_we;
  reg [7:0]   tram_dout = 0;
  reg [7:0]   tram [0:16383];
  // CG window (0xA4000-0xA4FFF) is exercised by its own bench; here the port is
  // simply held idle so the wildcard instantiation remains complete.
  wire [4:0]  cg_win_byte_sel;
  wire        cg_win_rd;
  reg [7:0]   cg_win_dout = 0;
  wire [7:0]  cg_win_din;
  wire        cg_win_we;
  // Glyph-region reader (the SDRAM's second port) and its request from the GDC:
  // both parked, so the subsystem never sees a fetch here.
  reg [18:0]  font_req_addr = 0;
  reg         font_req = 0;
  wire        font_word_valid;
  wire [31:0] font_word_data;
  wire [31:0] fmem_addr, fmem_din;
  wire        fmem_valid, fmem_write;
  wire [3:0]  fmem_be;
  wire [7:0]  fmem_burstcount;
  reg         fmem_ready = 1;
  reg [31:0]  fmem_dout = 0;
  reg         fmem_resp_valid = 0;

  wire [31:0] mem_addr, mem_din;
  reg [31:0]  mem_dout = 32'h0;
  reg [127:0] mem_line_dout = 128'd0;
  wire [3:0]  mem_be;
  wire [7:0]  mem_burstcount;
  wire        mem_line_read, mem_valid, mem_write;
  reg         mem_ready = 1, mem_resp_valid = 0, mem_line_resp_valid = 0;
  // The GVRAM scanout's SDRAM requester. The wildcard instantiation needs every port
  // named; nothing here drives the scanout, so it accepts and never answers.
  wire [31:0] mem3_addr, mem3_din;
  wire  [3:0] mem3_be;
  wire  [7:0] mem3_burstcount;
  wire        mem3_valid, mem3_write;
  reg  [31:0] mem3_dout = 32'h0;
  reg         mem3_ready = 1, mem3_resp_valid = 0;

  // ==== DUT ====
  // The GVRAM datapath's ports: the GRCG's device-bus bytes, and the
  // scanout's read side. Unused here, but the wildcard instantiation needs them.
  reg        grcg_we = 0;
  reg  [7:0] grcg_addr = 0;
  reg  [7:0] grcg_din = 0;
  wire       grcg_expand;   // the GRCG's CG-mode bit 7, fed back from the subsystem
  wire       grcg_expand_nx;   // mode[7]'s next state (opt-video VID-1); unused here

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

  wire [1:0] ems_state;

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

  pc9821_memory_subsystem #(.SYS_CLOCK_HZ(100_000_000)) dut (.*);

  // ==== BEHAVIOURAL GVRAM BACKEND ====
  reg [7:0] backend [0:BACKEND_BYTES-1];
  reg        resp_valid_r = 0;
  reg [31:0] resp_data_r = 0;
  integer    backend_reads = 0, backend_writes = 0;

  // Plane p's byte at column `off` on page `page`. The planes are byte-interleaved
  // in SDRAM: the column word at gvram_base + page*0x20000 + 4*off
  // carries {E,G,R,B}, so plane p is lane p of it. A planar address here would
  // make every expectation below describe the old layout.
  // NOTE the interleaved layout changes what "plane p's byte n" means: the page's
  // plane bytes are one per COLUMN, so consecutive bytes of a plane are consecutive
  // `off` values, not consecutive bytes at one address.
  function [31:0] plane_addr(input page, input [1:0] plane, input [14:0] off);
    begin
      plane_addr = GVRAM_BASE + (page ? 32'h0002_0000 : 32'h0) +
                   {15'd0, off, 2'b00} + {30'd0, plane};
    end
  endfunction

  // The GVRAM is SDRAM storage again: a CPU plane store becomes one transaction on the
  // mem_* requester, so the backend[] mirror observes it exactly as it observes guest RAM. Plane p
  // of the column word is byte lane p, which is what plane_addr already encodes.
  function automatic [7:0] gv_byte(input page, input [1:0] plane, input [14:0] off);
    begin
      // The GVRAM is M10K inside pc9821_gvram_dut now: read the array directly. The word
      // index is {page, off} and plane p is byte lane p of it.
      case (plane)
        2'd0: gv_byte = dut.u_gmem.mem0[{page, off}];
        2'd1: gv_byte = dut.u_gmem.mem1[{page, off}];
        2'd2: gv_byte = dut.u_gmem.mem2[{page, off}];
        default: gv_byte = dut.u_gmem.mem3[{page, off}];
      endcase
    end
  endfunction


  task backend_byte(input [31:0] addr, output [7:0] val);
    reg [31:0] o;
    begin
      o = addr - GVRAM_BASE;
      case (o[1:0])
        2'd0: val = dut.u_gmem.mem0[o[17:2]];
        2'd1: val = dut.u_gmem.mem1[o[17:2]];
        2'd2: val = dut.u_gmem.mem2[o[17:2]];
        default: val = dut.u_gmem.mem3[o[17:2]];
      endcase
    end
  endtask

  // The backend contract this core uses (src/memory/sdram.v: "byte address
  // (bits [1:0] ignored)", byte enables are lanes of the addressed DWORD), so the
  // store is indexed by the dword and the byte enable picks the lane.
  wire [31:0] mem_dword = {mem_addr[31:2], 2'b00};

  // A READ IS ANSWERED ONE BEAT PER WORD, `mem_burstcount` of them, exactly as src/memory/sdram.v
  // answers a burst (sdram.v:7). The GVRAM's write-combining buffer prefetches a short run of
  // consecutive words on a miss, so a model that answered ONE beat per REQUEST - which is all any
  // bench needed while cb_burstcount was hard-wired to 1 - would wedge the buffer mid-fill.
  reg [3:0]  rd_left = 4'd0;
  reg [31:0] rd_addr = 32'd0;

  always @(posedge clk) begin
    mem_resp_valid <= 1'b0;
    if (reset) begin
      rd_left <= 4'd0;
      rd_addr <= 32'd0;
    end else if (mem_valid && mem_ready && (rd_left == 4'd0)) begin
      if (mem_write) begin
        backend_writes = backend_writes + 1;
        for (integer q = 0; q < 4; q = q + 1)
          if (mem_be[q]) backend[mem_dword - BACKEND_BASE + q] <= mem_din[{q, 3'b000} +: 8];
        // The GVRAM's opt-in TWO-WORD write: word 0 on mem_din, word 1
        // on mem_din_hi at the NEXT dword. A mirror that applied only word 0 would read back a
        // half-written page and call the design wrong.
        if (mem_write && (mem_burstcount[3:0] == 4'd2))
          for (integer q = 0; q < 4; q = q + 1)
            if (mem_be[q])
              backend[mem_dword - BACKEND_BASE + 4 + q] <= mem_din_hi[{q, 3'b000} +: 8];
      end else begin
        backend_reads = backend_reads + 1;
        rd_addr <= mem_dword;
        rd_left <= (mem_burstcount == 8'd0) ? 4'd1 : mem_burstcount[3:0];
      end
    end
    // A word per clock from the store; the SDRAM's own latency is not what this bench measures.
    if (rd_left != 4'd0) begin
      resp_data_r <= {backend[rd_addr - BACKEND_BASE + 3],
                      backend[rd_addr - BACKEND_BASE + 2],
                      backend[rd_addr - BACKEND_BASE + 1],
                      backend[rd_addr - BACKEND_BASE]};
      mem_resp_valid <= 1'b1;
      rd_addr <= rd_addr + 32'd4;
      rd_left <= rd_left - 4'd1;
    end
  end
  // The read data is valid in the same cycle as the response, so it must be
  // combinational: a registered mem_dout would hand the engine the previous
  // read's word.
  always @* mem_dout = resp_data_r;

  initial begin : backend_init
    integer k;
    for (k = 0; k < BACKEND_BYTES; k = k + 1) backend[k] = 8'h00;
  end

  integer errors = 0;
  // Section 8's differential: whether the emitted unit differed from the source
  // at dir = 0, and whether the two directions' streams differed from each
  // other. Both must hold.
  reg     shifted_any = 1'b0;
  reg     dirs_differ = 1'b0;

  task automatic fail(input [8*100-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== REGISTER LOCKS, as the firmware and the games write them ====
  task automatic egc_set_access(input [15:0] v);
    begin @(negedge clk); egc_access = v; end
  endtask
  task automatic egc_set_fgbg(input [15:0] v);
    begin @(negedge clk); egc_fgbg = v; end
  endtask
  task automatic egc_set_ope(input [15:0] v);
    begin @(negedge clk); egc_ope = v; end
  endtask
  task automatic egc_set_mask(input [15:0] v);
    begin @(negedge clk); egc_mask = v; end
  endtask
  task automatic egc_set_fg(input [15:0] v);
    begin @(negedge clk); egc_fg = v; end
  endtask
  task automatic egc_set_bg(input [15:0] v);
    begin @(negedge clk); egc_bg = v; end
  endtask
  // 0x4AC/0x4AE re-arm the shifter (NP2kai egcshift), so they get the pulse the
  // I/O bus would give them.
  task automatic egc_set_shift(input [15:0] sft, input [15:0] leng);
    begin
      @(negedge clk);
      egc_sft = sft;
      egc_leng = leng;
      egc_shift_we = 1'b1;
      @(negedge clk);
      egc_shift_we = 1'b0;
    end
  endtask

  // ==== CPU ACCESS, in the shape z486 actually puts on the bus ====
  // THE ADDRESS'S LOW TWO BITS ARE NOT ON THE BUS. z486's address output is 30 bits
  // ("Physical address [31:2]", z486.sv:78) and pc9821_system forms the guest address
  // as {z_addr, 2'b00} (pc9821_system.sv:647,1061), so every access arrives
  // dword-aligned with the operand's byte lane carried ONLY by cpu_be -- z486's
  // calc_be(op_size, addr_low) (z486_pkg.sv:1169) and shift_write_data() (:1193).
  // This is the shape the subsystem and pc9821_gvram see on the machine; it is the
  // shape the existing benches did NOT drive, which is why the EGC's lane bug was
  // invisible to them.
  task automatic cpu_word_write(input [31:0] addr, input [15:0] data);
    begin
      @(negedge clk);
      cpu_addr = {addr[31:2], 2'b00};
      cpu_din = addr[1] ? {data, 16'd0} : {16'd0, data};
      cpu_be = (addr[1] ? 4'b1100 : 4'b0011);
      cpu_write = 1;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.u_egc.state != 4'd0) @(negedge clk);
      gvram_flush();
      // The backend store is non-blocking, so give it the edge it lands on.
      repeat (3) @(posedge clk);
    end
  endtask

  task automatic cpu_word_read(input [31:0] addr, output [15:0] data);
    begin
      @(negedge clk);
      cpu_addr = {addr[31:2], 2'b00};
      cpu_be = (addr[1] ? 4'b1100 : 4'b0011);
      cpu_write = 0;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      // Released at the ready edge (z486's shape, src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`),
      // before the pipelined produce's response cycle - held into it, the S_IDLE accept
      // takes the request twice. Read values are unchanged (EGCREAD.CSV / the machine vectors).
      cpu_valid = 0;
      cpu_be = 0;
      while (!cpu_resp_valid) @(negedge clk);
      #1;
      data = addr[1] ? cpu_dout[31:16] : cpu_dout[15:0];
      @(negedge clk);
      while (dut.u_egc.state != 4'd0) @(negedge clk);
      gvram_flush();
      repeat (3) @(posedge clk);
    end
  endtask

  task automatic cpu_byte_write(input [31:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      cpu_addr = {addr[31:2], 2'b00};
      cpu_din = {24'd0, data} << {addr[1:0], 3'b000};
      cpu_be = 4'b0001 << addr[1:0];
      cpu_write = 1;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.u_egc.state != 4'd0) @(negedge clk);
      gvram_flush();
      repeat (3) @(posedge clk);
    end
  endtask

  // A 32-bit guest store, the shape z486 presents (dword-aligned address, be = 1111).
  task automatic cpu_dword_write(input [31:0] addr, input [31:0] data);
    begin
      @(negedge clk);
      cpu_addr = {addr[31:2], 2'b00};
      cpu_din  = data;
      cpu_be   = 4'hF;
      cpu_write = 1;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.u_grcg.gstate != 3'd0) @(negedge clk);
      gvram_flush();
      repeat (3) @(posedge clk);
    end
  endtask

  // The GRCG's own register port (0x7C mode, 0x7E tiles), as the games write it.
  task automatic grcg_w(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk);
      grcg_we = 1; grcg_addr = a; grcg_din = d;
      @(negedge clk);
      grcg_we = 0;
    end
  endtask

  // The GVRAM's plane stores are COALESCED in a small write-back buffer now: a store to a
  // word that is already held completes with no SDRAM access, and the held word goes back as ONE
  // full-word write on eviction or on a flush. The backend[] mirror this bench observes is the
  // SDRAM content, so it is current only once the buffer has drained. Pulse the coalescer's own
  // flush (a raster line tick) and wait for it, so every check below reads the bytes the store
  // committed. Without this the mirror lags the store by the buffer's hold time.
  task automatic gvram_flush;
    begin
      @(negedge clk);
      scan_line_tick = 1'b1;
      @(negedge clk);
      scan_line_tick = 1'b0;
      @(posedge clk);
      while (1'b0) @(posedge clk);
      @(posedge clk);
    end
  endtask

  // A 16-bit port-style write of one of the EGC registers, as the firmware and
  // the games issue them: the value is what lands in the latch, so the bench
  // writes the latch directly (see the header on the gate).
  task automatic port_write16(inout [15:0] regv, input [15:0] data);
    begin
      @(negedge clk);
      regv = data;
    end
  endtask

  // The plane window the plain path writes through: the plane is selected by the
  // WINDOW for a plain access, and only the GRCG/EGC alias it away.
  function automatic [31:0] win_of(input [1:0] p);
    begin
      case (p)
        2'd0: win_of = WIN_P0;
        2'd1: win_of = WIN_P1;
        2'd2: win_of = WIN_P2;
        default: win_of = WIN_P3;
      endcase
    end
  endfunction

  // ==== CHECKS ====
  reg [7:0] b;
  reg [15:0] w;

  // TH01 op_01.cpp:257 whiteline_put(): GRCG RMW, tile 15, one 80-byte row of
  // 32-bit stores through the B window.
  task automatic whiteline_put(input integer y);
    begin
      grcg_w(8'h7C, 8'hC0);
      grcg_w(8'h7E, 8'hFF); grcg_w(8'h7E, 8'hFF);
      grcg_w(8'h7E, 8'hFF); grcg_w(8'h7E, 8'hFF);
      for (integer x = 0; x < 20; x = x + 1)
        cpu_dword_write(WIN_P0 + ((y*80) + x*4), 32'hFFFF_FFFF);
      grcg_w(8'h7C, 8'h00);
    end
  endtask

  // th01/hardware/egcrect.cpp:3 egc_copy_rect_1_to_0_16(): one 16-dot chunk per
  // row, read page 1 and write page 0 at the same plane offset. egc_start_copy()
  // = egc_on() (0x7C = 0x80, FF2 num 2) + EGC_SETUP_COPY.
  task automatic egc_copy_rect_1_to_0_16(
      input integer left, input integer top, input integer w_px, input integer h
  );
    integer x_floor, x_end, vo, row;
    begin
      egc_enable = 1'b1;
      egc_set_access(16'hFFF0);
      egc_set_fgbg(16'h00FF);
      egc_set_ope(16'h3100);            // COMPAREREAD | WS_PATREG | RL_MEMREAD
      egc_set_mask(16'hFFFF);
      egc_set_shift(16'h0000, 16'h000F);
      x_floor = (left / 16) * 16;
      x_end   = left + w_px;
      for (row = 0; row < h; row = row + 1) begin
        vo = ((top + row) * 80) + (x_floor / 8);
        while (vo < (((top + row) * 80) + (x_floor / 8)) + ((x_end - x_floor + 15) / 16) * 2) begin
          gvram_access_page = 1'b1;
          // A PLOAD_R (RL_MEMREAD) read latches the SELECTED PAT plane only - "Normal PLOAD_R
          // loads the selected PAT plane only.  Four-plane PAT setup uses four selected reads"
          // (PC98_EGC_CONFORMANCE v1.3 README; its RD02_PAT_S0..S3 rows, replayed by
          // tb_pc9821_egc_compare section 3) - where NP2kai latches all four from one read. So the
          // 0x4A2 read-plane selector walks 0..3 over the same source word, exactly as the
          // suite's own four-plane PAT setup does.
          for (integer k = 0; k < 4; k = k + 1) begin
            egc_set_fgbg({6'h00, k[1:0], 6'h00, k[1:0]});
            cpu_word_read(WIN_P0 + vo, w);
          end
          egc_set_fgbg(16'h00FF);
          gvram_access_page = 1'b0;
          cpu_word_write(WIN_P0 + vo, w);
          vo = vo + 2;
        end
      end
      egc_enable = 1'b0;
      // egc_off(): FF2 num 2 clear, then the GRCG off.
      grcg_w(8'h7C, 8'h00);
    end
  endtask

  // th01/formats/ptn_main.cpp ptn_put_quarter_8()/ptn_put_quarter(): vram_erase()
  // is the GRCG in RMW with zero tiles and the alpha row as the data, then the
  // sprite's four planes are OR'd in through their own windows (GRCG off).
  task automatic sprite_put(input integer left, input integer top, input [15:0] alpha);
    integer vo;
    begin
      grcg_w(8'h7C, 8'hC0);
      grcg_w(8'h7E, 8'h00); grcg_w(8'h7E, 8'h00);
      grcg_w(8'h7E, 8'h00); grcg_w(8'h7E, 8'h00);
      for (integer row = 0; row < 16; row = row + 1) begin
        vo = ((top + row) * 80) + (left / 8);
        cpu_word_write(WIN_P0 + vo, alpha);
      end
      grcg_w(8'h7C, 8'h00);
      for (integer row = 0; row < 16; row = row + 1) begin
        vo = ((top + row) * 80) + (left / 8);
        for (integer p = 0; p < 4; p = p + 1) begin
          cpu_word_read(WIN_P0 + (p * 32'h8000) + vo, w);
          cpu_word_write(WIN_P0 + (p * 32'h8000) + vo, w | (alpha & 16'h0F0F));
        end
      end
    end
  endtask

  function automatic [7:0] bg0(input integer off, input [1:0] p);
    begin
      bg0 = 8'h11 + (p * 8'h11) + off[7:0];
    end
  endfunction

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    ioctl_download = 1;
    @(negedge clk);
    ioctl_addr = 27'd0; ioctl_dout = 16'hBEEF; ioctl_wr = 1;
    @(negedge clk);
    ioctl_wr = 0;
    ioctl_download = 0;
    repeat (5) @(posedge clk);
    if (!cpu_run) fail("the CPU never came out of the ROM-load hold");

    begin : seq
      integer off, row, p, bad;
      integer ytop = 4;

      // The background: page 0 and page 1 hold the same distinct bytes, so a
      // restore that lands anywhere else, or not at all, is visible.
      for (off = 0; off < 3600; off = off + 2)
        for (p = 0; p < 4; p = p + 1)
          cpu_word_write(win_of(p[1:0]) + off, {bg0(off + 1, p[1:0]), bg0(off, p[1:0])});
      gvram_access_page = 1'b1;
      for (off = 0; off < 3600; off = off + 2)
        for (p = 0; p < 4; p = p + 1)
          cpu_word_write(win_of(p[1:0]) + off, {bg0(off + 1, p[1:0]), bg0(off, p[1:0])});
      gvram_access_page = 1'b0;

      // ============================================================
      // 1. THE INTRO'S WHITE LINES (symptom 1). whitelines_animate()
      //    clears the two rows it drew last frame with
      //    egc_copy_rect_1_to_0_16(0, y, RES_X, 1) and then draws two new rows
      //    with whiteline_put(). The clear must put the BACKGROUND back.
      // ============================================================
      $display("note: bg p0 320..323 = %02x %02x %02x %02x | p1 = %02x %02x %02x %02x",
               gv_byte(0,2'd0,320),gv_byte(0,2'd0,321),gv_byte(0,2'd0,322),gv_byte(0,2'd0,323),
               gv_byte(1,2'd0,320),gv_byte(1,2'd0,321),gv_byte(1,2'd0,322),gv_byte(1,2'd0,323));
      whiteline_put(ytop);
      bad = 0;
      for (off = 0; off < 80; off = off + 1)
        for (p = 0; p < 4; p = p + 1)
          if (gv_byte(0, p[1:0], (ytop*80) + off[14:0]) !== 8'hFF) bad = bad + 1;
      if (bad != 0) fail("the whiteline was not drawn in all four planes");

      $display("note: after draw p0 320..323 = %02x %02x %02x %02x | p1 = %02x %02x %02x %02x",
               gv_byte(0,2'd0,320),gv_byte(0,2'd0,321),gv_byte(0,2'd0,322),gv_byte(0,2'd0,323),
               gv_byte(1,2'd0,320),gv_byte(1,2'd0,321),gv_byte(1,2'd0,322),gv_byte(1,2'd0,323));
      egc_copy_rect_1_to_0_16(0, ytop, 640, 1);
      $display("note: after copy p0 320..323 = %02x %02x %02x %02x | p1 = %02x %02x %02x %02x",
               gv_byte(0,2'd0,320),gv_byte(0,2'd0,321),gv_byte(0,2'd0,322),gv_byte(0,2'd0,323),
               gv_byte(1,2'd0,320),gv_byte(1,2'd0,321),gv_byte(1,2'd0,322),gv_byte(1,2'd0,323));
      bad = 0;
      for (off = 0; off < 80; off = off + 1)
        for (p = 0; p < 4; p = p + 1)
          if (gv_byte(0, p[1:0], (ytop*80) + off[14:0]) !==
              gv_byte(1, p[1:0], (ytop*80) + off[14:0])) bad = bad + 1;
      if (bad != 0)
        fail("the EGC row restore did not put the background back: the whiteline survives in some planes/bytes");
      if (gv_byte(0, 2'd0, (ytop*80) + 2) !== bg0((ytop*80) + 2, 2'd0))
        fail("the EGC row restore wrote something other than the saved background");

      // The other half of the same row, and the lane's discriminating case: a
      // 16-bit chunk at a plane offset of 2 (mod 4) is on lanes 2:3.
      if (gv_byte(0, 2'd1, (ytop*80) + 70) !== bg0((ytop*80) + 70, 2'd1))
        fail("a lane-2:3 chunk of the EGC row restore did not come back");

      // ============================================================
      // 2. THE TALISMANS (symptom 2). ptn_put_quarter_8() erases the
      //    sprite's footprint with the GRCG RMW and zero tiles, draws the
      //    sprite, and the next frame restores it with
      //    ptn_sloppy_unput_quarter_16() = egc_copy_rect_1_to_0_16(left, top,
      //    16, 16). The black footprint must NOT survive.
      // ============================================================
      // (a) a footprint whose two bytes are on lanes 0:1, and (b) one on 2:3.
      // egc_copy_rect_1_to_0_16 rounds the chunk down to a 16-pixel boundary, so
      // the restored word is the one containing the sprite's first byte.
      for (integer which = 0; which < 2; which = which + 1) begin
        integer left;
        integer top;
        left = (which == 0) ? 64 : 112;      // byte 8 (lane 0) or byte 14 (lane 2)
        top  = 8 + (which * 20);
        sprite_put(left, top, 16'hF0F0);
        if (gv_byte(0, 2'd0, (top*80) + (left/8)) === bg0((top*80) + (left/8), 2'd0))
          fail("the sprite erase did not change the background");
        egc_copy_rect_1_to_0_16(left, top, 16, 16);
        bad = 0;
        for (row = 0; row < 16; row = row + 1)
          for (off = 0; off < 2; off = off + 1)
            for (p = 0; p < 4; p = p + 1)
              if (gv_byte(0, p[1:0], (((top+row)*80) + (left/8)) + off[14:0]) !==
                  gv_byte(1, p[1:0], (((top+row)*80) + (left/8)) + off[14:0])) bad = bad + 1;
        if (bad != 0)
          fail("the sprite restore left the erased footprint behind (black trails)");
      end
    end

  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_SPRITE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_SPRITE: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog (the runner bounds wall time too, but a bench that blocks
  // on a DUT signal with no bound would hang CI forever).
  initial begin
    #60_000_000;
    $fatal(1, "TB_PC9821_SPRITE: TIMEOUT");
  end

endmodule

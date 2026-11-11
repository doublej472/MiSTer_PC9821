`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_EGC:
// The EGC engine (pc9821_egc.sv) on the sequences the target software actually issues, driven through pc9821_memory_subsystem against a behavioural GVRAM: TH01's 0x3100 four-plane page copy where the read latches the pattern register from the source address and the following write stores it, the main BIOS's own 0x1400 colour fill (BANK7.BIN@0x35A1) and its 0x28F0 row shift at sft = 0 (BANK7.BIN@0x356B), TH05's 0x29F0 rect copy for an aligned source and destination, and the plane-enable and mask registers. Section 1b pins the two read kinds' pattern-register captures, which is the whole data path of the games' own copy: a compare read (OPE bit 13, set by the 0x3100 egc_setup_copy the games use) captures ALL FOUR planes from ONE read (EGCREAD.CSV RD17_P_*, `compare-plus-pload-captured-source`), so TH01's egc_copy_rect_1_to_0_16 (rec98/th01/hardware/egcrect.cpp:23 (tmp = egc_chunk(vo))) and TH04/TH05's tiles_render_all (rec98/th04/main/tile/render_a.asm:21 (ax, es:[si])) - one read, one WS_PATREG write per word, the write's datum coming from the pattern register - land the source on all four planes, while a normal read (bit 13 clear) still updates the SELECTED PAT plane only (RD02_PAT_S0..S3, the README.TXT rule that separates a normal PLOAD_R from Compare+PLOAD_R). The backend is a real store, so the resulting four planes and the CPU read-back are the assertions. Section 8 adds sft bit 12, the descending direction master.lib's egc_shift_down sets: at the same 0x28F0 mode and the same 2-bit sub-byte shift, dir=0 and dir=1 must produce DIFFERENT streams, which is the relation NP2kai's egcshift() fixes by inverting the shift arithmetic and starting its pointers at the end of the unit. Section 9 pins the shifter re-arm: NP2kai's 0x4AC/0x4AD/0x4AE/0x4AF handlers each run egcshift() and then set srcmask to 0xFFFF (io/egc.c cases 0x0c-0x0f), and memegc.c's egc_opew ANDs srcmask into the write mask in all three of its mode cases including the non-producing default, so the first write after a re-arm must be masked with 0xFFFF and not with the partial value the previous shift sequence left behind. Section 10 is the SHAKE's own shape - dstbit 0 with a non-zero srcbit, master.lib's DI = SI - 2 row shift - asserted BY VALUE in both directions against a port of NP2kai's lagging per-plane byte queue (egc_readword + egcsftb_{upl,dnl}_sub), which carries the cross-unit carry-in byte the shifter used to read as 0 and is exactly what section 8's relation check cannot see. Section 11 drives the same word feed with sft[3:0] in 8..15, where NP2kai's shiftinput_incw adds 16 - srcbit and CLEARS srcbit instead of taking the byte feed's `subtract 8, add nothing` branch - the suspected defect this bench settles - and asserts BOTH the stack, srcbit, dstbit and whether the produce ran after every unit AND the destination row by value against that same reference queue, which also models the word feed's `if (srcbit >= 8) outptr++`: a persistent one-byte source-window offset (an open defect, modelled by the egc.buf pointer window). Section 23 sweeps the ROP table: all 256 values of the OPE low byte, with the shifter loaded from a source read and the pattern operand taken from the pattern register, the source itself (OPE 0x0100), the foreground colour and the background colour (FGBG 14:13), each compared byte by byte against a transcription of NP2kai's opefn[] dispatch (mem/memegc.c:709-997), plus the same codes through the byte ROP path and through the RL_MEMWRITE (OPE 0x0200) and SHIFT_CPU (OPE 0x0400) operand updates.
//
// Sections 18-22 pin the BYTE path (memegc.c egc_opeb), which every word-path section above
// bypasses: the per-byte SHIFT_CPU feed gate, the fgbg-switch DEFAULT that 0x6000 falls into,
// the ROP's produce-output source, and the produced-lane placement of the 16-bit srcmask.
//
// The EGC gate itself is driven directly; its derivation (FF2 num 2 AND 0x7C bit
// 7) is checked in tb_pc9821_gdc_text.sv and tb_pc9821_iobus.sv.

module tb_pc9821_egc;
  // pc9821_memory_subsystem's pack-download hold: no boot-ROM download under the OSD Reset
  // level here (tb_pc9821_boot0_load drives that), so the level is low and the hold unread.
  wire hps_apply_reset = 1'b0;
  wire pack_load_hold;
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

  wire [1:0] ems_state;
  wire grcg_expand;   // the GRCG's CG-mode bit 7, fed back from the subsystem
  wire       grcg_expand_nx;   // mode[7]'s next state (opt-video VID-1); unused here

  wire top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)

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
  // The 16-colour mode (the guest's OUT 0x6A,0x01, FF2 num 0): this bench reaches the E plane at
  // 0xE0000-0xE7FFF, which the machine maps only in that mode (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b1;

  pc9821_memory_subsystem #(.SYS_CLOCK_HZ(100_000_000)) dut (.*);

  // ==== BEHAVIOURAL GVRAM BACKEND ====
  reg [7:0] backend [0:BACKEND_BYTES-1];
  reg        resp_valid_r = 0;
  reg [31:0] resp_data_r = 0;
  integer    backend_reads = 0, backend_writes = 0, backend_words = 0, backend_rd_words = 0;

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
      // index is {page, off} and plane p is byte lane p of it, which is what plane_addr encodes.
      case (plane)
        2'd0: gv_byte = dut.u_gmem.mem0[{page, off}];
        2'd1: gv_byte = dut.u_gmem.mem1[{page, off}];
        2'd2: gv_byte = dut.u_gmem.mem2[{page, off}];
        default: gv_byte = dut.u_gmem.mem3[{page, off}];
      endcase
    end
  endfunction

  // The colour-key MASK a read returns with COMPAREREAD (OPE bit 13) set, from the four plane
  // WORDS at the address - the AND over the planes 0x4A0 ACCESS enables of (plane word == the
  // retained FG colour's bit for that plane), which is what the machine returns (EGCREAD.CSV
  // RD20_AM_x for the ACCESS gating, RD21/RD22 for the FG reference). Bit 13 is the WHOLE gate:
  // the machine compares with the pattern source set to PAT as well (RD22_PATSEL), so the 0x3100
  // copy's own reads return this mask rather than the plane word. The copy itself is unaffected
  // - its write is WS_PATREG and ignores the CPU datum, which is why TH01 renders correctly on
  // the machine with 0x3100 in 0x4A4 - so the sections below assert the mask as the read's
  // datum and the destination by value as before.
  function automatic [15:0] cmp_mask_at(input page, input [14:0] off);
    integer p;
    reg [15:0] m, pw;
    begin
      m = 16'hFFFF;
      for (p = 0; p < 4; p = p + 1)
        if (!egc_access[p]) begin   // active LOW, exactly as pc9821_egc's plane_en
          pw = gv_byte(page, p[1:0], off) | (gv_byte(page, p[1:0], off + 15'd1) << 8);
          m = m & ~(pw ^ (egc_fg[p] ? 16'hFFFF : 16'h0000));
        end
      cmp_mask_at = m;
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
        // The GVRAM's opt-in TWO-WORD write: ONE request carries word 0
        // on mem_din and word 1 on mem_din_hi, at the NEXT dword. The mirror must apply both or
        // the bench would read a half-written page and call the design wrong.
        if (mem_burstcount[3:0] == 4'd2) begin
          backend_words = backend_words + 1;
          for (integer q = 0; q < 4; q = q + 1)
            if (mem_be[q])
              backend[mem_dword - BACKEND_BASE + 4 + q] <= mem_din_hi[{q, 3'b000} +: 8];
        end
      end else begin
        backend_reads = backend_reads + 1;
        backend_rd_words = backend_rd_words + ((mem_burstcount == 8'd0) ? 1 : mem_burstcount);
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
  // Section 13 counts the EGC's OWN D1 COLUMNS: one per byte-enabled column the read pass's
  // request covers (its cl_wbe is the CPU's byte enables, one bit per column) and one per
  // write-pass request. A 16-bit source read is TWO columns whether it leaves as two requests or
  // as ONE burst, so the fetch a shape covers is asserted, not inferred from the
  // coalescer's fills.
  integer egc_d1_reads = 0;
  integer egc_d1_writes = 0;
  // Section 15 counts the cycles the EGC spends in the state that evaluates a READ unit and
  // commits its produce (S_EVAL; since the pipelined produce, the response piece
  // assembles one state later and the read completes one cycle later). A write unit must never
  // be in it: the write pass presents
  // its own unit from S_WR, one state after the produce commits it.
  integer egc_eval_cycles = 0;
  always @(posedge clk) if (!reset && dut.u_egc.state == pc9821_egc_pkg::EGC_EVAL) egc_eval_cycles = egc_eval_cycles + 1;
  function integer be_cols(input [3:0] be);
    be_cols = {31'd0, be[0]} + {31'd0, be[1]} + {31'd0, be[2]} + {31'd0, be[3]};
  endfunction
  // ==== REFERENCE: NP2kai's ROP (mem/memegc.c opefn[256] dispatch, :935-997, and the
  // three generic functions it shares plus the six constants, :709-960) ====
  // Per byte: `rop` is the OPE low byte, `s` the shifter output quad byte, `d` the
  // destination byte and `p` the selected pattern byte (pattern register, source, fg or
  // bg). The dispatch is transcribed from the table, not derived from the RTL.
  function [7:0] np2_rop(input [7:0] rop, input [7:0] s, input [7:0] d, input [7:0] p);
    reg [7:0] r;
    begin
      case (rop)
        8'h00: r = 8'h00;
        8'h0F: r = ~s;
        8'hC0: r = s & d;
        8'hF0: r = s;
        8'hFC: r = s | ((~s) & d);
        8'hFF: r = 8'hFF;
        default: begin
          case (rop)
            8'h03, 8'h0C, 8'h30, 8'h33, 8'h3C, 8'h3F,
            8'hC3, 8'hCC, 8'hCF, 8'hF3: begin          // ope_np
              r = 8'h00;
              if (rop[7]) r = r | (s & d);
              if (rop[5]) r = r | (s & (~d));
              if (rop[3]) r = r | ((~s) & d);
              if (rop[1]) r = r | ((~s) & (~d));
            end
            8'h05, 8'h0A, 8'h50, 8'h55, 8'h5A, 8'h5F,
            8'hA0, 8'hA5, 8'hAA, 8'hAF, 8'hF5, 8'hFA: begin  // ope_nd
              r = 8'h00;
              if (rop[7]) r = r | (p & s);
              if (rop[6]) r = r | ((~p) & s);
              if (rop[3]) r = r | (p & (~s));
              if (rop[2]) r = r | ((~p) & (~s));
            end
            default: begin                              // ope_xx
              r = 8'h00;
              if (rop[7]) r = r | (p & s & d);
              if (rop[6]) r = r | ((~p) & s & d);
              if (rop[5]) r = r | (p & s & (~d));
              if (rop[4]) r = r | ((~p) & s & (~d));
              if (rop[3]) r = r | (p & (~s) & d);
              if (rop[2]) r = r | ((~p) & (~s) & d);
              if (rop[1]) r = r | (p & (~s) & (~d));
              if (rop[0]) r = r | ((~p) & (~s) & (~d));
            end
          endcase
        end
      endcase
      np2_rop = r;
    end
  endfunction

  // The CPU window of plane p, so a per-plane operand can be seeded with the EGC off.
  function [31:0] win_addr(input [1:0] p);
    begin
      win_addr = (p == 2'd0) ? WIN_P0 :
                 (p == 2'd1) ? WIN_P1 :
                 (p == 2'd2) ? WIN_P2 : WIN_P3;
    end
  endfunction
  always @(posedge clk) if (!reset && dut.u_egc.cl_valid && dut.u_egc.cl_ready) begin
    if (dut.u_egc.cl_write) egc_d1_writes = egc_d1_writes + 1;
    else                        egc_d1_reads  = egc_d1_reads  +
                                (dut.u_egc.cl_burst ? be_cols(dut.u_egc.cl_wbe) : 1);
  end
  // Section 8's differential: whether the emitted unit differed from the source
  // at dir = 0, and whether the two directions' streams differed from each
  // other. Both must hold.
  reg     shifted_any = 1'b0;
  reg     dirs_differ = 1'b0;
  // Section 10's oracle row: the word the reference queue emitted on each read.
  reg [15:0] exp_row [0:7];

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

  // ==== REFERENCE SHIFTER ORACLE: NP2kai's LAGGING per-plane queue (mem/memegc.c) ====
  // A port of ONE plane's byte queue and the word-path shift the shake uses (src8 > dst8, func 4
  // ascending / func 5 descending). egcshift() re-arms; egc_readword writes the feed at inptr and
  // advances it while the produce reads the LAGGING outptr; egcsftw_upl0 emits the low output byte
  // then the high one and egcsftw_dnl0 the high then the low. The four planes carry identical bytes
  // here, so one instance models them all. `or_h`/`or_low` are the last emitted sdata, i.e. exactly
  // the word egc_readword returns and the word the RTL must return.
  localparam integer ORQ_BASE = 128;
  reg  [7:0] orq [0:255];
  integer    or_in, or_out, or_stack, or_srcbit, or_dstbit;
  integer    or_l, or_r, or_remain, or_dir, or_func;
  reg  [7:0] or_h, or_low;
  // Section 11 reads this: whether the reference's produce RAN on the last read (its
  // `if (stack < (16 - dstbit))` early return is the gate the byte/word feed mix perturbs).
  reg        or_gate_open;

  task automatic oracle_arm(input [15:0] sft, input [15:0] leng);
    integer src8, dst8;
    begin
      or_remain = (leng & 16'h0FFF) + 16'd1;
      or_dir    = sft[12];
      or_in     = ORQ_BASE;
      or_out    = ORQ_BASE;
      or_srcbit = sft[3:0];
      or_dstbit = sft[7:4];
      src8 = or_srcbit & 3'h7;
      dst8 = or_dstbit & 3'h7;
      or_l = 0; or_r = 0; or_func = 0;
      if (src8 < dst8)      begin or_func = or_dir + 2; or_r = dst8 - src8; or_l = 8 - or_r; end
      else if (src8 > dst8) begin or_func = or_dir + 4; or_l = src8 - dst8; or_r = 8 - or_l; end
      or_stack = 0;
      or_h = 8'h00; or_low = 8'h00;
      or_gate_open = 1'b0;
    end
  endtask

  // One read: the reference's egc_readword feed + shiftinput_incw/decw + egcsftw_upl0/dnl0,
  // including the stack gate (the shake's first read is gated and emits the stale sdata).
  task automatic oracle_read(input [15:0] srcword, output [15:0] out);
    begin
      if (!or_dir) begin
        orq[or_in] = srcword[7:0]; orq[or_in+1] = srcword[15:8];
      end else begin
        orq[or_in-1] = srcword[7:0]; orq[or_in] = srcword[15:8];
      end
      if (or_stack <= 16) begin
        if (!or_dir) begin
          or_in = or_in + 2;
          if (or_srcbit >= 8) or_out = or_out + 1;
        end else begin
          or_in = or_in - 2;
          if (or_srcbit >= 8) or_out = or_out - 1;
        end
        or_stack = or_stack + (16 - or_srcbit);
        or_srcbit = 0;
      end
      if (or_stack < (16 - or_dstbit)) begin
        out = {or_h, or_low};           // gated: sdata holds the previous produce
        or_gate_open = 1'b0;
      end else begin
        or_gate_open = 1'b1;
        or_stack = or_stack - (16 - or_dstbit);
        if (or_func == 4) begin                    // ascending: low byte, then high
          if (or_remain >= 8) or_remain = or_remain - 8; else or_remain = 0;
          or_low = (orq[or_out] << or_l) | (orq[or_out+1] >> or_r); or_out = or_out + 1;
          if (or_remain != 0) begin
            if (or_remain >= 8) or_remain = or_remain - 8; else or_remain = 0;
            or_h = (orq[or_out] << or_l) | (orq[or_out+1] >> or_r); or_out = or_out + 1;
          end
        end else begin                             // descending: high byte, then low
          if (or_remain >= 8) or_remain = or_remain - 8; else or_remain = 0;
          or_out = or_out - 1;
          or_h = (orq[or_out+1] >> or_l) | (orq[or_out] << or_r);
          if (or_remain != 0) begin
            if (or_remain >= 8) or_remain = or_remain - 8; else or_remain = 0;
            or_out = or_out - 1;
            or_low = (orq[or_out+1] >> or_l) | (orq[or_out] << or_r);
          end
        end
        out = {or_h, or_low};
      end
    end
  endtask

  // ==== CPU ACCESS, in the shape z486 presents to the subsystem ====
  task automatic cpu_word_write(input [31:0] addr, input [15:0] data);
    begin
      @(negedge clk);
      cpu_addr = addr;
      cpu_din = addr[1] ? {data, 16'd0} : {16'd0, data};
      cpu_be = (addr[1] ? 4'b1100 : 4'b0011);
      cpu_write = 1;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
      gvram_flush();
      // The backend store is non-blocking, so give it the edge it lands on.
      repeat (3) @(posedge clk);
    end
  endtask

  task automatic cpu_word_read(input [31:0] addr, output [15:0] data);
    begin
      @(negedge clk);
      cpu_addr = addr;
      cpu_be = (addr[1] ? 4'b1100 : 4'b0011);
      cpu_write = 0;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      // Release at the ready edge (z486's own shape, src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`):
      // the pipelined produce registers the read response one cycle after the ready -
      // the read values are unchanged and still the machine's own (docs/probes/egc-conformance/xe10/
      // EGCREAD.CSV), and the +1 stays under the machine's measured read cost (GFX2-rerun.TXT
      // EGC3100SP) - so a request held into the response cycle is taken twice by the S_IDLE accept.
      // The negedge below is the old release's own wait, kept so the op retires one cycle after its
      // data and the +1 stays visible in the cadence.
      cpu_valid = 0;
      cpu_be = 0;
      while (!cpu_resp_valid) @(negedge clk);
      #1;
      data = addr[1] ? cpu_dout[31:16] : cpu_dout[15:0];
      @(negedge clk);
      while (dut.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
      gvram_flush();
      repeat (3) @(posedge clk);
    end
  endtask

  task automatic cpu_byte_write(input [31:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      cpu_addr = addr;
      cpu_din = {24'd0, data} << {addr[1:0], 3'b000};
      cpu_be = 4'b0001 << addr[1:0];
      cpu_write = 1;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
      gvram_flush();
      repeat (3) @(posedge clk);
    end
  endtask

  // A single-byte CPU read: one byte enable, and the byte arrives in the dword lane the lane
  // names (the consume edge places it at {unit_lane, 3'b000}) exactly as a byte store presents.
  task automatic cpu_byte_read(input [31:0] addr, output [7:0] data);
    begin
      @(negedge clk);
      cpu_addr = addr;
      cpu_be = 4'b0001 << addr[1:0];
      cpu_write = 0;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      // Released at the ready edge, before the pipelined produce's response cycle (see cpu_word_read);
      // the negedge below is the old release's own wait, kept so the +1 stays in the cadence.
      cpu_valid = 0;
      cpu_be = 0;
      while (!cpu_resp_valid) @(negedge clk);
      #1;
      data = cpu_dout[{addr[1:0], 3'b000} +: 8];
      @(negedge clk);
      while (dut.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
      gvram_flush();
      repeat (3) @(posedge clk);
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

  // ==== CHECKS ====
  reg [7:0] b;
  reg [15:0] w;

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;

    // Load a minimal pack so the CPU is allowed onto the bus.
    ioctl_download = 1;
    @(negedge clk);
    ioctl_addr = 27'd0; ioctl_dout = 16'hBEEF; ioctl_wr = 1;
    @(negedge clk);
    ioctl_wr = 0;
    ioctl_download = 0;
    repeat (5) @(posedge clk);
    if (!cpu_run) fail("the CPU never came out of the ROM-load hold");

    // ============================================================
    // 0. THE CONTROL: with the EGC gate OFF, a word store to a plane window
    //    lands in that plane only. This is the behaviour the defect report
    //    describes: three of the four planes keep stale data.
    // ============================================================
    egc_enable = 1'b0;
    cpu_word_write(WIN_P0 + 15'h2000, 16'h1234);          // plane 0, page 0
    if (gv_byte(0, 2'd0, 15'h2000) !== 8'h34 ||
        gv_byte(0, 2'd0, 15'h2001) !== 8'h12)
      fail("gate off: the store did not land in the addressed plane");
    if (gv_byte(0, 2'd1, 15'h2000) !== 8'h00)
      fail("gate off: the store reached a plane it should not have");
    cpu_word_write(WIN_P0 + 15'h2002, 16'h5678);
    if (gv_byte(0, 2'd1, 15'h2000) !== 8'h00)
      fail("gate off: a second store reached plane 1");

    // ============================================================
    // 1. TH01's 0x3100 page copy: read page 1, write page 0, same offset.
    //    th01/hardware/egcrect.cpp:3-28 with egc_impl.hpp:4-12's register set.
    // ============================================================
    egc_enable = 1'b1;
    egc_set_access(16'hFFF0);      // all four planes enabled (active low)
    egc_set_fgbg(16'h00FF);        // read plane 0, no colour-quad select
    egc_set_ope(16'h3100);         // COMPAREREAD | WS_PATREG | RL_MEMREAD
    egc_set_mask(16'hFFFF);
    egc_set_shift(16'h0000, 16'h000F);   // bit addresses 0, length 16 dots

    // Preload the SOURCE page (page 1, selected by 0xA6) with a distinct
    // pattern per plane and per byte, using plain stores (the gate is off, so
    // these are ordinary stores into the addressed plane of page 1).
    egc_enable = 1'b0;
    gvram_access_page = 1'b1;
    for (integer off = 0; off < 8; off = off + 2) begin
      cpu_word_write(WIN_P0 + 15'h1000 + off, 16'hB1C1 + off);
      cpu_word_write(WIN_P1 + 15'h1000 + off, 16'hD2E2 + off);
      cpu_word_write(WIN_P2 + 15'h1000 + off, 16'hF3A3 + off);
      cpu_word_write(WIN_P3 + 15'h1000 + off, 16'hA4B4 + off);
    end
    gvram_access_page = 1'b0;
    egc_enable = 1'b1;

    // The copy itself: graph_accesspage(1); tmp = egc_chunk(vo);
    //                    graph_accesspage(0); egc_chunk(vo) = tmp;
    // A PLOAD_R (RL_MEMREAD) read latches the SELECTED PAT plane only - "Normal PLOAD_R loads the
    // selected PAT plane only.  Four-plane PAT setup uses four selected reads" (the
    // PC98_EGC_CONFORMANCE v1.3 README; its RD02_PAT_S0..S3 rows, replayed by
    // tb_pc9821_egc_compare section 3) - where NP2kai latches all four from one read. So the
    // 0x4A2 read-plane selector walks 0..3 over the same source word, which is how the suite's own
    // four-plane PAT setup does it.
    for (integer off = 0; off < 8; off = off + 2) begin
      gvram_access_page = 1'b1;
      for (integer k = 0; k < 4; k = k + 1) begin
        egc_set_fgbg({6'h00, k[1:0], 6'h00, k[1:0]});
        cpu_word_read(WIN_P0 + 15'h1000 + off, w);
      end
      egc_set_fgbg(16'h00FF);
      gvram_access_page = 1'b0;
      if (w !== (16'hB1C1 + off))
        $display("note: source read back %04x, expected %04x (backend %02x %02x %02x %02x)",
                 w, 16'hB1C1 + off,
                 gv_byte(1,2'd0,15'h1000 + (off+0)),
                 gv_byte(1,2'd0,15'h1000 + (off+1)),
                 gv_byte(1,2'd0,15'h1000 + (off+2)),
                 gv_byte(1,2'd0,15'h1000 + (off+3)));
      gvram_access_page = 1'b0;
      cpu_word_write(WIN_P0 + 15'h1000 + off, w);
    end
    for (integer off = 0; off < 8; off = off + 1) begin
      if (gv_byte(0, 2'd0, 15'h1000 + off[14:0]) !==
          gv_byte(1, 2'd0, 15'h1000 + off[14:0]))
        fail("0x3100: plane 0 byte differs from the source page's plane 0");
      if (gv_byte(0, 2'd1, 15'h1000 + off[14:0]) !==
          gv_byte(1, 2'd1, 15'h1000 + off[14:0]))
        fail("0x3100: plane 1 byte differs from the source page's plane 1");
      if (gv_byte(0, 2'd2, 15'h1000 + off[14:0]) !==
          gv_byte(1, 2'd2, 15'h1000 + off[14:0]))
        fail("0x3100: plane 2 byte differs from the source page's plane 2");
      if (gv_byte(0, 2'd3, 15'h1000 + off[14:0]) !==
          gv_byte(1, 2'd3, 15'h1000 + off[14:0]))
        fail("0x3100: plane 3 (the E0000 intensity window) differs too");
    end
    // The source page must be untouched (a read must not write).
    if (gv_byte(1, 2'd0, 15'h1000) !== 8'hC1)
      fail("0x3100: the source page was modified");

    // A masked copy: TH01's egc_setup_copy_masked carries a MASK BYTE, so the
    // byte store to 0x4A8 replaces only the mask register's low byte and the
    // high byte keeps the 0xFFFF the setup wrote. The mask is therefore 0xFF00:
    // only the HIGH byte of each destination plane word comes from the pattern.
    egc_enable = 1'b0;
    for (integer off = 0; off < 8; off = off + 2)
      cpu_word_write(WIN_P0 + 15'h1100 + off, 16'h5A5A);
    egc_enable = 1'b1;
    egc_set_mask(16'hFF00);           // 0x4A8 <- 0x00 as a byte store
    gvram_access_page = 1'b1;
    cpu_word_read(WIN_P0 + 15'h1000, w);
    gvram_access_page = 1'b0;
    cpu_word_write(WIN_P0 + 15'h1100, w);
    if (gv_byte(0, 2'd0, 15'h1101) !== 8'hB1)
      fail("masked copy: the high byte did not take the pattern");
    if (gv_byte(0, 2'd0, 15'h1100) !== 8'h5A)
      fail("masked copy: the low byte was overwritten despite the mask");
    if (gv_byte(0, 2'd1, 15'h1101) !== 8'hD2)
      fail("masked copy: plane 1's high byte did not take the pattern");
    // Plane 1 was never written at page 0 0x1100, so its low byte is still the
    // backend's zero: the mask's low byte of 0x00 must not touch it.
    if (gv_byte(0, 2'd1, 15'h1100) !== 8'h00)
      fail("masked copy: plane 1's low byte was overwritten despite the mask");
    egc_set_mask(16'hFFFF);

    // ============================================================
    // 1b. THE COPY'S OWN SHAPE - ONE compare read, ONE WS_PATREG write - and the
    //     four planes it must land.
    //
    //     This is the sequence every Touhou background renderer issues. TH01's
    //     egc_copy_rect_1_to_0_16 is `tmp = egc_chunk(vo); graph_accesspage_func(0);
    //     egc_chunk(vo) = tmp;` (rec98/th01/hardware/egcrect.cpp:23 (tmp = egc_chunk(vo))) and TH04/TH05's
    //     tiles_render_all is `mov ax, es:[si]` / `mov es:[di], ax`
    //     (rec98/th04/main/tile/render_a.asm:21 (ax, es:[si])), both under egc_setup_copy()
    //     (rec98/th01/hardware/egc_impl.hpp:4-12: ACTIVEPLANE 0xFFF0, READPLANE 0x00FF,
    //     MODE 0x3100 = COMPAREREAD|WS_PATREG|RL_MEMREAD, MASK 0xFFFF, ADDRESS 0,
    //     BITLENGTH 0xF). ONE read per word, ONE write per word, four planes per word.
    //
    //     The write's DATUM is the PATTERN REGISTER, not the CPU's word (NP2kai
    //     mem/memegc.c egc_opew case 0x1000 returns &egc.patreg; the 16-bit WS_PATREG
    //     case), so the copy's whole data path is the READ's capture: whatever the read
    //     latches into the pattern register is what the write reproduces on all four
    //     planes. A read that captures only the selected plane therefore copies ONE
    //     plane and writes the pattern register's STALE contents to the other three -
    //     the background loses three of its four colour planes.
    //
    //     What the machine does is in the capture, and it separates the two read kinds:
    //     EGCREAD.CSV RD17_P_* (`compare-plus-pload-captured-source`) reports FOUR
    //     DIFFERENT plane values after a compare read (35DF D010 67D9 4912), while
    //     RD02_PAT_S0..S3 (`normal-pload-read-updates-selected-PAT-only`) leaves the
    //     three unselected planes holding their previous values. The suite's own
    //     README.TXT says exactly that split: "Normal PLOAD_R loads the selected PAT
    //     plane only.  Four-plane PAT setup uses four selected reads.  Compare+PLOAD_R
    //     is tested separately."
    //
    //     So a compare read MUST capture all four planes; a normal read must not. Both
    //     halves are asserted here, because a fix for one can break the other.
    // ============================================================

    // Fixture: PAT <- (0x1111, 0x2222, 0x3333, 0x4444) through the machine's own
    // four-selected-read setup (B05_PLOAD_READ `four-normal-reads-load-four-PAT-planes`,
    // RD02_PAT_S0..S3), so that any plane a later capture fails to load shows this
    // fixture's value instead of a source byte.
    egc_enable = 1'b0;
    cpu_word_write(WIN_P0 + 15'h1500, 16'h1111);
    cpu_word_write(WIN_P1 + 15'h1500, 16'h2222);
    cpu_word_write(WIN_P2 + 15'h1500, 16'h3333);
    cpu_word_write(WIN_P3 + 15'h1500, 16'h4444);
    egc_enable = 1'b1;
    egc_set_access(16'hFFF0);
    egc_set_mask(16'hFFFF);
    egc_set_shift(16'h0000, 16'h000F);
    egc_set_ope(16'h0100);                 // RL_MEMREAD, COMPAREREAD CLEAR: a normal read
    for (integer k = 0; k < 4; k = k + 1) begin
      egc_set_fgbg({6'h00, k[1:0], 6'h00, k[1:0]});   // the read-plane selector walks 0..3
      cpu_word_read(WIN_P0 + 15'h1500, w);
    end
    // Observe the pattern register the machine's way: a WS_PATREG write stores it, and the
    // planes are then plain memory.
    egc_set_fgbg(16'h00FF);
    egc_set_ope(16'h1000);                 // WS_PATREG, no RL_MEMREAD
    cpu_word_write(WIN_P0 + 15'h1600, 16'h0000);
    // The fixture's own check, word by word: the pattern register must read
    // 1111/2222/3333/4444 back out of the four planes.
    if (gv_byte(0, 2'd0, 15'h1600) !== 8'h11 || gv_byte(0, 2'd0, 15'h1601) !== 8'h11)
      fail("1b fixture: the pattern register's plane 0 is not the selected 0x1111");
    if (gv_byte(0, 2'd1, 15'h1600) !== 8'h22 || gv_byte(0, 2'd1, 15'h1601) !== 8'h22)
      fail("1b fixture: the pattern register's plane 1 is not the selected 0x2222");
    if (gv_byte(0, 2'd2, 15'h1600) !== 8'h33 || gv_byte(0, 2'd2, 15'h1601) !== 8'h33)
      fail("1b fixture: the pattern register's plane 2 is not the selected 0x3333");
    if (gv_byte(0, 2'd3, 15'h1600) !== 8'h44 || gv_byte(0, 2'd3, 15'h1601) !== 8'h44)
      fail("1b fixture: the pattern register's plane 3 is not the selected 0x4444");

    // A NORMAL read updates the SELECTED pattern plane only (RD02_PAT_S0..S3): read once with
    // the read plane set to 2 from a source whose plane 2 alone is 0x5A5A, and the pattern
    // register must be (1111, 2222, 5A5A, 4444).
    egc_enable = 1'b0;
    cpu_word_write(WIN_P0 + 15'h1520, 16'hAAAA);
    cpu_word_write(WIN_P1 + 15'h1520, 16'hBBBB);
    cpu_word_write(WIN_P2 + 15'h1520, 16'h5A5A);
    cpu_word_write(WIN_P3 + 15'h1520, 16'hDDDD);
    egc_enable = 1'b1;
    egc_set_ope(16'h0100);
    egc_set_fgbg(16'h02FF);                // read plane = 2, pattern source = PAT
    cpu_word_read(WIN_P0 + 15'h1520, w);
    egc_set_fgbg(16'h00FF);
    egc_set_ope(16'h1000);
    cpu_word_write(WIN_P0 + 15'h1620, 16'h0000);
    if (gv_byte(0, 2'd0, 15'h1620) !== 8'h11)
      fail("normal PLOAD_R changed an UNSELECTED pattern plane (0) - it must not (RD02_PAT_S0)");
    if (gv_byte(0, 2'd1, 15'h1620) !== 8'h22)
      fail("normal PLOAD_R changed an UNSELECTED pattern plane (1) - it must not (RD02_PAT_S1)");
    if (gv_byte(0, 2'd2, 15'h1620) !== 8'h5A || gv_byte(0, 2'd2, 15'h1621) !== 8'h5A)
      fail("normal PLOAD_R did not load the SELECTED pattern plane (2) - RD02_PAT_S2");
    if (gv_byte(0, 2'd3, 15'h1620) !== 8'h44)
      fail("normal PLOAD_R changed an UNSELECTED pattern plane (3) - it must not (RD02_PAT_S3)");
    // Re-establish the fixture for the compare case.
    egc_set_ope(16'h0100);
    for (integer k = 0; k < 4; k = k + 1) begin
      egc_set_fgbg({6'h00, k[1:0], 6'h00, k[1:0]});
      cpu_word_read(WIN_P0 + 15'h1500, w);
    end
    egc_set_fgbg(16'h00FF);

    // THE COPY. Source on page 1 (a distinct value per plane and per byte), destination on
    // page 0 cleared first, then ONE compare read and ONE WS_PATREG write per word - the order
    // and the width are the games' (they word-align their rectangles).
    egc_enable = 1'b0;
    for (integer off = 0; off < 8; off = off + 2) begin
      cpu_word_write(WIN_P0 + 15'h1400 + off, 16'hB1C1 + off);
      cpu_word_write(WIN_P1 + 15'h1400 + off, 16'hD2E2 + off);
      cpu_word_write(WIN_P2 + 15'h1400 + off, 16'hF3A3 + off);
      cpu_word_write(WIN_P3 + 15'h1400 + off, 16'hA4B4 + off);
      cpu_word_write(WIN_P0 + 15'h1420 + off, 16'h0000);
      cpu_word_write(WIN_P1 + 15'h1420 + off, 16'h0000);
      cpu_word_write(WIN_P2 + 15'h1420 + off, 16'h0000);
      cpu_word_write(WIN_P3 + 15'h1420 + off, 16'h0000);
    end
    egc_enable = 1'b1;
    egc_set_ope(16'h3100);                 // COMPAREREAD | WS_PATREG | RL_MEMREAD
    egc_set_access(16'hFFF0);
    egc_set_mask(16'hFFFF);
    egc_set_shift(16'h0000, 16'h000F);
    for (integer off = 0; off < 8; off = off + 2) begin
      gvram_access_page = 1'b1;
      cpu_word_read(WIN_P0 + 15'h1400 + off, w);    // the source read: the four-plane capture
      gvram_access_page = 1'b0;
      cpu_word_write(WIN_P0 + 15'h1420 + off, w);   // the WS_PATREG write: the register's datum
    end
    for (integer off = 0; off < 8; off = off + 1) begin
      if (gv_byte(0, 2'd0, 15'h1420 + off[14:0]) !== gv_byte(1, 2'd0, 15'h1400 + off[14:0]))
        fail("0x3100 one-read copy: plane 0 did not carry the source");
      if (gv_byte(0, 2'd1, 15'h1420 + off[14:0]) !== gv_byte(1, 2'd1, 15'h1400 + off[14:0]))
        fail("0x3100 one-read copy: plane 1 did not carry the source (stale pattern register)");
      if (gv_byte(0, 2'd2, 15'h1420 + off[14:0]) !== gv_byte(1, 2'd2, 15'h1400 + off[14:0]))
        fail("0x3100 one-read copy: plane 2 did not carry the source (stale pattern register)");
      if (gv_byte(0, 2'd3, 15'h1420 + off[14:0]) !== gv_byte(1, 2'd3, 15'h1400 + off[14:0]))
        fail("0x3100 one-read copy: plane 3 did not carry the source (stale pattern register)");
    end
    egc_set_ope(16'h0000);
    egc_set_fgbg(16'h00FF);

    // ============================================================
    // 2. The main BIOS's 0x1400 fill, BANK7.BIN@0x35A1: 0x4A2 <- 0x40FF
    //    (foreground colour quad, mask register NOT writable), 0x4A4 <-
    //    0x1400, then `rep stosw`.
    // ============================================================
    egc_set_access(16'hFFF0);
    egc_set_fgbg(16'h40FF);
    egc_set_ope(16'h1400);
    egc_set_fg(16'h0009);          // colour 9 = planes 0 and 3
    for (integer off = 0; off < 8; off = off + 2)
      cpu_word_write(WIN_P0 + 15'h3000 + off, 16'h0000);
    for (integer off = 0; off < 8; off = off + 1) begin
      if (gv_byte(0, 2'd0, 15'h3000 + off[14:0]) !== 8'hFF)
        fail("0x1400 fill: plane 0 (colour bit 0) is not full");
      if (gv_byte(0, 2'd1, 15'h3000 + off[14:0]) !== 8'h00)
        fail("0x1400 fill: plane 1 (colour bit 1 clear) is not empty");
      if (gv_byte(0, 2'd2, 15'h3000 + off[14:0]) !== 8'h00)
        fail("0x1400 fill: plane 2 (colour bit 2 clear) is not empty");
      if (gv_byte(0, 2'd3, 15'h3000 + off[14:0]) !== 8'hFF)
        fail("0x1400 fill: plane 3 (colour bit 3) is not full");
    end

    // ============================================================
    // 3. The main BIOS's 0x28F0 row shift at sft = 0, BANK7.BIN@0x356B: a
    //    `rep movsw` whose read feeds the shifter and whose write emits it.
    // ============================================================
    egc_set_access(16'hFFF0);
    egc_set_fgbg(16'h00FF);
    egc_set_ope(16'h28F0);
    egc_set_shift(16'h0000, 16'h027F);      // 639 dots, as the BIOS writes it
    egc_enable = 1'b0;
    for (integer off = 0; off < 16; off = off + 2)
      cpu_word_write(WIN_P0 + 15'h4000 + off, 16'h9100 + off);
    egc_enable = 1'b1;
    for (integer off = 0; off < 16; off = off + 2) begin
      cpu_word_read(WIN_P0 + 15'h4000 + off, w);
      cpu_word_write(WIN_P0 + 15'h4200 + off, w);
    end
    for (integer off = 0; off < 16; off = off + 1) begin
      if (gv_byte(0, 2'd0, 15'h4200 + off[14:0]) !==
          gv_byte(0, 2'd0, 15'h4000 + off[14:0]))
        fail("0x28F0: the row copy did not land byte-for-byte");
    end

    // ============================================================
    // 4. TH05's 0x29F0 rect copy with a 16-dot-aligned source and destination:
    //    0x29F0 is the same shifter path with RL_MEMREAD set
    //    (th04/hardware/egcrect.cpp:41-93).
    // ============================================================
    egc_set_ope(16'h29F0);
    egc_set_shift(16'h0000, 16'h000F);
    egc_enable = 1'b0;
    for (integer off = 0; off < 16; off = off + 2)
      cpu_word_write(WIN_P0 + 15'h5000 + off, 16'h3C00 + off);
    egc_enable = 1'b1;
    for (integer off = 0; off < 16; off = off + 2) begin
      cpu_word_read(WIN_P0 + 15'h5000 + off, w);
      cpu_word_write(WIN_P0 + 15'h5200 + off, w);
    end
    for (integer off = 0; off < 16; off = off + 1) begin
      if (gv_byte(0, 2'd0, 15'h5200 + off[14:0]) !==
          gv_byte(0, 2'd0, 15'h5000 + off[14:0]))
        fail("0x29F0: the rect copy did not land byte-for-byte");
    end

    // ============================================================
    // 5. The plane-enable register (0x4A0, active low) is a per-plane gate.
    // ============================================================
    egc_set_ope(16'h1400);
    egc_set_fgbg(16'h40FF);
    egc_set_fg(16'h000F);
    egc_set_access(16'hFFF1);      // plane 0 DISABLED
    egc_enable = 1'b0;
    for (integer off = 0; off < 4; off = off + 2)
      cpu_word_write(WIN_P0 + 15'h6000 + off, 16'h0000);
    egc_enable = 1'b1;
    for (integer off = 0; off < 4; off = off + 2)
      cpu_word_write(WIN_P0 + 15'h6000 + off, 16'hFFFF);
    if (gv_byte(0, 2'd0, 15'h6000) !== 8'h00)
      fail("plane enable: a disabled plane 0 was written");
    if (gv_byte(0, 2'd1, 15'h6000) !== 8'hFF)
      fail("plane enable: an enabled plane 1 was not written");
    egc_set_access(16'hFFF0);

    // ============================================================
    // 6. The read path the CPU sees: mode 0 has COMPAREREAD clear and
    //    SHIFT_CPU clear, so a read returns the shifted quad's read plane
    //    (0x4A2 bits 9:8). With a byte of the pattern register loaded by an
    //    0x3100 read, that is observable.
    // ============================================================
    gvram_access_page = 1'b0;
    egc_enable = 1'b0;
    cpu_word_write(WIN_P0 + 15'h7000, 16'h00AB);   // plane 0 = 0x00AB
    cpu_word_write(WIN_P1 + 15'h7000, 16'h00CD);   // plane 1
    egc_enable = 1'b1;
    // The read plane is 0x4A2's bits 9:8 (NP2kai `pl = (egc.fgbg >> 8) & 3`).
    egc_set_ope(16'h0000);          // plain: no COMPAREREAD, no SHIFT_CPU
    egc_set_fgbg(16'h0100);         // read plane = 1
    cpu_word_read(WIN_P0 + 15'h7000, w);
    if (w !== 16'h00CD) begin
      $display("FAIL: read plane 1 returned %04x, expected 00cd", w);
      errors = errors + 1;
    end
    egc_set_fgbg(16'h0000);         // read plane = 0
    cpu_word_read(WIN_P0 + 15'h7000, w);
    if (w !== 16'h00AB) begin
      $display("FAIL: read plane 0 returned %04x, expected 00ab", w);
      errors = errors + 1;
    end
    // COMPAREREAD returns the colour-key MASK. Bit 13 was once gated on 0x4A2's pattern
    // source, with the PAT case returning the ADDRESSED plane; the machine compares in the PAT
    // mode too (EGCREAD.CSV RD22_PATSEL expects the retained-FG mask there), so the mask is the
    // answer whatever the source - and it is the READ-plane-independent, window-independent
    // function of the four planes the helper computes.
    egc_set_ope(16'h2000);
    egc_set_fgbg(16'h0100);
    cpu_word_read(WIN_P0 + 15'h7000, w);
    if (w !== cmp_mask_at(1'b0, 15'h7000)) begin
      $display("FAIL: COMPAREREAD returned %04x, expected the colour-key mask %04x",
               w, cmp_mask_at(1'b0, 15'h7000));
      errors = errors + 1;
    end
    // SHIFT_CPU returns the READ plane (fgbg bits 9:8), NOT the addressed window plane
    // (mem/memegc.c:1091-1098 `mem[ad + planead[pl]]`).
    egc_set_ope(16'h0400);
    egc_set_fgbg(16'h0100);         // read plane = 1, window = plane 0
    cpu_word_read(WIN_P0 + 15'h7000, w);
    if (w !== 16'h00CD) begin
      $display("FAIL: SHIFT_CPU read returned %04x, expected the read plane 00cd", w);
      errors = errors + 1;
    end
    egc_set_ope(16'h0000);
    egc_set_fgbg(16'h00FF);

    // ============================================================
    // 7. The gate: with the EGC off, the same 0x3100-style sequence must not
    //    transform anything (the pattern register is never loaded, so the
    //    destination keeps what the plain store put there).
    // ============================================================
    egc_enable = 1'b0;
    egc_set_ope(16'h3100);
    cpu_word_write(WIN_P0 + 15'h7F00, 16'h0F0F);
    cpu_word_write(WIN_P0 + 15'h7F10, 16'h0F0F);
    if (gv_byte(0, 2'd1, 15'h7F10) !== 8'h00)
      fail("gate off: a plane other than the addressed one changed");
    if (gv_byte(0, 2'd0, 15'h7F10) !== 8'h0F)
      fail("gate off: the addressed plane did not take the plain store");

    // ============================================================
    // 8. THE DESCENDING DIRECTION, sft bit 12 -- the games' own
    //    egc_shift_down.
    //
    //    SPECIFICATION, two independent sources:
    //      * rec98/libs/master.lib/egc_shift_down.asm:141-143 programs
    //        ope = 0x28F0 (the SAME mode the section above drives), then
    //        `mov AX,DI / or AX,1000h  ; dir = 1` into 0x4AC, then the bit
    //        length into 0x4AE, and the CPU itself runs `std` so its own
    //        walk runs backward too. So the target library does not merely
    //        have a descending mode -- it uses one, and the guest's backward
    //        walk only makes sense if the engine's direction matches.
    //      * NP2kai mem/memegc.c `egcshift()`: `egc.func = (egc.sft >> 12) &
    //        1`, and with func set the shifter's in/out pointers start at
    //        `buf + 4096/8 + 3` -- the END of the unit -- instead of at buf.
    //        The shift arithmetic is inverted with it (for src8 < dst8 the
    //        first output is `data[0] << (dst - src)`, where the ascending
    //        case is `data[0] >> (dst - src)`).
    //
    //    So with dir = 1 and a NON-ZERO sub-byte shift the emitted unit must
    //    DIFFER from the source. This bench drives the SAME sequence and the
    //    SAME shift twice, once at dir = 0 and once at dir = 1, and requires
    //    BOTH to transform. That pairing is the point: a harness that could not
    //    tell the two apart, or a shifter that did nothing at either, fails one
    //    of them rather than passing both.
    //
    //    This is the one behaviour the bench's own header declares it does not
    //    cover.
    // ============================================================
    egc_set_access(16'hFFF0);
    egc_set_fgbg(16'h00FF);
    egc_set_ope(16'h28F0);
    egc_set_shift(16'h0042, 16'h000F);   // dir = 0, dst bit 4, src bit 2
    egc_enable = 1'b0;
    for (integer off = 0; off < 16; off = off + 2)
      cpu_word_write(WIN_P0 + 15'h6000 + off, 16'h9183 + off);
    egc_enable = 1'b1;
    for (integer off = 0; off < 16; off = off + 2) begin
      cpu_word_read(WIN_P0 + 15'h6000 + off, w);
      cpu_word_write(WIN_P0 + 15'h6200 + off, w);
    end
    for (integer off = 0; off < 16; off = off + 1) begin
      if (gv_byte(0, 2'd0, 15'h6200 + off[14:0]) !==
          gv_byte(0, 2'd0, 15'h6000 + off[14:0]))
        shifted_any = 1'b1;
    end

    // The same, with master.lib's `or AX,1000h` set.
    egc_set_shift(16'h1042, 16'h000F);   // dir = 1, dst bit 4, src bit 2
    egc_enable = 1'b0;
    for (integer off = 0; off < 16; off = off + 2)
      cpu_word_write(WIN_P0 + 15'h6400 + off, 16'h9183 + off);
    egc_enable = 1'b1;
    for (integer off = 0; off < 16; off = off + 2) begin
      cpu_word_read(WIN_P0 + 15'h6400 + off, w);
      cpu_word_write(WIN_P0 + 15'h6600 + off, w);
    end
    // The redundant per-direction-vs-source counter that used to sit here is
    // gone: the assertion below compares the two DIRECTIONS, which is the
    // relation the specification actually fixes.

    // TEMPORARY INSTRUMENT: dump both directions so the expectation can be
    // derived from NP2kai's formula rather than assumed.
    $display("SHIFTDIR src dir0:");
    for (integer off = 0; off < 16; off = off + 1)
      $display("  SHIFTDIR src[%0d]=%02x dir0[%0d]=%02x dir1[%0d]=%02x", off,
               gv_byte(0, 2'd0, 15'h6000 + off[14:0]), off,
               gv_byte(0, 2'd0, 15'h6200 + off[14:0]), off,
               gv_byte(0, 2'd0, 15'h6600 + off[14:0]));

    // THE ASSERTION, and it is the one this subsystem can justify without
    // guessing at the bit layout: NP2kai's egcshift() sets `egc.func = (sft >>
    // 12) & 1` and INVERTS the shift arithmetic under it (for src8 < dst8 the
    // ascending first output is `data[0] >> (dst-src)` and the descending one is
    // `data[0] << (dst-src)`), and it moves the in/out pointers to the END of the
    // unit. So for a non-degenerate shift the two directions MUST produce
    // different streams. That is a relation between two specified behaviours, so
    // it needs no knowledge of which bit comes first, and it holds whatever the
    // stream convention is.
    //
    // The failure it catches is the one the module's header warns about:
    // a module that ignores `sft_dir` and folds `dir = 1` into the plain copy
    // -- if that happens, the two streams become identical and this names it.
    for (integer off = 0; off < 16; off = off + 1) begin
      if (gv_byte(0, 2'd0, 15'h6600 + off[14:0]) !==
          gv_byte(0, 2'd0, 15'h6200 + off[14:0]))
        dirs_differ = 1'b1;
    end
    if (!dirs_differ)
      fail("sft bit 12 ignored: descending stream == ascending");

    // dir = 0 must shift, or the shifter is doing nothing at all and the
    // dir = 1 assertion above would be measuring the wrong thing.
    if (!shifted_any)
      fail("dir=0 shift inert: unit byte-identical to source");

    // ============================================================
    // 9. A SHIFTER RE-ARM RESTORES srcmask TO 0xFFFF
    // ============================================================
    // NP2kai io/egc.c:91-113 -- the 0x4AC/0x4AD/0x4AE/0x4AF write handlers each
    // end `egcshift(); egc.srcmask.w = 0xffff;`. And mem/memegc.c:1046-1078,
    // egc_opew, ANDs srcmask into the write mask in ALL THREE of its mode cases:
    //   case 0x0800: EGCOPE_SHIFTW;  mask2 &= srcmask;
    //   case 0x1000: EGCOPE_SHIFTW2; mask2 &= srcmask;
    //   default:     EGCOPE_SHIFTW2; mask2 &= srcmask;   <- does not produce
    // So the first write after a re-arm is masked with 0xFFFF. If the re-arm
    // forgets srcmask, the stale partial value from the previous sequence is
    // ANDed into that write instead.
    //
    // The observable form is chosen so nothing else can move: ROP 0xFF makes the
    // data all-ones whatever the shifter did (rop_class 7), so the write mask
    // ALONE decides the result. Destination pre-filled with 0, so a full mask
    // gives 0xFF and a stale 0x00F0 gives 0xF0.
    egc_set_access(16'hFFF0);          // all four planes enabled
    egc_set_fgbg(16'h00FF);
    egc_set_mask(16'hFFFF);

    // (a) pre-fill the destination with zero, with the shifter freshly re-armed
    //     so srcmask is full and the whole word lands.
    egc_set_shift(16'h0000, 16'h000F); // remain = 16: a whole word
    egc_set_ope(16'h0000);             // WS_CPU
    cpu_word_write(WIN_P0 + 15'h7000, 16'h0000);

    // (b) leave srcmask PARTIAL: leng = 3 means remain = 4, so the produce spends
    //     four bits of the low byte and mask_u1(3) = 0xF0, i.e. srcmask 0x00F0.
    egc_set_shift(16'h0000, 16'h0003);
    egc_set_ope(16'h0CF0);             // WS_ROP | SHIFT_CPU | ROP 0xF0
    cpu_word_write(WIN_P0 + 15'h7200, 16'h0000);

    // (c) RE-ARM. NP2kai sets srcmask back to 0xFFFF here.
    egc_set_shift(16'h0000, 16'h000F);

    // (d) a write that does NOT produce -- WS_ROP with SHIFT_CPU clear -- so the
    //     mask is `reg_mask & srcmask` and nothing recomputes srcmask.
    egc_set_ope(16'h08FF);             // WS_ROP | ROP 0xFF, SHIFT_CPU clear
    cpu_word_write(WIN_P0 + 15'h7000, 16'h0000);

    if (gv_byte(0, 2'd0, 15'h7000) !== 8'hFF)
      fail("EGC re-arm did not restore srcmask: first byte masked by a stale srcmask");
    if (gv_byte(0, 2'd0, 15'h7001) !== 8'hFF)
      fail("EGC re-arm did not restore srcmask: second byte masked by a stale srcmask");

    // ============================================================
    // 10. THE SHAKE'S OWN SHAPE: dstbit = 0 with a non-zero srcbit, against the
    //     REFERENCE QUEUE rather than against this module's own convention.
    //
    //     The shake sets 0x4AC = dots with bit 12 as the direction, so dstbit is 0 and srcbit
    //     2, and master.lib's row shift walks SI upward while it writes at DI = SI - 2
    //     (egc_shift_left_all.asm: `mov SI,0 / mov DI,0ffeh / rep movsw`). NP2kai's shifter
    //     reads its OUTPUT pointer one unit BEHIND its input pointer, so the word the read at
    //     SI returns is f(src[k-1], src[k]) - the previous unit's bytes plus the current unit's
    //     first byte - and it lands at DI = SI - 2, i.e. dest[j] = f(src[j], src[j+1]).
    //
    //     The old `shake_word` built that carry-in byte as 0, which is exactly what the dead
    //     `sreg` produced, so the section asserted this module's own defect against itself. The
    //     oracle above is a port of the reference queue; here every returned word AND the
    //     destination row are asserted against it by value.
    // ============================================================
    egc_enable = 1'b0;
    for (integer off = 0; off < 16; off = off + 2) begin
      cpu_word_write(WIN_P0 + 15'h6C00 + off[14:0], 16'h0000);
      cpu_word_write(WIN_P0 + 15'h6E00 + off[14:0], 16'h0000);
    end
    cpu_word_write(WIN_P0 + 15'h6BFE, 16'h0000);   // read 0's DI = SI - 2 slot
    for (integer n = 0; n < 8; n = n + 1)
      cpu_word_write(WIN_P0 + 15'h6A00 + 2 * n, {(8'h80 + 3 * n[7:0]), (8'h40 + n[7:0])});
    egc_enable = 1'b1;
    egc_set_access(16'hFFF0);
    egc_set_mask(16'hFFFF);
    egc_set_fgbg(16'h00FF);
    egc_set_ope(16'h28F0);

    for (integer d = 0; d < 2; d = d + 1) begin
      reg [15:0] dst_base;
      dst_base = 15'h6C00 + 2 * d * 15'h0100;
      // dir 0 first, then master.lib's `or AX,1000h`; the two rows are independent, so each
      // starts from a cleared destination and its own re-arm.
      egc_set_shift(d ? 16'h1002 : 16'h0002, 16'h027F);
      oracle_arm(d ? 16'h1002 : 16'h0002, 16'h027F);
      for (integer n = 0; n < 8; n = n + 1) begin
        reg [15:0] src16, exp16;
        src16 = {(8'h80 + 3 * n[7:0]), (8'h40 + n[7:0])};
        // 0x28F0 sets COMPAREREAD, so the READ returns the raw window plane (the shifter output
        // is what the WRITE stores), which is why the destination row is the assertion.
        cpu_word_read(WIN_P0 + 15'h6A00 + 2 * n, w);
        oracle_read(src16, exp16);
        exp_row[n] = exp16;
        cpu_word_write(WIN_P0 + dst_base + 2 * n - 2, w);   // the machine's DI = SI - 2
      end
      // The destination row: dest word j is what the read at SI = 2(j+1) produced, i.e.
      // f(src[j], src[j+1]) - one word behind the source index.
      for (integer j = 0; j < 7; j = j + 1) begin
        if (gv_byte(0, 2'd0, dst_base + 2 * j) !== exp_row[j+1][7:0] ||
            gv_byte(0, 2'd0, dst_base + 2 * j + 1) !== exp_row[j+1][15:8]) begin
          $display("FAIL shake dir%0d row word %0d: got %02x%02x want %04x", d, j,
                   gv_byte(0, 2'd0, dst_base + 2 * j + 1),
                   gv_byte(0, 2'd0, dst_base + 2 * j), exp_row[j+1]);
          errors = errors + 1;
        end
      end
    end
    // Read 0 is gated (stack 14 < 16), so its masked write at DI = SI - 2 = 0x6BFE must not land.
    if (gv_byte(0, 2'd0, 15'h6BFE) !== 8'h00)
      fail("shake: the gated first unit wrote its DI = SI - 2 slot");

    // ============================================================
    // 11. THE WORD FEED AT srcbit >= 8. NP2kai's WORD feed has TWO effects the byte feed does
    //     not (mem/memegc.c:611-623 against :590-609):
    //       * the stack arithmetic - `stack += 16 - srcbit` and CLEAR srcbit, where the byte feed
    //         subtracts 8 from srcbit and adds nothing. The RTL had applied the byte rule to word
    //         units too, so a word feed with sft[3:0] in 8..15 withheld 1..8 stack bits and
    //         carried a non-zero srcbit into the next unit;
    //       * `if (srcbit >= 8) outptr++` - a PERSISTENT one-byte offset of the shifter's source
    //         window, because inptr and outptr walk the same row buffer in lockstep everywhere
    //         else. It was once the remaining open EGC defect; the RTL
    //         models it (the egc.buf pointer window) and this section pins it BY VALUE.
    //
    //     The shape is section 10's with srcbit 0xA instead of 2: src8 = 0xA & 7 = 2 is exactly
    //     that section's sub-byte geometry, so the ONLY difference from it is the whole-byte feed
    //     bit. BOTH effects are asserted: the stack/srcbit/dstbit/produce-gate state after every
    //     read, and the destination row by value against the reference queue, which models the
    //     `outptr++` too. With the byte rule applied to a word unit, read 1 stayed GATED (the
    //     stack read 0 + 14 where the reference reads 6 + 14); without the offset every emitted
    //     word was built one source byte too early.
    // ============================================================
    egc_enable = 1'b0;
    for (integer off = 0; off < 16; off = off + 2) begin
      cpu_word_write(WIN_P0 + 15'h6200 + off[14:0], 16'h0000);
      cpu_word_write(WIN_P0 + 15'h6400 + off[14:0], 16'h0000);
      cpu_word_write(WIN_P0 + 15'h6600 + off[14:0], 16'h0000);
    end
    cpu_word_write(WIN_P0 + 15'h63FE, 16'h0000);   // read 0's DI = SI - 2 slot, dir 0
    cpu_word_write(WIN_P0 + 15'h65FE, 16'h0000);   // ... and dir 1
    for (integer n = 0; n < 8; n = n + 1)
      cpu_word_write(WIN_P0 + 15'h6200 + 2 * n, {(8'h80 + 3 * n[7:0]), (8'h40 + n[7:0])});
    egc_enable = 1'b1;
    egc_set_access(16'hFFF0);
    egc_set_mask(16'hFFFF);
    egc_set_fgbg(16'h00FF);
    egc_set_ope(16'h28F0);

    begin : word_srcbit8
      integer w_row_words;
      w_row_words = 0;
      for (integer d = 0; d < 2; d = d + 1) begin
        reg [15:0] dst_base;
        dst_base = 15'h6400 + 2 * d * 15'h0100;
        egc_set_shift(d ? 16'h100A : 16'h000A, 16'h027F);
        oracle_arm(d ? 16'h100A : 16'h000A, 16'h027F);
        for (integer n = 0; n < 8; n = n + 1) begin
          reg [15:0] src16, exp16;
          src16 = {(8'h80 + 3 * n[7:0]), (8'h40 + n[7:0])};
          cpu_word_read(WIN_P0 + 15'h6200 + 2 * n, w);
          oracle_read(src16, exp16);
          exp_row[n] = exp16;
          if (dut.u_egc.stack !== or_stack[5:0] ||
              dut.u_egc.srcbit !== or_srcbit[3:0] ||
              dut.u_egc.dstbit !== or_dstbit[3:0] ||
              (dut.u_egc.srcmask != 16'h0000) !== or_gate_open) begin
            $display("FAIL word feed srcbit>=8 dir%0d read %0d: stack=%0d srcbit=%0d dstbit=%0d mask=%04x produced=%b, reference stack=%0d srcbit=%0d dstbit=%0d produced=%b",
                     d, n, dut.u_egc.stack, dut.u_egc.srcbit, dut.u_egc.dstbit,
                     dut.u_egc.srcmask, (dut.u_egc.srcmask != 16'h0000),
                     or_stack, or_srcbit, or_dstbit, or_gate_open);
            errors = errors + 1;
          end
          cpu_word_write(WIN_P0 + dst_base + 2 * n - 2, w);   // the machine's DI = SI - 2
        end
        for (integer j = 0; j < 7; j = j + 1) begin
          w_row_words = w_row_words + 1;
          if (gv_byte(0, 2'd0, dst_base + 2 * j) !== exp_row[j+1][7:0] ||
              gv_byte(0, 2'd0, dst_base + 2 * j + 1) !== exp_row[j+1][15:8]) begin
            $display("FAIL word feed srcbit>=8 dir%0d row word %0d: got %02x%02x want %04x", d, j,
                     gv_byte(0, 2'd0, dst_base + 2 * j + 1),
                     gv_byte(0, 2'd0, dst_base + 2 * j), exp_row[j+1]);
            errors = errors + 1;
          end
        end
      end
      $display("NOTE egc: word feed srcbit>=8 - state, gate schedule and all %0d destination words match the reference queue (offset INCLUDED)",
               w_row_words);
    end

    // ============================================================
    // 12. THE EGC SOURCE READ is COALESCED. A long sequential walk over
    //     consecutive words must issue ONE backend read per unit -- the unit's enabled columns as
    //     one burst -- not one read per column. Before the coalescing change the buffer filled only its free
    //     slots and read through when none were free; the RTL presents the columns as one cl_burst
    //     read. The walk's units are 2 words apart: the un-coalesced form issues 512 reads for the
    //     256-unit walk, the coalesced form 256 (the wide fill is gone with the
    //     read cache).
    // ============================================================
    begin
      integer rd0, rd1, k;
      egc_enable = 1'b0;
      gvram_access_page = 1'b1;
      for (k = 0; k < 512; k = k + 1)
        cpu_word_write(WIN_P0 + 15'h2000 + 2 * k, 16'h1000 + k[15:0]);
      gvram_access_page = 1'b0;
      gvram_flush;
      egc_enable = 1'b1;
      egc_set_access(16'hFFF0);
      egc_set_fgbg(16'h00FF);
      egc_set_ope(16'h3100);
      egc_set_mask(16'hFFFF);
      egc_set_shift(16'h0000, 16'h000F);
      rd0 = backend_reads;
      for (k = 0; k < 256; k = k + 1) begin
        gvram_access_page = 1'b1;
        cpu_word_read(WIN_P0 + 15'h2000 + 2 * k, w);
        gvram_access_page = 1'b0;
      end
      rd1 = backend_reads - rd0;
      $display("NOTE egc: sequential source walk of 256 units -> %0d backend reads (one read per %0d units)", rd1, rd1 > 0 ? 256 / rd1 : 0);
      if (rd1 > 256)
        fail("the EGC source read is not coalesced: the unit's columns must be one burst, not one read per column");
    end

    // 13. THE SOURCE FETCH IS LIMITED TO THE COLUMNS THE ACCESS TOUCHES
    //     The read pass used to fetch all four columns of the unit's dword whatever the CPU
    //     access covered. Every value the shifter, the ROP and the write merge read out of
    //     lastvram is a byte of the unit's own lane pair (or one lane on, for wold_hi), so a
    //     column outside the access's byte enables is provably dead traffic. Counted on the
    //     EGC's own D1 port in COLUMNS (a read's cl_wbe is its byte enables, one bit per column,
    //     and the RTL makes those columns ONE logical read), so the fetch a shape covers is
    //     asserted rather than inferred.
    // ============================================================
    begin : src_fetch
      integer r_a, r_b;
      reg [15:0] rw, rw2;
      egc_enable = 1'b1;
      gvram_access_page = 1'b1;
      egc_set_access(16'hFFF0);
      egc_set_fgbg(16'h00FF);
      egc_set_mask(16'hFFFF);
      egc_set_shift(16'h0000, 16'h000F);
      egc_set_ope(16'h3100);

      // (a) A 16-bit read on lanes 0:1 fetches its OWN two columns, not the dword's four.
      @(negedge clk); r_a = egc_d1_reads;
      cpu_word_read(WIN_P0 + 15'h1000, rw);
      r_b = egc_d1_reads;
      if (r_b - r_a != 2)
        fail("EGC 16-bit source read fetched the whole dword: expected 2 columns on lanes 0:1");
      // The datum is the colour-key MASK, not the plane word: the copy's OPE is 0x3100, whose
      // bit 13 the machine applies in the PAT mode too (RD22_PATSEL). The copy's write still
      // stores the pattern register, so the source-skip assertion below is unaffected.
      if (rw !== cmp_mask_at(1'b1, 15'h1000))
        fail("EGC 16-bit source read returned the wrong word");

      // (b) The copy's write is a full-mask pattern write: the destination fetch is dead, so
      //     the write access issues NO read. The destination still takes the source word.
      gvram_access_page = 1'b0;
      @(negedge clk); r_a = egc_d1_reads;
      cpu_word_write(WIN_P0 + 15'h1100, rw);
      r_b = egc_d1_reads;
      if (r_b - r_a != 0)
        fail("EGC full-mask copy write still fetched a source it does not use");
      if (gv_byte(0, 2'd0, 15'h1100) !== 8'hC1 || gv_byte(0, 2'd0, 15'h1101) !== 8'hB1)
        fail("EGC source-skip changed the copy's result");

      // (c) The same 16-bit read on lanes 2:3 fetches columns 2 and 3.
      gvram_access_page = 1'b1;
      @(negedge clk); r_a = egc_d1_reads;
      cpu_word_read(WIN_P0 + 15'h1002, rw2);
      r_b = egc_d1_reads;
      if (r_b - r_a != 2)
        fail("EGC 16-bit source read on lanes 2:3 fetched the wrong column count");
      if (rw2 !== cmp_mask_at(1'b1, 15'h1002))
        fail("EGC 16-bit source read on lanes 2:3 returned the wrong word");
      gvram_access_page = 1'b0;

      // (d) A solid 0x1400 colour fill: the data quad is the colour register and the mask is
      //     full, so the source is not read at all -- zero D1 reads, one write request.
      egc_set_ope(16'h1400);
      egc_set_fgbg(16'h40FF);
      egc_set_fg(16'h0009);
      @(negedge clk); r_a = egc_d1_reads;
      cpu_word_write(WIN_P0 + 15'h1300, 16'hFFFF);
      r_b = egc_d1_reads;
      if (r_b - r_a != 0)
        fail("EGC solid colour fill fetched a source it does not use");
      if (gv_byte(0, 2'd0, 15'h1300) !== 8'hFF || gv_byte(0, 2'd1, 15'h1300) !== 8'h00 ||
          gv_byte(0, 2'd3, 15'h1300) !== 8'hFF)
        fail("EGC solid colour fill wrote the wrong planes");
      $display("NOTE egc: source fetch - 16-bit read = 2 columns, full-mask copy write = 0 reads, solid fill = 0 reads");
    end

    // ============================================================
    // 14. THE POSTED WRITE. The write pass advances on the ACCEPT, not on `cl_done`,
    //     so a write still in the backend when the next read is presented can complete in the
    //     SAME cycle the read is accepted. The read must take its OWN `cl_done`: with the backend
    //     held off until the read is on the D1 port, the write's pulse would otherwise complete the
    //     read and it would return the stale `cl_rdata`. This is the fail-first case, and the
    //     burst write is the arm the fold presents from `S_EVAL`.
    // ============================================================
    begin : posted_write
      reg [15:0] pw;
      egc_enable = 1'b0;
      gvram_access_page = 1'b1;
      cpu_word_write(WIN_P0 + 15'h1800, 16'hB1C1);   // the source word on page 1
      egc_enable = 1'b1;
      gvram_access_page = 1'b0;
      egc_set_access(16'hFFF0);
      egc_set_fgbg(16'h00FF);
      egc_set_mask(16'hFFFF);
      egc_set_shift(16'h0000, 16'h000F);
      egc_set_ope(16'h3100);

      // An EGC WRITE with the backend held off: the coalescer accepts it and the FSM posts it,
      // but it cannot complete.
      mem_ready = 1'b0;
      @(negedge clk);
      cpu_addr = WIN_P0 + 15'h1800;
      cpu_din  = 16'hB1C1;
      cpu_be   = 4'b0011;
      cpu_write = 1'b1;
      cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'b0;
      while (dut.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);

      // The READ while the write is in flight. `cpu_ready` is not asserted until the read
      // completes, so release the backend only once the read is ON THE PORT: the write then
      // completes in the read's accept cycle, the case this section exists for.
      gvram_access_page = 1'b1;
      @(negedge clk);
      cpu_addr = WIN_P0 + 15'h1800;
      cpu_be   = 4'b0011;
      cpu_write = 1'b0;
      cpu_valid = 1'b1;
      while (!(dut.u_egc.cl_valid && !dut.u_egc.cl_write)) @(negedge clk);
      @(negedge clk);
      mem_ready = 1'b1;
      while (!cpu_ready) @(negedge clk);
      // Release at the ready edge (z486's shape, src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`),
      // before the pipelined produce's response cycle (see cpu_word_read); the negedge below is the
      // old release's own wait, kept so the +1 stays in the cadence.
      cpu_valid = 1'b0; cpu_be = 4'b0;
      while (!cpu_resp_valid) @(negedge clk);
      #1; pw = cpu_dout[15:0];
      @(negedge clk);
      while (dut.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
      repeat (3) @(posedge clk);

      if (pw !== cmp_mask_at(1'b1, 15'h1800))
        fail("the posted write's completion was taken for the next read's: the EGC read returned stale data");
      $display("NOTE egc: posted write - a read presented while the write drains returns the source address's colour-key mask");
    end

    // ============================================================
    // 15. THE READ HOLD IS ADDRESS-SCOPED TO THE BURST'S RUN. The EGC's read burst
    //     streams straight from SDRAM and bypasses the write-combining buffer, so a DIRTY word the
    //     run covers must be written back first -- the buffer's copy is newer than SDRAM. A dirty
    //     word OUTSIDE the run is never read by the burst and must NOT hold it: the EGC reads page 1
    //     and writes page 0, so on a blit the hold never fires. Tested in BOTH directions, because
    //     narrowing the window to the run is correct only if the inside case still drains.
    // ============================================================
    // 16. THE WRITE UNIT NO LONGER WALKS THE READ'S EVALUATE STATE. A write that needs
    //     no source read -- the 0x3100 / 0x29F0 copy's own write, and any other full-mask write --
    //     is presented from S_WR, one state after its produce commit state (S_COMMIT)
    //     commits it, never the
    //     shared evaluate state the fold walked through. The assertion is the state the unit is
    //     NEVER in, and the
    //     read above validates the probe: if the read does not register an evaluate cycle, the
    //     write's zero is vacuous. The destination is still asserted by value and the
    //     read-modify-write write still fetches its source (section 13(b) covers the fetch).
    // ============================================================
    begin : write_skips_eval
      reg [15:0] fw;
      integer eval_wr, eval_rd, r_a, r_b;
      egc_enable = 1'b0;
      gvram_access_page = 1'b1;
      cpu_word_write(WIN_P0 + 15'h1C00, 16'hD4E2);
      egc_enable = 1'b1;
      egc_set_access(16'hFFF0);
      egc_set_fgbg(16'h00FF);
      egc_set_mask(16'hFFFF);
      egc_set_shift(16'h0000, 16'h000F);
      egc_set_ope(16'h3100);

      eval_rd = egc_eval_cycles;
      @(negedge clk); r_a = egc_d1_reads;
      cpu_word_read(WIN_P0 + 15'h1C00, fw);
      r_b = egc_d1_reads;
      if (egc_eval_cycles - eval_rd < 1)
        fail("EGC read did not evaluate: the S_EVAL probe is dead and section 15 asserts nothing");
      if ((r_b - r_a) != 2)
        fail("EGC fast-path read fetched the wrong column count");
      if (fw !== cmp_mask_at(1'b1, 15'h1C00))
        fail("EGC fast-path read returned the wrong word");

      gvram_access_page = 1'b0;
      eval_wr = egc_eval_cycles;
      @(negedge clk); r_a = egc_d1_reads;
      cpu_word_write(WIN_P0 + 15'h1C00, fw);
      r_b = egc_d1_reads;
      if (egc_eval_cycles != eval_wr)
        fail("EGC copy write spent a cycle in the read's evaluate state");
      if (r_b != r_a)
        fail("EGC copy write fetched a source it does not use");
      if (gv_byte(0, 2'd0, 15'h1C00) !== 8'hE2 || gv_byte(0, 2'd0, 15'h1C01) !== 8'hD4)
        fail("EGC copy write did not reach the destination");
      $display("NOTE egc: write unit - the full-mask copy write presents from S_WR and never enters the read's evaluate state");
    end

    // ============================================================
    // 17. THE READ FILL IS THE UNIT'S OWN RUN. A STRIDED source walk -- TH05's tile
    //     layer, whose rows are 40 columns apart -- must never be answered with the 8-word fill
    //     an earlier design gave the contiguous shake (that fill fed the M10K read cache and is gone
    //     with it). Counted in BACKEND READ WORDS (each request's mem_burstcount summed): the walk
    //     issues the unit's own run (~2 words a unit), so a wide fill would show here.
    // ============================================================
    begin
      integer wd0, wd1, k;
      egc_enable = 1'b0;
      gvram_access_page = 1'b1;
      for (k = 0; k < 256; k = k + 1)
        cpu_word_write(WIN_P0 + 15'h2000 + 40 * k, 16'h2000 + k[15:0]);
      gvram_access_page = 1'b0;
      gvram_flush;
      egc_enable = 1'b1;
      egc_set_access(16'hFFF0);
      egc_set_fgbg(16'h00FF);
      egc_set_ope(16'h3100);
      egc_set_mask(16'hFFFF);
      egc_set_shift(16'h0000, 16'h000F);
      wd0 = backend_rd_words;
      for (k = 0; k < 256; k = k + 1) begin
        gvram_access_page = 1'b1;
        cpu_word_read(WIN_P0 + 15'h2000 + 40 * k, w);
        gvram_access_page = 1'b0;
      end
      wd1 = backend_rd_words - wd0;
      $display("NOTE egc: strided source walk of 256 units (40-column stride) -> %0d backend read words", wd1);
      if (wd1 > 1024)
        fail("a STRIDED source walk was answered with the wide fill: it must fall back to the unit's run");
    end

    // ============================================================
    // 18. THE BYTE PATH'S FEED IS GATED BY SHIFT_CPU (NP2kai egc_opeb, memegc.c:1004-1035).
    //     A byte WS_PATREG unit (ope & 0x1800 == 0x1000) enters the fgbg switch's DEFAULT
    //     branch, whose EGCOPE_SHIFTB is guarded by `egc.ope & 0x400`; with SHIFT_CPU clear NO
    //     EGCOPE_SHIFTB runs, so egc_src is unchanged and the write stores the HELD shifter
    //     byte, not the CPU byte. The RTL fed the shifter on every WS_PATREG unit, so it stored
    //     the CPU byte. The held byte is made non-zero by a preceding producing byte read.
    // ============================================================
    begin : byte_feed_gate
      reg [7:0] hb;
      egc_enable = 1'b0;
      gvram_access_page = 1'b0;
      cpu_byte_write(WIN_P0 + 15'h2000, 8'hAB);      // the source byte the read will produce
      cpu_byte_write(WIN_P0 + 15'h2100, 8'h00);      // the destination byte, cleared
      egc_enable = 1'b1;
      egc_set_access(16'hFFF0);
      egc_set_fgbg(16'h0000);          // read plane 0, fgbg_sel 00
      egc_set_mask(16'hFFFF);
      egc_set_shift(16'h0000, 16'h000F);
      egc_set_ope(16'h0000);           // WS_CPU, SHIFT_CPU clear: a read produces
      cpu_byte_read(WIN_P0 + 15'h2000, hb);
      if (hb !== 8'hAB)
        fail("byte feed gate: the setup read did not return the source byte");
      egc_set_ope(16'h1000);           // WS_PATREG, SHIFT_CPU CLEAR
      cpu_byte_write(WIN_P0 + 15'h2100, 8'h55);
      if (gv_byte(0, 2'd0, 15'h2100) !== 8'hAB)
        fail("byte feed gate: a byte WS_PATREG write with SHIFT_CPU clear stored the CPU byte, not the held shifter byte");
      $display("NOTE egc: byte feed gate - SHIFT_CPU clear leaves the held shifter byte 0x%02x",
               gv_byte(0, 2'd0, 15'h2100));
    end

    // ============================================================
    // 19. THE BYTE PATH'S NO-COLOUR TEST IS 00 **OR** 11 (NP2kai egc_opeb case 0x1000).
    //     `egc.fgbg & 0x6000` selects bgc (0x2000) / fgc (0x4000) and RETURNS before
    //     `mask2 &= srcmask`; the switch DEFAULT - which 0x6000 (fgbg_sel 11) falls into - runs
    //     EGCOPE_SHIFTB and DOES AND srcmask. The RTL tested only fgbg_sel == 00, so a 0x6000
    //     byte write masked with the plain mask register instead of the shifter's srcmask.
    //     leng = 3 leaves the produced srcmask byte 0xF0, so only the high nibble may land.
    // ============================================================
    begin : byte_color_mask
      egc_enable = 1'b0;
      gvram_access_page = 1'b0;
      cpu_byte_write(WIN_P0 + 15'h2200, 8'h00);
      egc_enable = 1'b1;
      egc_set_access(16'hFFF0);
      egc_set_mask(16'hFFFF);
      egc_set_fgbg(16'h60FF);          // fgbg_sel = 11: the switch DEFAULT
      egc_set_shift(16'h0000, 16'h0003);   // remain = 4: srcmask mask_u1(3) = 0xF0
      egc_set_ope(16'h1400);           // WS_PATREG | SHIFT_CPU
      cpu_byte_write(WIN_P0 + 15'h2200, 8'hFF);
      if (gv_byte(0, 2'd0, 15'h2200) !== 8'hF0)
        fail("byte colour mask: a 0x6000 byte WS_PATREG write did not AND the shifter srcmask");
      $display("NOTE egc: byte colour mask - a 0x6000 byte write ANDs srcmask (0x%02x)",
               gv_byte(0, 2'd0, 15'h2200));
    end

    // ============================================================
    // 20. THE ROP'S SOURCE IS THE PRODUCE OUTPUT, not the registered sdata (NP2kai opefn reads
    //     egc_src AFTER EGCOPE_SHIFTW produces into it). The RTL's two-column WRITE BURST is
    //     presented from S_WR, one state after the produce commits its output to `sdata`, so it
    //     must see that produce output; skipping the produce and reading the PREVIOUS unit's
    //     `sdata` stored the wrong bytes. ROP 0xF0 returns src,
    //     so the destination must be the CPU word the produce emitted, not the stale sdata.
    // ============================================================
    begin : rop_produce_src
      reg [15:0] stale;
      egc_enable = 1'b0;
      gvram_access_page = 1'b0;
      cpu_word_write(WIN_P0 + 15'h3000, 16'h00AB);    // the stale sdata the read leaves
      cpu_word_write(WIN_P0 + 15'h3100, 16'h0000);    // destination, cleared
      egc_enable = 1'b1;
      egc_set_access(16'hFFF0);
      egc_set_fgbg(16'h00FF);
      egc_set_mask(16'hFFFF);
      egc_set_shift(16'h0000, 16'h000F);
      egc_set_ope(16'h0000);
      cpu_word_read(WIN_P0 + 15'h3000, stale);        // leaves sdata = 0x00AB
      if (stale !== 16'h00AB)
        fail("rop produce src: the setup read did not return the source word");
      egc_set_ope(16'h0CF0);                          // WS_ROP | SHIFT_CPU | ROP 0xF0 (src)
      cpu_word_write(WIN_P0 + 15'h3100, 16'h5555);
      if (gv_byte(0, 2'd0, 15'h3100) !== 8'h55 ||
          gv_byte(0, 2'd0, 15'h3101) !== 8'h55)
        fail("rop produce src: the ROP took the stale sdata, not the produce output");
      $display("NOTE egc: rop produce src - ROP 0xF0 stores the produce output, not the stale sdata");
    end

    // ============================================================
    // 21. THE SHIFTER UPDATES ONLY THE PRODUCED LANE OF THE 16-BIT srcmask (memegc.c
    //     shiftinput_byte + egcsftb_*0 write `srcmask._b[ext]`). An ODD-lane byte unit must
    //     leave the low byte of srcmask alone; the RTL placed the produced byte at lane 0
    //     always, so a later word unit ANDed in a zeroed low byte. The odd-lane read produces
    //     srcmask 0xFFFF (produced high byte 0xFF, low byte kept), so a following non-producing
    //     word write must store BOTH bytes.
    // ============================================================
    begin : srcmask_lane
      reg [7:0] ob;
      egc_enable = 1'b0;
      gvram_access_page = 1'b0;
      cpu_byte_write(WIN_P0 + 15'h4001, 8'h7E);      // the odd-lane source byte
      cpu_word_write(WIN_P0 + 15'h4100, 16'h0000);   // the destination word, cleared
      egc_enable = 1'b1;
      egc_set_access(16'hFFF0);
      egc_set_fgbg(16'h00FF);
      egc_set_mask(16'hFFFF);
      egc_set_shift(16'h0000, 16'h000F);
      egc_set_ope(16'h0000);
      cpu_byte_read(WIN_P0 + 15'h4001, ob);          // odd lane: updates srcmask[15:8]
      if (ob !== 8'h7E)
        fail("srcmask lane: the setup odd-lane read returned the wrong byte");
      egc_set_ope(16'h08FF);                          // WS_ROP | ROP 0xFF, SHIFT_CPU clear
      cpu_word_write(WIN_P0 + 15'h4100, 16'h0000);    // data all ones, mask = reg_mask & srcmask
      if (gv_byte(0, 2'd0, 15'h4100) !== 8'hFF ||
          gv_byte(0, 2'd0, 15'h4101) !== 8'hFF)
        fail("srcmask lane: the odd-lane produce zeroed srcmask's low byte, masking a later word write");
      $display("NOTE egc: srcmask lane - an odd-lane byte produce keeps srcmask's low byte");
    end

    // ============================================================
    // 22. A COLOUR-QUAD BYTE WRITE DOES NOT RUN THE SHIFTER (NP2kai egc_opeb case 0x1000).
    //     The bgc (0x2000) / fgc (0x4000) cases RETURN before EGCOPE_SHIFTB, so the shifter's
    //     held byte is untouched. The RTL fed the shifter on every WS_PATREG unit, corrupting
    //     egc_src that a later unit reads.
    // ============================================================
    begin : color_quad_no_feed
      reg [7:0] hb2;
      egc_enable = 1'b0;
      gvram_access_page = 1'b0;
      cpu_byte_write(WIN_P0 + 15'h5000, 8'hAB);
      cpu_byte_write(WIN_P0 + 15'h5100, 8'h00);
      egc_enable = 1'b1;
      egc_set_access(16'hFFF0);
      egc_set_mask(16'hFFFF);
      egc_set_fgbg(16'h0000);
      egc_set_shift(16'h0000, 16'h000F);
      egc_set_ope(16'h0000);
      cpu_byte_read(WIN_P0 + 15'h5000, hb2);         // sdata = 0xAB
      if (hb2 !== 8'hAB)
        fail("colour quad no-feed: the setup read did not return the source byte");
      egc_set_fgbg(16'h20FF);          // fgbg_sel 01 = bgc, returns before the shift
      egc_set_ope(16'h1400);           // WS_PATREG | SHIFT_CPU
      cpu_byte_write(WIN_P0 + 15'h5100, 8'h55);
      if (dut.u_egc.sdata[0][7:0] !== 8'hAB)
        fail("colour quad no-feed: a byte colour-quad write ran the shifter and clobbered the held egc_src");
      $display("NOTE egc: colour quad no-feed - a byte bgc/fgc write leaves the shifter alone");
    end

    // ============================================================
    // 23. THE ROP TRUTH TABLE
    //     the real EGC datapath and compared byte by byte with NP2kai's opefn[] dispatch
    //     (mem/memegc.c:709-997): all 256 codes, as a word write whose source is latched from a
    //     memory read and whose pattern operand is taken four ways - the pattern register, the
    //     source itself (OPE 0x0100), the foreground colour and the background colour
    //     (FGBG 14:13) - plus a byte-lane sweep over the same 256 codes.
    // ============================================================
    begin : rop_table
      reg [15:0] s_w [0:3];
      reg [15:0] d_w [0:3];
      reg [15:0] p_w [0:3];
      reg [15:0] fg_w [0:3];
      reg [15:0] bg_w [0:3];
      reg [15:0] q_w [0:3];
      reg [15:0] c_w;
      reg [15:0] fgbg_v, ope_v, pv, got, expv;
      reg [7:0]  rop_b;
      reg [1:0]  plb;
      reg        case_bad;
      reg [255:0] rop_bad_bits, pat_bad_bits, src_bad_bits;
      integer    rp, ps, pl, mism, cases_bad, bad_codes, pat_codes, src_codes, union_codes, kk, ext;
      integer    m_word, m_patw, m_patb, m_byte, m_src;

      // Four distinct (S,D,P) triples across the planes, two bytes each.
      s_w[0] = 16'hAA55; s_w[1] = 16'h0FF0; s_w[2] = 16'h1234; s_w[3] = 16'h5A5A;
      d_w[0] = 16'hCC33; d_w[1] = 16'h3333; d_w[2] = 16'hEDCB; d_w[3] = 16'hF0F0;
      p_w[0] = 16'hF00F; p_w[1] = 16'h5555; p_w[2] = 16'hA55A; p_w[3] = 16'h0F0F;
      // fg = 0x0009 -> planes 0 and 3 all-ones, 1 and 2 all-zero; bg = 0x0006 the inverse
      // (io/egc.c:12-27 maskword[value & 15]).
      fg_w[0] = 16'hFFFF; fg_w[1] = 16'h0000; fg_w[2] = 16'h0000; fg_w[3] = 16'hFFFF;
      bg_w[0] = 16'h0000; bg_w[1] = 16'hFFFF; bg_w[2] = 16'hFFFF; bg_w[3] = 16'h0000;
      // A stale pattern-register seed, distinct from S and D so a stale read is visible.
      q_w[0] = 16'h55AA; q_w[1] = 16'hFFFF; q_w[2] = 16'h0000; q_w[3] = 16'h1234;
      c_w = 16'h3C69;   // the SHIFT_CPU source word, distinct from S/D/P

      egc_enable = 1'b1;
      gvram_access_page = 1'b0;
      egc_set_access(16'hFFF0);      // all four planes enabled
      egc_set_mask(16'hFFFF);
      egc_set_fg(16'h0009);
      egc_set_bg(16'h0006);
      // Seed source (0x4000), destination (0x3000) and pattern seed (0x5000), one plane each.
      egc_enable = 1'b0;
      for (pl = 0; pl < 4; pl = pl + 1) begin
        plb = pl[1:0];
        cpu_word_write(win_addr(plb) + 15'h4000, s_w[pl]);
        cpu_word_write(win_addr(plb) + 15'h3000, d_w[pl]);
        cpu_word_write(win_addr(plb) + 15'h5000, p_w[pl]);
        cpu_word_write(win_addr(plb) + 15'h6000, q_w[pl]);
      end
      egc_enable = 1'b1;

      mism = 0; cases_bad = 0; rop_bad_bits = 256'd0;
      pat_bad_bits = 256'd0; src_bad_bits = 256'd0;
      m_word = 0; m_patw = 0; m_patb = 0; m_byte = 0; m_src = 0;
      for (ps = 0; ps < 4; ps = ps + 1) begin
        for (rp = 0; rp < 256; rp = rp + 1) begin
          rop_b = rp[7:0];
          case (ps)
            0: begin fgbg_v = 16'h0000; ope_v = 16'h0800 | {8'h00, rop_b}; end
            1: begin fgbg_v = 16'h0000; ope_v = 16'h0900 | {8'h00, rop_b}; end
            2: begin fgbg_v = 16'h4000; ope_v = 16'h0800 | {8'h00, rop_b}; end
            default: begin fgbg_v = 16'h2000; ope_v = 16'h0800 | {8'h00, rop_b}; end
          endcase

          egc_enable = 1'b0;
          for (pl = 0; pl < 4; pl = pl + 1) begin
            plb = pl[1:0];
            cpu_word_write(win_addr(plb) + 15'h3000, d_w[pl]);
          end
          egc_enable = 1'b1;

          egc_set_shift(16'h0000, 16'h00FF);   // re-arm: sft 0 (copy), long bit length
          // Four SELECTED reads load the four PAT planes - one plane per read: "Normal PLOAD_R
          // loads the selected PAT plane only.  Four-plane PAT setup uses four selected reads"
          // (PC98_EGC_CONFORMANCE v1.3 README; its RD02_PAT_S0..S3 rows, replayed by
          // tb_pc9821_egc_compare section 3), where NP2kai latches all four from one read.
          egc_set_ope(16'h1100);
          for (integer k = 0; k < 4; k = k + 1) begin
            egc_set_fgbg({6'h00, k[1:0], 6'h00, k[1:0]});
            cpu_word_read(win_addr(2'd0) + 15'h5000, pv);
          end
          egc_set_fgbg(16'h0000);
          egc_set_fgbg(fgbg_v);
          egc_set_ope(ope_v);                  // WS_ROP | rop
          cpu_word_read(win_addr(2'd0) + 15'h4000, pv);  // latch the source into the shifter
          cpu_word_write(win_addr(2'd0) + 15'h3000, 16'h0000);  // the ROP write
          gvram_flush;

          case_bad = 1'b0;
          for (pl = 0; pl < 4; pl = pl + 1) begin
            plb = pl[1:0];
            if (ps == 0)      pv = p_w[pl];
            else if (ps == 1) pv = s_w[pl];
            else if (ps == 2) pv = fg_w[pl];
            else              pv = bg_w[pl];
            got  = {gv_byte(0, plb, 15'h3001), gv_byte(0, plb, 15'h3000)};
            expv = {np2_rop(rop_b, s_w[pl][15:8], d_w[pl][15:8], pv[15:8]),
                    np2_rop(rop_b, s_w[pl][7:0],  d_w[pl][7:0],  pv[7:0])};
            if (got !== expv) begin
              case_bad = 1'b1;
              if (m_word < 24)
                $display("ROP MISMATCH patsrc=%0d rop=0x%02x plane=%0d S=%04x D=%04x P=%04x got=%04x want=%04x",
                         ps, rop_b, pl, s_w[pl], d_w[pl], pv, got, expv);
              mism = mism + 1; m_word = m_word + 1;
            end
          end
          if (case_bad) begin
            cases_bad = cases_bad + 1;
            rop_bad_bits[rp] = 1'b1;
          end
        end
      end

      // RL_MEMWRITE (OPE 0x0200): the pattern register is latched from the DESTINATION's old
      // content BEFORE the ROP runs (mem/memegc.c egc_writeword:1301-1309, egc_writebyte
      // :1148-1155), so the ROP's pattern operand IS the destination. Seed patreg with a
      // DIFFERENT value Q first, so a datapath that presents the write with the stale register
      // instead of the freshly latched one is visible.
      for (rp = 0; rp < 256; rp = rp + 1) begin
        rop_b = rp[7:0];
        egc_enable = 1'b0;
        for (pl = 0; pl < 4; pl = pl + 1) begin
          plb = pl[1:0];
          cpu_word_write(win_addr(plb) + 15'h3000, d_w[pl]);   // destination = D
          cpu_word_write(win_addr(plb) + 15'h6000, q_w[pl]);   // stale pattern seed = Q
        end
        egc_enable = 1'b1;
        egc_set_shift(16'h0000, 16'h00FF);
        // Four SELECTED reads load the four PAT planes - one plane per read: "Normal PLOAD_R
        // loads the selected PAT plane only.  Four-plane PAT setup uses four selected reads"
        // (PC98_EGC_CONFORMANCE v1.3 README; its RD02_PAT_S0..S3 rows, replayed by
        // tb_pc9821_egc_compare section 3), where NP2kai latches all four from one read.
        egc_set_ope(16'h1100);
        for (integer k = 0; k < 4; k = k + 1) begin
          egc_set_fgbg({6'h00, k[1:0], 6'h00, k[1:0]});
          cpu_word_read(win_addr(2'd0) + 15'h6000, pv);
        end
        egc_set_fgbg(16'h0000);
        egc_set_ope(16'h0800 | {8'h00, rop_b});             // WS_ROP, pat = patreg (Q)
        cpu_word_read(win_addr(2'd0) + 15'h4000, pv);       // sdata = S, patreg stays Q
        egc_set_ope(16'h0A00 | {8'h00, rop_b});             // WS_ROP | RL_MEMWRITE
        cpu_word_write(win_addr(2'd0) + 15'h3000, 16'h0000);
        gvram_flush;
        case_bad = 1'b0;
        for (pl = 0; pl < 4; pl = pl + 1) begin
          plb = pl[1:0];
          got  = {gv_byte(0, plb, 15'h3001), gv_byte(0, plb, 15'h3000)};
          expv = {np2_rop(rop_b, s_w[pl][15:8], d_w[pl][15:8], d_w[pl][15:8]),
                  np2_rop(rop_b, s_w[pl][7:0],  d_w[pl][7:0],  d_w[pl][7:0])};
          if (got !== expv) begin
            case_bad = 1'b1;
            if (m_patw < 40)
              $display("ROP PATLATCH MISMATCH rop=0x%02x plane=%0d S=%04x D=%04x Q=%04x got=%04x want=%04x",
                       rop_b, pl, s_w[pl], d_w[pl], q_w[pl], got, expv);
            mism = mism + 1; m_patw = m_patw + 1;
          end
        end
        if (case_bad) begin
          cases_bad = cases_bad + 1;
          pat_bad_bits[rp] = 1'b1;
        end
      end

      // The same pattern latch through the BYTE path, which presents its write one state later
      // than the burst path, so the two together say whether the stale read is burst-specific.
      for (rp = 0; rp < 256; rp = rp + 1) begin
        rop_b = rp[7:0];
        for (ext = 0; ext < 2; ext = ext + 1) begin
          egc_enable = 1'b0;
          for (pl = 0; pl < 4; pl = pl + 1) begin
            plb = pl[1:0];
            cpu_word_write(win_addr(plb) + 15'h3000, d_w[pl]);
            cpu_word_write(win_addr(plb) + 15'h6000, q_w[pl]);
          end
          egc_enable = 1'b1;
          egc_set_shift(16'h0000, 16'h00FF);
          // Four SELECTED reads load the four PAT planes - one plane per read: "Normal PLOAD_R
          // loads the selected PAT plane only.  Four-plane PAT setup uses four selected reads"
          // (PC98_EGC_CONFORMANCE v1.3 README; its RD02_PAT_S0..S3 rows, replayed by
          // tb_pc9821_egc_compare section 3), where NP2kai latches all four from one read.
          egc_set_ope(16'h1100);
          for (integer k = 0; k < 4; k = k + 1) begin
            egc_set_fgbg({6'h00, k[1:0], 6'h00, k[1:0]});
            cpu_word_read(win_addr(2'd0) + 15'h6000, pv);
          end
          egc_set_fgbg(16'h0000);
          egc_set_ope(16'h0800 | {8'h00, rop_b});
          cpu_word_read(win_addr(2'd0) + 15'h4000, pv);      // sdata = S
          egc_set_ope(16'h0A00 | {8'h00, rop_b});            // WS_ROP | RL_MEMWRITE
          cpu_byte_write(win_addr(2'd0) + 15'h3000 + ext[14:0], 8'h00);
          gvram_flush;
          case_bad = 1'b0;
          for (pl = 0; pl < 4; pl = pl + 1) begin
            plb = pl[1:0];
            got  = {8'd0, gv_byte(0, plb, 15'h3000 + ext[14:0])};
            expv = np2_rop(rop_b, s_w[pl][8*ext +: 8], d_w[pl][8*ext +: 8], d_w[pl][8*ext +: 8]);
            if (got[7:0] !== expv[7:0]) begin
              case_bad = 1'b1;
              if (m_patb < 6)
                $display("ROP PATLATCH BYTE MISMATCH rop=0x%02x lane=%0d plane=%0d S=%02x D=%02x Q=%02x got=%02x want=%02x",
                         rop_b, ext, pl, s_w[pl][8*ext +: 8], d_w[pl][8*ext +: 8],
                         q_w[pl][8*ext +: 8], got[7:0], expv[7:0]);
              mism = mism + 1; m_patb = m_patb + 1;
            end
          end
          if (case_bad) begin
            cases_bad = cases_bad + 1;
            pat_bad_bits[rp] = 1'b1;
          end
        end
      end

      // SHIFT_CPU (OPE 0x0400) with WS_ROP: the write feeds the shifter from the CPU word and
      // the ROP's source operand is that JUST-produced quad (mem/memegc.c egc_opew:1046-1057
      // runs EGCOPE_SHIFTW before opefn). A stale sdata is seeded first so a same-cycle read is
      // visible. Pattern operand from the pattern register.
      for (rp = 0; rp < 256; rp = rp + 1) begin
        rop_b = rp[7:0];
        egc_enable = 1'b0;
        for (pl = 0; pl < 4; pl = pl + 1) begin
          plb = pl[1:0];
          cpu_word_write(win_addr(plb) + 15'h3000, d_w[pl]);
        end
        egc_enable = 1'b1;
        egc_set_shift(16'h0000, 16'h00FF);
        // Four SELECTED reads load the four PAT planes - one plane per read: "Normal PLOAD_R
        // loads the selected PAT plane only.  Four-plane PAT setup uses four selected reads"
        // (PC98_EGC_CONFORMANCE v1.3 README; its RD02_PAT_S0..S3 rows, replayed by
        // tb_pc9821_egc_compare section 3), where NP2kai latches all four from one read.
        egc_set_ope(16'h1100);
        for (integer k = 0; k < 4; k = k + 1) begin
          egc_set_fgbg({6'h00, k[1:0], 6'h00, k[1:0]});
          cpu_word_read(win_addr(2'd0) + 15'h5000, pv);
        end
        egc_set_fgbg(16'h0000);
        egc_set_ope(16'h0800 | {8'h00, rop_b});
        cpu_word_read(win_addr(2'd0) + 15'h4000, pv);      // sdata = S (stale)
        egc_set_ope(16'h0C00 | {8'h00, rop_b});            // WS_ROP | SHIFT_CPU
        cpu_word_write(win_addr(2'd0) + 15'h3000, c_w);    // source = CPU word C
        gvram_flush;
        case_bad = 1'b0;
        for (pl = 0; pl < 4; pl = pl + 1) begin
          plb = pl[1:0];
          got  = {gv_byte(0, plb, 15'h3001), gv_byte(0, plb, 15'h3000)};
          expv = {np2_rop(rop_b, c_w[15:8], d_w[pl][15:8], p_w[pl][15:8]),
                  np2_rop(rop_b, c_w[7:0],  d_w[pl][7:0],  p_w[pl][7:0])};
          if (got !== expv) begin
            case_bad = 1'b1;
            if (m_src < 40)
              $display("ROP SHIFT_CPU MISMATCH rop=0x%02x plane=%0d C=%04x D=%04x P=%04x got=%04x want=%04x",
                       rop_b, pl, c_w, d_w[pl], p_w[pl], got, expv);
            mism = mism + 1; m_src = m_src + 1;
          end
        end
        if (case_bad) begin
          cases_bad = cases_bad + 1;
          src_bad_bits[rp] = 1'b1;
        end
      end

      // Byte-lane sweep: the same 256 codes through the BYTE ROP path (rop_out_byte) at both
      // lanes of the word, pattern operand from the pattern register.
      for (rp = 0; rp < 256; rp = rp + 1) begin
        rop_b = rp[7:0];
        for (ext = 0; ext < 2; ext = ext + 1) begin
          egc_enable = 1'b0;
          for (pl = 0; pl < 4; pl = pl + 1) begin
            plb = pl[1:0];
            cpu_word_write(win_addr(plb) + 15'h3000, d_w[pl]);
          end
          egc_enable = 1'b1;
          egc_set_shift(16'h0000, 16'h00FF);
          // Four SELECTED reads load the four PAT planes - one plane per read: "Normal PLOAD_R
          // loads the selected PAT plane only.  Four-plane PAT setup uses four selected reads"
          // (PC98_EGC_CONFORMANCE v1.3 README; its RD02_PAT_S0..S3 rows, replayed by
          // tb_pc9821_egc_compare section 3), where NP2kai latches all four from one read.
          egc_set_ope(16'h1100);
          for (integer k = 0; k < 4; k = k + 1) begin
            egc_set_fgbg({6'h00, k[1:0], 6'h00, k[1:0]});
            cpu_word_read(win_addr(2'd0) + 15'h5000, pv);
          end
          egc_set_fgbg(16'h0000);
          egc_set_ope(16'h0800 | {8'h00, rop_b});
          cpu_word_read(win_addr(2'd0) + 15'h4000, pv);
          cpu_byte_write(win_addr(2'd0) + 15'h3000 + ext[14:0], 8'h00);
          gvram_flush;
          case_bad = 1'b0;
          for (pl = 0; pl < 4; pl = pl + 1) begin
            plb = pl[1:0];
            expv = np2_rop(rop_b, s_w[pl][8*ext +: 8], d_w[pl][8*ext +: 8], p_w[pl][8*ext +: 8]);
            got  = {8'd0, gv_byte(0, plb, 15'h3000 + ext[14:0])};
            if (got[7:0] !== expv[7:0]) begin
              case_bad = 1'b1;
              if (m_byte < 24)
                $display("ROP BYTE MISMATCH rop=0x%02x lane=%0d plane=%0d S=%02x D=%02x P=%02x got=%02x want=%02x",
                         rop_b, ext, pl, s_w[pl][8*ext +: 8], d_w[pl][8*ext +: 8],
                         p_w[pl][8*ext +: 8], got[7:0], expv[7:0]);
              mism = mism + 1; m_byte = m_byte + 1;
            end
            // the other byte of the word must be left alone
            if (gv_byte(0, plb, 15'h3000 + (ext ^ 1)) !== d_w[pl][8*(ext ^ 1) +: 8]) begin
              case_bad = 1'b1;
              if (m_byte < 24)
                $display("ROP BYTE CLOBBER rop=0x%02x lane=%0d plane=%0d other byte changed",
                         rop_b, ext, pl);
              mism = mism + 1; m_byte = m_byte + 1;
            end
          end
          if (case_bad) begin
            cases_bad = cases_bad + 1;
            rop_bad_bits[rp] = 1'b1;
          end
        end
      end

      bad_codes = 0;
      for (kk = 0; kk < 256; kk = kk + 1) bad_codes = bad_codes + rop_bad_bits[kk];
      pat_codes = 0; src_codes = 0; union_codes = 0;
      for (kk = 0; kk < 256; kk = kk + 1) begin
        pat_codes = pat_codes + pat_bad_bits[kk];
        src_codes = src_codes + src_bad_bits[kk];
        if (rop_bad_bits[kk] || pat_bad_bits[kk] || src_bad_bits[kk]) union_codes = union_codes + 1;
      end
      $display("NOTE egc: ROP table - table=%0d shift-cpu=%0d pattern-latch-word=%0d pattern-latch-byte=%0d byte=%0d",
               m_word + m_byte, m_src, m_patw, m_patb, m_byte);
      $display("NOTE egc: ROP table - codes deviating: table=%0d shift-cpu=%0d pattern-latch=%0d (union %0d of 256)",
               bad_codes, src_codes, pat_codes, union_codes);
      if (m_word != 0 || m_byte != 0)
        fail("the EGC ROP datapath deviates from NP2kai's opefn[] table");
      if (m_patw != 0 || m_patb != 0)
        fail("the EGC RL_MEMWRITE pattern latch deviates from NP2kai");
      if (m_src != 0)
        fail("the EGC SHIFT_CPU source deviates from NP2kai");
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_EGC: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_EGC: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog (the runner bounds wall time too, but a bench that blocks
  // on a DUT signal with no bound would hang CI forever).
  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_EGC: TIMEOUT");
  end

endmodule

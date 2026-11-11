`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GVRAM_PORTA_EQUIV: a CYCLE-EXACT EQUIVALENCE (characterization, not a hardware claim) for the CPU-request -> GVRAM write-enable cone - an 80 MHz fit's worst same-clock family, ext_addr_r -> u_gmem's altsyncram port-A write captures. The array's port-A pins as the array reads them ({en, we, addr} on EVERY capturing clk_sys edge, {be, din} on every capturing write edge) must be bit-identical (and en/we idle-identical every cycle) to a golden computed from the documented semantics in independent arithmetic: the device-alias/window decode transcribed from pc9821_memory_subsystem/pc9821_memory_map, the one-visit walk and G_IDLE/G_RDC/G_RMWC tails of pc9821_gvram_arb, the GRCG capture-cycle presentation of pc9821_grcg (TDW pair bursts incl the both-pairs form, RMW mixed / 0xFF read-skip / 0x00 dead lane / holed datums, TCR read runs) and the EGC unit walk and column write issue of pc9821_egc (WS_CPU word-unit bursts and byte-unit singles, COMPAREREAD runs), with the RMW merge bytes from the golden's own array image. The same stream through the device aliases (the 15-16 MiB mirror, window-0 bias, the PEGC high alias and the EMS-shaded window, whose silence is pinned), posted back-to-back stores with the accept stall, read-after-write same/adjacent words, scanout line ticks during a walk, mid-walk 0x7C/0x7E writes, win0_sel/sys16m_en/ems_state changes between requests, a mid-walk reset and a cpu_run stall (the array is not reset: captures up to the reset edge are kept and pinned, later ones must vanish). The altsyncram has no input-register stage (OUTDATA_REG_A=UNREGISTERED, no INDATA/WRCONTROL/ADDRESS regs), so the block's edge capture IS the port contract this pins.
//
// TB_PC9821_GVRAM_PORTA_EQUIV: a CYCLE-EXACT EQUIVALENCE bench for the CPU-request ->
// GVRAM write-enable cone (the fitted lightoc build's worst same-clock family: the
// ext_addr_r -> u_gmem porta_we_reg family), pinned as a characterization against the
// documented semantics and NOT as a hardware claim: the hardware behaviour lives in the
// reference-derived benches (tb_pc9821_gfx_walk_hold, tb_pc9821_gvram_coherence,
// tb_pc9821_planewin_draw, the egc/grcg benches) and must stay green beside this one.
//
// THE CONTRACTS, asserted by NAME:
//  [porta-capture-identity] the GVRAM array's port-A pins carry a bit-identical
//     {a_en, a_we, a_be, a_addr, a_din} on EVERY clk_sys cycle in which the port actually
//     CAPTURES (a_en=1: a write edge captures {addr, data, be}, a read edge captures
//     {addr} into a_dout), and {a_en, a_we} are bit-identical EVERY cycle including idle.
//     This is the refactor contract for pc9821_gvram_mem's write decode and everything
//     upstream of it: the altsyncram's write port is the block's own edge capture (the map
//     report's parameter block for memN_rtl_0 has OUTDATA_REG_A=UNREGISTERED and no
//     INDATA/WRCONTROL/ADDRESS input-register stage; `ram_block1a63~porta_we_reg` in the
//     timing report is the write capture BEHIND the ram_block1a63|portawe pin, one Tco
//     past it), so "the port-A input registers capture identical values on identical
//     edges" is exactly "these pins are identical on every capturing edge". The idle
//     (a_en=0) values of addr/data/be are stated BLIND (below): the block captures
//     nothing there, and the port-B forward only observes them under a write edge, which
//     is pinned here.
//  [alias-decode-identity] the same store driven through the device aliases - the direct
//     plane windows, the 15-16 MiB mirror (0xFA8020), window-0 biased forms (0x461 =
//     0x0A / 0x0B / 0x0E), the PEGC high alias (0xFFF08020: EVRAM, not GVRAM) and the
//     EMS-shaded 0xB0000 window (ems_state != 0: not GVRAM) - produces the documented
//     port stream or the documented silence, so the device-alias/direct-request decode in
//     pc9821_memory_subsystem / pc9821_memory_map cannot move under the refactor.
//  [shape-coverage] the stream shapes are pinned across plain dword/word/byte/misaligned
//     stores and reads (the one-visit walk), GRCG TDW pair bursts (0x0011 / 0x1100 /
//     0xFFFF both-pairs), GRCG RMW mixed / 0xFF read-skip / 0x00 dead-lane / holed
//     datums, the GRCG TCR read run, EGC WS_CPU word-unit bursts and byte-unit singles
//     and the EGC COMPAREREAD column run - each as the documented access count and the
//     documented per-access {en,we,be,addr,din} from INDEPENDENT arithmetic (the golden
//     never reads the DUT: the RMW merge bytes come from the golden's own image).
//  [interleave-identity] back-to-back stores with the second presented while the first
//     walk drains (the accept stall), read-after-write to the same and the adjacent word
//     (the array is the read-after-write view; the write-combining buffer is gone, so "buffer hit/miss" here means exactly these raw interleavings), scanout
//     line ticks during a walk (the port-B share whose forward rides these same pins) and
//     an access-page change between requests all keep the port stream identical.
//  [mid-request-config-identity] a `out 0x7C`/`0x7E` (grcg_we) landing while a GRCG RMW
//     walk drains does not move the walk's remaining port cycles (the GRCG holds
//     cl_rmw/cl_wbe/cl_wdata until its own cl_done and the arb latches m_lane_be/m_tile),
//     and win0_sel / sys16m_en / ems_state changes between requests move the decode
//     exactly as documented.
//  [reset-and-stall-identity] a mid-walk reset and a cpu_run stall (an ioctl download
//     pulse) let the port capture exactly the edges before the reset/stall edge and go
//     quiet after it (the array is not reset: a write presented before the edge still
//     commits, and its record is kept), and the first post-recovery request streams
//     bit-identically.
//
// THE GOLDEN MODEL never reads the DUT. It decodes each CPU request with an independent
// transcription of the documented device-alias/window equations (pc9821_memory_subsystem.sv's
// eff_addr translations + pc9821_memory_map.sv's win0 bias and plane-window decode), then
// schedules the documented port accesses of the owning path in independent arithmetic: the
// one-visit walk and G_IDLE/G_RDC/G_RMWC tails of pc9821_gvram_arb, the GRCG's
// capture-cycle presentation of pc9821_grcg, the EGC's unit walk and column write issue of
// pc9821_egc. Calibration note (characterization, not a hardware claim): the per-shape
// schedule offsets are transcribed from the documented state flows and were checked on the
// PRE-CHANGE RTL this bench must pass on; they pin current behaviour, and a future change
// of it is exactly what this bench must catch.
//
// WHAT IT IS BLIND TO, stated: (1) it is not a hardware-behaviour bench - no NP2kai value
// is asserted here; (2) the idle (a_en=0) values of a_addr/a_din/a_be are not pinned (the
// block captures nothing there and the port-B forward only samples them under a write
// edge, which is pinned) - nothing may be made to depend on them; (3) the port-B fetch
// stream (gmb_*) is driven but not stream-pinned here (the scanout's benches own it; the
// port-A pinning makes the write-forward identical because rdw_* samples exactly these
// pins on exactly these edges); (4) the EGC stream is pinned for the WS_CPU (OPE 0x0000,
// mask 0xFFFF, shifter armed at zero) and COMPAREREAD (OPE 0x2000) command families only
// - the ROP / pattern / shifter produce families are tb_pc9821_egc*.sv's.

`default_nettype none

module tb_pc9821_gvram_porta_equiv;
  // pc9821_memory_subsystem's pack-download hold: no boot-ROM download under the OSD Reset
  // level here (tb_pc9821_boot0_load drives that), so the level is low and the hold unread.
  wire hps_apply_reset = 1'b0;
  wire pack_load_hold;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // The shared cycle index: during the interval after edge k, cyc == k. A golden record
  // names the interval whose LEVEL the array captures at that interval's end edge.
  reg [31:0] cyc = 0;
  always @(posedge clk) cyc <= cyc + 32'd1;

  // ==== DUT harness: the pc9821_memory_subsystem port shape ====
  reg [3:0] top_bank = 4'd8;
  reg ide_rom_enable = 0;
  reg        ide_ram_gate = 1;
    // 0x1E8E's IDE work-RAM gate: held ON so nothing here sees the gated
    // shape - tb_pc9821_memory_subsystem and tb_pc9821_memory_map pin it.
  reg bios_ram_gate = 0;
  reg top_shadow_en = 0;
  reg  soft_reboot = 1'b0;   // no reboot strobe in this bench
  reg [7:0] win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  reg  sys16m_en = 1'b1;
  reg  [1:0] ems_state = 2'd0;
  reg [31:0] pack_base = 32'h01F8_0000;
  reg [31:0] guest_ram_bytes = 32'h0200_0000;
  reg gvram_access_page = 0;

  reg        egc_enable = 1'b0;
  reg [15:0] egc_access = 16'hFFF0;
  reg [15:0] egc_fgbg = 16'h0000;
  reg [15:0] egc_ope = 16'h0000;
  reg [15:0] egc_fg = 16'h0000;
  reg [15:0] egc_mask = 16'hFFFF;
  reg [15:0] egc_bg = 16'h0000;
  reg [15:0] egc_sft = 16'h0000;
  reg [15:0] egc_leng = 16'h0000;
  reg        egc_shift_we = 1'b0;

  reg ioctl_download = 0, ioctl_wr = 0;
  reg [15:0] ioctl_index = 0;
  reg [26:0] ioctl_addr = 0;
  reg [15:0] ioctl_dout = 0;
  wire ioctl_wait, rom_ready, load_error, cpu_run;
  wire [17:0] font_addr;
  wire [15:0] font_data;
  wire font_we;

  reg [31:0] cpu_addr = 0, cpu_din = 0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  reg [3:0] cpu_be = 4'hF;
  reg [7:0] cpu_burstcount = 1;
  reg cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  wire cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  wire [13:0] tram_addr;
  wire [7:0] tram_din;
  wire tram_we;
  reg [7:0] tram_dout = 0;
  wire [4:0] cg_win_byte_sel;
  wire cg_win_rd;
  reg [7:0] cg_win_dout = 0;
  wire [7:0] cg_win_din;
  wire cg_win_we;
  reg [18:0] font_req_addr = 0;
  reg font_req = 0;
  wire font_word_valid;
  wire [31:0] font_word_data;
  wire [31:0] fmem_addr, fmem_din;
  wire fmem_valid, fmem_write;
  wire [3:0] fmem_be;
  wire [7:0] fmem_burstcount;
  reg fmem_ready = 1, fmem_resp_valid = 0;
  reg [31:0] fmem_dout = 32'd0;

  wire [31:0] mem_addr, mem_din;
  reg [31:0] mem_dout = 32'hA5A55A5A;
  wire [3:0] mem_be;
  wire [7:0] mem_burstcount;
  wire mem_valid, mem_write;
  reg mem_ready = 1, mem_resp_valid = 0;

  wire [31:0] mem3_addr, mem3_din;
  wire  [3:0] mem3_be;
  wire  [7:0] mem3_burstcount;
  wire        mem3_valid, mem3_write;
  reg  [31:0] mem3_dout = 32'h0;
  reg         mem3_ready = 1, mem3_resp_valid = 0;

  reg        grcg_we = 0;
  reg  [7:0] grcg_addr = 0;
  reg  [7:0] grcg_din = 0;
  wire       grcg_expand;
  wire       grcg_expand_nx;   // mode[7]'s next state (opt-video VID-1); unused here


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

  wire [31:0] mem_din_hi;

  wire [127:0] dbg_gfx_stats;
  wire dbg_walk_start, dbg_walk_cycle;
  wire dbg_egc_txn, dbg_egc_unit, dbg_grcg_store;
  wire dbg_gr_owned, dbg_eg_owned;
  wire dbg_access_page, dbg_scan_page_q;
  wire cg_win_byte_hold = 1'b0;
  wire gfx_odd_line = 1'b0;
  // SYS_CLOCK_HZ is this bench's own clock: 5 ns half-period = 10 ns = 100 MHz, so the GVRAM's
  // time-derived per-operation periods (pc9821_gvram_arb's GVRAM_PERIODS) are converted from
  // 100 MHz here, exactly as the core's build converts them from SYS_FREQ.
  // ==== DUT ====
  // The 16-colour mode (the guest's OUT 0x6A,0x01, FF2 num 0): this bench reaches the E plane at
  // 0xE0000-0xE7FFF, which the machine maps only in that mode (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b1;
  `ifdef VERILATOR
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

  pc9821_memory_subsystem #(.SYS_CLOCK_HZ(100_000_000)) dut (.*);
  `else
  // ---- pc9821_memory_subsystem's DMA bus-master port, tied off (see the iobus block) ----
/* verilator lint_off UNUSEDSIGNAL */
  wire        dma_addr_unused = 1'b0;
  wire [31:0] dma_addr = 32'd0;
  wire [31:0] dma_din  = 32'd0;
  wire [3:0]  dma_be   = 4'd0;
  wire        dma_valid = 1'b0;
  wire        dma_write = 1'b0;
  wire        dma_ready, dma_resp_valid;
  wire [31:0] dma_dout;
/* verilator lint_on UNUSEDSIGNAL */
  pc9821_memory_subsystem #(.SYS_CLOCK_HZ(100_000_000)) dut (.*);
  `endif

  // The array's port-A pins: exactly what u_gmem captures at each edge (the same
  // one-level probe shape tb_pc9821_gfx_walk_hold uses).
  wire        p_en   = dut.gma_en;
  wire        p_we   = dut.gma_we;
  wire  [3:0] p_be   = dut.gma_be;
  wire [15:0] p_addr = dut.gma_addr;
  wire [31:0] p_din  = dut.gma_din;

  // ==== CHECKS ====
  integer errors = 0;
  integer checks = 0;

  task automatic fail(input [8*260-1:0] what);
    begin
      $display("FAIL %0s (cyc %0d)", what, cyc);
      errors = errors + 1;
    end
  endtask

  // ==========================================================================
  // THE GOLDEN STREAM: one record per CAPTURING cycle (en=1). Idle cycles must show
  // en=0 and we=0 (checked every cycle by the checker below).
  // ==========================================================================
  localparam integer MAXEV = 20000;
  integer ev_n = 0, ev_i = 0;
  integer    ev_cyc  [0:MAXEV-1];
  reg        ev_we   [0:MAXEV-1];
  reg  [3:0] ev_be   [0:MAXEV-1];
  reg [15:0] ev_addr [0:MAXEV-1];
  reg [31:0] ev_din  [0:MAXEV-1];
  reg [8*120-1:0] ev_tag [0:MAXEV-1];
  reg [8*120-1:0] cur_tag = "init";

  task automatic exp(input integer c, input we, input [3:0] be,
                     input [15:0] a, input [31:0] d);
    begin
      ev_cyc[ev_n]  = c;
      ev_we[ev_n]   = we;
      ev_be[ev_n]   = be;
      ev_addr[ev_n] = a;
      ev_din[ev_n]  = d;
      ev_tag[ev_n]  = cur_tag;
      ev_n = ev_n + 1;
    end
  endtask

  // The reset/stall truncation: the array is not reset, so the captures whose edge is at
  // or before interval r still happen; everything later is dead and must be silent.
  task automatic truncate_after(input integer r);
    begin
      while (ev_n > ev_i && ev_cyc[ev_n-1] > r) ev_n = ev_n - 1;
    end
  endtask

  // ---- The golden's own image of the four plane bytes (RMW merge arithmetic) ----
  // index = ((page * 32768) + word15) * 4 + plane; one byte per plane per word.
  reg [7:0] gold [0:262143];
  integer gi;
  function integer gidx(input integer pg, input integer word15, input integer pl);
    gidx = ((pg * 32768) + word15) * 4 + pl;
  endfunction

  task automatic gold_set_word(input integer pg, input [15:0] waddr,
                               input [31:0] d, input [3:0] be);
    integer pl;
    begin
      for (pl = 0; pl < 4; pl = pl + 1)
        if (be[pl]) gold[gidx(pg, waddr & 16'h7FFF, pl)] = d[8*pl +: 8];
    end
  endtask

  function [31:0] gold_get_word(input integer pg, input [15:0] waddr);
    gold_get_word = {gold[gidx(pg, waddr & 16'h7FFF, 3)],
                     gold[gidx(pg, waddr & 16'h7FFF, 2)],
                     gold[gidx(pg, waddr & 16'h7FFF, 1)],
                     gold[gidx(pg, waddr & 16'h7FFF, 0)]};
  endfunction

  // ==========================================================================
  // THE DEVICE-ALIAS / WINDOW DECODE, transcribed independently from the documented
  // equations (pc9821_memory_subsystem.sv's eff_addr + pc9821_memory_map.sv's d_addr /
  // win0 bias and plane-window decode). Nothing here reads the DUT.
  // ==========================================================================
  reg        dec_hit;
  reg        dec_page;
  reg [1:0]  dec_plane;
  reg [14:0] dec_off;

  task automatic decode_req(input [31:0] a);
    reg [31:0] eff, d;
    reg        mirror, peg, win0_moved;
    reg [8:0]  win0_hi;
    reg [19:0] low20;
    reg        ems_shadow, contig, inten;
    begin
      mirror = sys16m_en && (a >= 32'h00FA_0000) && (a <= 32'h00FF_FFFF);
      peg    = sys16m_en && (a >= 32'hFFF0_0000) && (a <= 32'hFFF7_FFFF);
      eff    = mirror ? {12'd0, a[19:0]} :
               peg    ? {8'd0,  a[23:0]} : a;
      win0_moved = (eff >= 32'h0008_0000) && (eff <= 32'h0009_FFFF) && (win0_sel != 8'h08);
      win0_hi = {1'b0, win0_sel} + {8'd0, eff[16]};
      d = win0_moved ? {7'd0, win0_hi, eff[15:0]} : eff;
      low20 = d[19:0];
      ems_shadow = (low20 >= 20'hB0000) && (low20 <= 20'hBFFFF) &&
                   !(|d[31:20]) && (ems_state != 2'd0);
      contig = (low20 >= 20'hA8000) && (low20 <= 20'hBFFFF) && !ems_shadow;
      // The E plane only in the 16-colour mode (DMAROUTE-XE10.TXT P4 view V1: open bus otherwise).
      inten  = (low20 >= 20'hE0000) && (low20 <= 20'hE7FFF) && mode2_16color;
      // Window 0 at 0x0A is RAM of its own (no plane window): docs/probes/DMAROUTE-XE10.TXT W1.
      dec_hit = (contig || inten) && !(|d[31:20]) && !(win0_moved && (win0_sel == 8'h0A));
      dec_plane = contig ? (low20[16:15] - 2'd1) : 2'd3;
      dec_off = low20[14:0];
      dec_page = gvram_access_page;
    end
  endtask

  // ==========================================================================
  // STREAM GENERATORS: the documented port schedule of each store shape. Each takes
  // the ACCEPT interval (the interval whose end edge commits the client's capture) and
  // returns the interval the path is next free through *_next.
  // ==========================================================================

  // ---- The plain one-visit walk ----
  // The accept edge loads the client's presentation registers; walk_first resolves the
  // first live lane at acc+1 and one lane per clk_sys follows (writes) or per two
  // (reads: an issue cycle and its G_RDC capture). The write's done pulses one interval
  // after the last lane and cs returns to C_IDLE one interval later; a read keeps
  // C_RESP/C_RESP2 for two more.
  integer pl_next;
  task automatic gold_plain(input integer acc, input [31:0] a, input [31:0] din,
                            input [3:0] be, input wr);
    integer k, n, slot;
    reg [15:0] waddr;
    begin
      decode_req(a);
      if (!dec_hit) begin
        pl_next = acc + 2;
        free_at = pl_next;
      end else begin
        n = 0;
        slot = acc + 1;
        for (k = 0; k < 4; k = k + 1) begin
          if (be[k]) begin
            waddr = {dec_page, dec_off[14:2], k[1:0]};
            if (wr) begin
              exp(slot + n, 1'b1, (4'h1 << dec_plane), waddr, {4{din[8*k +: 8]}});
              gold_set_word(dec_page, waddr, {4{din[8*k +: 8]}}, (4'h1 << dec_plane));
              n = n + 1;
            end else begin
              exp(slot + 2*n, 1'b0, (4'h1 << dec_plane), waddr, {4{din[8*k +: 8]}});
              n = n + 1;
            end
          end
        end
        if (wr) begin pl_next = slot + n + 1; free_at = pl_next; end
        else    begin pl_next = slot + 2*n + 3; free_at = pl_next; end
      end
    end
  endtask

  // ---- The GRCG's capture-cycle presentation ----
  // mode[3:0] = active-LOW plane enables (cl_wbe = ~mode[3:0]); mode[7] = expand (owns
  // stores); mode[6] = RMW. The first live lane rides the accept interval itself. Lane
  // cost: 2 (read + the G_RMWC merge write) for a mixed RMW lane, 1 (write) for a TDW
  // lane or a 0xFF RMW read-skip, 0 for a 0x00 dead lane.
  integer gr_next;
  reg [3:0] gr_wbe;
  task automatic gold_grcg(input integer acc, input [31:0] a, input [31:0] din,
                           input [3:0] be, input [7:0] mode, input [31:0] tile);
    integer k, n, slot;
    reg [15:0] waddr, wbase;
    reg [7:0] dbyte;
    reg [31:0] emask, gmask, oldw;
    begin
      decode_req(a);
      gr_wbe = ~mode[3:0];
      // the pair-burst class, transcribed from pc9821_grcg's tdw_burst: a column PAIR
      // goes as ONE two-word request when the pair's enables are the whole pair and
      // (TDW always / RMW only at a 0xFF datum pair - the read-skip merge reduces to the
      // tile). Any other enable set keeps the per-lane walk.
      begin : pair_class
        reg p0, p1, plo, phi, pboth;
        p0 = (be[1:0] == 2'b11) && (!mode[6] || ((din[7:0] == 8'hFF) && (din[15:8] == 8'hFF)));
        p1 = (be[3:2] == 2'b11) && (!mode[6] || ((din[23:16] == 8'hFF) && (din[31:24] == 8'hFF)));
        plo = p0 && (be[3:2] == 2'b00);
        phi = p1 && (be[1:0] == 2'b00);
        pboth = (be == 4'b1111) && p0 && p1;
      if (!dec_hit) begin
        gr_next = acc + 2;
        free_at = gr_next;
      end else if ((mode[3:0] == 4'h0) && (plo || phi || pboth)) begin
        // TDW pair burst(s): word 0 rides the accept cycle, word 1 the G_W2B cycle.
        wbase = {dec_page, dec_off[14:2], 2'b00};
        if (be == 4'b1100) wbase = wbase + 16'd2;
        exp(acc,   1'b1, 4'hF, wbase,         tile);
        exp(acc+1, 1'b1, 4'hF, wbase + 16'd1, tile);
        gold_set_word(dec_page, wbase,         tile, 4'hF);
        gold_set_word(dec_page, wbase + 16'd1, tile, 4'hF);
        if (pboth) begin
          // the BOTH-pairs form's second pair: the GRCG re-presents it one clk_sys after the first
          // pair's cl_done (one bubble cycle), but the SECOND PAIR IS A SECOND CLIENT REQUEST and
          // the arbiter takes it only when the device's own per-operation period - the GRCG store's
          // 103.9 ns of docs/probes/GFX2.TXT, converted from SYS_CLOCK_HZ - has run out, armed by
          // the first pair's accept. That period is the binding floor here (it is longer than the
          // bubble), and it is read from the RTL's OWN GVRAM_PERIODS constant rather than restated.
          exp(acc + GVRAM_GR_HOLD,     1'b1, 4'hF, wbase + 16'd2, tile);
          exp(acc + GVRAM_GR_HOLD + 1, 1'b1, 4'hF, wbase + 16'd3, tile);
          gold_set_word(dec_page, wbase + 16'd2, tile, 4'hF);
          gold_set_word(dec_page, wbase + 16'd3, tile, 4'hF);
          gr_next = acc + GVRAM_GR_HOLD + 2;
          free_at = gr_next;
        end else begin
          gr_next = acc + 4;
          free_at = gr_next;
        end
      end else begin
        slot = acc;
        n = 0;
        for (k = 0; k < 4; k = k + 1) begin
          if (be[k]) begin
            dbyte = din[8*k +: 8];
            // the 0x00 dead-lane skip is RMW-only (lane_rmw gates lane_datum0); a TDW
            // lane writes the tile whatever the CPU datum byte is
            if (!mode[6] || (dbyte != 8'h00)) begin
              waddr = {dec_page, dec_off[14:2], k[1:0]};
              if (mode[6] && (dbyte != 8'hFF)) begin
                // a mixed RMW lane: the old word rides the read presentation and the
                // merged word goes back from G_RMWC one clk_sys later.
                exp(slot + n,     1'b0, gr_wbe, waddr, tile);
                emask = {{8{gr_wbe[3]}}, {8{gr_wbe[2]}}, {8{gr_wbe[1]}}, {8{gr_wbe[0]}}};
                gmask = emask & {4{dbyte}};
                oldw  = gold_get_word(dec_page, waddr);
                exp(slot + n + 1, 1'b1, 4'hF, waddr, (oldw & ~gmask) | (tile & gmask));
                gold_set_word(dec_page, waddr, (oldw & ~gmask) | (tile & gmask), 4'hF);
                n = n + 2;
              end else begin
                // a TDW lane or a 0xFF RMW read-skip: one write, the tile alone
                exp(slot + n, 1'b1, gr_wbe, waddr, tile);
                gold_set_word(dec_page, waddr, tile, gr_wbe);
                n = n + 1;
              end
            end
          end
        end
        gr_next = slot + n + 1;
        free_at = gr_next;
      end
      end
    end
  endtask

  // ---- The GRCG TCR read run: one cl read burst, one column access per clk_sys ----
  task automatic gold_tcr(input integer acc, input [31:0] a, input [3:0] be,
                          input [7:0] mode);
    integer c0, c1, c, slot;
    reg [15:0] wbase;
    begin
      decode_req(a);
      slot = acc + 2;   // G_IDLE captures the read at acc, G_TB presents at acc+2
      if (dec_hit) begin
        c0 = 0; c1 = 3;
        for (c = 0; c < 4; c = c + 1) if (be[c]) begin c0 = c; c = 4; end
        for (c = 3; c >= 0; c = c - 1) if (be[c]) begin c1 = c; c = -1; end
        wbase = {dec_page, dec_off[14:2], 2'b00};
        // the cc_rd_burst arm of g_single sets only gma_we low: gma_be keeps the arm's
        // 4'hF default and gma_din zero on every read-burst access (documented "Port A's
        // presented access" arm), so the burst reads present be = 4'hF whatever the
        // request's cl_wbe is
        for (c = c0; c <= c1; c = c + 1)
          exp(slot + (c - c0), 1'b0, 4'hF, wbase + c[15:0], 32'd0);
        gr_next = slot + (c1 - c0) + 2;
        free_at = gr_next;
      end else begin gr_next = slot + 1; free_at = gr_next; end
    end
  endtask

  // ---- The EGC's WS_CPU byte units and COMPAREREAD run ----
  // The unit walk (word_unit / next_set_lane, pc9821_egc.sv) and the column write issue
  // (col_wdata / col_wbe of g_col_plane, transcribed) with OPE 0x0000 (WS_CPU), mask
  // 0xFFFF and plane_en = ~egc_access[3:0] = 4'hF. GOLDEN SCOPE: BYTE units only - a
  // byte unit is one column single with the datum byte replicated ({4{d}}, be = plane_en),
  // no shifter produce and no destination fetch. A WORD unit runs the produce/dword-fetch
  // machinery (the shifter mask advances per unit and its fetch is a read burst first) and
  // is refused here - that family is tb_pc9821_egc*'s; its two-word burst rides the same
  // g_single burst_fits + G_W2B port template the GRCG's TDW bursts pin above. The cadence
  // is the documented state flow: S_IDLE accept at acc, S_FEED/S_STEP_LO/S_STEP_HI, the
  // write's four-step plane loop in S_COMMIT (egc-serial), then the S_WR column walk, which
  // starts AT the unit's own column (no skip cycles below or above it); a single waits its own
  // cl_done before the next unit's produce starts.
  integer eg_next;
  task automatic gold_egc_wr(input integer acc, input [31:0] a, input [31:0] din,
                             input [3:0] be);
    integer lane, slot, iu, w0;
    reg [15:0] base, wa;
    reg [7:0] d0;
    begin
      decode_req(a);
      base = {dec_page, dec_off[14:2], 2'b00};
      slot = acc + 9;
      iu = 0;
      while (iu < 4) begin
        lane = -1;
        for (w0 = 3; w0 >= 0; w0 = w0 - 1)
          if (be[w0] && (w0 >= iu)) lane = w0;
        if (lane < 0) begin
          iu = 4;
        end else if (!lane[0] && (lane != 3) && be[lane] && be[lane+1] &&
                     (be != 4'b1110) && (be != 4'b0111)) begin
          fail("golden covers EGC byte units only: a word unit was formed");
          iu = lane + 2;
        end else begin
          // one byte unit = one column single, presented from the unit's own column
          d0 = din[8*lane +: 8];
          if (dec_hit) begin
            wa = base + lane[15:0];
            exp(slot, 1'b1, 4'hF, wa, {4{d0}});
            gold_set_word(dec_page, wa, {4{d0}}, 4'hF);
          end
          // after the single's cl_done the next unit's produce starts at once: the step
          // A_{i+1} - A_i is 10 (the parallel engine's was 10 - lane_i + lane_{i+1}: its walk
          // skipped a cycle per column below and above the lane, which the serial engine's
          // two-column walk does not, and its one-cycle commit is the serial loop's four).
          // NO PERIOD TERM HERE: the EGC's requests are the ENGINE's own produce
          // steps and pc9821_gvram_arb's GVRAM_PERIODS neither arms nor waits for them (the
          // capture has no matched control for the EGC rows), so the engine's own cadence is
          // unchanged.
          slot = slot + 10;
          iu = lane + 1;
        end
      end
      eg_next = slot - 3;
      free_at = eg_next;
    end
  endtask

  task automatic gold_egc_rd(input integer acc, input [31:0] a, input [3:0] be);
    integer c0, c1, c;
    reg [15:0] base;
    begin
      decode_req(a);
      c0 = 0; c1 = 3;
      for (c = 0; c < 4; c = c + 1) if (be[c]) begin c0 = c; c = 4; end
      for (c = 3; c >= 0; c = c - 1) if (be[c]) begin c1 = c; c = -1; end
      base = {dec_page, dec_off[14:2], 2'b00};
      if (dec_hit)
        for (c = c0; c <= c1; c = c + 1)
          exp(acc + 1 + (c - c0), 1'b0, 4'hF, base + c[15:0], 32'd0);
      eg_next = acc + 1 + (c1 - c0) + 2;
      free_at = eg_next;
    end
  endtask

  // ==========================================================================
  // THE DEVICE'S OWN PER-OPERATION PERIODS, READ FROM THE RTL
  // ==========================================================================
  // pc9821_gvram_arb's GVRAM_PERIODS prices a GVRAM access at the machine's own per-operation
  // TIME (the Xe10 capture docs/probes/GFX2.TXT / GFXB.TXT). A shape that costs MORE THAN ONE
  // client request per CPU access therefore schedules its later requests a period apart, and this
  // golden takes those two constants from the DUT rather than restating them, so it can never
  // drift from the model it characterizes.
  wire [15:0] GVRAM_RD_HOLD = dut.u_gvram_arb.GVRAM_RD_HOLD;
  wire [15:0] GVRAM_WR_HOLD = dut.u_gvram_arb.GVRAM_WR_HOLD;
  wire [15:0] GVRAM_GR_HOLD = dut.u_gvram_arb.GVRAM_GR_HOLD;

  // ==========================================================================
  // THE CHECKER: every cycle, either the next expected record lands (and every field
  // matches bit-for-bit) or the port must be idle (en=0, we=0).
  // ==========================================================================
  always @(posedge clk) begin
    if (!reset || p_en || p_we) begin
      checks = checks + 1;
      if (ev_i < ev_n && ev_cyc[ev_i] == cyc) begin
        // The byte enables and the datum are compared on a write only: pc9821_gvram_mem reads
        // them only under a_en && a_we (the arbiter presents them unconditionally since C7-dc;
        // tools/check_seq_equiv.py's gvram_mem lemma), so a read's are not part of the port.
        if (p_en !== 1'b1 || p_we !== ev_we[ev_i] || p_addr !== ev_addr[ev_i] ||
            (ev_we[ev_i] && (p_be !== ev_be[ev_i] || p_din !== ev_din[ev_i]))) begin
          $display("FAIL %0s: porta capture at cyc %0d: got en=%b we=%b be=%h addr=%h din=%h, want en=1 we=%b be=%h addr=%h din=%h",
                   ev_tag[ev_i], cyc, p_en, p_we, p_be, p_addr, p_din,
                   ev_we[ev_i], ev_be[ev_i], ev_addr[ev_i], ev_din[ev_i]);
          errors = errors + 1;
        end
        ev_i = ev_i + 1;
      end else begin
        if (p_en !== 1'b0 || p_we !== 1'b0) begin
          $display("FAIL %0s: port active an UNEXPECTED cycle (cyc %0d): en=%b we=%b be=%h addr=%h din=%h",
                   cur_tag, cyc, p_en, p_we, p_be, p_addr, p_din);
          errors = errors + 1;
        end
      end
    end
  end

  // ==========================================================================
  // STIMULUS DRIVERS
  // ==========================================================================
  task automatic wait_ready(input integer bound);
    integer g;
    begin
      g = 0;
      while (!cpu_ready && g < bound) begin
        @(negedge clk);
        g = g + 1;
      end
      if (!cpu_ready) fail("cpu_ready never came");
    end
  endtask

  reg [31:0] last_resp = 32'd0;
  task automatic drain_resp(input integer bound);
    integer g;
    begin
      g = 0;
      while (!cpu_resp_valid && g < bound) begin
        @(negedge clk);
        g = g + 1;
      end
      // sample the data in the response interval itself: the subsystem's cpu_dout mux
      // falls back to the map route's stub the cycle after the strobe
      last_resp = cpu_dout;
      @(negedge clk);
    end
  endtask

  // One CPU access: the golden stream is pushed first (from the documented schedule),
  // then the request is presented at this interval's negedge. The pacing is the golden's
  // OWN schedule: each generator publishes the interval its path is next free at
  // (free_at), and nothing is presented before it - so the accept interval is always the
  // presentation interval except in the interleaving section, which passes an explicit
  // accept for exactly the stall case it pins.
  integer free_at = 0;
  task automatic do_access(input [8*120-1:0] tag, input integer owner,
                           input [31:0] a, input [31:0] din, input [3:0] be,
                           input wr, input [7:0] mode, input [31:0] tile,
                           input integer gap, input integer force_acc);
    integer t0, acc;
    begin
      cur_tag = tag;
      while (cyc < free_at + 6) @(negedge clk);
      repeat (gap) @(negedge clk);
      // THE DEVICE MUST BE FREE, not only the golden's own schedule: pc9821_gvram_arb's
      // GVRAM_PERIODS prices a GVRAM access at the machine's own per-operation TIME, so the
      // arbiter takes this request at the first interval after the previous access's period has
      // run out. This golden's stream is scheduled BY THE ACCEPT (every generator's slot numbers
      // start at `acc`), which is why the wait is here: after it, the presentation interval IS the
      // accept interval, exactly as the generator's free_at contract already assumed.
      // ... and only for the owners this model PRICES: the EGC's backend requests are the engine's
      // own produce steps (the capture has no matched control for the EGC rows), so this seam
      // neither arms nor waits on the period for them - an EGC CPU access keeps the stimulus phase
      // its golden was transcribed with.
      if (owner != 2)
        while ((dut.u_gvram_arb.gstate != 3'd0) || dut.u_gvram_arb.m_mode ||
               (dut.u_gvram_arb.cs != 4'd0) ||
               (dut.u_gvram_arb.hold_left != 16'd0)) @(negedge clk);
      @(negedge clk);
      t0 = cyc;
      acc = (force_acc >= 0) ? force_acc : t0;
      case (owner)
        0: gold_plain(acc, a, din, be, wr);
        1: gold_grcg (acc, a, din, be, mode, tile);
        2: if (wr) gold_egc_wr(acc, a, din, be);
           else    gold_egc_rd(acc, a, be);
        default: gold_tcr(acc, a, be, mode);
      endcase
      cpu_addr = a;
      cpu_din = din;
      cpu_be = be;
      cpu_write = wr;
      cpu_line_read = 1'b0;
      cpu_valid = 1'b1;
      wait_ready(300);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
    end
  endtask

  // A store to a route that is NOT the GVRAM's: the array must stay silent. The map
  // route answers from the backend stub (mem_ready = 1), so the request completes.
  task automatic quiet_store(input [8*120-1:0] tag, input [31:0] a, input [31:0] din);
    begin
      cur_tag = tag;
      while (cyc < free_at + 6) @(negedge clk);
      while ((dut.u_gvram_arb.gstate != 3'd0) || dut.u_gvram_arb.m_mode ||
             (dut.u_gvram_arb.cs != 4'd0) ||
             (dut.u_gvram_arb.hold_left != 16'd0)) @(negedge clk);
      @(negedge clk);
      cpu_addr = a;
      cpu_din = din;
      cpu_be = 4'hF;
      cpu_write = 1;
      cpu_valid = 1;
      wait_ready(300);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
    end
  endtask

  task automatic grcg_mode_write(input [7:0] m);
    begin
      @(negedge clk);
      grcg_addr = 8'h7C;
      grcg_din = m;
      grcg_we = 1;
      @(negedge clk);
      grcg_we = 0;
    end
  endtask

  task automatic grcg_tile_write(input [7:0] b0, input [7:0] b1,
                                 input [7:0] b2, input [7:0] b3);
    begin
      @(negedge clk);
      grcg_addr = 8'h7E; grcg_din = b0; grcg_we = 1;
      @(negedge clk);
      grcg_din = b1;
      @(negedge clk);
      grcg_din = b2;
      @(negedge clk);
      grcg_din = b3;
      @(negedge clk);
      grcg_we = 0;
    end
  endtask

  // ==========================================================================
  // SECTIONS
  // ==========================================================================
  integer cov_plain_store = 0, cov_plain_read = 0, cov_grcg_tdw = 0,
          cov_grcg_rmw = 0, cov_grcg_dead = 0, cov_grcg_ff = 0, cov_tcr = 0,
          cov_egc_wr = 0, cov_egc_rd = 0, cov_alias = 0, cov_quiet = 0,
          cov_interleave = 0, cov_midreq = 0, cov_reset = 0, cov_stall = 0,
          cov_cap_tdw_rmw = 0, cov_merge_edge = 0, cov_win0_bound = 0, cov_z3124 = 0;

  integer t0, t1, acc2;

  initial begin
    for (gi = 0; gi < 262144; gi = gi + 1) gold[gi] = 8'h00;

    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;

    // ---- prime the loader exactly as tb_pc9821_memory_subsystem does ----
    ioctl_download = 1;
    @(negedge clk);
    ioctl_addr = 27'd0;
    ioctl_dout = 16'hBEEF;
    ioctl_wr = 1;
    @(negedge clk);
    ioctl_wr = 0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    ioctl_download = 0;
    repeat (3) @(posedge clk);
    if (!cpu_run) fail("the loader priming did not release cpu_run");
    @(negedge clk);

    // ================= SECTION 1: plain store/read shapes =================
    do_access("S1 plain dword", 0, 32'h000A_8004, 32'h44332211, 4'hF, 1, 0, 0, 14, -1);
    cov_plain_store = cov_plain_store + 1;
    do_access("S1 plain dword p1", 0, 32'h000B_0010, 32'h89ABCDEF, 4'hF, 1, 0, 0, 14, -1);
    do_access("S1 plain word lo", 0, 32'h000B_8020, 32'h0000BEEF, 4'b0011, 1, 0, 0, 14, -1);
    do_access("S1 plain word hi", 0, 32'h000A_8024, 32'hFEED0000, 4'b1100, 1, 0, 0, 14, -1);
    do_access("S1 plain byte 0", 0, 32'h000A_8100, 32'h000000AA, 4'b0001, 1, 0, 0, 14, -1);
    do_access("S1 plain byte 2", 0, 32'h000A_8104, 32'h00BB0000, 4'b0100, 1, 0, 0, 14, -1);
    do_access("S1 plain partial", 0, 32'h000B_8200, 32'h00CC00DD, 4'b0101, 1, 0, 0, 14, -1);
    do_access("S1 plain partial2", 0, 32'h000A_8208, 32'hEE001100, 4'b1010, 1, 0, 0, 14, -1);
    do_access("S1 plain inten", 0, 32'h000E_000C, 32'h13579BDF, 4'hF, 1, 0, 0, 14, -1);

    do_access("S1 plain dword read", 0, 32'h000A_8004, 32'h0, 4'hF, 0, 0, 0, 14, -1);
    drain_resp(60);
    cov_plain_read = cov_plain_read + 1;
    do_access("S1 plain word read", 0, 32'h000B_8020, 32'h0, 4'b0011, 0, 0, 0, 14, -1);
    drain_resp(60);

    // ================= SECTION 2: GRCG shapes =================
    grcg_tile_write(8'h11, 8'h22, 8'h33, 8'h44);   // tile_w = {44,33,22,11}
    grcg_mode_write(8'h80);                        // expand, TDW class, planes on
    do_access("S2 TDW pair lo", 1, 32'h000A_8400, 32'hFFFF_FFFF, 4'b0011, 1, 8'h80, 32'h44332211, 14, -1);
    cov_grcg_tdw = cov_grcg_tdw + 1;
    do_access("S2 TDW pair hi", 1, 32'h000A_8404, 32'hFFFF_FFFF, 4'b1100, 1, 8'h80, 32'h44332211, 14, -1);
    do_access("S2 TDW both", 1, 32'h000B_8410, 32'hFFFF_FFFF, 4'hF, 1, 8'h80, 32'h44332211, 14, -1);

    grcg_mode_write(8'hC0);                        // expand + RMW
    do_access("S2 RMW mixed", 1, 32'h000A_8500, 32'h0F5A3CC3, 4'hF, 1, 8'hC0, 32'h44332211, 14, -1);
    cov_grcg_rmw = cov_grcg_rmw + 1;
    do_access("S2 RMW ff skip", 1, 32'h000A_8508, 32'hFFFFFFFF, 4'hF, 1, 8'hC0, 32'h44332211, 14, -1);
    cov_grcg_ff = cov_grcg_ff + 1;
    do_access("S2 RMW dead", 1, 32'h000A_8510, 32'h00000000, 4'hF, 1, 8'hC0, 32'h44332211, 14, -1);
    cov_grcg_dead = cov_grcg_dead + 1;
    do_access("S2 RMW holed", 1, 32'h000B_8520, 32'h00FF005A, 4'b0101, 1, 8'hC0, 32'h44332211, 14, -1);
    do_access("S2 RMW 1p ff", 1, 32'h000A_8530, 32'h000000FF, 4'b0001, 1, 8'hC0, 32'h44332211, 14, -1);

    grcg_mode_write(8'h80);                        // expand + TCR class
    do_access("S2 TCR read", 3, 32'h000A_8500, 32'h0, 4'b0110, 0, 8'h80, 0, 14, -1);
    drain_resp(80);
    cov_tcr = cov_tcr + 1;
    grcg_mode_write(8'h00);

    // ================= SECTION 3: EGC shapes =================
    // WS_CPU (OPE 0x0000) BYTE units are pure column writes (no shifter produce, no
    // destination fetch); word units run the produce/dword fetch machinery, which is
    // tb_pc9821_egc*'s territory (see the blind spot). The two-word burst PORT template
    // (the g_single burst_fits arm + the G_W2B tail) is the same RTL the GRCG's TDW
    // bursts exercise above.
    egc_enable = 1;
    egc_ope = 16'h0000;                            // WS_CPU
    egc_mask = 16'hFFFF;
    egc_access = 16'hFFF0;                         // plane_en = 4'hF
    egc_sft = 16'h0000;
    egc_leng = 16'h0000;
    @(negedge clk);
    egc_shift_we = 1;                              // arm the shifter at zero (srcmask = FFFF)
    @(negedge clk);
    egc_shift_we = 0;
    repeat (2) @(negedge clk);

    do_access("S3 EGC byte lo", 2, 32'h000A_8600, 32'h000000A5, 4'b0001, 1, 0, 0, 14, -1);
    cov_egc_wr = cov_egc_wr + 1;
    do_access("S3 EGC byte hi", 2, 32'h000B_8604, 32'h005A0000, 4'b0100, 1, 0, 0, 14, -1);
    do_access("S3 EGC holed pair", 2, 32'h000A_8608, 32'h00CC00DD, 4'b0101, 1, 0, 0, 14, -1);
    cov_egc_wr = cov_egc_wr + 1;
    do_access("S3 EGC odd pair", 2, 32'h000A_8610, 32'h00EE0033, 4'b0110, 1, 0, 0, 14, -1);
    repeat (14) @(negedge clk);

    egc_ope = 16'h2000;                            // COMPAREREAD
    do_access("S3 EGC read dword", 2, 32'h000A_8600, 32'h0, 4'hF, 0, 0, 0, 14, -1);
    drain_resp(120);
    cov_egc_rd = cov_egc_rd + 1;
    do_access("S3 EGC read word", 2, 32'h000B_8604, 32'h0, 4'b0011, 0, 0, 0, 14, -1);
    drain_resp(120);
    egc_enable = 0;
    repeat (8) @(negedge clk);

    // ================= SECTION 4: the device-alias decode =================
    win0_sel = 8'h0A;
    do_access("S4 win0 A8", 0, 32'h0008_0004, 32'h01020304, 4'hF, 1, 0, 0, 14, -1);
    cov_alias = cov_alias + 1;
    win0_sel = 8'h0B;
    do_access("S4 win0 B0", 0, 32'h0008_0010, 32'h05060708, 4'hF, 1, 0, 0, 14, -1);
    cov_alias = cov_alias + 1;
    win0_sel = 8'h08;
    do_access("S4 mirror FA8", 0, 32'h00FA_8020, 32'h0A0B0C0D, 4'hF, 1, 0, 0, 14, -1);
    cov_alias = cov_alias + 1;
    do_access("S4 inten E0", 0, 32'h000E_0040, 32'h10203040, 4'hF, 1, 0, 0, 14, -1);

    quiet_store("S4 quiet pegc high", 32'hFFF0_8020, 32'h55667788);
    cov_quiet = cov_quiet + 1;
    ems_state = 2'd1;
    quiet_store("S4 quiet ems shaded", 32'h000B_0080, 32'h99AABBCC);
    ems_state = 2'd0;
    cov_quiet = cov_quiet + 1;
    quiet_store("S4 quiet sys16m hole", 32'h00F8_0020, 32'h12345678);
    cov_quiet = cov_quiet + 1;
    quiet_store("S4 quiet plain RAM", 32'h0010_0020, 32'hDEADBEEF);
    cov_quiet = cov_quiet + 1;

    // ================= SECTION 5: interleavings =================
    // back-to-back stores: the second is presented while the first runs, so its accept is the
    // first interval the arbiter will TAKE it in. Two floors bound that interval: the plain
    // client is back in C_IDLE at T+6 (a dword walk from accept T: done at T+5, C_IDLE at T+6),
    // and the device's own per-operation period - the machine's 0.1420 us plain-store time
    // (docs/probes/GFXB.TXT), converted from SYS_CLOCK_HZ - has to have run out. The period is
    // the binding one, which is the whole point of the fix: the second store's accept is the
    // first interval after the FIRST store's period, and this file reads that period straight
    // from the RTL's own GVRAM_PERIODS constant rather than restating it.
    cur_tag = "S5 back-to-back";
    while (cyc < free_at + 6) @(negedge clk);
    @(negedge clk);
    t0 = cyc;
    gold_plain(t0, 32'h000A_8800, 32'h21436587, 4'hF, 1);
    cpu_addr = 32'h000A_8800; cpu_din = 32'h21436587; cpu_be = 4'hF;
    cpu_write = 1; cpu_valid = 1;
    wait_ready(300);
    @(negedge clk);
    t1 = cyc;
    acc2 = t0 + ((6 > (dut.u_gvram_arb.GVRAM_WR_HOLD + 0)) ? 6 : (dut.u_gvram_arb.GVRAM_WR_HOLD + 0));
    gold_plain(acc2, 32'h000A_8808, 32'h77665544, 4'b0011, 1);
    cpu_addr = 32'h000A_8808; cpu_din = 32'h77665544; cpu_be = 4'b0011;
    cpu_write = 1; cpu_valid = 1;
    wait_ready(300);
    @(negedge clk);
    cpu_valid = 0;
    cpu_write = 0;
    cov_interleave = cov_interleave + 1;

    // read-after-write: the same word and the adjacent word
    do_access("S5 raw seed", 0, 32'h000A_8810, 32'h89ABCDEF, 4'hF, 1, 0, 0, 14, -1);
    do_access("S5 raw same", 0, 32'h000A_8810, 32'h0, 4'hF, 0, 0, 0, 14, -1);
    drain_resp(60);
    if (last_resp !== 32'h89ABCDEF) begin
      $display("FAIL RAW same-word read: got %08x want 89abcdef (cyc %0d)", last_resp, cyc);
      errors = errors + 1;
    end
    cov_interleave = cov_interleave + 1;
    do_access("S5 raw adjacent", 0, 32'h000A_8814, 32'h0, 4'b0011, 0, 0, 0, 14, -1);
    drain_resp(60);

    // scanout line ticks DURING a walk: port B fetches while port A walks
    scan_enable = 1;
    scan_line_base = 15'h0010;
    scan_line_tick = 1;
    do_access("S5 scanout interleave", 0, 32'h000A_8820, 32'hCAFEBABE, 4'hF, 1, 0, 0, 14, -1);
    scan_line_tick = 0;
    repeat (3) @(negedge clk);
    scan_enable = 0;
    cov_interleave = cov_interleave + 1;

    // an access-page change between requests moves the addressed page
    gvram_access_page = 1;
    do_access("S5 page flip", 0, 32'h000A_8830, 32'h0F1E2D3C, 4'hF, 1, 0, 0, 14, -1);
    gvram_access_page = 0;

    // ================= SECTION 6: mid-request config changes =================
    grcg_tile_write(8'h55, 8'h66, 8'h77, 8'h88);   // tile_w = {88,77,66,55}
    grcg_mode_write(8'hC0);
    cur_tag = "S6 mid-walk mode write";
    while (cyc < free_at + 6) @(negedge clk);
    while ((dut.u_gvram_arb.gstate != 3'd0) || dut.u_gvram_arb.m_mode ||
           (dut.u_gvram_arb.cs != 4'd0) ||
           (dut.u_gvram_arb.hold_left != 16'd0)) @(negedge clk);
    repeat (2) @(negedge clk);
    @(negedge clk);
    t0 = cyc;
    gold_grcg(t0, 32'h000A_8900, 32'h0F5A3CC3, 4'hF, 8'hC0, 32'h88776655);
    cpu_addr = 32'h000A_8900; cpu_din = 32'h0F5A3CC3; cpu_be = 4'hF;
    cpu_write = 1; cpu_valid = 1;
    wait_ready(300);
    @(negedge clk);
    cpu_valid = 0;
    cpu_write = 0;
    // two clk_sys into the walk the guest rewrites the mode and tile registers; the
    // walk's remaining captures must be unmoved (the GRCG holds, the arb latches)
    grcg_addr = 8'h7C; grcg_din = 8'hC0; grcg_we = 1;
    @(negedge clk);
    grcg_addr = 8'h7E; grcg_din = 8'h99;
    @(negedge clk);
    grcg_we = 0;
    repeat (4) @(negedge clk);
    cov_midreq = cov_midreq + 1;
    grcg_mode_write(8'h00);
    grcg_tile_write(8'h11, 8'h22, 8'h33, 8'h44);

    // decode config changes between requests
    win0_sel = 8'h0A;
    do_access("S6 win0 A8 again", 0, 32'h0008_0040, 32'h7F000001, 4'hF, 1, 0, 0, 14, -1);
    win0_sel = 8'h0E;
    do_access("S6 win0 E0", 0, 32'h0008_0044, 32'h7F000002, 4'hF, 1, 0, 0, 14, -1);
    win0_sel = 8'h08;
    sys16m_en = 0;
    do_access("S6 sys16m off", 0, 32'h000A_8950, 32'h7F000003, 4'hF, 1, 0, 0, 14, -1);
    sys16m_en = 1;
    ems_state = 2'd2;
    quiet_store("S6 quiet ems unmapped", 32'h000B_0090, 32'h7F000004);
    ems_state = 2'd0;
    cov_midreq = cov_midreq + 1;

    // ================= SECTION 7: reset mid-walk =================
    cur_tag = "S7 reset mid-walk";
    while (cyc < free_at + 6) @(negedge clk);
    @(negedge clk);
    t0 = cyc;
    gold_plain(t0, 32'h000A_8A00, 32'h12344321, 4'hF, 1);
    cpu_addr = 32'h000A_8A00; cpu_din = 32'h12344321; cpu_be = 4'hF;
    cpu_write = 1; cpu_valid = 1;
    wait_ready(300);
    @(negedge clk);
    cpu_valid = 0;
    cpu_write = 0;
    repeat (1) @(negedge clk);
    reset = 1;
    truncate_after(cyc);   // captures at this interval's edge still commit; later ones die
    @(negedge clk);
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (2) @(negedge clk);
    do_access("S7 post-reset store", 0, 32'h000A_8A10, 32'h0BADF00D, 4'hF, 1, 0, 0, 14, -1);
    cov_reset = cov_reset + 1;

    // ================= SECTION 8: cpu_run stalls =================
    cur_tag = "S8 cpu_run stall";
    while (cyc < free_at + 6) @(negedge clk);
    while ((dut.u_gvram_arb.gstate != 3'd0) || dut.u_gvram_arb.m_mode ||
           (dut.u_gvram_arb.cs != 4'd0) ||
           (dut.u_gvram_arb.hold_left != 16'd0)) @(negedge clk);
    repeat (2) @(negedge clk);
    @(negedge clk);
    t0 = cyc;
    gold_plain(t0, 32'h000A_8B00, 32'hFEEDFACE, 4'hF, 1);
    cpu_addr = 32'h000A_8B00; cpu_din = 32'hFEEDFACE; cpu_be = 4'hF;
    cpu_write = 1; cpu_valid = 1;
    wait_ready(300);
    @(negedge clk);
    cpu_valid = 0;
    cpu_write = 0;
    repeat (1) @(negedge clk);
    ioctl_download = 1;
    // cpu_run is the loader's REGISTER (docs/timing.md, the download gate): it drops one
    // clk_sys after the download rises, at the loader's edge, and the gvram group resets with it.
    // So the stall edge is the NEXT interval's: this interval's captures still commit.
    @(negedge clk);
    truncate_after(cyc);
    @(negedge clk);
    ioctl_download = 0;
    repeat (3) @(negedge clk);
    if (!cpu_run) fail("cpu_run did not return after the download pulse");
    do_access("S8 post-stall store", 0, 32'h000A_8B10, 32'h55AA33CC, 4'hF, 1, 0, 0, 14, -1);
    cov_stall = cov_stall + 1;

    // ================= SECTION 9: the analytically-proven corners, now driven =================
    // These four classes were proved bit-exact on paper; each had no
    // stimulus, and an un-driven proof is silent forever. Each is now pinned end to end
    // (the golden is the same independent decode/schedule as everywhere else, so a
    // regression in any class is a stream mismatch).
    // ---- 9a: cap_tdw && rmw - the 0xFF pair burst whose UNCOVERED lanes carry the ----
    // divergent zero-flags (din bytes 2/3 are 0x00 -> cpu_din_datum0 = 4'b1100 where the
    // old cap_tdw override forced 4'b0000). mode 0xC0 is RMW (mode[6]=1) and be=0011 with
    // an 0xFF datum is the whole-pair read-skip, so the GRCG classifies it as the
    // two-word burst whose merge reduces to the tile (the F5 class). The covered bytes'
    // flags agree and the uncovered bytes are masked by cpu_be = 0 - exactly the step-3/5
    // bypass proof. The arbiter's own F5 assertion must stay silent (cl_wdata reads the
    // 0xFFFFFFFF override here).
    grcg_tile_write(8'h11, 8'h22, 8'h33, 8'h44);
    grcg_mode_write(8'hC0);
    do_access("S9 cap_tdw rmw pair", 1, 32'h000A_8C00, 32'h0000_FFFF, 4'b0011, 1, 8'hC0, 32'h44332211, 0, -1);
    cov_cap_tdw_rmw = cov_cap_tdw_rmw + 1;

    // ---- 9b: the merge-flag boundary values 0x01/0xFE in one four-class walk ----
    // lane 0 = 0x00 (dead: no access), lane 1 = 0x01 and lane 2 = 0xFE (the two
    // mergeable EDGE values - the read+merge-write path's innermost members), lane 3 =
    // 0xFF (write-only read-skip). A flag off-by-one at either edge flips a lane's class
    // and the stream.
    do_access("S9 merge edge walk", 1, 32'h000B_8C10, 32'hFFFE_0100, 4'hF, 1, 8'hC0, 32'h44332211, 0, -1);
    cov_merge_edge = cov_merge_edge + 1;
    grcg_mode_write(8'h00);

    // ---- 9c: the win0_in_window boundaries, each with the 0x461 sel that makes the ----
    // corner SHARP (a membership regression at that edge turns silence into writes or a
    // write into silence): 0x7FFFF @ 0x09 is below the window (regression -> a d=0xAFFFF
    // hit), 0x80000 @ 0x0B is the inclusive low edge (a hit at d=0xB0000; regression ->
    // silence), 0x9FFFF @ 0x09 is the inclusive high edge (a hit at d=0xAFFFF, the top of
    // plane B's window; regression -> silence), 0xA0000 @ 0x0B is above it (regression ->
    // a d=0xB0000 hit). 0x0A itself is no plane page (the window's RAM, DMAROUTE-XE10 W1), and
    // 0x09/0x0B are values the iobus never presents (it masks bit 0) but the map decodes.
    win0_sel = 8'h09;
    do_access("S9 win0 7FFFF", 0, 32'h0007_FFFF, 32'h13579BDF, 4'hF, 1, 0, 0, 0, -1);
    cov_win0_bound = cov_win0_bound + 1;
    win0_sel = 8'h0B;
    do_access("S9 win0 80000", 0, 32'h0008_0000, 32'h2468ACE0, 4'hF, 1, 0, 0, 0, -1);
    cov_win0_bound = cov_win0_bound + 1;
    win0_sel = 8'h09;
    do_access("S9 win0 9FFFF", 0, 32'h0009_FFFF, 32'h0F1E2D3C, 4'hF, 1, 0, 0, 0, -1);
    cov_win0_bound = cov_win0_bound + 1;
    win0_sel = 8'h0B;
    do_access("S9 win0 A0000", 0, 32'h000A_0000, 32'h77665544, 4'hF, 1, 0, 0, 0, -1);
    cov_win0_bound = cov_win0_bound + 1;

    // ---- 9d: the z3124 corner of the factored eff_top_zero (the 0xAB08_0000 class) ----
    // bits[23:20]=0 (z2320=1) and bits[19:17]=3'b100 (the window's slice) with
    // bits[31:24]=0xAB - the exact input where dropping the z3124 term from
    // `z2320 && (peg_high || z3124)` wrongly raises eff_top_zero and, at win0_sel 0x0B,
    // would translate this store into a d=0xB0000 plane-window write. Correct behaviour
    // is silence (the raw arm's top 12 bits are not zero).
    do_access("S9 z3124 corner", 0, 32'hAB08_0000, 32'hDEADBEEF, 4'hF, 1, 0, 0, 0, -1);
    cov_z3124 = cov_z3124 + 1;
    win0_sel = 8'h08;

    // ================= END =================
    repeat (8) @(posedge clk);
    if (ev_i != ev_n) begin
      $display("FAIL %0d golden captures never arrived (first wanted at cyc %0d, now %0d)",
               ev_n - ev_i, ev_cyc[ev_i], cyc);
      errors = errors + 1;
    end

    // ---- the named coverage guards ----
    if (cov_plain_store == 0) fail("coverage: plain stores never exercised");
    if (cov_plain_read  == 0) fail("coverage: plain reads never exercised");
    if (cov_grcg_tdw    == 0) fail("coverage: GRCG TDW bursts never exercised");
    if (cov_grcg_rmw    == 0) fail("coverage: GRCG RMW mixed never exercised");
    if (cov_grcg_ff     == 0) fail("coverage: GRCG 0xFF read-skip never exercised");
    if (cov_grcg_dead   == 0) fail("coverage: GRCG 0x00 dead lane never exercised");
    if (cov_tcr         == 0) fail("coverage: GRCG TCR read never exercised");
    if (cov_egc_wr      == 0) fail("coverage: EGC stores never exercised");
    if (cov_egc_rd      == 0) fail("coverage: EGC reads never exercised");
    if (cov_alias       == 0) fail("coverage: device aliases never exercised");
    if (cov_quiet       == 0) fail("coverage: quiet decodes never exercised");
    if (cov_interleave  == 0) fail("coverage: interleavings never exercised");
    if (cov_midreq      == 0) fail("coverage: mid-request config changes never exercised");
    if (cov_reset       == 0) fail("coverage: reset never exercised");
    if (cov_stall       == 0) fail("coverage: cpu_run stalls never exercised");
    if (cov_cap_tdw_rmw == 0) fail("coverage: cap_tdw && rmw pair burst never exercised");
    if (cov_merge_edge  == 0) fail("coverage: merge-flag edge values 0x01/0xFE never exercised");
    if (cov_win0_bound  < 4) fail("coverage: win0 boundary addresses (4) not all exercised");
    if (cov_z3124       == 0) fail("coverage: the z3124 corner never exercised");
    $display("corner guards: cap_tdw_rmw=%0d merge_edge=%0d win0_bound=%0d z3124=%0d",
             cov_cap_tdw_rmw, cov_merge_edge, cov_win0_bound, cov_z3124);

    // ==== VERDICT ====
    // $fatal, not a bare $display of the failure: Verilator's $finish returns from
    // the process with status 0, so a failing run has to raise the exit code itself.
    if (errors == 0) begin
      $display("gvram_porta_equiv: %0d checks, %0d captures pinned", checks, ev_n);
      $display("TB_PC9821_GVRAM_PORTA_EQUIV: PASS");
      $finish;
    end
    else
      $fatal(1, "FAIL tb_pc9821_gvram_porta_equiv: %0d errors (%0d checks)", errors, checks);
  end

endmodule

`default_nettype wire

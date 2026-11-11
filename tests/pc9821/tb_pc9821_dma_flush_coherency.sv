`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DMA_FLUSH_COHERENCY: a floppy sector the real FDC and uPD71071 DMA write into a buffer the CPU has already cached is visible on the CPU's next read - every bus-master byte the backend ACCEPTS snoops its line in both L1s (the 486's EADS#, one invalidate per accepted write), and the re-fetch returns the sector's own bytes where an unsnooped read returns the stale cached dword, with NO whole-L1 cache_flush walk raised on the DMA path; a differential replays a scenario suite (partial-line, multi-set/way, interleaved, wrap-around, back-to-back, wait-state) and six seeded fuzz sequences against the pre-T24 whole-L1 walk and requires every CPU read of a DMA-written address byte-identical, checking every read against a media-seeded oracle, and the tied-off, one-cycle-delayed, wrong-address and request-gated snoop mutants are each killed. A real 486 snoops EADS# per external write and software does not flush after a floppy DMA, so without the snoop the disk buffer is stale." ;;
//
// WHY THIS EXISTS. The DMA writes SDRAM behind the CPU's back
// and nothing invalidated the L1: the only cache_flush triggers were the iobus's
// mapping changes and 0x043F=0xA0, and pc9821_system tied the z486's snoop port
// off (.snoop_addr(32'd0), .snoop_valid(1'b0) - "no DMA snoop on this platform").
// Software does not flush after a floppy DMA, so a disk buffer the CPU had read or
// executed came back stale. The first fix requested a whole-L1 cache_flush at each
// DMA/FDC completion; this bench now pins the form that replaced it (T24): the
// top level drives z486's existing external snoop from the uPD71071's accepted
// write, so EVERY external write invalidates its line - the machine's EADS# - and
// the CPU is held for no walk. The bench drives the REAL chain end to end:
//   * the TC end - a count-exhausted transfer, where the pre-T24 form's flush
//     keyed on pc9821_dmac's memory-side terminal count (mem_tc);
//   * the EOT end - the FDC's command-result drain, for a command that ends
//     without a terminal count (the DMA count is left unexhausted, so mem_tc
//     never fires for it). The bench PROVES that case ran without a terminal
//     count (the DMA status nibble stays clear) and that the snoop covered it
//     anyway, because the snoop is per WRITE and needs no completion event.
//
// THE SEAM, stated so nobody over-reads this: the transfer runs through the real
// pc9821_iobus (real FDC, real uPD71071, real port choreography) and the CPU side
// is the real z486 `memory` with both L1s against sdram_backend_model at real
// sdram.v timing. The DMA's bus-master port is taken at its ACCEPT into the same
// backend storage the CPU reads - the shape an EGC/GRCG hardware writer has in
// tb_pc9821_cpu_vram_coherency - because what is under test is the coherency
// (cached line vs external write), not the SDRAM schedule; the DMA's route to the
// backend is pc9821_memory_subsystem's own story (tb_pc9821_memory_subsystem).
// This bench drives u_mem's snoop with the SAME expression pc9821_system uses
// (dma_mem_req && dma_mem_we && dma_mem_ready), so it pins the seam's contract.
//
// FAIL-FIRST: with the snoop tied off (the planted mutant's form) nothing
// invalidates the cached line, so this bench FAILS at "the CPU's next read" with
// the stale cached dword (0xA5A51234 where the sector's bytes are), and the
// invalidate-count check below then names the missing snoop.

`default_nettype none

module tb_pc9821_dma_flush_coherency;
  reg clk = 0;
  always #5 clk = ~clk;   // 100 MHz, the same clk_sys the fit uses
  reg reset = 1;

  // ==== the CPU-side port interface (the iobus's, as tb_pc9821_fdc_2dd_bank drives it) ====
  reg  [31:0] cpu_addr = 0, cpu_din = 0;
  reg  [3:0]  cpu_be = 0;
  reg         cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;

  // ==== the device fabric (no device is under test through it) ====
  reg  [7:0]  debug_status = 8'hA5;
  wire        device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire  [7:0] device_io_din;
  reg   [7:0] device_io_dout = 8'hC3;
  reg         device_rd_wait = 1'b0;
  reg         device_rd_hold = 1'b0;
  reg         device_wr_wait = 1'b0;

  // ==== the strap inputs and system-port outputs (.* needs every name) ====
  reg  [3:0]  bios_set = 4'd0;
  reg         gdc_clock_5m = 1'b0;
  reg  msw_hold = 1'b0;        // port 0x31 bit 4 at the measured machine's memory-switch init (0xF3)
  reg  text_lines_20 = 1'b0;   // port 0x31 bit 3 at the measured 25 lines (0xF3)
  reg  [1:0] floppy_mode = 2'd0;   // Auto (1M), 0x861E = 0xF7: the Floppy mode default
  wire [23:0] setup_cfg;       // the OSD configuration pc9821_cg is built from (unread here)
  reg         triple_fault_reset = 1'b0;
  reg         cal_cdat = 0;
  reg  [6:0]  cfg_ram_mib = 7'd0;
  reg         cfg_seed_en = 1'b0;
  wire        sdip_seed_pulse;
  reg         egc_gate = 1'b0;
  reg  [10:0] gdc_ff2_state = 11'd0;
  reg  [24:0] ps2_mouse = 25'd0;
  wire [3:0]  top_bank;
  wire [1:0]  ems_state;
  wire        sound_extend, beep_mute;
  wire [1:0]  beep_vol;
  wire        fdc_irq;
  wire        fdc_irq10;
  wire        mouse_irq;
  wire [7:0]  win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire        sys16m_en, ide_rom_enable, top_shadow_en, bios_ram_gate;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  wire        ide_ram_gate;
  wire        a20_enable, cpu_reset_req;
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire  [7:0] post_code;
  wire        post_write;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;
  wire  [3:0] dbg_gate;
  wire  [7:0] dbg_itf_stage;
  wire [15:0] dbg_artic_hi, dbg_last_io_addr;
  wire  [7:0] dbg_last_io_data;
  wire        dbg_last_io_rd, dbg_last_io_wr;
  wire        dbg_last_io_stb;
  wire  [7:0] dbg_fdc_state;
  wire  [7:0] dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;

  // ==== the core side of the native flush: the REAL z486 `memory` below ====
  wire cache_flush_req;
  wire crt31k;   // 0x09A8 bit 0 (pc9821_iobus), named so .* binds it
  wire cache_flush_busy;
  wire cache_flush_done;

  // ==== the floppy media seam (pc9821_fdd_media's side), modelled below ====
  wire [3:0]  fdd_present;
  wire        fdd_req, fdd_req_hdr, fdd_adv;
  wire [1:0]  fdd_unit;
  wire  [7:0] fdd_c, fdd_h, fdd_r, fdd_n, fdd_idx;
  wire [7:0]  fdd_tc;   // pc9821_iobus's physical-track pair (pc9821_fdc media_tc/media_hd)
  wire        fdd_hd;
  wire        fdd_mf;
  wire        fdd_2hd;   // pc9821_iobus's media-mode pair (pc9821_fdc media_2hd/media_rpm)
  wire        fdd_rpm;
  wire        fdd_ready, fdd_rdy, fdd_hdrv, fdd_err;
  wire  [7:0] fdd_dout, fdd_hr, fdd_hn, fdd_hs;

  // ==== the uPD71071's bus-master memory port, taken at its accept below ====
  wire [31:0] dma_mem_addr, dma_mem_din;
  wire [31:0] dma_mem_addr_nx;   // the address dma_mem_addr loads next, and its load cycle (unused here)
  wire        dma_mem_load;
  wire  [3:0] dma_mem_be;
  wire        dma_mem_req, dma_mem_we;
  reg         dma_mem_ready = 1'b0;
  reg  [31:0] dma_mem_dout = 32'd0;
  reg         dma_mem_resp_valid = 1'b0;
  // The DMA-side snoop the DUT's uPD71071 write drives: the SAME expression
  // pc9821_system feeds z486's external invalidate (dma_mem_req && dma_mem_we &&
  // dma_mem_ready). The planted mutant ties this to 1'b0.
  wire        dma_snoop_valid = dma_mem_req && dma_mem_we && dma_mem_ready;

  // ==== THE T24 DIFFERENTIAL SEAM ====
  // `diff_old` selects the coherency FORM under test, with the rest of the machine
  // unchanged:
  //   * 0 = the T24 form: z486's external invalidate driven per accepted bus-master
  //     write (dma_snoop_line below), exactly pc9821_system.
  //   * 1 = the pre-T24 REFERENCE: no snoop, and the whole-L1 cache_flush walk
  //     launched at the DMA/FDC completion from iobus's own RETIRED triggers
  //     (dma_mem_tc, the uPD71071's memory-side terminal count; fdc_res_done, the
  //     FDC command result drain). Those are the exact two events the pre-T24
  //     flush_launch OR'd into flush_event, so this reconstructs the old behaviour
  //     from the real signals rather than re-deriving it.
  reg         diff_old = 1'b0;
  // A one-cycle-delayed copy of the snoop, so the "snoop delayed one cycle" mutant
  // has a differently-timed form to select (unused by the correct wiring).
  reg         dma_snoop_valid_q = 1'b0;
  always @(posedge clk) dma_snoop_valid_q <= dma_snoop_valid;
  // The snoop pulse actually presented to z486; the delayed-cycle mutant rewrites
  // this line to dma_snoop_valid_q.
  wire        dma_snoop_line = dma_snoop_valid;
  // The snoop address; the "wrong address" mutant offsets it so the written set is
  // missed (a real 486 presents the written physical address).
  wire [31:0] dma_snoop_addr = dma_mem_addr;
  // The DMA-side flush trigger the old form used, from iobus's retired wires.
  wire        dma_old_complete = dut.dma_mem_tc | dut.fdc_res_done;
  // The two coherency inputs the DUT sees: the per-write snoop in the new form, the
  // completion walk in the old one. The I/O fabric's own mapping flush (cache_flush_req)
  // feeds both.
  wire        snoop_dut = diff_old ? 1'b0 : dma_snoop_line;
  wire        flush_dut = cache_flush_req | (diff_old ? dma_old_complete : 1'b0);
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;
  wire [3:0]  fdd_chg = 4'd0;          // no media change: the FDC's ready-change tag
  wire        fdd_frame_tick = 1'b0;


  wire [1:0] d8_bank;   // 0x063C bits 1-0 (the 0xD8000 bank select); unused here


  // P5: the device-bus chip selects are pc9821_iobus outputs now (its own one decode).
  // This bench drives no device select of its own, so they are named here for the wildcard
  // instantiation and left unused.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  // The OSD's I/O timing field (pc9821_iobus io_timing_xe10): Fast, the default table.
  wire io_timing_xe10 = 1'b0;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

  // ==== DUT ====
  // The CPU side of the coherency: the real z486 `memory` (both L1s and the native
  // whole-L1 cache_flush walk), exactly the harness tb_pc9821_cpu_vram_coherency
  // drives, with the iobus's cache_flush_req/busy/done as its platform flush.
  reg  [31:0] mcpu_addr = 32'h0;
  reg  [31:0] mcpu_wdata = 32'h0;
  reg   [3:0] mcpu_be = 4'hF;
  reg         mcpu_write = 1'b0;
  reg         mcpu_is_vga = 1'b0;
  reg         mcpu_valid = 1'b0;
  wire        m_req_accepted, m_req_complete, m_read_complete;
  wire [31:0] m_rdata;

  // The I$ side of the same `memory`: an instruction fetch port, so the snoop's reach
  // into the instruction cache (the report's "both L1s") is exercised, not just
  // asserted by reading memory.sv.
  reg         if_valid = 1'b0;
  reg  [31:0] if_addr = 32'h0;
  wire        if_accepted, if_complete;
  wire [127:0] if_line;

  wire [31:2] m_addr;
  wire  [3:0] m_be;
  wire  [7:0] m_burst;
  wire [31:0] m_dout;
  wire [31:0] m_din;
  wire [127:0] m_line_din;
  wire        m_valid, m_write, m_io, m_inta, m_ready;
  wire        m_resp_valid, m_line_resp_valid, m_line_read;
  wire [31:0] mem_accepts, mem_beats;

  memory #(
      .PROTECT_UMA_ROM(0),
      .DCACHE_SET_BITS(6),          // the shipped size (z486_mister.sv DCACHE_SET_BITS)
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
      // L1 on, FPU present: z486 drives these from cache_off_req/x87_off_req, which pc9821_system ties low
      .cache_enable(1'b1), .x87_off(1'b0),
      .device_mmio_enable(1'b1), .device_mmio_base(32'h0200_0000),
      .ram_cache_top(32'hFFFF_FFFF), .win0_unmapped(1'b0),
      .dcache_req_valid(mcpu_valid),
      .dcache_req_phys_addr_raw(mcpu_addr),
      .dcache_req_preread_offset(mcpu_addr[11:0]),
      // The real paging unit drives this from the demand itself (paging_unit.sv:
      // `early_idx_drive || pretrans_present || req_mem_present || dcache_req_valid_r`),
      // so a demand always owns the preread over a VIPT probe. Tying it to 1'b0 made
      // the core's own invariant fire (`l1_cache.sv:589: L1 pipelined store accepted
      // without preread priority`) on ANY pipelined store, so this bench never ran
      // past its first store. Model the rule the stub can express: a presented
      // demand reserves the port.
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
      .icache_req_valid(if_valid), .icache_req_phys_addr_raw(if_addr),
      .icache_req_accepted(if_accepted), .icache_req_complete(if_complete),
      .icache_rdata(if_line),
      // The DMA-side snoop, the SAME expression pc9821_system drives z486 with:
      // the uPD71071's write, as the backend accepts it, invalidates its line.
      .snoop_addr(dma_snoop_addr), .snoop_valid(snoop_dut),
      .cache_flush(flush_dut), .cache_flush_busy(cache_flush_busy),
      .cache_flush_done(cache_flush_done),
      .addr(m_addr), .be(m_be), .burstcount(m_burst), .line_read(m_line_read),
      .din(m_din), .line_din(m_line_din), .dout(m_dout),
      .valid(m_valid), .ready(m_ready), .write(m_write), .io(m_io),
      .resp_valid(m_resp_valid), .line_resp_valid(m_line_resp_valid), .inta(m_inta)
  );

  // The backend, at real sdram.v timing (tb_pc9821_cpu_vram_coherency's binding).
  sdram_backend_model #(
      .ACCEPT_TO_RESP(2), .WRITE_BUSY(2), .LINE_RESP(0), .WORDS_LOG2(21)
  ) backend (
      .clk(clk), .reset(reset), .valid(m_valid), .ready(m_ready), .write(m_write),
      .addr({m_addr, 2'b00}), .din(m_dout), .din_hi(32'd0), .be(m_be), .burstcount(m_burst),
      .dout(m_din), .resp_valid(m_resp_valid),
      .line_dout(m_line_din), .line_resp_valid(m_line_resp_valid),
      .busy(), .accepts(mem_accepts), .beats(mem_beats)
  );

  // ==== STIMULUS ====
  localparam [15:0] P_MSR_2HD  = 16'h0090,
                    P_DATA_2HD = 16'h0092,
                    P_MSR_2DD  = 16'h00C8,
                    P_DATA_2DD = 16'h00CA,
                    P_STRAP    = 16'h00BE,
                    P_DMA_STAT = 16'h0011,
                    P_DMA_MASK = 16'h0015,
                    P_DMA_MODE = 16'h0017,
                    P_DMA_CLRFF= 16'h0019,
                    P_DMA_MASTER = 16'h001B;

  // The media model, tb_pc9821_fdc_2dd_bank's: one image in unit 0, a sector of
  // 128<<N bytes whose byte k is (R ^ k) - so a transferred sector is checkable
  // byte for byte against the command's own R.
  reg        m_xfer, m_hdrv, m_err;
  reg [15:0] m_ptr;
  reg  [7:0] m_last_r, m_last_c, m_last_n;
  reg [15:0] m_reqs;
  wire [15:0] m_secbytes = (m_last_n[7:4] != 4'd0) ? 16'd32768 : (16'd128 << m_last_n[3:0]);

  assign fdd_present = 4'b0001;      // one image, in unit 0
  assign fdd_ready = !m_xfer;
  assign fdd_rdy   = m_xfer;
  assign fdd_err   = m_err;
  assign fdd_hdrv  = m_hdrv;
  assign fdd_dout  = m_xfer ? (m_last_r ^ m_ptr[7:0]) : 8'h00;
  assign fdd_hr    = fdd_idx + 8'd1;
  assign fdd_hn    = 8'h3;
  assign fdd_hs    = 8'h2;

  always @(posedge clk) begin
    if (reset) begin
      m_xfer <= 1'b0; m_hdrv <= 1'b0; m_err <= 1'b0;
      m_ptr <= 16'd0; m_last_r <= 8'h00; m_last_c <= 8'h00; m_last_n <= 8'h00;
      m_reqs <= 16'd0;
    end else begin
      if (fdd_req) begin
        m_err  <= 1'b0;
        m_hdrv <= 1'b0;
        m_reqs <= m_reqs + 16'd1;
        if (fdd_req_hdr) m_hdrv <= 1'b1;
        else begin
          m_xfer   <= 1'b1;
          m_ptr    <= 16'd0;
          m_last_r <= fdd_r;
          m_last_c <= fdd_c;
          m_last_n <= fdd_n;
        end
      end
      if (m_xfer && fdd_adv) begin
        if (m_ptr + 16'd1 >= m_secbytes) m_xfer <= 1'b0;
        m_ptr <= m_ptr + 16'd1;
      end
    end
  end

  // The bus-master memory model: one byte per dma_mem_req, accepted when dma_mem_ready
  // is high, landing in the SAME backend storage the CPU reads - the external-writer
  // seam (see the header). The byte comes from the lane mem_be names, exactly
  // pc9821_dmac's own lane decode, so a wrong lane shows up. `dma_stall` holds ready
  // low (an SDRAM wait state): a request stays presented across the held cycles, which
  // is what separates an accept-gated snoop from a request-gated one.
  integer    dma_writes = 0;
  reg [3:0]  dma_bad_be = 4'h0;
  reg        dma_stall = 1'b0;

  // The coherency ORACLE: a byte copy of what the backend must hold, updated by the
  // DMA model's own accepted bytes (below) and by the CPU stores (wr_dword). A CPU
  // read that disagrees with it read a stale L1 line. The DMA side is seeded from the
  // media model, never from our cache RTL, so it is not circular.
  reg [7:0]  shadow [0:262143];

  wire [7:0] mem_lane_byte = (dma_mem_addr[1:0] == 2'd0) ? dma_mem_din[7:0]   :
                             (dma_mem_addr[1:0] == 2'd1) ? dma_mem_din[15:8]  :
                             (dma_mem_addr[1:0] == 2'd2) ? dma_mem_din[23:16] :
                                                           dma_mem_din[31:24];

  always @(posedge clk) begin
    dma_mem_ready <= !dma_stall;               // one wait state when dma_stall is held
    if (!reset && dma_mem_req && dma_mem_we && dma_mem_ready) begin
      // The hardware-writer seam: the byte lands in the backend's own storage.
      if (dma_mem_be[0]) backend.mem[dma_mem_addr[22:2]][7:0]   <= mem_lane_byte;
      if (dma_mem_be[1]) backend.mem[dma_mem_addr[22:2]][15:8]  <= mem_lane_byte;
      if (dma_mem_be[2]) backend.mem[dma_mem_addr[22:2]][23:16] <= mem_lane_byte;
      if (dma_mem_be[3]) backend.mem[dma_mem_addr[22:2]][31:24] <= mem_lane_byte;
      if (dma_mem_be !== (4'b0001 << dma_mem_addr[1:0])) dma_bad_be <= dma_bad_be | 4'h1;
      shadow[dma_mem_addr[17:0]] <= mem_lane_byte;
      dma_writes = dma_writes + 1;
    end
  end

  // ==== THE SNOOP TIMING CONTRACT (the mutants' killing ground) ====
  // A real 486 asserts EADS# WITH the external write's bus cycle, and the invalidate
  // must not run before the byte is committed (the report's point 1). So, in the T24
  // form: every accepted write carries a snoop in that same cycle, and no snoop is
  // presented while a request is up but NOT yet accepted (ready low). `snoop_dut` is
  // the exact signal z486 sees, so a tied-off, delayed, or request-gated snoop trips
  // one of these counters.
  integer snoop_missing_at_accept = 0;   // accepted writes with no snoop this cycle
  integer snoop_early_while_waiting = 0; // snoops while a request is presented, not accepted
  always @(posedge clk) begin
    if (!reset && !diff_old) begin
      if (dma_mem_req && dma_mem_we && dma_mem_ready && !snoop_dut)
        snoop_missing_at_accept = snoop_missing_at_accept + 1;
      if (dma_mem_req && dma_mem_we && !dma_mem_ready && snoop_dut)
        snoop_early_while_waiting = snoop_early_while_waiting + 1;
    end
  end

  // One byte port access through the iobus fabric: cpu_valid held until cpu_ready,
  // the byte on the addressed lane, the address in cpu_addr[15:2].
  reg [7:0] rd_val;
  task automatic port_wr(input [15:0] p, input [7:0] d);
    reg [1:0] lane;
    begin
      lane = p[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, p[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_din = {24'd0, d} << (lane * 8);
      cpu_write = 1;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  task automatic port_rd(input [15:0] p);
    reg [1:0] lane;
    begin
      lane = p[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, p[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_write = 0;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      #1 rd_val = cpu_dout[{lane, 3'b000} +: 8];
      @(negedge clk);
      cpu_valid = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  localparam integer WAIT_CAP = 20000;
  localparam integer W_IRQ11 = 0, W_IRQ10 = 1, W_DRQ = 2;
  integer cyc;

  task automatic wait_level(input integer which, output integer waited);
    integer reached;
    begin
      waited  = 0;
      reached = 0;
      while (!reached && (waited < WAIT_CAP)) begin
        case (which)
          W_IRQ11: reached = (dut.fdc_irq   === 1'b1);
          W_IRQ10: reached = (dut.fdc_irq10 === 1'b1);
          default: reached = (dut.fdc_drq   === 1'b1);
        endcase
        if (!reached) begin
          @(negedge clk);
          waited = waited + 1;
        end
      end
    end
  endtask

  // The uPD71071 programmed through its own window, tb_pc9821_fdc_2dd_bank's
  // dmac_arm (the firmware's own sequence: master clear, address halves, bank,
  // count halves, mode 0x04|ch = port-to-memory, unmask).
  task automatic dmac_arm(input [1:0] ch, input [23:0] addr, input [15:0] count);
    begin
      port_wr(P_DMA_MASTER, 8'h00);
      port_wr(P_DMA_CLRFF,  8'h00);
      port_wr(16'h0001 + {12'd0, ch, 2'b00}, addr[7:0]);
      port_wr(16'h0001 + {12'd0, ch, 2'b00}, addr[15:8]);
      port_wr(16'h0021 + {13'd0, ((ch - 2'd1) & 2'd3), 1'b0}, addr[23:16]);
      port_wr(16'h0003 + {12'd0, ch, 2'b00}, count[7:0]);
      port_wr(16'h0003 + {12'd0, ch, 2'b00}, count[15:8]);
      port_wr(P_DMA_MODE, {4'b0000, 2'b01, ch});   // din[3:2] = 01: port -> memory
      port_wr(P_DMA_MASK, {6'b000000, ch});        // din[2] = 0 clears that channel's mask
    end
  endtask

  // READ DATA with MF=0: {hd,us}, C, H, R, N, EOT, GPL, DTL (NP2kai FDC_ReadData).
  task automatic read_data_cmd(input [15:0] data_port, input [7:0] unit_head,
                               input [7:0] c, input [7:0] h, input [7:0] r,
                               input [7:0] n, input [7:0] eot);
    begin
      port_wr(data_port, 8'h06);
      port_wr(data_port, unit_head);
      port_wr(data_port, c);
      port_wr(data_port, h);
      port_wr(data_port, r);
      port_wr(data_port, n);
      port_wr(data_port, eot);
      port_wr(data_port, 8'h00);   // GPL
      port_wr(data_port, 8'h00);   // DTL
    end
  endtask

  // Drain the seven-byte result. The drain's LAST byte is the FDC-complete leg's
  // event (pc9821_fdc's res_done), so this task is part of the fix's own trigger
  // choreography, not just cleanup.
  task automatic drain_result(input [15:0] data_port);
    integer k;
    begin
      for (k = 0; k < 7; k = k + 1) port_rd(data_port);
    end
  endtask

  // One CPU request through the real z486 `memory` (tb_pc9821_cpu_vram_coherency's
  // task, renamed onto the mcpu_* side). A read completes on the response; a write
  // completes at the accept and is posted to the store queue.
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
      if (!m_req_accepted) $fatal(1, "TB_PC9821_DMA_FLUSH_COHERENCY: no accept for %08x", a);
      rdata = 32'h0;
      if (!wr) begin
        g = 0;
        while (!m_read_complete && g < 200000) begin @(negedge clk); g = g + 1; end
        // The bound is generous ON PURPOSE: post-fix the flush walk holds
        // cpu_ready low for its 136 cycles (z486's flush_block), so a read issued
        // behind a just-launched walk is slow but never lost.
        if (!m_read_complete) $fatal(1, "TB_PC9821_DMA_FLUSH_COHERENCY: no response for %08x", a);
        rdata = m_rdata;
      end
      @(negedge clk);
      mcpu_valid = 1'b0; mcpu_write = 1'b0;
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic wr_dword(input [31:0] a, input [31:0] d);
    reg [31:0] sink;
    begin
      mreq(a, 1'b1, 4'hF, d, sink);
      // The store is write-through: the oracle gets the bytes the CPU wrote.
      shadow[a[17:0]]        = d[7:0];
      shadow[a[17:0] + 1]    = d[15:8];
      shadow[a[17:0] + 2]    = d[23:16];
      shadow[a[17:0] + 3]    = d[31:24];
    end
  endtask

  task automatic rd_dword(input [31:0] a, output [31:0] d);
    begin mreq(a, 1'b0, 4'hF, 32'h0, d); end
  endtask

  // The oracle's dword at `a`, little-endian like the CPU's reads.
  function automatic [31:0] sh_dword(input [31:0] a);
    begin
      sh_dword = {shadow[a[17:0] + 3], shadow[a[17:0] + 2],
                  shadow[a[17:0] + 1], shadow[a[17:0]]};
    end
  endfunction

  // Is this address served from an L1 line? Read it, then read it again: a hit
  // makes no new backend accept; a miss always does.
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

  // Is the line resident BEFORE this read? probes_cached cannot answer that - its own
  // first read re-fills the line - so sample the backend accepts across ONE read: a
  // hit adds none, a miss's fill does. The pre-read settle is generous so a fill from
  // an earlier access is never counted here.
  task automatic line_resident(input [31:0] a, output resident);
    reg [31:0] sink;
    reg [31:0] acc_before;
    begin
      repeat (32) @(posedge clk);
      acc_before = mem_accepts;
      rd_dword(a, sink);
      repeat (8) @(posedge clk);
      resident = (mem_accepts == acc_before) ? 1'b1 : 1'b0;
    end
  endtask

  // The sector's expected dword at a transferred offset: media byte k is (R ^ k)
  // with R = 1 (the media model above), so byte k of the sector is 8'h01 ^ k[7:0].
  function automatic [31:0] media_dword(input [15:0] off);
    begin
      media_dword = {8'h01 ^ (off[7:0] + 8'd3), 8'h01 ^ (off[7:0] + 8'd2),
                     8'h01 ^ (off[7:0] + 8'd1), 8'h01 ^ (off[7:0] + 8'd0)};
    end
  endfunction

  // The invalidate record: how many accepted bus-master writes snooped the L1 (the
  // pulse z486 actually sees, `snoop_dut`), and how many whole-L1 walks (cache_flush)
  // the DMA path asked for - which must be NONE in the T24 form and exactly the
  // completion events in the old reference.
  integer snoop_pulses = 0;
  integer flush_pulses = 0;
  integer old_walks = 0;               // whole-L1 walks raised by the pre-T24 reference
  integer snoop_writes_at_first = -1;
  always @(posedge clk) begin
    if (!reset) begin
      if (snoop_dut) begin
        if (snoop_pulses == 0) snoop_writes_at_first = dma_writes;
        snoop_pulses = snoop_pulses + 1;
      end
      if (flush_dut) flush_pulses = flush_pulses + 1;
      if (diff_old && flush_dut) old_walks = old_walks + 1;
    end
  end

  task automatic clear_flush_record;
    begin
      snoop_pulses = 0;
      flush_pulses = 0;
      snoop_writes_at_first = -1;
      snoop_missing_at_accept = 0;
      snoop_early_while_waiting = 0;
    end
  endtask

// ==== CHECKS ====

  integer errors = 0;
  integer checks = 0;
  integer case1_snoops = 0, case2_snoops = 0;
  reg [31:0] rdv;
  reg        cached;

  task automatic chk_dword(input [31:0] got, input [31:0] want, input [8*120-1:0] tag);
    begin
      checks = checks + 1;
      if (got !== want) begin
        $display("FAIL %0s: got %08x, want %08x", tag, got, want);
        errors = errors + 1;
      end
    end
  endtask

// ==== T24 DIFFERENTIAL, SCENARIO COVERAGE AND FUZZ ====
//
// The differential runs the SAME scenario suite twice: once in the T24 form
// (diff_old=0, the per-write snoop) and once against the pre-T24 reference
// (diff_old=1, no snoop; the whole-L1 walk launched at the completion from iobus's
// retired dma_mem_tc / fdc_res_done). Every CPU read of a DMA-written address is
// checked against a byte ORACLE (seeded by the media model on each DMA accept and by
// the CPU stores) and RECORDED; at the end the two traces must be entry-for-entry
// identical. So the claim is not "the new form is right in one case" but "the new
// form never leaves a stale line the walk would have invalidated" over the suite.

  localparam integer TRACE_MAX = 16384;
  integer    cur_mode = 0;
  integer    trace_n  [0:1];
  reg [31:0] trace_a  [0:1][0:TRACE_MAX-1];
  reg [31:0] trace_v  [0:1][0:TRACE_MAX-1];
  reg [31:0] mid_probe[0:1];   // the interleaved mid-transfer read, per mode
  reg [7:0]  stat;

  // Read through the CPU, check it against the oracle, and record it for the
  // differential.
  task automatic chk_and_rec(input [31:0] a, input [8*120-1:0] tag);
    reg [31:0] got;
    begin
      rd_dword(a, got);
      chk_dword(got, sh_dword(a), tag);
      if (trace_n[cur_mode] < TRACE_MAX) begin
        trace_a[cur_mode][trace_n[cur_mode]] = a;
        trace_v[cur_mode][trace_n[cur_mode]] = got;
        trace_n[cur_mode] = trace_n[cur_mode] + 1;
      end else begin
        $display("FAIL differential: trace overflow at %08x", a);
        errors = errors + 1;
      end
    end
  endtask

  // Seed a byte pattern made of dwords through the CPU (so it lands in the L1 and the
  // oracle), read the whole range back so the L1 really holds it, and record those
  // reads. `v` is the seed byte, byte k of the pattern is (v ^ k).
  task automatic seed_cache(input [31:0] a, input integer n, input [7:0] v, input [8*120-1:0] tag);
    integer k;
    begin
      for (k = 0; k + 4 <= n; k = k + 4)
        wr_dword(a + k, {v ^ (k+3), v ^ (k+2), v ^ (k+1), v ^ (k+0)});
      chk_and_rec(a, tag);
    end
  endtask

  // One full READ DATA sector (N=0 => 128 bytes) on channel 3, then drain the result.
  task automatic xfer_sector(input [15:0] dport, input [23:0] start,
                             input [7:0] r, input [15:0] count, input [7:0] eot);
    begin
      dma_writes = 0;
      dma_bad_be = 4'h0;
      dmac_arm(2'd3, start, count);
      read_data_cmd(dport, 8'h00, 8'h00, 8'h00, r, 8'h00, eot);
      wait_level(W_IRQ10, cyc);
      if (cyc >= WAIT_CAP)
        $fatal(1, "TB_PC9821_DMA_FLUSH_COHERENCY: sector xfer at %06x never completed", start);
      port_rd(P_DMA_STAT); stat = rd_val;
      drain_result(dport);
      repeat (8) @(negedge clk);
    end
  endtask

  // One instruction fetch through the real z486 `memory`'s I$ port (the shape
  // tb_pc9821_l1_alias_fill's fetch task uses).
  task automatic ifetch(input [31:0] a, output [127:0] line);
    integer g;
    begin
      @(negedge clk);
      if_addr = a; if_valid = 1'b1;
      g = 0;
      while (!if_accepted && g < 20000) begin @(negedge clk); g = g + 1; end
      if (!if_accepted) $fatal(1, "TB_PC9821_DMA_FLUSH_COHERENCY: no fetch accept for %08x", a);
      @(negedge clk);
      if_valid = 1'b0;
      g = 0;
      while (!if_complete && g < 20000) begin @(negedge clk); g = g + 1; end
      if (!if_complete) $fatal(1, "TB_PC9821_DMA_FLUSH_COHERENCY: no fetch response for %08x", a);
      line = if_line;
      repeat (4) @(posedge clk);
    end
  endtask

  // Is the I$ line resident before this fetch? Same accept-counting idea as
  // line_resident.
  task automatic ifetch_resident(input [31:0] a, output resident);
    reg [127:0] ln;
    reg [31:0] acc_before;
    begin
      repeat (32) @(posedge clk);
      acc_before = mem_accepts;
      ifetch(a, ln);
      repeat (8) @(posedge clk);
      resident = (mem_accepts == acc_before) ? 1'b1 : 1'b0;
    end
  endtask

  // ---- the scenarios ----

  // S1: a PARTIAL-line write. The sector starts 4 bytes into a cached line, so the
  // first line keeps its low 4 bytes and takes media bytes on 4..15. A stale first
  // line returns the seeded dword at 0x4004; the oracle does not.
  task automatic sc_partial;
    begin
      seed_cache(32'h0000_4000, 32, 8'hC0, "S1 pre-cache the DMA line");
      xfer_sector(P_DATA_2DD, 24'h004004, 8'h55, 16'd127, 8'h01);
      chk_and_rec(32'h0000_4000, "S1 partial-line dword (seeded low bytes + media high)");
      chk_and_rec(32'h0000_4004, "S1 first written dword of the line");
      chk_and_rec(32'h0000_400C, "S1 last written dword of the line");
      chk_and_rec(32'h0000_4010, "S1 second line after the DMA");
      chk_and_rec(32'h0000_4070, "S1 last line of the sector");
    end
  endtask

  // S2: MULTIPLE lines, sets and ways. Four ways of set 0 (0x5000/0x5400/0x5800/0x5C00)
  // are cached, then a sector covers 0x5000..0x507F. The D$ snoop is SET-WIDE, so all
  // four ways must be gone; a tag-matched snoop would keep the three untouched ways.
  task automatic sc_sets;
    reg resident;
    begin
      seed_cache(32'h0000_5000, 16, 8'h11, "S2 pre-cache way0 of set0");
      seed_cache(32'h0000_5400, 16, 8'h22, "S2 pre-cache way1 of set0");
      seed_cache(32'h0000_5800, 16, 8'h33, "S2 pre-cache way2 of set0");
      seed_cache(32'h0000_5C00, 16, 8'h44, "S2 pre-cache way3 of set0");
      // Prove the residency probe itself can say "resident" before trusting it.
      line_resident(32'h0000_5400, resident);
      checks = checks + 1;
      if (!resident) begin
        $display("FAIL S2 setup: the residency probe says 00005400 was NOT cached after seeding - it cannot detect the eviction");
        errors = errors + 1;
      end
      xfer_sector(P_DATA_2DD, 24'h005000, 8'h77, 16'd127, 8'h01);
      // The D$ snoop is SET-WIDE: an untouched WAY of the written set must be gone.
      // Observe it BEFORE any read re-fills the line.
      line_resident(32'h0000_5400, resident);
      checks = checks + 1;
      if (resident) begin
        $display("FAIL S2: the untouched way 00005400 is still resident after a write to its set - the D$ snoop must clear the whole set");
        errors = errors + 1;
      end
      line_resident(32'h0000_5C00, resident);
      checks = checks + 1;
      if (resident) begin
        $display("FAIL S2: the untouched way 00005C00 is still resident after a write to its set - the D$ snoop must clear the whole set");
        errors = errors + 1;
      end
      chk_and_rec(32'h0000_5000, "S2 written way0 after the DMA");
      chk_and_rec(32'h0000_5400, "S2 untouched way1 value after the DMA");
      chk_and_rec(32'h0000_5800, "S2 untouched way2 value after the DMA");
      chk_and_rec(32'h0000_5C00, "S2 untouched way3 value after the DMA");
    end
  endtask

  // S3: a CPU read INTERLEAVED during the transfer. The line is cached, the transfer
  // starts, and after 16 accepted bytes the CPU reads the first dword. The T24 form
  // must return the media bytes (the write already invalidated the set); the pre-T24
  // reference (no invalidate until completion) returns the stale seeded line. That
  // divergence is the point of the form, and is recorded, not asserted away.
  task automatic sc_interleaved;
    integer g;
    begin
      seed_cache(32'h0000_7000, 16, 8'hE0, "S3 pre-cache the interleaved line");
      dma_writes = 0;
      clear_flush_record;
      dmac_arm(2'd3, 24'h007000, 16'd127);
      read_data_cmd(P_DATA_2DD, 8'h00, 8'h00, 8'h00, 8'h01, 8'h00, 8'h01);
      g = 0;
      while (dma_writes < 16 && g < WAIT_CAP) begin @(negedge clk); g = g + 1; end
      if (dma_writes < 16) $fatal(1, "S3: the transfer never reached 16 bytes");
      rd_dword(32'h0000_7000, mid_probe[cur_mode]);
      wait_level(W_IRQ10, cyc);
      if (cyc >= WAIT_CAP) $fatal(1, "S3: the READ DATA never completed");
      port_rd(P_DMA_STAT); stat = rd_val;
      drain_result(P_DATA_2DD);
      repeat (8) @(negedge clk);
      chk_and_rec(32'h0000_7000, "S3 post-DMA read of the interleaved line");
      chk_and_rec(32'h0000_7040, "S3 post-DMA read of a later line");
      // In the T24 form the mid-transfer read must equal the oracle at its address.
      if (cur_mode == 0) begin
        checks = checks + 1;
        if (mid_probe[0] !== sh_dword(32'h0000_7000)) begin
          $display("FAIL S3: the mid-transfer read got %08x, want the media bytes %08x - a stale line survived a write",
                   mid_probe[0], sh_dword(32'h0000_7000));
          errors = errors + 1;
        end
      end
    end
  endtask

  // S4: a WRAP-AROUND buffer. The sector starts at 0x00FFF0 and runs to 0x01006F, so it
  // crosses the 64 KiB boundary and wraps the cache set index (set 63 -> 0). Both ends
  // must be invalidated.
  task automatic sc_wrap;
    begin
      seed_cache(32'h0000_FFF0, 16, 8'hA0, "S4 pre-cache the line at 0xFFF0");
      xfer_sector(P_DATA_2DD, 24'h00FFF0, 8'h33, 16'd127, 8'h01);
      chk_and_rec(32'h0000_FFF0, "S4 wrapped first line");
      chk_and_rec(32'h0001_0000, "S4 wrapped second page");
      chk_and_rec(32'h0001_0060, "S4 wrapped last dword");
    end
  endtask

  // S5: BACK-TO-BACK transfers. Two TC-ended sectors into adjacent buffers.
  task automatic sc_backtoback;
    begin
      seed_cache(32'h0000_8000, 16, 8'h50, "S5 pre-cache first buffer");
      seed_cache(32'h0000_8100, 16, 8'h51, "S5 pre-cache second buffer");
      xfer_sector(P_DATA_2DD, 24'h008000, 8'h21, 16'd127, 8'h01);
      xfer_sector(P_DATA_2DD, 24'h008100, 8'h22, 16'd127, 8'h01);
      chk_and_rec(32'h0000_8000, "S5 first buffer after two transfers");
      chk_and_rec(32'h0000_8080, "S5 first buffer tail");
      chk_and_rec(32'h0000_8100, "S5 second buffer after two transfers");
      chk_and_rec(32'h0000_8180, "S5 second buffer tail");
    end
  endtask

  // S6: a FRESH transfer immediately after the CPU read the previous one - the previous
  // transfer's line must not survive the next one over the SAME bytes.
  task automatic sc_fresh_after_read;
    begin
      seed_cache(32'h0000_9000, 16, 8'h60, "S6 pre-cache");
      xfer_sector(P_DATA_2DD, 24'h009000, 8'h31, 16'd127, 8'h01);
      chk_and_rec(32'h0000_9000, "S6 first transfer read by the CPU");
      xfer_sector(P_DATA_2DD, 24'h009000, 8'h3B, 16'd127, 8'h01);
      chk_and_rec(32'h0000_9000, "S6 second transfer over the same bytes");
      chk_and_rec(32'h0000_9040, "S6 second transfer tail");
    end
  endtask

  // S7: an SDRAM WAIT STATE. ready is held low while a request is presented, so a
  // request-gated snoop would pulse before the accept (and more than once per write).
  task automatic sc_waitstate;
    integer g;
    begin
      seed_cache(32'h0000_A000, 16, 8'h70, "S7 pre-cache");
      dma_writes = 0;
      clear_flush_record;
      dmac_arm(2'd3, 24'h00A000, 16'd127);
      read_data_cmd(P_DATA_2DD, 8'h00, 8'h00, 8'h00, 8'h01, 8'h00, 8'h01);
      g = 0;
      while (dma_writes < 8 && g < WAIT_CAP) begin @(negedge clk); g = g + 1; end
      if (dma_writes < 8) $fatal(1, "S7: the transfer never reached 8 bytes");
      dma_stall = 1'b1;
      repeat (6) @(negedge clk);
      dma_stall = 1'b0;
      wait_level(W_IRQ10, cyc);
      if (cyc >= WAIT_CAP) $fatal(1, "S7: the READ DATA never completed");
      port_rd(P_DMA_STAT); stat = rd_val;
      drain_result(P_DATA_2DD);
      repeat (8) @(negedge clk);
      if (cur_mode == 0) begin
        checks = checks + 1;
        if (snoop_pulses != dma_writes) begin
          $display("FAIL S7: snoops=%0d, accepted writes=%0d - one invalidate per ACCEPT (not per request) is required",
                   snoop_pulses, dma_writes);
          errors = errors + 1;
        end
        checks = checks + 1;
        if (snoop_missing_at_accept != 0 || snoop_early_while_waiting != 0) begin
          $display("FAIL S7: snoop timing contract broken: missing_at_accept=%0d early_while_waiting=%0d",
                   snoop_missing_at_accept, snoop_early_while_waiting);
          errors = errors + 1;
        end
      end
      chk_and_rec(32'h0000_A000, "S7 post-waitstate first dword");
      chk_and_rec(32'h0000_A040, "S7 post-waitstate later dword");
    end
  endtask

  // S8: the INSTRUCTION cache. A code line is fetched into the I$, a DMA sector
  // overwrites it, and the next fetch must return the media bytes - the report's
  // "the I$ tag-matches the line" reach of the same snoop, which a D$-only test
  // cannot see (the old whole-L1 walk also covered the I$).
  task automatic sc_icache;
    reg [127:0] ln;
    reg resident;
    begin
      seed_cache(32'h0000_6000, 16, 8'h90, "S8 seed the code line through the D$");
      ifetch(32'h0000_6000, ln);              // fill the I$ line
      ifetch_resident(32'h0000_6000, resident);
      checks = checks + 1;
      if (!resident) begin
        $display("FAIL S8 setup: the I$ line 00006000 is not resident after a fetch - the test proves nothing");
        errors = errors + 1;
      end
      xfer_sector(P_DATA_2DD, 24'h006000, 8'h44, 16'd127, 8'h01);
      // The I$ line must have been invalidated: the next fetch misses...
      ifetch_resident(32'h0000_6000, resident);
      checks = checks + 1;
      if (resident) begin
        $display("FAIL S8: the I$ line 00006000 survived a DMA write - the snoop must reach the I$");
        errors = errors + 1;
      end
      // ... and returns the media bytes.
      ifetch(32'h0000_6000, ln);
      checks = checks + 1;
      if (ln[31:0] !== sh_dword(32'h0000_6000) || ln[63:32] !== sh_dword(32'h0000_6004)) begin
        $display("FAIL S8: the I$ line after a DMA is stale: got %08x %08x, want %08x %08x",
                 ln[31:0], ln[63:32], sh_dword(32'h0000_6000), sh_dword(32'h0000_6004));
        errors = errors + 1;
      end
    end
  endtask

  // S9: the EOT end with NO terminal count (the case the pre-T24 form could only
  // catch from the FDC result drain, fdc_res_done). The DMA count is programmed for
  // eight sectors but the command's EOT ends it after one, so no TC fires.
  task automatic sc_eot_no_tc;
    begin
      seed_cache(32'h0000_B000, 16, 8'hD0, "S9 pre-cache for the EOT end");
      // R = EOT = 1: the FDC ends the command at the EOT ordinal without the DMA count
      // ever expiring (count 1023 -> no mem_tc), the exact trigger split case2 names.
      xfer_sector(P_DATA_2DD, 24'h00B000, 8'h01, 16'd1023, 8'h01);
      checks = checks + 1;
      if (stat !== 8'h00) begin
        $display("FAIL S9: the DMA status reads %02x - this case must end WITHOUT a terminal count (the EOT end)", stat);
        errors = errors + 1;
      end
      chk_and_rec(32'h0000_B000, "S9 the CPU's first read after the EOT-ended DMA");
      chk_and_rec(32'h0000_B040, "S9 the EOT-ended DMA's tail");
    end
  endtask

  task automatic run_suite(input integer m);
    begin
      cur_mode = m;
      trace_n[m] = 0;
      dma_stall = 1'b0;
      sc_partial;
      sc_sets;
      sc_interleaved;
      sc_wrap;
      sc_backtoback;
      sc_fresh_after_read;
      sc_waitstate;
      sc_icache;
      sc_eot_no_tc;
    end
  endtask

  // ---- the fuzz ----
  //
  // A seeded, reproducible sequence of CPU writes/reads and full DMA sectors over the
  // real chain. Region A (0x8000..0x8FFF) is the DMA target: the CPU only READS it (so
  // a stale L1 line is the only way to see the wrong bytes) and the DMA writes it.
  // Region B (0xC000..0xCFFF) is CPU-only scratch, so no store-queue/DMA ordering
  // ambiguity is introduced. Every CPU read is checked against the oracle. Runs the
  // same seeds in both forms; the traces must agree.
  localparam integer FUZZ_OPS = 120;
  // Zero a region in BOTH the backend model and the oracle, so a fuzz run starts from
  // a state that does not depend on any earlier run (the backend is not reset by the
  // DUT's reset). 
  task automatic clear_region(input [31:0] base, input integer words);
    integer k;
    begin
      for (k = 0; k < words; k = k + 1) begin
        backend.mem[base[22:2] + k] = 32'h0;
        shadow[base[17:0] + 4*k]     = 8'h00;
        shadow[base[17:0] + 4*k + 1] = 8'h00;
        shadow[base[17:0] + 4*k + 2] = 8'h00;
        shadow[base[17:0] + 4*k + 3] = 8'h00;
      end
    end
  endtask

  task automatic fuzz(input integer seed);
    integer i, op, r;
    reg [31:0] a;
    begin
      r = $urandom(seed);
      clear_region(32'h0000_8000, 1024);   // DMA target A
      clear_region(32'h0000_C000, 1024);   // CPU scratch B
      for (i = 0; i < FUZZ_OPS; i = i + 1) begin
        op = $urandom() % 4;
        if (op == 0) begin
          // CPU write to scratch B; let the store queue drain so the backend and the
          // oracle cannot be seen in different orders by a later DMA.
          a = 32'h0000_C000 + (($urandom() % 1024) & ~32'h3);
          wr_dword(a, $urandom());
          repeat (16) @(posedge clk);   // store queue drains before any later read
        end else if (op == 1) begin
          // CPU read of scratch B (oracle-checked)
          a = 32'h0000_C000 + (($urandom() % 1024) & ~32'h3);
          chk_and_rec(a, "fuzz scratch read");
        end else if (op == 2) begin
          // CPU read of the DMA target A (the coherency oracle)
          a = 32'h0000_8000 + (($urandom() % 2048) & ~32'h3);
          chk_and_rec(a, "fuzz target read");
        end else begin
          // A full sector into A at a dword-aligned random start. The store queue is
          // given time to drain first so no ordering ambiguity is introduced.
          a = 32'h0000_8000 + (($urandom() % 1920) & ~32'h3);
          repeat (64) @(posedge clk);
          xfer_sector(P_DATA_2DD, {8'h00, a[15:0]}, $urandom(), 16'd127, 8'h01);
          // and read the sector back through the CPU
          chk_and_rec(a, "fuzz post-DMA head read");
          chk_and_rec(a + 32'd64, "fuzz post-DMA mid read");
          chk_and_rec(a + 32'd124, "fuzz post-DMA tail read");
        end
      end
    end
  endtask

  integer fuzz_seeds [0:7];
  integer si, diff_n, suite_reads;
  task automatic run_fuzz_both;
    integer i;
    begin
      fuzz_seeds[0] = 1; fuzz_seeds[1] = 7; fuzz_seeds[2] = 42;
      fuzz_seeds[3] = 1337; fuzz_seeds[4] = 99991; fuzz_seeds[5] = 424242;
      for (si = 0; si < 6; si = si + 1) begin
        // new form
        cur_mode = 0; trace_n[0] = 0;
        reset = 1; repeat (8) @(negedge clk); reset = 0; repeat (4) @(negedge clk);
        diff_old = 1'b0; dma_stall = 1'b0;
        port_wr(P_STRAP, 8'h02);
        fuzz(fuzz_seeds[si]);
        // old reference
        cur_mode = 1; trace_n[1] = 0;
        reset = 1; repeat (8) @(negedge clk); reset = 0; repeat (4) @(negedge clk);
        diff_old = 1'b1; dma_stall = 1'b0;
        port_wr(P_STRAP, 8'h02);
        fuzz(fuzz_seeds[si]);
        // compare
        diff_n = trace_n[0];
        checks = checks + 1;
        if (trace_n[1] != diff_n) begin
          $display("FAIL fuzz seed %0d: the two forms read a different NUMBER of values (%0d vs %0d)",
                   fuzz_seeds[si], trace_n[0], trace_n[1]);
          errors = errors + 1;
        end else begin
          for (i = 0; i < diff_n; i = i + 1) begin
            if (trace_a[0][i] !== trace_a[1][i] || trace_v[0][i] !== trace_v[1][i]) begin
              $display("FAIL fuzz seed %0d at read %0d: addr %08x new=%08x old=%08x - the two forms disagree",
                       fuzz_seeds[si], i, trace_a[0][i], trace_v[0][i], trace_v[1][i]);
              errors = errors + 1;
              break;
            end
          end
        end
      end
    end
  endtask

  // Compare the scenario-suite traces for the two forms.
  task automatic compare_suite;
    integer i;
    begin
      diff_n = trace_n[0];
      checks = checks + 1;
      if (trace_n[1] != diff_n) begin
        $display("FAIL differential: the two forms read a different NUMBER of values (%0d new vs %0d old)",
                 trace_n[0], trace_n[1]);
        errors = errors + 1;
      end else begin
        for (i = 0; i < diff_n; i = i + 1) begin
          if (trace_a[0][i] !== trace_a[1][i] || trace_v[0][i] !== trace_v[1][i]) begin
            $display("FAIL differential at read %0d: addr %08x new=%08x old=%08x - the snoop form and the walk disagree",
                     i, trace_a[0][i], trace_v[0][i], trace_v[1][i]);
            errors = errors + 1;
            break;
          end
        end
      end
    end
  endtask

  initial begin
    #80_000_000;
    $fatal(1, "TB_PC9821_DMA_FLUSH_COHERENCY: watchdog timeout (no verdict reached)");
  end

  initial begin
    reset = 1;
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // The 2DD window and its channel, exactly tb_pc9821_fdc_2dd_bank's DMA case.
    port_wr(P_STRAP, 8'h02);

    // ================================================================ CASE 1:
    // a TC-ended transfer over a buffer the CPU has already cached.
    // (a) the CPU writes two dwords (two cache lines' worth is one line + its
    //     neighbour) and reads them back, so the L1 really holds them.
    wr_dword(32'h0000_2000, 32'hA5A5_1234);
    wr_dword(32'h0000_2004, 32'hDEAD_BEEF);
    wr_dword(32'h0000_2010, 32'h1111_2222);
    rd_dword(32'h0000_2000, rdv);
    chk_dword(rdv, 32'hA5A5_1234, "case1 pre-DMA read of the cached dword");
    probes_cached(32'h0000_2000, cached);
    checks = checks + 1;
    if (!cached) begin
      $display("FAIL case1 setup: 00002000 was NOT cached - the fail-first case proves nothing");
      errors = errors + 1;
    end

    // (b) the transfer: 128 bytes (N=0) over DMA channel 3, TC-ended (the count
    //     is exactly the sector).
    dma_writes = 0;
    dma_bad_be = 4'h0;
    clear_flush_record;
    dmac_arm(2'd3, 24'h002000, 16'd127);
    read_data_cmd(P_DATA_2DD, 8'h00, 8'h00, 8'h00, 8'h01, 8'h00, 8'h01);
    wait_level(W_IRQ10, cyc);
    if (cyc >= WAIT_CAP)
      $fatal(1, "case1: the READ DATA never completed within %0d cycles", WAIT_CAP);
    port_rd(P_DMA_STAT);
    if (rd_val !== 8'h08)
      $fatal(1, "case1: the DMA status reads %02x, expected 08 - channel 3's terminal count (this case is the TC end)",
             rd_val);
    drain_result(P_DATA_2DD);

    // (c) THE FAIL-FIRST ASSERTION (the audit's symptom): the CPU's next read of
    //     the buffer sees the SECTOR's bytes, not the stale cached dword.
    rd_dword(32'h0000_2000, rdv);
    chk_dword(rdv, media_dword(16'd0), "case1 the CPU's first read after the DMA (must be the sector's bytes)");
    rd_dword(32'h0000_2004, rdv);
    chk_dword(rdv, media_dword(16'd4), "case1 the neighbouring dword after the DMA");
    rd_dword(32'h0000_2010, rdv);
    chk_dword(rdv, media_dword(16'd16), "case1 the second line's dword after the DMA");

    // (d) the snoop contract: EVERY accepted bus-master write invalidated the L1
    //     (one EADS# per accepted write, so the count equals the accepted writes),
    //     and NO whole-L1 cache_flush walk was raised on the DMA path (T24).
    checks = checks + 1;
    if (snoop_pulses == 0 || snoop_pulses != dma_writes) begin
      $display("FAIL case1: DMA snoops=%0d, accepted writes=%0d - every accepted write must invalidate",
               snoop_pulses, dma_writes);
      errors = errors + 1;
    end
    checks = checks + 1;
    if (flush_pulses != 0) begin
      $display("FAIL case1: %0d whole-L1 cache_flush request(s) on the DMA path - the per-write snoop must replace the completion flush (T24)",
               flush_pulses);
      errors = errors + 1;
    end
    case1_snoops = snoop_pulses;
    if (dma_bad_be != 4'h0)
      $fatal(1, "case1: mem_be disagreed with the address's lane on at least one byte");

    // ================================================================ CASE 2:
    // an EOT-ended transfer - NO terminal count - which the pre-T24 form could
    // only cover from the FDC-complete leg (pc9821_fdc's result drain). The
    // per-write snoop needs no completion event, so it covers this the same way.
    dma_writes = 0;
    dma_bad_be = 4'h0;
    clear_flush_record;
    wr_dword(32'h0000_3000, 32'hA5A5_1234);     // re-establish a stale cached line
    wr_dword(32'h0000_3004, 32'hDEAD_BEEF);
    rd_dword(32'h0000_3000, rdv);
    chk_dword(rdv, 32'hA5A5_1234, "case2 pre-DMA read of the cached dword");
    probes_cached(32'h0000_3000, cached);
    checks = checks + 1;
    if (!cached) begin
      $display("FAIL case2 setup: 00003000 was NOT cached - the fail-first case proves nothing");
      errors = errors + 1;
    end

    // The DMA count is programmed for TWO sectors (256 bytes) but the command's
    // EOT ends it after ONE (128 bytes): the count never expires, so the uPD71071
    // reports NO terminal count and mem_tc never fires.
    dmac_arm(2'd3, 24'h003000, 16'd255);
    read_data_cmd(P_DATA_2DD, 8'h00, 8'h00, 8'h00, 8'h01, 8'h00, 8'h01);
    wait_level(W_IRQ10, cyc);
    if (cyc >= WAIT_CAP)
      $fatal(1, "case2: the READ DATA never completed within %0d cycles", WAIT_CAP);
    port_rd(P_DMA_STAT);
    if (rd_val !== 8'h00)
      $fatal(1, "case2: the DMA status reads %02x, expected 00 - this case must end WITHOUT a terminal count (the EOT end), or it proves nothing",
             rd_val);
    drain_result(P_DATA_2DD);
    repeat (8) @(negedge clk);

    rd_dword(32'h0000_3000, rdv);
    chk_dword(rdv, media_dword(16'd0), "case2 the CPU's first read after the EOT-ended DMA (must be the sector's bytes)");
    rd_dword(32'h0000_3004, rdv);
    chk_dword(rdv, media_dword(16'd4), "case2 the neighbouring dword after the EOT-ended DMA");

    checks = checks + 1;
    if (snoop_pulses == 0 || snoop_pulses != dma_writes) begin
      $display("FAIL case2: DMA snoops=%0d, accepted writes=%0d on the EOT-ended transfer - the per-write snoop must cover it without a terminal count",
               snoop_pulses, dma_writes);
      errors = errors + 1;
    end
    checks = checks + 1;
    if (flush_pulses != 0) begin
      $display("FAIL case2: %0d whole-L1 cache_flush request(s) on the EOT DMA path - the per-write snoop must replace the completion flush (T24)",
               flush_pulses);
      errors = errors + 1;
    end
    case2_snoops = snoop_pulses;
    if (dma_bad_be != 4'h0)
      $fatal(1, "case2: mem_be disagreed with the address's lane on at least one byte");

    // ================================================================ DIFFERENTIAL:
    // run the whole scenario suite in the T24 form and against the pre-T24 reference,
    // under a fresh reset each time, and require the two read traces identical.
    reset = 1; repeat (8) @(negedge clk); reset = 0; repeat (4) @(negedge clk);
    diff_old = 1'b0; dma_stall = 1'b0;
    port_wr(P_STRAP, 8'h02);
    run_suite(0);
    suite_reads = trace_n[0];
    reset = 1; repeat (8) @(negedge clk); reset = 0; repeat (4) @(negedge clk);
    diff_old = 1'b1; dma_stall = 1'b0;
    port_wr(P_STRAP, 8'h02);
    run_suite(1);
    compare_suite;

    // The interleaved mid-transfer read: report the two forms' answers.
    $display("NOTE dma_flush_coherency: interleaved mid-transfer read: snoop=%08x walk=%08x (oracle %08x)",
             mid_probe[0], mid_probe[1], sh_dword(32'h0000_7000));

    // The pre-T24 reference must actually have walked the L1s, or the differential is
    // vacuous: assert the walk fired in the reference form.
    checks = checks + 1;
    if (old_walks == 0) begin
      $display("FAIL differential: the pre-T24 reference raised NO whole-L1 walk - it is not the old form");
      errors = errors + 1;
    end

    // ================================================================ FUZZ:
    // six seeded sequences, each run in both forms; every CPU read checked against the
    // oracle and the traces required identical.
    run_fuzz_both;

    // The S1..S7 snoop-timing contract must hold in every scenario run.
    checks = checks + 1;
    if (snoop_missing_at_accept != 0 || snoop_early_while_waiting != 0) begin
      $display("FAIL: snoop timing contract: missing_at_accept=%0d early_while_waiting=%0d",
               snoop_missing_at_accept, snoop_early_while_waiting);
      errors = errors + 1;
    end

    $display("NOTE dma_flush_coherency: %0d check(s), %0d mismatch(es), case1 snoops=%0d case2 snoops=%0d, differential suite reads=%0d, old-form walks=%0d, last fuzz reads=%0d",
             checks, errors, case1_snoops, case2_snoops, suite_reads, old_walks, trace_n[0]);

// ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_DMA_FLUSH_COHERENCY: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_DMA_FLUSH_COHERENCY: FAIL (%0d errors)", errors);
    end
  end

endmodule

`default_nettype wire

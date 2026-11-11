`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DMA_TRAM: a uPD71071 bus-master byte addressed to the text RAM (0xA0000-0xA3FFF) is stored in the text RAM, so a CPU read of the window returns the transferred bytes, and a memory-to-port DMA read answers the text RAM's own byte - NP2kai's memp_write8 sends an address at or above CPU_MEMWRITEMAX (0xA0000) through the CPU's handler table, whose 0xA0000 slot is memtram_wr8 (mem/dmax86.c MEMP_WRITE8, i386c/cpumem.h, mem/memtram.c); MAME pc9801.cpp dma_write_byte writes the program space - with memtram_wr8's attribute rule (an odd byte at or above 0xA2000 is dropped and reads 0xFF), no write into the SDRAM backend under the window, a DMA byte at 0xA4000 (the CG window just past the text RAM, docs/probes/DMAROUTE-XE10.TXT case G1) reaching neither the text RAM nor the backend, and one to guest RAM still committing to the backend; a floppy IPL that DMAs a sector to A000:1000 and jumps there then executes that sector.
//
// WHY THIS EXISTS. The text RAM lives in M10K (pc9821_text_mem, reached only through
// pc9821_window_responder), and the DMA port went straight to the SDRAM backend at the byte's
// physical address, so a transfer into 0xA0000-0xA3FFF landed in SDRAM where nothing reads it.
// Psy-O-Blade's IPL (C0 H0 R1) reads C0 H0 R8 (1 KiB) with INT 1Bh AH=56h to ES:BP =
// A000:1000, prints its banner and does `jmp A000:1000`: the CPU then executed the empty text
// RAM and the screen stayed on the banner.
//
// WHERE THE EXPECTATIONS COME FROM. NP2kai mem/dmax86.c stores each port-to-memory byte with
// `MEMP_WRITE8(ch->adrs.d, ch->proc.inproc())` and reads each memory-to-port byte with
// MEMP_READ8; i386c/cpumem.c memp_write8 writes `mem[address]` only below I286_MEMWRITEMAX
// (= CPU_MEMWRITEMAX, `0x0a0000`, i386c/cpumem.h) and otherwise dispatches through the
// handler table the CPU's stores use, whose 0xA0000 slot is memtram_wr8 (mem/memtram.c):
// `if (address < 0xa2000) mem[address] = value` for the characters, and the attribute half
// stores only `if (!(address & 1))`. So the byte DMA'd to X is what a CPU read of X returns,
// an odd attribute byte is dropped (and reads 0xFF on this machine, the window responder's
// captured read rule), and a DMA read of X answers the text RAM's byte.
//
// FAIL-FIRST: before the route every text-RAM byte committed to the backend and the CPU read
// returned the text RAM's untouched contents.

module tb_pc9821_dma_tram;
  // pc9821_memory_subsystem's pack-download hold: no boot-ROM download under the OSD Reset
  // level here (tb_pc9821_boot0_load drives that), so the level is low and the hold unread.
  wire hps_apply_reset = 1'b0;
  wire pack_load_hold;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg [3:0] top_bank = 4'd8;
  reg ide_rom_enable = 0;
  // The IDE work RAM's 0x1E8E visibility gate (port 0x1E8E bit 0, latched in
  // pc9821_iobus). Held ON for every pre-existing expectation here - the
  // window-0 alias test below treats 0xDA000 as the work RAM - and driven both
  // ways by the gated-work-RAM section.
  reg ide_ram_gate = 1;
  reg bios_ram_gate = 0;
  // 0x043F's 0x8 nibble, latched in pc9821_iobus. Held off here: this bench is about
  // load/arbitration, and the shadow's routing has its own bench (tb_pc9821_shadow_romsum).
  reg top_shadow_en = 0;
  reg  soft_reboot = 1'b0;   // no reboot strobe in this bench
  reg [7:0] win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  // 0x043B bit 2, the 15-16 MiB system-space window. The machine's reset value is ON,
  // so these benches drive the same state the card comes up in.
  reg  sys16m_en = 1'b1;
  reg [31:0] pack_base = 32'h01F8_0000;
  reg [31:0] guest_ram_bytes = 32'h0200_0000;
  reg gvram_access_page = 0;
  // EGC: held disabled here. tb_pc9821_egc.sv is the bench that drives the
  // engine; this one only has to keep the route off so its own expectations
  // (plain translation) still hold.
  reg        egc_enable = 1'b0;
  reg [15:0] egc_access = 16'hFFF0;
  reg [15:0] egc_fgbg = 16'h00FF;
  reg [15:0] egc_ope = 16'h0000;
  reg [15:0] egc_fg = 16'h0000;
  reg [15:0] egc_mask = 16'hFFFF;
  reg [15:0] egc_bg = 16'h0000;
  reg [15:0] egc_sft = 16'h0000;
  reg [15:0] egc_leng = 16'h000F;
  reg        egc_shift_we = 1'b0;
  reg ioctl_download = 0, ioctl_wr = 0;
  reg [15:0] ioctl_index = 0;
  reg [26:0] ioctl_addr = 0;
  reg [15:0] ioctl_dout = 0;
  wire ioctl_wait, rom_ready, load_error, cpu_run;
  wire [17:0] font_addr;   // 18 bits: the whole FONT.ROM grid lives above the 2048 ANK words
  wire [15:0] font_data;
  wire font_we;

  reg [31:0] cpu_addr = 0, cpu_din = 0;
  wire [31:0] cpu_dout;
  // The line-form names: the boundary answers every fill as word beats now (the
  // beat-uniform fill, trade T22), so cpu_line_word/cpu_line_word_valid are dead
  // bench wires (no DUT port drives them; they read 0). The idle checks' OR terms
  // with cpu_line_word_valid are stricter-than-needed, not weaker.
  wire [31:0] cpu_line_word;
  reg [3:0] cpu_be = 4'hF;
  reg [7:0] cpu_burstcount = 1;
  reg cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  wire cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  wire [13:0] tram_addr;
  wire [7:0] tram_din;
  wire tram_we;
  reg [7:0] tram_dout = 0;
  reg [7:0] tram [0:16383];
  // The text RAM: one-cycle, write-first, pc9821_dpram's port shape (the memory_subsystem
  // bench's model).
  integer ti;
  initial for (ti = 0; ti < 16384; ti = ti + 1) tram[ti] = 8'h00;
  always @(posedge clk) begin
    if (tram_we) begin
      tram[tram_addr] <= tram_din;
      tram_dout <= tram_din;
    end else tram_dout <= tram[tram_addr];
  end
  // CG window (0xA4000-0xA4FFF) is exercised by its own bench; here the port is
  // simply held idle so the wildcard instantiation remains complete.
  wire [4:0] cg_win_byte_sel;
  wire cg_win_rd;
  reg [7:0] cg_win_dout = 0;
  wire [7:0] cg_win_din;
  wire cg_win_we;
  // Glyph-region reader (the SDRAM's second port) and its request from the GDC:
  // both parked, so the subsystem never sees a fetch here.
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
  reg [127:0] mem_line_dout = 128'h0123456789ABCDEFFEDCBA9876543210;
  wire [3:0] mem_be;
  wire [7:0] mem_burstcount;
  wire mem_line_read, mem_valid, mem_write;
  reg mem_ready = 0, mem_resp_valid = 0, mem_line_resp_valid = 0;
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

  reg        gvram_timing_xe10 = 0, gvram_gfx_scan_on = 0;   // OSD I/O timing Fast
  reg        scan_line_tick = 0;
  reg        scan_page = 0;
  reg [14:0] scan_line_base = 0;
  reg  [6:0] line_rd_addr = 0;
  reg        line_rd_sel = 0;
  wire [31:0] line_data;
  wire        line_sel;
  wire        line_ready;

  // The 0x043F EMS window state: 0 (no window) except in the EMS case below.
  reg [1:0] ems_state = 2'd0;

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
  // ---- pc9821_memory_subsystem's DMA bus-master port, driven by the cases ----
  reg  [31:0] dma_addr = 32'd0;
  wire [31:0] dma_snoop_addr;   // the DMA byte's post-map name, for the external snoop (unused here)
  // The DMAC's address load (pc9821_dmac mem_addr_nx/mem_load): the subsystem registers the
  // byte's route as the address loads, so the bench loads the address while no request is up
  // and presents it at least one cycle later, as the DMAC's S_FIRST/S_DEV -> S_MEM edge does.
  wire [31:0] dma_addr_nx = dma_addr;
  wire        dma_load    = !dma_valid;
  reg  [31:0] dma_din  = 32'd0;
  reg   [3:0] dma_be   = 4'd0;
  reg         dma_valid = 1'b0;
  reg         dma_write = 1'b0;
  wire        dma_ready, dma_resp_valid;
  wire [31:0] dma_dout;
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
  wire scan_walk_page = 1'b0;

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
  // The 16-colour select (port 0x6A FF2 num 0): 0 = the digital mode the machine resets to,
  // where 0xE0000-0xE7FFF is open bus (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b0;

  pc9821_memory_subsystem #(.SYS_CLOCK_HZ(100_000_000)) dut (.*);
  // ==== THE BACKEND: the bridge's launch/ack contract, minus the hiding $fatal ====
  // (see the header) - capture at first presentation, one-cycle ack ACK_LAT later,
  // payload stable until then, the committed transaction is the CAPTURED payload.
  localparam integer ACK_LAT  = 4;   // launch -> ack: the window the audit's steal needs
  localparam integer RESP_LAT = 2;   // commit -> the read's response beat

  localparam [1:0] B_IDLE = 2'd0, B_RUN = 2'd1, B_ACK = 2'd2;
  reg  [1:0] b_state;
  reg  [2:0] b_cnt;
  reg        b_cap_write;
  reg [31:0] b_cap_addr, b_cap_din;
  reg  [3:0] b_cap_be;
  reg [31:0] b_mem [0:4095];
  integer    b_commits;
  integer    b_payload_moves;
  reg [31:0] b_c_addr [0:7];
  reg [31:0] b_c_din  [0:7];
  reg  [3:0] b_c_be   [0:7];
  reg        b_c_wr   [0:7];
  reg        b_resp_pending;
  reg  [2:0] b_resp_delay;
  reg [31:0] b_resp_addr;
  integer    bi;

  always @(posedge clk) begin
    if (reset) begin
      b_state <= B_IDLE;
      b_cnt <= 3'd0;
      b_cap_write <= 1'b0; b_cap_addr <= 32'd0; b_cap_din <= 32'd0; b_cap_be <= 4'd0;
      b_commits <= 0;
      b_payload_moves <= 0;
      b_resp_pending <= 1'b0;
      b_resp_delay <= 3'd0;
      b_resp_addr <= 32'd0;
      mem_ready <= 1'b0;
      mem_resp_valid <= 1'b0;
    end else begin
      mem_ready <= 1'b0;
      mem_resp_valid <= 1'b0;
      case (b_state)
        B_IDLE: if (mem_valid) begin
          b_state <= B_RUN;
          b_cnt <= ACK_LAT[2:0];
          b_cap_write <= mem_write;
          b_cap_addr  <= mem_addr;
          b_cap_din   <= mem_din;
          b_cap_be    <= mem_be;
        end
        B_RUN: begin
          // The payload-stability contract (sdram_sync_bridge's requester check,
          // without its $fatal): the mux must not move the request under a held
          // valid.
          if ((mem_addr !== b_cap_addr) || (mem_din !== b_cap_din) ||
              (mem_be !== b_cap_be) || (mem_write !== b_cap_write))
            b_payload_moves <= b_payload_moves + 1;
          if (b_cnt != 3'd0) b_cnt <= b_cnt - 3'd1;
          else begin
            b_c_addr[b_commits[2:0]] <= b_cap_addr;
            b_c_din [b_commits[2:0]] <= b_cap_din;
            b_c_be  [b_commits[2:0]] <= b_cap_be;
            b_c_wr  [b_commits[2:0]] <= b_cap_write;
            b_commits <= b_commits + 1;
            if (b_cap_write) begin
              if (b_cap_be[0]) b_mem[b_cap_addr[13:2]][7:0]   <= b_cap_din[7:0];
              if (b_cap_be[1]) b_mem[b_cap_addr[13:2]][15:8]  <= b_cap_din[15:8];
              if (b_cap_be[2]) b_mem[b_cap_addr[13:2]][23:16] <= b_cap_din[23:16];
              if (b_cap_be[3]) b_mem[b_cap_addr[13:2]][31:24] <= b_cap_din[31:24];
            end else begin
              b_resp_pending <= 1'b1;
              b_resp_delay   <= RESP_LAT[2:0];
              b_resp_addr    <= b_cap_addr;
            end
            mem_ready <= 1'b1;       // the one-cycle ack, next cycle
            b_state <= B_ACK;
          end
        end
        B_ACK: b_state <= B_IDLE;    // the ack cycle: the payload may move here (the bridge's excluded cycle)
        default: b_state <= B_IDLE;
      endcase
      if (b_resp_pending) begin
        if (b_resp_delay != 3'd0) b_resp_delay <= b_resp_delay - 3'd1;
        else begin
          mem_dout <= b_mem[b_resp_addr[13:2]];
          mem_resp_valid <= 1'b1;
          b_resp_pending <= 1'b0;
        end
      end
    end
  end


  // ==== STIMULUS ====
  integer errors = 0;

  task automatic send_word(input [26:0] addr, input [15:0] data);
    begin
      while (ioctl_wait) @(negedge clk);
      @(negedge clk);
      ioctl_addr = addr;
      ioctl_dout = data;
      ioctl_wr = 1;
      @(negedge clk);
      ioctl_wr = 0;
    end
  endtask

  // Backend writes whose address lies in the text RAM window (the SDRAM under it): counted.
  integer hole_commits = 0;
  integer commits_seen = 0;
  always @(posedge clk) begin
    if (!reset && (b_commits > commits_seen)) begin
      commits_seen <= b_commits;
      if (b_cap_write && (b_cap_addr[31:14] == 18'h00028))
        hole_commits <= hole_commits + 1;
    end
  end

  // One DMA byte, the way pc9821_dmac presents it: one-hot lane from the address, the byte
  // replicated across the lanes, the request held until its accept.
  task automatic dma_byte(input [31:0] addr, input is_write, input [7:0] b, output [31:0] rd);
    integer g, seen, hold, resps;
    begin
      dma_addr  = addr;
      dma_din   = {4{b}};
      dma_be    = 4'b0001 << addr[1:0];
      dma_write = is_write;
      @(negedge clk);   // the DMAC's address load: one cycle before the request
      dma_valid = 1'b1;
      seen = 0; hold = 0; resps = 0; rd = 32'hXXXX_XXXX;
      g = 0;
      while (!(seen && hold >= 2) && g < 400) begin
        @(negedge clk);
        if (!seen && dma_valid && dma_ready) begin
          seen = 1;
          // The accept latency, request presented -> ready, in clk (informational: the cost of
          // one window byte on this path, reported so a change to it is visible).
          $display("DMA_LAT %s a=%08x %0d clk", is_write ? "WR" : "RD", addr, g + 1);
        end
        if (seen) begin
          if (hold >= 1) dma_valid = 1'b0;
          hold = hold + 1;
        end
        if (dma_resp_valid) begin resps = resps + 1; rd = dma_dout; end
        g = g + 1;
      end
      dma_valid = 1'b0;
      if (!seen) $fatal(1, "TB_PC9821_DMA_TRAM: FAIL (the DMA byte at %08x was never accepted)", addr);
      for (g = 0; g < 40; g = g + 1) begin
        @(negedge clk);
        if (dma_resp_valid) begin resps = resps + 1; rd = dma_dout; end
      end
      if (!is_write && resps != 1) begin
        $display("FAIL the DMA read at %08x saw %0d response(s), expected exactly 1", addr, resps);
        errors = errors + 1;
      end
      if (is_write && resps != 0) begin
        $display("FAIL the DMA write at %08x drew %0d response(s), expected none", addr, resps);
        errors = errors + 1;
      end
    end
  endtask

  task automatic cpu_read(input [31:0] addr, output [31:0] rd);
    integer g, seen, hold, resps;
    begin
      cpu_addr = addr; cpu_be = 4'hF; cpu_burstcount = 8'd1; cpu_line_read = 1'b0;
      cpu_write = 1'b0; cpu_valid = 1'b1;
      seen = 0; hold = 0; resps = 0; rd = 32'hXXXX_XXXX;
      g = 0;
      while (!(seen && hold >= 2) && g < 400) begin
        @(negedge clk);
        if (!seen && cpu_valid && cpu_ready) seen = 1;
        if (seen) begin
          if (hold >= 1) cpu_valid = 1'b0;
          hold = hold + 1;
        end
        if (cpu_resp_valid) begin resps = resps + 1; rd = cpu_dout; end
        g = g + 1;
      end
      cpu_valid = 1'b0;
      if (!seen) $fatal(1, "TB_PC9821_DMA_TRAM: FAIL (the CPU read at %08x was never accepted)", addr);
      for (g = 0; g < 40; g = g + 1) begin
        @(negedge clk);
        if (cpu_resp_valid) begin resps = resps + 1; rd = cpu_dout; end
      end
      if (resps != 1) begin
        $display("FAIL the CPU read at %08x saw %0d response(s), expected exactly 1", addr, resps);
        errors = errors + 1;
      end
    end
  endtask

  task automatic expect_word(input [8*40-1:0] tag, input [31:0] got, input [31:0] mask,
                             input [31:0] want);
    begin
      if ((got & mask) !== (want & mask)) begin
        $display("FAIL %0s: read %08x (mask %08x), want %08x", tag, got, mask, want);
        errors = errors + 1;
      end
    end
  endtask

// ==== CHECKS ====

  initial begin
    #80_000_000;
    $fatal(1, "TB_PC9821_DMA_TRAM: watchdog timeout (no verdict reached)");
  end

  reg [31:0] rd;
  integer commits_before;
  initial begin
    reset = 1;
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);
    ioctl_download = 1;
    send_word(27'd0, 16'hBEEF);
    repeat (2) @(posedge clk);
    ioctl_download = 0;
    begin : wait_rom
      integer g;
      g = 0;
      while (!rom_ready && g < 400) begin @(negedge clk); g = g + 1; end
    end
    if (!rom_ready || !cpu_run || load_error)
      $fatal(1, "TB_PC9821_DMA_TRAM: FAIL (the pack download did not release the CPU)");
    repeat (4) @(negedge clk);
    hole_commits = 0;

    // ---- a sector's first bytes into the character half at 0xA1000 (Psy-O-Blade's A000:1000) ----
    dma_byte(32'h000A_1000, 1'b1, 8'hEB, rd);
    dma_byte(32'h000A_1001, 1'b1, 8'hFE, rd);
    dma_byte(32'h000A_1002, 1'b1, 8'h90, rd);
    dma_byte(32'h000A_1003, 1'b1, 8'hCC, rd);
    dma_byte(32'h000A_0000, 1'b1, 8'h41, rd);   // the first character cell
    dma_byte(32'h000A_1FFF, 1'b1, 8'h7E, rd);   // the character half's last byte
    // ---- the attribute half: an even byte is stored, an odd one is dropped (memtram_wr8) ----
    dma_byte(32'h000A_2000, 1'b1, 8'hE1, rd);
    dma_byte(32'h000A_2001, 1'b1, 8'h5A, rd);
    dma_byte(32'h000A_3FDE, 1'b1, 8'h85, rd);

    cpu_read(32'h000A_1000, rd);
    expect_word("cpu read A1000 after DMA", rd, 32'hFFFF_FFFF, 32'hCC90_FEEB);
    cpu_read(32'h000A_0000, rd);
    expect_word("cpu read A0000 after DMA", rd, 32'h0000_00FF, 32'h0000_0041);
    cpu_read(32'h000A_1FFC, rd);
    expect_word("cpu read A1FFF after DMA", rd, 32'hFF00_0000, 32'h7E00_0000);
    cpu_read(32'h000A_2000, rd);
    expect_word("cpu read A2000 after DMA (odd lane reads FF)", rd, 32'h0000_FFFF, 32'h0000_FFE1);
    cpu_read(32'h000A_3FDC, rd);
    expect_word("cpu read A3FDE after DMA", rd, 32'h00FF_0000, 32'h0085_0000);
    if (tram[14'h2001] !== 8'h00) begin
      $display("FAIL the odd attribute byte 0xA2001 was stored (%02x); memtram_wr8 drops it", tram[14'h2001]);
      errors = errors + 1;
    end

    // ---- a memory-to-port DMA read of the window answers the text RAM's byte ----
    dma_byte(32'h000A_1002, 1'b0, 8'h00, rd);
    expect_word("dma read A1002", rd, 32'h00FF_0000, 32'h0090_0000);
    dma_byte(32'h000A_2001, 1'b0, 8'h00, rd);
    expect_word("dma read A2001 (odd attribute)", rd, 32'h0000_FF00, 32'h0000_FF00);

    if (hole_commits != 0) begin
      $display("FAIL %0d DMA write(s) into the text RAM window reached the SDRAM backend", hole_commits);
      errors = errors + 1;
    end

    // ---- controls: just past the text RAM (0xA4000) is the CG window, which takes the byte
    //      (docs/probes/DMAROUTE-XE10.TXT case G1; tb_pc9821_dma_route pins where), so neither
    //      the text RAM's offset 0 nor the backend sees it; guest RAM still goes to the backend ----
    commits_before = b_commits;
    tram[14'h0000] = 8'hC3;
    dma_byte(32'h000A_4000, 1'b1, 8'h3C, rd);
    if (b_commits != commits_before || tram[14'h0000] !== 8'hC3) begin
      $display("FAIL a DMA byte at 0xA4000 (the CG window) reached the backend or the text RAM (commits %0d -> %0d, tram[0] %02x)",
               commits_before, b_commits, tram[14'h0000]);
      errors = errors + 1;
    end
    commits_before = b_commits;
    dma_byte(32'h0000_2001, 1'b1, 8'h5C, rd);
    if (b_commits != commits_before + 1 || b_c_addr[commits_before[2:0]] !== 32'h0000_2001 ||
        b_c_be[commits_before[2:0]] !== 4'b0010) begin
      $display("FAIL a DMA byte to guest RAM 0x2001 did not commit to the backend once (commits %0d -> %0d)",
               commits_before, b_commits);
      errors = errors + 1;
    end
    // ---- a stale upper address bit is not the text RAM (the class is first-MiB only) ----
    commits_before = b_commits;
    dma_byte(32'h010A_1000, 1'b1, 8'h77, rd);
    if (b_commits != commits_before + 1) begin
      $display("FAIL a DMA byte at 0x010A1000 did not commit to the backend (commits %0d -> %0d)",
               commits_before, b_commits);
      errors = errors + 1;
    end
    cpu_read(32'h000A_1000, rd);
    expect_word("A1000 untouched by the 0x010A1000 byte", rd, 32'h0000_00FF, 32'h0000_00EB);

// ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_DMA_TRAM: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_DMA_TRAM: FAIL (%0d errors)", errors);
    end
  end

endmodule

`default_nettype wire

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DMA_GVRAM: a uPD71071 bus-master byte addressed to a graphics plane window (0xA8000-0xBFFFF, 0xE0000-0xE7FFF) is stored in that GVRAM plane, so a CPU read of the window returns the transferred bytes, and a memory-to-port DMA read of the window answers the plane's own bytes - the DMA is a bus master on the CPU's memory map (NP2kai mem/dmax86.c MEMP_WRITE8 -> i386c/cpumem.c memfn0.wr8; MAME pc9801.cpp dma_write_byte -> program space); a floppy IPL that reads its directory into 0xA8000 by DMA then finds it there. The backend sees no write into the SDRAM hole under the windows, a DMA byte to guest RAM still commits to the backend, and with an EMS window active 0xB0000 stays the backend's. A MODE WRITE LANDING WHILE A DMA BYTE IS IN FLIGHT does not move it: with port 0x6A's 256-colour bit or the 0x043F EMS state written between the byte's presentation and its accept, the byte is accepted exactly once, by the acceptor its class named when it was presented (a plane byte lands in its plane and never in the backend; an EMS-window byte, store or read, is the backend's alone and plane R stays untouched) - the class is frozen for the request's life, so the backend arm's request cannot fall before its ack and the share's granted visit cannot lose its request (FAIL-FIRST against the live mode decode, which re-routes the held byte).
//
// WHY THIS EXISTS. The planes live in M10K (pc9821_gvram_mem) and the DMA port went straight to
// the SDRAM backend at the byte's physical address, so a transfer into 0xA8000 landed in the
// SDRAM hole under the window and the CPU read back the untouched plane. Boot loaders that read
// their root directory and FAT into G-VRAM with INT 1Bh (ES = 0xA800 / 0xB000, the display
// stopped with GDC command 0x0C) then scanned an empty plane, never found their file, and
// retried forever on a black screen.
//
// WHERE THE EXPECTATIONS COME FROM. NP2kai's transfer loop stores each port-to-memory byte
// with MEMP_WRITE8(ch->adrs.d, ...) (mem/dmax86.c) and reads each memory-to-port byte with
// MEMP_READ8; for a first-MiB address memp_write8 dispatches through memfn0.wr8[address >> 15]
// (i386c/cpumem.c), the table the CPU's own stores use, whose 0xA8000-0xBFFFF and 0xE0000
// entries are the plane handlers. MAME's pc9801.cpp dma_write_byte writes through the CPU's
// program space as well. So the byte written at plane-window address X is what a CPU read of
// X returns, byte for byte, and a DMA read of X returns the plane's byte. The EMS rule is the
// map's own (pc9821_memory_map: B0000-BFFFF is the EMS window's while one is selected).
//
// FAIL-FIRST: before the route every window byte committed to the backend (the hole) and the
// CPU read returned the plane's power-up zeroes.

module tb_pc9821_dma_gvram;
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

  // The JIS ku-bank sweep (see the check at the end): one code from each bank of the JIS
  // grid, the region byte offset the scanout's decode implies for it, and FONT.ROM's own two
  // bytes at that offset (low byte = the even dump byte, bios/xe10/FONT.ROM). ku/ten are the
  // code; rel = (ku-0x21)*0xC00 + (ten-0x20)*0x20. Banks: row 0, the hiragana row, and
  // level-1/level-2's first, middle and last rows.
  localparam integer NJIS = 9;
  localparam [7:0]  jis_ku   [0:NJIS-1] = '{8'h21, 8'h24, 8'h30, 8'h40, 8'h4f, 8'h50, 8'h60, 8'h70, 8'h7c};
  localparam [7:0]  jis_ten  [0:NJIS-1] = '{8'h29, 8'h22, 8'h21, 8'h21, 8'h21, 8'h22, 8'h21, 8'h21, 8'h21};
  localparam [19:0] jis_rel  [0:NJIS-1] = '{20'h00120, 20'h02440, 20'h0b420, 20'h17420, 20'h22820,
                                            20'h23440, 20'h2f420, 20'h3b420, 20'h44420};
  localparam [15:0] jis_data [0:NJIS-1] = '{16'h0300, 16'h0200, 16'h3f00, 16'h1021, 16'h7f02,
                                            16'h7f00, 16'h107f, 16'h7c00, 16'h1408};

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
  // 0 = the pre-PEGC decode this bench drives; the PEGC arms are tb_pc9821_memmap_ref's. A reg
  // because the in-flight mode-change cases below write it (port 0x6A) while a DMA byte waits.
  reg  pegc_256 = 1'b0;
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
  // The 16-colour mode (the guest's OUT 0x6A,0x01, FF2 num 0): this bench reaches the E plane at
  // 0xE0000-0xE7FFF, which the machine maps only in that mode (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b1;

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

  // Backend writes whose address lies in a plane window (the SDRAM hole): counted while armed.
  integer hole_commits = 0;
  integer commits_seen = 0;
  always @(posedge clk) begin
    if (!reset && (b_commits > commits_seen)) begin
      commits_seen <= b_commits;
      if (b_cap_write && (b_cap_addr[31:20] == 12'd0) &&
          (((b_cap_addr[19:15] >= 5'b10101) && (b_cap_addr[19:15] <= 5'b10111)) ||
           (b_cap_addr[19:15] == 5'b11100)) && (ems_state == 2'd0))
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
      if (!seen) $fatal(1, "TB_PC9821_DMA_GVRAM: FAIL (the DMA byte at %08x was never accepted)", addr);
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

  // Every acceptance the DMA port signals, counted per byte by dma_byte_flip below.
  integer dma_readies = 0;
  always @(posedge clk) if (!reset && dma_valid && dma_ready) dma_readies <= dma_readies + 1;

  // One DMA byte as dma_byte presents it, with a MODE WRITE landing while the byte is in flight:
  // `flip_at` clk after the byte is first presented (and before its accept), port 0x6A's
  // 256-colour bit (`which` 0) or the 0x043F EMS state (`which` 1) takes `nv`. The CPU keeps
  // running while the uPD71071 holds a byte, so an OUT can land there. The byte must be
  // accepted exactly ONCE, by the acceptor its class named when it was presented.
  task automatic dma_byte_flip(input [31:0] addr, input is_write, input [7:0] b,
                               input integer flip_at, input integer which, input [1:0] nv,
                               output [31:0] rd, output integer readies);
    integer g, seen, hold, resps, r0;
    begin
      r0 = dma_readies;
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
        if (g + 1 == flip_at) begin
          if (seen)
            $fatal(1, "TB_PC9821_DMA_GVRAM: FAIL (the byte at %08x was accepted before its mode write; the case is vacuous)", addr);
          if (which == 0) pegc_256 = nv[0]; else ems_state = nv;
        end
        if (!seen && dma_valid && dma_ready) seen = 1;
        if (seen) begin
          if (hold >= 1) dma_valid = 1'b0;
          hold = hold + 1;
        end
        if (dma_resp_valid) begin resps = resps + 1; rd = dma_dout; end
        g = g + 1;
      end
      dma_valid = 1'b0;
      if (!seen) $fatal(1, "TB_PC9821_DMA_GVRAM: FAIL (the DMA byte at %08x was never accepted)", addr);
      for (g = 0; g < 40; g = g + 1) begin
        @(negedge clk);
        if (dma_resp_valid) begin resps = resps + 1; rd = dma_dout; end
      end
      readies = dma_readies - r0;
      if (readies != 1) begin
        $display("FAIL the DMA byte at %08x with a mode write in flight was accepted %0d time(s), expected exactly 1", addr, readies);
        errors = errors + 1;
      end
      if (!is_write && resps != 1) begin
        $display("FAIL the DMA read at %08x with a mode write in flight saw %0d response(s), expected exactly 1", addr, resps);
        errors = errors + 1;
      end
      if (is_write && resps != 0) begin
        $display("FAIL the DMA write at %08x with a mode write in flight drew %0d response(s), expected none", addr, resps);
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
      if (!seen) $fatal(1, "TB_PC9821_DMA_GVRAM: FAIL (the CPU read at %08x was never accepted)", addr);
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
    $fatal(1, "TB_PC9821_DMA_GVRAM: watchdog timeout (no verdict reached)");
  end

  reg [31:0] rd;
  integer commits_before;
  integer readies;
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
      $fatal(1, "TB_PC9821_DMA_GVRAM: FAIL (the pack download did not release the CPU)");
    repeat (4) @(negedge clk);
    hole_commits = 0;

    // ---- a floppy sector's first bytes into plane B (0xA8000), byte by byte ----
    dma_byte(32'h000A_8000, 1'b1, 8'h11, rd);
    dma_byte(32'h000A_8001, 1'b1, 8'h22, rd);
    dma_byte(32'h000A_8002, 1'b1, 8'h33, rd);
    dma_byte(32'h000A_8003, 1'b1, 8'h44, rd);
    dma_byte(32'h000A_8005, 1'b1, 8'h99, rd);
    // ---- one byte into each other plane window ----
    dma_byte(32'h000B_0010, 1'b1, 8'h55, rd);   // plane R
    dma_byte(32'h000B_8021, 1'b1, 8'h66, rd);   // plane G
    dma_byte(32'h000E_0032, 1'b1, 8'h77, rd);   // plane E
    dma_byte(32'h000A_FFFF, 1'b1, 8'hA5, rd);   // plane B's last byte

    cpu_read(32'h000A_8000, rd);
    expect_word("cpu read A8000 after DMA", rd, 32'hFFFF_FFFF, 32'h4433_2211);
    cpu_read(32'h000A_8004, rd);
    expect_word("cpu read A8005 after DMA", rd, 32'h0000_FF00, 32'h0000_9900);
    cpu_read(32'h000B_0010, rd);
    expect_word("cpu read B0010 after DMA", rd, 32'h0000_00FF, 32'h0000_0055);
    cpu_read(32'h000B_8020, rd);
    expect_word("cpu read B8021 after DMA", rd, 32'h0000_FF00, 32'h0000_6600);
    cpu_read(32'h000E_0030, rd);
    expect_word("cpu read E0032 after DMA", rd, 32'h00FF_0000, 32'h0077_0000);
    cpu_read(32'h000A_FFFC, rd);
    expect_word("cpu read AFFFF after DMA", rd, 32'hFF00_0000, 32'hA500_0000);

    // ---- a memory-to-port DMA read of the window answers the plane's byte ----
    dma_byte(32'h000A_8002, 1'b0, 8'h00, rd);
    expect_word("dma read A8002", rd, 32'h00FF_0000, 32'h0033_0000);

    if (hole_commits != 0) begin
      $display("FAIL %0d DMA write(s) into the plane windows reached the SDRAM backend (the hole under the window)", hole_commits);
      errors = errors + 1;
    end

    // ---- control: a DMA byte to guest RAM still commits to the backend ----
    commits_before = b_commits;
    dma_byte(32'h0000_2001, 1'b1, 8'h5C, rd);
    if (b_commits != commits_before + 1 || b_c_addr[commits_before[2:0]] !== 32'h0000_2001 ||
        b_c_be[commits_before[2:0]] !== 4'b0010) begin
      $display("FAIL a DMA byte to guest RAM 0x2001 did not commit to the backend once (commits %0d -> %0d)",
               commits_before, b_commits);
      errors = errors + 1;
    end

    // ---- an EMS window over 0xB0000: the byte is the backend's, not plane R's ----
    ems_state = 2'd1;
    repeat (2) @(negedge clk);
    commits_before = b_commits;
    dma_byte(32'h000B_0040, 1'b1, 8'hE5, rd);
    if (b_commits != commits_before + 1) begin
      $display("FAIL with an EMS window selected a DMA byte at 0xB0040 did not go to the backend (commits %0d -> %0d)",
               commits_before, b_commits);
      errors = errors + 1;
    end
    ems_state = 2'd0;
    repeat (2) @(negedge clk);
    cpu_read(32'h000B_0040, rd);
    expect_word("plane R B0040 untouched under EMS", rd, 32'h0000_00FF, 32'h0000_0000);

    // ---- a mode write while a DMA byte is in flight: the byte keeps the route it was
    //      presented on (the class is frozen for the request's life), and one acceptor takes it ----
    // (a) a plane byte, then 0x6A selects 256-colour mode before its accept: plane B takes it.
    commits_before = b_commits;
    dma_byte_flip(32'h000A_8041, 1'b1, 8'hC3, 1, 0, 2'd1, rd, readies);
    pegc_256 = 1'b0;
    repeat (2) @(negedge clk);
    if (b_commits != commits_before) begin
      $display("FAIL a plane byte with 256-colour mode selected in flight also reached the backend (commits %0d -> %0d)",
               commits_before, b_commits);
      errors = errors + 1;
    end
    cpu_read(32'h000A_8040, rd);
    expect_word("plane B A8041 after an in-flight 0x6A write", rd, 32'h0000_FF00, 32'h0000_C300);
    // (b) a plane-R byte, then 0x043F selects an EMS page before its accept: plane R takes it.
    commits_before = b_commits;
    dma_byte_flip(32'h000B_0072, 1'b1, 8'hB7, 1, 1, 2'd1, rd, readies);
    ems_state = 2'd0;
    repeat (2) @(negedge clk);
    if (b_commits != commits_before) begin
      $display("FAIL a plane-R byte with an EMS page selected in flight also reached the backend (commits %0d -> %0d)",
               commits_before, b_commits);
      errors = errors + 1;
    end
    cpu_read(32'h000B_0070, rd);
    expect_word("plane R B0072 after an in-flight 0x043F write", rd, 32'h00FF_0000, 32'h00B7_0000);
    // (c) a backend byte under EMS, then 0x043F returns to the planes before its ack: the
    //     backend takes it once, and plane R stays untouched.
    ems_state = 2'd1;
    repeat (2) @(negedge clk);
    commits_before = b_commits;
    dma_byte_flip(32'h000B_0060, 1'b1, 8'hD4, 2, 1, 2'd0, rd, readies);
    // The backend address is the EMS page's, not the window's physical 0xB0060 (the page sits at
    // ems_page_base, whose low 20 bits are 0x48000 - pc9821_memory_map lo_ems_page; the full
    // placement is tb_pc9821_dma_route's).
    if (b_commits != commits_before + 1 || b_c_addr[commits_before[2:0]][19:0] !== 20'h4_8060) begin
      $display("FAIL an EMS-window byte with the planes reselected in flight did not commit to the backend once (commits %0d -> %0d)",
               commits_before, b_commits);
      errors = errors + 1;
    end
    cpu_read(32'h000B_0060, rd);
    expect_word("plane R B0060 untouched after an in-flight 0x043F write", rd, 32'h0000_00FF, 32'h0000_0000);
    // (d) the same for a memory-to-port READ: the backend answers it, once, with its own byte
    //     (stored first at a word (c) does not touch, so plane R there still holds zero).
    ems_state = 2'd1;
    repeat (2) @(negedge clk);
    dma_byte(32'h000B_0064, 1'b1, 8'h6E, rd);
    dma_byte_flip(32'h000B_0064, 1'b0, 8'h00, 2, 1, 2'd0, rd, readies);
    expect_word("dma read B0064 (EMS) with the planes reselected in flight", rd, 32'h0000_00FF, 32'h0000_006E);
    ems_state = 2'd0;
    repeat (2) @(negedge clk);

// ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_DMA_GVRAM: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_DMA_GVRAM: FAIL (%0d errors)", errors);
    end
  end

endmodule

`default_nettype wire

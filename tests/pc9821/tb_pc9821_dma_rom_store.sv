`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DMA_ROM_STORE: a port-to-memory byte moved by the REAL uPD71071 engine (pc9821_dmac, its own address-load and request timing) into a firmware window is handled as a CPU store at that address is - the memory map decodes it as a STORE in the cycle its route is registered - so a floppy/HDD read DMA into the main BIOS ROM (0xE8010), the 0xD8000 option-ROM window (0xD8100), the PC-9801-86 SOUND.ROM window (0xCC100) or the 0xF8000 top window with 0x053D bit 1 clear (0xF8E90) commits nothing to the backend (NP2kai's DMA moves each byte with MEMP_WRITE8 through the CPU's handler table, mem/dmax86.c, i386c/cpumem.c `memfn0.wr8[address >> 15](address, value);`, and the write handler of those windows is memnc_wr8, which discards the store), while with the gate open the 0xF8E90 byte lands in the writable shadow (fw_shadow_base + 0x0E90, not the pack's bank) and marks it written, so the CPU's next read of 0xF8E90 under the BIOS-top bank returns the transferred byte (qemu-pc98 hw/i386/pc98-mem.c serves 0xF8000 from f8000_ram exactly when the bank is BIOS-top and the gate is set); a DMA byte to RAM still commits, and a memory-to-port DMA read of 0xE8010 still returns the pack byte. FAIL-FIRST against the route decoded from the DMAC's request qualifier mem_we, which is low in both load cycles, so every port-to-memory byte was classed a read: the ROM-window bytes committed to the pack and the gated shadow byte went to the pack's bank with the shadow left unwritten.
//
// WHY THIS EXISTS. pc9821_memory_subsystem registers a DMA byte's route on dma_load, the
// DMAC's address-load cycle (S_FIRST or S_DEV), and the decode took its direction from
// dma_write - pc9821_dmac's mem_we, which is `mem_req && ...` and only rises in S_MEM, after
// both load cycles. Every bench before this one drove the DMA port from a task that set
// dma_write together with the address, so the load cycle saw the right direction and the
// defect could not show; this one drives the subsystem from the real engine.
//
// WHERE THE EXPECTATIONS COME FROM. The DMA is a bus master on the CPU's own map (the real
// Xe10 lands each DMA byte where the CPU's lands in every window measured,
// docs/probes/DMAROUTE-XE10.TXT); the ROM windows' write handler is NP2kai's memnc_wr8
// (i386c/cpumem.c, the handler table on 0xE8000/0xF8000 with the gate clear); the shadow is
// qemu-pc98's f8000_ram. The backend addresses (the pack at pack_base, the shadow at
// pack_base + 1 MiB + 0x58000) are this core's SDRAM layout, not hardware facts: the facts
// are "no store reaches ROM" and "the gated store is read back".

`default_nettype none

module tb_pc9821_dma_rom_store;
  // pc9821_memory_subsystem's pack-download hold: no boot-ROM download under the OSD Reset
  // level here (tb_pc9821_boot0_load drives that), so the level is low and the hold unread.
  wire hps_apply_reset = 1'b0;
  wire pack_load_hold;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg [3:0] top_bank = 4'd8;
  reg ide_rom_enable = 1;   // 0x053D bit 4: the 0xD8000 option-ROM window shown (case R4)
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
  reg [31:0] pack_base = 32'h0200_0000;   // directly above the 32 MiB of guest RAM (whole MiB, as pc9821_system's)
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
  integer ti;
  initial for (ti = 0; ti < 16384; ti = ti + 1) tram[ti] = 8'h00;
  always @(posedge clk) begin
    if (tram_we) begin
      tram[tram_addr] <= tram_din;
      tram_dout <= tram_din;
    end else tram_dout <= tram[tram_addr];
  end
  // The CG window's byte port (0xA4000-0xA4FFF): a 32-position store standing in for the
  // GDC's class table, written on cg_win_we and read one cycle after cg_win_rd at the
  // position cg_win_byte_sel names ({page, row}; pc9821_cg owns which glyph byte that is,
  // and port 0xA9 reads the same store). Its own semantics are tb_pc9821_cg_window's; here it
  // only shows WHERE a byte went.
  wire [4:0] cg_win_byte_sel;
  wire cg_win_rd;
  reg [7:0] cg_win_dout = 0;
  wire [7:0] cg_win_din;
  wire cg_win_we;
  reg [7:0] cg_store [0:31];
  always @(posedge clk) begin
    if (cg_win_we) cg_store[cg_win_byte_sel] <= cg_win_din;
    if (cg_win_rd) cg_win_dout <= cg_store[cg_win_byte_sel];
  end
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

  reg        gvram_timing_xe10 = 0, gvram_gfx_scan_on = 0, gvram_crt31k = 0;   // OSD I/O timing Fast
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
  // ---- THE REAL uPD71071 ENGINE drives the subsystem's DMA bus-master port ----
  // The address load, its direction and the request come from pc9821_dmac as pc9821_iobus
  // wires them into pc9821_system (mem_addr_nx/mem_load/mem_load_we/mem_we/mem_req), so the
  // route is decoded in the engine's own load cycle, not a bench task's.
  reg         dsel = 1'b0, dwr = 1'b0;
  reg   [4:0] didx = 5'd0;
  reg   [7:0] ddin = 8'd0;
  wire  [7:0] ddout, ddout_comb;
  reg   [3:0] drq = 4'd0;
  wire  [3:0] dack;
  wire        dev_we, dev_stb, dev_tc;
  wire  [1:0] dev_ch;
  wire  [7:0] dev_dout;
  reg   [7:0] dev_din = 8'h00;
  wire [31:0] dma_addr, dma_addr_nx, dma_din;
  wire        dma_load, dma_load_write, dma_write, dma_valid;
  wire  [3:0] dma_be;
  wire        dma_ready, dma_resp_valid;
  wire [31:0] dma_dout;
  // The DMA byte's post-window-0 name, for the external snoop (pc9821_system); unread here.
  wire [31:0] dma_snoop_addr;
  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_dmac u_dmac (
    .clk(clk), .reset(reset),
    .sel(dsel), .write(dwr), .idx(didx), .din(ddin), .dout(ddout), .dout_comb(ddout_comb),
    .dev_drq(drq), .dev_dack(dack), .dev_we(dev_we), .dev_stb(dev_stb),
    .dev_tc(dev_tc), .dev_ch(dev_ch), .dev_dout(dev_dout), .dev_din(dev_din),
    .mem_addr(dma_addr), .mem_addr_nx(dma_addr_nx), .mem_load(dma_load),
    .mem_load_we(dma_load_write), .mem_we(dma_write), .mem_be(dma_be), .mem_din(dma_din),
    .mem_dout(dma_dout), .mem_req(dma_valid), .mem_ready(dma_ready),
    .mem_resp_valid(dma_resp_valid), .mem_tc()
  );
  /* verilator lint_on PINCONNECTEMPTY */
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
  // The PEGC view select (pc9821_crtc's mode2_256col):
  // 0 = the pre-PEGC decode this bench drives; the PEGC arms are tb_pc9821_memmap_ref's. A reg
  // because the in-flight mode-change cases below write it (port 0x6A) while a DMA byte waits.
  reg  pegc_256 = 1'b0;
  // The 16-colour select (pc9821_crtc's mode2_16color, port 0x6A FF2 num 0): 0 = the digital
  // mode the machine resets to, where 0xE0000-0xE7FFF is open bus (pc9821_memory_map
  // e_plane_nc). A reg because case I switches it.
  reg  mode2_16color = 1'b0;
  // PEGC packed scanout's fourth-requester port,
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
  reg [31:0] b_mem [bit [29:0]];   // the whole backend, by dword address (no aliasing)
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
  function automatic [31:0] be_mask(input [3:0] be);
    be_mask = {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
  endfunction
  function automatic [31:0] b_word(input [31:0] a);
    b_word = b_mem.exists(a[31:2]) ? b_mem[a[31:2]] : 32'h0000_0000;
  endfunction

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
              b_mem[b_cap_addr[31:2]] = b_word(b_cap_addr) & ~be_mask(b_cap_be) |
                                         b_cap_din & be_mask(b_cap_be);
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
          mem_dout <= b_word(b_resp_addr);
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

  task automatic reg_wr(input [4:0] i, input [7:0] d);
    begin
      @(negedge clk); dsel = 1; dwr = 1; didx = i; ddin = d;
      @(negedge clk); dsel = 0; dwr = 0;
    end
  endtask

  // The bytes the engine hands the device (memory-to-port) and the strobes it takes.
  reg  [7:0] dev_got;
  integer    dev_push, tc_seen;
  always @(posedge clk) begin
    if (dev_stb && dev_we) begin dev_got <= dev_dout; dev_push <= dev_push + 1; end
    if (dev_tc) tc_seen <= tc_seen + 1;
  end

  // One byte on channel 0 through the engine: master clear, the mode (0x04 = port to
  // memory, 0x08 = memory to port), the 24-bit address (low/high through the flip-flop,
  // then the 0x27 bank byte, index 19 = channel 0), a count of 0 (one byte, N+1), clear the
  // masks and raise DRQ until terminal count; then the engine must be idle again.
  task automatic dma_one(input [23:0] a, input [7:0] mode, input [7:0] b);
    integer g;
    begin
      reg_wr(5'd13, 8'h00);
      reg_wr(5'd12, 8'h00);
      reg_wr(5'd11, mode);
      reg_wr(5'd0, a[7:0]);
      reg_wr(5'd0, a[15:8]);
      reg_wr(5'd19, a[23:16]);
      reg_wr(5'd1, 8'h00);
      reg_wr(5'd1, 8'h00);
      dev_din = b;
      tc_seen = 0; dev_push = 0;
      reg_wr(5'd14, 8'h00);
      @(negedge clk); drq[0] = 1'b1;
      g = 0;
      while (tc_seen == 0 && g < 400) begin @(negedge clk); g = g + 1; end
      drq[0] = 1'b0;
      if (tc_seen == 0) $fatal(1, "TB_PC9821_DMA_ROM_STORE: FAIL (the DMA byte at %06x never reached terminal count)", a);
      g = 0;
      while (u_dmac.state != 3'd0 && g < 400) begin @(negedge clk); g = g + 1; end
      if (u_dmac.state != 3'd0) $fatal(1, "TB_PC9821_DMA_ROM_STORE: FAIL (the engine did not return to idle after %06x)", a);
      repeat (20) @(negedge clk);
    end
  endtask

  task automatic cpu_read(input [31:0] addr, output [31:0] rd);
    integer g, seen, hold, resps;
    begin
      cpu_addr = addr; cpu_be = 4'hF; cpu_burstcount = 8'd1; cpu_line_read = 1'b0;
      cpu_write = 1'b0; cpu_din = 32'd0; cpu_valid = 1'b1;
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
      if (!seen) $fatal(1, "TB_PC9821_DMA_ROM_STORE: FAIL (the CPU read at %08x was never accepted)", addr);
      for (g = 0; g < 40; g = g + 1) begin
        @(negedge clk);
        if (cpu_resp_valid) begin resps = resps + 1; rd = cpu_dout; end
      end
      if (resps != 1) begin
        $display("FAIL the CPU read at %08x saw %0d response(s)", addr, resps);
        errors = errors + 1;
      end
    end
  endtask

  // The backend's write commits since `c0`: exactly `n`, the last at `addr`/`be`.
  integer wr_commits;
  always @(posedge clk) if (reset) wr_commits <= 0;
                        else if (b_state == B_RUN && b_cnt == 3'd0 && b_cap_write) wr_commits <= wr_commits + 1;
  task automatic expect_writes(input [8*48-1:0] tag, input integer c0, input integer n,
                               input [31:0] addr, input [3:0] be);
    begin
      if (wr_commits != c0 + n) begin
        $display("FAIL %0s: %0d backend write(s), want %0d (last at %08x)", tag, wr_commits - c0, n,
                 b_c_addr[(b_commits - 1) & 7]);
        errors = errors + 1;
      end else if (n > 0 && (b_c_addr[(b_commits - 1) & 7] !== addr ||
                             b_c_be[(b_commits - 1) & 7] !== be || !b_c_wr[(b_commits - 1) & 7])) begin
        $display("FAIL %0s: the backend write went to %08x be %b, want %08x be %b", tag,
                 b_c_addr[(b_commits - 1) & 7], b_c_be[(b_commits - 1) & 7], addr, be);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_DMA_ROM_STORE: watchdog timeout (no verdict reached)");
  end

// ==== CHECKS ====
  // This bench's pack_base is 0x02000000; the shadow is pack_base + 1 MiB + 0x58000
  // (pc9821_memory_subsystem fw_shadow_base), the main BIOS's 0xE8000 is pack + 0x10000
  // (pc9821_memory_map lo_bios_lower).
  localparam [31:0] SHADOW = 32'h0200_0000 + 32'h0010_0000 + 32'h0005_8000;   // 0x02158000

  reg [31:0] rd;
  integer cw;
  integer g;
  initial begin
    dev_push = 0; tc_seen = 0;
    reset = 1;
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);
    ioctl_download = 1;
    send_word(27'd0, 16'hBEEF);
    repeat (2) @(posedge clk);
    ioctl_download = 0;
    g = 0;
    while (!rom_ready && g < 400) begin @(negedge clk); g = g + 1; end
    if (!rom_ready || !cpu_run || load_error)
      $fatal(1, "TB_PC9821_DMA_ROM_STORE: FAIL (the pack download did not release the CPU)");
    repeat (4) @(negedge clk);
    // The main BIOS's byte at 0xE8010 (pack + 0x10010), for the read control R7.
    b_mem[30'h0201_0010 >> 2] = 32'h0000_0077;

    // ---- R1: control, a DMA byte to RAM commits there ----
    cw = wr_commits;
    dma_one(24'h00_2001, 8'h04, 8'h5C);
    expect_writes("R1 RAM 0x2001", cw, 1, 32'h0000_2001, 4'b0010);

    // ---- R2: the main BIOS ROM 0xE8010: the store is discarded ----
    cw = wr_commits;
    dma_one(24'h0E_8010, 8'h04, 8'hA1);
    expect_writes("R2 BIOS ROM 0xE8010", cw, 0, 32'h0, 4'h0);

    // ---- R3: 0xF8E90 with 0x053D bit 1 clear: ROM, the store is discarded ----
    top_bank = 4'd9; top_shadow_en = 1'b1; bios_ram_gate = 1'b0;
    cw = wr_commits;
    dma_one(24'h0F_8E90, 8'h04, 8'hA2);
    expect_writes("R3 0xF8E90 gate clear", cw, 0, 32'h0, 4'h0);
    if (dut.fw_shadow_dirty !== 1'b0) begin
      $display("FAIL R3: a discarded store marked the shadow written"); errors = errors + 1;
    end

    // ---- R4: the 0xD8000 option-ROM window (0x053D bit 4 set, bank 0): discarded ----
    cw = wr_commits;
    dma_one(24'h0D_8100, 8'h04, 8'hA3);
    expect_writes("R4 option ROM 0xD8100", cw, 0, 32'h0, 4'h0);

    // ---- R5: the SOUND.ROM window 0xCC100: discarded ----
    cw = wr_commits;
    dma_one(24'h0C_C100, 8'h04, 8'hA4);
    expect_writes("R5 SOUND.ROM 0xCC100", cw, 0, 32'h0, 4'h0);

    // ---- R6: 0xF8E90 with the gate open: the shadow takes it and is read back ----
    bios_ram_gate = 1'b1;
    cw = wr_commits;
    dma_one(24'h0F_8E90, 8'h04, 8'h3C);
    expect_writes("R6 0xF8E90 gate open (the shadow)", cw, 1, SHADOW + 32'h0E90, 4'b0001);
    if (dut.fw_shadow_dirty !== 1'b1) begin
      $display("FAIL R6: the gated DMA store did not mark the shadow written"); errors = errors + 1;
    end
    cpu_read(32'h000F_8E90, rd);
    if (rd[7:0] !== 8'h3C) begin
      $display("FAIL R6: the CPU reads %02x at 0xF8E90 after the DMA store, want 3C", rd[7:0]);
      errors = errors + 1;
    end
    bios_ram_gate = 1'b0; top_bank = 4'd8; top_shadow_en = 1'b0;

    // ---- R7: control, a memory-to-port DMA read of 0xE8010 returns the pack byte ----
    cw = wr_commits;
    dma_one(24'h0E_8010, 8'h08, 8'h00);
    expect_writes("R7 DMA read of 0xE8010", cw, 0, 32'h0, 4'h0);
    if (dev_push != 1 || dev_got !== 8'h77) begin
      $display("FAIL R7: the device got %0d byte(s), last %02x, want one 77", dev_push, dev_got);
      errors = errors + 1;
    end

// ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_DMA_ROM_STORE: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_DMA_ROM_STORE: FAIL (%0d errors)", errors);
    end
  end

endmodule

`default_nettype wire

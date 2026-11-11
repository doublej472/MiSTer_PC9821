`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DMA_ROUTE: a uPD71071 bus-master byte goes where a CPU byte access at the same address goes, in both directions - the real Xe10 lands the DMA byte exactly where the CPU's lands in every window it was measured in (docs/probes/DMAROUTE-XE10.TXT, DMA=CPU in all 11 cases), as NP2kai's MEMP_WRITE8/MEMP_READ8 dispatch through the CPU's handler table (mem/dmax86.c, i386c/cpumem.c memfn0): with a 0x043F EMS page selected a DMA store to 0xB0040 commits to the EMS page (where the CPU's store at that address commits and its read finds it) and a DMA read there returns the page byte, while the unmapped EMS state drops the store and reads 0xFF; in 256-colour mode 0xA8000 and 0xB0000 are the PEGC packed banks (VGARD8's {bank, offset[14:0]} splice, bank A at 0xE0004, bank B at 0xE0006), 0xB8000 and the packed windows in plane mode are not connected (store dropped, read 0xFF - memnc), and 0xE0000 is the register file, so a DMA store to 0xE0006 sets bank B and moves the next DMA byte to that bank, and DMA stores of the capture's P4 bytes EB 09 00 00 to 0xE0004-0xE0007 read back 2B 00 00 00 to the CPU and the DMA (docs/probes/DMAROUTE-XE10.TXT P4); a bank write landing while a packed DMA byte is held does not move it (one commit, at the bank it was presented under, its payload unmoved); window 0 (0x0461) moves a DMA address in 0x80000-0x9FFFF as it moves a CPU's - at 0x0A to the window's own RAM page, neither plane B nor the text RAM (the capture's W1/W2: the window reads the bytes back while 0xA8100/0xA1000 and the covered RAM keep theirs), and to plain RAM at 0x10, the external snoop naming the moved address; a DMA store into the CG window at 0xA4000-0xA401F reaches the CG byte port at exactly the positions the CPU's stores reach, the glyph lines holding the transferred odd bytes and the window reading them back (the capture's G1: 0900503120FCF6D600511FC600B902A4 in both views); and with the 15-16 MiB system space on, 0xFA0000-0xFFFFFF aliases the low window (a DMA store to 0xFA8017 reaches plane B) while 0xF80000-0xF9FFFF drops a store and reads 0xFF. The intensity plane at 0xE0000 follows the 16-colour select (port 0x6A FF2 num 0) for a DMA byte as for a CPU access: in the digital mode a DMA store to 0xE0004 is dropped and a DMA or CPU read answers 0xFF (the machine's digital-mode slot, docs/probes/DMAROUTE-XE10.TXT P4 view V1; NP2kai memnc there while VOPBIT_ANALOG is clear), in the 16-colour mode the DMA byte lands in the plane, and a digital-mode store never reaches it. The default map is unchanged: RAM, an unmoved 0x80000, a plane and the text RAM. FAIL-FIRST against the physical-address backend arm, which sends every EMS, PEGC, CG and window-0 byte to the SDRAM at its own address.
//
// WHY THIS EXISTS. The memory subsystem's DMA port classed a byte by
// its physical address alone: the plane windows and the text RAM were routed, but an EMS page,
// the PEGC banks and registers and a moved window 0 were not, so such a byte went to the SDRAM
// under the window, where the CPU does not read it.
//
// WHERE THE EXPECTATIONS COME FROM. First the machine: docs/probes/DMAROUTE-XE10.TXT
// (tools/hwprobe/dmaroute, decoded by dmaroute_decode.py) runs each case with a CPU copy and a
// floppy DMA and reads every view after both; in all 11 cases the views are byte-identical
// (DMA=CPU yes). Its cases E1/E2 (the EMS page and the unmapped state), P1-P4 (the packed banks,
// B8000, the register file), W1-W3 (window 0 at 0x0A and 0x10) and G1 (the CG window) are the
// sections below of the same names; the exact bytes are cited where a section checks them.
// Then NP2kai's transfer loop (mem/dmax86.c `MEMP_WRITE8(ch->adrs.d,
// ...)`, `MEMP_READ8(ch->adrs.d)`) calls memp_write8/memp_read8, whose first-MiB arm is the CPU's
// handler table (i386c/cpumem.c `memfn0.wr8[address >> 15](address, value);`); with VOPBIT_VGA set
// that table's 0xA8000/0xB0000/0xB8000/0xE0000 slots are memvga0_wr8/memvga1_wr8/memnc_wr8/
// memvgaio_wr8 (i386c/cpumem.c's VOPBIT_VGA arm; memnc_rd8 `return(0xff);`), memvga0_wr8 drops the
// store in plane mode (mem/memvga.c), and memvgaio_wr8 stores 0xE0004-0xE0007 as the bank bytes.
// NP2kai has no 0x0461 window; qemu-pc98's pc98_dma_write_memory/read_memory use
// physical_memory_write/read (hw/dma/pc98-dma.c), on the system address space whose low MiB holds
// the window alias (hw/i386/pc98-mem.c mem_apply_window), so the window applies to a DMA address.
// The EMS page's three states are the machine's own (pc9821_memory_map's ems_state header). The
// backend placements (EMS_PAGE, PEG_BASE) are this core's SDRAM layout, not hardware facts; the
// facts are that the byte reaches the page / the bank, which the CPU accesses at the same
// address then see.

`default_nettype none

module tb_pc9821_dma_route;
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
  // The DMA byte's post-window-0 name, for the external snoop (pc9821_system).
  wire [31:0] dma_snoop_addr;
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
  // The 16-colour select (pc9821_crtc's mode2_16color, port 0x6A FF2 num 0): 0 = the digital
  // mode the machine resets to, where 0xE0000-0xE7FFF is open bus (pc9821_memory_map
  // e_plane_nc). A reg because case I switches it.
  reg  mode2_16color = 1'b0;
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

  // The snoop name the subsystem gives each accepted DMA byte (sampled on the accept).
  reg [31:0] last_snoop;
  always @(posedge clk) if (dma_valid && dma_ready) last_snoop <= dma_snoop_addr;

  // One DMA byte, the way pc9821_dmac presents it: one-hot lane from the address, the byte
  // replicated across the lanes, the request held until its accept and dropped after it.
  task automatic dma_byte(input [31:0] addr, input is_write, input [7:0] b, output [31:0] rd);
    integer g, seen, resps;
    begin
      dma_addr  = addr;
      dma_din   = {4{b}};
      dma_be    = 4'b0001 << addr[1:0];
      dma_write = is_write;
      @(negedge clk);   // the DMAC's address load: one cycle before the request
      dma_valid = 1'b1;
      seen = 0; resps = 0; rd = 32'hXXXX_XXXX;
      g = 0;
      while (!seen && g < 400) begin
        @(posedge clk);
        if (dma_valid && dma_ready) seen = 1;
        if (dma_resp_valid) begin resps = resps + 1; rd = dma_dout; end
        @(negedge clk);
        if (seen) dma_valid = 1'b0;
        g = g + 1;
      end
      if (!seen) $fatal(1, "TB_PC9821_DMA_ROUTE: FAIL (the DMA byte at %08x was never accepted)", addr);
      for (g = 0; g < 40; g = g + 1) begin
        @(posedge clk);
        if (dma_resp_valid) begin resps = resps + 1; rd = dma_dout; end
      end
      @(negedge clk);
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

  task automatic cpu_access(input [31:0] addr, input is_write, input [3:0] be, input [31:0] din,
                            output [31:0] rd);
    integer g, seen, hold, resps;
    begin
      cpu_addr = addr; cpu_be = be; cpu_burstcount = 8'd1; cpu_line_read = 1'b0;
      cpu_write = is_write; cpu_din = din; cpu_valid = 1'b1;
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
      cpu_write = 1'b0;
      if (!seen) $fatal(1, "TB_PC9821_DMA_ROUTE: FAIL (the CPU access at %08x was never accepted)", addr);
      for (g = 0; g < 40; g = g + 1) begin
        @(negedge clk);
        if (cpu_resp_valid) begin resps = resps + 1; rd = cpu_dout; end
      end
      if (resps != (is_write ? 0 : 1)) begin
        $display("FAIL the CPU %s at %08x saw %0d response(s)", is_write ? "store" : "read", addr, resps);
        errors = errors + 1;
      end
    end
  endtask

  task automatic cpu_read(input [31:0] addr, output [31:0] rd);
    cpu_access(addr, 1'b0, 4'hF, 32'd0, rd);
  endtask
  task automatic cpu_store8(input [31:0] addr, input [7:0] b);
    reg [31:0] unused_rd;
    cpu_access({addr[31:2], 2'b00}, 1'b1, 4'b0001 << addr[1:0], {4{b}}, unused_rd);
  endtask

  task automatic expect_byte(input [8*48-1:0] tag, input [31:0] got, input [1:0] lane,
                             input [7:0] want);
    begin
      if (got[lane*8 +: 8] !== want) begin
        $display("FAIL %0s: lane %0d read %02x, want %02x (word %08x)", tag, lane,
                 got[lane*8 +: 8], want, got);
        errors = errors + 1;
      end
    end
  endtask

  // The backend's commit record since `before`: exactly `n` commits, the last at `addr`/`be`.
  task automatic expect_commits(input [8*48-1:0] tag, input integer c0, input integer n,
                                input [31:0] addr, input [3:0] be);
    begin
      if (b_commits != c0 + n) begin
        $display("FAIL %0s: %0d backend commit(s), want %0d", tag, b_commits - c0, n);
        errors = errors + 1;
      end else if (n > 0 && (b_c_addr[(b_commits - 1) & 7] !== addr ||
                             b_c_be[(b_commits - 1) & 7] !== be)) begin
        $display("FAIL %0s: the backend commit went to %08x be %b, want %08x be %b", tag,
                 b_c_addr[(b_commits - 1) & 7], b_c_be[(b_commits - 1) & 7], addr, be);
        errors = errors + 1;
      end
    end
  endtask

  task automatic expect_plane(input [8*48-1:0] tag, input [31:0] addr, input [7:0] want);
    reg [31:0] w;
    begin
      cpu_read({addr[31:2], 2'b00}, w);
      expect_byte(tag, w, addr[1:0], want);
    end
  endtask

// ==== CHECKS ====
  initial begin
    #80_000_000;
    $fatal(1, "TB_PC9821_DMA_ROUTE: watchdog timeout (no verdict reached)");
  end

  // The backend placement constants are the subsystem's layout (pc9821_memory_subsystem
  // ems_page_base / peg_base = pack_base + 1 MiB + 0x48000 / 0x80000), with this bench's
  // pack_base 0x02000000. The ROUTE is the reference fact: the EMS page and the PEGC bank
  // are where NP2kai's handler table sends the byte (see the header).
  localparam [31:0] EMS_PAGE = 32'h0200_0000 + 32'h0010_0000 + 32'h0004_8000;   // 0x02148000
  localparam [31:0] PEG_BASE = 32'h0200_0000 + 32'h0010_0000 + 32'h0008_0000;   // 0x02180000

  function automatic [3:0] pegc_bank_a_now();
    pegc_bank_a_now = dut.pegc_bank_a;
  endfunction

  reg [31:0] rd;
  integer cb;
  integer g;
  initial begin
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
      $fatal(1, "TB_PC9821_DMA_ROUTE: FAIL (the pack download did not release the CPU)");
    repeat (4) @(negedge clk);

    // ---- D: the default map is unchanged: RAM, a plane, the text RAM, 0x80000 unmoved ----
    cb = b_commits;
    dma_byte(32'h0000_2001, 1'b1, 8'h5C, rd);
    expect_commits("D RAM 0x2001", cb, 1, 32'h0000_2001, 4'b0010);
    cb = b_commits;
    dma_byte(32'h0008_0042, 1'b1, 8'h5D, rd);
    expect_commits("D 0x80042 with window 0 at the identity", cb, 1, 32'h0008_0042, 4'b0100);
    if (last_snoop !== 32'h0008_0042) begin
      $display("FAIL D the snoop name of 0x80042 is %08x", last_snoop); errors = errors + 1;
    end
    cb = b_commits;
    dma_byte(32'h000A_8011, 1'b1, 8'h5E, rd);
    expect_commits("D plane B 0xA8011 (no backend)", cb, 0, 32'h0, 4'h0);
    expect_plane("D plane B 0xA8011", 32'h000A_8011, 8'h5E);
    dma_byte(32'h000A_0011, 1'b1, 8'h5F, rd);
    if (tram[14'h0011] !== 8'h5F) begin
      $display("FAIL D text RAM 0xA0011 holds %02x, want 5F", tram[14'h0011]); errors = errors + 1;
    end

    // ---- E1: an EMS page (0x043F 0x22) over 0xB0000: the byte is the page's ----
    // NP2kai: memfn0's 0xB0000 slot is the EMS window's handler while it is mapped; the map
    // sends a CPU byte at B0040 to the page (ems_page), so the DMA byte goes there too.
    ems_state = 2'd1;
    repeat (2) @(negedge clk);
    cb = b_commits;
    dma_byte(32'h000B_0040, 1'b1, 8'hE5, rd);
    expect_commits("E1 DMA store B0040 -> the EMS page", cb, 1, EMS_PAGE + 32'h40, 4'b0001);
    expect_plane("E1 CPU read B0040 under the page", 32'h000B_0040, 8'hE5);
    cb = b_commits;
    cpu_store8(32'h000B_0043, 8'h7A);
    expect_commits("E1 CPU store B0043 -> the EMS page", cb, 1, EMS_PAGE + 32'h40, 4'b1000);
    dma_byte(32'h000B_0043, 1'b0, 8'h00, rd);
    expect_byte("E1 DMA read B0043 under the page", rd, 2'd3, 8'h7A);
    // ---- E2: the unmapped state (0x043F 0x2x other): reads 0xFF, stores dropped ----
    ems_state = 2'd2;
    repeat (2) @(negedge clk);
    cb = b_commits;
    dma_byte(32'h000B_0050, 1'b1, 8'h33, rd);
    expect_commits("E2 DMA store B0050 unmapped (dropped)", cb, 0, 32'h0, 4'h0);
    dma_byte(32'h000B_0051, 1'b0, 8'h00, rd);
    expect_byte("E2 DMA read B0051 unmapped", rd, 2'd1, 8'hFF);
    expect_plane("E2 CPU read B0051 unmapped", 32'h000B_0051, 8'hFF);
    ems_state = 2'd0;
    repeat (2) @(negedge clk);
    expect_plane("E plane R B0040 untouched", 32'h000B_0040, 8'h00);
    expect_plane("E plane R B0050 untouched", 32'h000B_0050, 8'h00);

    // ---- P: 256-colour mode (0x6A 0x21): the PEGC handlers own the four windows ----
    // NP2kai i386c/cpumem.c VOPBIT_VGA arm: A8000 memvga0 (bank A), B0000 memvga1 (bank B),
    // B8000 memnc, E0000 memvgaio; the bank splice is VGARD8's `(mio1[p*2] & 15) << 15`.
    pegc_256 = 1'b1;
    repeat (2) @(negedge clk);
    cpu_store8(32'h000E_0004, 8'h03);   // bank A = 3
    cpu_store8(32'h000E_0006, 8'h05);   // bank B = 5
    cb = b_commits;
    dma_byte(32'h000A_8010, 1'b1, 8'h91, rd);
    expect_commits("P DMA store A8010 -> bank A 3", cb, 1, PEG_BASE + 32'h0001_8010, 4'b0001);
    dma_byte(32'h000B_0022, 1'b1, 8'h92, rd);
    expect_commits("P DMA store B0022 -> bank B 5", cb, 2, PEG_BASE + 32'h0002_8022, 4'b0100);
    expect_plane("P CPU read A8010 (bank A)", 32'h000A_8010, 8'h91);
    expect_plane("P CPU read B0022 (bank B)", 32'h000B_0022, 8'h92);
    cpu_store8(32'h000A_8013, 8'h6B);
    // The CPU's packed store is POSTED (pc9821_pegc_storebuf, drained within its 1 us combining
    // window); the DMA's read does not drain that buffer, so it is issued after the window.
    repeat (300) @(negedge clk);
    dma_byte(32'h000A_8013, 1'b0, 8'h00, rd);
    expect_byte("P DMA read A8013 (bank A)", rd, 2'd3, 8'h6B);
    // 0xB8000 is not connected in this mode
    cb = b_commits;
    dma_byte(32'h000B_8000, 1'b1, 8'h93, rd);
    expect_commits("P DMA store B8000 (not connected)", cb, 0, 32'h0, 4'h0);
    dma_byte(32'h000B_8001, 1'b0, 8'h00, rd);
    expect_byte("P DMA read B8001 (not connected)", rd, 2'd1, 8'hFF);
    // 0xE0000 is the register file: a DMA byte to E0006 sets bank B
    cb = b_commits;
    dma_byte(32'h000E_0006, 1'b1, 8'h07, rd);
    expect_commits("P DMA store E0006 (register, no backend)", cb, 0, 32'h0, 4'h0);
    cpu_read(32'h000E_0004, rd);
    expect_byte("P CPU read E0006 after the DMA store", rd, 2'd2, 8'h07);
    dma_byte(32'h000E_0004, 1'b0, 8'h00, rd);
    expect_byte("P DMA read E0004 (bank A register)", rd, 2'd0, 8'h03);
    cb = b_commits;
    dma_byte(32'h000B_0030, 1'b1, 8'h94, rd);
    expect_commits("P DMA store B0030 -> bank B 7", cb, 1, PEG_BASE + 32'h0003_8030, 4'b0001);
    // the plane-engine mode (0xE0100 bit 0): the packed windows are not connected
    cpu_store8(32'h000E_0100, 8'h01);
    cb = b_commits;
    dma_byte(32'h000A_8020, 1'b1, 8'h95, rd);
    expect_commits("P DMA store A8020 in plane mode (dropped)", cb, 0, 32'h0, 4'h0);
    dma_byte(32'h000A_8020, 1'b0, 8'h00, rd);
    expect_byte("P DMA read A8020 in plane mode", rd, 2'd0, 8'hFF);
    cpu_store8(32'h000E_0100, 8'h00);
    // A BANK WRITE WHILE A DMA BYTE IS IN FLIGHT does not move it: the byte presented under
    // bank A 3 commits once, at bank 3, with its payload held to the ack.
    cb = b_commits;
    b_payload_moves = 0;
    dma_addr = 32'h000A_8050; dma_din = {4{8'h96}}; dma_be = 4'b0001; dma_write = 1'b1;
    @(negedge clk);   // the DMAC's address load
    dma_valid = 1'b1;
    fork
      begin : held_dma
        g = 0;
        while (dma_valid && g < 400) begin
          @(posedge clk);
          if (dma_ready) begin @(negedge clk); dma_valid = 1'b0; end
          g = g + 1;
        end
      end
      cpu_store8(32'h000E_0004, 8'h09);   // bank A = 9, landing before the DMA byte's ack
    join
    if (pegc_bank_a_now() !== 4'd9) begin
      $display("FAIL P the in-flight bank write did not land (bank A %0d)", pegc_bank_a_now());
      errors = errors + 1;
    end
    repeat (20) @(negedge clk);
    expect_commits("P in-flight bank write: the byte keeps bank 3", cb, 1,
                   PEG_BASE + 32'h0001_8050, 4'b0001);
    if (b_payload_moves != 0) begin
      $display("FAIL P the backend payload moved under a held DMA byte (%0d)", b_payload_moves);
      errors = errors + 1;
    end
    // P4: the capture's register-file case. docs/probes/DMAROUTE-XE10.TXT P4 moves the sector's
    // first four bytes EB 09 00 00 to 0xE0004-0xE0007 in 256-colour mode and reads
    // `POST=2B000000` after the CPU run and after the DMA run alike (the bank registers keep
    // bits 5-0, the odd bytes read 0).
    dma_byte(32'h000E_0004, 1'b1, 8'hEB, rd);
    dma_byte(32'h000E_0005, 1'b1, 8'h09, rd);
    dma_byte(32'h000E_0006, 1'b1, 8'h00, rd);
    dma_byte(32'h000E_0007, 1'b1, 8'h00, rd);
    cpu_read(32'h000E_0004, rd);
    if (rd !== 32'h0000_002B) begin
      $display("FAIL P4 CPU read of E0004-E0007 after the DMA stores is %08x, the capture's POST reads 0000002b", rd);
      errors = errors + 1;
    end
    dma_byte(32'h000E_0004, 1'b0, 8'h00, rd);
    expect_byte("P4 DMA read E0004 (the capture's 2B)", rd, 2'd0, 8'h2B);
    dma_byte(32'h000E_0005, 1'b0, 8'h00, rd);
    expect_byte("P4 DMA read E0005 (the capture's 00)", rd, 2'd1, 8'h00);
    pegc_256 = 1'b0;
    repeat (2) @(negedge clk);
    expect_plane("P plane B A8010 untouched by the packed bytes", 32'h000A_8010, 8'h00);

    // ---- I: the intensity plane at 0xE0000 is a 16-colour-mode window for a DMA byte too ----
    // The DMA goes through the CPU's handler table (NP2kai mem/dmax86.c MEMP_WRITE8/MEMP_READ8),
    // whose 0xE0000 slot memm_vram makes memnc while VOPBIT_ANALOG is clear (i386c/cpumem.c);
    // the CPU's digital-mode 0xE0004 reads FF and keeps no store on the machine
    // (docs/probes/DMAROUTE-XE10.TXT case P4 view V1, `ORIG=FFFFFFFF PRE=FFFFFFFF POST=FFFFFFFF`).
    cb = b_commits;
    dma_byte(32'h000E_0004, 1'b1, 8'h6E, rd);
    expect_commits("I digital: DMA store E0004 (dropped, no backend)", cb, 0, 32'h0, 4'h0);
    dma_byte(32'h000E_0004, 1'b0, 8'h00, rd);
    expect_byte("I digital: DMA read E0004 (open bus)", rd, 2'd0, 8'hFF);
    expect_plane("I digital: CPU read E0004 (open bus)", 32'h000E_0004, 8'hFF);
    mode2_16color = 1'b1;   // the guest's OUT 0x6A,0x01
    repeat (2) @(negedge clk);
    expect_plane("I 16-colour: plane E E0004 untouched by the digital store", 32'h000E_0004, 8'h00);
    cb = b_commits;
    dma_byte(32'h000E_0005, 1'b1, 8'h6F, rd);
    expect_commits("I 16-colour: DMA store E0005 (the plane, no backend)", cb, 0, 32'h0, 4'h0);
    expect_plane("I 16-colour: CPU read E0005", 32'h000E_0005, 8'h6F);
    dma_byte(32'h000E_0005, 1'b0, 8'h00, rd);
    expect_byte("I 16-colour: DMA read E0005", rd, 2'd1, 8'h6F);
    mode2_16color = 1'b0;   // OUT 0x6A,0x00
    repeat (2) @(negedge clk);
    dma_byte(32'h000E_0005, 1'b1, 8'h70, rd);
    dma_byte(32'h000E_0005, 1'b0, 8'h00, rd);
    expect_byte("I digital again: DMA read E0005 (open bus)", rd, 2'd1, 8'hFF);
    mode2_16color = 1'b1;
    repeat (2) @(negedge clk);
    expect_plane("I 16-colour again: E0005 keeps 6F (the digital store dropped)", 32'h000E_0005, 8'h6F);
    mode2_16color = 1'b0;
    repeat (2) @(negedge clk);

    // ---- W: window 0 (0x0461) moves a DMA address in 0x80000-0x9FFFF as it moves a CPU's ----
    // docs/probes/DMAROUTE-XE10.TXT W1/W2 (0x0461=0x0A), DMA = CPU in both: the bytes stored
    // through 0x88100 and 0x81000 read back through the window (V0 -> D) while plane B at
    // 0xA8100 and the text RAM at 0xA1000 keep their prefills (V1 -> P1) and so does the RAM the
    // window covers (V2 -> P2): the window's page is RAM of its own, here the backend at the
    // translated 0xA8xxx/0xA0xxx, and neither a plane nor the text RAM is touched.
    win0_sel = 8'h0A;   // 0x80000 -> 0xA0000: the window's own RAM page
    repeat (2) @(negedge clk);
    cb = b_commits;
    dma_byte(32'h0008_8115, 1'b1, 8'hA1, rd);
    expect_commits("W1 0x0A: DMA store 0x88115 -> RAM 0xA8115", cb, 1, 32'h000A_8115, 4'b0010);
    if (last_snoop !== 32'h000A_8115) begin
      $display("FAIL W1 0x0A: the snoop name of the byte is %08x, want 000a8115", last_snoop);
      errors = errors + 1;
    end
    expect_plane("W1 0x0A: CPU read 0x88115 (the capture's V0)", 32'h0008_8115, 8'hA1);
    cb = b_commits;
    cpu_store8(32'h0008_8116, 8'hB1);
    expect_commits("W1 0x0A: CPU store 0x88116 -> RAM 0xA8116", cb, 1, 32'h000A_8114, 4'b0100);
    dma_byte(32'h0008_8116, 1'b0, 8'h00, rd);
    expect_byte("W1 0x0A: DMA read 0x88116", rd, 2'd2, 8'hB1);
    cb = b_commits;
    tram[14'h1024] = 8'h3D;
    dma_byte(32'h0008_1024, 1'b1, 8'hA2, rd);
    expect_commits("W2 0x0A: DMA store 0x81024 -> RAM 0xA1024", cb, 1, 32'h000A_1024, 4'b0001);
    if (tram[14'h1024] !== 8'h3D) begin
      $display("FAIL W2 0x0A: text RAM 0x1024 holds %02x after a DMA store to 0x81024, want 3D (the capture's V1 -> P1)", tram[14'h1024]);
      errors = errors + 1;
    end
    dma_byte(32'h0008_1024, 1'b0, 8'h00, rd);
    expect_byte("W2 0x0A: DMA read 0x81024 (the capture's V0)", rd, 2'd0, 8'hA2);
    expect_plane("W2 0x0A: CPU read 0x81024", 32'h0008_1024, 8'hA2);
    cb = b_commits;
    dma_byte(32'h0008_4024, 1'b1, 8'hA4, rd);   // 0x84024 -> RAM 0xA4024, not the CG window
    expect_commits("W 0x0A: DMA store 0x84024 -> RAM 0xA4024", cb, 1, 32'h000A_4024, 4'b0001);
    win0_sel = 8'h10;   // 0x80000 -> 0x100000: plain RAM
    repeat (2) @(negedge clk);
    cb = b_commits;
    dma_byte(32'h0008_0031, 1'b1, 8'hA3, rd);
    expect_commits("W 0x10: DMA store 0x80031 -> 0x100031", cb, 1, 32'h0010_0031, 4'b0010);
    if (last_snoop !== 32'h0010_0031) begin
      $display("FAIL W 0x10: the snoop name of the byte is %08x, want 00100031", last_snoop);
      errors = errors + 1;
    end
    expect_plane("W 0x10: CPU read 0x100031", 32'h0010_0031, 8'hA3);
    win0_sel = 8'h08;
    repeat (2) @(negedge clk);
    expect_plane("W1 plane B A8115 untouched by the window (the capture's V1)", 32'h000A_8115, 8'h00);
    expect_plane("W1 RAM 0x88115 untouched by the window (the capture's V2)", 32'h0008_8115, 8'h00);
    expect_plane("W2 RAM 0x81024 untouched by the window (the capture's V2)", 32'h0008_1024, 8'h00);

    // ---- S: the 15-16 MiB system space (0x043B bit 2 clear, sys16m_en): 0xFA0000-0xFFFFFF
    //      aliases the low 0xA0000-0xFFFFF (NP2kai memp_write8's 0xF00000 arm, memfnf -> memsys_wr8
    //      into the low table) and 0xF80000-0xF9FFFF answers nothing ----
    cb = b_commits;
    dma_byte(32'h00FA_8017, 1'b1, 8'hC1, rd);
    expect_commits("S DMA store 0xFA8017 (plane B alias, no backend)", cb, 0, 32'h0, 4'h0);
    expect_plane("S CPU read A8017 after the alias store", 32'h000A_8017, 8'hC1);
    dma_byte(32'h00F8_0010, 1'b1, 8'hC2, rd);
    expect_commits("S DMA store 0xF80010 (the hole, dropped)", cb, 0, 32'h0, 4'h0);
    dma_byte(32'h00F8_0010, 1'b0, 8'h00, rd);
    expect_byte("S DMA read 0xF80010 (the hole)", rd, 2'd0, 8'hFF);

    // ---- G1: the CG window (0xA4000-0xA4FFF), the capture's case G1 ----
    // docs/probes/DMAROUTE-XE10.TXT G1 (user glyph 0x7621 selected, DST=000A4000 LEN=20): after
    // the CPU run AND after the DMA run, the window's odd bytes A4001+2i (view V0) and port 0xA9
    // lines 0-15 (view V1) both read 0900503120FCF6D600511FC600B902A4 - the odd bytes of the
    // capture's SECTOR line - so the DMA byte lands where the CPU's lands (DMA=CPU yes). The
    // bench moves the same 32 bytes both ways and requires the same port contents, the odd bytes
    // at the port's {page 1, row i} positions (the CPU walk's byte_sel of A4001+2i), the window's
    // odd bytes reading them back, and no backend traffic.
    begin : g1
      reg [7:0] sector [0:31];
      reg [7:0] cpu_view [0:31];
      reg [255:0] sec_hex;
      integer i;
      sec_hex = 256'hEB09000049504C31202020FC31F68ED6BC0060510E1F8EC6BF0007B90002F3A4;   // SECTOR
      for (i = 0; i < 32; i = i + 1) sector[i] = sec_hex[255 - 8*i -: 8];
      for (i = 0; i < 32; i = i + 1) cg_store[i] = 8'h5A ^ i[7:0];   // a prefill unlike the sector
      cb = b_commits;
      for (i = 0; i < 32; i = i + 1) cpu_store8(32'h000A_4000 + i, sector[i]);
      for (i = 0; i < 32; i = i + 1) cpu_view[i] = cg_store[i];
      for (i = 0; i < 32; i = i + 1) cg_store[i] = 8'h5A ^ i[7:0];
      for (i = 0; i < 32; i = i + 1) dma_byte(32'h000A_4000 + i, 1'b1, sector[i], rd);
      expect_commits("G1 DMA stores to the CG window (no backend)", cb, 0, 32'h0, 4'h0);
      for (i = 0; i < 32; i = i + 1)
        if (cg_store[i] !== cpu_view[i]) begin
          $display("FAIL G1 CG port position %0d holds %02x after the DMA run, %02x after the CPU run",
                   i, cg_store[i], cpu_view[i]);
          errors = errors + 1;
        end
      for (i = 0; i < 16; i = i + 1)
        if (cg_store[16 + i] !== sector[2*i + 1]) begin
          $display("FAIL G1 CG line %0d (port 0xA9 view) holds %02x, the capture's V1 reads %02x",
                   i, cg_store[16 + i], sector[2*i + 1]);
          errors = errors + 1;
        end
      for (i = 0; i < 16; i = i + 1) begin
        dma_byte(32'h000A_4001 + 2*i, 1'b0, 8'h00, rd);
        expect_byte("G1 DMA read of A4001+2i", rd, (2*i + 1) & 3, sector[2*i + 1]);
        expect_plane("G1 CPU read of A4001+2i (the capture's V0)", 32'h000A_4001 + 2*i, sector[2*i + 1]);
      end
    end

// ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_DMA_ROUTE: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_DMA_ROUTE: FAIL (%0d errors)", errors);
    end
  end

endmodule

`default_nettype wire

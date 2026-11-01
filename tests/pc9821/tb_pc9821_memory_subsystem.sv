`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_MEMORY_SUBSYSTEM:
// ROM loading and bus arbitration: the CPU is held until the ROM has loaded, and the load/arbitration handshake grants the bus correctly afterwards. The absent ROM area at 0xC0000-0xD7FFF is a route of its own: a read returns all ones in z486's accept-then-respond phases with no backend transaction, an instruction fetch returns four all-ones words, and a store is swallowed. THE 12 KiB HOLE BETWEEN THE TEXT RAM AND THE PLANES, 0xA5000-0xA7FFF, is the same shape, because the machine reads 0xFF there and discards stores (docs/probes/VRAM.TXT:141-142): the direct address must not reach the backend, must answer all ones, and must swallow its stores, while 0xA4FFF stays the CG window's and 0xA8000 the B plane's, and the 0x0461 = 0x0A overlay keeps claiming the same 32 KiB. It also carries the JIS KU-BANK SWEEP: one JIS code from each bank of the FONT.ROM grid, driven through the real pack download, must land at the font store word the text scanout computes for that code and carry FONT.ROM's own bytes there, so a word offset that is a bit too narrow puts a whole ku bank at another bank's word and the log names the misplaced bank. THE 0x1E8E-GATED IDE WORK RAM AT 0xDA000-0xDBFFF IS THE MACHINE'S OWN GATE (docs/probes/SHADOWW.TXT:226-231: the 1E8E read-back runs FE FF FE through the 0x80/0x81/restore writes, the DA000 marker reads back FFFF under 0x80 and 5AA5 under 0x81, and the IDE ROM's work bytes reappear under 0x81): with the gate clear the window takes the absent route's own shape - all ones, stores swallowed, no backend transaction - and with it set the same address is ordinary RAM that takes the store at 0xDA000 and answers the read from it. THE TAIL ABOVE IT, 0xDC000-0xDFFFF, IS ABSENT IN BOTH GATE STATES (docs/probes/SHADOW.TXT:201-213 reads 0xFF over all 12 x 2 KiB blocks of the DA000..DFFFF region with the gate clear, ffblocks=000C; QEMU models the rest of the 0xD8000 window as rom_empty): all ones and swallowed stores whatever 0x1E8E holds, with the gate-ON state capture-pending (a marker write at 0xDC000 under 0x1E8E=0x81 settles it, probe2 /IDEGATE). THE DOWNLOAD GATE HAS NO LIVE ioctl TERM (docs/timing.md, the download gate): in the cycle the ioctl_download of a reload rises the CPU still runs and the loader does not own the backend, in the next cycle the CPU is held and the loader owns it, cpu_run rises in the second cycle after the download falls, a platform reset with the pack loaded keeps cpu_run high, and an out-of-range word keeps the CPU held after the download.


module tb_pc9821_memory_subsystem;
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
  reg [7:0] win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  // 0x043B bit 2, the 15-16 MiB system-space window. The machine's reset value is ON,
  // so these benches drive the same state the card comes up in.
  reg  sys16m_en = 1'b1;
  reg [31:0] pack_base = 32'h0200_0000;
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
  reg mem_ready = 1, mem_resp_valid = 0, mem_line_resp_valid = 0;
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

  // THE GVRAM NOW READS THE SHARED BACKEND, so this bench's backend must answer a READ with a
  // beat where every other route here answers only its own probe. pc9821_gvram's write-combining
  // buffer reads the target word ONCE on a plane-window store miss (the three planes the store
  // does not touch have to be carried into the merge), and a read miss prefetches up to
  // `mem_burstcount` consecutive words, which src/memory/sdram.v answers with ONE BEAT PER WORD.
  // The response is gated to the GVRAM's 256 KiB (gvram_base = pack_base + 1 MiB = 0x02080000, so
  // bits [31:18] = 0x082), so the TRAM / mapped-RAM / line probes above keep driving
  // mem_resp_valid themselves and this block never collides with them.
  reg [3:0] gv_rd_left = 4'd0;
  reg [1:0] gv_rd_st   = 2'd0;   // 0 idle, 1 beating, 2 the one-cycle tail that drops the strobe
  always @(posedge clk) begin
    case (gv_rd_st)
      2'd0: if (mem_valid && mem_ready && !mem_write && (mem_addr[31:18] == 14'h082)) begin
              mem_resp_valid <= 1'b1;
              mem_dout       <= 32'h0000_0000;
              gv_rd_st       <= (mem_burstcount <= 8'd1) ? 2'd2 : 2'd1;
              gv_rd_left     <= mem_burstcount - 4'd1;
            end
      2'd1: begin
              mem_resp_valid <= 1'b1;
              mem_dout       <= 32'h0000_0000;
              gv_rd_left     <= gv_rd_left - 4'd1;
              if (gv_rd_left == 4'd1) gv_rd_st <= 2'd2;
            end
      default: begin
              mem_resp_valid <= 1'b0;
              gv_rd_st       <= 2'd0;
            end
    endcase
  end

  integer errors = 0;
  integer gbeat = 0;
  // Coverage evidence for the decode sweep: a sweep that never sees a route
  // selected has proved nothing, so the sweep counts what it observed and the
  // check after it fails if any route was never exercised.
  integer saw_tram = 0, saw_cg = 0, saw_open = 0, saw_gvram = 0;
  integer writes = 0;
  integer w0 = 0;
  integer g0 = 0;
  integer font_writes = 0;
  reg [17:0] last_font_addr;
  reg [15:0] last_font_data;
  reg [31:0] last_write_addr, last_write_data;
  reg [3:0] last_write_be;
  always @(posedge clk) begin
    if (mem_valid && mem_ready && mem_write) begin
      writes = writes + 1;
      last_write_addr = mem_addr;
      last_write_data = mem_din;
      last_write_be = mem_be;
    end
    if (tram_we) begin
      tram[tram_addr] <= tram_din;
      tram_dout <= tram_din;
    end else tram_dout <= tram[tram_addr];
    if (font_we) begin
      font_writes = font_writes + 1;
      last_font_addr = font_addr;
      last_font_data = font_data;
    end
  end

  // THE GVRAM REACHES THE SHARED BACKEND AGAIN: its 256 KiB array is SDRAM-resident,
  // so a plane store is observed at pc9821_gvram's D1 boundary rather than at the array's old
  // port A, and mem_addr/mem_be on the backend are the same request one stage on.
  integer    gvram_writes = 0;
  reg [15:0] last_gvram_addr;
  reg [31:0] last_gvram_data;
  reg [3:0]  last_gvram_lanes;  // the plain path's four byte enables, presented in ONE visit
  reg [1:0]  last_gvram_plane;  // the plain path's plane byte lane
  // The GVRAM's D1 accept, observed at the D1 boundary so the count is one per plane access
  // whatever the SDRAM backend's latency. A plain plane-window access now presents the
  // base word, the CPU's byte enables and the plane in ONE visit (the backend walks the lanes), so
  // addr's low two bits are 0 and `lanes` carries what the old per-lane walk put in `be`.
  always @(posedge clk) begin
    if (dut.u_gvram_arb.cc_ready && dut.u_gvram_arb.cc_write) begin
      gvram_writes     = gvram_writes + 1;
      last_gvram_addr  = dut.u_gvram_arb.cc_addr;
      last_gvram_data  = dut.u_gvram_arb.cc_wdata;
      last_gvram_lanes = dut.u_gvram_arb.cc_lane_be;
      last_gvram_plane = dut.u_gvram_arb.cc_byte_lane;
    end
  end
  // ==== ROUTE-OWNERSHIP MONITORS ====
  // Whatever else changes, the mapper must never be told it was ACCEPTED while
  // another route owns the request the backend is serving: it would then treat
  // that route's completion as its own answer. The GVRAM was the historical firing
  // of the old check here; since its array became SDRAM-resident and it reaches
  // this backend again on its own ports, so it is an owner alongside the LOADER and
  // the mapper, and the check below holds the LOADER half of that contract.
  always @(posedge clk) begin
    if (!reset) begin
      if (dut.map_ready && dut.loader_owns) begin
        $display("FAIL route-ownership: the mapper was accepted while the loader owned the backend");
        errors = errors + 1;
      end
    end
  end

  // ==== STIMULUS ====

  // Wait for one more backend WRITE than the count the caller captured, bounded so
  // a route that stops answering fails the check below instead of hanging the run.
  integer wn;
  task automatic wait_write(input integer base);
    begin
      for (wn = 0; wn < 200 && writes == base; wn = wn + 1) @(negedge clk);
    end
  endtask

  // The same bound for a GVRAM plane store, which no longer reaches the backend.
  integer gwn;
  // THE DEVICE IDLE, not only the array FSM: pc9821_gvram_arb's GVRAM_PERIODS prices a GVRAM
  // access at the machine's own per-operation TIME (the Xe10 capture), so a store's ARRAY write
  // can land after the CPU's ready and after the client's walk has drained. The probe fields
  // below are read only once the device will take its next access, so they describe THIS store.
  task automatic drain_gvram;
    begin
      while ((dut.u_gvram_arb.gstate != 3'd0) || dut.u_gvram_arb.m_mode ||
             (dut.u_gvram_arb.cs != 4'd0) || (dut.u_gvram_arb.hold_left != 16'd0)) @(negedge clk);
      repeat (2) @(negedge clk);
    end
  endtask

  task automatic wait_gvram_write(input integer base);
    begin
      for (gwn = 0; gwn < 200 && gvram_writes == base; gwn = gwn + 1) @(negedge clk);
    end
  endtask

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

  // Two reads to the same route with cpu_valid never dropping between them. The
  // second request's address is presented while the first is still valid, which
  // is what z486's finalize window looks like on the bus. Bounded: a responder
  // that waits for valid to drop fails here by name instead of hanging the run.
  task automatic check_valid_held_pair(input [31:0] addr_a, input [31:0] addr_b,
                                      input is_write);
    integer guard;
    begin
      @(negedge clk);
      cpu_addr = addr_a;
      cpu_din = 32'h0000_5A00;
      cpu_be = 4'hF;
      cpu_line_read = 0;
      cpu_write = is_write;
      cpu_valid = 1;
      guard = 0;
      while (!cpu_ready && guard < 200) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (!cpu_ready) begin
        $display("FAIL valid-held pair: the FIRST access at %08x never got ready", addr_a);
        errors = errors + 1;
      end
      // The second access, with cpu_valid still high and no cycle spent on
      // another route in between.
      @(negedge clk);
      cpu_addr = addr_b;
      guard = 0;
      while (!cpu_ready && guard < 200) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (!cpu_ready) begin
        $display("FAIL valid-held pair: the second access at %08x never got ready -- the responder waits for cpu_valid to drop",
                 addr_b);
        errors = errors + 1;
      end
      // Release the bus and let the route return to idle before the next case.
      @(negedge clk);
      cpu_valid = 0;
      repeat (8) @(negedge clk);
    end
  endtask
  // The response half of the same rule, and the shape the authentic POST actually
  // died of: a route's answer must never be delivered because a DIFFERENT route's
  // backend completion arrived. Measured on the old RTL at cycle 37,763,735, with
  // cpu=0x000A3FE0 (TRAM), tram_select=1 and the mapper holding no request at all.
  task automatic check_no_stolen_answer;
    integer guard;
    begin
      @(negedge clk);
      cpu_addr      = 32'h000A_3FE0;   // TRAM, the address the POST died on
      cpu_be        = 4'hF;
      cpu_write     = 0;
      cpu_line_read = 0;
      cpu_valid     = 1;
      // Let the TRAM route answer, then deliver a shared-backend completion in the
      // same cycle -- which is not this route's, and must not be taken as the
      // mapper's either.
      guard = 0;
      while (!dut.win_cpu_resp_valid && guard < 200) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (!dut.win_cpu_resp_valid) begin
        $display("FAIL stolen-answer: the TRAM route never answered 000A3FE0");
        errors = errors + 1;
      end
      mem_resp_valid = 1;
      #1;
      if (dut.map_cpu_resp_valid) begin
        $display("FAIL stolen-answer: the mapper answered another route's completion (map_valid=%b tram_select=%b)",
                 dut.map_valid, dut.tram_select);
        errors = errors + 1;
      end
      mem_resp_valid = 0;
      @(negedge clk);
      cpu_valid = 0;
      repeat (8) @(negedge clk);
    end
  endtask
    // ==== THE SHARED BACKEND DOES NOT OBEY THE RESPONDER CONTRACT, AND THE
    //      ACCEPT RECORD MUST NOT ASSUME IT DOES ====
    //
    // sdram.v states its own read timing -- "Read latency is T_RCD + CAS +
    // 2*burst_cnt - 1 cycles from ACT to last data" (sdram.v:7) -- asserting
    // ready_pulse at the accept (sdram.v:1333) and resp_valid0 from data_resp_pulse
    // at the CAS return (sdram.v:396). A mapped READ is therefore answered SEVERAL
    // CYCLES after its accept, not one.
    //
    // An accept record that lasts one cycle misses its own response: the answer is
    // gated off and the CPU waits forever. That is exactly the observed hardware
    // failure -- the authentic POST sat at F000:FFF0 with IMR=FF and every activity
    // counter at zero -- and it is invisible to every other bench because THEIR
    // backend registers the response one cycle after valid&&ready
    // (the integrated tiers' SDRAM models), which is the one timing a one-cycle record
    // happens to be wide enough for.
    task automatic check_slow_backend_response(input integer resp_delay);
      integer i;
      begin
        @(negedge clk);
        mem_ready      = 1'b0;
        mem_resp_valid = 1'b0;
        cpu_addr       = 32'h0002_0000;   // plain mapped RAM; no other route selects it
        cpu_be         = 4'hF;
        cpu_write      = 1'b0;
        cpu_line_read  = 1'b0;
        cpu_burstcount = 8'd1;
        cpu_valid      = 1'b1;
        repeat (2) @(negedge clk);
        // ONE accept cycle, exactly as sdram.v pulses ready.
        mem_ready = 1'b1;
        #1;
        if (!dut.map_valid || !dut.map_ready || !cpu_ready) begin
          $display("FAIL slow-backend: the mapper was not accepted for 00020000 (valid=%b ready=%b cpu_ready=%b)",
                   dut.map_valid, dut.map_ready, cpu_ready);
          errors = errors + 1;
        end
        @(negedge clk);
        mem_ready = 1'b0;                 // the backend is busy from here
        cpu_valid = 1'b0;                 // and the CPU releases its request, as it does
        // Nothing may be answered during the gap, or this measures something else.
        for (i = 0; i < resp_delay; i = i + 1) begin
          @(negedge clk);
          if (dut.map_cpu_resp_valid) begin
            $display("FAIL slow-backend: the mapper answered %0d cycles before the backend gave a response",
                     resp_delay - i);
            errors = errors + 1;
          end
        end
        // The answer, several cycles after the accept.
        mem_dout       = 32'hA5A5_1234;
        mem_resp_valid = 1'b1;
        #1;
        if (!dut.map_cpu_resp_valid) begin
          $display("FAIL slow-backend: the mapper dropped its own response %0d cycles after the accept -- the CPU waits forever",
                   resp_delay);
          errors = errors + 1;
        end
        else if (dut.cpu_dout !== 32'hA5A5_1234) begin
          $display("FAIL slow-backend: the CPU was answered with %08x, not the backend's data",
                   dut.cpu_dout);
          errors = errors + 1;
        end
        mem_resp_valid = 1'b0;
        mem_dout       = 32'h0;
        mem_ready      = 1'b1;            // restore the bench's default
        repeat (3) @(negedge clk);
      end
    endtask

  // ==== THE DECODE IS EXCLUSIVE, AND THAT NEEDS A SWEEP, NOT A WATCHER ====
  //
  // The route-isolation block asserts that no two routes select one address. That
  // check can only ever fire on an address the STIMULUS happens to present, and
  // the stimulus here presents a handful - so a decode drift at any other address
  // would be invisible to it. This case walks the decode space instead, which is
  // the coverage the always-block cannot provide, and it is the reason a drift is
  // caught even where no test drives.
  //
  // The property is a pure function of cpu_addr and the config, so it is evaluated
  // with cpu_valid LOW: the routes are never gated on, nothing is in flight, and
  // the selects are still fully defined.
  function automatic integer count_route_selects();
    integer n;
    begin
      n = 0;
      if (dut.tram_select)   n = n + 1;
      if (dut.cg_win_select) n = n + 1;
      if (dut.open_select)   n = n + 1;
      if (dut.gvram_select)  n = n + 1;
      count_route_selects = n;
    end
  endfunction

  task automatic check_route_decode_is_exclusive(input [31:0] lo, input [31:0] hi,
                                                 input integer step, input [7:0] win);
    reg [31:0] a;
    integer n, bad;
    begin
      cpu_valid = 0;
      win0_sel  = win;
      bad = 0;
      a = lo;
      // `a + step` wraps past 0xFFFF_FFFF back to zero, which would loop forever on
      // a sweep that reaches the top of the address space, so the loop also stops
      // when it wraps to below where it started.
      while (a <= hi && bad == 0) begin
        cpu_addr = a;
        #1;
        n = count_route_selects();
        if (dut.tram_select)   saw_tram   = saw_tram   + 1;
        if (dut.cg_win_select) saw_cg     = saw_cg     + 1;
        if (dut.open_select)   saw_open   = saw_open   + 1;
        if (dut.gvram_select)  saw_gvram  = saw_gvram  + 1;
        if (n > 1) begin
          bad = 1;
          $display("FAIL decode-exclusive: %0d routes select cpu_addr=%08x with win0_sel=%02x (tram=%b cg=%b open=%b gvram=%b)",
                   n, a, win, dut.tram_select, dut.cg_win_select,
                   dut.open_select, dut.gvram_select);
          errors = errors + 1;
        end
        a = a + step;
        if (a < lo) bad = 2;   // wrapped; the range is covered
        @(negedge clk);
      end
    end
  endtask

  // The clock-aligned form of the stolen answer. The check inside
  // check_no_stolen_answer pulses the shared backend's completion and samples the
  // mapper combinationally 1 ns later, so it never survives a clock edge - and the
  // RTL's route-isolation block is a posedge assertion, which therefore cannot see
  // it. This drives the same hazard ACROSS a posedge, which is the shape the
  // authentic POST hit at 37,763,735 cycles, so the RTL guard has stimulus that can
  // actually reach it.
  task automatic check_stolen_answer_at_clock_edge;
    integer guard;
    integer bad;
    begin
      bad = 0;
      @(negedge clk);
      cpu_addr      = 32'h000A_3FE0;
      cpu_be        = 4'hF;
      cpu_write     = 0;
      cpu_line_read = 0;
      cpu_valid     = 1;
      guard = 0;
      while (!dut.win_cpu_resp_valid && guard < 200) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (!dut.win_cpu_resp_valid) begin
        $display("FAIL stolen-answer-edge: the TRAM route never answered 000A3FE0");
        errors = errors + 1;
      end
      // Both conditions must hold AT the edge, so hold the completion across it.
      mem_resp_valid = 1;
      #1;
      if (dut.map_cpu_resp_valid) begin
        $display("FAIL stolen-answer-edge: the mapper answered another route's completion (map_valid=%b tram_select=%b)",
                 dut.map_valid, dut.tram_select);
        errors = errors + 1;
      end
      @(posedge clk);   // the RTL guard's own sampling point
      #1;
      mem_resp_valid = 0;
      @(negedge clk);
      cpu_valid = 0;
      repeat (8) @(negedge clk);
    end
  endtask

  task automatic check_decode_coverage;
    begin
      if (saw_tram == 0 || saw_cg == 0 || saw_open == 0 || saw_gvram == 0) begin
        $display("FAIL decode-coverage: the sweep never selected a route, so it proves nothing (tram=%0d cg=%0d open=%0d gvram=%0d)",
                 saw_tram, saw_cg, saw_open, saw_gvram);
        errors = errors + 1;
      end else begin
        $display("decode sweep exercised every route: tram=%0d cg=%0d open=%0d gvram=%0d addresses",
                 saw_tram, saw_cg, saw_open, saw_gvram);
      end
    end
  endtask


  // THE DOWNLOAD GATE'S EDGES (docs/timing.md, "the download gate"; tools/check_cpu_run_inv.py
  // proves the loader side). cpu_run is pc9821_rom_loader's register and loader_owns is
  // `load_valid || !rom_ready`: neither reads the live ioctl_download. Pinned here, cycle by
  // cycle, on the whole subsystem:
  //   * a reload while the guest runs: in the cycle ioctl_download rises nothing has moved
  //     (cpu_run high, the loader not owning, a CPU request still served), and the next cycle
  //     the CPU is held and the loader owns the backend - before its first word can be presented;
  //   * the end edge, unchanged: cpu_run rises in the second cycle after the download falls;
  //   * a platform (OSD) reset with the pack loaded leaves cpu_run high (the pack survives it);
  //   * an out-of-range word keeps the CPU held after the download (load_error).
  task automatic check_download_gate_edges;
    integer n;
    begin
      // the reload while running
      @(negedge clk);
      if (!cpu_run || !rom_ready || dut.loader_owns) begin
        $display("FAIL gate-edges: precondition (run=%b ready=%b owns=%b)",
                 cpu_run, rom_ready, dut.loader_owns);
        errors = errors + 1;
      end
      ioctl_download = 1;
      #1;
      if (!cpu_run || dut.loader_owns) begin
        $display("FAIL gate-edges: the download's first cycle already moved the gate (run=%b owns=%b) - a live ioctl term is back",
                 cpu_run, dut.loader_owns);
        errors = errors + 1;
      end
      @(negedge clk);
      #1;
      if (cpu_run || !dut.loader_owns || rom_ready) begin
        $display("FAIL gate-edges: the cycle after the download rose did not hold the CPU (run=%b owns=%b ready=%b)",
                 cpu_run, dut.loader_owns, rom_ready);
        errors = errors + 1;
      end
      send_word(27'h000_0010, 16'h1234);
      repeat (2) @(negedge clk);
      // the end edge: cpu_run rises in the second cycle after the fall
      ioctl_download = 0;
      n = 0;
      while (!cpu_run && n < 8) begin
        @(negedge clk);
        n = n + 1;
      end
      if (n != 2 || !rom_ready || load_error) begin
        $display("FAIL gate-edges: cpu_run rose %0d cycles after the download fell (expected 2; ready=%b error=%b)",
                 n, rom_ready, load_error);
        errors = errors + 1;
      end
      // a platform reset with the pack loaded: the gate holds through it
      @(negedge clk);
      reset = 1;
      n = 0;
      repeat (4) begin
        @(negedge clk);
        if (!cpu_run) n = n + 1;
      end
      reset = 0;
      @(negedge clk);
      if (n != 0 || !cpu_run) begin
        $display("FAIL gate-edges: a platform reset with the pack loaded dropped cpu_run (%0d cycles low)", n);
        errors = errors + 1;
      end
      // an out-of-range word: the CPU stays held after the download
      ioctl_download = 1;
      send_word(27'h010_0000, 16'hDEAD);
      repeat (2) @(negedge clk);
      ioctl_download = 0;
      repeat (4) @(negedge clk);
      if (cpu_run || !load_error || rom_ready) begin
        $display("FAIL gate-edges: an out-of-range download released the CPU (run=%b error=%b ready=%b)",
                 cpu_run, load_error, rom_ready);
        errors = errors + 1;
      end
      // and a good reload releases it again
      ioctl_download = 1;
      send_word(27'h000_0010, 16'h1234);
      repeat (2) @(negedge clk);
      ioctl_download = 0;
      repeat (4) @(negedge clk);
      if (!cpu_run || load_error || !rom_ready) begin
        $display("FAIL gate-edges: a good reload after the error did not release the CPU (run=%b error=%b ready=%b)",
                 cpu_run, load_error, rom_ready);
        errors = errors + 1;
      end
    end
  endtask

  // ==== CHECKS ====

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;

    // Before a pack is loaded the CPU must be held and backend traffic blocked.
    cpu_valid = 1;
    cpu_addr = 32'h000F_FFF0;
    #1;
    if (cpu_run || cpu_ready || mem_valid) begin
      $display("FAIL CPU escaped before ROM load");
      errors = errors + 1;
    end
    cpu_valid = 0;

    ioctl_download = 1;
    send_word(27'd0, 16'hBEEF);
    repeat (2) @(posedge clk);
    ioctl_download = 0;
    repeat (3) @(posedge clk);
    if (!rom_ready || !cpu_run || load_error || writes != 1 ||
        last_write_addr !== 32'h02000000 ||
        last_write_data !== 32'h0000BEEF || last_write_be !== 4'b0011) begin
      $display("FAIL load/arbitration ready=%b run=%b writes=%0d addr=%08x",
               rom_ready, cpu_run, writes, last_write_addr);
      errors = errors + 1;
    end

    // CPU native request now owns the backend and sees translated ITF address.
    cpu_addr = 32'hFFFF_FFF0;
    cpu_valid = 1;
    cpu_write = 0;
    cpu_line_read = 1;
    cpu_burstcount = 8'd4;
    #1;
    if (!cpu_ready || !mem_valid || mem_write ||
        mem_addr !== 32'h02007FF0 || mem_burstcount != 8'd4) begin
      $display("FAIL CPU mapped request addr=%08x ready=%b", mem_addr, cpu_ready);
      errors = errors + 1;
    end
    @(negedge clk);
    cpu_valid = 0;
    // The 128-bit line form is gone from this boundary entirely (the beat-uniform
    // fill): the route answers this line read with 4 word beats. Drain all four,
    // asserting each arrives, so the shared accept record is left clean for the
    // tests below.
    for (int b = 0; b < 4; b = b + 1) begin
      mem_resp_valid = 1;
      #1;
      if (!cpu_resp_valid) begin
        $display("FAIL the map route did not answer line-read beat %0d", b);
        errors = errors + 1;
      end
      @(negedge clk);
    end
    mem_resp_valid = 0;
    #1;
    if (cpu_resp_valid) begin
      $display("FAIL the map route answered a fifth beat of a 4-beat line read");
      errors = errors + 1;
    end

    // A0000-A3FFF is local TRAM and must never reach SDRAM.
    cpu_addr = 32'h000A_0001;
    cpu_din = 32'h0000_5A00;
    cpu_be = 4'b0010;
    cpu_line_read = 0;
    cpu_write = 1;
    cpu_valid = 1;
    while (!cpu_ready) @(negedge clk);
    if (mem_valid || tram[14'h0001] !== 8'h5A) begin
      $display("FAIL local TRAM routing mem_valid=%b tram=%02x",
               mem_valid, tram[14'h0001]);
      errors = errors + 1;
    end
    @(negedge clk);
    cpu_valid = 0;
    cpu_write = 0;
    cpu_be = 4'hF;
    while (dut.u_window.state != 0) @(negedge clk);

    // Graphics VRAM, unlike TRAM, has its own datapath. Its 256 KiB array is
    // SDRAM-resident and pc9821_gvram owns it, so a CPU byte in a plane window becomes ONE
    // visit at the D1 boundary: cc_addr = the column word's BASE (the access page in bit 15),
    // cc_lane_be = the CPU's byte enables (which of the four consecutive words), and the plane
    // byte lane. A 0xA8001 byte is plane 0 (window 0), byte lane 1, so base column 0 with lane 1
    // enabled.
    g0 = gvram_writes;
    cpu_addr = 32'h000A_8001;
    cpu_din = 32'h0000_A500;
    cpu_be = 4'b0010;
    cpu_line_read = 0;
    cpu_write = 1;
    cpu_valid = 1;
    wait_gvram_write(g0);
    while (!cpu_ready) @(negedge clk);
    #1;
    if (gvram_writes - g0 != 1 ||
        last_gvram_addr !== 16'h0000 ||
        last_gvram_lanes !== 4'h2 ||
        last_gvram_plane !== 2'd0 ||
        last_gvram_data !== 32'h0000_A500) begin
      $display("FAIL graphics plane routing writes=%0d addr=%04x lanes=%x plane=%0d data=%08x",
               gvram_writes - g0, last_gvram_addr, last_gvram_lanes, last_gvram_plane,
               last_gvram_data);
      errors = errors + 1;
    end
    repeat (3) @(posedge clk);
    @(negedge clk);
    cpu_valid = 0;
    cpu_write = 0;
    cpu_be = 4'hF;

    // Window 0 DOES carry the TRAM/CG apertures: they are decoded on the
    // post-window-0 address (route_addr here, the mapper's own d_addr next to it),
    // so with 0x461 = 0x0A a store to 0x80001 lands on the text VRAM at 0xA0001
    // and reaches the TRAM bridge rather than the backend. The machine agrees
    // 0x80000 is not the RAM page under 0x0A (`0461=0A b=0800 a=5AA5 p=FF q=FF`,
    // the marker at no 64 KiB-aligned address of the first MiB) and the 0x463
    // sweep proves 0xA0000's word is the text RAM's own 0x0020, so the window's
    // low 32 KiB is the text VRAM there (closing that open question). Reachable from no firmware
    // (0x0461 is written only with 0x08/0x0C/0x0E), but the routing is the
    // machine's now and a silent change back is caught here.
    win0_sel = 8'h0A;
    cpu_addr = 32'h0008_0001;
    cpu_din = 32'h0000_3C00;
    cpu_be = 4'b0010;
    cpu_line_read = 0;
    cpu_write = 1;
    cpu_valid = 1;
    // THE READY IS READ AFTER A DELTA, NOT IN ZERO TIME. This case changes the address, the window
    // select AND cpu_valid in one time step and then reads the route's answer; without the settle it
    // samples the value from the PREVIOUS evaluation, which is the GVRAM's ready for the access
    // BEFORE this one -- and since a GVRAM store completes one clk_sys earlier, that stale
    // value is 1 here and the loop below would take it for the TRAM route's answer. The route
    // select is combinational from the address, so the settled read is the route's own
    // answer for THIS request.
    #1;
    while (!cpu_ready) @(negedge clk);
    #1;
    if (mem_valid) begin
      $display("FAIL window-0 0x0A store reached the backend at %08x", mem_addr);
      errors = errors + 1;
    end
    if (tram[14'h0001] !== 8'h3C) begin
      $display("FAIL window-0 0x0A store did not reach the TRAM bridge (%02x)",
               tram[14'h0001]);
      errors = errors + 1;
    end
    @(negedge clk);
    cpu_valid = 0;
    cpu_write = 0;
    cpu_be = 4'hF;
    win0_sel = 8'h08;

    // ---- The absent ROM area: all ones in z486's phases, nothing stored ----
    // 0xC0000-0xD7FFF is the machine's C-Bus option-ROM space with nothing
    // fitted: every byte reads 0xFF and stores are discarded (docs/probes/
    // SHADOW.TXT "REGION C0000..D7FFF", docs/probes/WIN.TXT
    // `0461=0C rb=0D b=FFFF a=FFFF`). The mapper decodes it and this subsystem
    // routes it to the registered pc9821_open_bus responder, so the guest sees
    // all ones, in the accept-then-respond phases z486 requires, with no SDRAM
    // transaction issued -- an option-ROM scan or a spurious call into the area
    // can then never execute SDRAM residue.
    cpu_addr = 32'h000C_0000;                    // the area's base
    cpu_din = 32'hDEAD_BEEF;                     // must not be stored anywhere
    cpu_be = 4'hF;
    cpu_line_read = 0;
    cpu_write = 0;
    cpu_valid = 1;
    repeat (3) @(negedge clk);                   // bounded: the response arrives
    if (mem_valid) begin
      $display("FAIL absent area reached the backend: mem_addr=%08x mem_valid=%b",
               mem_addr, mem_valid);
      errors = errors + 1;
    end
    if (cpu_dout !== 32'hFFFF_FFFF) begin
      $display("FAIL absent area returned %08x, want FFFFFFFF (all ones)", cpu_dout);
      errors = errors + 1;
    end
    cpu_valid = 0;
    repeat (2) @(negedge clk);
    // The store is swallowed: accepted, never written, never answered.
    cpu_addr = 32'h000D_7FFF;                    // the area's end
    cpu_write = 1;
    cpu_valid = 1;
    repeat (2) @(negedge clk);
    if (!cpu_ready || cpu_resp_valid || mem_valid) begin
      $display("FAIL absent-area store: ready=%b resp=%b mem_valid=%b addr=%08x",
               cpu_ready, cpu_resp_valid, mem_valid, mem_addr);
      errors = errors + 1;
    end
    @(negedge clk);
    if (cpu_resp_valid || cpu_line_word_valid || mem_valid) begin
      $display("FAIL absent-area store was answered or stored");
      errors = errors + 1;
    end
    cpu_valid = 0;
    cpu_write = 0;
    repeat (2) @(negedge clk);
    // An instruction fetch of the area is four all-ones words - the beat-uniform
    // fill, four word beats now that the 128-bit line form is gone from this
    // boundary (tb_pc9821_fill_beat_uniform diffs the forms byte for byte) - and
    // the phases are separate: a spurious call executes a constant, not residue.
    cpu_addr = 32'h000C_1000;
    cpu_line_read = 1;
    cpu_burstcount = 8'd4;
    cpu_valid = 1;
    @(negedge clk);
    if (cpu_ready || cpu_resp_valid) begin
      $display("FAIL absent-area line read answered combinationally");
      errors = errors + 1;
    end
    @(negedge clk);
    if (!cpu_ready || cpu_resp_valid) begin
      $display("FAIL absent-area line read acceptance phase");
      errors = errors + 1;
    end
    // Release at the accept edge's wake, the z486 discipline (memory.sv clears
    // ext_valid_r on the ready edge): the responder has latched the request and
    // must not re-accept it while the four beats stream.
    @(negedge clk);
    cpu_valid = 0;
    cpu_line_read = 0;
    cpu_burstcount = 8'd1;
    for (int b = 0; b < 4; b = b + 1) begin
      gbeat = 0;
      while (!cpu_resp_valid && gbeat < 200) begin @(negedge clk); gbeat = gbeat + 1; end
      if (cpu_ready || !cpu_resp_valid || cpu_dout !== 32'hFFFF_FFFF || mem_valid) begin
        $display("FAIL absent-area line read beat %0d: ready=%b resp=%b data=%08x mem_valid=%b",
                 b, cpu_ready, cpu_resp_valid, cpu_dout, mem_valid);
        errors = errors + 1;
      end
      @(negedge clk);
    end
    if (cpu_resp_valid || mem_valid) begin
      $display("FAIL absent-area line read ran past its four beats");
      errors = errors + 1;
    end
    cpu_valid = 0;
    cpu_line_read = 0;
    cpu_burstcount = 8'd1;
    repeat (2) @(negedge clk);
    // Window 0 over 0xC0000-0xDFFFF (0x461 = 0x0C) aliases the physical space,
    // so the alias inherits the area -- the machine's marker write through
    // 0x80000 under 0x0C did not take -- while the alias of the IDE work RAM at
    // the top of the same window stays RAM.
    win0_sel = 8'h0C;
    cpu_addr = 32'h0008_0000;                    // -> 0xC0000
    cpu_valid = 1;
    repeat (3) @(negedge clk);
    if (mem_valid || cpu_dout !== 32'hFFFF_FFFF) begin
      $display("FAIL window-0 0x0C alias of 0xC0000: mem_valid=%b data=%08x",
               mem_valid, cpu_dout);
      errors = errors + 1;
    end
    cpu_valid = 0;
    repeat (2) @(negedge clk);
    cpu_addr = 32'h0009_A000;                    // -> 0xDA000: still RAM
    cpu_write = 1;
    cpu_be = 4'b0010;
    cpu_din = 32'h0000_6F00;
    cpu_valid = 1;
    while (!cpu_ready) @(negedge clk);
    #1;
    if (!mem_valid || mem_addr !== 32'h000D_A000) begin
      $display("FAIL window-0 0x0C alias of 0xDA000: mem_valid=%b addr=%08x",
               mem_valid, mem_addr);
      errors = errors + 1;
    end
    @(negedge clk);
    cpu_valid = 0;
    cpu_write = 0;
    cpu_be = 4'hF;
    win0_sel = 8'h08;

    // ---- The 0x1E8E-gated IDE work RAM: 0xDA000-0xDBFFF ----
    // The machine's own measurement (docs/probes/SHADOWW.TXT:226-231): the
    // probe wrote 0x80, 0x81 and the as-found 0xFE to 0x1E8E and read back
    // "FE FF FE"; its marker word 5AA5 at DA000 read back FFFF under 0x80 and
    // 5AA5 under 0x81 (line 227), and the IDE ROM's own work bytes reappear at
    // the window once the gate opens (line 230) - the RAM SURVIVES the
    // disconnect, it is hidden rather than cleared. Gate OFF is therefore the
    // absent route's own shape at this window: all ones, stores swallowed, no
    // backend transaction - which is exactly what an EMM386 C0000-DFFFF region
    // scan sees on the machine and why it can never claim the IDE ROM's work
    // area as UMB. Gate ON is ordinary RAM again. FAIL-FIRST: this file drives
    // the gate input by name, so the same file builds against the pre-gate
    // map (where the pin does not exist and 0xDA000 is unconditional RAM) and
    // every check below fails there.
    ide_ram_gate = 0;
    cpu_addr = 32'h000D_A000;
    cpu_din = 32'h0000_5AA5;                     // the capture's own marker word
    cpu_be = 4'hF;
    cpu_line_read = 0;
    cpu_write = 0;
    cpu_valid = 1;
    repeat (3) @(negedge clk);                   // bounded: the response arrives
    if (mem_valid) begin
      $display("FAIL gate-off 0xDA000 reached the backend: mem_addr=%08x", mem_addr);
      errors = errors + 1;
    end
    if (cpu_dout !== 32'hFFFF_FFFF) begin
      $display("FAIL gate-off 0xDA000 returned %08x, want FFFFFFFF (SHADOWW.TXT:229 reads FF)",
               cpu_dout);
      errors = errors + 1;
    end
    cpu_valid = 0;
    repeat (2) @(negedge clk);
    // The marker store is dropped, not hidden in some shadow it could come back
    // from: SHADOWW.TXT:227 reads it back FFFF under 0x80, and the gate-on dump
    // of line 230 shows the IDE ROM's own bytes at DA000, not the marker.
    cpu_write = 1;
    cpu_valid = 1;
    repeat (2) @(negedge clk);
    if (!cpu_ready || cpu_resp_valid || mem_valid) begin
      $display("FAIL gate-off 0xDA000 store: ready=%b resp=%b mem_valid=%b addr=%08x",
               cpu_ready, cpu_resp_valid, mem_valid, mem_addr);
      errors = errors + 1;
    end
    @(negedge clk);
    if (cpu_resp_valid || cpu_line_word_valid || mem_valid) begin
      $display("FAIL gate-off 0xDA000 store was answered or stored");
      errors = errors + 1;
    end
    cpu_valid = 0;
    cpu_write = 0;
    repeat (2) @(negedge clk);
    // Gate ON: the same address is ordinary RAM again. The store must reach the
    // backend at 0xDA000 carrying the marker (SHADOWW.TXT:227's 5AA5), and the
    // read must be answered FROM that RAM rather than from the open bus.
    ide_ram_gate = 1;
    cpu_addr = 32'h000D_A000;
    cpu_din = 32'h0000_5AA5;
    cpu_write = 1;
    cpu_valid = 1;
    #1;
    while (!cpu_ready) @(negedge clk);
    #1;
    if (!mem_valid || mem_write !== 1'b1 || mem_addr !== 32'h000D_A000 ||
        mem_din !== 32'h0000_5AA5) begin
      $display("FAIL gate-on 0xDA000 store did not reach the RAM: valid=%b wr=%b addr=%08x data=%08x",
               mem_valid, mem_write, mem_addr, mem_din);
      errors = errors + 1;
    end
    @(negedge clk);
    cpu_valid = 0;
    cpu_write = 0;
    repeat (2) @(negedge clk);
    // The read half, in the backend's own slow-response shape (see
    // check_slow_backend_response above): one accept, then the RAM's answer.
    mem_ready = 1'b0;
    mem_resp_valid = 1'b0;
    cpu_addr = 32'h000D_A000;
    cpu_write = 1'b0;
    cpu_line_read = 1'b0;
    cpu_burstcount = 8'd1;
    cpu_valid = 1'b1;
    repeat (2) @(negedge clk);
    mem_ready = 1'b1;
    #1;
    if (!dut.map_valid || !dut.map_ready || !cpu_ready) begin
      $display("FAIL gate-on 0xDA000 read: the mapper was not accepted (valid=%b ready=%b cpu_ready=%b)",
               dut.map_valid, dut.map_ready, cpu_ready);
      errors = errors + 1;
    end
    @(negedge clk);
    mem_ready = 1'b0;
    cpu_valid = 1'b0;
    mem_dout = 32'h0000_5AA5;                   // the RAM answers the stored word
    mem_resp_valid = 1'b1;
    #1;
    if (!dut.map_cpu_resp_valid) begin
      $display("FAIL gate-on 0xDA000 read dropped its response -- the CPU waits forever");
      errors = errors + 1;
    end
    else if (cpu_dout !== 32'h0000_5AA5) begin
      $display("FAIL gate-on 0xDA000 read answered %08x, want 00005AA5 (SHADOWW.TXT:227)",
               cpu_dout);
      errors = errors + 1;
    end
    mem_resp_valid = 1'b0;
    mem_dout = 32'h0;
    mem_ready = 1'b1;
    repeat (3) @(negedge clk);

    // ---- The FF-always tail: 0xDC000-0xDFFFF (absent in BOTH gate states) ----
    // The machine reads 0xFF over all 12 x 2 KiB blocks of the DA000..DFFFF
    // region with the gate clear (docs/probes/SHADOW.TXT:201-213,
    // `summary: blocks=000C bytes=00006000 ... ffblocks=000C`), and QEMU models
    // the rest of the 0xD8000 window as rom_empty - a 0xFF fill with the 8 KiB
    // gated work RAM overlaid at 0xDA000 (hw/i386/pc98-mem.c d8000_rom;
    // NP2kai's 12 KiB gate mask is the outlier). So above the work RAM the
    // window answers all ones and swallows stores whatever 0x1E8E holds. The
    // gate-ON state of this tail is capture-pending: one marker write at
    // 0xDC000 under 0x1E8E=0x81 settles it (probe2 /IDEGATE, item 34), and the
    // modelled choice is the QEMU one until that capture lands.
    ide_ram_gate = 0;
    cpu_addr = 32'h000D_C000;
    cpu_din = 32'h0000_5AA5;
    cpu_be = 4'hF;
    cpu_line_read = 0;
    cpu_write = 0;
    cpu_valid = 1;
    repeat (3) @(negedge clk);                   // bounded: the response arrives
    if (mem_valid) begin
      $display("FAIL gate-off 0xDC000 reached the backend: mem_addr=%08x", mem_addr);
      errors = errors + 1;
    end
    if (cpu_dout !== 32'hFFFF_FFFF) begin
      $display("FAIL gate-off 0xDC000 returned %08x, want FFFFFFFF (SHADOW.TXT:201-213 reads FF)",
               cpu_dout);
      errors = errors + 1;
    end
    cpu_valid = 0;
    repeat (2) @(negedge clk);
    cpu_addr = 32'h000D_C800;
    cpu_write = 0;
    cpu_valid = 1;
    repeat (3) @(negedge clk);
    if (mem_valid || cpu_dout !== 32'hFFFF_FFFF) begin
      $display("FAIL gate-off 0xDC800: mem_valid=%b data=%08x, want FF (SHADOW.TXT ffblocks=000C)",
               mem_valid, cpu_dout);
      errors = errors + 1;
    end
    cpu_valid = 0;
    repeat (2) @(negedge clk);
    cpu_addr = 32'h000D_E000;
    cpu_valid = 1;
    repeat (3) @(negedge clk);
    if (mem_valid || cpu_dout !== 32'hFFFF_FFFF) begin
      $display("FAIL gate-off 0xDE000: mem_valid=%b data=%08x, want FF (SHADOW.TXT ffblocks=000C)",
               mem_valid, cpu_dout);
      errors = errors + 1;
    end
    cpu_valid = 0;
    repeat (2) @(negedge clk);
    cpu_addr = 32'h000D_FFFF;
    cpu_valid = 1;
    repeat (3) @(negedge clk);
    if (mem_valid || cpu_dout !== 32'hFFFF_FFFF) begin
      $display("FAIL gate-off 0xDFFFF: mem_valid=%b data=%08x, want FF (SHADOW.TXT ffblocks=000C)",
               mem_valid, cpu_dout);
      errors = errors + 1;
    end
    cpu_valid = 0;
    repeat (2) @(negedge clk);
    // Stores are dropped across the tail too: the marker cannot land anywhere in
    // it (SHADOW.TXT:200-213 shows the region reading FF at first touch, and
    // SHADOWW.TXT:227's gate-off marker reads back FFFF at DA000).
    cpu_addr = 32'h000D_C000;
    cpu_write = 1;
    cpu_valid = 1;
    repeat (2) @(negedge clk);
    if (!cpu_ready || cpu_resp_valid || mem_valid) begin
      $display("FAIL gate-off 0xDC000 store: ready=%b resp=%b mem_valid=%b addr=%08x",
               cpu_ready, cpu_resp_valid, mem_valid, mem_addr);
      errors = errors + 1;
    end
    @(negedge clk);
    if (cpu_resp_valid || cpu_line_word_valid || mem_valid) begin
      $display("FAIL gate-off 0xDC000 store was answered or stored");
      errors = errors + 1;
    end
    cpu_valid = 0;
    cpu_write = 0;
    repeat (2) @(negedge clk);
    cpu_addr = 32'h000D_FFFF;
    cpu_write = 1;
    cpu_valid = 1;
    repeat (2) @(negedge clk);
    if (!cpu_ready || cpu_resp_valid || mem_valid) begin
      $display("FAIL gate-off 0xDFFFF store: ready=%b resp=%b mem_valid=%b addr=%08x",
               cpu_ready, cpu_resp_valid, mem_valid, mem_addr);
      errors = errors + 1;
    end
    @(negedge clk);
    if (cpu_resp_valid || cpu_line_word_valid || mem_valid) begin
      $display("FAIL gate-off 0xDFFFF store was answered or stored");
      errors = errors + 1;
    end
    cpu_valid = 0;
    cpu_write = 0;
    repeat (2) @(negedge clk);
    // And gate ON does not resurrect the tail (the modelled QEMU rom_empty
    // shape; capture-pending per the note above).
    ide_ram_gate = 1;
    cpu_addr = 32'h000D_FFFF;
    cpu_write = 0;
    cpu_valid = 1;
    repeat (3) @(negedge clk);
    if (mem_valid || cpu_dout !== 32'hFFFF_FFFF) begin
      $display("FAIL gate-on 0xDFFFF: mem_valid=%b data=%08x, want FF (rom_empty shape)",
               mem_valid, cpu_dout);
      errors = errors + 1;
    end
    cpu_valid = 0;
    repeat (2) @(negedge clk);

    // ---- The 12 KiB gap between the text RAM and the planes: 0xA5000-0xA7FFF ----
    // The machine reads 0xFF at 0xA6000 and discards the store (docs/probes/VRAM.TXT:141-142,
    // `A600wrote= 00 FF 55 AA` / `got= FF FF FF FF`, reproduced in VRAM2.TXT:153-154), while the
    // TRAM row above it (A000/A200) and the plane rows below it (A800/B000/B800) round-trip in
    // the SAME capture -- so the range is a hole, neither storage nor an alias of one. It was
    // served by the mapper's default arm as live guest RAM at d_addr; the fix
    // routes it to the registered open-bus responder, so the guest sees all ones with NO backend
    // transaction, in the accept-then-respond phases z486 requires.
    cpu_addr = 32'h000A_5000;                    // the hole's base
    cpu_din  = 32'hDEAD_BEEF;                    // must not be stored anywhere
    cpu_be   = 4'hF;
    cpu_line_read = 0;
    cpu_write = 0;
    cpu_valid = 1;
    @(negedge clk);
    if (cpu_ready || cpu_resp_valid || mem_valid) begin
      $display("FAIL 0xA5000 answered in its presentation cycle: ready=%b resp=%b mem_valid=%b",
               cpu_ready, cpu_resp_valid, mem_valid);
      errors = errors + 1;
    end
    @(negedge clk);
    if (!cpu_ready || cpu_resp_valid || mem_valid) begin
      $display("FAIL 0xA5000 acceptance phase: ready=%b resp=%b mem_valid=%b addr=%08x",
               cpu_ready, cpu_resp_valid, mem_valid, mem_addr);
      errors = errors + 1;
    end
    @(negedge clk);
    if (cpu_ready || !cpu_resp_valid || cpu_dout !== 32'hFFFF_FFFF || mem_valid) begin
      $display("FAIL 0xA5000 response: ready=%b resp=%b data=%08x mem_valid=%b",
               cpu_ready, cpu_resp_valid, cpu_dout, mem_valid);
      errors = errors + 1;
    end
    cpu_valid = 0;
    repeat (2) @(negedge clk);
    // The store is swallowed: accepted, never written, never answered.
    cpu_addr = 32'h000A_7FFF;                    // the hole's top byte
    cpu_write = 1;
    cpu_valid = 1;
    repeat (2) @(negedge clk);                   // the acceptance phase
    if (!cpu_ready || cpu_resp_valid || mem_valid) begin
      $display("FAIL 0xA7FFF store: ready=%b resp=%b mem_valid=%b addr=%08x",
               cpu_ready, cpu_resp_valid, mem_valid, mem_addr);
      errors = errors + 1;
    end
    cpu_valid = 0;
    cpu_write = 0;
    repeat (2) @(negedge clk);
    if (cpu_resp_valid || cpu_line_word_valid || mem_valid) begin
      $display("FAIL 0xA7FFF store was answered or stored (resp=%b line=%b mem_valid=%b)",
               cpu_resp_valid, cpu_line_word_valid, mem_valid);
      errors = errors + 1;
    end
    // Leave the shared response-route queue as this section found it. PRE-FIX the mapper's
    // default arm ACCEPTED the read above (that is the defect this section exists for), and
    // since the backend's ready is combinational there, three held cycles push three owed beats
    // - so without this drain every LATER check in this bench would be reading a queue that is
    // not empty. Post-fix the route is the registered open-bus responder and the queue was never
    // touched, so the loop does not run at all.
    begin : drain_rt
      integer guard = 0;
      while (!dut.rt_empty && guard < 8) begin
        mem_resp_valid = 1;
        @(negedge clk);
        guard = guard + 1;
      end
      mem_resp_valid = 0;
    end
    repeat (2) @(negedge clk);
    // The gap's own boundaries did not move: 0xA4FFF is still the CG window on its own route and
    // 0xA8000 is still the B plane's, so the term that swallowed the hole's middle cannot have
    // swallowed its neighbours.
    cpu_addr = 32'h000A_4FFF;
    #1;
    if (dut.open_select || !dut.cg_win_select) begin
      $display("FAIL 0xA4FFF: open=%b cg=%b (the CG window must keep its own route)",
               dut.open_select, dut.cg_win_select);
      errors = errors + 1;
    end
    cpu_addr = 32'h000A_8000;
    #1;
    if (dut.open_select || !dut.gvram_select) begin
      $display("FAIL 0xA8000: open=%b gvram=%b (plane B must keep its own route)",
               dut.open_select, dut.gvram_select);
      errors = errors + 1;
    end
    // And the 0x0461 = 0x0A overlay's SHAPE is unchanged by the new term: that overlay claims the
    // whole 0xA0000-0xA7FFF as the text/hole window's contents (the same capture's `0461=0A ...
    // a=5AA5` shows a marker round-tripping at the overlay's base, so it is storage, not this
    // hole). What the overlay's UPPER 12 KiB actually CONTAINS is capture-pending and is NOT
    // modelled here.
    win0_sel = 8'h0A;
    cpu_addr = 32'h0008_6000;                    // -> route_addr 0xA6000
    #1;
    if (dut.open_select || !dut.tram_select) begin
      $display("FAIL 0x0461 = 0x0A overlay at 0x86000: open=%b tram=%b",
               dut.open_select, dut.tram_select);
      errors = errors + 1;
    end
    cpu_addr = 32'h0008_4000;                    // -> route_addr 0xA4000, the overlay's CG half
    #1;
    if (dut.open_select || !dut.tram_select) begin
      $display("FAIL 0x0461 = 0x0A overlay at 0x84000: open=%b tram=%b",
               dut.open_select, dut.tram_select);
      errors = errors + 1;
    end
    win0_sel = 8'h08;

    // The intensity plane is its own window, and since the D1 datapath it is no
    // longer an address bias on the map's backend bus: the access is routed to
    // pc9821_gvram, which owns the four planes in SDRAM, so one CPU byte
    // becomes ONE visit carrying the addressed window's plane lane (here plane 3,
    // the intensity plane).
    g0 = gvram_writes;
    cpu_addr = 32'h000E_0100;
    cpu_be = 4'b0001;
    cpu_write = 1;
    cpu_valid = 1;
    // The GVRAM route answers in phases -- accept, then the column access, then
    // the response -- so wait for the plane store rather than for a ready level
    // the other routes leave high while idle.
    wait_gvram_write(g0);
    while (!cpu_ready) @(negedge clk);
    // Release the request (the CPU re-presents it while it is held, which is z486's
    // shape) and THEN let the device drain: with the per-operation period the array write
    // lands after the ready, so the probe fields are read only once the device will take
    // its next access.
    @(negedge clk);
    cpu_valid = 0;
    cpu_write = 0;
    cpu_be = 4'hF;
    drain_gvram;
    if (gvram_writes - g0 != 1 ||
        last_gvram_addr !== 16'h0100 ||
        last_gvram_lanes !== 4'h1 ||
        last_gvram_plane !== 2'd3) begin
      $display("FAIL intensity plane routing writes=%0d addr=%04x lanes=%x plane=%0d",
               gvram_writes - g0, last_gvram_addr, last_gvram_lanes, last_gvram_plane);
      errors = errors + 1;
    end
    repeat (3) @(posedge clk);

    // The access page shifts the whole aperture by one interleaved page (128
    // KiB, D2's 0x8000 columns), not by a per-window bias: it is a_addr's top bit.
    gvram_access_page = 1;
    g0 = gvram_writes;
    cpu_addr = 32'h000A_8001;
    cpu_be = 4'b0010;
    cpu_write = 1;
    cpu_valid = 1;
    wait_gvram_write(g0);
    while (!cpu_ready) @(negedge clk);
    // Release the request (the CPU re-presents it while it is held, which is z486's
    // shape) and THEN let the device drain: with the per-operation period the array write
    // lands after the ready, so the probe fields are read only once the device will take
    // its next access.
    @(negedge clk);
    cpu_valid = 0;
    cpu_write = 0;
    cpu_be = 4'hF;
    drain_gvram;
    if (gvram_writes - g0 != 1 ||
        last_gvram_addr !== 16'h8000 ||
        last_gvram_lanes !== 4'h2 ||
        last_gvram_plane !== 2'd0) begin
      $display("FAIL access-page routing writes=%0d addr=%04x lanes=%x plane=%0d",
               gvram_writes - g0, last_gvram_addr, last_gvram_lanes, last_gvram_plane);
      errors = errors + 1;
    end
    gvram_access_page = 0;
    repeat (3) @(posedge clk);

    // A replacement pack download blocks CPU traffic from the loader's edge on: the cycle after
    // ioctl_download rises (the gate has no live ioctl term; check_download_gate_edges pins the
    // cycle), and before the loader can present its first word.
    @(negedge clk);
    ioctl_download = 1;
    @(negedge clk);
    cpu_valid = 1;
    #1;
    if (cpu_run || cpu_ready || mem_valid) begin
      $display("FAIL selected reload did not revoke CPU ownership");
      errors = errors + 1;
    end
    cpu_valid = 0;
    send_word(27'h003_0000, 16'h3412);
    repeat (2) @(posedge clk);
    ioctl_download = 0;
    repeat (3) @(posedge clk);
    if (font_writes != 1 || last_font_addr != 18'd0 ||
        last_font_data != 16'h3412 || last_write_addr != 32'h0203_0000) begin
      $display("FAIL font tap count=%0d addr=%05x data=%04x physical=%08x",
               font_writes, last_font_addr, last_font_data, last_write_addr);
      errors = errors + 1;
    end

    // THE JIS GRID IS NO LONGER IN M10K. A JIS word from the pack's glyph region
    // must NOT reach the font store: it stays in the pack's SDRAM copy and the GDC's fmem
    // reader fetches it into its row cache. The pack write itself must still land in SDRAM,
    // so this is the contract that the ANK tee (checked above) is the ONLY font M10K write.
    ioctl_download = 1;
    w0 = font_writes;
    send_word(27'h00A_4C00, 16'hABCD);
    repeat (2) @(posedge clk);
    ioctl_download = 0;
    repeat (3) @(posedge clk);
    if (font_writes != w0 || last_write_addr != (pack_base + 32'h000A_4C00)) begin
      $display("FAIL JIS tap font_writes=%0d (want %0d) physical=%08x (want %08x)",
               font_writes, w0, last_write_addr, pack_base + 32'h000A_4C00);
      errors = errors + 1;
    end

    // ---- THE JIS KU-BANK SWEEP: one code per bank, NONE may reach M10K ----
    // The JIS region lives in the pack's SDRAM copy now, so each bank's pack word must reach
    // SDRAM and NOT the font store. tb_pc9821_gdc_text pins the SCANOUT half (the walker's
    // per-cell fetch renders the dump's own bytes); this pins the loader half: the region is
    // still written to SDRAM (at pack 0x81800 + rel) and the fmem reader's own address
    // arithmetic (font base 0x1800 + row*0xC00 + ten*0x20) names that same pack address.
    begin : jis_banks
      integer bi;
      reg [26:0] b_pack;
      for (bi = 0; bi < NJIS; bi = bi + 1) begin
        b_pack = 27'h000_81800 + {7'd0, jis_rel[bi]};
        ioctl_download = 1;
        w0 = font_writes;
        send_word(b_pack, jis_data[bi]);
        repeat (2) @(posedge clk);
        ioctl_download = 0;
        repeat (3) @(posedge clk);
        if (font_writes != w0 || last_write_addr !== (pack_base + b_pack)) begin
          $display("FAIL JIS bank ku %02x ten %02x: pack %06x font_writes=%0d phys %08x",
                   jis_ku[bi], jis_ten[bi], b_pack, font_writes - w0, last_write_addr);
          errors = errors + 1;
        end
      end
      // The region's own top: FONT.ROM[0x43C40] must reach SDRAM at pack 0xC3C40 and nowhere
      // in M10K - a short word slice would have aliased it onto a low bank's store word.
      ioctl_download = 1;
      w0 = font_writes;
      send_word(27'h000_C3C40, 16'h1511);
      repeat (2) @(posedge clk);
      ioctl_download = 0;
      repeat (3) @(posedge clk);
      if (font_writes != w0 || last_write_addr !== (pack_base + 32'h000C_3C40)) begin
        $display("FAIL JIS tail: pack C3C40 font_writes=%0d phys %08x",
                 font_writes - w0, last_write_addr);
        errors = errors + 1;
      end
      $display("  JIS ku-bank sweep: %0d codes + the region tail checked against FONT.ROM", NJIS);
    end

    // ---- two accesses to one route with cpu_valid HELD ------------------
    // The shape every responder must survive, and the one no bench covered: a
    // CPU is not obliged to present one request per valid, so a responder that
    // leaves its accept state only when valid drops deadlocks -- the second
    // access never gets ready and the guest wedges mid-instruction. z486 does
    // exactly this on two consecutive accesses to one route (it holds the
    // request up while it finalizes the previous one), and the authentic ITF
    // hits it at BANK4@0x4CE4D/0x4CE51: two back-to-back stores/loads to the
    // 0xE4000 plane window, which stopped POST 551,000 cycles in with 0xE401C
    // outstanding. The bound turns "wedged" into a named
    // failure instead of a hang, for every route a CPU access can reach.
    check_valid_held_pair(32'h000A_0000, 32'h000A_0004, 1'b0);  // TRAM
    check_valid_held_pair(32'h000A_4000, 32'h000A_4008, 1'b0);  // CG window
    // The GVRAM route completes a store at the backend accept, so its pair is a
    // store pair -- which is exactly the ITF's shape at BANK4@0x4CE4D/0x4CE51.
    check_valid_held_pair(32'h000A_8001, 32'h000A_8005, 1'b1);  // GVRAM plane window
    check_valid_held_pair(32'h000E_4009, 32'h000E_401C, 1'b1);  // ...and the ITF's own pair
    check_valid_held_pair(32'h000C_0000, 32'h000C_0004, 1'b0);  // absent ROM area (open bus)

    // The route-ownership case: a route's answer must not be delivered because
    // another route's backend completion arrived, and the mapper must never be
    // told it was accepted during a transaction it does not own.
    check_no_stolen_answer;
    check_stolen_answer_at_clock_edge;

    // The decode is exclusive, walked rather than waited for. The fine sweep
    // covers 0xA0000-0xFFFFF because that is the only span in which any of the
    // four selects can be true; the coarse ones cover the rest of the low MiB and
    // the open-bus space above RAM, and the whole family is repeated across window
    // bases because gvram_select depends on window 0's bias.
    check_route_decode_is_exclusive(32'h000A_0000, 32'h000F_FFFF, 1,    8'h08);
    check_route_decode_is_exclusive(32'h0000_0000, 32'h0009_FFFF, 64,   8'h08);
    check_route_decode_is_exclusive(32'h000A_0000, 32'h000F_FFFF, 16,   8'h00);
    check_route_decode_is_exclusive(32'h000A_0000, 32'h000F_FFFF, 16,   8'h0E);
    check_route_decode_is_exclusive(32'h000A_0000, 32'h000F_FFFF, 16,   8'h0C);
    check_route_decode_is_exclusive(32'h000A_0000, 32'h000F_FFFF, 16,   8'hFF);
    check_route_decode_is_exclusive(32'h0010_0000, 32'h0040_0000, 1024, 8'h08);
    check_route_decode_is_exclusive(32'hFF00_0000, 32'hFFFF_FFFF, 65536, 8'h08);
    $display("decode sweeps finished at t=%0t of the bench's 20 ms budget", $time);
    check_decode_coverage;
    win0_sel = 8'h08;
    cpu_addr = 0;

    // And the case the hardware actually failed on: a mapped read whose backend
    // response arrives SEVERAL cycles after its accept, as the SDRAM controller's
    // read latency requires. The record of who the backend accepted must outlive
    // the accept, or the answer is dropped and the CPU waits forever.
    check_slow_backend_response(4);
    check_download_gate_edges;
  // ==== VERDICT ====

    if (errors == 0) begin
        $display("TB_PC9821_MEMORY_SUBSYSTEM: PASS");
        $finish;
    end
    else $fatal(1, "TB_PC9821_MEMORY_SUBSYSTEM: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog. The runner also bounds wall time
  // (BENCH_TIMEOUT) and greps the PASS marker, but a bench that
  // blocks on a DUT signal with no bound would hang CI forever.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_MEMORY_SUBSYSTEM: TIMEOUT");
  end

endmodule


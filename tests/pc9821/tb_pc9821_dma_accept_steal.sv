`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DMA_ACCEPT_STEAL: a DMA request raised 1-3 clk_sys after a CPU request has been launched at the backend cannot steal that request's accept - the presenting owner is tagged from presentation to the one-cycle ack, so the CPU's byte is committed exactly once with its own payload and its read response is still returned, and the DMA's own byte is committed exactly once on its own accept; with the unlocked mux the CPU's ack is consumed as dma_ready, the in-flight payload moves under the bridge's bare crossing and the floppy byte is dropped. A DMA memory READ (the uPD71071's memory-to-port direction, a floppy WRITE DATA's bytes) is answered to the DMA with the backend's own word, alone and with a CPU read in flight beside it, each response reaching only the requester whose read it is (fdd-write: the subsystem had no DMA read response at all, so a floppy write hung on hardware).
//
// WHY THIS EXISTS. The port-0 request mux in
// pc9821_memory_subsystem had no notion of which owner's request the backend had
// LAUNCHED: `dma_owns = dma_valid && !loader_owns` was free to move while a CPU
// request was in flight, and `mem_ready` is a raw one-cycle ack not tagged to a
// requester (sdram.v's registered ready pulse, through sdram_sync_bridge). A dma_valid rising in
// that window consumed the CPU's ack as dma_ready - the uPD71071 advanced on an
// accept its byte never got, the floppy byte was dropped, and a hijacked READ's
// response-route entry was never pushed, so the CPU waited forever. The fix tags
// the presenting owner until the ack (pc9821_memory_subsystem's launched-owner
// lock); this bench pins the tag by driving the two requesters against each other
// at every offset the window allows.
//
// THE BACKEND IS MODELLED ON PURPOSE, at the bridge's own launch contract: a
// request is CAPTURED at its first presentation cycle (the bare crossing - the
// controller latches the payload then), the one-cycle ack comes ACK_LAT clk_sys
// later, the payload must hold until that ack, and the committed transaction is
// the CAPTURED payload. That is the SDRAM bridge's contract with its own
// requester check left OUT - the check's $fatal is exactly what
// hides the audit's dropped byte from simulation, aborting the run before any
// byte-level assertion can name it. The stimulus raises dma_valid 1, 2 and 3
// clk_sys after the CPU request's launch, the whole ack window, and each case
// asserts the audit's own contract: every request commits EXACTLY ONCE with ITS
// OWN payload, and a read's response is still returned to its requester.
//
// FAIL-FIRST: before the lock the mux moves under the launch at every offset -
// the model counts the payload move and the commit record loses the DMA's byte
// and duplicates the CPU's - and the run fails by name.

module tb_pc9821_dma_accept_steal;
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

  // Exactly one commit with this payload in the record (a duplicate - the stolen
  // accept's retry - or a missing one both fail).
  function automatic commit_seen(input wr, input [31:0] addr, input [31:0] din,
                                 input [3:0] be);
    integer n, q;
    begin
      n = 0;
      for (q = 0; q < 8; q = q + 1)
        if ((q < b_commits) && (b_c_wr[q] === wr) && (b_c_addr[q] === addr) &&
            (b_c_be[q] === be) && (!wr || (b_c_din[q] === din)))
          n = n + 1;
      commit_seen = (n == 1);
    end
  endfunction

  // The pack download (tb_pc9821_memory_subsystem's shape): one word is enough to
  // close the window and release cpu_run.
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

  // The per-case record: the CPU's request and the DMA's, presented together with
  // the DMA raised `k` clk_sys after the CPU request's LAUNCH (the first cycle the
  // store buffer puts it on the backend).
  task automatic run_case(input [8*28-1:0] tag, input integer k,
                          input is_write, input use_dma);
    integer g, cpu_seen, dma_seen, resps, cpu_hold, dma_hold;
    reg [31:0] resp_data;
    begin
      b_commits = 0;
      b_payload_moves = 0;
      resps = 0;
      // Re-seed the read target: the earlier write cases overwrite this word.
      if (!is_write) b_mem[32'h0000_1000 >> 2] = 32'h5A5A_0F0F;

      cpu_addr = 32'h0000_1000;
      cpu_din  = 32'hCAFE_1000;
      cpu_be   = 4'hF;
      cpu_burstcount = 8'd1;
      cpu_line_read = 1'b0;
      cpu_write = is_write;
      // The DMA byte's address is loaded before either request is up (the DMAC loads its
      // address a cycle before it presents, pc9821_dmac mem_load); the presentation is below.
      if (use_dma) dma_addr = 32'h0000_2001;
      cpu_valid = 1'b1;

      g = 0;
      while (!dut.buf_mem_valid && g < 200) begin @(negedge clk); g = g + 1; end
      if (!dut.buf_mem_valid)
        $fatal(1, "%0s: the CPU request never reached the backend (map_valid=%b buf_valid=%b pres_locked=%b in_rd_block=%b rt %0d/%0d b_state=%0d cpu_ready=%b)",
               tag, dut.map_valid, dut.buf_mem_valid, dut.u_storebuf.pres_locked,
               dut.u_storebuf.in_rd_block, dut.rt_wr, dut.rt_rd, b_state, cpu_ready);

      if (use_dma) begin
        repeat (k) @(negedge clk);
        dma_din   = 32'h5C5C_5C5C;
        dma_be    = 4'b0010;
        dma_write = 1'b1;
        dma_valid = 1'b1;
      end

      cpu_seen = 0;
      dma_seen = use_dma ? 0 : 1;
      cpu_hold = 0;
      dma_hold = 0;
      g = 0;
      while (!((cpu_seen && (cpu_hold >= 2)) &&
               (!use_dma || (dma_seen && (dma_hold >= 2)))) && (g < 400)) begin
        @(negedge clk);
        if (!cpu_seen && cpu_valid && cpu_ready) cpu_seen = 1;
        if (!dma_seen && dma_valid && dma_ready) dma_seen = 1;
        // Each request holds THROUGH its accept's sampling edge and drops on the
        // NEXT negedge (the tree's own port_wr shape): dropping on the accept
        // cycle's negedge moves the payload before the DUT's accept edge, and
        // holding past it re-presents the request to the store buffer.
        if (cpu_seen) begin
          if (cpu_hold >= 1) begin cpu_valid = 1'b0; cpu_write = 1'b0; end
          cpu_hold = cpu_hold + 1;
        end
        if (use_dma && dma_seen) begin
          if (dma_hold >= 1) dma_valid = 1'b0;
          dma_hold = dma_hold + 1;
        end
        // the read's response, counted as it returns
        if (cpu_resp_valid) begin
          resps = resps + 1;
          resp_data = cpu_dout;
        end
        g = g + 1;
      end
      if (!cpu_seen) $fatal(1, "%0s: the CPU request was never accepted", tag);
      if (use_dma && !dma_seen) $fatal(1, "%0s: the DMA request was never accepted", tag);
      cpu_valid = 1'b0;
      cpu_write = 1'b0;
      dma_valid = 1'b0;

      // Let any late response land, then judge.
      for (g = 0; g < 40; g = g + 1) begin
        @(negedge clk);
        if (cpu_resp_valid) begin
          resps = resps + 1;
          resp_data = cpu_dout;
        end
      end

      // ---- the audit's contract: each request committed EXACTLY ONCE, with its
      //      OWN payload, and a read's response still returned ----
      if (b_payload_moves != 0) begin
        $display("FAIL %0s: the request mux moved the in-flight payload %0d time(s) between launch and ack", tag, b_payload_moves);
        errors = errors + 1;
      end
      if (b_commits != (use_dma ? 2 : 1)) begin
        $display("FAIL %0s: the backend committed %0d transaction(s), expected %0d - a stolen accept drops one request's byte and duplicates the other's", tag, b_commits, (use_dma ? 2 : 1));
        errors = errors + 1;
      end
      if (!commit_seen(is_write, 32'h0000_1000, 32'hCAFE_1000, 4'hF)) begin
        $display("FAIL %0s: the CPU's request was not committed exactly once with its own payload", tag);
        errors = errors + 1;
      end
      if (use_dma && !commit_seen(1'b1, 32'h0000_2001, 32'h5C5C_5C5C, 4'b0010)) begin
        $display("FAIL %0s: the DMA's byte was never committed - the floppy byte is dropped", tag);
        errors = errors + 1;
      end
      if (!is_write) begin
        if (resps != 1) begin
          $display("FAIL %0s: the CPU's read saw %0d response(s), expected exactly 1", tag, resps);
          errors = errors + 1;
        end else if (resp_data !== 32'h5A5A_0F0F) begin
          $display("FAIL %0s: the CPU's read answered %08x, want 5A5A0F0F (the backend storage's own word)", tag, resp_data);
          errors = errors + 1;
        end
      end
      repeat (4) @(negedge clk);
    end
  endtask

  // Exactly one commit with this payload in the record (a duplicate - the stolen
  // accept's retry - or a missing one both fail) - see commit_seen above.

  // A DMA memory READ (WRITE DATA's memory-to-port byte). Its one response beat must reach
  // dma_resp_valid with the backend's word and must NOT be taken by the CPU's route; with a
  // CPU read launched first (`with_cpu`, the DMA raised k clk later) each requester gets
  // exactly its own word. FAIL-FIRST: the subsystem tied dma_resp_valid to 0 (and a DMA read
  // tripped a $fatal under Verilator), so the uPD71071 waited in S_RESP forever.
  task automatic run_dma_read(input [8*28-1:0] tag, input integer k, input with_cpu);
    integer g, cpu_seen, dma_seen, cpu_resps, dma_resps, cpu_hold, dma_hold;
    reg [31:0] cpu_data, dma_data;
    begin
      b_mem[32'h0000_1000 >> 2] = 32'h5A5A_0F0F;
      b_mem[32'h0000_2000 >> 2] = 32'hD4D3_D2D1;
      cpu_resps = 0; dma_resps = 0;
      cpu_seen = with_cpu ? 0 : 1;
      dma_addr = 32'h0000_2002;   // loaded before the presentation below (pc9821_dmac mem_load)
      @(negedge clk);
      if (with_cpu) begin
        cpu_addr = 32'h0000_1000; cpu_be = 4'hF; cpu_burstcount = 8'd1;
        cpu_line_read = 1'b0; cpu_write = 1'b0; cpu_valid = 1'b1;
        g = 0;
        while (!dut.buf_mem_valid && g < 200) begin @(negedge clk); g = g + 1; end
        repeat (k) @(negedge clk);
      end
      dma_be = 4'b0100; dma_din = 32'd0;
      dma_write = 1'b0; dma_valid = 1'b1;
      dma_seen = 0; cpu_hold = 0; dma_hold = 0;
      g = 0;
      while (!(cpu_seen && dma_seen && (dma_hold >= 2) && (!with_cpu || cpu_hold >= 2)) && g < 400) begin
        @(negedge clk);
        if (!cpu_seen && cpu_valid && cpu_ready) cpu_seen = 1;
        if (!dma_seen && dma_valid && dma_ready) dma_seen = 1;
        if (with_cpu && cpu_seen) begin
          if (cpu_hold >= 1) cpu_valid = 1'b0;
          cpu_hold = cpu_hold + 1;
        end
        if (dma_seen) begin
          if (dma_hold >= 1) dma_valid = 1'b0;
          dma_hold = dma_hold + 1;
        end
        if (cpu_resp_valid) begin cpu_resps = cpu_resps + 1; cpu_data = cpu_dout; end
        if (dma_resp_valid) begin dma_resps = dma_resps + 1; dma_data = dma_dout; end
        g = g + 1;
      end
      cpu_valid = 1'b0; dma_valid = 1'b0;
      for (g = 0; g < 40; g = g + 1) begin
        @(negedge clk);
        if (cpu_resp_valid) begin cpu_resps = cpu_resps + 1; cpu_data = cpu_dout; end
        if (dma_resp_valid) begin dma_resps = dma_resps + 1; dma_data = dma_dout; end
      end
      if (!dma_seen) begin
        $display("FAIL %0s: the DMA read was never accepted", tag); errors = errors + 1;
      end
      if (dma_resps != 1) begin
        $display("FAIL %0s: the DMA read saw %0d response(s), expected exactly 1 (the engine waits in S_RESP for it)", tag, dma_resps);
        errors = errors + 1;
      end else if (dma_data !== 32'hD4D3_D2D1) begin
        $display("FAIL %0s: the DMA read answered %08x, want D4D3D2D1", tag, dma_data);
        errors = errors + 1;
      end
      if (cpu_resps != (with_cpu ? 1 : 0)) begin
        $display("FAIL %0s: the CPU route saw %0d response(s), expected %0d (a DMA beat must not reach it)", tag, cpu_resps, with_cpu ? 1 : 0);
        errors = errors + 1;
      end else if (with_cpu && (cpu_data !== 32'h5A5A_0F0F)) begin
        $display("FAIL %0s: the CPU read answered %08x, want 5A5A0F0F", tag, cpu_data);
        errors = errors + 1;
      end
      repeat (4) @(negedge clk);
    end
  endtask

// ==== CHECKS ====

  initial begin
    #80_000_000;
    $fatal(1, "TB_PC9821_DMA_ACCEPT_STEAL: watchdog timeout (no verdict reached)");
  end

  initial begin
    reset = 1;
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // The pack download releases cpu_run (the loader owns the backend while it runs).
    // Wait for the loader's own done: its word drains through the modelled backend,
    // which costs a few cycles more than an immediate stub would.
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
      $fatal(1, "the pack download did not release the CPU (rom_ready=%b cpu_run=%b err=%b)",
             rom_ready, cpu_run, load_error);

    // The read target's storage word, so the response is checkable by value.
    b_mem[32'h0000_1000 >> 2] = 32'h5A5A_0F0F;

    // ---- controls: one requester at a time (the model's own sanity) ----
    run_case("control cpu-only write", 0, 1'b1, 1'b0);
    run_case("control cpu-only read",  0, 1'b0, 1'b0);

    // ---- the steal: a DMA request raised 1-3 clk_sys after the CPU's launch ----
    run_case("write steal k=1", 1, 1'b1, 1'b1);
    run_case("write steal k=2", 2, 1'b1, 1'b1);
    run_case("write steal k=3", 3, 1'b1, 1'b1);
    run_case("read steal k=1",  1, 1'b0, 1'b1);
    run_case("read steal k=2",  2, 1'b0, 1'b1);
    run_case("read steal k=3",  3, 1'b0, 1'b1);

    // ---- a DMA memory READ (the floppy WRITE DATA direction) ----
    run_dma_read("dma read alone", 0, 1'b0);
    run_dma_read("dma read beside cpu k=1", 1, 1'b1);
    run_dma_read("dma read beside cpu k=3", 3, 1'b1);

// ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_DMA_ACCEPT_STEAL: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_DMA_ACCEPT_STEAL: FAIL (%0d errors)", errors);
    end
  end

endmodule

`default_nettype wire

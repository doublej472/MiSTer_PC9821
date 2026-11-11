`timescale 1ns/1ps
`include "sdram_sync_bench.svh"   // the SDRAM bench clock: the controller on clk_sys

// ==== WHAT THIS PROVES ====
// TB_PC9821_SUBSYSTEM_STALLS: the INTER-SUBSYSTEM handshakes complete under adversarial interleavings, or a scenario that genuinely wedges FAILS BY NAME instead of hanging the runner. The whole pc9821_memory_subsystem (the route queue, the mapper, the real GVRAM with its WCB + M10K cache, the font requester, the scanout line fetch) runs over the REAL SDRAM bridge and the REAL src/memory/sdram.v controller (on clk_sys, as every build runs it) against the chip model.
//
// The scenarios, each with a bounded wait and its own failure name. A - K are the
// handshakes that must complete; the mux-moved counter records any launch whose payload the
// request mux moved under (the one latent hazard found).
//   A  control: mapped RAM write/read and a 4-word line read across the bridge.
//   B  a 64-read valid-held stream on port 0 (the route queue holds two accepts, drains).
//   C  CPU + scanout + font all pending at once (ports 0, 1 and 3 together).
//   D  a scanout burst crossing an SDRAM row while a refresh is due, plus a CPU burst.
//   E  a POSTED write followed by a SAME-WORD read (full-word, WCB-resident and EGC-posted),
//      each asserted by value.
//   F  reset asserted with a route owed and a scanout burst outstanding.
//   G  a dirty WCB word behind a scanout line tick: the flush and the scanout both complete.
//   H  the GVRAM write-back flush owning port 0 while mapped reads are presented.
//   I  a 128-bit GVRAM plane line read (16 column reads) through the bridge.
//   J  two back-to-back GVRAM stores with `valid` held (the ITF 0x4CE4D/0x4CE51 shape).
//   K  a mapped read presented immediately behind a posted EGC write.
//
// Every wait is bounded, so a true stall becomes a FAIL with its scenario name and the run
// exits non-zero rather than hanging.

`default_nettype none

module tb_pc9821_subsystem_stalls;
  // pc9821_memory_subsystem's pack-download hold: no boot-ROM download under the OSD Reset
  // level here (tb_pc9821_boot0_load drives that), so the level is low and the hold unread.
  wire hps_apply_reset = 1'b0;
  wire pack_load_hold;
  localparam integer CYCLE_SYS_NS   = 20;
  localparam integer CAS = 2;                  // CAS_I = 2 below 100 MHz

  reg clk = 0;
  always #(CYCLE_SYS_NS/2)   clk = ~clk;      // 50 MHz: the subsystem AND the SDRAM controller
  reg reset = 1;

  integer tb_cycle = 0;
  always @(posedge clk) tb_cycle = tb_cycle + 1;
  integer errors = 0;

  // The commit-log the failure names come from: the last accepted port-0 request and the route
  // the subsystem credited it to, so a stall can be reported with its owner, not just "hung".
  reg [1:0]  last_owner = 2'd0;
  reg        last_write = 1'b0;
  reg [31:0] last_addr = 32'd0;
  integer    last_accept_cycle = 0;
  always @(posedge clk) if (mem_ready && mem_valid) begin
    last_owner       = dut.loader_owns ? 2'd1 : 2'd2;   // 1 = loader, 2 = mapper (the only port-0 owners)
    last_write       = mem_write;
    last_addr        = mem_addr;
    last_accept_cycle = tb_cycle;
  end

  // ==== DUT ====
  reg [3:0]  top_bank = 4'd8;
  reg        ide_rom_enable = 0;
  reg        ide_ram_gate = 1;
    // 0x1E8E's IDE work-RAM gate: held ON so nothing here sees the gated
    // shape - tb_pc9821_memory_subsystem and tb_pc9821_memory_map pin it.
  reg        bios_ram_gate = 0;
  reg [7:0]  win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  reg        top_shadow_en = 0;
  reg  soft_reboot = 1'b0;   // no reboot strobe in this bench
  reg        sys16m_en = 1'b1;
  reg [31:0] pack_base = 32'h0200_0000;
  reg [31:0] guest_ram_bytes = 32'h0200_0000;
  reg        gvram_access_page = 0;

  reg        grcg_we = 0;
  reg [7:0]  grcg_addr = 0;
  reg [7:0]  grcg_din = 0;
  wire       grcg_expand;
  wire       grcg_expand_nx;   // mode[7]'s next state (opt-video VID-1); unused here


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

  wire [17:0] font_addr;
  wire [15:0] font_data;
  wire        font_we;

  reg [31:0] cpu_addr = 0, cpu_din = 0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  reg [3:0]  cpu_be = 4'hF;
  reg [7:0]  cpu_burstcount = 8'd1;
  reg        cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  wire       cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  wire [13:0] tram_addr;
  wire [7:0]  tram_din;
  wire        tram_we;
  reg  [7:0]  tram_dout = 0;

  wire [4:0] cg_win_byte_sel;
  wire       cg_win_rd;
  reg  [7:0] cg_win_dout = 0;
  wire [7:0] cg_win_din;
  wire       cg_win_we;

  reg [18:0] font_req_addr = 0;
  reg        font_req = 0;
  wire       font_word_valid;
  wire [31:0] font_word_data;

  wire [31:0] fmem_addr, fmem_din;
  wire        fmem_valid, fmem_write, fmem_ready, fmem_resp_valid;
  wire  [3:0] fmem_be;
  wire  [7:0] fmem_burstcount;
  wire [31:0] fmem_dout;

  wire [1:0] ems_state;

  wire [31:0] mem_addr, mem_din;
  wire [31:0] mem_dout;
  wire [127:0] mem_line_dout;
  wire  [3:0] mem_be;
  wire  [7:0] mem_burstcount;
  wire        mem_line_read, mem_valid, mem_write, mem_ready, mem_resp_valid;
  wire        mem_line_resp_valid;
  wire [31:0] mem_din_hi;
  // The G3 gather session's qualifier and entries (the subsystem's mem_gath* outputs,
  // carried into the bridge; the store buffer groups its drains with them) and the
  // geometry its row key needs.
  wire        mem_gath;
  wire [440:0] mem_gath_extra;
  wire  [1:0] sdram_size = 2'd2;

  wire [31:0] mem3_addr, mem3_din;
  wire  [3:0] mem3_be;
  wire  [7:0] mem3_burstcount;
  wire        mem3_valid, mem3_write, mem3_ready, mem3_resp_valid;
  wire [31:0] mem3_dout;

  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire [1:0]  SDRAM_BA, SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS, CKE;
  wire        busy;

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

  // The plain-window client's ownership pulse (pc9821_memory_subsystem's dbg_pw_owned,
  // added 2026-10-03 so the page-coincidence counter covers plain stores too). `.*` needs a
  // matching net here; this bench does not read it.
  wire dbg_pw_owned;

  // 0x063C bank select into the 0xD8000 window: 0 = the IDE option ROM, the reset bank.

  reg  [1:0] d8_bank = 2'b00;
  // The 16-colour select (port 0x6A FF2 num 0): 0 = the digital mode the machine resets to,
  // where 0xE0000-0xE7FFF is open bus (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b0;

  pc9821_memory_subsystem dut (.*);

  sdram_sync_bridge #(
      .FREQ(`TB_SDRAM_FREQ), .FAST_GRADE(1'b0)
  ) bridge (
      .clk(clk), .resetn(~reset),
      .refresh_allowed(1'b1), .busy(busy), .sdram_size(2'd2),
      .valid0(mem_valid), .ready0(mem_ready), .wr0(mem_write),
      .addr0(mem_addr[26:0]), .din0(mem_din), .din0_hi(mem_din_hi), .gath0(mem_gath), .gath0_extra(mem_gath_extra), .dout0(mem_dout),
      .be0(mem_be), .resp_valid0(mem_resp_valid), .burst_cnt0(mem_burstcount[3:0]),
      .valid1(fmem_valid), .ready1(fmem_ready), .wr1(fmem_write),
      .addr1(fmem_addr[26:0]), .din1(fmem_din), .dout1(fmem_dout),
      .be1(fmem_be), .resp_valid1(fmem_resp_valid), .burst_cnt1(fmem_burstcount[3:0]),
      .valid2(mem3_valid), .ready2(mem3_ready), .wr2(mem3_write),
      .addr2(mem3_addr[26:0]), .din2(mem3_din), .dout2(mem3_dout),
      .be2(mem3_be), .resp_valid2(mem3_resp_valid), .burst_cnt2(mem3_burstcount[3:0]),
      .SDRAM_DQ(DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQM(SDRAM_DQM),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nCS(nCS),
      .SDRAM_CKE(CKE)
  );

  // The built design ties the line response off (z486_mister.sv); the word path answers.
  assign mem_line_resp_valid = 1'b0;

  sdram_chip_model #(.CAS(CAS), .T_RP(`TB_CHIP_TRP), .T_WR(`TB_CHIP_TWR)) chip (
      .clk(clk), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // ==== CHECKS ====
  integer line_sel_edges = 0;
  reg     line_sel_d = 0;
  integer refresh_seen = 0;
  integer font_beats = 0;
  always @(posedge clk) begin
    if (line_sel != line_sel_d) line_sel_edges = line_sel_edges + 1;
    line_sel_d <= line_sel;
    if (font_word_valid) font_beats = font_beats + 1;
  end
  always @(posedge clk)
    if (bridge.ctrl.state == 4'd7) refresh_seen = refresh_seen + 1;   // REFRESH

  // The mux-moved detector: record the payload at the bridge's port-0 LAUNCH, then compare it
  // with the payload at the ACK. If they differ, the request mux moved between the launch and
  // the registration of the accept -- the subsystem would then credit the accept to a route that
  // never launched, and the launched route would be owed a response forever.
  // STRENGTHENED: the move is safe only because the launch's route RETRIES
  // -- its ready is mux-gated low, so it never consumes an accept for a payload it did not
  // present. Assert that here, so the invariant is checked rather than incidental.
  // The launch: the first cycle a request is presented, which is when the controller can first
  // take it (the removed clock-domain bridge had its own req_launch register for this).
  reg  tb_wait0 = 1'b0;
  always @(posedge clk) tb_wait0 <= mem_valid && !mem_ready;
  wire tb_launch0 = mem_valid && !tb_wait0;
  reg [31:0] launch_addr = 32'd0;
  reg        launch_wr = 1'b0;
  reg  [1:0] launch_owner = 2'd0;
  integer    mux_moved = 0;
  always @(posedge clk) begin
    if (tb_launch0) begin
      launch_addr = mem_addr; launch_wr = mem_write;
      launch_owner = dut.loader_owns ? 2'd1 : 2'd2;   // 1 = loader, 2 = mapper
    end else if (mem_ready && mem_valid && (mem_addr !== launch_addr || mem_write !== launch_wr)) begin
      if (mux_moved == 0)
        $display("MUXMOVED t=%0d launch=%08x/%b ack=%08x/%b owner=%0d", tb_cycle,
                 launch_addr, launch_wr, mem_addr, mem_write, launch_owner);
      mux_moved = mux_moved + 1;
      if (launch_owner == 2'd1 && dut.load_ready)
        begin errors = errors + 1; $display("FAIL: moved launch let the launched loader consume the accept"); end
      if (launch_owner == 2'd3 && 1'b0)
        begin errors = errors + 1; $display("FAIL: moved launch let the launched GVRAM consume the accept"); end
      if (launch_owner == 2'd2 && dut.map_ready)
        begin errors = errors + 1; $display("FAIL: moved launch let the launched mapper consume the accept"); end
    end
  end

  // Route-queue depth, so a scenario can state the wedge's shape (accepted, never retired).
  wire [2:0] rt_depth = dut.rt_wr - dut.rt_rd;

  task automatic fail(input [255:0] what);
    begin
      errors = errors + 1;
      $display("FAIL subsystem_stalls: %0s (tb_cycle=%0d)", what, tb_cycle);
    end
  endtask

  // A global watchdog turns any wedged wait into a named non-zero exit, never a hung runner.
  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_SUBSYSTEM_STALLS: TIMEOUT");
  end

  // ==== STIMULUS ====
  task automatic load_rom;
    begin
      ioctl_download = 1;
      ioctl_addr = 27'd0;
      ioctl_dout = 16'hBEEF;
      ioctl_wr = 1;
      @(posedge clk);
      ioctl_wr = 0;
      repeat (2) @(posedge clk);
      ioctl_download = 0;
      while (!rom_ready) @(posedge clk);
      if (!cpu_run) fail("rom: cpu_run low after the pack download");
    end
  endtask

  integer init_guard;
  task automatic wait_idle;
    begin
      init_guard = 0;
      while (busy && init_guard < 200000) begin @(posedge clk); init_guard = init_guard + 1; end
      if (busy) fail("the SDRAM controller never left its initialization");
    end
  endtask

  function automatic [31:0] win_addr(input [1:0] plane, input [14:0] off);
    begin
      case (plane)
        2'd0:    win_addr = 32'h000A_8000 + {17'd0, off};
        2'd1:    win_addr = 32'h000B_0000 + {17'd0, off};
        2'd2:    win_addr = 32'h000B_8000 + {17'd0, off};
        default: win_addr = 32'h000E_0000 + {17'd0, off};
      endcase
    end
  endfunction

  integer g;
  integer g2;
  task automatic cpu_access(input [31:0] addr, input [31:0] din, input [3:0] be,
                            input wr, input line_rd, input [7:0] burst,
                            output [31:0] dout, output ok);
    begin
      @(negedge clk);
      cpu_addr = addr; cpu_din = din; cpu_be = be;
      cpu_write = wr; cpu_line_read = line_rd; cpu_burstcount = burst;
      cpu_valid = 1'b1;
      g = 0;
      while (!cpu_ready && g < 3000) begin @(negedge clk); g = g + 1; end
      if (!cpu_ready) begin
        fail("a CPU access never got `ready` (valid-without-ready wedge)");
        $display("   addr=%08x wr=%b gvram bstate=%0d m_mode=%b flush=%b cc_valid=%b cc_ready=%b | rt wr=%0d rd=%0d left=%0d | last ACC owner=%0d wr=%b addr=%08x",
                 addr, wr, dut.u_gvram_arb.gstate, dut.u_gvram_arb.m_mode, 1'b0,
                 dut.u_gvram_arb.cc_valid, dut.u_gvram_arb.cc_ready, dut.rt_wr, dut.rt_rd, dut.rt_left,
                 last_owner, last_write, last_addr);
        ok = 1'b0;
      end else begin
        // z486 releases the request on the posedge that samples `ready` (memory.sv clears
        // ext_valid_r on the accept), so `valid` is high for exactly the ready cycle. The
        // one-outstanding bridge request handshake depends on it: a valid still up after the
        // ack re-launches, which masks a misattributed accept. Hold `valid` through the ready
        // edge (so the accept registers), then drop it just after that edge. The 1 ns avoids a
        // same-edge race between this task and the DUT's sampling of cpu_valid.
        @(posedge clk);
        #1 cpu_valid = 1'b0;
        if (!wr) begin
          g = 0;
          while (!cpu_resp_valid && g < 3000) begin @(negedge clk); g = g + 1; end
          if (!cpu_resp_valid) begin
            fail("a CPU read was accepted but never answered (response owed, never produced)");
            $display("   addr=%08x rt wr=%0d rd=%0d left=%0d | last ACC owner=%0d wr=%b addr=%08x (accepted tb_cycle=%0d)",
                     addr, dut.rt_wr, dut.rt_rd, dut.rt_left,
                     last_owner, last_write, last_addr, last_accept_cycle);
            $display("   now: cpu_ready=%b mem_valid=%b mem_ready=%b map_valid=%b map_ready=%b gvram_cb_valid=%b loader_owns=%b load_valid=%b cpu_run=%b selects t%bc%bo%bg%b",
                     cpu_ready, mem_valid, mem_ready, dut.map_valid, dut.map_ready,
                     1'b0, dut.loader_owns, dut.load_valid, cpu_run,
                     dut.tram_select, dut.cg_win_select, dut.open_select, dut.gvram_select);
            ok = 1'b0;
          end else begin
            // The response is word beats everywhere now (the beat-uniform fill): a
            // cache-line read answers as `burst` beats, the first one the returned
            // word (the line form's word 0 - byte-identical,
            // tb_pc9821_fill_beat_uniform), and the rest are drained here so the
            // next access cannot be answered by this fill's beats.
            dout = cpu_dout;
            ok = 1'b1;
            for (g2 = 1; g2 < burst; g2 = g2 + 1) begin
              @(negedge clk);
              g = 0;
              while (!cpu_resp_valid && g < 3000) begin @(negedge clk); g = g + 1; end
              if (!cpu_resp_valid) begin
                fail("a line fill's beat never arrived (the 4-beat fill is incomplete)");
                ok = 1'b0;
              end
            end
          end
        end else begin
          dout = 32'd0; ok = 1'b1;
        end
      end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_line_read = 1'b0; cpu_burstcount = 8'd1;
      cpu_be = 4'hF;
    end
  endtask

  task automatic plane_store(input [1:0] plane, input [14:0] off, input [31:0] data, output ok);
    reg [31:0] d;
    begin
      cpu_access(win_addr(plane, off & 15'hFFF8), data, 4'hF, 1'b1, 1'b0, 8'd1, d, ok);
    end
  endtask

  task automatic plane_load(input [1:0] plane, input [14:0] off, output [31:0] data, output ok);
    begin
      cpu_access(win_addr(plane, off & 15'hFFF8), 32'd0, 4'hF, 1'b0, 1'b0, 8'd1, data, ok);
    end
  endtask

  task automatic scan_line_start(input [14:0] base, input page);
    begin
      @(negedge clk);
      scan_enable   = 1'b1;
      scan_page     = page;
      scan_line_base = base;
      scan_line_tick = 1'b1;
      @(negedge clk);
      scan_line_tick = 1'b0;
    end
  endtask

  integer wg;
  task automatic scan_wait_line(output ok);
    begin
      wg = 0;
      while (!dut.u_gvram_scan.fill_complete && wg < 4000) begin @(negedge clk); wg = wg + 1; end
      if (!dut.u_gvram_scan.fill_complete) begin
        fail("a scanout line fetch never completed (scanout starved or its burst wedged)");
        ok = 1'b0;
      end else ok = 1'b1;
    end
  endtask

  task automatic egc_setup;
    begin
      egc_access = 16'hFFF0;
      egc_fgbg   = 16'h00FF;
      egc_ope    = 16'h3100;
      egc_mask   = 16'hFFFF;
      @(negedge clk); egc_sft = 16'h0000; egc_leng = 16'h000F; egc_shift_we = 1'b1;
      @(negedge clk); egc_shift_we = 1'b0;
    end
  endtask

  reg [31:0] d0, d1;
  reg ok0, ok1;
  integer k, s;
  integer h_bad, h_first_bad, h_overlap;
  reg [31:0] h_addr_saved;

  initial begin
    reset = 1'b1;
    repeat (8) @(posedge clk);
    reset = 1'b0;
    wait_idle;
    load_rom;
    repeat (20) @(posedge clk);

    // ---- A. control: mapped RAM across the real bridge and controller ----
    cpu_access(32'h0002_0000, 32'hCAFE_1234, 4'hF, 1'b1, 1'b0, 8'd1, d0, ok0);
    cpu_access(32'h0002_0000, 32'd0, 4'hF, 1'b0, 1'b0, 8'd1, d0, ok1);
    if (!ok0 || !ok1 || d0 !== 32'hCAFE_1234)
      fail("A control: the mapped read-after-write across the bridge did not return the written word");
    else
      $display("PASS A: mapped write/read across the CDC bridge returned %08x", d0);
    cpu_access(32'h0002_0100, 32'd0, 4'hF, 1'b0, 1'b1, 8'd4, d0, ok0);
    if (!ok0) fail("A control: the 4-word mapped line read never completed");
    else      $display("PASS A: mapped 4-word line read completed");

    // ---- B. a valid-held stream of reads on port 0 (route queue depth > 1) ----
    // Present back-to-back mapped reads with `valid` held from each `ready` straight into the
    // next access (no idle cycle), so the bridge has one read's response in flight when it
    // accepts the next. Repeated 32 times: the route queue must hold two accepts at a time,
    // retire them in order, and drain.
    begin : scen_b
      integer bb;
      for (bb = 0; bb < 32; bb = bb + 1) begin
        @(negedge clk);
        cpu_addr = 32'h0002_0200 + (bb[31:0] * 8); cpu_din = 32'd0; cpu_be = 4'hF;
        cpu_write = 1'b0; cpu_line_read = 1'b0; cpu_burstcount = 8'd1; cpu_valid = 1'b1;
        g = 0;
        while (!cpu_ready && g < 3000) begin @(negedge clk); g = g + 1; end
        @(negedge clk);
        cpu_addr = 32'h0002_0204 + (bb[31:0] * 8);
        g = 0;
        while (!cpu_ready && g < 3000) begin @(negedge clk); g = g + 1; end
        @(posedge clk);
        #1 cpu_valid = 1'b0;
        g = 0;
        while (!cpu_resp_valid && g < 3000) begin @(negedge clk); g = g + 1; end
        g = 0;
        while (!cpu_resp_valid && g < 3000) begin @(negedge clk); g = g + 1; end
      end
      cpu_valid = 1'b0;
      repeat (20) @(negedge clk);
      if (rt_depth != 3'd0)
        fail("B: the response-route queue was left non-empty after the read stream drained");
      else
        $display("PASS B: the 64-read valid-held stream drained its route queue");
    end

    // ---- C. CPU + scanout + font all pending at once (ports 0, 1 and 3) ----
    begin : scen_c
      integer be0;
      be0 = font_beats;
      scan_line_start(15'h0200, 1'b0);
      @(negedge clk);
      font_req_addr = 19'd0; font_req = 1'b1;
      // Release font_req as soon as the burst is ACCEPTED; holding it just lets a second burst
      // issue while the CPU access runs, which is not what this scenario counts.
      g = 0;
      while (dut.font_left == 4'd0 && g < 3000) begin @(negedge clk); g = g + 1; end
      font_req = 1'b0;
      cpu_access(win_addr(2'd2, 15'h0300), 32'h1020_3040, 4'hF, 1'b1, 1'b0, 8'd1, d0, ok0);
      scan_wait_line(ok1);
      g = 0;
      while (dut.font_left != 4'd0 && g < 3000) begin @(negedge clk); g = g + 1; end
      if (!ok0) fail("C: the CPU store never completed with scanout+font pending");
      if (!ok1) fail("C: the scanout line never completed with CPU+font pending");
      if (font_beats - be0 != 8) fail("C: the font glyph burst did not deliver 8 beats");
      if (ok0 && ok1 && (font_beats - be0 == 8))
        $display("PASS C: CPU + scanout + font all completed (font beats=%0d, line swaps=%0d)",
                 font_beats - be0, line_sel_edges);
    end

    // ---- D. a scanout burst crossing an SDRAM row while a refresh is due ----
    begin : scen_d
      integer r0, bad;
      r0 = refresh_seen; bad = 0;
      // Seed every address this scenario reads, so a response that is ROUTED to the wrong route
      // shows up as the wrong DATA and not only as a missing response.
      for (k = 0; k < 8; k = k + 1)
        cpu_access(32'h0002_1000 + (k * 4), 32'h5A00_0000 + k, 4'hF, 1'b1, 1'b0, 8'd1, d0, ok0);
      for (k = 0; k < 8; k = k + 1) begin
        scan_line_start(15'h03F8 + (k[14:0] * 15'd80), 1'b0);
        cpu_access(32'h0002_1000 + (k * 4), 32'd0, 4'hF, 1'b0, 1'b0, 8'd1, d0, ok0);
        if (!ok0) bad = 1;
        if (d0 !== (32'h5A00_0000 + k)) begin
          bad = 1;
          $display("FAIL D: read %08x from %08x, want %08x (a misrouted response)",
                   d0, 32'h0002_1000 + (k * 4), 32'h5A00_0000 + k);
        end
        scan_wait_line(ok1);
        if (!ok1) bad = 1;
      end
      if (bad) fail("D: a row-crossing scanout burst / CPU read did not complete correctly across a refresh");
      else if (refresh_seen == r0) fail("D: no REFRESH was issued, so the interleaving was not exercised");
      else $display("PASS D: 8 row-crossing lines + CPU reads completed correctly across %0d refreshes",
                    refresh_seen - r0);
    end

    // ---- E. POSTED write followed by a SAME-WORD read across the bridge ----
    plane_store(2'd0, 15'h0400, 32'hDEAD_BEEF, ok0);
    plane_load (2'd0, 15'h0400, d0, ok1);
    if (!ok0 || !ok1 || d0 !== 32'hDEAD_BEEF)
      fail("E1: a posted full-word GVRAM store was not read back by a same-word read");
    else
      $display("PASS E1: posted full-word store -> same-word read returned %08x", d0);
    cpu_access(win_addr(2'd0, 15'h0410), 32'h0000_5A00, 4'b0010, 1'b1, 1'b0, 8'd1, d0, ok0);
    cpu_access(win_addr(2'd0, 15'h0410), 32'd0, 4'hF, 1'b0, 1'b0, 8'd1, d0, ok1);
    if (!ok0 || !ok1 || d0[15:8] !== 8'h5A)
      fail("E2: a WCB-resident partial store was not forwarded to a same-word read");
    else
      $display("PASS E2: WCB partial store -> same-word read forwarded byte 0x%02x", d0[15:8]);
    begin : scen_e3
      reg [31:0] src, got;
      integer pg;
      // The posted-write shape: the EGC's 0x3100 put advances on the D1 ACCEPT, so the
      // SAME-WORD read that follows it is what must see the written data across the bridge.
      // Source on access page 1, destination on page 0, distinct values, asserted by data.
      egc_setup;
      gvram_access_page = 1'b1;
      plane_store(2'd0, 15'h0500, 32'hA5A5_A5A5, ok0);
      gvram_access_page = 1'b0;
      plane_store(2'd0, 15'h0500, 32'h1234_5678, ok0);
      egc_enable = 1'b1;
      gvram_access_page = 1'b1;
      cpu_access(win_addr(2'd0, 15'h0500), 32'd0, 4'hF, 1'b0, 1'b0, 8'd1, src, ok0);  // pattern load
      gvram_access_page = 1'b0;
      cpu_access(win_addr(2'd0, 15'h0500), 32'hA5A5_A5A5, 4'hF, 1'b1, 1'b0, 8'd1, d0, ok1); // posted put
      egc_enable = 1'b0;
      while (dut.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
      cpu_access(win_addr(2'd0, 15'h0500), 32'd0, 4'hF, 1'b0, 1'b0, 8'd1, got, ok0);
      gvram_access_page = 1'b0;
      if (!ok0 || !ok1)
        fail("E3: the EGC posted write / same-word read did not complete");
      else if (got !== 32'hA5A5_A5A5) begin
        $display("FAIL E3: the EGC posted write was not visible to a same-word read (got %08x)", got);
        fail("E3: the EGC posted write was not visible to a same-word read");
      end else
        $display("PASS E3: EGC 0x3100 posted write -> same-word read returned %08x", got);
    end

    // ---- F. reset asserted MID-TRAFFIC ----
    begin : scen_f
      reg [31:0] rd;
      scan_line_start(15'h0600, 1'b0);
      @(negedge clk);
      cpu_addr = 32'h0002_2000; cpu_be = 4'hF; cpu_write = 1'b0; cpu_valid = 1'b1;
      // Hold until the read is ACCEPTED, so the reset lands with a route owed (a response in
      // flight) and a scanout burst outstanding -- the inconsistent-state window.
      g = 0;
      while (dut.rt_wr == dut.rt_rd && g < 3000) begin @(negedge clk); g = g + 1; end
      if (dut.rt_wr == dut.rt_rd)
        fail("F: no route was owed before the reset, so the window was not exercised");
      reset = 1'b1;
      cpu_valid = 1'b0;
      scan_enable = 1'b0;
      repeat (8) @(posedge clk);
      reset = 1'b0;
      cpu_addr = 32'd0; cpu_be = 4'hF; cpu_write = 1'b0; cpu_valid = 1'b0;
      cpu_line_read = 1'b0; cpu_burstcount = 8'd1;
      wait_idle;
      if (rt_depth != 3'd0 || dut.rt_left != 8'd0)
        fail("F: reset left the response-route queue inconsistent");
      else
        $display("PASS F: reset quiesced the route queue");
      repeat (10) @(posedge clk);
      if (dut.u_gvram_arb.gstate != 4'd0)
        fail("F: reset left the GVRAM backend FSM mid-transaction");
      else
        $display("PASS F: reset left the GVRAM FSM idle");
      cpu_access(32'h0002_2000, 32'hB00B_1234, 4'hF, 1'b1, 1'b0, 8'd1, rd, ok0);
      cpu_access(32'h0002_2000, 32'd0, 4'hF, 1'b0, 1'b0, 8'd1, rd, ok1);
      if (!ok0 || !ok1 || rd !== 32'hB00B_1234)
        fail("F: the first post-reset access did not complete correctly");
      else
        $display("PASS F: first post-reset access completed (%08x)", rd);
    end

    // ---- G. a dirty WCB word behind a scanout line tick ----
    begin : scen_g
      integer lines0;
      lines0 = line_sel_edges;
      cpu_access(win_addr(2'd3, 15'h0700), 32'h0000_7700, 4'b0001, 1'b1, 1'b0, 8'd1, d0, ok0);
      scan_line_start(15'h0800, 1'b0);
      scan_wait_line(ok1);
      scan_line_start(15'h0880, 1'b0);
      scan_wait_line(ok0);
      repeat (20) @(negedge clk);
      if (!ok1 || !ok0)
        fail("G: a scanout line did not complete across a WCB flush");
      else
        $display("PASS G: scanout lines completed across the WCB flush (line swaps=%0d)",
                 line_sel_edges - lines0);
    end

    // ---- H. THE FLUSH vs A CONCURRENT MAPPED READ ----
    // The GVRAM is block RAM now, so it owns NOTHING on port 0: the shared request mux
    // is only the loader and the mapper. The interleaving that used to matter here (a GVRAM
    // write-back flush moving the mux under a bridge launch) cannot arise, so what is left to
    // prove is the stronger statement - a GVRAM store burst and a scanout line tick leave the
    // mapper's own port-0 reads untouched, byte-exact, with no route ever miscredited.
    h_bad = 0; h_first_bad = 0; h_overlap = 0;
    // Seed the addresses the concurrency reads so a misrouted response is caught as wrong data.
    for (k = 0; k < 48; k = k + 1)
      cpu_access(32'h0002_3000 + (k * 4), 32'h3300_0000 + k, 4'hF, 1'b1, 1'b0, 8'd1, d0, ok0);
    // Dirty EVERY write-combining slot (8 words) so the flush has the longest run it can.
    for (k = 0; k < 8; k = k + 1)
      cpu_access(win_addr(2'd0, 15'h2000 + (k * 8)), 32'h0000_1100, 4'b0001, 1'b1, 1'b0, 8'd1, d0, ok0);
    // Arm the flush: a line tick sets flush_pending regardless of the scanout's own fetch.
    scan_line_start(15'h0900, 1'b0);
    for (k = 0; k < 48; k = k + 1) begin
      h_addr_saved = 32'h0002_3000 + (k * 4);
      if (1'b0) h_overlap = h_overlap + 1;
      cpu_access(h_addr_saved, 32'd0, 4'hF, 1'b0, 1'b0, 8'd1, d0, ok0);
      if (!ok0 || d0 !== (32'h3300_0000 + k)) begin
        h_bad = h_bad + 1;
        if (h_first_bad == 0) h_first_bad = k + 1;
        if (ok0) $display("FAIL H: read %08x from %08x, want %08x (misrouted)",
                          d0, h_addr_saved, 32'h3300_0000 + k);
      end
    end
    if (h_bad != 0)
      fail("H: a mapped read presented alongside the GVRAM store burst was misrouted or never answered");
    else
      $display("PASS H: %0d mapped reads completed byte-exact while the GVRAM wrote its own array",
               48);

    // ---- I. a 128-bit GVRAM PLANE line read through the real bridge ----
    // The plain path's line form walks 16 consecutive columns as 16 backend reads (C_VAL /
    // C_WAIT), one at a time. It must complete, and a line whose origin is near the plane end
    // must wrap inside the plane rather than walk off it.
    cpu_access(win_addr(2'd0, 15'h0A00), 32'd0, 4'hF, 1'b0, 1'b1, 8'd4, d0, ok0);
    if (!ok0) fail("I: the GVRAM 128-bit plane line read never completed");
    else      $display("PASS I: GVRAM 128-bit plane line read completed");

    // ---- J. two back-to-back GVRAM stores with `valid` held (the ITF 0x4CE4D/0x4CE51 shape) ----
    // z486 presents the second access while the first is finalizing, so the GVRAM client's
    // C_HOLD must accept an identical consecutive store and the route queue must drain.
    begin : scen_j
      integer jbad;
      jbad = 0;
      @(negedge clk);
      cpu_addr = win_addr(2'd2, 15'h0B00); cpu_din = 32'h1111_2222; cpu_be = 4'hF;
      cpu_write = 1'b1; cpu_line_read = 1'b0; cpu_burstcount = 8'd1; cpu_valid = 1'b1;
      g = 0;
      while (!cpu_ready && g < 3000) begin @(negedge clk); g = g + 1; end
      @(negedge clk);
      cpu_addr = win_addr(2'd2, 15'h0B08); cpu_din = 32'h3333_4444;
      g = 0;
      while (!cpu_ready && g < 3000) begin @(negedge clk); g = g + 1; end
      @(posedge clk); #1 cpu_valid = 1'b0;
      cpu_write = 1'b0; cpu_be = 4'hF;
      repeat (20) @(negedge clk);
      if (rt_depth != 3'd0) jbad = 1;
      if (jbad) fail("J: the back-to-back GVRAM store pair left the route queue non-empty");
      else      $display("PASS J: the back-to-back GVRAM store pair completed and drained");
    end

    // ---- K. a POSTED EGC write with a mapped read presented immediately behind it ----
    // The EGC's posted write releases the CPU at the D1 ACCEPT, so the mapped read below is
    // presented while the GVRAM's write burst is still draining on port 0 -- the window in
    // which the request mux can move under a bridge launch (see the mux-moved counter). The
    // mapped read must still complete with its own data.
    begin : scen_k
      reg [31:0] ksrc, kgot;
      egc_setup;
      cpu_access(32'h0002_4000, 32'h4B4B_4B4B, 4'hF, 1'b1, 1'b0, 8'd1, d0, ok0);
      gvram_access_page = 1'b1;
      plane_store(2'd0, 15'h0600, 32'hA5A5_A5A5, ok0);
      gvram_access_page = 1'b0;
      plane_store(2'd0, 15'h0600, 32'h1234_5678, ok0);
      egc_enable = 1'b1;
      gvram_access_page = 1'b1;
      cpu_access(win_addr(2'd0, 15'h0600), 32'd0, 4'hF, 1'b0, 1'b0, 8'd1, ksrc, ok0);
      gvram_access_page = 1'b0;
      cpu_access(win_addr(2'd0, 15'h0600), 32'hA5A5_A5A5, 4'hF, 1'b1, 1'b0, 8'd1, d0, ok1);
      // ...and NOW, while the GVRAM still owns port 0 draining the put, a mapped read.
      cpu_access(32'h0002_4000, 32'd0, 4'hF, 1'b0, 1'b0, 8'd1, kgot, ok0);
      egc_enable = 1'b0;
      while (dut.u_egc.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
      if (!ok0 || !ok1)
        fail("K: a mapped read behind a posted EGC write never completed");
      else if (kgot !== 32'h4B4B_4B4B) begin
        $display("FAIL K: the mapped read behind the posted EGC write returned %08x", kgot);
        fail("K: the mapped read behind the posted EGC write was misrouted");
      end else
        $display("PASS K: a mapped read behind a posted EGC write completed correctly");
    end

    // ==== VERDICT ====
    $display("NOTE subsystem_stalls: refreshes=%0d font beats=%0d line swaps=%0d mux-moved=%0d errors=%0d",
             refresh_seen, font_beats, line_sel_edges, mux_moved, errors);
    if (errors == 0) begin
      $display("TB_PC9821_SUBSYSTEM_STALLS: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_SUBSYSTEM_STALLS: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_SUBSYSTEM_STALLS: FAIL");
    end
  end

endmodule

`default_nettype wire

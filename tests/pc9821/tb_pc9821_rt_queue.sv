`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The mapped-read response-route queue (rt_beats/rt_left in pc9821_memory_subsystem) under a flood of outstanding reads: with the response side withheld, three reads are queued and their rt_beats slots read back as the ACCEPTED mem_burstcount sequence, the FOURTH read is REFUSED (map back-pressure at three outstanding) and the fifth with it, and when responses flow again each held read is accepted within 2 cycles of the head's RETIRE beat (back-pressure releases at rt_rd's advance, never at a counter expiry). Every owed beat reaches cpu_resp_valid exactly once, with its own tagged data, in accept order, and the queue drains to empty. FAIL-FIRST: on the pre-fix tree the 4th accept lands and the queue's 4th push fires the sim-only overflow guard (and 8 outstanding reads alias rt_wr == rt_rd so the queue reads EMPTY with 8 owed -- the delivered responses are gated off and the CPU deadlocks). The warrant is the responder contract in pc9821_memory_subsystem.sv itself plus r2-buffers F2's confirm-test shape; no magnitude comes from a capture.
//
// TB_PC9821_RT_QUEUE: the mapped-read RESPONSE-ROUTE QUEUE (rt_beats/rt_left in
// pc9821_memory_subsystem) under a flood of outstanding reads. A read accept queues
// its owed beat count and the response beats pop it; with the response side withheld
// the bench drives FIVE reads back-to-back through the map route (the backend's
// early-ack makes overlapping accepts legal) and asserts:
//
//   (1) NO SLOT IS OVERWRITTEN AND NOTHING ALIASES: three reads are queued, the
//       rt_beats slots are read back against the ACCEPTED mem_burstcount sequence,
//       and the FOURTH read is REFUSED (map back-pressure at three outstanding).
//       FAIL-FIRST: on the pre-fix tree the 4th accept lands and the queue's 4th push
//       hits the sim-only overflow $fatal at (rt_wr - rt_rd) == 3 (and 8 outstanding
//       reads alias rt_wr == rt_rd so the queue reads EMPTY with 8 owed -- the
//       responses are then GATED OFF and the CPU deadlocks).
//   (2) SHORTEST-STALL RELEASE: with responses flowing again, the held read is
//       accepted within 2 cycles of the head's RETIRE (the freeing response beat) --
//       back-pressure releases at rt_rd's advance, never at a counter expiry.
//   (3) EXACTLY-ONCE DELIVERY in accept order: every owed beat reaches cpu_resp_valid
//       exactly once, with its own tagged data, and the queue drains to empty.
//
// The warrant is the responder contract in pc9821_memory_subsystem.sv itself
// (accept-respond separation, the owed-beat QUEUE as the record that outlives the
// accept) plus the deadlock's confirm test shape. No magnitude is taken from
// a capture: the counts are the queue's own geometry (4 slots, 3-bit pointers).

module tb_pc9821_rt_queue;
  // pc9821_memory_subsystem's pack-download hold: no boot-ROM download under the OSD Reset
  // level here (tb_pc9821_boot0_load drives that), so the level is low and the hold unread.
  wire hps_apply_reset = 1'b0;
  wire pack_load_hold;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg [3:0] top_bank = 4'd8;
  reg ide_rom_enable = 0;
  reg        ide_ram_gate = 1;
    // 0x1E8E's IDE work-RAM gate: held ON so nothing here sees the gated
    // shape - tb_pc9821_memory_subsystem and tb_pc9821_memory_map pin it.
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
  // The 16-colour select (port 0x6A FF2 num 0): 0 = the digital mode the machine resets to,
  // where 0xE0000-0xE7FFF is open bus (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b0;

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
  // of the old check here; its array is now SDRAM-resident and it reaches
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
  // ==== CHECKS ====
  task automatic wait_write(input integer base);
    begin
      for (wn = 0; wn < 200 && writes == base; wn = wn + 1) @(negedge clk);
    end
  endtask

  // The same bound for a GVRAM plane store, which no longer reaches the backend.
  integer gwn;
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

  // ==== THE RESPONSE-ROUTE QUEUE UNDER A FLOOD ==========
  integer errors_q = 0;
  task automatic failq(input [8*160-1:0] what);
    begin
      errors_q = errors_q + 1;
      errors   = errors + 1;
      $display("FAIL rt_queue: %0s (t=%0t)", what, $time);
    end
  endtask

  // The owed-beat sequence the accepts promised, and the delivery log.
  integer exp_n = 0;
  integer exp_burst [0:15];
  integer got_beats = 0;
  reg [31:0] got_tags [0:31];

  // One mapped read, accepted within `guard` cycles (the early-ack backend: mem_ready
  // is high while the request is presented and drops the cycle after the accept, so a
  // held cpu_valid cannot be accepted twice).
  task automatic issue_read(input [31:0] addr, input [7:0] burst, input integer guard_lim,
                            input integer must_accept, output integer accepted);
    integer guard;
    begin
      @(negedge clk);
      cpu_addr = addr; cpu_burstcount = burst; cpu_be = 4'hF;
      cpu_write = 1'b0; cpu_line_read = 1'b0; cpu_valid = 1'b1;
      mem_ready = 1'b1; mem_resp_valid = 1'b0;
      accepted = 0;
      guard = 0;
      while (!accepted && (guard < guard_lim)) begin
        #1;
        if (cpu_ready) accepted = 1;
        else begin @(negedge clk); guard = guard + 1; end
      end
      if (accepted) begin
        exp_burst[exp_n] = burst;
        exp_n = exp_n + 1;
        @(negedge clk);
      end
      mem_ready = 1'b0; cpu_valid = 1'b0;
      if (must_accept && !accepted)
        failq("a read that must be accepted was refused");
    end
  endtask

  // One presented read that must stay REFUSED for `cycles` cycles (the back-pressure).
  task automatic expect_refused(input [31:0] addr, input [7:0] burst, input integer cycles);
    integer i;
    begin
      @(negedge clk);
      cpu_addr = addr; cpu_burstcount = burst; cpu_be = 4'hF;
      cpu_write = 1'b0; cpu_line_read = 1'b0; cpu_valid = 1'b1;
      mem_ready = 1'b1; mem_resp_valid = 1'b0;
      for (i = 0; i < cycles; i = i + 1) begin
        #1;
        if (cpu_ready)
          failq("a 4th outstanding read was accepted: the queue's next push aliases the head slot");
        @(negedge clk);
      end
    end
  endtask

  // Deliver one response beat (tagged) and log what the CPU was answered.
  task automatic deliver_beat(input [31:0] tag);
    begin
      mem_dout = tag;
      mem_resp_valid = 1'b1;
      #1;
      if (!cpu_resp_valid) failq("an owed response beat was not delivered to the CPU");
      else begin
        got_tags[got_beats] = cpu_dout;
        if (cpu_dout !== tag) failq("the delivered beat carried the wrong data");
      end
      got_beats = got_beats + 1;
      @(negedge clk);
      mem_resp_valid = 1'b0;
    end
  endtask

  // The release-latency watch: `addr` is presented while beats are delivered; the
  // accept must land within 2 cycles of the head's retire beat (the one this task is
  // told is the retiring one). Returns the observed latency.
  integer release_latency;
  task automatic deliver_and_watch_release(input [31:0] tag, input [31:0] addr,
                                           input [7:0] burst, input is_retire);
    integer i, accepted, seen;
    begin
      @(negedge clk);
      // the held read is presented alongside the beat
      cpu_addr = addr; cpu_burstcount = burst; cpu_be = 4'hF;
      cpu_write = 1'b0; cpu_line_read = 1'b0; cpu_valid = 1'b1;
      mem_ready = 1'b1;
      mem_dout = tag; mem_resp_valid = 1'b1;
      #1;
      if (cpu_resp_valid) begin
        got_tags[got_beats] = cpu_dout;
        if (cpu_dout !== tag) failq("the delivered beat carried the wrong data");
        got_beats = got_beats + 1;
      end else failq("an owed response beat was not delivered to the CPU");
      accepted = cpu_ready ? 1 : 0;
      if (accepted) begin
        exp_burst[exp_n] = burst; exp_n = exp_n + 1;
        release_latency = 0;
      end
      @(negedge clk);
      mem_resp_valid = 1'b0;
      seen = 1;
      while (!accepted && (seen <= 2)) begin
        #1;
        accepted = cpu_ready ? 1 : 0;
        if (accepted) begin
          exp_burst[exp_n] = burst; exp_n = exp_n + 1;
          release_latency = seen;
        end
        if (!accepted) begin @(negedge clk); seen = seen + 1; end
      end
      if (!accepted) begin
        failq("the back-pressure did not release within 2 cycles of the freeing response beat");
        release_latency = 99;
      end
      @(negedge clk);
      mem_ready = 1'b0; cpu_valid = 1'b0;
    end
  endtask

  integer acc;
  integer i;

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;

    // Bring the subsystem up the way tb_pc9821_memory_subsystem does: one pack word
    // so rom_ready releases the CPU and the map route owns the backend.
    ioctl_download = 1;
    send_word(27'd0, 16'hBEEF);
    repeat (2) @(posedge clk);
    ioctl_download = 0;
    repeat (3) @(posedge clk);
    if (!rom_ready || !cpu_run || load_error) begin
      $display("FAIL rt_queue: pack load did not release the CPU (ready=%b run=%b err=%b)",
               rom_ready, cpu_run, load_error);
      errors = errors + 1;
    end

    // ---- (1) THE FLOOD: five reads back-to-back, the response side withheld ----
    // bursts 2,3,1,2,1 - non-trivial owed counts so a slot alias is visible in the
    // read-back below. Pre-fix, the FOURTH accept's push fires the overflow $fatal;
    // eight outstanding reads would alias the queue EMPTY and deadlock the CPU.
    issue_read(32'h0002_0000, 8'd2, 20, 1, acc);
    issue_read(32'h0002_0010, 8'd3, 20, 1, acc);
    issue_read(32'h0002_0020, 8'd1, 20, 1, acc);
    if (exp_n != 3) failq("flood phase accepted the wrong number of reads");
    // No slot overwritten: the slots read back as the accepted mem_burstcount sequence.
    if ((dut.rt_beats[0] !== 8'd2) || (dut.rt_beats[1] !== 8'd3) || (dut.rt_beats[2] !== 8'd1))
      failq("rt_beats does not hold the accepted mem_burstcount sequence");
    if ((dut.rt_wr - dut.rt_rd) !== 3'd3)
      failq("the queue does not hold exactly 3 outstanding after 3 accepts");
    // The fourth and fifth reads: REFUSED while three are outstanding.
    expect_refused(32'h0002_0030, 8'd2, 10);
    expect_refused(32'h0002_0040, 8'd1, 5);

    // ---- (2)+(3): release at the retire, exactly-once delivery in accept order ----
    // The head is R0 (2 beats). Its RETIRE is its second beat; the held read (R3,
    // burst 2) must be accepted within 2 cycles of it.
    deliver_beat(32'hD000_0000);                    // R0 beat 0 (rt_left 2 -> 1)
    deliver_and_watch_release(32'hD000_0001, 32'h0002_0030, 8'd2, 1);  // R0 beat 1 = retire
    if (release_latency > 2)
      failq("the held 4th read was not re-accepted within 2 cycles of the freeing beat");
    // Three outstanding again (R1, R2, R3): the fifth read is refused...
    expect_refused(32'h0002_0040, 8'd1, 5);
    // ...until R1 (3 beats) retires on its third beat.
    deliver_beat(32'hD100_0000);
    deliver_beat(32'hD100_0001);
    deliver_and_watch_release(32'hD100_0002, 32'h0002_0040, 8'd1, 1);  // R1 beat 2 = retire
    if (release_latency > 2)
      failq("the held 5th read was not re-accepted within 2 cycles of the freeing beat");

    // Everything still owed, in accept order: R2(1), R3(2), R4(1).
    deliver_beat(32'hD200_0000);                    // R2 retire
    deliver_beat(32'hD300_0000);
    deliver_beat(32'hD300_0001);                    // R3 retire
    deliver_beat(32'hD400_0000);                    // R4 retire

    // ---- (3) exactly once, in accept order, and the queue drains to empty ----
    if (got_beats != 9)
      failq("the delivered beat count is not the owed count (5 reads, 9 beats)");
    if ((got_tags[0] !== 32'hD000_0000) || (got_tags[1] !== 32'hD000_0001) ||
        (got_tags[2] !== 32'hD100_0000) || (got_tags[3] !== 32'hD100_0001) ||
        (got_tags[4] !== 32'hD100_0002) || (got_tags[5] !== 32'hD200_0000) ||
        (got_tags[6] !== 32'hD300_0000) || (got_tags[7] !== 32'hD300_0001) ||
        (got_tags[8] !== 32'hD400_0000))
      failq("the delivered beats are not the accepted reads' beats in accept order");
    repeat (4) @(negedge clk);
    if ((dut.rt_wr !== dut.rt_rd) || (dut.rt_left !== 8'd0))
      failq("the queue did not drain to empty after every owed beat was delivered");
    if (dut.map_accepted !== 1'b0)
      failq("map_accepted is still gating a response with an empty queue");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_RT_QUEUE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_RT_QUEUE: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog, as every bench in this tree carries.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_RT_QUEUE: TIMEOUT");
  end

endmodule

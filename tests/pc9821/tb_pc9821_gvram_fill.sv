`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GVRAM_FILL:
// A 32 KiB fill of the GVRAM plane window completes against a backend that answers the way src/memory/sdram.v documents - a one-cycle accept pulse, several cycles to the first read beat, one response per beat, and a controller that serves one request at a time - and the read-back returns the fill value, so the ITF's stage-0x1B graphics VRAM test is not wedging in the route; and a cache-line read to normal RAM completes as FOUR WORD BEATS with no line producer anywhere, the beat-uniform fill (tb_pc9821_fill_beat_uniform diffs every beat against the bytes its route holds and pins the streaming cadence) - the old 128-bit line path is deleted end to end now, not merely dead.

// ==== DUT ====
// pc9821_memory_subsystem, with its backend answered by sdram_backend_model
// instead of the immediate stub every other tier uses.
//
// Two model instances sit on the backend and the bench selects between them:
//   - the IMMEDIATE one (ACCEPT_TO_RESP=0, WRITE_BUSY=0) is the stub the
//     integrated tiers drive, kept so the same stimulus can be run both ways;
//   - the REALISTIC one (ACCEPT_TO_RESP=5, WRITE_BUSY=3) is what sdram.v
//     documents for the authentic clk_sys.
// Only the selected instance drives mem_ready/mem_resp_valid.
//
// The line response used to be the switch that mattered: z486_mister.sv tied
// ext_mem0_line_resp_valid to 1'b0 and ext_mem0_line_dout to 128'd0. That port is gone from the
// design now -- cache fills complete as burstcount==4 word responses -- so the route has no
// line-response producer at all and the section-4 check below is the measurement of that.

module tb_pc9821_gvram_fill;
  // pc9821_memory_subsystem's pack-download hold: no boot-ROM download under the OSD Reset
  // level here (tb_pc9821_boot0_load drives that), so the level is low and the hold unread.
  wire hps_apply_reset = 1'b0;
  wire pack_load_hold;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  reg [3:0]  top_bank = 4'd8;
  reg        ide_rom_enable = 0;
  reg        ide_ram_gate = 1;
    // 0x1E8E's IDE work-RAM gate: held ON so nothing here sees the gated
    // shape - tb_pc9821_memory_subsystem and tb_pc9821_memory_map pin it.
  reg        bios_ram_gate = 0;
  reg [7:0]  win0_sel = 8'h08;
  wire       win0_sel_moved = (win0_sel != 8'h08);   // pc9821_iobus's registered compare
  // 0x043B bit 2, the 15-16 MiB system-space window. The machine's reset value is ON,
  // so these benches drive the same state the card comes up in.
  reg  sys16m_en = 1'b1;
  reg [31:0] pack_base = 32'h01F8_0000;
  reg [31:0] guest_ram_bytes = 32'h0200_0000;
  reg        gvram_access_page = 0;

  reg        grcg_we = 0;
  reg [7:0]  grcg_addr = 0;
  reg [7:0]  grcg_din = 0;
  wire       grcg_expand;   // the GRCG's CG-mode bit 7, fed back from the subsystem
  wire       grcg_expand_nx;   // mode[7]'s next state (opt-video VID-1); unused here


  // EGC held off: this bench is about the plain CPU path into a plane.
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

  wire [10:0] font_addr;
  wire [15:0] font_data;
  wire        font_we;

  // Scanout parked: the real core scans while this runs, but the scanout is
  // paced by design and leaving it off makes the fill's own behaviour the only
  // variable. A scanout-inclusive run is the natural follow-up.
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
  reg  [7:0]  tram [0:16383];

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
  wire        fmem_valid, fmem_write;
  wire [3:0]  fmem_be;
  wire [7:0]  fmem_burstcount;
  reg         fmem_ready = 1, fmem_resp_valid = 0;
  reg  [31:0] fmem_dout = 32'd0;

  // ---- the backend: the DUT sees one of two models, chosen by slow_mode ----
  wire [31:0] mem_addr, mem_din;
  wire [3:0]  mem_be;
  wire [7:0]  mem_burstcount;
  wire        mem_line_read, mem_valid, mem_write;

  reg slow_mode = 1;      // 1: realistic sdram timing; 0: the immediate stub
  reg line_producer = 0;  // 1: model supplies the line response; 0: as the FPGA

  wire        fast_ready, fast_resp_valid, fast_line_resp_valid;
  wire [31:0] fast_dout;
  wire [127:0] fast_line_dout;
  wire        slow_ready, slow_resp_valid, slow_line_resp_valid;
  wire [31:0] slow_dout;
  wire [127:0] slow_line_dout;

  wire mem_ready          = slow_mode ? slow_ready : fast_ready;
  wire mem_resp_valid     = slow_mode ? slow_resp_valid : fast_resp_valid;
  wire [31:0] mem_dout    = slow_mode ? slow_dout : fast_dout;
  // The line form is the point: when line_producer is 0 the bench reproduces
  // what z486_mister.sv builds -- no producer for this port at all.
  wire mem_line_resp_valid = line_producer &&
                             (slow_mode ? slow_line_resp_valid : fast_line_resp_valid);
  wire [127:0] mem_line_dout = slow_mode ? slow_line_dout : fast_line_dout;
  // The GVRAM scanout's SDRAM requester: the wildcard instantiation needs every port
  // named. This bench never starts the scanout, so it accepts and never answers.
  wire [31:0] mem3_addr, mem3_din;
  wire  [3:0] mem3_be;
  wire  [7:0] mem3_burstcount;
  wire        mem3_valid, mem3_write;
  reg  [31:0] mem3_dout = 32'h0;
  reg         mem3_ready = 1, mem3_resp_valid = 0;

  sdram_backend_model #(
      .ACCEPT_TO_RESP(0), .WRITE_BUSY(0), .LINE_RESP(1)
  ) be_fast (
      .clk(clk), .reset(reset),
      .valid(mem_valid), .ready(fast_ready), .write(mem_write),
      .addr(mem_addr), .din(mem_din), .din_hi(mem_din_hi), .be(mem_be), .burstcount(mem_burstcount), .gath(mem_gath), .gath_extra(mem_gath_extra),
      .dout(fast_dout), .resp_valid(fast_resp_valid),
      .line_dout(fast_line_dout), .line_resp_valid(fast_line_resp_valid),
      .busy(), .accepts(), .beats()
  );

  sdram_backend_model #(
      .ACCEPT_TO_RESP(5), .WRITE_BUSY(3), .LINE_RESP(1)
  ) be_slow (
      .clk(clk), .reset(reset),
      .valid(mem_valid), .ready(slow_ready), .write(mem_write),
      .addr(mem_addr), .din(mem_din), .din_hi(mem_din_hi), .be(mem_be), .burstcount(mem_burstcount), .gath(mem_gath), .gath_extra(mem_gath_extra),
      .dout(slow_dout), .resp_valid(slow_resp_valid),
      .line_dout(slow_line_dout), .line_resp_valid(slow_line_resp_valid),
      .busy(), .accepts(slow_accepts), .beats(slow_beats)
  );
  wire [31:0] slow_accepts, slow_beats;

  // ==== CHECKS ====
  //
  // SEEN TO FAIL, which is this tree's standard for trusting a test. Planting
  // the fixed defect -- making `backend_owner` in
  // pc9821_memory_subsystem.sv a ONE-CYCLE record again -- produces:
  //
  //   PASS fill: 8192 stores, 32769 backend writes ... finished at tb_cycle=229397
  //   FAIL read-back: dword 0 returned deadbeef (ok=0)
  //   PASS stub-fill: 256 stores completed against the immediate stub too
  //   FAIL line-with-producer: a cache-line read did not complete even WITH a
  //        line response producer -- the stimulus is wrong
  //
  // and the plant was reverted before this file was committed (the RTL is
  // untouched). Two things are worth reading out of that transcript:
  //
  //   * the FILL still passes with the defect planted, and the READ-BACK does
  //     not, which is the mechanism rather than a coincidence: a GVRAM write is
  //     completed by the accept alone, so the expired ownership record never
  //     enters its path, while a read waits in B_RESP for a `mem_resp_valid`
  //     that the expired record has gated off forever.
  //   * check 4's "the stimulus is wrong" message fires in that world, so check
  //     4 doubles as a tripwire for the very defect the fill is indifferent to.

  // 1 fill       : 8192 stores (the ITF's own cx=0x2000, 32 KiB) complete against
  //                a backend with a one-cycle accept pulse, 5 cycles to the
  //                first read beat, 3 busy cycles per write and one response
  //                per beat -- and at least 2 * 8192 backend writes were accepted.
  // 2 read-back  : dwords read back through the same route return the fill value.
  // 3 stub-fill  : the same stores pass against the immediate stub, so the bench
  //                is measuring the route and not its own stimulus.
  // 4 line-read  : a cache-line read (burstcount 4, z486 bus_unit.sv:301 `assign line_read`) to
  //                normal RAM completes as FOUR WORD BEATS - the beat-uniform
  //                fill every route answers with now (tb_pc9821_fill_beat_uniform
  //                diffs the form byte for byte against the 128-bit line it
  //                replaced), where the line form itself is gone from the
  //                boundary entirely (a dead path, deleted).


  wire [1:0] ems_state;
  wire top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)

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

  integer errors = 0;
  integer tb_cycle = 0;
  always @(posedge clk) tb_cycle = tb_cycle + 1;

  // gvram_base is pack_base + 1 MiB, so the plane-0 window at 0xA8000 lands on
  // 0x0208_0000 -- the same arithmetic tb_pc9821_memory_subsystem.sv checks.
  localparam [31:0] GV_BASE  = 32'h0208_0000;
  localparam [31:0] FILL_BASE = 32'h000A_8000;   // ES=0xA800, di=0 as the ITF sets them
  localparam integer FILL_DWORDS = 8192;         // the ITF's cx=0x2000
  // Each 32-bit store's four enabled plane bytes are four CONSECUTIVE plane
  // words, and the write-combining buffer now pairs adjacent dirty words into
  // ONE two-word burst, so a store owes between 2 and 4 backend
  // writes -- not one per byte lane as it did before the pair. The bound below
  // is the paired floor; the read-back phase is what proves the bytes. Bounded
  // well above the realistic worst case so a wedge is a timeout rather than a
  // slow pass.
  localparam integer STORE_BUDGET = 2000;

  // A hard watchdog, so a hang anywhere in the stimulus is a failure not a stall.
  initial begin
    #20_000_000;
    $display("FAIL watchdog: the fill did not finish (tb_cycle=%0d)", tb_cycle);
    $fatal(1, "TB_PC9821_GVRAM_FILL: FAIL watchdog");
  end

  task do_reset;
    begin
      reset = 1;
      repeat (8) @(posedge clk);
      reset = 0;
      repeat (4) @(posedge clk);
    end
  endtask

  // Load a minimal pack so rom_ready and cpu_run come up, exactly as the other
  // subsystem bench does.
  task load_rom;
    begin
      ioctl_download = 1;
      ioctl_addr = 27'd0;
      ioctl_dout = 16'hBEEF;
      ioctl_wr = 1;
      @(posedge clk);
      ioctl_wr = 0;
      repeat (2) @(posedge clk);
      ioctl_download = 0;
      repeat (4) @(posedge clk);
      if (!rom_ready || !cpu_run) begin
        $display("FAIL rom: ready=%b run=%b load_error=%b", rom_ready, cpu_run, load_error);
        errors = errors + 1;
      end
    end
  endtask

  // One CPU store, held until the route accepts. `c_ok` is the accept itself: a store is
  // COMPLETE on `ready`. z486's memory.sv completes an external write there (its store queue
  // drains on mem_ready) and consumes `resp_valid` only for a READ (`direct_rd_resp_now` is
  // gated `!ext_write_r`), so this route has never owed a store a response strobe -- asserting
  // one was the plain client's extra cycle, not the machine's contract. `c_ok` comes
  // back false if the route never accepts inside the budget, which is how a wedge is reported.
  // The request is released the cycle the route accepts, as z486 releases it.
  // No task output arguments: Verilator rejects them ("Too many arguments in
  // call"), so results land in module variables, as the other benches do.
  task automatic cpu_store(input [31:0] a, input [31:0] d, input [3:0] be);
    integer guard;
    begin
      cpu_addr  = a;
      cpu_din   = d;
      cpu_be    = be;
      cpu_write = 1;
      cpu_line_read = 0;
      cpu_burstcount = 8'd1;
      cpu_valid = 1;
      c_ok = 1'b0;
      guard = 0;
      while (!cpu_ready && guard < STORE_BUDGET) begin
        @(negedge clk);
        guard = guard + 1;
      end
      c_ok = cpu_ready;
      // A store is complete ON THE ACCEPT and z486 clears the request on `ready`, so release
      // it in the accept cycle and step past that cycle -- holding it one cycle longer would
      // present a second, identical access (the earlier C_RESP2/C_HOLD tail absorbed it).
      cpu_valid = 0;
      cpu_write = 0;
      @(negedge clk);
    end
  endtask

  // One CPU load, same discipline. The data returned by the route lands in c_rd.
  task automatic cpu_load(input [31:0] a);
    integer guard;
    begin
      cpu_addr  = a;
      cpu_din   = 32'd0;
      cpu_be    = 4'hF;
      cpu_write = 0;
      cpu_line_read = 0;
      cpu_burstcount = 8'd1;
      cpu_valid = 1;
      c_ok = 1'b0;
      c_rd = 32'hDEAD_BEEF;
      guard = 0;
      while (!cpu_ready && guard < STORE_BUDGET) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (cpu_ready) begin
        @(negedge clk);
        cpu_valid = 0;
        guard = 0;
        while (!cpu_resp_valid && guard < STORE_BUDGET) begin
          @(negedge clk);
          guard = guard + 1;
        end
        c_rd = cpu_dout;
        c_ok = cpu_resp_valid;
        @(negedge clk);
      end
      cpu_valid = 0;
    end
  endtask

  // A cache-line read: burstcount 4 is what z486's cache channels use, and
  // bus_unit.sv:301 turns exactly that shape into `line_read`. The route answers it
  // as FOUR WORD BEATS now (the beat-uniform fill; tb_pc9821_fill_beat_uniform).
  // `c_q_ok` says whether the route completed all four beats.
  task automatic cpu_line_load(input [31:0] a);
    integer guard, bn;
    begin
      cpu_addr  = a;
      cpu_din   = 32'd0;
      cpu_be    = 4'hF;
      cpu_write = 0;
      cpu_line_read  = 1;
      cpu_burstcount = 8'd4;
      cpu_valid = 1;
      c_q_ok = 1'b0;
      guard = 0;
      while (!cpu_ready && guard < STORE_BUDGET) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (cpu_ready) begin
        @(negedge clk);
        cpu_valid = 0;
        c_q_ok = 1'b1;
        for (bn = 0; bn < 4; bn = bn + 1) begin
          guard = 0;
          while (!cpu_resp_valid && guard < STORE_BUDGET) begin
            @(negedge clk);
            guard = guard + 1;
          end
          if (!cpu_resp_valid) begin
            c_q_ok = 1'b0;
            bn = 4;
          end else begin
            @(negedge clk);
          end
        end
      end
      cpu_valid = 0;
      cpu_line_read = 0;
    end
  endtask

  integer i, nfail;
  integer ok_count;
  reg c_ok;                 // result of the last cpu_store / cpu_load
  reg [31:0] c_rd;          // data returned by the last cpu_load
  reg c_q_ok;               // whether a cache-line read ever completed
  integer fill_timeout_at;

  initial begin
    nfail = 0;

    // ---- 1. THE FILL, against the realistic backend ----
    do_reset;
    load_rom;

    slow_mode = 1;
    line_producer = 0;      // the FPGA's world: no line response producer
    repeat (4) @(posedge clk);

    ok_count = 0;
    fill_timeout_at = -1;
    for (i = 0; i < FILL_DWORDS; i = i + 1) begin
      cpu_store(FILL_BASE + (i * 4), 32'hFFFF_FFFF, 4'hF);
      if (c_ok) ok_count = ok_count + 1;
      else if (fill_timeout_at < 0) begin
        fill_timeout_at = i;
        i = FILL_DWORDS;      // stop walking once it wedges
      end
    end

    if (fill_timeout_at >= 0) begin
      $display("FAIL fill-wedge: store %0d of %0d never completed against realistic timing (tb_cycle=%0d, accepts=%0d)",
               fill_timeout_at, FILL_DWORDS, tb_cycle, slow_accepts);
      errors = errors + 1;
      nfail = nfail + 1;
    end else if (ok_count != FILL_DWORDS) begin
      $display("FAIL fill-incomplete: %0d of %0d stores completed", ok_count, FILL_DWORDS);
      errors = errors + 1;
      nfail = nfail + 1;
    end else begin
      // The GVRAM is block RAM now: the fill is served ENTIRELY by the array and owes
      // the backend nothing, so the wedge tripwire is the STORE COUNT alone - every one of the
      // ITF's 8192 stores must complete - not a backend-write count. The count is still printed
      // so a future regression that puts the GVRAM back on the backend shows up here.
      $display("PASS fill: %0d stores served from the M10K array, %0d backend writes seen (the GVRAM owes none), %0d backend beats, finished at tb_cycle=%0d",
               FILL_DWORDS, slow_accepts, slow_beats, tb_cycle);
    end

    // ---- 2. THE READ-BACK: does the fill value come back? ----
    if (nfail == 0) begin
      ok_count = 0;
      for (i = 0; i < 16; i = i + 1) begin
        cpu_load(FILL_BASE + (i * 4));
        if (c_ok && c_rd === 32'hFFFF_FFFF) ok_count = ok_count + 1;
        else if (ok_count == i) begin
          $display("FAIL read-back: dword %0d returned %08x (ok=%b)", i, c_rd, c_ok);
          errors = errors + 1;
          nfail = nfail + 1;
        end
      end
      if (ok_count == 16)
        $display("PASS read-back: all 16 sampled dwords returned the fill value");
    end

    // ---- 3. THE SAME FILL against the immediate stub ----
    // The stub must also pass; if it did not, this bench would be measuring its
    // own stimulus rather than the route.
    do_reset;
    load_rom;
    slow_mode = 0;
    repeat (4) @(posedge clk);
    ok_count = 0;
    for (i = 0; i < 256; i = i + 1) begin
      cpu_store(FILL_BASE + (i * 4), 32'hFFFF_FFFF, 4'hF);
      if (c_ok) ok_count = ok_count + 1;
    end
    if (ok_count != 256) begin
      $display("FAIL stub-fill: only %0d of 256 stores completed against the immediate stub", ok_count);
      errors = errors + 1;
      nfail = nfail + 1;
    end else
      $display("PASS stub-fill: 256 stores completed against the immediate stub too");

    // ---- 4. A CACHE-LINE READ to normal RAM ----
    // Address 0x0002_0000 is ordinary guest RAM, so the MAPPER owns it. The route
    // answers a cache-line read as FOUR WORD BEATS (the beat-uniform fill: the
    // 128-bit line form has no producer in the built design and is gone from the
    // boundary entirely now - tb_pc9821_fill_beat_uniform diffs the two forms
    // byte for byte), so the read COMPLETES.
    slow_mode = 1;
    line_producer = 0;
    repeat (4) @(posedge clk);
    cpu_line_load(32'h0002_0000);
    if (!c_q_ok) begin
      $display("FAIL line-beats: a cache-line read to normal RAM did not complete as four word beats");
      errors = errors + 1;
      nfail = nfail + 1;
    end else
      $display("PASS line-beats: the map route completes a cache-line read to normal RAM as four word beats - the beat-uniform fill every route answers with now (tb_pc9821_fill_beat_uniform); the old dead line path is deleted now, not merely dead.");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GVRAM_FILL: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GVRAM_FILL: FAIL (%0d errors)", errors);
  end

endmodule

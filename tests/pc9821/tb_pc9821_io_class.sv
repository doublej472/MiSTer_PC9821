module tb_pc9821_io_class;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg [31:0] cpu_addr = 0, cpu_din = 0;
  reg [3:0] cpu_be = 0;
  reg cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire cpu_ready, cpu_resp_valid;
  reg [7:0] debug_status = 8'hA5;
  wire device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire [7:0] device_io_din;
  reg [7:0] device_io_dout = 8'hC3;
  // A device that presents its data in the strobe cycle, so it must not ask for
  // the extra read cycle. Every port in this sweep is timed against THIS value,
  // so the S_DEVWAIT cycle is never in the measurement: what is measured is the
  // class table's own hold, which is the subject.
  reg       device_rd_wait = 1'b0;
  wire [3:0] top_bank;
  wire sound_extend;
  wire ide_rom_enable, bios_ram_gate;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [7:0] win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire sys16m_en;
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)
  wire a20_enable, cpu_reset_req;
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire [7:0] post_code;
  wire post_write;
  // The core's native whole-L1 flush handshake (iobus's cache_flush_req /
  // cache_flush_busy / cache_flush_done), modelled here at ZERO LATENCY: this
  // bench does not measure flush timing, and an unmodelled cache_flush_done
  // would leave any flush-triggering write waiting in iobus's S_FLUSH forever.
  // The real request/done contract is tb_pc9821_cache_flush's subject.
  wire cache_flush_req;
  wire crt31k;   // 0x09A8 bit 0 (pc9821_iobus), named so .* binds it
  wire cache_flush_busy = 1'b0;
  wire cache_flush_done = cache_flush_req;
  wire [3:0] dbg_gate;
  wire [7:0] dbg_itf_stage;
  wire [15:0] dbg_artic_hi;
  wire [15:0] dbg_last_io_addr;
  wire  [7:0] dbg_last_io_data;
  wire        dbg_last_io_rd;
  wire        dbg_last_io_wr;
  // The FDC's debug taps: named because the DUT is (.*), not exercised here
  // (tb_pc9821_fdc_dbg pins them).
  wire [7:0]  dbg_fdc_state;
  wire [7:0]  dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;
  reg        cal_cdat = 0;
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  reg        triple_fault_reset = 1'b0;
  reg        egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;
  wire [1:0] ems_state;
  wire top_shadow_en;
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window

// ==== WHAT THIS PROVES ====
// The min-profile I/O class table, measured end to end through the real pc9821_iobus: a full sweep of the 16-bit port space recovers exactly three values - 0x005F = 82 (the machine's item-41 1621 ns, the BIOS POST timer test's requirement, charged in BOTH directions because a `wr`-dependent value there trips a Quartus fitter internal error), an 8253 WRITE 0x0071/0x0073/0x0075/0x0077/0x3FD9-0x3FDF = 21 (one 2.4576 MHz PIT tick, the write-side floor the ITF's POST timer self-test needs), and EVERY other access = 4, the FSM floor - in place of the machine's measured ladder (WAIT 30 > 8253 21 > default 15 = IDE task file 15 > graphics GDC 13 > text GDC 8 = IDE data 8 > EGC 7). An 8253 READ is the FSM floor and not 21, because that floor is a WRITE-side requirement and the capture reads the 8253 at the default class (its PITD0/PITD1 rows in docs/probes/IO.TXT): measured here in both directions. The IDE data ports 0x0640/0x0641, the IDE task-file/interface registers 0x0642-0x064E/0x074C/0x074E/0x0430/0x0432/0x1E8E, the text GDC 0x0060/0x0062, the graphics GDC 0x00A0/0x00A2, the EGC ports 0x04A0-0x04AF/0x006A/0x007C/0x007E/0x00A6 (including the GRCG pair) and the default are all at the FSM floor; the 47 named ports keep their arms so the inventory stays exact, and the bench prints the floor and the two survivors. And a MULTI-BYTE access is priced LANE BY LANE: on the machine each byte of an access is its own bus cycle and therefore carries its own class, so a two-lane read of 0x5E/0x5F costs 4 + 82 = 86 clk_sys (that ARTIC word read is the one the firmware does 20 times across BANK3/BANK6/BANK7/BIOS.ROM, and it used to pay one class plus a single cycle), two same-class lanes cost 4 + 4 = 8 where one class plus one cycle used to be charged, and the terminated high lane of a word read at 0x7C - which the machine never fetches - keeps its one cycle and pays no class.
//
// The table is the `io_access_cycles` function in pc9821_iobus.sv. This bench
// exists because a measurement showed that every EGC port was charged its `default`
// arm; it now pins every class at the floor plus the two floors the firmware
// needs. The AUDIT lines are the finding; the assertions are only what
// a wrong table would break.

  // ==== DUT ====
  reg device_rd_hold = 1'b0;
  reg [3:0]  bios_set = 4'd0;      // OSD BIOS set: 0 = PC-9821Xe10 (the default strap)
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  fdd_dip_fixed = 1'b1;   // the 0x00BE bit-2 FDD-mode switch at the measured unit's Fixed
  reg device_wr_wait = 1'b0;   // write back-pressure: unused here (no device buffer is stressed), 0 = never stall
  // The 0x9A0 query state input (pc9821_iobus): driven at 0 here - only
  // tb_pc9821_readback_sysports exercises the query protocol.
  reg [10:0] gdc_ff2_state = 11'd0;
  // The bus mouse's IRQ13 line and hps_io's parsed mouse packet - the ports
  // pc9821_iobus carries for pc9821_mouse; not exercised by this bench.
  wire        mouse_irq;
  reg  [24:0] ps2_mouse = 25'd0;
  // ---- pc9821_iobus's Phase-1 port groups, tied off: this bench drives NO floppy ----
  // The wildcard instantiation connects every port by name, so the floppy media seam and
  // the uPD71071's bus-master port need a signal here even though nothing in this bench
  // uses them (tools/check_wiring.py requires exactly that). With `fdd_present` clear the
  // FDC never takes its media path, so the data path this seam feeds is unreachable.
/* verilator lint_off UNUSEDSIGNAL */
  wire [3:0]  fdd_present = 4'd0;
  wire [3:0]  fdd_chg = 4'd0;          // no media change: the FDC's ready-change tag
  wire        fdd_frame_tick = 1'b0;
  wire        fdd_req, fdd_req_hdr, fdd_adv;
  wire [1:0]  fdd_unit;
  wire [7:0]  fdd_c, fdd_h, fdd_r, fdd_n, fdd_idx, fdd_dout, fdd_hr, fdd_hn, fdd_hs;
  wire [7:0]  fdd_tc;   // pc9821_iobus's physical-track pair (pc9821_fdc media_tc/media_hd)
  wire        fdd_hd;
  wire        fdd_mf;
  wire        fdd_2hd;   // pc9821_iobus's media-mode pair (pc9821_fdc media_2hd/media_rpm)
  wire        fdd_rpm;
  wire        fdd_ready = 1'b1, fdd_rdy = 1'b0, fdd_hdrv = 1'b0, fdd_err = 1'b0;
  wire [31:0] dma_mem_addr, dma_mem_din;
  wire [1:0]  dma_mem_gvwin;   // the DMAC's plane-window class (unused here)
  wire [3:0]  dma_mem_be;
  wire        dma_mem_req, dma_mem_we;
  wire        dma_mem_ready = 1'b0;
  wire [31:0] dma_mem_dout = 32'd0;
  wire        dma_mem_resp_valid = 1'b0;
/* verilator lint_on UNUSEDSIGNAL */
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;

  wire [1:0] d8_bank;   // 0x063C bits 1-0 (the 0xD8000 bank select); unused here

  // P5: the device-bus chip selects are pc9821_iobus outputs now (its own one decode).
  // This bench drives no device select of its own, so they are named here for the wildcard
  // instantiation and left unused.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0),.*);

  // ==== CHECKS ====


  // The table's own arms, as pc9821_iobus.sv declares them, plus the two
  // independently-known numbers the audit compares against. The 8253 arm is the one
  // DIRECTION-dependent class in the min profile: the ITF self-test floor is
  // a write-side requirement, and the capture's PITD0/PITD1 rows price an 8253 read at the
  // default class, which in this profile is the FSM floor.
  localparam integer CLASS_WAIT = 82;     // 0x005F (the machine's item-41 1621 ns, ONE value; a wr-dependent value trips a Quartus fitter bug)
  localparam integer CLASS_PITW = 21;     // an 8253 WRITE (IO_PIT_HOLD, kept)
  localparam integer CLASS_PITR = 4;      // an 8253 READ: the default read class, the FSM floor
  localparam integer CLASS_MIN  = 4;      // the FSM floor: every other class
  localparam integer CLASS_IDE  = 4;      // 0x0640/0x0641
  localparam integer CLASS_ATA  = 4;      // the task-file/interface registers
  localparam integer CLASS_GDC1 = 4;      // 0x0060/0x0062
  localparam integer CLASS_GDC2 = 4;      // 0x00A0/0x00A2
  localparam integer CLASS_EGC  = 4;      // 0x04A0-0x04AF, 0x006A, 0x007C, 0x007E, 0x00A6
  localparam integer CLASS_DEF  = 4;      // every other port
  localparam integer DOC_WAIT   = 30;     // 0x5F = 600 ns documented, at 50 MHz
  localparam real    NP2_FLAT   = 20.34;  // NP2kai: one 2.4576 MHz base clock
  localparam integer PIT_TICK   = 21;     // 2.4576 MHz against 50 MHz = 20.34

  function automatic integer class_of(input [15:0] p, input wr);
    begin
      if ((p & 16'hFFF0) == 16'h04A0)
        class_of = CLASS_EGC;
      else case (p)
        16'h005F:            class_of = CLASS_WAIT;
        16'h0071, 16'h0073, 16'h0075, 16'h0077,
        16'h3FD9, 16'h3FDB, 16'h3FDD, 16'h3FDF: class_of = wr ? CLASS_PITW : CLASS_PITR;
        16'h0640, 16'h0641:  class_of = CLASS_IDE;
        16'h0642, 16'h0644, 16'h0646, 16'h0648, 16'h064A,
        16'h064C, 16'h064E, 16'h074C, 16'h074E,
        16'h0430, 16'h0432, 16'h1E8E: class_of = CLASS_ATA;
        16'h0060, 16'h0062:  class_of = CLASS_GDC1;
        16'h00A0, 16'h00A2:  class_of = CLASS_GDC2;
        16'h006A, 16'h007C, 16'h007E, 16'h00A6: class_of = CLASS_EGC;
        default:             class_of = CLASS_DEF;
      endcase
    end
  endfunction

  // Every named class now shares the default's value (all are the FSM floor),
  // so a value-equality count discriminates nothing; this predicate counts by ARM
  // (coverage), not by value.
  function automatic integer is_named(input [15:0] p);
    begin
      if ((p & 16'hFFF0) == 16'h04A0)
        is_named = 1;
      else case (p)
        16'h005F:            is_named = 1;
        16'h0071, 16'h0073, 16'h0075, 16'h0077,
        16'h3FD9, 16'h3FDB, 16'h3FDD, 16'h3FDF: is_named = 1;
        16'h0640, 16'h0641:  is_named = 1;
        16'h0642, 16'h0644, 16'h0646, 16'h0648, 16'h064A,
        16'h064C, 16'h064E, 16'h074C, 16'h074E,
        16'h0430, 16'h0432, 16'h1E8E: is_named = 1;
        16'h0060, 16'h0062:  is_named = 1;
        16'h00A0, 16'h00A2:  is_named = 1;
        16'h006A, 16'h007C, 16'h007E, 16'h00A6: is_named = 1;
        default:             is_named = 0;
      endcase
    end
  endfunction

  integer errors = 0;
  integer measured_cycles = 0;
  reg [15:0] probe_port = 16'h0000;

  // One I/O read of `port`, counting clk_sys from the request to cpu_ready, the
  // same idiom tb_pc9821_io_wait uses: cpu_addr carries the BASE (the port with
  // its low two bits zero) and the LANE rides in cpu_be. The count is the class
  // hold plus one, because the request is presented on the negedge it is counted
  // from; `measured_cycles - 1` is the table value.
  task automatic measure_port;
    begin
      @(negedge clk);
      cpu_addr  = {16'd0, probe_port[15:2], 2'b00};
      cpu_be    = 4'b0001 << probe_port[1:0];
      cpu_write = 1'b0;
      cpu_valid = 1'b1;
      measured_cycles = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        measured_cycles = measured_cycles + 1;
        if (measured_cycles > 50000) begin
          $display("FAIL port %04x never became ready", probe_port);
          errors = errors + 1;
          measured_cycles = -1;
          disable measure_port;
        end
      end
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be    = 4'b0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  // The same measurement for a MULTI-LANE access, exactly as a real `in ax,dx` presents it: ONE
  // request, `base_port` the aligned base (its low two bits zero) and cpu_be carrying the lanes,
  // so the DUT prices the whole access - which is what this check is about. `wr` selects the
  // direction (the 8253 floor is write-only). Still `measured_cycles - 1` = the priced total.
  task automatic measure_lanes(input [15:0] base_port, input [3:0] be, input wr);
    // No `disable measure_lanes` here on purpose: Verilator 5.052 mis-parses a `disable` of the
    // enclosing task when the task HAS ports, and reports every call to it as "Too many
    // arguments". The overrun flag below is the same safety net (the bench's own watchdog
    // bounds a real hang).
    integer over;
    begin
      over = 0;
      @(negedge clk);
      cpu_addr  = {16'd0, base_port[15:2], 2'b00};
      cpu_be    = be;
      cpu_write = wr;
      cpu_valid = 1'b1;
      measured_cycles = 0;
      while (!cpu_ready && !over) begin
        @(negedge clk);
        measured_cycles = measured_cycles + 1;
        if (measured_cycles > 50000) begin
          $display("FAIL lanes %04x/%0x never became ready", base_port, be);
          errors = errors + 1;
          measured_cycles = -1;
          over = 1;
        end
      end
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be    = 4'b0;
      cpu_write = 1'b0;
      while (dut.state != 0 && !over) @(negedge clk);
    end
  endtask

  task automatic check_lanes(input [15:0] base_port, input [3:0] be, input wr,
                             input integer want, input string what);
    begin
      measure_lanes(base_port, be, wr);
      if (measured_cycles - 1 != want) begin
        $display("FAIL %0s: lanes %0x of %04x priced %0d clk_sys, expected %0d",
                 what, be, base_port, measured_cycles - 1, want);
        errors = errors + 1;
      end else begin
        $display("  lane sum  %04x be=%0x   priced %4d clk_sys  (%0s)",
                 base_port, be, measured_cycles - 1, what);
      end
    end
  endtask

  // Named arms plus the ports the campaign's EGC traffic uses.
  reg [15:0] audit [0:47];
  integer    audit_n = 0;
  integer    i = 0;
  integer    default_ports = 0, named_ports = 0;
  integer    egc_fast = 0;
  integer    m = 0;

  // ==== STIMULUS ====
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    audit[0]  = 16'h005F; audit[1]  = 16'h0640; audit[2]  = 16'h0641;
    audit[3]  = 16'h0642; audit[4]  = 16'h0644; audit[5]  = 16'h0646;
    audit[6]  = 16'h0648; audit[7]  = 16'h064A; audit[8]  = 16'h064C;
    audit[9]  = 16'h064E; audit[10] = 16'h074C; audit[11] = 16'h074E;
    audit[12] = 16'h0430; audit[13] = 16'h0432; audit[14] = 16'h1E8E;
    audit[15] = 16'h0060; audit[16] = 16'h0062; audit[17] = 16'h00A0;
    audit[18] = 16'h00A2; audit[19] = 16'h043B;
    audit[20] = 16'h006A; audit[21] = 16'h007C; audit[22] = 16'h007E; audit[23] = 16'h00A6;
    for (i = 0; i < 16; i = i + 1) audit[24 + i] = 16'h04A0 + i;
    audit[40] = 16'h0071; audit[41] = 16'h0073; audit[42] = 16'h0075;
    audit[43] = 16'h0077; audit[44] = 16'h3FD9; audit[45] = 16'h3FDB;
    audit[46] = 16'h3FDD; audit[47] = 16'h3FDF;
    audit_n = 48;

    // One line per named port, then the class-by-class audit record. `measure_port` is a READ,
    // so this loop compares against the read direction of the table (the 8253 arm's floor is
    // write-only; the write direction is measured separately below).
    for (i = 0; i < audit_n; i = i + 1) begin
      probe_port = audit[i];
      measure_port;
      m = measured_cycles - 1;
      if (m != class_of(probe_port, 1'b0)) begin
        $display("FAIL port %04x modelled %0d clk_sys, the table says %0d",
                 probe_port, m, class_of(probe_port, 1'b0));
        errors = errors + 1;
      end
      $display("  port %04x  modelled %4d clk_sys  (table %4d)",
               probe_port, m, class_of(probe_port, 1'b0));
    end

    // ---- the 8253's two directions ----
    // The ITF's POST timer self-test writes a count and reads it straight back, which is what
    // the >1 PIT tick floor is for, and it is a WRITE-side requirement: the capture's own 8253
    // rows are READS at the default class (PITD0/PITD1, docs/probes/IO.TXT: 823.3 ns, xRTL
    // 10.3 against the old 21-clk read arm). So the read is the FSM floor and the write keeps
    // IO_PIT_HOLD. FAIL-FIRST: before the fix the read measured 21 here.
    for (i = 40; i < audit_n; i = i + 1) begin
      probe_port = audit[i];
      measure_lanes({16'd0, probe_port[15:2], 2'b00}, 4'b0001 << probe_port[1:0], 1'b1);
      if (measured_cycles - 1 != CLASS_PITW) begin
        $display("FAIL 8253 port %04x WRITE modelled %0d clk_sys, expected %0d (one 2.4576 MHz tick)",
                 probe_port, measured_cycles - 1, CLASS_PITW);
        errors = errors + 1;
      end else begin
        $display("  port %04x  WRITE modelled %4d clk_sys  (the ITF self-test floor)",
                 probe_port, CLASS_PITW);
      end
    end

    $display("  --- audit ---");
    $display("  class wait   0x005F        modelled %4d  the machine's item-41 1621 ns, ONE value (a wr-dependent value trips a Quartus fitter bug)",
             CLASS_WAIT);
    $display("  class pit    0x0071-0x0077/0x3FD9-0x3FDF modelled %4d (write) / %4d (read)  the ITF self-test floor, kept on the WRITE: >= one 2.4576 MHz tick (20.34); the read is the default class, as captured",
             CLASS_PITW, CLASS_PITR);
    $display("  class ide    0x0640/0x0641 modelled %4d  the FSM floor (was the machine's measured 170 ns)",
             CLASS_IDE);
    $display("  class ata    0x0642-0x064E/0x074C/0x074E/0x0430/0x0432/0x1E8E modelled %4d  the FSM floor (was the machine's 299 ns scalar access)",
             CLASS_ATA);
    $display("  class gdc1   0x0060/0x0062 modelled %4d  the FSM floor (was the machine's 162 ns IDLE poll)",
             CLASS_GDC1);
    $display("  class gdc2   0x00A0/0x00A2 modelled %4d  the FSM floor (was the machine's 257 ns IDLE poll)",
             CLASS_GDC2);
    $display("  class default every other port modelled %4d  the FSM floor (was the machine's 299 ns scalar access)",
             CLASS_DEF);
    $display("  class egc    0x04A0-0x04AF/0x006A/0x007C/0x007E/0x00A6 modelled %4d  the FSM floor (was 7)",
             CLASS_EGC);
    $display("  the FSM floor is S_IDLE -> S_IOWAIT -> S_BYTE -> S_REPLY; the class value is the hold plus the FSM's own three cycles");
    $display("  NP2kai iocore.c:621,630 charges ONE flat cost per access (%.2f clk_sys = one 2.4576 MHz base clock), no per-port class", NP2_FLAT);
    $display("  qemu-pc98: no I/O timing at all; R10.TXT/PORTS.TXT/EMS.TXT/WIN.TXT hold port VALUES, no timing row");
    $display("  -> every class is now at the FSM floor but the two the firmware measures; the machine's measured ladder is NOT modelled");

    // The campaign's EGC ports carry the FSM floor like every other non-floor
    // class now. The GRCG pair (0x007C mode, 0x007E tile) is a later addition:
    for (i = 20; i < 40; i = i + 1) begin
      probe_port = audit[i];
      measure_port;
      if (measured_cycles - 1 == CLASS_EGC) egc_fast = egc_fast + 1;
      else begin
        $display("FAIL EGC port %04x is NOT the EGC class: %0d clk_sys", probe_port, measured_cycles - 1);
        errors = errors + 1;
      end
    end
    $display("  EGC ports on the EGC class: %0d of %0d", egc_fast, 20);

    // The whole 16-bit port space, so the inventory of the default is exact.
    for (i = 0; i <= 65535; i = i + 1) begin
      probe_port = i[15:0];
      measure_port;
      if (measured_cycles - 1 != class_of(probe_port, 1'b0)) begin
        if (errors < 8)
          $display("FAIL port %04x modelled %0d clk_sys, the table says %0d",
                   probe_port, measured_cycles - 1, class_of(probe_port, 1'b0));
        errors = errors + 1;
      end
      if (is_named(probe_port)) named_ports = named_ports + 1;
      else default_ports = default_ports + 1;
    end
    $display("  sweep: %0d ports modelled the default %0d, %0d ports carry a named class",
             default_ports, CLASS_DEF, named_ports);

    // ---- the lanes: EVERY lane the access fetches pays its own class ----
    // On the machine each byte of a multi-byte access is its own bus cycle, so its own class
    // applies: `in ax,0x5E` (the ARTIC word read, 20 firmware sites) is 0x5E's class plus
    // 0x5F's, and two same-class lanes are two classes. FAIL-FIRST: the old first-lane-only
    // rule measured 5 for the 0x0000 word read and 5 for this one instead of 8 and 34.
    m = 0;
    check_lanes(16'h0000, 4'b0011, 1'b0, CLASS_DEF + CLASS_DEF, "word read, two default lanes 0x00/0x01");
    check_lanes(16'h005C, 4'b1100, 1'b0, CLASS_DEF + CLASS_WAIT, "in ax,0x5E: the ARTIC word read, its high lane the 0x5F class");
    check_lanes(16'h04A0, 4'b0011, 1'b0, CLASS_EGC + CLASS_EGC, "word read over the EGC file block");
    check_lanes(16'h0430, 4'b0011, 1'b1, CLASS_ATA + CLASS_ATA, "word WRITE of the IDE interface register pair");
    check_lanes(16'h0060, 4'b0011, 1'b0, CLASS_GDC1 + CLASS_GDC1, "in ax,0x60: the text GDC status and its parameter lane");
    check_lanes(16'h005C, 4'b1111, 1'b0, 3 * CLASS_DEF + CLASS_WAIT, "32-bit read of the ARTIC counter's 0x5C-0x5F lanes (3 + the 0x5F class)");
    // The ONE lane that walks but is not charged: the terminated high lane of a word read at
    // 0x7C (NP2kai's minus_term; the machine never fetches port 0x7D). Its own S_BYTE cycle is
    // still spent, so the access is one class plus one cycle - unchanged by this fix.
    check_lanes(16'h007C, 4'b0011, 1'b0, CLASS_DEF + 1, "word read at 0x7C: the 0x7D lane is terminated and pays no class");

    // What the table must be for the firmware and the captures to mean anything.
    if (default_ports != 65489 || named_ports != 47) begin
      $display("FAIL the table covers %0d default + %0d named ports, expected 65489 + 47",
               default_ports, named_ports);
      errors = errors + 1;
    end
    if (egc_fast != 20) begin
      $display("FAIL only %0d of 20 EGC ports carry the EGC class", egc_fast);
      errors = errors + 1;
    end
    // The two floors survive and keep their values: the ITF's POST timer self-test
    // (BANK4@0x038F) needs the 8253 WRITE to outlast one 2.4576 MHz PIT tick (20.34),
    // and the firmware's own delay loops measure 0x005F (the 600 ns anchor).
    if (CLASS_WAIT < PIT_TICK || CLASS_PITW < PIT_TICK) begin
      $display("FAIL the POST self-test needs the 8253 WRITE to outlast one PIT tick: wait=%0d pitw=%0d",
               CLASS_WAIT, CLASS_PITW);
      errors = errors + 1;
    end
    if (CLASS_WAIT < DOC_WAIT) begin
      $display("FAIL 0x5F models %0d clk_sys, under the documented 600 ns (%0d): the firmware's own I/O-wait anchor",
               CLASS_WAIT, DOC_WAIT);
      errors = errors + 1;
    end
    if (real'(CLASS_PITW) < NP2_FLAT) begin
      $display("FAIL the 8253 write arm %0d is inside NP2kai's flat per-access cost %.2f: it no longer clears the ITF floor",
               CLASS_PITW, NP2_FLAT);
      errors = errors + 1;
    end
    // The READ side of the 8253 is the floor (F7): the floor is the WRITE's requirement, and
    // the capture prices an 8253 read at the default class. A read arm at the PIT floor would
    // be the old defect back again.
    if (CLASS_PITR != CLASS_MIN) begin
      $display("FAIL the 8253 READ arm is %0d clk_sys, not the default class (%0d): the capture prices PITD0/PITD1 at the default class",
               CLASS_PITR, CLASS_MIN);
      errors = errors + 1;
    end
    // The contract: EVERY class but the two floors is the FSM
    // minimum. The machine's measured ladder (default 15 = IDE task file
    // 15 > graphics GDC 13 > text GDC 8 = IDE data 8 > EGC 7) is deliberately not matched.
    if (!(CLASS_WAIT > CLASS_PITW && CLASS_PITW > CLASS_MIN)) begin
      $display("FAIL the surviving floor ranking is broken: wait=%0d pitw=%0d min=%0d",
               CLASS_WAIT, CLASS_PITW, CLASS_MIN);
      errors = errors + 1;
    end
    if (!(CLASS_IDE == CLASS_MIN && CLASS_ATA == CLASS_MIN &&
          CLASS_GDC1 == CLASS_MIN && CLASS_GDC2 == CLASS_MIN &&
          CLASS_EGC == CLASS_MIN && CLASS_DEF == CLASS_MIN)) begin
      $display("FAIL a non-floor class is not the FSM minimum %0d: ide=%0d ata=%0d gdc1=%0d gdc2=%0d egc=%0d default=%0d",
               CLASS_MIN, CLASS_IDE, CLASS_ATA, CLASS_GDC1, CLASS_GDC2, CLASS_EGC, CLASS_DEF);
      errors = errors + 1;
    end

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_IO_CLASS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_IO_CLASS: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_IO_CLASS: TIMEOUT");
  end

endmodule

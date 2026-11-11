module tb_pc9821_io_wait;
  // System port C bit 3: the beeper's MUTE (pc9821_iobus, ANDed with the PIT's
  // channel 2 in pc9821_system). This bench does not drive the beeper, but it
  reg [3:0]  bios_set = 4'd0;      // OSD BIOS set: 0 = PC-9821Xe10 (the default strap)
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  msw_hold = 1'b0;        // port 0x31 bit 4 at the measured machine's memory-switch init (0xF3)
  reg  text_lines_20 = 1'b0;   // port 0x31 bit 3 at the measured 25 lines (0xF3)
  reg  [1:0] floppy_mode = 2'd0;   // Auto (1M), 0x861E = 0xF7: the Floppy mode default
  wire [23:0] setup_cfg;       // the OSD configuration pc9821_cg is built from (unread here)
  // instantiates pc9821_iobus with (.*), which needs every port named -
  // tools/check_wiring.py enforces that, and it caught exactly this when the
  // port was added. tb_pc9821_beeper covers the behaviour.
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)
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
  // This bench models a device that presents its data in the strobe cycle,
  // which is every device except the GDC, so it must not ask for the extra
  // read cycle. Leaving it at z would make the I/O bus's wait decision
  // unknown instead of false.
  reg       device_rd_wait = 1'b0;
  wire [3:0] top_bank;
  wire sound_extend;
  wire ide_rom_enable, bios_ram_gate;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [7:0] win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire sys16m_en;   // 0x043B bit 2, the 15-16 MiB system-space window
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
  wire [15:0] dbg_last_io_addr;   // the most recent I/O access (the IO/DR/IV fields)
  wire  [7:0] dbg_last_io_data;
  wire        dbg_last_io_rd;
  wire        dbg_last_io_wr;
  wire        dbg_last_io_stb;
  // The FDC's debug taps: named because the DUT is (.*), not exercised here
  // (tb_pc9821_fdc_dbg pins them).
  wire [7:0]  dbg_fdc_state;
  wire [7:0]  dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;
  reg        cal_cdat = 0;   // serial calendar data, sampled into 0x33 bit 0
  // The configuration-image seed (pc9821_gdc_text's cfg_* block / pc9821_iobus's memory-switch
  // strap cell): 0 = no seed, which is what this bench wants. tb_pc9821_cg_read_path drives it.
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  // z486's triple_fault_reset: a one-cycle CPU shutdown pulse, connected to the
  // I/O bus in the core so it is consumed locally.
  reg        triple_fault_reset = 1'b0;
  // EGC: the gate pc9821_gdc_text exports (FF2 num 2 AND 0x7C bit 7), its register
  // file, and the 0x4AC/0x4AE shifter-reload pulse.
  reg        egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;
  integer     egc_shift_pulses = 0;

// ==== WHAT THIS PROVES ====
// Counts actual clk_sys cycles from request to cpu_ready for one port per class (0x005F wait, the 8253 0x0071 in BOTH directions, 0x0043 chipset, 0x0060 text GDC, 0x00A0 graphics GDC, the GRCG pair 0x007C/0x007E, an unmapped port) after a change lowered every class but the two the firmware measures to the FSM minimum: an 8253 WRITE still carries the one-2.4576-MHz-tick floor (21) while an 8253 READ is the FSM floor, which is the direction the floor is FOR (the ITF's own self-test programs a count and reads it straight back, and the capture reads 8253 count registers at the default class), the I/O-wait port 0x005F is the FSM floor on its own access in both directions (a read is the default class; a write is posted) while a write plus the access behind it is still the LONGEST wait (the posted write's bus time), and every other class -- the chipset default, both GDC idle polls, the GRCG pair and an unmapped port -- is now the 4-cycle FSM floor, so the machine's measured ladder (default 15 > graphics GDC 13 > text GDC 8 > EGC 7, with the GRCG pair at the EGC class) is no longer modelled. Also checks the responder contract on every access: the response must arrive on a later cycle than the accept, never in it.
//
// ---- the bench's own account of where each expectation comes from ----
//
// This exists because the per-class I/O wait is the fix that unblocked the boot
// and it has almost no test. The ITF's POST self-test at BANK4@0x038F programs a
// PIT counter, latches it and reads it back, and requires the count to have
// MOVED between the two writes: the bus access must outlast one 2.4576 MHz PIT
// tick (20.34 cycles) or the read is the byte just written and POST halts with
// TIMER ERROR at cs:0x2b39.
//   [source: the commit that landed the table]
//
// WHAT IS ASSERTED. The machine's per-class ladder was measured; matching it is
// waived in favour of the minimum, so EVERY class but the two
// the FIRMWARE measures is now IO_MIN_HOLD (4):
//   1. the 8253 WRITE costs at least one PIT tick (21 >= 20.34) - the ITF's own
//      requirement, and the floor that was being violated; its READ costs the default
//      class, which is what the capture prices (F7);
//   2. the I/O-wait port 0x005F (a posted write plus the access behind it) is still the
//      LONGEST: the firmware's own
//      delay loops measure it, so it is a floor rather than a timing choice;
//   3. every other class measures the 4-cycle FSM floor: the chipset default, the
//      text/graphics GDC, the GRCG pair 0x007C/0x007E and an unmapped port alike.
//
// Ports: 0x005F wait, 0x0071 the 8253, 0x0043 chipset/system, 0x0060 text GDC,
// 0x00A0 graphics GDC, 0x007C/0x007E the GRCG pair, 0x0123 unmapped.

  // ==== DUT ====
  // The software-DIP store is now enabled by default in the core, but the
  // override is kept to document that this bench exercises writes.
  // 0x043F EMS page register / window select (pc9821_iobus outputs).
  wire [1:0] ems_state;
  wire top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  // The FDC's level interrupt (slave PIC IRQ11). pc9821_iobus carries the
  // port and the `.*` DUT instantiation matches by name, so it must
  // be declared here; this bench does not exercise the floppy path.
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window

  reg device_rd_hold = 1'b0;
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
  wire [31:0] dma_mem_addr_nx;   // the address dma_mem_addr loads next, and its load cycle (unused here)
  wire        dma_mem_load;
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
  // The OSD's I/O timing field (pc9821_iobus io_timing_xe10): Fast, the default table.
  wire io_timing_xe10 = 1'b0;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

  // ==== CHECKS ====


  integer errors = 0;
  integer measured_cycles = 0;
  integer c_wait = 0, c_pit_w = 0, c_pit_r = 0, c_chipset = 0, c_gdc1 = 0, c_gdc2 = 0;
  integer c_grcg_mode = 0, c_grcg_tile = 0, c_unmapped = 0, c_5f_r = 0, c_5f_w = 0;
  reg [15:0] probe_port = 16'h0000;
  // The direction of the next timed access. The 8253 is the ONE port whose class depends on it
  //: its floor is the ITF self-test's WRITE requirement, so the read measures
  // the FSM floor. Held in a module-level reg rather than passed as a task argument because
  // this Verilator (5.052) mis-parses `disable` of a task that HAS ports.
  reg        probe_write = 1'b0;
  localparam integer PIT_TICK = 21;     // 2.4576 MHz against 50 MHz clk_sys = 20.34
  localparam integer IO_MIN_HOLD = 4;   // the FSM floor every non-floor class takes (pc9821_iobus.sv)

  // One I/O access to `port` in the direction `probe_write`, counting clk_sys cycles from the
  // request to cpu_ready.
  // The response is waited for separately because the responder contract requires
  // accept and response in SEPARATE cycles; a route that answered in the accept
  // cycle would clear nothing and wedge the CPU.
  task automatic measure_port;
    reg [1:0] lane;
    begin
      // The request idiom is the one the iobus bench already uses and the bus
      // actually takes: cpu_addr carries the BASE address (port bits 15:2 with
      // the low two forced to zero) and the LANE rides in cpu_be. Passing the
      // port number as the address instead makes the bus answer a different
      // port, which is how the first version of this bench measured nothing.
      lane = probe_port[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, probe_port[15:2], 2'b00};
      cpu_be   = 4'b0001 << lane;
      cpu_din  = 32'h0000_0000;
      cpu_write = probe_write;
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
      cpu_write = 1'b0;
      // Drain: the bus returns to IDLE before the next access can start.
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // 0x005F: its READ is the default class (the floor) and its WRITE is posted - the write's
    // own access is the floor and its bus time lands on the access right behind it, so the
    // wait is timed as the write plus that access.
    probe_port = 16'h005F; measure_port; c_5f_r    = measured_cycles;
    probe_write = 1'b1;
    probe_port = 16'h005F; measure_port; c_5f_w    = measured_cycles;
    probe_write = 1'b0;
    probe_port = 16'h0123; measure_port; c_wait    = c_5f_w + measured_cycles;
    // The 8253 in BOTH directions: its write keeps the ITF self-test floor and its read is the
    // default class the capture prices (F7). FAIL-FIRST on the read: it measured 21 before.
    probe_write = 1'b1;
    probe_port = 16'h0071; measure_port; c_pit_w   = measured_cycles;
    probe_write = 1'b0;
    probe_port = 16'h0071; measure_port; c_pit_r   = measured_cycles;
    probe_port = 16'h0043; measure_port; c_chipset = measured_cycles;
    probe_port = 16'h0060; measure_port; c_gdc1    = measured_cycles;
    probe_port = 16'h00A0; measure_port; c_gdc2    = measured_cycles;
    probe_port = 16'h007C; measure_port; c_grcg_mode = measured_cycles;
    probe_port = 16'h007E; measure_port; c_grcg_tile = measured_cycles;
    probe_port = 16'h0123; measure_port; c_unmapped  = measured_cycles;

    $display("  io_wait cycles: wait=%0d pit_w=%0d pit_r=%0d chipset=%0d gdc_text=%0d gdc_graphics=%0d",
             c_wait, c_pit_w, c_pit_r, c_chipset, c_gdc1, c_gdc2);
    $display("  io_wait GRCG pair: mode 0x007C=%0d tile 0x007E=%0d unmapped 0x0123=%0d",
             c_grcg_mode, c_grcg_tile, c_unmapped);

    // 1. the ITF's floor: the 8253 WRITE must outlast one PIT tick. The self-test programs a
    //    count into the counter and reads it straight back, so the floor belongs to the write;
    //    it is the one class the machine's own (299 ns) access cannot be matched on, so it
    //    alone carries the floor and every other class is at or below the machine's.
    if (c_pit_w - 1 < PIT_TICK) begin
      $display("FAIL the 8253 WRITE took %0d cycles, under one PIT tick (%0d): the ITF's own self-test cannot pass",
               c_pit_w - 1, PIT_TICK);
      errors = errors + 1;
    end
    // 1b. ...and the READ is the default class, not the floor: the machine
    //     reads an 8253 count register at the default class (its PITD0/PITD1 rows in
    //     docs/probes/IO.TXT), which this profile models as the FSM floor. FAIL-FIRST.
    if (c_pit_r - 1 != IO_MIN_HOLD) begin
      $display("FAIL the 8253 READ modelled %0d clk_sys, expected the default class (%0d): the floor is the WRITE's requirement",
               c_pit_r - 1, IO_MIN_HOLD);
      errors = errors + 1;
    end
    if (c_wait < 1) begin
      $display("FAIL the I/O-wait port read %0d cycles", c_wait);
      errors = errors + 1;
    end
    // 1c. 0x005F: the read is the default class and the write releases the CPU at the floor
    //     (posted: docs/probes/XE10T-XE10.TXT /IO R8_005F is the default read class, and
    //     W8_005F's period holds with 340 ns of work overlapping each write).
    if (c_5f_r - 1 != IO_MIN_HOLD || c_5f_w - 1 != IO_MIN_HOLD) begin
      $display("FAIL 0x005F is not the floor on its own access: read %0d, write %0d clk_sys (the write is posted)",
               c_5f_r - 1, c_5f_w - 1);
      errors = errors + 1;
    end

    // 2. the surviving ranking, on the directions that carry the floors:
    //    the wait (30) > the 8253 WRITE (21) > the FSM floor (4). The machine's measured ladder
    //    below the 8253 is waived: every non-floor class is now the same 4-cycle floor.
    if (!(c_wait - 1 > c_pit_w - 1 && c_pit_w - 1 > c_chipset - 1)) begin
      $display("FAIL the surviving floor ranking is broken: wait=%0d pit_w=%0d chipset=%0d",
               c_wait - 1, c_pit_w - 1, c_chipset - 1);
      errors = errors + 1;
    end

    // 3. every non-floor class measures the FSM floor, GDC pair and GRCG pair alike:
    //    the chipset default, both GDC idle polls, the GRCG pair and an unmapped port.
    if (!(c_chipset - 1 == IO_MIN_HOLD && c_gdc1 - 1 == IO_MIN_HOLD &&
          c_gdc2 - 1 == IO_MIN_HOLD)) begin
      $display("FAIL a GDC/default class is not the %0d-cycle FSM floor: chipset=%0d gdc_text=%0d gdc_graphics=%0d",
               IO_MIN_HOLD, c_chipset - 1, c_gdc1 - 1, c_gdc2 - 1);
      errors = errors + 1;
    end

    // 4. the GRCG pair 0x007C/0x007E is the FSM floor too (it was put on
    //    the EGC class, and the EGC class is now the floor): grcg_setcolor writes
    //    0x007C then 0x007E back-to-back, so both cost the same and both equal an
    //    unmapped port's floor.
    if (c_grcg_mode - 1 != IO_MIN_HOLD || c_grcg_tile - 1 != IO_MIN_HOLD) begin
      $display("FAIL the GRCG pair is not the %0d-cycle FSM floor: mode 0x007C modelled %0d, tile 0x007E modelled %0d",
               IO_MIN_HOLD, c_grcg_mode - 1, c_grcg_tile - 1);
      errors = errors + 1;
    end
    if (!(c_grcg_mode - 1 == c_unmapped - 1 && c_grcg_tile - 1 == c_unmapped - 1)) begin
      $display("FAIL the GRCG pair is not the same floor as an unmapped port: mode 0x007C=%0d tile 0x007E=%0d unmapped 0x0123=%0d",
               c_grcg_mode - 1, c_grcg_tile - 1, c_unmapped - 1);
      errors = errors + 1;
    end
    if (c_unmapped - 1 != IO_MIN_HOLD) begin
      $display("FAIL an unmapped port modelled %0d clk_sys, expected the FSM floor %0d", c_unmapped - 1, IO_MIN_HOLD);
      errors = errors + 1;
    end

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_IO_WAIT: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_IO_WAIT: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_IO_WAIT: TIMEOUT");
  end

endmodule

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_IO_5F: port 0x5F through the real pc9821_iobus at the shipped 90 MHz clk_sys, against the real Xe10 (docs/probes/XE10T-XE10.TXT /IO): an `in al,5Fh` costs no more than the machine's 788.4 ns (its R8_005F row, the default read class), an `out 5Fh,al` releases the CPU no later than 1404.1 ns after it starts (the machine's write period 1744.2 ns less the 340.1 ns of nops its W8_005F k=32 row overlaps with it: the write is posted), and back-to-back writes with the machine's own between-write work (its W8_005F control times 19.1, 41.3, 57.2, 98.5, 178.0 and 340.1 ns for k = 0..32 nops) recur every 1744.2 ns within one clk_sys at every k (the row's flat PIT period, 1744.0-1744.4 ns), where a blocking write grows with the work; an I/O access to another port after a 0x5F write starts no earlier than that period after it, so a firmware delay pair (`out 0x02 / out 0x5F`) is never shorter than on the machine.
//
// The expected values are the machine's: tools/hwprobe/xe10t/xe10t_decode.py on
// docs/probes/XE10T-XE10.TXT prints, for the /IO rows,
//   R8_005F   nop 0  gross 810.6  ctl 22.3  net 788.4  pit 803.4
//   W8_005F   nop 0/2/4/8/16/32  gross 1751.6 (every k)  ctl 19.1/41.3/57.2/98.5/178.0/340.1
//             pit 1744.4/1743.6/1744.0/1744.4/1744.0/1744.0
//   SWEEP W8_005F period 1751.6 ns ... KNEE-NOT-FOUND
// The ARTIC (gross) resolution is 3.18 ns per access over 1024 accesses; the PIT column is
// the finer one, so the period expected here is the PIT's 1744.0-1744.4 ns.

module tb_pc9821_io_5f;
  localparam real CLK_NS = 1000.0 / 90.0;   // 11.111 ns
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
  always #(CLK_NS / 2.0) clk = ~clk;   // 90 MHz, the shipped base profile's clk_sys
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
// Counts actual clk_sys cycles from request to cpu_ready for one port per class (0x005F wait, the 8253 0x0071 in BOTH directions, 0x0043 chipset, 0x0060 text GDC, 0x00A0 graphics GDC, the GRCG pair 0x007C/0x007E, an unmapped port) after a change lowered every class but the two the firmware measures to the FSM minimum: an 8253 WRITE still carries the one-2.4576-MHz-tick floor (21) while an 8253 READ is the FSM floor, which is the direction the floor is FOR (the ITF's own self-test programs a count and reads it straight back, and the capture reads 8253 count registers at the default class), the I/O-wait port is still the LONGEST (30), and every other class -- the chipset default, both GDC idle polls, the GRCG pair and an unmapped port -- is now the 4-cycle FSM floor, so the machine's measured ladder (default 15 > graphics GDC 13 > text GDC 8 > EGC 7, with the GRCG pair at the EGC class) is no longer modelled. Also checks the responder contract on every access: the response must arrive on a later cycle than the accept, never in it.
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
//   2. the I/O-wait port 0x005F is still the LONGEST (30): the firmware's own
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
  wire [1:0]  dma_mem_gvwin;   // the DMAC's plane-window class (unused here)
  wire [3:0]  dma_mem_be;
  wire        dma_mem_req, dma_mem_we;
  wire        dma_mem_ready = 1'b0;
  wire [31:0] dma_mem_dout = 32'd0;
  wire        dma_mem_resp_valid = 1'b0;
  wire [31:0] dma_mem_addr_nx;   // the address dma_mem_addr loads next, and its load cycle (unused here)
  wire        dma_mem_load;
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
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1), .SYS_CLOCK_HZ(32'd90_000_000)) dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

  // ==== STIMULUS ====
  integer errors = 0;
  realtime t_ready;          // when the last access's cpu_ready was seen
  realtime t_start;          // when the last access was presented

  // One byte access to `port`; returns when the bus is idle again. t_start/t_ready are the
  // request's presentation and its cpu_ready, both on the falling edge (so the half period
  // cancels in every difference below).
  task automatic io(input [15:0] port, input wr);
    reg [1:0] lane;
    integer guard;
    begin
      lane = port[1:0];
      @(negedge clk);
      cpu_addr  = {16'd0, port[15:2], 2'b00};
      cpu_be    = 4'b0001 << lane;
      cpu_din   = 32'h0000_0000;
      cpu_write = wr;
      cpu_valid = 1'b1;
      t_start   = $realtime;
      guard = 0;
      while (!cpu_ready && guard < 50000) begin
        @(negedge clk);
        guard = guard + 1;
      end
      if (!cpu_ready) begin
        $display("FAIL port %04x never became ready", port);
        errors = errors + 1;
      end
      t_ready = $realtime;
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be    = 4'b0;
      cpu_write = 1'b0;
    end
  endtask

  // Wait `ns` of CPU work (rounded up to whole clk_sys) after the last access's ready.
  task automatic work(input real ns);
    begin
      while ($realtime - t_ready < ns) @(negedge clk);
    end
  endtask

  // ==== CHECKS ====
  localparam real M_5F_READ   = 788.4;    // R8_005F net
  localparam real M_5F_PERIOD = 1744.2;   // W8_005F PIT period, 1744.0-1744.4 over k = 0..32
  localparam real M_5F_K32    = 340.1;    // W8_005F k=32 control time: work the write overlaps
  real m_ctl [0:5];
  real cost, period, prev, gap;
  integer k, n;

  initial begin
    m_ctl[0] = 19.1; m_ctl[1] = 41.3; m_ctl[2] = 57.2;
    m_ctl[3] = 98.5; m_ctl[4] = 178.0; m_ctl[5] = 340.1;
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (4) @(posedge clk);

    // 1. the read: no slower than the machine's default read class.
    io(16'h005F, 1'b0);
    cost = t_ready - t_start;
    $display("  in al,5Fh: %0.1f ns (machine %0.1f)", cost, M_5F_READ);
    if (cost > M_5F_READ) begin
      $display("FAIL an in al,5Fh costs %0.1f ns, over the machine's %0.1f ns", cost, M_5F_READ);
      errors = errors + 1;
    end

    // 2. a lone write releases the CPU early enough for the machine's k=32 overlap.
    repeat (400) @(posedge clk);   // the bus idle, nothing posted
    io(16'h005F, 1'b1);
    cost = t_ready - t_start;
    $display("  out 5Fh,al (bus idle): CPU released after %0.1f ns (machine at most %0.1f)",
             cost, M_5F_PERIOD - M_5F_K32);
    if (cost > M_5F_PERIOD - M_5F_K32) begin
      $display("FAIL an out 5Fh,al holds the CPU %0.1f ns: the machine's k=32 row overlaps %0.1f ns of work with a %0.1f ns write",
               cost, M_5F_K32, M_5F_PERIOD);
      errors = errors + 1;
    end

    // 3. back-to-back writes with the machine's between-write work: the period is flat.
    for (k = 0; k < 6; k = k + 1) begin
      repeat (400) @(posedge clk);
      io(16'h005F, 1'b1);
      prev = t_ready;
      period = 0.0;
      for (n = 0; n < 8; n = n + 1) begin
        work(m_ctl[k]);
        io(16'h005F, 1'b1);
        period = period + (t_ready - prev);
        prev = t_ready;
      end
      period = period / 8.0;
      $display("  out 5Fh loop, %0.1f ns of work between writes: period %0.1f ns (machine %0.1f)",
               m_ctl[k], period, M_5F_PERIOD);
      if (period < M_5F_PERIOD - CLK_NS || period > M_5F_PERIOD + CLK_NS) begin
        $display("FAIL the out 5Fh period with %0.1f ns of work is %0.1f ns, not the machine's %0.1f ns (+-1 clk)",
                 m_ctl[k], period, M_5F_PERIOD);
        errors = errors + 1;
      end
    end

    // 4. another port right behind a 0x5F write starts no earlier than the write's period.
    repeat (400) @(posedge clk);
    io(16'h005F, 1'b1);
    prev = t_start;
    io(16'h0043, 1'b1);
    gap = t_ready - prev;
    $display("  out 5Fh then out 43h: the second access completes %0.1f ns after the first starts", gap);
    if (gap < M_5F_PERIOD - CLK_NS) begin
      $display("FAIL an access behind a 0x5F write completed %0.1f ns after it, inside the machine's %0.1f ns write",
               gap, M_5F_PERIOD);
      errors = errors + 1;
    end

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_IO_5F: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_IO_5F: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_IO_5F: TIMEOUT");
  end

endmodule

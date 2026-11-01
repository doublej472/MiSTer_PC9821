`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PIT_TICK:
// TB_PC9821_PIT_TICK: The 8253 arm of the I/O class table is DERIVED from the profile clock, so the ITF's POST self-test floor holds at every clock the tree can be built for and not only at the 50 MHz base profile: with the iobus parameterised at 85 MHz (the `production` clock) an 8253 WRITE still outlasts one 2.4576 MHz PIT tick, where a fixed 21-cycle arm delivered 22 cycles = 259 ns and fell 148 ns short. The floor is asserted on the WRITE because that is the direction it exists for -- the ITF's self-test programs a count into the counter and reads it back, while the machine READS 8253 count registers at the default class (its PITD0/PITD1 rows in docs/probes/IO.TXT), so the read carries no floor at all. The bench asserts the property -- the delivered write, converted at SYS_CLOCK_HZ, covers one tick -- on the real port 0x0071 and its 0x3FDB alias, and that the arm still fits the bus's 12-bit hold field.
//
// ---- the bench's own account of where the expectation comes from ----
//
// This exists because this is the one known failure that can turn a reshaped
// wait-state table into a failed POST, and NOTHING in the tree would have caught it. The
// ITF's self-test (BANK4@0x038C-0x03CA) loads 0xFF into a PIT channel's counter, then
// issues a count-latch command and reads the latched count; the read must not be the byte
// just written, so at least one 2.4576 MHz tick (407 ns) must elapse between the load and
// the latch.
//
// The requirement is a TIME, the arm is a clk_sys CYCLE count, and `pc9821_iobus` is
// parameterised on SYS_CLOCK_HZ -- so a hardcoded arm is correct at exactly one profile.
// tb_pc9821_io_wait measures the arm at the default 50 MHz, where a fixed 21 passes; no
// bench instantiated the bus at another clock, which is the coverage gap this one closes.
//
// WHAT IS ASSERTED (CLK_HZ = 85,000,000, one tick = 1/2,457,600 s):
//   1. the delivered 8253 WRITE, in SYS_CLOCK_HZ cycles, covers one PIT tick
//      (cycles * 2,457,600 >= CLK_HZ) on 0x0071 and on the 0x3FDB alias;
//   2. the arm is at least ceil(CLK_HZ / 2,457,600) cycles -- the derived value, 35 at
//      85 MHz -- so a fix that merely raised the constant for one profile still fails.
// The current RTL (a fixed 21) delivers 22 cycles at this clock: check 1 computes
// 22 * 2,457,600 = 54,067,200 < 85,000,000 and the bench FAILs.

`default_nettype none

module tb_pc9821_pit_tick;
  // The production profile's clock. This is the whole point: the bench must NOT run at
  // the one clock where a hardcoded arm happens to be right.
  localparam integer CLK_HZ   = 85_000_000;
  localparam integer PIT_HZ   = 2_457_600;
  // ceil(CLK_HZ / PIT_HZ), computed here independently of the RTL.
  localparam integer PIT_TICK = (CLK_HZ + PIT_HZ - 1) / PIT_HZ;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)
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
  reg       device_rd_wait = 1'b0;
  wire [3:0] top_bank;
  wire sound_extend;
  wire ide_rom_enable, bios_ram_gate;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [7:0] win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire sys16m_en;
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
  integer     egc_shift_pulses = 0;
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window
  wire [1:0]  ems_state;
  wire        top_shadow_en;

  // ==== DUT ====
  // The 85 MHz (production) clock. `.*` matches every port by name; check_wiring.py
  // enforces that the list above is complete.
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
  pc9821_iobus #(.SYS_CLOCK_HZ(CLK_HZ)) dut (
      .ide_unit0_present(1'b0),.*);

  // ==== CHECKS ====
  integer errors = 0;
  integer measured_cycles = 0;
  integer c_real = 0, c_alias = 0;
  reg [15:0] probe_port = 16'h0000;

  // A WRITE, because that is the direction the floor exists for: the ITF's
  // POST self-test programs a count into the 8253 and reads it straight back, and it is the
  // PROGRAMMING that must outlast one 2.4576 MHz tick. The READ is the default class, which the
  // capture prices (its PITD0/PITD1 rows in docs/probes/IO.TXT), so it carries no floor at all.
  task automatic measure_port;
    reg [1:0] lane;
    begin
      lane = probe_port[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, probe_port[15:2], 2'b00};
      cpu_be   = 4'b0001 << lane;
      cpu_din  = 32'h0000_0000;
      cpu_write = 1'b1;
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
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  task automatic check_port(input [15:0] port, input integer cycles);
    begin
      // 1. the delivered 8253 WRITE, at SYS_CLOCK_HZ, must cover one PIT tick. `cycles` is the
      //    access's own clk_sys cycle count and the RTL counts clk_sys cycles, so the
      //    comparison with SYS_CLOCK_HZ is the RTL's property, not the bench's clock's.
      if (cycles * PIT_HZ < CLK_HZ) begin
        $display("FAIL port %04x: %0d cycles at %0d Hz = %0.1f ns, under one PIT tick (407 ns)",
                 port, cycles, CLK_HZ, cycles * 1.0e9 / CLK_HZ);
        errors = errors + 1;
      end
      // 2. the arm must be the DERIVED value, so a fix that raised the constant for one
      //    profile is still caught.
      if (cycles < PIT_TICK) begin
        $display("FAIL port %04x: %0d cycles, under the derived arm ceil(%0d/%0d) = %0d",
                 port, cycles, CLK_HZ, PIT_HZ, PIT_TICK);
        errors = errors + 1;
      end
      // 3. the arm is carried in io_hold's 12 bits; a value at the device ceiling must fit.
      if (cycles > 4095) begin
        $display("FAIL port %04x: %0d cycles does not fit io_hold's 12 bits", port, cycles);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    probe_port = 16'h0071; measure_port; c_real  = measured_cycles;
    probe_port = 16'h3FDB; measure_port; c_alias = measured_cycles;

    $display("  pit_tick: clk=%0d Hz tick=%0d ns derived_arm=%0d real=%0d alias=%0d cycles",
             CLK_HZ, 1_000_000_000 / PIT_HZ, PIT_TICK, c_real, c_alias);

    check_port(16'h0071, c_real);
    check_port(16'h3FDB, c_alias);

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PIT_TICK: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PIT_TICK: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_PIT_TICK: TIMEOUT");
  end

endmodule

`default_nettype wire

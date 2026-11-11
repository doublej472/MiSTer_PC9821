`timescale 1ns/1ps

// tb_pc9821_artic_atomic - a word read of the ARTIC counter never tears across a carry.

// ==== WHAT THIS PROVES ====
// TB_PC9821_ARTIC_ATOMIC: a word read of the ARTIC counter at 0x5E (the firmware delay() helper's `in ax,5Eh`, cnt[23:8]) returns ONE instant's value even when a 307.2 kHz tick carries out of bit 15 between its two byte lanes: swept across every phase of the tick around cnt = 0x00FFFF, the word is always 0x00FF or 0x0100 - never the torn 0x01FF that reads 65,536 ticks (213 ms) ahead and lets a `now - start >= n` delay loop exit early - matching both references' single snapshot per access (NP2kai io/artic.c artic_r16: `cnt = artic_getcnt(); if (port & 2) cnt >>= 8; return((UINT16)cnt);`; MAME src/mame/nec/pc9801.cpp timestamp_r returns `total_cycles() >> (8 * offset)` for the whole 16-bit access).
//
// FAIL-FIRST: before the fix the two lanes were read from the live counter in consecutive
// S_BYTE cycles, so a tick between them that carried into bit 16 gave 0x01FF.

module tb_pc9821_artic_atomic;
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
  // System port C bit 3, the beeper's mute, exported for the PC speaker path in
  reg [3:0]  bios_set = 4'd0;      // OSD BIOS set: 0 = PC-9821Xe10 (the default strap)
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  msw_hold = 1'b0;        // port 0x31 bit 4 at the measured machine's memory-switch init (0xF3)
  reg  text_lines_20 = 1'b0;   // port 0x31 bit 3 at the measured 25 lines (0xF3)
  reg  [1:0] floppy_mode = 2'd0;   // Auto (1M), 0x861E = 0xF7: the Floppy mode default
  wire [23:0] setup_cfg;       // the OSD configuration pc9821_cg is built from (unread here)
  // pc9821_system. This bench does not drive the beeper, but `dut (.*)` needs
  // every port named; tb_pc9821_beeper covers its behaviour.
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)
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
  wire [15:0] dbg_artic_hi;   // iobus exports the counter's high half for the watchdog
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

  // The software-DIP store is now enabled by default in the core, but the
  // override is kept to document that this bench exercises writes.
  // ==== DUT ====
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
  // THE WORD READ THE FIRMWARE MAKES, which no bench does.
  // BANK3@0x0B1B performs a 16-BIT read at 0x5E in the delay() helper. Every existing bench drives
  // `cpu_be = 1 << lane` - one byte - so the word path is untested. On x86 the byte lanes are fixed
  // (D[7:0] is byte 0 ... D[31:24] is byte 3), so an access at byte offset 2 of the dword carries
  // BE = 4'b1100 and its two bytes belong on D[31:16].
  integer werrors = 0;
  reg [15:0] wa1, wa2, wa3;
  task automatic read_word(input [15:0] port_, output [15:0] got);
    begin
      @(negedge clk);
      cpu_addr  = {16'd0, port_[15:2], 2'b00};
      cpu_be    = 4'b1100;
      cpu_write = 0;
      cpu_valid = 1;
      @(posedge clk);
      while (!cpu_ready) @(posedge clk);
      // z486's ACCEPT GAP: the CPU clears its external valid at the ready edge
      // (src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`),
      // so the request is withdrawn for the bubble cycle the I/O bus spends in S_HOLD and
      // may re-present on the next one. Holding cpu_valid across that bubble is a shape the
      // real CPU cannot produce, and the bus would serve the held request a second time
      // (pc9821_iobus's S_HOLD bubble is one unconditional cycle - its R6/R8 check says so).
      // The response byte is registered at S_REPLY, so it is still on cpu_dout here.
      @(negedge clk);
      got = cpu_dout[31:16];
      cpu_valid = 0; cpu_be = 0; cpu_write = 0;
      repeat (2) @(posedge clk);
    end
  endtask

  integer k, torn, seen_lo, seen_hi;
  reg [15:0] w;

  // ==== STIMULUS ====
  initial begin
    repeat (6) @(posedge clk);
    reset = 0;
    repeat (6) @(posedge clk);
    torn = 0; seen_lo = 0; seen_hi = 0;
    // Each read starts k cycles after a tick, with the counter set to 0x00FFFF right after
    // that tick, so the NEXT tick (the carry) lands at a known offset; k sweeps the read's
    // two lanes across it.
    for (k = 0; k < 800; k = k + 1) begin
      @(negedge clk);
      while (!dut.artic_tick) @(negedge clk);
      @(negedge clk);
      force dut.artic_cnt = 32'h0000_FFFF;
      @(negedge clk);
      release dut.artic_cnt;
      repeat (k % 400) @(negedge clk);
      read_word(16'h005E, w);
      if (w == 16'h00FF) seen_lo = seen_lo + 1;
      else if (w == 16'h0100) seen_hi = seen_hi + 1;
      else begin
        torn = torn + 1;
        if (torn < 4) $display("k=%0d: word 0x%04x is neither 0x00FF nor 0x0100", k, w);
      end
    end
    // ==== CHECKS ====
    $display("reads: 0x00FF=%0d 0x0100=%0d torn=%0d", seen_lo, seen_hi, torn);
    if (seen_lo == 0 || seen_hi == 0) werrors = werrors + 1;   // the sweep must straddle the tick
    if (torn != 0) werrors = werrors + 1;
    // ==== VERDICT ====
    if (werrors == 0) begin
      $display("TB_PC9821_ARTIC_ATOMIC: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ARTIC_ATOMIC: FAIL (%0d)", werrors);
  end

endmodule

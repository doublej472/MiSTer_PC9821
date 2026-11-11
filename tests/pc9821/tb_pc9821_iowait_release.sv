// tb_pc9821_iowait_release - the device_wr_wait re-check must be EVERY cycle once the
// bus-time hold has expired (the shortest-stall rule).

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// A back-pressured device write is released within 2 cycles of the device freeing its buffer - the S_IOWAIT re-check runs EVERY CYCLE once the bus-time class hold (io_hold) has expired, and the class hold itself is untouched (the strobe is never early). FAIL-FIRST: on the pre-fix iobus the 11-bit io_hold wraps 0 -> 2047 under a still-high device_wr_wait, so the write re-checks the wait only once per 2048 cycles and a 0xA46C write whose wait outlasts the hold lands ~2047 dead cycles after the device freed up. This bench sweeps the wait length around the wrap point (1/2/3/5 cycles, the expiry crossing, and 64/200 cycles past it) and floods 16 back-to-back writes against a device busy 7 cycles of every 8; both name the miss and fail by thousands of cycles on the pre-fix tree. Warrant: pc9821_iobus.sv's own S_DEVWAIT contract (the read wait is re-checked every cycle - the pattern F1 should follow) and NP2kai's direction (a write is applied the moment the device can take it); the bounds are the class's own FSM shape (IO_MIN_HOLD = 4), not a capture.
//
// TB_PC9821_IOWAIT_RELEASE: a back-pressured device write is released within 2 cycles
// of the device freeing its buffer - the S_IOWAIT re-check runs EVERY CYCLE once the
// bus-time class hold (io_hold, the real machine's I/O timing) has expired, and the
// class hold itself is untouched (the strobe is never early).
//
// FAIL-FIRST: on the pre-fix iobus, S_IOWAIT does `else io_hold <= io_hold - 1` with
// an 11-bit io_hold, so a write whose wait is still high when io_hold reaches 0
// WRAPS 0 -> 2047 and re-checks `device_wr_wait` only once per 2048 cycles.
// A 0xA46C write (the PCM86 write FIFO's back-pressure, the report's
// own example) whose wait outlasts the hold therefore lands ~2047 dead cycles after
// the device freed up - at 50 MHz up to 41 us of pure avoidable stall per
// back-pressured write, and a REP OUTSB stream to 0xA46C turns smooth back-pressure
// into a 2048-cycle heartbeat. This bench sweeps the wait length around the 0->2047
// wrap point and floods 16 back-to-back writes against a device that is busy 7 cycles
// of every 8; both fail on the pre-fix tree by thousands of cycles.
//
// Warrant: pc9821_iobus.sv's own S_DEVWAIT contract (the read wait is re-checked every
// cycle, the pattern the write side follows) and NP2kai's direction - it applies the write
// the moment the device can take it (WRQ/PCM86 buffer push is never delayed past the
// device's own accept). The cycle
// bounds are the class's own FSM shape (IO_MIN_HOLD = 4), not a capture.

module tb_pc9821_iowait_release;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ---- the I/O bus's CPU port (z486's external request) ----
  reg  [31:0] cpu_addr = 0, cpu_din = 0;
  reg  [3:0]  cpu_be = 0;
  reg         cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;
  reg  [7:0]  debug_status = 8'hA5;
  reg         cal_cdat = 0;
  wire [6:0]  cfg_ram_mib = 7'd0;
  wire        cfg_seed_en = 1'b0;
  reg         triple_fault_reset = 1'b0;
  reg  [3:0]  bios_set = 4'd0;
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  msw_hold = 1'b0;        // port 0x31 bit 4 at the measured machine's memory-switch init (0xF3)
  reg  text_lines_20 = 1'b0;   // port 0x31 bit 3 at the measured 25 lines (0xF3)
  reg  [1:0] floppy_mode = 2'd0;   // Auto (1M), 0x861E = 0xF7: the Floppy mode default
  wire [23:0] setup_cfg;       // the OSD configuration pc9821_cg is built from (unread here)

  // ---- the device fabric: the iobus's byte transaction ----
  wire        device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire  [7:0] device_io_din;
  wire  [7:0] device_io_dout = 8'hC3;   // the one-device read mux (no device built here)
  reg         device_rd_wait = 1'b0;
  reg         device_rd_hold = 1'b0;
  reg         device_wr_wait = 1'b0;   // THE SCRIPTED BACK-PRESSURE (pc9821_system's mux)
    // The GDC FF2 query state (a pc9821_iobus input since readbacks.md P6);
    // tied quiet here - this bench is not about the FF2 read-back.
    wire [10:0] gdc_ff2_state = 11'd0;

  // ---- iobus outputs this bench does not exercise (named because the DUT is (.*)) ----
  wire [3:0]  top_bank;
  wire        sound_extend;
  wire        ide_rom_enable, bios_ram_gate;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [7:0]  win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire        sys16m_en;
  wire        a20_enable, cpu_reset_req;
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire [7:0]  post_code;
  wire        post_write;
  // The core's native whole-L1 flush handshake (iobus's cache_flush_req /
  // cache_flush_busy / cache_flush_done), modelled here at ZERO LATENCY: this
  // bench does not measure flush timing, and an unmodelled cache_flush_done
  // would leave any flush-triggering write waiting in iobus's S_FLUSH forever.
  // The real request/done contract is tb_pc9821_cache_flush's subject.
  wire cache_flush_req;
  wire crt31k;   // 0x09A8 bit 0 (pc9821_iobus), named so .* binds it
  wire cache_flush_busy = 1'b0;
  wire cache_flush_done = cache_flush_req;
  wire [3:0]  dbg_gate;
  wire [7:0]  dbg_itf_stage;
  wire [15:0] dbg_artic_hi;
  wire [15:0] dbg_last_io_addr;
  wire  [7:0] dbg_last_io_data;
  wire        dbg_last_io_rd, dbg_last_io_wr;
  wire        dbg_last_io_stb;
  // The FDC's debug taps: named because the DUT is (.*), not exercised here
  // (tb_pc9821_fdc_dbg pins them).
  wire [7:0]  dbg_fdc_state;
  wire [7:0]  dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)
  wire [1:0]  ems_state;
  reg         egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  wire        top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window

  // ==== DUT ====
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

  // The OSD's I/O timing field (pc9821_iobus io_timing_xe10): Fast, the default table.
  wire io_timing_xe10 = 1'b0;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) bus (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

  // The shipped device decode so the 0xA46C write is a real device port (pcm_cs) exactly as
  // pc9821_system's fabric routes it: P5 made the ONE pc9821_device_select instance live inside
  // pc9821_iobus, so `.*` above binds these to it.
  wire ata_cs, pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;

  integer errors = 0;
  integer cycle = 0;
  always @(posedge clk) cycle = cycle + 1;

  // ==== CHECKS ====
  task automatic fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ---- the strobe monitor: every 0xA46C write the device sees, in order ----
  integer strobes = 0;
  reg [7:0] strobe_data [0:63];
  integer t_strobe = -1;
  always @(posedge clk) begin
    if (device_io_wr && (device_io_addr[15:0] == 16'hA46C)) begin
      t_strobe = cycle;
      if (strobes < 64) strobe_data[strobes] = device_io_din;
      strobes = strobes + 1;
    end
  end

  integer t_present, t_fall, waited, i;
  integer class_h;   // the measured no-wait latency: the class hold H

  // One 0xA46C byte write with the device's back-pressure scripted: device_wr_wait is
  // held `hold` cycles from the write's presentation and then drops. Records the
  // presentation/fall/strobe cycles.
  task automatic wr_waited_write(input [7:0] data, input integer hold);
    begin
      @(negedge clk);
      t_present = cycle;
      t_strobe = -1;
      device_wr_wait = 1'b1;
      cpu_addr = {16'd0, 16'hA46C};   // the port's BASE (0xA46C is lane-0 aligned); the lane rides in cpu_be
      cpu_be = 4'b0001;
      cpu_write = 1'b1;
      cpu_din = {24'd0, data};
      cpu_valid = 1'b1;
      repeat (hold) @(negedge clk);
      device_wr_wait = 1'b0;
      t_fall = cycle;
      waited = 0;
      while (!cpu_ready && waited < 6000) begin
        @(negedge clk);
        waited = waited + 1;
      end
      if (waited >= 6000) fail("a back-pressured write never completed");
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be = 4'b0;
      cpu_write = 1'b0;
      while (bus.state != 0) @(negedge clk);
      repeat (2) @(negedge clk);
    end
  endtask

  // The shortest-stall check: the device strobe lands within 2 cycles of whichever is
  // LATER - the class hold's expiry or the wait's fall. A counter that quantizes the
  // re-check (the 0 -> 2047 wrap) fails this by ~2047 cycles.
  task automatic check_release(input integer hold, input integer idx);
    integer release_bound;
    begin
      wr_waited_write(8'h40 + idx[7:0], hold);
      if (t_strobe < 0) fail("no device strobe was seen for a write");
      else begin
        if ((t_strobe - t_present) < 3)
          fail("the write landed BEFORE its bus-time class hold expired");
        release_bound = ((t_fall - t_present) > class_h) ? (t_fall - t_present) : class_h;
        if ((t_strobe - t_present) > (release_bound + 2)) begin
          $display("FAIL: the strobe landed %0d cycles after presentation (bound %0d) - the wr_wait re-check is quantized (hold=%0d)",
                   t_strobe - t_present, release_bound + 2, hold);
          errors = errors + 1;
        end
      end
    end
  endtask

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_IOWAIT_RELEASE: watchdog expired");
  end

  // The flood's scripted device: busy 7 cycles of every 8.
  reg flood_active = 0;
  always @(negedge clk)
    if (flood_active) device_wr_wait = (cycle[2:0] != 3'd7);

  integer flood_start, f0;
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // The class hold H, measured with no back-pressure at all (the bus-time hold the
    // fix must NOT move).
    wr_waited_write(8'h11, 0);
    class_h = t_strobe - t_present;
    if (class_h < 3) fail("the no-wait write did not take its class hold");
    $display("NOTE iowait_release: class hold H = %0d clk_sys for 0xA46C", class_h);

    // ---- the sweep around the 0 -> 2047 wrap point ----
    // Short waits (the device frees during the hold: release at the hold's expiry,
    // never early) and long waits (io_hold has LONG expired: release within 2 cycles
    // of the fall - the pre-fix tree wraps to 2047 here).
    check_release(1, 0);
    check_release(2, 1);
    check_release(3, 2);
    check_release(5, 3);
    check_release(class_h + 1, 4);      // the wait crosses the expiry
    check_release(class_h + 64, 5);     // io_hold long expired at the fall: the wrap case
    check_release(200, 6);              // ...and far past it

    // ---- the flood: 16 back-to-back writes against a device busy 7 of every 8 ----
    // Every write must land, in order, and the total must be the device's own busy
    // time plus the class holds - not 2048 cycles per re-check miss.
    strobes = 0;
    flood_active = 1;
    flood_start = cycle;
    for (f0 = 0; f0 < 16; f0 = f0 + 1) begin : one_write
      integer local_start, local_fall, w2;
      @(negedge clk);
      local_start = cycle;
      cpu_addr = {16'd0, 16'hA46C};
      cpu_be = 4'b0001;
      cpu_write = 1'b1;
      cpu_din = {24'd0, 8'h80 + f0[7:0]};
      cpu_valid = 1'b1;
      w2 = 0;
      while (!cpu_ready && w2 < 6000) begin @(negedge clk); w2 = w2 + 1; end
      if (w2 >= 6000) fail("a flood write never completed");
      @(negedge clk);
      cpu_valid = 1'b0; cpu_be = 4'b0; cpu_write = 1'b0;
      while (bus.state != 0) @(negedge clk);
    end
    flood_active = 0;
    device_wr_wait = 1'b0;
    if (strobes != 16) fail("the flood dropped a write (the device did not see 16 strobes)");
    for (f0 = 0; f0 < 16; f0 = f0 + 1)
      if ((strobes > f0) && (strobe_data[f0] !== (8'h80 + f0[7:0])))
        fail("the flood's writes landed out of order or with the wrong data");
    // 16 writes x (class hold + at most 8 busy) + slack. The pre-fix wrap pays ~2048
    // per write and misses this by two orders of magnitude.
    if ((cycle - flood_start) > (16 * (class_h + 8) + 64)) begin
      $display("FAIL: the flood took %0d cycles (bound %0d) - the wr_wait re-check is quantized",
               cycle - flood_start, 16 * (class_h + 8) + 64);
      errors = errors + 1;
    end
    $display("NOTE iowait_release: flood 16 writes in %0d clk_sys (bound %0d)",
             cycle - flood_start, 16 * (class_h + 8) + 64);

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_IOWAIT_RELEASE: FAIL (%0d errors)", errors);
    $display("TB_PC9821_IOWAIT_RELEASE: PASS");
    $finish;
  end
endmodule

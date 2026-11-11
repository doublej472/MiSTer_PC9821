`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_XE10_ABSENT_PORTS: on the Xe10 build (pc9821_iobus at its default parameters) three ports answer as the machine and the references do: 0x043B reads 0xFB out of reset with the 15-16 MiB system space enabled (bit 2 clear: NP2kai's zeroed necio latch, QEMU's power-up sys16m = 1 reading 0x00, on the machine's measured 0xFB base byte), the eight PC-9801-118 game-port addresses 0x1480-0x1487 read open bus 0xFF and reach no device in either direction (the Xe10 has no -118; NP2kai attaches the port only with that board), and 0x0EE0 reads 0xFF (PORTS.TXT 0EE0=FF) even after a POST-code write, the debug-status read-back existing only with DBG_STATUS_PORT.
//
// Expected values: docs/probes/PORTS.TXT (0EE0=FF, the 0x043B base byte 0xFB), NP2kai io/necio.c
// and cbus/board118.c, qemu-pc98 hw/i386/pc98-mem.c (mem_sys16m_read, the power-up sys16m = 1).
//
// FAIL-FIRST: before the change 0x043B read 0xFF out of reset with the system space disabled,
// 0x1480 answered the -118 model's 0xF0 through the device bus, and 0x0EE0 read debug_status.

module tb_pc9821_xe10_absent_ports;
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
  // 0x043F's 0x8 nibble: the writable shadow over the 0xF8000-0xFFFFF window.
  wire top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  // The FDC's level interrupt (slave PIC IRQ11). pc9821_iobus carries the
  // port and the `.*` DUT instantiation matches by name, so it must
  // be declared here; this bench does not exercise the floppy path.
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window
  wire a20_enable, cpu_reset_req;
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire [7:0] post_code;
  wire post_write;
  // The core's native whole-L1 flush handshake (iobus's cache_flush_req /
  // cache_flush_busy / cache_flush_done), modelled at ZERO latency: this bench
  // counts flush REQUESTS (the trigger contract is tb_pc9821_cache_flush's
  // subject), and an unmodelled done would leave a flush-triggering write
  // waiting in iobus's S_FLUSH forever. The log below counts the pulses.
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
  // strap cell): 0 = no seed for the bus-behaviour sections below, which is what those want.
  // The memory-switch strap-cell section near the end DRIVES both (the cell is only seeded
  // when cfg_seed_en is set), so they are regs with the no-seed power-up values.
  reg [6:0] cfg_ram_mib = 7'd0;
  reg       cfg_seed_en = 1'b0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one cycle (at the reset ASSERTION)
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

  wire [1:0] d8_bank;   // 0x063C bits 1-0, the 0xD8000 window's ROM bank
  // P5: the device-bus chip selects are pc9821_iobus outputs now (its own one decode).
  // This bench drives no device select of its own, so they are named here for the wildcard
  // instantiation and left unused.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  // The OSD's I/O timing field (pc9821_iobus io_timing_xe10): Fast, the default table.
  wire io_timing_xe10 = 1'b0;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

  // The CPU-reset gate, wired exactly as pc9821_system wires it (`.cpu_reset_req(cpu_reset_req)`,
  // clk_sys/reset, cpu_run from the pack, mem_busy from the SDRAM controller). It is here because
  // the DIP seed's hold is only a hold THROUGH this module: the seed asserts cpu_reset_req, and
  // this is the module that turns that request into the CPU's reset_n. `mem_busy` is 0 (the
  // production value once JEDEC init has finished) so the only hold is the request itself.
  reg  gate_cpu_run = 1'b1, gate_hps_apply_reset = 1'b0, gate_mem_busy = 1'b0;
  wire gate_cpu_reset_n;
  pc9821_cpu_reset_gate u_reset_gate (
    .clk(clk), .reset(reset), .cpu_run(gate_cpu_run), .hps_apply_reset(gate_hps_apply_reset),
    .cpu_reset_req(cpu_reset_req), .mem_busy(gate_mem_busy), .cpu_reset_n(gate_cpu_reset_n)
  );
  // Sticky violation flag for the seed section below: the CPU's reset_n must never be high in a
  // cycle the 24-byte walk is still writing. ARMED only by that section, because a mid-run OSD
  // action legitimately overlaps the gate's two-flop release synchroniser (the CPU is already
  // running there); the machine-reset case has no such window, because `release_ok` is low for
  // the whole reset window and clears the synchroniser on the assertion itself.
  reg gate_high_while_seeding = 1'b0;
  reg seed_monitor_armed = 1'b0;
  always @(posedge clk)
    if (seed_monitor_armed && dut.sdip_seq_active && gate_cpu_reset_n) gate_high_while_seeding <= 1'b1;

  integer errors = 0;
  integer flush_pulses = 0;
  integer gdc_writes = 0;
  integer post_writes = 0;
  integer reset_pulses = 0;
  reg [7:0] value;
  // ==== STIMULUS ====
  task automatic fail(input [8*80-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask
  reg [7:0] last_post_code;
  reg [7:0] last_gdc_addr, last_gdc_data;
  // The software-DIP store a cold core powers up with, captured before the
  // guest writes anything. "Reset DIPs" must reproduce exactly this state, so
  // the bench asserts the contract (the action restores the power-up image)
  // without keeping a second copy of the image.
  reg [7:0] sdip_powerup_shadow [0:23];
  // Device-bus read observation for the sound-decode checks below (see the
  // CHECKS section).
  reg        saw_dev_rd = 1'b0;
  reg [15:0] last_dev_rd_addr = 16'd0;
  always @(posedge clk) begin
    if (device_io_rd) begin
      saw_dev_rd <= 1'b1;
      last_dev_rd_addr <= device_io_addr;
    end
  end
  always @(posedge clk) begin
    if (post_write) begin
      post_writes = post_writes + 1;
      last_post_code = post_code;
    end
    if (cpu_reset_req) reset_pulses = reset_pulses + 1;
    if (egc_shift_we) egc_shift_pulses = egc_shift_pulses + 1;
    if (device_io_wr) begin
      gdc_writes = gdc_writes + 1;
      last_gdc_addr = device_io_addr[7:0];
      last_gdc_data = device_io_din;
    end
    if (cache_flush_req) flush_pulses = flush_pulses + 1;
  end

  // A flush trigger owes exactly ONE whole-L1 flush request now: the old
  // per-encoding snoop sweeps are retired with the pc9821_cache_flush
  // sequencer (tb_pc9821_cache_flush pins the trigger contract end to end),
  // so the log above counts requests and each trigger must emit exactly one.
  task automatic clear_flush_log;
    begin
      @(negedge clk);
      flush_pulses = 0;
    end
  endtask

  task automatic check_flush_once(input string description);
    begin
      if (flush_pulses != 1) begin
        $display("FAIL %0s count=%0d, want exactly 1 flush request", description,
                 flush_pulses);
        errors = errors + 1;
      end
    end
  endtask

  task automatic read_raw(input [15:0] portnum, output [7:0] data);
    reg [1:0] lane;
    begin
      lane = portnum[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_write = 0;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      #1;
      data = cpu_dout[{lane, 3'b000} +: 8];
      @(negedge clk);
      cpu_valid = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  task automatic write_byte(input [15:0] portnum, input [7:0] data);
    reg [1:0] lane;
    begin
      lane = portnum[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_din = {24'd0, data} << (lane * 8);
      cpu_write = 1;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  // A 16-bit port write. The authentic EGC sequences are all `out dx,ax`
  // (master.lib egc.asm, ReC98 egc.hpp), so the engine only ever sees this form
  // from the firmware and the games; the byte form is covered beside it.
  task automatic write_word(input [15:0] portnum, input [15:0] data);
    begin
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0011 << portnum[1:0];
      cpu_din = {16'd0, data} << (portnum[1:0] * 8);
      cpu_write = 1;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  task automatic read_byte(input [15:0] portnum, input [7:0] expected);
    reg [1:0] lane;
    begin
      lane = portnum[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_write = 0;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      #1;
      if (!cpu_resp_valid || cpu_dout[{lane, 3'b000} +: 8] !== expected) begin
        $display("FAIL read %04x got=%08x resp=%b", portnum, cpu_dout, cpu_resp_valid);
        errors = errors + 1;
      end
      @(negedge clk);
      cpu_valid = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  // A 16-bit port read (the `in ax,dx` shape): the same lane walk as read_byte
  // over both byte lanes of the word.
  task automatic read_word(input [15:0] portnum, input [15:0] expected);
    begin
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0011 << portnum[1:0];
      cpu_write = 0;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      #1;
      if (!cpu_resp_valid ||
          cpu_dout[{portnum[1:0], 3'b000} +: 16] !== expected) begin
        $display("FAIL read16 %04x got=%08x resp=%b", portnum, cpu_dout,
                 cpu_resp_valid);
        errors = errors + 1;
      end
      @(negedge clk);
      cpu_valid = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  // One access's duration, in clk cycles, from cpu_valid to cpu_ready. See the
  // IO_ACCESS_CYCLES comment in pc9821_iobus.sv: the authentic ITF's POST
  // measures this property twice (the port/counter walk at BANK4@0x038F needs
  // an access to outlast one 2.4576 MHz PIT tick, and the stage-0x24 IRQ0 race
  // at BANK4@0x0F84C0 needs ten `out 0x02 / out 0x5F` iterations to outlast 26
  // of them), and the 0x5F delay port the firmware's own loops use is this
  // same path. The bug this pins was invisible to an end-state check: a timing
  // test that passes by luck on one tree and halts POST on the next.
  localparam integer PIT_TICK_CYCLES = (50_000_000 + 2_457_600 - 1) / 2_457_600;
  task automatic measure_access_cycles(input [15:0] portnum, input is_write,
                                       output integer cycles);
    reg [1:0] lane;
    begin
      lane = portnum[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_din = 32'd0;
      cpu_write = is_write;
      cpu_valid = 1;
      cycles = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        cycles = cycles + 1;
      end
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  // ==== CHECKS ====
  integer    dev_rd_n = 0, dev_wr_n = 0;
  reg        saw_gameport_cs = 1'b0;
  always @(posedge clk) begin
    if (device_io_rd) dev_rd_n <= dev_rd_n + 1;
    if (device_io_wr) dev_wr_n <= dev_wr_n + 1;
    if (gameport_cs && (device_io_rd || device_io_wr)) saw_gameport_cs <= 1'b1;
  end

  task automatic chk(input bit cond, input string msg);
    begin
      if (!cond) begin
        $display("FAIL %0s", msg);
        errors = errors + 1;
      end
    end
  endtask

  integer k;
  integer n0;

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // ---- 0x043B out of reset: bit 2 clear, the system space enabled ---------------------
    // NP2kai's latch is zero until written (io/necio.c necio_i043b returns necio.port043b);
    // QEMU powers up `s->sys16m = 1` and reads `s->sys16m ? 0x00 : 0x04`. On the machine's
    // measured base byte (0xFB with bit 2 clear, PORTS.TXT) that is 0xFB.
    chk(sys16m_en === 1'b1, "0x043B: the 15-16 MiB system space is not enabled out of reset");
    read_byte(16'h043B, 8'hFB);

    // ---- 0x1480-0x1487: no PC-9801-118 on the Xe10 ---------------------------------------
    // NP2kai attaches the game port only with a -118 board (cbus/board118.c
    // `iocore_attachinp(0x1480+i, gameport_i1480);`); the Xe10's -86-class sound has none, so
    // the eight ports are unattached and read 0xFF, and no device answers them.
    n0 = dev_rd_n;
    for (k = 16'h1480; k <= 16'h1487; k = k + 1) read_byte(k[15:0], 8'hFF);
    chk(dev_rd_n == n0, "a 0x1480-0x1487 read reached the device bus");
    n0 = dev_wr_n;
    write_byte(16'h1480, 8'h00);
    chk(dev_wr_n == n0, "a 0x1480 write reached the device bus");
    chk(!saw_gameport_cs, "gameport_cs asserted on the Xe10 build");

    // ---- 0x0EE0: open bus on the machine (PORTS.TXT `0EE0=FF`) --------------------------
    read_byte(16'h0EE0, 8'hFF);
    write_byte(16'h0EE0, 8'h5A);   // the POST-code write still lands (post_write)...
    read_byte(16'h0EE0, 8'hFF);    // ...but nothing reads back

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_XE10_ABSENT_PORTS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_XE10_ABSENT_PORTS: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_XE10_ABSENT_PORTS: TIMEOUT");
  end

endmodule

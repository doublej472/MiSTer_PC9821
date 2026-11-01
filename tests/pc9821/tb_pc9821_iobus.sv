`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The I/O bus: the A20 gate (masked at power-on, and moved only by 0xF0/0xF2/0xF6 -- the system PPI's port C is a plain latch and not a second control), the 0x534 soft reset (only bit 0 requests one, and it masks A20), the ARTIC timestamp counter, the flush-pulse log over a full sweep, POST writes, and open-bus behaviour. It also decodes 0x043F's 0x2 nibble into the machine's three measured EMS-window states: 0x20 the identity (the ordinary VRAM planes, which the BIOS's own mode-set stub writes and the ITF writes back after its test), 0x22 the 64 KiB RAM page, and anything else unmapped. Further cases pin: the FDC 1.44M/RPM register 0x04BE is decoded (rpm[reg144[6:5]] | 0xFE, NP2kai io/fdc.c:1117-1134) and stays out of the unmapped telemetry, and the 0xF2 read tracks the A20 state (0xFE released / 0xFF masked, NP2kai cpuio_if2) instead of the old constant 0xFE. The word-read cases pin: a 16-bit read at 0x7C answers 0x00:the-byte (NP2kai's TERM_MINUS zero-extends the word read and never fetches 0x7D, io/iocore16.tbl:23-26 / io/iocore.c:781-782), while 0x7E is NOT in minus_term and keeps the default byte split with an open-bus 0xFF high byte (io/iocore.c:789-792) and byte reads at 0x7C/0x7D are untouched -- FAIL-FIRST on the 0x7C word read alone (0xFFC3 where NP2kai answers 0x00C3). The machine-reset seed: the software-DIP store is walked back to its power-up image by the machine-reset strobe (the same `reset || !cpu_run` this module's other configuration latches re-sample), instead of surviving as the previous run left it - otherwise a reset brings the ITF's SET THE SOFTWARE DIP-SWITCH message back - and the CPU is held in its reset class for the whole 24-byte walk (`cpu_reset_req`, turned into the CPU's reset_n by a real pc9821_cpu_reset_gate instance in this bench), so no read can land on a half-seeded bank. The walk starts at the reset ASSERTION, so a window longer than the walk - every real reset: a reload's seconds, an OSD reset's SDRAM calibration - finishes inside it and asks for no hold at all, which is what keeps the boot golden exact, and a reset pulse SHORTER than the walk is checked from the other side (the hold is requested and the walk is observable with the store still partly corrupt, so that hold check is not vacuous). FAIL-FIRST: before the change the corrupt byte survives a platform reset. And the memory-switch strap cell 0x79 - the machine's stored extended-memory size in MiB - answers the OSD RAM size as a read fallback (the recorded derivation: total MiB minus 2, the inverse of the MEASURED 0x1E at 32 MiB), 0x0E at the 16 MiB default and 0x1E at 32 MiB, until the guest writes its own byte and wins for good; FAIL-FIRST, because the pre-fix threshold answered 0x00 at every guest below 18 MiB.
//
// The I/O bus: the A20 gate (masked at power-on, and moved only by 0xF0/0xF2/0xF6 -- the system PPI's port C is a plain latch and not a second control), the 0x534 soft reset (only bit 0 requests one, and it masks A20), the ARTIC timestamp counter, the flush-pulse log over a full sweep, POST writes, and open-bus behaviour. It also decodes 0x043F's 0x2 nibble into the machine's three measured EMS-window states: 0x20 the identity (the ordinary VRAM planes, which the BIOS's own mode-set stub writes and the ITF writes back after its test), 0x22 the 64 KiB RAM page, and anything else unmapped. And it pins 0x043B bit 2 as the INVERTED request for the 15-16 MiB system-space hole - set asks for RAM there, clear enables the hole, reset leaves the hole off - which is the bit the ITF's stage-0x25 memory test writes 0x04 to. It also pins the word-read assembly at the GRCG's ports: a 16-bit read at 0x7C answers {0x00, the 0x7C byte} - NP2kai's TERM_MINUS zero-extends the word read and never fetches port 0x7D (io/iocore16.tbl:23-26 lists 0x7c, io/iocore.c:781-782) - while 0x7E is NOT in that table and keeps the default byte split with the 0xFF open-bus high byte (io/iocore.c:789-792), and byte reads at 0x7C/0x7D are untouched.


module tb_pc9821_iobus;
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
  reg  fdd_dip_fixed = 1'b1;   // the 0x00BE bit-2 FDD-mode switch at the measured unit's Fixed
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

  wire [1:0] d8_bank;   // 0x063C bits 1-0, the 0xD8000 window's ROM bank
  // P5: the device-bus chip selects are pc9821_iobus outputs now (its own one decode).
  // This bench drives no device select of its own, so they are named here for the wildcard
  // instantiation and left unused.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0),.*);

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

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    // A20 comes up MASKED: the PC-98 gate clears bit 20 and power-on leaves it
    // closed. That is the state the authentic ITF's own ADDRESS 20 LINE check at
    // BANK4@0xF8358 relies on -- it writes 1 MiB and requires the read at
    // physical 0 to match, and no 0xF2/0xF6 write precedes it anywhere in the
    // ROM set. Both references reset the gate masked (NP2kai
    // i386c/ia32/interface.c:87, QEMU target/i386/cpu.c:9421).
    if (a20_enable !== 1'b0) fail("A20 was not masked out of reset");
    // 0x063C resets to the IDE bank: the Xe10 reads FC (docs/probes/D8BANK-XE10.TXT), and
    // the authentic ITF copies the IDE option ROM out of 0xD8000 before it writes the port.
    if (d8_bank !== 2'd0) fail("0x063C does not reset to the IDE bank (bits 1-0 = 00)");
    for (integer k = 0; k < 24; k = k + 1) sdip_powerup_shadow[k] = dut.sdip[k];

    // ---- the bus time one I/O access occupies ---------------------------
    // The machine's I/O bus is slow and the authentic firmware measures it: the
    // 8253 ports must let an access outlast one 2.4576 MHz PIT tick (20.34 cycles
    // at 50 MHz), or the ITF's counter walk at the end of stage 0x1F reads back
    // the value it wrote and halts POST with "TIMER ERROR" (BANK4@0x01E1E7). The
    // floor is asserted on that port alone; every other class is the FSM minimum
    //, below the machine's measured access.
    begin : io_access_time
      // One access per class after the class table reduced every class but the two floors
      // to the FSM minimum: the 0x0071 8253 must still cover one PIT tick,
      // 0x5F is still the longest, and the GDC/IDE/default classes all measure the
      // same 4-cycle floor (+1 presenting cycle, `tb_pc9821_io_wait`).
      localparam integer IO_MIN_HOLD = 4;
      localparam integer IO_MIN_MEASURED = IO_MIN_HOLD + 1;
      integer pit_cycles, wait_cycles, gdc1_cycles, gdc2_cycles, ide_cycles;
      measure_access_cycles(16'h0071, 1'b1, pit_cycles);   // the 8253 (the ITF floor)
      measure_access_cycles(16'h005F, 1'b1, wait_cycles);  // the I/O-wait port
      measure_access_cycles(16'h0060, 1'b0, gdc1_cycles);  // text GDC
      measure_access_cycles(16'h00A0, 1'b0, gdc2_cycles);  // graphics GDC
      measure_access_cycles(16'h0640, 1'b0, ide_cycles);   // IDE PIO data port
      if (pit_cycles < PIT_TICK_CYCLES) begin
        $display("FAIL a 8253 access took %0d cycles, under one PIT tick (%0d): the ITF's counter walk reads back its own value",
                 pit_cycles, PIT_TICK_CYCLES);
        errors = errors + 1;
      end
      // THE SURVIVING RANKING: wait 30 > 8253 21 > the FSM floor. The machine's
      // measured ladder below the 8253 is deliberately not matched, so the GDC, IDE and
      // default classes are all the same FSM floor now. tb_pc9821_io_wait states the
      // same contract from the 0x0043 reference class; this one keeps the 0x0071.
      if (!(wait_cycles > pit_cycles && pit_cycles > gdc2_cycles)) begin
        $display("FAIL the surviving floor ranking is broken: wait=%0d pit=%0d gdc2=%0d",
                 wait_cycles, pit_cycles, gdc2_cycles);
        errors = errors + 1;
      end
      // The GDC classes and the IDE data port all take the FSM floor: each
      // measured count is the class value plus the presenting cycle (`tb_pc9821_io_wait`).
      if (!(gdc1_cycles == IO_MIN_MEASURED && gdc2_cycles == IO_MIN_MEASURED &&
            ide_cycles == IO_MIN_MEASURED)) begin
        $display("FAIL a non-floor class is not the %0d-cycle FSM floor: gdc1=%0d gdc2=%0d ide=%0d",
                 IO_MIN_MEASURED, gdc1_cycles, gdc2_cycles, ide_cycles);
        errors = errors + 1;
      end
      $display("IO ACCESS CYCLES pit=%0d wait=%0d gdc1=%0d gdc2=%0d ide=%0d (8253 floor=%0d, one PIT tick; every non-floor class = the 4-cycle FSM floor)",
               pit_cycles, wait_cycles, gdc1_cycles, gdc2_cycles, ide_cycles, PIT_TICK_CYCLES);
      // The measurement writes a device port, and `gdc_writes` counts every
      // device write; the POST/GDC delegation checks below expect to be the
      // first such writes in the bench, so the count starts from here.
      gdc_writes = 0;
    end

    read_byte(16'h0EE0, 8'hA5);   // debug status, on the core's own port
    // The memory-switch register file: 0x530 is the address latch, 0x531 the
    // data byte it selects. The authentic ITF's protected-mode block writes an
    // address to 0x530 and data to 0x531 (BANK4@0x9222/0x9226, the pattern loop
    // the 0x9211 routine runs) and then reads the data back out (BANK4@0x8DE8
    // `out dx,al; inc dx; in al,dx`), so the pair is a LATCH: the read-back
    // returns what the firmware wrote. Two indices, to prove it is addressed and
    // not a single byte; the address latch itself must also read back.
    write_byte(16'h0530, 8'h80);
    write_byte(16'h0531, 8'h0F);
    write_byte(16'h0530, 8'h01);
    write_byte(16'h0531, 8'h7E);
    read_byte(16'h0530, 8'h01);   // the address latch holds the last address
    read_byte(16'h0531, 8'h7E);   // ...and returns that index's data
    write_byte(16'h0530, 8'h80);
    read_byte(16'h0531, 8'h0F);   // the first index is still there
    // Unwritten indices read 0x00, the power-up content (the machine's resting
    // value on the pair is unmeasured;
    write_byte(16'h0530, 8'h40);
    read_byte(16'h0531, 8'h00);
    // ---- THE ONE SEEDED CELL: 0x79, the machine's stored extended-memory size in MiB ----
    // The only memory-switch cell with a machine measurement (the /MEMSW probe left the pair
    // holding address 0x79 with data 0x1E = 30 on the 32 MiB PC-9821Xe10, the extended size
    // that machine's own POST prints: +30720KB). It answers the OSD RAM size as a READ
    // fallback until the guest writes its own byte, and the fallback is the
    // total-minus-2 inverse of that measurement: 14 (0x0E) at the 16 MiB default, 0x1E at
    // 32 MiB. The expected values are the reference's, not this RTL's: 0x1E is machine-
    // measured and 0x0E is the recorded derivation (the firmware's own 32 total - 1 MiB
    // of base - 0.625 MiB of low memory reads 14 at 16 MiB too). FAIL-FIRST: the pre-fix
    // threshold answered 0x00 at every guest below 18 MiB - a size the OSD cannot even
    // select - so the 16 MiB default read 0 MiB extended where the machine's rule says 14.
    // THE STRAP IS A MEMORY-SWITCH CELL, SO ITS OSD SOURCE IS SAMPLED AT MACHINE RESET
    // ONLY: a mid-run size change moves nothing.
    cfg_seed_en = 1'b1;
    cfg_ram_mib = 7'd16;                       // the OSD default: a 16 MiB guest
    reset = 1; repeat (2) @(posedge clk); reset = 0;    // the reset-time latch samples it
    repeat (2) @(posedge clk);
    write_byte(16'h0530, 8'h79);
    read_byte(16'h0531, 8'h0E);                // 14 = 16 total - 2
    // FAIL-FIRST for the latch: on the live-apply wiring the mid-run flip below reads 0x1E.
    cfg_ram_mib = 7'd32;
    repeat (2) @(posedge clk);
    read_byte(16'h0531, 8'h0E);                // unchanged: the value applies at reset only
    reset = 1; repeat (2) @(posedge clk); reset = 0;
    repeat (2) @(posedge clk);
    write_byte(16'h0530, 8'h79);
    read_byte(16'h0531, 8'h1E);                // the MEASURED machine byte, at 32 MiB
    // The guest's own byte wins for good from here, exactly as the battery-backed cell
    // stops being a strap once the machine's own SETUP has written it.
    write_byte(16'h0531, 8'h55);
    read_byte(16'h0531, 8'h55);
    cfg_ram_mib = 7'd16;
    reset = 1; repeat (2) @(posedge clk); reset = 0;
    repeat (2) @(posedge clk);
    write_byte(16'h0530, 8'h79);
    read_byte(16'h0531, 8'h55);                // ... and no reset or size change brings the strap back
    cfg_seed_en = 1'b0;
    cfg_ram_mib = 7'd0;
    // Fixed part 0xF8: measured on a PC-9821Xe10 (bit 3 is a strap).
    read_byte(16'h0033, 8'hF8);
    // 0x33 bit 0 is the calendar's serial data output, not a constant: it used
    // to read as an even second no matter what the chip was sending.
    cal_cdat = 1'b1;
    read_byte(16'h0033, 8'hF9);
    cal_cdat = 1'b0;
    // Measured reset value (probes/PORTS.TXT, 2026-09-12): 0xB8, not 0xF9.
    read_byte(16'h0035, 8'hB8);
    write_byte(16'h0035, 8'hA5);
    read_byte(16'h0035, 8'hA5);
    // Port 37 uses an 8255-style bit index in bits 3:1 and set/reset in bit 0.
    write_byte(16'h0037, 8'h04); // clear bit 2
    read_byte(16'h0035, 8'hA1);
    write_byte(16'h0037, 8'h05); // set bit 2
    read_byte(16'h0035, 8'hA5);
    write_byte(16'h0037, 8'hF0); // high-nibble commands are ignored
    read_byte(16'h0035, 8'hA5);
    // The POST/debug port is the core's own, and deliberately not 0x1F:
    // that address is the uPD71071 DMA bank register on a real PC-98.
    write_byte(16'h0EE0, 8'h5A);
    if (post_writes != 1 || last_post_code != 8'h5A ||
        unmapped_writes != 0) begin
      $display("FAIL POST capture count=%0d code=%02x", post_writes,
               last_post_code);
      errors = errors + 1;
    end
    read_byte(16'h0060, 8'hC3);
    write_byte(16'h0062, 8'h0D);
    if (gdc_writes != 1 || last_gdc_addr != 8'h62 ||
        last_gdc_data != 8'h0D || unmapped_writes != 0) begin
      $display("FAIL GDC delegation count=%0d addr=%02x data=%02x",
               gdc_writes, last_gdc_addr, last_gdc_data);
      errors = errors + 1;
    end

    // NP2kai value 12 selects top BIOS. Completion must be delayed until the
    // complete invalidation has been emitted: the 32 KiB window at
    // 0xF8000-0xFFFFF AND the same storage's other encodings -- its
    // 0xFF8000-0xFFFFFF sys16m mirror, its win0=0x0E overlay at
    // 0x98000-0x9FFFF (aliases.md A2) and the fw_high alias at
    // 0xFFFF8000-0xFFFFFFFF -- 8192 lines in all.
    clear_flush_log();
    write_byte(16'h043D, 8'h12);
    if (top_bank != 4'd9) begin
      $display("FAIL top BIOS selection top_bank=%0d", top_bank);
      errors = errors + 1;
    end
    check_flush_once("top BIOS flush (one whole-L1 request)");

    // Reselecting the current state is not a mapping change, so it must not
    // pay for another 32 KiB invalidation (QEMU guards the same way).
    clear_flush_log();
    write_byte(16'h043D, 8'h12);
    if (flush_pulses != 0) begin
      $display("FAIL redundant 0x043D write emitted %0d flush request(s)", flush_pulses);
      errors = errors + 1;
    end

    // 0x043F: direct bank selection, 0xE0 | (bank << 1). This is what makes
    // the eight 32 KiB ROM banks reachable at all.
    clear_flush_log();
    write_byte(16'h043F, 8'hE6);
    if (top_bank != 4'd3) begin
      $display("FAIL 0x043F bank select top_bank=%0d", top_bank);
      errors = errors + 1;
    end
    check_flush_once("bank select flush (one whole-L1 request)");

    // The 0x20 nibble is the EMS page window, which is unrelated to the ROM
    // window: it must leave the window alone -- but it moves the 64 KiB window
    // at 0xB0000-0xBFFFF between three storages (planes / EMS page / open), so
    // it sweeps ITS encodings (aliases.md A4): 0xB0000-0xBFFFF, its
    // 0xFB0000-0xFBFFFF mirror and its win0=0x0A overlay at 0x90000-0x9FFFF.
    // Its low
    // nibble picks one of the machine's THREE measured states
    // (probes/EMS.TXT): 0x20 = the identity, i.e. the ordinary VRAM
    // planes; 0x22 = the 64 KiB RAM page the ITF fills and verifies
    // (BANK4@0xF82C7-0xF8317); anything else = unmapped (0x24 reads 0xFFFF).
    // The 0x20 state matters most: the BIOS's own mode-set stub writes 0x20|strap
    // (BANK7@0xD2A) and the ITF writes 0x20 back after its test
    // (BANK4@0xF834D), so treating it as the window would take the GVRAM planes
    // at 0xB0000-0xBFFFF away from every later mode set.
    clear_flush_log();
    write_byte(16'h043F, 8'h24);
    if (top_bank != 4'd3 || ems_state != 2'd2) begin
      $display("FAIL EMS write touched the ROM window top_bank=%0d ems_state=%0d",
               top_bank, ems_state);
      errors = errors + 1;
    end
    check_flush_once("EMS state change flush (one whole-L1 request)");
    write_byte(16'h043F, 8'h22);
    if (ems_state != 2'd1) begin
      $display("FAIL 0x043F=0x22 ems_state=%0d, want 1 (the 64 KiB RAM page)", ems_state);
      errors = errors + 1;
    end
    write_byte(16'h043F, 8'h20);
    if (ems_state != 2'd0) begin
      $display("FAIL 0x043F=0x20 ems_state=%0d, want 0 (the identity: the BIOS writes it)", ems_state);
      errors = errors + 1;
    end

    // 0x043F = 0xA0 is the 486 cache flush, not a bank select. It must
    // invalidate the whole L1 (every set of both caches) without touching the
    // ROM window -- and, as qemu's mem_bankctl_write falls through every case
    // that is not 0x20/0xE0 (pc98-mem.c:684-701), without touching the EMS
    // window either: with 0x22 enabled the page must SURVIVE the flush
    // (tb_pc9821_ems pins the route). Before
    // the fix this else-armed every non-0x2x write back to the identity and
    // the check below read ems_state=0 where it wants 1.
    write_byte(16'h043F, 8'h22);
    clear_flush_log();
    write_byte(16'h043F, 8'hA0);
    if (top_bank != 4'd3 || ems_state != 2'd1) begin
      $display("FAIL 0xA0 cache flush changed top_bank=%0d ems_state=%0d, want 3/1 (unchanged)",
               top_bank, ems_state);
      errors = errors + 1;
    end
    check_flush_once("0x43F cache flush");

    // 0x043F's 0x8 nibble is the 0xF8000-0xFFFFF window's writable-shadow enable
    //. It is a latch, not a bank: the ITF writes 0x80 before it stores its
    // candidate-drive bitmap (BANK4@0x1D0/0x19CE) and no site writes it back to zero,
    // so it stays set until reset -- which is what makes the memory map read the pack
    // during the ITF's first ROM-sum pass (the enable then is still clear) and the
    // shadow afterwards. It changes the window's read source, so it must cost the
    // window's invalidation exactly as a bank select does -- and it must leave the
    // EMS state alone (the 0x8 nibble is not one of the 0x2x states; qemu's
    // mem_bankctl_write falls through it, pc98-mem.c:684-701), so with 0x22's page
    // enabled the ems_state below is 1, not the identity the old else arm reset to.
    clear_flush_log();
    write_byte(16'h043F, 8'h80);
    if (!top_shadow_en || top_bank != 4'd3 || ems_state != 2'd1) begin
      $display("FAIL 0x043F=0x80 top_shadow_en=%b top_bank=%0d ems_state=%0d, want 1/3/1 (0x8x leaves the EMS state alone)",
               top_shadow_en, top_bank, ems_state);
      errors = errors + 1;
    end
    check_flush_once("shadow-enable flush (one whole-L1 request)");
    // Redundant, exactly as the bank select is: the latch only turns ON, so a re-write
    // cannot change the read source and must not flush.
    clear_flush_log();
    write_byte(16'h043F, 8'h80);
    if (flush_pulses != 0) begin
      $display("FAIL redundant 0x043F=0x80 emitted %0d flush request(s)", flush_pulses);
      errors = errors + 1;
    end
    // The 0xA0 cache flush is a different function of the same port and must not clear
    // the enable: only reset does. It must not move the EMS state either.
    write_byte(16'h043F, 8'hA0);
    if (!top_shadow_en || ems_state != 2'd1) begin
      $display("FAIL 0x043F=0xA0 top_shadow_en=%b ems_state=%0d, want 1/1 (unchanged)",
               top_shadow_en, ems_state);
      errors = errors + 1;
    end

    clear_flush_log();
    write_byte(16'h043D, 8'h10);
    if (top_bank != 4'd8) begin
      $display("FAIL ITF reselect top_bank=%0d", top_bank);
      errors = errors + 1;
    end
    check_flush_once("ITF flush (one whole-L1 request)");

    // ---- window 0 (0x0461) and window 1 (0x0463) -------------------------
    // 0x0461 moves the 128 KiB region at 0x80000-0x9FFFF to value*0x10000.
    // 0x80000-0x9FFFF is below the z486's internal VGA aperture and outside
    // the platform device aperture (0xC0000-0xFFFFF, mask 0xFFFC0000), so it
    // IS cached and a change must invalidate all 128 KiB. The firmware's three
    // values are 0x0E (BANK4@0x01D3/0x19D4), 0x0C (BANK4@0x0201) and 0x08
    // (BANK4@0x0265/0x1A4C/0x250E/0x4AB4, the identity it restores).
    if (win0_sel !== 8'h08) begin
      $display("FAIL 0x0461 reset value %02x, expected 08", win0_sel);
      errors = errors + 1;
    end
    // win0_sel_moved is the window-moved flag the memory map reads (the registered
    // `win0_sel != 8'h08`): it must follow every 0x0461 write, end to end.
    if (win0_sel_moved !== 1'b0) fail("win0_sel_moved set out of reset (the identity 08)");
    // Measured on the machine (probes/WIN.TXT, 2026-09-13, /WIN), first touch,
    // before anything wrote either port: 0x461 reads 09 and 0x463 reads 0B --
    // the identity 0x08 and the reset 0x0A, each with bit 0 reading back set.
    read_byte(16'h0461, 8'h09);
    read_byte(16'h0463, 8'h0B);

    clear_flush_log();
    write_byte(16'h0461, 8'h0E);
    if (win0_sel !== 8'h0E) begin
      $display("FAIL 0x0461 latch %02x", win0_sel);
      errors = errors + 1;
    end
    if (win0_sel_moved !== 1'b1) fail("win0_sel_moved not set after 0x0461 = 0E");
    check_flush_once("window 0 move");
    // Reselecting the current value is not a mapping change (QEMU guards the
    // same way), so it must not pay for another 128 KiB invalidation.
    clear_flush_log();
    write_byte(16'h0461, 8'h0E);
    if (flush_pulses != 0) begin
      $display("FAIL redundant 0x0461 write emitted %0d flush request(s)", flush_pulses);
      errors = errors + 1;
    end
    // Bit 0 is not part of the page number. The machine's own /WIN restore
    // reads 0x80000 = 0000 and 0x90000 = 502F with 0x461 = 0x09 and leaves the
    // register at 09 -- both words are still their own, i.e. 0x09 maps exactly
    // where 0x08 does. A 0x09 write over a 0x08 state is therefore not a
    // mapping change and must not invalidate anything, while the read-back is
    // still 09.
    // ... first the 0x0E -> 0x08 restore, which IS a change again.
    clear_flush_log();
    write_byte(16'h0461, 8'h08);
    check_flush_once("window 0 restore");
    if (win0_sel_moved !== 1'b0) fail("win0_sel_moved still set after the 0x0461 = 08 restore");
    clear_flush_log();
    write_byte(16'h0461, 8'h09);
    if (win0_sel_moved !== 1'b0) fail("win0_sel_moved set by 0x0461 = 09 (maps as the identity 08)");
    if (win0_sel !== 8'h08 || flush_pulses != 0) begin
      $display("FAIL 0x0461 = 09 moved the page: state=%02x flushes=%0d",
               win0_sel, flush_pulses);
      errors = errors + 1;
    end
    read_byte(16'h0461, 8'h09);

    // The register's read-back is NOT the value written and NOT QEMU's
    // (value & 0xFE): the machine answers (value | 1), for every value /WIN
    // swept it with: 0461=00 rb=01, =0A rb=0B, =0C rb=0D, =0F rb=0F,
    // =10 rb=11, =41 rb=41, =7F rb=7F. The stored page is (value & 0xFE), so
    // an odd value reads back as itself and maps as its even neighbour.
    write_byte(16'h0461, 8'h00);
    if (win0_sel !== 8'h00) fail("0x0461 = 00 did not store page 0");
    if (win0_sel_moved !== 1'b1) fail("win0_sel_moved not set after 0x0461 = 00");
    read_byte(16'h0461, 8'h01);              // 0461=00 rb=01
    write_byte(16'h0461, 8'h0A);
    read_byte(16'h0461, 8'h0B);              // 0461=0A rb=0B
    write_byte(16'h0461, 8'h0C);
    read_byte(16'h0461, 8'h0D);              // 0461=0C rb=0D
    write_byte(16'h0461, 8'h0F);
    if (win0_sel !== 8'h0E) fail("0x0461 = 0F stored bit 0");
    read_byte(16'h0461, 8'h0F);              // 0461=0F rb=0F
    write_byte(16'h0461, 8'h10);
    read_byte(16'h0461, 8'h11);              // 0461=10 rb=11
    write_byte(16'h0461, 8'h41);
    if (win0_sel !== 8'h40) fail("0x0461 = 41 stored bit 0");
    read_byte(16'h0461, 8'h41);              // 0461=41 rb=41
    write_byte(16'h0461, 8'h7F);
    if (win0_sel !== 8'h7E) fail("0x0461 = 7F stored bit 0");
    read_byte(16'h0461, 8'h7F);              // 0461=7F rb=7F
    write_byte(16'h0461, 8'h08);             // leave the window at the identity

    // 0x0463 is window 1 at 0xA0000-0xBFFFF. Measured: every value written
    // leaves 0xA0000-0xBFFFF identity-mapped -- the word at 0xA0000 stays the
    // text RAM's own, and the marker words land in pages 0x0A and 0x0B for all
    // eight values, 0x0A and 0x0E included -- while the register still reads
    // back (value | 1). A latch with no mapping effect is therefore the correct
    // model. No firmware bank in 160 KiB writes the port (the only writers of
    // the pair are the 0x0461 sites above), and the VRAM overlays whose 0x0A
    // semantics QEMU describes are what the core serves unconditionally.
    clear_flush_log();
    write_byte(16'h0463, 8'h00);  read_byte(16'h0463, 8'h01);   // 0463=00 rb=01
    write_byte(16'h0463, 8'h08);  read_byte(16'h0463, 8'h09);   // 0463=08 rb=09
    write_byte(16'h0463, 8'h0A);  read_byte(16'h0463, 8'h0B);   // 0463=0A rb=0B
    write_byte(16'h0463, 8'h0C);  read_byte(16'h0463, 8'h0D);   // 0463=0C rb=0D
    write_byte(16'h0463, 8'h0E);  read_byte(16'h0463, 8'h0F);   // 0463=0E rb=0F
    write_byte(16'h0463, 8'h0F);  read_byte(16'h0463, 8'h0F);   // 0463=0F rb=0F
    write_byte(16'h0463, 8'h10);  read_byte(16'h0463, 8'h11);   // 0463=10 rb=11
    write_byte(16'h0463, 8'h41);  read_byte(16'h0463, 8'h41);   // 0463=41 rb=41
    if (flush_pulses != 0) begin
      $display("FAIL 0x0463 cost %0d flush request(s)", flush_pulses);
      errors = errors + 1;
    end
    write_byte(16'h0463, 8'h0A);   // back to the measured resting value

    // The option-ROM window is OPEN FROM RESET on a non-PCI machine. QEMU's
    // `pc98_mem_reset` sets `ide_rom_gate = has_pci ? 0 : 1` with the comment
    // "the BX2 firmware expects the IDE ROM visible from reset", and the
    // authentic ITF proves it: its early code copies 8 KiB out of 0xD8000
    // *before* it ever writes 0x53D, so with the gate shut it copies zeros and
    // fails its own AA55 check at BANK4@0xFC681. Nothing needs to be written
    // first, which is the contract to assert here.
    if (!ide_rom_enable) begin
      $display("FAIL the option-ROM window is not open at reset");
      errors = errors + 1;
    end
    // The watchdog prints this nibble as G: [3] window, [2] 0x53D gate,
    // [1:0] 0x63C select (00 = the IDE option ROM, the Xe10's reset bank:
    // docs/probes/D8BANK-XE10.TXT reads FC).
    if (dbg_gate !== 4'hC) begin
      $display("FAIL IDE gate nibble %b, expected 1100", dbg_gate);
      errors = errors + 1;
    end
    // Closing it must invalidate anything cached from the window. The 0x053D
    // flush covers every line the gate decides and every ENCODING of it
    // (aliases.md A3): 0xD8000-0xFFFFF (the 8 KiB option-ROM window plus the
    // 64 KiB lower BIOS plus the 32 KiB banked window, 160 KiB = 10240 lines),
    // its 0xFD8000-0xFFFFFF mirror (10240 more), the win0=0x0C/0x0E overlay
    // encodings at 0x88000-0x9FFFF (6144), and the banked window's fw_high
    // alias (2048 more).
    clear_flush_log();
    write_byte(16'h053D, 8'h00);
    if (ide_rom_enable) begin
      $display("FAIL IDE ROM disable");
      errors = errors + 1;
    end
    check_flush_once("IDE ROM disable flush (one whole-L1 request)");
    // ...and reopening it must too.
    clear_flush_log();
    write_byte(16'h053D, 8'h10);
    if (!ide_rom_enable) begin
      $display("FAIL IDE ROM not enabled by 0x53D bit 4");
      errors = errors + 1;
    end
    check_flush_once("IDE ROM enable flush (one whole-L1 request)");

    // The ITF's own sequence on the normal path, in the values it writes:
    // 0x10 while it copies 8 KiB out of the window (BANK4@0x020F), 0x00 and
    // 0x02 after it (BANK4@0x0228/0x025B, both closed), and finally 0x16 --
    // bit 4 plus the two bits the non-PCI strap computes -- at BANK4@0x1A44,
    // which is the last 0x053D write before the main BIOS's option-ROM scan
    // and its `call far D800:000C` (BANK6@0x5698). 0x16 must leave the window
    // OPEN, because that call is where the IDE option ROM is installed.
    write_byte(16'h053D, 8'h02);
    if (ide_rom_enable) begin
      $display("FAIL 0x053D = 0x02 left the window open");
      errors = errors + 1;
    end
    write_byte(16'h053D, 8'h16);
    if (!ide_rom_enable) begin
      $display("FAIL 0x053D = 0x16 (the value before the BIOS call) closed the window");
      errors = errors + 1;
    end
    if (!bios_ram_gate) begin
      $display("FAIL 0x053D = 0x16 did not set the writable BIOS copy (bit 1)");
      errors = errors + 1;
    end

    // 0x063C no longer gates the window on a non-PCI machine: the main BIOS
    // writes 0x063C = (read & 0xFC) | 3 immediately before `call far
    // D800:000C` (BANK6 offset 0x567C-0x5698), so a 0x063C write must not
    // disable the window. The firmware's own far call proves the window stays
    // enabled; see notes/08-ide.md. It DOES change what the window shows (select
    // 3 is BANK0 0x4000-0x7FFF, docs/probes/D8BANK-XE10.TXT), so it costs exactly
    // the one L1 flush every remap of the window owes (tb_pc9821_cache_flush).
    write_byte(16'h053D, 8'h10);
    clear_flush_log();
    write_byte(16'h063C, 8'h03);
    if (!ide_rom_enable || flush_pulses != 1) begin
      $display("FAIL 0x063C write changed the window ide_en=%b flushes=%0d",
               ide_rom_enable, flush_pulses);
      errors = errors + 1;
    end
    write_byte(16'h053D, 8'h00);

    // 0x053D bit 1 is the writable-BIOS-copy gate and it decides whether the
    // firmware windows read RAM or ROM (QEMU
    // mem_apply_top_bank enables its f8000_ram/e8000_ram aliases on it), so a
    // change of it must invalidate every line the gate covers:
    // 0xD8000-0xFFFFF -- the option-ROM window, the 64 KiB lower BIOS and the
    // 32 KiB banked window, 160 KiB = 10240 16-byte lines. Without it a stale
    // cached read of the window would look exactly like the no-boot-device
    // defect this gate is half of.
    write_byte(16'h053D, 8'h00);
    clear_flush_log();
    write_byte(16'h053D, 8'h02);
    if (!bios_ram_gate) begin
      $display("FAIL 0x053D = 0x02 did not set the writable BIOS copy");
      errors = errors + 1;
    end
    check_flush_once("0x053D bit-1 flush (one whole-L1 request)");
    clear_flush_log();
    write_byte(16'h053D, 8'h02);
    if (flush_pulses != 0) begin
      $display("FAIL redundant 0x053D = 0x02 emitted %0d flush request(s)", flush_pulses);
      errors = errors + 1;
    end
    write_byte(16'h053D, 8'h00);

    // The 0x053D READ-BACK must put the writable-BIOS-copy gate in the SAME bit
    // the write takes it from (bit 1), or a guest read-modify-write cannot
    // round-trip it: with the gate clear the old read returned bit 1 = 1, so
    // writing the byte back turned the gate on. The measured 0x1F has bit 4 (the
    // window, on) and bit 1 (the gate, on) both set; with the gate off and the
    // window on the same byte reads 0x1D.
    write_byte(16'h053D, 8'h10);           // window on, gate off
    if (bios_ram_gate) fail("0x053D = 0x10 left the writable BIOS copy set");
    read_byte(16'h053D, 8'h1D);            // bit 1 = 0: the gate reads where it is written
    write_byte(16'h053D, 8'h12);           // window on, gate on
    read_byte(16'h053D, 8'h1F);            // the DOS-prompt value, round-tripped
    // A read-modify-write of the gate must round-trip: read the byte, write it
    // straight back, and the gate must not move.
    write_byte(16'h053D, 8'h10);
    read_raw(16'h053D, value);
    write_byte(16'h053D, value);
    if (bios_ram_gate) fail("a read-modify-write of a gate-clear 0x053D set the gate");
    write_byte(16'h053D, 8'h00);           // restore the resting state

    write_byte(16'h00F6, 8'h03);
    if (a20_enable) begin
      $display("FAIL A20 disable");
      errors = errors + 1;
    end

    // The system PPI's port C is a plain 8255 BSR latch, NOT a second A20
    // control: setting or resetting bit 4 moves only the 0x35 read-back. The
    // authentic ITF pulses bit 4 with the BSR bytes 0x09/0x08
    // (BANK4@0xF8F19/0xF908D) inside the second protected-mode block of its
    // POST, which has just RELEASED A20 with `out 0xF2,0` / `out 0xF6,2`
    // (BANK4@0xF8952/0xF8956); a gate that followed the PPI there masks A20 and
    // the block's 128 KiB zero-fill (GDT descriptor 0x40, base set at
    // BANK4@0xF8F0D/0xF8F11) wraps onto the GDT image at 0x8000 and the IDT at
    // 0x9000 the same block installed (BANK4@0xF892A/0xF8933). Neither reference
    // connects port 0x37 to A20 (QEMU hw/misc/pc98-sys.c
    // pc98_sysppi_ctrl_write, NP2kai io/sysport.c sysp_o37 -- where bit 4 is
    // the RS232C send line).
    write_byte(16'h00F6, 8'h02);          // 0xF6 strobe, bit 0 = 0: A20 released
    if (!a20_enable) fail("0xF6 did not release A20");
    read_raw(16'h0035, value);
    write_byte(16'h0037, 8'h09);          // BSR: set port C bit 4
    if (!a20_enable) fail("PPI port C bit 4 set moved A20");
    read_byte(16'h0035, value | 8'h10);   // ...yet the latch itself did move
    write_byte(16'h0037, 8'h08);          // BSR: reset port C bit 4
    if (!a20_enable) fail("PPI port C bit 4 reset moved A20");
    read_byte(16'h0035, value & ~8'h10);
    write_byte(16'h00F6, 8'h03);          // back to the state the tests above expect
    read_byte(16'h00F1, 8'hFF);
    write_byte(16'h00F2, 8'h00);
    if (!a20_enable) begin
      $display("FAIL A20 enable");
      errors = errors + 1;
    end

    // 0xF6 reads the machine's 0x5E whether the line is released OR masked: the a20map
    // probe masks with `out 0xF6,0x03` (its a20_mask) and then reads "after masking:
    // F6=5E F2=FF" while its masked reads wrap bit 20 (docs/probes/A20MAP-XE10.TXT:9,19);
    // "initial A20: F6=5E" with the line open (:2). The mask state is visible at 0xF2
    // only. NP2kai cpuio_if6 and MAME a20_ctrl_w report bit 0 = masked; the capture
    // outranks both. The old bench expected 0x5F masked, a value never measured.
    read_byte(16'h00F6, 8'h5E);         // 0xF2 above released the line
    write_byte(16'h00F6, 8'h03);        // mask
    read_byte(16'h00F6, 8'h5E);
    // Only 0x02 and 0x03 move the gate: NP2kai cpuio_of6 `switch(dat) { case 0x02: ...
    // case 0x03: ... }` and MAME pc9801.cpp a20_ctrl_w (`if(data == 0x02) ... else if
    // (data == 0x03) ... else logerror(...unmapped data write...)`). A read-modify-write
    // of the 0x5E it reads back, or any other byte with bit 1 set, leaves it alone.
    write_byte(16'h00F6, 8'h5E);
    if (a20_enable) fail("0xF6 = 0x5E (bit 1 set, not 0x02) released A20");
    write_byte(16'h00F6, 8'h02);        // release again
    write_byte(16'h00F6, 8'h07);
    if (!a20_enable) fail("0xF6 = 0x07 (bit 1 set, not 0x03) masked A20");
    write_byte(16'h00F6, 8'hFF);
    if (!a20_enable) fail("0xF6 = 0xFF (not 0x03) masked A20");
    read_byte(16'h00F6, 8'h5E);
    // 0xF2 reads TRACK the A20 state: NP2kai's cpuio_if2 returns
    // 0xFF - bit20(CPU_ADRSMASK), i.e. 0xFE released / 0xFF masked.
    // The constant 0xFE made a gate-state probe read
    // released even while masked; the machine's single 0xFE sample was taken with
    // the line released and separates neither model. FAIL-FIRST: 0xFF at the
    // second read below.
    read_byte(16'h00F2, 8'hFE);         // released
    write_byte(16'h00F6, 8'h03);        // mask
    read_byte(16'h00F2, 8'hFF);         // masked
    write_byte(16'h00F6, 8'h02);        // release again, as before
    read_byte(16'h00F2, 8'hFE);

    // The extended video port 0x9A0 is an INDEX/DATA QUERY (NP2kai gdc_i9a0,
    // io/gdc.c:969-1030): a write selects the index and
    // the read returns the indexed bit of the GDC extension state, with
    // `ret |= (gdc.clock & 2)` in every answer. Two machine captures pin both
    // halves (probes/PROBE.TXT `FF 9A0 after writing 0x0A: 00` and the un-written
    // `09A0=01`, eleven snapshots): the write-then-read is the table's index-0x0A
    // answer with analog-256 clear - the BIOS PEGC probe is NOT acknowledged -
    // and the un-written read stays the measured 0x01 because the power-up INDEX
    // is unmeasured. The old arm answered 0x01 for every index and its comment
    // claimed "bit 0 is held clear" while returning bit 0 SET. The table itself
    // is pinned bit for bit by tb_pc9821_readback_sysports.
    read_byte(16'h09A0, 8'h01);       // un-written: the machine's byte
    write_byte(16'h09A0, 8'h0A);
    read_byte(16'h09A0, 8'h00);       // ...and write-then-read is the QUERY

    // The floppy controller (uPD72065 class) answers its three system ports with
    // the MACHINE's idle reads. 0x90 is the MAIN STATUS register: idle it reads
    // 0x80 (RQM, "ready to talk"), and a driver that polls RQM before issuing a
    // command spins forever against the 0x00 an undecoded port returns -- which is
    // what the black-screen investigation found the guest doing. 0x92 is the DATA
    // register: the machine reads 0x80 there with no result standing (R10.TXT all
    // five snapshots, PORTS.TXT and EMS.TXT agree), so the
    // model answers the capture, not NP2kai fdc_i92's ZeroMemory'd lastdata latch.
    // 0x94 is the DOR: NP2kai fdc_i94 computes 0x44 for this machine (no DMA
    // request, external-priority strap), so the read is a computed byte and not a
    // latched one.
    read_byte(16'h0090, 8'h80);
    read_byte(16'h0092, 8'h80);
    read_byte(16'h0094, 8'h44);

    // 0x04BE is the FDC's 1.44M/RPM register (NP2kai io/fdc.c:1117-1134;
    // support144 = 1 on every PC-9821, so the Xe10 has it). Undecoded it answered
    // open bus 0xFF and counted in the unmapped telemetry the watchdog reads as
    // boot-stop evidence. Now it answers rpm[reg144[6:5]] |
    // 0xFE, and its traffic must NOT reach the unmapped counters - which the exact
    // count checks below (1 read / 1 write for 0x1235/0x1234 alone) assert, since
    // this block runs four accesses first. FAIL-FIRST: 0xFF at the first read.
    read_byte(16'h04BE, 8'hFE);         // power-up: rpm[0] | 0xFE
    write_byte(16'h04BE, 8'h51);        // bit 4 set: rpm[drive 2] = 1, and selected
    read_byte(16'h04BE, 8'hFF);
    write_byte(16'h04BE, 8'h00);        // selects drive 0; bit 4 clear stores no rpm
    read_byte(16'h04BE, 8'hFE);

    read_byte(16'h1235, 8'hFF);
    if (unmapped_reads != 16'd1 || last_unmapped_port != 16'h1235) begin
      $display("FAIL unmapped read accounting count=%0d last=%04x",
               unmapped_reads, last_unmapped_port);
      errors = errors + 1;
    end
    write_byte(16'h1234, 8'h55);
    if (unmapped_writes != 16'd1 || last_unmapped_port != 16'h1234) begin
      $display("FAIL unmapped write accounting count=%0d last=%04x",
               unmapped_writes, last_unmapped_port);
      errors = errors + 1;
    end

    // No PCI configuration space: a mid-range 486 PC-98 has no PCI bus, so
    // 0x0CF8-0x0CFF must stay open bus. That is also why the user's boot menu
    // reads 0x0CFF and sees 0xFF - it is probing for PCI and correctly finding
    // none on the target machine.
    read_byte(16'h0CF8, 8'hFF);
    read_byte(16'h0CFF, 8'hFF);

    // ---- word reads at the GRCG ports ------------------------
    // NP2kai's iocore_inp16 treats 0x7C as TERM_MINUS (io/iocore16.tbl:23-26
    // lists 0x7c): `case TERM_MINUS: return(iof->ioinp[port & 0xff](port))`
    // (io/iocore.c:781-782) returns the REG8 zero-extended into REG16, so
    // `in ax,7Ch` answers {0x00, the device byte} and port 0x7D is never
    // fetched. The device stub's 0xC3 is this bench's own device-port answer
    // (device_io_dout = 0xC3, :21) and stands in for whatever the video device
    // drives; the REAL 0x7C is write-only and its byte read is open bus 0xFF
    // (probes/RDBACK.TXT:152, pinned by tb_pc9821_readback_gdc). The ORACLE here
    // is the assembly - the zero-extended lane 1 - not the byte. 0x7E is NOT in
    // minus_term, so `in ax,7Eh` keeps the
    // default byte split (io/iocore.c:789-792): the high byte is port 0x7F's
    // own open-bus 0xFF, NOT zero. FAIL-FIRST on the 0x7C case alone: the
    // split answered 0xFFC3 where NP2kai answers 0x00C3. (Placed after the
    // exact-count open-bus checks: its undecoded lanes do count as unmapped.)
    read_word(16'h007C, 16'h00C3);
    read_word(16'h007E, 16'hFFC3);
    read_byte(16'h007C, 8'hC3);   // lane 0 is the device bus (this bench's stub); the real 0x7C reads FF
    read_byte(16'h007D, 8'hFF);   // and 0x7D alone is definp8 open bus, not zero

    // ---- the measured port table (probes/PORTS.TXT, 2026-09-12) ----------
    // Every value here was read off the real PC-9821Xe10 with the fixed probe.
    // They are grouped in one place on purpose: this is the set of answers a
    // differential test compares, and a regression in any of them should name
    // itself immediately rather than surfacing as a mysterious boot failure.
    read_byte(16'h0042, 8'h94);   // the firmware reads this for straps
    read_byte(16'h0032, 8'h45);
    read_byte(16'h0044, 8'h81);
    read_byte(16'h00F4, 8'hFC);
    read_byte(16'h0134, 8'h0F);
    read_byte(16'h0434, 8'hBE);
    read_byte(16'h053E, 8'hFC);
    // 0x053E is a READ-ONLY STRAP, not a latch or a gate: the write below cannot move it.
    // Neither reference makes it a control register (NP2kai has no I/O 0x053E at all -- its
    // 0x0053E is a BIOS memory cell -- so a decode that latched it would be invented).
    write_byte(16'h053E, 8'h00);
    read_byte(16'h053E, 8'hFC);
    // Sound-board ports 0x188/0x18A/0x18C/0x18E are DEVICE ports now: the
    // PC-9801-86's OPNA owns their behaviour (register select, joystick, BUSY
    // and the 0xA460 extension gate) and tb_pc9821_opna.sv asserts it against
    // the real chip. This bench's job is the I/O bus, so what it pins is the
    // DECODE: each of the four reaches the device bus rather than being
    // answered by the I/O bus, and a 0xA460 bit-0 write reaches the extension
    // latch the OPNA consumes. This bench models a device whose data byte is
    // the constant 0xC3 above, so a read here must return exactly that.
    saw_dev_rd = 0;
    read_byte(16'h0188, 8'hC3);
    if (!saw_dev_rd || last_dev_rd_addr !== 16'h0188)
      fail("0x188 did not reach the device bus");
    saw_dev_rd = 0;
    read_byte(16'h018A, 8'hC3);
    if (!saw_dev_rd || last_dev_rd_addr !== 16'h018A)
      fail("0x18A did not reach the device bus");
    saw_dev_rd = 0;
    read_byte(16'h018C, 8'hC3);
    if (!saw_dev_rd || last_dev_rd_addr !== 16'h018C)
      fail("0x18C did not reach the device bus");
    saw_dev_rd = 0;
    read_byte(16'h018E, 8'hC3);
    if (!saw_dev_rd || last_dev_rd_addr !== 16'h018E)
      fail("0x18E did not reach the device bus");
    // 0xA460 stays a system port: its write has to set the extension enable
    // pc9821_opna consumes.
    write_byte(16'h0A460, 8'h01);
    if (sound_extend !== 1'b1)
      fail("0xA460 bit 0 did not set the sound extension enable");
    write_byte(16'h0A460, 8'h00);
    if (sound_extend !== 1'b0)
      fail("0xA460 bit 0 did not clear the sound extension enable");
    // The WSS ports answer open bus. They used to answer 0x00 -- a deliberate
    // fabrication to spare the FREE BIOS a 65536-iteration timeout.
    read_byte(16'h0F40, 8'hFF);
    read_byte(16'h0F44, 8'hFF);
    read_byte(16'h0F45, 8'hFF);
    // 0x063C is a latch the machine reads back, and its bits 1-0 are the 0xD8000
    // bank select (docs/probes/D8BANK-XE10.TXT: start FC; writes of FD, FE, FF read
    // back FD, FE, FF). The write above left 0x03 in it.
    read_byte(16'h063C, 8'h03);
    if (d8_bank !== 2'd3) fail("0x063C bits 1-0 do not reach the 0xD8000 bank select");
    write_byte(16'h063C, 8'hFD);
    read_byte(16'h063C, 8'hFD);
    if (d8_bank !== 2'd1) fail("0x063C = FD does not select bank 1");
    write_byte(16'h063C, 8'hFC);
    read_byte(16'h063C, 8'hFC);
    read_byte(16'h043F, 8'hC4);   // closes an earlier open item

    // ---- software DIP switches -------------------------------------------
    // What the HARDWARE does, from measurement plus the authentic ITF's own
    // verifier (BANK4@0x46C0-0x4726):
    //   * the twelve data ports are one byte each; the port nibble picks the
    //     register and bit 6 of 0x8F1F picks the bank (0x80 = bank A,
    //     0xC0 = bank B);
    //   * one bit of 0x84 (bit 1) is a machine strap a write cannot move: it is
    //     unmeasured, NP2kai withholds it (io/dipsw.c) and the measured power-up
    //     byte 0x7C has it clear. EVERY OTHER BIT IS WRITABLE, the per-register
    //     PARITY bits (bit 0 of 0x84, bit 4 of 0x85, bit 7 of the rest) included -
    //     THIS BENCH USED TO ASSERT THE OPPOSITE and was inverted on the machine's
    //     evidence: the firmware writes those bits (SETUP's parity idiom
    //     BANK3@0xFA219; the ITF's `or al,0x80 / out 0x8E1E`) and the ITF's repair
    //     installs its factory tables through these ports (BANK4@0xFC7E4, tables
    //     BANK4@0x480C/0x4818), so a frozen parity bit composed the repair's 0x7F
    //     over the machine image 0xBF (probes/PORTS.TXT) into an EVEN 0xFF - the
    //     SET THE SOFTWARE DIP-SWITCH loop. The Xa7C9W capture holds the factory
    //     byte 0x7F at exactly that cell. Falsifier: `probe2 /RDBACK` at 0x8B1E or
    //     0x881E on the machine - if the machine masks that bit on write, the RTL
    //     change reverses (see pc9821_iobus.sv sdip_data_mask).
    //   * a READ RETURNS THE STORED BYTE VERBATIM, strap bits included. This bench
    //     used to assert the opposite (an odd-parity bit recomputed on every read,
    //     NP2kai's model), and the machine refutes it at the one port anyone has
    //     written and read back: docs/probes/RDBACK.TXT is `port=871E before=3E
    //     wrote=0C after=0C back=3E`, an EVEN-parity byte coming straight back.
    //     qemu-pc98 stores and returns the byte verbatim too, so the capture and it
    //     agree against NP2kai (capture outranks it). Only 0x871E of the twelve is
    //     measured -- a write-then-read round for the other eleven is owed.
    //   * the ITF's own verifier still passes on both models: the factory image it
    //     writes into a bank and reads back is odd-parity byte for byte (index 6
    //     excepted, and it has no parity bit), so a read of any of those bytes is
    //     the same value either way. Eleven of the twelve measured machine values
    //     (probes/PORTS.TXT) having odd parity is the image's property, not a
    //     recompute.
    read_byte(16'h041E, 8'hFF);             // untouched data port: all ones
    read_byte(16'h8F1F, 8'hFF);             // write-only on the machine
    read_byte(16'h841E, 8'h7C);             // bank A, measured
    read_byte(16'h8A1E, 8'hFF);             // index 6: the XOR partner, no strap bit
    read_byte(16'h8F1E, 8'h98);
    // The whole measured bank-A image reads back byte for byte. Asserting the
    // values therefore asserts the strap bits' positions too (a write cannot move
    // one, and no read forces one).
    write_byte(16'h8F1F, 8'h80);            // enable, bank A
    read_byte(16'h841E, 8'h7C);             // idx 0
    read_byte(16'h851E, 8'h02);             // idx 1
    read_byte(16'h861E, 8'h76);             // idx 2
    read_byte(16'h871E, 8'h3E);             // idx 3
    read_byte(16'h881E, 8'h7C);             // idx 4
    read_byte(16'h891E, 8'h7F);             // idx 5  (the XOR pair's first half)
    read_byte(16'h8A1E, 8'hFF);             // idx 6  (its partner)
    read_byte(16'h8B1E, 8'hBF);             // idx 7
    read_byte(16'h8C1E, 8'h7F);             // idx 8
    read_byte(16'h8D1E, 8'h7F);             // idx 9
    read_byte(16'h8E1E, 8'h49);             // idx 10
    read_byte(16'h8F1E, 8'h98);             // idx 11
    // A write cannot move 0x84's bit 1 (the one withheld strap) - and index 1's
    // bit 4 is DERIVED on the read from the DIP-2 strap (pc9821_iobus.sv
    // sdip_read_byte), so writing 0x5A stores 0x5A but the port presents 0x4A at
    // the entry-0 strap. The write owns the bit now (see the inversion above); the
    // read owns it too, and the read is what the ITF merges.
    write_byte(16'h851E, 8'h5A);
    read_byte(16'h851E, 8'h4A);
    // Bank B: same rules, bank selected by 0xC0. Its seeds are 0x8F then 0x80.
    write_byte(16'h8F1F, 8'hC0);
    read_byte(16'h851E, 8'h80);             // untouched by the bank-A write
    write_byte(16'h851E, 8'hA5);            // bit 4 is bank B index 1's strap: it stays clear
    read_byte(16'h851E, 8'hA5);
    read_byte(16'h841E, 8'h8F);             // bank B index 0, its only odd seed
    // Bank B's last four bytes must stay INSIDE the 24-byte store: with the bank
    // bit concatenated in front of the index these four ports addressed
    // sdip[24..27], outside `reg [7:0] sdip[0:23]`.
    read_byte(16'h8C1E, 8'h80);
    write_byte(16'h8C1E, 8'h3C);
    read_byte(16'h8C1E, 8'h3C);             // stored as written - bit 7, the parity
                                            // bit, included (the inversion above)
    read_byte(16'h8F1E, 8'h80);
    write_byte(16'h8F1F, 8'h80);            // back to bank A
    read_byte(16'h851E, 8'h4A);             // bank A keeps its own value
    read_byte(16'h841E, 8'h7C);

    // ---- the OSD actions are REMOVED ----
    // `Reset DIPs`/`Zero DIPs` and their store-walk sources are gone from CONF_STR and
    // the RTL; the store's restore walk keeps its machine-reset seed, pinned by the
    // MACHINE-RESET section below.

    // ---- the 0x989x register file (probes/R10.TXT /MODE) ------
    // The ITF reads 0x9894 at BANK4@0xFCAED and needs bit 3 CLEAR to continue
    // (`test al,0x8; je 0xfcb16`); bit 3 set diverts into the clock-reprogram
    // and the `out 0xF0` CPU-mode reset at 0xFCB11, which lands the guest in
    // zeroed RAM. Undecoded, the read is open bus 0xFF and bit 3 = 1, so every
    // cold boot took the fatal branch. The machine's byte is measured:
    // probes/R10.TXT /MODE reads 0x9894 = 0xF0 F0 and 0x9892 = 0xF0 F0, each
    // port twice with no writes at all. Bit 3 = 0 is likewise what the dump
    // requires. 0x98E0 is deliberately undecoded: the machine reads open bus
    // 0xFF there, and the ITF's only write to it (BANK4@0xFCB01, the fatal
    // branch) is the unmapped traffic that named this gate.
    begin
      integer ur0, uw0;
      reg [3:0] bank_before;
      ur0 = unmapped_reads;
      uw0 = unmapped_writes;

      read_raw(16'h9894, value);
      if (value[3] !== 1'b0) begin
        $display("FAIL 0x9894 bit 3 set: the ITF's 0xFCAF3 test would divert (byte=%02x)",
                 value);
        errors = errors + 1;
      end
      if (value !== 8'hF0)
        fail("0x9894 does not read the measured 0xF0");
      // The machine answers 0x9892 too, so it is a strap register and not a
      // write-only data port.
      read_raw(16'h9892, value);
      if (value !== 8'hF0)
        fail("0x9892 does not read the measured 0xF0");

      // A write must not move what the read answers. The measured datum is the
      // machine's NO-WRITE read (probes/R10.TXT /MODE, every port read twice,
      // no writes) = 0xF0; whether a write moves it is unmeasured until /MODEW,
      // so this pins the core's contract (write ignored) without claiming the
      // machine's write behaviour.
      write_byte(16'h9894, 8'hFF);
      write_byte(16'h9892, 8'hFF);
      read_raw(16'h9894, value);
      if (value !== 8'hF0) begin
        $display("FAIL out 0x9894/0x9892 moved the strap: byte=%02x", value);
        errors = errors + 1;
      end
      if (unmapped_reads != ur0)
        fail("decoded 0x9892/0x9894 reads incremented unmapped_reads");
      if (unmapped_writes != uw0)
        fail("decoded 0x9892/0x9894 writes incremented unmapped_writes");

      // 0x9890, 0x9896 and 0x98E0 read open bus on the machine and stay
      // undecoded here: every read is 0xFF, and a write to 0x98E0 keeps
      // counting as unmapped, which is the telemetry (U=98E0) that named the
      // ITF's fatal branch on the deployed build.
      ur0 = unmapped_reads;
      read_raw(16'h9890, value);
      if (value !== 8'hFF) fail("0x9890 is decoded: the machine reads open bus 0xFF");
      read_raw(16'h9896, value);
      if (value !== 8'hFF) fail("0x9896 is decoded: the machine reads open bus 0xFF");
      read_raw(16'h98E0, value);
      if (value !== 8'hFF) fail("0x98E0 is decoded: the machine reads open bus 0xFF");
      if (unmapped_reads != ur0 + 16'd3)
        fail("0x9890/0x9896/0x98E0 reads did not count as unmapped");
      uw0 = unmapped_writes;
      write_byte(16'h98E0, 8'hFF);
      if (unmapped_writes != uw0 + 16'd1)
        fail("0x98E0 write was decoded: it must stay unmapped telemetry");

      // ---- the CPU-mode request behind that bit ------------------------
      // `out 0xF0,<n>` is a CPU-MODE request, and 0x9894 bit 3 is the mode it
      // selects. The firmware is explicit about both ends: the ITF asks for
      // mode 0 at BANK4@0xFA67D (`mov al,0 / out 0xF0,al`) and for mode 1 at
      // BANK4@0xFA682 (`mov al,1 / out 0xF0,al`), and the main BIOS's own
      // mode-change routine reads 0x9894, takes bit 3 and writes exactly that
      // value to 0xF0 (BANK7@0xFD867: `in al,0x9894 / shr al,3 / and al,1 /
      // out 0xF0,al`). The machine reads 0x9894 = 0xF0 with bit 3 clear at a DOS
      // prompt, stably, with no writes -- that is what "strap" means, and
      // the CPU-mode reset spec defines the
      // port that way. The reset's operand is therefore IGNORED here, as both
      // references do (QEMU pc98_reset_pulse_write, NP2kai io/cpuio.c), and
      // 0x9894 must read its strap whatever the write says.
      //
      // The reset itself is asserted here only as "a pulse is requested": the
      // CPU-side effect (the first fetch is the reset vector of the window
      // mapped at that moment, with A20 wrapped at 1 MiB) is a property of the
      // CPU and the address map, and those are measured by tb_pc9821_boot and
      // tb_pc9821_userdisk.
      read_byte(16'h9894, 8'hF0);        // the measured strap, bit 3 clear
      reset_pulses = 0;
      bank_before = top_bank;
      // Re-capture the telemetry counters: the block above deliberately reads
      // and writes the three undecoded ports (0x9890/0x9896/0x98E0) to assert
      // that they stay unmapped.
      ur0 = unmapped_reads;
      uw0 = unmapped_writes;
      write_byte(16'h00F0, 8'h01);       // the operand is not the strap
      if (reset_pulses == 0) fail("out 0xF0 did not request a CPU reset");
      if (a20_enable) fail("out 0xF0 did not mask A20");
      read_raw(16'h9894, value);
      if (value !== 8'hF0)
        fail("out 0xF0 moved the 0x9894 strap: it is a strap, not a latch");
      // The reset class is a CPU-ONLY reset: the machine's own mode-change
      // routine saves MSW and ss:sp, requests it and resumes at CS:0x74 after
      // (BANK7@0xFD867/0xFD874), so RAM, the ROM window and every latch must
      // survive it. Asserted for the latches that decide what the next fetch
      // reads and where it lands.
      if (top_bank !== bank_before)
        fail("out 0xF0 moved the ROM window bank");
      read_byte(16'h00F0, 8'hA9);        // the port's own read is unchanged
      read_byte(16'h9892, 8'hF0);
      read_byte(16'h043F, 8'hC4);
      if (unmapped_writes != uw0 || unmapped_reads != ur0)
        fail("out 0xF0 traffic counted as unmapped");
      // Both request values the firmware uses, and neither may move the strap.
      write_byte(16'h00F0, 8'h00);
      read_raw(16'h9894, value);
      if (value !== 8'hF0)
        fail("out 0xF0,0 moved the 0x9894 strap");
    end

    // ---- newly decoded ports -------------------------------
    // Each of these is real firmware traffic that used to fall through to open
    // bus and inflate the boot-stop telemetry. Assert both the honest value and
    // that the unmapped counters do not move.
    begin
      integer ur0, uw0;
      ur0 = unmapped_reads;
      uw0 = unmapped_writes;

      // 0x3FDB/0x3FDF is the PIT alias the authentic ITF's timer self-test uses
      // (BANK4@0x373). In this bench device_io_dout stands in for the PIT, so
      // the assertion is that the port is decoded at all.
      read_raw(16'h3FDB, value);
      read_raw(16'h3FDF, value);

      // Measured straps/latches.
      read_byte(16'h063D, 8'hEC);          // bit 6 set (do NOT use QEMU's 0x04)
      read_byte(16'h063E, 8'hFE);
      read_byte(16'h063F, 8'h6C);
      write_byte(16'h063F, 8'h55);
      read_byte(16'h063F, 8'h55);
      read_byte(16'h0436, 8'h04);
      read_byte(16'h0439, 8'hB4);

      // 0x610 is the ITF's per-stage POST marker: it must LATCH (the machine's
      // own ITF writes it, and the watchdog's U= field names the stage from it),
      // and the same value must appear on the telemetry output. The GUEST READ is
      // open bus 0xFF, not the latch: probe2 /RDBACK wrote 0x1A and read FF
      // (`port=0610 before=FF wrote=1A after=FF back=FF`, docs/probes/RDBACK.TXT:161).
      write_byte(16'h0610, 8'h1F);
      read_byte(16'h0610, 8'hFF);
      if (dbg_itf_stage !== 8'h1F) begin
        $display("FAIL 0x610 did not reach the telemetry: dbg_itf_stage=%02x",
                 dbg_itf_stage);
        errors = errors + 1;
      end

      // The DMA address/count register PAIRS (BANK4@0x3E9). The ITF writes each
      // of these ports TWICE and reads it TWICE, requiring both reads to match:
      // four accesses per register, which returns the chip's ONE shared byte
      // flip-flop to the parity it entered with at every register boundary, and
      // because both writes carry the same byte both halves hold it. The earlier
      // ONE-write/ONE-read form here encoded eight independent latches, which is
      // not what a uPD71071 is -- and worse, it passed under BOTH models, so it
      // could never have caught the difference. tb_pc9821_dma_regs pins the pairs
      // and the flip-flop; this replay keeps the firmware's own requirement.
      write_byte(16'h0001, 8'hFF); write_byte(16'h0001, 8'hFF);
      read_byte(16'h0001, 8'hFF);  read_byte(16'h0001, 8'hFF);
      write_byte(16'h0001, 8'h00); write_byte(16'h0001, 8'h00);
      read_byte(16'h0001, 8'h00);  read_byte(16'h0001, 8'h00);
      write_byte(16'h000F, 8'hA5); write_byte(16'h000F, 8'hA5);
      read_byte(16'h000F, 8'hA5);  read_byte(16'h000F, 8'hA5);

      // 0x534 is the cold/warm + soft-reset latch: read 0xEC, and a write with
      // bit 0 set asks for a reset and masks A20.
      read_byte(16'h0534, 8'hEC);
      reset_pulses = 0;
      write_byte(16'h0534, 8'h00);
      if (reset_pulses != 0) fail("0x534 write without bit 0 requested a reset");
      write_byte(16'h0534, 8'h01);
      if (reset_pulses == 0) fail("0x534 bit 0 did not request a reset");
      if (a20_enable) fail("0x534 soft reset did not mask A20");

      // ---- the CPU's own SHUTDOWN is the same CPU-reset class ------------
      // z486 asserts triple_fault_reset when a fault arrives while #DF is being
      // delivered -- the CPU's reset pin. The machine must take that as the
      // same CPU-reset class 0xF0/0x534 request: raise cpu_reset_req and mask
      // A20, and move NOTHING else -- RAM, the ROM window and the latches
      // survive, which is what the firmware's resume frame needs
      // (BANK7@0xFD867). Before an earlier fix this request left the core as BUTTONS[1]
      // and came back only through the HPS.
      write_byte(16'h00F6, 8'h02);        // release A20: the mask must be the
      if (!a20_enable) fail("0xF6 did not release A20 before the shutdown");
      begin : shutdown_reset
        reg [3:0] bank_tf;
        reg [7:0] win_tf;
        bank_tf = top_bank;
        win_tf  = win0_sel;
        reset_pulses = 0;
        @(negedge clk);
        triple_fault_reset = 1'b1;
        @(negedge clk);
        triple_fault_reset = 1'b0;
        repeat (2) @(negedge clk);
        if (reset_pulses == 0)
          fail("the CPU shutdown did not request a CPU reset");
        if (a20_enable)
          fail("the CPU shutdown did not mask A20");
        if (top_bank !== bank_tf)
          fail("the CPU shutdown moved the ROM window bank");
        if (win0_sel !== win_tf)
          fail("the CPU shutdown moved window 0");
      end
      write_byte(16'h00F2, 8'h00);        // leave A20 released, as before

      // ARTIC timestamp counter: two reads separated by hundreds of clocks
      // must differ, which a constant cannot do. 0x5D and 0x5E mirror the same
      // byte on the machine (NP2kai artic.c attaches both to cnt[15:8]).
      read_raw(16'h005C, value);
      repeat (400) @(posedge clk);
      read_raw(16'h005D, value);
      if (value === 8'hFF) fail("ARTIC 0x5D read open bus");
      read_raw(16'h005E, value);

      // ---- the four ports the watchdog's U= field named (r11) --------------
      // The bus mouse: a uPD8255 PPI at 0x7FD9-0x7FDF whose Port B is the one
      // register this firmware reads. Both references return 0x40 while Port B
      // is an input -- NP2kai io/mouseif.c's mouseif_i7fdb tests the mode word
      // (uPD8255_PORTB, lsidef.h:11) and its mouseif_reset leaves mode = 0x93,
      // and QEMU hw/input/pc98-mouse.c's header says "0x7FDB Port B read:
      // status (reads 0x40 while configured as input)" with the same reset. The
      // ITF's branch is BANK4@0xF824E (`in al,dx / test al,0x40`), which picks
      // 0x80 for 0x43F when bit 6 is set. Port A is the attached-idle byte
      // (QEMU composes `(buttons & 0xf0) | 0x40`, and Linux pc98busmouse.c shows
      // the button bits inverted, so released = 1) composed with the power-up
      // latch = -1 nibble (mouseif_reset:325-326) = 0xEF, and the 8255 control
      // word at 0x7FDF is write-only in both references. Port C is the LIVE
      // latch through NP2kai's mouseif_i7fdd mode mask:
      // with the mode word 0x93 the C-lower input replaces the low nibble with
      // 0x08 and the three DIP strap bits mouseif.c:296-303 computes from the
      // software-DIP bank (all clear over the measured 0x841E = 0x7C /
      // 0x8E1E = 0x49 image), so the 0xF0 power-up latch reads 0xF8. The full
      // read model (mode
      // masking, the porta echo while A is an output, the BSR form, and the
      // mode write's Port C reset) is pinned by tb_pc9821_readback_sysports.
      read_byte(16'h7FDB, 8'h40);
      read_byte(16'h7FD9, 8'hEF);
      read_byte(16'h7FDD, 8'hF8);
      read_byte(16'h7FDF, 8'hFF);
      // ...and the rest of the PPI the firmware drives: 0x7FDD/0x7FDF at
      // BANK4@0xFC5BF/0xFC5C5 (0xFF then mode 0x93), 0x7FDB at BANK4@0xFCAB3,
      // the 0x7FDF bit-set/reset form at BANK4@0xFCA9B, and the 0xBFDB timer
      // alias at BANK7@0x59C6. The PPI writes latch now (the reads above are
      // live); the 0xBFDB write is pc9821_mouse's timing field (dat & 3,
      // mouseif_obfdb:309-312), and none of
      // the five may be counted as unmapped traffic.
      write_byte(16'h7FDD, 8'hFF);
      read_byte(16'h7FDD, 8'hF8);   // the firmware's own 7FDD=FF: the latch | strap
      write_byte(16'h7FDF, 8'h93);
      write_byte(16'h7FDB, 8'h00);
      write_byte(16'hBFDB, 8'h08);
      // The CG-ROM port block's 0xA7: the POST writes it three times
      // (BANK4@0xFC103, 0xFC2F7, 0xFC2FB) and no firmware site reads it. The
      // machine answers open bus there with no writes (probes/R10.TXT 00A7=FF
      // in all four captured states), so the read is 0xFF and the write must not
      // be counted. (The fourth site the notes name, BANK6@0x1DCB, is the
      // operand of the `call rel16` at BANK6@0x1DCA, not a port access.)
      write_byte(16'h00A7, 8'h01);
      write_byte(16'h00A7, 8'hFE);
      read_byte(16'h00A7, 8'hFF);
      // The DMA controller's extended bank registers and the 0x0E00/0x0E02 word
      // pair plus 0x0E0F the firmware zeroes with them (BANK4@0xFCB81, and the
      // dormant BANK2@0x0005). QEMU hw/dma/pc98-dma.c marks the four per-channel
      // registers write-only and neither reference gives any of them a read, so
      // 0x0E0F reads the open bus this fabric already answers with.
      write_byte(16'h0E05, 8'h00);
      write_byte(16'h0E00, 8'h00);
      write_byte(16'h0E0F, 8'h00);
      read_byte(16'h0E0F, 8'hFF);
      // The accelerator's index/data pair, written by the firmware as a 16-bit
      // `out dx,ax` to 0xFAA (BANK4@0xFD28F/0xFD3AE/0xFD3C6/0xFD3E4), which is
      // why the telemetry's last-unmapped-port field held 0x0FAB -- the odd
      // lane of a two-byte write. Both references name 0xFAB as the pair's data
      // byte (QEMU hw/display/pc98-wab.c) and give neither a read; 0xFAC is the
      // display-relay latch the firmware writes at BANK4@0xFD27B. A 16-bit
      // write here is two byte lanes, so 0xFAB must be decoded for the pair to
      // stop being reported.
      write_byte(16'h0FAA, 8'h03);
      write_byte(16'h0FAB, 8'h00);
      write_byte(16'h0FAC, 8'h00);
      read_byte(16'h0FAB, 8'hFF);
      // The telemetry field itself is the contract: none of the four may appear
      // in it, because the field names the port a boot stopped on.
      if (last_unmapped_port == 16'h7FDB || last_unmapped_port == 16'h00A7 ||
          last_unmapped_port == 16'h0E0F || last_unmapped_port == 16'h0FAB)
        fail("a decoded port is still the last unmapped port");

      if (unmapped_reads != ur0 || unmapped_writes != uw0) begin
        $display("FAIL decoded ports still incremented unmapped counters rd %0d->%0d wr %0d->%0d",
                 ur0, unmapped_reads, uw0, unmapped_writes);
        errors = errors + 1;
      end
    end

    // ---- the ports the machine answers and this core used to float --
    // Ten read arms plus one device-routing entry. Every value is a machine
    // capture, not an inference: probes/PORTS.TXT (2026-09-12, the fixed probe's
    // read-only sweep) and probes/R10.TXT (the hardened probe). Before this
    // change each read the open bus 0xFF, so a guest enumerating the surface saw
    // phantom-open registers where the machine drives a byte.
    begin
      integer ur0, uw0;
      ur0 = unmapped_reads;
      uw0 = unmapped_writes;

      // 0x09A8: the 24/31 kHz select latch beside 0x9A0. Its power-up read is the
      // machine's 0x00 (probes/R10.TXT snapshot `09A8=00 09A9=FF` and
      // probes/PORTS.TXT `09A8 00`); the write round-trip is tb_pc9821_readback_sysports'.
      read_byte(16'h09A8, 8'h00);
      // 0x98D7: the mouse IRQ register (Linux pc98 std_resources.c reserves it
      // as "mouse irq"). The machine reads 0x0D, twice, with no writes
      // (probes/R10.TXT /MODE, `98D7=0D 0D`). No firmware site READS it -- the
      // ITF only writes it (BANK4@0xFC991) -- so this arm is fidelity, not a
      // boot fix. The write stays accepted-and-ignored, which the second read
      // pins.
      read_byte(16'h98D7, 8'h0D);
      write_byte(16'h98D7, 8'hFF);
      read_byte(16'h98D7, 8'h0D);

      // 0x0040: the printer data port. The machine reads 0x00
      // (probes/PORTS.TXT `0040 00`), in one state (a DOS prompt with no printer
      // session).
      read_byte(16'h0040, 8'h00);

      // The uPD71071 DMA controller's read ports, answered by THE REAL ENGINE now
      // (pc9821_dmac, instantiated in pc9821_iobus): 0x01..0x29 are its register window
      // and these are its power-up bytes. The machine's 0x00 is a DRIVEN value, not bus
      // float: 0x11/0x1B read 0x00 while their odd neighbours 0x13/0x1D read 0xFF, and
      // 0x21/0x23/0x27/0x29 read 0x00 while 0x24/0x26 read 0xFF (probes/PORTS.TXT
      // `0011 00`, `001B 00`, `0021 00`, `0023 00`, `0027 00`, `0029 00`).
      read_byte(16'h0011, 8'h00);
      read_byte(16'h001B, 8'h00);
      read_byte(16'h0021, 8'h00);
      read_byte(16'h0023, 8'h00);
      read_byte(16'h0027, 8'h00);
      read_byte(16'h0029, 8'h00);
      // 0x13/0x15/0x17/0x1D/0x1F are the engine's write-only software-request, mask, mode
      // and mask-command registers; the machine drives 0xFF there and so does the module.
      read_byte(16'h0013, 8'hFF);
      read_byte(16'h0015, 8'hFF);
      read_byte(16'h0017, 8'hFF);
      read_byte(16'h001D, 8'hFF);
      read_byte(16'h001F, 8'hFF);
      // 0x25 reads the PRE-FIX PORTS capture's 0x0E (`0025 0E`, ONE sample; the hardened
      // R10.TXT does not sample it), and the stub used to seed that byte directly. With
      // the real chip the register file comes up at ITS reset state - 0x00 - because the
      // 0x0E the machine showed was DOS's own programming of the channel DOS transfers on,
      // which a core with no guest traffic cannot replay. The LATCH was always the
      // capture-proven part; the seed was a stand-in for the engine, and the engine is here.
      read_byte(16'h0025, 8'h00);

      // The ATA second channel's task file (0x740-0x74A) is a device port, so
      // it must route to the ATA module through pc9821_system's ata_cs. This
      // bench's device stub proves the routing: the byte comes from
      // device_io_dout (0xC3 here), not from the fabric's open bus.
      read_raw(16'h0740, value);
      if (value !== 8'hC3) begin
        $display("FAIL 0x740 is not routed to the device bus: got %02x", value);
        errors = errors + 1;
      end

      if (unmapped_reads != ur0 || unmapped_writes != uw0) begin
        $display("FAIL the newly answered ports still incremented unmapped counters rd %0d->%0d wr %0d->%0d",
                 ur0, unmapped_reads, uw0, unmapped_writes);
        errors = errors + 1;
      end
    end

    // ---- 0x043B bit 2: the 15-16 MiB system-space hole -------------
    // The bit is the hole's REQUEST and it is INVERTED from the enable it drives:
    // SET asks for RAM at 15-16 MiB, CLEAR enables the hole. NP2kai issue #107
    // prints exactly that (bit 2 set = "Memory hole at 15-16MB not enabled") and
    // qemu keys it the same way (`enable = !(data & 0x04)`, pc98-mem.c
    // mem_sys16m_write). Reset leaves the hole OFF, so 15-16 MiB is RAM.
    if (sys16m_en !== 1'b0) begin
      $display("FAIL 0x043B reset: sys16m_en=%b, want 0 (hole off: 15-16 MiB is RAM)", sys16m_en);
      errors = errors + 1;
    end
    // A 0x043B write that MOVES the bit remaps 0xF00000-0xFFFFFF (RAM <->
    // PEGC window / hole / low-memory mirror) and the peg_high alias at
    // 0xFFF00000-0xFFF7FFFF under cached L1 lines, so the write must pay for a
    // sweep of BOTH remapped ranges before it completes:
    // 65536 lines over 0xF00000-0xFFFFFF plus 32768 over the peg_high alias.
    clear_flush_log();
    write_byte(16'h043B, 8'h00);   // CLEAR = the guest enables the hole
    if (sys16m_en !== 1'b1) begin
      $display("FAIL 0x043B=0x00: sys16m_en=%b, want 1 (the hole is enabled there)", sys16m_en);
      errors = errors + 1;
    end
    check_flush_once("0x043B sys16m remap sweep");
    // A write that leaves the bit alone is not a mapping change and must not
    // pay for the sweep, exactly as 0x043D/0x0461/0x053D are guarded.
    clear_flush_log();
    write_byte(16'h043B, 8'h00);
    if (flush_pulses != 0) begin
      $display("FAIL redundant 0x043B = 0x00 emitted %0d flush request(s)", flush_pulses);
      errors = errors + 1;
    end
    // THE ITF'S OWN STAGE-0x25 WRITE (BANK4@0xF8906): 0x04 immediately before its
    // memory test, asking for RAM back at 15-16 MiB. Reading the bit straight
    // through instead put the hole where the test expected RAM.
    write_byte(16'h043B, 8'h04);
    if (sys16m_en !== 1'b0) begin
      $display("FAIL 0x043B=0x04: sys16m_en=%b, want 0 (RAM at 15-16 MiB, what the memory test needs)",
               sys16m_en);
      errors = errors + 1;
    end
    // A byte whose bit 2 is clear among others still enables the hole.
    write_byte(16'h043B, 8'hFB);
    if (sys16m_en !== 1'b1) begin
      $display("FAIL 0x043B=0xFB: sys16m_en=%b, want 1 (bit 2 clear)", sys16m_en);
      errors = errors + 1;
    end
    // The read-back FOLLOWS the live bit-2 request now (NP2kai's necio echo,
    // io/necio.c:24-27): 0x00 reads the machine's 0xFB
    // and 0x04 reads 0xFF - the "0xFF/0xFB class" the P4 confirm-method expects,
    // and what makes a guest RMW of 0x043B round-trip instead of reading a stale
    // constant. FAIL-FIRST: the second read was 0xFB under the constant.
    read_byte(16'h043B, 8'hFB);
    write_byte(16'h043B, 8'h04);
    read_byte(16'h043B, 8'hFF);
    write_byte(16'h043B, 8'h00);
    read_byte(16'h043B, 8'hFB);
  // ==== VERDICT ====

    // ---- EGC register decode, 0x04A0-0x04AE ----
    // The read half was already right and stays right: the machine answers open
    // bus at all sixteen ports (the machine's probe results) and
    // NP2kai attaches out handlers only (NP2kai/io/egc.c:101-107), so a test that
    // makes the register file readable is a regression.
    begin
      integer ur0, uw0;
      ur0 = unmapped_reads; uw0 = unmapped_writes;
      for (integer p = 0; p < 16; p = p + 1) read_byte(16'h04A0 + p, 8'hFF);
      // ... and the ports are decoded, so a guest write there is not telemetry
      // noise. That is what the defect report is about: they read as *undecoded*
      // ports and the write counter named them.
      write_byte(16'h04A4, 8'h00);
      if (unmapped_writes != uw0 || last_unmapped_port == 16'h04A4)
        fail("0x04A4 is still an unmapped port");
      if (unmapped_reads != ur0) fail("the EGC read arm incremented unmapped_reads");
    end

    // While the EGC is off, the register file is write-only in the other
    // direction too: every write is dropped, which is NP2kai's gate
    // (`if (!(vramop.operate & (1<<VOPBIT_EGC))) return;`, io/egc.c:24) and the
    // contract the module states.
    begin
      egc_gate = 1'b0;
      @(negedge clk);
      write_word(16'h04A4, 16'h3100);
      write_word(16'h04A0, 16'hFFF0);
      write_word(16'h04AE, 16'h000F);
      if (egc_ope !== 16'h0000)
        fail("0x4A4 latched with the EGC gate off");
      if (egc_access !== 16'hFFF0)
        fail("0x4A0 latched with the EGC gate off");   // still the power-up value
    end

    // With the gate on, the 16-bit `out dx,ax` form latches both halves in the
    // order the firmware and the games use it (low byte at the even port, high
    // byte at the odd one -- NP2kai egc_o4a0 cases 0x00/0x01).
    begin
      egc_gate = 1'b1;
      @(negedge clk);
      write_word(16'h04A4, 16'h3100);
      if (egc_ope !== 16'h3100) begin
        $display("FAIL 0x4A4 = 0x3100 read back as %04x", egc_ope);
        errors = errors + 1;
      end
      write_word(16'h04A0, 16'hFFF0);
      if (egc_access !== 16'hFFF0) begin
        $display("FAIL 0x4A0 = 0xFFF0 read back as %04x", egc_access);
        errors = errors + 1;
      end
      write_word(16'h04A2, 16'h00FF);
      // The two COLOUR registers are gated the other way round from 0x4A8: 0x4A6/0x4AA take a
      // write only while 0x4A2's bits 13-14 name FG / BG, and are DROPPED while the pattern comes
      // from PAT (EGCWRITE.CSV W00_FG_x / W01_BG_x, docs/probes/egc-conformance; tb_pc9821_egc_regs
      // section D replays those rows). NP2kai's egc_o4a0 writes them unconditionally.
      write_word(16'h04A2, 16'h4000);
      write_word(16'h04A6, 16'h000A);
      write_word(16'h04A2, 16'h2000);
      write_word(16'h04AA, 16'h0005);
      write_word(16'h04A2, 16'h00FF);
      if (egc_fgbg !== 16'h00FF) begin
        $display("FAIL 0x4A2 latched as %04x", egc_fgbg);
        errors = errors + 1;
      end
      if (egc_fg !== 16'h000A || egc_bg !== 16'h0005) begin
        $display("FAIL 0x4A6/0x4AA latched as %04x/%04x", egc_fg, egc_bg);
        errors = errors + 1;
      end
      // 0x4A8 is gated by 0x4A2's foreground/background colour field: with
      // bits 13-14 non-zero the mask register is NOT writable (NP2kai egc_o4a0
      // case 0x08/0x09). The firmware's own 0x1400 fill sets 0x4A2 = 0x40FF and
      // never writes 0x4A8 (BANK7.BIN@0x35A1), so this gate is load-bearing.
      // The two directions are separate assertions so the mask check cannot
      // "fail" merely because the 0x4A2 write above was dropped.
      write_word(16'h04A8, 16'h1234);
      if (egc_mask !== 16'h1234) begin
        $display("FAIL 0x4A8 did not latch with 0x4A2 = 0x00FF (%04x)", egc_mask);
        errors = errors + 1;
      end
      write_word(16'h04A2, 16'h40FF);
      if (egc_fgbg !== 16'h40FF) begin
        $display("FAIL 0x4A2 = 0x40FF latched as %04x", egc_fgbg);
        errors = errors + 1;
      end
      write_word(16'h04A8, 16'hABCD);
      if (egc_mask !== 16'h1234) begin
        $display("FAIL 0x4A8 latched while 0x4A2 selected a colour quad (%04x)", egc_mask);
        errors = errors + 1;
      end
      // 0x4AC/0x4AE reload the shifter (NP2kai egcshift) and nothing else in the
      // file has a side effect, so the pulse count is exact: one per byte lane
      // written, and a 16-bit write is two lanes.
      egc_shift_pulses = 0;
      write_word(16'h04AC, 16'h0300);
      write_word(16'h04AE, 16'h027F);
      if (egc_sft !== 16'h0300 || egc_leng !== 16'h027F) begin
        $display("FAIL 0x4AC/0x4AE latched as %04x/%04x", egc_sft, egc_leng);
        errors = errors + 1;
      end
      if (egc_shift_pulses != 4) begin
        $display("FAIL the shifter reload pulsed %0d times, want 4", egc_shift_pulses);
        errors = errors + 1;
      end
      egc_gate = 1'b0;
      @(negedge clk);
      // Back to the power-up image for the rest of the bench (the gate is off,
      // so this is a reset-only contract; nothing below reads these).
      write_word(16'h04A0, 16'hFFF0);
    end

    // ---- the MACHINE-RESET seed on the software-DIP store ----
    // The store is a battery-backed image on the machine and this module's `initial` block is
    // its power-up content - but `initial` runs at CONFIGURATION time, so a PLATFORM reset used
    // to leave the store exactly as the firmware and the guest had left it, and the ITF installs
    // its factory image over a bank whose bytes fail its odd-parity verify. The observed
    // consequence (a reset brings the SET THE SOFTWARE DIP-SWITCH message back), and the
    // strobe this bench calls `reset` IS the core's machine-reset strobe (`reset || !cpu_run` at
    // the pc9821_system instance), so the contract is checked here, at the store.
    begin
      integer k, wrong, partial_seen;

      // (1) A GUEST write moves the store off the power-up image - the precondition that makes
      // the restore assertion mean something. Index 4 (0x881E, mask 0x7F) reads 0x7C in the
      // image; index 5 (0x891E) holds 0x7F.
      write_byte(16'h8F1F, 8'h80);       // reopen the write gate (bank A)
      write_byte(16'h881E, 8'h2A);
      write_byte(16'h891E, 8'h00);
      @(negedge clk);
      if (dut.sdip[4] !== 8'h2A || dut.sdip[5] !== 8'h00)
        fail("the machine-reset seed check is vacuous: the guest writes never moved the store");

      // (2) A reset pulse SHORTER than the 24-byte walk. The walk must survive the release and
      // the CPU must be held for the whole of it: this is the case where a "working" seed still
      // leaves the ITF reading a half-seeded bank.
      gate_high_while_seeding = 1'b0;
      seed_monitor_armed = 1'b1;
      reset = 1'b1;
      repeat (3) @(posedge clk);
      reset = 1'b0;
      @(negedge clk);
      if (!dut.sdip_seq_active)
        fail("the machine-reset strobe did not start the DIP store walk");
      if (!cpu_reset_req)
        fail("the seed walk is running and the CPU's reset hold was NOT requested");
      partial_seen = 0;
      while (dut.sdip_seq_active) begin
        @(posedge clk);
        if (!cpu_reset_req)
          fail("the CPU-reset hold dropped while the seed walk was still running");
        // The walk is byte-at-a-time, so a reader landing here WOULD see a partial bank. This
        // asserts that rather than assuming it - a walk that finished in one cycle would make
        // the hold check above vacuous.
        if (dut.sdip_seq_idx <= 5'd5 && dut.sdip[4] === 8'h2A) partial_seen = 1;
      end
      if (!partial_seen)
        fail("the walk was never observed with the store still partly corrupt: the hold check is vacuous");
      if (gate_high_while_seeding)
        fail("the CPU's reset_n was high while the store walk was writing it");

      // (3) The store is the power-up image again, byte for byte, and it reads back through the
      // ports the ITF reads (its verifier's first two ports are bank A 0x84 and 0x85).
      @(negedge clk);
      wrong = 0;
      for (k = 0; k < 24; k = k + 1)
        if (dut.sdip[k] !== sdip_powerup_shadow[k]) wrong = wrong + 1;
      if (wrong != 0) begin
        $display("FAIL the machine-reset seed left %0d of 24 store bytes off the power-up image", wrong);
        errors = errors + 1;
      end
      read_byte(16'h881E, 8'h7C);
      read_byte(16'h891E, 8'h7F);
      read_byte(16'h841E, 8'h7C);              // the measured machine byte

      // (4) A reset window LONGER than the walk - which is every real one (a reload's seconds,
      // an OSD reset's SDRAM calibration). The walk then finishes INSIDE the window, the CPU's
      // boot is not delayed by a single cycle, and the golden boot cannot move. That is the whole
      // reason the walk starts at the ASSERTION rather than at the release.
      write_byte(16'h8F1F, 8'h80);       // the reset in (2) closed the gate
      write_byte(16'h881E, 8'h2A);
      @(negedge clk);
      reset = 1'b1;
      repeat (40) @(posedge clk);
      reset = 1'b0;
      repeat (3) @(posedge clk);
      if (dut.sdip_seq_active)
        fail("a reset window longer than the walk left the walk running at the release");
      if (cpu_reset_req)
        fail("a reset window longer than the walk still asked for a CPU-reset hold: the boot golden would move");
      wrong = 0;
      for (k = 0; k < 24; k = k + 1)
        if (dut.sdip[k] !== sdip_powerup_shadow[k]) wrong = wrong + 1;
      if (wrong != 0) begin
        $display("FAIL the long-window seed left %0d of 24 store bytes off the power-up image", wrong);
        errors = errors + 1;
      end
      // The seed is an event on the STORE, not a new write gate or a persistent load: the guest's
      // own write still lands afterwards, so the ITF's write-and-verify path is not fought.
      write_byte(16'h8F1F, 8'h80);
      write_byte(16'h881E, 8'h2A);
      read_byte(16'h881E, 8'h2A);
      @(negedge clk);
      if (dut.sdip[4] !== 8'h2A || dut.sdip_seq_active)
        fail("the machine-reset seed is still overwriting the store after it completed");
    end

    if (errors == 0) begin
        $display("TB_PC9821_IOBUS: PASS");
        $finish;
    end
    else $fatal(1, "TB_PC9821_IOBUS: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog. The runner also bounds wall time
  // (BENCH_TIMEOUT) and greps the PASS marker, but a bench that
  // blocks on a DUT signal with no bound would hang CI forever.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_IOBUS: TIMEOUT");
  end

endmodule

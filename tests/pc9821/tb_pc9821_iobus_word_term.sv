`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_IOBUS_WORD_TERM: a 16- or 32-bit IN at a byte port answers as the real Xe10 does (docs/probes/XE10T-XE10-AUDIT.TXT, the W/P/D rows of XE10T /AUDIT), through the real pc9821_iobus: at an even port of the terminated set (0x30-0x36/0x40-0x46 even and 0x7C with high byte 0xFF; 0x20, 0x22, 0x26, 0x60-0x7A and 0xA0-0xAC even with high byte 0x00, while 0x24 splits: docs/probes/KIT2-XE10-AUDIT2.TXT W0024 `b0=FF b1=0E w1=0EFF`) port P is read and P+1 is never fetched (`in ax,40h` does not read the keyboard's 0x41, `in ax,70h` leaves the PIT's 0x71 alone, `in ax,7Ch` answers 0xFF:P, `in ax,20h` answers 0x00:P, `in eax,70h` is two terminated words); every other word read is two byte reads P and P+1 with their side effects (`in ax,01h` and `in ax,00h` each toggle the DMAC byte flip-flop, `in ax,71h` reads 0x71 and 0x72, `in ax,0F6h`, `in ax,0D0h` and `in ax,0ADh` answer their two bytes), the set applies only when port bits 11:10 are clear (`in ax,1070h` is terminated, `in ax,0470h` byte-splits), and byte reads are never terminated.
//
// The expected SHAPES are the machine's (the capture's b0/b1 byte reads of P and P+1 beside
// `in ax,P` with EAX preloaded A55AC33C): W0040 `b0=00 b1=9C w1=FF00` and W0030 `b0=FF b1=F3
// w1=FFFF` (AH = FF, 0x41/0x31 not merged), W0060 `b0=05 b1=FF w1=0004` and W00A4 `b0=00
// b1=0F w1=0000` (AH = 00), W0020 `w1=00FF`, W007C `w1=FFFF`, P0070 `w=0000 x1=E9 x2=80` (the
// PIT latch untouched by `in ax,70h`), P0071 `w=0FE7 x1=80` (consumed by `in ax,71h`, AH = 0x72),
// D0001 `w=7D00` and D0000 `w=0000`, both `x1=C3 x2=3C` (the flip-flop toggled), W0021 `b0=00
// b1=EF w1=EF00` and W00AD `b0=FF b1=04 w1=04FF` (split), W00F6 `w1=FF5E` and W00D0 `w1=FF21`
// (no 0x2588, no preloaded C3). The low bytes come from this bench's device stub
// (device_io_dout = 0xC3 for every device-bus port) or from the core's own system ports.
//
// FAIL-FIRST: NP2kai's table (io/iocore16.tbl), which the core followed before, answered 0x2588 at
// 0x01/0xF6 without touching the flip-flop, 0xFF:P at 0x71 and 0xAD without reading P+1, 0x00:P at
// 0x7C and 0x08:P at 0x20.

module tb_pc9821_iobus_word_term;
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
  // Every device-bus read the DUT strobes, in order (the device stub answers 0xC3 to each).
  integer    dev_rd_n = 0;
  reg [15:0] dev_rd_log [0:63];
  always @(posedge clk) begin
    if (device_io_rd) begin
      if (dev_rd_n < 64) dev_rd_log[dev_rd_n] <= device_io_addr;
      dev_rd_n <= dev_rd_n + 1;
    end
  end

  task automatic chk(input bit cond, input string msg);
    begin
      if (!cond) begin
        $display("FAIL %0s", msg);
        errors = errors + 1;
      end
    end
  endtask

  // `in eax,P` with P dword-aligned.
  task automatic read_dword(input [15:0] portnum, input [31:0] expected);
    begin
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b1111;
      cpu_write = 0;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      #1;
      if (!cpu_resp_valid || cpu_dout !== expected) begin
        $display("FAIL read32 %04x got=%08x want=%08x", portnum, cpu_dout, expected);
        errors = errors + 1;
      end
      @(negedge clk);
      cpu_valid = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  integer n0;
  integer u0;
  reg [7:0] b_lo, b_hi;

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // ---- SPLIT: two byte reads, P then P+1, side effects included -------------------
    // The DMAC channel-0 address (0x01) through its byte flip-flop: low then high, which
    // leaves the flip-flop on the low byte.
    write_byte(16'h0001, 8'h34);
    write_byte(16'h0001, 8'h12);
    // D0001: `in ax,01h` reads 0x01 (the low byte, toggling the flip-flop) then the PIC's 0x02.
    n0 = dev_rd_n;
    read_word(16'h0001, 16'hC334);
    chk(dev_rd_n == n0 + 1 && dev_rd_log[n0] == 16'h0002, "in ax,01h did not read the PIC's 0x02");
    read_byte(16'h0001, 8'h12);          // the flip-flop moved once: the high byte is next
    // D0000: `in ax,00h` reads the PIC's 0x00 and then 0x01, so it toggles the flip-flop too.
    n0 = dev_rd_n;
    read_word(16'h0000, 16'h34C3);
    chk(dev_rd_n == n0 + 1 && dev_rd_log[n0] == 16'h0000, "in ax,00h did not read the PIC's 0x00");
    read_byte(16'h0001, 8'h12);
    // P0071: `in ax,71h` reads the PIT's 0x71 and 0x72.
    n0 = dev_rd_n;
    read_word(16'h0071, 16'hC3C3);
    chk(dev_rd_n == n0 + 2 && dev_rd_log[n0] == 16'h0071 && dev_rd_log[n0 + 1] == 16'h0072,
        "in ax,71h did not read 0x71 and then 0x72");
    // W00F6, W00F2, W00D0, W00AD, W0021: the two bytes, whatever they are.
    read_raw(16'h00F6, b_lo); read_raw(16'h00F7, b_hi); read_word(16'h00F6, {b_hi, b_lo});
    read_raw(16'h00F2, b_lo); read_raw(16'h00F3, b_hi); read_word(16'h00F2, {b_hi, b_lo});
    read_raw(16'h00D0, b_lo); read_raw(16'h00D1, b_hi); read_word(16'h00D0, {b_hi, b_lo});
    read_raw(16'h00AD, b_lo); read_raw(16'h00AE, b_hi); read_word(16'h00AD, {b_hi, b_lo});
    read_raw(16'h0021, b_lo); read_raw(16'h0022, b_hi); read_word(16'h0021, {b_hi, b_lo});
    // AUDIT2 W0024 (docs/probes/KIT2-XE10-AUDIT2.TXT:54, `b0=FF b1=0E w1=0EFF`): 0x24 splits,
    // 0x25 read above it. 0x25 (a DMA bank latch, internal to the bus) is given the machine's 0E
    // so the high byte can tell a split from the 00 term.
    write_byte(16'h0025, 8'h0E);
    read_raw(16'h0024, b_lo); read_raw(16'h0025, b_hi);
    chk(b_hi == 8'h0E, "0x25 does not read back the 0E written to it");
    read_word(16'h0024, {b_hi, b_lo});
    // A dword over 0xF0-0xF3 is four byte reads (W00F0 d=FFFEFF89: 0xF0, 0xF1, 0xF2, 0xF3).
    begin : f0dword
      reg [7:0] f0, f1, f2, f3;
      read_raw(16'h00F0, f0); read_raw(16'h00F1, f1); read_raw(16'h00F2, f2); read_raw(16'h00F3, f3);
      read_dword(16'h00F0, {f3, f2, f1, f0});
    end

    // ---- TERMINATED, high byte 0xFF ------------------------------------------------------
    // W0040: 0x40 is the printer data latch, 0x00 out of reset (PORTS.TXT `0040 00`).
    n0 = dev_rd_n;
    read_word(16'h0040, 16'hFF00);
    chk(dev_rd_n == n0, "in ax,40h read the keyboard's 0x41");
    // W007C: the GRCG mode port, its 0x7D lane not fetched.
    n0 = dev_rd_n;
    read_word(16'h007C, 16'hFFC3);
    chk(dev_rd_n == n0 + 1 && dev_rd_log[n0] == 16'h007C, "in ax,7Ch did not read exactly 0x7C");

    // ---- TERMINATED, high byte 0x00 ------------------------------------------------------
    // P0070: the PIT's 0x71 is not touched by `in ax,70h`.
    n0 = dev_rd_n;
    read_word(16'h0070, 16'h00C3);
    chk(dev_rd_n == n0 + 1 && dev_rd_log[n0] == 16'h0070,
        "in ax,70h did not read exactly 0x70 (the PIT's 0x71 must not be fetched)");
    // W0060 (d=00FF0004): a dword is two terminated words, 0x60 and 0x62.
    n0 = dev_rd_n;
    read_dword(16'h0060, 32'h00C3_00C3);
    chk(dev_rd_n == n0 + 2 && dev_rd_log[n0] == 16'h0060 && dev_rd_log[n0 + 1] == 16'h0062,
        "in eax,60h did not read exactly 0x60 and 0x62");
    n0 = dev_rd_n;
    read_dword(16'h0070, 32'h00C3_00C3);
    chk(dev_rd_n == n0 + 2 && dev_rd_log[n0] == 16'h0070 && dev_rd_log[n0 + 1] == 16'h0072,
        "in eax,70h did not read exactly 0x70 and 0x72");
    // W0020 / W0022 (d=00EF00FF): the calendar's even ports answer 0x00 above P.
    n0 = dev_rd_n;
    read_word(16'h0020, 16'h00C3);
    chk(dev_rd_n == n0 + 1 && dev_rd_log[n0] == 16'h0020, "in ax,20h did not read exactly 0x20");
    // W00A4 (d=00000000).
    n0 = dev_rd_n;
    read_word(16'h00A4, 16'h00C3);
    chk(dev_rd_n == n0 + 1 && dev_rd_log[n0] == 16'h00A4, "in ax,0A4h did not read exactly 0xA4");

    // ---- the 0x0C00 qualifier ----------------------------------------------------------
    // 0x1070: bits 11:10 clear, so the 0x70 entry applies (high byte 0x00) and
    // 0x1071 is not fetched; 0x0470: bit 10 set, so the word splits into two byte reads.
    // Both are undecoded here, so each fetched lane counts in the unmapped-read telemetry.
    u0 = unmapped_reads;
    read_word(16'h1070, 16'h00FF);
    chk(unmapped_reads == u0 + 1, "in ax,1070h fetched its terminated lane");
    u0 = unmapped_reads;
    read_word(16'h0470, 16'hFFFF);
    chk(unmapped_reads == u0 + 2, "in ax,0470h did not split into two byte reads");

    // ---- byte reads are never terminated -----------------------------------------------
    n0 = dev_rd_n;
    read_byte(16'h0071, 8'hC3);
    read_byte(16'h0041, 8'hC3);
    chk(dev_rd_n == n0 + 2 && dev_rd_log[n0] == 16'h0071 && dev_rd_log[n0 + 1] == 16'h0041,
        "a byte read at 0x71 / 0x41 was not fetched");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_IOBUS_WORD_TERM: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_IOBUS_WORD_TERM: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_IOBUS_WORD_TERM: TIMEOUT");
  end

endmodule

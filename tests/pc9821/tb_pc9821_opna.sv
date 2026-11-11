`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OPNA:
// The PC-9801-86's own port behaviour through the real I/O bus: the games' SOUND_O/SOUND_I/WAITREADY sequence, SSG register 7 reading back what was written, register 0x0E answering the joystick, the 0xFF chip ID, and 0x188's BUSY bit clearing within a bounded number of accesses -- which is the property the games' WAITREADY loop hangs on. It also pins the 0xA460 extension gate on 0x18C/0x18E. It asserts the chip's OWN audio output three ways: a programmed SSG tone moves snd_l, a keyed FM channel SWINGS BOTH WAYS (so a slowly drifting, block-0 channel - a silent FM that still moves the output - is a failure), and a triggered ADPCM-A rhythm instrument plays a supplied ROM image. It keys the FM a second time with the key-on first and a register write immediately behind it, and requires the board's timer IRQ line to rise, because a driver clocks the FM from that interrupt. It also keys a channel written through the extended port pair, which is the only path to FM channels 4-6. The FM register bank is written through the vendored core's sample-rate operator scan and was silent under the same back-to-back register writes the SSG tolerates. It does not cover ADPCM-B.


// The DUTs are pc9821_iobus plus pc9821_opna wired exactly as pc9821_system
// wires them, so the sequence runs down the real device path: iobus decodes
// 0x188/0x18A/0x18C/0x18E as device ports, pc9821_system's chip select routes
// them to the OPNA, and the OPNA asks for the one read cycle its registered
// data-out needs. A bench against pc9821_opna alone would not see the decode.

module tb_pc9821_opna;
  // The FM/rhythm audibility bounds (see CHK-11/12): skip this many clk of a window for
  // an earlier note's release, and require a tone to cross +-FM_MIN_SWING.
  localparam integer FM_SETTLE    = 300_000;
  localparam integer FM_MIN_SWING = 2048;

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
  wire [7:0] device_io_dout;
  wire       device_rd_wait;
  wire [3:0] top_bank;
  wire ide_rom_enable, bios_ram_gate, sound_extend;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  reg  [5:0] joystick = 6'b111111;   // the game port's switch lines, released
  // The rhythm ROM's pack-loader write port. This bench fills the ROM with a
  // non-silent ADPCM-A pattern so CHK-12 can require the channel to SOUND; with
  // the port left tied off (as it was) the ROM reads the all-zero code, which
  // the decoder turns into silence by design (src/opna/rhythm_rom/RHYTHM_ROM.v).
  reg         rhythm_we = 1'b0;
  reg  [11:0] rhythm_waddr = 12'd0;
  reg  [15:0] rhythm_wdata = 16'd0;
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

  // The EGC's register file and its gate. This bench drives the sound ports, not
  // the graphics accelerator, so the gate is tied off and the registers are left
  // unread; they are declared because pc9821_iobus carries them (merged
  // with this branch) and the `.*` instantiation below matches ports by name.
  wire        egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg;
  wire [15:0] egc_mask, egc_bg, egc_sft, egc_leng;
  wire        egc_shift_we;
  reg        cal_cdat = 0;
  // The configuration-image seed (pc9821_gdc_text's cfg_* block / pc9821_iobus's memory-switch
  // strap cell): 0 = no seed, which is what this bench wants. tb_pc9821_cg_read_path drives it.
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  reg        triple_fault_reset = 1'b0;

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

  // P5: the chip select is pc9821_iobus's own decode now (the ONE pc9821_device_select
  // instance lives inside it), so `.*` above binds it instead of a local copy.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  // The OSD's I/O timing field (pc9821_iobus io_timing_xe10): Fast, the default table.
  wire io_timing_xe10 = 1'b0;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

  // pc9821_system's device glue, reproduced: the OPNA is selected for its four
  // ports, it is the only device the bus waits a cycle for, and its output is
  // the only byte on the device bus (0xFF otherwise, standing in for the
  // devices this bench does not build).
  wire [7:0] opna_io_dout;
  wire       opna_rd_wait, opna_irq;
  wire signed [19:0] opna_snd_l, opna_snd_r;

  assign device_io_dout = opna_cs ? opna_io_dout : 8'hFF;
  assign device_rd_wait = opna_rd_wait;

  // The clock enable is derived from SYS_CLOCK_HZ; this bench runs at 100 MHz
  // (10 ns period) so the OPNA sees its own 7.9872 MHz.
  pc9821_opna #(.SYS_CLOCK_HZ(100_000_000)) sound (
    .clk(clk), .reset(reset),
    .io_addr(device_io_addr),
    .io_wr(device_io_wr && opna_cs),
    .io_rd(device_io_rd && opna_cs),
    .io_din(device_io_din),
    .io_dout(opna_io_dout),
    .io_rd_wait(opna_rd_wait),
    .extend(sound_extend),
    // The connector's six switch lines, which pc9821_gameport owns; this bench drives
    // them directly (the register's own behaviour is what it tests).
    .joystick(joystick),
    .snd_l(opna_snd_l), .snd_r(opna_snd_r),
    .irq(opna_irq),
    // The rhythm ROM, driven from the pack-loader port this bench owns (CHK-12).
    .rhythm_we(rhythm_we), .rhythm_waddr(rhythm_waddr),
    .rhythm_wdata(rhythm_wdata)
  );

  integer errors = 0;

  task automatic fail(input [8*90-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS ====
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

  task automatic read_byte(input [15:0] portnum, input [7:0] expected,
                           input [8*60-1:0] what);
    reg [7:0] got;
    begin
      read_raw(portnum, got);
      if (got !== expected) begin
        $display("FAIL %0s: read %04x got=%02x expected=%02x",
                 what, portnum, got, expected);
        errors = errors + 1;
      end
    end
  endtask

  // The games' own sequence (rec98 libs/master.lib/soundio.asm:52-56,
  // js_sense.asm:56-69): write the register index to 0x188, the data to 0x18A.
  task automatic sound_o(input [7:0] reg_index, input [7:0] data);
    begin
      write_byte(16'h0188, reg_index);
      write_byte(16'h018A, data);
    end
  endtask

  // The extended bank's register/data pair (0x18C/0x18E), the port pair the
  // card puts FM channels 4-6 behind: jt12_mmr decodes the chip address's high
  // bit as the channel's high bit (jt12_mmr.v:535), and the glue reaches it only
  // when 0xA460 bit 0 is set (pc9821_opna.sv op_sel).
  task automatic sound_x(input [7:0] reg_index, input [7:0] data);
    begin
      write_byte(16'h018C, reg_index);
      write_byte(16'h018E, data);
    end
  endtask

  // ==== CHECKS ====
  reg [7:0]  v;
  reg [7:0]  readback;
  reg        ready;
  integer    n;

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;

    // Let the OPNA's reset stretcher finish (16 clk&cen cycles) before any
    // access: a write while jt12 is held in reset is a design error it traps.
    repeat (2000) @(posedge clk);

    // ---- 1. the idle status has BUSY clear ------------------------------
    // The games' WAITREADY (`in AL,DX; test AL,80h; jnz LO`) runs before
    // every register access, so 0x188 bit 7 must be clear at idle.
    read_raw(16'h0188, v);
    if (v[7] !== 1'b0)
      fail("0x188 BUSY set with no access in flight");

    // ---- 2. the SSG register-7 read-modify-write ------------------------
    // js_start.asm:67-72 does `read reg 7 / and 3Fh / or 80h / write it
    // back`. Its subject is the SSG's two I/O-port DIRECTIONS (bits 6/7, which
    // the -86 board's game port uses) and it preserves the six active-low
    // tone/noise enables. A FRESH register reads the MACHINE's 0x00
    // (docs/probes/OPNA.TXT CHIPID: `0x18A with 0x188=07 ... : 00`), not
    // NP2kai's reset byte 0xbf (sound/opna.c:137), so this RMW installs 0x80 -
    // every source routed, i.e. what "start the SSG" means. An earlier analysis read the
    // 0x80 as an artefact of a model whose reads return 0; the capture shows the
    // hardware's own byte IS 0, and the die-shot LLE and ymfm agree (see
    // pc9821_opna.sv's seed block).
    write_byte(16'h0188, 8'h07);
    read_byte(16'h018A, 8'h00, "SSG reg 7 fresh");
    sound_o(8'h07, 8'h5A);
    read_byte(16'h018A, 8'h5A, "SSG reg 7 read-back");
    // ...and the games' own read/modify/write round trip.
    read_raw(16'h018A, readback);
    sound_o(8'h07, (readback & 8'h3F) | 8'h80);
    read_byte(16'h018A, (readback & 8'h3F) | 8'h80, "SSG reg 7 RMW");

    // ---- 3. the joystick at register 0x0E -------------------------------
    // NP2kai cbus/board86.c:55-62: reading 0x18A with register 0x0E selected
    // returns fmboard_getjoy(), 0xFF with nothing on the connector. master.lib
    // INVERTS this and masks 0x3F, so 0xFF reads as "nothing pressed".
    write_byte(16'h0188, 8'h0E);
    read_byte(16'h018A, 8'hFF, "joystick at register 0x0E");
    // The six switch lines are LIVE: they come from the game port, so a direction
    // held on the host's pad clears its bit (bit0 up, 1 down, 2 left, 3 right,
    // 4 button 1, 5 button 2 -- fmboard_getjoy's own order). The upper two bits
    // stay 1: NP2kai ORs the chip's interrupt flags into them, and the machine's
    // measured idle byte is 0xFF.
    joystick = 6'b111110;               // up held
    read_byte(16'h018A, 8'hFE, "the game port's up switch at register 0x0E");
    joystick = 6'b101111;               // button 1 held
    read_byte(16'h018A, 8'hEF, "the game port's button 1 at register 0x0E");
    joystick = 6'b111111;
    read_byte(16'h018A, 8'hFF, "the release at register 0x0E");

    // ---- 4. WAITREADY: BUSY clears in bounded time ----------------------
    // The old constants satisfied this by accident (0x03 and 0x7F both have bit
    // 7 clear), so this is not a bug the rewrite fixes but a property the
    // chip-backed model must keep -- a regression trap.
    // The data write below starts a real busy period, so the poll has something
    // to wait for; a stuck BUSY would fail it.
    write_byte(16'h018A, 8'h80);
    ready = 1'b0;
    for (n = 0; n < 512 && !ready; n = n + 1) begin
      read_raw(16'h0188, v);
      if (v[7] === 1'b0) ready = 1'b1;
    end
    if (!ready)
      fail("0x188 BUSY did not clear within 512 reads (WAITREADY would hang)");

    // ---- 5. the -86 chip ID ---------------------------------------------
    // NP2kai cbus/board86.c:73-76: register 0xFF reads back 1.
    write_byte(16'h0188, 8'hFF);
    read_byte(16'h018A, 8'h01, "register 0xFF chip ID");

    // ---- 6. the 0xA460 extension gate on 0x18C/0x18E --------------------
    // Before the gate, the extension bank is absent (NP2kai returns 0xFF).
    read_byte(16'h018C, 8'hFF, "0x18C closed");
    read_byte(16'h018E, 8'hFF, "0x18E closed");
    if (sound_extend !== 1'b0)
      fail("the extension enable was already set before any 0xA460 write");
    // The ITF writes 0xA460 = 0x73 on this machine's 86 path (BANK4@0x2A5E);
    // bit 0 alone is the extension enable (np2kai cbus/pcm86io.c:45-51).
    write_byte(16'h0A460, 8'h73);
    if (sound_extend !== 1'b1)
      fail("0xA460 bit 0 did not set the extension enable");
    // Now the bank answers: the extended status register, not open bus. It can
    // show the chip's BUSY bit if a write just started, so poll it clear rather
    // than sampling once.
    ready = 1'b0;
    for (n = 0; n < 512 && !ready; n = n + 1) begin
      read_raw(16'h018C, v);
      if ((v !== 8'hFF) && (v[7] === 1'b0)) ready = 1'b1;
    end
    if (!ready)
      fail("0x18C never answered as the extended status register");
    // And a write through the extended data port is accepted (the chip needs
    // the extended register-select latch first), with the same bounded busy.
    write_byte(16'h018C, 8'h08);
    write_byte(16'h018E, 8'h00);
    ready = 1'b0;
    for (n = 0; n < 512 && !ready; n = n + 1) begin
      read_raw(16'h018C, v);
      if ((v !== 8'hFF) && (v[7] === 1'b0)) ready = 1'b1;
    end
    if (!ready)
      fail("0x18C busy never cleared after an extended write");

    // ---- 7. no sound port is reported as unmapped -----------------------
    if (last_unmapped_port == 16'h0188 || last_unmapped_port == 16'h018A ||
        last_unmapped_port == 16'h018C || last_unmapped_port == 16'h018E ||
        last_unmapped_port == 16'h0A460)
      fail("a decoded sound port is still the last unmapped port");

    // ---- 8. IRQ is masked out of reset ----------------------------------
    if (opna_irq !== 1'b0)
      fail("the OPNA raised IRQ with both timers masked at reset");

    // ---- 9. the chip's AUDIO OUTPUT actually moves ----------------------
    // THE GAP THIS BENCH HAD, and it is why an OPNA "PASS" did not mean the card
    // made a sound: every check above drives the PORT side and none looks at
    // snd_l/snd_r, which this bench declares and never reads. Program SSG
    // channel A the way the games do - tone period via regs 0/1, the tone
    // enable in reg 7, the level in reg 8 - and require the output to MOVE.
    // A card that answers its ports perfectly and emits nothing is the fault
    // observed on hardware, and nothing here could see it before.
    begin
      integer lo, hi;
      sound_o(8'h00, 8'h00);   // tone A period fine
      sound_o(8'h01, 8'h01);   // tone A period coarse -> 0x0100 = 1950 Hz
      sound_o(8'h07, 8'h3E);   // tone A on, B/C and both noises off
      sound_o(8'h08, 8'h0F);   // channel A level = max
      lo = 0; hi = 0;
      for (n = 0; n < 300_000; n = n + 1) begin
        @(posedge clk);
        if (opna_snd_l > hi) hi = opna_snd_l;
        if (opna_snd_l < lo) lo = opna_snd_l;
      end
      if (hi === 0 && lo === 0)
        fail("the OPNA's audio output never moved: a programmed SSG tone stays silent");
      $display("  OPNA snd_l swing: %0d .. %0d", lo, hi);
    end

    // ---- 10. the game's OWN 86-board detection probe, run end to end ----
    // The probe is not the game's: TH01 checks through INT 0F2h (MDRV2's
    // MDRV2_CHECK_BOARD) and TH02-05 through INT 60h/61h (PMD/MMD AH=09), so the
    // hardware probe belongs to the resident driver. The one on record is KAJA's
    // own ONGCHK.COM, which ships with the PMD family in ReC98
    // (libs/kaja/ongchk.com; the 86 branch is disassembled at 0x1c8-0x222). It
    // names every read that must answer for the card to be seen:
    //   in 0xA460; cmp al,ffh; jz NO_BOARD   -- the card's ID register answers
    //   out 0xA460, al & 0fch              -- and the probe CLOSES the extension
    //   out 0x188, ffh; in 0x18A           -- read register 0FFh
    //   dec al; jnz RETRY                  -- it must read 1 (the chip ID)
    //   in 0x18C; in 0x18E; and al,bl; inc al; jz OK
    //                                      -- both extended ports must be 0FFh
    //                                          with the extension closed
    // Every read above is one this bench already pins in isolation (CHK-5, CHK-6),
    // but the probe only SUCCEEDS if they all hold in this order with the extension
    // gate moving between them. That is what a detection failure would look like
    // from the port side, and nothing else checks it.
    begin
      reg [7:0] d460, d18a, d18c, d18e;
      read_raw(16'h0A460, d460);
      if (d460 === 8'hFF)
        fail("the 86 probe's first read (0xA460) is open bus: no board is seen");
      // The probe saves 0xA460, masks bits 1:0 and writes it back, which clears
      // the extension enable (bit 0).
      write_byte(16'h0A460, d460 & 8'hFC);
      write_byte(16'h0188, 8'hFF);
      read_raw(16'h018A, d18a);
      if (d18a !== 8'h01)
        fail("the 86 probe read register 0xFF as not-1: the chip ID is wrong");
      read_raw(16'h018C, d18c);
      read_raw(16'h018E, d18e);
      if ((d18c & d18e) !== 8'hFF)
        fail("the 86 probe's closed-extension reads (0x18C/0x18E) did not both answer 0xFF");
      $display("  86 detection probe: 0xA460=%02x 0x18A=%02x 0x18C=%02x 0x18E=%02x -> board seen",
               d460, d18a, d18c, d18e);
    end

    // ---- 11. the six FM channels produce output -------------------------
    // THE FAILURE observed on hardware, and the one the SSG check above cannot
    // see: the OPNA answers every port and the SSG plays, but the FM melody is
    // silent. The FM register file is written through the vendored core's
    // sample-rate operator scan (src/opna/jt12/hdl/jt12_reg.v -> jt12_csr.v),
    // which needs each host register write held until the scan reaches its
    // slot; the banks jt12_mmr latches on the bus write itself (the SSG above,
    // ADPCM-A/B) have no such requirement. So the writes below use the SAME
    // back-to-back sound_o the games' driver and every other check use, and
    // before the glue paced them the FM output was a flat zero while the SSG
    // played.
    //
    // The FNUM pair order is the chip's, not this bench's invention: the vendored
    // core stores BLOCK/FNUM-high in ONE latch (jt12_mmr.v "latch_fnum") and only
    // commits it to a channel when that channel's FNUM-LOW register is written
    // (jt12_reg_ch.v, "if( up_fnumlo ) { reg_block, reg_fnum } <= {latch_fnum,din}").
    // So the high byte must be written FIRST. The real driver does exactly that:
    // PMD86.COM's frequency update is `add dh,0xa3` (-> 0xA4..0xA6, the high byte)
    // then `sub dh,0x4` (-> 0xA0..0xA2, the low byte) with the same register/data
    // primitives this bench drives through 0x188/0x18A. Writing the low byte
    // FIRST leaves the channel at block 0 - a subsonic drift, not a tone - which
    // is a silent FM that still "moves the output".
    begin
      integer fm_lo, fm_hi;
      // SSG off first, so what follows is the FM alone.
      sound_o(8'h08, 8'h00);   // channel A level 0 (CHK-9 left it at max)
      // FM channel 1, operator 1, ALG 7 (every operator a carrier) so the one
      // keyed operator is audible on its own: DT/MUL, TL, AR, DR, SR, SL/RR,
      // SSG-EG, then the channel's ALG, stereo and frequency.
      sound_o(8'h28, 8'h00);   // key off
      sound_o(8'h30, 8'h01);   // DT=0, MUL=1
      sound_o(8'h40, 8'h00);   // TL=0 (loudest)
      sound_o(8'h50, 8'h1F);   // AR=31 (fast attack, does not fall back off)
      sound_o(8'h60, 8'h00);   // DR=0
      sound_o(8'h70, 8'h00);   // SR=0
      sound_o(8'h80, 8'h0F);   // SL=0, RR=15
      sound_o(8'h90, 8'h00);   // SSG-EG off
      sound_o(8'hB0, 8'h07);   // ALG=7, FB=0
      sound_o(8'hB4, 8'hC0);   // L+R on, no AMS/PMS
      sound_o(8'hA4, 8'h22);   // block 4, fnum high -- FIRST, the chip's latch
      sound_o(8'hA0, 8'h69);   // fnum low -- commits block+fnum to channel 1
      sound_o(8'h28, 8'hF0);   // key on channel 1, all four operators
      fm_lo = 0; fm_hi = 0;
      for (n = 0; n < 600_000; n = n + 1) begin
        @(posedge clk);
        if (opna_snd_l > fm_hi) fm_hi = opna_snd_l;
        if (opna_snd_l < fm_lo) fm_lo = opna_snd_l;
      end
      $display("  OPNA FM snd_l swing: %0d .. %0d", fm_lo, fm_hi);
      // A tone SWINGS BOTH WAYS. The old "hi==0 && lo==0" test passed on the
      // slow subsonic ramp a block-0 channel makes, because that ramp only ever
      // moves upward; requiring a negative excursion is what tells a tone from
      // a drift, and it is the assertion that would have caught the order above.
      if (fm_hi === 0 && fm_lo === 0)
        fail("the six FM channels stay silent: a keyed FM channel emits nothing");
      if (fm_lo >= 0)
        fail("the keyed FM channel never swings negative: it is drifting, not sounding");
      // ...and at a TONE's amplitude, not a tail's. CHK-9's SSG square was just set to
      // level 0, and the board's AC coupling leaves a ONE-SIGNED decaying step of up to
      // the SSG's coupled peak (<= 1110, tb_pc9821_opna_ssg_level's band) - which on its
      // own satisfied both tests above with the FM missing entirely (a planted
      // mutation: mix_l without fm_l PASSED). One TL=0 carrier is the operator's full
      // scale, +-4096 in this junction's units (qemu fmopn.c:3023-3025 halving its
      // 8192; pc9821_opna.sv's join comment), so a sounding note must cross +-2048.
      if (fm_hi < FM_MIN_SWING || fm_lo > -FM_MIN_SWING)
        fail("the keyed FM channel never swings past +-2048: what moves is a tail, not the FM");

      // The SAME channel, keyed on again the way a driver keys a note: the
      // key-on first and a register write right behind it. That is the one
      // window left open, and it is specific to the key-on: jt12_mmr
      // holds `up_keyon` as a LEVEL only until the next DATA write lands
      // (jt12_mmr.v:342-347), and jt12_kon samples it at the chip's clock enable
      // (jt12_kon.v:70-78) - one clk in 37 at 50 MHz. The key-on above is the
      // LAST write, so it stays held and is always captured; here the 0xA4 byte
      // (FNUM high, the driver's order) arrives immediately behind it and clears
      // up_keyon, so the key-on has one clk_en window to be sampled in or lost.
      sound_o(8'h28, 8'h00);   // key channel 1 off
      repeat (4000) @(posedge clk);
      sound_o(8'h28, 8'hF0);   // key on channel 1, all four operators
      sound_o(8'hA4, 8'h22);   // block 4, fnum high -- immediately after the key-on
      sound_o(8'hA0, 8'h69);   // fnum low -- commits block+fnum to channel 1
      fm_lo = 0; fm_hi = 0;
      for (n = 0; n < 600_000; n = n + 1) begin
        @(posedge clk);
        // The first half of the window is skipped: it can hold the PREVIOUS note's
        // RR=15 release tail (a few ms), which swings both ways on its own.
        if (n >= FM_SETTLE && opna_snd_l > fm_hi) fm_hi = opna_snd_l;
        if (n >= FM_SETTLE && opna_snd_l < fm_lo) fm_lo = opna_snd_l;
      end
      $display("  OPNA key-on+write snd_l swing: %0d .. %0d", fm_lo, fm_hi);
      if (fm_hi === 0 && fm_lo === 0)
        fail("a key-on immediately followed by a write stayed silent: the key-on was dropped");
      if (fm_lo >= 0)
        fail("the key-on immediately followed by a write did not sound: drifting, not a tone");
      if (fm_hi < FM_MIN_SWING || fm_lo > -FM_MIN_SWING)
        fail("key-on+write: no +-2048 swing after the old note's release (key-on dropped)");

      // The OTHER three FM channels, written the way the card makes them reachable:
      // the second port pair 0x18C/0x18E, which jt12_mmr decodes as the high part
      // bit (up_ch = {part, selected_register[1:0]}, jt12_mmr.v:535) and which the
      // glue gates on 0xA460 bit 0 (op_sel). The channel sound_o programmed above
      // is part 0; channels 4-6 answer only on the extended pair, so a note here
      // proves the half of the FM register bank the earlier checks never touched.
      // The key-on stays on the LOW pair: jt12_mmr takes it only with !addr[1]
      // (jt12_mmr.v:342, `!addr[1]`), with the channel in din[2:0] = 4.
      write_byte(16'h0A460, 8'h73);   // re-enable the extension (CHK-10 left it closed)
      sound_o(8'h28, 8'h00);          // key off all channels
      repeat (4000) @(posedge clk);
      sound_x(8'h30, 8'h01);          // ch4 op1 DT/MUL
      sound_x(8'h40, 8'h00);          // TL=0
      sound_x(8'h50, 8'h1F);          // AR=31
      sound_x(8'h60, 8'h00);          // DR=0
      sound_x(8'h70, 8'h00);          // SR=0
      sound_x(8'h80, 8'h0F);          // SL=0, RR=15
      sound_x(8'h90, 8'h00);          // SSG-EG off
      sound_x(8'hB0, 8'h07);          // ALG=7
      sound_x(8'hB4, 8'hC0);          // L+R
      sound_x(8'hA4, 8'h22);          // block 4, fnum high
      sound_x(8'hA0, 8'h69);          // fnum low
      sound_o(8'h28, 8'hF4);          // key on channel 4 (din[2:0]=4)
      fm_lo = 0; fm_hi = 0;
      for (n = 0; n < 600_000; n = n + 1) begin
        @(posedge clk);
        // The first half of the window is skipped: it can hold the PREVIOUS note's
        // RR=15 release tail (a few ms), which swings both ways on its own.
        if (n >= FM_SETTLE && opna_snd_l > fm_hi) fm_hi = opna_snd_l;
        if (n >= FM_SETTLE && opna_snd_l < fm_lo) fm_lo = opna_snd_l;
      end
      $display("  OPNA ext-bank FM (ch4) snd_l swing: %0d .. %0d", fm_lo, fm_hi);
      if (fm_hi === 0 && fm_lo === 0)
        fail("the extended-bank FM channels stay silent: channels 4-6 reach the chip only at 0x18C/0x18E");
      if (fm_lo >= 0)
        fail("the extended-bank FM channel did not sound: drifting, not a tone");
      if (fm_hi < FM_MIN_SWING || fm_lo > -FM_MIN_SWING)
        fail("ext-bank FM ch4: no +-2048 swing after channel 1's release");
    end

    // ---- 12. the rhythm (ADPCM-A) channel sounds, on a loaded image -------
    // The chip's ADPCM-A path is a SECOND key-on, on its own registers, and it
    // was observed silent too. NP2kai's model is the reference for what the
    // driver writes (sound/opna.c writeRegister 0x10-0x1D -> rhythm_setreg):
    // 0x11 is the total level (active low), 0x18-0x1D are the per-instrument
    // level (bits 4:0, active low) and pan (bits 7:6), and a bit in 0x10 STARTS
    // that instrument. PMD86.COM does exactly this at its song start
    // (`mov dx,0x10ff`, `mov dh,0x11`) and its per-hit handler.
    //
    // The samples are not in the tree (no copyrighted data is committed), so the
    // bench supplies its own non-silent pattern through the ROM's loader port --
    // the same port pc9821_rhythm_loader drives in the design. The all-zero code
    // is the decoder's silence, so a pattern of one non-zero nibble distinguishes
    // "the channel ran and produced samples" from "the ROM was never read".
    begin
      integer rh_lo, rh_hi;
      for (n = 0; n < 4096; n = n + 1) begin
        @(negedge clk);
        rhythm_we = 1'b1;
        rhythm_waddr = n[11:0];
        rhythm_wdata = 16'h5555;   // nibble 5 repeated: not the silence code
      end
      @(negedge clk);
      rhythm_we = 1'b0;
      // Key the FM notes CHK-11 left sounding (channels 1 and 4) off and let their
      // RR=15 release finish first: a sustained FM note swings both ways on its own,
      // so with it still playing the "the drum emits something" test below could not
      // fail. What remains is CHK-9's one-signed SSG
      // coupling tail (<= 1110), which the amplitude bound below clears.
      sound_o(8'h28, 8'h00);
      sound_o(8'h28, 8'h04);
      repeat (FM_SETTLE) @(posedge clk);
      sound_o(8'h11, 8'h3F);   // rhythm total level: no attenuation
      sound_o(8'h18, 8'hDF);   // instrument 0: level 31 (loudest), both pans
      sound_o(8'h10, 8'h01);   // trigger instrument 0 (bass drum)
      rh_lo = 0; rh_hi = 0;
      for (n = 0; n < 600_000; n = n + 1) begin
        @(posedge clk);
        if (opna_snd_l > rh_hi) rh_hi = opna_snd_l;
        if (opna_snd_l < rh_lo) rh_lo = opna_snd_l;
      end
      $display("  OPNA rhythm snd_l swing: %0d .. %0d", rh_lo, rh_hi);
      if (rh_hi === 0 && rh_lo === 0)
        fail("the rhythm channel stays silent: a triggered ADPCM-A instrument emits nothing");
      if (rh_hi < FM_MIN_SWING && rh_lo > -FM_MIN_SWING)
        fail("the rhythm channel never moved past +-2048: what moved is a tail, not the drum");
    end

    // ---- 13. the FM's timer interrupt (the driver's IRQ5) fires ----------
    // The tone above proves the FM engine, but PMD does not key notes on a
    // free-running engine: it clocks playback from an OPNA timer interrupt
    // (the timers bench's header cites rec98's PMD documentation, AH=13h, the
    // Timer B user interrupt). A driver whose timer line never reaches the
    // guest never runs its note-on, so the FM is silent with no register at
    // fault - and a game that WAITS for the interrupt hangs instead of just
    // going quiet. This pins the board's own IRQ line rising from the same
    // ports a driver programs. tb_pc9821_opna_timers measures the rate; this
    // only asserts that the sequence the note above is part of lights it.
    begin
      reg [7:0] st_t;
      // Timer B, one count: 0x26 = 0xFF is one 2304-master-clock step. Timed
      // from the start write to the line; the exact latency is dominated by the
      // free-running counter's phase, so only its rise is required here. The
      // rate is measured in tb_pc9821_opna_timers.
      sound_o(8'h27, 8'h30);   // stop both timers, clear both flags
      sound_o(8'h26, 8'hFF);   // Timer B period
      sound_o(8'h27, 8'h0A);   // start B (bit 1), enable its IRQ (bit 3)
      n = 0;
      while (!opna_irq && n < 400_000) begin
        @(posedge clk); n = n + 1;
      end
      if (!opna_irq)
        fail("the OPNA timer IRQ (IRQ5) never rose: a driver clocks the FM from this line");
      else
        $display("  OPNA timer IRQ rose after %0d clk", n);
      // The overflow flag must be visible in the status byte a driver polls,
      // and the 0x27 clear must drop the line again.
      read_raw(16'h0188, st_t);
      if (st_t[1] !== 1'b1)
        fail("Timer B's overflow flag is not in the 0x188 status read");
      sound_o(8'h27, 8'h30);   // stop and clear, so the line drops again
      repeat (60) @(posedge clk);
      if (opna_irq !== 1'b0)
        fail("the OPNA timer IRQ stayed up after its flag was cleared");
    end

  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_OPNA: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog.
  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_OPNA: TIMEOUT");
  end

endmodule

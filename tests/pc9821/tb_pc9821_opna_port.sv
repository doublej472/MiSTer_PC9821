`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The PC-9801-86 board's DATA SHADOW through the real I/O bus: after a write to the low select port 0x188 alone, a read of the data port 0x18A answers the byte that write carried, and the extended data port 0x18E answers that shadow for every extended register except 0x08 and 0x0F, which are the only two NP2kai reads from the chip - and 0x0F IS answered from the chip (NP2kai s.reg[0x10F], 0x00 after reset), not the shadow; the 0x08 side (adpcm_readsample) is not asserted. Both expectations come from the board model itself (NP2kai cbus/board86.c opna_o188 assigns s.addrl AND s.data; opna_i18a returns s.data above 0x0F and below 0xFF; opna_o18e reads the chip only for addrh 0x08 and 0x0F), not from this RTL. It does NOT assert the 3ch/6ch stereo switch, which needs a vendored file, and it does not assert the chip's own register contents. It also pins the S1 same-cycle case: a queued write's drain fire meeting a host status read's S_BYTE must never corrupt the read - the fire holds the chip port to the host and retries - across a swept-phase stream of 0x188 reads whose bytes must all show the flags 0x00, never the data-port case.
//
// The PC-9801-86 board's DATA SHADOW through the real I/O bus: after a write to the low select port 0x188 alone, a read of the data port 0x18A answers the byte that write carried, and the extended data port 0x18E answers that shadow for every extended register except 0x08 and 0x0F, which are the only two NP2kai reads from the chip. Both expectations come from the board model itself (NP2kai cbus/board86.c opna_o188 assigns s.addrl AND s.data; opna_i18a returns s.data above 0x0F and below 0xFF; opna_o18e reads the chip only for addrh 0x08 and 0x0F), not from this RTL. It does NOT assert the 3ch/6ch stereo switch, which needs a vendored file, and it does not assert the chip's own register contents.
//
// WHY THIS IS THE PORT MODEL AND NOT THE CHIP: a guest reaches the OPNA only
// through the board's four ports. A shadow that answers the wrong byte is
// invisible to every chip-level test and visible to every driver that reads
// back a register it just wrote. Its first check is the one machine-sourced row
// in this file: SSG register 7's first-touch read is the machine's 0x00
// (docs/probes/OPNA.TXT CHIPID), not the 0xBF NP2kai and this RTL both carried,
// and master.lib's js_start read-modify-write therefore lands on 0x80 (all six
// SSG tone/noise sources routed) rather than 0xBF (all six disconnected).
//
// The DUTs are pc9821_iobus plus pc9821_opna wired exactly as pc9821_system
// wires them, so the sequence runs down the real device path and the 0xA460
// extension latch is exercised the way a guest sets it. Section 8 pins the
// S1 same-cycle case: a queued write's drain fire meeting a host
// status read's S_BYTE must never corrupt the read (the fire holds the chip
// port to the host and retries), swept across the read stream's start phase so
// the window is provably exercised.

// ==== DUT ====
module tb_pc9821_opna_port;
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
  // The FDC's debug taps: named because the DUT is (.*), not exercised here
  // (tb_pc9821_fdc_dbg pins them).
  wire [7:0]  dbg_fdc_state;
  wire [7:0]  dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;

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

  // 0x043F EMS page register / window select (pc9821_iobus outputs).
  wire [1:0] ems_state;
  wire top_shadow_en;
  // The FDC's level interrupt (slave PIC IRQ11). pc9821_iobus carries the
  // port and the `.*` DUT instantiation matches by name, so it must
  // be declared here; this bench does not exercise the floppy path.
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window

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

  // P5: the chip select is pc9821_iobus's own decode now (the ONE pc9821_device_select
  // instance lives inside it), so `.*` above binds it instead of a local copy.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0),.*);

  wire [7:0] opna_io_dout;
  wire       beep_mute = 1'b0;   // the system beeper's mute; not exercised here
  wire [1:0] beep_vol = 2'd0;   // the beeper volume register; not exercised here
  wire       opna_rd_wait, opna_irq;
  wire signed [19:0] opna_snd_l, opna_snd_r;

  assign device_io_dout = opna_cs ? opna_io_dout : 8'hFF;
  assign device_rd_wait = opna_rd_wait;

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
    .rhythm_we(1'b0), .rhythm_waddr(12'd0), .rhythm_wdata(16'd0)
  );

  integer errors = 0;

  task automatic fail(input string message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
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

  reg [7:0] got;

  // The S1 same-cycle monitor: counts every clk where an armed drain fire meets
  // a host read's S_BYTE (the window that used to mux the queued write's DATA
  // address onto the chip under the read). Read-only; the byte checks in
  // section 8 are what assert correctness.
  integer s1_collisions = 0;
  always @(negedge clk) begin
    if (!reset && sound.host_rd && sound.dr_fire) s1_collisions = s1_collisions + 1;
  end

  // ==== CHECKS ====
  initial begin
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (40) @(negedge clk);

    // ---- 0. SSG REGISTER 7's FIRST-TOUCH READ: the MACHINE's 0x00 ---------
    // probes/OPNA.TXT, section CHIPID: `0x18A with 0x188=07 (SSG register 7; the
    // references' reset seed is BF): 00`. The card is proven present by the row
    // above it in that block (0x188 = FF answers the -86 chip ID 0x01), so this
    // 0x00 is the YM2608's own register read and not open bus. Our read model
    // answered 0xBF, copied from NP2kai's opna_reset seed (sound/opna.c:137) -
    // which NP2kai itself answers - so the machine is the SOLE source here.
    // The consequence is master.lib's js_start (rec98 libs/master.lib/
    // js_start.asm:67-72: `in AL,DX` / `and AL,3fh` / `or AL,80h` / write back),
    // whose whole job is to force the SSG's two I/O-port DIRECTIONS while
    // preserving the six active-low tone/noise enables. The byte read HERE is
    // what the write-back installs: from 0x00 it installs 0x80 (all six sources
    // ROUTED - SSG sound works), from 0xBF it installs 0xBF (all six
    // DISCONNECTED - a silent SSG). The machine's 0x00 is the one that makes
    // js_start mean "start the SSG", so 0x80 is the outcome asserted below.
    write_byte(16'h0188, 8'h07);
    read_raw (16'h018A, got);
    if (got !== 8'h00)
      fail($sformatf("SSG register 7 first-touch read %02h; the machine's byte (OPNA.TXT CHIPID) is 00", got));
    write_byte(16'h018A, (got & 8'h3F) | 8'h80);   // js_start's read-modify-write
    read_raw (16'h018A, got);
    if (got !== 8'h80)
      fail($sformatf("js_start's reg-7 read-modify-write landed on %02h; from the machine's 00 it must be 80", got));

    // ---- 1. A 0x188 write ALONE sets the data shadow ----
    // NP2kai cbus/board86.c:14-19 opna_o188 assigns s.addrl AND s.data. So with
    // the low select pointing at an FM register (>= 0x10, so opna_i18a falls
    // through to s.data), a 0x18A read must answer the byte the 0x188 write
    // carried -- not whatever an earlier 0x18A write left behind.
    write_byte(16'h018A, 8'h3C);          // seed the shadow with something else
    write_byte(16'h0188, 8'h27);          // low select := 0x27, an FM register
    read_raw (16'h018A, got);
    if (got !== 8'h27)
      fail("a 0x188 write alone must set the data shadow (NP2kai opna_o188 sets s.data), but 0x18A answered the stale byte");

    // ---- 2. A 0x18A write to a register >= 0x10 is shadowed ----
    write_byte(16'h0188, 8'h2A);
    write_byte(16'h018A, 8'hC5);
    read_raw (16'h018A, got);
    if (got !== 8'hC5)
      fail("a 0x18A write must be the byte 0x18A reads back for a register >= 0x10 (NP2kai opna_i18a returns s.data)");

    // ---- 3. The chip ID at 0xFF, and the joystick at 0x0E, still win ----
    write_byte(16'h0188, 8'hFF);
    read_raw (16'h018A, got);
    if (got !== 8'h01)
      fail("select 0xFF must answer the -86 chip ID 0x01 (NP2kai opna_i18a returns 1)");
    write_byte(16'h0188, 8'h0E);
    read_raw (16'h018A, got);
    if (got !== 8'hFF)
      fail("select 0x0E must answer the joystick, idle, not the shadow");

    // ---- 4. Below 0x10 the SHADOW answers, not the last data byte ----
    write_byte(16'h0188, 8'h07);
    write_byte(16'h018A, 8'h5A);
    write_byte(16'h0188, 8'h20);          // move the select off the SSG bank
    write_byte(16'h0188, 8'h07);          // and back
    read_raw (16'h018A, got);
    if (got !== 8'h5A)
      fail("an SSG register below 0x10 must keep its own shadow byte across a select change");

    // ---- 5. 0x18C/0x18E are absent until 0xA460 bit 0 enables them ----
    read_raw (16'h018C, got);
    if (got !== 8'hFF)
      fail("0x18C must read 0xFF before the extension is enabled (NP2kai opna_i18c)");
    read_raw (16'h018E, got);
    if (got !== 8'hFF)
      fail("0x18E must read 0xFF before the extension is enabled (NP2kai opna_i18e)");
    write_byte(16'h0A460, 8'h01);         // the extension latch
    repeat (4) @(negedge clk);
    if (!sound_extend)
      fail("writing 0xA460 bit 0 must latch the extension; pc9821_iobus owns the latch");

    // ---- 6. THE EXTENDED DATA PORT IS A SHADOW, NOT A CHIP READ ----
    // NP2kai cbus/board86.c:92-110 opna_o18e reads the CHIP only when addrh is
    // 0x08 or 0x0F; every other extended register returns s.data. Answering the
    // chip for all of them is a wider read than the board gives, and this is
    // the assertion that fails on the pre-fix model.
    write_byte(16'h018C, 8'h20);          // extended select := 0x20 (not 08/0F)
    write_byte(16'h018E, 8'hA5);          // extended data
    read_raw (16'h018E, got);
    if (got !== 8'hA5)
      fail("an extended register other than 0x08/0x0F must read back the data shadow, not the chip (NP2kai opna_o18e)");

    // A second extended address, to show it is the shadow and not one register.
    write_byte(16'h018C, 8'h11);
    write_byte(16'h018E, 8'h7E);
    read_raw (16'h018E, got);
    if (got !== 8'h7E)
      fail("the extended data shadow must follow the extended select byte to any address outside 0x08/0x0F");

    // ---- 6b. ...and 0x0F IS a chip read, not the shadow ----
    // The other half of opna_i18e (cbus/board86.c:100-102: `if ((nAddress == 0x08)
    // || (nAddress == 0x0f)) return opna_readExtendedRegister(...)`). For 0x0F that
    // returns s.reg[0x10F] (sound/opna.c:629 `return opna->s.reg[nAddress + 0x100];`),
    // which opna_reset's memset leaves 0 (sound/opna.c:133, and :137-140 seed only
    // low-bank registers) and nothing in this bench writes. The 0x18C write just
    // moved the shadow to 0x0F (opna_o18c: s.data = dat), so a board that answered
    // 0x0F from the shadow reads 0x0F here instead of the reference's 0x00. Without
    // this the bench asserted only the shadow side of the split and a 0x0F (or
    // 0x08) routed to the shadow passed.
    write_byte(16'h018C, 8'h0F);
    read_raw (16'h018E, got);
    if (got !== 8'h00)
      fail($sformatf("extended register 0x0F must be read from the chip (NP2kai opna_i18e -> s.reg[0x10F] = 00 after reset), got %02h", got));

    // ---- 7. 0x18C still answers the CHIP's extended status ----
    // opna_i18c returns opna_readExtendedStatus when extended. This bench only
    // requires that it is not the shadow, because asserting the chip's own byte
    // would be reading the implementation back rather than a reference.
    write_byte(16'h018C, 8'h20);
    write_byte(16'h018E, 8'h00);
    read_raw (16'h018C, got);
    if (got === 8'h00)
      fail("0x18C must answer the chip's extended status, not the data shadow");

    // ---- 8. S1: a queued write's fire must not corrupt a coincident host read ----
    // The drain's chip write and a host read's one-cycle S_BYTE can land on the
    // same clk. Before the fix the addr mux served the queued write's DATA port
    // and jt12_dout (which re-latches dout from addr every clk) captured the
    // data-port case instead of the status case. Queue 0x188<-FF then 0x18A<-5A:
    // the chip's select latch is then 0xFF, so the data-port case is the chip ID
    // 0x01 and a corrupted status read returns 0x81 instead of the flags 0x00.
    // Stream 0x188 status reads across the drain, sweeping the stream's start
    // phase so some run lands a read's S_BYTE on the armed fire cycle.
    begin : s1
      integer k, n, q;
      reg [7:0] b;
      for (k = 0; k < 12; k = k + 1) begin
        write_byte(16'h0188, 8'hFF);        // select 0xFF: the chip-ID select
        write_byte(16'h018A, 8'h5A);        // one queued data byte (not FM: SHORT_GAP)
        repeat (k) @(negedge clk);          // sweep the read stream's phase
        for (n = 0; n < 10; n = n + 1) begin
          read_raw(16'h0188, b);
          if (b[6:0] !== 7'h00)
            fail($sformatf("S1 run %0d: status read %02h, bits 6:0 must be the flags 00 (the data-port case would show 01)", k, b));
        end
        // Every queued write must REACH the chip: the retried fire is held, not
        // lost. The drain paces one entry per SHORT_GAP, so wait it out (the
        // earlier sections leave a backlog) with a bound rather than a fixed gap.
        q = 0;
        while (((sound.wrq_cnt !== 0) || (sound.dr_state !== 2'd0)) && (q < 20000)) begin
          @(negedge clk); q = q + 1;
        end
        if ((sound.wrq_cnt !== 0) || (sound.dr_state !== 2'd0))
          fail($sformatf("S1 run %0d: the drain never finished (wrq_cnt=%0d dr_state=%0d) - a queued write was lost", k, sound.wrq_cnt, sound.dr_state));
      end
      if (s1_collisions == 0)
        fail("S1: no read S_BYTE ever met an armed fire - the same-cycle window was not exercised");
      else
        $display("NOTE S1 pass: %0d fire/read same-cycle collisions, every status byte clean", s1_collisions);
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_PORT: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_OPNA_PORT: FAIL (%0d)", errors);
      $fatal(1, "opna port model");
    end
  end

  // In-bench watchdog: the DUT's read path ends in a `while (!cpu_ready)`, so a
  // regression that never readies the bus would otherwise hang until the
  // runner's wall clock rather than failing here.
  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_OPNA_PORT: TIMEOUT");
  end
endmodule

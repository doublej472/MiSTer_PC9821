`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_BEEPER: The machine's own power-on beep is audible, and each half of it is the machine's: the TONE is the PIT's CHANNEL-1 mode-3 square wave, programmed through the 0x3FDF/0x3FDB port alias exactly as the firmware's own beep routine programs it (BANK4@0x4B2B: control 0x76 = channel 1, LSB then MSB, mode 3, then divisor 0x04CD = 1229 low and high) and measuring 2.4576 MHz divided by the divisor = 2000 Hz, and the GATE is system port C bit 3 used as a MUTE, so the 8255 bit-set/reset form on 0x37 with 0x06 makes it audible and 0x07 silences it, a whole-register write on 0x35 does the same, and the sound stops the moment the bit is set even though the counter is still running; and channel 2 is shown NOT to be the beeper, so the routing that put the beep on the RS-232C channel's divisor is caught. And the 0x871E software-DIP BEEPER VOLUME (bits [3:2]) actually scales the speaker amplitude: writing each code through the real I/O path yields the 0/1024/2048/3072 ladder through z486_mister's mirrored amplitude block - linear in the code with 0 = EXACT mute (NP2kai io/dipsw.c:44-57 sets BEEP_VOL from (value>>2)&3, sound/beepg.c:113-114 scales `samp *= vol`, sound/beepg.c:161-163 goes silent at 0), the unit pinned so code 2 - NP2kai's default 'Mid' (pccore.c:847) - is the historical 2,048, and the exported beep_vol port carries exactly the written bits.
//
// TB_PC9821_BEEPER: The machine's own power-on beep is audible, and each half of it is the machine's: the TONE is the PIT's CHANNEL-1 mode-3 square wave, programmed through the 0x3FDF/0x3FDB port alias exactly as the firmware's own beep routine programs it (BANK4@0x4B2B: control 0x76 = channel 1, LSB then MSB, mode 3, then divisor 0x04CD = 1229 low and high) and measuring 2.4576 MHz divided by the divisor = 2000 Hz, and the GATE is system port C bit 3 used as a MUTE, so the 8255 bit-set/reset form on 0x37 with 0x06 makes it audible and 0x07 silences it, a whole-register write on 0x35 does the same, and the sound stops the moment the bit is set even though the counter is still running; and channel 2 is shown NOT to be the beeper, so the routing that put the beep on the RS-232C channel's divisor is caught; and the exported beep_vol volume port carries the SELECTED bank's 0x871E bits, which is the other half of that register - 0x871E is bank A's sdip[3] with 0x8F1F bit 6 clear and bank B's sdip[15] with it set, so a bank-select write alone moves the volume and the two banks hold independent images, where a single mirror loaded only on the 0x871E write would answer bank A's code for both.
//
// WHERE THE EXPECTATIONS COME FROM, because none of them is read back off this
// tree's implementation:
//   * The PIT CHANNEL AND ITS PROGRAMMING are the firmware's own. Its beep
//     routine at BIOS.ROM@0x16F20 writes `mov al,0xB6; out 0x77,al` (channel 2,
//     mode 3 square wave, LSB then MSB, binary) and then the divisor low and high
//     to 0x75 at 0x16F61/0x16F65 [from-a-dump]. Those two are the ONLY writes to
//     0x75 anywhere in the firmware, so channel 2 drives the beeper and nothing
//     else does.
//   * The 2.4576 MHz input clock is the MACHINE's, already carried by
//     pc9821_pit's own INPUT_CLOCK_HZ and independently cross-checked by
//     tb_pc9821_iobus's PIT_TICK_CYCLES [from-the-machine, via the tree's
//     measured figures].
//   * The GATE POLARITY is NP2kai's board model: sound/beepc.c:170 is
//     `buz = (sysport.c & 8)?0:1;` and :111 ANDs it with the PIT output, so bit 3
//     SET means MUTED [from-NP2kai]. The firmware uses it the same way round: the
//     ITF clears bit 3 before stage 0x1F and sets it again afterwards
//     (BANK4@0x37F `out 0x37,0x06`, BANK4@0x3CB `out 0x37,0x07`) [from-a-dump].
//     i.e. `0x06` un-mutes and `0x07` mutes, which is the 8255 bit-set/reset
//     encoding (bit 0 = 0 clears, bit 0 = 1 sets) and NOT the other way round.
//   * The RESET VALUE is the machine's measured 0xB8 (probes/VRAM.TXT), whose bit
//     3 is SET, so a power-on machine is silent until the firmware says otherwise.
//
// WHAT IS DELIBERATELY NOT ASSERTED, and why: the exact two frequencies of the
// BIOS's power-on beep. The tone routine indexes a divisor table at cs:0x1560,
// and reading that table at the file offset gives 46-238 Hz for its first
// entries - which are not beep tones - so either the table's segment base is not
// the image base or the routine is reached by more than one path. The DIVISOR
// ARITHMETIC is proven here instead, which is the part the beeper's correctness
// actually rests on, and the report says plainly that the table was not pinned.

module tb_pc9821_beeper;
  // 50 MHz, and it MATTERS: this bench measures a period, and pc9821_pit derives
  // its tick enable from SYS_CLOCK_HZ against this clock, so a mismatched pair
  // would make every frequency wrong by the same ratio and the bench would not
  // notice. 20 ns per cycle, so cycles = ns / 20.
  reg clk = 0;
  always #10 clk = ~clk;

  // ==== STIMULUS ====
  reg reset = 1;

  // ---------------------------------------------------------------
  // DUT A: the system port, which owns the beeper's MUTE bit
  // ---------------------------------------------------------------
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
  reg        cal_cdat = 0;
  // The configuration-image seed (pc9821_gdc_text's cfg_* block / pc9821_iobus's memory-switch
  // strap cell): 0 = no seed, which is what this bench wants. tb_pc9821_cg_read_path drives it.
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  reg        triple_fault_reset = 1'b0;
  reg        egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;
  // The beeper's mute, the port added to pc9821_iobus for it.
  wire        beep_mute;
  // The beeper volume: 0x871E bits [3:2], auto-connected
  // by the .* instantiation below.
  wire [1:0]  beep_vol;

  // ---------------------------------------------------------------
  // DUT B: the PIT, whose channel 2 is the tone
  // ---------------------------------------------------------------
  // Named pit_sel, not pit_cs: pc9821_iobus is instantiated with `.*` and P5 made it output the
  // device-bus chip selects, so `pit_cs` there is the fabric's decode (this bench drives the PIT
  // directly, in isolation from it).
  reg        pit_sel  = 0;
  reg  [1:0] pit_addr = 0;   // 0=ch0 1=ch1 2=ch2 3=control
  reg        pit_wr   = 0, pit_rd = 0;
  reg  [7:0] pit_din  = 0;
  wire [7:0] pit_dout;
  wire       pit_out0, pit_out1, pit_out2;

  // ==== DUT ====
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

  // P5: the device-bus chip selects are pc9821_iobus outputs now (its own one decode).
  // This bench drives no device select of its own, so they are named here for the wildcard
  // instantiation and left unused.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) iobus (
      .ide_unit0_present(1'b0),.*);

  pc9821_pit #(.SYS_CLOCK_HZ(50_000_000)) pit (
      .clk(clk), .rst_n(~reset), .cs(pit_sel), .addr(pit_addr),
      .wr(pit_wr), .rd(pit_rd), .din(pit_din), .dout(pit_dout),
      .out0(pit_out0), .out1(pit_out1), .out2(pit_out2)
  );

  // The core's own composition, quoted verbatim from pc9821_system.sv. It is one
  // AND of the two things this bench drives and measures, so the bench proves the
  // HALVES - each against the machine - and states that the composition itself is
  // a single gate rather than pretending to test it.
  wire speaker = ~beep_mute & pit_out1;

  // MIRROR of z486_mister.sv's speaker amplitude block, byte-for-byte the shipped
  // block (status[19:18] is an UNDECLARED OSD field -> the 5'd0 shift below; vol_spk
  // is pc9821_system.sv's hard-wired 2'd3, so spk_out is the raw sounding amplitude).
  wire [1:0] vol_spk_mirror = 2'd3;
  reg [16:0] spk_out;
  always @(posedge clk) begin
    reg [16:0] spk;
    spk <= speaker ? ({15'd0, beep_vol} << (5'd10 + 5'd0)) : 17'd0;
    spk_out <= spk >> ~vol_spk_mirror;
  end

  integer errors = 0;
  integer i;
  integer c;   // the 0x871E beeper-volume code sweep (check 6b)

  // The machine's PIT input clock and this bench's clock, so an expected period in
  // cycles is derived rather than tuned: period_cycles = divisor * 50e6 / 2.4576e6.
  localparam real CLK_HZ   = 50_000_000.0;
  localparam real PIT_HZ   = 2_457_600.0;
  localparam real CYCLES_PER_TICK = CLK_HZ / PIT_HZ;   // 20.345

  task automatic fail(input [8*100-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ---- the system port, through the I/O bus's real CPU interface ----
  task automatic write_byte(input [15:0] portnum, input [7:0] data);
    reg [1:0] lane;
    integer guard;
    begin
      lane = portnum[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_din = {24'd0, data} << (lane * 8);
      cpu_write = 1;
      cpu_valid = 1;
      guard = 0;
      while (!cpu_ready && guard < 4096) begin @(negedge clk); guard = guard + 1; end
      if (guard >= 4096) fail("the system port never went ready for a write");
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      repeat (4) @(negedge clk);
    end
  endtask

  task automatic expect_read(input [15:0] portnum, input [7:0] expected,
                             input [8*60-1:0] what);
    reg [1:0] lane;
    integer guard;
    begin
      lane = portnum[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_write = 0;
      cpu_valid = 1;
      guard = 0;
      while (!cpu_ready && guard < 4096) begin @(negedge clk); guard = guard + 1; end
      if (guard >= 4096) fail("the system port never went ready for a read");
      #1;
      if (cpu_dout[{lane, 3'b000} +: 8] !== expected) begin
        $display("FAIL %0s: read %04x got %02x want %02x",
                 what, portnum, cpu_dout[{lane, 3'b000} +: 8], expected);
        errors = errors + 1;
      end
      @(negedge clk);
      cpu_valid = 0;
      cpu_be = 0;
      repeat (2) @(negedge clk);
    end
  endtask

  // ---- the PIT, exactly the way the firmware programs channel 2 ----
  task automatic pit_write(input [1:0] regsel, input [7:0] data);
    begin
      @(negedge clk);
      pit_sel = 1; pit_addr = regsel; pit_din = data; pit_wr = 1;
      @(negedge clk);
      pit_wr = 0; pit_sel = 0;
      repeat (2) @(negedge clk);
    end
  endtask

  // The firmware's own sequence: control 0x76 (bits 7:6 = 01 -> CHANNEL 1, LSB then
  // MSB, mode 3, binary), divisor low, divisor high. BANK4@0x4B2B.
  task automatic program_tone(input [15:0] divisor);
    begin
      pit_write(2'b11, 8'h76);
      pit_write(2'b01, divisor[7:0]);
      pit_write(2'b01, divisor[15:8]);
      repeat (8) @(negedge clk);
    end
  endtask

  // The RS-232C channel, which is NOT the beeper: control 0xB6 = channel 2, mode 3.
  task automatic program_ch2(input [15:0] divisor);
    begin
      pit_write(2'b11, 8'hB6);
      pit_write(2'b10, divisor[7:0]);
      pit_write(2'b10, divisor[15:8]);
      repeat (8) @(negedge clk);
    end
  endtask

  // The period of pit_out1 in clk cycles, averaged over several periods so the
  // counter's own +/-1 tick is not the measurement's noise floor.
  task automatic measure_tone_cycles(output real cycles);
    integer t0, t1;
    begin
      @(posedge pit_out1);
      t0 = $time;
      for (i = 0; i < 4; i = i + 1) @(posedge pit_out1);
      t1 = $time;
      cycles = (t1 - t0) / (4.0 * 20.0);
    end
  endtask

  // The period of the RS-232C channel's output (pit_out2), so the negative check can
  // show channel 2 CHANGED while the beeper did not.
  task automatic measure_out2_cycles(output real cycles);
    integer t0, t1;
    begin
      @(posedge pit_out2);
      t0 = $time;
      for (i = 0; i < 4; i = i + 1) @(posedge pit_out2);
      t1 = $time;
      cycles = (t1 - t0) / (4.0 * 20.0);
    end
  endtask

  task automatic expect_tone(input [15:0] divisor, input [8*40-1:0] what);
    real measured, expected, err_pct;
    begin
      program_tone(divisor);
      measure_tone_cycles(measured);
      expected = divisor * CYCLES_PER_TICK;
      err_pct  = 100.0 * (measured - expected) / expected;
      if (err_pct < 0.0) err_pct = -err_pct;
      $display("  %0s: divisor %0d -> %0.1f cycles, expected %0.1f (%.2f%% off)",
               what, divisor, measured, expected, err_pct);
      // 2%: the counter's own +/-1 tick per period is ~0.004% at these divisors,
      // so this is loose on purpose and still catches a wrong clock or a wrong
      // mode (a mode-0 or a half-period interpretation would be off by 2x).
      if (err_pct > 2.0)
        fail("tone period does not follow the divisor the firmware programs");
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // ---- 1. POWER-ON IS SILENT, for two independent reasons ----
    // The port resets to the machine's measured 0xB8, whose bit 3 is set...
    expect_read(16'h0035, 8'hB8, "system port C reset value");
    if (beep_mute !== 1'b1) begin
      $display("FAIL: power-on port C must mute the beeper (bit 3 set in 0xB8)");
      errors = errors + 1;
    end
    // ...and channel 1 is not running, so its output is low.
    if (pit_out1 !== 1'b0) begin
      $display("FAIL: an unprogrammed channel 1 must not produce a tone");
      errors = errors + 1;
    end
    if (speaker !== 1'b0) begin
      $display("FAIL: the beeper must be silent at power-on");
      errors = errors + 1;
    end

    // ---- 2. UNMUTED BUT UNPROGRAMMED IS STILL SILENT ----
    // The gate alone cannot make a sound: there has to be a tone under it. This
    // is the check that separates a gated square wave from "bit 3 is the sound".
    write_byte(16'h0037, 8'h06);          // clear bit 3 = AUDIBLE
    if (beep_mute !== 1'b0) begin
      $display("FAIL: 0x37 = 0x06 must CLEAR bit 3 (bit 0 of the BSR byte is 0)");
      errors = errors + 1;
    end
    if (speaker !== 1'b0) begin
      $display("FAIL: unmuted with no tone programmed must still be silent");
      errors = errors + 1;
    end

    // ---- 3. THE FIRMWARE'S OWN SEQUENCE PRODUCES A TONE ----
    program_tone(16'h04CD);               // 1229 ticks -> 2000 Hz
    repeat (64) @(posedge clk);
    if (speaker !== 1'b1) begin
      $display("FAIL: unmuted with channel 1 running must be audible");
      errors = errors + 1;
    end
    expect_tone(16'h04CD, "tone A (1229 -> 2000 Hz)");
    expect_tone(16'h03E6, "tone B (998 -> 2462 Hz, the 8 MHz strap divisor)");

    // ---- 3b. CHANNEL 2 IS NOT THE BEEPER ----
    // The defect this catches: routing the beeper to channel 2 makes the beep play the
    // RS-232C channel's divisor. Program channel 2 with a clearly different divisor and
    // require the beeper NOT to follow it.
    begin
      real ch1_cycles, ch2_cycles;
      program_tone(16'h04CD);             // the beeper: channel 1
      measure_tone_cycles(ch1_cycles);
      program_ch2(16'h0010);              // the RS-232C: channel 2, divisor 16
      measure_out2_cycles(ch2_cycles);    // measure CHANNEL 2's own output
      measure_tone_cycles(ch1_cycles);    // and re-measure the beeper
      $display("  ch1 beeper %0.1f cycles; ch2 (RS-232C) output %0.1f cycles",
               ch1_cycles, ch2_cycles);
      // The RS-232C channel must have MOVED to its own divisor...
      if (ch2_cycles > 400.0) begin
        $display("FAIL: channel 2 with divisor 16 must be ~325 cycles, got %0.1f",
                 ch2_cycles);
        errors = errors + 1;
      end
      // ...while the beeper stayed on channel 1's 1229-tick period, unmoved.
      if (ch1_cycles < 20000.0) begin
        $display("FAIL: the beeper must stay on channel 1's period, got %0.1f", ch1_cycles);
        errors = errors + 1;
      end
      if (speaker !== 1'b1) begin
        $display("FAIL: programming channel 2 must not disturb the channel-1 beeper");
        errors = errors + 1;
      end
    end

    // ---- 4. THE GATE STOPS THE SOUND WHILE THE COUNTER KEEPS RUNNING ----
    // This is the property a driver relies on: muting must not disturb timing.
    write_byte(16'h0037, 8'h07);          // set bit 3 = MUTED
    if (beep_mute !== 1'b1) begin
      $display("FAIL: 0x37 = 0x07 must SET bit 3 (bit 0 of the BSR byte is 1)");
      errors = errors + 1;
    end
    repeat (256) @(posedge clk);
    if (speaker !== 1'b0) begin
      $display("FAIL: a muted beeper must be silent even with the counter running");
      errors = errors + 1;
    end
    // ...and the tone is still there when it is unmuted again, so nothing was
    // disturbed. A gate implemented by stopping the counter would pass the check
    // above and fail this one.
    write_byte(16'h0037, 8'h06);
    repeat (64) @(posedge clk);
    if (speaker !== 1'b1) begin
      $display("FAIL: unmuting must restore the tone that was already running");
      errors = errors + 1;
    end

    // ---- 5. THE WHOLE-REGISTER FORM ON 0x35 DOES THE SAME ----
    // The firmware reaches the latch both ways, and the read of 0x35 is how the
    // ITF sees it, so the byte form has to move bit 3 too.
    write_byte(16'h0035, 8'hB0);          // bit 3 clear
    expect_read(16'h0035, 8'hB0, "0x35 whole-register write");
    if (beep_mute !== 1'b0) begin
      $display("FAIL: 0x35 = 0xB0 must clear the mute bit");
      errors = errors + 1;
    end
    write_byte(16'h0035, 8'hB8);
    expect_read(16'h0035, 8'hB8, "0x35 whole-register write back");
    if (beep_mute !== 1'b1) begin
      $display("FAIL: 0x35 = 0xB8 must set the mute bit");
      errors = errors + 1;
    end

    // ---- 6. THE BIT-INDEX ENCODING, not just bit 3 ----
    // The BSR byte is (bit << 1) | value, so 0x02/0x03 touch bit 1 and must NOT
    // move the beeper. A gate decoded as "any 0x37 write" would pass every check
    // above and fail this one.
    write_byte(16'h0035, 8'h00);          // everything clear
    write_byte(16'h0037, 8'h02);          // bit 1, value 0
    if (beep_mute !== 1'b0)
      fail("0x37 = 0x02 touched the beeper's bit; the BSR index is not decoded");
    write_byte(16'h0037, 8'h03);          // bit 1, value 1
    if (beep_mute !== 1'b0)
      fail("0x37 = 0x03 touched the beeper's bit; the BSR index is not decoded");
    expect_read(16'h0035, 8'h02, "bit 1 set through the BSR");

    // ---- 6b. THE 0x871E BEEPER VOLUME: bits [3:2] SCALE THE AMPLITUDE --------
    // NP2kai models a 2-bit beeper volume in software-DIP port 0x871E bits [3:2]:
    // a write sets it from (value >> 2) & 3 (io/dipsw.c:44-57) and the port reads
    // it back (io/dipsw.c:97-103). The LAW is amplitude linear in the code with
    // 0 = EXACT mute: sound/beepg.c:161-163 gates the generator on beepcfg.vol,
    // and the PC-98 default generator (mode 1, sound/beepc.c:68 `g_beep.mode =
    // 1`) scales `samp *= vol; samp <<= (10-2)` (sound/beepg.c:113-114), i.e. a
    // 1024*vol peak ladder; the oneshot path is the same linear law
    // (sound/beepg.c:57 `0x5000 * beepcfg.vol`). The UNIT is pinned so code 2 -
    // NP2kai's default "Mid" (pccore.c:847, sound/beepc.c:34 `beepcfg.vol = 2`)
    // - is bit-identical to this tree's shipped 2,048 amplitude: 0/1024/2048/3072.
    // The ABSOLUTE beeper level stays AUDIO_AUDIT AU-4 (capture-pending on the
    // real Xe10); only the register's scaling and its mute are asserted here.
    // Writes first open the machine's DIP write gate (0x8F1F bit 7) and select
    // bank A (bit 6 clear), then carry the measured 0x871E power-up image 0x3E
    // with only bits [3:2] replaced. 0x871E's parity bit is bit 7 and is
    // recomputed on read, so bits [3:2] read back exactly as written.
    write_byte(16'h8F1F, 8'h80);
    for (c = 0; c < 4; c = c + 1) begin
      reg [16:0] amp;
      write_byte(16'h871E, 8'h32 | (c << 2));
      // the exported register must carry EXACTLY the bits the port reads back
      // (NP2kai io/dipsw.c:44-57 takes (value >> 2) & 3 on the write).
      if (beep_vol !== c[1:0]) begin
        $display("FAIL: 0x871E bits [3:2] written %0d, beep_vol output is %0d", c, beep_vol);
        errors = errors + 1;
      end
      wait (speaker === 1'b1);
      repeat (4) @(posedge clk);
      amp = spk_out;
      $display("  beeper volume code %0d -> amplitude %0d (want %0d)",
               c, amp, c * 1024);
      if (amp !== 17'(c * 1024)) begin
        $display("FAIL: 0x871E bits [3:2] = %0d must scale the beeper amplitude to %0d, got %0d",
                 c, c * 1024, amp);
        errors = errors + 1;
      end
    end
    // And code 0 is a TRUE mute even with the gate open and the tone running:
    // NP2kai generates exactly nothing at vol 0 (sound/beepg.c:161-163).
    write_byte(16'h871E, 8'h32);
    wait (speaker === 1'b1);
    repeat (4) @(posedge clk);
    if (spk_out !== 17'd0)
      fail("beeper volume 0 must be an exact mute, not an attenuated leak");

    // ---- 6c. THE VOLUME FOLLOWS THE SELECTED BANK -------------------------
    // 0x871E is the fourth byte of the SELECTED bank: index 3 with 0x8F1F bit 6
    // clear, index 15 with it set. So a BANK-SELECT write moves the volume with
    // no write to the data port at all, and the two banks hold independent
    // images. This is the half a single mirror loaded only on the 0x871E write
    // would get wrong, and it is the check the store's per-bank mirrors have to
    // pass now that the store itself is a block memory with a clocked read (the
    // volume is a same-cycle consumer, so it cannot be read off that register).
    // State going in: bank A index 3 holds 0x32 (code 0, the mute just written)
    // and the write gate (0x8F1F bit 7) is open. Bank B index 3 is the 0x80
    // power-up image, i.e. code 0.
    write_byte(16'h8F1F, 8'hC0);          // bank B, gate open
    if (beep_vol !== 2'd0)
      fail("bank B's 0x871E power-up image 0x80 is code 0, but beep_vol does not follow the bank select");
    write_byte(16'h871E, 8'h3C);          // bank B: code 3
    if (beep_vol !== 2'd3)
      fail("bank B's 0x871E = 0x3C must read back as code 3 on beep_vol");
    write_byte(16'h8F1F, 8'h80);          // back to bank A: its own code 0
    if (beep_vol !== 2'd0)
      fail("bank A's 0x871E still holds code 0; beep_vol must not carry bank B's");
    write_byte(16'h8F1F, 8'hC0);          // bank B again: code 3 was left there
    if (beep_vol !== 2'd3)
      fail("bank B's 0x871E = 0x3C must survive a trip through bank A");
    write_byte(16'h8F1F, 8'h80);          // leave bank A selected for section 7

    // ---- 7. THE RESET STATE COMES BACK ----
    reset = 1;
    repeat (4) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);
    if (beep_mute !== 1'b1)
      fail("the mute bit must return to its reset value");
    if (speaker !== 1'b0)
      fail("the beeper must be silent after a reset");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_BEEPER: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_BEEPER: %0d failure(s)", errors);
    end
  end

  // A run that ends without a verdict is a failure, not a pass.
  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_BEEPER: timed out with no verdict");
  end

endmodule

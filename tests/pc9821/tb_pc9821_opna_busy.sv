`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OPNA_BUSY:
// TB_PC9821_OPNA_BUSY: the OPNA status BUSY bit (0x188 bit 7) after every write class the real Xe10 capture times (docs/probes/XE10T-XE10.TXT /OPNA: the address write, FM data 0x30/0x40/0xA0/0xB0, SSG 0x08, rhythm 0x11, ADPCM-B 0x00 through 0x18C/0x18E) reads CLEAR at the first status read after the write, through the real I/O bus and the real board glue: 32 trials per row, each run as the probe's opna_trial (wait clear, select, wait clear, write, poll 0x188 and count), give min and median 1 poll on every row and a max no higher than the capture's (29 polls on the FM and SSG rows, 1 on the address, rhythm and ADPCM-B rows), where the core used to hold BUSY 25-29 us after FM, SSG and rhythm writes; every write of the run still reaches the chip.
//
// The expected values are the machine's (docs/probes/XE10T-XE10.TXT, BEGIN:OPNA, T rows
// `polls=min/med/max`); the probe's procedure is tools/hwprobe/xe10t/sec_dev.inc opna_trial.
// The DUTs are pc9821_iobus plus pc9821_opna wired as pc9821_system wires them
// (tb_pc9821_opna's harness, with the queue's write back-pressure connected).

module tb_pc9821_opna_busy;

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
  wire device_wr_wait;   // the OPNA queue's write back-pressure, wired as pc9821_system wires it
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
  wire   opna_wr_wait;
  assign device_wr_wait = opna_cs && opna_wr_wait;

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
    .io_wr_wait(opna_wr_wait),
    .extend(sound_extend),
    // The connector's six switch lines, which pc9821_gameport owns; this bench drives
    // them directly (the register's own behaviour is what it tests).
    .joystick(joystick),
    .snd_l(opna_snd_l), .snd_r(opna_snd_r),
    .irq(opna_irq),
    // The rhythm ROM: not loaded (this bench writes only the silent rhythm total level).
    .rhythm_we(rhythm_we), .rhythm_waddr(rhythm_waddr),
    .rhythm_wdata(rhythm_wdata)
  );

  integer errors = 0;

  task automatic fail(input string message);
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

  // The probe's opna_wait: poll 0x188 until bit 7 is clear (bounded; the probe's 10 ms).
  task automatic opna_wait;
    reg [7:0] v;
    integer guard;
    begin
      guard = 0;
      v = 8'h80;
      while (v[7] && guard < 200000) begin
        read_raw(16'h0188, v);
        guard = guard + 1;
      end
      if (v[7]) fail("BUSY never cleared (the probe's 10 ms deadline)");
    end
  endtask

  // Every write the guest makes and every write the chip's own strobe takes: they must match.
  integer guest_writes = 0;
  integer chip_writes  = 0;
  always @(posedge clk)
    if (!reset && sound.u_opna.u_jt08.u_jt12.u_mmr.write) chip_writes = chip_writes + 1;

  // One trial, as opna_trial: data_mode 0 times the address write, 1 the data write.
  // The data port is the address port + 2; the poll is always 0x188.
  task automatic trial(input [15:0] aport, input [7:0] regi, input [7:0] data,
                       input data_mode, output integer polls);
    reg [7:0] v;
    begin
      opna_wait;
      if (data_mode) begin
        write_byte(aport, regi); guest_writes = guest_writes + 1;     // select (untimed)
        opna_wait;
        write_byte(aport + 16'd2, data); guest_writes = guest_writes + 1;   // the data write
      end else begin
        write_byte(aport, regi); guest_writes = guest_writes + 1;     // the address write
      end
      polls = 0;
      v = 8'h80;
      while (v[7] && polls < 65535) begin
        read_raw(16'h0188, v);
        polls = polls + 1;
      end
    end
  endtask

  // ==== CHECKS ====
  integer p [0:31];
  // 32 trials -> min / median / max, the probe's T-row statistics (tr_print: the median of
  // 32 sorted values is element 16).
  task automatic row(input [8*16-1:0] tag, input [15:0] aport, input [7:0] regi,
                     input [7:0] data, input data_mode, input integer cap_max);
    integer i, j, t, mn, md, mx, g;
    begin
      for (i = 0; i < 32; i = i + 1) trial(aport, regi, data, data_mode, p[i]);
      for (i = 0; i < 32; i = i + 1)
        for (j = i + 1; j < 32; j = j + 1)
          if (p[j] < p[i]) begin t = p[i]; p[i] = p[j]; p[j] = t; end
      mn = p[0]; md = p[16]; mx = p[31];
      // Between rows the probe prints the row (row_mark, tr_print: DOS console output,
      // milliseconds on the machine); the bench lets the queue drain there, bounded.
      g = 0;
      while ((sound.wrq_cnt != 0 || sound.dr_state != 0) && g < 400000) begin
        @(posedge clk); g = g + 1;
      end
      if (g >= 400000) fail($sformatf("%0s: the queue did not drain within 4 ms", tag));
      $display("  %0s polls=%0d/%0d/%0d (machine 1/1/%0d)", tag, mn, md, mx, cap_max);
      if (mn != 1) fail($sformatf("%0s: min polls %0d, the machine's is 1", tag, mn));
      if (md != 1) fail($sformatf("%0s: median polls %0d, the machine's is 1", tag, md));
      if (mx > cap_max) fail($sformatf("%0s: max polls %0d, over the machine's %0d", tag, mx, cap_max));
    end
  endtask

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (2000) @(posedge clk);   // the OPNA's reset stretcher

    // The capture's rows, in its order and with its register values (sec_dev.inc sec_opna,
    // tc_opna `OPNA 30=00 40=7F A0=00 B0=00 08=00 11=00, ext reg 00=00`), and its maxima.
    row("BUSY_ADDR",     16'h0188, 8'h30, 8'h00, 1'b0, 1);
    row("BUSY_FM30",     16'h0188, 8'h30, 8'h00, 1'b1, 29);
    row("BUSY_FM40",     16'h0188, 8'h40, 8'h7F, 1'b1, 29);
    row("BUSY_FMA0",     16'h0188, 8'hA0, 8'h00, 1'b1, 29);
    row("BUSY_FMB0",     16'h0188, 8'hB0, 8'h00, 1'b1, 29);
    row("BUSY_SSG08",    16'h0188, 8'h08, 8'h00, 1'b1, 29);
    row("BUSY_RHY11",    16'h0188, 8'h11, 8'h00, 1'b1, 1);
    // ADPCM-B control through the extended pair: 0xA460 bit 0 opens 0x18C/0x18E.
    write_byte(16'hA460, 8'h01);
    if (sound_extend !== 1'b1) fail("0xA460 bit 0 did not open the extended pair");
    row("BUSY_ADPCMB00", 16'h018C, 8'h00, 8'h00, 1'b1, 1);
    write_byte(16'hA460, 8'h00);

    // No write is lost: wait for the queue to drain (bounded), then count the chip's strobes.
    begin : drain
      integer g;
      g = 0;
      while ((sound.wrq_cnt != 0 || sound.dr_state != 0 || sound.ext_inj != 0) && g < 2000000) begin
        @(posedge clk); g = g + 1;
      end
    end
    // The 0xA460 bit-0 drop injects the board's two-word rhythm key-off (pc9821_opna B-4).
    if (chip_writes != guest_writes + 2)
      fail($sformatf("the chip took %0d writes, the guest made %0d (+2 key-off)", chip_writes, guest_writes));
    else
      $display("  every write reached the chip: %0d guest + 2 key-off", guest_writes);

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_BUSY: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_BUSY: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_OPNA_BUSY: TIMEOUT");
  end

endmodule

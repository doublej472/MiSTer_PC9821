`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OPNA_FLAGSYNC:
// TB_PC9821_OPNA_FLAGSYNC: a status read of the OPNA (0x188, 0x18C) never reports a timer or ADPCM-B flag that a write queued before it has reset, and IRQ12 has fallen by the time that read completes, through the real I/O bus and the real board glue driven with PMD 4.8o's own port sequences (rdychk, opnset44, opnset46, INT_check, FM_Timer_main, PMDB2's ADPCM-B key-on and EOS read): T1 a timer A reset (0x27) behind a loaded queue reads clear at the next rdychk read and IRQ12 is low; T7 a timer A overflow after that reset still reads set once the queue has drained; T2 PMD's IRQ12 handler over a main-thread write stream services every timer A and B overflow exactly once (no double tick from a stale flag, none lost); T3 ADPCM-B EOS and the BRDY mask read as the key-on's 0x110 writes left them; T4 a 400-call rdychk-paced burst reaches the chip complete and in order with the queue never past 64 words plus the one pair in flight; T6 no chip write lands inside the chip's own 32-cycle busy after an FM-register data write.
//
// Expected values:
//   * the flag reset acts at the write: YM2608 timer control 0x27 bits 4/5 (ymfm
//     ymfm_fm.ipp engine_mode_write `set_reset_status(0, reset_mask);`, NP2kai
//     sound/opntimer.c opna_settimer `opna->s.status &= ~((cData & 0x30) >> 4);`), the
//     ADPCM-B flag control 0x110 bit 7 and its masks (ymfm ymfm_opn.cpp ym2608::write_data
//     `if (bitfield(data, 7)) m_fm.set_reset_status(0, 0xff);`, read_status_hi
//     `status &= ~(m_flag_control & 0x1f);`), and a start clears EOS (ymfm ymfm_adpcm.cpp
//     `m_status = (m_status & ~STATUS_EOS) | STATUS_PLAYING;`). The IRQ line follows the
//     flags (the same set_reset_status).
//   * the guest is PMD 4.8o as shipped (PMD86.COM; offsets below): what it reads and
//     writes, in its order, is the stimulus, and "each overflow is serviced once" is what
//     its sequencer counts on (one TimerB_main call per timer B overflow).
//   * the chip's busy after a data write is 32 synthesizer cycles (ymfm ym2608::write_data
//     `ymfm_set_busy_end(32 * m_fm.clock_prescale())`), which T6 reads from the vendored
//     chip's own busy counter.
//   * T4's 64-word bound is the queue's stated BUSY point (pc9821_opna wrq_half), a design
//     contract, not a hardware value: the machine has no queue.
// The DUTs are pc9821_iobus plus pc9821_opna wired as pc9821_system wires them, with the
// write back-pressure and the status-read hold connected (tb_pc9821_opna_busy's harness).

module tb_pc9821_opna_flagsync;


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

  wire device_rd_hold;   // the OPNA's status-read hold, wired as pc9821_system wires it
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
  wire   opna_rd_hold;
  assign device_rd_hold = opna_cs && opna_rd_hold;
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
    .io_rd_hold(opna_rd_hold),
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
  reg  t4_done = 1'b0;   // T4's writer has finished: it stops the queue watcher
  time t2_end;           // T2 runs until this time

  task automatic fail(input string message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS ====
  // One byte I/O access through the real bus, as the CPU makes it.
  task automatic io_in(input [15:0] portnum, output [7:0] data);
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

  task automatic io_out(input [15:0] portnum, input [7:0] data);
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

  // PMD's rdychk (PMD86.COM 0x31C2: `in al,dx` / `in al,dx` / `test al,al` / `js` back to
  // the second read): one discarded read, then read until bit 7 is clear. PMD has no
  // timeout; the bench bounds it only so a stuck BUSY fails instead of hanging.
  integer busy_polls = 0;      // reads that found BUSY set, over the run
  task automatic rdychk(input [15:0] portnum, output [7:0] v);
    integer guard;
    begin
      io_in(portnum, v);
      guard = 0;
      io_in(portnum, v);
      while (v[7] && guard < 100000) begin
        busy_polls = busy_polls + 1;
        io_in(portnum, v);
        guard = guard + 1;
      end
      if (v[7]) fail($sformatf("rdychk on 0x%03h never saw BUSY clear", portnum));
    end
  endtask

  // Every write the guest makes to the chip's ports, logged in order; the chip's own strobes
  // are logged the same way, so T4 can compare the two sequences.
  reg [9:0] guest_log [0:4095];
  reg [9:0] chip_log  [0:4095];
  time      guest_t   [0:4095];   // when each write was made / reached the chip (T4's lag)
  time      chip_t    [0:4095];
  integer   guest_n = 0, chip_n = 0;
  task automatic chip_out(input [15:0] portnum, input [7:0] data);
    begin
      if (guest_n < 4096) begin
        guest_log[guest_n] = {portnum[2:1], data};
        guest_t[guest_n]   = $time;
      end
      guest_n = guest_n + 1;
      io_out(portnum, data);
    end
  endtask
  always @(posedge clk)
    if (!reset && sound.u_opna.u_jt08.u_jt12.u_mmr.write) begin
      if (chip_n < 4096) begin
        chip_log[chip_n] <= {sound.u_opna.u_jt08.u_jt12.u_mmr.addr,
                             sound.u_opna.u_jt08.u_jt12.u_mmr.din};
        chip_t[chip_n]   <= $time;
      end
      chip_n <= chip_n + 1;
    end

  // PMD's opnset44 (PMD86.COM 0x31B7): under cli, rdychk on the base status port, the
  // register select, PMD's address-to-data delay loop ([0x40E8]; one access time here),
  // the data. No BUSY check between the select and the data.
  task automatic opnset44(input [7:0] regi, input [7:0] data);
    reg [7:0] v;
    begin
      rdychk(16'h0188, v);
      chip_out(16'h0188, regi);
      chip_out(16'h018A, data);
    end
  endtask
  // opnset46 (0x31DF), the same on the extended pair.
  task automatic opnset46(input [7:0] regi, input [7:0] data);
    reg [7:0] v;
    begin
      rdychk(16'h018C, v);
      chip_out(16'h018C, regi);
      chip_out(16'h018E, data);
    end
  endtask

  // A writer that does not poll at all (raw pairs): it loads the queue the way a burst
  // from a non-polling driver, or a previous tick's backlog, leaves it.
  task automatic raw_fm_pairs(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) begin
        chip_out(16'h0188, 8'h40 + (k % 3));        // TL, channels 1-3 operator 1
        chip_out(16'h018A, 8'h20 + (k & 8'h0F));
      end
    end
  endtask

  task automatic drain_wait(input string tag);
    integer g;
    begin
      g = 0;
      while ((sound.wrq_cnt != 0 || sound.dr_state != 0 || sound.ext_inj != 0) && g < 4000000) begin
        @(posedge clk); g = g + 1;
      end
      if (g >= 4000000) fail($sformatf("%0s: the queue did not drain within 40 ms", tag));
    end
  endtask

  // ==== CHECKS ====
  // ---- T6: the chip's write recovery after an FM-register data write ----
  // jt12's own busy (jt12_mmr's 32-enable counter, the YM2608's 32-cycle busy) must be clear
  // whenever the queue presents the next write after a held (FM register) data write.
  reg  last_was_fm = 1'b0;
  integer t6_hits = 0, t6_checked = 0;
  always @(posedge clk)
    if (!reset && sound.dr_go) begin
      if (last_was_fm) begin
        t6_checked = t6_checked + 1;
        if (sound.u_opna.u_jt08.u_jt12.busy) t6_hits = t6_hits + 1;
      end
      last_was_fm <= sound.dr_str;
    end

  // ---- T2's scoreboard: timer overflows the chip raised, and what the handler did ----
  // An overflow is the vendored timer's flag-set condition (jt12_timers jt12_timer:
  // `enable && cen && zero && load && overflow`). owed counts overflows not yet serviced;
  // a service that finds none owed is a double tick, and an owed overflow still pending when
  // the guest's reset reaches the chip (clr_flag rises) is a lost one. The load, enable and
  // reset are read at the timer block's own ports: the glue drives them at the guest's
  // write (the flag-reset seam's host_tmr and host_clr_tmr), not the register port.
  wire t_cen   = sound.u_opna.u_jt08.u_jt12.timer_cen;
  wire t_zero  = sound.u_opna.u_jt08.u_jt12.zero;
  wire ovf_a   = t_cen && t_zero && sound.u_opna.u_jt08.u_jt12.genblk4.u_timers.load_A &&
                 sound.u_opna.u_jt08.u_jt12.genblk4.u_timers.enable_irq_A && sound.u_opna.u_jt08.u_jt12.overflow_A;
  // Timer B counts in 16ths of timer A's tick (jt12_timer FREE_EN): its carry is the
  // free-running prescaler's and the counter's, which the B instance computes as `overflow`.
  wire ovf_b   = t_cen && t_zero && sound.u_opna.u_jt08.u_jt12.genblk4.u_timers.load_B &&
                 sound.u_opna.u_jt08.u_jt12.genblk4.u_timers.enable_irq_B &&
                 sound.u_opna.u_jt08.u_jt12.genblk4.u_timers.timer_B.overflow;
  reg  clr_a_q = 1'b0, clr_b_q = 1'b0;
  wire clr_a_rise = sound.u_opna.u_jt08.u_jt12.genblk4.u_timers.clr_flag_A && !clr_a_q;
  wire clr_b_rise = sound.u_opna.u_jt08.u_jt12.genblk4.u_timers.clr_flag_B && !clr_b_q;
  integer ovf_a_n = 0, ovf_b_n = 0, owed_a = 0, owed_b = 0;
  integer svc_a = 0, svc_b = 0, dbl_a = 0, dbl_b = 0, lost_a = 0, lost_b = 0;
  reg     score_on = 1'b0;
  // Each guest service takes one owed overflow (tasks below); the always block takes the
  // chip's events. The two never touch the same variable in one time step: the guest side
  // runs at negedge, this at posedge.
  integer owed_a_take = 0, owed_b_take = 0;   // services, counted by the guest side
  always @(posedge clk) begin
    clr_a_q <= sound.u_opna.u_jt08.u_jt12.genblk4.u_timers.clr_flag_A;
    clr_b_q <= sound.u_opna.u_jt08.u_jt12.genblk4.u_timers.clr_flag_B;
    if (score_on) begin
      if (ovf_a) begin ovf_a_n = ovf_a_n + 1; owed_a = owed_a + 1; end
      if (ovf_b) begin ovf_b_n = ovf_b_n + 1; owed_b = owed_b + 1; end
      // A reset that lands with an overflow still owed past the services already made wipes it.
      if (clr_a_rise && (owed_a > owed_a_take)) begin
        lost_a = lost_a + (owed_a - owed_a_take); owed_a_take = owed_a;
      end
      if (clr_b_rise && (owed_b > owed_b_take)) begin
        lost_b = lost_b + (owed_b - owed_b_take); owed_b_take = owed_b;
      end
    end
  end
  task automatic service_a;
    begin
      svc_a = svc_a + 1;
      if (owed_a_take >= owed_a) dbl_a = dbl_a + 1;
      else owed_a_take = owed_a_take + 1;
    end
  endtask
  task automatic service_b;
    begin
      svc_b = svc_b + 1;
      if (owed_b_take >= owed_b) dbl_b = dbl_b + 1;
      else owed_b_take = owed_b_take + 1;
    end
  endtask

  // The 8259's request latch for IRQ12: the -86's timer IRQ is edge-triggered at the slave
  // PIC (PC-98 ICW1 LTIM = 0), so a rising edge of the line is one request, held in IRR while
  // PMD's handler has IR4 masked and delivered after it unmasks.
  reg     irq_q = 1'b0;
  integer irq_edges = 0, irq_taken = 0;
  always @(posedge clk) begin
    irq_q <= opna_irq;
    if (!reset && opna_irq && !irq_q) irq_edges = irq_edges + 1;
  end

  // PMD's timer work, as register traffic. TimerB_main (0x3AF4, the sequencer step) writes
  // a tick's worth of FM and SSG registers; TimerA_main (0x3B3B, the effect counter) a few
  // SSG ones. Their content does not matter here, only that they are writes through
  // opnset44 queued behind the 0x27 reset.
  integer tick_b_writes = 24;
  task automatic timerb_main;
    integer k;
    begin
      for (k = 0; k < tick_b_writes; k = k + 1)
        opnset44(8'hA4 + (k % 3), 8'h22);           // FNUM-high, channels 1-3
    end
  endtask
  task automatic timera_main;
    begin
      opnset44(8'h08, 8'h0C);
      opnset44(8'h00, 8'h40);
    end
  endtask

  // FM_Timer_main (PMD86.COM 0x3AA7): rdychk, select 0x27, PMD's delay, read the status
  // with 0x27 selected (`in al,dx` on the base port, 0x3ABF), write [0x411E] = 0x3F (reset
  // both flags, keep both timers loaded and enabled), then by the flags read:
  // 1 -> TimerA_main, 2 -> TimerB_main, 3 -> TimerB_main then TimerA_main (0x3ADA-0x3AEA).
  task automatic fm_timer_main;
    reg [7:0] v, st;
    begin
      rdychk(16'h0188, v);
      chip_out(16'h0188, 8'h27);
      io_in(16'h0188, st);
      // The overflows this read reports are the ones the handler services, so they are
      // taken here, before its reset: an overflow the reset then wipes is a lost one
      // (the scoreboard counts it at the timer block's clr_flag).
      if (st[1]) service_b;
      if (st[0]) service_a;
      chip_out(16'h018A, 8'h3F);
      case (st[1:0])
        2'd1: timera_main;
        2'd2: timerb_main;
        2'd3: begin timerb_main; timera_main; end
        default: ;
      endcase
    end
  endtask

  // The IRQ12 handler from INT_check on (0x3A31; the PIC mask, EOI and the PCM86 0xA468
  // check around it are outside the OPNA): rdychk and `and al,3`; a set flag runs
  // FM_Timer_main and loops back; a clear read is re-checked once more (0x3A50) and only a
  // second clear read leaves. Each read that leaves must find the line low (T5): an IRQ12
  // still high there is a request the edge-triggered PIC never sees again.
  integer handler_runs = 0, exit_irq_high = 0, int_reads = 0, int_stale = 0;
  task automatic pmd_irq_handler;
    reg [7:0] v;
    reg done;
    begin
      handler_runs = handler_runs + 1;
      done = 1'b0;
      while (!done) begin
        rdychk(16'h0188, v);
        int_reads = int_reads + 1;
        if (v[1:0] != 2'd0) fm_timer_main;
        else begin
          rdychk(16'h0188, v);
          if (v[1:0] != 2'd0) fm_timer_main;
          else begin
            done = 1'b1;
            if (opna_irq) exit_irq_high = exit_irq_high + 1;
          end
        end
      end
    end
  endtask

  initial begin : main
    reg [7:0] v;
    integer k, g, main_calls, maxq, okn, bz0;
    time    t4_start, lag, maxlag, t7_reset;
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (2000) @(posedge clk);   // the OPNA's reset stretcher

    // ---- T1 + T5: a timer A reset behind a loaded queue ----
    $display("T1: timer A reset (0x27) behind 30 queued FM pairs, then PMD's rdychk read");
    opnset44(8'h24, 8'hFF);          // NA = 1023: one count, about 18 us
    opnset44(8'h25, 8'h03);
    opnset44(8'h27, 8'h05);          // load A, enable A
    g = 0;
    v = 8'h00;
    while (!v[0] && g < 2000) begin io_in(16'h0188, v); g = g + 1; end
    if (!v[0]) fail("T1: timer A never raised its flag");
    if (!opna_irq) fail("T1: IRQ12 did not rise with the timer A flag");
    raw_fm_pairs(30);
    opnset44(8'h27, 8'h10);          // reset A; timer A unloaded and disabled, so it stays clear
    rdychk(16'h0188, v);             // PMD's next status read (INT_check, 0x3A35)
    $display("  status after the reset: %02h, IRQ12 %0d, queue %0d words", v, opna_irq, sound.wrq_cnt);
    if (v[0]) fail("T1: the status read after the 0x27 reset still reports the timer A flag");
    if (opna_irq) fail("T5: IRQ12 still high when the read after the reset completed");
    drain_wait("T1");

    // ---- T7: an overflow after the reset survives the queued 0x27 ----
    // Timer A at 33 counts (about 0.6 ms) keeps running; the guest resets its flag with
    // 0x27 = 0x15 (reset A, keep it loaded and enabled) behind 30 queued FM pairs, whose
    // drain (about 0.8 ms) outlasts one period. On the chip the reset acts at the write and
    // the next expiry sets the flag again (ymfm engine_timer_expired
    // `set_reset_status(STATUS_TIMERA, 0);`), so once the queue has drained the flag reads set.
    $display("T7: timer A keeps running; its reset behind 30 queued FM pairs, read after the drain");
    opnset44(8'h24, 8'hF7);          // NA = 991: 33 counts
    opnset44(8'h25, 8'h03);
    opnset44(8'h27, 8'h05);
    g = 0;
    v = 8'h00;
    while (!v[0] && g < 20000) begin io_in(16'h0188, v); g = g + 1; end
    if (!v[0]) fail("T7: timer A never raised its flag");
    raw_fm_pairs(30);
    t7_reset = $time;
    opnset44(8'h27, 8'h15);
    drain_wait("T7");
    io_in(16'h0188, v);
    $display("  status %0d us after the reset, queue drained: %02h", ($time - t7_reset) / 1000, v);
    if (!v[0]) fail("T7: the overflow after the guest's reset was wiped when the queued 0x27 landed");
    opnset44(8'h27, 8'h10);          // stop timer A, reset its flag
    drain_wait("T7 stop");

    // ---- T3: ADPCM-B EOS and the BRDY mask after PMDB2's key-on ----
    $display("T3: PMDB2 key-on behind 30 queued FM pairs, then the next tick's EOS read");
    io_out(16'hA460, 8'h01);         // the -86's extension open (PMD86.COM 0x549C)
    opnset46(8'h00, 8'h01);          // reset
    opnset46(8'h10, 8'h00);          // no flag masked
    opnset46(8'h01, 8'h02);          // 8-bit RAM
    opnset46(8'h02, 8'h00); opnset46(8'h03, 8'h00);   // start 0
    opnset46(8'h04, 8'h00); opnset46(8'h05, 8'h00);   // end 0: one 32-byte unit
    opnset46(8'h09, 8'hFF); opnset46(8'h0A, 8'hFF);   // fastest delta-N
    opnset46(8'h0B, 8'hFF);
    opnset46(8'h00, 8'hA0);          // start, from memory
    g = 0;
    v = 8'h00;
    while (!v[2] && g < 20000) begin io_in(16'h018C, v); g = g + 1; end
    if (!v[2]) fail("T3: the short sample never raised EOS");
    raw_fm_pairs(30);
    // PMDB2's key-on (PMDB2.COM 0x0722-0x0774), every write through opnset46.
    opnset46(8'h01, 8'h02);
    opnset46(8'h00, 8'h21);
    opnset46(8'h02, 8'h00); opnset46(8'h03, 8'h00);   // start 0
    opnset46(8'h04, 8'hFF); opnset46(8'h05, 8'hFF);   // end 0xFFFF: it cannot end in this test
    opnset46(8'h00, 8'hA0);
    opnset46(8'h01, 8'hC2);
    opnset46(8'h10, 8'h80);          // reset every flag
    opnset46(8'h10, 8'h18);          // mask BRDY and ZERO
    // The next tick: FM_Timer_main's rdychk on the base port (0x3AAC), then the bare EOS
    // read at the part's length expiry (PMDB2.COM 0x0282 `in al,dx` / `test al,4`).
    rdychk(16'h0188, v);
    io_in(16'h018C, v);
    $display("  0x18C after the key-on: %02h (EOS bit 2, BRDY bit 3)", v);
    if (v[2]) fail("T3: EOS still reads set after the key-on's 0x110 = 0x80 reset");
    if (v[3]) fail("T3: BRDY reads set although 0x110 = 0x18 masked it");
    opnset46(8'h00, 8'h01);          // stop
    drain_wait("T3");
    io_out(16'hA460, 8'h00);
    drain_wait("T3 close");

    // ---- T4: PMD's rdychk pacing over a long burst ----
    $display("T4: 400 opnset44 calls (FM, key-on, SSG, rhythm) back to back");
    k = guest_n;  g = chip_n;
    maxq = 0;
    bz0 = busy_polls;
    t4_start = $time;
    fork
      begin : t4_writer
        integer j;
        for (j = 0; j < 400; j = j + 1)
          case (j % 5)
            0: opnset44(8'h40 + (j % 3), j[7:0]);       // TL
            1: opnset44(8'hA4 + (j % 3), 8'h22);        // FNUM-high
            2: opnset44(8'hA0 + (j % 3), j[7:0]);       // FNUM-low
            3: opnset44(8'h28, {4'hF, 2'b00, j[1:0] == 2'd3 ? 2'd2 : j[1:0]});   // key-on
            default: opnset44(8'h08 + (j % 3), 8'h0A);  // SSG level
          endcase
        t4_done = 1'b1;
      end
      begin : t4_watch
        while (!t4_done) begin
          @(posedge clk);
          if (sound.wrq_cnt > maxq) maxq = sound.wrq_cnt;
        end
      end
    join
    $display("  the burst took %0d us of guest time with %0d BUSY reads", ($time - t4_start) / 1000,
             busy_polls - bz0);
    drain_wait("T4");
    okn = 0;
    maxlag = 0;
    if ((guest_n - k) != (chip_n - g))
      fail($sformatf("T4: the guest made %0d writes, the chip took %0d", guest_n - k, chip_n - g));
    for (main_calls = 0; main_calls < guest_n - k && main_calls < chip_n - g; main_calls = main_calls + 1)
      begin
        if (guest_log[k + main_calls] !== chip_log[g + main_calls]) okn = okn + 1;
        lag = chip_t[g + main_calls] - guest_t[k + main_calls];
        if (lag > maxlag) maxlag = lag;
      end
    if (okn != 0) fail($sformatf("T4: %0d writes reached the chip out of order or changed", okn));
    $display("  %0d writes, all in order: %0d; highest queue %0d words; worst write-to-chip lag %0d us",
             guest_n - k, okn == 0, maxq, maxlag / 1000);
    // 64 words, plus the select/data pair a polling writer issues on one BUSY-clear read.
    if (maxq > 66) fail($sformatf("T4: the queue reached %0d words under rdychk pacing (BUSY at 64)", maxq));

    // ---- T2: PMD's IRQ12 handler over a main-thread write stream ----
    // PMD's own timer setup (PMD86.COM 0x30D3): timer A = 0 (0x24, 0x25), timer B = the
    // tempo, 0x27 = 0x3F. A tempo of 0xC1 puts timer B one count (16 timer A ticks) short of
    // timer A, so the two drift through each other and every phase of the one against the
    // other's burst occurs. The main thread is a game calling PMD (INT 60h) in a loop: its
    // opnset44 calls keep the queue loaded; the interrupt is taken between two of them
    // (opnset44 runs under cli).
    $display("T2: PMD's INT_check / FM_Timer_main over a loaded queue, timers A=0 B=0xC1");
    opnset44(8'h26, 8'hC1);
    opnset44(8'h25, 8'h00);
    opnset44(8'h24, 8'h00);
    k = irq_edges;
    t2_end = $time + 64'd120_000_000;   // 120 ms: about six of each timer's overflows
    score_on = 1'b1;
    opnset44(8'h27, 8'h3F);
    main_calls = 0;
    while ($time < t2_end) begin
      opnset44(8'h40 + (main_calls % 3), main_calls[7:0]);   // the main thread's call
      main_calls = main_calls + 1;
      if (irq_edges != k + irq_taken) begin
        irq_taken = irq_taken + 1;
        pmd_irq_handler;
      end
    end
    // Stop the timers without resetting a flag, then let the handler finish what is owed.
    score_on = 1'b0;
    opnset44(8'h27, 8'h00);
    while (irq_edges != k + irq_taken) begin irq_taken = irq_taken + 1; pmd_irq_handler; end
    $display("  overflows A %0d B %0d; services A %0d B %0d; double A %0d B %0d; lost A %0d B %0d",
             ovf_a_n, ovf_b_n, svc_a, svc_b, dbl_a, dbl_b, lost_a, lost_b);
    $display("  handler runs %0d, INT_check reads %0d, main-thread calls %0d, BUSY reads %0d",
             handler_runs, int_reads, main_calls, busy_polls);
    if (ovf_a_n < 4 || ovf_b_n < 4) fail("T2: too few overflows to judge");
    if (dbl_a != 0 || dbl_b != 0)
      fail($sformatf("T2: %0d timer A and %0d timer B ticks serviced twice (a stale flag re-read)", dbl_a, dbl_b));
    if (lost_a != 0 || lost_b != 0)
      fail($sformatf("T2: %0d timer A and %0d timer B overflows wiped before service", lost_a, lost_b));
    if (svc_a != ovf_a_n || svc_b != ovf_b_n)
      fail($sformatf("T2: services A %0d B %0d against overflows A %0d B %0d", svc_a, svc_b, ovf_a_n, ovf_b_n));
    if (exit_irq_high != 0) fail($sformatf("T5: %0d handler exits with IRQ12 still high", exit_irq_high));
    drain_wait("T2");

    $display("T6: %0d chip writes after an FM-register data write, %0d inside the chip's busy", t6_checked, t6_hits);
    if (t6_checked == 0) fail("T6: no write followed an FM-register data write");
    if (t6_hits != 0) fail($sformatf("T6: %0d chip writes inside the chip's 32-cycle busy after an FM data write", t6_hits));

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_FLAGSYNC: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_FLAGSYNC: FAIL (%0d errors)", errors);
  end


  initial begin
    #2_000_000_000;
    $fatal(1, "TB_PC9821_OPNA_FLAGSYNC: TIMEOUT");
  end

endmodule

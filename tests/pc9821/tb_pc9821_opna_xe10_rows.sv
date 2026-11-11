`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OPNA_XE10_ROWS:
// TB_PC9821_OPNA_XE10_ROWS: the real Xe10's XE10T /OPNA2 rows hold on the core's 86-board glue and 8259 pair, driven with the probe's own port sequences (tools/hwprobe/xe10t/sec_opna2.inc): FR_TMRA and FR_TMRB, a timer A (NA 0x3E8) or timer B (NB 0xFE) flag raised with IRQ12 masked in the slave IMR (0x75) shows the slave IRR bit 4 set before the 0x27 reset, and after the reset (0x27 = 0x15 or 0x2A, the timer kept running) the flag reads clear within the machine's 3 status reads and the first IRR read finds bit 4 CLEAR no later than the machine's fastest drop (26 PIT counts, 10.58 us; docs/probes/XE10T-XE10-OPNA2.TXT `irr0=10 irr1=00 irrn=1` in 32/32 trials of each), and restoring the IMR then delivers no interrupt, while a flag left set still delivers exactly one; IDC, the identity reads with 0xA460 bit 0 closed and then open read the machine's bytes (`X IDC b=0188 ext=0 ... id=01 id2=01 r0e=FF r0f=FF r10=FF r20=20 w5a=5A wa5=A5 ... s4=FF s6=FF x00=FF xff=FF` and `ext=1 ... r10=10 r20=20 ... s6=00 x00=00 xff=FF`): register 0x10 reads FF while the extension is closed and echoes its select once it is open; TMRA_3FF and TMRB_FF, the probe's start sequence (o2_tmr) at 8 phases each reaches the 1-count flag no later than the machine's slowest trial (70 PIT counts, 28.48 us, for timer A; 751, 305.58 us, for timer B); TMRQ, the same 1-count starts written behind a polling driver's FM stream that has loaded the write queue (64 or more words) still reach the flag no later than those bounds (the machine has no queue; the core trailed by about 0.86 ms before the timer registers acted at the write), a load written while timer A runs takes effect at its overflow and does not restart the count (ymfm update_timer, NP2kai opna_settimer), and 0x27's CH3-mode bit 6 reaches the chip after every FM write queued before it and not at the guest's write.
//
// WHERE THE EXPECTED VALUES COME FROM: the real Xe10's /OPNA2 run,
// docs/probes/XE10T-XE10-OPNA2.TXT, decoded with tools/hwprobe/xe10t/xe10t_decode.py:
//   * FR_TMRA / FR_TMRB, 32 trials each: `irr0=10` (IRQ12 latched while masked) and
//     `irr1=00 irrn=1` (the FIRST slave IRR read after the reset finds it gone), the reset
//     write to that read 26-31 PIT counts (T rows `irr_pit=26/30/31`, 12.21 us median,
//     10.58 us minimum at 2.4576 MHz), the flag clear after 2-3 status reads
//     (`reads=2/3/3`). The core may be faster, never slower (AGENTS.md, policies).
//   * IDC (o2_idc), the identity reads at 0x188 with 0xA460 bit 0 closed (`ext=0`) and then
//     open (`ext=1`): the ID twice, registers 0x0E/0x0F/0x10/0x20 by select-then-read, SSG
//     0x0B written 5A and A5 and read back, +4/+6, and +6 after an extended select of 00
//     and FF. The +0 status (`st=27`) is not asserted: its bits 5 and 2 come and go between
//     rows of the same run (FR_TMRA `st0=01`, B2B_SSG `st=A3/A7/A5/A9`) and no reference
//     defines them, and the ext=1 `s4=03` is the as-found timer flags.
//   * TMRA_3FF / TMRB_FF (o2_tmr, 8 trials each): 0x27 <- 30, the load (0x24 <- FF,
//     0x25 <- 03 / 0x26 <- FF), a BUSY poll, 0x188 <- 27, a BUSY poll, 0x18A <- 15 / 2A,
//     then status polls to the flag: `start_pit=70/78/101` (A) and `101/105/751` (B), so the
//     machine's slowest 1-count trials took 28.48 us and 305.58 us from the start write. The
//     first count comes at the free-running prescaler's next step (timer B's /16 at 288 us:
//     the machine's i=2..7 stay at 101-105 PIT because the probe's own loop phase-locks to
//     it), so the bound is the slowest phase, and this bench sweeps the phase.
//   * TMRQ (item 155 b, owner 2026-11-01): the machine's chip has no write queue, so a timer
//     start acts at the write whatever FM writes came before it; the bound behind a loaded
//     queue is therefore the same slowest TMRA_3FF/TMRB_FF trial. TMRQ_RUN and TMRQ_MODE
//     are the chip's own rules, from the references: a load while running is taken at the
//     next overflow (ymfm ymfm_fm.ipp update_timer `if (enable && !m_timer_running[tnum])`,
//     engine_timer_expired `update_timer(tnum, 1, 0);`; NP2kai sound/opntimer.c
//     opna_settimer `if (!nevent_iswork(...))`), and 0x27 bits 7-6 (the CH3 mode) are a
//     register write in the chip's write order like any FM register (NP2kai sound/opna.c
//     `opna->opngen.opnch[2].extop = cData & 0xc0;` on that write).
//   * The probe's sequence (o2_frl / o2_frtrial): 0x27 <- 30; for A 0x24 <- FA, 0x25 <- 00
//     and 0x27 <- 15, for B 0x26 <- FE and 0x27 <- 2A; wait for the flag; read the IRR
//     (OCW3 0x0A to 0x08, read 0x08); 0x188 <- 27, then the reset byte to 0x18A (the
//     timer's own control byte again: reset bit, flag enable, load); status reads until the
//     flag clears; then the IRR. IRQ12 is masked in the slave IMR (0x75, the as-found
//     value of the run's `STATE OPNA2 imr_s=75`) for the whole section.
//
// ==== DUT ====
// pc9821_opna (the board glue and the vendored YM2608) and the real pc9821_interrupts pair,
// wired as pc9821_system wires them (the board's line on the slave's IR4,
// tb_pc9821_opna_timers' harness).

module tb_pc9821_opna_xe10_rows;
  localparam integer SYS_CLOCK_HZ = 50_000_000;
  localparam real    CLK_NS       = 1_000_000_000.0 / SYS_CLOCK_HZ;
  // The machine's fastest IRR drop after the reset write: 26 PIT counts at 2.4576 MHz.
  localparam real    MACH_IRR_DROP_MIN_NS = 26.0 * 1_000_000_000.0 / 2_457_600.0;  // 10579.4
  localparam integer MACH_FLAG_READS_MAX  = 3;

  reg clk = 0;
  always #(CLK_NS/2.0) clk = ~clk;

  reg        reset = 1;
  reg [15:0] io_addr = 16'h0188;
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_din = 8'h00;
  reg        extend = 1'b0;    // the run's as-found 0xA460 = 40: closed
  wire [7:0] io_dout;
  wire       io_rd_wait, io_rd_hold, io_wr_wait;
  wire       irq;
  wire signed [19:0] snd_l, snd_r;

  pc9821_opna #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd),
    .io_din(io_din), .io_dout(io_dout), .io_rd_wait(io_rd_wait),
    .io_rd_hold(io_rd_hold), .io_wr_wait(io_wr_wait),
    .extend(extend), .joystick(6'b111111),
    .snd_l(snd_l), .snd_r(snd_r),
    .irq(irq),
    .rhythm_we(1'b0), .rhythm_waddr(12'd0), .rhythm_wdata(16'd0)
  );

  // The 8259 pair, on its own bus (pc9821_opna selects itself from io_addr[2] alone).
  reg  [15:0] pic_addr = 16'h0000;
  reg         pic_wr = 0, pic_rd = 0;
  reg  [7:0]  pic_din = 8'h00;
  reg         pic_master_cs = 0, pic_slave_cs = 0;
  reg         pic_rst_n = 0;
  wire [7:0]  pic_slave_irq = {1'b0, 2'd0, irq, 2'd0, 1'b0, 1'b0};
  wire        pic_cpu_intr;
  reg         pic_cpu_inta = 0;
  wire [31:0] pic_inta_din;
  wire        pic_inta_ready;
  wire [7:0]  pic_dout, pic_dbg_imr, pic_dbg_irr, pic_dbg_isr;
  wire        pic_pit_out0, pic_pit_out1, pic_pit_out2;

  pc9821_interrupts #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) pic (
    .clk(clk), .reset_n(pic_rst_n),
    .io_wr(pic_wr), .io_rd(pic_rd), .io_addr(pic_addr), .io_din(pic_din),
    .master_cs(pic_master_cs), .slave_cs(pic_slave_cs), .pit_cs(1'b0),
    .io_dout(pic_dout),
    .keyboard_irq(1'b0), .vsync_irq(1'b0),
    .master_aux_irq(4'b0000),
    .slave_irq(pic_slave_irq),
    .cpu_intr(pic_cpu_intr), .cpu_inta(pic_cpu_inta),
    .cpu_inta_din(pic_inta_din), .cpu_inta_ready(pic_inta_ready),
    .pit_out0(pic_pit_out0), .pit_out1(pic_pit_out1), .pit_out2(pic_pit_out2),
    .dbg_imr(pic_dbg_imr), .dbg_irr(pic_dbg_irr), .dbg_isr(pic_dbg_isr)
  );

  integer errors = 0;
  task automatic fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS: the probe's port helpers ====
  // One `out` to a board port: a one-clk write strobe, as pc9821_iobus presents it.
  task automatic p_out(input [15:0] port, input [7:0] data);
    begin
      @(negedge clk); io_addr = port; io_din = data; io_wr = 1;
      @(negedge clk); io_wr = 0; io_din = 8'h00;
      while (io_wr_wait) @(negedge clk);
      repeat (2) @(negedge clk);
    end
  endtask
  // One `in` from a board port: the strobe, held while the glue asks for its wait/hold.
  task automatic p_in(input [15:0] port, output [7:0] data);
    begin
      @(negedge clk); io_addr = port; io_rd = 1;
      @(negedge clk); io_rd = 0;
      while (io_rd_hold) @(negedge clk);
      #1 data = io_dout;
      repeat (2) @(negedge clk);
    end
  endtask
  // o2_wait: poll the base status until bit 7 clears.
  task automatic o2_wait;
    reg [7:0] s;
    begin
      p_in(16'h0188, s);
      while (s[7]) p_in(16'h0188, s);
    end
  endtask
  // o2_put: BUSY-polled select and data.
  task automatic o2_put(input [7:0] r, input [7:0] d);
    begin
      o2_wait; p_out(16'h0188, r);
      o2_wait; p_out(16'h018A, d);
    end
  endtask

  task automatic pic_write(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk);
      pic_addr = portnum;
      pic_master_cs = (portnum == 16'h0000) || (portnum == 16'h0002);
      pic_slave_cs  = (portnum == 16'h0008) || (portnum == 16'h000A);
      pic_din = data; pic_wr = 1;
      @(negedge clk);
      pic_wr = 0; pic_master_cs = 0; pic_slave_cs = 0;
    end
  endtask
  // o2_irr: OCW3 0x0A (read the IRR) to the slave's command port, then read it.
  task automatic o2_irr(output [7:0] data);
    begin
      pic_write(16'h0008, 8'h0A);
      @(negedge clk);
      pic_addr = 16'h0008; pic_slave_cs = 1; pic_rd = 1;
      #1 data = pic_dout;
      @(negedge clk);
      pic_rd = 0; pic_slave_cs = 0;
    end
  endtask
  task automatic inta_cycle;
    begin
      @(negedge clk);
      pic_cpu_inta = 1;
      while (!pic_inta_ready) @(negedge clk);
      @(negedge clk);
      pic_cpu_inta = 0;
      repeat (2) @(negedge clk);
    end
  endtask

  // ==== CHECKS ====
  // One FR trial (o2_frtrial): msk = the timer's status bit, ctl = its control byte.
  task automatic fr_trial(input [7:0] msk, input [7:0] ctl, input [8*8-1:0] tag,
                          input integer i);
    reg [7:0] s, irr0, irr1;
    integer   reads, guard;
    realtime  t_rst, t_irr;
    begin
      guard = 0;
      p_in(16'h0188, s);
      while (!(s & msk) && guard < 200000) begin p_in(16'h0188, s); guard = guard + 1; end
      if (!(s & msk)) fail({tag, ": the timer flag never rose"});
      o2_irr(irr0);
      if (irr0[4] !== 1'b1) begin
        $display("  %0s i=%0d irr0=%02x", tag, i, irr0);
        fail({tag, ": IRQ12 not latched in the slave IRR while masked (machine irr0=10)"});
      end
      o2_wait;
      p_out(16'h0188, 8'h27);
      o2_wait;
      t_rst = $realtime;
      p_out(16'h018A, ctl);
      reads = 0;
      do begin p_in(16'h0188, s); reads = reads + 1; end
      while ((s & msk) && reads < 4096);
      if (reads > MACH_FLAG_READS_MAX) begin
        $display("  %0s i=%0d reads=%0d", tag, i, reads);
        fail({tag, ": the flag reset needed more status reads than the machine's 3"});
      end
      o2_irr(irr1);
      t_irr = $realtime;
      $display("  %0s i=%0d irr0=%02x irr1=%02x reads=%0d drop_ns=%0.1f", tag, i, irr0,
               irr1, reads, t_irr - t_rst);
      if (irr1[4] !== 1'b0)
        fail({tag, ": the first IRR read after the reset still shows IRQ12 (machine irr1=00, 32/32)"});
      if (t_irr - t_rst > MACH_IRR_DROP_MIN_NS)
        fail({tag, ": the IRR read after the reset came later than the machine's fastest drop (10.58 us)"});
    end
  endtask

  // The FR row (o2_frl): the timer programmed and started, then four trials.
  task automatic fr_row(input timer_b);
    reg [7:0] msk, ctl;
    integer   k;
    begin
      o2_put(8'h27, 8'h30);
      if (!timer_b) begin
        msk = 8'h01; ctl = 8'h15;
        o2_put(8'h24, 8'hFA);             // NA = 0x3E8: 24 counts
        o2_put(8'h25, 8'h00);
      end else begin
        msk = 8'h02; ctl = 8'h2A;
        o2_put(8'h26, 8'hFE);             // NB = 0xFE: 2 counts
      end
      o2_put(8'h27, ctl);
      for (k = 0; k < 4; k = k + 1)
        fr_trial(msk, ctl, timer_b ? "FR_TMRB" : "FR_TMRA", k);
      o2_put(8'h27, 8'h30);
    end
  endtask

  // One IDC row (o2_idc): the reads in the probe's order, compared with the machine's.
  task automatic idc_row(input ext, input [7:0] e_r10, input [7:0] e_s4, input [7:0] e_s6,
                         input [7:0] e_x00);
    reg [7:0] v;
    begin
      extend = ext;
      repeat (8) @(negedge clk);
      o2_wait; p_out(16'h0188, 8'hFF); o2_wait; p_in(16'h018A, v);
      if (v !== 8'h01) fail("IDC: the ID read is not the machine's 01");
      p_in(16'h018A, v);
      if (v !== 8'h01) fail("IDC: the ID re-read is not the machine's 01");
      o2_wait; p_out(16'h0188, 8'h0E); o2_wait; p_in(16'h018A, v);
      if (v !== 8'hFF) fail("IDC: register 0x0E is not the machine's FF");
      o2_wait; p_out(16'h0188, 8'h0F); o2_wait; p_in(16'h018A, v);
      if (v !== 8'hFF) fail("IDC: register 0x0F is not the machine's FF");
      o2_wait; p_out(16'h0188, 8'h10); o2_wait; p_in(16'h018A, v);
      $display("  IDC ext=%0d r10=%02x (machine %02x)", ext, v, e_r10);
      if (v !== e_r10)
        fail(ext ? "IDC ext=1: register 0x10 is not the machine's 10"
                 : "IDC ext=0: register 0x10 is not the machine's FF (extension closed)");
      o2_wait; p_out(16'h0188, 8'h20); o2_wait; p_in(16'h018A, v);
      if (v !== 8'h20) fail("IDC: register 0x20 is not the machine's 20");
      o2_put(8'h0B, 8'h5A); o2_wait; p_out(16'h0188, 8'h0B); o2_wait; p_in(16'h018A, v);
      if (v !== 8'h5A) fail("IDC: SSG 0x0B does not read back 5A");
      o2_put(8'h0B, 8'hA5); o2_wait; p_out(16'h0188, 8'h0B); o2_wait; p_in(16'h018A, v);
      if (v !== 8'hA5) fail("IDC: SSG 0x0B does not read back A5");
      o2_put(8'h0B, 8'h00); o2_wait;
      p_in(16'h0188, v);
      p_in(16'h018C, v);
      if ((e_s4 == 8'hFF) ? (v !== 8'hFF) : (v[7:2] !== 6'd0))
        fail("IDC: +4 is not the machine's (FF closed, the timer flags alone open)");
      p_in(16'h018E, v);
      if (v !== e_s6) fail("IDC: +6 is not the machine's");
      o2_wait; p_out(16'h018C, 8'h00); o2_wait; p_in(16'h018E, v);
      if (v !== e_x00) fail("IDC: +6 after an extended select of 00 is not the machine's");
      o2_wait; p_out(16'h018C, 8'hFF); o2_wait; p_in(16'h018E, v);
      if (v !== 8'hFF) fail("IDC: +6 after an extended select of FF is not the machine's FF");
    end
  endtask

  // One TMRx_ trial (o2_tmr) after `dly` clk: time from the 0x27 data write to the flag.
  task automatic tmr_trial(input timer_b, input integer dly, output realtime t_us);
    reg [7:0] s, msk, ctl;
    realtime  t0;
    integer   n2;
    begin
      o2_put(8'h27, 8'h30);
      if (!timer_b) begin
        msk = 8'h01; ctl = 8'h15;
        o2_put(8'h24, 8'hFF); o2_put(8'h25, 8'h03);
      end else begin
        msk = 8'h02; ctl = 8'h2A;
        o2_put(8'h26, 8'hFF);
      end
      repeat (dly) @(negedge clk);
      o2_wait; p_out(16'h0188, 8'h27); o2_wait;
      t0 = $realtime;
      p_out(16'h018A, ctl);
      n2 = 0;
      do begin p_in(16'h0188, s); n2 = n2 + 1; end while (!(s & msk) && n2 < 200000);
      t_us = ($realtime - t0) / 1000.0;
      o2_put(8'h27, 8'h30);
    end
  endtask

  // ==== R3: timer writes behind a loaded write queue (item 155 b, owner 2026-11-01) ====
  // A polling driver (PMD's opnset44: rdychk, select, data) streams FM operator writes; the
  // glue shows BUSY only from 64 queued words, so `pairs` o2_put pairs leave the queue
  // loaded with FM data writes that each drain behind a 27 us gap.
  task automatic fm_stream(input integer pairs, input [7:0] last_data);
    integer k;
    begin
      for (k = 0; k < pairs; k = k + 1)
        o2_put(8'h40 + (k % 16), (k == pairs - 1) ? last_data : 8'h7F);   // TL: silent
    end
  endtask

  // The chip's register port, watched at jt12_mmr: data writes counted from `chip_dw_arm`,
  // and the count at which a 0x27 data write with bit 6 set reached it.
  integer chip_dw = 0, mode_dw = -1;
  always @(posedge clk) begin
    if (!reset && dut.u_opna.u_jt08.u_jt12.u_mmr.write &&
        (dut.u_opna.u_jt08.u_jt12.u_mmr.addr == 2'b01)) begin
      chip_dw = chip_dw + 1;
      if ((dut.u_opna.u_jt08.u_jt12.u_mmr.selected_register == 8'h27) &&
          dut.u_opna.u_jt08.u_jt12.u_mmr.din[6] && (mode_dw < 0))
        mode_dw = chip_dw;
    end
  end

  // One TMRQ trial: the stream, then the probe's own start (o2_tmr's order, every write
  // BUSY-polled as PMD's timer setup is) timed from the 0x27 data write to the flag.
  task automatic tmrq_trial(input timer_b, input integer pairs, output realtime t_us,
                            output integer q_at_start);
    reg [7:0] s, msk, ctl;
    realtime  t0;
    integer   n2;
    begin
      fm_stream(pairs, 8'h7F);
      if (!timer_b) begin
        msk = 8'h01; ctl = 8'h15;
        o2_put(8'h24, 8'hFF); o2_put(8'h25, 8'h03);
      end else begin
        msk = 8'h02; ctl = 8'h2A;
        o2_put(8'h26, 8'hFF);
      end
      o2_wait; p_out(16'h0188, 8'h27); o2_wait;
      t0 = $realtime;
      p_out(16'h018A, ctl);
      q_at_start = dut.wrq_cnt;
      n2 = 0;
      do begin p_in(16'h0188, s); n2 = n2 + 1; end while (!(s & msk) && n2 < 200000);
      t_us = ($realtime - t0) / 1000.0;
      o2_put(8'h27, 8'h30);
      while (dut.wrq_cnt != 0) @(negedge clk);
    end
  endtask

  reg [7:0] st;
  integer   n, q_n, q_min;
  realtime  t_max, t_one, t_run0;

  initial begin
    repeat (20) @(posedge clk);
    reset = 0;
    pic_rst_n = 1;
    repeat (400) @(posedge clk);       // the glue's stretched chip reset and SSG sweep

    // Firmware ICWs (tb_pc9821_opna_timers section 10): master ICW2 0x08, cascade on IRQ7,
    // ICW4 0x1D; slave ICW2 0x10, ICW3 0x07, ICW4 0x01. The master's IMR leaves only the
    // cascade open; the slave's is the run's as-found 0x75 (IR4 = IRQ12 masked).
    pic_write(16'h0000, 8'h11); pic_write(16'h0002, 8'h08);
    pic_write(16'h0002, 8'h80); pic_write(16'h0002, 8'h1D);
    pic_write(16'h0002, 8'h7F);
    pic_write(16'h0008, 8'h11); pic_write(16'h000A, 8'h10);
    pic_write(16'h000A, 8'h07); pic_write(16'h000A, 8'h01);
    pic_write(16'h000A, 8'h75);

    // ---- R0. IDC: the run found 0xA460 = 40 (extension closed), then opened it ----
    idc_row(1'b0, 8'hFF, 8'hFF, 8'hFF, 8'hFF);
    idc_row(1'b1, 8'h10, 8'h03, 8'h00, 8'h00);

    // ---- R2. TMRA_3FF / TMRB_FF: the start acts no later than the machine's ----
    t_max = 0;
    for (n = 0; n < 8; n = n + 1) begin
      tmr_trial(1'b0, (n * 37 % 128) * 7, t_one);
      if (t_one > t_max) t_max = t_one;
    end
    $display("  TMRA_3FF max start-to-flag %0.2f us (machine max 28.48)", t_max);
    if (t_max > 28.48) fail("TMRA_3FF: a 1-count timer A start reached its flag later than the machine's slowest trial");
    t_max = 0;
    for (n = 0; n < 8; n = n + 1) begin
      tmr_trial(1'b1, (n * 37 % 128) * 113, t_one);
      if (t_one > t_max) t_max = t_one;
    end
    $display("  TMRB_FF max start-to-flag %0.2f us (machine max 305.58)", t_max);
    if (t_max > 305.58) fail("TMRB_FF: a 1-count timer B start reached its flag later than the machine's slowest trial");

    // ---- R3. TMRQ: the same 1-count starts behind a polling driver's loaded FM queue ----
    // The machine has no queue: its start acts at the write whatever FM traffic came
    // before it, so the bound is still its slowest TMRA_3FF/TMRB_FF trial, not ~0.86 ms.
    t_max = 0; q_min = 9999;
    for (n = 0; n < 4; n = n + 1) begin
      tmrq_trial(1'b0, 40 + n * 3, t_one, q_n);
      if (t_one > t_max) t_max = t_one;
      if (q_n < q_min) q_min = q_n;
    end
    $display("  TMRQ_A max start-to-flag %0.2f us behind >= %0d queued words (machine max 28.48)",
             t_max, q_min);
    if (q_min < 48) fail("TMRQ_A: the FM stream did not load the queue (setup)");
    if (t_max > 28.48) fail("TMRQ_A: a timer A start behind queued FM writes reached its flag later than the machine's slowest trial");
    t_max = 0; q_min = 9999;
    for (n = 0; n < 4; n = n + 1) begin
      tmrq_trial(1'b1, 40 + n * 3, t_one, q_n);
      if (t_one > t_max) t_max = t_one;
      if (q_n < q_min) q_min = q_n;
    end
    $display("  TMRQ_B max start-to-flag %0.2f us behind >= %0d queued words (machine max 305.58)",
             t_max, q_min);
    if (q_min < 48) fail("TMRQ_B: the FM stream did not load the queue (setup)");
    if (t_max > 305.58) fail("TMRQ_B: a timer B start behind queued FM writes reached its flag later than the machine's slowest trial");

    // ---- R4. TMRQ_RUN: a load written while timer A runs takes effect at its overflow ----
    // ymfm update_timer starts a timer only `if (enable && !m_timer_running[tnum])` and
    // engine_timer_expired reloads from the registers; NP2kai opna_settimer starts one only
    // if (!nevent_iswork(...)) and set_fmtimeraevent re-reads 0x24/0x25 at each expiry. So
    // NA = 0x3C0 (64 counts) started, then NA = 0x3FF and 0x27 = 0x15 (load kept) written
    // mid-period, raise the flag at the 64-count period's end, not one count after the write.
    o2_put(8'h27, 8'h30);
    o2_put(8'h24, 8'hF0); o2_put(8'h25, 8'h00);
    o2_wait; p_out(16'h0188, 8'h27); o2_wait;
    t_run0 = $realtime;
    p_out(16'h018A, 8'h15);
    repeat (32 * 18 * 50) @(negedge clk);           // about half the 1.15 ms period
    o2_put(8'h24, 8'hFF); o2_put(8'h25, 8'h03);
    o2_put(8'h27, 8'h15);
    n = 0;
    p_in(16'h0188, st);
    while (!st[0] && n < 200000) begin p_in(16'h0188, st); n = n + 1; end
    t_one = ($realtime - t_run0) / 1000.0;
    $display("  TMRQ_RUN first flag %0.2f us after the 64-count start (64 x 18.03 = 1153.8)", t_one);
    if (t_one < 63.0 * 18.03)
      fail("TMRQ_RUN: a load written while timer A ran restarted the count (the chip reloads at the overflow)");
    if (t_one > 66.0 * 18.03)
      fail("TMRQ_RUN: the running timer A overflowed late");
    o2_put(8'h27, 8'h30);

    // ---- R5. TMRQ_MODE: 0x27's CH3-mode bits stay ordered with the queued FM writes ----
    // They pick channel 3's per-operator F-numbers (jt12_mmr `effect`), an FM-side effect
    // the machine applies in write order, so they must reach the chip after every FM write
    // queued before them, and only then.
    while (dut.wrq_cnt != 0) @(negedge clk);
    repeat (20 * 6 * 50) @(negedge clk);
    chip_dw = 0; mode_dw = -1;
    fm_stream(40, 8'h7E);
    o2_put(8'h27, 8'h40);
    if (dut.u_opna.u_jt08.u_jt12.u_mmr.effect !== 1'b0)
      fail("TMRQ_MODE: the CH3 mode acted at the guest's write, ahead of the FM writes queued before it");
    n = 0;
    while (dut.u_opna.u_jt08.u_jt12.u_mmr.effect !== 1'b1 && n < 4_000_000) begin
      @(negedge clk); n = n + 1;
    end
    $display("  TMRQ_MODE 0x27 bit 6 reached the chip as data write %0d (after the stream's 40)",
             mode_dw);
    if (dut.u_opna.u_jt08.u_jt12.u_mmr.effect !== 1'b1)
      fail("TMRQ_MODE: the CH3 mode never reached the chip");
    else if (mode_dw != 41)
      fail("TMRQ_MODE: the CH3 mode reached the chip out of order with the FM writes queued before it");
    o2_put(8'h27, 8'h30);
    while (dut.wrq_cnt != 0) @(negedge clk);

    // ---- R1. FR_TMRA / FR_TMRB: IRQ12 leaves the IRR with the flag ----
    fr_row(1'b0);
    fr_row(1'b1);

    // The guest-visible side: with the request withdrawn, restoring the IMR delivers nothing.
    pic_write(16'h000A, 8'h65);        // IR4 open
    repeat (200) @(posedge clk);
    if (pic_cpu_intr)
      fail("restoring the slave IMR after the flag resets delivered an interrupt (the machine's IRR was clear)");
    pic_write(16'h000A, 8'h75);

    // Positive control: a flag left set while masked keeps the request, and the unmask
    // delivers exactly one interrupt (vector 0x14).
    o2_put(8'h26, 8'hFE);
    o2_put(8'h27, 8'h2A);
    n = 0;
    p_in(16'h0188, st);
    while (!st[1] && n < 200000) begin p_in(16'h0188, st); n = n + 1; end
    o2_irr(st);
    if (st[4] !== 1'b1) fail("control: a set flag did not latch IRQ12 while masked");
    pic_write(16'h000A, 8'h65);
    n = 0;
    while (!pic_cpu_intr && n < 1000) begin @(posedge clk); n = n + 1; end
    if (!pic_cpu_intr) fail("control: a flag left set did not interrupt at the unmask");
    else begin
      inta_cycle(); inta_cycle();
      if (pic_inta_din[7:0] !== 8'h14) fail("control: the interrupt was not vector 0x14 (IRQ12)");
    end
    pic_write(16'h000A, 8'h75);
    o2_put(8'h27, 8'h30);

    // ==== VERDICT ====
    // PASS when every row holds; each failing row is named with the capture value it missed.
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_XE10_ROWS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_XE10_ROWS: FAIL (%0d errors)", errors);
  end

  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_OPNA_XE10_ROWS: TIMEOUT");
  end

endmodule

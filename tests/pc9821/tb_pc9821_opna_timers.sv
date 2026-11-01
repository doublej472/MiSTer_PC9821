`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OPNA_TIMERS:
// The PC-9801-86's two hardware timers actually fire, at the rate the machine's master clock implies, and reach the guest both ways a driver can use them: the overflow flag appears in the 0x188 status read, and the board's IRQ line asserts; the periods are measured in clk cycles against the YM2608's own formula at this board's 7.9872 MHz master clock, and two ratio checks assume no clock at all. It also proves where that IRQ LANDS: the board's factory-default INT5 is IRQ12 (the slave 8259's IR4, vector 0x14), so the timer line is wired to the slave - not the master IRQ5 - and an INTA cycle answers vector 0x14. PMD - the driver Touhou's sound runs through - drives playback from Timer B and effects from Timer A, both as interrupts, so "the timer registers exist" is not the property that matters; "an interrupt arrives at the right rate and the flag says so" is.
//
// ==== DUT ====
// The board glue pc9821_opna driven at its own host port, so every access goes
// through the addressing a driver uses: 0x188 selects a register and reads the
// chip status, 0x18A writes the selected register. The port-to-chip address
// mapping is the glue's own {io_addr[2],io_addr[1]}, and tb_pc9821_opna already
// proves iobus routes these ports here, so this bench drives the board directly
// and spends its budget on the timers rather than re-proving the decode. The
// interrupt half also instantiates the real pc9821_interrupts pair, wired to the
// OPNA exactly as pc9821_system.sv wires it (the slave line, not a master aux).
//
// ==== CHECKS ====
// The timers are measured, not pattern-matched: the bench counts clk cycles from
// a clean start to the IRQ rise and compares that against the period the
// YM2608's own formula gives at this board's 7.9872 MHz master clock. Two ratio
// checks carry no clock assumption at all.
//
// ==== VERDICT ====
// PASS when every check holds, with the failing check named.
//
// WHERE THE EXPECTATIONS COME FROM, because this project's rule is that they
// come from the machine and not from the implementation:
//
//   * The period formula is the YM2608's own, quoted in the vendored core's
//     header: jt12/hdl/jt12_timers.v:21-22 - "Timer A = 144*(1024-NA)/Phi M,
//     Timer B = 2304*(256-NB)/Phi M", where Phi M is the chip's master clock.
//     That header is vendored RTL, so the primary reference is cited beside it:
//     NP2kai sound/opntimer.c:30 `l = 18 * (1024 - ...)` and :59
//     `l = 288 * (256 - opna->s.reg[0x26])`, in 2.4576 MHz-base CPU clocks scaled
//     by 1536/625 (:36), i.e. 18 us per Timer A count and 288 us per Timer B
//     count - within 0.2% of 144/7.9872 MHz and 2304/7.9872 MHz.
//   * Phi M for this board is 7.9872 MHz: NP2kai sound/opngen.h:13 has
//     OPNA_CLOCK = 3993600 and sound/opna.c:123 doubles it for the FM engine,
//     and the glue's clock-enable comment (pc9821_opna.sv:88-92) cites that.
//   * Which bit does what is NP2kai sound/opntimer.c:172-231 (opna_settimer),
//     cross-checked against sound/opntimer.c:104-145 (fmport_a/fmport_b):
//     0x27 bit0 starts Timer A, bit1 starts Timer B, bit2 enables A's IRQ,
//     bit3 enables B's IRQ, bit4 clears A's flag, bit5 clears B's flag; the
//     flags are status bits 0 and 1. jt12's register decode takes the same six
//     bits in the same order (jt12/hdl/jt12_mmr.v:361-366).
//   * That the flags are visible in a status read is jt12/hdl/jt12_dout.v:42 -
//     the low-bank read is {busy, 5'd0, flag_B, flag_A} - and NP2kai returns
//     the chip's status byte for 0x188 (cbus/board86.c:29-33).
//   * Timer A's value split, high eight bits into 0x24 and low two into 0x25,
//     is jt12_mmr.v:358-359 (`REG_CLKA1`/`REG_CLKA2`) and NP2kai opntimer.c:34
//     reads it the same way.
//   * That Timer B is the one that must work is PMD's own documentation,
//     rec98/libs/kaja/pmddata.doc: AH=13h is the Timer B user interrupt and
//     :96-101 says playback begins at the next Timer B interrupt; AH=14h is
//     the Timer A interrupt, whose rate :435 compares to the normal-display
//     VSync rate. Both are interrupts the driver expects to receive.
//
// A NOTE ON WHY THE MEASUREMENT IS A FIRST-RISE, NOT A PERIOD-BETWEEN-RISES.
// The chip holds the flag until the guest clears it, so the board's IRQ is a
// LEVEL that stays up until a 0x27 write sets the reset bit. There is therefore
// no second rising edge to measure between: the bench stops the timer, clears
// both flags, and times one clean start-to-first-interrupt, which is exactly
// the quantity PMD's tempo derives from.

module tb_pc9821_opna_timers;
  // 50 MHz, the core's own SYS_FREQ (pc9821_system.sv:285), so the glue's
  // clock-enable divider runs at the ratio it runs at on hardware.
  localparam integer SYS_CLOCK_HZ  = 50_000_000;
  localparam real    CLK_NS        = 1_000_000_000.0 / SYS_CLOCK_HZ;  // 20 ns

  // The board's master clock, from the references above.
  localparam real    OPNA_CLOCK_HZ = 7_987_200.0;

  // One YM2608 timer step, in clk cycles: 144 master clocks for Timer A and
  // 2304 for Timer B, straight from the formula.
  localparam real    TICK_A_CLK = 144.0  * SYS_CLOCK_HZ / OPNA_CLOCK_HZ; // 901.44
  localparam real    TICK_B_CLK = 2304.0 * SYS_CLOCK_HZ / OPNA_CLOCK_HZ; // 14423.1

  // Tolerance, as a fraction of the expected period plus a small absolute
  // floor, bounded rather than tuned:
  //   * the timers decrement on a 24-state sequencer wrap (6 channels x 4 slots,
  //     jt12_reg.v:189-202), so a start can land up to one wrap from a decrement
  //     boundary - 24 clock enables, about 150 clk;
  //   * jt12 derives the chip's internal clock enable from `cen` through
  //     jt12_div.v, a FRACTIONAL divider, so the effective rate sits a fraction
  //     below the nominal and the shortfall grows with the interval. Measured:
  //     -0.74% over Timer A's 57692 clk and -0.90% over Timer B's 230769.
  // 2% covers both with room. That is loose next to the sub-1% effect, and it
  // does not weaken the check that matters here: a master clock wrong by the
  // factor of two this subsystem was warned about misses by 100%.
  localparam real    TOL_FRAC = 0.02;
  localparam integer TOL_CLK  = 300;

  reg clk = 0;
  always #(CLK_NS/2.0) clk = ~clk;

  reg        reset = 1;
  reg [15:0] io_addr = 16'h0188;
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_din = 8'h00;
  wire [7:0] io_dout;
  wire       io_rd_wait;
  wire       irq;
  wire signed [19:0] snd_l, snd_r;

  pc9821_opna #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd),
    .io_din(io_din), .io_dout(io_dout), .io_rd_wait(io_rd_wait),
    .extend(1'b0),
    .snd_l(snd_l), .snd_r(snd_r),
    .irq(irq),
    .rhythm_we(1'b0), .rhythm_waddr(12'd0), .rhythm_wdata(16'd0)
  );

  // The 8259 pair the timer IRQ must reach. pc9821_system.sv wires the card's line to
  // the SLAVE controller (its IR4 = system IRQ12, the factory-default INT5, vector 0x14),
  // so this is the same concatenation: bit 4 of slave_irq. The 86-PCM shares the strap on
  // the real card, but this bench does not drive it. Its bus is kept separate from the
  // OPNA's because pc9821_opna selects itself from io_addr[2] alone, so a shared bus would
  // make every PIC write look like a chip write at register 0.
  reg  [15:0] pic_addr = 16'h0000;
  reg         pic_wr = 0, pic_rd = 0;
  reg  [7:0]  pic_din = 8'h00;
  reg         pic_master_cs = 0, pic_slave_cs = 0, pic_pit_cs = 0;
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
    .master_cs(pic_master_cs), .slave_cs(pic_slave_cs), .pit_cs(pic_pit_cs),
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

  task automatic fail(input [8*100-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS ====

  // A driver's register write: index to 0x188, data to 0x18A
  // (rec98 libs/master.lib/soundio.asm:52-56).
  task automatic sound_o(input [7:0] reg_index, input [7:0] data);
    begin
      @(negedge clk); io_addr = 16'h0188; io_din = reg_index; io_wr = 1;
      @(negedge clk);
      @(negedge clk); io_addr = 16'h018A; io_din = data;
      @(negedge clk);
      @(negedge clk); io_wr = 0; io_din = 8'h00;
    end
  endtask

  // A read of 0x188: the chip status, and so the timer overflow flags. The
  // chip's data-out is registered, which is why the glue asks for the wait
  // cycle, so the address is held for two clk before the byte is taken.
  task automatic read_status(output [7:0] data);
    begin
      @(negedge clk); io_addr = 16'h0188; io_rd = 1;
      @(negedge clk);
      @(negedge clk);
      #1 data = io_dout;
      @(negedge clk); io_rd = 0;
      @(negedge clk);
    end
  endtask

  // Stop both timers and clear both flags: 0x27 = 0x30 is bits 4 and 5, the two
  // resets, with both start bits clear. Every measurement begins from here so
  // each one times a full count from a clean flag state.
  task automatic stop_and_clear;
    begin
      sound_o(8'h27, 8'h30);
      repeat (60) @(posedge clk);
    end
  endtask

  // Time one clean start-to-first-interrupt, in clk cycles. 0 means the line
  // never rose within the budget, which the caller reports by name.
  task automatic measure_start_to_irq(input [7:0] ctrl, input integer limit,
                                      output integer cycles);
    integer n;
    begin
      sound_o(8'h27, ctrl);
      n = 0;
      while (!irq && n < limit) begin
        @(posedge clk); n = n + 1;
      end
      cycles = irq ? n : 0;
    end
  endtask

  // A write to the interrupt pair at a PC-98 port number. Only 0x0000/0x0002 (master),
  // 0x0008/0x000A (slave) and the PIT alias are decoded; the PIT is not used here.
  task automatic pic_write(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk);
      pic_addr = portnum;
      pic_master_cs = (portnum == 16'h0000) || (portnum == 16'h0002);
      pic_slave_cs  = (portnum == 16'h0008) || (portnum == 16'h000A);
      pic_pit_cs    = 0;
      pic_din = data;
      pic_wr = 1;
      @(negedge clk);
      pic_wr = 0;
    end
  endtask

  // One INTA assertion. The bridge answers the first by asserting ready and delivers the
  // vector on the second, so a full acknowledge is two of these (pc9821_inta_bridge).
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

  reg     [7:0] st;
  integer n_cycles;
  integer exp_a, exp_b;
  real    got_ms, exp_ms;

  task automatic check_period(input integer got, input real expected_clk,
                              input [8*70-1:0] what);
    real tol;
    begin
      got_ms = got * 1000.0 / SYS_CLOCK_HZ;
      exp_ms = expected_clk * 1000.0 / SYS_CLOCK_HZ;
      tol    = expected_clk * TOL_FRAC + TOL_CLK;
      if (got == 0) begin
        $display("FAIL %0s: the IRQ never rose", what);
        errors = errors + 1;
      end else if (((got - expected_clk) > tol) || ((expected_clk - got) > tol)) begin
        $display("FAIL %0s: measured %0d clk (%0.4f ms), expected %0.1f clk (%0.4f ms), tol %0.0f",
                 what, got, got_ms, expected_clk, exp_ms, tol);
        errors = errors + 1;
      end else begin
        $display("  %0s: %0d clk = %0.4f ms (expected %0.4f ms, %0.2f%% off)",
                 what, got, got_ms, exp_ms,
                 100.0 * (got - expected_clk) / expected_clk);
      end
    end
  endtask

  initial begin
    repeat (40) @(posedge clk);
    @(negedge clk); reset = 0;
    // The glue stretches the chip's reset over 16 clk&cen cycles
    // (pc9821_opna.sv:114-127, `rst_cnt <= 5'd16;`); let it finish before any register access.
    repeat (2000) @(posedge clk);

    // ---- 1. nothing has fired and no IRQ is up --------------------------
    // tb_pc9821_opna asserts the IRQ is masked out of reset; what has never
    // been asserted is everything after, which is this bench.
    read_status(st);
    if (st[1:0] !== 2'b00)
      fail("a timer overflow flag was set before any timer was started");
    if (irq !== 1'b0)
      fail("the IRQ was up before any timer was started");

    // ---- 2. Timer B fires at the rate the formula gives ------------------
    // 16 counts: 0x26 = 0xF0, so the counter runs 256-240 = 16 steps of 2304
    // master clocks each. Started with 0x27 = 0x0A, bit1 start and bit3 enable
    // its IRQ - the shape PMD uses for the interrupt that drives playback.
    // The count is small so the bench stays fast; 16 steps is still 230769 clk,
    // which is 770x the tolerance, so the rate is measured tightly.
    stop_and_clear;
    sound_o(8'h26, 8'hF0);
    exp_b = 16.0 * TICK_B_CLK;
    measure_start_to_irq(8'h0A, 3000000, n_cycles);
    check_period(n_cycles, exp_b, "Timer B 16 counts");

    // ---- 3. the overflow flag is visible in the 0x188 status read --------
    // Read after the interrupt, so this asserts the guest can see what the
    // timer did through the same status byte a driver polls, rather than
    // inferring it from the RTL.
    read_status(st);
    if (st[1] !== 1'b1)
      fail("Timer B's overflow flag is not visible in the 0x188 status read");
    if (st[0] !== 1'b0)
      fail("Timer A's flag is set while Timer A is stopped");

    // ---- 4. the flag clears on the write a driver uses, and only then ----
    // 0x27 = 0x2A: bit1 keeps B running, bit3 keeps its IRQ enabled, bit5 is
    // the flag reset. A driver clears the flag from inside the interrupt it is
    // servicing, so the clear must not stop the timer.
    sound_o(8'h27, 8'h2A);
    repeat (60) @(posedge clk);
    read_status(st);
    if (st[1] !== 1'b0)
      fail("Timer B's flag did not clear on a 0x27 write with bit 5 set");
    if (irq !== 1'b0)
      fail("the IRQ stayed up after Timer B's flag was cleared");
    // ...and it must fire again, which also proves the clear did not stop it.
    n_cycles = 0;
    while (!irq && n_cycles < 3000000) begin @(posedge clk); n_cycles = n_cycles + 1; end
    if (!irq) begin
      $display("FAIL: Timer B stopped firing after its flag was cleared");
      errors = errors + 1;
    end

    // ---- 5. the per-timer IRQ enable genuinely gates the flag AND the line -
    // Start B with its IRQ *disabled*: 0x27 = 0x02, bit1 only. The enable must
    // gate the status-flag set too, not just the IRQ line: NP2kai's fmport_b
    // guards `status |= 0x02` with (reg[0x27] & 0x08) (opntimer.c:113-116),
    // ymfm's engine_timer_expired gates set_reset_status on enable_timer_b()
    // (ymfm_fm.ipp:1520-1525), and qemu's TimerBOver gates on (mode & 0x08)
    // (fmopn.c:853). So neither the flag nor the line may assert.
    stop_and_clear;
    sound_o(8'h26, 8'hFC);          // 256-252 = 4 counts, so it expires fast
    sound_o(8'h27, 8'h02);          // bit1 start, bit3 clear: no IRQ
    // 4 counts x 14423 clk = ~57692 clk; wait well past that.
    repeat (140000) @(posedge clk);
    read_status(st);
    if (st[1] !== 1'b0)
      fail("Timer B's overflow flag set although its IRQ enable (0x27 bit3) was clear");
    if (irq !== 1'b0)
      fail("the board raised IRQ although Timer B's IRQ enable was clear");

    // ---- 6. Timer A fires at its own rate --------------------------------
    // 64 counts: 1024-64 = 960 = 0x3C0, so 0x24 takes the high eight bits
    // (0xF0) and 0x25 the low two (0). 0x27 = 0x05: bit0 start, bit2 enable.
    stop_and_clear;
    sound_o(8'h24, 8'hF0);
    sound_o(8'h25, 8'h00);
    exp_a = 64.0 * TICK_A_CLK;
    measure_start_to_irq(8'h05, 3000000, n_cycles);
    check_period(n_cycles, exp_a, "Timer A 64 counts");

    read_status(st);
    if (st[0] !== 1'b1)
      fail("Timer A's overflow flag is not visible in the 0x188 status read");

    // ---- 7. the two rates relate by 16, with no clock assumption ---------
    // 2304/144 = 16, so one Timer B step is 16 Timer A steps. This is a
    // property of the chip alone: it holds whatever the master clock is, which
    // is what stops a wrong assumed clock from making the whole bench agree
    // with itself. It is asserted on the TICKS, so the different counts the
    // two measurements use cannot flatter it.
    if ((TICK_B_CLK / TICK_A_CLK) != 16.0) begin
      $display("FAIL: the Timer B/Timer A step ratio is %0.3f, not 16",
               TICK_B_CLK / TICK_A_CLK);
      errors = errors + 1;
    end else
      $display("  Timer B step / Timer A step = 16 (2304/144)");

    // ---- 8. the counter value is used, not ignored -----------------------
    // Double Timer A's count (64 -> 128) and the period must double. A counter
    // wired to a constant passes every absolute check above if the constant
    // happens to suit one value; this is the check that catches it. 128 counts
    // is 1024-128 = 896 = 0x380, so 0x24 = 0xE0 and 0x25 = 0.
    stop_and_clear;
    sound_o(8'h24, 8'hE0);          // 1024-128 = 896 = 0x380
    sound_o(8'h25, 8'h00);
    measure_start_to_irq(8'h05, 3000000, n_cycles);
    check_period(n_cycles, 2.0 * exp_a, "Timer A 128 counts");

    // ---- 9. the flag clears ONLY on the reset bit, not on a stop ---------
    // This is where NP2kai and the chip differ, and the bench follows the
    // CHIP. opna_settimer (opntimer.c:190-195) drops the event when the start
    // bit goes clear, and its fmport_a (:104) reports the flag as cleared with
    // it - a convenience of that model. The chip has an explicit flag reset
    // (0x27 bit 4 for A, bit 5 for B) and jt12 implements exactly that:
    // jt12_timer sets the flag only on its overflow and clears it only on
    // clr_flag (jt12_timers.v:120-126). So stopping a timer must LEAVE its flag
    // standing - a driver that stops a timer and then reads the flag is
    // reading why it stopped. Asserting NP2kai's behaviour here would have
    // made this bench demand something the hardware does not do.
    stop_and_clear;
    sound_o(8'h26, 8'hF0);
    sound_o(8'h27, 8'h0A);              // start B, IRQ on
    n_cycles = 0;
    while (!irq && n_cycles < 3000000) begin @(posedge clk); n_cycles = n_cycles + 1; end
    if (!irq) fail("Timer B never fired in the stop-versus-clear check");
    sound_o(8'h27, 8'h08);              // bit3 only: B's IRQ enable, START BIT CLEAR
    repeat (60) @(posedge clk);
    read_status(st);
    if (st[1] !== 1'b1)
      fail("Timer B's flag was cleared by stopping the timer; only the 0x27 reset bit 5 may clear it");
    // ...and the reset bit does clear it, which is the path a driver uses.
    sound_o(8'h27, 8'h28);              // bit3 + bit5: the flag reset
    repeat (60) @(posedge clk);
    read_status(st);
    if (st[1] !== 1'b0)
      fail("Timer B's flag did not clear on a 0x27 write with bit 5 set");
    if (irq !== 1'b0)
      fail("the IRQ stayed up after Timer B's flag was cleared");

    // ---- 10. the timer IRQ reaches the slave 8259 as IRQ12, vector 0x14 ------
    // The board's factory-default DIP setting INT5 is IRQ12 (the slave's IR4), and PMD
    // selects that level from PSG register 0x0E's readback, so the
    // line every check above measured must land on the SLAVE and answer vector 0x14, not
    // on the master and answer IRQ5's 0x0D. pic_slave_irq is this bench's copy of the
    // system's concatenation, so this proves the OPNA reaches the slave as IRQ12 when
    // wired that way; the system's own expression is the change under test.
    pic_rst_n = 1;
    repeat (4) @(posedge clk);
    // Firmware ICW values: master ICW2 0x08 with the cascade on IRQ7 (ICW3 0x80) and
    // ICW4 0x1D (SFNM, buffered master); slave ICW2 0x10, ICW3 0x07, ICW4 0x01. Only the
    // cascade is unmasked on the master, and only IR4 on the slave, so nothing else can
    // be the source of the INT below.
    pic_write(16'h0000, 8'h11); pic_write(16'h0002, 8'h08);
    pic_write(16'h0002, 8'h80); pic_write(16'h0002, 8'h1D);
    pic_write(16'h0002, 8'h7F);
    pic_write(16'h0008, 8'h11); pic_write(16'h000A, 8'h10);
    pic_write(16'h000A, 8'h07); pic_write(16'h000A, 8'h01);
    pic_write(16'h000A, 8'hEF);
    repeat (8) @(posedge clk);
    if (pic_cpu_intr)
      fail("the PIC asserted INT before the OPNA raised its timer IRQ");

    // Start Timer B with its IRQ enabled - the shape PMD uses - and wait for the pair.
    sound_o(8'h26, 8'hF0);
    sound_o(8'h27, 8'h0A);
    n_cycles = 0;
    while (!pic_cpu_intr && n_cycles < 3000000) begin @(posedge clk); n_cycles = n_cycles + 1; end
    if (!pic_cpu_intr)
      fail("the OPNA timer IRQ never reached the 8259");
    // The request is in service as the master's cascade (IRQ7) and the slave's IR4.
    if (pic.dbg_irr[7] !== 1'b1)
      fail("the sound line did not raise the master's cascade input (IRQ7)");
    if (pic.dbg_irr[5] !== 1'b0)
      fail("the sound line raised master IRQ5; the factory-default line is the slave's IRQ12");
    if (pic.slave.ir_latch[4] !== 1'b1)
      fail("the sound line did not latch the slave's IR4 (system IRQ12)");

    // Two INTA assertions are one acknowledge; the vector is valid after the second.
    inta_cycle();
    inta_cycle();
    if (pic_inta_din[7:0] !== 8'h14) begin
      $display("FAIL: the OPNA timer IRQ answered vector %02x, want 14 (slave IR4)",
               pic_inta_din[7:0]);
      errors = errors + 1;
    end
    if (pic.slave.isr !== 8'h10)
      fail("the acknowledge did not put the slave's IR4 in service");
    // The request is a level the OPNA holds until its flag is cleared, so it is still high
    // after the acknowledge; clearing the flag drops it.
    sound_o(8'h27, 8'h28);
    repeat (60) @(posedge clk);
    if (irq !== 1'b0)
      fail("the OPNA IRQ stayed up after Timer B's flag was cleared in the routing check");

    // ---- VERDICT ----
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_TIMERS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_TIMERS: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: measured periods total well under 200 ms of simulated
  // time, so this is a generous bound that still catches a hang.
  initial begin
    #600_000_000;
    $fatal(1, "TB_PC9821_OPNA_TIMERS: TIMEOUT");
  end

endmodule

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PIT_DRIVER_RATE:
// The PIT's channel-0 tick rate is the DEVICE's, not a clk_sys count: programmed exactly as the Rusty intro's sound drivers program it (control word 0x36 to 0x77 = channel 0, LSB-then-MSB, mode 3, binary; divisor 0x00F6 = 246 to 0x71 twice, the port-0x42 bit-5 strap reading 0), the OUT0 interval is 246 / 2.4576 MHz = 100.0977 us -- 9990.24 Hz -- in simulated REAL TIME at 50 MHz, so the intro's INT 08h-driven music/PCM tick is 9990.24 Hz and not a cycle count that would move with the build profile. Mode 2 (rate generator) at the same divisor produces the same interrupt period with a one-tick-wide low pulse, mode 3 a 50 % square at that period (so a mode 2/3 mix-up is visible as the duty, not hidden as a rate), LSB-only and MSB-only access program the same period as LSB+MSB, a mid-flight reprogram to divisor 200 (0x00C8, the drivers' other strap arm) takes effect without stopping the channel, and the source-tick generator itself runs at 2457600/50000000 of clk_sys (49152 ticks per 1000000 cycles) - the constant that scales every tick.
//
// Fail-first: every expected value here is derived from INPUT_CLOCK_HZ
// (2.4576 MHz) and the guest's divisor, never from this RTL's own counts. The
// bench asserts the RATIONAL identity `interval_cycles * 2_457_600 ==
// periods * divisor * SYS_CLOCK_HZ` (within one clk_sys cycle), which is the
// same statement as `interval / periods == divisor / 2.4576 MHz` with the
// conversion done by the DEVICE clock - so a model that counted clk_sys
// instead, or that used the 8 MHz-series 1.9968 MHz input clock (the other
// strap arm's 1996800/200), or that confused the divisor with mode 3's
// half-period, fails by name.
//
// SOURCES OF THE NUMBERS (AGENTS.md evidence hierarchy):
//  * the input clock 2.4576 MHz: NP2kai counts the channel-0 period in
//    `pccore.multiple` CPU clocks off `pccore.baseclock`, which is
//    PCBASECLOCK25 = 2457600 for this strap (pccore.h:11, pccore.c:447-455,
//    io/pit.c:19-35); qemu-pc98 hard-codes the same PC98_PIT_FREQ
//    (hw/timer/i8254-pc98.c:61). The references diverge only for the 8 MHz
//    clock series (NP2kai's configurable 1996800, qemu's comment at
//    i8254-pc98.c:57-60) - which the strap rules out here.
//  * the drivers' program: PMD.COM file 0x358B, PMDB2.COM 0x442D, PDR.COM
//    0x008A/0x0B4A (all five sites decoded from the binaries).
//  * the strap: the machine's own `0042=94` - bit 5 CLEAR - in
//    docs/probes/MEMSW.TXT:72 and docs/probes/PIT-fixed.TXT:72, which is the
//    branch that loads divisor 0x00F6; our pc9821_iobus answers the same 0x94
//    (its HX_0042 read arm), so the driver picks the same arm on both machines.

`default_nettype none

module tb_pc9821_pit_driver_rate;

  // ==== DUT ====

  // The shipped profile's clock - pc9821_system.sv:310 (parameter SYS_FREQ = 50_000_000;) -
  // so the divider this bench measures is the one the machine builds.
  localparam integer SYS_HZ = 50_000_000;
  // The PIT's own input clock, as the references give it - never read out of the
  // DUT's INPUT_CLOCK_HZ parameter, which would make this circular.
  localparam integer PIT_HZ = 2_457_600;
  localparam integer CLK_NS = 1_000_000_000 / SYS_HZ;   // 20 ns

  // The divisors under test. 246 is the arm this machine's strap selects
  // (0x00F6), 200 the other one (0x00C8), and 256 the MSB-only case's divisor
  // (0x0100, so a single MSB byte is the whole divisor).
  localparam integer DIV_STRAP5 = 246;    // 0x00F6 -> 9990.2439 Hz (strap bit 5 = 0)
  localparam integer DIV_STRAP8 = 200;    // 0x00C8 -> 12288 Hz (strap bit 5 = 1)
  localparam integer DIV_MSB    = 256;    // 0x0100 -> 9600 Hz

  reg clk = 1'b0;
  always #(CLK_NS / 2) clk = ~clk;

  reg rst_n = 1'b0;
  reg       cs = 1'b0;
  reg       wr = 1'b0;
  reg       rd = 1'b0;
  reg [1:0] addr = 2'd0;
  reg [7:0] din = 8'h00;
  wire [7:0] dout;
  wire out0, out1, out2;

  pc9821_pit #(.SYS_CLOCK_HZ(SYS_HZ)) dut (
      .clk(clk), .rst_n(rst_n), .cs(cs), .addr(addr), .wr(wr), .rd(rd),
      .din(din), .dout(dout), .out0(out0), .out1(out1), .out2(out2));

  integer errors = 0;
  integer checks = 0;

  // ==== STIMULUS ====

  task automatic pit_write(input [1:0] port, input [7:0] value);
    begin
      @(negedge clk);
      addr = port; din = value; cs = 1'b1; wr = 1'b1;
      @(posedge clk);
      @(negedge clk);
      cs = 1'b0; wr = 1'b0;
    end
  endtask

  // Program channel 0 the way PMD.COM / PMDB2.COM / PDR.COM do it - control
  // word first, then the divisor's low byte and high byte (PDR.COM's helper at
  // file 0x008A is exactly `mov al,0x36 / out 0x77,al / mov al,cl / out
  // 0x71,al / mov al,ch / out 0x71,al`).
  task automatic program_ch0(input [7:0] ctrl, input integer divisor);
    begin
      pit_write(2'd3, ctrl);                     // 0x77: the control word
      pit_write(2'd0, divisor[7:0]);             // 0x71: LSB
      pit_write(2'd0, divisor[15:8]);            // 0x71: MSB
    end
  endtask

  // Wait for one OUT0 rising edge, sampled on clk.
  task automatic wait_rise;
    reg prev;
    begin
      prev = out0;
      forever begin
        @(posedge clk);
        if (out0 && !prev) break;
        prev = out0;
      end
    end
  endtask

  // Wait for one OUT0 falling edge, sampled on clk.
  task automatic wait_fall;
    reg prev;
    begin
      prev = out0;
      forever begin
        @(posedge clk);
        if (!out0 && prev) break;
        prev = out0;
      end
    end
  endtask

  // The interval spanning `periods` full OUT0 periods, in clk_sys cycles. Both
  // endpoints are a rising edge, so no partial period is included.
  task automatic measure_periods(input integer periods, output integer cycles);
    time t0, t1;
    integer n;
    begin
      wait_rise;
      t0 = $time;
      for (n = 0; n < periods; n = n + 1) begin
        wait_rise;
        t1 = $time;
      end
      cycles = (t1 - t0) / CLK_NS;
    end
  endtask

  // The HIGH and LOW half of one OUT0 period, in clk_sys cycles: this is what
  // separates mode 3 (a 50 % square) from mode 2 (low for one source tick) at
  // the SAME interrupt rate.
  task automatic measure_duty(output integer high_cycles, output integer low_cycles);
    time t0, t1, t2;
    begin
      wait_rise;
      t0 = $time;
      wait_fall;
      t1 = $time;
      wait_rise;
      t2 = $time;
      high_cycles = (t1 - t0) / CLK_NS;
      low_cycles  = (t2 - t1) / CLK_NS;
    end
  endtask

  // ==== CHECKS ====

  // The reference statement, in exact integer arithmetic: `periods` periods of
  // `divisor` source ticks is `periods * divisor / PIT_HZ` seconds, which is
  // `periods * divisor * SYS_HZ / PIT_HZ` clk_sys cycles. One clk_sys cycle of
  // slack, because each edge is sampled on a clk edge.
  task automatic check_period(input string label, input integer cycles,
                              input integer periods, input integer divisor);
    longint want;      // periods * divisor * SYS_HZ: 100 * 246 * 50e6 = 1.23e12
    begin
      checks = checks + 1;
      want = longint'(periods) * longint'(divisor) * longint'(SYS_HZ);
      if ((longint'(cycles) * longint'(PIT_HZ) > want + longint'(PIT_HZ)) ||
          (longint'(cycles) * longint'(PIT_HZ) + longint'(PIT_HZ) < want)) begin
        $display("FAIL: %0s measured %0d cycles over %0d periods = %0.4f us/period; the device clock's %0d/%0d = %0.4f us/period (%0.4f Hz)",
                 label, cycles, periods, (cycles * 1.0e6 / SYS_HZ) / periods,
                 divisor, PIT_HZ, (divisor * 1.0e6) / PIT_HZ, PIT_HZ * 1.0 / divisor);
        errors = errors + 1;
      end else begin
        $display("  OK   %0s %0d cycles / %0d periods = %0.4f us/period (reference %0d/%0d = %0.4f us, %0.4f Hz)",
                 label, cycles, periods, (cycles * 1.0e6 / SYS_HZ) / periods,
                 divisor, PIT_HZ, (divisor * 1.0e6) / PIT_HZ, PIT_HZ * 1.0 / divisor);
      end
    end
  endtask

  // A printed, non-asserted measurement: the one-byte-write byte-retention
  // divergence (see the note at case D).
  task automatic observe_period(input string label, input integer cycles,
                                input integer periods, input integer div_lo,
                                input integer div_hi);
    begin
      $display("  OBS  %0s %0d cycles / %0d periods = %0.4f us/period; divisor %0d would be %0.4f us, %0d would be %0.4f us",
               label, cycles, periods, (cycles * 1.0e6 / SYS_HZ) / periods,
               div_lo, (div_lo * 1.0e6) / PIT_HZ, div_hi, (div_hi * 1.0e6) / PIT_HZ);
    end
  endtask

  integer cycles;
  integer high_3, low_3, high_2, low_2;
  integer tick_count;
  integer i;

  // ==== VERDICT ====
  initial begin
    repeat (8) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (8) @(posedge clk);

    $display("TB_PC9821_PIT_DRIVER_RATE: PIT input clock %0d Hz, SYS_CLOCK_HZ %0d, driver divisor %0d",
             PIT_HZ, SYS_HZ, DIV_STRAP5);

    // ---- 1. the source-tick generator itself: 2457600/50000000 of clk_sys ----
    // 1000000 cycles x 2457600/50000000 = 49152 ticks exactly. A model whose
    // INPUT_CLOCK_HZ were wrong (the 8 MHz series' 1996800 -> 39936, or 4915200
    // doubled -> 98304) fails here by name; one tick of slack covers the
    // window's phase.
    tick_count = 0;
    for (i = 0; i < 1_000_000; i = i + 1) begin
      @(posedge clk);
      if (dut.pit_tick) tick_count = tick_count + 1;
    end
    checks = checks + 1;
    if (tick_count < 49151 || tick_count > 49152) begin
      $display("FAIL: %0d source ticks per 1000000 cycles; 2457600/50000000 of clk_sys is 49152 (INPUT_CLOCK_HZ is not 2.4576 MHz)",
               tick_count);
      errors = errors + 1;
    end else begin
      $display("  OK   source tick generator: %0d ticks / 1000000 cycles (49152 = 2457600/50000000 x 1000000)",
               tick_count);
    end

    // ---- 2. the drivers' exact program: control 0x36, divisor 0x00F6, mode 3 ----
    program_ch0(8'h36, DIV_STRAP5);
    measure_duty(high_3, low_3);
    $display("  mode 3 duty: high %0d cycles, low %0d cycles (123 source ticks each = 50 %%)", high_3, low_3);
    checks = checks + 1;
    // Divisor 246 in mode 3 is a 123/123 square: 123 ticks = 2502.4 cycles per
    // half at 50 MHz. A mode-2 program at the SAME divisor holds OUT high for
    // 245 ticks and low for one (about 4984 and 20 cycles) - the same interrupt
    // rate, a different shape - which is why the duty is asserted and not only
    // the period.
    if ((high_3 < 2500) || (high_3 > 2505) || (low_3 < 2500) || (low_3 > 2505)) begin
      $display("FAIL: mode 3 at divisor 246 is not a 50 %% square (high %0d / low %0d cycles; mode 2's shape is ~4984/20)",
               high_3, low_3);
      errors = errors + 1;
    end
    measure_periods(100, cycles);
    check_period("mode 3  LB+MB 0x00F6:", cycles, 100, DIV_STRAP5);

    // ---- 3. mode 2 at the same divisor: the SAME interrupt period ----
    program_ch0(8'h34, DIV_STRAP5);   // 0x34 = ch0, LB+MB, mode 2, binary
    measure_duty(high_2, low_2);
    $display("  mode 2 duty: high %0d cycles, low %0d cycles (one source tick low = 20.35 cycles)", high_2, low_2);
    checks = checks + 1;
    if ((low_2 < 20) || (low_2 > 22) || (high_2 < 4980) || (high_2 > 4990)) begin
      $display("FAIL: mode 2 at divisor 246 is not one source tick low (high %0d / low %0d cycles)", high_2, low_2);
      errors = errors + 1;
    end
    measure_periods(100, cycles);
    check_period("mode 2  LB+MB 0x00F6:", cycles, 100, DIV_STRAP5);

    // ---- 4. LSB-only access - the count register is first set with an explicit
    //         WORD write, so the byte this access mode does NOT write is a ZERO
    //         the guest asked for rather than a leftover from an earlier case: ----
    // The references disagree about the byte a one-byte write leaves behind -
    // QEMU zeroes it (`pit_load_count(s, val << 8)` for RW_STATE_MSB,
    // hw/timer/i8254.c:222-224) and so does NP2kai (`pitch->value = value << 8`,
    // io/pit.c:275-277), while this RTL retains it - and the machine-side answer
    // is one of the probe's gated rows (todo/2-probe-corrections.md item 10). So
    // every ASSERTED one-byte case here is written to be true under either rule,
    // and the divergence is measured in the OBS line at case 6 instead.
    program_ch0(8'h34, 16'h0000);       // both bytes explicit: count = 0x0000
    pit_write(2'd3, 8'h14);             // ch0, LSB only, mode 2
    pit_write(2'd0, DIV_STRAP5[7:0]);   // 0xF6 -> 0x00F6 under either rule
    measure_periods(100, cycles);
    check_period("mode 2  LSB  0x00F6:", cycles, 100, DIV_STRAP5);

    // ---- 5. MSB-only access ----
    program_ch0(8'h34, 16'h0000);       // both bytes explicit again, so the low
                                        // byte this mode does not write is 0x00
    pit_write(2'd3, 8'h24);             // ch0, MSB only, mode 2
    pit_write(2'd0, DIV_MSB[15:8]);     // 0x01 -> 0x0100 under either rule
    measure_periods(100, cycles);
    check_period("mode 2  MSB  0x0100:", cycles, 100, DIV_MSB);

    // ---- 6. OBSERVED, NOT ASSERTED: the byte a one-byte write leaves behind ----
    // A known non-zero low byte goes in first (an LSB-only write of 0xF6), then
    // an MSB-only write of 0x00 either leaves it alone (this RTL: 0x00F6 = 246)
    // or zeroes the whole count (QEMU and NP2kai: 0x0000 = 65536). The OBS line
    // prints the measurement and both candidate periods; nothing asserts which.
    program_ch0(8'h34, 16'h0000);
    pit_write(2'd3, 8'h14);             // LSB only
    pit_write(2'd0, 8'hF6);             // low byte = 0xF6
    pit_write(2'd3, 8'h24);             // MSB only
    pit_write(2'd0, 8'h00);             // high byte = 0x00
    measure_periods(50, cycles);
    observe_period("MSB-only write with a 0xF6 low byte:", cycles, 50,
                   DIV_STRAP5, 65536);

    // ---- 7. a mid-flight reprogram, the way the drivers do it ----
    // PDR.COM's install path (file 0x0B4A) and its per-playback path (the helper
    // at file 0x008A, called from 0x01FE) both write the control word and then
    // the two data bytes with the channel RUNNING, so the new rate must take
    // effect without a stop. 0x00C8 is the drivers' other strap arm.
    program_ch0(8'h36, DIV_STRAP8);
    measure_periods(100, cycles);
    check_period("reprogram ->0x00C8:", cycles, 100, DIV_STRAP8);
    program_ch0(8'h34, DIV_STRAP5);
    measure_periods(100, cycles);
    check_period("reprogram ->0x00F6:", cycles, 100, DIV_STRAP5);

    // The marker is a STANDALONE literal on its own line (tools/bench.py's runner
    // verdict); a count on the same $display leaves it unmatched, so the check
    // count goes on its own line.
    if (errors == 0) begin
      $display("  %0d checks", checks);
      $display("TB_PC9821_PIT_DRIVER_RATE: PASS");
    end else $fatal(1, "TB_PC9821_PIT_DRIVER_RATE: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #500_000_000;      // 500 ms; the whole run is about 80 ms of simulated time
    $fatal(1, "TB_PC9821_PIT_DRIVER_RATE: timeout");
  end

endmodule

`default_nettype wire

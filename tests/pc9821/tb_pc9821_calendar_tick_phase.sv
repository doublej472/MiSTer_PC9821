`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_CALENDAR_TICK_PHASE: a 0x128 write does not restart the calendar's interval tick (IRQ15), as kit 2's /AUDIT2 CALIRR rows show (docs/probes/KIT2-XE10-AUDIT2.TXT:31-41: the first fall after 0x128 <- 81, 80 or 83 lands inside one period, at 5311 and 8013 of 9600 ARTIC ticks, 609 and 3366 of 4800, 14994 and 17858 of 19200): on a 1 MHz instance, with the tick running at 0x81, rewriting 0x81 half a period after a tick brings the next fall half a period later (not a whole period), and switching to 0x80 or 0x83 mid-period brings the first fall sooner than the new rate's period; and a write that lands on the cycle of a tick is merged with it (docs/single-cycle-event-discipline.md R4): the tick is judged by the rate and enable written, so 0x80 written there still falls and sets the tick flag (0x90 read back) and 0x82 written there neither falls nor sets it.
//
// WHERE THE EXPECTED VALUES COME FROM: kit 2's /AUDIT2 run on the Xe10,
// docs/probes/KIT2-XE10-AUDIT2.TXT, the CALIRR rows. Each row writes its 0x128 value, reads
// 0x128, takes its time origin from the ARTIC counter, then samples the line for 100 ms
// (tools/hwprobe/xe10t/sec_audit2.inc a2_calirr); `e=` lists the edges in ARTIC ticks from
// that origin, a fall negative:
//   cfg=81 mode=N ... e=-5311,+5312,-14912,..   cfg=81 mode=R ... e=-8013,+8015,-17615,..
//   cfg=80 mode=N ... e=-609,+611,-5410,..      cfg=80 mode=R ... e=-3366,+3368,-8167,..
//   cfg=83 mode=N ... e=-14994,+14995           cfg=83 mode=R ... e=-17858,+17859
// The periods are 9600, 4800 and 19200 ticks (31.25, 15.625 and 62.5 ms at 307.2 kHz). A
// restart at the write would put every first fall a whole period out; each lands inside one,
// at a phase that differs between rows, so the tick runs free across the write. The phase a
// write lands at is the bench's own choice (the capture does not control it); what is
// asserted is that the tick keeps its phase across the write.
//
// The write-on-tick cycle is the merge rule of the module, not a capture.
//
// ==== DUT ====
// pc9821_calendar at SYS_CLOCK_HZ = 1 MHz: 1/64 s is 15625 cycles.

`default_nettype none

module tb_pc9821_calendar_tick_phase;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  localparam integer HZ  = 1_000_000;
  localparam integer P64 = HZ / 64;     // 15625
  localparam integer P32 = HZ / 32;     // 31250
  localparam integer P16 = HZ / 16;     // 62500

  reg        tick_we = 0, tick_rd = 0;
  reg  [7:0] tick_din = 0;
  wire [7:0] mode_dout, tick_dout;
  wire       cdat, irq;

  pc9821_calendar #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .rst_n(rst_n),
      .rtc_bcd(56'd0), .rtc_load(1'b0),
      .cmd_we(1'b0), .cmd_din(8'h00),
      .mode_we(1'b0), .mode_din(8'h00), .mode_dout(mode_dout),
      .tick_we(tick_we), .tick_rd(tick_rd), .tick_din(tick_din), .tick_dout(tick_dout),
      .cdat(cdat), .irq(irq));

  integer errors = 0;
  task automatic fail(input string message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS ====
  task automatic write_128(input [7:0] d);
    begin
      @(negedge clk); tick_din = d; tick_we = 1;
      @(negedge clk); tick_we = 0;
    end
  endtask
  task automatic read_128(output [7:0] d);
    begin
      @(negedge clk); tick_rd = 1; d = tick_dout;
      @(negedge clk); tick_rd = 0;
    end
  endtask
  // Cycles from now to the line's next fall (high -> low), or -1 past `limit`.
  task automatic cycles_to_fall(input integer limit, output integer n);
    reg prev;
    begin
      n = 0;
      prev = irq;
      forever begin
        @(posedge clk); #1;
        n = n + 1;
        if (prev && !irq) disable cycles_to_fall;
        if (n > limit) begin n = -1; disable cycles_to_fall; end
        prev = irq;
      end
    end
  endtask

  // ==== CHECKS ====
  // Each write's first fall measured against the tick's own phase and the rate's period.
  integer n, k;
  reg [7:0] v;

  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1;

    // ==== the tick runs at 0x81 (32 Hz); sync to a fall ====
    write_128(8'h81);
    cycles_to_fall(2 * P32, n);
    if (n < 0) fail("no tick at 0x81");
    cycles_to_fall(2 * P32, n);
    if (n < 0 || n < P32 - 4 || n > P32 + 4) fail($sformatf("0x81 period is %0d cycles, not %0d", n, P32));

    // ==== REWRITE 81 half a period after a tick (the R row: 81 after 81) ====
    // The write strobe lands 2 clocks into write_128, the read 2 more: the remaining phase
    // to the next tick is P32/2 from the bench's wait.
    repeat (P32 / 2 - 1) @(posedge clk);
    write_128(8'h81);
    read_128(v);
    cycles_to_fall(2 * P32, n);
    $display("  REWRITE 81: first fall %0d cycles after the write (period %0d)", n, P32);
    if (n < 0 || n >= P32 - 8)
      fail($sformatf("0x81 rewritten mid-period: first fall after %0d cycles, a whole period (machine: inside one period, 5311 and 8013 of 9600)", n));
    else if (n > P32 / 2 + 8 || n < P32 / 2 - 8)
      fail($sformatf("0x81 rewritten mid-period: first fall after %0d cycles, not the tick's own phase (%0d)", n, P32 / 2));

    // ==== 81 -> 80 (64 Hz) a quarter period after a tick ====
    repeat (P32 / 4) @(posedge clk);
    write_128(8'h80);
    read_128(v);
    cycles_to_fall(2 * P32, n);
    $display("  81->80: first fall %0d cycles after the write (period %0d)", n, P64);
    if (n < 0 || n >= P64 - 8)
      fail($sformatf("0x80 written mid-period: first fall after %0d cycles, not inside one 1/64 s period (machine: 609 and 3366 of 4800)", n));

    // ==== 80 -> 83 (16 Hz) just after a tick ====
    repeat (16) @(posedge clk);
    write_128(8'h83);
    read_128(v);
    cycles_to_fall(2 * P16, n);
    $display("  80->83: first fall %0d cycles after the write (period %0d)", n, P16);
    if (n < 0 || n >= P16 - 8)
      fail($sformatf("0x83 written: first fall after %0d cycles, not inside one 1/16 s period (machine: 14994 and 17858 of 19200)", n));

    // ==== a write on the tick's own cycle (R4 merge) ====
    // 0x80 written on the cycle of a 1/64 s step: that step is a 64 Hz tick.
    write_128(8'h81);
    read_128(v);                                   // clear the flag
    @(negedge clk);
    while (dut.tick_div != 23'(P64 - 2)) @(negedge clk);
    // the strobe is high for the posedge at which tick_div == P64 - 1 (the step)
    @(negedge clk); tick_din = 8'h80; tick_we = 1;
    #1 if (dut.tick_div !== 23'(P64 - 1)) fail("bench: the write did not land on the step");
    @(negedge clk); tick_we = 0;
    #1 if (irq !== 1'b0) fail("0x80 written on a tick's cycle: the tick did not lower the line");
    read_128(v);
    if (v !== 8'h90) fail($sformatf("0x80 written on a tick's cycle: 0x128 read %02x, not 0x90 (the tick lost)", v));
    // 0x82 (off) written on a step: no tick, no flag.
    repeat (20) @(posedge clk);
    @(negedge clk);
    while (dut.tick_div != 23'(P64 - 2)) @(negedge clk);
    @(negedge clk); tick_din = 8'h82; tick_we = 1;
    @(negedge clk); tick_we = 0;
    read_128(v);
    if (v !== 8'h82) fail($sformatf("0x82 written on a tick's cycle: 0x128 read %02x, not 0x82", v));
    for (k = 0; k < 3 * P64; k = k + 1) begin
      @(posedge clk);
      if (irq !== 1'b0) begin fail("0x82: the line rose with the tick off"); k = 3 * P64; end
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CALENDAR_TICK_PHASE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_CALENDAR_TICK_PHASE: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000_000;
    $fatal(1, "TB_PC9821_CALENDAR_TICK_PHASE: TIMEOUT");
  end

endmodule

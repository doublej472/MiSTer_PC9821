// tb_pc9821_pit - focused PC-98 PIT source-clock and zero-divisor checks.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PIT:
// The PIT's tick rate and zero-divisor behaviour, instantiated at the clock frequency the system ships (50 MHz) with the divider derived from the verified 2.4576 MHz input strap, so the counts here are the ones the hardware produces. The read side is pinned against the real 8253/8254 counting element too: a mode-3 read spans 0..N - the full divisor, down by 2 per source clock, QEMU hw/timer/i8254-pc98.c:100-103 `counter = count - ((2*d) % count)` - never the 0..N/2 half-count model; read-back STATUS bit 6 is the LIVE NULL COUNT (set by a control word, cleared by the count byte that COMPLETES the load, 8254 / NP2kai io/pit.c:244-254,307); and mode 0 keeps counting past terminal count, wrapping to 0xFFFF, instead of freezing at 0.


module tb_pc9821_pit;

  reg clk = 0;
  // 50 MHz, the frequency the system instantiates (SYS_FREQ), so the divider's
  // parameter and the bench clock agree with the shipped configuration.
  always #10 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, wr = 0, rd = 0;
  reg  [1:0] addr = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  wire out0, out1, out2;

  // ==== DUT ====
  pc9821_pit #(.SYS_CLOCK_HZ(50_000_000)) dut (
      .clk(clk),
      .rst_n(rst_n),
      .cs(cs),
      .addr(addr),
      .wr(wr),
      .rd(rd),
      .din(din),
      .dout(dout),
      .out0(out0),
      .out1(out1),
      .out2(out2)
  );

  reg [7:0] lo = 0, hi = 0, st = 0;
  reg [15:0] latched = 0, v1 = 0, v2 = 0, maxv = 0;
  integer errors = 0;
  integer ticks = 0;
  integer cycles;
  integer k;
  // ==== STIMULUS ====

  task write_pit(input [1:0] port, input [7:0] value);
    begin
      @(negedge clk);
      addr = port;
      din  = value;
      cs   = 1;
      wr   = 1;
      @(posedge clk);
      @(negedge clk);
      cs = 0;
      wr = 0;
    end
  endtask

  task read_pit(input [1:0] port, output [7:0] value);
    begin
      @(negedge clk);
      addr = port;
      cs   = 1;
      rd   = 1;
      @(posedge clk);
      value = dout;
      @(negedge clk);
      cs = 0;
      rd = 0;
    end
  endtask
  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;

    // 100000 system clocks at 50 MHz contain floor(100000*2457600/50000000)
    // source enables, allowing one count of edge-placement tolerance.
    ticks = 0;
    for (cycles = 0; cycles < 100000; cycles = cycles + 1) begin
      @(posedge clk);
      if (dut.pit_tick) ticks = ticks + 1;
    end
    if (ticks < 4915 || ticks > 4916) begin
      $display("FAIL: PIT source ticks=%0d want 4915/4916", ticks);
      errors = errors + 1;
    end

    // Channel 0, LSB/MSB, mode 0, binary; 0000 means 65536.
    write_pit(2'd3, 8'h30);
    write_pit(2'd0, 8'h00);
    write_pit(2'd0, 8'h00);
    ticks = 0;
    while (!out0 && ticks <= 65537) begin
      @(posedge clk);
      if (dut.pit_tick) ticks = ticks + 1;
    end
    if (!out0 || ticks < 65535 || ticks > 65537) begin
      $display("FAIL: zero divisor terminal count ticks=%0d out0=%b", ticks, out0);
      errors = errors + 1;
    end

    // BIOS IRQ0 handling reloads the existing mode-0 channel without a new
    // control word. The completed LSB/MSB write must lower OUT so another
    // terminal count creates a new interrupt edge.
    write_pit(2'd0, 8'h03);
    write_pit(2'd0, 8'h00);
    if (out0) begin
      $display("FAIL: mode-0 reload did not lower OUT");
      errors = errors + 1;
    end
    ticks = 0;
    while (!out0 && ticks <= 4) begin
      @(posedge clk);
      if (dut.pit_tick) ticks = ticks + 1;
    end
    if (!out0 || ticks < 2 || ticks > 4) begin
      $display("FAIL: mode-0 rearm ticks=%0d out0=%b", ticks, out0);
      errors = errors + 1;
    end

    // Mode 2 is high for N-1 clocks and low for one clock.
    write_pit(2'd3, 8'h34);  // channel 0, LSB/MSB, mode 2
    write_pit(2'd0, 8'h04);
    write_pit(2'd0, 8'h00);
    ticks = 0;
    while (out0 && ticks <= 6) begin
      @(posedge clk);
      if (dut.pit_tick) ticks = ticks + 1;
    end
    if (out0 || ticks != 4) begin
      $display("FAIL: mode-2 terminal pulse ticks=%0d out0=%b", ticks, out0);
      errors = errors + 1;
    end
    ticks = 0;
    while (!out0 && ticks <= 2) begin
      @(posedge clk);
      if (dut.pit_tick) ticks = ticks + 1;
    end
    if (!out0 || ticks != 1) begin
      $display("FAIL: mode-2 low width ticks=%0d out0=%b", ticks, out0);
      errors = errors + 1;
    end

    // Mode 3 divisor 4 has two-clock high and low half-periods, not a
    // four-clock half-period (which would halve the programmed frequency).
    write_pit(2'd3, 8'h36);  // channel 0, LSB/MSB, mode 3
    write_pit(2'd0, 8'h04);
    write_pit(2'd0, 8'h00);
    ticks = 0;
    while (out0 && ticks <= 4) begin
      @(posedge clk);
      if (dut.pit_tick) ticks = ticks + 1;
    end
    if (out0 || ticks != 2) begin
      $display("FAIL: mode-3 high half ticks=%0d out0=%b", ticks, out0);
      errors = errors + 1;
    end
    ticks = 0;
    while (!out0 && ticks <= 4) begin
      @(posedge clk);
      if (dut.pit_tick) ticks = ticks + 1;
    end
    if (!out0 || ticks != 2) begin
      $display("FAIL: mode-3 low half ticks=%0d out0=%b", ticks, out0);
      errors = errors + 1;
    end

    // Mode 3 divisor 5 (odd divisor): high half is 3 clocks, low half is 2 clocks.
    write_pit(2'd3, 8'h36);  // channel 0, LSB/MSB, mode 3
    write_pit(2'd0, 8'h05);
    write_pit(2'd0, 8'h00);
    ticks = 0;
    while (out0 && ticks <= 5) begin
      @(posedge clk);
      if (dut.pit_tick) ticks = ticks + 1;
    end
    if (out0 || ticks != 3) begin
      $display("FAIL: mode-3 odd divisor high half ticks=%0d out0=%b", ticks, out0);
      errors = errors + 1;
    end
    ticks = 0;
    while (!out0 && ticks <= 4) begin
      @(posedge clk);
      if (dut.pit_tick) ticks = ticks + 1;
    end
    if (!out0 || ticks != 2) begin
      $display("FAIL: mode-3 odd divisor low half ticks=%0d out0=%b", ticks, out0);
      errors = errors + 1;
    end

    // Channel-select 3 is read-back/reserved and must not touch an
    // out-of-range fourth channel or disturb channel 0.
    write_pit(2'd3, 8'hC0);
    if (dut.reload[0] !== 16'h0005 || dut.mode[0] !== 3'd3) begin
      $display("FAIL: read-back command disturbed channel 0");
      errors = errors + 1;
    end

    // ------------------------------------------------------------------
    // Counter readback: a latched value is consumed over its LSB/MSB pair, and
    // the access mode decides which byte(s) a read returns. NP2kai's
    // pit_getstat() clears the latch flag on the first read and toggles the
    // byte selector for a 16-bit read; before this was implemented the latch was
    // never consumed (so one latch command froze the channel for the rest of the
    // session) and every read returned the LSB twice.
    //
    // The VALUE is the 8253/8254 counting element, which in mode 3 holds the
    // FULL divisor and decrements by 2 per source clock, so a read spans 0..N
    // (NP2kai io/pit.c:168-230 returns 0..value for modes 2 and 3 alike; QEMU
    // hw/timer/i8254-pc98.c:100-103 converts
    // counter = count - ((2*d) % count)). The half-count model this bench used
    // to assert ("the count tops out at 0x8000") is exactly the defect.
    // ------------------------------------------------------------------
    // Channel 0, LSB-then-MSB access, mode 3, a long reload so the count barely moves.
    write_pit(2'd3, 8'h36);
    write_pit(2'd0, 8'hFF);
    write_pit(2'd0, 8'hFF);
    repeat (6) @(posedge clk);
    write_pit(2'd3, 8'h00);          // latch channel 0
    read_pit(2'd0, lo);
    read_pit(2'd0, hi);
    latched = {hi, lo};
    // A fresh load reads the divisor N (0xFFFF here) minus 2 per elapsed tick:
    // ABOVE N/2 and up to N. The old half-count model returned ~0x8000 and
    // fails both bounds.
    if (latched < 16'hFFF0) begin
      $display("FAIL latched 16-bit read gave %04x (want 0xFFF0..0xFFFF)", latched);
      errors = errors + 1;
    end
    // The latch is now consumed, so this pair is the live counter and must have
    // MOVED down (the old code returned the LSB twice for a frozen latch).
    ticks = 0;
    while (ticks < 2) begin
      @(posedge clk);
      if (dut.pit_tick) ticks = ticks + 1;
    end
    read_pit(2'd0, lo);
    read_pit(2'd0, hi);
    if ({hi, lo} >= latched || {hi, lo} < 16'hFFF0) begin
      $display("FAIL live 16-bit read gave %02x%02x after latched %04x", hi, lo, latched);
      errors = errors + 1;
    end

    // MSB-only access returns the high byte and consumes the latch. Mode 2 is
    // used here rather than mode 3 so both access widths cover both major
    // modes; a mode-2 counting element also spans the full 0..N read range.
    write_pit(2'd3, 8'h24);          // ch0, MSB only, mode 2 (rate generator)
    write_pit(2'd0, 8'hFF);
    write_pit(2'd0, 8'hFF);
    repeat (6) @(posedge clk);
    write_pit(2'd3, 8'h20);          // latch channel 0
    read_pit(2'd0, hi);
    if (hi < 8'hFD) begin
      $display("FAIL MSB-only read gave %02x", hi);
      errors = errors + 1;
    end

    // ------------------------------------------------------------------
    // F1 reach: a mode-3 latch+read must reach values ABOVE N/2 up to N.
    // Sampled every source tick over three full periods, the counting element
    // tops out at the divisor itself (N = 16 -> 16); the half-count model tops
    // out at N/2 (8) and fails.
    // ------------------------------------------------------------------
    write_pit(2'd3, 8'h36);          // ch0, LSB/MSB, mode 3
    write_pit(2'd0, 8'h10);          // divisor 16
    write_pit(2'd0, 8'h00);
    maxv = 16'h0000;
    for (k = 0; k < 24; k = k + 1) begin
      ticks = 0;
      while (ticks < 1) begin
        @(posedge clk);
        if (dut.pit_tick) ticks = ticks + 1;
      end
      write_pit(2'd3, 8'h00);        // latch channel 0
      read_pit(2'd0, lo);
      read_pit(2'd0, hi);
      if ({hi, lo} > maxv) maxv = {hi, lo};
    end
    if (maxv !== 16'h0010) begin
      $display("FAIL mode-3 read reach: max %04x want 0010 (N, not N/2)", maxv);
      errors = errors + 1;
    end

    // ------------------------------------------------------------------
    // F2: read-back STATUS bit 6 is the LIVE NULL COUNT flag. The 8254 sets it
    // on a control word and CLEARS it when the count load COMPLETES (NP2kai
    // pit_setflag/pit_setcount, io/pit.c:244-254,285-307): the first byte of
    // an LSB+MSB pair does not clear it (pit.c:292-296 returns early), the MSB
    // does. Hard-wiring it to 1 makes every load-completion poll spin forever.
    // ------------------------------------------------------------------
    write_pit(2'd3, 8'h36);          // control word: sets NULL COUNT
    write_pit(2'd3, 8'hC2);          // read-back status of CT0
    read_pit(2'd0, st);
    if (st[6] !== 1'b1) begin
      $display("FAIL status after control word bit6=%b want 1 (%02x)", st[6], st);
      errors = errors + 1;
    end
    write_pit(2'd0, 8'h34);          // first byte of the LSB+MSB pair only
    write_pit(2'd3, 8'hC2);
    read_pit(2'd0, st);
    if (st[6] !== 1'b1) begin
      $display("FAIL status after first count byte bit6=%b want 1 (%02x)", st[6], st);
      errors = errors + 1;
    end
    write_pit(2'd0, 8'h12);          // completing byte: clears NULL COUNT
    write_pit(2'd3, 8'hC2);
    read_pit(2'd0, st);
    if (st[6] !== 1'b0 || st[6:0] !== 7'h36) begin
      $display("FAIL status after count load bit6=%b want 0 (%02x)", st[6], st);
      errors = errors + 1;
    end

    // ------------------------------------------------------------------
    // F3: mode 0 keeps counting after terminal count. The real part wraps to
    // 0xFFFF and keeps decrementing with OUT latched high (QEMU
    // hw/timer/i8254-pc98.c:97: counter = (s->count - d) & 0xffff; NP2kai's
    // idle re-arm event io/pit.c:53 keeps the remain decreasing). The old model
    // froze at 0x0000 and every read answered 0, 0.
    // ------------------------------------------------------------------
    write_pit(2'd3, 8'h30);          // ch0, LSB/MSB, mode 0
    write_pit(2'd0, 8'h04);
    write_pit(2'd0, 8'h00);
    ticks = 0;
    while (!out0 && ticks <= 8) begin
      @(posedge clk);
      if (dut.pit_tick) ticks = ticks + 1;
    end
    ticks = 0;                       // two ticks past the terminal count
    while (ticks < 2) begin
      @(posedge clk);
      if (dut.pit_tick) ticks = ticks + 1;
    end
    write_pit(2'd3, 8'h00);          // latch channel 0
    read_pit(2'd0, lo);
    read_pit(2'd0, hi);
    v1 = {hi, lo};
    ticks = 0;
    while (ticks < 5) begin
      @(posedge clk);
      if (dut.pit_tick) ticks = ticks + 1;
    end
    write_pit(2'd3, 8'h00);
    read_pit(2'd0, lo);
    read_pit(2'd0, hi);
    v2 = {hi, lo};
    if (v1 <= 16'hFF00 || v2 <= 16'hFF00 || v2 >= v1) begin
      $display("FAIL mode-0 post-TC count %04x then %04x (want 0xFFFF wrapping down)", v1, v2);
      errors = errors + 1;
    end
  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_PIT: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PIT: FAIL (%0d errors)", errors);
  end

  // 60 ms: the zero-divisor check waits 65536 source ticks, which at the shipped
  // 50 MHz divider is ~27 ms of simulated time.
  initial begin
    #60_000_000;
    $fatal(1, "TB_PC9821_PIT: TIMEOUT");
  end

endmodule

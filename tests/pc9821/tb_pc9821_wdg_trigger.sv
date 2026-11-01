`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_WDG_TRIGGER: The stall watchdog's trigger decision distinguishes the three states it must report, and the one it exists for is reachable: a request held outstanding and never completed for the window reports 'W', no request at all reports 'S', and an unbroken stream of completions reports the 'P' heartbeat, so the wedge the old `!z_valid` condition could never fire on is now the case a test drives.
//
// WHY THIS EXISTS AND tb_pc9821_watchdog.sv DOES NOT COVER IT. That bench compares the
// formatter's 280 bytes against a golden capture: it tests the MESSAGE, never drives z_valid or
// z_ready, and so cannot see the trigger at all. The decision therefore had no test, and it was
// wrong in the one place that mattered - the stall arm required `!z_valid`, and a wedged CPU
// HOLDS z_valid high (it is a level, held until z_ready answers), so the arm was gated out
// exactly when it should have fired. Every capture from the real card read P, the heartbeat,
// and P was read as progress.
//
// The windows are parameters, so this bench shrinks 200 ms and 2 s to a few cycles. At the real
// SYS_FREQ reaching one trigger would take ten million cycles, which is not a bench.
//
// CHECK 1 IS THE REGRESSION. It is the case the old condition could not express, and a version
// of this module with `!z_valid` restored in the stall arm fails it - which is how the fix was
// shown to be a fix rather than a rewrite.

module tb_pc9821_wdg_trigger;

  // ==== DUT ====
  localparam [31:0] STALL  = 32'd8;
  localparam [31:0] PERIOD = 32'd32;

  reg        clk = 1'b0;
  reg        reset = 1'b1;
  reg        cpu_run = 1'b0;
  reg        hold = 1'b0;
  reg        z_valid = 1'b0;
  reg        z_ready = 1'b0;
  wire [7:0] path;
  wire       start;

  pc9821_wdg_trigger #(
      .WDG_STALL (STALL),
      .WDG_PERIOD(PERIOD)
  ) dut (
      .clk(clk), .reset(reset), .cpu_run(cpu_run),
      .hold(hold), .z_valid(z_valid), .z_ready(z_ready),
      .path(path), .start(start)
  );

  localparam [7:0] W = 8'h57;   // wedged: a request is outstanding and nothing completes
  localparam [7:0] S = 8'h53;   // idle: the CPU has stopped asking
  localparam [7:0] P = 8'h50;   // the heartbeat

  integer errors = 0;
  integer i;

  always #5 clk = ~clk;   // 10 ns period; every count in this bench is in cycles

  // 512 bits = 64 characters. 256 was not enough: a 33-character label does not fit and
  // Verilog's fixed-width conversion drops the leading character, so the message printed
  // "iggers before the window expired" and read like a typo rather than a truncation.
  task automatic check_int(input [511:0] what, input integer got, input integer want);
    begin
      if (got !== want) begin
        $display("  FAIL %s: got %0d, want %0d", what, got, want);
        errors = errors + 1;
      end else begin
        $display("  ok   %s = %0d", what, got);
      end
    end
  endtask

  task automatic check_byte(input [511:0] what, input [7:0] got, input [7:0] want);
    begin
      if (got !== want) begin
        $display("  FAIL %s: got %02x, want %02x", what, got, want);
        errors = errors + 1;
      end else begin
        $display("  ok   %s = %02x", what, got);
      end
    end
  endtask

  // Run the DUT until the trigger asserts, bounded so a trigger that never comes fails here
  // rather than hanging the runner. `start` is combinational and holds for exactly the cycle
  // whose condition is true, so it is sampled right after each edge; the extra edge lets the
  // registered path byte settle, and since the trigger resets the completion counter the
  // module cannot re-trigger on it.
  task automatic until_trigger(output [7:0] got_path, output integer cycles);
    integer guard;
    begin
      guard = 0;
      while (!start && guard < 500) begin
        @(posedge clk);
        guard = guard + 1;
      end
      @(posedge clk);
      got_path = path;
      cycles = guard;
      hold = 1'b1;          // the system would now be emitting the message
      @(posedge clk);
      hold = 1'b0;
    end
  endtask

  task automatic idle_reset();
    begin
      reset = 1'b1; cpu_run = 1'b0; hold = 1'b0; z_valid = 1'b0; z_ready = 1'b0;
      repeat (3) @(posedge clk);
      reset = 1'b0;
      @(posedge clk);
    end
  endtask

  // ==== CHECKS ====
  reg [7:0] got;
  integer   cyc;
  integer   early;

  initial begin
    idle_reset();

    // CHECK 1 - THE WEDGE, and the whole reason this bench exists. A request is asserted and
    // z_ready never comes: z_valid stays HIGH, which is the state the old `!z_valid` guard
    // excluded. The trigger must fire and must say W. Before the fix this bench could not be
    // written, because the condition it drives could not produce a trigger at all.
    $display("check 1: a request held outstanding and never completed reports the wedge");
    cpu_run = 1'b1;
    z_valid = 1'b1;
    z_ready = 1'b0;
    until_trigger(got, cyc);
    check_byte("wedged path byte W", got, W);
    check_int("the wedge fired at the window", cyc, STALL);
    idle_reset();

    // CHECK 2 - the window is real: nothing fires before it expires. A trigger that fired
    // immediately would satisfy check 1 while reporting a stall on a healthy machine.
    // The count is asserted to be ZERO, so this can fail; comparing a variable against itself
    // would be a check that cannot.
    $display("check 2: nothing fires before the window expires");
    cpu_run = 1'b1;
    z_valid = 1'b1;
    z_ready = 1'b0;
    early = 0;
    repeat (STALL - 1) begin
      @(posedge clk);
      if (start) early = early + 1;
    end
    check_int("triggers before the window expired", early, 0);
    idle_reset();

    // CHECK 3 - IDLE. No request at all for the window is the OTHER stall, and it is usually
    // healthy: a guest that is thinking looks like this. It must be reported as S, not W, or
    // the two states are not distinguished and the byte says nothing.
    $display("check 3: no request at all for the window reports idle");
    cpu_run = 1'b1;
    z_valid = 1'b0;
    until_trigger(got, cyc);
    check_byte("idle path byte S", got, S);
    idle_reset();

    // CHECK 4 - THE HEARTBEAT. Every request is accepted, so the completion counter never ages
    // out; the period still elapses and the message is still emitted, saying nothing about
    // progress. This is the reading that was mistaken for health.
    $display("check 4: an unbroken stream of completions reports the heartbeat");
    cpu_run = 1'b1;
    z_valid = 1'b1;
    z_ready = 1'b1;
    until_trigger(got, cyc);
    check_byte("heartbeat path byte P", got, P);
    check_int("the heartbeat fired at the period", cyc, PERIOD);
    idle_reset();

    // CHECK 5 - A STALL OUTRANKS THE HEARTBEAT. Both conditions must come true on the SAME
    // cycle, which needs setting up: both counters start together, so letting completions run
    // for (PERIOD - STALL) cycles first lines the two expiries up. The heartbeat fires on a
    // HEALTHY machine, so if it won here it would mask a wedge behind a normal reading - which
    // is exactly how the card's stall stayed hidden.
    $display("check 5: a stall coinciding with the heartbeat wins");
    cpu_run = 1'b1;
    z_valid = 1'b1;
    z_ready = 1'b1;                          // accepted, so the stall counter is held at 0
    repeat (PERIOD - STALL) @(posedge clk);  // the heartbeat clock runs up toward its window
    z_ready = 1'b0;                          // now the completion stops and both age together
    until_trigger(got, cyc);
    check_byte("coincident path byte W", got, W);
    // The timing matters too: the stall window is what expired, not the longer heartbeat. A
    // coincidence that reported W but fired a heartbeat late would pass the byte check while
    // still being slow to notice the machine had stopped.
    check_int("the coincidence fired at the stall window", cyc, STALL);
    idle_reset();

    // CHECK 6 - PROGRESS DEFEATS THE STALL. Requests are accepted every few cycles, always
    // inside the window, for several windows. No wedge is reported, because none occurred:
    // this is the counter resetting on COMPLETION and not on arrival, which is what makes
    // check 1 possible at all.
    $display("check 6: completions inside the window never report a wedge");
    cpu_run = 1'b1;
    for (i = 0; i < STALL * 4; i = i + 1) begin
      @(posedge clk);
      z_valid  = 1'b1;
      z_ready  = ((i % 2) == 0);      // accepted every other cycle, well inside the window
      if (start && path == W) begin
        $display("  FAIL a wedge was reported while requests were completing");
        errors = errors + 1;
      end
    end
    idle_reset();

    // CHECK 7 - NO GUEST, NO WATCHDOG. With cpu_run low the counters must not advance, or a
    // reset machine reports a stall on a CPU that is not running.
    $display("check 7: no trigger while the guest is not running");
    cpu_run = 1'b0;
    z_valid = 1'b1;
    z_ready = 1'b0;
    repeat (PERIOD * 2) begin
      @(posedge clk);
      if (start) begin
        $display("  FAIL the trigger fired with cpu_run low");
        errors = errors + 1;
      end
    end
    idle_reset();

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_WDG_TRIGGER: %0d check(s) failed", errors);
    $display("TB_PC9821_WDG_TRIGGER: PASS");
    $finish;
  end

  // A bench that stops making progress names itself instead of hanging the runner.
  initial begin
    #1_000_000;
    $fatal(1, "the watchdog trigger bench did not finish in 1 ms of simulated time");
  end

endmodule

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DBG_RECORD: The 351+256+100-byte debug report is emitted in order and survives an accept handshake that withholds a byte for as long as the FIFO behind it cannot take it: a byte presented while the FIFO is full is HELD - its strobe stays high and the same byte stays presented - and it is emitted exactly once when the handshake returns, so the whole 707-byte report arrives with no byte lost and none duplicated.
//
// WHY THIS EXISTS. The report is emitted at one byte per clk_sys into a 512-entry FIFO that drains
// at ~1 byte per 87 us, so the burst overran the FIFO, the overflow boundary landed inside the PRF
// record's last field, and the rest of the PRF plus the whole GFX record were dropped - the `AP=0`
// truncation a hardware capture showed. The fix is this module's handshake: no index
// advances until the byte presented has been ACCEPTED, and the strobe stays on a byte until its own
// accept - including the last byte of the report, which the pre-fix sequencing presented one cycle
// outside the record it belonged to. The failure mode is silent everywhere else in this tree,
// because nothing else instantiates the emitter.
//
// THE EXPECTED STREAM IS COMPUTED FROM THE STIMULUS, not from the RTL: the bench stands in for the
// three formatters, drives each char as a known function of the index the DUT reports, and
// recomputes the expected 707-byte sequence itself. A byte that arrives out of order, twice, or not
// at all therefore fails on a POSITION rather than on a plausible-looking value.
//
// CHECKS 2 AND 3 ARE THE REGRESSION. With the handshake ignored - the old emitter - the
// paced run captures a third of the report and the stalled run loses everything after the stall,
// which is what "the report's tail was dropped" means. Neither case is drivable with the sequencing
// inline in pc9821_system.sv, which is why it was moved into this module.

`default_nettype none

module tb_pc9821_dbg_record;

  // ==== DUT ====
  reg         clk_sys = 1'b0;
  reg         reset = 1'b1;
  wire        dbg_uart_accept;
  reg         wdg_start = 1'b0;
  reg  [7:0]  wdg_path = 8'h50;          // 'P', the heartbeat
  wire [7:0]  dbg_byte;
  wire        dbg_we;
  wire [15:0] wdg_idx;
  wire  [8:0] prf_idx;
  wire  [6:0] gfx_idx;
  wire        report_active;

  // The three formatters, as this bench stands in for them: a pure function of the index the DUT
  // reports, chosen so adjacent bytes differ and no byte of one record can be mistaken for a byte
  // of another. The DUT substitutes wdg_path at index 349, which the expected stream accounts for.
  wire [7:0] wdg_char = wdg_idx[7:0] ^ 8'hA5;
  wire [7:0] prf_char = prf_idx[7:0] ^ 8'h3C;
  wire [7:0] gfx_char = gfx_idx ^ 8'hC9;

  pc9821_dbg_record dut (
      .clk_sys(clk_sys), .reset(reset),
      .dbg_uart_accept(dbg_uart_accept),
      .wdg_start(wdg_start), .wdg_path(wdg_path), .wdg_char(wdg_char),
      .prf_char(prf_char), .gfx_char(gfx_char),
      .dbg_byte(dbg_byte), .dbg_we(dbg_we),
      .wdg_idx(wdg_idx), .prf_idx(prf_idx), .gfx_idx(gfx_idx),
      .report_active(report_active)
  );

  // ==== STIMULUS ====
  integer errors = 0;
  integer i;
  integer run_cycles = 0;   // cycles the last run took, so the pacing itself is checkable

  always #5 clk_sys = ~clk_sys;   // 10 ns period; every count in this bench is in cycles

  // The record's shape, restated here on purpose: the bench must not read out of the module under
  // test the lengths it is checking.
  localparam integer WDG_LEN = 351;   // indices 0..350, the trigger at 349, the LF at 350
  localparam integer PRF_LEN = 256;
  localparam integer GFX_LEN = 100;
  localparam integer TOTAL   = WDG_LEN + PRF_LEN + GFX_LEN;   // 707

  localparam [7:0] PATH_P = 8'h50;   // 'P'
  localparam [7:0] PATH_W = 8'h57;   // 'W'

  // The handshake the FIFO would present: `pace_en` off is a FULL FIFO (nothing is accepted),
  // `pace = 1` is room every cycle, `pace = 3` is one byte every three cycles - the shape a
  // 512-byte FIFO draining slowly presents to a 707-byte burst. It is a function of the cycle
  // counter rather than a value written from a stimulus process, so the capture below and the DUT
  // see the same decision for the same cycle and the two cannot race.
  integer cyc = 0;
  integer pace = 1;
  reg     pace_en = 1'b0;
  always @(posedge clk_sys) cyc = cyc + 1;

  assign dbg_uart_accept = pace_en && ((cyc % pace) == 0);

  // The expected byte at position k of one report.
  function [7:0] expected_at(input integer k);
    begin
      if (k == WDG_LEN - 2)           expected_at = PATH_P;      // the trigger substitution
      else if (k < WDG_LEN)           expected_at = (k & 8'hFF) ^ 8'hA5;
      else if (k < WDG_LEN + PRF_LEN) expected_at = ((k - WDG_LEN) & 8'hFF) ^ 8'h3C;
      else                            expected_at = ((k - WDG_LEN - PRF_LEN) & 8'hFF) ^ 8'hC9;
    end
  endfunction

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

  // The bytes the emitter presented AND the handshake took, in the order they were taken. Sampled in
  // the middle of the cycle, where the presented byte and the handshake are both stable, and this is
  // the top level's own rule: a byte enters the FIFO only if it was accepted.
  reg [7:0] cap [0:2047];
  integer   capn = 0;
  always @(negedge clk_sys) begin
    if (dbg_we && dbg_uart_accept) begin
      cap[capn] = dbg_byte;
      capn = capn + 1;
    end
  end

  task automatic idle_reset();
    begin
      reset = 1'b1; wdg_start = 1'b0; pace_en = 1'b0;
      repeat (3) @(posedge clk_sys);
      reset = 1'b0;
      capn = 0;
      @(negedge clk_sys);
    end
  endtask

  // A one-cycle trigger, driven between edges so the DUT samples it exactly once. On return the
  // report is in flight: the trigger was latched on the edge before the second assignment.
  task automatic pulse_start();
    begin
      @(negedge clk_sys);
      wdg_start = 1'b1;
      @(negedge clk_sys);
      wdg_start = 1'b0;
    end
  endtask

  // Wait for the report to leave flight. Bounded, so a handshake that never completes fails here
  // with a name instead of hanging the runner. A record ends only on its last byte's accept, so a
  // lost byte shows up as a short capture rather than as a wait that never returns.
  task automatic run_report(input integer bound);
    integer g;
    begin
      g = 0;
      while (report_active && (g < bound)) begin
        @(negedge clk_sys);
        g = g + 1;
      end
      if (report_active) $fatal(1, "the report was still in flight after %0d cycles", bound);
      run_cycles = g;
    end
  endtask

  // Compare the captured stream against the stream the stimulus says it must be, positionally.
  task automatic check_capture(input [511:0] what);
    integer k, bad_at;
    begin
      bad_at = -1;
      if (capn != TOTAL) begin
        $display("  FAIL %s: captured %0d bytes, want %0d", what, capn, TOTAL);
        errors = errors + 1;
      end else begin
        for (k = 0; k < TOTAL; k = k + 1)
          if ((cap[k] !== expected_at(k)) && (bad_at < 0)) bad_at = k;
        if (bad_at >= 0) begin
          $display("  FAIL %s: byte %0d is %02x, want %02x", what, bad_at, cap[bad_at],
                   expected_at(bad_at));
          errors = errors + 1;
        end else begin
          $display("  ok   %s: all %0d bytes present, in order, once each", what, TOTAL);
        end
      end
    end
  endtask

  // ==== CHECKS ====
  reg [7:0] held_byte;
  integer   held_count;
  integer   stall_we_high, stall_byte_stable, stall_count_stable;

  initial begin
    // CHECK 1 - AN IDLE EMITTER PRESENTS NOTHING, and one trigger emits all 707 bytes. A strobe that
    // floated high while no report was in flight would feed the FIFO bytes no report asked for. The
    // by-position comparison covers the shape, the trigger byte at 349 and the LF at 350; the three
    // index checks cover the record BOUNDARIES, which is what the record lengths are.
    $display("check 1: idle presents nothing; one trigger emits the whole 707-byte report");
    idle_reset();
    check_byte("idle strobe", {7'b0, dbg_we}, 8'h00);
    check_byte("idle report_active", {7'b0, report_active}, 8'h00);
    pace_en = 1'b1; pace = 1;
    pulse_start();
    run_report(2000);
    check_capture("free-running report");
    check_byte("strobe clear after the report", {7'b0, dbg_we}, 8'h00);
    check_int("watchdog index stopped at its record's last byte", wdg_idx, WDG_LEN - 1);
    check_int("PRF index stopped at its record's last byte", prf_idx, PRF_LEN - 1);
    check_int("GFX index stopped at its record's last byte", gfx_idx, GFX_LEN - 1);

    // CHECK 2 - THE REGRESSION: A PACED HANDSHAKE LOSES NOTHING. The FIFO takes one byte in three
    // cycles. Every byte must still arrive, once, in order; the two bounds below are what makes this
    // a pacing test rather than a free-running one, and an emitter that advanced its index without
    // the handshake would capture a third of the report.
    $display("check 2: a paced handshake (1 byte in 3) loses nothing");
    idle_reset();
    pace_en = 1'b1; pace = 3;
    pulse_start();
    run_report(4000);
    check_capture("paced report");
    check_int("the paced run really was paced (at least one cycle per byte)",
              (run_cycles >= TOTAL), 1);
    check_int("... and finished inside three cycles per byte", (run_cycles <= 3 * TOTAL + 8), 1);

    // CHECK 3 - THE WORST CASE: THE FIFO IS FULL MID-REPORT. The byte presented when the handshake
    // goes away must be HELD - strobe high, the same byte, nothing captured - for as long as the
    // FIFO is full, and emitted exactly once when room returns. This is the state the old
    // emitter stepped over, and the state the card's `AP=0` capture was taken in.
    $display("check 3: a full FIFO holds the byte and it is emitted exactly once on return");
    idle_reset();
    pace_en = 1'b1; pace = 1;
    pulse_start();
    i = 0;
    while ((capn < 300) && (i < 2000)) begin
      @(negedge clk_sys);
      i = i + 1;
    end
    check_int("the report reached 300 bytes before the stall", capn, 300);
    pace_en = 1'b0;   // the FIFO is full from here
    held_byte  = dbg_byte;
    held_count = capn;
    stall_we_high = 1; stall_byte_stable = 1; stall_count_stable = 1;
    repeat (500) begin
      @(negedge clk_sys);
      if (!dbg_we)                stall_we_high = 0;
      if (dbg_byte !== held_byte) stall_byte_stable = 0;
      if (capn !== held_count)    stall_count_stable = 0;
    end
    check_byte("the strobe stayed high through the stall", {7'b0, stall_we_high}, 8'h01);
    check_byte("the same byte stayed presented", {7'b0, stall_byte_stable}, 8'h01);
    check_byte("nothing was captured while unaccepted", {7'b0, stall_count_stable}, 8'h01);
    check_byte("the report was still in flight", {7'b0, report_active}, 8'h01);
    pace_en = 1'b1; pace = 1;
    run_report(4000);
    check_capture("the report after a 500-cycle stall");

    // CHECK 4 - THE TRIGGER SUBSTITUTION IS THE INPUT, NOT A CONSTANT, and a second report starts
    // from the record's first byte: a different path byte changes position 349 and NOTHING else, so
    // the byte the trigger latched is what is emitted there.
    $display("check 4: a second report re-emits the whole report with a different trigger byte");
    idle_reset();
    wdg_path = PATH_W;
    pace_en = 1'b1; pace = 1;
    pulse_start();
    run_report(2000);
    check_int("the whole report, with a different trigger", capn, TOTAL);
    check_byte("the trigger byte at 349", cap[WDG_LEN - 2], PATH_W);
    check_byte("the byte before it is unchanged", cap[WDG_LEN - 3], expected_at(WDG_LEN - 3));
    check_byte("the byte after it is unchanged", cap[WDG_LEN - 1], expected_at(WDG_LEN - 1));

    // CHECK 5 - A TRIGGER DURING A REPORT IS IGNORED. The trigger's own `hold` prevents this in the
    // real machine, but the emitter must not restart or duplicate a record if it sees one: a
    // `wdg_start` held for ten cycles inside a report must not add a byte to it.
    $display("check 5: a trigger inside a report adds nothing to it");
    idle_reset();
    wdg_path = PATH_P;
    pace_en = 1'b1; pace = 1;
    pulse_start();
    repeat (20) @(negedge clk_sys);
    wdg_start = 1'b1;
    repeat (10) @(negedge clk_sys);
    wdg_start = 1'b0;
    run_report(2000);
    check_int("bytes in the report with the extra trigger", capn, TOTAL);
    check_capture("the report with a trigger inside it");

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_DBG_RECORD: %0d check(s) failed", errors);
    $display("TB_PC9821_DBG_RECORD: PASS");
    $finish;
  end

  // A bench that stops making progress names itself instead of hanging the runner.
  initial begin
    #1_000_000;
    $fatal(1, "the debug report bench did not finish in 1 ms of simulated time");
  end

endmodule

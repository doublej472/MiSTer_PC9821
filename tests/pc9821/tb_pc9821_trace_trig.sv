`timescale 1ns/1ps

// tb_pc9821_trace_trig - the trace's second trigger fires on a burst's end and on a flip, each
// rate-limited by its own window.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_TRACE_TRIG: The instruction trace's second trigger (pc9821_trace_trig, a 20-clock window here) fires once QUIET clocks after the last GVRAM store of a burst (GRCG store pulses or plain-client ownership) and not again until another store; and it fires on a page flip (0xA4 display page or 0xA6 access page) while stores arrive EVERY clock - the drawing game the flip arm exists for - at most once per window and on every flip a whole window after the previous flip pulse, never on a flip inside the window after reset or after a pulse.
//
// ---- where each expectation comes from ----
// The trigger's contract as pc9821_system and pc9821_trace use it (the module header): a burst
// end is "a GVRAM store after >= 1 s with none" seen from its far side, and a flip may fire only
// when the window has elapsed since the last flip that fired. The bench keeps its own record of
// the stimulus (the last store, the last flip pulse) and judges every pulse against it. The one
// clock at exactly the window edge is allowed either way: the contract is a one-second window on
// hardware, where one clock is not a quantity anything depends on.

`default_nettype none

module tb_pc9821_trace_trig;
  localparam integer Q = 20;

  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg reset = 1'b1, grcg_store = 1'b0, pw_owned = 1'b0, display_page = 1'b0, access_page = 1'b0;
  wire trig;

  // ==== DUT ====
  pc9821_trace_trig #(.QUIET(32'(Q))) dut (
    .clk(clk), .reset(reset), .grcg_store(grcg_store), .pw_owned(pw_owned),
    .display_page(display_page), .access_page(access_page), .trig(trig));

  // ==== CHECKS ====
  // `t` counts clocks since reset fell. Every check below is against the stimulus record.
  integer errors = 0, t = 0;
  integer last_store = -1000000, last_flip_fire = 0, n_trig = 0, n_flip_fire = 0, n_flip_due = 0;
  reg     flip_now = 1'b0, store_now = 1'b0, expect_burst = 1'b0;
  reg     prev_disp = 1'b0, prev_acc = 1'b0;
  task automatic fail(input string m);
    begin if (errors < 20) $display("FAIL: %0s (clock %0d)", m, t); errors = errors + 1; end
  endtask

  // the inputs are driven at the falling edge; judge each rising edge's combinational `trig`
  always @(posedge clk) if (!reset) begin
    flip_now  = (display_page != prev_disp) || (access_page != prev_acc);
    store_now = grcg_store || pw_owned;
    prev_disp = display_page; prev_acc = access_page;
    if (trig) begin
      n_trig = n_trig + 1;
      if (flip_now) begin
        // a flip pulse: the window since the previous one (or reset) must have passed
        if (t - last_flip_fire < Q) fail($sformatf("a flip fired %0d clocks after the last flip pulse", t - last_flip_fire));
        last_flip_fire = t; n_flip_fire = n_flip_fire + 1;
      end else begin
        // a burst-end pulse: QUIET (or QUIET+1) clocks after the last store, and only once
        if (!expect_burst) fail("a pulse with no flip and no burst ending");
        else if (t - last_store < Q || t - last_store > Q + 1)
          fail($sformatf("the burst end fired %0d clocks after the last store, expected %0d", t - last_store, Q));
        expect_burst = 1'b0;
      end
    end else begin
      if (flip_now && t - last_flip_fire > Q) begin
        n_flip_due = n_flip_due + 1;
        fail($sformatf("a flip %0d clocks after the last flip pulse did not fire", t - last_flip_fire));
      end
      if (expect_burst && !store_now && t - last_store > Q + 1)
        begin fail("the burst end never fired"); expect_burst = 1'b0; end
    end
    if (store_now) begin last_store = t; expect_burst = 1'b1; end
    t = t + 1;
  end

  // ==== STIMULUS ====
  task automatic clocks(input integer n);
    begin repeat (n) @(negedge clk); end
  endtask
  integer k;
  initial begin
    clocks(3);
    reset = 1'b0;
    // 1. a flip inside the window after reset does not fire; one after it does
    clocks(5);  display_page = 1'b1; clocks(1);
    clocks(30); display_page = 1'b0; clocks(1);
    clocks(5);
    if (n_flip_fire != 1) fail($sformatf("%0d flip pulses after reset, expected 1", n_flip_fire));

    // 2. a burst of GRCG stores and plain ownership, then quiet: one burst-end pulse
    for (k = 0; k < 15; k = k + 1) begin
      @(negedge clk); grcg_store = (k % 3 == 0); pw_owned = (k % 3 == 1);
    end
    @(negedge clk); grcg_store = 1'b0; pw_owned = 1'b0;
    clocks(3 * Q);
    if (expect_burst) fail("the burst end did not fire");
    begin : once
      integer n0;
      n0 = n_trig;
      clocks(4 * Q);                                  // still quiet: nothing more
      if (n_trig != n0) fail("a quiet stretch fired again with no new store");
    end

    // 3. the drawing game: a store EVERY clock, a flip every 7 clocks, alternating pages
    begin : farland
      integer f0;
      f0 = n_flip_fire;
      pw_owned = 1'b1;
      for (k = 0; k < 40; k = k + 1) begin
        clocks(6);
        if (k % 2 != 0) display_page = ~display_page; else access_page = ~access_page;
        clocks(1);
      end
      // 280 clocks of flips 7 apart: one pulse at the first flip a window after each pulse,
      // so 280 / 21 = 13 or more (each one 21 apart: the first multiple of 7 past 20)
      if (n_flip_fire - f0 < 13) fail($sformatf("%0d flip pulses while drawing every clock, expected 13", n_flip_fire - f0));
      pw_owned = 1'b0;
    end
    clocks(3 * Q);

    // ==== VERDICT ====
    $display("TB_PC9821_TRACE_TRIG: %0d pulses, %0d on a flip", n_trig, n_flip_fire);
    if (errors != 0) $fatal(1, "TB_PC9821_TRACE_TRIG: FAIL (%0d errors)", errors);
    $display("TB_PC9821_TRACE_TRIG: PASS");
    $finish;
  end

  initial begin
    #200_000;
    $fatal(1, "TB_PC9821_TRACE_TRIG: timeout");
  end
endmodule

`default_nettype wire

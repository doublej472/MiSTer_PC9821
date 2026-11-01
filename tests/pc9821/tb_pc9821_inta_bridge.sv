`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// The five-state INTA bridge driven through the exact protocol of its own header comments - the first INTA answers with one dummy ready and din=0, the second pulses pic_interrupt_done for exactly one clk and the PIC's acknowledge-latched vector is read back a cycle later before ready drops and the FSM returns to idle - and the five corners that hide a protocol bug pinned: a strobe held high answers the first INTA once, an INTA with no pending request passes the PIC's spurious vector through unchanged, back-to-back interrupts re-arm because inta_responded clears between them, the vector handed over is the one on pic_interrupt_vector at the transfer (the acknowledge latch is the PIC's, not the bridge's - recorded rather than asserted), and reset_n in each of the five states returns to idle without a stray acknowledge.
//
// ---- where the sequence comes from ----
// [source 1: the module's own comments] src/pc9821/interrupts/pc9821_inta_bridge.sv's
// header and its per-state comments give the sequence: "z486.inta (1st cycle) to dummy
// response (ready + din=0)"; "S_INTA1: Wait for inta to deassert (BIU releases between
// cycles)"; "S_INTA2: Second INTA cycle: acknowledge the PIC ... the PIC latches the acked
// IRQ and its vector at the edge that ends this state"; "S_ACK: The acknowledge pulse is
// high this cycle. Wait one cycle so the PIC has latched int_vec/int_acked_irq off the same
// edge"; "S_XFER: return the vector the acked IRQ names".
//
// [source 2: the PIC benches] tb_pc9821_pic_ref.sv's `ack` task drives one acknowledge as
// `@(negedge clk); inta = 1; @(negedge clk); inta = 0;` - the single-cycle pulse the bridge
// produces on the second INTA - and tb_pc9821_interrupts.sv drives the same handshake
// through pc9821_interrupts. This bench instantiates the bridge ALONE, so its stimulus is
// the CPU-side bus cycle, not the PIC.

`default_nettype none

module tb_pc9821_inta_bridge;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg        pic_do  = 0;
  reg  [7:0] pic_vec = 0;
  reg        cpu_inta = 0;
  wire       pic_done;
  wire       cpu_intr;
  wire [31:0] cpu_din;
  wire       cpu_ready;

  integer errors = 0;
  integer cases  = 0;

  // Samples of the bridge's registered outputs on the edge they were emitted on.
  reg        rdy, ack;
  reg [31:0] din;
  reg        intr;

  // ==== DUT ====
  pc9821_inta_bridge dut (
      .clk(clk),
      .reset_n(rst_n),
      .pic_interrupt_do(pic_do),
      .pic_interrupt_vector(pic_vec),
      .pic_interrupt_done(pic_done),
      .cpu_intr(cpu_intr),
      .cpu_inta(cpu_inta),
      .cpu_inta_din(cpu_din),
      .cpu_inta_ready(cpu_ready)
  );

  // ==== STIMULUS ====

  // A named comparison, so a failure cites the case rather than a line number.
  task automatic check(input integer id, input [8*40-1:0] what,
                       input [31:0] got, input [31:0] want);
    begin
      cases = cases + 1;
      if (got !== want) begin
        $display("MISMATCH c%0d_%0s: got 0x%08x want 0x%08x", id, what, got, want);
        errors = errors + 1;
      end
      else $display("ok       c%0d_%0s = 0x%08x", id, what, got);
    end
  endtask

  // Present one clk of the CPU's INTA bus and return the bridge's registered outputs on
  // the edge that bus cycle is sampled at. cpu_inta is driven at the negedge, the FSM
  // samples it at the next posedge, and the outputs (all registered) are read just after
  // that posedge - the same drive/sample split tb_pc9821_kbd_codes uses.
  task automatic step(input bit inta);
    begin
      @(negedge clk);
      cpu_inta = inta;
      @(posedge clk);
      #1;
      rdy  = cpu_ready;
      ack  = pic_done;
      din  = cpu_din;
      intr = cpu_intr;
    end
  endtask

  // Return the bridge to idle and clear the stimulus.
  task automatic reset_dut;
    begin
      rst_n = 0; cpu_inta = 0; pic_do = 0; pic_vec = 0;
      repeat (3) @(negedge clk);
      rst_n = 1;
      repeat (2) @(negedge clk);
    end
  endtask

  // ==== CHECKS ====
  // The check-number prefixes in the output name the corner case, in the order this bench
  // covers them: c0 the plain handshake, c1 the strobe held high, c2 the inta_responded
  // guard across the handoff, c3 an INTA with no pending request, c4 back-to-back
  // interrupts, c5 the acknowledge-latched vector, c6-c10 reset_n in each of the five
  // states (idle, INTA1, INTA2, ACK, XFER).

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;

    // ---- 0. The documented handshake, end to end. ----
    // First INTA: dummy ready + din 0 (the "OPR_R on this cycle" the comment names).
    // Release; second INTA: the PIC acknowledge, one clk; then the vector, then idle.
    reset_dut();
    pic_do = 1'b1; pic_vec = 8'h41;
    step(1'b1);
    check(0, "intake1_ready",        {31'b0, rdy},  32'h1);
    check(0, "intake1_dummy_din",    din,           32'h0000_0000);
    check(0, "intake1_no_ack",       {31'b0, ack},  32'h0);
    check(0, "intake1_intr_level",   {31'b0, intr}, 32'h1);
    step(1'b0);
    check(0, "release_between_ready", {31'b0, rdy}, 32'h0);
    check(0, "release_between_ack",   {31'b0, ack}, 32'h0);
    step(1'b1);
    check(0, "intake2_ack_pulse",    {31'b0, ack},  32'h1);
    check(0, "intake2_not_ready",    {31'b0, rdy},  32'h0);
    pic_do = 1'b0;                    // the PIC drops INT on the acknowledge
    step(1'b0);
    check(0, "ack_is_one_cycle",     {31'b0, ack},  32'h0);
    check(0, "intr_drops_after_ack", {31'b0, intr}, 32'h0);
    step(1'b0);
    check(0, "xfer_ready",           {31'b0, rdy},  32'h1);
    check(0, "xfer_vector",          din,           32'h0000_0041);
    step(1'b0);
    check(0, "xfer_is_one_cycle",    {31'b0, rdy},  32'h0);

    // ---- 1. CPU holds the strobe high for more than one cycle. ----
    // The BIU can hold inta for more than one posedge; the FIRST INTA must be answered
    // once, not once per clk. A second ready pulse here is a double acknowledge.
    reset_dut();
    pic_do = 1'b1; pic_vec = 8'h10;
    step(1'b1);
    check(1, "first_intake_ready",   {31'b0, rdy},  32'h1);
    check(1, "first_intake_no_ack",  {31'b0, ack},  32'h0);
    step(1'b1);
    check(1, "hold_cycle2_quiet",    {31'b0, rdy},  32'h0);
    step(1'b1);
    check(1, "hold_cycle3_quiet",    {31'b0, rdy},  32'h0);
    check(1, "hold_cycle3_no_ack",   {31'b0, ack},  32'h0);
    step(1'b1);
    check(1, "hold_cycle4_quiet",    {31'b0, rdy},  32'h0);
    step(1'b0);
    check(1, "release_after_hold",   {31'b0, rdy},  32'h0);

    // ---- 1b. The inta_responded guard, exercised across the handoff. ----
    // Hold the strobe high from the second INTA through the vector handoff: once the
    // vector has been returned the held strobe must NOT start a second INTA. Without the
    // guard the FSM would re-enter S_INTA1 from idle on the still-high strobe.
    reset_dut();
    pic_do = 1'b1; pic_vec = 8'h42;
    step(1'b1);                       // S_IDLE -> S_INTA1
    step(1'b0);                       // S_INTA1 -> S_INTA2
    step(1'b1);                       // S_INTA2 -> S_ACK: the acknowledge pulse
    check(2, "ack_pulse",            {31'b0, ack},  32'h1);
    step(1'b1);                       // S_ACK -> S_XFER (strobe still high)
    check(2, "ack_one_cycle",        {31'b0, ack},  32'h0);
    step(1'b1);                       // S_XFER: vector returned
    check(2, "xfer_vector",          din,           32'h0000_0042);
    check(2, "xfer_ready",           {31'b0, rdy},  32'h1);
    step(1'b1);                       // S_IDLE, strobe still high
    check(2, "held_strobe_no_second_intake", {31'b0, rdy}, 32'h0);

    // ---- 2. An INTA with no pending request. ----
    // pc_interrupt_do is low, so cpu_intr stays low; the vector that reaches the CPU is the
    // PIC's spurious value (pc9821_pic.sv publishes icw2 | 7 when nothing is pending), and
    // the bridge must pass it through unchanged rather than substitute or drop it.
    reset_dut();
    pic_do = 1'b0; pic_vec = 8'h0F;   // ICW2 0x08 | 7, the machine's spurious vector
    step(1'b1);
    check(3, "no_request_intr_low",  {31'b0, intr}, 32'h0);
    check(3, "no_request_ready",     {31'b0, rdy},  32'h1);
    check(3, "no_request_dummy_din", din,           32'h0000_0000);
    step(1'b0);
    step(1'b1);
    check(3, "no_request_ack",       {31'b0, ack},  32'h1);
    step(1'b0);
    step(1'b0);
    check(3, "spurious_vector_passthrough", din,    32'h0000_000F);
    step(1'b0);

    // ---- 3. Back-to-back interrupts. ----
    // Two complete transactions in a row with different vectors: the second cannot start
    // unless inta_responded cleared in the release between them (it is cleared by both the
    // S_INTA1 arm and the trailing `if (!cpu_inta)`).
    reset_dut();
    pic_do = 1'b1; pic_vec = 8'h1A;
    step(1'b1);                                         // first INTA
    check(4, "first_intake_ready",   {31'b0, rdy},  32'h1);
    step(1'b0);
    step(1'b1);
    check(4, "first_ack",            {31'b0, ack},  32'h1);
    step(1'b0);
    step(1'b0);
    check(4, "first_vector",         din,           32'h0000_001A);
    step(1'b0);
    pic_vec = 8'h2B;                                    // the second request's vector
    step(1'b1);                                         // second INTA - must re-arm
    check(4, "second_intake_ready",  {31'b0, rdy},  32'h1);
    check(4, "second_intake_no_ack", {31'b0, ack},  32'h0);
    step(1'b0);
    step(1'b1);
    check(4, "second_ack",           {31'b0, ack},  32'h1);
    step(1'b0);
    step(1'b0);
    check(4, "second_vector",        din,           32'h0000_002B);
    step(1'b0);

    // ---- 4. The vector handed over is the PIC's acknowledge-latched value. ----
    // pc9821_pic.sv latches int_vec on the acknowledge edge (its `inta` arm) and holds it;
    // the bridge's transfer reads that one latched value back. The bench models the latch:
    // pic_interrupt_vector holds the acked value from before the first INTA through the
    // transfer, and the CPU must receive exactly it.
    reset_dut();
    pic_do = 1'b1; pic_vec = 8'h9C;
    step(1'b1);
    step(1'b0);
    step(1'b1);                       // the acknowledge edge: the PIC latches 0x9C here
    check(5, "ack_edge_pulse",       {31'b0, ack},  32'h1);
    step(1'b0);                       // S_ACK: the cycle the PIC latched
    step(1'b0);                       // S_XFER: the bridge reads the latched value back
    check(5, "acked_vector",         din,           32'h0000_009C);
    step(1'b0);
    // The boundary, RECORDED rather than asserted: the bridge is not itself a latch - it
    // reads pic_interrupt_vector at the transfer. A change AFTER the acknowledge pulse
    // therefore passes straight through, which is the documented division of labour (the
    // latch is the PIC's), not a bridge defect. The line prints what the bridge
    // would hand over so the seam is visible; it is deliberately not a pass/fail case,
    // because asserting pass-through would forbid a future bridge-side latch and asserting
    // the old value would fail against a contract the module does not own.
    reset_dut();
    pic_do = 1'b1; pic_vec = 8'h20;
    step(1'b1);
    step(1'b0);
    step(1'b1);                       // acknowledge edge
    pic_vec = 8'h7F;                  // changed after the pulse (out of the module's contract)
    step(1'b0);
    step(1'b0);
    $display("NOTE     c5_mid_handshake_change: pic_interrupt_vector changed after the ack; the bridge hands din=0x%02x (its transfer reads the input; the PIC owns the latch)", din[7:0]);
    step(1'b0);

    // ---- 5. reset_n in each of the five states. ----
    // Assert reset while the FSM is in each state: the outputs go idle on the next edge and
    // stay idle (no stray acknowledge, no ready), and the FSM restarts from idle - proven by
    // running a whole fresh transaction afterwards.
    // 5a: reset from S_IDLE.
    reset_dut();
    reset_in_state(6, 8'h11);
    // 5b: reset from S_INTA1.
    reset_dut();
    step(1'b1);
    check(7, "in_intake1_ready",     {31'b0, rdy},  32'h1);
    reset_in_state(7, 8'h22);
    // 5c: reset from S_INTA2.
    reset_dut();
    step(1'b1); step(1'b0);
    reset_in_state(8, 8'h33);
    // 5d: reset from S_ACK (the acknowledge pulse's own cycle).
    reset_dut();
    step(1'b1); step(1'b0); step(1'b1);
    check(9, "in_ack_ack_high",      {31'b0, ack},  32'h1);
    reset_in_state(9, 8'h44);
    // 5e: reset from S_XFER.
    reset_dut();
    step(1'b1); step(1'b0); step(1'b1); step(1'b0);
    reset_in_state(10, 8'h55);

    // ==== VERDICT ====
    $display("NOTE inta_bridge: %0d cases, %0d mismatched", cases, errors);
    if (errors == 0) begin
      $display("TB_PC9821_INTA_BRIDGE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_INTA_BRIDGE: FAIL (%0d of %0d cases)", errors, cases);
  end

  // Assert reset for two edges and require the outputs to be idle on both, then release and
  // run a fresh transaction to prove the FSM restarted from idle.
  task automatic reset_in_state(input integer id, input [7:0] vec);
    begin
      @(negedge clk); rst_n = 0; cpu_inta = 0;
      @(posedge clk); #1;
      check(id, "reset_ready_idle", {31'b0, cpu_ready}, 32'h0);
      check(id, "reset_ack_idle",   {31'b0, pic_done},  32'h0);
      @(posedge clk); #1;
      check(id, "reset_ready_stays_idle", {31'b0, cpu_ready}, 32'h0);
      check(id, "reset_ack_stays_idle",   {31'b0, pic_done},  32'h0);
      @(negedge clk); rst_n = 1;
      repeat (2) @(negedge clk);
      // Fresh transaction from idle: the FSM was reset, not merely quiet.
      pic_do = 1'b1; pic_vec = vec;
      step(1'b1);
      check(id, "fresh_intake_ready", {31'b0, rdy}, 32'h1);
      step(1'b0);
      step(1'b1);
      check(id, "fresh_ack",          {31'b0, ack}, 32'h1);
      step(1'b0);
      step(1'b0);
      check(id, "fresh_vector",       din,          {24'h0, vec});
      step(1'b0);
      pic_do = 1'b0;
    end
  endtask

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_INTA_BRIDGE: TIMEOUT");
  end

endmodule

`default_nettype wire

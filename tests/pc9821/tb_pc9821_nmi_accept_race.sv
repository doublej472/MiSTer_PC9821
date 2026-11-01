// tb_pc9821_nmi_accept_race - an NMI edge landing in the SAME clk_sys cycle as the
// NMI accept boundary must not be eaten.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// The z486 interrupt_controller's NMI latch folds its set and the boundary-accept clear into ONE next-state: an NMI edge landing in the accept cycle while the boundary consumes an OLDER pending NMI is deferred into the latch (set wins, never eaten), while an edge that IS the accepted request is consumed exactly once and not re-latched (a plain set-wins latch would deliver one edge twice through nmi_request_active's combinational path). FAIL-FIRST against the old clear-wins fold, which lost the colliding edge entirely.
//
// The z486 interrupt_controller's NMI latch folds its set and the boundary-accept
// clear into ONE next-state. Before the fix the set was guarded by
// `!nmi_accept_boundary` and the clear ran unconditionally, so an NMI EDGE in the
// accept cycle was neither latched nor re-queued whenever the boundary was
// consuming a DIFFERENT request (an older pending NMI): one NMI gone with no way
// for the edge source to re-request (the same S2 shape as the PIC's ir_set/ir_clr
// collision, race-idiom R3). After the fix the accept consumes EXACTLY ONE
// request - the pending latch if it has one (a same-cycle edge is then a NEW
// event and is deferred - set wins - never eaten), or the same-cycle edge itself
// when the latch is empty (the combinational nmi_request_active path has already
// delivered it to this very accept). S1 is the FAIL-FIRST case; S2 pins that the
// fix does not deliver one edge TWICE (a plain set-wins latch would re-latch the
// edge its own accept already delivered).
//
// THE SAME-CYCLE MEANS ONE POSEDGE: the task drives nmi and nmi_accept_boundary
// so both are stable across the SAME clk posedge the DUT samples.

module tb_pc9821_nmi_accept_race;

  logic clk = 0;
  always #5 clk = ~clk;
  logic reset_n = 0;

  logic intr = 0, nmi = 0, iflag = 0, i_rni = 0;
  logic shadow_start = 0, uc_exec = 0;
  logic [6:0] uc_aluop = 0;
  logic nmi_accept_boundary = 0;
  wire intr_pending, nmi_request_active, interrupt_pending, inhibit_interrupts;

  integer errors = 0;

  // ==== DUT ====
  interrupt_controller dut (
      .clk(clk),
      .reset_n(reset_n),
      .intr(intr),
      .nmi(nmi),
      .iflag(iflag),
      .i_rni(i_rni),
      .shadow_start(shadow_start),
      .uc_exec(uc_exec),
      .uc_aluop(uc_aluop),
      .nmi_accept_boundary(nmi_accept_boundary),
      .intr_pending(intr_pending),
      .nmi_request_active(nmi_request_active),
      .interrupt_pending(interrupt_pending),
      .inhibit_interrupts(inhibit_interrupts)
  );

  // ==== CHECKS ====
  task fail(input [8*160-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // A one-cycle NMI edge (rise then fall), with the rising edge in the cycle
  // that ends at the next posedge.
  task nmi_edge_pulse;
    begin
      @(negedge clk);
      nmi = 1;
      @(negedge clk);
      nmi = 0;
    end
  endtask

  // THE COLLISION: an NMI rising edge and the NMI accept boundary, both stable
  // across the same clk posedge.
  task nmi_edge_with_accept;
    begin
      @(negedge clk);
      nmi = 1;
      nmi_accept_boundary = 1;
      @(posedge clk);
      @(negedge clk);
      nmi = 0;
      nmi_accept_boundary = 0;
    end
  endtask

  task accept_only;
    begin
      @(negedge clk);
      nmi_accept_boundary = 1;
      @(posedge clk);
      @(negedge clk);
      nmi_accept_boundary = 0;
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset_n = 1;
    repeat (2) @(negedge clk);

    // ---------------------------------------------------------------
    // S1 (FAIL FIRST). A pending NMI is latched; a NEW NMI edge lands in the
    // exact clk the boundary accepts. The accept consumes the pending request;
    // the new edge is a second NMI and must be DEFERRED into the latch (set
    // wins over the clear), not eaten. Pre-fix the guard suppresses the set and
    // the clear empties the latch: one NMI lost.
    // ---------------------------------------------------------------
    nmi_edge_pulse;                              // latch NMI #1
    if (nmi_request_active !== 1'b1)
      fail("S1 setup: a plain NMI edge did not latch");
    nmi_edge_with_accept;                        // accept #1 + edge #2 in one clk
    @(negedge clk);
    if (nmi_request_active !== 1'b1)
      fail("S1: the NMI edge coincident with the accept was eaten (defer it, set-wins)");

    // Drain the deferred request so S2 starts from an empty latch.
    accept_only;
    @(negedge clk);
    if (nmi_request_active !== 1'b0)
      fail("S1 drain: the deferred NMI edge was not delivered by the next accept");

    // ---------------------------------------------------------------
    // S2. With an EMPTY latch, an NMI edge coincident with the accept IS the
    // request being accepted (the combinational nmi_request_active path delivers
    // it to this very accept): it must be CONSUMED, not re-latched, or one edge
    // delivers twice. This pins the exactly-once half of the discipline.
    // ---------------------------------------------------------------
    nmi_edge_with_accept;
    @(negedge clk);
    if (nmi_request_active !== 1'b0)
      fail("S2: the accepted NMI edge was re-latched (one edge would deliver twice)");

    // ---------------------------------------------------------------
    // S3. The plain paths: an edge alone latches and holds; an accept alone
    // consumes it.
    // ---------------------------------------------------------------
    nmi_edge_pulse;
    repeat (2) @(negedge clk);
    if (nmi_request_active !== 1'b1)
      fail("S3: the NMI request did not hold until accepted");
    accept_only;
    @(negedge clk);
    if (nmi_request_active !== 1'b0)
      fail("S3: a plain accept did not consume the pending NMI");

    // ==== VERDICT ====
    // A failing run must exit non-zero: $fatal, not $finish, which returns from
    // the process with status 0 and would make a failure look like no verdict.
    if (errors == 0) begin
      $display("TB_PC9821_NMI_ACCEPT_RACE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_NMI_ACCEPT_RACE: FAIL (%0d errors)", errors);
  end

endmodule

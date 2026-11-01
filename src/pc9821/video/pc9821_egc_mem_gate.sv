// PC-9821 EGC memory-dispatch gate, REGISTERED FROM BOTH SOURCES' NEXT STATE.
//
// The EGC's memory gate is `mode2_egc && grcg mode bit 7`: the EGC extended-mode latch (FF2 num 2,
// pc9821_crtc's mode2_egc) AND the GRCG's CG mode (0x7C bit 7, pc9821_grcg's mode[7]). Both terms
// are REGISTERS. A combinational AND (`gdc_egc_gate && mem_grcg_expand`) would put pc9821_crtc's
// mode2_egc at the head of a GVRAM-M10K endpoint cone - the only u_crtc-launched cone in the
// census (docs/timing.md).
//
// Registering it here is a TRUE PIPELINE RELOCATE, not a one-cycle lag: the flop is loaded with
// the AND of the two sources' NEXT states, so
//
//     gate(t) == (egc_gate(t) && grcg_expand(t))     for every cycle after reset,
//
// i.e. the value the consumer sees is BIT-IDENTICAL, cycle for cycle, to the
// combinational gate, while the flop breaks the cone (it can be placed at the far end, beside the
// GVRAM arbiter, because both inputs are next-state expressions that do not carry the arbiter's
// downstream logic). The next-state inputs are the sources' OWN next-state expressions
// (pc9821_crtc's gfx_egc_gate_nx and pc9821_grcg's expand_gate_nx), each reset-consistent with its
// source register, so the identity holds from the reset state onward - proven by induction in
// tools/check_gdc_egc_gate_inv.py over the REAL pc9821_crtc and pc9821_grcg.
//
// The `egc_gate`/`grcg_expand` inputs are the sources' CURRENT values. They feed only the
// simulation-only transparency assertion below (the R8 contract of this boundary): a plain lagged
// register, or a wrong next-state expression, fires it. tools/check_gdc_egc_gate_inv.py proves the
// same identity formally, so the shipped build (where the assertion is absent) rests on the proof.
`default_nettype none

module pc9821_egc_mem_gate (
    input wire clk,
    // The sources' own reset term (pc9821_system's `!rst_n_sys`, which is also
    // pc9821_memory_subsystem's `reset || !cpu_run`); the sources reset to 0 under it, so this
    // flop's clear keeps it aligned with them.
    input wire reset,

    input wire egc_gate,        // pc9821_crtc's mode2_egc (current)
    input wire egc_gate_nx,     // its next state (pc9821_crtc's gfx_egc_gate_nx)
    input wire grcg_expand,     // pc9821_grcg's mode[7] (current)
    input wire grcg_expand_nx,  // its next state (pc9821_grcg's expand_gate_nx)

    // The registered gate: == egc_gate & grcg_expand every cycle after reset.
    output wire gate
);

  reg gate_q;

  always @(posedge clk) begin
    if (reset) gate_q <= 1'b0;
    else       gate_q <= egc_gate_nx & grcg_expand_nx;
  end

  assign gate = gate_q;

`ifdef VERILATOR
  // R8: the relocate's contract. The registered gate is the combinational EGC x GRCG gate in
  // EVERY cycle (the next-state form). A plain lagged register (gate_q <= egc_gate & grcg_expand)
  // is one cycle behind on the cycle after a source moves; either defect fires this.
  always @* if (!reset && (gate != (egc_gate & grcg_expand)))
    $fatal(1, "pc9821_egc_mem_gate: the registered gate is not the combinational EGC x GRCG gate this cycle");
`endif

endmodule

`default_nettype wire

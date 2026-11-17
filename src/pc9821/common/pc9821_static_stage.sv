`default_nettype none

// pc9821_static_stage: a free-running register stage on an input that is static at its consumer,
// with the stability assertion that makes the stage legal.
//
// WHAT IT IS FOR. A timing cut of one shape recurs across the storage blocks: a value is consumed
// at a strobe (a command's execution, a probe's completion, a parse state), the logic that forms
// it is too deep for one clk_sys from its inputs, and those inputs are static for many cycles
// before the strobe (CDB bytes written in an earlier phase, a header captured sectors before the
// completion, a size latched at a mount). Registering the value DEPTH times without any enable then
// gives the same value at the strobe, provided the input has not changed in the DEPTH cycles before
// it. That proviso is the whole argument, and this module is where it is asserted, once.
//
// THE CONTRACT. q is d delayed DEPTH clk_sys cycles (DEPTH >= 1, no enable, no reset; every stage
// powers up 0, on an internal register). chk_en is the consumer's strobe: the cycle in which the
// instantiator reads q (or reads a later stage built from q) in place of the combinational value.
// In simulation, every cycle chk_en is high, d must equal its value in each of the DEPTH cycles
// before - so q, which is d from DEPTH cycles ago, is d now. This is a check of the PREMISE (the
// input held still), not of the result: it fails on a change that happened to leave the staged and
// combinational values equal, and it fails even when no bench looks at the consumer's output.
//
// A CHAIN of stages with logic between them (stage k's d a function of stage k-1's q) is one
// instance per stage, each with the SAME chk_en: if every stage's d held for its own DEPTH cycles
// at the strobe, the last stage's q is the whole chain's function of the inputs now (by induction
// from the last stage back: stage k's q equals its d now, which is its function of stage k-1's q
// now). A value with several consumers ORs their strobes into chk_en.
//
// chk_en and the check are simulation-only: chk_en has no effect on q, and synthesis sees the
// stage registers alone, the same flops a hand-written `always @(posedge clk) q <= d;` builds.
// tools/check_static_stage.py requires the storage blocks' free-running stages to be instances of
// this module, each with a real strobe.
module pc9821_static_stage #(
    parameter integer W     = 1,
    parameter integer DEPTH = 1
) (
    input  wire         clk,
    input  wire [W-1:0] d,
    output wire [W-1:0] q,
    /* verilator lint_off UNUSEDSIGNAL */   // read only by the simulation-only check below
    input  wire         chk_en
    /* verilator lint_on UNUSEDSIGNAL */
);

  wire [W-1:0] tap [0:DEPTH];
  assign tap[0] = d;
  genvar k;
  generate
    for (k = 0; k < DEPTH; k = k + 1) begin : g_stage
      reg [W-1:0] r;
      initial r = {W{1'b0}};
      always @(posedge clk) r <= tap[k];
      assign tap[k + 1] = r;
    end
  endgenerate
  assign q = tap[DEPTH];

  // synthesis translate_off
  // The premise, asserted at every strobe: d unchanged over the last DEPTH cycles. hist[i] is d
  // from i + 1 cycles ago; `seen` counts the cycles of history kept (a strobe before DEPTH cycles
  // have passed has no history to stand on and fails too: q is still its power-up value).
  reg [W-1:0] hist [0:DEPTH-1];
  integer     seen;
  initial seen = 0;
  integer     i;
  always @(posedge clk) begin
    if (chk_en) begin
      if (seen < DEPTH)
        $fatal(1, "pc9821_static_stage %m: consumed %0d cycle(s) after power-up, before its %0d-cycle settle",
               seen, DEPTH);
      for (i = 0; i < DEPTH; i = i + 1)
        if (hist[i] != d)
          $fatal(1, "pc9821_static_stage %m: consumed with d %0h, which was %0h %0d cycle(s) earlier (DEPTH %0d): the input was not static",
                 d, hist[i], i + 1, DEPTH);
    end
    for (i = DEPTH - 1; i > 0; i = i - 1) hist[i] <= hist[i - 1];
    hist[0] <= d;
    if (seen < DEPTH) seen <= seen + 1;
  end
  // synthesis translate_on

endmodule

`default_nettype wire

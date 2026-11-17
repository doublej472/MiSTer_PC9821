// THE REGISTERED RESET TREE: N copies of the platform reset, one per block, all loaded from the
// same source on the same clk_sys edge.
//
// WHY. The platform reset (z486_mister.sv's reset_sync_r[2]) is a SYNCHRONOUS reset, and as one
// register it drove about 9,700 endpoints across the device. Timed (the SDC no longer cuts it),
// about 1,380 of them failed setup by up to 4.5 ns at 90 MHz on the h5b-5900c2a2 fits, so the
// blocks behind those endpoints could leave reset a cycle after the rest of the machine - and a
// block whose own registers leave reset on different cycles can start in a state its RTL never
// reaches. Each copy here sits beside its block, so each block's release is a short local net
// that the fitter can meet in one cycle.
//
// THE CONTRACT. Every copy is `$past(reset)`: q[k] in cycle t+1 is `reset` in cycle t, for every
// k, from power-up on. So the whole machine still leaves reset on ONE edge, one clk_sys later
// than the source does; nothing else about the release changes. A consumer that ORs a level
// into its copy (the `|| !cpu_run` most blocks carry) does it AFTER the register, so that level
// keeps the timing it always had. tb_pc9821_reset_tree holds the copies of a whole
// pc9821_system to this.
//
// Every tree instance must be fed from an UNREGISTERED reset (the source itself, or the same
// source passed down a port): a copy of a copy would release a cycle after the rest.
//
// THE POWER-UP VALUE IS RESET (all ones), on this internal register (docs/policies.md: Quartus
// keeps an internal register's initializer and ignores an output port's). The source powers up
// in reset too (reset_sync_r = 3'b111), so the copies agree with $past(reset) from the first
// cycle.
//
// KEEPING THE COPIES. All N registers have the same D input, so synthesis would merge them back
// into one register and recreate the single big net. `preserve` keeps each register and
// DONT_MERGE_REGISTER forbids the duplicate-register merge; the fitted netlist is checked for N
// distinct `q[k]` registers per instance (the map report's register list).
`default_nettype none

module pc9821_reset_tree #(
    parameter int N = 1
) (
    input  wire         clk,
    input  wire         reset,   // the unregistered platform reset (see the contract above)
    output wire [N-1:0] q        // q[k] == $past(reset)
);

/* verilator lint_off PROCASSINIT */   // the power-up value, kept by Quartus on an internal register
(* preserve, altera_attribute = "-name DONT_MERGE_REGISTER ON" *) reg [N-1:0] q_r = {N{1'b1}};
/* verilator lint_on PROCASSINIT */
always @(posedge clk) q_r <= {N{reset}};
assign q = q_r;

endmodule

`default_nettype wire

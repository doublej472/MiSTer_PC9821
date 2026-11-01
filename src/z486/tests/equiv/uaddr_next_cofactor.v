// check-equiv: functions ../../microsequencer.sv uaddr_next_hi uaddr_next_pick
// microsequencer.sv uaddr_next: the cofactored form (the shipped uaddr_next_hi and
// uaddr_next_pick functions over the three arms, restated from the RTL wires
// uaddr_arm_hold/_step/_pb) against the priority chain it replaced (kept there as
// uaddr_next_reference): hold < seq_advance < exec redirect < pb_slot < fault <
// boundary < reset.  Every input bit is free.  MUTANT=1 gives the reference the
// port-B continuation priority over a fault, which the proof must tell apart.
module uaddr_next_cofactor #(parameter MUTANT = 0)
  (input rst_n, input seq_advance, input pb_slot, input ex_v, input [11:0] ex_t,
   input flt_v, input [11:0] flt_t, input bnd_v, input [11:0] bnd_t,
   input [11:0] uaddr, input [11:0] pb_entry_r, output mismatch);
// @@FUNCTIONS@@
  reg [11:0] ref_v;
  always @* begin
    ref_v = uaddr;
    if (seq_advance) ref_v = uaddr + 12'd1;
    if (ex_v) ref_v = ex_t;
    if (!MUTANT && pb_slot) ref_v = pb_entry_r + 12'd1;
    if (flt_v) ref_v = flt_t;
    if (MUTANT && pb_slot) ref_v = pb_entry_r + 12'd1;
    if (bnd_v) ref_v = bnd_t;
    if (!rst_n) ref_v = 12'h000;
  end
  wire        hi_v = !rst_n || bnd_v || flt_v;
  wire [11:0] hi   = uaddr_next_hi(rst_n, bnd_v, bnd_t, flt_t);
  wire [11:0] arm_hold = hi_v ? hi : ex_v ? ex_t : uaddr;
  wire [11:0] arm_step = hi_v ? hi : ex_v ? ex_t : uaddr + 12'd1;
  wire [11:0] arm_pb   = hi_v ? hi : pb_entry_r + 12'd1;
  wire [11:0] new_v = uaddr_next_pick(pb_slot, seq_advance, arm_pb, arm_step, arm_hold);
  assign mismatch = ref_v != new_v;
endmodule

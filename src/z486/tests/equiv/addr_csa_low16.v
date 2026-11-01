// check-equiv: functions ../../address_unit.sv relocate_csa32
// address_unit.sv effective_linear: the low half always from the folded
// 32-bit sum, the high half from the 16- or 32-bit arm, against the form it
// replaced, (sel16 ? linear16 : linear32) with linear16 =
// {16'd0, (a + b)[15:0]} + s and linear32 = (a + b) + s. Every operand and
// the arm select are free. MUTANT=1 takes the low half from the 16-bit EA
// without the base and must be refuted.
module addr_csa_low16 #(parameter MUTANT = 0)
  (input [31:0] a, input [31:0] b, input [31:0] s, input sel16,
   output mismatch);
// @@FUNCTIONS@@
  wire [31:0] off = a + b;
  wire [31:0] l16 = {16'd0, off[15:0]} + s;
  wire [31:0] l32 = off + s;
  wire [31:0] old_lin = sel16 ? l16 : l32;
  wire [31:0] csa = relocate_csa32(a, b, s);
  wire [15:0] lo = MUTANT ? off[15:0] : csa[15:0];
  wire [31:0] new_lin = {sel16 ? l16[31:16] : csa[31:16], lo};
  assign mismatch = old_lin != new_lin;
endmodule

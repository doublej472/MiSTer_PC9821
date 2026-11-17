// check-equiv: modules ../../alu.sv alu
// check-equiv: modules ../../alu_alt.sv alu_alt
// check-equiv: package ../../z486_pkg.sv
// alu.sv (the slice/carry-chain ALU every Verilator test and the Dhrystone
// bench build) against alu_alt.sv (the behavioural-adder ALU that data_unit.sv
// selects under Z486_USE_ALTERA_ALU, i.e. every Quartus build): result,
// flags_out and zsp_update are bit-identical for every op, op_size (3
// included), src, dst, flags and update_carry, so a pass of the suite on one
// stands for the other.  The undefined flags are compared too (AAA/AAS OF, the
// DAA/DAS ZF width), nothing is masked.  MUTANT=1 inverts alu_alt's AAA OF and
// must be refuted.
module alu_alt_equiv #(parameter MUTANT = 0)
  (input [4:0] op, input [31:0] src, input [31:0] dst, input [1:0] op_size,
   input [31:0] flags, input update_carry, output mismatch);
  wire [31:0] ra, rb, fa, fb;
  wire za, zb;
  alu     a (.op(op), .src(src), .dst(dst), .op_size(op_size), .flags(flags),
             .update_carry(update_carry), .result(ra), .flags_out(fa), .zsp_update(za));
  alu_alt b (.op(op), .src(src), .dst(dst), .op_size(op_size), .flags(flags),
             .update_carry(update_carry), .result(rb), .flags_out(fb), .zsp_update(zb));
  wire [31:0] fb_m = fb ^ ((MUTANT != 0 && op == 5'b11111) ? 32'h0000_0800 : 32'd0);  // ALU_AAA
  assign mismatch = (ra != rb) || (fa != fb_m) || (za != zb);
endmodule

// check-equiv: functions ../../data_unit.sv read_gpr_load_forwarded_late read_gpr_fmt read_gpr_fmt_op
// check-equiv: functions ../../shifter.sv shift_operand_at_size
// shifter.sv operands (the shipped read and pick functions, pasted) against the
// former gpr_dst_shift_size / gpr_src_shift_size = read_gpr_load_forwarded_late(
// reg, data_size), data_size = use_captured ? shift1_size : op_size:
//   source class 2 (DSTREG; selected only when !use_captured): fmt_op(dst)
//   alu_value DSTREG/SRCREG: shift_operand_at_size(use_captured,
//                             fmt(reg, shift1_size), fmt_op(reg))
// where fmt/fmt_op are data_unit's read_gpr_fmt/_op over the selected EX
// reads gpr_merge ex_* = view[reg] and view[{0, reg[1:0]}] (fused in RTL),
// with op_size_is0/is1 = (op_size == 0/1) (the registered decode's fused
// premise, data_unit.sv).  The 8 x 32 view, both register selects, both sizes
// and use_captured are free.  MUTANT=1 inverts use_captured in the new pick.
module shift_operand_size_split #(parameter MUTANT = 0)
  (input [255:0] view, input [2:0] dst, input [2:0] src, input [1:0] op_size,
   input [1:0] s1, input uc, output mismatch);
  wire [31:0] gpr_ex_view [0:7];
  genvar gi; generate for (gi = 0; gi < 8; gi = gi + 1) begin : g
    assign gpr_ex_view[gi] = view[gi*32 +: 32];
  end endgenerate
  wire op_size_is0 = (op_size == 2'd0);
  wire op_size_is1 = (op_size == 2'd1);
// @@FUNCTIONS@@
  wire [1:0]  data_size = uc ? s1 : op_size;
  wire [31:0] dst_old = read_gpr_load_forwarded_late(dst, data_size);
  wire [31:0] src_old = read_gpr_load_forwarded_late(src, data_size);
  wire [31:0] dfull = gpr_ex_view[dst], dbyte = gpr_ex_view[{1'b0, dst[1:0]}];
  wire [31:0] sfull = gpr_ex_view[src], sbyte = gpr_ex_view[{1'b0, src[1:0]}];
  wire [31:0] cls2_new = read_gpr_fmt_op(dfull, dbyte, dst[2]);
  wire        ucp = uc ^ (MUTANT != 0);
  wire [31:0] dst_new = shift_operand_at_size(ucp, read_gpr_fmt(dfull, dbyte, dst[2], s1),
                                              read_gpr_fmt_op(dfull, dbyte, dst[2]));
  wire [31:0] src_new = shift_operand_at_size(ucp, read_gpr_fmt(sfull, sbyte, src[2], s1),
                                              read_gpr_fmt_op(sfull, sbyte, src[2]));
  // every other dynamic read (ALU DSTREG/SRCREG, the factored sources) at any size
  wire [31:0] any_old = read_gpr_load_forwarded_late(dst, s1);
  wire [31:0] any_new = read_gpr_fmt(dfull, dbyte, dst[2], s1);
  assign mismatch = (!uc && (cls2_new != dst_old)) || (dst_new != dst_old) || (src_new != src_old) ||
                    (any_old != any_new);
endmodule

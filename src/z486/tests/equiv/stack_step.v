// data_unit.sv sigma <= ESP +/- operand size on a stack-op issue; address_unit.sv
// issue_stack_offset.
// old: sigma = stack32 ? (dir ? esp + d : esp - d)
//                      : {esp[31:16], dir ? esp[15:0] + d[15:0] : esp[15:0] - d[15:0]};
//      issue offset: dir ? (ss32 ? esp : {16'd0, esp[15:0]})
//                        : (ss32 ? esp - d : {16'd0, esp[15:0] - d[15:0]}).
// new: sigma = stack32 ? sum : {esp[31:16], sum[15:0]} with sum = esp + step, step = +/-2 or +/-4
//      as one signed constant; the issue offset takes the low half of one 32-bit subtract.
// ESP, the direction, the operand size and both stack widths are free. MUTANT=1 negates the
// wrong size in the subtract step (-2 for a dword) and must be refuted.
module stack_step #(parameter MUTANT = 0)
  (input [31:0] esp, input dir, input data32, input stack32, input ss32, output mismatch);
  wire [31:0] d = data32 ? 32'd4 : 32'd2;
  wire [31:0] sigma_old = stack32 ? (dir ? esp + d : esp - d)
                                  : {esp[31:16], dir ? esp[15:0] + d[15:0] : esp[15:0] - d[15:0]};
  wire [31:0] step = dir ? {29'd0, data32, ~data32, 1'b0}
                         : {29'h1FFF_FFFF, (data32 ^ MUTANT) ? 2'b10 : 2'b11, 1'b0};
  wire [31:0] sum = esp + step;
  wire [31:0] sigma_new = stack32 ? sum : {esp[31:16], sum[15:0]};
  wire [31:0] off_old = dir ? (ss32 ? esp : {16'd0, esp[15:0]})
                            : (ss32 ? esp - d : {16'd0, esp[15:0] - d[15:0]});
  wire [31:0] dec = esp - d;
  wire [31:0] off_new = dir ? (ss32 ? esp : {16'd0, esp[15:0]})
                            : (ss32 ? dec : {16'd0, dec[15:0]});
  assign mismatch = (sigma_old != sigma_new) || (off_old != off_new);
endmodule

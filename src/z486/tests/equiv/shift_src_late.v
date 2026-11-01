// data_unit.sv: read_gpr_load_forwarded's former body (size indexes the 8:1 view) against
// read_gpr_load_forwarded_late (both views indexed by reg_sel, size last), which
// is now the body of every read_gpr_load_forwarded call.
// MUTANT=1 indexes the byte view by the full reg_sel and must be refuted.
module shift_src_late #(parameter MUTANT = 0)
  (input [255:0] view, input [2:0] reg_sel, input [1:0] size, output mismatch);
  wire [31:0] v [0:7];
  genvar i; generate for (i = 0; i < 8; i = i + 1) begin : g
    assign v[i] = view[i*32 +: 32];
  end endgenerate
  // old
  wire [31:0] merged = v[(size == 2'd0) ? {1'b0, reg_sel[1:0]} : reg_sel];
  wire [31:0] old_r = (size == 2'd0) ? (reg_sel[2] ? {24'd0, merged[15:8]} : {24'd0, merged[7:0]}) :
                      (size == 2'd1) ? {16'd0, merged[15:0]} : merged;
  // new
  wire [31:0] bsrc = v[MUTANT ? reg_sel : {1'b0, reg_sel[1:0]}];
  wire [31:0] fsrc = v[reg_sel];
  wire [7:0]  bval = reg_sel[2] ? bsrc[15:8] : bsrc[7:0];
  wire [31:0] new_r = (size == 2'd0) ? {24'd0, bval} : (size == 2'd1) ? {16'd0, fsrc[15:0]} : fsrc;
  assign mismatch = old_r != new_r;
endmodule

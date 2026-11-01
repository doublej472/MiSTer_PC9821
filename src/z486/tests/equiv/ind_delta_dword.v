// check-equiv: tempinduct
// check-equiv: functions ../../address_unit.sv is_dword_stride
// address_unit.sv ind_delta_dword against z486.sv's former
// ind_delta_dword = (IND_DELTA == 4) || (IND_DELTA == -4), over ind_delta as
// address_unit writes it: reset 4; at instr_issue 2, or +-4 / +-2 for a stack
// operation by data32 and stack_dir; under exec the INDOP_PLUS_ALU operand
// (operand2) or the INDOP_PLUS ALU value, each when alu_source is not ZERO.
// Every condition and value is free each cycle (issue has priority, as the
// RTL's if/else). Sequential: proved by induction from the reset state.
// MUTANT=1 sets the flag for a 16-bit stack stride and must be refuted.
module ind_delta_dword #(parameter MUTANT = 0)
  (input clk, input rst, input issue, input stack_op, input stack_dir, input data32,
   input w_alu2, input [31:0] operand2, input w_plus, input [31:0] alu_value,
   output mismatch);
// @@FUNCTIONS@@
  reg [31:0] ind_delta = 32'd4; reg dword_r = 1'b1;
  always @(posedge clk) begin
    if (rst) begin
      ind_delta <= 32'd4; dword_r <= 1'b1;
    end else if (issue) begin
      ind_delta <= !stack_op ? 32'd2 :
                   !stack_dir ? (data32 ? -32'd4 : -32'd2) : (data32 ? 32'd4 : 32'd2);
      dword_r <= stack_op && (data32 || MUTANT);
    end else if (w_alu2) begin
      ind_delta <= operand2; dword_r <= is_dword_stride(operand2);
    end else if (w_plus) begin
      ind_delta <= alu_value; dword_r <= is_dword_stride(alu_value);
    end
  end
  assign mismatch = dword_r != ((ind_delta == 32'd4) || (ind_delta == -32'd4));
endmodule

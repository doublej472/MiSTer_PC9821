// check-equiv: tempinduct
// check-equiv: functions ../../z486.sv size_is01
// z486.sv op_size_du_is0/is1 (loaded through the shipped size_is01, pasted)
// against (op_size_du == 0) / (op_size_du == 1), over op_size_du as z486.sv's
// operand-size always_ff writes it: reset 1; at i_issue && !halted the D1
// operand size; else under uc_exec ALUJMP_BITS8/16/32 (0/1/2) or BITSDE
// (op_size_src_decode). Every condition and value is free each cycle.
// Sequential: proved by induction from the reset state.
// MUTANT=1 loads the decode at BITS32 as if the size were 1, which must be refuted.
module op_size_dec_reg #(parameter MUTANT = 0)
  (input clk, input rst, input issue, input halted, input uc_exec, input [6:0] uc_aluop,
   input [1:0] operand_size, input [1:0] op_size_src_decode, output mismatch);
// @@FUNCTIONS@@
  reg [1:0] du = 2'd1; reg is0 = 1'b0, is1 = 1'b1;
  always @(posedge clk) begin
    if (rst) begin
      du <= 2'd1; {is1, is0} <= size_is01(2'd1);
    end else if (issue && !halted) begin
      du <= operand_size; {is1, is0} <= size_is01(operand_size);
    end else if (uc_exec) begin
      case (uc_aluop)
        7'h24: begin du <= 2'd0; {is1, is0} <= size_is01(2'd0); end
        7'h25: begin du <= 2'd1; {is1, is0} <= size_is01(2'd1); end
        7'h27: begin du <= 2'd2; {is1, is0} <= size_is01(MUTANT ? 2'd1 : 2'd2); end
        7'h2A: begin du <= op_size_src_decode; {is1, is0} <= size_is01(op_size_src_decode); end
        default: ;
      endcase
    end
  end
  assign mismatch = (is0 != (du == 2'd0)) || (is1 != (du == 2'd1));
endmodule

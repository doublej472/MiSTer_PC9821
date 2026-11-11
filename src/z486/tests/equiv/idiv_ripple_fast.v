// check-equiv: functions ../../mul_div.sv div_sign_bit div_op_by_size div_abs_by_size div_ripple_bit_by_size idiv_ripple_by_size prediv_ripple_overflow_by_size
// mul_div.sv idiv_ripple and the PREDIV overflow term of a candidate:
// idiv_ripple_by_size / prediv_ripple_overflow_by_size (which read the masked
// sigma/divtmp registers, no 64-bit negator) against the full64 form they
// stand for: with U:V = |{H, L}| at the operand size n (the shipped full64),
// d = |divisor| and d_neg its sign,
//   candidate = (H negative ^ d_neg) && U:V[2n-1:2n-2] == 01b && d != 2^(n-1)
//               && !(H negative && U:V[2n-3:0] == d << (n-1))
//   overflow  = d == 0 || (U with bit n-2 cleared) >= d   (for a candidate)
// The divisor is a free tmpb through div_abs_by_size / div_sign_bit, as
// divisor_abs_r and div_divisor_neg hold it; sigma, divtmp and size are free.
// MUTANT=1 drops the negative-dividend exclusion from the candidate and must
// be refuted.
module idiv_ripple_fast #(parameter MUTANT = 0)
  (input [31:0] sigma, input [31:0] divtmp, input [1:0] op_size, input [31:0] tmpb,
   output mismatch);
  localparam logic DIV_OP_MASK   = 1'b0;
  localparam logic DIV_OP_NEGATE = 1'b1;
// @@FUNCTIONS@@
  wire [31:0] d = div_abs_by_size(tmpb, op_size);
  wire d_neg = div_sign_bit(tmpb, op_size);
  wire neg = div_sign_bit(sigma, op_size);
  reg [63:0] full64; reg [31:0] u; reg [63:0] rest; reg [63:0] dshift;
  reg top01; reg [31:0] smax; reg [31:0] ured;
  always @* begin
    full64 = (op_size == 2'd0) ? {48'h0, sigma[7:0], divtmp[7:0]} :
             (op_size == 2'd1) ? {32'h0, sigma[15:0], divtmp[15:0]} :
                                 {sigma, divtmp};
    if (neg) full64 = ~full64 + 64'h1;
    case (op_size)
      2'd0: begin u = {24'h0, full64[15:8]}; top01 = full64[15:14] == 2'b01;
                  rest = {50'h0, full64[13:0]}; dshift = {32'h0, d} << 7;
                  smax = 32'h80; end
      2'd1: begin u = {16'h0, full64[31:16]}; top01 = full64[31:30] == 2'b01;
                  rest = {34'h0, full64[29:0]}; dshift = {32'h0, d} << 15;
                  smax = 32'h8000; end
      default: begin u = full64[63:32]; top01 = full64[63:62] == 2'b01;
                  rest = {2'h0, full64[61:0]}; dshift = {32'h0, d} << 31;
                  smax = 32'h8000_0000; end
    endcase
    ured = u & ~(smax >> 1);
  end
  wire excl = neg && rest == dshift;
  wire spec_cand = (neg ^ d_neg) && top01 && d != smax && (MUTANT ? 1'b1 : !excl);
  wire spec_ovf = (d == 32'd0) || (ured >= d);
  wire new_cand = idiv_ripple_by_size(sigma, divtmp, op_size, d, d_neg);
  wire new_ovf = prediv_ripple_overflow_by_size(sigma, divtmp, op_size, d);
  assign mismatch = (spec_cand != new_cand) || (spec_cand && spec_ovf != new_ovf);
endmodule

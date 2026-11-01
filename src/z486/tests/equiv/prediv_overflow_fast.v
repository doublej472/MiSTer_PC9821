// check-equiv: functions ../../mul_div.sv div_sign_bit div_op_by_size prediv_overflow_by_size
// mul_div.sv div_overflow's PREDIV term: prediv_overflow_by_size (the compare
// on the masked sigma/divtmp registers, no 64-bit negator) against the form it
// replaced, (d == 0 || prediv_r_in >= d) with prediv_r_in the upper half of the
// size-masked double-width dividend {sigma, divtmp}, negated when its sign bit
// is set (the shipped always_comb restated). sigma, divtmp, size and the
// divisor register d are free (d is not assumed to be an abs value).
// MUTANT=1 drops the (L == 0) borrow term and must be refuted.
module prediv_overflow_fast #(parameter MUTANT = 0)
  (input [31:0] sigma, input [31:0] divtmp, input [1:0] op_size, input [31:0] d,
   output mismatch);
  localparam logic DIV_OP_MASK   = 1'b0;
  localparam logic DIV_OP_NEGATE = 1'b1;
// @@FUNCTIONS@@
  reg [63:0] full64; reg [31:0] r_in;
  always @* begin
    full64 = (op_size == 2'd0) ? {48'h0, sigma[7:0], divtmp[7:0]} :
             (op_size == 2'd1) ? {32'h0, sigma[15:0], divtmp[15:0]} :
                                 {sigma, divtmp};
    if (div_sign_bit(sigma, op_size)) full64 = ~full64 + 64'h1;
    case (op_size)
      2'd0: r_in = {24'h0, full64[15:8]};
      2'd1: r_in = {16'h0, full64[31:16]};
      default: r_in = full64[63:32];
    endcase
  end
  wire old_ovf = (d == 32'd0) || (r_in >= d);
  wire neg = div_sign_bit(sigma, op_size);
  wire [31:0] hx = div_op_by_size(DIV_OP_MASK, neg ? ~sigma : sigma, op_size);
  wire mut_ovf = (d == 32'd0) || (hx >= d) || (neg && (hx == d - 32'd1));
  wire new_ovf = MUTANT ? mut_ovf : prediv_overflow_by_size(sigma, divtmp, op_size, d);
  assign mismatch = old_ovf != new_ovf;
endmodule

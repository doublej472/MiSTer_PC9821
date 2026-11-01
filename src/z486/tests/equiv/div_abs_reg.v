// check-equiv: tempinduct
// check-equiv: functions ../../mul_div.sv div_abs_by_size div_sign_bit
// mul_div.sv divisor_abs_r against the live form it replaces,
// div_abs_by_size(tmpb, op_size) (the old div_divisor_abs).  The register is
// written on exactly the edges its two sources change, in the RTL's priority:
// the DEST_TMPB, gate_detect and PREDIV TMPB writes first (PREDIV last of the
// three), then the operand-size refresh (lowest priority):
//
//   DEST_TMPB   tmpb <= dest_value       and divisor_abs_r <= f(dest_value, op)
//   gate_detect tmpb <= desc_raw_hi      and divisor_abs_r <= f(desc_raw_hi, op)
//   PREDIV      tmpb <= f(tmpb, op)      and divisor_abs_r <= f(tmpb, op)
//   size change tmpb unchanged           and divisor_abs_r <= f(tmpb, op)
//
// where f = div_abs_by_size is the masked absolute value and op is the live
// operand size.  The PREDIV arm writes f(tmpb) back into tmpb, so the register
// keeps f(tmpb) there only because f is idempotent (f(f(x)) == f(x)): the
// load-bearing lemma, proved here over every 32-bit x and 2-bit size (the
// 8/16/32-bit abs is idempotent, the minimum-negative value of a size being
// its own fixed point).  The register is keyed to the operand size it saw, so
// the invariant is divisor_abs_r == f(tmpb, op_size_r); through the divide
// window op_size is constant (z486 loads op_size_du at instruction start and
// the divide microcode never rewrites it), so op_size == op_size_r where
// div_overflow reads it.  The three write enables, the size and the two
// sources are free every cycle, so the proof covers every order the RTL's
// enables can take.  Sequential: proved by induction from the reset state
// (TMPB 0, size 0, register 0, f(0) == 0).  MUTANT=1 drops the DEST_TMPB arm,
// so a raw divisor loaded into TMPB is never abs'd into the register, and must
// be refuted.
module div_abs_reg #(parameter MUTANT = 0)
  (input clk, input rst,
   input wr_tmpb,               // data_unit: exec && dest == DEST_TMPB
   input wr_gate,               // data_unit: exec && gate_detect
   input wr_md,                 // mul_div: tmpb_write (exec && aluop == PREDIV)
   input [1:0] op_size,         // live operand size
   input [31:0] dest_value, input [31:0] desc_raw_hi,
   input [31:0] lx, input [1:0] ls,   // the idempotence lemma's free operand
   output mismatch);
// @@FUNCTIONS@@
  reg [1:0]  op_size_r = 2'd0;
  reg [31:0] tmpb = 32'd0;
  reg [31:0] divisor_abs_r = 32'd0;
  // data_unit.sv's TMPB write, same priority.
  wire [31:0] div_abs = div_abs_by_size(tmpb, op_size);
  wire [31:0] tmpb_next = wr_md   ? div_abs
                        : wr_gate ? desc_raw_hi
                        : wr_tmpb ? dest_value : tmpb;
  // mul_div.sv's divisor_abs_r write, same priority; the DEST_TMPB arm is the
  // one the mutant drops, and the size refresh is last.
  wire [31:0] reg_next  = wr_md   ? div_abs
                        : wr_gate ? div_abs_by_size(desc_raw_hi, op_size)
                        : (wr_tmpb && !MUTANT) ? div_abs_by_size(dest_value, op_size)
                        : (op_size != op_size_r) ? div_abs
                        : divisor_abs_r;
  always @(posedge clk) begin
    if (rst) begin
      op_size_r <= 2'd0;
      tmpb <= 32'd0;
      divisor_abs_r <= 32'd0;
    end else begin
      op_size_r <= op_size;
      tmpb <= tmpb_next;
      divisor_abs_r <= reg_next;
    end
  end
  wire [31:0] lf = div_abs_by_size(lx, ls);
  assign mismatch = (divisor_abs_r != div_abs_by_size(tmpb, op_size_r))
                 || (div_abs_by_size(lf, ls) != lf);
endmodule

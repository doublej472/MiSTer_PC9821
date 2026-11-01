// check-equiv: functions ../../address_unit.sv relocate_csa32
// address_unit.sv's 32-bit relocation fold against the form it replaced:
// ((a + b) + s). The 3:2 compressor is the exact carry-save identity
//   a + b + s == (a^b^s) + (((a&b)|(b&s)|(a&s)) << 1)  (mod 2^32)
// so every operand must agree, with no state.
// MUTANT=1 drops the a&s term from the carry majority and must be refuted.
module addr_csa_reloc32 #(parameter MUTANT = 0)
  (input [31:0] a, input [31:0] b, input [31:0] s,
   output mismatch);
// @@FUNCTIONS@@
  wire [31:0] maj_mut = (a & b) | (b & s);
  wire [31:0] planted = (a ^ b ^ s) + {maj_mut[30:0], 1'b0};
  assign mismatch = (MUTANT ? planted : relocate_csa32(a, b, s)) != ((a + b) + s);
endmodule

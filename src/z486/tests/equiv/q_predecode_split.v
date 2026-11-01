// check-equiv: functions ../../ucode_rom.sv shift_source_predecode use_captured_predecode shift_uc_carry_predecode fpu_f8_predecode
// ucode_rom.sv q_shift_use_captured_r / q_shift_uc_carry_r / q_fpu_f8_r: the
// D-inputs formed on each port with q_sel_b (pb_slot) last (the shipped
// functions, pasted) against the form they replaced, the predecode of
// q_mem = q_sel_b ? q_mem_b : q_mem_a (use_captured restated from its former
// inline text).  Both 40-bit port words and the select are free.  MUTANT=1
// swaps the ports of the new fpu_f8 term and must be refuted.
module q_predecode_split #(parameter MUTANT = 0)
  (input [39:0] q_mem_a, input [39:0] q_mem_b, input q_sel_b, output mismatch);
  localparam ALUJMP_SHIFT = 7'h10, ALUJMP_SHIFT2 = 7'h12, ALUJMP_PASS2 = 7'h15;   // z486_pkg.sv
  localparam DEST_TMPH = 7'h11, DEST_DES_IO = 7'h6B, ALUSRC_TMPB = 6'h0B, BUSOP_IND_ALU2 = 6'h24;
  localparam SRC_TMPB = 6'h0B, SRC_TMPC = 6'h0C, SRC_TMPD = 6'h0D, SRC_TMPE = 6'h0E;
  localparam SRC_COUNTR = 6'h14, SRC_SIGMA = 6'h1E, SRC_IMM = 6'h1F, SRC_OPR_R = 6'h2D;
  localparam SRC_DSTREG = 6'h3D, SRC_SRCREG = 6'h3E, SRC_NEG1 = 6'h3F;
// @@FUNCTIONS@@
  wire [39:0] q_mem = q_sel_b ? q_mem_b : q_mem_a;
  wire uc_old = (q_mem[17:11] == ALUJMP_SHIFT2) ||
                ((q_mem[17:11] == ALUJMP_SHIFT) && (shift_source_predecode(q_mem[23:18]) == 4'd3));
  wire cy_old = shift_uc_carry_predecode(q_mem[36:0]);
  wire f8_old = fpu_f8_predecode(q_mem[36:0]);
  wire uc_new = q_sel_b ? use_captured_predecode(q_mem_b) : use_captured_predecode(q_mem_a);
  wire cy_new = q_sel_b ? shift_uc_carry_predecode(q_mem_b[36:0]) : shift_uc_carry_predecode(q_mem_a[36:0]);
  wire f8_new = (q_sel_b ^ (MUTANT != 0)) ? fpu_f8_predecode(q_mem_b[36:0]) : fpu_f8_predecode(q_mem_a[36:0]);
  assign mismatch = (uc_old != uc_new) || (cy_old != cy_new) || (f8_old != f8_new);
endmodule

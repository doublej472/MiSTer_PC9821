// check-equiv: functions ../../ucode_rom.sv shift2_source_predecode shift_captures_predecode
// ucode_rom.sv q_early_shift2_source / q_early_shift_captures (pasted from the
// RTL) against z486.sv's decode of uc_next (= q_early, whose low bits are
// q_mem = q_sel_b ? q_mem_b : q_mem_a), restated:
//   uc_next_shift2_source        = shift2_source_next_decode(uc_next[23:18])
//   uc_next_captures_shift_source = (uc_next[17:11] == ALUJMP_SHIFT2) ||
//        ((uc_next[17:11] == ALUJMP_SHIFT) && (uc_next[23:18] == SRC_SRCREG))
// new: each port decoded, q_sel_b selecting the result. Both 40-bit port words
// and the select are free. MUTANT=1 swaps the ports of the new capture
// decode and must be refuted.
module shift2_next_split #(parameter MUTANT = 0)
  (input [39:0] q_mem_a, input [39:0] q_mem_b, input q_sel_b, output mismatch);
  localparam ALUJMP_SHIFT  = 7'h10;   // z486_pkg.sv
  localparam ALUJMP_SHIFT2 = 7'h12;
  localparam SRC_TMPC   = 6'h0C;
  localparam SRC_TMPE   = 6'h0E;
  localparam SRC_SIGMA  = 6'h1E;
  localparam SRC_SRCREG = 6'h3E;
// @@FUNCTIONS@@
  function automatic [1:0] shift2_source_next_decode(input [5:0] source);
    case (source)
      SRC_TMPC:   shift2_source_next_decode = 2'd0;
      SRC_TMPE:   shift2_source_next_decode = 2'd1;
      SRC_SIGMA:  shift2_source_next_decode = 2'd2;
      SRC_SRCREG: shift2_source_next_decode = 2'd3;
      default:    shift2_source_next_decode = 2'd0;
    endcase
  endfunction
  wire [39:0] q_mem = q_sel_b ? q_mem_b : q_mem_a;
  wire [1:0] src_old = shift2_source_next_decode(q_mem[23:18]);
  wire       cap_old = (q_mem[17:11] == ALUJMP_SHIFT2) ||
                       ((q_mem[17:11] == ALUJMP_SHIFT) && (q_mem[23:18] == SRC_SRCREG));
  wire [1:0] src_new = q_sel_b ? shift2_source_predecode(q_mem_b[23:18])
                               : shift2_source_predecode(q_mem_a[23:18]);
  wire       cap_new = (q_sel_b ^ (MUTANT != 0)) ? shift_captures_predecode(q_mem_b)
                                                 : shift_captures_predecode(q_mem_a);
  assign mismatch = (src_old != src_new) || (cap_old != cap_new);
endmodule

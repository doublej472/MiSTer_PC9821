// check-equiv: functions ../../microsequencer.sv exec_redirect_of uaddr_next_hi uaddr_next_pick
// microsequencer.sv uaddr_next with the EX redirect formed for both uc_exec
// values (the shipped exec_redirect_of over the uc_exec-free conditions) and
// uc_exec picking each hold/step arm, against the form it replaced: one
// exec_redirect from the RTL's priority chain over the valid inputs (restated
// below as the translate_off exec_redirect_reference), each valid being
// uc_exec && its condition as z486.sv drives it (protection.sv redirect_taken,
// event_control.sv recipe_fallback_taken / gate_detect_now, mul_div.sv
// div_overflow, reljump_taken).  Every condition, target, select and uc_exec
// are free.  MUTANT=1 drops the held recipe rejection from the uc_exec-low arm
// and must be refuted.
module uaddr_exec_cofactor #(parameter MUTANT = 0)
  (input uc_exec, input rel_c, input [6:0] aluop, input [11:0] rel_t, input vm, input pe,
   input cpl_nz, input prot_prev, input [11:0] lj_t, input [11:0] ret_t,
   input prot_c, input [11:0] prot_t, input rec_c, input rec_hold, input [11:0] rec_t,
   input set_rpl, input div_c, input [11:0] div_t, input gate_c,
   input rst_n, input seq_advance, input pb_slot, input flt_v, input [11:0] flt_t,
   input bnd_v, input [11:0] bnd_t, input [11:0] uaddr, input [11:0] pb_entry_r,
   output mismatch);
  typedef struct packed {
      logic        valid;
      logic [11:0] target;
  } seq_redirect_t;
  localparam ALUJMP_LCALL = 7'h70;
  localparam ALUJMP_LJUMP = 7'h71;
  localparam ALUJMP_LJMPNP = 7'h72;
  localparam ALUJMP_LJMP86 = 7'h73;
  localparam ALUJMP_LJMPP = 7'h74;
  localparam ALUJMP_RETURN = 7'h7C;
  localparam [11:0] UADDR_CALL_GATE_386  = 12'h5BE;
  localparam [11:0] UADDR_MORE_PRIVILEGE = 12'h5FB;
// @@FUNCTIONS@@
  // old: the valids as z486.sv forms them, the reference priority chain
  wire rel_v  = uc_exec && rel_c;
  wire prot_v = uc_exec && prot_c;
  wire rec_v  = (uc_exec && rec_c) || rec_hold;
  wire div_v  = uc_exec && div_c;
  wire gate_v = uc_exec && gate_c;
  reg ov; reg [11:0] ot;
  always @* begin
    ov = 1'b0; ot = 12'h000;
    if (uc_exec) begin
      if (rel_v) begin ov = 1'b1; ot = rel_t; end
      case (aluop)
        ALUJMP_LJMP86: if (vm) begin ov = 1'b1; ot = lj_t; end
        ALUJMP_LJMPP: if (pe && !vm) begin ov = 1'b1; ot = lj_t; end
        ALUJMP_LJMPNP: if (pe && cpl_nz) begin ov = 1'b1; ot = lj_t; end
        ALUJMP_LCALL: begin ov = 1'b1; ot = lj_t; end
        ALUJMP_LJUMP: if (!prot_prev) begin ov = 1'b1; ot = lj_t; end
        ALUJMP_RETURN: begin ov = 1'b1; ot = ret_t; end
        default: ;
      endcase
      if (prot_v) begin ov = 1'b1; ot = prot_t; end
      if (rec_v) begin ov = 1'b1; ot = rec_t; end
      if (set_rpl) begin ov = 1'b1; ot = UADDR_MORE_PRIVILEGE; end
      if (div_v) begin ov = 1'b1; ot = div_t; end
      if (gate_v) begin ov = 1'b1; ot = UADDR_CALL_GATE_386; end
    end
    if (rec_v && !uc_exec) begin ov = 1'b1; ot = rec_t; end
  end
  wire        hi_v = !rst_n || bnd_v || flt_v;
  wire [11:0] hi   = uaddr_next_hi(rst_n, bnd_v, bnd_t, flt_t);
  wire [11:0] arm_pb   = hi_v ? hi : pb_entry_r + 12'd1;
  wire [11:0] o_hold = hi_v ? hi : ov ? ot : uaddr;
  wire [11:0] o_step = hi_v ? hi : ov ? ot : uaddr + 12'd1;
  wire [11:0] old_v = uaddr_next_pick(pb_slot, seq_advance, arm_pb, o_step, o_hold);
  // new
  seq_redirect_t x1, x0;
  assign x1 = exec_redirect_of(1'b1, rel_c, aluop, rel_t, vm, pe, cpl_nz, prot_prev, lj_t, ret_t,
                               prot_c, prot_t, rec_c, rec_hold, rec_t, set_rpl, div_c, div_t, gate_c);
  assign x0 = exec_redirect_of(1'b0, rel_c, aluop, rel_t, vm, pe, cpl_nz, prot_prev, lj_t, ret_t,
                               prot_c, prot_t, rec_c, MUTANT ? 1'b0 : rec_hold, rec_t, set_rpl,
                               div_c, div_t, gate_c);
  wire [11:0] h1 = hi_v ? hi : x1.valid ? x1.target : uaddr;
  wire [11:0] h0 = hi_v ? hi : x0.valid ? x0.target : uaddr;
  wire [11:0] s1 = hi_v ? hi : x1.valid ? x1.target : uaddr + 12'd1;
  wire [11:0] s0 = hi_v ? hi : x0.valid ? x0.target : uaddr + 12'd1;
  wire [11:0] new_v = uaddr_next_pick(pb_slot, seq_advance, arm_pb,
                                      uc_exec ? s1 : s0, uc_exec ? h1 : h0);
  assign mismatch = old_v != new_v;
endmodule

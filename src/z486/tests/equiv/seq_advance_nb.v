// z486.sv/event_control.sv seq_advance reading i_issue_nb (the cofactor of
// i_issue at branch_redirect = 0) against seq_advance reading i_issue, over
// the structure the RTL gives them:
//   branch_redirect = branch_ustep_rni && uc_exec && take (hardwired_control.sv);
//   q_flush = (uc_exec && pref) || (branch_redirect && !early_redirected) || rest;
//   q_flush_nb drops the branch_redirect term;
//   pb_issue = A && (sel ? slot_live : uc_exec) && !branch_redirect && !q_flush;
//   pb_issue_b23 = B && !q_flush; d2_ready = D && !q_flush;
//   d2_vipt_issue_ready = V && !q_flush; i_issue = (b23 || pb) && (L ? vipt : d2r);
//   seq_advance = (i_issue | uc_exec | other) & go.
// Every named input is free. The equality holds because a redirect needs
// uc_exec, which makes seq_advance independent of i_issue. MUTANT=1 lets the
// redirect fire without uc_exec, which must be refuted.
module seq_advance_nb #(parameter MUTANT = 0)
  (input uc_exec, input rni, input take, input early_redirected, input pref, input rest,
   input A, input sel, input slot_live, input B, input D, input V, input L,
   input other, input go, output mismatch);
  wire br = rni && (uc_exec || MUTANT) && take;
  wire qf    = (uc_exec && pref) || (br && !early_redirected) || rest;
  wire qf_nb = (uc_exec && pref) || rest;
  wire slot = sel ? slot_live : uc_exec;
  wire pb    = A && slot && !br && !qf;
  wire pb_nb = A && slot && !qf_nb;
  wire i_issue    = ((B && !qf)    || pb)    && (L ? (V && !qf)    : (D && !qf));
  wire i_issue_nb = ((B && !qf_nb) || pb_nb) && (L ? (V && !qf_nb) : (D && !qf_nb));
  wire seq_old = (i_issue    | uc_exec | other) & go;
  wire seq_new = (i_issue_nb | uc_exec | other) & go;
  assign mismatch = seq_old != seq_new;
endmodule

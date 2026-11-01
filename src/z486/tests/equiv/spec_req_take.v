// check-equiv: functions ../../z486.sv spec_req_on_take
// z486.sv pf_spec_req as spec_req_on_take (the shipped text, pasted) against the
// form it replaced:
//   pre && !eip_write_now && !(owner && !spec_owner_release), with
//   eip_write_now = branch_redirect || eip_write_other (folded into pre),
//   branch_redirect = ustep && take (hardwired_control.sv),
//   spec_owner_release = ustep && !branch_redirect.
// Every input is free. MUTANT=1 drops the release term from the reference (an
// owned line is never released by a not-taken uStep), which must be refuted.
module spec_req_take #(parameter MUTANT = 0)
  (input pre, input ustep, input owner, input take, output mismatch);
// @@FUNCTIONS@@
  wire redirect = ustep && take;
  wire release_ = MUTANT ? 1'b0 : (ustep && !redirect);
  wire old_req = pre && !redirect && !(owner && !release_);
  assign mismatch = old_req != spec_req_on_take(pre, ustep, owner, take);
endmodule

// check-equiv: functions ../../decoder.sv avail_ge
// decoder.sv avail_ge (pasted from the RTL): every D1 availability test
// (consume_prefix/consume_0f, struct_bytes_ok, sib_in_view, handoff_one_d2,
// handoff_raw_valid).
// old: k1q_avail >= need, with prefetch.sv's
//      k1q_avail = (k1q_avail_raw > k1_lim) ? k1_lim : k1q_avail_raw.
// new: avail_ge(raw, lim, need) = raw >= need && lim >= need.
// raw, lim and need are free. MUTANT=1 compares lim with > and must be refuted.
module k1_avail_ge #(parameter MUTANT = 0)
  (input [5:0] raw, input [5:0] lim, input [5:0] need, output mismatch);
// @@FUNCTIONS@@
  wire [5:0] avail = (raw > lim) ? lim : raw;
  wire old_ge = avail >= need;
  wire new_ge = MUTANT ? ((raw >= need) && (lim > need)) : avail_ge(raw, lim, need);
  assign mismatch = old_ge != new_ge;
endmodule

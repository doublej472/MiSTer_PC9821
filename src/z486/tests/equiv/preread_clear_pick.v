// l1_cache.sv rd_invalidated_r's set-wide clear term: the clear set compared
// against each preread-set candidate and picked by vipt_probe_fire, against
// the form it replaced, tag_clear_all && (tag_clear_set == preread_set) with
// preread_set = vipt_probe_fire ? vipt_probe_set : cpu_preread_set. Every
// input is free. MUTANT=1 swaps the pick and must be refuted.
module preread_clear_pick #(parameter MUTANT = 0)
  (input clear_all, input [7:0] clear_set, input fire,
   input [7:0] probe_set, input [7:0] cpu_set, output mismatch);
  wire [7:0] preread_set = fire ? probe_set : cpu_set;
  wire old_hit = clear_all && (clear_set == preread_set);
  wire pick = MUTANT ? !fire : fire;
  wire new_hit = clear_all && (pick ? (clear_set == probe_set) : (clear_set == cpu_set));
  assign mismatch = old_hit != new_hit;
endmodule

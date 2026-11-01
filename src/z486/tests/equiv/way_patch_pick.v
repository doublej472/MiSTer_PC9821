// check-equiv: functions ../../l1_cache.sv way_data_mux way_patch_pick
// l1_cache.sv way_patch_pick (the shipped text, pasted) against the form it
// replaced at the lookup and VIPT data picks:
//   pmatch && pway == way ? pdata : way_data_mux(way, data0..data3)
// with pmatch = patch_fwd_valid_r && the patch's dword compare. Every input bit
// is free. MUTANT=1 drops the way compare from the reference (a patch of
// another way would be returned), which the per-way form must be told apart from.
module way_patch_pick #(parameter MUTANT = 0)
  (input [1:0] way, input [31:0] data0, input [31:0] data1, input [31:0] data2,
   input [31:0] data3, input pmatch, input [1:0] pway, input [31:0] pdata,
   output mismatch);
// @@FUNCTIONS@@
  wire hit = pmatch && (MUTANT ? 1'b1 : (pway == way));
  wire [31:0] ref_v = hit ? pdata : way_data_mux(way, data0, data1, data2, data3);
  wire [31:0] new_v = way_patch_pick(way, data0, data1, data2, data3, pmatch, pway, pdata);
  assign mismatch = ref_v != new_v;
endmodule

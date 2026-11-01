// check-equiv: functions ../../l1_cache.sv vipt_tag_eq_split
// l1_cache.sv vipt_hit_vec: each way's tag compared on both arms of the resolve
// address with the VIPT TLB hit selecting last (the shipped vipt_tag_eq_split,
// pasted) against the compare it replaced, tag == (sel ? t : a)[TAG] with the
// A20 mask applied to the selected address (cache_unit masks each arm), and
// data_access's arms: resolve = page_en ? (tlb_hit ? hit_form : miss_form) :
// linear, use_tlb = page_en && tlb_hit, alt = page_en ? miss_form : linear.
// Every input bit is free (the property holds for any tag field; bits 26:12 here).
// MUTANT=1 gives the new alt arm the miss form even with paging off.
module vipt_tag_split #(parameter MUTANT = 0)
  (input page_en, input tlb_hit, input [31:0] hit_form, input [31:0] miss_form,
   input [31:0] linear, input a20, input [14:0] tag, output mismatch);
  localparam integer TAG_BITS = 15, TAG_MSB = 26, TAG_LSB = 12;
// @@FUNCTIONS@@
  wire [31:0] mask = a20 ? 32'hffff_ffff : ~32'h0010_0000;
  wire [31:0] resolve = (page_en ? (tlb_hit ? hit_form : miss_form) : linear) & mask;
  wire        use_tlb = page_en && tlb_hit;
  wire [31:0] tlb_arm = hit_form & mask;
  wire [31:0] alt_arm = ((page_en || MUTANT) ? miss_form : linear) & mask;
  wire old_eq = tag == resolve[TAG_MSB:TAG_LSB];
  wire new_eq = vipt_tag_eq_split(use_tlb, tag, tlb_arm[TAG_MSB:TAG_LSB], alt_arm[TAG_MSB:TAG_LSB]);
  assign mismatch = old_eq != new_eq;
endmodule

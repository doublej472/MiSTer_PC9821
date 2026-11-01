// check-equiv: functions ../../ucode_recipes.svh recipe_effective_entry
// check-equiv: functions ../../decoder.sv ov_hits recipe_effective_entry_hit
// decoder.sv handoff_overlay_entry = recipe_effective_entry_hit(entry,
// struct_ov_hit, opcode, modrm), with struct_ov_hit == ov_hits(entry) (the
// decoder's fuse; the hit is ov_hits taken on each arm of the entry mux),
// against the generated recipe_effective_entry(entry, opcode, modrm) it
// replaced. All three functions are the shipped text, pasted; every input bit
// is free, so a change to the generated overlay table that the hand-written
// hit form does not follow is refuted here. MUTANT=1 swaps two hit bits.
module overlay_entry_hit #(parameter MUTANT = 0)
  (input [11:0] entry, input [7:0] opcode, input [7:0] modrm, output mismatch);
// @@FUNCTIONS@@
  wire [5:0] h = ov_hits(entry);
  wire [5:0] hit = MUTANT ? {h[5:4], h[2], h[3], h[1:0]} : h;
  assign mismatch = recipe_effective_entry_hit(entry, hit, opcode, modrm) !=
                    recipe_effective_entry(entry, opcode, modrm);
endmodule

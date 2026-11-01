// check-equiv: functions ../../decoder.sv ov_hits group_ov_hits
// check-equiv: memory
// decoder.sv build_struct_work, the group ROM's arm of the overlay: the hit
// vector decoded from the group ROM's address (group_ov_hits) against the
// entry compares on the ROM's word it replaced, ov_hits(group_entry_rom[a]),
// for every one of the 1024 addresses of the shipped pla_group_entry.hex
// (both functions pasted from decoder.sv). The arm then applies the same
// recipe_effective_entry_hit(word, hits, opcode, modrm) as before, so equal
// hits give an equal entry. MUTANT=1 drops one address bit from the decode
// and must be refuted.
module group_overlay_addr #(parameter MUTANT = 0)
  (input [9:0] a, output mismatch);
  reg [15:0] group_entry_rom [0:1023];
  initial $readmemh("@@Z486_ROOT@@/pla_group_entry.hex", group_entry_rom);
// @@FUNCTIONS@@
  wire [9:0] a_dec = MUTANT ? {a[9:1], 1'b1} : a;
  assign mismatch = group_ov_hits(a_dec) != ov_hits(group_entry_rom[a][11:0]);
endmodule

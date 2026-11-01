// check-equiv: functions ../../pla_entry.svh pla_entry_lookup pla_group_lookup
// check-equiv: functions ../../pla_control.svh pla_control_opcode_lookup
// decoder.sv build_struct_work: the group select and row taken from the
// first-level entry word (entry_group = has_modrm && entry_first[11:6] == 0,
// group_code = entry_first[5:0]) against the opcode-class PLA they replaced
// (entry_group = pla_group_lookup(...)[6] && has_modrm, group_code =
// pla_group_lookup(...)[5:0]); the row is compared only where the group arm
// is selected. entry_first is pla_entry_lookup({data32, opcode, rep, pe, 1,
// 0F}) (the decoder's entry-ROM fuse, scripts/gen_pla_entry_rom.sv); all
// three generated functions are the shipped text and every input bit is
// free (rep included: a group row that depended on REP would be refuted).
// MUTANT=1 takes the row from entry_first[6:1] and must be refuted.
module group_from_entry #(parameter MUTANT = 0)
  (input data32, input [7:0] opcode, input pe, input has_0f, input rep, output mismatch);
// @@FUNCTIONS@@
  wire [11:0] ctl = pla_control_opcode_lookup(has_0f, opcode);
  wire        has_modrm = ctl[2] & ~ctl[0];
  wire [6:0]  grp = pla_group_lookup({data32, opcode, pe, has_0f});
  wire [15:0] first = pla_entry_lookup({data32, opcode, rep, pe, 1'b1, has_0f});
  wire        eg_old = grp[6] && has_modrm;
  wire        eg_new = has_modrm && (first[11:6] == 6'd0);
  wire [5:0]  row_new = MUTANT ? first[6:1] : first[5:0];
  assign mismatch = (eg_old != eg_new) || (eg_old && (grp[5:0] != row_new));
endmodule

// check-equiv: functions ../../pla_control.svh pla_control_opcode_lookup
// check-equiv: functions ../../decoder.sv modrm_disp_size
// The relative-branch literal plan that decoder.sv d2_branch_disp (and
// tests/equiv/spec_branch_disp.v) assume, from the decode tables: for every
// relative branch (Jcc 70-7F and 0F 80-8F, JMP EB/E9, CALL E8 - decoder.sv's
// rel_branch_kind) the opcode has no ModR/M, its one literal (lit2 none) is
// a displacement or an immediate that mirrors into it, of 1, 2 or 4 bytes,
// and the raw literal offset handoff_raw_lit_off_w = body_len - (lit1 +
// lit2) is 1. build_struct_work's no-ModR/M literal sizing and its body_len
// are restated from decoder.sv; the layout PLA, the D1 length table and
// modrm_disp_size are the shipped text. data32, addr32 and the byte after
// the opcode are free. MUTANT=1 adds ENTER (C8, two literals) to the branch
// set and must be refuted.
module branch_lit_plan #(parameter MUTANT = 0)
  (input has_0f, input [7:0] opcode, input data32, input addr32, input [7:0] modrm,
   output mismatch);
  localparam [1:0] LIT_NONE = 2'd0, LIT_IMM = 2'd1, LIT_DISP = 2'd2;
`include "@@Z486_ROOT@@/length_table.svh"
// @@FUNCTIONS@@
  wire rel = (!has_0f && (opcode[7:4] == 4'h7)) || (has_0f && (opcode[7:4] == 4'h8)) ||
             (!has_0f && ((opcode == 8'hEB) || (opcode == 8'hE9) || (opcode == 8'hE8))) ||
             (MUTANT && !has_0f && (opcode == 8'hC8));
  wire [11:0] ctl_bits = pla_control_opcode_lookup(has_0f, opcode);
  wire has_modrm = ctl_bits[2] & ~ctl_bits[0];
  reg [2:0] imm_total_size, imm_first_size, lit1_size, lit2_size;
  reg [1:0] lit1_kind, lit2_kind;
  reg       lit1_mirror;
  always @* begin
    imm_total_size = 3'd0; imm_first_size = 3'd0;
    lit1_kind = LIT_NONE; lit2_kind = LIT_NONE; lit1_size = 3'd0; lit2_size = 3'd0;
    lit1_mirror = 1'b0;
    // decoder.sv build_struct_work, the !has_modrm branch
    if (!has_0f && opcode[7:2] == 6'b101000) begin
      imm_total_size = addr32 ? 3'd4 : 3'd2;
      imm_first_size = imm_total_size;
    end else begin
      case (ctl_bits[11:6])
        6'b100111: imm_total_size = 3'd1;
        6'b110111: imm_total_size = data32 ? 3'd4 : 3'd2;
        6'b000111: imm_total_size = 3'd1;
        6'b010111: imm_total_size = 3'd2;
        6'b011111: imm_total_size = data32 ? 3'd4 : 3'd2;
        6'b100010: imm_total_size = 3'd1;
        6'b101111: imm_total_size = 3'd3;
        6'b111111: imm_total_size = data32 ? 3'd6 : 3'd4;
        default:   imm_total_size = 3'd0;
      endcase
      imm_first_size = imm_total_size;
      case (ctl_bits[11:6])
        6'b100010: imm_first_size = 3'd0;
        6'b101111: imm_first_size = 3'd2;
        6'b111111: imm_first_size = data32 ? 3'd4 : 3'd2;
        default: ;
      endcase
    end
    if (imm_total_size != 3'd0) begin
      if (imm_first_size != 3'd0) begin
        lit1_kind = LIT_IMM; lit1_size = imm_first_size; lit1_mirror = 1'b1;
      end
      if (imm_total_size != imm_first_size) begin
        if (lit1_kind == LIT_NONE) begin
          lit1_kind = LIT_DISP; lit1_size = imm_total_size - imm_first_size;
        end else begin
          lit2_kind = LIT_DISP; lit2_size = imm_total_size - imm_first_size;
        end
      end
    end
  end
  // body_len (decoder.sv build_struct_work)
  wire [3:0] len_opc = d1_length_lookup(has_0f, opcode, data32, addr32, modrm[5] | modrm[4]);
  wire [2:0] len_disp = (addr32 && (modrm[7:6] != 2'b11) && (modrm[2:0] == 3'b100))
                      ? 3'd0 : modrm_disp_size(addr32, modrm, 8'h00, 1'b0);
  wire [4:0] body_len = {2'b00, len_opc[2:0]} + (len_opc[3] ? {2'b00, len_disp} : 5'd0);
  wire [4:0] raw_lit_off_w = body_len - ({2'b00, lit1_size} + {2'b00, lit2_size});
  wire plan_ok = !has_modrm && (lit2_kind == LIT_NONE) &&
                 ((lit1_kind == LIT_DISP) || ((lit1_kind == LIT_IMM) && lit1_mirror)) &&
                 ((lit1_size == 3'd1) || (lit1_size == 3'd2) || (lit1_size == 3'd4)) &&
                 (raw_lit_off_w == 5'd1);
  assign mismatch = rel && !plan_ok;
endmodule

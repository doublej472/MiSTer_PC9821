// data_unit.sv EX-stage GPR write: the microcode destination's case.
// old: each destination arm wrote its own register/lane (DEST_EAX: eax <= v, DEST_eSP:
//      full or low-word write by pe && stack32, DEST_DSTREG: write_gpr(dst_reg_sel_r, v, op_size),
//      ..., DEST_USTEP_ALU gated by hardwired && !cancel, DEST_IRF gated by irf_writes_gpr).
// new: the case only decodes {gpr_wr_en, gpr_wr_sel, gpr_wr_size, gpr_wr_data} and one
//      write_gpr applies it.
// `arm` stands for the destination (one arm per DEST_* the old case names, plus "none"); the
// register file, every selector, size, flag and datum are free. write_gpr is restated from the
// RTL task (the two sides share it, so the proof is the dispatch). MUTANT=1 turns AH
// (DEST_AH, register 4 byte-sized) into a word write and must be refuted.
module gpr_wr_port #(parameter MUTANT = 0)
  (input [4:0] arm, input [255:0] regs, input [2:0] dst_sel, src_sel, countr_sel,
   input [1:0] op_size, input addr32, input stack_wide, input is_dword,
   input alu_gate, input irf_gate, input [31:0] v, alu_result, output mismatch);
  localparam A_EAX = 0, A_EDX = 1, A_ESP = 2, A_eSP = 3, A_EBP = 4, A_DSTREG = 5, A_SRCREG = 6,
             A_AX = 7, A_BP = 8, A_eAX_AL = 9, A_eDX_AH = 10, A_eCX = 11, A_eSI = 12, A_eDI = 13,
             A_AL = 14, A_AH = 15, A_BSWAP = 16, A_ALU = 17, A_IRF = 18;

  // write_gpr, as the RTL task, over the packed register file.
  function [255:0] wg(input [255:0] f, input [2:0] sel, input [31:0] val, input [1:0] size);
    reg [255:0] g;
    begin
      g = f;
      case (size)
        2'd0: begin
          case (sel)
            3'd0: g[7:0]     = val[7:0];
            3'd1: g[39:32]   = val[7:0];
            3'd2: g[71:64]   = val[7:0];
            3'd3: g[103:96]  = val[7:0];
            3'd4: g[15:8]    = val[7:0];
            3'd5: g[47:40]   = val[7:0];
            3'd6: g[79:72]   = val[7:0];
            3'd7: g[111:104] = val[7:0];
          endcase
        end
        2'd1: g[sel*32 +: 16] = val[15:0];
        2'd2: g[sel*32 +: 32] = val;
        default: ;
      endcase
      wg = g;
    end
  endfunction

  wire [31:0] bsw = {v[7:0], v[15:8], v[23:16], v[31:24]};
  wire [1:0]  ah_size = MUTANT ? 2'd1 : 2'd0;
  reg [255:0] old_n, new_n;
  always @* begin
    old_n = regs;
    case (arm)
      A_EAX:    old_n[31:0]    = v;
      A_EDX:    old_n[95:64]   = v;
      A_ESP:    old_n[159:128] = v;
      A_eSP:    if (stack_wide) old_n[159:128] = v; else old_n[143:128] = v[15:0];
      A_EBP:    old_n[191:160] = v;
      A_DSTREG: old_n = wg(old_n, dst_sel, v, op_size);
      A_SRCREG: old_n = wg(old_n, src_sel, v, op_size);
      A_AX:     old_n = wg(old_n, 3'd0, v, 2'd1);
      A_BP:     old_n = wg(old_n, 3'd5, v, 2'd1);
      A_eAX_AL: old_n = wg(old_n, 3'd0, v, op_size);
      A_eDX_AH: old_n = wg(old_n, op_size == 2'd0 ? 3'd4 : 3'd2, v, op_size);
      A_eCX:    old_n = wg(old_n, 3'd1, v, addr32 ? 2'd2 : 2'd1);
      A_eSI:    old_n = wg(old_n, 3'd6, v, addr32 ? 2'd2 : 2'd1);
      A_eDI:    old_n = wg(old_n, 3'd7, v, addr32 ? 2'd2 : 2'd1);
      A_AL:     old_n = wg(old_n, 3'd0, v, 2'd0);
      A_AH:     old_n = wg(old_n, 3'd4, v, ah_size);
      A_BSWAP:  old_n = wg(old_n, src_sel, bsw, 2'd2);
      A_ALU:    if (alu_gate) old_n = wg(old_n, dst_sel, alu_result, op_size);
      A_IRF:    if (irf_gate) old_n = wg(old_n, countr_sel, v, is_dword ? 2'd2 : 2'd1);
      default: ;
    endcase
  end

  reg        en;
  reg [2:0]  sel;
  reg [1:0]  size;
  reg [31:0] data;
  always @* begin
    en = 1'b1; sel = 3'd0; size = 2'd2; data = v;
    case (arm)
      A_EAX:    sel = 3'd0;
      A_EDX:    sel = 3'd2;
      A_ESP:    sel = 3'd4;
      A_eSP:    begin sel = 3'd4; if (!stack_wide) size = 2'd1; end
      A_EBP:    sel = 3'd5;
      A_DSTREG: begin sel = dst_sel; size = op_size; end
      A_SRCREG: begin sel = src_sel; size = op_size; end
      A_AX:     begin sel = 3'd0; size = 2'd1; end
      A_BP:     begin sel = 3'd5; size = 2'd1; end
      A_eAX_AL: begin sel = 3'd0; size = op_size; end
      A_eDX_AH: begin sel = (op_size == 2'd0) ? 3'd4 : 3'd2; size = op_size; end
      A_eCX:    begin sel = 3'd1; size = addr32 ? 2'd2 : 2'd1; end
      A_eSI:    begin sel = 3'd6; size = addr32 ? 2'd2 : 2'd1; end
      A_eDI:    begin sel = 3'd7; size = addr32 ? 2'd2 : 2'd1; end
      A_AL:     begin sel = 3'd0; size = 2'd0; end
      A_AH:     begin sel = 3'd4; size = 2'd0; end
      A_BSWAP:  begin sel = src_sel; data = bsw; end
      A_ALU:    begin en = alu_gate; sel = dst_sel; size = op_size; data = alu_result; end
      A_IRF:    begin en = irf_gate; sel = countr_sel; size = is_dword ? 2'd2 : 2'd1; end
      default:  en = 1'b0;
    endcase
    new_n = en ? wg(regs, sel, data, size) : regs;
  end
  assign mismatch = (old_n != new_n);
endmodule

// segmentation_unit.sv seg_base_for / raw_limit_for / ed_big_for: the descriptor-switch key
// (dsw) only redirects SS to CS.
// old: one selector tree per (sel, dsw), the SS leaf being `dsw ? CS : SS`.
// new: one dsw-free tree (SS leaf = SS) and a one-leaf swap after it,
//      `(dsw && sel == SEG_SS) ? CS : tree(sel)`.
// The seven descriptor payloads and the table bases are free; sel and dsw are free. The
// three functions are checked together (base 32 bits, raw limit 21 bits, ED/BIG 2 bits).
// MUTANT=1 swaps for SEG_DS instead of SEG_SS in the new base and must be refuted.
module seg_dsw_leaf #(parameter MUTANT = 0)
  (input [3:0] sel, input dsw,
   input [31:0] es_b, cs_b, ss_b, ds_b, fs_b, gs_b, tr_b, ldt_b, gdt_b, idt_b, input slctr2,
   input [20:0] es_l, cs_l, ss_l, ds_l, fs_l, gs_l, tr_l, ldt_l,
   input [1:0]  es_e, cs_e, ss_e, ds_e, fs_e, gs_e, tr_e,
   output mismatch);
  localparam [3:0] SEG_ES = 4'd0, SEG_CS = 4'd1, SEG_SS = 4'd2, SEG_DS = 4'd3, SEG_FS = 4'd4,
                   SEG_GS = 4'd5, SEG_IDT = 4'd6, SEG_TR = 4'd8, SEG_LDT = 4'd9, SEG_GDT = 4'd10;
  function [31:0] base_old(input [3:0] s, input d);
    case (s)
      SEG_ES: base_old = es_b;
      SEG_CS: base_old = cs_b;
      SEG_SS: base_old = d ? cs_b : ss_b;
      SEG_DS: base_old = ds_b;
      SEG_FS: base_old = fs_b;
      SEG_GS: base_old = gs_b;
      SEG_TR: base_old = tr_b;
      SEG_GDT: base_old = slctr2 ? ldt_b : gdt_b;
      SEG_IDT: base_old = idt_b;
      default: base_old = 32'h0;
    endcase
  endfunction
  function [31:0] base_tree(input [3:0] s);
    case (s)
      SEG_ES: base_tree = es_b;
      SEG_CS: base_tree = cs_b;
      SEG_SS: base_tree = ss_b;
      SEG_DS: base_tree = ds_b;
      SEG_FS: base_tree = fs_b;
      SEG_GS: base_tree = gs_b;
      SEG_TR: base_tree = tr_b;
      SEG_GDT: base_tree = slctr2 ? ldt_b : gdt_b;
      SEG_IDT: base_tree = idt_b;
      default: base_tree = 32'h0;
    endcase
  endfunction
  function [20:0] lim_old(input [3:0] s, input d);
    case (s)
      SEG_ES: lim_old = es_l;
      SEG_CS: lim_old = cs_l;
      SEG_SS: lim_old = d ? cs_l : ss_l;
      SEG_DS: lim_old = ds_l;
      SEG_FS: lim_old = fs_l;
      SEG_GS: lim_old = gs_l;
      SEG_TR: lim_old = tr_l;
      SEG_LDT: lim_old = ldt_l;
      default: lim_old = 21'h1F_FFFF;
    endcase
  endfunction
  function [20:0] lim_tree(input [3:0] s);
    case (s)
      SEG_ES: lim_tree = es_l;
      SEG_CS: lim_tree = cs_l;
      SEG_SS: lim_tree = ss_l;
      SEG_DS: lim_tree = ds_l;
      SEG_FS: lim_tree = fs_l;
      SEG_GS: lim_tree = gs_l;
      SEG_TR: lim_tree = tr_l;
      SEG_LDT: lim_tree = ldt_l;
      default: lim_tree = 21'h1F_FFFF;
    endcase
  endfunction
  function [1:0] ed_old(input [3:0] s, input d);
    case (s)
      SEG_ES: ed_old = es_e;
      SEG_CS: ed_old = cs_e;
      SEG_SS: ed_old = d ? cs_e : ss_e;
      SEG_DS: ed_old = ds_e;
      SEG_FS: ed_old = fs_e;
      SEG_GS: ed_old = gs_e;
      SEG_TR: ed_old = tr_e;
      default: ed_old = 2'b00;
    endcase
  endfunction
  function [1:0] ed_tree(input [3:0] s);
    case (s)
      SEG_ES: ed_tree = es_e;
      SEG_CS: ed_tree = cs_e;
      SEG_SS: ed_tree = ss_e;
      SEG_DS: ed_tree = ds_e;
      SEG_FS: ed_tree = fs_e;
      SEG_GS: ed_tree = gs_e;
      SEG_TR: ed_tree = tr_e;
      default: ed_tree = 2'b00;
    endcase
  endfunction
  wire [3:0] swap_sel = MUTANT ? SEG_DS : SEG_SS;
  wire [31:0] base_new = (dsw && sel == swap_sel) ? cs_b : base_tree(sel);
  wire [20:0] lim_new  = (dsw && sel == SEG_SS) ? cs_l : lim_tree(sel);
  wire [1:0]  ed_new   = (dsw && sel == SEG_SS) ? cs_e : ed_tree(sel);
  assign mismatch = (base_old(sel, dsw) != base_new) || (lim_old(sel, dsw) != lim_new) ||
                    (ed_old(sel, dsw) != ed_new);
endmodule

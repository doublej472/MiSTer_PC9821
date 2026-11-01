// check-equiv: functions ../../decoder.sv literal_value
// decoder.sv d2_branch_disp, the relative-branch displacement taken from the
// registered window at the constant raw offset 1 and sized by the skeleton,
// against the form z486.sv's spec_disp had: (branch_rel8 ? sext8 : ) of the
// d2_entry displacement, i.e. d2_final's merge of capture_literal over the
// literal window (skel_lit_win: the raw window at skel_raw_lit_off_r, or the
// late-captured skel_lit_r), restated here from decoder.sv for the
// displacement field. Premise - the relative-branch literal plan,
// tests/equiv/branch_lit_plan.v from the decode tables and a decoder fuse:
// one literal (lit2 none, so no phase B) of 1, 2 or 4 bytes, a displacement
// or a mirrored immediate, at raw offset 1. Every other input bit is free. MUTANT=1 drops
// the raw-offset premise and must be refuted.
module spec_branch_disp #(parameter MUTANT = 0)
  (input [31:0] lit_r, input [31:0] raw_hi, input [1:0] raw_lit_off, input window_raw,
   input [1:0] kind1, input [2:0] size1, input se1, input mirror1,
   input [1:0] kind2, input [2:0] size2, input se2, input mirror2,
   input fields_fit, input phaseB, input rel8,
   input [31:0] skel_disp, input [31:0] workB_disp, input [1:0] workB_kind2,
   input [2:0] workB_size2, input workB_se2, input workB_mirror2, input [1:0] workB_kind1,
   output mismatch);
  localparam [1:0] LIT_NONE = 2'd0, LIT_IMM = 2'd1, LIT_DISP = 2'd2;
// @@FUNCTIONS@@
  // capture_literal's displacement field (decoder.sv), in_lit1 = in.lit1_kind
  function automatic [31:0] cap_disp(input [31:0] d, input [31:0] win, input [1:0] kind,
                                     input [2:0] size, input se, input mirror, input [1:0] in_lit1);
    reg [31:0] v;
    begin
      v = literal_value(win, size, se);
      cap_disp = d;
      if (kind == LIT_IMM) begin
        if (mirror) cap_disp = v;
      end else if (kind == LIT_DISP) begin
        if (in_lit1 == LIT_NONE)
          case (size)
            3'd1: cap_disp = {d[31:8], v[7:0]};
            3'd2: cap_disp = {d[31:16], v[15:0]};
            3'd3: cap_disp = {d[31:24], v[23:0]};
            default: cap_disp = v;
          endcase
        else cap_disp = v;
      end
    end
  endfunction
  wire [31:0] raw_lit_win = raw_lit_off == 2'd0 ? lit_r :
                            raw_lit_off == 2'd1 ? {raw_hi[7:0],  lit_r[31:8]}  :
                            raw_lit_off == 2'd2 ? {raw_hi[15:0], lit_r[31:16]} :
                                                  {raw_hi[23:0], lit_r[31:24]};
  wire [31:0] win  = window_raw ? raw_lit_win : lit_r;
  wire [31:0] winB = (size1 == 3'd1) ? { 8'h00, win[31:8]}  :
                     (size1 == 3'd2) ? {16'h0,  win[31:16]} :
                     (size1 == 3'd3) ? {24'h0,  win[31:24]} : 32'h0;
  wire [31:0] capA  = cap_disp(skel_disp, win, kind1, size1, se1, mirror1, kind1);
  // capA's lit1 is cleared by its capture (kind1 == lit1_kind)
  wire [31:0] capAB = cap_disp(capA, winB, kind2, size2, se2, mirror2, LIT_NONE);
  wire [31:0] capB  = cap_disp(workB_disp, win, workB_kind2, workB_size2, workB_se2,
                               workB_mirror2, workB_kind1);
  wire has_litA = kind1 != LIT_NONE, has_litB = kind2 != LIT_NONE;
  wire [31:0] d2_disp = phaseB ? capB : !has_litA ? skel_disp : !has_litB ? capA :
                        fields_fit ? capAB : capA;
  wire [31:0] old_disp = rel8 ? {{24{d2_disp[7]}}, d2_disp[7:0]} : d2_disp;
  wire [31:0] bwin = window_raw ? {raw_hi[7:0], lit_r[31:8]} : lit_r;
  wire [31:0] new_disp = rel8 ? {{24{bwin[7]}}, bwin[7:0]} : literal_value(bwin, size1, se1);
  wire premise = !phaseB && (kind2 == LIT_NONE) && ((size1 == 3'd1) || (size1 == 3'd2) || (size1 == 3'd4)) &&
                 ((kind1 == LIT_DISP) || ((kind1 == LIT_IMM) && mirror1)) &&
                 (MUTANT || !window_raw || (raw_lit_off == 2'd1));
  assign mismatch = premise && (old_disp != new_disp);
endmodule

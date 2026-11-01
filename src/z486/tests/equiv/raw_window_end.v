// check-equiv: functions ../../decoder.sv raw_window_end
// decoder.sv raw_window_end (the shipped text, pasted) against the two-step
// form it replaced at handoff_raw_end:
//   {1'b0, body_len - (lit1 + lit2)} + (fits ? lit1 + lit2 : lit1),
//   fits = lit2_none || lit1 + lit2 <= 4,
// under the premise body_len >= lit1 + lit2 (the literals are part of the
// body; a translate_off fuse holds it at every D1 handoff). Every input bit is
// free. MUTANT=1 drops the premise: a body shorter than its literals wraps the
// 5-bit offset in the reference, which the new form must be told apart from.
module raw_window_end #(parameter MUTANT = 0)
  (input [4:0] body_len, input [2:0] lit1, input [2:0] lit2, input lit2_none,
   output mismatch);
// @@FUNCTIONS@@
  wire [3:0] lit_sum = {1'b0, lit1} + {1'b0, lit2};
  wire [4:0] off = body_len - ({2'b00, lit1} + {2'b00, lit2});
  wire [3:0] need = (lit2_none || lit_sum <= 4'd4) ? lit_sum : {1'b0, lit1};
  wire [5:0] ref_end = {1'b0, off} + {2'b00, need};
  wire premise = MUTANT ? 1'b1 : ({1'b0, body_len} >= {2'b00, lit1} + {2'b00, lit2});
  assign mismatch = premise && (ref_end != raw_window_end(body_len, lit1, lit2, lit2_none));
endmodule

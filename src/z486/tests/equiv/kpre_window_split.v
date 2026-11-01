// check-equiv: functions ../../prefetch.sv ptr_idx d1_window
// prefetch.sv k1q_early / k1q_next: the stepped D1 window formed from the
// step's size alone (k1p_adv_u) and picked against the held window by the
// decoder's byte-availability verdict (k1p_step_ok, k1p_commit_u), against
// the form it replaced: the preread window at k1p_preread_adv and the
// k1p_adv == k1p_preread_adv pick. The decoder terms are restated from
// decoder.sv (consume_prefix/consume_0f = pre_u && one byte in view;
// d1_preread_handoff / d1_handoff gate the handoff advance by
// d1_struct_ready and D2's slot). d1_window and ptr_idx are the shipped
// text; the queue, cursors, seed rebase and flush window are free.
// Premises (fused in prefetch.sv / decoder.sv): d1_struct_ready needs a byte
// in view (struct_len >= 1), and a seed cycle (empty queue) has none.
// MUTANT=1 drops D2's slot from the commit and must be refuted.
module kpre_window_split #(parameter MUTANT = 0)
  (input [255:0] q, input [3:0] k1p_word, input [1:0] k1p_boff, input [1:0] fa,
   input [3:0] seed_delta, input seed_now, input pre_u, input avail1, input struct_ready,
   input [3:0] hadv, input slot_ready, input q_flush, input [63:0] fl, output mismatch);
// @@FUNCTIONS@@
  // old (decoder.sv k1p_adv / k1p_preread_adv; prefetch.sv preread cursor)
  wire consume = pre_u && avail1;
  wire pre_handoff = !consume && struct_ready;
  wire handoff = !consume && slot_ready && struct_ready;
  wire [3:0] preread_adv = consume ? 4'd1 : pre_handoff ? hadv : 4'd0;
  wire [3:0] k1p_adv = consume ? 4'd1 : handoff ? hadv : 4'd0;
  wire [3:0] psum = {2'b00, k1p_boff} + preread_adv;
  wire [3:0] pword = seed_now ? (k1p_word + {2'b00, psum[3:2]} + seed_delta) : (k1p_word + {2'b00, psum[3:2]});
  wire [1:0] pboff = seed_now ? fa : psum[1:0];
  wire [63:0] hold = d1_window(q, k1p_word, k1p_boff);
  wire [63:0] preread_old = d1_window(q, pword, pboff);
  wire [63:0] early_old = q_flush ? fl : preread_old;
  wire [63:0] next_old = q_flush ? fl : (k1p_adv == preread_adv) ? preread_old : hold;
  // new
  wire [3:0] adv_u = pre_u ? 4'd1 : hadv;
  wire step_ok = pre_u ? avail1 : struct_ready;
  wire commit = MUTANT ? step_ok : (step_ok && (pre_u || slot_ready));
  wire [3:0] usum = {2'b00, k1p_boff} + adv_u;
  wire [3:0] uword = seed_now ? (k1p_word + seed_delta) : (k1p_word + {2'b00, usum[3:2]});
  wire [1:0] uboff = seed_now ? fa : usum[1:0];
  wire [63:0] step = d1_window(q, uword, uboff);
  wire [63:0] early_new = q_flush ? fl : (seed_now || step_ok) ? step : hold;
  wire [63:0] next_new = q_flush ? fl : (seed_now || commit) ? step : hold;
  wire premise = (!struct_ready || avail1) && (!seed_now || (!avail1 && !struct_ready));
  assign mismatch = premise && ((early_old != early_new) || (next_old != next_new));
endmodule

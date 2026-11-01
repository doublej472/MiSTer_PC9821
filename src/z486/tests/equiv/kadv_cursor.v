// prefetch.sv k1p_word_next / k1p_boff_next: the committed D1 cursor taken
// from the stepped cursor (k1p_u_word/boff, from k1p_adv_u, the seed rebase
// included) when D1 commits (k1p_commit_u) and held otherwise, the flush
// origin last, against the adder form it replaced: k1p_word + (k1p_boff +
// k1p_adv) >> 2, the flush origin, then the seed rebase. The decoder terms
// are restated from decoder.sv as in kpre_window_split.v (k1p_adv from
// consume_prefix/consume_0f and d1_handoff; k1p_adv_u / k1p_commit_u from
// the same inputs), so the decoder split is covered too. Premises (fused):
// the structural decode needs a byte in view, a seed cycle has none and is
// never a flush cycle (seed_now includes !q_flush through pf_can_fetch).
// MUTANT=1 leaves the seed out of the pick and must be refuted.
module kadv_cursor #(parameter MUTANT = 0)
  (input [3:0] k1p_word, input [1:0] k1p_boff, input [1:0] fa, input [3:0] seed_delta,
   input seed_now, input pre_u, input avail1, input struct_ready, input [3:0] hadv,
   input slot_ready, input q_flush, input [1:0] flush_word, input [1:0] k1pj_boff,
   output mismatch);
  wire consume = pre_u && avail1;
  wire handoff = !consume && slot_ready && struct_ready;
  wire [3:0] k1p_adv = consume ? 4'd1 : handoff ? hadv : 4'd0;
  wire [3:0] sum = {2'b00, k1p_boff} + k1p_adv;
  reg [3:0] w_old; reg [1:0] b_old;
  always @* begin
    w_old = k1p_word + {2'b00, sum[3:2]};
    b_old = sum[1:0];
    if (q_flush) begin w_old = {2'b00, flush_word}; b_old = k1pj_boff; end
    if (seed_now) begin w_old = w_old + seed_delta; b_old = fa; end
  end
  wire [3:0] adv_u = pre_u ? 4'd1 : hadv;
  wire step_ok = pre_u ? avail1 : struct_ready;
  wire commit = step_ok && (pre_u || slot_ready);
  wire [3:0] usum = {2'b00, k1p_boff} + adv_u;
  wire [3:0] uword = seed_now ? (k1p_word + seed_delta) : (k1p_word + {2'b00, usum[3:2]});
  wire [1:0] uboff = seed_now ? fa : usum[1:0];
  wire pick = MUTANT ? commit : (seed_now || commit);
  wire [3:0] w_new = q_flush ? {2'b00, flush_word} : pick ? uword : k1p_word;
  wire [1:0] b_new = q_flush ? k1pj_boff : pick ? uboff : k1p_boff;
  wire premise = (!struct_ready || avail1) && (!seed_now || (!avail1 && !struct_ready && !q_flush));
  assign mismatch = premise && ((w_old != w_new) || (b_old != b_new));
endmodule

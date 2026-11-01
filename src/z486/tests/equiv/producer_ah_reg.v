// check-equiv: tempinduct
// check-equiv: functions ../../data_unit.sv shift_ah_of
// The two registered per-producer AH lane selects that gpr_write_merge's
// lane_of uses in pv0/pv3f must equal the live decode of the registers they
// are registered beside, or the merge would take lane 1's byte from the wrong
// half of the datum:
//
//   producer 0 (shift token, data_unit recipe_shift_ah_r): written at
//     pipeline_advance from the load's (dst_reg_sel_r, op_size) when the token
//     loads (shift_ah_of, pasted from the RTL), and cleared on the kill, like
//     recipe_shift_hit_r; it is the visible token's decode only because the
//     token is not read otherwise.  tests/equiv/shift_hit_reg.v proves its two
//     siblings the same way.
//   producer 3 (write-back view, data_access vipt_load_wb_ah_r): written in the
//     same always_ff as vipt_load_wb_dst_r/_size_r, on the same two arms (EX
//     hit, slow completion, the slow arm later so it wins) and from the same
//     sources, so it equals (size_wb == 0) && dst_wb[2] every cycle, visible or
//     not.
//
// All conditions and source fields are free every cycle, so the proof covers
// every order the RTL's enables can take.  Sequential: proved by induction
// from the reset state.  MUTANT=1 swaps the write-back's AH/AL select (byte
// lane 1 takes the low half's decode) and must be refuted.
//
// The third flagged producer, the interrupt-entry ROM slot, has no new flop:
// its select is data_unit's ah_rom = op_size_is0 && dst_reg_sel_r[2], where
// op_size_is0 is the registered op_size == 0 decode whose correctness is
// tests/equiv/op_size_dec_reg.v and dst_reg_sel_r is the registered
// destination, so the composition is the live (op_size == 0) && dst[2] with
// the size decode already a flop.  A dedicated flop for the single AND would
// have to track op_size_du (z486, i_issue/uc_exec) and dst_reg_sel_r
// (data_unit, instr_start) across independent write edges, which one flop
// cannot do without a new port, for one LUT.
module producer_ah_reg #(parameter MUTANT = 0)
  (input clk, input rst,
   // producer 0 (shift token) write edges
   input p0_pa, input p0_cmd, input p0_cancel, input p0_kill,
   input [2:0] p0_dst_in, input [1:0] p0_size_in,
   // producer 3 (write-back) write edges and sources
   input p3_slow_done, input p3_ex_done,
   input [2:0] p3_slow_dst, input [1:0] p3_slow_size,
   input [2:0] p3_ex_dst, input [1:0] p3_ex_size,
   output mismatch);
// @@FUNCTIONS@@
  // ---- producer 0: shift token (data_unit recipe_shift_ah_r) ----------------
  wire p0_load = p0_cmd && !p0_cancel;          // recipe_shift_load
  reg p0_valid = 1'b0; reg [2:0] p0_dst = 3'd0; reg [1:0] p0_size = 2'd0;
  reg p0_killed = 1'b0; reg p0_ah = 1'b0;
  always @(posedge clk) begin
    if (rst) begin
      p0_valid <= 1'b0; p0_dst <= 3'd0; p0_size <= 2'd0; p0_killed <= 1'b0; p0_ah <= 1'b0;
    end else begin
      if (!p0_pa) begin
        if (p0_kill) p0_killed <= 1'b1;
      end else
        p0_killed <= 1'b0;
      if (p0_pa) begin
        p0_valid <= p0_load;
        if (p0_cmd) begin p0_dst <= p0_dst_in; p0_size <= p0_size_in; end
        p0_ah <= p0_load ? shift_ah_of(p0_dst_in, p0_size_in) : 1'b0;
      end else if (p0_kill) begin
        p0_ah <= 1'b0;
      end
    end
  end
  wire p0_vis = p0_valid && !p0_killed;

  // ---- producer 3: write-back view (data_access vipt_load_wb_ah_r) ----------
  reg [2:0] p3_dst = 3'd0; reg [1:0] p3_size = 2'd2; reg p3_ah = 1'b0;
  always @(posedge clk) begin
    if (rst) begin
      p3_dst <= 3'd0; p3_size <= 2'd2; p3_ah <= 1'b0;
    end else begin
      if (p3_ex_done) begin
        p3_dst <= p3_ex_dst; p3_size <= p3_ex_size;
        p3_ah <= (p3_ex_size == 2'd0) && p3_ex_dst[2];
      end
      if (p3_slow_done) begin
        p3_dst <= p3_slow_dst; p3_size <= p3_slow_size;
        p3_ah <= (p3_slow_size == 2'd0) && (MUTANT ? !p3_slow_dst[2] : p3_slow_dst[2]);
      end
    end
  end

  assign mismatch =
      (p0_ah != (p0_vis ? shift_ah_of(p0_dst, p0_size) : 1'b0)) ||
      (p3_ah != ((p3_size == 2'd0) && p3_dst[2]));
endmodule

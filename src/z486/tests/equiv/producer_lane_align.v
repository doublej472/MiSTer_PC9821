// check-equiv: functions ../../gpr_write_merge.sv be_of_size be_of_mode align_of_size align_of_mode lane_of
// gpr_write_merge.sv pv0..pv4 and pv3f (lane_of and the producer lane
// functions pasted from the RTL): a size-type producer (shift, ROM, write-back)
// and a mode-type producer (memory token, delay slot), in one lane.
// old: align_of_size(size, hb, data) / align_of_mode(mode, data).
// new: lane_of((size == 0) && hb, data) / lane_of(mode == EA_FWD_BHI, data).
// Every consumer takes a producer's byte only in its own lanes
// (be_of_size / be_of_mode), so the two must agree there; `use_s`/`use_m` are
// the consumer's other qualifiers (hit, view enable, register match) and
// `other` the rest of its mux. Everything is free. MUTANT=1 forgets the
// mode-type AH select and must be refuted.
module producer_lane_align #(parameter MUTANT = 0)
  (input [1:0] size, input hb, input [1:0] mode, input [31:0] data, input [1:0] lane,
   input use_s, input use_m, input [7:0] other, output mismatch);
  localparam [1:0] EA_FWD_BLO = 2'd0, EA_FWD_BHI = 2'd1, EA_FWD_W = 2'd2, EA_FWD_D = 2'd3;  // z486_pkg.sv
// @@FUNCTIONS@@
  wire [31:0] s_old = align_of_size(size, hb, data);
  wire [31:0] s_new = lane_of((size == 2'd0) && hb, data);
  wire [31:0] m_old = align_of_mode(mode, data);
  wire [31:0] m_new = lane_of(MUTANT ? 1'b0 : (mode == EA_FWD_BHI), data);
  wire [3:0]  s_be = be_of_size(size, hb);
  wire [3:0]  m_be = be_of_mode(mode);
  wire hs = use_s && s_be[lane];
  wire hm = use_m && m_be[lane];
  assign mismatch = ((hs ? s_old[lane*8 +: 8] : other) != (hs ? s_new[lane*8 +: 8] : other)) ||
                    ((hm ? m_old[lane*8 +: 8] : other) != (hm ? m_new[lane*8 +: 8] : other));
endmodule

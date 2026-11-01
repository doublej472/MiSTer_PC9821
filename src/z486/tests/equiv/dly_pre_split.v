// check-equiv: functions ../../z486.sv dly_lanes_of
// z486.sv dly_gpr_lanes_pre_r / dly_gpr_onehot_pre_r D-inputs: the lanes and
// one-hot formed on each port's predecode with pb_slot last (dly_lanes_of
// pasted from the RTL) against the form they replaced, the lanes of
// dly_gpr_pre = decode_dly_gpr(uc_next[30:24]).  uc_next[30:24] is
// pb_slot ? port B's field : port A's, and decode_dly_gpr reads nothing else
// that differs between the two forms, so decode(uc_next[30:24]) =
// pb_slot ? pre_b : pre_a (congruence; a translate_off fuse in z486.sv checks
// it every cycle).  pre_a, pre_b and the select are free.  MUTANT=1 swaps the
// ports of the new lanes and must be refuted.
module dly_pre_split #(parameter MUTANT = 0)
  (input [5:0] pre_a, input [5:0] pre_b, input pb_slot, output mismatch);
  localparam [1:0] FWD_BLO = 2'd0, FWD_BHI = 2'd1, FWD_W = 2'd2, FWD_D = 2'd3;  // z486.sv
// @@FUNCTIONS@@
  wire [5:0] pre = pb_slot ? pre_b : pre_a;
  wire [31:0] lanes_old = dly_lanes_of(pre[4:2], pre[1:0]);
  wire [7:0]  oh_old = 8'h01 << pre[4:2];
  wire        s = pb_slot ^ (MUTANT != 0);
  wire [31:0] lanes_new = s ? dly_lanes_of(pre_b[4:2], pre_b[1:0]) : dly_lanes_of(pre_a[4:2], pre_a[1:0]);
  wire [7:0]  oh_new = pb_slot ? (8'h01 << pre_b[4:2]) : (8'h01 << pre_a[4:2]);
  assign mismatch = (lanes_old != lanes_new) || (oh_old != oh_new);
endmodule

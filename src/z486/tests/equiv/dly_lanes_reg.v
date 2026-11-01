// check-equiv: tempinduct
// check-equiv: functions ../../z486.sv dly_lanes_of
// z486.sv dly_gpr_lanes_pre_r / dly_gpr_onehot_pre_r (the decode dly_lanes_of
// pasted from the RTL) against the former producer-4 terms over
// dly_gpr_sel_pre_r / dly_gpr_mode_pre_r: gpr_write_merge en4 = (dst_norm(4)
// == r) ? be_of_mode(mode_dly) : 0 and data_unit's pend_dly_mask one-hot
// 8'h01 << dst.  All four flops load from the same predecode on
// microcode_rom_ce (free), from reset sel 0 / mode FWD_D.  Sequential:
// proved by induction from the reset state.  MUTANT=1 resets the lanes as
// if the mode were FWD_W and must be refuted.
module dly_lanes_reg #(parameter MUTANT = 0)
  (input clk, input rst, input ce, input [2:0] sel_in, input [1:0] mode_in, output mismatch);
  localparam [1:0] FWD_BLO = 2'd0, FWD_BHI = 2'd1, FWD_W = 2'd2, FWD_D = 2'd3;  // z486.sv
// @@FUNCTIONS@@
  reg [2:0] sel = 3'd0; reg [1:0] mode = FWD_D;
  reg [31:0] lanes = 32'h0000_000F; reg [7:0] onehot = 8'h01;
  always @(posedge clk) begin
    if (rst) begin
      sel <= 3'd0; mode <= FWD_D;
      lanes <= dly_lanes_of(3'd0, MUTANT ? FWD_W : FWD_D); onehot <= 8'h01;
    end else if (ce) begin
      sel <= sel_in; mode <= mode_in;
      lanes <= dly_lanes_of(sel_in, mode_in); onehot <= 8'h01 << sel_in;
    end
  end
  // gpr_write_merge.sv dst_norm(4) / be_of_mode, restated
  wire [2:0] norm = ((mode == FWD_BLO) || (mode == FWD_BHI)) ? {1'b0, sel[1:0]} : sel;
  wire [3:0] be = (mode == FWD_BLO) ? 4'h1 : (mode == FWD_BHI) ? 4'h2 : (mode == FWD_W) ? 4'h3 : 4'hF;
  reg [31:0] old_lanes;
  integer r, b;
  always @* for (r = 0; r < 8; r = r + 1) for (b = 0; b < 4; b = b + 1)
    old_lanes[r*4 + b] = (norm == r) ? be[b] : 1'b0;
  assign mismatch = (old_lanes != lanes) || (onehot != (8'h01 << sel));
endmodule

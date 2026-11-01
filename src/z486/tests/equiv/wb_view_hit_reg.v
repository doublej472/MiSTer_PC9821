// check-equiv: tempinduct
// check-equiv: functions ../../data_access.sv wb_view_hit_of
// data_access.sv vipt_load_wb_view_hit_r (its decode wb_view_hit_of pasted
// from the RTL) against gpr_write_merge's former per-byte view hit,
// hitv3 = hit3 && !wb_is_alu with hit3 = v_wb && en3[b] and
// en3 = (dst_norm(3) == r) ? be_of_size(size_wb, dst_wb[2]) : 0, over the
// write-back registers v_wb = vipt_load_wb_valid_r, dst_wb/size_wb/wb_is_alu
// = vipt_load_wb_dst_r/_size_r/_is_alu_r.  The flop is written on exactly the
// edges vipt_load_wb_valid_r is, in the same order (reset, the per-cycle
// clear, the EX-hit write-back, the slow write-back, the flush clear); the
// write conditions and both sources are free every cycle.  Sequential:
// proved by induction from the reset state.  MUTANT=1 loads the slow
// write-back's hits from the EX token's is_alu and must be refuted.
module wb_view_hit_reg #(parameter MUTANT = 0)
  (input clk, input rst, input set_ex, input set_slow, input flush,
   input [2:0] ex_dst, input [1:0] ex_size, input ex_alu,
   input [2:0] slow_dst, input [1:0] slow_size, input slow_alu,
   output mismatch);
// @@FUNCTIONS@@
  function automatic [3:0] be_of_size(input [1:0] size, input high_byte);  // gpr_write_merge.sv
    be_of_size = (size == 2'd0) ? (high_byte ? 4'h2 : 4'h1)
               : (size == 2'd1) ? 4'h3 : 4'hF;
  endfunction
  reg valid_r = 1'b0; reg [2:0] dst_r = 3'd0; reg [1:0] size_r = 2'd2; reg alu_r = 1'b0;
  reg [31:0] hit_r = 32'd0;
  always @(posedge clk) begin
    if (rst) begin
      valid_r <= 1'b0; dst_r <= 3'd0; size_r <= 2'd2; alu_r <= 1'b0; hit_r <= 32'd0;
    end else begin
      valid_r <= 1'b0; hit_r <= 32'd0;
      if (set_ex) begin
        valid_r <= 1'b1; dst_r <= ex_dst; size_r <= ex_size; alu_r <= ex_alu;
        hit_r <= wb_view_hit_of(ex_dst, ex_size, ex_alu);
      end
      if (set_slow) begin
        valid_r <= 1'b1; dst_r <= slow_dst; size_r <= slow_size; alu_r <= slow_alu;
        hit_r <= wb_view_hit_of(slow_dst, slow_size, MUTANT ? ex_alu : slow_alu);
      end
      if (flush) begin
        valid_r <= 1'b0; hit_r <= 32'd0;
      end
    end
  end
  wire [2:0] norm = (size_r == 2'd0) ? {1'b0, dst_r[1:0]} : dst_r;   // dst_norm(3)
  wire [3:0] lanes = be_of_size(size_r, dst_r[2]);
  reg [31:0] old_hit;
  integer r, b;
  always @* begin
    for (r = 0; r < 8; r = r + 1)
      for (b = 0; b < 4; b = b + 1)
        old_hit[r*4 + b] = valid_r && ((norm == r) ? lanes[b] : 1'b0) && !alu_r;
  end
  assign mismatch = old_hit != hit_r;
endmodule

// check-equiv: tempinduct
// data_access.sv vipt_load_wb_wmask_r against data_unit's former write-back
// term of pend_write_mask, load_wb_valid ? 8'h01 << load_wb_widx : 0, with
// load_wb_widx = (size == 0) ? {0, dst[1:0]} : dst over vipt_load_wb_dst_r /
// vipt_load_wb_size_r.  The flop is written on exactly the edges
// vipt_load_wb_valid_r is, in the same order: the synchronous reset (dst 0,
// size 2, valid 0), the per-cycle clear, the EX-hit write-back (from
// vipt_load_ex_r), the slow write-back (from vipt_load_slow_r, later in the
// block so it wins) and the flush clear (last).  The four write conditions
// and both sources are free inputs every cycle, so the proof covers every
// order the RTL's enables can take.  Sequential: proved by induction from the
// reset state.  MUTANT=1 forgets the flush clear on the new flop and must be
// refuted.
module wb_wmask_reg #(parameter MUTANT = 0)
  (input clk, input rst, input set_ex, input set_slow, input flush,
   input [2:0] ex_dst, input [1:0] ex_size, input [2:0] slow_dst, input [1:0] slow_size,
   output mismatch);
  function automatic [7:0] wb_wmask_of(input [2:0] dst, input [1:0] size);  // data_access.sv
    wb_wmask_of = 8'h01 << ((size == 2'd0) ? {1'b0, dst[1:0]} : dst);
  endfunction
  reg valid_r = 1'b0; reg [2:0] dst_r = 3'd0; reg [1:0] size_r = 2'd2; reg [7:0] wmask_r = 8'd0;
  always @(posedge clk) begin
    if (rst) begin
      valid_r <= 1'b0; dst_r <= 3'd0; size_r <= 2'd2; wmask_r <= 8'd0;
    end else begin
      valid_r <= 1'b0; wmask_r <= 8'd0;
      if (set_ex) begin
        valid_r <= 1'b1; dst_r <= ex_dst; size_r <= ex_size;
        wmask_r <= wb_wmask_of(ex_dst, ex_size);
      end
      if (set_slow) begin
        valid_r <= 1'b1; dst_r <= slow_dst; size_r <= slow_size;
        wmask_r <= wb_wmask_of(slow_dst, slow_size);
      end
      if (flush) begin
        valid_r <= 1'b0;
        if (!MUTANT) wmask_r <= 8'd0;
      end
    end
  end
  // data_unit.sv load_wb_widx and the old pend_write_mask term
  wire [2:0] load_wb_widx = (size_r == 2'd0) ? {1'b0, dst_r[1:0]} : dst_r;
  wire [7:0] old_term = valid_r ? (8'h01 << load_wb_widx) : 8'h00;
  assign mismatch = old_term != wmask_r;
endmodule

// check-equiv: tempinduct
// check-equiv: functions ../../data_unit.sv shift_hit_of
// data_unit.sv recipe_shift_hit_r / recipe_shift_wmask_r (the decode
// shift_hit_of pasted from the RTL) against the former producer-0 terms:
// gpr_write_merge hit0 = v_shift && en0[b], en0 = (dst_norm(0) == r) ?
// be_of_size(size_shift, dst_shift[2]) : 0, and pend_shift_mask =
// v_shift ? 8'h01 << recipe_shift_widx : 0, with v_shift =
// recipe_shift_write.valid && !recipe_shift_killed, over the registers as
// data_unit updates them: at pipeline_advance valid takes the load (which
// includes !recipe_commit_cancel), dst/size/widx load under the load without
// the cancel term, killed clears; otherwise killed sets on the kill event;
// synchronous reset (valid 0, dst 0, size 0, widx 0, killed 0).
// pipeline_advance, the load, cancel, the kill event, destination and size
// are free every cycle.  Sequential: proved by induction from the reset
// state.  MUTANT=1 forgets to clear the mask on a kill and must be refuted.
module shift_hit_reg #(parameter MUTANT = 0)
  (input clk, input rst, input pa, input cmd, input cancel, input kill,
   input [2:0] dst_in, input [1:0] size_in, output mismatch);
// @@FUNCTIONS@@
  function automatic [3:0] be_of_size(input [1:0] size, input high_byte);  // gpr_write_merge.sv
    be_of_size = (size == 2'd0) ? (high_byte ? 4'h2 : 4'h1)
               : (size == 2'd1) ? 4'h3 : 4'hF;
  endfunction
  wire load = cmd && !cancel;           // recipe_shift_load
  wire [2:0] widx_in = (size_in == 2'd0) ? {1'b0, dst_in[1:0]} : dst_in;
  reg valid = 1'b0; reg [2:0] dst = 3'd0; reg [1:0] size = 2'd0; reg [2:0] widx = 3'd0;
  reg killed = 1'b0; reg [31:0] hit_r = 32'h0; reg [7:0] wmask_r = 8'h0;
  always @(posedge clk) begin
    if (rst) begin
      valid <= 1'b0; dst <= 3'd0; size <= 2'd0; widx <= 3'd0; killed <= 1'b0;
      hit_r <= 32'h0; wmask_r <= 8'h0;
    end else begin
      if (!pa) begin
        if (kill) killed <= 1'b1;
      end else
        killed <= 1'b0;
      if (pa) begin
        valid <= load;
        if (cmd) begin dst <= dst_in; size <= size_in; widx <= widx_in; end
        hit_r   <= load ? shift_hit_of(dst_in, size_in) : 32'h0;
        wmask_r <= load ? (8'h01 << widx_in) : 8'h0;
      end else if (kill) begin
        hit_r <= 32'h0;
        if (!MUTANT) wmask_r <= 8'h0;
      end
    end
  end
  wire v = valid && !killed;
  wire [2:0] norm = (size == 2'd0) ? {1'b0, dst[1:0]} : dst;
  wire [3:0] lanes = be_of_size(size, dst[2]);
  reg [31:0] old_hit;
  integer r, b;
  always @* begin
    for (r = 0; r < 8; r = r + 1)
      for (b = 0; b < 4; b = b + 1)
        old_hit[r*4 + b] = v && ((norm == r) ? lanes[b] : 1'b0);
  end
  wire [7:0] old_mask = v ? (8'h01 << widx) : 8'h00;
  assign mismatch = (old_hit != hit_r) || (old_mask != wmask_r);
endmodule

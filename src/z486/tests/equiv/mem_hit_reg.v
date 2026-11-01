// check-equiv: tempinduct
// check-equiv: functions ../../data_unit.sv mem_hit_of
// data_unit.sv recipe_memory_hit_r (its decode mem_hit_of pasted from the
// RTL) against gpr_write_merge's former producer-1 hit, hit1 = v_mem &&
// en1[b] with v_mem = recipe_memory_write.valid && !recipe_memory_killed and
// en1 = (dst_norm(1) == r) ? be_of_mode(mode_mem) : 0, over the registers as
// data_unit updates them: at pipeline_advance the token's valid takes
// load && !cancel, its dst/mode load under load (mode from op_size and
// dst[2], recipe_memory_mode_next) and killed clears; otherwise killed sets
// on recipe_memory_kill; synchronous reset (valid 0, dst 0, mode EA_FWD_D,
// killed 0).  pipeline_advance, load, cancel, the kill event, the
// destination and the size are free every cycle.  Sequential: proved by
// induction from the reset state.  MUTANT=1 does not clear the hits on a kill
// and must be refuted.
module mem_hit_reg #(parameter MUTANT = 0)
  (input clk, input rst, input pa, input load, input cancel, input kill,
   input [2:0] dst_in, input [1:0] size_in, output mismatch);
  localparam [1:0] EA_FWD_BLO = 2'd0, EA_FWD_BHI = 2'd1, EA_FWD_W = 2'd2, EA_FWD_D = 2'd3;  // z486_pkg.sv
// @@FUNCTIONS@@
  function automatic [3:0] be_of_mode(input [1:0] mode);   // gpr_write_merge.sv
    case (mode)
      EA_FWD_BLO: be_of_mode = 4'h1;
      EA_FWD_BHI: be_of_mode = 4'h2;
      EA_FWD_W:   be_of_mode = 4'h3;
      default:    be_of_mode = 4'hF;
    endcase
  endfunction
  wire [1:0] mode_next = (size_in == 2'd0) ? (dst_in[2] ? EA_FWD_BHI : EA_FWD_BLO)
                                           : (size_in == 2'd1 ? EA_FWD_W : EA_FWD_D);
  reg valid = 1'b0; reg [2:0] dst = 3'd0; reg [1:0] mode = EA_FWD_D; reg killed = 1'b0;
  reg [31:0] hit_r = 32'h0;
  always @(posedge clk) begin
    if (rst) begin
      valid <= 1'b0; dst <= 3'd0; mode <= EA_FWD_D; killed <= 1'b0; hit_r <= 32'h0;
    end else begin
      if (!pa) begin
        if (kill) killed <= 1'b1;
      end else
        killed <= 1'b0;
      if (pa) begin
        valid <= load && !cancel;
        if (load) begin dst <= dst_in; mode <= mode_next; end
      end
      if (pa)
        hit_r <= (load && !cancel) ? mem_hit_of(dst_in, mode_next) : 32'h0;
      else if (kill && !MUTANT)
        hit_r <= 32'h0;
    end
  end
  wire [2:0] norm = ((mode == EA_FWD_BLO) || (mode == EA_FWD_BHI)) ? {1'b0, dst[1:0]} : dst;
  wire [3:0] lanes = be_of_mode(mode);
  reg [31:0] old_hit;
  integer r, b;
  always @* begin
    for (r = 0; r < 8; r = r + 1)
      for (b = 0; b < 4; b = b + 1)
        old_hit[r*4 + b] = valid && !killed && ((norm == r) ? lanes[b] : 1'b0);
  end
  assign mismatch = old_hit != hit_r;
endmodule

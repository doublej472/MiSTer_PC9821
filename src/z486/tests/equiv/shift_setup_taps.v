// shifter.sv: the SHIFT1 setup_result (the RCL and SAR arms) and the SHIFT1
// eq_width_cf capture, restated in their former width-indexed form (width_mask,
// instr_cf << (width-1), alu_dst[width-1], a per-size SAR replicate) against the
// fixed-tap form (upstream 96f52b1 "simplify shift setup": per-size RCL taps and
// one dst_sign tap).  Every input free, op_size == 3 included (the former width
// and mask fall to their 32-bit default there, the new taps to their last arm).
// MUTANT=1 takes the 16-bit RCL carry tap one bit low and must be refuted.
module shift_setup_taps #(parameter MUTANT = 0)
  (input [31:0] alu_dst, input instr_cf, input [1:0] op_size, input [2:0] shift_operation,
   input instr_is_shxd, output mismatch);
  localparam [2:0] ROL = 3'd0, ROR = 3'd1, RCL = 3'd2, RCR = 3'd3,
                   SHL = 3'd4, SHR = 3'd5, SAL = 3'd6, SAR = 3'd7;
  // former
  wire [5:0] width = op_size == 2'd0 ? 6'd8 :
                     op_size == 2'd1 ? 6'd16 : 6'd32;
  wire [31:0] width_mask = op_size == 2'd0 ? 32'h0000_00ff :
                           op_size == 2'd1 ? 32'h0000_ffff : 32'hffff_ffff;
  reg [31:0] old_setup;
  always @* begin
    old_setup = alu_dst;
    if (!instr_is_shxd) begin
      case (shift_operation)
        RCL:     old_setup = (instr_cf << (width-1)) | ((alu_dst & width_mask) >> 1);
        RCR:     old_setup = {alu_dst, instr_cf};
        SHL, SHR, SAL: old_setup = 32'd0;
        SAR:     old_setup = op_size == 2'd0 ? {32{alu_dst[7]}} :
                             op_size == 2'd1 ? {32{alu_dst[15]}} : {32{alu_dst[31]}};
        default: old_setup = alu_dst;
      endcase
    end
  end
  wire old_eqcf = shift_operation[0] ? alu_dst[width-1] : alu_dst[0];
  // fixed taps
  wire dst_sign = op_size == 2'd0 ? alu_dst[7] :
                  op_size == 2'd1 ? alu_dst[15] : alu_dst[31];
  reg [31:0] new_setup;
  always @* begin
    new_setup = alu_dst;
    if (!instr_is_shxd) begin
      case (shift_operation)
        RCL:     new_setup = op_size == 2'd0 ? {24'd0, instr_cf, alu_dst[7:1]} :
                             op_size == 2'd1 ? (MUTANT ? {17'd0, instr_cf, alu_dst[14:1]}
                                                       : {16'd0, instr_cf, alu_dst[15:1]}) :
                                               {instr_cf, alu_dst[31:1]};
        RCR:     new_setup = {alu_dst, instr_cf};
        SHL, SHR, SAL: new_setup = 32'd0;
        SAR:     new_setup = {32{dst_sign}};
        default: new_setup = alu_dst;
      endcase
    end
  end
  wire new_eqcf = shift_operation[0] ? dst_sign : alu_dst[0];
  assign mismatch = (old_setup != new_setup) || (old_eqcf != new_eqcf);
endmodule

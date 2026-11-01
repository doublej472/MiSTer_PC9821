// mul_div.sv div7_calc: r_next_full, the DIV step's add or subtract.
// old: r_next_full = nonneg ? (r_alu_a - {3'b0, d}) : (r_alu_a + {3'b0, d}) (35 bits).
// new: one adder, r_alu_a + ({3'b0, d} ^ {35{nonneg}}) + nonneg.
// The step's carry flag reads r_next_full[width] ^ r_alu_a[width]; it is checked too, over every
// width the size selects (8, 16, 32), with d zero above its width as div_op_by_size makes it.
// r_alu_a, d, the direction and the size are free. MUTANT=1 drops the +1 of the subtract and
// must be refuted.
module div_step_addsub #(parameter MUTANT = 0)
  (input [34:0] r_alu_a, input [31:0] d_in, input nonneg, input [1:0] size, output mismatch);
  wire [4:0]  width = (size == 2'd0) ? 5'd8 : (size == 2'd1) ? 5'd16 : 5'd32;
  wire [31:0] d = (size == 2'd0) ? {24'h0, d_in[7:0]} : (size == 2'd1) ? {16'h0, d_in[15:0]} : d_in;
  wire [34:0] old_v = nonneg ? (r_alu_a - {3'b0, d}) : (r_alu_a + {3'b0, d});
  wire [34:0] new_v = r_alu_a + ({3'b0, d} ^ {35{nonneg}}) + {34'd0, nonneg & ~MUTANT};
  assign mismatch = (old_v != new_v) || ((old_v[width] ^ r_alu_a[width]) != (new_v[width] ^ r_alu_a[width]));
endmodule

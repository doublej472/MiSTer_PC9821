// gpr_write_merge.sv ex_select against byte_ex, the per-register EX merge it is
// value-identical to at ex_value[sel*32 +: 32].  Both restated (yosys cannot
// elaborate the shipped producer_lane/dst_norm calls inside ex_select's
// unrolled loop): each producer's hit for register r is a free bit vector
// h<k>[r*4 + b] (the registered hit_shift/hit_mem/hitv3_wb/lanes_dly bits, or
// the decoded en<k> && valid - the same per-register hit both forms read);
// byte_ex takes the youngest visible producer covering byte b of register r,
// else cur; ex_select first picks register sel's hits and cur, then merges in
// the same order, lowest priority first.  A translate_off fuse in
// gpr_write_merge checks ex_*_value against ex_value every cycle.
// MUTANT=1 indexes producer 3's hit by register 0 in the new form.
module ex_select_merge #(parameter MUTANT = 0)
  (input [255:0] cur, input [255:0] h_flat, input [255:0] pv_flat,
   input [7:0] vis_ex, input [2:0] sel, output mismatch);
  wire [31:0] h  [0:7];
  wire [31:0] pv [0:7];
  genvar gk; generate for (gk = 0; gk < 8; gk = gk + 1) begin : g
    assign h[gk]  = h_flat[gk*32 +: 32];
    assign pv[gk] = pv_flat[gk*32 +: 32];
  end endgenerate
  // byte_ex for every register, then the 8:1 read at sel (the old path)
  reg [255:0] ex_value;
  reg [31:0]  new_v;
  reg [3:0]   hv;
  integer r, b, k;
  always @* begin
    for (r = 0; r < 8; r = r + 1)
      for (b = 0; b < 4; b = b + 1) begin
        ex_value[r*32 + b*8 +: 8] = cur[r*32 + b*8 +: 8];
        for (k = 0; k < 8; k = k + 1)
          if (vis_ex[k] && h[k][r*4 + b]) ex_value[r*32 + b*8 +: 8] = pv[k][b*8 +: 8];
      end
    // ex_select(sel)
    new_v = cur[sel*32 +: 32];
    for (b = 0; b < 4; b = b + 1)
      for (k = 0; k < 8; k = k + 1) begin
        hv = (MUTANT && k == 3) ? h[k][3:0] : h[k][sel*4 +: 4];
        if (vis_ex[k] && hv[b]) new_v[b*8 +: 8] = pv[k][b*8 +: 8];
      end
  end
  assign mismatch = ex_value[sel*32 +: 32] != new_v;
endmodule

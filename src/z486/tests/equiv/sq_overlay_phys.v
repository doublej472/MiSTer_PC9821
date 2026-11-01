// check-equiv: functions ../../l1_cache.sv sq_slot_live sq_overlay_pick
// l1_cache.sv store-queue overlay (depth 4): the physical-slot form (the shipped
// sq_slot_live / sq_overlay_pick, pasted: per-slot hit = live && valid && the
// slot's own address == the word; per lane the youngest covering hit) against
// the age-ordered chain it replaced (restated, as kept in the RTL reference):
// oldest to youngest, `if (k < count && valid[tail+k] && addr[tail+k] == word)
// data = merge32(data, ...); be |= ...`.  Valid bits, addresses, data, byte
// enables, count, tail and the word are free.  MUTANT=1 drops the age guard
// (k < count) from the new hit and must be refuted.
module sq_overlay_phys #(parameter MUTANT = 0)
  (input [3:0] v, input [119:0] a, input [127:0] d, input [15:0] be, input [2:0] cnt,
   input [1:0] tail, input [29:0] word, output mismatch);
  localparam integer STOREQ_DEPTH = 4, STOREQ_IDX_BITS = 2, STOREQ_CNT_BITS = 3;
// @@FUNCTIONS@@
  function [31:0] be_mask(input [3:0] b);
    be_mask = {{8{b[3]}}, {8{b[2]}}, {8{b[1]}}, {8{b[0]}}};
  endfunction
  function [31:0] merge32(input [31:0] o, input [31:0] n, input [3:0] b);
    merge32 = (o & ~be_mask(b)) | (n & be_mask(b));
  endfunction
  reg [31:0] ov_d; reg [3:0] ov_be; reg [1:0] idx; reg [3:0] hit;
  integer k, p;
  always @* begin
    ov_d = 32'd0; ov_be = 4'd0;
    for (k = 0; k < 4; k = k + 1) begin
      idx = tail + k[1:0];
      if (k < cnt && v[idx] && a[idx*30 +: 30] == word) begin
        ov_d  = merge32(ov_d, d[idx*32 +: 32], be[idx*4 +: 4]);
        ov_be = ov_be | be[idx*4 +: 4];
      end
    end
    for (p = 0; p < 4; p = p + 1)
      hit[p] = (MUTANT ? 1'b1 : sq_slot_live(tail, cnt, p)) && v[p] && (a[p*30 +: 30] == word);
  end
  wire [35:0] nw = sq_overlay_pick(hit, tail, d, be);
  assign mismatch = (nw[35:32] != ov_be) || (nw[31:0] != ov_d);
endmodule

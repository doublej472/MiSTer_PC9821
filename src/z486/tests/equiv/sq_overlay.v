// l1_cache.sv store-queue forwarding (depth 4): the lookup word (S_LOOKUP) and the fill
// word (S_FILL).
// old: two chains oldest to youngest, each `if (k < count && valid && addr == {line, word})
//      data = merge32(data, store_data, store_be)`, the lookup chain on the request word and
//      the fill chain on the fill beat's word, from their own base words.
// new: one overlay on word = (state == S_FILL) ? fill_count : req_word (the youngest matching
//      store's bytes per lane and the lanes any store covers), applied with one merge32 to
//      either base.
// `in_fill` is the state: the lookup result is compared with the old lookup chain when it is
// low and the fill result with the old fill chain when it is high (each reader acts only in
// its own state). Valid bits, addresses, data, byte enables, count, tail and both bases are
// free. MUTANT=1 matches the overlay on the request word in S_FILL too and must be refuted.
module sq_overlay #(parameter MUTANT = 0)
  (input [3:0] v, input [119:0] a, input [127:0] d, input [15:0] be, input [2:0] cnt,
   input [1:0] tail, input [31:0] look_base, fill_base, input [27:0] line,
   input [1:0] req_word, fill_count, input in_fill, output mismatch);
  function [31:0] be_mask(input [3:0] b);
    be_mask = {{8{b[3]}}, {8{b[2]}}, {8{b[1]}}, {8{b[0]}}};
  endfunction
  function [31:0] merge32(input [31:0] o, input [31:0] n, input [3:0] b);
    merge32 = (o & ~be_mask(b)) | (n & be_mask(b));
  endfunction
  reg [31:0] old_look, old_fill, ov_d;
  reg [3:0]  ov_be;
  reg [1:0]  idx;
  wire [1:0] fwd_word = (in_fill && !MUTANT) ? fill_count : req_word;
  integer k;
  always @* begin
    old_look = look_base; old_fill = fill_base; ov_d = 32'd0; ov_be = 4'd0;
    for (k = 0; k < 4; k = k + 1) begin
      idx = tail + k[1:0];
      if (k < cnt && v[idx] && a[idx*30 +: 30] == {line, req_word})
        old_look = merge32(old_look, d[idx*32 +: 32], be[idx*4 +: 4]);
      if (k < cnt && v[idx] && a[idx*30 +: 30] == {line, fill_count})
        old_fill = merge32(old_fill, d[idx*32 +: 32], be[idx*4 +: 4]);
      if (k < cnt && v[idx] && a[idx*30 +: 30] == {line, fwd_word}) begin
        ov_d  = merge32(ov_d, d[idx*32 +: 32], be[idx*4 +: 4]);
        ov_be = ov_be | be[idx*4 +: 4];
      end
    end
  end
  wire [31:0] new_look = merge32(look_base, ov_d, ov_be);
  wire [31:0] new_fill = merge32(fill_base, ov_d, ov_be);
  assign mismatch = in_fill ? (new_fill != old_fill) : (new_look != old_look);
endmodule

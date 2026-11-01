// l1_icache.sv cpu_line: resp_valid_r ? fill_line : lookup_way_line against the
// form it replaced, lookup_read_hit_now ? lookup_way_line : fill_line, in every
// state where the line is read (cpu_resp_valid = lookup_read_hit_now ||
// resp_valid_r), under the FSM premise that resp_valid_r is never set in
// S_LOOKUP (lookup_read_hit_now implies S_LOOKUP; resp_valid_r is loaded 1
// only on S_FILL edges, which leave S_IDLE or S_FILL; translate_off fuse in
// l1_icache).  z486.sv fuses that the prefetcher consumes the line only in a
// completion cycle.  MUTANT=1 drops the premise and must be refuted.
module icache_line_sel #(parameter MUTANT = 0)
  (input in_lookup, input hit_rest, input resp_valid_r, input [127:0] way_line,
   input [127:0] fill_line, output mismatch);
  wire lookup_read_hit_now = in_lookup && hit_rest;
  wire premise = MUTANT ? 1'b1 : !(resp_valid_r && in_lookup);
  wire cpu_resp_valid = lookup_read_hit_now || resp_valid_r;
  wire [127:0] old_l = lookup_read_hit_now ? way_line : fill_line;
  wire [127:0] new_l = resp_valid_r ? fill_line : way_line;
  assign mismatch = premise && cpu_resp_valid && (old_l != new_l);
endmodule

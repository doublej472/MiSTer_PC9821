// cache_unit.sv g_class_split: the uncached bit of each mem_req arm's routing
// class, dcache_req_cls_m1/_m0[0].
// old: route[1] || (class_r != Z486_CACHE_CACHEABLE)   (CACHEABLE = 2'd0)
// new: route[1] || (|class_r)
// Quartus 17.0 Analysis & Synthesis built the old form, in cache_unit, as
// route[1] || (class_r != Z486_CACHE_NO_ALLOC); MUTANT=1 is that function and
// must be refuted. Every input is free.
module cls_uncached_reduce #(parameter MUTANT = 0)
  (input [1:0] class_r, input vga, output mismatch);
  wire old_unc = vga || (class_r != 2'd0);
  wire new_unc = MUTANT ? (vga || (class_r != 2'd2)) : (vga || (|class_r));
  assign mismatch = old_unc != new_unc;
endmodule

// check-equiv: functions ../../bus_unit.sv route_of
// bus_unit.sv SPLIT (route_of pasted from the RTL) with paging_unit.sv
// dcache_req_route_m1/_m0 and cache_unit.sv dcache_req_cls_m1/_m0 restated,
// as z486.sv wires them (dcache_req_split_sel = mem_req).
// old: ext_direct_req, ext_direct_launch and dcache_req_direct_inval formed
//      from the request as presented: dcache_req_valid / _is_io / _is_inta /
//      _is_vga_mem / _write (paging_unit, through early_present from mem_req)
//      and the class (cache_unit; its own split, proved by req_class_split.v,
//      is taken as the premise class = pre ? c_pre : mem_req ? c_1 : c_0).
// new: route_of on each mem_req arm, mem_req selecting.
// Every input is free (the classes too). MUTANT=1 builds the m0 arm's valid
// with the early write and must be refuted.
module req_route_split #(parameter MUTANT = 0)
  (input s_idle, input mem_servicing, input mem_req, input mem_write, input mem_is_io,
   input idle_mem_crossing, input mem_check_only, input live_store_posts,
   input pretrans_present, input req_mem_present,
   input valid_r, input cand, input io_r, input inta_r, input write_r, input req_is_write,
   input vga_early, input vga_req, input vga_r,
   input [1:0] c_pre, input [1:0] c_1, input [1:0] c_0,
   input x87, input mmio, input drained, input idle, input held, output mismatch);
// @@FUNCTIONS@@
  // ---- old: paging_unit.sv as presented ----
  wire ewid = s_idle && mem_req && !mem_servicing && mem_write && !mem_is_io;
  wire ewp  = ewid && !idle_mem_crossing && !mem_check_only && live_store_posts;
  wire ep   = ewp || pretrans_present;
  wire valid = valid_r || cand || ep;
  wire io    = (ep || req_mem_present) ? 1'b0 : io_r;
  wire inta  = (ep || req_mem_present) ? 1'b0 : inta_r;
  wire vga   = ep ? vga_early : req_mem_present ? vga_req : vga_r;
  wire wr    = pretrans_present ? 1'b0 : ewp ? 1'b1 : req_mem_present ? req_is_write : write_r;
  wire [1:0] cls = pretrans_present ? c_pre : mem_req ? c_1 : c_0;
  wire unc = vga || (cls != 2'd0);
  wire dir = (cls == 2'd1);
  // bus_unit.sv, the request as presented
  wire ddr  = valid && !x87 && (io || inta || unc || mmio);
  wire edr  = ddr && (vga || drained) && idle;
  wire inv  = dir && wr && !io && !inta && !mmio;
  wire [2:0] old_r = {edr, edr && !(held && inv), inv};
  // ---- new: the arms (paging_unit.sv / cache_unit.sv restated) ----
  wire ewp1 = s_idle && !mem_servicing && mem_write && !mem_is_io &&
              !idle_mem_crossing && !mem_check_only && live_store_posts;
  wire ep1  = ewp1 || pretrans_present;
  wire ep0  = (MUTANT ? ewp1 : 1'b0) || pretrans_present;
  wire [4:0] rt1 = {valid_r || cand || ep1, (ep1 || req_mem_present) ? 1'b0 : io_r,
                    (ep1 || req_mem_present) ? 1'b0 : inta_r,
                    ep1 ? vga_early : req_mem_present ? vga_req : vga_r,
                    pretrans_present ? 1'b0 : ewp1 ? 1'b1 : req_mem_present ? req_is_write : write_r};
  wire [4:0] rt0 = {valid_r || cand || ep0, (pretrans_present || req_mem_present) ? 1'b0 : io_r,
                    (pretrans_present || req_mem_present) ? 1'b0 : inta_r,
                    pretrans_present ? vga_early : req_mem_present ? vga_req : vga_r,
                    pretrans_present ? 1'b0 : req_mem_present ? req_is_write : write_r};
  wire [1:0] cr1 = pretrans_present ? c_pre : c_1;
  wire [1:0] cr0 = pretrans_present ? c_pre : c_0;
  wire [1:0] k1 = {cr1 == 2'd1, rt1[1] || (|cr1)};
  wire [1:0] k0 = {cr0 == 2'd1, rt0[1] || (|cr0)};
  wire [2:0] new_r = mem_req ? route_of(rt1, k1, x87, mmio, drained, idle, held)
                             : route_of(rt0, k0, x87, mmio, drained, idle, held);
  assign mismatch = old_r != new_r;
endmodule

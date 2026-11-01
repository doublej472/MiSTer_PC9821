// check-equiv: functions ../../z486_cache_map_pkg.sv z486_addr_in_window z486_window_match z486_classify_phys
// paging_unit.sv dcache_req_phys_addr_m1/_m0, dcache_req_is_io_m1/_m0 and
// cache_unit.sv g_class_split (CLASS_SPLIT=1), as z486.sv wires them
// (dcache_req_split_sel = mem_req).
// old: the request address {dcache_req_frame, dcache_req_offset} and
//      dcache_req_is_io formed from mem_req through idle_data_req ->
//      early_wr_idx_drive/early_wr_present/early_present, A20-masked by
//      (a20_enable || is_io) and classified once (dcache_req_class).
// new: the same expressions with pretrans_present low and mem_req fixed at 1
//      and at 0, plus the pretranslated arm (I/O 0), each arm masked by its own
//      I/O verdict and classified, pretrans_present then mem_req selecting
//      the class.
// Every request input is free, and so are the window enables and classes, the
// runtime no-allocate bound and VGA_PRE_WRAP; the window bounds and A20 masks
// are the PC-98 preset's (z486.sv defaults, z486_pc98_preset.svh). Also
// proved: the arms recombine to the old address and I/O verdict, which with
// class(sel ? a : b) = sel ? class(a) : class(b) carries the result to every
// window list (the cache unit's sim fuse checks the premise every cycle).
// MUTANT=1 drops !mem_is_io from the m1 arm's early-write drive and must be
// refuted.
module req_class_split #(parameter MUTANT = 0)
  (input s_idle, input mem_servicing, input mem_req, input mem_write,
   input mem_is_io, input idle_mem_crossing, input mem_check_only,
   input live_store_posts, input pretrans_present, input req_mem_present,
   input [31:0] pretrans_phys, input [31:0] linear_addr,
   input [31:0] req_mem_phys, input [31:0] req_linear,
   input [31:0] phys_r, input is_io_r, input a20_enable,
   input pre_wrap,
   input vga_en, input [1:0] vga_class, input ap_en, input [1:0] ap_class,
   input al_en, input [1:0] al_class, input w0_en, input [1:0] w0_class,
   input na_en, input [1:0] na_class, input [31:0] na_bound,
   output mismatch);
  localparam [31:0] mask_on  = 32'hffff_ffff, mask_off = 32'hffef_ffff;
  localparam [31:0] vga_base = 32'h000a_0000, vga_top  = 32'h000b_ffff;
  localparam [31:0] ap_base  = 32'h000a_0000, ap_top   = 32'h000f_ffff;
  localparam [31:0] al0_base = 32'h00f0_0000, al0_top  = 32'h00ff_ffff;
  localparam [31:0] al1_base = 32'hfff0_0000, al1_top  = 32'hfff7_ffff;
  localparam [31:0] al2_base = 32'hffff_8000, al2_top  = 32'hffff_ffff;
  localparam [31:0] w0_base  = 32'h0008_0000, w0_top   = 32'h0009_ffff;
  typedef enum logic [1:0] {
      Z486_CACHE_CACHEABLE = 2'd0,
      Z486_CACHE_DIRECT    = 2'd1,
      Z486_CACHE_NO_ALLOC  = 2'd2
  } z486_cache_class_t;
// @@FUNCTIONS@@
  function automatic [1:0] cls(input [31:0] raw, input io);
    logic [31:0] post;
    begin
      post = raw & ((a20_enable || io) ? mask_on : mask_off);
      cls = z486_classify_phys(raw, post, pre_wrap ? raw : post,
                               vga_en, vga_class, vga_base, vga_top,
                               ap_en, ap_class, ap_base, ap_top,
                               al_en, al_class, al0_base, al0_top, al1_base, al1_top,
                               al2_base, al2_top,
                               w0_en, w0_class, w0_base, w0_top,
                               na_en, na_class, na_bound);
    end
  endfunction

  wire [31:0] early_phys = linear_addr;
  // ---- old (paging_unit.sv before the split) ----
  wire idle_data_req      = s_idle && mem_req && !mem_servicing;
  wire early_wr_idx_drive = idle_data_req && mem_write && !mem_is_io;
  wire early_wr_present   = early_wr_idx_drive && !idle_mem_crossing &&
                            !mem_check_only && live_store_posts;
  wire early_idx_drive    = early_wr_idx_drive;
  wire early_present      = early_wr_present || pretrans_present;
  wire [19:0] frame  = pretrans_present ? pretrans_phys[31:12] :
                       early_present    ? early_phys[31:12] :
                       req_mem_present  ? req_mem_phys[31:12] : phys_r[31:12];
  wire [11:0] offset = pretrans_present ? pretrans_phys[11:0] :
                       early_idx_drive  ? linear_addr[11:0] :
                       req_mem_present  ? req_linear[11:0] : phys_r[11:0];
  wire [31:0] raw    = {frame, offset};
  wire        is_io  = (early_present || req_mem_present) ? 1'b0 : is_io_r;
  wire [1:0]  cls_old = cls(raw, is_io);

  // ---- new (the arms, restated from paging_unit.sv) ----
  wire ewid_m1 = s_idle && !mem_servicing && mem_write && (MUTANT ? 1'b1 : !mem_is_io);
  wire ewp_m1  = ewid_m1 && !idle_mem_crossing && !mem_check_only && live_store_posts;
  wire [31:0] m1 = {ewp_m1          ? early_phys[31:12] :
                    req_mem_present ? req_mem_phys[31:12] : phys_r[31:12],
                    ewid_m1         ? linear_addr[11:0] :
                    req_mem_present ? req_linear[11:0] : phys_r[11:0]};
  wire [31:0] m0 = req_mem_present ? {req_mem_phys[31:12], req_linear[11:0]} : phys_r;
  wire io_m1 = (ewp_m1 || req_mem_present) ? 1'b0 : is_io_r;
  wire io_m0 = req_mem_present ? 1'b0 : is_io_r;
  wire [1:0] cls_new = pretrans_present ? cls(pretrans_phys, 1'b0) :
                       mem_req ? cls(m1, io_m1) : cls(m0, io_m0);

  assign mismatch = (cls_new != cls_old) ||
                    ((pretrans_present ? pretrans_phys : mem_req ? m1 : m0) != raw) ||
                    ((pretrans_present ? 1'b0 : mem_req ? io_m1 : io_m0) != is_io);
endmodule

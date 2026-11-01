//
// Memory Unit
// Connects the bus interface unit and the cache unit
//
module memory
    import z486_cache_map_pkg::*;
#(
    parameter PROTECT_UMA_ROM = 0,
    parameter DCACHE_SET_BITS = 7,
    parameter ICACHE_SET_BITS = 7,
    parameter ENABLE_X87 = 0,
    parameter ENABLE_DEVICE_MMIO = 0,
    parameter [31:0] DEVICE_MMIO_MASK = 32'hff00_0000,

    // A20 gate masks, applied closed / open. Default = PC/AT bit-20 clear /
    // unmasked. The PC-98 preset uses the same bit-20 clear (Xe10-measured).
    parameter [31:0] A20_MASK_OFF = 32'hffef_ffff,
    parameter [31:0] A20_MASK_ON  = 32'hffff_ffff,

    // VGA/device A0000-BFFFF template window (VGA_ENABLE gates only this copy).
    parameter        VGA_ENABLE = 0,
    parameter        VGA_PRE_WRAP = 1,
    parameter [1:0]  VGA_CLASS = Z486_CACHE_DIRECT,
    parameter [31:0] VGA_BASE = 32'h000a_0000,
    parameter [31:0] VGA_TOP  = 32'h000b_ffff,

    // Device aperture (PC-98: A0000-FFFFF). Disabled by default.
    parameter        APERTURE_ENABLE = 0,
    parameter [1:0]  APERTURE_CLASS = Z486_CACHE_DIRECT,
    parameter [31:0] APERTURE_BASE = 32'h000a_0000,
    parameter [31:0] APERTURE_TOP  = 32'h000f_ffff,

    // Device-memory aliases (PC-98 mirror/PEGC/fw_high). Disabled by default.
    parameter        ALIAS_ENABLE = 0,
    parameter [1:0]  ALIAS_CLASS = Z486_CACHE_DIRECT,
    parameter [31:0] ALIAS0_BASE = 32'h00f0_0000,
    parameter [31:0] ALIAS0_TOP  = 32'h00ff_ffff,
    parameter [31:0] ALIAS1_BASE = 32'hfff0_0000,
    parameter [31:0] ALIAS1_TOP  = 32'hfff7_ffff,
    parameter [31:0] ALIAS2_BASE = 32'hffff_8000,
    parameter [31:0] ALIAS2_TOP  = 32'hffff_ffff,

    // Window-0 overlay range (PC-98 0x80000-0x9FFFF), enabled only when win0_unmapped.
    parameter        WIN0_ENABLE = 0,
    parameter [1:0]  WIN0_CLASS = Z486_CACHE_NO_ALLOC,
    parameter [31:0] WIN0_BASE = 32'h0008_0000,
    parameter [31:0] WIN0_TOP  = 32'h0009_ffff,

    // No-allocate bound: addresses at or above it never install a line.
    parameter        NO_ALLOC_ENABLE = 0,
    parameter [1:0]  NO_ALLOC_CLASS = Z486_CACHE_NO_ALLOC,
    parameter [31:0] NO_ALLOC_BOUND = 32'h0800_0000,

    // Runtime cacheable-RAM top; with RAM_BOUND_ENABLE the effective bound is
    // min(ram_cache_top, NO_ALLOC_BOUND).
    parameter        RAM_BOUND_ENABLE = 0,

    // Classify the demand request on the paging unit's mem_req arms
    // (cache_unit CLASS_SPLIT); 0 classifies dcache_req_phys_addr_raw directly.
    parameter        CLASS_SPLIT = 0
) (
    input              clk,
    input              reset_n,
    input              a20_enable,
    input              cache_enable,  // Dev menu: L1 caches on
    input              x87_off,       // Dev menu: no coprocessor
    input              device_mmio_enable,
    input      [31:0]  device_mmio_base,
    // Window-0 overlay verdict (0x80000-0x9FFFF target is not RAM); the
    // template's WIN0 window is enabled only while this is asserted.
    input              win0_unmapped,
    // The platform's cacheable-RAM top; only read when RAM_BOUND_ENABLE is set.
    input      [31:0]  ram_cache_top,

    // Paging-unit demand request
    input              dcache_req_valid,
    input      [31:0]  dcache_req_phys_addr_raw,
    // The request on both mem_req arms (read only with CLASS_SPLIT).
    input      [31:0]  dcache_req_phys_addr_m1,
    input      [31:0]  dcache_req_phys_addr_m0,
    input              dcache_req_is_io_m1,
    input              dcache_req_is_io_m0,
    input              dcache_req_split_sel,
    input              dcache_req_pre_sel,
    input      [31:0]  dcache_req_pre_phys,
    input      [4:0]   dcache_req_route_m1,
    input      [4:0]   dcache_req_route_m0,
    input      [11:0]  dcache_req_preread_offset,
    input              dcache_req_preread_priority,
    input              dcache_req_write,
    input       [3:0]  dcache_req_be,
    input      [31:0]  dcache_req_wdata,
    input      [31:0]  dcache_direct_wdata,
    input              dcache_req_is_io,
    input              dcache_req_is_inta,
    input              dcache_req_is_x87,
    input              dcache_req_is_vga_mem,
    input              dcache_req_is_pcd,    // page-level cache disable: a read miss does not allocate
    input              dcache_req_is_locked, // locked read: memory, never the L1
    output             dcache_stores_drained_out, // no posted store remains in the CPU
    // CR0.CD: no line allocates.  CR0.NW: write hits stay in the L1 and
    // external invalidations are ignored (486 cache operating modes).
    input              cache_cd,
    input              cache_nw,
    // LOCK# is asserted: the locked write goes to the bus even under NW=1.
    input              bus_locked,
    output             dcache_req_accepted, // Request ownership transferred
    output             dcache_req_complete, // Read or write operation completed
    output             dcache_read_complete, // Read data is valid this cycle
    output     [31:0]  dcache_rdata,

    // Retained, already-qualified physical store from a microcode fast path.
    // Acceptance transfers irrevocable ownership to the ordinary cache/store
    // queue; the cache may perform its internal enqueue on the following edge.
    input              fast_store_valid,
    input      [31:0]  fast_store_phys_addr_raw,
    input       [3:0]  fast_store_be,
    input      [31:0]  fast_store_wdata,
    output             fast_store_accepted,
    output             dcache_wr_ready,      // the L1 takes a direct store this cycle (registered)

    // Non-owning hardwired-load preread. A miss is retried through the demand
    // request interface above; this port never starts a fill by itself.
    input              dcache_vipt_probe_valid,
    input      [11:0]  dcache_vipt_probe_offset,
    output             dcache_vipt_probe_ready,
    output             dcache_vipt_probe_accepted,
    output             dcache_vipt_probe_direct_accepted,
    input              dcache_vipt_resolve_valid,
    input      [31:0]  dcache_vipt_resolve_phys_addr_raw,
    input      [31:0]  dcache_vipt_resolve_tlb_phys_raw,   // the address's arms and select
    input      [31:0]  dcache_vipt_resolve_alt_phys_raw,   // (data_access), for the tag compare
    input              dcache_vipt_resolve_use_tlb,
    output             dcache_vipt_resolve_hit,
    output     [31:0]  dcache_vipt_resolve_data,

    // x87 data-port response
    output             x87_req_selected,    // Route demand request to x87 port space
    input              x87_req_accepted,
    input              x87_req_complete,
    input              x87_read_complete,
    input      [31:0]  x87_rdata,

    // Paging-unit instruction request
    input              icache_req_valid,
    input      [31:0]  icache_req_phys_addr_raw,
    input              icache_req_is_pcd,
    output             icache_req_is_no_alloc,
    output             icache_req_spec_ok,  // a speculative fetch here reads cacheable RAM
    output             icache_req_accepted, // Prefetch request ownership transferred
    output             icache_req_complete, // Full instruction line is valid
    output     [127:0] icache_rdata,

    // External memory writers invalidate both caches.
    input      [31:0]  snoop_addr,
    input              snoop_valid,          // External writer invalidates this line

    // Native whole-L1 invalidate (486 INVD/WBINVD): the platform's held-level
    // request and the instruction path's request, arbitrated in the cache unit.
    input              cache_flush,
    input              cache_flush_insn,
    output             cache_flush_busy,
    output             cache_flush_done,

    // External memory bus
    output     [31:2]  addr,
    output      [3:0]  be,
    output      [7:0]  burstcount,
    output             line_read,             // Request is one complete cache line
    input      [31:0]  din,
    input      [127:0] line_din,
    output     [31:0]  dout,
    output             valid,                // External request is present
    input              ready,                // External request was accepted
    output             write,
    output             io,
    input              resp_valid,           // External read beat returned
    input              line_resp_valid,      // Complete aligned line returned
    output             inta
);

// CR0.NW=1 disables external invalidation cycles (486 cache operating modes);
// the CPU's own DIRECT-write invalidation of the split I-cache is internal.
wire snoop_valid_eff = snoop_valid && !cache_nw;
// A locked RMW reads memory, never the L1 (dcache_req_is_locked), so its write
// must reach memory too: a write hit kept cache-only under NW=1 would be
// invisible to the next locked read, and a locked sequence on the 486 bus is
// a locked read cycle followed by a locked write cycle.  While LOCK# is
// asserted the L1 therefore writes through (a hit still updates the line).
wire l1_cache_nw = cache_nw && !bus_locked;

wire [31:0] dcache_cpu_dout;
wire dcache_cpu_ready;
wire dcache_cpu_wr_ready;
assign dcache_wr_ready = dcache_cpu_wr_ready;
wire dcache_cpu_resp_valid;
wire [31:0] dcache_mem_addr;
wire [3:0] dcache_mem_be;
wire [7:0] dcache_mem_burstcount;
wire [31:0] dcache_mem_din;
wire dcache_mem_line_resp_valid;
wire dcache_mem_ready;
wire dcache_mem_resp_valid;
wire dcache_mem_valid;
wire dcache_mem_write;
wire dcache_req_is_device_mmio;
wire dcache_req_is_uncached;
wire dcache_req_is_direct;
wire [31:0] dcache_req_phys_addr;
wire dcache_stores_drained;
assign dcache_stores_drained_out = dcache_stores_drained;
wire [31:0] icache_mem_addr;
wire [3:0] icache_mem_be;
wire [7:0] icache_mem_burstcount;
wire icache_mem_line_resp_valid;
wire icache_mem_ready;
wire icache_mem_resp_valid;
wire icache_mem_valid;
wire normal_cache_req;
wire dcache_read_pending;
wire direct_rd_pending;
wire ext_valid_r;
wire icache_read_pending;
wire icache_invalidate_valid;
wire [31:0] icache_invalidate_addr;
wire [1:0] dcache_req_cls_m1, dcache_req_cls_m0;   // the routing class on mem_req's arms
cache_unit #(
    .PROTECT_UMA_ROM(PROTECT_UMA_ROM),
    .DCACHE_SET_BITS(DCACHE_SET_BITS),
    .ICACHE_SET_BITS(ICACHE_SET_BITS),
    .ENABLE_DEVICE_MMIO(ENABLE_DEVICE_MMIO),
    .DEVICE_MMIO_MASK(DEVICE_MMIO_MASK),
    .A20_MASK_OFF(A20_MASK_OFF),
    .A20_MASK_ON(A20_MASK_ON),
    .VGA_ENABLE(VGA_ENABLE),
    .VGA_PRE_WRAP(VGA_PRE_WRAP),
    .VGA_CLASS(VGA_CLASS),
    .VGA_BASE(VGA_BASE),
    .VGA_TOP(VGA_TOP),
    .APERTURE_ENABLE(APERTURE_ENABLE),
    .APERTURE_CLASS(APERTURE_CLASS),
    .APERTURE_BASE(APERTURE_BASE),
    .APERTURE_TOP(APERTURE_TOP),
    .ALIAS_ENABLE(ALIAS_ENABLE),
    .ALIAS_CLASS(ALIAS_CLASS),
    .ALIAS0_BASE(ALIAS0_BASE),
    .ALIAS0_TOP(ALIAS0_TOP),
    .ALIAS1_BASE(ALIAS1_BASE),
    .ALIAS1_TOP(ALIAS1_TOP),
    .ALIAS2_BASE(ALIAS2_BASE),
    .ALIAS2_TOP(ALIAS2_TOP),
    .WIN0_ENABLE(WIN0_ENABLE),
    .WIN0_CLASS(WIN0_CLASS),
    .WIN0_BASE(WIN0_BASE),
    .WIN0_TOP(WIN0_TOP),
    .NO_ALLOC_ENABLE(NO_ALLOC_ENABLE),
    .NO_ALLOC_CLASS(NO_ALLOC_CLASS),
    .NO_ALLOC_BOUND(NO_ALLOC_BOUND),
    .RAM_BOUND_ENABLE(RAM_BOUND_ENABLE),
    .CLASS_SPLIT(CLASS_SPLIT)
) cache_unit_inst (
    // Clock, reset and board configuration
    .clk(clk),
    .reset_n(reset_n),
    .a20_enable(a20_enable),
    .cache_enable(cache_enable),
    .device_mmio_enable(device_mmio_enable),
    .device_mmio_base(device_mmio_base),
    .win0_unmapped(win0_unmapped),
    .ram_cache_top(ram_cache_top),
    // Paging unit: demand data request (physical address, before A20 masking)
    .dcache_req_valid(dcache_req_valid),
    .dcache_req_phys_addr_raw(dcache_req_phys_addr_raw),
    .dcache_req_phys_addr_m1(dcache_req_phys_addr_m1),
    .dcache_req_phys_addr_m0(dcache_req_phys_addr_m0),
    .dcache_req_is_io_m1(dcache_req_is_io_m1),
    .dcache_req_is_io_m0(dcache_req_is_io_m0),
    .dcache_req_split_sel(dcache_req_split_sel),
    .dcache_req_pre_sel(dcache_req_pre_sel),
    .dcache_req_pre_phys(dcache_req_pre_phys),
    .dcache_req_route_m1(dcache_req_route_m1),
    .dcache_req_route_m0(dcache_req_route_m0),
    .dcache_req_cls_m1(dcache_req_cls_m1),
    .dcache_req_cls_m0(dcache_req_cls_m0),
    .dcache_req_preread_offset(dcache_req_preread_offset),
    .dcache_req_preread_priority(dcache_req_preread_priority),
    .dcache_req_write(dcache_req_write),
    .dcache_req_be(dcache_req_be),
    .dcache_req_wdata(dcache_req_wdata),
    .dcache_req_is_io(dcache_req_is_io),
    .dcache_req_is_inta(dcache_req_is_inta),
    .dcache_req_is_vga_mem(dcache_req_is_vga_mem),
    .dcache_req_is_pcd(dcache_req_is_pcd),
    .dcache_req_is_locked(dcache_req_is_locked),
    .cache_cd(cache_cd),
    .cache_nw(l1_cache_nw),
    // Execution core: WR_FAST store and VIPT load/RMW preread
    .fast_store_valid(fast_store_valid),
    .fast_store_phys_addr_raw(fast_store_phys_addr_raw),
    .fast_store_be(fast_store_be),
    .fast_store_wdata(fast_store_wdata),
    .fast_store_accepted(fast_store_accepted),
    .dcache_vipt_probe_valid(dcache_vipt_probe_valid),
    .dcache_vipt_probe_offset(dcache_vipt_probe_offset),
    .dcache_vipt_probe_ready(dcache_vipt_probe_ready),
    .dcache_vipt_probe_accepted(dcache_vipt_probe_accepted),
    .dcache_vipt_probe_direct_accepted(dcache_vipt_probe_direct_accepted),
    .dcache_vipt_resolve_valid(dcache_vipt_resolve_valid),
    .dcache_vipt_resolve_phys_addr_raw(dcache_vipt_resolve_phys_addr_raw),
    .dcache_vipt_resolve_tlb_phys_raw(dcache_vipt_resolve_tlb_phys_raw),
    .dcache_vipt_resolve_alt_phys_raw(dcache_vipt_resolve_alt_phys_raw),
    .dcache_vipt_resolve_use_tlb(dcache_vipt_resolve_use_tlb),
    .dcache_vipt_resolve_hit(dcache_vipt_resolve_hit),
    .dcache_vipt_resolve_data(dcache_vipt_resolve_data),
    // Paging unit: instruction line request (prefetch)
    .icache_req_valid(icache_req_valid),
    .icache_req_phys_addr_raw(icache_req_phys_addr_raw),
    .icache_req_is_pcd(icache_req_is_pcd),
    .icache_req_is_no_alloc(icache_req_is_no_alloc),
    .icache_req_spec_ok(icache_req_spec_ok),
    .icache_req_accepted(icache_req_accepted),
    .icache_req_complete(icache_req_complete),
    .icache_rdata(icache_rdata),
    // Bus interface unit: request routing and D-cache CPU response
    .x87_req_selected(x87_req_selected),
    .normal_cache_req(normal_cache_req),
    .dcache_req_is_device_mmio(dcache_req_is_device_mmio),
    .dcache_req_is_uncached(dcache_req_is_uncached),
    .dcache_req_is_direct(dcache_req_is_direct),
    .dcache_req_phys_addr(dcache_req_phys_addr),
    .dcache_cpu_ready(dcache_cpu_ready),
    .dcache_cpu_wr_ready(dcache_cpu_wr_ready),
    .dcache_cpu_resp_valid(dcache_cpu_resp_valid),
    .dcache_cpu_dout(dcache_cpu_dout),
    .dcache_stores_drained(dcache_stores_drained),
    // Bus interface unit: line fills and write-buffer drain (KBA/KBWR/KBRD)
    .dcache_mem_valid(dcache_mem_valid),
    .dcache_mem_addr(dcache_mem_addr),
    .dcache_mem_write(dcache_mem_write),
    .dcache_mem_be(dcache_mem_be),
    .dcache_mem_burstcount(dcache_mem_burstcount),
    .dcache_mem_din(dcache_mem_din),
    .dcache_mem_ready(dcache_mem_ready),
    .dcache_mem_resp_valid(dcache_mem_resp_valid),
    .dcache_mem_line_resp_valid(dcache_mem_line_resp_valid),
    .icache_mem_valid(icache_mem_valid),
    .icache_mem_addr(icache_mem_addr),
    .icache_mem_be(icache_mem_be),
    .icache_mem_burstcount(icache_mem_burstcount),
    .icache_mem_ready(icache_mem_ready),
    .icache_mem_resp_valid(icache_mem_resp_valid),
    .icache_mem_line_resp_valid(icache_mem_line_resp_valid),
    .ext_valid_r(ext_valid_r),
    .direct_rd_pending(direct_rd_pending),
    .dcache_read_pending(dcache_read_pending),
    .icache_read_pending(icache_read_pending),
    .din(din),
    .line_din(line_din),
    // External coherence (snoop invalidation) and the merged I-cache
    // invalidation from the bus unit.
    .snoop_addr(snoop_addr),
    .snoop_valid(snoop_valid_eff),
    .cache_flush(cache_flush),
    .cache_flush_insn(cache_flush_insn),
    .cache_flush_busy(cache_flush_busy),
    .cache_flush_done(cache_flush_done),
    .icache_invalidate_addr(icache_invalidate_addr),
    .icache_invalidate_valid(icache_invalidate_valid)
);

bus_unit #(.ENABLE_X87(ENABLE_X87), .SPLIT(CLASS_SPLIT)) bus_unit_inst (
    // Clock and reset
    .clk(clk),
    .reset_n(reset_n),
    .x87_off(x87_off),
    // Paging unit: demand request, cycle type and completion
    .dcache_req_valid(dcache_req_valid),
    .dcache_req_write(dcache_req_write),
    .dcache_req_be(dcache_req_be),
    .dcache_direct_wdata(dcache_direct_wdata),
    .dcache_req_is_io(dcache_req_is_io),
    .dcache_req_is_inta(dcache_req_is_inta),
    .dcache_req_is_vga_mem(dcache_req_is_vga_mem),
    .dcache_req_is_x87(dcache_req_is_x87),
    .dcache_req_route_m1(dcache_req_route_m1),
    .dcache_req_route_m0(dcache_req_route_m0),
    .dcache_req_cls_m1(dcache_req_cls_m1),
    .dcache_req_cls_m0(dcache_req_cls_m0),
    .dcache_req_split_sel(dcache_req_split_sel),
    .dcache_req_accepted(dcache_req_accepted),
    .dcache_req_complete(dcache_req_complete),
    .dcache_read_complete(dcache_read_complete),
    .dcache_rdata(dcache_rdata),
    // Execution core: WR_FAST store in flight
    .fast_store_valid(fast_store_valid),
    // FPU: coprocessor data-port cycles
    .x87_req_selected(x87_req_selected),
    .x87_req_accepted(x87_req_accepted),
    .x87_req_complete(x87_req_complete),
    .x87_read_complete(x87_read_complete),
    .x87_rdata(x87_rdata),
    // Cache unit: request routing and D-cache CPU response
    .normal_cache_req(normal_cache_req),
    .dcache_req_is_device_mmio(dcache_req_is_device_mmio),
    .dcache_req_is_uncached(dcache_req_is_uncached),
    .dcache_req_is_direct(dcache_req_is_direct),
    .dcache_req_phys_addr(dcache_req_phys_addr),
    .dcache_cpu_ready(dcache_cpu_ready),
    .dcache_cpu_wr_ready(dcache_cpu_wr_ready),
    .dcache_cpu_resp_valid(dcache_cpu_resp_valid),
    .dcache_cpu_dout(dcache_cpu_dout),
    .dcache_stores_drained(dcache_stores_drained),
    // Cache unit: line fills and write-buffer drain
    .dcache_mem_valid(dcache_mem_valid),
    .dcache_mem_addr(dcache_mem_addr),
    .dcache_mem_write(dcache_mem_write),
    .dcache_mem_be(dcache_mem_be),
    .dcache_mem_burstcount(dcache_mem_burstcount),
    .dcache_mem_din(dcache_mem_din),
    .dcache_mem_ready(dcache_mem_ready),
    .dcache_mem_resp_valid(dcache_mem_resp_valid),
    .dcache_mem_line_resp_valid(dcache_mem_line_resp_valid),
    .icache_mem_valid(icache_mem_valid),
    .icache_mem_addr(icache_mem_addr),
    .icache_mem_be(icache_mem_be),
    .icache_mem_burstcount(icache_mem_burstcount),
    .icache_mem_ready(icache_mem_ready),
    .icache_mem_resp_valid(icache_mem_resp_valid),
    .icache_mem_line_resp_valid(icache_mem_line_resp_valid),
    .ext_valid_r(ext_valid_r),
    .direct_rd_pending(direct_rd_pending),
    .dcache_read_pending(dcache_read_pending),
    .icache_read_pending(icache_read_pending),
    // External bus (XA/XD)
    .valid(valid),
    .ready(ready),
    .addr(addr),
    .be(be),
    .burstcount(burstcount),
    .line_read(line_read),
    .write(write),
    .io(io),
    .inta(inta),
    .dout(dout),
    .din(din),
    .resp_valid(resp_valid),
    .line_resp_valid(line_resp_valid),
    // External coherence (snoop invalidation) and the merged I-cache
    // invalidation forwarded to the cache unit.
    .snoop_addr(snoop_addr),
    .snoop_valid(snoop_valid_eff),
    .icache_invalidate_valid(icache_invalidate_valid),
    .icache_invalidate_addr(icache_invalidate_addr)
);
endmodule

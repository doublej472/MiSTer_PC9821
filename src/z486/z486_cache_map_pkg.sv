// z486 shared memory-map / cache-classification package. Imported by memory.sv,
// paging_unit.sv, paging_tlb.sv, l1_cache.sv and z486.sv; all bounds are
// compile-time scalar parameters.
package z486_cache_map_pkg;

// Per-window cache class. DIRECT is an ordered uncached transaction with no
// D-line installed; NO_ALLOC also answers the I-cache fetch without a line.
typedef enum logic [1:0] {
    Z486_CACHE_CACHEABLE = 2'd0,
    Z486_CACHE_DIRECT    = 2'd1,
    Z486_CACHE_NO_ALLOC  = 2'd2
} z486_cache_class_t;

// Which L1 fill datapaths to build. BOTH is the default; the single-beat
// bypass/direct read (S_BYPASS_WAIT) is separate and always built.
typedef enum logic [1:0] {
    // Per-DWORD burst gather fill (mem_resp_valid) and single-cycle whole-line
    // fill (mem_line_resp_valid) both present.
    Z486_FILL_BOTH = 2'd0,
    // Only the per-DWORD burst fill; mem_line_resp_valid/line_din are ignored.
    Z486_FILL_BEAT = 2'd1,
    // Only the whole-line fill; the per-beat arm inside S_FILL is removed.
    Z486_FILL_LINE = 2'd2
} z486_fill_mode_t;

// Inclusive [base, top] membership on a 32-bit address.
function automatic logic z486_addr_in_window(input logic [31:0] addr,
                                             input logic [31:0] base,
                                             input logic [31:0] top);
    z486_addr_in_window = (addr >= base) && (addr <= top);
endfunction

// A20 view: the mask only clears bits [31:20], so a window inside one 1 MiB
// segment compares [19:0] on the raw address and the segment on the masked one.
function automatic logic z486_window_match(input logic [31:0] addr_raw,
                                           input logic [31:0] addr_post,
                                           input logic [31:0] base,
                                           input logic [31:0] top);
    if (base[31:20] == top[31:20])
        z486_window_match = (addr_raw[19:0] >= base[19:0]) &&
                            (addr_raw[19:0] <= top[19:0]) &&
                            (addr_post[31:20] == base[31:20]);
    else
        z486_window_match = z486_addr_in_window(addr_post, base, top);
endfunction

// Page-base membership for the TLB fill path (pfn<<12 inside the window).
// The default (PC/AT A0000-BFFFF) is special-cased to upstream's compact
// compare: with the window on page-aligned boundaries the two are equivalent
// (tb_memmap_template checks this exhaustively), and the whole expression folds
// back to the original for a default build.  A platform that moves the window
// gets the general form.
function automatic logic z486_page_in_window(input logic [19:0] pfn,
                                             input logic [31:0] base,
                                             input logic [31:0] top);
    if (base == 32'h000a_0000 && top == 32'h000b_ffff)
        z486_page_in_window = (pfn[19:5] == 15'h5);
    else
        z486_page_in_window = z486_addr_in_window({pfn, 12'h000}, base, top);
endfunction

// Classify against the window list; a later window overrides an earlier one.
// vga_addr is raw under the pre-wrap test, else the A20-masked physical.
function automatic z486_cache_class_t z486_classify_phys(
    input logic [31:0] addr_raw,
    input logic [31:0] addr_post,
    input logic [31:0] vga_addr,
    input logic        vga_en,
    input logic [1:0]  vga_class,
    input logic [31:0] vga_base,
    input logic [31:0] vga_top,
    input logic        aperture_en,
    input logic [1:0]  aperture_class,
    input logic [31:0] aperture_base,
    input logic [31:0] aperture_top,
    input logic        alias_en,
    input logic [1:0]  alias_class,
    input logic [31:0] alias0_base,
    input logic [31:0] alias0_top,
    input logic [31:0] alias1_base,
    input logic [31:0] alias1_top,
    input logic [31:0] alias2_base,
    input logic [31:0] alias2_top,
    input logic        win0_en,
    input logic [1:0]  win0_class,
    input logic [31:0] win0_base,
    input logic [31:0] win0_top,
    input logic        no_alloc_en,
    input logic [1:0]  no_alloc_class,
    input logic [31:0] no_alloc_bound
);
    z486_cache_class_t cls;
    cls = Z486_CACHE_CACHEABLE;
    if (vga_en && z486_addr_in_window(vga_addr, vga_base, vga_top))
        cls = z486_cache_class_t'(vga_class);
    if (aperture_en && z486_window_match(addr_raw, addr_post, aperture_base, aperture_top))
        cls = z486_cache_class_t'(aperture_class);
    if (alias_en && (z486_window_match(addr_raw, addr_post, alias0_base, alias0_top) ||
                     z486_window_match(addr_raw, addr_post, alias1_base, alias1_top) ||
                     z486_window_match(addr_raw, addr_post, alias2_base, alias2_top)))
        cls = z486_cache_class_t'(alias_class);
    if (win0_en && z486_window_match(addr_raw, addr_post, win0_base, win0_top))
        cls = z486_cache_class_t'(win0_class);
    if (no_alloc_en && (addr_post >= no_alloc_bound))
        cls = z486_cache_class_t'(no_alloc_class);
    z486_classify_phys = cls;
endfunction

// The posted-store verdict of one 4 KB physical page, a pure function of the
// compile-time template: {P, Wb}.
//   P  = the page classifies CACHEABLE with window 0 closed (its runtime select
//        off) and the no-allocate bound at the parameter NO_ALLOC_BOUND;
//   Wb = the page does NOT classify CACHEABLE with window 0 open.
// A store may post (the direct store port, data_access st_postable) only when
// P && !(Wb && win0_unmapped); outside window 0 Wb == !P, so the runtime select
// reaches only window-0 pages.  The page is classified with addr_raw == addr_post
// (the A20 mask leaves it unchanged; the caller qualifies that at run time), so
// the VGA pre-wrap choice does not matter.  Exact per page only for windows on
// page boundaries: z486.sv turns posting off for a template that is not.
// The runtime RAM top (RAM_BOUND_ENABLE) is deliberately not an input: it only
// keeps lines out of the L1 above the guest's RAM, and a store there reaches
// the platform the same whether it posts or not (no line exists to hit; see
// memory.sv RAM_BOUND_ENABLE).
function automatic logic [1:0] z486_page_post_bits(
    input logic [19:0] pfn,
    input logic        vga_en,
    input logic [1:0]  vga_class,
    input logic [31:0] vga_base,
    input logic [31:0] vga_top,
    input logic        aperture_en,
    input logic [1:0]  aperture_class,
    input logic [31:0] aperture_base,
    input logic [31:0] aperture_top,
    input logic        alias_en,
    input logic [1:0]  alias_class,
    input logic [31:0] alias0_base,
    input logic [31:0] alias0_top,
    input logic [31:0] alias1_base,
    input logic [31:0] alias1_top,
    input logic [31:0] alias2_base,
    input logic [31:0] alias2_top,
    input logic        win0_en,
    input logic [1:0]  win0_class,
    input logic [31:0] win0_base,
    input logic [31:0] win0_top,
    input logic        no_alloc_en,
    input logic [1:0]  no_alloc_class,
    input logic [31:0] no_alloc_bound
);
    logic [31:0] a;
    logic p, wb;
    a = {pfn, 12'h000};
    p = (z486_classify_phys(a, a, a,
            vga_en, vga_class, vga_base, vga_top,
            aperture_en, aperture_class, aperture_base, aperture_top,
            alias_en, alias_class,
            alias0_base, alias0_top, alias1_base, alias1_top, alias2_base, alias2_top,
            1'b0, win0_class, win0_base, win0_top,
            no_alloc_en, no_alloc_class, no_alloc_bound) == Z486_CACHE_CACHEABLE);
    wb = (z486_classify_phys(a, a, a,
            vga_en, vga_class, vga_base, vga_top,
            aperture_en, aperture_class, aperture_base, aperture_top,
            alias_en, alias_class,
            alias0_base, alias0_top, alias1_base, alias1_top, alias2_base, alias2_top,
            win0_en, win0_class, win0_base, win0_top,
            no_alloc_en, no_alloc_class, no_alloc_bound) != Z486_CACHE_CACHEABLE);
    z486_page_post_bits = {p, wb};
endfunction

// A window lies on whole 4 KB pages (or is disabled): the per-page verdict
// above is then exact for every byte of the page.
function automatic logic z486_window_page_aligned(input logic en,
                                                  input logic [31:0] base,
                                                  input logic [31:0] top);
    z486_window_page_aligned = !en || ((base[11:0] == 12'h000) && (top[11:0] == 12'hfff));
endfunction

endpackage

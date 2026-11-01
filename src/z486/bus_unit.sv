//
// Bus Interface Unit
// External bus arbitration, cycle types and response tracking for the caches, I/O and x87
//
module bus_unit
    import z486_pkg::*;
#(
    parameter ENABLE_X87 = 0,
    // Form the direct-launch decision on the paging unit's two mem_req arms
    // (memory.sv CLASS_SPLIT); 0 forms it from the request as presented.
    parameter SPLIT = 0
)
(
    // Clock and reset
    input  logic clk,
    input  logic reset_n,
    input  logic x87_off,               // Dev menu: no coprocessor

    // Paging unit: demand request, cycle type and completion
    input  logic dcache_req_valid,
    input  logic dcache_req_write,
    input  logic [3:0] dcache_req_be,
    input  logic [31:0] dcache_direct_wdata,
    input  logic dcache_req_is_io,
    input  logic dcache_req_is_inta,
    input  logic dcache_req_is_vga_mem,
    input  logic dcache_req_is_x87,
    // The request's routing on both mem_req arms (read only with SPLIT):
    // {valid, is_io, is_inta, is_vga_mem, write} and {is_direct, is_uncached}.
    input  logic [4:0] dcache_req_route_m1,
    input  logic [4:0] dcache_req_route_m0,
    input  logic [1:0] dcache_req_cls_m1,
    input  logic [1:0] dcache_req_cls_m0,
    input  logic dcache_req_split_sel,
    output logic dcache_req_accepted,
    output logic dcache_req_complete,
    output logic dcache_read_complete,
    output logic [31:0] dcache_rdata,

    // Execution core: WR_FAST store in flight
    input  logic fast_store_valid,

    // FPU: coprocessor data-port cycles
    output logic x87_req_selected,
    input  logic x87_req_accepted,
    input  logic x87_req_complete,
    input  logic x87_read_complete,
    input  logic [31:0] x87_rdata,

    // Cache unit: request routing and D-cache CPU response
    input  logic normal_cache_req,
    input  logic dcache_req_is_device_mmio,
    input  logic dcache_req_is_uncached,
    input  logic dcache_req_is_direct,
    input  logic [31:0] dcache_req_phys_addr,
    input  logic dcache_cpu_ready,
    input  logic dcache_cpu_wr_ready,
    input  logic dcache_cpu_resp_valid,
    input  logic [31:0] dcache_cpu_dout,
    input  logic dcache_stores_drained,

    // Cache unit: line fills and write-buffer drain
    input  logic dcache_mem_valid,
    input  logic [31:0] dcache_mem_addr,
    input  logic dcache_mem_write,
    input  logic [3:0] dcache_mem_be,
    input  logic [7:0] dcache_mem_burstcount,
    input  logic [31:0] dcache_mem_din,
    output logic dcache_mem_ready,
    output logic dcache_mem_resp_valid,
    output logic dcache_mem_line_resp_valid,
    input  logic icache_mem_valid,
    input  logic [31:0] icache_mem_addr,
    input  logic [3:0] icache_mem_be,
    input  logic [7:0] icache_mem_burstcount,
    output logic icache_mem_ready,
    output logic icache_mem_resp_valid,
    output logic icache_mem_line_resp_valid,
    output logic ext_valid_r,
    output logic direct_rd_pending,
    output logic dcache_read_pending,
    output logic icache_read_pending,

    // External coherence (snoop invalidation) and the merged I-cache
    // invalidation forwarded to the cache unit.
    input  logic [31:0] snoop_addr,
    input  logic snoop_valid,
    output logic icache_invalidate_valid,
    output logic [31:0] icache_invalidate_addr,

    // External bus (XA/XD)
    output logic valid,
    input  logic ready,
    output logic [31:2] addr,
    output logic [3:0] be,
    output logic [7:0] burstcount,
    output logic line_read,
    output logic write,
    output logic io,
    output logic inta,
    output logic [31:0] dout,
    input  logic [31:0] din,
    input  logic resp_valid,
    input  logic line_resp_valid
);


logic [7:0] dcache_rd_pending;
logic [7:0] icache_rd_pending;
// direct_rd_pending: port

assign x87_req_selected = ENABLE_X87 && !x87_off && dcache_req_valid && dcache_req_is_x87;
// With the x87 off a 486SX has no coprocessor and no coprocessor bus cycles:
// a port cycle that an ESC routine still issues completes here, writes
// dropped and reads all ones.
wire x87_sink = ENABLE_X87 && x87_off && dcache_req_valid && dcache_req_is_x87;

wire dcache_direct_req = dcache_req_valid && !x87_req_selected && !x87_sink &&
                         (dcache_req_is_io || dcache_req_is_inta ||
                          dcache_req_is_uncached ||
                          dcache_req_is_device_mmio);
assign dcache_read_pending = (dcache_rd_pending != 8'd0);
assign icache_read_pending = (icache_rd_pending != 8'd0);
// I/O and INTA transactions must not overtake older posted stores.  This is
// what makes a CPU-filled Sound Blaster buffer visible before the following
// DSP command lets DMA consume it.  VGA memory already bypasses the posted
// queue, so direct VGA accesses remain mutually ordered without draining
// unrelated normal-RAM stores first.
wire direct_req_ordered = dcache_req_is_vga_mem || dcache_stores_drained;
wire ext_direct_req;
wire dcache_req_direct_inval;
wire ext_direct_req_whole = dcache_direct_req && direct_req_ordered &&
                      !direct_rd_pending &&
                      !dcache_read_pending && !icache_read_pending;
// A template DIRECT-window write invalidates its I-cache line in the first
// bus-valid cycle, without feeding external ready into the I-cache/prefetch
// merge.  Only DIRECT (not NO_ALLOC) writes need this: NO_ALLOC never installs
// a line, so there is nothing stale to clear.
wire dcache_req_direct_inval_whole = dcache_req_is_direct && dcache_req_write &&
                               !dcache_req_is_io && !dcache_req_is_inta &&
                               !dcache_req_is_device_mmio;
wire icache_direct_inval_held;
// Hold off the next invalidating direct write while the one-entry slot is
// stranded, so it cannot overwrite the queued address.  Only the launch is
// gated; ext_direct_req still blocks other ext requests, so the store stalls
// rather than being dropped.
wire ext_direct_launch_whole = ext_direct_req_whole &&
                         !(icache_direct_inval_held && dcache_req_direct_inval_whole);
// The same three decisions on each mem_req arm, mem_req (the segment verdict)
// selecting last (Shannon; the x87, device-MMIO and drain terms are taken as
// they are); tests/equiv/req_route_split.v proves the selected arms equal to
// the decisions above.
// x87 / device-MMIO / drain / pending / held terms common to both arms.
wire route_x87  = x87_req_selected || x87_sink;
wire route_idle = !direct_rd_pending && !dcache_read_pending && !icache_read_pending;
function automatic [2:0] route_of(input [4:0] rt, input [1:0] cls, input x87, input mmio,
                                  input drained, input idle, input held);
    logic v, io, inta, vga, wr, dir, unc, ddr, edr, inval;
    begin
        {v, io, inta, vga, wr} = rt;
        {dir, unc} = cls;
        ddr   = v && !x87 && (io || inta || unc || mmio);
        edr   = ddr && (vga || drained) && idle;
        inval = dir && wr && !io && !inta && !mmio;
        route_of = {edr, edr && !(held && inval), inval};
    end
endfunction
wire [2:0] route_r1 = route_of(dcache_req_route_m1, dcache_req_cls_m1, route_x87,
                               dcache_req_is_device_mmio, dcache_stores_drained,
                               route_idle, icache_direct_inval_held);
wire [2:0] route_r0 = route_of(dcache_req_route_m0, dcache_req_cls_m0, route_x87,
                               dcache_req_is_device_mmio, dcache_stores_drained,
                               route_idle, icache_direct_inval_held);
wire [2:0] route_split = dcache_req_split_sel ? route_r1 : route_r0;
assign ext_direct_req          = SPLIT ? route_split[2] : ext_direct_req_whole;
wire   ext_direct_launch       = SPLIT ? route_split[1] : ext_direct_launch_whole;
assign dcache_req_direct_inval = SPLIT ? route_split[0] : dcache_req_direct_inval_whole;
// synthesis translate_off
always @(posedge clk)
    if (reset_n && SPLIT &&
        ({ext_direct_req, ext_direct_launch, dcache_req_direct_inval} !==
         {ext_direct_req_whole, ext_direct_launch_whole, dcache_req_direct_inval_whole}))
        $fatal(1, "bus_unit: the split direct launch %b disagrees with the request's %b",
               {ext_direct_req, ext_direct_launch, dcache_req_direct_inval},
               {ext_direct_req_whole, ext_direct_launch_whole, dcache_req_direct_inval_whole});
// synthesis translate_on
wire ext_dcache_req = dcache_mem_valid && !ext_direct_req &&
                      !direct_rd_pending && !icache_read_pending;
wire ext_icache_req = icache_mem_valid && !ext_direct_req && !ext_dcache_req &&
                      !direct_rd_pending && !dcache_read_pending;

// Instruction-cache coherence for CPU stores into a template DIRECT window: the
// store bypasses the D-cache, so the matching I-cache line must be invalidated
// rather than patched.  A colliding invalidate waits in one pending slot, and
// the next invalidating direct write is held off until it drains.  Inert (and
// folded away) without template windows: dcache_req_is_direct is then 0.
logic        ext_direct_inval_r; // first bus-valid cycle of an invalidating write
logic        icache_direct_inval_pending;
logic [31:0] icache_direct_inval_addr_r;
wire icache_direct_inval = ext_direct_inval_r;
wire [31:0] icache_direct_inval_addr = {ext_addr_r, 2'b00};

// The snoop owns the single-address port, so a queued invalidate is stranded
// for as long as the snoop is asserted.
assign icache_direct_inval_held = icache_direct_inval_pending && snoop_valid;

assign icache_invalidate_valid = snoop_valid || icache_direct_inval_pending ||
                                 icache_direct_inval;
assign icache_invalidate_addr = snoop_valid ? snoop_addr :
                                icache_direct_inval_pending ? icache_direct_inval_addr_r :
                                icache_direct_inval_addr;

// Launch excludes pending reads; ext_valid_r blocks refills until the write is
// accepted. Thus an early invalidate cannot reinstall old data.
always_ff @(posedge clk) begin
    if (!reset_n)
        ext_direct_inval_r <= 1'b0;
    else
        ext_direct_inval_r <= !ext_valid_r && ext_direct_launch &&
                              dcache_req_direct_inval;
end

always_ff @(posedge clk) begin
    if (!reset_n) begin
        icache_direct_inval_pending <= 1'b0;
        icache_direct_inval_addr_r <= 32'h0;
    end else if (icache_direct_inval &&
                 (snoop_valid || icache_direct_inval_pending)) begin
        // Snoop owns the port this cycle: hold this invalidate.
        icache_direct_inval_pending <= 1'b1;
        icache_direct_inval_addr_r <= icache_direct_inval_addr;
    end else if (icache_direct_inval_pending && !snoop_valid) begin
        icache_direct_inval_pending <= 1'b0;
    end
end

// synthesis translate_off
// SIM-ONLY invariants of the DIRECT-window I-cache invalidate: the invalidate is
// presented in the first bus-valid cycle of an exclusive direct write, and a
// queued invalidate is never overwritten before the I-cache consumes it (with
// the snoop low the queued entry is presented that cycle, so replacing it then
// loses nothing).
always @(posedge clk) begin
    if (reset_n && icache_direct_inval &&
        (!ext_valid_r || ext_src_r != EXT_SRC_DIRECT || !ext_write_r ||
         ext_io_r || ext_inta_r || icache_read_pending ||
         dcache_read_pending || direct_rd_pending))
        $fatal(1, "bus_unit: DIRECT invalidate without exclusive write ownership");
    if (reset_n && icache_direct_inval && icache_direct_inval_pending &&
        snoop_valid)
        $fatal(1, "bus_unit: queued direct-write I-cache invalidate %08x overwritten un-consumed by %08x (snoop owns the port)",
               icache_direct_inval_addr_r, icache_direct_inval_addr);
end
// synthesis translate_on

localparam [1:0] EXT_SRC_NONE   = 2'd0;
localparam [1:0] EXT_SRC_DIRECT = 2'd1;
localparam [1:0] EXT_SRC_DCACHE = 2'd2;
localparam [1:0] EXT_SRC_ICACHE = 2'd3;

// ext_valid_r: port
logic [1:0]  ext_src_r;
logic [31:2] ext_addr_r;
logic [3:0]  ext_be_r;
logic [7:0]  ext_burstcount_r;
logic [31:0] ext_direct_dout_r;
logic [31:0] ext_dcache_dout_r;
logic        ext_write_r;
logic        ext_io_r;
logic        ext_inta_r;

wire ext_direct_accept = ext_valid_r && ready && (ext_src_r == EXT_SRC_DIRECT);
wire ext_dcache_accept = ext_valid_r && ready && (ext_src_r == EXT_SRC_DCACHE);
wire ext_icache_accept = ext_valid_r && ready && (ext_src_r == EXT_SRC_ICACHE);
wire direct_rd_resp_now = resp_valid &&
                          (direct_rd_pending || (ext_direct_accept && !ext_write_r));

// The L1 takes a write in more cycles than a read (behind another store's
// lookup), so each request type sees its own registered ready.
wire dcache_req_ready = dcache_req_write ? dcache_cpu_wr_ready : dcache_cpu_ready;
wire normal_req_accepted = normal_cache_req ? (dcache_req_ready && !fast_store_valid)
                                            : ext_direct_accept;
wire normal_req_complete = dcache_cpu_resp_valid ||
                           (normal_cache_req && dcache_req_write &&
                            dcache_cpu_wr_ready && !fast_store_valid) ||
                           direct_rd_resp_now ||
                           (ext_direct_accept && ext_write_r);
wire normal_read_complete = dcache_cpu_resp_valid || direct_rd_resp_now;
wire [31:0] normal_rdata = dcache_cpu_resp_valid ? dcache_cpu_dout : din;

assign dcache_req_accepted = x87_sink || (x87_req_selected ? x87_req_accepted : normal_req_accepted);
assign dcache_req_complete = normal_req_complete || x87_req_complete || x87_sink;
assign dcache_read_complete = normal_read_complete || x87_read_complete ||
                              (x87_sink && !dcache_req_write);
assign dcache_rdata = x87_sink ? 32'hFFFF_FFFF :
                      x87_read_complete ? x87_rdata : normal_rdata;

assign addr       = ext_addr_r;
assign be         = ext_be_r;
assign burstcount = ext_burstcount_r;
assign line_read  = ext_valid_r && !ext_write_r &&
                    (ext_burstcount_r == 8'd4) &&
                    ((ext_src_r == EXT_SRC_DCACHE) ||
                     (ext_src_r == EXT_SRC_ICACHE));
assign dout       = (ext_src_r == EXT_SRC_DIRECT) ? ext_direct_dout_r :
                    (ext_src_r == EXT_SRC_DCACHE) ? ext_dcache_dout_r : 32'd0;
assign valid      = ext_valid_r;
assign write      = ext_valid_r && ext_write_r;
assign io         = ext_valid_r && ext_io_r;
assign inta       = ext_valid_r && ext_inta_r;

assign dcache_mem_ready = ext_dcache_accept;
assign icache_mem_ready = ext_icache_accept;
// Bus contract: a read's response (a beat on resp_valid, or the whole line on
// line_resp_valid) may arrive in the cycle the read is accepted (valid &&
// ready) or in any later cycle; one read is outstanding at a time.  A beat in
// the accept cycle belongs to the read being accepted, as for a DIRECT read.
wire dcache_fill_accept = ext_dcache_accept && !ext_write_r;
wire dcache_resp_window = dcache_read_pending || dcache_fill_accept;
wire icache_resp_window = icache_read_pending || ext_icache_accept;
assign dcache_mem_resp_valid = dcache_resp_window && resp_valid;
assign icache_mem_resp_valid = icache_resp_window && resp_valid;
assign dcache_mem_line_resp_valid = dcache_resp_window && line_resp_valid;
assign icache_mem_line_resp_valid = icache_resp_window && line_resp_valid;

always_ff @(posedge clk) begin
    if (!reset_n) begin
        ext_valid_r <= 1'b0;
        ext_src_r <= EXT_SRC_NONE;
        ext_addr_r <= 30'h0;
        ext_be_r <= 4'h0;
        ext_burstcount_r <= 8'h0;
        ext_direct_dout_r <= 32'h0;
        ext_dcache_dout_r <= 32'h0;
        ext_write_r <= 1'b0;
        ext_io_r <= 1'b0;
        ext_inta_r <= 1'b0;
        dcache_rd_pending <= 8'd0;
        icache_rd_pending <= 8'd0;
        direct_rd_pending <= 1'b0;
    end else begin
        // Data is speculative until ext_src_r selects its registered owner.
        // Capturing both sources unconditionally prevents request arbitration
        // and live translation from becoming clock-enable muxes on dout.
        ext_direct_dout_r <= dcache_direct_wdata;
        ext_dcache_dout_r <= dcache_mem_din;

        if (ext_valid_r) begin
            if (ready) begin
                ext_valid_r <= 1'b0;
                ext_src_r <= EXT_SRC_NONE;
            end
        end else if (ext_direct_launch) begin
            ext_valid_r <= 1'b1;
            ext_src_r <= EXT_SRC_DIRECT;
            ext_addr_r <= dcache_req_phys_addr[31:2];
            ext_be_r <= dcache_req_be;
            ext_burstcount_r <= 8'd1;
            ext_write_r <= dcache_req_write;
            ext_io_r <= dcache_req_is_io;
            ext_inta_r <= dcache_req_is_inta;
        end else if (ext_dcache_req) begin
            ext_valid_r <= 1'b1;
            ext_src_r <= EXT_SRC_DCACHE;
            ext_addr_r <= dcache_mem_addr[31:2];
            ext_be_r <= dcache_mem_be;
            ext_burstcount_r <= dcache_mem_burstcount;
            ext_write_r <= dcache_mem_write;
            ext_io_r <= 1'b0;
            ext_inta_r <= 1'b0;
        end else if (ext_icache_req) begin
            ext_valid_r <= 1'b1;
            ext_src_r <= EXT_SRC_ICACHE;
            ext_addr_r <= icache_mem_addr[31:2];
            ext_be_r <= icache_mem_be;
            ext_burstcount_r <= icache_mem_burstcount;
            ext_write_r <= 1'b0;
            ext_io_r <= 1'b0;
            ext_inta_r <= 1'b0;
        end

        // The accept cycle's own response counts against the new read.
        if (dcache_fill_accept)
            dcache_rd_pending <= line_resp_valid ? 8'd0 :
                                 ext_burstcount_r - {7'd0, resp_valid};
        else if (dcache_read_pending && line_resp_valid)
            dcache_rd_pending <= 8'd0;
        else if (dcache_read_pending && resp_valid)
            dcache_rd_pending <= dcache_rd_pending - 8'd1;

        if (ext_icache_accept)
            icache_rd_pending <= line_resp_valid ? 8'd0 :
                                 ext_burstcount_r - {7'd0, resp_valid};
        else if (icache_read_pending && line_resp_valid)
            icache_rd_pending <= 8'd0;
        else if (icache_read_pending && resp_valid)
            icache_rd_pending <= icache_rd_pending - 8'd1;

        if (ext_direct_accept && !ext_write_r && !resp_valid)
            direct_rd_pending <= 1'b1;
        else if (direct_rd_pending && resp_valid)
            direct_rd_pending <= 1'b0;
    end
end



endmodule

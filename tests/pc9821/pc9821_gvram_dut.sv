// Test harness: the GVRAM's five pieces composed with the port list the unit benches
// already drive (an area pass split pc9821_gvram into pc9821_gvram_mem + pc9821_gvram_arb
// + pc9821_gvram_scan + pc9821_grcg + pc9821_egc). The core instantiates the five in
// pc9821_memory_subsystem; this file exists only so a bench keeps one DUT. TEST-ONLY.
//
// SYS_CLOCK_HZ is the bench's own clock frequency, the input the GVRAM's time-derived
// per-operation costs are converted with (pc9821_gvram_arb's GVRAM_PERIODS); a bench that
// runs this DUT at a clock other than 50 MHz MUST pass it, or the periods are the machine's
// ns at the wrong clock. THE CONTRACT IS MET: every bench here that clocks this harness at
// 10 ns (100 MHz) passes `SYS_CLOCK_HZ(100_000_000)`, and the 20 ns benches (and the
// `pc9821_memory_subsystem` instantiations at 20 ns) take the 50 MHz default, which is their
// own clock. A new bench at any other clock must pass its own frequency.
`default_nettype none

module pc9821_gvram_dut #(
    parameter integer SYS_CLOCK_HZ = 50_000_000
) (
    input wire clk,
    input wire reset,

    input wire        access_page,
    // pc9821_gvram_arb's Xe10 store table (OSD I/O timing = Xe10) and the graphics GDC's fetch
    // window it keys on. A bench that leaves them unconnected runs Fast.
    input wire        timing_xe10,
    input wire        gfx_scan_on,

    input  wire [1:0]   win_plane,
    input  wire [14:0]  win_offset,
    input  wire [31:0]  cpu_din,
    input  wire [3:0]   cpu_be,
    input  wire         cpu_line_read,
    input  wire         cpu_valid,
    input  wire         cpu_write,
    output wire [31:0]  cpu_dout,
    output wire [31:0] cpu_line_word,
    output wire         cpu_ready,
    output wire         cpu_resp_valid,
    output wire         cpu_line_word_valid,

    input wire        grcg_we,
    input wire [7:0]  grcg_addr,
    input wire [7:0]  grcg_din,
    output wire       grcg_expand,

    input wire        egc_gate,
    input wire [15:0] egc_access,
    input wire [15:0] egc_fgbg,
    input wire [15:0] egc_ope,
    input wire [15:0] egc_fg,
    input wire [15:0] egc_mask,
    input wire [15:0] egc_bg,
    input wire [15:0] egc_sft,
    input wire [15:0] egc_leng,
    input wire        egc_shift_we,

    // The graphics GDC's draw-engine visit (the GDC2 WRITE slice) - the same port share
    // pc9821_memory_subsystem wires. Unconnected in the older benches, which leaves
    // gdc_valid low and the CPU side permanently owning the port.
    input  wire        gdc_mem_valid,
    output wire        gdc_mem_ready,
    input  wire        gdc_mem_write,
    input  wire        gdc_mem_route_egc,
    input  wire        gdc_mem_route_grcg,
    input  wire        gdc_mem_page,
    input  wire [1:0]  gdc_mem_plane,
    input  wire [14:0] gdc_mem_offset,
    input  wire [31:0] gdc_mem_din,
    input  wire [3:0]  gdc_mem_be,
    output wire        gdc_mem_resp,
    output wire [31:0] gdc_mem_rdata,

    input  wire        scan_enable,
    input  wire        scan_line_tick,
    input  wire        scan_page,
    input  wire [14:0] scan_line_base,
    input  wire        gfx_odd_line,
    input  wire [6:0]  line_rd_addr,
    input  wire        line_rd_sel,
    output wire [31:0] line_data,
    output wire        line_sel,
    output wire        line_ready,

    output wire [127:0] dbg_gfx_stats,
    output wire         dbg_walk_start,
    output wire         dbg_walk_cycle,
    output wire         dbg_egc_txn,
    output wire         dbg_egc_unit,
    output wire         dbg_grcg_store,
    output wire         dbg_gr_owned,
    output wire         dbg_eg_owned,
    output wire         dbg_access_page,
    output wire         dbg_scan_page_q
);

  wire [15:0] gma_addr;
  wire [31:0] gma_din;
  wire  [3:0] gma_be;
  wire        gma_we, gma_en;
  wire [31:0] gma_dout;
  wire [15:0] gmb_addr;
  wire        gmb_en;
  wire [31:0] gmb_dout;
  wire        grcg_expand_gate, grcg_tcr_gate;
  wire        grcg_cl_valid, grcg_cl_write;
  wire [15:0] grcg_cl_addr;
  wire [31:0] grcg_cl_wdata;
  wire        grcg_cl_cap;
  wire        grcg_cl_cap_rmw;
  wire  [3:0] grcg_cl_hold_be;
  wire        grcg_cl_hold_rmw;
  wire  [3:0] grcg_cl_hold_datum0;
  wire  [3:0] grcg_cl_hold_mergeable;
  wire  [3:0] grcg_cl_wbe, grcg_cl_be;
  wire [31:0] grcg_cl_tile;
  wire        grcg_cl_rmw, grcg_cl_burst;
  wire [63:0] grcg_cl_wdata2;
  wire        grcg_cl_cap_pair_high;
  wire        grcg_cl_cap_burst, grcg_cl_hold_valid, grcg_cl_hold_write, grcg_cl_hold_burst;
  wire [15:0] grcg_cl_cap_addr, grcg_cl_hold_addr;
  wire  [3:0] grcg_cl_cap_wbe, grcg_cl_hold_wbe, grcg_cl_cap_be;
  wire [31:0] grcg_cl_cap_wdata, grcg_cl_hold_wdata;
  wire [63:0] grcg_cl_cap_wdata2, grcg_cl_hold_wdata2;
  wire        grcg_cl_ready, grcg_cl_done;
  wire [31:0] grcg_cpu_dout;
  wire        grcg_cpu_ready, grcg_cpu_resp_valid;
  wire        grcg_dbg_busy, grcg_dbg_rmw, grcg_dbg_write;
  wire        egc_cl_valid, egc_cl_write;
  wire [15:0] egc_cl_addr;
  wire [31:0] egc_cl_wdata;
  wire  [3:0] egc_cl_datum0;
  wire  [3:0] egc_cl_wbe;
  wire        egc_cl_burst;
  wire [63:0] egc_cl_wdata2;
  wire        egc_cl_ready, egc_cl_done;
  wire [31:0] egc_cpu_dout;
  wire        egc_cpu_ready, egc_cpu_resp_valid;
  wire        egc_dbg_busy;
  wire        own_grcg, own_egc;
  wire [31:0] cl_rdata;
  // The CPU-side port share (pc9821_gvram_share), the same seam the core wires in
  // pc9821_memory_subsystem: the arb's CPU route and the two engines' store ports see
  // the CPU or the GDC draw engine, one master at a time.
  wire        gvr_valid, gvr_write, gvr_line_read, gvr_page;
  wire  [1:0] gvr_plane;
  wire [14:0] gvr_offset;
  wire [31:0] gvr_din;
  wire  [3:0] gvr_din_z, gvr_din_f;
  wire  [3:0] gvr_be;
  wire        gvr_gate_egc, gvr_gate_grcg, gvr_gate_tcr;
  wire        gvr_ready, gvr_resp_valid, gvr_line_word_valid;
  wire [31:0] gvr_dout;
  wire [31:0] gvr_line_word;

  pc9821_gvram_mem u_gmem (
      .clk(clk),
      .a_addr(gma_addr), .a_din(gma_din), .a_be(gma_be),
      .a_we(gma_we), .a_en(gma_en), .a_dout(gma_dout),
      .b_addr(gmb_addr), .b_en(gmb_en), .b_dout(gmb_dout)
  );

  pc9821_gvram_share u_gvr_share (
      .clk(clk), .reset(reset),
      .cpu_req(cpu_valid),
      .cpu_write(cpu_write),
      .cpu_line_read(cpu_line_read),
      .cpu_page(access_page),
      .cpu_plane(win_plane),
      .cpu_offset(win_offset),
      .cpu_din(cpu_din),
      .cpu_be(cpu_be),
      .gate_egc(egc_gate),
      .gate_grcg(grcg_expand_gate),
      .gate_tcr(grcg_tcr_gate),
      .cpu_ready(cpu_ready),
      .cpu_resp_valid(cpu_resp_valid),
      .cpu_dout(cpu_dout),
      .cpu_line_word_valid(cpu_line_word_valid),
      .cpu_line_word(cpu_line_word),
      .gdc_valid(gdc_mem_valid),
      .gdc_write(gdc_mem_write),
      .gdc_route_egc(gdc_mem_route_egc),
      .gdc_route_grcg(gdc_mem_route_grcg),
      .gdc_page(gdc_mem_page),
      .gdc_plane(gdc_mem_plane),
      .gdc_offset(gdc_mem_offset),
      .gdc_din(gdc_mem_din),
      .gdc_be(gdc_mem_be),
      .gdc_ready(gdc_mem_ready),
      .gdc_resp_valid(gdc_mem_resp),
      .gdc_rdata(gdc_mem_rdata),
      .gvr_valid(gvr_valid),
      .gvr_write(gvr_write),
      .gvr_line_read(gvr_line_read),
      .gvr_page(gvr_page),
      .gvr_plane(gvr_plane),
      .gvr_offset(gvr_offset),
      .gvr_din(gvr_din), .gvr_din_z(gvr_din_z), .gvr_din_f(gvr_din_f),
      .gvr_be(gvr_be),
      .gvr_gate_egc(gvr_gate_egc),
      .gvr_gate_grcg(gvr_gate_grcg),
      .gvr_gate_tcr(gvr_gate_tcr),
      .gvr_ready(gvr_ready),
      .gvr_resp_valid(gvr_resp_valid),
      .gvr_dout(gvr_dout),
      .gvr_line_word_valid(gvr_line_word_valid),
      .gvr_line_word(gvr_line_word)
  );

  pc9821_gvram_arb #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) u_arb (
      .clk(clk), .reset(reset),
      .timing_xe10(timing_xe10), .gfx_scan_on(gfx_scan_on),
      .access_page(gvr_page),
      .win_plane(gvr_plane), .win_offset(gvr_offset),
      .cpu_din(gvr_din), .cpu_din_z(gvr_din_z), .cpu_din_f(gvr_din_f),
      .cpu_be(gvr_be), .cpu_line_read(gvr_line_read),
      .cpu_valid(gvr_valid), .cpu_write(gvr_write),
      .cpu_dout(gvr_dout), .cpu_line_word(gvr_line_word),
      .cpu_ready(gvr_ready), .cpu_resp_valid(gvr_resp_valid),
      .cpu_line_word_valid(gvr_line_word_valid),
      .grcg_expand_gate(gvr_gate_grcg), .grcg_tcr_gate(gvr_gate_tcr),
      .egc_gate(gvr_gate_egc),
      .grcg_cl_cap(grcg_cl_cap), .grcg_cl_cap_rmw(grcg_cl_cap_rmw),
      .grcg_cl_cap_burst(grcg_cl_cap_burst), .grcg_cl_cap_pair_high(grcg_cl_cap_pair_high), .grcg_cl_cap_addr(grcg_cl_cap_addr),
      .grcg_cl_cap_wbe(grcg_cl_cap_wbe), .grcg_cl_cap_wdata(grcg_cl_cap_wdata),
      .grcg_cl_cap_wdata2(grcg_cl_cap_wdata2), .grcg_cl_cap_be(grcg_cl_cap_be),
      .grcg_cl_hold_valid(grcg_cl_hold_valid), .grcg_cl_hold_write(grcg_cl_hold_write),
      .grcg_cl_hold_burst(grcg_cl_hold_burst), .grcg_cl_hold_addr(grcg_cl_hold_addr),
      .grcg_cl_hold_wbe(grcg_cl_hold_wbe), .grcg_cl_hold_wdata(grcg_cl_hold_wdata),
      .grcg_cl_hold_wdata2(grcg_cl_hold_wdata2),
      .grcg_cl_hold_be(grcg_cl_hold_be), .grcg_cl_hold_rmw(grcg_cl_hold_rmw),
      .grcg_cl_hold_datum0(grcg_cl_hold_datum0),
      .grcg_cl_hold_mergeable(grcg_cl_hold_mergeable),
      .grcg_cl_tile(grcg_cl_tile),
      .grcg_cl_ready(grcg_cl_ready),
      .grcg_cpu_dout(grcg_cpu_dout), .grcg_cpu_ready(grcg_cpu_ready),
      .grcg_cpu_resp_valid(grcg_cpu_resp_valid),
      .grcg_dbg_busy(grcg_dbg_busy), .grcg_dbg_rmw(grcg_dbg_rmw),
      .grcg_dbg_write(grcg_dbg_write),
      .egc_cl_valid(egc_cl_valid), .egc_cl_write(egc_cl_write),
      .egc_cl_addr(egc_cl_addr), .egc_cl_wdata(egc_cl_wdata),
      .egc_cl_datum0(egc_cl_datum0),
      .egc_cl_wbe(egc_cl_wbe), .egc_cl_burst(egc_cl_burst),
      .egc_cl_wdata2(egc_cl_wdata2), .egc_cl_ready(egc_cl_ready),
      .egc_cpu_dout(egc_cpu_dout), .egc_cpu_ready(egc_cpu_ready),
      .egc_cpu_resp_valid(egc_cpu_resp_valid), .egc_dbg_busy(egc_dbg_busy),
      .own_grcg(own_grcg), .own_egc(own_egc),
      .cl_rdata(cl_rdata),
      .grcg_cl_done(grcg_cl_done), .egc_cl_done(egc_cl_done),
      .gma_addr(gma_addr), .gma_din(gma_din), .gma_be(gma_be),
      .gma_we(gma_we), .gma_en(gma_en), .gma_dout(gma_dout),
      .dbg_gfx_stats(dbg_gfx_stats),
      .dbg_walk_start(dbg_walk_start), .dbg_walk_cycle(dbg_walk_cycle),
      .dbg_gr_owned(dbg_gr_owned), .dbg_eg_owned(dbg_eg_owned),
      .dbg_access_page(dbg_access_page)
  );

  pc9821_gvram_scan u_scan (
      .clk(clk), .reset(reset),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .gfx_odd_line(gfx_odd_line),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready),
      .scan_page_q(dbg_scan_page_q),
      .gmb_addr(gmb_addr), .gmb_en(gmb_en), .gmb_dout(gmb_dout)
  );

  pc9821_grcg u_grcg (
      .clk(clk), .reset(reset),
      .port_we(grcg_we), .port_addr(grcg_addr), .port_din(grcg_din),
      .expand_gate(grcg_expand_gate), .tcr_gate(grcg_tcr_gate),
      .cpu_valid(gvr_valid && own_grcg),
      .cpu_write(gvr_write), .cpu_addr({gvr_page, gvr_offset}),
      .cpu_din(gvr_din), .cpu_din_z(gvr_din_z), .cpu_din_f(gvr_din_f), .cpu_be(gvr_be),
      .cpu_dout(grcg_cpu_dout), .cpu_ready(grcg_cpu_ready),
      .cpu_resp_valid(grcg_cpu_resp_valid),
      .cl_valid(grcg_cl_valid), .cl_ready(grcg_cl_ready),
      .cl_write(grcg_cl_write), .cl_addr(grcg_cl_addr),
      .cl_wdata(grcg_cl_wdata), .cl_wbe(grcg_cl_wbe), .cl_be(grcg_cl_be),
      .cl_tile(grcg_cl_tile), .cl_rmw(grcg_cl_rmw), .cl_cap(grcg_cl_cap),
      .cl_cap_rmw(grcg_cl_cap_rmw), .cl_hold_be(grcg_cl_hold_be),
      .cl_hold_rmw(grcg_cl_hold_rmw), .cl_hold_datum0(grcg_cl_hold_datum0),
      .cl_hold_mergeable(grcg_cl_hold_mergeable),
      .cl_burst(grcg_cl_burst), .cl_wdata2(grcg_cl_wdata2),
      .cl_cap_burst(grcg_cl_cap_burst), .cl_cap_pair_high(grcg_cl_cap_pair_high), .cl_cap_addr(grcg_cl_cap_addr),
      .cl_cap_wbe(grcg_cl_cap_wbe), .cl_cap_wdata(grcg_cl_cap_wdata),
      .cl_cap_wdata2(grcg_cl_cap_wdata2), .cl_cap_be(grcg_cl_cap_be),
      .cl_hold_valid(grcg_cl_hold_valid), .cl_hold_write(grcg_cl_hold_write),
      .cl_hold_burst(grcg_cl_hold_burst), .cl_hold_addr(grcg_cl_hold_addr),
      .cl_hold_wbe(grcg_cl_hold_wbe), .cl_hold_wdata(grcg_cl_hold_wdata),
      .cl_hold_wdata2(grcg_cl_hold_wdata2),
      .cl_rdata(cl_rdata), .cl_done(grcg_cl_done),
      .dbg_busy(grcg_dbg_busy), .dbg_rmw(grcg_dbg_rmw), .dbg_write(grcg_dbg_write),
      .dbg_grcg_store(dbg_grcg_store)
  );

  pc9821_egc u_egc (
      .clk(clk), .reset(reset),
      .reg_access(egc_access), .reg_fgbg(egc_fgbg), .reg_ope(egc_ope),
      .reg_fg(egc_fg), .reg_mask(egc_mask), .reg_bg(egc_bg),
      .reg_sft(egc_sft), .reg_leng(egc_leng), .reg_shift_we(egc_shift_we),
      .cpu_page(gvr_page), .cpu_plane(gvr_plane),
      .cpu_offset(gvr_offset), .cpu_din(gvr_din), .cpu_be(gvr_be),
      .cpu_write(gvr_write),
      .cpu_valid(gvr_valid && own_egc),
      .cpu_dout(egc_cpu_dout), .cpu_ready(egc_cpu_ready),
      .cpu_resp_valid(egc_cpu_resp_valid),
      .cl_valid(egc_cl_valid), .cl_ready(egc_cl_ready),
      .cl_write(egc_cl_write), .cl_addr(egc_cl_addr),
      .cl_wdata(egc_cl_wdata), .cl_datum0(egc_cl_datum0), .cl_wbe(egc_cl_wbe),
      .cl_burst(egc_cl_burst), .cl_wdata2(egc_cl_wdata2),
      .cl_rdata(cl_rdata), .cl_done(egc_cl_done),
      .dbg_busy(egc_dbg_busy),
      .dbg_egc_txn(dbg_egc_txn), .dbg_egc_unit(dbg_egc_unit)
  );

  assign grcg_expand = grcg_expand_gate;

endmodule

`default_nettype wire

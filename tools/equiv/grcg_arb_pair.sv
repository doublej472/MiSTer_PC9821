// tools/check_seq_equiv.py --pair: the GRCG + GVRAM arbiter pair, wired as pc9821_memory_subsystem
// wires them (the GRCG's cpu_valid is the share's request AND the arbiter's own_grcg; both read
// the share's gvr_* view), with every other input free. The tool instantiates this text twice:
// once with the earlier revision's modules (PAIR_OLD: the arbiter reads the GRCG's muxed cl_*),
// once with the working tree's (the arbiter reads the GRCG's two raw arms), renamed so both
// designs load together, and proves the two wrappers equal on every output and register.
// `PAIR_MOD`, `GRCG_MOD` and `ARB_MOD` are substituted by the tool; this file is never compiled
// on its own.
module PAIR_MOD (
    input  wire        clk,
    input  wire        reset,
    input  wire        port_we,
    input  wire  [7:0] port_addr,
    input  wire  [7:0] port_din,
    input  wire        gvr_page,
    input  wire  [1:0] gvr_plane,
    input  wire [14:0] gvr_offset,
    input  wire [31:0] gvr_din,
    input  wire  [3:0] gvr_be,
    input  wire        gvr_line_read,
    input  wire        gvr_valid,
    input  wire        gvr_write,
    input  wire        gate_grcg_sel,   // the share's gvr_gate_grcg / gvr_gate_tcr / gvr_gate_egc
    input  wire        gate_tcr_sel,
    input  wire        gate_egc,
    input  wire        egc_cl_valid,
    input  wire        egc_cl_write,
    input  wire [15:0] egc_cl_addr,
    input  wire [31:0] egc_cl_wdata,
    input  wire  [3:0] egc_cl_datum0,
    input  wire  [3:0] egc_cl_wbe,
    input  wire        egc_cl_burst,
    input  wire [63:0] egc_cl_wdata2,
    input  wire [31:0] egc_cpu_dout,
    input  wire        egc_cpu_ready,
    input  wire        egc_cpu_resp_valid,
    input  wire        egc_dbg_busy,
    input  wire [31:0] gma_dout,
    output wire        expand_gate,
    output wire        tcr_gate,
    output wire [31:0] cpu_dout,
    output wire        cpu_ready,
    output wire        cpu_resp_valid,
    output wire        egc_cl_ready,
    output wire        egc_cl_done,
    output wire        own_egc,
    output wire [31:0] cl_rdata,
    output wire [15:0] gma_addr,
    output wire [31:0] gma_din,
    output wire  [3:0] gma_be,
    output wire        gma_we,
    output wire        gma_en,
    output wire [127:0] dbg_gfx_stats,
    output wire        dbg_walk_start,
    output wire        dbg_walk_cycle,
    output wire        dbg_gr_owned,
    output wire        dbg_eg_owned,
    output wire        dbg_pw_owned,
    output wire        dbg_access_page,
    output wire        g_dbg_busy,
    output wire        g_dbg_rmw,
    output wire        g_dbg_write,
    output wire        g_dbg_store,
    output wire        g_cpu_ready,
    output wire        g_cpu_resp_valid,
    output wire [31:0] g_cpu_dout
);
  // P3 (0b658493) replaced the arbiter's 128-bit line response (cpu_line_dout / cpu_line_resp_valid)
  // by a 32-bit word beat (cpu_line_word / cpu_line_word_valid) and moved a line read's accept to the
  // walk's start. That is a deliberate change of the PLAIN line-read path, so a revision before it
  // cannot be equal on it. The proof is scoped to accesses that are not line reads: cpu_line_read is
  // tied 0 on both sides (a line read never reaches the GRCG or the EGC: cc_owns_*_comb exclude it),
  // and the line response ports are internal, unobserved wires. The line path is held by the
  // window/line benches, not by this proof.
  wire [127:0] ln_dout_unused;       /*LD*/
  wire         ln_valid_unused;      /*LD*/
  wire  [31:0] ln_word_unused;       /*LW*/
  wire         ln_wvalid_unused;     /*LW*/
  wire        own_grcg;
  wire        grcg_cl_valid, grcg_cl_write, grcg_cl_cap, grcg_cl_cap_rmw, grcg_cl_hold_rmw;
  wire        grcg_cl_rmw, grcg_cl_burst, grcg_cl_ready, grcg_cl_done;
  wire [15:0] grcg_cl_addr;
  wire [31:0] grcg_cl_wdata, grcg_cl_tile;
  wire  [3:0] grcg_cl_wbe, grcg_cl_be, grcg_cl_hold_be, grcg_cl_hold_datum0, grcg_cl_hold_mergeable;
  wire [63:0] grcg_cl_wdata2;
  // Port A as pc9821_gvram_mem observes it (the C7-dc cut): the address under a_en, the data and
  // byte enables under a_en && a_we. That the memory reads no more than this is proven by
  // check_seq_equiv.py's gvram_mem lemma (two copies of the real module, the unobserved parts free).
  wire [15:0] gma_addr_raw;
  wire [31:0] gma_din_raw;
  wire  [3:0] gma_be_raw;
  assign gma_addr = gma_en ? gma_addr_raw : 16'd0;
  assign gma_din  = (gma_en && gma_we) ? gma_din_raw : 32'd0;
  assign gma_be   = (gma_en && gma_we) ? gma_be_raw : 4'd0;
  wire  [3:0] gvr_din_z = {(gvr_din[31:24] == 8'h00), (gvr_din[23:16] == 8'h00), (gvr_din[15:8] == 8'h00), (gvr_din[7:0] == 8'h00)}; /*DZ*/
  wire  [3:0] gvr_din_f = {(gvr_din[31:24] == 8'hFF), (gvr_din[23:16] == 8'hFF), (gvr_din[15:8] == 8'hFF), (gvr_din[7:0] == 8'hFF)}; /*DZ*/
`ifndef PAIR_OLD
  wire        grcg_cl_cap_burst, grcg_cl_hold_valid, grcg_cl_hold_write, grcg_cl_hold_burst;
  wire [15:0] grcg_cl_cap_addr, grcg_cl_hold_addr;
  wire  [3:0] grcg_cl_cap_wbe, grcg_cl_hold_wbe, grcg_cl_cap_be;
  wire [31:0] grcg_cl_cap_wdata, grcg_cl_hold_wdata;
  wire [63:0] grcg_cl_cap_wdata2, grcg_cl_hold_wdata2;
  wire        grcg_cl_cap_pair_high; /*PH*/
`endif

  GRCG_MOD u_grcg (
      .clk(clk), .reset(reset),
      .port_we(port_we), .port_addr(port_addr), .port_din(port_din),
      .expand_gate(expand_gate), .tcr_gate(tcr_gate),
      .cpu_valid(gvr_valid && own_grcg),
      .cpu_write(gvr_write), .cpu_addr({gvr_page, gvr_offset}),
      .cpu_din(gvr_din), .cpu_be(gvr_be),
      .cpu_din_z(gvr_din_z), .cpu_din_f(gvr_din_f), /*DZ*/
      .cpu_dout(g_cpu_dout), .cpu_ready(g_cpu_ready), .cpu_resp_valid(g_cpu_resp_valid),
      .cl_valid(grcg_cl_valid), .cl_ready(grcg_cl_ready),
      .cl_write(grcg_cl_write), .cl_addr(grcg_cl_addr),
      .cl_wdata(grcg_cl_wdata), .cl_wbe(grcg_cl_wbe), .cl_be(grcg_cl_be),
      .cl_tile(grcg_cl_tile), .cl_rmw(grcg_cl_rmw), .cl_cap(grcg_cl_cap),
      .cl_cap_rmw(grcg_cl_cap_rmw), .cl_hold_be(grcg_cl_hold_be),
      .cl_hold_rmw(grcg_cl_hold_rmw), .cl_hold_datum0(grcg_cl_hold_datum0),
      .cl_hold_mergeable(grcg_cl_hold_mergeable),
      .cl_burst(grcg_cl_burst), .cl_wdata2(grcg_cl_wdata2),
`ifndef PAIR_OLD
      .cl_cap_pair_high(grcg_cl_cap_pair_high), /*PH*/
      .cl_cap_burst(grcg_cl_cap_burst), .cl_cap_addr(grcg_cl_cap_addr),
      .cl_cap_wbe(grcg_cl_cap_wbe), .cl_cap_wdata(grcg_cl_cap_wdata),
      .cl_cap_wdata2(grcg_cl_cap_wdata2), .cl_cap_be(grcg_cl_cap_be),
      .cl_hold_valid(grcg_cl_hold_valid), .cl_hold_write(grcg_cl_hold_write),
      .cl_hold_burst(grcg_cl_hold_burst), .cl_hold_addr(grcg_cl_hold_addr),
      .cl_hold_wbe(grcg_cl_hold_wbe), .cl_hold_wdata(grcg_cl_hold_wdata),
      .cl_hold_wdata2(grcg_cl_hold_wdata2),
`endif
      .cl_rdata(cl_rdata), .cl_done(grcg_cl_done),
      .dbg_busy(g_dbg_busy), .dbg_rmw(g_dbg_rmw), .dbg_write(g_dbg_write),
      .dbg_grcg_store(g_dbg_store));

  ARB_MOD #(.SYS_CLOCK_HZ(80_000_000)) u_arb (
      .clk(clk), .reset(reset),
      .access_page(gvr_page), .win_plane(gvr_plane), .win_offset(gvr_offset),
      .cpu_din(gvr_din), .cpu_be(gvr_be), .cpu_line_read(1'b0),
      .cpu_din_z(gvr_din_z), .cpu_din_f(gvr_din_f), /*DZ*/
      .cpu_valid(gvr_valid), .cpu_write(gvr_write),
      .cpu_dout(cpu_dout),
      .cpu_line_dout(ln_dout_unused), /*LD*/
      .cpu_line_word(ln_word_unused), /*LW*/
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_resp_valid(ln_valid_unused), /*LD*/
      .cpu_line_word_valid(ln_wvalid_unused), /*LW*/
      .grcg_expand_gate(gate_grcg_sel), .grcg_tcr_gate(gate_tcr_sel), .egc_gate(gate_egc),
`ifdef PAIR_OLD
      .grcg_cl_valid(grcg_cl_valid), .grcg_cl_write(grcg_cl_write),
      .grcg_cl_addr(grcg_cl_addr), .grcg_cl_be(grcg_cl_be),
      .grcg_cl_wdata(grcg_cl_wdata), .grcg_cl_wbe(grcg_cl_wbe),
      .grcg_cl_rmw(grcg_cl_rmw), .grcg_cl_burst(grcg_cl_burst),
      .grcg_cl_wdata2(grcg_cl_wdata2),
`else
      .grcg_cl_cap_pair_high(grcg_cl_cap_pair_high), /*PH*/
      .grcg_cl_cap_burst(grcg_cl_cap_burst), .grcg_cl_cap_addr(grcg_cl_cap_addr),
      .grcg_cl_cap_wbe(grcg_cl_cap_wbe), .grcg_cl_cap_wdata(grcg_cl_cap_wdata),
      .grcg_cl_cap_wdata2(grcg_cl_cap_wdata2), .grcg_cl_cap_be(grcg_cl_cap_be),
      .grcg_cl_hold_valid(grcg_cl_hold_valid), .grcg_cl_hold_write(grcg_cl_hold_write),
      .grcg_cl_hold_burst(grcg_cl_hold_burst), .grcg_cl_hold_addr(grcg_cl_hold_addr),
      .grcg_cl_hold_wbe(grcg_cl_hold_wbe), .grcg_cl_hold_wdata(grcg_cl_hold_wdata),
      .grcg_cl_hold_wdata2(grcg_cl_hold_wdata2),
`endif
      .grcg_cl_cap(grcg_cl_cap), .grcg_cl_cap_rmw(grcg_cl_cap_rmw),
      .grcg_cl_hold_be(grcg_cl_hold_be), .grcg_cl_hold_rmw(grcg_cl_hold_rmw),
      .grcg_cl_hold_datum0(grcg_cl_hold_datum0),
      .grcg_cl_hold_mergeable(grcg_cl_hold_mergeable),
      .grcg_cl_tile(grcg_cl_tile),
      .grcg_cl_ready(grcg_cl_ready),
      .grcg_cpu_dout(g_cpu_dout), .grcg_cpu_ready(g_cpu_ready),
      .grcg_cpu_resp_valid(g_cpu_resp_valid),
      .grcg_dbg_busy(g_dbg_busy), .grcg_dbg_rmw(g_dbg_rmw), .grcg_dbg_write(g_dbg_write),
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
      .gma_addr(gma_addr_raw), .gma_din(gma_din_raw), .gma_be(gma_be_raw),
      .gma_we(gma_we), .gma_en(gma_en), .gma_dout(gma_dout),
      .dbg_gfx_stats(dbg_gfx_stats),
      .dbg_walk_start(dbg_walk_start), .dbg_walk_cycle(dbg_walk_cycle),
      .dbg_gr_owned(dbg_gr_owned), .dbg_eg_owned(dbg_eg_owned),
      .dbg_pw_owned(dbg_pw_owned),
      .dbg_access_page(dbg_access_page));
endmodule

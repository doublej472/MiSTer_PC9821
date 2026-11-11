`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The GVRAM arbiter's WORD path is cycle-for-cycle identical to the pre-rewrite module (pc9821_gvram_arb_ref.sv, the module as of 3b134fe4): over several hundred thousand cycles of random single reads, byte-enable walks and stores on random planes, pages and offsets against a synchronous GVRAM model, every arbiter output (cpu_ready, cpu_resp_valid, cpu_dout, the GVRAM port as pc9821_gvram_mem reads it (en and we, the address under en, the datum and byte enables under en && we), the client dones and the telemetry strobes) matches on every cycle. LINE READS ARE DELIBERATELY OUT OF THIS STIMULUS: P3 moved a line read's accept to the walk's start so its beats stream through the walk (a shorter fill, not an equal one), so a cycle-for-cycle line comparison no longer exists; the line path's bytes are pinned against the GVRAM model by tb_pc9821_gvram_coherence and its four-beat form and streaming cadence by tb_pc9821_fill_beat_uniform.
//
// ==== DUT ====
// pc9821_gvram_arb vs pc9821_gvram_arb_ref, same inputs, the GRCG and EGC clients idle (their gates
// low, so every access takes the plain path this rewrite touches). The reference is the pre-change
// text, not a model of the hardware: the arbiter's behaviour itself is pinned by
// tb_pc9821_gvram_rw and tb_pc9821_cpu_line_burst.

module tb_pc9821_gvram_arb_equiv;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  reg        access_page = 0, cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  reg  [1:0] win_plane = 0;
  reg [14:0] win_offset = 0;
  reg [31:0] cpu_din = 0;
  reg  [3:0] cpu_be = 4'hF;
  reg [31:0] gma_dout = 0;

  wire [31:0] d_cpu_dout;
  wire [31:0] r_cpu_dout;
  wire [31:0] d_cpu_line_word;
  wire [127:0] r_cpu_line_dout;
  wire  d_cpu_ready;
  wire  r_cpu_ready;
  wire  d_cpu_resp_valid;
  wire  r_cpu_resp_valid;
  wire  d_cpu_line_word_valid;
  wire  r_cpu_line_resp_valid;
  wire  d_grcg_cl_ready;
  wire  r_grcg_cl_ready;
  wire  d_egc_cl_ready;
  wire  r_egc_cl_ready;
  wire  d_own_grcg;
  wire  r_own_grcg;
  wire  d_own_egc;
  wire  r_own_egc;
  wire [31:0] d_cl_rdata;
  wire [31:0] r_cl_rdata;
  wire  d_grcg_cl_done;
  wire  r_grcg_cl_done;
  wire  d_egc_cl_done;
  wire  r_egc_cl_done;
  wire [15:0] d_gma_addr;
  wire [15:0] r_gma_addr;
  wire [31:0] d_gma_din;
  wire [31:0] r_gma_din;
  wire [3:0] d_gma_be;
  wire [3:0] r_gma_be;
  wire  d_gma_we;
  wire  r_gma_we;
  wire  d_gma_en;
  wire  r_gma_en;
  wire [127:0] d_dbg_gfx_stats;
  wire [127:0] r_dbg_gfx_stats;
  wire  d_dbg_walk_start;
  wire  r_dbg_walk_start;
  wire  d_dbg_walk_cycle;
  wire  r_dbg_walk_cycle;
  wire  d_dbg_gr_owned;
  wire  r_dbg_gr_owned;
  wire  d_dbg_eg_owned;
  wire  r_dbg_eg_owned;
  wire  d_dbg_pw_owned;
  wire  r_dbg_pw_owned;
  wire  d_dbg_access_page;
  wire  r_dbg_access_page;

  pc9821_gvram_arb dut (
    .clk(clk),
    .timing_xe10(1'b0), .gfx_scan_on(1'b0),   // Fast: the pre-field periods
    .reset(reset),
    .access_page(access_page),
    .win_plane(win_plane),
    .win_offset(win_offset),
    .cpu_din(cpu_din),
    .cpu_din_z({(cpu_din[31:24] == 8'h00), (cpu_din[23:16] == 8'h00), (cpu_din[15:8] == 8'h00), (cpu_din[7:0] == 8'h00)}),
    .cpu_din_f({(cpu_din[31:24] == 8'hFF), (cpu_din[23:16] == 8'hFF), (cpu_din[15:8] == 8'hFF), (cpu_din[7:0] == 8'hFF)}),
    .cpu_be(cpu_be),
    .cpu_line_read(cpu_line_read),
    .cpu_valid(cpu_valid),
    .cpu_write(cpu_write),
    .cpu_dout(d_cpu_dout),
    .cpu_line_word(d_cpu_line_word),
    .cpu_ready(d_cpu_ready),
    .cpu_resp_valid(d_cpu_resp_valid),
    .cpu_line_word_valid(d_cpu_line_word_valid),
    .grcg_expand_gate({{1{1'b0}}}),
    .grcg_tcr_gate({{1{1'b0}}}),
    .egc_gate({{1{1'b0}}}),
    .grcg_cl_cap(1'b0), .grcg_cl_cap_rmw(1'b0), .grcg_cl_cap_burst(1'b0), .grcg_cl_cap_pair_high(1'b0),
    .grcg_cl_cap_addr(16'd0), .grcg_cl_cap_wbe(4'd0), .grcg_cl_cap_wdata(32'd0),
    .grcg_cl_cap_wdata2(64'd0), .grcg_cl_cap_be(4'd0),
    .grcg_cl_hold_valid(1'b0), .grcg_cl_hold_write(1'b0), .grcg_cl_hold_burst(1'b0),
    .grcg_cl_hold_addr(16'd0), .grcg_cl_hold_wbe(4'd0), .grcg_cl_hold_wdata(32'd0),
    .grcg_cl_hold_wdata2(64'd0),
    .grcg_cl_hold_be(4'd0), .grcg_cl_hold_rmw(1'b0), .grcg_cl_hold_datum0(4'd0),
    .grcg_cl_hold_mergeable(4'd0), .grcg_cl_tile(32'd0),
    .grcg_cl_ready(d_grcg_cl_ready),
    .grcg_cpu_dout({{32{1'b0}}}),
    .grcg_cpu_ready({{1{1'b0}}}),
    .grcg_cpu_resp_valid({{1{1'b0}}}),
    .grcg_dbg_busy({{1{1'b0}}}),
    .grcg_dbg_rmw({{1{1'b0}}}),
    .grcg_dbg_write({{1{1'b0}}}),
    .egc_cl_valid({{1{1'b0}}}),
    .egc_cl_write({{1{1'b0}}}),
    .egc_cl_addr({{16{1'b0}}}),
    .egc_cl_wdata({{32{1'b0}}}),
    .egc_cl_datum0({{4{1'b0}}}),
    .egc_cl_wbe({{4{1'b0}}}),
    .egc_cl_burst({{1{1'b0}}}),
    .egc_cl_wdata2({{64{1'b0}}}),
    .egc_cl_ready(d_egc_cl_ready),
    .egc_cpu_dout({{32{1'b0}}}),
    .egc_cpu_ready({{1{1'b0}}}),
    .egc_cpu_resp_valid({{1{1'b0}}}),
    .egc_dbg_busy({{1{1'b0}}}),
    .own_grcg(d_own_grcg),
    .own_egc(d_own_egc),
    .cl_rdata(d_cl_rdata),
    .grcg_cl_done(d_grcg_cl_done),
    .egc_cl_done(d_egc_cl_done),
    .gma_addr(d_gma_addr),
    .gma_din(d_gma_din),
    .gma_be(d_gma_be),
    .gma_we(d_gma_we),
    .gma_en(d_gma_en),
    .gma_dout(gma_dout),
    .dbg_gfx_stats(d_dbg_gfx_stats),
    .dbg_walk_start(d_dbg_walk_start),
    .dbg_walk_cycle(d_dbg_walk_cycle),
    .dbg_gr_owned(d_dbg_gr_owned),
    .dbg_eg_owned(d_dbg_eg_owned),
    .dbg_pw_owned(d_dbg_pw_owned),
    .dbg_access_page(d_dbg_access_page)
  );
  pc9821_gvram_arb_ref ref0 (
    .clk(clk),
    .reset(reset),
    .access_page(access_page),
    .win_plane(win_plane),
    .win_offset(win_offset),
    .cpu_din(cpu_din),
    .cpu_be(cpu_be),
    .cpu_line_read(cpu_line_read),
    .cpu_valid(cpu_valid),
    .cpu_write(cpu_write),
    .cpu_dout(r_cpu_dout),
    .cpu_line_dout(r_cpu_line_dout),
    .cpu_ready(r_cpu_ready),
    .cpu_resp_valid(r_cpu_resp_valid),
    .cpu_line_resp_valid(r_cpu_line_resp_valid),
    .grcg_expand_gate({{1{1'b0}}}),
    .grcg_tcr_gate({{1{1'b0}}}),
    .egc_gate({{1{1'b0}}}),
    .grcg_cl_valid({{1{1'b0}}}),
    .grcg_cl_write({{1{1'b0}}}),
    .grcg_cl_addr({{16{1'b0}}}),
    .grcg_cl_be({{4{1'b0}}}),
    .grcg_cl_wdata({{32{1'b0}}}),
    .grcg_cl_wbe({{4{1'b0}}}),
    .grcg_cl_cap({{1{1'b0}}}),
    .grcg_cl_cap_rmw({{1{1'b0}}}),
    .grcg_cl_hold_be({{4{1'b0}}}),
    .grcg_cl_hold_rmw({{1{1'b0}}}),
    .grcg_cl_hold_datum0({{4{1'b0}}}),
    .grcg_cl_hold_mergeable({{4{1'b0}}}),
    .grcg_cl_tile({{32{1'b0}}}),
    .grcg_cl_rmw({{1{1'b0}}}),
    .grcg_cl_burst({{1{1'b0}}}),
    .grcg_cl_wdata2({{64{1'b0}}}),
    .grcg_cl_ready(r_grcg_cl_ready),
    .grcg_cpu_dout({{32{1'b0}}}),
    .grcg_cpu_ready({{1{1'b0}}}),
    .grcg_cpu_resp_valid({{1{1'b0}}}),
    .grcg_dbg_busy({{1{1'b0}}}),
    .grcg_dbg_rmw({{1{1'b0}}}),
    .grcg_dbg_write({{1{1'b0}}}),
    .egc_cl_valid({{1{1'b0}}}),
    .egc_cl_write({{1{1'b0}}}),
    .egc_cl_addr({{16{1'b0}}}),
    .egc_cl_wdata({{32{1'b0}}}),
    .egc_cl_datum0({{4{1'b0}}}),
    .egc_cl_wbe({{4{1'b0}}}),
    .egc_cl_burst({{1{1'b0}}}),
    .egc_cl_wdata2({{64{1'b0}}}),
    .egc_cl_ready(r_egc_cl_ready),
    .egc_cpu_dout({{32{1'b0}}}),
    .egc_cpu_ready({{1{1'b0}}}),
    .egc_cpu_resp_valid({{1{1'b0}}}),
    .egc_dbg_busy({{1{1'b0}}}),
    .own_grcg(r_own_grcg),
    .own_egc(r_own_egc),
    .cl_rdata(r_cl_rdata),
    .grcg_cl_done(r_grcg_cl_done),
    .egc_cl_done(r_egc_cl_done),
    .gma_addr(r_gma_addr),
    .gma_din(r_gma_din),
    .gma_be(r_gma_be),
    .gma_we(r_gma_we),
    .gma_en(r_gma_en),
    .gma_dout(gma_dout),
    .dbg_gfx_stats(r_dbg_gfx_stats),
    .dbg_walk_start(r_dbg_walk_start),
    .dbg_walk_cycle(r_dbg_walk_cycle),
    .dbg_gr_owned(r_dbg_gr_owned),
    .dbg_eg_owned(r_dbg_eg_owned),
    .dbg_pw_owned(r_dbg_pw_owned),
    .dbg_access_page(r_dbg_access_page)
  );

  // ---- the GVRAM model: a synchronous array, one cycle read latency, byte-enable writes ----
  reg [31:0] gmem [0:1023];
  integer gi;
  initial for (gi = 0; gi < 1024; gi = gi + 1) gmem[gi] = 32'h1357_9BDF * (gi + 1);
  always @(posedge clk) if (d_gma_en) begin
    if (d_gma_we) begin
      if (d_gma_be[0]) gmem[d_gma_addr[9:0]][7:0]   <= d_gma_din[7:0];
      if (d_gma_be[1]) gmem[d_gma_addr[9:0]][15:8]  <= d_gma_din[15:8];
      if (d_gma_be[2]) gmem[d_gma_addr[9:0]][23:16] <= d_gma_din[23:16];
      if (d_gma_be[3]) gmem[d_gma_addr[9:0]][31:24] <= d_gma_din[31:24];
    end
    gma_dout <= gmem[d_gma_addr[9:0]];
  end

  // ---- the CPU: one access at a time, a store ends at its ready, a read at its response ----
  integer seed = 5, cycles = 0, accesses = 0, gap = 0;
  reg [31:0] x;
  localparam [1:0] C_GAP = 2'd0, C_WAIT_RDY = 2'd1, C_WAIT_RESP = 2'd2;
  reg [1:0] cst = C_GAP;
  reg is_line;
  always @(negedge clk) if (!reset) begin
    cycles = cycles + 1;
    case (cst)
      C_GAP: if (gap > 0) gap = gap - 1; else begin
        x = $random(seed);
        access_page <= x[0]; win_plane <= x[2:1];
        win_offset <= {x[15:3]} % 15'd600;
        cpu_din <= $random(seed);
        is_line = 1'b0;   // see the claim: line reads moved to the streaming form (P3)
        cpu_line_read <= is_line;
        cpu_write <= !is_line && x[21];
        cpu_be <= is_line ? 4'hF : (x[25:22] == 0) ? 4'hF : x[25:22];
        cpu_valid <= 1; cst = C_WAIT_RDY; accesses = accesses + 1;
      end
      C_WAIT_RDY: if (d_cpu_ready) begin
        cpu_valid <= 0;
        if (cpu_write) begin cst = C_GAP; gap = x[31:28]; end else cst = C_WAIT_RESP;
      end
      C_WAIT_RESP: if (d_cpu_resp_valid) begin cst = C_GAP; gap = x[31:28]; end
    endcase
  end

  // ==== CHECKS ====
  integer errors = 0;
  always @(posedge clk) if (!reset) begin
    if (d_cpu_dout !== r_cpu_dout || d_cpu_ready !== r_cpu_ready || d_cpu_resp_valid !== r_cpu_resp_valid ||
        d_grcg_cl_ready !== r_grcg_cl_ready ||
        d_egc_cl_ready !== r_egc_cl_ready || d_own_grcg !== r_own_grcg || d_own_egc !== r_own_egc ||
        d_cl_rdata !== r_cl_rdata || d_grcg_cl_done !== r_grcg_cl_done || d_egc_cl_done !== r_egc_cl_done ||
        // port A as pc9821_gvram_mem observes it: the address under en, the datum and enables
        // under en && we (the arbiter presents them unconditionally since C7-dc)
        (d_gma_en && d_gma_addr !== r_gma_addr) ||
        (d_gma_en && d_gma_we && (d_gma_din !== r_gma_din || d_gma_be !== r_gma_be)) ||
        d_gma_we !== r_gma_we || d_gma_en !== r_gma_en || d_dbg_gfx_stats !== r_dbg_gfx_stats ||
        d_dbg_walk_start !== r_dbg_walk_start || d_dbg_walk_cycle !== r_dbg_walk_cycle ||
        d_dbg_gr_owned !== r_dbg_gr_owned || d_dbg_eg_owned !== r_dbg_eg_owned ||
        d_dbg_pw_owned !== r_dbg_pw_owned || d_dbg_access_page !== r_dbg_access_page) begin
      errors = errors + 1;
      if (errors < 10)
        $display("FAIL cycle %0d: dout %08h/%08h rdy %b/%b rsp %b/%b gma %04h/%04h",
                 cycles, d_cpu_dout, r_cpu_dout, d_cpu_ready, r_cpu_ready, d_cpu_resp_valid, r_cpu_resp_valid,
                 d_gma_addr, r_gma_addr);
    end
  end

  // ==== VERDICT ====
  initial begin
    repeat (4) @(posedge clk);
    reset <= 0;
    repeat (400000) @(posedge clk);
    if (accesses < 2000) $fatal(1, "TB_PC9821_GVRAM_ARB_EQUIV: only %0d accesses - the stimulus did not exercise the arbiter", accesses);
    if (errors != 0) $fatal(1, "TB_PC9821_GVRAM_ARB_EQUIV: %0d mismatches over %0d cycles", errors, cycles);
    $display("TB_PC9821_GVRAM_ARB_EQUIV: PASS");
    $display("NOTE gvram_arb_equiv: %0d cycles, %0d word accesses, identical", cycles, accesses);
    $finish;
  end
endmodule

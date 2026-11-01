`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_EGC_SERIAL_EQUIV: the PLANE-SERIAL pc9821_egc is indistinguishable from the PLANE-PARALLEL engine it replaced (kept verbatim as the bench-only tests/pc9821/pc9821_egc_par.sv) - two complete GVRAM stacks (pc9821_gvram_share + pc9821_gvram_arb + pc9821_gvram_mem + the engine), seeded with the same random GVRAM, run the same randomized register programs and CPU access streams (every OPE bit pattern, random ROPs, plane enables, masks, FG/BG, both shift directions with random source/destination bit addresses and lengths, every byte-enable set, both pages, 0-5 idle cycles between accesses so posted writes and back-to-back reads collide) plus forced COMPAREREAD and shifted-read/shifted-copy phases, and must agree on EVERY CPU read datum, on the ordered stream of GVRAM port-A writes (address, enables, enabled bytes) and on the final GVRAM; while the serial stack runs, its scanout port B samples a GVRAM word every cycle and every sample must be a WHOLE word some write of the reference committed (never some planes old and some new); and, with expected values from independent arithmetic, a CPU read issued the cycle after a posted WS_CPU write is accepted returns the written word on each of the four planes and in the compare mask. FAIL-FIRST: a planted serial-path bug (stage B dropping plane 3 from the compare AND) fails the read-datum comparison.
//
// WHY A DIFFERENTIAL: the serial engine changes WHERE the per-plane work happens (one 16-bit
// plane datapath stepped four times) and nothing about WHAT it computes, so the strongest
// statement is "bit-identical to the engine every other EGC bench already pinned against NP2kai
// and the Xe10 vectors" (tb_pc9821_egc_conformance, tb_pc9821_egc_compare). This bench is the
// randomized half of that statement; those benches stay green beside it.
//
// The four non-observability requirements and where each is asserted here:
//  (1) cross-plane results (the compare read's AND, the four-plane pattern latch) - phase B
//      forces COMPAREREAD reads with RL_MEMREAD and random FG/ACCESS, every datum compared;
//  (2) four steps whatever 0x4A0 enables - tb_pc9821_egc_xe10_pace asserts the per-access time
//      equal for 1/2/3/4 planes;
//  (3) atomic commit - the port-B every-cycle sample below;
//  (4) ordering - phase D, a read the cycle after a posted write.

`default_nettype none

// One GVRAM stack with ONE engine (PAR selects the parallel reference) and no GRCG: the share,
// the arbiter and the array exactly as pc9821_gvram_dut composes them. Port B is exposed so the
// bench can sample it every cycle; port A's pins are exposed for the write log.
module egc_eq_stack #(
    parameter integer SYS_CLOCK_HZ = 50_000_000,
    parameter integer PAR = 0
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        access_page,
    input  wire [1:0]  win_plane,
    input  wire [14:0] win_offset,
    input  wire [31:0] cpu_din,
    input  wire [3:0]  cpu_be,
    input  wire        cpu_valid,
    input  wire        cpu_write,
    output wire [31:0] cpu_dout,
    output wire        cpu_ready,
    output wire        cpu_resp_valid,
    input  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg, egc_sft, egc_leng,
    input  wire        egc_shift_we,
    input  wire [15:0] b_addr,
    input  wire        b_en,
    output wire [31:0] b_dout,
    output wire [15:0] gma_addr,
    output wire [31:0] gma_din,
    output wire  [3:0] gma_be,
    output wire        gma_we,
    output wire        gma_en,
    output wire        egc_busy
);
  wire [31:0] gma_dout;
  wire        egc_cl_valid, egc_cl_write, egc_cl_burst, egc_cl_ready, egc_cl_done;
  wire [15:0] egc_cl_addr;
  wire [31:0] egc_cl_wdata;
  wire  [3:0] egc_cl_datum0, egc_cl_wbe;
  wire [63:0] egc_cl_wdata2;
  wire [31:0] egc_cpu_dout, cl_rdata;
  wire        egc_cpu_ready, egc_cpu_resp_valid;
  wire        own_grcg, own_egc;
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
  /* verilator lint_off UNUSEDSIGNAL */
  wire        grcg_cl_ready, grcg_cl_done, gdc_ready, gdc_resp, line_resp;
  wire [31:0] gdc_rdata;
  wire [31:0] line_dout, dbg_gfx_stats;
  wire        dbg_walk_start, dbg_walk_cycle, dbg_gr_owned, dbg_eg_owned, dbg_access_page;
  wire        dbg_egc_txn, dbg_egc_unit;
  /* verilator lint_on UNUSEDSIGNAL */

  pc9821_gvram_mem u_gmem (
      .clk(clk),
      .a_addr(gma_addr), .a_din(gma_din), .a_be(gma_be),
      .a_we(gma_we), .a_en(gma_en), .a_dout(gma_dout),
      .b_addr(b_addr), .b_en(b_en), .b_dout(b_dout));

  pc9821_gvram_share u_gvr_share (
      .clk(clk), .reset(reset),
      .cpu_req(cpu_valid), .cpu_write(cpu_write), .cpu_line_read(1'b0),
      .cpu_page(access_page), .cpu_plane(win_plane), .cpu_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be),
      .gate_egc(1'b1), .gate_grcg(1'b0), .gate_tcr(1'b0),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid), .cpu_dout(cpu_dout),
      .cpu_line_word_valid(line_resp), .cpu_line_word(line_dout),
      .gdc_valid(1'b0), .gdc_write(1'b0), .gdc_route_egc(1'b0), .gdc_route_grcg(1'b0),
      .gdc_page(1'b0), .gdc_plane(2'd0), .gdc_offset(15'd0), .gdc_din(32'd0), .gdc_be(4'd0),
      .gdc_ready(gdc_ready), .gdc_resp_valid(gdc_resp), .gdc_rdata(gdc_rdata),
      .gvr_valid(gvr_valid), .gvr_write(gvr_write), .gvr_line_read(gvr_line_read),
      .gvr_page(gvr_page), .gvr_plane(gvr_plane), .gvr_offset(gvr_offset),
      .gvr_din(gvr_din), .gvr_din_z(gvr_din_z), .gvr_din_f(gvr_din_f), .gvr_be(gvr_be),
      .gvr_gate_egc(gvr_gate_egc), .gvr_gate_grcg(gvr_gate_grcg), .gvr_gate_tcr(gvr_gate_tcr),
      .gvr_ready(gvr_ready), .gvr_resp_valid(gvr_resp_valid), .gvr_dout(gvr_dout),
      .gvr_line_word_valid(gvr_line_word_valid), .gvr_line_word(gvr_line_word));

  pc9821_gvram_arb #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) u_arb (
      .clk(clk), .reset(reset),
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
      .grcg_cl_cap(1'b0), .grcg_cl_cap_rmw(1'b0), .grcg_cl_cap_burst(1'b0), .grcg_cl_cap_pair_high(1'b0),
      .grcg_cl_cap_addr(16'd0), .grcg_cl_cap_wbe(4'd0), .grcg_cl_cap_wdata(32'd0),
      .grcg_cl_cap_wdata2(64'd0), .grcg_cl_cap_be(4'd0),
      .grcg_cl_hold_valid(1'b0), .grcg_cl_hold_write(1'b0), .grcg_cl_hold_burst(1'b0),
      .grcg_cl_hold_addr(16'd0), .grcg_cl_hold_wbe(4'd0), .grcg_cl_hold_wdata(32'd0),
      .grcg_cl_hold_wdata2(64'd0),
      .grcg_cl_hold_be(4'd0), .grcg_cl_hold_rmw(1'b0), .grcg_cl_hold_datum0(4'd0),
      .grcg_cl_hold_mergeable(4'd0), .grcg_cl_tile(32'd0), .grcg_cl_ready(grcg_cl_ready),
      .grcg_cpu_dout(32'd0), .grcg_cpu_ready(1'b0), .grcg_cpu_resp_valid(1'b0),
      .grcg_dbg_busy(1'b0), .grcg_dbg_rmw(1'b0), .grcg_dbg_write(1'b0),
      .egc_cl_valid(egc_cl_valid), .egc_cl_write(egc_cl_write),
      .egc_cl_addr(egc_cl_addr), .egc_cl_wdata(egc_cl_wdata),
      .egc_cl_datum0(egc_cl_datum0),
      .egc_cl_wbe(egc_cl_wbe), .egc_cl_burst(egc_cl_burst),
      .egc_cl_wdata2(egc_cl_wdata2), .egc_cl_ready(egc_cl_ready),
      .egc_cpu_dout(egc_cpu_dout), .egc_cpu_ready(egc_cpu_ready),
      .egc_cpu_resp_valid(egc_cpu_resp_valid), .egc_dbg_busy(egc_busy),
      .own_grcg(own_grcg), .own_egc(own_egc),
      .cl_rdata(cl_rdata),
      .grcg_cl_done(grcg_cl_done), .egc_cl_done(egc_cl_done),
      .gma_addr(gma_addr), .gma_din(gma_din), .gma_be(gma_be),
      .gma_we(gma_we), .gma_en(gma_en), .gma_dout(gma_dout),
      .dbg_gfx_stats(dbg_gfx_stats),
      .dbg_walk_start(dbg_walk_start), .dbg_walk_cycle(dbg_walk_cycle),
      .dbg_gr_owned(dbg_gr_owned), .dbg_eg_owned(dbg_eg_owned),
      .dbg_pw_owned(), .dbg_access_page(dbg_access_page));

  generate
    if (PAR != 0) begin : g_par
      pc9821_egc_par u_egc (
          .clk(clk), .reset(reset),
          .reg_access(egc_access), .reg_fgbg(egc_fgbg), .reg_ope(egc_ope),
          .reg_fg(egc_fg), .reg_mask(egc_mask), .reg_bg(egc_bg),
          .reg_sft(egc_sft), .reg_leng(egc_leng), .reg_shift_we(egc_shift_we),
          .cpu_page(gvr_page), .cpu_plane(gvr_plane), .cpu_offset(gvr_offset),
          .cpu_din(gvr_din), .cpu_be(gvr_be), .cpu_write(gvr_write),
          .cpu_valid(gvr_valid && own_egc),
          .cpu_dout(egc_cpu_dout), .cpu_ready(egc_cpu_ready), .cpu_resp_valid(egc_cpu_resp_valid),
          .cl_valid(egc_cl_valid), .cl_ready(egc_cl_ready),
          .cl_write(egc_cl_write), .cl_addr(egc_cl_addr),
          .cl_wdata(egc_cl_wdata), .cl_datum0(egc_cl_datum0), .cl_wbe(egc_cl_wbe),
          .cl_burst(egc_cl_burst), .cl_wdata2(egc_cl_wdata2),
          .cl_rdata(cl_rdata), .cl_done(egc_cl_done),
          .dbg_busy(egc_busy), .dbg_egc_txn(dbg_egc_txn), .dbg_egc_unit(dbg_egc_unit));
    end else begin : g_ser
      pc9821_egc u_egc (
          .clk(clk), .reset(reset),
          .reg_access(egc_access), .reg_fgbg(egc_fgbg), .reg_ope(egc_ope),
          .reg_fg(egc_fg), .reg_mask(egc_mask), .reg_bg(egc_bg),
          .reg_sft(egc_sft), .reg_leng(egc_leng), .reg_shift_we(egc_shift_we),
          .cpu_page(gvr_page), .cpu_plane(gvr_plane), .cpu_offset(gvr_offset),
          .cpu_din(gvr_din), .cpu_be(gvr_be), .cpu_write(gvr_write),
          .cpu_valid(gvr_valid && own_egc),
          .cpu_dout(egc_cpu_dout), .cpu_ready(egc_cpu_ready), .cpu_resp_valid(egc_cpu_resp_valid),
          .cl_valid(egc_cl_valid), .cl_ready(egc_cl_ready),
          .cl_write(egc_cl_write), .cl_addr(egc_cl_addr),
          .cl_wdata(egc_cl_wdata), .cl_datum0(egc_cl_datum0), .cl_wbe(egc_cl_wbe),
          .cl_burst(egc_cl_burst), .cl_wdata2(egc_cl_wdata2),
          .cl_rdata(cl_rdata), .cl_done(egc_cl_done),
          .dbg_busy(egc_busy), .dbg_egc_txn(dbg_egc_txn), .dbg_egc_unit(dbg_egc_unit));
    end
  endgenerate
endmodule

module tb_pc9821_egc_serial_equiv;
  localparam integer CYCLE_NS = 20;
  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg reset = 1;
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  integer errors = 0;
  task automatic fail(input [8*200-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  // ==== DUT ====
  // ---- the two stacks' stimulus: S = serial (the DUT), P = parallel (the reference) ----
`define EQ_DECL(P) \
  reg        P``_page = 1'b0; \
  reg  [1:0] P``_plane = 2'd0; \
  reg [14:0] P``_off = 15'd0; \
  reg [31:0] P``_din = 32'd0; \
  reg  [3:0] P``_be = 4'hF; \
  reg        P``_valid = 1'b0, P``_write = 1'b0; \
  wire [31:0] P``_dout; \
  wire       P``_ready, P``_resp; \
  reg [15:0] P``_access = 16'hFFF0, P``_fgbg = 16'h00FF, P``_ope = 16'h0000, P``_fg = 16'h0000, \
             P``_mask = 16'hFFFF, P``_bg = 16'h0000, P``_sft = 16'h0000, P``_leng = 16'h000F; \
  reg        P``_shift_we = 1'b0; \
  reg [15:0] P``_baddr = 16'd0; \
  wire [31:0] P``_bdout; \
  wire [15:0] P``_gaddr; \
  wire [31:0] P``_gdin; \
  wire  [3:0] P``_gbe; \
  wire       P``_gwe, P``_gen, P``_busy;

  `EQ_DECL(s)
  `EQ_DECL(p)

`define EQ_STACK(P, ISPAR) \
  egc_eq_stack #(.SYS_CLOCK_HZ(50_000_000), .PAR(ISPAR)) stk_``P ( \
      .clk(clk), .reset(reset), .access_page(P``_page), .win_plane(P``_plane), \
      .win_offset(P``_off), .cpu_din(P``_din), .cpu_be(P``_be), .cpu_valid(P``_valid), \
      .cpu_write(P``_write), .cpu_dout(P``_dout), .cpu_ready(P``_ready), \
      .cpu_resp_valid(P``_resp), \
      .egc_access(P``_access), .egc_fgbg(P``_fgbg), .egc_ope(P``_ope), .egc_fg(P``_fg), \
      .egc_mask(P``_mask), .egc_bg(P``_bg), .egc_sft(P``_sft), .egc_leng(P``_leng), \
      .egc_shift_we(P``_shift_we), \
      .b_addr(P``_baddr), .b_en(1'b1), .b_dout(P``_bdout), \
      .gma_addr(P``_gaddr), .gma_din(P``_gdin), .gma_be(P``_gbe), .gma_we(P``_gwe), \
      .gma_en(P``_gen), .egc_busy(P``_busy));

  `EQ_STACK(s, 0)
  `EQ_STACK(p, 1)

  // ---- THE PROGRAM: one op list both stacks walk, each at its own pace ----
  localparam integer NOPS = 40000;
  localparam integer K_REG = 0, K_ARM = 1, K_ACC = 2;
  integer    op_kind [NOPS];
  integer    op_reg  [NOPS];      // K_REG: 0 access, 1 fgbg, 2 ope, 3 fg, 4 mask, 5 bg
  reg [15:0] op_val  [NOPS];      // K_REG value / K_ARM sft
  reg [15:0] op_val2 [NOPS];      // K_ARM leng
  reg        op_wr   [NOPS];
  reg        op_pg   [NOPS];
  reg [14:0] op_off  [NOPS];
  reg  [3:0] op_be   [NOPS];
  reg [31:0] op_din  [NOPS];
  integer    op_gap  [NOPS];
  integer    nops = 0;
  reg [31:0] rd_s [NOPS];
  reg [31:0] rd_p [NOPS];

  // The GVRAM window the program works in: columns WIN_BASE..WIN_BASE+WIN_N-1 on both pages, so
  // writes and reads collide on the same words.
  localparam [14:0] WIN_BASE = 15'h0100;
  localparam integer WIN_N = 64;

  // Each stack's walk of the op list. The CPU shape is z486's: an access is presented at a
  // negedge and released at the ready edge (src/z486/memory.sv `ext_valid_r <= 1'b0`), a read
  // then waits for its response; a register write is the iobus latch changing between accesses
  // (it may land while a posted write still drains, which both engines must treat alike).
`define EQ_RUN(P) \
  task automatic run_``P(input integer from, input integer to); \
    integer i, g; \
    begin \
      for (i = from; i < to; i = i + 1) begin \
        for (g = 0; g < op_gap[i]; g = g + 1) @(negedge clk); \
        case (op_kind[i]) \
          K_REG: begin \
            @(negedge clk); \
            case (op_reg[i]) \
              0: P``_access = op_val[i]; \
              1: P``_fgbg   = op_val[i]; \
              2: P``_ope    = op_val[i]; \
              3: P``_fg     = op_val[i]; \
              4: P``_mask   = op_val[i]; \
              default: P``_bg = op_val[i]; \
            endcase \
          end \
          K_ARM: begin \
            @(negedge clk); \
            P``_sft = op_val[i]; P``_leng = op_val2[i]; P``_shift_we = 1'b1; \
            @(negedge clk); \
            P``_shift_we = 1'b0; \
          end \
          default: begin \
            @(negedge clk); \
            P``_page = op_pg[i]; P``_plane = op_off[i][1:0]; P``_off = op_off[i]; \
            P``_din = op_din[i]; P``_be = op_be[i]; P``_write = op_wr[i]; P``_valid = 1'b1; \
            while (!P``_ready) @(negedge clk); \
            P``_valid = 1'b0; P``_write = 1'b0; \
            if (!op_wr[i]) begin \
              while (!P``_resp) @(negedge clk); \
              rd_``P[i] = P``_dout; \
            end \
          end \
        endcase \
      end \
      @(negedge clk); \
      while (P``_busy) @(negedge clk); \
    end \
  endtask

  `EQ_RUN(s)
  `EQ_RUN(p)

  // ---- the program generator ----
  integer seed = 32'h5EC1A1;
  function automatic integer rnd(input integer n);
    rnd = {$random(seed)} % n;
  endfunction
  task automatic add_reg(input integer r, input [15:0] v);
    begin op_kind[nops] = K_REG; op_reg[nops] = r; op_val[nops] = v; op_gap[nops] = rnd(3);
          nops = nops + 1; end
  endtask
  task automatic add_arm(input [15:0] sft, input [15:0] leng);
    begin op_kind[nops] = K_ARM; op_val[nops] = sft; op_val2[nops] = leng; op_gap[nops] = rnd(3);
          nops = nops + 1; end
  endtask
  task automatic add_acc(input wr, input pg, input [14:0] off, input [3:0] be, input [31:0] din,
                         input integer gap);
    begin op_kind[nops] = K_ACC; op_wr[nops] = wr; op_pg[nops] = pg; op_off[nops] = off;
          op_be[nops] = be; op_din[nops] = din; op_gap[nops] = gap; nops = nops + 1; end
  endtask
  function automatic [3:0] rnd_be(input integer dummy);
    reg [3:0] b;
    begin
      case (rnd(8))
        0, 1: b = 4'hF;
        2, 3: b = rnd(2) ? 4'b0011 : 4'b1100;
        4:    b = 4'b0001 << rnd(4);
        5:    b = (rnd(2) ? 4'b0110 : (rnd(2) ? 4'b1110 : 4'b0111));
        default: begin b = rnd(16); if (b == 4'h0) b = 4'h5; end
      endcase
      rnd_be = b;
    end
  endfunction
  function automatic [15:0] rnd_access(input integer dummy);
    case (rnd(5))
      0: rnd_access = 16'hFFF0;
      1: rnd_access = 16'hFFF0 | (16'h1 << rnd(4));
      2: rnd_access = 16'hFFFE;
      default: rnd_access = 16'hFFF0 | rnd(16);
    endcase
  endfunction
  function automatic [15:0] rnd_off(input integer dummy);
    rnd_off = WIN_BASE + {rnd(WIN_N), 2'b00};
  endfunction
  integer cov_cmp_rd = 0, cov_sft_rd = 0, cov_desc = 0, cov_moved = 0, cov_wr = 0, cov_rd = 0;
  // A shift arm with random direction and bit addresses; `leng` random over short and long.
  task automatic add_rnd_arm;
    reg [15:0] sft;
    begin
      sft = 16'h0000;
      sft[12]  = (rnd(2) != 0);          // descending
      sft[6:4] = 3'(rnd(8));             // dstbit
      sft[2:0] = 3'(rnd(8));             // srcbit
      if (rnd(4) == 0) sft[3] = 1'b1;   // srcbit >= 8
      if (sft[12]) cov_desc = cov_desc + 1;
      if (sft[2:0] != sft[6:4]) cov_moved = cov_moved + 1;
      add_arm(sft, 16'(rnd(3) == 0 ? rnd(4096) : rnd(64)));
    end
  endtask
  task automatic add_rnd_access(input integer bias_rd);
    reg wr;
    begin
      wr = (rnd(100) >= bias_rd);
      if (wr) cov_wr = cov_wr + 1; else cov_rd = cov_rd + 1;
      add_acc(wr, rnd(2), rnd_off(0), rnd_be(0), $random(seed), rnd(6));
    end
  endtask

  // Phase A: everything random.
  task automatic gen_phase_a(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) begin
        case (rnd(12))
          0: add_reg(0, rnd_access(0));
          1: add_reg(1, rnd(65536));
          2: add_reg(2, rnd(65536) & 16'h3FFF);
          3: add_reg(3, rnd(16));
          4: add_reg(4, rnd(3) == 0 ? rnd(65536) : 16'hFFFF);
          5: add_reg(5, rnd(16));
          6: add_rnd_arm;
          default: add_rnd_access(40);
        endcase
      end
    end
  endtask

  // Phase B: COMPAREREAD reads (OPE bit 13, with and without RL_MEMREAD) under random FG,
  // ACCESS and pattern selects, each followed by a WS_PATREG/WS_ROP write - the 0x3100 copy shape
  // and its relatives - so the cross-plane compare AND and the four-plane pattern latch carry.
  task automatic gen_phase_b(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) begin
        if (rnd(4) == 0) add_reg(3, rnd(16));
        if (rnd(4) == 0) add_reg(0, rnd_access(0));
        if (rnd(6) == 0) add_reg(1, {1'b0, 2'(rnd(4)), 3'b000, 2'(rnd(4)), 8'hFF});
        add_reg(2, 16'h2000 | (rnd(2) ? 16'h0100 : 16'h0000) | (rnd(2) ? 16'h0400 : 16'h0000) |
                   (rnd(256)));
        add_acc(1'b0, rnd(2), rnd_off(0), rnd_be(0), 32'd0, rnd(3));
        cov_cmp_rd = cov_cmp_rd + 1;
        add_reg(2, rnd(2) ? 16'h3100 : (16'h0800 | rnd(256)));
        add_acc(1'b1, rnd(2), rnd_off(0), rnd_be(0), $random(seed), rnd(3));
      end
    end
  endtask

  // Phase C: SHIFTED reads and copies - a shift arm with a moved/descending shift, then a run of
  // SHIFT_CPU-clear reads (the read feeds the shifter: 0x28F0 / 0x29F0 / RL_MEMREAD reads) and
  // the ROP writes that consume the produce, both directions.
  task automatic gen_phase_c(input integer n);
    integer k, r;
    begin
      for (k = 0; k < n; k = k + 1) begin
        add_rnd_arm;
        add_reg(2, rnd(2) ? 16'h28F0 : (rnd(2) ? 16'h29F0 : (16'h0800 | rnd(256))));
        for (r = 0; r < 1 + rnd(6); r = r + 1) begin
          add_acc(1'b0, rnd(2), rnd_off(0), rnd(2) ? 4'h3 : rnd_be(0), 32'd0, rnd(3));
          cov_sft_rd = cov_sft_rd + 1;
          add_acc(1'b1, rnd(2), rnd_off(0), rnd(2) ? 4'h3 : rnd_be(0), $random(seed), rnd(3));
        end
      end
    end
  endtask

  // ---- the write logs: every port-A write each stack's array commits, in order ----
  localparam integer NLOG = 120000;
  reg [15:0] wl_s_a [NLOG]; reg [31:0] wl_s_d [NLOG]; reg [3:0] wl_s_b [NLOG];
  reg [15:0] wl_p_a [NLOG]; reg [31:0] wl_p_d [NLOG]; reg [3:0] wl_p_b [NLOG];
  integer nwl_s = 0, nwl_p = 0;
  always @(posedge clk) if (!reset) begin
    if (s_gen && s_gwe && nwl_s < NLOG) begin
      wl_s_a[nwl_s] <= s_gaddr; wl_s_d[nwl_s] <= s_gdin; wl_s_b[nwl_s] <= s_gbe; nwl_s <= nwl_s + 1;
    end
    if (p_gen && p_gwe && nwl_p < NLOG) begin
      wl_p_a[nwl_p] <= p_gaddr; wl_p_d[nwl_p] <= p_gdin; wl_p_b[nwl_p] <= p_gbe; nwl_p <= nwl_p + 1;
    end
  end

  // ---- the serial stack's scanout-port sample, every cycle ----
  // A rotating window word is presented on port B each cycle and its registered word captured one
  // cycle later. After the run every sample must be a WHOLE word: the seed or a word some
  // REFERENCE write committed (its full post-write value), never a mix of old and new planes.
  localparam integer NSMP = 1200000;
  reg [15:0] smp_a [NSMP]; reg [31:0] smp_d [NSMP];
  integer nsmp = 0;
  reg        smp_on = 1'b0;
  reg [15:0] baddr_q;
  reg        smp_on_q = 1'b0;
  integer    lfsr = 1;
  always @(posedge clk) begin
    lfsr <= (lfsr >> 1) ^ ((lfsr & 1) ? 32'h8020_0003 : 0);
    s_baddr <= {lfsr[7], WIN_BASE[14:2] + {7'd0, lfsr[5:0]}, lfsr[9:8]};
    baddr_q <= s_baddr;
    smp_on_q <= smp_on;
    if (smp_on_q && nsmp < NSMP) begin
      smp_a[nsmp] <= baddr_q; smp_d[nsmp] <= s_bdout; nsmp <= nsmp + 1;
    end
  end

  // ---- the seed: the same random GVRAM in both arrays ----
  integer w;
  reg [31:0] sv;
  initial begin
    for (w = 0; w < 65536; w = w + 1) begin
      sv = $random(seed);
      stk_s.u_gmem.mem0[w] = sv[7:0];   stk_p.u_gmem.mem0[w] = sv[7:0];
      stk_s.u_gmem.mem1[w] = sv[15:8];  stk_p.u_gmem.mem1[w] = sv[15:8];
      stk_s.u_gmem.mem2[w] = sv[23:16]; stk_p.u_gmem.mem2[w] = sv[23:16];
      stk_s.u_gmem.mem3[w] = sv[31:24]; stk_p.u_gmem.mem3[w] = sv[31:24];
    end
  end
  reg [31:0] snap [0:65535];

  // ---- the atomic-commit check: membership of each sample in its word's legal history ----
  // The reference writes are chained per address (head/next) so each sample walks only its own
  // word's history.
  integer wl_head [0:65535];
  integer wl_tail [0:65535];
  integer wl_next [NLOG];
  task automatic check_samples;
    integer i, j, bad;
    reg [31:0] cur;
    reg        hit;
    begin
      for (i = 0; i < 65536; i = i + 1) begin wl_head[i] = -1; wl_tail[i] = -1; end
      for (j = 0; j < nwl_p; j = j + 1) begin
        wl_next[j] = -1;
        if (wl_head[wl_p_a[j]] < 0) wl_head[wl_p_a[j]] = j;
        else wl_next[wl_tail[wl_p_a[j]]] = j;
        wl_tail[wl_p_a[j]] = j;
      end
      bad = 0;
      for (i = 0; i < nsmp; i = i + 1) begin
        cur = snap[smp_a[i]];
        hit = (smp_d[i] == cur);
        for (j = wl_head[smp_a[i]]; j >= 0 && !hit; j = wl_next[j])
          begin
            cur = { wl_p_b[j][3] ? wl_p_d[j][31:24] : cur[31:24],
                    wl_p_b[j][2] ? wl_p_d[j][23:16] : cur[23:16],
                    wl_p_b[j][1] ? wl_p_d[j][15:8]  : cur[15:8],
                    wl_p_b[j][0] ? wl_p_d[j][7:0]   : cur[7:0] };
            hit = (smp_d[i] == cur);
          end
        if (!hit) begin
          if (bad < 8)
            $display("FAIL scanout sample %0d: word %04h read %08h, which no reference write ever committed whole",
                     i, smp_a[i], smp_d[i]);
          bad = bad + 1;
        end
      end
      if (bad != 0) fail("atomic commit: the scanout port saw a GVRAM word some planes old and some new");
      else $display("NOTE egc_serial_equiv: %0d scanout samples, every one a whole committed word", nsmp);
    end
  endtask

  // ---- phase D: the ordering rule, against independent arithmetic ----
  // A WS_CPU (OPE 0x0000) 16-bit write with mask 0xFFFF and all planes enabled stores the CPU
  // word into all four planes (NP2kai mem/memegc.c egc_opew default: `return &egc_vram_src` fed
  // from the CPU data, mask2 = mask & srcmask with the shifter armed at zero), so a read issued the
  // cycle after the write's accept must return that word for EACH plane through a SHIFT_CPU read
  // (OPE 0x0400 returns the read plane's memory, memegc.c:1091-1098) and the all-ones mask through
  // a COMPAREREAD against FG = 0xF (every plane equal to FG's bit wherever the word has a 1).
  task automatic order_s(input [15:0] wv, input [1:0] rp, input integer cmp);
    reg [31:0] got;
    begin
      // re-arm the shifter at zero so the WS_CPU word's srcmask is 0xFFFF (egcshift, io/egc.c)
      @(negedge clk);
      s_sft = 16'h0000; s_leng = 16'h000F; s_shift_we = 1'b1;
      @(negedge clk);
      s_shift_we = 1'b0;
      @(negedge clk);
      s_ope = 16'h0000; s_access = 16'hFFF0; s_mask = 16'hFFFF; s_fg = 16'h000F;
      s_fgbg = {6'd0, rp, 8'hFF};
      s_page = 1'b0; s_plane = 2'd0; s_off = 15'h0200; s_din = {16'h0, wv}; s_be = 4'b0011;
      s_write = 1'b1; s_valid = 1'b1;
      while (!s_ready) @(negedge clk);
      // The next access is presented at once (one cycle of the CPU's accept gap) while the
      // posted write still drains through the plane steps.
      s_valid = 1'b0; s_write = 1'b0;
      s_ope = cmp ? 16'h2000 : 16'h0400;
      @(negedge clk);
      s_valid = 1'b1;
      while (!s_ready) @(negedge clk);
      s_valid = 1'b0;
      while (!s_resp) @(negedge clk);
      got = s_dout;
      if (got[15:0] !== wv) begin
        $display("FAIL ordering: %s read right behind a posted write of %04h returned %04h (plane %0d)",
                 cmp ? "compare" : "SHIFT_CPU", wv, got[15:0], rp);
        errors = errors + 1;
      end
      @(negedge clk);
      while (s_busy) @(negedge clk);
    end
  endtask

  integer i, mism, k;
  reg [31:0] fs, fp;
  initial begin
    reset = 1'b1;
    gen_phase_a(6000);
    gen_phase_b(1200);
    gen_phase_c(800);
    gen_phase_a(2000);
    if (nops > NOPS) $fatal(1, "TB_PC9821_EGC_SERIAL_EQUIV: program overflows NOPS");
    for (i = 0; i < nops; i = i + 1) begin rd_s[i] = 32'hDEAD_BEEF; rd_p[i] = 32'hDEAD_BEEF; end
    repeat (8) @(posedge clk);
    for (w = 0; w < 65536; w = w + 1)
      snap[w] = {stk_s.u_gmem.mem3[w], stk_s.u_gmem.mem2[w], stk_s.u_gmem.mem1[w], stk_s.u_gmem.mem0[w]};
    reset = 1'b0;
    repeat (40) @(posedge clk);   // the ring scrub
    smp_on = 1'b1;
    fork
      run_s(0, nops);
      run_p(0, nops);
    join
    smp_on = 1'b0;
    repeat (4) @(posedge clk);
    $display("NOTE egc_serial_equiv: %0d ops (%0d writes, %0d reads, %0d compare reads, %0d shifted-phase reads, %0d descending and %0d moved arms), finished at cycle %0d",
             nops, cov_wr, cov_rd, cov_cmp_rd, cov_sft_rd, cov_desc, cov_moved, cyc);

    // ==== CHECKS ====
    // (a) every CPU read datum
    mism = 0;
    for (i = 0; i < nops; i = i + 1)
      if (op_kind[i] == K_ACC && !op_wr[i] && rd_s[i] !== rd_p[i]) begin
        if (mism < 8)
          $display("FAIL read op %0d (page %0d off %04h be %b): serial %08h, parallel %08h",
                   i, op_pg[i], op_off[i], op_be[i], rd_s[i], rd_p[i]);
        mism = mism + 1;
      end
    if (mism != 0) fail("a CPU read datum differs between the serial and the parallel engine");
    // (b) the ordered port-A write stream
    if (nwl_s != nwl_p) begin
      $display("FAIL write log: serial %0d writes, parallel %0d", nwl_s, nwl_p);
      errors = errors + 1;
    end
    mism = 0;
    for (i = 0; i < nwl_s && i < nwl_p; i = i + 1) begin
      fs = 32'd0; fp = 32'd0;
      for (k = 0; k < 4; k = k + 1) begin
        if (wl_s_b[i][k]) fs[8*k +: 8] = wl_s_d[i][8*k +: 8];
        if (wl_p_b[i][k]) fp[8*k +: 8] = wl_p_d[i][8*k +: 8];
      end
      if (wl_s_a[i] !== wl_p_a[i] || wl_s_b[i] !== wl_p_b[i] || fs !== fp) begin
        if (mism < 8)
          $display("FAIL write %0d: serial %04h/%b/%08h, parallel %04h/%b/%08h",
                   i, wl_s_a[i], wl_s_b[i], fs, wl_p_a[i], wl_p_b[i], fp);
        mism = mism + 1;
      end
    end
    if (mism != 0) fail("the GVRAM write stream differs between the serial and the parallel engine");
    // (c) the final GVRAM, whole array
    mism = 0;
    for (w = 0; w < 65536; w = w + 1)
      if ({stk_s.u_gmem.mem3[w], stk_s.u_gmem.mem2[w], stk_s.u_gmem.mem1[w], stk_s.u_gmem.mem0[w]} !==
          {stk_p.u_gmem.mem3[w], stk_p.u_gmem.mem2[w], stk_p.u_gmem.mem1[w], stk_p.u_gmem.mem0[w]})
        mism = mism + 1;
    if (mism != 0) fail("the final GVRAM differs between the serial and the parallel engine");
    $display("NOTE egc_serial_equiv: %0d port-A writes compared in order, final GVRAM compared", nwl_s);
    // (d) atomic commit
    check_samples();
    // coverage
    if (cov_cmp_rd < 1000 || cov_sft_rd < 1000 || cov_desc < 200 || cov_moved < 400 || nwl_s < 8000)
      fail("coverage: the program did not reach the compare/shifted/descending shapes it claims");
    // (e) the ordering rule
    for (i = 0; i < 4; i = i + 1) begin
      order_s(16'hA5C3 ^ (16'h1111 * i), i[1:0], 0);
      order_s(16'h3C96 ^ (16'h0101 * i), i[1:0], 1);
    end
    $display("NOTE egc_serial_equiv: a read the cycle after a posted write saw all four planes written");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_EGC_SERIAL_EQUIV: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_EGC_SERIAL_EQUIV: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_EGC_SERIAL_EQUIV: FAIL");
    end
  end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_EGC_SERIAL_EQUIV: TIMEOUT");
  end

endmodule

`default_nettype wire

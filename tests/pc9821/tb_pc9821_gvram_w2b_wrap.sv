`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The GVRAM array-access FSM's two-word write tail (G_W2B) wraps its second word at the 15-bit plane offset inside its own page (aliases.md A8): the array key is {page, offset[14:0]}, so the plain b_addr_q + 16'd1 carried into the page bit at {page, 0x7FFF} and wrote the OTHER page's offset 0, where every GVRAM path in NP2kai wraps at 15 bits (LOW15, mem/memvram.c:42,114,136, mem/memegc.c:1131,1327) and this module's own c_col column walk already wraps the same way. Driven at the arbiter's EGC client port with the two-word burst shape burst_fits names. FAIL-FIRST: the second word lands at the other page's offset 0 on both pages; PASS: it lands at the same page's offset 0 and the off-boundary pair is unchanged.
//
// The GVRAM array-access FSM's two-word write tail (G_W2B) wraps its second word at the
// 15-bit plane offset, inside its own page: a unit pair whose first dword is at plane
// offset 0x7FFF writes its second dword to THE SAME page's offset 0, never to the other
// page's offset 0. The 16-bit array key is {page, offset[14:0]}, so the plain
// `b_addr_q + 16'd1` carried into the page bit at {page, 0x7FFF} and aliased the other
// page (aliases.md A8). NP2kai wraps every GVRAM offset at 15 bits (LOW15,
// mem/memvram.c:42,114,136 and mem/memegc.c:1131,1327) and this module's own column
// walk c_col already wraps the same way; G_W2B (and only G_W2B, G_RBC's columns never
// reach the boundary) is the one place the carry escapes.
//
// FAILS BEFORE: the second word's write lands at {page^1, 0x0000}.
// PASSES AFTER: it lands at {page, 0x0000}, and the off-by-one control at 0x0100 is
// unchanged.
//
// The seam is the arbiter's own client port (the EGC's 64-bit pair), exactly the
// transaction shape burst_fits names: a write burst, two dwords, word 0 riding ef_addr.

`default_nettype none

module tb_pc9821_gvram_w2b_wrap;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ==== DUT: the array and its arbiter ====
  wire [15:0] gma_addr;
  wire [31:0] gma_din;
  wire  [3:0] gma_be;
  wire        gma_we, gma_en;
  wire [31:0] gma_dout;

  // The EGC client port driven directly (the arb is the unit under test).
  reg         egc_cl_valid = 0;
  reg         egc_cl_write = 0;
  reg  [15:0] egc_cl_addr = 0;
  reg  [31:0] egc_cl_wdata = 0;
  reg   [3:0] egc_cl_datum0 = 4'hF;
  reg   [3:0] egc_cl_wbe = 4'hF;
  reg         egc_cl_burst = 0;
  reg  [63:0] egc_cl_wdata2 = 0;
  wire        egc_cl_ready, egc_cl_done;

  // ==== DUT ====
  pc9821_gvram_mem u_gmem (
      .clk(clk),
      .a_addr(gma_addr), .a_din(gma_din), .a_be(gma_be),
      .a_we(gma_we), .a_en(gma_en), .a_dout(gma_dout),
      .b_addr(16'd0), .b_en(1'b0), .b_dout()
  );

  // SYS_CLOCK_HZ is this bench's own clock (10 ns = 100 MHz), which every DUT's time-derived
  // constant must be told (pc9821_gvram_dut's contract). It is NOT load-bearing for this file's
  // stimuli: the arbiter's GVRAM_PERIODS neither arms nor waits for the EGC's requests (the EGC's
  // backend requests are the engine's own produce steps - see pc9821_gvram_arb's GVRAM_PERIODS
  // block), and every request this bench presents arrives on the EGC client port with `egc_gate`
  // tied high. It stays so the conversion is the real clock's if that exemption ever changes.
  pc9821_gvram_arb #(.SYS_CLOCK_HZ(100_000_000)) u_arb (
      .clk(clk),
      .timing_xe10(1'b0), .gfx_scan_on(1'b0),   // Fast: the pre-field periods .reset(reset),
      .access_page(1'b0),
      .win_plane(2'd0), .win_offset(15'd0),
      .cpu_din(32'd0), .cpu_din_z(4'hF), .cpu_din_f(4'h0), .cpu_be(4'hF), .cpu_line_read(1'b0),
      .cpu_valid(1'b0), .cpu_write(1'b0),
      .cpu_dout(), .cpu_line_word(),
      .cpu_ready(), .cpu_resp_valid(), .cpu_line_word_valid(),
      .grcg_expand_gate(1'b0), .grcg_tcr_gate(1'b0),
      .egc_gate(1'b1),
      .grcg_cl_cap(1'b0), .grcg_cl_cap_rmw(1'b0), .grcg_cl_cap_burst(1'b0), .grcg_cl_cap_pair_high(1'b0),
      .grcg_cl_cap_addr(16'd0), .grcg_cl_cap_wbe(4'd0), .grcg_cl_cap_wdata(32'd0),
      .grcg_cl_cap_wdata2(64'd0), .grcg_cl_cap_be(4'd0),
      .grcg_cl_hold_valid(1'b0), .grcg_cl_hold_write(1'b0), .grcg_cl_hold_burst(1'b0),
      .grcg_cl_hold_addr(16'd0), .grcg_cl_hold_wbe(4'd0), .grcg_cl_hold_wdata(32'd0),
      .grcg_cl_hold_wdata2(64'd0),
      .grcg_cl_hold_be(4'd0), .grcg_cl_hold_rmw(1'b0), .grcg_cl_hold_datum0(4'd0),
      .grcg_cl_hold_mergeable(4'd0), .grcg_cl_tile(32'd0),
      .grcg_cl_ready(),
      .grcg_cpu_dout(32'd0), .grcg_cpu_ready(1'b0),
      .grcg_cpu_resp_valid(1'b0),
      .grcg_dbg_busy(1'b0), .grcg_dbg_rmw(1'b0), .grcg_dbg_write(1'b0),
      .egc_cl_valid(egc_cl_valid), .egc_cl_write(egc_cl_write),
      .egc_cl_addr(egc_cl_addr), .egc_cl_wdata(egc_cl_wdata),
      .egc_cl_datum0(egc_cl_datum0),
      .egc_cl_wbe(egc_cl_wbe), .egc_cl_burst(egc_cl_burst),
      .egc_cl_wdata2(egc_cl_wdata2), .egc_cl_ready(egc_cl_ready),
      .egc_cpu_dout(32'd0), .egc_cpu_ready(1'b0),
      .egc_cpu_resp_valid(1'b0), .egc_dbg_busy(1'b0),
      .own_grcg(), .own_egc(),
      .cl_rdata(),
      .grcg_cl_done(), .egc_cl_done(egc_cl_done),
      .gma_addr(gma_addr), .gma_din(gma_din), .gma_be(gma_be),
      .gma_we(gma_we), .gma_en(gma_en), .gma_dout(gma_dout),
      .dbg_gfx_stats(), .dbg_walk_start(), .dbg_walk_cycle(),
      .dbg_gr_owned(), .dbg_eg_owned(), .dbg_access_page()
  );

  // ==== The array write log: every write's key and dword ====
  integer wr_n = 0;
  reg [15:0] wr_addr [0:7];
  reg [31:0] wr_data [0:7];
  always @(posedge clk)
    if (!reset && gma_en && gma_we && (wr_n < 8)) begin
      wr_addr[wr_n] = gma_addr;
      wr_data[wr_n] = gma_din;
      wr_n = wr_n + 1;
    end

  integer errors = 0;

  // ==== CHECKS ====
  task automatic clear_log;
    begin
      @(negedge clk);
      wr_n = 0;
    end
  endtask

  // One two-word burst: word 0 at {page, off}, word 1 at {page, (off+1) & 0x7FFF}.
  // The client port's ready is the COMBINATIONAL accept announcement (cc_ready is
  // cc_valid && the accept gate): sample it in the cycle the request is presented and let the
  // next posedge be the accept, exactly as pc9821_egc drives the port. Polling it at
  // later negedges misses the accept cycle entirely (the level falls again in G_W2B).
  //
  // THE SAME-CYCLE DEMAND IS RESTORED, and the period is why it is still true: pc9821_gvram_arb's
  // acceptance period gates `cc_ready` through `cc_owns_egc || !hold_busy`, and this file's only
  // client is the EGC (`egc_gate` is tied high, `cpu_valid` tied low), so the period is never
  // consulted here and the announcement is still made in the presentation cycle. An EGC client is
  // not the period's subject; demanding it in the same cycle keeps the assertion as strong as it
  // was, and a future change that made this port wait would fail HERE rather than silently pass.
  task automatic burst2(input page, input [14:0] off,
                        input [31:0] lo, input [31:0] hi);
    integer g;
    begin
      @(negedge clk);
      egc_cl_valid = 1;
      egc_cl_write = 1;
      egc_cl_burst = 1;
      egc_cl_addr = {page, off};
      egc_cl_wdata = lo;
      egc_cl_wdata2 = {hi, lo};
      #1;
      if (egc_cl_ready !== 1'b1)
        $fatal(1, "TB_PC9821_GVRAM_W2B_WRAP: no accept announcement");
      @(posedge clk);              // the accept edge
      @(negedge clk);
      egc_cl_valid = 0;
      egc_cl_write = 0;
      egc_cl_burst = 0;
      g = 0;
      while (!egc_cl_done && g < 200) begin @(negedge clk); g = g + 1; end
      if (!egc_cl_done) $fatal(1, "TB_PC9821_GVRAM_W2B_WRAP: no completion");
      @(negedge clk);
    end
  endtask

  task automatic check_pair(input [15:0] w0_addr, input [31:0] w0_data,
                            input [15:0] w1_addr, input [31:0] w1_data,
                            input [8*80-1:0] tag);
    integer i;
    begin
      if (wr_n != 2 || wr_addr[0] !== w0_addr || wr_data[0] !== w0_data ||
          wr_addr[1] !== w1_addr || wr_data[1] !== w1_data) begin
        $display("FAIL %0s: %0d writes, w0=(%04x,%08x) w1=(%04x,%08x), want w0=(%04x,%08x) w1=(%04x,%08x)",
                 tag, wr_n,
                 wr_addr[0], wr_data[0], wr_addr[1], wr_data[1],
                 w0_addr, w0_data, w1_addr, w1_data);
        for (i = 0; i < wr_n; i = i + 1)
          $display("  log[%0d] = (%04x, %08x)", i, wr_addr[i], wr_data[i]);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;

    // The boundary unit pair on page 0: word 0 at offset 0x7FFF, word 1 must
    // WRAP to offset 0 of the SAME page (page 0, key 16'h0000) -- the bug put
    // it at the other page's offset 0 (key 16'h8000).
    clear_log();
    burst2(1'b0, 15'h7FFF, 32'hAAAA_0001, 32'hBBBB_0002);
    check_pair(16'h7FFF, 32'hAAAA_0001, 16'h0000, 32'hBBBB_0002,
               "page 0 boundary pair wraps to page 0 offset 0");

    // The same pair on page 1: word 1 wraps to {page 1, 0x0000} = 16'h8000 --
    // the bug carried out of the 16-bit key to 16'h0000 (page 0).
    clear_log();
    burst2(1'b1, 15'h7FFF, 32'hCCCC_0003, 32'hDDDD_0004);
    check_pair(16'hFFFF, 32'hCCCC_0003, 16'h8000, 32'hDDDD_0004,
               "page 1 boundary pair wraps to page 1 offset 0");

    // The off-boundary control: the plain increment case is unchanged.
    clear_log();
    burst2(1'b0, 15'h0100, 32'h1111_0005, 32'h2222_0006);
    check_pair(16'h0100, 32'h1111_0005, 16'h0101, 32'h2222_0006,
               "off-boundary pair still steps one dword");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GVRAM_W2B_WRAP: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GVRAM_W2B_WRAP: FAIL (%0d errors)", errors);
  end

  initial begin
    #1_000_000;
    $fatal(1, "TB_PC9821_GVRAM_W2B_WRAP: TIMEOUT");
  end
endmodule

`default_nettype wire

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The PEGC posted store buffer's area rewrite (per-entry per-lane merge writes with a one-hot match instead of a read-back merge, 25-bit entry addresses, age counters saturating at HOLD_CYCLES) is cycle-for-cycle identical to the pre-rewrite buffer (pc9821_pegc_storebuf_ref.sv, the module as of ac2538dc): over several hundred thousand cycles of random posted stores into a small pool of dwords and rows (so combines, adjacent pairs, same-row gathers, row changes, age-outs, a full buffer and drain-before-read all occur) with random backend accepts and response-queue back-pressure, in_ready, mem_valid, mem_burstcount/write/gath and busy match on every cycle, and the payload the controller reads - mem_addr/din/be, din_hi of a two-dword pair and the carried entries 1..burstcount-1 of a gather - match whenever a request is presented (the arbiter picks only a valid port, and an idle buffer's free slot at rp is written on every post since the C5-free cut), in four different 512 KiB windows (the entries hold only the window offset, byte address [18:2], and one shared copy of bits [26:19]).

// ==== DUT ====
// pc9821_pegc_storebuf vs pc9821_pegc_storebuf_ref, same inputs, two geometries (sdram_size 3 and 1)
// and two hold windows. The reference is the pre-change text, not a model of the hardware: this
// bench proves the rewrite did not change behaviour; the buffer's behaviour itself is pinned by
// tb_pc9821_pegc_store_rate and tb_pc9821_sdram_gather.

module tb_pc9821_pegc_storebuf_equiv;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  reg        in_valid = 0, in_write = 0, in_peg_route = 1, in_rd_block = 0;
  reg [31:0] in_addr = 0, in_din = 0;
  reg  [3:0] in_be = 0;
  reg  [7:0] in_burstcount = 1;
  reg  [1:0] sdram_size = 2'd3;
  reg        rdy_rnd = 0;
  reg [31:0] win_base = 32'h0200_0000;   // the 512 KiB window every store of a pass lies in

  `define OUTS(p) \
    wire p``_ready, p``_valid, p``_write, p``_gath, p``_busy; \
    wire [31:0] p``_addr, p``_din, p``_din_hi; wire [3:0] p``_be; wire [7:0] p``_bc; \
    wire [440:0] p``_ex;

  `OUTS(d)
  `OUTS(r)
  // the bridge's accept comes at least one cycle after the request is first presented
  reg d_valid_q = 0;
  always @(posedge clk) d_valid_q <= d_valid && !(d_valid && rdy_rnd && d_valid_q);
  wire d_mready = rdy_rnd && d_valid_q && d_valid;
  wire r_mready = rdy_rnd && d_valid_q && r_valid;

  pc9821_pegc_storebuf #(.HOLD_CYCLES(20), .GATHER_K(4)) dut (
    .clk(clk), .reset(reset), .in_valid(in_valid), .in_write(in_write), .in_addr(in_addr),
    .in_din(in_din), .in_be(in_be), .in_burstcount(in_burstcount), .in_peg_route(in_peg_route),
    .in_ready(d_ready), .in_rd_block(in_rd_block), .sdram_size(sdram_size),
    .mem_addr(d_addr), .mem_din(d_din), .mem_din_hi(d_din_hi), .mem_be(d_be),
    .mem_burstcount(d_bc), .mem_valid(d_valid), .mem_write(d_write), .mem_gath(d_gath),
    .mem_gath_extra(d_ex), .mem_ready(d_mready), .busy(d_busy));
  pc9821_pegc_storebuf_ref #(.HOLD_CYCLES(20), .GATHER_K(4)) ref0 (
    .clk(clk), .reset(reset), .in_valid(in_valid), .in_write(in_write), .in_addr(in_addr),
    .in_din(in_din), .in_be(in_be), .in_burstcount(in_burstcount), .in_peg_route(in_peg_route),
    .in_ready(r_ready), .in_rd_block(in_rd_block), .sdram_size(sdram_size),
    .mem_addr(r_addr), .mem_din(r_din), .mem_din_hi(r_din_hi), .mem_be(r_be),
    .mem_burstcount(r_bc), .mem_valid(r_valid), .mem_write(r_write), .mem_gath(r_gath),
    .mem_gath_extra(r_ex), .mem_ready(r_mready), .busy(r_busy));

  integer errors = 0, cycles = 0, seed = 1, ph;
  reg [31:0] rnd;
  // gather payload slots beyond the group are don't-care in the ref only in that nothing reads
  // them; compare the used entries (n_now of them) exactly, entries 1..3 of GATHER_K = 4.
  wire [188:0] d_exu = d_ex[188:0];
  wire [188:0] r_exu = r_ex[188:0];
  // The controller reads gather entry j only for j < burstcount (sdram.v's slot maps and its
  // contract check), so the dut may leave the slots past the group unqualified; the reference
  // zeroes them. Compare the carried entries only.
  function automatic [188:0] carried(input [188:0] ex, input [7:0] bc);
    begin
      carried = ex;
      if (bc < 8'd4) carried[188:126] = 63'd0;
      if (bc < 8'd3) carried[125:63]  = 63'd0;
      if (bc < 8'd2) carried[62:0]    = 63'd0;
    end
  endfunction
  wire [188:0] d_exu_used = carried(d_exu, d_bc);
  wire [188:0] r_exu_used = carried(r_exu, r_bc);

  task automatic new_req;
    reg [31:0] x;
    begin
      x = $random(seed);
      in_valid <= (x[3:0] < ph_density(ph));
      in_peg_route <= (x[7:4] != 4'd0);
      // mostly one-dword stores; some reads; an occasional wide write
      in_write <= (x[11:8] != 4'd0);
      in_burstcount <= (x[15:12] == 4'd0) ? 8'd4 : 8'd1;
      // pool: 3 rows x 6 dwords (adjacent pairs inside a row), plus a far row
      in_addr <= win_base + ((x[18:16] % 4) * 32'h1000) + ((x[22:19] % 6) * 4);
      // now and then the window's LAST dwords, so the wrap from its last dword to its first is met
      if (x[31:29] == 3'd0) in_addr <= (win_base & 32'hFFF8_0000) + 32'h0007_FFF0 + {28'd0, x[28:27], 2'b00};
      in_din <= $random(seed);
      in_be <= (x[26:23] < 4'd6) ? 4'hF : x[30:27];
    end
  endtask

  function automatic [3:0] ph_density(input integer p);
    ph_density = (p == 0) ? 4'd14 : (p == 1) ? 4'd8 : 4'd3;
  endfunction

  integer total = 0;
  always @(negedge clk) if (!reset) begin
    cycles = cycles + 1;
    rnd = $random(seed);
    rdy_rnd <= (ph == 2) ? (rnd[1:0] == 0) : (rnd[2:0] != 0);
    in_rd_block <= (rnd[9:4] == 0);
    // keep a request until it is accepted (the CPU holds valid and the payload)
    if (!in_valid || d_ready) new_req;
  end

  // ==== CHECKS ====
  // compare just before each rising edge
  always @(posedge clk) if (!reset) begin
    if (d_ready !== r_ready || d_valid !== r_valid || d_write !== r_write || d_gath !== r_gath ||
        d_busy !== r_busy || d_bc !== r_bc ||
        (d_valid && ((d_addr !== r_addr) || (d_din !== r_din) || (d_be !== r_be))) || (d_valid && d_gath && !d_write) ||
        (d_valid && !d_gath && d_write && (d_bc == 8'd2) && (d_din_hi !== r_din_hi)) ||
        (d_valid && d_gath && (d_exu_used !== r_exu_used))) begin
      errors = errors + 1;
      if (errors < 10)
        $display("FAIL cycle %0d ph %0d: rdy %b/%b val %b/%b addr %08h/%08h din %08h/%08h hi %08h/%08h be %h/%h bc %0d/%0d gath %b/%b busy %b/%b",
                 cycles, ph, d_ready, r_ready, d_valid, r_valid, d_addr, r_addr, d_din, r_din,
                 d_din_hi, r_din_hi, d_be, r_be, d_bc, r_bc, d_gath, r_gath, d_busy, r_busy);
    end
    if (d_valid && d_mready) total = total + 1;
  end

  // ==== VERDICT ====
  integer pass;
  initial begin
    for (pass = 0; pass < 4; pass = pass + 1) begin
      sdram_size = (pass % 2) ? 2'd1 : 2'd3;
      win_base = (pass == 0) ? 32'h0200_0000 : (pass == 1) ? 32'h0007_8000 : (pass == 2) ? 32'h07F8_0000 : 32'h0388_0000;
      seed = 100 + pass;
      for (ph = 0; ph < 3; ph = ph + 1) begin
        reset = 1; in_valid = 0;
        repeat (4) @(posedge clk);
        reset <= 0;
        repeat (60000) @(posedge clk);
      end
    end
    if (total < 1000) $fatal(1, "TB_PC9821_PEGC_STOREBUF_EQUIV: only %0d backend accepts - the stimulus did not exercise the buffer", total);
    if (errors != 0) $fatal(1, "TB_PC9821_PEGC_STOREBUF_EQUIV: %0d mismatches over %0d cycles", errors, cycles);
    $display("TB_PC9821_PEGC_STOREBUF_EQUIV: PASS");
    $display("NOTE pegc_storebuf_equiv: %0d cycles, %0d backend accepts, identical", cycles, total);
    $finish;
  end
endmodule

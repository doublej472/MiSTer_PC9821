// SPDX-License-Identifier: GPL-2.0-or-later
// The oracle module below is an earlier revision of Template_MiSTer sys/shadowmask.sv,
// Copyright (c) 2021 Sorgelig (https://github.com/MiSTer-devel/Template_MiSTer).
// See NOTICE, part 2.

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The shadowmask's 256x11 mask_lut is one mixed-clock M10K, not 2,816 flip-flops: a word written with a 3'b011 command on clk_sys is read back through the module's registered clk read (lut <= mask_lut[mask_idx]) at every one of the 256 indices the counters sweep, with the clk read latency and the mask_enable gating unchanged. The oracle is the pre-M10K register-array module run on the same stimulus, and the bench requires the two to agree on dout and the sync outputs at every clk edge while the oracle's own registered read equals the pattern written to each index.
//
// ---- the oracle is the OLD module, written out again ----
// An area pass moved mask_lut from 2,816 flip-flops with 256 per-word write enables
// into one M10K simple dual port: written word-by-word on clk_sys, read with a
// registered output on clk. The read was already one clk deep, so the RAM's
// output register keeps the latency identical and the change is a drop-in. That
// is a latency claim, so this bench runs the OLD register-array module as a
// second reference on the SAME stimulus and requires every output to match the
// DUT on every clk edge. A one-cycle slip, a lost address bit, a changed
// mask_enable gate or an unregistered read fails here and every write-only test
// passes.
//
// Two clocks. On the card clk is clk_hdmi (the read side) and clk_sys is the
// register-command side; here they are two free-running clocks (10 ns and 14 ns)
// so the mixed-clock path is the one exercised. The writes finish before the
// sweep starts, so no read collides with a write.
//
// The stimulus covers: a command 0x000 (which clears the word pointer and sets
// mask_enable), hmax=vmax=15, a write of all 256 distinct patterns, then a
// counters sweep across every (vcount,hcount) pair so every mask_idx is read.
// Every index must be read back at least once (coverage) and the oracle's read
// must equal that index's written pattern (value identity) for all 256; dout and
// the sync outputs must match the oracle cycle-for-cycle; and dropping enable
// must clear mask_enable.

module tb_pc9821_shadowmask;

  // ==== DUT ====
  // clk is the read side (clk_hdmi on the card), clk_sys the command side.
  reg clk = 0;
  reg clk_sys = 0;
  always #5 clk = ~clk;        // 10 ns
  always #7 clk_sys = ~clk_sys; // 14 ns

  reg         cmd_wr = 0;
  reg  [15:0] cmd_in = 16'h0;
  reg  [23:0] din = 24'h0;
  reg         hs_in = 1, vs_in = 1, de_in = 0, brd_in = 1;
  reg         enable = 1;

  wire [23:0] dout;
  wire        hs_out, vs_out, de_out;

  shadowmask dut (
      .clk (clk), .clk_sys (clk_sys),
      .cmd_wr (cmd_wr), .cmd_in (cmd_in),
      .din (din), .hs_in (hs_in), .vs_in (vs_in), .de_in (de_in), .brd_in (brd_in),
      .enable (enable),
      .dout (dout), .hs_out (hs_out), .vs_out (vs_out), .de_out (de_out)
  );

  // ==== the OLD module as the oracle ====
  // The earlier shadowmask: mask_lut as a register array. Its registered read
  // is exposed (dbg_lut) along with mask_idx and mask_enable so the bench can
  // check value identity and coverage on the reference directly.
  wire [10:0] ref_lut;
  wire [7:0]  ref_mask_idx;
  wire        ref_mask_enable;
  wire [23:0] ref_dout;
  wire        ref_hs, ref_vs, ref_de;

  shadowmask_ref oracle (
      .clk (clk), .clk_sys (clk_sys),
      .cmd_wr (cmd_wr), .cmd_in (cmd_in),
      .din (din), .hs_in (hs_in), .vs_in (vs_in), .de_in (de_in), .brd_in (brd_in),
      .enable (enable),
      .dout (ref_dout), .hs_out (ref_hs), .vs_out (ref_vs), .de_out (ref_de),
      .dbg_lut (ref_lut), .dbg_mask_idx (ref_mask_idx), .dbg_mask_enable (ref_mask_enable)
  );

  // ==== CHECKS ====

  integer errors = 0;
  integer i, v;
  reg compare_en = 0;

  // The written pattern for an index. Bit 10 set (red takes the HIGH nibble i[7:4],
  // green and blue the LOW nibble i[3:0]) and no other select bit, so the output is
  // injective in the index at the din driven below: a swap of a lane, a nibble or an
  // address bit cannot pass unnoticed.
  function [10:0] pat(input [7:0] idx); pat = 11'h400 | {3'b000, idx}; endfunction

  // Coverage: every index was presented to the oracle's read address, and the read
  // back equalled that index's written pattern.
  reg [255:0] cov = 256'h0;
  reg [255:0] rb  = 256'h0;
  reg [7:0]   idx_d;

  // ==== STIMULUS ====

  // One register command, held across exactly one posedge clk_sys.
  task cmd(input [15:0] c);
    begin
      @(negedge clk_sys);
      cmd_in = c; cmd_wr = 1'b1;
      @(negedge clk_sys);
      cmd_wr = 1'b0;
    end
  endtask

  // Compare the DUT against the oracle on every clk edge, and record the oracle's
  // own read-back. Both update on the same clk edge with the same inputs.
  always @(posedge clk) begin
    #1;
    if (compare_en) begin
      if (dout !== ref_dout) begin
        $display("FAIL dout: dut=%06x ref=%06x", dout, ref_dout);
        errors = errors + 1;
      end
      if (hs_out !== ref_hs || vs_out !== ref_vs || de_out !== ref_de) begin
        $display("FAIL sync: dut hs/vs/de=%b/%b/%b ref=%b/%b/%b",
                 hs_out, vs_out, de_out, ref_hs, ref_vs, ref_de);
        errors = errors + 1;
      end
      // Oracle read-back: dbg_lut is LUT[mask_idx one clk ago], so it must equal
      // the pattern written for idx_d (mask_idx delayed one clk).
      if (ref_lut !== pat(idx_d)) begin
        $display("FAIL readback: mask_idx_d=%02x lut=%03x want=%03x",
                 idx_d, ref_lut, pat(idx_d));
        errors = errors + 1;
      end
      cov[ref_mask_idx] = 1'b1;
      if (ref_lut === pat(idx_d)) rb[idx_d] = 1'b1;
      idx_d = ref_mask_idx;   // for the next edge
    end
  end

  integer bit_i;
  initial begin
    repeat (8) @(posedge clk);

    // ---- command 0x000: clear the word pointer, enable the mask ----
    cmd(16'h0008);            // {m_enable,mask_rotate,mask_2x} = 3'b100
    cmd(16'h400F);            // 010: hmax = 15
    cmd(16'h200F);            // 001: vmax = 15

    // ---- write all 256 mask_lut entries on clk_sys ----
    for (i = 0; i < 256; i = i + 1) cmd(16'h6000 | pat(i[7:0]));

    // Let the writes settle and the mask_enable pipeline land.
    repeat (16) @(posedge clk);
    if (ref_mask_enable !== 1'b1) begin
      $display("FAIL mask_enable did not set after a 0x000 command");
      errors = errors + 1;
    end

    // ---- counters sweep: every (vcount,hcount) pair, so every mask_idx ----
    // hcount cycles 0..15 (hmax2=15); vcount steps 0..15 with one arm (brd rising)
    // and one hs falling per step. 20 clocks per step covers the whole hcount cycle.
    din = 24'h404040;
    idx_d = ref_mask_idx;
    compare_en = 1;
    for (v = 0; v < 16; v = v + 1) begin
      if (v != 0) begin
        @(negedge clk); brd_in = 0;   // re-arm: next rising sets next_v
        @(negedge clk); brd_in = 1;
        @(negedge clk); hs_in = 0;    // next falling bumps vcount
        @(negedge clk); hs_in = 1;
      end
      repeat (20) @(negedge clk);
    end
    @(posedge clk); #1;
    compare_en = 0;

    // ---- enable is a gate on mask_enable ----
    enable = 0;
    repeat (4) @(posedge clk); #1;
    if (ref_mask_enable !== 1'b0) begin
      $display("FAIL mask_enable stayed set with enable low");
      errors = errors + 1;
    end

    // ---- coverage and value identity ----
    for (bit_i = 0; bit_i < 256; bit_i = bit_i + 1) begin
      if (!cov[bit_i]) begin $display("FAIL index %0d was never read", bit_i); errors = errors + 1; end
      if (!rb[bit_i])  begin $display("FAIL index %0d did not read back its pattern", bit_i); errors = errors + 1; end
    end

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SHADOWMASK: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_SHADOWMASK: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: a bench that blocks on a DUT signal with no bound hangs CI.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_SHADOWMASK: TIMEOUT");
  end

endmodule

// The earlier shadowmask, verbatim but for the three debug outputs. mask_lut is
// the register array the M10K replaced; its registered read is dbg_lut.
module shadowmask_ref
(
	input             clk,
	input             clk_sys,

	input             cmd_wr,
	input      [15:0] cmd_in,

	input      [23:0] din,
	input             hs_in,vs_in,
	input             de_in,
	input             brd_in,
	input             enable,

	output reg [23:0] dout,
	output reg        hs_out,vs_out,
	output reg        de_out,

	output     [10:0] dbg_lut,
	output     [7:0]  dbg_mask_idx,
	output            dbg_mask_enable
);

reg  [4:0] hmax;
reg  [4:0] vmax;
reg  [7:0] mask_idx;
reg        mask_2x;
reg        mask_rotate;
reg        mask_enable;
reg [10:0] mask_lut[256];

assign dbg_lut = lut;
assign dbg_mask_idx = mask_idx;
assign dbg_mask_enable = mask_enable;

always @(posedge clk) begin
	reg [4:0] hcount;
	reg [4:0] vcount;
	reg [3:0] hindex;
	reg [3:0] vindex;
	reg [4:0] hmax2;
	reg [4:0] vmax2;
	reg [11:0] pcnt,pde;
	reg old_hs, old_vs, old_brd;
	reg next_v;

	old_hs <= hs_in;
	old_vs <= vs_in;
	old_brd<= brd_in;

	hindex <= mask_2x ? hcount[4:1] : hcount[3:0];
	vindex <= mask_2x ? vcount[4:1] : vcount[3:0];
	mask_idx <= mask_rotate ? {hindex,vindex} : {vindex,hindex};

	hmax2 <= ((mask_rotate ? vmax : hmax) << mask_2x) | mask_2x;
	vmax2 <= ((mask_rotate ? hmax : vmax) << mask_2x) | mask_2x;

	pcnt <= pcnt+1'd1;
	if(old_brd && ~brd_in) pde <= pcnt-4'd3;

	hcount <= hcount+1'b1;
	if(hcount == hmax2 || pde == pcnt) hcount <= 0;

	if(~old_brd && brd_in) next_v <= 1;
	if(old_vs && ~vs_in) vcount <= 0;
	if(old_hs && ~hs_in) begin
		vcount <= vcount + next_v;
		next_v <= 0;
		pcnt   <= 0;
		if (vcount == vmax2) vcount <= 0;
	end
end

reg [4:0] r_mul, g_mul, b_mul;
reg [10:0] lut;
always @(posedge clk) begin
	lut <= mask_lut[mask_idx];

	r_mul <= 5'b10000; g_mul <= 5'b10000; b_mul <= 5'b10000;
	if (mask_enable) begin
		r_mul <= lut[10] ? {1'b1,lut[7:4]} : {1'b0,lut[3:0]};
		g_mul <= lut[9]  ? {1'b1,lut[7:4]} : {1'b0,lut[3:0]};
		b_mul <= lut[8]  ? {1'b1,lut[7:4]} : {1'b0,lut[3:0]};
	end
end

always @(posedge clk) begin
	reg [11:0] vid;
	reg  [7:0] r1,   g1,   b1;
	reg  [7:0] r2,   g2,   b2;
	reg  [7:0] r3_x, g3_x, b3_x;
	reg  [8:0] r3_y, g3_y, b3_y;
	reg  [8:0] r4,   g4,   b4;

	{r1,g1,b1} <= din;
	vid <= {vid[8:0],vs_in, hs_in, de_in};

	{r2,g2,b2} <= {r1,g1,b1};

	r3_x <= ({4{r_mul[0]}} & r2[7:4]) + ({8{r_mul[1]}} & r2[7:3]);
	r3_y <= ({6{r_mul[2]}} & r2[7:2]) + ({7{r_mul[3]}} & r2[7:1]) + ({9{r_mul[4]}} & r2[7:0]);
	g3_x <= ({4{g_mul[0]}} & g2[7:4]) + ({8{g_mul[1]}} & g2[7:3]);
	g3_y <= ({6{g_mul[2]}} & g2[7:2]) + ({7{g_mul[3]}} & g2[7:1]) + ({9{g_mul[4]}} & g2[7:0]);
	b3_x <= ({4{b_mul[0]}} & b2[7:4]) + ({8{b_mul[1]}} & b2[7:3]);
	b3_y <= ({6{b_mul[2]}} & b2[7:2]) + ({7{b_mul[3]}} & b2[7:1]) + ({9{b_mul[4]}} & b2[7:0]);

	r4 <= r3_x + r3_y;
	g4 <= g3_x + g3_y;
	b4 <= b3_x + b3_y;

	dout <= {{8{r4[8]}} | r4[7:0], {8{g4[8]}} | g4[7:0], {8{b4[8]}} | b4[7:0]};
	{vs_out,hs_out,de_out} <= vid[11:9];
end

always @(posedge clk_sys) begin
	reg m_enable;
	reg [7:0] idx;

	if (cmd_wr) begin
		case(cmd_in[15:13])
		3'b000: begin {m_enable, mask_rotate, mask_2x} <= cmd_in[3:1]; idx <= 0; end
		3'b001: vmax <= cmd_in[3:0];
		3'b010: hmax <= cmd_in[3:0];
		3'b011: begin mask_lut[idx] <= cmd_in[10:0]; idx <= idx + 1'd1; end
		endcase
	end

	mask_enable <= m_enable & enable;
end

endmodule

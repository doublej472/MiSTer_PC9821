`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The FM + ADPCM-A junction never reaches the die's 18-bit wrap: driven at its extremes (all 24 FM operator slots at the 14-bit rails with the 16-bit wrapped six-drum bus at its rails, ADPCM-B unwired), jt08_acc's wide accumulator equals the die's 18-bit masked sum (YM2608-LLE fmopna_impl.c ac_fm_accm1 & 0x3ffff) -- +131047 and -131072 exactly, the 18-bit range's own ends -- and its output equals the die's output-shifter rail (+32767 / -32768), so the core's wide sum + clamp16 and the die's 18-bit wrap + shifter rail are the same function over every reachable input.
//
// WHY. The question (a retired open-work item) was whether the die's 18-bit junction mask can wrap where the core's 20-bit
// sum rails. Arithmetic from the die (fmopna_impl.c): each operator contributes
// ((op_output & 0x1fff) >> 1), sign-extended from bit 13 (:5347-5349), i.e. -4096..+4095; the
// algorithm sum adds at most 4 operators per channel and 6 channels, so the FM total is
// -98304..+98280; the six-drum bus is masked to 16 bits (:5370, rss_sample_shift sign-extended
// :5365-5367) and sign-extended into the junction (:5309-5311), -32768..+32767. The sum is
// -131072..+131047, which is EXACTLY the 18-bit two's-complement range (-131072..+131071): the
// mask (:5321) is inert. The output shifter then rails on the top three bits of the 18-bit sum
// (:5403 ac_shifter_top = (accm >> 15) & 7; clipl = top==6 || (top&6)==4, cliph = top==1 ||
// (top&6)==2, :5460-5461), i.e. +-32768 -- the core's clamp. Only an ADPCM-B contribution
// (ad_output << 2, +-16384, :5394-5396) could push the sum past the range, and ADPCM-B is
// unwired in this core.
//
// THE EXPECTED VALUES ARE THE DIE'S. The model below re-implements the die's arithmetic from
// the cited lines, with the 18-bit mask, and is compared with the shipped jt08_acc.

// ==== DUT ====
// jt08_acc, the shipped FM+ADPCM-A junction, driven slot by slot.

module tb_pc9821_opna_junction_range;
  reg clk = 0;
  always #5 clk = ~clk;

  integer errors = 0;
  task automatic fail(input string m);
    begin errors = errors + 1; $display("MISMATCH: %0s", m); end
  endtask

  reg                clk_en = 0;
  reg                zero   = 0;
  reg  signed [13:0] op_result = 0;
  reg  [2:0]         cur_ch = 0;
  reg  [1:0]         cur_op = 0;
  reg  signed [19:0] adpcmA = 0;
  wire signed [19:0] left, right;

  jt08_acc dut(
    .clk(clk), .clk_en(clk_en), .cen(1'b1), .op_result(op_result), .rl(2'b11),
    .zero(zero), .s1_enters(1'b0), .s2_enters(1'b0), .s3_enters(1'b0), .s4_enters(1'b0),
    .cur_ch(cur_ch), .cur_op(cur_op), .alg(3'd7),
    .adpcmA_l(adpcmA), .adpcmA_r(adpcmA), .adpcmB_l(16'sd0), .adpcmB_r(16'sd0),
    .left(left), .right(right));

  wire signed [19:0] wide_l = dut.u_left.snd;

  // ---- the die's arithmetic (fmopna_impl.c) ----
  // one operator's contribution, :5347-5349
  function automatic integer die_op(input integer op14);
    integer o;
    begin
      o = op14 & 'h3fff;
      die_op = (o & 'h1fff) >> 1;
      if (o & 'h2000) die_op = die_op | 'h3f000;
    end
  endfunction
  // 18-bit two's complement -> integer
  function automatic integer s18(input integer v);
    integer t;
    begin t = v & 'h3ffff; s18 = (t >= 'h20000) ? t - 'h40000 : t; end
  endfunction
  // the die's frame sum: drum bus (16-bit wrapped) sign-extended (:5309-5311), then 24 operator
  // terms, masked to 18 bits (:5321)
  function automatic integer die_sum(input integer op14, input integer drum16);
    integer a, i;
    begin
      a = drum16 & 'hffff;
      if (a & 'h8000) a = a | 'h30000;
      for (i = 0; i < 24; i = i + 1) a = (a + die_op(op14)) & 'h3ffff;
      die_sum = s18(a);
    end
  endfunction
  // the output shifter's rail, :5403 and :5460-5461
  function automatic integer die_rail(input integer sum18);
    integer top, t;
    begin
      t = sum18 & 'h3ffff;
      top = (t >> 15) & 7;
      if (top == 1 || (top & 6) == 2) die_rail = 32767;
      else if (top == 6 || (top & 6) == 4) die_rail = -32768;
      else begin
        die_rail = t & 'hffff;
        if (die_rail >= 32768) die_rail = die_rail - 65536;
      end
    end
  endfunction

  localparam integer CH [0:5] = '{0, 1, 2, 4, 5, 6};

  // one frame of 24 operator slots; zero marks slot {op0,ch0}
  task automatic frame(input integer op14, input integer drum16);
    integer s;
    begin
      for (s = 0; s < 24; s = s + 1) begin
        cur_op    = s / 6;
        cur_ch    = CH[s % 6];
        op_result = op14;
        adpcmA    = drum16;
        zero      = (s == 0);
        @(negedge clk); clk_en = 1;
        @(negedge clk); clk_en = 0; zero = 0;
        repeat (3) @(negedge clk);
      end
    end
  endtask

  task automatic check(input string name, input integer op14, input integer drum16);
    integer e_sum, e_rail;
    begin
      frame(op14, drum16);
      frame(op14, drum16);
      frame(op14, drum16);
      e_sum  = die_sum(op14, drum16);
      e_rail = die_rail(e_sum);
      $display("  %0s: op=%0d drums=%0d  die sum=%0d rail=%0d | dut wide=%0d out=%0d",
               name, op14, drum16, e_sum, e_rail, wide_l, left);
      if (wide_l !== e_sum)  fail($sformatf("%0s: wide sum %0d, die's 18-bit sum %0d", name, wide_l, e_sum));
      if (left   !== e_rail) fail($sformatf("%0s: output %0d, die's shifter rail %0d", name, left, e_rail));
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (4) @(negedge clk);
    check("all-max positive", 8191, 32767);     // die sum +131047, the top of the range
    check("all-max negative", -8192, -32768);   // die sum -131072, the 18-bit minimum exactly
    check("FM high, drums low", 8191, -32768);  // +65512
    check("FM low, drums high", -8192, 32767);  // -65537
    check("just under +rail", 1000, 20700);     // +32700, between the rails (a rail set early shows here)
    check("just over -rail", -1000, -20700);    // -32700
    check("in range", 100, 1000);               // below the rails
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_JUNCTION_RANGE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_JUNCTION_RANGE: FAIL (%0d errors)", errors);
  end

  initial begin
    #5_000_000;
    $fatal(1, "TB_PC9821_OPNA_JUNCTION_RANGE: TIMEOUT");
  end
endmodule

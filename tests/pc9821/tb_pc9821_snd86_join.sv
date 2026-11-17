`timescale 1ns/1ps

// tb_pc9821_snd86_join - the -86 sample bus handed to sample_86_cdc comes from registers.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_SND86_JOIN: the PC-9801-86 join that feeds z486_mister.sv's sample_86_cdc (pc9821_snd86_join) presents a bus that no source change reaches inside the clk_sys cycle it happens in: with the YM2608 and 86-PCM outputs changed on the falling edge, between two rising edges, the bus never moves before the next rising edge, so the handshake's holding register (which loads the bus on an edge unrelated to the sources) only ever sees a path from registers through one 20-bit add, never the 86-PCM volume multiply - the release c03da744 seed 3 fit had 17 failing setup endpoints from pc9821_pcm86 hold_l through that multiply into the holding register, worst -0.79 ns; and the bus is the exact wide sum opna + sign-extended pcm of the values present at the previous rising edge (one clk_sys later than before, both devices alike), over random values, both ends of the bus's reachable range (+71,863 and -71,865: the clamped FM+ADPCM rail, the AC SSG peak and the PCM rail) and a width stress past it (+255,996 and -239,616, still inside 20 bits) on both channels.
//
// ---- where each expectation comes from ----
// The value: the join's definition (pc9821_system.sv before this change: snd86 = opna_snd +
// sign-extended pcm86_snd, 20 bits, unclamped), delayed one clk_sys. The structural check: the
// handshake's holding register (src/common/cdc_vector_handshake_continuous.sv) loads data_in on
// the clk_sys edge after its request flag drops, unrelated to when a source changed, so the
// bus must not depend combinationally on the sources. A zero-delay simulation cannot show a
// setup miss itself; it can show whether a source change reaches the bus inside the cycle,
// which is the path the miss was on.
//
// FAIL-FIRST: the mutations in tests/pc9821/mutations.json that put the pre-fix join back (the
// sum taken from the live inputs) or register only one term fail CHK-1.

module tb_pc9821_snd86_join;
  localparam real CYCLE_NS = 11.1111;   // clk_sys at the base profile's 90 MHz

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;

  reg  signed [19:0] opna_l = 0, opna_r = 0;
  reg  signed [15:0] pcm_l = 0, pcm_r = 0;
  wire signed [19:0] sum_l, sum_r;

  // ==== DUT ====
  pc9821_snd86_join dut (
    .clk(clk), .opna_l(opna_l), .opna_r(opna_r), .pcm_l(pcm_l), .pcm_r(pcm_r),
    .sum_l(sum_l), .sum_r(sum_r)
  );

  // ==== CHECKS ====
  integer errors = 0, comb_moves = 0, value_bad = 0, edges = 0;
  reg signed [19:0] exp_l, exp_r, held_l, held_r;
  function automatic signed [19:0] join_sum(input signed [19:0] o, input signed [15:0] p);
    join_sum = o + {{4{p[15]}}, p};
  endfunction

  // The YM2608's output is the jt08_acc junction clamped to 16 bits, sign-extended, plus the
  // AC-coupled SSG (pc9821_opna.sv), about [-39,097, +39,096]; the bench drives both ends of the
  // bus that range gives with the 86-PCM, and a labelled width stress past it.
  task automatic drive(input signed [19:0] ol, input signed [19:0] or_, input signed [15:0] pl,
                       input signed [15:0] pr);
    begin
      @(negedge clk);
      held_l = sum_l; held_r = sum_r;
      opna_l = ol; opna_r = or_; pcm_l = pl; pcm_r = pr;
      // CHK-1: nothing moves before the next rising edge
      #(CYCLE_NS/2 - 0.5);
      if (sum_l !== held_l || sum_r !== held_r) begin
        comb_moves++;
        if (comb_moves <= 4)
          $display("CHK-1 FAIL: bus moved mid-cycle L %0d -> %0d R %0d -> %0d", held_l, sum_l, held_r, sum_r);
      end
      @(posedge clk); #0.1;
      edges++;
      // CHK-2: the exact sum of the values present at that edge
      exp_l = join_sum(ol, pl); exp_r = join_sum(or_, pr);
      if (sum_l !== exp_l || sum_r !== exp_r) begin
        value_bad++;
        if (value_bad <= 4)
          $display("CHK-2 FAIL: L %0d (exp %0d) R %0d (exp %0d)", sum_l, exp_l, sum_r, exp_r);
      end
    end
  endtask

  integer i;
  integer seed = 32'h5EED_86A0;   // $random(seed) advances it: one reproducible sequence
  initial begin
    repeat (3) @(posedge clk);
    // the two ends of the bus's REACHABLE range: the YM2608 output is the FM+ADPCM sum clamped to
    // [-32,768, +32,767] at jt08_acc plus pc9821_opna's AC SSG term (the high-pass of a 0..6,329
    // join term), so it spans about [-39,097, +39,096]; the PCM rail adds [-32,768, +32,767]
    drive(20'sd39096, 20'sd39096, 16'sd32767, 16'sd32767);       // +71,863
    drive(20'sd39096, -20'sd39097, 16'sd32767, -16'sd32768);     // +71,863 / -71,865
    drive(-20'sd39097, 20'sd39096, -16'sd32768, 16'sd32767);
    // a WIDTH STRESS past anything the clamped YM2608 can produce, still inside 20 bits: the
    // join's add must not wrap whatever its inputs
    drive(20'sd223229, -20'sd206848, 16'sd32767, -16'sd32768);   // +255,996 / -239,616
    drive(-20'sd206848, 20'sd223229, -16'sd32768, 16'sd32767);
    drive(20'sd0, 20'sd0, 16'sd0, 16'sd0);
    for (i = 0; i < 20000; i = i + 1) begin
      drive($signed(20'($random(seed))) >>> 1, $signed(20'($random(seed))) >>> 1,
            16'($random(seed)), 16'($random(seed)));
    end
    // a sign walk: every PCM bit and every OPNA bit alone
    for (i = 0; i < 16; i = i + 1) drive(20'sd0, 20'sd0, 16'sd1 <<< i, -(16'sd1 <<< i));
    for (i = 0; i < 18; i = i + 1) drive(20'sd1 <<< i, -(20'sd1 <<< i), 16'sd0, 16'sd0);

    // ==== VERDICT ====
    if (comb_moves != 0)
      begin errors++; $display("FAIL snd86_join: %0d of %0d source changes reached the bus inside their cycle", comb_moves, edges); end
    if (value_bad != 0)
      begin errors++; $display("FAIL snd86_join: %0d of %0d edges with a wrong sum", value_bad, edges); end
    $display("TB_PC9821_SND86_JOIN: %0d source changes, %0d mid-cycle bus moves, %0d wrong sums",
             edges, comb_moves, value_bad);
    if (errors != 0) $fatal(1, "TB_PC9821_SND86_JOIN: FAIL (%0d errors)", errors);
    $display("TB_PC9821_SND86_JOIN: PASS");
    $finish;
  end

  initial begin
    #5_000_000;
    $fatal(1, "TB_PC9821_SND86_JOIN: watchdog expired");
  end
endmodule

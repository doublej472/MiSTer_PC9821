`timescale 1ns/1ps

// tb_pc9821_pcm86_cdc - the -86 sample bus must cross into CLK_AUDIO with no bit-mix.
//
// ==== WHAT THIS PROVES ====
// With the -86 card's sample bus crossing from clk_sys (50 MHz) to CLK_AUDIO (24.576 MHz) through the held cdc_vector_handshake_continuous that z486_mister.sv now instantiates, exactly as the CD path already does, every 86-PCM sample pair driven on the bus arrives at the destination intact and in order - including the full-scale 0x7FFFF and 0x80000 OF THE 20-BIT BUS and a walk of every bit - and the destination never holds a value whose L and R halves differ, which is the old/new bit-mix a per-bit or unsynchronised crossing produces; the crossing's latency is bounded and printed. The L/R-halves check can only see a LOGIC-level mix (a half registered on another strobe); a 2-state zero-delay simulation cannot produce a metastable capture, so the unsynchronised-crossing case it names is argued from the structure, not observed.
//
// With the -86 card's sample bus crossing from clk_sys (50 MHz) to CLK_AUDIO (24.576 MHz) through the held cdc_vector_handshake_continuous that z486_mister.sv now instantiates, exactly as the CD path already does, every 86-PCM sample pair driven on the bus arrives at the destination intact and in order - including the full-scale 0x7FFFF and 0x80000 and a walk of every bit - and the destination never holds a value whose L and R halves differ, which is the old/new bit-mix a per-bit or unsynchronised crossing produces; the crossing's latency is bounded and printed.
//
// ---- the bench's own account of where each expectation comes from ----
// The crossing is the -86 card's sample bus (sample_86_l/r) leaving clk_sys and being
// sampled by pc9821_audio_volume on CLK_AUDIO, which is the framework's asynchronous
// 24.576 MHz PLL. The crackle was measured there: the bus is a clk_sys combinational
// vector, the two clocks are in different SDC groups (sys/sys_top.sdc), and a raw wire lets
// a CLK_AUDIO edge catch the bus mid-flight and mix the old and new halves. This bench
// drives the exact module the fix instantiates, at the real clock ratio, and pins:
//
//  1. ARRIVAL. Every value presented is delivered. The handshake holds each value until the
//     destination has accepted it, so no sample is dropped even though clk_in is faster
//     than clk_out. [source: cdc_vector_handshake_continuous.sv's hold register + ack round trip]
//
//  2. INTEGRITY. The delivered value equals the driven value, bit for bit, including the
//     two full-scale codes and a one-hot walk of all twenty bits. [source: the module passes
//     data_in through unchanged; z486_mister.sv drives {sample_86_l, sample_86_r} on one vector]
//
//  3. NO HALF-MIX. Every driven pair has L == R, and the vector is captured and held as a
//     WHOLE, so the destination must never show a value whose two 20-bit halves differ. A
//     per-bit synchroniser - or the raw wire this replaces - produces exactly the old-L /
//     new-R value this monitor rejects. [source: the module's data_hold_clk_in captures the
//     whole vector on one clk_in edge, and data_out updates only after the 1-bit handshake]
//
//  4. ORDER. The stimulus advances only after the destination holds the current value, so a
//     skipped or reordered value fails the arrival check rather than passing unnoticed.
//
//  5. BOUNDED, MEASURED LATENCY. The source-to-destination delay is a few CLK_AUDIO cycles
//     (two synchroniser stages plus one destination flop), far below the ~18 us between the
//     OPNA's samples, and it is printed rather than assumed.
//
//  6. THE DROP CEILING, MEASURED. The module has no FIFO and no back-pressure: it holds one value
//     and re-arms only after its ack round trip, so a source changing faster than that round trip
//     is silently subsampled (repeated and skipped, never torn). The -86 bus is NOT an audio-rate
//     signal - the FM accumulator's register enable is clk_en = cen/6 = 1.3312 MHz at the reset
//     prescaler (src/opna/jt12/hdl/jt12_div.v:60-73, 91-98; cen = 7.9872 MHz,
//     src/opna/pc9821_opna.sv:88) = one change per 38 clk_sys cycles - so the margin above the
//     source has to be measured rather than assumed. A sweep drives a distinct value every P
//     clk_sys and counts the destination's transitions: P = 38 (the OPNA's own rate) must deliver
//     every value, P = 4 (10x over) must drop, and the smallest P that still delivers them all is
//     printed as the ceiling. [source: the module's new_value/ack loop; AUDIO_OUTPUT_AUDIT.md (b)]
//
// THE WIDTH IS THE SHIPPED ONE. W below is 20, the bus z486_mister.sv crosses since a194031e
// widened the -86 chain (A-1): an audit of the crossing against the framework's audio output
// contract (AUDIO_OUTPUT_AUDIT.md, D2) found this bench still exercising 16x2, which is the
// pre-A-1 instance. The module is width-generic, so the contract checks were never wrong, but
// the evidence now spans every bit of the vector the design actually crosses.
//
// Nothing here asserts a magnitude taken from a capture; the checks are the module's stated
// contract and the sample values are chosen, not measured.

module tb_pc9821_pcm86_cdc;
  // clk_sys is 50 MHz (CLOCK_RATE_HZ) and CLK_AUDIO is 24.576 MHz (sys/pll_audio.v), so the
  // crossing is exercised at the real fast-to-slow ratio.
  localparam integer CYCLE_SYS_NS   = 20;
  // 1e9 / 24.576e6 = 40.6901 ns; the half period keeps the ratio real rather than rounded to 2:1,
  // so the fast-to-slow corner this crossing lives in is what is tested.
  localparam real    CYCLE_AUDIO_NS = 40.6901;

  reg clk_sys = 0;
  reg clk_audio = 0;
  always #(CYCLE_SYS_NS/2)   clk_sys   = ~clk_sys;
  always #(CYCLE_AUDIO_NS/2) clk_audio = ~clk_audio;

  // ==== DUT ====
  // The crossing exactly as z486_mister.sv wires it: clk_sys to CLK_AUDIO, a 20x2-bit vector
  // (z486_mister.sv:1458-1462, the -86 card's sample bus).
  localparam integer W = 20;                 // bits per channel, as shipped
  reg  [2*W-1:0] data_in  = 0;
  wire [2*W-1:0] data_out;

  cdc_vector_handshake_continuous #(.DATA_WIDTH(2*W)) sample_86_cdc (
      .clk_in  (clk_sys),
      .clk_out (clk_audio),
      .data_in (data_in),
      .data_out(data_out)
  );

  // ==== CHECKS ====
  integer errors = 0;
  task automatic fail(input [1023:0] what);
    begin
      errors = errors + 1;
      $display("FAIL pcm86_cdc: %0s", what);
    end
  endtask

  // CHECK 3, kept as a concurrent monitor: the destination must never hold a value whose two
  // 20-bit halves differ, because every driven pair has L == R. Read on the negedge so it sees
  // the value the clk_audio flop wrote on the preceding posedge.
  integer half_mix = 0;
  always @(negedge clk_audio) begin
    if (data_out[2*W-1:W] !== data_out[W-1:0]) half_mix = half_mix + 1;
  end

  // CHECK 6's counter: the destination's own transitions. The vector is written whole, so one
  // delivered value is exactly one transition; a value the ack loop could not fit produces none.
  integer distinct = 0;
  reg [2*W-1:0] data_out_q = 0;
  always @(posedge clk_audio) begin
    if (data_out !== data_out_q) distinct = distinct + 1;
    data_out_q <= data_out;
  end

  // ==== STIMULUS ====
  // Zero, a one-hot walk of every bit position, both full-scale codes, -1, and two alternating
  // patterns - the values whose halves must survive intact.
  localparam integer N = W + 7;
  reg [W-1:0] vals [0:N-1];
  time       t0;
  integer    i, guard, arrived = 0;
  real       max_lat_ns = 0.0;

  // CHECK 6's stimulus: CEIL_N distinct values driven one per P clk_sys, and the periods swept.
  localparam integer CEIL_N = 24;
  integer    p, ceil_p = 0, opna_distinct = 0, fast_distinct = 0;
  integer    sweep [0:20];

  initial begin
    vals[0] = 20'h00000;
    for (i = 0; i < W; i = i + 1) vals[i+1] = 20'd1 << i;   // one-hot, all 20 positions
    vals[W+1] = 20'h7FFFF;   // positive full scale
    vals[W+2] = 20'h80000;   // negative full scale
    vals[W+3] = 20'hFFFFF;   // -1
    vals[W+4] = 20'hAAAAA;
    vals[W+5] = 20'h55555;
    vals[W+6] = 20'h12345;

    @(posedge clk_sys);
    for (i = 0; i < N; i = i + 1) begin
      @(posedge clk_sys);
      data_in = {vals[i], vals[i]};          // a full 86-PCM sample pair, L == R
      t0 = $time;
      guard = 0;
      while ((data_out !== data_in) && (guard < 400)) begin
        @(posedge clk_audio);
        guard = guard + 1;
      end
      if (data_out !== data_in) begin
        fail("an 86-PCM sample pair never arrived at the CLK_AUDIO side");
        $display("       driven=%h  destination=%h", data_in, data_out);
      end else begin
        arrived = arrived + 1;
        if (($time - t0) > max_lat_ns) max_lat_ns = $time - t0;
      end
      // Let the handshake ack and go idle, as it is for 18 us between the OPNA's samples,
      // so each value's latency is the crossing's own and not a back-to-back queue delay.
      repeat (20) @(posedge clk_sys);
    end

    // ==== CHECK 6: THE DROP CEILING ====
    // P = 38 clk_sys is 760 ns, the first period at or above the OPNA's 1.3312 MHz register
    // enable (751 ns). P = 4 (80 ns) is 10x a fast round trip, so it must drop: the module keeps
    // no queue between the hold register and the ack.
    sweep[0]=4; sweep[1]=5; sweep[2]=6; sweep[3]=7; sweep[4]=8; sweep[5]=9; sweep[6]=10;
    sweep[7]=11; sweep[8]=12; sweep[9]=13; sweep[10]=14; sweep[11]=16; sweep[12]=18;
    sweep[13]=20; sweep[14]=22; sweep[15]=24; sweep[16]=28; sweep[17]=32; sweep[18]=36;
    sweep[19]=38; sweep[20]=40;
    for (p = 0; p <= 20; p = p + 1) begin
      // A sentinel distinct from the sweep values, landed before the count starts, so the first
      // delivered sweep value is itself one transition.
      @(posedge clk_sys);
      data_in = {20'h3FFFF, 20'h3FFFF};
      repeat (40) @(posedge clk_sys);
      distinct = 0;
      for (i = 0; i < CEIL_N; i = i + 1) begin
        repeat (sweep[p]) @(posedge clk_sys);
        data_in = {20'h100 + i[19:0], 20'h100 + i[19:0]};
      end
      repeat (40) @(posedge clk_sys);        // let the last value land and the loop re-arm
      if (distinct >= CEIL_N && ceil_p == 0) ceil_p = sweep[p];
      if (sweep[p] == 38) opna_distinct = distinct;
      if (sweep[p] == 4)  fast_distinct = distinct;
    end

    if (opna_distinct < CEIL_N) begin
      fail("the crossing dropped a value at the OPNA's own 1.3312 MHz register rate (P=38)");
      $display("       %0d/%0d values delivered at P=38", opna_distinct, CEIL_N);
    end
    if (fast_distinct >= CEIL_N) begin
      fail("a 12.5 MHz source was delivered whole -- the ack loop is not bounding the rate");
      $display("       %0d/%0d values delivered at P=4", fast_distinct, CEIL_N);
    end

    // ==== VERDICT ====
    if (half_mix != 0) begin
      fail("the destination held a value with differing L/R halves -- a mid-flight capture");
      $display("       %0d half-mixed captures", half_mix);
    end

    $display("TB_PC9821_PCM86_CDC: %0d/%0d sample pairs arrived intact, order preserved",
             arrived, N);
    $display("TB_PC9821_PCM86_CDC: crossing latency <= %0.1f ns (%0.1f CLK_AUDIO cycles)",
             max_lat_ns, max_lat_ns / CYCLE_AUDIO_NS);
    $display("TB_PC9821_PCM86_CDC: %0d/%0d delivered at P=38 (the OPNA's 1.3312 MHz rate)",
             opna_distinct, CEIL_N);
    $display("TB_PC9821_PCM86_CDC: %0d/%0d delivered at P=4 (10x that rate) -- no back-pressure",
             fast_distinct, CEIL_N);
    $display("TB_PC9821_PCM86_CDC: fastest whole-delivery period %0d clk_sys = %0.2f MHz source",
             ceil_p, ceil_p ? (1000.0 / (ceil_p * CYCLE_SYS_NS)) : 0.0);
    if (errors != 0) $fatal(1, "TB_PC9821_PCM86_CDC: FAIL (%0d errors)", errors);
    $display("TB_PC9821_PCM86_CDC: PASS");
    $finish;
  end

  // WATCHDOG: a regression that wedges an unmatched wait must fail, not hang.
  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_PCM86_CDC: watchdog expired");
  end
endmodule

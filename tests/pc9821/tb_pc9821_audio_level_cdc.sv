`timescale 1ns/1ps

// tb_pc9821_audio_level_cdc - the OSD Audio page's level codes must reach CLK_AUDIO as whole words.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_AUDIO_LEVEL_CDC: the OSD Audio page's three 5-bit gain codes (PC-9801-86, Beeper, and CD audio on both channels) cross from clk_sys (90 MHz, base) to CLK_AUDIO (24.576 MHz) as one word through the held cdc_vector_handshake_continuous inside the real pc9821_audio_mix (level_cdc), so with every bit of the clk_sys source codes given its own routing delay (0.3 to 8.3 ns, inside one clk_sys period, the most a same-domain path may take) and each field stepped through every neighbouring pair of its eight entries (31/30/29/28/27/26/25/0, both directions, the 7-to-0 wrap included) hundreds of times at an incommensurate rate, alone and all three at once, the CLK_AUDIO side never holds a code that was not driven in any field - no 28-to-27 step ever shows 31 (0 dB) or 24, no 25-to-0 step a stray gain - a field that did not step never moves, the CD's L and R codes never differ, every driven code arrives, every CLK_AUDIO load of the handshake finds its clk_sys hold word stable for longer than that skew, the latency is bounded and printed, and from power-up until the first code crosses the -86 and beeper codes read 31 (0 dB, the level those sources had before the page) and the CD code 0 (Off, as its own crossing powered up).
//
// ---- where each expectation comes from ----
// The oracle is the stimulus itself: the bench drives only the eight codes of each field
// (pc9821_osd's level_code table: entries 0..6 -> 31..25, entry 7 -> 0), one step at a time, so
// ANY other value at the destination is a word assembled from two codes - the old/new bit mix
// an unsynchronised multi-bit crossing produces when a CLK_AUDIO edge lands while the source
// word is still settling. A 2-state zero-delay simulation cannot settle bits at different times
// by itself, so the bench gives each bit its own transport delay on the wire into the module:
// that is the skew real routing has, and it is legal inside clk_sys (STA guarantees each bit
// settles within one clk_sys period, so every clk_sys capture is clean). Only a capture by the
// OTHER clock can see the mix. The handshake captures the word on clk_sys and holds it stable
// for the destination's whole capture window (data_hold_clk_in, loaded only while the 1-bit
// new_value is low and held until the ack returns), so the destination never sees a settling
// word. The power-up values are the handshake's all-zero output decoded: the -86 and beeper
// fields cross inverted (pc9821_audio_mix), the CD field as is.
//
// FAIL-FIRST: the two mutations in tests/pc9821/mutations.json that turn the handshake back into
// a raw crossing (the destination loading the live source word, or loading on every CLK_AUDIO
// edge) make the INTERMEDIATE and STABLE-CAPTURE checks fail.

module tb_pc9821_audio_level_cdc;
  // clk_sys at the base profile's 90 MHz (build_profile.py base) and CLK_AUDIO at 24.576 MHz
  // (sys/pll_audio.v): the real, incommensurate ratio.
  localparam real CYCLE_SYS_NS   = 11.1111;
  localparam real CYCLE_AUDIO_NS = 40.6901;
  localparam real MAX_SKEW_NS    = 8.3;

  reg clk_sys = 0;
  reg clk_audio = 0;
  always #(CYCLE_SYS_NS/2)   clk_sys   = ~clk_sys;
  always #(CYCLE_AUDIO_NS/2) clk_audio = ~clk_audio;

  // ==== the source: the clk_sys codes and their per-bit routing delays ====
  // Field f = 0 (PC-9801-86), 1 (Beeper), 2 (CD audio).
  reg  [14:0] code_q = {5'd31, 5'd31, 5'd31};     // {cd, beep, 86}, the clk_sys registers
  wire [14:0] code_wire;
  genvar gb;
  generate for (gb = 0; gb < 15; gb = gb + 1) begin : g_skew
    // 0.3 ns .. 8.3 ns, each bit of a field on a different delay, interleaved across fields
    localparam real D = 0.3 + 8.0 * ((gb * 7) % 15) / 14.0;
    assign #(D) code_wire[gb] = code_q[gb];
  end endgenerate

  // ==== DUT ====
  // The real mix; only its level crossing is observed.
  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_audio_mix u_mix (
    .clk_sys     (clk_sys),
    .clk_audio   (clk_audio),
    .snd86_level (code_wire[4:0]),
    .beep_level  (code_wire[9:5]),
    .vol_cd_l    (code_wire[14:10]),
    .vol_cd_r    (code_wire[14:10]),
    .vol_master_l(5'd31), .vol_master_r(5'd31),
    .vol_voice_l (5'd31), .vol_voice_r (5'd31),
    .vol_midi_l  (5'd0),  .vol_midi_r  (5'd0),
    .vol_spk     (2'd3),
    .vol_en_cd   (2'b11),
    .sample_86_l (20'd0), .sample_86_r (20'd0),
    .cdda_l      (16'd0), .cdda_r      (16'd0),
    .speaker     (1'b0),
    .beep_vol    (2'd0),
    .mix_dry_l   (),
    .mix_dry_r   (),
    .valid       ()
  );
  /* verilator lint_on PINCONNECTEMPTY */
  // The CLK_AUDIO side of the crossing, decoded as the module decodes it.
  wire [4:0] a86  = u_mix.snd86_level_a;
  wire [4:0] abp  = u_mix.beep_level_a;
  wire [4:0] acdl = u_mix.vol_cd_l_a;
  wire [4:0] acdr = u_mix.vol_cd_r_a;
  function automatic [4:0] dest(input integer f);
    dest = (f == 0) ? a86 : (f == 1) ? abp : acdl;
  endfunction

  // ==== CHECKS ====
  integer errors = 0;
  // The eight codes of each field, in list order.
  reg [4:0] codes [0:7];
  initial begin
    codes[0] = 5'd31; codes[1] = 5'd30; codes[2] = 5'd29; codes[3] = 5'd28;
    codes[4] = 5'd27; codes[5] = 5'd26; codes[6] = 5'd25; codes[7] = 5'd0;
  end

  // Per field: the previous and the current code driven, the only two the destination may hold
  // while a step is in flight. The monitor starts once the power-up word has crossed.
  reg [4:0] prev_c [0:2];
  reg [4:0] cur_c  [0:2];
  initial for (int f = 0; f < 3; f++) begin prev_c[f] = 5'd31; cur_c[f] = 5'd31; end
  reg       check_on = 0;
  integer intermediate = 0, lr_split = 0, samples = 0;
  reg [4:0] first_bad = 5'd0;
  always @(negedge clk_audio) if (check_on) begin
    samples = samples + 1;
    if (acdl !== acdr) lr_split = lr_split + 1;
    for (int f = 0; f < 3; f++)
      if (dest(f) !== prev_c[f] && dest(f) !== cur_c[f]) begin
        if (intermediate == 0) first_bad = dest(f);
        intermediate = intermediate + 1;
      end
  end

  // The handshake's OWN crossing path is data_hold_clk_in (clk_sys) -> data_out (CLK_AUDIO), and
  // its wires have the same kind of skew. The zero-delay module cannot show a mix there, so the
  // protocol property is checked directly: every CLK_AUDIO edge that loads a new data_out must
  // find the hold word stable for longer than the largest per-bit delay above. The hold register
  // is a clk_sys flop, so it changes only at a clk_sys rising edge: a change seen at the
  // following falling edge happened half a period earlier. hc0/hc1 are the latest two change
  // times.
  realtime hc0 = 0.0, hc1 = 0.0;
  reg [19:0] hold_prev = 20'd0;
  always @(negedge clk_sys) begin
    if (u_mix.level_cdc.data_hold_clk_in !== hold_prev) begin
      hc1 = hc0; hc0 = $realtime - CYCLE_SYS_NS / 2;
    end
    hold_prev = u_mix.level_cdc.data_hold_clk_in;
  end
  integer  unstable_capture = 0;
  realtime min_age = 1.0e9;
  reg [19:0] out_prev = 20'd0;
  always @(posedge clk_audio) begin
    automatic realtime p = $realtime;
    automatic realtime age;
    #6;   // past this edge's update and the next clk_sys falling edge, which records a change at <= p
    if (check_on && u_mix.level_audio !== out_prev) begin
      age = p - ((hc0 <= p) ? hc0 : hc1);
      if (age < min_age) min_age = age;
      if (age <= MAX_SKEW_NS) unstable_capture = unstable_capture + 1;
    end
    out_prev = u_mix.level_audio;
  end

  // ==== STIMULUS ====
  integer steps = 0, arrived = 0, guard;
  real    t0, max_lat_ns = 0.0;
  function automatic bit all_arrived();
    all_arrived = (a86 === cur_c[0]) && (abp === cur_c[1]) && (acdl === cur_c[2]);
  endfunction
  // Drive new codes on the fields `mask` selects (bit f = field f) on one clk_sys edge.
  task automatic drive(input [2:0] mask, input [4:0] c0, input [4:0] c1, input [4:0] c2);
    begin
      @(posedge clk_sys);
      for (int f = 0; f < 3; f++) prev_c[f] = cur_c[f];
      if (mask[0]) cur_c[0] = c0;
      if (mask[1]) cur_c[1] = c1;
      if (mask[2]) cur_c[2] = c2;
      code_q <= {cur_c[2], cur_c[1], cur_c[0]};
      steps = steps + 1;
    end
  endtask
  // Step and wait (bounded) for the CLK_AUDIO side to hold it, then a gap that is not a
  // multiple of either period, so the step's phase against CLK_AUDIO walks the whole period.
  task automatic step_to(input [2:0] mask, input [4:0] c0, input [4:0] c1, input [4:0] c2,
                         input integer gap);
    begin
      drive(mask, c0, c1, c2);
      t0 = $realtime;
      guard = 0;
      while (!all_arrived() && guard < 200) begin @(posedge clk_audio); guard++; end
      if (all_arrived()) begin
        arrived = arrived + 1;
        if ($realtime - t0 > max_lat_ns) max_lat_ns = $realtime - t0;
      end
      repeat (gap) @(posedge clk_sys);
      for (int f = 0; f < 3; f++) prev_c[f] = cur_c[f];
    end
  endtask
  // The same on a fixed clk_sys schedule, NOT started from the previous arrival, so its phase
  // against the handshake's own loop is uncorrelated. The gap (>= 32 clk_sys = 356 ns) is longer
  // than the crossing's measured latency, so the codes must have arrived by its end.
  task automatic step_free(input [2:0] mask, input [4:0] c0, input [4:0] c1, input [4:0] c2,
                           input integer gap);
    begin
      drive(mask, c0, c1, c2);
      repeat (gap) @(posedge clk_sys);
      if (all_arrived()) arrived = arrived + 1;
      for (int f = 0; f < 3; f++) prev_c[f] = cur_c[f];
    end
  endtask

  initial begin
    // power-up: before the first handshake completes, the decoded codes are 31/31/0
    #1;
    if (a86 !== 5'd31 || abp !== 5'd31 || acdl !== 5'd0 || acdr !== 5'd0) begin
      errors++;
      $display("FAIL audio_level_cdc: power-up codes 86/beep/cd = %0d/%0d/%0d, want 31/31/0",
               a86, abp, acdl);
    end
    repeat (64) @(posedge clk_sys);
    if (!all_arrived()) begin errors++; $display("FAIL audio_level_cdc: the power-up codes never crossed"); end
    check_on = 1;
    for (int r = 0; r < 20; r++) begin
      for (int f = 0; f < 3; f++) begin
        // one field down the list and round the wrap (31 .. 25, 0, then 0 -> 31), then back up,
        // the other two held at a code of their own
        for (int k = 1; k <= 8; k++)
          step_to(3'(1 << f), codes[k % 8], codes[k % 8], codes[k % 8], 7 + (r * 3 + k + f) % 11);
        for (int k = 7; k >= 0; k--)
          step_to(3'(1 << f), codes[k], codes[k], codes[k], 9 + (r * 5 + k + f) % 13);
        step_to(3'(1 << f), codes[(r + f) % 8], codes[(r + f) % 8], codes[(r + f) % 8], 5);
      end
    end
    for (int r = 0; r < 60; r++) begin
      // all three fields step together, each to a different neighbour
      for (int k = 1; k <= 8; k++)
        step_free(3'b111, codes[k % 8], codes[(k + 3) % 8], codes[(k + 6) % 8],
                  32 + (r * 7 + k * 3) % 29);
      for (int k = 7; k >= 0; k--)
        step_free(3'(1 << (k % 3)), codes[k], codes[(k + 5) % 8], codes[(k + 2) % 8],
                  33 + (r * 11 + k * 5) % 31);
    end

    // ==== VERDICT ====
    if (intermediate != 0)
      begin errors++; $display("FAIL audio_level_cdc: %0d field samples held a code never driven (first %0d)",
                               intermediate, first_bad); end
    if (lr_split != 0)
      begin errors++; $display("FAIL audio_level_cdc: %0d samples with the CD L and R codes differing", lr_split); end
    if (unstable_capture != 0)
      begin errors++; $display("FAIL audio_level_cdc: %0d CLK_AUDIO captures of a hold word changed within %0.1f ns",
                               unstable_capture, MAX_SKEW_NS); end
    if (arrived != steps)
      begin errors++; $display("FAIL audio_level_cdc: %0d of %0d driven steps arrived", arrived, steps); end
    $display("TB_PC9821_AUDIO_LEVEL_CDC: %0d steps, %0d arrived, %0d CLK_AUDIO samples, %0d intermediate",
             steps, arrived, samples, intermediate);
    $display("TB_PC9821_AUDIO_LEVEL_CDC: the hold word was stable >= %0.1f ns before every load", min_age);
    $display("TB_PC9821_AUDIO_LEVEL_CDC: crossing latency <= %0.1f ns (%0.1f CLK_AUDIO cycles)",
             max_lat_ns, max_lat_ns / CYCLE_AUDIO_NS);
    if (errors != 0) $fatal(1, "TB_PC9821_AUDIO_LEVEL_CDC: FAIL (%0d errors)", errors);
    $display("TB_PC9821_AUDIO_LEVEL_CDC: PASS");
    $finish;
  end

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_AUDIO_LEVEL_CDC: watchdog expired");
  end
endmodule

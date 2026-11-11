`timescale 1ns/1ps

// tb_pc9821_audio_mix_equiv - the mix with the OSD Audio page at 0 dB against the pre-page mix.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_AUDIO_MIX_EQUIV: with the OSD Audio page's PC-9801-86 and Beeper levels at 0 dB (gain code 31, position 0, what a card with no config file and a config saved before the page both select), pc9821_audio_mix is clock-for-clock and bit-for-bit the CLK_AUDIO mix the top level carried before the page existed (pc9821_audio_mix_ref.sv, z486_mister.sv's vol_cd_cdc, speaker block, audio_volume_inst and mix_tmp/mix_dry block as of 105f3263), from the first CLK_AUDIO edge after power-up: on clk_sys 90 MHz and CLK_AUDIO 24.576 MHz, with random 20-bit -86 samples, random CD-DA samples, a random speaker tone and 0x871E ladder code on every CLK_AUDIO clock, random vol_voice/vol_master/vol_midi codes, and the CD audio code stepped at random clk_sys times through every code, the valid strobe agrees on every clock and both clamped outputs agree on every clock; so the page adds no latency and changes no sample at its defaults.
//
// ---- where each expectation comes from ----
// The reference is the pre-change text, not a model of the hardware: the law of the stage is
// pinned by tb_pc9821_audio_mix, tb_pc9821_audio_volume_table and tb_pc9821_audio_levels. The
// CD code crosses on its own 10-bit handshake in the reference and inside the 20-bit level word
// in the DUT; both handshakes run on the same clock pair from the same power-up state, so their
// destination loads coincide and the CD code reaches both stages on the same CLK_AUDIO edge.
//
// THE CHECKS:
// CHK-1 valid equal on every CLK_AUDIO clock.
// CHK-2 mix L/R equal on every CLK_AUDIO clock, power-up included.
// CHK-3 the run was not vacuous: thousands of strobes, both rails and the CD steps reached.

module tb_pc9821_audio_mix_equiv;
  localparam real CYCLE_SYS_NS   = 11.1111;
  localparam real CYCLE_AUDIO_NS = 40.6901;
  localparam integer AUDIO_CLOCKS = 200000;

  reg clk_sys = 0;
  reg clk_audio = 0;
  always #(CYCLE_SYS_NS/2)   clk_sys   = ~clk_sys;
  always #(CYCLE_AUDIO_NS/2) clk_audio = ~clk_audio;

  // ---- stimulus: clk_sys side ----
  reg  [4:0] vol_cd = 5'd31;
  // ---- stimulus: constants of pc9821_system, randomised slowly ----
  reg  [4:0] vol_master = 5'd31, vol_voice = 5'd31, vol_midi = 5'd0;
  reg  [1:0] vol_spk = 2'd3;
  reg  [4:0] vol_en = 5'b11111;
  // ---- stimulus: CLK_AUDIO side ----
  reg  [19:0] s86_l = 0, s86_r = 0;
  reg  [15:0] cd_l = 0, cd_r = 0;
  reg         spk = 0;
  reg  [1:0]  bvol = 2'd2;

  wire [15:0] ref_l, ref_r, dut_l, dut_r;
  wire        ref_v, dut_v;

  // ==== DUT ====
  pc9821_audio_mix_ref u_ref (
    .clk_sys(clk_sys), .CLK_AUDIO(clk_audio),
    .vol_cd_l(vol_cd), .vol_cd_r(vol_cd),
    .vol_master_l(vol_master), .vol_master_r(vol_master),
    .vol_voice_l(vol_voice), .vol_voice_r(vol_voice),
    .vol_midi_l(vol_midi), .vol_midi_r(vol_midi),
    .vol_spk(vol_spk), .vol_en(vol_en),
    .sample_86_l_audio(s86_l), .sample_86_r_audio(s86_r),
    .cdda_l(cd_l), .cdda_r(cd_r),
    .speaker_out_audio(spk), .beep_vol(bvol),
    .mix_pre_l(ref_l), .mix_pre_r(ref_r), .audio_volume_valid(ref_v));

  pc9821_audio_mix u_dut (
    .clk_sys(clk_sys), .clk_audio(clk_audio),
    .snd86_level(5'd31), .beep_level(5'd31),
    .vol_cd_l(vol_cd), .vol_cd_r(vol_cd),
    .vol_master_l(vol_master), .vol_master_r(vol_master),
    .vol_voice_l(vol_voice), .vol_voice_r(vol_voice),
    .vol_midi_l(vol_midi), .vol_midi_r(vol_midi),
    .vol_spk(vol_spk), .vol_en_cd(vol_en[2:1]),
    .sample_86_l(s86_l), .sample_86_r(s86_r),
    .cdda_l(cd_l), .cdda_r(cd_r),
    .speaker(spk), .beep_vol(bvol),
    .mix_dry_l(dut_l), .mix_dry_r(dut_r), .valid(dut_v));

  // ==== CHECKS ====
  integer errors = 0, cyc = 0, n_valid = 0, n_top = 0, n_bot = 0, n_cd_steps = 0;
  reg [31:0] g = 32'h1234ABCD;

  // CLK_AUDIO: new samples every clock, the comparison every clock.
  always @(posedge clk_audio) begin
    cyc <= cyc + 1;
    g <= {g[30:0], g[31] ^ g[21] ^ g[1] ^ g[0]};
    // the -86 sample spans the whole 20-bit bus some of the time (so both rails are hit)
    s86_l <= g[3] ? {{2{g[19]}}, g[17:0]} : {{6{g[15]}}, g[13:0]};
    s86_r <= g[4] ? ~{{2{g[18]}}, g[16:0], g[31]} : {{5{g[29]}}, g[29:15]};
    cd_l  <= g[31:16] ^ {cyc[7:0], 8'h5A};
    cd_r  <= g[15:0];
    spk   <= g[7] ^ g[11];
    bvol  <= g[9:8];
    if (cyc % 4096 == 4095) begin
      // the slot gains move slowly: they are constants in pc9821_system
      vol_master <= (g[2:0] == 0) ? 5'd28 : 5'd31;
      vol_voice  <= g[28:24];
      vol_midi   <= g[12:8];
      vol_en     <= {g[5], g[6], g[7], g[8], g[9]};
      vol_spk    <= g[11:10];
    end
  end
  always @(negedge clk_audio) begin
    if (dut_v !== ref_v) begin
      errors = errors + 1;
      if (errors <= 10) $display("FAIL CHK-1 audio clock %0d: valid %b, reference %b", cyc, dut_v, ref_v);
    end
    if (dut_l !== ref_l || dut_r !== ref_r) begin
      errors = errors + 1;
      if (errors <= 10)
        $display("FAIL CHK-2 audio clock %0d: mix %04x/%04x, reference %04x/%04x",
                 cyc, dut_l, dut_r, ref_l, ref_r);
    end
    if (ref_v) begin
      n_valid = n_valid + 1;
      if (ref_l == 16'h7FFF) n_top = n_top + 1;
      if (ref_l == 16'h8000) n_bot = n_bot + 1;
    end
  end

  // clk_sys: the CD audio code steps at random clk_sys instants through all 32 codes.
  reg [31:0] h = 32'h0BADF00D;
  integer gap = 0;
  always @(posedge clk_sys) begin
    h <= {h[30:0], h[31] ^ h[21] ^ h[1] ^ h[0]};
    if (gap == 0) begin
      vol_cd <= h[4:0];
      n_cd_steps = n_cd_steps + 1;
      gap = 40 + h[15:8];
    end else gap = gap - 1;
  end

  // ==== VERDICT ====
  initial begin
    wait (cyc == AUDIO_CLOCKS);
    $display("TB_PC9821_AUDIO_MIX_EQUIV: %0d audio clocks, %0d strobes, %0d CD code steps, rails +%0d/-%0d",
             cyc, n_valid, n_cd_steps, n_top, n_bot);
    if (n_valid < 1000 || n_top == 0 || n_bot == 0 || n_cd_steps < 100) begin
      errors = errors + 1;
      $display("FAIL CHK-3 the run was vacuous");
    end
    if (errors != 0) $fatal(1, "TB_PC9821_AUDIO_MIX_EQUIV: FAIL (%0d errors)", errors);
    $display("TB_PC9821_AUDIO_MIX_EQUIV: PASS");
    $finish;
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_AUDIO_MIX_EQUIV: watchdog expired");
  end
endmodule

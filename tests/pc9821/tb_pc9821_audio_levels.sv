`timescale 1ns/1ps

// tb_pc9821_audio_levels - the OSD Audio page's levels, each on its own source.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_AUDIO_LEVELS: the OSD Audio page's three levels reach the mix through the real pc9821_osd decode and the real pc9821_audio_mix (its clk_sys-to-CLK_AUDIO level crossing, the ten-channel volume stage and the one clamp), on clk_sys 90 MHz and CLK_AUDIO 24.576 MHz, and each acts on its own source only: with the PC-9801-86 board, the beeper and CD audio all sounding at once, every one of the eight positions of each field (0 dB to -12 dB in 2 dB steps, Off) scales that source by round(65536 * 10^(-dB/20)) / 65536 (floored, as the Q16 stage takes it) while the other two fields sit at other positions and their sources come out at exactly their own levels, on both channels; Off removes exactly that source (the sum is exactly the other two); the -86 level is in series with pc9821_system's vol_voice gain (vol_voice -6 dB and a -N dB level give -(6+N) dB), the guest's master gain still scales the whole sum before the clamp, and all 32 gain codes of each source's level, driven directly, give that source alone the law's gain (the beeper's ladder beep_vol * 1024 times it, at each of the three ladder steps).
//
// WHERE THE EXPECTED VALUES COME FROM. The gain law, not the RTL: a level of -N dB multiplies by
// 10^(-N/20), quantised to the Q16 gain round(65536 * 10^(-N/20)) (0 dB is exactly 65536, Off
// exactly 0), and the stage floors the product (sample * G) >> 16. The beeper's 0 dB amplitude
// is NP2kai's linear ladder, beep_vol * 1024 (sound/beepg.c:113-114 `samp *= vol;`). A code c of
// the stage is 2 * (31 - c) dB down. The sources are constants chosen distinct on each channel,
// so a level applied to the wrong source, or to both, moves the sum.
//
// THE CHECKS:
// CHK-1 each field, each position, the other two at other positions: mix = the three sources
//       each at its own level (L and R).
// CHK-2 Off on one field: the mix is exactly the other two sources.
// CHK-3 vol_voice at -6 dB: the -86 level adds to it (the slot's own gain is not replaced).
// CHK-4 vol_master at -6 dB: the master stage scales the levelled sum before the clamp.
// CHK-5 all 32 codes of each level, each source alone (a second mix, its codes driven directly).
//
// PASS when every sampled mix equals the law; FAIL names the field, the position or code and
// both values.

module tb_pc9821_audio_levels;
  localparam real CYCLE_SYS_NS   = 11.1111;   // clk_sys at the base profile's 90 MHz
  localparam real CYCLE_AUDIO_NS = 40.6901;   // CLK_AUDIO, 24.576 MHz (sys/pll_audio.v)

  reg clk_sys = 0;
  reg clk_audio = 0;
  always #(CYCLE_SYS_NS/2)   clk_sys   = ~clk_sys;
  always #(CYCLE_AUDIO_NS/2) clk_audio = ~clk_audio;

  // ==== the sources (CLK_AUDIO side), distinct on each channel ====
  localparam integer S86_L = 12345, S86_R = -9876;
  localparam integer CD_L  = 7001,  CD_R  = -6003;
  reg  [1:0] beep_vol = 2'd3;
  reg        speaker  = 1'b1;

  // ==== DUT ====
  // DUT 1: the OSD decode and the mix, as z486_mister.sv wires them.
  reg  [2:0] pos86 = 3'd0, posbp = 3'd0, poscd = 3'd0;
  wire [4:0] code86, codebp, codecd;
  pc9821_osd #(.CD_AUDIO_EN(1'b1)) u_osd (
    .osd_ram_size    (3'd0),
    .osd_gdc_clock   (1'b0),
    .osd_kbd_layout  (1'b0),
    .osd_snd86_level (pos86),
    .osd_beep_level  (posbp),
    .osd_cd_volume   (poscd),
    .ram_size_code   (),
    .gdc_clock_5m    (),
    .kbd_layout_jis  (),
    .snd86_level_code(code86),
    .beep_level_code (codebp),
    .cd_volume_code  (codecd)
  );

  reg  [4:0] vol_master = 5'd31;
  reg  [4:0] vol_voice  = 5'd31;
  wire [15:0] mix_l, mix_r;
  wire        valid;
  pc9821_audio_mix u_mix (
    .clk_sys     (clk_sys),
    .clk_audio   (clk_audio),
    .snd86_level (code86),
    .beep_level  (codebp),
    .vol_cd_l    (codecd),          // pc9821_system: vol_cd_l/r = cd_volume_code with CD audio
    .vol_cd_r    (codecd),
    .vol_master_l(vol_master),
    .vol_master_r(vol_master),
    .vol_voice_l (vol_voice),
    .vol_voice_r (vol_voice),
    .vol_midi_l  (5'd0),
    .vol_midi_r  (5'd0),
    .vol_spk     (2'd3),
    .vol_en_cd   (2'b11),
    .sample_86_l (20'(S86_L)),
    .sample_86_r (20'(S86_R)),
    .cdda_l      (16'(CD_L)),
    .cdda_r      (16'(CD_R)),
    .speaker     (speaker),
    .beep_vol    (beep_vol),
    .mix_dry_l   (mix_l),
    .mix_dry_r   (mix_r),
    .valid       (valid)
  );

  // DUT 2: the mix alone, its level codes driven directly (CHK-5).
  reg  [4:0] d86 = 5'd0, dbp = 5'd0, dcd = 5'd0;
  reg  [1:0] bv2 = 2'd0;
  reg        on86 = 0, oncd = 0;
  wire [15:0] mix2_l, mix2_r;
  wire        valid2;
  pc9821_audio_mix u_mix2 (
    .clk_sys     (clk_sys),
    .clk_audio   (clk_audio),
    .snd86_level (d86),
    .beep_level  (dbp),
    .vol_cd_l    (dcd),
    .vol_cd_r    (dcd),
    .vol_master_l(5'd31),
    .vol_master_r(5'd31),
    .vol_voice_l (5'd31),
    .vol_voice_r (5'd31),
    .vol_midi_l  (5'd0),
    .vol_midi_r  (5'd0),
    .vol_spk     (2'd3),
    .vol_en_cd   (2'b11),
    .sample_86_l (on86 ? 20'(S86_L) : 20'd0),
    .sample_86_r (on86 ? 20'(S86_R) : 20'd0),
    .cdda_l      (oncd ? 16'(CD_L) : 16'd0),
    .cdda_r      (oncd ? 16'(CD_R) : 16'd0),
    .speaker     (1'b1),
    .beep_vol    (bv2),
    .mix_dry_l   (mix2_l),
    .mix_dry_r   (mix2_r),
    .valid       (valid2)
  );

  // ==== the law ====
  // Q16 gain of an attenuation of `db` dB (db < 0: Off).
  function automatic longint gain_db(input integer db);
    real g;
    begin
      if (db < 0) gain_db = 0;
      else if (db == 0) gain_db = 65536;
      else begin
        g = 65536.0 * (10.0 ** (-db / 20.0));
        gain_db = longint'($rtoi(g + 0.5));
      end
    end
  endfunction
  // A stage code's attenuation (code 0: Off).
  function automatic integer db_of_code(input integer code);
    db_of_code = (code == 0) ? -1 : 2 * (31 - code);
  endfunction
  // A list position's attenuation (the page's list: 0..12 dB in 2 dB steps, then Off).
  function automatic integer db_of_pos(input integer pos);
    db_of_pos = (pos == 7) ? -1 : 2 * pos;
  endfunction
  function automatic longint scale(input longint s, input longint g);
    scale = (s * g) >>> 16;   // the stage's Q16 product, floored
  endfunction
  function automatic longint clamp16(input longint v);
    clamp16 = (v > 32767) ? 32767 : (v < -32768) ? -32768 : v;
  endfunction

  // ==== CHECKS ====
  integer errors = 0, checks = 0;

  // Wait for the level crossing and three passes of the ten-channel stage (mix_tmp -> master ->
  // mix_dry), then require the next three strobes to carry the expected pair.
  task automatic expect_mix(input [8*48-1:0] what, input integer idx,
                            input longint want_l, input longint want_r, input bit second);
    reg [15:0] gl, gr;
    begin
      #3000;
      repeat (3) begin
        do @(posedge clk_audio); while (second ? !valid2 : !valid);
        #1;
        gl = second ? mix2_l : mix_l;
        gr = second ? mix2_r : mix_r;
        checks = checks + 1;
        if ($signed(gl) !== 16'(clamp16(want_l)) || $signed(gr) !== 16'(clamp16(want_r))) begin
          errors = errors + 1;
          if (errors <= 20)
            $display("FAIL %0s [%0d]: mix L/R = %0d/%0d, want %0d/%0d", what, idx,
                     $signed(gl), $signed(gr), clamp16(want_l), clamp16(want_r));
        end
      end
    end
  endtask

  // The three sources at their levels (dB, -1 = Off), with vol_voice and vol_master in dB.
  function automatic longint want_sum(input bit left, input integer db86, input integer dbbp,
                                      input integer dbcd);
    longint s;
    begin
      s = scale(left ? S86_L : S86_R, gain_db(db86))
        + scale(longint'(beep_vol) * 1024, gain_db(dbbp))
        + scale(left ? CD_L : CD_R, gain_db(dbcd));
      want_sum = s;
    end
  endfunction

  integer p, q, k, d1, d2, d3, b;
  longint wl, wr;

  initial begin
    #2000;

    // ---- CHK-1 / CHK-2: each field walks its list, the others elsewhere ----
    for (p = 0; p < 8; p = p + 1) begin
      pos86 = p[2:0]; posbp = 3'((p + 3) % 8); poscd = 3'((p + 5) % 8);
      d1 = db_of_pos(p); d2 = db_of_pos((p + 3) % 8); d3 = db_of_pos((p + 5) % 8);
      expect_mix(p == 7 ? "CHK-2 PC-9801-86 Off" : "CHK-1 PC-9801-86 position", p,
                 want_sum(1, d1, d2, d3), want_sum(0, d1, d2, d3), 0);
    end
    for (p = 0; p < 8; p = p + 1) begin
      posbp = p[2:0]; pos86 = 3'((p + 2) % 8); poscd = 3'((p + 6) % 8);
      d2 = db_of_pos(p); d1 = db_of_pos((p + 2) % 8); d3 = db_of_pos((p + 6) % 8);
      expect_mix(p == 7 ? "CHK-2 Beeper Off" : "CHK-1 Beeper position", p,
                 want_sum(1, d1, d2, d3), want_sum(0, d1, d2, d3), 0);
    end
    for (p = 0; p < 8; p = p + 1) begin
      poscd = p[2:0]; pos86 = 3'((p + 4) % 8); posbp = 3'((p + 1) % 8);
      d3 = db_of_pos(p); d1 = db_of_pos((p + 4) % 8); d2 = db_of_pos((p + 1) % 8);
      expect_mix(p == 7 ? "CHK-2 CD audio Off" : "CHK-1 CD audio position", p,
                 want_sum(1, d1, d2, d3), want_sum(0, d1, d2, d3), 0);
    end
    // every source at 0 dB: the plain sum
    pos86 = 0; posbp = 0; poscd = 0;
    expect_mix("CHK-1 all at 0 dB", 0, S86_L + 3072 + CD_L, S86_R + 3072 + CD_R, 0);

    // ---- CHK-3: vol_voice -6 dB in series with the -86 level ----
    vol_voice = 5'd28;
    for (p = 0; p < 8; p = p + 1) begin
      pos86 = p[2:0]; posbp = 3'd1; poscd = 3'd2;
      d1 = (p == 7) ? -1 : 6 + db_of_pos(p);
      expect_mix("CHK-3 vol_voice -6 dB + PC-9801-86 position", p,
                 want_sum(1, d1, 2, 4), want_sum(0, d1, 2, 4), 0);
    end
    vol_voice = 5'd31;

    // ---- CHK-4: vol_master -6 dB scales the levelled sum ----
    vol_master = 5'd28;
    pos86 = 3'd1; posbp = 3'd4; poscd = 3'd6;
    wl = scale(want_sum(1, 2, 8, 12), gain_db(6));
    wr = scale(want_sum(0, 2, 8, 12), gain_db(6));
    expect_mix("CHK-4 vol_master -6 dB", 0, wl, wr, 0);
    vol_master = 5'd31;

    // ---- CHK-5: every code of each level, each source alone ----
    on86 = 1; oncd = 0; bv2 = 2'd0; dbp = 5'd31; dcd = 5'd31;
    for (k = 0; k < 32; k = k + 1) begin
      d86 = k[4:0];
      expect_mix("CHK-5 PC-9801-86 code", k, scale(S86_L, gain_db(db_of_code(k))),
                 scale(S86_R, gain_db(db_of_code(k))), 1);
    end
    on86 = 0; oncd = 1; d86 = 5'd31;
    for (k = 0; k < 32; k = k + 1) begin
      dcd = k[4:0];
      expect_mix("CHK-5 CD audio code", k, scale(CD_L, gain_db(db_of_code(k))),
                 scale(CD_R, gain_db(db_of_code(k))), 1);
    end
    oncd = 0; dcd = 5'd31;
    for (b = 0; b < 4; b = b + 1) begin
      bv2 = b[1:0];
      for (k = 0; k < 32; k = k + 1) begin
        dbp = k[4:0];
        wl = scale(longint'(b) * 1024, gain_db(db_of_code(k)));
        expect_mix("CHK-5 Beeper (ladder step x 32 + code)", b * 32 + k, wl, wl, 1);
      end
    end

    // ==== VERDICT ====
    $display("TB_PC9821_AUDIO_LEVELS: %0d strobes checked, %0d differ", checks, errors);
    if (errors != 0) $fatal(1, "TB_PC9821_AUDIO_LEVELS: FAIL (%0d errors)", errors);
    $display("TB_PC9821_AUDIO_LEVELS: PASS");
    $finish;
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_AUDIO_LEVELS: watchdog expired");
  end
endmodule

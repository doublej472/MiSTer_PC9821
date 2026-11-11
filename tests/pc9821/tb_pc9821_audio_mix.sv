// tb_pc9821_audio_mix - the -86 card's sample must reach the mixer's master output,
// and the CLK_AUDIO final mix must be the single-clamp sum the references have.
//
// ==== WHAT THIS PROVES ====
// The PC-9801-86's sample reaches AUDIO_L, and the volume stage obeys the law at its three broken points: with the mixer wired exactly as pc9821_audio_mix wires it at the OSD Audio page's 0 dB - the same ten-channel sb_volume concat and the same volumes pc9821_system.sv drives, INCLUDING both vol_cd ends - 5'd31 (the OSD CD audio volume field's 0 dB step) and 5'd0 (its Off step, and the constant without CD audio, pc9821_system.sv CDROM_AUDIO_EN; F6 asked for the muted arm) - a sample on the -86 slot comes out bit-identical at unity through the real pc9821_audio_volume, volume code 0 is TRUE MUTE (a full-scale CD-DA sample at vol_cd 0 contributes EXACTLY zero through the module and at mix_dry, both polarities - NP2kai volume-0 is exact 0, sound/beepg.c:161-163), and MASTER SCALING LANDS BEFORE THE FINAL SATURATION (NP2kai scales every source by vol_master pre-sum, sound/fmboard.c:103-133): at master code 28 (-6 dB) the over-rail sum +40000 comes out +20047 = floor(40000*32846/2^16) UNSATURATED and -40000 comes out -20048, where the old post-clamp master emitted +16422/-16423 of clipped audio turned down. It also pins the final DAC's arithmetic (datapaths.md F1/F2): spk + the -86 stream + CD sum WIDE (20-bit, no wrap) and saturate ONCE at mix_dry on the master-scaled sum - a positive overflow clamps to 0x7FFF (the pre-fix 17-bit mix_tmp wrapped and the saturator emitted 0x8000: wrong rail AND polarity), the sum swept through 65530..65545 stays on the +rail across the wrap boundary, a large negative clamps to 0x8000, and a wide (-86-scale) sample_86 crosses pc9821_audio_volume unclipped at unity to be clipped exactly once at the DAC.
//
// The PC-9801-86's sample reaches AUDIO_L at the WARRANTED VALUE, not merely nonzero:
// the ten-channel sb_volume chain runs with the volumes pc9821_system.sv hard-wires
// (vol_master/vol_voice = 31 = the gain table's 0 dB UNITY, pc9821_audio_volume.sv's
// gain_lut: volume 31 -> gain 0x10000 so the slot output is the sample BIT-IDENTICALLY),
// so a known sample on the -86 slot must come out at the SAME value at the slot output
// and at the mixer's master channel, and every OTHER channel output must be EXACTLY
// zero. A wrong gain, a 10x gain, a wrong volume pairing or a swapped channel/concat
// moves the value or lands the sample on a checked-zero channel and fails by name.
// And the FINAL DAC's arithmetic is the authentic one:
// the sum of speaker + the -86 stream + CD is computed WIDE and saturated ONCE,
// symmetrically, at mix_dry - ymfm's clamp16 / NP2kai's _saturation_s16 junction -
// so a POSITIVE overflow clamps to +32767 (never inverts to 0x8000 through a wrap)
// and a wide intermediate (the FM+ADPCM+SSG join: the FM+ADPCM sum is clamped at
// the jt08_acc junction and the SSG is added after it, so the join itself can still
// pass 16 bits) is clipped by the DAC and nowhere else.
//
// ==== WARRANT (the wiring copy is re-sourced, not self-referenced) ====
// The slot/channel assignment and the ten-channel concat order follow the MiSTer
// framework's sound.v channel order (the sb_volume contract pc9821_audio_mix implements)
// and NP2kai's -86 -> soundout routing (the OPNA/86 mix is the `soundout` sum at the
// DAC); the volumes are pc9821_system.sv's own hard-wires. The expected values are
// COMPUTED from the gain law (volume 31 = unity, documented in the gain table), not
// measured from this tree's outputs. Residual, named: the mixer junction shape itself
// is the framework's sound.v contract transcribed here (the bench cannot build z486_mister,
// which needs the framework) - the machine's AUDIO_L/R response to a known -86 sample is
// the real Xe10 capture still owed (capture-pending), so the RATIO side of the chain
// is pinned to the framework's documented gain law rather than to hardware.
//
// ==== DUT ====
// sb_volume (src/soc/sound/sound.v's contract in src/pc9821/audio/pc9821_audio_volume.sv)
// with the real ten-channel wiring, and the framework mixer's combinational lines.
// NOT the top level: that needs the framework, so this bench pins the wiring, which is
// where a card with working ports would hide. The mixer's sum/saturate copy is
// byte-for-byte the shipped pc9821_audio_mix block and the checks below are the golden
// model, so the pre-fix block (17-bit mix_tmp wrapping at 65536 and the (^mix[16:15])
// saturator clamping a positive overflow to 0x8000) fails them - the fail-first for F2 -
// and the widened one passes.
//
// ==== CHECKS ====
// CHK-0 the SHIPPED volume constants, and volume code 0 is TRUE MUTE:
//       vol_cd is 5'd0 exactly as pc9821_system.sv drives it without CD audio and at the
//       OSD CD audio volume's Off step (this bench used
//       to claim "EXACTLY as hard-wired" while wiring 5'd31), and a
//       FULL-SCALE CD-DA sample must contribute EXACTLY zero through the real
//       pc9821_audio_volume and at mix_dry, both polarities. NP2kai's volume-0
//       paths are exact zeros (sound/beepg.c:161-163 gates on vol,
//       sound/beepg.c:57/113 are linear multipliers, cbus/ideio.c:1737-1745
//       scales CD-DA by a linear davolume*vol_master product): code 0 is mute,
//       never a -62 dB floor. The pre-fix gain_lut[0] = 16'h0034 leaks
//       +25/-26 LSB at full scale and fails these checks by name.
// CHK-1 the -86 card's sample reaches the sb slot output AT UNITY (sb_l == sb_r == 4000,
//       the sample bit-identically: volume 31 is gain 0x10000).
// CHK-2 the mixer's master output carries the same warranted value (single contributor,
//       wide sum, no saturation at 4000).
// CHK-3 every other channel output is EXACTLY zero (a swapped concat moves the sample
//       onto one of these and fails here).
// CHK-4 F2 positive rail: spk 16384 + snd86 0x7FFF + cd 0x7FFF = 81918 saturates to
//       0x7FFF (pre-fix the 17-bit mix_tmp wraps to -49154 and the saturator emits
//       0x8000 - the wrong rail AND the wrong polarity).
// CHK-5 F2 sweep: the sum swept through 65530..65545 stays on 0x7FFF across the
//       17-bit wrap boundary (the discontinuity the pre-fix saturator shows).
// CHK-6 F2 negative rail: a large negative sum saturates to 0x8000.
// CHK-7 F1 at the DAC: a wide (-86-scale, past-16-bit) sample_86 crosses the real
//       pc9821_audio_volume unclipped at unity and is clipped ONCE, at mix_dry.
// CHK-8 MASTER VOLUME SCALES THE SUM BEFORE THE SATURATION, the shape
//       NP2kai has (sound/fmboard.c:103-133 scales every source by vol_master
//       pre-sum, so master can pull the mix back from its output clamp). At
//       master code 28 (-6 dB) an OVER-RAIL source sum of +40,000 must come out
//       at +20,047 = floor(40000 * 32846 / 2^16) - the exact -6 dB Q16 gain
//       (65536*10^(-6/20) = 32845.9 -> 32846) taken ONCE on the unclamped sum -
//       and NOT saturated. The pre-fix chain saturates mix_tmp at mix_dry first
//       and only then attenuates, emitting floor(32767 * 32846 / 2^16) = +16,422:
//       clipped audio turned down, the exact F4 defect. The negative arm
//       (-40,000 -> -20,048, the Q16 take floor-rounding like the reference's
//       >> shifts) catches the same defect below the rail.
//
// ==== VERDICT ====
// PASS when the sample survives the wiring at the warranted value, nothing else moved,
// and the final DAC's golden model holds; FAIL naming where it was lost or distorted,
// with the measured values.
//
// The volumes below start at pc9821_system.sv's values (vol_master/vol_voice = 31,
// vol_cd = 5'd0 - the constant WITHOUT CD audio and the OSD CD audio volume's Off step; every
// preset builds CDROM_AUDIO_EN, where vol_cd is that OSD field's gain code (pc9821_osd's
// cd_volume_code, -12..0 dB or Off; tb_pc9821_osd_cd_volume pins the mapping), and its 0 dB
// step 5'd31 is the unity arm CHK-4..6 drive) and the sample is inside the range tb_pc9821_opna measures
// from the real OPNA (0..4092). CHK-4..6 switch vol_cd to a deliberate UNITY arm
// (5'd31) so the CD term can drive the rail sweep; the 5'd0 (no CD audio) state is CHK-0.

module tb_pc9821_audio_mix;
  reg clk = 0;
  always #5 clk = ~clk;             // 10 ns

  integer errors = 0;

  // ---- the volumes, EXACTLY as pc9821_system.sv drives them ------------------
  // vol_cd starts at 5'd0, pc9821_system.sv's constant for a build WITHOUT CD audio and the
  // OSD CD audio volume's Off step (so that muted arm is exercised). In the CD-DA build every
  // preset ships vol_cd is the OSD field's code; its 0 dB step 5'd31 is the unity arm CHK-4..6
  // switch to below - so both ends are driven. vol_master drops to 5'd28 for CHK-8.
  reg  [4:0] vol_master_l = 5'd31;
  reg  [4:0] vol_master_r = 5'd31;
  wire [4:0] vol_voice_l  = 5'd31;
  wire [4:0] vol_voice_r  = 5'd31;
  wire [4:0] vol_midi_l   = 5'd0;
  wire [4:0] vol_midi_r   = 5'd0;
  reg  [4:0] vol_cd_l     = 5'd0;
  reg  [4:0] vol_cd_r     = 5'd0;
  wire [4:0] vol_mt32_l   = 5'd0;
  wire [4:0] vol_mt32_r   = 5'd0;

  // ---- the sources: the -86 card on the sb slot, and the CD arm -------------
  // sample_86 is the WIDE card sum (20 bits: the clamped FM+ADPCM junction joins the
  // SSG and 86-PCM, and the last saturation is at the final DAC).
  reg signed [19:0] sample_86_l = 20'sd4000;
  reg signed [19:0] sample_86_r = 20'sd4000;
  reg signed [15:0] cdda_l      = 16'sd0;
  reg signed [15:0] cdda_r      = 16'sd0;
  reg        [16:0] spk_out     = 17'd0;      // 0..16384, pc9821_audio_mix's spk register
  reg               vol_en_cd_l = 1'b1;       // z486_mister's vol_en[2]
  reg               vol_en_cd_r = 1'b1;       // z486_mister's vol_en[1]

  // ---- the mixer's own state, as pc9821_audio_mix holds it ---------------
  reg signed [19:0] mix_tmp_l = 20'sd0;
  reg signed [19:0] mix_tmp_r = 20'sd0;
  reg        [15:0] mix_dry_l = 16'd0;
  reg        [15:0] mix_dry_r = 16'd0;
  reg        [15:0] core_audio_l_r = 16'd0;
  reg        [15:0] core_audio_r_r = 16'd0;
  wire [15:0] mix_pre_l = mix_dry_l;     // status[21:20] is an undeclared OSD field -> 0
  wire [15:0] mix_pre_r = mix_dry_r;

  wire signed [19:0] master_l, master_r, sb_l, sb_r, opl_l, opl_r, cd_l, cd_r, mt32_l, mt32_r;
  wire        sb_volume_valid;

  pc9821_audio_volume #(.NUM_CH(10), .SAMPLE_WIDTH(20)) sb_volume_inst (
    .clk(clk),
    .volumes_in({vol_master_l, vol_master_r,
                 vol_voice_l,  vol_voice_r,
                 vol_midi_l,   vol_midi_r,
                 vol_cd_l,     vol_cd_r,
                 vol_mt32_l,   vol_mt32_r}),
    // The master slot carries mix_tmp, the wide pre-clamp sum, so master scaling
    // happens before the final saturation. The remaining
    // 16-bit sources sign-extend to the 20-bit fields (the flat concat form:
    // nested per-element braces are a parse trap).
    .samples_in({mix_tmp_l,          mix_tmp_r,
                 sample_86_l,        sample_86_r,
                 20'd0,              20'd0,
                 {4{cdda_l[15]}},    cdda_l,      {4{cdda_r[15]}},    cdda_r,
                 20'd0,              20'd0}),
    .samples_out({master_l, master_r,
                  sb_l,     sb_r,
                  opl_l,    opl_r,
                  cd_l,     cd_r,
                  mt32_l,   mt32_r}),
    .valid(sb_volume_valid)
  );

  // MIRROR of pc9821_audio_mix's final mix (spk + the -86 stream + CD),
  // kept byte-identical to the shipped block. This is the F1/F2 fix site: the sum
  // is 20-bit signed (max 16384 + 255996 + 32767 = 305147, no wrap) and the ONE
  // saturation is mix_dry's, symmetric at the 16-bit rails - and it lands on the
  // MASTER-SCALED sum (master sits before the clamp).
  wire signed [19:0] snd86_l_swap = sb_l;      // status[56] is undeclared -> 0
  wire signed [19:0] snd86_r_swap = sb_r;

  always @(posedge clk) begin
    if (sb_volume_valid) begin
      mix_tmp_l <= $signed({3'b0, spk_out})
                 + snd86_l_swap
                 + (vol_en_cd_l ? cd_l : 20'sd0);
      mix_tmp_r <= $signed({3'b0, spk_out})
                 + snd86_r_swap
                 + (vol_en_cd_r ? cd_r : 20'sd0);

      mix_dry_l <= (master_l >  20'sd32767) ? 16'h7FFF :
                   (master_l < -20'sd32768) ? 16'h8000 : master_l[15:0];
      mix_dry_r <= (master_r >  20'sd32767) ? 16'h7FFF :
                   (master_r < -20'sd32768) ? 16'h8000 : master_r[15:0];

      core_audio_l_r <= mix_pre_l;
      core_audio_r_r <= mix_pre_r;
    end
  end

  // Run one mix to its valid strobe and out the other side: sb_volume's outputs
  // are a ROTATING shift register read only on its `valid` strobe (z486_mister
  // gates on it), and mix_tmp/mix_dry sit one and two strobes behind the input.
  // Each wait is a genuine pulse EDGE: the checks run at a valid-aligned negedge,
  // where a bare wait(valid) passes immediately and the rotation has not yet
  // refreshed every channel - the stale-slot trap that made a correct mixer look
  // broken. Two fresh pulses cover the 10-channel pass plus the mix_dry register.
  task automatic mix_settle;
    begin
      wait (sb_volume_valid === 1'b0);
      wait (sb_volume_valid === 1'b1);
      @(negedge clk);
      wait (sb_volume_valid === 1'b0);
      wait (sb_volume_valid === 1'b1);
      @(negedge clk);
      wait (sb_volume_valid === 1'b0);
      wait (sb_volume_valid === 1'b1);
      @(negedge clk);
    end
  endtask

  // Five fresh pulses: the master-pre-clamp chain (mix_tmp -> master channel ->
  // mix_dry -> core_audio) sits one pass deeper than the direct checks need.
  task automatic mix_settle_deep;
    begin
      repeat (5) begin
        wait (sb_volume_valid === 1'b0);
        wait (sb_volume_valid === 1'b1);
        @(negedge clk);
      end
    end
  endtask

  task automatic chk(input [8*80-1:0] name, input [15:0] got, input [15:0] want);
    begin
      if (got !== want) begin
        $display("FAIL %0s: mix_dry_l = %04x (%0d), expected %04x (%0d)",
                 name, got, $signed(got), want, $signed(want));
        errors = errors + 1;
      end
    end
  endtask

  integer s;
  integer iv_sb, iv_master;
  integer iv_cd_l, iv_cd_r;   // 32-bit copies: %0d mis-renders narrow signed wires

  initial begin
    // sb_volume's outputs are a ROTATING shift register: slot k holds channel
    // (NUM_CH-1-k) only on the clock its `valid` strobe is high, which is the only clock
    // its consumer may read them on (z486_mister gates on it). Checking at an arbitrary
    // clock reads slot 0 one channel early - the mistake this bench made first, which
    // made a correct mixer look broken. Wait for the strobe, and let the register FILL
    // first: on the very first one it is still empty.
    repeat (30) begin
      wait (sb_volume_valid === 1'b1);
      @(negedge clk);
    end
    mix_settle;
    iv_sb    = sb_l;      // via 32-bit copies: Verilator's %0d mis-renders narrow
    iv_master = master_l; // signed wires (it duplicated this one's bits into 36)
    $display("  sb_l=%0d master_l=%0d mix_pre_l=%0d (at the valid strobe)",
             iv_sb, iv_master, $signed(mix_pre_l));

    // ---- CHK-0: volume code 0 is TRUE MUTE at the no-CD-audio hard-wire --
    // vol_cd is 5'd0 AS SHIPPED and the CD-DA stream is FULL SCALE: the cd slot
    // and mix_dry must both be EXACTLY zero. NP2kai's volume-0 paths are exact
    // zeros (sound/beepg.c:161-163 gates on vol; sound/beepg.c:57/113 and
    // cbus/ideio.c:1737-1745 are linear multipliers), so code 0 is mute, never a
    // -62 dB floor. The pre-fix gain_lut[0] = 16'h0034 leaks +25 at +32767 and
    // -26 at -32768 (floor(52*x/2^16)) and fails both arms by name.
    sample_86_l = 20'sd0;      sample_86_r = 20'sd0;
    spk_out     = 17'd0;
    cdda_l      = 16'sd32767;  cdda_r      = 16'sd32767;
    mix_settle_deep;
    if ((cd_l !== 20'sd0) || (cd_r !== 20'sd0)) begin
      iv_cd_l = cd_l; iv_cd_r = cd_r;
      $display("FAIL CHK-0a volume code 0 must be true mute: cd_l=%0d cd_r=%0d at full-scale cdda (want 0/0)",
               iv_cd_l, iv_cd_r);
      errors = errors + 1;
    end
    chk("CHK-0a full-scale CD at vol_cd 0 contributes exactly zero", mix_dry_l, 16'd0);
    chk("CHK-0a full-scale CD at vol_cd 0 contributes exactly zero (R)", mix_dry_r, 16'd0);
    cdda_l = -16'sd32768;  cdda_r = -16'sd32768;
    mix_settle_deep;
    if ((cd_l !== 20'sd0) || (cd_r !== 20'sd0)) begin
      iv_cd_l = cd_l; iv_cd_r = cd_r;
      $display("FAIL CHK-0b volume code 0 must be true mute (negative): cd_l=%0d cd_r=%0d at -32768 cdda (want 0/0)",
               iv_cd_l, iv_cd_r);
      errors = errors + 1;
    end
    chk("CHK-0b negative full-scale CD at vol_cd 0 contributes exactly zero", mix_dry_l, 16'd0);
    cdda_l = 16'sd0;  cdda_r = 16'sd0;
    sample_86_l = 20'sd4000;  sample_86_r = 20'sd4000;
    mix_settle_deep;

    // CHK-1: the card's sample reaches the sb slot output AT THE WARRANTED VALUE.
    // Volume 31 is the gain table's 0 dB unity (gain 0x10000), so the slot output is
    // the sample bit-identically: 4000 in, 4000 out. A wrong gain law, a wrong volume
    // pairing or a swapped concat moves this off 4000.
    if ((sb_l !== 20'sd4000) || (sb_r !== 20'sd4000)) begin
      $display("FAIL CHK-1 the -86 sample did not survive the sb slot at unity: sb_l=%0d sb_r=%0d (want 4000 bit-identical)",
               $signed(sb_l), $signed(sb_r));
      errors = errors + 1;
    end

    // CHK-2: and the mixer's master channel carries the same warranted value (the
    // only nonzero contributor, wide sum, no saturation at 4000).
    if ((master_l !== 20'sd4000) || (master_r !== 20'sd4000)) begin
      $display("FAIL CHK-2 the mixer's master output is %0d/%0d with a 4000 sb slot (want 4000/4000):", $signed(master_l), $signed(master_r));
      $display("         the card's sample reached AUDIO_L at the wrong value - check the gain or the volume pairing");
      errors = errors + 1;
    end

    // CHK-3: every OTHER channel output is EXACTLY zero for this stimulus. A swapped
    // channel or concat moves the sample onto one of these slots and fails here even
    // when CHK-1/CHK-2's value still looks plausible.
    if ((opl_l !== 20'sd0) || (opl_r !== 20'sd0) || (cd_l !== 20'sd0) || (cd_r !== 20'sd0) ||
        (mt32_l !== 20'sd0) || (mt32_r !== 20'sd0)) begin
      $display("FAIL CHK-3 a checked-zero channel is nonzero (swapped concat/channel?): opl=%0d/%0d cd=%0d/%0d mt32=%0d/%0d",
               $signed(opl_l), $signed(opl_r), $signed(cd_l), $signed(cd_r), $signed(mt32_l), $signed(mt32_r));
      errors = errors + 1;
    end

    // ---- CHK-4..6: the final DAC's rails (F2), 16-bit-range sources ----------
    // The exact configuration the report names: speaker at its +16384 maximum
    // (status[19:18]=3, vol_spk=31), the -86 stream and CD at full scale. The CD
    // volume switches to a deliberate UNITY arm (5'd31) here so the CD term can
    // drive the sweep; the no-CD-audio 5'd0 state is CHK-0's.
    vol_cd_l    = 5'd31;       vol_cd_r    = 5'd31;
    sample_86_l = 20'sd32767;  sample_86_r = 20'sd32767;
    cdda_l      = 16'sd32767;  cdda_r      = 16'sd32767;
    spk_out     = 17'd16384;
    vol_en_cd_l = 1'b1;        vol_en_cd_r = 1'b1;
    mix_settle;
    // 16384 + 32767 + 32767 = 81918 > 65535: pre-fix the 17-bit mix_tmp wraps to
    // -49154 and the (^mix[16:15]) saturator clamps to 0x8000 - wrong rail AND
    // wrong polarity (the report's F2 concrete error).
    chk("CHK-4 positive overflow clamps high", mix_dry_l, 16'h7FFF);
    chk("CHK-4 positive overflow clamps high (R)", mix_dry_r, 16'h7FFF);
    // CHK-5: the sum swept across the 17-bit wrap boundary. Each step raises the
    // CD term by one: 16384 + 32767 + cdda = 65530..65545. Every value is past the
    // 16-bit rail, so the DAC's answer is 0x7FFF throughout; the pre-fix saturator
    // flips to 0x8000 at 65536 - the discontinuity the report sweeps for.
    for (s = 0; s < 16; s = s + 1) begin
      cdda_l = 16'sd16379 + 16'(s);   // cdda 16379..16394 -> sum 65530..65545
      cdda_r = cdda_l;
      mix_settle;
      chk("CHK-5 sweep 65530..65545 stays on the +rail", mix_dry_l, 16'h7FFF);
    end

    // CHK-6: the negative rail. 0 + (-65536) + (-32768) = -98304 clamps to 0x8000.
    sample_86_l = -20'sd65536; sample_86_r = -20'sd65536;
    cdda_l      = -16'sd32768; cdda_r      = -16'sd32768;
    spk_out     = 17'd0;
    mix_settle;
    chk("CHK-6 negative overflow clamps low", mix_dry_l, 16'h8000);

    // ---- CHK-7: F1 at the DAC - the wide card sum, clipped ONCE -------------
    // A past-16-bit card sum (here 49147 = the clamped FM junction 32767 + the SSG
    // term 16380) must cross pc9821_audio_volume unclipped at unity (sb_l == 49147)
    // and be saturated exactly once, at the final DAC (mix_dry == 0x7FFF). The
    // earlier chain flat-topped the drum bus at 32767 long before this point.
    sample_86_l = 20'sd49147;  sample_86_r = 20'sd49147;
    cdda_l      = 16'sd0;      cdda_r      = 16'sd0;
    spk_out     = 17'd0;
    mix_settle;
    if (sb_l !== 20'sd49147) begin
      $display("FAIL CHK-7 the volume path clipped the wide -86 sum: sb_l = %0d, expected 49147", sb_l);
      errors = errors + 1;
    end
    chk("CHK-7 wide sum saturates once at the DAC", mix_dry_l, 16'h7FFF);

    // And the report's cancelling case: the same over-rail join with a NEGATIVE
    // PCM term folded in (49147 - 32768 = 16379) must pass through UNCLOPPED -
    // the sample the pre-fix intermediate clamp turned into -1 (0x7FFF then
    // -32768 at the card sum).
    sample_86_l = 20'sd16379;  sample_86_r = 20'sd16379;
    mix_settle;
    chk("CHK-7 cancelling sum passes unclipped", mix_dry_l, 16'sd16379);

    // ---- CHK-8: MASTER SCALES THE SUM BEFORE THE SATURATION ------
    // NP2kai scales every source by vol_master BEFORE the sum and the output
    // clamp (sound/fmboard.c:103-133), so lowering master pulls an over-rail mix
    // back from the clamp instead of attenuating already-clipped audio. Master
    // code 28 is -6 dB: Q16 gain 32846 (65536*10^(-6/20) = 32845.9 -> 32846).
    // An over-rail source sum of +40,000 must come out +20,047
    // (floor(40000*32846/2^16)), UNSATURATED. The pre-fix chain saturates at
    // mix_dry first (32767) and only then attenuates: floor(32767*32846/2^16) =
    // +16,422 - clipped audio turned down. The negative arm is -20,048
    // (floor(-40000*32846/2^16), the Q16 take floor-rounding like the
    // reference's >> shifts) vs the pre-fix -16,423.
    vol_master_l = 5'd28;      vol_master_r = 5'd28;
    vol_cd_l     = 5'd0;       vol_cd_r     = 5'd0;
    sample_86_l  = 20'sd40000; sample_86_r  = 20'sd40000;
    cdda_l       = 16'sd0;     cdda_r       = 16'sd0;
    spk_out      = 17'd0;
    mix_settle_deep;
    chk("CHK-8 master pre-clamp at -6 dB: +40000 -> +20047", core_audio_l_r, 16'd20047);
    chk("CHK-8 master pre-clamp at -6 dB: +40000 -> +20047 (R)", core_audio_r_r, 16'd20047);
    sample_86_l = -20'sd40000; sample_86_r = -20'sd40000;
    mix_settle_deep;
    chk("CHK-8b master pre-clamp at -6 dB: -40000 -> -20048", core_audio_l_r, -16'sd20048);
    chk("CHK-8b master pre-clamp at -6 dB: -40000 -> -20048 (R)", core_audio_r_r, -16'sd20048);

    if (errors == 0) begin
      $display("TB_PC9821_AUDIO_MIX: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_AUDIO_MIX: FAIL (%0d errors)", errors);
  end

  initial begin
    #4_000_000;
    $fatal(1, "TB_PC9821_AUDIO_MIX: TIMEOUT");
  end
endmodule

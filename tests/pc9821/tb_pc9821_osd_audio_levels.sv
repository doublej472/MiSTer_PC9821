`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OSD_AUDIO_LEVELS:
// The OSD Audio page's PC-9801-86 and Beeper fields, decoded: each of the eight list positions of each field (0 dB, -2 dB, -4 dB, -6 dB, -8 dB, -10 dB, -12 dB, Off) selects the pc9821_audio_volume gain code its label names (31,30,29,28,27,26,25,0: code 31 is 0 dB, each step down is -2 dB, code 0 is exact mute), so position 0 - what a card with no config file passes - is 0 dB, the unity level both sources had before the page existed; each field drives only its own code (moving one field leaves the other two codes where they were, the CD audio code included), and both fields decode the same way in a build without the CD drive's audio player (CD_AUDIO_EN 0), where only the CD code is held at 0.
//
// WHERE THE EXPECTED VALUES COME FROM. The option list and its order are the owner's
// specification of the page (index 0 is the config-less default; each list descends from it in
// 2 dB steps and ends at Off). Each label's code is derived here from its dB value, not copied
// from the RTL: pc9821_audio_volume's gain_lut is 0 dB at code 31 and 2 dB per code
// (src/pc9821/audio/pc9821_audio_volume.sv, `16'h804E, //  -6 dB`), so -N dB is 31 - N/2, and
// Off is code 0, the table's exact zero.
//
// THE CHECKS:
// CHK-1 both builds: every position of the PC-9801-86 field decodes to 31 - dB/2 (Off -> 0) on
//       snd86_level_code, while the Beeper and CD codes hold their own fields' values.
// CHK-2 the same for the Beeper field on beep_level_code.
// CHK-3 every position's code is distinct (each level is reachable once).
// CHK-4 CD_AUDIO_EN 0: the CD code stays 0 through every step of the other two fields.
//
// PASS when every position decodes to its label's code; FAIL naming the field, the position and
// the code seen.

module tb_pc9821_osd_audio_levels;

  // ==== DUT ====
  // Two instances: the CD-audio build every preset ships and a build without the player.
  reg  [2:0] sel86 = 3'd0;
  reg  [2:0] selbp = 3'd0;
  reg  [2:0] selcd = 3'd0;
  wire [4:0] c86_on, cbp_on, ccd_on;
  wire [4:0] c86_off, cbp_off, ccd_off;

  pc9821_osd #(.CD_AUDIO_EN(1'b1)) dut_on (
    .osd_ram_size    (3'd0),
    .osd_gdc_clock   (1'b0),
    .osd_kbd_layout  (1'b0),
    .osd_snd86_level (sel86),
    .osd_beep_level  (selbp),
    .osd_cd_volume   (selcd),
    .ram_size_code   (),
    .gdc_clock_5m    (),
    .kbd_layout_jis  (),
    .snd86_level_code(c86_on),
    .beep_level_code (cbp_on),
    .cd_volume_code  (ccd_on)
  );

  pc9821_osd #(.CD_AUDIO_EN(1'b0)) dut_off (
    .osd_ram_size    (3'd0),
    .osd_gdc_clock   (1'b0),
    .osd_kbd_layout  (1'b0),
    .osd_snd86_level (sel86),
    .osd_beep_level  (selbp),
    .osd_cd_volume   (selcd),
    .ram_size_code   (),
    .gdc_clock_5m    (),
    .kbd_layout_jis  (),
    .snd86_level_code(c86_off),
    .beep_level_code (cbp_off),
    .cd_volume_code  (ccd_off)
  );

  integer errors = 0;

  // ==== CHECKS ====
  //   "P2O[75:73],PC-9801-86,0 dB,-2 dB,-4 dB,-6 dB,-8 dB,-10 dB,-12 dB,Off;"
  //   "P2O[78:76],Beeper,0 dB,-2 dB,-4 dB,-6 dB,-8 dB,-10 dB,-12 dB,Off;"
  // The attenuation each position's label names, in dB; -1 marks Off.
  integer want_db [0:7];
  function automatic [4:0] code_of(input integer pos);
    code_of = (want_db[pos] < 0) ? 5'd0 : 5'(31 - want_db[pos] / 2);
  endfunction

  task automatic expect_codes(input [8*16-1:0] what, input integer pos,
                              input [4:0] w86, input [4:0] wbp, input [4:0] wcd);
    begin
      #1;
      if (c86_on !== w86 || c86_off !== w86) begin
        $display("FAIL %0s position %0d: snd86_level_code %0d/%0d (CD build/no-CD build), want %0d",
                 what, pos, c86_on, c86_off, w86);
        errors = errors + 1;
      end
      if (cbp_on !== wbp || cbp_off !== wbp) begin
        $display("FAIL %0s position %0d: beep_level_code %0d/%0d, want %0d",
                 what, pos, cbp_on, cbp_off, wbp);
        errors = errors + 1;
      end
      if (ccd_on !== wcd) begin
        $display("FAIL %0s position %0d: cd_volume_code %0d, want %0d (the CD field did not move)",
                 what, pos, ccd_on, wcd);
        errors = errors + 1;
      end
      if (ccd_off !== 5'd0) begin
        $display("FAIL CHK-4 %0s position %0d: cd_volume_code %0d without CD audio, want 0",
                 what, pos, ccd_off);
        errors = errors + 1;
      end
    end
  endtask

  reg [31:0] seen86, seenbp;
  integer i;

  initial begin
    want_db[0] = 0;    //  0 dB  <- the DEFAULT (unity, the pre-page level)
    want_db[1] = 2;    // -2 dB
    want_db[2] = 4;    // -4 dB
    want_db[3] = 6;    // -6 dB
    want_db[4] = 8;    // -8 dB
    want_db[5] = 10;   // -10 dB
    want_db[6] = 12;   // -12 dB
    want_db[7] = -1;   // Off
    seen86 = 32'd0;
    seenbp = 32'd0;

    // CHK-1: the -86 field walks its list; the beeper sits at -4 dB and the CD at -10 dB.
    selbp = 3'd2;
    selcd = 3'd5;
    for (i = 0; i < 8; i = i + 1) begin
      sel86 = i[2:0];
      expect_codes("CHK-1 PC-9801-86", i, code_of(i), code_of(2), code_of(5));
      if (seen86[c86_on]) begin
        $display("FAIL CHK-3 PC-9801-86 position %0d repeats code %0d", i, c86_on);
        errors = errors + 1;
      end
      seen86[c86_on] = 1'b1;
    end

    // CHK-2: the beeper walks its list; the -86 sits at -12 dB and the CD at Off.
    sel86 = 3'd6;
    selcd = 3'd7;
    for (i = 0; i < 8; i = i + 1) begin
      selbp = i[2:0];
      expect_codes("CHK-2 Beeper", i, code_of(6), code_of(i), code_of(7));
      if (seenbp[cbp_on]) begin
        $display("FAIL CHK-3 Beeper position %0d repeats code %0d", i, cbp_on);
        errors = errors + 1;
      end
      seenbp[cbp_on] = 1'b1;
    end

    // position 0 on all three: the config-less card
    sel86 = 3'd0; selbp = 3'd0; selcd = 3'd0;
    expect_codes("CHK-1/2 all at position 0", 0, 5'd31, 5'd31, 5'd31);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OSD_AUDIO_LEVELS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OSD_AUDIO_LEVELS: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: the bench is combinational and must never hang.
  initial begin
    #1_000_000;
    $fatal(1, "TB_PC9821_OSD_AUDIO_LEVELS: TIMEOUT");
  end

endmodule

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OSD_CD_VOLUME:
// The OSD's CD audio volume field, decoded: each of the eight list positions (0 dB, -2 dB, -4 dB, -6 dB, -8 dB, -10 dB, -12 dB, Off) selects the pc9821_audio_volume gain code its label names (31,30,29,28,27,26,25,0: code 31 is 0 dB, each step down is -2 dB, code 0 is exact mute), so position 0 - what a card with no config file passes - is 0 dB, the unity level the CD-DA channel had before the field existed (the owner's choice), with NP2kai's default CD-DA level (DAVOLUME 128 of 255 = -6 dB, sdl/ini.c:704, applied as davolume/255 in cbus/ideio.c:1738-1743) one of the steps; and a build without the CD drive's audio player (CD_AUDIO_EN 0) gives code 0 at every position.
//
// WHERE THE EXPECTED VALUES COME FROM. The option list and its order are the owner's
// specification of the field (index 0 is the config-less default; the list descends from it in
// 2 dB steps and ends at Off). Each label's code is derived here from its dB value,
// not copied from the RTL: pc9821_audio_volume's gain_lut is 0 dB at code 31 and 2 dB per code
// (src/pc9821/audio/pc9821_audio_volume.sv, `16'h804E, //  -6 dB`), so -N dB is 31 - N/2, and
// Off is code 0, the table's exact zero. The 0 dB default is the owner's choice (2026-10-31):
// unity, the level the CD-DA channel shipped at before the field existed. The clipping that had
// prompted a -6 dB default was a wrong-rail clamp in the output FIR (tb_pc9821_audio_out_sat),
// not a level problem. NP2kai's default stays a reference step of the list: its CD-DA mix
// multiplies each sample by davolume and divides by 255 (cbus/ideio.c:1738-1740), with
// davolume's default 128 (sdl/ini.c:704, wx/ini.cpp:237, x/ini.c:690), 20*log10(128/255) =
// -5.99 dB. The real drive's level is still uncaptured (todo item 106).
//
// THE CHECKS:
// CHK-1 CD_AUDIO_EN 1: all eight positions decode to 31 - dB/2 (Off -> 0).
// CHK-2 every position's code is distinct (each of the eight levels is reachable once).
// CHK-3 CD_AUDIO_EN 0: every position decodes to 0 (no CD audio, the channel stays muted).
//
// PASS when every position decodes to its label's code in both builds; FAIL naming the position,
// the label and the code seen.

module tb_pc9821_osd_cd_volume;

  // ==== DUT ====
  // Two instances: the CD-audio build every preset ships and a build without the player.
  reg  [2:0] sel = 3'd0;
  wire [4:0] code_on;
  wire [4:0] code_off;

  pc9821_osd #(.CD_AUDIO_EN(1'b1)) dut_on (
    .osd_ram_size  (3'd0),
    .osd_gdc_clock (1'b0),
    .osd_kbd_layout(1'b0),
    .osd_cd_volume (sel),
    .ram_size_code (),
    .gdc_clock_5m  (),
    .kbd_layout_jis(),
    .cd_volume_code(code_on)
  );

  pc9821_osd #(.CD_AUDIO_EN(1'b0)) dut_off (
    .osd_ram_size  (3'd0),
    .osd_gdc_clock (1'b0),
    .osd_kbd_layout(1'b0),
    .osd_cd_volume (sel),
    .ram_size_code (),
    .gdc_clock_5m  (),
    .kbd_layout_jis(),
    .cd_volume_code(code_off)
  );

  integer errors = 0;

  // ==== CHECKS ====
  //   "O[66:64],CD audio volume,0 dB,-2 dB,-4 dB,-6 dB,-8 dB,-10 dB,-12 dB,Off;"
  // The attenuation each position's label names, in dB; -1 marks Off.
  integer want_db [0:7];
  reg [4:0] want_code;
  reg [31:0] codes_seen;
  integer i;

  initial begin
    want_db[0] = 0;    //  0 dB  <- the DEFAULT (unity, the pre-field level)
    want_db[1] = 2;    // -2 dB
    want_db[2] = 4;    // -4 dB
    want_db[3] = 6;    // -6 dB  (NP2kai's default, davolume 128/255)
    want_db[4] = 8;    // -8 dB
    want_db[5] = 10;   // -10 dB
    want_db[6] = 12;   // -12 dB
    want_db[7] = -1;   // Off
    codes_seen = 32'd0;

    // CHK-1 / CHK-2
    for (i = 0; i < 8; i = i + 1) begin
      sel = i[2:0];
      #1;
      want_code = (want_db[i] < 0) ? 5'd0 : 5'(31 - want_db[i] / 2);
      if (code_on !== want_code) begin
        if (want_db[i] < 0)
          $display("FAIL CHK-1 position %0d (Off) must be gain code 0, got %0d", i, code_on);
        else if (want_db[i] == 0)
          $display("FAIL CHK-1 position %0d (0 dB) must be gain code %0d, got %0d", i,
                   want_code, code_on);
        else
          $display("FAIL CHK-1 position %0d (-%0d dB) must be gain code %0d, got %0d", i,
                   want_db[i], want_code, code_on);
        errors = errors + 1;
      end
      if (!$isunknown(code_on)) begin
        if (codes_seen[code_on]) begin
          $display("FAIL CHK-2 position %0d repeats gain code %0d", i, code_on);
          errors = errors + 1;
        end
        codes_seen[code_on] = 1'b1;
      end
    end

    // CHK-3
    for (i = 0; i < 8; i = i + 1) begin
      sel = i[2:0];
      #1;
      if (code_off !== 5'd0) begin
        $display("FAIL CHK-3 without CD audio position %0d must be code 0, got %0d", i, code_off);
        errors = errors + 1;
      end
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OSD_CD_VOLUME: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OSD_CD_VOLUME: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: the bench is combinational and must never hang.
  initial begin
    #1_000_000;
    $fatal(1, "TB_PC9821_OSD_CD_VOLUME: TIMEOUT");
  end

endmodule

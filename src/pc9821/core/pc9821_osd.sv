// The OSD's stored selections, decoded: one place per list POSITION -> value contract.
//
// IT IS A MODULE, NOT A FUNCTION IN THE TOP LEVEL, because a function there is unreachable from
// the benches in this tree. The contract is not obvious: a card with no
// config file passes 0 for every field, so list position 0 must be the bootable default.
// `z486_mister.sv`'s CONF_STR is the other half of every field and
// tools/check_osd_contract.py parses both; if you reorder a list there, map it here.

`default_nettype none

module pc9821_osd #(
  // The CD drive's audio player is built (z486_mister's CDROM_AUDIO_EN). With 0 there is no CD-DA
  // stream and the CD volume code is the constant 0 (mute), so the decode const-folds away.
  parameter CD_AUDIO_EN = 1'b0
) (
  // O[63:61],RAM Size - a list POSITION, not a size.
  input  wire [2:0] osd_ram_size,
  // O[3],Enter BIOS setup (hold HELP): 0 = Off (the default a config-less card passes).
  input  wire       osd_bios_setup,
  // O[32],GDC Clock: 0 = 2.5 MHz (position 0, the measured machine's strap and the
  // default a config-less card passes), 1 = 5 MHz.
  input  wire       osd_gdc_clock,
  // O[38],FDD mode: 0 = Auto (position 0, the default), 1 = Fixed.
  input  wire       osd_fdd_mode,
  // O[51],Keyboard: 0 = US (position 0, the default), 1 = JIS.
  input  wire       osd_kbd_layout,
  // O[66:64],CD audio volume - a list POSITION, not a gain code.
  input  wire [2:0] osd_cd_volume,
  // pc9821_system's guest-size code: 0..6 = log2(MiB), 7 = the 96 MiB ceiling.
  output reg  [2:0] ram_size_code,
  // 1 = the keyboard holds HELP (0x3F) from reset, which the ITF's POST reads to enter SETUP.
  // The generator is pc9821_kbd's; owns the evidence.
  output wire       bios_setup,
  // 1 = 5 MHz: PC-9821 port 0x31 bit 7 CLEAR. The strap's own semantics, its ROM consumer
  // and why it is not the software-DIP record are on pc9821_iobus's port declaration.
  output wire       gdc_clock_5m,
  // 1 = Fixed: port 0x00BE bit 2 reads 1 (pc9821_fdc's dip_fixed carries the evidence).
  output wire       fdd_dip_fixed,
  // 1 = the keyboard translates a JIS host layout, 0 = a US one (pc9821_kbd's translate()
  // carries the four keys that differ and their references).
  output wire       kbd_layout_jis,
  // pc9821_audio_volume's 5-bit code for the CD-DA channel: 31 = 0 dB, 2 dB per step, 0 = mute.
  output reg  [4:0] cd_volume_code
);

              // O[63:61],RAM Size,16M,32M,64M,96M,1M,2M,4M,8M
              // THE LIST IS ROTATED: MiSTer uses OPTION INDEX 0 FOR EVERY FIELD when a core has no stored
              // config file, so index 0 has to BE the default, and an ascending 1M..96M list cannot also
              // put 16 MB first. A rotated list makes a card with no .CFG behave like a card with a
              // zeroed one.
              // Four places of rotation, written out so a reader need not do modular arithmetic, with the
              // size CODE unchanged downstream (0..6 = log2(MiB), 7 = the 96 MiB ceiling):
              //   entry 0 -> 16 MiB (the default)   entry 4 -> 1 MiB
              //   entry 1 -> 32 MiB                 entry 5 -> 2 MiB
              //   entry 2 -> 64 MiB                 entry 6 -> 4 MiB
              //   entry 3 -> 96 MiB                 entry 7 -> 8 MiB
  always @* begin
    case (osd_ram_size)
      3'd0:    ram_size_code = 3'd4;   // entry 0 -> 16 MiB <- the DEFAULT, and the point
      3'd1:    ram_size_code = 3'd5;   // entry 1 -> 32 MiB
      3'd2:    ram_size_code = 3'd6;   // entry 2 -> 64 MiB
      3'd3:    ram_size_code = 3'd7;   // entry 3 -> 96 MiB, the design's ceiling
      3'd4:    ram_size_code = 3'd0;   // entry 4 -> 1 MiB
      3'd5:    ram_size_code = 3'd1;   // entry 5 -> 2 MiB
      3'd6:    ram_size_code = 3'd2;   // entry 6 -> 4 MiB
      default: ram_size_code = 3'd3;   // entry 7 -> 8 MiB
    endcase
  end

  // O[3],Enter BIOS setup (hold HELP),Off,On. Identity: position 0 = Off = the default.
  assign bios_setup = osd_bios_setup;

  // O[32],GDC Clock,2.5 MHz,5 MHz. Identity: position 0 = 2.5 MHz, which is the strap the
  // measured machine answers (0xF3, bit 7 set) and therefore what a config-less card boots.
  assign gdc_clock_5m = osd_gdc_clock;

  // O[38],FDD mode,Auto,Fixed. Identity: position 0 = Auto = 0x00BE bit 2 clear. Unlike the
  // straps above, position 0 is NOT the measured unit's setting (that unit is Fixed): both are
  // real switch positions, and Auto is the one a 2DD boot disk needs.
  assign fdd_dip_fixed = osd_fdd_mode;

  // O[51],Keyboard,US,JIS. Identity: position 0 = US, the layout the core translated before
  // the option existed for the backslash key (0x5D -> YEN, the DOS path separator).
  assign kbd_layout_jis = osd_kbd_layout;

  // O[66:64],CD audio volume,0 dB,-2 dB,-4 dB,-6 dB,-8 dB,-10 dB,-12 dB,Off
  // A runtime gain on the CD-DA channel, the counterpart of a real CD drive's volume wheel.
  // Position 0 is 0 dB, the owner's choice (2026-10-31): unity, the level the channel shipped at
  // before the field existed. The clipping that had prompted a -6 dB default was a wrong-rail
  // clamp in the output FIR (tb_pc9821_audio_out_sat), not a level problem. NP2kai's default
  // CD-DA level stays a cited reference step of the list: its mix scales each CD sample by
  // davolume/255 (cbus/ideio.c:1738-1740, `((int)np2cfg.davolume * np2cfg.vol_master / 100) *`
  // ... `/ 255 / 31`) and davolume defaults to 128 (sdl/ini.c:704, `&np2cfg.davolume,	128}`),
  // 20*log10(128/255) = -5.99 dB. The real drive's line level against the FM is uncaptured
  // (todo item 106). The list descends from the default in 2 dB steps and ends at Off (the
  // owner's order, 2026-10-31). Codes are pc9821_audio_volume's: -N dB is 31 - N/2 and Off is
  // code 0, the gain table's exact zero.
  always @* begin
    if (!CD_AUDIO_EN) cd_volume_code = 5'd0;   // no CD-DA player: the channel stays muted
    else case (osd_cd_volume)
      3'd0:    cd_volume_code = 5'd31;  // entry 0 ->  0 dB  <- the DEFAULT (unity)
      3'd1:    cd_volume_code = 5'd30;  // entry 1 -> -2 dB
      3'd2:    cd_volume_code = 5'd29;  // entry 2 -> -4 dB
      3'd3:    cd_volume_code = 5'd28;  // entry 3 -> -6 dB (NP2kai's default)
      3'd4:    cd_volume_code = 5'd27;  // entry 4 -> -8 dB
      3'd5:    cd_volume_code = 5'd26;  // entry 5 -> -10 dB
      3'd6:    cd_volume_code = 5'd25;  // entry 6 -> -12 dB
      default: cd_volume_code = 5'd0;   // entry 7 -> Off (exact mute)
    endcase
  end

endmodule

`default_nettype wire

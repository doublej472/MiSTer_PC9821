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
  // O[32],GDC Clock: 0 = 2.5 MHz (position 0, the measured machine's strap and the
  // default a config-less card passes), 1 = 5 MHz.
  input  wire       osd_gdc_clock,
  // O[68],Text lines: 0 = 25 (position 0, the default), 1 = 20.
  input  wire       osd_text_lines,
  // O[69],Memory switch: 0 = Initialise (position 0, the default), 1 = Keep.
  input  wire       osd_msw_keep,
  // O[72:71],Floppy mode - a list POSITION: 0 = Auto (1M) (the default), 1 = 1M,
  // 2 = Auto (640K), 3 = 640K.
  input  wire [1:0] osd_floppy_mode,
  // O[51],Keyboard: 0 = US (position 0, the default), 1 = JIS.
  input  wire       osd_kbd_layout,
  // The OSD Audio page's three levels, each a list POSITION, not a gain code:
  // O[75:73],PC-9801-86, O[78:76],Beeper and O[66:64],CD audio.
  input  wire [2:0] osd_snd86_level,
  input  wire [2:0] osd_beep_level,
  input  wire [2:0] osd_cd_volume,
  // pc9821_system's guest-size code: 0..6 = log2(MiB), 7 = the 96 MiB ceiling.
  output reg  [2:0] ram_size_code,
  // 1 = 5 MHz: PC-9821 port 0x31 bit 7 CLEAR. The strap's own semantics, its ROM consumer
  // and why it is not the software-DIP record are on pc9821_iobus's port declaration.
  output wire       gdc_clock_5m,
  // 1 = 20 text lines: PC-9821 port 0x31 bit 3 SET (pc9821_iobus's text_lines_20 port
  // carries the evidence).
  output wire       text_lines_20,
  // 1 = the memory switch is kept: port 0x31 bit 4 CLEAR (pc9821_iobus's msw_hold port).
  output wire       msw_keep,
  // The Floppy mode position, passed on as a position so an undriven port downstream is the
  // default; pc9821_iobus's fdmode_setup decodes it to SETUP's 0x861E value.
  output wire [1:0] floppy_mode,
  // 1 = the keyboard translates a JIS host layout, 0 = a US one (pc9821_kbd's translate()
  // carries the four keys that differ and their references).
  output wire       kbd_layout_jis,
  // pc9821_audio_volume's 5-bit gain codes (31 = 0 dB, 2 dB per step, 0 = mute) for the
  // -86 board, the beeper and the CD-DA channel (pc9821_audio_mix applies them).
  output wire [4:0] snd86_level_code,
  output wire [4:0] beep_level_code,
  output wire [4:0] cd_volume_code
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

  // O[32],GDC Clock,2.5 MHz,5 MHz. Identity: position 0 = 2.5 MHz, which is the strap the
  // measured machine answers (0xF3, bit 7 set) and therefore what a config-less card boots.
  assign gdc_clock_5m = osd_gdc_clock;

  // The two SETUP items the DIP Switch page adds (docs/bios-setup.md). Each is an identity,
  // and each position 0 is the setting the measured Xe10 holds (port 0x31 = 0xF3, docs/probes/
  // MEMSW.TXT: bit 3 clear = 25 lines, bit 4 set = initialise), which is also the SETUP
  // factory value (BANK3@0x09F0).
  // O[68],Text lines,25,20.
  assign text_lines_20 = osd_text_lines;
  // O[69],Memory switch,Initialise,Keep.
  assign msw_keep = osd_msw_keep;
  // O[72:71],Floppy mode,Auto (1M),1M,Auto (640K),640K. Identity: position 0 = Auto (1M), the
  // default because it runs the most software (docs/policies.md, the defaults rule); 1M, SETUP's
  // factory value and the measured Xe10's (0x861E = 0x76, docs/probes/PORTS.TXT:258), is 1.
  assign floppy_mode = osd_floppy_mode;

  // O[51],Keyboard,US,JIS. Identity: position 0 = US, the layout the core translated before
  // the option existed for the backslash key (0x5D -> YEN, the DOS path separator).
  assign kbd_layout_jis = osd_kbd_layout;

  // THE AUDIO PAGE: O[75:73],PC-9801-86 / O[78:76],Beeper / O[66:64],CD audio, each
  // 0 dB,-2 dB,-4 dB,-6 dB,-8 dB,-10 dB,-12 dB,Off. Every field is the same list (the owner's
  // specification of the page), so one decode serves all three. Codes are
  // pc9821_audio_volume's: -N dB is 31 - N/2 and Off is code 0, the gain table's exact zero.
  // Position 0 is 0 dB on each: unity, the level every source had before its field existed (a
  // card with no config file and a config saved before the page both read 0 there).
  //   * PC-9801-86: the whole board (FM, SSG, rhythm, ADPCM and the 86-PCM) as one level, a
  //     user control (the board has no volume of its own a guest does not set).
  //   * Beeper: the system speaker, on top of the 0x871E ladder the guest sets.
  //   * CD audio: the counterpart of a real CD drive's volume wheel. NP2kai's default CD-DA
  //     level stays a cited reference step of the list: its mix scales each CD sample by
  //     davolume/255 (cbus/ideio.c:1738-1740, `((int)np2cfg.davolume * np2cfg.vol_master / 100) *`
  //     ... `/ 255 / 31`) and davolume defaults to 128 (sdl/ini.c:704, `&np2cfg.davolume,	128}`),
  //     20*log10(128/255) = -5.99 dB. The real drive's line level against the FM is uncaptured
  //     (todo item 106). The clipping that had once prompted a -6 dB CD default was a wrong-rail
  //     clamp in the output FIR (tb_pc9821_audio_out_sat), not a level problem.
  function automatic [4:0] level_code(input [2:0] pos);
    case (pos)
      3'd0:    level_code = 5'd31;  // entry 0 ->  0 dB  <- the DEFAULT (unity)
      3'd1:    level_code = 5'd30;  // entry 1 -> -2 dB
      3'd2:    level_code = 5'd29;  // entry 2 -> -4 dB
      3'd3:    level_code = 5'd28;  // entry 3 -> -6 dB (NP2kai's CD-DA default)
      3'd4:    level_code = 5'd27;  // entry 4 -> -8 dB
      3'd5:    level_code = 5'd26;  // entry 5 -> -10 dB
      3'd6:    level_code = 5'd25;  // entry 6 -> -12 dB
      default: level_code = 5'd0;   // entry 7 -> Off (exact mute)
    endcase
  endfunction

  assign snd86_level_code = level_code(osd_snd86_level);
  assign beep_level_code  = level_code(osd_beep_level);
  // No CD-DA player (CD_AUDIO_EN 0): the channel stays muted and the decode const-folds away.
  assign cd_volume_code   = CD_AUDIO_EN ? level_code(osd_cd_volume) : 5'd0;

endmodule

`default_nettype wire

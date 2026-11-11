// SPDX-License-Identifier: BSD-2-Clause
// Copyright (c) 2014, Aleksander Osman; Copyright (C) 2017-2020 Alexey Melnikov.
// The ten-channel volume concat, vol_en and the speaker shift follow ao486_MiSTer
// rtl/soc/sound/sound.v (https://github.com/MiSTer-devel/ao486_MiSTer). Licence text: NOTICE,
// part 4.

// The machine's audio mix on CLK_AUDIO, with the OSD Audio page's per-source levels.
//
// THE SOURCES AND WHERE EACH LEVEL ACTS. Three sources reach the final DAC, and the OSD Audio
// page (pc9821_osd) gives each one a level, a pc9821_audio_volume gain code (31 = 0 dB, 2 dB
// per code, 0 = Off):
//   * the PC-9801-86 board, the whole board as one source: sample_86 is the YM2608's clamped
//     FM+ADPCM junction plus its SSG, plus the 86-PCM (pc9821_system's snd86 sum). It takes the
//     ten-channel stage's -86 slot, whose gain code is pc9821_system's vol_voice in series with
//     the OSD level (gain_series below): the level multiplies with the slot's own gain, it does
//     not replace it. The guest's own volumes (the 86-PCM's 0xA466, the YM2608's registers)
//     act upstream, inside pc9821_system, and are untouched.
//   * the beeper: a unipolar level whose amplitude is the 0x871E BEEPER VOLUME ladder,
//     beep_vol * 1024 (NP2kai sound/beepg.c:113-114 `samp *= vol;`), scaled by the OSD level's
//     gain from the same table (beep_gain below) before it enters the sum.
//   * CD audio: the cdda stream on the CD slot, at pc9821_system's vol_cd code - the OSD CD
//     audio field, which crossed on its own handshake before this module existed (A7).
// Every level acts on its own source before the three are summed, and the sum is clamped
// once, at mix_dry_l/r: the one saturation of the machine's audio (mix_tmp -> master -> mix_dry).
// At 0 dB on every level this module is clock-for-clock and bit-for-bit the mix the top level
// carried before the page existed (tb_pc9821_audio_mix_equiv, against
// tests/pc9821/pc9821_audio_mix_ref.sv), and no level adds a register on any sample path:
// each acts in a stage the sample already passed through, so the page adds no latency.
//
// THE CROSSING (docs/clock-domains.md A7). The levels are OSD codes on clk_sys, quasi-static
// but multi-bit words (28 -> 27 is 11100 -> 11011), so they cross together as one word on the
// held handshake the -86 bus uses: captured whole on clk_sys, held until CLK_AUDIO has taken
// it (tb_pc9821_audio_level_cdc). The -86 and beeper levels cross INVERTED (31 - code, the
// attenuation in 2 dB steps), so the handshake's all-zero power-up output reads 0 dB on those
// two, which is what they were before the page existed; the CD code crosses as it did (power-up
// 0 = Off). The decode after the crossing is three inverters.
`default_nettype none

module pc9821_audio_mix (
    input  wire        clk_sys,
    input  wire        clk_audio,
    // ---- clk_sys: the OSD Audio page's gain codes, decoded by pc9821_osd -------------------
    input  wire  [4:0] snd86_level,    // PC-9801-86
    input  wire  [4:0] beep_level,     // Beeper
    input  wire  [4:0] vol_cd_l,       // CD audio: pc9821_system's vol_cd (0 without CD audio)
    input  wire  [4:0] vol_cd_r,
    // ---- pc9821_system's constant mixer settings (constants: nothing to cross) -------------
    input  wire  [4:0] vol_master_l,
    input  wire  [4:0] vol_master_r,
    input  wire  [4:0] vol_voice_l,
    input  wire  [4:0] vol_voice_r,
    input  wire  [4:0] vol_midi_l,
    input  wire  [4:0] vol_midi_r,
    input  wire  [1:0] vol_spk,        // the framework's 0..3 speaker step (3 = 0 dB)
    input  wire  [1:0] vol_en_cd,      // vol_en[2:1]: the CD L/R output switches
    // ---- clk_audio --------------------------------------------------------------------------
    input  wire [19:0] sample_86_l,    // the -86 board's wide sum, already crossed (sample_86_cdc)
    input  wire [19:0] sample_86_r,
    input  wire [15:0] cdda_l,         // the CD-DA stream (src/soc/cdda.v, CLK_AUDIO side)
    input  wire [15:0] cdda_r,
    input  wire        speaker,        // the beeper tone, synchronised (A2)
    input  wire  [1:0] beep_vol,       // 0x871E [3:2], raw quasi-static (A3)
    output reg  [15:0] mix_dry_l,      // the clamped mix, loaded on `valid`
    output reg  [15:0] mix_dry_r,
    output wire        valid
);

// ---- the level crossing -----------------------------------------------------------------
wire [19:0] level_audio;
cdc_vector_handshake_continuous #(.DATA_WIDTH(20)) level_cdc (
    .clk_in  (clk_sys),
    .clk_out (clk_audio),
    .data_in ({~snd86_level, vol_cd_l, vol_cd_r, ~beep_level}),
    .data_out(level_audio)
);
wire [4:0] snd86_level_a = ~level_audio[19:15];
wire [4:0] vol_cd_l_a    =  level_audio[14:10];
wire [4:0] vol_cd_r_a    =  level_audio[9:5];
wire [4:0] beep_level_a  = ~level_audio[4:0];

// Two gain codes in series. The codes are a dB scale (code c is 2*(31-c) dB down, 0 is Off), so
// two stages in series are one stage at the summed attenuation: code a + b - 31. A product
// below the table's last step (-60 dB, code 1) is Off, as is a product with an Off factor
// (a or b = 0 makes a + b <= 31). With a = 31 (0 dB) the result is b exactly.
function automatic [4:0] gain_series(input [4:0] a, input [4:0] b);
    reg [5:0] s;
    begin
        s = {1'b0, a} + {1'b0, b};
        gain_series = (s <= 6'd31) ? 5'd0 : 5'(s - 6'd31);
    end
endfunction

wire [4:0] vol_86_l = gain_series(vol_voice_l, snd86_level_a);
wire [4:0] vol_86_r = gain_series(vol_voice_r, snd86_level_a);

// ---- the beeper -------------------------------------------------------------------------
// The beeper level's gain: pc9821_audio_volume's Q16 table (its gain_lut and the 17'h10000
// unity), entry for entry. Each nonzero step is round(65536 * 10^(-dB/20)), which is how
// tb_pc9821_audio_levels derives its expected values; code 0 is the exact zero.
function automatic [16:0] beep_gain_q16(input [4:0] code);
    case (code)
        5'd31:   beep_gain_q16 = 17'h10000; //   0 dB (exact unity)
        5'd30:   beep_gain_q16 = 17'h0CB59; //  -2 dB
        5'd29:   beep_gain_q16 = 17'h0A186; //  -4 dB
        5'd28:   beep_gain_q16 = 17'h0804E; //  -6 dB
        5'd27:   beep_gain_q16 = 17'h065EA; //  -8 dB
        5'd26:   beep_gain_q16 = 17'h050F4; // -10 dB
        5'd25:   beep_gain_q16 = 17'h0404E; // -12 dB
        5'd24:   beep_gain_q16 = 17'h03314; // -14 dB
        5'd23:   beep_gain_q16 = 17'h02893; // -16 dB
        5'd22:   beep_gain_q16 = 17'h0203A; // -18 dB
        5'd21:   beep_gain_q16 = 17'h0199A; // -20 dB
        5'd20:   beep_gain_q16 = 17'h01456; // -22 dB
        5'd19:   beep_gain_q16 = 17'h01027; // -24 dB
        5'd18:   beep_gain_q16 = 17'h00CD5; // -26 dB
        5'd17:   beep_gain_q16 = 17'h00A31; // -28 dB
        5'd16:   beep_gain_q16 = 17'h00818; // -30 dB
        5'd15:   beep_gain_q16 = 17'h0066E; // -32 dB
        5'd14:   beep_gain_q16 = 17'h0051C; // -34 dB
        5'd13:   beep_gain_q16 = 17'h0040F; // -36 dB
        5'd12:   beep_gain_q16 = 17'h00339; // -38 dB
        5'd11:   beep_gain_q16 = 17'h0028F; // -40 dB
        5'd10:   beep_gain_q16 = 17'h00209; // -42 dB
        5'd9:    beep_gain_q16 = 17'h0019E; // -44 dB
        5'd8:    beep_gain_q16 = 17'h00148; // -46 dB
        5'd7:    beep_gain_q16 = 17'h00105; // -48 dB
        5'd6:    beep_gain_q16 = 17'h000CF; // -50 dB
        5'd5:    beep_gain_q16 = 17'h000A5; // -52 dB
        5'd4:    beep_gain_q16 = 17'h00083; // -54 dB
        5'd3:    beep_gain_q16 = 17'h00068; // -56 dB
        5'd2:    beep_gain_q16 = 17'h00053; // -58 dB
        5'd1:    beep_gain_q16 = 17'h00042; // -60 dB
        default: beep_gain_q16 = 17'h00000; // Off (code 0): exact silence
    endcase
endfunction

// One sounding bit is beep_vol * 1024 at 0 dB: beep_vol is the 2-bit software-DIP BEEPER
// VOLUME at 0x871E bits [3:2] (pc9821_iobus), the register ITF SETUP writes. NP2kai scales the
// beeper amplitude by it LINEARLY with 0 = exact mute: io/dipsw.c:44-57 takes (value >> 2) & 3
// from a 0x871E write into BEEP_VOL, sound/beepg.c:113-114 scales `samp *= vol; samp <<= (10-2)`
// in the mode-1 generator the PC-98 defaults to (sound/beepc.c:68 `g_beep.mode = 1`), and
// sound/beepg.c:161-163 generates exactly nothing at vol 0. The ladder is therefore
// 0/1,024/2,048/3,072: code 2 - NP2kai's default "Mid" (pccore.c:847) - is 2,048. The
// absolute level against the FM is still open (the framework's status[19:18] shift that once
// raised it is undeclared, so the unit is the constant 1024). vol_spk is the framework's 0..3
// speaker step (3 = 0 dB), applied as a right shift, and is hard-wired by pc9821_system.
//
// The OSD level scales that ladder: beep_vol * 1024 * G / 2^16 = beep_vol * G / 2^6. beep_vol is
// two bits, so the product is two shifted copies of G, added: no multiplier. At 0 dB (G = 2^16)
// it is beep_vol << 10 exactly, the amplitude before the page existed.
//
// The value is UNIPOLAR (0 or +A, never -A), so a sounding beep carries a DC offset of A/2;
// that convention is capture-pending.
//
// `beep_vol` is a GUEST register on clk_sys (0x871E, written by ITF SETUP) sampled here on
// CLK_AUDIO with no synchroniser (docs/clock-domains.md, "Quasi-static levels"): a 2-bit
// amplitude CODE, not a word with an invalid state. The tone itself (`speaker`) is the
// synchronised signal.
wire [16:0] beep_gain = beep_gain_q16(beep_level_a);
wire [17:0] beep_vg   = (beep_vol[0] ? {1'b0, beep_gain} : 18'd0)
                      + (beep_vol[1] ? {beep_gain, 1'b0} : 18'd0);
wire [16:0] beep_amp  = {5'd0, beep_vg[17:6]};
/* verilator lint_off UNUSEDSIGNAL */   // beep_vg[5:0]: the fraction below one LSB of the ladder
wire [5:0]  beep_frac = beep_vg[5:0];
/* verilator lint_on UNUSEDSIGNAL */

reg  [16:0] spk_out;
always @(posedge clk_audio) begin
    reg [16:0] spk;
    spk <= speaker ? beep_amp : 17'd0;
    spk_out <= spk >> ~vol_spk;
end

// ---- the ten-channel volume stage and the final DAC ---------------------------------------
// pc9821_audio_volume's outputs are SAMPLE_WIDTH (20) bits, matching the wide -86 bus: the
// master channel is mix_tmp (the WIDE PRE-CLAMP sum) scaled by vol_master, and snd86 carries
// the unclamped card sum to the final mix. Master scaling therefore sits BEFORE the final
// saturation - the shape NP2kai has, where every source is scaled by vol_master/100 before the
// sum and the output clamp (sound/fmboard.c:103-133) - so lowering master pulls an over-rail mix
// back from the clamp instead of attenuating already-clipped audio. Scaling the wide sum is
// that same linear law taken on the exact sum (g*(a+b+c) = g*a+g*b+g*c).
//
// The final DAC's sum: the -86 stream spans [+255,996, -239,616], CD adds +-32,768 and the
// speaker up to +3,072, so the three-source sum needs 20 signed bits (range +-524,287). An
// 18-bit accumulator (range +-131,071) would wrap and hand the saturator the wrong
// rail/polarity. The one saturation of the whole machine's audio is the mix_dry saturate below
// - on the MASTER-SCALED sum, exactly ymfm's clamp16 / NP2kai's _saturation_s16 junction.
wire signed [19:0] master_l;
wire signed [19:0] master_r;
wire signed [19:0] snd86_l;
wire signed [19:0] snd86_r;
wire signed [19:0] cd_l;
wire signed [19:0] cd_r;
// The OPL and MT32 slots: no source (there is no OPL chip on a PC-9821 and no MT32 is
// instantiated), not multiplexed (USED below), so their outputs read 0 and are unread.
/* verilator lint_off UNUSEDSIGNAL */
wire signed [19:0] opl_l;
wire signed [19:0] opl_r;
wire signed [19:0] mt32_l;
wire signed [19:0] mt32_r;
/* verilator lint_on UNUSEDSIGNAL */
reg  signed [19:0] mix_tmp_l;
reg  signed [19:0] mix_tmp_r;

// USED = channels 9..6 (master L/R, -86 L/R) and 3..2 (CD L/R): the OPL and MT32 slots have no
// source and their outputs are unread, so the stage does not multiplex or hold them (10'h3CC).
// The MT32 slot's code is vol_midi (the "MT32 Volume Ctl" status[25] arm is undeclared and
// folded to 0, which selected vol_midi).
pc9821_audio_volume #(.NUM_CH(10), .SAMPLE_WIDTH(20), .USED(10'h3CC)) audio_volume_inst (
    .clk(clk_audio),
    .volumes_in({vol_master_l, vol_master_r,
                 vol_86_l,     vol_86_r,
                 vol_midi_l,   vol_midi_r,
                 vol_cd_l_a,   vol_cd_r_a,
                 vol_midi_l,   vol_midi_r}),
    // The master slot carries mix_tmp, the wide pre-clamp sum, so master scaling happens
    // before the final saturation. The 16-bit CD source sign-extends to the 20-bit field (the
    // flat concat form: nested per-element braces are a parse trap).
    .samples_in({mix_tmp_l,          mix_tmp_r,
                 sample_86_l,        sample_86_r,
                 20'd0,              20'd0,
                 {4{cdda_l[15]}},    cdda_l,     {4{cdda_r[15]}},    cdda_r,
                 20'd0,              20'd0}),
    .samples_out({master_l, master_r,
                  snd86_l,  snd86_r,
                  opl_l,    opl_r,
                  cd_l,     cd_r,
                  mt32_l,   mt32_r}),
    .valid(valid)
);

always @(posedge clk_audio) begin
    if (valid) begin
        // THE FINAL DAC: the three sources sum WIDE (20 bits, no wrap possible) into mix_tmp,
        // the master channel scales that sum on its next pass, and the ONE saturation below
        // lands on the SCALED value - master sits before the clamp (NP2kai
        // sound/fmboard.c:103-133), symmetrically at the 16-bit rails (ymfm's clamp16 /
        // NP2kai's _saturation_s16 junction).
        mix_tmp_l <= $signed({3'b0, spk_out})
                   + snd86_l
                   + (vol_en_cd[1] ? cd_l : 20'sd0);
        mix_tmp_r <= $signed({3'b0, spk_out})
                   + snd86_r
                   + (vol_en_cd[0] ? cd_r : 20'sd0);

        mix_dry_l <= (master_l >  20'sd32767) ? 16'h7FFF :
                 (master_l < -20'sd32768) ? 16'h8000 : master_l[15:0];
        mix_dry_r <= (master_r >  20'sd32767) ? 16'h7FFF :
                 (master_r < -20'sd32768) ? 16'h8000 : master_r[15:0];
    end
end

endmodule

`default_nettype wire

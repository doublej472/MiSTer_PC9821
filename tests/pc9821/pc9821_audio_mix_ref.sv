// SPDX-License-Identifier: BSD-2-Clause
// Copyright (c) 2014, Aleksander Osman; Copyright (C) 2017-2020 Alexey Melnikov.
// The ten-channel volume concat, vol_en and the speaker shift follow ao486_MiSTer
// rtl/soc/sound/sound.v (https://github.com/MiSTer-devel/ao486_MiSTer). Licence text: NOTICE,
// part 4.
// TEST REFERENCE: z486_mister.sv's CLK_AUDIO mix as of 105f3263 (the CD volume's vol_cd_cdc,
// the speaker block, audio_volume_inst and the mix_tmp/mix_dry block), copied with only its
// top-level wires turned into ports. It is the equivalence reference of
// tb_pc9821_audio_mix_equiv (the OSD Audio page at 0 dB must be this mix); not maintained.
`default_nettype none

module pc9821_audio_mix_ref (
    input  wire        clk_sys,
    input  wire        CLK_AUDIO,
    input  wire  [4:0] vol_cd_l,
    input  wire  [4:0] vol_cd_r,
    input  wire  [4:0] vol_master_l,
    input  wire  [4:0] vol_master_r,
    input  wire  [4:0] vol_voice_l,
    input  wire  [4:0] vol_voice_r,
    input  wire  [4:0] vol_midi_l,
    input  wire  [4:0] vol_midi_r,
    input  wire  [1:0] vol_spk,
    input  wire  [4:0] vol_en,
    input  wire [19:0] sample_86_l_audio,
    input  wire [19:0] sample_86_r_audio,
    input  wire [15:0] cdda_l,
    input  wire [15:0] cdda_r,
    input  wire        speaker_out_audio,
    input  wire  [1:0] beep_vol,
    output wire [15:0] mix_pre_l,
    output wire [15:0] mix_pre_r,
    output wire        audio_volume_valid
);

reg  [16:0] spk_out;
reg signed [19:0] mix_tmp_l;
reg signed [19:0] mix_tmp_r;
reg  [15:0] mix_dry_l;
reg  [15:0] mix_dry_r;

wire [4:0] vol_cd_l_audio;
wire [4:0] vol_cd_r_audio;

cdc_vector_handshake_continuous #(.DATA_WIDTH(5*2)) vol_cd_cdc (
	.clk_in   (clk_sys),
	.clk_out  (CLK_AUDIO),
	.data_in  ({vol_cd_l, vol_cd_r}),
	.data_out ({vol_cd_l_audio, vol_cd_r_audio})
);

always @(posedge CLK_AUDIO) begin
	reg [16:0] spk;
	spk <= speaker_out_audio ? ({15'd0, beep_vol} << 10) : 17'd0;
	spk_out <= spk >> ~vol_spk;
end

wire signed [19:0] master_l;
wire signed [19:0] master_r;
wire signed [19:0] snd86_l;
wire signed [19:0] snd86_r;
/* verilator lint_off UNUSEDSIGNAL */
wire signed [19:0] opl_l;
wire signed [19:0] opl_r;
/* verilator lint_on UNUSEDSIGNAL */
wire signed [19:0] cd_l;
wire signed [19:0] cd_r;
/* verilator lint_off UNUSEDSIGNAL */
wire signed [19:0] mt32_l;
wire signed [19:0] mt32_r;
/* verilator lint_on UNUSEDSIGNAL */
assign mix_pre_l = mix_dry_l;
assign mix_pre_r = mix_dry_r;
wire  [4:0] vol_mt32_l = vol_midi_l;
wire  [4:0] vol_mt32_r = vol_midi_r;

pc9821_audio_volume #(.NUM_CH(10), .SAMPLE_WIDTH(20), .USED(10'h3CC)) audio_volume_inst (
	.clk(CLK_AUDIO),
	.volumes_in({vol_master_l, vol_master_r,
	             vol_voice_l,  vol_voice_r,
	             vol_midi_l,   vol_midi_r,
	             vol_cd_l_audio, vol_cd_r_audio,
	             vol_mt32_l,   vol_mt32_r}),
	.samples_in({mix_tmp_l,                mix_tmp_r,
	             sample_86_l_audio,       sample_86_r_audio,
	             20'd0,                   20'd0,
	             {4{cdda_l[15]}},         cdda_l,        {4{cdda_r[15]}},         cdda_r,
	             20'd0,                   20'd0}),
	.samples_out({master_l, master_r,
	              snd86_l,  snd86_r,
	              opl_l,    opl_r,
	              cd_l,     cd_r,
	              mt32_l,   mt32_r}),
	.valid(audio_volume_valid)
);

wire signed [19:0] snd86_l_swap = snd86_l;
wire signed [19:0] snd86_r_swap = snd86_r;

always @(posedge CLK_AUDIO) begin
	if (audio_volume_valid) begin
		mix_tmp_l <= $signed({3'b0, spk_out})
		           + snd86_l_swap
		           + (vol_en[2] ? cd_l : 20'sd0);
		mix_tmp_r <= $signed({3'b0, spk_out})
		           + snd86_r_swap
		           + (vol_en[1] ? cd_r : 20'sd0);

		mix_dry_l <= (master_l >  20'sd32767) ? 16'h7FFF :
		             (master_l < -20'sd32768) ? 16'h8000 : master_l[15:0];
		mix_dry_r <= (master_r >  20'sd32767) ? 16'h7FFF :
		             (master_r < -20'sd32768) ? 16'h8000 : master_r[15:0];
	end
end

endmodule

`default_nettype wire

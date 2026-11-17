// The PC-9801-86 board's analog join: the YM2608's output (pc9821_opna: the clamped FM+ADPCM
// junction plus the AC-coupled SSG) and the 86-PCM DAC (pc9821_pcm86, already scaled by the
// guest's 0xA466 volume) summed WIDE and unclamped into the one -86 sample bus that
// z486_mister.sv crosses to CLK_AUDIO (sample_86_cdc). The sum's only clip is the final DAC's
// (pc9821_audio_mix's mix_dry saturator). The sum stays within about +-72k (the FM+ADPCM junction
// clamped to [-32,768, +32,767], the AC SSG term within about +-6.3k, the PCM86 DAC
// [-32,768, +32,767]), which 20 bits hold with room.
//
// WHY BOTH TERMS ARE REGISTERED HERE. The bus is the data word of a held handshake
// (cdc_vector_handshake_continuous): its clk_sys holding register loads the word on whatever
// clk_sys edge the handshake's request flag next goes high, an edge that has no relation to the
// cycle in which a source changed. So the path from each source into that holding register is a
// GENUINE single-cycle path. Without these registers it began at pc9821_pcm86's hold_l/hold_r
// (and vol5) and ran through the DAC's 16x16 volume multiply and both adds of the join: the
// slowest audio data path into any clk_sys register, negative at the slow corner on about one
// seed in three (release c03da744 seed 3: 17 endpoints, worst -0.79 ns, every one a left-channel
// bit). A miss loads a word whose high bits are still settling, which the mix carries as a
// one-sample spike up to the rails: a click on every miss, crackle while the 86-PCM plays.
// Registering both terms cuts the multiply (and the YM2608's clamp and SSG add) off that path:
// what reaches the holding register is one 20-bit add of two registers.
//
// The cost is one clk_sys (11 ns at 90 MHz) on the analog output of both devices, equally, so
// their relative timing is unchanged. Nothing the guest can read sees it: no port returns a DAC
// value, and the next stage is a 2.4576 MHz mixer and a 48 kHz output.
`default_nettype none

module pc9821_snd86_join (
    input  wire               clk,
    input  wire signed [19:0] opna_l,   // pc9821_opna snd_l/r
    input  wire signed [19:0] opna_r,
    input  wire signed [15:0] pcm_l,    // pc9821_pcm86 snd_l/r
    input  wire signed [15:0] pcm_r,
    output wire signed [19:0] sum_l,    // to sample_86_cdc's data word
    output wire signed [19:0] sum_r
);

/* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
reg signed [19:0] opna_l_q = 20'sd0;
reg signed [19:0] opna_r_q = 20'sd0;
reg signed [15:0] pcm_l_q  = 16'sd0;
reg signed [15:0] pcm_r_q  = 16'sd0;
/* verilator lint_on PROCASSINIT */

always @(posedge clk) begin
    opna_l_q <= opna_l;
    opna_r_q <= opna_r;
    pcm_l_q  <= pcm_l;
    pcm_r_q  <= pcm_r;
end

assign sum_l = opna_l_q + {{4{pcm_l_q[15]}}, pcm_l_q};
assign sum_r = opna_r_q + {{4{pcm_r_q[15]}}, pcm_r_q};

endmodule

`default_nettype wire

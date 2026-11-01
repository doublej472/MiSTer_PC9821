// SPDX-License-Identifier: BSD-2-Clause
// Copyright (c) 2014, Aleksander Osman; Copyright (C) 2017-2020 Alexey Melnikov.
// Derived from ao486_MiSTer rtl/soc/sound/sound.v, module sb_volume
// (https://github.com/MiSTer-devel/ao486_MiSTer). Licence text: NOTICE, part 4.

// N-channel audio volume attenuator for the PC-9821 core.
//
// The 5-bit table and the DSP-targeted multiply; code 0 is TRUE ZERO (a -62 dB
// floor there would leak +-25/26 LSB at full scale).
`default_nettype none

module pc9821_audio_volume
#(
    parameter integer NUM_CH       = 10, // number of channels
    parameter integer SAMPLE_WIDTH = 16, // number of bits per sample
    // Bit c set: channel c's output is consumed. Every channel still takes its slot in the
    // NUM_CH-clock sequence (the strobe cadence is part of the contract), but a channel whose
    // bit is clear is not multiplexed in and its samples_out field reads 0.
    parameter [NUM_CH-1:0] USED    = {NUM_CH{1'b1}}
)(
    input                                clk,
    input                 [NUM_CH*5-1:0] volumes_in,  // input volumes (5 bits per channel volume control)
    input      [NUM_CH*SAMPLE_WIDTH-1:0] samples_in,  // input samples (SAMPLE_WIDTH bits per channel sample)
    output wire [NUM_CH*SAMPLE_WIDTH-1:0] samples_out, // output samples (attenuated)
    output reg                           valid        // samples_out valid flag
);

// gain table (unsigned, 16-bit gain values)
// volume = 0 to 31 (5-bit): 0 is MUTE (true zero), 1..31 are -60 dB to 0 dB in
// 2 dB steps. Code 0 is exact silence because NP2kai's volume-0 paths are exact
// zeros - sound/beepg.c:161-163 gates the beeper generator on beepcfg.vol and
// every OSD volume is a linear multiplier (sound/beepg.c:57/113,
// cbus/ideio.c:1737-1745) - so 0 can never leak.
// 32 x 16 = 512 bits packed into one vector
localparam [511:0] gain_lut = {
    16'hFFFF, //   0 dB (17'h10000 will be used for unity gain)
    16'hCB59, //  -2 dB
    16'hA186, //  -4 dB
    16'h804E, //  -6 dB
    16'h65EA, //  -8 dB
    16'h50F4, // -10 dB
    16'h404E, // -12 dB
    16'h3314, // -14 dB
    16'h2893, // -16 dB
    16'h203A, // -18 dB
    16'h199A, // -20 dB
    16'h1456, // -22 dB
    16'h1027, // -24 dB
    16'h0CD5, // -26 dB
    16'h0A31, // -28 dB
    16'h0818, // -30 dB
    16'h066E, // -32 dB
    16'h051C, // -34 dB
    16'h040F, // -36 dB
    16'h0339, // -38 dB
    16'h028F, // -40 dB
    16'h0209, // -42 dB
    16'h019E, // -44 dB
    16'h0148, // -46 dB
    16'h0105, // -48 dB
    16'h00CF, // -50 dB
    16'h00A5, // -52 dB
    16'h0083, // -54 dB
    16'h0068, // -56 dB
    16'h0053, // -58 dB
    16'h0042, // -60 dB
    16'h0000  // mute (code 0 = exact zero; was 16'h0034, a -62 dB leak)
};

localparam [3:0] CH_LAST = 4'(NUM_CH-1);
// Power-up state: this module has no reset port - it runs
// free on CLK_AUDIO - so the seeds below ARE its reset. `ch` is self-fed
// (ch <= (ch == CH_LAST) ? 0 : ch + 1): unseeded it X-locks in 4-state sim and
// poisons gain/sample, samples_out (the 10-channel master mix) and valid
// forever. The seed state is silent: ch = 0, no gain, no sample, no output.
/* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
reg [3:0] ch = 4'd0;

// The selected channel's volume and sample: an AND-OR select over the USED channels only (a
// clear USED bit takes no select logic, and the select of an unused slot is don't-care).
reg [4:0] volume_5bit;
reg signed [SAMPLE_WIDTH-1:0] sample_sel;
integer ci;
always @* begin
    volume_5bit = 5'd0;
    sample_sel  = '0;
    for (ci = 0; ci < NUM_CH; ci = ci + 1)
        if (USED[ci] && (ch == 4'(ci))) begin
            volume_5bit = volumes_in[5*ci +: 5];
            sample_sel  = samples_in[SAMPLE_WIDTH*ci +: SAMPLE_WIDTH];
        end
end

reg signed [SAMPLE_WIDTH-1:0] sample = '0;
reg         gain_valid = 1'b0;
/* verilator lint_on PROCASSINIT */

// The 32-entry gain table is a 32x17 M10K ROM, not a LUT-selected packed vector.
// The synchronous read's capture register `gain_q` carries NO power-up value - a
// seed or reset on the read-capture register makes Quartus refuse the RAM and
// build the table out of LUTs (`Info 276007`) - so the startup silence is the
// one-clk `gain_valid` guard on the wire instead, exactly as pc9821_kbd's
// `rom_valid` does. Unlike pc9821_kbd's ROM, a LUT-table `gain` is also a register
// captured one clk after `ch`, so the registered read has the SAME latency and
// `sample`/`valid` need no extra stage.
// Measured module-alone (tools/res_exp_map.py): the M10K form is 128 ALMs /
// 182 regs + 544 M10K bits vs the LUT form's 134 ALMs / 198 regs; the
// `ramstyle = "MLAB"` spelling is silently ignored by Quartus 17.0.2 (the ROM
// lands in M10K either way), so MLAB is not a distinct, cheaper option.
(* ramstyle = "M10K" *) reg [16:0] gain_mem [0:31];
reg  [16:0] gain_q;
wire [16:0] gain = gain_valid ? gain_q : 17'd0;
integer gi;
initial begin
    for (gi = 0; gi < 32; gi = gi + 1)
        gain_mem[gi] = (gi == 31) ? 17'h10000 : {1'b0, gain_lut[gi*16 +: 16]};
end
always @(posedge clk) begin
    gain_q     <= gain_mem[volume_5bit];
    gain_valid <= 1'b1;
    sample     <= sample_sel;
end

// DSP-targeted multiply (1 x DSP block shared across all channels). The product
// and its taken slice are in SAMPLE_WIDTH terms: the gain is at most 2^16 (unity),
// so the product needs SAMPLE_WIDTH+17 bits and the scaled sample is the
// [SAMPLE_WIDTH+15:16] take (the Q16 shift). At SAMPLE_WIDTH=16 that is exactly
// the historical 34-bit product and [31:16] slice - bit-identical volumes.
/* verilator lint_off UNUSEDSIGNAL */   // the product's low 16 bits and top sign bit(s) are
// the discarded fractional/extension bits; only [SAMPLE_WIDTH+15:16] is the sample.
wire signed [SAMPLE_WIDTH+16:0] gain_product = $signed({1'b0, gain}) * sample;
/* verilator lint_on UNUSEDSIGNAL */

// Each consumed channel's product is captured once, in the clock after its sample entered the
// multiplier, and held for the ten-clock epoch. That is the value the ten-deep output shift
// register delivered to the consumer on `valid` (a product shifts down one position per clock
// and reaches channel c's field exactly NUM_CH-1-c clocks after the capture below, which is the
// clock `valid` is high): the strobe is high when ch == 1, and channel c was captured at the end
// of the clock with ch == c+1, so every field is from the same epoch. The fields hold between
// captures, so samples_out is meaningful on `valid` and that is the only clock the mixer reads.
// 6 of 10 fields at 20 bits is 120 flip-flops instead of the 160-bit chain (200 declared).
reg [NUM_CH*SAMPLE_WIDTH-1:0] out_q;
assign samples_out = out_q;
integer oc;
always @(posedge clk) begin
    for (oc = 0; oc < NUM_CH; oc = oc + 1)
        if (USED[oc] && (ch == 4'((oc + 1) % NUM_CH)))
            out_q[SAMPLE_WIDTH*oc +: SAMPLE_WIDTH] <= gain_product[SAMPLE_WIDTH+15:16];
    valid             <= (ch == 0);
    ch                <= (ch == CH_LAST) ? 4'd0 : ch + 4'd1;
end

// Power-up state, part 2: the captured fields and the strobe start silent.
/* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
initial begin
    out_q = '0;
    valid = 1'b0;
end
/* verilator lint_on PROCASSINIT */

endmodule

`default_nettype wire

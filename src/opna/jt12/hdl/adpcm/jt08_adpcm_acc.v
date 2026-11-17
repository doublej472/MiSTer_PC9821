/* This file is part of JT12.


    JT12 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT12 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT12.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 21-03-2019
*/
// same as jt10_adpcm_acc, except no linear interpolation

// Adds all 6 channels
// sampling frequency to 55.5 kHz
//
// LOCAL CHANGE (this repository): two, both about the drum-bus clip.
//
// 1. `gain_shift` attenuates EACH drum before it enters the summing accumulator, not
// the summed result. An attenuation applied to the OUTPUT (as jt12_top used to, at
// `adpcmA_l >>> rhythm_gain_shift`) would only scale an already flat-topped sum,
// which is the owner's "lowering the rhythm volume does not fix the distortion".
// At gain_shift == 0 the shift is bit-identical to upstream.
//
// 2. `acc` is a 16-BIT WRAPPING accumulator, which is the die's own six-drum sum
// (YM2608-LLE fmopna_impl.c:5363-5383, `ac_rss_accm1[0] = accm1 & 0xffff`), and
// `pcm_out` is that wrapped bus SIGN-EXTENDED to the 20-bit port. It is neither
// upstream's 16-bit `sat16` (a flat top - the "drums clipping" the owner heard)
// nor a wide no-limit sum: the die wraps, so three or more near-peak drums
// sign-flip the bus (e.g. +46080 -> -19456), and the FM+ADPCM junction above
// clamps ONCE (jt08_acc.v; the die's output-shifter rails == ymfm's clamp16).
// This module must not pre-clamp (YM2608-LLE fmopna_impl.c, the die model).
//
// The shift is done on the 16-bit pcm_in and the (whole) result is then sign-extended,
// rather than shifting an 18-bit sign-extended copy. The two are the same arithmetic,
// but the 18-bit-variable-shift form is miscompiled where it is bound into the
// accumulator (Verilator 5.052 emits a value near the 18-bit rail for any non-zero
// shift, which makes the SUM louder as the volume is lowered; measured, the report is not
// kept in the tree).
// Keep the shift on the narrow signed signal.

module jt08_adpcm_acc(
    input           rst_n,
    input           clk,        // CPU clock
    input           cen,        // 111 kHz
    // pipeline channel
    input   [5:0]   cur_ch,
    input   [5:0]   en_ch,
    input           match,

    input           en_sum,
    input   [2:0]   gain_shift, // per-drum RHYTHM attenuation; 0 = upstream
    input  signed [15:0] pcm_in,    // 18.5 kHz
    // THE SIX-DRUM BUS. LOCAL CHANGE (this repository): a 16-BIT WRAPPING accumulator, which is
    // the die's own six-drum sum (YM2608-LLE `fmopna_impl.c:5363-5383`:
    // `accm1 += rss_sample; ac_rss_accm1[0] = accm1 & 0xffff;`), sign-extended into the 20-bit
    // FM+ADPCM junction - the point where the die and this core saturate ONCE (jt08_acc, +/-32768;
    // the die's output shifter rails there). It is deliberately NOT
    // a wide sum and NOT a saturating one: three near-peak drums push the raw sum past +/-32767
    // and the die WRAPS (e.g. +46080 -> -19456), a full-scale sign flip, where upstream's `sat16`
    // flat-topped and the previous 20-bit wide sum passed the overflow on to the junction clamp.
    // The die (YM2608-LLE) is the primary chip-internal reference.
    output reg signed [19:0] pcm_out    // 55.5 kHz
);

wire signed [15:0] pcm_in_shr  = pcm_in >>> gain_shift;
wire signed [15:0] pcm_in_long = en_sum ? pcm_in_shr : 16'sd0;
reg  signed [15:0] acc;


always @(posedge clk or negedge rst_n)
    if( !rst_n ) begin
        acc     <= 16'd0;
        pcm_out <= 20'd0;   // reset state hygiene (was unreset upstream)
    end else if(cen) begin
        // Each round replaces the sum on the first drum slot (the die's `rss_cnt2 == 0` reload)
        // and adds the other five; the 16-bit signed add WRAPS, as the die's does.
        if( match )
            acc <= cur_ch[0] ? pcm_in_long : ( pcm_in_long + acc );
        if(en_ch[0] && cur_ch[0])
            pcm_out <= { {4{acc[15]}}, acc }; // the wrapped bus, sign-extended to the junction
    end

endmodule // jt10_adpcm_acc
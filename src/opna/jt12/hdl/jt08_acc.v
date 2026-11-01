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
    
    Each channel can use the full range of the DAC as they do not
    get summed in the real chip.

    Operator data is summed up without adding extra bits. This is
    the case of real YM3438, which was used on Megadrive 2 models.


*/

// YM2608
// ADPCM inputs
// Full OP resolution
// No PCM
// 4 OP channels
//
// LOCAL CHANGE (this repository): the accumulator is 20-bit, and the complete
// FM+ADPCM-A+ADPCM-B sum is clamped to the 16-bit rail HERE, at this junction,
// then sign-extended back to 20 bits so the downstream SSG + 86-PCM mix stays
// wide. This is ymfm's own clamp point: ym2608::clock_fm_and_adpcm sums FM +
// ADPCM-A(0x3f) + ADPCM-B(1) into one accumulator and calls m_last_fm.clamp16()
// ONCE on the complete sum (ymfm_opn.cpp:1410-1414), and the SSG is added AFTER
// that clamp (ymfm_opn.cpp:~1317) - exactly as pc9821_opna adds it after this
// one (mix_l = fm_l + (psg_snd << 3)). This is the arrangement the known-good
// 8f8194e2 tip shipped (jt12_single_acc #(.win(16),.wout(16))). The A-1 tip
// (a194031e) moved the only clamp to the final DAC and delivered the raw sum
// here instead; that left the +-206,848 FM+drum peak to shove the SSG+PCM86 mix
// into the DAC rail and hard-clip the whole mix (the owner's real-listening
// regression). z486_mister's mix_dry remains the LAST clamp, for the SSG/PCM86
// tail added after this one (NP2kai's single _saturation_s16). win=wout=20 keeps
// THIS accumulator from wrapping before the clamp: 24 FM operator slots at +-2^12
// after the >>>1 (= +-98,304), the six-drum bus (the die's 16-BIT WRAPPING sum,
// sign-extended: +-32,768, jt08_adpcm_acc.v), and ADPCM-B at +-2^14 (+-16,384):
// +-147,456, which is inside 2^19 but EXCEEDS signed 18-bit (+-131,072).
// THAT BOUND IS OURS, NOT THE DIE'S. The die sums into an 18-bit WRAPPING
// accumulator (`ac_fm_accm1[0] &= 0x3ffff`, fmopna_impl.c:5321) and its output
// shifter then rails at +-32768 (`ac_shifter_top = (chip->ac_fm_accm1[1] >> 15) & 7;`,
// :5403). The die adds each carrier slot separately (`ac_fm_output_en =
// chip->alg_output_l;`, :5351; each slot (op_output[2] & 0x1fff) >> 1, :5347), so its
// FM bound is the same 24 x +-4096 = +-98,304 as ours. For every input THIS BUILD can
// reach (ADPCM-B unwired: +-98,304 +-32,768 = -131,072..+131,047, exactly the signed-18
// range) our clamp16 IS the die's rails; only an ADPCM-B contribution (ad_output << 2,
// +-16,384, :5394) could push the die's sum past +-131,072 and wrap it where we clamp.
// tb_pc9821_opna_junction_range pins the extremes.

module jt08_acc(
    input               clk,
    input               clk_en /* synthesis direct_enable */,
    input               cen,
    input signed [13:0] op_result,
    input        [ 1:0] rl,
    input               zero,
    input               s1_enters,
    input               s2_enters,
    input               s3_enters,
    input               s4_enters,
    input       [2:0]   cur_ch,
    input       [1:0]   cur_op,
    input   [2:0]       alg,
    // The six-drum bus from jt08_adpcm_acc: the die's 16-BIT WRAPPING sum,
    // sign-extended onto this 20-bit port. Not a wide sum - see its header note.
    input signed [19:0] adpcmA_l,
    input signed [19:0] adpcmA_r,
    input signed [15:0] adpcmB_l,
    input signed [15:0] adpcmB_r,
    // combined output
    output signed [19:0] left,
    output signed [19:0] right
);

reg sum_en;

always @(*) begin
    case ( alg )
        default: sum_en = s4_enters;
        3'd4: sum_en = s2_enters | s4_enters;
        3'd5,3'd6: sum_en = ~s1_enters;        
        3'd7: sum_en = 1'b1;
    endcase
end

wire left_en = rl[1];
wire right_en= rl[0];
wire signed [15:0] opext = { {2{op_result[13]}}, op_result };
reg  signed [19:0] acc_input_l, acc_input_r;
reg acc_en_l, acc_en_r;

wire int_clk_en;    // accumlate clk enable
reg cen_pcm_a, cen_pcm_b, pre_pcm_a, pre_pcm_b;


// YM2608 mode:
// ADPCM-A/B channels accumlate 2 cycle later than FM channels 0/4.

assign int_clk_en = clk_en | (cen & cen_pcm_a) | (cen & cen_pcm_b) ;

always @(posedge clk) begin
    if (cen) begin
        if (clk_en) begin
            case({cur_op,cur_ch})
                {2'd0,3'd0}: begin  // ADPCM-A:
                    pre_pcm_a <= 1'b1;
                end
                {2'd0,3'd4}: begin  // ADPCM-B:
                    pre_pcm_b <= 1'b1;
                end
                default: begin
                    pre_pcm_a <= 1'b0;
                    pre_pcm_b <= 1'b0;
                end
            endcase
        end else begin
            pre_pcm_a <= 1'b0;
            pre_pcm_b <= 1'b0;
        end
        cen_pcm_a <= pre_pcm_a;
        cen_pcm_b <= pre_pcm_b;
    end
end

always @(*)
    case( {cen_pcm_a,cen_pcm_b} )
        2'b10: begin // ADPCM-A:
            acc_input_l = adpcmA_l;
            acc_input_r = adpcmA_r;
            `ifndef NOMIX
            acc_en_l    = 1'b1;
            acc_en_r    = 1'b1;
            `else 
            acc_en_l    = 1'b0;
            acc_en_r    = 1'b0;
            `endif
        end
        2'b01: begin // ADPCM-B:
            // Operator width is 14 bit, ADPCM-B is 16 bit; the >>>1 balance is
            // upstream's, kept, then sign-extended to the 20-bit accumulator.
            acc_input_l = { {5{adpcmB_l[15]}}, adpcmB_l[15:1] };
            acc_input_r = { {5{adpcmB_r[15]}}, adpcmB_r[15:1] };
            `ifndef NOMIX
            acc_en_l    = 1'b1;
            acc_en_r    = 1'b1;
            `else 
            acc_en_l    = 1'b0;
            acc_en_r    = 1'b0;
            `endif
        end
        default: begin
            // Note by Jose Tejada:
            // I don't think we should divide down the FM output
            // but someone was looking at the balance of the different
            // channels and made this arrangement
            // I suppose ADPCM-A would saturate if taken up a factor of 8 instead of 4
            // I'll leave it as it is but I think it is worth revisiting this:
            acc_input_l = { {5{opext[15]}}, opext[15:1] };   // (opext >>> 1), sign-extended to 20
            acc_input_r = { {5{opext[15]}}, opext[15:1] };
            acc_en_l    = sum_en & left_en;
            acc_en_r    = sum_en & right_en;
        end
    endcase

// Continuous output: the 20-bit accumulator, clamped to the 16-bit ymfm
// clamp16 rail AT THIS JUNCTION (the complete FM+ADPCM-A+ADPCM-B sum), then
// sign-extended back to 20 bits so pc9821_opna can add the SSG - and
// pc9821_system the 86-PCM - without losing their own headroom. z486_mister's
// mix_dry stays the final clamp for that tail.
wire [19:0] snd_l_wide, snd_r_wide;
wire signed [19:0] snd_l_s = snd_l_wide;
wire signed [19:0] snd_r_s = snd_r_wide;

jt12_single_acc #(.win(20),.wout(20)) u_left(
    .clk        ( clk            ),
    .clk_en     ( int_clk_en     ),
    .op_result  ( acc_input_l    ),
    .sum_en     ( acc_en_l       ),
    .zero       ( zero           ),
    .snd        ( snd_l_wide     )
);

jt12_single_acc #(.win(20),.wout(20)) u_right(
    .clk        ( clk            ),
    .clk_en     ( int_clk_en     ),
    .op_result  ( acc_input_r    ),
    .sum_en     ( acc_en_r       ),
    .zero       ( zero           ),
    .snd        ( snd_r_wide     )
);

// ymfm's clamp16 on the complete FM+ADPCM sum (ymfm_opn.cpp:1410-1414): the
// junction clamp restored from the known-good 8f8194e2. The sign-extended
// 20-bit result keeps the mix downstream of this point wide.
wire signed [15:0] left_c  = (snd_l_s >  20'sd32767)  ? 16'sh7FFF :
                             (snd_l_s < -20'sd32768) ? 16'sh8000 : snd_l_s[15:0];
wire signed [15:0] right_c = (snd_r_s >  20'sd32767)  ? 16'sh7FFF :
                             (snd_r_s < -20'sd32768) ? 16'sh8000 : snd_r_s[15:0];
assign left  = { {4{left_c[15]}},  left_c };
assign right = { {4{right_c[15]}}, right_c };

`ifdef SIMULATION
// Dump each channel independently
// It dumps values in decimal, left and right
integer f0,f1,f2,f4,f5,f6;
reg signed [15:0] sum_l[0:7], sum_r[0:7];

initial begin
    f0=$fopen("fm0.raw","w");
    f1=$fopen("fm1.raw","w");
    f2=$fopen("fm2.raw","w");
    f4=$fopen("fm4.raw","w");
    f5=$fopen("fm5.raw","w");
    f6=$fopen("fm6.raw","w");
end

always @(posedge clk) begin
    if(cur_op==2'b0) begin
        sum_l[cur_ch] <= acc_en_l ? acc_input_l : 16'd0;
        sum_r[cur_ch] <= acc_en_r ? acc_input_r : 16'd0;
    end else begin
        sum_l[cur_ch] <= sum_l[cur_ch] + (acc_en_l ? acc_input_l : 16'd0);
        sum_r[cur_ch] <= sum_r[cur_ch] + (acc_en_r ? acc_input_r : 16'd0);
    end
end

always @(posedge zero) begin
    $fwrite(f0,"%d,%d\n", sum_l[0], sum_r[0]);
    $fwrite(f1,"%d,%d\n", sum_l[1], sum_r[1]);
    $fwrite(f2,"%d,%d\n", sum_l[2], sum_r[2]);
    $fwrite(f4,"%d,%d\n", sum_l[4], sum_r[4]);
    $fwrite(f5,"%d,%d\n", sum_l[5], sum_r[5]);
    $fwrite(f6,"%d,%d\n", sum_l[6], sum_r[6]);
end
`endif

endmodule

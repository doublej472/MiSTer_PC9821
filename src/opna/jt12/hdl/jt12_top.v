/*  This file is part of JT12.

    JT12 is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT12 is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT12.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 14-2-2016

    Based on information posted by Nemesis on:
http://gendev.spritesmind.net/forum/viewtopic.php?t=386&postdays=0&postorder=asc&start=167

    Based on jt51_phasegen.v, from JT51

    */

module jt12_top (
    input           rst,        // rst should be at least 6 clk&cen cycles long
    input           clk,        // CPU clock
    (* direct_enable *) input cen,        // optional clock enable, if not needed leave as 1'b1
    input   [7:0]   din,
    input   [1:0]   addr,
    input           cs_n,
    input           wr_n,
    input           rd_n,

    output  [7:0]   dout,
    output          irq_n,
    // Configuration
    input           en_hifi_pcm,  // high to enable PCM interpolation on YM2612 mode
    // LOCAL CHANGE (this repository, on top of r13/64): the RHYTHM (ADPCM-A) bus
    // attenuation is a RUNTIME 3-bit SHIFT, not a parameter, because the OSD's
    // "Rhythm volume" field drives it. It is applied to EACH of the six ADPCM-A drums
    // inside jt08_adpcm_acc, BEFORE the accumulator that sums them, because that sum
    // is hard-limited to 16 bits: four or more loud drums overlapping clamp it, and an
    // attenuation applied to the summed result (as r13/64/r13/117 did here) could only
    // scale an already distorted, flat-topped value. Steps 0..5 are 0/-6/-12/-18/-24/-30
    // dB; 0 = bit-identical to upstream, and is what a card with no config file passes.
    input   [2:0]   rhythm_gain_shift,
    // ADPCM pins
    output  [19:0]  adpcma_addr,  // real hardware has 10 pins multiplexed through RMPX pin
    output  [ 3:0]  adpcma_bank,
    output          adpcma_roe_n, // ADPCM-A ROM output enable
    input   [ 7:0]  adpcma_data,  // Data from RAM
    output  [23:0]  adpcmb_addr,  // real hardware has 12 pins multiplexed through PMPX pin
    input   [ 7:0]  adpcmb_data,
    output          adpcmb_roe_n, // ADPCM-B ROM output enable
    output          adpcmb_wr_n,  // ADPCM-B RAM write strobe
    output  [ 7:0]  adpcmb_dout,
    // I/O pins used by YM2203 embedded YM2149 chip
    input      [7:0] IOA_in,
    input      [7:0] IOB_in,
    output     [7:0] IOA_out,
    output     [7:0] IOB_out,
    output           IOA_oe,
    output           IOB_oe,
    // Separated output
    output          [ 9:0] psg_A,
    output          [ 9:0] psg_B,
    output          [ 9:0] psg_C,
    output  signed  [19:0] fm_snd_left,
    output  signed  [19:0] fm_snd_right,
    output  signed  [15:0] adpcmA_l,
    output  signed  [15:0] adpcmA_r,
    output  signed  [15:0] adpcmB_l,
    output  signed  [15:0] adpcmB_r,
    // combined output
    output          [11:0] psg_snd,
    output  signed  [19:0] snd_right, // FM+PSG
    output  signed  [19:0] snd_left,  // FM+PSG
    output                 snd_sample,
    input           [ 5:0] ch_enable, // ADPCM-A channels
    // LOCAL CHANGE (B-4, this repository): 0xA460 bit 0 dropping switches the
    // FM to NP2kai's 3-channel mono configuration (cbus/board86.c:79-94): FM
    // channels 3-5 are muted and channels 0-2 are forced to center. The board
    // glue drives this from its `extend` latch; see pc9821_opna.sv.
    input                 ch3_mono,
    // LOCAL CHANGE (flag-reset seam, this repository): the board glue's timer flag
    // reset, a one-clk pulse per flag ([0] timer A, [1] timer B) on the guest's data
    // write that resets it (0x27 bit 4/5, or 0x110 bit 7). The chip resets the flag at
    // the bus write (ymfm ymfm_fm.ipp engine_mode_write `set_reset_status(0, reset_mask);`,
    // ymfm_opn.cpp ym2608::write_data `m_fm.set_reset_status(0, 0xff);`; NP2kai
    // sound/opntimer.c opna_settimer `opna->s.status &= ~((cData & 0x30) >> 4);`), but
    // the glue feeds the register port through a queue (pc9821_opna.sv), so the reset
    // comes in here at the write instead and the queued copy no longer carries it.
    // [1] is also held high, a level, while the guest's 0x110 Timer-B mask (bit 1)
    // stands: a real Xe10 keeps that flag clear under the mask while the timer runs
    // (pc9821_opna.sv tmr_mask_b, docs/probes/KIT1-XE10-OPNA.TXT STATUS3).
    //   Only the YM2608 configuration (use_adpcm == 2) takes it.
    input           [ 1:0] host_clr_tmr,
    // The same seam carries the timer registers themselves: the glue's copy of 0x24
    // (NA high), 0x25 (NA low), 0x26 (NB) and 0x27 bits 3-0 (enable B/A, load B/A),
    // written at the guest's bus write, as {value_A[9:0], value_B[7:0], enable_irq_B,
    // enable_irq_A, load_B, load_A}. The chip acts on them at the write (ymfm
    // engine_mode_write `update_timer(0, m_regs.load_timer_a(), 0);`; NP2kai sound/opna.c
    // `opna_settimer(opna, cData);` on the register write), and the queue in front of the
    // register port would start or reload a timer up to its whole drain late. 0x27 bits
    // 7-6 (the CH3 mode, jt12_mmr's `effect`/`csm`) stay on the register port, ordered
    // with the FM writes queued before them. Only use_adpcm == 2 takes it.
    input           [21:0] host_tmr,
    input           [ 7:0] debug_bus,
    output          [ 7:0] debug_view
);

// parameters to select the features for each chip type
// defaults to YM2612
parameter use_lfo=1, use_ssg=0, num_ch=6, use_pcm=1;
parameter use_adpcm=0;
parameter JT49_COMP=3'd1,
          JT49_DIV=2,
          YM2203_LUMPED=0;
parameter mask_div=1;
parameter use_chipid=0;

wire flag_A, flag_B, busy;

wire write = !cs_n && !wr_n;
wire clk_en, clk_en_ssg;

// Timers
wire    [9:0]   value_A;
wire    [7:0]   value_B;
wire            load_A, load_B;
wire            enable_irq_A, enable_irq_B;
wire            clr_flag_A, clr_flag_B;
wire            overflow_A;
wire            fast_timers;
wire    [4:0]   irq_mask;

wire            zero; // Single-clock pulse at the begginig of s1_enters
// LFO
wire    [2:0]   lfo_freq;
wire            lfo_en;
// Operators
wire            amsen_IV;
wire    [ 2:0]  dt1_I;
wire    [ 3:0]  mul_II;
wire    [ 6:0]  tl_IV;

wire    [ 4:0]  keycode_II;
wire    [ 4:0]  ar_I;
wire    [ 4:0]  d1r_I;
wire    [ 4:0]  d2r_I;
wire    [ 3:0]  rr_I;
wire    [ 3:0]  sl_I;
wire    [ 1:0]  ks_II;
// SSG operation
wire            ssg_en_I;
wire    [2:0]   ssg_eg_I;
// envelope operation
wire            keyon_I;
wire    [9:0]   eg_IX;
wire            pg_rst_II;
// Channel
wire    [10:0]  fnum_I;
wire    [ 2:0]  block_I;
wire    [ 1:0]  rl;
wire    [ 2:0]  fb_II;
wire    [ 2:0]  alg_I;
wire    [ 2:0]  pms_I;
wire    [ 1:0]  ams_IV;
// PCM
wire            pcm_en, pcm_wr;
wire    [ 8:0]  pcm;
// Test
wire            pg_stop, eg_stop;

wire            ch6op;
wire    [ 2:0]  cur_ch;
wire    [ 1:0]  cur_op;

// Operator
wire            xuse_internal, yuse_internal;
wire            xuse_prevprev1, xuse_prev2, yuse_prev1, yuse_prev2;
wire    [ 9:0]  phase_VIII;
wire            s1_enters, s2_enters, s3_enters, s4_enters;
wire            rst_int;
// LFO
wire    [6:0]   lfo_mod;
wire            lfo_rst;
// PSG
wire    [3:0]   psg_addr;
wire    [7:0]   psg_data, psg_dout;
wire            psg_wr_n;
// ADPCM-A
wire [15:0] addr_a;
wire [ 2:0] up_addr, up_lracl;
wire        up_start, up_end;
wire [ 7:0] aon_a, lracl;
wire [ 5:0] atl_a;     // ADPCM Total Level
wire        up_aon;
// APDCM-B
wire        acmd_on_b;     // Control - Process start, Key On
wire        acmd_rep_b;    // Control - Repeat
wire        acmd_rst_b;    // Control - Reset
wire        acmd_up_b;     // Control - New cmd received
wire        acmd_rec_b;    // Control - YM2608 Recording
wire        acmd_mem_b;    // Control - YM2608 Select external memory
wire        acmd_x8_b;     // Control - YM2608 RAM 8bit granularity
wire        acmd_rom_b;    // Control - YM2608 ROM select
wire [ 1:0] alr_b;         // Left / Right
wire [15:0] astart_b;      // Start address
wire [15:0] aend_b;        // End   address
wire [10:0] prescaler_b;   // YM2608 Prescaler
wire [15:0] adeltan_b;     // Delta-N
wire [ 7:0] aeg_b;         // Envelope Generator Control
wire [15:0] alimit_b;      // YM2608 Limit Address
wire        sel_ram_dat;   // YM2608 Select RAM buffer
wire        sel_dac_dat;   // YM2608 Select DAC buffer
wire [ 7:0] dout_b;        // YM2608 DOUT (RAM/DAC to BUS)
wire [ 5:0] adpcma_flags;  // ADPMC-A read over flags
wire        adpcmb_flag;
wire [ 3:0] adpcmb_flag2;  // YM2608 ADPCM flags
wire [ 6:0] flag_ctl;
wire [ 6:0] flag_mask;
wire [ 1:0] div_setting;
// CONTROL
wire        sel_chipid;

wire clk_en_2, clk_en_666, clk_en_111, clk_en_55;

assign debug_view = { 4'd0, flag_B, flag_A, div_setting };

generate
if( use_adpcm==1 ) begin: gen_adpcm
    wire rst_n;

    jt12_rst u_rst(
        .rst    ( rst   ),
        .clk    ( clk   ),
        .rst_n  ( rst_n )
    );

    jt10_adpcm_drvA u_adpcm_a(
        .rst_n      ( rst_n         ),
        .clk        ( clk           ),
        .cen        ( cen           ),
        .cen6       ( clk_en_666    ),  // clk & cen must be 666  kHz
        .cen1       ( clk_en_111    ),  // clk & cen must be 111 kHz

        .addr       ( adpcma_addr   ),  // real hardware has 10 pins multiplexed through RMPX pin
        .bank       ( adpcma_bank   ),
        .roe_n      ( adpcma_roe_n  ),  // ADPCM-A ROM output enable
        .datain     ( adpcma_data   ),

        // Control Registers
        .atl        ( atl_a         ),        // ADPCM Total Level
        .addr_in    ( addr_a        ),
        .lracl_in   ( lracl         ),
        .up_start   ( up_start      ),
        .up_end     ( up_end        ),
        .up_addr    ( up_addr       ),
        .up_lracl   ( up_lracl      ),

        .aon_cmd    ( aon_a         ),    // ADPCM ON equivalent to key on for FM
        .up_aon     ( up_aon        ),
        // Flags
        .flags      ( adpcma_flags  ),
        .clr_flags  ( flag_ctl[5:0] ),

        .pcm55_l    ( adpcmA_l      ),
        .pcm55_r    ( adpcmA_r      ),
        .ch_enable  ( ch_enable     )
    );

    jt10_adpcm_drvB u_adpcm_b(
        .rst_n      ( rst_n         ),
        .clk        ( clk           ),
        .cen        ( cen           ),
        .cen55      ( clk_en_55     ),

        // Control
        .acmd_on_b  ( acmd_on_b     ),  // Control - Process start, Key On
        .acmd_rep_b ( acmd_rep_b    ),  // Control - Repeat
        .acmd_rst_b ( acmd_rst_b    ),  // Control - Reset
        .acmd_up_b  ( acmd_up_b     ),  // Control - New command received
        .alr_b      ( alr_b         ),  // Left / Right
        .astart_b   ( astart_b      ),  // Start address
        .aend_b     ( aend_b        ),  // End   address
        .adeltan_b  ( adeltan_b     ),  // Delta-N
        .aeg_b      ( aeg_b         ),  // Envelope Generator Control
        // Flag
        .flag       ( adpcmb_flag   ),
        .clr_flag   ( flag_ctl[6]   ),
        // memory
        .addr       ( adpcmb_addr   ),
        .data       ( adpcmb_data   ),
        .roe_n      ( adpcmb_roe_n  ),

        .pcm55_l    ( adpcmB_l      ),
        .pcm55_r    ( adpcmB_r      )
    );
    assign adpcmb_wr_n  = 1'b1;
    assign adpcmb_dout  = 8'h0;
    assign adpcmb_flag2 = 4'h0;
    assign dout_b       = 8'h0;

    assign snd_sample   = zero;
    jt10_acc u_acc(
        .clk        ( clk           ),
        .clk_en     ( clk_en        ),
        .op_result  ( op_result_hd  ),
        .rl         ( rl            ),
        .zero       ( zero          ),
        .s1_enters  ( s2_enters     ),
        .s2_enters  ( s1_enters     ),
        .s3_enters  ( s4_enters     ),
        .s4_enters  ( s3_enters     ),
        .cur_ch     ( cur_ch        ),
        .cur_op     ( cur_op        ),
        .alg        ( alg_I         ),
        .adpcmA_l   ( adpcmA_l      ),
        .adpcmA_r   ( adpcmA_r      ),
        .adpcmB_l   ( adpcmB_l      ),
        .adpcmB_r   ( adpcmB_r      ),
        // combined output
        .left       ( fm_snd_left   ),
        .right      ( fm_snd_right  )
    );
end
if( use_adpcm==2 ) begin: gen_adpcm
    wire rst_n;
    wire sel_ram;
    // The RHYTHM (ADPCM-A) drum bus: jt08_adpcm_acc's accumulator is the die's
    // 16-BIT WRAPPING six-drum sum (fmopna_impl.c:5370), sign-extended here, and
    // jt08_acc's output is the single clamp (the ymfm clamp16 junction on
    // FM+ADPCM-A). The 16-bit module ports adpcmA_l/r keep their old, clamped
    // meaning below for any external consumer.
    wire signed [19:0] adpcmA_sum_l, adpcmA_sum_r;

    jt12_rst u_rst(
        .rst    ( rst   ),
        .clk    ( clk   ),
        .rst_n  ( rst_n )
    );

    jt08_adpcm_drvA u_adpcm_a(
        .rst_n      ( rst_n         ),
        .clk        ( clk           ),
        .cen        ( cen           ),
        .cen6       ( clk_en_666    ),  // clk & cen must be 666  kHz
        .cen1       ( clk_en_111    ),  // clk & cen must be 111 kHz

        .addr       ( adpcma_addr   ),  // real hardware has 10 pins multiplexed through RMPX pin
        .bank       ( adpcma_bank   ),
        .roe_n      ( adpcma_roe_n  ),  // ADPCM-A ROM output enable
        .datain     ( adpcma_data   ),

        // Control Registers
        .atl        ( atl_a         ),        // ADPCM Total Level
        .addr_in    ( addr_a        ),
        .lracl_in   ( lracl         ),
        .up_start   ( up_start      ),
        .up_end     ( up_end        ),
        .up_addr    ( up_addr       ),
        .up_lracl   ( up_lracl      ),

        .aon_cmd    ( aon_a         ),    // ADPCM ON equivalent to key on for FM
        .up_aon     ( up_aon        ),

        // RHYTHM GAIN KNOB: each of the six drums is attenuated BEFORE the
        // 6-channel sum below, so lowering it removes the sum's clamp instead of
        // scaling an already flat-topped result. See jt08_adpcm_acc.v.
        .gain_shift ( rhythm_gain_shift ),
        .pcm55_l    ( adpcmA_sum_l  ),
        .pcm55_r    ( adpcmA_sum_r  ),
        .ch_enable  ( ch_enable     )
    );
    assign adpcma_flags = 6'b000000;
    assign adpcmA_l = (adpcmA_sum_l > 20'sd32767)  ? 16'sh7FFF :
                      (adpcmA_sum_l < -20'sd32768) ? 16'sh8000 : adpcmA_sum_l[15:0];
    assign adpcmA_r = (adpcmA_sum_r > 20'sd32767)  ? 16'sh7FFF :
                      (adpcmA_sum_r < -20'sd32768) ? 16'sh8000 : adpcmA_sum_r[15:0];
    
    jt08_adpcm_drvB u_adpcm_b(
        .rst_n      ( rst_n         ),
        .clk        ( clk           ),
        .cen        ( cen           ),
        .cen55      ( clk_en_55     ),

        // Control
        .acmd_on_b  ( acmd_on_b     ),  // Control - Process start, Key On
        .acmd_rep_b ( acmd_rep_b    ),  // Control - Repeat
        .acmd_rst_b ( acmd_rst_b    ),  // Control - Reset
        .acmd_up_b  ( acmd_up_b     ),  // Control - New command received
        .alr_b      ( alr_b         ),  // Left / Right
        .astart_b   ( astart_b      ),  // Start address
        .aend_b     ( aend_b        ),  // End   address
        .adeltan_b  ( adeltan_b     ),  // Delta-N
        .aeg_b      ( aeg_b         ),  // Envelope Generator Control
        .alimit_b   ( alimit_b      ),  // Limit address
        // Flag
        .flag       ( adpcmb_flag2  ),
        .clr_flag   ( flag_ctl[5:2] ),
        // memory
        .addr       ( adpcmb_addr   ),
        .ram_din    ( adpcmb_data   ),
        .ram_dout   ( adpcmb_dout   ),
        .ram_oe_n   ( adpcmb_roe_n  ),
        .ram_wr_n   ( adpcmb_wr_n   ),
        .bus_din    ( din           ),
        .bus_dout   ( dout_b        ),
        .sel_ram    ( sel_ram       ),
        .wr_n       ( wr_n          ),
        .rd_n       ( rd_n          ),
        .acmd_mem_b ( acmd_mem_b    ),
        .acmd_rec_b ( acmd_rec_b    ),
        .acmd_x8_b  ( acmd_x8_b     ),
        .acmd_rom_b ( acmd_rom_b    ),
        .pcm55_l    ( adpcmB_l      ),
        .pcm55_r    ( adpcmB_r      )
    );
    assign sel_ram = (~cs_n & sel_ram_dat);
    assign adpcmb_flag = 1'b0;
    
    assign snd_sample   = zero;
    // LOCAL CHANGE (B-4): 3-channel mono re-pans the FM at the accumulator's
    // input: channels 0-2 become center (both outputs) and channels 3-5 become
    // muted. The ADPCM-A/B inputs are not touched (the drum stop is a key-off
    // register write injected by pc9821_opna, not an output mute).
    wire [1:0] rl_3ch = ch3_mono ? ((cur_ch < 3'd3) ? 2'b11 : 2'b00) : rl;

    jt08_acc u_acc(
        .clk        ( clk           ),
        .clk_en     ( clk_en        ),
        .cen        ( cen           ),
        .op_result  ( op_result_hd  ),
        .rl         ( rl_3ch        ),
        .zero       ( zero          ),
        .s1_enters  ( s2_enters     ),
        .s2_enters  ( s1_enters     ),
        .s3_enters  ( s4_enters     ),
        .s4_enters  ( s3_enters     ),
        .cur_ch     ( cur_ch        ),
        .cur_op     ( cur_op        ),
        .alg        ( alg_I         ),
        // The RHYTHM gain is applied per drum inside u_adpcm_a; these carry the
        // die's 16-BIT WRAPPING drum bus (u_adpcm_a's pcm55_*), so the
        // FM+rhythm sum below saturates ONCE at its output - the junction
        // NP2kai/ymfm clamp.
        .adpcmA_l   ( adpcmA_sum_l  ),
        .adpcmA_r   ( adpcmA_sum_r  ),
        .adpcmB_l   ( adpcmB_l      ),
        .adpcmB_r   ( adpcmB_r      ),
        // combined output
        .left       ( fm_snd_left   ),
        .right      ( fm_snd_right  )
    );
end
if( use_adpcm==0 ) begin: gen_adpcm_no
    assign adpcmA_l     = 'd0;
    assign adpcmA_r     = 'd0;
    assign adpcmB_l     = 'd0;
    assign adpcmB_r     = 'd0;
    assign adpcma_addr  = 'd0;
    assign adpcma_bank  = 'd0;
    assign adpcma_roe_n = 'b1;
    assign adpcmb_addr  = 'd0;
    assign adpcmb_roe_n = 'd1;
    assign adpcmb_wr_n  = 'b1;
    assign adpcmb_dout  = 8'd0;
    assign dout_b       = 8'h0;
    assign adpcma_flags = 0;
    assign adpcmb_flag  = 0;
    assign adpcmb_flag2 = 0;
end
endgenerate

jt12_dout #(.use_ssg(use_ssg),.use_adpcm(use_adpcm),.use_chipid(use_chipid)) u_dout(
//    .rst_n          ( rst_n         ),
    .clk            ( clk           ),        // CPU clock
    .flag_A         ( flag_A        ),
    .flag_B         ( flag_B        ),
    .busy           ( busy          ),
    .sel_chipid     ( sel_chipid    ),
    .adpcma_flags   ( adpcma_flags & flag_mask[5:0] ),
    .adpcmb_flag    ( adpcmb_flag & flag_mask[6]    ),
    .adpcmb_flag2   ( adpcmb_flag2 & { 2'b1, flag_mask[4:2] } ),
    .psg_dout       ( psg_dout      ),
    .dout_b         ( dout_b        ),
    .addr           ( addr          ),
    .dout           ( dout          )
);

jt12_mmr #(.use_ssg(use_ssg),.num_ch(num_ch),.use_pcm(use_pcm), .use_adpcm(use_adpcm), .mask_div(mask_div), .use_chipid(use_chipid))
    u_mmr(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen        ( cen       ),  // external clock enable
    .clk_en     ( clk_en    ),  // internal clock enable
    .clk_en_2   ( clk_en_2  ),  // input cen divided by 2
    .clk_en_ssg ( clk_en_ssg),  // internal clock enable
    .clk_en_666 ( clk_en_666),
    .clk_en_111 ( clk_en_111),
    .clk_en_55  ( clk_en_55 ),
    .din        ( din       ),
    .write      ( write     ),
    .addr       ( addr      ),
    .busy       ( busy      ),
    .ch6op      ( ch6op     ),
    .cur_ch     ( cur_ch    ),
    .cur_op     ( cur_op    ),
    // LFO
    .lfo_freq   ( lfo_freq  ),
    .lfo_en     ( lfo_en    ),
    // Timers
    .value_A    ( value_A   ),
    .value_B    ( value_B   ),
    .load_A     ( load_A    ),
    .load_B     ( load_B    ),
    .enable_irq_A   ( enable_irq_A  ),
    .enable_irq_B   ( enable_irq_B  ),
    .clr_flag_A ( clr_flag_A    ),
    .clr_flag_B ( clr_flag_B    ),
    .flag_A     ( flag_A        ),
    .overflow_A ( overflow_A    ),
    .fast_timers( fast_timers   ),
    .irq_mask   ( irq_mask      ),
    // PCM
    .pcm        ( pcm           ),
    .pcm_en     ( pcm_en        ),
    .pcm_wr     ( pcm_wr        ),
    // ADPCM-A
    .aon_a      ( aon_a         ),   // ON
    .atl_a      ( atl_a         ),   // TL
    .addr_a     ( addr_a        ),   // address latch
    .lracl      ( lracl         ),   // L/R ADPCM Channel Level
    .up_start   ( up_start      ),   // write enable start address latch
    .up_end     ( up_end        ),   // write enable end address latch
    .up_addr    ( up_addr       ),   // write enable end address latch
    .up_lracl   ( up_lracl      ),
    .up_aon     ( up_aon        ),
    // ADPCM-B
    .acmd_on_b  ( acmd_on_b     ),  // Control - Process start, Key On
    .acmd_rep_b ( acmd_rep_b    ),  // Control - Repeat
    .acmd_rst_b ( acmd_rst_b    ),  // Control - Reset
    .acmd_up_b  ( acmd_up_b     ),  // Control - New command received
    .acmd_rec_b ( acmd_rec_b    ),
    .acmd_mem_b ( acmd_mem_b    ),
    .acmd_x8_b  ( acmd_x8_b     ),
    .acmd_rom_b ( acmd_rom_b    ),
    .alr_b      ( alr_b         ),  // Left / Right
    .astart_b   ( astart_b      ),  // Start address
    .aend_b     ( aend_b        ),  // End   address
    .adeltan_b  ( adeltan_b     ),  // Delta-N
    .aeg_b      ( aeg_b         ),  // Envelope Generator Control
    .flag_ctl   ( flag_ctl      ),
    .flag_mask  ( flag_mask     ),
    .alimit_b   ( alimit_b      ),
    .pscale_b   ( prescaler_b   ),
    .sel_ram_dat( sel_ram_dat   ),
    .sel_dac_dat( sel_dac_dat   ),
    // Operator
    .xuse_prevprev1 ( xuse_prevprev1  ),
    .xuse_internal  ( xuse_internal   ),
    .yuse_internal  ( yuse_internal   ),
    .xuse_prev2     ( xuse_prev2      ),
    .yuse_prev1     ( yuse_prev1      ),
    .yuse_prev2     ( yuse_prev2      ),
    // PG
    .fnum_I     ( fnum_I    ),
    .block_I    ( block_I   ),
    .pg_stop    ( pg_stop   ),
    // EG
    .rl         ( rl        ),
    .fb_II      ( fb_II     ),
    .alg_I      ( alg_I     ),
    .pms_I      ( pms_I     ),
    .ams_IV     ( ams_IV    ),
    .amsen_IV   ( amsen_IV  ),
    .dt1_I      ( dt1_I     ),
    .mul_II     ( mul_II    ),
    .tl_IV      ( tl_IV     ),

    .ar_I       ( ar_I      ),
    .d1r_I      ( d1r_I     ),
    .d2r_I      ( d2r_I     ),
    .rr_I       ( rr_I      ),
    .sl_I       ( sl_I      ),
    .ks_II      ( ks_II     ),

    .eg_stop    ( eg_stop   ),
    // SSG operation
    .ssg_en_I   ( ssg_en_I  ),
    .ssg_eg_I   ( ssg_eg_I  ),

    .keyon_I    ( keyon_I   ),
    // Operator
    .zero       ( zero      ),
    .s1_enters  ( s1_enters ),
    .s2_enters  ( s2_enters ),
    .s3_enters  ( s3_enters ),
    .s4_enters  ( s4_enters ),
    // PSG interace
    .psg_addr   ( psg_addr  ),
    .psg_data   ( psg_data  ),
    .psg_wr_n   ( psg_wr_n  ),
    .debug_bus  ( debug_bus ),
    .div_setting(div_setting),
    // Chip ID
    .sel_chipid ( sel_chipid)
);

// YM2203 seems to use a fixed cen/3 clock for the timers, regardless
// of the prescaler setting
wire timer_cen = fast_timers ? cen : clk_en;
generate 
    if (use_adpcm==2) begin
        jt12_timers #(.num_ch(num_ch)) u_timers (
            .clk        ( clk           ),
            .clk_en     ( timer_cen     ),
            .rst        ( rst           ),
            .zero       ( zero          ),
            // LOCAL CHANGE (flag-reset seam): the timer registers are the glue's
            // (host_tmr above), not the register port's.
            .value_A    ( host_tmr[21:12] ),
            .value_B    ( host_tmr[11:4]  ),
            .load_A     ( host_tmr[0]     ),
            .load_B     ( host_tmr[1]     ),
            .enable_irq_A( host_tmr[2]    ),
            .enable_irq_B( host_tmr[3]    ),
            // LOCAL CHANGE (flag-reset seam): the register port's reset or the glue's.
            .clr_flag_A ( clr_flag_A | host_clr_tmr[0] ),
            .clr_flag_B ( clr_flag_B | host_clr_tmr[1] ),
            .flag_A     ( flag_A        ),
            .flag_B     ( flag_B        ),
            .overflow_A ( overflow_A    ),
            .irq_n      (               )
        );
        // LOCAL CHANGE (flag-reset seam): the enables are the glue's (host_tmr).
        // LOCAL CHANGE (0x29 timer IRQ, this repository): register 0x29 does not gate
        // the timer IRQs; upstream ANDed irq_mask[0]/[1] into the Timer A/B terms. On a
        // real Xe10 with the -86 board, Timer A interrupted 21 times per 0.2 s window
        // with 0x29 = 1F, 03, 02 and 00 alike (docs/probes/YM29-XE10.TXT
        // `IRQ  v29=00 n=21 st_end=00 st_isr=01 irr_end=88 ticks=61440`), where the
        // gated core read n=0 at 02 and 00
        // (docs/probes/core/YM29-CORE-rc-1a0b94ba-s4.TXT). NEC's -86
        // SOUND.ROM writes 0x29 = 00 and then waits for a Timer A interrupt. Timer B
        // is measured too: it interrupted 21 times per window with 0x29 = 03, 02, 01
        // and 00 alike (docs/probes/YM29B-XE10.TXT
        // `IRQB v29=00 n=21 st_end=00 st_isr=02 irr_end=80 ticks=61440`), as NP2kai has
        // it (sound/opntimer.c fmport_a/fmport_b test only `reg[0x27] & 0x04` / `& 0x08`)
        // and against the die model's reg_irq gate. irq_mask[4:2] still
        // gates the ADPCM flags (EOS, BRDY, ZERO), which the capture does not cover.
        assign irq_n = ~( (flag_A&host_tmr[2]&flag_mask[0]) | (flag_B&host_tmr[3]&flag_mask[1]) | (|(adpcmb_flag2[2:0]&flag_mask[4:2]&irq_mask[4:2])) );

    end else begin
        jt12_timers #(.num_ch(num_ch)) u_timers (
            .clk        ( clk           ),
            .clk_en     ( timer_cen     ),
            .rst        ( rst           ),
            .zero       ( zero          ),
            .value_A    ( value_A       ),
            .value_B    ( value_B       ),
            .load_A     ( load_A        ),
            .load_B     ( load_B        ),
            .enable_irq_A( enable_irq_A ),
            .enable_irq_B( enable_irq_B ),
            .clr_flag_A ( clr_flag_A    ),
            .clr_flag_B ( clr_flag_B    ),
            .flag_A     ( flag_A        ),
            .flag_B     ( flag_B        ),
            .overflow_A ( overflow_A    ),
            .irq_n      ( irq_n         )
        );
    end
endgenerate

// YM2203 does not have LFO
generate
if( use_lfo== 1) begin : gen_lfo
    jt12_lfo u_lfo(
        .rst        ( rst       ),
        .clk        ( clk       ),
        .clk_en     ( clk_en    ),
        .zero       ( zero      ),
        `ifdef NOLFO
        .lfo_rst    ( 1'b1      ),
        `else
        .lfo_rst    ( 1'b0      ),
        `endif
        .lfo_en     ( lfo_en    ),
        .lfo_freq   ( lfo_freq  ),
        .lfo_mod    ( lfo_mod   )
    );
end else begin : gen_nolfo
    assign lfo_mod = 7'd0;
end
endgenerate

// YM2203/YM2608/YM2610 have a PSG

`ifndef NOSSG
generate
    if( use_ssg==1 ) begin : gen_ssg
        jt49 #(.COMP(JT49_COMP), .CLKDIV(JT49_DIV), .YM2203_LUMPED(YM2203_LUMPED))
            u_psg( // note that input ports are not multiplexed
            .rst_n      ( ~rst      ),
            .clk        ( clk       ),    // signal on positive edge
            .clk_en     ( clk_en_ssg),    // clock enable on negative edge
            .addr       ( psg_addr  ),
            .cs_n       ( 1'b0      ),
            .wr_n       ( psg_wr_n  ),  // write
            .din        ( psg_data  ),
            .sound      ( psg_snd   ),  // combined output
            .A          ( psg_A     ),
            .B          ( psg_B     ),
            .C          ( psg_C     ),
            .dout       ( psg_dout  ),
            .sel        ( 1'b1      ),  // half clock speed
            .IOA_out    ( IOA_out   ),
            .IOB_out    ( IOB_out   ),
            .IOA_in     ( IOA_in    ),
            .IOB_in     ( IOB_in    ),
            .IOA_oe     ( IOA_oe    ),
            .IOB_oe     ( IOB_oe    ),
            // Unused:
            .sample     (           )
        );
        // DEAD: jtopna leaves .snd_left()/.snd_right() unconnected (pc9821_opna does the
        // board's FM+ADPCM+SSG join itself, and review2/opna-audit A-11 was corrected to
        // psg_snd << 2). Kept ALIGNED with that shipped join so wiring this upstream
        // combined output cannot reintroduce the SSG-2x-hot bug: << 2 is the PC88 board
        // join for THIS chip (PC88MiSTer.vhd:2505, the JTOPNA/YM2608 path), where upstream
        // wrote << 3 for the YM2203 (OPN) path, a different chip with a different SSG scale.
        assign snd_left  = fm_snd_left  + { 6'b0, psg_snd[11:0],2'd0};
        assign snd_right = fm_snd_right + { 6'b0, psg_snd[11:0],2'd0};
    end else begin : gen_nossg
        assign psg_snd  = 12'd0;
        assign snd_left = fm_snd_left;
        assign snd_right= fm_snd_right;
        assign psg_dout = 8'd0;
        assign psg_A    = 10'd0;
        assign psg_B    = 10'd0;
        assign psg_C    = 10'd0;
        assign IOA_oe   = 0;
        assign IOB_oe   = 0;
        assign IOA_out  = 0;
        assign IOB_out  = 0;
    end
endgenerate
`else
    assign psg_snd  = 12'd0;
    assign snd_left = fm_snd_left;
    assign snd_right= fm_snd_right;
    assign psg_dout = 8'd0;
`endif

wire    [ 8:0]  op_result;
wire    [13:0]  op_result_hd;
`ifndef NOFM

jt12_pg #(.num_ch(num_ch)) u_pg(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .clk_en     ( clk_en        ),
    // Channel frequency
    .fnum_I     ( fnum_I        ),
    .block_I    ( block_I       ),
    // Operator multiplying
    .mul_II     ( mul_II        ),
    // Operator detuning
    .dt1_I      ( dt1_I         ), // same as JT51's DT1
    // Phase modulation by LFO
    .lfo_mod    ( lfo_mod       ),
    .pms_I      ( pms_I         ),
    // phase operation
    .pg_rst_II  ( pg_rst_II     ),
    .pg_stop    ( pg_stop       ),
    .keycode_II ( keycode_II    ),
    .phase_VIII ( phase_VIII    )
);

wire [9:0] eg_V;

jt12_eg #(.num_ch(num_ch)) u_eg(
    .rst            ( rst           ),
    .clk            ( clk           ),
    .clk_en         ( clk_en        ),
    .zero           ( zero          ),
    .eg_stop        ( eg_stop       ),
    // envelope configuration
    .keycode_II     ( keycode_II    ),
    .arate_I        ( ar_I          ), // attack  rate
    .rate1_I        ( d1r_I         ), // decay   rate
    .rate2_I        ( d2r_I         ), // sustain rate
    .rrate_I        ( rr_I          ), // release rate
    .sl_I           ( sl_I          ), // sustain level
    .ks_II          ( ks_II         ), // key scale
    // SSG operation
    .ssg_en_I       ( ssg_en_I      ),
    .ssg_eg_I       ( ssg_eg_I      ),
    // envelope operation
    .keyon_I        ( keyon_I       ),
    // envelope number
    .lfo_mod        ( lfo_mod       ),
    .tl_IV          ( tl_IV         ),
    .ams_IV         ( ams_IV        ),
    .amsen_IV       ( amsen_IV      ),

    .eg_V           ( eg_V          ),
    .pg_rst_II      ( pg_rst_II     )
);

jt12_sh #(.width(10),.stages(4)) u_egpad(
    .clk    ( clk       ),
    .clk_en ( clk_en    ),
    .din    ( eg_V      ),
    .drop   ( eg_IX     )
);

jt12_op #(.num_ch(num_ch)) u_op(
    .rst            ( rst           ),
    .clk            ( clk           ),
    .clk_en         ( clk_en        ),
    .pg_phase_VIII  ( phase_VIII    ),
    .eg_atten_IX    ( eg_IX         ),
    .fb_II          ( fb_II         ),

    .test_214       ( 1'b0          ),
    .s1_enters      ( s1_enters     ),
    .s2_enters      ( s2_enters     ),
    .s3_enters      ( s3_enters     ),
    .s4_enters      ( s4_enters     ),
    .xuse_prevprev1 ( xuse_prevprev1),
    .xuse_internal  ( xuse_internal ),
    .yuse_internal  ( yuse_internal ),
    .xuse_prev2     ( xuse_prev2    ),
    .yuse_prev1     ( yuse_prev1    ),
    .yuse_prev2     ( yuse_prev2    ),
    .zero           ( zero          ),
    .op_result      ( op_result     ),
    .full_result    ( op_result_hd  )
);
`else
assign op_result    = 'd0;
assign op_result_hd = 'd0;
`endif

generate
    if( use_pcm==1 ) begin: gen_pcm_acc // YM2612 accumulator
        assign fm_snd_right[3:0] = 4'd0;
        assign fm_snd_left [3:0] = 4'd0;
        assign snd_sample        = zero;
        reg signed [8:0] pcm2;

        // interpolate PCM samples with automatic sample rate detection
        // this feature is not present in original YM2612
        // this improves PCM sample sound greatly
        /*
        jt12_pcm u_pcm(
            .rst        ( rst       ),
            .clk        ( clk       ),
            .clk_en     ( clk_en    ),
            .zero       ( zero      ),
            .pcm        ( pcm       ),
            .pcm_wr     ( pcm_wr    ),
            .pcm_resampled ( pcm2   )
        );
        */
        wire rst_pcm_n;

        jt12_rst u_rst_pcm(
            .rst    ( rst       ),
            .clk    ( clk       ),
            .rst_n  ( rst_pcm_n )
        );

        `ifndef NOPCMLINEAR
        wire signed [10:0] pcm_full;
        always @(*)
            pcm2 = en_hifi_pcm ? pcm_full[9:1] : pcm;

        jt12_pcm_interpol #(.DW(11), .stepw(5)) u_pcm (
            .rst_n ( rst_pcm_n      ),
            .clk   ( clk            ),
            .cen   ( clk_en         ),
            .cen55 ( clk_en_55      ),
            .pcm_wr( pcm_wr         ),
            .pcmin ( {pcm[8],pcm, 1'b0}    ),
            .pcmout( pcm_full       )
        );
        `else
        assign pcm2 = pcm;
        `endif

        jt12_acc u_acc(
            .rst        ( rst       ),
            .clk        ( clk       ),
            .clk_en     ( clk_en    ),
            .op_result  ( op_result ),
            .rl         ( rl        ),
            // note that the order changes to deal
            // with the operator pipeline delay
            .zero       ( zero      ),
            .s1_enters  ( s2_enters ),
            .s2_enters  ( s1_enters ),
            .s3_enters  ( s4_enters ),
            .s4_enters  ( s3_enters ),
            .ch6op      ( ch6op     ),
            .pcm_en     ( pcm_en    ),  // only enabled for channel 6
            .pcm        ( pcm2      ),
            .alg        ( alg_I     ),
            // combined output
            .left       ( fm_snd_left [15:4]  ),
            .right      ( fm_snd_right[15:4]  )
        );
    end
    if( use_pcm==0 && use_adpcm==0 ) begin : gen_2203_acc // YM2203 accumulator
        wire signed [15:0] mono_snd;
        assign fm_snd_left  = mono_snd;
        assign fm_snd_right = mono_snd;
        assign snd_sample   = zero;
        jt03_acc u_acc(
            .rst        ( rst       ),
            .clk        ( clk       ),
            .clk_en     ( clk_en    ),
            .op_result  ( op_result_hd ),
            // note that the order changes to deal
            // with the operator pipeline delay
            .s1_enters  ( s1_enters ),
            .s2_enters  ( s2_enters ),
            .s3_enters  ( s3_enters ),
            .s4_enters  ( s4_enters ),
            .alg        ( alg_I     ),
            .zero       ( zero      ),
            // combined output
            .snd        ( mono_snd  )
        );
    end
endgenerate

`ifdef SIMULATION
integer fsnd;
initial begin
    fsnd=$fopen("jt12.raw","wb");
end

always @(posedge zero) begin
    $fwrite(fsnd,"%u", {snd_left, snd_right});
end
`endif
endmodule

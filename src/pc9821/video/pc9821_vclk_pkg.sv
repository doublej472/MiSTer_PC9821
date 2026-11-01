// The PC-98's two dot clocks and the video PLL settings that reproduce them: ONE place, read by the
// dot enable on clk_sys (pc9821_dot_ce), the video PLL's controller (pc9821_vpll_ctl) and the
// generator's read-back (tools/profile_gen.py VCLK_SETTINGS, which must carry the same numbers).
//
// THE VIDEO PLL is a fractional-N PLL on the board's 50 MHz reference with N bypassed and C0 = 19:
//   CLK_VIDEO = 50 MHz x (M + K / 2^32) / 19,   and every dot clock below is CLK_VIDEO / 2.
// The dot enable on clk_sys runs at exactly the same rational number (pc9821_dot_ce), so the
// FIFO between the two (pc9821_video_out) never drifts: the two sides are the same ratio of the
// one 50 MHz crystal.
//
// 24 kHz (0x09A8 bit 0 clear): 400/19 MHz = 21.052 632 MHz, M 16, K 0 (VCO 800 MHz).
//   The rate is the modelling assumption pc9821_dot_ce documents. docs/probes/CRT31K.TXT's 24 kHz
//   rows read 21 051 001 Hz against the ARTIC's nominal 307 200 Hz; the decoder takes the
//   21 052 600 Hz nominal as the ARTIC's calibration, so those rows check the method, not this rate.
// 31 kHz (0x09A8 bit 0 set): the Xe10's SEPARATE 31 kHz oscillator, MEASURED: docs/probes/CRT31K.TXT
//   `RUN frames=70 ticks=306930` with the BIOS 31 kHz master SYNC (800 x 449) is a 70.0616 Hz frame
//   and 25 168 031 Hz once the ARTIC is calibrated by the same run's 24 kHz rows
//   (tools/hwprobe/crt31k/crt31k_decode.py). That is a VGA-class 25.175 MHz part (-276 ppm), NOT
//   NP2kai's `{25260000 / 8, ...}` (io/gdc.c:36, whose comment says the 31 kHz clock is unknown):
//   the capture outranks NP2kai and this is the stated divergence.
//   M 19, K 0x20B0_0000 = 19 + 523/4096: 50 MHz x 78347/4096 / 38 = 25 168 007.30 Hz, -0.94 ppm
//   from the capture (below its ~3 ppm ARTIC resolution). K keeps 12 fraction bits so the dot
//   enable's accumulator stays 21 bits at the shipped 90 MHz (DEN 1400832); the 32-bit K would be
//   0.000 ppm at 36 bits.
// There is no 15 kHz TV converter (no composite/S-Video output), so these two are the whole set.
`timescale 1ns / 1ps

package pc9821_vclk_pkg;
	localparam int unsigned VPLL_C     = 19;
	localparam int unsigned VPLL_M24   = 16;
	localparam int unsigned VPLL_K24   = 32'h0000_0000;
	localparam int unsigned VPLL_M31   = 19;
	localparam int unsigned VPLL_K31   = 32'h20B0_0000;
	// The K fraction bits the dot enable keeps: every K above is a multiple of 2^(32 - FRAC_BITS).
	localparam int unsigned FRAC_BITS  = 12;
endpackage

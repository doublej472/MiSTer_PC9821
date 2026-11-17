// The PC-98's two dot clocks and the video PLL settings that reproduce them: ONE place, read by the
// dot enable on clk_sys (pc9821_dot_ce), the video PLL's controller (pc9821_vpll_ctl) and the
// generator's read-back (tools/profile_gen.py VCLK_SETTINGS, which must carry the same numbers).
//
// THE VIDEO PLL is a fractional-N PLL on the board's 50 MHz reference with N bypassed and C0 = 24:
//   CLK_VIDEO = 50 MHz x (M + K / 2^32) / 24,   and every dot clock below is CLK_VIDEO / 2.
// The dot enable on clk_sys runs at exactly the same rational number (pc9821_dot_ce), so the
// FIFO between the two (pc9821_video_out) never drifts: the two sides are the same ratio of the
// one 50 MHz crystal. C0 is the same in both settings, so a switch rewrites only M and K
// (pc9821_vpll_ctl): the framework's reconfiguration core cannot be trusted with a C counter
// (sys/pll_cfg/pll_cfg_hdmi.v writes physical counter 5 whatever counter the write selects).
//
// EVERY SETTING KEEPS THE FRACTION K/2^32 INSIDE 0.05..0.95. That is the fractional-N PLL's legal
// range: Quartus 17.0's PLL generator rejects a setting outside it ("Error: vpll: The specified
// configuration creates a fractional multiplication factor outside of the legal range (0.05 to
// 0.95)", and for K = 0 also "gui_frac_multiply_factor 0 is out of range: 1-4294967295"). The
// 24 kHz setting was M 16, K 0, C0 19 (exactly 800/19 MHz) until 2026-11-16: an integer M on the
// fractional loop, which the generator refuses, programmed on every core load. With it, about 3 %
// of core loads on a card showed no picture until the next load (the scaler's input never
// received a frame; 5 of 171 loads). No legal setting makes 800/19 MHz exactly: M + K/2^32 =
// 16 x C0 / 19 (N bypassed) is an integer when 19 divides C0 and otherwise a repeating binary
// fraction, so the 24 kHz rate is the closest legal one FRAC_BITS can carry. C0 24 is the C0 that
// puts both settings' fractions in range with the 24 kHz clock closest to 800/19 MHz at 16 bits.
//
// 24 kHz (0x09A8 bit 0 clear): 400/19 MHz = 21.052 632 MHz nominal. M 20, K 0x35E5_0000:
//   50 MHz x (20 + 13797/65536) / 48 = 21 052 630.74 Hz, -0.040 ppm from 400/19 MHz (VCO 1010.53
//   MHz, fraction 0.2105). The rate is the modelling assumption pc9821_dot_ce documents.
//   docs/probes/CRT31K.TXT's 24 kHz rows read 21 051 001 Hz against the ARTIC's nominal 307 200 Hz;
//   the decoder takes the 21 052 600 Hz nominal as the ARTIC's calibration, so those rows check the
//   method, not this rate.
// 31 kHz (0x09A8 bit 0 set): the Xe10's SEPARATE 31 kHz oscillator, MEASURED: docs/probes/CRT31K.TXT
//   `RUN frames=70 ticks=306930` with the BIOS 31 kHz master SYNC (800 x 449) is a 70.0616 Hz frame
//   and 25 168 031 Hz once the ARTIC is calibrated by the same run's 24 kHz rows
//   (tools/hwprobe/crt31k/crt31k_decode.py). That is a VGA-class 25.175 MHz part (-276 ppm), NOT
//   NP2kai's `{25260000 / 8, ...}` (io/gdc.c:36, whose comment says the 31 kHz clock is unknown):
//   the capture outranks NP2kai and this is the stated divergence.
//   M 24, K 0x294C_0000 = 24 + 10572/65536: 50 MHz x 1583436/65536 / 48 = 25 168 037.41 Hz,
//   +0.255 ppm from the capture (below its ~3 ppm ARTIC resolution; VCO 1208.07 MHz, fraction 0.1613).
// FRAC_BITS 16: every K is a multiple of 2^16, which the dot enable keeps exactly (a 26-bit
// accumulator at the shipped 90 MHz, DEN 28311552).
// THE GENERATED SETTING is the 24 kHz one (VPLL_GEN_31 0): the PLL powers up in the configuration
// the guest starts in, so a core load reconfigures nothing (pc9821_vpll_ctl), and the SDC times the
// video domain at the faster 31 kHz period (tools/profile/z486_mister.sdc.in).
// There is no 15 kHz TV converter (no composite/S-Video output), so these two are the whole set.
`timescale 1ns / 1ps

package pc9821_vclk_pkg;
	localparam int unsigned VPLL_C     = 24;
	localparam int unsigned VPLL_M24   = 20;
	localparam int unsigned VPLL_K24   = 32'h35E5_0000;
	localparam int unsigned VPLL_M31   = 24;
	localparam int unsigned VPLL_K31   = 32'h294C_0000;
	// The configuration the PLL is generated in (and so powers up in): 0 = the 24 kHz one.
	// Read only by pc9821_vpll_ctl: a lint top without the controller imports this package for the
	// dot enable alone.
	/* verilator lint_off UNUSEDPARAM */
	localparam int unsigned VPLL_GEN_31 = 0;
	/* verilator lint_on UNUSEDPARAM */
	// The K fraction bits the dot enable keeps: every K above is a multiple of 2^(32 - FRAC_BITS).
	localparam int unsigned FRAC_BITS  = 16;
endpackage

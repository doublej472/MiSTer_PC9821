// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2018 Sorgelig. Derived from Template_MiSTer sys/video_cleaner.sv
// (https://github.com/MiSTer-devel/Template_MiSTer; upstream: "GPL Licensed"). See NOTICE, part 2.

// The framework's video_cleaner (sys/video_cleaner.sv, Copyright (c) 2018 Sorgelig, GPL), reduced
// to what this core uses of it and with its polarity detectors' counters sized for this core.
//
// What z486_mister.sv used: HBlank/VBlank/interlace/f1 TIED 0 and VGA_DE/HBlank_out/VBlank_out
// UNCONNECTED (the chain carries blanking in DE), so the module is the two sync-polarity fixers,
// one ce_pix register stage on R/G/B/HS/DE, and VS re-timed to the leading edge of HS - exactly the
// upstream module's `interlace & f1 == 0` arm with hbl = hs. Those statements are copied, not
// rewritten.
//
// THE ONE CHANGE is the polarity detector's three counters. Upstream's s_fix keeps `integer`
// (32-bit) counts of clk_vid cycles: `cnt` since the last sync edge, `neg` the last low phase,
// `pos` the last high phase, and outputs `pol = pos > neg` - "the longer phase is the inactive
// one". Here the counters SATURATE at SAT_CYCLES-1 (CLOCK_RATE_HZ/16 clocks = 62.5 ms at any
// clock rate), in COUNT_W bits. The comparison is unchanged whenever at most one of the two
// phases being compared reached the bound, because a saturated value still exceeds every shorter
// one; so the output is bit-identical for every sync waveform whose ACTIVE pulse is shorter than
// 62.5 ms. The core's syncs are the GDC's: the HSYNC pulse is a fraction of one line and the
// VSYNC pulse is the SYNC block's 5-bit vs field (pc9821_crtc.sv, VSYNC_W), at most 31 lines of a
// line no longer than 3328 dots at 21.0526 MHz (158 us), i.e. under 5 ms. A stuck sync (both
// counts frozen) behaves as upstream does too: pos and neg are only sampled at edges. The only
// waveform that separates them is a sync whose two phases are BOTH longer than 62.5 ms, which no
// SYNC block can program - or a phase longer than 2^31 clocks (43 s at 50 MHz), where upstream's
// signed `integer` count wraps negative and this one does not. tb_pc9821_video_cleaner_equiv
// runs the two side by side.
`timescale 1ns / 1ps

module pc9821_video_cleaner #(
	parameter integer CLOCK_RATE_HZ = 50_000_000
) (
	input            clk_vid,
	input            ce_pix,
	input      [7:0] R,
	input      [7:0] G,
	input      [7:0] B,
	input            HSync,
	input            VSync,
	input            DE_in,
	output reg [7:0] VGA_R,
	output reg [7:0] VGA_G,
	output reg [7:0] VGA_B,
	output reg       VGA_VS,
	output reg       VGA_HS,
	output reg       DE_out
);

localparam integer SAT_CYCLES = CLOCK_RATE_HZ / 16;
localparam integer COUNT_W    = $clog2(SAT_CYCLES);

wire hs, vs;
pc9821_sync_pol #(.COUNT_W(COUNT_W), .SAT(SAT_CYCLES - 1)) sync_v (clk_vid, HSync, hs);
pc9821_sync_pol #(.COUNT_W(COUNT_W), .SAT(SAT_CYCLES - 1)) sync_h (clk_vid, VSync, vs);

always @(posedge clk_vid) begin
	if(ce_pix) begin
		VGA_HS <= hs;
		VGA_R  <= R;
		VGA_G  <= G;
		VGA_B  <= B;
		DE_out <= DE_in;
		if(~VGA_HS & hs) VGA_VS <= vs;
	end
end

endmodule

// upstream s_fix with saturating COUNT_W-bit counters (see the header above). It lives in this file
// because it is this module's private half, as s_fix is video_cleaner's in sys/video_cleaner.sv.
/* verilator lint_off DECLFILENAME */
module pc9821_sync_pol #(
	parameter integer COUNT_W = 22,
	parameter integer SAT     = (1 << 22) - 1
) (
	input  clk,
	input  sync_in,
	output sync_out
);

assign sync_out = sync_in ^ pol;

reg pol;
// The counters start at 0, as upstream's `integer pos = 0, neg = 0, cnt = 0` do.
/* verilator lint_off PROCASSINIT */
reg [COUNT_W-1:0] pos = '0, neg = '0, cnt = '0;
reg s1, s2;
/* verilator lint_on PROCASSINIT */
always @(posedge clk) begin
	s1 <= sync_in;
	s2 <= s1;

	if(~s2 & s1) neg <= cnt;
	if(s2 & ~s1) pos <= cnt;

	if(cnt != COUNT_W'(SAT)) cnt <= cnt + 1'd1;
	if(s2 != s1) cnt <= '0;

	pol <= pos > neg;
end

endmodule
/* verilator lint_on DECLFILENAME */

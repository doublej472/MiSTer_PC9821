// The PC-98 dot enable on clk_sys: one cycle per dot at EXACTLY 400/19 MHz (21.052 631 6 MHz), the
// 24 kHz mode's dot rate, at any clk_sys - or, while 0x09A8 bit 0 is set (`c31`), at the 31 kHz
// mode's measured 25.168 MHz (pc9821_vclk_pkg has the capture and the exact ratio).
//
// THE RATE. 400/19 MHz = 50 MHz x 8/19: the board's 50 MHz reference times 8/19, which is also what
// the video PLL makes its own clock from (2 x 400/19 MHz = 800 MHz / 19, tools/profile/vpll_template.v).
// The rate is a MODELLING ASSUMPTION, not a measurement of the machine's dot clock: the in-tree
// corroboration is the raster (the probed horizontal blank is 208/848 = 24.53 % of a line, an 848-dot
// line at the ~24.8 kHz the machine runs; docs/pc9821-port-status.md "Pixel clock and the video
// pipeline" has the derivation). It is an exact ratio, not the carry of a fixed-width accumulator
// (a 24-bit one stepping round(21_052_600 x 2^24 / SYS_FREQ) lands 1.5 ppm below this rate).
//
// WHY EXACT. The analog output reads the core's picture through a small FIFO into the video clock
// domain (pc9821_video_out). The video clock is 2 x 400/19 MHz from the same 50 MHz reference and clk_sys
// is an integer-N PLL output of it (build_profile.py verifies both read back exactly), so the two
// sides' dot rates are the same rational number and the FIFO's fill can never drift: no frame is
// dropped or repeated, and the output needs no slip correction.
//
// THE ACCUMULATOR. ce fires NUM times every DEN clocks, NUM/DEN = dot rate / SYS_FREQ. Both rates are
// 25 MHz x (M + K/2^32) / 19 (the video PLL's output over two, pc9821_vclk_pkg), so they share one
// denominator and only NUM moves with `c31`: at the shipped 90 MHz the 24 kHz rate is 40/171
// (scaled by the common factor to 327680/1400832, which leaves its enable pattern bit-identical
// to the 40/171 accumulator's) and the 31 kHz rate 391735/1400832 (21 bits). Each dot is floor or
// ceil of DEN/NUM clocks (4 or 5 at 90 MHz for the 24 kHz dot, 3 or 4 for the 31 kHz one); only
// the average matters on this side. A change of `c31` takes effect on the next clock
// (the machine switches oscillators with the port write; the raster just runs on at the new rate).
//
// GUEST-VISIBLE: every raster event the guest can see (pc9821_crtc's vsync IRQ, the GDC status bits,
// the line timing) counts these enables, so the guest's time base is this rate at every clk_sys
// (tb_pc9821_sysclk_invariance).
`timescale 1ns / 1ps

module pc9821_dot_ce #(
	parameter integer SYS_FREQ = 50_000_000
) (
	input  clk,
	input  reset,
	input  c31,                                     // 0x09A8 bit 0: the 31 kHz dot clock
	output ce
);

import pc9821_vclk_pkg::*;

function automatic longint gcd(input longint a, input longint b);
	longint x, y, t;
	x = a;
	y = b;
	while (y != 0) begin
		t = x % y;
		x = y;
		y = t;
	end
	return x;
endfunction

// rate / SYS_FREQ = 25e6 x (M x 2^F + K >> (32 - F)) / (19 x 2^F x SYS_FREQ), F = FRAC_BITS.
localparam longint SCALE     = 64'd1 << FRAC_BITS;
localparam longint KSH       = 64'd32 - longint'(FRAC_BITS);
localparam longint MK24      = longint'(VPLL_M24) * SCALE + (longint'(VPLL_K24) >> KSH);
localparam longint MK31      = longint'(VPLL_M31) * SCALE + (longint'(VPLL_K31) >> KSH);
localparam longint NUM24_RAW = 64'd25_000_000 * MK24;
localparam longint NUM31_RAW = 64'd25_000_000 * MK31;
localparam longint DEN_RAW   = longint'(VPLL_C) * SCALE * longint'(SYS_FREQ);
localparam longint G         = gcd(gcd(NUM24_RAW, NUM31_RAW), DEN_RAW);
localparam longint NUM24     = NUM24_RAW / G;
localparam longint NUM31     = NUM31_RAW / G;
localparam longint DEN       = DEN_RAW / G;
localparam integer W         = $clog2(DEN + NUM31 + 1);

// The K this enable keeps must be the K the PLL is programmed with: no bits below FRAC_BITS.
generate if (((longint'(VPLL_K24) | longint'(VPLL_K31)) & ((64'd1 << KSH) - 1)) != 0) begin : g_k_bits
	pc9821_dot_ce_k_has_bits_below_frac_bits k_bits ();
end endgenerate

// The dot must be slower than clk_sys. The guard is an instance of a module that does not exist, so
// a too-slow configuration fails elaboration in every tool (Quartus 17 has no elaboration-time $error).
generate if (NUM31 >= DEN || NUM24 >= DEN) begin : g_too_slow
	pc9821_dot_ce_needs_clk_sys_above_25_17_MHz too_slow ();
end endgenerate

reg  [W-1:0] acc;
wire [W-1:0] sum = acc + (c31 ? W'(NUM31) : W'(NUM24));
assign ce = (sum >= W'(DEN));
always @(posedge clk) begin
	if (reset) acc <= '0;
	else       acc <= ce ? sum - W'(DEN) : sum;
end

endmodule

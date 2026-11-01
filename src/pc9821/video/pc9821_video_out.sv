// The core's picture into the video clock domain, and the analog converters that run there.
//
// WHY A VIDEO CLOCK. sys_top's analog port (vga_out) runs on CLK_VIDEO and updates on CE_PIXEL
// (sys/sys_top.v: on clk_vid). With CLK_VIDEO = clk_sys and the dot a fractional enable (4.275 clocks
// at the shipped 90 MHz), every pixel would be 4 or 5 clk_sys wide and every sync edge would move by a clk_sys
// period from line to line: shimmer, and a monitor that drops sync. HDMI hides it (the scaler
// resamples). Here CLK_VIDEO is clk_vid, a PLL clock at an exact multiple of the dot rate, so
// a pixel is a constant whole number of clocks:
//   native  clk_vid = 2 x 400/19 MHz (42.105 MHz), a dot every 2nd clock  -> 24.83 kHz lines
//   doubled the same clock, a pixel every clock (pc9821_line_doubler)     -> 49.66 kHz lines
//   31 kHz  clk_vid = 2 x 25.168 MHz (50.336 MHz), a dot every 2nd clock, NATIVE whatever the OSD
//           asks: 0x09A8 bit 0 put the raster on the machine's 31 kHz dot clock (pc9821_vclk_pkg), and
//           its 31.46 kHz lines are already a VGA monitor's rate, so the doubler (which would make
//           62.9 kHz) stands aside. The OSD's "Doubled" means "for a VGA monitor", which the 31 kHz
//           picture is as it stands.
// The video PLL is GENERATED as the RECONFIGURABLE variant (pc9821_vpll_ctl: the 24 kHz and 31 kHz
// settings in pc9821_vclk_pkg), and moves between them when the guest flips 0x09A8 bit 0. There is
// no 15 kHz TV converter (no composite/S-Video output).
//
// THE BOUNDARY. The raster (pc9821_crtc and everything guest-visible) stays on clk_sys, gated by the
// exact dot enable (pc9821_dot_ce), as the model of the machine; only its OUTPUT crosses.
// Each dot is written into a 16-entry FIFO on its clk_sys enable and read out on a dot enable of the
// video clock (every 2nd clock). Both enables run at exactly the same rate (the dot's own: 400/19 MHz,
// or 25.168 MHz of the 31 kHz clock while 0x09A8 bit 0 is set) from the same 50 MHz reference
// (pc9821_dot_ce says why exactly), so the FIFO's fill only wobbles by the enables' +-1 clock phase and
// the synchroniser's latency, around the half-full point it is primed to: nothing is ever dropped or
// repeated, the output frame is the guest's frame, and no guest-visible status bit or latency changes.
// This is X68000_MiSTer's split as well (renderer on the system clock, scanline RAMs read out on a
// reconfigurable scan clock), with a FIFO in place of its scanline RAMs because the PC-98 raster
// already runs at the output's dot rate.
//
// THE CROSSING (docs/single-cycle-event-discipline.md): the FIFO's write pointer crosses as a
// registered Gray code through two flops; dbl_on/vclk_31/vid_rst are levels through two flops each
// (vclk_31's synchronised copy also leaves as vmode_31, the framework's new_vmode).
// Nothing else crosses. The SDC times the pointer to one video clock (tools/profile/z486_mister.sdc.in).
// A reset of the read side (the PLL relocking, a clock switch) flushes the FIFO and re-primes it.
`timescale 1ns / 1ps

module pc9821_video_out #(
	parameter bit     DBL_EN     = 1'b1
) (
	// ---- the core's picture, clk_sys ----
	input            clk_sys,
	input            ce,                            // the dot enable (pc9821_dot_ce)
	input      [7:0] r_in,
	input      [7:0] g_in,
	input      [7:0] b_in,
	input            hs_in,                         // syncs active LOW (pc9821_crtc)
	input            vs_in,
	input            de_in,
	input            dbl_on,                        // level (OSD), any domain
	// ---- the video clock ----
	input            clk_vid,
	input            vclk_31,                       // level: clk_vid is the 31 kHz clock (pc9821_vpll_ctl)
	input            vid_rst,                       // level: clk_vid is not usable (PLL not locked/switching)
	output           clk_video,                     // = clk_vid: what the top hands the framework
	output           ce_out,
	output     [7:0] r_out,
	output     [7:0] g_out,
	output     [7:0] b_out,
	output           hs_out,
	output           vs_out,
	output           de_out,
	output           dbl_active,
	output           vmode_31,                      // clk_vid level: vclk_31 after this side's synchroniser
	output reg       fifo_ev                        // clk_vid: a flush, re-centre or underflow (diagnostics)
);

localparam integer AW    = 4;                       // 16 entries
localparam integer PRIME = 8;                       // start (and restart) half full
localparam integer DW    = 27;                      // {vs, hs, de, r, g, b}

function automatic [AW:0] bin2gray(input [AW:0] b);
	return b ^ (b >> 1);
endfunction
function automatic [AW:0] gray2bin(input [AW:0] g);
	reg [AW:0] b;
	b[AW] = g[AW];
	for (int i = AW - 1; i >= 0; i--) b[i] = b[i + 1] ^ g[i];
	return b;
endfunction

// NO RESET ON THE WRITE SIDE, BY DESIGN: the pointers free-run from their power-up values and the
// read side re-establishes its position from whatever it sees (as pc9821_line_doubler).
/* verilator lint_off PROCASSINIT */   // power-up values, no reset: see the note above
// ================================ clk_sys: write ================================
reg  [AW:0]   wptr  = '0;
reg  [AW:0]   wgray = '0;                           // registered, so it crosses glitch-free
(* ramstyle = "M10K, no_rw_check" *) reg [DW-1:0] mem [0:(1 << AW) - 1];
always @(posedge clk_sys) begin
	if (ce) begin
		mem[wptr[AW-1:0]] <= {vs_in, hs_in, de_in, r_in, g_in, b_in};
		wptr  <= wptr + 1'd1;
		wgray <= bin2gray(wptr + 1'd1);
	end
end

// ================================ clk_vid: read ================================
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [AW:0] wg_s1 = '0;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [AW:0] wg_s2 = '0;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [2:0]  lv_s1 = 3'b010;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [2:0]  lv_s2 = 3'b010;
always @(posedge clk_vid) begin
	wg_s1 <= wgray;
	wg_s2 <= wg_s1;
	lv_s1 <= {vclk_31, dbl_on, vid_rst};
	lv_s2 <= lv_s1;
end
wire v_dbl_on = lv_s2[1];
wire v_rst    = lv_s2[0];
wire v_31     = lv_s2[2];
// THE FRAMEWORK'S MODE NOTICE. hps_io re-reports the video mode (and re-takes its frame-clock count)
// when the measured active area changes or its new_vmode input differs from the value it latched at
// the previous frame (sys/hps_io.sv:957 `old_vmode != new_vmode`), compared on clk_vid at VSYNC. The
// 24 kHz and 31 kHz rasters are both 640 x 400 active, so on the native path only this level tells
// it the frame rate moved (56.4 Hz to 70.1 Hz). It is v_31 itself: on clk_vid, the domain hps_io's
// video_calc compares in, and it moves together with v_rst (the FIFO flush for the relock), so the
// first whole frame hps_io measures after a change is on the new clock.
assign vmode_31 = v_31;

// The dot enable of the video clock: every 2nd clock of 2 x dot. Free-running; its phase against
// the write side is whatever the prime leaves.
reg  vph = 1'b0;
wire vce = ~vph;
always @(posedge clk_vid)
	vph <= ~vph;

wire [AW:0] wbin  = gray2bin(wg_s2);
reg  [AW:0] rptr  = '0;
reg         primed = 1'b0;
wire [AW:0] level = wbin - rptr;
wire        take  = primed & vce & (level != '0);
// Next state: a reset flushes (empty, unprimed); the prime starts at half full; an underrun
// unprimes; a fill past 3/4 (the reader fell behind: a clock switch it did not see) re-centres.
wire        flush   = v_rst;
wire        recentre = primed & (level > (AW+1)'(PRIME + PRIME / 2));
wire [AW:0] rptr_n  = flush    ? wbin :
                      recentre ? wbin - (AW+1)'(PRIME) :
                      take     ? rptr + 1'd1 : rptr;
wire        primed_n = flush ? 1'b0 :
                       (!primed) ? (level >= (AW+1)'(PRIME)) :
                       (vce & (level == '0)) ? 1'b0 : 1'b1;
reg  [DW-1:0] q = '0;
initial fifo_ev = 1'b0;
always @(posedge clk_vid) begin
	fifo_ev <= recentre | (primed & vce & (level == '0)) | (flush & primed);
	rptr   <= rptr_n;
	primed <= primed_n;
	q      <= mem[rptr_n[AW-1:0]];
end

// The dot stream on the video clock: a constant enable (every vce), black and sync-inactive while
// the FIFO is not primed.
reg        f_ce = 1'b0;
reg  [7:0] f_r = '0, f_g = '0, f_b = '0;
reg        f_hs = 1'b1, f_vs = 1'b1, f_de = 1'b0;
always @(posedge clk_vid) begin
	f_ce <= vce;
	if (vce) {f_vs, f_hs, f_de, f_r, f_g, f_b} <= take ? q : {1'b1, 1'b1, 1'b0, 24'd0};
end
/* verilator lint_on PROCASSINIT */

// ================================ the converters, on clk_vid ================================
wire       dbl_ce;
wire [7:0] dbl_r, dbl_g, dbl_b;
wire       dbl_hs, dbl_vs, dbl_de;
wire       dbl_vs_r;
generate if (DBL_EN) begin : g_line_doubler
	// The doubled stream is a pixel on every clock of 2 x dot: ce2 = 1. Never at the 31 kHz clock (a
	// 31 kHz raster is already VGA-rate; see the header).
	pc9821_line_doubler line_doubler (
		.clk(clk_vid), .en(v_dbl_on & ~v_31), .ce(f_ce), .ce2(1'b1),
		.r_in(f_r), .g_in(f_g), .b_in(f_b), .hs_in(f_hs), .vs_in(f_vs), .de_in(f_de),
		.r_out(dbl_r), .g_out(dbl_g), .b_out(dbl_b), .hs_out(dbl_hs), .vs_out(dbl_vs_r), .de_out(dbl_de),
		.ce_out(dbl_ce), .doubling(dbl_active)
	);
	// THE DOUBLED VSYNC IS THREE LINES. Replayed, the GDC's 8-line pulse becomes 16 doubled lines
	// (322 us) of serrated composite sync, and a Samsung SyncMaster 795DF (31-165 kHz) loses sync on
	// it with MiSTer.ini composite_sync=1, where a 3-line pulse holds (tested on that monitor).
	// The rule for the analog output keeps the active area and the refresh exact and leaves the
	// sync shape free for compatibility: so the doubled VSYNC starts where the GDC's does (on an
	// HSYNC leading edge, pc9821_crtc's VSYNC pin) and ends three measured doubled line periods later,
	// on the third HSYNC leading edge after it; the line count, the frame and the picture are untouched.
	// Always (a doubled picture is not a PC-98 signal anyway); native
	// 24 kHz carries the GDC's own pulse.
	/* verilator lint_off PROCASSINIT */   // power-up values, no reset (as the line doubler)
	reg        dv_hq = 1'b1, dv_vq = 1'b1, dv_cut = 1'b0;
	reg [11:0] dv_lc = 12'd1, dv_lp = 12'd848;   // clocks since the hsync leading edge; the line period
	reg [13:0] dv_vc = '0;                        // clocks since the pulse's leading edge
	/* verilator lint_on PROCASSINIT */
	wire       dv_hs_fall = dv_hq & ~dbl_hs;
	wire       dv_vs_fall = dv_vq & ~dbl_vs_r;
	wire       dv_end     = ~dbl_vs_r & ~dv_vs_fall & (dv_vc == {dv_lp, 1'b0} + {2'b00, dv_lp});  // 3 lines
	always @(posedge clk_vid) begin
		dv_hq <= dbl_hs;
		dv_vq <= dbl_vs_r;
		dv_lc <= dv_hs_fall ? 12'd1 : dv_lc + 1'd1;
		if (dv_hs_fall) dv_lp <= dv_lc;
		dv_vc <= dv_vs_fall ? 14'd1 : dv_vc + 1'd1;
		dv_cut <= dv_vs_fall ? 1'b0 : (dv_cut | dv_end);
	end
	assign dbl_vs = dbl_active ? (dbl_vs_r | ((dv_cut | dv_end) & ~dv_vs_fall)) : dbl_vs_r;
end else begin : g_no_line_doubler
	assign {dbl_ce, dbl_r, dbl_g, dbl_b, dbl_hs, dbl_vs, dbl_de} = {f_ce, f_r, f_g, f_b, f_hs, f_vs, f_de};
	assign dbl_active = 1'b0;
	assign dbl_vs_r   = 1'b1;
	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_dbl = v_dbl_on ^ v_31 ^ dbl_vs_r;
	/* verilator lint_on UNUSEDSIGNAL */
end endgenerate

assign {ce_out, r_out, g_out, b_out, hs_out, vs_out, de_out} = {dbl_ce, dbl_r, dbl_g, dbl_b, dbl_hs, dbl_vs, dbl_de};
assign clk_video = clk_vid;

endmodule

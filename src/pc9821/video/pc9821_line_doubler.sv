// A native line doubler for the analog VGA port: the GDC's ~24.8 kHz raster becomes ~49.7 kHz with
// every line sent twice, at the guest's own frame rate (the default SYNC block, 848 x 440 dots at
// 21.0526 MHz, becomes 848 x 880 at 42.1052 MHz: 49.66 kHz, 56.42 Hz, 640 x 800 visible).
//
// WHAT IT DOES. Each input line - the samples between two hsync leading edges, sync and blanking
// included - is recorded into one of two line slots, and during the NEXT input line the recorded
// samples are replayed twice at twice the dot rate. The replay reproduces every waveform of the
// line (R, G, B, HSYNC, DE), so the doubled raster's porches, sync widths and active window are the
// GDC's own, halved in time; nothing here assumes a line length or a porch, and a guest that
// programs another SYNC block gets its own geometry doubled. VSYNC is replayed from the first copy
// only and held at the line's final level through the second, so a vsync edge inside a line is not
// repeated (a repeat would be a second, spurious vsync pulse). The output lags the input by one
// line.
//
// WHY THE CORE DOES IT AND NOT THE FRAMEWORK. sys_top's analog port shows the core's own signal
// unless the scaler output is selected (MiSTer.ini vga_scaler=1 or the core's VGA_SCALER), and the
// framework's scandoubler (video_mixer) is for 15 kHz cores: it doubles a 15 kHz signal to 31 kHz.
// This core is a 24 kHz machine, so a monitor that cannot take 24.8 kHz needs this module.
//
// THE CLOCK. ce2 is a second enable at exactly twice the dot rate that fires on every ce cycle
// too. In the core the doubler runs on the video clock, 2 x 400/19 MHz, where ce is every second
// clock and ce2 is every clock (pc9821_video_out), so every doubled pixel is exactly one clock.
//
// LINES LONGER THAN A SLOT. A slot holds SLOT_SAMPLES samples (1024, against the default's 848 and
// defsyncm15's 896), and the longest line doubled is SLOT_SAMPLES - 1 = 1023 samples: writing the
// slot's last address marks the line as overflowed (`wovf`, from `w_at_end`), so a line of exactly
// 1024 samples already passes through native. A line that overflows its slot cannot be replayed in its own time, so the
// module passes the input through unchanged (native) until lines fit again; the switch, like a
// change of `en`, happens on a line boundary.
//
// SINGLE-CYCLE EVENTS (docs/single-cycle-event-discipline.md). `line_ref` (an hsync leading edge on
// a dot enable) is the only event; its one consumer is the always block below, where it is merged
// with the ordinary dot/replay step in one next-state expression per register (R2/R4).
`timescale 1ns / 1ps

module pc9821_line_doubler #(
	parameter integer SLOT_AW = 10                  // log2 of the samples a line slot holds
) (
	input            clk,
	input            en,                            // 1 = double (runtime, OSD/forced_scandoubler)
	input            ce,                            // the dot enable (21.0526 MHz)
	input            ce2,                           // twice the dot rate; every ce cycle is a ce2 cycle
	input      [7:0] r_in,
	input      [7:0] g_in,
	input      [7:0] b_in,
	input            hs_in,                         // the GDC's syncs: active LOW (pc9821_crtc hs_out)
	input            vs_in,
	input            de_in,
	output     [7:0] r_out,
	output     [7:0] g_out,
	output     [7:0] b_out,
	output           hs_out,
	output           vs_out,
	output           de_out,
	output           ce_out,
	output           doubling                       // the doubled stream is the one being output
);

localparam integer SLOT_SAMPLES = 1 << SLOT_AW;
localparam integer DW = 27;                         // {vs, hs, de, r, g, b}

// NO RESET, BY DESIGN: the state below carries power-up values (Quartus loads them with the
// bitstream) and every register is re-established within one line of any input, so a reset would
// only add a fan-out. The video path the module sits in (video_cleaner, gamma, video_freak) has
// none either.
/* verilator lint_off PROCASSINIT */   // power-up values, no reset: see the note above
// ---- the line reference: the hsync LEADING edge (hs_in is active low), sampled on a dot ----
reg hs_q = 1'b1;
wire line_ref = ce & hs_q & ~hs_in;

// ---- write side: record every dot of the current line into slot wslot ----
reg              wslot = 1'b0;
reg [SLOT_AW-1:0] wptr = '0;                       // next sample index of the current line
reg              wovf  = 1'b0;                     // the current line has filled its slot
wire             w_at_end = &wptr;
// The sample count of the line that ends at this line_ref (its samples are 0 .. count-1).
wire [SLOT_AW:0] line_count = wovf ? (SLOT_AW+1)'(SLOT_SAMPLES) : {1'b0, wptr};
wire             line_fits  = ~wovf;
wire             we         = ce;
wire [SLOT_AW:0] waddr      = line_ref ? {~wslot, {SLOT_AW{1'b0}}} : {wslot, wptr};

always @(posedge clk) begin
	if (ce) begin
		hs_q  <= hs_in;
		wslot <= line_ref ? ~wslot : wslot;
		wptr  <= line_ref ? SLOT_AW'(1) : (w_at_end ? wptr : wptr + 1'd1);
		wovf  <= line_ref ? 1'b0 : (wovf | w_at_end);
	end
end

// ---- the line store: two slots, one written while the other is replayed ----
reg [DW-1:0] mem [0:2*SLOT_SAMPLES-1];
reg [DW-1:0] q;
always @(posedge clk) if (we) mem[waddr] <= {vs_in, hs_in, de_in, r_in, g_in, b_in};

// ---- read side: replay the finished line twice at ce2 ----
// rslot/rptr/rcopy name the sample the NEXT ce2 outputs; the RAM is addressed with their next-state
// values so `q` always holds mem[{rslot, rptr}] (one-cycle registered read, M10K-inferable).
reg              rslot = 1'b0;
reg [SLOT_AW-1:0] rptr = '0;
reg              rcopy = 1'b1;
reg [SLOT_AW:0]  rlen  = '0;
reg              active = 1'b0;
/* verilator lint_on PROCASSINIT */
wire             r_last = (rlen == '0) | ({1'b0, rptr} == rlen - 1'd1);

wire              rslot_n  = line_ref ? wslot : rslot;
wire [SLOT_AW-1:0] rptr_n  = line_ref ? '0 :
                             !ce2     ? rptr :
                             r_last   ? (rcopy ? rptr : '0) : rptr + 1'd1;
wire              rcopy_n  = line_ref ? 1'b0 : (ce2 & r_last) ? 1'b1 : rcopy;
wire [SLOT_AW:0]  raddr    = {rslot_n, rptr_n};

always @(posedge clk) q <= mem[raddr];

/* verilator lint_off PROCASSINIT */   // power-up values, no reset (see the note above)
reg  [7:0] d_r = '0, d_g = '0, d_b = '0;
reg        d_hs = 1'b1, d_vs = 1'b1, d_de = 1'b0, vs_hold = 1'b1, d_ce = 1'b0;
/* verilator lint_on PROCASSINIT */
always @(posedge clk) begin
	rslot  <= rslot_n;
	rptr   <= rptr_n;
	rcopy  <= rcopy_n;
	rlen   <= line_ref ? line_count : rlen;
	active <= line_ref ? (en & line_fits) : active;
	d_ce   <= ce2;
	if (ce2) begin
		{d_hs, d_de, d_r, d_g, d_b} <= q[DW-2:0];
		d_vs    <= rcopy ? vs_hold : q[DW-1];
		vs_hold <= rcopy ? vs_hold : q[DW-1];
	end
end

// Native when not doubling: the input itself, on its own enable.
assign r_out    = active ? d_r  : r_in;
assign g_out    = active ? d_g  : g_in;
assign b_out    = active ? d_b  : b_in;
assign hs_out   = active ? d_hs : hs_in;
assign vs_out   = active ? d_vs : vs_in;
assign de_out   = active ? d_de : de_in;
assign ce_out   = active ? d_ce : ce;
assign doubling = active;

`ifndef SYNTHESIS
// The ce/ce2 contract this module is built on: every dot enable is also a ce2.
always @(posedge clk) if (ce & ~ce2) $fatal(1, "pc9821_line_doubler: ce without ce2");
`endif

endmodule

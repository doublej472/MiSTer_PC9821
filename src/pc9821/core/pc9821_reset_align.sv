// The machine reset request (the OSD's Reset, the keyboard reset combo, a disk-change reset), held
// until the raster reaches the last dot of its frame.
//
// WHY. A machine reset restarts the raster: pc9821_crtc's position counter and pc9821_dot_ce are
// re-seeded at the reset (pc9821_raster_reseed), as NP2kai restarts its frame events at a reset
// (pccore_reset's nevent_allreset). Landing anywhere in the frame, that restart cuts the frame the
// framework is measuring, and two framework blocks react to one cut frame:
//   * sys/hps_io.sv video_calc counts, per frame closed at the end of VSYNC, the first DE line's
//     width and the DE lines (`if(vid_hcnt != hcnt || vid_vcnt != vcnt || old_vmode != new_vmode)
//     resto <= 1;`) and 15 frames later reports a new resolution (`if(&resto) vid_nres <= vid_nres
//     + 1'd1;`); Main_MiSTer answers with video_mode_adjust, and with vsync_adjust=2 that
//     re-programs the HDMI PLL and timing (video_set_mode).
//   * with vsync_adjust=2 the scaler runs low-latency, and sys/pll_hdmi_adj.vhd steers the HDMI PLL
//     from the difference between the input and output frame times of EVERY frame (`udiff <=
//     integer(to_integer(osizep)) - integer(icpt);`); a frame of another length is a large step.
// A television shows either as a loss of sync - for a reset that left the picture's mode as it was.
//
// A restart on the frame's last dot is the frame's own end: the frame closed at the next VSYNC has
// its usual lines, its usual first line and its usual length (longer only by the reset's hold, a few
// clocks for the OSD's Reset). So the request waits for `wrap` (pc9821_crtc's o_frame_end, a level
// for the whole last dot) and the reset asserts on its first clock. The counter is not held by the
// reset: it runs through it on the power-on geometry and is re-seeded at 0,0, with the dot enable,
// on the reset's first clock (pc9821_raster_reseed's `ent`, the reset input high while its copy is
// still low) - inside that last dot at any clk_sys above three clocks a dot - and again at the release.
// A request still held when it is taken (the keyboard reset combo, Main_MiSTer's reset bit through a
// core load) keeps the reset until it is released AND the raster reaches a last dot again, so the
// release is on a frame end as well (pc9821_raster_reseed keeps the raster running meanwhile).
// The guest sees nothing of this: what it finds at the release is the same reset state, after a
// reset that began at most one frame later and, if it was held, ended at most one frame later
// (17.7 ms at 24 kHz, 14.3 ms at 31 kHz).
//
// If no frame end comes within TIMEOUT clocks (a stopped raster) the request is taken, or the held
// reset let go, anyway. A request that comes while the reset is asserted anyway (`active`: the
// power-up reset, which Main_MiSTer's reset bit at a core load extends) is taken at once.
//
// `waiting` covers the wait: the top ORs it into pc9821_cpu_reset_gate's hps_apply_reset, so a CPU
// the OSD's Reset pulse has stopped stays stopped until the machine reset arrives, instead of
// restarting at the reset vector among devices that have not been reset yet.
//
// Single-cycle event discipline: `req` is a level whose one-cycle form (the OSD Reset is a status
// bit Main_MiSTer sets and clears at once) is caught by `pend`, whose one consumer is this block;
// `wrap` is a level read only while a request is pending. The output is a level the top's reset
// synchroniser takes as it took reset_req.
`timescale 1ns / 1ps

module pc9821_reset_align #(
	parameter integer TIMEOUT = 4_000_000          // clk_sys clocks: > one 24 kHz frame at 90 MHz
) (
	input  wire clk,
	input  wire req,                               // reset_req, any width
	input  wire wrap,                              // the raster is on its frame's last dot
	input  wire active,                            // the reset is already asserted (the synchroniser)
	output wire go,                                // the reset as the synchroniser takes it
	output wire waiting                            // a request is waiting for the frame end
);

// Power-up values, no reset: the platform reset (reset_async) sets the synchroniser by itself and
// needs nothing from here, and a request is a guest-invisible event this block alone holds.
/* verilator lint_off PROCASSINIT */
reg        pend   = 1'b0;                          // a request not yet taken
reg        held   = 1'b0;                          // the reset is asserted, until req is gone and a last dot comes
reg        wrap_q = 1'b0;                          // wrap's previous clock: take on its first
reg [$clog2(TIMEOUT+1)-1:0] wait_n = '0;
/* verilator lint_on PROCASSINIT */

wire wrap_first = wrap && !wrap_q;
wire timed_out  = (wait_n == TIMEOUT[$clog2(TIMEOUT+1)-1:0]);
// a request that comes while the reset is asserted anyway (the power-up reset, a held reset) is
// taken at once: it restarts nothing, it only keeps the reset
wire take   = pend && (wrap_first || timed_out || active);
// A held request lets the reset go on the first clock of a last dot too (pc9821_raster_reseed: the
// raster runs through the reset, and its restart at the release then lands where the frame ends).
wire let_go = held && !req && (wrap_first || timed_out);
assign go = take || held;
assign waiting = pend;

always @(posedge clk) begin
	wrap_q <= wrap;
	// held: from the take until req is gone and a last dot has come
	held   <= take ? req : (held && !let_go);
	pend   <= !take && (pend || (req && !held));
	wait_n <= ((pend && !take) || (held && !req && !let_go)) ? wait_n + 1'd1 : '0;
end

endmodule

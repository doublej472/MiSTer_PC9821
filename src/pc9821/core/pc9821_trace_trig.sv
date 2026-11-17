// The instruction trace's second trigger (pc9821_trace's `trig`), built only with PERF_LOG_EN = 1:
// pc9821_system instantiates it inside its g_telemetry branch, and ties trace_trig to 0 without.
// This is the DECISION, separated from pc9821_system so it can be TESTED with a short window.
//
// THE FIRST ARM: the end of a GRCG drawing burst - the event a game's dialog redraws ARE, and the
// one the OOM trigger cannot see. WHY THE BURST'S END AND NOT ITS START: the trace ring holds the
// PAST (8192 transitions), so a trigger at the burst's START dumps the idle loop the guest was
// waiting in, while a trigger at its END dumps the drawing that just happened, which is the whole
// point of having it.
// WHY A ONE-SECOND QUIET: a game draws a dialog and then sits in a keyboard wait with the GVRAM
// idle - measured on the running core, a dialog screen is quiet and an advance bursts to
// 145k-254k stores - so "a GVRAM store after >= 1 s with none" is exactly "an interaction just
// redrew the screen". That is rare enough that the trace's ~16 s dump is not swamped, and it is
// what makes pc9821_trace's per-pulse re-arm safe: one interaction, one dump.
// WHICH STORES COUNT: the WRITE owners only - the GRCG's store pulse and the plain client's
// ownership level. The plain arm is there because the GRCG's alone does not see Farland
// Story's drawing: its heartbeats move GW/GC/PW while GS/GR/GT stay flat, so its page-to-page
// copies are plain window stores and a GRCG-only trigger never fires on them (its copy loop
// is at 1459:05C7). READS are deliberately excluded - a client that polls a GVRAM byte every frame
// would reset the quiet timer forever and the trigger would never fire. THE EGC IS ALSO
// EXCLUDED, not overlooked: an EGC-driven game (Flame Zapper) may never go quiet, so it needs
// its own trigger shape rather than being folded in here untested.
// THE QUIET WINDOW IS ONE SECOND OF REAL TIME ON HARDWARE (QUIET = SYS_FREQ clocks, passed by
// pc9821_system), which is what makes it free there - it is not a simulation budget.
//
// THE SECOND ARM IS THE FLIP. Waiting for the game to STOP drawing alone never fires on
// Farland: it makes ~1000 GVRAM accesses per frame at 56.4 fps, so `burst_quiet` never reaches
// its limit, even on a static map screen, the quietest state a running game has. A frame-buffer
// flip is the event that MARKS a redraw, and the ring holds the PAST, so triggering on the flip
// dumps the drawing that just happened. Both `0xA4` (the display page) and `0xA6` (the access
// page) count, because a game may double-buffer with either; each is a one-cycle pulse (the
// register differs from its own previous value).
//
// ITS OWN TIMER RATE-LIMITS IT: a flip may fire a dump only when QUIET has elapsed since the
// last flip that fired, or a 56 fps flipper would emit a 114 KB dump every frame. The timer is
// `flip_quiet`, restarted only by a flip that fires; it cannot be the store-quiet timer, which
// every store restarts and which therefore never expires on Farland. It starts at 0, so the first
// flip fires QUIET after reset. The quiet arm is KEPT as a fallback for a game that does go idle
// (between dialog advances, for example).
`default_nettype none

module pc9821_trace_trig #(
    // Overridable so a bench can shrink the window to a few cycles; the design passes SYS_FREQ.
    parameter [31:0] QUIET = 32'd50_000_000
) (
    input  wire clk,
    input  wire reset,
    input  wire grcg_store,      // the GRCG's GVRAM store pulse
    input  wire pw_owned,        // the plain GVRAM client owns the write port (a level)
    input  wire display_page,    // 0xA4, pc9821_crtc's display page
    input  wire access_page,     // 0xA6, the CPU's access page
    output wire trig             // one-cycle freeze request to pc9821_trace
);

reg [31:0] burst_quiet;
reg [31:0] flip_quiet;
reg        burst_active;
reg        disp_prev, acc_prev;
wire       burst_end = burst_active && (burst_quiet >= QUIET);
wire       store_evt = grcg_store || pw_owned;
wire       flip_evt  = (display_page != disp_prev) || (access_page != acc_prev);
wire       rate_ok   = (flip_quiet >= QUIET);
always @(posedge clk) begin
    if (reset) begin
        burst_quiet  <= 32'd0;
        flip_quiet   <= 32'd0;
        burst_active <= 1'b0;
        disp_prev    <= 1'b0;
        acc_prev     <= 1'b0;
    end else begin
        disp_prev <= display_page;
        acc_prev  <= access_page;
        if (store_evt) begin
            burst_quiet  <= 32'd0;
            burst_active <= 1'b1;
        end else if (burst_quiet != QUIET) begin
            burst_quiet <= burst_quiet + 32'd1;
        end
        // One pulse per burst: the next store re-arms it.
        if (burst_end) burst_active <= 1'b0;
        // A flip that passes the rate limit becomes an event and restarts the flip window.
        if (flip_evt && rate_ok) flip_quiet <= 32'd0;
        else if (flip_quiet != QUIET) flip_quiet <= flip_quiet + 32'd1;
    end
end
wire flip_trig = flip_evt && rate_ok;
assign trig = burst_end | flip_trig;

endmodule

`default_nettype wire

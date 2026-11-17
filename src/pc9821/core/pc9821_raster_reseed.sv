// The raster through a held reset and a pack load: it keeps running, and it is re-seeded where its
// frame ends anyway.
//
// WHAT THE GUEST SEES IS UNCHANGED. A machine reset and the firmware pack's arrival (cpu_run) both
// restart the raster - pc9821_crtc's position counter at 0 and pc9821_dot_ce's accumulator at 0 on
// the guest's first clock, as NP2kai restarts its frame events at a reset (pccore_reset's
// nevent_allreset) - and that is what this block still delivers, clock for clock as when both were
// held through the reset:
//   * `reseed_dot` (the accumulator) is one clock, the machine reset's LAST clock (the reset input
//     already low, the block's registered copy still high), so the first clock out of reset finds
//     the accumulator at 0 as the held reset left it;
//   * `reseed_cnt` (the counter) is that clock and the first clock out of reset - the second is the
//     one the old cpu_run re-seed added after every reset (its delayed copy was held low by the
//     reset) - and the clock cpu_run rises, so the counter is 0 on the guest's first two clocks
//     (and on the reset's FIRST clock, which the guest cannot see: see below).
//
// WHAT THE DISPLAY SEES CHANGES. Held through a reset, the raster stopped: the framework saw no sync
// for as long as the reset was held (3.1 s at every core load, where Main_MiSTer holds the OSD reset
// bit while it sends the boot files; as long as the keyboard reset combo is held) and then a frame
// of any length, which sys/hps_io.sv reports as a new resolution and sys/pll_hdmi_adj.vhd answers
// with an HDMI clock step (pc9821_reset_align's header has both). Here the counter and the dot
// enable run through the reset on the power-on block (the geometry registers are held at it by the
// reset), and the two restarts land on the frame's last dot:
//   * the machine reset's release: pc9821_reset_align holds a held request until the raster's last
//     dot before it lets the reset go, so the re-seed comes inside that dot;
//   * cpu_run: `cpu_run` here is the loader's `cpu_run_ld` held low until the first clock of the
//     raster's last dot (`frame_end`, pc9821_crtc's o_frame_end), so the re-seed it makes - and the
//     CPU's release - come inside that dot. That waits up to one frame (17.7 ms on the power-on
//     raster) after the pack has loaded; cpu_run's FALL is immediate for the guest (a new pack
//     download must stop it at once) and waits for the frame end only in the CRTC (below).
// A re-seed inside the last dot cuts at most that dot's remainder, never a whole line, so every frame
// keeps its lines and, to within a dot, its length.
//
// THE RESET'S FIRST CLOCK RE-SEEDS THE COUNTER TOO. The reset puts the geometry back to the power-on
// block (pc9821_crtc's geom_d is held at it while rst_n_sys is low) about three clocks after it is
// taken, still inside the guest frame's last dot, so the counter meets that dot's closing edge with
// the power-on limits. A guest raster larger than them (a 550-line or an 896-dot block) then has no
// frame end to wrap at: vline or hdot runs on to 1023 and wraps (about 38 ms with no VSYNC from a
// 550-line frame, and the reset's release, which waits for a frame end, waits that long too).
// `ent` - the reset input high, the block's copy still low - restarts the counter at 0,0 there, which
// is the natural wrap the guest frame was about to make, cut by the same dot's remainder as the
// release's re-seed. It restarts the dot enable's accumulator with it, as the release does: with
// the counter at 0 and the accumulator left running, that dot's closing edge would count dot 0 a
// second time, and the framework's detector (sys/hps_io.sv video_calc) would read a 641-dot line -
// a resolution change (tb_pc9821_raster_hold). A raster no larger than the power-on one is
// unaffected but for that remainder.
// Nothing the guest sees moves: the release re-seeds the counter again, and the guest is in reset
// in between (tb_pc9821_raster_reset_geom).
// cpu_run's FALL (a second pack download) WAITS FOR THE FRAME END in the CRTC (the owner's
// decision: no re-seed mid-frame). The guest stops at once - every other block still reads
// `cpu_run` - but the CRTC's own copy, `cpu_run_crtc`, stays high until the first clock of the
// raster's next last dot, so the frame in progress completes with the guest's geometry; it then falls
// and the power-on geometry the CRTC's reset loads is the next frame's. That fall re-seeds the
// counter and the dot enable exactly as the reset's first clock does (`crtc_fall`, below), for the
// same reason: the geometry drops inside the last dot, and a guest raster larger than the power-on
// one would otherwise have no frame end to wrap at. Dropping the geometry where cpu_run fell instead
// either cut the frame (the counter below the power-on limits wraps early) or ran the counter away
// to 1023 (above them) (tb_pc9821_raster_run_fall). `cpu_run_crtc` RISES with `cpu_run` on the same
// clock (it is `run_r || crtc_hold`), so where cpu_run never falls - every boot - the CRTC's reset
// and every re-seed are clock for clock what they were. While it is held the CPU is stopped and the
// CRTC only scans out; its CPU-side registers are reset with the geometry at the frame end.
//
// Single-cycle event discipline: `reseed_cnt` and `reseed_dot` each have one consumer, which takes
// it as a synchronous reset (the CRTC's position counter; the dot enable's accumulator). Their
// sources are ORed: a coincidence restarts the same counter once, which is all either asks.
`timescale 1ns / 1ps

module pc9821_raster_reseed (
	input  wire clk,
	input  wire reset,          // pc9821_system's reset input (the top's synchroniser output)
	input  wire rst_q,          // this block's copy of it (pc9821_reset_tree: one clock behind)
	input  wire cpu_run_ld,     // the loader's cpu_run (pc9821_memory_subsystem)
	input  wire frame_end,      // the raster is on its frame's last dot (pc9821_crtc o_frame_end)
	output wire cpu_run,        // cpu_run_ld, its rise held to the first clock of the last dot
	output wire cpu_run_crtc,   // cpu_run for the CRTC's reset: its fall held to the next last dot
	output wire reseed_cnt,     // the position counter's synchronous restart
	output wire reseed_dot      // the dot enable's
);

/* verilator lint_off PROCASSINIT */   // power-up values; the platform reset re-seeds them anyway
reg run_r   = 1'b0;
reg run_d   = 1'b0;                    // cpu_run one clock late: its rise is a re-seed
reg fe_q    = 1'b0;
reg rel_d   = 1'b0;                    // the first clock out of the machine reset
reg crtc_hold = 1'b0;                  // cpu_run has fallen; the CRTC keeps it until the frame end
reg crtc_run_d = 1'b0;                 // cpu_run_crtc one clock late: its fall is a re-seed
/* verilator lint_on PROCASSINIT */

wire fe_first = frame_end && !fe_q;
wire rel      = rst_q && !reset;       // the machine reset's last clock
wire ent      = reset && !rst_q;       // the machine reset's first clock

always @(posedge clk) begin
	fe_q  <= frame_end;
	run_r <= cpu_run_ld && (run_r || fe_first);
	run_d <= run_r;
	rel_d <= rel;
	crtc_hold  <= run_r || (crtc_hold && !fe_first);
	crtc_run_d <= cpu_run_crtc;
end

assign cpu_run_crtc = run_r || crtc_hold;
wire   crtc_fall    = crtc_run_d && !cpu_run_crtc;   // the CRTC's cpu_run falls: at a last dot

assign cpu_run    = run_r;
assign reseed_cnt = ent || crtc_fall || rel || rel_d || (run_r && !run_d);
assign reseed_dot = ent || crtc_fall || rel;

endmodule

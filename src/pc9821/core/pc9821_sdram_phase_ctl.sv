// THE RUN-TIME SDRAM_CLK PHASE SHIFT: a MEASUREMENT instrument for test builds, never shipped.
// build_profile.py's sdram_phase_dyn (--dbg-sdram-phase) is OFF in every preset; with it off
// pc9821_system builds no part of this file and the main PLL has no dynamic-phase-shift ports in
// use (z486_mister.sv SDRAM_PHASE_DYN). With it on, a DOS program (tools/hwprobe/sdshmoo) moves
// the SDRAM pin clock (the main PLL's output 1) against clk_sys in the PLL's own phase steps and
// measures the SDRAM read/write window on the card it runs on, from one bitstream.
//
// Two modules, one per clock domain:
//   pc9821_sdram_phase_ctl  clk_sys: the guest's two I/O ports, the requested and the applied
//                           offset, the auto-revert watchdog. It asks for ONE step at a time.
//   pc9821_sdram_dps        the PLL's scan clock (the 50 MHz reference): performs one step on
//                           the PLL's dynamic-phase-shift ports per request.
// They talk through a toggle handshake (req toggles with step_up held, ack toggles back), each
// toggle crossing through two flops (docs/single-cycle-event-discipline.md, the audit checklist's sixth question).
//
// THE PLL'S DPS PROTOCOL (Intel Cyclone V Device Handbook, "Dynamic Phase Shift"; the vendor's
// own sequencer is sys/pll_cfg/altera_pll_reconfig_core.v `dyn_phase_shift`): set CNTSEL and UPDN,
// assert PHASEEN for at least two SCANCLK cycles, deassert it after PHASEDONE goes low, and the
// shift is complete when PHASEDONE returns high. One PHASEEN pulse moves the selected counter by
// one VCO/8 step (154.3 ps at the 810 MHz VCO of the 90 MHz build). CNTSEL is the LOGICAL output
// index: in DPS mode altera_pll passes it through dont_touch LUTs whose masks the fitter rewrites to
// the physical counter it placed (Quartus 17.0 libraries/megafunctions/altera_pll.v, `cntsel_int`:
// "For DPS-only mode, we want lcells in the IP for counter rotation"), so output 1 is cntsel 1.
//
// THE GUEST INTERFACE (device bus, pc9821_device_select's sdph_cs; the build's only users of 0x5FF0
// and 0x5FF2 - neither NP2kai's nor MAME's PC-9821 port map names them, and this core decodes
// nothing there otherwise, tb_pc9821_device_select):
//   0x5FF0 write  command: 00 keepalive, 01 one step later (+1), 02 one step earlier (-1),
//                 03 back to nominal (0), 04 clear the sticky `reverted` flag; others keepalive.
//   0x5FF2 write  the requested offset, signed steps (-128..+127); the controller walks there.
//   0x5FF0 read   status: [7:4] = 0xA (present: an unbuilt port reads 0xFF), [3] fault (a step
//                 timed out on the PLL; stepping has stopped and the offset may be off by one;
//                 sticky until a core reset),
//                 [2] reverted (the watchdog returned to nominal), [1] busy (a step is in flight
//                 or the applied offset is not yet the requested one), [0] armed (offset or
//                 request non-zero: the watchdog is counting).
//   0x5FF2 read   the APPLIED offset, signed steps.
// Every write to either port refreshes the watchdog. The offset is relative to the build's
// generated phase (the PLL's power-up state), which is offset 0 by construction.
//
// THE AUTO-REVERT. While the watchdog is armed and neither port is written for WDOG_MS
// milliseconds the request returns to 0 and `reverted` is set, so a guest that hangs at a bad
// phase lets the core walk itself back to the generated phase. The time comes from
// CLOCK_RATE_HZ, so it is the same at every clk_sys (AGENTS.md: rates come from the device).
// A core reset also requests offset 0 and clears `fault` (so stepping resumes); the applied offset
// and the handshake are never reset (the PLL keeps its phase across a core reset, so forgetting
// the count would lose track of it).
`default_nettype none

// The step count and the handshake take their POWER-UP value from their declaration (the FPGA's
// configuration state; each has a non-constant data input, so Quartus keeps it) and have no reset:
// the PLL keeps its phase across a core reset, so they must too. That is the
// declaration-initialised register PROCASSINIT reports. Every one is an internal declaration, never
// an initialised output port (Quartus 17.0 ignores an ANSI output-port initializer), and no flag is
// set-only (with no kept power-up level, ALLOW_POWER_UP_DONT_CARE lets Quartus replace a register
// whose data input is a constant by that constant): pc9821_sdram_dps.sv says how that pair stopped
// this instrument.
/* verilator lint_off PROCASSINIT */
module pc9821_sdram_phase_ctl #(
    parameter integer CLOCK_RATE_HZ = 50_000_000,
    parameter integer WDOG_MS = 100
) (
    input  wire        clk,
    input  wire        reset,       // synchronous: requests offset 0
    // The device bus (pc9821_system): cs is sdph_cs, wr/rd pc9821_iobus's one-cycle strobes.
    input  wire        cs,
    input  wire [15:0] addr,
    input  wire        wr,
    input  wire  [7:0] din,
    output wire  [7:0] dout,
    // To/from pc9821_sdram_dps (asynchronous: the scan-clock domain).
    output wire        step_req,          // toggles once per requested step
    output wire        step_up,           // the step's direction, held while it is in flight
    input  wire        step_ack_async,    // toggles once per completed (or timed-out) step
    input  wire        fault_async        // the last step timed out; settled before its ack toggles
);
  localparam integer TICK_DIV = (CLOCK_RATE_HZ + 999) / 1000;   // clk_sys cycles per ms
  localparam integer TICK_W = $clog2(TICK_DIV + 1);
  localparam integer MS_W = $clog2(WDOG_MS + 1);

  wire cmd_wr = cs && wr && (addr == 16'h5FF0);
  wire tgt_wr = cs && wr && (addr == 16'h5FF2);
  wire any_wr = cmd_wr || tgt_wr;

  // ---- the crossings back from the scan-clock domain -------------------------------------
  reg [1:0] ack_sync = 2'b00;
  reg [1:0] fault_sync = 2'b00;
  reg       ack_seen = 1'b0;
  always @(posedge clk) begin
    ack_sync <= {ack_sync[0], step_ack_async};
    fault_sync <= {fault_sync[0], fault_async};
  end
  wire ack_edge = ack_sync[1] != ack_seen;
  // pc9821_sdram_dps settles fault_async (the outcome of the step being acknowledged) FLT_LEAD scan
  // clocks before it toggles step_ack, so at ack_edge fault_sync[1] is that step's outcome.
  wire step_failed = ack_edge && fault_sync[1];
  // `fault_st`: set by a timed-out step's acknowledge, cleared by the core reset. They can coincide;
  // set-wins is the stated rule (R3), so a reset in the ack's cycle still reports the timeout.
  reg  fault_st = 1'b0;
  always @(posedge clk)
    fault_st <= (fault_st && !reset) || step_failed;
  wire fault = fault_st;

  // ---- the applied offset and the one-step-at-a-time requester ----------------------------
  reg step_req_q = 1'b0, step_up_q = 1'b0;
  assign step_req = step_req_q;
  assign step_up = step_up_q;
  reg signed [7:0] offset = 8'sd0;     // what the PLL has been moved by
  reg signed [7:0] target = 8'sd0;     // what the guest (or the watchdog / reset) asks for
  reg              pending = 1'b0;     // a request is in flight (req toggled, ack not yet seen)
  wire             want_step = !pending && !fault && (offset != target);
  // pending is set by the issue and cleared by the ack; the two cannot coincide (an issue needs
  // !pending, an ack exists only while pending), and `pending_ack_issue` below asserts it.
  always @(posedge clk) begin
    if (ack_edge) begin
      ack_seen <= ack_sync[1];
      pending <= 1'b0;
      offset <= step_up_q ? offset + 8'sd1 : offset - 8'sd1;
    end else if (want_step) begin
      step_up_q <= target > offset;
      step_req_q <= ~step_req_q;
      pending <= 1'b1;
    end
  end

  // ---- the watchdog ----------------------------------------------------------------------
  wire armed = (offset != 8'sd0) || (target != 8'sd0);
  reg [TICK_W-1:0] tick = '0;
  reg [MS_W-1:0]   ms = '0;
  wire tick_wrap = (tick == TICK_W'(TICK_DIV - 1));
  // The expiry and a write in the same cycle: the write refreshes, so the watchdog does not fire
  // (a guest that is still writing is alive). wdog_fire is therefore qualified by !any_wr.
  wire wdog_fire = armed && !any_wr && tick_wrap && (ms == MS_W'(WDOG_MS - 1));
  always @(posedge clk) begin
    if (any_wr || !armed || wdog_fire) begin
      tick <= '0;
      ms <= '0;
    end else if (tick_wrap) begin
      tick <= '0;
      ms <= ms + 1'b1;
    end else begin
      tick <= tick + 1'b1;
    end
  end

  // ---- the request: one next-state expression for every writer (R2/R4) ---------------------
  // Priority, stated: a core reset returns to nominal; then a guest write; then the watchdog
  // (which cannot fire in a write's cycle, above). +1/-1 saturate at the signed range.
  reg signed [7:0] target_n;
  always @(*) begin
    target_n = target;
    if (reset)
      target_n = 8'sd0;
    else if (cmd_wr && din == 8'h01)
      target_n = (target == 8'sd127) ? target : target + 8'sd1;
    else if (cmd_wr && din == 8'h02)
      target_n = (target == 8'sh80) ? target : target - 8'sd1;   // 8'sh80 = -128
    else if (cmd_wr && din == 8'h03)
      target_n = 8'sd0;
    else if (tgt_wr)
      target_n = din;
    else if (wdog_fire)
      target_n = 8'sd0;
  end
  // `reverted`: set by the watchdog, cleared by command 04. They cannot coincide (the fire needs
  // a cycle without a write), and set-wins is the stated rule anyway (R3).
  reg reverted = 1'b0;
  wire clear_rev = cmd_wr && (din == 8'h04);
  always @(posedge clk) begin
    target <= target_n;
    reverted <= (reverted && !clear_rev) || wdog_fire;
  end

  wire busy = pending || (offset != target);
  assign dout = (addr == 16'h5FF2) ? offset : {4'hA, fault, reverted, busy, armed};

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (ack_edge && !pending)
      $fatal(1, "pc9821_sdram_phase_ctl: a step acknowledged with none in flight");
    if (ack_edge && want_step)
      $fatal(1, "pc9821_sdram_phase_ctl: pending_ack_issue - an issue and an ack in one cycle");
    if (wdog_fire && any_wr)
      $fatal(1, "pc9821_sdram_phase_ctl: the watchdog fired in a write's cycle");
  end
`endif
endmodule
/* verilator lint_on PROCASSINIT */

`default_nettype wire

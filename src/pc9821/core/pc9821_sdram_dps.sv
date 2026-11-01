// The scan-clock half of the run-time SDRAM_CLK phase instrument; pc9821_sdram_phase_ctl.sv
// describes the instrument, the PLL's DPS protocol and the CNTSEL mapping.
`default_nettype none

// One PLL phase step per request, on the PLL's scan clock. The handbook's sequence: PHASEEN high
// for at least MIN_EN cycles AND until PHASEDONE has gone low, then low until PHASEDONE is high
// again. A step that does not see PHASEDONE fall or rise within TIMEOUT cycles is acknowledged
// anyway, so the controller never waits forever, with `fault` set: `fault` is the OUTCOME OF THE
// LAST STEP (1 = it timed out), cleared when a request is accepted and set at the timeout, and it
// settles FLT_LEAD scan clocks before the step_ack toggle that reports it. The stickiness lives in
// the controller (pc9821_sdram_phase_ctl's fault_st), on clk_sys, where the core reset clears it.
// WHY `fault` IS NOT A STICKY SET-ONLY FLAG, AND WHY NO OUTPUT PORT CARRIES AN INITIALIZER. The
// first version declared `output reg fault = 1'b0` and only ever assigned 1'b1. Quartus 17.0
// ignores an initializer written in an ANSI output-port declaration (a .build experiment, recorded
// in docs/sdram-margin.md section 2: `output reg p = 1'b1` synthesizes with power_up low and no
// NOT-gate push-back, an internal `reg r = 1'b1` gets the push-back and powers up 1), so the
// register had no power-up level, and with the qsf's ALLOW_POWER_UP_DONT_CARE its constant data
// input let Quartus replace it by VCC: "Stuck at VCC due to stuck port data_in" in every fitted
// --dbg-sdram-phase build, so the controller read a fault at power-up and never issued a step
// (hardware shmoo, 2026-10-29). So every register here is an internal declaration (its
// initializer is the power-up level Quartus keeps) driving its port, and `fault` is also cleared
// at each accepted request, so its power-up value does not matter at all: the controller only
// samples it at an acknowledge, and every acknowledge follows an accept.
// The registers take their POWER-UP value from their declaration (the FPGA's configuration state)
// and have no reset: the PLL keeps its phase across a core reset, so the handshake must too. That
// is the declaration-initialised register PROCASSINIT reports.
/* verilator lint_off PROCASSINIT */
module pc9821_sdram_dps #(
    parameter [4:0]   CNTSEL = 5'd1,      // the SDRAM pin clock: PLL output 1 (logical index)
    parameter integer MIN_EN = 2,
    parameter integer TIMEOUT = 1023,
    // Scan clocks `fault` is held settled before the step_ack toggle that reports it. The two
    // values cross through separate two-flop synchronisers that may each resolve one destination
    // clock late, so `fault` must lead by more than one destination (clk_sys) period: 2 scan
    // clocks are 40 ns, more than one clk_sys period at every clk_sys above 25 MHz.
    parameter integer FLT_LEAD = 2
) (
    input  wire       clk,                // the PLL's scanclk
    input  wire       step_req_async,
    input  wire       step_up_async,      // stable for the whole request (held by the controller)
    input  wire       phase_done_async,
    output wire       phase_en,
    output wire       updn,
    output wire [4:0] cntsel,
    output wire       step_ack,
    output wire       fault
);
  assign cntsel = CNTSEL;
  reg phase_en_q = 1'b0, updn_q = 1'b0, step_ack_q = 1'b0, fault_q = 1'b0;
  assign phase_en = phase_en_q;
  assign updn = updn_q;
  assign step_ack = step_ack_q;
  assign fault = fault_q;
  localparam integer TW = $clog2(TIMEOUT + 1);
  reg [1:0] req_sync = 2'b00;
  reg [1:0] done_sync = 2'b11;
  reg       req_seen = 1'b0;
  always @(posedge clk) begin
    req_sync <= {req_sync[0], step_req_async};
    done_sync <= {done_sync[0], phase_done_async};
  end
  wire done = done_sync[1];

  localparam [1:0] S_IDLE = 2'd0, S_EN = 2'd1, S_WAIT = 2'd2, S_FLT = 2'd3;
  reg [1:0]    state = S_IDLE;
  reg [TW-1:0] cnt = '0;
  always @(posedge clk) begin
    case (state)
      S_IDLE: if (req_sync[1] != req_seen) begin
        req_seen <= req_sync[1];
        // step_up has been stable since the controller toggled the request, at least the two
        // synchroniser cycles ago that req_sync[1] took to change.
        updn_q <= step_up_async;
        phase_en_q <= 1'b1;
        fault_q <= 1'b0;                     // this step's outcome is not known yet
        cnt <= '0;
        state <= S_EN;
      end
      S_EN: begin
        cnt <= cnt + 1'b1;
        if (cnt >= TW'(MIN_EN - 1) && !done) begin
          phase_en_q <= 1'b0;
          cnt <= '0;
          state <= S_WAIT;
        end else if (cnt == TW'(TIMEOUT)) begin
          phase_en_q <= 1'b0;
          fault_q <= 1'b1;
          cnt <= '0;
          state <= S_FLT;
        end
      end
      S_WAIT: begin
        cnt <= cnt + 1'b1;
        if (done) begin
          step_ack_q <= ~step_ack_q;
          state <= S_IDLE;
        end else if (cnt == TW'(TIMEOUT)) begin
          fault_q <= 1'b1;
          cnt <= '0;
          state <= S_FLT;
        end
      end
      // A timed-out step: `fault` was set on entry; acknowledge FLT_LEAD scan clocks later.
      S_FLT: begin
        cnt <= cnt + 1'b1;
        if (cnt == TW'(FLT_LEAD - 1)) begin
          step_ack_q <= ~step_ack_q;
          state <= S_IDLE;
        end
      end
      default: state <= S_IDLE;
    endcase
  end
endmodule
/* verilator lint_on PROCASSINIT */

`default_nettype wire

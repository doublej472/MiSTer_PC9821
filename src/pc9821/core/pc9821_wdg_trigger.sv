// WHEN the stall watchdog speaks, and WHICH of its three states it is reporting.

// This is the DECISION, separated from the message so it can be TESTED. The stall arm must NOT
// require `!z_valid`: a wedged CPU HOLDS z_valid high, so that would suppress the one condition
// the arm exists to report.

// z_valid is a LEVEL (src/z486/memory.sv:173 `output valid`) held until z_ready answers, so the arithmetic is
// about COMPLETION: a request that is never answered must age out.

// THREE STATES, and the third is the failure; z_valid sampled when the counter expires is what
// separates them:
//   W  a request is OUTSTANDING and has not completed for the window. THE WEDGE - the machine
//      has stopped. z_valid high, z_ready low.
//   S  NO request for the window. Halted, or a long I/O wait; usually healthy.
//   P  the heartbeat, every period regardless. ON ITS OWN IT SAYS NOTHING about progress.
`default_nettype none

module pc9821_wdg_trigger #(
    // Both are overridable so a bench can shrink the windows to a few cycles. The design
    // passes the real ones (200 ms and 2 s at SYS_FREQ); a bench that had to simulate 200 ms
    // of 50 MHz would take 10 million cycles to reach one trigger, which is not a bench.
    parameter [31:0] WDG_STALL  = 32'd10_000_000,
    parameter [31:0] WDG_PERIOD = 32'd100_000_000
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       cpu_run,    // the guest is running; no guest, no watchdog
    input  wire       hold,       // a message is in flight: the counters freeze
    input  wire       z_valid,    // a CPU memory request is present (a LEVEL)
    input  wire       z_ready,    // that request was accepted
    output reg  [7:0] path,       // 'W' / 'S' / 'P', latched when the trigger fires
    output wire       start       // begin a message; asserted for the trigger cycle
);

localparam [7:0] WDG_PATH_WEDGE  = 8'h57;   // 'W'
localparam [7:0] WDG_PATH_IDLE   = 8'h53;   // 'S'
localparam [7:0] WDG_PATH_PERIOD = 8'h50;   // 'P'

// THE TWO COUNTERS ARE SIZED TO THE WINDOWS THEY COUNT, and the windows are the parameters above
// (200 ms and 2 s at SYS_FREQ): each saturates at its own window, so $clog2(window+1) bits carry
// its whole range - 24 and 27 at 50 MHz, 5 and 4 in the bench's shortened windows. The one-bit
// floor is for a window a parameter could set to zero.
localparam integer STALL_BITS  = ($clog2(WDG_STALL + 1) < 1) ? 1 : $clog2(WDG_STALL + 1);
localparam integer PERIOD_BITS = ($clog2(WDG_PERIOD + 1) < 1) ? 1 : $clog2(WDG_PERIOD + 1);
reg [STALL_BITS-1:0]  since_completion;   // cycles since a request was ACCEPTED
reg [PERIOD_BITS-1:0] since_period;       // cycles since the last heartbeat

wire stalled = (since_completion == WDG_STALL);
wire wedged  = stalled && z_valid && !z_ready;
wire idle    = stalled && !z_valid;
wire period  = (since_period == WDG_PERIOD);

// A stall outranks the heartbeat. The heartbeat fires on a HEALTHY machine too, so letting it
// win when both hold would mask the fault behind a normal reading.
assign start = cpu_run && !hold && (wedged || idle || period);

always @(posedge clk) begin
    if (reset) begin
        since_completion <= {STALL_BITS{1'b0}};
        since_period     <= {PERIOD_BITS{1'b0}};
        path             <= WDG_PATH_PERIOD;
    end else if (cpu_run && !hold) begin
        // COMPLETION, not arrival. Resetting on arrival let a CPU waiting forever on a
        // transaction that never completes hold z_valid high and reset this every cycle, so
        // the counter could never reach the window and the stall arm could never fire.
        //
        // The expiry resets it too, so a message does not leave the counter sitting at the
        // window: without that, the next time `hold` drops the same expired value is still
        // there and the trigger fires again immediately, instead of waiting a fresh window.
        if ((z_valid && z_ready) || stalled) since_completion <= {STALL_BITS{1'b0}};
        else since_completion <= since_completion + 1'b1;

        // The heartbeat's own clock, independent of the stall: it counts up whether or not a
        // stall is in progress, so a stall does not postpone the next heartbeat by a window.
        if (period) since_period <= {PERIOD_BITS{1'b0}};
        else since_period <= since_period + 1'b1;

        if (wedged)      path <= WDG_PATH_WEDGE;
        else if (idle)   path <= WDG_PATH_IDLE;
        else if (period) path <= WDG_PATH_PERIOD;
    end
end

endmodule

`default_nettype wire

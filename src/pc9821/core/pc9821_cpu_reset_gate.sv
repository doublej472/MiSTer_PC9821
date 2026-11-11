// WHEN the CPU may leave reset, separated from pc9821_system so that it can be TESTED.
//
// z486 consumes reset_n as an ASYNCHRONOUS reset (always_ff @(posedge clk or negedge reset_n)
// in decoder, paging_unit, paging_tlb, paging_walker, prefetch and z486.sv itself), so
// asynchronous ASSERTION is safe and DEASSERTION is the hazardous half.
//
// TWO REASONS THE RELEASE IS DELAYED. HOLD is the platform's CPU-reset hold, re-armed by the
// warm CPU-reset class (out 0xF0, 0x534, a z486 shutdown). SDRAM is that the controller is still
// running its JEDEC initialisation, and THE ROM IS NOT READABLE UNTIL THAT FINISHES.
`default_nettype none

module pc9821_cpu_reset_gate #(
    parameter [3:0] HOLD_CYCLES = 4'hF   // overridable so a bench can shrink the hold
) (
    input  wire clk,
    input  wire reset,            // the platform reset; also restarts the SDRAM controller (see below)
    input  wire cpu_run,          // the pack is present (pc9821_memory_subsystem)
    input  wire hps_apply_reset,  // the OSD's own Reset action
    input  wire cpu_reset_req,    // the warm CPU-reset class
    input  wire mem_busy,         // the SDRAM controller's own busy
    output wire cpu_reset_n
);

// The SDRAM term, and the defect it closes. A platform reset re-runs the controller's JEDEC
// initialisation (src/memory/sdram.v:1903-1905 `state_n = INIT;` with busy_buf_n high) and it then spends
// ~200 us calibrating before it answers anything. A core reload hides that because the pack
// download holds cpu_run low for seconds; an OSD reset does not, because pc9821_rom_loader keeps
// rom_ready deliberately so the pack is not re-downloaded - so the CPU was released 15 cycles
// after reset and fetched the reset vector out of an uninitialised SDRAM. That is the
// intermittent "ROM SUM ERROR", and why only a full reload was reliable.
// mem_busy is that controller's own busy. src/memory/sdram.v:287-291 states its reset contract
// (the power-up value "must be BUSY until the init sequence finishes") and nce is tied low, so it
// IS busy_buf: high from reset, and low for the first time only once init completes. Nothing else
// can be that edge, which is what makes the first low safe to use as the ready signal.
// The one platform reset that does NOT restart the controller is a boot-ROM pack download under
// the OSD Reset level (pc9821_memory_subsystem's pack_load_hold keeps the controller out of it so
// the pack can land); the controller then finished its initialisation during the download, its
// busy is low once it is idle, and the term passes at its first idle cycle after the reset.
reg sdram_ready;
always @(posedge clk) begin
    if (reset) sdram_ready <= 1'b0;
    else if (!mem_busy) sdram_ready <= 1'b1;
end

// The hold the design always had, extended by the SDRAM term above and never shortened by it.
reg [3:0] hold;
always @(posedge clk) begin
    if (reset || hps_apply_reset || !cpu_run || !sdram_ready) hold <= HOLD_CYCLES;
    else if (cpu_reset_req) hold <= HOLD_CYCLES;
    else if (hold != 4'd0) hold <= hold - 4'd1;
end

// Assert asynchronously, deassert synchronously. A combinational release would rise in the very
// cycle the hold reaches zero - inside z486's recovery window - so different flops could leave
// reset on different cycles and the CPU would be internally inconsistent for a cycle or more (a
// machine that boots only sometimes). This release comes off a clk flop,
// two cycles later, with full setup margin.
wire release_ok = !reset && cpu_run && !hps_apply_reset && (hold == 4'd0) && sdram_ready;
/* verilator lint_off SYNCASYNCNET */   // intentional: this IS the reset synchroniser
reg [1:0] release_sync;
always @(posedge clk or negedge release_ok) begin
    if (!release_ok) release_sync <= 2'b00;
    else          release_sync <= {release_sync[0], 1'b1};
end
assign cpu_reset_n = release_sync[1];
/* verilator lint_on SYNCASYNCNET */

endmodule

`default_nettype wire

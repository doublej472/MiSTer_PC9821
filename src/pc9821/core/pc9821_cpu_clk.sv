// The CPU-throttle platform side: the gated CPU clock (this file) and the bus bridge (pc9821_cpu_bus_bridge.sv) between the gated
// z486 and the clk_sys platform.
//
// z486 has no speed input (src/z486/docs/throttle.md, the 0ebf0d0 re-vendor): a slower CPU is the
// same CPU seeing fewer clock edges. cpu_throttle (src/z486/cpu_throttle.sv) produces
// `cpu_ce`, REGISTERED on clk_sys: cpu_ce high in a clk_sys cycle means the CPU gets the edge
// that ENDS that cycle. The platform therefore owes the CPU (src/z486/docs/throttle.md, "What the
// platform must do"):
//   - a glitch-free gated clock (this module);
//   - a transfer that happens exactly in the cpu_ce cycles in which valid && ready held, so a
//     responder's one-cycle ready in a non-enabled cycle is HELD until the next enabled edge
//     and the responder does not see `valid` again meanwhile (the accept latch below);
//   - every pulse input held until the next enabled edge: resp_valid with its data (a FIFO,
//     because the SDRAM burst cannot be back-pressured), cache_flush, and the DMA-side
//     snoop_valid with its address (one-deep, back-pressured: the platform will not present
//     a second DMA write while one waits - pc9821_system's dma_snoop_busy gate);
//     the two pulse inputs this platform ties off are nmi (0 - a bare one-cycle pulse WOULD
//     need a hold before it is connected, the CPU edge-detects it) and line_resp_valid (0 -
//     beats are the response form here, and the 128-bit line_din would need its own
//     registered hold, not the beat FIFO);
//   - every one-CPU-cycle output pulse sampled under cpu_ce.
// With cpu_ce constant 1 (setting 0, "Full") no latch is ever set and the FIFO is never
// written, so every output equals its input: the bridge is a wire and the full-speed core is
// cycle-identical to the ungated one (the boot golden pins that).

// The gated CPU clock. On the FPGA it is a Cyclone V clock-control block (the ALTCLKCTRL
// atom, cyclonev_clkena) whose `ena` is registered on the FALLING edge of its input clock, so
// an enable that changes just after a rising edge cannot glitch the output. It costs no LABs
// and one global clock network.
//
// THE ENABLE IS STAGED ON THE FALLING EDGE, ONE CYCLE AHEAD. The block's own falling-edge
// register samples `ena` HALF a clk_sys period after the rising edge that launches it. Fed
// straight from cpu_throttle's rising-edge register, that is a 5.6 ns (90 MHz) route from a
// fabric register to the clock-control block at the die's global-clock site, and the fitter
// does not hold it to that: when the route is longer, the block samples the enable one cycle
// late and the CPU's edges no longer fall in the cycles the bridge holds its handshakes for
// (it pops a response beat or releases an accept at an edge the CPU did not get), so the CPU
// stalls on the first such cycle. That needs cpu_ce to toggle, so Full (constant 1) never
// shows it; at 33/25/16 MHz some placements of a source never boot.
// So the throttle's enable (`ce_next`) is captured by a FABRIC falling-edge register
// (`ce_fall`: a rising-to-falling half-cycle path between two ordinary registers, placeable
// side by side), and the block samples ce_fall one FULL period after that register launches
// it (falling to falling). The CPU therefore gets the edge ending the cycle AFTER the one in
// which ce_next was high, and the platform's cpu_ce (`ce`, ce_next registered once on the
// rising edge) is high in exactly that cycle, so "cpu_ce high in a clk_sys cycle means the
// CPU gets the edge that ends it" still holds. The rate and its Bresenham spread are
// cpu_throttle's, shifted by one clk_sys cycle. At Full ce_next, ce_fall and ce are all
// constant 1: no cycle of the full-speed core changes.
// The simulation build models the block exactly (a falling-edge enable register ANDed with the clock),
// not with the fork's low-phase latch (cpu_clk_gate), which would pass ce_fall half a cycle
// early. SIM_ENA_ROUTE_PS (simulation only, default 0) delays the enable's route into the
// block, so tb_pc9821_cpu_clk can show which route delays each structure tolerates.
module pc9821_cpu_clk #(
    parameter int SIM_ENA_ROUTE_PS = 0
) (
    input  wire clk,       // clk_sys
    input  wire ce_next,   // cpu_throttle's cpu_ce: the CPU edge it selects ends the NEXT cycle
    output wire ce,        // the platform's cpu_ce: the CPU gets the edge ending this cycle
    output wire gclk       // the CPU's clock
);
// Power-up 1, like cpu_throttle's reset value (it forces 1 while the CPU is in reset).
/* verilator lint_off PROCASSINIT */   // no reset here: the stage follows the throttle, 1 at power-up
reg ce_q    = 1'b1;
reg ce_fall = 1'b1;
always @(posedge clk) ce_q    <= ce_next;
always @(negedge clk) ce_fall <= ce_next;
assign ce = ce_q;
`ifdef VERILATOR
    wire ena_routed;
    if (SIM_ENA_ROUTE_PS == 0) begin : g_route0
        assign ena_routed = ce_fall;
    end else begin : g_route
        assign #(SIM_ENA_ROUTE_PS * 1ps) ena_routed = ce_fall;
    end
    reg ena_reg = 1'b1;
    always @(negedge clk) ena_reg <= ena_routed;
    /* verilator lint_on PROCASSINIT */
    assign gclk = clk & ena_reg;
`else
    /* verilator lint_on PROCASSINIT */
    cyclonev_clkena #(
        .clock_type("Global Clock"),
        .ena_register_mode("falling edge"),
        .ena_register_power_up("high"),
        .disable_mode("low"),
        .test_syn("high")
    ) u_clkena (
        .inclk(clk), .ena(ce_fall), .enaout(), .outclk(gclk)
    );
`endif
endmodule

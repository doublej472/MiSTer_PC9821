# 6. Memory: the SDRAM controller and its bridges

143. **Same-row write follow-on in the SDRAM controller.** **WORK.** Every single-dword store pays
    ACT, tRCD and auto-precharge, so the controller accepts one store every 7 cycles at 90 MHz
    (8 before the write exit trim) even when the next store is already waiting in the same row
    (82 % of Dhrystone's consecutive stores). Keep the row open when the presented follower is in
    the same chip, bank and row, write it without a new ACT, and close it with an explicit
    PRECHARGE when the streak ends, so a non-hit access is cycle-identical. Hold tRAS, tWR, tRC
    and the refresh deadline. The lane is closed; the implementation is the tag `archive/sd-impl` (commit c83f5b3b, not merged): same-row
    stores 4 cycles apart at 90 MHz and 5 at 120 MHz, real-controller Dhrystone 271,807 ->
    240,330 (-11.6 %), sequential stores 145,938 -> 83,898 (-42.5 %). Its fit cost, 6 seeds per
    side at 90 MHz `base`: with the live row compare, clk_sys mean slack -6.51 ns against -5.13 ns
    for the tree without it, and 4 of 6 seeds clear the `pll_hdmi` floor; with the compare
    registered a cycle early (`CHAIN_KEY_REG`, same-row stores 5 cycles apart, Dhrystone 246,490),
    -6.05 ns and 6 of 6 (about 0.9 ns clk_sys worse than the tree without it). The route to
    take is the `CHAIN_KEY_REG=1` variant, after a 6-seed per-side sweep. Either variant moves
    the two real-controller pins (boot 942534, Dhrystone 271807): it is a performance trade
    that buys speed for clk_sys margin, so the owner decides. **Done when:** it costs no clk_sys margin on a 6-seed sweep per side
    (mean and worst within the placer's noise) and no `pll_hdmi` loss, the SDRAM benches,
    `tb_pc9821_sdram_chain` and the chip model's checks stay green, and the real-controller
    Dhrystone and boot pins (`docs/dhrystone-numbers.md`, `docs/testing.md`) are moved with the
    change's attribution.

161. **A DMA byte behind a posted PEGC store.**
    **WORK.** A uPD71071 byte takes the CPU's route for its address (`tb_pc9821_dma_route`; the
    machine agrees in every measured window, `docs/probes/DMAROUTE-XE10.TXT`), but a CPU PEGC
    packed/aperture store is posted in `pc9821_pegc_storebuf` for up to 1 us, which a DMA byte
    to the same dword does not drain, so the two are ordered by the backend rather than by
    program order. No known guest DMAs into a PEGC window. **Done when:** a DMA access to a
    buffered PEGC dword is ordered after the CPU's earlier store, with a fail-first bench.

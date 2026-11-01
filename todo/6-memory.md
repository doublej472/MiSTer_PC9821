# 6. Memory: the SDRAM controller and its bridges

143. **Same-row write follow-on in the SDRAM controller.** **WORK.** Every single-dword store pays
    ACT, tRCD and auto-precharge, so the controller accepts one store every 7 cycles at 90 MHz
    (8 before the write exit trim) even when the next store is already waiting in the same row
    (82 % of Dhrystone's consecutive stores). Keep the row open when the presented follower is in
    the same chip, bank and row, write it without a new ACT, and close it with an explicit
    PRECHARGE when the streak ends, so a non-hit access is cycle-identical. Hold tRAS, tWR, tRC
    and the refresh deadline. An implementation exists (commit c83f5b3b, not merged): same-row
    stores 4 cycles apart at 90 MHz and 5 at 120 MHz, real-controller Dhrystone 271,807 ->
    240,330 (-11.6 %), sequential stores 145,938 -> 83,898 (-42.5 %). Its fit cost, 6 seeds per
    side at 90 MHz `base`: with the live row compare, clk_sys mean slack -6.51 ns against -5.13 ns
    for the tree without it, and 4 of 6 seeds clear the `pll_hdmi` floor; with the compare
    registered a cycle early (`CHAIN_KEY_REG`, same-row stores 5 cycles apart, Dhrystone 246,490),
    -6.05 ns and 6 of 6. **Done when:** it costs no clk_sys margin on a 6-seed sweep per side
    (mean and worst within the placer's noise) and no `pll_hdmi` loss, the SDRAM benches,
    `tb_pc9821_sdram_chain` and the chip model's checks stay green, and the real-controller
    Dhrystone and boot pins (`docs/dhrystone-numbers.md`, `docs/testing.md`) are moved with the
    change's attribution.

148. **DMA into an EMS page or the PEGC bank goes to the SDRAM hole.** **WORK.** A uPD71071 byte
    addressed to 0xB0000-0xBFFFF while a 0x043F EMS page is selected, or to a plane window
    (0xA8000-0xBFFFF, 0xE0000-0xE7FFF) in 256-colour mode, takes the backend arm at its physical
    address (`pc9821_memory_subsystem.sv` `dma_gvram_live`), which is the SDRAM under the window
    that the CPU does not read there. NP2kai sends the byte where the CPU's handler table points
    (mem/dmax86.c `MEMP_WRITE8` -> i386c/cpumem.c `memfn0.wr8[address >> 15]`): the EMS page,
    or the PEGC bank. The window-0 move of a DMA address (0x0461) is the same class and is also
    not modelled. No known guest transfer targets these windows. **Done when:** a DMA byte in
    each case lands where a CPU byte store at the same address lands, routed through the map's
    EMS/PEGC translation, with a fail-first bench against NP2kai's routing.

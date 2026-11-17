# 6. Memory: the SDRAM controller and its bridges

143. **Same-row write follow-on in the SDRAM controller.** **DECISION (OWNER).** Every
    single-dword store pays ACT, tRCD and auto-precharge, so the controller accepts one store every
    7 cycles at 90 MHz even when the next store is already waiting in the same row (82 % of
    Dhrystone's consecutive stores). Keeping the row open for a same-chip/bank/row follower (an
    explicit PRECHARGE when the streak ends, so a non-hit access is cycle-identical, and tRAS, tWR,
    tRC and the refresh deadline held) is implemented at the tag `archive/sd-impl`; its speed and
    clk_sys-margin numbers are `docs/trade-candidates.md` T90. The route is the `CHAIN_KEY_REG=1`
    variant after a 6-seed per-side sweep; either variant moves the real-controller pins (boot
    1706106, Dhrystone 271807), so the owner decides. **Done when:** the owner decides; if taken, it
    costs no clk_sys margin on a 6-seed sweep per side and no `pll_hdmi` loss, the SDRAM benches
    and `tb_pc9821_sdram_chain` stay green, and the real-controller pins
    (`docs/dhrystone-numbers.md`, `docs/testing.md`) move with the change's attribution.

161. **A DMA byte behind a posted PEGC store.**
    **WORK.** A uPD71071 byte takes the CPU's route for its address (`tb_pc9821_dma_route`; the
    machine agrees in every measured window, `docs/probes/DMAROUTE-XE10.TXT`), but a CPU PEGC
    packed/aperture store is posted in `pc9821_pegc_storebuf` for up to 1 us, which a DMA byte
    to the same dword does not drain, so the two are ordered by the backend rather than by
    program order. No known guest DMAs into a PEGC window. **Done when:** a DMA access to a
    buffered PEGC dword is ordered after the CPU's earlier store, with a fail-first bench.

196. **`cpu_run` fans out raw into the CPU request gating.**
    **WORK.** After the registered reset tree, the largest single-register cone on `clk_sys` was
    `cpu_run`: about 17,200 endpoints, about 8,450 of them failing, worst about -4.0 ns (timing
    census of a full fit taken before the frame-end wait at `cpu_run`). Most of it is the
    `cpu_valid && cpu_run` request gating (about 7,200 endpoints into the GVRAM RAM), not resets.
    Two registers carry it now: the loader's `cpu_run_ld` (`pc9821_rom_loader`) and the system's
    `cpu_run`, which is `run_r` in `pc9821_raster_reseed` (it rises at the first frame end after
    `cpu_run_ld`, `docs/trade-candidates.md` T93, and the same edge re-seeds the raster counter,
    `reseed_cnt`). It was left raw on purpose: registering it moves the release edge by one clock,
    and a registered copy for the gating must move the raster re-seed with it or the guest's first
    raster clocks change. **Done when:** the census is re-taken on a current fit; `cpu_run`
    reaches its consumers through registered copies (as the reset tree does for reset), with the
    re-seed moved together and the release-edge move shown to be guest-invisible by a bench (the
    first CPU fetch after a core load is unchanged, or moves by the documented clock with the boot
    golden attributed); a seed sweep shows the cone cleared without a `pll_hdmi` or SDRAM I/O loss;
    and the `cpu_run` sentences in `docs/timing.md` and `pc9821_memory_subsystem.sv` (which still
    call it the loader's register) are updated.

225. **INTA bridge: the taken flag follows the masked strobe.** **WORK.** `pc9821_cpu_bus_bridge.sv`
    drops the platform INTA while an accept is held (`p_inta = c_inta && !acc_pend`), and
    `pc9821_inta_bridge.sv`'s `inta_responded` is computed from that masked strobe, so during a
    throttled accept wait the flag clears without the CPU releasing INTA. Nothing is lost today
    (`tb_pc9821_throttle` covers INTA at 8 and 1 MHz), but the bridge's double-answer assertion
    cannot see a held strobe answered twice under throttling, and its comment ("the clear can only
    fire while the strobe is low") no longer holds. **Done when:** the taken flag (or the assertion)
    is driven from the CPU-side strobe, the comment is corrected, and a bridge bench that holds an
    accept across several disabled cycles fails on a second answer before the CPU's INTA falls
    (proven with a mutation entry), with the throttle and inta_bridge benches and the integrated
    build green.

228. **Xe10 I/O timing below about 47 MHz clk_sys.** **WORK.** The Xe10 I/O hold (`pc9821_iobus.sv`
    S_IOWAIT, 12-bit unsigned) subtracts the CPU's share and the FSM's own cycles from the class
    time; the fastest class (0x0FAA, 255 ns) leaves exactly 0 at 50 MHz, so below about 47 MHz the
    subtraction wraps to a stall of about 4,090 cycles per access. Every preset is above it, but
    `build_profile.py --custom` accepts clk_sys down to 25 MHz. **Done when:** `build_profile.py`
    rejects (or clamps) a custom clk_sys whose fastest Xe10 class is shorter than the subtracted
    cycles, with a `--selftest` plant, or the iobus clamps the subtraction at zero with a fail-first
    bench at a 40 MHz SYS_CLOCK_HZ; and the posted 0x5F write and IO_MIN_HOLD classes are shown not
    to reach that stage.

229. **mediumoc: CL3 at 100 MHz unconfirmed on hardware.** **UNVERIFIED (INFERRED).** Builds at 100
    MHz and above use CL3 (`build_profile.py`, `sdram.v` `CAS_I`; `docs/trade-candidates.md` T58),
    resting on two boards' placement statistics; the `mediumoc` preset with CL3 has not passed its
    own hardware run, and the -7 part's CL2 minimum tCK is not cited from its datasheet. **Done
    when:** `mediumoc` passes the scripted regression on both test cards with the result in
    `docs/sdram-margin.md`, or `docs/build.md` lists it as an unconfirmed overclock; and the -7 CL2
    tCK is cited, or the docs say the cutover rests on the hardware evidence only.

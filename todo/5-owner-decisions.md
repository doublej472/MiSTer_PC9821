# 5. Owner decisions

Blocked on a maintainer decision, not on work. Latency trades live in
`docs/trade-candidates.md`, not here.

53. **z486 reset-state divergences.** **DECISION (OWNER).** `CR0` resets to `0x00000010` (the
    datasheet says `0x60000010`); `idt_limit`/`gdt_limit` reset to `0x003FF` (datasheet `0xFFFF`).
    The CR0 half is the z486 parameter `RESET_CACHE_DISABLED` (0 today). **Decision:** probe the
    CR0 the ITF leaves at the DOS prompt FIRST, then decide whether to set the parameter to 1. The
    limit half (a z486 fork change in `segmentation_unit.sv` plus a passing suite) stays noted as a
    fork change pending that CR0 check. **Done when:** the DOS-prompt CR0 is known and the
    parameter and the limits are decided from it.

82. **I/O access cost per port class: machine bus time or the shortest stall.** **DECISION
    (OWNER).** The machine's per-class costs are measured (`docs/probes/IO.TXT`, against the
    1621 ns `0x5F` anchor). The default `min` profile charges the FSM floor except for the `0x5F`
    wait and the 8253; `iofaithful` charges the measured table (`pc9821_iobus.sv`;
    `ioprobe_decode.py --check-rtl` compares them). **Decision:** the default stays the `min`
    profile and `iofaithful` stays opt-in. **Open verification:** the EGC register file's
    address-parity split (even 8.6-9.4 us, odd ~825 ns) needs its mechanism resolved before any
    floor is set around it. **Done when:** the parity split's mechanism is explained by a capture
    or the chip references.

140. **Licence of the original MiSTer port's surviving code.** **DECISION (OWNER).** These files
    still carry code from nand2mario's z486_MiSTer port, which states no licence (checked
    2026-10-30: GitHub reports none for the repository and its README has no licence text;
    nand2mario's z486 CPU repository is Apache-2.0); `NOTICE` (part 5) lists them as "licence to
    be confirmed". The project's own licence is undecided too: the Apache-2.0 `LICENSE` was
    removed and `NOTICE` reduced to third-party notices, granting no licence for the project's
    own code, until this item settles which licence it takes. Surviving
    share (lines by `git blame -w -M -C`, licence audit 2026-10-28): `z486_mister.sv` 649/2141
    (30 %; also ao486.sv/Template.sv ancestry, GPL-2-or-later), `src/memory/sdram.v` 371/2096
    (18 %), `src/memory/split_sdram_backend.sv` 76/222 (34 %), `src/memory/sdram_sync_bridge.sv`
    33/209 (16 %), `src/common/uart_tx_V2.v` 91/99, `src/pc9821/interrupts/pc9821_inta_bridge.sv`
    0 lines by blame but 35 % of its 8-token shingles (renamed from `pic_inta_bridge.sv`, header
    text kept), `z486_mister.qsf` 334/401, `z486_mister.qpf` 2/2,
    `z486_mister.clk_sys_top_setup.tcl` 7/7, `backend.qip` 11/109, `rtl/pll/pll_0002.qip` 4/4,
    `Makefile` 7/42, `.gitignore` 26/107, `build_profile.py` 92/2249 (4 %),
    `tools/profile/z486_mister.sdc.in` (renamed from the port's `z386_mister.sdc`, since templated
    and largely rewritten; share not measured), `tools/fit_metrics.py` 5/260,
    `tools/check_sdram_pins.py` 3/170. **Owner's intent:** share a licence with the
    original core, since so much of this project derives from it: match z486_MiSTer's licence
    once it has one. That needs its author to choose one, so the next step is an owner action:
    ask nand2mario to license z486_MiSTer, then choose the project's own licence to match and add
    it as the root `LICENSE`, with `NOTICE` part 5 folded into that grant. Still to do either
    way: trace the projects those files were themselves copied from (many may predate the port)
    and confirm theirs. The fallback, if no licence comes, is to rewrite the surviving code.
    **Done when:** the project's own licence is chosen and in the root `LICENSE`, and every listed
    file has a confirmed licence (and its `NOTICE` entry says so) or no longer contains the
    port's code.

146. **Review NOTICE's copyright line.** **DECISION (OWNER).** `NOTICE` opens with "Copyright
    2026 Jonathan Frederick and the project's contributors". The Apache-2.0 grant that followed
    it was removed with `LICENSE` (item 140); the line itself is kept unchanged as a plain
    copyright statement, not a licence grant. **Done when:** the owner has reviewed the line and either kept it or changed it.

149. **Graphics GDC WRITE pacing.** **DECISION (OWNER).** The WRITE family (WDAT and the other
    write commands) runs unpaced, while the Xe10 takes about 1.40 us per word
    (`docs/probes/gdc-conformance`, GDCTIME WDAT_N0001..N0257: 3442 milli-ticks of the
    2.4576 MHz PIT per word). Unpaced, DRAWING (0xA0 bit 3) clears almost at once and FIFO FULL
    (bit 1) is never reached; figure drawing is paced at 0.665 us per dot, faster than the
    machine's WRITE rate. Options: the machine's 1.40 us, figure parity, or unpaced (today); a paced WRITE
    needs the FIFO hold first. Deferred to the release after 2026-10-31. Test it against Rusty's
    C-Lab logo intro, which runs fast at full CPU speed and is right at 16 MHz
    (`docs/compatibility.md`), with a build pacing WRITE at 1.40 us (and figures at the
    machine's rate where a capture gives it). **Done when:** the pacing is chosen and that A/B on the Rusty intro is recorded.

# 5. Owner decisions

Blocked on a maintainer decision, not on work. Latency trades live in
`docs/trade-candidates.md`, not here.

53. **z486 reset-state divergences.** **DECISION (OWNER).** `CR0` resets to `0x00000010` (the
    datasheet says `0x60000010`). The machine at the DOS prompt (`docs/probes/KIT1-XE10-CFG0.TXT`, the
    CPU line): `CR0 = 0x00000032` (CD = NW = 0, ET, NE, and MP, which the BIOS sets because the
    486DX2's FPU answers FNINIT: `fpu_sw=0000 fpu_cw=037F`). The core
    (`docs/probes/core/KIT1-CORE-rc-e6db0f05-s3-CFG0.TXT`): `CR0 = 0x00000030` and no FPU
    (`ENABLE_X87 = 0` in `z486_mister.sv`), which is also why MP differs. So the ITF leaves CD/NW
    clear whatever the reset value. The IDTR/GDTR half is answered and fixed: the machine holds
    limit `FFFF`, base 0, at the DOS prompt (`docs/probes/KIT1-XE10-CFG0.TXT:78` `idt=FFFF:00000000
    gdt=FFFF:00000000`; NP2kai's reset agrees) and straight after a CPU-only reset through port F0
    with no POST in between (`docs/probes/KIT2-XE10-RSTDTR.TXT:2`, `reset idt=FFFF:00000000
    gdt=FFFF:00000000 cr0=00000030`), and the fork resets both to `FFFF` (z486 `d5cf5bd`, vendored,
    `tb_reset_dtr`; the core's kit-2 capture predates it). The same reset leaves EDX = `00000432`
    on the machine (family 4, model 3, stepping 2; the Xe10's CPU has no CPUID) where z486 sets
    `00000420` (`src/z486/data_unit.sv:1439`, `edx     <= 32'h0000_0420;`), which CPU-detection code
    that reads DX after a reset can see. The cache sub-question is answered by the same capture:
    straight after the CPU-only reset the machine reads `cr0=00000030` (CD and NW clear), so the
    z486 parameter `RESET_CACHE_DISABLED` stays 0, as it is. **Decision:** whether the core
    carries the FPU (`ENABLE_X87`, an area trade), and which reset signature it reports (setting
    EDX to `0x432` is a fork-first change with a fork bench; the fork's own tests may rely on
    `0x420`). **Done when:** both are decided on this data, and a core RSTDTR capture on the
    current build confirms the IDTR/GDTR fix on a card.

140. **Licence of the original MiSTer port's surviving code.** **DECISION (OWNER).** These files
    still carry code from nand2mario's z486_MiSTer port, which states no licence (checked
    2026-10-30: GitHub reports none for the repository and its README has no licence text;
    nand2mario's z486 CPU repository is Apache-2.0); `NOTICE` (part 5) lists them as "licence to
    be confirmed". The project's own code is licensed under Apache-2.0 (root `LICENSE`, owner
    decision 2026-11-04); in these files that grant covers only the project's own contributions,
    not the port's surviving lines, which this item still has to settle. Surviving
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
    `tools/check_sdram_pins.py` 3/170. **Options:** ask nand2mario to license z486_MiSTer (a
    licence compatible with Apache-2.0 and with the GPL parts the bitstream carries would let
    `NOTICE` part 5 record it, or fold those lines into the project's grant if nand2mario agrees),
    or rewrite the surviving lines. Still to do either way: trace the projects those files were
    themselves copied from (many may predate the port) and confirm theirs; and the gameport/MIDI
    wiring odiaboeeu contributed to the port (`NOTICE` part 5; about a dozen lines of
    `z486_mister.sv` by blame) needs that contributor's licence statement in `NOTICE`, or the
    lines rewritten. **Done when:** every
    listed file has a confirmed licence (and its `NOTICE` entry says so) or no longer contains
    the port's code. The 2026-11 release ships with these files listed in `NOTICE` as "licence to
    be confirmed" (owner decision, 2026-11-06).

149. **Graphics GDC WRITE pacing.** **DECISION (OWNER).** The WRITE family (WDAT and the other
    write commands) runs unpaced by default, while the Xe10 takes about 1.40 us per word
    (`docs/probes/gdc-conformance`, GDCTIME WDAT_N0001..N1025: a least-squares 1401.5 ns per
    word against the 2.4576 MHz PIT, 1400.4 ns over N0001..N0257). Unpaced, DRAWING (0xA0 bit 3)
    clears almost at once and FIFO FULL (bit 1) is never reached. Figure drawing is paced at
    14 dot clocks (0.665 us) per dot by default; the capture gives the machine's figure rate too
    (GDCTIME LINE_N0001..N2049: 1401.4 ns per dot). **What exists:** both paces are compile-time
    options, 0 (today's engine) in every preset: `python3 build_profile.py base --gdc-write-pace
    1400` (GDC_WRITE_PACE_NS, `pc9821_gdc2` WRITE_PACE_NS) and `--gdc-fig-pace N`
    (GDC_FIG_PACE_NS, FIG_PACE_NS), each N ns of real time per unit at any clk_sys.
    `tb_pc9821_gdc2_pace` holds a paced build to the WDAT_N and LINE_N rows (within one period:
    1400 ns matches the rows up to N = 513, 1401 ns every row) and shows FIFO FULL reached behind
    a paced 64-word WRITE; the FIFO hold it needs is in the tree. Options for the default: the
    machine's rate (1400 or 1401 ns), figure parity, or unpaced (today): machine-accurate pacing
    against guest-visible speed, a trade the owner decides. Rusty's C-Lab logo intro, the title
    first suspected, does not depend on it: **A/B recorded (2026-11-09, one card, CPU Speed Full,
    a build pacing both, `--gdc-write-pace 1401 --gdc-fig-pace 1401`, and one pacing WRITE alone):**
    neither build changes the intro: the logo's sine wipe takes 0.35 s (both paced) and 0.33 s
    (WRITE paced) against 0.33 s unpaced, the whole logo 5.15 s in all three, and the voice is the
    same length. The wipe draws through the GRCG with the CPU, not with GDC commands (the
    machine's own timing of it is `tools/hwprobe/rwipe`), so Rusty does not depend on the WRITE rate,
    and no other title is known to. **Done when:** the pacing is chosen (unpaced stays the default
    until a title needs otherwise).

160. **CPU outlier instructions.** **WORK.** The machine is a 486 at 100 MHz (XE10T `/ID`:
    `cpuid=0`; `docs/probes/XE10T-XE10.TXT`). Owner decision 2026-11-01: the core's CPU being
    uniformly slower than the machine (its 90 MHz clock, about 11 %) is accepted; specific
    instructions, calls or memory accesses that cost much more than a 486's are followed up in the
    z486 fork. Outliers at equal clock (XE10T `/CPU`, core vs machine): CLI/STI about 1.8x, near
    CALL 1.5-1.8x, INT/IRET about 1.5x (also through BIOS INT 18h, 1.45-1.53x), LOOP about 1.4x.
    Cause: these still run the 80386 microcode sequences (late or redundant queue flushes, the V86
    IOPL gate in real mode, a 5-word real-mode CS load). Fixed in the fork (vendored `d5d0974`,
    fork-simulator clocks of the XE10T `/CPU` replica): CLI/STI 8.0 -> 4.8, STI+CLI 16.0 -> 9.8,
    LOOP not taken 10.9 -> 6.7, CALL m16:16 + RETF 41.0 -> 35.0 with an aligned pointer, RETF
    22.2 -> 19.2, IRET 35.0 -> 32.0, INT n + IRET 63.0 -> 59.0. A further outlier the CALLF row
    exposed: an access crossing a dword boundary takes paging's crossing path, 10.5 clocks for a
    load instead of the 486's about 4. A direct load inside one 16-byte line now takes 4.5 (one
    crossing a line still 10.5); a microcode read does not yet, and the probe's own CALLF row has
    its far pointer unaligned (48.2 -> 42.2, machine 35.6): extending the two-dword probe to
    microcode reads is the next step there.
    Still open, as proposals: near CALL/RET (a `call-rel` redirect from the D2 target, RET from the
    load data, CALL r/m as a recipe; Dhrystone moves), LOOP taken (8.9; JCNT1 on eCX, or a
    hardwired `loop-rel`), the INT/IRET IOPL gate outside V86 (a !VM entry overlay, -2 each), and
    the real-mode vector read on the L1 probe path (a trade: -1 per warm INT, +1 on the boot golden;
    `docs/trade-candidates.md` T75). The `/CPU` probe has not been re-run on a core with these
    changes.
    Misaligned main-memory accesses (XE10W `/MISAL2`, `docs/probes/XE10W-XE10-MIS2RUN1.TXT` against
    `docs/probes/core/XE10W-CORE-rc-c03da744-s3-XE10-MIS2RUN1.TXT`, ns per access, L1-warm): a word
    load across a dword 87.6 on the machine, 98.4 on the core; across a 16-byte line 87.5 against
    165.1 (1.9x); a dword load at offset 1 88.7 against 109.6, across a line 88.7 against 176.2 (2x).
    The other way round, the core is faster: stores (aligned 102.2 against 80.8, across a dword
    199.1 against 160.5), `rep movsw` to an odd destination 149.6 against 86.6 and `rep movsd` to
    one 201.9 against 117.2, a missing line 327 against 255. Owner decision 2026-11-11: recorded
    here and left for the fork (the line-crossing load is the paging crossing path above).
    With the Xe10 read period in place (`docs/probes/core/XE10W-CORE-grcgrd-d6722e67-s3-XE10-MIS2RUN1.TXT`),
    `rep movsw` from the GVRAM to main memory is 652 ns a word on the core against 777 on the machine
    (`GMVR_0_V`): the machine's string move adds its RAM store after the read, the core's overlaps.
    **Done when:** each outlier is explained against the 486's documented clocks and either fixed
    in the fork (re-vendored per AGENTS.md) or recorded as a trade.

153. **EGC read pace.** **DECISION (OWNER).** The machine's same-page EGC read+write costs 677 ns
    net (`docs/probes/EGCP.TXT`); the core's plane-serial EGC (`docs/trade-candidates.md` T41)
    costs 263.9 ns, flat over 1-4 planes, and `tb_pc9821_egc_xe10_pace` bounds it from above only.
    In the Xe10 I/O timing the EGC's requests are exempt from the class table by design
    (`pc9821_gvram_arb.sv`, the Xe10 table's note). Pacing the EGC read to the machine's would add
    guest-visible latency to an EGC-heavy path, a latency trade. The machine half of the XE10T
    `/EGC` section is captured (`docs/probes/XE10T-XE10.TXT:172-219`); no core run of it exists.
    **Done when:** the owner decides whether the EGC read is paced (if so: a class-table row from
    `EGCP.TXT`'s 677 ns and a fail-first bench), and a current-core XE10T `/EGC` capture is
    compared with the machine's.

230. **Keyboard receive FIFO overrun: which byte is lost.** **DECISION (OWNER).** `pc9821_kbd.sv`
    enqueues only while fewer than 16 bytes wait and drops the NEW byte on overrun (often a key
    release, so the guest sees a stuck key), as NP2kai and QEMU do; the uPD8251A die has a one-byte
    receive register and overwrites the OLD character. Other die divergences in the same 8251 table
    are left waived: no receiver gating by RxEN/RTS, every 0x43 write after an internal reset taken
    as a command, 0x99 answering FA FB where NP2kai answers FC, and the residual IRQ re-poke window.
    A related rule rests on no reference: a make is refused and OE set while the queue still has
    free slots (`room_2`: `fifo_owed < 9'd15`, the break reservation), which neither NP2kai (drop-newest
    only when its queue is full) nor undoc98 shows; with many keys held the guest sees OE early.
    **Decision:** keep the references' drop-newest, or follow the die. **Done when:** either the
    overrun keeps the newest byte (drop the oldest, set OE) with a fail-first bench from the
    datasheet and a mutation entry, or the reference behaviour is written into
    `docs/pc9821-port-status.md` (the 8251 section) as a deliberate divergence with the waived rows
    listed; and OE on a refused make is either kept (recorded the same way) or raised only when the
    queue is full, with `tb_pc9821_kbd_overrun_break` asserting the choice.

231. **Published-tree hygiene: attributions, internal labels and a check.** **DECISION (OWNER).**
    `docs/policies.md` ("Documentation and wording") bans attributions, dated decision quotes and
    internal labels in the published tree, but the tree carries many: "owner decision" notes and
    quoted chat in src comments and `docs/trade-candidates.md` (review labels and approval quotes in
    the T84-T93 rows), and the policy file itself uses dated owner-decision notes; no tool checks
    the pre-push rules (no machine or host names, no private paths, no game names in README).
    **Decision:** (a) amend the rule to allow dated decision notes as a record of authority while
    banning quoted chat and review labels, or (b) scrub them. **Done when:** the tree matches the
    chosen rule, and a `tools/check_release_hygiene.py` (seconds, pure python, with an allowlist of
    intended public references) fails on the banned patterns, is listed in AGENTS.md's static checks
    and passes on the release tree.

232. **Trade rows still Raised: a disposition for each.** **DECISION (OWNER).** About 25 rows of
    `docs/trade-candidates.md` sit at Raised with no recorded disposition (T10, T16, T19, T20,
    T24-T27, T30, T33, T34, T38, T39, T42, T50, T55, T56, T59, T61, T64-T66, T75, T76, T90). T90
    (the SDRAM same-row write follow-on, item 143) changes the bitstream, so it needs its answer
    before a release fit sweep. **Done when:** each Raised row has a one-line disposition (taken,
    not taken for this release, parked, or superseded), T90 has its yes or no before the sweep, and
    T33/T34 (which wait on a PEGC store-rate capture) get a capture item or are marked not planned.

233. **z486 microcode and table data files: their licence.** **DECISION (OWNER).**
    `src/z486/LICENSE-SCOPE.md` limits the Apache grant to the fork's `*.sv`, `*.svh`, `*.py` and
    `*.md` files and excludes `ucode.hex`; `NOTICE` part 1 says the other `*.hex` and `*.mif` files
    are outside it too. The design loads `ucode.mif` and `x87_ucode.mif` (`z486_mister.qsf`) and the
    PLA tables, so they are in every bitstream with no stated terms. **Done when:** for each data
    file the bitstream embeds, `NOTICE` and `src/z486/LICENSE-SCOPE.md` state a confirmed licence
    (upstream's terms or permission), or the file is shown to be generated by Apache-covered scripts
    in the tree.

234. **NOTICE part 8 and the GPL-2 text.** **WORK.** `NOTICE` part 8 lists the NP2kai tables
    transcribed and says no other code is copied, but the tree takes more data from NP2kai source
    (the FDC command parameter-count table, the raw-floppy size guesser rows, the even-port
    termination sets of `iocore16.tbl`, the EGC ROP table's organisation) and from ao486
    (`pc9821_gameport.sv`'s axis formula and tick, `pc9821_pic.sv`'s cited behaviour), and ao486 is
    not in part 4; `NOTICE` refers to GPL-2 text for `sys/` that the tree does not ship. **Done
    when:** each table or file is added to part 8 (NP2kai) or part 4 (ao486), or recorded there as
    facts-only with the reason, the "no other code is copied" sentence is true as written, and
    `NOTICE` ships the GPL-2 text or words the `sys/` sentence so it does not point at an absent
    file.

235. **Build identification in the OSD.** **DECISION (OWNER).** CONF_STR ends with a bare `"V,v"`
    (`z486_mister.sv`), without the template's BUILD_DATE, and the shipped RBF is undated, so a user
    or a report cannot tell which release is running. A build date in the netlist makes every fit
    differ (`tools/check_fit.py` excludes `build_id.v` from its attribution hash for that reason).
    **Decision:** show a build date or release tag, or stay unversioned. **Done when:** the OSD
    shows the chosen identification (with the fit-determinism consequence in `docs/fitting.md`), or
    `docs/policies.md` records that the core is unversioned and what a report should quote (the
    release notes' sha256).

236. **`mister_load.sh` and an RBF with no timing record.** **DECISION (OWNER).**
    `tools/mister_load.sh`'s `pll_hdmi` gate refuses a below-floor build but only warns, and
    deploys, when `artifact-timing.json` is missing or has no margin field, so a copied RBF without
    its record bypasses the gate AGENTS.md describes. **Decision:** refuse or warn. **Done when:**
    either the branch refuses (with a `--selftest` case, still overridable by
    `--allow-marginal-hdmi`), or `docs/fitting.md` records warn as the rule and the
    release-candidate procedure requires the deploy log to show a margin line.

237. **Release notes for the next release.** **WORK.** No notes exist for the next release; the only
    draft describes the previous one, with stale counts and document paths. A release blocker in
    documentation. **Done when:** a new notes file (kept with the other release material, not edited
    over the shipped notes) names the chosen release-candidate fit (seed, sha256), its compatibility
    counts equal `docs/user/compatibility.md`'s summary, its document paths resolve, it covers each
    user-visible change since the previous release, and the maintainer has reviewed it against the
    log.

238. **PC-9801-86 PCM: a frame spliced by a FIFO overflow.** **DECISION (OWNER).** Low priority:
    reachable only by a guest that ignores the 0xA466 full flag. Latching a frame base at the frame
    start leaves two splice paths: a write on the frame-start edge lands at the frame base because
    `pc9821_pcm86_buf` serves writes before a pending read, and a second write in the same frame
    overwrites an unread frame byte (a trial of the latched base spliced 17 of 287 runs against 85
    today). **Options:** (a) slip first: restart the frame at the new read pointer after the
    outstanding read (an overflow-only delay of tens of clk_sys, possibly one IRQ edge); (b)
    NP2kai's drain-first order, by serving reads before writes (changes normal-case timing) or
    back-pressuring the write (a latency trade); (c) accept the latched base as a partial
    improvement. **Done when:** an option is chosen and, if (a) or (b), a full-buffer write during
    the frame fetch is benched against NP2kai's order with no splice.

256. **`tb_pc9821_gvram_latency`: a ceiling or the machine's pace.** **DECISION (OWNER).** The
    bench's per-operation checks are upper bounds only (`floor()` fails only above the capture
    plus its tolerance), so a tree with every `GVRAM_PERIODS` constant zeroed passes all eleven ns
    checks: every pre-model value the bench lists (write 80 ns, read 180, PW4RW 130, copy 130/260,
    GRCG 100) is faster than its capture. Only the 50 MHz busy-scene lower bound would catch it,
    and the claim's FAIL-FIRST sentence is false. **Decision:** faster-than-the-machine is legal
    (reword the claim, keep the ceiling, add the 100 MHz scene lower bound), or the capture is a
    floor (add a lower bound of capture minus tolerance at both clocks). **Done when:** the claim
    states the chosen rule, the bench asserts it, and a mutant zeroing a period is killed.

257. **Benches that pin exact latency and handshake laws.** **DECISION (OWNER).** Several benches
    hold an exact internal timing that no capture prices, so a correct and faster redesign fails
    them: the GRCG/EGC store hold bounds and array-access counts (`tb_pc9821_gfx_engine_hold`,
    `tb_pc9821_gfx_walk_hold`), the one-clk_sys store hold (`tb_pc9821_gvram_decouple`), the
    store buffer's `in_ready` on a full buffer (`tb_pc9821_pegc_store_rate`'s full-buffer-combine
    leg), the 3-clk enqueue / 4-clk deliver depth (`tb_pc9821_kbd_pipeline`), the throttled
    bridge's snoop hold and exact snoop count (`tb_pc9821_dma_snoop_throttle`), and the exact
    host-cost and stall laws (`tb_pc9821_block_hostcost`, `tb_pc9821_rt_queue`,
    `tb_pc9821_subsystem_stalls`). Each is a latency/area trade
    (`docs/trade-candidates.md`), not a hardware fact. **Decision:** which stay as project gates
    (labelled as such in their claims) and which become bounds or guest-visible period checks
    against the captures. **Done when:** each named bench's claim says which it is, the converted
    ones assert bounds or captured periods, and `docs/trade-candidates.md` records the gates that
    stay.

258. **Keyboard 0x9D: the NUM lamp bit.** **DECISION (OWNER).** `pc9821_kbd.sv` keeps bit 0 (NUM)
    of the 0x9D lamp command (`lock_flags <= din[3:0] & (LOCK_NUM | LOCK_CAPS | LOCK_KANA)`),
    drives the NUM lamp from it and echoes it in the 0x9D+0x60 query, and `tb_pc9821_kbd_led`
    expects it "as NP2kai does". NP2kai's `keystat.c` stores only CAPS and KANA and its
    `getledstat()` never reports NUM. No capture covers the NUM bit. **Decision:** follow NP2kai
    (drop NUM from the set and the query) or keep it as a deliberate divergence with a real-keyboard
    source. **Done when:** the RTL and `tb_pc9821_kbd_led` follow the choice, the bench asserts the
    query after a NUM set, and a kept divergence is cited in the 8251/keyboard section of
    `docs/pc9821-port-status.md`.

266. **ROM loader: a short pack download.** **DECISION (OWNER).** `pc9821_rom_loader.sv` enforces
    only the upper bound (`address_ok = (ioctl_addr < PACK_BYTES) && !ioctl_addr[0]`): a
    "Load BIOS ROM" file shorter than the 1 MiB pack (`tools/pack_layout.py` PACK_SIZE) still
    raises rom_ready and releases the CPU against whatever SDRAM holds, and
    `tb_pc9821_rom_loader`'s short-download block only reports it. **Decision:** raise load_error
    when the download ends below the pack size (or below a parameterised minimum), or keep the
    permissive load. **Done when:** the choice is in the RTL or written into the loader header,
    and the bench asserts it (a fail-first case for a rejected short download, with a mutation
    entry).

270. **Bench policy: reference copies, mutants and internal pins.** **DECISION (OWNER).** Open
    questions the bench review left: (a) whether benches that compare against a frozen copy of our
    own earlier RTL (`crtc_geom_equiv`, `gdc2_equiv`, `pegc_equiv`, `pegc_storebuf_equiv`,
    `fdd_media_equiv`, `pic_equiv`, `audio_out_equiv`, `audio_volume_equiv`, `pcm86_equiv`,
    `tram_addr_equiv`, `gvram_porta_equiv`, `gvram_arb_equiv` and the z486 `*_equiv` benches) stay
    in the battery, are excluded from the correctness claim, or retire once their refactor has
    soaked; (b) whether every bench needs a killed mutant (item 240); (c) retiring `tb_pc9821_gamma`
    and `tb_pc9821_shadowmask`, which compare the frozen `sys/` modules with copies of themselves;
    (d) the rewrite plan for the benches judged implementation-detail (debug-UART contracts kept
    only under `check_telemetry_contract.py`, internal taps replaced by port or output checks); (e)
    `tb_pc9821_egc_post_walk`, written for an EGC per-word walk the arbiter no longer makes (the
    walk serves the plain and GRCG paths only, `pc9821_gvram_arb.sv` `cc_lane_many`), now kept as a
    data check on posted EGC writes with its walk witnesses printed only: retire it or rewrite it.
    **Done when:** each of (a)-(e) has a recorded rule in `docs/testing.md`, and the benches it
    retires or relabels are changed with `tools/check_tests.py` and the manifest following.
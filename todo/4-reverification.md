# 4. Re-verification items

Claims that rest on a single sample, or a divergence whose cause is still unknown.

42. **16-bit word I/O at byte ports: what XE10T `/AUDIT` and `/AUDIT2` leave open.**
    **VERIFIED (HW)** for one port. Word `IN` is measured (`docs/probes/XE10T-XE10-AUDIT.TXT`, W/P/D
    rows) and `pc9821_iobus.sv` follows it: odd-start words and every port outside NP2kai's even
    terminations split into two byte reads, 0x30-0x36/0x40-0x46 even and 0x7C answer 0xFF above P,
    0x20-0x26/0x60-0x7A/0xA0-0xAC even answer 0x00. Kit 2's `/AUDIT2`
    (`docs/probes/KIT2-XE10-AUDIT2.TXT`; the core: `docs/probes/core/KIT2-CORE-AUDIT2.TXT`):
    (a) word `OUT` writes both bytes on the machine, as on the core and unlike NP2kai: `out 09h,ax`
    lands 5A at 0x09 and FF at 0x0A (`WO0009 ... i1=FF x1=5A`), `out 0Ah,ax` both bytes, `out
    6Ch,ax` the low byte at 0x6C (`WO006C ... a0=70 a1=FF`) - MATCHES. (b) The new word reads match
    their class (0x26, 0x34/0x36, 0x44/0x46, 0x72-0x76, 0xA2, 0x75/0x79/0xAF) except 0x24, which
    splits on the machine (`docs/probes/KIT2-XE10-AUDIT2.TXT:54`, `W0024 b0=FF b1=0E w1=0EFF`: P + 1
    read); the core now splits it too (`tb_pc9821_iobus_word_term`). 0x20, 0x22 and 0x26 cannot
    tell a split from the 00 term (P + 1 reads 00 there) and keep it. (c) Inconclusive: the timing rows cannot tell a
    one-cycle word from a split one on the machine, because even the split control 0x0A costs the
    same as a byte read (`T000A n=1024 b=2027 w=2027`; 0x7C/0x20/0x22 likewise), so whether `in
    ax,7Ch`/`20h`/`22h` fetch P + 1 stays open. (d) Inconclusive: 0x0C24 is a live port on the machine
    (reads `5C`, `W0C24 b0=5C`; the built-in sound's decoder port, `docs/bios-setup.md`), open bus FF
    on the core, and 0x0C25 reads FF, so its word read cannot show the qualifier; 0x0422 reads FFFF
    on both. (e) Bytes the rows read that the core answers differently, with no model yet: 0x35 reads
    `B8` (`W0034 b0=FF b1=B8`; the core `BF`, the low three bits set; both kits read B8): 0x35 is
    the system PPI's port C, a latch the core keeps (`system_port_c`), and bits 0-2 are the
    RS-232C interrupt enables software sets through it, so the difference is the session's state
    (something in the core's boot sets them), not a constant; 0xD0 reads 0x21 (core FF),
    0x640 with no DRQ 0x06 (core 00); 0x641 0xFF, which the core now answers on the live bank with BSY and DRQ clear and device 0 selected (the idle bank is a PCMKIT `IDE640` row, item 251), 0xA46C 0xEE (now a constant: whether it moves
    with the 86 board's state is unmeasured). **Done when:** (c) and (d) are settled by a read-side-effect row (0x7D/0x21 state changed by
    the word read) and a 0x0C2x word row with the built-in sound enabled, and (e) has a model or a
    reason to leave it.

43. **DMA bank ports `0x21/0x23/0x25/0x27`: low-nibble width.** **NEEDS RE-VERIFICATION.** The
    latch masks with `& 0x0F` from one capture (`docs/probes/RDBACK.TXT`: `A5 -> 05`); NP2kai's
    IA32 build stores the byte unmasked. **Done when:** a second marker (e.g. `0x5A`) confirms the
    mask is exactly the low nibble.

141. **Self-modifying code inside the prefetch window.** **DECISION (OWNER):** deferred
    (`docs/trade-candidates.md` T83, revisit after this release; a fork change, measured by the
    machine, `VERIFIED (HW)`).
    Star Cruiser's drawing routine patches an immediate 18-20 bytes ahead of the executing
    instruction with no jump in between (0060:0D40 writes into 0060:0D54, 0060:0D3B into
    0060:0D4D); the 50 MHz userdisk simulation stays black where the card at 90 MHz plays.
    SELFMOD on the machine (`docs/probes/KIT1-XE10-SM.TXT`, `selfmod_decode.py`): a store by the
    5-byte `mov byte [imm],imm` is not seen up to the end of the second 16-byte line from the
    routine's start (first NEW at offset 32), a store by the 2-byte `mov [bx],ah` up to the end of
    the first line (offset 16). Kit 2's other forms (`docs/probes/KIT2-XE10-SM2.TXT`): with the store
    inside line 0, the forms with BOTH a displacement and an immediate are stale one line further
    (offset 32: `mov byte [bx+d8],imm8`, `mov word [disp16],imm16`, and the IMM form after 1, 2 or 3
    register-only instructions), the forms with only one (`mov [disp16],al`, `mov byte [bx],imm8`)
    stop at offset 16 like the REG form: Intel's "one clock for using both displacement and
    immediate" (Intel486 PRM, instruction timing footnote 22) fits, and the extra register
    instructions add nothing (the 32-byte queue holds two lines). When the store crosses into line
    1 the extra line usually holds (first NEW at 48), but not when a 16-bit field straddles the line
    boundary - the IMM form's A = 0Dh (its disp16 at bytes 15-16), the same position in the P1I-P3I
    and W16 rows, W16's imm16 at A = 0Bh - and the one-field forms gain it at one crossing each
    (`mov [disp16],al` at A = 0Fh, `mov byte [bx],imm8` at A = 0Eh): no documented mechanism, so a
    rule fitted to these rows is inference. The core is stale only through the line that holds the
    store's last byte in every form, so it matches the one-field forms in line 0 and never shows the
    extra line (`docs/probes/core/KIT2-CORE-KIT-SM2.TXT`); its table is the same at OSD CPU Speed
    33 MHz (`docs/probes/core/KIT2-CORE-SM2-CPU33.TXT`). At Star Cruiser's distances the machine runs
    the OLD immediate at most alignments, the core the NEW at all. **Done when:** z486 reproduces the
    machine's tables in the fork (the disp+imm clock at least) or the owner accepts the difference.

193. **Metajo SP from its own FreeDOS(98) hard-disk image stops after the R-FORCE logo.**
    **WORK.** Booted from the image it ships on, the game shows the R-FORCE logo and then a black
    screen with a text cursor, before and after the INT5 junction fix; NP2kai reaches the title
    menu with the same image. A `--dbg-cpu` capture puts the CPU from about 80 s in the vendor
    shell's own stop loop (`jmp $` after a call with 0x7F, 0), so the shell failed to start the
    menu program; NP2kai loads it and streams PC-9801-86 PCM data at that point, where the core
    takes IRQ0 at about 14 kHz. The same game's files run from an NEC MS-DOS 6.20 boot
    (`docs/user/compatibility.md`). **Done when:** the step the shell fails is found (its DOS calls
    against NP2kai's) and either fixed with a bench or shown not to be a core bug.

150. **Sync `sys/` with Template_MiSTer.** **NEEDS RE-VERIFICATION.** `sys/` is now a verbatim
    copy of upstream 76dd8f5 (2026-10-28; was 3ea1134, 2026-08-26): 6 files, +72/-16. It brings
    afd7808 (registered analog/I2S audio outputs and a debounced I/O-board mode bit, against
    glitches on the 3.5 mm output), 9c8eadb (five `LFB_*` emu inputs, now declared unused in
    `module emu`), 5dda373 (YC timing; the core sets `MISTER_DISABLE_YC`) and 76dd8f5 (force
    feedback; FFB stays 0 and the six `joystick_N_ffb` inputs are tied to 0). The static checks
    and an analysis-and-synthesis compile pass on it. A `sys/` change moves `pll_hdmi` placement,
    so what remains is hardware-side: the 6-seed sweep with the `pll_hdmi` floor and the SDRAM
    I/O gate, the 10-load screen, the scripted regression, and an ear check of the 3.5 mm output
    on a card with an I/O board. **Done when:** those pass on the synced tree.

210. **XE10Z on the current core.** **WORK.** The Xe10's XE10Z capture
    (`docs/probes/XE10Z-XE10.TXT`) was compared only with a core run that predates the fixes it led
    to (`docs/probes/core/XE10Z-CORE-rs-8b71a248-s6.TXT`): the 0x841E store, READ NATIVE MAX, the
    MPU clock-to-host dither, the calendar TIME SET folds, the port 0x29 DMA bounds and the z486 SAL
    re-vendor were each checked only by a bench. **Done when:** the same XE10Z.COM (sha256 bf45714c)
    runs on a build of the current tree, the capture is committed under `docs/probes/core/`, and
    `xe10z_decode.py` reports no difference from the Xe10's run except the rows items 200 and 201
    hold open (any other row becomes its own item).

218. **A CD title freezes on its first intro text.** **NEEDS RE-VERIFICATION.** Star Cruiser 2 (boot
    floppy + CD, `docs/user/compatibility.md`) stops on its first intro text with no CD audio and no
    response to keys or clicks; the fade-in is caught at a different point each run, unchanged
    across builds and at 25 MHz, so the wait is more likely an interrupt, CD command or timer than
    CPU speed. Whether NP2kai passes the same point with the same images is not recorded. **Done
    when:** a `--dbg-cpu` capture names the loop the game spins in and what it waits for, the same
    images run in NP2kai, and the cause is fixed with a reference-backed bench or the row is
    reclassified with the NP2kai result.

219. **Three titles take no input at their first menu.** **NEEDS RE-VERIFICATION.** Mega lo Mania,
    Might and Magic V and Olivia's Mystery (`docs/user/compatibility.md`, partial) never register
    the first menu choice: a button or key edge that never reaches the game, which could be one
    mouse-button or keyboard read-back defect; none was run in NP2kai with the same image and input.
    **Done when:** each runs in NP2kai with the same image and input and the result is in its row; a
    title that passes there gets a port trace of the mouse or keyboard read-back at the stuck point
    and a fail-first bench, otherwise its row says it is not a core bug.

220. **Partial titles from the hard-disk smoke run not in the compatibility list.** **NEEDS
    RE-VERIFICATION.** The hard-disk smoke run left four partial titles that
    `docs/user/compatibility.md` does not list: Atelier OZ (an empty menu box), and A Ressha de Ikou
    III HD, The Atlas HD and Big Honour (a garbled first line, then 'not enough memory' or a return
    to the prompt; the retry with HIMEM and DOS=HIGH has no recorded result). **Done when:** each is
    re-run on a card (the three with HIMEM and DOS=HIGH) and in NP2kai with the same image, each
    gets a compatibility row, and a core divergence found gets its own item.

221. **31 kHz on an analog VGA monitor.** **NEEDS RE-VERIFICATION.** `docs/user/troubleshooting.md`
    says the 31 kHz mode has not been checked on an analog VGA monitor; the regression and capture
    checks use HDMI only. **Done when:** a card with a VGA monitor (or a scan converter that reports
    the sync rates) shows the native 24 kHz and 31 kHz pictures and the doubled one stable at the
    expected line rates, with a screenshot kept, and the Known issues sentence is removed or
    narrowed to what failed.

222. **The Japanese-keyboard Known issue and the Main_MiSTer release.** **NEEDS RE-VERIFICATION.**
    `docs/user/troubleshooting.md` says the Japanese keyboard's ろ key arrives as カナ in MiSTer
    release 20261010 and is fixed in the next Main_MiSTer release; no check against a newer release
    is recorded. **Done when:** the key is checked on a card running the current Main_MiSTer release
    and the line names the first fixed release (or is deleted).

223. **The release game sample as a tracked list.** **WORK.** AGENTS.md's release checklist and
    `docs/mister-testing.md` "Game test sets" define the sample's categories but no title list, and
    the lists used so far are untracked build files, so a new release cannot reproduce or compare
    the previous sample's coverage. **Done when:** a tracked file lists the sample's titles by
    category (with the setup each needs, no image paths), `docs/mister-testing.md` refers to it, and
    a check confirms every listed title is in `docs/user/compatibility.md`.

226. **Tool leftovers: quartus_gui, wait_build, the MPU decoder.** **WORK.**
    `tools/quartus_gui.sh`'s header says it plants an X resource database (Xft.dpi), but the script
    has no such code; `tools/wait_build.py` turns a status record with no `log` key into `Path('')`
    and crashes instead of reporting the failed build; and `tools/hwprobe/mputest/mputest_decode.py`
    starts a message on a data byte that arrives with no running status, unchecked against NP2kai
    `mpu98ii.c`. **Done when:** the quartus_gui header matches the script (or the script plants the
    database), wait_build reports a record without a log (selftest plant), and the MPU decoder's
    no-running-status data byte follows NP2kai or is flagged as an orphan, with a `--selftest` case.

239. **The throttle tiers' runtime runs in the gates.** **WORK.** `tests/pc9821/run_throttle.sh`
    (the OSD CPU Speed throttle through the real z486) and `run_dma_snoop_throttle.sh` (DMA writes
    accepted inside a gated CPU run still invalidate cached lines) are outside `tools/bench.py
    --all`, and AGENTS.md's gates only compile them (`run_integrated_build.sh`), so a change to
    `cpu_clk`, the bus bridge's snoop hold, the DMAC or the iobus can pass every gate and break CPU
    Speed or leave a stale L1 line. **Done when:** AGENTS.md and `docs/testing.md` list both runs as
    gates for such changes (with the memory and no-overlap rules), a release-candidate run of both
    is recorded, and each has at least two recorded mutants in `tests/pc9821/mutations.json`.

240. **Benches and RTL files with no recorded mutant.** **WORK.** `tests/pc9821/mutations.json`
    holds no mutant for about 75 of the 403 benches, among them guest-visible race and reset benches
    (the kbd reset/race, ata srst/abort/irq-hold, grcg, gvram coherence and contention,
    nmi_accept_race and iowait_release families), and none at all for four RTL files
    (`pc9821_gvram_share.sv`, `sdram_sync_bridge.sv`, `pc9821_wdg_trigger.sv`,
    `pc9821_hps_slot_demux.sv`); the record has no survived or excused status, so nothing shows a
    vacuous bench. **Done when:** each such bench that asserts a guest-visible value or a race has a
    killed mutant against its own claim (or an entry in a short, shrink-only "cannot be mutated
    because" ledger that a check enforces), the four RTL files each have a killing entry, and
    `mutate_bench.py --plan ... --check-plan` passes; whether `tools/check_tests.py` enforces the
    ledger is decided with it.
242. **The census clock proc in a real Quartus STA session.** **NEEDS RE-VERIFICATION.**
    `tools/timing/census.tcl` now fetches clk_sys through a proc (`pc9821_sys_clock`) that
    `sdc_audit.tcl` also calls; it was parsed with tclsh but not run in a Quartus STA session, and
    the census's own call sits outside the catch around `sdc_audit.tcl`, so a Quartus-specific
    failure loses the census output and leaves the deploy's exception counts unjudged. **Done
    when:** a real fit's post-STA run (or a `quartus_sta` session on a fitted database) executes it,
    `output_files/census/exceptions.txt` carries the same clk_sys endpoint and exception counts as
    before on the same fit, and `check_sdc_exceptions --fit` judges it without an error row.

259. **The keyboard's IRQ1 re-poke dip through the real PIC.** **NEEDS RE-VERIFICATION.** While a
    delivered byte is unread, `pc9821_kbd.sv` drops its IRQ for one clk_sys every tick. The master
    PIC withdraws IRQ1 on a fall (`WD_UNMASKED` bit 1) with no `WD_FILTER` bit, so the dip may clear
    the pending request for one cycle before the rise re-sets it; the slave's IR4 bubble was given
    `WD_FILTER` for this reason. `tb_pc9821_kbd_single_service` and `tb_pc9821_kbd_repoke` use a
    private latch model and `tb_pc9821_irq_withdraw` drives IRQ1 by hand, so no bench runs the two
    together. **Done when:** an integrated kbd + PIC bench holds IF off across several ticks with a
    byte unread and sweeps INTA across the dip cycle, expecting only the keyboard vector; if it
    fails, IRQ1's withdraw is filtered with that bench as the fail-first proof.

267. **CRTC state when cpu_run falls and rises within one frame.** **NEEDS RE-VERIFICATION.**
    `pc9821_raster_reseed.sv` holds the CRTC with `cpu_run_crtc = run_r || crtc_hold`. If cpu_run
    falls and a new rise reaches the frame end before the held CRTC's own, both terms hand over on
    the same edge, `cpu_run_crtc` never falls, and the previous guest's CRTC registers carry into
    the new run. `tb_pc9821_raster_run_fall` has no such case. **Done when:** a bench case with a
    fall and rise inside one frame states the expected CRTC state, and the RTL passes it (a
    dedicated clear if it fails first).

268. **IRQ12: back-to-back bubbles against WD_FILTER.** **NEEDS RE-VERIFICATION.** `WD_FILTER`
    withdraws once the line has been low for two cycles (`ir_fall_held = ~ir_in & ~ir_prev &
    ir_prev2`). If the OPNA and the 86-PCM raise hidden events on consecutive cycles in
    `pc9821_irq_share`, or pcm86's own `irq_bubble` meets the share's bubble, the shared line is low
    for two cycles, the pending IRQ12 is withdrawn and re-set, and the spurious-interrupt window
    reopens. `tb_pc9821_irq_share_race` raises one bubble per run. **Done when:** the two producers
    are shown unable to emit adjacent hidden events, or a bench with adjacent events fails first
    and the filter or the share is changed to cover it.

269. **Two request-path cones no fit has timed.** **NEEDS RE-VERIFICATION.** The per-lane write
    hold put `device_wr_wait` in front of the `lane_advance -> lane_nx -> port decode -> sel_q`
    cone of `pc9821_iobus.sv` (a path that once missed setup by 2-4.8 ns), and the packed scan's
    burst count and address in `pc9821_pegc_scan.sv` now pass a 17-bit add and a 4-bit mux on the
    port-3 SDRAM request. **Done when:** the release seed sweep's path census
    (`tools/timing/`) reports both cones with positive slack on the chosen seed, or the tight one is
    registered (a "wait seen" flag; `wrap_cut`/`burst_len` latched at the line restart) without
    adding guest-visible latency.

272. **PIC OCW2: the rotate-in-auto-EOI command with nonzero L bits.** **WORK** (after the
    release). `pc9821_pic.sv` sets or clears rotate-on-AEOI only when `din[6:0] == 7'd0`, so an
    OCW2 of 0x07 (R = 0, SL = 0, EOI = 0, L = 7) leaves the mode set. The 8259A data sheet and QEMU
    (`hw/intc/i8259.c`, `cmd = val >> 5`) ignore L when SL and EOI are clear. Low value: the ITF
    does not use auto-EOI (ICW4 0x1D/0x09). The 0x80 rotate itself is item 244. **Done when:** the
    decode tests `din[6:5] == 2'b00`, a `tb_pc9821_pic_ref` case with L != 0 (0x07 clears the mode,
    0x87 sets it) fails before and passes after, and a mutation entry restores the old test.

273. **`tb_pc9821_cg_window`: the reset-persistence check and two unconnected inputs.** **WORK.**
    Section 3c asserts that user-CG RAM persists across a machine reset, which the shipped CG
    re-seed (`cfg_seed_en`) contradicts, and the bench leaves `cfg_seed_en` and `cfg_ram_mib`
    unconnected. **Done when:** the bench connects both inputs, section 3c asserts what the re-seed
    does (or is removed with the reason), and a mutant on the re-seed is killed.

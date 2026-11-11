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
    that reads DX after a reset can see. **Decision:** whether to set the z486 parameter
    `RESET_CACHE_DISABLED` (0 today), whether the core carries the FPU, and which reset signature
    it reports. **Done when:** all three are decided on this data.

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
    themselves copied from (many may predate the port) and confirm theirs. **Done when:** every
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
    machine's rate (1400 or 1401 ns), figure parity, or unpaced (today). Test it against Rusty's
    C-Lab logo intro, which runs fast at full CPU speed and is right at 16 MHz
    (`docs/user/compatibility.md`), with a build pacing both (`--gdc-write-pace 1401 --gdc-fig-pace
    1401`) and one pacing WRITE alone. **A/B recorded (2026-11-09, one card, CPU Speed Full):**
    neither build changes the intro: the logo's sine wipe takes 0.35 s (both paced) and 0.33 s
    (WRITE paced) against 0.33 s unpaced, the whole logo 5.15 s in all three, and the voice is the
    same length. The wipe draws through the GRCG with the CPU, not with GDC commands (the
    machine's own timing of it is `tools/hwprobe/rwipe`), so Rusty does not choose this default.
    **Done when:** the pacing is chosen.

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
    **Done when:** each outlier is explained against the 486's documented clocks and either fixed
    in the fork (re-vendored per AGENTS.md) or recorded as a trade.

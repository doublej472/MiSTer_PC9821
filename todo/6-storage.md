# 6. Storage: IDE/ATA, FDC, CD-ROM

21. **`0x0433`: bank 1's interrupt bit.** **CAPTURE-PENDING.** The core answers 0x0433 as the
    per-bank interrupt-pending port: bit 0 bank 0's INTRQ, as `docs/probes/KIT1-XE10-IDE1.TXT`
    measures it (`00` with every bank written, `01` while a CHECK POWER MODE completion pends on
    bank 0, `00` after the status read; `tb_pc9821_readback_ata`), and bit 1 bank 1's whichever bank
    is selected, each gated by its nIEN, which is qemu-pc98's `irq_levels` form. The nIEN half
    matches the machine: with nIEN set on bank 0 the CHECK POWER MODE completion leaves 0x0433 at
    `00` (`docs/probes/KIT2-XE10-IDE2.TXT:26`, `433/433@00` `00 00`, the command ran: count `FF`).
    Bank 1 is still unmeasured: XE10CFG `/IDE2`'s bank-1 row issued no command, because bank 1's
    status read showed no DRDY (`ran=0`, `KIT2-XE10-IDE2.TXT:24`), so the Xe10 as measured has no
    ready device there. **Done when:** the IRQ433 row runs with a device on bank 1 (0x0433 read with
    0x0432 = 01 and = 00 while it pends) and the RTL follows it; and Windows 95's ATA driver, which
    reads the port, is re-checked on a card.

27. **IDE bank-select `0x0432`: what the measured rows leave open.** **CAPTURE-PENDING.** The core
    reads 0x0432 back as the two kits measured: 00/01/02/03/2A/80 -> 00/01/00/01/22/00
    (`docs/probes/KIT1-XE10-IDE1.TXT`), 04/06/07/10/20/22/23/40 -> 00/00/01/10/20/22/23/FF
    (`docs/probes/KIT2-XE10-IDE2.TXT:4-18`; bit 6 set reads FF), and with bit 2 set the task file
    0x0642-0x064E, 0x074C and 0x074E reads that read-back byte (`pc9821_ata.sv` `tf_b2_echo`,
    `pc9821_atapi.sv` steps aside; `tb_pc9821_readback_ata`). NEC's NECCDD.SYS writes 07 and reads
    0x0432 only, then writes 01 before its first task-file access (its file offsets 0x2007-0x201A;
    `tb_pc9821_atapi` C10 follows it). Still open: (a) whether a write, the 0x064E acknowledge or
    the data port 0x0640/0x0641 and 0x0740-0x074A reach the device in the bit-2 state (they keep
    the bank-0/1 window; kit 2's CHECK POWER MODE there did not run, `ran=0`,
    `KIT2-XE10-IDE2.TXT:20,22`); (b) the bank 02/03 task file (status 00/04, 0x074E 00/04, kit 1),
    not modelled; (c) `23` read bank 0's registers (sector 04, cylinder 05, drive/head A1) although
    bit 0 is set, so whether bit 1 + bit 5 select bank 0 or that machine's bank 1 answered alike is
    unknown (a row with 21 and 23 and a distinct device on each bank settles it); and the core's
    0x074E with the slave selected reads `0F` (kit 1). **Done when:** those rows are captured and
    followed, and NECCDD.SYS still finds the CD-ROM on a card after this change.

59. **FDC: an empty powered drive's status bytes.** **CAPTURE-PENDING.** The 2026-11-07 kit ran
    with both drives powered (`docs/probes/XE10T-XE10-FDC2A.TXT`, `-FDC2B.TXT`, `-FDC2C.TXT`,
    `docs/probes/KIT1-XE10-FDMODE.TXT`, `-FDMODE1.TXT`): `[0x55C] = 03`, 0x94 reads 44, 0xC8 and
    0xCC read FF, as on the core. The empty drive differs: RECALIBRATE ends with `ST0 = 68|u`
    (IC = 01, SE, NR) where the core and NP2kai give `28|u`, and SENSE DRIVE STATUS answers ST3
    `59` for an empty drive 1 (WP set) but `18` for an empty drive 0 (-FDC2B.TXT, -FDC2C.TXT
    `UNIT da=90 cls=E st3=18`), where the core gives `19|u`: the WP bit of an empty drive is
    the drive's own, not one rule. Kit 2 dumped the BIOS's per-unit table after a cold boot with
    both drives empty (`docs/probes/KIT2-XE10-FD0.TXT:2`): `[0x55C] = 03` and the first byte of each
    8-byte entry at 0x0564/0x056C/0x0574/0x057C is `C8 E9 CA CB` (IC = 11 on every unit; NR on all
    four; SE on unit 1 only), where the core's run of the same kit stores `E0 E9 F2 F3`
    (`docs/probes/core/KIT2-CORE-KIT-FD0.TXT:2`, before the fdc lane's not-ready changes). So the
    stored bytes all have IC set and the drives still count as present: the BIOS POST's
    `test byte [0x564+unit*8],0xC0` (BANK7@0x7716) is not the presence test these bytes reach, or
    the table is rewritten after it. It is rewritten: the BIOS's IRQ11 handler (BANK7@0x7B10-0x7B58)
    drains SENSE INTERRUPT STATUS until 80 and stores each result's ST0 and PCN at 0x564 + 8 x unit,
    skipping an IC-bit-7 result only while the unit's bit stands in [0x55E] (a normal completion
    sets it); the POST's presence test reads the table (BANK7@0x770E-0x7728, `test byte [bx],0xC0`
    -> `or [0x55C],al`) and then clears [0x55E]'s low nibble and writes 0x94 <- 18 (BANK7@0x772A),
    so the cold-boot dump holds the LAST IC = 1x status per unit after the POST - C8 = AI|NR|0,
    E9 = AI|SE|NR|1, CA, CB - which is not what the presence test saw. Which later event (a ready
    poll after the 18, or a RECALIBRATE ended by a reset) leaves SE on unit 1 only is not known,
    and the core's capture predates the fdc lane's not-ready changes, so the current core's bytes
    are unmeasured. Not modelled until the POST's own RECALIBRATE answer is known.
    **Done when:** the same dump is taken with a disk in drive 0 (kit 2's optional `OPTFD` step,
    not run) and with the slave IRR and 0x55E read right after the POST's 0x94 <- 18, the core's
    run of the current tree is compared with both, and `pc9821_fdc.sv`
    answers RECALIBRATE and ST3 as captured with a fail-first bench (`tb_pc9821_fdc_conform`).

66. **In-game disk-load latency (Touhou 5 dialogue loads).** **CAPTURE-PENDING.** A dialogue
    load waits seconds on the core, but the FPGA path is not the cause: `tb_pc9821_ata_th5load`
    prices one 21-sector face change at ~79 k clk_sys (HPS model lat=4600), well under the
    machine's 143 us/sector (`docs/probes/IDELAT-clean.TXT`), and the IDE ROM's standby settle is
    off: `[0x59A]` reads `00` on the machine (`docs/probes/KIT1-XE10-CFG0.TXT`, `MEM 059A`) and on
    the core (`docs/probes/core/KIT1-CORE-rc-e6db0f05-s3-CFG0.TXT`). The suspects are the HPS
    round trip per handshake on the real card and the guest's CPU/I/O cost per `insw`.
    **Done when:** `idelat` on the core is compared with `docs/probes/IDELAT-clean.TXT` and the
    time of one dialogue load is split on the core with the `trace` profile.

106. **CD-ROM: what works and what is unverified.** **UNVERIFIED (INFERRED) for NECCDM/NECCDD.**
    ATAPI on bank 1's master, the hard disk always bank 0's (fixed layout; the
    stock Xe10's and NP2kai's, `tb_pc9821_ide_layout`); answers follow NP2kai `ideio.c`/`atapicmd.c`
    (`tb_pc9821_atapi`). Hardware-verified: `NECCD.SYS`, `NECCDD.SYS` and `NECCDM.SYS` + MSCDEX read
    data and play CD-DA (2026-10-20, capture card: the played track matches the disc, pitch ratio
    1.000, speed exact, no clipping; `tools/av_cdda_match.py`). Open: `PATACD.SYS` rejects some
    IOCTLs, the CD-DA level against a real drive, no CD boot. The level is a user control in the
    meantime: the OSD Audio page's "CD audio" field (status[66:64], -12..0 dB or Off), defaulting to
    0 dB (the owner's choice, 2026-10-31: unity, the level shipped before the field existed; the
    clipping that had prompted -6 dB was the output FIR's wrong-rail clamp,
    `tb_pc9821_audio_out_sat`, not a level problem). NP2kai's default CD-DA level, davolume 128
    of 255 (`sdl/ini.c:704`, -6 dB), stays a reference step of the list. **Done when:** the
    level is captured against a real drive on the same capture chain (the capture sets which
    step the field's default should be).

163. **FDC timing is not tied to the disk's rotation.** **WORK.** The core's seek,
    READ ID and READ DATA finish in microseconds. XE10T `/FDC` (DA 0x91, 2HD, N=3), machine vs core:
    - SEEK 0->40: 164.8 ms (about 4.1 ms a step) vs 172 us.
    - READ ID spacing: 19.26 ms vs 537 us. On the machine that is one sector pitch, and 8 IDs
      take 166.9 ms, one 360 rpm turn.
    - One-sector READ DATA, completion to completion: 166.73 ms (one turn) vs 1.07 ms.
    - 8-sector READ DATA: 281.6 ms vs 5.24 ms.

    Sources: `docs/probes/XE10T-XE10-FDC.TXT` and the core's capture of the same binary. Only the
    missing-sector search (`X_NDW`) uses the spindle (`spin`). READ ID's order on the core is not
    tied to the head's angle. A faster storage path is allowed, but a loader or protection that
    times a turn, or counts READ IDs per turn, sees about 1 ms instead of 166.7 ms. The real
    timing would be a large guest-visible latency increase, more than the storage exemption's
    "small". Owner (2026-11-01): no preference on speed; rotation timing may matter to some
    titles' copy protection. So the fast path stays, and a copy-protected floppy title that
    fails its check is first tested against this item (does the check time a turn, count READ
    IDs per turn, or read a sector position?). Zavas's protected Program disk passes today.
    **Done when:** such a title is found and the rotation model (SPECIFY's SRT step rate, sector
    position against `spin`, the per-sector time) is built for it with a bench on the XE10T
    rows, or the floppy titles in `docs/user/compatibility.md` are all checked with none affected,
    when this becomes a known issue (`docs/user/troubleshooting.md`).

171. **CD-DA ring depth against slow SD-card reads.** **WORK.**
    The owner reports that a microSD read can take nearly half a second in the worst cases, and the
    CD-DA ring has to ride that out (it is why trade T79, a smaller ring, was rejected). The current
    6144-word ring covers about 10.4 sectors of CD-DA before it runs dry under a stalled reader,
    about 139 ms at 75 sectors per second, well short of half a second. Not established: whether a
    stall that long reaches the ring (the framework's own read path may buffer ahead), and what a
    guest hears when the ring runs dry. **Done when:** the worst-case stall the ring sees has been
    measured on a card with a slow microSD (a CD-DA underrun counter on the debug UART, or a
    recorded dropout); and either the ring covers it, or a deeper ring (about 0.5 s is ~38 sectors,
    roughly 3.6 times today's M10K cost) is raised as a trade with its fit numbers.

178. **Floppy copy-protection fidelity.** **WORK.** Not modelled today: ST2 is always 0 (no
    deleted-data marks, no CM/SK, no CRC errors DE/DD), READ DELETED DATA and READ TRACK act as
    READ DATA, and the media seam carries no per-sector status (MAME takes it from the D88 sector
    header, `d88_dsk.cpp`; NP2kai drops it); READ ID returns the track register and head as C/H,
    not the ID field (NP2kai's behaviour; MAME and the chip return the ID field); the 100 ms VFO
    timer (TTRG/TMSK) is absent (MAME notes Sorcerian and Hydlide expect it); the D88 sector
    search is not bounded by the next track's offset (NP2kai `fdd_d88.c` is), so an empty track
    answers READ ID with the next track's ID. **Done when:** each is modelled against its
    reference with a fail-first bench, or recorded in the known issues (`docs/user/troubleshooting.md`).

179. **Floppy media and interface details.** **WORK.** 2D D88 images (fd_type 0x00) mount but
    read only cylinder 0 (NP2kai's double-step fold, `fdd_d88.c`, is not modelled); a write to
    port 0x00BF changes the interface strap (NP2kai, MAME and qemu-pc98 decode 0x00BE only); 2DD
    media on the 1M interface are timed at 360 rpm, not 300 (MAME `fdc_set_density_mode`); the
    fd_type 0x30 tolerance reads only at rpm 0, never at the rpm 1 a 1.44 MB disk needs;
    `tools/fdconv.py` converts 2D FDIs no reader accepts, refuses mixed 1.2/1.44 MB NFDs a 0x21
    D88 can hold, writes tracks of more than 40 sectors silently, drops the write-protect flag on
    raw output without a message, and skips odd `.fdd` files silently in batch mode. The
    compatibility row whose reason is that a 3.5-inch drive cannot read a 77-cylinder 15x512 2HD
    disk needs a run in NP2kai before that wording stays. **Done when:** each is fixed with a
    bench or selftest case, or recorded as a limitation.

190. **FDC VFO timer: the held masked expiry on a card.** **NEEDS RE-VERIFICATION.** The VFO
    one-shot now holds an expiry that happens while 0x94 TMSK is clear and shows it when TMSK is set
    again, as the machine does (`docs/probes/KIT2-XE10-FD0.TXT:4`, `irr200ms/irr0C ... 90 98 ...
    rise=00000003`; `pc9821_fdc.sv` `vfo_out`, `tb_pc9821_fdc_vfo` V5); only a trigger clears it.
    Windows 95's HSFLOP.PDR should not see the difference: in both of its --dbg-fdc captures (the
    w95fd lane's, 236 and 5441 writes to 0x94) every write that sets TMSK without a trigger comes
    within 1 ms of a trigger write, so no held expiry is ever shown. **Done when:** Windows 95's B:
    drive and a DOS floppy boot pass on a card with the change.


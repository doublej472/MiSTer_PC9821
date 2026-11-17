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

66. **In-game disk-load latency (Touhou 5 dialogue loads).** **CAPTURE-PENDING.** A dialogue load
    waits seconds on the core, but the FPGA path is not the cause: `tb_pc9821_ata_th5load` prices
    one 21-sector face change at about 94,500 clk_sys, about 1.9 ms (HPS model lat=4600, 9 clk per
    word as `io_latency_profile` measures), well under the machine's 143 us/sector
    (`docs/probes/IDELAT-clean.TXT`), and the IDE ROM's standby settle is off: `[0x59A]` reads `00`
    on the machine (`docs/probes/KIT1-XE10-CFG0.TXT`, `MEM 059A`) and on the core
    (`docs/probes/core/KIT1-CORE-rc-e6db0f05-s3-CFG0.TXT`). The suspects are the HPS round trip per
    handshake on the real card and the guest's CPU/I/O cost per `insw`. **Done when:** `idelat` on
    the core is compared with `docs/probes/IDELAT-clean.TXT` and the time of one dialogue load is
    split on the core with the `trace` profile.

106. **CD-ROM: what works and what is unverified.** **CAPTURE-PENDING.**
    ATAPI on bank 1's master, the hard disk always bank 0's (fixed layout; the
    stock Xe10's and NP2kai's, `tb_pc9821_ide_layout`); answers follow NP2kai `ideio.c`/`atapicmd.c`
    (`tb_pc9821_atapi`). Hardware-verified: `NECCD.SYS`, `NECCDD.SYS` and `NECCDM.SYS` + MSCDEX read
    data and play CD-DA (2026-10-20, capture card: the played track matches the disc, pitch ratio
    1.000, speed exact, no clipping; `tools/av_cdda_match.py`). Open: `PATACD.SYS` rejects some
    direct driver calls (IOCTLs; it reads files and plays CD-DA), the CD-DA level against a real
    drive, and booting from the CD itself (titles that boot from their own CD boot floppy work);
    and the drive's answer to the first TEST UNIT READYs after power-up, which the Xe10 capture
    gives as UNIT ATTENTION 06/29/00 then 06/28/00 (`docs/probes/XE10T-XE10-CD.TXT`), is held as
    a waived divergence in `tb_pc9821_atapi_xe10_tur` because that capture's drive is suspected
    faulty. The level is a user control in the
    meantime: the OSD Audio page's "CD audio" field (status[66:64], -12..0 dB or Off), defaulting to
    0 dB (the owner's choice, 2026-10-31: unity, the level shipped before the field existed; the
    clipping that had prompted -6 dB was the output FIR's wrong-rail clamp,
    `tb_pc9821_audio_out_sat`, not a level problem). NP2kai's default CD-DA level, davolume 128
    of 255 (`sdl/ini.c:704`, -6 dB), stays a reference step of the list. **Done when:** the
    level is captured against a real drive on the same capture chain (the capture sets which
    step the field's default should be), and XE10T `/CD` is captured with a known-good drive and
    the bench's WAIVED lines become assertions of what it reads (or the divergence is confirmed).

163. **FDC timing is not tied to the disk's rotation.** **WORK.** The core's seek and
    READ DATA finish in microseconds. XE10T `/FDC` (DA 0x91, 2HD, N=3), machine vs core:
    - SEEK 0->40: 164.8 ms (about 4.1 ms a step) vs 172 us.
    - READ ID spacing: 19.26 ms on the machine, one sector pitch (8 IDs take 166.9 ms, one 360
      rpm turn). The core now matches it: READ ID answers one sector period later (`X_IDW`,
      `tb_pc9821_fdc_readid_wait`), so this row is closed.
    - One-sector READ DATA, completion to completion: 166.73 ms (one turn) vs 1.07 ms.
    - 8-sector READ DATA: 281.6 ms vs 5.24 ms.

    Sources: `docs/probes/XE10T-XE10-FDC.TXT` and the core's capture of the same binary. Only the
    missing-sector search (`X_NDW`) and READ ID's sector-period wait (`X_IDW`) use the spindle
    (`spin`); the angle at which an isolated command starts is not modelled. A faster storage path is allowed, but a loader or protection that
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
    not the ID field (NP2kai's behaviour; MAME and the chip return the ID field); the D88 sector
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
    raw output without a message, and skips odd `.fdd` files silently in batch mode. (The
    77-cylinder 15x512 2HD title that stays black on the core is item 203.) **Done when:** each is fixed with a
    bench or selftest case, or recorded as a limitation.

190. **FDC VFO timer: the held masked expiry on a card.** **NEEDS RE-VERIFICATION.** The VFO
    one-shot now holds an expiry that happens while 0x94 TMSK is clear and shows it when TMSK is set
    again, as the machine does (`docs/probes/KIT2-XE10-FD0.TXT:4`, `irr200ms/irr0C ... 90 98 ...
    rise=00000003`; `pc9821_fdc.sv` `vfo_out`, `tb_pc9821_fdc_vfo` V5); only a trigger clears it.
    Windows 95's HSFLOP.PDR should not see the difference: in both of its --dbg-fdc captures (the
    w95fd lane's, 236 and 5441 writes to 0x94) every write that sets TMSK without a trigger comes
    within 1 ms of a trigger write, so no held expiry is ever shown. **Done when:** Windows 95's B:
    drive and a DOS floppy boot pass on a card with the change.

203. **A 77-cylinder 15x512 2HD floppy title stays black on the core.** **NEEDS RE-VERIFICATION.**
    Solitaire Royale (`docs/user/compatibility.md`, also from its NFD dump converted to D88) stays
    black on the core, where NP2kai with the same Xe10 firmware reaches the title; NP2kai boots
    floppies through its own boot code, so whether the real Xe10 boots this disk is not known, and
    where the core's IPL path stops (READ ID, the media-mode check, the 15-sector geometry) has not
    been traced. **Done when:** a `--dbg-cpu` or FDC trace names the first step at which the core
    and NP2kai differ for this disk, and it is fixed with a fail-first bench from NP2kai's
    behaviour, or a real-Xe10 boot of the disk shows the machine fails too and the row says so.

212. **ATAPI MODE SELECT with no data-out phase.** **UNVERIFIED (INFERRED).** `pc9821_atapi.sv`
    completes MODE SELECT(10) (0x55) at once, without its parameter list (NP2kai's workaround), and
    leaves MODE SELECT(6) (0x15) unhandled; a real drive enters a DATA-OUT phase for a non-zero list
    length, and the audio control page (0x0E) it carries is never applied. No bench exercises either
    opcode. **Done when:** what NECCD/NECCDD/PATACD send (CDB, PF bit, list length) is captured in a
    CD session on the core, and either a DATA-OUT phase that consumes the list (and stores page
    0x0E) is implemented with a fail-first bench in `tb_pc9821_atapi`, or the limitation is recorded
    in the known issues with those drivers shown not to depend on it.

213. **FORMAT on a D88 floppy image.** **WORK.** MS-DOS FORMAT of a blank D88 image fails, while a
    raw `.hdm` formats (`docs/user/troubleshooting.md` Known issues); NP2kai's `fdd_d88.c` rebuilds
    the track from FORMAT TRACK's ID list. **Done when:** a fail-first bench rebuilds a D88 track
    from a FORMAT TRACK command (ID list, gap, fill byte) with expected values from NP2kai
    `fdd_d88.c`, MS-DOS FORMAT on a blank D88 completes on a card and the Known issues line is
    removed, or the owner records D88 FORMAT as not supported and this item is closed.

214. **ATA aborted commands: the status of a generic unsupported command.** **CAPTURE-PENDING.** The
    captured aborts are modelled: IDENTIFY PACKET (A1) to the hard disk and READ NATIVE MAX (F8)
    answer ERROR 04, STATUS 0x51 and rewrite Sector Count and Sector Number to 01/01 with the
    cylinder and drive/head kept (`docs/probes/XE10Y-XE10-K3M.TXT:43`,
    `docs/probes/XE10Z-XE10.TXT:218-219`), and IDENTIFY DEVICE reads SC 00 at DRQ and FF after the
    block (K3M:42); `tb_pc9821_ata_conform`, `tb_pc9821_ata_identify`. Every other unsupported
    command still aborts with NP2kai's 0x41 and leaves the task file. For F8 only the Sector Count
    rewrite is measured: `tools/hwprobe/xe10z/xe10z.s` does not preload SN before F8, so the
    captured SN 01 may be the BIOS's value, and the SN rewrite is inferred from the A1 row.
    **Done when:** an unsupported command other than A1 and F8 is captured on the Xe10's drive and
    the generic abort follows it with a fail-first bench, and an F8 row with SN preloaded to a
    distinct value settles the F8 SN rewrite (until then the F8 benches and comments call it
    inferred).

215. **ATAPI READ across a disc change: the sense.** **UNVERIFIED (INFERRED).** A mount during an
    active READ(10) ends the command with CHECK CONDITION, ILLEGAL REQUEST, ASC 0x21 after the
    buffered sector drains (`pc9821_atapi.sv` `rd_medchg`, `tb_pc9821_atapi` C30): NP2kai's answer
    only. A real MMC drive more likely reports UNIT ATTENTION 6/28 (medium may have changed) or NOT
    READY 2/3A, and a driver that decodes the sense takes a different path. **Done when:** a disc
    swap during a READ(10) data phase followed by REQUEST SENSE is captured on the Xe10's CD drive
    (a known-good one, item 106) and the RTL and C30 follow it, or NP2kai's answer is accepted after
    a CD title is checked across a disc swap on a card.

216. **A 2DD floppy title whose IPL retries forever.** **NEEDS RE-VERIFICATION.** Savior
    (`docs/user/compatibility.md`, both disks) stays black: its IPL reads 2DD 16x256 sectors and
    retries forever, unchanged after the NFD-to-D88 conversion; NP2kai is black too, so a bad dump
    or a protection check is likely, and items 178 and 179 are candidate causes. **Done when:** the
    disk is retried after item 178/179 work lands and its row updated, or a trace shows the IPL's
    retry cause (the status it rejects) and it is fixed or documented as a bad dump with that
    evidence.

217. **MGL slot indices in the user docs.** **WORK.** No user doc mentions MGL files, and this
    core's slot map is not the usual one (`tools/check_mister_layout.py`: HDD 0, FDD1 1, FDD2 2,
    HDD2 3, CD-ROM 4), so an MGL written for another core's layout, or for this core before HDD2
    existed, mounts the wrong drive. **Done when:** `docs/user/setup.md` (or `images.md`) has a
    short MGL section with the file's location, one example for the firmware pack, a hard disk and a
    CD, and the slot table, and the table is covered by the existing layout check.

245. **ATAPI READ CD (0xBE) and READ CD MSF (0xB9).** **WORK.** NP2kai implements both; the core
    aborts them (`pc9821_atapi.sv`), a divergence from the primary reference. Needed: raw 2352-byte
    sector reads (NP2kai supports them only on 2352-byte images), the data-selection field (sync,
    header, subheaders, user data, EDC/ECC; variable sizes up to 2352 bytes), audio-track detection,
    a 1176-word sector buffer instead of 1024 with per-size byte counts and DRQ handling, and MSF
    decoding for 0xB9: roughly 300-500 RTL lines plus benches. GET CONFIGURATION (0x46) keeps
    NP2kai's little-endian feature header and 512-byte reply, and READ SUB-CHANNEL its 0x12 length,
    both MMC deviations NP2kai has; no PC-98 driver in the tree issues 0x46. **Done when:** 0xBE and
    0xB9 answer as NP2kai's `atapi_cmd_readcd` does for 2048- and 2352-byte images, with benches
    from NP2kai, and a title or driver that uses them runs on a card.

262. **ATA answers taken from a spec or a reading, not the machine.** **UNVERIFIED (INFERRED).**
    (a) An absent unit 1 reads STATUS 0x00 (`tb_pc9821_ata`), from ATA-3 and the Linux/98 driver;
    no capture selects unit 1 on a single-drive channel. (b) DEVICE RESET (0x08) on the CD's bank
    leaves ERROR 0x01 (`tb_pc9821_atapi` C2); NP2kai (`cbus/ideio.c` device reset) ORs 0x80 when
    the slave is absent, giving 0x81. (c) IDENTIFY words 1 and 54 clamp the cylinder count at
    0xFFFF (`tb_pc9821_ata_idcyl`) where ATA/ATAPI-6 caps the default CHS geometry at 16383; word
    54 has NP2kai support, word 1 none. (d) On an image of 2^28 sectors or more a command that
    reads LBA 0x0FFFFFFF is refused (`tb_pc9821_ata_range`), an inference from IDENTIFY words
    60/61 that NP2kai does not make. **Done when:** a probe reads 0x064E after selecting an absent
    unit 1 and 0x0642 after DEVICE RESET on the Xe10, each of (a)-(d) is matched to the capture or
    a cited reference with a fail-first bench, and the benches' comments cite the source.

264. **ATA: the status while SRST is still held after a drained block.** **NEEDS
    RE-VERIFICATION.** SRST asserted while a block is in flight sets BSY and drains it; the drain's
    completion writes `status_reg <= device_present ? ATA_READY : 0` without testing
    `soft_reset`, so a driver still holding SRST reads 0x50 where the no-block path reads 0x00
    (`pc9821_ata.sv` X_DRAIN). No capture or reference covers the status during a held SRST.
    **Done when:** NP2kai's (or the machine's) status during a held SRST is established, and the
    drain completion follows it with a fail-first bench (or the difference is shown unreachable).

265. **ATAPI READ TOC with more than 127 tracks.** **WORK.** `toc_ent` (8 bits,
    `tracks - toc_st + 2`) wraps at 256 and the entry index and lead-out compare are 7 bits
    (`te_b == tracks[6:0]`), so a PCD whose header declares 128 or more tracks returns a wrapped
    TOC. `tools/cue2pcd.py` refuses track numbers above 99, so only a hand-made header reaches it.
    **Done when:** the PCD header's track count is clamped to 99 at parse (matching the
    converter's contract) or the widths are widened, with a bench case for a 255-track header.

274. **ATA IDENTIFY words 57-58 for an image over 128 GiB.** **WORK.** Words 60-61 (and the
    range check) use `lba28_capacity`, clamped to 0x0FFFFFFF, but words 57-58 report
    `current_capacity`, which the geometry divider loads from the unclamped `act_capacity`
    (`pc9821_ata.sv` `current_capacity  <= act_capacity - {19'd0, div_remainder_next};`), while
    word 54 clamps the cylinders to 0xFFFF. So an image of 0x20000000 sectors reports a current
    capacity of about 0x20000000 against a user-addressable count of 0x0FFFFFFF. Reads and writes
    are refused past LBA 0x0FFFFFFE, so no data is at risk; only IDENTIFY disagrees with itself.
    Changing it changes the logic (a new fit). **Done when:** NP2kai's words 57-58 for such a disk
    are read (ideio.c) and the core follows them (or the clamped `lba28_capacity`, if NP2kai gives
    no answer), with a fail-first case in `tb_pc9821_ata_identify` for a disk over 128 GiB.

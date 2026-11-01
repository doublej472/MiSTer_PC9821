# 6. Storage: IDE/ATA, FDC, CD-ROM

59. **FDC: re-capture with both drives powered.** **CAPTURE-PENDING.** An equipped but empty
    drive answers NP2kai's `SE|NR` recalibrate, so the BIOS marks both drives present
    (`[0x55C] = 0x03`, `pc9821_fdc.sv`); the Xe10 captures read `0x01`, but drive 1 was unpowered
    when they were taken. Also uncaptured: the unselected 2DD/2HD window's byte and the
    `0x94`/`0xCC` control byte (`ioprobe` has the rows). **Done when:** `0x055C` and those rows are
    captured with both drives powered (empty, then a diskette in drive 2) and
    `tb_pc9821_fdc_conform` pins them.

66. **In-game disk-load latency (Touhou 5 dialogue loads).** **CAPTURE-PENDING.** A dialogue
    load waits seconds on the core, but the FPGA path is not the cause: `tb_pc9821_ata_th5load`
    prices one 21-sector face change at ~79 k clk_sys (HPS model lat=4600), well under the
    machine's 143 us/sector (`docs/probes/IDELAT-clean.TXT`), and the IDE ROM's standby settle is
    off when `[0x59A]` is 0 (derived from the dumps, not captured). The suspects are the HPS
    round trip per handshake on the real card and the guest's CPU/I/O cost per `insw`.
    **Done when:** `idelat` on the core is compared with `docs/probes/IDELAT-clean.TXT`, `[0x59A]`
    is read on the core (expected 0) and on the machine, and the time of one dialogue load is
    split on the core with the `trace` profile.

106. **CD-ROM: what works and what is unverified.** **UNVERIFIED (INFERRED) for NECCDM/NECCDD.**
    ATAPI on bank 1's master, the hard disk always bank 0's (fixed layout; the
    stock Xe10's and NP2kai's, `tb_pc9821_ide_layout`); answers follow NP2kai `ideio.c`/`atapicmd.c`
    (`tb_pc9821_atapi`). Hardware-verified: `NECCD.SYS`, `NECCDD.SYS` and `NECCDM.SYS` + MSCDEX read
    data and play CD-DA (2026-10-20, capture card: the played track matches the disc, pitch ratio
    1.000, speed exact, no clipping; `tools/av_cdda_match.py`). Open: `PATACD.SYS` rejects some
    IOCTLs, the CD-DA level against a real drive, no CD boot. The level is a user control in the
    meantime: the OSD's "CD audio volume" field (status[66:64], -12..0 dB or Off), defaulting to
    0 dB (the owner's choice, 2026-10-31: unity, the level shipped before the field existed; the
    clipping that had prompted -6 dB was the output FIR's wrong-rail clamp,
    `tb_pc9821_audio_out_sat`, not a level problem). NP2kai's default CD-DA level, davolume 128
    of 255 (`sdl/ini.c:704`, -6 dB), stays a reference step of the list. **Done when:** the
    level is captured against a real drive on the same capture chain (the capture sets which
    step the field's default should be).

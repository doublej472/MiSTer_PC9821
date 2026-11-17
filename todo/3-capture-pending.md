# 3. Capture-pending hardware questions

A software model exists, but no machine measurement settles it, and the answer would change
what a guest observes. Each item names the measurement. Probes are in `tools/hwprobe/` (a
missing probe has to be written; run it on the core first, then on the machine).

22. **CRTC horizontal porch split.** **CAPTURE-PENDING.** The power-on raster uses the uPD7220
    field map (MAME `upd7220.cpp`; `pc9821_crtc.sv`, `tb_pc9821_gdc_sync_raster`): active 640,
    front porch 80, sync 64, back porch 64 dots. NP2kai places no porches (it only sums the fields
    into the line). Only the 848-dot total is measured (`docs/probes/KIT2-XE10-TXTMODE.TXT`).
    **Done when:** HSYNC is scoped against the active dots on the video output (or the monitor's
    picture position is photographed against the core's) and `pc9821_crtc.sv` matches the
    measured porches.

23. **GDC status bit 6 (blank): the window against the active dots.** **CAPTURE-PENDING.** Both
    GDCs (`0xA0` and `0x60`) read bit 6 high 0.24 of a line on the machine, rising at the VSYNC fall
    (`docs/probes/XE10Y-XE10-K3M.TXT`, kit 3's HBL polls); `pc9821_crtc.sv` drives it over the
    line's first HTOTAL - HACTIVE dots so it rises in the poll VSYNC falls in
    (`tb_pc9821_crtc_blank_phase`). Unmeasured: where the VSYNC edges and the bit-6 window sit
    against the picture's own active dots. **Done when:** a capture places them and
    `pc9821_crtc.sv` follows it.

24. **Game port: opposite-direction priority.** **CAPTURE-PENDING.** With up+down (or
    left+right) held, the core reports the minimum discharge (up/left wins,
    `pc9821_gameport.sv`); NP2kai `board118.c` the maximum. **Done when:** timestamped axis-bit
    polls with a real joystick, per direction, both opposite pairs and idle, decide it.

26. **GDC SCROLL partition walk past partition 2.** **UNVERIFIED (INFERRED).** The core walks
    partitions 3/4 and wraps to 1, as NP2kai `vram/makegrph.c` does. **Done when:** SCROLL
    (`0x70` via `0xA2`) is programmed with four distinct partition starts on the machine and rows
    200-399 are photographed and compared.

28. **`0x043F` read-back encoding, and the writes that freeze the machine.** **CAPTURE-PENDING.**
    The read is value-dependent (`docs/probes/EMS.TXT`: `20` -> `C4`, `80` -> `C5`, `82` -> `C7`,
    `C4` -> `CB`) but under-determined. Kit 2's sweep (`RISKY /43F`, nibbles 2, 8, E, A, C, then
    the rest) froze the machine twice: the write of `23` (`docs/probes/KIT2-XE10-RISKY-43F.TXT`,
    `ROW 43F 23` with no R43F line after it) and, resumed, the write of `26` (`ROW 43F 26`, the
    file's last line); both freezes needed a power cycle (the owner's video shows only the step
    banner). The rows taken read `20`/`21`/`24`/`25` -> `C4` and `22` -> `C5` (`KIT2-XE10-RISKY-43F.TXT:9`, `R43F 22 C5 C5`),
    each with the F8000 ROM window and the B0000 word unchanged and `C4` again after the
    put-back. The core reads `C4` for every value and never freezes
    (`docs/probes/core/KIT2-CORE-RISKY-43F.TXT`); a freeze is not something to model. **Done
    when:** the sweep resumes past `26` (skipping `23` and `26`), ideally with the 0x8x, 0xEx,
    0xAx and 0xCx values first, and the read-back is pinned by a bench.

31. **`0xE0000` answering nothing.** **CAPTURE-PENDING.** The digital half is measured and
    modelled: in the digital (8-colour) mode DOS leaves (`0x9A0` index 4 reads 0), `0xE0004`
    reads `FF` and a store there does not read back (`docs/probes/DMAROUTE-XE10.TXT` case P4,
    view V1: `ORIG=FFFFFFFF PRE=FFFFFFFF POST=FFFFFFFF`), `0xE0000` reads `FF FF FF FF` after
    `00 FF 55 AA` (`docs/probes/VRAM2.TXT`), and window 0 at `0x0E` reads `FFFF` at `0xE0000`
    (`docs/probes/WIN.TXT`); NP2kai agrees (`i386c/cpumem.c` installs `memnc` at `0xE0000` when
    `VOPBIT_ANALOG` is clear). `pc9821_memory_map` decodes the E plane only with `pc9821_crtc`'s
    `mode2_16color` set and routes the digital-mode slot to the open-bus responder
    (`e_plane_nc`), in the CPU's instance and in the DMA's (`dma_map`, so a uPD71071 byte to
    `0xE0000` in the digital mode is dropped / reads `FF`, as NP2kai's DMA through the same
    handler table does; `tb_pc9821_e_plane_mode`, `tb_pc9821_memory_map`, `tb_pc9821_dma_route`).
    The CPU half of the 16-colour mode is **captured** too (kit 3, `XE10Y /K3M` E0000,
    `docs/probes/XE10Y-XE10-K3M.TXT:27`): with 0x6A <- 01 the Xe10 reads 00000000 at 0xE0000 and
    takes AA55FF00 (a plane, as NP2kai and the core), and in the digital mode FFFFFFFF. Still
    open: only a uPD71071 DMA write to `0xE0004` in the digital mode, which no capture has (P4's
    DMA run is made in the 256-colour state, and K3M does no DMA). **Done when:** a
    DMAROUTE-style run with a disk in a drive writes `0xE0004` by DMA in the digital mode on the
    machine and the core's dropped byte is confirmed or changed with a fail-first bench.

35. **`0x989x`: bits 0-2 of the latch.** **CAPTURE-PENDING.** 0x9892 and 0x9894 each latch bit 3
    from a write whose high nibble is 0 (`docs/probes/KIT2-XE10-RISKY-989.TXT`: 08 reads F8, 55, AA
    and the put-back F0 are ignored; the POST's bit-3 branch clears it with 00, BANK4@0x4AF5;
    `pc9821_iobus.sv` `r9892_b3`/`r9894_b3`, `tb_pc9821_iobus`). Bits 0-2 read 0 always: only 00
    and 08 were taken, and the firmware's clock path writes the table's low nibble to 0x9892 and
    08-0F to 0x9894 (BANK4@0x1C75-0x1C99). A guest that writes 08 to 0x9894 sends the next POST
    through the clock branch (00, 00, 98E0 <- 05, `out 0xF0`, then a normal POST); that reboot is
    not run on the core. **Done when:** a capture of 01, 02, 04, 0F, 18 and 80 written to each
    port settles the low bits and the high-nibble rule, and a reboot after `0x9894 <- 08` is run
    on a card.

38. **OPNA ADPCM-B over the data bus: the read-back and BRDY timing.** **CAPTURE-PENDING.** The
    write half is modelled from XE10T `/OPNA2` (`docs/probes/XE10T-XE10-OPNA2.TXT`): bytes written
    through 0x108 in memory-write mode move the unit's address, EOS sets at the stop address (`i=32
    ... st=0C`), the +6 read answers the byte written (`s6=80`), and a `0x110 = 80` flag reset
    leaves BRDY clear for the next read, BRDY returning once the unit is idle (a marked LOCAL FIX,
    `src/opna/LICENSE-SCOPE.md`; `tb_pc9821_opna_adpcmb_mem`). Open: what a read returns after a
    pattern is written (whether RAM is behind ADPCM-B on the machine); the BRDY the machine kept
    through three resets right after EOS (FR_ADB i=0..2), which no reference explains; and when BRDY
    returns after a reset while idle (the core uses the second 55.5 kHz sample enable, 18-36 us,
    bounded but not measured by the capture). **Done when:** a probe writes a pattern through
    `0x108` and reads it back through `0x108`/BRDY, and polls 0x18C with PIT timestamps for about 1
    ms after a reset, on the machine and the core, and the RTL follows it with fail-first benches.

82. **Xe10 I/O timing: the EGC file's even read and the `out` side.** **CAPTURE-PENDING.** The
    owner's decision (2026-11-08) is in: the OSD's I/O timing field, Fast (the default) or Xe10, a
    runtime choice by exception to the compile-time-knob rule (`docs/policies.md`). The Xe10 table
    is the net_ns of the XE10T /IO rows (`docs/probes/XE10T-XE10.TXT`, `pc9821_iobus.sv`'s Xe10
    class table, `tb_pc9821_io_latency_profile`), less the core CPU's own 8 clk_sys per I/O
    instruction (`docs/probes/core/KIT2-CORE-SPEED.TXT`), and a 16-bit access pays one class.
    Open: (a) the EGC register file's EVEN-address read is 5989.1 ns in XE10T but 8608.5-9365.1 ns
    in `docs/probes/IO.TXT`, and its mechanism (why even addresses only) is unexplained; (b) the
    CPU share (8 clk_sys) is measured on `in al,dx`: on the card in Xe10 mode SPEED reads
    `in al,dx` 800.01 / 655.58 ns at 0x02 / 0xA0 against the machine's 802.30 / 650.77
    (`docs/probes/core/IOT-CORE-XE10-SPEED.TXT`), and XE10T's write rows land within 0-1 % of the
    machine's, but its READ rows sit 1.6-7 % (13-28 ns, 1-2.5 clk_sys at 90 MHz) above them
    (`docs/probes/core/IOT-CORE-XE10-XE10T-IO.TXT`): SPEED and XE10T price the core's `in` 1-2 clk
    apart, which neither capture explains (XE10W `/MISAL2`'s aligned word reads show the same
    +28.7 ns: `IOIW_0` 820.2 on the core against 791.5); (c) a 32-bit access is priced as two
    classes, unmeasured; (d) a 16-bit access at a byte device port costs one class on the machine
    (XE10T `/IO`: `R16_005C` `art=255/255/256`, `R16_0188` `254/255/255`, `W16_04A8` `106/106/107`,
    `docs/probes/XE10T-XE10.TXT:378`, `:380`, `:412`, the same as the byte rows) and the Xe10 table
    prices it so, but no word row at 0x4A0 is captured: that read is safe (XE10CFG `/W4A0` read
    `FFFF FFFF` with no freeze, `docs/probes/KIT1-XE10-W4A0.TXT`) and was withdrawn from `/IO` after
    the freeze in item 154. A word at lanes 1-2 of a dword is measured (XE10W `/MISAL2`,
    `docs/probes/XE10W-XE10-MIS2RUN1.TXT`: `IOOW_5` one class, `IOIW_1` two classes less 127.1 ns)
    and priced so; a word that CROSSES a dword (`IOOW_3`, `IOIW_3`, port 4n+3) reaches the iobus as
    two separate requests (z486 `paging_unit.sv` `PG_CROSS_*`), each priced on its own, and nothing
    marks the second half: the machine's `out dx,ax` at 0xA3 is 499.1 ns, the core's two fast-class
    halves about 610 (the read, 1519.5 against about 1570, is close). Pricing it needs the CPU to
    tag the split's second request, a fork change. **Done when:** an XE10T row reads the EGC file's even port in two
    EGC states (mode register 0x04A0 as found and after a write) and a word row at 0x4A0 on the
    machine, and a core run
    of the same XE10T `/IO` in Xe10 mode lands on every machine row within one clk_sys.

94. **Software-DIP store: the machine's post-POST state.** **CAPTURE-PENDING.** Both
    configuration stores are re-seeded from the power-up image on every reset
    (`tb_pc9821_pram`). (a), the `0x851E = 0xE3` divergence, is settled: bank A's `0x851E` stores
    only bit 4 and puts the write's other bits on port 0x31 (`docs/probes/XE10CFG-XE10-CFGWR.TXT`,
    `tb_pc9821_msw_hold`). Open: (b) whether the ITF's KANJI CG RAM test leaves code `0x2056` wiped
    or intact. The 2026-11-07 kit read code 0x2056 rows 0..0xF through the `0xA4000` window (the
    ITF's own path, `BANK4@0x4677`) after a cold power-on, after three RESETs and after software
    reboots (`docs/probes/KIT1-XE10-CG0-USERCG.TXT`, `-CGR1-`, `-CGR2-`, `-CGR3-`, `-CGSW-`,
    `-CGCHK-USERCG.TXT`): all `00`, no `AA 55`, identical in every state, while codes 0x0156-0x1F56
    hold fixed non-zero bytes that do not mirror the software DIPs. The core holds its default
    record there (`docs/probes/core/KIT1-CORE-rc-e6db0f05-s3-CG0.TXT`). The machine's backup battery was dead for that run (its calendar counted up from zero after power-on), so a record
    lost with the battery may explain the zeros. Kit Z (2026-11-14, `docs/probes/README.md`'s
    `XE10Z-XE10.TXT` row) found DATE and TIME correct, so the battery state may have changed, but
    no power cycle has shown it holding. **Done when:** the battery is confirmed good (the calendar
    survives a power cycle) and only then XE10CFG `/CG`'s window read (kit 1's CG0/CGR/CGSW steps)
    is repeated after a cold and a warm boot.

97. **The `0x0461` window above page 9.** **CAPTURE-PENDING.** Pages 0x00-0x07 are a hole on the
    real Xe10 and on the core (`docs/probes/KIT2-XE10-RISKY-461.TXT:5-17`: FFFF over the window
    while the memory those pages name holds data, a store through it dropped; page 08 the identity;
    `pc9821_memory_map.sv` `win0_hole_page`, `tb_pc9821_win0_out_of_range`). Pages 0x0A-0xFF keep
    QEMU's alias (0x0A is the measured RAM page, DMAROUTE-XE10.TXT), but only 0x0A, 0x0C, 0x0E, 0x10,
    0x41 and 0x7F have rows. **Done when:** a capture of pages 0x10, 0x20 and 0x7E (read and a
    marker store through the window, the direct word beside it) confirms or corrects the alias.

98. **`0x043B` bit 2: pin the measured polarity; bit 3 when unwritten.** **WORK** for bit 2;
    **CAPTURE-PENDING** for bit 3. Kit 2's unreal-mode `RISKY /43B`
    (`docs/probes/KIT2-XE10-RISKY-43B.TXT:5-13`) measured what NP2kai `io/necio.c`/QEMU gave and
    the core models (`sys16m_en`): with bit 2 clear (FB, F3) 0xF00000 and 0xF80000 read FFFFFFFF
    and do not take a write, 0xFA0000 mirrors 0x0A0000, 0xFE8000 mirrors 0x0E8000 and 0xFFFFF0
    0x0FFFF0; with bit 2 set (FF, F7) the whole range is plain RAM (reads 00000000, 0xF80000 takes a
    write); after a write bit 3 reads 1 (F3 -> FB, F7 -> FF). The core's run of the same binary
    reads identically, row for row (`docs/probes/core/KIT2-CORE-RISKY-43B.TXT`). The polarity is
    pinned only in two halves (`tb_pc9821_iobus`'s 0x043B rows, `tb_pc9821_sys16m`), with no F3/F7
    write rows. Bit 3 with NO write is not always 1: three captures read `043B=F3` after boot
    (`docs/probes/MEMSW-XE10-MEMSW0.TXT:111`, `XE10CFG-XE10-CFGF1.TXT:17` `F3 F3`,
    `XE10CFG-XE10-CFGEND.TXT:17` `FB F3`), where the core always reads FB/FF; what clears it is
    unknown. **Done when:** a bench holds the `/43B` rows from the capture (the F3/F7 writes and
    their FB/FF read-backs included), proven with `tools/mutate_bench.py`; and a capture that reads
    0x043B across boots and the firmware's writes says what bit 3 follows, with the core matching
    it (until then `docs/bios-setup.md`'s "bit 3 reads 1" is a statement about reads after a
    write).

99. **Machine settings the OSD cannot yet offer.** **CAPTURE-PENDING.** The SETUP item ->
    (software-DIP index, bit) map is decoded in `docs/bios-setup.md`, and what each item does on the
    machine is item 172. Open: (b) the mouse-interface mode (`sdip[2]` bit 5 -> port `0x7FDB` bit
    6, which the core's mouse ignores), a hidden item SETUP cannot reach, so the capture writes the
    DIP byte itself and reboots; (c) the DMA clock (`sdip[2]` bit 4: `out 0xF4,4` compatible or
    `out 0xF4,5` fast, `docs/bios-setup.md`; the core decodes 0xF4 as a read-only `0xFC`). Every
    capture so far, all taken after POST, reads `00F4=FC` and `7FDB=FF`
    (`docs/probes/XE10CFG-XE10-*.TXT`; the core's run of the kit reads the same), but none flipped
    either item. With Port B an input the core answers 0x40 at 0x7FDB, NP2kai's constant, which
    no row has read (item 254). A PC-speaker volume field is a feature idea, not a
    capture, and is left to the owner. **Done when:** the SETUP DMA clock item is flipped both ways
    and `0xF4` read, and `0x7FDB` is read after a hidden-bit write of `sdip[2]` bit 5 both ways.

112. **Memory-switch cell `0x79` at a second RAM size.** **CAPTURE-PENDING.** The core answers
    total - 2 MiB at every size (`pc9821_iobus.sv` `msw_79_strap`, matched on an index of exactly
    0x79); the only measurement is the pair `0x530 = F9`, `0x531 = 1E` on a 32 MiB Xe10
    (`docs/probes/MEMSW-XE10-MEMSW0.TXT:145-146`, read-only). The index reads back with bit 7 set,
    so whether bit 7 of the index matters (does the cell answer at both 0x79 and 0xF9) is open as
    well. **Done when:** a `probe2 /MEMSW` on a machine with another installed size confirms or
    corrects the formula, and a probe that writes the index as 0x79 and as 0xF9 says whether bit 7
    is part of the address.

114. **IRQ15: the tick at a 0x128 write.** **CAPTURE-PENDING.** The tick is free-running, as the
    Xe10's first falls after `0x128 <- 81`/`80` show (5311 and 8013 of 9600, 609 and 3366 of 4800,
    14994 and 17858 of 19200 ARTIC ticks, `docs/probes/KIT2-XE10-AUDIT2.TXT:31-41`):
    `pc9821_calendar.sv` runs one 1/64 s chain with 1/32 s and 1/16 s taps and a write does not
    restart it (`tb_pc9821_calendar_tick_phase`). Still inferred: what a write landing at a
    controlled phase does, and the line state while bit 7 is clear or the rate is off. **Done
    when:** a row writes 0x128 at a known phase against the previous tick (and with bit 7 clear) and
    the RTL follows it.

121. **IDE bank placement under Linux's `pc98ide` driver.** **CAPTURE-PENDING.** The driver writes
    `0` to `0x432` and identifies units on bank 0 only; the core's disk is bank 0's master in every
    build (fixed layout; `tb_pc9821_ata_linux_probe`), so it finds the disk. Open
    is the measured Xe10, whose CF card sits on the second connector (`docs/probes/IDE.TXT`).
    **Done when:** that Linux image is booted there - finding the disk would mean the `0x432` bank
    model is wrong - and `ideprobe` is run in the same setup.

154. **XE10T unified timing capture.** **CAPTURE-PENDING.** One binary, `tools/hwprobe/xe10t`
    (`XE10T /ALL`), covers the CPU identity, the unmeasured I/O writes, 16-bit port reads, TRAM/CG
    cost, the `0xA6` drain, IRQ entry and OPNA BUSY. The first Xe10 run (binary 678d4070) froze
    hard in `/IO` at the EGC even/odd alternation; that row, and every `/IO` read no machine
    capture had made, are gone, and each device row now commits a `ROW` line first. The Xe10 `/ALL` run is committed
    (`docs/probes/XE10T-XE10.TXT`, 536 lines, every section from ID to RESTORE, no freeze). **Done when:** `XE10T /ALL`
    has run on the core, the decoder's `.expect` file and its analysis are in `docs/probes/`,
    benches cite them, and the timing probes it supersedes are retired.

156. **IRQ entry latency.** **CAPTURE-PENDING.** The machine's XE10T `/IRQ` section is
    captured (`docs/probes/XE10T-XE10.TXT:423-432`: `IRQ0_ENTRY lat_pit=5/5/7`, `INT08_SOFT swint_pit=7/8/10`,
    `UNMASK_ENTRY unmask_pit=11/12/14`, in PIT counts). **Done when:** the core's `/IRQ` run is
    compared with it and the core's entry latency follows.

167. **A second hard disk on IDE bank 1.** **UNVERIFIED (INFERRED).** The OSD's "IDE bank 1"
    field puts a second hard disk (hps_io slot 3) on bank 1's master in place of the CD-ROM
    (`tb_pc9821_ide_bank1_hdd`). That the Xe10 IDE ROM registers it is read from the disassembly
    (BANK3@0x0A0A IDENTIFY, `or [0x5ba],1<<slot` at @0x0A96, slot-order numbering at
    @0x0DC0-0x0DFB: DA/UA 0x81 behind bank 0's disk, 0x80 alone); no run of the real BIOS on the
    core with two images and no capture of the machine with a disk on each connector exists. Also
    unmeasured: how a protected-mode driver (Windows 95's, Linux/98's) uses the two banks at once,
    which the shared transfer engine serializes (`docs/trade-candidates.md` T76). **Done when:**
    `tb_pc9821_userdisk` with `+HDD2_FILE` shows 0x55D/0x5BA with both disks registered and DOS
    giving the second disk a drive letter; the Xe10 with an ATA disk on each connector is captured
    (port 0xF0, 0x55D, 0x5BA, 0x457, the drive letters) and compared; and Windows 95 and Linux/98
    are run on the core with two disks and checked by eye.

168. **CPUSUITE on the Xe10: the CPU behaviours not adopted.** **CAPTURE-PENDING.**
    The Xe10 CPUSUITE runs (`docs/probes/CPUSUITE-XE10-run1.TXT` .. `run5.TXT`) and the triage
    pack (`docs/probes/CPUSUITE-XE10-triage.TXT`, sources in `tools/hwprobe/cpusuite/triage/`)
    led to the fork changes in `docs/z486-local-patch.md`, "CPU behaviour taken from the real
    machine" (the IDIV quirk at r8/r16/r32, DR6 bit 12, the REP CMPS/SCAS fault flags, the 16-bit
    error-code write and DR6.Bn for disabled breakpoints among them, each adopted because an
    independent source corroborates the capture). Still open: (B) **The silicon differences z486 does not follow** (rows of the triage capture
    unless a run is named; z486's behaviour after the arrow):
    1. INVD, WBINVD and INVLPG run at CPL3 (`tri_priv_mask` `data=00000007`, `cpl3_priv_gp`;
       `invd_wbinvd_cpl3` `data=00000000` and `invlpg_ss_limit_gp` `data=00000001`, run3) and INVD
       in V86 at IOPL 0 (`v86_invd_gp` `data=0D010079`, run5, the #GP is the HLT after it); the
       Intel486 PRM and every reference make them CPL0-only -> z486 raises #GP(0).
    2. 0F 07 raises #DB as a trap after two bytes (vector 1, no error code): `tri_0f07_pm`/`_rm`
       `data=01AA0002`, `tri_opsweep`'s one mismatch -> z486 raises #UD.
    3. BSWAP r16 leaves CX = the low word of the 32-bit swap, ECX[31:16] kept: `tri_bswap16`
       `data=89ABAB89`, `bswap_486` -> z486 swaps all 32 bits.
    4. MOV CR3 delivers the old tables' #PF for the prefetch of the next page: `tri_cr3_race`
       `data=00012000` (CR2 = that page) -> z486 does not (`cr3_walk_race_fault`).
    5. The GDT accessed-bit write #PF reports CR2 = the descriptor's first byte: `tri_desc_cr2`
       `data=00009818` -> z486 reports the high dword (+4).
    6. After MOV CR0 sets PG only the rest of the current 16-byte line runs untranslated:
       `tri_pg_grace0/8/13` `data=30/38/3D` -> z486 keeps one line more (`paging_grace` accepts both).
    7. A 386 interrupt gate from ring 3 through a 286 TSS leaves ESP[31:16] = 9B01h (an internal
       leftover): `tri_tss286_esp` `data=9B012FEC` -> z486 zero-extends SP0.
    8. UMOV's memory forms do not access normal memory (the store does not land, the load gives
       0079h): `tri_umov` `data=99000000` -> z486 runs them as MOV, the documented user-mode
       meaning; that UMOV raises no #UD and its register form moves is adopted (it already was).
    Several may be AMD-only traits of this part. **Owner decision (2026-11-03):** z486 keeps its
    behaviour for every row of (B), including 4 (the CR3 race) and the `nw_lock` count (11 on
    the part, 12 on z486, both accepted by the program): a row is adopted only when an
    independent source corroborates the capture, and none does yet. **Done when:** an Intel 486 has run the
    same programs, so each of (B) is recorded as common to the 486 or AMD-only (a row that a
    source then corroborates goes back to the owner as a fork change with its test programs
    corrected). The patent example US 5,689,721's B0F8h / 1Eh, whose printed remainder 36h follows an
    arithmetic slip, is settled: kit 3's `XE10Y /K3M` IDIV reads AX = F880 on the Xe10
    (`docs/probes/XE10Y-XE10-K3M.TXT`), AH = F8h as the model and z486 give (the core's run reads
    the same; NP2kai raises #DE).

170. **What a software reboot resets on the Xe10.** **NEEDS RE-VERIFICATION** (the core side).
    The machine's answer is captured (`docs/probes/RBOOT-XE10.TXT`): with 0x063C, 0x1E8E and a
    0xF8E90 marker moved, the 0x534 reboot came back to DOS by itself and every field read as
    cold (`063C=FC 1E8E=FE F8E8F=00 05 B8`); memory switch 5 written A1 before it read 01 after it
    (memory switch = initialise, `XE10CFG-XE10-P6INIT/P6INITR.TXT`); port 0x31, moved to 12 by a
    0x851E write, read F3 again (`XE10CFG-XE10-CFGRB.TXT`). POST rewrites all of these, so the
    capture cannot tell a reset from a rewrite. By the RTL the core's 0x534 path gives the same
    AFTER line (`pc9821_iobus.sv`'s 0x534 arm and P31), but the core's own `RBOOT /S` -> `/R` run
    has not reached `/R`. The ARTIC counter restarts too: after each `RBOOT /Y` (out 0xF0, then the
    ITF's 0x534 reboot) it reads 13.0 s at the next boot's first AUTOEXEC command, the boot's own
    length (`docs/probes/KIT1-XE10-BOOTLOG.TXT`, `stamp_decode.py`), where the core's counter runs on
    through the reboot (`docs/probes/core/KIT1-CORE-rc-e6db0f05-s3-BOOTLOG.TXT`: 15.05 s boots,
    ARTIC 12-52 s at arrival). The 0x534 arm resets its own list of latches only (A20, the ROM
    and RAM gates, the windows, the top shadow); `ems_state`, `sys16m_en_q`, `sdip_ctrl`,
    `system_port_c`, the 0x436/0x439/0x63F configuration latches, the 0x6C border, the 0x9A8 select
    and the 0x989x latch are left to POST, and no bench reads them across a 0x534 write.
    **Done when:** a userdisk-tier run at Boot order Auto prints an AFTER line equal to BEFORE, the
    ARTIC's restart at a reboot is modelled or raised, and a core RBOOT run that moves `ems_state`,
    the 0x8F1F control and port 0x35 before the reboot reads them back after it, compared with the
    Xe10 (a latch the machine shows cold is reset in the 0x534 arm with a fail-first bench).

172. **The BIOS SETUP items on the machine.** **CAPTURE-PENDING** (two rows left). The
    2026-11-03/04 sessions ran every step (`docs/probes/XE10CFG-XE10-*.TXT`, `FDMODE-XE10-*.TXT`,
    `MEMSW-XE10-P6KEPT.TXT`, `SNDTEST-XE10-SND.TXT`; the as-found SETUP pages are transcribed in
    `docs/bios-setup.md`). Settled: port 0x31 bit 7/4/3 follow SETUP's GDC clock, memory switch
    and text lines (F3 -> 6B) and 0x871E bit 5 follows the memory switch (3E -> 9E); the floppy
    disk mode survives POST (0x861E 76/F7/75/F4 -> port 0x00BE FF/FB/F0/F4, and the 640K modes
    re-equip the drives as 640 KB units, 0x55C/0x55D 03/01 -> 00/31); Sound "used" turns on a
    codec that answers at 0x0F40-0x0F48 and 0xA460 = 73 with or without the PC-9801-86 board, and
    hides the -86 board's OPNA (0x188/0x18A read FF, `sndtest` silent), so the core's -86 board and
    no codec are the machine with Sound "not used"; text lines 20 sets port 0x31 bit 3, and DOS
    still shows 25 lines (owner's observation). Open: (1) the configuration record read through
    the `0xA4000` window: the 2026-11-07 kit read it as all `00` in every state (item 94), with the
    backup battery dead, so it is not yet known; the core's default record (factory row 4 0xCF,
    row 2 0x0C, sum 0xE6, `tb_pc9821_setup_record`) comes from SETUP's encoding; (2) memory switch
    "keep" with a non-default switch 5 (P6): the step's `/MSW5 A1` file is not on the card, so
    whether A1 was written before the RESET is unknown (it read 01 after; MSW3 read 04, not 0C, so
    the ITF's init did not run). **Done when:** the record is read through the window before and
    after one SETUP change with a working battery, and P6 is re-run with its `P6SET.TXT` kept.

180. **Port 0xCC bit 4 (the drive's RDY) in the 640K interface mode.** **CAPTURE-PENDING.** The
    core reads bit 4 as the RDY of the drive the controller's last command addressed, for one
    uPD765A drive poll (1.024 ms) after that command, and 0 otherwise (`pc9821_fdc.sv` THE
    SELECTED DRIVE'S RDY LINE): the BIOS reads it straight after a SENSE DRIVE STATUS of the unit
    (BANK7@0x7E67-0x7E7E) and, with the 640K AI off (Floppy mode Auto's interface toggle), fails
    every read AH=60h on a clear bit (BANK7@0x7525-0x7535), while `docs/probes/FDMODE-XE10-FDMF0.TXT`
    and `-FDMF1.TXT` read 0x64 at the DOS prompt with a disk in drive 0. The capture does not
    time its reads against a command, so the window and the motor's part are inference.
    **Done when:** a probe row reads 0xCC in 640K mode straight after a SENSE DRIVE STATUS of a
    drive with and without a disk, with the motor on and off, and again a few ms later, and
    `pc9821_fdc.sv`'s `sel_rdy` and `tb_pc9821_fdc_2dd_bank` case 10b follow. The probe exists:
    `XE10T /FDC2 /M640` (`tools/hwprobe/xe10t/README.md`; port 0xCC bit 4 after SENSE DRIVE STATUS,
    run with SETUP's floppy disk mode at 640K), and the core's run of it is
    `docs/probes/core/XE10T-FDC2-CORE-M640.TXT`; only the Xe10 run is owed (and the section is
    extended first if it does not cover the disk, motor and delay cases above).

181. **The ITF's saved port table across a reset on the Xe10.** **CAPTURE-PENDING.** At the end of
    a POST the ITF saves a port table into CG RAM from code 0x5610 line 0x20 up (BANK4@0x2136-0x2192)
    and keeps it while its length word is non-zero (BANK4@0x1D34-0x1D64); every POST's KANJI CG-RAM
    test (BANK4@0x0076-0x00F4) zeroes codes 0x5620-0x567F, which the table crosses (0x183 bytes on
    the core, 0x15A in the Xa7C9W capture, qemu-pc98 roms/pc98bios/memsw.inc), so on the core the
    boot after a kept table failed its check (BANK4@0x4741-0x47AD) and installed the factory DIP
    image (BANK4@0x47B2) on every second machine reset. The core now clears the length at every
    machine reset and 0x534 reboot (`pc9821_cg.sv` CG_RESTORE_LEN), so every boot rebuilds the table
    as the first boot after a core load does, and the ITF's fast path (BANK4@0x1D64 `jmp 0x2329`,
    about 2 s instead of 12 s at Boot order SASI1 on the card) is not taken. The 2026-11-07 kit ran
    three RESETs in a row (`docs/probes/KIT1-XE10-BOOTLOG.TXT`, `stamp_decode.py`): the ARTIC
    restarts at each RESET and reads 12.6-13.1 s at the first AUTOEXEC command, against 13.0 s
    after each software reboot, so no RESET took a fast path; and code 0x1056 line 0x20 held the
    same fixed bytes, no plausible length word, after the cold boot and every RESET
    (`docs/probes/KIT1-XE10-CG0-USERCG.TXT` .. `-CGR3-USERCG.TXT`). The machine's backup battery was dead for that run (its calendar counted up from zero after power-on), and with no
    valid record the ITF may never keep a table, so the run cannot tell the battery's effect from
    the ITF's rule. **Done when:** the three RESETs are repeated with a working battery and the
    length clear is kept or replaced from the answer.

194. **Ready change on a floppy insert with the motor stopped.** **CAPTURE-PENDING.** At POST the
    Xe10 BIOS writes 0xBE <- 07 (EMTON set), so 0x94 bit 3 drives the floppy motor, and its IRQ11
    handler stops the motor about 150 timer writes after the last INT 1Bh command (0x94 <- 00). The
    core follows NP2kai's drive model (`ai_gate` in `pc9821_fdc.sv`, NP2kai diskdrv.c): with EMTON
    set and the motor off, an insert raises no ready-change interrupt until the motor bit rises, while
    an eject still reports C9. A game that polls the BIOS result byte for the insert (Burai Part 2,
    drive 2) therefore misses a disk mounted after the motor stopped. No capture shows what a real
    drive does. **Done when:** a probe waits for the motor timeout, ejects and inserts a disk in
    drive 2, and reads SENSE INTERRUPT STATUS (and 0x94/0xBE) at each step; `pc9821_fdc.sv` and the
    compatibility note follow the answer, with a bench whose expected values come from the capture.

199. **PEGC packed store: two states.** **CAPTURE-PENDING.** On the Xe10 a 24 kHz PEGC packed
    store on a graphics line runs at one of two rates, about 145 or about 181 ns per store, fixed
    within a row and chosen by something before it: /MISAL2's sequence always reads the low state
    and /RDLAT's always the high one (in every binary and in both `/REP` passes,
    `docs/probes/XE10Y-XE10-REP.TXT`), while `XE10Y /PKAB` flips between rows and even between the
    nop points of one sweep, in both test orders and every factor row
    (`docs/probes/XE10Y-XE10-PKAB_AB.TXT`; the L1 off, `-PKAB_N.TXT`, and a write-buffer drain,
    `-PKAB_D.TXT`, do not explain it). What sets the state is unknown. The owner's decision
    (2026-11-13): "keep 182.8 for the PEGC stores until we can separate why it's different
    depending on method" - so `tools/xe10_classes.csv` keeps PK_WR_24A (and its 24P copy) at the
    high state, 182.8. The 24 kHz text stores with 256 colours on look like the same effect (CELLS'
    3PA one-word store reads 162.1 ns where /RDLAT1 reads 139.9 in that state), so their 24P cells stay
    declared fallback-24 (the owner, 2026-11-13: "keep the 24 kHz values for the text stores").
    **Done when:** a probe names what selects the state (the access before the
    store stream, the loop's alignment or phase) and the table and `pc9821_pegc_xe10_pace.sv` follow
    it, with a bench row.

201. **uPD4990A TIME SET: the folds no capture row measures.** **UNVERIFIED (INFERRED).** The
    chip loads every set and folds a digit past its counter's end at once (`XE10Z /CAL`,
    `docs/probes/XE10Z-XE10.TXT:234-247`; `pc9821_calendar.sv` ts_*, `tb_pc9821_calendar_timeset`).
    Each fold is measured at one value only: the seconds' units at A and F (carrying), the day's
    units at A (not carrying), minute 60, hour 24, month 13, year A0, weekday 7. Inferred from
    those and open: units B..E in every field and A..F outside the seconds and the day; minute
    tens 7..F; hours 25..3F (and the hour's units past 9); month 14..15; weekday 8..F; the year's
    units A..F; seconds tens 6/7 loaded directly (carry a minute or not); and how a folded day
    00, day 32..39 or month 0 counts on. The set restarting the second (the first tick one second
    after it) is inferred from 28 reads 1.1 s apart that each moved exactly one second, not
    timed directly. **Done when:** a probe sets each of those values (and times the first tick
    after a set with the ARTIC counter) on the machine and `pc9821_calendar.sv` follows the reads.

204. **FDC write-side and FORMAT rows.** **CAPTURE-PENDING.** The Xe10 FDC captures cover READ DATA
    and READ ID; `pc9821_fdc.sv` takes the rest from NP2kai, MAME or the datasheet: WRITE DATA and
    FORMAT keep NP2kai's MSR drive-busy bit (the machine sets none for READ DATA/READ ID,
    `docs/probes/XE10T-XE10-FDC2A.TXT`, `-FDC2C.TXT`); the writes and FORMAT take READ DATA's
    not-ready result delay; a terminal count BEFORE EOT follows the datasheet/MAME (every captured
    row ends on R == EOT); a WRITE DATA past EOT; and ST0 HD after a terminal-count end under MT
    follows NP2kai where MAME reports the last sector's side. Two write-side contents rest on
    reasoning too: the bytes past a mid-sector terminal count of WRITE DATA keep the medium's old
    data (`tb_pc9821_fdc_handoff` H5; NP2kai writes its stale buffer tail, and the data sheet's pad
    is not cited), and a D88 sector stored shorter than its N keeps only its stored bytes
    (`tb_pc9821_fdd_write` W3b, the author's reading of the format). **Done when:** an XE10T-style section
    (READ/WRITE DATA with TC at R < EOT under MT = 0 and 1, WRITE DATA beyond EOT, the MSR polled
    during WRITE DATA and FORMAT, the result-phase delay of each) is captured on the Xe10 and on the
    core with the same binary, each row is matched or fixed with a fail-first bench quoting the
    capture, the sector read back after a mid-sector TC write is captured too, NP2kai's
    `fdd_write_d88` is cited for the D88 layout, and the `pc9821_fdc.sv` comments that say these
    are not captured cite this item.

205. **IRQ10 (the 640 KB FDC interrupt): the masked request.** **CAPTURE-PENDING.**
    `pc9821_interrupts.sv` keeps IRQ10 a pure edge latch because it is not measured, while IRQ11
    (the 1 MB FDC) drops a request raised and lowered while masked (`docs/probes/XE10T-XE10-FDC.TXT`
    `irq11_taken=0`). If the 640 KB line behaves the same on the machine, a 640 KB-mode driver that
    masks IR10, runs a command and unmasks takes a stale interrupt on the core. Only the core's run
    of the RST640 row exists (`docs/probes/core/XE10T-FDC2-CORE-M640.TXT`). **Done when:** `XE10T
    /FDC2 /M640` (the run item 180 owes) captures the RST640 row on the Xe10, and IRQ10 is added to
    the master's withdraw masks with a fail-first bench quoting it, or the edge latch is confirmed
    and the comment cites the capture.

206. **The drive-letter search time behind Rusty's cut voice.** **CAPTURE-PENDING.** Rusty's C-Lab
    logo voice is cut short at CPU Speed Full and complete at 16 MHz: OP.COM stops the voice after
    searching every drive letter, whose duration depends on how quickly empty floppy drives answer
    (`docs/user/compatibility.md`); the machine's time for that search is not measured. **Done
    when:** a DOS probe in `tools/hwprobe/` times a drive-letter sweep with empty floppy drives (and
    the INT 1Bh not-ready answer) on the Xe10 and on the core with the same binary, the captures are
    in `docs/probes/`, and the core's not-ready latency is fixed with a bench if it differs, or the
    row is closed as matching.

207. **Graphics GDC PITCH and DGD at 5 MHz.** **CAPTURE-PENDING.** At the 2.5 MHz GDC clock the
    graphics GDC's row step follows the guest's PITCH, halved by FIGS DGD, for WRITE and figures
    alike, as the Xe10's rows measure (`docs/probes/gdc-conformance/xe10-2.5MHz/GDCADDR.CSV`
    ADDR_PITCH_CARRY, `GDPIT0.CSV`-`GDPIT3.CSV`; `tb_pc9821_gdc2_write`,
    `tb_pc9821_gdc2_figure_xe10`). No capture covers the 5 MHz GDC clock, where `pc9821_gdc2.sv`
    keeps the drawing step at 40 words with DGD ignored. **Done when:** GDCADDR ADDR_PITCH_CARRY and
    RUNPITCH (GDPIT) are run on the Xe10 at 5 MHz, the rows are replayed in a bench and
    `adv_pitch_w` follows them. Optional rows on the way: a byte-width WDAT stream and a CSRW that
    sets CSRR byte 2 bit 2.

208. **EXECUTE DEVICE DIAGNOSTIC (0x90): the interrupt.** **CAPTURE-PENDING.** `pc9821_ata.sv`
    completes 0x90 with an interrupt when nIEN is clear; NP2kai raises none (`tb_pc9821_ata_conform`
    asserts the captured ERROR 0x01 and waives only the interrupt). The Xe10 capture records status 0x50 and ERROR
    0x01 after 0x90 (`docs/probes/IDE.TXT:341-344`), but not whether INTRQ was raised, and no bench
    pins it either way. `tb_pc9821_ata_linux_probe` L4 asserts the interrupt and ERROR 0x01 with
    device 1 selected from ATA-3 alone, where NP2kai gives 0x81 (slave absent) and no interrupt,
    and the core's ATAPI model follows NP2kai (no interrupt), so the hard disk and the CD answer
    0x90 differently. **Done when:** a probe records whether the Xe10 raises IRQ 9 after 0x90 with
    nIEN clear (raw capture in `docs/probes/`), and `tb_pc9821_ata_conform` asserts the machine's
    interrupt answer with a fail-first bench, or the waiver cites the capture; `pc9821_ata.sv` and
    `pc9821_atapi.sv` then give one answer, and L4 cites it.

244. **PIC OCW2 0x80: rotate in auto-EOI mode.** **CAPTURE-PENDING.** `pc9821_pic.sv` follows
    NP2kai (`io/pic.c:291-310`): OCW2 0x80 rotates the priority pointer to the in-service level
    + 1 when a level is in service, with no auto-EOI model behind it. The 8259A data sheet and
    QEMU (`hw/intc/i8259.c:258-261`) only set the rotate-in-auto-EOI mode, and MAME
    (`pic8259.cpp:305-306`) steps the pointer even with the ISR empty. **Done when:** rows A and B
    (and optionally C) of a PIC rotate probe in the next Xe10 kit are captured and decoded, and the
    RTL matches the capture with a bench.

246. **FDC WRITE with terminal count: ST0 HD.** **CAPTURE-PENDING.** On a multi-track WRITE ended by
    terminal count, the core (like NP2kai's write path) reports the head that was being written in
    ST0 HD; the Xe10 capture covers only the read side. **Done when:** an MT WRITE DATA ended by TC
    on side 0 and side 1 is captured on the Xe10 and the RTL follows it with a bench.

247. **ATAPI READ CAPACITY: count or last LBA, and with no medium.** **CAPTURE-PENDING.** The core
    returns the sector count and succeeds with no disc, as NP2kai does; MMC returns the last LBA and
    NOT READY. **Done when:** READ CAPACITY with a disc and with the tray empty is captured on the
    Xe10's CD drive and the RTL follows it with a bench.

248. **PIT: a two-byte reload while the counter runs.** **CAPTURE-PENDING.** The core follows NP2kai
    (the new count takes effect only when both bytes are written); QEMU and the 8254 data sheet mix
    the new low byte with the old high byte. **Done when:** on the Xe10, channel 0 runs in mode 2 at
    0x1000, the low byte of 0x2080 is written, and the periods are timed against ARTIC before the
    high byte (a mixed reload shows 528 ARTIC ticks per period, an unmixed one 512), and the RTL
    follows it.

249. **Keyboard 0x9C: typematic delay and rate.** **CAPTURE-PENDING.** undoc98 decodes 0x9C 0x70 as
    a 1000 ms delay where NP2kai treats it as "inhibit", and the rate field has no documented rates.
    Needs someone at the real keyboard. **Done when:** a key is held for 3 s after each of 0x9C 00,
    20, 40, 60, 70, 21 and 3F with the 0x41 bytes logged against ARTIC, and the RTL follows the
    measured delays and rates.

250. **Keyboard link byte time.** **CAPTURE-PENDING.** The core paces keyboard bytes at NP2kai's
    1,280 per second; the link is a fixed 19200 bps (about 1,745 bytes/s). Changing the constant is
    a timing trade for the owner. **Done when:** the three bytes of the 0x96 response (FA A0 83) are
    timed against ARTIC on the Xe10 and the owner decides the constant from the measurement.

251. **The PCMKIT capture run on the Xe10.** **CAPTURE-PENDING.** One CF kit
    (`tools/hwprobe/pcm86ovf/mkpcmkit.py`; core run in `docs/probes/core/` once committed) answers:
    the 86-PCM FIFO past full, status and line-out (`PCMOVF`, item 238); OCW2 0x80 (`PICROT`, item
    244); the shadow-bank orders the captures do not cover (`SHBANK`: 043D=02, 043F=Ex then 043D=00;
    043D=00, 043F=EE then 043D=00; every Ex under 043D=02; the 0x10/0x12/0x18 aliases); the 0x29
    gate of the ADPCM interrupts (`OPNAX /G`, item 211); INSL and the pad (`OPNAX /J`, 0x0E after
    0x0F = 80, C0, 00, 40 with a button held); and 0x0640/0x0641 on the idle bank (`IDE640`). **Done
    when:** the kit's captures and the line-out recording are decoded against the core run and each
    answer is in the RTL with a fail-first bench or recorded where it already matches.

252. **IRQ0 withdrawn on an unmasked OUT0 fall.** **CAPTURE-PENDING.** The master PIC is built
    with `WD_UNMASKED(8'h83)` (`pc9821_interrupts.sv`), so a latched IRQ0 is withdrawn on every
    falling edge of PIT OUT0, masked or not. In mode 3 OUT0 falls every half period, so an
    unmasked request that is not taken in time (IF = 0 for more than half a period) is lost at the
    next fall, where an edge latch would hold it until INTA. `docs/probes/IRQWD.TXT` measures only
    the MASKED case (`IRQ0 masked poll`), and its `PITCH0 IRR before ch0-write after = 01 01` row
    shows that a channel-0 control write did NOT clear the IRR, against the NP2kai write-clear
    (`pit_o71`/`pit_o77`) that `tb_pc9821_pit_irq_reprogram` cites. The rule fixed a game
    regression, so it stays until it is measured. **Done when:** an IRQWD row with IRQ0 UNMASKED
    and IF = 0 reads the IRR across several mode-3 half-period falls and across a channel-0 mode-0
    control word, on the Xe10 and the core with the same binary, the capture is committed under
    `docs/probes/`, and `WD_UNMASKED` bit 0 follows it (kept, narrowed to the write-caused fall, or
    dropped) with a fail-first bench quoting the row.

253. **ATA READ SECTORS: the status while BSY, and a command written while BSY.**
    **CAPTURE-PENDING.** The core's busy status is `ATA_ST_BSY` alone (0x80), and a command
    written while BSY is ignored; `tb_pc9821_ata_datapath`, `tb_pc9821_ata_drq_takeover`,
    `tb_pc9821_ata_iowait` and `tb_pc9821_ata_cmd_race` (S2) pin the exact 0x80 and the ignore.
    No reference supplies either value: NP2kai has no BSY phase for a read, and the only busy read
    captured on the machine is a RECALIBRATE poll that keeps DRDY and DSC
    (`docs/probes/IDE.TXT:334` `RECAL poll 1 D0 BSY=1 DRDY=1 DSC=1`). **Done when:** a probe reads
    0x064E and 0x074C while a READ SECTORS is busy, and again after a second command written
    during it, on the Xe10 and the core, and the busy status and the command-while-BSY rule follow
    the capture with fail-first benches (until then the benches should assert only bit 7 and DRQ).

254. **Mouse port 0x7FDB with Port B an input.** **CAPTURE-PENDING.** With Port B programmed as an
    input, `pc9821_mouse.sv` reads 0x7FDB as NP2kai's constant 0x40 (`mouseif_i7fdb`), and
    `tb_pc9821_mouse` asserts it at power-up (`power-up 7FDB = 0x40`); a guest that tests only bit
    6 (the ITF at BANK4@0xF824E) cannot tell it from 0xFF. Every Xe10 capture reads
    `PORT 7FDB=FF FF` (`docs/probes/XE10CFG-XE10-CFG0.TXT:22`, `docs/probes/KIT1-XE10-CFG0.TXT:22`),
    but after POST has programmed the 8255, and the core's run of the same probe reads FF there
    too (`docs/probes/core/KIT1-CORE-rc-e6db0f05-s3-CFG0.TXT:22`), so no row shows the input-mode
    byte. **Done when:** a probe writes an 8255 mode word with Port B input (0x7FDF bit 1 set) and
    reads 0x7FDB, on the Xe10 and the core, and `pc9821_mouse.sv` and `tb_pc9821_mouse` follow the
    row (0x40 kept with the capture cited, or the captured byte).

261. **Graphics GDC drawing cases no capture covers.** **CAPTURE-PENDING.** Three graphics-GDC
    answers rest on references or inference. (a) Arcs: `tb_pc9821_gdc2_figure` asserts radii 1-100
    against NP2kai's `gdcsub_vectc` circle, which the line captures already refute for lines
    (`tb_pc9821_gdc2_figure_xe10`); the machine's arcs (`docs/probes/KIT1-XE10-GDCFIG.BIN`, radii
    15, 30, 40, 55, 70 and 95) are compared only by hand with `gvdump_decode --compare`. (b) A
    partial multi-bit MASK (0x00FF, 0x0F0F) now walks as a rotate; the captures cover only one-hot
    masks (WDAT_STEP) and FFFF (GDCADDR). (c) The WRITE walk's 19-bit address now borrows below
    EAD 0 into plane G and carries out of bit 18; GDCADDR's rows stay at or above 0x0FFFE going
    down and end at 0x40001 going up. **Done when:** GDCFIG's arcs are decoded into a vector file
    replayed by a bench, and GDCADDR/WDAT rows for a partial multi-bit mask and for a borrow below
    0 and a carry past 0x7FFFF are captured on the Xe10 and the RTL follows them with fail-first
    benches.

263. **FDC: READ DATA's C after RECALIBRATE, and 0x04BE bit 4 against the 640K DIP.**
    **CAPTURE-PENDING.** (a) `tb_pc9821_fdc_seek_track` S4 runs RECALIBRATE, then READ DATA with
    C = 3 and no SEEK, and expects cylinder 3's data: NP2kai's `fdc_lasttreg` rule adopts C and
    seeks, where a uPD765A leaves the head on track 0 (ND or track 0's data). No capture covers a
    mismatched C. (b) `tb_pc9821_fdc_2dd_bank` asserts that 0x04BE bit 4 and 0xCC follow the
    interface strap, not the 640K-mode DIP (0x00BE bit 3), but in every capture the two move
    together (`docs/probes/FDMODE-XE10-FDMF0.TXT`, `-FDMF1.TXT`, `-FDMF3.TXT`), so the separation
    is inference. **Done when:** a probe reads the sector after RECALIBRATE + READ DATA with C != 0,
    and 0x04BE/0x00CC after an `out 0xBE` that sets the strap and the 640K DIP apart, on the Xe10
    and the core, and both benches follow the rows (or label the NP2kai rule as a compatibility
    choice).

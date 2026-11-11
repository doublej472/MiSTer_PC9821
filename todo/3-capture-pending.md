# 3. Capture-pending hardware questions

A software model exists, but no machine measurement settles it, and the answer would change
what a guest observes. Each item names the measurement. Probes are in `tools/hwprobe/` (a
missing probe has to be written; run it on the core first, then on the machine).

22. **CRTC horizontal porch split.** **CAPTURE-PENDING.** The power-on raster follows NP2kai's
    field mapping (active 640, front porch 128, sync 56, back porch 24 dots); only the 848-dot
    total is measured. **Done when:** HSYNC is scoped on the video output and
    `pc9821_crtc.sv` matches the measured porches.

23. **GDC status bit 6 (blank): the phase inside the line.** **CAPTURE-PENDING.** Both GDCs
    (`0xA0` and `0x60`) read bit 6 high 23.4 % of the time on the machine, the horizontal blank
    of one line (208/848); the core now drives the per-line horizontal blank on every line
    (`tb_pc9821_crtc_stat_blank`; NP2kai `io/gdc.c` `gdc_i60` raises it once per raster line).
    Unmeasured: where in the line the high part sits (the core uses the dots after the active
    640). **Done when:** bit 6 is sampled against a raster tick inside a line on the machine
    and `pc9821_crtc.sv` places the measured window.

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
    Still open: the 16-colour half (the plane at `0xE0000` after `OUT 0x6A,0x01`) rests on NP2kai
    alone, and no capture has a DMA transfer into `0xE0000` in the digital mode (P4's DMA run
    is made in the 256-colour state). **Done when:** `0xE0000` is re-read on the machine in the
    16-colour mode (the plane expected), with a digital-mode DMA write to `0xE0004` in the same run.

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

38. **OPNA ADPCM-B over the data bus.** **UNVERIFIED (INFERRED).** The ADPCM-B RAM is not
    fitted (`adpcm_din = 8'h00`) but the register-0x08 bus-fed path is wired (`jt12_top.v`
    `bus_din(din)`, the write data goes out on the unconnected `adpcm_dout`). Measured in
    simulation (2026-10, scratch bench, not kept: it would only pin our RTL): with the
    extension on, ADPCM-B started in external-memory mode (`0x100 = 0xA0`, level `0xFF`,
    delta-N `0x4000`) over a RAM that reads zero is NOT silent - the output peaks at ~1.2 k
    (nibble 0 decodes to a rising delta), against 0 with the unit not started. So the core is
    silent only for a guest that never starts ADPCM-B. **Done when:** the real chip's behaviour
    with no RAM behind it (or whether the machine has the 256 KiB the -86 board lists) is
    captured - a probe that writes a pattern through `0x108` and reads it back through
    `0x108`/the BRDY flag - and the core either fits the RAM or gates the unit to match.
    XE10T `/OPNA2` (`docs/probes/XE10T-XE10-OPNA2.TXT`) has the write half: in memory-write
    mode (0x100 = 0x60, 0x101 = 0x02, start = stop = 0, limit 0xFFFF) BRDY follows each of 40
    bytes written through 0x108 (ADB_W, 40/40), EOS (status 0x04) sets at the 32nd byte (ADB_W
    `i=32 ... st=0C`: the stop address, in 32-byte units, reached), ADB_END reads `st=0C` and the
    +6 read with 0x08 still selected answers `s6=80` (the byte just written), and BRDY then
    stays set through three 0x110 = 0x80 resets (FR_ADB i=0..2 time out). The core
    (`docs/probes/core/XE10T-CORE-opnasafe-OPNA2.TXT`) matches BRDY 40/40 but never sets EOS
    (`st=08`) and reads `s6=00`: software that streams samples into the RAM and waits for EOS
    would time out. The read-back half (write a pattern, read it through 0x108) is still owed.

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
    apart, which neither capture explains; (c) a 32-bit access and a word at an odd port are priced
    as two classes, unmeasured. **Done when:** an XE10T row reads the EGC file's even port in two
    EGC states (mode register 0x04A0 as found and after a write) on the machine, and a core run
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
    lost with the battery may explain the zeros. **Done when:** the window read is repeated after a
    cold and a warm boot with a working battery.

97. **The `0x0461` window above page 9.** **CAPTURE-PENDING.** Pages 0x00-0x07 are a hole on the
    real Xe10 and on the core (`docs/probes/KIT2-XE10-RISKY-461.TXT:5-17`: FFFF over the window
    while the memory those pages name holds data, a store through it dropped; page 08 the identity;
    `pc9821_memory_map.sv` `win0_hole_page`, `tb_pc9821_win0_out_of_range`). Pages 0x0A-0xFF keep
    QEMU's alias (0x0A is the measured RAM page, DMAROUTE-XE10.TXT), but only 0x0A, 0x0C, 0x0E, 0x10,
    0x41 and 0x7F have rows. **Done when:** a capture of pages 0x10, 0x20 and 0x7E (read and a
    marker store through the window, the direct word beside it) confirms or corrects the alias.

98. **`0x043B` bit 2: pin the measured polarity.** **WORK.** Kit 2's unreal-mode `RISKY /43B`
    (`docs/probes/KIT2-XE10-RISKY-43B.TXT:5-13`) measured what NP2kai `io/necio.c`/QEMU gave and
    the core models (`sys16m_en`): with bit 2 clear (FB, F3) 0xF00000 and 0xF80000 read FFFFFFFF
    and do not take a write, 0xFA0000 mirrors 0x0A0000, 0xFE8000 mirrors 0x0E8000 and 0xFFFFF0
    0x0FFFF0; with bit 2 set (FF, F7) the whole range is plain RAM (reads 00000000, 0xF80000 takes a
    write); bit 3 reads 1 whatever is written (F3 -> FB, F7 -> FF). The core's run of the same
    binary reads identically, row for row (`docs/probes/core/KIT2-CORE-RISKY-43B.TXT`). Nothing pins
    the polarity in the battery. **Done when:** a bench holds those rows from the capture, and the
    references to this item (`docs/bios-setup.md`, the `risky` sources and `mkkit2.py`) are
    reworded so it can be retired.

99. **Machine settings the OSD cannot yet offer.** **CAPTURE-PENDING.** (a) The SETUP item ->
    (software-DIP index, bit) map is decoded in `docs/bios-setup.md`; what each item does on the
    machine is item 172; (b) the mouse-interface mode (`sdip[2]` bit 5 -> port `0x7FDB` bit 6, which the
    core's mouse ignores); (c) the chipset select (`sdip[2]` bit 4 -> port `0xF4`, decoded as a
    read-only `0xFC`); (d) a PC-speaker volume that preserves the DIP byte's mirror/parity bits.
    **Done when:** `0x7FDB`/`0xF4` are captured with each bit both ways. P4 is answered: `0x7FDB=FF`, `0x7FDD=18`,
    `0x7FDF=FF`, stable across both reads and every SETUP change of the 2026-11-04 session
    (`docs/probes/XE10CFG-XE10-*.TXT`), and the core reads the same.

112. **Memory-switch cell `0x79` at a second RAM size.** **CAPTURE-PENDING.** The core answers
    total - 2 MiB at every size (`pc9821_iobus.sv` `msw_79_strap`); the only measurement is `0x1E`
    on a 32 MiB Xe10. **Done when:** a read-only `probe2 /MEMSW` on a machine with another
    installed size confirms or corrects the formula.

114. **IRQ15: does a 0x128 write restart the tick?** **CAPTURE-PENDING.** The line's shape is
    the machine's: high, a short low pulse at each tick, a 0x128 read leaving it
    (`docs/probes/KIT2-XE10-AUDIT2.TXT:27-41`; `pc9821_calendar.sv`, `tb_pc9821_calendar_xe10`
    CALIRR, `tb_pc9821_irq_withdraw` C). The backup battery was dead for both kits, but that costs
    the calendar its time across power-off, not its running count (1 s/s in the session, the four
    rates' periods agree), so the shape stands. Still a difference: the core restarts the period at
    every 0x128 write, but the machine's first fall after `0x128 <- 81` came 5311 and 8013 ARTIC
    ticks in (`cfg=81 mode=N ... e=-5311`, `mode=R ... e=-8013`), not a period later, and after
    `<- 80` 609 ticks in: the tick looks free-running. Also inferred, not measured: the line held low
    while bit 7 is clear or the rate is off. **Done when:** a row writes 0x128 at a known phase
    against the previous tick (and with bit 7 clear) and the RTL follows it.

121. **IDE bank placement under Linux's `pc98ide` driver.** **CAPTURE-PENDING.** The driver writes
    `0` to `0x432` and identifies units on bank 0 only; the core's disk is bank 0's master in every
    build (fixed layout; `tb_pc9821_ata_linux_probe`), so it finds the disk. Open
    is the measured Xe10, whose CF card sits on the second connector (`docs/probes/IDE.TXT`).
    **Done when:** that Linux image is booted there - finding the disk would mean the `0x432` bank
    model is wrong - and `ideprobe` is run in the same setup.

126. **Graphics GDC arc: radius and rounding.** **CAPTURE-PENDING.** The conformance suite's
    GDCDRAW ARC rows ERRORed on the Xe10 (the machine locked up after the runaway rectangles), so
    no arc is measured. `pc9821_gdc2` draws radius D + 1 (the datasheet's D = r - 1, MAME
    draw_arc) as the exactly rounded circle round(r - sqrt(r^2 - i^2)); NP2kai takes radius D and
    misrounds single dots through its 4096-entry table. **Done when:** `tools/hwprobe/gdcfig`'s
    picture (its arcs at radii 1..100 in all eight octants) is captured on the Xe10 and compared
    dot for dot with the core's.

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

157. **16-bit I/O on the faithful profile.** **VERIFIED (HW)** for `0x640`; **CAPTURE-PENDING** for
    the other 16-bit ports. The faithful profile charges a word access as the sum of its byte lanes:
    1646 ns for `in ax,0x640`, where `docs/probes/IDELAT-clean.TXT` (CAL DATWORD) measures 515 ns.
    The XE10T `/IO` word rows are captured: `R16_005C` and `R16_0188` cost
    `art=255/255/256` and `254/255/255` (`docs/probes/XE10T-XE10.TXT:378`, `:380`), the same as the byte rows
    (`R8_005C` `254/255/256` at `:288`, `R8_0188` `254/255/256` at `:328`), and `W16_04A8` is
    `106/106/107` (`:412`). The 16-bit read at 0x4A0 (withdrawn from `/IO` after the freeze in item
    154) is safe: XE10CFG `/W4A0` read `FFFF FFFF` on the machine with no freeze
    (`docs/probes/KIT1-XE10-W4A0.TXT`), as on the core. **Done when:** the faithful table prices a
    16-bit device port as one access (checked against those rows), and an XE10T `/IO` word row at
    0x4A0 is captured for the EGC file's word read.

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
    independent source corroborates the capture). Still open: (A) **The patent example's AH.**
    US 5,689,721's worked example B0F8h / 1Eh gives quotient 80h without overflow (adopted), but
    its printed remainder 36h follows an arithmetic slip in its step-3 row; the model and the
    silicon rule give AH = F8h, which is what z486 returns. A B0F8h / 1Eh case on the Xe10
    confirms it. (B) **The silicon differences z486 does not follow** (rows of the triage capture
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
    independent source corroborates the capture, and none does yet. **Done when:** a B0F8h / 1Eh
    case has run on the Xe10 with the raw capture in `docs/probes/`; and an Intel 486 has run the
    same programs, so each of (B) is recorded as common to the 486 or AMD-only (a row that a
    source then corroborates goes back to the owner as a fork change with its test programs
    corrected).

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
    ARTIC 12-52 s at arrival). **Done when:** a userdisk-tier run at Boot order Auto prints an
    AFTER line equal to BEFORE, and the ARTIC's restart at a reboot is modelled or raised.

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
    `pc9821_fdc.sv`'s `sel_rdy` and `tb_pc9821_fdc_2dd_bank` case 10b follow. The 2026-11-07 kit's optional
    640K pass was not run.

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

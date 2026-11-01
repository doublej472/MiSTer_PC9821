# 3. Capture-pending hardware questions

A software model exists, but no machine measurement settles it, and the answer would change
what a guest observes. Each item names the measurement. Probes are in `tools/hwprobe/` (a
missing probe has to be written; run it on the core first, then on the machine).

3. **`0x9A8` latch width.** **CAPTURE-PENDING.** `docs/probes/RDBACK.TXT` reads `00`, then
    `01` after writing `01`, then `00` after the restore; `pc9821_iobus.sv` now latches bit 0 (NP2kai's
    width, `tb_pc9821_readback_sysports`). **Done when:** one more write with high bits set settles
    its width (1 bit or a byte).

15. **Analog palette registers: index width and read-back.** **CAPTURE-PENDING.** In analog
    16-colour mode, is `0xA8` a full 8-bit index (write `AB`, read `AB` or `0B`), and do
    `0xAA/AC/AE` return the full DAC byte or a nibble? The existing read-back capture ran in
    digital mode. **Done when:** an analog-mode (`0x6A`) write/read capture exists and
    `pc9821_gfx_palette.sv`'s 16-entry mirror follows it (or, if write-only, the DAC output on
    screen is measured instead).

17. **GDC `mode1` (`0x68`) read model.** **CAPTURE-PENDING.** The DOS-prompt read is `0x18`;
    the RTL seeds NP2kai's `0x98`. The question is the read model (raw latch, encoded, or
    constant). **Done when:** a fresh-boot read-only `0x68` capture, before and after a known
    mode write, is matched in `pc9821_iobus.sv`.

18. **OPNA extended read-back: `0x18A`/`0x18E`/`0x18C`.** **CAPTURE-PENDING.** Three reads the
    references disagree on: (a) `0x18E` with extended select `0x0F` - QEMU `0x80`, NP2kai the
    shadow `0x00`, this core the ADPCM-B data bus, YM2608-LLE the bus echo of the last byte
    written; (b) `0x18A` after `0x188 = 0x0F`/`0x08` (stable `00`, `FF`, or a moving data bus);
    (c) whether `0x110` masks the `0x18C` timer bits (QEMU masks, NP2kai and the RTL do not).
    **Done when:** `opnapro`'s extended rows (at reset and after a `5A` marker; with
    `0x110 <- 0x1F` against its control) are captured and the RTL follows them.

21. **`0x0433`: IDE connect flag or IRQ-pending?** **CAPTURE-PENDING.** The RTL answers
    NP2kai's connect flag (`device_present ? 0x02 : 0x00`); the only capture (no drive) cannot
    discriminate. **Done when:** `0x0433` is read with a drive on the selected bank and with an
    IDE interrupt pending.

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

27. **IDE bank-select `0x0432` bit 7 and `0x074E` with the slave selected.** **CAPTURE-PENDING.**
    With bit 7 clear the RTL floats the task file, where one capture answers it (`0x01` ->
    `0x064E = 0x50`); `0x074E` is only measured with the master selected. **Done when:**
    `ideprobe` writes `0x0432` in `{00, 01, 02, 03, 2A, 80}` reading `0x064E/0x0640/0x074C/0x074E`
    after each, and reads `0x074E` with `0x064C = 0xB0`; `pc9821_ata.sv` follows.

28. **`0x043F` read-back encoding.** **CAPTURE-PENDING.** The read is value-dependent
    (`docs/probes/EMS.TXT`: `20` -> `C4`, `80` -> `C5`, `82` -> `C7`, `C4` -> `CB`) but
    under-determined. **Done when:** a full write/read sweep is captured and pinned by a bench.

31. **`0xE0000` answering nothing.** **CAPTURE-PENDING.** Possibly a mode artefact: the
    intensity plane is reachable only in analog modes. **Done when:** `0xE0000` is re-read in
    analog mode, before any `pc9821_memory_map.sv` change.

34. **`0xDC000-0xDFFFF` with the IDE work-RAM gate on.** **CAPTURE-PENDING.** `DA000-DBFFF`
    and the gate-off state are measured (`docs/probes/SHADOWW.TXT`, `SHADOW.TXT`); the gate-ON
    `DC000-DFFFF` is modelled as `FF`. **Done when:** a marker written at `0xDC000` with
    `0x1E8E = 0x81` is read back on the machine.

35. **`0x989x` write behaviour.** **CAPTURE-PENDING.** Only reads are captured
    (`0x9894/0x9892 = 0xF0`; `0x9890/0x9896/0x98E0 = FF`). **Done when:** an opt-in
    write-then-read of those ports is captured.

36. **`0x6C` and the `0x60-0x6F` decode.** **CAPTURE-PENDING.** `0x6C` is the last port a guest
    hits that nothing answers; the decode skips `0x66` and `0x6C`. **Done when:** `0x60-0x6F`
    are read on the machine and the decode follows.

37. **CG window even offsets.** **CAPTURE-PENDING.** NP2kai reads the low page for even
    offsets, QEMU round-trips them, the RTL drops the write and reads zero (`pc9821_cg.sv`).
    **Done when:** reads and writes of consecutive offsets across the `0xA4000` window are
    captured.

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

94. **Software-DIP store: the machine's post-POST state.** **CAPTURE-PENDING.** Both
    configuration stores are re-seeded from the power-up image on every reset
    (`tb_pc9821_pram`). Unmeasured: (a) the core ends a boot with `0x851E = 0xE3` where the
    machine reads `0x02` (`docs/probes/PORTS.TXT`); (b) whether the ITF's KANJI CG RAM test
    leaves code `0x2056` wiped or intact. **Done when:** `probe2 /RDBACK` on `0x851E`, and a read
    of code `0x2056` rows `0..0xD` after a warm reset, are captured.

97. **The `0x0461` window's page 0/1: alias or hole.** **CAPTURE-PENDING.**
    `docs/probes/WIN.TXT` reads `0xFFFF` through the window with page 0 selected, where the core
    maps RAM at `0x00000`. **Done when:** the word at physical `0x00000` is compared with the same
    word through the window at `0x80000` (`0x0461 = 0x00`, then restore `0x08`).

98. **`0x043B` bit 2: the 15-16 MiB system space's polarity.** **CAPTURE-PENDING.** `sys16m_en`
    switches the PEGC window at `0xF00000`, the `0xF80000` hole and the `0xFA0000` mirror; the
    polarity is from NP2kai `io/necio.c`/QEMU, never measured. **Done when:** an unreal-mode probe
    (`memmap`/`a20map` carry the code) reads those addresses with bit 2 flipped both ways (and a
    bit-3 control).

99. **Machine settings the OSD cannot yet offer.** **CAPTURE-PENDING.** (a) The SETUP item ->
    (software-DIP index, bit) map: the item descriptor table near `BANK3@0x21ED-0x230F` is not
    decoded; (b) the mouse-interface mode (`sdip[2]` bit 5 -> port `0x7FDB` bit 6, which the
    core's mouse ignores); (c) the chipset select (`sdip[2]` bit 4 -> port `0xF4`, decoded as a
    read-only `0xFC`); (d) a PC-speaker volume that preserves the DIP byte's mirror/parity bits.
    **Done when:** the table is decoded and `0x7FDB`/`0xF4` are captured with each bit both ways.

110. **The DIP store's write-side parity bits.** **CAPTURE-PENDING.** The store lets the ITF's
    port writes set each register's parity bit (only `0x841E` bit 1 is withheld). **Done when:**
    `probe2 /RDBACK` writes `0x7F`/`0xDC` at `0x8B1E` and `0x881E` and reads back; if the machine
    masks those bits, the RTL change reverses.

112. **Memory-switch cell `0x79` at a second RAM size.** **CAPTURE-PENDING.** The core answers
    total - 2 MiB at every size (`pc9821_iobus.sv` `msw_79_strap`); the only measurement is `0x1E`
    on a 32 MiB Xe10. **Done when:** a read-only `probe2 /MEMSW` on a machine with another
    installed size confirms or corrects the formula.

114. **Masked-request withdraw on the acking access: IRQ15.** **CAPTURE-PENDING.** `irqwd`
    (`docs/probes/IRQWD.TXT`) measured IRQ0/1/9/12/2 and `pc9821_pic`'s `WD_MASK` follows it;
    IRQ15 (calendar, `0x128`) did not trigger. **Done when:** `irqwd`'s IRQ15 section is re-run
    with the calendar interrupt enabled and `WD_MASK` matches.

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

128. **Text row geometry: 20/30 lines, partitions, smooth scroll.** **CAPTURE-PENDING.**
    `pc9821_crtc.sv`'s text line sequencer transcribes NP2kai `vram/maketext.c`
    (`tb_pc9821_text_modes`); no machine capture of a 20/30-line, split or scrolled screen exists.
    Open: the PL < 16 row (NP2kai runs nowline PL..BL-PL, not PL..BL), a partition switch in
    mid-row, the SSL cut below the SDR region, and whether a CRTC write lands mid-frame (live
    here) or next frame (NP2kai). **Done when:** `tools/hwprobe/txtmode` (`TXTMODE`, a key per
    state) is photographed in all seven states on the machine and compared with the core's
    screenshots of the same binary, and the RTL follows any difference.

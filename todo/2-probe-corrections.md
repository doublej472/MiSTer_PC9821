# 2. Probe re-runs

Measurements whose first capture was invalid or incomplete. Probes are in `tools/hwprobe/`,
captures in `docs/probes/`.

10. **PIT channel 0: one-byte write retention and the `FFE5` divisor read.** **CAPTURE-PENDING.**
    After a one-byte count write this core keeps the other count byte; QEMU, NP2kai and MAME
    zero it. `docs/probes/PIT-fixed.TXT` also reads an out-of-range `divisor = FFE5`. **Done
    when:** a fresh-boot `probe2 /PIT` run passes its scan gate and its Experiment 2/3/4 rows say
    which retention the machine has; `pc9821_pit.sv` follows it with a fail-first bench.

13. **GDC light-pen (LPEN) read-back.** **NEEDS RE-VERIFICATION.** One capture: master `C0`
    popped `FF FF FF`, slave `C0` `00 00 F0`, slave `E0` `28 40 F8 01 00`; NP2kai and the RTL
    return no LPEN bytes. **Done when:** a repeat at several reset/frame positions (`probe2`'s
    GDC section) shows whether the bytes are constants or live beam state; only then change
    `pc9821_crtc.sv`/`pc9821_gdc2.sv`.

158. **probe2 /WIPE W5 fencepost.** **WORK.** W5 counts 64 VSYNC edges from an arbitrary raster
    phase, so the window holds about 63.2 frames and its 57.115 Hz / 434 lines is wrong; the machine
    runs that mode at 5445 ARTIC ticks per frame (`docs/probes/CRT31K.TXT`). **Done when:**
    `wipe_decode.py`'s W5 verdict and the rusty-re raster figure are corrected in writing (the XE10T
    `/CAL` section replaces the measurement).

159. **ioprobe_decode against the current RTL.** **WORK.** `tools/hwprobe/ioprobe/ioprobe_decode.py
    docs/probes/IO.TXT` fails with `KeyError: 'IO_WAIT_5F'`; the RTL no longer has that localparam,
    nor `IO_NS_5F_W` (a 0x5F write is posted now, `IO_POST_5F`, and has no class-table value).
    **Done when:** its `--check-rtl` parses the `IO_NS_*` table, or the decoder's RTL check is
    retired with the probe once the XE10T capture supersedes `IO.TXT`.
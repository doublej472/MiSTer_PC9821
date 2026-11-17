# 2. Probe re-runs

Measurements whose first capture was invalid or incomplete. Probes are in `tools/hwprobe/`,
captures in `docs/probes/`.

13. **GDC light-pen (LPEN) read-back.** **NEEDS RE-VERIFICATION.** One capture
    (`docs/probes/RDBACK.TXT:171-173`): master `C0` popped `FF FF FF`, slave `C0` `00 00 F0`, slave
    `E0` `28 40 F8 01 00`. The RTL answers LPEN with `00 00 00` (NP2kai's never-written
    para[29..31], `pc9821_crtc.sv`, `pc9821_gdc2.sv`) and `0xFF` once the queue is empty, so the
    master's `FF FF FF` is consistent with the modelled empty queue and the slave's first two bytes
    match; the open question is only the slave's third byte, `F0` (a constant, beam state or a
    stale latch). Low priority. **Done when:** a repeat at several reset/frame positions (probe2
    `/RDBACK`'s GDC section, or an LPEN row in a later XE10T/XE10Z kit) shows what the third byte
    is; only then change `pc9821_crtc.sv`/`pc9821_gdc2.sv`.

158. **probe2 /WIPE W5 fencepost.** **WORK.** W5 counts 64 VSYNC edges from an arbitrary raster
    phase, so the window holds about 63.2 frames and its 57.115 Hz / 434 lines is wrong; the machine
    runs that mode at 5445 ARTIC ticks per frame (`docs/probes/CRT31K.TXT`). **Done when:**
    `wipe_decode.py`'s W5 block carries the caveat (edges counted from an arbitrary phase give a
    window of N-1 to N frames; the machine's 5445 ticks per frame, 56.42 Hz, 440 lines, from
    `CRT31K.TXT` and XE10T `/CAL`) with a selftest case. `tools/hwprobe/xe10t/README.md` already
    records the fencepost in writing.

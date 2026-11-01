# 6. Audio: OPNA/SSG/ADPCM

78. **OPNA `0xA466` DAC-control handling.** **UNVERIFIED (INFERRED).** The core adopts NP2kai's
    Policenauts/WinNT workaround, which is not hardware evidence. **Done when:** a capture or a
    datasheet justifies (or replaces) it.

150. **Sync `sys/` with Template_MiSTer.** **WORK.** `sys/` is byte-identical to Template_MiSTer
    3ea1134 (2026-08-26); upstream 76dd8f5 (2026-10-28) is four commits ahead, 6 files, +72/-16.
    Wanted: afd7808 (registered analog/I2S audio outputs and a debounced I/O-board mode bit:
    glitches on the 3.5 mm output). Forced: 9c8eadb adds five `LFB_*` inputs to `emu_ports.vh`,
    so `module emu` in `z486_mister.sv` needs the five ports. Not used here: 5dda373 (YC; the core
    sets `MISTER_DISABLE_YC`) and 76dd8f5 (force feedback; tie the six `joystick_N_ffb` inputs to 0).
    The current `sys/` works with current Main_MiSTer (an unknown command 0x45 answers 0). A `sys/`
    change moves `pll_hdmi` placement, so it takes the full seed sweep, the load screen and the
    regression. **Done when:** `sys/` is upstream HEAD, the release-candidate gates pass on it,
    and the 3.5 mm output is checked by ear on a card with an I/O board.

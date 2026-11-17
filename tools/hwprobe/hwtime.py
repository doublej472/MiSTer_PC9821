#!/usr/bin/env python3
"""hwtime.py - the PC-98 time bases the probe decoders share (imported, not run).

The ARTIC counter (ports 0x5C/0x5E) ticks at 307 200/s. PIT raw counts move at the
strap-selected oscillator: 2 457 600/s on the 2.4576 MHz strap (divisor 0x6000), 1 996 800/s
on the 1.9968 MHz strap (divisor 0x4E00, work-area 0501 bit 7). So one ARTIC tick is 8 raw PIT
counts on the first strap and 6.5 on the second; `pit_per_artic()` gives the ratio for a rate.

`referee()` is the per-window health label the ioprobe and idelat decoders apply to a window
measured with both counters (it was copied in each). ARTIC serves whenever its delta is >= 1
tick: at these window sizes the 24-bit counter cannot wrap or tear, while the PIT's 16-bit raw
delta wraps silently (a 3-reload window reads ~8192 counts low) and a torn latch word
mis-assembles. PIT serves only sub-tick windows. The cross-check is a label at the measured
0.5-5% agreement band: 'ok', 'WRAP' (the -8192-count reload signature, rejected), 'neq' beyond
the band, 'sub' for a sub-tick window.

Small-window rule: the absolute floors (16 counts, 32 for the WRAP check) exist for latch-read
quantisation, but they are CLAMPED to the reference so the band never exceeds +/-100% on
windows below ~320 counts (art = 1 tick, ref = 8: 'ok' spans pit 0..16, not 0..24).
"""

from __future__ import annotations

ARTIC_HZ = 307_200
ARTIC_NS = 1e9 / ARTIC_HZ          # 3255.208 ns per tick
PIT_HZ_24576 = 2_457_600           # the 2.4576 MHz strap (divisor 0x6000)
PIT_HZ_19968 = 1_996_800           # the 1.9968 MHz strap (divisor 0x4E00)

# clk_sys of the shipping build profile (build_profile.py `base`: "90 MHz clk_sys"). The one
# place a decoder that converts clk_sys counts should take its default from; ioprobe_decode pins
# its RTL column to it. tools/decode_telemetry.py (83.333) and tools/decode_dbglog.py (80) still
# carry their own defaults: moving them is an owner decision (it changes their printed rates).
CLK_SYS_HZ_BASE = 90_000_000


def pit_per_artic(pit_hz: int = PIT_HZ_24576) -> float:
    """Raw PIT counts per ARTIC tick at the strap rate `pit_hz` (8.0 or 6.5)."""
    return pit_hz / ARTIC_HZ


def referee(pit: int, art: int, ratio: float = 8.0) -> str:
    """The health label of one window ('ok', 'WRAP', 'neq', 'sub'); see the module text.

    `ratio` is the raw PIT counts per ARTIC tick the window is judged against. The decoders
    pass 8 (the 2.4576 MHz strap's law) today, also on a capture whose PITDIV names the
    1.9968 MHz strap, where they print a strap note instead.
    """
    if art >= 1:
        ref = max(art * ratio, 1)
        if abs(pit - ref) <= min(max(16, 0.05 * ref), ref):
            return "ok"
        if abs(ref - pit - 8192) <= min(max(32, 0.02 * ref), ref):
            return "WRAP"
        return "neq"
    return "sub"

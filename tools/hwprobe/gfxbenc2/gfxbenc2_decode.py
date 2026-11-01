#!/usr/bin/env python3
"""gfxbenc2_decode.py - parse a GFXBENC2 capture into per-case machine numbers.

Usage:
    python3 tools/hwprobe/gfxbenc2/gfxbenc2_decode.py GFX2.TXT [GFX2B.TXT ...]

GFXBENC2 (tools/hwprobe/gfxbenc2/gfxbenc2.s) is the real-machine per-subsystem graphics
benchmark. It prints one line per timed case:

    GFX2 <TAG> UNITS=<n> ARTIC=<ticks> CLK50=<total> PER=<per-unit>

where UNITS is the case's own count, ARTIC is the raw 24-bit counter delta at the
documented 307200 Hz, CLK50 = ARTIC * 50000000 / 307200 (clk_sys at the core's
50 MHz), and PER = CLK50 * 1000 / UNITS (MILLI-clk_sys per unit).

TIME BASE. ARTIC ticks are converted BOTH ways with the device clocks and no
run-local scale (the /TIME ladder's lesson): absolute ns = ticks * 3255.208 (307200 Hz,
machine-confirmed by a raster check on the machine), and clk_sys at 50 MHz
for diffing against the core's own benchmarks. The printed CLK50/PER fields are
recomputed from ARTIC here and flagged if they disagree (integer rounding).

CONTROLS. CTRLPW / CTRLGC / CTRLCP are loop-shell control rows (the ioprobe
discipline: the same loop with each GVRAM access replaced by a register op).
The decoder nets each matched case and prints the per-op NS that the
rusty-pacing-fix-plan.md section 4 "Fix 1" fail-first constants need:

    GRCG_RMW net = (GRCG_RMW - CTRLGC) / 16    ns per 4-plane RMW word
    PW4RW    net = (PW4RW - CTRLPW) / 128     ns per access (32 per RMW word)
    PLANE_COPY net = (PLANE_COPY - CTRLCP) / 32   ns per access (16 pairs)

PW1-PW4 net approximately with CTRLPW (the same shell per plane); the EGC and
text rows are gross-only (their shells have no matched control).

The table beside the CORE's own benchmark numbers (tools/bench.py gfx_scene at
the tip named in CORE_GFX_SCENE_SRC; the decoder prints that provenance and its
per-phase raw totals in its header block):

    gfx_scene A  1983 clk_sys/sprite   the plain plane-window draw (40 in 79340)
    gfx_scene B   336 clk_sys/sprite   the EGC 0x3100 blit (40 in 13451)
    gfx_scene D  2401 clk_sys/sprite   the full busy scene (40 in 96040)
    gfx_scene G   505 clk_sys/row      the playfield shake (EGC 0x28F0, sft=2;
                                       400 rows in 202366)

A hand-copied bench number rots: before the
per-operation GVRAM acceptance period this table read 1952 / 343 / 3319 / 513.
Re-run the bench named in CORE_GFX_SCENE_SRC and compare before trusting a copy.

Nothing here talks to hardware; it is a pure text parser.
"""

from __future__ import annotations

import argparse
import re
import sys

# clk_sys per ARTIC tick at the core's 50 MHz (the documented 307200 Hz tick),
# and ns per tick (307200 Hz, machine-confirmed).
CLK_PER_TICK = 50_000_000 / 307_200
NS_PER_TICK = 1e9 / 307_200
# Exemption from the strap-divisor rule: this decoder is ARTIC-only (gfxbenc2 never touches the
# PIT), so there is no PIT_HZ strap to cross-check and no sub-tick PIT column.

# The core's own numbers, from tools/bench.py gfx_scene. Stored as the raw
# (units the phase ran, clk_sys the phase took, the unit name) so the number has
# ONE home and the decoder can print the totals it came from; the per-unit value
# is the bench's own printed clk_sys/unit (its integer division of the total).
# "unit" is what the core counts them per; the machine's PER/1000 is the same.
#
# PROVENANCE: re-derived on tip 5756409 (committed 2026-09-29); the bench's own
# lines (`python3 tools/bench.py gfx_scene`) are
#     A plain sprite draw: 40 sprites in 79340 clk_sys = 1983 clk_sys/sprite
#     B EGC sprite blit (page1->page0): 40 sprites in 13451 clk_sys = 336 ...
#     D FULL busy scene (erase+draw+restore x 40, scanout live): 96040 clk_sys = 2401 ...
#     G playfield shake (0x28F0, sft=2, 400 rows x 24 words): 202366 clk_sys = 505 ...
# re-check by re-running `python3 tools/bench.py gfx_scene`.
CORE_GFX_SCENE_SRC = "tools/bench.py gfx_scene @ 5756409"
CORE = {
    "gfx_scene A": (40, 79_340, "clk_sys/sprite"),
    "gfx_scene B": (40, 13_451, "clk_sys/sprite"),
    "gfx_scene D": (40, 96_040, "clk_sys/sprite"),
    "gfx_scene G": (400, 202_366, "clk_sys/row"),
}


def core_per_unit(name: str) -> float:
    """The bench's own clk_sys per unit: its integer division of the phase total."""
    units, total, _ = CORE[name]
    return total // units


# TAG -> (shape, unit, accesses per unit (int, 0 = not an access-counted shape),
#         core metric it maps to or None, matched control TAG or None).
META = {
    "PW1": ("1-plane window write", "sprite", 16, None, "CTRLPW"),
    "PW2": ("2-plane window write", "sprite", 32, None, "CTRLPW"),
    "PW3": ("3-plane window write", "sprite", 48, None, "CTRLPW"),
    "PW4": ("4-plane window write", "sprite", 64, None, "CTRLPW"),
    "PW4RW": ("4-plane read-modify-write", "sprite", 128, "gfx_scene A", "CTRLPW"),
    "CTRLPW": ("PW4RW loop shell, accesses replaced (control)", "sprite", 128,
               None, None),
    "EGC3100": ("EGC 0x3100 put, page1->page0", "sprite", 16, "gfx_scene B", None),
    "EGC3100SP": ("EGC 0x3100 put, same page", "sprite", 16, None, None),
    "EGC28F0": ("EGC 0x28F0 shifted copy sft=2", "sprite", 16, None, None),
    "EGC1400": ("EGC 0x1400 solid colour fill", "sprite", 16, None, None),
    "EGC0CF0": ("EGC 0x0CF0 ROP F0 write feed", "sprite", 16, None, None),
    "GRCG_TDW": ("GRCG TDW tile clear", "sprite", 16, None, "CTRLGC"),
    "GRCG_RMW": ("GRCG RMW erase", "sprite", 16, None, "CTRLGC"),
    "CTRLGC": ("GRCG fill loop shell, store replaced (control)", "sprite", 16,
               None, None),
    "PLANE_COPY": ("plain plane-0 -> plane-1 copy", "sprite", 32, None, "CTRLCP"),
    "CTRLCP": ("PLANE_COPY loop shell, accesses replaced (control)", "sprite", 32,
               None, None),
    "TRAM_FILL": ("text-plane TRAM fill", "line", 160, None, None),
    "CG_FONT": ("CG font read via 0xA9", "glyph", 0, None, None),
    "TXT_LINE": ("whole text subsystem per line", "line", 0, None, None),
}

LINE_RE = re.compile(
    r"^GFX2\s+(\S+)\s+UNITS=(\d+)\s+ARTIC=(\d+)\s+CLK50=(\d+)\s+PER=(\d+)\s*$"
)


def parse(path: str) -> tuple[list, bool]:
    cases = []
    begin = end = False
    with open(path, "r", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\r\n")
            if "BEGIN:GFXBENC2" in line:
                begin = True
            if "END:GFXBENC2" in line:
                end = True
            m = LINE_RE.match(line)
            if m:
                cases.append((m.group(1), int(m.group(2)), int(m.group(3)),
                              int(m.group(4)), int(m.group(5))))
    return cases, (begin and end)


def ns_per_unit(units: int, artic: int) -> float:
    return artic * NS_PER_TICK / units if units else float("nan")


def net_ns(by: dict, tag: str, divisor: int) -> tuple[float, str]:
    """(net ns per op, note) = (tag - its control) per unit / ops per unit."""
    shape, unit, accesses, core, ctrl = META.get(tag, ("?", "?", 0, None, None))
    if not ctrl or ctrl not in by or tag not in by:
        return float("nan"), f"needs {ctrl} (no matched control row in this capture)"
    t_units, t_artic = by[tag][1], by[tag][2]
    c_units, c_artic = by[ctrl][1], by[ctrl][2]
    gross = ns_per_unit(t_units, t_artic)
    shell = ns_per_unit(c_units, c_artic)
    return (gross - shell) / divisor, f"{tag} {gross:.0f} - {ctrl} {shell:.0f}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("captures", nargs="+")
    args = ap.parse_args()

    rc = 0
    for path in args.captures:
        cases, complete = parse(path)
        print(f"=== {path} ===")
        if not cases:
            print("  no GFX2 case lines found")
            rc = 1
            continue
        if not complete:
            print("  WARNING: no BEGIN/END:GFXBENC2 pair - a section may have hung "
                  "(the earlier cases are still valid)")
        print("  anchor: ARTIC 307200 Hz -> 3255.208 ns/tick; 162.7604 clk50/tick")
        print(f"  core column: {CORE_GFX_SCENE_SRC} ->")
        for key, (units, total, unit) in CORE.items():
            print(f"    {key.split()[-1]} {total // units} {unit} "
                  f"({units} units in {total} clk_sys)")
        print("    re-check it against the tree: python3 tools/bench.py gfx_scene")
        print()
        print(f"  {'TAG':<11} {'CLK/unit':>10} {'ns/unit':>9} {'accs':>5} "
              f"{'ns/acc':>8} {'unit':<7} {'shape':<32} {'core':<26} {'machine/core':>12}")
        for tag, units, artic, clk50, per in cases:
            shape, unit, accesses, core, ctrl = META.get(
                tag, ("?", "?", 0, None, None))
            clk_unit = per / 1000.0
            ns_unit = ns_per_unit(units, artic)
            ns_acc = ns_unit / accesses if accesses else float("nan")
            # The printed fields are the probe's integer math; recompute and flag.
            expect_clk = artic * 50_000_000 // 307_200
            flag = "" if abs(expect_clk - clk50) <= 1 else f" (CLK50 != ARTIC-derived {expect_clk})"
            corecol = ""
            ratio = ""
            if core and core in CORE:
                cval, cunit = core_per_unit(core), CORE[core][2]
                corecol = f"{core}={cval:.0f} {cunit}"
                ratio = f"{clk_unit / cval:.3f}"
            accs_s = f"{accesses}" if accesses else "-"
            ns_acc_s = f"{ns_acc:.1f}" if accesses else "-"
            print(f"  {tag:<11} {clk_unit:>10.3f} {ns_unit:>9.0f} {accs_s:>5} "
                  f"{ns_acc_s:>8} {unit:<7} {shape:<32} {corecol:<26} {ratio:>12}{flag}")
            if tag not in META:
                print(f"     (unknown TAG {tag}: not in this decoder's table)")
                rc = 1
        by = {c[0]: c for c in cases}

        # The Fix-1 per-op constants, net of the matched loop-shell controls.
        print()
        print("  NET OF CONTROL (rusty-pacing-fix-plan.md section 4 Fix 1 constants):")
        rmw, rmw_how = net_ns(by, "GRCG_RMW", 16)
        print(f"    GRCG RMW word (4-plane read-merge-write store) = "
              f"{rmw:.1f} ns   [{rmw_how} / 16 stores]")
        pw, pw_how = net_ns(by, "PW4RW", 128)
        print(f"    PW4RW per access (read or write of one plane word) = "
              f"{pw:.1f} ns; per 4-plane RMW word = {pw * 32:.1f} ns   [{pw_how} / 128 accs]")
        pc, pc_how = net_ns(by, "PLANE_COPY", 32)
        print(f"    PLANE_COPY per access = {pc:.1f} ns; per word moved = "
              f"{pc * 2:.1f} ns   [{pc_how} / 32 accs]")
        print("    PW1-PW4 net approximately with CTRLPW (same shell per plane);"
              "\n    the EGC and text rows are gross-only (no matched control).")

        # Cross-checks between cases that share a shape.
        if "EGC3100" in by and "EGC3100SP" in by:
            a = by["EGC3100"][4] / 1000.0
            b = by["EGC3100SP"][4] / 1000.0
            print()
            print(f"  0xA6 page-switch cost = EGC3100 - EGC3100SP = "
                  f"{a - b:+.3f} clk_sys/sprite")
        if "PW4RW" in by and "PW4" in by:
            rw = by["PW4RW"][4] / 1000.0
            w = by["PW4"][4] / 1000.0
            print(f"  the read half of PW4RW = {rw - w:+.3f} clk_sys/sprite "
                  f"(PW4RW {rw:.3f} - PW4 {w:.3f})")
        if all(k in by for k in ("GRCG_RMW", "PW4RW", "EGC3100")):
            erase = by["GRCG_RMW"][4] / 1000.0
            draw = by["PW4RW"][4] / 1000.0
            restore = by["EGC3100"][4] / 1000.0
            scene = erase + draw + restore
            d_core = core_per_unit("gfx_scene D")
            print(f"  scene reconstruction = GRCG_RMW + PW4RW + EGC3100 = "
                  f"{scene:.3f} clk_sys/sprite; core gfx_scene D = {d_core:.0f} -> "
                  f"machine/core = {scene / d_core:.3f}")
        print()
    return rc


if __name__ == "__main__":
    sys.exit(main())

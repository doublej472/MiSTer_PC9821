#!/usr/bin/env python3
"""gfxbench_decode.py - parse a GFXBENCH capture into per-word GVRAM costs.

Usage:
    python3 tools/hwprobe/gfxbench/gfxbench_decode.py GFXB.TXT [GFXBB.TXT ...]

GFXBENCH (tools/hwprobe/gfxbench/gfxbench.s) is the frozen raw-window bandwidth
comparator: 8 x 32 KiB `rep stosw` fills and `rep lodsw` reads per window,
bracketed by the ARTIC counter at the documented 307200 Hz (machine-confirmed,
a raster check on the machine) and printed as KiB/s.  One line per window:

    TRAM(A0000) WRITE=<kibs> KB/s READ=<kibs> KB/s

WHAT IT DECIDES.  The GVRAM0(A8000) WRITE row refreshes the plain-fill anchor on
THIS machine (the reference Xe10, 100 MHz): the long-standing "13.8 MB/s =
0.145 us/word" figure has NO raw capture
in docs/probes/ and its source does not name which machine produced it, so this
run is the authoritative one and settles whether that number is machine-portable.

TIME BASE (the /TIME ladder's lesson): the device clock only - ARTIC ticks x 3255.208 ns,
no run-local scale, no PIT (so none of the item-10/41 defect classes apply). The
timed windows are 256 KiB of `rep` string ops (no per-iteration loop shell to
net out; the two ARTIC bracket reads bias a ~20-37 ms window by well under
0.1%).  The source is frozen byte-identical (the archived comparator
gfxbenc2.com is measured against it), so this decoder - not the probe - is where
the per-word ns are derived.

Nothing here talks to hardware; it is a pure text parser.
"""

from __future__ import annotations

import argparse
import re
import sys

NS_PER_TICK = 1e9 / 307_200   # the ARTIC tick, machine-confirmed.
# PIT-strap exemption: this decoder is ARTIC-only (gfxbench never touches the
# PIT), so there is no PIT_HZ strap to cross-check and no sub-tick PIT column.

# The legacy anchor every report quotes: 13.8 MB/s plain GRCG-off fill read as
# 0.145 us/word (2-byte words, decimal MB).  Kept as the comparison target.
ANCHOR_US_PER_WORD = 0.145

LINE_RE = re.compile(
    r"^(?P<tag>TRAM\(A0000\)|GVRAM0\(A8000\)|ATTR\(A2000\))\s+"
    r"WRITE=(?P<wr>\d+) KB/s READ=(?P<rd>\d+) KB/s"
)


def per_word_ns(kibs: int) -> float:
    """ns per 16-bit word for a window throughput in KiB/s (2-byte words)."""
    return 1e9 / (kibs * 512) if kibs else float("nan")


def decode(path: str) -> int:
    text = open(path, "r", errors="replace").read()
    begin = "BEGIN:GFXBENCH" in text
    end = "END:GFXBENCH" in text
    rows = []
    for line in text.splitlines():
        m = LINE_RE.match(line.strip())
        if m:
            rows.append((m.group("tag"), int(m.group("wr")), int(m.group("rd"))))
    print(f"=== {path} ===")
    if not rows:
        print("  no GFXBENCH rows found")
        return 1
    if not (begin and end):
        print("  WARNING: no BEGIN/END:GFXBENCH pair - the run may have hung")
    print("  anchor: ARTIC 307200 Hz -> 3255.208 ns/tick (device clock, no run-local scale)")
    print()
    print(f"  {'window':<14} {'dir':<6} {'KiB/s':>7} {'MB/s':>7} {'ns/word':>8} {'us/word':>8}")
    anchor = None
    for tag, wr, rd in rows:
        for direction, kibs in (("WRITE", wr), ("READ", rd)):
            ns = per_word_ns(kibs)
            mb = kibs * 1024 / 1e6
            print(f"  {tag:<14} {direction:<6} {kibs:>7} {mb:>7.2f} "
                  f"{ns:>8.1f} {ns / 1000:>8.4f}")
            if tag == "GVRAM0(A8000)" and direction == "WRITE":
                anchor = ns
    print()
    if anchor is not None:
        print(f"  THE ANCHOR: GVRAM0 plain-fill write = {anchor / 1000:.4f} us/word on THIS "
              f"machine,\n    against the legacy {ANCHOR_US_PER_WORD} us/word (13.8 MB/s)."
              "\n    The legacy figure's capture is not in docs/probes/ and "
              "its source does not name the\n    machine (unverified);"
              " this run on the\n    Xe10 is authoritative and settles "
              "whether that number is machine-portable.")
    else:
        print("  (no GVRAM0(A8000) WRITE row: the anchor cannot be refreshed from this capture)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("captures", nargs="+")
    args = ap.parse_args()
    rc = 0
    for path in args.captures:
        try:
            rc |= decode(path)
        except OSError as exc:
            print(f"cannot read {path}: {exc}", file=sys.stderr)
            rc = 1
        print()
    return rc


if __name__ == "__main__":
    sys.exit(main())

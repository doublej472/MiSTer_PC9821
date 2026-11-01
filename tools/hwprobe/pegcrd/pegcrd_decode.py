#!/usr/bin/env python3
"""pegcrd_decode.py - decode a PEGCRD capture: does the machine return the byte?

Usage:
    python3 tools/hwprobe/pegcrd/pegcrd_decode.py PEGCRD.TXT

PEGCRD (tools/hwprobe/pegcrd/pegcrd.s) writes a six-entry palette pattern in the
16-colour analogue mode and in the PEGC 256-colour mode, then reads each entry
back through 0xAA/0xAC/0xAE. One row per entry:

    16  ENTRY=01 WROTE_R=12 G=34 B=56 READ_R=02 G=04 B=06
    256 ENTRY=01 ...

The question this capture settled (docs/probes/PEGCRD-XE10.TXT): in 256-colour mode does
0xAA/0xAC/0xAE return the byte written (NP2kai and this core) or 0 (MAME)?
The decoder classifies every row and prints the verdict:

    byte      all three channels read back exactly as written
    zero      all three read 0            -> the 3-M10K mirror can be deleted
    nibble    the low four bits survive   -> a 4-bit DAC register, not the byte
    other     anything else (printed as-is)

The 16-colour rows are the control: that path's mirror is the one already used
by the core's 16-entry readback, so the 256-colour answer is read beside it.
Entries 5A and A5 are in the pattern to separate an unmasked 8-bit index from a
4-bit-masked one; the decoder says which the 256-colour reads imply.

The port order is PC-98's: 0xA8 = index, 0xAA = green, 0xAC = red, 0xAE = blue.
WROTE_R is the byte written to 0xAC, WROTE_G to 0xAA, WROTE_B to 0xAE; READ_*
is the same port read back. The mode rows print 0x6A and the 0x9A0 query bits
(0x04 = 16-colour, 0x08 = FF2 write enable, 0x0A = GDCANALOG_256, 0x07 = EGC).

Nothing here talks to hardware; it is a pure text parser.
"""

from __future__ import annotations

import re
import sys

ROW = re.compile(
    r"^(16|256)\s+ENTRY=([0-9A-F]{2})\s+"
    # pegcrd.s prints the G and B fields bare (`msg_g: " G="`); the prefixed form is accepted too.
    r"WROTE_R=([0-9A-F]{2})\s+(?:WROTE_)?G=([0-9A-F]{2})\s+(?:WROTE_)?B=([0-9A-F]{2})\s+"
    r"READ_R=([0-9A-F]{2})\s+(?:READ_)?G=([0-9A-F]{2})\s+(?:READ_)?B=([0-9A-F]{2})\s*$")
MODE = re.compile(
    r"^MODE 6A=([0-9A-F]{2})\s+9A0_04=([0-9A-F]{2})\s+9A0_07=([0-9A-F]{2})\s+"
    r"9A0_08=([0-9A-F]{2})\s+9A0_0A=([0-9A-F]{2})\s*$")


def classify(w, r):
    # A zero write/zero read is "zero", not "byte": it cannot prove the port
    # returns the written byte, so it is excluded from the verdict below.
    if r == (0, 0, 0):
        return "zero"
    if r == w:
        return "byte"
    if r == tuple(x & 0x0F for x in w):
        return "nibble"
    return "other"


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    text = open(argv[1], "rb").read().decode("ascii", "replace")
    modes = []
    rows = {"16": [], "256": []}
    for line in text.splitlines():
        m = MODE.match(line)
        if m:
            modes.append(tuple(int(x, 16) for x in m.groups()))
            continue
        m = ROW.match(line)
        if m:
            mode, entry = m.group(1), int(m.group(2), 16)
            w = tuple(int(m.group(i), 16) for i in (3, 4, 5))
            r = tuple(int(m.group(i), 16) for i in (6, 7, 8))
            rows[mode].append((entry, w, r, classify(w, r)))

    if not rows["16"] and not rows["256"]:
        print("no PEGCRD rows found (is this the right capture?)")
        return 1

    print("mode rows (0x6A, then the 0x9A0 query: 04=16col 07=EGC "
          "08=write-enable 0A=GDCANALOG_256)")
    for t in modes:
        print(f"  6A={t[0]:02X}  9A0_04={t[1]:02X} 9A0_07={t[2]:02X} "
              f"9A0_08={t[3]:02X} 9A0_0A={t[4]:02X}")

    for mode in ("16", "256"):
        if not rows[mode]:
            continue
        title = "16-colour analogue" if mode == "16" else "PEGC 256-colour"
        print(f"\n== {title} ==")
        for entry, w, r, kind in rows[mode]:
            print(f"  entry {entry:02X}  wrote R={w[0]:02X} G={w[1]:02X} "
                  f"B={w[2]:02X}  read R={r[0]:02X} G={r[1]:02X} B={r[2]:02X}  {kind}")
        counts = {}
        for _, _, _, kind in rows[mode]:
            counts[kind] = counts.get(kind, 0) + 1
        print("  summary: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
        if mode == "16":
            print("  (the 16-entry table indexes 0xA8 with palnum & 15: the 5A and A5 "
                  "rows land on entries 0A and 05, so their readback is the alias's, "
                  "not their own - the 256 rows are the index-width test.)")

    print("\n== verdict ==")
    # Did each mode actually take? The 0x9A0 query is the independent witness:
    # 0x04 is the 16-colour bit, 0x0A is GDCANALOG_256.
    last = {}
    for t in modes:
        if t[1]:
            last["16"] = t
        if t[4]:
            last["256"] = t
    if rows["16"] and "16" not in last:
        print("  16-colour: the 0x9A0 index-0x04 query never read 1 - the mode "
              "did not take, so those rows do not answer the readback.")
    if rows["256"] and "256" not in last:
        print("  256-colour: the 0x9A0 index-0x0A query never read 1 - the 256 "
              "mode did not take, so those rows do NOT answer the 256-colour readback question.")
    for mode in ("16", "256"):
        if not rows[mode]:
            continue
        # A written-zero entry cannot discriminate byte from zero; 5A/A5 alias
        # 0A/05 in the 16-entry table and test the alias, not the readback.
        considered = [r for r in rows[mode] if r[1] != (0, 0, 0)]
        if mode == "16":
            considered = [r for r in considered if r[0] < 0x10]
        if not considered:
            considered = rows[mode]
        kinds = {kind for _, _, _, kind in considered}
        if kinds == {"byte"}:
            print(f"  {mode}: every channel reads back the byte written "
                  f"({len(considered)} in-range entries).")
        elif kinds == {"zero"}:
            print(f"  {mode}: every channel reads 0 "
                  f"({len(considered)} entries).")
        else:
            print(f"  {mode}: mixed readback {sorted(kinds)} - inspect the rows.")
    if rows["256"]:
        kinds = {kind for _, w, _, kind in rows["256"] if w != (0, 0, 0)}
        if kinds == {"byte"}:
            print("  256-colour: the read is real -> keep the pal256 mirror "
                  "(NP2kai's model); T69 is the only palette cut left.")
        elif kinds == {"zero"}:
            print("  256-colour: the machine answers 0 -> delete the pal256 "
                  "mirror, its three read registers and its 3 M10K with no "
                  "replacement (MAME's model). T68/T69 are then moot.")
        else:
            print("  256-colour: not a clean byte-or-zero answer; the printed "
                  "rows are the new evidence.")
    # 8-bit index test: 5A/A5 read back their own values only if the index is
    # unmasked; with a 4-bit index they alias 0A/05.
    if rows["256"]:
        d = {entry: (w, r) for entry, w, r, _ in rows["256"]}
        if 0x5A in d and 0xA5 in d:
            ok5a = d[0x5A][1] == d[0x5A][0] and any(d[0x5A][1])
            ok5b = d[0xA5][1] == d[0xA5][0] and any(d[0xA5][1])
            if ok5a and ok5b:
                print("  index: 5A and A5 return their own bytes -> the 256-colour "
                      "index is the full 8-bit 0xA8 value.")
            elif d[0x5A][1] == (0, 0, 0) and d[0xA5][1] == (0, 0, 0):
                print("  index: 5A and A5 read 0 (consistent with a masked index "
                      "or a write-only port).")
            else:
                print("  index: 5A/A5 do not both return their own bytes; "
                      "compare with entries 0A/05 before calling the index width.")
    if "END:PEGCRD" not in text:
        print("\n** capture has no END:PEGCRD: a mode section did not finish **")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""grcgpace_decode.py - the machine's GRCG store shapes beside the core's.

Usage:
    python3 tools/hwprobe/grcgpace/grcgpace_decode.py GRCGPACE.TXT

GRCGPACE (tools/hwprobe/grcgpace/grcgpace.s) times nine shapes, 65 536 stores
each, three runs, with the ARTIC counter (307 200 Hz):

    SHAPE=GRCG_RMW_D_LOOP MODE=C0 WIDTH=32 STORES=65536 RUN=1 ARTIC=... \
          NS_TOTAL=... NS_PER=125.000 NS_PER_WORD=62.500

NS_PER is ns per store as issued (a 32-bit store is one store); NS_PER_WORD is
the same divided by two, the number to compare with the machine's 16-bit rows
(GFX2.TXT's GRCG RMW 103.9 ns and TDW gross 183.3 ns; GFXB.TXT's plain word
store 142.0 ns). The decoder means the three runs and prints:

  * the machine table, with the run spread as a health check;
  * net costs: loop shapes minus CTRL_D_LOOP (loop shell) and GRCG shapes minus
    their plain control, so the GRCG expansion is separated from the host loop;
  * the core's own 80 MHz numbers from trade T68 / `tb_pc9821_gvram_store_pace`
    (112.5 -> 125.0 ns on the 32-bit RMW store, 137.5 -> 150.0 ns on the TDW
    dword burst) and the deltas.

The point of the capture is the two walk-bound shapes: the core is at 125.0 and
150.0 ns after T68; the machine's 16-bit row can only bound them (2 x 103.9 =
207.8 ns for the RMW dword, 183.3 ns for the TDW word). These rows put the
machine's actual 32-bit number beside them.

Nothing here talks to hardware; it is a pure text parser.
"""

from __future__ import annotations

import re
import statistics
import sys

LINE = re.compile(
    r"^SHAPE=(\S+) MODE=([0-9A-F]{2}) WIDTH=(\d+) STORES=(\d+) RUN=(\d+) "
    r"ARTIC=(\d+) NS_TOTAL=(\d+) NS_PER=([0-9.]+) NS_PER_WORD=([0-9.]+)\s*$")

# The core at 80 MHz, trade T68 / tb_pc9821_gvram_store_pace (P1a report):
CORE = {
    "PLAIN_W_LOOP": (137.5, 137.5, "plain 16-bit store, period-bound"),
    "GRCG_RMW_W_LOOP": (100.0, 100.0, "GRCG 16-bit RMW, period-bound"),
    "PLAIN_D_LOOP": (137.5, 137.5, "plain 32-bit store, period-bound"),
    "GRCG_RMW_D_LOOP": (112.5, 125.0, "GRCG 32-bit RMW, walk-bound"),
    "CTRL_D_LOOP": (0.0, 0.0, "loop shell, no store"),
    "PLAIN_W_REP": (0.0, 0.0, "rep stosw, GRCG off"),
    "TDW_W_REP": (0.0, 0.0, "GRCG TDW rep stosw"),
    "PLAIN_D_REP": (0.0, 0.0, "rep stosd, GRCG off"),
    "TDW_D_REP": (137.5, 150.0, "GRCG TDW 32-bit burst, walk-bound"),
}
MACHINE_ROWS = {
    "PLAIN_W_LOOP": "GFXB plain word 142.0",
    "GRCG_RMW_W_LOOP": "GFX2 GRCG RMW word 103.9",
    "PLAIN_D_LOOP": "none (2 x 142.0 = 284.0 if split)",
    "GRCG_RMW_D_LOOP": "none (2 x 103.9 = 207.8 if split)",
    "TDW_W_REP": "GFX2 TDW gross word 183.3",
    "TDW_D_REP": "none (2 x 183.3 = 366.6 if split)",
}


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    text = open(argv[1], "rb").read().decode("ascii", "replace")
    rows = {}
    for line in text.splitlines():
        m = LINE.match(line)
        if not m:
            continue
        tag = m.group(1)
        rows.setdefault(tag, []).append({
            "mode": m.group(2), "width": int(m.group(3)),
            "stores": int(m.group(4)), "run": int(m.group(5)),
            "artic": int(m.group(6)), "total": int(m.group(7)),
            "per": float(m.group(8)), "per_word": float(m.group(9)),
        })

    if not rows:
        print("no GRCGPACE rows found (is this the right capture?)")
        return 1

    print("== machine (3 runs, ns per store as issued) ==")
    print(f"{'shape':18s} {'w':>2s} {'ns/store':>10s} {'ns/16b':>9s} "
          f"{'spread':>8s}  reference")
    means = {}
    for tag, rs in rows.items():
        per = [r["per"] for r in rs]
        pw = [r["per_word"] for r in rs]
        mean = statistics.mean(per)
        means[tag] = mean
        spread = (max(per) - min(per)) / mean * 100 if mean else 0.0
        print(f"{tag:18s} {rs[0]['width']:2d} {mean:10.3f} "
              f"{statistics.mean(pw):9.3f} {spread:7.2f}%  "
              f"{MACHINE_ROWS.get(tag, '')}")
    print("  (ns/16b = the same row per 16-bit word equivalent: a 32-bit store "
          "counts as two)")

    print("\n== net of the loop shell / the plain control ==")
    def get(tag):
        return means.get(tag)
    if get("PLAIN_W_LOOP") and get("GRCG_RMW_W_LOOP"):
        print(f"  GRCG word overhead   {get('GRCG_RMW_W_LOOP') - get('PLAIN_W_LOOP'):+8.3f} ns/store "
              f"(RMW - plain word)")
    if get("CTRL_D_LOOP") is not None and get("PLAIN_D_LOOP"):
        print(f"  plain dword net      {get('PLAIN_D_LOOP') - get('CTRL_D_LOOP'):+8.3f} ns/store "
              f"(PLAIN_D - CTRL_D)")
    if get("CTRL_D_LOOP") is not None and get("GRCG_RMW_D_LOOP"):
        print(f"  GRCG dword net       {get('GRCG_RMW_D_LOOP') - get('CTRL_D_LOOP'):+8.3f} ns/store "
              f"(GRCG_RMW_D - CTRL_D)")
    if get("PLAIN_D_LOOP") and get("GRCG_RMW_D_LOOP"):
        print(f"  GRCG dword overhead  {get('GRCG_RMW_D_LOOP') - get('PLAIN_D_LOOP'):+8.3f} ns/store "
              f"(GRCG_RMW_D - PLAIN_D)")
    if get("PLAIN_W_REP") and get("TDW_W_REP"):
        print(f"  TDW word overhead    {get('TDW_W_REP') - get('PLAIN_W_REP'):+8.3f} ns/store "
              f"(TDW_W - PLAIN_W rep)")
    if get("PLAIN_D_REP") and get("TDW_D_REP"):
        print(f"  TDW dword overhead   {get('TDW_D_REP') - get('PLAIN_D_REP'):+8.3f} ns/store "
              f"(TDW_D - PLAIN_D rep)")

    print("\n== core at 80 MHz (T68 / tb_pc9821_gvram_store_pace) ==")
    print(f"{'shape':18s} {'pre-T68':>10s} {'post-T68':>10s}  machine delta")
    for tag in ("PLAIN_W_LOOP", "GRCG_RMW_W_LOOP", "PLAIN_D_LOOP",
                "GRCG_RMW_D_LOOP", "TDW_D_REP"):
        if tag not in means:
            continue
        pre, post, _ = CORE.get(tag, (0, 0, ""))
        print(f"{tag:18s} {pre:10.3f} {post:10.3f}  "
              f"{means[tag] - post:+8.3f} ns vs post")

    print("\n== verdict ==")
    if "GRCG_RMW_D_LOOP" in means and "GRCG_RMW_W_LOOP" in means:
        dw, ww = means["GRCG_RMW_D_LOOP"], means["GRCG_RMW_W_LOOP"]
        print(f"  GRCG RMW: machine {dw:.1f} ns/32-bit store "
              f"({dw / 2:.1f} ns/16-bit equivalent) against "
              f"{ww:.1f} ns for the 16-bit row.")
        if dw > 1.5 * ww:
            print("    -> the 32-bit store is split into two 16-bit GRCG "
                  "operations (near 2 x the word row).")
        elif dw < 1.2 * ww:
            print("    -> the 32-bit store is one 32-bit GRCG operation "
                  "(near the word row).")
        else:
            print("    -> in between; price it from the row, not a model.")
        _, post, _ = CORE["GRCG_RMW_D_LOOP"]
        print(f"    core post-T68 {post:.1f} ns is "
              f"{'BELOW' if post < dw else 'ABOVE'} the machine row by "
              f"{abs(post - dw):.1f} ns.")
    if "TDW_D_REP" in means and "TDW_W_REP" in means:
        dd, ww = means["TDW_D_REP"], means["TDW_W_REP"]
        print(f"  GRCG TDW: machine {dd:.1f} ns/32-bit store "
              f"({dd / 2:.1f} ns/16-bit equivalent) against "
              f"{ww:.1f} ns for the 16-bit row.")
        _, post, _ = CORE["TDW_D_REP"]
        print(f"    core post-T68 {post:.1f} ns is "
              f"{'BELOW' if post < dd else 'ABOVE'} the machine row by "
              f"{abs(post - dd):.1f} ns.")
    if "END:GRCGPACE" not in text:
        print("\n** capture has no END:GRCGPACE: a shape did not finish **")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

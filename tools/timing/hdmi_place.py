#!/usr/bin/env python3
"""Where the framework pll_hdmi cone and the clk_vid cluster sit in one fit.

    tools/timing/hdmi_place.py SEED_OUTPUT_FILES/hplace [--map] [--json]

Reads what tools/timing/hdmi_place.tcl (QUARTUS_POST_STA_TCL) wrote: every cell's location
(cells.txt.gz), the keepers each of the two clocks fans out to (regs_hdmi.txt, regs_vid.txt) and
the worst pll_hdmi setup paths (hdmi_paths.rpt summary, hdmi_worst.rpt full paths). Prints, per
group, the p5-p50-p95 spread of its registers on the X/Y grid; the X/Y span of each of the worst
paths' cells; and with --map a 2x2-bin map of the right-hand block under the HPS (X45-X89,
Y0-Y40) by dominant owner. --json prints the per-group numbers for tables.
"""
from __future__ import annotations

import collections
import gzip
import json
import re
import sys
from pathlib import Path

LOC_RE = re.compile(r"(\w+?)_X(\d+)_Y(\d+)")
# STA's keeper names carry entity:instance pairs; cell names carry instances only.
ENTITY_RE = re.compile(r"(^|\|)[^|:\[]+:")

HDMI_GROUPS = ("ascal", "hdmi_osd", "HDMI_shadowmask", "vga_scaler_out", "csync_hdmi")
VID_GROUPS = ("ascal", "emu", "vga_osd", "vga_out")
MAP_GROUPS = {
    "A": ("ascal|",),
    "O": ("hdmi_osd|", "HDMI_shadowmask|", "vga_scaler_out|", "csync_hdmi|"),
    "V": ("vga_osd|", "vga_out|", "emu|video_out|", "emu|video_cleaner|", "emu|hps_io|video_calc|",
          "emu|video_freak|", "emu|gamma|", "VGA_scanlines|", "csync_vga|", "sync_h|", "sync_v|",
          "ar_muldiv|"),
    "C": ("emu|core|cpu|",),
    "M": ("emu|core|memory|",),
}


def load(d: Path):
    loc: dict[str, tuple[str, int, int]] = {}
    for line in gzip.open(d / "cells.txt.gz", "rt"):
        where, _, name = line.rstrip("\n").partition(" ")
        m = LOC_RE.match(where)
        if m and name:
            loc[name] = (m.group(1), int(m.group(2)), int(m.group(3)))
    return loc


def keepers(d: Path, tag: str, loc) -> list[tuple[str, tuple[str, int, int]]]:
    out = []
    for line in open(d / f"regs_{tag}.txt"):
        name = ENTITY_RE.sub(r"\1", line.strip())
        if name in loc:
            out.append((name, loc[name]))
    return out


def spread(points) -> dict | None:
    if not points:
        return None
    xs = sorted(p[1][1] for p in points)
    ys = sorted(p[1][2] for p in points)
    q = lambda a, f: a[int(f * (len(a) - 1))]
    return {"n": len(points), "x": [q(xs, .05), q(xs, .5), q(xs, .95)],
            "y": [q(ys, .05), q(ys, .5), q(ys, .95)],
            "area": (q(xs, .95) - q(xs, .05) + 1) * (q(ys, .95) - q(ys, .05) + 1)}


def worst_paths(d: Path) -> list[dict]:
    """Each full path in hdmi_worst.rpt: its slack and the X/Y span of its LAB cells."""
    text = (d / "hdmi_worst.rpt").read_text(errors="replace")
    out = []
    for chunk in re.split(r"\n(?=; Slack\s)|\nPath #\d+", text):
        m = re.search(r"Slack\s*;\s*(-?\d+\.\d+)", chunk)
        cells = [(int(x), int(y)) for x, y in
                 re.findall(r"(?:LABCELL|MLABCELL|FF)_X(\d+)_Y(\d+)", chunk)]
        if m and cells:
            xs = [c[0] for c in cells]; ys = [c[1] for c in cells]
            out.append({"slack": float(m.group(1)), "dx": max(xs) - min(xs), "dy": max(ys) - min(ys),
                        "box": [min(xs), min(ys), max(xs), max(ys)]})
    return out


def corner_map(loc) -> list[str]:
    grid: dict = collections.defaultdict(collections.Counter)
    for name, (kind, x, y) in loc.items():
        if kind not in ("LABCELL", "MLABCELL") or x < 45 or y > 40:
            continue
        g = next((k for k, pres in MAP_GROUPS.items() if name.startswith(pres)), "x")
        grid[(x // 2, y // 2)][g] += 1
    rows = ["2x2 bins X45-89 Y0-40; A ascal, O hdmi_osd/shadowmask/scaler_out, V clk_vid "
            "helpers + VGA, C cpu, M memory, x other; lowercase = under half the bin"]
    for yb in range(20, -1, -1):
        row = ""
        for xb in range(22, 45):
            c = grid[(xb, yb)]
            if not c:
                row += " "
                continue
            g, n = c.most_common(1)[0]
            row += g if 2 * n >= sum(c.values()) else g.lower()
        rows.append(f"Y{yb * 2:2d} {row}")
    return rows


def analyse(d: Path) -> dict:
    loc = load(d)
    hdmi, vid = keepers(d, "hdmi", loc), keepers(d, "vid", loc)
    res = {"hdmi": spread(hdmi), "vid": spread(vid)}
    for g in HDMI_GROUPS:
        res[f"hdmi.{g}"] = spread([p for p in hdmi if p[0].startswith(g + "|")])
    for g in VID_GROUPS:
        res[f"vid.{g}"] = spread([p for p in vid if p[0].startswith(g + "|")])
    wp = worst_paths(d)
    res["worst_paths"] = len(wp)
    if wp:
        res["worst_dx_max"] = max(p["dx"] for p in wp)
        res["worst_dy_max"] = max(p["dy"] for p in wp)
        res["worst_first"] = wp[0]
    return res, loc


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 2
    d = Path(argv[0])
    res, loc = analyse(d)
    if "--json" in argv:
        print(json.dumps(res, sort_keys=True))
        return 0
    for k, v in res.items():
        if isinstance(v, dict) and "n" in v:
            print(f"{k:24s} n={v['n']:5d}  X {v['x'][0]:2d}-{v['x'][1]:2d}-{v['x'][2]:2d}  "
                  f"Y {v['y'][0]:2d}-{v['y'][1]:2d}-{v['y'][2]:2d}  p5-p95 box {v['area']} LAB sites")
    print(f"worst paths: {res['worst_paths']}, max span dx {res.get('worst_dx_max')} "
          f"dy {res.get('worst_dy_max')}; first {res.get('worst_first')}")
    if "--map" in argv:
        print("\n".join(corner_map(loc)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

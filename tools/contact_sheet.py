#!/usr/bin/env python3
"""contact_sheet.py DIR [--glob PATTERN] [--cols 8] [--thumb 160x100] [--out FILE]

A contact sheet of a directory of screenshots, for reading a hardware run at a glance: DIR/grid.png
holds every image (sorted by name) as a thumbnail with its index, and a line per image on stdout
gives the index, the name and the mean absolute difference to the previous image - the number
that finds the frame where the picture froze (a stalled run reads ~0.00 for every row after it)
or the one where it changed. Used by the debug-UART method (docs/mister-testing.md, the debug UART)
with tools/mister_capture.sh's screenshot loop.

The MiSTer names its screenshots with a date prefix (`2026...`), which is the default glob; pass
--glob '*.png' for anything else. Needs Pillow.

Usage:  contact_sheet.py DIR [--glob '2*.png'] [--cols 8] [--thumb 160x100] [--out DIR/grid.png]
        contact_sheet.py --selftest
"""
from __future__ import annotations

import argparse
import glob
import os
import sys
import tempfile


def build(paths, cols, thumb, out, log=print):
    from PIL import Image, ImageChops, ImageDraw, ImageStat
    w, h = thumb
    rows = max(1, (len(paths) + cols - 1) // cols)
    sheet = Image.new("RGB", (w * cols, h * rows))
    prev, diffs = None, []
    for i, path in enumerate(paths):
        im = Image.open(path).convert("RGB")
        d = sum(ImageStat.Stat(ImageChops.difference(im, prev.resize(im.size))).mean) / 3 if prev is not None else 0.0
        diffs.append(d)
        log(f"{i} {os.path.basename(path)} {d:.2f}")
        prev = im
        t = im.resize((w, h))
        ImageDraw.Draw(t).text((2, 2), str(i), fill=(255, 255, 0))
        sheet.paste(t, ((i % cols) * w, (i // cols) * h))
    sheet.save(out)
    return diffs


def selftest() -> int:
    from PIL import Image
    with tempfile.TemporaryDirectory() as d:
        for i, shade in enumerate((10, 10, 10, 200, 200)):
            Image.new("RGB", (64, 40), (shade, shade, shade)).save(os.path.join(d, f"2026-{i}.png"))
        paths = sorted(glob.glob(os.path.join(d, "2*.png")))
        diffs = build(paths, 4, (32, 20), os.path.join(d, "grid.png"), log=lambda *_: None)
        ok = (len(diffs) == 5 and diffs[1] == 0 and diffs[2] == 0 and diffs[3] > 100 and diffs[4] == 0
              and os.path.getsize(os.path.join(d, "grid.png")) > 0)
        print("contact_sheet.py --selftest:", "PASS" if ok else f"FAIL {diffs}")
        return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir", nargs="?")
    ap.add_argument("--glob", default="2*.png")
    ap.add_argument("--cols", type=int, default=8)
    ap.add_argument("--thumb", default="160x100")
    ap.add_argument("--out")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.dir:
        ap.error("a directory of screenshots is required")
    paths = sorted(glob.glob(os.path.join(a.dir, a.glob)))
    if not paths:
        print(f"no files match {os.path.join(a.dir, a.glob)}", file=sys.stderr)
        return 1
    w, _, h = a.thumb.partition("x")
    out = a.out or os.path.join(a.dir, "grid.png")
    build(paths, a.cols, (int(w), int(h)), out)
    print(f"wrote {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Decode a CRT31K.TXT capture: frame rate, line rate and dot clock per mode.

    python3 tools/hwprobe/crt31k/crt31k_decode.py CRT31K.TXT

Each `RUN frames=N ticks=T` line under a `MODE ... htotal_dots=H vtotal=V` header gives
    frame Hz = artic_hz * N / T,  line Hz = frame Hz * V,  dot Hz = line Hz * H.
The ARTIC resolution is one tick in T (~3 ppm at T ~ 300 000), and the ARTIC's own crystal
tolerance applies to every number; the 24 kHz rows calibrate it against the known
21 052 600 Hz nominal dot clock (NP2kai io/gdc.c `21052600 / 8`, MAME pc9821.cpp
`XTAL(21'052'600)`), and the calibrated 31 kHz figure is printed beside the raw one.
"""
import re
import sys

NOMINAL_24K_DOT = 21_052_600


def decode(text):
    artic = 307200
    m = re.search(r"artic_hz=(\d+)", text)
    if m:
        artic = int(m.group(1))
    modes = []
    cur = None
    for line in text.splitlines():
        m = re.match(r"MODE (\S+) htotal_dots=(\d+) vtotal=(\d+)\s*(.*)", line)
        if m:
            cur = {"name": f"{m.group(1)} {m.group(4)}".strip(), "h": int(m.group(2)),
                   "v": int(m.group(3)), "runs": [], "timeouts": 0}
            modes.append(cur)
            continue
        m = re.match(r"RUN frames=(\d+) ticks=(\d+)", line)
        if m and cur is not None:
            cur["runs"].append((int(m.group(1)), int(m.group(2))))
        elif line.startswith("RUN TIMEOUT") and cur is not None:
            cur["timeouts"] += 1
    return artic, modes


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    text = open(argv[1], "rb").read().decode("ascii", "replace")
    artic, modes = decode(text)
    cal = None
    for md in modes:
        dots = []
        for n, t in md["runs"]:
            fv = artic * n / t
            dots.append(fv * md["v"] * md["h"])
            print(f"{md['name']:28s} frames={n:3d} ticks={t:7d}  frame {fv:9.4f} Hz  "
                  f"line {fv * md['v']:10.2f} Hz  dot {fv * md['v'] * md['h']:12.0f} Hz")
        if md["timeouts"]:
            print(f"{md['name']:28s} {md['timeouts']} run(s) TIMED OUT (no VSYNC edge)")
        if dots:
            mean = sum(dots) / len(dots)
            md["dot"] = mean
            print(f"{md['name']:28s} mean dot {mean:12.0f} Hz")
            if md["name"].startswith("24K") and cal is None:
                cal = NOMINAL_24K_DOT / mean
    for md in modes:
        if md["name"].startswith("31K") and "dot" in md:
            print(f"\n31 kHz dot clock: {md['dot']:.0f} Hz raw"
                  + (f", {md['dot'] * cal:.0f} Hz calibrated by the 24 kHz rows "
                     f"(ARTIC factor {cal:.7f})" if cal else ""))
            print("  references: VGA 25 175 000 Hz; NP2kai io/gdc.c gdcclk[2] 25 260 000 Hz")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""Decode a CRT31K.TXT capture: frame rate, line rate and dot clock per mode.

    python3 tools/hwprobe/crt31k/crt31k_decode.py CRT31K.TXT
    python3 tools/hwprobe/crt31k/crt31k_decode.py --selftest

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
# The calibrating 24 kHz rows must agree with each other: one ARTIC tick in T ~ 326 700 is ~3 ppm,
# so rows more than a few ticks apart are not one steady mode (a hung or partial run) and the
# factor they give is flagged.
CAL_SPREAD_PPM = 10.0


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


def selftest():
    import contextlib
    import io
    import os
    import tempfile
    good = ("CRT31K artic_hz=307200\nMODE 24K htotal_dots=848 vtotal=440 (as found)\n"
            "RUN frames=60 ticks=326700\nRUN frames=60 ticks=326698\n"
            "MODE 31K htotal_dots=800 vtotal=449\nRUN frames=70 ticks=306930\n")
    bad = good.replace("ticks=326698", "ticks=326000") + "RUN frames=70 ticks=0\n"
    outs = []
    for t in (good, bad):
        with tempfile.NamedTemporaryFile("w", suffix=".TXT", delete=False) as f:
            f.write(t)
        o = io.StringIO()
        with contextlib.redirect_stdout(o):
            rc = main(["crt31k_decode.py", f.name])
        os.unlink(f.name)
        outs.append((rc, o.getvalue()))
    assert outs[0][0] == 0 and "spread" not in outs[0][1] and "calibrated" in outs[0][1], outs[0]
    assert outs[1][0] == 0 and "spread" in outs[1][1] and "row void" in outs[1][1], outs[1]
    print("crt31k_decode selftest: PASS")
    return 0


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest()
    if len(argv) != 2:
        print(__doc__)
        return 2
    text = open(argv[1], "rb").read().decode("ascii", "replace")
    artic, modes = decode(text)
    cal = None
    for md in modes:
        dots = []
        for n, t in md["runs"]:
            if t == 0 or n == 0:
                print(f"{md['name']:28s} frames={n:3d} ticks={t:7d}  row void (no time elapsed)")
                continue
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
                spread = (max(dots) - min(dots)) / mean * 1e6
                if spread > CAL_SPREAD_PPM:
                    print(f"{md['name']:28s} ** the calibrating rows spread {spread:.1f} ppm"
                          f" (> {CAL_SPREAD_PPM:.0f}): not one steady mode, the factor is suspect")
    for md in modes:
        if md["name"].startswith("31K") and "dot" in md:
            print(f"\n31 kHz dot clock: {md['dot']:.0f} Hz raw"
                  + (f", {md['dot'] * cal:.0f} Hz calibrated by the 24 kHz rows "
                     f"(ARTIC factor {cal:.7f})" if cal else ""))
            print("  references: VGA 25 175 000 Hz; NP2kai io/gdc.c gdcclk[2] 25 260 000 Hz")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

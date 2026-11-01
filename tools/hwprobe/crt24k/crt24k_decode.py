#!/usr/bin/env python3
"""crt24k_decode.py - cross-check a CRT24K capture's two time bases.

Usage:
    python3 tools/hwprobe/crt24k/crt24k_decode.py CRT24K.TXT

CRT24K (tools/hwprobe/crt24k/crt24k.s) times the same 60-frame VSYNC window
against the ARTIC counter (307 200 Hz) and against PIT channel 0 in each run:

    PIT measured_top=FFF7 mod=65536 hz=2457600 ratio_milli=7919 x2=0
          strap0501=24
    RUN=1 frames=60 artic=326674 pit=2613388 pit_ok=1 pit_mod=65536 \
          pit_raw=8052 pit_expected=2613392 artic_fps=56.4232 pit_fps=56.4233 \
          artic_frame_ns=17723198.7 pit_frame_ns=17723171.6

`measured_top` is the largest latched word over 30 ms; `mod` is the counting
modulus it names (65536 = a free-running 16-bit counter, as this core's
profile-0 image reads; 24576/19968 = the Xe10's 0x6000/0x4E00 divisor;
49152/39936 = the 8253 mode-3 2*count element at those divisors), `hz` the
base rate, `ratio_milli` the short-window element counts per ARTIC tick
(~8.0 Xe10 / ~16.0 for the 2*count element) and `x2` that convention. The
RUN's `pit`/`pit_raw`/`pit_expected` are in SOURCE counts at `hz`, so the frame
rate is `hz * frames / pit` on either convention.

The two references are sampled at the same rising VSYNC edges (both counters are
latched immediately after the edge in the same code path), so their noise is
independent. The decoder prints, per run, each reference's frame rate and its
ppm from the 24 kHz nominal (21 052 600 / 848 / 440 = 56.4232 Hz), plus the
PIT-vs-ARTIC difference:

  * a few ppm between PIT and ARTIC means both counters agree on the frame, and
    the ppm from nominal is the frame itself (the crash-free case);
  * a difference between the two means one counter/reference is off on that
    machine, and the ARTIC-only number `crt31k` reports cannot attribute it.

The core-side comparison is `crt31k` on a card: 326 672-326 675 ARTIC ticks per
60 frames in the 24 kHz mode (the model's 326 674.0), against the Xe10 capture's
326 698-326 700 (docs/probes/CRT31K.TXT), ~77 ppm apart. (A 2026-10-17 report of
326 872-326 875 on a card was the screenshot font's 6 misread as an 8.) This probe
supplies the Xe10's second-reference row that decides whether those ~77 ppm are
the Xe10's frame or its ARTIC crystal.

Nothing here talks to hardware; it is a pure text parser.
"""

from __future__ import annotations

import re
import sys

ARTIC_HZ = 307_200
NOMINAL_HZ = 21_052_600 / (848 * 440)     # 56.4232... Hz

MODE = re.compile(r"^MODE 24K 09A8=([0-9A-F]{2})\s*$")
DIV = re.compile(r"^PIT measured_top=([0-9A-F]+) mod=(\d+) hz=(\d+) "
                 r"ratio_milli=(\d+) x2=(\d+) strap0501=([0-9A-F]{2})\s*$")
RUN = re.compile(
    r"^RUN=(\d+) frames=(\d+) artic=(\d+) pit=(\d+) pit_ok=(\d+) "
    r"pit_mod=(\d+) pit_raw=(\d+) pit_expected=(\d+) "
    r"artic_fps=([0-9.]+) pit_fps=([0-9.]+) "
    r"artic_frame_ns=([0-9.]+) pit_frame_ns=([0-9.]+)\s*$")


def ppm(v):
    return (v / NOMINAL_HZ - 1.0) * 1e6


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    text = open(argv[1], "rb").read().decode("ascii", "replace")
    mode = div = None
    runs = []
    for line in text.splitlines():
        m = MODE.match(line)
        if m:
            mode = m.group(1)
            continue
        m = DIV.match(line)
        if m:
            div = (m.group(1), int(m.group(2)), int(m.group(3)),
                   int(m.group(4)), int(m.group(5)), m.group(6))
            continue
        m = RUN.match(line)
        if m:
            runs.append({
                "run": int(m.group(1)), "frames": int(m.group(2)),
                "artic": int(m.group(3)), "pit": int(m.group(4)),
                "ok": int(m.group(5)), "mod": int(m.group(6)),
                "raw": int(m.group(7)), "expected": int(m.group(8)),
                "afps": float(m.group(9)), "pfps": float(m.group(10)),
                "ans": float(m.group(11)), "pns": float(m.group(12)),
            })

    print(f"nominal 24 kHz frame = {NOMINAL_HZ:.4f} Hz "
          f"(21 052 600 / 848 / 440)")
    if mode is not None:
        print(f"as-found 0x09A8 = {mode} (bit 0 clear = 24 kHz)")
    if div is not None:
        print(f"PIT measured top = 0x{div[0]}, counting modulus {div[1]} "
              f"at {div[2]} Hz; short-window element/ARTIC ratio "
              f"{div[3] / 1000:.3f} (x2={div[4]}); work-area 0501 = {div[5]} "
              f"(bit 7 {'set' if int(div[5], 16) & 0x80 else 'clear'})")
        print("  (modulus 65536 = a free-running 16-bit counter, as this core's "
              "profile-0 image reads; 24576/19968 = the Xe10's 0x6000/0x4E00; "
              "49152/39936 = the 2x mode-3 element at those divisors)")
    if not runs:
        print("no CRT24K RUN rows found (is this the right capture?)")
        return 1

    print("\nrun  artic_ticks  artic_fps  ppm_artic   pit_counts  pit_fps  "
          "ppm_pit  pit-vs-artic")
    for r in runs:
        # Recompute from the raw counts: the probe's printed values are a
        # convenience, not the evidence.
        afps = ARTIC_HZ * r["frames"] / r["artic"]
        div_hz = int(div[2]) if div else 2_457_600
        valid = bool(r["ok"] and r["pit"])
        pfps = div_hz * r["frames"] / r["pit"] if valid else 0.0
        cross = (pfps / afps - 1.0) * 1e6 if valid else 0.0
        pfs = f"{pfps:8.4f}" if valid else "     n/a"
        pps = f"{ppm(pfps):+8.1f}" if valid else "     n/a"
        crs = f"{cross:+9.1f}" if valid else "      n/a"
        print(f"{r['run']:3d}  {r['artic']:11d}  {afps:9.4f}  {ppm(afps):+9.1f}  "
              f"{r['pit']:11d}  {pfs}  {pps}  {crs}")

    afps = [ARTIC_HZ * r["frames"] / r["artic"] for r in runs]
    div_hz = int(div[2]) if div else 2_457_600
    pfps = [div_hz * r["frames"] / r["pit"] for r in runs if r["ok"] and r["pit"]]
    mean_a = sum(afps) / len(afps)
    if not pfps:
        print("\n** no PIT rows were coherent (pit_ok=0): only the ARTIC column "
              "is evidence **")
        print(f"mean ARTIC frame {mean_a:.5f} Hz ({ppm(mean_a):+.1f} ppm)")
        return 1 if "END:CRT24K" not in text else 0
    mean_p = sum(pfps) / len(pfps)
    print(f"\nmean ARTIC frame {mean_a:.5f} Hz ({ppm(mean_a):+.1f} ppm), "
          f"spread {max(afps) - min(afps):.5f} Hz")
    print(f"mean PIT   frame {mean_p:.5f} Hz ({ppm(mean_p):+.1f} ppm), "
          f"spread {max(pfps) - min(pfps):.5f} Hz")
    print(f"PIT vs ARTIC mean difference {((mean_p / mean_a) - 1.0) * 1e6:+.1f} ppm")

    print("\n== verdict ==")
    diff = abs((mean_p / mean_a) - 1.0) * 1e6
    if diff < 20:
        print(f"  the two references agree to {diff:.1f} ppm: the frame itself "
              f"is {ppm(mean_a):+.1f} ppm from nominal on this machine.")
        print("  Compare this with the other machine's crt31k row: a difference "
              "between the machines is the frame, not the ARTIC, because both "
              "references here say the same thing.")
    else:
        print(f"  the references DISAGREE by {diff:.1f} ppm: one of them is "
              f"off on this machine. Do not read the ARTIC-only row as the "
              f"frame's error until the disagreement is attributed.")
    if "END:CRT24K" not in text:
        print("\n** capture has no END:CRT24K: a run did not finish **")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

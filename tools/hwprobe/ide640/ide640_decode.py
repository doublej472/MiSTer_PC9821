#!/usr/bin/env python3
"""ide640_decode.py - decode an IDE640 capture (tools/hwprobe/ide640/ide640.s): 0x0640/0x0641 per
bank and device, beside the core's answer and the earlier machine captures.

    ide640_decode.py CAPTURE [CAPTURE2]   one capture, or two (core first, then the machine)
    ide640_decode.py --selftest

THE PREDICTIONS for 0x0641 (the data port's odd byte):
  core-old     00 on every row (this tree; the k0-run1 core run read 00 on both banks, both devices)
  core-fix     the core with the 0x0641 fix (`ATA 0x0641 reads 0xFF with BSY and DRQ clear`):
               FF on the live bank (01) with device 0 selected and BSY/DRQ clear, the only state
               the captures cover; 00 elsewhere, including the idle bank
               (00), which no capture decides
  the machine  as found at a DOS prompt, bank 00: FF (docs/probes/KIT1-XE10-IDEPROBE.TXT:8
               `0640=06 0641=FF`); live bank 01, device 0: FF (:21 `0640=50 0641=FF`)
0x0640 is printed beside the machine's captured as-found byte (bank 00: 06; bank 01: 50/51); both
cores read 00 there (0x0640 is not changed by the fix).
"""
from __future__ import annotations

import re
import sys

ROW = re.compile(r"^IDE bank=(\w\w) dh=(\S+) r640=(\w\w) r641=(\w\w) (\w\w) r64E=(\w\w) r64C=(\w\w)")
CAPTURED_640 = {"00": "06", "01": "50/51"}


def parse(text):
    rows, rest, done = [], None, False
    for raw in text.splitlines():
        line = raw.strip()
        m = ROW.match(line)
        if m:
            rows.append(m.groups())
        elif line.startswith("RESTORE"):
            rest = line
        elif line == "IDE640 DONE":
            done = True
    return rows, rest, done


def core_641(bank, dh, st, fix):
    if not fix:
        return "00"
    dev0 = dh == "--" or not (int(dh, 16) & 0x10)      # "--": the as-found 064C (A0 or A3 here)
    return "FF" if bank == "01" and dev0 and not (int(st, 16) & 0x88) else "00"


def report(cap):
    rows, rest, done = cap
    out = ["bank dh  r640 (captured asf) r641 x2 r64E r64C | core-old core-fix -> agrees with"]
    for bank, dh, r640, a, b, st, dhr in rows:
        o, f = core_641(bank, dh, st, False), core_641(bank, dh, st, True)
        agree = [n for n, p in (("core-old", o), ("core-fix", f)) if a == b == p]
        if bank in ("00", "01") and dh in ("--", "A0") and a == "FF":
            agree.append("machine-asf")
        v = ", ".join(agree) if agree else ("UNSTABLE" if a != b else "NEITHER")
        out.append("%-4s %-3s %-4s (%-5s)         %s %s   %s   %s  | %-8s %-8s -> %s" % (
            bank, dh, r640, CAPTURED_640.get(bank, "-"), a, b, st, dhr, o, f, v))
    out.append(rest or "RESTORE missing")
    if not done:
        out.append("NOT DONE")
    return out


def selftest():
    def cap(fix):
        return "\r\n".join(["IDE640 v1"] + ["IDE bank=%s dh=%s r640=00 r641=%s %s r64E=%s r64C=A0" % (
            b, d, core_641(b, d, st, fix), core_641(b, d, st, fix), st)
            for b in ("00", "01") for d, st in (("--", "50"), ("A0", "50"), ("B0", "00"))] +
            ["RESTORE 0432 was=00 now=00", "IDE640 DONE"])
    a = report(parse(cap(False)))
    b = report(parse(cap(True)))
    ok = (sum("core-old" in x.split(" -> ")[-1] for x in a[1:7]) == 6 and
          sum("core-fix" in x.split(" -> ")[-1] for x in b[1:7]) == 6 and
          sum("core-old" in x.split(" -> ")[-1] for x in b[1:7]) == 4)
    print("selftest: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main(argv):
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) not in (2, 3):
        print(__doc__)
        return 2
    for p in argv[1:]:
        print("==== " + p)
        print("\n".join(report(parse(open(p, "rb").read().decode("ascii", "replace")))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""picrot_decode.py - decode a PICROT capture (tools/hwprobe/picrot/picrot.s): which of IR0 (INT 08h)
and IR2 (INT 0Ah) the master 8259 delivers first after each OCW2 sequence, against each reference.

    picrot_decode.py CAPTURE [CAPTURE2]   one capture, or two (core first, then the machine)
    picrot_decode.py --selftest

THE PREDICTIONS (the first vector; 08 = pry 0, 0A = pry 1 or 2):
  row   8259A data sheet  QEMU i8259.c  NP2kai io/pic.c  MAME pic8259.cpp  this RTL (pc9821_pic.sv)
  R0    08                08            08               08                08          (the control)
  RA    08                08            08               0A                08          (80h, ISR empty)
  RB    08                08            0A               0A                0A          (80h, IR0 in service)
  RC0   0A                0A            0A               0A                0A          (C1h: the control)
  RC    0A                0A            0A               08                0A          (C1h then 00h)
The data sheet: 80h sets the rotate-in-AEOI mode and does not move the pointer, 00h clears it.
QEMU: `s->rotate_on_auto_eoi = cmd >> 2;` (i8259.c:258-261). NP2kai: 80h rotates past the
first in-service level only when the ISR is non-empty (pic.c:291-310). MAME: 80h steps the
pointer by one (pic8259.cpp:305-306) and 00h resets it to 0 (:285). The RTL: NP2kai's rotate, plus
the AEOI mode. RA and RB together separate the data sheet/QEMU, NP2kai/RTL and MAME.
"""
from __future__ import annotations

import re
import sys

REFS = ("datasheet", "QEMU", "NP2kai", "MAME", "RTL")
PRED = {"R0": ("08", "08", "08", "08", "08"), "RA": ("08", "08", "08", "0A", "08"),
        "RB": ("08", "08", "0A", "0A", "0A"), "RC0": ("0A", "0A", "0A", "0A", "0A"),
        "RC": ("0A", "0A", "0A", "08", "0A")}
ROW = re.compile(r"^ROW (\w+)\s+tr=(\w+) irr=(\w+) order= (.*?)n=(\w+) pre=(\w+) tmo=(\w+)")


def parse(text: str) -> dict:
    cap = {"rows": [], "state": None, "restore": None, "done": False}
    for raw in text.splitlines():
        line = raw.strip()
        m = ROW.match(line)
        if m:
            name, tr, irr, order, n, pre, tmo = m.groups()
            cap["rows"].append({"name": name, "tr": tr, "irr": irr, "order": order.split(),
                                "n": int(n, 16), "pre": pre, "tmo": int(tmo, 16)})
        elif line.startswith("STATE "):
            cap["state"] = line
        elif line.startswith("RESTORE "):
            cap["restore"] = line
        elif line == "PICROT DONE":
            cap["done"] = True
    return cap


def report(cap) -> list:
    out = [cap["state"] or "STATE missing"]
    out.append("row  tr  irr  order        | " + " ".join("%-9s" % r for r in REFS) + " -> agrees with")
    by = {}
    for r in cap["rows"]:
        first = r["order"][0] if r["order"] else None
        p = PRED.get(r["name"])
        if r["tmo"] or first is None or p is None:
            v = "VOID (tmo=%X: 2 = IRR never showed both, 4 = fewer than two vectors; pre=%s)" % (r["tmo"], r["pre"])
        else:
            v = ", ".join(ref for ref, x in zip(REFS, p) if x == first) or "NONE"
        by.setdefault(r["name"], []).append(first)
        out.append("%-4s %-3s %-4s %-12s | %s -> %s" % (
            r["name"], r["tr"], r["irr"], " ".join(r["order"]) or "-",
            " ".join("%-9s" % x for x in (p or ("?",) * 5)), v))
    for name, firsts in by.items():
        if len(set(firsts)) > 1:
            out.append("  %s: the trials DISAGREE (%s)" % (name, " ".join(str(f) for f in firsts)))
    ra = by.get("RA", [None])[0]
    rb = by.get("RB", [None])[0]
    if ra and rb:
        model = {("08", "08"): "the data sheet / QEMU (the pointer never moves on 80h)",
                 ("08", "0A"): "NP2kai / this RTL (80h rotates only with a level in service)",
                 ("0A", "0A"): "MAME (80h always steps the pointer)"}.get((ra, rb), "none of the references")
        out.append("verdict (RA, RB) = (%s, %s): %s" % (ra, rb, model))
    out.append(cap["restore"] or "RESTORE missing")
    if not cap["done"]:
        out.append("NOT DONE")
    return out


def plant(ref: str) -> str:
    i = REFS.index(ref)
    L = ["PICROT v1", "STATE imr=7D isr=00 irr=00 pit0st=B0 periodic=00"]
    for name in ("R0", "RA", "RB", "RC0", "RC"):
        f = PRED[name][i]
        s = "0A" if f == "08" else "08"
        for tr in (1, 2, 3):
            L.append("ROW %-3s tr=%02X irr=05 order= %s %s n=02 pre=%s tmo=00" % (
                name, tr, f, s, "01" if name == "RB" else "FF"))
    L += ["RESTORE IMR was=7D now=7D vectors OK", "PICROT DONE"]
    return "\r\n".join(L) + "\r\n"


def selftest() -> int:
    bad = 0
    for ref in REFS:
        rep = report(parse(plant(ref)))
        rows = [ln for ln in rep if " -> " in ln and not ln.startswith("row")]
        if len(rows) != 15 or not all(ref in ln.split(" -> ")[1] for ln in rows):
            print("selftest %s: %s" % (ref, rows))
            bad += 1
    want = {"datasheet": "data sheet", "NP2kai": "NP2kai", "MAME": "MAME"}
    for ref, w in want.items():
        if not any(ln.startswith("verdict") and w in ln for ln in report(parse(plant(ref)))):
            bad += 1
    print("selftest: %s" % ("PASS" if not bad else "FAIL"))
    return 1 if bad else 0


def main(argv) -> int:
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

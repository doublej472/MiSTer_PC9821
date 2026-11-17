#!/usr/bin/env python3
"""opnax_decode.py - decode OPNAX captures (tools/hwprobe/opnax/opnax.s): /G (OPNAXG.TXT) the 0x29
gate of the ADPCM flags, /J (OPNAXJ.TXT) 0x0E against 0x0F.

    opnax_decode.py CAPTURE [CAPTURE...]   any mix of /G and /J captures
    opnax_decode.py --selftest

/G PREDICTIONS (see gate_pred and timer_base for the core's own columns, from the k0-run1 core run;
IRQ12 deliveries while 40 bytes are written in ADPCM-B memory-write mode, 0x110 =
00, the handler resetting the flags so each new flag is a new request; EOS sets after byte 32 on
the Xe10, docs/probes/XE10T-XE10-OPNA2.TXT ADB_W i=32 `st=0C`):
  GATE     the core, qemu fmopn.c YM2608IRQMaskWrite, ymfm set_irq_mask(m_irq_enable & ...):
           0x29 = 00: none; 04 (EOS): about 1; 08 (BRDY): about one per byte; 10 (ZERO): none;
           1F: BRDY's count plus EOS's
  NO-GATE  0x29 does not gate the ADPCM flags (as ym29 found for the timers on the Xe10,
           docs/probes/YM29B-XE10.TXT): every 0x29 value gives the 1F row's count
  NP2kai   never raises an ADPCM interrupt: no deliveries for any value
/J PREDICTIONS (0x0E with a pad button held; FF with none):
  NP2kai fmboard_getjoy and the core: the pad while 0x0F bit 6 is clear (80 and 00), FF for C0, 40
  MAME's -86: the pad only while (0x0F & C0) == 80, so FF for 00 as well
"""
from __future__ import annotations

import re
import sys

GROW = re.compile(r"^GATE r29=(\w\w) irqs=(\w+) isr_st=(\w\w) st0=(\w\w) st_end=(\w\w) irr_end=(\w\w) irr_rst=(\w\w) brdy_to=(\w\w)")
JROW = re.compile(r"^JOY hold=(\w\w) r0f<-(\w\w) r0e=(\w\w) (\w\w)")


def parse(text):
    cap = {"gate": [], "joy": [], "lines": [ln.strip() for ln in text.splitlines()]}
    for line in cap["lines"]:
        m = GROW.match(line)
        if m:
            g = m.groups()
            cap["gate"].append({"v": g[0], "n": int(g[1], 16), "isr_st": g[2], "st_end": g[4],
                                "irr_end": g[5], "irr_rst": g[6], "bto": int(g[7], 16)})
        m = JROW.match(line)
        if m:
            cap["joy"].append(m.groups())
    cap["done"] = "OPNAX DONE" in cap["lines"]
    return cap


CAP = 200      # opnax.s isr12 masks IR12 after 200 deliveries


def timer_base(rows) -> int:
    """deliveries owed to the OPNA timer flags, not to ADPCM: the 00 row's count when its handler
    saw a timer flag (isr_st bit 0 or 1). In this core the timer interrupt is NOT gated by 0x29
    (src/opna/jt12/hdl/jt12_top.v:660 `assign irq_n = ~( (flag_A&host_tmr[2]&flag_mask[0]) |
    (flag_B&host_tmr[3]&flag_mask[1]) | ...`, irq_mask only on [4:2]) and the firmware leaves
    the timer flags set (k0-run1 STATE `st188=03`), so a request is already latched when a row
    unmasks IR12: one delivery whatever 0x29 holds (k0-run1: 00 and 10 read 1 with isr_st 09,
    timer A plus BRDY). The line is down again by the row's end (irr_end 00), so no second edge
    follows from it; ZERO (0x29 = 10) is never raised by a memory write."""
    for r in rows:
        if r["v"] == "00" and int(r["isr_st"], 16) & 0x03:
            return r["n"]
    return 0


def gate_model(rows):
    by = {r["v"]: r["n"] for r in rows}
    if not by:
        return None
    base = timer_base(rows)
    x = {v: max(0, n - base) for v, n in by.items()}
    storm = [v for v, n in by.items() if n >= CAP]
    if storm and set(storm) <= {"08", "1F"} and x.get("00", 0) == 0 and x.get("10", 0) == 0:
        return ("BRDY-STORM at the %d cap for 0x29 = %s, 00/10 at the timer baseline %d "
                "(core-old: the vendored jt08 re-sets BRDY whenever its memory port is idle, "
                "the vendored ADPCM-B unit re-sets BRDY whenever idle; the line never drops, irr_end = 10) - GATED otherwise" % (
                    CAP, "/".join(sorted(storm)), base))
    if all(n == 0 for n in by.values()):
        return "NONE (NP2kai: no ADPCM interrupt at all; or IR12 not wired to the extension)"
    if x.get("00", 0) == 0 and x.get("10", 0) == 0 and x.get("08", 0) >= 8 and x.get("1F", 0) >= 8:
        return "GATE (the core-fix, qemu, ymfm; timer baseline %d subtracted)" % base
    full = by.get("1F", 0)
    if full and all(abs(n - full) <= max(3, full // 5) for n in by.values()):
        return "NO-GATE (0x29 does not gate the ADPCM flags)"
    return "OTHER"


def gate_pred(v, base):
    """(core-old, core-fix) deliveries for one 0x29 value, the timer baseline included.
    core-old (the core before the ADPCM-B memory-write fix): EOS never sets in the 40-byte write
    (status read 08 for all 40 bytes), BRDY re-sets whenever idle -> the cap.
    core-fix (the core with the ADPCM-B memory-write and BRDY fixes): EOS after the 32nd byte,
    BRDY once per byte (about 40)."""
    old = {"00": str(base), "04": "%d-%d" % (base, base + 1), "08": "%d(cap)" % CAP,
           "10": str(base), "1F": "%d(cap)" % CAP}.get(v, "?")
    fix = {"00": str(base), "04": "%d" % (base + 1), "08": "~%d" % (base + 40),
           "10": str(base), "1F": "~%d" % (base + 41)}.get(v, "?")
    return old, fix


def joy_pred(sel, held):
    pad = "pad" if held else "FF"
    return ("FF" if sel & 0x40 else pad), (pad if sel == 0x80 else "FF")


def report(cap):
    out = []
    if cap["gate"]:
        base = timer_base(cap["gate"])
        out.append("GATE r29 irqs | core-old core-fix | isr_st st_end irr_end irr_rst brdy_to")
        for r in cap["gate"]:
            po, pf = gate_pred(r["v"], base)
            out.append("  %s   %4d%s | %-8s %-8s | %s     %s     %s      %s      %d" % (
                r["v"], r["n"], " STORM" if r["n"] >= CAP else "      ", po, pf, r["isr_st"], r["st_end"],
                r["irr_end"], r["irr_rst"], r["bto"]))
        out.append("  timer baseline %d (the 00 row's delivery with a timer flag in isr_st: a timer request "
                   "already latched, ungated by 0x29 in this core)" % base)
        out.append("  verdict: %s" % gate_model(cap["gate"]))
    if cap["joy"]:
        out.append("JOY hold r0f r0e x2 | NP2kai/core  MAME -> agrees with")
        for hold, sel, a, b in cap["joy"]:
            held = hold != "00"
            np2, mame = joy_pred(int(sel, 16), held)
            got = "FF" if a == "FF" else "pad"
            agree = [n for n, p in (("NP2kai/core", np2), ("MAME", mame)) if p == got]
            out.append("  %s   %s  %s %s | %-11s  %-4s -> %s%s" % (
                hold, sel, a, b, np2, mame, ", ".join(agree) or "NONE", "" if a == b else " (UNSTABLE)"))
        if all(r[2] == "FF" for r in cap["joy"] if r[0] != "00"):
            out.append("  note: every held row reads FF: no pad answered (or the button was not held)")
    if any(ln.startswith("JOY SKIP") for ln in cap["lines"]):
        out.append("JOY skipped at a prompt")
    out += [ln for ln in cap["lines"] if ln.startswith("RESTORE")]
    if not cap["done"]:
        out.append("NOT DONE")
    return out


def selftest():
    def gate(counts):
        return "\r\n".join(["GATE r29=%s irqs=%04X isr_st=0C st0=00 st_end=08 irr_end=00 irr_rst=00 brdy_to=00" % (v, n)
                            for v, n in counts] + ["OPNAX DONE"])
    bad = 0
    if not gate_model(parse(gate([("00", 0), ("04", 1), ("08", 40), ("10", 0), ("1F", 41)]))["gate"]).startswith("GATE"):
        bad += 1
    if not gate_model(parse(gate([("00", 41), ("04", 41), ("08", 41), ("10", 41), ("1F", 41)]))["gate"]).startswith("NO-GATE"):
        bad += 1
    if not gate_model(parse(gate([(v, 0) for v in ("00", "04", "08", "10", "1F")]))["gate"]).startswith("NONE"):
        bad += 1
    storm = gate([("00", 1), ("04", 2), ("08", 200), ("10", 1), ("1F", 200)]).replace("isr_st=0C", "isr_st=09")
    if not gate_model(parse(storm)["gate"]).startswith("BRDY-STORM"):
        print("selftest: storm", gate_model(parse(storm)["gate"]))
        bad += 1
    j = "\r\n".join("JOY hold=%02X r0f<-%s r0e=%s %s" % (h, s, v, v) for h in (0, 1)
                    for s, v in (("80", "EF" if h else "FF"), ("C0", "FF"), ("00", "EF" if h else "FF"), ("40", "FF")))
    rep = report(parse(j + "\r\nOPNAX DONE"))
    rows = [ln for ln in rep if " -> " in ln and not ln.startswith("JOY")]
    if not all("NP2kai/core" in ln for ln in rows):
        bad += 1
    print("selftest: %s" % ("PASS" if not bad else "FAIL"))
    return 1 if bad else 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) < 2:
        print(__doc__)
        return 2
    for p in argv[1:]:
        print("==== " + p)
        print("\n".join(report(parse(open(p, "rb").read().decode("ascii", "replace")))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

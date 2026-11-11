#!/usr/bin/env python3
"""ym29_decode.py - decode a YM29 capture: does YM2608 register 0x29 gate the timer IRQs?

Usage:
    python3 tools/hwprobe/ym29/ym29_decode.py YM29.TXT
    python3 tools/hwprobe/ym29/ym29_decode.py --selftest

YM29 (tools/hwprobe/ym29/ym29.s) runs a timer for two 0.2 s windows (61440 ARTIC ticks)
per 0x29 value: an IRQ window (INT 14h hooked, IRQ12 open, the handler counts and resets
the flag) and a POLL window (IRQ12 masked, the status flag polled and reset, the slave
IRR's bit 4 sampled). v1 tested Timer A only (0x29 in 1F 03 02 00); v2 adds 0x29 = 01 and
Timer B (NB = 0xE0, the same ~9.5 ms period as Timer A's NA = 0x200). Lines:

    IRQ   v29=00 n=0 st_end=01 st_isr=00 irr_end=A0 ticks=61440 pit0=.. pit1=.. sat=0   (Timer A)
    POLL  v29=00 flags=21 ir4=0 polls=29493 irr_or=A0 ticks=61441 pit0=.. pit1=..        (Timer A)
    IRQB  v29=00 ...                                                                  (Timer B, v2)
    POLLB v29=00 ...                                                                  (Timer B, v2)

(the probe prints `IRQ  v29`, `POLL v29`, `IRQB v29`, `POLLB v29`.)

The question (answered NO-GATE for both timers by docs/probes/YM29B-XE10.TXT): NEC's SOUND.ROM writes 0x29 = 00 and then waits for a Timer
A interrupt. The YM2608-LLE die model, qemu-pc98 (fmopn.c) and MAME ymfm say 0x29 bit 0
enables the Timer A IRQ and bit 1 the Timer B IRQ (reset 1F); NP2kai (sound/opntimer.c)
ignores 0x29. The Xe10's v1 capture (docs/probes/YM29-XE10.TXT) read NO-GATE for Timer A.
Per value and timer the decoder says:

    irq        interrupts arrived (n > 0)
    gated      no interrupt, but the flag rose (st_end has the timer's flag bit, or POLL flags > 0)
    no-timer   no interrupt and no flag: the timer did not run (the row is void)

Per timer (A: bit 0, B: bit 1), from the rows whose 0x29 has that bit set and clear:

    GATES      the 1F control interrupts, every value with the timer's bit set interrupts,
               every value with it clear is gated: the die/qemu/ymfm reading
    NO-GATE    every value interrupts, the bit clear or not: NP2kai's reading
    MIXED      anything else (printed per row)
    VOID       the 1F control did not interrupt, or no YM2608 was tested
    n/a        the capture has no rows for the timer (a v1 capture has no Timer B)

and the overall result names both.

v3 lines (the 2026-11 kit): `READMAP b=0188 r00= <16> r10= <16> r20= <16> rFF=xx` (the data-port
read of every base register 0x00..0x2F, select only), `RD29 v29=xx pre=xx post=xx` (0x29 read
around each write) and `IRRH M|S MASKED|FOUND n=.. b0=..b7=.. or=xx and=xx` (2 s IRR histograms).
For 0x29 the decoder says READS-FF (the Xe10's BASE r29=FF: not readable), ECHO-SELECT (29, the
select latch: NP2kai's s.reg shadow answer and the core's v2 reading) or FOLLOWS-WRITE (post =
the value written). Nothing here talks to hardware; it is a text parser.
"""

from __future__ import annotations

import re
import sys

FIELDS_IRQ = (r"v29=([0-9A-F]{2}) n=(\d+) st_end=([0-9A-F]{2}) st_isr=([0-9A-F]{2}) "
              r"irr_end=([0-9A-F]{2}) ticks=(\d+) pit0=([0-9A-F]{4}) pit1=([0-9A-F]{4}) sat=(\d)\s*$")
FIELDS_POLL = (r"v29=([0-9A-F]{2}) flags=(\d+) ir4=(\d+) polls=(\d+) irr_or=([0-9A-F]{2}) "
               r"ticks=(\d+) pit0=([0-9A-F]{4}) pit1=([0-9A-F]{4})\s*$")
IRQ = {"A": re.compile(r"^IRQ\s+" + FIELDS_IRQ), "B": re.compile(r"^IRQB\s+" + FIELDS_IRQ)}
POLL = {"A": re.compile(r"^POLL\s+" + FIELDS_POLL), "B": re.compile(r"^POLLB\s+" + FIELDS_POLL)}
USE = re.compile(r"^USE b=([0-9A-F]{4}) id=([0-9A-F]{2}) irq=(\d+)\s*$")
ARTIC_HZ = 307200
TIMER_BIT = {"A": 0x01, "B": 0x02}          # the 0x29 enable bit and the status flag bit


def parse(text: str) -> dict:
    out = {"use": None, "rows": {"A": [], "B": []}, "begin": False, "end": False,
           "version": 1}
    for line in text.splitlines():
        line = line.rstrip("\r")
        if line.startswith("BEGIN:YM29"):
            out["begin"] = True
        elif line.startswith("END:YM29"):
            out["end"] = True
        elif line.startswith("YM29 v2:"):
            out["version"] = 2
        elif line.startswith("YM29 v3:"):
            out["version"] = 3
        elif m := re.match(r"^READMAP b=([0-9A-F]{4}) r00=((?: [0-9A-F]{2}){16}) r10=((?: [0-9A-F]{2}){16})"
                           r" r20=((?: [0-9A-F]{2}){16}) rFF=([0-9A-F]{2})\s*$", line):
            out["readmap"] = [int(x, 16) for x in (m[2] + m[3] + m[4]).split()] + [int(m[5], 16)]
        elif m := re.match(r"^RD29 v29=([0-9A-F]{2}) pre=([0-9A-F]{2}) post=([0-9A-F]{2})\s*$", line):
            out.setdefault("rd29", []).append((int(m[1], 16), int(m[2], 16), int(m[3], 16)))
        elif m := re.match(r"^IRRH ([MS]) (MASKED|FOUND) n=(\d+)((?: b\d=\d+){8}) or=([0-9A-F]{2}) and=([0-9A-F]{2})\s*$", line):
            bits = [int(x) for x in re.findall(r"b\d=(\d+)", m[4])]
            out.setdefault("irrh", {})[(m[1], m[2])] = {"n": int(m[3]), "bits": bits,
                                                        "or": int(m[5], 16), "and": int(m[6], 16)}
        elif m := USE.match(line):
            out["use"] = (int(m[1], 16), int(m[2], 16))
        else:
            for t in ("A", "B"):
                if m := IRQ[t].match(line):
                    out["rows"][t].append({"v": int(m[1], 16), "n": int(m[2]),
                                           "st_end": int(m[3], 16), "st_isr": int(m[4], 16),
                                           "irr_end": int(m[5], 16), "ticks": int(m[6]),
                                           "sat": int(m[9])})
                elif m := POLL[t].match(line):
                    rows = out["rows"][t]
                    if not rows or rows[-1]["v"] != int(m[1], 16) or "flags" in rows[-1]:
                        raise ValueError(f"POLL row without its IRQ row: {line}")
                    rows[-1].update({"flags": int(m[2]), "ir4": int(m[3]), "polls": int(m[4]),
                                     "irr_or": int(m[5], 16), "pticks": int(m[6])})
    return out


def classify(r: dict, t: str) -> str:
    if r["n"] > 0:
        return "irq"
    if (r["st_end"] & TIMER_BIT[t]) or r.get("flags", 0) > 0:
        return "gated"
    return "no-timer"


def timer_verdict(cap: dict, t: str) -> str:
    rows = cap["rows"][t]
    if not rows:
        return "n/a"
    if not cap["use"] or cap["use"][1] != 0x01:
        return "VOID"
    ctl = [classify(r, t) for r in rows if r["v"] == 0x1F]
    if not ctl or any(c != "irq" for c in ctl):
        return "VOID"
    on = [classify(r, t) for r in rows if r["v"] & TIMER_BIT[t]]
    off = [classify(r, t) for r in rows if not r["v"] & TIMER_BIT[t]]
    if not off:
        return "VOID"
    if all(c == "irq" for c in on) and all(c == "gated" for c in off):
        return "GATES"
    if all(c == "irq" for c in on + off):
        return "NO-GATE"
    return "MIXED"


def verdict(cap: dict) -> str:
    """v1 compatibility: Timer A's verdict alone."""
    v = timer_verdict(cap, "A")
    return "VOID" if v in ("n/a", "MIXED") else v


def overall(cap: dict) -> str:
    a, b = timer_verdict(cap, "A"), timer_verdict(cap, "B")
    if a == "NO-GATE" and b == "NO-GATE":
        return "NEITHER timer is gated by 0x29 (NP2kai's reading): ungate both"
    if a == "GATES" and b == "GATES":
        return "BOTH timers are gated by their 0x29 bit (die model, qemu, ymfm)"
    if b == "n/a":
        return f"Timer A {a}; no Timer B rows (a v1 capture)"
    return f"Timer A {a}, Timer B {b}: the timers differ, or a row is void - read the rows"


def report(cap: dict) -> str:
    lines = []
    if not (cap["begin"] and cap["end"]):
        lines.append("WARNING: the capture lacks BEGIN:YM29/END:YM29 (a section did not finish)")
    lines.append(f"capture version v{cap['version']}")
    if cap["use"]:
        lines.append(f"tested base {cap['use'][0]:04X}, chip id {cap['use'][1]:02X}"
                     + ("" if cap["use"][1] == 1 else " (NOT a YM2608)"))
    else:
        lines.append("no OPNA base answered")
    for t in ("A", "B"):
        for r in cap["rows"][t]:
            per = (r["ticks"] / ARTIC_HZ / r["n"] * 1000) if r["n"] else 0.0
            bit = "set" if r["v"] & TIMER_BIT[t] else "clear"
            lines.append(f"Timer {t} 0x29={r['v']:02X} (bit {bit:5s}): {classify(r, t):8s} irq n={r['n']:3d}"
                         + (f" ({per:.2f} ms each)" if r["n"] else "")
                         + f"  flag at end={1 if r['st_end'] & TIMER_BIT[t] else 0}"
                         + f"  poll flags={r.get('flags', '-')}  IRR4 polls={r.get('ir4', '-')}"
                         + ("  SATURATED" if r["sat"] else ""))
    for t in ("A", "B"):
        lines.append(f"VERDICT Timer {t}: {timer_verdict(cap, t)}")
    lines.append(f"RESULT: {overall(cap)}")
    lines += v3_report(cap)
    return "\n".join(lines)


def r29_class(rd: list) -> str:
    posts = {post for _, _, post in rd}
    if all(post == v for v, _, post in rd):
        return "FOLLOWS-WRITE (0x29 reads back what was written)"
    if posts == {0xFF}:
        return "READS-FF (0x29 is not readable: the Xe10's v1/v2 BASE r29=FF)"
    if posts == {0x29}:
        return "ECHO-SELECT (reads 29, the select latch: the core's v2 BASE r29=29)"
    return "MIXED " + " ".join(f"{v:02X}->{post:02X}" for v, _, post in rd)


def v3_report(cap: dict) -> list:
    out = []
    rm = cap.get("readmap")
    if rm:
        out.append("READMAP 00-0F: " + " ".join(f"{x:02X}" for x in rm[0:16]))
        out.append("READMAP 10-1F: " + " ".join(f"{x:02X}" for x in rm[16:32]))
        out.append("READMAP 20-2F: " + " ".join(f"{x:02X}" for x in rm[32:48]) + f"   FF: {rm[48]:02X}")
        out.append(f"  0x29 reads {rm[0x29]:02X}; registers 0x10-0x2F reading FF: "
                   f"{sum(1 for x in rm[16:48] if x == 0xFF)}/32, reading their own number: "
                   f"{sum(1 for i, x in enumerate(rm[16:48]) if x == 0x10 + i)}/32")
    if cap.get("rd29"):
        out.append("RD29 " + " ".join(f"{v:02X}:{pre:02X}->{post:02X}" for v, pre, post in cap["rd29"]))
        out.append("RD29 verdict: " + r29_class(cap["rd29"]))
    for key, h in sorted(cap.get("irrh", {}).items()):
        n = h["n"] or 1
        bits = " ".join(f"b{i}={100.0 * c / n:5.1f}%" for i, c in enumerate(h["bits"]))
        out.append(f"IRRH {key[0]} {key[1]:6s} n={h['n']} {bits} or={h['or']:02X} and={h['and']:02X}")
    return out


def _sample(gate_a: bool, gate_b: bool, v2: bool = True) -> str:
    """A capture in the probe's own format; gate_x = the timer's IRQ follows its 0x29 bit."""
    rows = []
    values = (0x1F, 0x03, 0x02, 0x01, 0x00, 0x1F) if v2 else (0x1F, 0x03, 0x02, 0x00, 0x1F)
    for v in values:
        for t, tag, gate in (("A", ("IRQ ", "POLL"), gate_a), ("B", ("IRQB", "POLLB"), gate_b)):
            if t == "B" and not v2:
                continue
            on = (not gate) or (v & TIMER_BIT[t])
            n = 21 if on else 0
            st = 0 if on else TIMER_BIT[t]
            rows.append(f"{tag[0]} v29={v:02X} n={n} st_end={st:02X} st_isr={TIMER_BIT[t] if on else 0:02X} "
                        f"irr_end=A0 ticks=61440 pit0=F897 pit1=7886 sat=0")
            rows.append(f"{tag[1]} v29={v:02X} flags=21 ir4=0 polls=29493 irr_or=A0 ticks=61441 "
                        f"pit0=77D0 pit1=F7B4")
    head = ["BEGIN:YM29"]
    if v2:
        head += ["YM29 v2: does YM2608 reg 0x29 (IRQ enable) gate the Timer A and B IRQs?",
                 "TIMERS A NA=200 B NB=E0 win=61440"]
    return "\r\n".join(head + ["BASE b=0188 st=03 st2=03 a460=40 id=01 r0e=FF r0f=FF r29=FF",
                               "BASE b=0288 st=FF st2=FF a460=40", "USE b=0188 id=01 irq=12", *rows,
                               "RESTORE m_imr=7D->7D s_imr=51->51 vec14=FD80:0161->FD80:0161",
                               "END:YM29", ""])


def selftest() -> int:
    fails = 0
    cases = [
        (_sample(False, False), ("NO-GATE", "NO-GATE")),
        (_sample(True, True), ("GATES", "GATES")),
        (_sample(False, True), ("NO-GATE", "GATES")),
        (_sample(True, False), ("GATES", "NO-GATE")),
        (_sample(False, False, v2=False), ("NO-GATE", "n/a")),
        (_sample(True, True, v2=False), ("GATES", "n/a")),
        # the control did not interrupt
        (_sample(True, True).replace("IRQ  v29=1F n=21", "IRQ  v29=1F n=0"), ("VOID", "GATES")),
        # not a YM2608
        (_sample(True, True).replace("USE b=0188 id=01", "USE b=0188 id=00"), ("VOID", "VOID")),
        # one bit-clear row interrupts while the other is gated
        (_sample(True, True).replace("IRQB v29=01 n=0", "IRQB v29=01 n=21"), ("GATES", "MIXED")),
    ]
    for i, (text, want) in enumerate(cases):
        cap = parse(text)
        got = (timer_verdict(cap, "A"), timer_verdict(cap, "B"))
        if got != want:
            print(f"FAIL case {i}: verdicts {got}, want {want}")
            fails += 1
    if parse(_sample(True, True))["version"] != 2 or parse(_sample(True, True, v2=False))["version"] != 1:
        print("FAIL: version line")
        fails += 1
    try:
        parse("IRQ  v29=00 n=0 st_end=01 st_isr=00 irr_end=A0 ticks=1 pit0=0000 pit1=0000 sat=0\n"
              "POLL v29=1F flags=1 ir4=0 polls=1 irr_or=00 ticks=1 pit0=0000 pit1=0000\n")
        print("FAIL: a POLL row for another value was accepted")
        fails += 1
    except ValueError:
        pass
    v3 = _sample(True, True).replace("YM29 v2:", "YM29 v3:") + (
        "READMAP b=0188 r00=" + " 00" * 16 + " r10=" + " FF" * 16 + " r20=" + " FF" * 16 + " rFF=01\r\n"
        "RD29 v29=1F pre=FF post=FF\r\nRD29 v29=00 pre=FF post=FF\r\n"
        "IRRH M MASKED n=100 b0=0 b1=0 b2=0 b3=0 b4=0 b5=0 b6=0 b7=50 or=80 and=00\r\n")
    c3 = parse(v3)
    rep3 = report(c3)
    for want in ("capture version v3", "READS-FF", "b7= 50.0%", "registers 0x10-0x2F reading FF: 32/32"):
        if want not in rep3:
            print(f"FAIL v3: {want!r} not in the report")
            fails += 1
    if "ECHO-SELECT" not in r29_class([(0x1F, 0x29, 0x29), (0x00, 0x29, 0x29)]) or \
            "FOLLOWS" not in r29_class([(0x1F, 0x00, 0x1F), (0x03, 0x1F, 0x03)]):
        print("FAIL: r29_class")
        fails += 1
    print(f'{"PASS" if not fails else "FAIL"}: ym29_decode selftest ({fails} failing)')
    return 1 if fails else 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    if len(argv) != 2:
        print(__doc__)
        return 2
    with open(argv[1], "rb") as f:
        text = f.read().decode("ascii", "replace")
    cap = parse(text)
    print(report(cap))
    return 1 if "VOID" in (timer_verdict(cap, "A"), timer_verdict(cap, "B")) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

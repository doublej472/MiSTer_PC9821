#!/usr/bin/env python3
"""irqwd_decode.py - turn an IRQWD capture into one verdict per IRQ line.

IRQWD (tools/hwprobe/irqwd/irqwd.s) measures, on the real Xe10, whether a masked
IRQ request that a guest acks is WITHDRAWN by the machine or HELD in the 8259's
edge latch. The core's model holds it; NP2kai withdraws it for the keyboard, IDE,
calendar, OPNA and MPU (pic_resetirq) and clears the timer (picmask). The core
already knows it waives the PIT channel-0 clear (tb_pc9821_pit_ref), so IRQ0 is
the confirmed one; this capture settles the rest.

    python3 tools/hwprobe/irqwd/irqwd_decode.py IRQWD.TXT
    python3 tools/hwprobe/irqwd/irqwd_decode.py --selftest

Rows read (all printed by the probe):

    master IMR IRR ISR = mm rr ii
    slave  IMR IRR ISR = mm rr ii
    IRQ0 masked poll lo hi falls rises = n n n n
    PITCH0 IRR before ch0-write after = bb aa
    IRQ1  keyboard 0x41 ack latched=L latch_irr=H postack_irr=H delivered=N
    IRQ9  IDE 0x64E ack         ...
    IRQ12 OPNA reg 0x27 ack     ...
    IRQ15 calendar 0x128 ack    ...

Verdicts:
    PITOUT falls/rises>0      -> the PIT channel-0 OUT pin is toggling (the IRQ0
                                 row's control; a static OUT voids it)
    IRQ0   falls>0            -> CLEARS the masked timer request (STEELGUN works)
           falls=0 + PITOUT   -> HOLDS
           no PITOUT row      -> UNKNOWN (the control is missing, not static)
    PITCH0 before bit0 set and after bit0 clear -> CLEARS (the ch0 write withdraws)
    LINE   trig=0             -> NO-TRIGGER (device absent / banking wrong)
           postack_irr bit SET -> HOLDS (keep the latch)
           postack_irr bit CLEAR -> WITHDRAWS (adopt NP2kai pic_resetirq)

A torn capture (no END:IRQWD, or a section missing its row) is refused: exit 1.
"""

import re
import sys

# (label, controller, IRR bit) - the bit is the line's bit in its own PIC.
LINES = [
    ("IRQ1", "master", 0x02),
    ("IRQ9", "slave", 0x02),
    ("IRQ12", "slave", 0x10),
    ("IRQ15", "slave", 0x80),
]


def get(pattern, text):
    m = re.search(pattern, text)
    return m.group(1) if m else None


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "-"
    if path == "--selftest":
        return selftest()
    text = sys.stdin.read() if path == "-" else open(path, "r", errors="replace").read()
    return decode(text)


def decode(text):
    if "BEGIN:IRQWD" not in text and "IRQWD - PC-9821" not in text:
        print("IRQWD DECODE: REFUSED - this is not an IRQWD capture", file=sys.stderr)
        return 1
    torn = "END:IRQWD" not in text
    if torn:
        print("IRQWD DECODE: WARNING - no END:IRQWD (torn capture); rows shown are still valid")

    print("IRQWD DECODE")
    m_state = get(r"master IMR IRR ISR = ([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2})", text)
    s_state = get(r"slave\s+IMR IRR ISR = ([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2})", text)
    if m_state:
        print(f"  as found: master IMR/IRR/ISR = {m_state}")
    if s_state:
        print(f"  as found: slave  IMR/IRR/ISR = {s_state}")

    missing = []

    # ---- PITOUT: is the PIT channel-0 OUT pin toggling? (the IRQ0 control) ----
    pitout = None
    mp = re.search(r"PITOUT ch0_status lo hi falls rises = ([0-9A-Fa-f]{2}) (\d+) (\d+) (\d+) (\d+)", text)
    if mp:
        st, lo, hi, of, orr = mp.groups()
        pitout = int(of) + int(orr)
        mode = (int(st, 16) >> 1) & 7
        v = "TOGGLES" if pitout > 0 else "STATIC"
        print(f"  {v:12} PITOUT ch0_status={st} mode={mode} falls={of} rises={orr}")
    else:
        missing.append("PITOUT")

    # ---- IRQ0: the masked timer poll ----
    m0 = re.search(r"IRQ0 masked poll ch0_status lo hi falls rises = ([0-9A-Fa-f]{2}) (\d+) (\d+) (\d+) (\d+)", text)
    if m0:
        st, lo, hi, falls, rises = m0.groups()
        lo, hi, falls, rises = int(lo), int(hi), int(falls), int(rises)
        mode = (int(st, 16) >> 1) & 7
        if falls > 0:
            v = "CLEARS"
        elif pitout is None:
            v = "UNKNOWN"
        elif pitout:
            v = "HOLDS"
        else:
            v = "NO-PIT"
        note = ""
        if v == "UNKNOWN":
            note = "  (no PITOUT row: the control is missing - row void)"
        elif v == "NO-PIT":
            note = "  (the PIT was not toggling - row void)"
        print(f"  {v:12} IRQ0   ch0_status={st} mode={mode} falls={falls} rises={rises} "
              f"lo={lo} hi={hi}" + note)
    else:
        missing.append("IRQ0")

    # ---- PITCH0: the channel-0 write ----
    m1 = re.search(r"PITCH0 IRR before ch0-write after = ([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2})", text)
    if m1:
        pre, post = (int(x, 16) for x in m1.groups())
        if not (pre & 1):
            v = "NO-LATCH (bit0 was clear before the write)"
        elif post & 1:
            v = "HOLDS"
        else:
            v = "CLEARS (the ch0 control write withdraws IRQ0)"
        print(f"  {v:12} PITCH0 before={pre:02X} after={post:02X}")
    else:
        missing.append("PITCH0")

    # ---- the four device lines ----
    for label, ctl, bit in LINES:
        m = re.search(
            label + r"\s+\S.*?trig=([0-9A-Fa-f]{2}) latch_irr=([0-9A-Fa-f]{2}) "
            r"postack_irr=([0-9A-Fa-f]{2})", text)
        if not m:
            missing.append(label)
            continue
        trig, latch_irr, post = (int(x, 16) for x in m.groups())
        if trig == 0:
            v = "NO-TRIGGER"
        elif post & bit:
            v = "HOLDS"
        else:
            v = "WITHDRAWS"
        print(f"  {v:12} {label:5} trig={trig:02X} latch_irr={latch_irr:02X} "
              f"postack_irr={post:02X} ({ctl} bit {bit:02X})")

    if missing:
        print(f"  MISSING rows: {' '.join(missing)}")
        print("IRQWD DECODE: INCOMPLETE - a probe that hung leaves its section without a row")
        return 1
    if torn:
        print("IRQWD DECODE: INCOMPLETE - no END:IRQWD (torn capture); the verdicts above are not a run")
        return 1
    print("IRQWD DECODE: OK - one verdict per line")
    return 0


def selftest():
    """Plants: the committed shape decodes OK; a torn copy (END:IRQWD cut) and a copy without
    the PITOUT row are refused, the latter's IRQ0 verdict UNKNOWN (not NO-PIT)."""
    import contextlib
    import io
    good = "\n".join([
        "IRQWD - PC-9821 masked-IRQ withdraw probe", "BEGIN:IRQWD",
        "  PITOUT ch0_status lo hi falls rises = 36 10 20 3 3",
        "  IRQ0 masked poll ch0_status lo hi falls rises = 36 0 65532 0 0",
        "  PITCH0 IRR before ch0-write after = 01 00",
        "  IRQ1  keyboard 0x41 ack trig=01 latch_irr=02 postack_irr=02 delivered=0",
        "  IRQ9  IDE 0x64E ack trig=01 latch_irr=02 postack_irr=00 delivered=0",
        "  IRQ12 OPNA reg 0x27 ack trig=01 latch_irr=10 postack_irr=10 delivered=0",
        "  IRQ15 calendar 0x128 ack trig=01 latch_irr=80 postack_irr=80 delivered=0",
        "END:IRQWD", ""])

    def run(t):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = decode(t)
        return rc, out.getvalue()
    rc, o = run(good)
    assert rc == 0 and "OK - one verdict" in o and "HOLDS        IRQ0" in o, o
    rc, o = run(good.replace("END:IRQWD", ""))
    assert rc == 1 and "INCOMPLETE - no END:IRQWD" in o, o
    rc, o = run("\n".join(l for l in good.split("\n") if "PITOUT" not in l))
    assert rc == 1 and "UNKNOWN      IRQ0" in o and "NO-PIT" not in o, o
    print("irqwd_decode selftest: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())

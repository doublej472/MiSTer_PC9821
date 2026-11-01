#!/usr/bin/env python3
"""Decode SDSHMOO.TXT (tools/hwprobe/sdshmoo) into the SDRAM pass window per chip half.

    sdshmoo_decode.py SDSHMOO.TXT [--step-ps 154.32] [--clk-mhz 90]
    sdshmoo_decode.py --selftest

A step counts only where the phase was really moved there: its `rb` (the applied offset the
instrument read back after the move, 0x5FF2) must equal the requested step, else the step is
NOT APPLIED - it is listed without an ns offset and is never a window point (on the 2026-10-29
hardware run a stuck `fault` kept every step at nominal while the requests said +1/-1). An applied
step PASSES when it has no data error in either chip half, a clean canary, and a status with no
watchdog revert and no wait timeout. The status's `fault` bit (a PLL step timed out, so the applied
count may be off by one per timeout) does not fail a step's data: it makes the whole run
INCONCLUSIVE, as does any step that was not applied. (The program's own `judge`, which picks where
the sweep stops, also counts `fault` as a failure.) The window is the contiguous run of passing
applied steps around step 0, per chip half and for the whole module; each edge is the last passing
step, and a BEGIN with no STEP is a hang at that step (a failure). The step is the PLL's VCO/8:
154.3 ps at the 90 MHz build's 810 MHz VCO (rtl/pll's readback `phase_step_ps`).

The verdict applies docs/sdram-margin.md's criterion: both sides of the window at least --need-ns
(default 1.0 ns) from the shipped phase, for every chip half that was tested. Exit status: 0 PASS,
1 FAIL, 2 NO DATA, 3 INCONCLUSIVE (fault seen, a step not applied, or a window side short of
the criterion whose edge was not measured, e.g. a nominal-only run).
"""
from __future__ import annotations

import argparse
import re
import sys

FIELD = re.compile(r"(\w+)=(\S+)")


def parse(text: str) -> dict:
    head, steps, final, begun = {}, {}, None, []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("SDSHMOO "):
            head = dict(FIELD.findall(line))
        elif line.startswith("BEGIN "):
            begun.append(int(line.split()[1]))
        elif line.startswith(("STEP ", "FINAL ")):
            kind, off = line.split()[:2]
            rec = dict(FIELD.findall(line))
            rec["off"] = int(off)
            if kind == "FINAL":
                final = rec
            else:
                steps[int(off)] = rec
    hung = [o for o in begun if o not in steps]
    if final is None and hung and hung[-1] == 0 and 0 in steps:
        hung = hung[:-1]       # the FINAL step's BEGIN is a step-0 BEGIN too
    return {"head": head, "steps": steps, "final": final, "hung": hung}


def _status_bad(s: str) -> bool:
    """A wait timeout (T prefix) or the watchdog's `reverted` [2]: the step's data are not valid."""
    if s.startswith("T"):
        return True
    return bool(int(s, 16) & 0x04)


def _status_fault(s: str) -> bool:
    """The instrument's `fault` [3]: a PLL step timed out; the applied count is uncertain."""
    return bool(int(s.lstrip("T") or "0", 16) & 0x08)


def has_fault(rec: dict) -> bool:
    return _status_fault(rec.get("st0", "00")) or _status_fault(rec.get("st1", "00"))


def applied(rec: dict, present: bool = True) -> bool:
    """The phase was moved to the requested step: the read-back applied offset equals it. Without
    the instrument (present=0) only nominal runs, and nothing is moved."""
    if not present:
        return rec["off"] == 0
    rb = rec.get("rb")
    if rb is None:
        return False
    return int(rb, 16) == (rec["off"] & 0xFF)


def step_ok(rec: dict, chip: int | None = None) -> bool:
    """chip None = the whole module; 0/1 = that chip half's data only (plus the shared checks)."""
    errs = [int(rec.get("err0", "0"), 16), int(rec.get("err1", "0"), 16)]
    data_bad = (errs[0] or errs[1]) if chip is None else errs[chip]
    return not (data_bad or int(rec.get("can", "0"), 16)
                or _status_bad(rec.get("st0", "00")) or _status_bad(rec.get("st1", "00")))


def window(steps: dict, hung: list, chip: int | None,
           present: bool = True) -> tuple[int | None, int | None]:
    """(lowest, highest) passing applied step of the contiguous run through 0; None where 0
    fails or was not applied."""
    def ok(o):
        return (o in steps and o not in hung and applied(steps[o], present)
                and step_ok(steps[o], chip))
    if not ok(0):
        return None, None
    lo = 0
    while ok(lo - 1):
        lo -= 1
    hi = 0
    while ok(hi + 1):
        hi += 1
    return lo, hi


def report(text: str, step_ps: float, need_ns: float) -> int:
    d = parse(text)
    steps, hung = d["steps"], d["hung"]
    present = d["head"].get("present", "1") not in ("0", "+0")
    print(f"header: {d['head']}")
    if not steps:
        print("VERDICT: NO DATA (no STEP line)")
        return 2
    dual = any(int(r.get("err1", "0"), 16) for r in steps.values()) or \
        "," in d["head"].get("ext", "") and int(d["head"]["ext"].split(",")[1].split("-")[1], 16) > 0x4000000
    print(f"{'step':>5} {'ns':>7}  verdict  rb err0     err1     dq0  dq1  can      st0/st1 pat")
    for o in sorted(steps):
        r = steps[o]
        app = applied(r, present)
        v = ("pass" if step_ok(r) else "FAIL") if app else "n/a"
        ns = f"{o * step_ps / 1000:>+7.3f}" if app else f"{'--':>7}"
        note = "" if app else f"  NOT APPLIED (requested {o:+d}, the phase read back {r.get('rb')})"
        print(f"{o:>+5} {ns}  {v:<7}  {r.get('rb')} {r.get('err0')} {r.get('err1')} "
              f"{r.get('dq0')} {r.get('dq1')} {r.get('can')} {r.get('st0')}/{r.get('st1')} "
              f"{r.get('pat')}{' fault' if has_fault(r) else ''}{note}")
    for o in hung:
        print(f"{o:>+5} {o * step_ps / 1000:>+7.3f}  HANG     (BEGIN with no STEP)")
    final = d["final"]
    if final is not None:
        if not applied(final, present):
            print(f"FINAL (step 0 again): n/a - NOT APPLIED (the phase read back {final.get('rb')})")
        else:
            print(f"FINAL (step 0 again): {'pass' if step_ok(final) else 'FAIL'}")
    recs = list(steps.values()) + ([final] if final is not None else [])
    not_applied = sorted(r["off"] for r in steps.values() if not applied(r, present))
    faulted = any(has_fault(r) for r in recs) or _status_fault(d["head"].get("st", "00"))
    verdict = 0
    unknown = False
    for name, chip in (("module", None), ("chip0 (< 64 MiB)", 0), ("chip1 (>= 64 MiB)", 1)):
        if chip == 1 and not dual:
            continue
        lo, hi = window(steps, hung, chip, present)
        if lo is None:
            print(f"window {name}: step 0 FAILS")
            verdict = 1
            continue
        lns, hns = -lo * step_ps / 1000, hi * step_ps / 1000
        cut_lo = cut_hi = ""
        if (lo - 1) not in steps and (lo - 1) not in hung:
            cut_lo = "low edge not reached"
        elif (lo - 1) in steps and not applied(steps[lo - 1], present):
            cut_lo = "low edge not measured (next step not applied)"
        if (hi + 1) not in steps and (hi + 1) not in hung:
            cut_hi = "high edge not reached"
        elif (hi + 1) in steps and not applied(steps[hi + 1], present):
            cut_hi = "high edge not measured (next step not applied)"
        cut = [c for c in (cut_lo, cut_hi) if c]
        # A side short of the criterion FAILS only where its edge was measured; a side whose sweep
        # stopped (range) or whose next step never moved is UNKNOWN, not a failure.
        sides = [("meets" if ns >= need_ns else ("unknown" if c else "BELOW"))
                 for ns, c in ((lns, cut_lo), (hns, cut_hi))]
        tag = "meets" if sides == ["meets", "meets"] else (
            "BELOW" if "BELOW" in sides else "UNKNOWN (edge not measured)")
        print(f"window {name}: steps {lo:+d}..{hi:+d} = -{lns:.3f} / +{hns:.3f} ns "
              f"(total {lns + hns:.3f} ns){' [' + ', '.join(cut) + ']' if cut else ''}  "
              f"{tag} +-{need_ns:.2f} ns")
        if "BELOW" in sides:
            verdict = 1
        elif "unknown" in sides:
            unknown = True
    if final is not None and applied(final, present) and not step_ok(final):
        verdict = 1
    if verdict == 0 and (faulted or not_applied or unknown
                         or (final is not None and not applied(final, present))):
        if faulted:
            print("INSTRUMENT: `fault` is set (a PLL step timed out, or the flag powered up set):"
                  " the applied offsets are not trustworthy")
        if not_applied:
            print(f"INSTRUMENT: {len(not_applied)} step(s) not applied "
                  f"({', '.join(f'{o:+d}' for o in not_applied)}): the phase never reached them")
        if unknown:
            print("WINDOW: an edge was not measured (the sweep's range or a step not applied):"
                  " no margin verdict")
        print("VERDICT: INCONCLUSIVE")
        return 3
    print(f"VERDICT: {'PASS' if verdict == 0 else 'FAIL'}")
    return verdict


def selftest() -> int:
    lines = ["SDSHMOO v1 present=1 st=A0 ext=00110000-01000000,01000000-06000000 passes=1 range=-36..+36 stop=+4"]
    def step(o, e0=0, e1=0, st1="A0", can=0, kind="STEP", rb=None, st0="A0"):
        rb = (o & 0xFF) if rb is None else rb
        return (f"{kind} {o:+d} st0={st0} rb={rb:02X} st1={st1} err0={e0:08X} err1={e1:08X} dq0=0000 "
                f"dq1=0000 first=00000000 xor=00000000 pat=0 can={can:08X} abort=0 pe=0")
    for o in [0, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6, 7, -7, 8, -8, 9, -9, 10, -10]:
        lines.append(f"BEGIN {o:+d}")
        e1 = 5 if o >= 8 else 0           # chip 1 fails from +8
        e0 = 3 if o <= -9 or o >= 10 else 0
        lines.append(step(o, e0, e1))
    lines.append("BEGIN +11")             # a hang
    lines.append("BEGIN +0")
    lines.append(step(0, kind="FINAL"))
    d = parse("\n".join(lines))
    assert d["hung"] == [11], d["hung"]
    assert window(d["steps"], d["hung"], None) == (-8, 7)
    assert window(d["steps"], d["hung"], 0) == (-8, 9)
    assert window(d["steps"], d["hung"], 1) == (-10, 7)
    assert not step_ok(dict(FIELD.findall(step(0, st1="A4"))))     # watchdog revert
    assert not step_ok(dict(FIELD.findall(step(0, can=1))))        # canary
    assert not step_ok(dict(FIELD.findall(step(0).replace("st0=A0", "st0=TA2"))))  # timeout
    assert step_ok(dict(FIELD.findall(step(0, st1="A8"))))          # fault alone: data still good
    assert report("\n".join(lines), 154.32, 1.0) == 0               # 7*0.154 = 1.08 ns each side
    assert report("\n".join(lines), 154.32, 1.2) == 1
    # The 2026-10-29 hardware run (.build/shmoo-hw/SDSHMOO-90MHz-step-proof.TXT): `fault` stuck at
    # power-up, every request read back 00. Step 0's data are good, +1/-1 never moved: not window
    # points, no ns offset, and the run is INCONCLUSIVE, not a data FAIL.
    proof = ["SDSHMOO v1 present=1 st=A8 ext=00110000-00910000 passes=+1 range=-1..+1 stop=+1",
             "BEGIN +0", step(0, st0="A8", st1="A8"),
             "BEGIN +1", step(1, st0="AC", st1="AC", rb=0),
             "BEGIN -1", step(-1, st0="AC", st1="AC", rb=0),
             "BEGIN +0", step(0, st0="A8", st1="A8", kind="FINAL"), "END steps=+4"]
    dp = parse("\n".join(proof))
    assert not applied(dp["steps"][1]) and not applied(dp["steps"][-1]) and applied(dp["steps"][0])
    assert window(dp["steps"], dp["hung"], None) == (0, 0)
    assert report("\n".join(proof), 154.32, 1.0) == 3
    # A negative step reads back in two's complement; a step whose phase stopped short is n/a.
    assert applied({"off": -7, "rb": "F9"}) and not applied({"off": -7, "rb": "FA"})
    short = list(lines)
    short[short.index(next(x for x in short if x.startswith("STEP +3 ")))] = step(3, rb=2)
    ds = parse("\n".join(short))
    assert window(ds["steps"], ds["hung"], None) == (-8, 2)
    assert report("\n".join(short), 154.32, 0.1) == 3
    print("sdshmoo_decode selftest: PASS")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", nargs="?")
    ap.add_argument("--step-ps", type=float, default=154.32,
                    help="the PLL phase step in ps (VCO/8; 154.32 at the 90 MHz build)")
    ap.add_argument("--need-ns", type=float, default=1.0,
                    help="the margin each side of the window must reach (docs/sdram-margin.md)")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    if not a.log:
        ap.error("give SDSHMOO.TXT")
    return report(open(a.log, errors="replace").read(), a.step_ps, a.need_ns)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

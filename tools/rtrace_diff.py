#!/usr/bin/env python3
"""rtrace_diff.py A.bin B.bin [--show N] [--persist N]: diff two instruction-trace dumps.

The debug-UART method's third step (docs/mister-testing.md, the debug UART):
once the sampler has placed the stall and the snoop has shown which memory is involved, the same
trigger is run twice - a good run and a bad one, or two builds - and the two frozen traces
(pc9821_dbg_cpu's 0x43 records, from a capture of the debug UART) are compared HERE.

The two instruction streams are aligned on (CS, EIP) with difflib, so a burst of extra
instructions on one side is an insertion rather than a mismatch of everything after it. The tool
reports

  * the first PATH divergence (the first place the two runs executed different instructions), with
    both windows around it, and
  * the first aligned instruction whose SP or EFLAGS[15:0] differs and STAYS different for the next
    --persist aligned issues (a one-issue difference is pipeline-lag noise).

The trace carries {CS, next EIP, SP, EFLAGS[15:0]} per issue; the general registers are not in it
(z486 exports no tap for them).

Usage:  rtrace_diff.py A.bin B.bin [--show 12] [--persist 3]
        rtrace_diff.py --selftest
"""
from __future__ import annotations

import argparse
import difflib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import decode_dbglog as dbg  # noqa: E402


def load(path: str):
    cap = dbg.parse(open(path, "rb").read())
    return dbg.trace_of(cap)


def row(e) -> str:
    return f"{e['cs']:04X}:{e['eip']:08X} SP={e['sp']:04X} FL={e['flags']:04X}"


def diff(ta, ga, tb, gb, show=12, persist=3, out=print):
    """Returns (first path divergence tuple or None, first register divergence tuple or None)."""
    out(f"A: {len(ta)} entries, trigger {ga};  B: {len(tb)} entries, trigger {gb}")
    ka = [(e["cs"], e["eip"]) for e in ta]
    kb = [(e["cs"], e["eip"]) for e in tb]
    sm = difflib.SequenceMatcher(None, ka, kb, autojunk=False)
    blocks = [m for m in sm.get_matching_blocks() if m.size]
    out("matching blocks (a, b, len):", [(m.a, m.b, m.size) for m in blocks])
    pairs = [(m.a + k, m.b + k) for m in blocks for k in range(m.size)]
    first = None
    for idx, (i, j) in enumerate(pairs):
        for field in ("sp", "flags"):
            if ta[i][field] != tb[j][field]:
                ok = all(ta[pairs[idx + q][0]][field] != tb[pairs[idx + q][1]][field]
                         for q in range(1, persist + 1) if idx + q < len(pairs))
                if ok:
                    first = (idx, i, j, field.upper())
                    break
        if first:
            break
    path = None
    ops = [op for op in sm.get_opcodes() if op[0] != "equal"]
    if ops:
        tag, i1, i2, j1, j2 = ops[0]
        path = (tag, i1, i2, j1, j2)
        out(f"first path divergence: {tag} A[{i1}:{i2}] B[{j1}:{j2}]")
        for k in range(max(0, i1 - show), min(len(ta), i2 + 3)):
            out("  A", k, row(ta[k]))
        for k in range(max(0, j1 - show), min(len(tb), j2 + 3)):
            out("  B", k, row(tb[k]))
    else:
        out("the two traces execute the same instruction stream")
    if first:
        idx, i, j, field = first
        out(f"first persistent {field} divergence at aligned issue A[{i}] / B[{j}]")
        for q in range(max(0, idx - show), min(len(pairs), idx + 6)):
            x, y = pairs[q]
            out(f"  A{x:3d} {row(ta[x])}\n  B{y:3d} {row(tb[y])}")
    else:
        out("no persistent SP/EFLAGS divergence on aligned instructions")
    return path, first


def selftest() -> int:
    def entries(eips, sp0=0x1000, fl=0x202, bump_from=None):
        return [dict(idx=n, cs=0x100, eip=e, sp=sp0 + (4 if bump_from is not None and n >= bump_from else 0), flags=fl)
                for n, e in enumerate(eips)]
    base = list(range(0x4000, 0x4020))
    a = entries(base)
    quiet = lambda *a, **k: None
    bad = 0
    path, reg = diff(a, None, entries(base), None, out=quiet)
    if path or reg:
        print("SELFTEST FAIL: identical traces reported a divergence")
        bad += 1
    path, reg = diff(a, None, entries(base[:10] + [0x9000, 0x9001] + base[10:]), None, out=quiet)
    if not path or path[0] != "insert" or path[3] != 10:
        print(f"SELFTEST FAIL: a two-instruction insertion at 10 reported as {path}")
        bad += 1
    path, reg = diff(a, None, entries(base, bump_from=12), None, out=quiet)
    if path or not reg or reg[3] != "SP" or reg[1] != 12:
        print(f"SELFTEST FAIL: a persistent SP difference from issue 12 reported as {reg}")
        bad += 1
    one = entries(base)
    one[12]["sp"] += 4
    path, reg = diff(a, None, one, None, out=quiet)
    if reg:
        print("SELFTEST FAIL: a one-issue SP blip was reported as persistent")
        bad += 1
    print("rtrace_diff.py --selftest:", "FAIL" if bad else "PASS")
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a", nargs="?")
    ap.add_argument("b", nargs="?")
    ap.add_argument("--show", type=int, default=12)
    ap.add_argument("--persist", type=int, default=3)
    ap.add_argument("--selftest", action="store_true")
    n = ap.parse_args()
    if n.selftest:
        return selftest()
    if not (n.a and n.b):
        ap.error("two captures are required")
    ta, ga = load(n.a)
    tb, gb = load(n.b)
    diff(ta, ga, tb, gb, n.show, n.persist)
    return 0


if __name__ == "__main__":
    sys.exit(main())

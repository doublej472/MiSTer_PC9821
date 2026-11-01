#!/usr/bin/env python3
"""check_micro_equiv.py -- yosys SAT proofs that a rewritten combinational expression equals its
pre-rewrite form, for the small rewrites too local to warrant a tool of their own.

Each tools/equiv/*.sv holds `module m(..., output mismatch)` containing BOTH forms and
`assign mismatch = old != new`. The runner proves mismatch is 0 for every input. A file lists
`// PLANT: <text> => <replacement>` lines: each mutation of the file must make the proof FAIL,
so a proof that cannot fail is caught by --selftest. A file naming `PAIR_MOD` is a
tools/check_seq_equiv.py --pair template and is skipped here.

A file may also prove the REAL source text rather than a copy of it: a line
`// SPAN: <path> | <start text> | <end text>` pastes the source lines from the first one
containing <start text> through the next one containing <end text> (e.g. a function and the
localparams it reads) in place of the harness's `// SPAN-HERE` line.

  python3 tools/check_micro_equiv.py [--selftest]
"""
import glob
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def expand(text):
    m = re.search(r"^// SPAN: (.*?) \| (.*?) \| (.*?)$", text, re.M)
    if not m:
        return text
    lines = open(os.path.join(REPO, m.group(1).strip())).read().splitlines()
    a = next(i for i, ln in enumerate(lines) if m.group(2) in ln)
    b = next(i for i in range(a, len(lines)) if m.group(3) in lines[i])
    assert text.count("// SPAN-HERE") == 1, "SPAN needs exactly one // SPAN-HERE"
    return text.replace("// SPAN-HERE", "\n".join(lines[a:b + 1]))


def prove(text):
    with tempfile.TemporaryDirectory() as tmp:
        open(os.path.join(tmp, "m.sv"), "w").write(text)
        r = subprocess.run(["yosys", "-p", "read_verilog -sv m.sv; hierarchy -top m; proc; flatten; "
                            "memory_map; opt; sat -prove mismatch 0 -verify"],
                           cwd=tmp, capture_output=True, text=True)
    return r.returncode == 0 and "SUCCESS!" in r.stdout


def main():
    selftest = "--selftest" in sys.argv
    files = sorted(glob.glob(os.path.join(REPO, "tools", "equiv", "*.sv")))
    bad = 0
    for f in files:
        raw = open(f).read()
        if "PAIR_MOD" in raw:   # a tools/check_seq_equiv.py --pair template, not a mismatch proof
            print("%-28s %s" % (os.path.basename(f), "SKIP (check_seq_equiv --pair template)"))
            continue
        text = expand(raw)   # a PLANT may then target the pasted source text too
        ok = prove(text)
        print("%-28s %s" % (os.path.basename(f), "PROVEN" if ok else "FAILED"))
        bad += not ok
        if selftest:
            for m in re.finditer(r"// PLANT: (.*?) => (.*)", text):
                a, b = m.group(1), m.group(2)
                body = text.replace(m.group(0), "")
                if a not in body:
                    print("  plant anchor missing: %s" % a)
                    bad += 1
                elif prove(body.replace(a, b, 1)):
                    print("  plant NOT caught: %s" % a)
                    bad += 1
                else:
                    print("  plant caught: %s" % a)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

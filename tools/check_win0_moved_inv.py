#!/usr/bin/env python3
"""check_win0_moved_inv.py -- prove, by induction over the REAL pc9821_iobus, that its registered
`win0_sel_moved` equals `win0_sel != 8'h08` in every reachable cycle, the reset included
(docs/timing.md C7-head: the memory map and the subsystem read the flag in place of the compare,
and pc9821_system feeds it to z486 as win0_unmapped).

The tool pastes the assertion into a COPY of pc9821_iobus (the tree is never edited); every
device it instantiates is replaced by a stub built from its own port list (tools/iobus_formal.py),
so their outputs are FREE (any value, any cycle) - a superset of the real behaviour. Every
top-level input, the reset included, is free. yosys `sat -tempinduct` proves the assertion from a
reset in the first step and by induction for every later step.

--selftest plants defects that must each make the proof FAIL.

  python3 tools/check_win0_moved_inv.py [--selftest]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iobus_formal  # noqa: E402

PROP = r"""
  // ---- check_win0_moved_inv.py (pasted into a copy; never in the tree) ----
  always @* if (!reset) assert (win0_sel_moved == (win0_sel != 8'h08));
"""

PLANTS = [
    # the flag computed from the old value instead of the one being written
    ("win0_sel_moved <= (next_win0 != 8'h08);", "win0_sel_moved <= (win0_sel != 8'h08);"),
    # the wrong reset value
    ("win0_sel_moved <= 1'b0;    // (8'h08 != 8'h08)", "win0_sel_moved <= 1'b1;"),
    # win0_sel written somewhere the flag is not
    ("                win0_sel       <= next_win0;\n",
     "                win0_sel       <= next_win0 | 8'h01;\n"),
]


def prove(plant=None):
    return iobus_formal.prove_property(PROP, [plant] if plant else [])


def main():
    ok, log = prove()
    print("iobus win0_sel_moved == (win0_sel != 8'h08): %s" % ("PROVEN" if ok else "FAILED"))
    bad = 0 if ok else 1
    if not ok:
        print(log[-3000:])
    if "--selftest" in sys.argv:
        for p in PLANTS:
            pok, _ = prove(p)
            print("  plant %s: %s" % ("NOT caught" if pok else "caught", p[1].strip()[:60]))
            bad += pok
        print("check_win0_moved_inv: selftest %s" % ("FAIL" if bad else "PASS"))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

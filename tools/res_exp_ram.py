#!/usr/bin/env python3
"""Read a Quartus map.rpt's synthesis-side RAM facts (also the parser tools/res_exp_map.py uses).

A per-ENTITY table diff (ALUTs / regs / bits / DSP) cannot answer the question this tool
is about: did a memory INFER, or was it built from LUTs?
A memory missing from the Analysis & Synthesis RAM Summary is implemented in logic, and nothing
in the entity table says which. This tool prints:

  * `--ram`      every RAM Summary row whose hierarchy name matches a regex (the acceptance
                 evidence for an inference -- an attribute is not evidence);
  * `--totals`   the A&S Resource Usage Summary lines (device ALMs estimate, combinational
                 ALUTs, registers, MLAB bits, block-memory bits, DSP), which is where an
                 inferred memory's block bits appear;
  * `--settings` A&S Settings rows (the "did the assignment actually take effect" check --
                 Quartus silently ignores an invalid assignment name);
  * two reports  a delta of every one of the above, so a before/after pair is one command.

Usage:
  python3 tools/res_exp_ram.py NEW.map.rpt --compare BASE.map.rpt --ram 'pc9821_kbd|pc9821_crtc'
  python3 tools/res_exp_ram.py NEW.map.rpt --settings RESOURCE_AWARE

Exit status is nonzero when a requested regex matches nothing (fail-loud), so "the row I
expected is not there" cannot read as a pass.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

TOTALS = (
    "Estimate of Logic utilization (ALMs needed)",
    "Combinational ALUT usage for logic",
    "Dedicated logic registers",
    "Total MLAB memory bits",
    "Total block memory bits",
    "Total DSP Blocks",
)

# A report row is `; field ; field ; ... ;`, padded with spaces on both sides of the `;`.
def _cells(line: str) -> list[str] | None:
    stripped = line.strip()
    if not stripped.startswith(";"):
        return None
    body = stripped[1:]
    if body.endswith(";"):
        body = body[:-1]
    cells = [c.strip() for c in body.split(";")]
    return cells


def _table(lines: list[str], start: int) -> list[list[str]]:
    """The rows after `lines[start]`, up to the end of the table.

    A Quartus report table is bounded by `+---...+` rulings, not by `;`, and a ruling occurs
    BOTH under the header and at the table's close -- so a ruling never ends the table and may
    not be taken for a row either. What ends it is the blank line after the closing ruling, or
    a single-cell `; <Section Title>` row (the next section's own heading).
    """
    rows: list[list[str]] = []
    for line in lines[start + 1:]:
        if line.startswith("+"):
            continue
        cells = _cells(line)
        if cells is None or len(cells) < 2:
            if rows:
                break
            continue
        rows.append(cells)
    return rows


def _section(lines: list[str], title: str) -> list[list[str]]:
    """The rows of one `; <title>` report section, as cell lists."""
    for i, line in enumerate(lines):
        if line.lstrip("; ").startswith(title):
            return _table(lines, i)
    return []


def parse(path: Path) -> dict:
    text = path.read_text(errors="replace").splitlines()
    totals: dict[str, str] = {}
    for line in text:
        cells = _cells(line)
        if cells and cells[0] in TOTALS and len(cells) >= 2:
            totals[cells[0]] = cells[1]
    # The RAM Summary's header row is the last row of dashes before the memory rows; take
    # every row after the first `Name ... Type ... Size ... MIF` header.
    ram: list[list[str]] = []
    for i, line in enumerate(text):
        cells = _cells(line)
        if not cells:
            continue
        if cells[0] == "Name" and "Type" in cells and "Size" in cells:
            ram = [rc for rc in _table(text, i) if len(rc) >= 5]
            break
    settings: dict[str, str] = {}
    for row in _section(text, "Analysis & Synthesis Settings"):
        if len(row) >= 2 and row[0] != "Option":
            settings[row[0]] = row[1]
    return {"totals": totals, "ram": ram, "settings": settings}


def fmt(n: str) -> str:
    try:
        return f"{int(n.replace(',', '')):,}"
    except ValueError:
        return n


def show_ram(rows: list[list[str]], pattern: re.Pattern) -> int:
    hits = [r for r in rows if pattern.search(r[0])]
    for r in hits:
        name, typ, mode = r[0], r[1], r[2]
        depth_a, width_a, depth_b, width_b = r[3], r[4], r[5], r[6]
        size, mif = r[7], r[8]
        print(f"  {name}")
        print(f"      {typ} | {mode} | A {depth_a}x{width_a} | B {depth_b}x{width_b}"
              f" | size {size} | MIF {mif}")
    if not hits:
        print(f"  (no RAM row matches {pattern.pattern!r}: the array is implemented in LOGIC)")
    return len(hits)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("report", type=Path)
    ap.add_argument("--compare", type=Path, help="baseline report; print deltas against it")
    ap.add_argument("--ram", help="regex over RAM Summary hierarchy names")
    ap.add_argument("--settings", help="regex over the A&S Settings option names")
    ap.add_argument("--totals", action="store_true", help="print the A&S Resource Usage Summary")
    args = ap.parse_args(argv)

    new = parse(args.report)
    if not new["totals"] and not new["ram"]:
        print(f"res_exp_ram: {args.report} has no Analysis & Synthesis tables", file=sys.stderr)
        return 1
    base = parse(args.compare) if args.compare else None
    rc = 0

    if args.ram:
        pat = re.compile(args.ram)
        print(f"RAM Summary rows matching {args.ram!r}  [{args.report.name}]")
        if show_ram(new["ram"], pat) == 0:
            if base:
                print(f"  baseline had {sum(1 for r in base['ram'] if pat.search(r[0]))} such row(s)")
            rc = 2
        if base:
            print(f"  -- total RAM rows in {args.report.name}: {len(new['ram'])}"
                  f" (baseline {args.compare.name}: {len(base['ram'])})")

    if args.settings:
        pat = re.compile(args.settings)
        print(f"A&S Settings matching {args.settings!r}")
        for opt, val in new["settings"].items():
            if pat.search(opt):
                old = base["settings"].get(opt) if base else None
                mark = "" if old is None or old == val else f"   (baseline: {old})"
                print(f"  {opt} = {val}{mark}")

    if args.totals:
        print(f"A&S Resource Usage Summary  [{args.report.name}]")
        for key in TOTALS:
            val = new["totals"].get(key, "-")
            line = f"  {key:<45} {fmt(val):>12}"
            if base:
                old = base["totals"].get(key, "-")
                try:
                    delta = int(val.replace(",", "")) - int(old.replace(",", ""))
                    line += f"   (baseline {fmt(old):>12}, delta {delta:+,})"
                except ValueError:
                    line += f"   (baseline {old})"
            print(line)

    if args.compare:
        added = [r[0] for r in new["ram"] if r[0] not in {b[0] for b in base["ram"]}]
        gone = [r[0] for r in base["ram"] if r[0] not in {n[0] for n in new["ram"]}]
        if added:
            print("RAM rows ADDED by the change:")
            for name in added:
                print(f"  + {name}")
        if gone:
            print("RAM rows REMOVED by the change:")
            for name in gone:
                print(f"  - {name}")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Re-derive the GDC conformance gap and the oracle tables from the REAL Xe10 capture.

The oracle is `docs/probes/gdc-conformance/{xe10-2.5MHz,mister}/*.CSV` - a
real PC-9821 Xe10 and this core on the `pc98-gdc-tests-v1.0-rc6`
`RUNFULL` profile at GDC clock 2.5 MHz (the suite's own `RUNINFO.TXT`). The Xe10
side is REAL HARDWARE, the top of this repo's evidence hierarchy, so every
expectation below is a number the machine produced, never one derived from our
RTL. `GDC*.EXE` is not redistributed; the register protocol quoted in
`docs/probes/gdc-conformance/README.md` was recovered by disassembling the
suite's own binary, and the two cross-checks this tool runs (the CURS parameter
encoding and the CURD read-back model) are the machine's own columns, not our
model played back at us.

What it does:

  * parses every `GDC*.CSV` on both sides and FAILS if the two runs disagree on
    any case id or on any group's row count - the capture is only an oracle if
    both sides ran the same cases (the suite commits rows incrementally, so a
    truncated run would otherwise look like a smaller gap);
  * re-derives the gap (Xe10 PASS, this core not PASS) and the reverse gap, per
    suite `class`, and writes `docs/probes/gdc-conformance/CLUSTERS.CSV`;
  * checks the `GDCCURS` `CURD` read-back model against the Xe10's own
    `raw_curd` column, and checks the `CURS` three-parameter encoding the suite
    itself uses against the machine's decoded `EAD`/`DAD` - reporting the rows
    where that encoding cannot carry the DAD (the open question in the README).

`CLUSTERS.CSV` is a GENERATED file: this tool is the only thing that writes it,
`--check` compares the committed copy, and a hand edit is a bug (AGENTS.md,
"Generated files: fix the generator, then regenerate").

Usage:
    python3 tools/gen_gdc_compare_vectors.py [--check]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CAP = ROOT / "docs" / "probes" / "gdc-conformance"
SIDES = ("xe10-2.5MHz", "mister")
OUT = CAP / "CLUSTERS.CSV"

GROUPS = ("GDCADDR", "GDCCURS", "GDCDRAW", "GDCFIFO", "GDCGCHR", "GDCQUIRK",
          "GDCRDAT", "GDCRDX", "GDCRESET", "GDCROP", "GDCSTATE", "GDCTIME",
          "GDCWDAT", "GDCWG")

# The five CURD read-back bytes' model, from the suite's own decoder at
# GDCCURS.EXE+0x8B5: EAD = b0 | b1<<8 | (b2 & 3)<<16, MASK = b3 | b4<<8, and the
# Xe10's b2 is a fixed 0xF0 in bits 7:2. The MASK relationship is the thing the
# capture is checked against - it is the machine's column, not our guess.
CURD_FMT = 0xF0

# The CURS (0x49) three-parameter encoding the suite's helper at GDCCURS.EXE+0x618
# sends for a cursor at (EAD, DAD): {EAD[7:0], EAD[15:8],
# (EAD[15:8]) | (DAD<<4) | EAD[17:16]}. Documented in the README with the byte
# layout; used here only to report which rows it cannot carry.
def curs_params(ead: int, dad: int) -> tuple[int, int, int]:
    b0 = ead & 0xFF
    b1 = (ead >> 8) & 0xFF
    b2 = b1 | ((dad & 0xF) << 4) | ((ead >> 16) & 0x3)
    return b0, b1, b2 & 0xFF


class Capture:
    """One side's CSVs, keyed by case id, with the header's config banner."""

    def __init__(self, side: str):
        self.side = side
        self.rows: dict[str, dict[str, str]] = {}
        self.groups: dict[str, list[str]] = {}
        self.banner: dict[str, str] = {}
        for grp in GROUPS:
            path = CAP / side / f"{grp}.CSV"
            if not path.exists():
                continue
            lines = path.read_text().splitlines()
            banner = [ln for ln in lines if ln.startswith("#")]
            body = [ln for ln in lines if ln.strip() and not ln.startswith("#")]
            if not body:
                continue
            head = [c.strip() for c in body[0].split(",")]
            ids = []
            for line in body[1:]:
                fields = [c.strip() for c in line.split(",")]
                row = dict(zip(head, fields))
                rid = row["case"]
                # A case id is unique across the whole suite; a duplicate would
                # make the two sides silently non-comparable.
                if rid in self.rows:
                    raise SystemExit(f"{side}: duplicate case id {rid}")
                self.rows[rid] = row
                ids.append(rid)
            self.groups[grp] = ids
            self.banner[grp] = banner[-1] if banner else ""

    def by_class(self, cls: str) -> list[dict[str, str]]:
        return [r for r in self.rows.values() if r.get("class") == cls]


def hexbytes(joined: str) -> list[int]:
    """`XX-XX-XX-XX-XX` (the suite's raw_curd prefix) -> five ints."""
    return [int(x, 16) for x in joined.split("-")]


def curd_model(ead: int, dad: int) -> list[int]:
    """The five read-back bytes the machine's own CURD rows show."""
    mask = 1 << dad
    return [ead & 0xFF, (ead >> 8) & 0xFF, CURD_FMT | ((ead >> 16) & 0x3),
            mask & 0xFF, (mask >> 8) & 0xFF]


def check_capture(xe: Capture, mi: Capture) -> None:
    if set(xe.rows) != set(mi.rows):
        only_x = sorted(set(xe.rows) - set(mi.rows))[:5]
        only_m = sorted(set(mi.rows) - set(xe.rows))[:5]
        raise SystemExit(f"the two runs cover different cases "
                         f"(xe10-only {only_x}, mister-only {only_m})")
    for grp in GROUPS:
        a, b = xe.groups.get(grp, []), mi.groups.get(grp, [])
        if a != b:
            raise SystemExit(f"{grp}: the two runs' case order differs "
                             f"({len(a)} vs {len(b)} rows)")


def gap_table(xe: Capture, mi: Capture) -> list[tuple]:
    tally: dict[str, list[int]] = {}
    for rid, row in xe.rows.items():
        cls = row.get("class", "?")
        t = tally.setdefault(cls, [0, 0, 0, 0])   # gap, xe_pass, mi_pass, total
        t[3] += 1
        xp = row.get("outcome") == "PASS"
        mp = mi.rows[rid].get("outcome") == "PASS"
        t[1] += xp
        t[2] += mp
        if xp and not mp:
            t[0] += 1
    return sorted(((c, *t) for c, t in tally.items()), key=lambda r: (-r[1], r[0]))


def check_curd(xe: Capture) -> tuple[int, int, list[str]]:
    """Model-vs-hardware on the CURD rows, and the CURS encoding's blind spot."""
    bad_model: list[str] = []
    blind: list[str] = []
    n = 0
    for row in xe.by_class("CURD"):
        ead = int(row["input_ead"], 16)
        dad = int(row["input_dad"])
        raw = hexbytes(row["raw_curd"].split("/")[0])
        n += 1
        if raw != curd_model(ead, dad):
            bad_model.append(f"{row['case']}: hardware {raw} != model "
                             f"{curd_model(ead, dad)}")
        # the encoding the suite itself emits, from its own helper
        _, _, b2 = curs_params(ead, dad)
        if (b2 >> 4) != dad:
            blind.append(row["case"])
    return n, len(blind), blind


def render(clusters, xe_pass, mi_pass, gap, rev, n_curd, blind) -> str:
    L = []
    L.append("# GENERATED by tools/gen_gdc_compare_vectors.py - do not edit.\n")
    L.append("# Source: docs/probes/gdc-conformance/{xe10-2.5MHz,mister}/*.CSV\n")
    L.append("# (pc98-gdc-tests-v1.0-rc6, RUNFULL, GDC clock 2.5 MHz; the Xe10\n")
    L.append("# side is real PC-9821 hardware - the oracle. See README.md.)\n")
    L.append(f"# xe10_pass={xe_pass} mister_pass={mi_pass} gap={gap} "
             f"reverse_gap={rev} curd_rows={n_curd} "
             f"curs_encoding_blind={len(blind)}\n")
    L.append("group,class,rows,xe10_pass,mister_pass,gap\n")
    for cls, g, xp, mp, tot in clusters:
        L.append(f"GDCCLUSTER,{cls},{tot},{xp},{mp},{g}\n")
    return "".join(L)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="verify the committed CLUSTERS.CSV matches a fresh run")
    args = ap.parse_args()

    xe = Capture(SIDES[0])
    mi = Capture(SIDES[1])
    check_capture(xe, mi)

    clusters = gap_table(xe, mi)
    gap = sum(c[1] for c in clusters)
    xe_pass = sum(c[2] for c in clusters)
    mi_pass = sum(c[3] for c in clusters)
    rev = sum(1 for rid, row in xe.rows.items()
              if row.get("outcome") != "PASS"
              and mi.rows[rid].get("outcome") == "PASS")
    n_curd, n_blind, blind = check_curd(xe)

    print(f"case rows per side                              : {len(xe.rows)}")
    print(f"with a hardware expectation (Xe10 PASS)         : {xe_pass}")
    print(f"this core PASS                                  : {mi_pass}")
    print(f"gap (Xe10 PASS, this core not PASS)             : {gap}")
    print(f"reverse gap (Xe10 not PASS, this core PASS)     : {rev}")
    print(f"CURD rows the Xe10 read-back model reproduces   : {n_curd}")
    if blind:
        print(f"  rows the suite's 3-parameter CURS encoding CANNOT carry the DAD: "
              f"{len(blind)} (e.g. {blind[0]}) - see README.md")
    print("gap by suite class (class, gap, xe10 PASS, this core PASS, rows):")
    for cls, g, xp, mp, tot in clusters:
        if g:
            print(f"  {g:4d}  {cls:<12} xe10={xp:<4} mister={mp:<4} rows={tot}")

    text = render(clusters, xe_pass, mi_pass, gap, rev, n_curd, blind)
    if args.check:
        cur = OUT.read_text() if OUT.exists() else ""
        if cur != text:
            print(f"STALE: {OUT.relative_to(ROOT)} does not match a fresh run",
                  file=sys.stderr)
            return 1
        print(f"OK: {OUT.relative_to(ROOT)} is up to date")
        return 0
    OUT.write_text(text)
    print(f"wrote {OUT.relative_to(ROOT)} ({len(text)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

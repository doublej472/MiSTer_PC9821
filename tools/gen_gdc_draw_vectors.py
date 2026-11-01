#!/usr/bin/env python3
"""Generate the graphics GDC's figure-drawing replay vectors from the REAL Xe10 capture.

The oracle is `docs/probes/gdc-conformance/xe10-2.5MHz/{GDCDRAW,GDCGCHR,GDCROP}.CSV`:
a real PC-9821 Xe10 running `pc98-gdc-tests-v1.0-rc6` at GDC clock 2.5 MHz (see
that directory's README.md). Every expected word and cursor below is a value the
MACHINE wrote or reported - the CSV's `changes` and `curd` columns - never one derived
from this repo's RTL. The tool only re-encodes the rows' own inputs and outputs as
SystemVerilog constants for `tb_pc9821_gdc2_figure_xe10`.

What a row carries (the bench programs exactly this and compares exactly this):

  * the command (FIGD 0x6C or GCHRD 0x68), FIGS P1/DC/D/D2/D1/DM, the cursor (EAD, dAD),
    the PRAM pattern bytes RA8..RA15, the GCHRD zoom and the ROP;
  * the seeded old value of every word the row lists (`old` in `R:WORD:OLD>NEW`), every
    other GVRAM word zero;
  * the expected new value of each listed word, the total count of changed R-plane words
    the machine reported, whether the list is the complete set (the suite truncates long
    lists), and the machine's CURD cursor (EAD, MASK).

Inputs the CSV does not spell out, and where they come from:

  * GDCDRAW and GDCROP rows use the ROP the row names (GDCROP's `rop` column), or SET for
    GDCDRAW, and the all-ones line pattern except LINE_PATTERN_A53C (`line-pattern`, the
    A53C its name and its output carry);
  * GDCGCHR rows start at EAD 0x9000, dAD 8 - the cursor every GDCDRAW/GDCROP row starts
    from (`start_ead`/`start_dad`) - and use SET; their PRAM bytes are the row's own
    `pram=K.B` (one-hot), `solid` (all FF), `onehot-pram15.0`, `opcode=7K;one-byte=V`, or
    `pattern=all-zero`;
  * the eight GCHR_SLANT rows' PRAM pattern is not recorded by the suite. ONE byte set,
    81 42 24 18 18 24 42 81 (RA8..RA15, an X), reproduces SLANT_D0's 9 words exactly and
    the other seven directions' rows then follow from it - so seven of the eight are
    predictions, not fits. GCHR_REPLACE's REPLACE_MIXED (pattern not recorded) is skipped.

`gdc_draw_xe10_vectors.svh` is a GENERATED file: this tool is the only thing that writes
it and `--check` compares the committed copy (AGENTS.md, "Generated files").

Usage:
    python3 tools/gen_gdc_draw_vectors.py [--check]
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CAP = ROOT / "docs" / "probes" / "gdc-conformance" / "xe10-2.5MHz"
OUT = ROOT / "tests" / "pc9821" / "gdc_draw_xe10_vectors.svh"

FIGD, GCHRD = 0x6C, 0x68
SLANT_RA = [0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81]   # RA8..RA15
PLANES = {"E": 0, "B": 1, "R": 2, "G": 3}                      # EAD bits 15:14
MAXCH = 32                                                     # listed words kept per row


def rows(name: str):
    lines = [l for l in (CAP / name).read_text().splitlines() if not l.startswith("#")]
    rd = list(csv.reader(lines))
    hdr = rd[0]
    for r in rd[1:]:
        if len(r) >= len(hdr):
            yield dict(zip(hdr, r))


def parse_changes(s: str):
    """`N/P:WORD:OLD>NEW|...` -> (N, [(plane, word, old, new)], complete)."""
    if "/" not in s:
        return 0, [], True
    n, rest = s.split("/", 1)
    out = []
    for e in rest.split("|") if rest else []:
        p = e.split(":")
        if len(p) != 3 or ">" not in p[2]:
            continue
        old, new = p[2].split(">")
        if len(old) != 4 or len(new) != 4:
            continue    # the suite's own truncation marker ("8000...")
        out.append((PLANES[p[0]], int(p[1], 16), int(old, 16), int(new, 16)))
    return int(n), out, int(n) == len(out)


def parse_curd(s: str):
    """`28-90-F0-01-00/09028/M0001/D0` -> (EAD[15:0], MASK, raw byte 2)."""
    raw = [int(b, 16) for b in s.split("/")[0].split("-")]
    return raw[0] | (raw[1] << 8), raw[3] | (raw[4] << 8), raw[2]


def w14(v: int) -> int:
    return int(v) & 0x3FFF


class Row:
    def __init__(self, rid, cmd, p1, dc, d, d2, d1, dm, ead, dad, ra, zoom, rop, chg, curd):
        self.rid, self.cmd, self.p1 = rid, cmd, p1
        self.dc, self.d, self.d2, self.d1, self.dm = map(w14, (dc, d, d2, d1, dm))
        self.ead, self.dad, self.ra, self.zoom, self.rop = ead, dad, ra, zoom, rop
        self.n, self.ch, self.complete = chg
        self.curd_ead, self.curd_mask, self.curd_b2 = curd


def ra_line(pattern: int):
    ra = [0] * 8
    ra[0], ra[1] = pattern & 0xFF, pattern >> 8          # RA8, RA9
    return ra


def collect():
    out = []
    for r in rows("GDCDRAW.CSV"):
        kind = r["kind"]
        if kind not in ("dot", "line", "raw-line", "rect", "line-pattern"):
            continue
        if r["outcome"] == "ERROR":
            continue
        pat = 0xA53C if kind == "line-pattern" else 0xFFFF
        out.append(Row(r["case"], FIGD, int(r["p1"], 16), int(r["dc"]), int(r["d"]),
                       int(r["d2"]), int(r["d1"]), int(r["dm"]), int(r["start_ead"], 16),
                       int(r["start_dad"]), ra_line(pat), 0, 3,
                       parse_changes(r["changes"]), parse_curd(r["curd"])))
    for r in rows("GDCROP.CSV"):
        cls = r["class"]
        if cls not in ("FIGD_ROP", "FIGD_PATTERN", "FIGD_PATTERN_LINE"):
            continue
        rop, old, pat = int(r["rop"]), int(r["old"], 16), int(r["pattern"], 16)
        n, ch, complete = parse_changes(r["changes"])
        if cls == "FIGD_PATTERN_LINE":
            # the 48-pixel canonical horizontal line from word 0x1000, dAD 0 (`curd` ends
            # one word past it); every one of its three words is seeded with `old`.
            p1, dc, d, d2, d1, dad = 0x0A, 47, -47, -94, 0, 0
            seeds = [(2, 0x1000 + k, old) for k in range(3)]
        else:
            p1, dc, d, d2, d1, dad = 0x00, 0, 8, 8, -1, int(r["dad"])
            seeds = [(2, 0x1000, old)]
        out.append(Row(r["case"], FIGD, p1, dc, d, d2, d1, -1, 0x9000, dad, ra_line(pat), 0,
                       rop, (n, ch, complete), parse_curd(r["curd"])))
        out[-1].seeds = seeds
    for r in rows("GDCGCHR.CSV"):
        cls = r["class"]
        prm = {}
        for kv in r["params"].split(";"):
            k, _, v = kv.partition("=")
            prm[k] = v
        ra, zoom, rop, seeds = [0] * 8, 0, 3, None
        dirn, dc, d = int(prm.get("dir", 0)), int(prm.get("dc", 7)), int(prm.get("d", 8))
        p1 = 0x10 | dirn
        if cls == "GCHR_ONEHOT":
            byte, bit = prm["pram"].split(".")
            ra[int(byte) - 8] = 1 << int(bit)
            zoom = int(prm["zoom"]) - 1
        elif cls == "GCHR_AREA":
            ra = [0xFF] * 8
        elif cls == "GCHR_ZOOM":
            ra[7] = 0x01
            zoom = int(prm["zoomreg"])
        elif cls == "GCHR_SLANT":
            ra = list(SLANT_RA)
            p1 |= 0x80
        elif cls == "GCHR_PRAM_ADDR":
            ra[int(prm["opcode"], 16) - 0x78] = int(prm["one-byte"], 16)
        elif cls == "GCHR_REPLACE":
            if "all-zero" not in r["params"]:
                continue    # REPLACE_MIXED: the suite does not record its pattern
            rop = 0
        else:
            continue
        row = Row(r["case"], GCHRD, p1, dc, d, d, -1, -1, 0x9000, 8, ra, zoom, rop,
                  parse_changes(r["changes"]), parse_curd(r["curd"]))
        out.append(row)
    for row in out:
        if not hasattr(row, "seeds"):
            row.seeds = [(p, w, o) for (p, w, o, _) in row.ch if o != 0]
    return out


def fmt_id(text: str) -> str:
    return text.encode("ascii")[:16].ljust(16, b" ").hex()


def render(vs) -> str:
    L = []
    L.append("// GENERATED by tools/gen_gdc_draw_vectors.py - do not edit.\n")
    L.append("// Source: docs/probes/gdc-conformance/xe10-2.5MHz/{GDCDRAW,GDCROP,GDCGCHR}.CSV\n")
    L.append("// (pc98-gdc-tests-v1.0-rc6, GDC clock 2.5 MHz, a real PC-9821 Xe10). Every\n")
    L.append("// expected word and cursor is the machine's own `changes`/`curd` column.\n\n")
    chs, seeds = [], []
    cfgs = []
    for v in vs:
        ch = v.ch[:MAXCH]
        sd = v.seeds[:MAXCH]
        cfgs.append((v, len(chs), len(ch), len(seeds), len(sd)))
        chs += [(p, w, n) for (p, w, _, n) in ch]
        seeds += sd
    L.append(f"localparam int GDX_N = {len(vs)};\n")
    L.append(f"localparam int GDX_NCH = {len(chs)};\n")
    L.append(f"localparam int GDX_NSEED = {len(seeds)};\n")
    L.append("// GDX_CFG: {cmd[7:0], p1[7:0], dc[13:0], d[13:0], d2[13:0], d1[13:0], dm[13:0],\n")
    L.append("//   ead[15:0], dad[3:0], ra8..ra15[63:0], zoom[3:0], rop[1:0], n_changed[15:0],\n")
    L.append("//   complete, ch_off[15:0], n_listed[7:0], seed_off[15:0], n_seed[7:0],\n")
    L.append("//   curd_ead[15:0], curd_mask[15:0], curd_b2[7:0]}; GDX_ID: the row's id, 16 ASCII bytes\n")
    fields_w = [8, 8, 14, 14, 14, 14, 14, 16, 4, 64, 4, 2, 16, 1, 16, 8, 16, 8, 16, 16, 8]
    width = sum(fields_w)
    L.append(f"localparam int GDX_CFGW = {width};\n")
    L.append("localparam [127:0] GDX_ID [0:GDX_N-1] = '{\n")
    L.append(",\n".join(f"  128'h{fmt_id(v.rid)}" for v in vs) + "\n};\n")
    L.append("localparam [GDX_CFGW-1:0] GDX_CFG [0:GDX_N-1] = '{\n")
    elems = []
    for k, (v, choff, nch, sdoff, nsd) in enumerate(cfgs):
        vals = [v.cmd, v.p1, v.dc, v.d, v.d2, v.d1, v.dm, v.ead, v.dad,
                sum(b << (8 * (7 - i)) for i, b in enumerate(v.ra)), v.zoom, v.rop, v.n,
                1 if (v.complete and len(v.ch) <= MAXCH) else 0, choff, nch, sdoff, nsd,
                v.curd_ead, v.curd_mask, v.curd_b2]
        val = 0
        for f, w in zip(vals, fields_w):
            val = (val << w) | (f & ((1 << w) - 1))
        comma = "," if k < len(vs) - 1 else ""
        elems.append(f"  {width}'h{val:0{(width + 3) // 4}X}{comma}  // {v.rid}")
    L.append("\n".join(elems) + "\n};\n\n")
    L.append("// GDX_CH[k]: {plane[1:0], word[13:0], new_cpu[15:0]} (the listed words, row by row)\n")
    L.append("localparam [31:0] GDX_CH [0:GDX_NCH-1] = '{\n")
    L.append(",\n".join("  " + ", ".join(f"32'h{(p << 30) | (w << 16) | n:08X}"
                                          for (p, w, n) in chs[i:i + 8])
                        for i in range(0, len(chs), 8)) + "\n};\n\n")
    L.append("// GDX_SEED[k]: {plane[1:0], word[13:0], old_cpu[15:0]} (seeded before the row)\n")
    L.append("localparam [31:0] GDX_SEED [0:GDX_NSEED-1] = '{\n")
    L.append(",\n".join("  " + ", ".join(f"32'h{(p << 30) | (w << 16) | o:08X}"
                                          for (p, w, o) in seeds[i:i + 8])
                        for i in range(0, len(seeds), 8)) + "\n};\n")
    return "".join(L)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="verify the committed vectors match a fresh run")
    args = ap.parse_args()
    vs = collect()
    text = render(vs)
    print(f"rows: {len(vs)} (complete lists: {sum(1 for v in vs if v.complete)})")
    if args.check:
        cur = OUT.read_text() if OUT.exists() else ""
        if cur != text:
            print(f"STALE: {OUT.relative_to(ROOT)} does not match a fresh run", file=sys.stderr)
            return 1
        print(f"OK: {OUT.relative_to(ROOT)} is up to date")
        return 0
    OUT.write_text(text)
    print(f"wrote {OUT.relative_to(ROOT)} ({len(text)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

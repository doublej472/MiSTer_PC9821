#!/usr/bin/env python3
"""Area of a design from its fits, split into the part a cut can own and the part it cannot.

    tools/fit_area.py show SWEEP|SEED ...                 # one row per fit
    tools/fit_area.py compare --base SWEEP... --cand SWEEP... [--depth 4] [--top 15]
    tools/fit_area.py survey ROOT ...                     # within-source seed spread, per metric
    tools/fit_area.py --selftest

A SWEEP is a directory of seedNNN/ (a seed_sweep.py or remote_fit.py run); a SEED is one
seedNNN/ (or any directory holding output_files/). Several sweeps may make up one side.

WHY THIS EXISTS. The fitter's `ALMs needed [=A-B+C]` (fit.summary's `Logic utilization`) is the
sum of two different things:

  map_alms   Analysis & Synthesis' `Estimate of Logic utilization (ALMs needed)`. A function of
             the source alone: every seed of one source reads the SAME value (survey: sd 0 over
             66 same-source groups, 640 fits). Its ALUT and register counts likewise.
  psyn_alms  alms_needed - map_alms: what the fitter adds - physical synthesis at `Extra` effort,
             register duplication and retiming, routability duplication. Within one source its
             seed sd is ~40-150; ACROSS sources at the same clock it ranges ~1,650..2,800 and
             moves by hundreds on a change of a few hundred ALUTs (one series of area cuts:
             +4 on 49008d8c, +424 on 127eda63). It is a deterministic response of the fitter to the
             whole netlist under a design that misses timing by ~5 ns everywhere, not noise
             that more seeds average away.

So a change's own area is read from map_* (exact, one A&S run per side) and, per module, from
the entity tables (map and fit); the fit-level alms_needed/LABs are reported with their seed SE
and the psyn term beside them, so a fit delta that is all psyn is visible as such. The
netlist-optimization counts (Created/Duplicated/Retimed by physical synthesis and the router)
say where psyn went.

`compare` prints per metric: each side's mean, sd and n, the delta, and 2 x its standard error
(an `exact` delta where both sides are constant). `survey` groups every fit under the roots by
the source hash recorded in output_files/fit-source.sha256 (plus the configuration) and prints
each metric's pooled within-source sd: the seed noise floor a sweep must beat.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

PROJECT = "z486_mister"

# Fitter Resource Usage Summary rows (fit.rpt), value = the first number after the label.
FIT_ROWS = (
    ("alms_needed", r"ALMs needed \[=A-B\+C\]"),
    ("alms_placed", r"\[A\] ALMs used in final placement \[=a\+b\+c\+d\]"),
    ("alms_lut_reg", r"\[a\] ALMs used for LUT logic and registers"),
    ("alms_lut", r"\[b\] ALMs used for LUT logic"),
    ("alms_reg", r"\[c\] ALMs used for registers"),
    ("alms_mem", r"\[d\] ALMs used for memory \(up to half of total ALMs\)"),
    ("alms_dense", r"\[B\] Estimate of ALMs recoverable by dense packing"),
    ("alms_unavail", r"\[C\] Estimate of ALMs unavailable \[=a\+b\+c\+d\]"),
    ("labs", r"Total LABs:  partially or completely used"),
    ("fit_aluts", r"Combinational ALUT usage for logic"),
    ("route_thru", r"Combinational ALUT usage for route-throughs"),
    ("fit_regs", r"Dedicated logic registers"),
)
# Analysis & Synthesis Resource Usage Summary rows (map.rpt).
MAP_ROWS = (
    ("map_alms", r"Estimate of Logic utilization \(ALMs needed\)"),
    ("map_aluts", r"Combinational ALUT usage for logic"),
    ("map_regs", r"Dedicated logic registers"),
)
# The metrics in print order. The psyn_* are derived (fit minus map).
METRICS = ("map_alms", "map_aluts", "map_regs", "alms_needed", "psyn_alms", "psyn_aluts",
           "psyn_regs", "labs", "alms_placed", "alms_dense", "alms_unavail", "fit_aluts",
           "route_thru", "fit_regs")
NUM = re.compile(r"(-?[\d,]+(?:\.\d+)?)")


def _num(text: str) -> float:
    v = float(text.replace(",", ""))
    return int(v) if v.is_integer() else v


def _section(path: Path, title: str, limit: int = 40000) -> str:
    """The text of the report table whose title row is `; <title>` (up to `limit` chars)."""
    out: list[str] = []
    size = 0
    try:
        with path.open(errors="replace") as handle:
            on = False
            for line in handle:
                if not on:
                    if line.startswith("; " + title) and line[2 + len(title):].strip(" ;\n") == "":
                        on = True
                    continue
                if not line.strip():
                    break
                out.append(line)
                size += len(line)
                if size > limit:
                    break
    except OSError:
        return ""
    return "".join(out)


def _rows(text: str, rows) -> dict:
    out = {}
    for key, label in rows:
        m = re.search(r"^;\s*" + label + r"\s*;\s*([\d,.]+)", text, re.MULTILINE)
        if m:
            out[key] = _num(m.group(1))
    return out


def entity_table(path: Path, title: str, columns: dict) -> dict:
    """{full hierarchy name: {key: total value}} from a `... Utilization by Entity` table.

    `columns` maps a header label to a key; a cell `263.0 (263.0)` gives its total (the first
    number), which includes the node's children."""
    out: dict = {}
    try:
        handle = path.open(errors="replace")
    except OSError:
        return out
    with handle:
        on, header = False, None
        for line in handle:
            if not on:
                if line.startswith("; " + title) and line[2 + len(title):].strip(" ;\n") == "":
                    on = True
                continue
            if not line.strip():
                break
            if not line.startswith(";"):
                continue
            cells = [c.strip() for c in line.strip().strip(";").split(";")]
            if header is None:
                header = cells
                continue
            row = dict(zip(header, cells))
            name = row.get("Full Hierarchy Name")
            if not name:
                continue
            vals = {}
            for label, key in columns.items():
                m = NUM.match(row.get(label, ""))
                if m:
                    vals[key] = _num(m.group(1))
            out[name] = vals
    return out


FIT_ENTITY = {"ALMs needed [=A-B+C]": "alms", "Combinational ALUTs": "aluts",
              "Dedicated Logic Registers": "regs"}
MAP_ENTITY = {"Combinational ALUTs": "aluts", "Dedicated Logic Registers": "regs"}


def netlist_optimizations(path: Path) -> dict:
    """Counts of the fitter's netlist changes by (action, source): e.g. psyn_created."""
    keys = {("Created", "Physical Synthesis"): "opt_psyn_created",
            ("Deleted", "Physical Synthesis"): "opt_psyn_deleted",
            ("Modified", "Physical Synthesis"): "opt_psyn_modified",
            ("Retimed Register", "Physical Synthesis"): "opt_psyn_retimed",
            ("Duplicated", "Router Logic Cell Insertion and Logic Duplication"): "opt_route_dup",
            ("Duplicated", "Register Packing"): "opt_pack_dup"}
    out = {v: 0 for v in keys.values()}
    try:
        handle = path.open(errors="replace")
    except OSError:
        return {}
    seen = False
    with handle:
        on, bars = False, 0
        for line in handle:
            if not on:
                if line.startswith("; Fitter Netlist Optimizations"):
                    on = seen = True
                continue
            if line.startswith("+"):
                bars += 1
                if bars >= 3:
                    break
                continue
            if not line.startswith(";"):
                if not line.strip():
                    break
                continue
            cells = [c.strip() for c in line.split(";")]
            if len(cells) > 3:
                k = keys.get((cells[2], cells[3]))
                if k:
                    out[k] += 1
    return out if seen else {}


def fit_area(seed_dir: Path, entities: bool = False) -> dict:
    """The area numbers of one fit (seed_dir holds output_files/, or is it)."""
    seed_dir = Path(seed_dir)
    of = seed_dir / "output_files" if (seed_dir / "output_files").is_dir() else seed_dir
    fit, mapr = of / f"{PROJECT}.fit.rpt", of / f"{PROJECT}.map.rpt"
    out: dict = {"dir": str(seed_dir)}
    m = re.match(r"seed(\d+)$", seed_dir.name)
    if m:
        out["seed"] = int(m.group(1))
    out.update(_rows(_section(fit, "Fitter Resource Usage Summary"), FIT_ROWS))
    out.update(_rows(_section(mapr, "Analysis & Synthesis Resource Usage Summary"), MAP_ROWS))
    for a, b, k in (("alms_needed", "map_alms", "psyn_alms"), ("fit_aluts", "map_aluts", "psyn_aluts"),
                    ("fit_regs", "map_regs", "psyn_regs")):
        if a in out and b in out:
            out[k] = out[a] - out[b]
    out.update(netlist_optimizations(fit))
    try:
        attr = (of / "fit-source.sha256").read_text(errors="replace")
        for key in ("rtl-hash", "config", "clock"):
            mm = re.search(rf"^{key}: (.*)$", attr, re.MULTILINE)
            if mm:
                out[key.replace("-", "_")] = mm.group(1).strip()
    except OSError:
        pass
    try:
        summary = (seed_dir / "summary.txt").read_text()
        mm = re.search(r"^verdict=(\w+)", summary, re.MULTILINE)
        if mm:
            out["verdict"] = mm.group(1)
    except OSError:
        pass
    if entities:
        out["fit_entities"] = entity_table(fit, "Fitter Resource Utilization by Entity", FIT_ENTITY)
        out["map_entities"] = entity_table(mapr, "Analysis & Synthesis Resource Utilization by Entity",
                                           MAP_ENTITY)
    return out


def seed_dirs(paths) -> list[Path]:
    out = []
    for p in map(Path, paths):
        if (p / "output_files").is_dir() or p.name.startswith("seed"):
            out.append(p)
        else:
            out.extend(sorted(d for d in p.glob("seed[0-9]*") if d.is_dir()))
    return out


def fits_of(paths, entities: bool = False) -> list[dict]:
    """The fits under `paths` that produced a fit report (a crashed seed has none)."""
    rows = [fit_area(d, entities) for d in seed_dirs(paths)]
    return [r for r in rows if "alms_needed" in r]


def crashed_of(paths) -> list[Path]:
    return [d for d in seed_dirs(paths) if "alms_needed" not in fit_area(d)]


def stats(values: list[float]) -> tuple:
    """(mean, sd, n); sd 0 for one value."""
    if not values:
        return (None, None, 0)
    return (statistics.mean(values), statistics.stdev(values) if len(values) > 1 else 0.0,
            len(values))


def delta(base: list[float], cand: list[float]) -> tuple:
    """(delta of means, 2 x its standard error, exact) - exact when both sides are constant."""
    mb, sb, nb = stats(base)
    mc, sc, nc = stats(cand)
    if not nb or not nc:
        return (None, None, False)
    exact = len(set(base)) == 1 and len(set(cand)) == 1
    se2 = 2 * math.sqrt((sb ** 2) / nb + (sc ** 2) / nc)
    return (mc - mb, se2, exact)


def _fmt(v, spec=",.0f"):
    return "-" if v is None else format(v, spec)


def cmd_show(args) -> int:
    rows = fits_of(args.paths)
    cols = ("seed", "map_alms", "alms_needed", "psyn_alms", "labs", "map_aluts", "fit_aluts",
            "map_regs", "fit_regs", "alms_dense", "opt_psyn_created", "opt_route_dup")
    print(" ".join(f"{c:>16}" for c in ("dir",) + cols))
    for r in rows:
        name = "/".join(Path(r["dir"]).parts[-2:])[-16:]
        print(" ".join([f"{name:>16}"] + [f"{_fmt(r.get(c)):>16}" for c in cols]))
    for d in crashed_of(args.paths):
        print(f"{d}: no fit report (crashed or not run)")
    return 0


def side(paths) -> tuple[list[dict], list[Path]]:
    return fits_of(paths, entities=True), crashed_of(paths)


def entity_deltas(base: list[dict], cand: list[dict], table: str, key: str,
                  depth: int) -> list[tuple]:
    """[(name, mean base, mean cand, delta, 2SE)] for every node at hierarchy depth <= `depth`."""
    names = set()
    for r in base + cand:
        names.update(n for n in r.get(table, {}) if n.count("|") <= depth)
    out = []
    for n in names:
        b = [r[table].get(n, {}).get(key, 0) for r in base if r.get(table)]
        c = [r[table].get(n, {}).get(key, 0) for r in cand if r.get(table)]
        if b and c:
            d, se2, _ = delta(b, c)
            out.append((n, statistics.mean(b), statistics.mean(c), d, se2))
    return out


def compare(base: list[dict], cand: list[dict]) -> list[dict]:
    out = []
    keys = list(METRICS) + sorted({k for r in base + cand for k in r if k.startswith("opt_")})
    for k in keys:
        b = [r[k] for r in base if isinstance(r.get(k), (int, float))]
        c = [r[k] for r in cand if isinstance(r.get(k), (int, float))]
        d, se2, exact = delta(b, c)
        out.append({"metric": k, "base": stats(b), "cand": stats(c), "delta": d, "se2": se2,
                    "exact": exact})
    return out


def cmd_compare(args) -> int:
    base, bcrash = side(args.base)
    cand, ccrash = side(args.cand)
    print(f"base: {len(base)} fits, {len(bcrash)} without a fit report; "
          f"cand: {len(cand)} fits, {len(ccrash)} without a fit report")
    for name, rows in (("base", base), ("cand", cand)):
        srcs = sorted({r.get("rtl_hash", "?") for r in rows})
        if len({r.get("map_alms") for r in rows}) > 1:
            print(f"WARNING: {name} mixes netlists (map_alms differs between its fits): {srcs}")
    print(f"{'metric':<18}{'base mean':>11}{'sd':>7}{'n':>4}{'cand mean':>12}{'sd':>7}{'n':>4}"
          f"{'delta':>9}{'2SE':>8}")
    for row in compare(base, cand):
        (mb, sb, nb), (mc, sc, nc) = row["base"], row["cand"]
        if not nb and not nc:
            continue
        band = "exact" if row["exact"] else _fmt(row["se2"])
        flag = ""
        if row["delta"] is not None and not row["exact"] and row["se2"] and \
                abs(row["delta"]) > row["se2"]:
            flag = "  *"
        print(f"{row['metric']:<18}{_fmt(mb):>11}{_fmt(sb):>7}{nb:>4}{_fmt(mc):>12}{_fmt(sc):>7}"
              f"{nc:>4}{_fmt(row['delta'], '+,.0f'):>9}{band:>8}{flag}")
    print("(* = |delta| > 2SE.  map_* are the source's own logic, exact per source; psyn_* is the\n"
          " fitter's growth, a per-source response that more seeds do not average away.)")
    if args.top:
        for table, key, label in (("map_entities", "aluts", "map ALUTs"),
                                  ("map_entities", "regs", "map registers"),
                                  ("fit_entities", "alms", "fit ALMs needed"),
                                  ("fit_entities", "aluts", "fit ALUTs")):
            rows = entity_deltas(base, cand, table, key, args.depth)
            rows.sort(key=lambda t: -abs(t[3]))
            print(f"\nlargest {label} deltas, hierarchy depth <= {args.depth}:")
            for n, b, c, d, se2 in rows[:args.top]:
                short = re.sub(r"[A-Za-z0-9_]+:", "", n)
                print(f"  {d:+9.1f} (2SE {se2:6.1f})  {b:10.1f} -> {c:10.1f}  {short}")
    return 0


def survey(rows: list[dict]) -> dict:
    """{metric: (pooled within-source sd, groups, fits)} over groups of >= 2 fits of one source."""
    groups: dict = defaultdict(list)
    for r in rows:
        if r.get("rtl_hash") and r.get("rtl_hash") != "(not given)":
            groups[(r["rtl_hash"], r.get("config", ""))].append(r)
    out = {}
    for k in METRICS:
        num = den = ng = nf = 0
        sds = []
        for rs in groups.values():
            v = [r[k] for r in rs if isinstance(r.get(k), (int, float))]
            if len(v) < 2:
                continue
            num += statistics.variance(v) * (len(v) - 1)
            den += len(v) - 1
            ng += 1
            nf += len(v)
            sds.append(statistics.stdev(v))
        if den:
            out[k] = (math.sqrt(num / den), ng, nf, statistics.median(sds), max(sds))
    return out


def cmd_survey(args) -> int:
    paths = []
    for root in map(Path, args.roots):
        paths.extend(p for p in root.glob("**/seed[0-9]*") if (p / "output_files").is_dir())
    rows = fits_of(sorted(set(paths)))
    res = survey(rows)
    print(f"{len(rows)} fits")
    print(f"{'metric':<16}{'pooled sd':>10}{'median sd':>10}{'max sd':>8}{'groups':>8}{'fits':>6}")
    for k, (sd, ng, nf, med, mx) in res.items():
        print(f"{k:<16}{sd:>10.1f}{med:>10.1f}{mx:>8.1f}{ng:>8}{nf:>6}")
    return 0


# ---------------------------------------------------------------- selftest ----

def _plant(root: Path, name: str, alms: int, map_alms: int, rtl: str, extra_entity: int = 0) -> Path:
    of = root / name / "output_files"
    of.mkdir(parents=True)
    (of / f"{PROJECT}.fit.rpt").write_text(f"""Fitter report
; Fitter Netlist Optimizations ;
+------+
; Node ; Action ; Operation ; Reason ;
+------+
; a~1 ; Created ; Physical Synthesis ; Timing optimization ;
; a~2 ; Created ; Physical Synthesis ; Timing optimization ;
; b~1 ; Duplicated ; Router Logic Cell Insertion and Logic Duplication ; Routability optimization ;
+------+

+------+
; Fitter Resource Usage Summary                                                               ;
+------+
; Logic utilization (ALMs needed / total ALMs on device)      ; {alms:,} / 41,910       ; 89 %  ;
; ALMs needed [=A-B+C]                                        ; {alms:,}                ;       ;
;     [A] ALMs used in final placement [=a+b+c+d]             ; 39,000 / 41,910       ; 93 %  ;
;     [B] Estimate of ALMs recoverable by dense packing       ; 2,459 / 41,910        ; 6 %   ;
;     [C] Estimate of ALMs unavailable [=a+b+c+d]             ; 806 / 41,910          ; 2 %   ;
; Total LABs:  partially or completely used                   ; 4,118 / 4,191         ; 98 %  ;
; Combinational ALUT usage for logic                          ; 57,420                ;       ;
; Combinational ALUT usage for route-throughs                 ; 5,017                 ;       ;
; Dedicated logic registers                                   ; 35,425                ;       ;

+------+
; Fitter Resource Utilization by Entity ;
+------+
; Compilation Hierarchy Node ; ALMs needed [=A-B+C] ; Combinational ALUTs ; Dedicated Logic Registers ; Full Hierarchy Name ; Entity Name ;
+------+
; |sys_top ; {alms}.0 (10.0) ; 57420 (5) ; 35425 (1) ; |sys_top ; sys_top ;
;    |kbd:kbd| ; {100 + extra_entity}.5 (100.5) ; 200 (200) ; 300 (300) ; |sys_top|kbd:kbd ; kbd ;
+------+
""")
    (of / f"{PROJECT}.map.rpt").write_text(f"""Map report
+------+
; Analysis & Synthesis Resource Usage Summary ;
+------+
; Resource                                    ; Usage ;
+------+
; Estimate of Logic utilization (ALMs needed) ; {map_alms} ;
;                                             ;       ;
; Combinational ALUT usage for logic          ; 55729 ;
; Dedicated logic registers                   ; 33772 ;

+------+
; Analysis & Synthesis Resource Utilization by Entity ;
+------+
; Compilation Hierarchy Node ; Combinational ALUTs ; Dedicated Logic Registers ; Full Hierarchy Name ; Entity Name ;
+------+
; |sys_top ; 55729 (1249) ; 33772 (1473) ; |sys_top ; sys_top ;
;    |kbd:kbd| ; {200 - extra_entity} (200) ; 300 (300) ; |sys_top|kbd:kbd ; kbd ;
+------+
""")
    (of / "fit-source.sha256").write_text(f"rtl-hash: {rtl}\nconfig: {{}}\n")
    (root / name / "summary.txt").write_text("seed=1\nverdict=passed\n")
    return root / name


def selftest() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        b1 = _plant(root / "base", "seed001", 37347, 35536, "aaaa")
        _plant(root / "base", "seed002", 37447, 35536, "aaaa")
        _plant(root / "cand", "seed001", 37100, 35300, "bbbb", extra_entity=7)
        _plant(root / "cand", "seed002", 37200, 35300, "bbbb", extra_entity=7)
        (root / "cand" / "seed003").mkdir()          # a crashed seed: no output_files
        r = fit_area(b1, entities=True)
        assert r["alms_needed"] == 37347 and r["map_alms"] == 35536, r
        assert r["psyn_alms"] == 37347 - 35536, r
        assert r["labs"] == 4118 and r["fit_aluts"] == 57420 and r["route_thru"] == 5017, r
        assert r["alms_placed"] == 39000 and r["alms_dense"] == 2459 and r["alms_unavail"] == 806, r
        assert r["map_aluts"] == 55729 and r["map_regs"] == 33772 and r["fit_regs"] == 35425, r
        assert r["opt_psyn_created"] == 2 and r["opt_route_dup"] == 1, r
        assert r["rtl_hash"] == "aaaa" and r["seed"] == 1 and r["verdict"] == "passed", r
        assert r["fit_entities"]["|sys_top|kbd:kbd"]["alms"] == 100.5, r["fit_entities"]
        assert r["map_entities"]["|sys_top|kbd:kbd"]["aluts"] == 200, r["map_entities"]
        base, bc = side([root / "base"])
        cand, cc = side([root / "cand"])
        assert len(base) == 2 and len(cand) == 2 and len(cc) == 1 and not bc, (base, cand, cc)
        rows = {x["metric"]: x for x in compare(base, cand)}
        assert rows["map_alms"]["exact"] and rows["map_alms"]["delta"] == -236, rows["map_alms"]
        assert not rows["alms_needed"]["exact"] and rows["alms_needed"]["delta"] == -247, rows
        se = 2 * math.sqrt(2 * (statistics.stdev([37347, 37447]) ** 2) / 2)
        assert abs(rows["alms_needed"]["se2"] - se) < 1e-9, rows["alms_needed"]
        ent = {n: d for n, _, _, d, _ in entity_deltas(base, cand, "fit_entities", "alms", 2)}
        assert ent["|sys_top|kbd:kbd"] == 7, ent
        ent = {n: d for n, _, _, d, _ in entity_deltas(base, cand, "map_entities", "aluts", 2)}
        assert ent["|sys_top|kbd:kbd"] == -7, ent
        # Depth filter: depth 1 excludes the kbd node.
        assert all(n.count("|") <= 1 for n, *_ in entity_deltas(base, cand, "fit_entities",
                                                                 "alms", 1))
        sv = survey(base + cand)
        assert sv["map_alms"][0] == 0.0 and sv["map_alms"][1] == 2, sv
        assert abs(sv["alms_needed"][0] - statistics.stdev([37347, 37447])) < 1e-9, sv
        # A planted mixed side must be visible: map_alms not constant.
        _plant(root / "mixed", "seed001", 37347, 35536, "aaaa")
        _plant(root / "mixed", "seed002", 37347, 35000, "cccc")
        mixed, _ = side([root / "mixed"])
        assert len({x["map_alms"] for x in mixed}) == 2
    print("fit_area selftest: PASS")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--selftest", action="store_true")
    sub = p.add_subparsers(dest="cmd")
    s = sub.add_parser("show")
    s.add_argument("paths", nargs="+")
    c = sub.add_parser("compare")
    c.add_argument("--base", nargs="+", required=True)
    c.add_argument("--cand", nargs="+", required=True)
    c.add_argument("--depth", type=int, default=4, help="entity hierarchy depth (| count)")
    c.add_argument("--top", type=int, default=15, help="entity rows per table (0: none)")
    v = sub.add_parser("survey")
    v.add_argument("roots", nargs="+")
    args = p.parse_args()
    if args.selftest:
        return selftest()
    if args.cmd == "show":
        return cmd_show(args)
    if args.cmd == "compare":
        return cmd_compare(args)
    if args.cmd == "survey":
        return cmd_survey(args)
    p.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())

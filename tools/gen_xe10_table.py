#!/usr/bin/env python3
"""Write src/pc9821/core/pc9821_xe10_timing_pkg.sv: OSD I/O timing = Xe10's class table.

THE SOURCE IS tools/xe10_classes.csv, one row per class: the device (gvram, tram, pegc), the class
(direction, width, GRCG kind), the display mode (24 = 24 kHz, 31 = 31 kHz with the 256-colour
display off, 48 = 31 kHz with it on, 24P = 24 kHz with it on), the raster phase (V = not on a graphics line, A = on one),
the SHAPE (`latency`: a read the CPU waits for, so the CPU's own work adds on; `rate`: a store's
accept-to-accept period, which the work between stores hides), the value in ns and the capture row
it comes from. `tools/check_xe10_table.py` re-derives every value from that row; this script only
validates the table's shape and renders it. The rendered package is generated, never edited
(AGENTS.md: fix the generator, then regenerate).

THE PACKAGE holds the ns values (x10, one decimal) as one packed vector, the class bases, each
device's largest value (its counters' width guard: a max() the generator takes, not an OR list in
the RTL), the conversion rule every device writes inline (nearest clk_sys, so a class is the same real
time at every profile clock; inline because the SAT proofs' yosys reads no package function) and
the cycle tables that rule gives at every preset build profile's clock (build_profile.py's
PROFILES). Entry layout: class base + 2 * mode + phase, mode 0/1/2/3 = 24/31/48/24P,
phase 0/1 = V/A; each class is XE10_PER_CLASS = 8 entries.

Usage:
  tools/gen_xe10_table.py           validate, then write the package
  tools/gen_xe10_table.py --check   validate and compare (the gate's static check)
  tools/gen_xe10_table.py --print   print the package
"""
from __future__ import annotations

import csv
import importlib.util
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CSV = ROOT / "tools/xe10_classes.csv"
PKG = ROOT / "src/pc9821/core/pc9821_xe10_timing_pkg.sv"

DEVICES = (("gvram", "GV"), ("tram", "TX"), ("pegc", "PK"))
MODES = ("24", "31", "48", "24P")
PER_CLASS = len(MODES) * 2   # entries per class: every mode, both phases
PHASES = ("V", "A")
FIELDS = ("name", "device", "cls", "dir", "width", "kind", "mode", "phase", "shape", "ns",
          "basis", "source", "line", "quantity")
QUANTITIES = ("pit", "net", "art", "rwipe", "pair")


ENTRY_MAX = 0xFFFF           # each package entry is 16 bits wide ([16*i +: 16])


def read_rows(path: Path = CSV) -> list[dict]:
    lines = [ln for ln in path.read_text().splitlines() if ln.strip() and not ln.startswith("#")]
    rd = csv.DictReader(lines)
    if tuple(rd.fieldnames or ()) != FIELDS:
        raise SystemExit(f"{path}: header is {rd.fieldnames}, want {list(FIELDS)}")
    return [dict(r) for r in rd]


def problems(rows: list[dict]) -> list[str]:
    """Every shape rule the table must keep; empty = valid."""
    out = []
    names = set()
    order = []
    for i, r in enumerate(rows):
        where = f"row {i + 2} ({r.get('name')})"
        pre = dict(DEVICES).get(r["device"])
        if pre is None:
            out.append(f"{where}: device {r['device']!r} is not one of {[d for d, _ in DEVICES]}")
            continue
        want = f"{pre}_{r['cls'].upper()}_{r['mode']}{r['phase']}"
        if r["name"] != want:
            out.append(f"{where}: name must be {want}")
        if r["name"] in names:
            out.append(f"{where}: duplicate name")
        names.add(r["name"])
        if r["mode"] not in MODES or r["phase"] not in PHASES:
            out.append(f"{where}: mode/phase {r['mode']}{r['phase']}")
        if r["dir"] not in ("rd", "wr"):
            out.append(f"{where}: dir {r['dir']!r}")
        elif r["shape"] != ("latency" if r["dir"] == "rd" else "rate"):
            out.append(f"{where}: a {r['dir']} class is {'latency' if r['dir'] == 'rd' else 'rate'}-shaped")
        if not r["cls"].startswith(r["dir"] + "_") and r["cls"] != r["dir"]:
            out.append(f"{where}: class {r['cls']!r} does not start with its direction")
        if not re.fullmatch(r"\d{2,4}\.\d", r["ns"]):
            out.append(f"{where}: ns {r['ns']!r} is not one-decimal")
        elif ns_x10(r) > ENTRY_MAX:
            # every package entry is a 16'd literal (ns x10, and the cycle counts below it)
            out.append(f"{where}: ns {r['ns']} (x10 = {ns_x10(r)}) does not fit a 16-bit entry")
        if r["quantity"] not in QUANTITIES:
            out.append(f"{where}: quantity {r['quantity']!r}")
        if not r["line"].isdigit():
            out.append(f"{where}: line {r['line']!r}")
        if not (ROOT / r["source"]).is_file():
            out.append(f"{where}: no such capture {r['source']}")
        if r["basis"] != "measured" and not re.fullmatch(r"fallback-(24|31)", r["basis"]):
            out.append(f"{where}: basis {r['basis']!r}")
        if r["basis"].startswith("fallback-") and r["basis"][-2:] == r["mode"]:
            out.append(f"{where}: a row cannot fall back to its own mode")
        order.append((r["device"], r["cls"], r["mode"], r["phase"]))
    # each class is PER_CLASS consecutive rows in mode-then-phase order, devices in DEVICES order
    seen_cls = []
    for k in range(0, len(order), PER_CLASS):
        grp = order[k:k + PER_CLASS]
        if len(grp) != PER_CLASS or {(d, c) for d, c, _, _ in grp} != {grp[0][:2]}:
            out.append(f"rows {k + 2}..: a class is not {PER_CLASS} consecutive rows")
            break
        if [(m, p) for _, _, m, p in grp] != [(m, p) for m in MODES for p in PHASES]:
            out.append(f"class {grp[0][1]}: rows are not in "
                       f"{' '.join(m + p for m in MODES for p in PHASES)} order")
        if grp[0][:2] in seen_cls:
            out.append(f"class {grp[0][1]} of {grp[0][0]} appears twice")
        seen_cls.append(grp[0][:2])
    devs = [d for d, _ in seen_cls]
    if devs != sorted(devs, key=[d for d, _ in DEVICES].index):
        out.append("devices are not in gvram, tram, pegc order")
    # a fallback row carries exactly the row it names
    by = {(r["device"], r["cls"], r["mode"], r["phase"]): r for r in rows}
    for r in rows:
        if r["basis"].startswith("fallback-"):
            src = by.get((r["device"], r["cls"], r["basis"][-2:], r["phase"]))
            if src is None or src["basis"] != "measured":
                out.append(f"{r['name']}: falls back to an unmeasured row")
            elif (src["ns"], src["source"], src["line"], src["quantity"]) != \
                    (r["ns"], r["source"], r["line"], r["quantity"]):
                out.append(f"{r['name']}: is not a copy of {src['name']}")
    return out


def ns_x10(r: dict) -> int:
    return int(r["ns"].replace(".", ""))


def cyc(hz: int, x10: int) -> int:
    """The package's conversion: the nearest clk_sys (half up)."""
    return (hz * x10 + 5_000_000_000) // 10_000_000_000


def profile_clocks() -> list[tuple[str, int]]:
    spec = importlib.util.spec_from_file_location("build_profile", ROOT / "build_profile.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["build_profile"] = mod
    spec.loader.exec_module(mod)
    by_hz: dict[int, list[str]] = {}
    for name, cfg in mod.PROFILES.items():
        by_hz.setdefault(cfg.clk_sys_hz, []).append(name)
    return [("/".join(v), hz) for hz, v in sorted(by_hz.items())]


def render(rows: list[dict]) -> str:
    n = len(rows)
    classes = []
    for k in range(0, n, PER_CLASS):
        r = rows[k]
        classes.append((f"XE10_{dict(DEVICES)[r['device']]}_{r['cls'].upper()}", k, r))
    maxes = {}
    for dev, pre in DEVICES:
        vals = [ns_x10(r) for r in rows if r["device"] == dev]
        maxes[pre] = max(vals) if vals else 0
    clocks = profile_clocks()
    L = []
    w = L.append
    w("// GENERATED by tools/gen_xe10_table.py from tools/xe10_classes.csv - DO NOT EDIT.")
    w("// Regenerate with `python3 tools/gen_xe10_table.py`; `--check` is the gate's comparison, and")
    w("// tools/check_xe10_table.py re-derives every value below from its cited capture row.")
    w("//")
    w("// OSD I/O timing = Xe10's CLASS TABLE: the real Xe10's cost of one CPU access per device, class,")
    w("// display mode and raster phase. A `latency` class (a read) is the time the machine's CPU waits")
    w("// for the access, the capture's net (the nop-0 row less its control loop, so the shell is not")
    w("// in it); the device holds the read's response that long after the access less the core CPU's")
    w("// own cycles around it, so CPU work between reads ADDS to it as on the machine. A `rate` class")
    w("// (a store) is the machine's sustained accept-to-accept period, the capture's nop-0 time per")
    w("// store; the work between stores hides inside it. Fast (OSD I/O timing = Fast) reads none of")
    w("// this. Entry = class base + 2 * mode + phase; mode 0 = 24 kHz, 1 = 31 kHz with the 256-colour")
    w("// display off, 2 = 31 kHz with it on (the kit's 640x480 mode), 3 = 24 kHz with it on; phase 0 = off a graphics line")
    w("// (the vertical blank, or the display stopped: the captures' _V and _O rows agree), 1 = on one.")
    w("//")
    w("//   class                       mode phase    ns  shape    basis        source:line (quantity)")
    for r in rows:
        w("//   %-27s  %s   %s   %7s  %-7s  %-11s  %s:%s (%s)" % (
            r["name"], r["mode"], r["phase"], r["ns"], r["shape"], r["basis"],
            r["source"].replace("docs/probes/", ""), r["line"], r["quantity"]))
    w("//")
    w("// clk_sys cycles per preset build profile (build_profile.py PROFILES), nearest:")
    hdr = "//   %-27s" % "class" + "".join("  %9s" % f"{hz // 1_000_000} MHz" for _, hz in clocks)
    w(hdr)
    for r in rows:
        w("//   %-27s" % r["name"] + "".join("  %9d" % cyc(hz, ns_x10(r)) for _, hz in clocks))
    w("`timescale 1ns / 1ps")
    w("")
    w("package pc9821_xe10_timing_pkg;")
    w("  // The mode codes and the class bases (each class is XE10_PER_CLASS entries: %s)." %
      " ".join(m + p for m in MODES for p in PHASES))
    w("  // They name the whole layout; a device indexes its classes from its first base, so most are")
    w("  // documentation rather than read.")
    w("  /* verilator lint_off UNUSEDPARAM */   // the layout's names, read by a device or by a reader")
    w("  localparam int unsigned XE10_MODE_24 = 0, XE10_MODE_31 = 1, XE10_MODE_48 = 2, XE10_MODE_24P = 3;")
    w("  /* verilator lint_on UNUSEDPARAM */")
    w("  // The entries per class (every mode, both phases): the stride each device walks its classes by.")
    w(f"  localparam int unsigned XE10_PER_CLASS = {PER_CLASS};")
    w("  /* verilator lint_off UNUSEDPARAM */")
    w(f"  localparam int unsigned XE10_N = {n};")
    for nm, base, _ in classes:
        w(f"  localparam int unsigned {nm} = {base};")
    w("  /* verilator lint_on UNUSEDPARAM */")
    w("  // Each device's widest entry, ns x10: the width guard of its counters (a max over the table).")
    for pre, v in maxes.items():
        w(f"  localparam int unsigned XE10_{pre}_MAX_NS_X10 = {v};")
    w("  // The values, ns x10, entry i at [16*i +: 16].")
    w(f"  localparam [{n}*16-1:0] XE10_NS_X10 = {{")
    for i in range(n - 1, -1, -1):
        r = rows[i]
        w("    16'd%d%s  // %3d %s" % (ns_x10(r), "," if i else " ", i, r["name"]))
    w("  };")
    w("")
    w("  // THE CONVERSION every device writes inline (a package function is not read by every tool")
    w("  // the tree checks with): cycles = (SYS_CLOCK_HZ * ns_x10 + 5_000_000_000) / 10_000_000_000,")
    w("  // the nearest clk_sys, half up. The tables below are its result at each preset profile clock,")
    w("  // the per-profile counts the devices produce at those clocks (tools/gen_xe10_table.py --check")
    w("  // re-renders them from the same rule); a device at any other clock (a bench, a --custom")
    w("  // profile) converts the same way.")
    w("  /* verilator lint_off UNUSEDPARAM */   // the per-profile record; the devices convert inline")
    for nm, hz in clocks:
        w(f"  // {hz // 1_000_000} MHz ({nm})")
        w(f"  localparam [{n}*16-1:0] XE10_CYC_{hz // 1_000_000}MHZ = {{")
        for i in range(n - 1, -1, -1):
            w("    16'd%d%s  // %3d %s" % (cyc(hz, ns_x10(rows[i])), "," if i else " ", i, rows[i]["name"]))
        w("  };")
    w("  /* verilator lint_on UNUSEDPARAM */")
    w("endpackage")
    return "\n".join(L) + "\n"


def main(argv: list[str]) -> int:
    rows = read_rows()
    bad = problems(rows)
    if bad:
        for b in bad:
            print("gen_xe10_table: " + b, file=sys.stderr)
        return 1
    text = render(rows)
    if "--print" in argv:
        sys.stdout.write(text)
        return 0
    if "--check" in argv:
        cur = PKG.read_text() if PKG.exists() else ""
        if cur != text:
            print(f"gen_xe10_table: {PKG.relative_to(ROOT)} is stale - run tools/gen_xe10_table.py",
                  file=sys.stderr)
            return 1
        print(f"gen_xe10_table: {PKG.relative_to(ROOT)} matches {CSV.relative_to(ROOT)} ({len(rows)} classes)")
        return 0
    PKG.write_text(text)
    print(f"gen_xe10_table: wrote {PKG.relative_to(ROOT)} ({len(rows)} classes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

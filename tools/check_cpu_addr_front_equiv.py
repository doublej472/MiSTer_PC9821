#!/usr/bin/env python3
"""check_cpu_addr_front_equiv.py -- prove the ONE window-0 front end is the one the subsystem had.

Before P2 (structural-refactors-20261017.md) pc9821_memory_subsystem computed the window-0
membership test, the 9-bit bias add and the 32-bit bias select a second time, in parallel with
pc9821_memory_map's own copy, and the two were held together by prose plus the standalone
two-expression harness `tools/equiv/route_addr_vs_d_addr.sv` (deleted with P2: it compared two
transcriptions, not the shipped text).  P2 exports the mapper's pair (`d_addr`, `win0_moved`) and
the subsystem reads it, so the equality must be a FACT of the shipped text rather than a claim -
which is what this tool proves.

THE PROOF.  One yosys SAT run over ONE free input vector -- cpu_addr (32 bits), sys16m_en,
win0_sel (8 bits), win0_sel_moved -- builds both revisions' arithmetic from the text itself:

  * the OLD subsystem's `eff_addr`, `win0_moved`, `win0_hi` and `route_addr` are extracted by
    name from `--old REV`'s file;
  * the CURRENT subsystem's `eff_addr` (the translation, unchanged by P2) is extracted from the
    working tree;
  * the CURRENT map's `win0_in_window`, `win0_hi`, `win0_moved` and `d_addr` are extracted from
    the working tree and wired exactly as pc9821_memory_subsystem wires them: the map's
    `cpu_addr` is the subsystem's `eff_addr`, its `cpu_addr_raw` is the subsystem's `cpu_addr`.

and proves

  old_eff_addr == new_eff_addr  AND  old_win0_moved == new_win0_moved  AND
  old_route_addr == new_d_addr

for EVERY assignment to the free inputs.  Nothing here is reachable-state-reduced: the identity
holds over the whole input space, which is what makes it a replacement for the old two-file
obligation rather than a sample of it.  (`sat -set-def-inputs` fixes the internal definitions,
so the proof is over the free pins only.)

The set of signals is DISCOVERED from the text (a signal that was renamed or deleted fails the
run with "does not declare", it does not silently pass), and every extracted expression is
round-trip checked against the file so a truncated multi-line match is never proved instead of
the source.

A checker that cannot fail is not evidence, so `--plant NAME` mutates the working tree's text in
the proof only, and the run is expected to FAIL.  `--selftest` runs the clean proof plus every
plant and requires each outcome.

Usage:
  python3 tools/check_cpu_addr_front_equiv.py --old HEAD~1
  python3 tools/check_cpu_addr_front_equiv.py --old 2a006af6 --plant unbiased
  python3 tools/check_cpu_addr_front_equiv.py --selftest
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUBSYSTEM = "src/pc9821/core/pc9821_memory_subsystem.sv"
MAP = "src/pc9821/core/pc9821_memory_map.sv"

# The free input vector: the subsystem's own CPU-side inputs plus the two window-0 state bits.
FREE = [("cpu_addr", "31:0"), ("sys16m_en", None), ("win0_sel", "7:0"),
        ("win0_sel_moved", None)]

OLD_SIGNALS = ["sys16m_mirror", "peg_high", "bios_top", "eff_addr",
               "win0_moved", "win0_hi", "route_addr"]
NEW_SUB_SIGNALS = ["sys16m_mirror", "peg_high", "bios_top", "eff_addr"]
NEW_MAP_SIGNALS = ["win0_in_window", "win0_hi", "win0_moved", "d_addr"]

# Mutations of the WORKING TREE's text, applied to the proof's copy only.  Each must make the
# tool report a mismatch; together they break every term of the identity.
PLANTS = {
    # (file, old text, new text)
    # the exported bias dropped: d_addr becomes the plain (unbiased) address
    "unbiased": (MAP,
                 "assign d_addr = win0_moved ? {7'd0, win0_hi, cpu_addr[15:0]} : cpu_addr;",
                 "assign d_addr = cpu_addr;"),
    # the membership slice one bit off: the window becomes 0x88000-0x9FFFF
    "moved_slice": (MAP,
                    "(cpu_addr_raw[19:17] == 3'b100)",
                    "(cpu_addr_raw[19:17] == 3'b101)"),
    # the bias add's carry term dropped (win0_sel odd and cpu_addr[16] set: one page short)
    "hi_carry": (MAP,
                 "{1'b0, win0_sel} + {8'd0, cpu_addr_raw[16]}",
                 "{1'b0, win0_sel}"),
    # the translation the exported address is built on: the BIOS-at-4G splice truncated
    "eff_splice": (SUBSYSTEM,
                   "bios_top       ? {12'd0, cpu_addr[19:0]} :",
                   "bios_top       ? {13'd0, cpu_addr[18:0]} :"),
}

DECL_RE = re.compile(
    r"(?m)^[ \t]*(?:wire[ \t]+(?:\[([^\]]*)\][ \t]*)?|assign[ \t]+)"
    r"([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(.*?);",
    re.S,
)
# one token: a sized literal (kept verbatim) or a bare identifier (a candidate to rename)
TOK_RE = re.compile(r"\d+\s*'\s*[sS]?[bBoOdDhH]\s*[0-9a-fA-FxXzZ?_]+|[A-Za-z_][A-Za-z0-9_]*")


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def git_show(rev, path):
    out = subprocess.run(["git", "show", "%s:%s" % (rev, path)],
                         cwd=REPO, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("check_cpu_addr_front_equiv: git show %s:%s failed:\n%s"
                 % (rev, path, out.stderr))
    return out.stdout


def widths(text):
    """name -> declared range, from every port and wire declaration in the file.

    A continuous assignment carries no width of its own (`assign d_addr = ...` for a 32-bit
    output port), and proving a 32-bit address as 1 bit would prove nothing, so the width is
    taken from the declaration that DOES state it."""
    t = strip_comments(text)
    out = {}
    for m in re.finditer(r"(?m)^[ \t]*(?:input|output|inout)[ \t]+(?:wire[ \t]+)?"
                         r"(?:\[([^\]]*)\][ \t]*)?([A-Za-z_][A-Za-z0-9_]*)", t):
        if m.group(1):
            out[m.group(2)] = m.group(1)
    for m in re.finditer(r"(?m)^[ \t]*wire[ \t]+(?:\[([^\]]*)\][ \t]*)?"
                         r"([A-Za-z_][A-Za-z0-9_]*)", t):
        if m.group(1):
            out[m.group(2)] = m.group(1)
    return out


def decls(text):
    """name -> (declared range, whitespace-normalised RHS) for every continuous assignment."""
    w = widths(text)
    return {m.group(2): (m.group(1) or w.get(m.group(2)), " ".join(m.group(3).split()))
            for m in DECL_RE.finditer(strip_comments(text))}


def need(table, names, where):
    missing = [n for n in names if n not in table]
    if missing:
        sys.exit("check_cpu_addr_front_equiv: %s does not declare %s (the proof would be "
                 "vacuous, so it is refused instead)" % (where, ", ".join(missing)))
    return {n: table[n] for n in names}


def wire(name, rng, expr):
    """One declaration, at the WIDTH THE SOURCE DECLARED: proving a 9-bit bias adder as 32 bits
    would change the arithmetic the proof is about."""
    return "  wire %s%s = %s;" % ("[%s] " % rng if rng else "", name, expr)


def roundtrip(text, sig, rng, expr, where):
    """True iff the declaration the proof parsed really is in the file's text.

    Guards the extractor itself: a multi-line expression truncated at the wrong `;` would be
    proved instead of the source.  Any of the three legal shapes is accepted, because a
    continuous assignment may be written `assign x = ...`, `wire x = ...` or `wire [w] x = ...`."""
    flat = " ".join(strip_comments(text).split())
    forms = ["assign %s = %s;" % (re.escape(sig), re.escape(expr)),
             "wire %s = %s;" % (re.escape(sig), re.escape(expr))]
    if rng:
        forms.append("wire \\[%s\\] %s = %s;"
                     % (re.escape(rng), re.escape(sig), re.escape(expr)))
    if not any(re.search(p, flat) for p in forms):
        sys.exit("check_cpu_addr_front_equiv: extraction round-trip failed for %s in the %s "
                 "(parsed %r)" % (sig, where, expr))


def rename(expr, defined, prefix, extra=None):
    """Prefix every name this side defines; remap the side's aliases; leave free inputs alone."""
    def sub(m):
        s = m.group(0)
        if s[0].isdigit():                 # a sized literal: never touched
            return s
        if extra and s in extra:
            return extra[s]
        return prefix + s if s in defined else s
    return TOK_RE.sub(sub, expr)


def build(old_text, new_sub_text, new_map_text):
    o = need(decls(old_text), OLD_SIGNALS, "the --old revision's subsystem")
    ns = need(decls(new_sub_text), NEW_SUB_SIGNALS, "the working tree's subsystem")
    nm = need(decls(new_map_text), NEW_MAP_SIGNALS, "the working tree's map")

    lines = ["`default_nettype none", "module m("]
    ports = []
    for name, width in FREE:
        ports.append("  input wire %s%s" % ("[%s] " % width if width else "", name))
    ports.append("  output wire mismatch")
    lines.append(",\n".join(ports))
    lines.append(");")
    for name, (rng, expr) in o.items():
        lines.append(wire("o_" + name, rng, rename(expr, set(o), "o_")))
    for name, (rng, expr) in ns.items():
        lines.append(wire("n_" + name, rng, rename(expr, set(ns), "n_")))
    map_alias = {"cpu_addr": "n_eff_addr", "cpu_addr_raw": "cpu_addr"}
    for name, (rng, expr) in nm.items():
        lines.append(wire("n_" + name, rng,
                          rename(expr, set(nm), "n_", extra=map_alias)))
    lines.append("  assign mismatch = (o_eff_addr != n_eff_addr) | "
                 "(o_win0_moved != n_win0_moved) | (o_route_addr != n_d_addr);")
    lines.append("endmodule")
    return "\n".join(lines) + "\n"


def prove(sv_text):
    os.makedirs(os.path.join(REPO, ".build"), exist_ok=True)
    with tempfile.TemporaryDirectory(dir=os.path.join(REPO, ".build")) as tmp:
        path = os.path.join(tmp, "m.sv")
        open(path, "w").write(sv_text)
        script = ("read_verilog -sv m.sv; prep -top m; "
                  "sat -prove mismatch 0 -verify -set-def-inputs -show-inputs")
        r = subprocess.run(["yosys", "-q", "-p", script], cwd=tmp,
                           capture_output=True, text=True)
        return r.returncode == 0, (r.stdout + r.stderr)[-2500:]


def main():
    ap = argparse.ArgumentParser()
    # REQUIRED, not defaulted: a default of HEAD~1 becomes the POST-P2 revision as soon as this
    # cut lands, and the proof would then compare the text with itself - a check that cannot fail.
    ap.add_argument("--old", required=True,
                    help="the revision whose subsystem still computed its own bias "
                         "(pre-P2: 2a006af6 for the cut that landed it)")
    ap.add_argument("--plant", action="append", default=[],
                    help="plant a known error in the WORKING TREE's text (must fail): "
                         + ", ".join(sorted(PLANTS)))
    ap.add_argument("--selftest", action="store_true",
                    help="run the clean proof and every plant, and check both outcomes")
    args = ap.parse_args()

    old_text = git_show(args.old, SUBSYSTEM)
    new_sub = open(os.path.join(REPO, SUBSYSTEM)).read()
    new_map = open(os.path.join(REPO, MAP)).read()

    plants = sorted(PLANTS) if args.selftest else args.plant
    for p in plants:
        if p not in PLANTS:
            sys.exit("check_cpu_addr_front_equiv: unknown plant %r" % p)

    for text, names, where in ((old_text, OLD_SIGNALS, "--old subsystem"),
                               (new_sub, NEW_SUB_SIGNALS, "working-tree subsystem"),
                               (new_map, NEW_MAP_SIGNALS, "working-tree map")):
        table = decls(text)
        for n in names:
            roundtrip(text, n, table[n][0], table[n][1], where)

    ok, log = prove(build(old_text, new_sub, new_map))
    print("route_addr/win0_moved (the one window-0 front end) == the pre-P2 subsystem's, "
          "for every 32-bit address and both flags: %s" % ("PROVEN" if ok else "FAILED"))
    bad = 0 if ok else 1
    if not ok:
        print(log)

    if plants:
        print("== plants (each must make the proof FAIL) ==")
        for p in plants:
            src_file, frm, to = PLANTS[p]
            src = new_sub if src_file == SUBSYSTEM else new_map
            if frm not in src:
                sys.exit("check_cpu_addr_front_equiv: plant %s anchor moved" % p)
            planted = src.replace(frm, to, 1)
            pok = prove(build(old_text,
                              planted if src_file == SUBSYSTEM else new_sub,
                              planted if src_file == MAP else new_map))[0]
            print("  plant %-12s %s" % (p, "NOT caught" if pok else "caught"))
            bad += pok
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

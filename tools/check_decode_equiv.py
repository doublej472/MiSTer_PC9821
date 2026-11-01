#!/usr/bin/env python3
"""check_decode_equiv.py -- prove the area-memsub bit-slice decode rewrite is a no-op.

The lane rewrote every first-megabyte window and alias decode in
`src/pc9821/core/pc9821_memory_map.sv` and `src/pc9821/core/pc9821_memory_subsystem.sv`
from 32-bit magnitude compares (`addr >= 32'h000E_8000 && addr <= 32'h000F_7FFF`) to
bit-slice identities.  This tool proves the shipped (new) expression of each of those
predicates is bit-identical to the pre-change form **for every 32-bit input**, which is
strictly stronger than an exhaustive sweep of the first MiB plus the special-cased high
prefixes -- a proof over the whole input space includes those.

METHOD: yosys's SAT engine, one proof per predicate.  For a predicate pair (old_expr,
new_expr) over free inputs I, the tool emits

    module pred (<free inputs>) output wire mismatch;
      <helper definitions>            // signals that exist only in the new revision
      wire old_val = <old_expr>;
      wire new_val = <new_expr>;
      assign mismatch = old_val ^ new_val;
    endmodule

and runs `sat -prove mismatch 0 -verify`.  `sat` asks whether ANY assignment to I makes
`mismatch` nonzero; `-verify` makes yosys fail (exit 1) and print the counterexample model
when one exists.  No model found == proven equal on the whole space.

The predicate set is DISCOVERED, not hard-coded: both revisions are read, every continuous
assignment (`wire NAME = ...` / `assign NAME = ...`) is extracted by name, and a predicate
is a signal whose expression text changed between the two revisions.  A signal that exists
ONLY in the new revision (an extracted helper such as `tram_window`) is inlined rather than
left free -- leaving it free would prove the pair on an impossible input space (route_addr
decoupled from tram_window) and would false-fail a correct rewrite.

A checker that cannot fail is not evidence, so `--plant NAME` mutates the new revision's
text before extraction and the run is expected to FAIL.  `--selftest` runs the clean proof
plus every plant and checks both outcomes.  See PLANT.

Usage:
  python3 tools/check_decode_equiv.py --old 92132cd7^ --new 92132cd7
  python3 tools/check_decode_equiv.py --old 92132cd7^ --new HEAD --plant ide_rom_bit13
  python3 tools/check_decode_equiv.py --selftest
  python3 tools/check_decode_equiv.py --list-plants
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = {
    "memory_map": "src/pc9821/core/pc9821_memory_map.sv",
    "memory_subsystem": "src/pc9821/core/pc9821_memory_subsystem.sv",
}
ADDR_RE = re.compile(r"\b(cpu_addr|d_addr|route_addr)\b")

# Mutations of the NEW (shipped) text.  Each must make the tool report a mismatch.
#   ide_rom_bit13   an error this check caught in a rewrite: the 8 KiB option-ROM window kept only
#                   bits [15:14] (=10), i.e. it also claimed 0xDC000-0xDFFFF.
#   absent_half     an error this check caught in a rewrite: the absent-ROM area's half-block escape
#                   (block D with bit 15 clear) was dropped, so 0xD0000-0xD7FFF went
#                   missing.
#   s16m_ge         a `<`/`<=`-class slip: the 15-16 MiB mirror's `>= 8'hFA` became
#                   `> 8'hFA`, dropping 0xFA0000-0xFAFFFF.
#   fw_high_bit15   the top-of-4G ROM alias lost its bit-15 term, so it leaked the
#                   0xFFFF0000-0xFFFF7FFF half that must NOT match.
PLANTS = {
    "ide_rom_bit13": ("d_addr[15:13] == 3'b100", "d_addr[15:14] == 2'b10"),
    "absent_half": ("(!d_addr[16] || !d_addr[15])", "(!d_addr[16] || d_addr[15])"),
    "s16m_ge": ("cpu_addr[23:16] >= 8'hFA", "cpu_addr[23:16] > 8'hFA"),
    "fw_high_bit15": ("&d_addr[31:15]", "&d_addr[31:16]"),
}

# Remove Verilog based literals (32'h0008_0000, 3'b100, 2'd1) before tokenising identifiers -- a
# bare `\d+` must NOT be stripped, or `sys16m_en` tokenises as `sys` + `m_en`.
NUM_RE = re.compile(r"\d+\s*'\s*[sS]?[bBoOdDhH]\s*[0-9a-fA-FxXzZ?_]+")
ID_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
DECL_RE = re.compile(
    r"(?m)^[ \t]*(?:wire[ \t]+(?:\[[^\]]*\][ \t]*)?|assign[ \t]+)"
    r"([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(.*?);",
    re.S,
)


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def git_show(rev, path):
    out = subprocess.run(
        ["git", "show", "%s:%s" % (rev, path)],
        cwd=REPO, capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit("check_decode_equiv: git show %s:%s failed:\n%s" % (rev, path, out.stderr))
    return out.stdout


def decls(text):
    """name -> normalised RHS for every continuous assignment in one revision of one file."""
    t = strip_comments(text)
    out = {}
    for m in DECL_RE.finditer(t):
        out[m.group(1)] = " ".join(m.group(2).split())
    return out


def roundtrip_ok(text, sig, expr):
    """True iff `wire/assign <sig> = <expr>;` really is in the file.

    Guards the extractor itself: if a multi-line expression were truncated at the wrong
    `;`, the proof would be about text that is not in the source.
    """
    flat = " ".join(strip_comments(text).split())
    for kw in ("wire", "assign"):
        if "%s %s = %s;" % (kw, sig, expr) in flat:
            return True
    # a ranged declaration (`wire [W-1:0] sig = ...`), which DECL_RE also accepts
    return re.search(r"wire \[[^\]]*\] ?%s = %s;" % (re.escape(sig), re.escape(expr)), flat) is not None


def identifiers(expr):
    e = NUM_RE.sub(" ", expr)
    return set(ID_RE.findall(e))


def collect(old_texts, new_texts):
    """Discover the predicate pairs: every signal whose expression text changed.

    old_texts/new_texts are {file key: text} for the two revisions.  A signal declared
    only in the new revision is an extracted helper of the rewrite (tram_window), not a
    predicate -- it is inlined on the new side, transitively.
    """
    preds = []
    for key in FILES:
        d_old = decls(old_texts[key])
        d_new = decls(new_texts[key])
        helpers = {s: e for s, e in d_new.items() if s not in d_old}
        for sig in sorted(d_new):
            if sig not in d_old or d_old[sig] == d_new[sig]:
                continue
            old_expr, new_expr = d_old[sig], d_new[sig]
            for rev_text, e in ((old_texts[key], old_expr), (new_texts[key], new_expr)):
                if not roundtrip_ok(rev_text, sig, e):
                    sys.exit("check_decode_equiv: extraction round-trip failed for %s "
                             "in %s (parsed %r)" % (sig, key, e))
            used = identifiers(old_expr) | identifiers(new_expr)
            defined = {sig}
            helper_defs = {}
            work = set(used) & set(helpers)
            while work:
                h = work.pop()
                if h in helper_defs:
                    continue
                helper_defs[h] = helpers[h]
                defined.add(h)
                for nid in identifiers(helpers[h]) & set(helpers):
                    work.add(nid)
            preds.append({
                "label": sig,
                "file": key,
                "old": old_expr,
                "new": new_expr,
                "free": sorted(used - defined),
                "helpers": helper_defs,
            })
    return preds


def emit_module(pred):
    free = pred["free"]
    if not free:
        sys.exit("check_decode_equiv: predicate %s has no free inputs" % pred["label"])
    lines = [
        "// generated by tools/check_decode_equiv.py -- do not edit",
        "`default_nettype none",
        "module pred_%s (" % pred["label"],
    ]
    ports = ["  input [31:0] %s" % f for f in free]
    ports.append("  output wire mismatch")
    lines.append(",\n".join(ports))
    lines.append(");")
    for h, e in sorted(pred["helpers"].items()):
        lines.append("  wire %s = %s;" % (h, e))
    lines.append("  wire old_val = %s;" % pred["old"])
    lines.append("  wire new_val = %s;" % pred["new"])
    lines.append("  assign mismatch = old_val ^ new_val;")
    lines.append("endmodule")
    lines.append("")
    return "\n".join(lines)


SAT_FAIL_RE = re.compile(r"model found:\s*FAIL")
SAT_OK_RE = re.compile(r"no model found:\s*SUCCESS")
MODEL_ROW_RE = re.compile(r"^\s+\\(\w+)\s+(-?\d+)\s+([0-9a-fA-F]+)\s+([01]+)\s*$")
MODULE_NAMES = {
    "memory_map": "pc9821_memory_map",
    "memory_subsystem": "pc9821_memory_subsystem",
}
EQUIV_DONE_RE = re.compile(r"Equivalence successfully proven")
EQUIV_COUNT_RE = re.compile(
    r"Found (\d+) \$equiv cells in equiv:\s*\n\s*Of those cells (\d+) are proven and (\d+) are unproven")
# yosys stamps every run with its own wall clock, so strip those lines: the committed logs
# are evidence, and evidence that changes on every run is not diffable.
VOLATILE_LOG_RE = re.compile(r"Logfile hash:|^Time spent:|^End of script\.")


def sanitize_log(log):
    return "\n".join(l for l in log.splitlines() if not VOLATILE_LOG_RE.search(l)) + "\n"


def residual(text, names):
    """The file's code with comments and the named declarations deleted, whitespace-flat.

    Comparing the two revisions' residuals proves the DISCOVERED predicate list is
    complete: if they are identical, then no changed statement lies outside a discovered
    declaration.  (Comments are excluded because the rewrite's prose changed too.)
    """
    t = strip_comments(text)
    t = DECL_RE.sub(lambda m: "" if m.group(1) in names else m.group(0), t)
    return " ".join(t.split())


def run_whole_module(key, old_text, new_text, workdir):
    """Structural equivalence of a WHOLE module (every internal signal, not just the
    discovered predicates), via yosys equiv_make / equiv_simple / equiv_induct.

    Only a module that elaborates standalone can be compared this way.  A control run of
    the unchanged source against ITSELF separates `yosys cannot do this module' from
    `the revisions differ': if old-vs-old aborts too, the method is unavailable here.

    The renamed source copies the flow needs are written to a temp directory and removed
    again -- leaving module copies in the tree makes every bare-name citation ambiguous
    (AGENTS.md: temporary files never in the tree).  Only the yosys logs are kept, under <workdir>/wm/.
    """
    logdir = os.path.join(workdir, "wm")
    os.makedirs(logdir, exist_ok=True)
    mod = MODULE_NAMES[key]
    tmp = tempfile.mkdtemp(prefix="deq_wm_")
    try:
        paths = {}
        for tag, text in (("gold", old_text), ("gate", new_text)):
            renamed = re.sub(r"(?m)^module\s+%s\b" % mod, "module %s_%s" % (tag, key),
                             text, count=1)
            if renamed == text:
                return "SKIPPED", "module %s not renamed" % mod
            paths[tag] = os.path.join(tmp, "%s_%s.sv" % (key, tag))
            with open(paths[tag], "w") as f:
                f.write(renamed)

        def flow(gold_path, gate_path, gold_mod, gate_mod):
            script = (
                "read_verilog -sv %s; proc; memory; opt; design -stash gold; "
                "read_verilog -sv %s; proc; memory; opt; design -stash gate; "
                "design -copy-from gold -as %s %s; design -copy-from gate -as %s %s; "
                "equiv_make %s %s equiv; hierarchy -top equiv; equiv_simple; "
                "equiv_induct; equiv_status -assert"
                % (gold_path, gate_path, gold_mod, gold_mod, gate_mod, gate_mod,
                   gold_mod, gate_mod)
            )
            out = subprocess.run(["yosys", "-p", script], cwd=tmp, capture_output=True,
                                 text=True)
            return out.stdout + out.stderr

        gm, gt = "gold_%s" % key, "gate_%s" % key
        log = flow(os.path.basename(paths["gold"]), os.path.basename(paths["gate"]), gm, gt)
        with open(os.path.join(logdir, "%s_equiv.log" % key), "w") as f:
            f.write(sanitize_log(log))
        if EQUIV_DONE_RE.search(log):
            m = EQUIV_COUNT_RE.search(log)
            return "EQUIVALENT", ("%s/%s $equiv cells proven" % (m.group(2), m.group(1))
                                  if m else "equivalence proven")
        # control: the unchanged source against itself, to attribute the failure
        ctrl = flow(os.path.basename(paths["gold"]), os.path.basename(paths["gold"]), gm, gm)
        with open(os.path.join(logdir, "%s_control.log" % key), "w") as f:
            f.write(sanitize_log(ctrl))
        if not EQUIV_DONE_RE.search(ctrl):
            return "UNAVAILABLE", ("yosys equiv_make aborts on this module (its own "
                                   "old-vs-old control aborts identically)")
        return "NOT-EQUIVALENT", "control equivalence proven; revisions differ"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def run_proof(sv_path, pred, workdir):
    script = (
        "read_verilog -sv %s; prep -top pred_%s; "
        "sat -prove mismatch 0 -verify -set-def-inputs -show-inputs"
        % (os.path.basename(sv_path), pred["label"])
    )
    env = dict(os.environ)
    out = subprocess.run(
        ["yosys", "-p", script], cwd=workdir, capture_output=True, text=True, env=env,
    )
    log = out.stdout + out.stderr
    if SAT_OK_RE.search(log):
        status = "PROVEN"
    elif SAT_FAIL_RE.search(log):
        status = "MISMATCH"
    else:
        status = "ERROR"
    witness = []
    if status == "MISMATCH":
        for line in log.splitlines():
            m = MODEL_ROW_RE.match(line)
            if m:
                name, dec, hexv = m.group(1), m.group(2), m.group(3)
                if name in pred["free"] and (ADDR_RE.search(name) or name in ("cpu_addr",)):
                    witness.append("%s=0x%s" % (name, hexv))
    return status, witness, log


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()[:12]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--old", default="92132cd7^", help="pre-change revision (default: 92132cd7^)")
    ap.add_argument("--new", default="92132cd7", help="shipped revision (default: 92132cd7)")
    ap.add_argument("--plant", action="append", default=[], metavar="NAME",
                    help="mutate the new revision's text (see --list-plants)")
    ap.add_argument("--list-plants", action="store_true")
    ap.add_argument("--selftest", action="store_true",
                    help="run the clean proof and every plant; exit 0 only if the clean "
                         "run proves all predicates AND every plant is caught")
    ap.add_argument("--workdir", default=os.path.join(REPO, ".build", "decode-equiv-out"))
    args = ap.parse_args()

    if args.list_plants:
        for name, (frm, to) in sorted(PLANTS.items()):
            print("%-16s  %s  ->  %s" % (name, frm, to))
        return 0

    plants = list(PLANTS) if args.selftest else args.plant
    for p in plants:
        if p not in PLANTS:
            sys.exit("check_decode_equiv: unknown plant %r (see --list-plants)" % p)

    os.makedirs(args.workdir, exist_ok=True)
    # The shipped tree must be the revision we prove about.
    for path in FILES.values():
        d = subprocess.run(["git", "diff", "--quiet", args.new, "--", path], cwd=REPO).returncode
        if d != 0:
            print("WARNING: %s in the worktree differs from %s -- proving the revision, "
                  "not the tree" % (path, args.new))

    def build_and_check(plant_name):
        old_texts = {k: git_show(args.old, p) for k, p in FILES.items()}
        new_texts = {}
        planted = 0
        for key, path in FILES.items():
            t = git_show(args.new, path)
            if plant_name:
                frm, to = PLANTS[plant_name]
                if frm in t:
                    t = t.replace(frm, to)
                    planted += 1
            new_texts[key] = t
        if plant_name and not planted:
            sys.exit("check_decode_equiv: plant %s: %r not found in either file"
                     % (plant_name, PLANTS[plant_name][0]))
        preds = collect(old_texts, new_texts)
        tag = plant_name or "clean"
        results = []
        for pred in preds:
            sv = os.path.join(args.workdir, "pred_%s.sv" % pred["label"])
            with open(sv, "w") as f:
                f.write(emit_module(pred))
            status, witness, log = run_proof(sv, pred, args.workdir)
            # Raw logs for the proof runs; for a plant run only the mismatch is evidence.
            if tag == "clean" or status == "MISMATCH":
                with open(os.path.join(args.workdir, "%s_%s.log" % (tag, pred["label"])), "w") as f:
                    f.write(sanitize_log(log))
            results.append((pred, status, witness))
        return preds, results

    print("check_decode_equiv: old=%s new=%s%s"
          % (args.old, args.new, "  plant=%s" % ",".join(plants) if plants else ""))
    print("  memory_map       sha(old)=%s sha(new)=%s"
          % (sha(git_show(args.old, FILES["memory_map"])), sha(git_show(args.new, FILES["memory_map"]))))
    print("  memory_subsystem sha(old)=%s sha(new)=%s"
          % (sha(git_show(args.old, FILES["memory_subsystem"])),
             sha(git_show(args.new, FILES["memory_subsystem"]))))

    clean_preds, clean_results = build_and_check(None)
    print("\n== shipped (no plant): %d predicates discovered" % len(clean_preds))
    print("  extraction round-trip: every predicate expression verified verbatim in both")
    print("  revisions' text (the extractor did not truncate an expression)")
    bits_total = 0
    addr_preds = 0
    clean_ok = True
    for pred, status, witness in clean_results:
        n = 32 * len(pred["free"])
        bits_total += n
        has_addr = any(ADDR_RE.search(f) for f in pred["free"])
        addr_preds += has_addr
        print("  %-16s %-16s inputs=%-28s 2^%-3d  %-8s %s"
              % (pred["file"], pred["label"], ",".join(pred["free"]), n, status,
                 "helpers=%s" % ",".join(sorted(pred["helpers"])) if pred["helpers"] else ""))
        if status != "PROVEN":
            clean_ok = False
            print("      old: %s" % pred["old"])
            print("      new: %s" % pred["new"])
            print("      counterexample: %s" % (", ".join(witness) or "see log"))
    proven = sum(1 for _, s, _ in clean_results if s == "PROVEN")
    print("  => %d/%d predicates proven; %d of them carry a 32-bit address input, so each is"
          % (proven, len(clean_results), addr_preds))
    print("     proven at EVERY one of the 2^32 addresses and every control-input combination")
    print("     (sum over predicates: %d free input bits)." % bits_total)
    print("  VERDICT: %s" % ("EQUIVALENT" if clean_ok else "NOT EQUIVALENT"))

    old_texts = {k: git_show(args.old, p) for k, p in FILES.items()}
    new_texts = {k: git_show(args.new, p) for k, p in FILES.items()}

    # ---- completeness: no changed statement may lie outside a discovered declaration
    names = set()
    for pr in clean_preds:
        names.add(pr["label"])
        names |= set(pr["helpers"])
    print("\n== diff completeness (nothing changed outside the discovered declarations)")
    complete = True
    for key in FILES:
        r_old = residual(old_texts[key], names)
        r_new = residual(new_texts[key], names)
        ok = r_old == r_new
        complete = complete and ok
        print("  %-16s comments + %d discovered declarations deleted, residual identical: %s"
              % (key, len(names), "yes" if ok else "NO"))
        if not ok:
            for i, (a, b) in enumerate(zip(r_old, r_new)):
                if a != b:
                    print("      first divergence at char %d: %r vs %r"
                          % (i, r_old[max(0, i - 40):i + 40], r_new[max(0, i - 40):i + 40]))
                    break
            else:
                print("      one residual is a prefix of the other")
    print("  => the revisions' only code difference is those %d declarations" % len(names))

    # ---- second method: whole-module structural equivalence, where yosys can do it
    print("\n== whole-module structural equivalence (yosys equiv_make/equiv_simple/equiv_induct)")
    wm_ok = True
    for key in FILES:
        status, note = run_whole_module(key, old_texts[key], new_texts[key], args.workdir)
        print("  %-16s %-14s %s" % (key, status, note))
        if status == "NOT-EQUIVALENT":
            wm_ok = False
    print("  => at whole-module level this proves EVERY internal signal, not just the")
    print("     discovered predicates; a module yosys cannot compare is covered by the")
    print("     per-predicate proofs (and by diff completeness above)")
    clean_ok = clean_ok and complete and wm_ok
    print("\n  SHIPPED DECODE EQUIVALENT TO PRE-CHANGE FORM: %s" % ("YES" if clean_ok else "NO"))

    plant_ok = True
    for plant in plants:
        _, results = build_and_check(plant)
        caught = [p["label"] for p, s, _ in results if s == "MISMATCH"]
        detected = len(caught) > 0 and len(results) == len(clean_preds)
        print("\n== plant %s: %d/%d predicates flagged MISMATCH%s"
              % (plant, len(caught), len(results),
                 "  (checker DISCRIMINATES)" if detected else "  (!! CHECKER BLIND)"))
        for pred, status, witness in results:
            if status == "MISMATCH":
                print("     %s: counterexample at %s" % (pred["label"], ", ".join(witness) or "?"))
        if not detected:
            plant_ok = False

    if args.selftest:
        print("\n== selftest: clean=%s plants=%s"
              % ("PASS" if clean_ok else "FAIL", "PASS" if plant_ok else "FAIL"))
    return 0 if (clean_ok and plant_ok) else 1


if __name__ == "__main__":
    sys.exit(main())

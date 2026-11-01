#!/usr/bin/env python3
"""Prove a bench CAN FAIL: plant a mutation in a copy of one of its sources, require a FAIL.

A green bench is evidence only if the same bench goes red when the behaviour it claims to
check is broken. This tool plants that breakage in a COPY of one source (never the tree),
builds and runs the bench through tools/bench.py's own run_one_bench -- so a mutant is
judged by exactly the verdict rule the gate uses (the strict `<marker>: PASS` line AND
exit 0) -- and reports, per mutant:

  KILLED       the bench failed: it can see this defect (the result we want)
  SURVIVED     the bench still PASSES with the defect in place: it cannot see it
  BUILD-ERROR  the mutant does not compile, so it proves nothing either way
  STALE        the `from` text is no longer in the file exactly once (the source moved;
               re-point the mutation rather than guessing)

and the CONTROL, the unmutated bench, which must PASS first: a mutant that "fails" on a
bench that already fails proves nothing.

  tools/mutate_bench.py BENCH --file SRC --from OLD --to NEW [--why TEXT]
  tools/mutate_bench.py --plan tests/pc9821/mutations.json [--bench NAME ...]
  tools/mutate_bench.py --plan FILE --check-plan
                                         without Verilator: every entry still names a
                                         source its bench builds and its `from` text still
                                         occurs exactly once (a record that has rotted is
                                         evidence that no longer applies)
  tools/mutate_bench.py --selftest       the substitution rules, without Verilator

The committed record is tests/pc9821/mutations.json: mutants each named bench KILLED
when it was recorded. Re-run it after changing a bench's
checks; re-point an entry whose source moved rather than deleting it.

SRC is a repo-relative path the bench builds: one of its manifest sources, its own
testbench (tests/pc9821/tb_pc9821_<name>.sv), or an `include file found through the
bench include path (tests/pc9821/*.svh). Mutating a file the bench does not build would
"survive" trivially, so it is refused. `from` must occur EXACTLY ONCE in SRC; use more
context to disambiguate. A plan is a JSON list of {"bench", "file", "from", "to", "why"}.

Exit 0 iff every control passed and every mutant was KILLED. Builds live under
.build/mutate/<bench>/ (one object directory per bench, so its mutants rebuild
incrementally) and are removed afterwards unless --keep; a Verilator object directory is
large (docs/lanes.md: prune build trees).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench  # noqa: E402
from proc import REPO_ROOT, die, have  # noqa: E402

MUT_ROOT = REPO_ROOT / ".build/mutate"


def apply_mutation(text: str, old: str, new: str) -> tuple[str | None, str]:
    """The mutated text, or None and why not. `old` must occur exactly once."""
    if old == new:
        return None, "`from` and `to` are identical: that is not a mutation"
    count = text.count(old)
    if count != 1:
        return None, f"`from` occurs {count} times (must be exactly once)"
    return text.replace(old, new, 1), ""


def buildable(name: str, rel: str, files: list[str]) -> bool:
    """Is `rel` something this bench's build actually reads?"""
    if rel in files or rel == f"tests/pc9821/tb_pc9821_{name}.sv":
        return True
    # An `include file is read through -I, not the file list.
    return rel.endswith((".svh", ".vh")) and (REPO_ROOT / rel).parent in (
        bench.TB_DIR, bench.Z486, bench.X87)


def run(name: str, manifest: dict, run_dir: Path, substitute: dict | None) -> tuple[bool, str, str]:
    """(passed, why-not, log text)."""
    log_root = run_dir / "logs"
    _n, ok, _sec, detail = bench.run_one_bench(
        name, manifest,
        verilator_jobs=bench.env_int("VERILATOR_JOBS", 4),
        vflags=os.environ.get("VFLAGS", "-O2"),
        build_timeout=bench.env_int("BUILD_TIMEOUT_INT", 900),
        run_timeout=bench.env_int("BENCH_TIMEOUT_INT", 600),
        verbose=False, substitute=substitute, run_dir=run_dir, log_root=log_root)
    log = log_root / f"bench-{name}.log"
    return ok, detail, log.read_text() if log.exists() else ""


def first_failure_line(log: str) -> str:
    for line in log.splitlines():
        low = line.lower()
        if (line.lstrip().startswith(("FAIL", "MISMATCH")) or "%Fatal" in line
                or ": FAIL" in line or "timed out" in low):
            return line.strip()[:160]
    return ""


def mutate_bench(name: str, mutants: list[dict], manifest: dict, keep: bool) -> list[tuple]:
    """Run the control, then each mutant. Returns (label, verdict, detail) rows."""
    rows = []
    entry = manifest.get(name)
    if entry is None:
        return [(f"{name}", "ERROR", "no such bench")]
    files = entry[2]
    base = MUT_ROOT / name
    obj_dir = base / "build"          # one object dir: the mutants rebuild incrementally
    try:
        ok, detail, _log = run(name, manifest, obj_dir, None)
        rows.append((f"{name} control", "PASS" if ok else "CONTROL-FAILS", detail))
        if not ok:
            return rows
        for i, m in enumerate(mutants):
            label = f"{name} #{i} {m['file']}: {m.get('why', '')}".rstrip(": ")
            rel = m["file"]
            if not buildable(name, rel, files):
                rows.append((label, "ERROR", f"{rel} is not built by this bench"))
                continue
            src = REPO_ROOT / rel
            mutated, why = apply_mutation(src.read_text(), m["from"], m["to"])
            if mutated is None:
                rows.append((label, "STALE", why))
                continue
            copy = base / f"m{i}" / rel
            copy.parent.mkdir(parents=True, exist_ok=True)
            copy.write_text(mutated)
            ok, detail, log = run(name, manifest, obj_dir, {rel: copy})
            if ok:
                rows.append((label, "SURVIVED", "the bench still PASSES with this defect"))
            elif detail.startswith("verilator build"):
                rows.append((label, "BUILD-ERROR", detail))
            else:
                rows.append((label, "KILLED", first_failure_line(log) or detail))
    finally:
        if not keep:
            shutil.rmtree(base, ignore_errors=True)
    return rows


def check_plan(plan: list[dict], manifest: dict) -> int:
    """Static: every entry applies to the tree as it is now."""
    bad = []
    for i, m in enumerate(plan):
        missing = [k for k in ("bench", "file", "from", "to", "why") if k not in m]
        if missing:
            bad.append(f"entry {i}: missing {', '.join(missing)}")
            continue
        entry = manifest.get(m["bench"])
        if entry is None:
            bad.append(f"entry {i}: no such bench {m['bench']!r}")
            continue
        if not buildable(m["bench"], m["file"], entry[2]):
            bad.append(f"entry {i} ({m['bench']}): {m['file']} is not built by this bench")
            continue
        path = REPO_ROOT / m["file"]
        if not path.exists():
            bad.append(f"entry {i} ({m['bench']}): {m['file']} does not exist")
            continue
        _t, why = apply_mutation(path.read_text(), m["from"], m["to"])
        if _t is None:
            bad.append(f"entry {i} ({m['bench']}: {m['why']}): STALE - {why}")
    for b in bad:
        print(f"  - {b}")
    print(f"MUTATION PLAN: {'FAIL' if bad else 'PASS'} ({len(plan)} entries, "
          f"{len({m.get('bench') for m in plan})} benches, {len(bad)} stale/invalid)")
    return 1 if bad else 0


def selftest() -> int:
    cases = [
        ("a = b;", "a = b;", "a = c;", "a = c;"),
        ("x x", "x", "y", None),           # twice: refused
        ("abc", "zzz", "y", None),          # absent: refused
        ("abc", "abc", "abc", None),        # identity: refused
    ]
    bad = []
    for text, old, new, want in cases:
        got, _why = apply_mutation(text, old, new)
        if got != want:
            bad.append(f"apply_mutation({text!r}, {old!r}, {new!r}) = {got!r}, want {want!r}")
    if not buildable("pit_ref", "tests/pc9821/egc_xe10_vectors.svh", []):
        bad.append("an .svh in the bench include path must count as built")
    if buildable("pit_ref", "src/pc9821/video/pc9821_crtc.sv", ["src/a.sv"]):
        bad.append("a source the bench does not list must be refused")
    if bad:
        print("MUTATE_BENCH SELFTEST: FAIL")
        for b in bad:
            print(f"  - {b}")
        return 1
    print(f"MUTATE_BENCH SELFTEST: PASS ({len(cases) + 2} cases)")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("bench", nargs="?")
    ap.add_argument("--file")
    ap.add_argument("--from", dest="old")
    ap.add_argument("--to", dest="new")
    ap.add_argument("--why", default="")
    ap.add_argument("--plan", help="a JSON list of mutations")
    ap.add_argument("--only", action="append", default=[],
                    help="with --plan: run only these benches (repeatable)")
    ap.add_argument("--keep", action="store_true", help="keep .build/mutate/<bench>/")
    ap.add_argument("--check-plan", action="store_true",
                    help="with --plan: check the entries still apply, without building")
    ap.add_argument("--selftest", action="store_true")
    opts = ap.parse_args(argv)

    if opts.selftest:
        return selftest()
    manifest = bench.load_manifest()
    if opts.check_plan:
        if not opts.plan:
            die("--check-plan needs --plan FILE", code=2)
        return check_plan(json.loads(Path(opts.plan).read_text()), manifest)
    if not have("verilator"):
        die("verilator is not installed", code=1)

    by_bench: dict[str, list[dict]] = {}
    if opts.plan:
        for m in json.loads(Path(opts.plan).read_text()):
            if opts.only and m["bench"] not in opts.only:
                continue
            by_bench.setdefault(m["bench"], []).append(m)
    elif opts.bench and opts.file and opts.old is not None and opts.new is not None:
        by_bench[opts.bench] = [dict(bench=opts.bench, file=opts.file, why=opts.why,
                                     **{"from": opts.old, "to": opts.new})]
    else:
        die("give BENCH --file --from --to, or --plan FILE", code=2)

    all_rows = []
    for name, mutants in by_bench.items():
        rows = mutate_bench(name, mutants, manifest, opts.keep)
        for label, verdict, detail in rows:
            print(f"{verdict:<13}{label}")
            if detail and verdict != "PASS":
                print(f"{'':<13}  {detail}")
            sys.stdout.flush()
        all_rows += rows
    bad = [r for r in all_rows if r[1] not in ("PASS", "KILLED")]
    killed = sum(1 for r in all_rows if r[1] == "KILLED")
    print(f"==> {killed} mutant(s) killed, {len(bad)} not (survived/stale/build-error/control)")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

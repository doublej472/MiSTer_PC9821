#!/usr/bin/env python3
"""Run PC-9821 unit benches under Verilator -- one, or all of them.

This is the ONE bench runner: `make bench`, the gate (tests/pc9821/run.sh) and the
out-of-repo measurement front end all end up here, so they cannot drift apart about
what a bench is built from or how its verdict is read.

It replaces the bench half of the old measure script (the device/sweep half stayed with
the out-of-repo dev tools). That code was safe but was the tree's
most-quoted bash: a per-bench source list built by word-splitting, verilator's flags
and the `-I` include paths assembled by shell concatenation, and a verdict taken from
`grep -q "$MARK: PASS"` on a log while the run's own exit code was discarded with
`|| true`. Here the manifest is imported as Python data (tools/gen_bench_sources.py
declares it), the file list is a list rather than a string that gets split, and a
bench PASSes only when BOTH its runner exited 0 AND its own PASS marker is in the
output -- so the historical "exited 0 while printing FAIL" bench cannot pass silently --
AND no line of its output opens with FAIL or MISMATCH (a check that reports a failure
without counting it).

  tools/bench.py --list          the manifest: what each bench proves
  tools/bench.py <name>          one bench, built and run alone, output streamed
  tools/bench.py --all           every bench, BENCH_JOBS at a time (default NCPU)
  tools/bench.py --selftest      the verdict rules on planted outputs, without Verilator

Environment: BENCH_JOBS (parallel benches, default NCPU), VERILATOR_JOBS (-j per build,
default 4), VFLAGS (default -O2), BUILD_TIMEOUT_INT (default 900), BENCH_TIMEOUT_INT
(default 600).
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from proc import REPO_ROOT, TOOLS_DIR, capture, die, have, nproc, stream  # noqa: E402

TB_DIR = REPO_ROOT / "tests/pc9821"
RUN_ROOT = TB_DIR / "build"
LOG_ROOT = REPO_ROOT / "build/measure"
Z486 = REPO_ROOT / "src/z486"
X87 = Z486 / "x87"

# The warnings the benches have always built with. They are named here, once, because
# they are the reason a bench compiling clean is not the gate's lint pass
# (tools/check_lint.py runs with NONE of them). VFLAGS in the environment overrides only
# the optimisation flag, exactly as the old measure script did.
VERILATOR_WARN_FLAGS = [
    "-Wall", "-Wno-fatal",
    "-Wno-PINMISSING", "-Wno-UNUSEDSIGNAL", "-Wno-UNUSEDPARAM", "-Wno-SYNCASYNCNET",
    # IMPURE fires for the `/* verilator no_inline_task */` tasks in
    # tests/pc9821/pc9821_egc_ref.sv, whose module-level regs are accessed through
    # vlSelf exactly as the inlined form did. The metacomment exists so Verilator
    # compiles the golden model ONCE instead of one copy per tb call site (the
    # egc_conformance bench otherwise emits ~3.4M lines / 290 MB of C++ and takes
    # ~14 minutes to compile). The differential suite still compares every case
    # byte-for-byte, so a wrong golden would fail the bench.
    "-Wno-IMPURE",
]


def load_manifest() -> dict:
    """The bench table, imported as Python so the file list is a list, not a string."""
    source = TOOLS_DIR / "gen_bench_sources.py"
    spec = importlib.util.spec_from_file_location("gen_bench_sources", source)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # declares the table; runs nothing else
    return module.BENCHES


def names(manifest: dict) -> list[str]:
    return sorted(manifest)


def env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, "").strip() or default)
    except ValueError:
        die(f"{name} is not an integer: {os.environ[name]!r}")


def marker_present(output: str, marker: str) -> bool:
    """The bench's PASS line, EXACTLY: `<marker>: PASS` alone on its own line.

    This used to fall back to `f"{marker}: PASS" in output`, which accepts the marker
    anywhere -- inside a diagnostic line, an echoed claim, or a `FAIL: no TB_X: PASS`
    message -- so a run could satisfy the runner without printing its verdict. Every
    bench's PASS display emits the marker alone on its line (checked across
    the whole tree), so the exact line is the honest test."""
    return re.search(rf"^{re.escape(marker)}: PASS[ \t\r]*$", output, re.M) is not None


# A line that OPENS with a failure word is a check reporting a failure. A bench that prints
# one and still prints its PASS marker and exits 0 has a check that reports but does not
# count (its `errors++` is missing or on another path) -- a vacuous check the marker and the
# exit code cannot see. Case-sensitive, at the start of the line (after indentation), so
# narration such as "CHECK 2: the ITF fail path" or "0 byte(s) fail" is not caught; no
# passing bench in the tree prints such a line.
FAILURE_LINE = re.compile(r"^[ \t]*(?:FAIL|MISMATCH)", re.M)


def failure_line(output: str) -> str | None:
    """The first line that opens with FAIL/MISMATCH, or None."""
    m = FAILURE_LINE.search(output)
    if m is None:
        return None
    end = output.find("\n", m.start())
    return output[m.start(): end if end >= 0 else None].strip()


def run_one_bench(name: str, manifest: dict, *, verilator_jobs: int, vflags: str,
                  build_timeout: int, run_timeout: int, verbose: bool,
                  substitute: dict[str, Path] | None = None,
                  run_dir: Path | None = None,
                  log_root: Path | None = None) -> tuple[str, bool, float, str]:
    """Build and run one bench; (name, passed, seconds, why-not).

    `substitute`, `run_dir` and `log_root` exist for tools/mutate_bench.py: a mutant
    build replaces some of the bench's sources (manifest path -> the mutated copy,
    the testbench itself included as `tests/pc9821/tb_pc9821_<name>.sv`) and builds
    in its own directory, through THIS function, so a mutant is judged by exactly
    the verdict rule the gate uses. The gate passes none of them."""
    entry = manifest.get(name)
    if entry is None:
        return name, False, 0.0, f"no such bench: {name} (see `tools/bench.py --list`)"
    marker, _claim, files = entry
    if not files:
        return name, False, 0.0, "the manifest declares no sources for this bench"
    substitute = substitute or {}

    tb_rel = f"tests/pc9821/tb_pc9821_{name}.sv"
    tb = TB_DIR / f"tb_pc9821_{name}.sv"
    if not tb.exists():
        return name, False, 0.0, f"missing testbench {tb}"
    tb = substitute.get(tb_rel, tb)

    run_dir = run_dir or RUN_ROOT / f"bench-{name}"
    log_root = log_root or LOG_ROOT
    obj = run_dir / "obj"
    obj.mkdir(parents=True, exist_ok=True)
    log_root.mkdir(parents=True, exist_ok=True)
    # The real z486's microcode and PLA images are $readmemh'd BY RELATIVE NAME at
    # RUN time (ucode_rom.sv, the two PLA entry ROMs), so they must sit beside the
    # binary - exactly what run_boot.sh's symlink loop does for the integrated tiers.
    # A bench that instantiates the full CPU (grcg_cpu) needs this; the others never
    # read them, and an extra symlink costs nothing. Without it the CPU executes an
    # all-zero microcode store and wanders off, which reads as a bench timeout.
    for hex in sorted(Z486.glob("*.hex")):
        link = run_dir / hex.name
        if not link.exists():
            link.symlink_to(hex.resolve())
    build_log = log_root / f"bench-{name}.build.log"
    run_log = log_root / f"bench-{name}.log"
    # A substituted `include file (an .svh) is found through the include path, so the
    # directories holding substitutes come FIRST and shadow the tree's copy.
    sub_dirs = sorted({str(p.parent) for p in substitute.values()})

    argv = [
        "verilator", "--binary", "--timing", "-j", str(verilator_jobs), vflags,
        *VERILATOR_WARN_FLAGS,
        *[f"-I{d}" for d in sub_dirs],
        f"-I{Z486}", f"-I{X87}", f"-I{TB_DIR}",
        "--top-module", f"tb_pc9821_{name}",
        "--Mdir", str(obj),
        *[str(substitute.get(f, REPO_ROOT / f)) for f in files],
        str(tb),
    ]

    start = time.monotonic()
    if verbose:
        code, build_out = stream(argv, log=build_log)
    else:
        code, build_out, timed_out = capture(argv, timeout=build_timeout)
        build_log.write_text(build_out)
        if timed_out:
            return name, False, time.monotonic() - start, f"verilator build timed out ({build_timeout}s)"
    if code != 0:
        return name, False, time.monotonic() - start, f"verilator build failed (see {build_log})"

    exe = obj / f"Vtb_pc9821_{name}"
    code, run_out, timed_out = capture([str(exe)], cwd=run_dir, timeout=run_timeout)
    run_log.write_text(run_out)
    if verbose:
        sys.stdout.write(run_out)
        sys.stdout.flush()

    elapsed = time.monotonic() - start
    if timed_out:
        return name, False, elapsed, f"the run timed out ({run_timeout}s, see {run_log})"
    if not marker_present(run_out, marker):
        return name, False, elapsed, f"no '{marker}: PASS' marker (see {run_log})"
    if code != 0:
        return name, False, elapsed, f"printed its PASS marker but exited {code} (see {run_log})"
    bad = failure_line(run_out)
    if bad is not None:
        return name, False, elapsed, (f"printed its PASS marker but also a failure line "
                                      f"{bad[:120]!r} (see {run_log})")
    return name, True, elapsed, ""


def run_all(manifest: dict, *, jobs: int, verbose: bool) -> int:
    all_names = names(manifest)
    if not all_names:
        die("the bench manifest is empty, so there is nothing to run", code=1)
    verilator_jobs = env_int("VERILATOR_JOBS", 4)
    # `--all` runs `jobs` benches at once and each build spends `verilator_jobs`
    # threads on the compile (verilator elaboration + g++). At the defaults that is
    # NCPU x 4 threads, a 4:1 oversubscription during the compile burst that slows
    # every g++. Cap the per-bench thread count so the product stays at the core
    # count; a single-bench run (`bench.py <name>`) keeps the full VERILATOR_JOBS.
    if jobs > 0:
        verilator_jobs = max(1, min(verilator_jobs, nproc() // jobs))
    build_timeout = env_int("BUILD_TIMEOUT_INT", 900)
    run_timeout = env_int("BENCH_TIMEOUT_INT", 600)
    vflags = os.environ.get("VFLAGS", "-O2")

    print(f"==> {len(all_names)} benches, {jobs} at a time "
          f"(BENCH_JOBS={jobs}, verilator -j {verilator_jobs})")
    results: dict[str, tuple[bool, float, str]] = {}
    if jobs <= 1:
        for name in all_names:
            _name, ok, seconds, detail = run_one_bench(
                name, manifest, verilator_jobs=verilator_jobs, vflags=vflags,
                build_timeout=build_timeout, run_timeout=run_timeout, verbose=verbose)
            results[name] = (ok, seconds, detail)
            print(f"{name:<22}{'PASS' if ok else 'FAIL'} ({seconds:.0f}s)")
            if not ok and detail:
                print(f"    {detail}")
    else:
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            futures = {
                pool.submit(run_one_bench, name, manifest, verilator_jobs=verilator_jobs,
                            vflags=vflags, build_timeout=build_timeout,
                            run_timeout=run_timeout, verbose=False): name
                for name in all_names
            }
            for future in as_completed(futures):
                name, ok, seconds, detail = future.result()
                results[name] = (ok, seconds, detail)
                print(f"{name:<22}{'PASS' if ok else 'FAIL'} ({seconds:.0f}s)")
                if not ok and detail:
                    print(f"    {detail}")

    failed = [n for n in all_names if not results.get(n, (False,))[0]]
    print(f"==> {len(all_names) - len(failed)}/{len(all_names)} benches pass under Verilator")
    if failed:
        print(f"==> failed: {' '.join(failed)}")
        return 1
    return 0


def list_benches(manifest: dict) -> int:
    print(f"{'bench':<22}{'proves'}")
    for name in names(manifest):
        marker, claim, _files = manifest[name]
        print(f"{name:<22} {claim}")
    return 0


def selftest() -> int:
    """The verdict's text rules against planted outputs: each must be judged as stated."""
    m = "TB_PC9821_X"
    cases = [
        ("the marker alone on its line", f"x\n{m}: PASS\n", True, None),
        ("the marker with a trailing CR", f"{m}: PASS\r\n", True, None),
        ("the marker inside a sentence", f"FAIL: no {m}: PASS here\n", False,
         f"FAIL: no {m}: PASS here"),
        ("another bench's marker", "TB_PC9821_Y: PASS\n", False, None),
        ("a FAIL line before the marker", f"  FAIL step 3\n{m}: PASS\n", True, "FAIL step 3"),
        ("a MISMATCH line", f"MISMATCH a: rtl=1\n{m}: PASS\n", True, "MISMATCH a: rtl=1"),
        ("narration mentioning fail", f"CHECK 2: the ITF fail path\n0 fail\n{m}: PASS\n", True, None),
    ]
    bad = []
    for label, out, want_marker, want_fail in cases:
        if marker_present(out, m) != want_marker:
            bad.append(f"{label}: marker_present is {not want_marker}")
        if failure_line(out) != want_fail:
            bad.append(f"{label}: failure_line is {failure_line(out)!r}, want {want_fail!r}")
    if bad:
        print("BENCH VERDICT SELFTEST: FAIL")
        for b in bad:
            print(f"  - {b}")
        return 1
    print(f"BENCH VERDICT SELFTEST: PASS ({len(cases)} planted outputs)")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run PC-9821 unit benches under Verilator.",
        add_help=True,
    )
    parser.add_argument("bench", nargs="?", help="one bench name (from `--list`)")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--all", action="store_true", help="every bench")
    group.add_argument("--list", action="store_true", help="print the manifest and exit")
    group.add_argument("--selftest", action="store_true",
                       help="check the verdict rules on planted outputs and exit")
    parser.add_argument("--jobs", type=int, default=None,
                        help="benches to run at once (default: $BENCH_JOBS or NCPU)")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    opts = parse_args(argv)
    manifest = load_manifest()

    if opts.selftest:
        return selftest()
    if opts.list:
        return list_benches(manifest)
    if opts.all:
        jobs = opts.jobs if opts.jobs is not None else env_int("BENCH_JOBS", nproc())
        return run_all(manifest, jobs=jobs, verbose=False)
    if not opts.bench:
        die("name a bench, or pass --all / --list", code=2)
    if not have("verilator"):
        die("verilator is not installed", code=1)
    verilator_jobs = env_int("VERILATOR_JOBS", 4)
    build_timeout = env_int("BUILD_TIMEOUT_INT", 900)
    run_timeout = env_int("BENCH_TIMEOUT_INT", 600)
    vflags = os.environ.get("VFLAGS", "-O2")
    print(f"==> bench {opts.bench} (verilator -j {verilator_jobs}; log build/measure/bench-{opts.bench}.log)")
    name, ok, seconds, detail = run_one_bench(
        opts.bench, manifest, verilator_jobs=verilator_jobs, vflags=vflags,
        build_timeout=build_timeout, run_timeout=run_timeout, verbose=True)
    if ok:
        print(f"==> {name}: PASS under Verilator ({seconds:.0f}s)")
        return 0
    print(f"==> {name}: FAIL - {detail}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

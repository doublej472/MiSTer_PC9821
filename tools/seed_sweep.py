#!/usr/bin/env python3
"""Seed sweep: fit many Quartus seeds of a build profile and rank them by timing.

Each seed is fitted in its own copy of the working tree (so concurrent fits cannot
collide), at most --jobs at a time, and completion is judged by the fit's own
status file rather than by process state (a killed podman CLI can leave its
container running, so a PID is not evidence). The fitter crashes on some runs (a
known Quartus flake), so a failed fit is retried up to --retries times before the
seed is recorded as failed. A seed that already has a recorded verdict is skipped
on re-run, so the sweep survives interruption and resumes where it left off.

    tools/seed_sweep.py --profile heavyoc --count 100 --jobs 10
    nohup tools/seed_sweep.py --profile heavyoc --count 100 --jobs 10 &
    tools/seed_sweep.py --report          # rank the finished seeds, print the best
    tools/seed_sweep.py --profile base --sdram-mhz 110 --count 6 --jobs 3 --dir .build/sw110
    tools/seed_sweep.py --profile-file sweep.toml --count 6 --jobs 3 --dir .build/swX

Any build_profile.py override (--clk-sys-mhz, --sdram-mhz, --sdram-phase-ps, --trace,
--profile-file, ...) is applied to every seed's copy on top of --profile, and each seed
refuses to fit unless its copy resolves to exactly the configuration the parent resolved.
The PLL is generated once, into the parent's .build/pll-cache/, and every seed reuses it.

Per seed the verdict lands in <dir>/seedNNN/status.txt and the measured timing in
<dir>/seedNNN/summary.txt; a one-line-per-seed roll-up is <dir>/summary.txt. The
working copies are deleted as soon as a seed's numbers are recorded, so the disk
cost is bounded by --jobs trees, not by --count.

RESUME IS KEYED ON WHAT WAS FITTED. A seed's summary.txt records `identity=`, the sha256 of
{resolved configuration, the RTL source hash (tools/check_fit.py --rtl-hash-of), the fit knobs
in the environment}. A re-run skips a seed only when its identity equals the current one; a
seed that was fitted from different source or another profile makes the sweep REFUSE (exit 1,
the stale seeds listed) instead of silently mixing two designs in one ranking. Pick one:
--restart-stale renames each stale seedNNN to seedNNN.stale-<time> (its output_files are never
deleted) and fits it afresh; --trust-existing accepts a summary written before identities
existed. --retry-failed re-fits seeds recorded `verdict=failed` (the old directory is kept the
same way). summary.txt is written LAST, after output_files and metrics.json are in place, so a
killed sweep never leaves a verdict without its reports.

SHARED HOSTS. --slot-dir DIR --slot-max N (env FIT_SLOT_DIR / FIT_SLOT_MAX) makes each seed take
a tools/host_slots.py slot before it copies its tree, so the sweep (and every other launcher
using that DIR) stays under N fits; --slot-all counts every running container of the container
runtime too, and --max-load L waits (with a slot dir) while the 1-minute load average is above
L. For a sweep on another machine see tools/remote_fit.py.

The ranking is by clk_sys setup slack (the profile's limiting clock) AMONG THE DEPLOYABLE seeds:
a seed whose framework `pll_hdmi` setup slack is below the deploy floor is flagged and can never
be BEST (clk_sys alone could recommend a placement that wedges the scaler). The floor and the
verdict rules are --min-other-setup (default -0.35 ns; `none` disables it), --min-positive
(require pll_hdmi > 0) and --min-seeds N (refuse a verdict from fewer than N measured seeds). The
report exits nonzero when the sweep has no deployable seed or the seed count is short, so a script
can refuse to deploy. Each seed's summary.txt records `other_setup`/`other_tns`/`other_clock`
(the worst framework clock) and `hdmi_setup`/`hdmi_tns` (pll_hdmi by name).

THE SDRAM PIN INTERFACE is the second deploy floor. tools/build.py runs tools/timing/sdram_io.tcl
after every fit (output_files/sdram_io.txt: the output and DQ read-capture setup/hold slacks at
every timing corner), and each summary records `sdram_out_setup`/`sdram_out_hold`/`sdram_in_setup`/
`sdram_in_hold` (each the worst over the corners) and `sdram_io_min`/`sdram_io_worst`. A seed is
deployable only when sdram_io_min >= --min-sdram-io (default 0 ns, tools/fit_metrics.py
SDRAM_IO_FLOOR; `none` disables); a seed fitted before the record existed is not deployable while
the floor is on.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_DIR))
import build_profile  # noqa: E402  (the configuration overrides, shared with tools/build.py)
sys.path.insert(0, str(PROJECT_DIR / "tools"))
import host_slots  # noqa: E402  (the shared-host ceiling: one slot per running fit)
import fit_metrics  # noqa: E402  (the per-fit numbers, shared with tools/fit_matrix.py)
COPY_EXCLUDE = (".git", ".build", "output_files", "db", "incremental_db",
                "build", "simulation", "__pycache__")
STATUS = "status.txt"      # the fit's own verdict (STATE=..., FIT_EXIT=...)
SUMMARY = "summary.txt"    # our recorded numbers for the seed
PRINT_LOCK = threading.Lock()


def log(msg: str) -> None:
    with PRINT_LOCK:
        print(msg, flush=True)


def sweep_dir(args) -> Path:
    return Path(args.dir).resolve() if args.dir else PROJECT_DIR / ".build" / "seedsweep"


def seed_dir(root: Path, seed: int) -> Path:
    return root / f"seed{seed:03d}"


def source_hash() -> str:
    """The RTL source hash the fits are of (the rule tools/check_fit.py attributes fits by)."""
    out = subprocess.run([sys.executable, str(PROJECT_DIR / "tools" / "check_fit.py"),
                          "--rtl-hash-of", str(PROJECT_DIR)],
                         capture_output=True, text=True, check=False)
    if out.returncode != 0:
        raise SystemExit(f"cannot hash the design sources: {out.stdout}{out.stderr}")
    return out.stdout.strip()


FIT_KNOBS = ("QUARTUS_FIT_SETTINGS", "QUARTUS_NUM_PARALLEL_PROCESSORS", "QUARTUS_AGGRESSIVE",
             "QUARTUS_DTM_RETRY", "QUARTUS_POST_STA_TCL", "QUARTUS_IMAGE")


def fit_knobs(env=None) -> dict:
    """The environment that changes what a fit produces (file contents, not paths)."""
    env = os.environ if env is None else env
    knobs = {}
    for k in FIT_KNOBS:
        v = env.get(k, "").strip()
        if not v:
            continue
        if k in ("QUARTUS_FIT_SETTINGS", "QUARTUS_POST_STA_TCL") and Path(v).is_file():
            v = "sha256:" + hashlib.sha256(Path(v).read_bytes()).hexdigest()
        knobs[k] = v
    return knobs


def make_identity(expected: str, source: str, knobs: dict) -> str:
    blob = json.dumps({"config": json.loads(expected), "source": source, "knobs": knobs},
                      sort_keys=True)
    return hashlib.sha256(blob.encode()).hexdigest()


def summary_field(sd: Path, key: str) -> str | None:
    """One `key=value` from a seed's summary.txt (None: no summary or no such key)."""
    try:
        for line in (sd / SUMMARY).read_text().splitlines():
            if line.startswith(key + "="):
                return line.split("=", 1)[1]
    except OSError:
        pass
    return None


def classify_seeds(root: Path, seeds: list[int], identity: str, *, trust_existing: bool,
                   retry_failed: bool) -> tuple[list[int], list[int]]:
    """(stale, redo): seeds whose recorded fit is of something else / to re-fit."""
    stale, redo = [], []
    for seed in seeds:
        sd = seed_dir(root, seed)
        if not (sd / SUMMARY).exists():
            continue
        got = summary_field(sd, "identity")
        if got is None:
            if not trust_existing:
                stale.append(seed)
        elif got != identity:
            stale.append(seed)
        elif retry_failed and summary_field(sd, "verdict") == "failed":
            redo.append(seed)
    return stale, redo


def move_aside(root: Path, seed: int) -> Path:
    sd = seed_dir(root, seed)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dst = sd.with_name(f"{sd.name}.stale-{stamp}")
    n = 0
    while dst.exists():
        n += 1
        dst = sd.with_name(f"{sd.name}.stale-{stamp}-{n}")
    sd.rename(dst)    # output_files travel with it: never deleted
    return dst


def copy_work_tree(dst: Path) -> None:
    """Copy the current tree into dst, excluding the heavyweight/generated dirs."""
    def ignore(_dir, names):
        return [n for n in names if n in COPY_EXCLUDE]
    shutil.copytree(PROJECT_DIR, dst, ignore=ignore, symlinks=True)


def fit_once(tree: Path, seed: int, profile_argv: list[str], expected: str) -> bool:
    """Apply the configuration in `tree`, then run one fit; True iff the fit passed."""
    log_path = tree / "build.log"
    status = tree / STATUS
    for stale in (log_path, status, tree / SUMMARY):
        if stale.exists():
            stale.unlink()
    # The configuration is TREE STATE (the top level's localparams + the qsf record; the PLL
    # and SDC are generated from it), so it is applied inside the seed's copy - the caller's
    # tree is never touched - and the copy must resolve to exactly the parent's configuration.
    sw = subprocess.run([sys.executable, str(tree / "build_profile.py"), *profile_argv],
                        cwd=tree, capture_output=True, text=True, check=False)
    got = subprocess.run([sys.executable, str(tree / "build_profile.py"), "--print-config"],
                         cwd=tree, capture_output=True, text=True, check=False)
    if sw.returncode != 0 or got.stdout.strip() != expected:
        log(f"  !! configuration did not apply: {sw.stdout}{sw.stderr}{got.stdout}{got.stderr}")
        return False
    cmd = [sys.executable, str(tree / "tools" / "build.py"), "--seed", str(seed),
           "--log", str(log_path), "--status-file", str(status)]
    subprocess.run(cmd, cwd=tree, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)
    return "STATE=passed" in status.read_text() if status.exists() else False


def _slack_after(text: str, key: str) -> float | None:
    """The slack on the line after the sta.summary row whose Setup line names `key`."""
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        if "Setup" in ln and key in ln and i + 1 < len(lines):
            m = re.search(r"\s(-?\d+\.\d+)\s*$|\s(-?\d+\.\d+)\s", lines[i + 1])
            if m:
                return float(next(g for g in m.groups() if g is not None))
    return None


def record(tree: Path) -> dict:
    """Extract the numbers we rank by out of the fit's reports."""
    out = {}
    sta = tree / "output_files" / "z486_mister.sta.summary"
    fit = tree / "output_files" / "z486_mister.fit.summary"
    if sta.exists():
        txt = sta.read_text(errors="replace")
        # clk_sdram (general[1]) exists only in fits of a pre-2026-10-09 split-clock tree; a
        # current fit's general[1] is the SDRAM pin clock and has no summary row.
        for name, key in (("clk_sys_slack", "emu|pll|pll_inst|altera_pll_i|general[0]"),
                          ("clk_sys_slack", "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0]."),
                          ("clk_sdram_slack", "emu|pll|pll_inst|altera_pll_i|general[1]")):
            if name in out:
                continue
            v = _slack_after(txt, key)
            if v is not None:
                out[name] = v
        m = re.search(r"Worst-case\s+Setup\s+Slack\s*:\s*(-?\d+\.\d+)", txt)
        if m:
            out["worst_setup_slack"] = float(m.group(1))
        # The framework clocks, from one parse (tools/fit_metrics.sta_numbers): the worst
        # "other" clock and, by name, pll_hdmi - the domain whose placement can wedge the
        # scaler. Its TNS is kept beside the slack: a cluster of failing paths with a WNS
        # that clears the floor is exactly the case the WNS alone cannot see.
        nums = fit_metrics.sta_numbers(txt)
        for key in ("other_setup", "other_tns", "other_clock", "hdmi_setup", "hdmi_tns"):
            if key in nums:
                out[key] = nums[key]
    # The SDRAM pin interface at every corner (output_files/sdram_io.txt, tools/build.py): the
    # read capture binds at the fast corner, which the sta.summary never shows.
    sio = tree / "output_files" / fit_metrics.SDRAM_IO_FILE
    if sio.exists():
        nums = fit_metrics.sdram_io_numbers(sio.read_text(errors="replace"))
        for key in SDRAM_IO_KEYS:
            if key in nums:
                out[key] = nums[key]
    if fit.exists():
        m = re.search(r"Logic utilization \(in ALMs\)\s*:\s*([\d,]+)\s*/\s*([\d,]+)",
                      fit.read_text(errors="replace"))
        if m:
            out["alm"] = int(m.group(1).replace(",", ""))
            out["alm_pct"] = round(100.0 * out["alm"] / int(m.group(2).replace(",", "")), 1)
    return out


def do_seed(root: Path, seed: int, profile_argv: list[str], expected: str, retries: int,
            identity: str = "", slots: dict | None = None) -> None:
    sd = seed_dir(root, seed)
    if (sd / SUMMARY).exists():
        return  # already done (resume; main() has refused or moved aside anything stale)
    sd.mkdir(parents=True, exist_ok=True)
    slot = token = None
    if slots and slots.get("dir"):
        slot = host_slots.acquire(Path(slots["dir"]), slots["max"], f"seed{seed:03d}",
                                  pid=os.getpid(), mine="*" if slots.get("all") else "",
                                  path=str(sd), poll=15, max_load=slots.get("max_load"))
        token = host_slots.token_of(slot)
    try:
        _fit_seed(sd, seed, profile_argv, expected, retries, identity)
    finally:
        if slot:
            host_slots.release(slot, token)


def _fit_seed(sd: Path, seed: int, profile_argv: list[str], expected: str,
              retries: int, identity: str) -> None:
    tree = sd / "tree"
    verdict = "failed"
    attempt = 0
    for attempt in range(1, retries + 2):
        if tree.exists():
            shutil.rmtree(tree)
        copy_work_tree(tree)
        log(f"[seed {seed:03d}] fit attempt {attempt}")
        if fit_once(tree, seed, profile_argv, expected):
            verdict = "passed"
            break
        log(f"[seed {seed:03d}] fit attempt {attempt} FAILED (the Quartus flake is expected ~30% of the time)")
        if (tree / "build.log").exists() and attempt <= retries:
            # Each failed attempt's log survives (the last attempt's is kept below as build.log).
            shutil.copy2(tree / "build.log", sd / f"build.attempt{attempt}.log")
    nums = record(tree)
    # Preserve the ENTIRE build output before the tree goes away: the RBF and the
    # basic timings are the minimum (the summary above), but a seed's full
    # output_files folder (the RBF, the sta/fit/map reports, the pin/model dumps)
    # plus the fit log are what make a result auditable later. Kept at
    # <dir>/seedNNN/output_files and <dir>/seedNNN/build.log.
    out_src = tree / "output_files"
    if out_src.exists():
        shutil.copytree(out_src, sd / "output_files", dirs_exist_ok=True)
    scratch_out = tree / ".build" / "quartus" / "output_files"
    if scratch_out.exists():
        shutil.copytree(scratch_out, sd / "output_files", dirs_exist_ok=True)
    if (tree / "build.log").exists():
        shutil.copy2(tree / "build.log", sd / "build.log")
    shutil.rmtree(tree, ignore_errors=True)   # keep the disk bounded
    # The full per-fit numbers (both clocks' setup/TNS/hold, LABs, fit time, any Quartus
    # internal error and where it struck) beside the summary, from the kept reports and log.
    with open(sd / "metrics.json", "w") as f:
        json.dump({"seed": seed, "verdict": verdict, "attempts": attempt,
                   "config": json.loads(expected), **fit_metrics.fit_metrics(sd)},
                  f, indent=1, sort_keys=True)
    # LAST, atomically: summary.txt is the "this seed is done" marker resume trusts.
    tmp = sd / (SUMMARY + ".tmp")
    with open(tmp, "w") as f:
        f.write(f"seed={seed}\nverdict={verdict}\nattempts={attempt}\n")
        f.write(f"config={expected}\n")
        if identity:
            f.write(f"identity={identity}\n")
        for k, v in nums.items():
            f.write(f"{k}={v}\n")
    os.replace(tmp, sd / SUMMARY)
    log(f"[seed {seed:03d}] {verdict} " +
        " ".join(f"{k}={v}" for k, v in nums.items()))


def load_summaries(root: Path) -> list[dict]:
    rows = []
    for sd in sorted(root.glob("seed*")):
        s = sd / SUMMARY
        if not s.exists():
            continue
        row = {"seed": sd.name}
        for line in s.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                try:
                    row[k] = float(v) if "." in v else int(v)
                except ValueError:
                    row[k] = v
        rows.append(row)
    return rows


# The deploy floor for the framework HDMI PLL's setup slack, from its single home in
# tools/fit_metrics.py (tools/mister_load.sh reads the same value through --print-hdmi-floor).
HDMI_FLOOR = fit_metrics.HDMI_FLOOR
# pll_hdmi TNS worse than this is a CAUTION, not a refusal: the one hardware-confirmed wedge is
# TNS -23.1 and the other bad-band seed -18.8, but a WNS that clears the floor can still carry
# a failing cluster (the worst such seed is -0.333/TNS -11.0) and none of those was
# hardware-tested, so the correlation is a hypothesis (study section 6.1).
TNS_CAUTION = -5.0
# The SDRAM pin-interface floor (tools/fit_metrics.py SDRAM_IO_FLOOR says why 0 ns) and the summary
# keys that carry it.
SDRAM_IO_FLOOR = fit_metrics.SDRAM_IO_FLOOR
SDRAM_IO_KEYS = ("sdram_out_setup", "sdram_out_hold", "sdram_in_setup", "sdram_in_hold",
                 "sdram_io_min", "sdram_io_worst")


def parse_floor(text: str) -> float | None:
    """--min-other-setup's value: a number, or `none` to disable the floor."""
    if text.strip().lower() in ("none", "off", "-"):
        return None
    return float(text)


def guard_value(row: dict) -> float | None:
    """The seed's pll_hdmi setup slack: by name if recorded, else the worst other clock.

    A summary written before hdmi_setup existed has only other_setup (the worst framework
    PLL), which in every fit of this tree is pll_hdmi; a sweep of such seeds is judged but
    the report says which key it used.
    """
    for key in ("hdmi_setup", "other_setup"):
        v = row.get(key)
        if isinstance(v, (int, float)):
            return float(v)
    return None


def guard_tns(row: dict) -> float | None:
    for key in ("hdmi_tns", "other_tns"):
        v = row.get(key)
        if isinstance(v, (int, float)):
            return float(v)
    return None


def evaluate(rows: list[dict], floor: float | None = HDMI_FLOOR, min_positive: bool = False,
             min_seeds: int = 1, tns_caution: float | None = TNS_CAUTION,
             sdram_floor: float | None = SDRAM_IO_FLOOR) -> dict:
    """The sweep's verdict as data: what may be deployed, and every reason it may not.

    The rule (docs/timing.md, the pll_hdmi study):
      * a seed is deployable when its pll_hdmi setup slack >= `floor` (default -0.35 ns);
      * --min-positive tightens that to > 0 ns (TNS 0: no failing path at all);
      * --min-seeds N refuses a verdict from fewer than N seeds that recorded a margin - the
        placer's seed-to-seed spread is 0.1-0.4 ns, so one fit is a draw, not a measurement;
      * pll_hdmi TNS < tns_caution is attached as a caution, never silently dropped;
      * a seed is deployable only when its SDRAM pin interface's worst slack over every corner
        and both directions (sdram_io_min) >= `sdram_floor` (default 0 ns, --min-sdram-io); a seed
        with no such record (fitted before tools/timing/sdram_io.tcl ran in every fit) is not
        deployable while the floor is on - its read window was never measured.
    Pure (no I/O) so the selftest can plant every case.
    """
    passed = []
    for r in rows:
        if r.get("verdict") != "passed":
            continue
        rr = dict(r)
        rr["hdmi"] = guard_value(rr)
        rr["hdmi_tns"] = guard_tns(rr)
        passed.append(rr)
    known = [r for r in passed if r["hdmi"] is not None]
    unknown = [r for r in passed if r["hdmi"] is None]
    deployable, rejected = [], []
    for r in known:
        if floor is not None and r["hdmi"] < floor:
            r["why"] = f"hdmi {r['hdmi']:+.3f} < floor {floor:+.3f} ns"
            rejected.append(r)
        elif min_positive and not r["hdmi"] > 0:
            r["why"] = f"hdmi {r['hdmi']:+.3f} is not positive"
            rejected.append(r)
        elif sdram_floor is not None and not isinstance(r.get("sdram_io_min"), (int, float)):
            r["why"] = ("no SDRAM I/O corner record (fitted before sdram_io.tcl ran in every "
                        "fit): refit, or --min-sdram-io none")
            rejected.append(r)
        elif sdram_floor is not None and r["sdram_io_min"] < sdram_floor:
            r["why"] = (f"SDRAM I/O {r['sdram_io_min']:+.3f} ({r.get('sdram_io_worst', '?')}) < "
                        f"floor {sdram_floor:+.3f} ns")
            rejected.append(r)
        else:
            deployable.append(r)
    for r in known:
        if (tns_caution is not None and r["hdmi_tns"] is not None
                and r["hdmi_tns"] < tns_caution):
            r["caution"] = f"TNS {r['hdmi_tns']:.1f} ns < {tns_caution:g}"
    deployable.sort(key=lambda r: -float(r.get("clk_sys_slack", -99)))
    problems: list[str] = []
    if len(known) < min_seeds:
        problems.append(f"only {len(known)} seed(s) recorded a pll_hdmi margin and "
                        f"--min-seeds {min_seeds} needs {min_seeds}: refit more seeds")
    if not deployable:
        if known and any("SDRAM I/O" in r.get("why", "") for r in rejected):
            problems.append(f"no seed clears both deploy floors (pll_hdmi and the SDRAM I/O "
                            f"{sdram_floor:+.3f} ns floor; each rejected seed says which)")
        elif known and floor is not None:
            worst = max(r["hdmi"] for r in known)
            problems.append(f"every one of {len(known)} measured seed(s) is below the "
                            f"{floor:+.3f} ns pll_hdmi deploy floor (best {worst:+.3f} ns)")
        elif known and min_positive:
            problems.append(f"no seed has a positive pll_hdmi margin "
                            f"({len(known)} measured)")
        else:
            problems.append("no seed recorded a pll_hdmi margin (refit; old summaries do not "
                            "carry one)")
    vals = [r["hdmi"] for r in known]
    stats = {
        "n": len(vals),
        "mean": statistics.mean(vals) if vals else None,
        "sd": statistics.stdev(vals) if len(vals) > 1 else (0.0 if vals else None),
        "min": min(vals) if vals else None,
        "max": max(vals) if vals else None,
        "ge0": sum(1 for v in vals if v >= 0),
        "ge_floor": (sum(1 for v in vals if floor is not None and v >= floor)
                     if floor is not None else len(vals)),
        "caution": [r for r in known if "caution" in r],
    }
    return {"passed": passed, "known": known, "unknown": unknown,
            "deployable": deployable, "rejected": rejected, "problems": problems,
            "stats": stats, "floor": floor, "sdram_floor": sdram_floor}


def report(root: Path, top: int = 10, floor: float | None = HDMI_FLOOR,
           min_positive: bool = False, min_seeds: int = 1,
           sdram_floor: float | None = SDRAM_IO_FLOOR) -> int:
    """Print the ranking and the deploy verdict; 0 iff the sweep has a deployable seed."""
    allrows = load_summaries(root)
    idents = {r.get("identity", "(none)") for r in allrows}
    if len(idents) > 1:
        log(f"  NOTE: {len(idents)} different fit identities in {root} (different source, "
            f"profile or knobs): this ranking mixes designs")
    res = evaluate(allrows, floor, min_positive, min_seeds, sdram_floor=sdram_floor)
    st = res["stats"]
    fl = "disabled" if floor is None else f"{floor:+.3f} ns"
    log(f"\n== {st['n']} seed(s) with a pll_hdmi margin, ranked by clk_sys among the "
        f"deployable ones (floor {fl}) ==")
    sfl = "disabled" if sdram_floor is None else f"{sdram_floor:+.3f} ns"
    log(f"   SDRAM I/O floor {sfl}: sdIO = the worst of out/in setup/hold over every corner")
    log(f"  {'seed':<10}{'clk_sys':>9}{'clk_sdram':>11}{'hdmi':>8}{'hdmiTNS':>9}"
        f"{'outS':>7}{'outH':>7}{'inS':>7}{'inH':>7}{'sdIO':>7}"
        f"{'ALM':>8}{'ALM%':>7}{'att':>5}")
    shown = res["deployable"][:top] + res["rejected"] + res["unknown"]
    for r in shown:
        flag = ""
        if r["hdmi"] is None:
            flag = "  ? no pll_hdmi margin recorded -- NOT DEPLOYABLE"
        elif "why" in r:
            flag = f"  ! {r['why']} -- NOT DEPLOYABLE"
        if "caution" in r:
            flag += f"  ~ pll_hdmi {r['caution']}"
        hdmi = f"{r['hdmi']:+.3f}" if r["hdmi"] is not None else "-"
        tns = f"{r['hdmi_tns']:.3f}" if r["hdmi_tns"] is not None else "-"
        sio = "".join(f"{r[k]:>+7.3f}" if isinstance(r.get(k), (int, float)) else f"{'-':>7}"
                      for k in ("sdram_out_setup", "sdram_out_hold", "sdram_in_setup",
                                "sdram_in_hold", "sdram_io_min"))
        log(f"  {r['seed']:<10}"
            f"{r.get('clk_sys_slack', 0):>9.3f}{r.get('clk_sdram_slack', 0):>11.3f}"
            f"{hdmi:>8}{tns:>9}{sio}"
            f"{r.get('alm', 0):>8}{r.get('alm_pct', 0):>7.1f}{r.get('attempts', 1):>5}"
            f"{flag}")
    if st["n"]:
        sd = f"{st['sd']:.3f}" if st["sd"] is not None else "-"
        log(f"  hdmi setup: n={st['n']} mean {st['mean']:+.3f} sd {sd} "
            f"min {st['min']:+.3f} max {st['max']:+.3f}; "
            f">= 0: {st['ge0']}/{st['n']}, >= floor: {st['ge_floor']}/{st['n']}")
        for r in st["caution"]:
            log(f"  ~ {r['seed']}: pll_hdmi TNS {r['hdmi_tns']:.1f} ns is a failing cluster "
                f"(caution only; one hardware-confirmed wedge runs -23.1)")
    if res["unknown"]:
        log(f"  {len(res['unknown'])} passed seed(s) carry no pll_hdmi margin (summaries "
            f"written before it was recorded): refit them to judge them")
    if res["problems"]:
        for p in res["problems"]:
            log(f"  FAIL: {p}")
    if res["deployable"] and not res["problems"]:
        best = res["deployable"][0]
        tns = f", TNS {best['hdmi_tns']:+.1f} ns" if best["hdmi_tns"] is not None else ""
        sio = (f", SDRAM I/O {best['sdram_io_min']:+.3f} ns ({best.get('sdram_io_worst', '?')})"
               if isinstance(best.get("sdram_io_min"), (int, float)) else "")
        log(f"\n  BEST: {best['seed']}  clk_sys {best.get('clk_sys_slack', 0):+.3f} ns, "
            f"hdmi {best['hdmi']:+.3f} ns{tns}{sio}")
    if res["problems"]:
        why = "; ".join(res["problems"])
        if res["deployable"]:
            log(f"VERDICT: FAIL -- no deploy verdict yet ({why})")
        else:
            log(f"VERDICT: FAIL -- nothing in this sweep may be deployed ({why})")
        return 1
    log(f"VERDICT: PASS -- {len(res['deployable'])} deployable seed(s) of {st['n']} "
        f"measured; deploy {res['deployable'][0]['seed']} "
        f"(hdmi {res['deployable'][0]['hdmi']:+.3f} ns)")
    return 0


def selftest() -> int:
    """Hardware-free checks of the resume/identity logic (plants each error and must catch it)."""
    import tempfile
    cfg = json.dumps({"clk": 80})
    ident = make_identity(cfg, "src1", {})
    assert ident != make_identity(cfg, "src2", {}), "source change must change identity"
    assert ident != make_identity(json.dumps({"clk": 75}), "src1", {}), "config change"
    assert ident != make_identity(cfg, "src1", {"QUARTUS_AGGRESSIVE": "1"}), "knob change"
    assert ident == make_identity(cfg, "src1", {}), "identity must be deterministic"
    with tempfile.TemporaryDirectory() as t:
        root = Path(t)
        def mk(seed, **kv):
            d = seed_dir(root, seed)
            (d / "output_files").mkdir(parents=True)
            (d / "output_files" / "keep.rbf").write_text("x")
            (d / SUMMARY).write_text("".join(f"{k}={v}\n" for k, v in kv.items()))
        mk(1, verdict="passed", identity=ident)
        mk(2, verdict="passed", identity="other")
        mk(3, verdict="passed")                      # pre-identity
        mk(4, verdict="failed", identity=ident)
        assert classify_seeds(root, [1, 2, 3, 4, 5], ident, trust_existing=False,
                              retry_failed=False) == ([2, 3], []), "stale detection"
        assert classify_seeds(root, [1, 2, 3, 4, 5], ident, trust_existing=True,
                              retry_failed=True) == ([2], [4]), "trust/retry"
        moved = move_aside(root, 2)
        assert (moved / "output_files" / "keep.rbf").exists(), "output_files must survive"
        assert not seed_dir(root, 2).exists()
    assert fit_knobs({"QUARTUS_AGGRESSIVE": "1", "OTHER": "z"}) == {"QUARTUS_AGGRESSIVE": "1"}

    # ---- the HDMI deploy guard: every planted case must be caught ----------------------
    def row(seed, clk_sys, hdmi, tns=0.0, verdict="passed", sdio=0.5):
        r = {"seed": seed, "verdict": verdict, "clk_sys_slack": clk_sys,
             "other_setup": hdmi, "other_tns": tns}
        if sdio is not None:
            r["sdram_io_min"] = sdio
            r["sdram_io_worst"] = "in_hold@MIN_fast_1100mv_-40c"
        return r
    # A below-floor seed that ranks best on clk_sys is excluded from BEST.
    rows = [row("seed001", -5.00, -0.10), row("seed002", -4.00, -0.60),
            row("seed003", -5.20, -0.349)]
    res = evaluate(rows)
    assert [r["seed"] for r in res["deployable"]] == ["seed001", "seed003"], res
    assert {r["seed"] for r in res["rejected"]} == {"seed002"}
    assert "below the" in res["rejected"][0]["why"] or "floor" in res["rejected"][0]["why"]
    # An all-below sweep is a failure, and the message says so.
    res = evaluate([row("seed001", -5.0, -0.40), row("seed002", -4.0, -0.50)])
    assert not res["deployable"] and res["problems"], res
    assert "floor" in res["problems"][0]
    # A negative but above-floor seed is deployable (the hardware-verified -0.33 case).
    res = evaluate([row("seed001", -5.0, -0.330)])
    assert [r["seed"] for r in res["deployable"]] == ["seed001"], res
    assert not res["problems"]
    # --min-positive rejects a non-positive sweep; one positive seed passes it.
    assert not evaluate([row("seed001", -5.0, -0.10)], min_positive=True)["deployable"]
    assert evaluate([row("seed001", -5.0, -0.10), row("seed002", -5.1, 0.05)],
                    min_positive=True)["deployable"][0]["seed"] == "seed002"
    # --min-seeds refuses a verdict from a short distribution.
    assert evaluate([row("seed001", -5.0, 0.1)], min_seeds=6)["problems"]
    assert not evaluate([row(f"seed{i:03d}", -5.0, 0.1) for i in range(1, 7)],
                        min_seeds=6)["problems"]
    # A TNS cluster is a caution, and a seed without any margin is unknown, not deployable.
    res = evaluate([row("seed001", -5.0, -0.20, tns=-9.0)])
    assert res["stats"]["caution"] and res["deployable"], res
    res = evaluate([{"seed": "seed001", "verdict": "passed", "clk_sys_slack": -5.0}])
    assert res["unknown"] and not res["deployable"], res
    # ---- the SDRAM pin-interface guard: every planted case must be caught --------------
    # A seed below the SDRAM I/O floor never ranks BEST, even with the best clk_sys.
    res = evaluate([row("seed001", -4.0, 0.1, sdio=-0.05), row("seed002", -5.0, 0.1, sdio=0.2)])
    assert [r["seed"] for r in res["deployable"]] == ["seed002"], res
    assert "SDRAM I/O" in res["rejected"][0]["why"], res
    # A seed with no corner record is not deployable while the floor is on, and is with `none`.
    res = evaluate([row("seed001", -4.0, 0.1, sdio=None)])
    assert not res["deployable"] and "no SDRAM I/O" in res["rejected"][0]["why"], res
    assert res["problems"], res
    assert evaluate([row("seed001", -4.0, 0.1, sdio=None)], sdram_floor=None)["deployable"]
    # A raised floor rejects a seed the default admits; exactly-at-floor is deployable.
    assert not evaluate([row("seed001", -4.0, 0.1, sdio=0.10)], sdram_floor=0.15)["deployable"]
    assert evaluate([row("seed001", -4.0, 0.1, sdio=0.0)])["deployable"]
    # The pll_hdmi reason wins the message when both fail (the deploy gate it has always been).
    res = evaluate([row("seed001", -4.0, -0.6, sdio=-1.0)])
    assert "hdmi" in res["rejected"][0]["why"], res
    # The parser: sdram_io.txt -> per-group worst over corners, the minimum, `na` tolerated.
    nums = fit_metrics.sdram_io_numbers(
        "corner=7_slow_1100mv_100c out_setup=1.2 out_hold=1.0 in_setup=0.9 in_hold=2.1\n"
        "corner=MIN_fast_1100mv_-40c out_setup=4.5 out_hold=1.7 in_setup=4.5 in_hold=0.25\n"
        "corner=MIN_fast_1100mv_100c out_setup=4.4 out_hold=na in_setup=4.1 in_hold=0.7\n")
    assert nums["sdram_in_hold"] == 0.25 and nums["sdram_out_hold"] == 1.0, nums
    assert nums["sdram_io_min"] == 0.25, nums
    assert nums["sdram_io_worst"] == "in_hold@MIN_fast_1100mv_-40c", nums
    assert fit_metrics.sdram_io_numbers("garbage\n") == {}
    # report() itself returns the gate's exit code (all-below fails, a good sweep passes).
    with tempfile.TemporaryDirectory() as t:
        root = Path(t)
        for seed, hdmi in ((1, -0.5), (2, -0.6)):
            d = seed_dir(root, seed)
            d.mkdir()
            (d / SUMMARY).write_text(f"seed={seed}\nverdict=passed\nclk_sys_slack=-5.0\n"
                                     f"other_setup={hdmi}\nsdram_io_min=0.4\n")
        assert report(root) == 1, "an all-below sweep must fail"
        (seed_dir(root, 2) / SUMMARY).write_text("seed=2\nverdict=passed\nclk_sys_slack=-4.0\n"
                                                 "other_setup=+0.1\nsdram_io_min=0.4\n")
        assert report(root) == 0, "one deployable seed must pass"
        assert report(root, min_seeds=6) == 1, "--min-seeds must refuse a short sweep"
        assert report(root, sdram_floor=0.5) == 1, "--min-sdram-io must refuse a short window"
        (seed_dir(root, 2) / SUMMARY).write_text("seed=2\nverdict=passed\nclk_sys_slack=-4.0\n"
                                                 "other_setup=+0.1\n")
        assert report(root) == 1, "a seed without an SDRAM I/O record must not pass the gate"
        assert report(root, sdram_floor=None) == 0, "`none` must disable the SDRAM I/O gate"
    print("seed_sweep selftest: PASS")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--profile", choices=sorted(build_profile.PROFILES),
                    help="the build_profile preset (default heavyoc, or the --profile-file's "
                         "'preset'); overrides apply on top")
    ap.add_argument("--count", type=int, default=100, help="how many seeds to sweep (default 100)")
    ap.add_argument("--jobs", type=int, default=10, help="max concurrent fits (default 10)")
    ap.add_argument("--retries", type=int, default=3, help="retries per seed for the fit flake (default 3)")
    ap.add_argument("--dir", help="the sweep directory (default <repo>/.build/seedsweep)")
    ap.add_argument("--seeds", help="an explicit list, e.g. 1,2,5-8")
    ap.add_argument("--report", action="store_true", help="just rank the finished seeds")
    ap.add_argument("--top", type=int, default=10, help="how many rows the report prints")
    ap.add_argument("--min-other-setup", type=parse_floor, default=HDMI_FLOOR,
                    metavar="NS",
                    help="the pll_hdmi setup-slack deploy floor (default -0.35 ns: admits every "
                         "hardware-verified good placement and rejects every known scaler wedge; "
                         "`none` disables it). A seed below it is flagged and never BEST, and a "
                         "sweep with no seed above it exits nonzero")
    ap.add_argument("--min-sdram-io", type=parse_floor, default=SDRAM_IO_FLOOR, metavar="NS",
                    help="the SDRAM pin-interface deploy floor: the worst of the output and DQ "
                         "read-capture setup/hold slacks over every timing corner "
                         "(output_files/sdram_io.txt) must be >= NS (default 0 ns: the SDC's "
                         "constraints are the supported modules' datasheet limits; `none` "
                         "disables it). A seed with no record is not deployable while it is on")
    ap.add_argument("--min-positive", action="store_true",
                    help="deploy only seeds with pll_hdmi > 0 ns (TNS 0: no failing path)")
    ap.add_argument("--min-seeds", type=int, default=1, metavar="N",
                    help="refuse a verdict from fewer than N seeds that recorded a pll_hdmi "
                         "margin (use 6 for a change's A/B: the seed spread is 0.1-0.4 ns)")
    ap.add_argument("--restart-stale", action="store_true",
                    help="seeds recorded for a different identity are renamed seedNNN.stale-<time> "
                         "(kept) and fitted afresh, instead of refusing the sweep")
    ap.add_argument("--retry-failed", action="store_true",
                    help="re-fit seeds recorded verdict=failed (old dir kept as .stale-<time>)")
    ap.add_argument("--trust-existing", action="store_true",
                    help="accept summaries written before identities existed")
    ap.add_argument("--slot-dir", default=os.environ.get("FIT_SLOT_DIR"),
                    help="host_slots directory: each seed holds one slot while it fits "
                         "(env FIT_SLOT_DIR)")
    ap.add_argument("--slot-max", type=int, default=int(os.environ.get("FIT_SLOT_MAX", "0") or 0),
                    help="the ceiling for --slot-dir (env FIT_SLOT_MAX)")
    ap.add_argument("--slot-all", action="store_true",
                    help="also count every running container of the runtime against the ceiling")
    ap.add_argument("--max-load", type=float, default=None,
                    help="with --slot-dir: wait to start a fit while the 1-minute load average "
                         "exceeds this")
    ap.add_argument("--selftest", action="store_true", help="run the hardware-free logic checks")
    ap.add_argument("--prepare", action="store_true",
                    help="resolve the configuration and generate its PLL into the shared cache "
                         "(and have Quartus check its qsf_set), then exit without fitting - so "
                         "concurrent sweeps of one configuration never generate it at once")
    build_profile.add_override_args(ap)
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if args.slot_dir and args.slot_max < 1:
        ap.error("--slot-dir needs --slot-max N (N >= 1)")
    root = sweep_dir(args)
    root.mkdir(parents=True, exist_ok=True)

    if args.report:
        return report(root, args.top, args.min_other_setup, args.min_positive, args.min_seeds,
                      args.min_sdram_io)

    if args.seeds:
        seeds = []
        for part in args.seeds.split(","):
            if "-" in part:
                a, b = part.split("-")
                seeds.extend(range(int(a), int(b) + 1))
            else:
                seeds.append(int(part))
    else:
        seeds = list(range(1, args.count + 1))

    if args.profile:
        preset = [args.profile]
    elif args.profile_file or args.custom:
        preset = []
    else:
        preset = ["heavyoc"]
    profile_argv = preset + build_profile.override_argv(args)
    resolved = subprocess.run([sys.executable, str(PROJECT_DIR / "build_profile.py"),
                               "--print-config", *profile_argv],
                              capture_output=True, text=True, check=False)
    if resolved.returncode != 0:
        log(f"configuration {' '.join(profile_argv)} is invalid:\n{resolved.stdout}{resolved.stderr}")
        return 1
    expected = resolved.stdout.strip()
    # One PLL generation for the whole sweep: every seed's copy shares the parent's cache.
    os.environ.setdefault("PC9821_PLL_CACHE", str(PROJECT_DIR / ".build" / "pll-cache"))
    import profile_gen
    config = build_profile.config_from_record(json.loads(expected))
    with tempfile.TemporaryDirectory(prefix="seed-sweep-pll-") as tmp:
        try:
            profile_gen.generate_pll(config.pll_request(), Path(tmp), project_dir=PROJECT_DIR,
                                     log=log)
            profile_gen.generate_vpll(config.vpll_request(), Path(tmp), project_dir=PROJECT_DIR,
                                      log=log)
        except profile_gen.GenerationError as exc:
            log(f"PLL generation failed, nothing swept: {exc}")
            return 1
    problems = build_profile.quartus_check_qsf_set(config.qsf_set)
    if problems:
        log("qsf_set refused, nothing swept:\n  " + "\n  ".join(problems))
        return 1
    if args.prepare:
        log(f"prepared: {expected}")
        return 0

    identity = make_identity(expected, source_hash(), fit_knobs())
    stale, redo = classify_seeds(root, seeds, identity, trust_existing=args.trust_existing,
                                 retry_failed=args.retry_failed)
    if stale and not args.restart_stale:
        log(f"REFUSING: seeds {stale} in {root} were fitted from a different source, profile or "
            f"fit knobs (or predate identities); resuming would mix two designs in one ranking.\n"
            f"  --restart-stale moves them aside (kept) and re-fits, --trust-existing accepts "
            f"pre-identity summaries, or choose a fresh --dir.")
        return 1
    for sd_seed in stale + redo:
        log(f"moved aside: {move_aside(root, sd_seed)}")
    (root / "sweep.json").write_text(json.dumps(
        {"identity": identity, "config": json.loads(expected), "knobs": fit_knobs()},
        indent=1, sort_keys=True))
    slots = ({"dir": args.slot_dir, "max": args.slot_max, "all": args.slot_all,
              "max_load": args.max_load} if args.slot_dir else None)
    log(f"sweeping {len(seeds)} seeds of {' '.join(profile_argv)} with {args.jobs} jobs, "
        f"{args.retries} retries -> {root}")
    log(f"configuration: {expected}")
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futs = {pool.submit(do_seed, root, s, profile_argv, expected, args.retries, identity, slots): s
                for s in seeds}
        for f in cf.as_completed(futs):
            f.result()   # surface any unexpected exception
    return report(root, args.top, args.min_other_setup, args.min_positive, args.min_seeds,
                      args.min_sdram_io)


if __name__ == "__main__":
    raise SystemExit(main())

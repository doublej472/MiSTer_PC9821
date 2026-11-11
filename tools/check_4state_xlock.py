#!/usr/bin/env python3
"""Run the benches whose claim is a 4-STATE X-lock under iverilog, outside the build path.

WHY THIS EXISTS. `tools/bench.py` is the one bench runner and its engine is Verilator,
which is 2-STATE: a register with no initialiser and no reset reads as 0, so a bench
whose whole point is "this self-fed counter must not X-lock" cannot fail under the gate
at all. Six benches carry that claim (`audio_volume_x`, `cdda_div_reset`, `cg_win_seed`,
`crtc_stat_seed`, `kbd_warmreset`, `system_reset_seed`).
A claim the shipped run cannot falsify is not evidence, so this script gives the
falsifiable ones their own explicitly named 4-state run.

WHY iverilog AND NOT A VERILATOR FLAG. Verilator has no 4-state mode. `--x-assign`
chooses the value a --x-assign-able X in the SOURCE becomes, and `--x-initial unique`
gives each uninitialised variable a distinct DEFINITE value; neither propagates X. An
unseeded self-fed register would start at some definite value and resolve normally, so
the X-lock the bench is named for still could not be reached. Icarus Verilog is a real
4-state simulator and is the tool used here.

WHY THIS IS NOT IN THE BUILD PATH. `tools/check_wiring.py` holds the rule that no
build-path file invokes iverilog/vvp, and that rule is right -- the gate must be one
engine. This script is exempted by name from that check, is named by the six benches' banners, and is
run BY HAND or as a separate check; nothing in `tests/`/`tools/` invokes it and
`tools/bench.py --all` never sees it.

WHAT IT RUNS. Its file list is the SAME manifest `tools/bench.py` reads
(`tools/gen_bench_sources.py`), so the DUT it elaborates cannot drift from the one the
gate elaborates. Same verdict discipline as bench.py: a bench passes only when vvp
exited 0 AND its `TB_<NAME>: PASS` marker is alone on a line.

  python3 tools/check_4state_xlock.py                every covered bench
  python3 tools/check_4state_xlock.py crtc_stat_seed  one bench (the bench.py name)
  python3 tools/check_4state_xlock.py --list          what is covered, and what is not
  python3 tools/check_4state_xlock.py --selftest      + the RTL ablations that must FAIL
  python3 tools/check_4state_xlock.py --keep          keep the build dir for inspection

`--selftest` is what keeps this run a CHECK rather than a green light: for every covered
bench it applies a named ablation to the DUT source (in memory, into a temp dir outside
the tree), rebuilds, and REQUIRES the 4-state run to fail. A 4-state run that passes on a
broken design is no better than the 2-state one, so a mutation that is NOT caught is
reported as a defect of this script, not as a pass. A mutant that DOES NOT ELABORATE is
reported as a defect too: a build the elaborator rejected never ran, so it is no evidence
that the guard works (audit-benches F2 -- `caught = not ok` counted iverilog's own
rejection as a catch, which is the "a check that cannot fail" class again).

COVERAGE IS NOT UNIFORM, and the script says so out loud rather than in prose: see
COVERS/UNCOVERED below. `system_reset_seed` is listed and NOT run -- pc9821_system does
not elaborate under iverilog at all, and the FIRST error is not in the bench's own RTL but in
the frozen vendored `src/opna/jt12/hdl/jt12_top.v`. Its banner was weakened to say so.
Registers whose power-up value the 4-state run reaches are named per bench in
COVERS[...]['registers'].

Exit: 0 every covered bench passed (and, with --selftest, every ablation was caught);
     1 a bench failed or an ablation escaped; 3 no 4-state simulator on this host.
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
TB_DIR = ROOT / "tests/pc9821"
Z486, X87 = ROOT / "src/z486", ROOT / "src/z486/x87"

# iverilog needs both an elaborator and its runtime; naming only the first would report
# a missing simulator as a bench failure.
IVERILOG, VVP = "iverilog", "vvp"

BUILD_TIMEOUT, RUN_TIMEOUT = 300, 120

# The six benches the audit named. `registers` is what the bench's own X assertions
# CAN see -- not what its claim mentions, which is the distinction the report carries.
COVERS: dict[str, dict] = {
    "audio_volume_x": {
        "mutations": [
            ("src/pc9821/audio/pc9821_audio_volume.sv",
             "reg [3:0] ch = 4'd0;", "reg [3:0] ch;",
             "drop the channel counter's power-up seed (the self-fed X-lock)"),
            ("src/pc9821/audio/pc9821_audio_volume.sv",
             "initial begin\n    out_q = '0;\n    valid = 1'b0;\nend",
             "initial begin\nend",
             "drop the captured output fields' power-up seed (they read X until first captured)"),
        ],
    },
    "cdda_div_reset": {
        "mutations": [
            ("src/soc/cdda.v",
             "reg         clk_44100 = 0;\nreg  [CNT_W-1:0] clk_44100_cnt = 0;",
             "reg         clk_44100;\nreg  [CNT_W-1:0] clk_44100_cnt;",
             "drop the 44.1 kHz divider's power-up seed (the accumulator X-lock)"),
            ("src/soc/cdda.v",
             "reg [BUFFER_WIDTH-1:0] read_addr = 0, write_addr = 0;",
             "reg [BUFFER_WIDTH-1:0] read_addr, write_addr;",
             "drop the ring pointers' power-up seed (buffer_q reads X)"),
            ("src/soc/cdda.v",
             "reg [15:0] audio_l = 0;\nreg [15:0] audio_r = 0;",
             "reg [15:0] audio_l;\nreg [15:0] audio_r;",
             "drop the resample flops' power-up seed"),
        ],
    },
    "cg_win_seed": {
        "mutations": [
            ("src/pc9821/video/pc9821_cg.sv",
             "  reg         win_rd_d = 1'b0;", "  reg         win_rd_d;",
             "drop the window-read mux register's power-up seed"),
            ("src/pc9821/video/pc9821_cg.sv",
             "  reg        cfg_seed_hit_q = 1'b0;\n  reg  [7:0] cfg_seed_read_q = 8'd0;",
             "  reg        cfg_seed_hit_q;\n  reg  [7:0] cfg_seed_read_q;",
             "drop the configuration-seed compare registers' power-up seed"),
        ],
    },
    "crtc_stat_seed": {
        "mutations": [
            ("src/pc9821/video/pc9821_crtc.sv",
             "    reg       stat_dr = 1'b0;", "    reg       stat_dr;",
             "drop the GDC status toggle's power-up seed (the self-fed X-lock)"),
            ("src/pc9821/video/pc9821_crtc.sv",
             "      vs_sync_ff <= 2'b00;\n      de_ff      <= 2'b00;",
             "      vs_sync_ff <= 2'b11;\n      de_ff      <= 2'b11;",
             "change the resample flops' RESET value (the 2-state half of the claim)"),
        ],
    },
    "kbd_warmreset": {
        "mutations": [
            ("src/pc9821/input/pc9821_kbd.sv",
             "      ctrl_writes  <= 8'd0;\n", "",
             "drop the control-write counter's reset (its X-lock sets the dbg latches X)"),
        ],
    },
}

# Named, with the reason, so a reader of `--list` sees the uncovered case instead of
# finding five out of six and assuming the sixth is run somewhere else.
UNCOVERED: dict[str, str] = {
    "system_reset_seed": (
        "pc9821_system still does not elaborate in iverilog, but NOT for the two reasons "
        "this bench once listed: those are fixed (pc9821_dmac.sv:536 (dout_comb = 8'hFF;) is now a "
        "legal l-value, and its iobus sibling "
        "src/pc9821/core/pc9821_iobus.sv:470 (assign dbg_itf_stage = itf_stage;) now "
        "follows its declaration). What iverilog reports FIRST is a frozen file: "
        "src/opna/jt12/hdl/jt12_top.v labels two generate blocks `gen_adpcm` "
        "(use_adpcm==1 and use_adpcm==2), which iverilog rejects even "
        "though the conditions are exclusive. With that one label renamed in a copy OUTSIDE "
        "the tree, 140 errors appear over 11 files (87 of them in pc9821_system.sv) where "
        "the pre-fix tree had 161 - so the two fixes removed 21 errors and unlocked "
        "nothing. Its F6/F7 claims were weakened to what the Verilator run proves."
    ),
}

MARKER_RE_CACHE: dict[str, str] = {}

# The three outcomes of a build+run, kept apart because they are not the same evidence.
# A mutant that iverilog REJECTS never ran, so "the run failed" cannot be concluded from
# it; only RUN_FAIL is a caught ablation. This is the distinction F2 asked for.
RUN_PASS = "pass"          # built, ran, printed the marker alone on a line, exited 0
RUN_FAIL = "fail"          # built and ran, and the 4-state run did not pass -- a CATCH
BUILD_FAIL = "build-fail"  # iverilog rejected it, or the bench cannot be built at all


def load_manifest() -> dict:
    spec = importlib.util.spec_from_file_location("gen_bench_sources", ROOT / "tools/gen_bench_sources.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.BENCHES


def which(name: str) -> str | None:
    return shutil.which(name)


def build_and_run(name: str, manifest: dict, workdir: pathlib.Path, override: dict[pathlib.Path, pathlib.Path]
                  ) -> tuple[str, str]:
    """Elaborate `tb_pc9821_<name>` with iverilog and run it. -> (state, transcript).

    `override` swaps DUT sources for modified copies (the --selftest path), so the build
    uses the same list the gate uses with exactly one file substituted. The state is one
    of RUN_PASS / RUN_FAIL / BUILD_FAIL; a build failure is NOT a caught ablation."""
    entry = manifest.get(name)
    if entry is None:
        return BUILD_FAIL, f"no such bench: {name}"
    marker, _claim, files = entry
    if not files:
        return BUILD_FAIL, "the manifest declares no sources for this bench"

    tb = TB_DIR / f"tb_pc9821_{name}.sv"
    if not tb.exists():
        return BUILD_FAIL, f"missing testbench {tb}"

    sources = []
    for f in files:
        p = ROOT / f
        sources.append(str(override.get(p, p)))
    out = workdir / f"{name}.vvp"
    top = f"tb_pc9821_{name}"
    argv = [IVERILOG, "-g2012", "-s", top, f"-I{Z486}", f"-I{X87}", "-o", str(out),
            *sources, str(tb)]
    try:
        built = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=BUILD_TIMEOUT)
    except subprocess.TimeoutExpired:
        return BUILD_FAIL, f"iverilog timed out after {BUILD_TIMEOUT}s"
    log = built.stdout + built.stderr
    # iverilog's own warnings (a 'sorry:' about an unsupported construct, a static-init
    # note) are not the verdict; only its exit status is.
    if built.returncode != 0:
        return BUILD_FAIL, "iverilog failed:\n" + "\n".join(
            ln for ln in log.splitlines() if "warning:" not in ln and "sorry:" not in ln)[:4000]

    try:
        ran = subprocess.run([VVP, str(out)], cwd=workdir, capture_output=True, text=True,
                             timeout=RUN_TIMEOUT)
    except subprocess.TimeoutExpired:
        # It BUILT and then did not finish: for a bench, not a pass. (An X-locked run can
        # hang, which is a real failure of the run, not of the elaborator.)
        return RUN_FAIL, f"vvp timed out after {RUN_TIMEOUT}s (an X-locked run can hang)"

    log = ran.stdout + ran.stderr
    passed = re.search(rf"^{re.escape(marker)}: PASS[ \t\r]*$", log, re.M) is not None
    if passed and ran.returncode == 0:
        return RUN_PASS, log
    why = "no PASS marker" if not passed else f"printed PASS but exited {ran.returncode}"
    return RUN_FAIL, f"{why}\n" + "\n".join(log.splitlines()[-12:])


def run_covered(names: list[str], manifest: dict, workdir: pathlib.Path) -> int:
    bad = 0
    for name in names:
        state, log = build_and_run(name, manifest, workdir, {})
        print(f"{name:<22}{'PASS' if state == RUN_PASS else 'FAIL'}")
        if state != RUN_PASS:
            bad += 1
            for line in log.splitlines()[:8]:
                print("    " + line)
    return bad


def selftest(names: list[str], manifest: dict, workdir: pathlib.Path) -> int:
    """Every named ablation must make the 4-state run FAIL. An uncaught one is a defect.

    A mutant the elaborator REJECTS is a defect of this script too: nothing ran, so the
    guard has not been shown to work. `caught = not ok` conflated the two (F2)."""
    escaped = 0
    for name in names:
        for src, old, new, label in COVERS[name]["mutations"]:
            path = ROOT / src
            text = path.read_text()
            hits = text.count(old)
            if hits != 1:
                print(f"{name:<22}ABLATION STALE ({src}: {hits} matches for {old!r})")
                escaped += 1
                continue
            mut = workdir / f"mut-{name}" / path.name
            mut.parent.mkdir(parents=True, exist_ok=True)
            mut.write_text(text.replace(old, new, 1))
            state, log = build_and_run(name, manifest, workdir, {path: mut})
            verdict = {RUN_PASS: "ESCAPED", RUN_FAIL: "caught",
                       BUILD_FAIL: "DID NOT BUILD"}[state]
            print(f"{name:<22}{verdict}  {label}")
            if state == RUN_PASS:
                escaped += 1
                print("    the 4-state run PASSED on the ablated DUT (a claim that cannot fail)")
            elif state == BUILD_FAIL:
                escaped += 1
                print("    the mutated DUT did not elaborate, so the run never happened: "
                      "no evidence the guard works (an unbuildable mutant is not a catch)")
                for line in log.splitlines()[:6]:
                    print("      " + line)
    if escaped:
        print(f"==> {escaped} ablation(s) were not a failing 4-state run: this check is not yet a check")
    else:
        print("==> every ablation failed the 4-state run it is the fail-first for")
    return escaped


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("bench", nargs="*", help="bench name(s) as tools/bench.py spells them")
    ap.add_argument("--list", action="store_true", help="print coverage and the uncovered case")
    ap.add_argument("--selftest", action="store_true", help="run the RTL ablations that must fail")
    ap.add_argument("--keep", action="store_true", help="keep the temp build dir")
    args = ap.parse_args()

    if args.list:
        for name in sorted({*COVERS, *UNCOVERED}):
            if name in COVERS:
                print(f"{name:<22}covered   ({len(COVERS[name]['mutations'])} ablation(s) in --selftest)")
            else:
                print(f"{name:<22}NOT RUN   {UNCOVERED[name]}")
        return 0

    names = args.bench or sorted(COVERS)
    unknown = [n for n in names if n not in COVERS]
    if unknown:
        for n in unknown:
            print(f"{n}: not covered by this run"
                  + (f" -- {UNCOVERED[n]}" if n in UNCOVERED else " (not one of the six)"),
                  file=sys.stderr)
        return 1

    if not (which(IVERILOG) and which(VVP)):
        # Never a silent skip: the six benches' X-lock claim then has NO run behind it.
        print(f"{IVERILOG}/{VVP} is not installed, so the 4-state X-lock claims of "
              f"{', '.join(sorted(COVERS))} have no backing run on this host. Install "
              f"Icarus Verilog (or run these six by hand on a host that has it); the "
              f"Verilator gate cannot substitute -- it is 2-state.", file=sys.stderr)
        return 3

    manifest = load_manifest()
    missing = [n for n in sorted(COVERS) if n not in manifest]
    if missing:
        print(f"these benches are no longer in the manifest, so their claim has lost its "
              f"backing run: {missing}", file=sys.stderr)
        return 1

    workdir = pathlib.Path(tempfile.mkdtemp(prefix="four-state-"))
    try:
        print(f"==> {len(names)} bench(es) under {IVERILOG} (4-state), build dir {workdir}")
        bad = run_covered(names, manifest, workdir)
        if args.selftest:
            bad += selftest(names, manifest, workdir)
        for name in sorted(UNCOVERED):
            print(f"{name:<22}NOT RUN   {UNCOVERED[name].splitlines()[0][:90]}...")
        print(f"==> {len(names) - bad}/{len(names)} 4-state runs pass" if not args.selftest
              else f"==> {'all covered benches pass and every ablation was caught' if not bad else f'{bad} problem(s)'}")
        return 1 if bad else 0
    finally:
        if args.keep:
            print(f"kept: {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

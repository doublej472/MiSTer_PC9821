#!/usr/bin/env python3
"""The numbers one fit is judged by, read from its output_files/ (and its build log).

    tools/fit_metrics.py <dir> [<dir> ...]     # a seed directory: <dir>/output_files + build.log

Every value comes from Quartus's own reports, with the clock NAMED as STA names it:
general[0] is clk_sys (z486_mister.sdc's pc9821_clk_sys), which since the split-clock removal
(2026-10-09) is the SDRAM controller's clock too. In a fit of an
OLDER split-clock tree general[1] was clk_sdram; in a current fit general[1] is the SDRAM pin clock,
which has no register endpoints and so never appears in the summary - clk_sdram_* are then absent. The STA summary is the slow corner only (the qsf sets
TIMEQUEST_MULTICORNER_ANALYSIS OFF), which is what every fit in this tree has been ranked by.

  labs            fit.rpt's `Total LABs: partially or completely used` (THE binding resource)
  map_alms        map.rpt's `Estimate of Logic utilization (ALMs needed)`: the source's own logic,
                  identical over seeds (tools/fit_area.py splits a fit's area with it)
  alms_needed     fit.summary's `Logic utilization (in ALMs)` (= ALMs needed [=A-B+C])
  registers       fit.summary's `Total registers`
  interconnect    fit.rpt's peak interconnect usage, total %
  clk_sys_setup / clk_sys_tns / clk_sys_hold         general[0]
  clk_sdram_setup / clk_sdram_tns / clk_sdram_hold   general[1], split-clock fits only (absent otherwise)
  sdram_io_setup / sdram_io_tns / sdram_io_hold      PC9821_SDRAM_CLK: the SDRAM PIN interface (the
                   SDC's set_output_delay/set_input_delay on SDRAM_*), which no core clock's
                   summary row includes - a pin that loses its fast I/O register shows up only here
  sdram_out_setup / sdram_out_hold / sdram_in_setup / sdram_in_hold
                   the SDRAM pin interface's worst slack per group over EVERY timing corner, from
                   output_files/sdram_io.txt (tools/timing/sdram_io.tcl, run by tools/build.py after
                   every fit): out = command/address/DQM/write data at the pins, in = the DQ read
                   capture, whose window binds at the FAST corner the flow's summary never shows
  sdram_io_min / sdram_io_worst           the smallest of those four and `group@corner` naming it:
                   what tools/seed_sweep.py --min-sdram-io gates on
  sdram_io_corners                        the whole per-corner table (metrics.json only)
  other_setup / other_tns / other_clock   the worst setup slack of every OTHER clock in the summary
                   (framework PLLs) and that clock's TNS and short name
  hdmi_setup / hdmi_tns                   the framework HDMI PLL (`pll_hdmi`) specifically: the domain
                   whose placement can wedge the scaler (docs/timing.md, the pll_hdmi study). It is
                   the clock `other_setup` normally names, but recording it by name keeps the
                   deploy guard on the right clock even if another framework PLL is worse.
  map_min / fit_min / sta_min                        flow.rpt's elapsed time per module
  internal_errors  every distinct `Internal Error: Sub-system: X, File: F, Line: L` in the log
  dtm_fallback     the build re-fitted after the DTM crash (tools/build.py's fallback)
  crash_stage      where the first internal error struck (the last `Info (NNN): Starting ...`
                   or module banner before it)
  rbf              the bitstream exists
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

PROJECT = "z486_mister"
# The deploy-time timing record beside the RBF. tools/build.py writes it after every fit and
# tools/mister_load.sh refuses an RBF whose pll_hdmi margin is below the floor.
ARTIFACT = "artifact-timing.json"
# THE deploy floor for the framework HDMI PLL's setup slack, stated once for the tools: the
# observed bad band is -0.635 (a hardware-confirmed scaler wedge), -0.633, -0.845, -0.932,
# -1.005 and -1.721, while hardware-verified GOOD placements reach -0.33, so -0.35 ns admits
# every known-good placement and rejects every known wedge. tools/seed_sweep.py and
# tools/fit_matrix.py import it; tools/mister_load.sh reads it through --print-hdmi-floor.
# The rule and its numbers: docs/fitting.md, "Timing and area facts".
HDMI_FLOOR = -0.35
# THE deploy floor for the SDRAM pin interface (sdram_io_min, every corner, both directions), stated
# once for the tools like HDMI_FLOOR. The SDC's I/O constraints ARE the supported module set's
# datasheet limits (Alliance AS4C32M16SB -7, the slower grade of the supported -6/-7 parts: tAC 6.0,
# tOH 2.5, tIS 1.5, tIH 0.8 ns), applied at every FPGA corner at once, so any slack >= 0 means the
# placement meets the supported parts' datasheet at every corner; below 0 a corner of the fitted
# placement misses one of them. The model carries no board flight time and no dual-chip loading,
# and the hardware window the shmoo measures is what sizes the real margin (AGENTS.md, Timing and
# area facts): this floor only refuses a placement STA already says is outside the datasheet.
SDRAM_IO_FLOOR = 0.0
TIMING_KEYS = ("other_setup", "other_tns", "other_clock", "hdmi_setup", "hdmi_tns",
               "clk_sys_setup", "clk_sys_tns", "sdram_io_min", "sdram_io_worst")
# The per-corner SDRAM pin-interface record tools/build.py writes beside the reports.
SDRAM_IO_FILE = "sdram_io.txt"
SDRAM_IO_GROUPS = ("out_setup", "out_hold", "in_setup", "in_hold")

# The core PLL's outputs (pll_audio also has a general[0], so the instance is part of the key).
# A dynamic-phase-shift build (sdram_phase_dyn) names the same outputs cyclonev_pll|counter[N].
CLOCKS = (("clk_sys", "emu|pll|pll_inst|altera_pll_i|general[0]"),
          ("clk_sys", "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0]."),
          ("clk_sdram", "emu|pll|pll_inst|altera_pll_i|general[1]"),
          ("sdram_io", "PC9821_SDRAM_CLK"))
INTERNAL_RE = re.compile(r"Internal Error: Sub-system: (\w+), File: (\S+), Line: (\d+)")
# A crash that is not an assertion: "*** Fatal Error: Segment Violation at (nil)".
FATAL_RE = re.compile(r"\*\*\* Fatal Error: (.*)")
STAGE_RE = re.compile(r"Info(?: \(\d+\))?: (Start(?:ing|ed) [^.]*|Running Quartus Prime [A-Za-z &]+|"
                      r"Fitter \w+(?: \w+)? operations (?:beginning|ending)|Delay annotation completed)")


def _read(path: Path) -> str | None:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return None


def clock_short(clock: str) -> str:
    """A readable name for a STA clock path (`pll_hdmi|...` -> `pll_hdmi`)."""
    for name in ("pll_hdmi", "pll_audio"):
        if name in clock:
            return name
    return clock.split("|")[-1]


def sta_numbers(text: str) -> dict:
    """{clk_sys_setup, clk_sys_tns, clk_sys_hold, ..., other_setup, hdmi_setup, ...} from a
    sta.summary."""
    out: dict = {}
    other: list[tuple[float, float | None, str]] = []
    for block in re.split(r"\n\s*\n", text):
        m = re.search(r"Type\s*:\s*(Setup|Hold|Recovery|Removal)\s+'([^']*)'", block)
        if not m:
            continue
        kind, clock = m.group(1).lower(), m.group(2)
        slack = re.search(r"Slack\s*:\s*(-?\d+\.\d+)", block)
        tns = re.search(r"TNS\s*:\s*(-?\d+\.\d+)", block)
        value = float(slack.group(1)) if slack else None
        tn = float(tns.group(1)) if tns else None
        core = next((name for name, key in CLOCKS if key in clock), None)
        if core:
            if value is not None:
                out[f"{core}_{kind}"] = value
            if tn is not None and kind == "setup":
                out[f"{core}_tns"] = tn
        elif kind == "setup" and value is not None:
            other.append((value, tn, clock))
    if other:
        worst = min(other, key=lambda o: o[0])
        out["other_setup"] = worst[0]
        out["other_clock"] = clock_short(worst[2])
        if worst[1] is not None:
            out["other_tns"] = worst[1]
        hdmi = [o for o in other if clock_short(o[2]) == "pll_hdmi"]
        if hdmi:
            h = min(hdmi, key=lambda o: o[0])
            out["hdmi_setup"] = h[0]
            if h[1] is not None:
                out["hdmi_tns"] = h[1]
    return out


def sdram_io_numbers(text: str) -> dict:
    """{sdram_<group>, sdram_io_min, sdram_io_worst, sdram_io_corners} from sdram_io.txt.

    Each group's value is its worst slack over every corner the file lists. A group with no
    path at any corner (`na`) is left out; sdram_io_min is then over the groups that exist, and is
    absent when no group has a number (a script that ran but timed nothing is not a margin).
    """
    corners: dict = {}
    for line in text.splitlines():
        fields = dict(f.split("=", 1) for f in line.split() if "=" in f)
        name = fields.pop("corner", None)
        if not name:
            continue
        row = {}
        for g in SDRAM_IO_GROUPS:
            try:
                row[g] = float(fields.get(g, "na"))
            except ValueError:
                pass
        corners[name] = row
    out: dict = {}
    if not corners:
        return out
    out["sdram_io_corners"] = corners
    worst: list[tuple[float, str]] = []
    for g in SDRAM_IO_GROUPS:
        vals = [(row[g], c) for c, row in corners.items() if g in row]
        if vals:
            v, c = min(vals)
            out[f"sdram_{g}"] = v
            worst.append((v, f"{g}@{c}"))
    if worst:
        v, where = min(worst)
        out["sdram_io_min"] = v
        out["sdram_io_worst"] = where
    return out


def elapsed_minutes(flow_rpt: str) -> dict:
    out = {}
    for label, key in (("Analysis & Synthesis", "map_min"), ("Fitter", "fit_min"),
                       ("TimeQuest Timing Analyzer", "sta_min")):
        m = re.search(rf";\s*{re.escape(label)}\s*;\s*(\d+):(\d+):(\d+)\s*;", flow_rpt)
        if m:
            h, mi, s = (int(x) for x in m.groups())
            out[key] = round(h * 60 + mi + s / 60, 1)
    return out


def log_numbers(log: str) -> dict:
    out: dict = {}
    errors = []
    stage = ""
    first_stage = ""
    for line in log.splitlines():
        sm = STAGE_RE.search(line)
        if sm:
            stage = sm.group(1).strip()
        em = INTERNAL_RE.search(line)
        fm = FATAL_RE.search(line)
        if em or fm:
            sig = (f"{em.group(1)} {em.group(2).rsplit('/', 1)[-1]}:{em.group(3)}" if em
                   else f"FATAL {fm.group(1).strip()}")
            if sig not in errors:
                errors.append(sig)
            if not first_stage:
                first_stage = stage
    out["internal_errors"] = errors
    if first_stage:
        out["crash_stage"] = first_stage
    # tools/build.py's DTM fallback: its banner (a detached build's log) or its own command, a
    # quartus_fit that reads the qsf (the flow's runs with --read_settings_files=off).
    out["dtm_fallback"] = ("re-fitting the mapped database" in log
                           or re.search(r"^\$ .*quartus_fit z486_mister -c z486_mister\s*$", log,
                                        re.MULTILINE) is not None)
    return out


def fit_metrics(seed_dir: Path) -> dict:
    """The metrics of one fit; seed_dir holds output_files/ (and usually build.log)."""
    seed_dir = Path(seed_dir)
    of = seed_dir / "output_files" if (seed_dir / "output_files").is_dir() else seed_dir
    out: dict = {"rbf": (of / f"{PROJECT}.rbf").exists()}
    if (sta := _read(of / f"{PROJECT}.sta.summary")):
        out.update(sta_numbers(sta))
    if (fit := _read(of / f"{PROJECT}.fit.summary")):
        m = re.search(r"Logic utilization \(in ALMs\)\s*:\s*([\d,]+)", fit)
        if m:
            out["alms_needed"] = int(m.group(1).replace(",", ""))
        m = re.search(r"Total registers\s*:\s*([\d,]+)", fit)
        if m:
            out["registers"] = int(m.group(1).replace(",", ""))
    rpt = of / f"{PROJECT}.fit.rpt"
    if rpt.exists():
        with rpt.open(errors="replace") as handle:
            for line in handle:
                if "Total LABs:  partially or completely used" in line and "labs" not in out:
                    m = re.search(r";\s*([\d,]+)\s*/\s*([\d,]+)", line)
                    if m:
                        out["labs"] = int(m.group(1).replace(",", ""))
                elif "Peak interconnect usage (total/H/V)" in line and "interconnect" not in out:
                    m = re.search(r";\s*([\d.]+)%", line)
                    if m:
                        out["interconnect"] = float(m.group(1))
    # The A&S estimate: a function of the source alone (identical over seeds), so the part of an
    # area delta a change owns; alms_needed - map_alms is the fitter's own growth (tools/fit_area.py).
    mrpt = of / f"{PROJECT}.map.rpt"
    if mrpt.exists():
        with mrpt.open(errors="replace") as handle:
            for line in handle:
                if line.startswith("; Estimate of Logic utilization (ALMs needed)"):
                    m = re.search(r";\s*([\d,]+)\s*;", line[46:])
                    if m:
                        out["map_alms"] = int(m.group(1).replace(",", ""))
                    break
    if (sio := _read(of / SDRAM_IO_FILE)):
        out.update(sdram_io_numbers(sio))
    if (flow := _read(of / f"{PROJECT}.flow.rpt")):
        out.update(elapsed_minutes(flow))
    for name in ("build.log", "build.attempt1.log"):
        if (log := _read(seed_dir / name)):
            out.update(log_numbers(log))
            break
    return out


def write_artifact(out_dir: Path, seed: int | None = None) -> Path | None:
    """Write ARTIFACT beside the fit's RBF: the seed and the pll_hdmi margin the RBF was drawn at.

    The attribution (`fit-source.sha256`) is written BEFORE the fit and describes the SOURCE;
    this file is written AFTER it and describes the PLACEMENT. tools/mister_load.sh reads it so a
    seed that wedges the scaler cannot be deployed by accident. Nothing is written when the fit
    produced no STA summary to read (a failed fit): absent is honest, a made-up zero is not.
    """
    out_dir = Path(out_dir)
    numbers = fit_metrics(out_dir)
    if not any(k in numbers for k in ("other_setup", "hdmi_setup")):
        return None
    rec: dict = {"rbf": f"{PROJECT}.rbf", "sta_summary": f"{PROJECT}.sta.summary"}
    if seed is not None:
        rec["seed"] = seed
    rbf = out_dir / f"{PROJECT}.rbf"
    if rbf.exists():
        rec["rbf_sha256"] = hashlib.sha256(rbf.read_bytes()).hexdigest()
    for k in TIMING_KEYS:
        if k in numbers:
            rec[k] = numbers[k]
    path = out_dir / ARTIFACT
    path.write_text(json.dumps(rec, indent=1, sort_keys=True) + "\n")
    return path


def main(argv: list[str]) -> int:
    if argv[:1] == ["--print-hdmi-floor"]:
        print(f"{HDMI_FLOOR:g}")
        return 0
    if argv[:1] == ["--write-artifact"]:
        ap = argparse.ArgumentParser(prog="tools/fit_metrics.py --write-artifact",
                                     description=write_artifact.__doc__)
        ap.add_argument("out_dir", help="the fit's output_files directory")
        ap.add_argument("--seed", type=int, default=None)
        a = ap.parse_args(argv[1:])
        path = write_artifact(Path(a.out_dir), a.seed)
        if path is None:
            print(f"no STA summary in {a.out_dir}: no {ARTIFACT} written", file=sys.stderr)
            return 1
        print(f"wrote {path}")
        return 0
    if not argv:
        print(__doc__)
        return 2
    for d in argv:
        print(json.dumps({"dir": d, **fit_metrics(Path(d))}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Build the PC-9821 RBF, in the Quartus container, with one reliable success signal.

This replaces tools/container_build.sh (still present as a shim). The shell script was
not wrong about the fit; it was wrong about being a shell, and each of the three
incidents the tooling round was asked to fix shows up here:

  * THE BUILD MUST OUTLIVE ITS LAUNCHER. A fit ran under a launcher that was killed
    (a timed-out parent process), the SIGHUP reached the `podman run` child, and the
    artifacts were lost with the scratch. Here every long-running child is started
    with start_new_session=True, and `--detach` re-execs this whole program in its own
    session so even the copy-back and the status write happen with no launcher alive.

  * THE BUILD MUST SAY WHETHER IT SUCCEEDED, ONCE, RELIABLY. The old flow hid errors
    in `>/dev/null` and left callers to invent `sleep N; tail log` polling. This prints
    exactly one verdict line -- `BUILD: PASS` or `BUILD: FAIL <why>` -- exits 0/1, and
    records the same verdict in .build/quartus.status.json, which `tools/wait_build.py`
    reads. The RBF's existence is checked in the same place, so "the fit exited 0 but
    no artifact was copied back" is a FAIL, not a silence.

  * NOTHING IS DISCARDED. No step's output is redirected to /dev/null, and every
    external command is run through tools/proc.py, which streams to the terminal and
    to a log at once.

Usage:
  tools/build.py                      # fit this tree, stream the output, exit on verdict
  tools/build.py --seed 7             # pin the fitter seed
  tools/build.py --fit-settings s.qsf # append a qsf snippet of fitter settings
  tools/build.py --detach             # start it in its own session, return at once
  tools/wait_build.py                 # then block for the verdict (exit 0/1)
  tools/build.py --dry-run            # print every command, run none
  tools/build.py --profile mediumoc --trace          # apply a configuration, then build
  tools/build.py --profile-file sweep.toml           # (any build_profile.py override)

Environment (unchanged from container_build.sh): QUARTUS_IMAGE, CONTAINER_RUNTIME,
QUARTUS_NICE (the fit's CPU niceness, default 19 with idle I/O; 0 = normal priority), QUARTUS_SCRATCH, QUARTUS_SEED, QUARTUS_AGGRESSIVE, QUARTUS_FIT_SETTINGS, and
QUARTUS_POST_STA_TCL: a quartus_sta Tcl script run against the fitted database after a
successful flow, its output saved as output_files/post_sta.txt (tools/timing/sdram_io.tcl, the
SDRAM pin interface at every corner into output_files/sdram_io.txt, runs after EVERY successful
flow regardless) - so a seed sweep (which deletes
each seed's tree) keeps the path detail the stock sta.rpt does not carry.

The fitter-settings snippet is how a settings experiment reaches the scratch qsf without
editing the tracked one: --fit-settings FILE (or QUARTUS_FIT_SETTINGS=FILE) appends the
file's `set_*_assignment` lines after the profile block, so the last assignment wins. The
snippet is validated before the fit -- Quartus silently ignores an invalid assignment, and
a fit that never took effect would read as "this setting does nothing".
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import build_profile  # noqa: E402  (the configuration overrides, shared with seed_sweep.py)
from proc import (  # noqa: E402
    REPO_ROOT,
    TOOLS_DIR,
    eprint,
    have,
    quote,
    run_detached,
    stream,
    tree_tag,
)

DRY = False
TEE_LOG: Path | None = None
STATUS_JSON = REPO_ROOT / ".build" / "quartus.status.json"
DEFAULT_LOG = REPO_ROOT / ".build" / "quartus.log"

# The summary lines a human wants from a fit log. Kept as one list so the status file
# and the terminal report cannot disagree about what "the result" is.
SUMMARY = re.compile(
    r"Full Compilation was successful|Logic utilization|Total registers|"
    r"Total RAM Blocks|Total block memory bits|Total DSP Blocks|"
    r"Error \(23031\)|Internal Error"
)

# One line of a fitter-settings snippet: a global or instance assignment. The value may
# contain spaces (Quartus quotes those), so only the assignment name is matched strictly.
FIT_SETTING = re.compile(r"^set_(?:global|instance)_assignment\s+-name\s+\S+\s+\S")


def _now() -> float:
    return time.time()


def _stamp(epoch: float) -> str:
    return datetime.datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M:%S")


def run(argv, *, log: Path | None = None, new_session: bool = False) -> tuple[int, str]:
    """Run argv, or print it under --dry-run. One choke point, so no step can hide."""
    argv = [str(a) for a in argv]
    if DRY:
        print("  would run: " + quote(argv), flush=True)
        return 0, ""
    # Every step tees to the same --log, so it APPENDS: opened "w" per step, the log ended up
    # holding only the last step (the copy-back rsync), and a seed sweep's kept build.log lost
    # the Quartus output - the internal errors included. main() truncates it once.
    if log is None and TEE_LOG is not None:
        return stream(argv, log=TEE_LOG, new_session=new_session, append=True)
    return stream(argv, log=log, new_session=new_session)


class Build:
    def __init__(self, opts) -> None:
        self.opts = opts
        env = os.environ.copy()
        self.env = env
        self.runtime = env.get("CONTAINER_RUNTIME", "podman")
        self.image = env.get("QUARTUS_IMAGE", "docker.io/raetro/quartus:mister")
        # A fit is batch work on a shared machine: the container runs at the lowest CPU priority
        # and idle I/O class, so an interactive or other workload on the same host goes first.
        # Niceness is inherited across fork, and podman forks conmon and the container from this
        # client, so the whole fit runs at it. Under CONTAINER_RUNTIME=docker it does NOT: the
        # docker daemon starts the container, so nice/ionice reach only the client; set the
        # priority on the daemon's side there. QUARTUS_NICE=0 runs at normal priority.
        self.nice = int(env.get("QUARTUS_NICE", "19") or 0)
        self.project = opts.project
        self.scratch = Path(env.get("QUARTUS_SCRATCH") or (REPO_ROOT / ".build" / "quartus"))
        self.seed = opts.seed
        if self.seed is None and env.get("QUARTUS_SEED", "").strip():
            self.seed = int(env["QUARTUS_SEED"])
        self.fit_settings = opts.fit_settings
        if self.fit_settings is None and env.get("QUARTUS_FIT_SETTINGS", "").strip():
            self.fit_settings = Path(env["QUARTUS_FIT_SETTINGS"])
        self.log = opts.log or DEFAULT_LOG
        self.started = _now()
        self.exit = 1
        self.state = "running"
        self.rbf: Path | None = None
        self.digest = ""

    # --- the status record, written by whatever process owns the build ----------

    def write_status(self, state: str, exit_code: int | None = None) -> None:
        self.state = state
        if exit_code is not None:
            self.exit = exit_code
        if DRY:
            return
        record = {
            "state": state,
            "pid": os.getpid(),
            "project": self.project,
            "seed": self.seed,
            "tree": str(REPO_ROOT),
            "scratch": str(self.scratch),
            "log": str(self.log),
            "started": self.started,
            "started_at": _stamp(self.started),
            "ended": _now() if state != "running" else None,
            "exit": exit_code,
            "rbf": str(self.rbf) if self.rbf else None,
            "sha256": self.digest or None,
        }
        _atomic_json(STATUS_JSON, record)
        if self.opts.status_file:
            self._write_status_file()

    def _write_status_file(self) -> None:
        """The per-seed human-readable file the sweep collects, and its summary."""
        assert self.opts.status_file
        lines = [
            f"STATE={self.state}",
            f"FIT_EXIT={self.exit}",
            f"SEED={self.seed}",
            f"FIT_SETTINGS={self.fit_settings or ''}",
            f"PROJECT={self.project}",
            f"DURATION_S={_now() - self.started:.1f}",
            f"RBF={self.rbf or ''}",
            f"SHA256={self.digest or ''}",
            f"LOG={self.log}",
        ]
        summary = summarize(self.log)
        if summary:
            lines.append("--- summary ---")
            lines.extend(summary)
        target = Path(self.opts.status_file)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("\n".join(lines) + "\n")

    def fail(self, message: str, code: int = 1):
        eprint(f"BUILD: FAIL - {message}")
        eprint(f"  log: {self.log}")
        self.write_status("failed", code)
        raise SystemExit(code)

    def ok(self) -> int:
        if DRY:
            print("BUILD: DRY-RUN (no fit was run, so nothing was verified)")
            return 0
        print()
        print(f"RBF: {self.rbf}")
        print(f"sha256 {self.digest}")
        print(f"BUILD: PASS ({_now() - self.started:.0f}s)")
        self.write_status("passed", 0)
        return 0

    # --- the steps --------------------------------------------------------------

    def step(self, argv, what: str, *, new_session: bool = False) -> None:
        code, _ = run(argv, new_session=new_session)
        if code != 0:
            self.fail(f"{what} failed (exit {code})")

    def capture(self, argv, what: str) -> str:
        argv = [str(a) for a in argv]
        if DRY:
            print("  would run: " + quote(argv), flush=True)
            return ""
        code, out = stream(argv)
        if code != 0:
            self.fail(f"{what} failed (exit {code})")
        return out

    def apply_fit_settings(self, qsf: Path) -> None:
        """Append the opt-in fitter-settings snippet to the scratch qsf.

        The snippet lets a settings experiment be attributed to the settings and nothing
        else: the tracked qsf is untouched, and QUARTUS_FIT_SETTINGS is inherited by every
        child a sweep launches, so all of a variant's seeds carry the same lines.
        """
        if not self.fit_settings:
            return
        path = Path(self.fit_settings)
        try:
            lines = parse_fit_settings(path)
        except (OSError, ValueError) as exc:
            self.fail(str(exc))
        print(f"==> fitter settings: {path} ({len(lines)} assignment(s))")
        for line in lines:
            print(f"      {line}")
        if DRY:
            return
        with qsf.open("a") as handle:
            handle.write(f"\n# --- fitter settings ({path.name}) ---\n")
            for line in lines:
                handle.write(line + "\n")

    def run(self) -> int:
        opts = self.opts
        if not DRY and not have(self.runtime):
            self.fail(
                f"container runtime '{self.runtime}' not found "
                "(set CONTAINER_RUNTIME=docker?)"
            )

        self.write_status("running")
        print(f"==> tree:    {REPO_ROOT}")
        print(f"==> image:   {self.image}")
        print(f"==> project: {self.project} (scratch: {self.scratch})")
        print(f"==> started: {_stamp(self.started)}")

        # Fresh scratch copy: no .git (Quartus demands write access to every file it
        # sees and the git objects are read-only) and no previous build state. src/z486
        # is vendored with the local patch already applied, so there is nothing to apply.
        if not DRY:
            shutil.rmtree(self.scratch, ignore_errors=True)
            self.scratch.mkdir(parents=True, exist_ok=True)
        self.step(
            [
                "rsync", "-a",
                "--exclude=.git", "--exclude=db", "--exclude=incremental_db",
                "--exclude=output_files", "--exclude=mister_deploy", "--exclude=.build",
                # Verilator's per-bench build tree: generated, gitignored, and tens of GB. The fit
                # reads none of it, and copying it made every build slow and, when two builds
                # overlapped, fatal (the other build's rmtree pulls the directories out from under
                # this rsync: "mkstemp ... No such file or directory").
                "--exclude=tests/pc9821/build",
                f"{REPO_ROOT}/", f"{self.scratch}/",
            ],
            "copy the tree into the scratch",
        )

        # The main PLL (rtl/pll*) and the constraints (z486_mister.sdc) are GENERATED and
        # git-ignored, so a fresh checkout has neither: generate the RECORDED configuration's
        # pair into the scratch (cached, read back and verified - tools/profile_gen.py), then
        # --check the scratch itself, so the fit cannot start unless its top level, qsf
        # record, PLL and SDC all describe the same build.
        self.step(
            [sys.executable, str(REPO_ROOT / "build_profile.py"), "--pll-into", str(self.scratch)],
            "generate the active configuration's PLL and SDC",
        )
        self.step(
            [sys.executable, str(REPO_ROOT / "build_profile.py"), "--check",
             "--tree", str(self.scratch), "--require-generated"],
            "the profile agreement check",
        )

        qsf = self.scratch / f"{self.project}.qsf"
        if self.seed is not None:
            print(f"==> fitter seed: {self.seed}")
            if not DRY:
                with qsf.open("a") as handle:
                    handle.write(f"\nset_global_assignment -name SEED {self.seed}\n")
        if self.env.get("QUARTUS_AGGRESSIVE", "0") == "1":
            print("==> aggressive routability optimization: on")
            if not DRY:
                with qsf.open("a") as handle:
                    handle.write(
                        "set_global_assignment -name "
                        "FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION ALWAYS\n"
                    )
        self.apply_fit_settings(qsf)
        # QUARTUS_NUM_PARALLEL_PROCESSORS: how many threads Quartus may use (the qsf says ALL).
        # Execution, not configuration - Quartus documents parallel compilation as
        # deterministic - but the post-fit CUT / DYN_ENUM internal errors report "Processors in
        # use: 16" and pass on a retry, so the thread count is a variable worth controlling.
        npp = self.env.get("QUARTUS_NUM_PARALLEL_PROCESSORS", "").strip()
        if npp and not DRY:
            if not re.fullmatch(r"ALL|[1-9][0-9]*", npp):
                self.fail(f"QUARTUS_NUM_PARALLEL_PROCESSORS={npp!r}: ALL or a positive integer")
            text, n = re.subn(r"(?m)^set_global_assignment -name NUM_PARALLEL_PROCESSORS .*$",
                              f"set_global_assignment -name NUM_PARALLEL_PROCESSORS {npp}",
                              qsf.read_text())
            if n != 1:
                self.fail("the scratch qsf has no single NUM_PARALLEL_PROCESSORS line to set")
            qsf.write_text(text)
            print(f"==> NUM_PARALLEL_PROCESSORS {npp}")

        tree_before = self.capture(
            [sys.executable, str(TOOLS_DIR / "check_fit.py"), "--rtl-hash-of", str(REPO_ROOT)],
            "the pre-fit rtl tree hash",
        ).strip()
        print(f"==> rtl tree hash: {tree_before}")

        # Record which tree this fit is of, beside the reports, BEFORE the fit and the
        # copy-back, so both carry it and check_fit.py can refuse to give a verdict for
        # a fit it cannot attribute. Without it a never-built checkout reports PASS for
        # whatever fit happens to sit in its scratch.
        self.step(
            [
                sys.executable, str(TOOLS_DIR / "check_fit.py"), "--write-attribution",
                str(self.scratch / "output_files"), "--tree", str(REPO_ROOT),
                "--rtl-hash", tree_before,
            ],
            "write the fit attribution",
        )

        # The fit itself. new_session=True: a SIGHUP aimed at this program's process
        # group does not reach the container, so a killed launcher cannot take a running
        # fit down with it mid-build.
        container = f"pc9821-{self.seed}-{tree_tag(REPO_ROOT)}" if self.seed is not None else f"pc9821-{tree_tag(REPO_ROOT)}"
        # A killed podman CLI can leave its container behind; remove a stale one so the
        # --name below cannot collide. The rm's exit is irrelevant (missing is fine).
        run([self.runtime, "rm", "-f", container])

        def in_container(*cmd: str) -> int:
            code, out = run(
                [
                    *(["nice", "-n", str(self.nice), "ionice", "-c", "3"] if self.nice else []),
                    self.runtime, "run", "--rm", "--name", container,
                    "-e", "HOME=/tmp",
                    "-v", f"{self.scratch}:/work",
                    "-w", "/work",
                    self.image,
                    *cmd,
                ],
                new_session=True,
            )
            in_container.out = out
            return code

        fit_code = in_container("/opt/intelFPGA/quartus/bin/quartus_sh", "--flow", "compile",
                                self.project)
        # THE QUARTUS 17.0.2 DTM CRASH. The flow runs
        # quartus_fit with --read_settings_files=off (the settings as quartus_map stored them in
        # the database); on some netlists that fitter dies at the start of physical synthesis
        # with `Internal Error: Sub-system: DTM, ... dtm_node.cpp, Line: 772`, every attempt.
        # The SAME mapped database fitted by quartus_fit reading its settings from the qsf
        # (the default --read_settings_files=on) does not crash, and on a netlist where both
        # work the two fits are identical (every resource table and the pin file). So the map is
        # kept and the fit, the assembler and STA are re-run that way, exactly as the flow would
        # have run them otherwise. QUARTUS_DTM_RETRY=0 turns this off.
        if (fit_code != 0 and not DRY
                and "Internal Error: Sub-system: DTM" in (getattr(in_container, "out", "") or "")
                and self.env.get("QUARTUS_DTM_RETRY", "1") != "0"):
            print("==> the fitter hit the Quartus DTM internal error; re-fitting the mapped "
                  "database with quartus_fit reading the qsf (--read_settings_files=on)")
            run([self.runtime, "rm", "-f", container])
            q = "/opt/intelFPGA/quartus/bin/"
            fit_code = (in_container(q + "quartus_fit", self.project, "-c", self.project)
                        or in_container(q + "quartus_asm", "--read_settings_files=off",
                                        "--write_settings_files=off", self.project,
                                        "-c", self.project)
                        or in_container(q + "quartus_sta", self.project, "-c", self.project))
            if fit_code == 0:
                print("==> DTM fallback: fit, assembler and STA completed")

        # The SDRAM pin interface at EVERY corner (tools/timing/sdram_io.tcl), always: the flow's
        # STA summary is the slow corner's output paths only, and the read capture's window binds
        # at the fast corner, so without this no fit records half of the window the deploy gate
        # (seed_sweep.py --min-sdram-io) reads. Its failure is reported, never a build failure:
        # the gate then sees no record, which it treats as not deployable.
        if fit_code == 0 and not DRY:
            shutil.copy2(TOOLS_DIR / "timing" / "sdram_io.tcl", self.scratch / "sdram_io.tcl")
            run([self.runtime, "rm", "-f", container])
            code = in_container("bash", "-lc",
                                "/opt/intelFPGA/quartus/bin/quartus_sta -t sdram_io.tcl "
                                "> output_files/sdram_io.log 2>&1")
            print(f"==> SDRAM I/O corner STA: exit {code} (output_files/sdram_io.txt)")

        # The opt-in path report (QUARTUS_POST_STA_TCL): run while the database still exists,
        # into output_files so the copy below (and a sweep's per-seed copy) keeps it. Its
        # failure is reported but never fails the build - the fit's own verdict stands.
        post_tcl = self.env.get("QUARTUS_POST_STA_TCL", "").strip()
        if fit_code == 0 and post_tcl and not DRY:
            shutil.copy2(post_tcl, self.scratch / "post_sta.tcl")
            run([self.runtime, "rm", "-f", container])
            code = in_container("bash", "-lc",
                                "/opt/intelFPGA/quartus/bin/quartus_sta -t post_sta.tcl "
                                "> output_files/post_sta.txt 2>&1")
            print(f"==> post-fit STA script {post_tcl}: exit {code} (output_files/post_sta.txt)")

        # Bring the artifacts back REGARDLESS of pass/fail, so a failed seed's partial
        # output_files (fit reports + any produced files) survives for inspection. A silent
        # copy is how a build can report success while the artifact never left the scratch
        # tree, so the copy's exit matters.
        out = REPO_ROOT / "output_files"
        if not DRY:
            out.mkdir(parents=True, exist_ok=True)
        self.step(
            ["rsync", "-a", f"{self.scratch}/output_files/", f"{out}/"],
            "copy the artifacts back",
        )

        if fit_code != 0:
            self.fail(f"the Quartus fit failed (exit {fit_code})")

        # THE SUCCESS SIGNAL. quartz_sh can exit 0 with no bitstream; the artifact's
        # existence is the thing that decides.
        self.rbf = out / f"{self.project}.rbf"
        if not DRY:
            if not self.rbf.exists():
                self.fail(f"{self.rbf} was not produced")
            self.digest = _sha256(self.rbf)
            # Which register drives each SDRAM pin is decided by the fitter and invisible to every
            # simulation (a build whose DQ output enable came from a DDIO_OE atom passed them all
            # and was black on hardware): the fit's own pin tables must name the intended ones.
            self.step(
                [sys.executable, str(TOOLS_DIR / "check_sdram_pins.py"), "--reports", str(out),
                 "--project", self.project],
                "check the SDRAM pins' output and output-enable registers",
            )
            # The placement's own record, beside the RBF: which seed drew it and the pll_hdmi
            # margin it drew. fit-source.sha256 above describes the SOURCE and is written before
            # the fit; this is what tools/mister_load.sh gates the deploy on.
            self.step(
                [sys.executable, str(TOOLS_DIR / "fit_metrics.py"), "--write-artifact", str(out),
                 *(["--seed", str(self.seed)] if self.seed is not None else [])],
                "write the artifact timing record",
            )

        tree_after = self.capture(
            [sys.executable, str(TOOLS_DIR / "check_fit.py"), "--rtl-hash-of", str(REPO_ROOT)],
            "the post-fit rtl tree hash",
        ).strip()
        if not DRY and tree_after != tree_before:
            eprint(
                f"WARNING: the RTL tree changed during the build "
                f"({tree_before} -> {tree_after}). The build used a frozen copy, so this "
                f"RBF is already stale."
            )
        elif not DRY:
            print(f"==> rtl tree unchanged ({tree_after}): this RBF matches the tree")

        return self.ok()


def parse_fit_settings(path: Path) -> list[str]:
    """The assignment lines of a fitter-settings snippet, or a refusal that names the line.

    Quartus silently ignores an invalid assignment name or value, so a typo would fit with
    the setting absent and the run would read as "this setting does nothing". Refusing here
    turns that into a failed build before the 25-minute fit is spent.
    """
    text = Path(path).read_text()
    lines: list[str] = []
    for n, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not FIT_SETTING.match(stripped):
            raise ValueError(
                f"{path}:{n}: not a `set_global_assignment -name NAME VALUE` line: "
                f"{stripped!r}"
            )
        lines.append(stripped)
    return lines


def summarize(log: Path, limit: int = 12) -> list[str]:
    if DRY or not Path(log).exists():
        return []
    hits = [line.rstrip("\n") for line in Path(log).read_text(errors="replace").splitlines()
            if SUMMARY.search(line)]
    return hits[-limit:]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _atomic_json(path: Path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(record, indent=2) + "\n")
    os.replace(tmp, path)


def apply_profile_args(opts) -> None:
    """--profile / the configuration overrides: apply them to THIS tree, as build_profile.py would.

    The configuration is tree state (the top level's localparams and the qsf record are
    tracked and hashed into the fit's attribution), so it is applied to the working tree and
    not to the scratch alone - otherwise the attribution would describe a different build.
    It runs once, before any detach, so a bad override fails here and not in the child.
    """
    argv = ([opts.profile] if opts.profile else []) + build_profile.override_argv(opts)
    if not argv:
        return
    cmd = [sys.executable, str(REPO_ROOT / "build_profile.py"), *argv]
    print("==> configuration: " + quote(cmd), flush=True)
    if DRY:
        return
    code, _ = stream(cmd)
    if code != 0:
        eprint(f"BUILD: FAIL - build_profile.py {' '.join(argv)} failed (exit {code})")
        raise SystemExit(1)


def running_build(status_json: Path = STATUS_JSON) -> int | None:
    """The pid of a LIVE build already recorded in this tree's status file, else None.

    Two builds of one tree share the scratch (`.build/quartus` is wiped at the start of every
    build) and the status file, so the second one corrupts the first's fit. A recorded
    `running` whose pid is dead is a crashed build and is ignored.
    """
    try:
        rec = json.loads(Path(status_json).read_text())
    except (OSError, ValueError):
        return None
    pid = rec.get("pid")
    if rec.get("state") != "running" or not isinstance(pid, int) or pid == os.getpid():
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except PermissionError:
        return pid
    try:
        with open(f"/proc/{pid}/stat") as h:
            if h.read().split(") ", 1)[1][0] == "Z":
                return None
    except (OSError, IndexError):
        pass
    return pid


def launch_detached(opts) -> int:
    """Re-exec this program in its own session; return as soon as it has started."""
    log = Path(opts.log) if opts.log else DEFAULT_LOG
    child = [sys.executable, str(Path(__file__).resolve()), "--child", "--log", str(log)]
    if opts.seed is not None:
        child += ["--seed", str(opts.seed)]
    if opts.fit_settings is not None:
        child += ["--fit-settings", str(opts.fit_settings)]
    if opts.project != "z486_mister":
        child += ["--project", opts.project]
    if opts.status_file:
        child += ["--status-file", str(Path(opts.status_file).resolve())]

    proc = run_detached(child, log=log, cwd=REPO_ROOT)
    print(f"BUILD: launched pid {proc.pid} (own session; a SIGHUP to this shell cannot kill it)")
    print(f"  log    : {log}")
    print(f"  status : {STATUS_JSON}")
    print(f"  wait   : tools/wait_build.py   (exit 0 = pass, 1 = fail)")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build the RBF in the Quartus container; exit 0 only if the artifact exists.",
    )
    parser.add_argument("--seed", type=int, help="pin the Quartus fitter seed")
    parser.add_argument("--fit-settings", type=Path,
                        help="a qsf snippet of set_*_assignment lines appended to the "
                             "scratch qsf (or set QUARTUS_FIT_SETTINGS)")
    parser.add_argument("--project", default="z486_mister", help="Quartus revision to compile")
    parser.add_argument("--detach", action="store_true",
                        help="start the build in its own session and return immediately; "
                             "the verdict is then read with tools/wait_build.py")
    parser.add_argument("--child", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--log", type=Path, help="where the build's output is logged")
    parser.add_argument("--status-file", type=Path,
                        help="also write a human-readable status file (the sweep's per-seed file)")
    parser.add_argument("--dry-run", action="store_true",
                        help="print every command that would run, and run none")
    parser.add_argument("--profile", choices=sorted(build_profile.PROFILES),
                        help="apply this preset (build_profile.py <preset>) before building")
    build_profile.add_override_args(parser)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    global DRY, TEE_LOG
    opts = parse_args(argv)
    DRY = opts.dry_run
    if not opts.child:
        apply_profile_args(opts)
    if not DRY and not opts.child:
        other = running_build()
        if other:
            eprint(f"BUILD: FAIL - a build of this tree is already running (pid {other}, "
                   f"{STATUS_JSON}); it owns {REPO_ROOT / '.build' / 'quartus'}. Wait for it "
                   f"(tools/wait_build.py) or fit from another tree (tools/seed_sweep.py).")
            return 1
    if opts.detach and not opts.child and not DRY:
        return launch_detached(opts)
    # In sync mode a --log is tee'd to; the detached child's stdout is already the log,
    # so it must not open the same file again and truncate what it is writing.
    TEE_LOG = opts.log if (opts.log and not opts.child) else None
    if TEE_LOG is not None and not DRY:
        Path(TEE_LOG).parent.mkdir(parents=True, exist_ok=True)
        Path(TEE_LOG).write_text("")
    return Build(opts).run()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

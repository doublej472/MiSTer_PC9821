#!/usr/bin/env python3
"""Run a Quartus seed sweep on another machine and bring EVERY result back.

    export FIT_HOST=builder                       # or --host; any ssh destination, keys only
    tools/remote_fit.py run --label myfix -- --profile base --seeds 2,3 --jobs 2
    tools/remote_fit.py status                    # the last run (or --run-id ID)
    tools/remote_fit.py fetch                     # copy every seedNNN back (idempotent)
    tools/remote_fit.py report                    # fetch, then tools/seed_sweep.py --report on it
    tools/remote_fit.py list                      # the runs this checkout has launched
    tools/remote_fit.py --selftest

What `run` does, in order:
  1. SNAPSHOT: the working tree = every tracked file as it is on disk now (uncommitted edits
     included, files deleted on disk left out) plus untracked, not-ignored files under
     --untracked-max-kb (default 1024; bigger ones are listed and skipped). It is rsync'd to
     <remote-dir>/<run-id>/tree on the host. A run's tree is its own: a later run never changes
     it, so a sweep that is still fitting cannot have its source swapped under it.
  2. LAUNCH: tools/seed_sweep.py is started there in its own session (survives this launcher
     and the ssh connection), with --dir <run>/sweep and a host_slots ceiling: every seed holds
     one slot of --slot-dir (default ~/.fit-slots on the host, shared by every user of this
     tool) while it fits, the ceiling is --slot-max (env FIT_SLOT_MAX, default 12), and
     --slot-all (default on) also counts containers other launchers started, so a busy shared
     machine is never pushed over its ceiling. --max-load waits while the host is loaded.
  3. WAIT (unless --no-wait), then FETCH: rsync of <run>/sweep back to
     <local-dir> (default .build/remote-fit/<run-id>): every seedNNN/ with its output_files,
     summary.txt, metrics.json and logs, plus the sweep log. A fetch FAILS when rsync reports a
     partial transfer (exit 23; 24, files vanished, is tolerated) or when a seed whose summary
     says verdict=passed came back without output_files/*.rbf or output_files/sdram_io.txt, so a
     report never ranks a seed it could not deploy. Nothing is ever deleted, locally or
     on the host: the remote tree and sweep stay until you remove them by hand (an
     output_files is that placement's only record).

Resuming: `run --run-id ID` re-pushes the source into the same run and starts the sweep again;
seed_sweep refuses to mix fits of different source (its identity check), so a changed tree needs
--restart-stale (passed through after `--`) or a new run id. The host needs python3, rsync and
the container runtime (CONTAINER_RUNTIME, passed with --remote-env CONTAINER_RUNTIME=docker).
The sweep arguments after `--` are seed_sweep.py's own (--dir is ours and refused).

REMOTE AND LOCAL ARE JUDGED THE SAME WAY. The pll_hdmi deploy gate is forwarded to the sweep on
the host AND applied to the report fetched back here, and this tool exits nonzero when either
fails: `--min-other-setup NS` (the floor; seed_sweep's default is -0.35 ns, `none` disables),
`--min-positive` (only seeds with pll_hdmi > 0 ns), `--min-seeds N` (refuse a verdict from
fewer than N measured seeds) and `--min-sdram-io NS` (the SDRAM pin interface's worst slack over
every corner; seed_sweep's default is 0 ns, `none` disables). Both `run` and `report` take them.
"""
from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RUNS_DIR = REPO / ".build" / "remote-fit"
SSH_BASE = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=30"]


def sh(argv, **kw) -> subprocess.CompletedProcess:
    return subprocess.run([str(a) for a in argv], text=True, **kw)


class Remote:
    def __init__(self, host: str, ssh_opts: list[str] | None = None):
        self.host = host
        self.opts = SSH_BASE + (ssh_opts or [])

    def ssh_argv(self, *cmd: str) -> list[str]:
        return ["ssh", *self.opts, self.host, *cmd]

    def run(self, script: str, check: bool = True) -> subprocess.CompletedProcess:
        """Run a shell script on the host (fed on stdin, so no quoting layers)."""
        r = sh(self.ssh_argv("sh", "-s"), input=script, capture_output=True)
        if check and r.returncode != 0:
            raise SystemExit(f"remote command failed ({r.returncode}) on {self.host}:\n"
                             f"{r.stdout}{r.stderr}")
        return r

    def rsync_e(self) -> str:
        return "ssh " + " ".join(shlex.quote(o) for o in self.opts)


def snapshot_files(repo: Path, untracked_max_kb: int) -> tuple[list[str], list[str]]:
    """(files to send, untracked files skipped for size). Paths are relative to repo."""
    def ls(*flags):
        out = subprocess.run(["git", "-C", str(repo), "ls-files", "-z", *flags],
                             capture_output=True, check=True).stdout
        return [p for p in out.decode().split("\0") if p]
    tracked = ls("--cached")
    untracked = ls("--others", "--exclude-standard")
    send, skipped = [], []
    for p in tracked:
        if os.path.lexists(repo / p):          # deleted-on-disk tracked files are left out
            send.append(p)
    for p in untracked:
        fp = repo / p
        if not os.path.lexists(fp):
            continue
        if fp.is_file() and not fp.is_symlink() and fp.stat().st_size > untracked_max_kb * 1024:
            skipped.append(p)
        else:
            send.append(p)
    return sorted(set(send)), skipped


def new_run_id(label: str) -> str:
    safe = "".join(c if c.isalnum() or c in "-_" else "-" for c in label) or "run"
    return f"{safe}-{time.strftime('%Y%m%d-%H%M%S')}"


def check_sweep_args(args: list[str]) -> list[str]:
    for a in args:
        if a == "--dir" or a.startswith("--dir="):
            raise SystemExit("--dir is chosen by remote_fit (the run's own sweep directory)")
        if a in ("--report", "--selftest"):
            raise SystemExit(f"{a} is not a sweep: use `remote_fit.py report`")
    return args


def add_gate_args(p: argparse.ArgumentParser) -> None:
    """The seed_sweep.py deploy-gate flags (pll_hdmi and SDRAM I/O), on both `run` and `report`."""
    p.add_argument("--min-other-setup", default=None, metavar="NS",
                   help="forwarded to seed_sweep.py: the pll_hdmi setup-slack deploy floor "
                        "(seed_sweep's default is -0.35 ns; `none` disables it)")
    p.add_argument("--min-positive", action="store_true",
                   help="forwarded: deploy only seeds with pll_hdmi > 0 ns")
    p.add_argument("--min-seeds", type=int, default=None, metavar="N",
                   help="forwarded: require N measured seeds before a verdict (use 6)")
    p.add_argument("--min-sdram-io", default=None, metavar="NS",
                   help="forwarded: the SDRAM pin-interface deploy floor over every corner "
                        "(seed_sweep's default is 0 ns; `none` disables it)")


def gate_args(args) -> list[str]:
    """The pll_hdmi deploy-gate flags to forward to tools/seed_sweep.py.

    They are the SAME decision remotely and locally: seed_sweep's --min-other-setup floor
    (default -0.35 ns), --min-positive and --min-seeds N. Defaults here are None so an
    unset flag leaves seed_sweep's own default in force.
    """
    out: list[str] = []
    if getattr(args, "min_other_setup", None) is not None:
        out += ["--min-other-setup", str(args.min_other_setup)]
    if getattr(args, "min_positive", False):
        out.append("--min-positive")
    if getattr(args, "min_seeds", None) is not None:
        out += ["--min-seeds", str(args.min_seeds)]
    if getattr(args, "min_sdram_io", None) is not None:
        out += ["--min-sdram-io", str(args.min_sdram_io)]
    return out


def sweep_command(py: str, run_dir: str, sweep_args: list[str], slot_dir: str, slot_max: int,
                  slot_all: bool, max_load: float | None,
                  gates: list[str] | None = None) -> str:
    cmd = [py, f"{run_dir}/tree/tools/seed_sweep.py", "--dir", f"{run_dir}/sweep",
           "--slot-dir", slot_dir, "--slot-max", str(slot_max)]
    if slot_all:
        cmd.append("--slot-all")
    if max_load is not None:
        cmd += ["--max-load", str(max_load)]
    cmd += sweep_args
    cmd += gates or []
    return " ".join(shlex.quote(c) for c in cmd)


def last_run_file() -> Path:
    return RUNS_DIR / "last"


def resolve_run_id(args) -> str:
    if args.run_id:
        return args.run_id
    try:
        return last_run_file().read_text().strip()
    except OSError:
        raise SystemExit("no run id: pass --run-id (or launch one with `run`)")


def remote_paths(args, run_id: str) -> tuple[str, str]:
    base = args.remote_dir.rstrip("/")
    return base, f"{base}/{run_id}"


def cmd_run(args, rem: Remote) -> int:
    sweep_args = check_sweep_args(args.sweep_args)
    run_id = args.run_id or new_run_id(args.label)
    base, run_dir = remote_paths(args, run_id)
    files, skipped = snapshot_files(REPO, args.untracked_max_kb)
    for p in skipped:
        print(f"  skipped (untracked, over {args.untracked_max_kb} KiB): {p}")
    print(f"==> run {run_id} on {rem.host}: {len(files)} files -> {run_dir}/tree")
    # A live sweep in this run owns its tree: refuse to swap it.
    # The reply is LIVE or IDLE; anything else (ssh itself failed) must not read as "not live".
    st = rem.run(f"if cd {shlex.quote(run_dir)} 2>/dev/null && [ -f pid ] && [ ! -f exit ] && "
                 f"kill -0 $(cat pid) 2>/dev/null; then echo LIVE; else echo IDLE; fi", check=False)
    live = live_reply(st.stdout)
    if live is None:
        raise SystemExit(f"could not ask {rem.host} whether run {run_id} is live "
                         f"(ssh {st.returncode}); not touching its tree:\n{st.stderr}")
    if live:
        raise SystemExit(f"run {run_id} is still sweeping on {rem.host}; not touching its tree")
    rem.run(f"mkdir -p {shlex.quote(run_dir)} && rm -rf {shlex.quote(run_dir)}/tree.new "
            f"{shlex.quote(run_dir)}/exit")
    r = sh(["rsync", "-a", "-e", rem.rsync_e(), "--from0", "--files-from=-", f"{REPO}/",
            f"{rem.host}:{run_dir}/tree.new/"], input="\0".join(files) + "\0")
    if r.returncode != 0:
        raise SystemExit("rsync of the tree failed")
    rem.run(f"cd {shlex.quote(run_dir)} && rm -rf tree && mv tree.new tree")
    slot_dir = args.slot_dir or f"{args.remote_home}/.fit-slots"
    max_load = args.max_load
    if max_load is None:
        max_load = float(rem.run("nproc").stdout.strip() or 0)
    cmd = sweep_command(args.remote_python, run_dir, sweep_args, slot_dir, args.slot_max,
                        not args.no_slot_all, max_load or None, gate_args(args))
    env = " ".join(f"export {shlex.quote(e)};" for e in args.remote_env)
    # setsid + nohup: the sweep outlives this launcher and the ssh session. `exit` is written
    # when the sweep ends (any way but SIGKILL), so a waiter never has to guess from a pid.
    script = (f"cd {shlex.quote(run_dir)} && {env} rm -f exit && "
              f"(setsid nohup sh -c {shlex.quote(cmd + '; echo $? > exit')} > log 2>&1 < /dev/null "
              f"& echo $! > pid) && echo LAUNCHED\n")
    out = rem.run(script)
    if "LAUNCHED" not in out.stdout:
        raise SystemExit(f"launch failed: {out.stdout}{out.stderr}")
    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    last_run_file().write_text(run_id + "\n")
    with open(RUNS_DIR / "runs.txt", "a") as f:
        f.write(f"{run_id}\t{rem.host}\t{run_dir}\t{' '.join(sweep_args)}\n")
    print(f"==> launched; sweep log {run_dir}/log")
    if args.no_wait:
        print(f"    later: tools/remote_fit.py --host {rem.host} --run-id {run_id} status|fetch|report")
        return 0
    return wait_and_fetch(args, rem, run_id)


def live_reply(stdout: str) -> bool | None:
    """The pre-launch LIVE check's reply: True live, False idle, None no reply (ssh failed)."""
    first = (stdout.splitlines() or [""])[0].strip()
    return {"LIVE": True, "IDLE": False}.get(first)


UNREACHABLE = "UNREACHABLE"


def parse_status(stdout: str) -> int | None | str:
    """The status script's verdict: an exit code, None while RUNNING, -1 for DEAD or MISSING
    (a reply that says the sweep is gone), or UNREACHABLE when there is no recognised reply
    (ssh itself failed: a network blip is not a finished sweep)."""
    lines = stdout.splitlines()
    state = lines[0].strip() if lines else ""
    if state.startswith("EXIT ") and state.split()[1:2] and state.split()[1].isdigit():
        return int(state.split()[1])
    if state == "RUNNING":
        return None
    if state in ("DEAD", "MISSING"):
        return -1
    return UNREACHABLE


def status_text(args, rem: Remote, run_id: str) -> tuple[str, int | None | str]:
    _, run_dir = remote_paths(args, run_id)
    r = rem.run(
        f"cd {shlex.quote(run_dir)} || {{ echo MISSING; exit 0; }}\n"
        f"if [ -f exit ]; then echo \"EXIT $(cat exit)\"; "
        f"elif [ -f pid ] && kill -0 $(cat pid) 2>/dev/null; then echo RUNNING; "
        f"else echo DEAD; fi\n"
        f"n=$(ls -d sweep/seed[0-9][0-9][0-9] 2>/dev/null | wc -l); "
        f"d=$(ls sweep/seed[0-9][0-9][0-9]/summary.txt 2>/dev/null | wc -l); "
        f"echo \"seeds: $d done / $n started\"\n"
        f"tail -n 3 log 2>/dev/null; true\n", check=False)
    code = parse_status(r.stdout)
    if code == UNREACHABLE:
        return f"UNREACHABLE (ssh {r.returncode}) {r.stderr.strip()}\n", code
    return r.stdout, code


def cmd_status(args, rem: Remote) -> int:
    out, _ = status_text(args, rem, resolve_run_id(args))
    print(out, end="")
    return 0


# rsync exit codes a fetch accepts. 24 (source files vanished during the transfer) is the
# sweep's own scratch coming and going under the excluded seed*/tree/, and the results it
# copies are written once; 23 (partial transfer due to error: a file that could not be read
# or written, a full local disk) means a result may be missing, so it is a failed fetch.
RSYNC_OK = (0, 24)


def missing_outputs(local: Path) -> list[str]:
    """Every seed the report will count (summary.txt verdict=passed) whose deploy files are not
    here: output_files/*.rbf, what is deployed, and output_files/sdram_io.txt, what the SDRAM
    I/O floor was judged from. summary.txt is written last on the host (seed_sweep.py), so a
    passed summary without them is an incomplete copy, and its seed must not rank."""
    problems = []
    for sd in sorted(local.glob("seed[0-9][0-9][0-9]")):
        summary = sd / "summary.txt"
        if not summary.is_file() or "verdict=passed" not in summary.read_text().splitlines():
            continue
        out = sd / "output_files"
        if not list(out.glob("*.rbf")):
            problems.append(f"{sd.name}: no output_files/*.rbf")
        if not (out / "sdram_io.txt").is_file():
            problems.append(f"{sd.name}: no output_files/sdram_io.txt")
    return problems


def fetch(args, rem: Remote, run_id: str) -> Path:
    _, run_dir = remote_paths(args, run_id)
    local = Path(args.local_dir) if args.local_dir else RUNS_DIR / run_id
    local.mkdir(parents=True, exist_ok=True)
    # No --delete, no --remove-source-files: the remote copy stays, and a re-fetch only adds.
    r = sh(["rsync", "-a", "--exclude=seed*/tree/", "-e", rem.rsync_e(), f"{rem.host}:{run_dir}/sweep/", f"{local}/"])
    if r.returncode not in RSYNC_OK:
        raise SystemExit(f"fetch failed (rsync {r.returncode}): the local copy in {local} may be "
                         f"incomplete; re-run fetch")
    sh(["rsync", "-a", "-e", rem.rsync_e(), f"{rem.host}:{run_dir}/log", f"{local}/remote-sweep.log"])
    n = len(list(local.glob("seed[0-9][0-9][0-9]")))
    print(f"==> fetched {n} seed dir(s) -> {local}")
    missing = missing_outputs(local)
    if missing:
        raise SystemExit("fetch incomplete: a passed seed is missing what it would deploy or was "
                         "judged from:\n  " + "\n  ".join(missing))
    return local


def wait_and_fetch(args, rem: Remote, run_id: str) -> int:
    code = None
    last = ""
    misses = 0
    while True:
        out, code = status_text(args, rem, run_id)
        if code == UNREACHABLE:
            misses += 1
            if misses > args.ssh_retries:
                raise SystemExit(f"{rem.host} unreachable on {misses} polls in a row; the sweep "
                                 f"may still be running: tools/remote_fit.py --host {rem.host} "
                                 f"--run-id {run_id} status|fetch|report")
            print(f"[{time.strftime('%H:%M:%S')}] {out.strip()} (retry {misses}/{args.ssh_retries})",
                  flush=True)
            time.sleep(args.poll)
            continue
        misses = 0
        head = out.splitlines()[:2]
        line = " | ".join(head)
        if line != last:
            print(f"[{time.strftime('%H:%M:%S')}] {line}", flush=True)
            last = line
        if code is not None:
            break
        time.sleep(args.poll)
    local = fetch(args, rem, run_id)
    rep = sh([sys.executable, str(REPO / "tools" / "seed_sweep.py"), "--dir", str(local),
              "--report", *gate_args(args)])
    return 0 if code == 0 and rep.returncode == 0 else 1


def cmd_fetch(args, rem: Remote) -> int:
    fetch(args, rem, resolve_run_id(args))
    return 0


def cmd_report(args, rem: Remote) -> int:
    local = fetch(args, rem, resolve_run_id(args))
    return sh([sys.executable, str(REPO / "tools" / "seed_sweep.py"), "--dir", str(local),
               "--report", "--top", str(args.top), *gate_args(args)]).returncode


def cmd_list(args, rem) -> int:
    try:
        print((RUNS_DIR / "runs.txt").read_text(), end="")
    except OSError:
        print("(no runs launched from this checkout)")
    return 0


def selftest() -> int:
    with tempfile.TemporaryDirectory() as t:
        repo = Path(t) / "r"
        repo.mkdir()
        g = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True,
                                      capture_output=True)
        g("init", "-q")
        g("config", "user.email", "t@t")
        g("config", "user.name", "t")
        (repo / "a.sv").write_text("a")
        (repo / "gone.sv").write_text("g")
        (repo / ".gitignore").write_text("ign/\n")
        g("add", "-f", "a.sv", "gone.sv", ".gitignore")
        g("commit", "-qm", "x")
        (repo / "a.sv").write_text("edited")                 # uncommitted edit: sent as on disk
        (repo / "gone.sv").unlink()                          # deleted: left out
        (repo / "new.sv").write_text("n")                    # untracked small: sent
        (repo / "big.bin").write_bytes(b"x" * 3000)          # untracked big: skipped
        (repo / "ign").mkdir()
        (repo / "ign" / "z").write_text("z")                 # ignored: not sent
        send, skipped = snapshot_files(repo, 1)
        assert send == [".gitignore", "a.sv", "new.sv"], send
        assert skipped == ["big.bin"], skipped
    assert new_run_id("my fix!").startswith("my-fix--")
    for bad in (["--dir", "x"], ["--dir=x"], ["--report"]):
        try:
            check_sweep_args(bad)
        except SystemExit:
            continue
        raise AssertionError(f"{bad} must be refused")
    c = sweep_command("python3", "/r/run1", ["--profile", "base", "--seeds", "2,3"], "/s", 5,
                      True, 40.0)
    assert "--slot-dir /s --slot-max 5 --slot-all --max-load 40.0 --profile base" in c, c
    assert "--dir /r/run1/sweep" in c
    # The pll_hdmi deploy gate travels with the remote sweep, and the selftest proves it is
    # forwarded rather than dropped (a remote run judged differently from a local one is the bug).
    g = gate_args(argparse.Namespace(min_other_setup="-0.3", min_positive=True, min_seeds=6,
                                     min_sdram_io="0.1"))
    assert g == ["--min-other-setup", "-0.3", "--min-positive", "--min-seeds", "6",
                 "--min-sdram-io", "0.1"], g
    assert gate_args(argparse.Namespace()) == [], "unset flags must leave seed_sweep defaults"
    c = sweep_command("python3", "/r/run1", ["--profile", "base"], "/s", 5, True, 40.0, g)
    assert c.endswith("--min-other-setup -0.3 --min-positive --min-seeds 6 --min-sdram-io 0.1"), c
    # A failed ssh (empty or foreign reply) is UNREACHABLE, never a finished sweep (-1).
    assert parse_status("") == UNREACHABLE and parse_status("ssh: connect refused\n") == UNREACHABLE
    assert parse_status("RUNNING\nseeds: 0 done / 1 started\n") is None
    assert parse_status("EXIT 0\n") == 0 and parse_status("EXIT 3\n") == 3
    assert parse_status("DEAD\n") == -1 and parse_status("MISSING\n") == -1
    assert parse_status("EXIT\n") == UNREACHABLE
    assert live_reply("LIVE\n") is True and live_reply("IDLE\n") is False
    assert live_reply("") is None, "a failed ssh must not read as idle"
    # rsync 23 (partial transfer due to error) is a failed fetch; 24 (vanished files) is not.
    assert 23 not in RSYNC_OK and 24 in RSYNC_OK and 0 in RSYNC_OK
    # Every passed seed must have come back with its RBF and its SDRAM I/O record.
    with tempfile.TemporaryDirectory() as t:
        local = Path(t)

        def seed(name, verdict, *files):
            sd = local / name
            (sd / "output_files").mkdir(parents=True)
            (sd / "summary.txt").write_text(f"seed=1\nverdict={verdict}\n")
            for f in files:
                (sd / "output_files" / f).write_text("x")
        seed("seed001", "passed", "z486_mister.rbf", "sdram_io.txt")
        seed("seed002", "failed")                                   # failed: not counted
        seed("seed003.stale-1", "passed")                           # moved aside: not counted
        assert missing_outputs(local) == [], missing_outputs(local)
        seed("seed004", "passed", "sdram_io.txt")
        seed("seed005", "passed", "z486_mister.rbf")
        assert missing_outputs(local) == ["seed004: no output_files/*.rbf",
                                          "seed005: no output_files/sdram_io.txt"], \
            missing_outputs(local)
    r = Remote("h", ["-p", "2222"])
    assert r.ssh_argv("true")[-2:] == ["h", "true"] and "-p" in r.ssh_argv("true")
    print("remote_fit selftest: PASS")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default=os.environ.get("FIT_HOST"),
                    help="ssh destination of the build host, keys only (env FIT_HOST)")
    ap.add_argument("--remote-dir", default=os.environ.get("FIT_REMOTE_DIR", "fits"),
                    help="directory on the host holding the runs (default ~/fits; env "
                         "FIT_REMOTE_DIR)")
    ap.add_argument("--ssh-opt", action="append", default=[], help="one extra ssh argument per use, e.g. --ssh-opt=-p --ssh-opt=2222")
    ap.add_argument("--run-id", help="the run to act on (default: the last launched)")
    ap.add_argument("--local-dir", help="where fetch puts the seeds (default "
                                        ".build/remote-fit/<run-id>)")
    ap.add_argument("--remote-python", default=os.environ.get("FIT_REMOTE_PYTHON", "python3"))
    ap.add_argument("--selftest", action="store_true")
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("run", help="snapshot, launch, wait, fetch, report")
    p.add_argument("--label", default=REPO.name, help="prefix of the run id (default: the "
                                                      "checkout's directory name)")
    p.add_argument("--untracked-max-kb", type=int, default=1024)
    p.add_argument("--slot-dir", help="host_slots directory on the host (default "
                                      "<remote-dir's parent>/.fit-slots)")
    p.add_argument("--slot-max", type=int, default=int(os.environ.get("FIT_SLOT_MAX", "12")),
                   help="ceiling of concurrent fits on the host, all containers counted (env "
                        "FIT_SLOT_MAX, default 12)")
    p.add_argument("--no-slot-all", action="store_true",
                   help="count only this tool's slots, not every running container")
    p.add_argument("--max-load", type=float,
                   default=float(os.environ["FIT_MAX_LOAD"]) if os.environ.get("FIT_MAX_LOAD") else None,
                   help="don't start a fit while the host's 1-minute load average is above this "
                        "(env FIT_MAX_LOAD; default: the host's core count; 0 disables)")
    p.add_argument("--remote-env", action="append", default=[], metavar="K=V",
                   help="environment for the sweep on the host (repeatable), e.g. "
                        "CONTAINER_RUNTIME=docker")
    p.add_argument("--no-wait", action="store_true", help="launch and return")
    p.add_argument("--poll", type=int, default=60)
    p.add_argument("--ssh-retries", type=int, default=30,
                   help="polls in a row the host may fail to answer before the wait gives up "
                        "(the sweep keeps running; default 30)")
    p.add_argument("sweep_args", nargs=argparse.REMAINDER, help="after --: seed_sweep.py arguments")
    add_gate_args(p)
    for name in ("status", "fetch", "list"):
        sub.add_parser(name)
    p = sub.add_parser("report")
    p.add_argument("--top", type=int, default=10)
    add_gate_args(p)
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if not args.cmd:
        ap.error("a command is required")
    if args.cmd == "list":
        return cmd_list(args, None)
    if not args.host:
        ap.error("--host (or FIT_HOST) is required")
    rem = Remote(args.host, args.ssh_opt)
    # Relative remote paths would resolve against whatever directory a command cd'd into.
    args.remote_home = rem.run("echo $HOME").stdout.strip()
    if not args.remote_dir.startswith("/"):
        args.remote_dir = f"{args.remote_home}/{args.remote_dir}"
    if args.cmd == "run":
        if args.sweep_args and args.sweep_args[0] == "--":
            args.sweep_args = args.sweep_args[1:]
        return cmd_run(args, rem)
    return {"status": cmd_status, "fetch": cmd_fetch, "report": cmd_report}[args.cmd](args, rem)


if __name__ == "__main__":
    raise SystemExit(main())

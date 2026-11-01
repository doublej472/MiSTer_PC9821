#!/usr/bin/env python3
"""Subprocess helpers shared by this directory's tools.

Why this file exists at all: every incident the new tools are meant to prevent came
from a shell losing track of a child process. A SIGHUP to a launcher killed the fits
still running under it; a `>/dev/null` hid the error that explained a failure; an exit
code read after a pipe belonged to `tee` rather than to the program. Those are one
class of mistake -- a shell's process and quoting model -- and this module puts the
rules in one place so that no tool has to restate them:

  * A CHILD'S OUTPUT IS NEVER DISCARDED. stream() copies it to this process AND to a
    log file, so a failure has both a live view and a durable record. There is no
    option to send it to /dev/null.
  * A NON-ZERO EXIT IS A VALUE, NOT AN EXCEPTION. stream() returns the code; the
    caller decides what it means, and every command prints its own verdict and sets
    its own exit code rather than relying on `set -e`.
  * ANYTHING THAT OUTLIVES ITS LAUNCHER IS STARTED IN ITS OWN SESSION. run_detached()
    (and stream(new_session=True)) pass start_new_session=True, so the child is not
    in the launcher's process group and a SIGHUP to the launcher -- a killed shell, a
    timed-out parent process -- cannot reach it. This is the seed-sweep fix.
"""

from __future__ import annotations

import hashlib
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent


def eprint(*args) -> None:
    print(*args, file=sys.stderr)


def die(message: str, code: int = 2):
    """Print a one-line error and exit. The exit code is the tool's contract."""
    eprint(f"{Path(sys.argv[0]).name}: {message}")
    raise SystemExit(code)


def have(program: str) -> str | None:
    return shutil.which(program)


def nproc() -> int:
    """The host's logical CPU count, for sizing parallel jobs. Callers use this as
    the DEFAULT worker count, not a cap: the box is deliberately oversubscribed
    (NCPU jobs of a few threads each) and the kernel load-balances."""
    return os.cpu_count() or 1


def _spawn_argv(argv) -> list[str]:
    return [str(a) for a in argv]


def stream(argv, *, log: Path | str | None = None, cwd: Path | str | None = None,
           env: dict | None = None, new_session: bool = False,
           append: bool = False) -> tuple[int, str]:
    """Run argv, echoing combined stdout+stderr here AND to log.

    Returns (exit_code, all_output). Never raises on a non-zero exit: the caller owns
    the verdict. There is deliberately no way to suppress the output.
    """
    argv = _spawn_argv(argv)
    log_file = None
    if log is not None:
        log = Path(log)
        log.parent.mkdir(parents=True, exist_ok=True)
        # append: a build's steps share one log, so each step adds to it instead of
        # replacing what the steps before it wrote.
        log_file = log.open("a" if append else "w")
        log_file.write("$ " + shlex.join(argv) + "\n")
        log_file.flush()
    print("$ " + shlex.join(argv), flush=True)

    proc = subprocess.Popen(
        argv,
        cwd=str(cwd) if cwd is not None else str(REPO_ROOT),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=new_session,
    )
    assert proc.stdout is not None
    chunks: list[str] = []
    for line in proc.stdout:
        chunks.append(line)
        sys.stdout.write(line)
        sys.stdout.flush()
        if log_file is not None:
            log_file.write(line)
            log_file.flush()
    code = proc.wait()
    if log_file is not None:
        log_file.close()
    return code, "".join(chunks)


# A child that floods its output (a bench stuck in a printing loop) must not take the host down:
# capture() once held a runaway bench's whole output in memory and the OOM killer reaped it at
# 53 GB resident, along with the interactive login. Past this many bytes the child
# is killed and the run reported as overflowed; no bench writes within orders of magnitude of it.
CAPTURE_MAX_BYTES = int(os.environ.get("PC9821_CAPTURE_MAX_BYTES", 256 * 1024 * 1024))


def capture(argv, *, cwd: Path | str | None = None, env: dict | None = None,
            timeout: float | None = None,
            max_bytes: int | None = None) -> tuple[int, str, bool]:
    """Run argv and capture its combined output.

    Returns (exit_code, output, timed_out). A timeout kills the child and reports
    exit 124 with whatever it printed before it was killed, so a hang is reported
    rather than mistaken for a pass. Output past max_bytes (CAPTURE_MAX_BYTES by default)
    kills the child too and reports exit 125 with the first max_bytes and a closing note,
    so a flood is a failure rather than an out-of-memory host.
    """
    import threading
    argv = _spawn_argv(argv)
    limit = CAPTURE_MAX_BYTES if max_bytes is None else max_bytes
    proc = subprocess.Popen(
        argv,
        cwd=str(cwd) if cwd is not None else str(REPO_ROOT),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    chunks: list[bytes] = []
    state = {"size": 0, "overflow": False}

    def pump() -> None:
        while True:
            data = proc.stdout.read1(1 << 16)
            if not data:
                return
            if state["overflow"]:
                continue
            room = limit - state["size"]
            if len(data) > room:
                chunks.append(data[:room])
                state["size"] = limit
                state["overflow"] = True
                proc.kill()
                continue
            chunks.append(data)
            state["size"] += len(data)

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    timed_out = False
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        proc.kill()
        proc.wait()
    reader.join()
    output = b"".join(chunks).decode("utf-8", "replace")
    if state["overflow"]:
        return 125, output + f"\n[capture: output exceeded {limit} bytes; the child was killed]\n", False
    if timed_out:
        return 124, output, True
    return proc.returncode, output, False


def tree_tag(path) -> str:
    """A short, stable tag for a tree path, for unique per-build container names.

    Two concurrent builds (lanes, or a sweep on each of two machines sharing a podman
    daemon) must not collide on a podman container name. The seed alone is not unique
    across trees, so the name carries a hash of the tree's absolute path too.
    """
    return hashlib.sha256(str(path).encode()).hexdigest()[:8]


def run_detached(argv, *, log, cwd=None, env=None) -> subprocess.Popen:
    """Start argv in its OWN session, output to log, and return the Popen.

    start_new_session=True is the whole point: the child is a session and process
    group leader, so a SIGHUP or SIGINT sent to this tool's process group -- which is
    what a killed shell or a timed-out parent process delivers -- does not reach it. A
    build launched here finishes even if everything that launched it dies.
    """
    argv = _spawn_argv(argv)
    log = Path(log)
    log.parent.mkdir(parents=True, exist_ok=True)
    handle = log.open("w")
    env = env if env is not None else os.environ.copy()
    proc = subprocess.Popen(
        argv,
        cwd=str(cwd) if cwd is not None else str(REPO_ROOT),
        env=env,
        stdout=handle,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    return proc


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # os.kill(pid, 0) also succeeds for a zombie (exited but not reaped). A zombie is
    # not alive, so read /proc/<pid>/stat and treat state 'Z' as dead.
    try:
        with open(f"/proc/{pid}/stat", "rb") as f:
            stat = f.read().decode(errors="replace")
    except OSError:
        return True
    rparen = stat.rfind(")")
    if rparen < 0 or rparen + 2 >= len(stat):
        return True
    return stat[rparen + 2] != "Z"


def quote(argv) -> str:
    return shlex.join(_spawn_argv(argv))

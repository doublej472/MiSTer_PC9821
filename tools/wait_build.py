#!/usr/bin/env python3
"""Block until this tree's build finishes, then exit with its verdict.

This replaces the shell wait script of the old tooling (out of tree now). That script was already
the right idea -- track the build PROCESS rather than sleeping a guessed number of
seconds -- and this keeps it, with the two things the shell could not do reliably:

  * THE VERDICT IS THE EXIT CODE. wait_build.sh printed a grep of the log and always
    exited 0, so a caller that trusted it waited correctly and then passed a failed
    build. Here exit 0 means the build produced its RBF and 1 means it did not, which
    is the same verdict tools/build.py recorded in .build/quartus.status.json.

  * A DEAD BUILD IS REPORTED, NOT WAITED FOR FOREVER. The status file names the owning
    pid; if that pid is gone while the state is still "running" -- the build was
    killed -- this says so and exits 1 instead of polling a log that will never grow.

  * IT WAITS ONLY FOR THIS TREE'S BUILD. The status lives inside the checkout, so worktrees
    building in parallel never observe each other.

Background pattern (start, do other work, then block for the result):
  tools/build.py --detach
  ... write the doc, run the gate ...
  tools/wait_build.py            # blocks, then exits 0 (pass) or 1 (fail)
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from proc import REPO_ROOT, eprint, pid_alive  # noqa: E402
from build import summarize  # noqa: E402


def read_status(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        return None


def wait(tree: Path, start_timeout: float, interval: float, deadline: float | None) -> int:
    status_path = tree / ".build" / "quartus.status.json"
    start = time.monotonic()

    record = read_status(status_path)
    while record is None and time.monotonic() - start < start_timeout:
        time.sleep(interval)
        record = read_status(status_path)
    if record is None:
        eprint(
            f"wait_build: no build has run in {tree} "
            f"(no {status_path}). Start one with tools/build.py --detach."
        )
        return 2

    if record.get("state") == "running":
        pid = int(record.get("pid", 0) or 0)
        print(f"wait_build: waiting on pid {pid} "
              f"(log {record.get('log')}, started {record.get('started_at')}) ...")
        while True:
            time.sleep(interval)
            fresh = read_status(status_path)
            if fresh is not None:
                record = fresh
            if record.get("state") != "running":
                break
            if not pid_alive(pid):
                print("wait_build: the build process is gone while still marked running "
                      "- it was killed before it could finish")
                _report(record, Path(str(record.get("log", ""))))
                return 1
            if deadline is not None and time.monotonic() - start > deadline:
                eprint(f"wait_build: still running after {deadline:.0f}s; giving up "
                       f"(the build itself is untouched)")
                return 3

    log = Path(str(record.get("log", "")))
    state = record.get("state")
    _report(record, log)
    if state == "passed":
        print(f"BUILD: PASS ({_duration(record)})")
        return 0
    print(f"BUILD: FAIL ({state}; exit {record.get('exit')})")
    return 1


def _duration(record: dict) -> str:
    try:
        return f"{float(record['ended']) - float(record['started']):.0f}s"
    except (KeyError, TypeError, ValueError):
        return "duration unknown"


def _report(record: dict, log: Path) -> None:
    print(f"=== build {record.get('state')} ({record.get('started_at')}) ===")
    if record.get("rbf"):
        print(f"RBF:    {record['rbf']}")
        print(f"sha256: {record.get('sha256')}")
    summary = summarize(log)
    for line in summary:
        print("  " + line)
    if not summary and log and not log.exists():
        print(f"  (log {log} not found)")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Block until this tree's build finishes.")
    parser.add_argument("--tree", type=Path, default=REPO_ROOT,
                        help="the checkout whose build to wait for (default: this one)")
    parser.add_argument("--start-timeout", type=float, default=30.0,
                        help="seconds to wait for a detached build to write its status")
    parser.add_argument("--interval", type=float, default=2.0, help="poll interval, seconds")
    parser.add_argument("--timeout", type=float, default=None,
                        help="give up after this many seconds (the build is not killed)")
    args = parser.parse_args(argv)
    return wait(Path(args.tree).resolve(), args.start_timeout, args.interval, args.timeout)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

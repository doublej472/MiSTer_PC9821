#!/usr/bin/env python3
"""Run one tools/mister_regress.py regression on SEVERAL MiSTers at once.

    tools/mister_multi.py --hosts root@cardA,root@cardB --mode split  -- <regress args>
    tools/mister_multi.py --hosts a,b --mode repeat --lock-wait 3600 -- --go --rbf x.rbf \
        --hdd-image d.img --items probe,doom --scenarios s.json
    tools/mister_multi.py --selftest

  --hosts   comma list of ssh destinations (env MISTER_HOSTS); a bare name gets root@
  --mode    split   the items are dealt round-robin over the hosts (wall-clock: each item once)
            repeat  every host runs every item (multi-device stability: the same build on N cards)
  everything after `--` is mister_regress.py's own argument list; do not pass --host, --out or
  --items there (--items is read from it to be split, then passed per host).

Each host gets its own results directory (<out>/<host-slug>/, default
.build/mister-multi/<time>-<pid>/) and its own patched image copy, so concurrent runs share no
local path, and its own card lock (mister_regress's, per card; --lock-wait S is passed through
so a card busy with another run is waited for rather than refused). The combined summary is
<out>/summary.txt (and printed): one row per host and item; the exit status is 0 only if every
host's run exited 0. Without --go in the regress arguments every host prints its plan only.
Password / keys: MISTER_PASS as everywhere (default 1; empty = ssh keys), shared by all hosts.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGRESS = ROOT / "tools" / "mister_regress.py"
DEFAULT_ITEMS = ("speeds", "keymap", "probe", "probe-cda", "doom", "th05", "rusty", "policenauts", "flamezap", "cpusuite")  # = mister_regress.DEFAULT_ITEMS


def norm_host(h: str) -> str:
    h = h.strip()
    return h if "@" in h else f"root@{h}"


def slug(h: str) -> str:
    h = h.split("@", 1)[-1]
    return "".join(c if c.isalnum() or c in "-_." else "_" for c in h)


def split_items(items: list[str], hosts: list[str], mode: str) -> dict[str, list[str]]:
    if mode == "repeat":
        return {h: list(items) for h in hosts}
    plan = {h: [] for h in hosts}
    for i, it in enumerate(items):
        plan[hosts[i % len(hosts)]].append(it)
    return plan


def pop_option(args: list[str], name: str) -> tuple[list[str], str | None]:
    """Remove `name VALUE` / `name=VALUE` from args; returns (rest, value)."""
    rest, val, i = [], None, 0
    while i < len(args):
        a = args[i]
        if a == name and i + 1 < len(args):
            val = args[i + 1]
            i += 2
            continue
        if a.startswith(name + "="):
            val = a.split("=", 1)[1]
        else:
            rest.append(a)
        i += 1
    return rest, val


def summarize(out: Path, hosts: list[str], codes: dict[str, int]) -> str:
    lines = []
    for h in hosts:
        rj = out / slug(h) / "results.json"
        lines.append(f"== {h} (exit {codes.get(h)})")
        try:
            for k, (v, d) in json.loads(rj.read_text()).items():
                lines.append(f"  {v:10s} {k:12s} {d}")
        except (OSError, ValueError):
            lines.append("  (no results.json: the run did not finish; see its log.txt)")
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--hosts", default=os.environ.get("MISTER_HOSTS"))
    ap.add_argument("--mode", choices=("split", "repeat"), default="split")
    ap.add_argument("--out", help="combined results directory")
    ap.add_argument("--lock-wait", type=int, default=0)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("regress_args", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.hosts:
        ap.error("--hosts (or MISTER_HOSTS) is required")
    hosts = [norm_host(h) for h in a.hosts.split(",") if h.strip()]
    if len(set(hosts)) != len(hosts):
        ap.error("duplicate host")
    rargs = a.regress_args[1:] if a.regress_args[:1] == ["--"] else a.regress_args
    for bad in ("--host", "--out", "--selftest"):
        if any(x == bad or x.startswith(bad + "=") for x in rargs):
            ap.error(f"{bad} is chosen by mister_multi")
    rargs, items = pop_option(rargs, "--items")
    items = [i for i in (items.split(",") if items else DEFAULT_ITEMS) if i]
    plan = split_items(items, hosts, a.mode)
    out = Path(a.out) if a.out else ROOT / ".build" / "mister-multi" / f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"
    out.mkdir(parents=True, exist_ok=True)
    procs = {}
    for h in hosts:
        if not plan[h]:
            print(f"{h}: no items (more hosts than items)")
            continue
        cmd = [sys.executable, str(REGRESS), *rargs, "--host", h, "--out", str(out / slug(h)),
               "--items", ",".join(plan[h]), "--lock-wait", str(a.lock_wait)]
        (out / slug(h)).mkdir(parents=True, exist_ok=True)
        logf = open(out / slug(h) / "stdout.txt", "w")
        print(f"{h}: {','.join(plan[h])}")
        procs[h] = (subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT), logf)
    codes = {}
    for h, (p, logf) in procs.items():
        codes[h] = p.wait()
        logf.close()
    text = summarize(out, hosts, codes)
    (out / "summary.txt").write_text(text)
    print(text, end="")
    print(f"results: {out}")
    return 0 if all(c == 0 for c in codes.values()) and procs else 1


def selftest() -> int:
    import tempfile
    assert norm_host("mister") == "root@mister" and norm_host("u@h") == "u@h"
    assert split_items(["a", "b", "c"], ["h1", "h2"], "split") == {"h1": ["a", "c"], "h2": ["b"]}
    assert split_items(["a", "b"], ["h1", "h2"], "repeat") == {"h1": ["a", "b"], "h2": ["a", "b"]}
    assert pop_option(["--x", "--items", "a,b", "--y"], "--items") == (["--x", "--y"], "a,b")
    assert pop_option(["--items=a"], "--items") == ([], "a")
    assert slug("root@my card") == "my_card"
    with tempfile.TemporaryDirectory() as t:
        out = Path(t)
        (out / "h1").mkdir()
        (out / "h1" / "results.json").write_text(json.dumps({"keymap": ["PASS", "ok"]}))
        txt = summarize(out, ["root@h1", "root@h2"], {"root@h1": 0, "root@h2": 1})
        assert "PASS" in txt and "no results.json" in txt, txt
    print("mister_multi selftest: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

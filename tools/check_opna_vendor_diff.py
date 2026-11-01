#!/usr/bin/env python3
"""Hold src/opna/ and its pinned upstream together (the vendor-diff gate).

src/opna/LICENSE-SCOPE.md pins PC88_MiSTer `rtl/sound/` at one commit and says every file of
jt12/, jt49/ and jtopna.v is a byte-identical copy of it except TEN files with documented, marked
local changes.  This check proves that against a real checkout:

  * the files that differ from upstream are EXACTLY the recorded list (LOCAL_FILES below);
  * every one of them carries a `LOCAL CHANGE`/`LOCAL FIX`/`LOCAL PATCH` marker (a delta that is
    not marked in-file is a defect), and is named in LICENSE-SCOPE.md;
  * no vendored file is absent from upstream (an unrecorded addition inside the vendored trees);
  * the checkout's HEAD is the commit LICENSE-SCOPE.md pins.

The baseline is a PC88_MiSTer checkout at the pinned commit, from --upstream or $OPNA_UPSTREAM.
Without one the script prints a loud SKIP and exits 2 - never a pass.  --selftest plants a delta
in an unlisted file, an unmarked delta in a listed file, a stale list entry and a foreign file in
temp copies and requires each to be named; it needs no checkout (the tree is its own baseline).

Exit 0 = agrees, 1 = a difference, 2 = the check could not run (SKIP).
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# The recorded list (src/opna/LICENSE-SCOPE.md, "Upstream"), relative to src/opna/.
LOCAL_FILES = frozenset({
    "jtopna.v",
    "jt12/hdl/jt08.v",
    "jt12/hdl/jt12_top.v",
    "jt12/hdl/jt08_acc.v",
    "jt12/hdl/adpcm/jt08_adpcm_drvA.v",
    "jt12/hdl/adpcm/jt08_adpcm_acc.v",
    "jt12/hdl/adpcm/jt08_adpcm_cnt.v",
    "jt12/hdl/jt12_timers.v",
    "jt12/hdl/jt12_mmr.v",
    "jt49/hdl/jt49.v",
})
VENDORED = ("jt12", "jt49", "jtopna.v")      # the vendored trees; the rest of src/opna is ours
# A cross-reference counts (LICENSE-SCOPE.md: "marked in-file ... or cross-referenced to one"),
# e.g. jt08_adpcm_drvA.v's "See jt08_adpcm_acc.v's local-change note".
MARKER_RE = re.compile(r"LOCAL[- ](CHANGE|FIX|PATCH)", re.I)
SOUND = Path("rtl") / "sound"


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def walk(base: Path) -> dict[str, Path]:
    out: dict[str, Path] = {}
    for top in VENDORED:
        p = base / top
        if p.is_file():
            out[top] = p
        elif p.is_dir():
            for q in sorted(p.rglob("*")):
                if q.is_file() and "__pycache__" not in q.parts:
                    out[str(q.relative_to(base))] = q
    return out


def pinned_commit(doc: Path) -> str | None:
    m = re.search(r"commit\s+`([0-9a-f]{40})`", doc.read_text(encoding="utf-8"))
    return m.group(1) if m else None


def compare(up_base: Path, tree: Path, doc: Path, local: frozenset[str]) -> list[str]:
    up, ven = walk(up_base), walk(tree)
    scope = doc.read_text(encoding="utf-8")
    problems: list[str] = []
    differing = {f for f in ven.keys() & up.keys() if ven[f].read_bytes() != up[f].read_bytes()}
    for f in sorted(differing - local):
        problems.append(f"UNRECORDED delta: {f} differs from upstream and is not on the recorded list")
    for f in sorted(local - differing):
        problems.append(f"STALE list entry: {f} is recorded as modified but equals upstream (or is absent)")
    for f in sorted(ven.keys() - up.keys()):
        problems.append(f"FOREIGN file: {f} is inside a vendored tree but not in upstream")
    for f in sorted(local & differing):
        text = ven[f].read_text(encoding="utf-8", errors="replace")
        if not MARKER_RE.search(text):
            problems.append(f"UNMARKED delta: {f} differs from upstream but carries no LOCAL CHANGE/FIX/PATCH marker or cross-reference")
        if f not in scope and Path(f).name not in scope:
            problems.append(f"UNDOCUMENTED: {f} is not named in {doc.name}")
    n = len(local)
    words = {10: "ten"}
    if f"**{words.get(n, n)}** files" not in scope:
        problems.append(f"{doc.name} does not state the recorded count ({words.get(n, n)}) of modified files")
    return problems


def selftest(tree: Path, doc: Path) -> int:
    fails = 0
    with tempfile.TemporaryDirectory(prefix="opna-selftest-") as tmp:
        tmp = Path(tmp)
        base = tmp / "up"
        shutil.copytree(tree, base)          # the tree as its own baseline: nothing differs yet
        t0 = tmp / "t"
        # Baseline of the selftest: tree == upstream, so the real recorded list is "stale" everywhere.
        # Use a list of the files that carry a marker, so the clean control passes.
        local = frozenset(LOCAL_FILES)
        # Make the "upstream" copy differ from the tree on exactly the recorded files.
        for f in local:
            p = base / f
            p.write_bytes(p.read_bytes() + b"\n// upstream\n")
        probs = compare(base, tree, doc, local)
        if probs:
            print("  selftest control: clean tree reported problems:", *probs, sep="\n    "); fails += 1
        else:
            print("  selftest control: recorded list over a clean copy -> passes")

        def case(name: str, up_edit, tree_rel: str | None, tree_edit, expect: str, lst=local):
            nonlocal fails
            u, t = tmp / f"u-{name}", tmp / f"t-{name}"
            shutil.copytree(base, u); shutil.copytree(tree, t)
            up_edit(u); tree_edit(t)
            got = compare(u, t, doc, lst)
            if any(expect in g for g in got):
                print(f"  selftest {name}: caught ({expect})")
            else:
                print(f"  selftest {name}: FAILED to catch ({expect}); got {got}"); fails += 1

        unlisted = "jt12/hdl/jt12_pm.v"
        if not (tree / unlisted).exists():
            unlisted = next(f for f in walk(tree) if f not in local and f.endswith(".v"))
        nop = lambda d: None
        case("A-unrecorded-delta", nop, unlisted,
             lambda d: (d / unlisted).write_bytes((d / unlisted).read_bytes() + b"\n// x\n"), "UNRECORDED delta")
        case("B-unmarked-delta", nop, None,
             lambda d: (d / "jt49/hdl/jt49.v").write_text(
                 MARKER_RE.sub("NOTE", (d / "jt49/hdl/jt49.v").read_text(encoding="utf-8")) + "\n// y\n",
                 encoding="utf-8"), "UNMARKED delta")
        case("C-stale-entry", lambda d: (d / "jt49/hdl/jt49.v").write_bytes(
                 (tree / "jt49/hdl/jt49.v").read_bytes()), None, nop, "STALE list entry")
        case("D-foreign-file", nop, None,
             lambda d: (d / "jt12/hdl/foreign_extra.v").write_text("module x; endmodule\n"), "FOREIGN file")
    return 1 if fails else 0


def main() -> int:
    root = repo_root()
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tree", default=str(root / "src" / "opna"))
    ap.add_argument("--doc", default=str(root / "src" / "opna" / "LICENSE-SCOPE.md"))
    ap.add_argument("--upstream", default=os.environ.get("OPNA_UPSTREAM"),
                    help="PC88_MiSTer checkout at the pinned commit (or $OPNA_UPSTREAM)")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    tree, doc = Path(a.tree), Path(a.doc)
    if a.selftest:
        rc = selftest(tree, doc)
        print("OPNA VENDOR DIFF SELFTEST:", "PASS" if rc == 0 else "FAIL")
        return rc
    if not a.upstream or not Path(a.upstream).is_dir():
        print("OPNA VENDOR DIFF: SKIP - no PC88_MiSTer checkout (--upstream DIR or $OPNA_UPSTREAM at the"
              " commit src/opna/LICENSE-SCOPE.md pins); nothing was checked")
        return 2
    up = Path(a.upstream)
    pin = pinned_commit(doc)
    if not pin:
        print(f"OPNA VENDOR DIFF: FAIL - no pinned commit found in {doc}")
        return 1
    head = subprocess.run(["git", "-C", str(up), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    if head != pin:
        print(f"OPNA VENDOR DIFF: FAIL - checkout HEAD {head or '?'} is not the pinned {pin}")
        return 1
    problems = compare(up / SOUND, tree, doc, LOCAL_FILES)
    for p in problems:
        print("  FAIL", p)
    print(f"OPNA VENDOR DIFF: {'FAIL - %d problem(s)' % len(problems) if problems else 'PASS - exactly the %d recorded files differ, all marked' % len(LOCAL_FILES)}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

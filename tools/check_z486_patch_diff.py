#!/usr/bin/env python3
"""Hold docs/z486-local-patch.md and src/z486/ together.

The contract (docs/z486-local-patch.md, `### Verified diff map`):

  * every file that differs from the pinned checkout is listed in the map,
  * every file that carries a `LOCAL PATCH` marker is listed in the map,
  * the only files deliberately not carried are the ones named in the map's
    "only in upstream" row,
  * the only files carried that upstream does not have are the ones named in the
    map's "only in tree" row (this platform's PC-98 test/infrastructure set),
  * and the map was taken against the pin the document names.

The baseline is a checkout of the z486 fork at the vendored commit, supplied via
`--upstream` or `$Z486_UPSTREAM`. With neither supplied the script prints a loud SKIP
(exit 2) rather than checking anything - never a pass. `--selftest` proves it can
still fail (it plants a delta and a removed map row in temp copies).

It is the only thing holding the map and the tree together now that `src/z486/` may
legitimately change (through the fork).

Usage:
    tools/check_z486_patch_diff.py [--tree src/z486] [--doc docs/z486-local-patch.md]
                                     [--upstream DIR]
                                     [--selftest]

Exit 0 = agrees, 1 = a difference, 2 = the check could not run (a loud SKIP, never a pass).
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PIN_RE = re.compile(r"\b([0-9a-f]{40})\b")
MAP_HEADER = "Verified diff map"
MARKER_RE = re.compile(r"LOCAL PATCH|LOCAL CHANGE|LOCAL FIX|LOCAL ADD|PORT CONTRACT \(entry")
SKIP_DIRS = {".git", "__pycache__"}


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def read_doc(doc: Path) -> tuple[str, dict[str, str], set[str], set[str]]:
    """-> (pin or None, {file: entries-cell}, {"only in upstream" names}, {"only in tree" names})

    The pin is OPTIONAL since src/z486/ became a plain copy of the fork: this repo
    no longer names the baseline's provenance (self-containment - an out-of-repo
    path in a citation is a defect), so the document normally carries no 40-hex pin
    and the baseline is whatever `--upstream`/`$Z486_UPSTREAM` supplies. When a pin
    IS named it is still verified against that checkout's HEAD.

    "only in upstream" is the fork-tracked set this repo deliberately does not
    carry; "only in tree" is the PC-98 test/infrastructure set this repo carries
    that the fork does not (added 2026-10-03: the fork dropped them in its rebase
    onto the rewritten upstream, but this platform's benches still name them)."""
    text = doc.read_text(encoding="utf-8")
    m = PIN_RE.search(text)
    pin = m.group(1) if m else None
    lines = text.splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.startswith("### ") and MAP_HEADER in l)
    except StopIteration:
        raise SystemExit(f"FAIL: no '### {MAP_HEADER}' section in {doc}")
    rows: dict[str, str] = {}
    upstream_only: set[str] = set()
    tree_only: set[str] = set()
    explicit_none = False
    for line in lines[start + 1:]:
        if line.startswith("##"):
            break   # the next section (## or ###): this map's table is over
        if not line.startswith("|"):
            if rows:
                break
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 2 or set(cells[0]) <= set("- :"):
            continue
        first, entries = cells[0], cells[1]
        if first.lower().startswith("file"):        # the table header row
            continue
        # An EXPLICIT no-delta row - `| (none) | ... |` - is how a map says the tree is a
        # plain copy of its baseline. It must be written out: a map that merely parsed
        # to nothing (a broken table, a renamed header) is still a failure below.
        if first.lower().strip("`()") == "none":
            explicit_none = True
            continue
        if first.lower().startswith("only in upstream"):
            for f in re.findall(r"`([^`]+)`", first):
                upstream_only.add(f)
            continue
        if first.lower().startswith("only in tree"):
            for f in re.findall(r"`([^`]+)`", first):
                tree_only.add(f)
            continue
        name = first.strip("`")
        if name:
            rows[name] = entries
    if explicit_none and (rows or upstream_only or tree_only):
        raise SystemExit(f"FAIL: the diff map in {doc} has a '(none)' row AND delta rows")
    if not explicit_none and not rows and not upstream_only and not tree_only:
        raise SystemExit(f"FAIL: the diff map in {doc} parsed to zero rows and no "
                         "'only in upstream'/'only in tree' row (a drop-in map has "
                         "zero delta rows but still names its not-carried files, and a "
                         "plain copy says so with a '| (none) | ... |' row)")
    return pin, rows, upstream_only, tree_only


def _tracked(tree: Path) -> set[str] | None:
    """The files git tracks under `tree`, or None if git cannot answer.

    Scoping the walk to TRACKED files is what keeps this check honest in a working
    tree. `make -C src/z486/tests dhrystone` is a REQUIRED gate, and it writes
    `tests/trace.vcd` and `tests/ucode_base.hex` - both of which src/z486/.gitignore
    already declares generated (`*.vcd` at line 3, `tests/ucode*.hex` at line 18). A
    raw filesystem walk reports them as "only in the tree" and fails this check right
    after another gate created them, which would make the two gates a trap in
    sequence. The upstream side is a git checkout too, so both sides are scoped the
    same way; a tree git cannot answer for (the selftest's temp copies) falls back to
    the plain walk.
    """
    try:
        done = subprocess.run(
            ["git", "-C", str(tree), "ls-files", "-z", "--", "."],
            capture_output=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    keep = {p.decode() for p in done.stdout.split(b"\0") if p}
    return keep or None


def walk(tree: Path) -> dict[str, Path]:
    keep = _tracked(tree)
    out: dict[str, Path] = {}
    for p in sorted(tree.rglob("*")):
        if p.is_dir() or any(part in SKIP_DIRS for part in p.parts):
            continue
        rel = str(p.relative_to(tree))
        if keep is not None and rel not in keep:
            continue
        out[rel] = p
    return out


def compare(upstream: Path, tree: Path, rows: dict[str, str], upstream_only: set[str],
            tree_only: set[str]) -> list[str]:
    up, ven = walk(upstream), walk(tree)
    problems: list[str] = []

    differing = sorted(f for f in up.keys() & ven.keys()
                       if up[f].read_bytes() != ven[f].read_bytes())
    missing_up = sorted(up.keys() - ven.keys())
    missing_ven = sorted(ven.keys() - up.keys())

    documented = set(rows)
    for f in differing:
        if f not in documented:
            problems.append(f"UNDOCUMENTED delta: {f} differs from upstream but is not in the map")
    for f in documented:
        if f not in differing:
            problems.append(f"STALE map row: {f} is listed but does not differ from upstream")
    for f in missing_up:
        if f not in upstream_only:
            problems.append(f"UNDOCUMENTED deletion: {f} exists upstream but not in the tree")
    for f in upstream_only:
        if f not in missing_up:
            problems.append(f"STALE map row: {f} is named as not carried but IS present")
    for f in missing_ven:
        if f not in tree_only:
            problems.append(f"UNDOCUMENTED new file: {f} exists only in the tree")
    for f in tree_only:
        if f not in missing_ven:
            problems.append(f"STALE map row: {f} is named as tree-only but is absent")

    # Every local-patch marker must sit in a file the map names.
    for f, p in ven.items():
        if p.suffix not in (".sv", ".svh", ".py", ".hex", ".md", ".gitignore") and p.name != ".gitignore":
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if f in up and up[f].read_bytes() == p.read_bytes():
            continue   # byte-identical to upstream: its markers are upstream's prose
        if MARKER_RE.search(text) and f not in documented:
            problems.append(f"UNDOCUMENTED marker: {f} carries a LOCAL PATCH block and is not in the map")
    return problems


def selftest(upstream: Path, tree: Path, rows: dict[str, str], upstream_only: set[str],
             tree_only: set[str]) -> int:
    """Plant three violations; each must be named. Nothing in the real tree is touched.

    The plants go into a file the map does NOT list (a file that must stay byte-identical
    to upstream), because planting inside a documented file is not a contract violation --
    the contract the document states is per-FILE (the map names the differing files)."""
    failures = 0
    victim_name = next((f for f in walk(tree) if f.endswith(".sv") and f not in rows), None)
    if victim_name is None:
        print("  selftest: no unlisted .sv file to plant into")
        return 1

    def plant(dest: Path, name: str, text: str) -> Path:
        p = dest / name
        p.write_text(p.read_text(encoding="utf-8") + text, encoding="utf-8")
        return p

    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / "z486"
        shutil.copytree(tree, copy, ignore=shutil.ignore_patterns(*SKIP_DIRS))
        plant(copy, victim_name, "\n// planted mutant\n")
        problems = compare(upstream, copy, rows, upstream_only, tree_only)
        if any(victim_name in p and "UNDOCUMENTED delta" in p for p in problems):
            print(f"  selftest A: planted delta in unlisted {victim_name} -> caught")
        else:
            print("  selftest A: FAILED to catch a planted delta"); failures += 1

        copy2 = Path(tmp) / "z486b"
        shutil.copytree(tree, copy2, ignore=shutil.ignore_patterns(*SKIP_DIRS))
        plant(copy2, victim_name, "\n// LOCAL PATCH (PC-9821 core): planted\n")
        problems2 = compare(upstream, copy2, dict(rows), upstream_only, tree_only)
        if any(victim_name in p and "UNDOCUMENTED marker" in p for p in problems2):
            print(f"  selftest B: marker in unlisted {victim_name} -> caught")
        else:
            print("  selftest B: FAILED to catch a marked-file delta"); failures += 1

        # A map row removed for a file that really differs must be reported.
        # The base map may be EMPTY (a drop-in re-vendor), so the differing file
        # is planted (as A) and then documented; with its row removed the
        # compare must report it.
        copy3 = Path(tmp) / "z486c"
        shutil.copytree(tree, copy3, ignore=shutil.ignore_patterns(*SKIP_DIRS))
        plant(copy3, victim_name, "\n// planted mutant\n")
        documented = dict(rows)
        documented[victim_name] = "99"
        clean = compare(upstream, copy3, documented, upstream_only, tree_only)
        trimmed = dict(documented)
        trimmed.pop(victim_name, None)
        problems3 = compare(upstream, copy3, trimmed, upstream_only, tree_only)
        if (not any(victim_name in x for x in clean) and
                any(victim_name in x and "UNDOCUMENTED delta" in x for x in problems3)):
            print(f"  selftest C: a removed map row ({victim_name}) -> caught")
        else:
            print("  selftest C: FAILED to catch a removed map row"); failures += 1

        # A stale row (a file listed that does NOT differ) must be reported.
        extra = dict(rows)
        extra[victim_name] = "99"
        problems4 = compare(upstream, tree, extra, upstream_only, tree_only)
        if any(victim_name in p and "STALE map row" in p for p in problems4):
            print("  selftest D: a row for an unmodified file -> caught")
        else:
            print("  selftest D: FAILED to catch a stale map row"); failures += 1
    return 1 if failures else 0


def default_upstream(start: Path) -> Path | None:
    """The comparison baseline is SUPPLIED, never guessed.

    It comes from `$Z486_UPSTREAM` (or `--upstream`) and from nothing else: this
    repo carries no path to any external checkout and no name is searched for.
    Absent a baseline the check SKIPs loudly (exit 2) - except `--selftest`, which
    falls back to using the tree as its own baseline, because proving the guard can
    still fail needs no external material."""
    import os
    env = os.environ.get("Z486_UPSTREAM")
    return Path(env) if env else None


def main() -> int:
    root = repo_root()
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tree", default=str(root / "src/z486"))
    ap.add_argument("--doc", default=str(root / "docs/z486-local-patch.md"))
    ap.add_argument("--upstream", default=None)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    tree, doc = Path(args.tree), Path(args.doc)
    if not tree.is_dir():
        print(f"FAIL: no vendored tree at {tree}")
        return 2
    pin, rows, upstream_only, tree_only = read_doc(doc)

    upstream = Path(args.upstream) if args.upstream else default_upstream(tree)
    have_upstream = upstream is not None and (upstream / ".git").exists()
    head = None
    if not have_upstream:
        if not args.selftest:
            print(f"SKIP: no upstream checkout at {upstream} (set --upstream or $Z486_UPSTREAM). "
                  f"The map cannot be checked without one -- this is NOT a pass.")
            return 2
        # --selftest needs no external material: the tree is its own baseline and the
        # plants land in UNLISTED files, which is exactly the contract being proved.
        upstream = tree
        print("selftest: no upstream given - using the tree as its own baseline")
    else:
        head = subprocess.run(["git", "-C", str(upstream), "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
        if pin is not None and head != pin:
            print(f"FAIL: the checkout is {head}, the document pins {pin}")
            return 1
        if args.selftest:
            print(f"selftest against {upstream} @ {head[:12]}")

    if args.selftest:
        return selftest(upstream, tree, rows, upstream_only, tree_only)

    problems = compare(upstream, tree, rows, upstream_only, tree_only)
    if problems:
        print(f"FAIL: {len(problems)} problem(s) between {doc} and {tree}")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(f"Z486 PATCH MAP: PASS ({len(rows)} documented files, "
          f"{len(upstream_only)} deliberately not carried, {len(tree_only)} tree-only, "
          f"upstream {(head or '?')[:12]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

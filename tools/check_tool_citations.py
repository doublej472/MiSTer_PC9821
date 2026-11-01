#!/usr/bin/env python3
"""A citation of a tool must name a tool that EXISTS in this repository.

WHY THIS EXISTS. An earlier cleanup moved internal dev tooling out of the tree and left
the citations behind. Twelve in-tree sites named
`tools/check_wiring.py`, ten named `tools/check_telemetry_contract.py`, ten named
`tools/measure.sh`, and the benches and the SDC named more -- and NOTHING could see it,
because a sentence naming a file is not a build input, a port, or a signal: no compiler,
no linter and no bench reads it. A cited verifier that does not exist is a check that
cannot fail, one level up, and the fix was to restore the checkers. Restoring them fixes the sites someone happened
to look at; this is the guard that makes the next one impossible to ship. A path that
does not resolve is now a gate failure, not a sentence a reader has to trust.

WHAT COUNTS AS A CITATION. A `tools/<path>` token with one of TOOL_EXTS, or one that ends
in `/`. The extension test is what keeps prose out: `tools/build` (as in "the build ran")
has no extension, and `tools/hwprobe/` is a directory, so both are recognised for what
they are. A citation of a `.com` is checked against the SOURCE it is built from
(`<dir>/<name>.s`, the rule in tools/hwprobe/Makefile), not against the binary:
tools/hwprobe/README.md is explicit that those binaries are built, never committed.

WHAT IS DELIBERATELY OUT OF SCOPE, each for a reason and not for convenience:
  * docs/probes/*.TXT are RAW real-machine captures. Their text is what the machine or
    the probe printed at capture time, so a path inside one is evidence, not a claim, and
    editing it would be falsifying the capture.
  * vendored trees (src/z486, src/opna, sys/) are byte-identical copies of someone else's
    code and are not ours to edit.
  * a citation in a file under an untracked local `scratch/` -- throwaway analysis, not shipped.

THE TOLERATED LEDGER is site-scoped on purpose: it names the citing FILE and the path it
cites, so a new file citing an absent tool still fails even while an old one is listed.
Every entry a fix the citing file's owner owes, and the entry carries the replacement, so
paying the debt is mechanical. The ledger is SHRINK-ONLY and self-checking: an entry
whose file no longer carries that citation is itself a failure, so the list cannot rot
into a permission.

Usage:
  tools/check_tool_citations.py             check the tree; exit 1 on any violation
  tools/check_tool_citations.py --list      every citation found, and its verdict
  tools/check_tool_citations.py --selftest  plant the defects in a temp tree and require
                                            each to be rejected (the tool's own fail-first
                                            check: a guard that cannot fail is the defect
                                            this file exists to find)
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Where a citation can appear. src/ and tests/ are the RTL and the benches, tools/ and
# docs/ the tooling and the documents about it; the repo root is scanned too, because the
# SDC's own provenance notes cite the STA tools that produced them.
SCAN_DIRS = ("src", "tests", "tools", "docs")
ROOT_FILE_SUFFIXES = {".md", ".sv", ".sdc", ".qsf", ".qip", ".sh", ".py", ".tcl"}

# A `tools/...` token is a citation when it ends in one of these. Fixed rather than
# derived from the tools/ tree: `.tcl` and `.TXT` are cited here and would not be found by
# a dynamic set, and a cited path that does not exist is the whole point.
TOOL_EXTS = {".py", ".sh", ".tcl", ".s", ".md", ".txt", ".bat", ".com", ".cfg",
             ".ld", ".json", ".asm", ".mk"}

# A binary or a build product cannot be a citing document.
SKIP_CITING_SUFFIX = {".rbf", ".sof", ".bin", ".png", ".jpg", ".gif", ".hex", ".mif",
                      ".rpt", ".qpf", ".db", ".pyc", ".pickle", ".gz", ".zip", ".rom",
                      ".com", ".o", ".elf"}
# THIS FILE NAMES THE MISSING PATHS -- in the ledger's reasons and in the account of what
# it was written for -- so it is its own only exception, by NAME and not by directory, the
# same way check_wiring.py excludes itself from its iverilog rule.
SELF = pathlib.Path(__file__).name
SKIP_PARTS = {".git", ".build", "output_files", "build", "__pycache__", "db",
              "incremental_db", "lanes", "mister_deploy", "node_modules", "scratch"}
# Vendored trees: byte-identical copies of someone else's code, not ours to edit (and the
# AGENTS contract makes an edit here a defect on its own).
SKIP_PREFIX = ("sys/", "src/z486/", "src/opna/")

CITATION = re.compile(r"(?<![\w/.-])tools/([A-Za-z0-9_][A-Za-z0-9_./-]*)")

# A `.com` is built from the `.s` beside it by tools/hwprobe/Makefile (`$(1)/$(1).com:
# $(1)/$(1).s`), and the binaries are not committed (tools/hwprobe/README.md: "The binaries are
# not committed."). So the citation is checked against its source.
ARTIFACT_SOURCE = {".com": ".s"}

# THE TOLERATED LEDGER: (citing file, cited path, why it is still there, who owes the fix).
# Nothing here is a tools/ file -- those are fixed, not tolerated.
TOLERATED = (
    # PRINTED PATH STRINGS inside a probe, not prose about one: the banner is a `.ascii`
    # in the source, so changing it changes the built `.com` that the kept captures in
    # docs/probes/ identify themselves by.
    ("tools/hwprobe/idelat/idelat.s", "tools/hwprobe/idelat.s",
     "printed by the probe's banner; the path moved under idelat/ and the fix carries a "
     "binary hash refresh", "hwprobe"),
    ("tools/hwprobe/ideprobe/ideprobe.s", "tools/hwprobe/ideprobe.s",
     "printed by the probe's banner; the path moved under ideprobe/ and the fix carries "
     "a binary hash refresh", "hwprobe"),
    ("tools/hwprobe/ioprobe/ioprobe.s", "tools/hwprobe/ioprobe.s",
     "printed by the probe's banner; the path moved under ioprobe/ and the fix carries a "
     "binary hash refresh", "hwprobe"),
)


def is_exempt(rel: pathlib.Path) -> bool:
    """True for a path (relative to ROOT) that this guard does not scan.

    docs/probes/*.TXT are raw captures, the SKIP_PREFIX trees are vendored copies of someone
    else's code, and the rest is build output, VCS metadata and scratch; see the module
    docstring. The research archive used to be named here as well; it lives outside this
    repository now, so no path relative to ROOT can begin with it and the branch that tested
    for it is gone.
    """
    text = rel.as_posix()
    if rel.suffix.lower() == ".txt" and text.startswith("docs/probes/"):
        return True
    if any(text.startswith(prefix) for prefix in SKIP_PREFIX):
        return True
    return any(part in SKIP_PARTS for part in rel.parts)


def citing_files(root: pathlib.Path) -> list[pathlib.Path]:
    """Every file that may cite a tool, as paths relative to root."""
    out: list[pathlib.Path] = []
    for name in SCAN_DIRS:
        base = root / name
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if not path.is_file() or path.suffix in SKIP_CITING_SUFFIX:
                continue
            rel = path.relative_to(root)
            if not is_exempt(rel) and rel.name != SELF:
                out.append(rel)
    for path in root.iterdir():
        if (path.is_file() and not path.name.startswith(".") and path.name != "Makefile"
                and path.suffix in ROOT_FILE_SUFFIXES):
            out.append(path.relative_to(root))
    return sorted(out)


def citations_in(text: str) -> list[str]:
    """The cited paths in one file's text, in order, de-duplicated."""
    seen: list[str] = []
    for match in CITATION.finditer(text):
        token = match.group(1).rstrip(".,:;`)\"'!?*")
        if not token:
            continue
        if token.endswith("/"):
            if token not in seen:
                seen.append(token)
            continue
        if pathlib.PurePosixPath(token).suffix.lower() not in TOOL_EXTS:
            continue                      # prose, not a citation (see the docstring)
        if token not in seen:
            seen.append(token)
    return seen


def resolves(root: pathlib.Path, cited: str) -> bool:
    """Does the cited path name something this repository has?"""
    target = root / "tools" / cited
    if cited.endswith("/"):
        return target.is_dir()
    if target.exists():
        return True
    # A cited build artifact is judged by the source it is built from (see the docstring).
    if target.suffix in ARTIFACT_SOURCE:
        return target.with_suffix(ARTIFACT_SOURCE[target.suffix]).exists()
    return False


def tolerated(citing: str, cited: str, ledger) -> tuple[str, str] | None:
    """The ledger entry for this site, as (reason, owner), or None."""
    for entry in ledger:
        if entry[0] == citing and entry[1] == cited:
            return entry[2], entry[3]
    return None


def scan(root: pathlib.Path, ledger) -> tuple[list, list]:
    """(violations, tolerated_hits) as lists of (citing, cited, detail)."""
    violations, hits = [], []
    for rel in citing_files(root):
        try:
            text = (root / rel).read_text(errors="ignore")
        except OSError:
            continue
        for cited in citations_in(text):
            if resolves(root, cited):
                continue
            entry = tolerated(rel.as_posix(), f"tools/{cited}", ledger)
            if entry:
                hits.append((rel.as_posix(), f"tools/{cited}", entry[0], entry[1]))
            else:
                violations.append((rel.as_posix(), cited, "no such file"))
    return violations, hits


def stale_ledger(root: pathlib.Path, ledger, hits) -> list:
    """Ledger entries that are no longer true: the citation is gone, or its file is."""
    out = []
    hit_sites = {(c, p) for c, p, _r, _o in hits}
    for citing, cited, _reason, _owner in ledger:
        if not (root / citing).exists():
            out.append(f"{citing}: the file this entry names does not exist")
        elif (citing, cited) not in hit_sites:
            out.append(f"{citing}: no longer cites {cited} -- delete the entry")
    return out


def selftest() -> int:
    """Plant each defect in a temp tree and require the guard to reject it.

    The point of this tool is that a citation to a missing file cannot ship, so the tool
    itself has to be fail-first: a guard whose scanner silently matches nothing would pass
    forever and be exactly the defect it was written to find."""
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "tools").mkdir()
        (root / "tools" / "real_tool.py").write_text("# a tool that exists\n")
        (root / "tests").mkdir()
        (root / "tests" / "planted.sv").write_text(
            "// see tools/real_tool.py (fine) and tools/absent_tool.py (a planted defect)\n")
        (root / "tests" / "fine.sh").write_text("# tools/real_tool.py is all this one cites\n")

        violations, hits = scan(root, ())
        planted = [v for v in violations if v[1] == "absent_tool.py"]
        if not planted:
            failures.append("planted a citation to tools/absent_tool.py and the guard passed it")
        if any(v[1] == "real_tool.py" for v in violations):
            failures.append("the guard rejected a citation to a tool that exists")
        if hits:
            failures.append("the guard matched a ledger entry with an empty ledger")

        # A .com is judged by its source: the build rule in tools/hwprobe/Makefile.
        (root / "tests" / "artifacts.md").write_text(
            "run tools/hwprobe/probe/probe.com after make -C tools/hwprobe\n")
        violations, _ = scan(root, ())
        if not [v for v in violations if v[1].endswith("probe.com")]:
            failures.append("a .com with no .s beside it was accepted")
        (root / "tools" / "hwprobe" / "probe").mkdir(parents=True)
        (root / "tools" / "hwprobe" / "probe" / "probe.s").write_text("; a probe\n")
        violations, _ = scan(root, ())
        if [v for v in violations if v[1].endswith("probe.com")]:
            failures.append("a .com whose .s exists was rejected")

        # The ledger must not be a permission: a site that is NOT listed still fails.
        ledger = (("tests/other.sv", "tools/absent_tool.py", "a reason", "tests"),)
        (root / "tests" / "other.sv").write_text("// tools/absent_tool.py\n")
        violations, hits = scan(root, ledger)
        if [v for v in violations if v[0] == "tests/other.sv"]:
            failures.append("a listed site was still reported as a violation")
        if not [h for h in hits if h[0] == "tests/other.sv"]:
            failures.append("a listed site was not matched to its ledger entry")
        # A ledger entry whose citing file does not exist is stale...
        ghost = ledger + (("tests/ghost.sv", "tools/absent_tool.py", "a reason", "tests"),)
        if not stale_ledger(root, ghost, hits):
            failures.append("a ledger entry naming a file that does not exist was not stale")
        # ...and so is one whose citation has been paid (the file no longer cites it).
        (root / "tests" / "paid.sv").write_text("// this file cites no tool any more\n")
        paid = (("tests/paid.sv", "tools/absent_tool.py", "a reason", "tests"),)
        if not stale_ledger(root, paid, ()):
            failures.append("a paid ledger entry was not reported stale")

        # And the ledger must not cover a DIFFERENT file citing the same path.
        (root / "tests" / "third.sv").write_text("// tools/absent_tool.py\n")
        violations, _ = scan(root, ledger)
        if not [v for v in violations if v[0] == "tests/third.sv"]:
            failures.append("a second file citing a tolerated path was tolerated too")

    if failures:
        print("TOOL CITATION SELFTEST: FAIL")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("TOOL CITATION SELFTEST: PASS (planted defects rejected, honest citations accepted)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--list", action="store_true", help="print every citation and its verdict")
    parser.add_argument("--selftest", action="store_true", help="reject planted bad citations")
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    violations, hits = scan(ROOT, TOLERATED)
    if args.list:
        for rel in citing_files(ROOT):
            for cited in citations_in((ROOT / rel).read_text(errors="ignore")):
                if resolves(ROOT, cited):
                    state = "ok"
                elif tolerated(rel.as_posix(), f"tools/{cited}", TOLERATED):
                    state = "tolerated"
                else:
                    state = "MISSING"
                print(f"{state:<10} {rel}: tools/{cited}")
        print()

    for citing, cited, reason, owner in hits:
        print(f"tolerated  {citing}: {cited} -- {reason} (fixed in: tools/{owner}/)")

    stale = stale_ledger(ROOT, TOLERATED, hits)
    for entry in stale:
        print(f"STALE LEDGER ENTRY: {entry}")
    for citing, cited, detail in violations:
        print(f"MISSING    {citing}: tools/{cited} ({detail})")

    checked = sum(len(citations_in((ROOT / rel).read_text(errors="ignore")))
                  for rel in citing_files(ROOT))
    if violations or stale:
        print(f"\nTOOL CITATION CHECK: FAIL ({len(violations)} citation(s) to a tool that does "
              f"not exist, {len(stale)} stale ledger entry/entries; {checked} citations checked)")
        return 1
    print(f"\nTOOL CITATION CHECK: PASS ({checked} citations checked, "
          f"{len(hits)} tolerated and listed above)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

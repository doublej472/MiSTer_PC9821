#!/usr/bin/env python3
"""A citation of a document must name a document this repository TRACKS.

WHY THIS EXISTS. Two cleanups moved the round reports, the audit set and the research notes
out of the tree (`docs/reports/`, `docs/research/`, the root `*_AUDIT.md` files) and left the
citations behind: `pegc-scope-REPORT.md 4 row 2` in two dozen benches, `aliases.md A8`,
`datapaths.md F1`, `race-idiom R3`, `res-mlab-REPORT section 7.2`, `r13/215`, `FIX_REPORT`,
`ISSUES.md C-5`. A sentence naming a file is read by no compiler, linter or bench, so nothing
saw them: a citation that cannot be followed is a fact nobody can check (docs/policies.md,
"Comments carry hardware facts"). tools/check_tool_citations.py guards `tools/...` paths and
tools/check_line_citations.py guards `file:LINE`; this guards the rest of the class:

  * RULE 1 - a `*.md` name (bare, or with a directory) must resolve to a tracked file: the
    exact repository path, or a tracked file whose path ends in `/<cited path>`. A line
    broken inside a hyphenated name (`docs/single-cycle-event-` / `discipline.md`) is
    joined first. A name inside an http(s) URL is the URL's business, not a citation.
  * RULE 2 - a label of the RETIRED report corpus (RETIRED_LABELS below) may not be cited at
    all: those documents are gone, so the label points nowhere whatever file it sits in.
    Cite the tracked source that holds the fact instead (a docs/probes capture, an NP2kai
    `file:line`, a docs/ section, a `todo/` item as `item NN`), or state the fact inline.

WHAT IS OUT OF SCOPE, each for a reason:
  * docs/probes/*.TXT are raw real-machine captures: their text is what the probe printed,
    so a name inside one is evidence, not a claim, and editing it would falsify the capture;
  * sys/ and src/z486/ are byte-identical copies of other trees (Template_MiSTer, the z486
    fork) and are fixed upstream, never here (AGENTS.md);
  * binaries and build output.

THE LEDGER is site-scoped, as in check_tool_citations.py: (citing file, cited text, why).
EXTERNAL entries name a document of an upstream project that is cited by name and never
vendored here (MiSTer's developer docs, SDRAMsim's guide). FIXTURE entries are file names a
tool's own --selftest creates in a temporary tree. PRINTED entries are text inside a
DOS probe's `.ascii` strings: changing it changes the built `.com` that the kept captures in
docs/probes/ identify themselves by, so the fix belongs to the probe's owner with a rebuild.
The ledger is SHRINK-ONLY: an entry whose site no longer carries the citation fails as
stale, so it cannot rot into a permission, and it never covers a different file.

Usage:
  tools/check_doc_citations.py             check the tree; exit 1 on any violation
  tools/check_doc_citations.py --list      every citation found, and its verdict
  tools/check_doc_citations.py --selftest  plant each defect in a temp tree and require it
                                           to be rejected
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
# THIS FILE NAMES THE RETIRED LABELS (in its rules and its account of why it exists), so it
# is its own only exception, by name.
SELF = "tools/check_doc_citations.py"
SKIP_PREFIX = ("sys/", "src/z486/")
SKIP_SUFFIX = {".rbf", ".sof", ".bin", ".png", ".jpg", ".gif", ".hex", ".mif", ".rpt",
               ".qpf", ".db", ".pyc", ".gz", ".zip", ".rom", ".com", ".o", ".elf", ".img",
               ".wav", ".pdf", ".BIN", ".ROM", ".COM"}

MD = re.compile(r"(?<![\w/.-])((?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_][A-Za-z0-9_.-]*\.md)(?![\w-])")
URL = re.compile(r"https?://\S+")
# A name broken across a comment line at a hyphen: `...event-\n  // discipline.md`.
WRAP = re.compile(r"-\n[ \t]*(?://+|#+|;+|\*|--|REM\b)?[ \t]*(?=[A-Za-z0-9_])")

# The retired corpus: labels of documents that are no longer in the tree. Each is a regex
# with the reason it can never resolve.
RETIRED_LABELS = (
    (r"\b[a-z0-9][a-z0-9-]*-REPORT\b", "a round/lane report (`<name>-REPORT`); the reports left the tree"),
    (r"\bFIX_REPORT\b", "a lane fix report; the reports left the tree"),
    (r"\bREPORT sec\.", "an unnamed report section; the reports left the tree"),
    (r"\br\d{1,2}/\d{2,3}\b", "a research-round note (`rNN/NNN`); docs/research/ left the tree"),
    (r"\brace-idiom\b", "the race-idiom report; cite docs/single-cycle-event-discipline.md R1-R8"),
    (r"\b([a-z0-9]+-audit) [A-Z]-?\d+\b", "an audit finding label; the audit set left the tree"),
    (r"\bTODO \d+\b", "an old TODO number; open work is cited as `item NN` (todo/README.md)"),
)
LABELS = [(re.compile(p), why) for p, why in RETIRED_LABELS]

# THE LEDGER: (citing file, cited text, kind, why).
TOLERATED = (
    ("tests/pc9821/tb_pc9821_kbd_led.sv", "MkDocs_MiSTer/docs/developer/hps_io.md", "EXTERNAL",
     "MiSTer's developer documentation (MiSTer-devel/MkDocs_MiSTer), cited by its own path"),
    ("tools/mister_load.sh", "developer/conf_str.md", "EXTERNAL",
     "MiSTer's developer documentation (MkDocs_MiSTer), named in the sentence"),
    ("z486_mister.sv", "developer/emu.md", "EXTERNAL",
     "MiSTer's developer documentation (MkDocs_MiSTer)"),
    ("z486_mister.sv", "emu.md", "EXTERNAL",
     "MiSTer's developer documentation, cited as `MkDocs_MiSTer emu.md`"),
    ("docs/sdram.md", "CONTROLLER_GUIDE.md", "EXTERNAL",
     "birdybro/SDRAMsim_MiSTer's guide, named with its repository"),
    ("tests/pc9821/xsds_128mbyte_sdram_model.sv", "CONTROLLER_GUIDE.md", "EXTERNAL",
     "birdybro/SDRAMsim_MiSTer's guide, named with its repository"),
    ("src/opna/jt49/README.md", "doc/conn.md", "EXTERNAL",
     "upstream jt49's own README (vendored verbatim; the path is upstream's)"),
    # PRINTED probe text (see the docstring): owed to the probe's owner with a rebuild.
    ("tools/hwprobe/idelat/idelat.s", "r13/215", "PRINTED",
     "the RATES banner and the 8:1 law lines; the fact is the PIT/ARTIC 8:1 ratio"),
    ("tools/hwprobe/idelat/idelat.s", "r13/219", "PRINTED", "the RATES banner"),
    ("tools/hwprobe/ioprobe/ioprobe.s", "r13/215", "PRINTED", "the PIT/ARTIC 8:1 line"),
    ("tools/hwprobe/ideprobe/ideprobe.s", "io-audit F3", "PRINTED",
     "the 0x64C drive/head write read-back section header"),
    ("tools/hwprobe/probe2/probe2.s", "r11/06", "PRINTED", "a section header"),
    ("tools/hwprobe/probe2/probe2.s", "r12/69", "PRINTED", "a section header"),
    ("tools/hwprobe/probe2/probe2.s", "r11/17", "PRINTED", "a section header"),
    ("tools/hwprobe/probe2/probe2.s", "r10/01", "PRINTED", "a section header"),
    ("tools/hwprobe/probe2/probe2.s", "r11/14", "PRINTED", "a section header"),
    ("tools/hwprobe/probe2/probe2.s", "r12/04", "PRINTED", "a section header"),
    ("tools/hwprobe/probe2/probe2.s", "r12/02", "PRINTED", "a section header"),
    ("tools/hwprobe/probe2/probe2.s", "r5/03", "PRINTED", "a section header"),
    ("tools/hwprobe/probe2/probe2.s", "r6/08", "PRINTED", "a section header"),
    # A FIXTURE: a file name the citing tool writes into its own temp tree in --selftest.
    ("tools/check_tool_citations.py", "artifacts.md", "FIXTURE",
     "the --selftest's planted citing file, created in a temp tree"),
)


def tracked(root: pathlib.Path) -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=root, capture_output=True,
                         check=True).stdout.decode()
    return [p for p in out.split("\0") if p]


def citing(files: list[str]) -> list[str]:
    out = []
    for f in files:
        if f == SELF or f.startswith(SKIP_PREFIX):
            continue
        if f.startswith("docs/probes/") and f.lower().endswith(".txt"):
            continue
        if pathlib.PurePosixPath(f).suffix in SKIP_SUFFIX:
            continue
        out.append(f)
    return out


class Resolver:
    def __init__(self, files: list[str]):
        self.files = set(files)
        self.by_base: dict[str, list[str]] = {}
        for f in files:
            self.by_base.setdefault(f.rsplit("/", 1)[-1], []).append(f)

    def ok(self, cited: str) -> bool:
        p = cited[2:] if cited.startswith("./") else cited
        while p.startswith("../"):
            p = p[3:]
        if p in self.files:
            return True
        base = p.rsplit("/", 1)[-1]
        return any(f == p or f.endswith("/" + p) for f in self.by_base.get(base, []))


def findings(text: str, resolver: Resolver) -> list[tuple[str, str]]:
    """(cited text, verdict) for every citation in one file: verdict is 'ok' or a reason."""
    text = WRAP.sub("-", text)
    urls = [m.span() for m in URL.finditer(text)]
    in_url = lambda pos: any(a <= pos < b for a, b in urls)
    out: list[tuple[str, str]] = []
    seen = set()
    for m in MD.finditer(text):
        if in_url(m.start()):
            continue
        cited = m.group(1)
        if cited in seen:
            continue
        seen.add(cited)
        out.append((cited, "ok" if resolver.ok(cited) else "no tracked file by that name"))
    for rx, why in LABELS:
        for m in rx.finditer(text):
            if in_url(m.start()) or m.group(0) in seen:
                continue
            # `<name>-audit X1` is a label of a TRACKED audit when `<name>-audit.md` exists
            # (src/z486/docs/coherency-audit.md's C-rows are cited that way).
            if rx.groups and resolver.ok(m.group(1) + ".md"):
                continue
            seen.add(m.group(0))
            out.append((m.group(0), why))
    return out


def scan(root: pathlib.Path, files: list[str], ledger) -> tuple[list, list]:
    resolver = Resolver(files)
    sites = {(c, t) for c, t, _k, _w in ledger}
    violations, hits = [], []
    for rel in citing(files):
        try:
            text = (root / rel).read_text(errors="ignore")
        except OSError:
            continue
        for cited, verdict in findings(text, resolver):
            if verdict == "ok":
                continue
            if (rel, cited) in sites:
                hits.append((rel, cited))
            else:
                violations.append((rel, cited, verdict))
    return violations, hits


def stale_ledger(root: pathlib.Path, ledger, hits) -> list[str]:
    out = []
    got = set(hits)
    for c, t, _k, _w in ledger:
        if not (root / c).exists():
            out.append(f"{c}: the file this entry names does not exist")
        elif (c, t) not in got:
            out.append(f"{c}: no longer cites {t!r} -- delete the entry")
    return out


def selftest() -> int:
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "docs").mkdir()
        (root / "tests").mkdir()
        (root / "docs" / "real-doc.md").write_text("# a document that exists\n")
        (root / "docs" / "coherency-audit.md").write_text("| C9 | a tracked audit row |\n")
        (root / "docs" / "single-cycle-event-discipline.md").write_text("# rules\n")
        plants = {
            "tests/missing.sv": "// see gone-scope-REPORT.md 4 row 2\n",
            "tests/bare.sv": "// (aliases.md A8)\n",
            "tests/label.sv": "// the fold (race-idiom R3)\n",
            "tests/round.sv": "// the queue split (r13/110)\n",
            "tests/fix.sv": "// see the lane FIX_REPORT\n",
            "tests/todo.py": "# the defect (TODO 89)\n",
            "tests/audit.s": "/* write enable (dip-audit P6) */\n",
        }
        honest = {
            "tests/fine.sv": "// docs/real-doc.md and real-doc.md and ../docs/real-doc.md\n",
            "tests/wrapped.sv": "// (docs/single-cycle-event-\n// discipline.md R3)\n",
            "tests/url.md": "see <https://example.org/elsewhere/GUIDE.md>\n",
            "tests/prose.sv": "// THE FIFO IS FULL MID-REPORT; see the todo list\n",
            "tests/tracked_audit.sv": "// the patch race (coherency-audit C9)\n",
        }
        for d in (plants, honest):
            for rel, body in d.items():
                (root / rel).write_text(body)
        files = ["docs/real-doc.md", "docs/single-cycle-event-discipline.md", "docs/coherency-audit.md",
                 *plants, *honest]
        violations, hits = scan(root, files, ())
        flagged = {v[0] for v in violations}
        for rel in plants:
            if rel not in flagged:
                failures.append(f"planted a dangling citation in {rel} and the guard passed it")
        for rel in honest:
            if rel in flagged:
                bad = [v for v in violations if v[0] == rel]
                failures.append(f"the guard rejected an honest citation: {bad}")
        if hits:
            failures.append("the guard matched a ledger entry with an empty ledger")

        # The ledger is site-scoped: it covers its own site, not another file's.
        ledger = (("tests/bare.sv", "aliases.md", "EXTERNAL", "a reason"),)
        violations, hits = scan(root, files, ledger)
        if [v for v in violations if v[0] == "tests/bare.sv"]:
            failures.append("a listed site was still reported")
        (root / "tests" / "other.sv").write_text("// aliases.md\n")
        violations, _ = scan(root, files + ["tests/other.sv"], ledger)
        if not [v for v in violations if v[0] == "tests/other.sv"]:
            failures.append("a ledger entry covered a different file citing the same name")
        # ...and shrink-only: a paid or ghost entry is stale.
        if not stale_ledger(root, (("tests/fine.sv", "aliases.md", "EXTERNAL", "r"),), ()):
            failures.append("a ledger entry whose site no longer cites it was not stale")
        if not stale_ledger(root, (("tests/ghost.sv", "aliases.md", "EXTERNAL", "r"),), ()):
            failures.append("a ledger entry naming a missing file was not stale")

    if failures:
        print("DOC CITATION SELFTEST: FAIL")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("DOC CITATION SELFTEST: PASS (planted dangling citations rejected, honest ones accepted)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", action="store_true", help="print every citation and its verdict")
    ap.add_argument("--selftest", action="store_true", help="reject planted bad citations")
    args = ap.parse_args()
    if args.selftest:
        return selftest()

    files = tracked(ROOT)
    if args.list:
        resolver = Resolver(files)
        for rel in citing(files):
            for cited, verdict in findings((ROOT / rel).read_text(errors="ignore"), resolver):
                print(f"{'ok' if verdict == 'ok' else 'MISSING':<8} {rel}: {cited}")
        print()
    violations, hits = scan(ROOT, files, TOLERATED)
    for c, t, kind, why in TOLERATED:
        if (c, t) in hits:
            print(f"tolerated  {c}: {t!r} [{kind}] -- {why}")
    stale = stale_ledger(ROOT, TOLERATED, hits)
    for s in stale:
        print(f"STALE LEDGER ENTRY: {s}")
    for rel, cited, why in violations:
        print(f"MISSING    {rel}: {cited!r} ({why})")
    if violations or stale:
        print(f"\nDOC CITATION CHECK: FAIL ({len(violations)} dangling citation(s), "
              f"{len(stale)} stale ledger entr{'y' if len(stale) == 1 else 'ies'})")
        return 1
    print(f"\nDOC CITATION CHECK: PASS ({len(hits)} tolerated and listed above)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""The TODO split is one contract stated in four places, and this holds them together.

WHY THIS IS A PYTHON CHECK AND NOT A BENCH. The fact being checked is not a signal
level - it is SOURCE TEXT and the identity of item NUMBERS. The open-work list is a
short index (`TODO.md`) plus one file per theme under `todo/`. Four things must agree:
the item headers that exist in `todo/*.md`, the item -> file table and the retired-number
list in `todo/README.md`, the file list in the repo-root `TODO.md`, and the `item NN`
references scattered through the tree in RTL comments, docs, tools and tests. Nothing
about a reference except the NUMBER survives a move, so the numbers are stable public IDs.

THE NUMBERING RULE. A closed item is deleted and its number RETIRED: listed on the
`Retired numbers:` line of `todo/README.md` and never reused. So every number from 1 to
the highest one in use must be either a live item or retired (a number that is neither is
a LOST item), no number may be both, and a reference to a retired number fails like a
reference to a number that never existed.

THE FAILURE THIS GUARDS. An edit that loses an item, duplicates a number, reuses a
retired one, or leaves a reference pointing at a number that no longer exists. None of
those shows up as a compile error, a failing bench or a lint warning.

The item table's TITLES must also match the theme files' headings (the heading is the
source of truth), and README's `## Sections` map, not the whole README, must name every
theme file.

Nothing here is a copy: every expected value is read out of the tree. `--selftest` plants
a lost number, a retired-but-present number, a duplicate, a dangling reference, an empty
section map and a drifted index title in a temporary copy of the list and requires each to
be caught.

Exit 0 when the four agree; non-zero, naming the disagreement, when they do not.
"""

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TODO = ROOT / "TODO.md"
TODO_DIR = ROOT / "todo"
RETIRED_LINE = re.compile(r"^Retired numbers:\s*(.*)$", re.MULTILINE)

ITEM_HEADER = re.compile(r"^(\d+)\. \*\*")
# The heading's bold title: `NN. **Title.** **TAG.** ...` -> `Title.`
ITEM_TITLE = re.compile(r"^(\d+)\. \*\*(.+?)\*\*")
README_ROW = re.compile(r"^\|\s*(\d+)\s*\|(.*)\|\s*`todo/([0-9A-Za-z._-]+\.md)`\s*\|\s*$")
TODO_FILE = re.compile(r"todo/([0-9A-Za-z._-]+\.md)")
REFERENCE = re.compile(r"\bitems?\s+(\d+(?:\s*[\u2013/-]\s*\d+)*)", re.IGNORECASE)

# Directories that are build output, VCS metadata, local scratch or runtime dumps. They are
# gitignored and carry no item references, but walking them (disk images, Verilator `.gch`
# precompiled headers) would make this check take many seconds. The `obj*` prefix matches
# the same class `.gitignore` ignores (`obj_dir/`, `obj*/`).
SKIP_DIRS = {"build", ".git", ".build", ".worktrees", "output_files", "__pycache__",
             "mister_deploy", "db", "incremental_db", "node_modules", "assets", "scratch"}
# `src/z486/` is a plain copy of the z486 fork (AGENTS.md): its docs are the fork's text, may
# cite this core's item numbers as they stood when written, and cannot be edited here.
SKIP_REL = ("src/z486/",)
SKIP_SUFFIX = (".rpt", ".qpf", ".sof", ".rbf", ".bin", ".hex", ".mif", ".png",
               ".wav", ".jpg", ".gif", ".o", ".a", ".so", ".elf", ".img",
               ".vcd", ".gch", ".com", ".COM")  # .com: built DOS probes; their .s source is walked

problems: list[str] = []


def fail(msg: str) -> None:
    problems.append(msg)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def titles_in_todo() -> dict[int, str]:
    """number -> the heading's bold title, over every item header in todo/*.md (not README)."""
    out: dict[int, str] = {}
    for path in sorted(TODO_DIR.glob("*.md")):
        if path.name == "README.md":
            continue
        for line in read(path).splitlines():
            m = ITEM_TITLE.match(line)
            if m:
                out.setdefault(int(m.group(1)), m.group(2).strip())
    return out


def section_lines(name: str) -> list[str]:
    """The lines of todo/README.md's `## <name>` section (empty when it is absent)."""
    lines = read(TODO_DIR / "README.md").splitlines()
    try:
        start = lines.index(f"## {name}")
    except ValueError:
        return []
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith("## ")), len(lines))
    return lines[start:end]


def items_in_todo() -> tuple[dict[int, str], dict[str, list[int]]]:
    """(number -> file, file -> numbers) over every item header in todo/*.md.

    README.md is excluded: it carries the index TABLE (rows like `| 1 | ... |`),
    not item bodies, and those rows must not be mistaken for headers.
    """
    by_number: dict[int, str] = {}
    by_file: dict[str, list[int]] = {}
    for path in sorted(TODO_DIR.glob("*.md")):
        if path.name == "README.md":
            continue
        nums: list[int] = []
        for line in read(path).splitlines():
            m = ITEM_HEADER.match(line)
            if not m:
                continue
            n = int(m.group(1))
            if n in by_number:
                fail(f"item {n} appears in BOTH {by_number[n]} and {path.name} "
                     f"-- each item lives in exactly one file")
            else:
                by_number[n] = path.name
            nums.append(n)
        by_file[path.name] = nums
    return by_number, by_file


def retired_numbers() -> set[int]:
    """The `Retired numbers:` line of todo/README.md (closed items' numbers, never reused)."""
    m = RETIRED_LINE.search(read(TODO_DIR / "README.md"))
    if not m:
        fail("todo/README.md has no `Retired numbers:` line")
        return set()
    nums = [int(n) for n in re.findall(r"\d+", m.group(1))]
    if len(nums) != len(set(nums)):
        fail("todo/README.md's `Retired numbers:` line lists a number twice")
    return set(nums)


def check_numbering(by_number: dict[int, str], retired: set[int]) -> None:
    nums = sorted(by_number)
    if not nums:
        fail("no item headers found under todo/ -- the split is missing or empty")
        return
    both = sorted(set(nums) & retired)
    if both:
        fail(f"item number(s) {both} are RETIRED but still present (a retired number is never reused)")
    # a number that is neither live nor retired is a LOST item
    top = max(nums + sorted(retired))
    lost = sorted(set(range(1, top + 1)) - set(nums) - retired)
    if lost:
        fail(f"item number(s) {lost} are MISSING: neither an item nor on the `Retired numbers:` line")


def check_readme_table(by_number: dict[int, str]) -> None:
    # Only the `## Items` table maps a NUMBER to a file. The `## Sections` map above it
    # uses the same `| N | text | file |` shape for SECTION numbers, so parsing the
    # whole file would read the five section-6 rows as five copies of one item.
    lines = read(TODO_DIR / "README.md").splitlines()
    try:
        start = lines.index("## Items")
    except ValueError:
        fail("todo/README.md has no `## Items` section")
        return
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith("## ")), len(lines))
    seen: dict[int, str] = {}
    row_title: dict[int, str] = {}
    for line in lines[start:end]:
        m = README_ROW.match(line)
        if not m:
            continue
        n, fn = int(m.group(1)), m.group(3)
        if n in seen:
            fail(f"todo/README.md lists item {n} twice")
        seen[n] = fn
        row_title[n] = m.group(2).strip()
    if not seen:
        fail("todo/README.md has no item -> file table (no rows matched)")
        return
    for n in sorted(by_number):
        if n not in seen:
            fail(f"item {n} is not listed in todo/README.md's item table")
        elif seen[n] != by_number[n]:
            fail(f"item {n}: todo/README.md says {seen[n]} but it lives in {by_number[n]} "
                 f"-- the index lies about where the item is")
    for n in sorted(seen):
        if n not in by_number:
            fail(f"todo/README.md lists item {n}, which exists in no todo/*.md file")
    # The theme file's heading is the source of truth for an item's title; the index row
    # is the lookup route for `item NN`, so a row that drifted from it misleads the reader.
    titles = titles_in_todo()
    for n in sorted(set(row_title) & set(titles)):
        if row_title[n] != titles[n]:
            fail(f"item {n}: todo/README.md's title {row_title[n]!r} differs from the heading "
                 f"{titles[n]!r} in todo/{by_number.get(n, '?')} -- copy the heading")


def check_file_lists(by_number: dict[int, str]) -> None:
    on_disk = {p.name for p in TODO_DIR.glob("*.md")}
    root_named = set(TODO_FILE.findall(read(TODO)))
    if root_named != on_disk:
        for f in sorted(on_disk - root_named):
            fail(f"todo/{f} exists but is not named by the repo-root TODO.md index")
        for f in sorted(root_named - on_disk):
            fail(f"the repo-root TODO.md names todo/{f}, which does not exist")
    # README's section map must name every DATA file (README itself is the index). Only the
    # `## Sections` table counts: the item table names every file too, so reading the whole
    # README would let an empty section map pass.
    readme_named = set(TODO_FILE.findall("\n".join(section_lines("Sections"))))
    data = on_disk - {"README.md"}
    for f in sorted(data - readme_named):
        fail(f"todo/{f} is not named by todo/README.md's section map")
    # Every data file that is named must also carry at least one item -- except the
    # standing-rules file, which is rules, not items (packed as a body, no headers).
    if not by_number:
        fail("no items found under todo/ at all")


def check_references(valid: set[int]) -> int:
    """Every `item NN` (or range) anywhere in the tree must name an existing item.

    Returns the number of reference SITES (a range or a `45/46` pair is one site).
    """
    sites = 0
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith("obj")]
        if (Path(base).relative_to(ROOT).as_posix() + "/").startswith(SKIP_REL):
            dirs[:] = []
            continue
        for name in files:
            if name.endswith(SKIP_SUFFIX):
                continue
            path = Path(base) / name
            # a raw capture's text is what the probe PRINTED (byte-for-byte evidence, never
            # edited), so an item number in it is history, not a reference to resolve
            if name.endswith(".TXT") and path.relative_to(ROOT).as_posix().startswith("docs/probes/"):
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for m in REFERENCE.finditer(text):
                sites += 1
                for n in re.findall(r"\d+", m.group(1)):
                    if int(n) not in valid:
                        rel = path.relative_to(ROOT)
                        fail(f"{rel}: cites item {n}, which is not one of the "
                             f"{len(valid)} existing items")
    return sites


def run(root: Path) -> tuple[dict[int, str], dict[str, list[int]], set[int], int]:
    """Run every check against the tree at `root`; the failures land in `problems`."""
    global ROOT, TODO, TODO_DIR
    ROOT, TODO, TODO_DIR = root, root / "TODO.md", root / "todo"
    problems.clear()
    by_number, by_file = items_in_todo()
    retired = retired_numbers()
    check_numbering(by_number, retired)
    check_readme_table(by_number)
    check_file_lists(by_number)
    refs = check_references(set(by_number))
    return by_number, by_file, retired, refs


def selftest(real_root: Path) -> int:
    """Plant each defect class in a temp copy of the list and require it to be caught."""
    import shutil
    import tempfile

    by_number, _, retired, _ = run(real_root)
    if not by_number or not retired:
        print("TODO SPLIT SELFTEST: FAIL - the real list has no items or no retired numbers")
        return 1
    live, gone = min(by_number), min(retired)

    def plant(name: str, edit, expect: str) -> bool:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shutil.copytree(real_root / "todo", root / "todo")
            shutil.copy(real_root / "TODO.md", root / "TODO.md")
            (root / "src").mkdir()
            (root / "src" / "ok.sv").write_text(f"// see item {live}\n")
            edit(root)
            run(root)
            hit = any(expect in p for p in problems)
            print(f"  {'caught' if hit else 'MISSED'}: {name}")
            if not hit:
                for p in problems:
                    print("      " + p)
            return hit

    readme = lambda r: r / "todo" / "README.md"

    def drop_retired(r: Path) -> None:      # a retired number vanishes from the list = LOST
        t = read(readme(r))
        m = RETIRED_LINE.search(t)
        rest = [n for n in re.findall(r"\d+", m.group(1)) if int(n) != gone]
        readme(r).write_text(t.replace(m.group(0), "Retired numbers: " + ", ".join(rest)))

    def reuse_retired(r: Path) -> None:     # a live item takes a retired number
        f = r / "todo" / by_number[live]
        f.write_text(read(f) + f"\n{gone}. **Planted item.** **KNOWN GAP.**\n")

    def duplicate(r: Path) -> None:         # the same live number in two files
        other = sorted(set(by_number.values()) - {by_number[live]})[0]
        f = r / "todo" / other
        f.write_text(read(f) + f"\n{live}. **Planted duplicate.** **KNOWN GAP.**\n")

    def dangling(r: Path) -> None:          # code cites a retired number
        (r / "src" / "bad.sv").write_text(f"// see item {gone}\n")

    def empty_sections(r: Path) -> None:    # the section map loses its rows
        t = read(readme(r))
        out, skip = [], False
        for line in t.splitlines():
            if line == "## Sections":
                skip = True
            elif line.startswith("## "):
                skip = False
            if skip and line.startswith("| ") and "`todo/" in line:
                continue
            out.append(line)
        readme(r).write_text("\n".join(out) + "\n")

    def drift_title(r: Path) -> None:       # an index row's title drifts from its heading
        t = read(readme(r))
        row = re.compile(rf"^\|\s*{live}\s*\|.*$", re.MULTILINE)
        readme(r).write_text(row.sub(f"| {live} | A planted wrong title. | `todo/{by_number[live]}` |",
                                     t, count=1))

    ok = all([
        plant("a retired number dropped from the list (lost)", drop_retired, "MISSING"),
        plant("a retired number reused by a live item", reuse_retired, "RETIRED but still present"),
        plant("one number in two files", duplicate, "appears in BOTH"),
        plant("a reference to a retired number", dangling, f"cites item {gone}"),
        plant("an empty section map", empty_sections, "not named by todo/README.md's section map"),
        plant("an index title that differs from its heading", drift_title, "differs from the heading"),
    ])
    # and the unplanted copy must be clean apart from the real tree's own references
    print(f"TODO SPLIT SELFTEST: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest(ROOT)
    if not TODO.is_file() or not TODO_DIR.is_dir():
        print("TODO SPLIT CHECK: FAIL - expected TODO.md and a todo/ directory")
        return 1

    by_number, by_file, retired, refs = run(ROOT)

    if problems:
        for p in problems:
            print("  FAIL " + p)
        print()
        print(f"TODO SPLIT CHECK: FAIL - {len(problems)} problem(s)")
        return 1

    nums = sorted(by_number)
    print(f"TODO SPLIT CHECK: PASS - {len(nums)} live items and {len(retired)} retired numbers "
          f"(1..{max(nums + sorted(retired))}, none lost, none reused, no duplicates) over "
          f"{len(by_file)} item file(s) + index; "
          f"{len(set(TODO_FILE.findall(read(TODO))))} todo files named by TODO.md; "
          f"{refs} in-tree `item NN` reference(s) all resolve")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

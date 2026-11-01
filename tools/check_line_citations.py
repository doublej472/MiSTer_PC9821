#!/usr/bin/env python3
"""Every `path:LINE` citation of a file in this repository must still point at its fact.

docs/policies.md asks a `file:NNN` citation to quote a short fragment of the target line so a
reader can check it by eye. A line number goes stale whenever the cited file moves, and
nothing else in the gates reads a sentence, so this resolver does it:

  * it finds every `path:LINE`, `path:A-B` and `path:N,M` / `path:N/M` citation in the
    tracked files (a bare `:N` in backticks after a citation on the same line cites the
    same file);
  * it resolves `path` against the tracked files: an exact repository path, else the one
    tracked file whose path ends in `/path`. A path no tracked file matches is EXTERNAL
    (NP2kai, MAME, Quartus, ... are not vendored here) and is skipped, never failed;
    a path several tracked files match is checked against each and passes if any fits;
  * it requires every cited line to exist (and a range to run forwards);
  * when the citation quotes a fragment right after it - `` `...` ``, "..." or (...),
    with an optional `, ` between - it requires that fragment (whitespace collapsed; a
    `...` inside it splits it into pieces that must each appear) on the cited lines or
    within +-WINDOW lines of them. A parenthesised text counts as a fragment only when it
    looks like code (holds one of CODE_CHARS), so prose in brackets is not a quote.

Citing files: tracked text files outside the vendored trees (src/z486, sys, src/opna,
which may be CITED) and outside docs/probes (raw captures, evidence, never edited).

Usage:
  tools/check_line_citations.py             check the tree; exit 1 on any failure
  tools/check_line_citations.py --list      every in-repo citation and its verdict
  tools/check_line_citations.py --selftest  plant a bad line, an out-of-range line and a
                                            wrong fragment, and require each to fail
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
WINDOW = 3
SKIP_CITING_PREFIX = ("sys/", "src/z486/", "src/opna/", "docs/probes/")
SELF = "tools/check_line_citations.py"
CODE_CHARS = set("=;[]<>_`'{}|&!") | {"(", "->", "::"}

# path:LINE, path:A-B, path:N,M,... / path:N/:M. The path ends in a name with an
# extension; the extension starts with a letter so `1.5:2` is not a citation.
CITE = re.compile(
    r"(?<![\w/.-])((?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_-][A-Za-z0-9_.-]*\.[A-Za-z][A-Za-z0-9]*)"
    r":(\d+(?:-\d+)?(?:[,/]:?\d+(?:-\d+)?)*)(?![\w.:])")
BARE = re.compile(r"`:(\d+(?:-\d+)?)`")
FRAG = re.compile(r"""\A`?(?:,\s*|\s+)(?:`([^`]{1,200})`|"([^"]{1,200})"|\(([^()]{1,200})\))""")


def tracked(root: pathlib.Path) -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=root, capture_output=True,
                         check=True).stdout.decode()
    return [p for p in out.split("\0") if p]


class Resolver:
    def __init__(self, root: pathlib.Path, files: list[str]):
        self.root = root
        self.files = set(files)
        self.by_base: dict[str, list[str]] = {}
        for f in files:
            self.by_base.setdefault(f.rsplit("/", 1)[-1], []).append(f)
        self.cache: dict[str, list[str] | None] = {}

    def resolve(self, path: str) -> list[str]:
        p = path.lstrip("./") if path.startswith("./") else path
        if p in self.files:
            return [p]
        base = p.rsplit("/", 1)[-1]
        return [f for f in self.by_base.get(base, []) if f == p or f.endswith("/" + p)]

    def lines(self, f: str) -> list[str] | None:
        if f not in self.cache:
            try:
                # split on LF only: str.splitlines() also breaks at \x1c-\x1e and
                # \x85, which the raw probe captures hold as data bytes
                text = (self.root / f).read_bytes().decode("utf-8", errors="replace")
                self.cache[f] = [l.rstrip("\r") for l in text.split("\n")]
                if self.cache[f] and self.cache[f][-1] == "":
                    self.cache[f].pop()
            except OSError:
                self.cache[f] = None
        return self.cache[f]


def norm(s: str) -> str:
    return " ".join(s.split())


def parse_ranges(spec: str) -> list[tuple[int, int]]:
    out = []
    for part in re.split(r"[,/]:?", spec):
        a, _, b = part.partition("-")
        out.append((int(a), int(b) if b else int(a)))
    return out


def looks_like_code(s: str) -> bool:
    return any(c in s for c in CODE_CHARS)


def check_one(res: Resolver, target: str, ranges, frag: str | None) -> str | None:
    """None when the citation holds against `target`, else the reason it does not."""
    lines = res.lines(target)
    if lines is None:
        return "unreadable"
    n = len(lines)
    for a, b in ranges:
        if a < 1 or b < a:
            return f"bad range {a}-{b}"
        if b > n:
            return f"line {b} past the end ({n} lines)"
    if frag is None:
        return None
    pieces = [norm(x) for x in frag.split("...") if norm(x).strip(" .")]
    if not pieces:
        return None
    for a, b in ranges:
        lo, hi = max(1, a - WINDOW), min(n, b + WINDOW)
        text = norm(" ".join(lines[lo - 1:hi]))
        line_by_line = [norm(l) for l in lines[lo - 1:hi]]
        if all(p in text or any(p in l for l in line_by_line) for p in pieces):
            return None
    return f"fragment {frag!r} not within {WINDOW} lines"


def scan(root: pathlib.Path, files: list[str] | None = None):
    files = files if files is not None else tracked(root)
    res = Resolver(root, files)
    results = []  # (citing, lineno, cite_text, target_or_None, verdict_or_None)
    for f in files:
        if f.startswith(SKIP_CITING_PREFIX) or f == SELF:
            continue
        try:
            raw = (root / f).read_bytes()
        except OSError:
            continue
        if b"\0" in raw[:4096]:
            continue
        text = raw.decode("utf-8", errors="replace")
        for ln, line in enumerate(text.split("\n"), 1):
            last_targets: list[str] = []
            spans = []
            for m in CITE.finditer(line):
                targets = res.resolve(m.group(1))
                if not targets:
                    last_targets = []
                    continue
                spans.append((m, targets))
                last_targets = targets
                tail = line[m.end():]
                fm = FRAG.match(tail)
                frag = None
                if fm:
                    if fm.group(1) is not None:
                        frag = fm.group(1)
                    elif fm.group(2) is not None:
                        frag = fm.group(2)
                    else:
                        inner = re.search(r"`([^`]+)`", fm.group(3))
                        if inner:
                            frag = inner.group(1)
                        elif looks_like_code(fm.group(3)):
                            frag = fm.group(3)
                if frag is not None and (re.fullmatch(r":\d+(?:-\d+)?", frag)
                                         or CITE.search(frag)):
                    frag = None  # the next citation, not a quote
                ranges = parse_ranges(m.group(2))
                why = [check_one(res, t, ranges, frag) for t in targets]
                verdict = None if any(w is None for w in why) else why[0]
                results.append((f, ln, m.group(0) + (f" {frag!r}" if frag else ""),
                                targets[0], verdict))
                # a bare `:N` right after this one cites the same file
                for bm in BARE.finditer(tail[:80]):
                    rng = parse_ranges(bm.group(1))
                    why = [check_one(res, t, rng, None) for t in targets]
                    verdict = None if any(w is None for w in why) else why[0]
                    results.append((f, ln, f"{m.group(1)}:{bm.group(1)}", targets[0],
                                    verdict))
    return results


def run(root: pathlib.Path, list_all: bool) -> int:
    results = scan(root)
    bad = [r for r in results if r[4]]
    for f, ln, cite, tgt, why in (results if list_all else bad):
        print(f"{'FAIL' if why else 'ok  '} {f}:{ln}: {cite} -> {tgt}"
              + (f": {why}" if why else ""))
    print(f"check_line_citations: {len(results)} in-repo citations, {len(bad)} failing")
    return 1 if bad else 0


def unquoted(root: pathlib.Path) -> int:
    res = Resolver(root, tracked(root))
    n = 0
    for f, ln, cite, tgt, why in scan(root):
        if why or "'" in cite.split(" ", 1)[-1] and " " in cite or tgt.startswith(
                ("docs/probes/", "sys/")):
            continue
        spec = cite.rsplit(":", 1)[1]
        ranges = parse_ranges(spec)
        lines = res.lines(tgt) or []
        a, b = ranges[0]
        n += 1
        print(f"{f}:{ln}: {cite}")
        for i in range(a, min(b, a + 2) + 1):
            if i <= len(lines):
                print(f"    {tgt}:{i}: {lines[i - 1].strip()[:110]}")
    print(f"{n} unquoted citations of editable files")
    return 0


def selftest() -> int:
    with tempfile.TemporaryDirectory() as d:
        root = pathlib.Path(d)
        (root / "src").mkdir()
        (root / "src" / "a.sv").write_text(
            "module a;\n  reg foo_r;\n  always @(posedge clk) foo_r <= 1'b0;\nendmodule\n")
        good = [
            "// `src/a.sv:3`, `foo_r <= 1'b0`",
            "// a.sv:2 (reg foo_r)",
            "// a.sv:1-4 \"module a\"",
            "// io/pit.c:378 is NP2kai, external",
            "// `a.sv:2`, `:3`",
            "// src/a.sv:3 (the reset branch)",
        ]
        planted = {
            "bad line": "// src/a.sv:0",
            "out of range": "// `src/a.sv:9`",
            "inverted range": "// src/a.sv:4-2",
            "wrong fragment": "// `src/a.sv:2`, `foo_r <= 1'b1`",
            "bare past end": "// `a.sv:2`, `:7`",
        }
        cases = {"good": good, **{k: [v] for k, v in planted.items()}}
        failures = []
        for name, body in cases.items():
            (root / "t.txt").write_text("\n".join(body) + "\n")
            res = scan(root, ["src/a.sv", "t.txt"])
            nbad = sum(1 for r in res if r[4])
            ncite = sum(1 for r in res if r[0] == "t.txt")
            if name == "good":
                if nbad or ncite != len(good):
                    failures.append(f"good: {nbad} failing, {ncite} found "
                                    f"(want 0, {len(good)}): {res}")
            elif nbad == 0:
                failures.append(f"{name}: not caught")
        for f in failures:
            print("SELFTEST FAIL:", f)
        if failures:
            return 1
    print(f"check_line_citations selftest: PASS ({len(planted)} planted defects caught)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--unquoted", action="store_true",
                    help="list citations of editable files (not docs/probes, not sys/) that "
                         "quote no fragment, with the cited text, for review by eye")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.unquoted:
        return unquoted(ROOT)
    return run(ROOT, a.list)


if __name__ == "__main__":
    sys.exit(main())

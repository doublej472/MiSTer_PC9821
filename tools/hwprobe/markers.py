#!/usr/bin/env python3
"""markers.py - split a probe capture by its BEGIN:/END: section markers (imported, not run).

Shared by ioprobe_decode, idelat_decode and ideprobe_decode, which each carried a copy.

A marker must START its own line and be alone on it. The probes' banner prose names the markers
(ioprobe's `Sections are BEGIN:IO<port><mode>/END:IO<port><mode>: ...`), and a mid-line match
counted that sentence as a section named `IO`: a complete IO.TXT decoded as `HUNG: IO` plus one
extra section. Every real marker in the archived captures is alone on its line, so the anchor
changes none of their decodes.
"""

from __future__ import annotations

import re

BEGIN_RE = re.compile(r"\s*BEGIN:([A-Z0-9]+)\s*$")
END_RE = re.compile(r"\s*END:([A-Z0-9]+)\s*$")


def sections(text: str) -> tuple[dict[str, list[str]], list[str], list[str]]:
    """-> (found, opens, closes): found maps a section name to its lines, opens and closes are
    the marker names in order. A name in opens with no matching close is the section that hung."""
    found: dict[str, list[str]] = {}
    opens: list[str] = []
    closes: list[str] = []
    cur: str | None = None
    for line in text.splitlines():
        m = BEGIN_RE.match(line)
        if m:
            cur = m.group(1)
            opens.append(cur)
            found.setdefault(cur, [])
            continue
        m = END_RE.match(line)
        if m:
            closes.append(m.group(1))
            cur = None
            continue
        if cur is not None:
            found[cur].append(line)
    return found, opens, closes


def hung(opens: list[str], closes: list[str]) -> list[str]:
    """The sections opened and never closed, in order."""
    closed = set(closes)
    return [o for o in opens if o not in closed]

#!/usr/bin/env python3
"""Every PAIR of memory routes that could act on one request must be named.

pc9821_memory_subsystem.sv arbitrates its routes onto one shared backend, and the checks
that catch two of them acting on one request are hand-written lists of PAIRS:

    if ((win_cpu_ready && open_cpu_ready) || ... )
        $fatal(1, "PC9821 multiple memory routes accepted one request");

A hand-written C(n,2) list is exactly the kind of thing that loses one, and losing one is
invisible: the check still exists, the gate still passes, and it simply cannot see the one
event it was written for.

That has already happened here. The word form of the response check named all ten pairs;
the line form named nine, missing `gvram && map`. Nothing in the tree could see the
omission, because a missing term in a disjunction is not a failure - it is a smaller
disjunction. (The line form itself is gone as of P3: a cache-line fill is four word beats
answered on the routes' own `<route>_cpu_resp_valid`, so there is one response vocabulary
and this check holds the two lists it still has - accept and word response.)

TWO VOCABULARIES, because the merge of pc9821_tram_bridge and pc9821_cg_window into
pc9821_window_responder changed what a "route" is at each level:

  RESPONDERS - the modules that can ANSWER one request. Their signals are
    <route>_cpu_ready / _cpu_resp_valid (a line read's beats are the word responses, so
    there is no separate line signal). The TRAM bridge and the CG byte window are ONE
    responder now (the same byte walk, and the route select guarantees they are never in
    flight together), and the PEGC register file is a route of its own, so this is FIVE
    routes: win/open/gvram/peg/map, C(5,2) = 10 pairs. Their lists are the accept and
    respond checks.

  ADDRESS ROUTES - the one-hot select side of the memory map. SIX routes, so the pair
    contract is C(6,2) = 15: the route-overlap check names the pairs among
    tram/cg_win/open/gvram/peg_reg, and the map-under-another-owner check names map against
    each of them. This half is NOT optional after the merge - sharing one responder gives the
    two windows a NEW way to be wrong, an address that selects both would hand one engine two
    routes - so the tool checks it too rather than quietly dropping a route.

Both vocabularies are named by their SIGNAL name per route rather than by a suffix
convention, so a rename is a failure here instead of a silently smaller count.

How a pair is "named": the check's condition is a disjunction of conjunctions. A pair (A,B)
is covered if some term holds A's and B's signals as its CONJUNCTS - either directly as
`A && B`, or through `A && (B || C)`, whose group is a set of alternatives and so names
(A,B) and (A,C) but not (B,C). This walks that structure rather than counting terms or
restating the text, so a grouped term and separate terms are treated the same way.

Run: python3 tools/check_route_pairs.py
"""
import itertools
import pathlib
import re
import sys

# Anchored to the tool, not to the caller's cwd: a bare relative path made the check read
# whatever happened to be here, and print a traceback instead of usage when run from
# anywhere but the tree root. A check that only works from one directory is a check that is
# not run.
ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src/pc9821/core/pc9821_memory_subsystem.sv"

# The five modules that can ANSWER one request, as the prefix their signals carry. The TRAM
# bridge and the CG window share the `win` prefix because they are one responder; the PEGC
# register file's route is `peg` (pc9821_pegc).
RESP_ROUTES = ["win", "open", "gvram", "peg", "map"]
# A route's line response is its word response now (P3 deleted the 128-bit line form), so
# there are two lists per route, not three.
RESP_SUFFIXES = ["_cpu_ready", "_cpu_resp_valid"]

# The six ADDRESS routes, as the signal each is named by in its own pair lists. `map` is the
# mapper's live request (its select is the complement, so it has no `<route>_select`).
SELECT_SIGNALS = {
    "tram":    "tram_select",
    "cg_win":  "cg_win_select",
    "open":    "open_select",
    "gvram":   "gvram_select",
    "peg_reg": "peg_reg_select",
    "map":     "map_valid",
}


def split_top(text: str, sep: str) -> list:
    """Split on sep at parenthesis depth 0 only."""
    parts, depth, cur = [], 0, []
    i = 0
    while i < len(text):
        if text.startswith(sep, i) and depth == 0:
            parts.append("".join(cur))
            cur = []
            i += len(sep)
            continue
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        cur.append(c)
        i += 1
    parts.append("".join(cur))
    return parts


def assertion_region(text: str) -> str:
    """The trailing `ifdef VERILATOR block, comments stripped, where every route check lives.

    Starting from the LAST marker matters: the file has two VERILATOR blocks, and the
    route-isolation checks are in the second one. Scoping also keeps a condition in the
    ordinary RTL from being mistaken for a check, and stripping comments matters for the
    same reason it always does here -- a comment sitting inside a disjunction becomes part
    of the term text, and one that wraps a whole conjunction in parentheses defeats the
    conjunct/alternative reading below.
    """
    at = text.rfind("`ifdef VERILATOR")
    region = text[at:] if at >= 0 else text
    region = re.sub(r"/\*.*?\*/", " ", region, flags=re.S)
    return re.sub(r"//[^\n]*", "", region)


def all_conditions(text: str) -> list:
    """Every paren-balanced `if (...)` condition in text, in source order.

    The check bodies contain $display calls whose parentheses defeat a regex, so this
    balances from each `if (` instead.
    """
    out = []
    for m in re.finditer(r"\bif \(", text):
        open_paren = m.end() - 1
        depth = 0
        for i in range(open_paren, len(text)):
            c = text[i]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    out.append(text[open_paren + 1:i])
                    break
    return out


def enclosing_condition(text: str, token: str) -> str | None:
    """The last `if (...)` condition that mentions token.

    The route signals appear first in the INSTANCES above the checks, so walking back to
    the nearest `if (` finds the wrong thing; taking the LAST match, inside the assertion
    region, finds the check.
    """
    found = [c for c in all_conditions(text) if token in c]
    return found[-1] if found else None


def strip_outer(text: str) -> str:
    t = text.strip()
    while t.startswith("(") and t.endswith(")") and \
            split_top(t[1:-1], "||") == [t[1:-1]]:
        t = t[1:-1].strip()
    return t


def routes_in(term: str, signals: dict) -> set:
    """Route names whose signal appears in this term."""
    return {r for r, s in signals.items()
            if re.search(r"\b" + re.escape(s) + r"\b", term)}


def covered_pairs(cond: str, signals: dict) -> set:
    """Pairs of routes this condition can see, for one signal vocabulary.

    A term is a conjunction that may hold a disjunctive GROUP, and the two name DIFFERENT
    things: `A && B` names the pair (A,B); `A && (B || C)` names the pairs (A,B) and (A,C)
    and NOT (B,C) -- B and C are alternatives there, never both. Expanding a group into
    intra-group pairs (which a first version of this did) makes a grouped term cover
    everything in it at once, and the check then passes on any subset: measured here, that
    alone covered all ten address-route pairs from the single map-under-owner term, so
    deleting a real pair term still passed.
    """
    pairs = set()
    for term in split_top(cond, "||"):
        t = strip_outer(term)
        if not t:
            continue
        groups = [routes_in(g, signals) for g in re.findall(r"\(([^()]*)\)", t)
                  if "||" in g]
        # the names OUTSIDE the disjunctive groups: a group's contents are alternatives,
        # not conjuncts, so only the groups are blanked out
        top_text = t
        for g in re.findall(r"\(([^()]*)\)", t):
            if "||" in g:
                top_text = top_text.replace("(" + g + ")", " ")
        top = routes_in(top_text, signals)
        if len(top) >= 2:
            for a, b in itertools.combinations(sorted(top), 2):
                pairs.add((a, b))
        for g in groups:
            for a in top:
                for b in g:
                    if a != b:
                        pairs.add(tuple(sorted((a, b))))
    return pairs


def all_pairs(routes) -> list:
    return list(itertools.combinations(routes, 2))


def missing_from(have: set, routes) -> list:
    return [f"{a} && {b}" for a, b in all_pairs(routes)
            if (a, b) not in have and (b, a) not in have]


def main() -> int:
    text = SRC.read_text()
    region = assertion_region(text)
    problems = []

    # ---- the four responders: the accept / respond / respond-line pair lists ----
    for suffix in RESP_SUFFIXES:
        seen = {m for m in re.findall(r"\b([a-z_]+)" + re.escape(suffix) + r"\b", text)
                if any(m.startswith(r) for r in RESP_ROUTES)}
        if seen != set(RESP_ROUTES):
            problems.append(
                f"responder{suffix}: the file has signals for {sorted(seen)}, but this "
                f"check knows {RESP_ROUTES} -- a route was added or renamed")

    for suffix in RESP_SUFFIXES:
        sig = {r: r + suffix for r in RESP_ROUTES}
        cond = enclosing_condition(region, sig["gvram"])
        if cond is None:
            problems.append(f"responder{suffix}: no check condition found using {sig['gvram']}")
            continue
        have = {(a, b) for (a, b) in covered_pairs(cond, sig) if a != b}
        missing = missing_from(have, RESP_ROUTES)
        label = suffix.lstrip("_")
        if missing:
            problems.append(
                f"responder {label}: {len(missing)} of {len(all_pairs(RESP_ROUTES))} pairs "
                f"cannot be seen by this check: " + ", ".join(missing))
        else:
            print(f"  responder {label:14s} names all {len(all_pairs(RESP_ROUTES))} route pairs")

    # ---- the five address routes: the select-side pair lists ----
    absent = [s for s in SELECT_SIGNALS.values() if not re.search(r"\b" + s + r"\b", text)]
    if absent:
        problems.append(f"address routes: select signal(s) {absent} not present at all")
    unknown = {m for m in re.findall(r"\b([a-z_]+_select)\b", text)
               if m not in SELECT_SIGNALS.values()}
    if unknown:
        problems.append(
            f"address routes: {sorted(unknown)} look like route selects this check does not "
            f"know -- a route was added or renamed")

    sel_have = set()
    for cond in all_conditions(region):
        if routes_in(cond, SELECT_SIGNALS):
            sel_have |= covered_pairs(cond, SELECT_SIGNALS)
    sel_have = {(a, b) for (a, b) in sel_have if a != b}
    sel_missing = missing_from(sel_have, list(SELECT_SIGNALS))
    if sel_missing:
        problems.append(
            f"address routes: {len(sel_missing)} of {len(all_pairs(SELECT_SIGNALS))} select "
            f"pairs cannot be seen by the checks: " + ", ".join(sel_missing))
    else:
        print(f"  address routes         names all {len(all_pairs(SELECT_SIGNALS))} route pairs")

    if problems:
        print("ROUTE-PAIR COVERAGE: FAIL", file=sys.stderr)
        for p in problems:
            print(f"  FAIL {p}", file=sys.stderr)
        return 1
    print(f"ROUTE-PAIR COVERAGE: PASS ({len(RESP_ROUTES)} responders "
          f"({len(all_pairs(RESP_ROUTES))} pairs, {len(RESP_SUFFIXES)} checks), "
          f"{len(SELECT_SIGNALS)} address routes ({len(all_pairs(SELECT_SIGNALS))} pairs))")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""idelat_decode.py - parse an IDELAT capture into the th5-ide latency targets.

Usage:
    python3 tools/hwprobe/idelat/idelat_decode.py IDELAT.TXT [IDELAT2.TXT ...]

IDELAT (tools/hwprobe/idelat/idelat.s) is the real-machine IDE READ latency
probe.  It prints, per window, the raw PIT counts moved and the ARTIC counter
delta (see the row shapes in the .s header).  This script converts both with
the DEVICE CLOCK RATES - no run-local scale exists anywhere in the run:

    PIT channel-0: 2 457 600 counts/s  (1 count = 406.901 ns)
    ARTIC counter:   307 200 ticks/s   (1 tick  = 3255.208 ns)

Both rates are machine-confirmed (8 raw PIT counts per
ARTIC tick over three windows on two programs; the ARTIC rate independently by
the raster edge counts).  The PITDIV line cross-checks the PIT STRAP: a
divisor near 0x4E00 means the BIOS work-area 0501 bit-7 strap selects the
1.9968 MHz oscillator and the PIT rate is switched to 1 996 800 counts/s;
anything unrecognised keeps 2.4576 MHz with a loud warning.

REFEREE: **ARTIC is preferred whenever its delta is >= 1 tick** -
at these scales the 24-bit counter cannot wrap (54.6 s) and its reads cannot
tear, while the PIT's 16-bit raw delta wraps silently above one 65536-count
period and the torn latch word mis-assembles.  The
worked example: a 70000-count truth (3 PIT reloads) reads as raw16 =
61808 - 11% low, INSIDE the old 25% band - exactly the cold command->first-DRQ
regime.  PIT is kept only for sub-tick windows (ARTIC delta 0).  The 8:1
cross-check is retained as a health label with the machine-measured 0.5-5%
agreement band: ok / WRAP (the -8192-count reload signature, explicitly
rejected) / neq (disagreement beyond 5%) / sub (sub-tick, PIT used).

LEGACY x2 RULE: the archived /TIME and T2R captures print halved-era PIT ns
(the mode-3 /2 that a raster check on the machine refuted), so any quoted ns from
them must be doubled before it is compared with this probe's output or with
the 30-clk / 81-clk anchor axes.

DEGENERATE CAPTURES (the first capture's defect).  The first shipped
`idelat.com` computed the READ windows' ARTIC deltas with the PIT's operand
order, so they came out NEGATIVE (`IDELAT.TXT` `drq_art=FFFFFECD` = -307 ticks)
while the CAL rows were right.  Reading those as unsigned gave the 1.4e10-us
DECISION CONSTANTS this decoder used to print.  It now checks every READ row's
ARTIC column first: a delta with bit 31 set (or one above ~3.4 s of ticks) is
reported as a DEGENERATE CAPTURE banner, the `|ARTIC|` column is cross-checked
against the PIT column at the 8:1 law so the PIT numbers can be trusted, and the
READ constants are then priced from the PIT column alone (`PIT!` label).

WHO DECIDES.  The decoder recomputes the 8:1 ratio from the printed fields for
every window (`own_cross_check`), and THAT is the authority: `ok` and the
documented `WRAP` are consistent, a sub-tick window cannot be refereed, and only
a real disagreement refuses.  The probe's own `SELFCHECK` tally is a SECONDARY
diagnostic - when it fails while the fields agree, the capture is quoted and the
output names `INSTRUMENT DEFECT (probe self-check), DATA CONSISTENT` (TODO 89:
the one-trip build scaled the PIT column and failed all 58 windows on data that
was never in doubt).  A capture whose run is INCOMPLETE (a BEGIN: with no END:, a
section missing, or no `IDELAT DONE` trailer) is refused: its rows are partial
data that look like constants.  A refusal exits 1; a quoted-but-defective capture
exits 0.

STRAP ASSUMPTION.  The 8:1 law the tables and the self-check referee against is
the 2.4576 MHz PIT strap's.  On the 1.9968 MHz strap
(divisor 0x4E00, which this decoder does recognise below) the ratio is 6.5 raw
counts per ARTIC tick, so the probe's `chk_pair` would fail EVERY window and a
SELFCHECK failure there is the strap, not a sign or order defect - the PITDIV
line is the discriminator (and a 16-bit PIT wrap in the longest CAL window would
present as a failure too).

The output ends with the DECISION CONSTANTS block: the numbers the IDE timing
work aims for, each with the row it came from.  Nothing here talks to
hardware; it is a pure text parser.
"""

from __future__ import annotations

import argparse
import re
import statistics
import sys

PIT_HZ = 2_457_600                 # switched to 1_996_800 when PITDIV ~= 0x4E00
ARTIC_HZ = 307_200
ARTIC_NS = 1e9 / ARTIC_HZ      # 3255.208 ns per tick
TM_N = 1024

# True while decoding a capture whose READ-row ARTIC deltas are the pre-fix
# idelat.com's negated ones; set per capture by decode().
ART_DEGENERATE = False
ART_NEGATIVE = 1 << 31         # bit 31 set = the inverted-sign defect
ART_ABSURD = 1 << 20           # > ~3.4 s of ARTIC ticks: no window here is that long


def pit_ns(counts: int) -> float:
    return counts * 1e9 / PIT_HZ

# The two candidate axes for the 0x5F anchor question:
# is one 005F access the documented 600 ns (30 clk_sys at 50 MHz) or the class
# table's 81 clk_sys (1620 ns)?  The measured absolute excess decides.
AXIS_30_NS = 600.0
AXIS_81_NS = 1620.0


def sections(text: str) -> tuple[dict[str, list[str]], list[str], list[str]]:
    """Split a capture by BEGIN:/END: markers.

    Returns (found, opens, closes): found maps a section name to its lines, opens
    and closes are the marker names in order.  A name in opens with no matching
    close is the section that hung.

    A marker must START its own line (the same anchor ioprobe_decode.py uses).
    Without it, prose that names the markers becomes a phantom section - the
    ioprobe banner's `Sections are BEGIN:IO<port><mode>/...` sentence decoded a
    complete capture as `HUNG: IO`.  idelat's own banner
    line 8 (`Sections are BEGIN:/END: bracketed: ...`) carries a slash after the
    colon, so it is matched by neither form and every archived capture decodes
    identically under the anchor.
    """
    found: dict[str, list[str]] = {}
    opens: list[str] = []
    closes: list[str] = []
    cur: str | None = None
    for line in text.splitlines():
        m = re.match(r"\s*BEGIN:([A-Z0-9]+)\s*$", line)
        if m:
            cur = m.group(1)
            opens.append(cur)
            found.setdefault(cur, [])
            continue
        m = re.match(r"\s*END:([A-Z0-9]+)\s*$", line)
        if m:
            closes.append(m.group(1))
            cur = None
            continue
        if cur is not None:
            found[cur].append(line)
    return found, opens, closes


def referee(pit: int, art: int) -> tuple[str, str]:
    """(which column to trust, health label) for one raw window.

    Prefer ARTIC whenever its delta is >= 1 tick (no wrap/tear at
    these scales); keep PIT only for sub-tick windows.  The 8:1 cross-check is
    a health label at the machine-measured agreement band (0.5-5%): 'ok',
    'WRAP' for the -8192-count reload signature (explicitly rejected), 'neq'
    beyond 5%, 'sub' when the window is sub-tick and PIT serves.

    Small-window rule: the absolute floors (16 counts,
    32 for the WRAP check) exist for latch-read quantization, but they are
    CLAMPED to ref so the effective band never exceeds +/-100% on windows
    below ~320 counts (art=1 tick, ref=8: 'ok' now spans pit 0..16, not
    0..24).  Label-only: ns still come from ARTIC at art >= 1.
    """
    if art >= 1:
        ref = max(art * 8, 1)
        if abs(pit - ref) <= min(max(16, 0.05 * ref), ref):
            return "art", "ok"
        if abs(ref - pit - 8192) <= min(max(32, 0.02 * ref), ref):
            return "art", "WRAP"
        return "art", "neq"
    return "pit", "sub"


def pick(pit: int, art: int) -> tuple[float, str]:
    which, label = referee(pit, art)
    ns = pit_ns(pit) if which == "pit" else art * ARTIC_NS
    return ns, label


def signed32(v: int) -> int:
    """The probe's 32-bit subtraction read as a signed delta (see bad_art)."""
    return v - (1 << 32) if v >= ART_NEGATIVE else v


def bad_art(art: int) -> bool:
    """True for a READ-row ARTIC delta that cannot be a window this probe made.

    Bit 31 set is the first shipped idelat.com's inverted sign (the READ rows
    subtracted start - end where the ARTIC counter counts up); a delta above
    ~3.4 s of ticks is absurd at these window sizes either way.
    """
    return art >= ART_NEGATIVE or art > ART_ABSURD


def pick_read(pit: int, art: int) -> tuple[float, str]:
    """READ-row ns: the PIT column when the ARTIC column is degenerate.

    The two columns are two views of one window, so the PIT column is a sound
    substitute wherever the ARTIC one is the pre-fix sign defect - the banner
    prints how many of the affected rows' |ARTIC| values confirm it at 8:1.
    """
    if bad_art(art):
        return pit_ns(pit), "PIT!"
    return pick(pit, art)


CAL_RE = re.compile(
    r"^CAL\s+(?P<label>\S+)\s+port=(?P<port>[0-9A-Fa-f]{4})\s+mode=(?P<mode>\S)\s+"
    r"pit=(?P<pit>[0-9A-Fa-f]+)\s+base=(?P<base>[0-9A-Fa-f]+)\s+"
    r"artic=(?P<artic>[0-9A-Fa-f]+)\s+bartic=(?P<bartic>[0-9A-Fa-f]+)"
)
R1_RE = re.compile(
    r"^R1\s+t=(?P<t>\d+)\s+sec=(?P<sec>\d+)\s+warm=(?P<warm>\d+)\s+"
    r"st0=(?P<st0>[0-9A-Fa-f]{2})\s+st1=(?P<st1>[0-9A-Fa-f]{2})\s+"
    r"polls=(?P<polls>[0-9A-Fa-f]+)\s+to=(?P<to>\d+)\s+ck=(?P<ck>[0-9A-Fa-f]+)\s+"
    r"drq_pit=(?P<dpit>[0-9A-Fa-f]+)\s+drq_art=(?P<dart>[0-9A-Fa-f]+)\s+"
    r"xfer_pit=(?P<xpit>[0-9A-Fa-f]+)\s+xfer_art=(?P<xart>[0-9A-Fa-f]+)"
)
RN_RE = re.compile(
    r"^RN\s+t=(?P<t>\d+)\s+k=(?P<k>\d+)\s+sec=(?P<sec>\d+)\s+st=(?P<st>[0-9A-Fa-f]{2})\s+"
    r"polls=(?P<polls>[0-9A-Fa-f]+)\s+to=(?P<to>\d+)\s+ck=(?P<ck>[0-9A-Fa-f]+)\s+"
    r"drq_pit=(?P<dpit>[0-9A-Fa-f]+)\s+drq_art=(?P<dart>[0-9A-Fa-f]+)\s+"
    r"xfer_pit=(?P<xpit>[0-9A-Fa-f]+)\s+xfer_art=(?P<xart>[0-9A-Fa-f]+)"
)
RNEND_RE = re.compile(
    r"^RNEND\s+t=(?P<t>\d+)\s+st=(?P<st>[0-9A-Fa-f]{2})\s+"
    r"polls=(?P<polls>[0-9A-Fa-f]+)\s+to=(?P<to>\d+)\s+"
    r"done_pit=(?P<dpit>[0-9A-Fa-f]+)\s+done_art=(?P<dart>[0-9A-Fa-f]+)\s+"
    r"sum_ck=(?P<ck>[0-9A-Fa-f]+)\s+fst=(?P<fst>[0-9A-Fa-f]{2})"
)
# The probe's own pit:artic 8:1 self-check tally (SELFCHECK section).
SELFCHECK_RE = re.compile(
    r"SELFCHECK windows=(?P<win>\d+) ok=(?P<ok>\d+) fail=(?P<fail>\d+) sub=(?P<sub>\d+)"
)


def parse_all(found: dict[str, list[str]]):
    cal, r1, rn, rnend = [], [], [], []
    for name, lines in found.items():
        for line in lines:
            if (m := CAL_RE.match(line)) and name == "CAL":
                d = m.groupdict()
                cal.append({
                    "label": d["label"], "port": int(d["port"], 16), "mode": d["mode"],
                    "pit": int(d["pit"], 16), "base": int(d["base"], 16),
                    "artic": int(d["artic"], 16), "bartic": int(d["bartic"], 16),
                })
            elif (m := R1_RE.match(line)) and name == "READ1":
                d = m.groupdict()
                r1.append({
                    "t": int(d["t"]), "sec": int(d["sec"]), "warm": int(d["warm"]),
                    "st0": d["st0"], "st1": d["st1"], "polls": int(d["polls"], 16),
                    "to": int(d["to"]), "ck": int(d["ck"], 16), "dpit": int(d["dpit"], 16), "dart": int(d["dart"], 16),
                    "xpit": int(d["xpit"], 16), "xart": int(d["xart"], 16),
                })
            elif (m := RN_RE.match(line)) and name == "READN":
                d = m.groupdict()
                rn.append({
                    "t": int(d["t"]), "k": int(d["k"]), "sec": int(d["sec"]),
                    "st": d["st"], "polls": int(d["polls"], 16), "to": int(d["to"]),
                    "ck": int(d["ck"], 16), "dpit": int(d["dpit"], 16), "dart": int(d["dart"], 16),
                    "xpit": int(d["xpit"], 16), "xart": int(d["xart"], 16),
                })
            elif (m := RNEND_RE.match(line)) and name == "READN":
                d = m.groupdict()
                rnend.append({
                    "t": int(d["t"]), "st": d["st"], "polls": int(d["polls"], 16),
                    "to": int(d["to"]), "dpit": int(d["dpit"], 16),
                    "dart": int(d["dart"], 16), "fst": d["fst"],
                })
    return cal, r1, rn, rnend


def med(vals: list[float]) -> float:
    return statistics.median(vals) if vals else float("nan")


def degenerate_read_rows(
    r1: list[dict], rn: list[dict], ends: list[dict]
) -> list[tuple[str, int]]:
    """[(row label, raw ARTIC delta)] for every READ-row delta that cannot be a
    window this probe made (see bad_art)."""
    bad: list[tuple[str, int]] = []
    for r in r1:
        for field, name in (("dart", "drq_art"), ("xart", "xfer_art")):
            if bad_art(r[field]):
                bad.append((f"R1 t={r['t']} {name}", r[field]))
    for r in rn:
        for field, name in (("dart", "drq_art"), ("xart", "xfer_art")):
            if bad_art(r[field]):
                bad.append((f"RN t={r['t']} k={r['k']} {name}", r[field]))
    for e in ends:
        if bad_art(e["dart"]):
            bad.append((f"RNEND t={e['t']} done_art", e["dart"]))
    return bad


def print_degenerate_banner(
    bad: list[tuple[str, int]], r1: list[dict], rn: list[dict], ends: list[dict]
) -> None:
    """The pre-fix sign defect, plus the proof that the PIT column is sound.

    A negated ARTIC delta is still the right MAGNITUDE, so every affected row
    is cross-checked as |ARTIC| x 8 against its own PIT delta: if those agree
    at the 8:1 law the sign is the whole defect and the PIT column carries the
    numbers; if they do not, the row is not merely mis-signed and nothing from
    it should be quoted.
    """
    print()
    print("  *** DEGENERATE CAPTURE ***")
    print(f"  {len(bad)} READ-row ARTIC delta(s) cannot be a window this probe made. First")
    print("  few, with the value read as the signed 32-bit delta it is:")
    for label, val in bad[:4]:
        print(f"    {label}=0x{val:08X} = {signed32(val)}")
    print(
        "  That is the first shipped idelat.com's sign defect: the READ windows computed\n"
        "  their ARTIC delta as start - end while the ARTIC counter counts UP (tm_finish,\n"
        "  which feeds every CAL row, always had it right). Read as unsigned they are\n"
        "  ~1.4e10 us - the numbers this decoder used to print as DECISION CONSTANTS.\n"
        "  The PIT column is a separate instrument, so the READ tables below are priced\n"
        "  from it alone (ref label 'PIT!') after this cross-check:"
    )
    agree = total = 0
    for r in r1 + rn:
        for pf, af in (("dpit", "dart"), ("xpit", "xart")):
            if bad_art(r[af]):
                total += 1
                exp = abs(signed32(r[af])) * 8
                agree += abs(r[pf] - exp) <= max(16, 0.10 * exp)
    for e in ends:
        if bad_art(e["dart"]):
            total += 1
            exp = abs(signed32(e["dart"])) * 8
            agree += abs(e["dpit"] - exp) <= max(16, 0.10 * exp)
    pct = 100.0 * agree / total if total else float("nan")
    print(
        f"    {agree}/{total} affected row(s) agree: |ARTIC| x 8 = the PIT delta within 10%"
        f" ({pct:.0f}%)."
    )
    if total and agree == total:
        print(
            "  => the sign is the whole defect: the PIT-sourced figures below are usable,\n"
            "     and re-running the fixed IDELAT.COM will confirm them from the ARTIC side."
        )
    else:
        print(
            "  => NOT all of them agree: do NOT quote this capture's READ constants from\n"
            "     either column. Re-run the fixed IDELAT.COM."
        )


def own_cross_check(
    cal: list[dict], r1: list[dict], rn: list[dict], ends: list[dict]
) -> tuple[int, int, int, list[str]]:
    """The decoder's OWN 8:1 cross-check of the printed fields.

    Returns (agree, checked, degenerate, skipped, failing labels).  `checked` counts every
    printed window whose two columns are both present and refereable (each CAL
    row's own window and its interleaved control, each READ row's DRQ and transfer
    windows, each RNEND completion window); `degenerate` counts the ones whose
    ARTIC field is the pre-fix sign defect (handled by that banner, which
    cross-checks |ARTIC| x 8).

    THIS is what decides whether a capture's numbers may be quoted, because it is
    computed here from the same fields the tables print and owes nothing to any
    one probe build's arithmetic.  The probe's own SELFCHECK tally is a SECONDARY
    diagnostic: a tally that fails while this cross-check passes is an instrument
    defect in the probe, and refusing a good capture is as bad as quoting a torn
    one (TODO 89: `IDELAT-fixed.TXT` - the probe scaled the PIT delta, all 58 of
    its windows fail, and every one of them is consistent here).
    """
    agree = checked = degen = skipped = 0
    failing: list[str] = []
    pairs: list[tuple[str, int, int]] = []
    for r in cal:
        label = f"CAL {r['label'].strip()}"
        pairs.append((f"{label} window", r["pit"], r["artic"]))
        pairs.append((f"{label} control", r["base"], r["bartic"]))
    for r in r1:
        pairs.append((f"R1 t={r['t']} drq", r["dpit"], r["dart"]))
        pairs.append((f"R1 t={r['t']} xfer", r["xpit"], r["xart"]))
    for r in rn:
        pairs.append((f"RN t={r['t']} k={r['k']} drq", r["dpit"], r["dart"]))
        pairs.append((f"RN t={r['t']} k={r['k']} xfer", r["xpit"], r["xart"]))
    for e in ends:
        pairs.append((f"RNEND t={e['t']} done", e["dpit"], e["dart"]))
    for label, pit, art in pairs:
        if bad_art(art):
            degen += 1
            continue
        # The decoder's own doctrine, per window: 'ok' and 'WRAP' are consistent
        # (a wrapped PIT delta is expected above one 16-bit PIT period and the ARTIC
        # column serves - that is what referee() labels WRAP for), 'sub' cannot be
        # refereed at all, and only 'neq' is a real disagreement.
        _, label_kind = referee(pit, art)
        if label_kind == "sub":
            skipped += 1
            continue
        checked += 1
        if label_kind in ("ok", "WRAP"):
            agree += 1
        else:
            failing.append(f"{label}: pit={pit} vs 8 x artic={art * 8} ({label_kind})")
    return agree, checked, degen, skipped, failing


def print_strap_note() -> None:
    """The 0x4E00 caveat, printed wherever a disagreement can be the strap instead.

    The 8:1 law is the 2.4576 MHz strap's; on the 1.9968 MHz strap (divisor 0x4E00,
    work-area 0501 bit 7) the ratio is 6.5 counts per ARTIC tick, so chk_pair AND
    this decoder's own 8:1 cross-check both fail there on every window.  A
    disagreement on such a capture is the strap, not a torn read or a sign bug.
    """
    print(
        "  NOTE (strap): the PITDIV line says the 1.9968 MHz strap (0x4E00), where the\n"
        "  law is 6.5 raw counts per ARTIC tick, NOT 8. Both checks assume the 2.4576 MHz\n"
        "  strap, so a systematic disagreement here is the STRAP - re-derive the band\n"
        "  before diagnosing a torn read, a sign bug or an instrument defect."
    )


def probe_tally_scale_defect(text: str) -> tuple[int, int] | None:
    """The probe's own `PIT delta=X but 8 x ARTIC delta=8X` lines, if any.

    That signature is the shipped chk_pair defect (it scaled the PIT column):
    `0x112D x 8 = 0x8968` in `IDELAT-fixed.TXT`.  Returning the first pair lets
    the banner name the defect instead of only reporting a failed tally.
    """
    for m in re.finditer(r"PIT delta=([0-9A-Fa-f]+) but 8 x ARTIC delta=([0-9A-Fa-f]+)",
                         text):
        pit, claimed = int(m.group(1), 16), int(m.group(2), 16)
        if claimed == pit * 8:
            return pit, claimed
    return None


def print_cal(cal: list[dict]) -> dict[str, float]:
    print("== CAL: the poll-cost shape and the anchor ==")
    print(
        f"  {'row':8} {'md':2} {'iter_ns':>8} {'excess_ns':>9} {'ex_art':>8} {'ref':>4}  (of "
        f"{TM_N} iterations, per iteration)"
    )
    out: dict[str, float] = {}
    for r in cal:
        excess_pit = max(r["pit"] - r["base"], 0)
        excess_art = max(r["artic"] - r["bartic"], 0)
        ex_ns, ex_lab = pick(excess_pit, excess_art)
        tot_ns, tot_lab = pick(r["pit"], r["artic"])
        print(
            f"  {r['label']:8} {r['mode']:2} {tot_ns / TM_N:>8.1f} "
            f"{ex_ns / TM_N:>9.1f} {excess_art * ARTIC_NS / TM_N:>8.1f} {tot_lab:>4}"
        )
        out[r["label"].strip()] = ex_ns / TM_N
        out[r["label"].strip() + "+tot"] = tot_ns / TM_N
    if "WAIT5F" in out:
        w = out["WAIT5F"]
        d30 = abs(w - AXIS_30_NS) / AXIS_30_NS
        d81 = abs(w - AXIS_81_NS) / AXIS_81_NS
        print(
            f"\n  ANCHOR: one 005F write access = {w:.0f} ns over its control"
            f" (600 ns is {100 * w / AXIS_30_NS:.0f}% of the documented figure;"
            f" 1620 ns is {100 * w / AXIS_81_NS:.0f}% of 81 clk at 50 MHz)."
        )
        if min(d30, d81) > 0.20:
            print(
                "    INDETERMINATE - the 0x5F anchor stays open: the measurement is within ~20%"
                " of neither\n    axis.  Do NOT print a nearest-axis verdict from it.  If"
                " this number came from a\n    legacy capture, apply the x2 rule first"
                " (halved-era PIT ns:\n    double them) and re-run"
                " the comparison."
            )
        else:
            verdict = (
                "the documented 30 clk (600 ns) axis" if d30 < d81
                else "the class table's 81 clk (1620 ns) axis"
            )
            print(
                f"    Verdict: closer to {verdict} (within 20%)."
                f"\n    This decides the 0x5F anchor question:"
                f" quote class\n    times on the axis above.  Note the documented 600 ns"
                f" may be the inserted WAIT\n    only, not the total access cost - if the"
                f" measurement lands ~1.6-1.7 us, the 600 ns\n    figure and the total"
                f" access are different quantities and the total is what"
                f" io_access_cycles prices.\n    LEGACY x2: halved-era captures (the /TIME"
                f" and T2/T2R prints) must be doubled before\n    this comparison - e.g."
                f" T2R's raw 819 ns reads 1638 ns corrected, at the 81-clk axis."
            )
    return out


def print_read1(rows: list[dict], cal: dict[str, float]) -> dict[str, float]:
    print("\n== READ1: READ SECTORS count=1 (command issue -> DRQ -> 256 words) ==")
    print(
        f"  {'t':>2} {'sec':>3} {'warm':>4} {'drq_gross':>9} {'drq_net':>8} {'polls':>7} "
        f"{'xfer':>8} {'w/word':>7} {'sum':>8} {'st':>4} {'ck':>4} to  ref"
    )
    polllp = cal.get("POLLLP+tot", 0.0)
    out: dict[str, float] = {}
    cold_drq, cold_xfer, warm_drq, warm_xfer = [], [], [], []
    for r in rows:
        drq_ns, drq_lab = pick_read(r["dpit"], r["dart"])
        xfer_ns, xfer_lab = pick_read(r["xpit"], r["xart"])
        net = max(drq_ns - r["polls"] * polllp, 0.0)
        check = f"{drq_lab}/{xfer_lab}"
        print(
            f"  {r['t']:>2} {r['sec']:>3} {r['warm']:>4} {drq_ns / 1e3:>9.2f} "
            f"{net / 1e3:>8.2f} {r['polls']:>7} {xfer_ns / 1e3:>8.2f} "
            f"{xfer_ns / 256:>7.1f} {(drq_ns + xfer_ns) / 1e3:>8.2f} "
            f"{r['st0']}{r['st1']} {r['ck']:04X} {r['to']}  {check}"
        )
        if r["to"] == 0:
            (warm_drq if r["warm"] else cold_drq).append(drq_ns)
            (warm_xfer if r["warm"] else cold_xfer).append(xfer_ns)
    if cold_drq:
        out["cold_drq_ns"] = med(cold_drq)
        out["cold_xfer_ns"] = med(cold_xfer)
    if warm_drq:
        out["warm_drq_ns"] = med(warm_drq)
        out["warm_xfer_ns"] = med(warm_xfer)
    if cold_drq and warm_drq:
        print(
            f"  cold medians: drq {med(cold_drq) / 1e3:.2f} us, xfer "
            f"{med(cold_xfer) / 1e3:.2f} us ({med(cold_xfer) / 256:.1f} ns/word);"
            f" warm medians: drq {med(warm_drq) / 1e3:.2f} us, xfer "
            f"{med(warm_xfer) / 1e3:.2f} us"
        )
        print(
            "  'first-touch this probe' vs 'immediate re-read': the warm rows show the"
            "\n  drive's own cache effect on command->DRQ.  TH5's speech loads are mostly"
            "\n  cold reads across many sectors: aim at the cold figures."
        )
    return out


def print_readn(rows: list[dict], ends: list[dict], cal: dict[str, float]) -> dict[str, float]:
    print("\n== READN: READ SECTORS count=N (one command, N sectors) ==")
    print(
        f"  {'t':>2} {'k':>2} {'sec':>3} {'drq':>8} {'xfer':>8} {'incr':>8} {'w/word':>7} "
        f"{'polls':>7} {'st':>2} {'ck':>4} to  ref"
    )
    polllp = cal.get("POLLLP+tot", 0.0)
    out: dict[str, float] = {}
    for r in rows:
        drq_ns, drq_lab = pick_read(r["dpit"], r["dart"])
        xfer_ns, xfer_lab = pick_read(r["xpit"], r["xart"])
        check = f"{drq_lab}/{xfer_lab}"
        print(
            f"  {r['t']:>2} {r['k']:>2} {r['sec']:>3} {drq_ns / 1e3:>8.2f} "
            f"{xfer_ns / 1e3:>8.2f} {(drq_ns + xfer_ns) / 1e3:>8.2f} "
            f"{xfer_ns / 256:>7.1f} {r['polls']:>7} "
            f"{r['st']} {r['ck']:04X} {r['to']}  {check}"
        )
    for e in ends:
        done_ns, done_w = pick_read(e["dpit"], e["dart"])
        trial = [r for r in rows if r["t"] == e["t"] and r["to"] == 0]
        if trial and e["to"] == 0:
            total = sum(pick_read(r["dpit"], r["dart"])[0] + pick_read(r["xpit"], r["xart"])[0]
                        for r in trial) + done_ns
            n = len(trial)
            tail_incr = med([pick_read(r["dpit"], r["dart"])[0] + pick_read(r["xpit"], r["xart"])[0]
                             for r in trial[1:]]) if n > 1 else float("nan")
            print(
                f"  t={e['t']} END: completion {done_ns / 1e3:.2f} us after the last word;"
                f" total {total / 1e3:.1f} us for {n} sectors"
                f" = {total / n / 1e3:.2f} us/sector effective,"
                f" media+transfer tail increment {tail_incr / 1e3:.2f} us/sector,"
                f" throughput {512 * n / (total / 1e9) / 1e6:.2f} MB/s"
            )
            if e["t"] == 1:
                out["multi_cold_total_ns"] = total
                out["multi_cold_per_sector_ns"] = total / n
                out["multi_cold_tail_incr_ns"] = tail_incr
                out["multi_cold_first_ns"] = (pick_read(trial[0]["dpit"], trial[0]["dart"])[0]
                                              + pick_read(trial[0]["xpit"], trial[0]["xart"])[0])
            else:
                out["multi_warm_per_sector_ns"] = total / n
    print(
        "  k=1's drq is command issue -> first DRQ; k>1's drq is the previous word's"
        "\n  end -> next DRQ; incr = that gap plus the sector's own transfer.  The k>1"
        "\n  increment is the per-sector media cost inside one command (no per-command"
        "\n  overhead): compare it with READ1's single-sector total."
    )
    return out


def print_decisions(cal: dict[str, float], r1: dict[str, float], rn: dict[str, float]) -> None:
    print("\n== DECISION CONSTANTS (what th5-ide aims for) ==")
    if ART_DEGENERATE:
        print(
            "  (DEGENERATE CAPTURE: the READ constants below come from the PIT column alone -\n"
            "  the ARTIC column of those rows is the first shipped probe's inverted sign.\n"
            "  See the banner above; re-run with the fixed IDELAT.COM before quoting them.)"
        )
    rows = [
        ("command issue -> first DRQ, cold", r1.get("cold_drq_ns"),
         "READ1 cold rows, drq_gross (net of poll cost in drq_net)"),
        ("command issue -> first DRQ, warm cache", r1.get("warm_drq_ns"),
         "READ1 warm rows"),
        ("single-sector PIO transfer (256 words)", r1.get("cold_xfer_ns"),
         "READ1 cold rows, xfer"),
        ("per-word PIO transfer", (r1.get("cold_xfer_ns") or float("nan")) / 256,
         "READ1 cold xfer / 256; CAL DATWORD is the access floor"),
        ("multi-sector first sector (incl. command)", rn.get("multi_cold_first_ns"),
         "READN t=1 k=1"),
        ("multi-sector per-sector incremental", rn.get("multi_cold_tail_incr_ns"),
         "READN t=1 k>1 median (drq gap + transfer)"),
        ("multi-sector effective per sector", rn.get("multi_cold_per_sector_ns"),
         "READN t=1 total / N"),
        ("one status poll iteration", cal.get("POLLLP+tot"),
         "CAL POLLLP (in + inc + test + jnz + loop)"),
        ("one bare status read", cal.get("POLLSTA"),
         "CAL POLLSTA excess over control"),
        ("one alternate-status read", cal.get("POLLALT"),
         "CAL POLLALT excess over control"),
        ("one timestamp pair (window bracket)", cal.get("TSTAMP+tot"),
         "CAL TSTAMP - the bias bound on the windows above"),
    ]
    for name, val, src in rows:
        if val is None or val != val:
            print(f"  {name:38} {'(not measured)':>12}   [{src}]")
        elif val >= 100_000:
            print(f"  {name:38} {val / 1e3:>9.1f} us   [{src}]")
        else:
            print(f"  {name:38} {val:>9.1f} ns   [{src}]")
    print(
        "\n  These are ABSOLUTE (device-crystal) numbers: unlike the /TIME ladder's"
        "\n  nanoseconds they carry no run-local scale and compare across runs directly."
        "\n  Poll cost shape: net each drq window by subtracting polls x one poll"
        "\n  iteration (drq_net in READ1) to bracket the true DRQ assertion to within"
        "\n  one poll iteration of the loop."
    )


def decode(text: str) -> bool:
    """Decode one capture.  Returns True when its DECISION CONSTANTS were refused:
    an incomplete run, or a failure of THIS decoder's own row-by-row 8:1
    cross-check.  The probe's SELFCHECK tally is a secondary diagnostic - when it
    fails while the cross-check passes, the capture is quoted and the instrument
    defect is named (TODO 89).  main() exits non-zero on a refusal."""
    global PIT_HZ, ART_DEGENERATE
    PIT_HZ = 2_457_600
    ART_DEGENERATE = False
    found, opens, closes = sections(text)
    cal_rows, r1_rows, rn_rows, rn_ends = parse_all(found)
    bad_read = degenerate_read_rows(r1_rows, rn_rows, rn_ends)
    ART_DEGENERATE = any(v >= ART_NEGATIVE for _, v in bad_read)
    m = re.search(r"SELFCHECK windows=(\d+) ok=(\d+) fail=(\d+) sub=(\d+)", text)
    selfcheck = tuple(int(x) for x in m.groups()) if m else None
    # The decoder's OWN cross-check of the printed fields is the authority; the
    # probe's tally is a secondary diagnostic (see own_cross_check).
    agree, checked, degen, skipped, failing = own_cross_check(cal_rows, r1_rows, rn_rows, rn_ends)
    own_ok = checked > 0 and not failing
    tally_failed = bool(selfcheck and selfcheck[2] > 0)
    scale_defect = probe_tally_scale_defect(text)
    # A run that hung (a BEGIN: with no END:) or stopped before the DONE trailer has
    # only partial rows, and the trap is exactly that they look like data.  The
    # DECISION CONSTANTS are refused for it too.
    closed = set(closes)
    hung = [o for o in opens if o not in closed]
    done = "IDELAT DONE" in text
    absent = [s for s in ("SETUP", "CAL", "READN", "READ1", "RESTORE") if s not in found]
    incomplete = bool(hung or absent or not done)
    # Refusal keys on the decoder's OWN cross-check plus an incomplete run - the
    # probe's tally can only add the INSTRUMENT DEFECT banner, never a refusal.
    refuse = incomplete or checked == 0 or bool(failing)

    m = re.search(r"GEO w1 w3 w6 w49 w60 w61 =\s*([0-9A-Fa-f ]+)", text)
    if m:
        print("== SETUP ==")
        print(f"  IDENTIFY geometry words: {m.group(1).strip()}")
    m = re.search(r"RANGE cyl=0000 head=00 nsec=(\d+) spt=(\d+)", text)
    if m:
        print(f"  scratch range: cyl 0 / head 0 / sectors 1..{int(m.group(1)) + 3}"
              f" (sectors/track {m.group(2)})")
    m = re.search(r"PITDIV \(diagnostic only\) coherent max=([0-9A-Fa-f]+) accepted=([0-9A-Fa-f]+)/([0-9A-Fa-f]+)", text)
    if m:
        div = int(m.group(1), 16)
        acc, tot = int(m.group(2), 16), int(m.group(3), 16)
        note = "" if tot == 0 or acc * 2 >= tot else " (low coherence: the latch read still tears - timing unaffected, PIT is refereed per window)"
        print(f"  PITDIV diagnostic: 0x{div:04X} coherent pairs {acc}/{tot}{note}")
        # The divisor is the strap discriminator - 0x4E00 means the
        # BIOS work-area 0501 bit-7 strap selects the 1.9968 MHz oscillator and
        # every PIT-derived figure moves 19% (2.4576/1.9968).
        if 0x4800 <= div <= 0x5400:
            PIT_HZ = 1_996_800
            print("  PIT STRAP: divisor ~= 0x4E00 -> the 1.9968 MHz oscillator"
                  " (work-area 0501 bit 7); PIT rate switched to 1996800 counts/s")
        elif 0x5A00 <= div <= 0x6600:
            print("  PIT STRAP: divisor ~= 0x6000 -> the 2.4576 MHz oscillator"
                  " (work-area 0501 bit 7)")
        else:
            print(f"  ** PIT STRAP UNRECOGNIZED: divisor 0x{div:04X} is neither 0x6000"
                  " nor 0x4E00 (tearing?). Assuming 2.4576 MHz; the absolute PIT"
                  " columns (sub-tick windows only) may be skewed. **")

    print()
    if selfcheck is not None:
        win, ok, failed, sub = selfcheck
        print(f"== SELFCHECK (the probe's own pit:artic 8:1 tally) ==")
        print(f"  windows checked {win}: ok {ok}, fail {failed}, sub-tick {sub}")
        if failed and own_ok:
            print()
            print("  *** INSTRUMENT DEFECT (probe self-check), DATA CONSISTENT ***")
            print(
                f"  The probe's chk_pair failed {failed} of its {win} windows, but THIS decoder's\n"
                f"  own cross-check of the same printed fields agrees on {agree}/{checked} window(s)\n"
                "  at the 8:1 law - the probe's tally and the fields disagree, and the fields are\n"
                "  the evidence. Refusing a consistent capture is as bad as quoting a torn one."
            )
            if scale_defect:
                pit, claimed = scale_defect
                print(
                    f"  Signature: the probe printed `8 x ARTIC delta={claimed:08X}` for\n"
                    f"  `PIT delta={pit:08X}` - {claimed:08X} = {pit:08X} x 8, i.e. it scaled the PIT\n"
                    "  column (the two operands rode in one register: a 16-bit `mov` into AX after\n"
                    "  loading EAX from the ARTIC array leaves EAX holding the PIT). TODO 89; the\n"
                    "  probe is fixed, and the constants below are quoted from the fields as printed."
                )
            if PIT_HZ != 2_457_600:
                print_strap_note()
            print(
                "  The DECISION CONSTANTS below are QUOTED: they come from the printed fields,\n"
                "  cross-checked here. Re-running the fixed IDELAT.COM is optional (a clean tally\n"
                "  for the record) - no machine re-run is needed for these numbers."
            )
        elif failed:
            print(
                "  *** SELF-CHECK FAILED: this capture's own PIT and ARTIC columns disagree at\n"
                "  the 8:1 law, so neither can be quoted. The DECISION CONSTANTS are REFUSED.\n"
                "  Re-run IDELAT.COM (the probe exits 1 on this too). ***"
            )
            if PIT_HZ != 2_457_600:
                print(
                    "  NOTE (strap): this capture's PITDIV says the 1.9968 MHz strap (0x4E00),\n"
                    "  where the law is 6.5 raw counts per ARTIC tick, NOT 8: chk_pair assumes the\n"
                    "  2.4576 MHz strap, so a failure here is the STRAP and not a sign/order bug -\n"
                    "  re-derive the band before diagnosing anything."
                )
    # The cross-check block is the reconciliation with the probe's own tally, so it
    # is printed only when the capture carries one: a pre-self-check capture (the
    # first IDELAT run) decodes byte-identically to before this change.
    if selfcheck is not None:
        print()
        print("== decoder cross-check (authoritative: computed from the printed fields) ==")
        aside = []
        if degen:
            aside.append(f"{degen} degenerate (the sign defect, above)")
        if skipped:
            aside.append(f"{skipped} sub-tick")
        print(f"  {agree}/{checked} window(s) agree at 8:1 (ok or the documented WRAP)"
              + (f"; aside: {', '.join(aside)}" if aside else ""))
        if failing:
            print(f"  *** {len(failing)} window(s) DISAGREE: ***")
            for f in failing[:6]:
                print(f"    {f}")
            if len(failing) > 6:
                print(f"    (+{len(failing) - 6} more)")
        elif checked:
            print("  every checkable window agrees: this capture's numbers are quotable")
    if bad_read:
        print_degenerate_banner(bad_read, r1_rows, rn_rows, rn_ends)
    print()
    cal = print_cal(cal_rows)
    r1 = print_read1(r1_rows, cal)
    rn = print_readn(rn_rows, rn_ends, cal)
    if refuse:
        print("\n== DECISION CONSTANTS (what th5-ide aims for) ==")
        if not incomplete:
            print(
                f"  REFUSED: this decoder's own cross-check fails on {len(failing)} of"
                f" {checked} window(s),\n  so the printed fields are not evidence. Re-run"
                " IDELAT.COM and decode the new capture."
            )
        else:
            print(
                "  REFUSED: the run is INCOMPLETE, so these rows are partial data, not\n"
                f"  constants. hung={hung or '-'} absent={absent or '-'} "
                f"done={'yes' if done else 'no'}."
                "\n  Re-run IDELAT.COM and decode the new capture."
            )
        if not incomplete and PIT_HZ != 2_457_600:
            print_strap_note()
    else:
        print_decisions(cal, r1, rn)
        if tally_failed:
            print("\n  (the probe's own tally failed while the fields agree: see the"
                  " INSTRUMENT DEFECT banner above.)")

    print("\n== run completeness ==")
    print(f"  sections opened: {', '.join(opens) or '(none)'}")
    if hung:
        print(f"  HUNG (BEGIN: with no END:): {', '.join(hung)}")
    if absent:
        print(f"  NOT PRESENT: {', '.join(absent)}")
    if done:
        print("  complete: every BEGIN: has its END:, the sections are present and the run"
              " reached IDELAT DONE" if not (hung or absent) else
              "  IDELAT DONE printed, but the markers above say the capture is partial")
    else:
        print("  INCOMPLETE: no IDELAT DONE trailer")
    return refuse


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("captures", nargs="+", help="IDELAT capture file(s)")
    args = ap.parse_args()
    refused = False
    for path in args.captures:
        try:
            text = open(path, "r", errors="replace").read()
        except OSError as exc:
            print(f"cannot read {path}: {exc}", file=sys.stderr)
            return 1
        print(f"### {path}")
        refused |= decode(text)
        print()
    # Exit 1 when any capture's constants were refused (incomplete run or a failed
    # self-check), the way the probe exits 1 on its own FAIL markers.
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main())

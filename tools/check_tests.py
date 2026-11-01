#!/usr/bin/env python3
"""Check every testbench's STRUCTURE and VERDICT, statically.

No simulation, no build. Per bench it requires:

  1  a WHAT THIS PROVES banner whose text matches the manifest word for word
  2  a bound: a watchdog, or a cycle-limited run
  3  a verdict that cannot pass silently -- a failing run must exit non-zero, and a
     passing one must not also print a failure (Verilator's $finish returns from the
     process rather than aborting it, so a bare trailing $fatal runs after a PASS)
  4  the PASS marker the manifest declares, printed exactly
  5  the standard sections: WHAT THIS PROVES, DUT, CHECKS, VERDICT

Exit status 0 if every bench conforms.

Usage:
  tools/check_tests.py            check every bench against the rules above
  tools/check_tests.py --ledger   print the KNOWN-LEGACY sets for THIS tree, ready to
                                  paste, so the ledger below is read off the tree rather
                                  than typed by hand
  tools/check_tests.py --selftest plant the verdict shapes rule 3 exists to reject and
                                  require each to be caught, then re-check the real tree
                                  (a guard that cannot fail is the defect it hunts)

THE KNOWN-LEGACY DEBT LEDGER, and why a checker that is installed red is worse than one
that is absent. This tool was out of the tree for 421
commits while the benches kept being written and reviewed, and what it checks drifted:
77 of 202 benches no longer carry the manifest claim verbatim, 44 are missing one or more
of the DUT/CHECKS/VERDICT banners, 5 are shaped so a failing run still exits 0 and 1 has
no `$fatal(1, ...)` at all. None of that is the checker's opinion -- it is what the tree
says -- and none of it can be fixed from tools/: the fixes belong in the benches.

A checker that simply fails on all of it cannot be added to the gate, and one kept out of
the gate is a check nobody runs, which is the defect class this repository's own
check_lint.py docstring names. So the debt is ENUMERATED here instead of hidden: the four
sets below name the benches that carry each class of debt TODAY, and the bench name is a
work order for that bench. What the ledger does NOT do is tolerate
anything new:

  * a bench that is in no set must be clean -- ONE new bench with a diverged claim, no
    bound, a missing banner or a silent verdict fails this tool, which is the whole point
    of restoring it;
  * the ledger is SHRINK-ONLY and self-checking: an entry that no longer shows its class,
    or that names a bench which does not exist, is itself a failure, so the sets cannot
    rot into a suppression nobody can see. Paying the debt means deleting the entry.
"""
import importlib.util
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TB_DIR = ROOT / "tests/pc9821"

# The verdict forms that are acceptable, and the one that is not.
SILENT_PASS = re.compile(r'if\s*\(\s*errors\s*==\s*0\s*\)\s*\$display', re.S)
# The same defect under another name: a verdict that prints its failure and then $finish,
# so the process still exits 0. SILENT_PASS above keys on a counter called `errors`, which
# is how tb_pc9821_block_share.sv (its counter is `fails`) printed FAIL and exited 0 while
# satisfying every other rule in this file -- the class had a blind spot the whole time it
# was a ledger. This pattern is the shape itself, whatever the counter is called: a FAIL
# $display followed by $finish and NOTHING BETWEEN, with no $fatal on that path.
#
# THE `end` IS THE POINT. The first form of this pattern was
# `\s*` between the two statements, and `\s*` cannot cross an `end` -- so the same silent
# verdict WRAPPED IN begin/end read as clean, because whitespace is not the only thing that
# can sit between a FAIL display and its $finish. The wrapper is optional textually (a
# one-line `if` needs none, a multi-statement arm does), so the pattern allows one `end`
# there. It still requires the $finish to be reached with NO $fatal in between: a shape like
# `if (fails != 0) begin $display("FAIL"); $fatal(1, ...); end $finish;` is a correct verdict
# and does not match, and the selftest below holds both sides of that line.
SILENT_FINISH = re.compile(
    r'\$display\s*\(\s*"[^"]*FAIL[^"]*"[^;]*\)\s*;\s*\n'
    r'(?:\s*end\s*\n)?'
    r'\s*\$finish\s*;', re.S)
# The other shape that returns 0 on failure: a verdict block that ends with a bare
# trailing $fatal. Verilator's $finish returns from the process rather than aborting
# it, so that $fatal also runs after a PASS and prints "FAIL (0 errors)". Six benches
# already had this shape and r7 recorded it; my own rewrite then spread it to ten
# more. The correct form has `else`.
BARE_TRAILING_FATAL = re.compile(r"\$finish;\s*\n\s*end\s*\n\s*\$fatal\s*\(", re.S)
HARD_FAIL = re.compile(r"\$fatal\s*\(\s*1\s*,", re.S)

# The sections every bench must have. STIMULUS is expected but not required: a bench
# with no helper tasks drives the DUT inline in its run block, and open_bus is one.
SECTIONS = ["WHAT THIS PROVES", "DUT", "CHECKS", "VERDICT"]
OPTIONAL_SECTIONS = ["STIMULUS"]

INTEGRATED = ["boot", "portharness", "userdisk", "throttle", "dma_snoop_throttle"]

# ---------------------------------------------------------------------------------------
# THE LEDGER: benches that carry each class of debt today. See the module docstring.
# ---------------------------------------------------------------------------------------
# The manifest claim and the bench's WHAT THIS PROVES banner have diverged (the claim was
# updated for a change and the banner was not, or the other way round). The fix is to make
# the banner the manifest claim, word for word, which is what tests/pc9821/
# tb_pc9821_gvram_decouple.sv:6 "manifest claim VERBATIM" already states as the convention.
# PAID: all 71 benches now open their banner with the claim
# verbatim, so the class is enforced for every bench rather than owed. Six claims were
# CORRECTED rather than copied, because the bench and the claim disagreed about what is
# proved and the bench was right: kbd_codes (99 agree / 2 divergences, not 98/3),
# cg_window (the even/low page IS asserted at the machine's 0x8F), egc_regs (the GRCG
# bit-7 gate case IS asserted through the bench's own AND), pcm86_cdc (the 20-bit bus's
# 0x7FFFF/0x80000, not the 16-bit codes), ata_throughput (4856 clk/sector - the bench's
# own 4600 + 256 - not a stale 4926) and sound_sum (the claim was a fragment with no
# subject).
CLAIM_DRIFT = set()

# One or more of the DUT / CHECKS / VERDICT banners is absent. Owed by the bench:
# either the banners or the rule, but a bench that cannot be read structurally is how a
# bench loses its claim quietly. PAID: every bench now names
# its four sections, so the class is enforced for every bench rather than owed. The banners
# were placed where the block they name begins (DUT = the declaration/instance block, CHECKS
# = the check helpers and the run, VERDICT = the verdict), and a few benches whose header
# carried a section MAP further up the file had those map lines demoted to sub-headings,
# because the checker reads the first occurrence of each banner.
MISSING_BANNERS = set()

# `if (errors == 0) $display(PASS)` with no `$fatal` at all: a run that found a mismatch
# prints no PASS marker but exits 0, so a hand-run looks green. tools/bench.py still fails
# such a bench (it requires the marker AND exit 0), which is why this was debt rather than
# an emergency. PAID: both remaining benches carried the
# shape and now raise the exit code, so the set is empty and the class is enforced for
# every bench -- a new one that can pass silently is a hard failure, not ledger debt.
# Note the detector is `if (errors == 0) $display` textually: a bench whose verdict is
# `if (errors == 0) begin $display(PASS); end else $fatal(1, ...)` is correct and the
# textual form is what the checker can see, which is why the verdicts below use it.
EXITS_ZERO_ON_FAILURE = set()

# No `$fatal(1, ...)` anywhere in the file: the failing path cannot make the process exit
# non-zero even in principle.
NO_FATAL = set()

LEDGER = (
    ("claim", CLAIM_DRIFT,
     "its WHAT THIS PROVES text does not match the manifest's claim"),
    ("banner", MISSING_BANNERS,
     "missing section banner(s)"),
    ("silent-pass", EXITS_ZERO_ON_FAILURE,
     "CAN PASS SILENTLY"),
    ("no-fatal", NO_FATAL,
     "no $fatal(1, ...) anywhere"),
)


def load_table():
    """name -> (marker, claim). The unit benches come from the manifest; the three
    integrated benches are declared with it and checked the same way."""
    spec = importlib.util.spec_from_file_location("gb", ROOT / "tools/gen_bench_sources.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    table = {n: (v[0], v[1]) for n, v in mod.BENCHES.items()}
    for n in INTEGRATED:
        table[n] = (None, None)          # marker/claim filled in below, from the file
    return table


def check_bench(name, marker, manifest_claim, src):
    """Every problem with one bench, as (class, message) pairs.

    The class is what the ledger keys on; the message is what a reader sees."""
    problems = []

    # 1. claim banner
    if "==== WHAT THIS PROVES ====" not in src:
        problems.append(("banner-absent", "no 'WHAT THIS PROVES' banner"))

    # 2. BOUNDED, which is not the same as "has a #delay watchdog". A bench is
    #    bounded if a watchdog can fire, or if its run cannot outlast a cycle
    #    count: boot uses `repeat (20_000_000) @(posedge clk_sys)` and userdisk a
    #    cycle budget, and both terminate. Only accepting the watchdog form
    #    reported those two as unbounded. Case-insensitive because calendar and
    #    pic spell it "timeout".
    #
    #    BOTH FORMS WERE WIDENED after four benches read as unbounded that are not:
    #    three end their run with a finite `for (i = 0; i < DIRECTED + 20000; ...)`
    #    cycle loop and one carries a watchdog whose delay is an EXPRESSION
    #    (`#(RESET_NS + WINDOW_NS + 20_000_000); $fatal(1, "timeout")`). The
    #    loop form is accepted only for a CYCLE-SCALE trip count (a four-digit
    #    numeric, or a parameter plus one) and only when the loop waits on a clock,
    #    so the `for (w = 0; w < 4; ...)` stimulus loops inside benches cannot pass
    #    for a bound.
    has_watchdog = re.search(r"#(?:[\d_]+|\([^;\n]*\))\s*;[\s\S]{0,240}?\$fatal",
                             src) is not None
    cycle_bounded = re.search(
        r"repeat\s*\(\s*[\d_'eE]+\s*\)\s*@\s*\(\s*posedge"
        r"|tb_cycle\s*<\s*budget"
        r"|while\s*\([^)]*<\s*(?:budget|[\d_]+)"
        r"|for\s*\(\s*\w+\s*=[^;]*;\s*\w+\s*<\s*(?:[\w']+\s*\+\s*)?[\d_']{4,}\s*;"
        r"[^)]*\)[\s\S]{0,300}?@\s*\("
        r"|for\s*\(\s*\w+\s*=[^;]*;\s*\w+\s*<\s*(?:[\w']+\s*\+\s*)?[\d_']{4,}\s*;"
        r"[^)]*\)\s*@\s*\(", src) is not None
    if not (has_watchdog or cycle_bounded):
        problems.append(("bound", "no bound: neither a watchdog nor a cycle-limited run"))
    # A bare `wait (...)` BEFORE the cycle bound is not bounded: the bound lives
    # after it, so a regression that never satisfies the wait hangs until the
    # runner's wall clock (lane 07 measured 30 minutes of that).
    code_only = re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", src, flags=re.S))
    wait_pos = code_only.find("wait (")
    if wait_pos < 0:
        wait_pos = code_only.find("wait(")
    bounds = [m.start() for m in re.finditer(r"repeat\s*\(|tb_cycle\s*<", code_only)]
    bound_pos = bounds[-1] if bounds else -1
    # Only meaningful when no `#delay` watchdog exists: a watchdog in its own
    # initial block fires even while the stimulus is stuck in a wait, so pic (which
    # has one) is bounded and boot/userdisk (which do not) are not.
    early_wait = wait_pos >= 0 and bound_pos >= 0 and wait_pos < bound_pos and not has_watchdog

    # 3. cannot pass silently
    if BARE_TRAILING_FATAL.search(src):
        problems.append(("bare-trailing-fatal",
                         "verdict ends with a bare trailing $fatal: a PASS would also "
                         "print FAIL(0 errors), and a failure would exit 0"))
    elif SILENT_PASS.search(src):
        problems.append(("silent-pass",
                         "CAN PASS SILENTLY: `if (errors == 0) $display(PASS)` with no $fatal"))
    elif SILENT_FINISH.search(src):
        problems.append(("silent-pass",
                         "CAN PASS SILENTLY: a FAIL $display followed by $finish, with no "
                         "$fatal on that path (the process exits 0)"))
    elif not HARD_FAIL.search(src):
        problems.append(("no-fatal",
                         "no $fatal(1, ...) anywhere: a failing run would not exit non-zero"))

    # 4. marker matches the manifest
    if f'"{marker}: PASS"' not in src:
        problems.append(("marker", f"does not print the declared marker '{marker}: PASS'"))

    # 4b. the stated claim is the manifest's claim, word for word, so the bench
    #     and the manifest cannot drift apart about what is being proved.
    #
    #     NOTE the containment is over the RAW source with only whitespace
    #     collapsed, so a claim wrapped across two `//` lines does NOT match (the
    #     comment marker between them is a character, not whitespace). Two benches
    #     sat on this ledger for exactly that reason: readback_ata and
    #     readback_sysports carried the claim word for word, line-wrapped. Write the
    #     claim as ONE comment line at the top of WHAT THIS PROVES, the shape
    #     tb_pc9821_gvram_decouple.sv and tb_pc9821_artic_word.sv use.
    if manifest_claim:
        body = re.sub(r"\s+", " ", src)
        if re.sub(r"\s+", " ", manifest_claim) not in body:
            problems.append(("claim", "its WHAT THIS PROVES text does not match the manifest's claim"))

    # 5. sections, in order
    pos = [src.find(f"==== {s} ====") for s in SECTIONS]
    missing = [s for s, q in zip(SECTIONS, pos) if q < 0]
    if missing:
        problems.append(("banner", "missing section banner(s): " + ", ".join(missing)))
    elif pos != sorted(pos):
        problems.append(("banner-order", "section banners are out of order"))
    no_stimulus = not any(src.find(f"==== {o} ====") >= 0 for o in OPTIONAL_SECTIONS)

    return problems, early_wait, no_stimulus


def ledger_for(cls):
    for name, members, _text in LEDGER:
        if name == cls:
            return members
    return None


def print_ledger(table):
    """The sets for this tree, ready to paste into this file."""
    found = {cls: set() for cls, _members, _text in LEDGER}
    for name, (marker, claim) in sorted(table.items()):
        path = TB_DIR / f"tb_pc9821_{name}.sv"
        if not path.exists():
            continue
        src = path.read_text()
        eff_marker = marker or f"TB_PC9821_{name.upper()}"
        problems, _early, _no_stim = check_bench(name, eff_marker, claim, src)
        for cls, _msg in problems:
            if cls in found:
                found[cls].add(name)
    for cls, _members, _text in LEDGER:
        names = sorted(found[cls])
        print(f"{cls} ({len(names)}):")
        for n in names:
            print(f'    "{n}",')


# ---------------------------------------------------------------------------------------
# THE SELFTEST: plant the verdict shapes rule 3 exists to reject, plus one correct verdict
# that must be accepted. Every planted source is otherwise a whole well-formed bench --
# bounded, bannered, marker and claim matching -- so the ONLY thing the checker can
# complain about is the shape under test, and `check_bench` is called on the text exactly
# as the real benches are. This is the audit's own method (plant a mutant, require the
# guard to catch it, with a control that must pass) kept in the tool, because a scanner
# whose regex silently stops matching passes forever -- which is what F1 was.
# ---------------------------------------------------------------------------------------
SELFTEST_MARKER = "TB_PC9821_SELFTEST"
SELFTEST_CLAIM = "a planted bench: the claim line the checker must find verbatim"


def _planted_bench(verdict: str, *, bound: bool = True, claim: bool = True,
                   sections: bool = True) -> str:
    """A planted bench's text: well-formed except for what the flags remove."""
    watchdog = ("initial begin\n"
                "  #(20_000_000);\n"
                "  $fatal(1, \"timeout\");\n"
                "end\n") if bound else ""
    return ("`timescale 1ns/1ps\n"
            "// ==== WHAT THIS PROVES ====\n"
            + (f"// {SELFTEST_CLAIM}\n" if claim else "")
            + ("// ==== DUT ====\n  // ==== CHECKS ====\n" if sections else "")
            + "module tb;\n"
              "  integer fails = 0;\n"
            + watchdog + verdict + "endmodule\n")


def _cases() -> list:
    """(label, expected problem classes, verdict text, other planted flags) per shape."""
    marker = f'"{SELFTEST_MARKER}: PASS"'
    good = ("  // ==== VERDICT ====\n"
            f"  if (fails == 0) begin\n    $display({marker});\n  end else begin\n"
            "    $display(\"  FAIL: %0d mismatches\", fails);\n"
            "    $fatal(1, \"FAIL (%0d)\", fails);\n  end\n  $finish;\n")
    silent_bare = ("  // ==== VERDICT ====\n"
                   f"  if (fails == 0) $display({marker});\n"
                   "  if (fails != 0) $display(\"  FAIL: %0d mismatches\", fails);\n"
                   "  $finish;\n")
    silent_wrapped = ("  // ==== VERDICT ====\n"
                      f"  if (fails == 0) begin\n    $display({marker});\n  end\n"
                      "  if (fails != 0) begin\n"
                      "    $display(\"  FAIL: %0d mismatches\", fails);\n  end\n"
                      "  $finish;\n")
    trailing_fatal = ("  // ==== VERDICT ====\n"
                      f"  if (fails == 0) begin\n    $display({marker});\n    $finish;\n  end\n"
                      "  $fatal(1, \"FAIL (%0d failures)\", fails);\n")
    no_fatal = ("  // ==== VERDICT ====\n"
                f"  if (fails == 0) $display({marker});\n  $finish;\n")
    wrong_marker = ('  // ==== VERDICT ====\n'
                    '  if (fails == 0) $display("TB_PC9821_OTHER: PASS");\n'
                    '  else $fatal(1, "FAIL");\n  $finish;\n')
    return [
        ("the correct verdict (the control)", set(), good, {}),
        ("a FAIL $display then $finish", {"silent-pass"}, silent_bare, {}),
        ("the same FAIL $display inside begin/end", {"silent-pass"}, silent_wrapped, {}),
        ("a bare trailing $fatal", {"bare-trailing-fatal"}, trailing_fatal, {}),
        ("no $fatal(1, ...) at all", {"bound", "no-fatal"}, no_fatal, dict(bound=False)),
        ("no bound", {"bound"}, good, dict(bound=False)),
        ("a marker that is not the manifest's", {"marker"}, wrong_marker, {}),
        ("a missing section banner", {"banner"}, good, dict(sections=False)),
        ("a banner with no claim under it", {"claim"}, good, dict(claim=False)),
    ]


def selftest() -> int:
    """Every planted shape must be caught, the correct one accepted, then the real tree."""
    cases = _cases()
    failures = []
    for label, want, verdict, flags in cases:
        src = _planted_bench(verdict, **flags)
        found, _early, _no_stim = check_bench("planted", SELFTEST_MARKER, SELFTEST_CLAIM, src)
        got = {cls for cls, _msg in found}
        if got != want:
            failures.append(f"{label}: expected {sorted(want) or 'no problem'}, the checker "
                            f"reported {sorted(got) or 'no problem'}")
    if failures:
        print("TEST STRUCTURE SELFTEST: FAIL")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"TEST STRUCTURE SELFTEST: PASS ({len(cases)} planted bench(es): every rejected "
          f"shape was caught and the correct verdict was accepted)")
    print("   the real tree must also stay clean (that is the other half of a selftest):")
    return check_tree(load_table(), quiet=True)


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    table = load_table()
    if "--ledger" in sys.argv:
        print_ledger(table)
        return 0
    return check_tree(table)


def check_tree(table: dict, quiet: bool = False) -> int:
    problems = {}
    NOTE = []

    def note(name, cls, msg):
        problems.setdefault(name, []).append((cls, msg))

    integrated_claims = {
        "boot": "The diagnostic pack boots through the real CPU, memory and I/O path and "
                "reaches its own result marker.",
        "portharness": "A script of port operations runs against the real I/O bus and prints "
                       "one machine-readable line per access with its cycle; a failed "
                       "expectation exits non-zero and an unknown op is reported rather than "
                       "ignored.",
        "throttle": "The OSD CPU Speed throttle slows the CPU and only the CPU, through the real CPU, bridge, memory and I/O path: at 8 MHz and at 1 MHz a 4096-iteration DEC/JNZ takes the clock ratio times its full-speed time (within 3%), a 12288-dword REP STOSD takes at least one throttled CPU edge per dword (the throttle acts inside the REP, which an instruction-boundary throttle cannot), every timed interval is its CPU-edge count at the selected rate, and the guest's architectural results - a data-dependent checksum over the region re-read after a whole-L1 flush, and the region itself - are identical at every setting, with a CPU reset, an I/O read, burst line fills, the 0x043F flush and an INTA all crossing the gated-clock bridge on the way; and at every setting an IRQ0 the 8259 raises a few platform cycles after it acknowledges IRQ2 (its INT low for less than one throttled CPU clock) is still taken once the IRQ2 handler's IRET sets IF (a 486 samples INTR as a level, so INTR need not be seen low between two requests).",
        "dma_snoop_throttle": "TB_PC9821_DMA_SNOOP_THROTTLE: DMA writes accepted by the backend inside a gated (cpu_ce=0) CPU run still invalidate every line they land in - one FDC byte held for the next enabled edge, then TWO back-to-back bytes of a software-request channel-0 transfer in ONE disabled run, each into a different cached line, with both re-reads coherent. It runs the REAL pc9821_system (real z486, real gated cpu_clk, real bridge, real iobus/FDC/uPD71071) at OSD CPU Speed = 1 MHz, so a disabled run spans the uPD71071's ~8-cycle byte cadence: a one-deep snoop hold would let the second accept replace the first address and leave the first line stale, and the bench also asserts no write was accepted while the bridge held a snoop (the back-pressure).",
        "userdisk": 'The AUTHENTIC firmware against a user IDE image reaches the IPL at 1FC0:0000, and before that it passes the CG-window configuration record asserted by the ITF\'s own writes (no repair store at 0x811, the accept-only stage 0x05). That is a control-flow criterion and cannot see wrong sector data; this is the only tier that exercises the disk at all, it is skipped when PC98_USERDISK is unset, and its instruments run during the run rather than on a timeout path.',
    }
    for name, entry in sorted(table.items()):
        marker = entry[0] or f"TB_PC9821_{name.upper()}"
        manifest_claim = entry[1] or integrated_claims.get(name)
        path = TB_DIR / f"tb_pc9821_{name}.sv"
        if not path.exists():
            note(name, "no-such-bench", "no such testbench")
            continue
        src = path.read_text()
        found, early_wait, no_stimulus = check_bench(name, marker, manifest_claim, src)
        for cls, msg in found:
            note(name, cls, msg)
        if early_wait:
            # A NOTE, not a failure: this check cannot reason about `fork ... join_any`
            # with a bounded sibling (boot's remaining waits are inside one) and it
            # cannot tell code from comments without stripping them. It found three
            # genuinely unbounded pack waits, which are now fixed; a human must judge
            # what is left. Reporting it as a failure would be a false gate.
            NOTE.append(f"{name}: a `wait (` precedes the last cycle bound with no "
                        f"watchdog -- verify by reading that a bounded sibling covers it")
        if no_stimulus:
            NOTE.append(f"{name}: no separate STIMULUS section (the DUT is driven "
                        f"inline in the run block)")

    # The ledger is checked in both directions: an entry that is no longer true, or that
    # names a bench which does not exist, is a failure. Deleting a paid entry is part of
    # paying it, which is what keeps these sets from becoming a suppression nobody sees.
    stale_ledger = []
    for cls, members, _text in LEDGER:
        for name in sorted(members):
            if name not in table:
                stale_ledger.append(f"{cls}: '{name}' is not a bench in the manifest")
            elif name not in problems or cls not in {c for c, _m in problems[name]}:
                stale_ledger.append(f"{cls}: '{name}' no longer shows this problem -- "
                                    f"delete the ledger entry")

    # Everything a ledger entry covers is reported as debt; everything else fails.
    fatal = {}
    for name, found in problems.items():
        for cls, msg in found:
            members = ledger_for(cls)
            if members is not None and name in members:
                continue
            fatal.setdefault(name, []).append(msg)

    width = max(len(n) for n in table) if table else 10
    if not quiet:
        for name in sorted(table):
            found = problems.get(name, [])
            if name in fatal:
                state = "PROBLEM"
            elif found:
                state = "legacy"
            else:
                state = "ok"
            print(f"{name:<{width}}  {state}")
            for msg in fatal.get(name, []):
                print(f"{'':<{width}}    - {msg}")

    live = len({n for _cls, members, _text in LEDGER for n in members if n in problems})
    if not quiet:
        print()
        for n in NOTE:
            print(f"note: {n}")
    if live:
        by_class = ", ".join(f"{cls} {len(members)}" for cls, members, _text in LEDGER)
        print(f"ledger: {live} bench(es) carry KNOWN-LEGACY debt ({by_class}) -- "
              f"see the sets at the top of this file and the report; a clean bench is "
              f"one that appears in none of them")
    for name in sorted(fatal):
        if quiet:
            for msg in fatal[name]:
                print(f"{name}: PROBLEM - {msg}")
    for bad in stale_ledger:
        print(f"STALE LEDGER ENTRY: {bad}")
    if fatal or stale_ledger:
        print(f"TEST STRUCTURE: FAIL ({len(fatal)} bench(es) with problems this ledger does "
              f"not cover, {len(stale_ledger)} stale ledger entry/entries)")
        return 1
    total = len(table)
    print(f"TEST STRUCTURE: PASS ({total} benches: {total - live} clean, "
          f"{live} on the debt ledger)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

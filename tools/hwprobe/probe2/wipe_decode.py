#!/usr/bin/env python3
"""wipe_decode.py - parse a PROBE2 /WIPE capture into machine numbers, each beside
the core's own number, with the hypothesis the experiment tests and its verdict.

Usage:
    python3 tools/hwprobe/probe2/wipe_decode.py WIPE.TXT [WIPE2.TXT ...]

WHAT IT DECODES. `PROBE2 /WIPE` (tools/hwprobe/probe2/probe2.s, section /WIPE)
replicates the C-Lab logo's wipe step (CLABLOGO.EXE `CS:0x2C0`) on the real
machine, in the game's own 640x400 16-colour mode, and prints one `WIPE ...` row
per measurement:

    WIPE ASFOUND 0068=18 006A=00 007C=00 00A4=00 00A6=00 0002=7D
    WIPE W1 MIX=alu OPS=6 ITERS=1048576 ARTIC=...
    WIPE W1 MIX=rowbody ITERS=9900 ARTIC=...
    WIPE W1 MIX=rowbody-gfx ITERS=9900 ARTIC=...
    WIPE W6 CALL=41 ARTIC=...
    WIPE W5 FRAMES=64 LINES=28160 ARTIC=348480
    WIPE STEP ARM=W2 MODE=disp-on IDX=0 FILL=... ROWS=... FLIP=... TOTAL=...
    WIPE W4 IMR 0002=7D window=79 readback=79
    WIPE W3 DISPLAY 0068=98 -> blank 18 readback=18
    WIPE W4 IMR restored 0002=7D now=7D vector=FD80:0937 IRQS=3
    WIPE RESTORE 0068=18 -> 18 ...
    WIPE RESTVEC FD80:0937 -> FD80:0937

TIME BASE. ARTIC ticks are converted with the device clock only: 1 tick =
3255.208333 ns (307 200 Hz, the rate a raster check on the machine confirmed and
the rate FLIP.TXT's own PERIOD line is quoted against), i.e. 162.7604 clk_sys per
tick at the core's 50 MHz. Absolute nanosecond figures are therefore comparable
across runs and machines; nothing here is scaled by a run-local constant.

THE CORE'S NUMBERS come from a core-side bench replay of the same step (a
one-off research bench, not kept in the tree) and from the FLIP.TXT raster
capture. Unlike the machine's columns they are BENCH results, so they carry the
commit they were measured at - a hand-copied bench number is a constant that
rots the moment the RTL moves. It already did once: the GVRAM latency fix's
per-operation GVRAM acceptance period took the step from 22 508 to 30 507 clk_sys
and the fill from 11 999 to 19 995, while the blit (which has to read anyway) and
the I/O term did not move:

    whole step (walk only)  30 507 clk_sys = 610.1 us, 16 398 array accesses
    the 4000-word fill      19 995 clk_sys = 399.9 us
    the 100x20-word blit     9 997 clk_sys = 199.9 us   (4 array accesses/store)
    tile loads + GRCG + flip  1 624 clk_sys =  32.5 us  (I/O bus, not walk)
    frame period             5445 ARTIC ticks = 17.7232 ms / 440 lines
    row body (derived)       ~890 clk_sys = 17.8 us per row

The decoder prints the provenance of its core column in its header block, so a
reader can see how old it is without opening this file.

DEGENERACY IS REFUSED, NOT AVERAGED. A capture with no BEGIN/END:WIPE pair, no
STEP rows, an arm that is missing, a step whose phases do not add up to its own
TOTAL, or a RESTORE row whose read-back differs from the as-found byte is
reported loudly and the derived numbers are withheld: the raw columns are the
evidence, and a torn capture must not produce a plausible-looking number
(the lesson of the 2026-09-24 capture set).

HYPOTHESES. Every experiment's row prints the hypothesis it tests and a verdict
word (CONFIRMED / REFUTED / INDETERMINATE) computed from the numbers, so the
capture's own table of contents is its conclusion.

Nothing here talks to hardware; it is a pure text parser.
"""

from __future__ import annotations

import argparse
import re
import sys

NS_PER_TICK = 1e9 / 307_200          # 3255.208333 ns
CLK50_PER_TICK = 50_000_000 / 307_200  # 162.7604 clk_sys per tick

# --- the core's own numbers -------------------------------------------------
# PROVENANCE. Measured on tip a62e97db (committed 2026-09-24), the first tip
# carrying the GVRAM latency fix's per-operation GVRAM acceptance period.
# STEP/FILL/BLIT
# are the C3 steady-state step, the C1 fill and the C2 blit "accept" clk_sys of
# a one-off research replay bench (not in the gate's manifest and not kept in
# the tree), so treat them as dated. IO is the step's 406 GRCG-port writes + 2 page-flip
# writes at pc9821_iobus's IO_MIN_HOLD = 4 clk_sys - an I/O-bus price, not a
# GVRAM walk, so the fix did not move it (the replay's C4 note prints the same
# law with a 408-write count; neither number is load-bearing here).
CORE_STEP_SRC = "wipe-step replay bench @ a62e97db"
CORE_STEP_CLK = 30_507
CORE_STEP_NS = CORE_STEP_CLK * 20.0          # 610 140 ns (was 22 508 / 450 160)
CORE_FILL_CLK = 19_995                       # was 11 999 before the fix
CORE_BLIT_CLK = 9_997                        # unchanged: the blit reads anyway
CORE_IO_CLK = 1_624
CORE_FRAME_TICKS = 5_445.0                   # FLIP.TXT PERIOD=5445 (machine capture)
CORE_FRAME_NS = CORE_FRAME_TICKS * NS_PER_TICK
CORE_LINES = 440                             # FLIP.TXT, same capture
# DERIVED, not measured by the replay: the row body and the ALU body are the
# z486's instruction cost from the measured per-instruction rates applied to the
# row's instruction mix (wipe-step-probe-REPORT.md section 5.2). They are CPU
# numbers, so a GVRAM-side change (like the fix above) does not move them.
CORE_ROW_CLK = 890                           # per row body, report section 5.2
CORE_ALU_CLK_PER_ITER = 9.0                  # 6 instr at the measured 1-2 clk
CORE_RUN_LOGO_EDGES = 281.0                  # 151 + 65 + 65 frame units

# The wall-clock decomposition this probe is meant to close (measured
# totals): the un-synchronised T_draw is 2.0375 s on the machine and 1.0875 s on
# the core, i.e. ~20.6 / ~11.0 ms per step IF the wipe carried it - the number
# the reporting inherited and no static term could reproduce.
T_DRAW_MACHINE_MS_PER_STEP = 20.6
T_DRAW_CORE_MS_PER_STEP = 11.0

STEP_RE = re.compile(
    r"WIPE STEP ARM=(\S+) MODE=(\S+) IDX=(\d+) FILL=(\d+) ROWS=(\d+) FLIP=(\d+) TOTAL=(\d+)")
W1_RE = re.compile(r"WIPE W1 MIX=(\S+)(?: OPS=(\d+))? ITERS=(\d+) ARTIC=(\d+)")
W6_RE = re.compile(r"WIPE W6 CALL=(\S+) ARTIC=(\d+)")
W5_RE = re.compile(r"WIPE W5 FRAMES=(\d+) LINES=(\d+) ARTIC=(\d+)")
REST_RE = re.compile(r"WIPE RESTORE (.+)$")
RESTV_RE = re.compile(r"WIPE RESTVEC ([0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}) -> "
                      r"([0-9A-Fa-f]{4}:[0-9A-Fa-f]{4})")
IRQIMR_RE = re.compile(r"WIPE W4 IMR 0002=([0-9A-Fa-f]{2}) window=([0-9A-Fa-f]{2}) "
                       r"readback=([0-9A-Fa-f]{2})")
IRQEND_RE = re.compile(r"WIPE W4 IMR restored 0002=([0-9A-Fa-f]{2}) now=([0-9A-Fa-f]{2}) "
                       r"vector=([0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}) IRQS=(\d+)")
DISP_RE = re.compile(r"WIPE W3 DISPLAY 0068=([0-9A-Fa-f]{2}) -> blank "
                     r"([0-9A-Fa-f]{2}) readback=([0-9A-Fa-f]{2})")
ASFOUND_RE = re.compile(r"WIPE ASFOUND (.+)$")
PORTVAL_RE = re.compile(r"([0-9A-Fa-f]{4})=([0-9A-Fa-f]{2})")
PORTBACK_RE = re.compile(r"([0-9A-Fa-f]{4})=([0-9A-Fa-f]{2}) -> ([0-9A-Fa-f]{2})")

ARM_ORDER = ["W2", "W3", "W3B", "W4A", "W4B", "W4C"]


def ns(ticks: float) -> float:
    return ticks * NS_PER_TICK


def ms(ticks: float) -> float:
    return ticks * NS_PER_TICK / 1e6


def verdict(ok: bool | None) -> str:
    if ok is None:
        return "INDETERMINATE"
    return "CONFIRMED" if ok else "REFUTED"


class Capture:
    def __init__(self, path: str):
        self.path = path
        self.begin = self.end = False
        self.steps: dict[str, list[tuple]] = {}
        self.w1: dict[str, tuple] = {}
        self.w6: list[tuple] = []
        self.w5: tuple | None = None
        self.asfound: dict[str, str] = {}
        self.restore: dict[str, tuple] = {}
        self.restvec: tuple | None = None
        self.irq_imr: tuple | None = None
        self.irq_end: tuple | None = None
        self.disp_blank = None
        self.disp_unblank = None

    def parse(self) -> None:
        with open(self.path, "r", errors="replace") as fh:
            for raw in fh:
                line = raw.rstrip("\r\n")
                if "BEGIN:WIPE" in line:
                    self.begin = True
                if "END:WIPE" in line:
                    self.end = True
                m = STEP_RE.match(line)
                if m:
                    self.steps.setdefault(m.group(1), []).append(
                        (m.group(2), int(m.group(3)), int(m.group(4)),
                         int(m.group(5)), int(m.group(6)), int(m.group(7))))
                    continue
                m = W1_RE.match(line)
                if m:
                    self.w1[m.group(1)] = (int(m.group(3)), int(m.group(4)))
                    continue
                m = W6_RE.match(line)
                if m:
                    self.w6.append((m.group(1), int(m.group(2))))
                    continue
                m = W5_RE.match(line)
                if m:
                    self.w5 = (int(m.group(1)), int(m.group(2)), int(m.group(3)))
                    continue
                m = ASFOUND_RE.match(line)
                if m:
                    self.asfound = {p: v for p, v in PORTVAL_RE.findall(m.group(1))}
                    continue
                m = REST_RE.match(line)
                if m:
                    for p, was, now in PORTBACK_RE.findall(m.group(1)):
                        self.restore[p] = (was, now)
                    continue
                m = RESTV_RE.match(line)
                if m:
                    self.restvec = (m.group(1), m.group(2))
                    continue
                m = IRQIMR_RE.match(line)
                if m:
                    self.irq_imr = m.groups()
                    continue
                m = IRQEND_RE.match(line)
                if m:
                    self.irq_end = m.groups()
                    continue
                m = DISP_RE.match(line)
                if m:
                    if self.disp_blank is None:
                        self.disp_blank = m.groups()
                    else:
                        self.disp_unblank = m.groups()
                    continue


def arm_stats(steps: list[tuple]) -> dict:
    """Per-arm aggregation: whole-step and per-phase first-step / steady-state."""
    idx = [s[1] for s in steps]
    total = [s[5] for s in steps]
    steady = total[1:] if len(total) > 1 else total
    out = {
        "n": len(steps),
        "mode": steps[0][0],
        "first": total[0],
        "steady": sum(steady) / len(steady),
        "first_fill": steps[0][2],
        "first_rows": steps[0][3],
        "first_flip": steps[0][4],
        "fill": sum(s[2] for s in steps[1:]) / max(len(steps) - 1, 1),
        "rows": sum(s[3] for s in steps[1:]) / max(len(steps) - 1, 1),
        "flip": sum(s[4] for s in steps[1:]) / max(len(steps) - 1, 1),
        "idx_ok": idx == list(range(len(steps))),
        "total": total,
        "max": max(total),
        "min": min(total),
        "median": sorted(total)[len(total) // 2],
    }
    out["phase_sum_ok"] = all(s[2] + s[3] + s[4] == s[5] for s in steps)
    return out


def decode(cap: Capture) -> int:
    print(f"=== {cap.path} ===")
    rc = 0
    if not (cap.begin and cap.end):
        print("  ** REJECTED: no BEGIN:WIPE/END:WIPE pair - the /WIPE section hung, "
              "crashed or was never run.")
        print("     The section that died is the one named by its last BEGIN: marker "
              "(probe2 prints one per section), so a WIPE.TXT without END:WIPE is the "
              "measurement that /WIPE did not finish; power-cycle and re-run.")
        return 1
    if not cap.steps:
        print("  ** REJECTED: no WIPE STEP rows - nothing was measured.")
        return 1

    print("  anchor: ARTIC 307 200 Hz -> 3255.2083 ns/tick; "
          "162.7604 clk_sys/tick at the core's 50 MHz")
    print(f"  core column: {CORE_STEP_SRC} -> step {CORE_STEP_CLK} clk_sys "
          f"({CORE_STEP_NS/1000:.1f} us, walk only), fill {CORE_FILL_CLK}, "
          f"blit {CORE_BLIT_CLK}, I/O {CORE_IO_CLK}; FLIP.TXT frame "
          f"{CORE_FRAME_TICKS:.0f} ticks / {CORE_LINES} lines")
    print("    (dated bench numbers: re-measure before relying on them)")
    if cap.asfound:
        print("  as-found: " + " ".join(f"{p}={v}" for p, v in sorted(cap.asfound.items())))
    else:
        print("  ** no ASFOUND row: the first-touch bytes are not in this capture")
        rc = 1

    # ---- W1: the CPU term, measured --------------------------------------
    print()
    print("  W1  HYPOTHESIS: the CPU term is measurable, not derived (report 5.5's "
          "only soft number)")
    print(f"      {'MIX':<14}{'iters':>9}{'ARTIC':>8}{'ns/unit':>10}{'machine':>14}"
          f"{'core ns':>9}{'m/c':>7}  unit")
    if not cap.w1:
        print("      ** no W1 rows: the CPU calibration is missing")
        rc = 1
    for mix in ("alu", "rowbody", "rowbody-gfx"):
        if mix not in cap.w1:
            print(f"      ** MIX={mix} missing")
            rc = 1
            continue
        iters, artic = cap.w1[mix]
        per = ns(artic) / iters
        if mix == "alu":
            core_ns = CORE_ALU_CLK_PER_ITER * 20.0
            m_s = f"{per/6:.1f} ns/instr"
            unit = "instruction (6-op body)"
        else:
            core_ns = CORE_ROW_CLK * 20.0
            m_s = f"{per*9_900/1e6:.1f} ms/run"
            unit = "row body (9900/run)"
        print(f"      {mix:<14}{iters:>9}{artic:>8}{per:>10.1f}{m_s:>14}"
              f"{core_ns:>9.0f}{per/core_ns:>7.3f}  {unit}")
    if "alu" in cap.w1:
        iters, artic = cap.w1["alu"]
        per = ns(artic) / iters
        print(f"      ALU mix: {per/6:.1f} ns/instruction = {1e9/(per/6)/1e6:.1f} M instr/s "
              f"= ~{1e9/(per/6)/100e6:.2f} IPC if this machine is the 100 MHz DX4-100 "
              f"(the body is 4 adds + dec + jnz, so the rate is a simple-ALU rate)")
        print(f"      core: {CORE_ALU_CLK_PER_ITER/6:.1f} clk/instr = "
              f"{1e9/(CORE_ALU_CLK_PER_ITER*20/6)/1e6:.1f} M instr/s at 50 MHz "
              f"(simple ALU 1-2 clk) -> the machine's CPU is "
              f"{(CORE_ALU_CLK_PER_ITER*20/6)/(per/6):.2f}x the core per instruction")
    if "rowbody" in cap.w1 and "rowbody-gfx" in cap.w1:
        t = ns(cap.w1["rowbody"][1]) / cap.w1["rowbody"][0]
        g = ns(cap.w1["rowbody-gfx"][1]) / cap.w1["rowbody-gfx"][0]
        d = (g - t) / t * 100.0
        print(f"      text vs graphics mode (instruction fetch): {t:.1f} -> {g:.1f} ns/row "
              f"= {d:+.1f}%  (bracket bias ~5 us per window)")
    if "rowbody" in cap.w1:
        iters, artic = cap.w1["rowbody"]
        per = ns(artic) / iters
        ok = 2_000.0 <= per <= 20_000.0
        print(f"      VERDICT {verdict(ok)}: the measured row body is {per:.0f} ns/row; the "
              f"report derived ~7 400 ns/row (740 clk at 100 MHz) and the core's is "
              f"{CORE_ROW_CLK*20:.0f} ns/row")
        print(f"      -> the logo's 9900 row bodies cost {ms(ns(artic)/iters*9900/NS_PER_TICK):.1f} ms "
              f"on the machine vs {ms(CORE_ROW_CLK*20*9900/NS_PER_TICK):.1f} ms in the core's "
              f"instructions (the CPU term points the WRONG WAY for a core-faster defect)")

    # ---- W2..W4: the step replay ----------------------------------------
    print()
    print("  W2/W3/W4  HYPOTHESIS: the replica prices the machine's per-step work, and "
          "the display/interrupt state changes it")
    arms = {}
    for arm, steps in cap.steps.items():
        arms[arm] = arm_stats(steps)
        if not arms[arm]["idx_ok"]:
            print(f"      ** ARM={arm}: IDX is not 0..n-1 - a step row was lost")
            rc = 1
        if not arms[arm]["phase_sum_ok"]:
            print(f"      ** ARM={arm}: FILL+ROWS+FLIP != TOTAL on some step "
                  f"(a torn row) - this arm's numbers are withheld")
            rc = 1
    print(f"      {'ARM':<6}{'MODE':<15}{'n':>3}{'first ms':>10}{'steady ms':>11}"
          f"{'FILL us':>9}{'ROWS us':>9}{'FLIP us':>8}{'vs core':>9}")
    for arm in ARM_ORDER:
        if arm not in arms:
            print(f"      ** ARM={arm} missing from the capture")
            rc = 1
            continue
        a = arms[arm]
        if not a["phase_sum_ok"]:
            continue
        st_ns = ns(a["steady"])
        print(f"      {arm:<6}{a['mode']:<15}{a['n']:>3}{ms(a['first']):>10.3f}"
              f"{ms(a['steady']):>11.3f}{ns(a['fill'])/1000:>9.1f}"
              f"{ns(a['rows'])/1000:>9.1f}{ns(a['flip'])/1000:>8.1f}"
              f"{st_ns/CORE_STEP_NS:>9.3f}")
    # W2 verdict
    if "W2" in arms and arms["W2"]["phase_sum_ok"]:
        a = arms["W2"]
        st_ms = ms(a["steady"])
        core_ms = CORE_STEP_NS / 1e6
        ok = st_ms < 5.0
        print(f"      W2 machine step (display on): {st_ms:.3f} ms "
              f"[fill {ns(a['fill'])/1000:.1f} + rows {ns(a['rows'])/1000:.1f} + "
              f"flip {ns(a['flip'])/1000:.1f} us], first step {ms(a['first']):.3f} ms")
        print(f"         core twin (walk only): {CORE_STEP_NS/1000:.1f} us; "
              f"machine/core = {st_ms*1e6/CORE_STEP_NS:.2f}")
        n_steps = 99
        run_m = st_ms * n_steps
        print(f"      VERDICT {verdict(ok)}: ")
        if ok:
            print(f"         the step is {T_DRAW_MACHINE_MS_PER_STEP/st_ms:.1f}x SHORT of "
                  f"the {T_DRAW_MACHINE_MS_PER_STEP:.1f} ms/step the wall-clock "
                  f"decomposition implies, and the machine's step is "
                  f"{st_ms*1e6/CORE_STEP_NS:.2f}x the core's own walk - so the remaining "
                  f"T_draw is NOT in the step, and what IS in the step makes the core "
                  f"FASTER, not slower")
        else:
            print(f"         the step is at or above the "
                  f"{T_DRAW_MACHINE_MS_PER_STEP:.1f} ms/step the wall-clock decomposition "
                  f"implies: the step IS large enough to carry T_draw on this capture")
        print(f"      -> 99 steps = {run_m/1000:.3f} s on the machine vs "
              f"{core_ms*n_steps/1000:.3f} s of core walk; T_draw is ~2.04 s "
              f"(machine) / ~1.09 s (core), so the wipe carries "
              f"{run_m/2040*100:.1f}% of the machine's T_draw and "
              f"{core_ms*n_steps/1090*100:.1f}% of the core's")
    # W3 verdict
    if all(k in arms and arms[k]["phase_sum_ok"] for k in ("W2", "W3", "W3B")):
        on = (arms["W2"]["steady"] + arms["W3B"]["steady"]) / 2.0
        off = arms["W3"]["steady"]
        drift = arms["W3B"]["steady"] - arms["W2"]["steady"]
        diff = on - off
        # A contention cost is only real if it exceeds the run's own drift.
        ok = diff > abs(drift) and diff > 0.02 * on
        print(f"      W3 display contention: enabled {ms(on):.3f} ms vs blanked "
              f"{ms(off):.3f} ms -> {ns(diff)/1000:+.1f} us/step "
              f"({diff/on*100:+.1f}%), drift control {ns(drift)/1000:+.1f} us")
        print(f"      VERDICT {verdict(ok)}: "
              f"{'the display fetch costs real per-step time that the core does not model' if ok else 'no display-fetch cost distinguishable from drift (the blanking arm and the drift control agree)'}")
        print(f"      -> over 99 steps that is {ms(diff*99):+.1f} ms of the machine's "
              f"T_draw ({ms(abs(diff)*99)/2040*100:.2f}% of the 2.04 s); the core models no "
              f"display-fetch term at all, so this is a pure machine/core delta")
        for tag, row in (("blank  ", cap.disp_blank), ("unblank", cap.disp_unblank)):
            if row:
                print(f"      {tag} row: 0068 {row[0]} -> {row[1]} (read-back {row[2]})"
                      f"{'' if row[1] == row[2] else '  ** the write did not take'}")
    # W4 verdict
    if all(k in arms and arms[k]["phase_sum_ok"] for k in ("W4A", "W4B", "W4C")):
        a, b, c = (arms[k]["steady"] for k in ("W4A", "W4B", "W4C"))
        irqs = int(cap.irq_end[3]) if cap.irq_end else 0
        d = c - a
        spike = arms["W4C"]["max"] - arms["W4C"]["median"]
        jitter = arms["W4A"]["max"] - arms["W4A"]["min"]
        ok = None if irqs == 0 else (spike > jitter and spike >= 2)
        print(f"      W4 interrupts: IF=0 {ms(a):.3f} ms, IF=1 as-found IMR {ms(b):.3f} ms, "
              f"IRQ2 unmasked {ms(c):.3f} ms ({irqs} delivered IRQ2)")
        print(f"         amortized step delta (IRQ2 arm - IF=0 arm) = {ns(d)/1000:+.1f} us; "
              f"spike over the arm's own median = {ns(spike)/1000:+.1f} us against a "
              f"{ns(jitter)/1000:.1f} us spread in the IF=0 arm")
        print(f"      VERDICT {verdict(ok)}: "
              f"{'a VSYNC delivery inside a step costs measurable time' if ok else ('no delivery-resolution cost beyond the arms own jitter at this sample size (the count is the evidence; divide the spike by the count for the per-delivery bound)' if ok is False else 'no IRQ2 was delivered inside the arms, so this capture says nothing about the cost (re-run with the raster running)')}")
        if irqs > 0:
            print(f"      -> {irqs} delivery/deliveries in 10 steps (~10.5 ms of stepping at "
                  f"56.4 Hz): the per-delivery bound is {ns(spike)/1000/max(irqs,1):.1f} us of "
                  f"step time. The core's IRQ2 entry is ~4 clk_sys = 80 ns plus its handler, "
                  f"so only a per-delivery cost of order 100 us-1 ms could be this "
                  f"defect; a sub-10 us one cannot")
        if cap.irq_imr:
            print(f"         IMR window: as-found {cap.irq_imr[0]} -> window "
                  f"{cap.irq_imr[1]}, read-back {cap.irq_imr[2]}"
                  f"{'' if cap.irq_imr[1] == cap.irq_imr[2] else '  ** MISMATCH: the mask write did not take'}")

    # ---- W5: the raster --------------------------------------------------
    print()
    print("  W5  HYPOTHESIS: a y=525 raster would make the logo's 281 edges 5.94 s "
          "instead of 4.98 s - the whole 0.95 s defect")
    if cap.w5 is None:
        print("      ** no W5 row")
        rc = 1
    else:
        frames, lines, artic = cap.w5
        if frames <= 0 or artic <= 0:
            print("      ** degenerate W5 row (zero frames or zero ticks)")
            rc = 1
        else:
            per_frame = artic / frames
            lines_per_frame = lines / frames
            logo_s = per_frame * NS_PER_TICK * CORE_RUN_LOGO_EDGES / 1e9
            core_logo_s = CORE_FRAME_NS * CORE_RUN_LOGO_EDGES / 1e9
            print(f"      {frames} frames, {lines} 0xA0 bit-6 edges, {artic} ARTIC ticks")
            print(f"      frame period = {per_frame:.1f} ticks = {ns(per_frame)/1e6:.4f} ms "
                  f"= {1e9/(ns(per_frame)):.3f} Hz  (core: {CORE_FRAME_TICKS:.0f} ticks = "
                  f"{CORE_FRAME_NS/1e6:.4f} ms = 56.423 Hz)")
            print(f"      lines/frame from the bit-6 edges = {lines_per_frame:.1f} "
                  f"(core: {CORE_LINES})")
            print(f"      -> the logo's 281 edges = {logo_s:.3f} s on this machine vs "
                  f"{core_logo_s:.3f} s in the core = {logo_s-core_logo_s:+.3f} s")
            if lines_per_frame < 1.5:
                ok = None
                print("      VERDICT INDETERMINATE: the bit-6 edges counted one per FRAME, "
                      "not one per line, so this capture gives the period but no line "
                      "count (quote only the period)")
            elif lines_per_frame > 380:
                near440 = abs(lines_per_frame - 440) < 25
                near525 = abs(lines_per_frame - 525) < 25
                if near440:
                    print(f"      HYP y=525 REFUTED: the vertical total is "
                          f"{lines_per_frame:.0f} lines - the core's own 440-line raster, "
                          f"so the 0.96 s raster hypothesis is dead and the 281 edges are "
                          f"frame-locked the same on both machines")
                    print(f"      -> implied vertical total {lines_per_frame:.0f} lines; the "
                          f"0.95 s must come from the un-synchronised part of the logo")
                elif near525:
                    print(f"      HYP y=525 CONFIRMED: the vertical total is "
                          f"{lines_per_frame:.0f} lines, not 440 - the 281 edges are "
                          f"{logo_s:.2f} s here vs {core_logo_s:.2f} s in the core, which "
                          f"IS the whole defect")
                else:
                    print(f"      VERDICT INDETERMINATE: the vertical total is "
                          f"{lines_per_frame:.0f} lines - neither the 440 the core runs nor "
                          f"the 525 the hypothesis needs")
            else:
                print("      VERDICT INDETERMINATE: the bit-6 edge rate is neither "
                      "per-frame nor per-line; quote only the period")

    # ---- W6: the mode-set timeline --------------------------------------
    print()
    print("  W6  HYPOTHESIS: the mode set is the largest priced non-wipe term "
          "(report: ~50-75 ms on the machine)")
    if not cap.w6:
        print("      ** no W6 rows")
        rc = 1
    else:
        mode_total = 0
        for call, ticks in cap.w6:
            if not call.endswith("R"):
                mode_total += ticks
            print(f"      CALL={call:<4} {ticks:>7} ticks {ns(ticks)/1e6:>9.3f} ms")
        print(f"      mode set total (the four forward calls) = {mode_total} ticks = "
              f"{ns(mode_total)/1e6:.3f} ms")
        ok = 20e6 <= ns(mode_total) <= 150e6
        print(f"      VERDICT {verdict(ok)}: {ns(mode_total)/1e6:.1f} ms against the "
              f"report's 50-75 ms band; the core prices the same sequence at "
              f"~35-50 ms (0x5F write 600 ns vs 1621 ns)")

    # ---- the restore proof ----------------------------------------------
    print()
    print("  RESTORE LEDGER (the as-found -> read-back proof)")
    for p in sorted(cap.restore):
        was, now = cap.restore[p]
        flag = "" if was == now else "   ** NOT RESTORED"
        print(f"      {p}={was} -> {now}{flag}")
        if was != now:
            rc = 1
    if cap.restvec:
        a, b = cap.restvec
        print(f"      INT 0Ah {a} -> {b}"
              f"{'' if a == b else '   ** VECTOR NOT RESTORED'}")
        if a != b:
            rc = 1
    if not cap.restore:
        print("      ** no RESTORE row in the capture - the restore cannot be checked")
        rc = 1
    if cap.irq_end:
        was, now = cap.irq_end[0], cap.irq_end[1]
        print(f"      master IMR (W4C) 0002={was} -> {now}"
              f"{'' if was == now else '   ** NOT RESTORED'}")
        if was != now:
            rc = 1
    print()
    return rc


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("captures", nargs="+")
    args = ap.parse_args()
    rc = 0
    for path in args.captures:
        cap = Capture(path)
        try:
            cap.parse()
        except OSError as exc:
            print(f"=== {path} ===\n  ** cannot read: {exc}")
            rc = 1
            continue
        rc |= decode(cap)
    return rc


if __name__ == "__main__":
    sys.exit(main())

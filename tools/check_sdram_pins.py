#!/usr/bin/env python3
"""Check, in a fit's own report, that every SDRAM pin is driven by the register we intend.

Simulation cannot see this: the vendor I/O cells are behavioural models there, and the fitter
decides which atom actually drives a pin. A build whose SDRAM DQ output enable came from a
cyclonev_ddio_oe atom passed the battery, the boot golden and STA, and was black on hardware
(2026-10-22, dtm-obuf seed 10). The fitter's pin tables (z486_mister.fit.rpt, "Output Pins" and
"Bidir Pins") name each pin's output register and output-enable source, so this reads them:

  * every SDRAM command/address/BA/DQM output and every SDRAM_DQ pin has its Output Register in
    the I/O cell (`yes`);
  * every SDRAM_DQ pin's output enable comes from the intended register, in the intended place:
      - the cell build (sdram.v OUT_DDIO): the pin's own FABRIC register `g_out_ddio.dq_oe_q[n]`
        (n = the pin's bit), with NO I/O-cell OE register (`Output Enable Register` = no). Packed
        into the pins, even one per pin, it still crashed the fitter (DTM io_obuf, dob-lane2 seed
        11); driven by a cyclonev_ddio_oe atom (OE source `g_out_ddio.oen_pins[n]`) the build was
        black on hardware;
      - the packed build (sdram_out_ddio off): `dq_oen` / `dq_oen~_Duplicate_k`, packed (`yes`).
    Anything else - a DDIO_OE atom's net, another net, a register of the wrong bit - fails.

    tools/check_sdram_pins.py --reports DIR     (DIR holds z486_mister.fit.rpt; tools/build.py
                                                 runs this on every fit's output_files)
    tools/check_sdram_pins.py --selftest
Exit 0 pass, 1 fail.
"""
from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

CTRL = r"\|sdram:ctrl\|"
OUT_PINS = (["SDRAM_A[%d]" % i for i in range(13)] + ["SDRAM_BA[0]", "SDRAM_BA[1]", "SDRAM_DQML",
            "SDRAM_DQMH", "SDRAM_nCS", "SDRAM_nRAS", "SDRAM_nCAS", "SDRAM_nWE"])
DQ_PINS = ["SDRAM_DQ[%d]" % i for i in range(16)]


def oe_problem(pin_bit: int, source: str, oe_register: str | None) -> str | None:
    """None if the pin's OE source and its OE-register placement are the intended pair."""
    # The fitter's pin table names a source it inverts on the way to the OE as `<node> (inverted)`
    # (the fabric dq_oe_q holds 1 = Hi-Z, so its OE is its inverse; a packed register can instead
    # absorb the inversion, which is how the base build's dq_oen reads).
    source = re.sub(r" \(inverted\)$", "", source)
    if re.search(CTRL + r"g_out_ddio\.dq_oe_q\[%d\](~DUPLICATE)?$" % pin_bit, source):
        return None if oe_register == "no" else (
            f"output enable dq_oe_q[{pin_bit}] is in the I/O cell (Output Enable Register = "
            f"{oe_register!r}): the cell build keeps it in the fabric (a packed OE crashed the fitter)")
    if re.search(CTRL + r"dq_oen(~_Duplicate_\d+)?$", source):
        return None if oe_register == "yes" else (
            f"packed build's dq_oen is not in the I/O cell (Output Enable Register = {oe_register!r})")
    return (f"output enable driven by {source!r}, not its own dq_oe_q[{pin_bit}] (cell build) "
            "or dq_oen (packed build)")


def table(text: str, title: str) -> dict[str, dict[str, str]]:
    """One of the fit report's pin tables, {pin name: {column: value}}."""
    m = re.search(r"^; " + re.escape(title) + r"\s*;\s*$", text, re.M)
    if not m:
        return {}
    rows: dict[str, dict[str, str]] = {}
    header = None
    for line in text[m.end():].splitlines():
        if not line.strip():
            if header is not None and rows:
                break
            continue
        if not line.startswith(";"):
            continue
        cells = [c.strip() for c in line.strip().strip(";").split(";")]
        if header is None:
            header = cells
            continue
        row = dict(zip(header, cells))
        # The table's trailing columns do not line up with its header in this Quartus (a row
        # carries a load value the header does not name), so the output-enable source is read as
        # what it is: the row's hierarchical node name, its last cell that holds a '|'.
        row["Output Enable Source"] = next((c for c in reversed(cells) if "|" in c), "")
        rows[cells[0]] = row
    return rows


def check(text: str) -> list[str]:
    problems = []
    outs, bidir = table(text, "Output Pins"), table(text, "Bidir Pins")
    if not outs or not bidir:
        return ["the fit report has no Output Pins / Bidir Pins table"]
    for pin in OUT_PINS:
        row = outs.get(pin)
        if row is None:
            problems.append(f"{pin}: not in the Output Pins table")
        elif row.get("Output Register") != "yes":
            problems.append(f"{pin}: its output register is not in the I/O cell "
                            f"(Output Register = {row.get('Output Register')!r})")
    for bit, pin in enumerate(DQ_PINS):
        row = bidir.get(pin)
        if row is None:
            problems.append(f"{pin}: not in the Bidir Pins table")
            continue
        if row.get("Output Register") != "yes":
            problems.append(f"{pin}: Output Register = {row.get('Output Register')!r}, not yes")
        msg = oe_problem(bit, row.get("Output Enable Source", ""), row.get("Output Enable Register"))
        if msg:
            problems.append(f"{pin}: {msg}")
    return problems


def selftest() -> int:
    cols = ["Name", "Output Register", "Output Enable Register", "Output Enable Source"]
    pre = "emu:emu|split_sdram_backend:de10_guest_memory|sdram_sync_bridge:memory|sdram:ctrl|"

    def report(oe_src, out_reg="yes", drop=None, oe_reg="no"):
        lines = ["; Output Pins ;", "; " + " ; ".join(cols[:2]) + " ;"]
        lines += [f"; {p} ; {out_reg} ;" for p in OUT_PINS if p != drop]
        lines += ["", "; Bidir Pins ;", "; " + " ; ".join(cols) + " ;"]
        lines += [f"; {p} ; yes ; {oe_reg} ; {oe_src(i)} ;" for i, p in enumerate(DQ_PINS)]
        return "\n".join(lines) + "\n\n"

    cases = [
        ("cell build, per-pin fabric OE registers", report(lambda i: f"{pre}g_out_ddio.dq_oe_q[{i}]"), True),
        ("cell build, fabric OE registers reported inverted",
         report(lambda i: f"{pre}g_out_ddio.dq_oe_q[{i}] (inverted)"), True),
        ("cell build, per-pin OE registers packed (the seed-11 crash form)",
         report(lambda i: f"{pre}g_out_ddio.dq_oe_q[{i}]", oe_reg="yes"), False),
        ("packed build, dq_oen and its duplicates",
         report(lambda i: pre + ("dq_oen" if i == 0 else f"dq_oen~_Duplicate_{i}"), oe_reg="yes"), True),
        ("packed build with dq_oen left in the fabric",
         report(lambda i: pre + "dq_oen", oe_reg="no"), False),
        ("OE from a DDIO_OE atom's net (the black build)",
         report(lambda i: f"{pre}g_out_ddio.oen_pins[{i}]", oe_reg="yes"), False),
        ("OE register of the wrong bit", report(lambda i: f"{pre}g_out_ddio.dq_oe_q[{15 - i}]"), False),
        ("an address output register left in the fabric",
         report(lambda i: f"{pre}g_out_ddio.dq_oe_q[{i}]", out_reg="no"), False),
        ("a pin missing", report(lambda i: f"{pre}g_out_ddio.dq_oe_q[{i}]", drop="SDRAM_nWE"), False),
    ]
    fails = 0
    for name, text, want in cases:
        got = not check(text)
        ok = got == want
        fails += not ok
        print(f"selftest: {'ok  ' if ok else 'FAIL'} {name}: {'pass' if got else 'fail'}")
    print(f"check_sdram_pins.py --selftest: {'PASS' if not fails else 'FAIL'} ({len(cases)} cases)")
    return 1 if fails else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reports", type=Path, help="a fit's output_files directory")
    ap.add_argument("--project", default="z486_mister")
    ap.add_argument("--selftest", action="store_true")
    ns = ap.parse_args()
    if ns.selftest:
        return selftest()
    if ns.reports is None:
        ap.error("--reports DIR is required")
    rpt = ns.reports / f"{ns.project}.fit.rpt"
    if not rpt.is_file():
        print(f"SDRAM PIN CHECK: FAIL - {rpt} not found")
        return 1
    problems = check(rpt.read_text(errors="replace"))
    for p in problems:
        print(f"  {p}")
    print(f"SDRAM PIN CHECK: {'FAIL' if problems else 'PASS'} - "
          f"{len(OUT_PINS)} outputs and {len(DQ_PINS)} DQ pins in {rpt}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Hold the debug-UART record table to every place that writes it down.

The framework's records are `0xA5, type, ...` and their lengths are a function of the type. That
function is written in THREE places that must agree, and a disagreement is silent in a bench and
in lint (a mux whose table is one byte short splits a record on hardware and nothing else notices):

  1. src/pc9821/core/pc9821_dbg_mux.sv   dbg_rec_len  - where records are kept whole
  2. tools/decode_dbglog.py              LEN          - where they are read
  3. the instruments' own emitters       what they actually send

and the CD log's lengths are a fourth: tools/decode_cdlog.py (the CD log's own decoder, header
+ payload) must give the same totals as the table's 0x01-0x0B rows.

This checks 1 against 2, 2 against the CD log's decoder, and that every record type the emitters
in pc9821_dbg_cpu.sv / pc9821_gdc_log.sv / pc9821_fdc_log.sv name is in the table with the length their record builders
declare. The benches (tb_pc9821_dbg_mux, tb_pc9821_dbg_cpu) carry their OWN tables, written from the
record definitions, so a change must be made in all of them or a bench fails.

Usage:  tools/check_dbglog_contract.py            (--selftest plants a wrong table and a missing type)
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
MUX = ROOT / "src/pc9821/core/pc9821_dbg_mux.sv"
CPU = ROOT / "src/pc9821/core/pc9821_dbg_cpu.sv"
GDC = ROOT / "src/pc9821/video/pc9821_gdc_log.sv"
FDC = ROOT / "src/pc9821/storage/pc9821_fdc_log.sv"
CDDEC = ROOT / "tools/decode_cdlog.py"


def mux_table(text: str) -> dict[int, int]:
    """dbg_rec_len's case arms -> {type: length}."""
    m = re.search(r"function automatic \[5:0\] dbg_rec_len.*?endfunction", text, re.S)
    if not m:
        raise SystemExit("pc9821_dbg_mux.sv has no dbg_rec_len function")
    table = {}
    for arm in re.finditer(r"((?:8'h[0-9A-Fa-f]{2}\s*,?\s*)+):\s*dbg_rec_len\s*=\s*6'd(\d+);", m.group(0)):
        for t in re.findall(r"8'h([0-9A-Fa-f]{2})", arm.group(1)):
            table[int(t, 16)] = int(arm.group(2))
    return table


def table_problems(mux_text: str | None = None) -> list[str]:
    import decode_dbglog as d
    problems = []
    mux = mux_table(mux_text if mux_text is not None else MUX.read_text())
    for t in sorted(set(mux) | set(d.LEN)):
        if mux.get(t) != d.LEN.get(t):
            problems.append(f"type 0x{t:02X}: the mux says {mux.get(t)}, decode_dbglog.py says {d.LEN.get(t)}")
    if CDDEC.exists():
        txt = CDDEC.read_text()
        m = re.search(r"^LEN = (\{.*?\})", txt, re.M)
        if m:
            cd = eval(m.group(1), {})
            for t, payload in cd.items():
                if d.LEN.get(t) != 4 + payload:
                    problems.append(f"CD type {t}: decode_cdlog.py gives {4 + payload} bytes, the table {d.LEN.get(t)}")
    return problems


def emitter_problems(cpu_text: str | None = None, gdc_text: str | None = None,
                     fdc_text: str | None = None) -> list[str]:
    import decode_dbglog as d
    cpu = cpu_text if cpu_text is not None else CPU.read_text()
    gdc = gdc_text if gdc_text is not None else GDC.read_text()
    problems = []
    seen = set()
    for m in re.finditer(r"8'hA5,\s*(?:e_cur\[100\]\s*\?\s*)?8'h([0-9A-Fa-f]{2})(?:\s*:\s*8'h([0-9A-Fa-f]{2}))?", cpu):
        seen |= {int(g, 16) for g in m.groups() if g}
    for m in re.finditer(r"8'hA5,\s*8'h(2[01])", cpu):
        seen.add(int(m.group(1), 16))
    seen |= {0x21} if "8'h21" in cpu else set()
    for t in sorted(seen):
        if t not in d.LEN:
            problems.append(f"pc9821_dbg_cpu.sv emits type 0x{t:02X}, which is not in the table")
    for t in (0x20, 0x21, 0x30, 0x31, 0x32, 0x43, 0x44):
        if t not in seen:
            problems.append(f"pc9821_dbg_cpu.sv no longer names type 0x{t:02X}, which the table and decoder carry")
    # the CPU serialiser's own length constants (k_len) against the table
    m = re.search(r"wire \[5:0\]\s+k_len = (.*?);", cpu, re.S)
    if m:
        lens = re.findall(r"\(kind == K_(\w+)\)\s*\?\s*6'd(\d+)", m.group(1))
        tail = re.search(r":\s*6'd(\d+)\s*$", m.group(1).strip())
        want = {"SMP": 0x20, "EVT": 0x30, "LST": 0x32, "TRC": 0x43}
        for name, n in lens:
            if name in want and d.LEN[want[name]] != int(n):
                problems.append(f"pc9821_dbg_cpu.sv k_len for K_{name} is {n}, the table says {d.LEN[want[name]]}")
        if tail and d.LEN[0x44] != int(tail.group(1)):
            problems.append(f"pc9821_dbg_cpu.sv k_len for the trigger record is {tail.group(1)}, the table says {d.LEN[0x44]}")
    else:
        problems.append("pc9821_dbg_cpu.sv has no k_len expression to check")
    gtypes = {int(x, 16) for x in re.findall(r"r_type\s*<=\s*8'h([0-9A-Fa-f]{2})", gdc)}
    if "{4'h1, pn}" in gdc:
        gtypes |= set(range(0x10, 0x19))
    for t in sorted(gtypes):
        if t not in d.LEN:
            problems.append(f"pc9821_gdc_log.sv emits type 0x{t:02X}, which is not in the table")
    for t in (0x19, 0x1E, 0x1F):
        if t not in gtypes:
            problems.append(f"pc9821_gdc_log.sv no longer names type 0x{t:02X}")
    if "r_long ? 4'd8 : 4'd6" not in gdc:
        problems.append("pc9821_gdc_log.sv's record lengths (r_last = r_long ? 8 : 6) changed: re-check the table's 0x10-0x19 rows")
    # the floppy log: every type it builds (the access event's e_type and the stage's r_type) is a
    # seven-byte record, its serialiser ends at r_i == 6
    fdc = fdc_text if fdc_text is not None else FDC.read_text()
    ftypes = {int(x, 16) for x in re.findall(r"(?:r_type|e_type)\s*<?=\s*8'h([0-9A-Fa-f]{2})", fdc)}
    ftypes |= {int(x, 16) for x in re.findall(r"e_type\s*=\s*io_wr\s*\?\s*8'h([0-9A-Fa-f]{2})\s*:\s*8'h([0-9A-Fa-f]{2})", fdc)[0]} \
        if re.search(r"e_type\s*=\s*io_wr\s*\?", fdc) else set()
    ftypes.discard(0x00)
    for t in sorted(ftypes):
        if d.LEN.get(t) != 7:
            problems.append(f"pc9821_fdc_log.sv emits type 0x{t:02X}, which the table gives {d.LEN.get(t)} bytes, not 7")
    for t in (0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x5E, 0x5F):
        if t not in ftypes:
            problems.append(f"pc9821_fdc_log.sv no longer names type 0x{t:02X}")
    if "if (r_i == 3'd6) busy <= 1'b0;" not in fdc:
        problems.append("pc9821_fdc_log.sv's record length (r_i == 6, seven bytes) changed: re-check the table's 0x50-0x5F rows")
    return problems


def selftest() -> int:
    bad = 0
    mux = MUX.read_text()
    broken = mux.replace("8'h20, 8'h21: dbg_rec_len = 6'd34;", "8'h20, 8'h21: dbg_rec_len = 6'd33;")
    if not any("0x20" in p for p in table_problems(broken)):
        print("SELFTEST FAIL: a mux table one byte short for the sample was not caught")
        bad += 1
    dropped = mux.replace("8'h44: dbg_rec_len = 6'd13;", "")
    if not any("0x44" in p for p in table_problems(dropped)):
        print("SELFTEST FAIL: a mux table missing the trigger record was not caught")
        bad += 1
    cpu = CPU.read_text()
    if not any("k_len" in p for p in emitter_problems(cpu.replace("(kind == K_EVT) ? 6'd15", "(kind == K_EVT) ? 6'd14"))):
        print("SELFTEST FAIL: a CPU serialiser length that disagrees with the table was not caught")
        bad += 1
    gdc = GDC.read_text()
    if not any("0x1E" in p for p in emitter_problems(None, gdc.replace("8'h1E", "8'h09"))):
        print("SELFTEST FAIL: the display log reverting LOST to the CD log's type was not caught")
        bad += 1
    fdc = FDC.read_text()
    if not any("0x5E" in p for p in emitter_problems(None, None, fdc.replace("8'h5E", "8'h1E"))):
        print("SELFTEST FAIL: the floppy log emitting another instrument's LOST type was not caught")
        bad += 1
    if table_problems() or emitter_problems():
        print("SELFTEST FAIL: the real tree is not clean")
        bad += 1
    print("check_dbglog_contract.py --selftest:", "FAIL" if bad else "PASS")
    return 1 if bad else 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    problems = table_problems() + emitter_problems()
    for p in problems:
        print("FAIL:", p)
    if problems:
        return 1
    print("DEBUG-UART RECORD CONTRACT: PASS (mux table = decoder table = the emitters' record builders)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

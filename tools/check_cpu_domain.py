#!/usr/bin/env python3
"""The gated CPU clock domain: every pulse input held, every hold back-pressured.

WHY THIS EXISTS. z486 runs on a GATED clock (`pc9821_cpu_clk`, enabled by `cpu_ce`), so a
one-cycle pulse raised by the clk_sys platform has no ending CPU edge when it lands in a
disabled cycle. `pc9821_cpu_bus_bridge` is the ONLY legal crossing for such a pulse: it
holds the pulse (and its payload) until the CPU's next enabled edge. The T24 audit found
two defects of exactly this class - a snoop pulse wired straight into the gated domain
(F1), and a one-entry hold with no back-pressure, so a second accepted DMA write could
replace the waiting address (G1). BOTH were invisible to every bench: Verilator is 2-state
and the unit benches run the CPU at Full speed (cpu_ce constant 1), where the bridge is a
wire. Only the integrated throttle tiers can see the class, and they only see the cases
they happen to drive.

This check holds the WIRING together statically, which is the class no bench sees:

  1. Every one-cycle PULSE input of the z486 instance is driven by the bridge's matching
     output, or by a constant on the documented tied-off list. A pulse wired straight to a
     clk_sys producer fails, even if today's benches never raise it in a disabled cycle.

  2. Every hold the bridge can OVERRUN is back-pressured. `p_snoop_busy` is a one-deep
     hold; if the platform presents/accepted the next write while it is high, the waiting
     address is replaced and an invalidate is lost silently. So the wire it drives must be
     consumed by the DMA presentation (`pc9821_memory_subsystem`'s `.dma_valid`, i.e.
     mem_valid's DMA arm) AND by the accept the DMAC sees (the iobus's `.dma_mem_ready`,
     i.e. dma_ready). Gating the accept alone is not enough - the subsystem's owner lock
     releases on mem_ready and re-presents the same byte - so both are required.

  3. The CPU-clock-domain INSTANCE SET is exactly {z486, pc9821_cpu_bus_bridge} plus the
     gate itself (pc9821_cpu_clk): a new module clocked by cpu_clk or consuming cpu_ce is
     a second unbridged consumer, which is how F1 happened in the first place.

WHAT THIS CANNOT SEE, stated so nobody over-reads it: a pulse that is correctly bridged but
whose producer does not hold its payload, a hold that is deep enough for one producer and
not another, and any behaviour at all. It is a wiring contract, not a proof; the integrated
throttle tiers (`tb_pc9821_throttle`, `tb_pc9821_dma_snoop_throttle`) are the behavioural
half.

Usage:
  tools/check_cpu_domain.py                check the tree; exit 1 on any violation
  tools/check_cpu_domain.py --root DIR     check another tree (the selftest's copies)
  tools/check_cpu_domain.py --selftest     plant each defect in a temp tree and require the
                                           check to reject it (a guard that cannot fail is
                                           the defect this file exists to find)
"""
from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

SYSTEM_SV = pathlib.Path("src/pc9821/core/pc9821_system.sv")
BRIDGE_SV = pathlib.Path("src/pc9821/core/pc9821_cpu_bus_bridge.sv")

# The z486 inputs that are ONE-CYCLE pulses (or one-cycle accepts) and therefore must cross
# the gated-clock boundary through the bridge. `intr` is deliberately absent: it is a LEVEL
# held until the CPU's INTA sequence, and `a20_enable`/`single_step` are levels too. Each
# entry is (z486 port, the bridge output that must drive it, or None for a tied-off port).
PULSE_INPUTS = {
    "ready":             "c_ready",
    "resp_valid":        "c_resp_valid",
    "line_resp_valid":   None,     # tied off: beats are the response form (pc9821_cpu_clk.sv)
    "snoop_valid":       "c_snoop_valid",
    "cache_flush":       "c_flush_req",
    "nmi":               None,     # tied off: no NMI source; WOULD need a hold if connected
}

# The tied-off pulse inputs, and the constant each must be. A non-zero or non-literal
# expression on one of these is a crossing without a hold.
TIED_OFF = {"line_resp_valid": "1'b0", "nmi": "1'b0"}

# A pulse-hold the bridge can OVERRUN, and the two terms the platform must gate with it.
# (busy output, the instance/port whose expression must depend on it) - see check 2.
OVERRUN_HOLDS = {
    "p_snoop_busy": ("pc9821_memory_subsystem", "dma_valid"),
}

# The accept side the DMAC sees for the same byte (the second term G1 requires).
DMA_ACCEPT = ("pc9821_iobus", "dma_mem_ready", "pc9821_memory_subsystem", "dma_ready")

# The only instances allowed in the gated CPU clock domain. cpu_throttle is the RATE
# GENERATOR (it produces cpu_ce); pc9821_cpu_clk is the clock gate; the other two are the
# CPU and its one legal crossing.
CPU_DOMAIN = {"z486", "pc9821_cpu_bus_bridge", "pc9821_cpu_clk", "cpu_throttle"}

KEYWORDS = {
    "module", "endmodule", "function", "endfunction", "task", "endtask", "always",
    "always_ff", "always_comb", "always_latch", "initial", "assign", "if", "else",
    "for", "while", "repeat", "case", "endcase", "begin", "end", "wire", "reg",
    "input", "output", "inout", "parameter", "localparam", "generate", "endgenerate",
    "genvar", "integer", "typedef", "struct", "union", "package", "import",
}


def strip_comments(s: str) -> str:
    s = re.sub(r"/\*.*?\*/", " ", s, flags=re.S)
    s = s.replace("\r", "")
    return re.sub(r"//[^\n]*", "", s)


def skip_ws(s: str, i: int) -> int:
    while i < len(s) and s[i].isspace():
        i += 1
    return i


def match_paren(s: str, i: int) -> int:
    """Index of the ')' matching the '(' at i, or -1."""
    depth = 0
    while i < len(s):
        c = s[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def split_top(s: str) -> list[str]:
    out, depth, cur = [], 0, []
    for c in s:
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if c == "," and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    out.append("".join(cur))
    return out


def instances(text: str):
    """(module, instance, port-map dict) for every instantiation in stripped source.

    A deliberately small scanner rather than a Verilog parser: an instantiation is a line
    starting with a module name at column 0, an optional ``#(...)`` parameter list, an
    instance name, and a parenthesised port list."""
    out = []
    pos = 0
    head = re.compile(r"(?m)^([A-Za-z_]\w*)\b[ \t]*(#)?")
    while True:
        m = head.search(text, pos)
        if not m:
            break
        mod = m.group(1)
        pos = m.end()
        if mod in KEYWORDS:
            continue
        j = skip_ws(text, pos)
        if m.group(2) and j < len(text) and text[j] == "(":
            k = match_paren(text, j)
            if k < 0:
                continue
            j = skip_ws(text, k + 1)
        m2 = re.compile(r"([A-Za-z_]\w*)\s*\(").match(text, j)
        if not m2:
            continue
        inst = m2.group(1)
        pstart = m2.end() - 1
        pend = match_paren(text, pstart)
        if pend < 0:
            continue
        ports = {}
        for item in split_top(text[pstart + 1:pend]):
            pm = re.match(r"\s*\.\s*([A-Za-z_]\w*)\s*(?:\((.*)\))?\s*$", item, re.S)
            if pm:
                ports[pm.group(1)] = (pm.group(2) or "").strip()
        out.append((mod, inst, ports))
        pos = pend + 1
    return out


def find_inst(insts, mod, path=None):
    for (m, i, p) in insts:
        if m == mod and (path is None or i == path):
            return i, p
    return None, None


def wire_rhs(text: str, name: str):
    """The right-hand side of a continuous assignment / net initializer for `name`."""
    m = re.search(rf"(?m)^\s*(?:wire|assign)\b[^;=\n]*\b{re.escape(name)}\b\s*=\s*([^;]+);",
                  text)
    if m:
        return m.group(1)
    return None


def depends_on(text: str, expr: str, target: str, depth: int = 6, seen=None) -> bool:
    """`target` appears in expr, directly or through up to `depth` wire definitions."""
    seen = seen or set()
    ids = set(re.findall(r"[A-Za-z_]\w*", expr))
    if target in ids:
        return True
    if depth == 0:
        return False
    for name in ids:
        if name in seen:
            continue
        rhs = wire_rhs(text, name)
        if rhs and depends_on(text, rhs, target, depth - 1, seen | {name}):
            return True
    return False


def bridge_outputs(text: str):
    return set(re.findall(r"\boutput\s+(?:wire|logic|reg)\b[^;]*?\b([A-Za-z_]\w*)\s*[,;\n]",
                          text))


def check(root: pathlib.Path) -> list[str]:
    problems: list[str] = []
    sys_path = root / SYSTEM_SV
    br_path = root / BRIDGE_SV
    for p in (sys_path, br_path):
        if not p.exists():
            return [f"cannot read {p}"]
    text = strip_comments(sys_path.read_text())
    br_text = strip_comments(br_path.read_text())
    insts = instances(text)
    if not insts:
        return ["no instantiations parsed from pc9821_system.sv - the scanner is broken, "
                "so this check must not pass"]

    # ---- 1. the z486 pulse inputs ----
    zi, zports = find_inst(insts, "z486")
    if zports is None:
        problems.append("no z486 instantiation found - cannot check the CPU-domain crossings")
        zports = {}
    bi, bports = find_inst(insts, "pc9821_cpu_bus_bridge")
    if bports is None:
        problems.append("no pc9821_cpu_bus_bridge instantiation found")
        bports = {}
    bridge_out = bridge_outputs(br_text)
    if not bridge_out:
        problems.append(f"no output ports parsed from {BRIDGE_SV}")

    for port, out_port in sorted(PULSE_INPUTS.items()):
        if port not in zports:
            problems.append(f"z486 .{port} is not connected - cannot prove it is held "
                            f"(a pulse input must be bridge-driven or a documented constant)")
            continue
        expr = zports[port]
        if out_port is None:
            want = TIED_OFF.get(port)
            if expr.replace(" ", "") != want:
                problems.append(
                    f"z486 .{port}({expr}) is a pulse input with no hold: it must stay the "
                    f"tied-off constant {want} until the bridge holds it (pc9821_cpu_clk.sv)")
            continue
        if out_port not in bridge_out:
            problems.append(
                f"pc9821_cpu_bus_bridge has no output {out_port} (z486 .{port} needs it)")
            continue
        driven = bports.get(out_port)
        if driven is None:
            problems.append(f"the bridge does not connect its output {out_port}")
            continue
        if expr != driven:
            problems.append(
                f"z486 .{port}({expr}) is NOT the bridge's {out_port} ({driven}): a one-cycle "
                f"pulse wired straight into the gated CPU domain is lost whenever cpu_ce=0")

    # ---- 2. every overrun-capable hold is back-pressured ----
    for busy_port, (mod, port) in sorted(OVERRUN_HOLDS.items()):
        if busy_port not in bports:
            problems.append(
                f"the bridge's {busy_port} is not connected: a one-deep hold with no "
                f"back-pressure lets a second accepted write replace the waiting address")
            continue
        busy_wire = bports[busy_port]
        if not re.fullmatch(r"[A-Za-z_]\w*", busy_wire):
            problems.append(f"the bridge's {busy_port} drives '{busy_wire}', not a wire")
            continue
        mi, mports = find_inst(insts, mod)
        if mports is None:
            problems.append(f"no {mod} instantiation - cannot check {busy_port}'s consumer")
            continue
        pres = mports.get(port)
        if pres is None:
            problems.append(f"{mod} .{port} is not connected")
            continue
        rhs = wire_rhs(text, pres)
        if rhs is None or not depends_on(text, pres, busy_wire):
            shown = pres if rhs is None else f"{pres} = {rhs.strip()}"
            problems.append(
                f"the DMA presentation {shown} does not depend on {busy_wire}: the "
                f"{busy_port} hold can be overrun")
        # the accept side: the DMAC must not see a ready while the hold is occupied
        (amod, aport, mmod, mport) = DMA_ACCEPT
        ai, aports = find_inst(insts, amod)
        m2i, m2ports = find_inst(insts, mmod)
        if aports is None or m2ports is None:
            problems.append(f"cannot find {amod}/{mmod} to check the DMA accept gate")
            continue
        acc_expr = aports.get(aport)
        raw_expr = m2ports.get(mport)
        if acc_expr is None or raw_expr is None:
            problems.append(f"{amod} .{aport} or {mmod} .{mport} is not connected")
            continue
        if acc_expr == raw_expr:
            problems.append(
                f"the DMAC's {aport}({acc_expr}) is the ungated accept: gating the "
                f"presentation alone re-writes the byte (the owner lock releases on "
                f"mem_ready), gating the accept alone is the {busy_port} overrun")
            continue
        arhs = wire_rhs(text, acc_expr)
        if arhs is None or not depends_on(text, acc_expr, busy_wire):
            shown = acc_expr if arhs is None else f"{acc_expr} = {arhs.strip()}"
            problems.append(
                f"the DMAC accept {shown} does not depend on {busy_wire}: a write can "
                f"still be accepted while the hold is occupied")

    # ---- 3. the CPU-clock-domain instance set ----
    dom = set()
    for (mod, inst, ports) in insts:
        if ports.get("clk", None) == "cpu_clk" or ports.get("cpu_ce", None) == "cpu_ce":
            dom.add(mod)
        elif ports.get("ena", None) == "cpu_ce":
            dom.add(mod)          # the gate itself (pc9821_cpu_clk)
    unknown = dom - CPU_DOMAIN
    for mod in sorted(unknown):
        problems.append(
            f"{mod} runs in the gated CPU clock domain but is not on the list: only "
            f"z486 (the CPU) and pc9821_cpu_bus_bridge (its crossing) may see cpu_clk/"
            f"cpu_ce - a second consumer needs its own hold, not a direct connection")
    for mod in sorted(CPU_DOMAIN - dom):
        problems.append(f"{mod} is no longer in the CPU clock domain - the list is stale")

    return problems


def selftest() -> int:
    """Plant each defect class in a copy of the tree and require a rejection."""
    src_sys = ROOT / SYSTEM_SV
    src_br = ROOT / BRIDGE_SV
    # Plant into the RAW text (comments and all), so the copy stays a valid source file.
    raw_sys = src_sys.read_text()
    raw_br = src_br.read_text()
    failures = []

    def run_case(name, sys_text, expect_fail, why_hint):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            (root / SYSTEM_SV).parent.mkdir(parents=True, exist_ok=True)
            (root / BRIDGE_SV).parent.mkdir(parents=True, exist_ok=True)
            (root / SYSTEM_SV).write_text(sys_text)
            (root / BRIDGE_SV).write_text(raw_br)
            probs = check(root)
            if expect_fail and not probs:
                failures.append(f"{name}: accepted, but {why_hint}")
            elif not expect_fail and probs:
                failures.append(f"{name}: rejected a correct tree: {probs[0]}")
            elif expect_fail and not any(why_hint in p for p in probs):
                # the planted defect must be named, not merely caught by accident
                failures.append(f"{name}: rejected, but not for {why_hint!r}: {probs[0]}")

    # control
    run_case("control", raw_sys, False, None)
    # 1. a pulse wired straight into the gated domain
    run_case("direct-snoop",
             raw_sys.replace(".snoop_addr(zc_snoop_addr), .snoop_valid(zc_snoop_valid),",
                             ".snoop_addr(zc_snoop_addr), .snoop_valid(dma_snoop_valid),"),
             True, "NOT the bridge's c_snoop_valid")
    # 2. the presentation ungated (the hold can be overrun)
    run_case("no-backpressure",
             raw_sys.replace(".dma_valid(dma_mem_req_pres),", ".dma_valid(dma_mem_req),"),
             True, "does not depend on dma_snoop_busy")
    # 2b. the accept ungated
    run_case("accept-ungated",
             raw_sys.replace(".dma_mem_ready(dma_mem_ack),", ".dma_mem_ready(dma_mem_ready),"),
             True, "is the ungated accept")
    # 3. a second CPU-domain consumer
    run_case("extra-domain-instance",
             raw_sys.replace("pc9821_kbd #(.SYS_CLOCK_HZ(SYS_FREQ)) keyboard (",
                             "pc9821_watchdog rogue (.clk(cpu_clk), .reset(reset));\n"
                             "pc9821_kbd #(.SYS_CLOCK_HZ(SYS_FREQ)) keyboard ("),
             True, "runs in the gated CPU clock domain")
    # 4. a tied-off pulse suddenly driven
    run_case("nmi-driven",
             raw_sys.replace(".intr(z_intr), .nmi(1'b0), .inta(zc_inta),",
                             ".intr(z_intr), .nmi(nmi_pulse), .inta(zc_inta),"),
             True, "no hold")

    if failures:
        print("CPU-DOMAIN CHECK SELFTEST: FAIL", file=sys.stderr)
        for f in failures:
            print(f"  FAIL {f}", file=sys.stderr)
        return 1
    print("CPU-DOMAIN CHECK SELFTEST: PASS (5 planted defects rejected, control accepted)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", default=str(ROOT))
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    root = pathlib.Path(args.root).resolve()
    problems = check(root)
    if problems:
        print("CPU-DOMAIN CROSSINGS: FAIL", file=sys.stderr)
        for p in problems:
            print(f"  FAIL {p}", file=sys.stderr)
        return 1
    print("CPU-DOMAIN CROSSINGS: PASS (6 z486 pulse inputs held or documented, "
          "the snoop hold back-pressured on both the presentation and the accept, "
          f"{len(CPU_DOMAIN)} CPU-domain instances)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

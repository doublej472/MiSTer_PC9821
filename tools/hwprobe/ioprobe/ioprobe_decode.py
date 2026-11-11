#!/usr/bin/env python3
"""ioprobe_decode.py - parse an IOPROBE capture into a per-port clk_sys table.

Usage:
    python3 tools/hwprobe/ioprobe/ioprobe_decode.py IO.TXT [IO2.TXT ...]

IOPROBE (tools/hwprobe/ioprobe/ioprobe.s) is the real-machine PC-9821 I/O wait-state
probe for every port class. It prints, for each measured access, one line inside
a BEGIN:IO<port><mode>/END:IO<port><mode> section:

    WAIT5F  port=005F mode=W pit=03F2 base=00C3 artic=0001A2B3 bartic=00004567

pit/base are the PIT mode-3 oscillator counts for the access and its interleaved
control (a register move); artic/bartic are the ARTIC-counter deltas for the same
two windows. This script converts a port's excess over its control, as a fraction
of the 0x005F write row's excess, into clk_sys and ns:

    clk_sys = 30 * (pit - base) / (WAIT5F pit - base)
    ns      = 600 * (pit - base) / (WAIT5F pit - base)

because 0x005F is the machine's documented 600 ns = 30 clk_sys I/O-wait port. No
absolute time base is assumed: the run's own scale cancels. The ARTIC columns give
a second, independent ratio (clk_a) from the same windows; a row where clk_sys and
clk_a disagree is flagged, which is how a wrapped/tearing PIT window shows up.

The clk_sys column for a port is the number pc9821_iobus.sv io_access_cycles()
should return for that port's class. The RTL column prints the arm the class table
carries today, so the diff is one line per port.

THE 0x5F ANCHOR'S xBASE CURRENCY: the ratio "quote only xBASE" refers to is the clk_sys
column (the class's excess over its own paired control as a ratio to the WAIT5F
anchor).  REFEREE: absolute ns prefer the ARTIC column whenever
its delta is >= 1 tick (PIT only for sub-tick windows); the 8:1 check is a
health label at the 0.5-5% band with the -8192-count reload signature
explicitly rejected.  LEGACY x2: halved-era captures must have their quoted ns
doubled before axis comparisons - the x2 scaling
this decoder applies to legacy PIT columns is exactly that rule.

Nothing here talks to hardware; it is a pure text parser.
"""

from __future__ import annotations

import argparse
import ast
import re
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path

# The 0x5F I/O-wait port is the machine's documented 600 ns / 30 clk_sys class.
WAIT_NS = 600
WAIT_CLK = 30

# Device-clock rates (machine-confirmed): raw PIT counts
# move at 2 457 600/s (1 = 406.901 ns) and the ARTIC counter ticks at
# 307 200/s (1 = 3255.208 ns), 8 raw counts per tick.  These give ABSOLUTE ns
# with no run-local scale - the thing the /TIME ladder never had.
# PIT_HZ follows the strap the measured divisor discriminates -
# a divisor near 0x4E00 means the BIOS work-area 0501 bit-7 strap selects the
# 1.9968 MHz oscillator and decode() switches the rate (a 19% move).
PIT_HZ = 2_457_600
ARTIC_HZ = 307_200
ARTIC_NS = 1e9 / ARTIC_HZ


def pit_ns(counts: int) -> float:
    return counts * 1e9 / PIT_HZ

# The two candidate axes for the anchor question: one
# 005F access is either the documented 600 ns (30 clk at 50 MHz) or the class
# table's 81 clk (1620 ns).  The absolute WAIT5F excess decides.
TM_N = 1024
AXIS_30_NS = 600.0
AXIS_81_NS = 1620.0

# ---------------------------------------------------------------------------
# THE RTL SIDE: what pc9821_iobus.sv io_access_cycles() prices TODAY, read out of
# the source.
#
# This column used to be a hand-copied table (0x5F 81, text GDC 23, graphics GDC
# 34, EGC 20, IDE PIO 42, default 42) - an earlier class table.  The current one
# dropped every class but 0x5F and the 8253 to the FSM floor (IO_MIN_HOLD = 4
# clk_sys), so that table printed a same-looking number for classes the core
# prices at the floor: exactly the misreading item 82's decision must not be
# made from.  The table is now parsed from the function itself, so it cannot go
# stale, and --check-rtl fails loudly when the parse drifts from EXPECTED_RTL.
# ---------------------------------------------------------------------------
IOBUS_SV = Path(__file__).resolve().parents[3] / "src/pc9821/core/pc9821_iobus.sv"
TOP_SV = Path(__file__).resolve().parents[3] / "z486_mister.sv"

# The checked-in expectation of the parse (--check-rtl), keyed by the I/O TIMING
# MODE: io_access_cycles() carries BOTH tables, chosen at run time by the OSD's
# "I/O timing" field (pc9821_iobus's io_timing_xe10), so --check-rtl checks both.
# FAST (`!xe10`): `constants` are the two firmware floors and `above_floor` is every
# census (port, mode) that is NOT the FSM floor - only the 8253 WRITE, whose floor is
# the ITF timer self-test's (one 2.4576 MHz tick); 0x5F is the floor both ways (its
# write is posted: the bus time behind it is IO_POST_5F, outside this function).
# XE10: the IO_NS_* class times at 50 MHz, and every census entry is priced by
# xe10_class() below - a hand-written mirror of the Xe10 branch, so an arm that moved
# away from it is a drift, not a re-derivation. The Xe10 table's per-access CPU share
# (IO_XE10_CPU_CYC, taken off in io_access_hold, not here) is pinned beside it.
XE10_CONSTANTS_50MHZ = {
    "IO_NS_SLOW_R": 40, "IO_NS_SLOW_W": 42,
    "IO_NS_EGC_R": 18, "IO_NS_FAST_W": 16,
    "IO_NS_GDC1": 21, "IO_NS_GDC2": 32,
    "IO_NS_EGCF_HI": 300, "IO_NS_9A0": 18, "IO_NS_FAA": 13,
    "IO_MIN_HOLD": 4, "IO_XE10_CPU_CYC": 8,
}

MODES = ("fast", "xe10")

EXPECTED_RTL: dict = {
    "fast": {
        "clock_hz": 90_000_000,
        "constants": {"IO_MIN_HOLD": 4, "IO_PIT_HOLD": 21},
        "above_floor": {
            (0x0071, "W"): "IO_PIT_HOLD", (0x0073, "W"): "IO_PIT_HOLD",
            (0x0075, "W"): "IO_PIT_HOLD", (0x0077, "W"): "IO_PIT_HOLD",
            (0x3FD9, "W"): "IO_PIT_HOLD", (0x3FDB, "W"): "IO_PIT_HOLD",
            (0x3FDD, "W"): "IO_PIT_HOLD", (0x3FDF, "W"): "IO_PIT_HOLD",
        },
    },
    "xe10": {"clock_hz": 90_000_000, "constants": XE10_CONSTANTS_50MHZ},
}


def xe10_class(port: int, mode: str) -> str:
    """The constant that must price (port, mode) in the Xe10 table.

    This is the checked-in expectation of the Xe10 branch's class table, written
    independently of the parser's arm structure: the net_ns of the Xe10's XE10T
    /IO rows (docs/probes/XE10T-XE10.TXT), which the RTL's comment lists row by
    row. The EGC file's EVEN-read class is charged as measured; its mechanism is
    still unresolved (item 82)."""
    wr = mode == "W"
    if port & 0xFFF0 == 0x04A0:
        if wr:
            return "IO_NS_FAST_W"
        return "IO_NS_EGCF_HI" if port % 2 == 0 else "IO_NS_SLOW_R"
    if port == 0x005F:
        return "IO_MIN_HOLD" if wr else "IO_NS_SLOW_R"   # the write is posted (IO_POST_5F)
    if port in (0x0060, 0x0062):
        return "IO_NS_GDC1"
    if port in (0x00A0, 0x00A2):
        return "IO_NS_GDC2"
    if port in (0x006A, 0x00A6):
        return "IO_NS_FAST_W" if wr else "IO_NS_EGC_R"
    if port in (0x007C, 0x007E, 0x0064, 0x00A4):
        return "IO_NS_FAST_W" if wr else "IO_NS_SLOW_R"
    if port in (0x09A0, 0x09A8):
        return "IO_NS_9A0"
    if port == 0x0FAA:
        return "IO_NS_FAA"
    # the 8253 (and its 0x3FD9 alias), the IDE task file and every other port
    return "IO_NS_SLOW_W" if wr else "IO_NS_SLOW_R"


def expected_class(mode_sel: str, port: int, mode: str) -> str:
    """The constant name that must price a census entry in I/O timing mode `mode_sel`."""
    if mode_sel == "fast":
        return EXPECTED_RTL["fast"]["above_floor"].get((port, mode), "IO_MIN_HOLD")
    return xe10_class(port, mode)


class RtlParseError(Exception):
    """io_access_cycles() could not be read out of the source."""


@dataclass(frozen=True)
class RtlArm:
    read_cycles: int
    write_cycles: int
    label: str
    ports: tuple[int, ...]      # the exact ports the arm names (empty = default)


@dataclass(frozen=True)
class RtlTable:
    clock_hz: int
    constants: dict[str, int]   # every modeled localparam: floors + IO_NS_*
    arms: tuple[RtlArm, ...]
    default: RtlArm
    top_clock_hz: int | None
    mode: str                   # the I/O timing mode: "fast" or "xe10"

    def arm_of(self, port: int) -> RtlArm:
        for arm in self.arms:
            if port in arm.ports:
                return arm
        return self.default

    def cycles(self, port: int, wr: bool = False) -> int:
        arm = self.arm_of(port)
        return arm.write_cycles if wr else arm.read_cycles

    def ns(self, cycles: int, clock_hz: int | None = None) -> float:
        return cycles * 1e9 / (clock_hz or self.top_clock_hz or self.clock_hz)


def _eval_node(node) -> int:
    """A Verilog constant expression, evaluated on the AST (no eval())."""
    if isinstance(node, ast.Constant) and isinstance(node.value, int):
        return node.value
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub, ast.Invert)):
        v = _eval_node(node.operand)
        return {ast.UAdd: lambda x: x, ast.USub: lambda x: -x, ast.Invert: lambda x: ~x}[type(node.op)](v)
    if isinstance(node, ast.BinOp) and isinstance(
            node.op, (ast.Add, ast.Sub, ast.Mult, ast.Div, ast.FloorDiv, ast.Mod,
                      ast.LShift, ast.RShift, ast.BitAnd, ast.BitOr, ast.BitXor)):
        a, b = _eval_node(node.left), _eval_node(node.right)
        op = node.op
        if isinstance(op, ast.Add):
            return a + b
        if isinstance(op, ast.Sub):
            return a - b
        if isinstance(op, ast.Mult):
            return a * b
        if isinstance(op, (ast.Div, ast.FloorDiv)):
            return a // b          # Verilog / on integers truncates toward zero
        if isinstance(op, ast.Mod):
            return a % b
        if isinstance(op, ast.LShift):
            return a << b
        if isinstance(op, ast.RShift):
            return a >> b
        if isinstance(op, ast.BitAnd):
            return a & b
        if isinstance(op, ast.BitOr):
            return a | b
        return a ^ b
    raise RtlParseError(f"unsupported constant expression node: {ast.dump(node)}")


def _const_expr(expr: str, env: dict[str, int]) -> int:
    """`32'd4`, `16'h04A0` and `(SYS_CLOCK_HZ * 32'd3 + 32'd4_999_999) / 32'd5_000_000`."""
    bases = {"b": 2, "o": 8, "d": 10, "h": 16}

    def lit(m: re.Match) -> str:
        digits = re.sub(r"_", "", m.group(3))
        return str(int(digits, bases[m.group(2).lower()]))

    e = re.sub(r"\b(\d+)'([bBoOdDhH])([0-9a-fA-F_]+)", lit, expr)
    e = re.sub(r"\b\d+'(?=\()", "", e)      # a sized expression cast: 16'(expr)

    def ident(m: re.Match) -> str:
        name = m.group(0)
        if name not in env:
            raise RtlParseError(f"unknown identifier {name!r} in {expr!r}")
        return str(env[name])

    e = re.sub(r"\b[A-Za-z_]\w*\b", ident, e)
    try:
        parsed = ast.parse(e, mode="eval")
    except SyntaxError as exc:
        raise RtlParseError(f"cannot parse {expr!r}: {exc}") from exc
    return _eval_node(parsed.body)


def _short_label(comment: str | None, fallback: str) -> str:
    """The arm's own trailing comment, cut to a column label."""
    if not comment:
        return fallback
    text = re.sub(r"//", "", comment).strip()
    text = re.sub(r"^(the|The)\s+", "", text)
    for cut in "(,.:":
        text = text.split(cut)[0]
    text = text.split(" is ")[0]          # "EGC register file is one 16-byte block"
    return text.strip() or fallback


def _top_clock_hz(path: Path) -> int | None:
    """z486_mister.sv's CLOCK_RATE_HZ: the clock the tree builds at today."""
    if not path.exists():
        return None
    m = re.search(r"localparam\s+CLOCK_RATE_HZ\s*=\s*([\d_]+)", path.read_text())
    return int(m.group(1).replace("_", "")) if m else None


def _constant(token: str, env: dict[str, int]) -> int:
    token = token.strip()
    return env[token] if token in env else _const_expr(token, env)


_SIMPLE_RHS = re.compile(r"^[\w']+$")
_DIR_RHS = re.compile(r"^wr\s*\?\s*(?P<w>[\w']+)\s*:\s*(?P<r>[\w']+)$")
_BLOCK_RHS = re.compile(
    r"^wr\s*\?\s*(?P<w>[\w']+)\s*:\s*"
    r"!portnum\[0\]\s*\?\s*"
    r"(?P<hi>[\w']+)\s*:\s*(?P<lo>[\w']+)$")


def _rhs_price(rhs: str, env: dict[str, int], port: int
               ) -> tuple[int, int]:
    """(read_cycles, write_cycles) for one io_access_cycles RHS.

    Modeled: a bare constant, `wr ? A : B`, and the Xe10 block arm's
    parity-gated nested ternary.  Anything else is a shape this parser does not
    model and raises - a stale RTL column is worse than no column."""
    rhs = " ".join(rhs.split())
    m = _SIMPLE_RHS.match(rhs)
    if m:
        v = _constant(rhs, env)
        return v, v
    m = _DIR_RHS.match(rhs)
    if m:
        return _constant(m.group("r"), env), _constant(m.group("w"), env)
    m = _BLOCK_RHS.match(rhs)
    if m:
        w = _constant(m.group("w"), env)
        lo = _constant(m.group("lo"), env)
        hi = _constant(m.group("hi"), env)
        read = hi if port % 2 == 0 else lo
        return read, w
    raise RtlParseError(f"io_access_cycles RHS in a shape this parser does not"
                        f" model: {rhs!r}")


def _block_comment(branch: str, if_start: int, if_end: int, assign_end: int
                   ) -> str | None:
    """The block arm's own comment: the // lines between the if and its
    assignment (the Xe10 branch's style), or failing that the // lines
    immediately before the if (the min branch's style)."""
    mid = branch[if_end:assign_end]
    m = re.search(r"//(.*)", mid)
    if m:
        return m.group(1).strip()
    pre = branch[:if_start].splitlines()
    pre_comments = []
    for line in reversed(pre):
        if line.strip().startswith("//"):
            pre_comments.append(line.strip()[2:].strip())
        elif line.strip():
            break
    return pre_comments[-1] if pre_comments else None


def _parse_branch(branch: str, env: dict[str, int]
                  ) -> tuple[list[RtlArm], RtlArm]:
    """The named arms + default arm of one io_access_cycles branch."""
    arms: list[RtlArm] = []

    blk_if = re.search(
        r"if\s*\(\(?\s*portnum\s*&\s*(16'h[0-9A-Fa-f_]+)\s*\)?\s*==\s*"
        r"(16'h[0-9A-Fa-f_]+)\s*\)", branch)
    if not blk_if:
        raise RtlParseError("the (portnum & 0xFFF0) == 0x04A0 block arm not found")
    mask = _const_expr(blk_if.group(1), env)
    base = _const_expr(blk_if.group(2), env)
    size = (~mask & 0xFFFF) + 1
    if size > 0x100:
        raise RtlParseError(f"the block arm covers {size} ports: mask 0x{mask:04X} looks wrong")
    blk_assign = re.search(r"io_access_cycles\s*=\s*(.+?);",
                           branch[blk_if.end():], re.S)
    if not blk_assign:
        raise RtlParseError("the block arm's assignment not found")
    even = _rhs_price(blk_assign.group(1), env, base)
    odd = _rhs_price(blk_assign.group(1), env, base + 1)
    if even[1] != odd[1]:
        raise RtlParseError("the block arm's write branch is parity-dependent (unmodeled)")
    label = _short_label(_block_comment(branch, blk_if.start(), blk_if.end(),
                                        blk_if.end() + blk_assign.end()),
                         "block arm")
    if even[0] == odd[0]:
        arms.append(RtlArm(even[0], even[1], label, tuple(range(base, base + size))))
    else:
        arms.append(RtlArm(even[0], even[1], label, tuple(range(base, base + size, 2))))
        arms.append(RtlArm(odd[0], odd[1], label,
                           tuple(range(base + 1, base + size, 2))))

    case = re.search(r"case\s*\(\s*portnum\s*\)(.*?)\bendcase", branch, re.S)
    if not case:
        raise RtlParseError("the case (portnum) block not found")
    case_body = case.group(1)
    # '16'd23' as well as 'IO_MIN_HOLD': a literal arm is legal and, if the pattern
    # could not see it, the arm would vanish from the table silently.
    arm_re = re.compile(
        r"(?P<ports>(?:16'h[0-9A-Fa-f_]+\s*,\s*)*16'h[0-9A-Fa-f_]+|default)\s*:\s*"
        r"io_access_cycles\s*=\s*(?P<rhs>.+?);[ \t]*(?P<comment>//[^\n]*)?", re.S)
    found = 0
    default_arm: RtlArm | None = None
    for am in arm_re.finditer(case_body):
        found += 1
        ports = tuple(int(p.replace("_", ""), 16)
                      for p in re.findall(r"16'h([0-9A-Fa-f_]+)", am.group("ports")))
        read, write = _rhs_price(am.group("rhs"), env, 0)
        arm = RtlArm(read, write,
                     _short_label(am.group("comment"),
                                  am.group("rhs") if ports else "default"),
                     ports)
        if ports:
            arms.append(arm)
        else:
            default_arm = arm
    # An arm in a shape the parser does not model would be invisible to the
    # regexes above, so count the branch's own assignments and refuse to be
    # silently incomplete.
    assignments = len(re.findall(r"io_access_cycles\s*=", branch))
    matched = 1 + found            # the (portnum & ...) block arm + the case arms
    if not found or matched != assignments:
        raise RtlParseError(f"{matched} arm(s) matched (1 block + {found} case) but"
                            f" the branch assigns {assignments} time(s):"
                            " an arm is in a shape this parser does not model")
    if default_arm is None:
        raise RtlParseError("no default arm")
    return arms, default_arm


def parse_io_access_cycles(path: Path = IOBUS_SV, mode: str = "fast") -> RtlTable:
    """io_access_cycles()'s arms and constants, read from the RTL source.

    Parsed: SYS_CLOCK_HZ's default, every modeled localparam (the two firmware
    floors, the Xe10 IO_NS_* class times and its CPU share), and the block arm and
    case arms of the branch I/O timing `mode` selects ("fast": `if (!xe10)`,
    "xe10": its else) - each arm's trailing comment as its label and its READ/WRITE
    price.  Raises RtlParseError on anything unexpected: a stale RTL column
    would be worse than no column.
    """
    if not path.exists():
        raise RtlParseError(f"{path} not found")
    text = path.read_text()

    env: dict[str, int] = {}
    # SYS_CLOCK_HZ's default is the last parameter before the port list, so it has
    # no ';' (the file writes `parameter [31:0] SYS_CLOCK_HZ = 32'd50_000_000`).
    m = re.search(r"parameter\s*(?:\[[^\]]*\]\s*)?SYS_CLOCK_HZ\s*=\s*([^,;)\n]+)", text)
    if not m:
        raise RtlParseError("SYS_CLOCK_HZ's default not found")
    env["SYS_CLOCK_HZ"] = _const_expr(m.group(1), env)

    consts: dict[str, str] = {
        n: e for n, e in re.findall(
            r"localparam\s*(?:\[[^\]]*\]\s*)?(\w+)\s*=\s*(.+?);", text)
    }
    modeled = {"IO_MIN_HOLD", "IO_PIT_HOLD", "IO_XE10_CPU_CYC",
               "IO_NS_SLOW_R", "IO_NS_SLOW_W", "IO_NS_EGC_R", "IO_NS_FAST_W",
               "IO_NS_GDC1", "IO_NS_GDC2",
               "IO_NS_EGCF_HI", "IO_NS_9A0", "IO_NS_FAA"}
    missing = modeled - set(consts)
    if missing:
        raise RtlParseError(f"localparams not found: {sorted(missing)}")
    for _ in range(6):                      # fixpoint: the exprs reference SYS_CLOCK_HZ
        for name, expr in consts.items():
            if name not in env:
                try:
                    env[name] = _const_expr(expr, env)
                except RtlParseError:
                    pass
    for name in modeled:
        if name not in env:
            raise RtlParseError(f"{name} did not evaluate (expr {consts[name]!r})")

    body = re.search(r"function\s+automatic\s*\[\d+:\d+\]\s*io_access_cycles\s*\(.*?\n(.*?)\n\s*endfunction",
                     text, re.S)
    if not body:
        raise RtlParseError("io_access_cycles() body not found")
    body = body.group(1)

    if mode not in MODES:
        raise RtlParseError(f"unknown I/O timing mode {mode!r}")
    split = re.search(r"if\s*\(\s*!\s*xe10\s*\)\s*begin(.*?)\belse\s*begin(.*?)\Z",
                      body, re.S)
    if not split:
        raise RtlParseError("the `if (!xe10)` (Fast) / else (Xe10) branch not found")
    active = split.group(1) if mode == "fast" else split.group(2)

    arms, default_arm = _parse_branch(active, env)

    return RtlTable(env["SYS_CLOCK_HZ"],
                    {name: env[name] for name in sorted(modeled)},
                    tuple(arms), default_arm, _top_clock_hz(TOP_SV), mode)


try:
    RTL: RtlTable | None = parse_io_access_cycles()
except RtlParseError as exc:
    RTL = None
    RTL_ERROR = str(exc)
else:
    RTL_ERROR = ""


def rtl_drift(table: RtlTable | None) -> list[str]:
    """Every way the parsed table differs from the checked-in EXPECTED_RTL.

    Each census entry's READ and WRITE price is compared to the CONSTANT the
    checked-in expectation names for it (not just to the FSM floor): swapping
    IO_WAIT_5F and IO_PIT_HOLD (30 <-> 21) would otherwise pass the gate while
    printing a wrong price.
    """
    if table is None:
        return [f"io_access_cycles() unreadable: {RTL_ERROR}"]
    drift: list[str] = []
    prof = EXPECTED_RTL.get(table.mode)
    if prof is None:
        return [f"I/O timing mode {table.mode!r} is not pinned in EXPECTED_RTL"]
    for name, value in sorted(prof["constants"].items()):
        got = table.constants.get(name)
        if got != value:
            drift.append(f"{name}: source says {got}, expected {value}")
    for port, mode in CENSUS + RTL_EXTRA:
        want_name = expected_class(table.mode, port, mode)
        want_cycles = table.constants.get(want_name)
        if want_cycles is None:
            drift.append(f"0x{port:04X} ({mode}): the localparam {want_name} no longer"
                         " evaluates (the arm cannot be priced)")
            continue
        got = table.cycles(port, mode == "W")
        if got != want_cycles:
            drift.append(f"{table.mode} 0x{port:04X} ({mode}): priced at {got} clk"
                         f" ('{table.arm_of(port).label}'), expected {want_name} ="
                         f" {want_cycles} clk")
    top = table.top_clock_hz
    if top is not None and top != prof["clock_hz"]:
        drift.append(f"the build profile's clock is {top} Hz, the expectation pins "
                     f"{prof['clock_hz']} Hz (re-derive EXPECTED_RTL)")
    return drift


# Entries --check-rtl prices beyond the probe's census: the XE10T /IO rows that gave the Xe10
# table an arm of its own and that ioprobe never measured (the 0x64/0xA4/0x7E fast writes,
# the 0x09A8 read).
RTL_EXTRA: list[tuple[int, str]] = [
    (0x0064, "W"), (0x00A4, "W"), (0x007E, "W"), (0x09A8, "R"),
]


def print_rtl_drift(drift: list[str]) -> None:
    print("  ** RTL TABLE CONTRACT VIOLATION: src/pc9821/core/pc9821_iobus.sv")
    print("     io_access_cycles() no longer matches the checked-in EXPECTED_RTL, so the")
    print("     RTL column below is NOT what the core prices. THIS DECODE EXITS 1.")
    print("     Re-derive EXPECTED_RTL in ioprobe_decode.py (or fix the RTL). **")
    for d in drift:
        print(f"     - {d}")



# The census the probe measures: every entry of io_tab in ioprobe.s, as
# (port, mode). A BEGIN: with no END: names the port a hang happened in, and a
# port that has no section at all never got reached, so both are reported.
CENSUS: list[tuple[int, str]] = [
    (0x005F, "W"), (0x005F, "R"), (0x005C, "R"),
    (0x0000, "R"), (0x0002, "R"), (0x0008, "R"), (0x000A, "R"),
    (0x0071, "R"), (0x0073, "R"), (0x0077, "W"),
    (0x0020, "R"), (0x0022, "R"),
    (0x0041, "R"), (0x0043, "R"),
    (0x0060, "R"), (0x0062, "R"),
    (0x00A0, "R"), (0x00A2, "R"),
    (0x006A, "R"), (0x006A, "W"), (0x007C, "R"), (0x007C, "W"),
    (0x00A6, "R"), (0x00A6, "W"),
    (0x04A0, "R"), (0x04A1, "R"), (0x04A2, "R"), (0x04A3, "R"),
    (0x04A4, "R"), (0x04A5, "R"), (0x04A6, "R"), (0x04A7, "R"),
    (0x04A8, "R"), (0x04A9, "R"), (0x04AA, "R"), (0x04AB, "R"),
    (0x04AC, "R"), (0x04AD, "R"), (0x04AE, "R"), (0x04A0, "W"),
    (0x0188, "R"), (0x018A, "R"), (0x018C, "R"), (0x018E, "R"),
    (0x0188, "W"), (0x018A, "W"),
    (0xA460, "R"), (0xA462, "R"),
    (0x0430, "R"), (0x0432, "R"), (0x0433, "R"), (0x0435, "R"),
    (0x0640, "R"), (0x0641, "R"), (0x0642, "R"), (0x0644, "R"),
    (0x0646, "R"), (0x0648, "R"), (0x064A, "R"), (0x064C, "R"),
    (0x064E, "R"), (0x1E8E, "R"),
    (0x0740, "R"), (0x0742, "R"), (0x0744, "R"), (0x0746, "R"),
    (0x0748, "R"), (0x074A, "R"), (0x074C, "R"), (0x074E, "R"),
    (0x1480, "R"), (0x1481, "R"),
    (0x0011, "R"), (0x001B, "R"), (0x0021, "R"), (0x0023, "R"),
    (0x0025, "R"), (0x0027, "R"), (0x0029, "R"),
    (0x0040, "R"), (0x0090, "R"), (0x0092, "R"), (0x0094, "R"),
    (0x043B, "R"), (0x043D, "R"), (0x043F, "R"), (0x0461, "R"),
    (0x0463, "R"), (0x0530, "R"), (0x0531, "R"), (0x0534, "R"),
    (0x053D, "R"), (0x063C, "R"), (0x063D, "R"), (0x063E, "R"),
    (0x063F, "R"), (0x0EE0, "R"), (0x09A0, "R"), (0x98D7, "R"),
    (0x9892, "R"), (0x9894, "R"), (0x18F0, "R"), (0x18F2, "R"),
    (0x0FAA, "R"), (0x7FD9, "R"), (0xBFDB, "R"),
]


def sections(text: str) -> tuple[dict[str, list[str]], list[str], list[str]]:
    """Split a capture by BEGIN:/END: markers.

    Returns (found, opens, closes): found maps a section name to its lines, opens
    and closes are the marker names in order. A name in opens with no matching
    close is the section that hung.

    A marker must START its own line.  The probe's banner prose names the markers
    (`Sections are BEGIN:IO<port><mode>/END:IO<port><mode>: ...`), and a
    mid-line match counted that sentence as a section named `IO`: the first
    100 MHz IO.TXT is complete (it ends `IOPROBE DONE`) but decoded as
    `HUNG: IO` plus one extra section, with the census otherwise exact.  The
    anchor is what makes prose safe, and it holds for the already-archived
    captures too (every real marker is alone on its line).
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


ROW_RE = re.compile(
    r"^\s*(?P<label>\S+)\s+"
    r"port=(?P<port>[0-9A-Fa-f]{4})\s+"
    r"mode=(?P<mode>[RW])\s+"
    r"pit=(?P<pit>[0-9A-Fa-f]+)\s+"
    r"base=(?P<base>[0-9A-Fa-f]+)\s+"
    r"artic=(?P<artic>[0-9A-Fa-f]+)\s+"
    r"bartic=(?P<bartic>[0-9A-Fa-f]+)"
)


def parse_rows(lines: list[str]) -> list[dict]:
    rows = []
    for line in lines:
        m = ROW_RE.match(line)
        if m:
            d = m.groupdict()
            rows.append(
                {
                    "label": d["label"],
                    "port": int(d["port"], 16),
                    "mode": d["mode"],
                    "pit": int(d["pit"], 16),
                    "base": int(d["base"], 16),
                    "artic": int(d["artic"], 16),
                    "bartic": int(d["bartic"], 16),
                }
            )
    return rows


def excess(x: int, y: int) -> int:
    return max(x - y, 0)


def pick_ns(pit_counts: int, art_ticks: int) -> tuple[float, str]:
    """Absolute ns for one window, refereed (ARTIC whenever its delta is >= 1 tick).

    Prefer ARTIC whenever its delta is >= 1 tick: at these scales the 24-bit
    counter cannot wrap or tear, while the PIT's 16-bit raw delta wraps
    silently (a 3-reload window reads ~8192 counts low - INSIDE the old 25%
    band) and the torn latch word mis-assembles.  PIT
    survives only for sub-tick windows (art_ticks == 0).  The 8:1 cross-check
    is a health label at the machine-measured 0.5-5% band: ok / WRAP (the
    -8192-count signature, explicitly rejected) / neq / sub.

    Small-window rule: the absolute floors (16 counts,
    32 for the WRAP check) exist for latch-read quantization, but they are
    CLAMPED to ref so the effective band never exceeds +/-100% on windows
    below ~320 counts (art=1 tick, ref=8: 'ok' now spans pit 0..16, not
    0..24).  Label-only: ns still come from ARTIC at art_ticks >= 1.
    """
    if art_ticks >= 1:
        ref = max(art_ticks * 8, 1)
        if abs(pit_counts - ref) <= min(max(16, 0.05 * ref), ref):
            return art_ticks * ARTIC_NS, "ok"
        if abs(ref - pit_counts - 8192) <= min(max(32, 0.02 * ref), ref):
            return art_ticks * ARTIC_NS, "WRAP"
        return art_ticks * ARTIC_NS, "neq"
    return pit_ns(pit_counts), "sub"


def clk_and_ns(ex: int, w_ex: int) -> tuple[float | None, float | None]:
    if w_ex <= 0 or ex <= 0:
        return None, None
    return WAIT_CLK * ex / w_ex, WAIT_NS * ex / w_ex


def print_table(rows: list[dict], scale: int) -> None:
    wait = next((r for r in rows if r["port"] == 0x005F and r["mode"] == "W"), None)
    if wait is None:
        print("  (no WAIT5F row: the run never reached the 0x005F anchor - run it alone)")
        return
    w_ex = excess(wait["pit"], wait["base"]) * scale
    w_art = excess(wait["artic"], wait["bartic"])
    w_abs, w_which = pick_ns(w_ex, w_art)
    print(
        f"  anchor 0x005F W: excess {w_ex} raw PIT counts / {w_art} ARTIC ticks"
    )
    d30 = abs(w_abs / TM_N - AXIS_30_NS) / AXIS_30_NS
    d81 = abs(w_abs / TM_N - AXIS_81_NS) / AXIS_81_NS
    print(
        f"  ANCHOR: one 005F write access = {w_abs / TM_N:.0f} ns over its control"
        f" (via {w_which})"
    )
    print(
        f"    (600 ns is {100 * w_abs / TM_N / AXIS_30_NS:.0f}% of the documented figure;"
        f" 1620 ns is {100 * w_abs / TM_N / AXIS_81_NS:.0f}% of 81 clk at 50 MHz)."
    )
    if min(d30, d81) > 0.20:
        print(
            "    INDETERMINATE - the 0x5F anchor stays open: within ~20% of neither axis. Do NOT"
            "\n    print a nearest-axis verdict from it.  LEGACY x2 RULE: halved-era captures"
            "\n    (/TIME and the T2/T2R prints) must be doubled"
            "\n    before this comparison - T2R's raw 819 ns reads 1638 ns corrected, at the"
            "\n    81-clk axis where TR.TXT (1.63 us) and EGCPORT (1.73 us) already point."
        )
    else:
        verdict = (
            "the documented 30 clk (600 ns) axis" if d30 < d81
            else "the class table's 81 clk (1620 ns) axis"
        )
        print(
            f"    Verdict: closer to {verdict} (within 20%)."
            "\n    This decides the 0x5F anchor question. Note the"
            "\n    documented 600 ns may be the inserted WAIT only, not the total access cost:"
            "\n    if the measurement lands ~1.6-1.7 us both readings survive and the total is"
            "\n    what io_access_cycles prices.  (Legacy halved-era prints: x2 first.)"
        )
    if w_ex <= 0:
        print("  (the anchor's PIT excess is not positive: read the ARTIC columns only)")
    # Xe10's classes are REAL TIMES evaluated at the iobus default clock (SYS_CLOCK_HZ), so
    # their ns are taken at that clock; Fast's floors are clk_sys COUNTS, so theirs are taken
    # at the build profile's clock.
    clock = ((RTL.clock_hz if RTL.mode == "xe10" else (RTL.top_clock_hz or RTL.clock_hz))
             if RTL else 50_000_000)
    print(
        f"  {'port':5} {'md':2} {'label':8} {'pit':>6} {'base':>6} {'excess':>6} "
        f"{'clk_sys':>7} {'ns':>6} {'clk_a':>7} {'abs_ns':>8} {'via':>3} "
        f"{'RTL':>4} {'RTL_ns':>7} {'xRTL':>5} arm"
    )
    for r in sorted(rows, key=lambda r: (r["port"], r["mode"])):
        ex = excess(r["pit"], r["base"]) * scale
        clk, ns = clk_and_ns(ex, w_ex)
        art = excess(r["artic"], r["bartic"])
        clk_a, _ = clk_and_ns(art, w_art)
        abs_ns, which = pick_ns(ex, art)
        if RTL is not None:
            cycles = RTL.cycles(r["port"], r["mode"] == "W")
            price_ns = RTL.ns(cycles, clock)
            rtl_s, rtl_ns_s = f"{cycles}", f"{price_ns:.0f}"
            ratio_s = f"{abs_ns / TM_N / price_ns:.1f}" if price_ns > 0 else "-"
            rtl_arm = RTL.arm_of(r["port"]).label
        else:
            rtl_s, rtl_ns_s, ratio_s = "-", "-", "-"
            rtl_arm = f"RTL UNREADABLE ({RTL_ERROR})"
        if r["port"] == 0x005F and r["mode"] == "W":
            clk_s, ns_s = "30.0", "600"       # the axis itself (documented 600 ns / 30 clk)
        else:
            clk_s = f"{clk:.1f}" if clk is not None else "-"
            ns_s = f"{ns:.0f}" if ns is not None else "-"
        clk_a_s = f"{clk_a:.1f}" if clk_a is not None else "-"
        flag = ""
        if clk is not None and clk_a is not None and max(clk, clk_a) > 0:
            if abs(clk - clk_a) / max(clk, clk_a) > 0.05:
                flag = "  <-- PIT/ARTIC disagree beyond 5% (wrapped/torn PIT window? read clk_a)"
        print(
            f"  {r['port']:04X}  {r['mode']:2} {r['label']:8} {r['pit']:6d} "
            f"{r['base']:6d} {ex:6d} {clk_s:>7} {ns_s:>6} {clk_a_s:>7} "
            f"{abs_ns / TM_N:>8.1f} {which:>3} {rtl_s:>4} {rtl_ns_s:>7} {ratio_s:>5} "
            f"{rtl_arm}{flag}"
        )
    print(
        f"  clk_sys is anchored so 0x005F = {WAIT_CLK} clk (the DOCUMENTED 600 ns).\n"
        f"  RTL and RTL_ns are what src/pc9821/core/pc9821_iobus.sv io_access_cycles()\n"
        f"  prices TODAY in the {RTL.mode if RTL else 'fast'} I/O timing table (--io-timing),"
        f" parsed from that function\n  at {clock / 1e6:.0f} MHz (Xe10: the iobus default clock,"
        " whose classes are real times;\n  Fast: the profile's CLOCK_RATE_HZ, whose floors are"
        " clk_sys counts); xRTL = abs_ns / RTL_ns.\n"
        "  abs_ns is ABSOLUTE (device clocks, both columns refereed at 8 raw PIT counts per\n"
        "  ARTIC tick): per-access ns over the row's own control, comparable across runs.\n"
        "  THE 0x5F ANCHOR'S xBASE CURRENCY: the ratio to quote from this table is the clk_sys column\n"
        "  (the class's excess over its own paired control as a ratio to the WAIT5F anchor; the\n"
        "  run's own scale cancels) - \"quote only xBASE\" means this column, not the ns ones.\n"
        "  xRTL 10x on a Fast floor row is EXPECTED, not a decoder bug: Fast drops every class but\n"
        "  the 8253 write to IO_MIN_HOLD deliberately (the OSD's I/O timing field, item 82;\n"
        "  Xe10 is the measured table).  What the column is for is making sure the RTL\n"
        "  figure you read is the one the FSM actually carries."
    )


def print_class_summary(rows: list[dict]) -> None:
    """The measured median per io_access_cycles() ARM, beside that arm's price.

    The arms are the function's own (their labels come from its comments), so a
    port priced at the FSM floor groups under the floor and the summary cannot
    imply a class price the core no longer carries.  meash/RTL compares the two
    in ns at the profile clock: a large ratio is item 82's stall-budget gap.
    """
    wait = next((r for r in rows if r["port"] == 0x005F and r["mode"] == "W"), None)
    if wait is None:
        return
    w_ex = excess(wait["pit"], wait["base"])
    if w_ex <= 0:
        return
    # Xe10's classes are REAL TIMES evaluated at the iobus default clock (SYS_CLOCK_HZ), so
    # their ns are taken at that clock; Fast's floors are clk_sys COUNTS, so theirs are taken
    # at the build profile's clock.
    clock = ((RTL.clock_hz if RTL.mode == "xe10" else (RTL.top_clock_hz or RTL.clock_hz))
             if RTL else 50_000_000)
    # The machine's absolute price of one 0x5F access: what the clk_sys axis is worth
    # in ns for THIS capture (1621 ns on IO.TXT, not the documented 600).  Using the
    # capture's own anchor keeps meas_ns equal to the per-row abs_ns column.
    anchor_ns = pick_ns(excess(wait["pit"], wait["base"]),
                        excess(wait["artic"], wait["bartic"]))[0] / TM_N
    groups: dict[tuple[str, str], list[tuple[int, str, float]]] = {}
    for r in rows:
        if r["port"] == 0x005F:
            continue  # the anchor itself; its 0x5F row is the 30.0/600 reference
        clk, _ = clk_and_ns(excess(r["pit"], r["base"]), w_ex)
        if clk is None:
            continue
        arm = RTL.arm_of(r["port"]) if RTL else None
        groups.setdefault((arm.label if arm else "?", r["mode"]), []).append(
            (r["port"], r["mode"], clk))
    print(
        f"  {'arm':24} {'md':2} {'ports':>5} {'med30':>7} {'RTL':>5} {'RTL_ns':>7} "
        f"{'meas_ns':>8} {'xRTL':>5}  (min30..max30)"
    )
    for (arm_name, mode), entries in sorted(groups.items()):
        vals = [c for _, _, c in entries]
        wr = mode == "W"
        cycles = RTL.cycles(entries[0][0], wr) if RTL else 0
        price_ns = RTL.ns(cycles, clock) if RTL else float("nan")
        lo, med, hi = min(vals), statistics.median(vals), max(vals)
        # med30 is median/clk_sys on the 0x5F=30 axis; the machine's absolute price is
        # that ratio against THIS capture's own 0x5F absolute (see anchor_ns).
        meas_ns = med / WAIT_CLK * anchor_ns
        print(
            f"  {arm_name:24} {mode:2} {len(vals):>5} {med:>7.1f} {cycles:>5} "
            f"{price_ns:>7.0f} {meas_ns:>8.0f} {meas_ns / price_ns:>5.1f}  "
            f"({lo:.1f}..{hi:.1f})"
        )
    print(
        f"  med30 is the measured median on the documented 0x005F = 30 axis (one 0x5F\n"
        f"  access = {anchor_ns:.0f} ns ABSOLUTE on this capture - the 600 ns figure is the\n"
        f"  documented WAIT alone, so the two are not the same quantity; see docs/probes/IO.TXT).\n"
        "  RTL/RTL_ns is what io_access_cycles() prices that arm today at the profile\n"
        "  clock.  xRTL > 1 is the machine costing more than the core bills it - that gap\n"
        "  IS item 82's stall-budget decision, and the FSM-floor change chose the floor\n"
        "  deliberately, so a large xRTL on an FSM-floor arm is expected rather than a\n"
        "  defect.  Ports whose median is an outlier within their own arm are candidates\n"
        "  for their own arm."
    )


def print_completeness(opens: list[str], closes: list[str]) -> None:
    """Was the run complete?  A hung section is the one whose BEGIN: has no END:;
    a census port with no section was never reached.  The DONE trailer is checked
    too, so a capture truncated after its last END: is not read as complete."""
    closed = set(closes)
    hung = [o for o in opens if o not in closed]
    census_names = {f"IO{p:04X}{m}" for p, m in CENSUS}
    io_seen = {o for o in opens if o.startswith("IO")}
    missing = sorted(census_names - io_seen)
    extra = sorted(io_seen - census_names)
    print(f"  BEGIN: markers: {len(opens)} ({len(io_seen)} IO-prefixed section(s) + "
          f"{len(opens) - len(io_seen)} other); the census expects {len(census_names)} "
          f"(io_tab entries)")
    print(f"  IO-prefixed names matching the census: {len(io_seen - set(extra))}; "
          f"not in the census: {len(extra)}")
    if hung:
        print(f"  HUNG (BEGIN: with no END:): {', '.join(hung)}")
    if missing:
        print(f"  NOT REACHED: {', '.join(missing)}")
    if extra:
        print(f"  with an unknown/extra name: {', '.join(extra)}")
    if not hung and not missing and not extra:
        print("  complete: every census port has a closed BEGIN:/END: pair")
    else:
        print("  (a name above that is not a census section is either a new io_tab entry"
              " the")
        print("   CENSUS lacks, or prose that matched a marker - both are decoder-side)")


def decode(text: str) -> list[str]:
    """Decode one capture.  Returns the RTL-table drift list (empty when the parse
    matches EXPECTED_RTL); main() exits non-zero on a non-empty one, because the
    RTL column IS a contract and a wrong price must not read as a note."""
    global PIT_HZ
    PIT_HZ = 2_457_600  # reset per capture: one 0x4E00-era
    # file in a multi-file invocation must not skew every later capture 23%.
    found, opens, closes = sections(text)

    # The halved-era probes printed raw counts / 2 (the mode-3 halving is 2x wrong on
    # this machine).  The current probe prints
    # raw counts (its banner says so); a legacy capture is scaled x2 here so the
    # absolute columns mean the same thing either way.
    scale = 1 if "RAW counts" in text else 2

    print("== RTL class table (src/pc9821/core/pc9821_iobus.sv, parsed) ==")
    drift: list[str] = rtl_drift(RTL)
    if RTL is None:
        print(f"  ** the RTL column is UNAVAILABLE: {RTL_ERROR} **")
        print("  Do not read any RTL figure below as what the core prices.")
    else:
        clock = RTL.top_clock_hz or RTL.clock_hz
        print(f"  clock {clock / 1e6:.0f} MHz (z486_mister.sv CLOCK_RATE_HZ; the iobus"
              f" default is {RTL.clock_hz / 1e6:.0f} MHz; I/O timing {RTL.mode})")
        for name in ("IO_MIN_HOLD", "IO_PIT_HOLD", "IO_XE10_CPU_CYC"):
            c = RTL.constants[name]
            print(f"  {name:12} = {c:>3} clk = {RTL.ns(c, clock):>5.0f} ns")
        for arm in RTL.arms:
            ports = ", ".join(f"{p:04X}" for p in arm.ports[:8]) + (
                f" (+{len(arm.ports) - 8})" if len(arm.ports) > 8 else "")
            price = (f"{arm.read_cycles}" if arm.read_cycles == arm.write_cycles
                     else f"{arm.read_cycles} R / {arm.write_cycles} W")
            print(f"  {price:>13} clk  {arm.label:24} {ports}")
        price = (f"{RTL.default.read_cycles}"
                 if RTL.default.read_cycles == RTL.default.write_cycles
                 else f"{RTL.default.read_cycles} R / {RTL.default.write_cycles} W")
        print(f"  {price:>13} clk  {RTL.default.label:24} (every other port)")
        if drift:
            print_rtl_drift(drift)
        else:
            print("  (matches EXPECTED_RTL - see --check-rtl to assert this)")

    divisor = None
    m = re.search(r"PIT channel-0 measured divisor =\s*([0-9A-Fa-f]+)", text)
    if m:
        divisor = int(m.group(1), 16)
    print("== SETUP ==")
    if scale == 2:
        print("  (legacy capture: PIT columns are halved-era, scaled x2 for absolute ns)")
    if divisor is not None:
        note = "" if 0x4000 <= divisor <= 0x7000 else " (outside the documented 0x6000/0x4E00; the ratio method does not need it)"
        print(f"  PIT channel-0 measured divisor = 0x{divisor:04X}{note}")
        # The divisor discriminates the strap - 0x4E00 means the
        # BIOS work-area 0501 bit-7 strap selects the 1.9968 MHz oscillator.
        if 0x4800 <= divisor <= 0x5400:
            PIT_HZ = 1_996_800
            print("  PIT STRAP: divisor ~= 0x4E00 -> the 1.9968 MHz oscillator"
                  " (work-area 0501 bit 7); PIT rate switched to 1996800 counts/s")
        elif 0x5A00 <= divisor <= 0x6600:
            print("  PIT STRAP: divisor ~= 0x6000 -> the 2.4576 MHz oscillator"
                  " (work-area 0501 bit 7)")
        else:
            print(f"  ** PIT STRAP UNRECOGNIZED: divisor 0x{divisor:04X} is neither 0x6000"
                  " nor 0x4E00 (tearing?). Assuming 2.4576 MHz; sub-tick PIT windows may"
                  " be skewed. **")
    else:
        print("  (no divisor line)")

    rows: list[dict] = []
    for name, lines in found.items():
        rows.extend(parse_rows(lines))

    print("\n== per-port access cost ==")
    print_table(rows, scale)

    print("\n== class summary ==")
    print_class_summary(rows)

    print("\n== run completeness ==")
    print_completeness(opens, closes)
    return drift


def main() -> int:
    global RTL, RTL_ERROR
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("captures", nargs="*", help="IOPROBE capture file(s)")
    ap.add_argument("--check-rtl", action="store_true",
                    help="parse io_access_cycles() and FAIL (exit 1) if it drifts from"
                         " the checked-in EXPECTED_RTL; no capture needed")
    ap.add_argument("--rtl", type=Path, metavar="PATH",
                    help="read io_access_cycles() from PATH instead of the tree's"
                         " pc9821_iobus.sv (for checking a proposed RTL change)")
    ap.add_argument("--io-timing", choices=MODES, default="fast",
                    help="which I/O timing table (the OSD's I/O timing field) the RTL"
                         " column prices: fast (the default) or xe10")
    args = ap.parse_args()
    rtl_path = args.rtl or IOBUS_SV
    if args.rtl is not None or args.io_timing != "fast":
        try:
            RTL = parse_io_access_cycles(rtl_path, args.io_timing)
            RTL_ERROR = ""
        except RtlParseError as exc:
            RTL, RTL_ERROR = None, str(exc)
    if args.check_rtl:
        failed = 0
        for mode in MODES:
            try:
                table = parse_io_access_cycles(rtl_path, mode)
            except RtlParseError as exc:
                print(f"FAIL: io_access_cycles() unreadable ({mode}): {exc}")
                return 1
            drift = rtl_drift(table)
            clock = table.top_clock_hz or table.clock_hz
            print(f"  parsed {rtl_path} at {clock / 1e6:.0f} MHz "
                  f"(I/O timing {mode}): {len(table.arms)} named arm(s) + the default, "
                  f"constants {table.constants}")
            if drift:
                print_rtl_drift(drift)
                failed += len(drift)
                continue
            if mode == "fast":
                print(f"  fast: above the FSM floor in the census: "
                      f"{', '.join(f'0x{p:04X} {m}' for p, m in sorted(EXPECTED_RTL['fast']['above_floor']))}")
            else:
                print("  xe10: every census entry is priced by xe10_class()")
        if failed:
            print(f"\nFAIL ({failed} drift item(s))")
            return 1
        print("\nPASS (io_access_cycles() matches EXPECTED_RTL in both I/O timing modes)")
        return 0
    if not args.captures:
        ap.error("a capture file is required (or pass --check-rtl)")
    drift_seen = False
    for path in args.captures:
        try:
            text = open(path, "r", errors="replace").read()
        except OSError as exc:
            print(f"cannot read {path}: {exc}", file=sys.stderr)
            return 1
        print(f"### {path}")
        drift_seen |= bool(decode(text))
        print()
    # A drifted (or unreadable) RTL table is a contract violation: the decode's RTL
    # column is not what the core prices, so it must not exit 0.
    return 1 if drift_seen else 0


if __name__ == "__main__":
    sys.exit(main())

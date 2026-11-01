#!/usr/bin/env python3
"""check_powerup_init.py -- no register's behaviour may rest on an initializer Quartus discards.

THE FACTS (Quartus 17.0, the container build.py runs; measured by synthesizing a probe module with
the qsf's ALLOW_POWER_UP_DONT_CARE ON and reading quartus_map's report and quartus_cdb's VQM,
docs/sdram-margin.md section 2):
  - an initializer on an INTERNAL register declaration (`reg r = 1'b1;`) is kept: the register
    powers up to it (a 1 gets NOT-gate push-back), even when its only assignment is a constant
    (`reg s = 1'b0; ... if (go) s <= 1'b1;` stays a register);
  - an initializer in an ANSI OUTPUT-PORT declaration (`output reg p = 1'b1`) is IGNORED: the
    register gets no power-up level (power_up low, no push-back), and when its data input is a
    constant (a set-only or clear-only flag) ALLOW_POWER_UP_DONT_CARE lets Quartus replace it by
    that constant: "Stuck at VCC due to stuck port data_in". Verilator keeps every initializer, so
    the benches never see the difference.
That pair stopped the run-time SDRAM phase instrument on hardware: pc9821_sdram_dps's
`output reg fault = 1'b0`, only ever assigned 1'b1, was tied to VCC in every fitted
--dbg-sdram-phase build, so the controller read a fault at power-up and never stepped.

TWO CHECKS.
  (default)      every .sv/.v under src/pc9821, src/memory, src/pcm86, src/soc, src/common and
                 z486_mister.sv. An output-port initializer FAILS when its value is not zero
                 (Quartus powers the register up 0, not to it), or when every assignment to the
                 register (whole-register, non-blocking or blocking) is one and the same constant
                 literal different from it (Quartus folds the register to that constant). A zero
                 output-port initializer on a register with a non-constant writer is counted, not
                 failed (Quartus powers it up 0, as written; an internal register is the explicit
                 form). Precision over recall: an assignment the scanner cannot read as a literal
                 (a parameter, an expression, a part-select, a concatenation target, a port
                 connection) counts as non-constant.
                 An `initial` block that assigns an output-port register is judged the same way
                 as a port initializer (its value is the power-up value it asks for): a nonzero or
                 unreadable value FAILS, and so does a zero on a register only ever assigned one
                 other constant. The `initial` form on a port is not measured either way, and the
                 policy puts every power-up value on an internal register.
  --map-rpt R    a Quartus map report: each "Stuck at VCC/GND due to stuck port data_in" register
                 in those trees whose source declaration has an initializer that disagrees with
                 the tie FAILS (the tie discarded the initializer). Registers with no initializer,
                 or whose initializer is the tied value, are legitimate constant folding and are
                 only counted. Run it on a fit's output_files/z486_mister.map.rpt.

The vendored trees (src/z486: the CPU fork; src/opna: PC88_MiSTer) and sys/ (Template_MiSTer) are
not ours to edit; --vendor scans the first two too and REPORTS their findings without failing.

Usage: python3 tools/check_powerup_init.py [--map-rpt FILE] [--vendor] [--selftest]
       (exit 0 = clean, 1 = a register relies on a discarded initializer)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OURS = ["src/pc9821", "src/memory", "src/pcm86", "src/soc", "src/common"]
OURS_FILES = ["z486_mister.sv"]
VENDOR = ["src/z486", "src/opna"]

KW = {"if", "else", "begin", "end", "case", "endcase", "for", "while", "assign", "default",
      "return", "repeat", "wait", "forever"}


def strip_comments(t: str) -> str:
    t = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), t, flags=re.S)
    return re.sub(r"//[^\n]*", "", t)


def literal(e: str) -> int | None:
    """The value of a constant literal, or None. Handles 0, 1, 'b0/'1/'0, N'bX/N'hX/N'dX,
    N{1'b1} replications of a literal, and a sign-less decimal."""
    e = e.strip()
    while e.startswith("(") and e.endswith(")"):
        e = e[1:-1].strip()
    m = re.fullmatch(r"'([01])", e)
    if m:
        return -1 if m.group(1) == "1" else 0          # all ones / all zeros: width-free
    m = re.fullmatch(r"(\d+)?\s*'\s*[sS]?([bBhHdDoO])\s*([0-9a-fA-F_xXzZ]+)", e)
    if m:
        digits = m.group(3).replace("_", "")
        if re.search(r"[xXzZ]", digits):
            return None
        base = {"b": 2, "h": 16, "d": 10, "o": 8}[m.group(2).lower()]
        return int(digits, base)
    if re.fullmatch(r"\d+", e):
        return int(e)
    m = re.fullmatch(r"\{\s*(\d+)\s*\{\s*(1'b[01])\s*\}\s*\}", e)
    if m:
        return -1 if m.group(2).endswith("1") else 0
    return None


def same(a: int, b: int) -> bool:
    if a == -1 or b == -1:                               # '1 against a sized all-ones value
        other = b if a == -1 else a
        return other == -1 or (other != 0 and (other & (other + 1)) == 0)
    return a == b


def modules(text: str):
    for m in re.finditer(r"\bmodule\s+(\w+)(.*?)\bendmodule\b", text, re.S):
        yield m.group(1), m.group(2)


DECL = re.compile(r"\b(?:reg|logic|bit)\b(?:\s+(?:signed|unsigned))?\s*(?:\[[^\]]*\]\s*)*([^;]*);")


def initialised(body: str, ports_only: bool = False) -> dict[str, tuple[int | None, str]]:
    """name -> (initializer value or None if not a literal, its text), scalar/vector decls only
    (an unpacked array's `= ...` is not a register initializer this check can judge). With
    ports_only, only the ANSI output-port initializers."""
    out = {}
    if ports_only:
        for mm in re.finditer(r"\boutput\s+(?:reg|logic)\b(?:\s+signed)?\s*(?:\[[^\]]*\]\s*)?(\w+)\s*=\s*"
                              r"([^,;)\n]+)", body):
            out[mm.group(1)] = (literal(mm.group(2)), mm.group(2).strip())
        return out
    for m in DECL.finditer(body):
        decl = m.group(1)
        if "(" in decl.split("=")[0]:                    # a function/port header, not a decl
            continue
        # split the declarators at top-level commas
        depth, cur, parts = 0, "", []
        for ch in decl:
            if ch in "({[":
                depth += 1
            elif ch in ")}]":
                depth -= 1
            if ch == "," and depth == 0:
                parts.append(cur)
                cur = ""
            else:
                cur += ch
        parts.append(cur)
        for p in parts:
            mm = re.fullmatch(r"\s*(\w+)\s*=\s*(.+?)\s*", p, re.S)
            if mm and mm.group(1) not in KW:
                out[mm.group(1)] = (literal(mm.group(2)), mm.group(2).strip())
    # output reg x = v in an ANSI port list
    for mm in re.finditer(r"\boutput\s+(?:reg|logic)\b(?:\s+signed)?\s*(?:\[[^\]]*\]\s*)?(\w+)\s*=\s*"
                          r"([^,;)\n]+)", body):
        out[mm.group(1)] = (literal(mm.group(2)), mm.group(2).strip())
    return out


# A statement start: after `;`, `:`, a newline, `begin`, `else` or a closing `)` (an if/case
# condition) - never after `(`, so `if (a <= b)` is a comparison, not a write. Lookbehinds, so a
# match does not consume the `;` the next statement starts after.
_START = r"(?:^|(?<=[;:\n])|(?<=begin)|(?<=else)|(?<=\)))"
ASSIGN = re.compile(_START + r"\s*([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*(<=|=)\s*([^;]+);", re.M)
CONCAT_LHS = re.compile(_START + r"\s*\{([^}]*)\}\s*<?=", re.M)


def writers(body: str, name: str) -> list[int | None]:
    """Every value assigned to `name` outside its declaration: an int literal, or None for a
    non-constant / partial / unreadable write."""
    vals = []
    for m in ASSIGN.finditer(body):
        if m.group(1) != name:
            continue
        pre = body[max(0, m.start(1) - 40):m.start(1)]
        if re.search(r"\b(reg|logic|bit|wire|localparam|parameter|integer|genvar)\b[^;]*$", pre):
            continue                                     # the declaration itself
        if re.search(r"\bassign\s*$", pre) or re.search(r"\bfor\s*\([^)]*$", pre):
            vals.append(None)
            continue
        if m.group(2):                                   # a bit/part select: partial write
            vals.append(None)
            continue
        vals.append(literal(m.group(4)))
    for m in CONCAT_LHS.finditer(body):
        if re.search(r"\b%s\b" % re.escape(name), m.group(1)):
            vals.append(None)
    # a module port connection or a task output also writes it; be conservative
    if re.search(r"\.\w+\s*\(\s*%s\s*\)" % re.escape(name), body):
        vals.append(None)
    return vals


def _balanced(t: str, i: int) -> int:
    """The index just past the bracket group opening at t[i]."""
    depth = 0
    for j in range(i, len(t)):
        if t[j] == "(":
            depth += 1
        elif t[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
    return len(t)


def output_regs(body: str) -> set[str]:
    """The module's output ports that are registers: ANSI `output reg|logic [..] a, b` (a bare
    name after a comma continues the previous declaration) and the non-ANSI body forms
    `output reg x;` and `output x; ... reg x;`."""
    out: set[str] = set()
    i = 0
    m = re.match(r"\s*(?:import[^;]*;\s*)*", body)
    i = m.end() if m else 0
    if body[i:i + 1] == "#":
        i = body.index("(", i)
        i = _balanced(body, i)
    while i < len(body) and body[i].isspace():
        i += 1
    if body[i:i + 1] == "(":
        hdr = body[i + 1:_balanced(body, i) - 1]
        depth, cur, items = 0, "", []
        for ch in hdr:
            if ch in "({[":
                depth += 1
            elif ch in ")}]":
                depth -= 1
            if ch == "," and depth == 0:
                items.append(cur)
                cur = ""
            else:
                cur += ch
        items.append(cur)
        is_oreg = False
        for it in items:
            it = re.sub(r"\(\*.*?\*\)", " ", it).split("=")[0].strip()
            mm = re.match(r"(input|output|inout)\b(.*)", it, re.S)
            if mm:
                is_oreg = mm.group(1) == "output" and re.search(r"\b(reg|logic)\b", mm.group(2)) is not None
            nm = re.search(r"(\w+)\s*(?:\[[^\]]*\]\s*)*$", it)
            if is_oreg and nm:
                out.add(nm.group(1))
    plain_out: set[str] = set()
    for mm in re.finditer(r"\boutput\b([^;()]*);", body):
        decl = re.sub(r"\[[^\]]*\]", " ", mm.group(1))
        names = {n for n in re.findall(r"\b([A-Za-z_]\w*)\b", decl)
                 if n not in {"reg", "logic", "wire", "signed", "unsigned"}}
        (out if re.search(r"\b(reg|logic)\b", decl) else plain_out).update(names)
    for mm in DECL.finditer(body):
        for n in re.findall(r"(?:^|,)\s*([A-Za-z_]\w*)", mm.group(1)):
            if n in plain_out:
                out.add(n)
    return out


def initial_bodies(body: str) -> list[str]:
    """The text of every `initial` block: a begin..end group (nested) or one statement."""
    out = []
    for m in re.finditer(r"\binitial\b", body):
        rest = body[m.end():]
        b = re.match(r"\s*begin\b", rest)
        if not b:
            out.append(rest[:rest.find(";") + 1])
            continue
        depth = 0
        for t in re.finditer(r"\b(begin|end)\b", rest):
            depth += 1 if t.group(1) == "begin" else -1
            if depth == 0:
                out.append(rest[:t.end()])
                break
    return out


def initial_port_values(body: str) -> dict[str, tuple[int | None, str]]:
    """output-port register -> (value an initial block gives it, or None if not a whole-register
    literal, the text)."""
    ports = output_regs(body)
    got = {}
    for ib in initial_bodies(body):
        for m in re.finditer(r"(?<![\w.$])([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*<?=\s*([^;]+);", ib):
            if m.group(1) in ports:
                v = None if m.group(2) else literal(m.group(3))
                got[m.group(1)] = (v, m.group(3).strip())
    return got


def scan_source(paths: list[Path], tally: list | None = None) -> list[str]:
    bad = []
    for f in paths:
        text = strip_comments(f.read_text(errors="replace"))
        rel = f.relative_to(ROOT) if f.is_relative_to(ROOT) else f
        for mod, body in modules(text):
            for name, (init, itext) in initialised(body, ports_only=True).items():
                w = writers(body, name)
                const = bool(w) and all(v is not None for v in w) and all(same(v, w[0]) for v in w)
                if init is None or init != 0:
                    bad.append(f"{rel}: {mod}.{name}: output-port initializer {itext} - Quartus "
                               f"ignores it (the register powers up 0); declare an internal reg "
                               f"with the initializer and drive the port from it")
                elif const and not same(w[0], init):
                    bad.append(f"{rel}: {mod}.{name}: output-port initializer {itext} (ignored by "
                               f"Quartus) on a register only ever assigned "
                               f"{w[0] if w[0] != -1 else chr(39) + '1'} - ALLOW_POWER_UP_DONT_CARE "
                               f"ties it to that value; give it a real clear")
                elif tally is not None:
                    tally.append(f"{rel}: {mod}.{name}")
            for name, (init, itext) in initial_port_values(body).items():
                w = [v for v in writers(body, name)]
                # the initial block's own write is one of writers(); judge the others
                w.remove(init) if init in w else None
                const = bool(w) and all(v is not None for v in w) and all(same(v, w[0]) for v in w)
                if init is None or init != 0:
                    bad.append(f"{rel}: {mod}.{name}: output port given {itext} in an initial "
                               f"block - a power-up value lives on an internal register; declare "
                               f"`reg r = {itext};` and drive the port from it")
                elif const and not same(w[0], init):
                    bad.append(f"{rel}: {mod}.{name}: output port given {itext} in an initial "
                               f"block on a register only ever assigned "
                               f"{w[0] if w[0] != -1 else chr(39) + '1'} - give it an internal "
                               f"register and a real clear")
                elif tally is not None:
                    tally.append(f"{rel}: {mod}.{name} (initial)")
    return bad


def tree_files(dirs: list[str], files: list[str]) -> list[Path]:
    out = []
    for d in dirs:
        out += sorted((ROOT / d).rglob("*.sv")) + sorted((ROOT / d).rglob("*.v"))
    out += [ROOT / f for f in files if (ROOT / f).exists()]
    return out


def mod_index(paths: list[Path]) -> dict[str, tuple[Path, str]]:
    idx = {}
    for f in paths:
        text = strip_comments(f.read_text(errors="replace"))
        for mod, body in modules(text):
            idx.setdefault(mod, (f, body))
    return idx


def scan_map(rpt: str, idx: dict[str, tuple[Path, str]]) -> tuple[list[str], int]:
    """(failures, legitimate ties counted) for the report's data_in-stuck registers."""
    bad, ok = [], 0
    for line in rpt.splitlines():
        if "due to stuck port data_in" not in line:
            continue
        cols = [c.strip() for c in line.split(";")]
        if len(cols) < 3 or not cols[1]:
            continue
        m = re.search(r"Stuck at (VCC|GND)", line)
        if not m:
            continue
        tie = 1 if m.group(1) == "VCC" else 0
        path = cols[1].split("|")
        mod = path[-2].split(":")[0] if len(path) > 1 else "emu"
        if mod == "emu":
            mod = "emu"
        if mod not in idx:
            continue
        leaf = path[-1]
        base = re.sub(r"\[.*", "", leaf)
        base = re.sub(r"~\d+$", "", base)
        if "." in base:
            continue                                     # a state-machine bit or struct field
        f, body = idx[mod]
        init = initialised(body).get(base)
        if init is None or init[0] is None:
            ok += 1
            continue
        bits = re.search(r"\[([\d,.]+)\]$", leaf)
        val = init[0]
        if bits:
            idxs = []
            for part in bits.group(1).split(","):
                if ".." in part:
                    a, b = part.split("..")
                    idxs += range(int(a), int(b) + 1)
                elif part.isdigit():
                    idxs.append(int(part))
            want = [(1 if val == -1 else (val >> i) & 1) for i in idxs]
        else:
            want = [1 if val == -1 else (val & 1)]
        if all(w == tie for w in want):
            ok += 1
        else:
            bad.append(f"{f.relative_to(ROOT)}: {cols[1]}: initialised to {init[1]} but Quartus tied "
                       f"it to {m.group(1)} (stuck port data_in): the initializer was discarded")
    return bad, ok


SELFTEST_OLD_DPS = """
module dps(input wire clk, input wire go, output reg fault = 1'b0, output reg ack = 1'b0);
  reg seen = 1'b0;
  always @(posedge clk) begin
    if (go != seen) begin seen <= go; ack <= ~ack; end
    else if (go) fault <= 1'b1;
  end
endmodule
"""
SELFTEST_FIXED_DPS = SELFTEST_OLD_DPS.replace(
    "if (go != seen) begin seen <= go;", "if (go != seen) begin seen <= go; fault <= 1'b0;")
SELFTEST_CLEARONLY = """
module c(input wire clk, input wire x, output reg pone = 1'b1, output reg [3:0] armed = 4'hF);
  reg [3:0] keep = 4'h3, mixed = 4'h0;
  reg internal_set = 1'b0;           // set-only but internal: Quartus keeps the initializer
  always @(posedge clk) begin
    if (x) armed <= 4'h0;
    keep <= keep;
    pone <= x;
    if (x) mixed <= 4'h1; else mixed <= 4'h2;
    if (x) internal_set <= 1'b1;
  end
endmodule
"""
SELFTEST_INITIAL = """
module v #(parameter integer N = 2) (
    input  wire       clk,
    input  wire       x,
    output reg        busy,                 // 1 in the initial block: flagged
    output reg  [1:0] st, other,            // other continues the declaration: flagged
    output reg        ok,                   // 0 with a non-constant writer: counted
    output wire       w
);
  output_unused_name_guard u0 (.a(clk));
  reg inner;
  reg [3:0] mem [0:3];
  integer i;
  initial begin
    busy  = 1'b1;
    other = 2'd3;
    inner = 1'b1;
    ok    = 1'b0;
    for (i = 0; i < 4; i = i + 1) mem[i] = 4'h1;
  end
  assign w = inner;
  always @(posedge clk) begin busy <= x; ok <= x; inner <= x; st <= {x, x}; other <= {x, x}; end
endmodule
module nonansi(clk, q, r);
  input clk;
  output q;
  output r;
  reg q;
  reg r;
  initial q = 1'b1;
  always @(posedge clk) begin q <= ~q; r <= ~r; end
endmodule
"""
SELFTEST_MAP = """
; emu:emu|dps:g.d|fault                    ; Stuck at VCC due to stuck port data_in ;
; emu:emu|dps:g.d|ack                      ; Stuck at GND due to stuck port data_in ;
; emu:emu|c:u|mixed[3]                     ; Stuck at GND due to stuck port data_in ;
; emu:emu|c:u|keep[0]                      ; Stuck at VCC due to stuck port data_in ;
"""


def selftest() -> int:
    import tempfile
    fails = 0
    with tempfile.TemporaryDirectory() as td:
        def scan(src: str) -> list[str]:
            p = Path(td) / "t.sv"
            p.write_text(src)
            return scan_source([p])
        if not any("dps.fault" in b for b in scan(SELFTEST_OLD_DPS)):
            print("selftest FAIL: the set-only fault (the 2026-10-29 bug) was not flagged"); fails += 1
        if scan(SELFTEST_FIXED_DPS):
            print("selftest FAIL: a fault cleared at the accept was flagged"); fails += 1
        got = scan(SELFTEST_CLEARONLY)
        if not any("c.armed" in b for b in got):
            print("selftest FAIL: a nonzero (and clear-only) port initializer was not flagged"); fails += 1
        if not any("c.pone" in b for b in got):
            print("selftest FAIL: a nonzero port initializer was not flagged"); fails += 1
        if any("keep" in b or "mixed" in b or "internal_set" in b for b in got):
            print("selftest FAIL: an internal register was flagged"); fails += 1
        got = scan(SELFTEST_INITIAL)
        for want in ("v.busy", "v.other", "nonansi.q"):
            if not any(want + ":" in b and "initial" in b for b in got):
                print(f"selftest FAIL: an initial block's power-up value on output port {want} "
                      f"was not flagged"); fails += 1
        if any(n in b for b in got for n in ("v.inner", "v.ok", "v.st", "v.mem", "nonansi.r")):
            print(f"selftest FAIL: an internal register or a zero/unset port was flagged: {got}")
            fails += 1
        p1, p2 = Path(td) / "a.sv", Path(td) / "b.sv"
        p1.write_text(SELFTEST_OLD_DPS)
        p2.write_text(SELFTEST_CLEARONLY)
        idx = {}
        for p in (p1, p2):
            for mod, body in modules(strip_comments(p.read_text())):
                idx[mod] = (p, body)
        global ROOT
        root, ROOT = ROOT, Path(td)
        try:
            bad, ok = scan_map(SELFTEST_MAP, idx)
        finally:
            ROOT = root
        if len(bad) != 1 or "fault" not in bad[0] or ok != 3:
            print(f"selftest FAIL: map cross-check gave {bad} / {ok} legitimate"); fails += 1
    if (literal("8'sh80"), literal("'1"), literal("{4{1'b1}}"), literal("3'd5")) != (0x80, -1, -1, 5):
        print("selftest FAIL: literal parsing"); fails += 1
    print(f"check_powerup_init selftest: {'PASS' if not fails else 'FAIL'}")
    return 1 if fails else 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--map-rpt", type=Path)
    ap.add_argument("--vendor", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    ours = tree_files(OURS, OURS_FILES)
    tally: list[str] = []
    bad = scan_source(ours, tally)
    for b in bad:
        print("FAIL:", b)
    msg = (f"{len(ours)} source files; {len(tally)} zero output-port initializer(s) on registers "
           f"with a non-constant writer (power up 0, as written)")
    if a.map_rpt:
        mbad, ok = scan_map(a.map_rpt.read_text(errors="replace"), mod_index(ours))
        for b in mbad:
            print("FAIL:", b)
        bad += mbad
        msg += f"; {a.map_rpt.name}: {ok} data_in ties agree with their initializer (or have none)"
    if a.vendor:
        vend = tree_files(VENDOR, [])
        vbad = scan_source(vend)
        if a.map_rpt:
            vbad += scan_map(a.map_rpt.read_text(errors="replace"), mod_index(vend))[0]
        for b in vbad:
            print("VENDOR (report to the fork/vendor, do not edit):", b)
        msg += f"; vendored: {len(vbad)} finding(s) in {len(vend)} files"
    print(f"POWER-UP INIT CHECK: {'PASS' if not bad else 'FAIL'} ({msg})")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

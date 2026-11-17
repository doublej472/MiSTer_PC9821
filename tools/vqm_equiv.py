#!/usr/bin/env python3
"""Post-map netlist equivalence: what Quartus BUILT, not what Verilator simulates.

A rewrite proven value-identical in RTL (tests/equiv, the fuses) can still be
synthesized wrong: fork b980746's split launch decision black-screened the core
on hardware while every simulation passed, because Quartus 17.0 Analysis &
Synthesis built cache_unit's `route[1] || (class_r != Z486_CACHE_CACHEABLE)` as
`... != Z486_CACHE_NO_ALLOC` (fork 1f78790). This tool reads Quartus VQM
netlists (`quartus_cdb <rev> --vqm=<file>` after quartus_map) and proves, with
yosys SAT, that two netlists compute the same thing:

  regs A.vqm B.vqm --filter SUB [--rpt A.map.rpt] [--each]
      every dffeas whose instance name contains SUB and exists in both: its
      next state (d/ena/sclr/sload/asdata) as a function of every register,
      RAM/DSP output and top-level input (the same net name is the same free
      variable on both sides), its asynchronous controls (clrn/prn/aload, compared
      as functions too) and its power_up value. Registers of an FSM Quartus
      re-encoded are constrained to the encodings map.rpt lists - Quartus may
      assume those, nothing else; the tool prints how many tables it read and
      how many it applied. --each proves register by register and names the failures.
      A filter matching no common register exits 2 (nothing proved); a register
      in only one netlist is DIFFERENT unless --allow-missing is given.
  nets A.vqm B.vqm NETA=NETB[&COND] ...
      the named nets equal (optionally only where COND is 1; COND in A).
  --selftest
      a planted LUT-mask defect must be caught and the unmodified pair proved.

Cell semantics follow Intel's simulation models in quartus/eda/sim_lib (Quartus 17.0):

  * cyclonev_atoms.v, module cyclonev_lcell_comb: f0..f3 are lut4 over lut_mask's four
    16-bit quarters, f1/f3 taking datag in place of datac in extended-LUT mode
    (`f2_input3`); combout is the 6-LUT mask[{f,e,d,c,b,a}], or in extended mode
    dataf ? (datae ? f3 : f2) : (datae ? f1 : f0); the adder's second input is sharein
    under shared_arith, else !lut4(f2 quarter, a, b, c, dataf); sumout = cin ^ f0 ^ that,
    cout its majority, shareout = f2. The model gives the cell's inputs no pull (plain
    `buf`), so an input the VQM leaves unconnected is taken as 0 here; Quartus leaves an
    input unconnected only when the mask does not depend on it (cin is written `gnd`).
  * altera_primitives.v, module dffeas: ena over sclr over sload (sclr_over_ena "false",
    the default; a cell that sets it is refused); unconnected aload/sclr/sload/asdata are
    tri0 and unconnected clrn/prn/ena tri1, which are the defaults used here.

Named comb nets are NOT comparable between two syntheses (Quartus reuses names for
partial terms); registers, (* keep *) wires and top-level ports are.
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys
import tempfile

# The emitter recurses once per combinational level (net -> cell -> net); a deep cone or a
# long carry chain must not die at Python's default limit of 1000.
sys.setrecursionlimit(max(sys.getrecursionlimit(), 200_000))

CELL_RE = re.compile(r'^(cyclonev_\w+|dffeas)\s+(\\\S+\s|\S+)\s*\(')


def norm(s):
    s = s.strip()
    return s[1:].strip() if s.startswith('\\') else s


def parse(path):
    """VQM -> (cells {inst: [type, {port: net}, {param: value}]}, assigns {net: spec})."""
    cells, assigns, cur = {}, {}, None
    with open(path) as f:
        for line in f:
            if cur is not None and line.startswith(('defparam ', 'cyclonev_', 'dffeas ', 'assign ')):
                cur = None
            if cur is not None:
                st = line.strip()
                if st.startswith(');'):
                    cur = None
                    continue
                m = re.match(r'\.(\w+)\((.*)\)\)?;?,?\s*$', st)
                if m:
                    net = m.group(2).strip()
                    if net.endswith(')'):
                        net = net[:-1].strip()
                    cur[1][m.group(1)] = norm(net) if net else None
                    if st.endswith('));'):
                        cur = None
                continue
            if line.startswith('assign '):
                m = re.match(r'assign\s+(\\\S+\s|\S+)\s*=\s*(~?)\s*(\\\S+\s|[^;]+?)\s*;', line)
                if m:
                    lhs, inv, rhs = norm(m.group(1)), m.group(2) == '~', m.group(3).strip()
                    if rhs == "1'b0":
                        assigns[lhs] = ('c', 0)
                    elif rhs == "1'b1":
                        assigns[lhs] = ('c', 1)
                    else:
                        assigns[lhs] = ('n', inv, norm(rhs))
                continue
            if line.startswith('defparam '):
                m = re.match(r'defparam\s+(\\\S+\s|\S+)\s*\.(\w+)\s*=\s*(.*);', line)
                if m and norm(m.group(1)) in cells:
                    cells[norm(m.group(1))][2][m.group(2)] = m.group(3).strip().strip('"')
                continue
            m = CELL_RE.match(line)
            if m:
                cur = [m.group(1), {}, {}]
                cells[norm(m.group(2))] = cur
    return cells, assigns


def fsm_constraints(rpt):
    """map.rpt 'State Machine' tables -> [(column register nets, encoding rows)].

    The table's hierarchy is `|sys_top|emu:emu|...|<inst>|<state>` and its columns are the
    one-hot register names; the VQM names the same registers with the same entity:instance
    path minus the top (`emu:emu|...|<state>.<STATE>`), so only the first component is cut."""
    out = []
    if not rpt:
        return out
    if not os.path.exists(rpt):
        raise SystemExit(f"vqm_equiv: --rpt {rpt}: no such file")
    lines = open(rpt, errors='replace').read().splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r'^; State Machine - \|[^|]+\|(\S+)\s*;', lines[i])
        if m:
            base = m.group(1).rsplit('|', 1)[0]
            cols = [c.strip() for c in lines[i + 2].strip().strip(';').split(';')][1:]
            rows, j, ok = [], i + 4, True
            while j < len(lines) and lines[j].startswith(';'):
                f = [c.strip() for c in lines[j].strip().strip(';').split(';')]
                if len(f) - 1 != len(cols) or any(x not in ('0', '1') for x in f[1:]):
                    ok = False
                else:
                    rows.append([int(x) for x in f[1:]])
                j += 1
            if ok and rows:
                out.append(([base + '|' + c for c in cols], rows))
            else:
                print(f"vqm_equiv: WARNING: State Machine table {m.group(1)} in {rpt} is not "
                      f"0/1 rows over its columns; not applied")
            i = j
        i += 1
    return out


class Emitter:
    """Writes one netlist's cones as Verilog over shared leaf inputs."""

    def __init__(self, tag, cells, assigns, leaves, lines):
        self.tag, self.c, self.a, self.leaves, self.lines = tag, cells, assigns, leaves, lines
        self.drv, self.done, self.busy = {}, set(), set()
        for inst, (t, ports, _) in cells.items():
            if t == 'cyclonev_lcell_comb':
                for p in ('combout', 'sumout', 'cout', 'shareout'):
                    if ports.get(p):
                        self.drv[ports[p]] = (inst, p)

    def ident(self, inst):
        h = hashlib.blake2b(inst.encode(), digest_size=5).hexdigest()
        return f"{self.tag}_{h}"

    def net(self, n):
        if n is None or n == 'gnd':
            return "1'b0"
        if n == 'vcc':
            return "1'b1"
        if n in self.a:
            a = self.a[n]
            if a[0] == 'c':
                return "1'b1" if a[1] else "1'b0"
            v = self.net(a[2])
            return f"(~{v})" if a[1] else v
        if n in self.drv:
            inst, p = self.drv[n]
            self.cell(inst)
            return f"{self.ident(inst)}_{p}"
        if n not in self.leaves:
            self.leaves[n] = f"L{len(self.leaves)}"
        return self.leaves[n]

    def cell(self, inst):
        if inst in self.done:
            return
        if inst in self.busy:
            # a wire used before its declaration: yosys would report an unrelated parse error
            raise SystemExit(f"vqm_equiv: combinational loop through {inst} ({self.tag})")
        self.busy.add(inst)
        self._cell(inst)
        self.busy.discard(inst)
        self.done.add(inst)

    def _cell(self, inst):
        _, ports, prm = self.c[inst]
        g = lambda p: self.net(ports.get(p)) if ports.get(p) else "1'b0"
        a, b, c, d, e, f, gg = [g('data' + x) for x in 'abcdefg']
        mask = prm.get('lut_mask', 'F' * 16).replace("64'h", '')
        ext = prm.get('extended_lut', 'off') == 'on'
        sh = prm.get('shared_arith', 'off') == 'on'
        I, L = self.ident(inst), self.lines
        c3 = gg if ext else c
        L.append(f"wire [63:0] {I}_m = 64'h{mask};")
        L.append(f"wire {I}_f0 = {I}_m[{{4'd0,{d},{c},{b},{a}}}];")
        L.append(f"wire {I}_f1 = {I}_m[16+{{{d},{c3},{b},{a}}}];")
        L.append(f"wire {I}_f2 = {I}_m[32+{{{d},{c},{b},{a}}}];")
        L.append(f"wire {I}_f3 = {I}_m[48+{{{d},{c3},{b},{a}}}];")
        if ext:
            L.append(f"wire {I}_combout = {f} ? ({e} ? {I}_f3 : {I}_f2) : ({e} ? {I}_f1 : {I}_f0);")
        else:
            L.append(f"wire {I}_combout = {I}_m[{{{f},{e},{d},{c},{b},{a}}}];")
        ai2 = g('sharein') if sh else f"(~{I}_m[32+{{{f},{c},{b},{a}}}])"
        cin = g('cin')
        L.append(f"wire {I}_ai2 = {ai2};")
        L.append(f"wire {I}_sumout = {cin} ^ {I}_f0 ^ {I}_ai2;")
        L.append(f"wire {I}_cout = ({cin} & {I}_f0) | ({cin} & {I}_ai2) | ({I}_f0 & {I}_ai2);")
        L.append(f"wire {I}_shareout = {I}_f2;")

    def next_state(self, inst):
        _, ports, prm = self.c[inst]
        if prm.get('sclr_over_ena', 'false') != 'false':
            raise SystemExit(f"vqm_equiv: {inst} sets sclr_over_ena, which this model does not carry")
        g = lambda p, dflt: self.net(ports.get(p)) if ports.get(p) else dflt
        d, ena = g('d', "1'b0"), g('ena', "1'b1")
        sclr, sload, asd, q = g('sclr', "1'b0"), g('sload', "1'b0"), g('asdata', "1'b0"), g('q', "1'b0")
        return f"(({ena}) ? (({sclr}) ? 1'b0 : (({sload}) ? {asd} : {d})) : {q})"

    def async_ctl(self, inst):
        """{clrn, prn, aload, asdata} as one 4-bit value (the unconnected defaults of
        altera_primitives.v's dffeas: clrn/prn tri1, aload/asdata tri0)."""
        _, ports, _ = self.c[inst]
        g = lambda p, dflt: self.net(ports.get(p)) if ports.get(p) else dflt
        clrn, prn = g('clrn', "1'b1"), g('prn', "1'b1")
        aload, asd = g('aload', "1'b0"), g('asdata', "1'b0")
        return f"{{{clrn}, {prn}, {aload}, (({aload}) & {asd})}}"

    @staticmethod
    def has_async_of(cells, inst):
        ports = cells[inst][1]
        return any(ports.get(p) for p in ('clrn', 'prn', 'aload'))


def build_miter(A, B, pairs, rpt=None):
    """pairs: [(label, exprA_fn, exprB_fn)] -> (verilog text, labels, leaves)."""
    leaves, lines = {}, []
    ca, aa = A
    cb, ab = B
    ea, eb = Emitter('A', ca, aa, leaves, lines), Emitter('B', cb, ab, leaves, lines)
    labels = []
    for k, (label, fa, fb) in enumerate(pairs):
        x, y = fa(ea), fb(eb)
        lines.append(f"wire diff{k} = |({x} ^ {y});")
        labels.append(label)
    legal = []
    tables = fsm_constraints(rpt)
    applied = partial = 0
    for cols, rows in tables:
        if not any(col in leaves for col in cols):
            continue
        applied += 1
        partial += not all(col in leaves for col in cols)
        terms = []
        for r in rows:
            lits = [(leaves[col] if bit else f"~{leaves[col]}") for col, bit in zip(cols, r) if col in leaves]
            terms.append("(" + (" & ".join(lits) or "1'b1") + ")")
        legal.append("(" + " | ".join(terms) + ")")
    hdr = "module miter(" + ", ".join(['output trig'] + [f"output tdiff{k}" for k in range(len(pairs))]
                                      + [f"input {v}" for v in leaves.values()]) + ");\n"
    body = "\n".join(lines) + "\n"
    if rpt:
        print(f"vqm_equiv: {len(tables)} FSM encoding tables read from {rpt}, {applied} applied to "
              f"this cone ({partial} over only some of their registers: a projection, so looser)")
    body += "wire legal = " + (" & ".join(legal) if legal else "1'b1") + ";\n"
    body += "assign trig = legal & (" + (" | ".join(f"diff{k}" for k in range(len(pairs))) or "1'b0") + ");\n"
    for k in range(len(pairs)):
        body += f"assign tdiff{k} = legal & diff{k};\n"
    return hdr + body + "endmodule\n", labels, leaves


def sat(miter_text, targets):
    """-> list of bool (True = proved never 1) for each target signal."""
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, 'miter.v')
        open(p, 'w').write(miter_text)
        script = f"read_verilog {p}; proc; opt -fast; " + " ".join(f"sat -prove {t} 0;" for t in targets)
        r = subprocess.run(['yosys', '-q', '-p', script], capture_output=True, text=True)
        out = r.stdout + r.stderr
        res = re.findall(r'SAT proof finished - (no model found: SUCCESS|model found: FAIL)', out)
        if len(res) != len(targets):
            # yosys -q hides the verdict lines; rerun verbosely
            r = subprocess.run(['yosys', '-p', script], capture_output=True, text=True)
            res = re.findall(r'SAT proof finished - (no model found: SUCCESS|model found: FAIL)', r.stdout)
        if len(res) != len(targets):
            raise SystemExit("vqm_equiv: yosys gave no verdict:\n" + (r.stdout + r.stderr)[-2000:])
        return [x.startswith('no model') for x in res]


def cmd_regs(args):
    A, B = parse(args.a), parse(args.b)
    ra = {i for i, c in A[0].items() if c[0] == 'dffeas' and args.filter in i}
    rb = {i for i, c in B[0].items() if c[0] == 'dffeas' and args.filter in i}
    regs = sorted(ra & rb)
    only_a, only_b = sorted(ra - rb), sorted(rb - ra)
    print(f"vqm_equiv: {len(regs)} registers common to both, {len(only_a)} only in A, "
          f"{len(only_b)} only in B")
    # A proof over no registers is `trig = 0` and proves trivially: a filter that matches
    # nothing (a typo) must never read EQUAL.
    if not regs:
        print(f"vqm_equiv: NO REGISTERS match --filter {args.filter!r} in both netlists: "
              f"nothing was proved")
        return 2
    # A register one synthesis has and the other lacks is a difference the miter cannot see
    # (it compares only common registers), so it fails unless the caller accepts it.
    missing = [f"only in A: {r}" for r in only_a] + [f"only in B: {r}" for r in only_b]
    for m in missing[:20]:
        print("  MISSING", m)
    if missing and not getattr(args, 'allow_missing', False):
        print("vqm_equiv: DIFFERENT (register sets differ; --allow-missing proves the common "
              "registers only)")
        return 1
    # power_up is a parameter, not a function: compared as text ("low" when not written,
    # the dffeas default being DONT_CARE, which Quartus writes explicitly).
    pu = [r for r in regs if A[0][r][2].get('power_up') != B[0][r][2].get('power_up')]
    for r in pu[:20]:
        print(f"  POWER_UP differs: {r}: {A[0][r][2].get('power_up')} vs {B[0][r][2].get('power_up')}")
    if pu:
        print(f"vqm_equiv: DIFFERENT ({len(pu)} register(s) with a different power_up)")
        return 1
    pairs = [(r, (lambda e, r=r: e.next_state(r)), (lambda e, r=r: e.next_state(r))) for r in regs]
    # A register's asynchronous controls are compared as functions when either side has one.
    pairs += [(r + " (clrn/prn/aload)", (lambda e, r=r: e.async_ctl(r)),
               (lambda e, r=r: e.async_ctl(r)))
              for r in regs if Emitter.has_async_of(A[0], r) or Emitter.has_async_of(B[0], r)]
    text, labels, leaves = build_miter(A, B, pairs, args.rpt)
    print(f"vqm_equiv: {len(leaves)} free leaves")
    targets = [f"tdiff{k}" for k in range(len(pairs))] if args.each else ['trig']
    ok = sat(text, targets)
    if args.each:
        bad = [labels[k] for k, v in enumerate(ok) if not v]
        for b in bad:
            print("  DIFFERS:", b)
        good = not bad
    else:
        good = ok[0]
    print("vqm_equiv:", "EQUAL" if good else "DIFFERENT")
    return 0 if good else 1


def cmd_nets(args):
    A, B = parse(args.a), parse(args.b)
    # a conditioned pair is (a ^ b) & cond, cond taken in A
    leaves, lines = {}, []
    ea, eb = Emitter('A', *A, leaves, lines), Emitter('B', *B, leaves, lines)
    outs = []
    for k, spec in enumerate(args.pairs):
        cond = None
        if '&' in spec:
            spec, cond = spec.split('&', 1)
        na, nb = (spec.split('=') + [spec])[:2]
        cx = f" & ({ea.net(cond)})" if cond else ""
        lines.append(f"wire diff{k} = (({ea.net(na)}) ^ ({eb.net(nb)})){cx};")
        outs.append(f"diff{k}")
    text = ("module miter(" + ", ".join(['output trig'] + [f"input {v}" for v in leaves.values()]) + ");\n"
            + "\n".join(lines) + f"\nassign trig = {' | '.join(outs)};\nendmodule\n")
    ok = sat(text, ['trig'])[0]
    print("vqm_equiv:", "EQUAL" if ok else "DIFFERENT")
    return 0 if ok else 1


SELFTEST_VQM = r"""
cyclonev_lcell_comb \x~0_I (
	.dataa(\ra ),
	.datab(\rb ),
	.combout(\x~0 ));
defparam \x~0_I .shared_arith = "off";
defparam \x~0_I .extended_lut = "off";
defparam \x~0_I .lut_mask = "MASK";

cyclonev_lcell_comb \s~1_I (
	.datad(\__ALT_INV__ra ),
	.cin(gnd),
	.sumout(\s~1 ),
	.cout(\s~2 ));
defparam \s~1_I .shared_arith = "off";
defparam \s~1_I .extended_lut = "off";
defparam \s~1_I .lut_mask = "00000000000000FF";

dffeas \y~I (
	.clk(\clk ),
	.d(\x~0 ),
	.q(\y ));

dffeas \z~I (
	.clk(\clk ),
	.d(\s~1 ),
	.ena(\rb ),
	.q(\z ));
assign \__ALT_INV__ra  = ~ \ra ;
"""


def _lcell(name, ports, mask, ext="off", shared="off"):
    """One cyclonev_lcell_comb in VQM text (selftest only)."""
    body = ",\n".join(f"\t.{k}({v})" for k, v in ports.items())
    return (f"cyclonev_lcell_comb \\{name}_I (\n{body});\n"
            f"defparam \\{name}_I .shared_arith = \"{shared}\";\n"
            f"defparam \\{name}_I .extended_lut = \"{ext}\";\n"
            f"defparam \\{name}_I .lut_mask = \"{mask}\";\n\n")


def _dff(name, ports, power_up=None):
    body = ",\n".join(f"\t.{k}({v})" for k, v in ports.items())
    pu = f"defparam \\{name}~I .power_up = \"{power_up}\";\n" if power_up else ""
    return f"dffeas \\{name}~I (\n{body});\n{pu}\n"


# A two-state one-hot FSM table in map.rpt's layout (the registers u|st.S0 and u|st.S1).
SELFTEST_RPT = """; State Machine - |top|u|st ;
+-------+-------+-------+
; Name  ; st.S1 ; st.S0 ;
+-------+-------+-------+
; st.S0 ; 0     ; 1     ;
; st.S1 ; 1     ; 0     ;
+-------+-------+-------+
"""


def _selftest_cells(td):
    """The cell-semantics plants: each (label, A text, B text, rpt or None, want rc)."""
    rf = "\\ra ", "\\rb ", "\\rc ", "\\rg ", "\\re ", "\\rf "
    ra, rb, rc, rg, re_, rf_ = rf
    cases = []
    # Extended LUT: with extended_lut on, f1 reads datag in place of datac. Quarter 1 = F0F0
    # (input3) and the rest 0 make combout = !f & e & input3, which a plain 6-LUT with the
    # same mask computes from datac. A wired (c=rc, g=rg) equals B wired (c=rg); a model
    # that fed f1 datac would see rc and fail the equal pair.
    m = "00000000F0F00000"
    a = _lcell("x", dict(dataa=ra, datab=rb, datac=rc, datag=rg, datae=re_, dataf=rf_, combout="\\x "), m, ext="on")
    b = _lcell("x", dict(dataa=ra, datab=rb, datac=rg, datae=re_, dataf=rf_, combout="\\x "), m)
    b2 = _lcell("x", dict(dataa=ra, datab=rb, datac=rc, datae=re_, dataf=rf_, combout="\\x "), m)
    reg = _dff("y", dict(clk="\\clk ", d="\\x ", q="\\y "))
    cases += [("extended LUT == plain LUT on datag", a + reg, b + reg, None, 0),
              ("extended LUT != plain LUT on datac", a + reg, b2 + reg, None, 1)]
    # Shared arithmetic: sumout = cin ^ f0 ^ sharein, against the unshared form whose adder
    # input is !lut4(quarter 2, a, b, c, dataf). P's shareout (its quarter 2) is AND(a, b);
    # the unshared cell's quarter 2 is its complement 7777, so both sums are cin ^ f0 ^ ab.
    p_ = _lcell("p", dict(dataa=ra, datab=rb, shareout="\\p~sh "), "0000888800000000")
    qa = _lcell("q", dict(dataa=ra, datab=rb, datad=rc, cin="gnd", sharein="\\p~sh ",
                          sumout="\\q "), "0000000000000F0F", shared="on")
    qb = _lcell("q", dict(dataa=ra, datab=rb, datad=rc, cin="gnd", sumout="\\q "),
                "0000777700000F0F")
    qb2 = _lcell("q", dict(dataa=ra, datab=rb, datad=rc, cin="gnd", sumout="\\q "),
                 "0000888800000F0F")
    reg = _dff("z", dict(clk="\\clk ", d="\\q ", q="\\z "))
    cases += [("shared-arith sum == the unshared sum", p_ + qa + reg, qb + reg, None, 0),
              ("shared-arith sum != an uncomplemented adder input", p_ + qa + reg, qb2 + reg, None, 1)]
    # Asynchronous controls and power-up: invisible to the next-state function, so each is
    # compared on its own.
    plain = _dff("w", dict(clk="\\clk ", d=ra, q="\\w "))
    clr = _dff("w", dict(clk="\\clk ", d=ra, clrn=rb, q="\\w "))
    high = _dff("w", dict(clk="\\clk ", d=ra, q="\\w "), power_up="high")
    cases += [("a register that gained an asynchronous clear", plain, clr, None, 1),
              ("the same asynchronous clear on both sides", clr, clr, None, 0),
              ("a register whose power_up differs", plain, high, None, 1)]
    # FSM encodings from map.rpt: r = S0 & S1 is 0 on every legal one-hot code, so it equals
    # a register fed 0 only when the table is applied.
    st = (_dff("u|st.S0", dict(clk="\\clk ", d=ra, q="\\u|st.S0 ")) +
          _dff("u|st.S1", dict(clk="\\clk ", d=rb, q="\\u|st.S1 ")))
    both = _lcell("r~0", dict(dataa="\\u|st.S0 ", datab="\\u|st.S1 ", combout="\\r~0 "), "8888888888888888")
    ra_ = st + both + _dff("r", dict(clk="\\clk ", d="\\r~0 ", q="\\r "))
    rb_ = st + _dff("r", dict(clk="\\clk ", d="gnd", q="\\r "))
    rpt = os.path.join(td, "map.rpt")
    with open(rpt, "w") as f:
        f.write(SELFTEST_RPT)
    cases += [("an FSM-only-reachable difference, with the map.rpt encodings", ra_, rb_, rpt, 0),
              ("the same difference with no encodings", ra_, rb_, None, 1)]
    return cases


def selftest():
    with tempfile.TemporaryDirectory() as td:
        good = os.path.join(td, 'a.vqm')
        same = os.path.join(td, 'b.vqm')
        bad = os.path.join(td, 'c.vqm')
        # AND of ra, rb: minterm 3 of a 2-input LUT replicated over the unused inputs
        andmask = format(int('8888888888888888', 16), '016X')
        open(good, 'w').write(SELFTEST_VQM.replace('MASK', andmask))
        open(same, 'w').write(SELFTEST_VQM.replace('MASK', andmask))
        open(bad, 'w').write(SELFTEST_VQM.replace('MASK', '6666666666666666'))   # XOR
        ns = argparse.Namespace
        r1 = cmd_regs(ns(a=good, b=same, filter='', rpt=None, each=True))
        r2 = cmd_regs(ns(a=good, b=bad, filter='', rpt=None, each=True))
        if r1 != 0 or r2 != 1:
            print("vqm_equiv selftest: FAIL (equal pair", r1, ", planted defect", r2, ")")
            return 1
        # a filter that matches nothing must not read EQUAL
        r3 = cmd_regs(ns(a=good, b=same, filter='no_such_reg', rpt=None, each=False))
        # a register the other netlist lacks is a difference, unless explicitly allowed
        drop = os.path.join(td, 'd.vqm')
        text = SELFTEST_VQM.replace('MASK', andmask)
        cut = text[:text.index('dffeas \\z~I')] + text[text.index('assign '):]
        open(drop, 'w').write(cut)
        r4 = cmd_regs(ns(a=good, b=drop, filter='', rpt=None, each=False, allow_missing=False))
        r5 = cmd_regs(ns(a=good, b=drop, filter='', rpt=None, each=False, allow_missing=True))
        if r3 != 2 or r4 != 1 or r5 != 0:
            print("vqm_equiv selftest: FAIL (empty filter", r3, ", missing register", r4,
                  ", allowed", r5, ")")
            return 1
        fails = []
        for label, ta, tb, rpt, want in _selftest_cells(td):
            pa, pb = os.path.join(td, 'ca.vqm'), os.path.join(td, 'cb.vqm')
            open(pa, 'w').write(ta)
            open(pb, 'w').write(tb)
            got = cmd_regs(ns(a=pa, b=pb, filter='', rpt=rpt, each=False, allow_missing=False))
            if got != want:
                fails.append(f"{label}: rc {got}, want {want}")
        # a combinational loop is named, not left to yosys as an unrelated parse error
        loop = (_lcell("l1", dict(dataa="\\l2 ", combout="\\l1 "), "5555555555555555") +
                _lcell("l2", dict(dataa="\\l1 ", combout="\\l2 "), "5555555555555555") +
                _dff("k", dict(clk="\\clk ", d="\\l1 ", q="\\k ")))
        pl = os.path.join(td, 'loop.vqm')
        open(pl, 'w').write(loop)
        try:
            cmd_regs(ns(a=pl, b=pl, filter='', rpt=None, each=False, allow_missing=False))
            fails.append("a combinational loop was not reported")
        except SystemExit as e:
            if "combinational loop" not in str(e):
                fails.append(f"a combinational loop gave {e}")
        if fails:
            print("vqm_equiv selftest: FAIL")
            for f in fails:
                print("  -", f)
            return 1
    print("vqm_equiv selftest: PASS")
    return 0


def main():
    if '--selftest' in sys.argv:
        return selftest()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('regs')
    r.add_argument('a'); r.add_argument('b')
    r.add_argument('--filter', default='')
    r.add_argument('--rpt', help='map.rpt of A (FSM encodings)')
    r.add_argument('--each', action='store_true')
    r.add_argument('--allow-missing', action='store_true',
                   help='prove the common registers even when one netlist has registers the other lacks')
    n = sub.add_parser('nets')
    n.add_argument('a'); n.add_argument('b'); n.add_argument('pairs', nargs='+')
    args = ap.parse_args()
    return cmd_regs(args) if args.cmd == 'regs' else cmd_nets(args)


if __name__ == '__main__':
    sys.exit(main())

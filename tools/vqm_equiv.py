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
      variable on both sides). Registers of an FSM Quartus re-encoded are
      constrained to the encodings map.rpt lists - Quartus may assume those,
      nothing else. --each proves register by register and names the failures.
  nets A.vqm B.vqm NETA=NETB[&COND] ...
      the named nets equal (optionally only where COND is 1; COND in A).
  --selftest
      a planted LUT-mask defect must be caught and the unmodified pair proved.

Cell semantics follow Intel's cyclonev_atoms.v (cyclonev_lcell_comb: 6-LUT,
extended-LUT mode with datag, arithmetic sumout/cout, shared arithmetic) and
altera_primitives.v (dffeas: ena over sclr over sload). Named comb nets are NOT
comparable between two syntheses (Quartus reuses names for partial terms);
registers, (* keep *) wires and top-level ports are.
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys
import tempfile

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
    """map.rpt 'State Machine' tables -> [(column register nets, encoding rows)]."""
    out = []
    if not rpt or not os.path.exists(rpt):
        return out
    lines = open(rpt, errors='replace').read().splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r'^; State Machine - \|[^|]+\|(\S+)\s*;', lines[i])
        if m:
            base = m.group(1).rsplit('|', 1)[0]
            cols = [c.strip() for c in lines[i + 2].strip().strip(';').split(';')][1:]
            rows, j = [], i + 4
            while j < len(lines) and lines[j].startswith(';'):
                f = [c.strip() for c in lines[j].strip().strip(';').split(';')]
                rows.append([int(x) for x in f[1:]])
                j += 1
            out.append(([base + '|' + c for c in cols], rows))
            i = j
        i += 1
    return out


class Emitter:
    """Writes one netlist's cones as Verilog over shared leaf inputs."""

    def __init__(self, tag, cells, assigns, leaves, lines):
        self.tag, self.c, self.a, self.leaves, self.lines = tag, cells, assigns, leaves, lines
        self.drv, self.done = {}, set()
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
        self.done.add(inst)
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
        _, ports, _ = self.c[inst]
        g = lambda p, dflt: self.net(ports.get(p)) if ports.get(p) else dflt
        d, ena = g('d', "1'b0"), g('ena', "1'b1")
        sclr, sload, asd, q = g('sclr', "1'b0"), g('sload', "1'b0"), g('asdata', "1'b0"), g('q', "1'b0")
        return f"(({ena}) ? (({sclr}) ? 1'b0 : (({sload}) ? {asd} : {d})) : {q})"


def build_miter(A, B, pairs, rpt=None):
    """pairs: [(label, exprA_fn, exprB_fn)] -> (verilog text, labels, leaves)."""
    leaves, lines = {}, []
    ca, aa = A
    cb, ab = B
    ea, eb = Emitter('A', ca, aa, leaves, lines), Emitter('B', cb, ab, leaves, lines)
    labels = []
    for k, (label, fa, fb) in enumerate(pairs):
        x, y = fa(ea), fb(eb)
        lines.append(f"wire diff{k} = {x} ^ {y};")
        labels.append(label)
    legal = []
    for cols, rows in fsm_constraints(rpt):
        if not any(col in leaves for col in cols):
            continue
        terms = []
        for r in rows:
            lits = [(leaves[col] if bit else f"~{leaves[col]}") for col, bit in zip(cols, r) if col in leaves]
            terms.append("(" + (" & ".join(lits) or "1'b1") + ")")
        legal.append("(" + " | ".join(terms) + ")")
    hdr = "module miter(" + ", ".join(['output trig'] + [f"output tdiff{k}" for k in range(len(pairs))]
                                      + [f"input {v}" for v in leaves.values()]) + ");\n"
    body = "\n".join(lines) + "\n"
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
    regs = sorted(i for i, c in A[0].items() if c[0] == 'dffeas' and args.filter in i
                  and i in B[0] and B[0][i][0] == 'dffeas')
    only = sorted(i for i, c in A[0].items() if c[0] == 'dffeas' and args.filter in i and i not in B[0])
    print(f"vqm_equiv: {len(regs)} registers common to both, {len(only)} only in A")
    pairs = [(r, (lambda e, r=r: e.next_state(r)), (lambda e, r=r: e.next_state(r))) for r in regs]
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
    n = sub.add_parser('nets')
    n.add_argument('a'); n.add_argument('b'); n.add_argument('pairs', nargs='+')
    args = ap.parse_args()
    return cmd_regs(args) if args.cmd == 'regs' else cmd_nets(args)


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Every instantiation's port list, against the module it names.

WHY THIS EXISTS. A bench instantiates the module it tests DIRECTLY and wires every port
itself. Nothing in this tree instantiates the DUT's parent, so a port that is connected in
the module but forgotten at the instantiation is INVISIBLE to every bench, to the whole
gate, and to a successful fit. It shows up only on hardware, as a feature that silently
does nothing.

That is not hypothetical here: `pc9821_memory_subsystem`'s nine EGC register inputs are
declared, produced by the iobus, carried on wires in pc9821_system.sv - and never connected
to the instance. The EGC's registers have therefore never been driven. Verilator's
UNUSEDSIGNAL and a code review both recorded it; nothing acted.

AN UNCONNECTED OUTPUT IS NORMAL; AN UNCONNECTED INPUT IS A DEFECT. An input nobody drives
is undriven: synthesis usually ties it low while simulation reads it as x, so a bench and
the card disagree about a signal that is supposed to carry state. So this check reports the
two separately and only the second is an error. An unconnected output is reported as
information, because a monitor port deliberately left open is a design decision - the top
leaves pc9821_system's `software_reset` open on purpose, and the comment above that
instantiation says why.

WHAT THIS CANNOT SEE, stated so nobody over-reads it:
  - a port connected to the WRONG signal. `.foo(bar)` where bar is not foo's meaning is
    invisible to a name-matching check, and is left to review.
  - a non-ANSI module header, which cannot be parsed mechanically. Those are reported as
    UNRESOLVED, never silently skipped.
  - anything inside src/z486/, the pinned submodule.
Expected values are read out of the RTL itself, so this cannot drift from the design - it
compares a design against ITSELF, which is the only thing a port-list check can do.

THE SAME DEFECT, ONE LEVEL UP: A DROPPED PARAMETER. A compile-time knob travels down the
hierarchy as a `parameter` (AGENTS.md: "it travels down as a `parameter`, and the unselected
branch const-folds away"). When a parent declares a parameter (or a localparam) and a child it
instantiates declares a parameter of the SAME NAME, the instance must say what the child gets:
`.NAME(NAME)` to pass it through, or `.NAME(<value>)` to pin it on purpose. An instance that says
nothing silently gives the child its DEFAULT, and the default of every build knob here is "off".
That happened: pc9821_system declared MPU_EN, its pc9821_iobus instance never passed it, so the
iobus's device_select decoded the MPU-PC98II's ports with MPU_EN 0 in every build, including the
`base` preset that carries the card, and the card was unreachable (introduced in f631642e, and
widened when the device select moved inside the iobus). A unit bench that instantiates the child
with the parameter set cannot see it, and neither can the port check above. So every
same-name parameter must appear in the instance's `#(...)`; an intentionally different value is
written there explicitly, which also documents it. `--selftest` plants each form.
  Not seen: a parameter passed under a DIFFERENT name (`.SYS_CLOCK_HZ(SYS_FREQ)` is right, a
  wrong one is review's), positional `#(8)` overrides (reported UNRESOLVED), and anything whose
  PARENT is inside src/z486/ (the vendored CPU; its modules are still read as children).

Usage: tools/check_port_lists.py [root] [--all | FILE ...]
       tools/check_port_lists.py --selftest
       (no argument = every file under src/ plus the top level, which is what --all
        spells out; a named FILE narrows it)
Exit 0 when no input is unconnected and no same-name parameter is dropped; 1 otherwise,
naming module, instance and port or parameter.
"""
import os, re, sys, pathlib

def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    s = re.sub(r'//[^\n]*', ' ', s)
    return re.sub(r'"(\\.|[^"\\])*"', '""', s)

def split_top(body):
    out, d, cur = [], 0, ''
    for ch in body:
        if ch in '([{': d += 1
        elif ch in ')]}': d -= 1
        if ch == ',' and d == 0: out.append(cur); cur = ''
        else: cur += ch
    out.append(cur); return out

def name_of(decl):
    d = re.sub(r'\[[^\]]*\]', ' ', decl.split('=')[0])
    t = re.findall(r'[A-Za-z_]\w*', d)
    return t[-1] if t else None

def port_dirs(decl):
    """(name, direction) for an ANSI port declaration."""
    n = name_of(decl)
    if not n: return None
    d = decl.lower()
    for k in ('input', 'output', 'inout'):
        if re.search(r'\b' + k + r'\b', d):
            return (n, k)
    return None

# DIRECTORIES A MODULE MUST NEVER BE READ FROM. `module_ports` finds a module by NAME, and it
# searched root.rglob('*.sv') - which walks the fit's scratch tree and every lane checkout. On this
# machine those ALWAYS exist, and rglob reaches .build/quartus FIRST, so the checker parsed a
# SNAPSHOT of the module taken at some earlier build instead of the source it was being asked
# about. It then reported six ports as "connected but not a port" that were declared in the file it
# had been given, and the same mechanism could equally have produced a false PASS when a stale copy
# happened to declare more. A checker that can read a different file than the one under test is not
# checking the tree; scope it to the source.
# A `reference/` directory (third-party sources dropped in locally for comparison, e.g. other
# cores' SDRAM controllers) has module names that collide with ours (`sdram`): never the tree.
SKIP_DIRS = ('.build', '.worktrees', 'lanes', 'output_files', 'db', 'incremental_db', 'mister_deploy', '.git',
             '__pycache__', 'build', 'reference')


def in_source_tree(path: pathlib.Path, root: pathlib.Path) -> bool:
    try:
        rel = path.relative_to(root)
    except ValueError:
        return False
    return not any(part in SKIP_DIRS for part in rel.parts)


def source_files(root):
    """Every *.sv under root, pruning SKIP_DIRS during the walk (rglob would descend into every
    lane checkout and build tree first, which costs minutes)."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for fn in sorted(filenames):
            if fn.endswith('.sv'):
                yield pathlib.Path(dirpath) / fn


def module_ports(root, name):
    for f in source_files(root):
        if not in_source_tree(f, root):
            continue
        try: src = strip_comments(f.read_text(errors='ignore'))
        except Exception: continue
        for m in re.finditer(r'\bmodule\s+' + re.escape(name) + r'\b', src):
            i = m.end()
            def skip_ws(i):
                while i < len(src) and src[i] in ' \t\n': i += 1
                return i
            i = skip_ws(i)
            if i < len(src) and src[i] == '#':
                i = skip_ws(i + 1)
                if i < len(src) and src[i] == '(':
                    d = 0
                    while i < len(src):
                        if src[i] == '(': d += 1
                        elif src[i] == ')':
                            d -= 1
                            if d == 0: break
                        i += 1
                    i += 1
            i = skip_ws(i)
            if i >= len(src) or src[i] != '(': return None
            d = 0; st = i
            while i < len(src):
                if src[i] == '(': d += 1
                elif src[i] == ')':
                    d -= 1
                    if d == 0: break
                i += 1
            ports = [port_dirs(p) for p in split_top(src[st+1:i])]
            ports = [p for p in ports if p]
            if ports: return (str(f), ports)
    return None

RESERVED = set(('module endmodule if else for while case endcase begin end always assign initial '
                'function task localparam parameter wire reg integer generate endgenerate input '
                'output inout return default posedge negedge or and not xor').split())

def audit(root, target, verbose):
    src = strip_comments(target.read_text(errors='ignore'))
    pat = re.compile(r'\b([A-Za-z_]\w*)\s*(#\s*\([^;]*?\)\s*)?([A-Za-z_]\w*)\s*\(', re.S)
    errs, info, unres = [], [], []
    for m in pat.finditer(src):
        mod, inst = m.group(1), m.group(3)
        if mod in RESERVED: continue
        j = m.end() - 1; d = 0
        while j < len(src):
            if src[j] == '(': d += 1
            elif src[j] == ')':
                d -= 1
                if d == 0: break
            j += 1
        if not src[j+1:j+3].strip().startswith(';'): continue
        body = src[m.end():j]
        if '.' not in body: continue
        conns = set(re.findall(r'\.\s*([A-Za-z_]\w*)\s*\(', body))
        declared = module_ports(root, mod)
        if declared is None:
            unres.append((mod, inst)); continue
        dfile, ports = declared
        for pname, pdir in ports:
            if pname in conns: continue
            if pdir == 'input':
                errs.append((mod, inst, pname, dfile))
            else:
                info.append((mod, inst, pname, pdir))
        for c in sorted(conns):
            if c not in [p[0] for p in ports]:
                errs.append((mod, inst, c + ' (connected but not a port)', dfile))
    if verbose:
        for mod, inst, port, dfile in info:
            print("  info  %-26s %-20s unconnected OUTPUT %s" % (mod, inst, port))
        for mod, inst in unres:
            print("  ??    %-26s %-20s module not found / non-ANSI - NOT CHECKED" % (mod, inst))
    return errs, unres


# ---------------------------------------------------------------------------------------------
# Parameter pass-through (see the module docstring: the MPU_EN drop).
# ---------------------------------------------------------------------------------------------
_PARAM_TYPE = r'(?:(?:integer|int|bit|logic|reg|real|string|signed|unsigned|type)\s+)*'

def _balanced(src, i):
    """Index of the ')' that closes the '(' at src[i]."""
    d = 0
    while i < len(src):
        if src[i] == '(': d += 1
        elif src[i] == ')':
            d -= 1
            if d == 0: return i
        i += 1
    return -1

def _skip_ws(src, i):
    while i < len(src) and src[i] in ' \t\r\n': i += 1
    return i

def _header_params(hdr):
    """Names in a `#( parameter A = 1, B = 2, parameter [3:0] C = 0 )` list."""
    names = []
    for item in split_top(hdr):
        if '=' not in item: continue
        lhs = re.sub(r'\[[^\]]*\]', ' ', item.split('=')[0])
        toks = re.findall(r'[A-Za-z_]\w*', lhs)
        if toks: names.append(toks[-1])
    return names

def _body_params(body, kinds):
    """Names declared by `parameter`/`localparam` statements in a module body, including the
    comma-continued `parameter A = 1, B = 2;` form."""
    names = []
    for m in re.finditer(r'\b(' + '|'.join(kinds) + r')\b([^;]*);', body):
        names += _header_params(m.group(2))
    return names

def module_table(files):
    """name -> {'file', 'params' (overridable), 'all' (parameter+localparam), 'body'}."""
    table = {}
    for f in files:
        try: src = strip_comments(pathlib.Path(f).read_text(errors='ignore'))
        except Exception: continue
        for m in re.finditer(r'\bmodule\s+([A-Za-z_]\w*)\b', src):
            name = m.group(1)
            end = src.find('endmodule', m.end())
            if end < 0: continue
            i = _skip_ws(src, m.end())
            hdr = []
            if i < len(src) and src[i] == '#':
                i = _skip_ws(src, i + 1)
                if i < len(src) and src[i] == '(':
                    j = _balanced(src, i)
                    hdr = _header_params(src[i + 1:j])
                    i = j + 1
            body = src[i:end]
            params = set(hdr) | set(_body_params(body, ('parameter',)))
            alln = params | set(_body_params(body, ('localparam',)))
            table.setdefault(name, {'file': str(f), 'params': params, 'all': alln, 'body': body})
    return table

def instances(body):
    """(child, instance, override text or None) for every `child [#(...)] inst (...);`."""
    out = []
    for m in re.finditer(r'\b([A-Za-z_]\w*)\s*(?=[#A-Za-z_])', body):
        child = m.group(1)
        if child in RESERVED: continue
        i = _skip_ws(body, m.end())
        ov = None
        if i < len(body) and body[i] == '#':
            i = _skip_ws(body, i + 1)
            if i >= len(body) or body[i] != '(': continue
            j = _balanced(body, i)
            if j < 0: continue
            ov = body[i + 1:j]
            i = _skip_ws(body, j + 1)
        mi = re.match(r'([A-Za-z_]\w*)\s*(\[[^\]]*\]\s*)?\(', body[i:])
        if not mi or mi.group(1) in RESERVED: continue
        k = i + mi.end() - 1
        j = _balanced(body, k)
        if j < 0 or not body[j + 1:j + 3].strip().startswith(';'): continue
        out.append((child, mi.group(1), ov))
    return out

def param_audit(table, parents):
    """[(parent file, parent, child, instance, [dropped names])] and [(parent, child, inst)]
    whose overrides are positional (unresolved)."""
    errs, unres = [], []
    for pname in parents:
        p = table[pname]
        for child, inst, ov in instances(p['body']):
            if child not in table or child == pname: continue
            common = p['all'] & table[child]['params']
            if not common: continue
            if ov is not None and ov.strip() and '.' not in ov:
                unres.append((pname, child, inst)); continue
            passed = set(re.findall(r'\.\s*([A-Za-z_]\w*)\s*\(', ov or ''))
            dropped = sorted(common - passed)
            if dropped:
                errs.append((p['file'], pname, child, inst, dropped))
    return errs, unres

def param_main(root, targets):
    files = sorted(set(list(root.glob('src/**/*.sv')) + list(root.glob('src/**/*.v')) +
                       list(root.glob('*.sv'))))
    files = [f for f in files if in_source_tree(f, root)]
    table = module_table(files)
    tset = set(str(pathlib.Path(t).resolve()) for t in targets)
    parents = [n for n, e in table.items()
               if 'src/z486/' not in str(pathlib.Path(e['file']).resolve().relative_to(root))
               and str(pathlib.Path(e['file']).resolve()) in tset]
    return param_audit(table, parents)

def selftest():
    """Plant each form in a scratch tree and require the verdict the docstring promises."""
    import tempfile
    cases = [
        # (name, parent source, expected dropped list for the one instance)
        ('passed through', 'module p #(parameter EN = 0) (); c #(.EN(EN)) u (.a(1\'b0)); endmodule', []),
        ('dropped (the MPU_EN form)',
         'module p (); parameter EN = 1\'b0; parameter W = 2;\n'
         'c #(.W(W)) u (.a(1\'b0)); endmodule', ['EN']),
        ('dropped, no #() at all', 'module p #(parameter EN = 1) (); c u (.a(1\'b0)); endmodule', ['EN']),
        ('dropped from a localparam knob (the top level form)',
         'module p (); localparam EN = 1\'b1; c #(.W(3)) u (.a(1\'b0)); endmodule', ['EN']),
        ('comma-continued header', 'module p #(parameter W = 1, EN = 0) (); c #(.W(W)) u (.a(1\'b0)); endmodule', ['EN']),
        ('pinned explicitly', 'module p #(parameter EN = 1) (); c #(.EN(1\'b0)) u (.a(1\'b0)); endmodule', []),
        ('no common name', 'module p #(parameter OTHER = 1) (); c u (.a(1\'b0)); endmodule', []),
        ('nested override expression', 'module p #(parameter EN = 1, W = 2) (); '
         'c #(.W((W > 1) ? (W) : 1)) u (.a(1\'b0)); endmodule', ['EN']),
    ]
    child = 'module c #(parameter EN = 1\'b0, parameter [3:0] W = 4\'d1) (input wire a); endmodule\n'
    bad = 0
    with tempfile.TemporaryDirectory() as d:
        for name, psrc, want in cases:
            f = pathlib.Path(d) / 'm.sv'
            f.write_text(child + psrc + '\n')
            table = module_table([f])
            errs, unres = param_audit(table, ['p'])
            got = errs[0][4] if errs else []
            ok = got == want and not unres
            print('  %s  %-52s dropped=%s (want %s)' % ('ok  ' if ok else 'FAIL', name, got, want))
            bad += not ok
        # a positional override is reported, never passed silently
        f = pathlib.Path(d) / 'm.sv'
        f.write_text(child + 'module p #(parameter EN = 1) (); c #(1) u (.a(1\'b0)); endmodule\n')
        errs, unres = param_audit(module_table([f]), ['p'])
        ok = not errs and unres == [('p', 'c', 'u')]
        print('  %s  %-52s unresolved=%s' % ('ok  ' if ok else 'FAIL', 'positional override', unres))
        bad += not ok
    print()
    print('PORT LIST CHECK SELFTEST: %s' % ('PASS' if not bad else 'FAIL - %d case(s)' % bad))
    return 1 if bad else 0

def main():
    args = [a for a in sys.argv[1:]]
    if '--selftest' in args:
        return selftest()
    # Anchored to the tool, not to the caller's cwd -- the reason check_route_pairs.py states
    # for the same choice: a relative root made a check read whatever happened to be in the
    # caller's directory, which is not the tree under test, and a check that only works from
    # one directory is a check that does not get run.
    root = pathlib.Path(__file__).resolve().parent.parent
    if args and not args[0].startswith('--'):
        p = pathlib.Path(args[0])
        if p.is_dir(): root = p.resolve(); args = args[1:]
    allf = '--all' in args
    args = [a for a in args if not a.startswith('--')]
    # THE WHOLE SOURCE TREE IS THE DEFAULT, and that is a correction rather than a
    # preference: the default used to be the top level alone, while
    # tests/pc9821/tb_pc9821_artic_watch.sv:17 "is two named ports in one file" says the
    # pc9821_system -> pc9821_perf_msg
    # `.dbg_artic_hi(artic_hi)` hop "is checked by tools/check_port_lists.py" -- and in
    # pc9821_system.sv, which the old default never read. A cited check that does not run
    # is the defect class this round is about, so the tool now audits what its citations
    # say it audits; a named FILE still narrows it for a single-file fix.
    if allf or not args:
        targets = sorted(set(list(root.glob('src/**/*.sv')) + list(root.glob('src/**/*.v')) +
                             list(root.glob('*.sv'))))
    else:
        targets = [pathlib.Path(a) for a in args]

    # A NAMED TARGET THAT DOES NOT EXIST IS A FAILURE, NOT A PASS. This loop used to
    # `continue` past a missing file and then print PASS with len(targets), so
    # `check_port_lists.py no-such-file.sv` reported "PASS ... (1 file(s))" having audited
    # nothing, and a typo in a filename read as a clean bill of health.
    missing = [str(t) for t in targets if not t.exists()]
    if missing:
        for m in missing:
            print("  FAIL  %s does not exist" % m)
        print()
        print("PORT LIST CHECK: FAIL - %d named file(s) do not exist" % len(missing))
        return 1
    total = 0
    audited = 0
    for t in targets:
        if 'z486/' in str(t): continue          # a pinned submodule, not ours to police
        errs, unres = audit(root, t, verbose=allf or len(targets) == 1)
        audited += 1
        for mod, inst, port, dfile in errs:
            print("  FAIL  %s:%s" % (t, 0))
            print("        %s instance %s in %s" % (mod, inst, pathlib.Path(dfile).name))
            print("        UNCONNECTED INPUT or bad port: %s" % port)
        total += len(errs)
    perrs, punres = param_main(root, [t for t in targets if 'z486/' not in str(t)])
    for pfile, parent, child, inst, dropped in perrs:
        print("  FAIL  %s" % pfile)
        print("        %s instance %s in %s" % (child, inst, parent))
        print("        PARAMETER DROPPED (declared by both, not in the instance's #()): %s"
              % ", ".join(dropped))
    for parent, child, inst in punres:
        print("  ??    %s instance %s in %s: positional parameter override - NOT CHECKED"
              % (child, inst, parent))
    total += len(perrs)
    print()
    if total:
        print("PORT LIST CHECK: FAIL - %d unconnected input(s)/bad connection(s)/dropped parameter(s)"
              % total)
        return 1
    if not audited:
        # Every target was skipped, so a PASS here would be a claim about work that did not
        # happen. Refuse a verdict instead of giving a meaningless one.
        print("PORT LIST CHECK: FAIL - every target was skipped, so nothing was audited")
        return 1
    # Count what was AUDITED, not what was asked for: the two differ whenever a target is
    # skipped, and the number in a PASS line is a claim about work that was done.
    print("PORT LIST CHECK: PASS - no instantiation leaves an input undriven or drops a "
          "same-name parameter (%d file(s))" % audited)
    return 0

if __name__ == '__main__':
    sys.exit(main())

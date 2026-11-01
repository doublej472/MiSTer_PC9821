#!/usr/bin/env python3
"""iobus_formal.py -- the shared text front end of the yosys proofs over the REAL pc9821_iobus
(tools/check_iobus_lane_inv.py, tools/check_win0_moved_inv.py).

It turns the module's text into something yosys reads, never editing the tree: the package import
moves to file scope, the `// translate_off` blocks and the power-up `initial` blocks are dropped
(the proofs start from a reset), a property is pasted before `endmodule`, and every module
pc9821_iobus instantiates is replaced by a stub built from its own port list, so the submodules'
outputs are FREE (any value, any cycle) - a superset of the real behaviour.

The submodules are found from the iobus text itself (every instantiation of a module defined
under src/), and the port lists are parsed with comments and string literals masked, so a
parenthesis inside a comment cannot unbalance the scan.

  python3 tools/iobus_formal.py --selftest
"""
import glob
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IOBUS = "src/pc9821/core/pc9821_iobus.sv"
PKG = "src/pc9821/core/pc9821_ports_pkg.sv"

SAT_SCRIPT = ("read_verilog -sv -formal -noblackbox iobus.sv; hierarchy -top pc9821_iobus; proc; "
              "chformal -lower; flatten; memory; opt_clean; setundef -undriven -anyseq; "
              "opt -fast; sat -tempinduct -prove-asserts -set-init-undef -set-def-inputs "
              "-set-def-formal -seq 1 -set-at 1 reset 1 -maxsteps 4 -verify")


def code_mask(src):
    """A copy of src with every comment and string literal blanked to spaces (newlines kept), so
    offsets match the original and only code characters remain."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
        else:
            i += 1
            continue
        for k in range(i, j):
            if out[k] != "\n":
                out[k] = " "
        i = j
    return "".join(out)


def balanced(code, i):
    """Index just past the parenthesised group that opens at code[i] == '(' (code is masked)."""
    if code[i] != "(":
        raise ValueError("expected '(' at offset %d, found %r" % (i, code[i]))
    depth = 0
    for j in range(i, len(code)):
        if code[j] == "(":
            depth += 1
        elif code[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
    raise ValueError("unbalanced parenthesis opening at offset %d" % i)


def skip_ws(code, i):
    while code[i].isspace():
        i += 1
    return i


def module_defs():
    """{module name: path} for every module defined under src/."""
    defs = {}
    for f in sorted(glob.glob(os.path.join(REPO, "src", "**", "*.*v"), recursive=True)):
        code = code_mask(open(f, errors="replace").read())
        for m in re.finditer(r"^\s*module\s+(\w+)", code, re.M):
            defs.setdefault(m.group(1), os.path.relpath(f, REPO))
    return defs


def instantiated(src, defs):
    """The modules src instantiates: `NAME [#(...)] INST (` with NAME defined under src/."""
    code = code_mask(src)
    found = []
    for m in re.finditer(r"^\s*(\w+)\b\s*(?=[#\w])", code, re.M):
        name = m.group(1)
        if name not in defs or name in found:
            continue
        i = skip_ws(code, m.end())
        if code[i] == "#":
            i = skip_ws(code, i + 1)
            if code[i] != "(":
                continue
            i = skip_ws(code, balanced(code, i))
        inst = re.match(r"\w+\s*\(", code[i:])
        if inst:
            found.append(name)
    return found


def port_stub(rel, name, blackbox=False):
    """The module's header (parameters and port list) closed with `endmodule`, comments dropped."""
    src = open(os.path.join(REPO, rel)).read()
    code = code_mask(src)
    m = re.search(r"^\s*module\s+%s\b" % re.escape(name), code, re.M)
    if not m:
        sys.exit("module %s not found in %s" % (name, rel))
    i = skip_ws(code, m.end())
    if code[i] == "#":
        i = skip_ws(code, balanced(code, skip_ws(code, i + 1)))
    b = balanced(code, i)
    return ("(* blackbox *)\n" if blackbox else "") + code[m.start():b].strip() + ";\nendmodule\n"


def stubs(src, blackbox=False):
    defs = module_defs()
    return "".join(port_stub(defs[n], n, blackbox) for n in instantiated(src, defs))


def strip_initial(src):
    """src without its `initial begin ... end` blocks (begin/end counted on the masked text)."""
    code = code_mask(src)
    out, pos = [], 0
    for m in re.finditer(r"^\s*initial\s+begin\b", code, re.M):
        if m.start() < pos:
            continue
        depth, j = 0, m.end() - len("begin")
        for tok in re.finditer(r"\bbegin\b|\bend\b", code[j:]):
            depth += 1 if tok.group(0) == "begin" else -1
            if depth == 0:
                out.append(src[pos:m.start()])
                pos = j + tok.end()
                break
        else:
            raise ValueError("unterminated initial block at offset %d" % m.start())
    out.append(src[pos:])
    return "".join(out)


def prep(io, modname="pc9821_iobus"):
    """The module text yosys can read: no package import inside, no simulation-only blocks, no
    power-up `initial` blocks, renamed to modname."""
    imp = "  import pc9821_ports_pkg::*;\n"
    if io.count(imp) != 1:
        sys.exit("pc9821_iobus: expected exactly one %r" % imp.strip())
    io = io.replace(imp, "")
    while "// translate_off" in io:
        a = io.index("// translate_off")
        io = io[:a] + io[io.index("// translate_on", a) + len("// translate_on"):]
    io = strip_initial(io)
    return io.replace("module pc9821_iobus", "module " + modname, 1)


def replace_once(text, a, b, what):
    if text.count(a) != 1:
        sys.exit("%s anchor must occur exactly once (found %d): %r" % (what, text.count(a), a))
    return text.replace(a, b)


def iobus_text(plants=()):
    io = open(os.path.join(REPO, IOBUS)).read()
    for a, b in plants:
        io = replace_once(io, a, b, "plant")
    return io


def prove_property(prop, plants=()):
    """Paste prop into a copy of pc9821_iobus (plants applied first) and prove its assertions by
    induction from a reset. Returns (proven, log)."""
    raw = iobus_text(plants)
    io = prep(raw)
    k = io.rindex("endmodule")
    io = io[:k] + prop + io[k:]
    text = (open(os.path.join(REPO, PKG)).read() + "\nimport pc9821_ports_pkg::*;\n" + io + "\n" +
            stubs(raw))
    os.makedirs(os.path.join(REPO, ".build"), exist_ok=True)
    with tempfile.TemporaryDirectory(dir=os.path.join(REPO, ".build")) as tmp:
        open(os.path.join(tmp, "iobus.sv"), "w").write(text)
        r = subprocess.run(["yosys", "-q", "-p", SAT_SCRIPT], cwd=tmp, capture_output=True,
                           text=True)
    log = r.stdout + r.stderr
    # Only a failed proof is a FAIL; any other yosys error (a plant that breaks the parse, a
    # missing module) would otherwise pass for a caught plant.
    if r.returncode and "proof did fail" not in log:
        sys.exit("yosys did not reach the proof:\n" + log[-3000:])
    return r.returncode == 0, log


def selftest():
    """The parser on planted text: a parenthesis in a comment or string, a parameterised module,
    an instantiation hidden in a comment."""
    bad = 0
    src = ('module a #(parameter P = (1), parameter string S = ")(")  // a ( comment\n'
           '  (input x, /* ) */ output y // b) ok\n  );\nendmodule\n')
    code = code_mask(src)
    i = skip_ws(code, code.index("#") + 1)
    j = skip_ws(code, balanced(code, i))
    hdr = code[:balanced(code, j)]
    want = "output y"
    bad += want not in hdr or "comment" in hdr or not hdr.rstrip().endswith(")")
    try:
        balanced(code_mask("( // )\n"), 0)
        bad += 1
    except ValueError:
        pass
    body = ("  foo #(.P(1)) u_foo (.x(a));\n  // bar u_bar (.x(a));\n  baz u_baz(.x(b));\n"
            "  assign q = foo(1);\n")
    got = instantiated(body, {"foo": "", "bar": "", "baz": ""})
    bad += got != ["foo", "baz"]
    init = "initial begin\n  x = 0; // end\nend\nwire y;\n"
    bad += strip_initial(init).strip() != "wire y;"
    print("iobus_formal: selftest %s" % ("FAIL" if bad else "PASS"))
    return bad


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(1 if selftest() else 0)
    raw = iobus_text()
    print("pc9821_iobus instantiates (stubbed):", ", ".join(instantiated(raw, module_defs())))

#!/usr/bin/env python3
"""A strobe or bus that several devices share must be qualified by the consumer's own select.

The class this holds (the Policenauts intro stall, a hard-disk corruption): hps_io has ONE
`sd_buff_wr` / `sd_buff_addr` / `sd_buff_dout` for every disk slot. A module that counts or stores
those words must AND in ITS OWN slot's `sd_ack`, or it also swallows the words another slot is
streaming. `pc9821_block_io` had `stream_word = fetch_active && !fetch_write && sd_buff_wr` - the
shared strobe with no `sd_ack` - and counted the CD slot's words into the disk's buffer. The
CD module (`pc9821_atapi`: `e_word = E_STREAM && sd_ack && sd_buff_wr`) gates it correctly. Nothing
in lint, in a bench of one slot, or in the boot golden can see the omission, because every one of
them runs a single slot at a time.

THE RULE. For each shared signal family (FAMILIES below) every module that CONSUMES a shared
signal must have the use qualified by that module's own select:
  sd_hps   hps_io's sd_buff_wr/addr/dout       -> the slot's sd_ack
  ioctl    hps_io's ioctl_wr/addr/dout         -> an ioctl_index match
  io_bus   the shared I/O strobes device_io_wr/rd -> an address decode / chip select
  mem_resp the SDRAM backend's shared mem_resp_valid -> the owning route's select

HOW A USE IS JUDGED (a lexical dataflow, not a proof):
  1. The shared names start at a SEED (a wire in the top level or in pc9821_system) and spread
     down the hierarchy by BARE forwarding: `.port(shared)` makes `port` shared in the callee.
     A forward is not itself a use - the callee is checked instead. A non-bare connection
     (`.io_wr(device_io_wr && ata_cs)`) is a use, judged like any expression.
  2. A USE is any statement (an `assign`, a declaration initialiser, an assignment in an always,
     an `if`/`case` condition) that mentions a shared name. It is QUALIFIED if the identifiers of
     the statement, of every enclosing `if`/`case` condition, and of everything those identifiers
     are assigned from (transitively, through wires and registers) include one of the family's
     qualifier names.
  3. An unqualified use that defines a name (`wire stream_word = ... sd_buff_wr`) is PENDING on that
     name: it passes only if EVERY other statement that reads the name is itself qualified (the
     qualification may sit at the consumer). A pending name with no reader passes (dead logic); one
     that leaves through an output port, or an unqualified use with no name, is a HIT.
  4. Simulation-only code (`$display`/`$fatal` bodies and their conditions, `ifdef VERILATOR`
     blocks, `// synthesis translate_off` regions) observes and does not consume; it is skipped.

A HIT is `file:line`. A hit that is justified is listed in LEDGER with its reason, keyed by
(file, family, signal, defined-name). The ledger is SHRINK-ONLY: an entry that no longer matches
a hit fails the check itself, so a fixed defect or a rename cannot leave a stale excuse.

AUDITED AND NOT CHECKED (printed by --list): signals that look shared but have one writer or are
event-coded, so there is no select to omit - see NOT_CHECKED.

Run:  python3 tools/check_shared_strobes.py            check the tree
      python3 tools/check_shared_strobes.py --selftest plant the defects; each must be caught
      python3 tools/check_shared_strobes.py --list     print the families, seeds and exclusions
      python3 tools/check_shared_strobes.py --root DIR check another tree (e.g. a git archive)
Exit 0 = clean, 1 = a hit / stale ledger entry / self-test failure.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Files that are consumers: the top level and project RTL. src/z486 and src/opna are vendored and
# have no view of these buses; sys/ is the framework (the SOURCE of the shared signals).
SCAN_GLOBS = ["z486_mister.sv", "src/pc9821/**/*.sv", "src/pc9821/**/*.v", "src/pcm86/**/*.sv",
              "src/pcm86/**/*.v", "src/memory/**/*.sv", "src/memory/**/*.v",
              "src/soc/**/*.sv", "src/soc/**/*.v", "src/common/**/*.sv", "src/common/**/*.v"]
FRAMEWORK_PREFIXES = ("sys/",)
# Modules that are the SOURCE side or a vendored implementation: a connection into one is not
# a consumer to check. hps_io drives the sd_buff/ioctl signals.
EXTERNAL_MODULES = {"hps_io"}


VERBOSE = False


class Family:
    def __init__(self, name, seeds, qualifier, why):
        self.name = name
        self.seeds = seeds                      # {module: [shared names declared in it]}
        self.qualifier = re.compile(qualifier)  # matches a qualifying identifier
        self.why = why


FAMILIES = [
    Family(
        "sd_hps",
        {"emu": ["sd_buff_wr", "sd_buff_addr", "sd_buff_dout"]},
        r"^(?:\w*_)?(?:sd|img|fdd\d?|cd|disk)_ack$",
        "hps_io has ONE sd_buff_wr/addr/dout for every slot; only that slot's sd_ack says the "
        "stream is this module's"),
    Family(
        "ioctl",
        {"emu": ["ioctl_wr", "ioctl_addr", "ioctl_dout"]},
        r"^ioctl_index$",
        "hps_io's ioctl_wr/addr/dout carry every download index; ioctl_index says which file"),
    Family(
        "io_bus",
        {"pc9821_system": ["device_io_wr", "device_io_rd"]},
        r"^(?:\w+_)?(?:cs|sel|select)\d*$|^\w+_cs\w*$|^(?:device_)?io_addr\w*$|^addr\w*$",
        "device_io_wr/rd pulse for EVERY port the CPU touches; a device acts only on its own "
        "address decode or chip select"),
    Family(
        "mem_resp",
        {"pc9821_memory_subsystem": ["mem_resp_valid"]},
        r"^(?:loader_owns|map_accepted|rt_head\w*|rt_empty|\w+_owns|\w+_owner\w*)$",
        "the backend's one mem_resp_valid answers whichever route issued the read; only the "
        "owner-qualified copy belongs to a route"),
]

# Signals audited and deliberately not checked, with the reason (printed by --list).
NOT_CHECKED = {
    "ps2_key / ps2_mouse": "hps_io's parsed PS/2 words, TOGGLE-coded (bit 10 flips per key), one "
                           "consumer each; there is no shared select to omit",
    "core_dbg_uart_we / debug_uart_*": "an arbiter at the top level, not a consumer: several "
                                      "PRODUCERS share the one UART, each arm is guarded by the "
                                      "arbiter's own accept (z486_mister.sv debug_uart_*_accept)",
    "fmem_resp_valid / pmem_resp_valid": "dedicated per-port SDRAM resp_valid1/2 (sdram.v "
                                         "req_id_buf decode already qualifies them at the source)",
    "sd_buff_din": "driven, not consumed: block_share fans ONE engine value to every slot and "
                   "hps_io samples only the acknowledged slot's (pc9821_block_share.sv)",
}

# (file, family, signal, defined-name) -> reason. Shrink-only.
LEDGER = [
    # (empty) pc9821_hps_slot_demux qualifies every bit it forwards (ZERO_DATA is a parameter
    # in the same statement as the ack), so no hit is excused.
]

# ---------------------------------------------------------------------------------------------
# lexing

TOKEN = re.compile(
    r"\d*'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ_?]+|[A-Za-z_`$][\w$]*|\d[\w.]*"
    r"|<=|>=|===|!==|==|!=|&&|\|\||<<|>>|::|\S")
IDENT = re.compile(r"(?<![\w$`.'])[A-Za-z_][\w$]*")
KEYWORDS = {
    "if", "else", "begin", "end", "case", "casez", "casex", "endcase", "default", "assign", "wire",
    "reg", "logic", "input", "output", "inout", "always", "always_ff", "always_comb", "initial",
    "posedge", "negedge", "or", "and", "not", "for", "while", "integer", "genvar", "signed",
    "unsigned", "localparam", "parameter", "function", "endfunction", "generate", "endgenerate",
}


def strip_comments(t):
    """Blank comments (newlines kept, so line numbers survive), and sim-only regions."""
    def blank(m):
        return re.sub(r"[^\n]", " ", m.group(0))
    # `// synthesis translate_off` .. `translate_on` (the tree's one sim-only fence) observes too.
    t = re.sub(r"//\s*synthesis\s+translate_off.*?//\s*synthesis\s+translate_on", blank, t, flags=re.S)
    t = re.sub(r"/\*.*?\*/", blank, t, flags=re.S)
    t = re.sub(r"//[^\n]*", blank, t)
    t = re.sub(r"\"(?:[^\"\\\n]|\\.)*\"", lambda m: '"' + " " * (len(m.group(0)) - 2) + '"', t)
    # `ifdef VERILATOR / `ifndef SYNTHESIS ... `endif (the first `else/`endif closes it): the
    # assertions and displays in there observe, they do not consume.
    out, lines, skip, depth = [], t.split("\n"), False, 0
    for ln in lines:
        s = ln.strip()
        if not skip and re.match(r"`ifdef\s+(VERILATOR|SIMULATION)\b|`ifndef\s+SYNTHESIS\b", s):
            skip, depth = True, 1
            out.append("")
            continue
        if skip:
            if re.match(r"`if(n?def)?\b", s):
                depth += 1
            elif re.match(r"`endif\b", s):
                depth -= 1
                if depth == 0:
                    skip = False
            out.append("")
            continue
        out.append(re.sub(r"^\s*`(ifdef|ifndef|else|endif|elsif|define|include|timescale|"
                          r"default_nettype|undef)\b.*$", lambda m: " " * len(m.group(0)), ln))
    return "\n".join(out)


def tokenize(text, line0=1):
    """[(token, line)] with line numbers from the (newline-preserving) text."""
    toks, line, pos = [], line0, 0
    for m in re.finditer(r"\n|" + TOKEN.pattern, text):
        s = m.group(0)
        if s == "\n":
            line += 1
        else:
            toks.append((s, line))
    return toks


def idents(text):
    return [m.group(0) for m in IDENT.finditer(text) if m.group(0) not in KEYWORDS]


# ---------------------------------------------------------------------------------------------
# module extraction

class Stmt:
    __slots__ = ("line", "lhs", "rhs", "ctx", "kind", "conn")

    def __init__(self, line, lhs, rhs, ctx, kind, conn=None):
        self.line, self.lhs, self.rhs, self.ctx, self.kind, self.conn = \
            line, lhs, rhs, tuple(ctx), kind, conn


class Module:
    def __init__(self, name, path):
        self.name, self.path = name, path
        self.ports = {}       # name -> direction
        self.stmts = []
        self.insts = []       # (inst_type, inst_name, line, [(port, expr)])


def balanced(text, i):
    """text[i] == '(': return the index of the matching ')'."""
    depth = 0
    for j in range(i, len(text)):
        c = text[j]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j
    return len(text) - 1


def split_top(s, sep=","):
    out, depth, cur = [], 0, []
    for c in s:
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if c == sep and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    out.append("".join(cur))
    return out


INST_RE = re.compile(
    r"(?<![\w$.`])([A-Za-z_]\w*)\s*(?:#\s*\()?")  # the head; refined by hand below


def find_instances(body):
    """[(type, name, start, end, [(port, expr)])] for `T [#(..)] n ( .p(e), ... );`."""
    res = []
    for m in re.finditer(r"(?<![\w$.`])([A-Za-z_]\w*)(\s*#\s*\()?", body):
        typ = m.group(1)
        if typ in KEYWORDS or typ in ("module", "endmodule", "function", "task"):
            continue
        i = m.end()
        if m.group(2):
            i = balanced(body, m.end() - 1) + 1
        n = re.compile(r"\s*([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*\(\s*\.").match(body, i)
        if not n:
            continue
        op = body.index("(", n.start(1) + len(n.group(1)))
        cl = balanced(body, op)
        conns = []
        for seg in split_top(body[op + 1:cl]):
            c = re.match(r"\s*\.(\w+)\s*\((.*)\)\s*$", seg, re.S)
            if c:
                conns.append((c.group(1), c.group(2).strip()))
        res.append((typ, n.group(1), m.start(), cl + 1, conns))
    return res


def parse_modules(path, text):
    clean = strip_comments(text)
    mods = []
    for m in re.finditer(r"\bmodule\s+(\w+)", clean):
        end = clean.find("endmodule", m.end())
        if end < 0:
            end = len(clean)
        mod = Module(m.group(1), path)
        # header
        i = m.end()
        j = i
        if re.compile(r"\s*#\s*\(").match(clean, i):
            j = balanced(clean, clean.index("(", i)) + 1
        k = clean.find("(", j)
        semi = clean.find(";", j)
        if 0 <= k < semi:
            close = balanced(clean, k)
            direction = None
            for seg in split_top(clean[k + 1:close]):
                seg = re.sub(r"\[[^\]]*\]", " ", seg)
                words = re.findall(r"[A-Za-z_]\w*", seg)
                if not words:
                    continue
                for w in words:
                    if w in ("input", "output", "inout"):
                        direction = w
                if words[-1] not in ("input", "output", "inout", "wire", "reg", "logic"):
                    mod.ports[words[-1]] = direction
            body_start = semi + 1
        else:
            body_start = semi + 1
        body = clean[body_start:end]
        base_line = clean.count("\n", 0, body_start) + 1
        # instances: record and blank them out of the statement stream
        blanked = list(body)
        for typ, name, s, e, conns in find_instances(body):
            ln = base_line + body.count("\n", 0, s)
            mod.insts.append((typ, name, ln, conns))
            for q in range(s, e):
                if blanked[q] != "\n":
                    blanked[q] = " "
            for port, expr in conns:
                pos = body.find("." + port, s)
                cl = base_line + body.count("\n", 0, pos if pos >= 0 else s)
                mod.stmts.append(Stmt(cl, None, expr, [], "conn", (typ, name, port)))
        parse_items(mod, tokenize("".join(blanked), base_line))
        mods.append(mod)
    return mods


def lhs_base(toks):
    """The assigned name of an lhs/decl token list: first non-keyword identifier before any '['
    for an assignment, the LAST identifier for a declaration with an initialiser."""
    names = [t for t, _ in toks if re.match(r"[A-Za-z_]", t) and t not in KEYWORDS]
    return names


class P:
    def __init__(self, mod, toks):
        self.m, self.t, self.i = mod, toks, 0

    def peek(self, k=0):
        return self.t[self.i + k][0] if self.i + k < len(self.t) else None

    def line(self):
        return self.t[min(self.i, len(self.t) - 1)][1] if self.t else 0

    def take(self):
        tok = self.t[self.i]
        self.i += 1
        return tok

    def paren(self):
        """At '(' : consume to the matching ')'; return its tokens (without the parens)."""
        depth, out = 0, []
        while self.i < len(self.t):
            tok = self.take()
            if tok[0] == "(":
                depth += 1
                if depth == 1:
                    continue
            elif tok[0] == ")":
                depth -= 1
                if depth == 0:
                    return out
            out.append(tok)
        return out

    def to_semi(self):
        depth, out = 0, []
        while self.i < len(self.t):
            tok = self.t[self.i]
            if tok[0] in ("(", "[", "{"):
                depth += 1
            elif tok[0] in (")", "]", "}"):
                depth -= 1
            elif tok[0] == ";" and depth <= 0:
                self.i += 1
                return out
            elif tok[0] in ("end", "endcase", "endgenerate", "endfunction") and depth <= 0:
                return out
            out.append(tok)
            self.i += 1
        return out


def text_of(toks):
    return " ".join(t for t, _ in toks)


def split_assign(toks):
    depth = 0
    for k, (t, _) in enumerate(toks):
        if t in ("(", "[", "{"):
            depth += 1
        elif t in (")", "]", "}"):
            depth -= 1
        elif depth == 0 and t in ("=", "<="):
            return toks[:k], toks[k + 1:]
    return None, toks


DECL_KW = {"wire", "logic", "reg", "integer", "localparam", "parameter", "input", "output",
           "inout", "genvar", "var", "tri", "real", "time", "typedef", "import", "int", "bit"}
SYSTASK = re.compile(r"^\s*\$|\bassert\b|\bassume\b|\bcover\b")


def parse_items(mod, toks):
    p = P(mod, toks)
    while p.i < len(p.t):
        before = p.i
        parse_stmt(p, [])
        if p.i == before:
            p.i += 1


def add_simple(p, toks, ctx):
    if not toks:
        return False
    first = toks[0][0]
    if first.startswith("$") or SYSTASK.search(first):
        return True                       # observer
    lhs_t, rhs_t = split_assign(toks)
    line = toks[0][1]
    if lhs_t is None and first in DECL_KW:
        return False                      # a declaration with no initialiser reads nothing
    if lhs_t is None:
        p.m.stmts.append(Stmt(line, None, text_of(rhs_t), ctx, "expr"))
        return False
    if first in ("wire", "logic", "reg", "integer", "localparam", "parameter", "input",
                 "output", "inout", "genvar", "var") or (first.startswith("`") is False and
                                                            len(lhs_base(lhs_t)) > 1 and
                                                            lhs_t[0][0] in ("wire", "logic", "reg")):
        names = lhs_base([x for x in lhs_t if x[0] not in ("[",)])
        name = names[-1] if names else None
    elif first == "assign":
        names = lhs_base(lhs_t[1:])
        name = names[0] if names else None
    else:
        names = lhs_base(lhs_t)
        name = names[0] if names else None
    lhs_extra = ""
    # the index expression of an lhs (`mem[sd_buff_addr] <= ...`) is a use of whatever it names
    if lhs_t and name:
        lhs_extra = text_of([x for x in lhs_t if x[0] != name][1:]) if first != "assign" else \
            text_of(lhs_t[1:])
    p.m.stmts.append(Stmt(line, name, text_of(rhs_t) + " " + lhs_extra, ctx, "assign"))
    return False


def parse_stmt(p, ctx):
    """Parse one item/statement; returns True if it was observer-only (sim code)."""
    t = p.peek()
    if t is None:
        return True
    if t in ("generate", "endgenerate", "end", "endcase", "endfunction", ";", "else"):
        p.i += 1
        return True
    if t == "begin":
        p.take()
        if p.peek() == ":":
            p.i += 2
        obs = True
        while p.peek() not in (None, "end"):
            before = p.i
            obs = parse_stmt(p, ctx) and obs
            if p.i == before:
                p.i += 1
        p.i += 1
        return obs
    if t == "if":
        ln = p.line()
        p.take()
        cond = p.paren()
        mark = len(p.m.stmts)
        p.m.stmts.append(Stmt(ln, None, text_of(cond), ctx, "cond"))
        nctx = ctx + [text_of(cond)]
        obs = parse_stmt(p, nctx)
        if p.peek() == "else":
            p.take()
            obs = parse_stmt(p, nctx) and obs
        if obs:                           # `if (bad) $fatal(...)`: the condition only observes
            del p.m.stmts[mark:]
        return obs
    if t in ("case", "casez", "casex"):
        ln = p.line()
        p.take()
        sel = p.paren()
        p.m.stmts.append(Stmt(ln, None, text_of(sel), ctx, "cond"))
        nctx = ctx + [text_of(sel)]
        while p.peek() not in (None, "endcase"):
            depth = 0
            while p.peek() not in (None, "endcase"):    # the label, up to its ':'
                tok = p.peek()
                if tok in ("(", "[", "{"):
                    depth += 1
                elif tok in (")", "]", "}"):
                    depth -= 1
                elif tok == ":" and depth == 0:
                    p.i += 1
                    break
                p.i += 1
            if p.peek() == "endcase":
                break
            parse_stmt(p, nctx)
        p.i += 1
        return False
    if t in ("for", "while", "repeat", "foreach"):
        p.take()
        hdr = p.paren()
        p.m.stmts.append(Stmt(p.line(), None, text_of(hdr), ctx, "cond"))
        return parse_stmt(p, ctx + [text_of(hdr)])
    if t in ("always", "always_ff", "always_comb", "always_latch", "initial", "final"):
        p.take()
        if p.peek() == "@":
            p.take()
            if p.peek() == "(":
                p.paren()
            else:
                p.take()
        return parse_stmt(p, ctx)
    if t in ("function", "task"):
        ln = p.line()
        start = p.i
        endkw = "end" + t
        while p.peek() not in (None, endkw):
            p.i += 1
        p.m.stmts.append(Stmt(ln, None, text_of(p.t[start:p.i]), ctx, "expr"))
        p.i += 1
        return False
    if t in ("forever",):
        p.take()
        return parse_stmt(p, ctx)
    if t == "@" or t == "#":
        p.take()
        if p.peek() == "(":
            p.paren()
        else:
            p.take()
        return parse_stmt(p, ctx)
    toks = p.to_semi()
    return add_simple(p, toks, ctx)


# ---------------------------------------------------------------------------------------------
# analysis

class Hit:
    def __init__(self, path, line, family, signal, name, why):
        self.path, self.line, self.family, self.signal, self.name, self.why = \
            path, line, family, signal, name, why

    def key(self):
        return (self.path, self.family, self.signal, self.name)

    def __str__(self):
        return "%s:%d: [%s] %s used with no %s-qualifier (via '%s') - %s" % (
            self.path, self.line, self.family, self.signal, self.family, self.name, self.why)


def analyse(mods_by_name, families, external=EXTERNAL_MODULES):
    hits = []
    for fam in families:
        shared = {}      # module -> set of shared names
        for mn, names in fam.seeds.items():
            if mn in mods_by_name:
                shared.setdefault(mn, set()).update(names)
        # propagate down the hierarchy by bare forwarding
        changed = True
        while changed:
            changed = False
            for mn, S in list(shared.items()):
                mod = mods_by_name[mn]
                for typ, iname, ln, conns in mod.insts:
                    if typ not in mods_by_name:
                        continue
                    for port, expr in conns:
                        base = re.sub(r"\[[^\]]*\]", "", expr).strip()
                        if (base in S and mods_by_name[typ].ports.get(port) == "input"
                                and port not in shared.get(typ, set())):
                            shared.setdefault(typ, set()).add(port)
                            changed = True
        if VERBOSE:
            for mn, S in sorted(shared.items()):
                print("  [%s] %s: %s" % (fam.name, mn, ", ".join(sorted(S))))
        for mn, S in shared.items():
            hits.extend(check_module(mods_by_name, mods_by_name[mn], S, fam, external))
    # one hit per (file, line, family, signal)
    seen, out = set(), []
    for h in hits:
        k = (h.path, h.line, h.family, h.signal, h.name)
        if k not in seen:
            seen.add(k)
            out.append(h)
    return out


def check_module(mods_by_name, mod, S, fam, external):
    hits = []
    defs = {}                 # name -> [rhs idents]
    readers = {}              # name -> [Stmt that read it, in rhs or ctx]
    for s in mod.stmts:
        if s.kind in ("assign",) and s.lhs:
            defs.setdefault(s.lhs, []).append(set(idents(s.rhs)))
    for s in mod.stmts:
        names = set(idents(s.rhs))
        for c in s.ctx:
            names.update(idents(c))
        for n in names:
            readers.setdefault(n, []).append(s)
    outs = {n for n, d in mod.ports.items() if d in ("output", "inout")}

    def closure(s):
        seen = set(idents(s.rhs))
        for c in s.ctx:
            seen.update(idents(c))
        frontier = set(seen)
        for _ in range(10):
            nxt = set()
            for n in frontier:
                for d in defs.get(n, []):
                    for x in d:
                        if x not in seen:
                            seen.add(x)
                            nxt.add(x)
            if not nxt:
                break
            frontier = nxt
        return seen

    def qualified(s):
        return any(fam.qualifier.match(n) for n in closure(s))

    def uses(s):
        names = set(idents(s.rhs))
        return [n for n in names if n in S and n != s.lhs]

    memo = {}

    def ok(s, stack):
        """(passes, explanation) for statement s that touches a shared name."""
        if qualified(s):
            return True, ""
        if s.kind == "conn" or not s.lhs:
            return False, "no qualifier in the expression or its enclosing conditions"
        name = s.lhs
        if name in outs:
            return False, "leaves through output port '%s' unqualified" % name
        if name in S:
            return True, ""
        if name in stack:
            return True, ""
        if name in memo:
            return memo[name]
        memo[name] = (True, "")
        sinks = [r for r in readers.get(name, []) if r is not s and r.lhs != name]
        bad = None
        for r in sinks:
            good, why = ok(r, stack | {name})
            if not good:
                bad = (r.line, why)
                break
        res = (True, "") if bad is None else \
            (False, "'%s' is read unqualified at line %d (%s)" % (name, bad[0], bad[1]))
        memo[name] = res
        return res

    for s in mod.stmts:
        used = uses(s)
        if not used:
            continue
        if s.kind == "conn":
            typ, iname, port = s.conn
            base = re.sub(r"\[[^\]]*\]", "", s.rhs).strip()
            if base in S:                    # bare forward: the callee is checked
                if typ in external:
                    continue
                if typ not in mods_by_name:
                    hits.append(Hit(mod.path, s.line, fam.name, base, "%s.%s" % (iname, port),
                                    "forwarded into '%s', which is not in the scanned tree" % typ))
                continue
        good, why = ok(s, frozenset())
        if VERBOSE:
            q = sorted(n for n in closure(s) if fam.qualifier.match(n))
            print("    %s:%d %s %s <- %s%s" % (mod.path, s.line, "ok " if good else "HIT",
                  s.lhs or s.kind, ",".join(used), (" [qual: %s]" % ",".join(q)) if q else
                  (" [no qual: deferred to sinks]" if good else "")))
        if not good:
            name = s.lhs or ("%s.%s" % (s.conn[1], s.conn[2]) if s.conn else "<expr>")
            for u in used:
                hits.append(Hit(mod.path, s.line, fam.name, u, name, why))
    return hits


# ---------------------------------------------------------------------------------------------
# driver

def load_tree(root):
    mods = {}
    files = []
    for g in SCAN_GLOBS:
        files.extend(sorted(root.glob(g)))
    for f in dict.fromkeys(files):
        rel = f.relative_to(root).as_posix()
        if rel.startswith(FRAMEWORK_PREFIXES):
            continue
        for m in parse_modules(rel, f.read_text(encoding="utf-8", errors="replace")):
            mods[m.name] = m
    return mods


def apply_ledger(hits, ledger):
    used, left = set(), []
    for h in hits:
        match = [i for i, e in enumerate(ledger)
                 if (e["file"], e["family"], e["signal"], e["name"]) == h.key()]
        if match:
            used.update(match)
        else:
            left.append(h)
    stale = [e for i, e in enumerate(ledger) if i not in used]
    return left, stale


def run(root):
    hits = analyse(load_tree(root), FAMILIES)
    return apply_ledger(hits, LEDGER_DICTS)


LEDGER_DICTS = [dict(file=a, family=b, signal=c, name=d, reason=e) for a, b, c, d, e in LEDGER]


# ---------------------------------------------------------------------------------------------
# self-test: a synthetic tree, the original defect among the plants

TOP = """module emu (input clk);
  wire sd_buff_wr; wire [12:0] sd_buff_addr; wire [15:0] sd_buff_dout;
  wire ioctl_wr; wire [26:0] ioctl_addr; wire [15:0] ioctl_dout;
  wire [4:0] sd_ack;
  hps_io hps (.sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
              .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout));
  %s
endmodule
"""

# the pre-fix pc9821_block_io shape: the shared strobe with no sd_ack
BLOCK_IO_BAD = """module pc9821_block_io (input clk, input sd_ack, input sd_buff_wr,
    input [12:0] sd_buff_addr, input [15:0] sd_buff_dout, output reg done);
  reg fetch_active, fetch_write, transfer_error;
  reg [12:0] words_received;
  reg [15:0] cache_ram [0:255];
  wire [12:0] fetch_span = 13'd256;
  wire stream_word = fetch_active && !fetch_write && sd_buff_wr;
  wire valid_buffer_word = stream_word && (sd_buff_addr < fetch_span);
  always @(posedge clk) begin
    if (sd_ack) fetch_active <= 1'b1;
    if (stream_word) words_received <= words_received + 13'd1;
    if (valid_buffer_word) cache_ram[sd_buff_addr[7:0]] <= sd_buff_dout;
  end
endmodule
"""

BLOCK_IO_GOOD = BLOCK_IO_BAD.replace(
    "fetch_active && !fetch_write && sd_buff_wr;",
    "fetch_active && !fetch_write && sd_ack && sd_buff_wr;")

# the same defect, reaching the data bus only (strobe qualified, bus used bare)
BUS_BAD = """module bus_user (input clk, input sd_ack, input sd_buff_wr, input [15:0] sd_buff_dout,
    output reg [15:0] q);
  always @(posedge clk) begin
    q <= sd_buff_dout;
  end
endmodule
"""
BUS_GOOD = BUS_BAD.replace("    q <= sd_buff_dout;", "    if (sd_ack && sd_buff_wr) q <= sd_buff_dout;")

# defect where the unqualified strobe is registered, the qualifier sitting in an if() context
REG_BAD = """module reg_user (input clk, input sd_ack, input sd_buff_wr, output reg w);
  reg wd;
  always @(posedge clk) begin
    wd <= sd_buff_wr;
    w <= wd;
  end
endmodule
"""
REG_GOOD_CTX = """module reg_user (input clk, input sd_ack, input sd_buff_wr, output reg w);
  reg wd;
  always @(posedge clk) begin
    if (sd_ack) wd <= sd_buff_wr;
    w <= wd;
  end
endmodule
"""

IOCTL_BAD = """module ld (input clk, input [15:0] ioctl_index, input ioctl_wr, input [26:0] ioctl_addr,
    input ioctl_download, output reg we);
  wire in_region = ioctl_addr < 27'd4096;
  always @(posedge clk) we <= ioctl_wr && in_region;
endmodule
"""
IOCTL_GOOD = IOCTL_BAD.replace("ioctl_wr && in_region", "ioctl_wr && in_region && "
                               "(ioctl_index == 16'd0)")

SYSTEM_BAD = """module pc9821_system (input clk, input a);
  wire device_io_wr, device_io_rd; wire [15:0] device_io_addr; wire ata_cs;
  wire hit_a = device_io_wr;
  wire tap = device_io_rd;
  io_dev u (.clk(clk), .io_wr(device_io_wr), .io_rd(device_io_rd & a), .io_addr(device_io_addr));
endmodule
"""
SYSTEM_GOOD = """module pc9821_system (input clk, input a);
  wire device_io_wr, device_io_rd; wire [15:0] device_io_addr; wire ata_cs;
  io_dev u (.clk(clk), .io_wr(device_io_wr && ata_cs), .io_rd(device_io_rd && ata_cs),
            .io_addr(device_io_addr));
endmodule
"""
IO_DEV_BAD = """module io_dev (input clk, input io_wr, input io_rd, input [15:0] io_addr);
  reg [7:0] r;
  always @(posedge clk) if (io_wr) r <= 8'd1;
endmodule
"""

MEM_BAD = """module pc9821_memory_subsystem (input clk, input mem_resp_valid, input loader_owns,
    output reg beat, output tap);
  assign tap = mem_resp_valid;
  always @(posedge clk) beat <= mem_resp_valid && !loader_owns;
endmodule
"""
MEM_GOOD = MEM_BAD.replace("assign tap = mem_resp_valid;", "assign tap = mem_resp_valid && !loader_owns;")


def tree_from(files):
    mods = {}
    for path, text in files.items():
        for m in parse_modules(path, text):
            mods[m.name] = m
    return mods


def selftest():
    fails = []

    def case(label, files, want, families=FAMILIES):
        """want: dict {family: expected hit count (>=1 means at least that many distinct lines)}"""
        hits = analyse(tree_from(files), families)
        got = {}
        for h in hits:
            got[h.family] = got.get(h.family, 0) + 1
        for fam, n in want.items():
            have = got.get(fam, 0)
            if (n == 0 and have != 0) or (n > 0 and have < n):
                fails.append("%s: family %s wanted %s hit(s), got %d: %s" % (
                    label, fam, n, have, "; ".join(str(h) for h in hits)))
        for fam in got:
            if fam not in want:
                fails.append("%s: unexpected hits in %s: %s" % (
                    label, fam, "; ".join(str(h) for h in hits)))

    def sd_tree(child, name="pc9821_block_io", extra_inst=""):
        inst = ("%s u (.clk(clk), .sd_ack(sd_ack[0]), .sd_buff_wr(sd_buff_wr), "
                ".sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout));" % name)
        return {"z486_mister.sv": TOP % inst, "child.sv": child}

    # control: the corrected block_io is clean (the check must not cry wolf)
    case("block_io fixed", sd_tree(BLOCK_IO_GOOD), {})
    # the original defect, through a bare forward from the top, caught in the callee
    case("block_io original defect", sd_tree(BLOCK_IO_BAD), {"sd_hps": 1})
    # strobe qualified but the data bus used bare
    inst = ("bus_user u (.clk(clk), .sd_ack(sd_ack[0]), .sd_buff_wr(sd_buff_wr), "
            ".sd_buff_dout(sd_buff_dout), .q());")
    case("bus used bare", {"z486_mister.sv": TOP % inst, "c.sv": BUS_BAD}, {"sd_hps": 1})
    case("bus qualified", {"z486_mister.sv": TOP % inst, "c.sv": BUS_GOOD}, {})
    # a registered strobe whose consumer never sees the select
    inst = "reg_user u (.clk(clk), .sd_ack(sd_ack[0]), .sd_buff_wr(sd_buff_wr), .w());"
    case("registered strobe, no select", {"z486_mister.sv": TOP % inst, "c.sv": REG_BAD},
         {"sd_hps": 1})
    case("registered strobe, select in if()", {"z486_mister.sv": TOP % inst,
                                                "c.sv": REG_GOOD_CTX}, {})
    # a use written directly in the top level (a non-bare connection with no select)
    inst = "blk u (.clk(clk), .wr(sd_buff_wr & clk));"
    case("non-bare connection", {"z486_mister.sv": TOP % inst,
                                 "c.sv": "module blk (input clk, input wr); endmodule"},
         {"sd_hps": 1})
    # forwarded into a module that is not in the tree
    inst = "mystery u (.wr(sd_buff_wr));"
    case("forward into an unscanned module", {"z486_mister.sv": TOP % inst}, {"sd_hps": 1})
    # ioctl
    inst = ("ld u (.clk(clk), .ioctl_index(16'd0), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), "
            ".ioctl_download(1'b1), .we());")
    case("ioctl unqualified", {"z486_mister.sv": TOP % inst, "c.sv": IOCTL_BAD}, {"ioctl": 1})
    case("ioctl qualified", {"z486_mister.sv": TOP % inst, "c.sv": IOCTL_GOOD}, {})
    # I/O bus: an unqualified non-bare connection, an unqualified wire, and a callee with no decode
    case("io bus unqualified", {"s.sv": SYSTEM_BAD, "d.sv": IO_DEV_BAD}, {"io_bus": 2})
    case("io bus qualified", {"s.sv": SYSTEM_GOOD, "d.sv": IO_DEV_BAD}, {})
    # shared response valid
    case("mem_resp unqualified", {"m.sv": MEM_BAD}, {"mem_resp": 1})
    case("mem_resp qualified", {"m.sv": MEM_GOOD}, {})
    # sim-only observers are not consumers
    obs = MEM_GOOD.replace("endmodule", "  always @(posedge clk) if (mem_resp_valid) "
                           "$fatal(1, \"x\");\nendmodule")
    case("observer not a use", {"m.sv": obs}, {})
    # the ledger is shrink-only
    hits = analyse(tree_from(sd_tree(BLOCK_IO_BAD)), FAMILIES)
    if not hits:
        fails.append("ledger test has no hit to ledger")
    else:
        h = hits[0]
        led = [dict(file=h.path, family=h.family, signal=h.signal, name=h.name, reason="t")]
        left, stale = apply_ledger(hits[:1], led)
        if left or stale:
            fails.append("a matching ledger entry should excuse its hit and not be stale")
        left, stale = apply_ledger([], led)
        if not stale:
            fails.append("a ledger entry with no hit must be reported stale")
    return fails


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--verbose", action="store_true", help="print the shared-name spread")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--root", default=str(ROOT))
    a = ap.parse_args()
    global VERBOSE
    VERBOSE = a.verbose
    if a.list:
        for f in FAMILIES:
            print("%-9s seeds=%s qualifier=/%s/\n          %s" % (
                f.name, f.seeds, f.qualifier.pattern, f.why))
        print("\nAudited, not checked:")
        for k, v in NOT_CHECKED.items():
            print("  %s: %s" % (k, v))
        return 0
    if a.selftest:
        fails = selftest()
        for f in fails:
            print("SELFTEST FAIL:", f)
        if fails:
            return 1
        print("check_shared_strobes selftest: PASS (the original block_io defect and every other "
              "plant caught; the qualified controls clean)")
        # and the tree itself must still parse into the modules the seeds name
    root = pathlib.Path(a.root)
    mods = load_tree(root)
    for f in FAMILIES:
        for seed in f.seeds:
            if seed not in mods:
                print("check_shared_strobes: FAIL - seed module '%s' (family %s) not found under "
                      "%s" % (seed, f.name, root))
                return 1
    left, stale = apply_ledger(analyse(mods, FAMILIES), LEDGER_DICTS)
    for h in left:
        print(h)
    for e in stale:
        print("STALE LEDGER ENTRY (no hit matches it any more - delete it): %s" % e)
    if left or stale:
        print("check_shared_strobes: FAIL - %d unqualified use(s), %d stale ledger entr%s" % (
            len(left), len(stale), "y" if len(stale) == 1 else "ies"))
        return 1
    print("check_shared_strobes: PASS (%d modules scanned, %d ledger entries)" % (
        len(mods), len(LEDGER)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

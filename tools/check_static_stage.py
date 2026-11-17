#!/usr/bin/env python3
"""check_static_stage.py -- a free-running stage on a static input is a pc9821_static_stage.

THE CLASS. A timing cut of one shape recurs in the storage blocks: a value consumed at a strobe is
registered behind DEPTH free-running clk_sys stages because its inputs are static for many cycles
before the strobe (PLAY AUDIO MSF's CDB bytes, the HDI header and the probed drive's size, the D88
verdict, hps_io's image size behind the mount/eject event). Written by hand, each stage carried its
own prose argument and its own sim-only check, comparing the staged and combinational values at a
consume point behind gates that differed site by site. src/pc9821/common/pc9821_static_stage.sv
is that stage with the premise asserted once (d unchanged over the last DEPTH cycles at every
strobe), so every such cut states its DEPTH and its strobe in one line.

THREE CHECKS.
  1 STAGES. In every file of SCAN (the storage blocks and the mount/eject seam), an `always @(posedge
    clk)` block that is a pure free-running stage - no if/case/for, only `reg <= expr;` statements -
    must not exist unless each register it writes is in ALLOWED with the reason it is not a static
    stage (an edge detector, an event pipeline, a registered handshake). A new hand-built stage, or
    one that loses its pc9821_static_stage, fails here.
  2 INSTANCES. Every pc9821_static_stage instance under src/ states its .W and .DEPTH and connects
    .chk_en to a strobe: a constant (1'b0, 1'b1, 0, 1) is not a strobe, and a stage whose check can
    never fire, or always fires, argues nothing. The instances found are counted per file, and the
    files holding the migrated cuts (EXPECTED) must hold at least the recorded number, so a cut
    that is quietly reverted to a hand-built register is caught by check 1 or by this count.
  3 FENCING. Simulation-only code under src/pc9821 is fenced ONE way: `// synthesis translate_off`
    ... `// synthesis translate_on`, which Quartus, yosys and the tools that pre-strip it read alike.
    The other spellings (`ifndef SYNTHESIS / `ifdef SYNTHESIS, a bare `// translate_off`, `synopsys
    translate_off`) fail, and every translate_off must close with a translate_on before the next one
    and before endmodule.

Run:  python3 tools/check_static_stage.py             check the tree
      python3 tools/check_static_stage.py --selftest  plant each defect; each must be caught
      python3 tools/check_static_stage.py --list      print the instances and the allowed stages
Exit 0 = clean, 1 = a finding or a self-test failure.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

PRIM = "pc9821_static_stage"
PRIM_FILE = "src/pc9821/common/pc9821_static_stage.sv"

# Check 1's scope: the files whose free-running stages are the static-input class.
SCAN = sorted(["src/pc9821/core/pc9821_mount_eject.sv"] +
              [str(p.relative_to(ROOT)) for p in (ROOT / "src/pc9821/storage").glob("*.sv")])

# (file, register): a pure free-running block that is NOT a static-input stage, with the reason.
ALLOWED = {
    ("src/pc9821/core/pc9821_mount_eject.sv", "eject_q"):
        "the OSD bit's previous level, for its rising edge (an edge detector)",
    ("src/pc9821/core/pc9821_mount_eject.sv", "pend"):
        "the pending-eject set, a merge of events (R7), not a stage",
    ("src/pc9821/core/pc9821_mount_eject.sv", "hps_d"):
        "hps_io's mount event delayed one cycle: an event, not a static value",
    ("src/pc9821/core/pc9821_mount_eject.sv", "mounted_q"):
        "the registered output event: an event, not a static value",
    ("src/pc9821/storage/pc9821_fdc.sv", "adv_q"):
        "the registered handoff to the medium (T84): one event per byte, a handshake",
    ("src/pc9821/storage/pc9821_fdc.sv", "abort_q"):
        "the registered handoff's abort event (T84), shifted with adv_q",
    ("src/pc9821/storage/pc9821_fdc.sv", "din_q"):
        "the byte carried with adv_q (T84): data of an event, read only with it",
    ("src/pc9821/storage/pc9821_fdc.sv", "chg_q"):
        "the medium's change tag as last seen, for its change (an edge detector)",
    ("src/pc9821/storage/pc9821_ata.sv", "sector_word_q"):
        "the sector buffer's registered M10K read port: its address moves every cycle",
    ("src/pc9821/storage/pc9821_block_io.sv", "hs_ack"):
        "hps_io's sector stream one stage in, the slot's acknowledge: an event pipeline (the whole stream moves together), not a static value",
    ("src/pc9821/storage/pc9821_block_io.sv", "hs_wr"):
        "hps_io's sector stream one stage in, the word strobe: an event pipeline (the whole stream moves together), not a static value",
    ("src/pc9821/storage/pc9821_block_io.sv", "hs_addr"):
        "hps_io's sector stream one stage in, the word's index: an event pipeline (the whole stream moves together), not a static value",
    ("src/pc9821/storage/pc9821_block_io.sv", "hs_dout"):
        "hps_io's sector stream one stage in, the word: an event pipeline (the whole stream moves together), not a static value",
    ("src/pc9821/storage/pc9821_atapi.sv", "hs_ack"):
        "hps_io's sector stream one stage in, the slot's acknowledge: an event pipeline (the whole stream moves together), not a static value",
    ("src/pc9821/storage/pc9821_atapi.sv", "hs_wr"):
        "hps_io's sector stream one stage in, the word strobe: an event pipeline (the whole stream moves together), not a static value",
    ("src/pc9821/storage/pc9821_atapi.sv", "hs_addr"):
        "hps_io's sector stream one stage in, the word's index: an event pipeline (the whole stream moves together), not a static value",
    ("src/pc9821/storage/pc9821_atapi.sv", "hs_dout"):
        "hps_io's sector stream one stage in, the word: an event pipeline (the whole stream moves together), not a static value",
    ("src/pc9821/storage/pc9821_atapi.sv", "buf_q"):
        "the buffer's registered block-RAM read port: its address moves every cycle",
    ("src/pc9821/storage/pc9821_atapi.sv", "vh_q"):
        "the ISO's synthesised header word, registered to match the RAM read beside it",
    ("src/pc9821/storage/pc9821_atapi.sv", "rom_q"):
        "the identify/inquiry/mode-sense ROM's registered read port",
    ("src/pc9821/storage/pc9821_atapi.sv", "lg_st_d"):
        "LOG_EN: the FSM state as last seen, for the log's phase-change event",
    ("src/pc9821/storage/pc9821_atapi.sv", "lg_loaded_d"):
        "LOG_EN: the medium-loaded level as last seen, for the log's ready event",
    ("src/pc9821/storage/pc9821_atapi.sv", "lg_rst_d"):
        "LOG_EN: the reset level as last seen, for the log's reset event",
    ("src/pc9821/storage/pc9821_atapi.sv", "lg_cmd_d"):
        "LOG_EN: the command write one cycle late, for the log's same-cycle completion",
    ("src/pc9821/storage/pc9821_atapi.sv", "lg_daflag_d"):
        "LOG_EN: the player flag as last seen, for the log's player event",
    ("src/pc9821/storage/pc9821_fdd_media.sv", "mnt_lvl_q"):
        "hps_io's mount level as last seen, for its rising edge (an edge detector)",
    ("src/pc9821/storage/pc9821_fdd_media.sv", "chg"):
        "the media-change tag, toggled by each mount edge (a counter of events)",
    ("src/pc9821/storage/pc9821_fdd_media.sv", "blk_rd_data"):
        "the block buffer's registered read port for the host's write-back",
    ("src/pc9821/storage/pc9821_fdd_media.sv", "track_q"):
        "the track table's registered read port: its address moves with each request",
}

# Check 2's floor: the files the static-input cuts were migrated into, and their instance counts.
EXPECTED = {
    "src/pc9821/storage/pc9821_ata.sv": 2,        # the CHS address and checks, the LBA room
    "src/pc9821/storage/pc9821_atapi.sv": 3,      # PLAY AUDIO MSF: bytes, frames, clamps
    "src/pc9821/storage/pc9821_hdd_image.sv": 7,  # size, geometry, file sectors, HDI cap, raw/tail/fits
    "src/pc9821/storage/pc9821_fdd_media.sv": 1,  # the D88 verdict
    "src/pc9821/core/pc9821_mount_eject.sv": 1,   # hps_io's size and flag beside the event
}

FENCE_GLOBS = ["src/pc9821/**/*.sv", "src/pc9821/**/*.v"]


def strip_comments(t):
    """Blank // and /* */ comments and strings, keeping newlines (line numbers survive)."""
    def blank(m):
        return re.sub(r"[^\n]", " ", m.group(0))
    t = re.sub(r"/\*.*?\*/", blank, t, flags=re.S)
    t = re.sub(r"\"(?:[^\"\\\n]|\\.)*\"", blank, t)
    return re.sub(r"//[^\n]*", blank, t)


def strip_sim(t):
    """Blank `// synthesis translate_off` .. `translate_on` regions (simulation-only code)."""
    return re.sub(r"//\s*synthesis\s+translate_off.*?//\s*synthesis\s+translate_on",
                  lambda m: re.sub(r"[^\n]", " ", m.group(0)), t, flags=re.S)


ALWAYS = re.compile(r"\balways(?:_ff)?\s*@\s*\(\s*posedge\s+\w+\s*\)")


def block_after(t, pos):
    """The statement text of the always block whose sensitivity list ends at pos, and its end."""
    m = re.compile(r"\s*").match(t, pos)
    p = m.end()
    if t.startswith("begin", p) and not re.match(r"\w", t[p + 5:p + 6] or " "):
        depth, q = 0, p
        for w in re.finditer(r"\b(begin|end)\b", t[p:]):
            depth += 1 if w.group(1) == "begin" else -1
            if depth == 0:
                q = p + w.end()
                return t[p + 5:p + w.start()], q
        return t[p + 5:], len(t)
    q = t.find(";", p)
    return t[p:q + 1], q + 1


def pure_stages(text):
    """[(line, [regs])] for every always block that is a pure free-running stage."""
    t = strip_comments(strip_sim(text))
    out = []
    for m in ALWAYS.finditer(t):
        body, _ = block_after(t, m.end())
        if re.search(r"\b(if|case|casez|casex|for|while|begin)\b", body):
            continue
        stmts = [s.strip() for s in body.split(";") if s.strip()]
        if not stmts or not all(re.match(r"^[\w\[\]:+\-' ]+\s*<=", s) for s in stmts):
            continue
        regs = [re.match(r"^(\w+)", s).group(1) for s in stmts]
        out.append((t.count("\n", 0, m.start()) + 1, regs))
    return out


INST = re.compile(r"\b%s\s*#\s*\((?P<params>.*?)\)\s*(?P<name>\w+)\s*\((?P<ports>.*?)\)\s*;" % PRIM,
                  re.S)


def port_expr(ports, name):
    """The expression connected to .name(...) in a port list (balanced parentheses)."""
    m = re.search(r"\.%s\s*\(" % name, ports)
    if not m:
        return None
    depth, i = 1, m.end()
    while i < len(ports) and depth:
        depth += {"(": 1, ")": -1}.get(ports[i], 0)
        i += 1
    return ports[m.end():i - 1].strip()


def instances(text):
    """[(line, name, params, chk_en)] for every pc9821_static_stage instance."""
    t = strip_comments(strip_sim(text))
    out = []
    for m in INST.finditer(t):
        out.append((t.count("\n", 0, m.start()) + 1, m.group("name"), m.group("params"),
                    port_expr(m.group("ports") + ")", "chk_en")))
    return out


CONST = re.compile(r"^(\d+'[bdhoBDHO]?[0-9a-fA-F_xXzZ]+|\d+|'[01])$")


def check_instances(rel, text):
    probs, n = [], 0
    for line, name, params, chk in instances(text):
        n += 1
        where = "%s:%d (%s)" % (rel, line, name)
        if not re.search(r"\.W\s*\(", params) or not re.search(r"\.DEPTH\s*\(", params):
            probs.append("%s: a %s states .W and .DEPTH explicitly" % (where, PRIM))
        if chk is None or not chk:
            probs.append("%s: .chk_en is not connected (the stage's strobe)" % where)
        elif CONST.match(chk.replace(" ", "")):
            probs.append("%s: .chk_en(%s) is a constant, not a strobe" % (where, chk))
    return probs, n


def check_stages(rel, text):
    probs = []
    for line, regs in pure_stages(text):
        for r in regs:
            if (rel, r) not in ALLOWED:
                probs.append("%s:%d: `%s` is a hand-built free-running stage: make it a %s "
                             "(its DEPTH and its consumer's strobe), or list it in ALLOWED with the "
                             "reason it is not a static-input stage" % (rel, line, r, PRIM))
    return probs


BAD_FENCE = [
    (re.compile(r"^\s*`ifn?def\s+SYNTHESIS\b", re.M), "`ifdef/`ifndef SYNTHESIS"),
    (re.compile(r"^\s*//\s*translate_(off|on)\b", re.M), "a bare `// translate_off/on`"),
    (re.compile(r"synopsys\s+translate_(off|on)"), "`synopsys translate_off/on`"),
    (re.compile(r"/\*\s*synthesis\s+translate_(off|on)"), "a /* */ translate_off/on"),
]


def check_fencing(rel, text):
    probs = []
    for rx, what in BAD_FENCE:
        for m in rx.finditer(text):
            probs.append("%s:%d: %s: sim-only code is fenced `// synthesis translate_off` .. "
                         "`// synthesis translate_on`" % (rel, text.count("\n", 0, m.start()) + 1, what))
    open_at = None
    for m in re.finditer(r"//\s*synthesis\s+translate_(off|on)\b|\bendmodule\b", text):
        line = text.count("\n", 0, m.start()) + 1
        tok = m.group(1) or "endmodule"
        if tok == "off":
            if open_at:
                probs.append("%s:%d: translate_off inside the one opened at line %d" % (rel, line, open_at))
            open_at = line
        elif tok == "on":
            if not open_at:
                probs.append("%s:%d: translate_on with no translate_off open" % (rel, line))
            open_at = None
        elif open_at:
            probs.append("%s:%d: endmodule inside the translate_off opened at line %d" % (rel, line, open_at))
            open_at = None
    return probs


def fence_files(root):
    seen = set()
    for g in FENCE_GLOBS:
        for p in sorted(root.glob(g)):
            if p not in seen:
                seen.add(p)
                yield p


def run(root, files=None):
    """All findings for the tree at root; files (rel -> text) overrides what is read from disk."""
    files = files or {}

    def read(rel):
        if rel in files:
            return files[rel]
        p = root / rel
        return p.read_text(encoding="utf-8", errors="replace") if p.exists() else None

    probs = []
    if read(PRIM_FILE) is None:
        probs.append("%s: the primitive is missing" % PRIM_FILE)
    for rel in SCAN:
        t = read(rel)
        if t is not None:
            probs += check_stages(rel, t)
    counts = {}
    rels = sorted({str(p.relative_to(root)) for p in root.glob("src/**/*.sv")} | set(files))
    for rel in rels:
        if rel.startswith(("src/z486/", "src/opna/")) or rel == PRIM_FILE:
            continue
        t = read(rel)
        if t is None or PRIM not in t:
            continue
        p, n = check_instances(rel, t)
        probs += p
        counts[rel] = n
    for rel, want in EXPECTED.items():
        if counts.get(rel, 0) < want:
            probs.append("%s: %d %s instance(s), the migrated cuts are %d" %
                         (rel, counts.get(rel, 0), PRIM, want))
    for p in fence_files(root):
        rel = str(p.relative_to(root))
        probs += check_fencing(rel, read(rel))
    for rel in sorted(files):
        if rel.startswith("src/pc9821/") and not (root / rel).exists():
            probs += check_fencing(rel, files[rel])
    stale = [k for k in ALLOWED if read(k[0]) is None or
             k[1] not in {r for _, regs in pure_stages(read(k[0])) for r in regs}]
    for f, r in stale:
        probs.append("ALLOWED entry (%s, %s) matches no free-running block any more: remove it" % (f, r))
    return probs, counts


def selftest():
    """Plant each defect class in a copy of a real file; each must be caught, the clean tree not."""
    fails = []
    base, _ = run(ROOT)
    if base:
        fails.append("the clean tree has findings: %s" % base[:3])

    def plant(rel, a, b, expect, label):
        t = (ROOT / rel).read_text(encoding="utf-8")
        if t.count(a) != 1:
            fails.append("%s: plant anchor not found once in %s" % (label, rel))
            return
        probs, _ = run(ROOT, {rel: t.replace(a, b)})
        if not any(expect in p for p in probs):
            fails.append("%s: not caught (findings: %s)" % (label, probs[:3]))

    me = "src/pc9821/core/pc9821_mount_eject.sv"
    fdd = "src/pc9821/storage/pc9821_fdd_media.sv"
    # 1: the D88 verdict hand-staged again (the pre-primitive form)
    plant(fdd, "  wire d88_looks_valid_q;\n",
          "  reg d88_looks_valid_q;\n  always @(posedge clk) d88_looks_valid_q <= d88_looks_valid;\n",
          "hand-built free-running stage", "hand stage")
    # 1: a begin/end form of the same
    plant(me, "    mounted_q  <= hps_d | issue;\n",
          "    mounted_q  <= hps_d | issue;\n    stale_q    <= hps_size;\n",
          "`stale_q` is a hand-built", "hand stage in an allowed block")
    # 2: a stage whose strobe is tied off
    plant(fdd, "      .chk_en(!reset && (st == ST_PARSE) && !walk_en && !abort_now));",
          "      .chk_en(1'b0));", "is a constant", "tied-off strobe")
    # 2: DEPTH left to its default
    plant(fdd, "  pc9821_static_stage #(.W(1), .DEPTH(1)) u_d88_valid (",
          "  pc9821_static_stage #(.W(1)) u_d88_valid (", "states .W and .DEPTH", "implicit DEPTH")
    # 2: an instance removed (the count floor)
    t = (ROOT / fdd).read_text(encoding="utf-8")
    a = t.index("  pc9821_static_stage #(.W(1), .DEPTH(1)) u_d88_valid (")
    b = t.index(";", a) + 1
    probs, _ = run(ROOT, {fdd: t[:a] + "  assign d88_looks_valid_q = d88_looks_valid;" + t[b:]})
    if not any("instance(s), the migrated cuts are" in p for p in probs):
        fails.append("removed instance: not caught")
    # 3: the other fence spellings and an unclosed fence
    plant(me, "  // synthesis translate_off\n", "`ifndef SYNTHESIS\n", "SYNTHESIS", "`ifndef SYNTHESIS")
    plant(me, "  // synthesis translate_off\n", "  // translate_off\n", "bare", "bare translate_off")
    plant(me, "  // synthesis translate_on\n", "", "endmodule inside", "unclosed translate_off")
    # ALLOWED stays honest: an entry whose block is gone is stale
    plant(me, "    hps_d      <= hps_mounted;\n    mounted_q  <= hps_d | issue;\n  end\n",
          "    if (1'b1) hps_d <= hps_mounted;\n    mounted_q  <= hps_d | issue;\n  end\n",
          "matches no free-running block", "stale ALLOWED entry")
    for f in fails:
        print("SELFTEST FAIL: " + f)
    print("check_static_stage selftest: %s (%d plants)" % ("FAIL" if fails else "PASS", 9))
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    probs, counts = run(ROOT)
    if a.list:
        for rel in sorted(counts):
            for line, name, params, chk in instances((ROOT / rel).read_text(encoding="utf-8")):
                print("%s:%d %s #(%s) chk_en=%s" % (rel, line, name, " ".join(params.split()), " ".join(chk.split())))
        for (f, r), why in sorted(ALLOWED.items()):
            print("allowed %s %s: %s" % (f, r, why))
    for p in probs:
        print("FAIL: " + p)
    print("check_static_stage: %s (%d instances in %d files, %d scanned for hand-built stages)"
          % ("FAIL" if probs else "PASS", sum(counts.values()), len(counts), len(SCAN)))
    return 1 if probs else 0


if __name__ == "__main__":
    sys.exit(main())

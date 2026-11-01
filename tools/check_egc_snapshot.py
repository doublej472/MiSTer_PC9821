#!/usr/bin/env python3
"""check_egc_snapshot.py -- the observation lemma behind pc9821_egc's narrowed snapshot (C3).

pc9821_egc latches the EGC's eight configuration registers at each access's S_IDLE accept
(`acc_*`, so a guest write landing mid-op cannot change the op). The image used to be 128 flops
(the eight guest words); it now keeps only the bits a cone decodes - 91 flops instead of 128, in
five of the eight registers (acc_fg/acc_mask/acc_bg are untouched). This tool is the proof that
the narrowing is unobservable. It has three parts, and each one FAILS when the RTL moves away from
the claim:

1. THE WRITERS. Each narrowed register has exactly two procedural assignments: the reset arm's
   constant and S_IDLE's accept from the `reg_*` port. A third writer is the one change a
   mapping proof cannot see, so it is refused here.

2. THE READS. Every read of a narrowed register in the file selects bits inside the declared
   vector. (Verilator's SELRANGE also makes a dropped-bit read a build error; this names it and
   covers the reads Verilator would silently widen.)

3. THE MAPPING, BY SAT. A harness generated from the file's OWN text - the accept expressions,
   the reset constants, the fence's retained-slice projections and every consumer expression -
   is proved by yosys for EVERY 16-bit guest value: each consumer of the narrowed field equals
   the same consumer fed the full-width field, at the bit the guest wrote. A second harness is
   the one-step induction over the snapshot's only two writers: assuming the invariant in the
   previous state, it holds after reset, after an accept (for ALL guest values) and after a
   hold. The harness text is extracted from pc9821_egc.sv by anchored search, so a change to
   any of those expressions enters the proof instead of stepping around it.

What this does NOT prove: the module's other state or its sequence. The `ifdef VERILATOR` fence
at the end of pc9821_egc.sv runs the same equality in every cycle of every bench that builds the
module, and the EGC benches are the behavioural pin.

  python3 tools/check_egc_snapshot.py
  python3 tools/check_egc_snapshot.py --selftest     # plants seven defects; each must be caught
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EGC = "src/pc9821/core/pc9821_egc.sv"

# (register, declared width, the guest-visible reset image of the FULL-width field - NP2kai
#  egc_reset, the values the pre-C3 snapshot held - and the projection the VERILATOR fence
#  compares the narrowed register against). The reset constants and the accept expressions are
#  NOT copied here: they are extracted from pc9821_egc.sv below and enter the proof as the
#  file's own text, with the shadow's reset pinned to the full-width image.
SNAP = [
    ("access", 4, "16'hFFF0", "acc_ref_access[3:0]"),
    ("fgbg", 4, "16'h00FF", "{acc_ref_fgbg[9:8], acc_ref_fgbg[14:13]}"),
    ("ope", 14, "16'h0000", "acc_ref_ope[13:0]"),
    ("sft", 9, "16'h0000", "{acc_ref_sft[12], acc_ref_sft[7:0]}"),
    ("leng", 12, "16'h000F", "acc_ref_leng[11:0]"),
]

# (name, the anchored form the file writes, the guest bit the consumer must still read). The
# expression itself is EXTRACTED from the file (never copied into this tool), so the SAT below
# proves the file's own consumer against the pre-narrowing guest bit: a slid index, a swapped
# field or a wrong packing fails the proof, it does not just disagree with a table here.
CONSUMERS = [
    ("fgbg_sel", "wire [1:0]  fgbg_sel   = %s;", "x_fgbg[14:13]"),
    ("read_plane", "wire [1:0]  read_plane = %s;", "x_fgbg[9:8]"),
    ("sft_src8", "wire [2:0] sft_src8 = %s;", "x_sft[2:0]"),
    ("sft_dst8", "wire [2:0] sft_dst8 = %s;", "x_sft[6:4]"),
    ("sft_dir", "wire       sft_dir  = %s;", "x_sft[12]"),
    ("ope_cmprd", "wire        ope_cmprd  = %s;", "x_ope[13]"),
    ("ope_sftcpu", "wire        ope_sftcpu = %s;", "x_ope[10]"),
    ("ope_mode", "wire [1:0]  ope_mode   = %s;", "x_ope[12:11]"),
    ("pat_rd", "wire        pat_rd     = %s;", "(x_ope[9:8] == 2'b01)"),
    ("pat_wr", "wire        pat_wr     = %s;", "(x_ope[9:8] == 2'b10)"),
    ("rop_needs_dst", "wire rop_needs_dst = %s;",
     "|((x_ope[7:0] ^ (x_ope[7:0] >> 2)) & 8'h33)"),
]
# The plane enables are four assigns over acc_access[0..3].
PLANE_EN = "assign plane_en[%d] = !%s;"
# The ROP table's ternary index is the one consumer whose INDEX is data; it must still be the
# 8-entry table table (a leading constant 0), and it must select the same guest bit.
ROP_INDEX = "assign rop_b[gb] = acc_ope[%s];"


def read_egc():
    return open(os.path.join(REPO, EGC)).read()


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


class LemmaError(Exception):
    """The file no longer matches the lemma's claim; the message names the claim it lost."""


def find_one(text, pattern, what):
    """The single match of an anchored pattern, or a failure naming the claim it lost."""
    hits = re.findall(pattern, text)
    if len(hits) != 1:
        raise LemmaError("%s: expected exactly one match of %r, found %d"
                         % (what, pattern, len(hits)))
    return hits[0] if isinstance(hits[0], str) else hits[0][0]


def capture(text, template, what, *args):
    """The captured expression in `template`, where `%s` is the capture and `args` fill the rest."""
    pre, suf = template.split("%s")
    if args:
        pre = pre % args
    return find_one(text, re.escape(pre) + "([^;]+)" + re.escape(suf), what)


def writers(text, name):
    """(the reset constant, the accept expression) as the file writes them, or a LemmaError."""
    got = [x.strip() for x in re.findall(r"\b%s\s*<=\s*([^;]+);" % name, strip_comments(text))]
    const = [g for g in got if re.fullmatch(r"\d+'h[0-9a-fA-F_]+", g)]
    port = [g for g in got if "reg_" in g]
    if len(got) != 2 or len(const) != 1 or len(port) != 1:
        raise LemmaError("%s's writers are %s: want exactly one reset constant and one accept "
                         "from the reg_* port" % (name, got))
    return const[0], port[0]


def check_writers(text):
    """Part 1: two writers per register, and the shadow's reset is the guest-visible image."""
    problems = []
    for reg, _w, full_rst, _proj in SNAP:
        for name in ("acc_%s" % reg, "acc_ref_%s" % reg):
            try:
                writers(text, name)
            except LemmaError as e:
                problems.append(str(e))
        try:
            rst, _acc = writers(text, "acc_ref_%s" % reg)
        except LemmaError:
            continue
        if rst != full_rst:
            problems.append("acc_ref_%s resets to %s, the guest-visible image is %s"
                            % (reg, rst, full_rst))
    return problems


def check_reads(text):
    """Part 2: every read selects inside the declared vector."""
    body = strip_comments(text)
    problems = []
    widths = {r: w for r, w, *_ in SNAP}
    # The declaration lines and every assignment LHS are not reads.
    body = re.sub(r"reg\s*\[[^\]]*\]\s*acc_[a-z]+;", "", body)
    body = re.sub(r"acc_(?:access|fgbg|ope|sft|leng)\s*<=", "", body)
    body = re.sub(r"acc_ref_[a-z]+\s*<=", "", body)
    for m in re.finditer(r"\bacc_(access|fgbg|ope|sft|leng)\b(\s*\[([^\]]+)\])?", body):
        reg, idx = m.group(1), m.group(3)
        if idx is None:
            continue                      # the whole vector: every declared bit is retained
        rng = re.fullmatch(r"\s*(\d+)\s*(?::\s*(\d+)\s*)?", idx)
        if rng is None:
            # A data-dependent index: the ROP table's, bounded by its leading constant 0.
            if not re.search(r"acc_ope\[\{\s*1'b0\s*,", body):
                problems.append("%s: data-dependent index %r with no leading constant 0"
                                % (reg, idx))
            continue
        hi = int(rng.group(1))
        lo = int(rng.group(2)) if rng.group(2) is not None else hi
        if hi >= widths[reg] or lo > hi:
            problems.append("%s[%s] reads outside the %d-bit vector %s"
                            % (reg, idx.strip(), widths[reg], reg))
    return problems


def mapping_harness(text):
    """Part 3a: the consumers, fed from the accept expressions, against the guest's own bits."""
    body = text
    lines = []
    for reg, w, _rst, _proj in SNAP:
        _nrst, acc = writers(text, "acc_%s" % reg)
        lines.append("  wire [%d:0] n_%s = %s;" % (w - 1, reg, acc.replace("reg_", "x_")))
    asserts = []
    for name, pat, old in CONSUMERS:
        expr = capture(body, pat, name)
        asserts.append("    assert (%s == %s);   // %s"
                       % (expr.replace("acc_", "n_"), old, name))
    for k in range(4):
        expr = capture(body, PLANE_EN, "plane_en[%d]" % k, k)
        asserts.append("    assert (!%s == !x_access[%d]);   // plane_en[%d]"
                       % (expr.replace("acc_", "n_"), k, k))
    rop = capture(body, ROP_INDEX, "rop_b index")
    if not rop.strip().startswith("{1'b0,"):
        raise LemmaError("the ROP index `%s` is not bounded to the table's 8 entries"
                         % rop.strip())
    asserts.append("    // the ROP table's data index: free src/dst/pat, every reachable index\n"
                   "    assert (n_ope[{1'b0, src_b, dq_w, pat_b}] ==\n"
                   "            x_ope[{1'b0, src_b, dq_w, pat_b}]);")
    return ("module egc_snap_map(\n"
            "  input [15:0] x_access, x_fgbg, x_ope, x_sft, x_leng,\n"
            "  input src_b, dq_w, pat_b\n"
            ");\n" + "\n".join(lines) + "\n"
            "  always @* begin\n" + "\n".join(asserts) + "\n  end\nendmodule\n")


def induction_harness(text):
    """Part 3b: the invariant survives the snapshot's two writers and a hold."""
    body = text
    ports, nxt_n, nxt_w, assume, asserts = [], [], [], [], []
    ports.append("input rst, take")
    ports.append("input [15:0] x_access, x_fgbg, x_ope, x_sft, x_leng")
    for reg, w, full_rst, proj in SNAP:
        rst, acc = writers(body, "acc_%s" % reg)
        ref_rst, ref_acc = writers(body, "acc_ref_%s" % reg)
        proj_n = proj.replace("acc_ref_", "r_")
        ports.append("input [%d:0] p_%s" % (w - 1, reg))
        ports.append("input [15:0] r_%s" % reg)
        assume.append("    assume (p_%s == %s);" % (reg, proj_n))
        nxt_n.append("  wire [%d:0] q_%s = rst ? %s : take ? %s : p_%s;"
                     % (w - 1, reg, rst, acc.replace("reg_", "x_"), reg))
        nxt_w.append("  wire [15:0] qr_%s = rst ? %s : take ? %s : r_%s;"
                     % (reg, ref_rst, ref_acc.replace("reg_", "x_"), reg))
        asserts.append("    assert (q_%s == %s);   // %s" % (reg, proj_n.replace("r_", "qr_"), reg))
        # the shadow's reset is the guest-visible image; the narrowed one must pack it
        asserts.append("    assert (!rst || qr_%s == %s);   // %s's reset image"
                       % (reg, full_rst, reg))
    # The fence's projection is the retained-slice claim; it must still be the one the file has.
    for reg, _w, _r, proj in SNAP:
        find_one(body, r"if \(acc_%s !== " % reg, "fence compare of %s" % reg)
        if ("acc_%s !== %s)" % (reg, proj)) not in body:
            raise LemmaError("the fence's projection of %s is not `%s`"
                             % (reg, proj))
    return ("module egc_snap_ind(\n  " + ",\n  ".join(ports) + "\n);\n"
            + "\n".join(nxt_n) + "\n" + "\n".join(nxt_w) + "\n"
            "  always @* begin\n" + "\n".join(assume) + "\n" + "\n".join(asserts)
            + "\n  end\nendmodule\n")


def yosys_prove(srctext, top):
    with tempfile.TemporaryDirectory() as tmp:
        p = os.path.join(tmp, "h.sv")
        open(p, "w").write(srctext)
        r = subprocess.run(["yosys", "-q", "-p",
                            "read_verilog -sv -formal h.sv; hierarchy -top %s; proc; opt_clean; "
                            "chformal -lower; sat -prove-asserts -set-assumes -verify" % top],
                           cwd=tmp, capture_output=True, text=True)
    ok = r.returncode == 0
    msg = ("proved for every input" if ok else
           (r.stdout + r.stderr).strip().splitlines()[-1] if (r.stdout + r.stderr).strip() else "")
    return ok, msg


def run(text):
    """Every problem the file has against the lemma, at the strongest available proof."""
    problems = check_writers(text) + check_reads(text)
    if problems:
        return problems        # a structural failure invalidates the harness extraction
    try:
        ok, msg = yosys_prove(mapping_harness(text), "egc_snap_map")
        if not ok:
            problems.append("SAT: a consumer of the narrowed image is not the full-width "
                            "consumer (%s)" % msg)
        ok, msg = yosys_prove(induction_harness(text), "egc_snap_ind")
        if not ok:
            problems.append("SAT: the snapshot's invariant is not preserved by its writers (%s)"
                            % msg)
    except LemmaError as e:
        problems.append(str(e))
    return problems


# (name, plant): each must be caught. Substitutions are on the WHOLE file text.
PLANTS = [
    ("a third writer", "      acc_leng   <= reg_leng[11:0];",
     "      acc_leng   <= reg_leng[11:0];\n      acc_leng   <= reg_leng[11:1];"),
    ("a mis-mapped direction bit", "acc_sft    <= {reg_sft[12], reg_sft[7:0]};",
     "acc_sft    <= {reg_sft[13], reg_sft[7:0]};"),
    ("a consumer that slides one bit", "wire [2:0] sft_dst8 = acc_sft[6:4];",
     "wire [2:0] sft_dst8 = acc_sft[5:3];"),
    ("a reset constant that does not pack", "acc_leng   <= 12'h00F;",
     "acc_leng   <= 12'h01F;"),
    ("a read outside the narrowed vector", "assign plane_en[0] = !acc_access[0];",
     "assign plane_en[0] = !acc_access[7];"),
    ("the two fgbg fields swapped", "acc_fgbg   <= {reg_fgbg[9:8], reg_fgbg[14:13]};",
     "acc_fgbg   <= {reg_fgbg[13:12], reg_fgbg[9:8]};"),
    ("a shadow reset that is not the image", "acc_ref_sft    <= 16'h0000;",
     "acc_ref_sft    <= 16'h0100;"),
]


def selftest():
    text = read_egc()
    bad = []
    unplanted = run(text)
    if unplanted:
        bad.append("the unplanted file fails: %s" % unplanted)
    for name, old, new in PLANTS:
        if text.count(old) != 1:
            bad.append("plant %r: anchor occurs %d times" % (name, text.count(old)))
            continue
        problems = run(text.replace(old, new))
        if not problems:
            bad.append("plant %r SURVIVED" % name)
        else:
            print("  plant %-38s caught: %s" % (name, problems[0][:90]))
    if bad:
        print("CHECK_EGC_SNAPSHOT SELFTEST: FAIL")
        for b in bad:
            print("  - " + b)
        return 1
    print("CHECK_EGC_SNAPSHOT SELFTEST: PASS (%d plants)" % len(PLANTS))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    problems = run(read_egc())
    for p in problems:
        print("  - " + p)
    kept = sum(w for _r, w, _f, _p in SNAP)
    print("CHECK_EGC_SNAPSHOT: %s" % ("FAIL" if problems else
          "PASS - %d of 8 registers narrowed, %d + 48 flops instead of 128, every consumer "
          "unchanged for all 2^16 guest values" % (len(SNAP), kept)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

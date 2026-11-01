#!/usr/bin/env python3
"""check_seq_equiv.py -- prove a module's rewrite cycle-identical to an earlier revision of it.

For a ZERO-CYCLE restructuring (a mux moved after a register-free function, a select
duplicated, a decode precomputed from the same registered inputs) the rewritten module keeps
the same registers, so yosys's equivalence flow can match them and prove every register input
and every output equal for every input and every reachable state:

  equiv_make old new; equiv_simple -seq N; equiv_induct -seq N; equiv_status -assert

The old text is `git show REV:FILE`, renamed; the new text is the working tree's. A run that
reports "unproven" cells fails. `--plant OLD=>NEW` mutates the NEW text first, and the run must
then FAIL (a proof that cannot fail proves nothing); each PLANTS entry below is one such check,
run by --selftest.

  python3 tools/check_seq_equiv.py --old REV src/pc9821/<path>.sv
  python3 tools/check_seq_equiv.py --selftest

--pair proves a change that moves logic ACROSS a module boundary: the GRCG + GVRAM arbiter pair,
wired as pc9821_memory_subsystem wires them (tools/equiv/grcg_arb_pair.sv; every other input
free), at --old against the working tree, every output and register of the pair. That is the
proof of the C7-tail cut (docs/timing.md): the arbiter forms its port-A presentation on both arms
of the GRCG capture from the GRCG's raw taps instead of reading the GRCG's muxed outputs.

  python3 tools/check_seq_equiv.py --pair --old 5d7e6412

Since the C7-dc cut the pair's port A is compared as pc9821_gvram_mem reads it (the address under
gma_en, the datum and byte enables under gma_en && gma_we; the wrapper masks the rest), and --pair
also proves that lemma on the real pc9821_gvram_mem (prove_gmem_mask) and that the share's datum
flags are the bytes of its gvr_din (prove_share_flags, C7-dz).

A cut that REMOVES or NARROWS a register cannot be matched by name alone, so a proof can carry its
strengthening: --old-add/--new-add paste text into each copy (a `(* keep *)` wire of one name on both
sides is one more paired cell, so `inv = <predicate>` on the old side against `inv = 1'b1` on the new
is an invariant the induction assumes and re-proves; a wire exposing a narrowed register's value on
both sides pairs it through --blacklist), --with reads submodules both sides share, --new REV takes
the new side from a revision, and prove()'s gate= encodes an instantiator's input contract. The
area cuts are recorded in PROOFS and rerun with plants by

  python3 tools/check_seq_equiv.py --proof all
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (file, old revision, plant anchor, replacement): the clean proof of FILE against REV must pass
# and the planted one must fail.
PAIR_FILES = ("src/pc9821/video/pc9821_grcg.sv", "src/pc9821/core/pc9821_gvram_arb.sv")
PAIR_WRAP = "tools/equiv/grcg_arb_pair.sv"
PAIR_REV = "6b457f7f"   # the pair before the burst-arm cut (the wrapper also proves 5d7e6412, the pair before C7-tail)
# (file, plant anchor, replacement) on the working tree's pair: the --pair proof must FAIL
# Steps whose exactness rests on a STATE invariant (true in every reachable state, not a
# combinational identity): the proof is run with the earlier form substituted back into the working
# tree's text, and the substitution itself is proven by induction in tools/check_arb_resp_inv.py
# (its pq[k].x_gr_d_m == x_gr_d_old assertions, with gstate == G_RMWC -> m_mode).
PAIR_INV_SUBST = [
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "wire  [7:0] x_gr_d_m   = x_wdata[{m_lane[1:0], 3'b000} +: 8];",
     "wire  [7:0] x_gr_d_m   = x_wdata[{x_lane[1:0], 3'b000} +: 8];"),
    # P3 (0b658493) moved a plain LINE read's accept (c_line_ready_q) and gated the walk-end accept
    # on !c_line_mode. The pair is scoped to non-line accesses (the wrapper ties cpu_line_read to 0
    # on both sides, tools/equiv/grcg_arb_pair.sv), and under that tie c_line_mode and
    # c_line_ready_q are 0 in every reachable state: each is reset to 0 and loaded only from
    # cpu_line_read (`c_line_mode <= cpu_line_read;` and `c_line_ready_q <= 1'b1;` inside
    # `if (cpu_line_read)`). So the two terms are identically 0 and are dropped from the new text
    # before the comparison (an old revision that predates P3 has neither).
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "((cs == C_RESP) && !c_line_mode) ||", "(cs == C_RESP) ||"),
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "c_store_ready_q || c_line_ready_q) :", "c_store_ready_q) :"),
]
PAIR_PLANTS = [
    # the timing-cones cut's two plants (the first live lane / any-live test per arm, outside the
    # port-A block: the FSM reads them)
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "cpu_din_datmid[w_first_cap[1:0]]", "cpu_din_datmid[w_first_hold[1:0]]"),
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "(cap_arm ? (|lane_live_cap) : (|lane_live_hold))", "(|lane_live_hold)"),
    # the capture arm's GRCG RMW class read from the latched image
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "      wire        a_rmw    = CAP ? grcg_cl_cap_rmw    : grcg_cl_hold_rmw;",
     "      wire        a_rmw    = grcg_cl_hold_rmw;"),
    # the final select picks the arms the wrong way round for the data only
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "    gma_din  = grcg_cl_cap ? (grcg_cl_cap_burst ? (grcg_cl_cap_pair_high ? pq[3].p_din : pq[2].p_din) : pq[1].p_din) : pq[0].p_din;",
     "    gma_din  = grcg_cl_cap ? (grcg_cl_cap_burst ? (grcg_cl_cap_pair_high ? pq[3].p_din : pq[2].p_din) : pq[0].p_din) : pq[1].p_din;"),
    # the burst arms' select reads the wrong class (high pair taken for the low one)
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "(grcg_cl_cap_pair_high ? pq[3].p_addr : pq[2].p_addr)", "(grcg_cl_cap_pair_high ? pq[2].p_addr : pq[3].p_addr)"),
    # the non-burst capture arm presents the burst's all-ones datum
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "CAP ? (BURST ? 32'hFFFF_FFFF : cpu_din)", "CAP ? 32'hFFFF_FFFF"),
    # the non-GRCG owner's replicated byte reads the wrong lanes
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "wire  [7:0] x_ef_byte_nog = x_wdata[{x_lane_nog, 3'b000} +: 8];",
     "wire  [7:0] x_ef_byte_nog = x_wdata[7:0];"),
    # the merge flag loses its owner AND (it is only the GRCG owner's function)
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "wire        x_gr_merge = cc_owns_grcg && xg_merge;", "wire        x_gr_merge = xg_merge;"),
    # C7-own: the walk decision reads the GRCG owner's form for every owner
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "wire        x_walk_first = cc_owns_grcg ? xg_walk_first : x_walk_first_ng;",
     "wire        x_walk_first = xg_walk_first;"),
    # C7-own: the other owners' hold-arm lane reads the live enables instead of c_be
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "wire  [2:0] x_first_hng = first_live(c_be);", "wire  [2:0] x_first_hng = first_live(cpu_be);"),
    # C7-dc: a walk's word address taken from the client instead of x_base (m_mode walks)
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "wire [15:0] x_ef_addr = {x_base, x_walk_act ? x_lane[1:0] : x_addr[1:0]};",
     "wire [15:0] x_ef_addr = {x_addr[15:2], x_walk_act ? x_lane[1:0] : x_addr[1:0]};"),
    # C7-dc: the single access's burst word presented for every write
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "p_din  = (x_burst_fits && !x_lane_many) ? x_wdata2 : x_ef_data;", "p_din  = x_wdata2;"),
    # P3 scoping: the ready of a non-line access is still compared (owner mux arms swapped)
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "cc_owns_grcg  ? grcg_cpu_ready : egc_cpu_ready;", "cc_owns_grcg  ? egc_cpu_ready : grcg_cpu_ready;"),
    # the owner-substituted live lanes forget the RMW zero-skip
    ("src/pc9821/core/pc9821_gvram_arb.sv",
     "~(xg_rmw_hold ? lane_datum0_hold : 4'd0);", "4'hF;"),
    # the GRCG's capture-arm address loses the TDW high-pair offset
    ("src/pc9821/video/pc9821_grcg.sv",
     "tdw_burst && pair_high ? 2'b10 : 2'b00};",
     "1'b0 ? 2'b10 : 2'b00};"),
]


def pair_wrapper(old, ph=True, side=None, dz=True, lw=True):
    """The wrapper text for one side: PAIR_OLD sections kept for the old side, the others for new."""
    out, keep, stack = [], True, []
    for line in open(os.path.join(REPO, PAIR_WRAP)).read().splitlines():
        t = line.strip()
        if t == "`ifdef PAIR_OLD":
            stack.append(keep); keep = keep and old; continue
        if t == "`ifndef PAIR_OLD":
            stack.append(keep); keep = keep and not old; continue
        if t == "`else":
            outer = stack[-1]; keep = outer and not keep if outer else False; continue
        if t == "`endif":
            keep = stack.pop(); continue
        if keep and (ph or "/*PH*/" not in line) and (dz or "/*DZ*/" not in line) \
                and (lw or "/*LW*/" not in line) and (not lw or "/*LD*/" not in line):
            out.append(line)
    side = side or ("old" if old else "new")
    return ("\n".join(out).replace("PAIR_MOD", "eqv_" + side)
            .replace("GRCG_MOD", side + "_grcg").replace("ARB_MOD", side + "_arb"))


def prove_pair(rev, plant=None, seq=2):
    texts = {}
    old_text = {}
    has_taps = False
    has_ph = True   # the old revision exports/takes pair_high (the wrapper's /*PH*/ lines)
    has_lw = True   # the old revision has P3's word-beat line ports (else the 128-bit cpu_line_dout)
    has_dz = True   # the old revision takes the share's datum flags (the wrapper's /*DZ*/ lines)
    for side in ("old", "new"):
        parts = []
        for rel in PAIR_FILES:
            if side == "old":
                r = subprocess.run(["git", "show", "%s:%s" % (rev, rel)], cwd=REPO,
                                   capture_output=True, text=True)
                if r.returncode:
                    sys.exit("git show failed: " + r.stderr)
                t = r.stdout
                old_text[rel] = t
                if rel.endswith("gvram_arb.sv"):
                    has_ph = "grcg_cl_cap_pair_high" in t
                    has_dz = "cpu_din_z" in t
                    has_lw = "cpu_line_word_valid" in t
                    has_taps = "grcg_cl_cap_burst" in t   # the C7-tail ports (else the muxed cl_* wrapper)
            else:
                t = open(os.path.join(REPO, rel)).read()
                for srel, a, b in PAIR_INV_SUBST:
                    # a revision that already carries the step needs no substitution (and must not
                    # get one: the two texts then agree on the step's own wire)
                    if srel == rel and a not in old_text.get(rel, ""):
                        if t.count(a) != 1:
                            sys.exit("invariant substitution anchor must occur exactly once: %s" % a)
                        t = t.replace(a, b)
                if plant and plant[0] == rel:
                    if t.count(plant[1]) != 1:
                        sys.exit("plant anchor must occur exactly once: %s" % plant[1])
                    t = t.replace(plant[1], plant[2])
            name = module_name(t)
            short = "grcg" if "grcg" in name else "arb"
            parts.append(t.replace("module %s" % name, "module %s_%s" % (side, short), 1))
        parts.append(pair_wrapper(side == "old" and not has_taps, side != "old" or has_ph, side,
                                  side != "old" or has_dz, side != "old" or has_lw))
        texts[side] = "\n".join(parts)
    with tempfile.TemporaryDirectory() as tmp:
        for side, t in texts.items():
            open(os.path.join(tmp, side + ".sv"), "w").write(t)
        # The per-arm port-A presentation registers are compared through the masked port (the
        # wrapper's gma_* outputs, C7-dc), not by name: their unobserved values may differ.
        open(os.path.join(tmp, "black.txt"), "w").write("".join(
            "\\u_arb.pq[%d].%s\n" % (k, n) for k in range(4) for n in ("p_addr", "p_din", "p_be"))
            + "".join("\\%s\n" % n for n in ("gma_addr_raw", "gma_din_raw", "gma_be_raw", "u_arb.gma_addr",
                                                "u_arb.gma_din", "u_arb.gma_be")))
        script = ("read_verilog -sv old.sv; read_verilog -sv new.sv; proc; opt_clean; "
                  "memory; flatten; hierarchy -check; "
                  "equiv_make -blacklist black.txt eqv_old eqv_new eq; hierarchy -top eq; "
                  "equiv_simple -seq %d; equiv_induct -seq %d; equiv_status -assert" % (seq, seq))
        r = subprocess.run(["yosys", "-p", script], cwd=tmp, capture_output=True, text=True)
    ok = r.returncode == 0 and "Equivalence successfully proven!" in r.stdout
    summary = [ln.strip() for ln in r.stdout.splitlines() if "are proven" in ln]
    return ok, (summary[-1] if summary else r.stdout[-1500:] + r.stderr[-800:])


SHARE = "src/pc9821/core/pc9821_gvram_share.sv"
SHARE_PROP = """
  // ---- check_seq_equiv.py (pasted into a copy; never in the tree) ----
  always @* begin
    assert (gvr_din_z == {(gvr_din[31:24] == 8'h00), (gvr_din[23:16] == 8'h00),
                          (gvr_din[15:8] == 8'h00), (gvr_din[7:0] == 8'h00)});
    assert (gvr_din_f == {(gvr_din[31:24] == 8'hFF), (gvr_din[23:16] == 8'hFF),
                          (gvr_din[15:8] == 8'hFF), (gvr_din[7:0] == 8'hFF)});
  end
"""
SHARE_PLANTS = [
    ("  assign gvr_din_z      = gdc_own_q ? bytes_00(gdc_din) : bytes_00(cpu_din);",
     "  assign gvr_din_z      = gdc_own_q ? bytes_00(cpu_din) : bytes_00(cpu_din);"),
    ("  assign gvr_din_f      = gdc_own_q ? bytes_ff(gdc_din) : bytes_ff(cpu_din);",
     "  assign gvr_din_f      = gdc_own_q ? bytes_ff(gdc_din) : bytes_00(cpu_din);"),
]


def prove_share_flags(plant=None):
    """The pair wrapper forms the datum flags from gvr_din (its /*DZ*/ lines); this proves the
    share's own flags are that function of its gvr_din in EVERY state (the registers free)."""
    t = open(os.path.join(REPO, SHARE)).read()
    if plant:
        if t.count(plant[0]) != 1:
            sys.exit("plant anchor must occur exactly once: %s" % plant[0])
        t = t.replace(plant[0], plant[1])
    while "// synthesis translate_off" in t:
        a = t.index("// synthesis translate_off")
        t = t[:a] + t[t.index("// synthesis translate_on", a) + len("// synthesis translate_on"):]
    k = t.rindex("endmodule")
    t = t[:k] + SHARE_PROP + t[k:]
    with tempfile.TemporaryDirectory() as tmp:
        open(os.path.join(tmp, "share.sv"), "w").write(t)
        r = subprocess.run(["yosys", "-q", "-p", "read_verilog -sv -formal share.sv; proc; "
                            "chformal -lower; flatten; opt_clean; dffunmap; sat -tempinduct -prove-asserts "
                            "-set-init-zero -verify"],
                           cwd=tmp, capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr)[-1500:]


GMEM = "src/pc9821/core/pc9821_gvram_mem.sv"
GMEM_NAMES = ["mem0", "mem1", "mem2", "mem3", "wr_any", "lane_we", "a_dout", "b_rd", "rdw_hit_q",
              "rdw_din_q", "rdw_be_q", "rdw_hit", "b_dout", "a_addr", "a_din", "a_be", "a_we"]
GMEM_PLANTS = [
    # the array read ignores a_en (it would observe the address of an idle cycle)
    ("    if (a_en) a_dout <= {mem3[a_addr], mem2[a_addr], mem1[a_addr], mem0[a_addr]};",
     "    a_dout <= {mem3[a_addr], mem2[a_addr], mem1[a_addr], mem0[a_addr]};"),
    # the read-during-write bypass forgets the write qualifier
    ("  wire rdw_hit = a_en && a_we && (a_addr == b_addr);", "  wire rdw_hit = a_en && (a_addr == b_addr);"),
]


def prove_gmem_mask(plant=None):
    """THE LEMMA THE MASKED PAIR PROOF RESTS ON (C7-dc): pc9821_gvram_mem observes a_addr only under
    a_en, a_we only under a_en, and a_din/a_be only under a_en && a_we. Two copies of the REAL module
    body (its arrays cut to four words, the address to two bits) run side by side from one reset
    image; their inputs agree only on that masked view (assumed), every other bit is free, and
    both copies' outputs (with their arrays and read registers as the induction's strengthening)
    are proven equal in every reachable cycle."""
    t = open(os.path.join(REPO, GMEM)).read()
    if plant:
        if t.count(plant[0]) != 1:
            sys.exit("plant anchor must occur exactly once: %s" % plant[0])
        t = t.replace(plant[0], plant[1])
    body = t[t.index(");", t.index("module pc9821_gvram_mem")) + 2:t.rindex("endmodule")]
    body = body.replace("[0:65535]", "[0:3]")

    def copy(x):
        b = body
        for n in GMEM_NAMES:
            b = re.sub(r"\b%s\b" % n, "%s_%s" % (x, n), b)
        return b
    mems = "".join("    assert (A_mem%d[%d] == B_mem%d[%d]);\n" % (m, i, m, i)
                   for m in range(4) for i in range(4))
    top = ("module gm_prod(input wire clk, input wire a_en, input wire [1:0] aA, input wire [1:0] aB,\n"
           "  input wire [31:0] dA, input wire [31:0] dB, input wire [3:0] beA, input wire [3:0] beB,\n"
           "  input wire weA, input wire weB, input wire [1:0] bb, input wire b_en);\n"
           "  wire [15:0] A_a_addr = {14'd0, aA}; wire [15:0] B_a_addr = {14'd0, aB};\n"
           "  wire [15:0] b_addr = {14'd0, bb};\n"
           "  wire [31:0] A_a_din = dA; wire [31:0] B_a_din = dB;\n"
           "  wire [3:0] A_a_be = beA; wire [3:0] B_a_be = beB;\n"
           "  wire A_a_we = weA; wire B_a_we = weB;\n"
           "  reg [31:0] A_a_dout, B_a_dout; wire [31:0] A_b_dout, B_b_dout;\n"
           + copy("A") + copy("B") +
           "  always @* begin\n"
           "    assume (!a_en || aA == aB);\n"
           "    assume (!a_en || weA == weB);\n"
           "    assume (!(a_en && weA) || (dA == dB && beA == beB));\n"
           "    assert (A_a_dout == B_a_dout);\n"
           "    assert (A_b_dout == B_b_dout);\n"
           "    assert (A_b_rd == B_b_rd);\n"
           "    assert (A_rdw_hit_q == B_rdw_hit_q);\n"
           "    assert (!A_rdw_hit_q || (A_rdw_din_q == B_rdw_din_q && A_rdw_be_q == B_rdw_be_q));\n"
           + mems + "  end\nendmodule\n")
    with tempfile.TemporaryDirectory() as tmp:
        open(os.path.join(tmp, "gm.sv"), "w").write(top)
        r = subprocess.run(["yosys", "-q", "-p", "read_verilog -sv -formal gm.sv; hierarchy -top gm_prod; "
                            "proc; chformal -lower; memory; flatten; opt_clean; sat -tempinduct -prove-asserts "
                            "-set-assumes -set-init-zero -verify"],
                           cwd=tmp, capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr)[-1500:]


# (file, old revision, plant anchor, replacement) for single-file proofs: the clean proof of FILE
# against REV must pass and the planted one must fail. Empty since the C7-tail cut changed the
# arbiter's port list (its single-file proof against bf1b6650, the timing-cones cut, no longer
# matches ports); that cut's two plants now run against the pair proof below (PAIR_PLANTS).
PLANTS = []


def module_name(text):
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("module "):
            return s.split()[1].split("(")[0].split("#")[0].strip()
    sys.exit("no module declaration found")


def pp_sv(text):
    """Rewrite an initialized `automatic reg` declaration into a declaration plus an assignment.

    Yosys 0.66 rejects `automatic reg [n] x = expr;` inside a block ("Invalid nesting of always
    blocks and/or initializations"), and src/memory/sdram.v uses them throughout. The rewrite is
    semantics-preserving (a block-local declaration's initializer runs at block entry, which is
    where the inserted assignment sits, before every later statement) and is applied to BOTH
    revisions so the proof compares like with like."""
    return re.sub(r'automatic(\s+reg(?:\s*\[[^\]]*\])?\s+)(\w+)\s*=\s*([^;]*);',
                  r'automatic\1\2;\n            \2 = \3;', text)


def prove(rel, rev, plant=None, seq=2, with_files=(), old_add="", new_add="", blacklist=(), new_rev=None,
          gate=(), new_subst=(), abstract_mul=False):
    old = subprocess.run(["git", "show", "%s:%s" % (rev, rel)], cwd=REPO,
                         capture_output=True, text=True)
    if old.returncode:
        sys.exit("git show failed: " + old.stderr)
    if new_rev:   # --new REV: the new side from a revision instead of the working tree
        new = subprocess.run(["git", "show", "%s:%s" % (new_rev, rel)], cwd=REPO,
                             capture_output=True, text=True, check=True).stdout
    else:
        new = open(os.path.join(REPO, rel)).read()
    if plant:
        a, b = plant
        if new.count(a) != 1:
            sys.exit("plant anchor must occur exactly once: %s" % a)
        new = new.replace(a, b)
    name = module_name(new)

    def add(t, extra):
        # --old-add/--new-add: text pasted before the module's LAST endmodule of a COPY (never the
        # tree). A wire of the same name on both sides becomes one more $equiv cell, so a state
        # invariant written as `wire inv_x = <predicate>;` on the old side and `wire inv_x = 1'b1;`
        # on the new one is assumed by equiv_induct's hypothesis and must be re-proven every step:
        # the strengthening an induction over a removed register needs.
        if not extra:
            return t
        k = t.rindex("endmodule")
        return t[:k] + extra + "\n" + t[k:]
    for x, y in new_subst:   # e.g. the instantiation's parameter value written as the default
        if new.count(x) != 1:
            sys.exit("new_subst anchor must occur exactly once: %s" % x)
        new = new.replace(x, y)

    def env(t):
        # gate: the ENVIRONMENT CONTRACT an instantiator keeps, applied to both copies alike. Each
        # (port, guard) renames the input port to <port>_in and feeds the body <port>_in && guard,
        # so the proof covers exactly the input traces the contract allows.
        for port, guard in gate:
            t, n = re.subn(r"(input\s+wire\s+)%s\b" % port, r"\1%s_in" % port, t, count=1)
            if n != 1:
                sys.exit("gate: input port %s not found" % port)
        if gate:
            k = t.index(");", t.index("module %s" % name)) + 2
            t = t[:k] + "".join("\n  wire %s = %s_in && (%s);" % (p_, p_, g) for p_, g in gate) + t[k:]
        return t
    old_t = env(add(pp_sv(old.stdout), old_add)).replace("module %s" % name, "module eqv_old", 1)
    new_t = env(add(pp_sv(new), new_add)).replace("module %s" % name, "module eqv_new", 1)
    if abstract_mul:
        # abstract_mul: every `{...} * {...}` product becomes `{...} ^ {...}` in BOTH copies, so the
        # SAT problem holds no multiplier (a 16x16 product pair does not finish in 30 min). Sound by
        # congruence only when each product's operands are themselves paired cells (proven equal):
        # the same function of equal operands is equal, whatever the function. The record states
        # which pairs carry the operands.
        nold, nnew = len(re.findall(r"\} \* \{", old_t)), len(re.findall(r"\} \* \{", new_t))
        if nold == 0 or nold != nnew:
            sys.exit("abstract_mul: the copies must hold the same number (>0) of products: %d vs %d"
                     % (nold, nnew))
        old_t = re.sub(r"\} \* \{", "} ^ {", old_t)
        new_t = re.sub(r"\} \* \{", "} ^ {", new_t)
    with tempfile.TemporaryDirectory() as tmp:
        open(os.path.join(tmp, "old.sv"), "w").write(old_t)
        open(os.path.join(tmp, "new.sv"), "w").write(new_t)
        # --with: submodule files both sides instantiate unchanged (read once, flattened into both).
        wnames = []
        for i, w in enumerate(with_files):
            wn = "with%d.sv" % i
            open(os.path.join(tmp, wn), "w").write(pp_sv(open(os.path.join(REPO, w)).read()))
            wnames.append(wn)
        bl = ""
        if blacklist:
            open(os.path.join(tmp, "black.txt"), "w").write("".join("%s\n" % n for n in blacklist))
            bl = "-blacklist black.txt "
        # `memory` (not `memory -nomap`): equiv's SAT has no model for a $mem cell, and a file with
        # an array (sdram.v's gather slot maps) otherwise dies on "No SAT model available".
        script = ("read_verilog -sv old.sv new.sv %s; proc; opt_clean; memory; flatten; memory; "
                  "equiv_make %seqv_old eqv_new eq; hierarchy -top eq; "
                  "equiv_simple -seq %d; equiv_induct -seq %d; equiv_status -assert"
                  % (" ".join(wnames), bl, seq, seq))
        r = subprocess.run(["yosys", "-p", script], cwd=tmp, capture_output=True, text=True)
    ok = r.returncode == 0 and "Equivalence successfully proven!" in r.stdout
    summary = [ln.strip() for ln in r.stdout.splitlines() if "are proven" in ln]
    unproven = [ln.strip() for ln in r.stdout.splitlines() if "Unproven $equiv" in ln]
    return ok, ((summary[-1] if summary else r.stdout[-1500:] + r.stderr[-800:])
                + "".join("\n  " + u for u in unproven[:12]))


# RECORDED PROOFS (`--proof NAME`, `--proof all`): each cut's proof, rerunnable from its commit pair.
# name: (file, old rev, new rev, options, plants that must FAIL). Options are prove()'s keywords; an
# invariant pair (old_add/new_add) is the induction's strengthening (see prove()'s add()), and its
# base case - the predicate after reset - is stated in the comment beside it.
DPRAM4 = "tools/equiv/seq/dpram4.sv"   # pc9821_dpram cut to four words, no initialiser (the crtc's
                                       # text RAM, identical on both sides; the cuts do not read it)
CRTC_WITH = ("src/pc9821/core/pc9821_text_mem.sv", DPRAM4)
HDD_OLD_ADD = ("(* keep *) wire [40:0] pq_slo = size_q[40:0]; (* keep *) wire pq_shi = |size_q[63:41]; (* keep *) wire pq_r0 = (hdr_word[0] == 16'd0); (* keep *) wire pq_r1 = (hdr_word[1] == 16'd0); (* keep *) wire [20:0] pq_hs = {hdr_word[5][4:0], hdr_word[4]}; (* keep *) wire pq_hshz = (hdr_word[5][15:5] == 11'd0); (* keep *) wire [31:0] pq_ds = {hdr_word[7], hdr_word[6]}; (* keep *) wire pq_b8 = (hdr_word[8] == 16'd512); (* keep *) wire pq_b9 = (hdr_word[9] == 16'd0); (* keep *) wire [7:0] pq_spt = hdr_word[10][7:0]; (* keep *) wire pq_spth = (hdr_word[10][15:8] == 8'd0); (* keep *) wire pq_s11 = (hdr_word[11] == 16'd0); (* keep *) wire [7:0] pq_hd = hdr_word[12][7:0]; (* keep *) wire pq_hdh = (hdr_word[12][15:8] == 8'd0); (* keep *) wire pq_h13 = (hdr_word[13] == 16'd0); (* keep *) wire [15:0] pq_cy = hdr_word[14]; (* keep *) wire pq_cyh = (hdr_word[15] == 16'd0); (* keep *) wire [3:0] pq_ck = {vhd_word[3] == 16'h7869, vhd_word[2] == 16'h7463, vhd_word[1] == 16'h656E, vhd_word[0] == 16'h6F63}; (* keep *) wire [3:0] pq_dof = {vhd_word[11] == 16'hFFFF, vhd_word[10] == 16'hFFFF, vhd_word[9] == 16'hFFFF, vhd_word[8] == 16'hFFFF}; (* keep *) wire pq_c24 = (vhd_word[24] == 16'd0); (* keep *) wire [6:0] pq_c25h = bswap16(vhd_word[25]) >> 9; (* keep *) wire [40:0] pq_clo = {vhd_word[25][0], vhd_word[25][15:8], vhd_word[26][7:0], vhd_word[26][15:8], vhd_word[27][7:0], vhd_word[27][15:8]}; (* keep *) wire pq_t30 = (vhd_word[30] == 16'd0); (* keep *) wire pq_t31 = (bswap16(vhd_word[31]) == 16'd2); (* keep *) wire [15:0] pq_cs32 = vhd_word[32]; (* keep *) wire [15:0] pq_cs33 = vhd_word[33];")
HDD_NEW_ADD = ('(* keep *) wire [40:0] pq_slo = size_lo; (* keep *) wire pq_shi = size_hi; (* keep *) wire pq_r0 = h_res0_z; (* keep *) wire pq_r1 = h_res1_z; (* keep *) wire [20:0] pq_hs = h_hsize; (* keep *) wire pq_hshz = h_hsize_hi_z; (* keep *) wire [31:0] pq_ds = h_datasz; (* keep *) wire pq_b8 = h_bps_lo_512; (* keep *) wire pq_b9 = h_bps_hi_z; (* keep *) wire [7:0] pq_spt = h_spt; (* keep *) wire pq_spth = h_spt_hi_z; (* keep *) wire pq_s11 = h_spt_w11_z; (* keep *) wire [7:0] pq_hd = h_heads; (* keep *) wire pq_hdh = h_heads_hi_z; (* keep *) wire pq_h13 = h_heads_w13_z; (* keep *) wire [15:0] pq_cy = h_cyls; (* keep *) wire pq_cyh = h_cyls_hi_z; (* keep *) wire [3:0] pq_ck = v_cookie_w; (* keep *) wire [3:0] pq_dof = v_dof_w; (* keep *) wire pq_c24 = v_cur_w24_z; (* keep *) wire [6:0] pq_c25h = v_cur_w25_hi; (* keep *) wire [40:0] pq_clo = v_cur_lo; (* keep *) wire pq_t30 = v_type_hi_z; (* keep *) wire pq_t31 = v_type_lo_2; (* keep *) wire [15:0] pq_cs32 = v_csum_w32; (* keep *) wire [15:0] pq_cs33 = v_csum_w33;')
PROOFS = {
    # rdptr pairs by name with the old register: the identity is the whole strengthening.
    "pcm86_rdptr": ("src/pcm86/pc9821_pcm86.sv", "849c0e0a~", "849c0e0a",
                    dict(with_files=("src/pcm86/pc9821_pcm86_buf.sv",)),
                    [("wire [14:0] rdptr = wrptr - count[14:0];",
                      "wire [14:0] rdptr = wrptr - count[14:0] - {14'd0, count[15]};")]),
    # reset: tick_div = 0 <= tick_period.
    "calendar_tick": ("src/pc9821/rtc/pc9821_calendar.sv", "38cc050c~", "38cc050c",
                      dict(old_add="(* keep *) wire inv_tick = (tick_div <= tick_period);",
                           new_add="(* keep *) wire inv_tick = 1'b1;"),
                      [("end else if (tick_div == tick_period) begin",
                        "end else if (tick_div == (tick_period ^ 23'd2)) begin")]),
    # reset: both dividers 0.
    "kbd_div_width": ("src/pc9821/input/pc9821_kbd.sv", "616d0fc5~", "616d0fc5",
                      dict(blacklist=("xfer_div", "pace_div"),
                           old_add="(* keep *) wire inv_k = (xfer_div <= XFER_TICK_CYCLES - 26'd1) && "
                                   "(pace_div <= XFER_TICK_CYCLES - 26'd1); (* keep *) wire [25:0] xd_v = "
                                   "xfer_div; (* keep *) wire [25:0] pd_v = pace_div;",
                           new_add="(* keep *) wire inv_k = 1'b1; (* keep *) wire [25:0] xd_v = "
                                   "{{(26-XFER_W){1'b0}}, xfer_div}; (* keep *) wire [25:0] pd_v = "
                                   "{{(26-XFER_W){1'b0}}, pace_div};"),
                      [("deliver_key    ? XFER_LAST :", "deliver_key    ? (XFER_LAST - XFER_ONE) :"),
                       ("(xfer_div == XFER_LAST) ? '0", "(xfer_div == (XFER_LAST - XFER_ONE)) ? '0")]),
    # reset: S_IDLE, base_addr 0, line_request 0, byte_index 0. The DMA byte path (S_DMA_WAIT,
    # S_DMA_CAPTURE, and S_HOLD after a DMA write) leaves base_addr/byte_index/byte_count alone, so
    # the count relation is exempt there (and in S_HOLD) and only the alignment terms are carried.
    "window_or": ("src/pc9821/core/pc9821_window_responder.sv", "5313c45d~", "5313c45d",
                  dict(blacklist=("base_addr", "byte_index"),
                       old_add="(* keep *) wire inv_w = (base_addr[1:0] == 2'b00) && (!line_request || "
                               "base_addr[3:2] == 2'b00) && ((state == S_IDLE) || (state == S_HOLD) || (state == "
                               "S_DMA_WAIT) || (state == S_DMA_CAPTURE) || ((byte_count == "
                               "(line_request ? 5'd16 : 5'd4)) && (byte_index < byte_count))) && "
                               "(line_request || byte_index[4:2] == 3'd0); (* keep *) wire [13:0] ba_v = "
                               "base_addr; (* keep *) wire [4:0] bi_v = byte_index;",
                       new_add="(* keep *) wire inv_w = 1'b1; (* keep *) wire [13:0] ba_v = "
                               "{base_addr, 2'b00}; (* keep *) wire [4:0] bi_v = {1'b0, byte_index};"),
                  [("line_request ? (byte_index == 4'hF)", "line_request ? (byte_index == 4'hB)")]),
    # The port is compared ONLY under its strobe (pc9821_hdd_image samples req_lba on the pulse).
    "ata_block_lba": ("src/pc9821/storage/pc9821_ata.sv", "475f1d07~", "475f1d07",
                      dict(blacklist=("block_lba",),
                           old_add="(* keep *) wire [31:0] lba_q = (block_read || block_write) ? block_lba : 32'd0;",
                           new_add="(* keep *) wire [31:0] lba_q = (block_read || block_write) ? block_lba : 32'd0;"),
                      [("lba_plus1     <= 1'b1;   // block_lba = (current_lba + 1) + 1",
                        "lba_plus1     <= 1'b0;"),
                       ("lba_plus1   <= 1'b0;   // block_lba = current_lba", "lba_plus1   <= 1'b1;")]),
    # Environment: pc9821_block_share never requests while the engine is busy (both copies gated);
    # the new copy elaborated as block_share instantiates it. reset: serve_st = S_NONE.
    "block_io_serial": ("src/pc9821/storage/pc9821_block_io.sv", "a288f1bc~", "a288f1bc",
                        dict(gate=(("req_read", "!busy"), ("req_write", "!busy")),
                             new_subst=(("parameter SERIAL_REQ = 0", "parameter SERIAL_REQ = 1"),),
                             old_add="(* keep *) wire inv_sw = (serve_st != S_WAIT);",
                             new_add="(* keep *) wire inv_sw = 1'b1;"),
                        [("wire        req_past_end  = room33[32] || (room33[31:0] == 32'd0);",
                          "wire        req_past_end  = room33[32];"),
                         ("wire [31:0] room          = room33[31:0];",
                          "wire [31:0] room          = room33[31:0] - 32'd1;")]),
    # reset: gdc_snd_cnt 0, cmd_active 0.
    "crtc_csrr": ("src/pc9821/video/pc9821_crtc.sv", "56baf0cf~", "56baf0cf",
                  dict(with_files=CRTC_WITH,
                       old_add="(* keep *) wire inv_q = (!cmd_active || cur_cmd == 8'h06 || cur_cmd == 8'h47 || "
                               "cur_cmd == 8'h49 || cur_cmd == 8'h4B) && ((gdc_snd_cnt == 3'd0) || ((cur_cmd == "
                               "8'hE0) && (gdc_snd[0] == csr_ead[0]) && (gdc_snd[1] == csr_ead[1]) && (gdc_snd[2] "
                               "== (csr_ead2 & 8'h03)) && (gdc_snd[3] == 8'h00) && (gdc_snd[4] == 8'h00) && "
                               "(gdc_snd_ptr + gdc_snd_cnt == 3'd5) && (gdc_snd_ptr <= 3'd4)) || ((cur_cmd == "
                               "8'hC0) && (gdc_snd[0] == 8'h00) && (gdc_snd[1] == 8'h00) && (gdc_snd[2] == 8'h00) "
                               "&& (gdc_snd_ptr + gdc_snd_cnt == 3'd3) && (gdc_snd_ptr <= 3'd2))); (* keep *) wire "
                               "[2:0] k_v = (cur_cmd == 8'h47) ? 3'd0 : (cur_cmd == 8'h49) ? 3'd1 : (cur_cmd == "
                               "8'h4B) ? 3'd2 : (cur_cmd == 8'h06) ? 3'd3 : (cur_cmd == 8'hE0) ? 3'd4 : 3'd5;",
                       new_add="(* keep *) wire inv_q = 1'b1; (* keep *) wire [2:0] k_v = cur_k;"),
                  [("(gdc_snd_ptr == 3'd2) ? (csr_ead2 & 8'h03)", "(gdc_snd_ptr == 3'd2) ? (csr_ead2 & 8'h07)"),
                   ("(cur_k == 3'd1 || cur_k == 3'd2) ? 3'd3 : 3'd1", "(cur_k == 3'd1) ? 3'd3 : 3'd1")]),
    # The snapshot-to-compare distance bounds the 8-bit difference by the ack's pipeline stage.
    # reset: cfg_ack, its synchroniser and cfg_ack_seen all 0, so no stage is in flight.
    "crtc_epoch": ("src/pc9821/video/pc9821_crtc.sv", "bfa2502f~", "bfa2502f",
                   dict(with_files=CRTC_WITH, blacklist=("cfg_epoch", "cfg_epoch_snap"),
                        old_add="(* keep *) wire [7:0] ep_d = cfg_epoch - cfg_epoch_snap; (* keep *) wire inv_e "
                                "= ((cfg_ack == cfg_ack_sync[0]) || (ep_d <= 8'd1)) && ((cfg_ack_sync[0] == "
                                "cfg_ack_sync[1]) || (ep_d <= 8'd2)) && ((cfg_ack_sync[1] == cfg_ack_seen) || "
                                "(ep_d <= 8'd3)); (* keep *) wire [1:0] ep_v = cfg_epoch[1:0]; (* keep *) wire "
                                "[1:0] sn_v = cfg_epoch_snap[1:0];",
                        new_add="(* keep *) wire inv_e = 1'b1; (* keep *) wire [1:0] ep_v = cfg_epoch; "
                                "(* keep *) wire [1:0] sn_v = cfg_epoch_snap;"),
                   [("else if (cfg_ack_edge && (cfg_epoch == cfg_epoch_snap)) cfg_dirty <= 1'b0;",
                     "else if (cfg_ack_edge && (cfg_epoch[0] == cfg_epoch_snap[0])) cfg_dirty <= 1'b0;")]),
    # Each narrowed capture is paired with the old words' corresponding function (the pq_* wires);
    # no state invariant is needed. Power-up (no reset touches them): every old word is 0, and every
    # new capture's initial value is that function of zero words (the module's initial block). The
    # geometry products are abstracted (abstract_mul): their operands are the paired pq_spt, pq_hd,
    # pq_cy, so equal operands give equal products whatever the function.
    "hdd_fields": ("src/pc9821/storage/pc9821_hdd_image.sv", "c4e84041~", "c4e84041",
                   dict(abstract_mul=True, old_add=HDD_OLD_ADD, new_add=HDD_NEW_ADD),
                   [("8'd8:  h_bps_lo_512  <= (a_buf_data == 16'd512);",
                     "8'd8:  h_bps_lo_512  <= (a_buf_data == 16'd256);"),
                    ("(v_cur_lo[8:0] == 9'd0) && (v_cur_lo != 41'd0) && vhd_cur_hi_z &&",
                     "(v_cur_lo[8:0] == 9'd0) && vhd_cur_hi_z &&"),
                    ("wire hdr_total_ok  = !size_hi && (size_lo[40:33] == 8'd0) &&",
                     "wire hdr_total_ok  = !size_hi && (size_lo[40:34] == 7'd0) &&")]),
}


def run_recorded(names, plants=True):
    bad = 0
    for n in names:
        rel, ro, rn, opts, pl = PROOFS[n]
        ok, msg = prove(rel, ro, None, 2, new_rev=rn, **opts)
        print("%-16s %s vs %s: %s (%s)" % (n, rn, ro, "PROVEN" if ok else "NOT proven", msg))
        bad += not ok
        for a_, b_ in (pl if plants else []):
            pok, _ = prove(rel, ro, (a_, b_), 2, new_rev=rn, **opts)
            print("  plant %-60s %s" % (b_.strip()[:60], "NOT caught" if pok else "caught"))
            bad += pok
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file", nargs="?")
    ap.add_argument("--old", default="bf1b6650")
    ap.add_argument("--plant", help="OLD=>NEW text mutation of the new file (must FAIL)")
    ap.add_argument("--seq", type=int, default=2)
    ap.add_argument("--proof", action="append", default=[],
                    help="run a recorded proof and its plants (a PROOFS name, or `all`)")
    ap.add_argument("--new", dest="new_rev", help="the new side from this revision (default: the working tree)")
    ap.add_argument("--with", dest="with_files", action="append", default=[],
                    help="a submodule file both revisions instantiate (repo-relative; repeatable)")
    ap.add_argument("--old-add", default="", help="text (or @FILE) pasted before the old copy's endmodule")
    ap.add_argument("--new-add", default="", help="text (or @FILE) pasted before the new copy's endmodule")
    ap.add_argument("--blacklist", action="append", default=[],
                    help="a signal name equiv_make must not pair (repeatable)")
    ap.add_argument("--abstract-mul", action="store_true",
                    help="replace every {..} * {..} product by {..} ^ {..} in both copies (see prove())")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--pair", action="store_true",
                    help="prove the GRCG + arbiter pair (tools/equiv/grcg_arb_pair.sv) at --old")
    a = ap.parse_args()
    if a.proof:
        names = sorted(PROOFS) if "all" in a.proof else a.proof
        bad = run_recorded(names)
        print("check_seq_equiv: recorded proofs %s" % ("FAIL" if bad else "PASS"))
        sys.exit(1 if bad else 0)
    if a.pair:
        rev = a.old if a.old != "bf1b6650" else PAIR_REV
        ok, msg = prove_pair(rev, seq=a.seq)
        print("check_seq_equiv: grcg+arb pair vs %s: %s (%s)" % (rev, "PROVEN" if ok else "NOT proven", msg))
        bad = not ok
        gok, gmsg = prove_gmem_mask()
        print("check_seq_equiv: pc9821_gvram_mem observes port A only through the masked view: %s"
              % ("PROVEN" if gok else "NOT proven\n" + gmsg))
        bad += not gok
        sok, smsg = prove_share_flags()
        print("check_seq_equiv: the share's datum flags == the bytes of its gvr_din: %s"
              % ("PROVEN" if sok else "NOT proven\n" + smsg))
        bad += not sok
        if a.selftest:
            for pl in PAIR_PLANTS:
                pok, _ = prove_pair(rev, pl, a.seq)
                print("  plant %-60s %s" % (pl[2].strip()[:60], "NOT caught" if pok else "caught"))
                bad += pok
            for pl in GMEM_PLANTS:
                pok, _ = prove_gmem_mask(pl)
                print("  plant %-60s %s" % (pl[1].strip()[:60], "NOT caught" if pok else "caught"))
                bad += pok
            for pl in SHARE_PLANTS:
                pok, _ = prove_share_flags(pl)
                print("  plant %-60s %s" % (pl[1].strip()[:60], "NOT caught" if pok else "caught"))
                bad += pok
        sys.exit(1 if bad else 0)
    if a.selftest:
        bad = 0
        for rel in sorted({p[0] for p in PLANTS}):
            rev = [p[1] for p in PLANTS if p[0] == rel][0]
            ok, msg = prove(rel, rev, seq=a.seq)
            print("%-45s %s  %s" % (rel, "PROVEN" if ok else "FAILED", msg))
            bad += not ok
        for rel, rev, x, y in PLANTS:
            ok, _ = prove(rel, rev, (x, y), a.seq)
            print("  plant %-60s %s" % (x[:60], "NOT caught" if ok else "caught"))
            bad += ok
        ok, msg = prove_pair(PAIR_REV, seq=a.seq)
        print("%-45s %s  %s" % ("grcg+arb pair vs " + PAIR_REV, "PROVEN" if ok else "FAILED", msg))
        bad += not ok
        for pl in PAIR_PLANTS:
            pok, _ = prove_pair(PAIR_REV, pl, a.seq)
            print("  plant %-60s %s" % (pl[2].strip()[:60], "NOT caught" if pok else "caught"))
            bad += pok
        print("check_seq_equiv: selftest %s" % ("FAIL" if bad else "PASS"))
        sys.exit(1 if bad else 0)
    if not a.file:
        ap.error("a FILE (repo-relative) or --selftest is required")
    plant = tuple(a.plant.split("=>", 1)) if a.plant else None
    def txt(v):
        return open(v[1:]).read() if v.startswith("@") else v
    ok, msg = prove(a.file, a.old, plant, a.seq, a.with_files, txt(a.old_add), txt(a.new_add),
                    a.blacklist, a.new_rev, abstract_mul=a.abstract_mul)
    print("check_seq_equiv: %s vs %s: %s (%s)" % (a.file, a.old, "PROVEN" if ok else "NOT proven", msg))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

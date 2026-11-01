#!/usr/bin/env python3
"""check_gdc_egc_gate_inv.py -- prove the EGC memory gate (opt-video VID-1) is a TRUE PIPELINE
RELOCATE, by induction/equivalence over the REAL pc9821_crtc and pc9821_grcg.

`pc9821_system`'s `gdc_egc_mem_gate` used to be the combinational `gdc_egc_gate && mem_grcg_expand`
(pc9821_crtc's FF2 num-2 latch AND pc9821_grcg's 0x7C bit 7), which launched the only
`u_crtc`-launched GVRAM-M10K cone in the census (docs/timing.md). It is now the register
pc9821_egc_mem_gate, loaded from BOTH sources' NEXT state. The proof has four parts:

 1. EQUIVALENCE, pc9821_crtc vs its pre-change text at BASE: the rewritten module keeps every
    register - mode2_egc above all - and every output. The new next-state export is demoted to an
    internal wire for the match, so this proves the changed register's next state is the OLD one.
 2. EQUIVALENCE, pc9821_grcg vs BASE, the same way: the mode register is unchanged.
 3. INDUCTION: pc9821_crtc's exported `gfx_egc_gate_nx` IS mode2_egc's next state, and
    pc9821_grcg's exported `expand_gate_nx` IS mode[7]'s next state, in every reachable cycle from
    a reset with every input free.
 4. LEMMA: pc9821_egc_mem_gate's register, loaded from the two exports, equals the combinational
    AND in every cycle.

Together: the sources behave exactly as before (1,2), the exports are their next states (3), and
the gate register is loaded from those exports (4) - so gate(t) == mode2_egc(t) && mode[7](t) for
every cycle after reset, i.e. the value a consumer reads is bit-identical to the pre-change
combinational gate. No request or draw can observe a different owner, and the flop cuts the cone.

Properties are pasted into COPIES (the tree is never edited). In the induction (3) pc9821_crtc's
one submodule, pc9821_text_mem, is a stub built from its port list with FREE outputs - a superset of
the real RAM, so the proof covers every value it could return; the equivalence (1) reads the real
pc9821_text_mem / pc9821_dpram on both sides.

Parts 3 and 4 hold on the working tree and alone give gate(t) == mode2_egc(t) && mode[7](t): they
are the default run. Parts 1 and 2 compare against the pre-cut revision BASE, so they are a record
of the cut, valid only until either module next changes; `--history` runs them, and exits 2 (SKIP)
in a clone without BASE.

--selftest plants defects that must each make a proof FAIL (the equivalence plants only with
--history).

  python3 tools/check_gdc_egc_gate_inv.py [--selftest] [--history]
"""
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iobus_formal  # noqa: E402  (its comment-aware port-list stub)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CRTC = "src/pc9821/video/pc9821_crtc.sv"
GRCG = "src/pc9821/video/pc9821_grcg.sv"
MOD = "src/pc9821/video/pc9821_egc_mem_gate.sv"
TMEM = "src/pc9821/core/pc9821_text_mem.sv"
DPRAM = "src/pc9821/common/pc9821_dpram.sv"
BASE = "13340f1b"   # the tree before VID-1

CRTC_PROP = r"""
  // ---- check_gdc_egc_gate_inv.py (pasted into a copy; never in the tree) ----
  reg geg_chk;
  always @(posedge clk_sys) if (!rst_n_sys) geg_chk <= 1'b0; else geg_chk <= gfx_egc_gate_nx;
  always @* if (rst_n_sys) assert (mode2_egc == geg_chk);
"""

GRCG_PROP = r"""
  // ---- check_gdc_egc_gate_inv.py (pasted into a copy; never in the tree) ----
  reg ge_chk;
  always @(posedge clk) if (reset) ge_chk <= 1'b0; else ge_chk <= expand_gate_nx;
  always @* if (!reset) assert (mode[7] == ge_chk);
"""

LEMMA = r"""
module geg_lemma(input wire clk, input wire reset, input wire ew, input wire eb,
                 input wire gw, input wire gb);
  reg egc, grcg;
  always @(posedge clk) begin
    if (reset) begin egc <= 1'b0; grcg <= 1'b0; end
    else begin if (ew) egc <= eb; if (gw) grcg <= gb; end
  end
  wire egc_nx  = ew ? eb : egc;
  wire grcg_nx = gw ? gb : grcg;
  wire gate;
  pc9821_egc_mem_gate dut(.clk(clk), .reset(reset), .egc_gate(egc), .egc_gate_nx(egc_nx),
                          .grcg_expand(grcg), .grcg_expand_nx(grcg_nx), .gate(gate));
  always @* if (!reset) assert (gate == (egc & grcg));
endmodule
"""

# (anchor, replacement) on the working tree's text; the base-equivalence proof must FAIL.
CRTC_EQUIV_PLANTS = [
    # the reset term inverted (the register clears on the wrong phase)
    ("wire mode2_egc_nx = (!rst_n_sys) ? 1'b0 : ((mode2_egc_wr && mode2_wren) ? io_din[0] : mode2_egc);",
     "wire mode2_egc_nx = (rst_n_sys) ? 1'b0 : ((mode2_egc_wr && mode2_wren) ? io_din[0] : mode2_egc);"),
]
CRTC_PLANTS = [
    # the export is the register's current value, not its next state
    ("assign gfx_egc_gate_nx = mode2_egc_nx;", "assign gfx_egc_gate_nx = mode2_egc;"),
]
GRCG_PLANTS = [
    # the export is not the mode register's next state (the current value)
    ("assign expand_gate_nx = reset ? 1'b0\n                        : ((port_we && (port_addr == 8'h7C)) ? port_din[7] : mode[7]);",
     "assign expand_gate_nx = mode[7];"),
    # the 0x7C address decode checks the wrong port (a 0x7E write would move mode[7]'s next state)
    ("(port_we && (port_addr == 8'h7C)) ? port_din[7] : mode[7]",
     "(port_we && (port_addr == 8'h7E)) ? port_din[7] : mode[7]"),
]
LEMMA_PLANTS = [
    # the plain lagged register (the report's mutant)
    ("else       gate_q <= egc_gate_nx & grcg_expand_nx;",
     "else       gate_q <= egc_gate & grcg_expand;"),
]


def strip_initial(src):
    out, pos = [], 0
    for m in re.finditer(r"^\s*initial\s+begin\b", src, re.M):
        if m.start() < pos:
            continue
        depth, j = 0, m.end() - len("begin")
        for tok in re.finditer(r"\bbegin\b|\bend\b", src[j:]):
            depth += 1 if tok.group(0) == "begin" else -1
            if depth == 0:
                out.append(src[pos:m.start()])
                pos = j + tok.end()
                break
    out.append(src[pos:])
    return "".join(out)


def apply_plant(src, plant, rel):
    if plant:
        a, b = plant
        if src.count(a) != 1:
            sys.exit("plant anchor must occur exactly once in %s: %r" % (rel, a))
        src = src.replace(a, b)
    return src


def yosys(text, script, timeout=3600):
    os.makedirs(os.path.join(REPO, ".build"), exist_ok=True)
    with tempfile.TemporaryDirectory(dir=os.path.join(REPO, ".build")) as tmp:
        open(os.path.join(tmp, "x.sv"), "w").write(text)
        r = subprocess.run(["yosys", "-q", "-p", script], cwd=tmp, capture_output=True,
                           text=True, timeout=timeout)
    return r.returncode == 0, (r.stdout + r.stderr)


INDUCT = ("read_verilog -sv -formal -noblackbox x.sv; hierarchy -top %s; proc; chformal -lower; flatten; "
          "memory; opt_clean; setundef -undriven -anyseq; opt -fast; "
          "sat -tempinduct -prove-asserts -set-init-undef -set-def-inputs -set-def-formal "
          "-seq 1 -set-at 1 %s %s -maxsteps 4 -verify")


def prove_crtc(plant=None):
    crtc = apply_plant(open(os.path.join(REPO, CRTC)).read(), plant, CRTC)
    k = crtc.rindex("endmodule")
    crtc = strip_initial(crtc[:k]) + CRTC_PROP + crtc[k:]
    # the text RAM is a stub built from pc9821_text_mem's port list, its outputs FREE (a superset
    # of the real RAM): mapping its 16K-word array into the SAT model needs tens of GB
    text = crtc + "\n" + iobus_formal.port_stub(TMEM, "pc9821_text_mem")
    return yosys(text, INDUCT % ("pc9821_crtc", "rst_n_sys", "0"))


def prove_grcg(plant=None):
    g = apply_plant(open(os.path.join(REPO, GRCG)).read(), plant, GRCG)
    k = g.rindex("endmodule")
    g = strip_initial(g[:k]) + GRCG_PROP + g[k:]
    return yosys(g, INDUCT % ("pc9821_grcg", "reset", "1"))


def prove_lemma(plant=None):
    mod = apply_plant(open(os.path.join(REPO, MOD)).read(), plant, MOD)
    return yosys(mod + "\n" + LEMMA, INDUCT % ("geg_lemma", "reset", "1"))


def demote(src, expr):
    """Take the new next-state export out of the port list and make it an internal wire, so the
    equivalence flow sees one port list on both sides."""
    src = re.sub(r"\n\s*output wire %s," % re.escape(expr), "", src, count=1)
    return src.replace("  assign %s = " % expr, "  wire %s = " % expr, 1)


def prove_equiv(rel, plant=None):
    old = subprocess.run(["git", "show", "%s:%s" % (BASE, rel)], cwd=REPO,
                         capture_output=True, text=True)
    if old.returncode:
        sys.exit("git show failed: " + old.stderr)
    new = apply_plant(open(os.path.join(REPO, rel)).read(), plant, rel)
    new = demote(new, "gfx_egc_gate_nx" if rel == CRTC else "expand_gate_nx")
    new = strip_initial(new)
    new = new.replace("module " + module_name(new), "module eqv_new", 1)
    old_t = strip_initial(old.stdout).replace("module " + module_name(old.stdout), "module eqv_old", 1)
    extra = ""
    files = {"old.sv": old_t, "new.sv": new}
    if rel == CRTC:
        files["tm.sv"] = strip_initial(open(os.path.join(REPO, TMEM)).read())
        files["dp.sv"] = strip_initial(open(os.path.join(REPO, DPRAM)).read())
        extra = " tm.sv dp.sv"
    os.makedirs(os.path.join(REPO, ".build"), exist_ok=True)
    with tempfile.TemporaryDirectory(dir=os.path.join(REPO, ".build")) as tmp:
        for name, text in files.items():
            open(os.path.join(tmp, name), "w").write(text)
        script = ("read_verilog -sv old.sv new.sv%s; proc; opt_clean; memory; flatten; "
                  "equiv_make eqv_old eqv_new eq; hierarchy -top eq; "
                  "equiv_simple -seq 2; equiv_induct -seq 2; equiv_status -assert") % extra
        r = subprocess.run(["yosys", "-q", "-p", script], cwd=tmp, capture_output=True,
                           text=True, timeout=3600)
    return r.returncode == 0, (r.stdout + r.stderr)


def module_name(text):
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("module "):
            return s.split()[1].split("(")[0].split("#")[0].strip()
    sys.exit("no module declaration found")


def history_rev_present():
    r = subprocess.run(["git", "cat-file", "-e", BASE + "^{commit}"], cwd=REPO,
                       capture_output=True, text=True)
    return r.returncode == 0


def main():
    selftest = "--selftest" in sys.argv
    history = "--history" in sys.argv
    bad = 0
    if history and not history_rev_present():
        print("SKIP: --history needs revision %s (the tree before the cut), which this clone "
              "does not hold" % BASE)
        sys.exit(2)
    if history:
        for rel, label in ((CRTC, "pc9821_crtc"), (GRCG, "pc9821_grcg")):
            ok, log = prove_equiv(rel)
            print("%s == its text at %s (every register and output): %s" % (label, BASE, "PROVEN" if ok else "FAILED"))
            if not ok:
                print(log[-2500:])
            bad += not ok
    for fn, label in ((prove_crtc, "pc9821_crtc gfx_egc_gate_nx == mode2_egc's next state"),
                      (prove_grcg, "pc9821_grcg expand_gate_nx == mode[7]'s next state"),
                      (prove_lemma, "pc9821_egc_mem_gate gate == egc_gate & grcg_expand every cycle")):
        ok, log = fn()
        print("%s: %s" % (label, "PROVEN" if ok else "FAILED"))
        if not ok:
            print(log[-2500:])
        bad += not ok
    if selftest:
        if history:
            for p in CRTC_EQUIV_PLANTS:
                pok, _ = prove_equiv(CRTC, p)
                print("  crtc-equiv plant %s: %s" % ("NOT caught" if pok else "caught", p[1].strip()[:64]))
                bad += pok
        for p in CRTC_PLANTS:
            pok, _ = prove_crtc(p)
            print("  crtc plant %s: %s" % ("NOT caught" if pok else "caught", p[1].strip()[:64]))
            bad += pok
        for p in GRCG_PLANTS:
            pok, _ = prove_grcg(p)
            print("  grcg plant %s: %s" % ("NOT caught" if pok else "caught", p[1].strip()[:64]))
            bad += pok
        for p in LEMMA_PLANTS:
            pok, _ = prove_lemma(p)
            print("  lemma plant %s: %s" % ("NOT caught" if pok else "caught", p[1].strip()[:64]))
            bad += pok
        print("check_gdc_egc_gate_inv: selftest %s" % ("FAIL" if bad else "PASS"))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

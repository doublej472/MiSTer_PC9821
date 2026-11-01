#!/usr/bin/env python3
"""check_arb_resp_inv.py -- prove, by induction over the REAL GVRAM cluster, the state invariants
pc9821_gvram_arb's response routing rests on (docs/timing.md TB; the routing's combinational
identity under them is tools/equiv/arb_resp_route.sv).

The cluster is tests/pc9821/pc9821_gvram_dut.sv (the share, the arbiter, the GRCG and the EGC,
wired as pc9821_memory_subsystem wires them - this tool checks the subsystem's two engine
cpu_valid gates textually, since the proof rests on them) with the GVRAM array and the
scanout replaced by stubs whose outputs are FREE (any value, any cycle): the proof covers every
data and scanout behaviour, which is a superset of the real ones. Every top-level input (the
CPU, the GDC visit, the GRCG/EGC registers, reset) is free too.

The tool pastes this block into a COPY of the arbiter (the tree is never edited) and asks yosys
`sat -tempinduct` to prove every assertion in every reachable state, the reset included:

  I0  !(own_egc_q && own_grcg_q)                      the owner latch is one-hot or plain
  I1  cs != C_IDLE           -> plain latched          the plain client's transaction keeps its owner
  I2  grcg_dbg_busy          -> GRCG latched           the GRCG's walk keeps its owner
  I3  egc_dbg_busy           -> EGC latched            the EGC's walk keeps its owner
  I4  egc_cpu_resp_valid     -> cs == C_IDLE && GRCG idle
  and the three implications the routing needs:
  C1  cs == C_RESP2          -> cc_owns_plain
  C2  grcg_cpu_resp_valid    -> cc_owns_grcg
  C3  egc_cpu_resp_valid     -> !(cs == C_RESP2) && !grcg_cpu_resp_valid

--selftest plants defects that must each make the proof FAIL.

  python3 tools/check_arb_resp_inv.py [--selftest]
"""
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB = "src/pc9821/core/pc9821_gvram_arb.sv"
SUBSYS = "src/pc9821/core/pc9821_memory_subsystem.sv"
OTHERS = ["tests/pc9821/pc9821_gvram_dut.sv", "src/pc9821/core/pc9821_gvram_share.sv",
          "src/pc9821/video/pc9821_grcg.sv", "src/pc9821/core/pc9821_egc.sv",
          "src/pc9821/common/pc9821_dpram.sv"]
GATES = [".cpu_valid(gvr_valid && gvram_own_grcg)", ".cpu_valid(gvr_valid && gvram_own_egc)"]

PROPS = r"""
  // ---- check_arb_resp_inv.py (pasted into a copy; never in the tree) ----
  always @* begin
    if (!reset) begin
      assert (!(own_egc_q && own_grcg_q));
      assert ((cs == C_IDLE) || (!own_egc_q && !own_grcg_q));
      assert (!grcg_dbg_busy || (own_grcg_q && !own_egc_q));
      assert (!egc_dbg_busy || (own_egc_q && !own_grcg_q));
      assert (!egc_cpu_resp_valid || ((cs == C_IDLE) && !grcg_dbg_busy));
      assert (!(cs == C_RESP2) || cc_owns_plain);
      assert (!grcg_cpu_resp_valid || cc_owns_grcg);
      assert (!egc_cpu_resp_valid || (!(cs == C_RESP2) && !grcg_cpu_resp_valid));
      // tmg-120: G_RMWC is only entered inside a walk, where the arm's lane is m_lane, so the
      // merge byte formed from m_lane equals the one formed from the datum-dependent lane.
      assert (gstate != G_RMWC || m_mode);
      assert (gstate != G_RMWC || (pq[0].x_gr_d_m == pq[0].x_gr_d_old));
      assert (gstate != G_RMWC || (pq[1].x_gr_d_m == pq[1].x_gr_d_old));
      assert (gstate != G_RMWC || (pq[2].x_gr_d_m == pq[2].x_gr_d_old));
      assert (gstate != G_RMWC || (pq[3].x_gr_d_m == pq[3].x_gr_d_old));
    end
  end
"""

# The array and the scanout: their port lists copied from their sources (so a stub cannot
# drift), no body, so every output is undriven and becomes free under setundef -anyseq.
STUBS = [("src/pc9821/core/pc9821_gvram_mem.sv", "pc9821_gvram_mem"),
         ("src/pc9821/core/pc9821_gvram_scan.sv", "pc9821_gvram_scan")]

# (file, anchor, replacement): each must make the proof fail.
PLANTS = [
    # the owner latch re-evaluated while a transaction is in flight
    (ARB, "end else if (!any_inflight) begin\n      own_egc_q  <= cc_owns_egc_comb;",
     "end else if (1'b1) begin\n      own_egc_q  <= cc_owns_egc_comb;"),
    # the GRCG's cpu_valid no longer gated by its owner
    ("tests/pc9821/pc9821_gvram_dut.sv", ".cpu_valid(gvr_valid && own_grcg)", ".cpu_valid(gvr_valid)"),
    # the EGC's cpu_valid no longer gated by its owner
    ("tests/pc9821/pc9821_gvram_dut.sv", ".cpu_valid(gvr_valid && own_egc)", ".cpu_valid(gvr_valid)"),
    # the RMWC merge byte takes the wrong lane
    (ARB, "wire  [7:0] x_gr_d_m   = x_wdata[{m_lane[1:0], 3'b000} +: 8];",
     "wire  [7:0] x_gr_d_m   = x_wdata[{m_lane[1:0] ^ 2'b01, 3'b000} +: 8];"),
    # a GRCG merge started outside a walk (G_RMWC reachable with m_mode clear)
    (ARB, "              m_mode  <= 1'b1;\n              m_write <= ef_wr;", "              m_mode  <= 1'b0;\n              m_write <= ef_wr;"),
    # the plain client accepting without owning the port
    (ARB, "C_IDLE: if (cpu_valid && cc_owns_plain) begin", "C_IDLE: if (cpu_valid) begin"),
]


def port_stub(rel, name):
    src = open(os.path.join(REPO, rel)).read()
    a = src.index("module " + name)
    b = src.index(");", a)
    return src[a:b + 2] + "\nendmodule\n"


def prove(plant=None):
    texts = {}
    for rel in [ARB] + OTHERS:
        texts[rel] = open(os.path.join(REPO, rel)).read()
    if plant:
        rel, a, b = plant
        if texts[rel].count(a) != 1:
            sys.exit("plant anchor must occur exactly once in %s: %r" % (rel, a))
        texts[rel] = texts[rel].replace(a, b)
    # yosys's parser takes a package import at file scope but not as a module item.
    egc = "src/pc9821/core/pc9821_egc.sv"
    imp = "  import pc9821_egc_pkg::*;\n"
    assert texts[egc].count(imp) == 1 and texts[egc].count("endpackage\n") == 1
    texts[egc] = texts[egc].replace(imp, "").replace("endpackage\n", "endpackage\n" + imp.strip() + "\n")
    # ... nor an enum-typed localparam or variable: the 4-bit vector it is (egc_state_e is
    # `enum logic [3:0]`), the same bits.
    for a, b in (("localparam egc_state_e ", "localparam [3:0] "),
                 ("pc9821_egc_pkg::egc_state_e state;", "reg [3:0] state;")):
        assert texts[egc].count(a) == 1, a
        texts[egc] = texts[egc].replace(a, b)
    arb = texts[ARB]
    k = arb.rindex("endmodule")
    texts[ARB] = arb[:k] + PROPS + arb[k:]
    with tempfile.TemporaryDirectory(dir=os.path.join(REPO, ".build")) as tmp:
        names = []
        for i, rel in enumerate([ARB] + OTHERS):
            fn = os.path.join(tmp, "f%d.sv" % i)
            open(fn, "w").write(texts[rel])
            names.append(fn)
        fn = os.path.join(tmp, "stubs.sv")
        open(fn, "w").write("".join(port_stub(r, n) for r, n in STUBS))
        names.append(fn)
        script = ("read_verilog -sv -formal %s; hierarchy -top pc9821_gvram_dut; proc; chformal -lower; flatten; "
                  "memory; opt_clean; setundef -undriven -anyseq; opt -fast; "
                  "sat -tempinduct -prove-asserts -set-init-undef -set-def-inputs -set-def-formal -seq 1 -set-at 1 reset 1 -show-ports -maxsteps 6 -verify%s"
                  % (" ".join(names), os.environ.get("ARB_INV_SHOW", "")))
        r = subprocess.run(["yosys"] + ([] if os.environ.get("ARB_INV_VERBOSE") else ["-q"]) + ["-p", script], cwd=tmp, capture_output=True, text=True)
    ok = r.returncode == 0
    if os.environ.get("ARB_INV_VERBOSE"):
        open(os.path.join(REPO, ".build", "arb_resp_inv.log"), "w").write(r.stdout + r.stderr)
    return ok, r.stdout + r.stderr


def main():
    sub = open(os.path.join(REPO, SUBSYS)).read()
    bad = 0
    for g in GATES:
        if g not in sub:
            print("pc9821_memory_subsystem no longer gates an engine as the proof assumes: %s" % g)
            bad += 1
    ok, log = prove()
    print("arb response-routing invariants: %s" % ("PROVEN" if ok else "FAILED"))
    if not ok:
        print(log[-4000:])
        bad += 1
    if "--selftest" in sys.argv:
        for p in PLANTS:
            pok, _ = prove(p)
            print("  plant %s: %s" % ("NOT caught" if pok else "caught", p[2][:60].replace("\n", " ")))
            bad += pok
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

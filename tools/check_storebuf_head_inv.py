#!/usr/bin/env python3
"""check_storebuf_head_inv.py -- prove the C5-head cut (docs/timing.md) cycle-identical, by
induction over the REAL pc9821_pegc_storebuf.

The cut replaces three combinational terms of the drain decision and the merge window:
  * pair_ok's `win_addr[1] == win_addr[0] + 1` by the registered pair fact nx_adj[rp];
  * grp_run's `rowkey(win_addr[gi]) == rowkey(win_addr[0])` by the registered same-row facts
    nx_row[rp + gi - 1] along the prefix;
  * the merge window's pres_cnt by post_cnt (pres_cnt with pass_req = 0), read only under a post.
The tool pastes into a COPY of the module (the tree is never edited) the EARLIER expressions,
computed from the same window, and asserts that each new term equals its old one wherever the old
one is read: pair_ok and grp_run in every cycle, the match (and so can_combine) whenever the
request is postable. Strengthening invariants make the step inductive: wp == rp + count with
count <= 8, last_addr == ent_addr[wp-1] while the buffer is not empty, every held pair's facts
equal its addresses' relations, and a presented drain carries no more than the held entries.
yosys `sat -tempinduct` proves them from a reset with every input free (sdram_size included, at
every value), so the module's state and outputs are the earlier module's in every cycle.

A second proof covers the C5-free cut (the slot at wp written on every post, not only on an
allocation): a MITER of the module at FREE_BASE and the working tree's, sharing every input, proves
by induction that the control state, the pair facts and every HELD entry (addr, data, enables, age)
stay equal, and that every output the controller reads is equal: in_ready, mem_valid, mem_write,
mem_burstcount, mem_gath and busy always; mem_addr/mem_din/mem_be while mem_valid; mem_din_hi on a
pair drain; and gather entry j only for j < the drain's entry count (src/memory/sdram_sync_bridge.sv
gath0_extra_used is the same mask). Only a FREE slot may differ, and nothing reads one.

The first proof holds on the working tree and is the default run. The second compares against the
earlier revision FREE_BASE, so it is a record of that cut, valid only until the module next changes;
`--history` runs it, and exits 2 (SKIP) in a clone without FREE_BASE.

--selftest plants defects that must each make the proofs FAIL (the miter plants only with
--history).

  python3 tools/check_storebuf_head_inv.py [--selftest] [--history]
"""
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SB = "src/pc9821/core/pc9821_pegc_storebuf.sv"

PROP = r"""
  // ---- check_storebuf_head_inv.py (pasted into a copy; never in the tree) ----
  // the earlier terms, from the same head window
  reg  [3:0] old_grp_run;
  always @* begin : old_grp_sel
    integer gi;
    reg [15:0] rk;
    old_grp_run = 4'd0;
    rk          = rowkey(win_addr[0]);
    for (gi = 0; gi < GATHER_K; gi = gi + 1)
      if ((gi < count) && (old_grp_run == 4'(gi)) && (rowkey(win_addr[gi]) == rk))
        old_grp_run = 4'(gi + 1);
  end
  wire old_pair_ok = (count >= 4'd2) && (win_be[0] == 4'hF) && (win_be[1] == 4'hF) &&
                     ({1'b0, win_addr[1]} == ({1'b0, win_addr[0]} + 18'd1));
  reg  [DEPTH-1:0] old_match_hit;
  always @* begin : old_match
    integer mi;
    reg [2:0] off;
    for (mi = 0; mi < DEPTH; mi = mi + 1) begin
      off = 3'(mi) - rp;
      old_match_hit[mi] = (ent_addr[mi] == in_addr[18:2]) && ({1'b0, off} >= pres_cnt) &&
                          ({1'b0, off} < count);
    end
  end
  // the held pair (rp+j, rp+j+1)'s relations
  function automatic held_ok(input integer j);
    held_ok = (4'(j + 1) < count);
  endfunction
  integer pj;
  always @* begin
    if (!reset) begin
      // the equalities the cut rests on
      assert (pair_ok == old_pair_ok);
      assert (grp_run == old_grp_run);
      if (in_valid && postable) assert (match_hit == old_match_hit);
      // the strengthening invariants
      assert (count <= 4'd8);
      assert (wp == 3'(rp + count[2:0]));
      if (count != 4'd0) assert (last_addr == ent_addr[3'(wp - 3'd1)]);
      if (pres_locked && !pres_pass) assert ((pres_n <= count) && (pres_n != 4'd0));
      for (pj = 0; pj < DEPTH - 1; pj = pj + 1)
        if (held_ok(pj)) begin
          assert (nx_adj[3'(rp + 3'(pj))] ==
                  ({1'b0, ent_addr[3'(rp + 3'(pj + 1))]} == ({1'b0, ent_addr[3'(rp + 3'(pj))]} + 18'd1)));
          assert (nx_row_lg[3'(rp + 3'(pj))] ==
                  (ent_addr[3'(rp + 3'(pj + 1))][16:9] == ent_addr[3'(rp + 3'(pj))][16:9]));
          assert (nx_row_sm[3'(rp + 3'(pj))] ==
                  (ent_addr[3'(rp + 3'(pj + 1))][16:8] == ent_addr[3'(rp + 3'(pj))][16:8]));
        end
    end
  end
"""

# The same properties written for the FULL-WIDTH buffer (25-bit entry addresses): the miter pastes
# them into the older side.
PROP_FULL = r"""
  // ---- check_storebuf_head_inv.py (pasted into a copy; never in the tree) ----
  // the earlier terms, from the same head window
  reg  [3:0] old_grp_run;
  always @* begin : old_grp_sel
    integer gi;
    reg [15:0] rk;
    old_grp_run = 4'd0;
    rk          = rowkey(win_addr[0]);
    for (gi = 0; gi < GATHER_K; gi = gi + 1)
      if ((gi < count) && (old_grp_run == 4'(gi)) && (rowkey(win_addr[gi]) == rk))
        old_grp_run = 4'(gi + 1);
  end
  wire old_pair_ok = (count >= 4'd2) && (win_be[0] == 4'hF) && (win_be[1] == 4'hF) &&
                     (win_addr[1] == (win_addr[0] + 25'd1));
  reg  [DEPTH-1:0] old_match_hit;
  always @* begin : old_match
    integer mi;
    reg [2:0] off;
    for (mi = 0; mi < DEPTH; mi = mi + 1) begin
      off = 3'(mi) - rp;
      old_match_hit[mi] = (ent_addr[mi] == in_addr[26:2]) && ({1'b0, off} >= pres_cnt) &&
                          ({1'b0, off} < count);
    end
  end
  // the held pair (rp+j, rp+j+1)'s relations
  function automatic held_ok(input integer j);
    held_ok = (4'(j + 1) < count);
  endfunction
  integer pj;
  always @* begin
    if (!reset) begin
      // the equalities the cut rests on
      assert (pair_ok == old_pair_ok);
      assert (grp_run == old_grp_run);
      if (in_valid && postable) assert (match_hit == old_match_hit);
      // the strengthening invariants
      assert (count <= 4'd8);
      assert (wp == 3'(rp + count[2:0]));
      if (count != 4'd0) assert (last_addr == ent_addr[3'(wp - 3'd1)]);
      if (pres_locked && !pres_pass) assert ((pres_n <= count) && (pres_n != 4'd0));
      for (pj = 0; pj < DEPTH - 1; pj = pj + 1)
        if (held_ok(pj)) begin
          assert (nx_adj[3'(rp + 3'(pj))] ==
                  (ent_addr[3'(rp + 3'(pj + 1))] == (ent_addr[3'(rp + 3'(pj))] + 25'd1)));
          assert (nx_row_lg[3'(rp + 3'(pj))] ==
                  (ent_addr[3'(rp + 3'(pj + 1))][24:9] == ent_addr[3'(rp + 3'(pj))][24:9]));
          assert (nx_row_sm[3'(rp + 3'(pj))] ==
                  (ent_addr[3'(rp + 3'(pj + 1))][22:8] == ent_addr[3'(rp + 3'(pj))][22:8]));
        end
    end
  end
"""
PROP_NARROW = PROP

PLANTS = [
    # the adjacency fact taken against the wrong neighbour
    ("      nx_adj[3'(wp - 3'd1)]    <= alloc_now ? ({1'b0, in_addr[18:2]} == ({1'b0, last_addr} + 18'd1)) : nx_adj[3'(wp - 3'd1)];   // 18 bits: the window's last dword and its first are NOT adjacent",
     "      nx_adj[3'(wp - 3'd1)]    <= alloc_now ? (in_addr[18:2] == last_addr) : nx_adj[3'(wp - 3'd1)];"),
    # the newest-dword register not updated by the allocation
    ("      last_addr    <= alloc_now ? in_addr[18:2] : last_addr;\n", ""),
    # the run read at the wrong slot
    ("((gi == 0) || nx_row[3'(rp + 3'(gi - 1))])", "((gi == 0) || nx_row[3'(rp + 3'(gi))])"),
    # the merge window without the drain's commit
    ("  wire [3:0] post_cnt   = post_drain ? post_n : 4'd0;", "  wire [3:0] post_cnt   = 4'd0;"),
    # C5-A: the count mux select is inverted, so the adder picks the wrong side
    ("      count <= alloc_now ? (cnt_base + 4'd1) : cnt_base;",
     "      count <= alloc_now ? cnt_base : (cnt_base + 4'd1);"),
]


def strip_ifdef_verilator(src):
    out, skip = [], 0
    for line in src.splitlines(keepends=True):
        t = line.strip()
        if t.startswith("`ifdef VERILATOR"):
            skip += 1
            continue
        if skip and t.startswith("`endif"):
            skip -= 1
            continue
        if not skip:
            out.append(line)
    return "".join(out)


def prove(plant=None):
    src = open(os.path.join(REPO, SB)).read()
    if plant:
        a, b = plant
        if src.count(a) != 1:
            sys.exit("plant anchor must occur exactly once: %r" % a)
        src = src.replace(a, b)
    src = strip_ifdef_verilator(src)   # the simulation-only checks ($fatal/$countones)
    k = src.rindex("endmodule")
    src = src[:k] + PROP + src[k:]
    os.makedirs(os.path.join(REPO, ".build"), exist_ok=True)
    with tempfile.TemporaryDirectory(dir=os.path.join(REPO, ".build")) as tmp:
        open(os.path.join(tmp, "sb.sv"), "w").write(src)
        script = ("read_verilog -sv -formal sb.sv; hierarchy -top pc9821_pegc_storebuf; proc; "
                  "chformal -lower; flatten; memory; opt_clean; setundef -undriven -anyseq; "
                  "opt -fast; sat -tempinduct -prove-asserts -set-init-undef -set-def-inputs "
                  "-set-def-formal -seq 1 -set-at 1 reset 1 -maxsteps 4 -verify")
        r = subprocess.run(["yosys", "-q", "-p", script], cwd=tmp, capture_output=True, text=True)
    return r.returncode == 0, r.stdout[-4000:] + r.stderr[-1500:]


FREE_BASE = "6304b310"   # the store buffer with full-width (25-bit) entry addresses
WINDOW_HI = "8'hA5"      # the one 512 KiB window the miter drives every request into (byte address [26:19])

# pasted into each side of the miter: the state the induction holds equal (held entries masked)
DBG_PORT = "    output wire        busy\n);"
DBG_TEXT = r"""
  // ---- check_storebuf_head_inv.py miter tap (pasted into a copy; never in the tree) ----
  reg [8*(25+32+4+AGE_W)-1:0] dbg_held;
  always @* begin : dbg_pack
    integer di;
    reg [2:0] doff;
    dbg_held = '0;
    for (di = 0; di < DEPTH; di = di + 1) begin
      doff = 3'(di) - rp;
      if ({1'b0, doff} < count)
        dbg_held[di*(25+32+4+AGE_W) +: (25+32+4+AGE_W)] = {%(FULL_ENT)s, ent_data[di], ent_be[di], ent_age[di]};
    end
  end
  // the window invariant the miter's driven inputs make inductive: every held dword lies in ONE
  // 512 KiB window (byte address [26:19] == WINDOW), the shared copy / upper address bits included
  always @* begin : dbg_window
    integer wi;
    if (!reset && (count != 4'd0)) begin
      assert (%(HELD_HI_LAST)s == %(HI)s);
      for (wi = 0; wi < DEPTH; wi = wi + 1)
        if ({1'b0, 3'(3'(wi) - rp)} < count) assert (%(HELD_HI_ENT)s == %(HI)s);
    end
  end
  // the pair facts nx_*[e] are read only while BOTH entries e and e+1 are held; for any other
  // pair they were decided against a stale `last_addr` (a power-up junk or a popped entry's) and
  // the two buffers' junk differs (the full-width buffer keeps bits the narrow one does not)
  reg [DEPTH-1:0] dbg_nx_adj, dbg_nx_lg, dbg_nx_sm;
  always @* begin : dbg_nx
    integer ni;
    for (ni = 0; ni < DEPTH; ni = ni + 1) begin
      dbg_nx_adj[ni] = (({1'b0, 3'(3'(ni) - rp)} + 4'd1) < count) ? nx_adj[ni]    : 1'b0;
      dbg_nx_lg[ni]  = (({1'b0, 3'(3'(ni) - rp)} + 4'd1) < count) ? nx_row_lg[ni] : 1'b0;
      dbg_nx_sm[ni]  = (({1'b0, 3'(3'(ni) - rp)} + 4'd1) < count) ? nx_row_sm[ni] : 1'b0;
    end
  end
  assign dbg_state = {dbg_held, wp, rp, count, pres_locked, pres_pass, pres_pair, pres_n,
                      hold_force_r, (count != 4'd0) ? %(FULL_LAST)s : 25'd0, dbg_nx_adj, dbg_nx_lg, dbg_nx_sm,
                      use_pass, pair_now};
"""
DBG_W = "8*(25+32+4+AGE_W)+3+3+4+1+1+1+4+1+25+8+8+8+1+1"

MITER = r"""
module miter (
    input wire clk, input wire reset, input wire in_valid, input wire in_write,
    input wire [31:0] in_addr, input wire [31:0] in_din, input wire [3:0] in_be,
    input wire [7:0] in_burstcount, input wire in_peg_route, input wire in_rd_block,
    input wire [1:0] sdram_size, input wire mem_ready);
  localparam integer AGE_W = $clog2(50 + 1);
  localparam integer W = %(W)s;
  wire a_in_ready, b_in_ready, a_valid, b_valid, a_write, b_write, a_gath, b_gath, a_busy, b_busy;
  wire [31:0] a_addr, b_addr, a_din, b_din, a_hi, b_hi;
  wire [3:0] a_be, b_be;
  wire [7:0] a_bc, b_bc;
  wire [440:0] a_gx, b_gx;
  wire [W-1:0] a_st, b_st;
  wire [31:0] in_addr_w = {in_addr[31:27], %(HI)s, in_addr[18:0]};   // every request in ONE 512 KiB window
  sb_old A (.clk(clk), .reset(reset), .in_valid(in_valid), .in_write(in_write), .in_addr(in_addr_w),
            .in_din(in_din), .in_be(in_be), .in_burstcount(in_burstcount), .in_peg_route(in_peg_route),
            .in_ready(a_in_ready), .in_rd_block(in_rd_block), .sdram_size(sdram_size),
            .mem_addr(a_addr), .mem_din(a_din), .mem_din_hi(a_hi), .mem_be(a_be), .mem_burstcount(a_bc),
            .mem_valid(a_valid), .mem_write(a_write), .mem_gath(a_gath), .mem_gath_extra(a_gx),
            .mem_ready(mem_ready), .busy(a_busy), .dbg_state(a_st));
  sb_new B (.clk(clk), .reset(reset), .in_valid(in_valid), .in_write(in_write), .in_addr(in_addr_w),
            .in_din(in_din), .in_be(in_be), .in_burstcount(in_burstcount), .in_peg_route(in_peg_route),
            .in_ready(b_in_ready), .in_rd_block(in_rd_block), .sdram_size(sdram_size),
            .mem_addr(b_addr), .mem_din(b_din), .mem_din_hi(b_hi), .mem_be(b_be), .mem_burstcount(b_bc),
            .mem_valid(b_valid), .mem_write(b_write), .mem_gath(b_gath), .mem_gath_extra(b_gx),
            .mem_ready(mem_ready), .busy(b_busy), .dbg_state(b_st));
  wire use_pass = a_st[1];
  wire pair_now = a_st[0];
  integer gj;
  always @* begin
    if (!reset) begin
      assert (a_st == b_st);
      assert ((a_in_ready == b_in_ready) && (a_valid == b_valid) && (a_write == b_write) &&
              (a_gath == b_gath) && (a_busy == b_busy) && (a_bc == b_bc));
      if (a_valid) assert ((a_addr == b_addr) && (a_din == b_din) && (a_be == b_be));
      if (a_valid && !use_pass && pair_now) assert (a_hi == b_hi);
      for (gj = 1; gj < 4; gj = gj + 1)
        if (a_valid && a_gath && (gj < a_bc)) assert (a_gx[(gj-1)*63 +: 63] == b_gx[(gj-1)*63 +: 63]);
    end
  end
endmodule
"""

FREE_PLANTS = [
    # the free-slot write lands on the slot BEFORE wp (a held entry)
    ("        ent_addr[wp] <= in_addr[18:2];",
     "        ent_addr[3'(wp - 3'd1)] <= in_addr[18:2];"),
    # the age of the slot reset on a post one entry late
    ("        if (post_accept && (3'(i) == wp))\n          ent_age[i] <= {AGE_W{1'b0}};",
     "        if (post_accept && (3'(i) == 3'(wp + 3'd1)))\n          ent_age[i] <= {AGE_W{1'b0}};"),
]


def tapped(src, name, narrow):
    if src.count(DBG_PORT) != 1:
        sys.exit("the busy port moved; re-point DBG_PORT")
    src = src.replace(DBG_PORT, "    output wire        busy,\n    output wire [%s-1:0] dbg_state\n);" % DBG_W)
    src = strip_ifdef_verilator(src).replace("module pc9821_pegc_storebuf", "module " + name, 1)
    k = src.rindex("endmodule")
    # each side's own inductive invariants (PROP) strengthen the miter's step
    dbg = DBG_TEXT % ({"FULL_ENT": "{hi_r, ent_addr[di]}", "FULL_LAST": "{hi_r, last_addr}",
                       "HELD_HI_LAST": "hi_r", "HELD_HI_ENT": "hi_r", "HI": WINDOW_HI} if narrow else
                      {"FULL_ENT": "ent_addr[di]", "FULL_LAST": "last_addr",
                       "HELD_HI_LAST": "last_addr[24:17]", "HELD_HI_ENT": "ent_addr[wi][24:17]",
                       "HI": WINDOW_HI})
    return src[:k] + dbg + (PROP_NARROW if narrow else PROP_FULL) + src[k:]


def prove_free(plant=None):
    old = subprocess.run(["git", "show", "%s:%s" % (FREE_BASE, SB)], cwd=REPO, capture_output=True,
                         text=True)
    if old.returncode:
        sys.exit("git show failed: " + old.stderr)
    new = open(os.path.join(REPO, SB)).read()
    if plant:
        if new.count(plant[0]) != 1:
            sys.exit("plant anchor must occur exactly once: %r" % plant[0])
        new = new.replace(plant[0], plant[1])
    text = (tapped(old.stdout, "sb_old", False) + tapped(new, "sb_new", True) +
            MITER % {"W": DBG_W, "HI": WINDOW_HI})
    with tempfile.TemporaryDirectory(dir=os.path.join(REPO, ".build")) as tmp:
        open(os.path.join(tmp, "m.sv"), "w").write(text)
        script = ("read_verilog -sv -formal m.sv; hierarchy -top miter; proc; flatten; "
                  "chformal -lower; memory; opt_clean; setundef -undriven -anyseq; "
                  "opt -fast; sat -tempinduct -prove-asserts -set-init-undef -set-def-inputs "
                  "-set-def-formal -seq 1 -set-at 1 reset 1 -maxsteps 4 -verify")
        r = subprocess.run(["yosys", "-q", "-p", script], cwd=tmp, capture_output=True, text=True)
    return r.returncode == 0, r.stdout[-4000:] + r.stderr[-1500:]


def main():
    history = "--history" in sys.argv
    if history and subprocess.run(["git", "cat-file", "-e", FREE_BASE + "^{commit}"], cwd=REPO,
                                  capture_output=True).returncode:
        print("SKIP: --history needs revision %s, which this clone does not hold" % FREE_BASE)
        sys.exit(2)
    ok, log = prove()
    print("storebuf head facts == the window compares (pair_ok, grp_run, the merge window): %s"
          % ("PROVEN" if ok else "FAILED"))
    bad = 0 if ok else 1
    if not ok:
        print(log)
    if history:
        fok, flog = prove_free()
        print("storebuf vs %s (held entries, control state, every read output): %s"
              % (FREE_BASE, "PROVEN" if fok else "FAILED"))
        if not fok:
            print(flog)
        bad += not fok
    if "--selftest" in sys.argv:
        for p in (FREE_PLANTS if history else []):
            pok, _ = prove_free(p)
            print("  free plant %s: %s" % ("NOT caught" if pok else "caught", p[1].strip()[:70]))
            bad += pok
        for p in PLANTS:
            pok, _ = prove(p)
            print("  plant %s: %s" % ("NOT caught" if pok else "caught", (p[1].strip() or "(removed) " + p[0].strip())[:70]))
            bad += pok
        print("check_storebuf_head_inv: selftest %s" % ("FAIL" if bad else "PASS"))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

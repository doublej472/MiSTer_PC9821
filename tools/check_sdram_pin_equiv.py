#!/usr/bin/env python3
"""check_sdram_pin_equiv.py -- src/memory/sdram.v against an earlier revision of itself, pin for pin.

A zero-cycle rewrite of the SDRAM controller (a look-ahead register, a precomputed field) must leave
every pin and every requester output identical on every clk cycle. tools/equiv/seq/tb_sdram_pin_equiv.sv
runs the working tree's controller beside the one at REV (`git show REV:src/memory/sdram.v`, the module
renamed sdram_ref) from one random stimulus - gathers, single and two-word writes, read bursts, row
splits, refresh, the two-chip module - each against its own chip models, and fails on the first cycle
any pin (A, BA, DQM, nCS, nRAS, nCAS, nWE, CKE, DQ with Z) or port output differs. The expected value
is the earlier controller's own behaviour: this proves a rewrite changed nothing, not that the
controller is right (the sdram benches and the real-controller gates do that).

CONFIGS are the shipped wiring (ADQM=1 at 90 MHz on a 128 MB two-chip module, and with nce gating),
the 64 MB geometry and the DQM-less RMW path. --selftest also builds each PLANT (a mutation of the
working tree's controller) and requires the comparison to FAIL, so a harness that cannot see a
defect is caught. Build output goes under .build/sdram-pin-equiv (git-ignored).

  python3 tools/check_sdram_pin_equiv.py [--old REV] [--selftest]

RECORDED: the S1-b pin look-ahead (docs/timing.md) is proven against its parent with --old <that
commit>~; the default REV is HEAD.
"""
import argparse
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SDRAM = "src/memory/sdram.v"
TB = "tools/equiv/seq/tb_sdram_pin_equiv.sv"
CHIP = "tests/pc9821/sdram_chip_model.sv"
WORK = os.path.join(REPO, ".build", "sdram-pin-equiv")

# (name, ADQM, FREQ, sdram_size, nce gating)
CONFIGS = [
    ("adqm1-90-128mb", "1'b1", "90_000_000", "2'd3", "0"),
    ("adqm1-90-128mb-nce", "1'b1", "90_000_000", "2'd3", "1"),
    ("adqm1-90-64mb", "1'b1", "90_000_000", "2'd2", "0"),
    ("adqm0-90-64mb", "1'b0", "90_000_000", "2'd2", "0"),
    ("adqm1-50-32mb", "1'b1", "50_000_000", "2'd1", "0"),
]

# (anchor, replacement, config) on the working tree's sdram.v: each must make the comparison FAIL.
# Each also disarms the SIM-ONLY look-ahead check, so the comparison itself is what must see it.
LA_CHECK = "    if (la_live && ("
LA_OFF = "    if (1'b0 && ("
PLANTS = [
    # the READ column look-ahead loses its second-segment form (row splits read the wrong column)
    ("    la_rd_col16 <= rd_row2_n ? ({5'b0, rd_issued_n} - {5'b0, rd_seg_halfs_n})",
     "    la_rd_col16 <= 1'b0 ? ({5'b0, rd_issued_n} - {5'b0, rd_seg_halfs_n})", "adqm1-90-128mb"),
    # WRITE_BURST's auto-precharge rides the half after the segment's last
    ("    la_wb_last  <= (la_h_n == ({2'b0, wr_seg_h_n} - 5'd1));",
     "    la_wb_last  <= (la_h_n == {2'b0, wr_seg_h_n});", "adqm1-90-128mb"),
    # the gather write's slot test one slot late
    ("    la_gw       <= (gk_wc_n < gk_wtot);", "    la_gw       <= (gk_wc < gk_wtot);", "adqm1-90-128mb"),
    # REFRESH's second AUTO REFRESH (two-chip module) read from the current cycle
    ("    la_crc      <= (cycle_n == T_RC);", "    la_crc      <= (cycle == T_RC);", "adqm1-90-128mb"),
    # the DQM-less RMW read issues one cycle early
    ("    la_rmw_iss  <= (cycle_n >= rmw_c0_n) && (rmw_issued_n < rmw_total_reads_n);",
     "    la_rmw_iss  <= (cycle_n >= rmw_c0_n - 5'd1) && (rmw_issued_n < rmw_total_reads_n);", "adqm0-90-64mb"),
]


def run(cmd, log):
    with open(log, "w") as f:
        return subprocess.run(cmd, cwd=REPO, stdout=f, stderr=subprocess.STDOUT).returncode


def one(rev, cfg, new_text, tag):
    name, adqm, freq, size, nce = cfg
    w = os.path.join(WORK, tag)
    shutil.rmtree(w, ignore_errors=True)
    os.makedirs(w)
    old = subprocess.run(["git", "show", "%s:%s" % (rev, SDRAM)], cwd=REPO, capture_output=True,
                         text=True, check=True).stdout
    if "\nmodule sdram " not in old and "\nmodule sdram\n" not in old and "\nmodule sdram #" not in old:
        sys.exit("no `module sdram` in %s:%s" % (rev, SDRAM))
    old = old.replace("\nmodule sdram", "\nmodule sdram_ref", 1)
    open(os.path.join(w, "sdram_ref.v"), "w").write(old)
    open(os.path.join(w, "sdram.v"), "w").write(new_text)
    defs = ["+define+PE_ADQM=%s" % adqm, "+define+PE_FREQ=%s" % freq, "+define+PE_SIZE=%s" % size,
            "+define+PE_NCE=%s" % nce]
    jobs = os.environ.get("VERILATOR_JOBS", "2")
    rc = run(["verilator", "--binary", "--timing", "-O2", "-j", jobs, "-Wno-fatal", "-Wno-lint",
              "-Wno-style", "-Wno-MULTIDRIVEN"] + defs +
             ["--top-module", "tb_sdram_pin_equiv", "--Mdir", os.path.join(w, "obj"),
              os.path.join(w, "sdram.v"), os.path.join(w, "sdram_ref.v"), CHIP, TB],
             os.path.join(w, "build.log"))
    if rc:
        return False, "BUILD FAILED (%s)" % os.path.join(w, "build.log")
    log = os.path.join(w, "run.log")
    rc = run([os.path.join(w, "obj", "Vtb_sdram_pin_equiv")], log)
    out = open(log).read()
    ok = rc == 0 and "\nTB_SDRAM_PIN_EQUIV: PASS" in "\n" + out
    stat = [ln for ln in out.splitlines() if ln.startswith("ADQM=")]
    first = [ln for ln in out.splitlines() if "MISMATCH" in ln or "Error" in ln or "fatal" in ln.lower()]
    return ok, (stat[0] if stat else "") + ((" | first: " + first[0].strip()) if first and not ok else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", default="HEAD", help="the earlier revision (default HEAD)")
    ap.add_argument("--selftest", action="store_true", help="also run every plant; each must FAIL")
    a = ap.parse_args()
    new = open(os.path.join(REPO, SDRAM)).read()
    bad = 0
    for cfg in CONFIGS:
        ok, msg = one(a.old, cfg, new, cfg[0])
        print("%-20s vs %s: %s  %s" % (cfg[0], a.old, "IDENTICAL" if ok else "DIFFERS", msg))
        bad += not ok
    if a.selftest:
        cmap = {c[0]: c for c in CONFIGS}
        for i, (x, y, cname) in enumerate(PLANTS):
            if new.count(x) != 1 or new.count(LA_CHECK) != 1:
                sys.exit("plant anchor must occur exactly once: %s" % x)
            t = new.replace(x, y).replace(LA_CHECK, LA_OFF)
            ok, msg = one(a.old, cmap[cname], t, "plant%d" % i)
            print("  plant %-64s %s" % (y.strip()[:64], "NOT caught" if ok else "caught"))
            bad += ok
    print("check_sdram_pin_equiv: %s" % ("FAIL" if bad else "PASS"))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

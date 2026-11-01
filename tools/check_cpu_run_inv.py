#!/usr/bin/env python3
"""check_cpu_run_inv.py -- prove the registered download gate (docs/timing.md, "the download gate").

pc9821_memory_subsystem's `cpu_run` and `loader_owns` used to OR in the LIVE
`ioctl_download && ioctl_index == IOCTL_INDEX` (`selected`), which put hps_io's register at the
head of the GVRAM write cone. cpu_run is now pc9821_rom_loader's own register and loader_owns is
`load_valid || !rom_ready`. Two facts make that safe, and this tool proves both over the REAL
loader (the tree is never edited; the properties are pasted into a copy):

 1. INDUCTION (yosys `sat -tempinduct`, every input free, the platform reset included, from the
    power-up image the loader's `initial` block declares):
      * cpu_run == (rom_ready && !load_error) in every cycle;
      * download_d implies !rom_ready (the loader clears rom_ready in its edge cycle and only
        sets it while deselected);
    and therefore the dropped term changes cpu_run and loader_owns ONLY in a cycle where
    `selected && !download_d` (the loader's own download edge, or a platform-reset cycle with a
    download selected), asserted directly.
 2. EQUIVALENCE (yosys equiv_make/equiv_simple/equiv_induct) of the rewritten loader against
    its text at BASE: rom_ready, load_error and every other output and register are unchanged
    (the new `cpu_run` output is demoted to an internal register for the match).

Part 1 holds on the working tree and is the default run. Part 2 compares against the pre-cut
revision BASE, so it is a record of the cut, valid only until the loader next changes; `--history`
runs it, and exits 2 (SKIP) in a clone without BASE.

--selftest plants defects that must each make a proof FAIL (the equivalence plants only with
--history).

  python3 tools/check_cpu_run_inv.py [--selftest] [--history]
"""
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOADER = "src/pc9821/core/pc9821_rom_loader.sv"
BASE = "651a1ad1"   # the loader before the registered gate

PROP = r"""
  // ---- check_cpu_run_inv.py (pasted into a copy; never in the tree) ----
  always @* begin
    assert (cpu_run == (rom_ready && !load_error));
    assert (!(download_d && rom_ready));
    // the subsystem's old cpu_run / loader_owns differ from the new ones only where
    // selected && !download_d
    assert ((cpu_run == (rom_ready && !load_error && !selected)) || (selected && !download_d));
    assert (((mem_valid || !rom_ready) == (selected || mem_valid || !rom_ready)) ||
            (selected && !download_d));
  end
"""

PORT = """    output reg         cpu_run
);"""

INDUCT_PLANTS = [
    # registered from the current flags instead of their next state (one cycle late)
    ("cpu_run    <= rom_ready_nx && !load_error_nx;", "cpu_run    <= rom_ready && !load_error;"),
    # the wrong power-up value
    ("    cpu_run      = 1'b0;", "    cpu_run      = 1'b1;"),
    # the edge no longer clears rom_ready
    ("  wire rom_ready_nx  = sel_edge ? 1'b0 :", "  wire rom_ready_nx  = 1'b0 ? 1'b0 :"),
]

EQUIV_PLANTS = [
    # the edge's clear outranks the out-of-range raise (the old NBA order had the raise last)
    ("  wire load_error_nx = bad_word ? 1'b1 : (sel_edge ? 1'b0 : load_error);",
     "  wire load_error_nx = sel_edge ? 1'b0 : (bad_word ? 1'b1 : load_error);"),
    # rom_ready published while a request is still in flight
    ("(saw_download && !selected && !busy && !load_error) ? 1'b1 :",
     "(saw_download && !selected && !load_error) ? 1'b1 :"),
]


def loader_text(plant=None):
    src = open(os.path.join(REPO, LOADER)).read()
    if plant:
        a, b = plant
        if src.count(a) != 1:
            sys.exit("plant anchor must occur exactly once: %r" % a)
        src = src.replace(a, b)
    return src


def yosys(script, files):
    os.makedirs(os.path.join(REPO, ".build"), exist_ok=True)
    with tempfile.TemporaryDirectory(dir=os.path.join(REPO, ".build")) as tmp:
        for name, text in files.items():
            open(os.path.join(tmp, name), "w").write(text)
        r = subprocess.run(["yosys", "-p", script], cwd=tmp, capture_output=True, text=True)
    return r


def prove_induct(plant=None):
    src = loader_text(plant)
    k = src.rindex("endmodule")
    src = src[:k] + PROP + src[k:]
    script = ("read_verilog -sv -formal l.sv; hierarchy -top pc9821_rom_loader; proc; "
              "chformal -lower; flatten; memory; opt_clean; setundef -undriven -anyseq; "
              "opt -fast; sat -tempinduct -prove-asserts -set-def-inputs -set-def-formal "
              "-seq 1 -set-at 1 reset 1 -maxsteps 4 -verify")
    r = yosys(script, {"l.sv": src})
    return r.returncode == 0, r.stdout[-2000:] + r.stderr[-800:]


def prove_equiv(plant=None):
    old = subprocess.run(["git", "show", "%s:%s" % (BASE, LOADER)], cwd=REPO,
                         capture_output=True, text=True)
    if old.returncode:
        sys.exit("git show failed: " + old.stderr)
    new = loader_text(plant)
    i = new.find("    output reg         saw_download,\n")
    j = new.find(PORT)
    if i < 0 or j < i:
        sys.exit("the cpu_run port declaration moved; re-point PORT")
    # demote the new output to an internal register, so both modules present one port list
    new = new[:i] + "    output reg         saw_download\n);\n  reg cpu_run;" + new[j + len(PORT):]
    old_t = old.stdout.replace("module pc9821_rom_loader", "module eqv_old", 1)
    new_t = new.replace("module pc9821_rom_loader", "module eqv_new", 1)
    script = ("read_verilog -sv old.sv new.sv; proc; opt_clean; memory -nomap; flatten; "
              "equiv_make eqv_old eqv_new eq; hierarchy -top eq; "
              "equiv_simple -seq 2; equiv_induct -seq 2; equiv_status -assert")
    r = yosys(script, {"old.sv": old_t, "new.sv": new_t})
    ok = r.returncode == 0 and "Equivalence successfully proven!" in r.stdout
    summary = [ln.strip() for ln in r.stdout.splitlines() if "are proven" in ln]
    return ok, (summary[-1] if summary else r.stdout[-1500:] + r.stderr[-800:])


def main():
    bad = 0
    history = "--history" in sys.argv
    if history and subprocess.run(["git", "cat-file", "-e", BASE + "^{commit}"], cwd=REPO,
                                  capture_output=True).returncode:
        print("SKIP: --history needs revision %s (the loader before the cut), which this clone "
              "does not hold" % BASE)
        sys.exit(2)
    ok, log = prove_induct()
    print("rom_loader cpu_run == rom_ready && !load_error, download_d -> !rom_ready, "
          "old/new gate differ only at selected && !download_d: %s" % ("PROVEN" if ok else "FAILED"))
    if not ok:
        print(log)
    bad += not ok
    if history:
        ok, msg = prove_equiv()
        print("rom_loader vs %s (every output and register but cpu_run): %s (%s)"
              % (BASE, "PROVEN" if ok else "NOT proven", msg))
        bad += not ok
    if "--selftest" in sys.argv:
        for p in INDUCT_PLANTS:
            pok, _ = prove_induct(p)
            print("  induct plant %s: %s" % ("NOT caught" if pok else "caught", p[1].strip()[:64]))
            bad += pok
        for p in (EQUIV_PLANTS if history else []):
            pok, _ = prove_equiv(p)
            print("  equiv plant %s: %s" % ("NOT caught" if pok else "caught", p[1].strip()[:64]))
            bad += pok
        print("check_cpu_run_inv: selftest %s" % ("FAIL" if bad else "PASS"))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

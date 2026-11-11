#!/usr/bin/env python3
"""check_iobus_hit_equiv.py -- prove pc9821_iobus's predecoded hit[] lines equal the full compares.

pc9821_iobus decodes every SYSTEM port as `hit[HX_xxxx] = (hb_HH && lb_LL)` over shared byte
compares of port_addr. The form before that was `hit[HX_xxxx] = (port_addr == 16'hHHLL)`. This tool
reads both revisions (the working tree and --old, default the last full-compare revision),
rebuilds every line as a yosys expression over ONE free 16-bit port_addr (and MPU_EN), and runs a
SAT proof that the two vectors are identical for every port and both MPU_EN values. It also checks
the predicate that the parallel_case in the same file rests on: no two lines of the new form
can be set by one port (at most one-hot).

THE DEVICE HALF IS NOT HERE ANY MORE (P5, structural-refactors-20261017.md): pc9821_iobus's 85
device-bus match lines were deleted and that claim moved to pc9821_device_select's `dev_bus_cs`,
which `tb_pc9821_device_select` sweeps against the old list verbatim. So the two revisions need
not name the same lines; what this tool requires is:
  * every line the working tree names also exists in --old (a renamed/dropped SYSTEM line is a
    defect, not a refactor), except a SYSTEM port added since: its reference is the full compare
    its own name spells (`hit[HX_006C]` against `port_addr == 16'h006C`), so a new line is
    proved like every old one and cannot answer a port its name does not, and
  * the set the working tree no longer names is EXACTLY the old revision's device half, taken
    from that revision's own `pc9821_ports_pkg.sv` (the constants whose index is below the first
    system index, 85 there) -- so the deletion cannot quietly take a system port with it.

--selftest plants a wrong low byte in one line of the new text and requires the proof to FAIL, and
a dropped system line must be refused.

  python3 tools/check_iobus_hit_equiv.py [--old REV] [--selftest]
"""
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = "src/pc9821/core/pc9821_iobus.sv"
PKG = "src/pc9821/core/pc9821_ports_pkg.sv"
FULL_REV = "6304b310"   # the last revision whose hit[] lines were the full `port_addr == 16'h....` compares
DEVICE_HALF = 85        # the pre-P5 split: hit[0..84] were the device ports, hit[85..193] the system ones
LINE = re.compile(r"^\s*assign hit\[(HX_\w+)\] = (.*);\s*$", re.M)


def lines(text):
    out = {}
    for m in LINE.finditer(text):
        out[m.group(1)] = m.group(2)
    return out


def order(text):
    """The names in the order the file assigns them (the two halves are contiguous runs)."""
    return [m.group(1) for m in LINE.finditer(text)]


def helpers(text):
    return "\n".join(m.group(0).strip() for m in re.finditer(r"^\s*wire (?:hb|lb)_[0-9A-F]{2} = .*;\s*$", text, re.M))


def git_show(rev, path):
    r = subprocess.run(["git", "show", "%s:%s" % (rev, path)], cwd=REPO,
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit("git show %s:%s failed:\n%s" % (rev, path, r.stderr))
    return r.stdout


ADDED_REF = {}   # name -> the full compare its name spells, for a SYSTEM line added since --old


def build(old, new, names):
    lo, ln = lines(old), lines(new)
    lo.update(ADDED_REF)
    v = ["module m(input wire [15:0] port_addr, input wire MPU_EN, output wire mismatch, output wire multi);"]
    v.append(helpers(new))
    n = len(names)
    v.append("  wire [%d:0] ho, hn;" % (n - 1))
    for i, name in enumerate(names):
        v.append("  assign ho[%d] = %s;" % (i, lo[name]))
        v.append("  assign hn[%d] = %s;" % (i, ln[name]))
    v.append("  assign mismatch = (ho != hn);")
    # at most one hot (the old form is distinct-constant equalities; prove it on the new)
    v.append("  wire [%d:0] below = hn & (hn - %d'd1);" % (n - 1, n))
    v.append("  assign multi = (below != %d'd0);" % n)
    v.append("endmodule")
    return "\n".join(v)


def prove(old, new, names):
    text = build(old, new, names)
    os.makedirs(os.path.join(REPO, ".build"), exist_ok=True)
    with tempfile.TemporaryDirectory(dir=os.path.join(REPO, ".build")) as tmp:
        open(os.path.join(tmp, "m.sv"), "w").write(text)
        script = ("read_verilog -sv m.sv; hierarchy -top m; proc; flatten; opt; "
                  "sat -prove mismatch 0 -prove multi 0 -verify")
        r = subprocess.run(["yosys", "-q", "-p", script], cwd=tmp, capture_output=True, text=True)
    return r.returncode == 0, r.stdout[-2000:] + r.stderr[-1500:]


def device_names(old_pkg, old):
    """The names the OLD revision called device ports, from its own package's indices."""
    idx = {m.group(1): int(m.group(2))
           for m in re.finditer(r"(HX_[0-9A-F]{4}) = (\d+)", old_pkg)}
    dev = {k for k, v in idx.items() if v < DEVICE_HALF}
    return dev


def main():
    rev = FULL_REV
    if "--old" in sys.argv:
        rev = sys.argv[sys.argv.index("--old") + 1]
    old = git_show(rev, SRC)
    old_pkg = git_show(rev, PKG)
    new = open(os.path.join(REPO, SRC)).read()

    lo, ln = lines(old), lines(new)
    dropped = set(lo) - set(ln)
    added = set(ln) - set(lo)
    bad = 0
    for name in sorted(added):
        if not re.fullmatch(r"HX_[0-9A-F]{4}", name):
            sys.exit("the working tree names a hit[] line %s that --old %s does not, and its name "
                     "spells no port to prove it against" % (name, rev))
        ADDED_REF[name] = "(port_addr == 16'h%s)" % name[3:]
    if added:
        print("hit[] lines added since %s, each proved against the compare its name spells: %s"
              % (rev, ", ".join(sorted(added))))
    dev = device_names(old_pkg, old)
    if dropped:
        if dropped != dev:
            sys.exit("the working tree dropped %s, which is not exactly the old revision's device "
                     "half (%d names)" % (sorted(dropped), len(dev)))
        print("hit[] lines dropped == the pre-P5 device half: %d names" % len(dropped))
    names = sorted(ln)
    ok, log = prove(old, new, names)
    print("iobus hit[] lines (%d) == the full 16-bit compares, and at most one-hot: %s"
          % (len(names), "PROVEN" if ok else "FAILED"))
    if not ok:
        print(log)
        bad += 1

    if "--selftest" in sys.argv:
        m = re.search(r"assign hit\[HX_0044\] = \(hb_00 && lb_44\);", new)
        if not m:
            sys.exit("selftest anchor moved")
        planted = new.replace(m.group(0), "assign hit[HX_0044] = (hb_00 && lb_42);")
        pok, _ = prove(old, planted, names)
        print("  plant (wrong low byte) %s" % ("NOT caught" if pok else "caught"))
        bad += pok
        # a dropped SYSTEM line must be refused before any proof is attempted
        gone = new.replace("assign hit[HX_0044] = (hb_00 && lb_44);\n", "")
        try:
            p2 = lines(gone)
            dropped2 = set(lo) - set(p2)
            refused = dropped2 != dev
        except SystemExit:
            refused = True
        print("  plant (a system line dropped) %s" % ("caught" if refused else "NOT caught"))
        bad += 0 if refused else 1
        # an ADDED line answering a port its name does not spell must fail the proof too
        for name in sorted(added):
            m = re.search(r"assign hit\[%s\] = \(hb_(..) && lb_(..)\);" % name, new)
            if not m:
                continue
            wrong = "%02X" % (int(m.group(2), 16) ^ 0x01)
            planted = new.replace(m.group(0), "assign hit[%s] = (hb_%s && lb_%s);"
                                  % (name, m.group(1), wrong))
            if "wire lb_%s " % wrong not in planted:
                planted = planted.replace("  wire lb_%s " % m.group(2),
                                          "  wire lb_%s = (port_addr[7:0] == 8'h%s);\n  wire lb_%s "
                                          % (wrong, wrong, m.group(2)), 1)
            pok, _ = prove(old, planted, names)
            print("  plant (an added line, wrong low byte) %s" % ("NOT caught" if pok else "caught"))
            bad += pok
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

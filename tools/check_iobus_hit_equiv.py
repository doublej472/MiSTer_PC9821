#!/usr/bin/env python3
"""check_iobus_hit_equiv.py -- prove pc9821_iobus's predecoded hit[] lines equal the full compares.

pc9821_iobus decodes every SYSTEM port as `hit[HX_HHLL] = (hb_HH && lb_LL)` over shared byte
compares of port_addr. The form before that was the full compare `hit[HX_HHLL] = (port_addr ==
16'hHHLL)`, which every line's own name spells. The default proof needs only the working tree: it
rebuilds every line as a yosys expression over ONE free 16-bit port_addr (and MPU_EN) and runs a
SAT proof that each equals the full compare its name spells, for every port and both MPU_EN
values, and that no two lines can be set by one port (at most one-hot: the predicate the
parallel_case in the same file rests on).

--history adds the record of the cut, against the revision whose lines were still the full
compares (--old REV, default FULL_REV below): every line both revisions name is proved equal to the
old revision's text, and the set the working tree no longer names must be EXACTLY that revision's
device half (the P5 structural refactor moved those 85 lines to pc9821_device_select's
`dev_bus_cs`, which `tb_pc9821_device_select` sweeps), taken from its own `pc9821_ports_pkg.sv`, so
the deletion cannot have taken a system port with it. A clone without that revision (a squashed
release) exits 2 (SKIP), never a pass.

--selftest plants a wrong low byte in one line and requires the proof to FAIL; with --history it
also requires the history check to refuse a dropped system line.

  python3 tools/check_iobus_hit_equiv.py [--selftest] [--history [--old REV]]
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


def helpers(text):
    return "\n".join(m.group(0).strip() for m in re.finditer(r"^\s*wire (?:hb|lb)_[0-9A-F]{2} = .*;\s*$", text, re.M))


def git_show(rev, path):
    """The text of path at rev, or None when this clone does not carry rev."""
    r = subprocess.run(["git", "show", "%s:%s" % (rev, path)], cwd=REPO,
                       capture_output=True, text=True)
    return None if r.returncode else r.stdout


def spelled(names):
    """name -> the full compare its name spells: the reference every line is proved against."""
    return {n: "(port_addr == 16'h%s)" % n[3:] for n in names}


def build(ref, new, names):
    """A miter of each line of new against ref[name], plus the one-hot predicate on new."""
    ln = lines(new)
    v = ["module m(input wire [15:0] port_addr, input wire MPU_EN, output wire mismatch, output wire multi);"]
    v.append(helpers(new))
    n = len(names)
    v.append("  wire [%d:0] ho, hn;" % (n - 1))
    for i, name in enumerate(names):
        v.append("  assign ho[%d] = %s;" % (i, ref[name]))
        v.append("  assign hn[%d] = %s;" % (i, ln[name]))
    v.append("  assign mismatch = (ho != hn);")
    v.append("  wire [%d:0] below = hn & (hn - %d'd1);" % (n - 1, n))
    v.append("  assign multi = (below != %d'd0);" % n)
    v.append("endmodule")
    return "\n".join(v)


def prove(ref, new, names):
    text = build(ref, new, names)
    os.makedirs(os.path.join(REPO, ".build"), exist_ok=True)
    with tempfile.TemporaryDirectory(dir=os.path.join(REPO, ".build")) as tmp:
        open(os.path.join(tmp, "m.sv"), "w").write(text)
        script = ("read_verilog -sv m.sv; hierarchy -top m; proc; flatten; opt; "
                  "sat -prove mismatch 0 -prove multi 0 -verify")
        r = subprocess.run(["yosys", "-q", "-p", script], cwd=tmp, capture_output=True, text=True)
    return r.returncode == 0, r.stdout[-2000:] + r.stderr[-1500:]


def name_problems(new):
    """Every line's name must spell a port: that is the reference it is proved against."""
    return ["hit[%s] spells no port to prove it against" % n
            for n in lines(new) if not re.fullmatch(r"HX_[0-9A-F]{4}", n)]


def device_names(old_pkg, old):
    """The names the OLD revision called device ports, from its own package's indices."""
    idx = {m.group(1): int(m.group(2))
           for m in re.finditer(r"(HX_[0-9A-F]{4}) = (\d+)", old_pkg)}
    dev = {k for k, v in idx.items() if v < DEVICE_HALF}
    return dev


def history_problems(old, old_pkg, new):
    """The cut's record: what the working tree dropped is exactly the old device half."""
    lo, ln = lines(old), lines(new)
    dropped = set(lo) - set(ln)
    dev = device_names(old_pkg, old)
    if dropped and dropped != dev:
        return ["the working tree dropped %s, which is not exactly the old revision's device "
                "half (%d names)" % (sorted(dropped - dev) or sorted(dev - dropped), len(dev))]
    return []


def history_ref(old, new):
    """The old revision's text for every line both name; a line added since keeps the full
    compare its name spells."""
    ref = spelled(lines(new))
    ref.update({n: e for n, e in lines(old).items() if n in ref})
    return ref


def main():
    history = "--history" in sys.argv
    rev = FULL_REV
    if "--old" in sys.argv:
        rev = sys.argv[sys.argv.index("--old") + 1]
        history = True
    new = open(os.path.join(REPO, SRC)).read()
    names = sorted(lines(new))
    bad = 0
    for p in name_problems(new):
        print("FAIL:", p)
        bad += 1
    if bad:
        sys.exit(1)
    ok, log = prove(spelled(names), new, names)
    print("iobus hit[] lines (%d) == the full 16-bit compares their names spell, and at most "
          "one-hot: %s" % (len(names), "PROVEN" if ok else "FAILED"))
    if not ok:
        print(log)
        bad += 1

    old = old_pkg = None
    if history:
        old, old_pkg = git_show(rev, SRC), git_show(rev, PKG)
        if old is None or old_pkg is None:
            print("SKIP: --history needs revision %s, which this clone does not carry" % rev)
            sys.exit(2 if not bad else 1)
        for p in history_problems(old, old_pkg, new):
            print("FAIL:", p)
            bad += 1
        added = sorted(set(names) - set(lines(old)))
        if added:
            print("hit[] lines added since %s, each proved against the compare its name spells: %s"
                  % (rev, ", ".join(added)))
        hok, hlog = prove(history_ref(old, new), new, names)
        print("history: the lines == revision %s's text, and the dropped set == its device half "
              "(%d names): %s" % (rev, len(device_names(old_pkg, old)),
                                  "PROVEN" if hok and not bad else "FAILED"))
        if not hok:
            print(hlog)
            bad += 1

    if "--selftest" in sys.argv:
        m = re.search(r"assign hit\[HX_0044\] = \(hb_00 && lb_44\);", new)
        if not m:
            sys.exit("selftest anchor moved")
        planted = new.replace(m.group(0), "assign hit[HX_0044] = (hb_00 && lb_42);")
        pok, _ = prove(spelled(names), planted, names)
        print("  plant (wrong low byte) %s" % ("NOT caught" if pok else "caught"))
        bad += pok
        renamed = new.replace("assign hit[HX_0044]", "assign hit[HX_SYS44]")
        caught = bool(name_problems(renamed))
        print("  plant (a line whose name spells no port) %s" % ("caught" if caught else "NOT caught"))
        bad += 0 if caught else 1
        if history:
            # a dropped SYSTEM line must be refused by the same function main() runs
            gone = new.replace(m.group(0) + "\n", "")
            refused = bool(history_problems(old, old_pkg, gone))
            print("  plant (a system line dropped) %s" % ("caught" if refused else "NOT caught"))
            bad += 0 if refused else 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

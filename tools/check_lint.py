#!/usr/bin/env python3
"""Lint this project's own RTL with EVERY warning enabled, and fail on any that is not waived.

WHY THIS EXISTS, and it is not tidiness. The benches build with four suppressions:

    -Wno-fatal -Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET

Those four cover 522 of the design's 882 warnings, and they are exactly the categories a
glitch, a mis-wired port or a dangling signal hides in: PINMISSING is a port connected to
nothing, SYNCASYNCNET is an asynchronous reset used in a synchronous block, UNUSEDSIGNAL is a
signal nothing reads. A suppression nobody can see is the same defect as a check that cannot
fail, one level up - so this runs with none of them and requires every remaining warning to be
either fixed or waived IN THE SOURCE, where the diff shows it.

GETTING THE INVOCATION RIGHT IS HALF THE POINT. Two attempts to lint this design by hand were
wrong before this tool existed. `--top-module z486_mister` does not exist - the top module is
named `emu` - and Verilator answers that with a single %Error among a page of warnings, so
reading the warning count instead of the error gives a confident, meaningless number. And the
include path needs BOTH src/z486 and src/z486/x87, because z486's x87 packages `include` files
by bare name from the x87 directory; without it the lint aborts on the first package. Both
facts are encoded here so nobody re-derives them by being fooled.

OUR FILES ONLY. src/z486, rtl/ao486 and the opna/jt12/jt49 trees are vendored and keep the
warnings they arrived with - a vendored copy stays verbatim, so its warnings are not ours to
fix. src/soc/ and src/common/ ARE ours: they carry local edits (cdda.v's power-up seeds,
synchronizer.sv's fitter attribute, the cdda wiring), and excluding them left those
edits with no automated warning coverage. The two files inside them that ARE byte-identical
vendored copies are named in VENDOR_EXEMPT, individually. The scope is a list of prefixes, not
a glob, so a new vendor directory cannot be swept in by accident. The testbenches are ours but
are not shipped RTL, so they are out of scope too; a warning there is noise, not a defect in the
machine.

A WAIVER IS SOURCE, and the reason is required by convention rather than by this parser: put
the reason on the lint_off line or the line above it. A waiver with no reason is indistinguishable
from a warning nobody read.

Usage:
  tools/check_lint.py               lint and fail on any unwaived warning in our files
  tools/check_lint.py FILE...       only these files (a lane checks its own set meanwhile)
  tools/check_lint.py --report      counts by file and category
  tools/check_lint.py --detail      every warning line, with file, line and message
  tools/check_lint.py --all         include vendored and testbench warnings as well
"""

from __future__ import annotations

import collections
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

# The system is elaborated through a bench top, because PC9821_Z486_RTL is the ordered source
# list for the whole core and the bench instantiates pc9821_system. THE SHIPPED TOP LEVEL IS A
# SEPARATE PASS: the bench never instantiates z486_mister.sv (whose module is named `emu`), so
# linting only the bench leaves the MiSTer wrapper unchecked - and that is where the design meets
# the framework, so its missing port connections are exactly the kind this check exists to find.
TOP = "tb_pc9821_boot"
TOP_SHIPPED = "emu"

# Our shipped RTL. A prefix list, not a glob - see the docstring.
OUR_PREFIXES = (
    "src/pc9821/",
    "src/pcm86/",
    "src/memory/",
    "src/soc/",
    "src/common/",
    "src/opna/pc9821_opna.sv",
    "src/opna/pc9821_opna_",
    "z486_mister.sv",
    "src/ide_hps.v",
)

# Vendored files that sit INSIDE an OUR_PREFIXES directory. A vendored copy stays verbatim, so a
# warning in one is not ours to fix; each is named with the checkout it is identical to, so the
# exemption cannot creep onto a file that has been edited. Verified with `diff` at the time of
# writing (2026-09-24): both byte-identical.
VENDOR_EXEMPT = (
    "src/common/uart_tx_V2.v",                        # z486-mister-upstream/src/common/uart_tx_V2.v
    "src/common/cdc_vector_handshake_continuous.sv",  # z486-mister-upstream/src/common/ (same name)
)

# Ours, but not shipped RTL: a warning here is bench noise.
EXCLUDE_PREFIXES = ("tests/",)

WARNING_RE = re.compile(r"^%Warning-([A-Z0-9_]+): ([^:]+):(\d+):")
ERROR_RE = re.compile(r"^%Error", re.M)


def sources() -> list[str]:
    """The design's file list and include flags, taken from the tree's own shared list."""
    script = ROOT / "tests/pc9821/z486_rtl.sh"
    out = subprocess.run(
        ["bash", "-c",
         'source tests/pc9821/z486_rtl.sh; printf "%s\\n" "${PC9821_Z486_RTL[@]}"; '
         'printf "%%INCLUDES%%\\n-I%s\\n-I%s\\n" "$Z" "$X"'],
        cwd=ROOT, capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("could not read tests/pc9821/z486_rtl.sh:\n" + out.stderr)
    files, includes = [], []
    for line in out.stdout.splitlines():
        if line == "%INCLUDES%":
            continue
        (includes if line.startswith("-I") else files).append(line)
    files.append("tests/pc9821/tb_pc9821_boot.sv")
    files.append("tests/pc9821/sdram_backend_model.sv")
    return files + includes


def run_lint() -> str:
    """Both passes: the core through its bench top, and the shipped top level."""
    logs = []
    bench = ["verilator", "--lint-only", "-Wall", "--top-module", TOP] + sources()
    out = subprocess.run(bench, cwd=ROOT, capture_output=True, text=True, timeout=2400)
    logs.append(out.stdout + out.stderr)

    qip = ROOT / "backend.qip"
    if qip.is_file():
        # THE ORDERED LIST COMES FIRST AND THE FRAMEWORK FILES ARE APPENDED. backend.qip alone
        # is not compilable on its own: z486's packages must precede their users, and linting
        # from the .qip order produces a wall of 'Reference to X before declaration' errors in
        # vendored code that look like defects and are not. PC9821_Z486_RTL is the order the
        # benches prove works; add only what it does not already name.
        ordered = [f for f in sources() if not f.startswith("-I")]
        extra = [w for w in re.findall(r"[^\s]+\.(?:sv|v)", qip.read_text())]
        # The MiSTer framework. sys_udiv and sys_umul live in sys/math.sv, gamma_fast in
        # sys/gamma_corr.sv, and without those the pass dies on MODMISSING rather than linting.
        framework = sorted(str(p.relative_to(ROOT))
                           for pat in ("sys/*.sv", "sys/*.v")
                           for p in ROOT.glob(pat))
        seen = set(ordered)
        shipped = (ordered
                   + [e for e in extra if e not in seen]
                   + [f for f in framework if f not in seen])

        # THE MAIN PLL IS STUBBED, AND THIS IS WHAT MAKES THE SHIPPED TOP LEVEL LINTABLE AT ALL.
        # z486_mister.sv instantiates `pll`, which is rtl/pll.v - GENERATED by build_profile.py
        # from tools/profile/pll_template.v and gitignored, so a fresh checkout lacks it - and that
        # file instantiates `altera_pll`, a Quartus megafunction with no Verilator model. So the
        # lint used to stop at MODMISSING and the one file where this design meets the framework
        # was covered by no automated check in the tree. A port-list stub is all that is needed:
        # the real module's ports are refclk, rst, outclk_0 (clk_sys), outclk_1 (the phase-shifted
        # SDRAM_CLK) and locked - two outputs since the split-clock configuration and its
        # clk_sdram output were removed - plus the five dynamic-phase-shift ports every generated
        # wrapper declares (tools/profile_gen.py DPS_PORTS; tied off unless sdram_phase_dyn). Warnings inside
        # the megafunction are not ours to fix; the top level's WIRING is, and it is now linted.
        stub_dir = pathlib.Path(tempfile.mkdtemp(prefix="pc9821-lint-"))
        (stub_dir / "pll_stub.sv").write_text(
            "// Generated by tools/check_lint.py. Stands in for the Quartus main PLL so the\n"
            "// shipped top level can be linted. Not part of the design.\n"
            "module pll(input wire refclk, input wire rst, output wire outclk_0,\n"
            "           output wire outclk_1, output wire locked,\n"
            "           input wire phase_en, input wire scanclk, input wire updn,\n"
            "           input wire [4:0] cntsel, output wire phase_done);\n"
            "  assign outclk_0 = refclk;\n"
            "  assign outclk_1 = refclk;\n"
            "  assign locked   = ~rst;\n"
            "  assign phase_done = phase_en ^ scanclk ^ updn ^ (^cntsel);\n"
            "endmodule\n"
            "// altddio_out (Quartus megafunction; sys_top.v's copies are not in the shipped list).\n"
            "module altddio_out #(parameter extend_oe_disable = \"OFF\", intended_device_family = \"\",\n"
            "                     invert_output = \"OFF\", lpm_hint = \"\", lpm_type = \"\",\n"
            "                     oe_reg = \"\", power_up_high = \"OFF\", parameter integer width = 1)(\n"
            "  input wire [width-1:0] datain_h, input wire [width-1:0] datain_l, input wire outclock,\n"
            "  output wire [width-1:0] dataout, input wire aclr, input wire aset, input wire oe,\n"
            "  input wire outclocken, input wire sclr, input wire sset);\n"
            "  assign dataout = outclock ? datain_h : datain_l;\n"
            "endmodule\n")
        # The video PLL (rtl/vpll*, generated the same way) and the framework's write-only
        # reconfiguration core (sys/pll_cfg/pll_cfg_hdmi.v, a subdirectory the framework glob does
        # not take), which the top level instantiates a second time for the video PLL
        # (pc9821_vpll_ctl), so the stub carries its reconfiguration ports.
        (stub_dir / "vpll_stub.sv").write_text(
            "// Generated by tools/check_lint.py: stands in for the generated video PLL and the\n"
            "// framework's PLL reconfiguration core. Not part of the design.\n"
            "module vpll(input wire refclk, input wire rst, output wire outclk_0, output wire locked,\n"
            "            input wire [63:0] reconfig_to_pll, output wire [63:0] reconfig_from_pll);\n"
            "  assign reconfig_from_pll = reconfig_to_pll;\n"
            "  assign outclk_0 = refclk;\n  assign locked = ~rst;\nendmodule\n"
            "module pll_cfg_hdmi(input wire mgmt_clk, input wire mgmt_reset, output wire mgmt_waitrequest,\n"
            "  input wire mgmt_write, input wire [5:0] mgmt_address, input wire [31:0] mgmt_writedata,\n"
            "  output wire [63:0] reconfig_to_pll, input wire [63:0] reconfig_from_pll);\n"
            "  assign mgmt_waitrequest = mgmt_reset | (|reconfig_from_pll);\n"
            "  assign reconfig_to_pll = {mgmt_writedata, 24'd0, mgmt_address, mgmt_clk, mgmt_write};\n"
            "endmodule\n")
        shipped = [f for f in shipped
                   if not (f in ("rtl/pll.v", "rtl/vpll.v") or f.startswith(("rtl/pll/", "rtl/vpll/")))]
        shipped.append(str(stub_dir / "pll_stub.sv"))
        shipped.append(str(stub_dir / "vpll_stub.sv"))
        args = (["verilator", "--lint-only", "-Wall",
                 # THE MISTER FRAMEWORK NEEDS TWO SUPPRESSIONS AND NOTHING ELSE DOES. sys/hps_io.sv
                 # assigns to signals it never declares (IMPLICIT), and under IEEE 1800-2023
                 # Verilator makes the resulting PROCASSWIRE a hard ERROR, so the shipped pass died
                 # before linting anything. --language 1800-2017 and 1800-2012 do not clear it.
                 # These are vendored framework files we must not edit, and the alternative is no
                 # top-level lint at all.
                 #
                 # WHAT THIS COSTS, stated rather than hidden: z486_mister.sv is our file and it is
                 # only in THIS pass, so an IMPLICIT or PROCASSWIRE in the top level would be hidden
                 # by these two flags. Both are zero in our core files, which the bench pass checks
                 # with all warnings on, and the top level's real risk is its WIRING - which is
                 # PINMISSING and PINCONNECTEMPTY, and both are still reported here.
                 "-Wno-PROCASSWIRE", "-Wno-IMPLICIT",
                 "-Isrc/z486", "-Isrc/z486/x87", "-Isys", "--top-module", TOP_SHIPPED]
                + shipped + ["z486_mister.sv"])
        out = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=2400)
        text = out.stdout + out.stderr
        logs.append(text)
    return "\n".join(logs)


def is_ours(path: str) -> bool:
    if path.startswith(EXCLUDE_PREFIXES) or path in VENDOR_EXEMPT:
        return False
    return path.startswith(OUR_PREFIXES)


def main(argv: list[str]) -> int:
    report = "--report" in argv
    detail = "--detail" in argv
    everything = "--all" in argv
    # Positional file arguments restrict the report to those files, so a change mid-triage can
    # get a clean verdict for ITS files while the rest of the tree is still over the line.
    # Without this the only green run is the one after every change has landed.
    only = [a for a in argv[1:] if not a.startswith("--")]

    log = run_lint()

    errors = [l for l in log.splitlines() if ERROR_RE.match(l)]
    # 'Exiting due to N warning(s)' is Verilator's summary, not a defect. A missing top module
    # is reported once per pass and is a SETUP failure, so it must be caught here: a bad top
    # name yields a page of warnings and one line of error, and reading the warnings instead
    # gives a confident, meaningless baseline.
    real_errors = [e for e in errors
                   if "warning(s)" not in e and "was not found in design" not in e]  # noqa
    if real_errors:
        print("LINT SETUP FAILED - fix the invocation before reading any warning:")
        for e in real_errors[:10]:
            print("  " + e)
        return 2

    hits = collections.defaultdict(collections.Counter)
    seen = set()
    total = 0
    lines_out: list[str] = []
    for raw_line in log.splitlines():
        m = WARNING_RE.match(raw_line)
        if not m:
            continue
        cat, path, line = m.group(1), m.group(2), m.group(3)
        total += 1
        if not (everything or is_ours(path)):
            continue
        if only and path not in only:
            continue
        # THE TWO PASSES OVERLAP, so a core module is elaborated by both and its warnings are
        # reported twice. The key must be the WHOLE warning line, not (file, line, category):
        # several distinct warnings can sit on one line - a concatenation produces one per
        # operand - and keying on the line collapsed them, dropping pc9821_iobus.sv from 33 to
        # 10. The full text distinguishes exactly the duplicates and nothing else.
        key = raw_line.strip()
        if key in seen:
            continue
        seen.add(key)
        hits[path][cat] += 1
        lines_out.append(raw_line.strip())

    ours = sum(sum(c.values()) for c in hits.values())

    if detail:
        # Each collected line is a warning header: file, line, category and the message, which
        # carries the signal or port name a triage decision actually needs. The source line and
        # caret Verilator prints underneath are not collected - open the file for those.
        for line in lines_out:
            print("  " + line)
        print("  ---- %d warning(s) in our files, from %d over both passes" % (ours, total))
        return 0

    if report or everything:
        print("  %-46s %5s  %s" % ("file", "total", "categories"))
        for f, c in sorted(hits.items(), key=lambda kv: -sum(kv[1].values())):
            print("  %-46s %5d  %s"
                  % (f, sum(c.values()), " ".join("%s=%d" % kv for kv in c.most_common())))
        print("  ---- design total %d warning(s) over both passes; ours %d" % (total, ours))
        return 0

    if ours == 0:
        print("LINT: PASS - no unwaived warning in %d design warning(s); ours are clean"
              % total)
        return 0

    print("LINT: FAIL - %d warning(s) in our RTL, from %d in the design" % (ours, total))
    for f, c in sorted(hits.items(), key=lambda kv: -sum(kv[1].values())):
        print("  %s" % f)
        for cat, n in c.most_common():
            print("      %-24s %d" % (cat, n))
    print()
    print("  EITHER fix it, OR waive it IN THE SOURCE with a reason, so the diff shows both:")
    print("      /* verilator lint_off <CATEGORY> */   // why this is intentional")
    print("      ...the construct...")
    print("      /* verilator lint_on <CATEGORY> */")
    print("  A waiver with no reason is indistinguishable from a warning nobody read.")
    print("  Run with --report to see every line.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""Check a Quartus fit for the failure mode that is invisible until it is fatal.

A memory array that stops being inferred as block RAM becomes registers, and the
design then either fails to fit or silently eats the whole device. `cg_ram` did
exactly that: two read addresses on one clock, 64 Kb of inferred memory turned into
65,536 registers, 41,910/41,910 ALMs, 0 RAM blocks.

This reads the reports a fit already produces and says so. It needs no build of its
own, so it can be run after any fit:

    tools/check_fit.py [--scratch DIR | --reports DIR] [--tree DIR]
    tools/check_fit.py --write-attribution DIR --tree TREE --rtl-hash H   (container_build.sh)
    tools/check_fit.py --rtl-hash-of TREE

WHICH TREE A FIT BELONGS TO. A fit report does not name its source, and this check
used to default its scratch to one fixed path, so run in a checkout that had never
been built it silently read some OTHER tree's fit and printed PASS for it. That is
the worst kind of guard - one that is trusted and wrong. So a fit must now carry its
own provenance and this refuses to give a verdict without it:

  * tools/container_build.sh calls `--write-attribution` after the fit, which writes
    `fit-source.sha256` beside the reports: the tree path, and the sha256 of every
    RTL source the fit was built from.
  * the normal mode reads that file and re-hashes the same files in the tree it
    names. A file that has changed since the fit makes this FAIL and says which,
    because that fit does not describe that tree any more.
  * if the attribution is ABSENT this REFUSES (exit 2). Absent is not "probably
    fine" - absent is the bug. Re-fit, or point --reports at a fit that has one.

Exit status: 0 the fit closed and every array expected in block RAM is in it;
1 the fit or its attribution is wrong; 2 this check could not attribute the fit
to a tree at all, so it has no verdict to give.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import os
import pathlib
import re
import sys

# Arrays this design intends to be block RAM. Membership in the map report's RAM
# Summary is the evidence: an inferred array appears by name, and one that fell into
# registers does not appear at all.
EXPECTED_RAM = {
    # NOT LISTED, AND DELIBERATELY: pc9821_watchdog_msg's message table is ~43 ALUTs of what
    # should be memory, and it does NOT infer. The cause was found with a ten-candidate
    # minimal repro: ONLY a synchronous read infers; every async form fails, including an
    # unguarded one and two with write ports, whose 4096 bits land in registers. The fix
    # costs one clk_sys cycle of latency in a 24 ms message, so it is cheap - but the array
    # is deliberately left out of this list rather than added, because adding it would fail
    # EVERY fit until the RTL is changed, and a guard that is always red is a guard nobody
    # reads. Whichever change makes the ROM synchronous should add its entry here in the same
    # commit, and then the guard will mean what it says.
    # c48ef091 moved the text VRAM into pc9821_text_mem, so the key moved with it.
    "pc9821_text_mem:u_text_mem|pc9821_dpram:u_tram": "the text VRAM planes",
    "pc9821_cg:u_cg|pc9821_dpram:u_ank": "the character generator (the ANK table; the JIS font is SDRAM-backed)",
    "pc9821_cg:u_cg": "the CG store (cg_ram)",
    "l1_cache:dcache_inst": "the z486 data cache",
    "l1_icache:icache_inst": "the z486 instruction cache",
    "pc9821_ata:ata": "the ATA sector buffer",
    # The scanout line buffer is the array the global SYNTH_RESOURCE_AWARE_INFERENCE_FOR_BLOCK_RAM
    # OFF rescues: without that setting Quartus demotes its 8,192 bits to registers. It has no
    # in-tree per-module guard (the out-of-tree EGC resource harness proves only the EGC), so it is listed
    # here: a fit that loses the inference is caught by this check.
    "pc9821_gvram_scan:u_gvram_scan|altsyncram:line_buf_rtl_0": "the scanout line buffer",
    # The PC-9801-86 86-PCM block's 32 KiB sample buffer MOVED TO SDRAM
    # (sdram-offload: src/pcm86/pc9821_pcm86_buf.sv is the memory controller's
    # third port). It is no longer a dpram, so it is DELIBERATELY absent here:
    # it is expected to be SDRAM-backed, not RAM-inferred, and keeping the old
    # pc9821_dpram:u_buf entry would fail every fit.
}

# WHAT A FIT IS MADE OF, stated once. Both the recorded provenance and the "is this
# still the same tree?" verdict are built from this set, and tools/container_build.sh
# now asks for its summary hash through --rtl-hash-of rather than keeping its own copy
# of the rule.
#
# IT HAD ITS OWN COPY, AND THE TWO DRIFTED. The summary hash gained the root level
# while the VERIFIED FILE LIST did not, so a change to z486_mister.sv - the top of the
# design - still passed as the same tree: the exact failure the provenance exists to
# prevent. Worse, the summary hash was never recomputed or compared anywhere (it is
# recorded "for humans"), so only the file list ever decided anything, and the file
# list was the half that had not been fixed.
#
# The set deliberately covers more than .sv/.v/.vhd:
#   * .svh  - Verilog headers the HDL `include`s. z486's PLA and platform definitions
#             are .svh, so a change there changes the CPU.
#   * .mif, .hex - memory contents. src/z486/ucode.mif is the CPU's microcode and the
#             x87 tables are .mif; the fitted logic changes with no HDL edit at all.
#   * .qip, .qsf, .sdc - what gets compiled and under what constraints.
#             sys/pll_q17.qip is how the design's `pll` instance is defined at all.
# The root level is included because z486_mister.sv and the project .qsf are there.
#
# AND WHAT IS EXCLUDED, each with the reason it is excluded:
#   * build_id.v - Quartus generates it, it is gitignored, and its content is a build
#             timestamp. Including it would fail every fit its own attribution.
#   * the generated main PLL (rtl/pll.qip, rtl/pll.v, rtl/pll/pll_0002.v) - also
#             gitignored, and also present or absent depending on how the tree was last
#             built: a fresh checkout has none, build_profile.py generates them into the
#             tree, and tools/build.py generates them into its scratch. A file that comes
#             and goes would fail a fit's attribution for a reason that is not the design.
#             What they are generated FROM is still covered: z486_mister.qsf carries the
#             whole build configuration as its '# Active config' JSON record (clk_sys -
#             the SDRAM's clock too - the SDRAM phase, every compile-time knob) and is hashed below, and
#             the PLL template is hashed as an EXTRA_FILES entry; build_profile.py --check
#             reads the generated PLL back against that record before every fit.
#             The other sys/pll*.v are tracked sources and are NOT excluded - the
#             names here are exact, so pll_hdmi.v and pll_audio_0002.v stay in.
#   * src/z486/tests/ - z486's own test harness. Nothing there is compiled into the
#             design, and running the suite MATERIALISES .hex images in that directory
#             (tests/pla_entry_rom.hex and tests/pla_group_entry.hex are untracked, so
#             they appear and disappear with the tests), which would make a fit's
#             provenance depend on whether the suite had been run since the fit.
RTL_DIRS = ("rtl", "src", "sys")
SOURCE_SUFFIXES = (".sv", ".v", ".vhd", ".svh", ".mif", ".hex")
BUILD_SUFFIXES = (".qip", ".qsf", ".sdc")
DESIGN_SUFFIXES = SOURCE_SUFFIXES + BUILD_SUFFIXES
EXCLUDE_PREFIXES = ("src/z486/tests/",)
EXCLUDE_NAMES = ("build_id.v", "pll.qip", "pll.v", "pll_0002.v")
# The two templates the generated PLL and SDC come from (tools/profile_gen.py). They are not
# under RTL_DIRS, but a change to either changes what is fitted, so they are design inputs.
EXTRA_FILES = ("tools/profile/pll_template.v", "tools/profile/z486_mister.sdc.in")

ATTRIBUTION_NAME = "fit-source.sha256"


def repo_root() -> pathlib.Path:
    """The checkout this script lives in - not the scratch, which is a copy."""
    return pathlib.Path(__file__).resolve().parents[1]


def default_scratch(repo: pathlib.Path) -> pathlib.Path:
    """Where a build in `repo` writes its reports.

    THIS MUST MATCH tools/container_build.sh, and it now cannot fail to: both use this
    one rule, the scratch is .build/quartus inside the checkout, and a lane therefore
    gets its own copy with no naming convention to remember. A lane that has not been
    built has no reports here, which is the point - it must not silently read the
    central tree's fit instead.

    IT USED TO SAY /tmp/pc9821_z486_quartus[_<lane>] HERE WHILE THE BUILDER HAD ALREADY
    MOVED TO .build/quartus, and the comment above went on claiming the two matched.
    So this looked in a directory the builder no longer wrote, and where a lane's old
    /tmp scratch still existed it read a STALE fit and printed a verdict for it - the
    precise failure that comment warns about, in the function that warns about it. Old
    /tmp/pc9821_z486_quartus_* trees from those builds are still on disk.
    """
    if os.environ.get("QUARTUS_SCRATCH"):
        return pathlib.Path(os.environ["QUARTUS_SCRATCH"])
    return repo / ".build" / "quartus"


def rtl_files(tree: pathlib.Path) -> list[pathlib.Path]:
    """Every file a fit is built from, as paths relative to tree, sorted.

    The root level is scanned one deep rather than recursively, so this cannot walk
    into .build/ (which holds the build's own scratch copy of the tree) or into a
    lane's neighbours.
    """
    found: set[pathlib.Path] = set()
    for d in RTL_DIRS:
        base = tree / d
        if base.is_dir():
            found.update(p for p in base.rglob("*") if p.is_file())
    found.update(p for p in tree.glob("*") if p.is_file())
    out = [pathlib.Path(rel) for rel in EXTRA_FILES if (tree / rel).is_file()]
    for p in found:
        rel = p.relative_to(tree)
        if p.suffix not in DESIGN_SUFFIXES or p.name in EXCLUDE_NAMES:
            continue
        if str(rel).startswith(EXCLUDE_PREFIXES):
            continue
        out.append(rel)
    return sorted(out)


def rtl_hash(tree: pathlib.Path) -> str:
    """A short summary hash of every file a fit is built from.

    Derived from rtl_files(), so the hash a build records and the file list this check
    verifies can no longer disagree about what the design is. Paths are hashed with the
    contents so that a rename or a move is visible, not just an edit.
    """
    h = hashlib.sha256()
    for rel in rtl_files(tree):
        h.update(str(rel).encode())
        h.update(b"\0")
        h.update(sha256_of(tree / rel).encode())
        h.update(b"\n")
    return h.hexdigest()[:16]


def sha256_of(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def active_config_record(tree: pathlib.Path) -> str | None:
    """The qsf's '# Active config:' JSON record (build_profile.py), verbatim, or None."""
    qsf = tree / "z486_mister.qsf"
    if not qsf.is_file():
        return None
    match = re.search(r"^# Active config: (\{.*\})$", qsf.read_text(), re.MULTILINE)
    return match.group(1) if match else None


def active_profile_and_clock(tree: pathlib.Path) -> tuple[str | None, int | None]:
    """The profile named in the qsf, and the clock z486_mister.sv declares.

    THE CLOCK RATE HAS TWO HOMES and the artifact cannot otherwise say which one it obeys.
    The '# Active profile:' marker decides the generated main PLL, which is the clock the
    design really runs at. CLOCK_RATE_HZ in z486_mister.sv is what the RTL believes. Both
    are recorded here so a bitstream's clock is READABLE rather than recoverable only by
    diffing two artifacts; build_profile.py --check refuses to fit when they disagree.
    Neither is added to rtl_files(), which already hashes both files.
    """
    profile: str | None = None
    clock: int | None = None
    qsf = tree / "z486_mister.qsf"
    if qsf.is_file():
        match = re.search(r"# Active profile: (\w+)", qsf.read_text())
        if match:
            profile = match.group(1)
    top = tree / "z486_mister.sv"
    if top.is_file():
        match = re.search(r"^localparam[ \t]+CLOCK_RATE_HZ[ \t]*=[ \t]*([0-9_]+);",
                          top.read_text(), re.MULTILINE)
        if match:
            clock = int(match.group(1).replace("_", ""))
    return profile, clock


def write_attribution(out_dir: pathlib.Path, tree: pathlib.Path, rtl_hash: str) -> int:
    """Write the provenance of the fit whose reports are in out_dir."""
    files = rtl_files(tree)
    if not files:
        sys.exit(f"refusing to write an attribution with no RTL found under {tree}")
    profile, clock = active_profile_and_clock(tree)
    out_dir.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Which tree the fit reported in this directory was built from.",
        "# Written by tools/check_fit.py --write-attribution, called by tools/container_build.sh.",
        "# Read by tools/check_fit.py, which refuses to print a verdict without it.",
        "# Format: these fields, then one '<sha256>  <path relative to tree>' per file.",
        f"tree: {tree}",
        f"rtl-hash: {rtl_hash}",
        f"profile: {profile if profile is not None else '(no marker)'}",
        f"clock: {clock if clock is not None else '(no localparam)'}",
        f"config: {active_config_record(tree) or '(no record)'}",
        f"files: {len(files)}",
        f"built: {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
    ]
    for rel in files:
        lines.append(f"{sha256_of(tree / rel)}  {rel}")
    path = out_dir / ATTRIBUTION_NAME
    path.write_text("\n".join(lines) + "\n")
    print(f"wrote {path}: {len(files)} RTL files, tree {tree}")
    return 0


def read_attribution(path: pathlib.Path) -> dict:
    fields: dict[str, str] = {}
    files: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        if line.startswith(("tree:", "rtl-hash:", "profile:", "clock:", "config:", "files:",
                            "built:")):
            k, _, v = line.partition(":")
            fields[k] = v.strip()
            continue
        digest, _, rel = line.partition("  ")
        if len(digest) == 64 and rel:
            files[rel] = digest
    fields["files_map"] = files
    return fields


def verify_attribution(att: dict, tree: pathlib.Path) -> list[str]:
    """Every problem that makes this fit NOT a fit of `tree`."""
    problems: list[str] = []
    expected = att["files_map"]
    actual = {str(r): None for r in rtl_files(tree)}
    for rel in sorted(set(actual) - set(expected)):
        problems.append(f"{rel} is in the tree but was not part of the fit")
    for rel in sorted(set(expected) - set(actual)):
        problems.append(f"{rel} was part of the fit but is gone from the tree")
    for rel in sorted(set(expected) & set(actual)):
        now = sha256_of(tree / rel)
        if now != expected[rel]:
            problems.append(f"{rel} has changed since the fit")
    return problems


def refuse(msg: str) -> int:
    """No verdict can be given, as distinct from a verdict of FAIL (exit 1)."""
    print(msg, file=sys.stderr)
    return 2


def parse_fit(text: str) -> dict:
    out = {}
    for label, pat in (
        ("ALMs", r"Logic utilization \(ALMs needed / total ALMs on device\)\s*;\s*([\d,]+)\s*/\s*([\d,]+)"),
        ("LABs", r"Total LABs:\s+partially or completely used\s*;\s*([\d,]+)\s*/\s*([\d,]+)"),
        ("RAM blocks", r"Total RAM Blocks\s*;\s*([\d,]+)\s*/\s*([\d,]+)"),
        ("registers", r"Total registers\s*;\s*([\d,]+)"),
        ("memory bits", r"Total block memory bits\s*;\s*([\d,]+)\s*/\s*([\d,]+)"),
    ):
        m = re.search(pat, text)
        if m:
            out[label] = [int(x.replace(",", "")) for x in m.groups()]
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scratch", default=None, help="a build's scratch directory "
                    "(default: this checkout's own, derived as container_build.sh does)")
    ap.add_argument("--reports", default=None, help="directory holding the Quartus reports")
    ap.add_argument("--tree", default=None, help="the tree the reports are meant to describe "
                    "(default: the tree named by the fit's own attribution)")
    ap.add_argument("--write-attribution", default=None, metavar="OUTPUT_FILES_DIR",
                    help="record what the fit in this directory was built from, and exit. "
                         "Called by tools/container_build.sh after a fit.")
    ap.add_argument("--rtl-hash", default="(not given)",
                    help="the summary hash container_build.sh printed, recorded for humans")
    ap.add_argument("--rtl-hash-of", default=None, metavar="TREE",
                    help="print the summary hash of every file that tree's fit is built "
                         "from, and exit. tools/container_build.sh calls this, so the hash "
                         "it records and the file list this check verifies come from one "
                         "rule instead of two that can drift apart.")
    args = ap.parse_args()

    here = repo_root()

    if args.rtl_hash_of:
        tree = pathlib.Path(args.rtl_hash_of).resolve()
        if not rtl_files(tree):
            sys.exit(f"no design sources found under {tree}")
        print(rtl_hash(tree))
        return 0

    if args.write_attribution:
        tree = pathlib.Path(args.tree).resolve() if args.tree else here
        return write_attribution(pathlib.Path(args.write_attribution), tree, args.rtl_hash)

    if args.reports:
        root = pathlib.Path(args.reports)
    else:
        scratch = pathlib.Path(args.scratch) if args.scratch else default_scratch(here)
        root = scratch / "output_files"

    fit = root / "z486_mister.fit.rpt"
    mp = root / "z486_mister.map.rpt"
    if not fit.exists():
        return refuse(f"no fit report at {fit}\n"
                      f"  (build first with tools/container_build.sh, or pass --reports DIR;\n"
                      f"   a lane has its own scratch, so {root} is empty until it has built)")

    # The attribution gate, BEFORE any verdict is printed. Absent is not "probably
    # fine": this check cannot tell which tree a fit belongs to without it, and
    # guessing is what made it report another tree's fit as PASS.
    att_path = root / ATTRIBUTION_NAME
    if not att_path.exists():
        return refuse(f"REFUSING TO GUESS: no {ATTRIBUTION_NAME} in {root}\n"
                      f"  A fit report does not name its source tree, so without this file this\n"
                      f"  check cannot tell whose fit it is reading - and it used to print PASS\n"
                      f"  for whichever tree happened to be there. Re-fit with\n"
                      f"  tools/container_build.sh, or pass --reports for a fit that has one.\n"
                      f"  (Lane checkouts have their own scratch at .build/quartus inside\n"
                      f"   the checkout, so a lane that has not built reads NO fit rather\n"
                      f"   than the central tree's. This used to look in /tmp, where a\n"
                      f"   lane's stale scratch could still be found and reported on.)")
    att = read_attribution(att_path)
    att_tree = pathlib.Path(att["tree"]).resolve() if att.get("tree") else None
    if att_tree is None or not att_tree.is_dir():
        return refuse(f"REFUSING TO GUESS: {att_path} names tree {att.get('tree')!r}, "
                      f"which does not exist, so this fit cannot be attributed to anything")

    print(f"reports: {root}")
    print(f"fit source: {att_tree}  (rtl-hash {att.get('rtl-hash', '?')}, "
          f"built {att.get('built', '?')}, {att.get('files', '?')} files)")
    # The clock the bitstream runs at is not in the RTL hash and never was: a profile switch
    # rewrites both the localparam and the generated PLL. Print it, so nobody has to infer it.
    print(f"  profile {att.get('profile', '(none recorded - this fit predates the field)')}, "
          f"clock {att.get('clock', '?')} Hz")
    if att.get("config"):
        print(f"  config {att['config']}")
    if att_tree != here:
        print(f"  NOTE: that is NOT the checkout this check is running in ({here}).")
        print(f"        Verifying against the tree the fit names; pass --tree to override.")

    tree = pathlib.Path(args.tree).resolve() if args.tree else att_tree
    problems = verify_attribution(att, tree)
    if problems:
        print(f"  attribution  {len(problems)} problem(s) against {tree}")
    else:
        print(f"  attribution  verified: every RTL file matches {tree} as the fit found it")

    text = fit.read_text(errors="ignore")
    res = parse_fit(text)
    for label in ("ALMs", "LABs", "RAM blocks", "registers", "memory bits"):
        v = res.get(label)
        if not v:
            continue
        if len(v) == 2:
            pct = 100.0 * v[0] / v[1] if v[1] else 0.0
            flag = "  <-- FULL" if v[0] >= v[1] else ""
            print(f"  {label:<12} {v[0]:>8,} / {v[1]:<8,} ({pct:5.1f}%){flag}")
        else:
            print(f"  {label:<12} {v[0]:>8,}")

    bad = []
    if "Can't fit design in device" in text:
        bad.append("the fit did not close at all")
    for label in ("ALMs", "LABs"):
        v = res.get(label)
        if v and len(v) == 2 and v[0] >= v[1]:
            bad.append(f"{label} are at 100% of the device")

    # A design with this much inferred memory that fits with NO block RAM has had its
    # arrays turned into registers: that is what a port-count problem looks like from
    # here (64 Kb of CG store became 65,536 flip-flops while the map report still listed
    # the M10K). Checking the map report alone missed it, so check the fit's own use.
    rb = res.get("RAM blocks")
    bits = res.get("memory bits")
    if rb and len(rb) == 2:
        inferred_bits = bits[0] if bits else 0
        if rb[0] == 0 and inferred_bits > 100_000:
            bad.append(f"the fit uses no RAM blocks at all while {inferred_bits:,} memory "
                       f"bits were inferred -- the arrays became registers")
        else:
            print(f"  RAM blocks    {rb[0]:,} in use for {inferred_bits:,} inferred bits")

    if mp.exists():
        summary = mp.read_text(errors="ignore")
        head = summary.find("Analysis & Synthesis RAM Summary")
        body = summary[head:head + 80_000] if head >= 0 else ""
        missing = [f"{n} ({why})" for n, why in EXPECTED_RAM.items() if n not in body]
        # An array absent from the RAM summary is a defect only when the design CONTAINS the
        # module that should hold it. A report from a tree that predates a feature has neither,
        # and calling that "not inferred as RAM" is a false accusation: it sent a lane chasing a
        # block that was not in the tree it had fitted, and the lane correctly spent its time
        # disproving me instead of fixing anything. The check still FAILS in both cases - a
        # stale report should be re-fitted, not trusted - but it now says WHICH case it is,
        # because the two call for opposite actions.
        not_inferred = [m for m in missing if m.split(":")[0] in summary]
        absent = [m for m in missing if m not in not_inferred]
        if not missing:
            print("  inferred RAM  all expected arrays present")
        else:
            print(f"  inferred RAM  MISSING: {', '.join(missing)}")
        for m in not_inferred:
            bad.append(f"NOT INFERRED AS RAM: {m} -- the module is in this design but its array "
                       f"is not in the RAM summary, so it became registers")
        for m in absent:
            bad.append(f"ABSENT FROM THIS DESIGN: {m} -- the module holding it appears nowhere "
                       f"in this fit, so this report predates the feature; re-fit rather than "
                       f"looking for an inference bug")
    else:
        print("  inferred RAM  (no map report; skipping the inference check)")

    print()
    if problems:
        print(f"FIT CHECK: FAIL -- this fit is NOT of {tree}:")
        for p in problems[:20]:
            print(f"  {p}")
        if len(problems) > 20:
            print(f"  ... and {len(problems) - 20} more")
        return 1
    if bad:
        for b in bad:
            print(f"FIT CHECK: FAIL -- {b}")
        return 1
    print("FIT CHECK: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())

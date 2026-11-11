#!/usr/bin/env python3
"""Static wiring check: is everything connected together correctly?

Parsing and cross-references only -- no simulation, no build, no DUT -- so it is safe
and cheap to run before anything expensive. The generated bench table is SOURCED and
its functions CALLED, because substring checks once passed a table whose
`bench_sources()` did not exist.

Exit status 0 if everything is consistent, 1 otherwise.

WHAT THIS COPY DOES NOT COVER. This tool was restored to `tools/` after the
an earlier cleanup moved it out of the tree, and the checks it
carried that were tied to the measurement front end went with that front end: the
sub-command checks on the measure script, the port-sweep baseline's canonical-line
format and the device-grammar README agreement all named files (measure.sh, measure/)
that this repository no longer ships -- the unit-bench half of that front end is
`tools/bench.py` and the device/sweep half stays with the out-of-repo dev tools. Every
path this file reads exists in this repository.
"""
import importlib.util
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FAIL = []
NOTE = []


def check(ok, message):
    print(("  ok   " if ok else "  FAIL ") + message)
    if not ok:
        FAIL.append(message)


def load_generator():
    spec = importlib.util.spec_from_file_location("gb", ROOT / "tools/gen_bench_sources.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)          # defines the table; runs nothing else
    return mod


print("== the bench table ==")
gen = load_generator()
TABLE = gen.BENCHES
# One home for the expected count: it used to be written twice, and the two copies
# disagreed, so the check PASSED while printing "37 benches declared" beside a table of
# 61. A number stated in a message must come from the same place as the number tested.
# The expected count used to be a literal here, and every bench-adding change had to remember to
# bump it: it conflicted on four separate merges, and a change that forgot would have failed the
# gate for a reason unrelated to its bench. It is now DERIVED, and the check is stronger than the
# constant was. Every testbench on disk must be either claimed by a table entry or named below as
# one an integration script runs on its own, so deleting an entry fails - its bench becomes
# unclaimed - which is exactly what the constant was for, with no number to keep in step.
STANDALONE_BENCHES = {
    "TB_PC9821_BOOT",         # run_boot.sh boots a disk image end to end
    "TB_PC9821_PORTHARNESS",  # shared port harness, not a bench of its own
    "TB_PC9821_USERDISK",     # run_userdisk.sh
    "TB_PC9821_THROTTLE",     # run_throttle.sh: the real CPU at Full, 8 MHz and 1 MHz
    "TB_PC9821_DMA_SNOOP_THROTTLE",  # run_dma_snoop_throttle.sh: the real system, gated cpu_ce
}
EXPECTED_BENCHES = len(TABLE)
declared = {marker.upper() for marker, _claim, _files in TABLE.values()}
on_disk = {q.stem.upper() for q in (ROOT / "tests/pc9821").glob("tb_*.sv")}
unclaimed = sorted(on_disk - declared - STANDALONE_BENCHES)
check(not unclaimed, f"every testbench is claimed by a bench entry or listed standalone (unclaimed: {unclaimed})")
stale = sorted(STANDALONE_BENCHES - on_disk)
check(not stale, f"every standalone row names a real testbench (stale: {stale})")
for name, (marker, claim, files) in sorted(TABLE.items()):
    check(not any("$(" in x for x in [marker, claim] + list(files)),
          f"{name}: no shell substitution in the table (the self-reference bug)")
    check(len(claim.split()) >= 5, f"{name}: states what it proves, as a sentence")
    check(bool(files), f"{name}: declares sources")
    missing = [f for f in files if not (ROOT / f).exists()]
    check(not missing, f"{name}: all {len(files)} source file(s) exist" + (f" (missing {missing})" if missing else ""))
    check((ROOT / f"tests/pc9821/tb_pc9821_{name}.sv").exists(), f"{name}: testbench exists")

print("== the generated file agrees with the table ==")
# cwd=ROOT, because tools/gen_bench_sources.py resolves the table's paths and its output
# file RELATIVE TO THE CALLER'S DIRECTORY: run from anywhere else it reports every source
# as missing and would have this checker fail for a reason that has nothing to do with the
# table. (AGENTS.md runs it from the root.)
r = subprocess.run([sys.executable, str(ROOT / "tools/gen_bench_sources.py"), "--check"],
                   capture_output=True, text=True, cwd=ROOT)
check(r.returncode == 0, f"gen_bench_sources.py --check: {r.stdout.strip() or r.stderr.strip()}")

# Functional probe: SOURCE the generated file and call the functions the consumers
# call. Substring checks are what let a missing bench_sources() pass unnoticed,
# so this asks the shell what it actually returns.
def sh(expr):
    q = subprocess.run(["bash", "-c",
                        f"source tests/pc9821/bench_sources.sh && {expr}"],
                       capture_output=True, text=True, cwd=ROOT)
    return q.returncode, q.stdout.strip(), q.stderr.strip()

rc, names, err = sh("bench_list")
listed = names.split()
check(rc == 0 and len(listed) == EXPECTED_BENCHES, f"bench_list returns {EXPECTED_BENCHES} names (got {len(listed)})")
bench_files = {}
for n in listed:
    rc, srcs, err = sh(f'bench_sources {n}')
    files = srcs.split()
    bench_files[n] = files
    check(rc == 0 and bool(files), f"bench_sources {n} returns a file list")
    check(not any(("[" in f or "'" in f) for f in files),
          f"bench_sources {n} returns shell words, not a Python list repr")
    check(all((ROOT / f).exists() for f in files),
          f"bench_sources {n}: every listed file exists")
    rc, claim, err = sh(f'bench_claim {n}')
    check(rc == 0 and len(claim.split()) >= 5 and "['" not in claim and "']" not in claim,
          f"bench_claim {n} returns a sentence, not a list repr "
          f"(a bracket in prose, like [4:1], is fine)")
    # The shell must hand back the table's claim byte for byte. A claim emitted in double
    # quotes had its `...` spans RUN as commands and its $ words expanded: the claims were
    # mangled, and a span holding a redirect left empty files named `=` and `status` in the
    # caller's directory on every run of this check.
    check(claim == TABLE[n][1].strip() and not err,
          f"bench_claim {n} returns the table's claim verbatim (no shell expansion)")
print("== the two source lists are used by the tiers they belong to ==")
# Two lists exist on purpose. bench_sources.sh declares what ONE unit bench is built
# from; tests/pc9821/z486_rtl.sh declares the whole SoC for the integrated benches.
# They overlap by design (a unit bench names the platform file it tests, and the
# system list contains every platform file). The defect this guards is a CONSUMER
# that concatenates them: the old measure script's bench path built every unit
# bench from "${PC9821_Z486_RTL[@]}" "$SRC", so each of the ~40 shared files was
# compiled twice. Verilator survives that by picking one copy and warning MODDUP,
# which cost a whole-system elaboration per unit bench and, worse, turned MODDUP
# into noise: two DIFFERENT files defining one module -- the collision a file list
# exists to expose -- would have hidden among warnings that are always present.
for n in listed:
    files = bench_files.get(n, [])
    dupes = sorted({f for f in files if files.count(f) > 1})
    check(not dupes, f"bench_sources {n} lists no file twice" + (f" (duplicated {dupes})" if dupes else ""))

zsh = ROOT / "tests/pc9821/z486_rtl.sh"
ztext = zsh.read_text()
m = re.search(r"PC9821_Z486_RTL=\((.*?)\n\)", ztext, re.S)
check(m is not None, "z486_rtl.sh declares PC9821_Z486_RTL as a parenthesised list")
sys_files = re.findall(r"[\w./-]+\.sv", m.group(1)) if m else []
check(len(sys_files) > 30, f"the system list is the whole SoC (found {len(sys_files)} files)")
check(len(sys_files) == len(set(sys_files)),
      "the system list itself lists no file twice")

# The runner itself must build each bench from its OWN declared list (the manifest in
# tools/gen_bench_sources.py) and never from the whole-system list: concatenating the
# two compiled every shared file twice and turned MODDUP from a signal into noise.
bench_src = (ROOT / "tools/bench.py").read_text()
bench_live = re.sub(r"#[^\n]*", "", bench_src)
check("gen_bench_sources" in bench_src,
      "tools/bench.py builds from the manifest declared by tools/gen_bench_sources.py")
check("PC9821_Z486_RTL" not in bench_live,
      "the unit-bench build does NOT also pass the whole-system list (that is what "
      "compiled every shared file twice)")
for runner in ["run_boot.sh", "run_userdisk.sh", "run_portharness.sh"]:
    rt = (ROOT / "tests/pc9821" / runner).read_text()
    check("PC9821_Z486_RTL" in rt, f"{runner} still builds from the whole-system list")

gen_sh = (ROOT / "tests/pc9821/bench_sources.sh")
check(gen_sh.exists(), "tests/pc9821/bench_sources.sh exists")
if gen_sh.exists():
    text = gen_sh.read_text()
    check("$(" not in text, "bench_sources.sh has no shell substitution (would recurse)")
    for name in TABLE:
        check(f"    {name})" in text, f"bench_sources.sh has an entry for {name}")

print("== every wildcard-instantiated DUT port resolves in its testbench ==")
# `dut (.*)` connects every port of the DUT by name, so a port with no matching
# signal in the testbench is a compile error -- found by an expensive run, not here.
# Adding the telemetry output dbg_itf_stage to pc9821_iobus broke two consumers
# this way (tb_pc9821_iobus.sv and the port sweep harness), so check it statically.
def strip_comments_sv(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)

def module_ports(name):
    """Port names of an ANSI-style module, or None if it is not found here.

    Comments are stripped FIRST: these port lists carry long contract comments
    between entries, and a parser that reads documentation as declarations reports
    every word in them as a port name."""
    for path in (ROOT / "src").rglob("*.sv"):
        text = strip_comments_sv(path.read_text(errors="ignore"))
        m = re.search(r"^module\s+" + re.escape(name) + r"\b", text, re.M)
        if not m:
            continue
        rest = text[m.end():]
        if rest.lstrip().startswith("#"):            # skip the parameter list
            rest = rest[rest.index("(") + 1:]
            rest = rest[rest.index(")") + 1:]
        head = rest[rest.index("(") + 1:]
        head = head[:head.index(");")]
        ports, ansi = [], False
        for seg in head.split(","):
            seg = re.sub(r"\[[^\]]*\]", " ", seg)
            words = re.findall(r"[A-Za-z_]\w*", seg)
            if not words:
                continue
            if words[0] in ("input", "output", "inout"):
                ansi = True
                words = words[1:]
            words = [w for w in words if w not in ("wire", "reg", "logic", "signed", "unsigned", "var")]
            ports += words
        return ports if ansi else None
    return None

wc_files = [p for p in sorted((ROOT / "tests/pc9821").glob("*.sv"))]
checked_ports = 0
for p in wc_files:
    raw = p.read_text(errors="ignore")
    live = strip_comments_sv(raw)
    # The `.*` may follow named connections (`dut (.ide_unit0_present(1'b0), .*)`), so the
    # list before it is allowed: 35 benches instantiate pc9821_iobus that way and a new
    # port without a bench signal passed this check until it was widened.
    for m in re.finditer(r"\b([a-z_]\w*)\s*(?:#\([^;]*?\))?\s+\w+\s*\((?:[^;]*?,)?\s*\.\*\s*\)", live):
        dut_mod = m.group(1)
        ports = module_ports(dut_mod)
        if ports is None:
            continue
        checked_ports += 1
        missing = [q for q in ports if not re.search(r"(?<![A-Za-z0-9_])" + re.escape(q) + r"(?![A-Za-z0-9_])", live)]
        check(not missing,
              f"{p.name}: every {dut_mod} port has a signal"
              + (f" (no signal for {missing})" if missing else ""))
check(checked_ports >= 7, f"found the wildcard DUT instantiations (checked {checked_ports})")

print("== a bench that declares the real SDRAM controller elaborates it ==")
# The table checks above prove spelling and file existence, never that a
# declared source is part of the DUT: a bench could list `src/memory/sdram.v`, compile fine
# because Verilator ignores a module nothing instantiates, and prove nothing about the
# controller its claim named. `plain_write` and the stale graphics benches did exactly that --
# their top instantiated only `pc9821_gvram`. This maps the claim-critical REAL sources to the
# module they define and requires that module to be REACHABLE from the bench's own top module.
#
# It is deliberately narrow. A bench may legitimately list a helper file, and the generic models
# (`sdram_2port_model`, `sdram_backend_model`) are helpers many benches share, so only the real
# controller and the chip model that exists to sit under it are checked. Widen CLAIM_CRITICAL
# when a new claim rests on another source; do not turn this into an all-files rule (the opna
# benches and the pcm86 benches list generated or generate-instantiated sources this parser
# cannot follow, and an over-strict check is a check nobody can leave on).
CLAIM_CRITICAL = {
    "src/memory/sdram.v": "sdram",
    "tests/pc9821/sdram_chip_model.sv": "sdram_chip_model",
}


def sv_modules(text: str) -> dict:
    """module name -> its body. Comments must already be stripped, or a module named in prose
    reads as a declaration."""
    out = {}
    for m in re.finditer(r"^\s*module\s+([A-Za-z_]\w*)", text, re.M):
        end = text.find("endmodule", m.end())
        out[m.group(1)] = text[m.end():end if end > 0 else len(text)]
    return out


def sv_instantiates(body: str) -> set:
    """The module names a body instantiates: `name [#(...)] instance (`. A function/task call
    (`foo(`) has no instance identifier and the over-match on keywords (if/for/case) never names
    a CLAIM_CRITICAL module, so both are harmless here."""
    return set(re.findall(
        r"(?<![A-Za-z0-9_.$])([A-Za-z_]\w*)\s*(?:#\s*\([^;]*?\)\s*)?[A-Za-z_]\w*\s*\(", body))


def sv_macro_instantiates(body: str, macros: dict) -> set:
    """A module instantiated through a macro (`` `NAME #(...) inst ( ``), resolved to EVERY value
    the bench's sources and includes `define NAME as - both arms of an `ifdef, because either
    build is one the bench runs (tests/pc9821/sdram_sync_bench.svh carried such a macro,
    TB_SDRAM_BRIDGE, until the split-clock build was removed)."""
    out = set()
    for name in re.findall(
            r"`([A-Za-z_]\w*)\s*(?:#\s*\([^;]*?\)\s*)?[A-Za-z_]\w*\s*\(", body):
        out |= macros.get(name, set())
    return out


def sv_defines(text: str) -> dict:
    """`define NAME <module-like token> -> {tokens}, over every arm."""
    out: dict = {}
    for m in re.finditer(r"^\s*`define\s+([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*$", text, re.M):
        out.setdefault(m.group(1), set()).add(m.group(2))
    return out


def reachable_from(top: str, modules: dict, macros: dict | None = None) -> set:
    seen, work = set(), [top]
    while work:
        cur = work.pop()
        if cur in seen:
            continue
        seen.add(cur)
        body = modules.get(cur, "")
        work.extend((sv_instantiates(body) | sv_macro_instantiates(body, macros or {})) - seen)
    return seen


_claim_critical_benches = 0
for name, (_marker, _claim, files) in sorted(TABLE.items()):
    wanted = {CLAIM_CRITICAL[f]: f for f in files if f in CLAIM_CRITICAL}
    if not wanted:
        continue
    _claim_critical_benches += 1
    modules, macros = {}, {}
    for rel in list(files) + [f"tests/pc9821/tb_pc9821_{name}.sv"]:
        p = ROOT / rel
        if p.suffix in (".sv", ".v") and p.exists():
            text = strip_comments_sv(p.read_text(errors="ignore"))
            modules.update(sv_modules(text))
            # `include "x.svh" is resolved beside the including file (the benches' +incdir).
            for inc in re.findall(r'`include\s+"([^"]+)"', text):
                ip = p.parent / inc
                if ip.exists():
                    for k, v in sv_defines(strip_comments_sv(ip.read_text(errors="ignore"))).items():
                        macros.setdefault(k, set()).update(v)
            for k, v in sv_defines(text).items():
                macros.setdefault(k, set()).update(v)
    reached = reachable_from(f"tb_pc9821_{name}", modules, macros)
    for mod, rel in sorted(wanted.items()):
        check(mod in reached,
              f"{name}: declares {rel} (module {mod}) and instantiates it from its top"
              + ("" if mod in reached else f" -- module {mod} is never instantiated"))
check(_claim_critical_benches >= 5,
      f"found the benches that declare a claim-critical source (checked {_claim_critical_benches})")

print("== shell scripts parse ==")
scripts = sorted(list((ROOT / "tests/pc9821").glob("*.sh")) + list((ROOT / "tools").glob("*.sh")))
for s in scripts:
    p = subprocess.run(["bash", "-n", str(s)], capture_output=True, text=True)
    check(p.returncode == 0, f"bash -n {s.relative_to(ROOT)}" + (f" -- {p.stderr.strip()[:120]}" if p.returncode else ""))

print("== the gate's own wiring ==")
# The gate is the command list in AGENTS.md, and tests/pc9821/run.sh is its one command:
# the unit tier, the diagnostic boot and z486's own suite. Follow run.sh so a tier dropped
# from it fails here, which is the job the old substring check on run.sh did.
run_sh = (ROOT / "tests/pc9821/run.sh").read_text()
for needed in ["tools/bench.py --all", "tests/pc9821/run_boot.sh",
               "tests/pc9821/run_z486_suite.sh"]:
    check(needed in run_sh, f"run.sh runs {needed}")

print("== files the tooling depends on ==")
for rel in ["tools/bench.py", "tools/gen_bench_sources.py", "tools/build_pack.py",
            "tools/check_pack.py", "tests/pc9821/z486_rtl.sh", "tests/pc9821/run_boot.sh",
            "tests/pc9821/run_userdisk.sh", "tests/pc9821/run_portharness.sh",
            "tests/pc9821/tb_pc9821_portharness.sv", "tests/pc9821/bench_sources.sh"]:
    check((ROOT / rel).exists(), f"{rel} exists")

print("== the portharness still emits the machine-readable sweep line ==")
# The DEVICE sweep -- the script format, the port baseline and its projection -- lives out
# of tree with the measure script, so what remains checkable here is the shape it
# parses: the one-line CSV the harness prints per access.
harness = (ROOT / "tests/pc9821/tb_pc9821_portharness.sv").read_text()
check(re.search(r'\$display\("PORT %s,%04x,%04x,%04x,%0d,%0d"', harness) is not None,
      "the harness emits the PORT CSV line the port sweep reads")

print("== no iverilog left in the build path ==")
# Only an INVOCATION counts, and neither a comment nor a claim is one. Several bench
# claims tell a human to re-run that bench under a 4-state simulator to see the
# fail-first X-lock; that is an instruction to a person, not a dependency of this tree.
# So: comments go, and what is then searched for is a COMMAND -- a word in a shell
# command position, or, in a Python/Verilog file, either a bare word in code or the
# exact command literal `"iverilog"`/`'vvp'` (the form a spawner's argv takes).
def strip_comments(text: str, suffix: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    if suffix in (".sh", ".py", ".txt"):
        text = re.sub(r"(^|\s)#[^\n]*", r"\1", text, flags=re.M)
    return text


def strip_strings(text: str) -> str:
    return re.sub(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', " ", text)


OLD_ENGINE = re.compile(r"\biverilog\b|\bvvp\b")
# A shell command position: line start (possibly behind `VAR=...`), after a pipeline or
# separator, or inside a command substitution.
SH_INVOKE = re.compile(r"(?:^|[|&;(]|\$\(|`)[ \t]*(?:[A-Za-z_]\w*=\S+[ \t]+)*(?:iverilog|vvp)\b", re.M)
CMD_LITERAL = re.compile(r"""["'](?:iverilog|vvp)["']""")
live = [q for q in list((ROOT / "tests").rglob("*")) + list((ROOT / "tools").rglob("*"))
        if q.is_file() and q.suffix in (".sh", ".py", ".sv")
        # check_4state_xlock.py is the by-hand 4-state companion run (iverilog by design,
        # never invoked by a gate), so it is the one tool allowed to spawn it.
        and q.name not in ("check_wiring.py", "check_4state_xlock.py")]
offenders = []
for q in live:
    code = strip_comments(q.read_text(errors="ignore"), q.suffix)
    if q.suffix == ".sh":
        invoked = bool(SH_INVOKE.search(code))
    else:
        invoked = bool(OLD_ENGINE.search(strip_strings(code)) or CMD_LITERAL.search(code))
    if invoked:
        offenders.append(q.relative_to(ROOT))
check(not offenders,
      f"the build path invokes iverilog/vvp: {offenders}" if offenders
      else "no build-path file invokes iverilog/vvp (comments and claim prose may name it)")
# The engine the runner DOES use, stated positively: the manifest-driven runner's argv
# names Verilator, so dropping the engine from the toolchain cannot pass this check as
# "nothing invokes the old one".
bench_src = (ROOT / "tools/bench.py").read_text()
check('"verilator"' in bench_src,
      "tools/bench.py invokes Verilator (the one bench runner's engine)")

print("== the core's own reset does not leave the core ==")
# The defect, as measured: the CPU's triple-fault request left the FPGA
# as BUTTONS[1] -- the I/O board's USER BUTTON -- and only came back through the
# HPS, where Main_MiSTer/user_io.cpp masks it while the OSD is visible (the
# OSD-open stall seen on hardware). The core now consumes it inside pc9821_system
# instead. z486_mister.sv is not in any Verilator bench's file list, so the
# wiring is guarded statically here; the CPU-side effect (a shutdown resets the
# CPU with no external stimulus, RAM and the ROM window intact) is measured by
# tb_pc9821_boot.
top = (ROOT / "z486_mister.sv").read_text()
check(re.search(r"assign\s+BUTTONS\s*=\s*2'b00\s*;", top) is not None,
      "z486_mister.sv drives BUTTONS = 2'b00 (the core simulates no button press)")
check("core_soft_reset_req" not in top,
      "z486_mister.sv does not export the CPU's shutdown request as a button")
check(re.search(r"wire\s+reset_req\s*=\s*buttons\[1\]\s*\|\s*status\[0\]", top) is not None,
      "the framework's own reset_req = buttons[1] | status[0] still starts the core's reset wire")
# This is the text z486_mister.sv:627 `reset_req = buttons[1] | status[0]` names as
# LOAD-BEARING. It is a CONTAINMENT check and
# not an end-anchored one on purpose: the wire legitimately gained a third term
# (`| disk_change_reset`, the HPS disk-change reset) and the framework's two terms still
# lead it, which is what keeps hps_io's `buttons` port name intact (`BUTTONS` differs from
# it by case alone). What must not happen is a rename of that port or the loss of either
# term -- and an end-anchored regex would have called the third term a wiring break.

# THE BOOT-ROM PACK DOWNLOAD. Main_MiSTer holds status[0] across a boot0.rom transfer, so the
# SDRAM backend the loader writes through is on the platform reset EXCEPT while
# pc9821_system's pack_load_hold is high (tb_pc9821_boot0_load drives the real pc9821_system
# with this reset modelled; z486_mister.sv itself is in no bench, so the two texts are pinned
# here). Losing the gate leaves the controller in reset for the whole download; losing the
# port connection leaves the hold undriven.
check(re.search(r"\)\s*de10_guest_memory\s*\((?:(?!\);).)*?\.reset\(\s*reset_sync_r\[2\]\s*&&\s*!pack_load_hold\s*\)",
                top, re.S) is not None,
      "the SDRAM backend's reset is reset_sync_r[2] && !pack_load_hold")
check(re.search(r"\.pack_load_hold\s*\(\s*pack_load_hold\s*\)", top) is not None,
      "z486_mister.sv connects pc9821_system's pack_load_hold")

# The PC speaker is a real device on this machine, so a CONSTANT `speaker_out` is always
# wrong -- and that is exactly what it was: `assign speaker_out = 1'b0;` tied off the last
# wire of a path z486_mister.sv had carried all along, so the beeper computed nothing and
# reached no DAC. The rest of the chain is pc9821_system -> z486_mister.sv's synchronizer and
# the pc9821_audio_mix instance (its amplitude stage and its term in mix_tmp_l/r), and the
# wiring between them is AT THE TOP LEVEL, so no unit bench reaches it (z486_mister.sv is in no
# bench's file list -- the same reason the BUTTONS checks above are static). These two are the cheap half of that
# coverage: one fires if the line is tied off again, the other if it is driven by only
# half of the pair the machine uses, i.e. a tone with no mute or a mute with no tone.
system_src = (ROOT / "src/pc9821/core/pc9821_system.sv").read_text()
speaker_assign = re.search(r"assign\s+speaker_out\s*=\s*([^;]*);", system_src)
check(speaker_assign is not None, "pc9821_system.sv assigns speaker_out")
if speaker_assign:
    speaker_rhs = speaker_assign.group(1)
    check(re.search(r"1'b[01]\b", speaker_rhs) is None,
          "pc9821_system.sv does not tie speaker_out to a constant")
    # The TONE is PIT channel 1 (BANK4@0x4B2B programs channel 1 through the 0x3FDF/0x3FDB
    # alias); the exact channel is asserted by tb_pc9821_beeper, so this check only requires
    # that the RHS carries a PIT output alongside the mute and not a constant.
    check("beep_mute" in speaker_rhs and re.search(r"pit_out\d", speaker_rhs) is not None,
          "speaker_out is driven by BOTH the PIT's tone and the system port's mute")
    # tb_pc9821_beeper proves the tone is CHANNEL 1 (BANK4@0x4B2B) and the amplitude ladder,
    # but on its OWN copy of this expression and of z486_mister.sv's amplitude block, so a
    # system rewired to pit_out2 left it green. Hold both copies to
    # the shipped text.
    beeper_tb = (ROOT / "tests/pc9821/tb_pc9821_beeper.sv").read_text()
    norm = lambda t: re.sub(r"\s+", "", t)
    tb_speaker = re.search(r"wire\s+speaker\s*=\s*([^;]*);", beeper_tb)
    check(tb_speaker is not None and norm(tb_speaker.group(1)) == norm(speaker_rhs),
          "pc9821_system's speaker_out is the expression tb_pc9821_beeper proves (channel 1, muted)")
    # The amplitude block itself is no longer mirrored: the bench instantiates pc9821_audio_mix,
    # the module z486_mister.sv instantiates for the mix, at the OSD Beeper level's 0 dB. What
    # stays static is that both really do: the top level drives the mix's tone from the
    # synchronised speaker_out, and the bench feeds it its own tone at gain code 31.
    top_live_src = strip_comments_sv((ROOT / "z486_mister.sv").read_text())
    mix_inst = re.search(r"\bpc9821_audio_mix\s+u_audio_mix\s*\((?:(?!\);).)*\);", top_live_src, re.S)
    check(mix_inst is not None, "z486_mister.sv instantiates pc9821_audio_mix (u_audio_mix)")
    if mix_inst:
        inst = mix_inst.group(0)
        check(re.search(r"\.speaker\s*\(\s*speaker_out_audio\s*\)", inst) is not None
              and re.search(r"\.beep_vol\s*\(\s*beep_vol\s*\)", inst) is not None,
              "the mix's tone is the synchronised speaker_out and its ladder the 0x871E beep_vol")
        check(re.search(r"\.beep_level\s*\(\s*beep_level_code\s*\)", inst) is not None
              and re.search(r"\.snd86_level\s*\(\s*snd86_level_code\s*\)", inst) is not None,
              "the mix's Beeper and PC-9801-86 levels are pc9821_osd's decoded codes")
    tb_live = strip_comments_sv(beeper_tb)
    check(re.search(r"\bpc9821_audio_mix\s+u_mix\s*\((?:(?!\);).)*\.beep_level\s*\(\s*5'd31\s*\)"
                    r"(?:(?!\);).)*\.speaker\s*\(\s*speaker\s*\)", tb_live, re.S) is not None,
          "tb_pc9821_beeper measures the shipped pc9821_audio_mix at the Beeper level's 0 dB")

# The slave 8259's request lines are wired in pc9821_system's `.slave_irq({...})`
# concatenation, and the benches that prove a device's IRQ lands on its vector
# (tb_pc9821_opna_timers on IR4 = vector 0x14, the mouse on IR5, the FDC on IR3) each build
# their OWN copy of that concatenation, so a reordered or dropped term in the system would
# leave every one of them green. Hold the real one here, bit by
# bit, MSB first: IR7 calendar, IR6 none, IR5 bus mouse (NP2kai io/mouseif.c:135
# `pic_setirq(0x0d)`), IR4 the sound card's INT5 = IRQ12 (OPNA timers and 86-PCM),
# IR3 FDC (the BIOS's vector 0x13 ISR), IR2 the FDC's 2DD-window IRQ10, IR1 IDE (HDD and
# CD share the one channel IRQ), IR0 none. IR4 is int5_irq, the output of the pc9821_irq_share
# junction whose two inputs are the OPNA's and the 86-PCM's lines (tb_pc9821_irq_share: every
# event from either is its own request), held below too.
slave = re.search(r"\.slave_irq\s*\(\s*\{([^}]*)\}\s*\)", system_src)
check(slave is not None, "pc9821_system.sv wires the slave PIC as a .slave_irq({...}) concatenation")
if slave:
    terms = [re.sub(r"\s+", "", t) for t in slave.group(1).split(",")]
    want = [{"cal_irq"}, {"1'b0"}, {"mouse_irq"}, {"int5_irq"}, {"fdc_irq"},
            {"fdc_irq10"}, {"ata_irq", "cd_irq"}, {"1'b0"}]
    got = [set(t.split("|")) for t in terms]
    check(got == want,
          f"the slave PIC's IR7..IR0 are calendar, -, mouse, INT5 (OPNA+PCM86), FDC, FDC-2DD, IDE|CD, - "
          f"(found {terms})")
share = re.search(r"\bpc9821_irq_share\s+\w+\s*\(((?:(?!\);).)*)\);", system_src, re.S)
check(share is not None
      and re.search(r"\.irq_a\s*\(\s*opna_irq\s*\)", share.group(1)) is not None
      and re.search(r"\.irq_b\s*\(\s*pcm86_irq\s*\)", share.group(1)) is not None
      and re.search(r"\.irq\s*\(\s*int5_irq\s*\)", share.group(1)) is not None,
      "pc9821_system.sv's pc9821_irq_share takes opna_irq and pcm86_irq and drives int5_irq")

print("== the top level drives the video PLL with the cut-down reconfiguration core ==")
# z486_mister.sv used to instantiate the full `pll_cfg` (altera_pll_reconfig_top/-core: the
# status/read, MIF, DPS and manual-DPRIO arms plus the C0..C17 counter file) for the video PLL.
# pc9821_vpll_ctl writes only N (0x03), M (0x04), K (0x07) and start (0x02), which the
# framework's write-only `pll_cfg_hdmi` (sys/pll_cfg/pll_cfg_hdmi.v) services against the same
# DPRIO register map; in the fit's entity table that swap is 410 -> 170 ALMs / 296 -> 192 regs
# (pll_cfg:vpll_cfg vs pll_cfg_hdmi, main-89a68d43 seed 003). tb_pc9821_pll_cfg_lockstep proves
# the two cores program a PLL register model identically; this line stops the full core coming
# back silently, and it FAILED on the tree that still read `pll_cfg vpll_cfg (`.
top_live = strip_comments_sv((ROOT / "z486_mister.sv").read_text())
top_inst = sv_instantiates(sv_modules(top_live).get("emu", ""))
check("pll_cfg_hdmi" in top_inst, "z486_mister.sv instantiates pll_cfg_hdmi for the video PLL")
check("pll_cfg" not in top_inst,
      "z486_mister.sv instantiates no full pll_cfg (the video PLL writes only N, M, K and start)")

print("== the framework hears every 24/31 kHz switch, and the UART line follows the OSD mode ==")
# hps_io re-reports the video mode only when the active hcnt/vcnt change or new_vmode differs from
# the level latched at the previous frame (sys/hps_io.sv:986 `old_vmode != new_vmode`). The 24 kHz
# and 31 kHz rasters are both 640 x 400 active, so on the native path new_vmode is the only notice:
# the top level tied it to 1'b0 and Main kept the 56 Hz frame timing for a 70 Hz picture.
# tb_pc9821_vmode_notify proves video_out's vmode_31 makes video_calc report each switch; this holds
# the top level to feeding that output, and not a constant, into hps_io.
nv = re.search(r"\.new_vmode\s*\(\s*([^)]*?)\s*\)", top_live)
vm = re.search(r"\.vmode_31\s*\(\s*([^)]*?)\s*\)", top_live)
check(nv is not None and vm is not None and nv.group(1) == vm.group(1)
      and re.fullmatch(r"[A-Za-z_]\w*", nv.group(1) or "") is not None,
      "hps_io's new_vmode is the net pc9821_video_out's vmode_31 drives "
      f"(new_vmode={nv.group(1) if nv else None!r}, vmode_31={vm.group(1) if vm else None!r})")
# UART_TXD reaches Linux's ttyS1. Main_MiSTer sends the OSD's UART mode as 0 None, 1 PPP/Modem,
# 2 Console, 3 MIDI (user_io.cpp SetUARTMode); the debug UART (the reset banner, instrument records)
# belongs on the line only in None, where no Linux process reads it as input.
txd = re.search(r"assign\s+UART_TXD\s*=\s*([^;]*);", top_live)
dbg_mode = re.search(r"wire\s+uart_debug_mode\s*=\s*\(\s*uart_mode\s*==\s*8'd0\s*\)\s*;", top_live)
rhs = re.sub(r"\s+", "", txd.group(1)) if txd else ""
check(dbg_mode is not None, "uart_debug_mode is uart_mode == 0 (the OSD's None)")
check(rhs.count("debug_uart_tx") == 1 and "uart_debug_mode?debug_uart_tx:1'b1" in rhs
      and "uart_midi_mode?mpu_uart_tx:" in rhs,
      f"UART_TXD carries the MPU in MIDI, the debug UART only in None, and idles high otherwise ({rhs!r})")

print("== the Memory switch and Boot order fields drive the memory-switch hold on port 0x31 ==")
# tb_pc9821_msw_hold pins pc9821_iobus's side (the latch and bit 4); the decode from the OSD
# fields lives in pc9821_system's iobus instance, which no unit bench reaches. The Memory switch
# field's Keep (msw_keep) holds it; so do Boot order positions 1..6, which seed a non-default
# 0xA3FF2 nibble (pc9821_text_mem msw_fdd_nib); 0 and 7 decode to the measured nibble and leave
# the switch to the Memory switch field.
_sys_live = re.sub(r"//[^\n]*", "", (ROOT / "src/pc9821/core/pc9821_system.sv").read_text())
check(re.search(r"\.msw_hold\(msw_keep\s*\|\|\s*\(\(cfg_fdd_mode\s*!=\s*3'd0\)\s*&&\s*"
                r"\(cfg_fdd_mode\s*!=\s*3'd7\)\)\)", _sys_live) is not None,
      "pc9821_system connects iobus msw_hold to msw_keep || ((cfg_fdd_mode != 0) && (cfg_fdd_mode != 7))")
# The Text lines field reaches the iobus by name, and its setup_cfg reaches pc9821_cg.
check(re.search(r"\.text_lines_20\(text_lines_20\)", _sys_live) is not None,
      "pc9821_system connects the Text lines field to the iobus")
check(len(re.findall(r"\.setup_cfg\(setup_cfg\)", _sys_live)) == 2,
      "pc9821_system connects the iobus's setup_cfg to pc9821_cg")
# The Floppy mode field reaches the iobus by name (tb_pc9821_floppy_mode pins the iobus side),
# and the top level reaches pc9821_system with it; setup_cfg is the 24-bit {0x861E, 0x871E,
# port 0x31} seed both stores are built from.
check(re.search(r"\.floppy_mode\(floppy_mode\)", _sys_live) is not None,
      "pc9821_system connects the Floppy mode field to the iobus")
check(re.search(r"wire\s*\[23:0\]\s*setup_cfg;", _sys_live) is not None,
      "pc9821_system's setup_cfg carries the three seed bytes (24 bits)")
_top_live = re.sub(r"//[^\n]*", "", (ROOT / "z486_mister.sv").read_text())
check(re.search(r"\.osd_floppy_mode\(status\[72:71\]\)", _top_live) is not None
      and re.search(r"\.floppy_mode\s*\(floppy_mode\)", _top_live) is not None,
      "z486_mister decodes status[72:71] in pc9821_osd and passes floppy_mode to pc9821_system")

print()
for n in NOTE:
    print(f"note: {n}")
if FAIL:
    print(f"\nWIRING CHECK: FAIL ({len(FAIL)} problem(s))")
    sys.exit(1)
print("\nWIRING CHECK: PASS (static only -- nothing was simulated)")

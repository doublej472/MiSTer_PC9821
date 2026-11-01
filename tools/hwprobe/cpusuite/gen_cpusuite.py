#!/usr/bin/env python3
"""gen_cpusuite.py - build the CPUSUITE pack: z486's own self-checking test programs, re-assembled
to run on a PC-98 under the DOS harness CPUSUITE.COM (cpusuite.asm beside this file).

WHAT IT READS. src/z486/tests/programs/*.json + *.asm, the CPU's own contract suite: each program
starts from a reset-like state the bench sets up (tb_protected_mode.sv: selectors, hidden descriptor
caches, CR0/CR3, ESP=0xFF00, EFLAGS=2, GDTR=IDTR=0/0x3FF), checks itself, writes 0x01 (pass) or 0xFF
(fail) to port 0xE0 and halts. The memory image (page tables at CR3, the code at its physical base)
is built exactly as src/z486/tests/test_protected_mode.py builds it - that module is imported, not
copied, so a change to the bench's layout reaches this pack.

WHAT IT CHANGES. Nothing in src/z486/. Each program is assembled from its unmodified source with
prelude.inc pre-included (nasm -p), which re-defines OUT so the bench's status/data ports never
reach PC-98 hardware (see prelude.inc). The harness enters each program in the state the bench
gives it and gets control back through the PC-98 CPU-reset return (port 0xF0 + 0000:0404).

WHAT IT WRITES (into --out, default build/ beside this script, git-ignored):
  CPUSUITE.BIN   the pack the harness loads into XMS (format: cpusuite.asm, "PACK FORMAT")
  CPUSUITE.LST   one line per program: RUN / EXCL with the reason; the classification report
  manifest.json  the same, machine-readable (tools/mister_regress.py's cpusuite item reads it)

    python3 tools/hwprobe/cpusuite/gen_cpusuite.py               # build the pack
    python3 tools/hwprobe/cpusuite/gen_cpusuite.py --simcheck    # + run every PATCHED program in
                                                                 #   z486's own bench and require the
                                                                 #   trap to latch the bench's verdict
    python3 tools/hwprobe/cpusuite/gen_cpusuite.py --selftest
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
SUITE = ROOT / "src/z486/tests"
PRELUDE = HERE / "prelude.inc"

# The harness's engine page (cpusuite.asm ENG_PHYS). A protected-mode program that starts with
# paging on is entered by a far jump executed in this page right after CR0.PG is set, so the
# program's own page tables get one extra identity PTE for it (the bench needs none: it starts the
# CPU at the program's first instruction directly).
ENG_PHYS = 0x9F000
# Memory the bench's 512 KiB model covers (tb_protected_mode.sv MEM_SIZE = 1 << 19); the harness
# zeroes it before each program, as the bench starts from zeroed memory.
MEM_SIZE = 0x80000
# 0000:0404 holds the SS:SP the firmware's CPU-reset return loads (cpusuite.asm, "THE RETURN").
SHUTDOWN_VEC = 0x404

PACK_MAGIC = b"CPUSUIT1"
REC_SIZE = 128
NAME_LEN = 40

# Bench devices the programs can talk to besides the verdict ports (tb_protected_mode.sv, the I/O
# write/read decode): a program that needs one cannot run without the bench.
BENCH_PORTS = {
    0xE8: "the bench's INTR/NMI injector (port 0xE8)",
    0xEC: "the bench's INTR/NMI injector (delay, port 0xEC)",
    0xF0: "the bench's INTR/NMI injector (instruction delay, port 0xF0)",
    0xF4: "the bench's INTR vector (port 0xF4)",
    0xF8: "the bench's NMI pulse width (port 0xF8)",
    0xFC: "the bench's cycle counter (port 0xFC)",
    0xC0: "the bench's platform cache flush (port 0xC0)",
    0xC4: "the bench's no-snoop DMA poke (ports 0xC4/0xC8)",
    0xC8: "the bench's no-snoop DMA poke (ports 0xC4/0xC8)",
    0xCC: "the bench's asynchronous platform flush (port 0xCC)",
    0xD0: "the bench's A20 write counters (port 0xD0)",
    0xD4: "the bench's A20 write counters (port 0xD4)",
}
BENCH_PLUSARGS = {
    "xdma_trig": "the bench's external-master DMA injector (xdma)",
    "intr_rerequest": "the bench's INTR re-request model",
    "intr_drop_delay": "the bench's slow-PIC INTR model",
    "fuzz_irq_period": "the bench's random INTR source",
}

# Per-program decisions the rules above cannot see, each with its reason.
MANUAL_EXCLUDE = {
    "v86_io_bitmap_iopl3": "its denied I/O is the status-port write itself (from V86, expecting #GP at "
                           "that instruction); the trap's ports are not the program's port",
    "ifetch_page_fault": "its fixed layout needs the out-of-line dispatch, whose section lands past the pages "
                         "the program maps (--simcheck: no trap, the bench times out)",
}
# Programs that write the bench's "running" marker (0) through a CONSTANT port: their constant-port
# E0 writes check AL (with the stack) before trapping (prelude.inc CPUS_STATIC_E0_PROGRESS).
STATIC_E0_PROGRESS = {"seg_paging"}

RM_DATA_FLAGS = 0x2900   # tb_protected_mode.sv RM_DATA_FLAGS / RM_CODE_FLAGS
RM_CODE_FLAGS = 0xA900
SREGS = ("ES", "CS", "SS", "DS", "FS", "GS")   # x86 segment-register numbering 0-5


def suite_module():
    sys.path.insert(0, str(SUITE))
    import test_protected_mode as tpm   # noqa: E402  (the suite's own runner: tests + image layout)
    return tpm


# ---------------------------------------------------------------------------------------------
# descriptors
# ---------------------------------------------------------------------------------------------
def descriptor(base: int, limit: int, flags: int, d_b=None) -> bytes:
    """A GDT descriptor whose LOADED cache equals the bench's build_seg_desc(base, limit[19:0],
    flags): type[15:12] S[11] DPL[10:9] P[8] D_B[7] G[6] A[5]. The accessed bit is set in the
    descriptor so loading it writes nothing back to the table."""
    typ, s, dpl, p = (flags >> 12) & 15, (flags >> 11) & 1, (flags >> 9) & 3, (flags >> 8) & 1
    db_ = (flags >> 7) & 1 if d_b is None else d_b
    g = (flags >> 6) & 1
    limit &= 0xFFFFF
    access = (p << 7) | (dpl << 5) | (s << 4) | typ | 1
    hi = (g << 7) | (db_ << 6) | (limit >> 16)
    return struct.pack("<HHBBBB", limit & 0xFFFF, base & 0xFFFF, (base >> 16) & 0xFF, access, hi,
                       (base >> 24) & 0xFF)


# ---------------------------------------------------------------------------------------------
# classification
# ---------------------------------------------------------------------------------------------
_NUM = re.compile(r"^(0x[0-9a-fA-F]+|[0-9][0-9a-fA-F]*[hH]|\d+)$")


def _num(tok: str, syms: dict):
    tok = tok.strip()
    if tok in syms:
        return syms[tok]
    if _NUM.match(tok):
        if tok[-1] in "hH":
            return int(tok[:-1], 16)
        return int(tok, 0)
    return None


def static_ports(src: str) -> set:
    """Ports the source names in OUT/IN/MOV DX forms, with EQU/%define names resolved. A static
    scan (no bench needed); --simcheck checks the dynamic truth against the pack."""
    syms = {}
    for m in re.finditer(r"(?im)^\s*(?:%define\s+(\w+)\s+([^\s;]+)|(\w+)\s+equ\s+([^\s;]+))", src):
        name, val = (m.group(1), m.group(2)) if m.group(1) else (m.group(3), m.group(4))
        v = _num(val, syms)
        if v is not None:
            syms[name] = v
    ports = set()
    for line in src.splitlines():
        code = line.split(";", 1)[0]
        for m in re.finditer(r"(?i)\bout\s+([^,\s]+)\s*,|\bin\s+(?:al|ax|eax)\s*,\s*([^\s,]+)|"
                             r"\bmov\s+e?dx\s*,\s*([^\s,\]]+)", code):
            tok = next(g for g in m.groups() if g)
            v = _num(tok, syms)
            if v is not None:
                ports.add(v & 0xFFFF)
    return ports


def classify(name: str, cfg: dict, src: str):
    """-> (None, None) when the program runs, else (category, reason)."""
    if cfg.get("requires_x87"):
        return "x87", "needs the x87: the PC-9821 core is built with ENABLE_X87=0"
    if cfg.get("requires_pc98_map"):
        return "bench-only", "needs the bench's PC-98 memory-map model (outside the 317-program suite)"
    if cfg.get("requires_bigmem"):
        return "bench-only", "needs the 4 MiB bench (outside the 317-program suite)"
    if cfg.get("expect_fail"):
        return "bench-only", "an expected failure in the bench"
    if name in MANUAL_EXCLUDE:
        return "semantics", MANUAL_EXCLUDE[name]
    for a in cfg.get("sim_plusargs", []):
        k = a.lstrip("+").split("=")[0]
        if k in BENCH_PLUSARGS:
            return "bench-device", "needs " + BENCH_PLUSARGS[k]
    used = sorted(p for p in static_ports(src) if p in BENCH_PORTS)
    if used:
        return "bench-device", "needs " + "; ".join(dict.fromkeys(BENCH_PORTS[p] for p in used))
    return None, None


# ---------------------------------------------------------------------------------------------
# assembly and image
# ---------------------------------------------------------------------------------------------
def assemble(asm: Path, out: Path, defines=()):
    """Assemble with the prelude; inline dispatch first, the out-of-line form if a fixed layout
    (TIMES n-($-$$)) cannot take it. -> (ok, mode or error text)."""
    errs = []
    for mode in ("inline", "outline"):
        d = list(defines) + (["-DCPUS_OUTLINE"] if mode == "outline" else [])
        r = subprocess.run(["nasm", "-f", "bin", "-p", str(PRELUDE), *d, "-o", str(out), str(asm)],
                           capture_output=True, text=True)
        if r.returncode == 0:
            return True, mode
        errs.append(r.stderr.strip().splitlines()[0] if r.stderr.strip() else "nasm failed")
    return False, errs[-1]


def code_phys_of(cfg: dict) -> int:
    """Where the bench loads the code (test_protected_mode.build_memory_image): 0x10000, or the
    physical page the first mapping of CS's linear base names."""
    for pt in cfg.get("page_tables", []):
        if pt[0] == cfg.get("seg_cache", {}).get("CS", {}).get("base", 0x10000000):
            return pt[1]
    return 0x10000


def build_image(tpm, cfg: dict, code: bytes, pad: bool):
    """{phys: byte} as test_protected_mode.build_memory_image lays it out, plus the launch-pad PTE.
    -> (memory, code_phys, problem-or-None)."""
    mem = {}
    pts = cfg.get("page_tables", [])
    if pts:
        for addr, data in tpm.generate_page_tables(pts, page_dir_addr=cfg["cr3"] & 0xFFFFF000).items():
            for i, b in enumerate(data):
                mem[addr + i] = b
    code_phys = code_phys_of(cfg)
    for i, b in enumerate(code):
        mem[code_phys + i] = b
    if pad:
        # one more PTE: linear ENG_PHYS -> physical ENG_PHYS, in the page table PDE 0 points at
        pd = cfg["cr3"] & 0xFFFFF000
        pde = int.from_bytes(bytes(mem.get(pd + i, 0) for i in range(4)), "little")
        if not pde & 1:
            return mem, code_phys, "no page table covers linear 0-4 MiB for the harness's launch page"
        for lin, phys, n, _ in pts:
            if lin <= ENG_PHYS < lin + n * 0x1000:
                return mem, code_phys, "the program maps the harness's launch page itself"
        pte_addr = (pde & 0xFFFFF000) + ((ENG_PHYS >> 12) & 0x3FF) * 4
        for i, b in enumerate(struct.pack("<I", ENG_PHYS | 0x23)):    # P RW A, supervisor
            mem[pte_addr + i] = b
    hi = max(mem) if mem else 0
    if hi >= MEM_SIZE:
        return mem, code_phys, f"its image reaches 0x{hi:X}, past the bench's 512 KiB"
    if any(mem.get(SHUTDOWN_VEC + i, 0) for i in range(4)):
        return mem, code_phys, "its image occupies 0000:0404, the CPU-reset return vector"
    return mem, code_phys, None


def chunks(mem: dict, gap=16):
    """Non-zero runs (the harness zero-fills first), merging runs closer than `gap` bytes."""
    out = []
    for a in sorted(k for k, v in mem.items() if v):
        if out and a - (out[-1][0] + len(out[-1][1])) <= gap:
            s, b = out[-1]
            b.extend([0] * (a - (s + len(b))))
            b.append(mem[a])
        else:
            out.append((a, bytearray([mem[a]])))
    return out


def entry_state(cfg: dict, code_phys: int):
    """The bench's initial state (tb_protected_mode.sv's plusarg defaults) as the harness needs it:
    -> dict(mode, cr0, cr3, eip, sel[6], desc[6], null_mask) or raises ValueError."""
    real = cfg.get("start_mode", "protected").lower() == "real"
    sc = cfg.get("seg_cache") or {}
    isel = cfg.get("initial_selectors", {})
    d_init = cfg.get("d_init", 0 if real else 1)
    if real:
        dflt = {"CS": (code_phys >> 4) & 0xFFFF}
        dflt.update({k: 0 for k in ("DS", "SS", "ES", "FS", "GS")})
    else:
        dflt = {"CS": 8, "DS": 0x10, "SS": 0x18, "ES": 0x20, "FS": 0x28, "GS": 0x30}
    sel, desc, null_mask = [], [], 0
    for i, r in enumerate(SREGS):
        s = isel.get(r, dflt[r]) & 0xFFFF
        if r in sc:
            base, limit, flags = sc[r]["base"], sc[r]["limit"], sc[r]["flags"]
        elif real:
            base, limit, flags = (code_phys if r == "CS" else 0), 0xFFFF, (RM_CODE_FLAGS if r == "CS" else RM_DATA_FLAGS)
        else:
            raise ValueError("a protected-mode start without seg_cache (the bench's 0x10000000 defaults)")
        if real:
            # the harness sets the attributes in protected mode, then loads the selector in real mode,
            # which sets base = selector << 4 and keeps the rest (z486 segmentation_unit.sv SEG_CMD_SBRM)
            if base != (s << 4):
                raise ValueError(f"real-mode {r} base 0x{base:X} is not its selector 0x{s:X} << 4")
            if r == "CS" and d_init:
                raise ValueError("a real-mode start with a 32-bit CS (a real-mode far jump clears D)")
        elif s & 0xFFFC == 0:
            if r == "CS":
                raise ValueError("a null CS selector")
            if base != 0:
                raise ValueError(f"null {r} selector with base 0x{base:X} (the real-mode detour gives base 0)")
            null_mask |= 1 << i
        elif s & 4:
            raise ValueError(f"an LDT selector for {r}")
        elif (s >> 3) >= 8:
            raise ValueError(f"{r} selector 0x{s:X} is past the harness's 8-entry staging tables")
        desc.append(descriptor(base, limit, flags, d_init if r == "CS" else None))
        sel.append(s)
    eip = cfg["eip"]
    if real and eip > 0xFFFF:
        raise ValueError("a real-mode EIP above 0xFFFF")
    cr0 = cfg["cr0"]
    if real and cr0 & 1:
        raise ValueError("a real-mode start with CR0.PE set")
    if not real and not cr0 & 1:
        raise ValueError("a protected-mode start with CR0.PE clear")
    return dict(real=real, cr0=cr0, cr3=cfg["cr3"], eip=eip, sel=sel, desc=desc, null_mask=null_mask)


def record(name: str, st: dict, data_off: int, data_len: int, flags: int) -> bytes:
    """One pack directory entry (cpusuite.asm, "PACK FORMAT")."""
    r = bytearray(REC_SIZE)
    nb = name.encode()[: NAME_LEN - 1]
    r[0:len(nb)] = nb
    struct.pack_into("<IIBBHIII", r, 40, data_off, data_len, 0 if st["real"] else 1, flags,
                     st["null_mask"], st["cr0"], st["cr3"], st["eip"])
    struct.pack_into("<6H", r, 64, *st["sel"])
    for i, d in enumerate(st["desc"]):
        r[76 + 8 * i: 84 + 8 * i] = d
    return bytes(r)


FLAG_TRIPLE = 1   # the program passes by triple-faulting (the bench's expect_triple_fault)


def build(out: Path, only=None, jobs=8):
    tpm = suite_module()
    out.mkdir(parents=True, exist_ok=True)
    work = out / "obj"
    work.mkdir(exist_ok=True)
    names = sorted(tpm.TESTS)
    if only:
        names = [n for n in names if n in only]

    def one(name):
        cfg = tpm.TESTS[name]
        asm = SUITE / "programs" / cfg["asm"]
        src = asm.read_text(errors="replace")
        cat, why = classify(name, cfg, src)
        if cat:
            return dict(name=name, run=False, category=cat, reason=why)
        defines = ["-DCPUS_STATIC_E0_PROGRESS"] if name in STATIC_E0_PROGRESS else []
        binf = work / f"{name}.bin"
        ok, mode = assemble(asm, binf, defines)
        if not ok:
            return dict(name=name, run=False, category="layout", reason=f"the patched source does not assemble ({mode})")
        try:
            st = entry_state(cfg, code_phys_of(cfg))
        except ValueError as e:
            return dict(name=name, run=False, category="entry-state", reason=str(e))
        pad = (not st["real"]) and bool(st["cr0"] & 0x80000000)
        mem, code_phys, problem = build_image(tpm, cfg, binf.read_bytes(), pad)
        if problem:
            return dict(name=name, run=False, category="memory", reason=problem)
        return dict(name=name, run=True, mode=mode, st=st, mem=mem, code_phys=code_phys,
                    triple=bool(cfg.get("expect_triple_fault")), defines=defines,
                    note=("passes by triple-faulting" if cfg.get("expect_triple_fault") else ""))

    with ThreadPoolExecutor(jobs) as ex:
        res = list(ex.map(one, names))

    runs = [r for r in res if r["run"]]
    blob = bytearray()
    recs = []
    data_base = 16 + REC_SIZE * len(runs)
    for r in runs:
        off = data_base + len(blob)
        for addr, b in chunks(r["mem"]):
            blob += struct.pack("<II", addr, len(b)) + bytes(b)
            blob += bytes(-len(blob) % 4)
        blob += struct.pack("<II", 0, 0)
        recs.append(record(r["name"], r["st"], off, data_base + len(blob) - off,
                           FLAG_TRIPLE if r["triple"] else 0))
    pack = PACK_MAGIC + struct.pack("<II", len(runs), 16) + b"".join(recs) + blob
    (out / "CPUSUITE.BIN").write_bytes(pack)
    lst = [f"; CPUSUITE pack: {len(runs)} of {len(res)} z486 test configurations run (generated by "
           f"tools/hwprobe/cpusuite/gen_cpusuite.py)"]
    for r in res:
        if r["run"]:
            lst.append(f"RUN  {r['name']:32s} {'real' if r['st']['real'] else 'prot'}"
                       f"{' outline' if r['mode'] == 'outline' else ''}{' ' + r['note'] if r['note'] else ''}")
        else:
            lst.append(f"EXCL {r['name']:32s} [{r['category']}] {r['reason']}")
    (out / "CPUSUITE.LST").write_text("\n".join(lst) + "\n")
    man = {"count": len(runs), "pack_bytes": len(pack),
           "run": [r["name"] for r in runs],
           "excluded": {r["name"]: {"category": r["category"], "reason": r["reason"]} for r in res if not r["run"]}}
    (out / "manifest.json").write_text(json.dumps(man, indent=1) + "\n")
    return res, man


# ---------------------------------------------------------------------------------------------
# --simcheck: the PATCHED programs in z486's own bench
# ---------------------------------------------------------------------------------------------
def bench_command(tpm, cfg, hexf, code_phys, cycles):
    """The suite runner's own simulator command line (test_protected_mode.run_simulation builds
    it), captured instead of run, so the output can be streamed: +trace_mem is large."""
    cap = {}

    class _Capture:
        TimeoutExpired = subprocess.TimeoutExpired

        @staticmethod
        def run(cmd, **kw):
            cap["cmd"] = cmd

            class R:
                returncode, stdout, stderr = 0, "", ""
            return R()
    real = tpm.subprocess
    tpm.subprocess = _Capture
    try:
        tpm.run_simulation("x", cfg, hexf, code_phys, cycles=cycles)
    finally:
        tpm.subprocess = real
    return cap["cmd"]


def simcheck(res, out: Path, jobs=8):
    """Run every packed program, patched, in tb_protected_mode with +trace_io +trace_mem and
    require what the harness will read on the PC-98: exactly the bench's verdict latched as ~AL
    into port 0x0A, then the CPU-reset write to 0xF0, and neither bench port (0xE0/0xE4) ever
    written. A program that passes by triple-faulting must still do that and must not trap. And
    0000:0404 (THE RETURN's SS:SP) must survive: a program that writes it must reach the trap in
    real mode, where the trap stores it again (prelude.inc). The unpatched program's bench verdict
    is the reference."""
    tpm = suite_module()
    exe = SUITE / "obj_dir/Vtb_protected_mode"
    if not exe.exists():
        subprocess.run(["make", "-C", str(SUITE), "obj_dir/Vtb_protected_mode"], check=True)
    os.environ["SIM_PLUSARGS"] = "+trace_io +trace_mem"
    cwd = os.getcwd()
    os.chdir(SUITE)            # the bench reads its ROM images relative to the suite directory
    runs = [r for r in res if r["run"]]
    work = Path(tempfile.mkdtemp(prefix="cpus_", dir=out))
    cmds = {}
    for r in runs:             # serially: bench_command swaps the runner module's subprocess
        cfg = tpm.TESTS[r["name"]]
        hexf = work / f"{r['name']}.hex"
        hi = max(r["mem"])
        hexf.write_text("".join(f"{r['mem'].get(a, 0):02X}\n" for a in range(hi + 1)))
        cmds[r["name"]] = bench_command(tpm, cfg, hexf, r["code_phys"], cfg.get("cycles", 20000) * 2)

    io_re = re.compile(r"IO WR port=([0-9a-f]{4}) data=([0-9a-f]{8})")

    def one(r):
        wr, w404, after_trap_404, triple, latched = [], 0, 0, False, None
        p = subprocess.Popen(cmds[r["name"]], stdout=subprocess.PIPE, text=True, bufsize=1 << 20)
        for line in p.stdout:
            if line.startswith("MEM WR @00000404"):
                w404 += 1
                if latched is not None:
                    after_trap_404 += 1
            elif line.startswith("IO WR"):
                m = io_re.search(line)
                if m:
                    wr.append(m.groups())
                    if m.group(1) == "0008" and latched is None:
                        latched = int(m.group(2), 16)
            elif "Triple-fault" in line:
                triple = True
        p.wait()
        bad = [pp for pp, _ in wr if pp in ("00e0", "00e4")]
        if bad:
            return r["name"], False, f"a bench port was written ({bad[0]})"
        if r["triple"]:
            ok = triple and not any(pp == "00f0" for pp, _ in wr)
            if ok and w404:
                return r["name"], False, "writes 0000:0404 and leaves by a triple fault (the return would be lost)"
            return r["name"], ok, "triple fault as the bench expects" if ok else "no triple fault"
        for i, (pp, d) in enumerate(wr):
            if pp == "0008" and i + 1 < len(wr) and wr[i + 1][0] == "00f0":
                verdict = (~(int(d, 16) >> 16)) & 0xFF
                if w404 > after_trap_404 and not after_trap_404:
                    return r["name"], False, "writes 0000:0404 and traps in protected mode (the return would be lost)"
                return r["name"], verdict == 1, f"trap latched verdict 0x{verdict:02X}"
        return r["name"], False, "no trap (the bench ran out of cycles)"

    try:
        with ThreadPoolExecutor(jobs) as ex:
            got = list(ex.map(one, runs))
    finally:
        os.chdir(cwd)
        shutil.rmtree(work, ignore_errors=True)
    return got


# ---------------------------------------------------------------------------------------------
def selftest() -> int:
    fails = 0

    def check(c, what):
        nonlocal fails
        print(("ok   " if c else "FAIL ") + what)
        fails += 0 if c else 1

    # descriptors: the bench's default flat code/data and real-mode flags
    check(descriptor(0x10000, 0xFFFFF, 0xA9E0) == bytes.fromhex("ffff0000019bcf00"), "flat 32-bit code at 0x10000")
    check(descriptor(0, 0xFFFFF, 0x29E0) == bytes.fromhex("ffff00000093cf00"), "flat 32-bit data (accessed set)")
    check(descriptor(0x10000, 0xFFFFF, 0xA9E0, d_b=0) == bytes.fromhex("ffff0000019b8f00"), "d_init=0 clears CS.D")
    check(descriptor(0, 0xFFFF, RM_DATA_FLAGS) == bytes.fromhex("ffff000000930000"), "real-mode data cache")
    check(descriptor(0x20000000, 0xFFFFFFFF, 0x29E0)[7] == 0x20, "a limit above 20 bits is truncated as the bench does")
    # static port scan
    src = "STATUS_PORT equ 0xE0\nSIG equ 0E8h\n%define CY 0xFC\n mov dx, SIG\n out dx, al\n in eax, CY\n out 0x80, al ; out 0xC0, al\n"
    check(static_ports(src) == {0xE8, 0xFC, 0x80}, "static ports resolve EQU/%define and skip comments")
    check(classify("x", {"requires_x87": True}, "")[0] == "x87", "x87 programs are excluded")
    check(classify("x", {"sim_plusargs": ["xdma_trig=1"]}, "")[0] == "bench-device", "xdma programs are excluded")
    check(classify("x", {}, "SIG equ 0xE8\n mov dx, SIG\n")[0] == "bench-device", "INTR-injector programs are excluded")
    check(classify("x", {}, "STATUS_PORT equ 0xE0\n out STATUS_PORT, al\n")[0] is None, "a plain program runs")
    # chunks merge small gaps and drop zeros
    c = chunks({0: 1, 1: 0, 2: 3, 100: 4, 101: 5, 200: 0})
    check(c == [(0, bytearray([1, 0, 3])), (100, bytearray([4, 5]))], "chunks: zero-filled gaps, zero runs dropped")
    # entry state
    st = entry_state({"start_mode": "real", "cr0": 0, "cr3": 0, "eip": 0, "initial_selectors": {}}, 0x10000)
    check(st["sel"][1] == 0x1000 and st["desc"][1] == descriptor(0x10000, 0xFFFF, RM_CODE_FLAGS, 0), "real start: CS=1000")
    pm = {"start_mode": "protected", "cr0": 1, "cr3": 0, "eip": 0,
          "initial_selectors": {"CS": 8, "DS": 0, "SS": 0, "ES": 0, "FS": 0, "GS": 0},
          "seg_cache": {k: {"base": 0x10000 if k == "CS" else 0, "limit": 0xFFFFF, "flags": 0xA9E0 if k == "CS" else 0x29E0} for k in SREGS}}
    check(entry_state(pm, 0x10000)["null_mask"] == 0b111101, "null data selectors take the real-mode detour")
    bad = dict(pm, seg_cache=dict(pm["seg_cache"], DS={"base": 0x20000, "limit": 0xFFFFF, "flags": 0x29E0}))
    try:
        entry_state(bad, 0x10000)
        check(False, "a null selector with a non-zero base is refused")
    except ValueError:
        check(True, "a null selector with a non-zero base is refused")
    # record layout (cpusuite.asm reads these offsets)
    rec = record("abc", entry_state(pm, 0x10000), 0x1234, 0x56, FLAG_TRIPLE)
    check(len(rec) == REC_SIZE and rec[:4] == b"abc\0" and struct.unpack_from("<II", rec, 40) == (0x1234, 0x56)
          and rec[48] == 1 and rec[49] == 1 and struct.unpack_from("<H", rec, 66)[0] == 8, "record layout")
    print(f"selftest: {'PASS' if not fails else f'{fails} FAIL'}")
    return 1 if fails else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(HERE / "build"))
    ap.add_argument("--only", help="comma-separated program names (default: all)")
    ap.add_argument("--simcheck", action="store_true", help="run every packed program in z486's bench")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    if not shutil.which("nasm"):
        print("nasm is not installed (the z486 suite's own assembler)", file=sys.stderr)
        return 1
    out = Path(a.out).resolve()
    res, man = build(out, set(a.only.split(",")) if a.only else None, a.jobs)
    cats = {}
    for r in res:
        if not r["run"]:
            cats[r["category"]] = cats.get(r["category"], 0) + 1
    print(f"CPUSUITE pack: {man['count']} programs run, {len(res) - man['count']} excluded "
          f"({', '.join(f'{k} {v}' for k, v in sorted(cats.items()))}); {man['pack_bytes']} bytes -> {out / 'CPUSUITE.BIN'}")
    if a.simcheck:
        got = simcheck(res, out, a.jobs)
        bad = [g for g in got if not g[1]]
        for n, ok, d in got:
            if not ok:
                print(f"SIMCHECK FAIL {n}: {d}")
        print(f"simcheck: {len(got) - len(bad)}/{len(got)} programs latch the bench's verdict through the trap")
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""fuzz_hazard.py - differential fuzz for copies of memory state racing stores,
invalidates and fills (the class of the victim-slot defect: a branch-target
line demoted while a store killed only the active copy).

Each seed generates a 32-bit protected-mode program with paging on that mixes:
  - self-modifying code: stores (MOV d/w/b, RMW ADD/XOR/INC/NOT/NEG, XCHG,
    STOSD, MOVSD) into small `mov eax, imm32; ret` functions, through their own
    linear address or a second linear alias of the same frame, some crossing a
    line, followed (0-7 NOPs, optionally a not-taken Jcc that buffers the line)
    by a CALL that must run the new bytes;
  - patches of an upcoming instruction in the main stream followed by a JMP;
  - not-taken Jcc to function lines (branch-target buffer / victim churn);
  - PTE flips of a CODE page and a DATA page between two frames with INVLPG or
    a CR3 reload, then a call / load through them;
  - INVLPG and CR3-reload storms, WBINVD;
  - hot-window loads / stores / RMWs and cold-line loads (fills) between them.
Every result is folded into EBX, reported on port 0xE4.

The reference run is +z486_fast_off +z486_cache_off (no fast paths, no L1s, so no
branch-target buffer, VIPT, patch queue or store-to-load sharing); each variant
(fast paths on; fast off with caches on; fast paths toggled at random) must
report the same EBX at the same memory latency.

  fuzz_hazard.py --count N [--first S] [--jobs J] [--ops K] [--keep-fail DIR] [--rmw]

--rmw makes 70% of the operations read-modify-write storms (ADD/OR/AND/XOR/SUB/ADC/
XCHG/INC/DEC/NOT/NEG [mem] in byte/word/dword form, LOCK-prefixed, across a line or a
page boundary, absolute or register-based, with a load / store / cold fill / second RMW
placed immediately before so the RMW's first micro-step can stall after its probe).

Prints one line per seed and a summary; exit 1 on any mismatch.
"""
import argparse
import concurrent.futures as cf
import os
import random
import re
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
TDIR = HERE.parent
sys.path.insert(0, str(TDIR))
import test_protected_mode as tpm  # noqa: E402

CODE_BASE = 0x10000        # CS base; main code at CS:0
F_LIN = 0x40000            # patchable functions (identity frame)
F_SLOT0 = F_LIN + 4        # slot i at F_SLOT0 + 8*i: odd slots' imm32 cross a line
F_ALIAS = 0x200000         # second linear mapping of F's frame
NF = 48
CP_LIN = 0x50000           # code page remapped between CP_A / CP_B
CP_A, CP_B = 0x60000, 0x61000
NCP = 16
DP_LIN = 0x52000           # data page remapped between DP_A / DP_B
DP_A, DP_B = 0x62000, 0x63000
HOT = 0x70000              # 256-byte hot window
# FUZZ_PC98=1 (with the PC-98 map testbench, Z486_TESTBENCH=obj_dir_pc98/...):
# the hot-window operations also run on a device window (GVRAM, uncached
# DIRECT: its stores must take the demand path) and on window 0's RAM range,
# both folded into the result, so a device store that posts (merged, reordered
# against a VGA read that does not wait for the store queue) or a window-0
# store that does not changes the checksum or trips cache_unit's assertion.
PC98 = os.environ.get("FUZZ_PC98") == "1"
DEV = 0xA8000              # 256-byte GVRAM window (PC-98 DIRECT)
W0 = 0x90000               # 256-byte window in window 0's range (RAM)
COLD = 0x64000             # cold lines, 0x40 apart
PT = 0x1000
PTE_FL = 0x23              # P, RW, A (supervisor)


def pte_addr(lin):
    return PT + (lin >> 12) * 4


def cs_off(lin):
    return lin - CODE_BASE


class Gen:
    def __init__(self, seed, nops, rmw=False):
        self.rmw = rmw
        self.r = random.Random(seed)
        self.L = []
        self.lbl = 0
        self.nops = nops
        self.cold = 0
        self.cp_frame = CP_A
        self.dp_frame = DP_A

    def e(self, s):
        self.L.append("    " + s)

    def label(self):
        self.lbl += 1
        return f"L{self.lbl}"

    def fold(self):
        self.e("rol ebx, 5")
        self.e("xor ebx, eax")

    def pad(self):
        n = self.r.choice([0, 0, 1, 2, 3, 4, 5, 6, 7])
        for _ in range(n):
            self.e("nop")

    def rnd32(self):
        return self.r.randrange(1 << 32)

    def f_addr(self, i, alias=False):
        a = F_SLOT0 + 8 * i
        return (a - F_LIN + F_ALIAS) if alias else a

    def patch(self, addr):
        """Store into the imm32 at addr (= function + 1..)."""
        r = self.r
        k = r.randrange(11)
        v = self.rnd32()
        if k == 0:
            self.e(f"mov dword [{addr:#x}], {v:#x}")
        elif k == 1:
            o = r.randrange(3)
            self.e(f"mov word [{addr + o:#x}], {v & 0xffff:#x}")
        elif k == 2:
            o = r.randrange(4)
            self.e(f"mov byte [{addr + o:#x}], {v & 0xff:#x}")
        elif k == 3:
            self.e(f"mov esi, {v:#x}")
            self.e(f"add [{addr:#x}], esi")
        elif k == 4:
            self.e(f"inc dword [{addr:#x}]")
        elif k == 5:
            self.e(f"not dword [{addr:#x}]")
        elif k == 6:
            self.e(f"mov esi, {v:#x}")
            self.e(f"xchg [{addr:#x}], esi")
        elif k == 7:
            self.e(f"mov edi, {addr:#x}")
            self.e(f"mov eax, {v:#x}")
            self.e("stosd")
        elif k == 8:
            self.e(f"mov esi, {HOT + 4 * r.randrange(32):#x}")
            self.e(f"mov edi, {addr:#x}")
            self.e("movsd")
        elif k == 9:
            self.e(f"mov esi, {v:#x}")
            self.e(f"xor [{addr:#x}], esi")
        else:
            self.e(f"neg dword [{addr:#x}]")

    def call_f(self, i, alias=None):
        if alias is None:
            alias = self.r.random() < 0.3
        self.e(f"call {cs_off(self.f_addr(i, alias)):#x}")
        self.fold()

    def jcc_f(self, i):
        self.e("cmp esp, esp")
        self.e(f"jne {cs_off(self.f_addr(i, self.r.random() < 0.3)):#x}")

    def rmw_addr(self):
        """Address for an RMW: aligned, line-crossing, or page-crossing."""
        r = self.r
        k = r.randrange(10)
        if k < 4:
            return HOT + (r.randrange(0, 0xfc) & ~3)
        if k < 7:                                    # straddles a 16-byte line
            return HOT + 16 * r.randrange(1, 15) - r.randrange(1, 4)
        if k < 9:                                    # straddles a page (data page, remapped)
            return DP_LIN + 0x1000 - r.randrange(1, 4)
        return DP_LIN + 4 * r.randrange(1024)

    def rmw_insn(self, a):
        r = self.r
        sz = r.choice(["dword", "dword", "dword", "word", "byte"])
        reg = {"dword": "ebx", "word": "bx", "byte": "bl"}[sz]
        form = r.randrange(4)
        if form == 0:
            mem = f"[{a:#x}]"
        elif form == 1:
            self.e(f"mov esi, {a:#x}")
            mem = "[esi]"
        elif form == 2:
            self.e(f"mov esi, {a - 8:#x}")
            mem = "[esi+8]"
        else:
            self.e(f"mov esi, {(a - 4 * 3) & 0xffffffff:#x}")
            self.e("mov edx, 3")
            mem = "[esi+edx*4]"
        pre = "lock " if r.random() < 0.2 else ""
        op = r.choice(["add", "or", "and", "xor", "sub", "adc", "sbb", "xchg", "inc", "dec",
                       "not", "neg", "addi", "ori"])
        if op in ("inc", "dec", "not", "neg"):
            self.e(f"{pre}{op} {sz} {mem}")
        elif op == "xchg":
            self.e(f"{pre}xchg {mem}, {reg}")
        elif op in ("addi", "ori"):
            self.e(f"{pre}{op[:-1]} {sz} {mem}, {r.randrange(1, 100)}")
        else:
            self.e(f"{pre}{op} {mem}, {reg}")

    def rmw_storm(self):
        r = self.r
        a = self.rmw_addr()
        ctx = r.randrange(9)
        if ctx == 1:                                  # an older load still in flight
            self.e(f"mov eax, [{HOT + 4 * r.randrange(64):#x}]")
        elif ctx == 2:                                # an older store (patch slot / queue)
            self.e(f"mov [{HOT + 4 * r.randrange(64):#x}], ecx")
            self.e(f"mov [{HOT + 4 * r.randrange(64):#x}], ecx")
        elif ctx == 3 and self.cold < 0xbf00:         # a cold fill (memory latency)
            self.e(f"mov eax, [{COLD + self.cold:#x}]")
            self.cold += 0x40
        elif ctx == 4:                                # a back-to-back RMW
            self.e(f"add [{HOT + 4 * r.randrange(64):#x}], ebx")
        elif ctx == 5:                                # a store to the RMW's own word
            self.e(f"mov [{a & ~3:#x}], ebx")
        elif ctx == 6:                                # a crossing store, paging path
            self.e(f"mov [{HOT + 16 * r.randrange(1, 15) - 2:#x}], ebx")
        elif ctx == 7:
            self.e("mov eax, cr3")
            self.e("mov cr3, eax")
        for _ in range(r.choice([0, 0, 0, 1, 2])):
            self.e("nop")
        for _ in range(r.choice([1, 1, 2, 3])):       # the RMW (and back-to-back ones)
            self.rmw_insn(a if r.random() < 0.7 else self.rmw_addr())
        if r.random() < 0.7:
            self.e(f"mov eax, [{a & ~3:#x}]")
            self.fold()
        if r.random() < 0.1:
            self.e("wbinvd")

    def op(self):
        r = self.r
        if self.rmw and r.random() < 0.7:
            self.rmw_storm()
            return
        k = r.randrange(100)
        if k < 22:                                   # SMC into a function, then use it
            i = r.randrange(NF)
            if r.random() < 0.3:
                self.jcc_f(i)                         # buffered before the store
            self.patch(self.f_addr(i, r.random() < 0.4) + 1)
            self.pad()
            if r.random() < 0.4:
                self.jcc_f(i if r.random() < 0.7 else r.randrange(NF))
            if r.random() < 0.8:
                self.call_f(i)
        elif k < 30:
            self.call_f(r.randrange(NF))
        elif k < 36:
            self.jcc_f(r.randrange(NF))
        elif k < 42:                                  # patch an upcoming instruction
            lb = self.label()
            v = self.rnd32()
            self.e(f"mov dword [{CODE_BASE:#x} + {lb} + 1], {v:#x}")
            self.pad()
            self.e(f"jmp {lb}")
            self.L.append(f"{lb}:")
            self.e("mov eax, 0")
            self.fold()
        elif k < 50:                                  # remap the code page
            self.cp_frame = CP_B if self.cp_frame == CP_A else CP_A
            self.e(f"mov dword [{pte_addr(CP_LIN):#x}], {self.cp_frame | PTE_FL:#x}")
            self.inval(CP_LIN)
            self.pad()
            self.e(f"call {cs_off(CP_LIN + 8 * r.randrange(NCP)):#x}")
            self.fold()
        elif k < 54:                                  # SMC into a code-page frame by identity
            fr = r.choice([CP_A, CP_B])
            self.patch(fr + 8 * r.randrange(NCP) + 1)
            self.pad()
            self.e(f"call {cs_off(CP_LIN + 8 * r.randrange(NCP)):#x}")
            self.fold()
        elif k < 60:                                  # remap the data page
            self.dp_frame = DP_B if self.dp_frame == DP_A else DP_A
            self.e(f"mov dword [{pte_addr(DP_LIN):#x}], {self.dp_frame | PTE_FL:#x}")
            self.inval(DP_LIN)
            self.pad()
            self.e(f"mov eax, [{DP_LIN + 4 * r.randrange(1024):#x}]")
            self.fold()
            if r.random() < 0.5:
                self.e(f"add [{DP_LIN + 4 * r.randrange(1024):#x}], ebx")
        elif k < 64:                                  # invalidate storm
            for _ in range(r.randrange(1, 5)):
                self.inval(r.choice([CP_LIN, DP_LIN, F_LIN, F_ALIAS, HOT, CODE_BASE]))
        elif k < 65:
            self.e("wbinvd")
        elif k < 80:                                  # hot window
            base = HOT
            if PC98 and r.random() < 0.4:
                base = r.choice([DEV, W0])
            a = base + r.randrange(0, 0xfc)
            if r.random() < 0.7:
                a &= ~3
            kk = r.randrange(6)
            if kk == 0:
                self.e(f"mov eax, [{a:#x}]")
                self.fold()
            elif kk == 1:
                self.e(f"mov [{a:#x}], ebx")
            elif kk == 2:
                self.e(f"add [{a:#x}], ebx")
            elif kk == 3:
                self.e(f"mov [{a:#x}], ebx")
                self.e(f"mov eax, [{(a & ~3):#x}]")
                self.fold()
            elif kk == 4:
                self.e(f"mov byte [{a:#x}], bl")
                self.e(f"movzx eax, word [{a & ~1:#x}]")
                self.fold()
            else:
                self.e(f"inc dword [{a & ~3:#x}]")
        elif k < 92:                                  # cold line fill
            if self.cold < 0xbf00:
                c = COLD + self.cold
                self.cold += 0x40
                self.e(f"mov eax, [{c:#x}]")
                self.fold()
                if r.random() < 0.4:
                    self.e(f"mov [{c + 4:#x}], ebx")
        else:
            self.e("mov eax, cr3")                       # CR3 reload
            self.e("mov cr3, eax")

    def inval(self, lin):
        if self.r.random() < 0.75:
            self.e(f"invlpg [{lin:#x}]")
        else:
            self.e("mov eax, cr3")
            self.e("mov cr3, eax")

    def program(self):
        r = self.r
        L = self.L
        L += ["BITS 32", "ORG 0", "start:", "    mov esp, 0x7f000", "    cld",
              "    xor ebx, ebx"]
        # F's alias PTE, the two remapped pages' PTEs
        self.e(f"mov dword [{pte_addr(F_ALIAS):#x}], {F_LIN | PTE_FL:#x}")
        self.e(f"mov dword [{pte_addr(CP_LIN):#x}], {CP_A | PTE_FL:#x}")
        self.e(f"mov dword [{pte_addr(DP_LIN):#x}], {DP_A | PTE_FL:#x}")
        self.e("mov eax, cr3")
        self.e("mov cr3, eax")
        # functions: B8 imm32 C3 CC CC (8 bytes)
        for base, n in ((F_SLOT0, NF), (CP_A, NCP), (CP_B, NCP)):
            for i in range(n):
                a = base + 8 * i
                self.e(f"mov dword [{a:#x}], {0xb8 | ((self.rnd32() & 0xffffff) << 8):#x}")
                self.e(f"mov dword [{a + 4:#x}], {0xcccc_c300 | (self.rnd32() & 0xff):#x}")
        # data frames and the hot window
        self.e(f"mov edi, {DP_A:#x}")
        self.e(f"mov eax, {self.rnd32():#x}")
        self.e("mov ecx, 2048")
        lb = self.label()
        self.L.append(f"{lb}:")
        self.e("stosd")
        self.e("add eax, 0x9e3779b9")
        self.e(f"loop {lb}")
        for win in ([HOT, DEV, W0] if PC98 else [HOT]):
            self.e(f"mov edi, {win:#x}")
            self.e("mov ecx, 64")
            lb = self.label()
            self.L.append(f"{lb}:")
            self.e("stosd")
            self.e("rol eax, 7")
            self.e(f"loop {lb}")
        self.e("wbinvd")
        for _ in range(self.nops):
            self.op()
        # fold the hot window(s) and both data frames' first lines
        for win in ([HOT, DEV, W0] if PC98 else [HOT]):
            self.e(f"mov esi, {win:#x}")
            self.e("mov ecx, 64")
            lb = self.label()
            self.L.append(f"{lb}:")
            self.e("lodsd")
            self.fold()
            self.e(f"loop {lb}")
        self.e(f"mov eax, [{DP_A:#x}]")
        self.fold()
        self.e(f"mov eax, [{DP_B:#x}]")
        self.fold()
        self.e("mov eax, ebx")
        self.e("out 0xe4, eax")
        self.e("mov al, 1")
        self.e("out 0xe0, al")
        self.e("hlt")
        return "\n".join(L) + "\n"


def config(name, lat):
    seg = {"base": 0, "limit": 0xffffffff, "flags": 0x29e0}
    return {"asm": name + ".asm", "start_mode": "protected", "cr0": 0x80000001, "cr3": 0,
            "eip": 0,
            "seg_cache": {"CS": {"base": CODE_BASE, "limit": 0xffffffff, "flags": 0xa9e0},
                          "DS": seg, "SS": seg, "ES": seg, "FS": seg, "GS": seg},
            "page_tables": [[0, 0, 128, "RW"]] + ([[W0, W0, 1, "RW"], [DEV, DEV, 1, "RW"]] if PC98 else []),
            "mem_latency": lat, "cycles": 3_000_000}


def run_one(stem, cfg, plus):
    scale = tpm.THROTTLE_CYCLE_SCALE[tpm.throttle_setting(" ".join(plus))]
    old = os.environ.get("SIM_PLUSARGS")
    os.environ["SIM_PLUSARGS"] = " ".join(["+trace_io"] + plus)
    try:
        ok, failed, timeout, out = tpm.run_simulation(stem.name, cfg, stem.with_suffix(".hex"),
                                                      CODE_BASE, False, False, cfg["cycles"] * scale,
                                                      wall_timeout=900 * scale)
    finally:
        if old is None:
            os.environ.pop("SIM_PLUSARGS", None)
        else:
            os.environ["SIM_PLUSARGS"] = old
    m = re.findall(r"TEST DATA: 0x([0-9A-Fa-f]+)", out)
    if "Fatal" in out or "%Error" in out:
        fat = next((l for l in out.splitlines() if "Fatal" in l or "%Error" in l), "")
        return "FATAL " + fat.strip()[:160]
    if timeout or not ok:
        return "TIMEOUT" if timeout else ("NOPASS " + (m[-1] if m else "NONE"))
    return m[-1].lower() if m else "NONE"


def seed_job(seed, nops, keep_dir, rmw=False, extra=""):
    r = random.Random(seed * 7919 + 1)
    lat = r.choice(list(range(0, 33)))
    narrow = r.random() < 0.3
    toggle = r.choice([37, 101, 257, 997])
    work = Path(tempfile.mkdtemp(prefix=f"fzh_{seed}_"))
    stem = work / f"fzh_{seed}"
    asm = Gen(seed, nops, rmw).program()
    stem.with_suffix(".asm").write_text(asm)
    cfg = config(stem.name, lat)
    if not tpm.assemble(stem.with_suffix(".asm"), stem.with_suffix(".bin"),
                        stem.with_suffix(".lst")):
        return seed, lat, "ASM FAIL", {}
    tpm.build_memory_image(cfg, stem.with_suffix(".bin"), stem.with_suffix(".hex"))
    # +spec_check: the bench's branch-target buffer oracle (a stale seeded line
    # is a $fatal, i.e. a FATAL result, even when the checksum survives it).
    base = [f"+mem_latency={lat}", "+spec_check"] + (["+no_line_fill"] if narrow else []) + extra.split() + os.environ.get("FUZZ_EXTRA", "").split()
    ref = run_one(stem, cfg, base + ["+z486_fast_off", "+z486_cache_off"])
    res = {
        "fast": run_one(stem, cfg, base),
        "fastoff": run_one(stem, cfg, base + ["+z486_fast_off"]),
        f"toggle{toggle}": run_one(stem, cfg, base + [f"+z486_fast_toggle={toggle}"]),
    }
    # FUZZ_THROTTLE="2 5 7": also run at those CPU throttle settings (the CPU's
    # clock gated, memory and I/O at full rate) against the same reference.
    for sel in os.environ.get("FUZZ_THROTTLE", "").replace(",", " ").split():
        res[f"thr{sel}"] = run_one(stem, cfg, base + [f"+cpu_speed={sel}"])
    bad = {k: v for k, v in res.items() if v != ref}
    if bad and keep_dir:
        Path(keep_dir).mkdir(parents=True, exist_ok=True)
        shutil.copy(stem.with_suffix(".asm"), Path(keep_dir) / f"fzh_{seed}.asm")
    shutil.rmtree(work, ignore_errors=True)
    desc = f"lat {lat}{' narrow' if narrow else ''}"
    return seed, desc, ref, res


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--count", type=int, default=8)
    ap.add_argument("--first", type=int, default=1)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--ops", type=int, default=400)
    ap.add_argument("--keep-fail", default="")
    ap.add_argument("--extra", default="", help="extra plusargs for every run, e.g. '+cpu_speed=2'")
    ap.add_argument("--rmw", action="store_true", help="RMW-heavy operation mix")
    a = ap.parse_args()
    if a.jobs > 8 and not os.environ.get("FUZZ_ALLOW_WIDE"):
        print("--jobs capped at 8 (set FUZZ_ALLOW_WIDE=1 on a dedicated host)")
        a.jobs = 8
    bad = 0
    n = 0
    with cf.ProcessPoolExecutor(max_workers=a.jobs) as ex:
        futs = [ex.submit(seed_job, s, a.ops, a.keep_fail, a.rmw, a.extra)
                for s in range(a.first, a.first + a.count)]
        for f in cf.as_completed(futs):
            seed, desc, ref, res = f.result()
            n += 1
            ok = all(v == ref for v in res.values()) and not ref.startswith(("FATAL", "TIMEOUT", "NOPASS", "NONE", "ASM"))
            bad += not ok
            print(f"SEED {seed} {desc} ref {ref} " +
                  " ".join(f"{k} {v}" for k, v in res.items()) +
                  (" MATCH" if ok else " MISMATCH"), flush=True)
    print(f"fuzz_hazard: {n - bad}/{n} seeds match")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

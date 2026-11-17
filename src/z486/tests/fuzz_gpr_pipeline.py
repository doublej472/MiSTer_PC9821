#!/usr/bin/env python3
"""Seeded differential stress for the integer pipeline.

Generates random flat 32-bit protected-mode programs from a small instruction
subset (loads, stores, RMW, partial-register writes, PUSH/POP, LEA, shifts,
XCHG, MOVZX/MOVSX, BSWAP, IMUL, occasional WBINVD so loads miss again),
computes the architectural result with a Python model and makes the program
check every general register and every data dword itself.  Cold misses and a
long memory latency keep deferred load tokens, delay-slot bypasses and
write-backs overlapping, which is what the hazard inventory's A7/A8 items ask
about.  A mismatch prints the failing seed; rerun it with --seed N --keep.

    ./fuzz_gpr_pipeline.py --count 40           # seeds 1..40
    ./fuzz_gpr_pipeline.py --seed 17 --keep -v   # reproduce one
"""
import argparse
import os
import random
import sys
from pathlib import Path

import test_protected_mode as tpm

M32 = 0xFFFFFFFF
REGS = ['eax', 'ecx', 'edx', 'ebx', 'esi', 'edi']        # EBP = data base, ESP = stack
R8L = {'eax': 'al', 'ecx': 'cl', 'edx': 'dl', 'ebx': 'bl'}
R8H = {'eax': 'ah', 'ecx': 'ch', 'edx': 'dh', 'ebx': 'bh'}
R16 = {r: r[1:] for r in REGS}
DATA = 0x20000
NDW = 64
STACK = 0x8000


class Model:
    def __init__(self, rng):
        self.r = {x: rng.getrandbits(32) for x in REGS}
        self.mem = {}
        self.data = [rng.getrandbits(32) for _ in range(NDW)]
        for i, v in enumerate(self.data):
            for b in range(4):
                self.mem[DATA + 4 * i + b] = (v >> (8 * b)) & 0xFF
        self.esp = STACK
        for a in range(STACK - 0x400, STACK):
            self.mem[a] = 0

    def rd(self, a, n):
        return sum(self.mem[a + i] << (8 * i) for i in range(n))

    def wr(self, a, n, v):
        for i in range(n):
            self.mem[a + i] = (v >> (8 * i)) & 0xFF


def gen(seed, n_insns, corrupt=False):
    rng = random.Random(seed)
    m = Model(rng)
    lines = []
    reg = lambda: rng.choice(REGS)

    def disp(width=4, unaligned_ok=True):
        if unaligned_ok and rng.random() < 0.15:
            return rng.randrange(0, NDW * 4 - width)
        return rng.randrange(0, NDW) * 4 if width == 4 else rng.randrange(0, NDW * 4 - width)

    for _ in range(n_insns):
        k = rng.randrange(23)
        if k == 0:
            d, v = reg(), rng.getrandbits(32)
            lines.append(f'mov {d}, 0x{v:08x}'); m.r[d] = v
        elif k == 1:
            d, s = reg(), reg()
            lines.append(f'mov {d}, {s}'); m.r[d] = m.r[s]
        elif k in (2, 3):
            d, o = reg(), disp()
            lines.append(f'mov {d}, [ebp+{o}]'); m.r[d] = m.rd(DATA + o, 4)
        elif k == 4:
            s, o = reg(), disp()
            lines.append(f'mov [ebp+{o}], {s}'); m.wr(DATA + o, 4, m.r[s])
        elif k == 5:
            op = rng.choice(['add', 'sub', 'xor', 'and', 'or'])
            d, s = reg(), reg()
            lines.append(f'{op} {d}, {s}')
            a, b = m.r[d], m.r[s]
            m.r[d] = {'add': a + b, 'sub': a - b, 'xor': a ^ b, 'and': a & b, 'or': a | b}[op] & M32
        elif k == 6:
            op = rng.choice(['add', 'sub', 'xor', 'and', 'or'])
            d, o = reg(), disp()
            lines.append(f'{op} {d}, [ebp+{o}]')
            a, b = m.r[d], m.rd(DATA + o, 4)
            m.r[d] = {'add': a + b, 'sub': a - b, 'xor': a ^ b, 'and': a & b, 'or': a | b}[op] & M32
        elif k == 7:
            op = rng.choice(['add', 'xor', 'or'])
            s, o = reg(), disp()
            lines.append(f'{op} [ebp+{o}], {s}')
            a, b = m.rd(DATA + o, 4), m.r[s]
            m.wr(DATA + o, 4, {'add': a + b, 'xor': a ^ b, 'or': a | b}[op] & M32)
        elif k == 8:
            op, d = rng.choice(['inc', 'dec', 'not', 'neg']), reg()
            lines.append(f'{op} {d}')
            a = m.r[d]
            m.r[d] = {'inc': a + 1, 'dec': a - 1, 'not': ~a, 'neg': -a}[op] & M32
        elif k == 9:
            d, b, i = reg(), reg(), reg()
            sc, o = rng.choice([1, 2, 4, 8]), rng.randrange(-64, 64)
            lines.append(f'lea {d}, [{b}+{i}*{sc}{o:+d}]')
            m.r[d] = (m.r[b] + m.r[i] * sc + o) & M32
        elif k == 10:
            s = reg()
            lines.append(f'push {s}')
            m.esp -= 4; m.wr(m.esp, 4, m.r[s])
        elif k == 11:
            d = reg()
            if m.esp < STACK:
                lines.append(f'pop {d}')
                m.r[d] = m.rd(m.esp, 4); m.esp += 4
            else:
                lines.append(f'mov {d}, [ebp+0]'); m.r[d] = m.rd(DATA, 4)
        elif k == 12:
            a, b = reg(), reg()
            lines.append(f'xchg {a}, {b}'); m.r[a], m.r[b] = m.r[b], m.r[a]
        elif k == 13:
            d, o = reg(), disp(1)
            lines.append(f'movzx {d}, byte [ebp+{o}]'); m.r[d] = m.rd(DATA + o, 1)
        elif k == 14:
            d, o = reg(), disp(2)
            v = m.rd(DATA + o, 2)
            lines.append(f'movsx {d}, word [ebp+{o}]')
            m.r[d] = (v | 0xFFFF0000) if v & 0x8000 else v
        elif k == 15:
            op, d, c = rng.choice(['shl', 'shr', 'sar', 'rol']), reg(), rng.randrange(1, 32)
            lines.append(f'{op} {d}, {c}')
            a = m.r[d]
            if op == 'shl': v = a << c
            elif op == 'shr': v = a >> c
            elif op == 'sar': v = (a - (1 << 32) if a & 0x80000000 else a) >> c
            else: v = (a << c) | (a >> (32 - c))
            m.r[d] = v & M32
        elif k == 16:
            d, s = reg(), reg()
            lines.append(f'imul {d}, {s}'); m.r[d] = (m.r[d] * m.r[s]) & M32
        elif k == 17:
            d = reg()
            lines.append(f'bswap {d}')
            m.r[d] = int.from_bytes(m.r[d].to_bytes(4, 'little'), 'big')
        elif k == 18:
            d = rng.choice(list(R8L)); hi = rng.random() < 0.5; o = disp(1)
            name = (R8H if hi else R8L)[d]
            v = m.rd(DATA + o, 1)
            lines.append(f'mov {name}, [ebp+{o}]')
            sh = 8 if hi else 0
            m.r[d] = (m.r[d] & ~(0xFF << sh) & M32) | (v << sh)
        elif k == 19:
            d, s = reg(), reg()
            lines.append(f'mov {R16[d]}, {R16[s]}')
            m.r[d] = (m.r[d] & 0xFFFF0000) | (m.r[s] & 0xFFFF)
        elif k == 20:
            s, o = rng.choice(list(R8L)), disp(1)
            lines.append(f'mov [ebp+{o}], {R8L[s]}'); m.wr(DATA + o, 1, m.r[s] & 0xFF)
        elif k == 21:
            # A ROM-path load (moffs through a non-flat FS) whose destination
            # a younger direct ALU load then reads: the A8 window.
            # A dword-crossing operand cannot take the microcode-read probe,
            # so it is the optimistic paging read whose miss holds mem_opt_wait.
            o = rng.randrange(0, NDW - 1) * 4 + rng.choice([0, 0, 0, 1, 2, 3])
            o2 = disp()
            op = rng.choice(['and', 'add', 'xor', 'or'])
            if rng.random() < 0.5:
                # A store just before keeps the L1 busy, so the load cannot
                # take the probe path and enters paging optimistically.
                s3, o3 = reg(), disp()
                lines.append(f'mov [ebp+{o3}], {s3}'); m.wr(DATA + o3, 4, m.r[s3])
            if rng.random() < 0.5:
                lines.append('wbinvd')
            lines.append(f'mov eax, [fs:0x{DATA + o:x}]')
            lines.append(f'{op} eax, [ebp+{o2}]')
            a, b = m.rd(DATA + o, 4), m.rd(DATA + o2, 4)
            m.r['eax'] = {'add': a + b, 'xor': a ^ b, 'and': a & b, 'or': a | b}[op] & M32
        elif k == 22:
            lines.append('wbinvd' if rng.random() < 0.5 else 'nop')
        else:
            pass

    asm = ['BITS 32', 'ORG 0', 'start:', f'    mov esp, 0x{STACK:x}', f'    mov ebp, 0x{DATA:x}']
    asm += [f'    mov {r}, 0x{v:08x}' for r, v in Model(random.Random(seed)).r.items()]
    asm += ['    wbinvd']
    asm += ['    ' + l for l in lines]
    if corrupt:                       # self-test: the checker must notice
        m.r['ebx'] ^= 1
    code = 1
    for r in REGS:
        asm += [f'    cmp {r}, 0x{m.r[r]:08x}', f'    jne fail_{code}']; code += 1
    asm += [f'    cmp esp, 0x{m.esp:x}', f'    jne fail_{code}']; code += 1
    for i in range(NDW):
        asm += [f'    cmp dword [ebp+{4*i}], 0x{m.rd(DATA + 4*i, 4):08x}', f'    jne fail_{code}']
        code += 1
    asm += ['    mov al, 1', '    out 0xe0, al', '    hlt']
    for c in range(1, code):
        asm += [f'fail_{c}:', f'    mov eax, {c}', '    jmp fail']
    asm += ['fail:', '    out 0xe4, eax', '    mov al, 0xff', '    out 0xe0, al', '    hlt']
    data = b''.join(v.to_bytes(4, 'little') for v in Model(random.Random(seed)).data)
    return '\n'.join(asm) + '\n', data


def run_seed(seed, n_insns, latency, verbose, keep, plusargs=(), corrupt=False):
    # (SIM_PLUSARGS=+cpu_speed=N runs the program with the CPU's clock gated)
    scale = tpm.THROTTLE_CYCLE_SCALE[tpm.throttle_setting(os.environ.get('SIM_PLUSARGS', ''))]
    asm, data = gen(seed, n_insns, corrupt)
    work = tpm.TESTS_DIR / '.fuzz'
    work.mkdir(exist_ok=True)
    stem = work / f'fuzz_{seed}'
    (stem.with_suffix('.asm')).write_text(asm)
    cfg = {
        'asm': str(stem.with_suffix('.asm')), 'start_mode': 'protected', 'cr0': 0x11,
        'cr3': 0, 'eip': 0, 'cycles': 200000, 'mem_latency': latency,
        'initial_selectors': {s: 0x10 for s in ('DS', 'SS', 'ES', 'FS', 'GS')} | {'CS': 0x08},
        'seg_cache': {s: {'base': 0, 'limit': 0xffffffff, 'flags': 0x29e0}
                      for s in ('DS', 'SS', 'ES', 'GS')}
                     | {'FS': {'base': 0, 'limit': 0x000fffff, 'flags': 0x29e0}}
                     | {'CS': {'base': 0x10000, 'limit': 0xffffffff, 'flags': 0xa9e0}},
        'sim_plusargs': list(plusargs),
    }
    if not tpm.assemble(stem.with_suffix('.asm'), stem.with_suffix('.bin'),
                        stem.with_suffix('.lst')):
        return False, 'assembly failed'
    hexf = stem.with_suffix('.hex')
    code_phys = tpm.build_memory_image(cfg, stem.with_suffix('.bin'), hexf)
    # Append the data region to the image (byte-per-line hex).
    lines = hexf.read_text().split()
    need = DATA + len(data)
    lines += ['00'] * max(0, need - len(lines))
    for i, b in enumerate(data):
        lines[DATA + i] = f'{b:02X}'
    hexf.write_text('\n'.join(lines) + '\n')
    ok, failed, timeout, out = tpm.run_simulation(f'fuzz_{seed}', cfg, hexf, code_phys,
                                                  verbose, False, cfg['cycles'] * scale,
                                                  wall_timeout=120 * scale)
    if not keep:
        for suf in ('.asm', '.bin', '.lst', '.hex'):
            stem.with_suffix(suf).unlink(missing_ok=True)
    a7 = out.count('HAZARD A7')
    a8 = out.count('HAZARD A8')
    if ok:
        return True, f'PASS a7={a7} a8={a8}'
    detail = next((l.strip() for l in out.splitlines() if 'Failure data' in l), '')
    return False, ('TIMEOUT' if timeout else 'FAIL ' + detail)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--count', type=int, default=24)
    ap.add_argument('--first', type=int, default=1)
    ap.add_argument('--seed', type=int)
    ap.add_argument('--insns', type=int, default=160)
    ap.add_argument('--keep', action='store_true')
    ap.add_argument('-v', '--verbose', action='store_true')
    args = ap.parse_args()
    if not tpm.build_testbench():
        return 1
    # The checker must reject a corrupted expectation before any pass counts.
    # It must fail at the corrupted EBX compare itself: an assembly error, a
    # timeout or a crash is a broken harness, not a catch.
    ok, msg = run_seed(1, 40, 0, False, False, corrupt=True)
    want = f'FAIL Failure data: 0x{REGS.index("ebx") + 1:08x}'
    if ok or msg != want:
        print(f'fuzz self-test FAILED: a corrupted EBX expectation gave {msg!r}, not {want!r}')
        return 1
    seeds = [args.seed] if args.seed is not None else range(args.first, args.first + args.count)
    bad = []
    hits = []
    for s in seeds:
        for lat in (0, 7, 20):
            ok, msg = run_seed(s, args.insns, lat, args.verbose, args.keep,
                               plusargs=('monitor_hazards',))
            if ok and msg != 'PASS a7=0 a8=0':
                hits.append((s, lat, msg))
            if not ok:
                bad.append((s, lat, msg))
                print(f'seed {s} latency {lat}: {msg}')
    total = len(list(seeds)) * 3
    for s, lat, msg in hits:
        print(f'seed {s} latency {lat}: hazard window reached, result correct ({msg})')
    print(f'fuzz: {total - len(bad)}/{total} programs passed; '
          f'{len(hits)} reached an A7/A8 hazard window')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())

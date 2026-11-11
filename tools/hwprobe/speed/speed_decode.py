#!/usr/bin/env python3
"""speed_decode.py - decode a SPEED capture, or compare two (the core against the machine).

    speed_decode.py SPEED.TXT                 the numbers of one run
    speed_decode.py A.TXT B.TXT               both, and B's speed relative to A's per row
                                              (> 1.00: B is faster); the SAME binary only
    speed_decode.py --image SPEED.COM X.TXT   check that X.TXT came from that binary
    speed_decode.py --selftest

The capture (speed.asm header): `ID SPEED v1 crc=<CRC-32 of the .COM> size=<bytes>`, `PITCAL ...`,
`DHRY iters=<n> art=<ticks from MARK_START to MARK_END> ... result=<0 = the gate's validation
passed> ... PASS|FAIL`, `ROW <name> n=<ops> bytes=<bytes> art=<fastest of 3> t=<3 trials>`,
`END:SPEED`. Every `art` is in ARTIC ticks: 307,200 Hz (1 tick = 3.2552 us).

Derived:
  - Dhrystone/s per run, and the slope (t100000 - t10000) / 90000 iterations, which removes the
    two marker interrupts; DMIPS = Dhrystone/s / 1757 (VAX 11/780 = 1757 Dhrystone/s, the
    convention docs/dhrystone-numbers.md uses).
  - ROW ns/op (gross). ALU, IN02 and INA0 are loops of the LOOP row's shell (dec ecx / jnz) plus
    their body, so their net ns/op subtracts LOOP's ns/iteration. String rows give MB/s.
  - PITCAL pit/art: 8.0 (2.4576 MHz) or 6.5 (1.9968 MHz, by the 0x0501 strap): the ARTIC is the
    time base only if this matches.
"""
from __future__ import annotations

import re
import sys
import zlib

ARTIC_HZ = 307200
DMIPS_DHRY = 1757
SHELL = {'ALU', 'IN02', 'INA0'}
ID_RE = re.compile(r'ID SPEED v(\d+) crc=([0-9A-F]{8}) size=(\d+)$')
PIT_RE = re.compile(r'PITCAL strap0501=([0-9A-F]{2}) order=(\d) pitmax=(\d+) win=(\d+) art=(\d+) pit=(\d+)$')
DHRY_RE = re.compile(r'DHRY iters=(\d+) art=(\d+) total=(\d+) marks=(\d+) result=([0-9A-F]{8}) '
                     r'fault=(\d) dps=(\d+|-) (PASS|FAIL)$')
ROW_RE = re.compile(r'ROW (\w+) n=(\d+) bytes=(\d+) art=(\d+) t=(\d+),(\d+),(\d+)$')


class Capture:
    def __init__(self, text: str, name: str = '?'):
        self.name = name
        self.id = None
        self.pit = None
        self.dhry = []
        self.rows = {}
        self.end = False
        for ln in text.splitlines():
            ln = ln.strip()
            if m := ID_RE.match(ln):
                self.id = (int(m[1]), m[2], int(m[3]))
            elif m := PIT_RE.match(ln):
                self.pit = dict(strap=int(m[1], 16), order=int(m[2]), pitmax=int(m[3]), win=int(m[4]),
                                art=int(m[5]), pit=int(m[6]))
            elif m := DHRY_RE.match(ln):
                self.dhry.append(dict(iters=int(m[1]), art=int(m[2]), total=int(m[3]), marks=int(m[4]),
                                      result=int(m[5], 16), fault=int(m[6]), ok=m[8] == 'PASS'))
            elif m := ROW_RE.match(ln):
                self.rows[m[1]] = dict(n=int(m[2]), bytes=int(m[3]), art=int(m[4]),
                                       t=[int(m[5]), int(m[6]), int(m[7])])
            elif ln == 'END:SPEED':
                self.end = True

    def problems(self) -> list:
        p = []
        if not self.id:
            p.append('no ID line')
        if not self.end:
            p.append('no END:SPEED (the run stopped)')
        for d in self.dhry:
            if not d['ok']:
                p.append(f"DHRY {d['iters']}: FAIL result={d['result']:08X} fault={d['fault']} marks={d['marks']}")
        if self.pit and self.pit['win']:
            r = self.pit_ratio()
            if not (abs(r - 8.0) < 0.02 or abs(r - 6.5) < 0.02):
                p.append(f'PITCAL pit/art {r:.4f} is neither 8.0 nor 6.5: the ARTIC time base is suspect')
        return p

    def pit_ratio(self) -> float:
        return self.pit['pit'] / self.pit['art'] if self.pit and self.pit['art'] else float('nan')

    def dps(self) -> dict:
        """Dhrystone/s: per iteration count (fastest run), and the slope between the two counts."""
        best = {}
        for d in self.dhry:
            if d['ok'] and d['art']:
                best[d['iters']] = min(best.get(d['iters'], 1 << 62), d['art'])
        out = {f'DHRY{n}': n * ARTIC_HZ / a for n, a in sorted(best.items())}
        ks = sorted(best)
        if len(ks) >= 2 and ks[-1] > ks[0]:
            slope = (best[ks[-1]] - best[ks[0]]) / (ks[-1] - ks[0])
            if slope > 0:
                out['DHRYSLOPE'] = ARTIC_HZ / slope
        return out

    def ns(self, name: str) -> float:
        r = self.rows[name]
        return r['art'] * 1e9 / ARTIC_HZ / r['n']

    def net_ns(self, name: str) -> float:
        v = self.ns(name)
        if name in SHELL and 'LOOP' in self.rows:
            v -= self.ns('LOOP')
        return v

    def mbs(self, name: str):
        r = self.rows[name]
        return r['bytes'] / (r['art'] / ARTIC_HZ) / 1e6 if r['bytes'] and r['art'] else None


def report(c: Capture) -> list:
    L = [f'== {c.name}']
    if c.id:
        L.append(f'binary crc={c.id[1]} size={c.id[2]}')
    if c.pit:
        L.append(f"PITCAL pit/art = {c.pit_ratio():.4f} over {c.pit['win']} windows (strap 0x0501={c.pit['strap']:02X})")
    for k, v in c.dps().items():
        L.append(f'{k:10s} {v:10.0f} Dhrystone/s  {v / DMIPS_DHRY:7.2f} DMIPS')
    for name in c.rows:
        mb = c.mbs(name)
        s = f'{name:8s} {c.ns(name):9.2f} ns/op'
        if name in SHELL:
            s += f'  net {c.net_ns(name):8.2f} ns'
        if mb:
            s += f'  {mb:8.2f} MB/s'
        L.append(s)
    for p in c.problems():
        L.append('PROBLEM: ' + p)
    return L


def compare(a: Capture, b: Capture) -> list:
    L = [f'== {b.name} relative to {a.name} (> 1.00: {b.name} faster)']
    da, db = a.dps(), b.dps()
    for k in da:
        if k in db:
            L.append(f'{k:10s} {da[k]:10.0f} {db[k]:10.0f}  x{db[k] / da[k]:.3f}')
    for name in a.rows:
        if name in b.rows:
            na, nb = a.net_ns(name), b.net_ns(name)
            r = f'x{na / nb:.3f}' if nb > 0 and na > 0 else 'n/a'
            L.append(f'{name:10s} {na:9.2f} {nb:9.2f} ns  {r}')
    return L


def same_binary(a: Capture, b: Capture) -> bool:
    return bool(a.id and b.id and a.id == b.id)


SELFTEST = """ID SPEED v1 crc=D291BA6A size=27424\r
PITCAL strap0501=24 order=0 pitmax=65532 win=8 art=48000 pit=384000\r
DHRY iters=10000 art=61440 total=61500 marks=2 result=00000000 fault=0 dps=50000 PASS\r
DHRY iters=100000 art=614400 total=614460 marks=2 result=00000000 fault=0 dps=50000 PASS\r
DHRY iters=100000 art=614410 total=614470 marks=2 result=00000000 fault=0 dps=49999 PASS\r
ROW LOOP n=4000000 bytes=0 art=122880 t=122880,122881,122882\r
ROW ALU n=4000000 bytes=0 art=245760 t=245760,245760,245761\r
ROW IN02 n=200000 bytes=0 art=61440 t=61440,61441,61440\r
ROW MOVSD n=1048576 bytes=4194304 art=30720 t=30720,30720,30720\r
RESTORE vram=put-back grcg=off\r
END:SPEED\r
"""


def selftest() -> int:
    c = Capture(SELFTEST, 'synthetic')
    ok = True

    def chk(cond, what):
        nonlocal ok
        if not cond:
            print('SELFTEST FAIL:', what)
            ok = False
    chk(c.id == (1, 'D291BA6A', 27424), 'ID line')
    chk(abs(c.pit_ratio() - 8.0) < 1e-9, 'PIT ratio')
    d = c.dps()
    chk(abs(d['DHRY10000'] - 50000) < 1e-6, 'dps 10000')
    chk(abs(d['DHRY100000'] - 50000) < 1e-6, 'dps 100000 (fastest of two)')
    chk(abs(d['DHRYSLOPE'] - 50000) < 1e-6, 'slope')
    chk(abs(c.ns('LOOP') - 100.0) < 1e-6, 'LOOP 100 ns')
    chk(abs(c.net_ns('ALU') - 100.0) < 1e-6, 'ALU net 100 ns')
    chk(abs(c.net_ns('IN02') - 900.0) < 1e-6, 'IN02 net 900 ns')
    chk(abs(c.mbs('MOVSD') - 41.94304) < 1e-6, 'MOVSD MB/s')
    chk(c.problems() == [], f'no problems: {c.problems()}')
    bad = Capture(SELFTEST.replace('result=00000000 fault=0 dps=50000 PASS', 'result=D0000006 fault=0 dps=50000 FAIL', 1)
                  .replace('END:SPEED', ''), 'bad')
    chk(len(bad.problems()) == 2, 'FAIL row and missing END reported')
    chk('DHRY10000' not in bad.dps(), 'a FAIL run is not counted')
    fast = Capture(SELFTEST.replace('ROW ALU n=4000000 bytes=0 art=245760', 'ROW ALU n=4000000 bytes=0 art=184320'), 'fast')
    cmp = compare(c, fast)
    chk(any(ln.startswith('ALU') and 'x2.000' in ln for ln in cmp), 'compare ratio')
    other = Capture(SELFTEST.replace('crc=D291BA6A', 'crc=00000000'), 'other')
    chk(not same_binary(c, other) and same_binary(c, fast), 'binary identity')
    chk(f'{zlib.crc32(b"123456789"):08X}' == 'CBF43926', 'CRC-32 convention (the probe computes the same)')
    print('SELFTEST PASS' if ok else 'SELFTEST FAILED')
    return 0 if ok else 1


def main(argv) -> int:
    if argv[:1] == ['--selftest']:
        return selftest()
    if argv[:1] == ['--image'] and len(argv) == 3:
        img = open(argv[1], 'rb').read()
        c = Capture(open(argv[2], encoding='ascii', errors='replace').read(), argv[2])
        want = (1, f'{zlib.crc32(img):08X}', len(img))
        print(f'image crc={want[1]} size={want[2]}; capture {c.id}')
        return 0 if c.id == want else 1
    if len(argv) not in (1, 2):
        print(__doc__)
        return 2
    caps = [Capture(open(p, encoding='ascii', errors='replace').read(), p) for p in argv]
    for c in caps:
        print('\n'.join(report(c)))
    if len(caps) == 2:
        if not same_binary(*caps):
            print('REFUSED: the two captures come from different SPEED binaries')
            return 1
        print('\n'.join(compare(*caps)))
    return 1 if any(c.problems() for c in caps) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

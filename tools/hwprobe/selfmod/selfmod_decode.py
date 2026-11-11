#!/usr/bin/env python3
"""selfmod_decode.py - decode a SELFMOD capture (todo item 141).

    selfmod_decode.py SELFMOD.TXT            per row: the first distance D at which the NEW
                                             immediate ran (the store was seen), per run
    selfmod_decode.py --compare A.TXT B.TXT  the rows that differ (machine vs core, or the core
                                             at two clock ratios: the SAME binary only)
    selfmod_decode.py --selftest

Each ROW line is `ROW <IMM|REG> A=<aa> R1=<40 chars> R2=<40 chars>`, char k (k = 0..39) the
result at D = k + 1: O = the old immediate executed (the store into the prefetch window was
not seen), N = the new one, ? = neither. Expected (selfmod.s header): NP2kai has no prefetch
queue model, N everywhere; a real i486 does not snoop its queue, O below the prefetched span.
"""
from __future__ import annotations

import re
import sys

ROW = re.compile(r'ROW (IMM|REG|A2D|BI8|BD8|W16|P1I|P2I|P3I) A=([0-9A-F]{2}) R1=([ON?]{40}) R2=([ON?]{40})$')


def parse(text: str) -> dict:
    rows = {}
    for ln in text.splitlines():
        m = ROW.match(ln.strip())
        if m:
            rows[(m[1], int(m[2], 16))] = (m[3], m[4])
    return rows


def first_new(s: str):
    i = s.find('N')
    return None if i < 0 else i + 1


def shape(s: str) -> str:
    """'O' * k + 'N' * (40 - k) is a clean threshold; anything else is irregular."""
    k = first_new(s)
    if k is None:
        return 'all O' if set(s) == {'O'} else 'irregular'
    return 'threshold' if s == 'O' * (k - 1) + 'N' * (41 - k) else 'irregular'


def report(rows: dict) -> list[str]:
    if not rows:
        return ['no ROW lines (BEGIN:SELFMOD without rows = the probe stopped)']
    o = ['form A   R1 first-N  R2 first-N  shape']
    for (form, a), (r1, r2) in sorted(rows.items()):
        o.append(f'{form}  {a:2d}   {str(first_new(r1)):>10}  {str(first_new(r2)):>10}  {shape(r1)}/{shape(r2)}')
    for form in ('IMM', 'REG', 'A2D', 'BI8', 'BD8', 'W16', 'P1I', 'P2I', 'P3I'):
        ks = [first_new(r[i]) for (f, _), r in rows.items() if f == form for i in (0, 1)]
        ks = [k for k in ks if k is not None]
        if ks:
            o.append(f'{form}: the store is seen from D = {min(ks)}..{max(ks)} (over alignments and runs)')
        elif any(f == form for f, _ in rows):
            o.append(f'{form}: the store is never seen up to D = 40')
    all_n = all(set(r1) == {'N'} and set(r2) == {'N'} for r1, r2 in rows.values())
    o.append('VERDICT: ' + ('every store seen at every distance (NP2kai\'s form: no stale prefetch)' if all_n
                            else 'stale immediates execute inside the prefetch window (an i486 that does not snoop its queue)'))
    s20 = [rows[k][0][17:20] for k in rows if k[0] == 'IMM']
    if s20:
        o.append('Star Cruiser distances D=18..20 (IMM, R1, per alignment): ' + ' '.join(s20))
    return o


def compare(a: dict, b: dict) -> list[str]:
    out = []
    for k in sorted(set(a) | set(b)):
        if a.get(k) != b.get(k):
            out.append(f'{k[0]} A={k[1]:02X}: {a.get(k)} -> {b.get(k)}')
    return out or ['identical']


def selftest() -> int:
    fails = 0

    def check(name, cond):
        nonlocal fails
        print(f'{"PASS" if cond else "FAIL"} {name}')
        fails += 0 if cond else 1

    t = ('BEGIN:SELFMOD\r\n'
         'ROW IMM A=00 R1=' + 'O' * 19 + 'N' * 21 + ' R2=' + 'O' * 19 + 'N' * 21 + '\r\n'
         'ROW IMM A=01 R1=' + 'O' * 18 + 'N' * 22 + ' R2=' + 'O' * 18 + 'N' * 22 + '\r\n'
         'ROW REG A=00 R1=' + 'N' * 40 + ' R2=' + 'N' * 40 + '\r\nEND:SELFMOD\r\n')
    r = parse(t)
    check('three rows parsed', len(r) == 3)
    check('first N at D=20', first_new(r[('IMM', 0)][0]) == 20)
    check('threshold shape', shape(r[('IMM', 0)][0]) == 'threshold')
    check('irregular shape', shape('ONO' + 'N' * 37) == 'irregular')
    rep = '\n'.join(report(r))
    check('report range', 'IMM: the store is seen from D = 19..20' in rep)
    check('verdict stale', 'stale immediates' in rep)
    allnew = {k: ('N' * 40, 'N' * 40) for k in r}
    check('verdict NP2kai', 'NP2kai' in '\n'.join(report(allnew)))
    check('compare finds rows', len(compare(r, allnew)) == 2)
    print(f'{"PASS" if not fails else "FAIL"}: selfmod_decode selftest ({fails} failing)')
    return 1 if fails else 0


def main(argv) -> int:
    if argv[1:] == ['--selftest']:
        return selftest()
    if len(argv) == 4 and argv[1] == '--compare':
        for ln in compare(parse(open(argv[2], encoding='latin-1').read()),
                          parse(open(argv[3], encoding='latin-1').read())):
            print(ln)
        return 0
    if len(argv) == 2:
        for ln in report(parse(open(argv[1], encoding='latin-1').read())):
            print(ln)
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))

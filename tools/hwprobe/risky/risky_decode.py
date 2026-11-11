#!/usr/bin/env python3
"""risky_decode.py - tabulate a RISKY capture (tools/hwprobe/risky/risky.s; todo items 28, 35, 97, 98).

    risky_decode.py CAPTURE.TXT [CAPTURE2.TXT]     one capture, or machine vs core side by side
    risky_decode.py --selftest

Per item:
  43F (item 28)  the read-back after each write (r1, r2), what the F8000 window showed (its
                 first word and 32 KiB sum: which ROM bank) and the B0000 word (the EMS
                 window), and whether the put-back (0x043F <- 20, 0x043D <- 02) brought the
                 as-found window back. A ROW with no R43F line is a write that hung (HUNG).
                 The read-back is summarised as a function of the written value where one
                 fits (r1 == f(v) for the low nibble, per high nibble).
  989 (item 35)  each write's five port reads and the CPU loop's ARTIC ticks against the
                 as-found loop (a moved CPU clock shows as a changed tick count).
  461 (item 97)  per page: the window words beside the same physical words (ALIAS when they
                 are equal and not all FFFF, HOLE when the window reads FFFF where memory does
                 not), and the marker written through the window (landed in the cell or not).
  43B (item 98)  per write: the read-back and every address's dword, with the change against
                 the as-found row marked.
Exit 0 when every item block present ends with its END line, 1 otherwise.
"""
from __future__ import annotations

import re
import sys

ITEMS = ('43F', '989', '461', '43B')


def blocks(text: str) -> dict:
    """item -> list of lines between BEGIN:RISKY item and END:RISKY item (the last block wins;
    an unended block is kept with ended=False)."""
    out = {}
    cur = None
    for raw in text.splitlines():
        line = raw.strip()
        m = re.match(r'BEGIN:RISKY (\w+)$', line)
        if m:
            cur = m.group(1)
            out[cur] = {'lines': [], 'ended': False}
            continue
        m = re.match(r'END:RISKY (\w+)$', line)
        if m and cur == m.group(1):
            out[cur]['ended'] = True
            cur = None
            continue
        if cur:
            out[cur]['lines'].append(line)
    return out


def all_lines(text: str, item: str) -> list:
    """every line of every block of ITEM (a resumed 43F run is a second block in the same file)."""
    res, cur = [], None
    for raw in text.splitlines():
        line = raw.strip()
        if line == f'BEGIN:RISKY {item}':
            cur = item
        elif line == f'END:RISKY {item}':
            cur = None
        elif cur:
            res.append(line)
    return res


def dec_43f(lines: list) -> tuple:
    out = []
    asf = next((l for l in lines if l.startswith('ASFOUND 43F=')), None)
    if asf:
        out.append('as found: ' + asf[8:])
    rows, started, resumed = {}, [], []
    for l in lines:
        m = re.match(r'ROW 43F ([0-9A-F]{2})$', l)
        if m:
            started.append(int(m.group(1), 16))
        m = re.match(r'RESUME after ([0-9A-F]{2})', l)
        if m:
            resumed.append(int(m.group(1), 16))
        m = re.match(r'R43F ([0-9A-F]{2}) ([0-9A-F]{2}) ([0-9A-F]{2}) ([0-9A-F]{4}) ([0-9A-F]{8}) ([0-9A-F]{4})'
                     r' \| 20/02 -> ([0-9A-F]{2}) ([0-9A-F]{4}) ([0-9A-F]{8}) ([0-9A-F]{4}) (ok|BAD)', l)
        if m:
            g = m.groups()
            rows[int(g[0], 16)] = dict(r1=int(g[1], 16), r2=int(g[2], 16), f8w=g[3], f8s=g[4], b0w=g[5],
                                      r3=int(g[6], 16), ok=g[10] == 'ok')
    hung = [v for v in started if v not in rows]
    bad = sorted(v for v, r in rows.items() if not r['ok'])
    out.append(f'rows {len(rows)}/256, hung {" ".join(f"{v:02X}" for v in hung) or "none"}, '
               f'put-back BAD {" ".join(f"{v:02X}" for v in bad) or "none"}')
    if resumed:
        out.append('resumed after ' + ' '.join(f'{v:02X}' for v in resumed))
    out.append('read-back r1 per value (rows = high nibble, columns = low nibble 0-F; .. = no row, ** = hung):')
    out.append('     ' + ' '.join(f' {i:X}' for i in range(16)))
    for hi in range(16):
        cells = []
        for lo in range(16):
            v = hi * 16 + lo
            cells.append(f'{rows[v]["r1"]:02X}' if v in rows else ('**' if v in hung else '..'))
        out.append(f'  {hi:X}x ' + ' '.join(cells))
    unstable = [f'{v:02X}' for v, r in sorted(rows.items()) if r['r1'] != r['r2']]
    out.append('r1 != r2 (read twice): ' + (' '.join(unstable) or 'none'))
    after = sorted({r['r3'] for r in rows.values()})
    out.append('read-back after the put-back (20/02): ' + ' '.join(f'{x:02X}' for x in after))
    views = {}
    for v, r in sorted(rows.items()):
        views.setdefault((r['f8w'], r['f8s']), []).append(v)
    out.append('F8000 window as shown after the write (first word, 32 KiB sum: values):')
    for (w, s), vs in views.items():
        out.append(f'  {w} {s}: ' + ' '.join(f'{v:02X}' for v in vs))
    b0 = {}
    for v, r in sorted(rows.items()):
        b0.setdefault(r['b0w'], []).append(v)
    out.append('B0000 word after the write: ' + '; '.join(f'{w}: {len(vs)} values ({vs[0]:02X}..{vs[-1]:02X})'
                                                       for w, vs in b0.items()))
    return out, rows, hung


def dec_989(lines: list) -> list:
    out = []
    base = None
    for l in lines:
        if l.startswith('LOOP ticks'):
            t = [int(x, 16) for x in re.findall(r'\b[0-9A-F]{4}\b', l.split(')', 1)[-1])]
            base = sum(t) / len(t) if t else None
            out.append(f'loop as found: {" ".join(f"{x}" for x in t)} ticks')
        elif l.startswith('ASFOUND'):
            out.append('as found: ' + l[8:])
    for l in lines:
        m = re.match(r'W989 ([0-9A-F]{4}) ([0-9A-F]{2}) -> (.*) loop=([0-9A-F]{4}) ([0-9A-F]{4})$', l)
        if m:
            t = (int(m.group(4), 16) + int(m.group(5), 16)) / 2
            dev = f' clock {100.0 * (t - base) / base:+.1f}%' if base else ''
            out.append(f'  {m.group(1)} <- {m.group(2)}: {m.group(3).strip()}  loop {t:.0f}{dev}')
        elif l.startswith('RESTORE'):
            out.append('  ' + l)
    rd = [l for l in lines if l.startswith('RD989')]
    if rd:
        out.insert(0, 'single reads: ' + ' '.join(l[6:] for l in rd))
    rds = [l for l in lines if l.startswith('ROW 989 RD')]
    if len(rds) > len(rd):
        out.append('HUNG reading ' + rds[-1][11:])
    started = [l for l in lines if l.startswith('ROW 989') and ' RD ' not in l]
    done = [l for l in lines if l.startswith('W989')]
    if len(started) > len(done):
        out.append('HUNG at ' + started[-1])
    return out


def dec_461(lines: list) -> list:
    out = []
    for l in lines:
        if l.startswith('ASFOUND'):
            out.append('as found: ' + l[8:])
        m = re.match(r'R461 ([0-9A-F]{2}) rb=([0-9A-F]{2}) win\(80000 80400 90000 9FFFE\)=((?:[0-9A-F]{4} ){4})'
                     r'dir=((?:[0-9A-F]{4} ){4})mark\(win before/after, cell\)=(\S+(?: \S+ \S+)?) \| rs=([0-9A-F]{2})'
                     r' 80000=([0-9A-F]{4}) (ok|BAD)', l)
        if m:
            pg, rb, win, dr, mk, rs, w80, ok = m.groups()
            win, dr = win.split(), dr.split()
            same = sum(a == b for a, b in zip(win, dr))
            if all(w == 'FFFF' for w in win) and not all(d == 'FFFF' for d in dr):
                cls = 'HOLE (window reads FFFF)'
            elif same == 4:
                cls = 'ALIAS (window = memory)'
            else:
                cls = f'OTHER ({same}/4 words equal)'
            mtxt = ''
            if mk != '-':
                w0, w1, cell = mk.split()
                mtxt = ('; marker landed in memory' if cell == 'C3A5' else
                        '; marker did not reach memory') + f' (window {w0}->{w1}, cell {cell})'
            out.append(f'  page {pg} rb={rb}: {cls}{mtxt}; put-back rs={rs} {ok}')
            out.append(f'      window {" ".join(win)}   direct {" ".join(dr)}')
    started = [l for l in lines if l.startswith('ROW 461')]
    done = [l for l in lines if l.startswith('R461')]
    if len(started) > len(done):
        out.append('HUNG at ' + started[-1])
    return out


def dec_43b(lines: list) -> list:
    out = []
    ref = None
    for l in lines:
        if l.startswith('ASFOUND') or l.startswith('SKIP'):
            out.append(l)
        m = re.match(r'R43B (\w+) rb=([0-9A-F]{2}) ([0-9A-F]{2}) (.*) W\(F80000 before/~written/put back\)=(\S+) (\S+) (\S+)$', l)
        if m:
            v, a, b, rest, w0, w1, w2 = m.groups()
            vals = dict(re.findall(r'([0-9A-F]{6})=([0-9A-F]{8})', rest))
            if ref is None:
                ref = vals
            diff = [k for k in vals if vals[k] != ref.get(k)]
            wr = 'writable' if w1 != w0 and w1 == f'{(~int(w0, 16)) & 0xFFFFFFFF:08X}' else 'not writable'
            out.append(f'  write {v:>2} rb={a} {b}: F80000 {wr}; changed vs as found: {" ".join(diff) or "none"}')
            out.append('      ' + ' '.join(f'{k}={vals[k]}' for k in vals))
    started = [l for l in lines if l.startswith('ROW 43B')]
    done = [l for l in lines if l.startswith('R43B')]
    if len(started) > len(done):
        out.append('HUNG at ' + started[-1])
    return out


def decode(text: str) -> tuple:
    out = []
    ok = True
    bl = blocks(text)
    for item in ITEMS:
        if item not in bl:
            continue
        out.append(f'== RISKY {item} ' + ('' if bl[item]['ended'] else '(NO END line: hung or cut)'))
        ok &= bl[item]['ended']
        if item == '43F':
            o, _, _ = dec_43f(all_lines(text, '43F'))
            out += o
        elif item == '989':
            out += dec_989(bl[item]['lines'])
        elif item == '461':
            out += dec_461(bl[item]['lines'])
        else:
            out += dec_43b(bl[item]['lines'])
    if not bl:
        out.append('no RISKY block found')
        ok = False
    return out, ok


SELF = """RISKY v1 write-then-read rows (tools/hwprobe/risky): items 28 /43F, 35 /989, 97 /461, 98 /43B
BEGIN:RISKY 43F
ASFOUND 43F=C4 f8w=00A1 f8sum=12345678 b0w=0000
ROW 43F 20
R43F 20 C4 C4 00A1 12345678 0000 | 20/02 -> C4 00A1 12345678 0000 ok
ROW 43F 21
R43F 21 C5 C5 00A1 12345678 FFFF | 20/02 -> C4 00A1 12345678 0000 ok
ROW 43F 22
BEGIN:RISKY 43F
ASFOUND 43F=C4 f8w=00A1 f8sum=12345678 b0w=0000
RESUME after 22 (its ROW has no R43F line: the write hung)
ROW 43F 23
R43F 23 C7 C7 00A1 12345678 FFFF | 20/02 -> C4 00A1 12345678 0000 ok
RESTORE 043F<-20 043D<-02 (the BIOS's state), 043F reads C4
END:RISKY 43F
BEGIN:RISKY 461
ASFOUND 0461=09 0463=0B marker@00012340 80000=0000
ROW 461 00
R461 00 rb=01 win(80000 80400 90000 9FFFE)=FFFF FFFF FFFF FFFF dir=1234 0000 5678 9ABC mark(win before/after, cell)=FFFF FFFF 3C5A | rs=09 80000=0000 ok
ROW 461 08
R461 08 rb=09 win(80000 80400 90000 9FFFE)=0000 1111 2222 3333 dir=0000 1111 2222 3333 mark(win before/after, cell)=- | rs=09 80000=0000 ok
RESTORE 0461<-09 now 09
END:RISKY 461
BEGIN:RISKY 989
ASFOUND 9890=FF 9892=F0 9894=F0 9896=FF 98E0=FF
LOOP ticks (65535 x dec/jnz, ARTIC) 0100 0100 0100
ROW 989 RD 9890
RD989 9890=FF
ROW 989 RD 9892
RD989 9892=F0
ROW 989 9890 00
W989 9890 00 -> 9890=FF 9892=F0 9894=F0 9896=FF 98E0=FF  loop=0100 0102
ROW 989 9894 08
END:RISKY 989
BEGIN:RISKY 43B
ASFOUND 043B=FB FB F6=01
ROW 43B AS
R43B AS rb=FB FB F00000=00000000 F80000=FFFFFFFF FA0000=00200020 0A0000=00200020 FE8000=12345678 0E8000=12345678 FFFFF0=EA00FD00 0FFFF0=EA00FD00 W(F80000 before/~written/put back)=FFFFFFFF FFFFFFFF FFFFFFFF
ROW 43B FF
R43B FF rb=FF FF F00000=11111111 F80000=22222222 FA0000=33333333 0A0000=00200020 FE8000=44444444 0E8000=12345678 FFFFF0=55555555 0FFFF0=EA00FD00 W(F80000 before/~written/put back)=22222222 DDDDDDDD 22222222
RESTORE 043B<-FB now FB F6=01
END:RISKY 43B
"""


def selftest() -> int:
    out, ok = decode(SELF)
    text = '\n'.join(out)
    checks = [
        ('rows 3/256, hung 22' in text, '43F hung value found'),
        ('resumed after 22' in text, '43F resume seen'),
        ('  2x C4 C5 ** C7' in text, '43F nibble table'),
        ('page 00 rb=01: HOLE' in text, '461 hole'),
        ('marker did not reach memory' in text, '461 marker'),
        ('page 08 rb=09: ALIAS' in text, '461 alias'),
        ('HUNG at ROW 989 9894 08' in text, '989 hang'),
        ('single reads: 9890=FF 9892=F0' in text, '989 single reads'),
        ('(NO END line' not in text.split('== RISKY 989')[1].split('\n')[0], '989 ended'),
        ('write FF rb=FF FF: F80000 writable; changed vs as found: F00000 F80000 FA0000 FE8000 FFFFF0' in text, '43B diff'),
        (ok, 'all blocks ended'),
    ]
    bad = [n for c, n in checks if not c]
    if bad:
        print(text)
        print('SELFTEST FAIL:', ', '.join(bad))
        return 1
    _, ok2 = decode(SELF.replace('END:RISKY 43B\n', ''))
    if ok2:
        print('SELFTEST FAIL: a missing END was not flagged')
        return 1
    print('SELFTEST PASS')
    return 0


def main(argv: list) -> int:
    if argv[1:2] == ['--selftest']:
        return selftest()
    if len(argv) < 2:
        print(__doc__)
        return 2
    rc = 0
    for p in argv[1:]:
        text = open(p, 'rb').read().decode('ascii', 'replace')
        out, ok = decode(text)
        print(f'### {p}')
        print('\n'.join(out))
        rc |= 0 if ok else 1
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv))

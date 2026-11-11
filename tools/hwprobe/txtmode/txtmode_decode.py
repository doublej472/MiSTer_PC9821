#!/usr/bin/env python3
"""txtmode_decode.py - decode a `TXTMODE /D` log (tools/hwprobe/txtmode/txtmode_d.inc; todo item 128).

    txtmode_decode.py CAPTURE.TXT [CAPTURE2.TXT]   one log, or machine vs core state by state
    txtmode_decode.py --selftest

Per step (P1-P7, S3-S7, W1-W9; txtmode_d.inc): the bytes the probe sent (GDC commands and
parameters, CRTC writes), the CRTC read-back and port 0x68, the BIOS work bytes, the master
GDC's status and CSRR answer, the frame (16 VSYNC periods on the 307.2 kHz ARTIC -> frame rate;
the one-frame line count -> line rate = lines x frame rate; lines inside VSYNC), and the TRAM
read-back CRCs checked against the pattern txtmode.s writes (fill_pattern, and the step's name
in rows 0 and 3, columns 40-58). Exit 0 when the log ends with END:TXTMODE, all 21 steps are
logged and every TRAM CRC matches, 1 otherwise.
"""
from __future__ import annotations

import re
import sys

ARTIC_HZ = 307200.0


def crc16(data: bytes) -> int:
    """CRC-16/CCITT-FALSE, as txtmode_d.inc crc_b computes it."""
    c = 0xFFFF
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def pattern_row(row: int, name: str) -> tuple:
    """(code bytes, attribute bytes) of one TRAM row as fill_pattern + d_title leave it (the
    step's 19-character name in rows 0 and 3, columns 40-58)."""
    words, attrs = [], []
    base = (((row % 7) + 1) << 5) | 0x01

    def put(w, a):
        words.append(w)
        attrs.append(a)
    for ch in f'R{row:02d} ':
        put(ord(ch), base)
    for w in (0x4114, 0x4194, 0x7A1B, 0x7A9B):
        put(w, base)
    put(0x20, base)
    for i in range(50):
        put(ord('0') + i % 10, base)
    put(0x20, base)
    for _ in range(10):
        put(ord('U'), base | 0x08)
    for _ in range(10):
        put(ord('V'), base | 0x04)
    if row in (0, 3):
        for i, ch in enumerate(name):
            words[40 + i] = ord(ch)
            attrs[40 + i] = 0xE1
    code = b''.join(bytes((w & 0xFF, w >> 8)) for w in words)
    return code, bytes(attrs)


def plane(name: str, rows: int = 50) -> tuple:
    code, attr = b'', b''
    for r in range(rows):
        c, a = pattern_row(r, name)
        code += c
        attr += a
    return code, attr


def parse(text: str) -> tuple:
    steps, cur = [], None
    ended = 'END:TXTMODE' in text
    for raw in text.splitlines():
        line = raw.rstrip('\r\n')
        m = re.match(r'STEP ([0-9A-F]{2}) (.{19})', line)
        if m:
            cur = {'n': int(m.group(1), 16), 'name': m.group(2)}
            steps.append(cur)
            continue
        if cur is None:
            continue
        line = line.strip()
        for key, pre in (('out', 'OUT '), ('crtc', 'CRTC 70-7A '), ('bda', 'BDA 053C-053F '), ('stat', 'STAT '),
                         ('csrr', 'CSRR ')):
            if line.startswith(pre):
                cur[key] = line[len(pre):].strip()
        if line.startswith('FRAME'):
            m = re.search(r'ticks=([0-9A-F]{8}) lines=([0-9A-F]{4}) vsync_lines=([0-9A-F]{4})', line)
            if m:
                cur['ticks'], cur['lines'], cur['vsl'] = (int(x, 16) for x in m.groups())
        m = re.match(r'TRAM 0-3999 ([0-9A-F]{4}) ([0-9A-F]{4})', line)
        if m:
            cur['tram'] = (int(m.group(1), 16), int(m.group(2), 16))
        m = re.match(r'TRAM0 ([0-9A-F]{4}) ([0-9A-F]{4})', line)
        if m:
            cur['tram0'] = (int(m.group(1), 16), int(m.group(2), 16))
    return steps, ended


def frame(s: dict) -> str:
    if not s.get('ticks'):
        return 'frame: not measured'
    fhz = 16 * ARTIC_HZ / s['ticks']
    return (f'frame {fhz:.3f} Hz, {s["lines"]} lines -> line {s["lines"] * fhz / 1000:.3f} kHz, '
            f'VSYNC {s["vsl"]} lines')


def tram_check(s: dict) -> str:
    code, attr = plane(s['name'])
    want = (crc16(code), crc16(attr))
    want0 = (crc16(code[:160]), crc16(attr[:80]))
    if s.get('tram') == want and s.get('tram0') == want0:
        return 'matches the pattern'
    part = []
    if s.get('tram', (None, None))[0] != want[0]:
        part.append('code')
    if s.get('tram', (None, None))[1] != want[1]:
        part.append('attr')
    if s.get('tram0') != want0:
        part.append('row 0')
    return 'DIFFERS: ' + ', '.join(part)


def decode(text: str) -> tuple:
    steps, ended = parse(text)
    out, ok = [], ended
    if not ended:
        out.append('NO END:TXTMODE line')
    for s in steps:
        out.append(f'== STEP {s["n"]:02d} {s["name"]}')
        out.append('   ' + frame(s))
        out.append(f'   sent: {s.get("out", "-")}')
        out.append(f'   CRTC 70-7A, 68: {s.get("crtc", "-")}   BDA: {s.get("bda", "-")}')
        out.append(f'   GDC status at start: {s.get("stat", "-")}   CSRR: {s.get("csrr", "-")}')
        t = tram_check(s)
        out.append('   TRAM: ' + t)
        ok &= t.startswith('matches')
    if len(steps) != 21:
        out.append(f'{len(steps)} of 21 steps logged')
        ok = False
    return out, ok, steps


def compare(a: str, b: str) -> list:
    _, _, sa = decode(a)
    _, _, sb = decode(b)
    out = ['== compare (first vs second)']
    for x, y in zip(sa, sb):
        out.append(f'STEP {x["n"]:02d} {x["name"]}: {frame(x)}  |  {frame(y)}')
        for k in ('out', 'crtc', 'bda', 'csrr'):
            if x.get(k) != y.get(k):
                out.append(f'   {k} differs: {x.get(k)}  |  {y.get(k)}')
    return out


NAMES = ['P1 SYNC 4E NOPITCH ', 'P2 +PITCH 50       ', 'P3 SYNC 4C NOPITCH ', 'P4 SYNC 3E NOPITCH ',
         'P5 SYNC0E 4E START ', 'P6 PITCH THEN SYNC ', 'P7 SYNC PITCH INT18', 'S3 30 LINES +PITCH ',
         'S4 2 PARTS +PITCH  ', 'S5 4 PARTS         ', 'S6 SCROLL 240 SSL7 ', 'S7 SUR29 SDR9 SSL6 ',
         'W1 SUR29 SDR9 SSL0 ', 'W2 SUR29 SDR9 SSL1 ', 'W3 SUR29 SDR9 SSL2 ', 'W4 SUR29 SDR9 SSL4 ',
         'W5 SUR29 SDR9 SSL6 ', 'W6 SUR29 SDR9 SSL8 ', 'W7 SUR29 SDR9 SSL12', 'W8 SUR29 SDR9 SSL15',
         'W9 SUR0 SDR24 SSL6 ']


def selftest() -> int:
    lines = ['TXTMODE /D v2 text pitch and row geometry', 'CRTC 70 72 74 76 78 7A as found: 00 0F 0F 00 00 18 ']
    for i, name in enumerate(NAMES, 1):
        code, attr = plane(name)
        c, a = crc16(code), crc16(attr)
        if i == 10:
            a ^= 1
        lines += [f'STEP {i:02X} {name}', 'OUT C0F P10 P4E P07 P25 P07 P07 P90 P65 C0D ',
                  'CRTC 70-7A 00 0F 0F 00 00 18 68=18', 'BDA 053C-053F 00 00 00 00 | ' + '00 ' * 16,
                  'STAT 04 04 24 04 44 04 04 04', 'CSRR 00 00 00 -- --',
                  'FRAME 16 VSYNC ticks=000156C0 lines=01B8 vsync_lines=0008',
                  f'TRAM 0-3999 {c:04X} {a:04X}', f'TRAM0 {crc16(code[:160]):04X} {crc16(attr[:80]):04X}']
    lines += ['TXTMODE done', 'END:TXTMODE']
    out, ok, _ = decode('\r\n'.join(lines) + '\r\n')
    t = '\n'.join(out)
    checks = [(crc16(b'123456789') == 0x29B1, 'crc16 check value'),
              ('frame 56.' in t and 'line 24.' in t, 'frame/line rates'),
              ('STEP 10 S5 4 PARTS' in t and 'DIFFERS: attr' in t, 'tram mismatch named'),
              (not ok, 'mismatch fails the exit'),
              (t.count('matches the pattern') == 20, 'twenty clean steps')]
    bad = [n for c, n in checks if not c]
    if bad:
        print(t)
        print('SELFTEST FAIL:', ', '.join(bad))
        return 1
    print('SELFTEST PASS')
    return 0


def main(argv: list) -> int:
    if argv[1:2] == ['--selftest']:
        return selftest()
    if len(argv) < 2:
        print(__doc__)
        return 2
    texts = [open(p, 'rb').read().decode('ascii', 'replace') for p in argv[1:3]]
    rc = 0
    for p, t in zip(argv[1:3], texts):
        out, ok, _ = decode(t)
        print(f'### {p}')
        print('\n'.join(out))
        rc |= 0 if ok else 1
    if len(texts) == 2:
        print('\n'.join(compare(*texts)))
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv))

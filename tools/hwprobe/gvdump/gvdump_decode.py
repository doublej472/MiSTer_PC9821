#!/usr/bin/env python3
"""gvdump_decode.py - read a GVDUMP file (four 32000-byte planes B, R, G, I of 640x400).

    gvdump_decode.py DUMP.BIN                 per-plane summary (bytes set, constant planes)
    gvdump_decode.py --png DUMP.BIN OUT.png   the picture, 16 colours (I,G,R,B -> palette index
                                              bits 3..0, the PC-98 order), a fixed default palette
    gvdump_decode.py --compare A.BIN B.BIN    differing bytes per plane and the first rows that
                                              differ (the machine vs the core, the same binary)
    gvdump_decode.py --selftest
"""
from __future__ import annotations

import sys

PLANE = 32000
NAMES = ('B', 'R', 'G', 'I')


def planes(data: bytes):
    if len(data) != 4 * PLANE:
        raise ValueError(f'{len(data)} bytes, want {4 * PLANE}')
    return [data[i * PLANE:(i + 1) * PLANE] for i in range(4)]


def summary(data: bytes) -> list[str]:
    out = []
    for n, p in zip(NAMES, planes(data)):
        bits = sum(bin(b).count('1') for b in p)
        const = len(set(p)) == 1
        out.append(f'plane {n}: {bits} dots set' + (f' (constant {p[0]:02X})' if const else ''))
    return out


def compare(a: bytes, b: bytes) -> list[str]:
    out = []
    for n, pa, pb in zip(NAMES, planes(a), planes(b)):
        diff = [i for i in range(PLANE) if pa[i] != pb[i]]
        rows = sorted({i // 80 for i in diff})
        out.append(f'plane {n}: {len(diff)} bytes differ' + (f', rows {rows[:8]}{"..." if len(rows) > 8 else ""}' if diff else ''))
    return out


def to_png(data: bytes, path: str) -> None:
    from PIL import Image
    pl = planes(data)
    pal = [(0, 0, 0), (0, 0, 0x77), (0x77, 0, 0), (0x77, 0, 0x77), (0, 0x77, 0), (0, 0x77, 0x77),
           (0x77, 0x77, 0), (0x77, 0x77, 0x77), (0x44, 0x44, 0x44), (0, 0, 0xFF), (0xFF, 0, 0),
           (0xFF, 0, 0xFF), (0, 0xFF, 0), (0, 0xFF, 0xFF), (0xFF, 0xFF, 0), (0xFF, 0xFF, 0xFF)]
    im = Image.new('RGB', (640, 400))
    px = im.load()
    for y in range(400):
        for xb in range(80):
            o = y * 80 + xb
            for bit in range(8):
                m = 0x80 >> bit
                c = sum((1 << k) for k in range(4) if pl[k][o] & m)
                px[xb * 8 + bit, y] = pal[c]
    im.save(path)


def selftest() -> int:
    a = bytes(4 * PLANE)
    b = bytearray(a)
    b[PLANE + 80 * 5] = 0x80
    ok = compare(a, bytes(b))[1].startswith('plane R: 1 bytes differ, rows [5]') and \
        summary(bytes(b))[1] == 'plane R: 1 dots set' and 'constant 00' in summary(a)[0]
    print(f'{"PASS" if ok else "FAIL"}: gvdump_decode selftest')
    return 0 if ok else 1


def main(argv) -> int:
    if argv[1:] == ['--selftest']:
        return selftest()
    if len(argv) == 4 and argv[1] == '--compare':
        for ln in compare(open(argv[2], 'rb').read(), open(argv[3], 'rb').read()):
            print(ln)
        return 0
    if len(argv) == 4 and argv[1] == '--png':
        to_png(open(argv[2], 'rb').read(), argv[3])
        return 0
    if len(argv) == 2:
        for ln in summary(open(argv[1], 'rb').read()):
            print(ln)
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))

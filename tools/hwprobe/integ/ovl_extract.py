#!/usr/bin/env python3
"""ovl_extract.py - read the files a guest wrote in a tests/pc9821 userdisk run.

The userdisk tier never writes its image: with +IMG_RW the guest's sector writes land in an
in-memory overlay, and +IMG_OVL_OUT=<file> dumps that overlay at the end of the run as text,
one `<word index hex> <word hex>` per line (word index = lba*256 + word, little-endian words).
This applies the overlay to a COPY of the image and copies the named files out of it with
fatimg.py, so a probe run in simulation leaves the same capture files the machine would.

    ovl_extract.py IMAGE OVERLAY OUTDIR NAME [NAME ...]      (NAME = DOS path, e.g. CFG0.TXT)
    ovl_extract.py --selftest
"""
from __future__ import annotations

import os
import shutil
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fatimg  # noqa: E402


def apply_overlay(img_path: str, ovl_path: str) -> int:
    n = 0
    with open(img_path, 'r+b') as f, open(ovl_path) as o:
        for ln in o:
            parts = ln.split()
            if len(parts) != 2:
                continue
            k, w = int(parts[0], 16), int(parts[1], 16)
            f.seek(k * 2)
            f.write(struct.pack('<H', w))
            n += 1
    return n


def extract(image: str, overlay: str, outdir: str, names: list[str]) -> list[str]:
    os.makedirs(outdir, exist_ok=True)
    copy = os.path.join(outdir, 'ovl-applied.img')
    shutil.copyfile(image, copy)
    apply_overlay(copy, overlay)
    got = []
    with open(copy, 'rb') as f:
        fs = fatimg.Fat(f, fatimg.locate_volume(f, None, None, 0))
        for name in names:
            try:
                data = fs.cat(name)
            except SystemExit:
                data = None
            if data is None:
                continue
            with open(os.path.join(outdir, name.replace('\\', '_')), 'wb') as out:
                out.write(data)
            got.append(name)
    os.remove(copy)
    return got


def selftest() -> int:
    with tempfile.TemporaryDirectory() as td:
        img = os.path.join(td, 'v.img')
        with open(img, 'wb') as f:
            f.write(bytes(4096))
        ovl = os.path.join(td, 'o.txt')
        with open(ovl, 'w') as f:
            f.write('801 4241\n802 4443\n')     # words 0x801/0x802 = bytes 0x1002..0x1005
        apply_overlay(img, ovl)
        b = open(img, 'rb').read()
        ok = b[0x1002:0x1006] == b'ABCD' and b[0x1000:0x1002] == b'\0\0'
        print(f'{"PASS" if ok else "FAIL"}: ovl_extract selftest (overlay words land little-endian at lba*512 + 2*word)')
        return 0 if ok else 1


def main(argv) -> int:
    if argv[1:] == ['--selftest']:
        return selftest()
    if len(argv) < 5:
        print(__doc__)
        return 2
    got = extract(argv[1], argv[2], argv[3], argv[4:])
    for g in argv[4:]:
        print(f'{"got " if g in got else "MISSING "}{g}')
    return 0 if len(got) == len(argv) - 4 else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))

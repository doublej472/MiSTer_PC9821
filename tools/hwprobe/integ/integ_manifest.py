#!/usr/bin/env python3
"""integ_manifest.py - build INTEG.COM's manifest from a disk image (host side).

INTEG.COM (tools/hwprobe/integ/integ.s) reads files through DOS and compares them with this
manifest. The manifest's expected values are computed HERE from the image's own bytes, with
a reader that shares nothing with the core's RTL, so a mismatch in the guest means the bytes
the guest received are not the bytes in the image - the Policenauts class (the HDD's sector
buffer filled with the CD's CD-DA words) shows up as a BAD row with the file offset.

    # a hard disk image (FAT16 in MBR partition 0), the 12 largest files under \\GAMES
    integ_manifest.py --image MAIN.img --partition 0 --drive C: --under GAMES --largest 12 \
        --max-bytes 4194304 --out C_INTEG.MAN

    # a floppy image (raw .hdm/.img; convert a D88 first with tools/vfdd2raw.py)
    integ_manifest.py --image GAME.hdm --drive A: --all --out A_INTEG.MAN

    # a CD: an ISO, a PCD (tools/cue2pcd.py) or a raw 2352-byte MODE1 data track
    integ_manifest.py --cd GAME.pcd --layout pcd --drive E: --largest 6 --out E_INTEG.MAN

    # list what is there without writing anything
    integ_manifest.py --image MAIN.img --partition 0 --list

The manifest format is documented in integ.s. A file is checked over its first
min(size, --max-bytes) bytes, so a 500 MB game file costs a few seconds, not minutes; the
whole-file CRC in the 'F' row is over exactly those bytes, and INTEG reads exactly that many.

The image is the user's and is never committed; this tool only reads it.
    integ_manifest.py --selftest      # round-trips a synthetic volume (mtools if present)
"""
from __future__ import annotations

import argparse
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fatimg import Entry, Fat, Iso, locate_volume  # noqa: E402

BLK = 512


# ---------------------------------------------------------------------------------------------
# the manifest
# ---------------------------------------------------------------------------------------------
def block_crcs(data: bytes):
    return [zlib.crc32(data[i:i + BLK]) & 0xFFFFFFFF for i in range(0, len(data), BLK)]


def manifest_text(files, drive: str) -> str:
    """files: iterable of (dos_path_without_drive, bytes_checked)."""
    out = ["INTEG1 512"]
    for path, data in files:
        out.append(f"F {len(data):08X} {zlib.crc32(data) & 0xFFFFFFFF:08X} {drive}\\{path}")
        crcs = block_crcs(data)
        for i in range(0, len(crcs), 8):
            out.append("B " + " ".join(f"{c:08X}" for c in crcs[i:i + 8]))
    return "\r\n".join(out) + "\r\n"


def select(entries, args):
    ents = [e for e in entries if e.size >= args.min_bytes and e.path.isascii()]
    if args.under:
        u = args.under.upper().strip('\\/').replace('/', '\\') + '\\'
        ents = [e for e in ents if e.path.upper().startswith(u)]
    if args.file:
        want = {w.upper().replace('/', '\\').lstrip('\\') for w in args.file}
        ents = [e for e in ents if e.path.upper() in want]
        missing = want - {e.path.upper() for e in ents}
        if missing:
            raise SystemExit(f"not on the volume: {sorted(missing)}")
    elif args.largest:
        ents = sorted(ents, key=lambda e: -e.size)[:args.largest]
    elif not args.all:
        raise SystemExit("choose --file, --largest N or --all")
    return ents


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group()
    src.add_argument('--image', help='a FAT12/16 hard-disk or floppy image')
    src.add_argument('--cd', help='an ISO 9660 CD image (iso, pcd or raw 2352)')
    ap.add_argument('--layout', choices=('iso', 'pcd', 'raw'), default='iso', help='the --cd image layout')
    ap.add_argument('--partition', type=int, help='MBR partition entry (default: bare volume, else 0)')
    ap.add_argument('--offset', type=lambda s: int(s, 0), help='byte offset of the FAT boot sector')
    ap.add_argument('--skip', type=lambda s: int(s, 0), default=0, help='container header bytes (.hdi/.nhd)')
    ap.add_argument('--drive', default='C:', help='the drive letter DOS will see (default C:)')
    ap.add_argument('--file', action='append', help='a path on the volume (repeatable)')
    ap.add_argument('--largest', type=int, help='the N largest files')
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--under', help='restrict to a directory, e.g. GAMES\\TH05')
    ap.add_argument('--min-bytes', type=int, default=1, help='ignore files smaller than this')
    ap.add_argument('--max-bytes', type=int, default=4 << 20, help='check at most this many bytes per file')
    ap.add_argument('--out', help='write the manifest here (default stdout)')
    ap.add_argument('--list', action='store_true', help='list the files and exit')
    ap.add_argument('--cat', help='write this file of the image to stdout (e.g. a capture the guest left)')
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    if not (a.image or a.cd):
        ap.error('give --image or --cd')
    drive = a.drive.rstrip('\\').upper()
    if not drive.endswith(':'):
        drive += ':'
    with open(a.image or a.cd, 'rb') as f:
        if a.image:
            fs = Fat(f, locate_volume(f, a.partition, a.offset, a.skip))
            entries = list(fs.walk())
            reader = lambda e: fs.read_file(e, a.max_bytes)
        else:
            fs = Iso(f, a.layout)
            entries = list(fs.walk())
            reader = lambda e: fs.read(e.start, min(e.size, a.max_bytes))
        if a.cat:
            sys.stdout.buffer.write(fs.cat(a.cat))
            return 0
        if a.list:
            for e in sorted(entries, key=lambda e: -e.size):
                print(f"{e.size:10d}  {drive}\\{e.path}")
            return 0
        chosen = select(entries, a)
        text = manifest_text(((e.path, reader(e)) for e in chosen), drive)
    if a.out:
        with open(a.out, 'w', newline='') as o:
            o.write(text)
        print(f"{a.out}: {len(chosen)} files, {sum(min(e.size, a.max_bytes) for e in chosen)} bytes checked",
              file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


# ---------------------------------------------------------------------------------------------
def selftest() -> int:
    """Round-trip: a synthetic FAT16 and FAT12 volume built with mtools, read back by Fat."""
    import os
    import shutil
    import subprocess
    import tempfile
    if not shutil.which('mformat'):
        print("SKIP: mtools (mformat/mcopy) not installed")
        return 2
    rc = 0
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, 'src')
        os.makedirs(os.path.join(src, 'SUB'))
        files = {'A.BIN': os.urandom(70000), 'SUB/B.DAT': os.urandom(1234), 'SUB/EMPTY.TXT': b''}
        for p, data in files.items():
            with open(os.path.join(src, p), 'wb') as o:
                o.write(data)
        for name, fmt in (('f16', ['-t', '400', '-h', '4', '-s', '32']), ('f12', ['-f', '1440'])):
            img = os.path.join(d, name + '.img')
            subprocess.run(['mformat', '-C', '-i', img] + fmt + ['::'], check=True, capture_output=True)
            subprocess.run(['mcopy', '-i', img, '-s', os.path.join(src, 'A.BIN'),
                            os.path.join(src, 'SUB'), '::'], check=True, capture_output=True)
            with open(img, 'rb') as f:
                fs = Fat(f, 0)
                found = {e.path.replace('\\', '/'): fs.read_file(e, 1 << 30) for e in fs.walk()}
            for p, data in files.items():
                if found.get(p) != data:
                    print(f"FAIL: {name}: {p} read back differently")
                    rc = 1
            print(f"{name}: {'OK' if rc == 0 else 'FAIL'} ({len(found)} files, {'FAT16' if fs.fat16 else 'FAT12'})")
    text = manifest_text([('X.BIN', bytes(range(256)) * 5 + b'abc')], 'C:')
    lines = text.split('\r\n')
    want = zlib.crc32(bytes(range(256)) * 5 + b'abc') & 0xFFFFFFFF
    if lines[1] != f"F {1283:08X} {want:08X} C:\\X.BIN" or not lines[2].startswith('B ') \
            or len(lines[2].split()) != 1 + 3:
        print("FAIL: manifest shape", lines[:3])
        rc = 1
    return rc


if __name__ == '__main__':
    sys.exit(main())

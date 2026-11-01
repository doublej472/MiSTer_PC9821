#!/usr/bin/env python3
"""fatimg.py - read (and, for a COPY of an image, write) FAT12/16 volumes and ISO 9660 images.

Shared by integ_manifest.py (the INTEG manifest generator) and tools/mister_regress.py (which
puts INTEG.COM and its manifests into a COPY of the user's disk image before it goes to the
MiSTer). Stdlib only, so it also runs on the MiSTer's python3.

WRITES ARE FOR TEST COPIES. `Fat.put` allocates clusters, updates every FAT copy and a directory
entry; it has been round-tripped against mtools on synthetic volumes (`--selftest`) and nothing
else. Never point it at an original image.

    fatimg.py --selftest
"""
from __future__ import annotations

import struct
import sys
from dataclasses import dataclass

# ---------------------------------------------------------------------------------------------
# FAT12/16
# ---------------------------------------------------------------------------------------------
@dataclass
class Entry:
    path: str          # DOS path, '\\'-separated, no drive
    size: int
    start: int         # first cluster / extent
    is_dir: bool


class Fat:
    """A FAT12/FAT16 volume inside a raw image (the PC-98 layouts DOS 3.3-6.2 produce)."""

    def __init__(self, f, base: int):
        self.f = f
        self.base = base
        b = self._read(0, 512)
        self.bps = struct.unpack('<H', b[11:13])[0]
        self.spc = b[13]
        self.resv = struct.unpack('<H', b[14:16])[0]
        self.nfats = b[16]
        self.rootent = struct.unpack('<H', b[17:19])[0]
        tot16 = struct.unpack('<H', b[19:21])[0]
        self.fatsz = struct.unpack('<H', b[22:24])[0]
        tot32 = struct.unpack('<I', b[32:36])[0]
        if self.bps not in (256, 512, 1024, 2048) or self.spc == 0 or self.spc & (self.spc - 1) \
                or self.nfats == 0 or self.fatsz == 0 or self.rootent == 0:
            raise SystemExit(f"no FAT12/16 BPB at byte {base} (bps={self.bps} spc={self.spc} "
                             f"fats={self.nfats} rootent={self.rootent}); pass --offset/--partition")
        total = tot16 or tot32
        self.root_lba = self.resv + self.nfats * self.fatsz
        self.root_secs = (self.rootent * 32 + self.bps - 1) // self.bps
        self.data_lba = self.root_lba + self.root_secs
        self.clsz = self.spc * self.bps
        self.nclusters = (total - self.data_lba) // self.spc
        self.fat16 = self.nclusters >= 4085
        self.fat = self._read(self.resv * self.bps, self.fatsz * self.bps)

    def _read(self, off, n):
        self.f.seek(self.base + off)
        return self.f.read(n)

    def next(self, c: int) -> int:
        if self.fat16:
            return struct.unpack_from('<H', self.fat, c * 2)[0]
        o = c * 3 // 2
        v = struct.unpack_from('<H', self.fat, o)[0]
        return (v >> 4) if c & 1 else (v & 0xFFF)

    def eoc(self, c: int) -> bool:
        return c >= (0xFFF8 if self.fat16 else 0xFF8) or c < 2

    def chain(self, c0: int):
        c, seen = c0, 0
        while not self.eoc(c):
            yield c
            c = self.next(c)
            seen += 1
            if seen > self.nclusters + 2:
                raise SystemExit("FAT chain loops")

    def read_cluster(self, c: int) -> bytes:
        return self._read((self.data_lba + (c - 2) * self.spc) * self.bps, self.clsz)

    def read_file(self, e: Entry, limit: int) -> bytes:
        out = bytearray()
        want = min(e.size, limit)
        for c in self.chain(e.start):
            out += self.read_cluster(c)
            if len(out) >= want:
                break
        if len(out) < want:
            raise SystemExit(f"{e.path}: FAT chain shorter than the directory size")
        return bytes(out[:want])

    @staticmethod
    def _dirents(data: bytes):
        for i in range(0, len(data), 32):
            e = data[i:i + 32]
            if e[0] == 0:
                return
            if e[0] == 0xE5 or e[11] == 0x0F or e[11] & 0x08:
                continue
            yield e

    @staticmethod
    def _name(e: bytes) -> str:
        n = e[:8].decode('ascii', 'replace').rstrip()
        x = e[8:11].decode('ascii', 'replace').rstrip()
        return n + ('.' + x if x else '')

    # ---- lookup by path ----
    @staticmethod
    def _n83(name: str) -> bytes:
        n, _, x = name.upper().partition('.')
        return n.ljust(8)[:8].encode() + x.ljust(3)[:3].encode()

    def find(self, path: str):
        """The Entry for a DOS path (case-insensitive, '\\' or '/'), or None."""
        want = path.upper().replace('/', '\\').strip('\\')
        for e in self.walk():
            if e.path.upper() == want:
                return e
        return None

    def cat(self, path: str, limit: int = 1 << 30) -> bytes:
        e = self.find(path)
        if e is None:
            raise SystemExit(f"not on the volume: {path}")
        return self.read_file(e, limit)

    # ---- writing: FOR TEST COPIES ONLY ----
    def _write(self, off, data):
        self.f.seek(self.base + off)
        self.f.write(data)

    def _set_next(self, c: int, v: int):
        if self.fat16:
            struct.pack_into('<H', self.fat, c * 2, v)
            return
        o = c * 3 // 2
        cur = struct.unpack_from('<H', self.fat, o)[0]
        cur = ((cur & 0x000F) | (v << 4)) if c & 1 else ((cur & 0xF000) | (v & 0xFFF))
        struct.pack_into('<H', self.fat, o, cur & 0xFFFF)

    def _flush_fat(self):
        for k in range(self.nfats):
            self._write((self.resv + k * self.fatsz) * self.bps, bytes(self.fat))

    def _slots(self, dirstart):
        """Byte offsets (in the volume) of every 32-byte slot of a directory."""
        if dirstart is None:
            for i in range(self.rootent):
                yield self.root_lba * self.bps + i * 32
        else:
            for c in self.chain(dirstart):
                base = (self.data_lba + (c - 2) * self.spc) * self.bps
                for i in range(self.clsz // 32):
                    yield base + i * 32

    def put(self, path: str, data: bytes):
        """Create or replace a file. The directory must exist (the root always does)."""
        self.fat = bytearray(self.fat)
        parts = [p for p in path.upper().replace('/', '\\').split('\\') if p]
        dirstart = None
        for p in parts[:-1]:
            want, found = self._n83(p), None
            for off in self._slots(dirstart):
                e = self._read(off, 32)
                if e[0] == 0:
                    break
                if e[0] != 0xE5 and e[:11] == want and e[11] & 0x10:
                    found = struct.unpack('<H', e[26:28])[0]
                    break
            if found is None:
                raise SystemExit(f"no directory {p} on the volume")
            dirstart = found
        name = self._n83(parts[-1])
        target = free = None
        for off in self._slots(dirstart):
            e = self._read(off, 32)
            if e[0] == 0 or e[0] == 0xE5:
                free = free if free is not None else off
                if e[0] == 0:
                    break
                continue
            if e[:11] == name and not e[11] & 0x10:
                target = off
                break
        if target is not None:                       # replace: release the old chain
            old = struct.unpack('<H', self._read(target + 26, 2))[0]
            for c in list(self.chain(old)):
                self._set_next(c, 0)
        else:
            target = free
        if target is None:
            raise SystemExit("directory is full")
        need = (len(data) + self.clsz - 1) // self.clsz
        got = []
        for c in range(2, self.nclusters + 2):
            if len(got) == need:
                break
            if self.next(c) == 0:
                got.append(c)
        if len(got) < need:
            raise SystemExit("volume is full")
        eoc = 0xFFFF if self.fat16 else 0xFFF
        for i, c in enumerate(got):
            self._set_next(c, got[i + 1] if i + 1 < len(got) else eoc)
            chunk = data[i * self.clsz:(i + 1) * self.clsz].ljust(self.clsz, b'\0')
            self._write((self.data_lba + (c - 2) * self.spc) * self.bps, chunk)
        ent = name + bytes([0x20]) + bytes(10) + struct.pack(
            '<HHHI', 12 << 11, ((2026 - 1980) << 9) | (10 << 5) | 10, got[0] if got else 0, len(data))
        self._write(target, ent)
        self._flush_fat()
        self.f.flush()

    def walk(self):
        root = self._read(self.root_lba * self.bps, self.root_secs * self.bps)
        yield from self._walk(root, '')

    def _walk(self, data: bytes, prefix: str):
        for e in self._dirents(data):
            name = self._name(e)
            if name in ('.', '..'):
                continue
            start = struct.unpack('<H', e[26:28])[0]
            size = struct.unpack('<I', e[28:32])[0]
            if e[11] & 0x10:
                sub = b''.join(self.read_cluster(c) for c in self.chain(start))
                yield from self._walk(sub, prefix + name + '\\')
            else:
                yield Entry(prefix + name, size, start, False)


def locate_volume(f, partition, offset, skip):
    """Return the byte offset of the FAT volume's boot sector."""
    if offset is not None:
        return offset
    f.seek(skip)
    s0 = f.read(512)
    f.seek(skip + 512)
    if partition is None:
        # a bare volume (a floppy image) starts with a jump and a plausible BPB
        bps = struct.unpack('<H', s0[11:13])[0]
        if bps in (256, 512, 1024, 2048) and s0[13] and s0[16]:
            return skip
        partition = 0
    if s0[510:512] != b'\x55\xAA':
        raise SystemExit("no MBR (55AA) in sector 0; give --offset BYTES for this image")
    e = s0[446 + 16 * partition: 446 + 16 * partition + 16]
    if not e[4]:
        raise SystemExit(f"MBR partition {partition} is empty")
    return skip + struct.unpack('<I', e[8:12])[0] * 512


# ---------------------------------------------------------------------------------------------
# ISO 9660 (the CD), over an ISO, a PCD or a raw MODE1/2352 data track
# ---------------------------------------------------------------------------------------------
class Iso:
    def __init__(self, f, layout: str):
        self.f, self.layout = f, layout
        if layout == 'pcd':
            f.seek(0)
            if f.read(8) != b'PC98CD01':
                raise SystemExit("not a PCD (missing 'PC98CD01'); use --layout iso or raw")
        pvd = self.sector(16)
        if pvd[1:6] != b'CD001':
            raise SystemExit("no ISO 9660 primary volume descriptor at sector 16")
        self.root = self._rec(pvd[156:190])

    def sector(self, n: int) -> bytes:
        if self.layout == 'iso':
            self.f.seek(n * 2048)
        elif self.layout == 'pcd':
            self.f.seek(2352 + n * 2352 + 16)
        else:                                  # raw 2352, MODE1 user data at +16
            self.f.seek(n * 2352 + 16)
        return self.f.read(2048)

    def read(self, lba: int, size: int) -> bytes:
        out = bytearray()
        n = lba
        while len(out) < size:
            out += self.sector(n)
            n += 1
        return bytes(out[:size])

    @staticmethod
    def _rec(r: bytes):
        return (struct.unpack_from('<I', r, 2)[0], struct.unpack_from('<I', r, 10)[0])

    def walk(self):
        yield from self._walk(self.root, '')

    def _walk(self, d, prefix):
        data = self.read(d[0], d[1])
        i = 0
        while i < len(data):
            ln = data[i]
            if ln == 0:
                i = (i // 2048 + 1) * 2048
                continue
            rec = data[i:i + ln]
            i += ln
            nlen = rec[32]
            raw = rec[33:33 + nlen]
            if raw in (b'\x00', b'\x01'):
                continue
            name = raw.decode('ascii', 'replace').split(';')[0]
            if name.endswith('.'):
                name = name[:-1]
            lba, size = self._rec(rec)
            if rec[25] & 2:
                yield from self._walk((lba, size), prefix + name + '\\')
            else:
                yield Entry(prefix + name, size, lba, False)




def selftest() -> int:
    """Round-trip against mtools: what Fat.put writes, mtools reads (and dosfstools' fsck accepts)."""
    import os
    import shutil
    import subprocess
    import tempfile
    if not shutil.which('mformat'):
        print("SKIP: mtools not installed")
        return 2
    rc = 0
    with tempfile.TemporaryDirectory() as d:
        for name, fmt in (('f16', ['-t', '400', '-h', '4', '-s', '32']), ('f12', ['-f', '1440'])):
            img = os.path.join(d, name + '.img')
            subprocess.run(['mformat', '-C', '-i', img] + fmt + ['::'], check=True, capture_output=True)
            subprocess.run(['mmd', '-i', img, '::SUB'], check=True, capture_output=True)
            blob = bytes((i * 7 + 1) & 0xFF for i in range(100_000))
            with open(img, 'r+b') as f:
                fs = Fat(f, 0)
                fs.put('INTEG.COM', blob[:4032])
                fs.put('BIG.DAT', blob)
                fs.put('SUB\\IN.DAT', blob[:777])
                fs.put('BIG.DAT', blob[:5000])         # replace with a shorter file
                fs.put('EMPTY.TXT', b'')
            for dos, want in (('INTEG.COM', blob[:4032]), ('BIG.DAT', blob[:5000]),
                              ('SUB/IN.DAT', blob[:777]), ('EMPTY.TXT', b'')):
                out = os.path.join(d, 'out.bin')
                subprocess.run(['mcopy', '-n', '-i', img, '::' + dos, out], check=True, capture_output=True)
                if open(out, 'rb').read() != want:
                    print(f"FAIL: {name}: mtools reads {dos} differently")
                    rc = 1
            with open(img, 'rb') as f:
                if Fat(f, 0).cat('big.dat') != blob[:5000]:
                    print(f"FAIL: {name}: Fat.cat differs")
                    rc = 1
            fsck = shutil.which('fsck.fat') or shutil.which('fsck.vfat')
            if fsck:
                r = subprocess.run([fsck, '-n', img], capture_output=True, text=True)
                if r.returncode != 0:
                    print(f"FAIL: {name}: fsck.fat: {r.stdout.strip()[-300:]}")
                    rc = 1
            print(f"{name}: {'OK' if rc == 0 else 'FAIL'}" + (' (fsck.fat clean)' if fsck else ' (no fsck.fat)'))
    return rc


def _cli(argv):
    """fatimg.py IMAGE [--partition N] --put DOSNAME LOCALFILE   (a TEST COPY only; runs on the MiSTer too)"""
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('image')
    ap.add_argument('--partition', type=int)
    ap.add_argument('--skip', type=lambda s: int(s, 0), default=0,
                    help='container header bytes (.hdi/.nhd) before the MBR/volume')
    ap.add_argument('--put', nargs=2, metavar=('DOSNAME', 'LOCALFILE'), required=True)
    a = ap.parse_args(argv)
    with open(a.image, 'r+b') as f:
        fs = Fat(f, locate_volume(f, a.partition, None, a.skip))
        data = open(a.put[1], 'rb').read()
        fs.put(a.put[0], data)
    print(f"put {a.put[0]} ({len(data)} bytes) into {a.image}")
    return 0


if __name__ == '__main__':
    if '--selftest' in sys.argv:
        sys.exit(selftest())
    if len(sys.argv) > 1:
        sys.exit(_cli(sys.argv[1:]))
    print(__doc__)

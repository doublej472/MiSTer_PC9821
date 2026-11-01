#!/usr/bin/env python3
"""Convert a PC-98 hard-disk image (SASI 256-byte or IDE 512-byte, any geometry) into an
image the core's IDE BIOS boots: 512-byte sectors, 8 heads x 17 sectors per track.

WHY. The core is a PC-9821Xe10 with one IDE drive. Its ROM IDE BIOS addresses the disk as 8
heads x 17 sectors (NP2kai cbus/ideio.c turns the ROM IDE BIOS off for any other geometry:
`if (sxsi->surfaces != 8 || sxsi->sectors != 17) {`), and the drive has 512-byte sectors. Most
PC-98 HDI images are SASI disks (256-byte sectors, 4/6/8 heads x 33 sectors) or IDE disks laid
out as 4 heads x 17 sectors; on the core the first stops at the BIOS "insert system disk"
message and the second goes black, because the partition table's CHS addresses and the DOS
boot sector's partition offsets are in the wrong geometry and sector size.

WHAT A PC-98 DISK HOLDS (verified on NEC MS-DOS 5.0/6.2 images; the IPL and boot-sector
roles below are read from their code, which this tool never copies into itself):

  byte 0       the IPL ("IPL1" at +4), 256 bytes of code; 55 AA at +0xFE (and at +0x1FE on
               512-byte media). It asks the BIOS for the sector length (INT 1Bh AH=84h) and
               reads by relative sector number, so the same code runs on both sector sizes.
  sector 1     the partition table: 32-byte entries (FreeBSD sys/diskpc98.h `struct
               pc98_partition`): +0 mid (bit 7 bootable), +1 sid (bit 7 active; 0x81 FAT12,
               0x91/0xA1 FAT16, 0xE1 FAT32), +4 IPL sector/head/cylinder(16), +8 start
               sector/head/cylinder(16), +12 end sector/head/cylinder(16), +16 name. One
               sector of it: 8 entries on 256-byte media, 16 on 512-byte media. NEC FDISK
               starts and ends partitions on cylinder boundaries and writes the end as
               (cylinder, 0, 0) with the cylinder INCLUSIVE.
  byte 1024    the NEC boot-menu loader (the IPL reads 0x1C00 bytes from relative sector
               4 on 256-byte media or 2 on 512-byte media, i.e. byte 1024 either way).
  partition    a FAT boot sector whose BPB carries bytes per LOGICAL sector (1024 on NEC
               DOS hard disks), sectors/track, heads and hidden sectors = the partition's
               start in PHYSICAL sectors; NEC's boot code also keeps, after the DOS 4 BPB,
               +0x3E u32 partition start (physical sectors), +0x42 u16 data-area offset
               (physical sectors), +0x44 u16 physical sector length; it reads IO.SYS by
               relative sector number from those three.

Because the FAT logical sector (1024 bytes) is a multiple of both physical sizes, the
filesystem itself does not change: the partition is copied byte for byte. Only the
addresses around it are rewritten:

  - the target geometry is 8 heads x 17 sectors x 512 bytes (--heads/--spt override);
  - each partition is placed at the first cylinder of the new geometry at or after its old
    byte offset (and after the previous one); its span is rounded up to whole cylinders;
  - the partition table moves to sector 1 of the new sector size, with every start/end/IPL
    CHS rewritten in the new geometry (end written in the source's convention);
  - each FAT boot sector gets the new sectors/track, heads and hidden sectors, and, where
    the NEC fields hold the values described above, the new +0x3E/+0x42/+0x44;
  - the IPL sector gets 55 AA at +0x1FE; the loader bytes from 1024 up to the first
    partition are copied at the same byte offsets.

LIMITS. A filesystem whose logical sector is smaller than 512 bytes cannot sit on 512-byte
media unchanged (reported, not converted). A FAT32 partition (sid 0xE1, or a BPB whose 16-bit
sectors-per-FAT is 0 with a 32-bit count at +0x24) is refused before anything is written: its
BPB and NEC fields sit at other offsets and the verifier reads only FAT12/16 (no FAT32
partition occurs in a survey of 1679 PC-98 HDI/NHD images, all FAT12/16). A non-FAT partition
is relocated unpatched (a warning names it). A disk with no NEC partition table (a game's own IPL that reads fixed
CHS addresses through INT 1Bh) is refused, since nothing says where its data must go.

SAFETY. The output is written to a temporary file in DST's directory, read back and verified,
and only then renamed to DST (os.replace); a failed conversion or verify leaves nothing under
DST's name and an existing DST untouched. DST may not be SRC or a link to it, even with --force.

COPYRIGHT. No NEC code is embedded: the IPL, loader and boot sectors come from the input
image, or (--ipl-from) from a user-supplied donor image with 512-byte sectors.

Usage:
  tools/pc98_hdd_convert.py SRC.hdi DST.hdi        # convert (DST .hdi -> HDI, else raw)
  tools/pc98_hdd_convert.py SRC DST --ipl-from DONOR.hdi
  tools/pc98_hdd_convert.py --info IMG [IMG...]    # header, partition table, BPBs
  tools/pc98_hdd_convert.py --survey IMG [IMG...]  # one classification line per image
  tools/pc98_hdd_convert.py --verify SRC DST       # every file in every FAT partition matches
  tools/pc98_hdd_convert.py --selftest             # synthetic SASI/IDE images round-trip

Inputs: HDI (Anex86/NP2), NHD (T98-NEXT), or a raw image with --src-geometry SS,H,S.
Python 3.9 compatible.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys
import tempfile

HDI_HEADER = 4096
NHD_SIG = b"T98HDDIMAGE.R0\x00"

FAT_SIDS = {0x81: "FAT12", 0x91: "FAT16", 0xA1: "FAT16L", 0xE1: "FAT32"}


class ConvertError(Exception):
    pass


# ----------------------------------------------------------------------------- image I/O

class Image:
    """A disk image's data area plus its geometry."""

    def __init__(self, data, ss, heads, spt, cyls, fmt, hddtype=0):
        self.data = data
        self.ss = ss
        self.heads = heads
        self.spt = spt
        self.cyls = cyls
        self.fmt = fmt
        self.hddtype = hddtype

    @property
    def cyl_bytes(self):
        return self.heads * self.spt * self.ss

    def chs_to_lba(self, c, h, s):
        return (c * self.heads + h) * self.spt + s


def load_image(path, src_geometry=None):
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:15] == NHD_SIG:
        hsize, cyls = struct.unpack_from("<II", raw, 0x110)
        heads, spt, ss = struct.unpack_from("<HHH", raw, 0x118)
        return Image(raw[hsize:], ss, heads, spt, cyls, "nhd")
    if src_geometry is None and len(raw) > HDI_HEADER and raw[:4] == b"\0\0\0\0":
        (_, hddtype, hsize, dsize, ss, spt, heads, cyls) = struct.unpack_from("<8I", raw, 0)
        if hsize >= 32 and ss in (256, 512, 1024) and 0 < heads < 256 and 0 < spt < 256:
            return Image(raw[hsize:hsize + dsize], ss, heads, spt, cyls, "hdi", hddtype)
    if src_geometry is None:
        raise ConvertError("%s: not an HDI/NHD image; give --src-geometry SS,HEADS,SPT for "
                           "a raw image" % path)
    ss, heads, spt = src_geometry
    return Image(raw, ss, heads, spt, len(raw) // (ss * heads * spt), "raw")


def hdi_header(datasize, ss, spt, heads, cyls):
    hdr = struct.pack("<8I", 0, 0, HDI_HEADER, datasize, ss, spt, heads, cyls)
    return hdr + b"\0" * (HDI_HEADER - len(hdr))


# ----------------------------------------------------------------------------- partitions

class Part:
    def __init__(self, idx, raw):
        self.idx = idx
        self.raw = bytes(raw)
        (self.mid, self.sid, _, _, self.ipl_s, self.ipl_h, self.ipl_c,
         self.s_s, self.s_h, self.s_c, self.e_s, self.e_h, self.e_c) = \
            struct.unpack_from("<BBBBBBHBBHBBH", raw, 0)
        self.name = raw[16:32].rstrip(b"\0 ").decode("shift_jis", "replace")

    @property
    def empty(self):
        return self.mid == 0 and self.sid == 0

    def nec_end(self):
        return self.e_h == 0 and self.e_s == 0


def read_ptable(img):
    """Entries of the sector-1 partition table (one sector: 8 or 16 entries)."""
    n = min(img.ss, 512) // 32
    base = img.ss
    out = []
    for i in range(n):
        p = Part(i, img.data[base + 32 * i: base + 32 * i + 32])
        if not p.empty:
            out.append(p)
    return out


def part_extent(img, p):
    """(start byte, end byte exclusive) of a partition in its own geometry."""
    start = img.chs_to_lba(p.s_c, p.s_h, p.s_s) * img.ss
    if p.nec_end():
        end = (p.e_c + 1) * img.cyl_bytes
    else:
        end = (img.chs_to_lba(p.e_c, p.e_h, p.e_s) + 1) * img.ss
    return start, min(end, len(img.data))


class BPB:
    def __init__(self, sec):
        self.ok = False
        if len(sec) < 0x40:
            return
        self.jmp = sec[0]
        (self.bps, self.spc, self.rsv, self.nfat, self.rootent, self.tot16, self.media,
         self.spf, self.spt, self.heads, self.hidden) = struct.unpack_from("<HBHBHHBHHHI", sec, 11)
        self.tot32 = struct.unpack_from("<I", sec, 0x20)[0]
        self.oem = sec[3:11].decode("ascii", "replace")
        self.extsig = sec[0x26]
        self.sec = bytes(sec[:0x48])
        self.nec_start, self.nec_data, self.nec_ss = struct.unpack_from("<IHH", sec, 0x3E)
        jump_ok = sec[0] == 0xE9 or (sec[0] == 0xEB and sec[2] == 0x90)
        shape_ok = (jump_ok and self.bps in (128, 256, 512, 1024, 2048) and self.spc
                    and self.spc & (self.spc - 1) == 0 and self.nfat in (1, 2)
                    and self.rsv >= 1)
        self.ok = bool(shape_ok and self.spf > 0)
        # FAT32 (Microsoft FAT spec, BPB_FATSz16 = 0 and BPB_FATSz32 at +0x24, root entries 0)
        self.spf32 = struct.unpack_from("<I", sec, 0x24)[0]
        self.fat32 = bool(shape_ok and self.spf == 0 and self.spf32 > 0 and self.rootent == 0)

    @property
    def total(self):
        return self.tot16 or self.tot32

    @property
    def jump_target(self):
        """Offset the boot sector's first instruction jumps to (where its code starts)."""
        if self.sec[0] == 0xEB:
            return self.sec[1] + 2
        return (struct.unpack_from("<H", self.sec, 1)[0] + 3) & 0xFFFF

    def data_start(self):
        """Byte offset of the data area from the boot sector."""
        root = (self.rootent * 32 + self.bps - 1) // self.bps
        return (self.rsv + self.nfat * self.spf + root) * self.bps

    def nec_offset(self, ss, start_lba):
        """Where NEC's boot code keeps (u32 partition start, u16 data-area offset, u16
        sector length), all in physical sectors: +0x3E after a DOS 4+ BPB (NEC DOS 5.0/6.2),
        +0x18 in NEC DOS 3.3, whose BPB stops at sectors-per-FAT and whose boot code reads
        the root directory from (+0x18) + 1 + 2 * sectors-per-FAT. None when neither holds
        values consistent with this partition."""
        for off in (0x3E, 0x18):
            st, data, pss = struct.unpack_from("<IHH", self.sec, off)
            if pss == ss and st == start_lba and data * ss == self.data_start():
                return off
        return None

    def nec_fields(self, ss, start_lba):
        return self.nec_offset(ss, start_lba) is not None

    def fs_bytes(self):
        return self.total * self.bps


# ----------------------------------------------------------------------------- FAT reader

class Fat:
    """A minimal FAT12/16 reader over a partition's bytes (for --verify and the selftest)."""

    def __init__(self, buf):
        self.buf = buf
        b = BPB(buf[:512])
        if not b.ok:
            raise ConvertError("no FAT BPB")
        self.b = b
        self.fat_off = b.rsv * b.bps
        self.root_off = (b.rsv + b.nfat * b.spf) * b.bps
        self.data_off = b.data_start()
        self.clus = b.spc * b.bps
        nclus = (b.total * b.bps - self.data_off) // self.clus
        self.fat16 = nclus >= 4085

    def next(self, c):
        if self.fat16:
            v = struct.unpack_from("<H", self.buf, self.fat_off + 2 * c)[0]
            return None if v >= 0xFFF8 else v
        o = self.fat_off + c * 3 // 2
        v = struct.unpack_from("<H", self.buf, o)[0]
        v = v >> 4 if c & 1 else v & 0xFFF
        return None if v >= 0xFF8 else v

    def chain(self, c):
        out, seen = bytearray(), set()
        while c is not None and 2 <= c and c not in seen:
            seen.add(c)
            o = self.data_off + (c - 2) * self.clus
            out += self.buf[o:o + self.clus]
            c = self.next(c)
        return bytes(out)

    def entries(self, raw):
        for i in range(0, len(raw) - 31, 32):
            e = raw[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5 or e[11] == 0x0F or e[11] & 0x08:
                continue
            name = e[0:8].rstrip(b" ")
            ext = e[8:11].rstrip(b" ")
            if name in (b".", b".."):
                continue
            if name[:1] == b"\x05":
                name = b"\xe5" + name[1:]
            full = (name + (b"." + ext if ext else b"")).decode("shift_jis", "replace")
            yield full, e[11], struct.unpack_from("<H", e, 26)[0], struct.unpack_from("<I", e, 28)[0]

    def walk(self):
        """{path: sha1 or '<dir>'} for every file and directory."""
        out = {}
        root = self.buf[self.root_off:self.data_off]
        stack = [("", root)]
        depth = 0
        while stack and depth < 100000:
            depth += 1
            prefix, raw = stack.pop()
            for name, attr, clus, size in self.entries(raw):
                path = prefix + "/" + name
                if attr & 0x10:
                    out[path] = "<dir>"
                    if clus >= 2:
                        stack.append((path, self.chain(clus)))
                else:
                    data = self.chain(clus)[:size] if clus >= 2 else b""
                    out[path] = hashlib.sha1(data).hexdigest() + ":%d" % size
        return out


# ----------------------------------------------------------------------------- analysis

def classify(img):
    """(class, notes) for one image, without converting it."""
    notes = []
    d = img.data
    if len(d) < 2 * img.ss:
        return "empty", notes
    if img.ss == 512 and img.heads == 8 and img.spt == 17:
        geo = "native"
    else:
        geo = "convert"
    ipl = d[4:8] == b"IPL1"
    parts = read_ptable(img)
    if not parts:
        return ("no-ptable" + ("" if ipl else "-noipl")), notes
    kinds = []
    for p in parts:
        start, end = part_extent(img, p)
        if start < img.ss * 2 or start >= len(d):
            kinds.append("badchs")
            continue
        b = BPB(d[start:start + 512])
        if b.fat32 or is_fat32_sid(p.sid):
            kinds.append("fat32")
            continue
        if not b.ok:
            kinds.append("nonfat(sid=%02x)" % p.sid)
            continue
        if b.bps < 512:
            kinds.append("bps%d" % b.bps)
        else:
            off = b.nec_offset(img.ss, start // img.ss)
            if off == 0x18:
                kinds.append("fat+nec33")
            elif b.hidden * img.ss != start:
                kinds.append("hidden-mismatch")
            else:
                kinds.append("fat" + ("+nec" if off else "") + ":" + b.oem.strip())
    notes.append(",".join(kinds))
    if any(k.startswith(("badchs", "bps", "fat32")) for k in kinds):
        return geo + "-blocked", notes
    if not any(k.startswith("fat") for k in kinds):
        return geo + "-nonfat", notes
    return geo + ("-ok" if ipl else "-noipl"), notes


def info(path, args):
    img = load_image(path, args.src_geometry)
    print("%s: %s, %d-byte sectors, %d heads x %d sectors x %d cylinders (%d bytes data)%s"
          % (path, img.fmt.upper(), img.ss, img.heads, img.spt, img.cyls, len(img.data),
             ", hddtype %d" % img.hddtype if img.fmt == "hdi" else ""))
    d = img.data
    print("  IPL: %s, 55AA@0x%X: %s" % ("IPL1" if d[4:8] == b"IPL1" else repr(d[:8]),
                                     img.ss - 2, d[img.ss - 2:img.ss] == b"\x55\xaa"))
    for p in read_ptable(img):
        start, end = part_extent(img, p)
        print("  part %d: mid=%02X sid=%02X %-6s start C%d/H%d/S%d end C%d/H%d/S%d ipl C%d/H%d/S%d"
              " bytes 0x%X-0x%X '%s'" % (p.idx, p.mid, p.sid, FAT_SIDS.get(p.sid & 0xF1, "?"),
                                         p.s_c, p.s_h, p.s_s, p.e_c, p.e_h, p.e_s,
                                         p.ipl_c, p.ipl_h, p.ipl_s, start, end, p.name))
        b = BPB(d[start:start + 512])
        if b.fat32:
            print("    FAT32 BPB (sectors per FAT %d): not supported by the converter" % b.spf32)
            continue
        if not b.ok:
            print("    no FAT BPB")
            continue
        print("    BPB '%s' bps=%d spc=%d rsv=%d fats=%d root=%d total=%d spf=%d spt=%d heads=%d"
              " hidden=%d  NEC +3E=%d +42=%d +44=%d (%s)  fs bytes 0x%X"
              % (b.oem, b.bps, b.spc, b.rsv, b.nfat, b.rootent, b.total, b.spf, b.spt,
                 b.heads, b.hidden, b.nec_start, b.nec_data, b.nec_ss,
                 "matches" if b.nec_fields(img.ss, start // img.ss) else "not NEC layout",
                 b.fs_bytes()))
    cls, notes = classify(img)
    print("  class: %s %s" % (cls, " ".join(notes)))


# ----------------------------------------------------------------------------- conversion

def is_fat32_sid(sid):
    """0xE1 (bit 7 = active) is FAT32 in the PC-98 system id (FreeBSD diskpc98.h list above)."""
    return sid & 0x7F == 0x61


def chs_of(lba, heads, spt):
    c, r = divmod(lba, heads * spt)
    h, s = divmod(r, spt)
    return c, h, s


def convert(img, heads=8, spt=17, donor=None, log=print):
    ss = 512
    cylb = heads * spt * ss
    if img.ss not in (256, 512):
        raise ConvertError("source sector length %d is not 256 or 512" % img.ss)
    if img.data[4:8] != b"IPL1" and donor is None:
        log("warning: no NEC IPL signature at byte 4; the IPL is copied as-is")
    parts = read_ptable(img)
    if not parts:
        raise ConvertError("no partition table in sector 1: nothing says where the data goes")
    plan = []
    for p in sorted(parts, key=lambda q: part_extent(img, q)[0]):
        start, end = part_extent(img, p)
        if start < 2 * img.ss or start >= len(img.data) or end <= start:
            raise ConvertError("partition %d: start/end CHS outside the image" % p.idx)
        b = BPB(img.data[start:start + 512])
        if b.fat32 or is_fat32_sid(p.sid):
            raise ConvertError("partition %d (sid %02X, '%s') is FAT32: not supported (its BPB "
                               "and NEC fields are not patched and its files cannot be "
                               "verified); nothing was written" % (p.idx, p.sid, p.name))
        if b.ok:
            if b.bps < ss or b.bps % ss:
                raise ConvertError("partition %d: FAT logical sector %d bytes cannot sit on "
                                   "512-byte media unchanged" % (p.idx, b.bps))
            if b.fs_bytes() > end - start:
                log("warning: partition %d: FAT claims 0x%X bytes, partition holds 0x%X"
                    % (p.idx, b.fs_bytes(), end - start))
        else:
            log("warning: partition %d (sid %02X, '%s') has no FAT BPB: relocated byte for byte, "
                "its contents are not patched" % (p.idx, p.sid, p.name))
        plan.append((p, start, end, b))

    out_parts = []
    next_cyl = 1
    for p, start, end, b in plan:
        ncyl0 = max(next_cyl, -(-start // cylb))
        span = -(-(end - start) // cylb)
        out_parts.append((p, start, end, b, ncyl0, span))
        next_cyl = ncyl0 + span
    total_cyls = next_cyl
    out = bytearray(total_cyls * cylb)

    # System area: IPL sector, partition table, loader bytes.
    first_src = plan[0][1]
    if donor is not None:
        if donor.ss != 512:
            raise ConvertError("--ipl-from: the donor must have 512-byte sectors")
        dfirst = min([part_extent(donor, q)[0] for q in read_ptable(donor)] or [len(donor.data)])
        out[0:512] = donor.data[0:512]
        lim = min(dfirst, out_parts[0][4] * cylb)
        out[1024:lim] = donor.data[1024:lim]
    else:
        out[0:img.ss] = img.data[0:img.ss]
        out[1024:first_src] = img.data[1024:first_src]
    out[510:512] = b"\x55\xaa"
    out[512:1024] = b"\0" * 512

    for slot, (p, start, end, b, ncyl0, span) in enumerate(out_parts):
        nstart = ncyl0 * cylb
        out[nstart:nstart + (end - start)] = img.data[start:end]
        nlba = nstart // ss
        e = bytearray(p.raw)
        sc, sh, s_s = chs_of(nlba, heads, spt)
        if p.nec_end():
            ec, eh, es = ncyl0 + span - 1, 0, 0
        else:
            ec, eh, es = chs_of(nlba + span * heads * spt - 1, heads, spt)
        ipl_old = img.chs_to_lba(p.ipl_c, p.ipl_h, p.ipl_s) * img.ss
        if (p.ipl_c, p.ipl_h, p.ipl_s) == (p.s_c, p.s_h, p.s_s):
            ic, ih, is_ = sc, sh, s_s
        elif start <= ipl_old < end:
            ic, ih, is_ = chs_of((nstart + ipl_old - start) // ss, heads, spt)
        else:
            ic, ih, is_ = p.ipl_c, p.ipl_h, p.ipl_s
            log("warning: partition %d: IPL address outside the partition, left as-is" % p.idx)
        struct.pack_into("<BBHBBHBBH", e, 4, is_, ih, ic, s_s, sh, sc, es, eh, ec)
        out[512 + 32 * slot:512 + 32 * slot + 32] = e
        if b.ok:
            bs = bytearray(out[nstart:nstart + 512])
            old_lba = start // img.ss
            nec = b.nec_offset(img.ss, old_lba)
            if nec != 0x18 and b.jump_target >= 0x1E:
                # a DOS 3.3-style BPB ends before +0x18; only a longer one has geometry
                if b.hidden != old_lba:
                    log("warning: partition %d: BPB hidden sectors %d != partition start %d; "
                        "rewritten to the new start" % (p.idx, b.hidden, old_lba))
                struct.pack_into("<HH", bs, 0x18, spt, heads)
                if b.jump_target > 0x1E or b.extsig == 0x29:
                    struct.pack_into("<I", bs, 0x1C, nlba)
                else:
                    struct.pack_into("<H", bs, 0x1C, nlba)
            if nec is not None:
                struct.pack_into("<IHH", bs, nec, nlba, b.data_start() // ss, ss)
            else:
                log("note: partition %d: boot sector has no NEC +3E/+42/+44 fields (OEM '%s'); "
                    "only the BPB is rewritten" % (p.idx, b.oem))
            out[nstart:nstart + 512] = bs
        log("partition %d '%s': bytes 0x%X-0x%X -> cylinder %d..%d (LBA %d), %s"
            % (p.idx, p.name, start, end, ncyl0, ncyl0 + span - 1, nlba,
               ("FAT bps %d" % b.bps) if b.ok else "not FAT"))
    return Image(bytes(out), ss, heads, spt, total_cyls, "hdi")


def write_image(img, path, fmt):
    with open(path, "wb") as f:
        if fmt == "hdi":
            f.write(hdi_header(len(img.data), img.ss, img.spt, img.heads, img.cyls))
        f.write(img.data)
        f.flush()
        os.fsync(f.fileno())


def same_file(a, b):
    try:
        return os.path.samefile(a, b)
    except OSError:
        return False


def write_verified(src, dst_img, dst_path, fmt, log=print):
    """Write dst_img to a temporary file beside dst_path, read it back, verify it against
    src, and only then rename it to dst_path. True on success; on any failure nothing is left
    under dst_path's name (an existing dst_path is untouched) and the temporary is removed."""
    d = os.path.dirname(os.path.abspath(dst_path))
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(dst_path) + ".", suffix=".part",
                               dir=d)
    os.close(fd)
    umask = os.umask(0)
    os.umask(umask)
    try:
        os.chmod(tmp, 0o666 & ~umask)     # mkstemp makes 0600; give DST the usual mode
        write_image(dst_img, tmp, fmt)
        back = load_image(tmp, None if fmt == "hdi" else (512, dst_img.heads, dst_img.spt))
        if back.data != dst_img.data:
            log("ERROR: the temporary output does not read back as written")
            return False
        if not verify(src, back, log=log):
            return False
        os.replace(tmp, dst_path)
        tmp = None
        return True
    finally:
        if tmp is not None and os.path.exists(tmp):
            os.unlink(tmp)


def fat_listing(img):
    """{(partition index, path): digest} over every FAT partition."""
    out = {}
    for p in read_ptable(img):
        start, end = part_extent(img, p)
        b = BPB(img.data[start:start + 512])
        if not b.ok:
            continue
        for k, v in Fat(img.data[start:end]).walk().items():
            out[(p.name, k)] = v
    return out


def verify(src, dst, log=print):
    a, b = fat_listing(src), fat_listing(dst)
    bad = [k for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]
    for k in bad[:20]:
        log("MISMATCH %s:%s %s != %s" % (k[0], k[1], a.get(k), b.get(k)))
    log("verify: %d entries, %d mismatches" % (len(a), len(bad)))
    return not bad and len(a) > 0


# ----------------------------------------------------------------------------- selftest

def build_fat(bps, spc, files, total, rootent=64, media=0xF8):
    """A FAT12 filesystem image (bytes) holding `files` {name: bytes} in its root."""
    rsv, nfat = 1, 2
    nclus_guess = total // spc
    spf = -(-((nclus_guess + 2) * 3 // 2 + 1) // bps)
    buf = bytearray(total * bps)
    bs = bytearray(512)
    bs[0:3] = b"\xEB\x45\x90"
    bs[3:11] = b"SELFTEST"
    struct.pack_into("<HBHBHHBHHHI", bs, 11, bps, spc, rsv, nfat, rootent, total, media, spf,
                     17, 4, 0)
    bs[0x26] = 0x29
    bs[0x36:0x3E] = b"FAT12   "
    bs[0x1FE:0x200] = b"\x55\xaa"
    buf[0:512] = bs
    fat = bytearray(spf * bps)
    fat[0:3] = bytes([media, 0xFF, 0xFF])
    root_off = (rsv + nfat * spf) * bps
    data_off = root_off + -(-(rootent * 32) // bps) * bps
    clus = spc * bps
    nextc = 2
    for i, (name, data) in enumerate(sorted(files.items())):
        n = max(1, -(-len(data) // clus))
        first = nextc if data else 0
        for k in range(n if data else 0):
            c = nextc + k
            v = 0xFFF if k == n - 1 else c + 1
            o = c * 3 // 2
            cur = struct.unpack_from("<H", fat, o)[0]
            cur = (cur & 0x000F) | (v << 4) if c & 1 else (cur & 0xF000) | v
            struct.pack_into("<H", fat, o, cur)
        off = data_off + (nextc - 2) * clus
        buf[off:off + len(data)] = data
        if data:
            nextc += n
        stem, _, ext = name.partition(".")
        ent = stem.ljust(8).encode() + ext.ljust(3).encode() + bytes([0x20]) + b"\0" * 14
        ent += struct.pack("<HI", first, len(data))
        buf[root_off + 32 * i:root_off + 32 * i + 32] = ent
    for k in range(nfat):
        buf[(rsv + k * spf) * bps:(rsv + (k + 1) * spf) * bps] = fat
    return bytes(buf), (data_off)


def build_disk(ss, heads, spt, cyls, parts_spec):
    """A synthetic PC-98 disk: fake IPL, partition table, NEC-style boot fields."""
    cylb = heads * spt * ss
    d = bytearray(cyls * cylb)
    d[0:4] = b"\xEB\x0A\x90\x90"
    d[4:8] = b"IPL1"
    d[ss - 2:ss] = b"\x55\xaa"
    d[1024:1024 + 16] = b"LOADER-SENTINEL!"
    for i, spec in enumerate(parts_spec):
        c0, c1, fsbytes, name, nec_end = spec[:5]
        dos33 = len(spec) > 5 and spec[5]
        start = c0 * cylb
        e = struct.pack("<BBBBBBHBBH", 0xA1, 0x81, 0, 0, 0, 0, c0, 0, 0, c0)
        if nec_end:
            e += struct.pack("<BBH", 0, 0, c1)
        else:
            e += struct.pack("<BBH", spt - 1, heads - 1, c1)
        e += name.ljust(16).encode()
        d[ss + 32 * i:ss + 32 * i + 32] = e
        d[start:start + len(fsbytes)] = fsbytes
        lba = start // ss
        b = BPB(d[start:start + 512])
        if dos33:
            # NEC DOS 3.3 layout: BPB ends at sectors-per-FAT, NEC trio at +0x18
            d[start:start + 3] = b"\xEB\x1F\x90"
            d[start + 0x18:start + 0x48] = b"\0" * 0x30
            struct.pack_into("<IHH", d, start + 0x18, lba, b.data_start() // ss, ss)
        else:
            struct.pack_into("<HHI", d, start + 0x18, spt, heads, lba)
            struct.pack_into("<IHH", d, start + 0x3E, lba, b.data_start() // ss, ss)
    return Image(bytes(d), ss, heads, spt, cyls, "hdi")


def selftest():
    fails = []
    quiet = lambda *a: None

    def check(cond, msg):
        if not cond:
            fails.append(msg)

    payload = {"IO.SYS": bytes(range(256)) * 37, "MSDOS.SYS": b"kernel" * 900,
               "GAME.EXE": os.urandom(70000), "EMPTY.TXT": b""}
    cases = [
        ("SASI 4h/33s", 256, 4, 33, 40, [(1, 30, "DOS", True), (31, 39, "DATA", True)]),
        ("SASI 8h/33s", 256, 8, 33, 30, [(1, 29, "DOS", True)]),
        ("SASI 6h/33s", 256, 6, 33, 30, [(1, 29, "DOS", False)]),
        ("IDE 4h/17s", 512, 4, 17, 60, [(1, 59, "DOS", True)]),
        ("IDE 8h/17s", 512, 8, 17, 30, [(1, 29, "DOS", True)]),
        ("SASI DOS3.3", 256, 4, 33, 40, [(1, 39, "DOS33", True, True)]),
        ("IDE DOS3.3", 512, 4, 17, 60, [(1, 59, "DOS33", True, True)]),
    ]
    for label, ss, h, s, cyls, specs in cases:
        built = []
        for c0, c1, name, nec_end, *dos33 in specs:
            nbytes = (c1 - c0 + 1) * h * s * ss
            fs, _ = build_fat(1024, 4, payload, nbytes // 1024 - 3)
            built.append((c0, c1, fs, name, nec_end, bool(dos33)))
        src = build_disk(ss, h, s, cyls, built)
        dst = convert(src, log=quiet)
        check(dst.ss == 512 and dst.heads == 8 and dst.spt == 17, label + ": geometry")
        check(dst.data[4:8] == b"IPL1" and dst.data[510:512] == b"\x55\xaa", label + ": IPL")
        check(dst.data[1024:1040] == b"LOADER-SENTINEL!", label + ": loader bytes")
        check(verify(src, dst, log=quiet), label + ": files differ after conversion")
        dparts = read_ptable(dst)
        check(len(dparts) == len(specs), label + ": partition count")
        prev_end = 0
        for p in dparts:
            start, end = part_extent(dst, p)
            check(start % dst.cyl_bytes == 0, label + ": partition not cylinder-aligned")
            check(start >= prev_end, label + ": partitions overlap")
            prev_end = end
            b = BPB(dst.data[start:start + 512])
            off = b.nec_offset(512, start // 512)
            if p.name.startswith("DOS33"):
                check(off == 0x18, label + ": NEC 3.3 +18/+1C/+1E")
            else:
                check(b.ok and b.spt == 17 and b.heads == 8, label + ": BPB geometry")
                check(b.hidden == start // 512, label + ": BPB hidden sectors")
                check(off == 0x3E, label + ": NEC +3E/+42/+44")
            check(classify(dst)[0] == "native-ok", label + ": converted image classifies native")
        # idempotent: converting the output again changes nothing
        again = convert(dst, log=quiet)
        check(again.data == dst.data, label + ": second conversion is not a no-op")
        # serialization round trip
        with tempfile.TemporaryDirectory() as td:
            p = os.path.join(td, "x.hdi")
            write_image(dst, p, "hdi")
            back = load_image(p)
            check(back.data == dst.data and back.cyls == dst.cyls, label + ": HDI round trip")
    # planted defects the checks must catch
    fs, _ = build_fat(1024, 4, payload, 100)
    src = build_disk(256, 4, 33, 40, [(1, 30, fs, "DOS", True)])
    dst = bytearray(convert(src, log=quiet).data)
    start = part_extent(Image(bytes(dst), 512, 8, 17, 0, "raw"), read_ptable(
        Image(bytes(dst), 512, 8, 17, 0, "raw"))[0])[0]
    dst[start + 0x400 * 50] ^= 0xFF          # inside a file's data
    check(not verify(src, Image(bytes(dst), 512, 8, 17, 0, "hdi"), log=quiet),
          "planted data corruption not detected")
    small, _ = build_fat(256, 4, payload, 1500)
    try:
        convert(build_disk(256, 4, 33, 40, [(1, 30, small, "OLD", True)]), log=quiet)
        fails.append("bps-256 filesystem was not refused")
    except ConvertError:
        pass
    try:
        convert(Image(b"\0" * 65536, 256, 4, 33, 2, "raw"), log=quiet)
        fails.append("image without a partition table was not refused")
    except ConvertError:
        pass
    fails += selftest_fat32(payload, quiet) + selftest_safe_output(payload)
    for f in fails:
        print("FAIL: " + f)
    print("selftest: %s (%d layouts, FAT32 refusal, safe output)"
          % ("PASS" if not fails else "FAIL", len(cases)))
    return 1 if fails else 0


def as_fat32(disk, idx):
    """Turn partition idx of a synthetic disk into a FAT32-shaped one: sid 0xE1, BPB
    sectors-per-FAT 0 with a 32-bit count at +0x24, no fixed root directory."""
    d = bytearray(disk.data)
    d[disk.ss + 32 * idx + 1] = 0xE1
    p = read_ptable(Image(bytes(d), disk.ss, disk.heads, disk.spt, disk.cyls, "raw"))[idx]
    start = part_extent(disk, p)[0]
    spf = struct.unpack_from("<H", d, start + 0x16)[0]
    struct.pack_into("<H", d, start + 0x11, 0)          # BPB_RootEntCnt
    struct.pack_into("<H", d, start + 0x16, 0)          # BPB_FATSz16
    struct.pack_into("<I", d, start + 0x24, spf)        # BPB_FATSz32
    return Image(bytes(d), disk.ss, disk.heads, disk.spt, disk.cyls, disk.fmt)


def selftest_fat32(payload, quiet):
    """FAT32 is refused before anything is written, alone or beside a FAT16 partition, and
    detected from the BPB alone (sid left at 0x81) as well as from the sid."""
    fails = []
    fs, _ = build_fat(1024, 4, payload, 100)
    cases = {
        "FAT32-only": (build_disk(256, 4, 33, 40, [(1, 30, fs, "W98", True)]), [0]),
        "FAT16 + FAT32": (build_disk(256, 4, 33, 40, [(1, 20, fs, "DOS", True),
                                                      (21, 39, fs, "W98", True)]), [1]),
    }
    for label, (disk, idx) in cases.items():
        f32 = disk
        for i in idx:
            f32 = as_fat32(f32, i)
        try:
            convert(f32, log=quiet)
            fails.append(label + ": FAT32 partition was not refused")
        except ConvertError as e:
            if "FAT32" not in str(e):
                fails.append(label + ": refused for the wrong reason: %s" % e)
        if not classify(f32)[0].endswith("-blocked"):
            fails.append(label + ": FAT32 does not classify as blocked")
    # BPB shape alone (sid still 0x81)
    d = bytearray(as_fat32(cases["FAT32-only"][0], 0).data)
    d[256 + 1] = 0x81
    b_only = Image(bytes(d), 256, 4, 33, 40, "hdi")
    if not BPB(b_only.data[part_extent(b_only, read_ptable(b_only)[0])[0]:][:512]).fat32:
        fails.append("FAT32 BPB (spf16 0, spf32 > 0) not detected")
    try:
        convert(b_only, log=quiet)
        fails.append("FAT32 BPB under a FAT12/16 sid was not refused")
    except ConvertError:
        pass
    # the CLI writes nothing for a refused image
    with tempfile.TemporaryDirectory() as td:
        sp, dp = os.path.join(td, "f32.hdi"), os.path.join(td, "out.hdi")
        write_image(as_fat32(cases["FAT16 + FAT32"][0], 1), sp, "hdi")
        if main_quiet([sp, dp]) == 0 or os.listdir(td) != ["f32.hdi"]:
            fails.append("CLI: a FAT16 + FAT32 image left output %s" % sorted(os.listdir(td)))
    return fails


def main_quiet(argv):
    import contextlib
    import io
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return main(argv)


def selftest_safe_output(payload):
    """The CLI never destroys its input: DST == SRC (also via a link, also with --force) is
    refused with SRC intact; a failed verify leaves nothing under DST's name and an existing
    DST untouched; a success leaves exactly DST, no temporary."""
    global verify
    fails = []
    fs, _ = build_fat(1024, 4, payload, 100)
    disk = build_disk(256, 4, 33, 40, [(1, 30, fs, "DOS", True)])
    with tempfile.TemporaryDirectory() as td:
        sp = os.path.join(td, "src.hdi")
        write_image(disk, sp, "hdi")
        with open(sp, "rb") as f:
            orig = f.read()

        def src_intact(label):
            with open(sp, "rb") as f:
                if f.read() != orig:
                    fails.append(label + ": the source was modified")

        for argv, label in (([sp, sp, "--force"], "DST == SRC --force"),
                            ([sp, os.path.join(td, ".", "src.hdi"), "--force"], "DST == ./SRC")):
            if main_quiet(argv) == 0:
                fails.append(label + ": not refused")
            src_intact(label)
        ln = os.path.join(td, "link.hdi")
        try:
            os.symlink(sp, ln)
            if main_quiet([sp, ln, "--force"]) == 0:
                fails.append("DST symlink to SRC --force: not refused")
            src_intact("DST symlink to SRC")
            os.unlink(ln)
        except (OSError, NotImplementedError):
            pass
        os.link(sp, ln)
        if main_quiet([sp, ln, "--force"]) == 0:
            fails.append("DST hard link to SRC --force: not refused")
        src_intact("DST hard link to SRC")
        os.unlink(ln)
        # a failed verify: nothing new under DST, an existing DST untouched
        real_verify = verify
        verify = lambda a, b, log=print: False
        try:
            dp = os.path.join(td, "new.img")
            if main_quiet([sp, dp]) == 0:
                fails.append("failed verify: exit 0")
            if os.path.exists(dp):
                fails.append("failed verify: output left under DST's name")
            old = os.path.join(td, "old.img")
            with open(old, "wb") as f:
                f.write(b"previous contents")
            main_quiet([sp, old, "--force"])
            with open(old, "rb") as f:
                if f.read() != b"previous contents":
                    fails.append("failed verify: an existing DST was replaced")
        finally:
            verify = real_verify
        if sorted(os.listdir(td)) != ["old.img", "src.hdi"]:
            fails.append("failed verify: temporaries left: %s" % sorted(os.listdir(td)))
        # success: exactly DST appears, it converts, and --force replaces old.img
        for name, extra in (("ok.hdi", []), ("old.img", ["--force"])):
            dp = os.path.join(td, name)
            if main_quiet([sp, dp] + extra) != 0:
                fails.append("%s: conversion failed" % name)
                continue
            back = load_image(dp, None if name.endswith(".hdi") else (512, 8, 17))
            if not verify(disk, back, log=lambda *a: None):
                fails.append("%s: written image does not verify" % name)
        if sorted(os.listdir(td)) != ["ok.hdi", "old.img", "src.hdi"]:
            fails.append("success: unexpected files: %s" % sorted(os.listdir(td)))
        src_intact("all runs")
    return fails


# ----------------------------------------------------------------------------- main

def parse_geometry(s):
    try:
        v = tuple(int(x, 0) for x in s.split(","))
        assert len(v) == 3
        return v
    except Exception:
        raise argparse.ArgumentTypeError("expected SECTORSIZE,HEADS,SECTORS")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", nargs="?")
    ap.add_argument("dst", nargs="?")
    ap.add_argument("--info", nargs="+", metavar="IMG", help="print header, partitions, BPBs")
    ap.add_argument("--survey", nargs="+", metavar="IMG", help="one class line per image")
    ap.add_argument("--verify", nargs=2, metavar=("SRC", "DST"),
                    help="compare every file in every FAT partition")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--ipl-from", metavar="DONOR", help="take the IPL sector and loader "
                    "from this 512-byte-sector image instead of the source")
    ap.add_argument("--format", choices=("hdi", "raw"), help="default: from DST's extension")
    ap.add_argument("--heads", type=int, default=8)
    ap.add_argument("--spt", type=int, default=17)
    ap.add_argument("--src-geometry", type=parse_geometry, metavar="SS,H,S",
                    help="geometry of a raw source image")
    ap.add_argument("--force", action="store_true", help="overwrite DST")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    try:
        if args.info:
            for p in args.info:
                info(p, args)
            return 0
        if args.survey:
            for p in args.survey:
                try:
                    img = load_image(p)
                    cls, notes = classify(img)
                    print("%s\t%d/%d/%d\t%s\t%s" % (cls, img.ss, img.heads, img.spt,
                                                    " ".join(notes), p))
                except Exception as e:
                    print("error\t-\t%s\t%s" % (e, p))
            return 0
        if args.verify:
            ok = verify(load_image(args.verify[0], args.src_geometry), load_image(args.verify[1]))
            return 0 if ok else 1
        if not (args.src and args.dst):
            ap.error("SRC and DST are required (or --info/--survey/--verify/--selftest)")
        for other in [args.src] + ([args.ipl_from] if args.ipl_from else []):
            if same_file(args.dst, other):
                raise ConvertError("%s is the same file as %s: refusing to overwrite an input "
                                   "(even with --force)" % (args.dst, other))
        if os.path.exists(args.dst) and not args.force:
            raise ConvertError("%s exists (--force to overwrite)" % args.dst)
        if os.path.isdir(args.dst):
            raise ConvertError("%s is a directory" % args.dst)
        src = load_image(args.src, args.src_geometry)
        donor = load_image(args.ipl_from) if args.ipl_from else None
        dst = convert(src, args.heads, args.spt, donor)
        fmt = args.format or ("hdi" if args.dst.lower().endswith(".hdi") else "raw")
        if not write_verified(src, dst, args.dst, fmt):
            print("ERROR: the converted filesystems differ from the source; nothing was "
                  "written to %s" % args.dst)
            return 1
        print("wrote %s: %s, 512-byte sectors, %d heads x %d sectors x %d cylinders (verified)"
              % (args.dst, fmt.upper(), dst.heads, dst.spt, dst.cyls))
        return 0
    except ConvertError as e:
        print("error: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

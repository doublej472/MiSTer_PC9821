#!/usr/bin/env python3
"""Convert a PC-98 floppy image the core does not read (Virtual98 FDD, NFD r0/r1, and the FDIs
the core does not mount) into one it does: a raw .hdm when the disk is a plain uniform one of a
size the core knows, else a D88.

WHAT THE CORE READS (docs/user/images.md "Formats"): D88, raw images whose file size picks the
layout, and an FDI whose header is a whole number of 512-byte blocks and whose sectors are 256,
512 or 1024 bytes on a 2DD/2HD/1.44 MB type (pc9821_fdd_media.sv's FDI header section). Every
other FDI, and everything else, is converted here; an FDI the core mounts converts too. The input format is recognised from the file's
contents, never its name. Each reader below follows NP2kai's (the project's software
reference), cited per format:

  VIRTUAL98 FDD (.fdd with a header; NP2kai diskimage/fd/fdd_vfdd.c fdd_set_vfdd, layout
    fdd_head_vfdd.h). verID "VFD1.00" or "VFD1.01" (8 bytes, NUL-terminated), memo[128],
    write_protect (LE16), spdrv (LE16), dmy[80] = 220 bytes; then _VFDD_ID id[160][26], 12
    bytes each: C H R N D DDAM flMF flHD and dataPoint (LE32). Entry [t][i] is slot i of
    physical track t = cylinder * 2 + head (fdd_read_vfdd seeks `trk = (fdc.treg[fdc.us] << 1)
    + fdc.hd` and searches id[trk][i].R); C = 0xFF is no sector. A dataPoint of 0 or
    0xFFFFFFFF means a sector filled with its D byte (`FillMemory(fdc.buf, secsize, ...D)`);
    otherwise 128 << N bytes are read from it. The medium is 2HD when id[0][0].flHD is set,
    1.44 MB (rpm 1) when id[0][17] has flMF == 1 and flHD == 1, else 2DD. The special-read
    data of spdrv is not used by NP2kai's reader either and is not carried.
  FDI (Anex86; NP2kai diskimage/fd/fdd_xdf.c fdd_set_fdi). A 32-byte header of LE32 fields:
    dummy, fddtype, headersize, fddsize, sectorsize, sectors, surfaces, cylinders; NP2kai
    accepts a power-of-two sector size of 128..16384, 1..255 sectors, surfaces == 2,
    1..127 cylinders, and a file of exactly headersize + the data. The data is raw, cylinder
    by cylinder, head 0 then 1, sectors 1..n. fddtype & 0xF0: 0x10/0x70/0xF0 2DD, 0x30/0xB0
    1.44 MB, 0x50/0xD0 2D, 0x90 2HD.
  NFD r0 (T98-Next; NP2kai diskimage/fd/fdd_nfd.c fdd_set_nfd, layout fdd_head_nfd.h).
    "T98FDDIMAGE.R0\\0", comment[0x100], dwHeadSize (LE32 at 0x110), flProtect (0x114), byHead
    (0x115, 1 or 2), then NFD_SECT_ID si[163][26] at 0x120, 16 bytes each: C H R N flMFM
    flDDAM byStatus ST0 ST1 ST2 byPDA. Slot [t][i] is physical track t = C*2+H (the
    reader's "NFDのトラック番号はC/Hの物理スロット"); C = 0xFF is no sector. The data starts at
    dwHeadSize and runs through the table in order, 128 << N bytes per present sector.
  NFD r1. "T98FDDIMAGE.R1\\0", the same first 0x116 bytes, dwTrackHead[164] at 0x120 (the file
    offset of each physical track's info, 0 = no track), dwAddInfo at 0x3B0 (must be 0). At a
    track's offset: wSector, wDiag (LE16, a 16-byte NFD_TRACK_ID1), then wSector 16-byte
    NFD_SECT_ID1 (C H R N flMFM flDDAM byStatus ST0 ST1 ST2 byRetry byPDA) and wDiag 16-byte
    NFD_DIAG_ID1 (Cmd C H R N byStatus ST0 ST1 ST2 byRetry dwDataLen byPDA). The data starts at
    dwHeadSize; tracks follow in the order of their info offsets (the reader sorts them:
    "データ部はトラック情報がヘッダに格納された物理順に並ぶ"); within a track each sector holds
    (byRetry + 1) copies of 128 << N bytes, then each special-read entry (byRetry + 1) copies
    of dwDataLen bytes.
  D88 (also accepted, to make a raw .hdm of a plain D88; NP2kai fdd/d88head.h and
    diskimage/fd/fdd_head_d88.h). A 0x2B0-byte header: name[17], reserved[9], protect (0x1A,
    bit 4), fd_type (0x1B: 0x00 2D, 0x10 2DD, 0x20 2HD), fd_size (LE32 0x1C), trackp[164]
    (LE32 0x20, 0 = no track, index C*2+H); each track a run of a 16-byte _D88SEC (c h r n,
    sectors LE16, mfm_flg 0x00 MFM / 0x40 FM, del_flg 0x10 deleted, stat, 5 reserved,
    rpm_flg at +13, size LE16 at +14) and its data.

WHAT A D88 CAN HOLD. Per sector: its ID (C H R N), MFM/FM, deleted mark, the BIOS result code
(stat, which NP2kai's D88 read returns as the result: fdd_read_d88 `fddlasterror = p->stat;`,
as its NFD read returns byStatus: fdd_read_nfd `fddlasterror = id->byStatus;`), and ONE copy
of the data, in the track's own sector order. One medium per disk. A 1.44 MB disk is written
as fd_type 0x21 with rpm_flg 1 in every sector: NP2kai's rpmcheck accepts a 2HD sector at rpm 1
only when the type's minor nibble is non-zero and the sector's rpm_flg is 1 (fdd_d88.c
rpmcheck). NOT representable, so DROPPED, and a conversion that would drop any of it is
refused unless --lossy is given (the message lists what): an NFD r1 sector's retry copies
(byRetry > 0, weak-bit protection: only the first copy is kept), its special-read entries
(wDiag > 0), the ST0/ST1/ST2 bytes of a sector whose status is not 0 (the status itself is
kept), sectors of a second medium on one disk, and tracks past the D88's 164.

RAW .hdm. Written only when it is lossless: every track 0..T-1 present, each the same sector
count and size, IDs C = cylinder, H = head, R = 1..n, all MFM, none deleted, status 0, and the
size one the core reads as a raw image (docs/user/images.md's list). Otherwise .hdm is refused;
.d88 works. With no OUT the output is SRC's name with .hdm when lossless, else .d88.

SAFETY. The input is only read. The output is written to a temporary name beside it, read back
with this tool's own D88/raw reader and compared sector by sector with the source, and only
then renamed into place. An output that is the input (or a link to it) is refused, even with
--force; an existing output is kept unless --force.

Usage:
  tools/fdconv.py SRC [OUT.hdm | OUT.d88] [--lossy] [--force]
  tools/fdconv.py --info SRC [SRC...]       # the format, medium, layout, what would be dropped
  tools/fdconv.py --batch DIR [--lossy]     # every convertible image under DIR
  tools/fdconv.py --selftest                # synthetic images of each format round-trip

It runs on a computer (Python 3.9 or later); the image it writes is then copied to the SD card.
The batch mode converts a whole folder of images at once, and is safe to re-run.
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import tempfile

D88_TRACKS = 164
D88_HEADER = 0x20 + 4 * D88_TRACKS          # 0x2B0
# the core's D88 extent bound (src/pc9821/storage/pc9821_fdd_media.sv D88_MAX_EXTENT)
D88_MAX_EXTENT = 2_000_000

# the raw sizes the core reads (docs/user/images.md "Raw floppy sizes"): (cylinders, sectors, N, medium, rpm)
RAW_LAYOUTS = [
    (77, 8, 3, "2HD", 0), (78, 8, 3, "2HD", 0), (79, 8, 3, "2HD", 0), (80, 8, 3, "2HD", 0),
    (80, 15, 2, "2HD", 0), (80, 18, 2, "2HD", 1), (80, 21, 2, "2HD", 1),
    (77, 26, 1, "2HD", 0), (77, 9, 3, "2HD", 0),
    (80, 8, 2, "2DD", 0), (80, 9, 2, "2DD", 0),
]

VFDD_IDS = (b"VFD1.00\0", b"VFD1.01\0")
VFDD_TRK, VFDD_SEC = 160, 26
VFDD_HEAD = 220
VFDD_HEADERSIZE = VFDD_HEAD + 12 * VFDD_TRK * VFDD_SEC + 32
NFD_R0 = b"T98FDDIMAGE.R0\0"
NFD_R1 = b"T98FDDIMAGE.R1\0"
NFD_TRK0, NFD_TRK1, NFD_SEC = 163, 164, 26
NFD_HEAD0 = 0x120 + 16 * NFD_TRK0 * NFD_SEC + 0x10
NFD_HEAD1 = 0x3C0


class FormatError(Exception):
    pass


class Sector:
    __slots__ = ("c", "h", "r", "n", "data", "mfm", "ddam", "stat")

    def __init__(self, c, h, r, n, data, mfm=True, ddam=False, stat=0):
        self.c, self.h, self.r, self.n = c, h, r, n
        self.data, self.mfm, self.ddam, self.stat = data, mfm, ddam, stat

    def key(self):
        return (self.c, self.h, self.r, self.n, self.data, self.mfm, self.ddam, self.stat)


class Disk:
    """A floppy as physical tracks (index cylinder * 2 + head) of sectors in track order."""

    def __init__(self, fmt, media, rpm=0, protect=False):
        self.fmt, self.media, self.rpm, self.protect = fmt, media, rpm, protect
        self.tracks: dict[int, list[Sector]] = {}
        self.losses: list[str] = []      # what a D88 cannot hold (refused without --lossy)
        self.notes: list[str] = []

    def add(self, trk, sec):
        self.tracks.setdefault(trk, []).append(sec)

    def nsectors(self):
        return sum(len(v) for v in self.tracks.values())


def secsize(n):
    if n > 8:
        raise FormatError("sector length code N=%d is beyond 8 (32 KB)" % n)
    return 128 << n


def _need(buf, off, size, what):
    if off < 0 or off + size > len(buf):
        raise FormatError("%s: offset 0x%X + %d is past the end of the file (%d bytes)"
                          % (what, off, size, len(buf)))
    return buf[off:off + size]


# ----------------------------------------------------------------------------- readers

def read_vfdd(buf):
    if len(buf) < VFDD_HEADERSIZE or buf[:8] not in VFDD_IDS:
        raise FormatError("not a Virtual98 FDD image")
    wp, spdrv = struct.unpack_from("<hh", buf, 136)
    ids = [struct.unpack_from("<8Bi", buf, VFDD_HEAD + 12 * i)
           for i in range(VFDD_TRK * VFDD_SEC)]
    first, e17 = ids[0], ids[17]
    if first[7]:
        media, rpm = "2HD", 1 if (e17[6] == 1 and e17[7] == 1) else 0
    else:
        media, rpm = "2DD", 0
    disk = Disk("Virtual98 FDD (%s)" % buf[:7].decode("ascii"), media, rpm, wp != 0)
    for i, (c, h, r, n, d, ddam, mf, hd, ptr) in enumerate(ids):
        if c == 0xFF:
            continue
        size = secsize(n)
        if ptr in (0, -1):
            data = bytes([d]) * size
        else:
            data = _need(buf, ptr & 0xFFFFFFFF, size, "Virtual98 sector C%d H%d R%d" % (c, h, r))
        disk.add(i // VFDD_SEC, Sector(c, h, r, n, data, mfm=bool(mf), ddam=bool(ddam)))
        if bool(hd) != (media == "2HD"):
            disk.losses.append("track %d sector R%d is a %s sector on a %s disk (a D88 has "
                               "one medium)" % (i // VFDD_SEC, r, "2HD" if hd else "2DD", media))
    if spdrv:
        disk.notes.append("spdrv=%d: the image's special-read data is not carried (NP2kai's "
                          "reader does not use it either)" % spdrv)
    return disk


def read_fdi(buf):
    if len(buf) < 32:
        raise FormatError("not an FDI image")
    _, fddtype, hsize, _, ss, spt, heads, cyls = struct.unpack_from("<8I", buf, 0)
    if (ss & (ss - 1)) or not (ss & 0x7F80) or not 0 < spt < 256 or heads != 2 \
            or not 0 < cyls < 128:
        raise FormatError("not an FDI image (header fields out of NP2kai's accepted range)")
    if len(buf) != hsize + ss * spt * heads * cyls:
        raise FormatError("not an FDI image (size is not headersize + the data)")
    media, rpm = {0x10: ("2DD", 0), 0x70: ("2DD", 0), 0xF0: ("2DD", 0), 0x30: ("2HD", 1),
                  0xB0: ("2HD", 1), 0x50: ("2D", 0), 0xD0: ("2D", 0),
                  0x90: ("2HD", 0)}.get(fddtype & 0xF0, (None, 0))
    if media is None:
        raise FormatError("FDI fddtype 0x%X is not one NP2kai accepts" % fddtype)
    n = ss.bit_length() - 8
    disk = Disk("FDI", media, rpm)
    off = hsize
    for c in range(cyls):
        for h in range(heads):
            for r in range(1, spt + 1):
                disk.add(c * 2 + h, Sector(c, h, r, n, buf[off:off + ss]))
                off += ss
    return disk


PDA_MEDIA = {0x10: ("2DD", 0), 0x30: ("2HD", 1), 0x90: ("2HD", 0)}


def _pda_media(pda, n, sectors):
    """NP2kai fdd_nfd.c nfd_set_media: the PDA (0x10 2DD, 0x30 1.44 MB, 0x90 2HD) or, for 0,
    a guess from N and the sector count."""
    if pda == 0:
        pda = (0x10 if sectors <= 9 else 0x30 if sectors >= 17 else 0x90) if n == 2 else 0x90
    if pda not in PDA_MEDIA:
        raise FormatError("the first sector's PDA 0x%02X is not 0x10/0x30/0x90, the media "
                          "NP2kai's reader accepts" % pda)
    return PDA_MEDIA[pda]


def _nfd_common(buf, rev):
    hsize = struct.unpack_from("<I", buf, 0x110)[0]
    protect, heads = buf[0x114], buf[0x115]
    if not 1 <= heads <= 2:
        raise FormatError("NFD byHead %d is not 1 or 2" % heads)
    if hsize > len(buf) or hsize < (NFD_HEAD0 if rev == 0 else NFD_HEAD1):
        raise FormatError("NFD dwHeadSize 0x%X is smaller than the r%d header or past the end of "
                          "the file (NP2kai's reader refuses it too)" % (hsize, rev))
    return hsize, protect


def read_nfd0(buf):
    if len(buf) < NFD_HEAD0 or buf[:15] != NFD_R0:
        raise FormatError("not an NFD r0 image")
    hsize, protect = _nfd_common(buf, 0)
    entries = []
    for t in range(NFD_TRK0):
        for i in range(NFD_SEC):
            e = struct.unpack_from("<11B", buf, 0x120 + 16 * (t * NFD_SEC + i))
            if e[0] != 0xFF:
                entries.append((t, e))
    if not entries:
        raise FormatError("NFD r0 holds no sector")
    # The medium: NP2kai takes the first sector's PDA (nfd_set_media(fdd, sec->byPDA, sec->N,
    # NFD_SECMAX)). For a PDA of 0 it passes the table width 26 as the sector count, which
    # guesses 1.44 MB for every 512-byte disk; the track's real count is used here instead.
    t0, e0 = entries[0]
    count0 = sum(1 for t, _ in entries if t == t0)
    media, rpm = _pda_media(e0[10], e0[3], count0)
    if e0[10] == 0:
        notes = ["PDA 0: the medium (%s%s) is guessed from N and the track's %d sectors"
                 % (media, " 1.44 MB" if rpm else "", count0)]
    else:
        notes = []
    disk = Disk("NFD r0", media, rpm, protect != 0)
    disk.notes += notes
    off = hsize
    for t, (c, h, r, n, mfm, ddam, st, st0, st1, st2, pda) in entries:
        size = secsize(n)
        data = _need(buf, off, size, "NFD sector C%d H%d R%d" % (c, h, r))
        off += size
        disk.add(t, Sector(c, h, r, n, data, bool(mfm), bool(ddam), st))
        _nfd_losses(disk, t, r, st, (st0, st1, st2), pda, media, rpm)
    if off != len(buf):
        disk.notes.append("%d bytes after the last sector's data are ignored" % (len(buf) - off))
    return disk


def _nfd_losses(disk, t, r, st, sts, pda, media, rpm):
    if st and any(sts):
        disk.losses.append("track %d R%d: status 0x%02X is kept, its ST0/ST1/ST2 %02X %02X %02X "
                           "are dropped" % ((t, r, st) + tuple(sts)))
    if pda and PDA_MEDIA.get(pda) != (media, rpm):
        disk.losses.append("track %d R%d is a PDA 0x%02X sector on a %s disk (a D88 has one "
                           "medium; NP2kai's reader never matches it either)" % (t, r, pda, media))


def read_nfd1(buf):
    if len(buf) < NFD_HEAD1 or buf[:15] != NFD_R1:
        raise FormatError("not an NFD r1 image")
    hsize, protect = _nfd_common(buf, 1)
    heads = list(struct.unpack_from("<164I", buf, 0x120))
    if struct.unpack_from("<I", buf, 0x3B0)[0]:
        raise FormatError("NFD r1 dwAddInfo is not 0 (an extension NP2kai refuses)")
    order = sorted((pos, t) for t, pos in enumerate(heads) if pos)
    tracks = []
    prev_end = NFD_HEAD1
    for pos, t in order:
        nsec, ndiag = struct.unpack_from("<HH", _need(buf, pos, 16, "NFD r1 track %d" % t))
        end = pos + 16 + 16 * (nsec + ndiag)
        if pos < prev_end or end > hsize:
            raise FormatError("NFD r1 track %d info overlaps or passes dwHeadSize" % t)
        prev_end = end
        secs = [struct.unpack_from("<12B", buf, pos + 16 + 16 * j) for j in range(nsec)]
        diags = [struct.unpack_from("<10BIB", buf, pos + 16 + 16 * (nsec + j))
                 for j in range(ndiag)]
        tracks.append((t, secs, diags))
    first = next(((t, s) for t, s, _ in tracks if s), None)
    if first is None:
        raise FormatError("NFD r1 holds no sector")
    t0, s0 = first
    media, rpm = _pda_media(s0[0][11], s0[0][3], len(s0))
    disk = Disk("NFD r1", media, rpm, protect != 0)
    if s0[0][11] == 0:
        disk.notes.append("PDA 0: the medium (%s%s) is guessed from N and the track's %d sectors"
                          % (media, " 1.44 MB" if rpm else "", len(s0)))
    off = hsize
    for t, secs, diags in tracks:
        for (c, h, r, n, mfm, ddam, st, st0, st1, st2, retry, pda) in secs:
            size = secsize(n)
            data = _need(buf, off, size * (retry + 1), "NFD r1 sector C%d H%d R%d" % (c, h, r))
            off += size * (retry + 1)
            disk.add(t, Sector(c, h, r, n, data[:size], bool(mfm), bool(ddam), st))
            if retry and any(data[k * size:(k + 1) * size] != data[:size]
                             for k in range(1, retry + 1)):
                disk.losses.append("track %d R%d: %d retry copies that differ from the first "
                                   "are dropped (only the first copy is kept)" % (t, r, retry))
            _nfd_losses(disk, t, r, st, (st0, st1, st2), pda, media, rpm)
        for (cmd, c, h, r, n, st, st0, st1, st2, retry, dlen, pda) in diags:
            if not dlen or dlen > 0x8000:
                raise FormatError("NFD r1 track %d: special-read length %d" % (t, dlen))
            _need(buf, off, dlen * (retry + 1), "NFD r1 special read on track %d" % t)
            off += dlen * (retry + 1)
            disk.losses.append("track %d: special-read entry (command 0x%02X, C%d H%d R%d N%d, "
                               "%d bytes) is dropped" % (t, cmd, c, h, r, n, dlen))
    if off != len(buf):
        disk.notes.append("%d bytes after the last data are ignored" % (len(buf) - off))
    return disk


D88_MEDIA = {0x00: "2D", 0x10: "2DD", 0x20: "2HD"}


def read_d88(buf):
    if len(buf) < D88_HEADER:
        raise FormatError("not a D88 image")
    fd_type, fd_size = buf[0x1B], struct.unpack_from("<I", buf, 0x1C)[0]
    if fd_type & 0xF0 not in D88_MEDIA or fd_size != len(buf):
        raise FormatError("not a D88 image (fd_type 0x%02X, fd_size %d, file %d bytes)"
                          % (fd_type, fd_size, len(buf)))
    rpm = 1 if (fd_type & 0x0F) else 0
    disk = Disk("D88", D88_MEDIA[fd_type & 0xF0], rpm, bool(buf[0x1A] & 0x10))
    for t, pos in enumerate(struct.unpack_from("<164I", buf, 0x20)):
        if not pos:
            continue
        count = None
        k = 0
        while count is None or k < count:
            c, h, r, n, nsec, mfm, ddam, st = struct.unpack_from(
                "<4BH3B", _need(buf, pos, 16, "D88 track %d" % t))
            size = struct.unpack_from("<H", buf, pos + 14)[0]
            count = nsec if count is None else count
            data = _need(buf, pos + 16, size, "D88 track %d sector %d" % (t, k))
            disk.add(t, Sector(c, h, r, n, data, not (mfm & 0x40), bool(ddam & 0x10), st))
            if rpm and buf[pos + 13] != 1:
                disk.losses.append("track %d R%d: rpm_flg %d on a 1.44 MB disk"
                                   % (t, r, buf[pos + 13]))
            pos += 16 + size
            k += 1
    return disk


def read_any(buf):
    """Recognise the format from the contents (never the name)."""
    if buf[:15] == NFD_R0:
        return read_nfd0(buf)
    if buf[:15] == NFD_R1:
        return read_nfd1(buf)
    if buf[:8] in VFDD_IDS:
        return read_vfdd(buf)
    try:
        return read_d88(buf)
    except FormatError:
        pass
    try:
        return read_fdi(buf)
    except FormatError:
        pass
    raise FormatError("not a Virtual98 FDD, FDI, NFD r0/r1 or D88 image (%d bytes)%s"
                      % (len(buf), "; a raw image of this size is already read by the core"
                         if raw_layout_of_size(len(buf)) else ""))


def raw_layout_of_size(size):
    for cyls, spt, n, media, rpm in RAW_LAYOUTS:
        if cyls * 2 * spt * (128 << n) == size:
            return cyls, spt, n, media, rpm
    return None


# ----------------------------------------------------------------------------- writers

def raw_blockers(disk):
    """Why DISK cannot be a raw image ([] = it can)."""
    why = []
    if disk.losses:
        why.append("it carries data a raw image cannot hold")
    if not disk.tracks:
        return why + ["it has no tracks"]
    ntrk = max(disk.tracks) + 1
    sec0 = disk.tracks.get(0, [None])[0]
    if sec0 is None:
        return why + ["track 0 is missing"]
    spt, n = len(disk.tracks[0]), sec0.n
    for t in range(ntrk):
        secs = disk.tracks.get(t)
        if not secs:
            why.append("track %d is missing" % t)
            break
        if len(secs) != spt or sorted(s.r for s in secs) != list(range(1, spt + 1)):
            why.append("track %d has sectors %s, not R 1..%d"
                       % (t, sorted(s.r for s in secs), spt))
            break
        bad = [s for s in secs if s.n != n or s.c != t // 2 or s.h != t % 2 or not s.mfm
               or s.ddam or s.stat or len(s.data) != 128 << n]
        if bad:
            s = bad[0]
            why.append("track %d R%d is not a plain sector (C%d H%d N%d %s%s status 0x%02X)"
                       % (t, s.r, s.c, s.h, s.n, "MFM" if s.mfm else "FM",
                          " deleted" if s.ddam else "", s.stat))
            break
    if why:
        return why
    lay = raw_layout_of_size(ntrk * spt * (128 << n))
    if lay is None or lay[1:3] != (spt, n):
        return ["%d cylinders x 2 x %d x %d bytes is not a raw size the core reads"
                % (ntrk // 2, spt, 128 << n)]
    if lay[3:] != (disk.media, disk.rpm):
        return ["the raw size reads as %s%s, the disk is %s%s"
                % (lay[3], " 1.44 MB" if lay[4] else "", disk.media,
                   " 1.44 MB" if disk.rpm else "")]
    return []


def write_raw(disk):
    out = bytearray()
    for t in range(max(disk.tracks) + 1):
        for s in sorted(disk.tracks[t], key=lambda s: s.r):
            out += s.data
    return bytes(out)


def write_d88(disk, name=b""):
    big = [t for t in disk.tracks if t >= D88_TRACKS]
    if big:
        raise FormatError("tracks %s are past the D88's %d" % (big, D88_TRACKS))
    fd_type = {"2D": 0x00, "2DD": 0x10, "2HD": 0x20}[disk.media] | (1 if disk.rpm else 0)
    body = bytearray()
    table = [0] * D88_TRACKS
    for t in sorted(disk.tracks):
        secs = disk.tracks[t]
        table[t] = D88_HEADER + len(body)
        for s in secs:
            hdr = struct.pack("<4BH3B5BH", s.c, s.h, s.r, s.n, len(secs),
                              0x00 if s.mfm else 0x40, 0x10 if s.ddam else 0x00, s.stat,
                              0, 0, 0, 0, 1 if disk.rpm else 0, len(s.data))
            body += hdr + s.data
    head = bytearray(D88_HEADER)
    head[0:17] = (name[:16] + b"\0" * 17)[:17]
    head[0x1A] = 0x10 if disk.protect else 0x00
    head[0x1B] = fd_type
    struct.pack_into("<I", head, 0x1C, D88_HEADER + len(body))
    struct.pack_into("<164I", head, 0x20, *table)
    return bytes(head + body)


def same_sectors(a, b):
    """Every track of A in B, sector for sector (ID, flags, status, data) in the same order."""
    if sorted(a.tracks) != sorted(b.tracks):
        return False
    for t in a.tracks:
        x = a.tracks[t]
        y = b.tracks[t]
        if len(x) != len(y):
            return False
        # a raw image is written in R order; compare as sets of sector keys in that case
        if [s.key() for s in x] != [s.key() for s in y] and \
                sorted(s.key() for s in x) != sorted(s.key() for s in y):
            return False
    return True


def convert_bytes(buf, kind, lossy=False, name=b""):
    """(output bytes, disk, kind) for the image BUF; KIND 'hdm', 'd88' or None (auto)."""
    disk = read_any(buf)
    if kind is None:
        kind = "d88" if raw_blockers(disk) else "hdm"
    if kind == "hdm":
        why = raw_blockers(disk)
        if why:
            raise FormatError("cannot be a raw .hdm: %s; write a .d88 instead" % "; ".join(why))
        out = write_raw(disk)
        back = read_raw(out)
    else:
        if disk.losses and not lossy:
            raise FormatError("a D88 cannot hold everything in this image (--lossy converts "
                              "it anyway and drops it): %s; e.g.\n  %s"
                              % (loss_tally(disk.losses), "\n  ".join(_summary(disk.losses, 3))))
        out = write_d88(disk, name)
        if len(out) > D88_MAX_EXTENT:
            raise FormatError("the D88 would be %d bytes; the core reads a D88 of at most %d"
                              % (len(out), D88_MAX_EXTENT))
        back = read_d88(out)
    if not same_sectors(disk, back):
        raise FormatError("internal error: the output does not read back as the source")
    return out, disk, kind


def read_raw(buf):
    lay = raw_layout_of_size(len(buf))
    if lay is None:
        raise FormatError("not a raw size the core reads")
    cyls, spt, n, media, rpm = lay
    disk = Disk("raw", media, rpm)
    ss = 128 << n
    off = 0
    for c in range(cyls):
        for h in range(2):
            for r in range(1, spt + 1):
                disk.add(c * 2 + h, Sector(c, h, r, n, buf[off:off + ss]))
                off += ss
    return disk


LOSS_KINDS = (("special-read", "special-read (READ DIAGNOSTIC) entries"),
              ("retry", "sectors whose differing retry copies are dropped (first copy kept)"),
              ("ST0/ST1/ST2", "error sectors whose ST0/ST1/ST2 are dropped (status kept)"),
              ("medium", "sectors of a second medium"),
              ("rpm_flg", "sectors with another rpm_flg"))


def loss_tally(losses):
    """'N what; M what' over the loss lines, by kind."""
    out = []
    for word, what in LOSS_KINDS:
        n = sum(1 for x in losses if word in x)
        if n:
            out.append("%d %s" % (n, what))
    return "; ".join(out)


def _summary(lines, limit=12):
    return lines if len(lines) <= limit else lines[:limit] + ["... and %d more"
                                                               % (len(lines) - limit)]


def describe(disk):
    out = ["format %s, medium %s%s%s, %d tracks, %d sectors"
           % (disk.fmt, disk.media, " 1.44 MB (rpm 1)" if disk.rpm else "",
              ", write-protected" if disk.protect else "", len(disk.tracks), disk.nsectors())]
    why = raw_blockers(disk)
    out.append("raw .hdm: " + ("possible (lossless)" if not why else "no - " + "; ".join(why)))
    out += ["note: " + x for x in disk.notes]
    if disk.losses:
        out.append("D88 cannot hold: " + loss_tally(disk.losses))
    out += ["  " + x for x in _summary(disk.losses)]
    return "\n".join(out)


# ----------------------------------------------------------------------------- files

def same_file(a, b):
    try:
        return os.path.samefile(a, b)
    except OSError:
        return False


def write_atomic(data, dst):
    """DST via a temporary name in its folder; renamed into place only after it reads back."""
    d = os.path.dirname(os.path.abspath(dst))
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(dst) + ".", suffix=".part", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        umask = os.umask(0)
        os.umask(umask)
        os.chmod(tmp, 0o666 & ~umask)
        with open(tmp, "rb") as f:
            if f.read() != data:
                raise FormatError("the temporary output does not read back as written")
        os.replace(tmp, dst)
        tmp = None
    finally:
        if tmp is not None and os.path.exists(tmp):
            os.unlink(tmp)


def kind_of(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".d88":
        return "d88"
    if ext == ".hdm":
        return "hdm"
    raise FormatError("%s: the output name must end in .hdm or .d88" % path)


def convert_file(src, dst=None, lossy=False, force=False, log=print):
    with open(src, "rb") as f:
        buf = f.read()
    name = os.path.splitext(os.path.basename(src))[0].encode("latin-1", "replace")
    kind = kind_of(dst) if dst else None
    out, disk, kind = convert_bytes(buf, kind, lossy, name)
    dst = dst or os.path.splitext(src)[0] + "." + kind
    if same_file(src, dst) or os.path.abspath(src) == os.path.abspath(dst):
        raise FormatError("%s is the input file: refusing (even with --force)" % dst)
    if os.path.isdir(dst):
        raise FormatError("%s is a directory" % dst)
    if os.path.exists(dst) and not force:
        raise FormatError("%s exists (--force to overwrite)" % dst)
    write_atomic(out, dst)
    for x in disk.notes:
        log("note: " + x)
    if disk.losses:
        log("dropped (--lossy): " + loss_tally(disk.losses))
    log("wrote %s: %s from %s, %s%s, %d tracks, %d sectors (verified)"
        % (dst, kind.upper(), disk.fmt, disk.media, " 1.44 MB" if disk.rpm else "",
           len(disk.tracks), disk.nsectors()))
    return dst


# ---- batch mode (--batch DIR): a whole folder of floppy images in one run ----
# Every .nfd, .fdi and .fdd under DIR that holds a format this tool converts gets a .hdm (or,
# when a raw image cannot hold it, a .d88) beside it, same stem. A .fdd that is already a raw
# image is left alone (the core reads it). An output that already holds exactly what this tool
# would write is up to date; an existing file of that name with other contents is never
# replaced. The sources are only ever opened for reading.
BATCH_EXTS = (".nfd", ".fdi", ".fdd")


def find_images(root):
    found = []
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if not x.startswith("."))
        found += [os.path.join(d, f) for f in sorted(files)
                  if f.lower().endswith(BATCH_EXTS) and not f.startswith(".")]
    return found


def batch(root, lossy=False, log=print):
    """Convert every image under ROOT; returns the number that failed or were refused."""
    if not os.path.isdir(root):
        log("fdconv: %s is not a directory" % root)
        return 1
    imgs = find_images(root)
    log("fdconv: %d .nfd/.fdi/.fdd file(s) under %s" % (len(imgs), root))
    made = skipped = failed = 0
    claimed = set()
    for src in imgs:
        rel = os.path.relpath(src, root)
        try:
            with open(src, "rb") as f:
                buf = f.read()
            name = os.path.splitext(os.path.basename(src))[0].encode("latin-1", "replace")
            if src.lower().endswith(".fdd") and buf[:8] not in VFDD_IDS:
                continue                        # a raw .fdd: the core reads it as it is
            out, disk, kind = convert_bytes(buf, None, lossy, name)
        except (FormatError, OSError) as e:
            log("%s\n  SKIP: %s" % (rel, str(e).replace("\n", "\n  ")))
            failed += 1
            continue
        dst = os.path.splitext(src)[0] + "." + kind
        key = os.path.normcase(os.path.abspath(dst))
        if key in claimed:
            log("%s\n  SKIP: %s is written from another image of the same name"
                % (rel, os.path.basename(dst)))
            failed += 1
            continue
        claimed.add(key)
        if os.path.exists(dst):
            with open(dst, "rb") as f:
                if f.read() == out:
                    log("%s\n  up to date: %s" % (rel, os.path.basename(dst)))
                    skipped += 1
                    continue
            log("%s\n  SKIP: %s exists with other contents; not replacing it"
                % (rel, os.path.basename(dst)))
            failed += 1
            continue
        try:
            write_atomic(out, dst)
        except (FormatError, OSError) as e:
            log("%s\n  FAILED: %s" % (rel, e))
            failed += 1
            continue
        log("%s\n  %s %s%s -> %s%s" % (rel, disk.fmt, disk.media, " 1.44 MB" if disk.rpm else "",
                                        os.path.basename(dst),
                                        " (dropped: %s)" % loss_tally(disk.losses)
                                        if disk.losses else ""))
        made += 1
    log("fdconv: %d converted, %d already up to date, %d skipped or failed"
        % (made, skipped, failed))
    return failed


# ----------------------------------------------------------------------------- self-test

def _pattern(t, r, size, salt=0):
    return bytes(((t * 37 + r * 11 + i + salt) * 7) & 0xFF for i in range(size))


def make_fdi(cyls, spt, n, fddtype, hsize=4096):
    ss = 128 << n
    data = b"".join(_pattern(c * 2 + h, r, ss) for c in range(cyls) for h in range(2)
                    for r in range(1, spt + 1))
    hdr = struct.pack("<8I", 0, fddtype, hsize, len(data), ss, spt, 2, cyls)
    return hdr + bytes(hsize - 32) + data


def make_vfdd(cyls, spt, n, hd=True, filled=()):
    """filled: (track, R) sectors stored as a D-byte fill (dataPoint 0)."""
    head = bytearray(VFDD_HEADERSIZE)
    head[0:8] = VFDD_IDS[0]
    data = bytearray()
    ss = 128 << n
    for t in range(cyls * 2):
        for i in range(spt):
            r = i + 1
            if (t, r) in filled:
                ptr = 0
            else:
                ptr = VFDD_HEADERSIZE + len(data)
                data += _pattern(t, r, ss)
            struct.pack_into("<8Bi", head, VFDD_HEAD + 12 * (t * VFDD_SEC + i),
                             t // 2, t % 2, r, n, 0xE5, 0, 1, 1 if hd else 0, ptr)
    for t in range(cyls * 2, VFDD_TRK):
        for i in range(VFDD_SEC):
            head[VFDD_HEAD + 12 * (t * VFDD_SEC + i)] = 0xFF
    for t in range(cyls * 2):
        for i in range(spt, VFDD_SEC):
            head[VFDD_HEAD + 12 * (t * VFDD_SEC + i)] = 0xFF
    return bytes(head + data)


def make_nfd0(tracks, pda=0x90):
    """tracks: {t: [(c, h, r, n, mfm, ddam, status)]}; data is _pattern(t, r, size)."""
    head = bytearray(NFD_HEAD0)
    head[0:15] = NFD_R0
    struct.pack_into("<I", head, 0x110, NFD_HEAD0)
    head[0x115] = 2
    for i in range(NFD_TRK0 * NFD_SEC):
        head[0x120 + 16 * i] = 0xFF
    data = bytearray()
    for t in sorted(tracks):
        for i, (c, h, r, n, mfm, ddam, st) in enumerate(tracks[t]):
            struct.pack_into("<11B", head, 0x120 + 16 * (t * NFD_SEC + i),
                             c, h, r, n, mfm, ddam, st, 0x40 if st else 0, 0x20 if st else 0,
                             0, pda)
            data += _pattern(t, r, 128 << n)
    return bytes(head + data)


def make_nfd1(tracks, pda=0x90, retries=None, diags=None):
    """retries {(t, r): copies-1}: the extra copies differ; diags {t: [dlen]}."""
    retries, diags = retries or {}, diags or {}
    info = bytearray()
    heads = [0] * NFD_TRK1
    order = sorted(set(tracks) | set(diags))
    for t in order:
        heads[t] = NFD_HEAD1 + len(info)
        secs, dg = tracks.get(t, []), diags.get(t, [])
        info += struct.pack("<HH12x", len(secs), len(dg))
        for (c, h, r, n, mfm, ddam, st) in secs:
            info += struct.pack("<12B4x", c, h, r, n, mfm, ddam, st, 0, 0, 0,
                                retries.get((t, r), 0), pda)
        for k, dlen in enumerate(dg):
            info += struct.pack("<10BIBx", 0x06, t // 2, t % 2, 1, 3, 0, 0, 0, 0, 0, dlen, pda)
    hsize = NFD_HEAD1 + len(info)
    head = bytearray(NFD_HEAD1)
    head[0:15] = NFD_R1
    struct.pack_into("<I", head, 0x110, hsize)
    head[0x115] = 2
    struct.pack_into("<164I", head, 0x120, *heads)
    data = bytearray()
    for t in order:
        for (c, h, r, n, mfm, ddam, st) in tracks.get(t, []):
            for k in range(retries.get((t, r), 0) + 1):
                data += _pattern(t, r, 128 << n, salt=k)
        for dlen in diags.get(t, []):
            data += bytes(dlen)
    return bytes(head + info + data)


def plain_tracks(cyls, spt, n):
    return {t: [(t // 2, t % 2, r, n, 1, 0, 0) for r in range(1, spt + 1)]
            for t in range(cyls * 2)}


def selftest():
    fails = []

    def check(cond, what):
        if not cond:
            fails.append(what)
            print("SELFTEST FAIL:", what)

    def raw_ref(cyls, spt, n):
        return b"".join(_pattern(c * 2 + h, r, 128 << n) for c in range(cyls)
                        for h in range(2) for r in range(1, spt + 1))

    # 1. every format of a plain 1.25 MB 2HD disk converts to the same raw .hdm, and to a D88
    #    that reads back as the same sectors
    ref = raw_ref(77, 8, 3)
    images = {
        "FDI": make_fdi(77, 8, 3, 0x90),
        "Virtual98": make_vfdd(77, 8, 3),
        "NFD r0": make_nfd0(plain_tracks(77, 8, 3)),
        "NFD r1": make_nfd1(plain_tracks(77, 8, 3)),
    }
    for label, img in images.items():
        try:
            out, disk, kind = convert_bytes(img, None)
            check(kind == "hdm" and out == ref, label + ": auto picks a raw .hdm, equal to the data")
            check(disk.media == "2HD" and disk.rpm == 0, label + ": 2HD medium")
            d88, _, _ = convert_bytes(img, "d88")
            check(d88[0x1B] == 0x20 and struct.unpack_from("<I", d88, 0x1C)[0] == len(d88),
                  label + ": D88 type 0x20 and size")
            check(write_raw(read_d88(d88)) == ref, label + ": the D88 holds the same sectors")
            check(convert_bytes(d88, "hdm")[0] == ref, label + ": D88 -> raw round trip")
        except FormatError as e:
            check(False, "%s: %s" % (label, e))
    # 2. other media: FDI 1.44 MB and 2DD, Virtual98 2DD with a filled sector, NFD 1.44 MB
    out, disk, _ = convert_bytes(make_fdi(80, 18, 2, 0x30, hsize=32), None)
    check(out == raw_ref(80, 18, 2) and disk.rpm == 1, "FDI 1.44 MB with a 32-byte header")
    d88 = convert_bytes(make_fdi(80, 18, 2, 0x30), "d88")[0]
    check(d88[0x1B] == 0x21 and d88[D88_HEADER + 13] == 1,
          "1.44 MB D88: fd_type minor 1, rpm_flg 1 (NP2kai rpmcheck)")
    out, disk, _ = convert_bytes(make_fdi(80, 8, 2, 0x10), None)
    check(out == raw_ref(80, 8, 2) and disk.media == "2DD", "FDI 2DD 640 KB")
    out, disk, _ = convert_bytes(make_vfdd(80, 9, 2, hd=False, filled={(3, 4)}), None)
    exp = bytearray(raw_ref(80, 9, 2))
    exp[(3 * 9 + 3) * 512:(3 * 9 + 4) * 512] = b"\xE5" * 512
    check(disk.media == "2DD" and out == bytes(exp), "Virtual98 2DD 720 KB, a D-filled sector")
    out, disk, _ = convert_bytes(make_nfd0(plain_tracks(80, 18, 2), pda=0x30), None)
    check(disk.rpm == 1 and out == raw_ref(80, 18, 2), "NFD r0 PDA 0x30 is 1.44 MB")
    disk = read_nfd0(make_nfd0(plain_tracks(80, 8, 2), pda=0))
    check(disk.media == "2DD" and disk.notes, "NFD r0 PDA 0, 8 x 512: 2DD (a guess, noted)")
    # an interleaved sector list (the physical order 1, 5, 2, 6, ...) is still a raw image in
    # R order
    tr = plain_tracks(77, 8, 3)
    for t in tr:
        tr[t] = [tr[t][i] for i in (0, 4, 1, 5, 2, 6, 3, 7)]
    check(convert_bytes(make_nfd0(tr), None)[0] == ref, "an interleaved track is written in R order")
    # Virtual98 FM and deleted-data flags reach the D88 (and keep it from being raw)
    v = bytearray(make_vfdd(77, 8, 3))
    v[VFDD_HEAD + 12 * (3 * VFDD_SEC + 1) + 6] = 0          # track 3 R2: flMF 0 (FM)
    v[VFDD_HEAD + 12 * (4 * VFDD_SEC + 2) + 5] = 1          # track 4 R3: DDAM
    out, disk, kind = convert_bytes(bytes(v), None)
    back = read_d88(out)
    check(kind == "d88" and not back.tracks[3][1].mfm and back.tracks[3][0].mfm
          and back.tracks[4][2].ddam and out[D88_HEADER + 6] == 0x00,
          "Virtual98 FM / DDAM flags reach the D88 (mfm_flg 0x40, del_flg 0x10)")
    # 3. a disk only a D88 holds: an FM 128-byte track 0 side 0 (BASIC 2HD), a deleted
    #    sector, an error status and an out-of-order sector list keep their attributes
    tr = plain_tracks(77, 26, 1)
    tr[0] = [(0, 0, r, 0, 0, 0, 0) for r in range(1, 27)]
    tr[5] = [(2, 1, r, 1, 1, 1 if r == 3 else 0, 0xB0 if r == 4 else 0)
             for r in (1, 14, 2, 15, 3, 16, 4, 17, 5, 18, 6, 19, 7, 20, 8, 21, 9, 22, 10, 23,
                       11, 24, 12, 25, 13, 26)]
    nfd = make_nfd0(tr)
    try:
        convert_bytes(nfd, "hdm")
        check(False, "a non-uniform disk must be refused as .hdm")
    except FormatError:
        pass
    try:
        convert_bytes(nfd, None)
        check(False, "an error status with ST bytes must need --lossy")
    except FormatError as e:
        check("ST0/ST1/ST2" in str(e), "the refusal names the dropped ST bytes")
    out, disk, kind = convert_bytes(nfd, None, lossy=True)
    back = read_d88(out)
    check(kind == "d88", "auto picks D88 for a non-uniform disk")
    t0 = back.tracks[0]
    check(all(not s.mfm and s.n == 0 and len(s.data) == 128 for s in t0), "FM 128-byte track 0")
    t5 = back.tracks[5]
    check([s.r for s in t5][:4] == [1, 14, 2, 15], "the sector order is kept")
    check([s.ddam for s in t5 if s.r == 3] == [True] and [s.stat for s in t5 if s.r == 4] ==
          [0xB0], "deleted mark and status are kept")
    check(t5[0].c == 2 and t5[0].h == 1, "a sector ID that differs from its track is kept")
    check(out[0x1B] == 0x20 and out[D88_HEADER + 4] == 26, "D88 type and sector count")
    # 4. NFD r1 protection data: retries and special reads are dropped only with --lossy;
    #    equal retry copies are not a loss
    tr = plain_tracks(77, 8, 3)
    r1 = make_nfd1(tr, retries={(4, 2): 2}, diags={7: [1024]})
    try:
        convert_bytes(r1, None)
        check(False, "NFD r1 retries/special reads must be refused without --lossy")
    except FormatError as e:
        check("retry" in str(e) and "special-read" in str(e), "the refusal lists both losses")
    out, disk, kind = convert_bytes(r1, None, lossy=True)
    check(kind == "d88" and write_raw(read_d88(out)) == raw_ref(77, 8, 3),
          "--lossy keeps the first copy of each sector, the rest of the disk intact")
    plain = make_nfd1(tr)
    hdr = bytearray(plain)
    check(convert_bytes(bytes(hdr), None)[0] == raw_ref(77, 8, 3), "NFD r1 plain")
    # 5. refusals: unknown data, a raw size, an FDI whose size disagrees, dwAddInfo != 0
    for label, img in (("random", bytes(5000)), ("raw size", bytes(1261568)),
                       ("short FDI", make_fdi(77, 8, 3, 0x90)[:-1])):
        try:
            read_any(img)
            check(False, label + ": must be refused")
        except FormatError:
            pass
    bad = bytearray(plain)
    struct.pack_into("<I", bad, 0x3B0, 1)
    try:
        read_any(bytes(bad))
        check(False, "NFD r1 dwAddInfo != 0 must be refused")
    except FormatError:
        pass
    fails += _selftest_files(images)
    print("fdconv selftest:", "PASS" if not fails else "FAIL (%d)" % len(fails))
    return 0 if not fails else 1


def _selftest_files(images):
    """The CLI and --batch: output == input refused, an existing output kept, sources never
    written, an up-to-date output skipped, a foreign file of the output's name kept."""
    import contextlib
    import hashlib
    import io
    fails = []

    def check(cond, what):
        if not cond:
            fails.append(what)
            print("SELFTEST FAIL (files):", what)
    quiet = lambda *a: None   # noqa: E731
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "a.nfd")
        with open(src, "wb") as f:
            f.write(images["NFD r0"])
        before = hashlib.sha256(images["NFD r0"]).hexdigest()
        try:
            convert_file(src, src, force=True, log=quiet)
            check(False, "output == input must be refused")
        except FormatError:
            pass
        os.symlink("a.nfd", os.path.join(d, "link.d88"))
        try:
            convert_file(src, os.path.join(d, "link.d88"), force=True, log=quiet)
            check(False, "an output that links to the input must be refused")
        except FormatError:
            pass
        check(convert_file(src, log=quiet) == os.path.join(d, "a.hdm"), "default name .hdm")
        try:
            convert_file(src, log=quiet)
            check(False, "an existing output must be kept without --force")
        except FormatError:
            pass
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            check(main([src, os.path.join(d, "b.d88")]) == 0, "CLI .d88")
            check(main([src, os.path.join(d, "b.img")]) == 1, "CLI refuses another extension")
        check(read_d88(open(os.path.join(d, "b.d88"), "rb").read()).nsectors() == 154 * 8,
              "the CLI's D88")
        # batch
        root = os.path.join(d, "games")
        os.makedirs(os.path.join(root, "x"))
        os.makedirs(os.path.join(root, ".hidden"))
        for name, img in (("x/one.fdi", images["FDI"]), ("x/two.FDD", images["Virtual98"]),
                          ("x/raw.fdd", bytes(1261568)), ("x/junk.nfd", b"T98FDDIMAGE.R0\0"),
                          ("x/three.nfd", images["NFD r1"]), (".hidden/h.nfd", images["NFD r0"])):
            with open(os.path.join(root, name), "wb") as f:
                f.write(img)
        with open(os.path.join(root, "x", "three.hdm"), "wb") as f:
            f.write(b"someone else's file")
        logs = []
        n = batch(root, log=logs.append)
        check(n == 2, "batch: junk and the foreign three.hdm are refused (got %d)" % n)
        x = os.path.join(root, "x")
        check(sorted(os.listdir(x)) == ["junk.nfd", "one.fdi", "one.hdm", "raw.fdd",
                                        "three.hdm", "three.nfd", "two.FDD", "two.hdm"],
              "batch outputs: %s" % sorted(os.listdir(x)))
        check(open(os.path.join(x, "three.hdm"), "rb").read() == b"someone else's file",
              "a foreign file is never replaced")
        check(open(os.path.join(x, "one.hdm"), "rb").read() == convert_bytes(images["FDI"],
                                                                             None)[0],
              "the batch output is the conversion")
        check(not os.path.exists(os.path.join(root, ".hidden", "h.hdm")), "hidden folders skipped")
        logs.clear()
        batch(root, log=logs.append)
        check(sum("\n  up to date" in x for x in logs) == 2, "second run: up to date")
        check(hashlib.sha256(open(src, "rb").read()).hexdigest() == before, "source unchanged")
        check(not [f for f in os.listdir(x) if f.endswith(".part")], "no temporary left")
    return fails


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", nargs="?")
    ap.add_argument("dst", nargs="?", help="OUT.hdm or OUT.d88 (default: SRC's name, .hdm when "
                    "a raw image holds the disk losslessly, else .d88)")
    ap.add_argument("--info", nargs="+", metavar="IMG")
    ap.add_argument("--batch", metavar="DIR",
                    help="convert every .nfd/.fdi/.fdd under DIR that has no up-to-date output "
                         "beside it")
    ap.add_argument("--lossy", action="store_true",
                    help="drop what a D88 cannot hold (listed) instead of refusing")
    ap.add_argument("--force", action="store_true", help="overwrite an existing output")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    if a.batch:
        return 1 if batch(a.batch, a.lossy, log=lambda m: print(m, flush=True)) else 0
    try:
        if a.info:
            for p in a.info:
                with open(p, "rb") as f:
                    print("%s:\n%s" % (p, describe(read_any(f.read()))))
            return 0
        if not a.src:
            ap.error("SRC is required (or --info/--batch/--selftest)")
        convert_file(a.src, a.dst, a.lossy, a.force)
        return 0
    except (FormatError, OSError) as e:
        print("error: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

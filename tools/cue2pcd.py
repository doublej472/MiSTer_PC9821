#!/usr/bin/env python3
"""Convert a CUE sheet and its BIN file(s), or a CloneCD set, into ONE .PCD image for the core's CD-ROM drive.

WHY ONE FILE. hps_io mounts one file per OSD slot, so the track layout a CUE keeps in a separate
text file has to travel inside the image. A PCD is a 2352-byte header followed by the disc as raw
2352-byte sectors, LBA 0 first:

  offset 0     the header sector (2352 bytes; the first 2048 are read by the drive at mount)
                  0  "PC98CD01"
                  8  track count            9  first track number
                 12  lead-out LBA (u32 LE)
                 16  4 bytes per entry (tracks, then the lead-out): u32 LE =
                       control (0x14 data / 0x10 audio) | LBA << 8 (24 bits)
                       | 0x80000000 for a MODE2 track
                512  per entry: the LBA, u32 big-endian      (READ TOC, LBA form)
               1024  per entry: 00 M S F of LBA + 150         (READ TOC, MSF form)
               1536  per entry: the same M S F in BCD         (NEC drivers' BCD form)
  offset 2352  disc sector 0, 1, ... as raw 2352-byte sectors

This is the layout of the Zet98 core's converter (Zet98_486_MiSTer's pc98_cd_image.py @3843bd5,
read as a FORMAT DESCRIPTION only - none of its code is used here), so a PCD from either tool
mounts in either core. src/pc9821/storage/pc9821_atapi.sv reads the header fields above and
serves a data sector's MODE1 user data from raw offset +16.

WHAT IS NEW HERE: MIXED SECTOR SIZES IN ONE BIN, AND PREGAP. A CUE may describe one BIN whose
tracks have different sector sizes - e.g. track 01 MODE1/2048 (cooked) followed by AUDIO tracks
(raw 2352) - and its INDEX times count SECTORS of each track's own size. The file is therefore
walked track by track: a track occupies the file from its first INDEX (00 if present, else 01)
up to the next track's first INDEX, at its own sector size (NP2kai's CUE reader does the same
walk: NP2kai diskimage/cddfile.c, the per-track sector_size loop). A PREGAP (and
POSTGAP) is NOT in the file: it is generated as silent sectors on the disc, so every later LBA
moves by its length - again NP2kai's rule (cdd_cue.c's pregapoffset).

COOKED DATA SECTORS ARE EXPANDED TO RAW 2352-BYTE MODE1 SECTORS (the choice, and why). The
alternative was a per-track sector size in the header, so the drive would find a 2048-byte
sector at a variable stride. That moves a track-table walk and a second multiplier into the
RTL for every read; a uniform 2352 stride is one constant multiply (2352 = 2048+256+32+16) and
the header the drive already reads. The cost is 15% more bytes on the SD card for the data
track, which is nothing next to a CD's audio. A wrapped sector gets the 12-byte sync, the
header (BCD M:S:F of LBA+150, mode 1) and its 2048 bytes; the 288-byte EDC/ECC tail is ZERO by
default (the drive never reads it - it has no READ CD) and correct with --ecc, which computes
the ECMA-130 EDC (CRC-32, polynomial 0x8001801B) and the RSPC P/Q parity, so the image is also a
valid raw disc for other tools.

CLONECD (.ccd + .img [+ .sub]). The .img is the whole disc as raw 2352-byte sectors from LBA
0, every track in one file, so it is already a PCD's body; only the track list comes from the
.ccd, an INI file. Read the way NP2kai reads it (NP2kai diskimage/cd/cdd_ccd.c openccd: the
image is the .ccd's name with ".img", the sector size is "2352byte固定", "MODE=1" makes the
track data (0x14) and "MODE=0" audio (0x10), "INDEX 1=" is the track's start LBA in the image
and "INDEX 0=" its pregap's): each [TRACK n] section gives a track, whose sectors run from its
INDEX 0 (else INDEX 1; track 1 from LBA 0) to the next track's start. The disc ends where the
.img ends. The [Entry] sections are the TOC the drive read from the disc's lead-in (Point
1..99 a track, PLBA its address, Control bit 2 a data track; 0xA2 the lead-out), which is what
a guest's READ TOC sees on the real disc, so where a track has an entry its PLBA is the PCD's
TOC address (a stronger source than NP2kai's INDEX 1, which it uses only without one; a
difference is reported). A data/audio disagreement between the two, or a lead-out that is not
the image's end, is refused. MODE=2 is a MODE2 track (the PCD's MODE2 flag). Refused: more than one session (the drive has a
one-session TOC) and DataTracksScrambled=1. The .sub (96 subchannel bytes per sector) is not
read: the drive serves no subchannel.

Usage:
  tools/cue2pcd.py GAME.cue [GAME.pcd] [--ecc] [--force]
  tools/cue2pcd.py GAME.ccd [GAME.pcd] [--force]   # CloneCD: the .img beside it, raw
  tools/cue2pcd.py GAME.cue --info          # the parsed layout and the TOC, no output
  tools/cue2pcd.py --batch DIR              # every CUE/CCD under DIR without an up-to-date PCD
  tools/cue2pcd.py --selftest               # synthetic CUEs (mixed sizes, PREGAP) round-trip

It runs on a computer (Python 3.9 or later); the PCD it writes is then copied to the SD card.
The batch mode converts a whole folder of images at once, and is safe to re-run.
"""

from __future__ import annotations

import argparse
import os
import re
import struct
import sys
import tempfile
from dataclasses import dataclass, field

RAW = 2352
MAGIC = b"PC98CD01"
SIZES = {"MODE1/2048": 2048, "MODE1/2352": RAW, "MODE2/2048": 2048, "MODE2/2336": 2336,
         "MODE2/2352": RAW, "AUDIO": RAW}


def msf_frames(text: str) -> int:
    m = re.fullmatch(r"(\d+):(\d+):(\d+)", text.strip())
    if not m:
        raise ValueError(f"bad M:S:F time {text!r}")
    mm, ss, ff = (int(x) for x in m.groups())
    if ss >= 60 or ff >= 75:
        raise ValueError(f"bad M:S:F time {text!r}")
    return (mm * 60 + ss) * 75 + ff


def msf(lba_plus_150: int) -> tuple[int, int, int]:
    return lba_plus_150 // 4500, (lba_plus_150 // 75) % 60, lba_plus_150 % 75


def bcd(v: int) -> int:
    return (v // 10) << 4 | (v % 10)


@dataclass
class Track:
    number: int
    mode: str
    file: str
    big_endian: bool
    index0: int | None = None
    index1: int | None = None
    pregap: int = 0
    postgap: int = 0
    # filled by layout()
    file_offset: int = 0       # byte offset of its first INDEX in the file
    file_sectors: int = 0      # sectors it occupies in the file (from its first INDEX)
    disc_lba: int = 0          # the TOC address: INDEX 01 on the disc
    disc_first: int = 0        # first disc sector of the track incl. PREGAP

    @property
    def size(self) -> int:
        return SIZES[self.mode]

    @property
    def audio(self) -> bool:
        return self.mode == "AUDIO"

    @property
    def control(self) -> int:
        return 0x10 if self.audio else 0x14


@dataclass
class Disc:
    tracks: list[Track] = field(default_factory=list)
    leadout: int = 0
    notes: list[str] = field(default_factory=list)


def resolve(base: str, name: str) -> str:
    """The FILE's path; CUEs written on Windows often differ from the file name in case only."""
    path = os.path.join(base, name)
    if os.path.exists(path):
        return path
    folded = [f for f in os.listdir(base) if f.lower() == name.lower()]
    return os.path.join(base, folded[0]) if len(folded) == 1 else path


def parse_cue(path: str) -> Disc:
    base = os.path.dirname(os.path.abspath(path))
    disc = Disc()
    cur_file, big = None, False
    with open(path, encoding="latin-1") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.upper().startswith(("REM", "CATALOG", "TITLE", "PERFORMER",
                                                    "SONGWRITER", "ISRC", "FLAGS", "CDTEXTFILE")):
                continue
            m = re.match(r'FILE\s+(?:"([^"]+)"|(\S+))\s+(\S+)$', line, re.I)
            if m:
                kind = m.group(3).upper()
                if kind not in ("BINARY", "MOTOROLA"):
                    raise ValueError(f"FILE type {kind} is not supported (BINARY / MOTOROLA only)")
                cur_file = resolve(base, m.group(1) or m.group(2))
                big = kind == "MOTOROLA"
                continue
            m = re.match(r"TRACK\s+(\d+)\s+(\S+)$", line, re.I)
            if m:
                if cur_file is None:
                    raise ValueError("TRACK before any FILE")
                mode = m.group(2).upper()
                if mode not in SIZES:
                    raise ValueError(f"track mode {mode} is not supported")
                disc.tracks.append(Track(int(m.group(1)), mode, cur_file, big))
                continue
            m = re.match(r"INDEX\s+(\d+)\s+(\S+)$", line, re.I)
            if m:
                if not disc.tracks:
                    raise ValueError("INDEX before any TRACK")
                n, t = int(m.group(1)), msf_frames(m.group(2))
                if n == 0:
                    disc.tracks[-1].index0 = t
                elif n == 1:
                    disc.tracks[-1].index1 = t
                continue   # INDEX 02+ are sub-indices inside the track: nothing to lay out
            m = re.match(r"(PREGAP|POSTGAP)\s+(\S+)$", line, re.I)
            if m:
                if not disc.tracks:
                    raise ValueError(f"{m.group(1)} before any TRACK")
                setattr(disc.tracks[-1], m.group(1).lower(), msf_frames(m.group(2)))
                continue
            raise ValueError(f"unrecognised CUE line: {line!r}")
    if not 1 <= len(disc.tracks) <= 99:
        raise ValueError("a disc has 1..99 tracks")
    for a, b in zip(disc.tracks, disc.tracks[1:]):
        if b.number != a.number + 1:
            raise ValueError(f"track {b.number} does not follow track {a.number}")
    for t in disc.tracks:
        if t.index1 is None:
            raise ValueError(f"track {t.number} has no INDEX 01")
        if t.index0 is not None and t.index0 > t.index1:
            raise ValueError(f"track {t.number}: INDEX 00 after INDEX 01")
    layout(disc)
    return disc


def layout(disc: Disc) -> None:
    """File offsets (the mixed-size walk) and disc LBAs (PREGAP/POSTGAP generated)."""
    by_file: dict[str, list[Track]] = {}
    for t in disc.tracks:
        by_file.setdefault(t.file, []).append(t)
    for name, tracks in by_file.items():
        size = os.path.getsize(name)
        offset, prev = 0, None
        for t in tracks:
            start = t.index0 if t.index0 is not None else t.index1
            if prev is None:
                # Sectors before the first track's first INDEX in a file belong to nothing on
                # the disc layout NP2kai builds either; there are none in a well-formed CUE.
                if start != 0:
                    offset = start * t.size
            else:
                pstart = prev.index0 if prev.index0 is not None else prev.index1
                prev.file_sectors = start - pstart
                if prev.file_sectors <= 0:
                    raise ValueError(f"track {t.number} starts before track {prev.number}")
                offset += prev.file_sectors * prev.size
            t.file_offset = offset
            prev = t
        rest = size - offset
        if rest < 0 or rest % prev.size:
            raise ValueError(f"{name}: track {prev.number} has {rest} bytes, not a whole number "
                             f"of {prev.size}-byte sectors (check the CUE's modes/INDEX times)")
        prev.file_sectors = rest // prev.size
    lba = 0
    for t in disc.tracks:
        t.disc_first = lba
        before_index1 = (t.index1 - t.index0) if t.index0 is not None else 0
        t.disc_lba = lba + t.pregap + before_index1
        lba += t.pregap + t.file_sectors + t.postgap
    disc.leadout = lba
    if disc.leadout >= 1 << 20:
        raise ValueError("disc too long for the drive's 20-bit LBA")


def parse_ccd(path: str) -> Disc:
    """A CloneCD set (see CLONECD above): the [TRACK n] list, checked against [Entry] TOC."""
    base = os.path.dirname(os.path.abspath(path))
    sections: list[tuple[str, dict[str, str]]] = []
    with open(path, encoding="latin-1") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith(";"):
                continue
            m = re.fullmatch(r"\[(.+)\]", line)
            if m:
                sections.append((m.group(1).strip().upper(), {}))
                continue
            if "=" not in line or not sections:
                raise ValueError(f"unrecognised CCD line: {line!r}")
            k, v = line.split("=", 1)
            sections[-1][1][k.strip().upper()] = v.strip()
    if not sections or sections[0][0] != "CLONECD":
        raise ValueError("not a CloneCD control file (no [CloneCD] section)")

    def num(sec: dict[str, str], key: str, where: str) -> int:
        try:
            return int(sec[key], 0)
        except (KeyError, ValueError):
            raise ValueError(f"[{where}] has no valid {key}=") from None
    disc_sec = dict(next((d for n, d in sections if n == "DISC"), {}))
    if int(disc_sec.get("SESSIONS", "1"), 0) != 1:
        raise ValueError(f"{disc_sec['SESSIONS']} sessions: only a one-session disc can be "
                         f"converted (the drive's TOC is one session)")
    if int(disc_sec.get("DATATRACKSSCRAMBLED", "0"), 0):
        raise ValueError("DataTracksScrambled=1: the data sectors are stored scrambled")
    img = os.path.splitext(path)[0] + ".img"
    img = resolve(base, os.path.basename(img))
    if not os.path.exists(img):
        raise ValueError(f"the image {os.path.basename(img)} is not beside the .ccd")
    size = os.path.getsize(img)
    if size % RAW:
        raise ValueError(f"{os.path.basename(img)} is {size} bytes, not whole 2352-byte sectors")
    # the TOC the drive read, where the CCD carries it
    toc = {}
    for name, sec in sections:
        if re.fullmatch(r"ENTRY\s+\d+", name):
            if int(sec.get("SESSION", "1"), 0) != 1:
                continue
            toc[num(sec, "POINT", name)] = (num(sec, "CONTROL", name), num(sec, "PLBA", name))
    disc = Disc()
    modes = {0: "AUDIO", 1: "MODE1/2352", 2: "MODE2/2352"}
    starts: list[int] = []
    for name, sec in sections:
        m = re.fullmatch(r"TRACK\s+(\d+)", name)
        if not m:
            continue
        where = f"TRACK {m.group(1)}"
        mode = num(sec, "MODE", where)
        if mode not in modes:
            raise ValueError(f"[{where}] MODE={mode} is not 0, 1 or 2")
        t = Track(int(m.group(1)), modes[mode], img, False)
        t.index1 = num(sec, "INDEX 1", where)
        t.index0 = num(sec, "INDEX 0", where) if "INDEX 0" in sec else None
        if t.index0 is not None and t.index0 > t.index1:
            raise ValueError(f"[{where}] INDEX 0 after INDEX 1")
        t.disc_lba = t.index1
        if t.number in toc:
            ctrl, plba = toc[t.number]
            if bool(ctrl & 4) == t.audio:
                raise ValueError(f"track {t.number}: [TRACK] MODE={mode} but the TOC entry's "
                                 f"control 0x{ctrl:X} says {'data' if ctrl & 4 else 'audio'}")
            if plba != t.index1:
                disc.notes.append(f"track {t.number}: the TOC entry's LBA {plba} is used, not "
                                  f"[TRACK] INDEX 1={t.index1}")
            t.disc_lba = plba
        elif toc:
            raise ValueError(f"track {t.number} is not in the [Entry] TOC")
        disc.tracks.append(t)
        first = t.index0 if t.index0 is not None else t.index1
        starts.append(0 if not starts else min(first, t.disc_lba))
    if not 1 <= len(disc.tracks) <= 99:
        raise ValueError("a disc has 1..99 tracks ([TRACK n] sections)")
    for a, b in zip(disc.tracks, disc.tracks[1:]):
        if b.number != a.number + 1:
            raise ValueError(f"track {b.number} does not follow track {a.number}")
    disc.leadout = size // RAW
    starts.append(disc.leadout)
    for t, first, nxt in zip(disc.tracks, starts, starts[1:]):
        if not first <= t.disc_lba < nxt or not first <= t.index1 < nxt:
            raise ValueError(f"track {t.number}: LBA {t.disc_lba} (INDEX 1={t.index1}) is "
                             f"outside its extent {first}..{nxt - 1} of the "
                             f"{disc.leadout}-sector image")
        t.disc_first = first
        t.file_offset, t.file_sectors = first * RAW, nxt - first
    if 0xA2 in toc and toc[0xA2][1] != disc.leadout:
        raise ValueError(f"the TOC lead-out is LBA {toc[0xA2][1]}, the image holds "
                         f"{disc.leadout} sectors")
    if disc.leadout >= 1 << 20:
        raise ValueError("disc too long for the drive's 20-bit LBA")
    return disc


def parse_image(path: str) -> Disc:
    """A CUE sheet, or a CloneCD .ccd (by its extension)."""
    return parse_ccd(path) if path.lower().endswith(".ccd") else parse_cue(path)


# ---- ECMA-130 EDC/ECC (--ecc) ----
def _edc_table() -> list[int]:
    table = []
    for i in range(256):
        e = i
        for _ in range(8):
            e = (e >> 1) ^ (0xD8018001 if e & 1 else 0)   # 0x8001801B, bit-reversed
        table.append(e)
    return table


EDC = _edc_table()
GF_EXP = [0] * 512
GF_LOG = [0] * 256
_x = 1
for _i in range(255):
    GF_EXP[_i] = _x
    GF_LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D   # x^8 + x^4 + x^3 + x^2 + 1, ECMA-130 annex A
for _i in range(255, 512):
    GF_EXP[_i] = GF_EXP[_i - 255]


def _gmul(a: int, b: int) -> int:
    return 0 if a == 0 or b == 0 else GF_EXP[GF_LOG[a] + GF_LOG[b]]


def edc(data: bytes) -> int:
    e = 0
    for byte in data:
        e = EDC[(e ^ byte) & 0xFF] ^ (e >> 8)
    return e


def _rs_parity(symbols: list[int]) -> tuple[int, int]:
    """The two parity symbols p0 (at the second-to-last position) and p1 (last) of a
    Reed-Solomon codeword over GF(2^8) whose check matrix is H = [[1..1],[a^(n-1)..a^0]]
    (ECMA-130 annex A): sum(c_i) = 0 and sum(c_i * a^(n-1-i)) = 0, n = len(symbols) + 2."""
    n = len(symbols) + 2
    s0 = 0
    s1 = 0
    for i, v in enumerate(symbols):
        s0 ^= v
        s1 ^= _gmul(v, GF_EXP[n - 1 - i])
    # unknowns x (position n-2, weight a^1) and y (position n-1, weight a^0):
    #   x + y = s0 ;  a*x + y = s1   =>  x = (s0 + s1) / (1 + a) , y = s0 + x
    inv = GF_EXP[255 - GF_LOG[1 ^ 2]]
    x = _gmul(s0 ^ s1, inv)
    return x, s0 ^ x


def _rs_fill(sector: bytearray) -> None:
    # P parity: for each lane and each of the 43 columns, the 24 data symbols at word index
    # row*43 + col, rows 0..23, then 2 parity symbols stored at words 1032 + col and 1075 + col.
    for lane in range(2):
        for col in range(43):
            syms = [sector[12 + 2 * (row * 43 + col) + lane] for row in range(24)]
            p0, p1 = _rs_parity(syms)
            sector[12 + 2 * (24 * 43 + col) + lane] = p0
            sector[12 + 2 * (25 * 43 + col) + lane] = p1
    # Q parity: for each lane and each of the 26 diagonals, the 43 symbols at word index
    # (44*m + 43*d) mod 1118, m = 0..42, then 2 parity symbols at words 1118 + d and 1144 + d.
    for lane in range(2):
        for d in range(26):
            syms = [sector[12 + 2 * ((44 * m + 43 * d) % 1118) + lane] for m in range(43)]
            q0, q1 = _rs_parity(syms)
            sector[12 + 2 * (1118 + d) + lane] = q0
            sector[12 + 2 * (1144 + d) + lane] = q1


def mode1_sector(user: bytes, lba: int, with_ecc: bool) -> bytes:
    m, s, f = msf(lba + 150)
    sector = bytearray(RAW)
    sector[0:12] = b"\x00" + b"\xff" * 10 + b"\x00"
    sector[12:16] = bytes((bcd(m), bcd(s), bcd(f), 1))
    sector[16:2064] = user
    if with_ecc:
        sector[2064:2068] = struct.pack("<I", edc(sector[0:2064]))
        _rs_fill(sector)
    return bytes(sector)


def header(disc: Disc) -> bytes:
    h = bytearray(RAW)
    h[0:8] = MAGIC
    h[8] = len(disc.tracks)
    h[9] = disc.tracks[0].number
    struct.pack_into("<I", h, 12, disc.leadout)
    entries = [(t.control, t.disc_lba, t.mode.startswith("MODE2")) for t in disc.tracks]
    entries.append((disc.tracks[-1].control, disc.leadout, False))
    for i, (ctrl, lba, mode2) in enumerate(entries):
        struct.pack_into("<I", h, 16 + 4 * i, ctrl | (lba << 8) | (0x80000000 if mode2 else 0))
        struct.pack_into(">I", h, 512 + 4 * i, lba)
        m, s, f = msf(lba + 150)
        h[1024 + 4 * i:1028 + 4 * i] = bytes((0, m, s, f))
        h[1536 + 4 * i:1540 + 4 * i] = bytes((0, bcd(m), bcd(s), bcd(f)))
    return bytes(h)


def sectors(disc: Disc, with_ecc: bool):
    """Yield every disc sector, LBA 0 first, as 2352 raw bytes."""
    handles: dict[str, object] = {}
    lba = 0
    try:
        for t in disc.tracks:
            silent = bytes(RAW)
            for _ in range(t.pregap):
                yield silent if t.audio else mode1_sector(bytes(2048), lba, with_ecc)
                lba += 1
            h = handles.get(t.file) or handles.setdefault(t.file, open(t.file, "rb"))
            h.seek(t.file_offset)
            for _ in range(t.file_sectors):
                data = h.read(t.size)
                if len(data) != t.size:
                    raise ValueError(f"{t.file}: short read in track {t.number}")
                if t.size == RAW:
                    if t.audio and t.big_endian:
                        data = bytes(b for pair in zip(data[1::2], data[0::2]) for b in pair)
                    yield data
                elif t.mode == "MODE1/2048" or t.mode == "MODE2/2048":
                    yield mode1_sector(data, lba, with_ecc)
                else:
                    raise ValueError(f"track {t.number}: {t.mode} cannot be stored raw")
                lba += 1
            for _ in range(t.postgap):
                yield silent if t.audio else mode1_sector(bytes(2048), lba, with_ecc)
                lba += 1
    finally:
        for h in handles.values():
            h.close()
    assert lba == disc.leadout


def describe(disc: Disc) -> str:
    out = []
    for t in disc.tracks:
        m, s, f = msf(t.disc_lba + 150)
        out.append(f"track {t.number:2d} {t.mode:<10} {'audio' if t.audio else 'data '} "
                   f"LBA {t.disc_lba:7d} {m:02d}:{s:02d}:{f:02d}  file +{t.file_offset} "
                   f"x{t.file_sectors} @{t.size}  pregap {t.pregap} postgap {t.postgap}")
    m, s, f = msf(disc.leadout + 150)
    out.append(f"lead-out LBA {disc.leadout} {m:02d}:{s:02d}:{f:02d}")
    out += ["note: " + x for x in disc.notes]
    return "\n".join(out)


def convert(cue: str, out: str, with_ecc: bool, progress=None, disc: Disc | None = None) -> Disc:
    """Write OUT through OUT.part and rename it into place, so an interrupted run never leaves
    a truncated image under the real name. PROGRESS(done, total) is called every 1% or so."""
    disc = disc or parse_image(cue)
    tmp = out + ".part"
    step = max(1, disc.leadout // 100)
    try:
        with open(tmp, "wb") as o:
            o.write(header(disc))
            for n, sector in enumerate(sectors(disc, with_ecc)):
                o.write(sector)
                if progress and n % step == 0:
                    progress(n, disc.leadout)
        os.replace(tmp, out)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise
    if progress:
        progress(disc.leadout, disc.leadout)
    return disc


# ---- batch mode (--batch DIR): a whole folder of CD images in one run ----
# Every CUE under DIR gets a PCD beside it (same stem) unless an up-to-date one is already
# there. The sources are only ever opened for reading. A PCD is up to date when it is a PCD of
# exactly the size the CUE's layout gives, its header sector is the one this tool would write, and
# it is not older than the CUE or any file the CUE names: then it is skipped, so the batch is safe
# to re-run. Free space is checked per image BEFORE writing (the whole image plus a margin).
PCD_MARGIN = 64 << 20


def pcd_size(disc: Disc) -> int:
    return RAW * (1 + disc.leadout)


def _sources(cue: str, disc: Disc) -> list[str]:
    return [cue] + sorted({t.file for t in disc.tracks})


def pcd_up_to_date(cue: str, out: str, disc: Disc) -> bool:
    try:
        st = os.stat(out)
    except FileNotFoundError:
        return False
    if st.st_size != pcd_size(disc):
        return False
    with open(out, "rb") as f:
        if f.read(RAW) != header(disc):
            return False
    return all(st.st_mtime >= os.stat(s).st_mtime for s in _sources(cue, disc))


def find_cues(root: str) -> list[str]:
    """Every CUE and CCD under ROOT (hidden names skipped). A CCD whose stem also has a CUE in
    the same folder is left out: both would write the same .pcd, and the CUE is converted."""
    found = []
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if not x.startswith("."))
        cue_stems = {os.path.splitext(f)[0].lower() for f in files if f.lower().endswith(".cue")}
        found += [os.path.join(d, f) for f in sorted(files)
                  if not f.startswith(".") and (f.lower().endswith(".cue") or (
                      f.lower().endswith(".ccd")
                      and os.path.splitext(f)[0].lower() not in cue_stems))]
    return found


def _human(n: int) -> str:
    return f"{n / (1 << 20):.0f} MiB"


def batch(root: str, with_ecc: bool = False, free_bytes=None, log=print) -> int:
    """Convert every CUE/CCD under ROOT. Returns the number of them that failed (0 = all done or
    already up to date). FREE_BYTES(path) is injectable for the self-test."""
    import shutil
    free_bytes = free_bytes or (lambda path: shutil.disk_usage(path).free)
    if not os.path.isdir(root):
        log(f"cue2pcd: {root} is not a directory")
        return 1
    cues = find_cues(root)
    log(f"cue2pcd: {len(cues)} CUE/CCD file(s) under {root}, {_human(free_bytes(root))} free")
    made = skipped = failed = 0
    for i, cue in enumerate(cues, 1):
        rel = os.path.relpath(cue, root)
        out = os.path.splitext(cue)[0] + ".pcd"
        log(f"[{i}/{len(cues)}] {rel}")
        try:
            disc = parse_image(cue)
        except (ValueError, OSError) as e:
            log(f"  SKIP: cannot use this file: {e}")
            failed += 1
            continue
        srcs = [os.path.realpath(s) for s in _sources(cue, disc)]
        if os.path.realpath(out) in srcs or os.path.realpath(out + ".part") in srcs:
            log(f"  SKIP: the output name {os.path.basename(out)} is one of its own source files")
            failed += 1
            continue
        if os.path.exists(out):
            if pcd_up_to_date(cue, out, disc):
                log(f"  up to date: {os.path.basename(out)}")
                skipped += 1
                continue
            with open(out, "rb") as f:
                if f.read(len(MAGIC)) != MAGIC:
                    log(f"  SKIP: {os.path.basename(out)} exists and is not a PCD; not replacing it")
                    failed += 1
                    continue
            log(f"  {os.path.basename(out)} is stale (older than its sources or a different "
                f"layout): rebuilding")
        if os.path.exists(out + ".part"):
            os.remove(out + ".part")          # a previous run was interrupted
        need = pcd_size(disc)
        free = free_bytes(os.path.dirname(out) or ".")
        if free < need + PCD_MARGIN:
            log(f"  SKIP: needs {_human(need)} (+{_human(PCD_MARGIN)} margin), only "
                f"{_human(free)} free")
            failed += 1
            continue
        for note in disc.notes:
            log(f"  note: {note}")
        log(f"  {len(disc.tracks)} track(s), {disc.leadout} sectors -> "
            f"{os.path.basename(out)} ({_human(need)})")
        last = [-1]

        def progress(done, total):
            pct = done * 100 // max(1, total)
            if pct >= last[0] + 10 or done == total:
                last[0] = pct
                log(f"    {pct:3d}%")
        try:
            convert(cue, out, with_ecc, progress, disc)
        except (ValueError, OSError) as e:
            log(f"  FAILED: {e}")
            failed += 1
            continue
        made += 1
    log(f"cue2pcd: {made} converted, {skipped} already up to date, {failed} failed")
    return failed


# ---- self-test: synthetic discs, every rule above checked against independent arithmetic ----
def selftest() -> int:
    fails = 0

    def check(cond, what):
        nonlocal fails
        if not cond:
            fails += 1
            print("SELFTEST FAIL:", what)

    def user(lba, i):
        return (lba * 7 + i * 3 + (i >> 8)) & 0xFF

    def pcm(n, i):
        return (n * 31 + i * 5) & 0xFF

    with tempfile.TemporaryDirectory(dir=os.environ.get("CUE2PCD_TMP")) as d:
        # one BIN: 12 cooked MODE1 sectors, 5 audio (track 2, after a 2 s PREGAP), then an
        # INDEX 00 run of 3 audio sectors and 4 more for track 3
        data = bytes(user(l, i) for l in range(12) for i in range(2048))
        a2 = bytes(pcm(2, i) for i in range(5 * RAW))
        a3 = bytes(pcm(3, i) for i in range(7 * RAW))
        with open(os.path.join(d, "x.bin"), "wb") as f:
            f.write(data + a2 + a3)
        with open(os.path.join(d, "x.cue"), "w") as f:
            f.write('FILE "x.bin" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n'
                    '  TRACK 02 AUDIO\n    PREGAP 00:02:00\n    INDEX 01 00:00:12\n'
                    '  TRACK 03 AUDIO\n    INDEX 00 00:00:17\n    INDEX 01 00:00:20\n')
        for with_ecc in (False, True):
            out = os.path.join(d, f"x{int(with_ecc)}.pcd")
            disc = convert(os.path.join(d, "x.cue"), out, with_ecc)
            img = open(out, "rb").read()
            check(len(img) == RAW * (1 + 12 + 150 + 5 + 7), "file length (header + every sector)")
            check(img[0:8] == MAGIC and img[8] == 3 and img[9] == 1, "magic / track count / first")
            # track 2 starts after 12 data sectors + 150 generated; track 3's INDEX 01 is 3 into
            # its INDEX 00 run, 5 audio sectors after track 2's start
            check([t.disc_lba for t in disc.tracks] == [0, 162, 170], "TOC LBAs")
            check(disc.leadout == 12 + 150 + 5 + 7, "lead-out")
            check(struct.unpack_from("<I", img, 12)[0] == disc.leadout, "header lead-out")
            check(struct.unpack_from("<I", img, 16 + 4)[0] == 0x10 | (162 << 8), "entry 1 word")
            check(struct.unpack_from(">I", img, 512 + 8)[0] == 170, "entry 2 BE LBA")
            check(img[1024 + 8:1028 + 8] == bytes((0, 0, 4, 20)), "entry 2 MSF (320 = 0:04:20)")
            check(img[1536 + 12:1540 + 12] == bytes((0, 0, 0x04, 0x24)),
                  "lead-out BCD (174 + 150 = 324 frames = 0:04:24)")
            # a cooked sector: sync, BCD header, user data at +16
            s5 = img[RAW * (1 + 5):RAW * (2 + 5)]
            check(s5[0:12] == b"\x00" + b"\xff" * 10 + b"\x00", "sync")
            check(s5[12:16] == bytes((0x00, 0x02, 0x05, 1)), "MODE1 header of LBA 5 (00:02:05)")
            check(s5[16:2064] == bytes(user(5, i) for i in range(2048)), "user data at +16")
            # the PREGAP is silence; the audio is copied raw
            check(img[RAW * (1 + 12):RAW * (1 + 162)] == bytes(150 * RAW), "PREGAP silence")
            check(img[RAW * (1 + 162):RAW * (1 + 167)] == a2, "track 2 audio")
            check(img[RAW * (1 + 167):RAW * (1 + 174)] == a3, "track 3 audio incl. INDEX 00")
            if with_ecc:
                check(struct.unpack_from("<I", s5, 2064)[0] == edc(s5[0:2064]), "EDC")
                check(any(s5[2076:]), "ECC present")
            else:
                check(not any(s5[2064:]), "EDC/ECC zero by default")
        # the EDC against the published CRC check value of its polynomial (reflected 0x8001801B,
        # init 0, no final xor: "123456789" -> 0x6EC2EDC4)
        check(edc(b"123456789") == 0x6EC2EDC4, "EDC check value")
        # the RS code: every P column and Q diagonal must have a zero syndrome
        sec = bytearray(mode1_sector(bytes(user(9, i) for i in range(2048)), 9, True))
        ok = True
        for lane in range(2):
            for col in range(43):
                syms = [sec[12 + 2 * (row * 43 + col) + lane] for row in range(26)]
                s0 = s1 = 0
                for i, v in enumerate(syms):
                    s0 ^= v
                    s1 ^= _gmul(v, GF_EXP[25 - i])
                ok &= s0 == 0 and s1 == 0
            for dg in range(26):
                syms = [sec[12 + 2 * ((44 * m + 43 * dg) % 1118) + lane] for m in range(43)]
                syms += [sec[12 + 2 * (1118 + dg) + lane], sec[12 + 2 * (1144 + dg) + lane]]
                s0 = s1 = 0
                for i, v in enumerate(syms):
                    s0 ^= v
                    s1 ^= _gmul(v, GF_EXP[44 - i])
                ok &= s0 == 0 and s1 == 0
        check(ok, "RSPC syndromes zero")
        # rejected inputs
        with open(os.path.join(d, "bad.cue"), "w") as f:
            f.write('FILE "x.bin" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n'
                    '  TRACK 02 AUDIO\n    INDEX 01 00:00:13\n')
        try:
            parse_cue(os.path.join(d, "bad.cue"))
            check(False, "a size that is not whole sectors must be rejected")
        except ValueError:
            pass
        fails += _selftest_ccd(d)
        fails += _selftest_batch(d, os.path.join(d, "x0.pcd"))
    print("cue2pcd selftest:", "PASS" if fails == 0 else f"FAIL ({fails})")
    return 0 if fails == 0 else 1


CCD_HEAD = "[CloneCD]\nVersion=3\n[Disc]\nTocEntries={n}\nSessions={sessions}\n" \
           "DataTracksScrambled={scr}\nCDTextLength=0\n[Session 1]\nPreGapMode=1\n"
CCD_ENTRY = "[Entry {i}]\nSession=1\nPoint=0x{point:02x}\nADR=0x01\nControl=0x{ctrl:02x}\n" \
            "TrackNo=0\nAMin=0\nASec=0\nAFrame=0\nALBA=-150\nZero=0\nPMin={pm}\n" \
            "PSec={ps}\nPFrame={pf}\nPLBA={plba}\n"


def write_ccd(path: str, tracks, leadout: int, sessions: int = 1, scrambled: int = 0,
              toc_override=None, ctrl_override=None) -> None:
    """A CloneCD control file in CloneCD's own layout (Version=3, as a real one reads):
    TRACKS = [(number, mode 0/1/2, index1, index0 or None)]; TOC_OVERRIDE {point: plba},
    CTRL_OVERRIDE {point: control}."""
    toc = [(0xA0, 4 if tracks[0][1] else 0, tracks[0][0] * 4500 - 150),
           (0xA1, 4 if tracks[-1][1] else 0, tracks[-1][0] * 4500 - 150),
           (0xA2, 4 if tracks[-1][1] else 0, leadout)]
    toc += [(n, 4 if mode else 0, i1) for n, mode, i1, _ in tracks]
    text = CCD_HEAD.format(n=len(toc), sessions=sessions, scr=scrambled)
    for i, (point, ctrl, plba) in enumerate(toc):
        plba = (toc_override or {}).get(point, plba)
        ctrl = (ctrl_override or {}).get(point, ctrl)
        m, s_, f = msf(plba + 150)
        text += CCD_ENTRY.format(i=i, point=point, ctrl=ctrl, pm=m, ps=s_, pf=f, plba=plba)
    for n, mode, i1, i0 in tracks:
        text += f"[TRACK {n}]\nMODE={mode}\n" + (f"INDEX 0={i0}\n" if i0 is not None else "") \
            + f"INDEX 1={i1}\n"
    with open(path, "w", newline="\r\n") as f:
        f.write(text)


def _selftest_ccd(d: str) -> int:
    """A CloneCD set gives the PCD the equivalent raw CUE gives; a disagreeing TOC, two
    sessions, scrambled data and an image that does not end at the lead-out are refused."""
    import shutil
    fails = 0

    def check(cond, what):
        nonlocal fails
        if not cond:
            fails += 1
            print("SELFTEST FAIL (ccd):", what)
    cd = os.path.join(d, "ccd")
    os.makedirs(cd)
    # 6 raw MODE1 sectors, then an audio track with a 2-sector INDEX 0 run and 4 more, then a
    # MODE2 track of 3 sectors
    body = bytes((i * 11 + 3) & 0xFF for i in range(15 * RAW))
    with open(os.path.join(cd, "c.img"), "wb") as f:
        f.write(body)
    with open(os.path.join(cd, "c.cue"), "w") as f:
        f.write('FILE "c.img" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n'
                '  TRACK 02 AUDIO\n    INDEX 00 00:00:06\n    INDEX 01 00:00:08\n'
                '  TRACK 03 MODE2/2352\n    INDEX 01 00:00:12\n')
    tracks = [(1, 1, 0, None), (2, 0, 8, 6), (3, 2, 12, None)]
    write_ccd(os.path.join(cd, "c.ccd"), tracks, 15)
    ref, got = os.path.join(cd, "ref.pcd"), os.path.join(cd, "got.pcd")
    convert(os.path.join(cd, "c.cue"), ref, False)
    disc = convert(os.path.join(cd, "c.ccd"), got, False)
    img = open(got, "rb").read()
    check(img == open(ref, "rb").read(), "the CCD's PCD equals the equivalent CUE's")
    check(img[RAW:] == body, "the .img is the PCD body byte for byte")
    check([t.disc_lba for t in disc.tracks] == [0, 8, 12] and disc.leadout == 15, "TOC")
    check(struct.unpack_from("<I", img, 16 + 8)[0] == 0x14 | (12 << 8) | 0x80000000,
          "MODE2 track: data control and the MODE2 flag")
    check(struct.unpack_from("<I", img, 16 + 4)[0] == 0x10 | (8 << 8), "audio track word")
    # without [Entry] sections (NP2kai reads only [TRACK n]) the result is the same
    text = open(os.path.join(cd, "c.ccd")).read()
    with open(os.path.join(cd, "n.ccd"), "w") as f:
        f.write(re.sub(r"\[Entry \d+\][^[]*", "", text))
    os.symlink("c.img", os.path.join(cd, "n.img"))
    check(header(parse_ccd(os.path.join(cd, "n.ccd"))) == img[:RAW], "a CCD without [Entry] TOC")
    # a TOC entry whose PLBA differs from INDEX 1 (a disc whose lead-in TOC points 1 sector
    # before INDEX 1): the TOC's address is the one the guest sees, and the difference is noted
    write_ccd(os.path.join(cd, "t.ccd"), tracks, 15, toc_override={2: 7})
    os.symlink("c.img", os.path.join(cd, "t.img"))
    td = parse_ccd(os.path.join(cd, "t.ccd"))
    check([t.disc_lba for t in td.tracks] == [0, 7, 12] and len(td.notes) == 1,
          "the TOC entry's PLBA is the TOC address, noted")
    check(struct.unpack_from(">I", header(td), 512 + 4)[0] == 7, "header LBA from the TOC")
    bad = {
        "TOC control disagrees": dict(ctrl_override={2: 4}),
        "lead-out disagrees": dict(toc_override={0xA2: 16}),
        "two sessions": dict(sessions=2),
        "scrambled": dict(scrambled=1),
    }
    for label, kw in bad.items():
        write_ccd(os.path.join(cd, "b.ccd"), tracks, 15, **kw)
        if not os.path.exists(os.path.join(cd, "b.img")):
            os.symlink("c.img", os.path.join(cd, "b.img"))
        try:
            parse_ccd(os.path.join(cd, "b.ccd"))
            check(False, f"{label}: must be refused")
        except ValueError:
            pass
    write_ccd(os.path.join(cd, "b.ccd"), [(1, 1, 0, None), (2, 0, 16, None)], 15)
    try:
        parse_ccd(os.path.join(cd, "b.ccd"))
        check(False, "a track past the end of the image must be refused")
    except ValueError:
        pass
    # the CLI refuses an output that is the input's own image, even with --force
    import contextlib
    import io
    before = open(os.path.join(cd, "c.img"), "rb").read()
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            main([os.path.join(cd, "c.ccd"), os.path.join(cd, "c.img"), "--force"])
            check(False, "output == input must be refused")
        except SystemExit as e:
            check(e.code != 0, "output == input exits non-zero")
    check(open(os.path.join(cd, "c.img"), "rb").read() == before, "the input image is untouched")
    # --batch picks up a CCD, and leaves out a CCD that has a CUE of the same name beside it
    root = os.path.join(cd, "games")
    for sub in ("a", "b"):
        os.makedirs(os.path.join(root, sub))
        shutil.copy(os.path.join(cd, "c.img"), os.path.join(root, sub, "C.IMG"))
        shutil.copy(os.path.join(cd, "c.ccd"), os.path.join(root, sub, "C.ccd"))
    shutil.copy(os.path.join(cd, "c.cue"), os.path.join(root, "b", "c.cue"))
    with open(os.path.join(root, "b", "c.cue")) as f:
        cue_text = f.read().replace('"c.img"', '"C.IMG"')
    with open(os.path.join(root, "b", "c.cue"), "w") as f:
        f.write(cue_text)
    found = [os.path.relpath(x, root) for x in find_cues(root)]
    check(found == [os.path.join("a", "C.ccd"), os.path.join("b", "c.cue")],
          f"batch finds the CCD and prefers a same-name CUE: {found}")
    logs: list[str] = []
    check(batch(root, free_bytes=lambda path: 1 << 40, log=logs.append) == 0, "CCD batch run")
    check(open(os.path.join(root, "a", "C.pcd"), "rb").read() == img, "the batch CCD's PCD")
    logs.clear()
    batch(root, free_bytes=lambda path: 1 << 40, log=logs.append)
    check(sum(x.startswith("  up to date") for x in logs) == 2, "a CCD's PCD is up to date")
    return fails


def _selftest_batch(d: str, x_ref: str) -> int:
    """--batch: converts what needs it, skips what is up to date, never writes a source, refuses
    a name collision or a foreign file, honours free space and cleans an interrupted run."""
    import hashlib
    import shutil
    fails = 0

    def check(cond, what):
        nonlocal fails
        if not cond:
            fails += 1
            print("SELFTEST FAIL (batch):", what)

    root = os.path.join(d, "games")
    g1, g2, hid = (os.path.join(root, n) for n in ("g1", "g2", ".hidden"))
    for x in (g1, g2, hid):
        os.makedirs(x)
    shutil.copy(os.path.join(d, "x.bin"), g1)
    shutil.copy(os.path.join(d, "x.cue"), os.path.join(g1, "X.CUE"))   # case of the extension
    # a multi-FILE cue: a raw MODE1/2352 data track and an AUDIO track, one BIN each
    with open(os.path.join(g2, "m1.bin"), "wb") as f:
        f.write(bytes((i * 13) & 0xFF for i in range(3 * RAW)))
    with open(os.path.join(g2, "m2.bin"), "wb") as f:
        f.write(bytes((i * 7 + 1) & 0xFF for i in range(4 * RAW)))
    with open(os.path.join(g2, "m.cue"), "w") as f:
        f.write('FILE "m1.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n'
                'FILE "m2.bin" BINARY\n  TRACK 02 AUDIO\n    INDEX 00 00:00:00\n'
                '    INDEX 01 00:00:01\n')
    with open(os.path.join(g2, "bad.cue"), "w") as f:     # names a missing file
        f.write('FILE "none.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
    with open(os.path.join(g2, "c.pcd"), "wb") as f:      # a cue whose own BIN is c.pcd
        f.write(bytes(RAW))
    with open(os.path.join(g2, "c.cue"), "w") as f:
        f.write('FILE "c.pcd" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
    shutil.copy(os.path.join(g2, "m1.bin"), os.path.join(g2, "n.bin"))
    with open(os.path.join(g2, "n.cue"), "w") as f:
        f.write('FILE "n.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
    with open(os.path.join(g2, "n.pcd"), "wb") as f:      # someone else's file of that name
        f.write(b"not a pcd")
    shutil.copy(os.path.join(g1, "X.CUE"), os.path.join(hid, "h.cue"))
    shutil.copy(os.path.join(d, "x.bin"), hid)

    def snap(names):
        out = {}
        for n in names:
            st = os.stat(n)
            out[n] = (hashlib.sha256(open(n, "rb").read()).hexdigest(), st.st_mtime_ns)
        return out
    srcs = [os.path.join(g1, "x.bin"), os.path.join(g1, "X.CUE"), os.path.join(g2, "m1.bin"),
            os.path.join(g2, "m2.bin"), os.path.join(g2, "m.cue"), os.path.join(g2, "c.pcd"),
            os.path.join(g2, "n.pcd"), os.path.join(g2, "n.bin")]
    before = snap(srcs)
    logs: list[str] = []
    big = lambda path: 1 << 40   # noqa: E731

    xp, mp = os.path.join(g1, "X.pcd"), os.path.join(g2, "m.pcd")
    n_fail = batch(root, free_bytes=big, log=logs.append)
    check(n_fail == 3, f"first run: 3 refusals (bad, c, n), got {n_fail}")
    check(os.path.exists(xp) and open(xp, "rb").read() == open(x_ref, "rb").read(),
          "the batch PCD equals the single-file conversion")
    m = open(mp, "rb").read() if os.path.exists(mp) else b""
    check(len(m) == RAW * (1 + 3 + 4), "multi-FILE PCD length")
    check(m[RAW:RAW * 4] == open(os.path.join(g2, "m1.bin"), "rb").read(), "multi-FILE data track")
    check(m[RAW * 4:] == open(os.path.join(g2, "m2.bin"), "rb").read(), "multi-FILE audio track")
    check(struct.unpack_from(">I", m, 512 + 4)[0] == 4, "multi-FILE track 2 LBA (INDEX 01 = 3 + 1)")
    check(open(os.path.join(g2, "n.pcd"), "rb").read() == b"not a pcd", "a foreign .pcd is kept")
    check(not os.path.exists(os.path.join(hid, "h.pcd")), "hidden directories are not walked")
    check(any("one of its own source files" in x for x in logs), "the collision is reported")

    t_x, t_m = os.stat(xp).st_mtime_ns, os.stat(mp).st_mtime_ns
    logs.clear()
    batch(root, free_bytes=big, log=logs.append)
    check(sum(x.startswith("  up to date") for x in logs) == 2, "second run: both images up to date")
    check((os.stat(xp).st_mtime_ns, os.stat(mp).st_mtime_ns) == (t_x, t_m),
          "second run rewrites nothing")

    # a source newer than its PCD: rebuilt (and only that one)
    st = os.stat(mp)
    os.utime(os.path.join(g2, "m2.bin"), ns=(st.st_atime_ns, st.st_mtime_ns + 10**9))
    before[os.path.join(g2, "m2.bin")] = snap([os.path.join(g2, "m2.bin")])[os.path.join(g2, "m2.bin")]
    logs.clear()
    batch(root, free_bytes=big, log=logs.append)
    check(any("stale" in x for x in logs) and os.stat(xp).st_mtime_ns == t_x,
          "a newer source rebuilds its PCD only")
    check(open(mp, "rb").read() == m, "the rebuilt PCD is the same image")

    # a truncated PCD is not up to date
    with open(xp, "r+b") as f:
        f.truncate(RAW * 3)
    batch(root, free_bytes=big, log=lambda _: None)
    check(open(xp, "rb").read() == open(x_ref, "rb").read(), "a truncated PCD is rebuilt")

    # no room: nothing written, no .part left; a stale .part from an interrupted run is removed
    os.remove(xp)
    with open(xp + ".part", "wb") as f:
        f.write(b"interrupted")
    logs.clear()
    batch(root, free_bytes=lambda path: 1 << 20, log=logs.append)
    check(not os.path.exists(xp) and not os.path.exists(xp + ".part"),
          "too little space: nothing written, the stale .part removed")
    check(any("free" in x and "SKIP" in x for x in logs), "the space refusal is reported")
    batch(root, free_bytes=big, log=lambda _: None)
    check(os.path.exists(xp) and not os.path.exists(xp + ".part"), "converted once space allows")

    check(snap(srcs) == before, "no source file was modified (content and mtime)")
    return fails


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("cue", nargs="?", help="the .cue (or CloneCD .ccd)")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--ecc", action="store_true", help="compute EDC/ECC for wrapped data sectors")
    ap.add_argument("--info", action="store_true", help="print the layout; write nothing")
    ap.add_argument("--force", action="store_true", help="overwrite an existing output")
    ap.add_argument("--batch", metavar="DIR",
                    help="convert every CUE/CCD under DIR that has no up-to-date PCD beside it")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    if a.batch:
        return 1 if batch(a.batch, a.ecc, log=lambda m: print(m, flush=True)) else 0
    if not a.cue:
        ap.error("a CUE sheet or CloneCD .ccd is required")
    if a.info:
        print(describe(parse_image(a.cue)))
        return 0
    out = a.out or os.path.splitext(a.cue)[0] + ".pcd"
    disc = parse_image(a.cue)
    srcs = [os.path.realpath(x) for x in _sources(a.cue, disc)]
    if os.path.realpath(out) in srcs or os.path.realpath(out + ".part") in srcs:
        ap.error(f"{out} is one of the input's own files: refusing (even with --force)")
    if os.path.exists(out) and not a.force:
        ap.error(f"refusing to overwrite {out} (--force)")
    disc = convert(a.cue, out, a.ecc, disc=disc)
    print(describe(disc))
    print(f"wrote {out} ({os.path.getsize(out)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

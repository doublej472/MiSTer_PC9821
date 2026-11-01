#!/usr/bin/env python3
"""The PC-98 firmware pack: its layout, its one directory, and reading it back.

THE PACK IS THE ONLY FIRMWARE INPUT THE CORE HAS. `pc9821_rom_loader.sv` ingests an
ioctl stream (ioctl_download/index/wr/addr/dout) -- the MiSTer HPS path a `.bin` in the
MGL drives -- so the card loads `pc98pack.bin` and the benches drive the same interface
byte for byte. Nothing else reaches the guest.

This module exists so ONE table defines that file. Before it, the layout was written out
in tools/build_pack.py, again in tools/check_pack.py, again in prose in the docs, and
implicitly in the loader's PACK_BYTES; a reader could not tell which was authoritative.
Here it is built from, verified against, listed by, and extracted to, so the tool and the
documentation agree by construction rather than by maintenance.

THE LAYOUT. Offsets are fixed; this table is the contract the loader's PACK_BYTES, the
firmware reserve's gvram_base and tools/check_pack.py all follow:

    +0x00000  0x08000  ITF slot, bank 4                BANK4.BIN, and the reset vector
    +0x10000  0x10000  main BIOS, lower 64 KiB         BIOS.ROM[0x00000:0x10000]
    +0x20000  0x08000  main BIOS top = the 0xF8000 window, bank 7   BANK7.BIN
    +0x30000  0x01000  ANK 8x16 window                 FONT.ROM[0x800:0x1800]
    +0x31000  0x08000  extended ROM bank 0             BANK0.BIN
    +0x39000  0x08000  extended ROM bank 1             BANK1.BIN
    +0x41000  0x08000  extended ROM bank 2             BANK2.BIN
    +0x49000  0x02000  YM2608 ADPCM-A rhythm ROM       --rhythm image, or 0x00 filler
    +0x70000  0x08000  IDE option-ROM slot, bank 3     BANK3.BIN
    +0x80000  0x46800  character generator, the whole FONT.ROM verbatim
    +0xC6800  0x04000  PC-9801-86 SOUND.ROM window     SOUND.ROM (0xCC000-0xCFFFF)
    +0xCA800  0x35800  unused (0xFF filler), free for later consumers

Everything below +0x80000 kept the offset it had when the reserve was 512 KiB, so only the
font had to be placed. The font begins exactly at the old reserve boundary: a pack built
before the reserve grew therefore carries NONE of it (every glyph reads stale SDRAM) rather
than a misleading first 32 KiB, and a reader of the file can see the split -- firmware in
the low half, the glyph generator in the high half. The character generator reads it as a
plain pack region at pack_base + 0x80000 + <glyph offset>, which needs no memory-map
change: the map is untouched by the font's presence.

ONE MACHINE, ONE DIRECTORY. Every region but the rhythm ROM comes from a single directory
of dumps -- BANK0.BIN..BANK7.BIN, BIOS.ROM, FONT.ROM -- and two of those files ARE two of
the named inputs: the reset ITF is BANK4.BIN and the IDE option ROM is BANK3.BIN, because
the machine's banks are selected by port 0x043F and those are the banks that hold them. So
`Dumps.discover()` derives five inputs from one path, which is why a pack needs no
incantation.

THE 0xF8000 WINDOW IS BANK 7, NOT THE BIOS TOP. The two images are the same but for one
byte: BANK7.BIN@0x0E90 is 0x00 and BIOS.ROM@0x10E90 is 0x04, the IDE drive bitmap the ITF
writes at BANK4@0x19D4, over a dump-time 0x00. The firmware's own ROM-sum test sums the
window word-wise into two independent 8-bit accumulators and requires both to be zero
(BANK4@0x194-0x1C4), and only BANK7's byte leaves that sum at zero. So the window is built
from BANK7.BIN -- and this is why extracting a pack cannot reproduce the original BIOS.ROM
top half exactly. `extract()` writes the pack's bytes and says so; it does not repair the
byte, which would be inventing data the pack does not hold.

THE IDE SLOT IS 32 KiB BECAUSE IT SERVES TWO WINDOWS, and that is a fact about the machine
rather than about this tool, so it is carried on the region itself and printed by `--list`
(`Region.note`). It is the reason the input is BANK3.BIN and 32 KiB rather than the 8 KiB
the 0xD8000 window alone would need.

THE FONT IS VERBATIM. FONT.ROM is 0x46800 bytes and the pack holds all of it unmodified
(the ANK window is an additional slice out of offset 0x800, not the font's only use), so
the generator's index arithmetic stays RTL's business and extraction is a copy.

THE SOUND.ROM REGION IS A FITTED DEVICE'S ROM, so its 0xFF fill is a STATE and not a
missing input: without the image the 0xCC000 window reads 0xFF, which is exactly what the
machine answers when no PC-9801-86 card is fitted (docs/probes/SHADOW.TXT:150-199: every
2 KiB block of the C-bus area outside the card's 16 KiB reads 0xFF). The image itself is
the user's dump (SOUND.ROM, 16384 bytes; its bytes match all eight of the capture's
sampled blocks), supplied like the rhythm image -- found beside it in --dumps, or named
with --sound -- and the region is therefore `optional` in REGIONS: check_pack warns on
the filler instead of failing it (unlike every other region, whose 0xFF fill can only
mean a missing input).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

# --- the layout's constants, in one place -----------------------------------
PACK_SIZE = 0x100000
BANK_SIZE = 0x8000
BIOS_SIZE = 0x18000
IDE_SIZE = 0x2000            # minimum; the slot is 32 KiB
IDE_SLOT = 0x8000
ANK_SOURCE = 0x800
ANK_SIZE = 0x1000
FONT_OFFSET = 0x80000
FONT_SIZE = 0x46800          # 288,768 B, FONT.ROM's exact size (not 288 KiB)
RHYTHM_OFFSET = 0x49000
RHYTHM_SIZE = 0x2000
SOUND_OFFSET = 0xC6800       # the free tail's start: a fitted -86's option ROM
SOUND_SIZE = 0x4000          # 16 KiB, the 0xCC000-0xCFFFF window verbatim
SOUND_NAME = "SOUND.ROM"
# The dump set's only self-disagreement: BANK7.BIN@0x0E90 vs BIOS.ROM@0x10E90.
BANK7_KNOWN_DIVERGENCE = 0x0E90

# Which bank each named input is, and where each bank's slot begins.
ITF_BANK = 4
IDE_BANK = 3
BANK_OFFSET = {0: 0x31000, 1: 0x39000, 2: 0x41000, 3: 0x70000,
               4: 0x00000, 5: 0x10000, 6: 0x18000, 7: 0x20000}

# The main-BIOS entry vector its top half must carry, and where in the BIOS it sits.
BIOS_ENTRY_VECTOR = bytes.fromhex("ea000080fd")
BIOS_ENTRY_OFFSET = 0x17FF0

# The extracted rhythm image is named for the file it is: the packed 8 KiB YM2608
# ADPCM-A mask ROM, the same image the user passes to --rhythm.
RHYTHM_NAME = "OPNA_ADPCM.ROM"


@dataclass(frozen=True)
class Region:
    """One contiguous run of pack bytes, and what fills it.

    `note` is empty for every region whose placement is obvious from the table, and carries
    the reason when the region has a property a reader could not derive -- the IDE slot's
    two windows, for instance. `--list` prints them, so a fact that explains the layout has
    a home in the tool that owns the layout rather than in prose beside it.

    `optional` marks a region whose 0xFF fill is a valid pack STATE (a fitted device's ROM
    image not supplied: the window reads 0xFF, the machine's own "no card fitted" answer),
    so check_pack warns on the filler where it fails every other region's.
    """

    offset: int
    size: int
    what: str
    source: str
    note: tuple[str, ...] = ()
    optional: bool = False

    @property
    def end(self) -> int:
        return self.offset + self.size


REGIONS: tuple[Region, ...] = (
    Region(0x00000, 0x8000, "ITF slot, bank 4 (the reset vector)", "BANK4.BIN"),
    Region(0x10000, 0x10000, "main BIOS, lower 64 KiB", "BIOS.ROM[0x0000:0x10000]"),
    Region(0x20000, 0x8000, "main BIOS top = the 0xF8000 window, bank 7", "BANK7.BIN"),
    Region(0x30000, 0x1000, "ANK 8x16 window", "FONT.ROM[0x800:0x1800]"),
    Region(0x31000, 0x8000, "extended ROM bank 0", "BANK0.BIN"),
    Region(0x39000, 0x8000, "extended ROM bank 1", "BANK1.BIN"),
    Region(0x41000, 0x8000, "extended ROM bank 2", "BANK2.BIN"),
    Region(0x49000, 0x2000, "YM2608 ADPCM-A rhythm ROM", "--rhythm image; a zero-filled region is NOT silent"),
    Region(0x70000, 0x8000, "IDE option-ROM slot, bank 3", "BANK3.BIN",
           note=("The IDE slot serves BOTH windows, which is why it may be 32 KiB: the",
                 "0xD8000 option-ROM window reads the slot from offset 0 (8 KiB, the value",
                 "of the reset bank the BIOS scans) and the 0xF8000 bank-3 window reads all",
                 "32 KiB (which is how the authentic ITF reaches its own option ROM at",
                 "F800:2000). An 8 KiB image is accepted and the rest is left as padding.")),
    Region(0x80000, 0x46800, "character generator, the whole FONT.ROM", "FONT.ROM"),
    Region(SOUND_OFFSET, SOUND_SIZE, "PC-9801-86 SOUND.ROM window (0xCC000-0xCFFFF)",
           "SOUND.ROM", optional=True,
           note=("The fitted PC-9801-86's 16 KiB option ROM, served read-only at",
                 "0xCC000-0xCFFFF. Without the image the window reads 0xFF,",
                 "the machine's answer when no -86 is fitted, so the fill is a state rather",
                 "than a missing input (see the module docstring).")),
)

# Extraction: output file -> the pack ranges that make it up. BANKn.BIN is that bank's
# slot. BIOS.ROM is its three halves, so its top comes from the bank-7 slot (see the
# module docstring: it differs from the original BIOS.ROM at one byte).
EXTRACTS: tuple[tuple[str, tuple[tuple[int, int], ...]], ...] = tuple(
    (f"BANK{index}.BIN", ((BANK_OFFSET[index], BANK_SIZE),)) for index in range(8)
) + (
    ("BIOS.ROM", ((0x10000, 0x10000), (0x20000, 0x8000))),
    ("FONT.ROM", ((FONT_OFFSET, FONT_SIZE),)),
)


def mem_regions(with_banks: bool) -> tuple[tuple[int, int], ...]:
    """The byte ranges the `.mem` mirror covers, which is what build_pack wrote.

    Without the eight banks the extended area and most of the option-ROM slot are 0xFF
    filler, and the loader writes only what it was given -- so the mirror is narrower
    there, and a fixed list would make the benches simulate a different pack.
    """
    common = ((0x00000, 0x08000), (0x10000, 0x28000), (0x30000, 0x31000))
    tail = ((RHYTHM_OFFSET, RHYTHM_OFFSET + RHYTHM_SIZE),)
    font = ((FONT_OFFSET, FONT_OFFSET + FONT_SIZE),)
    sound = ((SOUND_OFFSET, SOUND_OFFSET + SOUND_SIZE),)
    if with_banks:
        return common + ((0x31000, 0x49000),) + tail + ((0x70000, 0x78000),) + font + sound
    return common + tail + ((0x70000, 0x72000),) + font + sound


# --- reading the dumps ------------------------------------------------------


def exact(path: Path, size: int, label: str) -> bytes:
    data = path.read_bytes()
    if len(data) != size:
        raise SystemExit(f"{label}: {path} is {len(data)} bytes, expected {size}")
    return data


@dataclass(frozen=True)
class Dumps:
    """One machine's ROM images, as files or as directories of files."""

    itf: Path
    bios: Path
    ide: Path
    font: Path
    banks: Path | None = None

    @staticmethod
    def discover(directory: Path) -> "Dumps":
        """One dump directory: BANK0..BANK7.BIN, BIOS.ROM, FONT.ROM.

        The ITF and the IDE option ROM are not extra inputs -- they are BANK4.BIN and
        BANK3.BIN, already in that directory. Names are matched case-insensitively,
        because dump tools disagree about case and a user should not have to.
        """
        if not directory.is_dir():
            raise SystemExit(f"--dumps: {directory} is not a directory")
        found = {entry.name.upper(): entry for entry in directory.iterdir()}

        def need(name: str) -> Path:
            path = found.get(name.upper())
            if path is None:
                raise SystemExit(
                    f"--dumps: {directory} has no {name}. It needs BANK0.BIN.."
                    f"BANK7.BIN, BIOS.ROM and FONT.ROM from one machine."
                )
            return path

        for index in range(8):
            need(f"BANK{index}.BIN")
        return Dumps(itf=need("BANK4.BIN"), bios=need("BIOS.ROM"),
                     ide=need("BANK3.BIN"), font=need("FONT.ROM"), banks=directory)


def parse_mif(text: str, path: Path) -> bytes:
    """A Quartus .mif holding the packed 8 KiB rhythm image.

    Accepts the shape PC88_MiSTer ships (`WIDTH`/`DEPTH`/`ADDRESS_RADIX`/`DATA_RADIX`,
    then `addr : value;` or `[a..b] : value;` entries). A `WIDTH != 8` file is rejected
    with the reason: the six per-instrument files are `WIDTH=4` nibble streams, not this
    ROM, and their counts (894/1284/11902/772/1284/260 = 16,396 nibbles = 8,198 bytes) do
    not concatenate to 8,192 -- repacking them wrongly would misplace every instrument
    after the first.
    """
    def field(name: str) -> str | None:
        match = re.search(rf"^\s*{name}\s*=\s*(\w+)\s*;", text, re.M | re.I)
        return match.group(1).upper() if match else None

    width = int(field("WIDTH") or 0)
    depth = int(field("DEPTH") or 0)
    if width != 8 or depth != RHYTHM_SIZE:
        raise SystemExit(
            f"rhythm: {path} is a MIF with WIDTH={width} DEPTH={depth}; the "
            f"rhythm ROM is the PACKED WIDTH=8 DEPTH={RHYTHM_SIZE} image. A "
            "WIDTH=4 file is one of the six per-instrument nibble streams and "
            "cannot be concatenated into this ROM (see the module docstring)."
        )
    radix = {"HEX": 16, "BIN": 2, "OCT": 8, "DEC": 10, "DECIMAL": 10, "UNS": 10}
    try:
        addr_base = radix[field("ADDRESS_RADIX") or "HEX"]
        data_base = radix[field("DATA_RADIX") or "HEX"]
    except KeyError as exc:
        raise SystemExit(f"rhythm: {path}: unsupported radix {exc.args[0]}")

    body = re.search(r"CONTENT\s+BEGIN(.*?)\bEND\s*;", text, re.S | re.I)
    if body is None:
        raise SystemExit(f"rhythm: {path}: no CONTENT BEGIN ... END; block")
    image = bytearray(RHYTHM_SIZE)
    written = bytearray(RHYTHM_SIZE)
    for statement in body.group(1).split(";"):
        if ":" not in statement:
            continue
        where, value = statement.split(":", 1)
        value = value.strip().split()[0]
        where = where.strip()
        span = re.fullmatch(r"\[\s*(\w+)\s*\.\.\s*(\w+)\s*\]", where)
        if span:
            first, last = (int(span.group(1), addr_base), int(span.group(2), addr_base))
        else:
            first = last = int(where, addr_base)
        data = int(value, data_base)
        for address in range(first, last + 1):
            if address >= RHYTHM_SIZE:
                raise SystemExit(f"rhythm: {path}: entry 0x{address:04X} is past the ROM")
            image[address] = data & 0xFF
            written[address] = 1
    if not all(written):
        missing = written.find(0)
        raise SystemExit(f"rhythm: {path}: address 0x{missing:04X} is not given")
    return bytes(image)


def find_rhythm(directory: Path) -> Path | None:
    """The rhythm image inside a --dumps directory, if the user put one there.

    The directory already holds every other runtime ROM, so a present
    OPNA_ADPCM.ROM is the image the pack should carry; leaving it unused is the way a
    zero-filled rhythm region shipped and became the percussion pop heard on hardware. Matching is
    case-insensitive, as for the other dump names.
    """
    return _find_named(directory, RHYTHM_NAME)


def find_sound(directory: Path) -> Path | None:
    """The PC-9801-86's SOUND.ROM inside a --dumps directory, if the user put one there.

    Same discovery as the rhythm image ("beside OPNA_ADPCM.ROM"): the
    directory already holds every other runtime ROM, and a full dump set carries
    SOUND.ROM beside them.
    """
    return _find_named(directory, SOUND_NAME)


def _find_named(directory: Path, name: str) -> Path | None:
    if not directory.is_dir():
        return None
    found = {entry.name.upper(): entry for entry in directory.iterdir()}
    path = found.get(name.upper())
    return path if path is not None and path.is_file() else None


def load_rhythm(path: Path) -> bytes:
    """The packed 8 KiB rhythm image, as a raw .bin or a Quartus .mif."""
    data = path.read_bytes()
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        text = None
    if text is not None and re.search(r"^\s*(DEPTH|WIDTH|ADDRESS_RADIX|CONTENT)\b",
                                      text, re.M):
        return parse_mif(text, path)
    if len(data) != RHYTHM_SIZE:
        raise SystemExit(
            f"rhythm: {path} is {len(data)} bytes, expected {RHYTHM_SIZE} -- the "
            "packed YM2608 ADPCM-A image (byte N is ROM address N). A .mif of "
            "WIDTH=8 DEPTH=8192 is also accepted."
        )
    return data


# --- building ---------------------------------------------------------------


def build(dumps: Dumps, rhythm: Path | None = None,
          sound: Path | None = None) -> tuple[bytes, list[str]]:
    """The 1 MiB pack, and the advisory notes the caller should print.

    The notes name every place the supplied images disagree with each other, because
    each one is a real property of the pack rather than a complaint: bank 4 IS the ITF
    image, and bank 7 is what the 0xF8000 window holds.
    """
    notes: list[str] = []
    itf = exact(dumps.itf, BANK_SIZE, "ITF")
    bios = exact(dumps.bios, BIOS_SIZE, "BIOS")
    ide = dumps.ide.read_bytes()
    if len(ide) not in (IDE_SIZE, IDE_SLOT):
        raise SystemExit(f"IDE: {dumps.ide} is {len(ide)} bytes, expected "
                         f"{IDE_SIZE} or {IDE_SLOT}")
    ide = ide.ljust(IDE_SLOT, b"\xff")   # an 8 KiB image pads the rest of the slot
    font = exact(dumps.font, FONT_SIZE, "font")

    banks = None
    if dumps.banks is not None:
        banks = [exact(dumps.banks / f"BANK{i}.BIN", BANK_SIZE, f"BANK{i}")
                 for i in range(8)]

    pack = bytearray([0xFF]) * PACK_SIZE
    pack[0x00000:0x08000] = itf
    pack[0x10000:0x20000] = bios[0x00000:0x10000]
    # The 0xF8000 window shows bank 7 at reset, and the ITF's ROM-sum test sums that
    # 32 KiB window requiring a zero 8-bit sum, so the window is built from BANK7.BIN
    # whenever the machine's banks are supplied (see the module docstring). Bank roles
    # follow qemu-pc98's enum, which is the layout the firmware itself assumes: 0 PCI,
    # 1 APIC, 2 BASIC, 3 IDE option ROM, 4 ITF, and 5..7 the 96 KiB main BIOS with bank
    # 7 the bank the 0xF8000 window shows by default. Banks 4..7 therefore already sit
    # in the ITF and BIOS slots filled here, so only 0-3 need placing.
    pack[0x20000:0x28000] = banks[7] if banks is not None else bios[0x10000:0x18000]
    pack[0x30000:0x31000] = font[ANK_SOURCE:ANK_SOURCE + ANK_SIZE]
    # The rhythm ROM: the one user-supplied image. Without it the region is zeros, and
    # zeros are NOT a graceful no-image state: an all-zero ADPCM-A nibble is code 0 at
    # step 0 = a +2 delta per sample, so the decoder's 12-bit accumulator ramps and wraps
    # (a DC-carrying sawtooth cut off at the drum's end) instead of resting. The caller
    # is required to warn about it (build_pack.py); the zero-fill is kept only so the
    # benches and test packs can be built without Yamaha's data.
    pack[RHYTHM_OFFSET:RHYTHM_OFFSET + RHYTHM_SIZE] = \
        load_rhythm(rhythm) if rhythm is not None else bytes(RHYTHM_SIZE)
    # The PC-9801-86's option ROM: 16 KiB at 0xCC000-0xCFFFF, the window the
    # machine answers real code at when the card is fitted (docs/probes/SHADOW.TXT:150-199
    # matches a SOUND.ROM dump at all eight sampled blocks). Without the image
    # the region keeps the pack's 0xFF fill, which is the machine's own "no card fitted"
    # answer -- a state, not a missing input (see the module docstring).
    if sound is not None:
        pack[SOUND_OFFSET:SOUND_OFFSET + SOUND_SIZE] = \
            exact(sound, SOUND_SIZE, "SOUND.ROM")
    pack[FONT_OFFSET:FONT_OFFSET + FONT_SIZE] = font
    # Fixed width: the slice MUST be the whole 32 KiB slot, or the assignment resizes
    # the pack past its 1 MiB reserve.
    pack[0x70000:0x78000] = ide

    if banks is not None:
        if banks[ITF_BANK] != itf:
            notes.append("note: bank 4 is the --itf image, not the supplied BANK4")
        if banks[5] != bios[0x00000:0x08000] or banks[6] != bios[0x08000:0x10000]:
            notes.append("note: BANK5/BANK6 do not match the BIOS halves given as BIOS.ROM")
        if banks[7] != bios[0x10000:0x18000]:
            differing = [i for i in range(BANK_SIZE)
                         if banks[7][i] != bios[0x10000 + i]]
            if differing == [BANK7_KNOWN_DIVERGENCE]:
                notes.append("note: bank 7 is BANK7.BIN; it and "
                             "BIOS.ROM[0x10000:0x18000] differ only at 0x0E90 (the "
                             "0xF8E90 equipment latch), where BANK7's byte keeps the "
                             "0xF8000 window's 8-bit sum zero")
            else:
                notes.append(f"note: BANK7 differs from BIOS.ROM[0x10000:0x18000] in "
                             f"{len(differing)} bytes; the 0xF8000 window still comes "
                             "from BANK7.BIN")
        for bank, offset in ((0, 0x31000), (1, 0x39000), (2, 0x41000)):
            pack[offset:offset + 0x8000] = banks[bank]
        pack[0x70000:0x78000] = banks[IDE_BANK]   # the whole option-ROM window

    problems = vector_problems(bytes(pack))
    if problems:
        raise SystemExit("pack: " + "; ".join(problems))
    return bytes(pack), notes


def vector_problems(pack: bytes) -> list[str]:
    """The reset and entry vectors a pack must carry. No dumps needed.

    check_pack.py runs this on a pack alone, which is what makes a pack verifiable from
    the card without shipping the dumps to it.
    """
    problems = []
    # The reset vector is checked for SHAPE, not for one byte string: any far jump into
    # F800:0000-7FFF is a valid reset, and pinning the exact offset would reject a
    # legitimate ITF that happens to jump elsewhere inside its own bank.
    reset = pack[0x7FF0:0x7FF5]
    if (reset[0] != 0xEA or reset[3:5] != b"\x00\xF8"
            or int.from_bytes(reset[1:3], "little") >= BANK_SIZE):
        problems.append(f"ITF reset vector at 0x7FF0 is {reset.hex()}, not a valid "
                        "jump into F800:0000-7FFF")
    entry = pack[0x20000 + BIOS_ENTRY_OFFSET - 0x10000:
                 0x20000 + BIOS_ENTRY_OFFSET - 0x10000 + 5]
    if entry != BIOS_ENTRY_VECTOR:
        problems.append(f"main-BIOS entry vector is {entry.hex()}, expected "
                        f"{BIOS_ENTRY_VECTOR.hex()}")
    return problems


# --- reading a pack back ----------------------------------------------------


def extract(pack: bytes, out_dir: Path) -> list[tuple[Path, str]]:
    """Write a pack's regions back out as the files a dump set has.

    This is what makes a pack self-sufficient: a test holding only the pack can obtain
    whatever it needs, so no test has to ask for four separate ROM paths.

    Returns (path, note) pairs. The note is non-empty when the file is NOT the original
    dump byte for byte -- BIOS.ROM's top half is the bank-7 slot, so it carries BANK7's
    byte at 0x10E90. Repairing that byte here would be inventing data, so it is named
    instead.
    """
    if len(pack) != PACK_SIZE:
        raise SystemExit(f"extract: pack is {len(pack)} bytes, expected {PACK_SIZE}")
    out_dir.mkdir(parents=True, exist_ok=True)
    written: list[tuple[Path, str]] = []
    for name, ranges in EXTRACTS:
        data = b"".join(pack[start:start + length] for start, length in ranges)
        path = out_dir / name
        path.write_bytes(data)
        note = ""
        if name == "BIOS.ROM":
            note = ("its top half is the pack's bank-7 slot, so byte 0x10E90 is "
                    f"BANK7.BIN's 0x{bank_top_byte(pack):02X}, not an original "
                    "BIOS.ROM's 0x04")
        written.append((path, note))
    rhythm = pack[RHYTHM_OFFSET:RHYTHM_OFFSET + RHYTHM_SIZE]
    if any(rhythm):
        path = out_dir / RHYTHM_NAME
        path.write_bytes(rhythm)
        written.append((path, ""))
    # SOUND.ROM is written only when the pack carries one: the 0xFF fill is the
    # "no card fitted" state, and writing it out would invent a dump the pack does not
    # hold (the same rule as the rhythm image's zero fill).
    sound = pack[SOUND_OFFSET:SOUND_OFFSET + SOUND_SIZE]
    if any(byte != 0xFF for byte in sound):
        path = out_dir / SOUND_NAME
        path.write_bytes(sound)
        written.append((path, ""))
    return written


def bank_top_byte(pack: bytes) -> int:
    """The byte the 0xF8000 window carries at the documented divergence."""
    return pack[0x20000 + BANK7_KNOWN_DIVERGENCE]


# --- the table --list prints ------------------------------------------------


def layout_table() -> str:
    """The layout as text, from REGIONS rather than from prose beside it."""
    lines = [f"PC-98 firmware pack layout ({PACK_SIZE} bytes = "
             f"0x{PACK_SIZE:X})", "",
             f"  {'offset':<10}{'size':<10}{'region':<46}source"]
    for region in REGIONS:
        lines.append(f"  +0x{region.offset:05X}  0x{region.size:05X}   "
                     f"{region.what:<46}{region.source}")
    for region in REGIONS:
        if not region.note:
            continue
        lines.append("")
        lines.append(f"  {region.what} (+0x{region.offset:05X}):")
        lines.extend(f"    {line}" for line in region.note)
    lines.append("")
    lines.append("  Extract any of it with:  build_pack.py --pack PACK --extract DIR")
    lines.append("  Files written:           "
                 + ", ".join(name for name, _ in EXTRACTS)
                 + f", {RHYTHM_NAME} (if set), {SOUND_NAME} (if set)")
    return "\n".join(lines)

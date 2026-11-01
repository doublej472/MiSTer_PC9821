#!/usr/bin/env python3
"""Build the native non-overlapping 1 MiB PC-98 firmware pack, or read one back.

The layout, the dump directory's contents and the rhythm image's format are all stated
in ONE place -- tools/pack_layout.py, which this is a command line over. `--list` prints
that table rather than a copy of it.

    tools/build_pack.py --dumps DIR --out build/pc98pack.bin [--mem build/pc98pack.mem]

ONE input, because one machine's dump directory already holds all of them: BANK4.BIN is
the reset ITF and BANK3.BIN is the IDE option ROM, so naming --dumps names five things at
once (see pack_layout.Dumps.discover). The pack it writes is the only firmware input the
core has: the card loads the .bin and the benches drive the same ioctl interface.

    tools/build_pack.py --pack PCK --extract DIR     # a pack back to dump-shaped files
    tools/build_pack.py --list                       # the layout, from the one table

The explicit form (--itf/--bios/--ide/--font/--banks) still works for anyone already
using it, and is what --dumps resolves to.

The rhythm ROM (--rhythm) is the one region with no dump: the six percussion samples the
YM2608 keeps in its own mask ROM are Yamaha's data, so they are not committed here and
the user supplies the packed 8 KiB image exactly as they supply the BIOS and the font.
When --dumps names a directory that holds OPNA_ADPCM.ROM, that file is used
automatically; a directory without it is diagnosed loudly rather than built quietly.

The PC-9801-86's SOUND.ROM (--sound) is supplied the same way -- Yamaha's data, found
beside OPNA_ADPCM.ROM in --dumps or named explicitly -- and fills the
16 KiB the 0xCC000-0xCFFFF window serves. WITHOUT it the region is 0xFF, which is the
machine's own answer when no -86 card is fitted (docs/probes/SHADOW.TXT:150-199), so
that build is reported but is a valid state -- unlike the rhythm's zero fill below.

AN ALL-ZERO RHYTHM IMAGE IS NOT SILENCE. This was believed ("all-zero ADPCM codes, which
the decoder turns into silence") and a pack built without the image shipped that way,
which is the harsh percussion pop heard on hardware. An ADPCM-A all-zero nibble is code 0 at step
0, i.e. a +2 delta every 18.5 kHz sample, so the decoder's 12-bit accumulator RAMPS and
wraps: the declared drum becomes a DC-carrying sawtooth ending in an abrupt cut, on
every trigger, at every level. The real image decodes to a normal zero-mean percussion
envelope. The region is still zero-filled when no image is named (so test packs can be
built), but that build is reported as a warning with this consequence, not as a
"graceful no-image state". A WIDTH=4 per-instrument .mif is refused with the reason
(pack_layout.parse_mif).

Nothing is committed to the tree: the ROMs are RUNTIME INPUTS, and the policy is stated
in docs/pc9821-port-status.md.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

import pack_layout
from pack_layout import Dumps


def write_mem(pack: bytes, path: Path, with_banks: bool) -> None:
    """The sparse 16-bit readmemh file the benches load.

    Mirrors what was actually written: with the banks, the extended area and the whole
    32 KiB option-ROM window hold data the loader also writes, so a fixed list would make
    the benches simulate a different pack (pack_layout.mem_regions).
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii") as stream:
        for start, end in pack_layout.mem_regions(with_banks):
            stream.write(f"@{start // 2:05x}\n")
            for offset in range(start, end, 2):
                stream.write(f"{pack[offset] | (pack[offset + 1] << 8):04x}\n")


def source(args: argparse.Namespace) -> tuple[Dumps, list[str]]:
    """Which dumps, from --dumps or from the explicit flags."""
    if args.dumps is not None:
        if any((args.itf, args.bios, args.ide, args.font, args.banks)):
            raise SystemExit("give --dumps OR the explicit --itf/--bios/--ide/--font, "
                             "not both: --dumps resolves to exactly those four")
        return Dumps.discover(args.dumps), []
    missing = [name for name in ("itf", "bios", "ide", "font") if getattr(args, name) is None]
    if missing:
        raise SystemExit(
            "give --dumps <one machine's dump directory> (the simple form), or all of "
            "--itf --bios --ide --font; missing: " + " ".join("--" + name for name in missing))
    return Dumps(itf=args.itf, bios=args.bios, ide=args.ide, font=args.font,
                 banks=args.banks), []


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build the 1 MiB PC-98 firmware pack, or read one back.")
    parser.add_argument("--dumps", type=Path,
                        help="ONE machine's dump directory: BANK0.BIN..BANK7.BIN, "
                             "BIOS.ROM and FONT.ROM. THE SIMPLE FORM - it resolves "
                             "--itf, --ide, --bios and --font at once, because BANK4.BIN "
                             "IS --itf and BANK3.BIN IS --ide. One path, no incantation.")
    parser.add_argument("--itf", type=Path,
                        help="the reset ITF bank. This is BANK4.BIN in your dump "
                             "directory, so --dumps already supplies it and you do not "
                             "need this flag - the bank holding it is what makes the "
                             "one-directory form possible.")
    parser.add_argument("--bios", type=Path,
                        help="the main BIOS: BIOS.ROM, 98304 bytes, in your dump directory")
    parser.add_argument("--ide", type=Path,
                        help="the IDE option ROM. This is BANK3.BIN in your dump "
                             "directory, so --dumps already supplies it. 32 KiB, or "
                             "8 KiB (the rest of the slot is padded); the slot serves "
                             "two windows, which --list explains.")
    parser.add_argument("--font", type=Path,
                        help="the character generator: FONT.ROM, 288768 bytes, in your "
                             "dump directory")
    parser.add_argument("--banks", type=Path,
                        help="directory containing BANK0.BIN..BANK7.BIN, the eight "
                             "32 KiB ROM banks of one machine. --dumps is that "
                             "directory, so it supplies this too.")
    parser.add_argument("--out", type=Path,
                        help="the pack to write. This is the file the core loads and "
                             "the benches drive, so it is the whole firmware input.")
    parser.add_argument("--mem", type=Path,
                        help="optional sparse 16-bit readmemh mirror of the pack, for "
                             "the benches; the core itself loads the .bin")
    parser.add_argument("--rhythm", type=Path,
                        help="packed 8 KiB YM2608 ADPCM-A rhythm ROM (.bin, or a "
                             "WIDTH=8 DEPTH=8192 .mif). Yamaha's data, so you supply "
                             "it as you supply the BIOS. When --dumps names a directory "
                             "that holds OPNA_ADPCM.ROM, that file is used "
                             "automatically. WITHOUT an image the region is "
                             "zero-filled, and that is NOT silence: zero ADPCM codes "
                             "decode to a DC-carrying sawtooth on every drum, so the "
                             "build warns loudly and the drums will pop.")
    parser.add_argument("--sound", type=Path,
                        help="the PC-9801-86's 16 KiB SOUND.ROM, served at "
                             "0xCC000-0xCFFFF. Yamaha's data, so you supply "
                             "it as you supply the BIOS. When --dumps names a directory "
                             "that holds SOUND.ROM, that file is used automatically. "
                             "WITHOUT an image the window answers 0xFF, which is the "
                             "machine's own 'no -86 fitted' state.")
    parser.add_argument("--pack", type=Path,
                        help="an existing pack, to extract its regions from (with "
                             "--extract)")
    parser.add_argument("--extract", type=Path,
                        help="with --pack: write its regions back out here as "
                             "dump-shaped files - BANK0.BIN..BANK7.BIN, BIOS.ROM, "
                             "FONT.ROM, and OPNA_ADPCM.ROM / SOUND.ROM when the pack "
                             "carries one - so a pack alone is enough for a test")
    parser.add_argument("--list", action="store_true",
                        help="print the pack layout and exit: every region, what fills "
                             "it, where the file comes from, and why the regions are "
                             "the size they are")
    args = parser.parse_args()

    if args.list:
        print(pack_layout.layout_table())
        return

    if args.pack is not None:
        if args.extract is None:
            raise SystemExit("--pack needs --extract DIR (or use --list for the layout)")
        pack = args.pack.read_bytes()
        for path, note in pack_layout.extract(pack, args.extract):
            size = len(path.read_bytes())
            suffix = f"  -- {note}" if note else ""
            print(f"{path}  {size} bytes{suffix}")
        print(f"extracted {args.pack} (sha256 "
              f"{hashlib.sha256(pack).hexdigest()})")
        return

    if args.out is None:
        raise SystemExit("give --out PACK to build, or --list, or --pack with --extract")
    dumps, notes = source(args)
    rhythm = args.rhythm
    if rhythm is None and args.dumps is not None:
        rhythm = pack_layout.find_rhythm(args.dumps)
        if rhythm is not None:
            print(f"--dumps {args.dumps}: rhythm={rhythm.name} (found in the dump "
                  f"directory; pass --rhythm to override)")
    sound = args.sound
    if sound is None and args.dumps is not None:
        sound = pack_layout.find_sound(args.dumps)
        if sound is not None:
            print(f"--dumps {args.dumps}: sound={sound.name} (found in the dump "
                  f"directory; pass --sound to override)")
    if args.dumps is not None:
        print(f"--dumps {args.dumps}: ITF={dumps.itf.name} IDE={dumps.ide.name} "
              f"BIOS={dumps.bios.name} FONT={dumps.font.name}")
    pack, built_notes = pack_layout.build(dumps, rhythm, sound)
    # "Without an image the rhythm region is zero" is NOT a benign default: zero ADPCM-A
    # codes ramp the decoder's accumulator, so the drums buzz and pop on every trigger.
    # Say so on stderr (a diagnostic, like the notes below) rather than let a pack that
    # makes the percussion sound broken leave the build looking successful.
    if not any(pack[pack_layout.RHYTHM_OFFSET:
                    pack_layout.RHYTHM_OFFSET + pack_layout.RHYTHM_SIZE]):
        print("WARNING: no rhythm image: the pack's ADPCM-A region is all zero, which "
              "is NOT silence -- zero ADPCM codes ramp and wrap, so every drum will "
              "buzz and pop. Pass --rhythm FILE, or put OPNA_ADPCM.ROM in --dumps.",
              file=sys.stderr)
    # A missing SOUND.ROM is a valid state (the machine's own "no -86 fitted" answer),
    # but say so: the reference Xe10 HAS the card, so a silent 0xFF window is usually a
    # build that forgot the image rather than a deliberate choice.
    if all(byte == 0xFF for byte in pack[pack_layout.SOUND_OFFSET:
                                        pack_layout.SOUND_OFFSET + pack_layout.SOUND_SIZE]):
        print("note: no SOUND.ROM image: the 0xCC000-0xCFFFF window answers 0xFF, i.e. "
              "no PC-9801-86 fitted (a valid machine state). Pass --sound FILE, or put "
              "SOUND.ROM in --dumps, to expose the card's option ROM.", file=sys.stderr)
    # Diagnostics, not results: a note says the supplied images disagree somewhere real,
    # and on stdout it would be captured into a build log as though the build had said it.
    for note in notes + built_notes:
        print(note, file=sys.stderr)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(pack)
    if args.mem:
        write_mem(pack, args.mem, with_banks=dumps.banks is not None)

    print(f"{args.out}: {len(pack)} bytes "
          f"sha256={hashlib.sha256(pack).hexdigest()}")
    for region in pack_layout.REGIONS:
        if region.offset in (0x00000, 0x10000, 0x20000, 0x30000, 0x49000,
                             0x70000, 0x80000, pack_layout.SOUND_OFFSET):
            print(f"  +0x{region.offset:05X} 0x{region.size:05X} {region.what}")
    reset = pack[0x7FF0:0x7FF5]
    print(f"reset vector: {reset.hex()} -> "
          f"F800:{int.from_bytes(reset[1:3], 'little'):04X}")


if __name__ == "__main__":
    main()

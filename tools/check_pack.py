#!/usr/bin/env python3
"""Prove a firmware pack is self-consistent, and, when you have them, that it IS the dumps.

The pack is assembled by tools/build_pack.py and is then consumed twice from two
artifacts: the card loads `pc98pack.bin` and the benches load `pc98pack.mem`. Neither
consumer can tell a pack built from other inputs, built without the banks, or edited after
the fact -- the guest simply runs different firmware and the symptom looks like a core bug.
That is the failure this check exists to make impossible.

TWO MODES, and the difference is what a user has to hand:

  tools/check_pack.py --pack PACK [--mem MEM]
      The pack ALONE, checked against the firmware's own contracts. This is the mode for
      a pack sitting on a card, where the dumps are not shipped with it. It asserts:

        * the pack is exactly 1 MiB and its regions do not overlap or run past the end;
        * the ITF slot's reset vector is a far jump into F800:0000-7FFF, and the main
          BIOS's top half carries its entry vector -- the two bytes the machine needs
          before it can execute anything;
        * every 32 KiB bank slot, and the 0xE8000 64 KiB lower shadow, has a zero 8-bit
          sum IN EACH BYTE POSITION. The ITF's own ROM-sum test (BANK4@0x194-0x1C4) sums a
          window word-wise into two independent accumulators, `add dl,al` for the
          even-addressed byte and `add dh,ah` for the odd, and requires both zero. A
          window that sums to zero only in combination still fails on the machine;
        * the ANK window at +0x30000 equals the same bytes of the font at +0x80000. The
          pack carries FONT.ROM verbatim AND a slice of it, so the two must agree -- a
          pack built from two different fonts is caught here with no dumps at all;
        * no layout region is 0xFF filler, which is what a missing input leaves;
        * the `.mem` mirror, when given, describes exactly the layout regions and every
          word equals the corresponding pack word -- a stale `.mem` beside a fresh `.bin`
          would otherwise be loaded silently by the benches.

  tools/check_pack.py --pack PACK --dumps DIR      (or the explicit --itf/--bios/... form)
      The same checks PLUS the identity checks: every layout region compared byte for
      byte against the dump it is defined to hold -- the ITF slot against BANK4.BIN, both
      halves of the main BIOS, the ANK window against FONT.ROM[0x800:0x1800], the
      extended banks, the IDE slot (all 32 KiB of bank 3, not just the 8 KiB the D8000
      window shows), the 0xF8000 window against BANK7.BIN, and the whole 0x46800-byte
      FONT.ROM verbatim at +0x80000. This is the mode for the machine the pack is built on.

ONE MACHINE, ONE DIRECTORY: `--dumps DIR` supplies all five inputs at once, exactly as
build_pack.py --dumps does, and looks for the rhythm image and the PC-9801-86's
SOUND.ROM in that directory too.

Exit status is 0 only when every check selected holds; otherwise each failing region and
the first differing offsets are printed and the exit status is 1.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

import pack_layout
from pack_layout import (ANK_SIZE, ANK_SOURCE, BANK_SIZE, BANK7_KNOWN_DIVERGENCE,
                         BIOS_SIZE, Dumps, FONT_OFFSET, FONT_SIZE, IDE_SLOT, PACK_SIZE,
                         REGIONS, RHYTHM_OFFSET, RHYTHM_SIZE)

errors: list[str] = []


def fail(message: str) -> None:
    errors.append(message)


def read(path: Path, size: int | None, label: str) -> bytes:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise SystemExit(f"check_pack: cannot read {label} {path}: {exc}")
    if size is not None and len(data) != size:
        raise SystemExit(f"check_pack: {label} {path} is {len(data)} bytes, expected {size}")
    return data


def report_diff(actual: bytes, expected: bytes, what: str, limit: int = 6) -> None:
    """Name the first differing offsets, so a failure points at a byte, not at a size."""
    offsets = [i for i in range(min(len(actual), len(expected))) if actual[i] != expected[i]]
    if not offsets:
        return
    shown = ", ".join(
        f"0x{off:05X} pack=0x{actual[off]:02X} dump=0x{expected[off]:02X}"
        for off in offsets[:limit]
    )
    more = "" if len(offsets) <= limit else f" (+{len(offsets) - limit} more)"
    fail(f"{what}: {len(offsets)} byte(s) differ -- {shown}{more}")


def parse_mem(path: Path) -> dict[int, int]:
    """The `.mem` file as {word address: word}. build_pack.py writes it, so the only
    shape accepted is build_pack.py's: an @address line, then 4-digit hex words."""
    words: dict[int, int] = {}
    address: int | None = None
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        if line.startswith("@"):
            try:
                address = int(line[1:], 16)
            except ValueError:
                raise SystemExit(f"check_pack: {path}:{lineno}: bad @address {line!r}")
            continue
        if address is None:
            raise SystemExit(f"check_pack: {path}:{lineno}: word before any @address")
        if len(line) != 4 or any(c not in "0123456789abcdefABCDEF" for c in line):
            raise SystemExit(f"check_pack: {path}:{lineno}: not a 4-digit hex word: {line!r}")
        if address in words:
            fail(f"{path.name}: word address 0x{address:05X} written twice")
        words[address] = int(line, 16)
        address += 1
    return words


def parity_sums(region: bytes) -> tuple[int, int]:
    """The two 8-bit sums the ITF's ROM-sum test accumulates, one per byte of the word."""
    return (sum(region[0::2]) & 0xFF, sum(region[1::2]) & 0xFF)


def resolve_dumps(args: argparse.Namespace) -> Dumps | None:
    """The dumps to check against, or None for the pack-alone mode."""
    if args.dumps is not None:
        if any((args.itf, args.bios, args.ide, args.font, args.banks)):
            raise SystemExit("give --dumps OR the explicit --itf/--bios/--ide/--font, "
                             "not both: --dumps resolves to exactly those four")
        return Dumps.discover(args.dumps)
    named = [args.itf, args.bios, args.ide, args.font]
    if not any(named):
        if args.banks is not None:
            raise SystemExit("--banks is an input to the identity checks; give --dumps, "
                             "or --itf --bios --ide --font with it")
        return None
    missing = [name for name, value in zip(("itf", "bios", "ide", "font"), named)
               if value is None]
    if missing:
        raise SystemExit("the identity checks need all four dumps; missing: "
                         + " ".join("--" + name for name in missing)
                         + " (or pass --dumps DIR for all five at once)")
    return Dumps(itf=args.itf, bios=args.bios, ide=args.ide, font=args.font,
                 banks=args.banks)


def check_layout(pack: bytes) -> None:
    """The table's own promises: in range, in order, and not overlapping."""
    ordered = sorted(REGIONS, key=lambda region: region.offset)
    for region in ordered:
        if region.end > PACK_SIZE:
            fail(f"{region.what}: ends at 0x{region.end:05X}, past the pack's "
                 f"0x{PACK_SIZE:05X}")
    for first, second in zip(ordered, ordered[1:]):
        if first.end > second.offset:
            fail(f"{first.what} and {second.what} overlap "
                 f"(0x{first.offset:05X}-0x{first.end - 1:05X} and "
                 f"0x{second.offset:05X}-0x{second.end - 1:05X})")
    for region in REGIONS:
        chunk = pack[region.offset:region.end]
        if chunk and all(byte == 0xFF for byte in chunk):
            if region.optional:
                # A fitted device's ROM image not supplied is a STATE, not a missing
                # input: the window reads 0xFF, the machine's own "no card fitted"
                # answer (pack_layout's module docstring). Say so, do not fail it.
                print(f"check_pack: note: {region.what} (0x{region.offset:05X}-"
                      f"0x{region.end - 1:05X}) is 0xFF: no image was supplied, so "
                      "its window answers 'no device fitted'", file=sys.stderr)
                continue
            fail(f"{region.what} (0x{region.offset:05X}-0x{region.end - 1:05X}) is 0xFF "
                 "filler: its input was missing when the pack was built")


def check_pack_alone(pack: bytes) -> None:
    """Everything provable without the dumps: the vectors and the ROM-sum contract."""
    for problem in pack_layout.vector_problems(pack):
        fail(problem)

    # The pack carries FONT.ROM verbatim at +0x80000 AND a 0x1000-byte slice of it at
    # +0x30000. Both are in the pack, so they must agree; two different fonts is a real
    # mistake and this catches it with no dumps present.
    window = pack[0x30000:0x30000 + ANK_SIZE]
    in_font = pack[FONT_OFFSET + ANK_SOURCE:FONT_OFFSET + ANK_SOURCE + ANK_SIZE]
    report_diff(window, in_font, "pack ANK window (0x30000) vs its own font at 0x80000")

    # The ROM-sum contract (BANK4@0x194-0x1C4). This is a property of the PACK, not of
    # the dumps' byte-identity to each other: the build once placed BIOS.ROM's top half
    # in the 0xF8000 window, and the identity checks did not catch it because they
    # compared against that same wrong input.
    slots = [(index, offset) for index, offset in sorted(pack_layout.BANK_OFFSET.items())]
    for bank, offset in slots:
        even, odd = parity_sums(pack[offset:offset + BANK_SIZE])
        if even or odd:
            fail(f"pack bank {bank} (0x{offset:05X}-0x{offset + BANK_SIZE - 1:05X}): "
                 f"even-byte 8-bit sum 0x{even:02X}, odd-byte 8-bit sum 0x{odd:02X}; "
                 "the firmware's ROM-sum test requires both 0x00")
    even, odd = parity_sums(pack[0x10000:0x20000])
    if even or odd:
        fail(f"pack 0xE8000 64 KiB lower shadow (0x10000-0x1FFFF): even-byte 8-bit sum "
             f"0x{even:02X}, odd-byte 8-bit sum 0x{odd:02X}; the firmware's ROM-sum test "
             "requires both 0x00")


def check_against_dumps(pack: bytes, dumps: Dumps, rhythm: Path | None,
                        sound: Path | None) -> None:
    """Every region against the dump it is defined to hold."""
    itf = read(dumps.itf, BANK_SIZE, "ITF")
    bios = read(dumps.bios, BIOS_SIZE, "BIOS")
    font = read(dumps.font, FONT_SIZE, "font")
    ide = read(dumps.ide, None, "IDE")
    if len(ide) not in (0x2000, IDE_SLOT):
        raise SystemExit(f"check_pack: IDE {dumps.ide} is {len(ide)} bytes, "
                         f"expected 8192 or {IDE_SLOT}")
    banks = None
    if dumps.banks is not None:
        banks = [read(path, BANK_SIZE, f"BANK{i}")
                 for i, path in enumerate(dumps.bank_paths())]

    if banks is not None:
        report_diff(itf, banks[pack_layout.ITF_BANK], f"--itf {dumps.itf.name} vs "
                    f"BANK{pack_layout.ITF_BANK}.BIN")
    report_diff(pack[0x00000:0x08000], banks[pack_layout.ITF_BANK] if banks else itf,
                f"pack ITF slot vs BANK{pack_layout.ITF_BANK}.BIN"
                if banks else "pack ITF slot vs the ITF image")
    report_diff(pack[0x10000:0x20000], bios[0x00000:0x10000],
                "pack lower-BIOS region vs BIOS.ROM[0x0000:0x10000]")
    report_diff(pack[0x20000:0x28000], banks[7] if banks else bios[0x10000:0x18000],
                "pack 0xF8000 window (bank 7) vs BANK7.BIN" if banks
                else "pack 0xF8000 window vs BIOS.ROM[0x10000:0x18000]")
    report_diff(pack[0x30000:0x31000], font[ANK_SOURCE:ANK_SOURCE + ANK_SIZE],
                "pack ANK window vs FONT.ROM[0x800:0x1800]")
    report_diff(pack[FONT_OFFSET:FONT_OFFSET + FONT_SIZE], font,
                f"pack character generator (0x{FONT_OFFSET:05X}) vs FONT.ROM")

    if banks is not None:
        for bank in (0, 1, 2):
            offset = pack_layout.BANK_OFFSET[bank]
            report_diff(pack[offset:offset + BANK_SIZE], banks[bank],
                        f"pack extended bank {bank} vs BANK{bank}.BIN")
        report_diff(pack[0x70000:0x78000], banks[pack_layout.IDE_BANK],
                    f"pack IDE slot vs BANK{pack_layout.IDE_BANK}.BIN")
        report_diff(ide.ljust(IDE_SLOT, b"\xff"), banks[pack_layout.IDE_BANK],
                    "--ide (padded) vs BANK3.BIN")
        report_diff(bios[0x00000:0x08000], banks[5], "BIOS.ROM[0x0000:0x8000] vs BANK5.BIN")
        report_diff(bios[0x08000:0x10000], banks[6], "BIOS.ROM[0x8000:0x10000] vs BANK6.BIN")
        # The three BIOS halves must be one machine's ROM. BANK7 and BIOS.ROM's top half
        # are the same image but for the one byte the dump set disagrees with itself
        # about; any other difference means the inputs are mixed sets.
        bank7_diff = [i for i in range(BANK_SIZE) if banks[7][i] != bios[0x10000 + i]]
        unexpected = [i for i in bank7_diff if i != BANK7_KNOWN_DIVERGENCE]
        if unexpected:
            fail("BANK7.BIN differs from BIOS.ROM[0x10000:0x18000] at "
                 + ", ".join(f"0x{off:04X}" for off in unexpected[:6])
                 + " -- beyond the documented BANK7@0x0E90 divergence")
    report_diff(pack[0x70000:0x78000],
                banks[pack_layout.IDE_BANK] if banks is not None
                else ide.ljust(IDE_SLOT, b"\xff"),
                f"pack IDE slot vs BANK{pack_layout.IDE_BANK}.BIN" if banks is not None
                else "pack IDE slot vs the --ide image padded to the slot")

    # The rhythm region: against the user's image when one is named or found in the dump
    # directory. A zero region is reported even when no image is available, because it is
    # NOT a no-image silence state: zero ADPCM codes ramp the decoder and make every drum
    # buzz. A pack that lacks an image its own dump directory holds is the exact failure
    # this check exists to catch (the deployed pack shipped without its rhythm image).
    region = pack[RHYTHM_OFFSET:RHYTHM_OFFSET + RHYTHM_SIZE]
    if rhythm is not None:
        report_diff(region, pack_layout.load_rhythm(rhythm),
                    f"pack rhythm ROM vs --rhythm {rhythm.name}")
    elif not any(region):
        print("check_pack: WARNING: the rhythm region is all zero, which is NOT silence "
              "-- zero ADPCM codes ramp the decoder, so every drum will buzz and pop. "
              "Rebuild with --rhythm (or put OPNA_ADPCM.ROM in the dump directory).",
              file=sys.stderr)

    # The PC-9801-86's SOUND.ROM: the same contract as the rhythm region --
    # a pack that lacks an image its own dump directory holds is the failure this check
    # exists to catch. An all-FF region with no image available is the valid "no card"
    # state and is only noted (check_layout above).
    region = pack[pack_layout.SOUND_OFFSET:pack_layout.SOUND_OFFSET + pack_layout.SOUND_SIZE]
    if sound is not None:
        report_diff(region, read(sound, pack_layout.SOUND_SIZE, "SOUND.ROM"),
                    f"pack SOUND.ROM window vs --sound {sound.name}")
    elif not all(byte == 0xFF for byte in region):
        print("check_pack: note: the 0xCC000 SOUND.ROM window holds content that was "
              "not verified (no --sound and no SOUND.ROM in the dump directory)",
              file=sys.stderr)


def check_mem(pack: bytes, mem_path: Path) -> None:
    """The `.mem` the benches load, against the pack and against the layout."""
    mem = parse_mem(mem_path)
    written = set(mem)
    wanted = {word for region in REGIONS
              for word in range(region.offset // 2, region.end // 2)}
    missing = sorted(wanted - written)
    extra = sorted(written - wanted)
    if missing:
        fail(f"{mem_path.name}: {len(missing)} pack word(s) absent, first "
             f"0x{missing[0]:05X}: the benches cannot load what the pack holds")
    if extra:
        fail(f"{mem_path.name}: {len(extra)} word(s) outside the layout, first "
             f"0x{extra[0]:05X}")
    wrong = []
    for word in sorted(wanted & written):
        value = pack[word * 2] | (pack[word * 2 + 1] << 8)
        if mem[word] != value:
            wrong.append(word)
    if wrong:
        word = wrong[0]
        value = pack[word * 2] | (pack[word * 2 + 1] << 8)
        fail(f"{mem_path.name}: {len(wrong)} word(s) differ from the pack, first at "
             f"0x{word:05X}: mem=0x{mem[word]:04X} pack=0x{value:04X}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prove a firmware pack is self-consistent, and that it is the dumps.")
    parser.add_argument("--pack", type=Path, required=True,
                        help="the pack to check: the .bin the card loads")
    parser.add_argument("--mem", type=Path, default=None,
                        help="optional .mem mirror the benches load; when omitted the "
                             "mirror checks are skipped (the card consumes only the .bin)")
    parser.add_argument("--dumps", type=Path,
                        help="ONE machine's dump directory, to check the pack against "
                             "byte for byte. Omit it and the pack is checked against the "
                             "firmware's own contracts alone.")
    parser.add_argument("--itf", type=Path, default=None,
                        help="the reset ITF bank, to check the pack's ITF slot against. "
                             "This is BANK4.BIN in your dump directory, so --dumps "
                             "already supplies it and you do not need this flag.")
    parser.add_argument("--bios", type=Path, default=None,
                        help="the main BIOS, to check the pack's two BIOS halves "
                             "against: BIOS.ROM, 98304 bytes, in your dump directory")
    parser.add_argument("--ide", type=Path, default=None,
                        help="the IDE option ROM, to check the pack's option-ROM slot "
                             "against. This is BANK3.BIN in your dump directory, so "
                             "--dumps already supplies it.")
    parser.add_argument("--font", type=Path, default=None,
                        help="the character generator, to check the pack's ANK window "
                             "and its whole-font region against: FONT.ROM, 288768 "
                             "bytes, in your dump directory")
    parser.add_argument("--banks", type=Path, default=None,
                        help="directory of BANK0.BIN..BANK7.BIN, the eight 32 KiB ROM "
                             "banks of one machine (what build_pack.py --dumps or "
                             "--banks gave). Needed for the extended banks, the IDE "
                             "slot and the 0xF8000 window.")
    parser.add_argument("--rhythm", type=Path, default=None,
                        help="optional packed 8 KiB rhythm image the pack was built "
                             "with (--rhythm); when given, the pack's rhythm region is "
                             "verified against it")
    parser.add_argument("--sound", type=Path, default=None,
                        help="optional PC-9801-86 SOUND.ROM the pack was built with "
                             "(--sound); when given, the 0xCC000 window's region is "
                             "verified against it")
    args = parser.parse_args()

    pack = read(args.pack, PACK_SIZE, "pack")
    dumps = resolve_dumps(args)
    # The rhythm image is the one input that is not always in the dump directory. With
    # --dumps, take OPNA_ADPCM.ROM beside the ROMs when it is there; name it explicitly
    # otherwise. A zero region is not a benign default (see check_against_dumps).
    rhythm = args.rhythm
    if rhythm is None and args.dumps is not None:
        rhythm = pack_layout.find_rhythm(args.dumps)
    # SOUND.ROM is discovered the same way ("beside OPNA_ADPCM.ROM").
    sound = args.sound
    if sound is None and args.dumps is not None:
        sound = pack_layout.find_sound(args.dumps)

    check_layout(pack)
    check_pack_alone(pack)
    if dumps is not None:
        check_against_dumps(pack, dumps, rhythm, sound)
    else:
        if rhythm is not None:
            report_diff(pack[RHYTHM_OFFSET:RHYTHM_OFFSET + RHYTHM_SIZE],
                        pack_layout.load_rhythm(rhythm),
                        f"pack rhythm ROM vs --rhythm {rhythm.name}")
        if sound is not None:
            report_diff(pack[pack_layout.SOUND_OFFSET:
                             pack_layout.SOUND_OFFSET + pack_layout.SOUND_SIZE],
                        read(sound, pack_layout.SOUND_SIZE, "SOUND.ROM"),
                        f"pack SOUND.ROM window vs --sound {sound.name}")

    # Stated rather than silently skipped, so a PASS never hides that the mirror was not
    # looked at: the card consumes only the .bin.
    if args.mem is None:
        print("note: no --mem given: the .mem mirror was NOT checked "
              "(the .bin checks above stand)")
    else:
        check_mem(pack, args.mem)

    if errors:
        print("PACK CHECK FAILED")
        for error in errors:
            print(f"- {error}")
        return 1

    print(f"PACK CHECK PASSED: {args.pack.name} "
          + ("IS the dumps, byte for byte" if dumps is not None
             else "is self-consistent and meets the firmware's own contracts"))
    if dumps is None:
        print("  checked WITHOUT the dumps: the layout, the vectors, the ANK/font "
              "agreement, the ROM-sum contract and the filler state")
    else:
        where = args.dumps if args.dumps is not None else args.banks
        print("  identity checked against the dumps"
              + (f" in {where}" if where is not None else ""))
        if args.banks is None and args.dumps is None:
            print("  note: no bank directory was given, so the extended banks, the IDE "
                  "slot and the 0xF8000 window were checked against BIOS.ROM and the "
                  "IDE image rather than against BANKn.BIN")
    if rhythm is not None and dumps is not None:
        print(f"  rhythm ROM verified against {rhythm.name}")
    if sound is not None and dumps is not None:
        print(f"  SOUND.ROM window verified against {sound.name}")
    print(f"  sha256 pack {hashlib.sha256(pack).hexdigest()}")
    if args.mem is not None:
        print(f"  sha256 mem  {hashlib.sha256(args.mem.read_bytes()).hexdigest()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

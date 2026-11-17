#!/usr/bin/env python3
"""Synthetic, firmware-byte-free tests for external pack/ITF tooling."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def run(*args: object, success: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if (result.returncode == 0) != success:
        raise SystemExit(f"unexpected command result {result.returncode}:\n{result.stdout}")
    return result


def run_split(*args: object, success: bool = True) -> tuple[str, str]:
    """Like run(), but stdout and stderr kept apart.

    A diagnostic printed to stdout is captured into a build log as if it were a result, so
    the two streams are checked separately rather than merged.
    """
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if (result.returncode == 0) != success:
        raise SystemExit(f"unexpected command result {result.returncode}:\n"
                         f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
    return result.stdout, result.stderr


def checksum_zero(data: bytes) -> bytes:
    """Force a zero 8-bit sum in EACH byte position by adjusting the last word.

    The ITF sums a window word-wise into two independent 8-bit accumulators, one
    per byte of the word, and requires both to be zero (BANK4@0x194); every
    32 KiB bank in the real dump set satisfies that, which is the property
    check_pack.py asserts. The synthetic machine has to satisfy it too. The last
    word of a bank lies outside every reset/entry vector the builders validate.
    """
    data = bytearray(data)
    data[-2] = (data[-2] - sum(data[0::2])) & 0xFF
    data[-1] = (data[-1] - sum(data[1::2])) & 0xFF
    return bytes(data)


def main() -> None:
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        source = work / "itfrom.res"
        source.write_text("static const unsigned char itf[] = {\n" +
                          ",".join("0x00" for _ in range(6000)) +
                          "\n};\n", encoding="ascii")
        itf = work / "itf.bin"
        run(ROOT / "tools/build_np2_itf.py", "--source", source,
            "--out", itf)
        itf_data = checksum_zero(itf.read_bytes())
        itf.write_bytes(itf_data)
        assert len(itf_data) == 0x8000
        assert itf_data[5886:5888] == b"\x00\x04"
        assert itf_data[5924] == 0x90
        assert itf_data[0x7FF0:0x7FF5] == bytes.fromhex("ea000000f8")

        bios = bytearray([0xFF]) * 0x18000
        bios[0x17FF0:0x17FF5] = bytes.fromhex("ea000080fd")
        (work / "bios.bin").write_bytes(bios)
        (work / "ide.bin").write_bytes(bytes([0xA5]) * 0x2000)
        # The whole dump: FONT.ROM is 0x46800 bytes and the builder now takes it
        # verbatim (the ANK window is additionally sliced out of offset 0x800).
        font = bytes((index & 0xFF) for index in range(0x46800))
        (work / "font.bin").write_bytes(font)
        pack = work / "pack.bin"
        run(ROOT / "tools/build_pack.py", "--itf", itf,
            "--bios", work / "bios.bin", "--ide", work / "ide.bin",
            "--font", work / "font.bin", "--out", pack)
        packed = pack.read_bytes()
        assert len(packed) == 0x100000
        assert packed[0:0x8000] == itf_data
        assert packed[0x10000:0x20000] == bios[0:0x10000]
        assert packed[0x20000:0x28000] == bios[0x10000:0x18000]
        assert packed[0x30000:0x31000] == font[0x800:0x1800]
        assert packed[0x80000:0x80000 + 0x46800] == font
        assert packed[0x70000:0x72000] == bytes([0xA5]) * 0x2000

        bad_itf = bytearray(itf_data)
        bad_itf[0x7FF0:0x7FF5] = b"\xEA\x00\x80\x00\xF8"
        (work / "bad-itf.bin").write_bytes(bad_itf)
        run(ROOT / "tools/build_pack.py",
            "--itf", work / "bad-itf.bin", "--bios", work / "bios.bin",
            "--ide", work / "ide.bin", "--font", work / "font.bin",
            "--out", work / "bad-pack.bin", success=False)

        # --- tools/check_pack.py, on a synthetic eight-bank machine --------
        # The check's whole job is to fail when the pack is not the dumps, or
        # when it does not carry the firmware's checksum contract, so it is
        # tested here for its PASS and for each failure shape it claims to
        # catch. The synthetic set is self-consistent by construction except for
        # the one byte the real dump set disagrees with itself about, which is
        # planted deliberately: the BIOS top may carry BANK7's partner byte.
        banks_dir = work / "banks"
        banks_dir.mkdir()
        bank_data = [bytes(((bank * 0x11 + index) % 251) for index in range(0x8000))
                     for bank in range(8)]
        bank_data[4] = itf_data
        bank_data[7] = (bank_data[7][:0x7FF0]
                        + bytes.fromhex("ea000080fd") + bank_data[7][0x7FF5:])
        bank_data = [checksum_zero(bank) for bank in bank_data]
        for bank in range(8):
            (banks_dir / f"BANK{bank}.BIN").write_bytes(bank_data[bank])
        top = bytearray(bank_data[7])
        top[0xE90] = (top[0xE90] + 1) & 0xFF      # the BANK7/BIOS.ROM divergence
        real_bios = bank_data[5] + bank_data[6] + bytes(top)
        (work / "real-bios.bin").write_bytes(real_bios)
        (work / "real-ide.bin").write_bytes(bank_data[3])
        real_pack = work / "real-pack.bin"
        real_mem = work / "real-pack.mem"
        run(ROOT / "tools/build_pack.py", "--itf", itf,
            "--bios", work / "real-bios.bin", "--ide", work / "real-ide.bin",
            "--font", work / "font.bin", "--banks", banks_dir,
            "--out", real_pack, "--mem", real_mem)
        # The 0xF8000 window comes from BANK7.BIN, not from the BIOS top: that
        # is the byte the window's 8-bit sum needs.
        assert real_pack.read_bytes()[0x20000:0x28000] == bank_data[7]
        check = ("--pack", real_pack, "--mem", real_mem, "--itf", itf,
                 "--bios", work / "real-bios.bin", "--ide", work / "real-ide.bin",
                 "--font", work / "font.bin", "--banks", banks_dir)
        run(ROOT / "tools/check_pack.py", *check)

        # a hand edit anywhere in the pack: a single wrong byte in the 0xF8000
        # window must fail, and the failure must name the 8-bit sum it breaks
        # (not only the dump-identity diff, which a pack built from the wrong
        # input would report against that same input).
        hand = bytearray(real_pack.read_bytes())
        hand[0x20E90] ^= 0xFF
        (work / "hand-pack.bin").write_bytes(hand)
        result = run(ROOT / "tools/check_pack.py", *
                     (("--pack", work / "hand-pack.bin") + tuple(check[2:])), success=False)
        assert "0xF8000 window" in result.stdout, result.stdout
        win_even = format(sum(hand[0x20000:0x28000:2]) & 0xFF, "02X")
        win_odd = format(sum(hand[0x20001:0x28000:2]) & 0xFF, "02X")
        assert f"even-byte 8-bit sum 0x{win_even}" in result.stdout, result.stdout
        assert f"odd-byte 8-bit sum 0x{win_odd}" in result.stdout, result.stdout

        # The deploy path calls check_pack.py WITHOUT --mem (the card consumes
        # only the .bin, and no mirror sits beside a deployable pack). The .bin
        # checks must still run there, and still fail on a wrong 0xF8000 window
        # -- the exact shape of the stale pc98pack-xe10.bin that reached the
        # card and made the guest flash ROM SUM ERROR.
        result = run(ROOT / "tools/check_pack.py", "--pack", real_pack,
                     "--itf", itf, "--bios", work / "real-bios.bin",
                     "--ide", work / "real-ide.bin", "--font", work / "font.bin",
                     "--banks", banks_dir)
        assert "PACK CHECK PASSED" in result.stdout, result.stdout
        assert "mirror was NOT checked" in result.stdout, result.stdout
        result = run(ROOT / "tools/check_pack.py", "--pack", work / "hand-pack.bin",
                     "--itf", itf, "--bios", work / "real-bios.bin",
                     "--ide", work / "real-ide.bin", "--font", work / "font.bin",
                     "--banks", banks_dir, success=False)
        assert "0xF8000 window" in result.stdout, result.stdout
        assert "pack bank 7" in result.stdout, result.stdout

        # A pack that IS its dumps byte for byte, but whose bank 0 sums to
        # something other than zero: every identity check passes and only the
        # checksum contract fires. This is the shape the real bug had -- the
        # 0xF8000 window was built from the BIOS top, which the old check
        # compared against that same BIOS top, so it passed while the sum the
        # firmware tests did not.
        bad_banks = work / "banks-badsum"
        bad_banks.mkdir()
        for bank in range(8):
            data = bytearray(bank_data[bank])
            if bank == 0:
                data[0x10] ^= 0x01
            (bad_banks / f"BANK{bank}.BIN").write_bytes(bytes(data))
        bad_pack = work / "badsum-pack.bin"
        bad_mem = work / "badsum-pack.mem"
        run(ROOT / "tools/build_pack.py", "--itf", itf,
            "--bios", work / "real-bios.bin", "--ide", work / "real-ide.bin",
            "--font", work / "font.bin", "--banks", bad_banks,
            "--out", bad_pack, "--mem", bad_mem)
        result = run(ROOT / "tools/check_pack.py", "--pack", bad_pack,
                     "--mem", bad_mem,
                     "--itf", itf, "--bios", work / "real-bios.bin",
                     "--ide", work / "real-ide.bin", "--font", work / "font.bin",
                     "--banks", bad_banks, success=False)
        assert "pack bank 0" in result.stdout, result.stdout
        # The byte that moved is at an even offset, so only the even sum moved:
        # the message has to name both positions, which is the contract the ITF
        # checks (`add dl,al` / `add dh,ah`, BANK4@0x194).
        assert "even-byte 8-bit sum 0x01" in result.stdout, result.stdout
        assert "odd-byte 8-bit sum 0x00" in result.stdout, result.stdout
        assert "byte(s) differ" not in result.stdout, result.stdout

        # a pack built without --banks
        no_banks = work / "no-banks-pack.bin"
        no_banks_mem = work / "no-banks-pack.mem"
        run(ROOT / "tools/build_pack.py", "--itf", itf,
            "--bios", work / "real-bios.bin", "--ide", work / "real-ide.bin",
            "--font", work / "font.bin", "--out", no_banks,
            "--mem", no_banks_mem)
        result = run(ROOT / "tools/check_pack.py", "--pack", no_banks,
                     "--mem", no_banks_mem,
                     "--itf", itf, "--bios", work / "real-bios.bin",
                     "--ide", work / "real-ide.bin", "--font", work / "font.bin",
                     "--banks", banks_dir, success=False)
        assert "0xFF filler" in result.stdout, result.stdout

        # a stale .mem, in the two shapes the benches can hit. Both are real,
        # parseable mirrors -- a .mem left over from another build and a .mem of
        # this pack with one word damaged -- so the check has to say so by
        # comparing words. (Handing it the binary pack instead only proved a
        # non-zero exit, which a parse crash on read_text also produces.)
        result = run(ROOT / "tools/check_pack.py", "--pack", real_pack,
                     "--mem", no_banks_mem,
                     "--itf", itf, "--bios", work / "real-bios.bin",
                     "--ide", work / "real-ide.bin", "--font", work / "font.bin",
                     "--banks", banks_dir, success=False)
        assert "word(s) absent" in result.stdout, result.stdout

        stale_mem = work / "stale-pack.mem"
        lines = real_mem.read_text().splitlines()
        for index, line in enumerate(lines):
            if line and not line.startswith("@"):
                lines[index] = format(int(line, 16) ^ 0xFFFF, "04X")
                break
        stale_mem.write_text("\n".join(lines) + "\n")
        result = run(ROOT / "tools/check_pack.py", "--pack", real_pack,
                     "--mem", stale_mem,
                     "--itf", itf, "--bios", work / "real-bios.bin",
                     "--ide", work / "real-ide.bin", "--font", work / "font.bin",
                     "--banks", banks_dir, success=False)
        assert "differ from the pack" in result.stdout, result.stdout

        # --- the rhythm region: the user-supplied 8 KiB ADPCM-A image ------
        # It is optional (no image -> zeros -> silence), and the one source is
        # the user's file (tools/build_pack.py states the rule). Both accepted
        # forms are exercised: the raw packed .bin and a WIDTH=8/DEPTH=8192
        # Quartus .mif. A WIDTH=4 file is one of the six per-instrument nibble
        # streams and must be refused, not silently repacked.
        rhythm = bytes(((index * 7 + 0x11) & 0xFF) for index in range(0x2000))
        (work / "rhythm.bin").write_bytes(rhythm)
        mif_lines = ["WIDTH=8;", "DEPTH=8192;", "", "ADDRESS_RADIX=HEX;",
                     "DATA_RADIX=HEX;", "", "CONTENT BEGIN"]
        mif_lines += [f"  {index:04X} : {value:02X};" for index, value in enumerate(rhythm)]
        mif_lines.append("END;")
        (work / "rhythm.mif").write_text("\n".join(mif_lines) + "\n")

        # with no --rhythm the region is zero-filled, which is the silence state
        assert real_pack.read_bytes()[0x49000:0x4B000] == bytes(0x2000)

        rhythm_pack = work / "rhythm-pack.bin"
        rhythm_mem = work / "rhythm-pack.mem"
        run(ROOT / "tools/build_pack.py", "--itf", itf,
            "--bios", work / "real-bios.bin", "--ide", work / "real-ide.bin",
            "--font", work / "font.bin", "--banks", banks_dir,
            "--rhythm", work / "rhythm.bin",
            "--out", rhythm_pack, "--mem", rhythm_mem)
        assert rhythm_pack.read_bytes()[0x49000:0x4B000] == rhythm
        run(ROOT / "tools/check_pack.py", "--pack", rhythm_pack, "--mem", rhythm_mem,
            "--itf", itf, "--bios", work / "real-bios.bin",
            "--ide", work / "real-ide.bin", "--font", work / "font.bin",
            "--banks", banks_dir, "--rhythm", work / "rhythm.bin")

        # the .mif form must build the identical region
        mif_pack = work / "rhythm-mif-pack.bin"
        run(ROOT / "tools/build_pack.py", "--itf", itf,
            "--bios", work / "real-bios.bin", "--ide", work / "real-ide.bin",
            "--font", work / "font.bin", "--banks", banks_dir,
            "--rhythm", work / "rhythm.mif", "--out", mif_pack)
        assert mif_pack.read_bytes()[0x49000:0x4B000] == rhythm

        # a pack whose rhythm byte changed fails against --rhythm, and names it
        wrong_rhythm = bytearray(rhythm_pack.read_bytes())
        wrong_rhythm[0x49010] ^= 0x01
        (work / "wrong-rhythm-pack.bin").write_bytes(wrong_rhythm)
        result = run(ROOT / "tools/check_pack.py", "--pack", work / "wrong-rhythm-pack.bin",
                     "--itf", itf, "--bios", work / "real-bios.bin",
                     "--ide", work / "real-ide.bin", "--font", work / "font.bin",
                     "--banks", banks_dir, "--rhythm", work / "rhythm.bin",
                     success=False)
        assert "rhythm ROM" in result.stdout, result.stdout

        # one of the six per-instrument nibble files is refused with the reason
        (work / "one-instrument.mif").write_text(
            "WIDTH=4;\nDEPTH=894;\nADDRESS_RADIX=HEX;\nDATA_RADIX=HEX;\n"
            "CONTENT BEGIN\n  000 : 0;\nEND;\n")
        result = run(ROOT / "tools/build_pack.py", "--itf", itf,
                     "--bios", work / "real-bios.bin", "--ide", work / "real-ide.bin",
                     "--font", work / "font.bin", "--banks", banks_dir,
                     "--rhythm", work / "one-instrument.mif",
                     "--out", work / "nibble-pack.bin", success=False)
        assert "WIDTH=4" in result.stdout, result.stdout

        # a raw file of the wrong length is refused
        (work / "short.bin").write_bytes(bytes(100))
        run(ROOT / "tools/build_pack.py", "--itf", itf,
            "--bios", work / "real-bios.bin", "--ide", work / "real-ide.bin",
            "--font", work / "font.bin", "--banks", banks_dir,
            "--rhythm", work / "short.bin", "--out", work / "short-pack.bin",
            success=False)

        # --- the one-directory form, and reading a pack back -------------------
        # The pack is the only firmware input the core has, so the tools take the pack
        # and one dump DIRECTORY rather than four independent ROM paths. That is the
        # point of pack_layout.py: one table, so the builder, the checker and the reader
        # cannot disagree about the file.
        dumps_dir = work / "dumps"
        dumps_dir.mkdir()
        for bank in range(8):
            (dumps_dir / f"BANK{bank}.BIN").write_bytes(bank_data[bank])
        (dumps_dir / "BIOS.ROM").write_bytes(real_bios)
        (dumps_dir / "FONT.ROM").write_bytes(font)

        one_command = work / "one-command-pack.bin"
        one_command_mem = work / "one-command-pack.mem"
        result = run(ROOT / "tools/build_pack.py", "--dumps", dumps_dir,
                     "--out", one_command, "--mem", one_command_mem)
        # ITF=BANK4.BIN and IDE=BANK3.BIN are DERIVED from the directory, so this must
        # be the same pack the explicit five produced, byte for byte.
        assert one_command.read_bytes() == real_pack.read_bytes(), \
            "the one-directory form built a different pack"
        assert one_command_mem.read_bytes() == real_mem.read_bytes(), "mem differs"
        assert "ITF=BANK4.BIN IDE=BANK3.BIN" in result.stdout, result.stdout

        # Dumps.discover matches names case-insensitively, so a directory of lower-case
        # names must build the same pack AND pass check_pack's identity checks: the
        # bank loop once re-opened literal "BANK{i}.BIN" names, which a case-sensitive
        # filesystem does not have.
        lower_dir = work / "dumps-lower"
        lower_dir.mkdir()
        for entry in dumps_dir.iterdir():
            (lower_dir / entry.name.lower()).write_bytes(entry.read_bytes())
        lower_pack = work / "lower-pack.bin"
        run(ROOT / "tools/build_pack.py", "--dumps", lower_dir, "--out", lower_pack)
        assert lower_pack.read_bytes() == real_pack.read_bytes(), \
            "the lower-case dump directory built a different pack"
        result = run(ROOT / "tools/check_pack.py", "--pack", lower_pack, "--dumps", lower_dir)
        assert "identity checked against the dumps" in result.stdout, result.stdout

        # --dumps with a file missing names the file rather than raising a traceback
        partial = work / "partial-dumps"
        partial.mkdir()
        (partial / "BIOS.ROM").write_bytes(real_bios)
        result = run(ROOT / "tools/build_pack.py", "--dumps", partial,
                     "--out", work / "partial.bin", success=False)
        assert "no BANK0.BIN" in result.stdout, result.stdout

        # --list prints the table from the one home rather than from a copy of it, AND
        # it is the HOME of the one fact that explains a region's size rather than its
        # contents: why the IDE slot is 32 KiB. That sentence was removed from README.md
        # and assigned here, so if this assertion ever fails the fact is homeless again.
        result = run(ROOT / "tools/build_pack.py", "--list")
        for what in ("ITF slot", "IDE option-ROM slot", "character generator",
                     "0xF8000 window"):
            assert what in result.stdout, result.stdout
        assert "serves BOTH windows" in result.stdout, result.stdout
        assert "0xD8000 option-ROM window" in result.stdout, result.stdout
        assert "F800:2000" in result.stdout, result.stdout

        # the mismatch notes are DIAGNOSTICS and must not sit on stdout, where a build
        # log would capture them as though the build had produced them. The synthetic set
        # has the real BANK7/BIOS.ROM divergence, so there is a note to place.
        out, err = run_split(ROOT / "tools/build_pack.py", "--dumps", dumps_dir,
                             "--out", work / "streams-pack.bin")
        assert "note:" in err, err
        assert "note:" not in out, out
        assert "sha256" in out, out

        # --extract writes dump-shaped files back out, so a test holding only the pack
        # needs nothing else. The eight banks and the font ARE the originals; BIOS.ROM
        # cannot be, because its top half is the bank-7 slot and BANK7 differs from
        # BIOS.ROM's top at one byte, which is the documented divergence.
        out = work / "extracted"
        result = run(ROOT / "tools/build_pack.py", "--pack", real_pack, "--extract", out)
        for bank in range(8):
            assert (out / f"BANK{bank}.BIN").read_bytes() == bank_data[bank], bank
        assert (out / "FONT.ROM").read_bytes() == font
        extracted_bios = (out / "BIOS.ROM").read_bytes()
        assert len(extracted_bios) == 0x18000
        differing = [i for i in range(0x18000) if extracted_bios[i] != real_bios[i]]
        assert differing == [0x10000 + 0x0E90], [hex(i) for i in differing]
        assert "0x10E90" in result.stdout, result.stdout
        # the divergence is BANK7's byte, i.e. the pack's window byte and not a repair
        assert extracted_bios[0x10E90] == bank_data[7][0x0E90]

        # a pack built with no rhythm image extracts no rhythm file, and one built with
        # an image extracts exactly it
        assert not (out / "OPNA_ADPCM.ROM").exists()
        rhythm_out = work / "extracted-rhythm"
        run(ROOT / "tools/build_pack.py", "--pack", rhythm_pack, "--extract", rhythm_out)
        assert (rhythm_out / "OPNA_ADPCM.ROM").read_bytes() == rhythm

        # --- check_pack.py with the PACK ALONE -------------------------------
        # A pack on a card is checked without shipping the dumps to it, so the checks
        # that need no dumps are the firmware's own contracts. Each must have teeth: a
        # check that cannot fail is not a check.
        result = run(ROOT / "tools/check_pack.py", "--pack", real_pack)
        assert "checked WITHOUT the dumps" in result.stdout, result.stdout
        result = run(ROOT / "tools/check_pack.py", "--pack", real_pack, "--mem", real_mem)
        assert "PACK CHECK PASSED" in result.stdout, result.stdout
        assert "checked WITHOUT the dumps" in result.stdout, result.stdout
        # --dumps must NOT claim to have checked without them
        result = run(ROOT / "tools/check_pack.py", "--pack", real_pack, "--dumps", dumps_dir)
        assert "checked WITHOUT the dumps" not in result.stdout, result.stdout
        assert "identity checked against the dumps" in result.stdout, result.stdout

        # the ANK/font agreement CAN fail: move one byte of the window only
        window_pack = bytearray(real_pack.read_bytes())
        window_pack[0x30010] ^= 0xFF
        (work / "window-pack.bin").write_bytes(window_pack)
        result = run(ROOT / "tools/check_pack.py", "--pack", work / "window-pack.bin",
                     success=False)
        assert "ANK window (0x30000) vs its own font" in result.stdout, result.stdout

        # the vector check CAN fail, and this case ISOLATES it: the two bytes swapped
        # here sit at the same parity, so the ROM-sum contract still passes and the
        # entry vector is the only thing broken. A byte edit would have been caught by
        # the sum check too, which would not have proved this check fires at all.
        entry_pack = bytearray(real_pack.read_bytes())
        entry_pack[0x27FF0], entry_pack[0x27FF2] = (entry_pack[0x27FF2],
                                                    entry_pack[0x27FF0])
        (work / "entry-pack.bin").write_bytes(entry_pack)
        result = run(ROOT / "tools/check_pack.py", "--pack", work / "entry-pack.bin",
                     success=False)
        assert "main-BIOS entry vector" in result.stdout, result.stdout
        assert "ROM-sum test requires" not in result.stdout, \
            "the entry-vector case must not be decided by the sum check: " + result.stdout

        # the ROM-sum contract CAN fail with no dumps at all
        sum_pack = bytearray(real_pack.read_bytes())
        sum_pack[0x31010] ^= 0x01
        (work / "sum-pack.bin").write_bytes(sum_pack)
        result = run(ROOT / "tools/check_pack.py", "--pack", work / "sum-pack.bin",
                     success=False)
        assert "pack bank 0" in result.stdout, result.stdout
        assert "even-byte 8-bit sum 0x01" in result.stdout, result.stdout

        # the size check CAN fail: a pack one byte short is not a pack
        (work / "short-pack.bin").write_bytes(real_pack.read_bytes()[:-1])
        result = run(ROOT / "tools/check_pack.py", "--pack", work / "short-pack.bin",
                     success=False)
        assert "expected 1048576" in result.stdout, result.stdout

    print("TEST_FIRMWARE_TOOLS: PASS")


if __name__ == "__main__":
    main()

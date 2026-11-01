#!/usr/bin/env python3
"""Generate README.md's keyboard table from pc9821_kbd.sv's translate(), so the two cannot drift.

WHAT IT WRITES. The block between `<!-- keymap:begin -->` and `<!-- keymap:end -->` in README.md:
a markdown table with one row per PC key that matters (each key whose PC-98 key differs from its
own label, every PC-98 special key, the keys only one layout maps) and the PC-98 key it gives in
each OSD Keyboard layout, plus one summary row for the keys that give the PC-98 key of their own
name, and a line naming the PC-98 keys no PC key reaches. Every cell is derived from the RTL:
`translate(jis, extended, set2)` parsed from src/pc9821/input/pc9821_kbd.sv, through PC_KEYS (the
set-2 code Main_MiSTer's input.cpp ev2ps2[] sends for each PC key) and PC98_KEYS (NP2kai
keystat.tbl's key numbers, with the symbols the BIOS key table gives unshifted / shifted).

WHAT --check ALSO HOLDS. remap_slot() in the same file - the four set-2 codes whose translation
depends on the layout, which the held-layout record keys on - must name exactly the codes whose
two translations differ; a layout row added without its slot would leave that key stuck across a
layout change. And every set-2 code translate() maps must be a PC key this table knows, so a new
mapping cannot go undocumented.

Usage:
  tools/gen_keymap_table.py           rewrite README.md's block
  tools/gen_keymap_table.py --check   exit 1 when the block, remap_slot() or PC_KEYS disagree
  tools/gen_keymap_table.py --print   print the block
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KBD = ROOT / "src/pc9821/input/pc9821_kbd.sv"
README = ROOT / "README.md"
BEGIN, END = "<!-- keymap:begin -->", "<!-- keymap:end -->"

# PC-98 key number -> the name shown (NP2kai keystat.tbl names; the symbol keys show what the BIOS
# key table gives unshifted and shifted, NP2kai bios/keytable.res = the Xe10 table at BANK7 0x632B).
PC98_KEYS = {
    0x00: "ESC", 0x0B: "`-` `=`", 0x0C: "`^` `` ` ``", 0x0D: "`¥` `|` (`¥` is the `\\` of DOS paths)",
    0x0E: "BS", 0x0F: "TAB", 0x1A: "`@` `~`", 0x1B: "`[` `{`", 0x1C: "RETURN", 0x26: "`;` `+`",
    0x27: "`:` `*`", 0x28: "`]` `}`", 0x30: "`,` `<`", 0x31: "`.` `>`", 0x32: "`/` `?`",
    0x33: "RO: Shift gives `_`", 0x34: "SPACE", 0x35: "XFER", 0x36: "ROLL UP", 0x37: "ROLL DOWN",
    0x38: "INS", 0x39: "DEL", 0x3A: "up", 0x3B: "left", 0x3C: "right", 0x3D: "down",
    0x3E: "HOME/CLR", 0x3F: "HELP", 0x40: "keypad `-`", 0x41: "keypad `/`", 0x45: "keypad `*`",
    0x49: "keypad `+`", 0x4D: "keypad `=`", 0x4F: "keypad `,`", 0x50: "keypad `.`",
    0x51: "NFER", 0x52: "VF1", 0x53: "VF2", 0x54: "VF3", 0x55: "VF4", 0x56: "VF5",
    0x60: "STOP", 0x61: "COPY", 0x70: "SHIFT", 0x71: "CAPS", 0x72: "KANA", 0x73: "GRPH",
    0x74: "CTRL", 0x77: "left Windows", 0x78: "right Windows", 0x79: "APP",
}
for _i, _c in enumerate("1234567890"):
    PC98_KEYS[0x01 + _i] = _c
for _row, _base in (("QWERTYUIOP", 0x10), ("ASDFGHJKL", 0x1D), ("ZXCVBNM", 0x29)):
    for _i, _c in enumerate(_row):
        PC98_KEYS[_base + _i] = _c
for _i in range(10):
    PC98_KEYS[0x62 + _i] = "f･%d" % (_i + 1)
for _code, _n in ((0x42, 7), (0x43, 8), (0x44, 9), (0x46, 4), (0x47, 5), (0x48, 6), (0x4A, 1),
                  (0x4B, 2), (0x4C, 3), (0x4E, 0)):
    PC98_KEYS[_code] = "keypad %d" % _n

# The PC keys in table order: (extended, set2) -> the key's name. The set-2 code is the one
# Main_MiSTer input.cpp ev2ps2[] sends (hps_io normalizes Pause to E0 0x77 and PrintScreen to
# E0 0x7C). `same` marks the keys that give the PC-98 key of their own name, folded into the
# summary row when every layout agrees.
PC_KEYS: list[tuple[tuple[bool, int], str, str | None]] = [
    # (key, the name in the table, the PC-98 name a "same" key must give)
    ((False, 0x76), "Esc", "ESC"),
    ((False, 0x0E), "`` ` `` (JIS: 半角/全角)", None),
    ((False, 0x4E), "`-`", "`-` `=`"),
    ((False, 0x55), "`=` (JIS: `^`)", None),
    ((False, 0x6A), "JIS `¥`", None),
    ((False, 0x66), "Backspace", "BS"),
    ((False, 0x0D), "Tab", "TAB"),
    ((False, 0x54), "`[` (JIS: `@`)", None),
    ((False, 0x5B), "`]` (JIS: `[`)", None),
    ((False, 0x5D), "`\\` (JIS: `]`)", None),
    ((False, 0x5A), "Enter", "RETURN"),
    ((False, 0x58), "Caps Lock", "CAPS"),
    ((False, 0x4C), "`;`", "`;` `+`"),
    ((False, 0x52), "`'` (JIS: `:`)", None),
    ((False, 0x12), "left Shift", "SHIFT"),
    ((False, 0x59), "right Shift", "SHIFT"),
    ((False, 0x41), "`,`", "`,` `<`"),
    ((False, 0x49), "`.`", "`.` `>`"),
    ((False, 0x4A), "`/`", "`/` `?`"),
    ((False, 0x61), "ISO key left of Z", None),
    ((False, 0x51), "JIS `ろ`", None),
    ((False, 0x14), "left Ctrl", "CTRL"),
    ((True, 0x1F), "left Windows", "left Windows"),
    ((False, 0x11), "left Alt", None),
    ((False, 0x67), "JIS 無変換", None),
    ((False, 0x29), "Space", "SPACE"),
    ((False, 0x64), "JIS 変換", None),
    ((False, 0x13), "JIS カタカナ/ひらがな", None),
    ((True, 0x11), "right Alt", None),
    ((True, 0x27), "right Windows", "right Windows"),
    ((True, 0x2F), "Menu", None),
    ((True, 0x14), "right Ctrl", None),
    ((False, 0x78), "F11", None),
    ((False, 0x07), "F12 (opens the MiSTer menu)", None),
    ((True, 0x7C), "Print Screen", None),
    ((False, 0x7E), "Scroll Lock", None),
    ((True, 0x77), "Pause", None),
    ((True, 0x70), "Insert", "INS"),
    ((True, 0x71), "Delete", "DEL"),
    ((True, 0x6C), "Home", None),
    ((True, 0x69), "End", None),
    ((True, 0x7D), "Page Up", None),
    ((True, 0x7A), "Page Down", None),
    ((True, 0x75), "up", "up"),
    ((True, 0x6B), "left", "left"),
    ((True, 0x74), "right", "right"),
    ((True, 0x72), "down", "down"),
    ((False, 0x77), "Num Lock", None),
    ((True, 0x4A), "keypad `/`", "keypad `/`"),
    ((False, 0x7C), "keypad `*`", "keypad `*`"),
    ((False, 0x7B), "keypad `-`", "keypad `-`"),
    ((False, 0x79), "keypad `+`", "keypad `+`"),
    ((True, 0x5A), "keypad Enter", "RETURN"),
    ((False, 0x71), "keypad `.`", "keypad `.`"),
]
# Letters, digits, F1-F10 and keypad digits: their own name, checked like the "same" rows above.
for _c, _code in zip("1234567890", (0x16, 0x1E, 0x26, 0x25, 0x2E, 0x36, 0x3D, 0x3E, 0x46, 0x45)):
    PC_KEYS.append(((False, _code), _c, _c))
for _c, _code in zip("QWERTYUIOPASDFGHJKLZXCVBNM",
                     (0x15, 0x1D, 0x24, 0x2D, 0x2C, 0x35, 0x3C, 0x43, 0x44, 0x4D, 0x1C, 0x1B, 0x23,
                      0x2B, 0x34, 0x33, 0x3B, 0x42, 0x4B, 0x1A, 0x22, 0x21, 0x2A, 0x32, 0x31, 0x3A)):
    PC_KEYS.append(((False, _code), _c, _c))
for _n, _code in enumerate((0x05, 0x06, 0x04, 0x0C, 0x03, 0x0B, 0x83, 0x0A, 0x01, 0x09), 1):
    PC_KEYS.append(((False, _code), "F%d" % _n, "f･%d" % _n))
for _n, _code in ((0, 0x70), (1, 0x69), (2, 0x72), (3, 0x7A), (4, 0x6B), (5, 0x73), (6, 0x74),
                  (7, 0x6C), (8, 0x75), (9, 0x7D)):
    PC_KEYS.append(((False, _code), "keypad %d" % _n, "keypad %d" % _n))

SUMMARY = "Any key not listed: letters, digits, F1-F10, Esc, Enter, Shift, arrows, keypad"


def parse_translate(text: str) -> dict[str, dict[tuple[bool, int], int]]:
    """translate() -> {'us': {(ext, set2): pc98}, 'jis': {...}}; unmapped codes are absent."""
    body = text[text.index("function automatic [7:0] translate"):]
    body = body[:body.index("endfunction")]
    ext_part, _, base_part = body.partition("end else begin")
    tables: dict[str, dict[tuple[bool, int], int]] = {"us": {}, "jis": {}}
    row = re.compile(r"^\s*((?:8'h[0-9A-Fa-f]{2},\s*)*8'h[0-9A-Fa-f]{2}):\s*translate\s*=\s*"
                     r"(?:jis\s*\?\s*8'h([0-9A-Fa-f]{2})\s*:\s*)?8'h([0-9A-Fa-f]{2})\s*;", re.M)
    for ext, part in ((True, ext_part), (False, base_part)):
        for m in row.finditer(part):
            us = int(m.group(3), 16)
            jis = int(m.group(2), 16) if m.group(2) else us
            for k in re.findall(r"8'h([0-9A-Fa-f]{2})", m.group(1)):
                for lay, v in (("us", us), ("jis", jis)):
                    if v != 0xFF:
                        tables[lay][(ext, int(k, 16))] = v
    return tables


def parse_remap_slot(text: str) -> set[tuple[bool, int]]:
    body = text[text.index("function automatic [2:0] remap_slot"):]
    body = body[:body.index("endfunction")]
    return {(False, int(c, 16)) for c in re.findall(r"8'h([0-9A-Fa-f]{2}):\s*remap_slot\s*=\s*3'b1", body)}


def name(code: int | None) -> str:
    """The table cell for a PC-98 key: a `|` is escaped so it does not end the markdown cell."""
    return "nothing" if code is None else PC98_KEYS[code].replace("|", "\\|")


def build(tables) -> tuple[str, list[str]]:
    problems: list[str] = []
    known = {k for k, _, _ in PC_KEYS}
    for lay in ("us", "jis"):
        for k in sorted(set(tables[lay]) - known):
            problems.append(f"translate() maps set-2 {'E0 ' if k[0] else ''}{k[1]:02X} ({lay}), "
                            "which PC_KEYS does not name: add the key to the table")
    rows = []
    folded = []
    for key, label, same in PC_KEYS:
        us, jis = tables["us"].get(key), tables["jis"].get(key)
        if same is not None:
            if us is not None and us == jis and PC98_KEYS.get(us) == same:
                folded.append(label)
                continue
            problems.append(f"{label}: marked as giving {same!r} but gives US {name(us)!r} / "
                            f"JIS {name(jis)!r}")
        rows.append(f"| {label} | {name(us)} | {name(jis)} |")
    reached = set(tables["us"].values()) | set(tables["jis"].values())
    missing = [PC98_KEYS[c] for c in sorted(PC98_KEYS) if c not in reached]
    lines = [
        BEGIN,
        "<!-- generated by tools/gen_keymap_table.py from pc9821_kbd.sv; do not edit by hand -->",
        "",
        "| PC key | PC-98 key, US layout | PC-98 key, JIS layout |",
        "|---|---|---|",
        f"| {SUMMARY} | the same key | the same key |",
        *rows,
        "",
        "No PC key gives " + ", ".join(missing) + ".",
        END,
    ]
    return "\n".join(lines), problems


def main(argv: list[str]) -> int:
    text = KBD.read_text()
    tables = parse_translate(text)
    block, problems = build(tables)
    differ = {k for k in set(tables["us"]) | set(tables["jis"])
              if tables["us"].get(k) != tables["jis"].get(k)}
    slots = parse_remap_slot(text)
    if differ != slots:
        problems.append("remap_slot() names %s but the rows that differ between the layouts are %s"
                        % (sorted(slots), sorted(differ)))
    if "--print" in argv:
        print(block)
        return 0
    readme = README.read_text()
    if BEGIN not in readme or END not in readme:
        problems.append(f"README.md has no {BEGIN} ... {END} block")
        new = readme
    else:
        head, rest = readme.split(BEGIN, 1)
        new = head + block + rest.split(END, 1)[1]
    if "--check" in argv:
        if new != readme:
            problems.append("README.md's keyboard table is stale: run tools/gen_keymap_table.py")
        for p in problems:
            print("FAIL:", p)
        print("KEYMAP TABLE: " + ("FAIL" if problems else "PASS (README table, remap_slot and "
                                  "PC_KEYS agree with translate())"))
        return 1 if problems else 0
    if problems:
        for p in problems:
            print("FAIL:", p)
        return 1
    if new != readme:
        README.write_text(new)
        print("wrote README.md's keyboard table")
    else:
        print("README.md's keyboard table is current")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

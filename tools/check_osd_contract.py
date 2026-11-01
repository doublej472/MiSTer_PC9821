#!/usr/bin/env python3
"""The OSD's option strings and the RTL that decodes them are one contract, stated twice.

WHY THIS IS A PYTHON CHECK AND NOT A VERILATOR BENCH. The fact being checked is not a
signal level - it is SOURCE TEXT. The user sees the option list in z486_mister.sv's
CONF_STR; pc9821_osd.sv maps a LIST POSITION to a size code; pc9821_system.sv maps that
code to a byte count. The failure this guards is those three drifting apart, and a
Verilator bench cannot read a string literal or a case-statement, so the existing
tb_pc9821_osd.sv necessarily restates all three in hand-written arrays and checks the
module against a COPY of the intent. Its own comment even carries the option string,
which is the tell: a comment is where a fact goes when nothing can check it.

That is not a criticism of that bench, which is a good bench and pins things this check
cannot reach (the permutation, the polarity, the default). It is a statement of what it
cannot see: if the CONF_STR list is reordered and the module is not, the bench stays
green and the OSD shows one size while the guest gets another. Which is the exact
shape of the defect that reached a real card and froze it - a card with no config
file passes 0 for every field, 0 meant 1 MB, and a 1 MB guest cannot boot the Xe10 BIOS.

So this parses the files and asserts they agree. Nothing here is a copy: every expected
value is read out of the RTL, so a change to any one of them fails until the others move
with it.

WHAT IT COVERS NOW, AND WHY EVERY `O` FIELD RATHER THAN THE THREE THAT MATTERED.
The first version of this file parsed three fields: RAM Size, VSync and the Machine
(BIOS-set) field. `O[3]` - Enter BIOS setup (hold HELP) - was covered by NOTHING: not its
label, not its two options, not that position 0 is Off, not that status[3] reaches a
consumer. The only guard it had was tb_pc9821_osd.sv, which hand-copies the intent - the
circularity this file was written to break. A gate with one field outside it is a gate
that reports PASS about a contract nobody checked, so the coverage is now:

  1. every CONF_STR field that names status bits is parsed, bracketed or not - the parse
     is scoped to the `localparam CONF_STR = { ... };` block, because a quoted entry in a
     COMMENT used to be parsed as a second field of the same kind (`S1,D88FDDHDM,FDD0;`
     beside the floppy wiring was a phantom root-menu member);
  2. every declared `O` field's bits are READ by the core (a field wired to nothing is
     declared-but-dead, and that is invisible to every Verilog tool);
  3. that read REACHES a consumer: a read that is a module-port connection must be read
     inside the module that declares the port, one hop - which is the check that would
     have caught `O[3]` being wired to a port its module ignored;
  4. no two declared fields share a bit (and no option field shares one with an `R`/`T`
     action field) - the general form of the guard the Machine field once needed;
  5. each field's POSITION 0 is the value the measured machine has, from a table that
     names the reference (`FIELD_DEFAULT`); a new field with no entry is a FAILURE, not a
     silent pass, because position 0 is what a card with no config file gets;
  6. the option count fits the field's width, every `O` field's label is non-empty, and
     the RAM Size list, the position->code mapping and the code->bytes table still agree
     (the original RAM Size contract, unchanged);
  7. THE SUB-PAGE TAGS agree with the pages: a `P{#}` already belongs before the option
     letter it scopes (`P1O[32]`, which is what Template_MiSTer and PCXT_MiSTer ship and
     what the framework's own `d5P1o2` example states), and the complaint this
     answers was about WHERE a setting appears, so the gate has to see the grouping: every page a field
     or separator is filed under must be DECLARED by a `P{n},Title` entry, every declared
     page must have something in it, page 0 (the root menu) is not a page, and a page tag
     written AFTER the field it scopes is rejected rather than silently read as a field
     with a tag in its name. The Field the parse produces keeps `bitspec` (the bits, which
     is what FIELD_DEFAULT is keyed by) apart from `spec` (the entry as spelled), so moving
     a field between pages cannot silently drop it out of the default table;
  8. THE ROOT MENU'S LAYOUT is the one ROOT_LAYOUT states (the owner's order): the firmware
     pack's Load first, then the drives - each Mount directly followed by its own Eject, HDD,
     CD-ROM, FDD1, FDD2 - then RAM Size, CPU Speed and Keyboard as one group, the DIP Switch page, the
     video options, and Reset last, each group set off by a separator. Every Mount has its
     Eject, wired to that Mount's hps_io slot.

WHAT IT DELIBERATELY DOES NOT DO. It does not require that every status bit the RTL reads
be declared: this core reads a set of bits no OSD entry declares on purpose (the
gameport's controls and the hot-swap flag among them), and a check that demanded it would fail on the
honest tree. It also does not police the framework's own reserved bits ([3:1]'s menu
background index, [4]'s palette bit): `sys/**` is frozen, the framework only writes those
while `is_menu()` is true - i.e. while the MENU core, not this one, is loaded - and the
house reference (ao486_MiSTer) declares fields on those same bits, so a blanket guard
there would fail the reference.

Exit 0 when the contract holds; non-zero, naming the disagreement, when it does not.

Usage:
  tools/check_osd_contract.py             check the tree; exit 1 on any violation
  tools/check_osd_contract.py --selftest  plant each class of violation in memory and
                                          require every one to be rejected (a check that
                                          cannot fail is the defect this file exists to
                                          find, so the guard carries its own mutant set)
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOP = ROOT / "z486_mister.sv"
OSD = ROOT / "src/pc9821/core/pc9821_osd.sv"
SYSTEM = ROOT / "src/pc9821/core/pc9821_system.sv"
# The ONE hardware-switch field's POSITION -> switch-field table. It lives at the point of
# use (pc9821_text_mem, which owns the TRAM the cell sits in) and not in pc9821_osd, because the
# field's port carries a LIST POSITION all the way down: position 0 has to mean the measured
# machine there too, so that an undriven port is the captured machine. The 0xA3FEA base-memory
# code is HARDCODED to 640 KB in pc9821_text_mem and has no OSD field, so it has no table here.
CRTC = ROOT / "src/pc9821/core/pc9821_text_mem.sv"
# The CPU Speed field's POSITION -> RATE table: cpu_throttle's rate_khz() in the vendored z486
# (the fork owns it). The OSD labels are plain rates, so each label must name the rate its
# position selects - the label-vs-rate drift the cpu-speed table checker guarded before the
# field was withdrawn on 2026-09-27; it was deleted with the field.
THROTTLE = ROOT / "src/z486/cpu_throttle.sv"

# Where a module-port consumer may be found. src/ is this core's RTL and sys/ the frozen
# framework it sits in (hps_io is reached that way); build trees are never scanned.
RTL_DIRS = (ROOT / "src", ROOT / "sys")

# --- the one status-bit fact that is a table rather than a parse ------------------
#
# POSITION 0 IS THE CONFIG-LESS CARD. The framework passes option index 0 for a field
# when the core has no stored config and CONF_STR has no syntax for a default, so position
# 0 is the machine the core is when nobody has configured it - and the reference for each
# entry below is the MACHINE, not a preference. A field with no entry is a failure: a new
# field's default has to be justified against the reference by whoever adds it, and an
# unregistered default is exactly the "nobody checked" state this file exists to remove.
FIELD_DEFAULT: dict[str, tuple[str, str]] = {
    "O[63:61]": (
        "16M",
        "the project's default and the machine's usable size: a 1 MB guest cannot run the "
        "Xe10 BIOS at all (a card booted that way freezes)",
    ),
    "O[31:28]": (
        "Xe10",
        "the MEASURED PC-9821Xe10 port-0xF0 strap 0xA9 (docs/probes/PORTS.TXT "
        "`00F0 A9`), so a config-less card answers what the captured machine answers",
    ),
    "O[32]": (
        "2.5 MHz",
        "the MEASURED PC-9821Xe10 port-0x31 strap 0xF3, whose bit 7 SET the BIOS reads as "
        "the 2.5 MHz GDC clock (docs/probes/PORTS.TXT `0031` = 0xF3; BIOS.ROM@0xFD93C copies "
        "it into work-area 0x54D bit 5, and the display-mode setter derives the games' bit 2 "
        "from that), so a config-less card answers the captured machine's clock",
    ),
    "O[38]": (
        "Auto",
        "both positions exist on the machine (MAME pc9801.cpp fdc_mode_r `(m_dsw3->read() & 3) "
        "<< 2`, DSW3:1 Fixed / Auto-Detection; the measured unit is Fixed, docs/probes/"
        "FDMODE-XE10.TXT `PORT 00BE=FF`); Auto by design decision because with "
        "Fixed POST leaves the 640 KB floppy interface uninitialised and a 2DD boot disk "
        "that addresses it gets no drive",
    ),
    "O[17:14]": (
        "Full",
        "the CPU at the profile's own clk_sys rate, ungated: position 0 makes cpu_throttle's "
        "cpu_ce constant 1, so a config-less card runs the cycle-identical full-speed core the "
        "boot golden and Dhrystone are pinned on",
    ),
    "O[3]": (
        "Off",
        "the machine enters SETUP only while HELP is held at POST; a config-less card "
        "must POST normally (the ITF writes 0x7FDD/0x7FDF but never reads Port C)",
    ),
    "O[51]": (
        "US",
        "the host keyboard's layout, not a machine setting: the machine's own keyboard is JIS "
        "and no host key changes its key numbers, only which PC key gives which. US is the "
        "layout the core translated the backslash key in before the option existed (set-2 0x5D "
        "-> YEN, the DOS path separator), so a config-less card keeps it",
    ),
    "O[23:22]": (
        "Original",
        "the machine's own raster, unstretched - the picture a real monitor shows",
    ),
    "O[81:80]": (
        "Native 24kHz",
        "the machine's own 24.8 kHz raster on the analog port, as the PC-9821's monitor connector "
        "carries it (pc9821_crtc's SYNC-block raster); doubling or TV conversion is a choice the "
        "user's display makes (MiSTer.ini forced_scandoubler=1 turns the doubler on from Native)",
    ),
    "O[83:82]": (
        "None",
        "the machine draws no scanlines: the darkening is a display effect on the doubled picture",
    ),
    "O[46:45]": (
        "Normal",
        "1:1 scaling: the machine's own pixel count, the framework's only neutral option",
    ),
    "O[66:64]": (
        "0 dB",
        "not a machine setting but the user's CD-DA level, like the volume wheel on a real CD "
        "drive (the drive's line level against the FM is uncaptured, todo item 106): 0 dB is "
        "the owner's choice (2026-10-31), unity, the level the CD-DA channel shipped at before "
        "the field existed - the clipping that had prompted a -6 dB default was a wrong-rail "
        "clamp in the output FIR (tb_pc9821_audio_out_sat), not a level problem. NP2kai's "
        "default CD-DA level stays a step of the list: davolume 128 of 255 (sdl/ini.c:704, "
        "applied as davolume/255 in cbus/ideio.c:1738-1740), 20*log10(128/255) = -5.99 dB",
    ),
    "O[42:40]": (
        "Auto",
        "the MEASURED PC-9821Xe10 memory-switch byte 0xA3FF2 = 0x01 carries nibble 0, and "
        "the authentic BIOS's own boot helper treats that as its `jz` class - keep the mode "
        "the FDC controller reports (BANK7@0x598C-0x5999: `mov bx,0xa000 / mov es,bx / mov "
        "ah,[es:0x3ff2] / and ah,0xF0 / jz`), which is what a config-less card must boot. "
        "The field moved here from O[34:33] when the list grew past three entries (the "
        "2-bit field could not hold seven options and widening in place would have stolen "
        "the (now-removed) Base memory field's bit 35); a saved config stores 0 at these "
        "bits, so an old setting "
        "falls back to this entry - the measured machine - instead of re-mapping to another "
        "one, which is the same shape as an undriven port",
    ),
}

# --- the option LABEL <-> encoded VALUE contracts that are tables, not parses ----------
#
# The checks below compare a field's POSITION->CODE table (pc9821_osd.sv) against the
# user-facing label in z486_mister.sv. That comparison is the one thing no other check in
# this file can make: the RAM Size block at the end of this file has done it for one field
# since the 1 MB freeze, and these two carry the same contract for the hardware switches,
# where a swapped pair of labels is a wrong MACHINE DESCRIPTION and not a preference.
# Every value here comes from a reference, never from the RTL.

# O[42:40],Boot order: the high nibble of the memory-switch cell 0xA3FF2 - the BOOT/FDD
# nibble. Positions 0..2 keep the three values the authentic BIOS's boot helper distinguishes
# (BANK7@0x5991-0x59A9: compare against 0x20 and 0x40, keep the controller's own mode
# otherwise; NP2kai bios.c:254: `mem[MEMB_MSW5] & 0xf0`, "!= 0x20" is the 1 MB case, 0x20 the
# 640 KB one). Positions 3..6 append NP2kai's boot-device codes for the same nibble
# (bios1b.c:883-926 `switch (mem[MEMB_MSW5] & 0xf0)`: 0x60 MO, 0xa0 SASI 1, 0xb0 SASI 2,
# 0xc0 SCSI) - the primary software reference's names for those switch positions. THE
# DIVERGENCE is real and lives in the RTL's comment and the report: the real Xe10 firmware
# does not select a boot device from this nibble (its boot helper keeps the controller's FDD
# mode for every value but 0x20/0x40, and NP2kai's own switch comment at bios1b.c:883 says
# the value should really arrive in the AL register), so this table pins the ENCODING the
# reference names, not a claim that the machine boots MO/SASI/SCSI from it.
FDD_NIBBLE: dict[str, int] = {
    "Auto": 0x0, "640K": 0x2, "1M": 0x4, "MO": 0x6, "SASI1": 0xa, "SASI2": 0xb, "SCSI": 0xc,
}

# O[66:64],CD audio volume: each option's LABEL against the pc9821_audio_volume gain code
# pc9821_osd.sv maps its position to. The code scale is that module's gain table, 0 dB at code 31
# and 2 dB per code (pc9821_audio_volume.sv's gain_lut), so "-N dB" is code 31 - N/2, and "Off"
# is code 0, the table's exact zero. A label whose code is not this is a volume the menu
# misnames.
def cd_volume_label_code(label: str) -> int | None:
    """'-6 dB' -> 28, '0 dB' -> 31, 'Off' -> 0; None for a label that names no gain step."""
    if label == "Off":
        return 0
    m = re.fullmatch(r"(-?)(\d+) dB", label)
    if not m:
        return None
    n = int(m.group(2))
    if (m.group(1) == "" and n != 0) or n % 2 or n > 60:
        return None
    return 31 - n // 2


# THE DIP SWITCH PAGE. The requirement: all DIP/configuration
# handling lives in the `P1,DIP Switch` sub-page. The ports below are the ones the top level
# wires the DIP page's fields into - the status[] read at the connection (`osd_bios_setup`,
# `osd_gdc_clock`, `osd_fdd_mode` - the FDD-mode switch, O[38] - and `cfg_fdd_mode` - the Boot
# order, whose name only resembles it) or the port itself where the field's bits
# are read straight off status[] (`bios_set`) - so a field that reaches one of them IS a DIP
# field and must be filed under that page. A new switch field dropped into the root menu, or
# an existing one moved out, is a contract change this catches. (`sdip_restore`/`sdip_zero`
# left this list when the `Reset DIPs`/`Zero DIPs` actions were removed entirely, and
# `cfg_base_mem` left when the base memory was hardcoded to 640 KB.)
DIP_PAGE = 1
DIP_PORTS = ("bios_set",
             "osd_bios_setup", "osd_gdc_clock", "osd_fdd_mode", "cfg_fdd_mode")

problems: list[str] = []


def note(msg: str) -> None:
    problems.append(msg)


# --- source text -------------------------------------------------------------------

def slurp(path: Path) -> str | None:
    """The file's text, or None. A missing file is a failure, never a silent pass."""
    try:
        return path.read_text(errors="replace")
    except OSError:
        return None


def strip_comments(text: str) -> str:
    """Comments removed, newlines kept so a reader's line still means the same line.

    A DECLARED-BUT-UNREAD FIELD IS A FACT ABOUT THE RTL, NOT ABOUT ITS PROSE: this file's
    own docstrings, the CONF_STR commentary and half the tree's module headers mention
    `status[5]`/`status[6]` and would otherwise count as consumers.
    """
    text = re.sub(r"/\*[\s\S]*?\*/", lambda m: "\n" * m.group(0).count("\n"), text)
    return re.sub(r"//[^\n]*", "", text)


# --- CONF_STR: every entry, and the bits each one names ----------------------------

# Every quoted string in CONF_STR is one entry (the last one may carry no `;`). The
# framework also has entries that do NOT name status bits - the core name, `-` separators,
# file slots (F0/S0), joystick bits (J), info text (I) - so only a field whose spec is a
# single kind letter (optionally bracketed, optionally digit-suffixed) with a comma after
# it is treated as a bit field.
ENTRY = re.compile(r'"([^"]*)"')
BRACKETED = re.compile(r"^([A-Za-z])\[(\d+)(?::(\d+))?\]$")
DIGITS = re.compile(r"^([A-Za-z])(\d+)$")
BARE = re.compile(r"^([A-Za-z])$")

# THE SUB-PAGE TAG. `P{n}` is the framework's display grouping: `P2,Title` opens a page and
# every entry whose spec carries the `P{n}` tag is listed under it. It moves NO status bit,
# so it changes nothing this file checks about BITS - but it does change what the parser
# sees, and a spec it cannot read is a field it would silently stop covering.
PAGE_PREFIX = re.compile(r"^P(\d+)")
PAGE_TAG = re.compile(r"P(\d+)")
# The letters that introduce a real field or action inside a spec token. A `P{n}` tag that
# follows one of them is the order the framework's own documentation calls INCORRECT
# ("d5P1o2,..." is right, "P1d5o2,..." is not): the tag must come before the option/file
# letter it scopes, though digit specs may precede it (Template.sv's "d0P1F1,BIN;").
KIND_LETTERS = "OTRSFIJVH"

# The kinds that name STATUS BITS, and the framework's spelling rule for them: a
# BRACKETED field is read as written (`O[63:61]` is bits 61..63), an UNBRACKETED one is
# per-digit and a LOWERCASE letter adds 32 (`oDE` is bits 45,46 - ao486's Scale field).
# The kinds with no bits at all (F/S slots, J joystick bits, I info text, V version) are
# listed here so the parser can ignore them on purpose rather than by accident.
BIT_KINDS = "ORT"


class Field:
    def __init__(self, spec: str, kind: str, bits: set[int], width_hi: int | None,
                 label: str, options: list[str], page: int | None = None) -> None:
        self.spec = spec            # as CONF_STR spells it, page tag and all
        self.kind = kind
        self.bits = bits
        self.hi = width_hi
        self.label = label
        self.options = options
        # The `P{n}` sub-page, or None for the root menu. DISPLAY GROUPING ONLY: the page
        # is not part of the field's identity, so FIELD_DEFAULT is keyed by `bitspec`.
        self.page = page

    @property
    def bitspec(self) -> str:
        """The spec without its page tag: what names the STATUS BITS, e.g. `O[32]`."""
        return PAGE_PREFIX.sub("", self.spec, count=1)

    @property
    def is_option(self) -> bool:
        return self.kind.upper() == "O"

    @property
    def name(self) -> str:
        """The field as CONF_STR spells it, which is how the messages name it."""
        return self.spec

    def lo_hi(self) -> tuple[int, int]:
        return min(self.bits), max(self.bits)


CONF_BLOCK = re.compile(r"localparam\s+CONF_STR\s*=\s*\{(.*?)\n\};", re.S)


# A profile-rewritten CONF_STR LINE: `localparam NAME = "...";` (CONF_STR_CD, CONF_STR_VIDEO),
# spliced into the block by name because a string cannot be built conditionally.
STRING_PARAM = re.compile(r'^\s*localparam\s+(\w+)\s*=\s*"([^"]*)"\s*;', re.M)
# The header is the framework's FIRST element (the core name and the UART/MIDI declaration),
# not menu entries, so it is never spliced in as entries.
NOT_ENTRIES = {"CONF_STR_HEADER"}


def conf_str_region(text: str) -> str:
    """The CONF_STR literal's own text - the block the framework reads.

    THE PARSE IS SCOPED TO THIS BLOCK, NOT TO THE FILE. Every other quoted string in
    z486_mister.sv is prose in a comment, and one of them quotes a real entry
    ("S1,D88FDDHDM,FDD0;" beside the floppy-slot wiring): parsed as CONF_STR it became a
    SECOND S1 field, i.e. a phantom member of the root menu, and the page checks this file
    now carries would report pages and fields the user never sees. The block is the
    contract, so the block is what is parsed; the full text is still what `status_reads`
    (comment-stripped) searches for the RTL side.
    """
    m = CONF_BLOCK.search(text)
    region = m.group(1) if m else text
    # COMMENTS ARE PROSE: a comment inside the block that quotes an entry (the profile-rewritten
    # lines are described that way) would otherwise parse as a phantom entry of the menu.
    region = strip_comments(region)
    # THE PROFILE-REWRITTEN LINES ARE PART OF THE MENU. A bare identifier in the block is a
    # string localparam (CONF_STR_CD, CONF_STR_VIDEO); its value is spliced in one quoted
    # entry per `;`, as the framework reads it, so the CD's mount and eject - which exist only
    # in every preset since 2026-10-10 and are absent from a --no-cdrom build - are checked
    # exactly as the tree is configured.
    params = {k: v for k, v in STRING_PARAM.findall(strip_comments(text))}

    def splice(mm: re.Match) -> str:
        name = mm.group(1)
        if name in NOT_ENTRIES or name not in params:
            return mm.group(0)
        entries = [e for e in params[name].split(";") if e]
        return "".join(f'"{e};",' for e in entries)

    return re.sub(r"(?m)^\s*([A-Z_][A-Z0-9_]*)\s*,", splice, region)


UNREADABLE_HINT = (
    " Use the bracketed spelling (O[63:61]), the plain digit spelling (O12), a page "
    "definition (P1,Title), a page separator (P1-), or a page tag that comes first "
    "(P1O[63:61]) - a spec this check cannot read is a field it stops covering."
)


def conf_str_fields(text: str) -> tuple[list[Field], list[str], dict[int, str]]:
    """Every bit-naming CONF_STR field, the messages for what it could not read, and pages.

    The pages come back as {number: title}. A `P{n},Title` entry DEFINES page n; a bare
    `P{n}-` (with a label) is a separator inside it; a field's tag REFERENCES it. A page
    reference with no definition, or a definition nothing is filed under, is a defect this
    parser reports rather than a spelling it tolerates - the user sees the page either way.
    """
    fields: list[Field] = []
    unreadable: list[str] = []
    pages: dict[int, str] = {}
    referenced: dict[int, str] = {}
    for m in ENTRY.finditer(text):
        body = m.group(1)
        if "," not in body:
            continue
        spec, rest = body.split(",", 1)
        spec = spec.strip().rstrip(";")
        if not spec:
            continue
        parts = [p.strip() for p in rest.split(",")]
        label = parts[0] if parts else ""
        options = parts[1:]

        # --- the sub-page tag, which must precede the field it scopes ----------------
        page: int | None = None
        first_kind = min((spec.index(c) for c in KIND_LETTERS if c in spec), default=None)
        for tag in PAGE_TAG.finditer(spec):
            if first_kind is not None and tag.start() > first_kind:
                unreadable.append(
                    f'CONF_STR entry "{spec}": the P{tag.group(1)} page tag comes AFTER the '
                    f"{spec[first_kind]} field it scopes. The framework reads the tag first, "
                    f"so write P{tag.group(1)}{spec[:tag.start()]}{spec[tag.end():]}"
                )
                break
        pm = PAGE_PREFIX.match(spec)
        if pm:
            page = int(pm.group(1))
            spec = spec[pm.end():]
            if page < 1:
                unreadable.append(
                    f'CONF_STR entry "{spec}": page 0 is the ROOT menu, not a sub-page, so '
                    "a field tagged P0 would be filed under a page the framework never "
                    "opens. Drop the tag to leave the entry in the root menu"
                )
                continue
            if not spec:
                # a page DEFINITION: "P2,Title;"
                if not label:
                    unreadable.append(
                        f'"P{page}" declares sub-page {page} with no title, so the '
                        f"framework has nothing to name it: use P{page},Title"
                    )
                    continue
                pages[page] = label
                continue
            if spec == "-":
                # a separator INSIDE the page: "P2-;" or "P2-, -=-;"
                referenced[page] = label
                continue

        # F/S slots (and the other non-bit kinds) name an image or file SLOT INDEX, not a
        # status bit: `S3` is hps_io disk slot 3 and moves nothing in status[]. Reading it as
        # bit 3 made the second hard disk's slot collide with the BIOS-setup option O[3].
        km = re.match(r"^([A-Za-z])", spec)
        if km and km.group(1).upper() not in BIT_KINDS and (BRACKETED.match(spec) or DIGITS.match(spec)):
            continue
        bm = BRACKETED.match(spec)
        if bm:
            kind = bm.group(1)
            hi = int(bm.group(2))
            lo = int(bm.group(3)) if bm.group(3) else hi
            fields.append(Field(spec, kind, set(range(min(hi, lo), max(hi, lo) + 1)),
                                max(hi, lo), label, options, page))
        elif (dm := DIGITS.match(spec)):
            kind = dm.group(1)
            offset = 32 if kind.islower() else 0
            bits = {int(d) + offset for d in dm.group(2)}
            fields.append(Field(spec, kind, bits, max(bits), label, options, page))
        elif BARE.match(spec):
            continue  # a bare letter names no bit (V, J, I, A); nothing to check
        else:
            unreadable.append(
                f'CONF_STR entry "{(("P%d" % page) if page else "") + spec},..." names '
                "status bits, a page, or a page tag in a form this check cannot read, so "
                "its field would be covered by nothing." + UNREADABLE_HINT
            )
        if page is not None:
            referenced[page] = label

    # Every page a separator or a field names must be one a `P{n},Title` entry opened.
    for number, _label in referenced.items():
        if number not in pages:
            unreadable.append(
                f"CONF_STR: a field or separator is tagged onto sub-page {number}, but no "
                f'"P{number},Title;" entry declares that page, so its contents would be '
                "filed under a sub-page the user never sees"
            )
    for number, title in pages.items():
        if number not in referenced:
            unreadable.append(
                f'CONF_STR: sub-page {number} ("{title.strip(chr(59))}") is declared but '
                "nothing is filed under it, so the user gets an empty sub-page"
            )
    return fields, unreadable, pages


def status_reads(text: str) -> list[tuple[set[int], str, str | None]]:
    """Every `status[...]` read in comment-stripped RTL.

    Returns (bits, the text before the read on its line, the module port it feeds). The
    port is None when the read is an expression rather than an instantiation connection
    (`.osd_bios_setup(status[3]),` vs `ar <= status[23:22];`).
    """
    out: list[tuple[set[int], str, str | None]] = []
    for m in re.finditer(r"status\[(\d+)(?:\s*:\s*(\d+))?\]", text):
        hi = int(m.group(1))
        lo = int(m.group(2)) if m.group(2) else hi
        line_start = text.rfind("\n", 0, m.start()) + 1
        prefix = text[line_start:m.start()]
        pm = re.search(r"\.\s*([A-Za-z_]\w*)\s*\(\s*$", prefix)
        out.append((set(range(min(hi, lo), max(hi, lo) + 1)), prefix.strip(),
                    pm.group(1) if pm else None))
    return out


# --- one hop: does the module a port feeds actually READ it? ------------------------

def match_paren(text: str, open_paren: int) -> int:
    """The index of the `)` that closes the `(` at open_paren, or len(text)."""
    depth = 0
    i = open_paren
    while i < len(text):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(text)


def module_bodies(text: str) -> list[tuple[str, str, str]]:
    """(name, port-list text, body text) for every module in a file.

    The port list is found by paren matching, and a `#( ... )` PARAMETER list is skipped
    first: the tree's modules are parameterised (`pc9821_osd #(.SYS_CLOCK_HZ(...)) (`),
    and stopping at the parameter list's close would put the whole port list in the BODY,
    where every declared port then reads as a consumer of itself - which is exactly the
    false pass the one-hop check exists to prevent.
    """
    out: list[tuple[str, str, str]] = []
    for m in re.finditer(r"\bmodule\s+(\w+)", text):
        i = m.end()
        hash_pos = text.find("#", i)
        open_paren = text.find("(", i)
        if open_paren < 0:
            continue
        if 0 <= hash_pos < open_paren:
            # the parameter list; the port list is the next paren group after it
            open_paren = text.find("(", match_paren(text, open_paren) + 1)
            if open_paren < 0:
                continue
        close = match_paren(text, open_paren)
        endmodule = text.find("endmodule", close)
        body_end = endmodule if endmodule > 0 else len(text)
        out.append((m.group(1), text[open_paren:close + 1], text[close + 1:body_end]))
    return out


def rtl_sources() -> list[tuple[str, str]]:
    """Every RTL file this check can follow a port into: (path, text)."""
    out: list[tuple[str, str]] = []
    for directory in RTL_DIRS:
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*.sv")):
            text = slurp(path)
            if text is not None:
                out.append((str(path), text))
    return out


def port_consumers(port: str, sources: list[tuple[str, str]]) -> list[str]:
    """The modules that both declare `port` and read it in their body.

    One hop is what the contract needs: `status[3] -> .osd_bios_setup(...) -> the module
    that owns the option` has to end in SOMETHING, and the failure this catches is a port
    declared and never used (the port list is a promise; the body is the payment).

    The SOURCES are passed in rather than read here so that --selftest runs against its
    own mutated copies: a guard whose mutants cannot reach it is a guard that only proves
    it can read the disk.
    """
    found: list[str] = []
    pat = re.compile(r"\b" + re.escape(port) + r"\b")
    for _path, text in sources:
        if port not in text:
            continue
        for name, ports, body in module_bodies(strip_comments(text)):
            if pat.search(ports) and pat.search(body):
                found.append(name)
    return found


# --- the checks ---------------------------------------------------------------------

def check(top_text: str, osd_text: str, system_text: str,
          sources: list[tuple[str, str]], crtc_text: str = "") -> dict[str, str]:
    """Run every check against the three texts; return the PASS summary lines."""
    summary: dict[str, str] = {}
    top_code = strip_comments(top_text)
    reads = status_reads(top_code)
    read_bits: set[int] = set()
    read_ports: dict[str, int] = {}
    for bits, _prefix, port in reads:
        read_bits |= bits
        if port:
            read_ports[port] = read_ports.get(port, 0) + 1

    conf_text = conf_str_region(top_text)
    fields, unreadable, pages = conf_str_fields(conf_text)
    for message in unreadable:
        # Fail loud rather than skip: a spec this parser cannot read is a field this gate
        # would silently stop covering, which is the state O[3] was in. The parser words
        # these itself, close to the cause.
        note(message)
    option_fields = [f for f in fields if f.is_option]
    action_fields = [f for f in fields if not f.is_option]

    if not option_fields:
        note("z486_mister.sv declares no O[...] option field at all")

    # 6. the option count must fit the field's width.
    for f in fields:
        width = len(f.bits)
        if len(f.options) > 2 ** width:
            note(
                f"{f.spec} ({f.label}) is {width} bit(s), so it can select at most "
                f"{2 ** width} option(s), but its CONF_STR entry offers {len(f.options)}"
            )

    # 2. every declared option field must be read by the core.
    for f in option_fields:
        if not f.label:
            note(f"{f.spec} has no label in CONF_STR")
        missing = sorted(f.bits - read_bits)
        if missing:
            note(
                f"{f.spec} ({f.label}) is declared in CONF_STR but the RTL reads "
                f"nothing at status{missing}: the field is wired to nothing, so the "
                "user can select an option that does nothing"
            )
        # 3. one hop: a read that is a port connection must be read inside its module.
        for bits, prefix, port in reads:
            if port is None or not (bits & f.bits):
                continue
            if read_ports.get(port, 0) and not port_consumers(port, sources):
                note(
                    f"{f.spec} ({f.label}) reaches only the `{port}` port connection "
                    f"(`{prefix}`), and no module that declares `{port}` reads it: the "
                    "option is wired to a port its module ignores"
                )

    # 4. no two declared fields may share a bit.
    #
    # THIS IS THE LIVE FORM OF A GUARD THAT HAD GONE DEAD. The Machine (BIOS-set) field
    # once sat on status[5]/status[6], where the DDR framebuffer's fb_fmt
    # assignment read the same bits, so selecting a BIOS set silently flipped BGR -> RGB.
    # The old guard parsed that ONE expression; the framebuffer descriptor was deleted
    # and the framework's FB_* pins are tied off, so the expression it
    # parsed no longer exists and the guard could never fire again - a check that cannot
    # fail. What replaced it is the general rule below, which fires on the shape a field
    # collision can still take (one declared field's bits inside another's), and the
    # remaining fact the old guard rested on - no framebuffer-format reader left to
    # collide with - is a property of the RTL this file cannot miss (there is no fb_fmt
    # assignment in z486_mister.sv).
    for i, a in enumerate(option_fields):
        for b in option_fields[i + 1:]:
            shared = sorted(a.bits & b.bits)
            if shared:
                note(
                    f"CONF_STR fields {a.spec} ({a.label}) and {b.spec} ({b.label}) "
                    f"share status{shared}: one option write moves the other field, and "
                    "which one the user selected stops meaning anything"
                )
    for a in option_fields:
        for b in action_fields:
            shared = sorted(a.bits & b.bits)
            if shared:
                note(
                    f"CONF_STR option field {a.spec} ({a.label}) shares status{shared} "
                    f"with the action field {b.spec} ({b.label}): an action pulse would "
                    "be read as a stored option value"
                )

    # 5. each field's position 0 is the measured machine's default.
    #
    # Keyed by bitspec, NOT by spec: the page tag is display grouping, so moving a field
    # between pages must not silently make this table miss it.
    default_summary: list[str] = []
    for f in option_fields:
        entry = FIELD_DEFAULT.get(f.bitspec)
        if entry is None:
            note(
                f"{f.bitspec} ({f.label}) has no default in FIELD_DEFAULT: position 0 is "
                "what a card with no config file passes, so its machine value has to be "
                "stated with its reference before this gate can cover the field"
            )
            continue
        want, why = entry
        if not f.options:
            note(f"{f.spec} ({f.label}) offers no options, so position 0 is undefined")
            continue
        if f.options[0].strip() != want:
            note(
                f"{f.spec} ({f.label}) position 0 is {f.options[0]!r}, want {want!r} "
                f"({why})"
            )
        if len(f.options) < 2:
            note(f"{f.spec} ({f.label}) offers {len(f.options)} option(s), so it cannot "
                 "be selected at all")
        default_summary.append(f"{f.spec} = {f.options[0]}")
    summary["defaults"] = ", ".join(default_summary)

    # 5c. THE DIP PAGE: every field the top level wires into the DIP sub-page's own ports is
    #     filed under it. The requirement is that ALL DIP/configuration handling lives
    #     in the `P1,DIP Switch` sub-page, and the failure this catches is a switch field left
    #     in the root menu (or moved back there) where the user has to hunt for it.
    dip_members: list[str] = []
    for bits, _prefix, port in reads:
        if port is None or port not in DIP_PORTS:
            continue
        for f in fields:
            if not (bits & f.bits):
                continue
            dip_members.append(f.spec)
            if f.page != DIP_PAGE:
                note(
                    f"{f.spec} ({f.label}) is wired to the DIP sub-page's `{port}` port but "
                    f"is filed in {'the root menu' if f.page is None else f'P{f.page}'}: the "
                    f"menu's contract is that all DIP/configuration handling lives in the "
                    f"P{DIP_PAGE} sub-page"
                )
    summary["dip"] = ", ".join(sorted(set(dip_members))) if dip_members else "(none)"

    # 5d. THE HARDWARE-SWITCH FIELDS: each offered option's LABEL must be the value the code
    #     pc9821_osd.sv maps that position to. This is the class the RAM Size block below has
    #     covered for one field since the 1 MB freeze, applied to the two memory-switch fields,
    #     where a swapped pair of labels is a wrong MACHINE DESCRIPTION: the cell is read by
    #     the firmware and nothing checks the value the core writes there.
    #
    #     The unreachable positions (a 2-bit field offers 3 options, a 3-bit one offers 6)
    #     must decode to the MEASURED machine rather than to a value nobody measured, so a
    #     hand-edited config file cannot ask for a machine that was never captured.
    def switch_table(name: str) -> tuple[dict[int, int], int | None]:
        """{position: code} from pc9821_osd.sv's `<name>` case arms, plus the default's code.

        The arms are written `<w>'d<pos>: <name> = <w>'d<code>;` - the same spelling the RAM
        Size table above uses - so one parse reads both fields.
        """
        arms = {int(m.group(1)): int(m.group(2)) for m in re.finditer(
            r"\d+'d(\d+):\s*" + name + r"\s*=\s*\d+'d(\d+);", crtc_text)}
        dm = re.search(r"default:\s*" + name + r"\s*=\s*\d+'d(\d+);", crtc_text)
        return arms, (int(dm.group(1)) if dm else None)

    def field_width(bitspec: str) -> int | None:
        for f in fields:
            if f.bitspec == bitspec:
                return len(f.bits)
        return None

    fdd_options = conf_str_options(conf_text, "O[42:40]")
    fdd_summary = "?"
    if fdd_options is None:
        note("z486_mister.sv has no CONF_STR entry for O[42:40] (Boot order)")
    else:
        arms, dflt = switch_table("msw_fdd_nib")
        width = field_width("O[42:40]")
        if not arms:
            note("pc9821_text_mem.sv has no 'msw_fdd_nib = N'dM' case arms")
        elif width is not None and len(arms) > 2 ** width:
            note(f"pc9821_osd.sv maps {len(arms)} FDD positions, more than the field's "
                 f"{2 ** width}")
        elif dflt is None:
            note("pc9821_text_mem.sv's msw_fdd_nib has no `default:` arm, so a position the "
                 "CONF_STR list does not offer maps to nothing")
        else:
            measured = FDD_NIBBLE.get(fdd_options[0].strip())
            for pos, word in enumerate(fdd_options):
                code = arms.get(pos, dflt)
                want = FDD_NIBBLE.get(word.strip())
                if want is None:
                    note(
                        f'Boot order position {pos}: option "{word}" is not one of the named '
                        f"values {sorted(FDD_NIBBLE)} - positions 0-2 are the classes the "
                        "authentic BIOS's boot helper distinguishes (BANK7@0x599B/0x59A0 "
                        "compares 0x20/0x40, `jz`/`jnz` keeps otherwise) and 3-6 are NP2kai "
                        "bios1b.c:883-926's boot-device codes (0x60/0xa0/0xb0/0xc0), so any "
                        "other label would encode a switch position no reference names"
                    )
                elif code != want:
                    note(
                        f'Boot order position {pos}: the CONF_STR list in z486_mister.sv says '
                        f'"{word}" (nibble 0x{want:x}), but pc9821_osd.sv maps that position '
                        f"to 0x{code:x} - the position->code table and the label have drifted "
                        "apart, and the code is what the BIOS reads out of 0xA3FF2"
                    )
            if measured is not None and dflt != measured:
                note(
                    f"pc9821_text_mem.sv's msw_fdd_nib `default:` arm is {dflt}, want "
                    f"{measured} (the measured nibble, entry 0): a position the list does not "
                    "offer must describe the captured machine, not another one"
                )
            # The positions the list does NOT offer are written out for exactly this reason:
            # a hand-edited config file can pass any value the field's width allows, and it
            # must land on the captured machine rather than on a nibble nobody measured.
            for pos in range(2 ** width if width else 0):
                if pos < len(fdd_options) or pos not in arms or measured is None:
                    continue
                if arms[pos] != measured:
                    note(
                        f"Boot order position {pos} is not offered by the CONF_STR list but "
                        f"pc9821_text_mem.sv maps it to nibble 0x{arms[pos]:x}, want the measured "
                        f"0x{measured:x}"
                    )
            fdd_summary = ", ".join(f"{w}->0x{arms.get(p, dflt):x}"
                                    for p, w in enumerate(fdd_options))
    summary["fdd"] = fdd_summary

    # 5f. THE CD AUDIO VOLUME (a CD-DA build only): each option's label is the gain code
    #     pc9821_osd.sv maps its position to (cd_volume_label_code), and every one of the
    #     field's positions is offered, so no saved value can land on an unlabelled code.
    cdvol_options = conf_str_options(conf_text, "O[66:64]")
    cdvol_summary = "(not in this build)"
    if cdvol_options is not None:
        arms = {int(m.group(1)): int(m.group(2)) for m in re.finditer(
            r"3'd(\d):\s*cd_volume_code\s*=\s*5'd(\d+);", osd_text)}
        dm = re.search(r"default:\s*cd_volume_code\s*=\s*5'd(\d+);", osd_text)
        dflt = int(dm.group(1)) if dm else None
        if len(cdvol_options) != 8:
            note(f"O[66:64] (CD audio volume) offers {len(cdvol_options)} options, want all 8 "
                 "positions of the 3-bit field labelled")
        if not arms or dflt is None:
            note("pc9821_osd.sv has no `3'dN: cd_volume_code = 5'dM;` arms with a `default:`")
        else:
            for pos, word in enumerate(cdvol_options):
                want = cd_volume_label_code(word.strip())
                code = arms.get(pos, dflt)
                if want is None:
                    note(f'CD audio volume position {pos}: option "{word}" names no gain step '
                         "(want \"Off\" or \"-N dB\" with N even, 0..60)")
                elif code != want:
                    note(f'CD audio volume position {pos}: the CONF_STR list says "{word}" '
                         f"(gain code {want}), but pc9821_osd.sv maps that position to {code}")
            cdvol_summary = ", ".join(f"{w}->{arms.get(p, dflt)}"
                                      for p, w in enumerate(cdvol_options))
    summary["cdvol"] = cdvol_summary

    # 5e. THE DRIVES: one Eject per Mount, wired to that mount's slot.
    #     Every `S{n},<ext>,Mount <drive>` image slot has exactly one `T[b],Eject <drive>`
    #     trigger, and the top level routes status[b] to pc9821_mount_eject's eject_req[n] - one
    #     `assign eject_req[n] = status[b];` per slot - so an eject can never be offered for a
    #     drive the menu cannot mount, nor land on another drive's slot (the CD-ROM's Eject was
    #     the missing one: its slot passed hps_io's events straight through).
    drives_summary = check_drives(conf_text, top_code, fields)
    summary["drives"] = drives_summary

    # 8. THE ROOT MENU'S LAYOUT (ROOT_LAYOUT): the order and grouping the user sees.
    summary["layout"] = check_layout(conf_text)

    # 9. THE FORMATS EACH MOUNT ENTRY OFFERS (MOUNT_EXTS).
    summary["mount_exts"] = check_mount_exts(conf_text)

    # 5b. THE SUB-PAGES, reported rather than checked for taste: which entries the user
    #     now finds under which sub-menu. Every field's page is already known to be
    #     declared (conf_str_fields rejects the alternatives), so this is the summary a
    #     reader compares against PC-9821_z486_MiSTer's CONF_STR.
    page_summary: list[str] = []
    for number in sorted(pages):
        members = [f for f in fields if f.page == number]
        page_summary.append(
            f"P{number} {pages[number]!r}: " + ", ".join(f.spec for f in members)
        )
    root = [f.spec for f in fields if f.page is None]
    summary["pages"] = "; ".join(page_summary) if page_summary else "(none)"
    summary["root"] = ", ".join(root)

    # --- 6 again: the original RAM Size contract, unchanged ------------------------
    ram_options = conf_str_options(conf_text, "O[63:61]")

    if ram_options is None:
        note("z486_mister.sv has no CONF_STR entry for O[63:61] (RAM Size)")

    pos_to_code: dict[int, int] = {}
    for m in re.finditer(r"3'd(\d):\s*ram_size_code\s*=\s*3'd(\d);", osd_text):
        pos_to_code[int(m.group(1))] = int(m.group(2))

    # POSITION 7 IS WRITTEN AS `default:` rather than `3'd7:`, which is a real asymmetry in
    # the module and is legal because osd_ram_size is 3 bits wide: positions 0..6 are
    # explicit, so `default` can only ever be reached by 7. Deriving that from the declared
    # width rather than from the comment is the point - a comment is not a contract. If the
    # RTL ever lists all eight explicitly, `default` becomes unreachable and this stops
    # attributing it to anything; if it ever left TWO positions to `default`, that is
    # ambiguous and is reported as a failure rather than guessed at.
    default_m = re.search(r"default:\s*ram_size_code\s*=\s*3'd(\d);", osd_text)
    if default_m:
        uncovered = [p for p in range(8) if p not in pos_to_code]
        if len(uncovered) == 1:
            pos_to_code[uncovered[0]] = int(default_m.group(1))
        elif len(uncovered) > 1:
            note(
                "pc9821_osd.sv leaves positions "
                f"{uncovered} to a single `default` arm, so one width of osd_ram_size "
                "cannot be told from another"
            )

    if not pos_to_code:
        note("pc9821_osd.sv has no 'ram_size_code = 3'dN' case arms")
    if set(pos_to_code) != set(range(8)) and pos_to_code:
        note(f"pc9821_osd.sv maps {sorted(pos_to_code)}, want positions 0..7")

    # The VSync polarity check departed with the field: its whole content was which bit
    # value meant which rate, and O[4] no longer exists now that the core keeps the guest's
    # own raster as its only option.

    code_to_bytes: dict[int, int] = {}
    # The assignment target is named guest_ram_bytes in pc9821_system.sv's own comment/name, but
    # the table moved into the size_code_bytes() function so the same table can also produce the
    # module-fixed pack base, so accept either name.
    for m in re.finditer(
        r"3'd(\d):\s*(?:guest_ram_bytes|size_code_bytes)\s*=\s*32'h([0-9a-fA-F_]+)\s*;",
        system_text,
    ):
        code_to_bytes[int(m.group(1))] = int(m.group(2).replace("_", ""), 16)

    if not code_to_bytes:
        note("pc9821_system.sv has no 'guest_ram_bytes/size_code_bytes = 32'h...' case arms")
    if set(code_to_bytes) != set(range(8)) and code_to_bytes:
        note(f"pc9821_system.sv maps {sorted(code_to_bytes)}, want codes 0..7")

    # THE CONTRACT: every position of the OSD list must select the size its own label
    # names. That single sentence is the whole of it: the label comes from the string the
    # user reads, the position goes through the module, and the code goes through the
    # system's table. If any of the three moves without the others, this fails.
    if ram_options is not None and pos_to_code and code_to_bytes:
        if len(ram_options) != len(pos_to_code):
            note(
                f"CONF_STR offers {len(ram_options)} RAM sizes but the module maps "
                f"{len(pos_to_code)} positions"
            )
        else:
            for pos, word in enumerate(ram_options):
                want_mib = mib_of(word)
                if want_mib is None:
                    note(f'RAM Size position {pos}: option "{word}" is not a size label')
                    continue
                code = pos_to_code.get(pos)
                if code is None:
                    note(f"RAM Size position {pos} has no mapping in pc9821_osd.sv")
                    continue
                got = code_to_bytes.get(code)
                if got is None:
                    note(f"pc9821_system.sv has no entry for size code {code}")
                    continue
                want = want_mib << 20
                if got != want:
                    # Name the FILE each side came from, because the two ways this fails need
                    # opposite responses: a drifted string is fixed in z486_mister.sv, a drifted
                    # mapping in pc9821_osd.sv, and a drifted table in pc9821_system.sv. A
                    # message that only said "16 MiB != 8 MiB" would aim the reader at the
                    # wrong file half the time.
                    note(
                        f'RAM Size position {pos}: the CONF_STR list in z486_mister.sv says '
                        f'"{word}" ({want_mib} MiB), but the position maps to size code {code} '
                        f"in pc9821_osd.sv and pc9821_system.sv says that code is "
                        f"{got >> 20} MiB ({got} bytes)"
                    )

        # THE PROJECT'S TWO MENU REQUIREMENTS, stated rather than inferred, and named here
        # so a regression to either is unmistakable. A card with no config file passes 0 for
        # every field, so position 0 is what such a card boots.
        if ram_options:
            default0 = mib_of(ram_options[0])
            if default0 == 1:
                note(
                    "RAM Size position 0 is 1M: a card with no config file boots a 1 MB "
                    "guest, which cannot run the Xe10 BIOS at all (the card "
                    "freezes)"
                )
            elif default0 != 16:
                note(f"RAM Size position 0 is {ram_options[0]}, want 16M (the project's default)")

    # --- the BIOS-set wiring probe ---------------------------------------------------
    #
    # It reads the CONNECTION rather than a remembered bit number: a check that hardcoded
    # 31:28 would pass the day someone rewired the port to a colliding field and kept the
    # comment. What it adds over the generic field checks above is that this particular
    # field has to exist at all and its option count has to fit - the contract stated
    # when the BIOS set became selectable.
    bios_wire = re.search(r"\.bios_set\s*\(\s*status\[(\d+)(?:\s*:\s*(\d+))?\]\s*\)", top_code)
    bios_summary = "?"
    if not bios_wire:
        note("z486_mister.sv does not connect .bios_set(...) to a status[...] field")
    else:
        hi = int(bios_wire.group(1))
        lo = int(bios_wire.group(2)) if bios_wire.group(2) else hi
        width = max(lo, hi) - min(lo, hi) + 1
        field = f"O[{hi}:{lo}]" if hi != lo else f"O[{hi}]"
        bios_summary = field
        bios_options = conf_str_options(conf_text, field)
        if bios_options is None:
            note(f"z486_mister.sv wires .bios_set to {field} but CONF_STR has no entry for it")
        else:
            bios_summary = f"{field} ({len(bios_options)} sets)"
            if len(bios_options) > 2 ** width:
                note(
                    f"the BIOS-set field {field} is {width} bits, so it can select at most "
                    f"{2 ** width} sets, but its CONF_STR entry offers {len(bios_options)} options"
                )
    summary["bios"] = bios_summary
    summary["ram"] = ", ".join(ram_options) if ram_options else "?"
    summary["mapping"] = (
        f"{len(pos_to_code)} positions -> size codes, each label's size == "
        "pc9821_system.sv's bytes for that code"
    )
    summary["speed"] = check_cpu_speed(conf_text, top_code, sources)
    summary["fields"] = ", ".join(f"{f.spec} {f.label}" for f in option_fields)
    summary["actions"] = ", ".join(
        f"{f.spec} {f.label}" for f in action_fields if f.options or f.label
    )
    return summary


THROTTLE_ARM = re.compile(r"4'd(\d+)\s*:\s*rate_khz\s*=\s*(\d+)\s*;")
SPEED_LABEL = re.compile(r"^(\d+(?:\.\d+)?) MHz$")


def check_cpu_speed(conf_text: str, top_code: str, sources: list[tuple[str, str]]) -> str:
    """The CPU Speed labels against cpu_throttle's rate table; return the summary line.

    The field is found by its CONNECTION (.cpu_speed_sel(status[..])), not a remembered bit
    number. Position 0 must be Full (rate_khz's default arm, a strict no-op); every other
    label must be `<rate> MHz` and equal the arm for its position; every arm cpu_throttle
    defines must have a label (a rate the OSD cannot reach is a dead arm, and a label past
    the table would select the reserved full-speed codes while claiming a rate).
    """
    wire = re.search(r"\.cpu_speed_sel\s*\(\s*status\[(\d+)\s*:\s*(\d+)\]\s*\)", top_code)
    if not wire:
        note("z486_mister.sv does not connect .cpu_speed_sel(...) to a status[hi:lo] field")
        return "?"
    field = f"O[{wire.group(1)}:{wire.group(2)}]"
    options = conf_str_options(conf_text, field)
    if options is None:
        note(f"z486_mister.sv wires .cpu_speed_sel to {field} but CONF_STR has no entry for it")
        return "?"
    throttle = next((text for path, text in sources if path == str(THROTTLE)), None)
    if throttle is None:
        note(f"cannot read {THROTTLE.relative_to(ROOT)}: the CPU Speed labels have no rate table")
        return "?"
    arms = {int(pos): int(khz) for pos, khz in THROTTLE_ARM.findall(strip_comments(throttle))}
    if not arms:
        note("cpu_throttle.sv's rate_khz() has no `4'dN: rate_khz = K;` arm this check can read")
        return "?"
    if options[0] != "Full":
        note(f'CPU Speed position 0 is "{options[0]}"; it must be Full (rate_khz 0, cpu_ce '
             "constant 1)")
    if 0 in arms:
        note("cpu_throttle.sv gives position 0 a rate; position 0 must be full speed")
    for pos, label in enumerate(options[1:], start=1):
        m = SPEED_LABEL.match(label)
        if not m:
            note(f'CPU Speed position {pos} label "{label}" is not a plain "<rate> MHz"')
            continue
        khz = round(float(m.group(1)) * 1000)
        if pos not in arms:
            note(f'CPU Speed position {pos} "{label}" has no rate_khz arm: it would run at '
                 "full speed")
        elif arms[pos] != khz:
            note(f'CPU Speed position {pos} is labelled "{label}" but cpu_throttle runs it at '
                 f"{arms[pos]} kHz")
    for pos in sorted(arms):
        if pos >= len(options):
            note(f"cpu_throttle.sv's rate_khz arm {pos} ({arms[pos]} kHz) has no CPU Speed label")
    return f"{field} ({len(options)} positions, every label == rate_khz)"


MENU_ENTRY = re.compile(r'"([^"]*)"')
EJECT_ASSIGN = re.compile(r"assign\s+eject_req\s*\[\s*(\d+)\s*\]\s*=\s*status\s*\[\s*(\d+)\s*\]\s*;")


def check_drives(conf_text: str, top_code: str, fields: list[Field]) -> str:
    """Check 5e (see the call site); return its summary line."""
    mounts: dict[str, int] = {}            # drive -> hps_io slot
    for m in MENU_ENTRY.finditer(conf_text):
        body = m.group(1).rstrip(";")
        parts = [p.strip() for p in body.split(",")]
        sm = re.fullmatch(r"S(\d+)", parts[0])
        if sm and len(parts) >= 3:
            label = parts[2]
            if not label.startswith("Mount "):
                note(f'CONF_STR image slot "{body}": its label must be "Mount <drive>" (the '
                     "project's OSD layout), so that its Eject can be named after the same drive")
                continue
            drive = label[len("Mount "):].strip()
            if drive in mounts:
                note(f'CONF_STR offers "Mount {drive}" twice (slots {mounts[drive]} and '
                     f"{sm.group(1)})")
            mounts[drive] = int(sm.group(1))
    ejects: dict[str, int] = {}            # drive -> status bit
    for f in fields:
        label = f.label.rstrip(";").strip()
        if f.kind == "T" and label.startswith("Eject "):
            drive = label[len("Eject "):].strip()
            if drive in ejects:
                note(f'CONF_STR offers "Eject {drive}" twice')
            ejects[drive] = min(f.bits)
            if len(f.bits) != 1:
                note(f"{f.spec} ({f.label}) is a trigger on more than one status bit")

    wired: dict[int, int] = {}              # slot -> status bit
    for slot, bit in EJECT_ASSIGN.findall(top_code):
        wired.setdefault(int(slot), int(bit))
    for drive, slot in mounts.items():
        if drive not in ejects:
            note(f'CONF_STR offers "Mount {drive}" (hps_io slot {slot}) but no '
                 f'"T[..],Eject {drive}" trigger: the drive cannot be ejected from the OSD')
            continue
        bit = ejects[drive]
        if wired.get(slot) != bit:
            got = "nothing" if slot not in wired else f"status[{wired[slot]}]"
            note(f'"Eject {drive}" is T[{bit}], but z486_mister.sv drives eject_req[{slot}] '
                 f"(the slot of \"Mount {drive}\") from {got}: the eject reaches the wrong "
                 "drive or none (want `assign eject_req[" f"{slot}] = status[{bit}];`)")
    for drive, bit in ejects.items():
        if drive not in mounts:
            note(f'CONF_STR offers "Eject {drive}" (T[{bit}]) for a drive no "Mount {drive}" '
                 "image slot offers")

    by_slot = sorted(mounts.items(), key=lambda kv: kv[1])
    return ", ".join(f"S{slot} {d} <-> T[{ejects.get(d, '?')}]" for d, slot in by_slot)


# THE ROOT MENU'S LAYOUT, the owner's order: the firmware pack (the BIOS ROM set) first, then
# the drives - each Mount directly followed by its own Eject, HDD, CD-ROM, FDD1, FDD2 - then
# the machine (RAM Size, CPU Speed and the Keyboard layout, one group), the DIP Switch page, the video options, and
# Reset last. One inner list is one group, set off from the next by a `-` separator. An entry
# is named by its spec (the text before the first comma); a `?` suffix marks an entry only
# some builds declare (the CD-ROM's pair with cdrom_en, its CD audio volume with
# cdrom_audio_en, the analog-video fields with
# vga_dbl_en: build_profile.py's rewritten lines), which the layout then expects exactly when
# the build has it. Entries filed under a sub-page are that page's, not the root menu's, and
# an entry this list does not name is left to the other checks (a new field's default, its
# reader), so a new option fails here only once it is placed between the named ones wrongly.
# DISPLAY ORDER ONLY: no status bit, slot index or F index depends on it (the CONF_STR
# comments in z486_mister.sv cite the framework lines that make that so).
ROOT_LAYOUT: list[list[str]] = [
    ["F0"],
    ["S0", "T[8]", "S4?", "T[11]?", "O[66:64]?", "S1", "T[9]", "S2", "T[10]"],
    ["O[63:61]", "O[17:14]", "O[51]"],
    ["P1"],
    ["O[23:22]", "O[46:45]", "O[81:80]?", "O[83:82]?"],
    ["T[0]", "R[0]", "J", "V"],
]


# 9. THE IMAGE FORMATS EACH DRIVE'S FILE BROWSER OFFERS: Main_MiSTer shows only files whose
#    extension is in the entry's list (3-character groups), so a format the core reads but the
#    entry omits cannot be mounted without renaming the file. The HDD reads raw, HDI and fixed VHD
#    images by their content (pc9821_hdd_image.sv: the HDI header and the "conectix" footer).
MOUNT_EXTS: dict[str, str] = {
    "S0": "IMGHDIVHD",          # Mount HDD: raw, HDI, fixed VHD
    "S1": "D88FDDHDM",          # Mount FDD1
    "S2": "D88FDDHDM",          # Mount FDD2
    "S4": "ISOPCD",             # Mount CD-ROM (CD builds only)
}


def check_mount_exts(conf_text: str) -> str:
    """Check 9: each image slot offers MOUNT_EXTS' extensions; return the summary."""
    seen = []
    for m in re.finditer(r'(S\d),([A-Z0-9]*),Mount ', conf_text):
        slot, exts = m.group(1), m.group(2)
        want = MOUNT_EXTS.get(slot)
        if want is None:
            continue
        seen.append(f"{slot}={exts}")
        if exts != want:
            note(f"the {slot} Mount entry offers {exts!r}, want {want!r} (MOUNT_EXTS: a format "
                 "the core reads must be one the file browser shows)")
    return " ".join(seen)


def root_groups(conf_text: str) -> list[list[str]]:
    """The root menu as groups of entry specs, split at `-` separators (empty groups dropped)."""
    groups: list[list[str]] = [[]]
    for m in MENU_ENTRY.finditer(conf_text):
        spec = m.group(1).split(",", 1)[0].rstrip(";").strip()
        if spec == "-":
            groups.append([])
            continue
        pm = PAGE_PREFIX.match(spec)
        if pm and spec[pm.end():]:
            continue            # a sub-page member (`P1O[32]`, `P1-`): not the root menu's
        groups[-1].append(spec)
    return [g for g in groups if g]


def check_layout(conf_text: str) -> str:
    """Check 8: the root menu's groups and their order are ROOT_LAYOUT's; return the summary."""
    named = {e.rstrip("?") for g in ROOT_LAYOUT for e in g}
    actual = [[s for s in g if s in named] for g in root_groups(conf_text)]
    actual = [g for g in actual if g]
    present = {s for g in actual for s in g}
    want = [[e.rstrip("?") for e in g if not e.endswith("?") or e.rstrip("?") in present]
            for g in ROOT_LAYOUT]
    want = [g for g in want if g]

    def show(groups: list[list[str]]) -> str:
        return " | ".join(" ".join(g) for g in groups)

    if actual != want:
        note("CONF_STR's root menu is not the contracted layout (ROOT_LAYOUT: the ROM pack "
             "first, then each drive's Mount and Eject - HDD, CD-ROM, FDD1, FDD2 - then RAM "
             "Size, CPU Speed and Keyboard, the DIP Switch page, video, Reset; `|` is a separator): "
             f"it reads {show(actual)}, want {show(want)}")
    return show(actual)


def conf_str_options(text: str, bits: str) -> list[str] | None:
    """Return the option words of the CONF_STR entry for a bit field like 'O[63:61]'.

    The entry is quoted:  "O[63:61],RAM Size,16M,32M,...;",
    Returns None when the entry is absent, which the caller reports as a failure:
    an option that vanished is a contract change, not a reason to skip a check.
    """
    # The `P{n}` tag is allowed before the bits (the sub-page that holds the field), so the
    # regex tolerates it: "P1O[32],GDC Clock,...;" and "O[32],..." both answer.
    m = re.search(r'"(?:P\d+)?' + re.escape(bits) + r',([^;"]*);"', text)
    if not m:
        return None
    fields = [f.strip() for f in m.group(1).split(",")]
    # fields[0] is the human label ("RAM Size", "VSync"); the rest are the options.
    return fields[1:]


def mib_of(word: str) -> int | None:
    """'16M' -> 16. Returns None when the option is not a size label."""
    m = re.fullmatch(r"(\d+)M", word)
    return int(m.group(1)) if m else None


# --- the run ------------------------------------------------------------------------

def report(summary: dict[str, str]) -> None:
    print("OSD CONTRACT CHECK: PASS")
    print(f"  O fields        {summary['fields']}")
    print(f"  RAM Size list   {summary['ram']}")
    print(f"  BIOS set field  {summary['bios']}  (wired to .bios_set, count fits its width)")
    print(f"  CPU Speed       {summary['speed']}  (labels against cpu_throttle.sv)")
    print(f"  position 0      {summary['defaults']}  (each against FIELD_DEFAULT's reference)")
    print(f"  drives          {summary['drives']}  (Mount/Eject pairs, eject_req wired per slot)")
    print(f"  layout          {summary['layout']}  (the root menu's groups, ROOT_LAYOUT)")
    print(f"  root menu       {summary['root']}")
    print(f"  sub-pages       {summary['pages']}")
    print(f"  DIP page        P{DIP_PAGE} holds {summary['dip']} (every field wired to a DIP port)")
    print(f"  switch values   Boot order {summary['fdd']} (label -> the nibble the cell takes)")
    print(f"  CD volume       {summary['cdvol']} (label -> pc9821_audio_volume gain code)")
    print(f"  mapping         {summary['mapping']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--selftest", action="store_true",
                        help="reject planted violations in memory")
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    texts = []
    for path in (TOP, OSD, SYSTEM, CRTC):
        text = slurp(path)
        if text is None:
            print(f"OSD CONTRACT CHECK: FAIL -- cannot read {path}")
            return 1
        texts.append(text)

    top, osd, system, crtc = texts
    summary = check(top, osd, system, rtl_sources(), crtc)
    if problems:
        print("OSD CONTRACT CHECK: FAIL")
        for p in problems:
            print(f"  - {p}")
        return 1
    report(summary)
    return 0


# --- selftest: every class of violation, planted and required to be rejected ---------

def selftest() -> int:
    """Plant one defect per class this gate claims to catch; each must be rejected.

    The honest source is checked first: if it already fails, the mutants prove nothing,
    so that is a failure of the selftest itself (the same rule check_tool_citations.py
    and check_z486_patch_diff.py apply to their own guards).
    """
    texts = {}
    for key, path in (("top", TOP), ("osd", OSD), ("system", SYSTEM), ("crtc", CRTC),
                      ("throttle", THROTTLE)):
        text = slurp(path)
        if text is None:
            print(f"OSD CONTRACT SELFTEST: FAIL -- cannot read {path}")
            return 1
        texts[key] = text

    global problems
    problems = []
    sources = rtl_sources()
    paths = {"top": str(TOP), "osd": str(OSD), "system": str(SYSTEM), "crtc": str(CRTC),
             "throttle": str(THROTTLE)}

    def run(mutated: dict[str, str]) -> None:
        """Check every text with each one standing in for its own file."""
        global problems
        problems = []
        here = [(path, mutated[key] if path == paths[key] else text)
                for key, _ in paths.items()
                for path, text in sources if path == paths[key]]
        rest = [(path, text) for path, text in sources if path not in paths.values()]
        check(mutated["top"], mutated["osd"], mutated["system"], here + rest,
              mutated["crtc"])

    run(texts)
    if problems:
        print("OSD CONTRACT SELFTEST: FAIL -- the honest source does not pass:")
        for p in problems:
            print(f"  - {p}")
        return 1

    # BOTH menus, made in memory the way build_profile.py writes them (its profile-rewritten
    # CONF_STR_CD line), whichever one the tree is configured with: the CD build's (every
    # preset's default since 2026-10-10) and the --no-cdrom opt-out's, so the CD's mount/eject
    # pair is checked as a CD build has it and its absence as a build without the drive has it.
    # A CD build with the drive's audio player also carries the CD audio volume field; a
    # data-only drive (--no-cdrom-audio) has the pair alone.
    cdvol_entry = "O[66:64],CD audio volume,0 dB,-2 dB,-4 dB,-6 dB,-8 dB,-10 dB,-12 dB,Off;"
    cd_line = '"T[8],Eject HDD;S4,ISOPCD,Mount CD-ROM;T[11],Eject CD-ROM;' + cdvol_entry + '"'
    cddata_line = '"T[8],Eject HDD;S4,ISOPCD,Mount CD-ROM;T[11],Eject CD-ROM;"'
    nocd_line = '"T[8],Eject HDD;"'

    def menu(line: str) -> str:
        return re.sub(r'(?m)^(localparam\s+CONF_STR_CD\s*=\s*)"[^"]*"', r"\g<1>" + line,
                      texts["top"], count=1)

    variants = {}
    for tag, line in (("cd", cd_line), ("cddata", cddata_line), ("nocd", nocd_line)):
        top = menu(line)
        if top.count(f"CONF_STR_CD = {line};") != 1:
            print(f"OSD CONTRACT SELFTEST: FAIL -- could not build the {tag} menu in memory")
            return 1
        variants[tag] = dict(texts, top=top)
        run(variants[tag])
        if problems:
            print(f"OSD CONTRACT SELFTEST: FAIL -- the honest {tag} menu does not pass:")
            for p in problems:
                print(f"  - {p}")
            return 1

    # (The VSync entry that used to lead the profile-rewritten CONF_STR_VIDEO line left
    # with the field, so the new-field plant anchors on the Scale entry, a plain quoted
    # line of the block.)
    scale_line = '"O[46:45],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",'
    biosup_line = '"P1O[3],Enter BIOS setup (hold HELP),Off,On;"'
    page_line = '"P1,DIP Switch;"'
    cases: list[tuple[str, str, tuple]] = [
        ("the RAM Size default is 1M again", "top",
         ('"O[63:61],RAM Size,16M,', '"O[63:61],RAM Size,1M,')),
        ("a selected field is never read by the RTL", "top",
         (".osd_bios_setup(status[3]),", ".osd_bios_setup(1'b0),")),
        ("a field is wired to a port its module ignores", "osd",
         ("assign bios_setup = osd_bios_setup;", "assign bios_setup = 1'b0;")),
        ("two declared fields share a bit", "top",
         ('"P1O[31:28],Machine,', '"P1O[46:45],Machine,')),
        ("an option field shares a bit with an action field", "top",
         ('"R[0],Reset and close OSD;"',
          '"R[0],Reset and close OSD;"\n\t"P1O[0],Sharpen,Off,On;"')),
        ("a field's position 0 is not the machine's", "top",
         (biosup_line, '"P1O[3],Enter BIOS setup (hold HELP),On,Off;"')),
        ("an option list longer than its field is wide", "top",
         (biosup_line, '"P1O[3],Enter BIOS setup (hold HELP),Off,On,Maybe;"')),
        ("a new option field with no measured default", "top",
         (scale_line, scale_line + '\n\t"O[5],Teleport,Off,On;",')),
        ("the RAM size table drifts a code", "osd",
         ("3'd0:    ram_size_code = 3'd4;", "3'd0:    ram_size_code = 3'd5;")),
        ("the Machine field loses its CONF_STR entry", "top",
         ('"P1O[31:28],Machine,Xe10,Xe;"', '"P1O[27:24],Machine,Xe10,Xe;"')),
        ("a status-bit field is written in a form the parser cannot read", "top",
         ('"O[17:14],CPU Speed,', '"O(17:14),CPU Speed,')),
        ("an option is filed under a sub-page nothing declares", "top",
         ('"P1O[32],GDC Clock,2.5 MHz,5 MHz;"', '"P3O[32],GDC Clock,2.5 MHz,5 MHz;"')),
        ("a page tag comes after the field it scopes", "top",
         ('"P1O[32],GDC Clock,2.5 MHz,5 MHz;"', '"O[32]P1,GDC Clock,2.5 MHz,5 MHz;"')),
        ("a declared sub-page holds nothing", "top",
         (biosup_line, biosup_line + '\n\t"P2,Empty Page;"')),
        ("a page definition loses its title", "top",
         (page_line, '"P1,"')),
        ("a page tag names the root menu", "top",
         ('"P1O[32],GDC Clock,2.5 MHz,5 MHz;"', '"P0O[32],GDC Clock,2.5 MHz,5 MHz;"')),
        # --- the hardware-switch fields' own classes -------------------------------------
        ("a DIP field is moved out of the DIP sub-page", "top",
         ('"P1O[42:40],Boot order,Auto,640K,1M,MO,SASI1,SASI2,SCSI;"',
          '"O[42:40],Boot order,Auto,640K,1M,MO,SASI1,SASI2,SCSI;"')),
        ("the FDD mode switch is moved out of the DIP sub-page", "top",
         ('"P1O[38],FDD mode,Auto,Fixed;"', '"O[38],FDD mode,Auto,Fixed;"')),
        ("the Boot order list's labels are swapped", "top",
         ('"P1O[42:40],Boot order,Auto,640K,1M,MO,SASI1,SASI2,SCSI;"',
          '"P1O[42:40],Boot order,640K,Auto,1M,MO,SASI1,SASI2,SCSI;"')),
        ("the Boot order position->code table drifts", "crtc",
         ("3'd1:    msw_fdd_nib = 4'd2;", "3'd1:    msw_fdd_nib = 4'd4;")),
        ("a boot-device position's code drifts", "crtc",
         ("3'd4:    msw_fdd_nib = 4'd10;", "3'd4:    msw_fdd_nib = 4'd6;")),
        ("an FDD position the list does not offer stops describing the machine", "crtc",
         ("3'd7:    msw_fdd_nib = 4'd0;", "3'd7:    msw_fdd_nib = 4'd2;")),
        # --- the drives (5e): Mount/Eject pairs, their slot wiring, the layout ---------------
        ("a mounted drive has no Eject", "top",
         ('"T[9],Eject FDD1;",', '')),
        ("an Eject is named after a drive the menu does not mount", "top",
         ('"T[9],Eject FDD1;"', '"T[9],Eject FDD0;"')),
        ("an Eject is wired to another drive's slot", "top",
         ("assign eject_req[1] = status[9];", "assign eject_req[1] = status[10];")),
        ("two CPU Speed labels are swapped", "top",
         ("8 MHz,6 MHz,", "6 MHz,8 MHz,")),
        ("the CPU Speed field's position 0 is a rate", "top",
         ("CPU Speed,Full,33 MHz,", "CPU Speed,33 MHz,Full,")),
        ("a CPU Speed label past the rate table", "top",
         ("0.75 MHz,0.5 MHz;", "0.75 MHz,0.5 MHz,0.25 MHz;")),
        ("cpu_throttle's rate table moves under the labels", "throttle",
         ("4'd5:    rate_khz = 8000;", "4'd5:    rate_khz = 10000;")),
        ("cpu_throttle grows an arm the OSD cannot reach", "throttle",
         ("default: rate_khz = 0; ", "4'd14:   rate_khz = 250;\n        default: rate_khz = 0; ")),
        ("the CPU Speed selector is wired to nothing", "top",
         (".cpu_speed_sel       (status[17:14]),", ".cpu_speed_sel       (4'd0),")),
        ("a drive's eject_req is wired to nothing", "top",
         ("assign eject_req[2] = status[10];", "assign eject_req[2] = 1'b0;")),
        ("an image slot's label is not Mount <drive>", "top",
         ('"S1,D88FDDHDM,Mount FDD1;",', '"S1,D88FDDHDM,FDD1;",')),
        # --- the formats each Mount entry offers (9) ----------------------------------------
        ("the HDD Mount hides HDI and VHD images", "top",
         ('"S0,IMGHDIVHD,Mount HDD;",', '"S0,IMG,Mount HDD;",')),
        ("a CD build's Mount drops PCD images", "top-cd",
         (cd_line, cd_line.replace("ISOPCD", "ISO"))),
        # --- the root menu's layout (8) ---------------------------------------------------
        ("an Eject sits above its Mount", "top",
         ('"S1,D88FDDHDM,Mount FDD1;",\n\t"T[9],Eject FDD1;",',
          '"T[9],Eject FDD1;",\n\t"S1,D88FDDHDM,Mount FDD1;",')),
        ("the drives go back to every Mount, then every Eject", "top",
         ('"T[9],Eject FDD1;",\n\t"S2,D88FDDHDM,Mount FDD2;",',
          '"S2,D88FDDHDM,Mount FDD2;",\n\t"T[9],Eject FDD1;",')),
        ("the ROM pack's load is back at the bottom", "top",
         (('\t"F0,BIN,Load BIOS ROM;",\n\t"-;",\n', ''),
          ('"R[0],Reset and close OSD;",', '"R[0],Reset and close OSD;",\n\t"-;",\n\t"F0,BIN,Load BIOS ROM;",'))),
        ("the floppies are listed above the hard disk", "top",
         (('\t"S1,D88FDDHDM,Mount FDD1;",\n\t"T[9],Eject FDD1;",\n', ''),
          ('\t"S0,IMGHDIVHD,Mount HDD;",',
           '\t"S1,D88FDDHDM,Mount FDD1;",\n\t"T[9],Eject FDD1;",\n\t"S0,IMGHDIVHD,Mount HDD;",'))),
        ("RAM Size and CPU Speed are split by a separator", "top",
         ('"O[17:14],CPU Speed,', '"-;",\n\t"O[17:14],CPU Speed,')),
        ("the DIP Switch page moves above the drives", "top",
         (('\t"P1,DIP Switch;",\n', ''),
          ('\t"S0,IMGHDIVHD,Mount HDD;",', '\t"P1,DIP Switch;",\n\t"-;",\n\t"S0,IMGHDIVHD,Mount HDD;",'))),
        ("a CD build lists the CD-ROM after the floppies", "top-cd",
         ((cd_line, nocd_line),
          ('"T[10],Eject FDD2;",', '"T[10],Eject FDD2;",\n\t"S4,ISOPCD,Mount CD-ROM;",\n\t"T[11],Eject CD-ROM;",'))),
        ("a CD build loses the CD-ROM's Eject", "top-cd",
         (cd_line, '"T[8],Eject HDD;S4,ISOPCD,Mount CD-ROM;' + cdvol_entry + '"')),
        ("the CD audio volume's default is NP2kai's -6 dB, not the owner's 0 dB", "top-cd",
         (cd_line, cd_line.replace("0 dB,-2 dB,-4 dB,-6 dB,",
                                   "-6 dB,-2 dB,-4 dB,0 dB,"))),
        ("a CD audio volume label misnames its gain code", "osd",
         ("3'd6:    cd_volume_code = 5'd25;", "3'd6:    cd_volume_code = 5'd24;")),
        ("the CD audio volume offers fewer positions than its field holds", "top-cd",
         (cd_line, cd_line.replace(",-12 dB,Off;", ",-12 dB;"))),
        ("a CD build's Eject is wired to the unused slot 3", "top-cd",
         ("assign eject_req[4] = status[11];", "assign eject_req[3] = status[11];")),
        ("a build without the CD offers the CD-ROM's Eject", "top-nocd",
         (f"CONF_STR_CD = {nocd_line};", 'CONF_STR_CD = "T[8],Eject HDD;T[11],Eject CD-ROM;";')),
    ]

    accepted = []
    for name, key, edit in cases:
        key, _, tag = key.partition("-")
        base = variants[tag] if tag else texts
        # One (old, new) pair, or a tuple of them applied in order (a MOVE is two edits).
        edits = edit if isinstance(edit[0], tuple) else (edit,)
        source = base[key]
        for old, new in edits:
            if source.count(old) != 1:
                break
            source = source.replace(old, new)
        else:
            old = None
        if old is not None:
            accepted.append((name, f"the mutation does not apply to {key} ({old!r})"))
            continue
        mutated = dict(base)
        mutated[key] = source
        run(mutated)
        if not problems:
            accepted.append((name, "the planted defect was NOT rejected"))
        else:
            print(f"  rejected  {name}: {problems[0]}")

    if accepted:
        print("OSD CONTRACT SELFTEST: FAIL")
        for name, why in accepted:
            print(f"  - {name}: {why}")
        return 1
    print(f"OSD CONTRACT SELFTEST: PASS ({len(cases)} planted defects rejected, "
          "honest source and its CD, data-only CD and --no-cdrom menus clean)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""The watchdog message and the tool that decodes it must agree, field for field.

WHY THIS EXISTS. pc9821_watchdog_msg.sv formats a 351-byte record and
tools/decode_telemetry.py decodes it by character index. Nothing in the tree
checked that the two still agreed, so the contract between a formatter and its
only reader was enforced by nobody. That is the same shape as the OSD contract
that broke in the field (a mapping no bench could reach) and the bench manifest
that could silently lose an entry: a reader-visible contract with no parser.

Two independent failures are possible and both are silent:

  * a placeholder byte (0x00 in the ROM) with no selector arm emits NUL into the
    middle of the message, so a field arrives short and every field after it
    shifts;
  * a selector arm on a byte that holds literal text overwrites the text, so a
    label is silently replaced by a hex digit.

The two COMPUTED records (PRF and GFX) are held to their own modules the same way: their labels
and lengths must be the decoder's field tables', and the last-byte index the report emitter
(pc9821_dbg_record) uses must be one less than the length its formatter declares.

Both are checked here. So is the field-by-field agreement with the decoder,
including the widths, because the decoder trusts the width to decide how many
characters belong to a field. And so is the THIRD writer: the report sequencer
substitutes the trigger byte by index, which is a coordinate in two files.

Fails-first: removing one selector arm, or changing one width in the decoder,
makes this exit non-zero.

Usage: tools/check_telemetry_contract.py
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RTL = ROOT / "src/pc9821/core/pc9821_watchdog_msg.sv"
RTL_SYS = ROOT / "src/pc9821/core/pc9821_system.sv"
# The report SEQUENCER: which record is in flight and which byte of it is presented. It was inline
# in pc9821_system.sv and was moved into its own module so the emission's pacing handshake
# could have a bench. The coordinates checked below travelled with it, so the emitter is searched
# in both files rather than in a filename.
RTL_SEQ = ROOT / "src/pc9821/core/pc9821_dbg_record.sv"
EMITTERS = (RTL_SEQ, RTL_SYS)


def emitter_text():
    return "\n".join(p.read_text() for p in EMITTERS if p.exists())


RTL_PRF = ROOT / "src/pc9821/core/pc9821_perf_msg.sv"
RTL_GFX = ROOT / "src/pc9821/core/pc9821_gfx_msg.sv"
DEC = ROOT / "tools/decode_telemetry.py"

# The contract: 351 bytes, ONE line, and the file states 214 of them are literal text. The record
# used to be 299 bytes over four lines and 277 until the HP field (the HPS block fetch's
# cycles) was appended before T, and 289 until the six STORAGE fields (FST/FCM/FRS/FCH
# for the FDC, ALB/ASE for the ATA) were appended before T the same way; the length and the
# literal count are restated here rather than derived so that a change to either has to be made in
# two places on purpose.
MSG_LEN = 351
EXPECTED_LITERAL_BYTES = 214

# The PRF record's own shape: the prefix "PRF", then N fields of (1-byte space + 2-char label
# + '=' + 8 hex digits), then one LF. The label text lives in the RTL's prf_label function, the
# length in its PRF_MSG_LEN, and the field list in the decoder's PRF_FIELDS; this is the third
# party that holds the three together. The field COUNT is not stated here on purpose: it is the
# decoder's list, so a field added to one side only fails the length comparison below rather than
# being masked by a second copy of the number.
PRF_PREFIX_LEN = 3
PRF_LABEL_LEN = 2
PRF_DIGITS = 8
PRF_SUFFIX_LEN = 1
PRF_SPACE_LEN = 1


def parse_rom(text):
    """Every `msg[i] = <value>;` into {index: byte}. '"X"' is a character, 8'hNN is a byte."""
    rom = {}
    for m in re.finditer(r"msg\[\s*(\d+)\]\s*=\s*([^;]+);", text):
        i = int(m.group(1))
        v = m.group(2).strip()
        if v.startswith('"'):
            rom[i] = ord(v.strip('"'))
        elif v.startswith("8'h"):
            # NOT v[4:]: "8'h50"[4:] is "0", which reads every literal as zero and
            # produces a page of convincing, entirely false findings.
            rom[i] = int(v.replace("8'h", ""), 16)
        elif v == "0":
            rom[i] = 0
        else:
            rom[i] = None
    return rom


def parse_dyn(text):
    """Every selector arm -- `16'dN: nib = ...;`, or the older `wdg_dyn = ...` -- into
    {index: expression}.

    The formatter used to spell every field byte `wdg_dyn = wdg_hc(<nibble>)`, which
    expanded to 92 copies of the nibble decoder; it now selects the nibble into `nib`
    and decodes once. The arm still names the index its field occupies, and the index
    set is the only part of it this check reads, so both spellings are accepted.
    """
    return {int(m.group(1)): m.group(2).strip()
            for m in re.finditer(r"16'd(\d+):\s*(?:wdg_dyn|nib)\s*=\s*([^;]+);", text)}


def render(rom, n):
    """The message as the UART sends it, with '#' where a field byte will land."""
    return "".join(chr(rom[i]) if rom.get(i) else "#" for i in range(n))


def decoder_fields(text):
    """(group, name, width) in declaration order, from the decoder's own tables."""
    out = []
    for m in re.finditer(r"([A-Z_0-9]+FIELDS)\s*=\s*\[(.*?)\n\]", text, re.S):
        for name, w in re.findall(r'\("([A-Z0-9]+)",\s*(\d+)', m.group(2)):
            out.append((m.group(1), name, int(w)))
    return out


def check_bench_indices(text, bad):
    """Four benches read a field out of the record BY INDEX, which is a coordinate this check can
    see and they cannot: tb_pc9821_artic_watch reads the U field's four digits one at a time,
    tb_pc9821_io_trace reads the 19 characters of " IO=#### DR=# IV=##", and tb_pc9821_fdc_dbg /
    tb_pc9821_ata_ctx read their storage field's first digit (FST_DIG0 / ALB_DIG0). All read a
    literal index, so a field that moves leaves them reading some other byte and failing for a
    reason that looks like a device fault. The formatter's rendered record is the authority; each
    entry names the anchor text and the offset from it to the first digit the bench reads, and the
    pair is compared here so the failure names the coordinate instead."""
    for path, pat, anchor, off in (
        (ROOT / "tests/pc9821/tb_pc9821_artic_watch.sv",
         r"msg_idx = 16'd(\d+); #1; umsg\[0\]", " U=", 3),
        (ROOT / "tests/pc9821/tb_pc9821_io_trace.sv",
         r"msg_idx = 16'd(\d+) \+ k", " IO=", 0),
        (ROOT / "tests/pc9821/tb_pc9821_fdc_dbg.sv",
         r"FST_DIG0 = 16'd(\d+)", " FST=", 5),
        (ROOT / "tests/pc9821/tb_pc9821_ata_ctx.sv",
         r"ALB_DIG0 = 16'd(\d+)", " ALB=", 5),
    ):
        if not path.exists():
            bad.append(f"the bench that reads the {anchor.strip()} field by index is missing: {path}")
            continue
        m = re.search(pat, path.read_text())
        if not m:
            bad.append(f"{path.name}: no literal record index found for the {anchor.strip()} field, "
                       f"so this check cannot hold it to the formatter")
            continue
        want = text.index(anchor) + off
        if int(m.group(1)) != want:
            bad.append(f"{path.name} reads the record from index {m.group(1)}, but the formatter "
                       f"puts the {anchor.strip()} field there at index {want}")


def check_trigger_index(rom, bad):
    """The trigger byte has TWO writers: the ROM (a '?' placeholder) and the report sequencer
    (which overwrites that index with the path letter). The index is therefore a coordinate
    written down in two files, and the one failure that would be invisible everywhere else is
    the two drifting apart: the emitter would substitute a hexadecimal digit into the middle of
    a field, and every width in the record would stay right. So the emitter's index must land on
    the ROM's '?', and the LF that ends the line must be the byte after it."""
    sys_text = emitter_text()
    m_trig = re.search(r"localparam \[15:0\] WDG_TRIG_IDX = 16'd(\d+);", sys_text)
    m_last = re.search(r"localparam \[15:0\] WDG_MSG_LAST = 16'd(\d+);", sys_text)
    if not m_trig or not m_last:
        bad.append("pc9821_system.sv does not declare both WDG_TRIG_IDX and WDG_MSG_LAST, so "
                   "the trigger's byte index cannot be checked against the formatter")
        return
    trig, last = int(m_trig.group(1)), int(m_last.group(1))
    if last != MSG_LEN - 1:
        bad.append(f"pc9821_system.sv says the record ends at index {last}, but it is "
                   f"{MSG_LEN} bytes: the last index is {MSG_LEN - 1}")
    if trig != MSG_LEN - 2:
        bad.append(f"pc9821_system.sv substitutes the trigger at index {trig}, but the trigger "
                   f"must be the SECOND-TO-LAST byte ({MSG_LEN - 2}): the last byte has to be "
                   f"the LF that ends the line, or the next record's start is glued to it")
    if rom.get(trig) != ord("?"):
        bad.append(f"index {trig} in the ROM is {rom.get(trig)!r}, not '?': the emitter "
                   f"overwrites this byte, so it must be the '?' that says nothing substituted it")
    if rom.get(MSG_LEN - 1) != 0x0A:
        bad.append(f"the record's last byte (index {MSG_LEN - 1}) is {rom.get(MSG_LEN - 1)!r}, "
                   f"not a single LF 0x0A")
    if rom.get(MSG_LEN - 2) == 0x0A or 0x0D in [rom.get(i) for i in range(MSG_LEN)]:
        bad.append("the record carries a CR (0x0D): a tty's ICRNL maps it to a second newline, "
                   "which is the blank line between records this record was rewritten to remove")


def check():
    bad = []
    rtl = RTL.read_text()
    dec = DEC.read_text()

    rom = parse_rom(rtl)
    dyn = parse_dyn(rtl)

    missing = [i for i in range(MSG_LEN) if i not in rom]
    if missing:
        bad.append(f"the ROM has no entry for indices {missing}")

    # Invariant 1: every placeholder is driven, or the message carries a NUL.
    undriven = sorted(i for i in range(MSG_LEN) if rom.get(i) == 0 and i not in dyn)
    if undriven:
        bad.append(f"{len(undriven)} placeholder byte(s) have no selector arm, so the message "
                   f"emits NUL and every later field shifts: {undriven}")

    # Invariant 2: no arm overwrites literal text.
    clobber = sorted(i for i in range(MSG_LEN) if rom.get(i) not in (0, None) and i in dyn)
    if clobber:
        bad.append(f"{len(clobber)} literal byte(s) are overwritten by a selector arm, so a "
                   f"label becomes a hex digit: {clobber}")

    literal = sum(1 for i in range(MSG_LEN) if rom.get(i))
    if literal != EXPECTED_LITERAL_BYTES:
        bad.append(f"{literal} literal bytes, expected {EXPECTED_LITERAL_BYTES}; either the "
                   f"message changed or the file's own header is now wrong")

    # Invariant 3: each decoder field's declared width equals the run of field slots
    # after its name in the rendered message. NAME must be delimited, or F= matches
    # inside TF= and P= matches inside EIP= and the check reports two phantom defects. The PRF
    # record's PRF_FIELDS is checked against ITS formatter below, not against this message.
    text = render(rom, MSG_LEN)
    for group, name, width in decoder_fields(dec):
        if group != "W_FIELDS":
            continue
        m = re.search(r"(?<![A-Z0-9])" + re.escape(name) + r"=(\?+|#+)", text)
        if not m:
            bad.append(f"{group}: {name} is not in the formatted message at all")
            continue
        got = len(m.group(1))
        if got != width:
            bad.append(f"{group}: {name} is declared width {width} in the decoder but the "
                       f"message gives it {got} character(s) -- the decoder would read "
                       f"{got} characters and mis-parse every field after it")

    # Invariant 4: the record is ONE line, so it may not carry the LF anywhere but its end.
    body_lf = [i for i in range(MSG_LEN - 1) if rom.get(i) == 0x0A]
    if body_lf:
        bad.append(f"the record carries an LF inside it, at {body_lf}: the record is one line "
                   f"and its only newline is its last byte")

    check_trigger_index(rom, bad)
    check_bench_indices(text, bad)
    bad.extend(check_perf(dec))
    bad.extend(check_gfx(dec))
    check_record_end(dec, bad)
    return bad


def check_record_end(dec_text, bad):
    """The emitter DECIDES EACH COMPUTED RECORD'S LAST BYTE by index, so PRF_MSG_LEN and
    GFX_MSG_LEN are coordinates written down in two files. A record that grew without the loop
    would emit its last byte from the next record's formatter, and every field would stay right,
    so this is checked here rather than trusted."""
    sys_text = emitter_text()
    # (module, counter, tag, index width). The PRF index is 9 bits (the record is 256 bytes, so
    # its length does not fit in 8); the GFX index is still 7 bits and its
    # 100-byte record still fits, so the two widths are named here rather than assumed common.
    for module, wire_name, tag, width in ((RTL_PRF, "prf_idx", "PRF", "9"),
                                         (RTL_GFX, "gfx_idx", "GFX", "7")):
        if not module.exists():
            continue
        m_len = re.search(r"[A-Z]{3}_MSG_LEN\s*=\s*" + width + r"'d(\d+)", module.read_text())
        m_end = re.search(r"if \(" + wire_name + r" == " + width + r"'d(\d+)\)", sys_text)
        if not m_len or not m_end:
            bad.append(f"the report emitter has no `if ({wire_name} == 7'dN)` end test for the "
                       f"{tag} record, or the record declares no length: the two cannot be held "
                       f"together")
            continue
        if int(m_end.group(1)) != int(m_len.group(1)) - 1:
            bad.append(f"the {tag} record is {m_len.group(1)} bytes, but the emitter ends it at "
                       f"index {m_end.group(1)} instead of {int(m_len.group(1)) - 1}")


def check_perf(dec_text):
    """The PRF record: its labels and length must be the decoder's, word for word.

    The stall record is checked by INDEX against a ROM; this record is computed from its counter
    inputs, so the two things that can drift are the FIELD LABELS (the RTL's prf_label function
    against the decoder's PRF_FIELDS) and the LENGTH (the RTL's PRF_MSG_LEN against the layout the
    loop walks). Both are checked here, and so is the LF: one LF, never a CR.
    """
    bad = []
    if not RTL_PRF.exists():
        return [f"the perf record module is missing: {RTL_PRF}"]
    prf = RTL_PRF.read_text()

    m = re.search(r"PRF_MSG_LEN\s*=\s*9'd(\d+)", prf)
    if not m:
        return ["pc9821_perf_msg.sv declares no PRF_MSG_LEN"]
    msglen = int(m.group(1))

    head = prf.split("function [7:0] prf_label", 1)
    if len(head) != 2:
        return ["pc9821_perf_msg.sv has no prf_label function"]
    labels = re.findall(r'"([A-Z0-9]{2})"', head[1].split("endfunction", 1)[0])

    fields = [f for f in decoder_fields(dec_text) if f[0] == "PRF_FIELDS"]
    names = [f[1] for f in fields]
    if names != labels:
        bad.append(f"PRF_FIELDS {names} does not match the RTL's label order {labels}")
        return bad

    for _, name, width in fields:
        if width != PRF_DIGITS:
            bad.append(f"PRF_FIELDS: {name} is declared width {width} in the decoder but the "
                       f"record emits {PRF_DIGITS} hex digits")

    want = (PRF_PREFIX_LEN +
            sum(PRF_SPACE_LEN + PRF_LABEL_LEN + 1 + w for _, _, w in fields) +
            PRF_SUFFIX_LEN)
    if want != msglen:
        bad.append(f"PRF_MSG_LEN is {msglen} but the decoder's {len(fields)} fields of "
                   f"{PRF_SPACE_LEN}+{PRF_LABEL_LEN}+1+{PRF_DIGITS} with a {PRF_PREFIX_LEN}-byte "
                   f"prefix and {PRF_SUFFIX_LEN}-byte suffix make {want}")
    m_nl = re.search(r"PRF_MSG_LEN - 1: ch = 8'h([0-9A-Fa-f]{2})", prf)
    if not m_nl or m_nl.group(1).upper() != "0A":
        bad.append("pc9821_perf_msg.sv's last byte is not a single LF (0x0A)")
    return bad


def check_gfx(dec_text):
    """The GFX record: its labels and length must be the decoder's, word for word.

    The same contract check check_perf applies to PRF. The two
    records are separate modules with separate layouts; this one is 88 bytes (a 3-byte prefix +
    seven 12-byte fields + one LF), and its last byte is an LF, never a CR.
    """
    bad = []
    if not RTL_GFX.exists():
        return [f"the graphics record module is missing: {RTL_GFX}"]
    gfx = RTL_GFX.read_text()

    m = re.search(r"GFX_MSG_LEN\s*=\s*7'd(\d+)", gfx)
    if not m:
        return ["pc9821_gfx_msg.sv declares no GFX_MSG_LEN"]
    msglen = int(m.group(1))

    head = gfx.split("function [7:0] gfx_label", 1)
    if len(head) != 2:
        return ["pc9821_gfx_msg.sv has no gfx_label function"]
    labels = re.findall(r'"([A-Z0-9]{2})"', head[1].split("endfunction", 1)[0])

    fields = [f for f in decoder_fields(dec_text) if f[0] == "GFX_FIELDS"]
    names = [f[1] for f in fields]
    if names != labels:
        bad.append(f"GFX_FIELDS {names} does not match the RTL's label order {labels}")
        return bad

    for _, name, width in fields:
        if width != PRF_DIGITS:
            bad.append(f"GFX_FIELDS: {name} is declared width {width} in the decoder but the "
                       f"record emits {PRF_DIGITS} hex digits")

    want = (PRF_PREFIX_LEN +
            sum(PRF_SPACE_LEN + PRF_LABEL_LEN + 1 + w for _, _, w in fields) +
            PRF_SUFFIX_LEN)
    if want != msglen:
        bad.append(f"GFX_MSG_LEN is {msglen} but the decoder's {len(fields)} fields of "
                   f"{PRF_SPACE_LEN}+{PRF_LABEL_LEN}+1+{PRF_DIGITS} with a {PRF_PREFIX_LEN}-byte "
                   f"prefix and {PRF_SUFFIX_LEN}-byte suffix make {want}")
    m_nl = re.search(r"GFX_MSG_LEN - 1: ch = 8'h([0-9A-Fa-f]{2})", gfx)
    if not m_nl or m_nl.group(1).upper() != "0A":
        bad.append("pc9821_gfx_msg.sv's last byte is not a single LF (0x0A)")
    return bad


def main():
    bad = check()
    rom = parse_rom(RTL.read_text())
    dyn = parse_dyn(RTL.read_text())
    if bad:
        print("TELEMETRY CONTRACT CHECK: FAIL")
        for b in bad:
            print(f"  - {b}")
        return 1
    literal = sum(1 for i in range(MSG_LEN) if rom.get(i))
    print(f"TELEMETRY CONTRACT CHECK: PASS ({MSG_LEN} bytes, {literal} literal, "
          f"{len(dyn)} from a field, {literal + len(dyn)} of {MSG_LEN} accounted for, "
          f"{len(decoder_fields(DEC.read_text()))} decoder fields agree)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

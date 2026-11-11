#!/usr/bin/env python3
"""mputest_decode.py - the tables, the reference wire model and the capture decoder of MPUTEST
(tools/hwprobe/mputest/mputest.s), the MIDI-interface probe.

THIS FILE OWNS THE TABLES. Every byte MPUTEST sends is a script in SCRIPTS below; the probe's
`mputest_tables.inc` and the bench include `tests/pc9821/mputest_bytes.svh` are GENERATED from
it (`--gen`; `--check` and `--selftest` fail on a stale copy), so the .COM, the core bench and
this decoder run the same bytes, and the capture carries the tables' CRC-32 to prove it.

Usage:
    python3 tools/hwprobe/mputest/mputest_decode.py --gen            # regenerate both includes
    python3 tools/hwprobe/mputest/mputest_decode.py --check          # includes current?
    python3 tools/hwprobe/mputest/mputest_decode.py --selftest
    python3 tools/hwprobe/mputest/mputest_decode.py MPUTEST.TXT      # check + summarise
    python3 tools/hwprobe/mputest/mputest_decode.py MPUTEST.TXT --wire WIRE.BIN [--model M]
            # compare a raw MIDI-OUT capture (ttyS1 at 31250, `amidi -r`, MidiLink UDP
            # payloads concatenated) with the stream the run must have produced
    python3 tools/hwprobe/mputest/mputest_decode.py --expect FLOW [--raw N] [--model M] [--hex]
            # write the expected wire stream of a run (FLOW = BYTES or DEFAULT[,RAW])
    python3 tools/hwprobe/mputest/mputest_decode.py MPUTEST.TXT --pair OTHER.TXT
            # two captures (core and card) side by side

THE OP ENCODING (one byte stream per section, terminated by 0x00):
    01 cc          CMD cc: poll BUSY (status bit 6) clear, write cc to the command port, wait
                   (bounded) for status bit 7 to clear, read the data port; every further byte
                   that is waiting is drained and counted. Printed as a `CMD` row.
    02 n b1..bn    DATA: n bytes (1..255) to the data port, BUSY polled before each.
    03 lo hi       WAIT lo+256*hi milliseconds (ARTIC-timed).
    04 text 24     LABEL: print `LABEL text` ('$'-terminated).
    05 lo hi       FIFO: an n-byte non-commercial SysEx (F0 7D d.. F7, d_i = i & 0x7F) written
                   with BUSY polled, the status recorded after each write (a `FIFO` row).
    06             RAW: the same SysEx shape, /RAW:n bytes (default 200), written with NO poll.
    00             end of section.

THE REFERENCE WIRE MODEL (`wire()`), per model:
  np2    NP2kai cbus/mpu98ii.c, the reference the core follows for the wire (5939e0c line numbers):
         sendmpureset (:247-258) sends 16 x {B0+ch, 7B, 00} and is called by both mpucmd_ff
         (:627-634) and mpucmd_3f (:471-477); in UART mode a data byte goes to the line as
         written (mpu98ii_o0 `if (mpu98.mode) { sent = cm_mpu98->write(...)`) and the command
         port honours only 0xFF, which ACKs and leaves UART mode with NO reset burst
         (mpu98ii_o2 `if (dat == 0xff) { mpu98.mode = 0; setrecvdata(MPUMSG_ACK);`); in
         intelligent mode 0xD0-0xD7 assemble one short message with running status expanded
         to a full status byte (sendmpumsg :793-813) and 0xDF passes a system message.
  manual the core's reference (todo item 173): np2's wire, but the 0xFF that leaves UART mode
         is NOT ACKed, as the Roland MPU-401 Technical Reference Manual says (section 5.3, "The
         MPU-401 will not return an ACK ($FE) in this one case."; section 4.1, "An ACK will not
         be sent back upon sending a SYSTEM RESET to leave the UART MODE ($3F).") and as a real
         MPU-PC98 does (docs/probes/MPUTEST-XE10.TXT, MPUTEST-XE10-BYTES.TXT: `ack=--`, 4 of 4).
         The manual is silent on MIDI OUT at a reset, so the bursts stay NP2kai's (item 174).
         Its wire is byte-identical to np2's; only the ACK expectation differs.
  quiet  manual's ACKs, but neither 0xFF nor 0x3F puts any byte on the line: what a card does
         if its reset only silences its own sequencer. It is a decoding hypothesis for a real
         card's capture (MPU-PC98 vs MPU-PC98II), not a claim; the decoder reports which
         model a capture matches.
The capture's CMD rows are checked against the manual model's ACKs (np2's differing answer is
noted beside a row).
A USB-MIDI capture (`amidi -r`) re-inserts running status and drops 0xFE/0xF8 unless `-a -c`
is given; `--wire` therefore also compares at the MIDI-message level, which both survive.

Exit status: 0 clean, 1 a check failed, 2 usage.
"""
import argparse
import pathlib
import re
import sys
import zlib

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
INC = HERE / "mputest_tables.inc"
SVH = ROOT / "tests/pc9821/mputest_bytes.svh"
ARTIC_HZ = 307_200

OP_END, OP_CMD, OP_DATA, OP_WAIT, OP_LABEL, OP_FIFO, OP_RAW = range(7)
RAW_DEFAULT = 200
FIFO_LEN = 200


# ---- MIDI message helpers ------------------------------------------------------------------
def roland_dt1(model, addr, data, dev=0x10):
    """A Roland DT1 (command 0x12) SysEx: F0 41 dev model 12 addr.. data.. sum F7, the sum
    being the value that makes (addr + data + sum) a multiple of 128 (the Roland checksum)."""
    body = list(addr) + list(data)
    return [0xF0, 0x41, dev, model, 0x12] + body + [(-sum(body)) & 0x7F, 0xF7]


# GS RESET: F0 41 10 42 12 40 00 7F 00 41 F7 (Roland GS: model 42, address 40 00 7F, data 00).
GS_RESET = roland_dt1(0x42, (0x40, 0x00, 0x7F), (0x00,))
assert GS_RESET == [0xF0, 0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7]


def sc_display_text(text):
    """The Sound Canvas display-letter message: model 0x45, address 10 00 00, up to 32 ASCII
    characters shown on the LCD (SC-55/SC-88 family; sources in the README)."""
    t = text.encode("ascii")[:32]
    return roland_dt1(0x45, (0x10, 0x00, 0x00), t)


def nonc_sysex(n):
    """An n-byte SysEx with the non-commercial manufacturer ID 0x7D (MIDI 1.0: reserved for
    non-commercial use, so every synth ignores it): F0 7D d0.. F7, d_i = i & 0x7F."""
    assert n >= 3
    return [0xF0, 0x7D] + [i & 0x7F for i in range(n - 3)] + [0xF7]


def wait(ms):
    return [OP_WAIT, ms & 0xFF, ms >> 8]


def cmd(c):
    return [OP_CMD, c]


def data(bs):
    out = []
    bs = list(bs)
    while bs:
        chunk, bs = bs[:255], bs[255:]
        out += [OP_DATA, len(chunk)] + chunk
    return out


def label(text):
    assert "$" not in text and len(text) < 70
    return [OP_LABEL] + list(text.encode("ascii")) + [0x24]


# ---- the scripts ---------------------------------------------------------------------------
def s_reset():
    return cmd(0xFF)


def s_uart():
    # enter UART mode, then 200 bytes back to back with BUSY polled (the FIFO row), then leave
    return cmd(0x3F) + [OP_FIFO, FIFO_LEN & 0xFF, FIFO_LEN >> 8] + cmd(0xFF)


def s_raw():
    # 100 ms after 0x3F first, so a reset burst (np2 model: 48 bytes, 15.4 ms) has drained and
    # the blind run meets an empty output path; the lone F7 afterwards closes a SysEx whose
    # own F7 was lost (a stray EOX is ignored by a receiver)
    return cmd(0x3F) + wait(100) + [OP_RAW] + wait(300) + data([0xF7]) + wait(100) + cmd(0xFF)


def s_exit():
    return cmd(0xFF)


C_SCALE = [60, 62, 64, 65, 67, 69, 71, 72]


def s_play():
    o = []
    o += label("UART mode (0x3F) - the next sound is the GS reset") + cmd(0x3F) + wait(1000)
    o += label("GS reset SysEx (SC-88 Pro: parts reset)") + data(GS_RESET) + wait(1000)
    o += label("SC-88 Pro display text 'PC-9821 MPUTEST'") + data(
        sc_display_text("PC-9821 MPUTEST  MIDI probe")) + wait(2000)
    o += label("C major scale, ch1 piano (prog 1)") + data([0xC0, 0x00]) + wait(500)
    for n in C_SCALE:
        o += data([0x90, n, 0x64]) + wait(300) + data([0x80, n, 0x40]) + wait(50)
    o += wait(800)
    o += label("chords ch1-4: piano/strings/trumpet/nylon gtr")
    o += data([0xC0, 0, 0xC1, 48, 0xC2, 56, 0xC3, 24]) + wait(500)
    for root in (60, 65, 67, 60):
        notes = [root, root + 4, root + 7, root + 12]
        if root == 65:
            notes = [60, 65, 69, 72]
        if root == 67:
            notes = [59, 62, 67, 71]
        for ch, n in enumerate(notes):
            o += data([0x90 + ch, n, 0x50])
        o += wait(900)
        for ch, n in enumerate(notes):
            o += data([0x80 + ch, n, 0x40])
        o += wait(100)
    o += wait(800)
    o += label("running status: 16 notes ch1, one 0x90 status byte")
    run = [0x90]
    for n in [60, 64, 67, 72, 76, 72, 67, 64] * 2:
        run += [n, 0x60]
    o += data(run[:1])
    for i in range(1, len(run), 2):
        o += data(run[i:i + 2]) + wait(110) + data([run[i], 0x00])
    o += wait(800)
    o += label("drums ch10: kick snare hat x4")
    for n in [36, 42, 38, 42] * 2:
        o += data([0x99, n, 0x64]) + wait(200) + data([0x89, n, 0x40])
    o += wait(800)
    o += label("long SysEx, 300 bytes, ID 7D (inaudible), then a note")
    o += data(nonc_sysex(300)) + data([0x90, 72, 0x64]) + wait(500) + data([0x80, 72, 0x40])
    o += wait(800)
    o += label("pitch bend sweep ch1 (strings): up 2, down 4, back")
    o += data([0xC0, 48, 0x90, 67, 0x64]) + wait(300)
    steps = ([0x2000 + i * 0x200 for i in range(1, 16)] + [0x3FFF] +
             [0x3FFF - i * 0x200 for i in range(1, 32)] + [0x0000] +
             [i * 0x200 for i in range(1, 17)])
    for v in steps:
        o += data([0xE0, v & 0x7F, v >> 7]) + wait(40)
    o += wait(300) + data([0x80, 67, 0x40, 0xC0, 0x00]) + wait(800)
    o += label("all notes off + reset controllers ch1-16")
    for ch in range(16):
        o += data([0xB0 + ch, 0x7B, 0x00, 0xB0 + ch, 0x79, 0x00])
    o += wait(500)
    o += label("leave UART mode (0xFF)") + cmd(0xFF) + wait(500)
    o += label("intelligent mode: 0xD0 note on, 0xD0 running-status off")
    o += cmd(0xD0) + data([0x90, 69, 0x64]) + wait(600) + cmd(0xD0) + data([69, 0x00])
    o += wait(300)
    o += label("intelligent mode: 0xDF SysEx (display text)")
    o += cmd(0xDF) + data(sc_display_text("MPUTEST done")) + wait(1500)
    return o


def s_bytes():
    """/BYTES: the fixed sequence for the byte-exact wire comparison (stage A). Every byte is
    listed in the README's /BYTES table."""
    o = []
    o += label("BYTES 1 reset 0xFF") + cmd(0xFF)
    o += label("BYTES 2 UART mode 0x3F") + cmd(0x3F)
    o += label("BYTES 3 GS reset") + data(GS_RESET)
    o += label("BYTES 4 program change + running-status run")
    o += data([0xC0, 0x00, 0x90, 0x3C, 0x40, 0x3E, 0x40, 0x40, 0x40,
               0x3C, 0x00, 0x3E, 0x00, 0x40, 0x00])
    o += label("BYTES 5 140-byte SysEx ID 7D") + data(nonc_sysex(140))
    o += label("BYTES 6 pitch bend centre + all notes off ch1")
    o += data([0xE0, 0x00, 0x40, 0xB0, 0x7B, 0x00])
    o += label("BYTES 7 0xFF in UART mode") + cmd(0xFF)
    o += label("BYTES 8 0xD0 short messages, running status")
    o += cmd(0xD0) + data([0x91, 0x3C, 0x40]) + cmd(0xD0) + data([0x3C, 0x00])
    o += label("BYTES 9 0xDF SysEx") + cmd(0xDF) + data([0xF0, 0x7D, 0x01, 0x02, 0x03, 0xF7])
    o += label("BYTES 10 reset 0xFF") + cmd(0xFF)
    return o


SCRIPTS = {
    "RESET": s_reset(), "UART": s_uart(), "PLAY": s_play(), "RAW": s_raw(),
    "EXIT": s_exit(), "BYTES": s_bytes(),
}
ORDER = ["RESET", "UART", "PLAY", "RAW", "EXIT", "BYTES"]


def tables_crc():
    blob = b"".join(bytes(SCRIPTS[k] + [OP_END]) for k in ORDER)
    return zlib.crc32(blob) & 0xFFFFFFFF


# ---- the reference model -------------------------------------------------------------------
MODELS = ("np2", "manual", "quiet")
SHORT_LEN = {0x8: 3, 0x9: 3, 0xA: 3, 0xB: 3, 0xC: 2, 0xD: 2, 0xE: 3, 0xF: 1}
BURST = [b for ch in range(16) for b in (0xB0 + ch, 0x7B, 0x00)]


class Card:
    """The reference card state across sections (mode and running status persist)."""

    def __init__(self, model):
        assert model in MODELS
        self.model = model
        self.uart = False
        self.phase = None     # None, 'short', 'long', 'follow'
        self.rstat = 0
        self.msg = []
        self.need = 0
        self.wire = []
        self.acks = []        # one bool per CMD: whether the reference ACKs it

    def command(self, c):
        if self.uart:
            if c == 0xFF:
                # leaves UART mode; only NP2kai ACKs it (see the docstring's manual model)
                self.uart = False
                self.acks.append(self.model == "np2")
            else:
                self.acks.append(False)
            return
        self.acks.append(True)
        self.phase = None
        if c == 0xFF:
            if self.model != "quiet":
                self.wire += BURST
            self.rstat = 0
        elif c == 0x3F:
            self.uart = True
            if self.model != "quiet":
                self.wire += BURST
        elif 0xD0 <= c <= 0xD7:
            self.phase, self.msg = "short", []
        elif c == 0xDF:
            self.phase, self.msg = "long", []
        elif 0xE0 <= c <= 0xEF:
            self.phase = "follow"

    def datum(self, b):
        if self.uart:
            self.wire.append(b)
            return
        if self.phase == "short":
            if not self.msg:
                if b & 0x80:
                    if (b & 0xF0) != 0xF0:
                        self.rstat = b
                    self.need = SHORT_LEN[b >> 4]
                    self.msg = [b]
                else:
                    self.need = SHORT_LEN.get(self.rstat >> 4, 0)
                    self.msg = [self.rstat, b]
            else:
                self.msg.append(b)
            if len(self.msg) >= self.need:
                self.wire += self.msg
                self.phase = None
        elif self.phase == "long":
            self.msg.append(b)
            head = self.msg[0]
            if ((head == 0xF0 and b == 0xF7) or (head in (0xF2, 0xF3) and len(self.msg) == 3)
                    or head not in (0xF0, 0xF2, 0xF3) or len(self.msg) >= 512):
                self.wire += self.msg
                self.phase = None
        elif self.phase == "follow":
            self.phase = None
        # idle: a stray data byte sends nothing

    def run(self, ops, raw_n=RAW_DEFAULT):
        for op in parse_ops(ops):
            if op[0] == "CMD":
                self.command(op[1])
            elif op[0] == "DATA":
                for b in op[1]:
                    self.datum(b)
            elif op[0] == "FIFO":
                for b in nonc_sysex(op[1]):
                    self.datum(b)
            elif op[0] == "RAW":
                for b in nonc_sysex(raw_n):
                    self.datum(b)


def parse_ops(ops):
    out, i = [], 0
    while i < len(ops):
        o = ops[i]
        if o == OP_END:
            break
        if o == OP_CMD:
            out.append(("CMD", ops[i + 1])); i += 2
        elif o == OP_DATA:
            n = ops[i + 1]; out.append(("DATA", ops[i + 2:i + 2 + n])); i += 2 + n
        elif o == OP_WAIT:
            out.append(("WAIT", ops[i + 1] | ops[i + 2] << 8)); i += 3
        elif o == OP_LABEL:
            j = ops.index(0x24, i)
            out.append(("LABEL", bytes(ops[i + 1:j]).decode("ascii"))); i = j + 1
        elif o == OP_FIFO:
            out.append(("FIFO", ops[i + 1] | ops[i + 2] << 8)); i += 3
        elif o == OP_RAW:
            out.append(("RAW",)); i += 1
        else:
            raise ValueError("bad op %02x at %d" % (o, i))
    return out


def flow_sections(flow):
    """The sections a run executes, in order, from the capture's FLOW= field."""
    f = flow.upper().split(",")
    if "BYTES" in f:
        return ["BYTES"]
    secs = ["RESET", "UART"]
    if "NOPLAY" not in f:
        secs.append("PLAY")
    if "RAW" in f:
        secs.append("RAW")
    secs.append("EXIT")
    return secs


def expected(flow, model="manual", raw_n=RAW_DEFAULT):
    card = Card(model)
    for s in flow_sections(flow):
        if s == "RESET":
            card.run(SCRIPTS["RESET"])
            card.command(0x94)          # the IRQ section's ACK-only command (see mputest.s)
        else:
            card.run(SCRIPTS[s], raw_n)
    return card


# ---- generation ----------------------------------------------------------------------------
def hexrows(bs, per=16, prefix="    .byte "):
    rows = []
    for i in range(0, len(bs), per):
        rows.append(prefix + ", ".join("0x%02X" % b for b in bs[i:i + per]))
    return rows


def gen_inc():
    out = ["/* GENERATED by tools/hwprobe/mputest/mputest_decode.py --gen - DO NOT EDIT.",
           " * The op scripts MPUTEST runs (encoding in that file's docstring). */",
           "    .equ TABLES_CRC_HI, 0x%04X" % (tables_crc() >> 16),
           "    .equ TABLES_CRC_LO, 0x%04X" % (tables_crc() & 0xFFFF),
           "    .equ RAW_DEFAULT, %d" % RAW_DEFAULT]
    for k in ORDER:
        out.append("ops_%s:" % k.lower())
        out += hexrows(SCRIPTS[k] + [OP_END])
    out.append("tables_crc_str: .ascii \"%08X$\"" % tables_crc())
    return "\n".join(out) + "\n"


def gen_svh():
    ops = SCRIPTS["BYTES"] + [OP_END]
    card = expected("BYTES")
    w = card.wire
    out = ["// GENERATED by tools/hwprobe/mputest/mputest_decode.py --gen - DO NOT EDIT.",
           "// MPUTEST /BYTES: the op script the DOS probe runs (MPUTEST_OPS, the encoding in",
           "// mputest_decode.py's docstring), the MIDI-OUT byte stream NP2kai's cbus/mpu98ii.c",
           "// produces for it (MPUTEST_WIRE) and the ACK per command (MPUTEST_ACK) of the model",
           "// \"manual\" in that file's Card class: no ACK for the 0xFF that leaves UART mode.",
           "// Tables CRC-32 %08X (printed by the probe)." % tables_crc(),
           "localparam int MPUTEST_OPS_N = %d;" % len(ops),
           "localparam int MPUTEST_WIRE_N = %d;" % len(w),
           "localparam int MPUTEST_CMD_N = %d;" % len(card.acks),
           "localparam logic [7:0] MPUTEST_OPS [MPUTEST_OPS_N] = '{"]
    out.append(",\n".join("  " + ", ".join("8'h%02X" % b for b in ops[i:i + 12])
                          for i in range(0, len(ops), 12)) + "};")
    out.append("localparam logic [7:0] MPUTEST_WIRE [MPUTEST_WIRE_N] = '{")
    out.append(",\n".join("  " + ", ".join("8'h%02X" % b for b in w[i:i + 12])
                          for i in range(0, len(w), 12)) + "};")
    out.append("localparam logic MPUTEST_ACK [MPUTEST_CMD_N] = '{" +
               ", ".join("1'b%d" % a for a in card.acks) + "};")
    return "\n".join(out) + "\n"


def gen_all():
    return {INC: gen_inc(), SVH: gen_svh()}


def do_check():
    bad = 0
    for p, text in gen_all().items():
        if not p.exists() or p.read_text() != text:
            print("STALE: %s (run mputest_decode.py --gen)" % p.relative_to(ROOT))
            bad = 1
    if not bad:
        print("mputest tables: generated files current (crc %08X)" % tables_crc())
    return bad


# ---- capture parsing -----------------------------------------------------------------------
HDR_RE = re.compile(r"^MPUTEST v(\d+) tables=([0-9A-F]{8}) flow=(\S+) raw=(\d+)")
CMD_RE = re.compile(r"^CMD (\S+) (\w\w) ack=(\S\S) polls=([0-9A-F]+) t=([0-9A-F]+) "
                    r"extra=([0-9A-F]+)(?: busy=([0-9A-F]+))?")
PORT_RE = re.compile(r"^PORT base=([0-9A-F]{4}) st=([0-9A-F]{2}) dat=([0-9A-F]{2})")
FOUND_RE = re.compile(r"^(FOUND|NOTFOUND)(?: base=([0-9A-F]{4}))?")
IRQ_RE = re.compile(r"^IRQ imr=([0-9A-F]{4}) before=([0-9A-F]{4}) pend=([0-9A-F]{4}) "
                    r"after=([0-9A-F]{4}) ack=(\S\S)")
FIFO_RE = re.compile(r"^FIFO n=([0-9A-F]+) first_busy=([0-9A-F]+) busy_polls=([0-9A-F]+) "
                     r"t=([0-9A-F]+) timeouts=([0-9A-F]+)")
RAWR_RE = re.compile(r"^RAWW n=([0-9A-F]+) t=([0-9A-F]+) st=([0-9A-F]{2})")
STS_RE = re.compile(r"^FIFOST ((?:[0-9A-F]{2} ?)+)$")


def parse_capture(text):
    lines = [l.rstrip("\r") for l in text.split("\n")]
    cap = {"hdr": None, "begins": [], "ends": [], "cmds": [], "ports": [], "found": None,
           "irq": None, "fifo": None, "fifost": [], "raww": None, "done": False,
           "errors": [], "notes": []}
    for no, l in enumerate(lines, 1):
        m = HDR_RE.match(l)
        if m:
            cap["hdr"] = dict(v=int(m[1]), tables=m[2], flow=m[3], raw=int(m[4]))
            continue
        if l.startswith("BEGIN:"):
            cap["begins"].append(l[6:].strip()); continue
        if l.startswith("END:"):
            cap["ends"].append(l[4:].strip()); continue
        m = CMD_RE.match(l)
        if m:
            cap["cmds"].append(dict(sec=m[1], cmd=int(m[2], 16), ack=m[3],
                                    polls=int(m[4], 16), t=int(m[5], 16),
                                    extra=int(m[6], 16),
                                    busy=int(m[7], 16) if m[7] else 0)); continue
        m = PORT_RE.match(l)
        if m:
            cap["ports"].append((int(m[1], 16), int(m[2], 16), int(m[3], 16))); continue
        m = FOUND_RE.match(l)
        if m:
            cap["found"] = int(m[2], 16) if m[2] else None; continue
        m = IRQ_RE.match(l)
        if m:
            cap["irq"] = dict(imr=int(m[1], 16), before=int(m[2], 16), pend=int(m[3], 16),
                              after=int(m[4], 16), ack=m[5]); continue
        m = FIFO_RE.match(l)
        if m:
            cap["fifo"] = dict(n=int(m[1], 16), first_busy=int(m[2], 16),
                               busy_polls=int(m[3], 16), t=int(m[4], 16),
                               timeouts=int(m[5], 16)); continue
        m = STS_RE.match(l)
        if m:
            cap["fifost"] += [int(x, 16) for x in m[1].split()]; continue
        m = RAWR_RE.match(l)
        if m:
            cap["raww"] = dict(n=int(m[1], 16), t=int(m[2], 16), st=int(m[3], 16)); continue
        if l.startswith("MPUTEST DONE"):
            cap["done"] = True
    if cap["hdr"] is None:
        cap["errors"].append("HEADER-MISSING")
    elif cap["hdr"]["tables"] != "%08X" % tables_crc():
        cap["errors"].append("TABLES-MISMATCH: capture %s, this decoder %08X (a different "
                             "build of the probe)" % (cap["hdr"]["tables"], tables_crc()))
    for b in cap["begins"]:
        if b not in cap["ends"]:
            cap["errors"].append("TRUNCATED in section %s (BEGIN without END)" % b)
    if not cap["done"]:
        cap["errors"].append("DONE-MISSING")
    return cap


def irq_bits(word):
    """The 16-bit {slave,master} IRR word -> IRQ numbers. Master IR7 is the slave's cascade
    input on the PC-98, so it is dropped when a slave line explains it."""
    bits = [i for i in range(16) if word >> i & 1]
    if 7 in bits and any(b >= 8 for b in bits):
        bits.remove(7)
    return bits


def us(ticks):
    return ticks * 1e6 / ARTIC_HZ


def summarise(cap, out=print):
    h = cap["hdr"] or {}
    out("MPUTEST capture: flow=%s raw=%s tables=%s" % (h.get("flow"), h.get("raw"),
                                                      h.get("tables")))
    for base, st, dat in cap["ports"]:
        out("  port %04X: status %02X data %02X%s" % (base, st, dat,
                                                     "  <- answers" if st != 0xFF else ""))
    out("  card base: %s" % ("%04X" % cap["found"] if cap["found"] is not None else "NONE"))
    if cap["irq"]:
        q = cap["irq"]
        new = q["pend"] & ~q["before"]
        out("  IRQ: request seen on %s (IRR before %04X, ACK pending %04X, after read %04X, "
            "IMR %04X)" % (irq_bits(new) or "no line", q["before"], q["pend"], q["after"],
                           q["imr"]))
        # Only IR6 (INT2, master bit 6) is the card's line: other lines that rise in the same
        # window (a slave line and its master IR7 cascade on the Xe10 run) are not the card's.
        ir6 = 1 << 6
        if new & ir6:
            out("       after the ACK read the IR6 request is %s" %
                ("HELD in the IRR" if q["after"] & ir6 else "WITHDRAWN"))
        elif new:
            out("       no IR6 request: the lines that rose are not the card's")
    flow = h.get("flow", "DEFAULT")
    card = expected(flow, "manual", h.get("raw", RAW_DEFAULT))
    np2 = expected(flow, "np2", h.get("raw", RAW_DEFAULT))
    if len(cap["cmds"]) != len(card.acks):
        out("  WARNING: %d CMD rows, the run has %d commands" % (len(cap["cmds"]),
                                                               len(card.acks)))
    for c, want, want_np2 in zip(cap["cmds"], card.acks, np2.acks):
        got = c["ack"] != "--"
        flag = "" if got == want else "   <- reference (MPU-401 manual) %s" % (
            "ACKs" if want else "does not ACK")
        if want_np2 != want:
            flag += "   (NP2kai %s)" % ("ACKs" if want_np2 else "does not ACK")
        out("  CMD %-5s %02X ack=%s %7.1f us (%d polls) extra=%d busy-polls=%d%s" % (
            c["sec"], c["cmd"], c["ack"], us(c["t"]), c["polls"], c["extra"], c["busy"], flag))
    if cap["fifo"]:
        f = cap["fifo"]
        rate = (us(f["t"]) / f["n"]) if f["n"] else 0
        out("  FIFO: %d bytes BUSY-polled in %.1f ms (%.1f us/byte; 320 us is the 31250-baud "
            "line), first BUSY before write #%d, %d busy polls, %d timeouts" % (
                f["n"], us(f["t"]) / 1000, rate, f["first_busy"], f["busy_polls"],
                f["timeouts"]))
        if cap["fifost"]:
            out("        status after each of the first writes: %s" %
                " ".join("%02X" % s for s in cap["fifost"]))
    if cap["raww"]:
        r = cap["raww"]
        out("  RAW: %d bytes written blind in %.1f us, status after %02X (compare the wire "
            "capture for the bytes that survived)" % (r["n"], us(r["t"]), r["st"]))
    for e in cap["errors"]:
        out("  ERROR: " + e)
    return 1 if cap["errors"] else 0


# ---- wire comparison -----------------------------------------------------------------------
def messages(stream, drop_rt=True):
    """Parse a MIDI byte stream into complete messages, running status expanded, real-time
    bytes (F8-FF) dropped when drop_rt (what `amidi -r` does without -a/-c)."""
    out, status, cur, need, sysex = [], 0, [], 0, None
    for b in stream:
        if b >= 0xF8:
            if not drop_rt:
                out.append((b,))
            continue
        if sysex is not None:
            if b == 0xF7:
                out.append(tuple(sysex + [b])); sysex = None
                continue
            if b & 0x80:
                out.append(tuple(sysex) + ("UNTERMINATED",)); sysex = None
            else:
                sysex.append(b)
                continue
        if b == 0xF0:
            sysex = [b]; continue
        if b & 0x80:
            if b == 0xF7:
                out.append(("STRAY-F7",)); continue
            status = b if b < 0xF0 else 0
            cur, need = [b], SHORT_LEN[b >> 4]
            if b in (0xF1, 0xF3):
                need = 2
            elif b == 0xF2:
                need = 3
            elif b >= 0xF4:
                need = 1
        else:
            if not cur:
                if not status:
                    out.append(("ORPHAN", b)); continue
                cur, need = [status], SHORT_LEN[status >> 4]
            cur.append(b)
        if cur and len(cur) >= need:
            out.append(tuple(cur)); cur = []
    if sysex is not None:
        out.append(tuple(sysex) + ("UNTERMINATED",))
    return out


def compare_wire(got, want, out=print):
    """Byte-exact first; then message level (running status / USB-MIDI re-framing proof)."""
    if got == want:
        out("  WIRE: byte-exact, %d bytes" % len(got))
        return "exact"
    n = next((i for i, (a, b) in enumerate(zip(got, want)) if a != b), min(len(got), len(want)))
    out("  WIRE: not byte-exact: %d bytes captured, %d expected, first difference at byte %d"
        % (len(got), len(want), n))
    out("        expected ..%s" % " ".join("%02X" % b for b in want[max(0, n - 4):n + 12]))
    out("        captured ..%s" % " ".join("%02X" % b for b in got[max(0, n - 4):n + 12]))
    # a lone EOX (the F7 the /RAW section sends after its burst) is not a message: a
    # message-level capture path (NP2kai's cmmidi, USB-MIDI) drops it
    mg = [m for m in messages(got) if m != ("STRAY-F7",)]
    mw = [m for m in messages(want) if m != ("STRAY-F7",)]
    if mg == mw:
        out("  WIRE: message-level identical (%d messages): the difference is framing only "
            "(running status re-inserted or real-time bytes dropped by the capture path)"
            % len(mw))
        return "messages"
    k = next((i for i, (a, b) in enumerate(zip(mg, mw)) if a != b), min(len(mg), len(mw)))
    out("  WIRE: messages differ at message %d of %d expected (%d captured)" % (k, len(mw),
                                                                               len(mg)))
    for tag, lst in (("expected", mw), ("captured", mg)):
        for m in lst[k:k + 3]:
            out("        %s %s" % (tag, " ".join("%02X" % b if isinstance(b, int) else b
                                                 for b in m)[:120]))
    return "differ"


def wire_report(cap, wire_bytes, model=None, out=print):
    h = cap["hdr"] or {"flow": "DEFAULT", "raw": RAW_DEFAULT}
    results = {}
    for m in ([model] if model else ["manual", "quiet"]):
        out("model %s:" % m)
        results[m] = compare_wire(list(wire_bytes), expected(h["flow"], m, h["raw"]).wire, out)
    if "RAW" in h["flow"].upper().split(","):
        out("  RAW: the blind burst's survivors are counted from the 0x7D SysEx in the capture:")
        ms = [x for x in messages(list(wire_bytes)) if len(x) > 2 and x[1] == 0x7D]
        for x in ms:
            out("        7D SysEx of %d bytes%s" % (len(x), " (unterminated)"
                                                    if x[-1] == "UNTERMINATED" else ""))
    good = [m for m, r in results.items() if r in ("exact", "messages")]
    out("verdict: %s" % ("matches model %s" % "/".join(good) if good else "matches no model"))
    return 0 if good else 1


# ---- selftest ------------------------------------------------------------------------------
def synth_capture(flow="DEFAULT", ack_all=True, truncate=False):
    card = expected(flow)
    rows = ["MPUTEST v1 tables=%08X flow=%s raw=%d" % (tables_crc(), flow, RAW_DEFAULT),
            "BEGIN:DETECT", "PORT base=E0D0 st=80 dat=FE", "FOUND base=E0D0", "END:DETECT"]
    secs = flow_sections(flow)
    ci = 0
    for s in secs:
        rows.append("BEGIN:%s" % s)
        n = sum(1 for o in parse_ops(SCRIPTS[s]) if o[0] == "CMD") + (1 if s == "RESET" else 0)
        for _ in range(n):
            rows.append("CMD %s %02X ack=%s polls=0003 t=0001 extra=00" % (
                s, 0xFF, "FE" if (ack_all or card.acks[ci]) else "--"))
            ci += 1
        if s == "RESET":
            rows.append("IRQ imr=BFF8 before=0000 pend=0040 after=0040 ack=FE")
        if s == "UART":
            rows.append("FIFO n=00C8 first_busy=0010 busy_polls=00001234 t=00004CCC "
                        "timeouts=0000")
            rows.append("FIFOST 00 00 40 40")
        rows.append("END:%s" % s)
        if truncate:
            rows.pop()
            break
    if not truncate:
        rows.append("MPUTEST DONE")
    return "\r\n".join(rows) + "\r\n"


def selftest():
    fails = 0

    def check(cond, what):
        nonlocal fails
        print(("  ok   " if cond else "  FAIL ") + what)
        fails += 0 if cond else 1

    check(do_check() == 0, "generated includes are current")
    check(GS_RESET[-2] == 0x41, "GS reset checksum 0x41")
    d = sc_display_text("A")
    check(d[:8] == [0xF0, 0x41, 0x10, 0x45, 0x12, 0x10, 0x00, 0x00] and
          (sum(d[5:-1]) & 0x7F) == 0, "display DT1 framing and Roland checksum")
    b = expected("BYTES")
    check(b.wire[:48] == BURST and b.wire[48:96] == BURST, "manual: 0xFF and 0x3F both burst")
    check(b.wire[96:107] == GS_RESET, "manual: UART-mode bytes pass byte-exact after the bursts")
    i = len(b.wire) - 48 - 6 - 6
    check(b.wire[i:i + 6] == [0x91, 0x3C, 0x40, 0x91, 0x3C, 0x00],
          "manual: 0xD0 running status is expanded to a full status byte")
    cmds = [o[1] for o in parse_ops(SCRIPTS["BYTES"]) if o[0] == "CMD"]
    check(b.wire[-48:] == BURST and cmds == [0xFF, 0x3F, 0xFF, 0xD0, 0xD0, 0xDF, 0xFF] and
          b.acks == [True, True, False, True, True, True, True],
          "manual: the closing reset bursts, every /BYTES command ACKed but the UART-mode 0xFF")
    n = expected("BYTES", "np2")
    check(n.wire == b.wire and n.acks == [True] * len(n.acks),
          "np2: the same wire as manual, and every /BYTES command ACKed (the UART-mode 0xFF too)")
    d = expected("DEFAULT,RAW")
    check(sum(1 for a in d.acks if not a) == 3,
          "manual: the default run's three UART-mode exits (UART, PLAY, RAW) are not ACKed")
    q = expected("BYTES", "quiet")
    check(len(q.wire) == len(b.wire) - 3 * 48, "quiet model: no bursts")
    check(messages([0x90, 0x3C, 0x40, 0x3E, 0x40]) == [(0x90, 0x3C, 0x40), (0x90, 0x3E, 0x40)],
          "message parser expands running status")
    # a USB-MIDI style capture (running status re-inserted) matches at message level
    usb = []
    for m in messages(b.wire):
        usb += list(m)
    lines = []
    check(compare_wire(usb, b.wire, lines.append) == "messages",
          "framing-only difference is reported as message-level identical")
    lost = b.wire[:150] + b.wire[160:]
    check(compare_wire(lost, b.wire, lines.append) == "differ", "a lost byte is caught")
    cap = parse_capture(synth_capture("BYTES"))
    out = []
    check(summarise(cap, out.append) == 0 and not cap["errors"], "a clean capture decodes")
    cap = parse_capture(synth_capture("DEFAULT", truncate=True))
    check(any("TRUNCATED" in e for e in cap["errors"]) and "DONE-MISSING" in cap["errors"],
          "a truncated capture is flagged")
    bad = synth_capture("BYTES").replace("tables=%08X" % tables_crc(), "tables=00000000")
    check(any("TABLES-MISMATCH" in e for e in parse_capture(bad)["errors"]),
          "a capture of another build is flagged")
    cap = parse_capture(synth_capture("DEFAULT"))
    check(cap["irq"] and irq_bits(cap["irq"]["pend"] & ~cap["irq"]["before"]) == [6],
          "IRR word 0040 decodes to IRQ6")
    check(wire_report(parse_capture(synth_capture("BYTES")), b.wire, None, lines.append) == 0,
          "wire report: an exact manual stream passes")
    check(wire_report(parse_capture(synth_capture("BYTES")), lost, "np2", lines.append) == 1,
          "wire report: a lossy stream fails")
    print("SELFTEST %s (%d failures)" % ("PASS" if not fails else "FAIL", fails))
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("capture", nargs="?")
    ap.add_argument("--gen", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--wire")
    ap.add_argument("--model", choices=list(MODELS))
    ap.add_argument("--expect")
    ap.add_argument("--raw", type=int, default=RAW_DEFAULT)
    ap.add_argument("--hex", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("--pair")
    a = ap.parse_args()
    if a.gen:
        for p, text in gen_all().items():
            p.write_text(text)
            print("wrote %s" % p.relative_to(ROOT))
        return 0
    if a.check:
        return do_check()
    if a.selftest:
        return selftest()
    if a.expect:
        w = bytes(expected(a.expect, a.model or "manual", a.raw).wire)
        if a.out:
            pathlib.Path(a.out).write_bytes(w)
        if a.hex or not a.out:
            for i in range(0, len(w), 16):
                print(" ".join("%02X" % b for b in w[i:i + 16]))
        return 0
    if not a.capture:
        ap.print_usage()
        return 2
    cap = parse_capture(pathlib.Path(a.capture).read_bytes().decode("ascii", "replace"))
    rc = summarise(cap)
    if a.pair:
        print("--- %s" % a.pair)
        rc |= summarise(parse_capture(pathlib.Path(a.pair).read_bytes().decode("ascii",
                                                                                "replace")))
    if a.wire:
        rc |= wire_report(cap, pathlib.Path(a.wire).read_bytes(), a.model)
    return rc


if __name__ == "__main__":
    sys.exit(main())

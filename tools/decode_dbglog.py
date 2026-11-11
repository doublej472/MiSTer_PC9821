#!/usr/bin/env python3
"""decode_dbglog.py - decode the debug-UART instrument framework's capture.

The core's debug UART (/dev/ttyS1 on the MiSTer, 115200 8N1) carries, in a build made with any of
build_profile.py's --dbg-* / --cdrom-log options, a stream of records that pc9821_dbg_mux
interleaves ON RECORD BOUNDARIES. Every record is `0xA5, type, ...`; its total length is a
function of the type (LEN below, held equal to the RTL's table by tools/check_dbglog_contract.py).
Bytes outside a record - the core's "Z386 start" reset banner, which can land inside a record when
the guest resets mid-record and is removed first, and line noise - are skipped and counted.

  type          source                      record
  0x01-0x0B     CD drive (--dbg-cd)         pc9821_atapi's command log (see CD_NAMES)
  0x10-0x18     display log (--dbg-gdc)     a display-port write; 0x19 a text-attribute run;
                                            0x1E LOST, 0x1F ALIVE
  0x20 / 0x21   CPU sampler (--dbg-cpu)     34 bytes, every sample_ms; 0x21 = a sample was skipped
  0x30 / 0x31   memory snoop (--dbg-snoop)  a CPU write / a read response beat in the window;
                                            0x32 LOST events
  0x43 / 0x44   instruction trace (--dbg-trig)  one entry of the frozen ring / the trigger record
                                            (stage byte {tag, 0, last, stage}: tag 4 = an io:
                                            trigger, last = --dbg-last-ms)
  0x50-0x56     floppy log (--dbg-fdc)      FDC data write/read, MSR change, IRQ edge, control
                                            register, DMA write/read; 0x5E LOST, 0x5F ALIVE

Usage:
  decode_dbglog.py CAPTURE                 the records in order (samples condensed to one line)
  decode_dbglog.py CAPTURE --summary       counts per type, losses, span, skipped bytes
  decode_dbglog.py CAPTURE --bins [--bin S --top N]
                                           sampler rates per time bin and the top CS:IPs of each
  decode_dbglog.py CAPTURE --hist          CS:IP histogram of the samples
  decode_dbglog.py CAPTURE --trace         the frozen trace and its trigger
  decode_dbglog.py CAPTURE --snoop-check [--dump ADDR]
                                           replay the snoop into a shadow memory and report every
                                           read beat that does not return what was last written
  decode_dbglog.py CAPTURE --gdcw OUT      the display writes as `GDCW cyc=<ms> port=.. val=..` lines
  decode_dbglog.py CAPTURE --attrmap MS    the text attribute map the runs imply at MS
  decode_dbglog.py CAPTURE --json          one JSON object per record
  decode_dbglog.py CAPTURE --fdc           the floppy log alone, with each command's bytes, its
                                           result and the controller's last state at the end
  decode_dbglog.py --selftest              encode every record type, decode it, compare

  --from S / --to S select a time range (seconds from the first record of the capture).
  --clk-mhz F is clk_sys (default 80), for the snoop/trace cycle counters.
"""
from __future__ import annotations

import argparse
import collections
import json
import sys
from dataclasses import dataclass, field

BANNER = b"Z386 start\r\n"
SYNC = 0xA5

# Total record length by type. THE TABLE: pc9821_dbg_mux.sv's dbg_rec_len holds the same numbers.
LEN = {
    0x01: 8, 0x02: 16, 0x03: 12, 0x04: 18, 0x05: 9, 0x06: 9, 0x07: 5, 0x08: 5, 0x09: 5, 0x0A: 5,
    0x0B: 12,
    **{t: 7 for t in range(0x10, 0x19)}, 0x19: 9, 0x1E: 7, 0x1F: 7,
    0x20: 34, 0x21: 34,
    0x30: 15, 0x31: 15, 0x32: 8,
    0x43: 15, 0x44: 13,
    **{t: 7 for t in range(0x50, 0x57)}, 0x5E: 7, 0x5F: 7,
}
# Types whose last byte is 0x5A (a framing check the decoder applies).
TAIL5A = {0x20, 0x21, 0x43, 0x44}

CD_NAMES = {1: "CMD", 2: "CDB", 3: "DATA", 4: "DONE", 5: "MOUNT", 6: "READY", 7: "DEVCTL",
            8: "BANK", 9: "LOST", 10: "ALIVE", 11: "PLAYER"}
OPS = {0x00: 'TEST UNIT READY', 0x03: 'REQUEST SENSE', 0x12: 'INQUIRY', 0x1B: 'START/STOP',
       0x1E: 'PREVENT/ALLOW', 0x25: 'READ CAPACITY', 0x28: 'READ(10)', 0x2B: 'SEEK',
       0x42: 'READ SUB-CHANNEL', 0x43: 'READ TOC', 0x45: 'PLAY AUDIO', 0x46: 'GET CONFIG',
       0x47: 'PLAY AUDIO MSF', 0x4B: 'PAUSE/RESUME', 0x4E: 'STOP PLAY', 0x55: 'MODE SELECT',
       0x5A: 'MODE SENSE', 0xBD: 'MECHANISM STATUS', 0xBE: 'READ CD', 0xB9: 'READ CD MSF'}
GDC_PORTS = [0x60, 0x62, 0xA0, 0xA2, 0x68, 0x6A, 0xA4, 0xA6, 0x09A8]
# The sampler's byte map (pc9821_dbg_cpu's header): name -> byte offset.
SAMPLE_FIELDS = ["irq0", "irq1", "irq2", "mOth", "irq9", "irq13", "sOth", "vsirq", "w64", "imr",
                 "irr", "isr", "ata", "flags", "rdA0", "intr", "irq12", "simr", "sisr", "ud"]


def source_of(t: int) -> str:
    if 0x01 <= t <= 0x0B:
        return "cd"
    if 0x10 <= t <= 0x1F:
        return "gdc"
    if t in (0x20, 0x21):
        return "cpu"
    if t in (0x30, 0x31, 0x32):
        return "snoop"
    if 0x50 <= t <= 0x5F:
        return "fdc"
    return "trace"


@dataclass
class Rec:
    off: int                 # byte offset in the (banner-stripped) capture
    type: int
    src: str
    t: float                 # seconds on the record's own time base (unwrapped)
    p: bytes                 # the whole record
    f: dict = field(default_factory=dict)


@dataclass
class Capture:
    recs: list
    skipped: int = 0
    banners: int = 0
    total: int = 0


class Unwrap:
    """A free-running counter of `bits` bits, made monotonic: a value far below the last one is a
    wrap. A small step back is left alone (the snoop swaps a write and a read beat of one cycle)."""

    def __init__(self, bits: int):
        self.mod, self.base, self.prev = 1 << bits, 0, None

    def __call__(self, v: int) -> int:
        if self.prev is not None and self.prev - v > self.mod // 2:
            self.base += self.mod
            self.prev = v
        elif self.prev is None or v > self.prev:
            self.prev = v
        return self.base + v


def parse(data: bytes, clk_mhz: float = 80.0) -> Capture:
    banners = data.count(BANNER)
    data = data.replace(BANNER, b"")
    recs, skipped, i, n = [], 0, 0, len(data)
    uw = {"ms_cd": Unwrap(16), "ms_gdc": Unwrap(16), "ms_cpu": Unwrap(16), "cyc": Unwrap(32),
          "t_fdc": Unwrap(24)}
    clk_hz = clk_mhz * 1e6
    while i < n:
        t = data[i + 1] if i + 1 < n else -1
        ln = LEN.get(t)
        if data[i] != SYNC or ln is None or i + ln > n or (t in TAIL5A and data[i + ln - 1] != 0x5A):
            skipped += 1
            i += 1
            continue
        p = data[i:i + ln]
        src = source_of(t)
        r = Rec(i, t, src, 0.0, p)
        if src == "cd":
            r.t = uw["ms_cd"]((p[2] << 8) | p[3]) / 1000.0
        elif src == "gdc":
            r.t = uw["ms_gdc"]((p[2] << 8) | p[3]) / 1000.0
            if t == 0x19:
                r.f = dict(prev=(p[4] << 8) | p[5], start=(p[6] << 8) | p[7], val=p[8])
            elif t in (0x1E, 0x1F):
                r.f = dict(line=((p[4] & 3) << 8) | p[5], val=p[6])
            else:
                r.f = dict(port=GDC_PORTS[t - 0x10], line=((p[4] & 3) << 8) | p[5], val=p[6])
        elif src == "fdc":
            r.t = uw["t_fdc"](int.from_bytes(p[2:5], "big")) / 100000.0
            r.f = dict(a=p[5], b=p[6])
        elif src == "cpu":
            r.t = uw["ms_cpu"]((p[2] << 8) | p[3]) / 1000.0
            r.f = dict(cs=(p[4] << 8) | p[5], ip=(p[6] << 8) | p[7], lost=(t == 0x21),
                       **{k: p[8 + j] for j, k in enumerate(SAMPLE_FIELDS)},
                       udcs=(p[28] << 8) | p[29], udip=(p[30] << 8) | p[31], seq=p[32])
            r.f["pe"], r.f["vm"], r.f["if"], r.f["intr_now"] = (p[21] >> 7) & 1, (p[21] >> 6) & 1, (p[21] >> 5) & 1, (p[21] >> 4) & 1
        elif src == "snoop":
            cyc = uw["cyc"](int.from_bytes(p[2:6], "big"))
            r.t = cyc / clk_hz
            if t == 0x32:
                r.f = dict(cyc=cyc, lost=int.from_bytes(p[6:8], "big"))
            else:
                r.f = dict(cyc=cyc, read=(t == 0x31), addr=int.from_bytes(p[6:10], "big"), aux=p[10] & 0xF,
                           data=int.from_bytes(p[11:15], "big"))
        else:
            if t == 0x43:
                r.f = dict(idx=int.from_bytes(p[2:4], "big"), cs=int.from_bytes(p[4:6], "big"),
                           eip=int.from_bytes(p[6:10], "big"), sp=int.from_bytes(p[10:12], "big"),
                           flags=int.from_bytes(p[12:14], "big"))
            else:
                # stage byte {tag[3:0], 0, last, stage[1:0]} (pc9821_dbg_cpu rec_g)
                r.f = dict(stage=p[2] & 3, last=(p[2] >> 2) & 1, tag=p[2] >> 4,
                           addr=int.from_bytes(p[3:7], "big"), data=int.from_bytes(p[7:11], "big"),
                           be=p[11] & 0xF)
        recs.append(r)
        i += ln
    cap = Capture(recs, skipped, banners, n)
    # time bases of different sources are each from power-up; the capture's own zero is the first
    # record of any kind, which is the only common reference the stream carries
    return cap


def trigger_text(f: dict) -> str:
    """One line for a 0x44 record: an io: trigger names the port, the byte and the match count."""
    last = " (last occurrence)" if f.get("last") else ""
    if f.get("tag") == 4:
        return (f"stage {f['stage']}{last} OUT port={f['addr'] & 0xFFFF:04X} val={f['data'] & 0xFF:02X} "
                f"match #{f['data'] >> 8} since arming")
    return f"stage {f['stage']}{last} addr={f['addr']:08X} data={f['data']:08X} be={f['be']:X}"


def trace_of(cap: Capture):
    """(entries, trigger): the frozen trace in order and the 0x44 record (or None)."""
    ent = [r.f for r in cap.recs if r.type == 0x43]
    trg = [r.f for r in cap.recs if r.type == 0x44]
    return ent, (trg[-1] if trg else None)


def sample_line(r: Rec) -> str:
    f = r.f
    return (f"{r.t:9.3f}s  SAMPLE{'*' if f['lost'] else ' '} #{f['seq']:3d} {f['cs']:04X}:{f['ip']:04X} "
            f"{'PE ' if f['pe'] else ''}{'VM ' if f['vm'] else ''}{'IF ' if f['if'] else ''}"
            f"i0={f['irq0']} i1={f['irq1']} vs={f['vsirq']} i9={f['irq9']} i12={f['irq12']} i13={f['irq13']} "
            f"imr={f['imr']:02X} isr={f['isr']:02X} simr={f['simr']:02X} sisr={f['sisr']:02X} "
            f"ata={f['ata']} w64={f['w64']} a0={f['rdA0']} intr={f['intr']}")


def cd_line(r: Rec) -> str:
    t, p = r.type, r.p[4:]
    if t == 1:
        s = f"CMD    {p[0]:02x}  drhd={p[1]:02x} dev={p[2]} status_before={p[3]:02x}"
    elif t == 2:
        s = f"CDB    {' '.join(f'{b:02x}' for b in p)}  ({OPS.get(p[0], '?')})"
    elif t in (3, 4):
        s = (f"{'DATA' if t == 3 else 'DONE'}   status={p[0]:02x} error={p[1]:02x} ireason={p[2]:02x} "
             f"bytes={p[3] | (p[4] << 8)} sense={p[5]:x}/{p[6]:02x}/{p[7]:02x}")
        if t == 4:
            s += f"  read: {(p[12] << 8) | p[13]} words sum={(p[8] << 8) | p[9]:04x} xor={(p[10] << 8) | p[11]:04x}"
    elif t == 5:
        s = f"MOUNT  size={int.from_bytes(p, 'big')}"
    elif t == 6:
        s = f"READY  pcd={p[0]} tracks={p[1]} sectors={int.from_bytes(p[2:5], 'big')}"
    elif t == 7:
        s = f"DEVCTL {p[0]:02x}"
    elif t == 8:
        s = f"BANK   {p[0]:02x}"
    elif t == 11:
        s = (f"PLAYER status={p[0]:02x} pos={int.from_bytes(p[1:4], 'big')} left={int.from_bytes(p[4:7], 'big')} "
             f"engine_idle={p[7] >> 1 & 1} cdda_req={p[7] & 1}")
    elif t == 10:
        s = f"ALIVE  {p[0]:02x}  (power-up or the end of a core reset)"
    else:
        s = f"LOST   {p[0]} record(s)"
    return f"{r.t:9.3f}s  CD {s}"


FDC_CMDS = {0x02: "READ DIAGNOSTIC", 0x03: "SPECIFY", 0x04: "SENSE DRIVE STATUS", 0x05: "WRITE DATA",
            0x06: "READ DATA", 0x07: "RECALIBRATE", 0x08: "SENSE INT STATUS", 0x09: "WRITE DELETED",
            0x0A: "READ ID", 0x0C: "READ DELETED", 0x0D: "FORMAT", 0x0F: "SEEK", 0x11: "SCAN EQUAL",
            0x13: "CONFIGURE", 0x19: "SCAN LOW/EQ", 0x1D: "SCAN HIGH/EQ"}
FDC_CTL = {0: "0094", 1: "00CC", 2: "00BE", 3: "04BE", 4: "00BF"}
FDC_DMA = {0x09: "ch2 addr", 0x0B: "ch2 count", 0x11: "cmd/status", 0x13: "request", 0x15: "single mask",
           0x17: "mode", 0x19: "clear FF", 0x1B: "master clear", 0x1D: "clear mask", 0x1F: "all mask",
           0x23: "ch2 bank", 0x29: "bank mode", 0x39: "0439"}


def fdc_state(b: int) -> str:
    """pc9821_fdc dbg_state {IRQ, DRQ, st[2:0], x_st[2:0]}."""
    st = ["IDLE", "PARAM", "EXEC", "RESULT"][(b >> 3) & 3] if (b >> 3) & 7 < 4 else f"st{(b >> 3) & 7}"
    xs = ["-", "REQ", "XFER", "WEND", "NDW", "IDW"][b & 7] if b & 7 < 6 else f"x{b & 7}"
    return f"[{'I' if b & 0x80 else '.'}{'D' if b & 0x40 else '.'} {st}/{xs}]"


def fdc_line(r: Rec) -> str:
    t, a, b = r.type, r.f["a"], r.f["b"]
    if t == 0x50:
        s = f"WR 92 <- {a:02x}  {fdc_state(b)}"
        if (b >> 3) & 7 == 0:
            s += f"  ({FDC_CMDS.get(a & 0x1F, 'invalid')})"
    elif t == 0x51:
        s = f"RD 92 -> {a:02x}  {fdc_state(b)}"
    elif t == 0x52:
        s = f"MSR    -> {a:02x}  (after {b}{'+' if b == 255 else ''} read(s) of the previous value)"
    elif t == 0x53:
        s = f"IRQ {'RISE' if a else 'FALL'}   {fdc_state(b)}"
    elif t == 0x54:
        s = f"{'RD' if b & 0x80 else 'WR'} {FDC_CTL.get(b & 7, '?')} {'->' if b & 0x80 else '<-'} {a:02x}"
    elif t in (0x55, 0x56):
        s = f"DMA {'WR' if t == 0x55 else 'RD'} {(0x400 | a) if a == 0x39 else a:04x} ({FDC_DMA.get(a, '?')}) {'<-' if t == 0x55 else '->'} {b:02x}"
    elif t == 0x5E:
        s = f"LOST {a} record(s)"
    else:
        s = f"ALIVE {a:02x}"
    return f"{r.t:11.5f}s  FDC {s}"


def cmd_fdc(cap: Capture, t0, t1) -> None:
    rs = [r for r in cap.recs if r.src == "fdc" and in_range(r, t0, t1, {})]
    for r in rs:
        print(fdc_line(r))
    last = [r for r in rs if r.type in (0x50, 0x51, 0x53)]
    if last:
        print(f"# {len(rs)} floppy records; the controller's last reported state {fdc_state(last[-1].f['b'])}, "
              f"last MSR {next((r.f['a'] for r in reversed(rs) if r.type == 0x52), 0):02x}")


def line_of(r: Rec, vtotal: int = 440, vactive: int = 400) -> str:
    t, f = r.type, r.f
    if r.src == "fdc":
        return fdc_line(r)
    if r.src == "cpu":
        return sample_line(r)
    if r.src == "cd":
        return cd_line(r)
    if r.src == "gdc":
        if t == 0x19:
            return (f"{r.t:9.3f}s  GDC ATTR run from cell {f['start']} (row {f['start'] // 80}, col {f['start'] % 80}) "
                    f"= {f['val']:02x}   [previous run ended at cell {f['prev']}]")
        if t == 0x1F:
            return f"{r.t:9.3f}s  GDC ALIVE {f['val']:02x}"
        if t == 0x1E:
            return f"{r.t:9.3f}s  GDC LOST {f['val']} record(s)"
        dline = (f["line"] + 2) % vtotal
        return f"{r.t:9.3f}s  GDC OUT {f['port']:04x} <- {f['val']:02x}   raster {f['line']:3d} (decode line {dline:3d})"
    if r.src == "snoop":
        if t == 0x32:
            return f"{r.t:9.6f}s  SNOOP LOST {f['lost']} event(s)"
        k = f["aux"]
        extra = f" be={f['aux']:X}" if not f["read"] else f" req(line={k >> 3 & 1}, burst={k & 7})"
        return f"{r.t:9.6f}s  SNOOP {'R' if f['read'] else 'W'} {f['addr']:08X} {f['data']:08X}{extra}  cyc={f['cyc']}"
    if t == 0x43:
        return (f"TRACE  #{f['idx']:4d} {f['cs']:04X}:{f['eip']:08X} sp={f['sp']:04X} fl={f['flags']:04X}")
    return "TRIGGER " + trigger_text(f)


def in_range(r: Rec, t0, t1, base) -> bool:
    t = r.t - base.get(r.src, 0.0)
    return (t0 is None or t >= t0) and (t1 is None or t < t1)


def cmd_summary(cap: Capture) -> None:
    by = collections.Counter(r.type for r in cap.recs)
    print(f"{len(cap.recs)} records, {cap.skipped} byte(s) outside records, {cap.banners} reset banner(s), "
          f"{cap.total} byte(s) after the banners")
    for t in sorted(by):
        print(f"  0x{t:02X} {source_of(t):5s} x{by[t]}")
    lost_g = sum(r.f["val"] for r in cap.recs if r.type == 0x1E)
    lost_s = sum(r.f["lost"] for r in cap.recs if r.type == 0x32)
    lost_c = sum(r.p[4] for r in cap.recs if r.type == 0x09)
    lost_f = sum(r.f["a"] for r in cap.recs if r.type == 0x5E)
    smp = [r for r in cap.recs if r.src == "cpu"]
    skipped_samples = 0
    for a, b in zip(smp, smp[1:]):
        skipped_samples += (b.f["seq"] - a.f["seq"] - 1) & 255
    print(f"  records LOST: display {lost_g}, CD {lost_c}, floppy {lost_f}; snoop events lost {lost_s}; "
          f"samples skipped (sequence gaps) {skipped_samples}")
    for src in ("cd", "gdc", "fdc", "cpu", "snoop"):
        rs = [r for r in cap.recs if r.src == src]
        if rs:
            print(f"  {src}: {rs[0].t:.3f} .. {rs[-1].t:.3f} s on its own clock")


def cmd_bins(cap: Capture, width: float, top: int, t0, t1) -> None:
    rs = [r for r in cap.recs if r.src == "cpu"]
    if not rs:
        print("no sampler records")
        return
    base = rs[0].t
    rs = [r for r in rs if (t0 is None or r.t - base >= t0) and (t1 is None or r.t - base < t1)]
    bins = collections.OrderedDict()
    for r in rs:
        bins.setdefault(int((r.t - base) // width), []).append(r)
    for b, rr in bins.items():
        s = {k: sum(r.f[k] for r in rr) for k in ("irq0", "irq1", "irq2", "mOth", "irq9", "irq13", "sOth", "vsirq",
                                                    "w64", "ata", "rdA0", "intr", "irq12", "ud")}
        h = collections.Counter((r.f["cs"], r.f["ip"] & 0xFFF0) for r in rr)
        tops = " ".join(f"{cs:04X}:{ip:04X}x{c}" for (cs, ip), c in h.most_common(top))
        last = rr[-1].f
        print(f"{b * width:8.1f} n={len(rr):3d} i0={s['irq0']:3d} i1={s['irq1']:4d} i2={s['irq2']:3d} "
              f"vs={s['vsirq']:3d} w64={s['w64']:4d} m={s['mOth']:2d} i9={s['irq9']:3d} i13={s['irq13']:3d} "
              f"i12={s['irq12']:3d} so={s['sOth']:3d} ata={s['ata']:3d} a0={s['rdA0']:4d} "
              f"imr={last['imr']:02X} isr={last['isr']:02X} irr={last['irr']:02X} simr={last['simr']:02X} "
              f"sisr={last['sisr']:02X} fl={last['flags']:02X} ud={s['ud']} | {tops}")


def cmd_hist(cap: Capture, t0, t1) -> None:
    rs = [r for r in cap.recs if r.src == "cpu"]
    if not rs:
        print("no sampler records")
        return
    base = rs[0].t
    rs = [r for r in rs if (t0 is None or r.t - base >= t0) and (t1 is None or r.t - base < t1)]
    h = collections.Counter((r.f["cs"], r.f["ip"]) for r in rs)
    for (cs, ip), c in h.most_common(60):
        print(f"{cs:04X}:{ip:04X} {c:6d} {100.0 * c / len(rs):5.1f}%")


def cmd_trace(cap: Capture) -> None:
    ent, trg = trace_of(cap)
    for e in ent:
        print(f"#{e['idx']:4d} {e['cs']:04X}:{e['eip']:08X} sp={e['sp']:04X} fl={e['flags']:04X}")
    if trg:
        print("trigger: " + trigger_text(trg))
    else:
        print("no trigger record")
    print(f"# {len(ent)} trace entries")


def cmd_snoop_check(cap: Capture, dumps, limit: int) -> int:
    ev = [r for r in cap.recs if r.type in (0x30, 0x31)]
    # the collision swap reorders by at most one cycle: order by stamp, a read beat first on a tie
    ev.sort(key=lambda r: (r.f["cyc"], 0 if r.f["read"] else 1))
    samples = [r for r in cap.recs if r.src == "cpu"]
    print(f"{len(samples)} samples, {len(ev)} snoop events, "
          f"{sum(r.f['lost'] for r in cap.recs if r.type == 0x32)} lost, "
          f"{sum(1 for r in samples if r.f['lost'])} samples after a skip")
    shadow, lastw, mism = {}, {}, 0
    per_s = collections.Counter()
    t_first = ev[0].t if ev else 0.0
    for r in ev:
        f = r.f
        per_s[(int(r.t - t_first), "R" if f["read"] else "W")] += 1
        dw = f["addr"] & ~3
        if not f["read"]:
            for b in range(4):
                if f["aux"] >> b & 1:
                    shadow[dw + b] = (f["data"] >> (8 * b)) & 0xFF
            lastw[dw] = (f["cyc"], f["data"], f["aux"], r.t)
        else:
            bad = [b for b in range(4) if dw + b in shadow and shadow[dw + b] != (f["data"] >> (8 * b)) & 0xFF]
            if bad:
                mism += 1
                if mism <= limit:
                    lw = lastw.get(dw)
                    if lw:
                        print(f"MISMATCH t={r.t - t_first:9.6f} read {dw:08X}={f['data']:08X} bytes {bad}; last write "
                              f"{lw[1]:08X} be={lw[2]:X} {f['cyc'] - lw[0]} cycles earlier")
                    else:
                        print(f"MISMATCH t={r.t - t_first:9.6f} read {dw:08X}={f['data']:08X} (no dword write)")
    print(f"{mism} mismatching read beat(s)")
    secs = sorted({s for s, _ in per_s})
    print("per-second events (W/R):", " ".join(f"{s}:{per_s[(s, 'W')]}/{per_s[(s, 'R')]}" for s in secs))
    for x in dumps:
        print(f"-- history of {x & ~3:08X}")
        for r in ev:
            if r.f["addr"] & ~3 == x & ~3:
                print(f"  t={r.t - t_first:9.6f} cyc={r.f['cyc']:08X} {'R' if r.f['read'] else 'W'} "
                      f"{'' if r.f['read'] else 'be=%X ' % r.f['aux']}{r.f['data']:08X}")
    return mism


def cmd_gdcw(cap: Capture, out: str) -> None:
    lines = [f"GDCW cyc={int(r.t * 1000)} port={r.f['port']:04x} val={r.f['val']:02x} vline={r.f['line']}\n"
             for r in cap.recs if r.src == "gdc" and 0x10 <= r.type <= 0x18]
    with open(out, "w") as fh:
        fh.writelines(lines)
    print(f"{len(lines)} display write(s) -> {out}")


def cmd_attrmap(cap: Capture, at_ms: int) -> None:
    attr, run = [None] * 4096, None

    def close(end):
        if run is not None:
            for c in range(run[0], min(end, 4095) + 1):
                attr[c] = run[1]
    for r in cap.recs:
        if r.type != 0x19:
            continue
        if r.t * 1000 > at_ms:
            break
        close(r.f["prev"])
        run = (r.f["start"], r.f["val"])
    a2 = list(attr)
    if run is not None:
        a2[run[0]] = run[1]
    print("# attribute map (rows 0..24, cols 0..79); the open run is marked at its start only")
    for row in range(25):
        print(f"# {row:2d} " + " ".join("..".rjust(2) if a2[row * 80 + c] is None else f"{a2[row * 80 + c]:02x}" for c in range(80)))


# ------------------------------------------------------------------------------------------
# --selftest: an ENCODER written from the record definitions (not from parse()), round-tripped
# ------------------------------------------------------------------------------------------
def _encode_all() -> tuple[bytes, list]:
    out, want = bytearray(), []

    def add(rec: bytes, **expect):
        assert len(rec) == LEN[rec[1]], f"selftest encoder: type {rec[1]:02x} is {len(rec)} bytes, table says {LEN[rec[1]]}"
        out.extend(rec)
        want.append((rec[1], expect))
    ms = lambda v: v.to_bytes(2, "big")
    for t in range(1, 12):                                    # the CD log: 4-byte header + payload
        add(bytes([SYNC, t]) + ms(1000 + t) + bytes(range(1, LEN[t] - 3)), t=(1000 + t) / 1000)
    for n in range(9):                                        # display port writes
        add(bytes([SYNC, 0x10 + n]) + ms(2000 + n) + (123 + n).to_bytes(2, "big") + bytes([0x70 + n]),
            port=GDC_PORTS[n], line=123 + n, val=0x70 + n)
    add(bytes([SYNC, 0x19]) + ms(2100) + (79).to_bytes(2, "big") + (80).to_bytes(2, "big") + bytes([0xE1]),
        prev=79, start=80, val=0xE1)
    add(bytes([SYNC, 0x1E]) + ms(2101) + (0).to_bytes(2, "big") + bytes([7]), val=7)
    add(bytes([SYNC, 0x1F]) + ms(2102) + (0).to_bytes(2, "big") + bytes([0x5A]), val=0x5A)
    for t in (0x20, 0x21):                                    # samples
        fields = bytearray(range(1, 21))
        fields[13] = 0xA0                                     # the flags byte (offset 21 of the record)
        add(bytes([SYNC, t]) + ms(3000 + t) + (0xF800).to_bytes(2, "big") + (0x1234).to_bytes(2, "big")
            + bytes(fields) + (0xBEEF).to_bytes(2, "big") + (0x0102).to_bytes(2, "big") + bytes([77, 0x5A]),
            cs=0xF800, ip=0x1234, lost=(t == 0x21), seq=77, udcs=0xBEEF, udip=0x0102, pe=1, vm=0, **{"if": 1})
    cyc = 0x1000_0000
    add(bytes([SYNC, 0x30]) + cyc.to_bytes(4, "big") + (0x2FB20).to_bytes(4, "big") + bytes([0x3]) + (0xDEADBEEF).to_bytes(4, "big"),
        read=False, addr=0x2FB20, aux=3, data=0xDEADBEEF, cyc=cyc)
    add(bytes([SYNC, 0x31]) + (cyc + 5).to_bytes(4, "big") + (0x2FB24).to_bytes(4, "big") + bytes([0xB]) + (0x12345678).to_bytes(4, "big"),
        read=True, addr=0x2FB24, aux=0xB, data=0x12345678, cyc=cyc + 5)
    add(bytes([SYNC, 0x32]) + (cyc + 9).to_bytes(4, "big") + (3).to_bytes(2, "big"), lost=3, cyc=cyc + 9)
    add(bytes([SYNC, 0x43]) + (5).to_bytes(2, "big") + (0x1234).to_bytes(2, "big") + (0x5678).to_bytes(4, "big")
        + (0xFFFE).to_bytes(2, "big") + (0x0202).to_bytes(2, "big") + bytes([0x5A]), idx=5, cs=0x1234, eip=0x5678, sp=0xFFFE, flags=0x202)
    # the last entry of a 2^12 ring (--dbg-trace-aw 12): the index is 16 bits, here a V86 segment
    add(bytes([SYNC, 0x43]) + (4095).to_bytes(2, "big") + (0xFD80).to_bytes(2, "big") + (0x1A82).to_bytes(4, "big")
        + (0x0FFE).to_bytes(2, "big") + (0x0246).to_bytes(2, "big") + bytes([0x5A]), idx=4095, cs=0xFD80, eip=0x1A82, sp=0x0FFE, flags=0x246)
    t10 = lambda v: v.to_bytes(3, "big")                     # the floppy log's 10 us time
    for n, t in enumerate(list(range(0x50, 0x57)) + [0x5E, 0x5F]):
        add(bytes([SYNC, t]) + t10(0x123400 + n) + bytes([0x40 + n, 0x80 + n]),
            t=(0x123400 + n) / 100000.0, a=0x40 + n, b=0x80 + n)
    add(bytes([SYNC, 0x44, 2]) + (0x3D950).to_bytes(4, "big") + (0xDEADBEEF).to_bytes(4, "big") + bytes([0xF, 0x5A]),
        stage=2, addr=0x3D950, data=0xDEADBEEF, be=0xF, last=0, tag=0)
    # an io: trigger in the last-occurrence mode: OUT 0x0F to port 0x92, the 7th match
    add(bytes([SYNC, 0x44, 0x45]) + (0x92).to_bytes(4, "big") + (0x70F).to_bytes(4, "big") + bytes([0x0, 0x5A]),
        stage=1, addr=0x92, data=0x70F, be=0, last=1, tag=4)
    return bytes(out), want


def selftest() -> int:
    data, want = _encode_all()
    bad = 0

    def check(label, cap, want, skipped=0):
        nonlocal bad
        if len(cap.recs) != len(want) or cap.skipped != skipped:
            print(f"SELFTEST FAIL {label}: {len(cap.recs)} records ({cap.skipped} skipped), expected {len(want)}")
            bad += 1
            return
        for r, (t, exp) in zip(cap.recs, want):
            got = dict(r.f, t=r.t)
            diffs = {k: (got.get(k), v) for k, v in exp.items() if (got.get(k) != v if k != "t" else abs(got["t"] - v) > 1e-9)}
            if r.type != t or diffs:
                print(f"SELFTEST FAIL {label}: type {t:02x}: {diffs or ('decoded as %02x' % r.type)}")
                bad += 1
    check("plain", parse(data), want)
    # a reset banner landing INSIDE a record, line noise before the stream, and a 16-bit time wrap
    cut = data[:20] + BANNER + data[20:]
    check("banner inside a record", parse(b"\x00\xA5\x99" + cut), want, skipped=3)
    cap = parse(b"\x00\xA5\x99" + cut)
    if cap.banners != 1 or cap.skipped != 3:
        print(f"SELFTEST FAIL: banner/noise accounting: {cap.banners} banner(s), {cap.skipped} skipped (want 1, 3)")
        bad += 1
    wrap = b"".join(bytes([SYNC, 0x07]) + ms.to_bytes(2, "big") + b"\x00" for ms in (65530, 5, 40))
    ts = [r.t for r in parse(wrap).recs]
    if ts != [65.530, (65536 + 5) / 1000, (65536 + 40) / 1000]:
        print(f"SELFTEST FAIL: ms wrap: {ts}")
        bad += 1
    # a 5A tail that is missing is not a record
    broken = bytearray(data)
    off = next(r.off for r in parse(data).recs if r.type == 0x20)
    broken[off + 33] = 0x00
    if any(r.type == 0x20 and r.off == off for r in parse(bytes(broken)).recs):
        print("SELFTEST FAIL: a sample without its 0x5A tail was accepted")
        bad += 1
    # the table agrees with the RTL's, when the tree is here
    try:
        import check_dbglog_contract as c
        problems = c.table_problems()
        for p in problems:
            print("SELFTEST FAIL:", p)
        bad += len(problems)
    except ImportError:
        pass
    print("decode_dbglog.py --selftest:", "FAIL" if bad else f"PASS ({len(want)} record types round-tripped)")
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", nargs="?")
    ap.add_argument("--summary", action="store_true")
    ap.add_argument("--bins", action="store_true")
    ap.add_argument("--hist", action="store_true")
    ap.add_argument("--trace", action="store_true")
    ap.add_argument("--snoop-check", action="store_true")
    ap.add_argument("--dump", type=lambda x: int(x, 0), action="append", default=[])
    ap.add_argument("--max", type=int, default=60)
    ap.add_argument("--gdcw", metavar="OUT")
    ap.add_argument("--attrmap", type=int, metavar="MS")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--fdc", action="store_true")
    ap.add_argument("--bin", type=float, default=1.0)
    ap.add_argument("--top", type=int, default=4)
    ap.add_argument("--from", dest="t0", type=float)
    ap.add_argument("--to", dest="t1", type=float)
    ap.add_argument("--clk-mhz", type=float, default=80.0)
    ap.add_argument("--vtotal", type=int, default=440)
    ap.add_argument("--vactive", type=int, default=400)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.capture:
        ap.error("a capture file (or '-') is required")
    data = sys.stdin.buffer.read() if a.capture == "-" else open(a.capture, "rb").read()
    cap = parse(data, a.clk_mhz)
    if a.summary:
        cmd_summary(cap)
    elif a.bins:
        cmd_bins(cap, a.bin, a.top, a.t0, a.t1)
    elif a.hist:
        cmd_hist(cap, a.t0, a.t1)
    elif a.trace:
        cmd_trace(cap)
    elif a.snoop_check:
        cmd_snoop_check(cap, a.dump, a.max)
    elif a.gdcw:
        cmd_gdcw(cap, a.gdcw)
    elif a.attrmap is not None:
        cmd_attrmap(cap, a.attrmap)
    elif a.fdc:
        cmd_fdc(cap, a.t0, a.t1)
    elif a.json:
        for r in cap.recs:
            print(json.dumps(dict(off=r.off, type=r.type, src=r.src, t=r.t, f=r.f)))
    else:
        base = {}
        for r in cap.recs:
            base.setdefault(r.src, r.t)
        shown = 0
        for r in cap.recs:
            if in_range(r, a.t0, a.t1, {}):
                print(line_of(r, a.vtotal, a.vactive))
                shown += 1
        print(f"# {len(cap.recs)} records ({shown} shown), {cap.skipped} byte(s) outside records, "
              f"{cap.banners} reset banner(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

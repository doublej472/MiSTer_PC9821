#!/usr/bin/env python3
"""dmaroute_decode.py - decode a DMAROUTE capture: where did each DMA byte land?

Usage:
    python3 tools/hwprobe/dmaroute/dmaroute_decode.py DMAROUTE.TXT

DMAROUTE (tools/hwprobe/dmaroute/dmaroute.s) moves LEN bytes of a known floppy sector
(C0 H0 R1) into a memory window twice per case, once with the CPU (XFER=CPU) and once
with the uPD71071 on the floppy's DMA channel (XFER=DMA), and reads a set of VIEWS of
the same bytes before and after:

    RUN E1 XFER=DMA STATE=EMS22 DST=000B0200 LEN=20
    DMA BIOS=00 SAME=01 RC=00 RES=00000000000103 ST11=04/04 MSR=80 IRQ11=0001
    V0 STATE=EMS22 AT=B000:0200 KIND=MEM N=20
    V0 ORIG=...   the as-found bytes (written back after the run)
    V0 PRE=...    after the per-view prefill (expected bytes XOR the view's key)
    V0 POST=...   after the transfer

Each POST view is classified:

    D     every byte is the transferred byte (the sector's; for the CG views, its odd bytes)
    Pn    every byte is still view n's prefill (n = this view: untouched; another n: an alias
          of view n, which was prefilled after this one)
    FF    every byte reads 0xFF (open bus / not connected)
    ORIG  the as-found bytes (a store that is dropped but whose reads are not 0xFF)
    MIX   anything else (the counts are printed)

and every DMA run is compared with the CPU run of the same case: "DMA = CPU" when every
view's POST bytes are identical, i.e. the DMA byte went where the CPU's byte went - which
is the rule NP2kai implements (mem/dmax86.c MEMP_WRITE8 -> i386c/cpumem.c memfn0.wr8) and
lane/dma-route models. That verdict needs no reference: the machine supplies both sides.

The tables below give the per-view DMA POST tags of two references:

EXPECT_DMA_ROUTE - the core after lane/dma-route (tests/pc9821/tb_pc9821_dma_route.sv), as
    corrected against the Xe10 capture (docs/probes/DMAROUTE-XE10.TXT): a DMA byte goes where a
    CPU byte goes in every window, and the CPU-side map now answers the capture in E1/E2 (0x24
    written from the identity keeps the planes), P4's register file (bits 5-0 of the bank
    registers, the odd bytes read 0), W1/W2 (window 0 at 0x0A is RAM of its own) and G1 (the CG
    window takes the DMA byte) and P4's second view (the E plane at 0xE0000 exists only in the
    16-colour mode; in the digital mode the probe found the slot reads 0xFF, todo item 31).

NP2KAI - the capture of this probe in NP2kai (IA-32 SDL2 build, Xe10 BIOS, the probe's own
    floppy image; run recorded in the lane's report). NP2kai implements neither 0x043F's
    EMS window (only an EPSON-machine port, io/epsonio.c) nor 0x0461, so in the E and W
    cases every view is the identity mapping - planes at B0000, plain RAM at 0x88100/0x81000/
    0x9F000 - which is why those rows differ from EXPECT_DMA_ROUTE.

A real-machine capture (docs/probes/DMAROUTE-XE10.TXT once it exists) outranks both.

Nothing here talks to hardware; it is a pure text parser.
"""

from __future__ import annotations

import re
import sys

# The per-case DMA POST tags of the lane/dma-route model (see the docstring).
EXPECT_DMA_ROUTE = {
    "C0": ["D"],
    "E1": ["D", "P2", "P2"],          # the EMS page; 0x24 written from 0x20 is the planes (V1 = V2)
    "E2": ["P0", "D", "D"],           # 0x24 from the identity: the store lands in plane R
    "P1": ["D", "D", "P2"],           # bank A; the same bank through window B; the plane untouched
    "P2": ["D", "D", "P2"],           # bank B; the same bank through window A; the plane untouched
    "P3": ["FF", "P1"],               # B8000 not connected in 256-colour mode (memnc)
    "P4": ["MIX(d=2/4)", "FF"],       # bank registers keep bits 5-0, odd bytes 0 (2B 00 00 00);
                                      # no E plane in the digital mode: open bus (item 31)
    "W1": ["D", "P1", "P2"],          # 0x88100 -> the window's RAM page; plane B and RAM untouched
    "W2": ["D", "P1", "P2"],          # 0x81000 -> the window's RAM page; text RAM and RAM untouched
    "W3": ["D", "P1"],                # 0x9F000 -> 0x11F000; RAM at 0x9F000 untouched
    "G1": ["D", "D"],                 # the CG byte port takes the byte, as the CPU's
}

# NP2kai's answer: this probe run in NP2kai (IA-32 SDL2 build of the np2ref copy, i486DX 63.9 MHz,
# Xe10 BIOS, plain DOS 6.20 with HIMEM, a FAT12 2HD image in drive 0x90), 2026-11-01. Every DMA
# run was clean (RC=00, TC set, one IRQ11 taken by the probe's handler) and equal to the CPU run.
NP2KAI = {
    "C0": ["D"],
    "E1": ["D", "D", "D"],            # no 0x043F window: all three views are plane R
    "E2": ["D", "D", "D"],
    "P1": ["D", "D", "P2"],
    "P2": ["D", "D", "P2"],
    "P3": ["FF", "P1"],
    "P4": ["D", "FF"],                # E0004 in the as-found digital mode reads 0xFF in NP2kai
    "W1": ["D", "P1", "D"],           # no 0x0461 window: 0x88100 is plain RAM
    "W2": ["D", "P1", "D"],
    "W3": ["D", "D"],
    "G1": ["D", "D"],                 # memtram_wr8 writes the user glyph (mem/memtram.c)
}

CASE_TEXT = {
    "C0": "plain conventional RAM (control)",
    "E1": "0xB0200 with the 0x043F=0x22 EMS page",
    "E2": "0xB0200 with 0x043F=0x24 (after 0x20)",
    "P1": "PEGC 256 packed bank A (A8100, A=5)",
    "P2": "PEGC 256 packed bank B (B0100, B=6)",
    "P3": "PEGC 256 B8100 (not connected)",
    "P4": "PEGC 256 register file E0004-E0007",
    "W1": "0x0461=0x0A: 0x88100 (-> 0xA8100)",
    "W2": "0x0461=0x0A: 0x81000 (-> 0xA1000)",
    "W3": "0x0461=0x10: 0x9F000 -> 0x11F000",
    "G1": "CG window A4000, user glyph 0x7621",
}

RE_SECTOR = re.compile(r"^SECTOR ([0-9A-F]+)\s*$")
RE_KEYS = re.compile(r"^KEYS ([0-9A-F]+)\s*$")
RE_RUN = re.compile(r"^RUN (\w+) XFER=(CPU|DMA) STATE=(\S+) DST=([0-9A-F]{8}) LEN=([0-9A-F]{2})\s*$")
RE_DMA = re.compile(r"^DMA BIOS=([0-9A-F]{2}) SAME=([0-9A-F]{2}) RC=([0-9A-F]{2}) RES=([0-9A-F]{14})"
                    r" ST11=([0-9A-F]{2})/([0-9A-F]{2}) MSR=([0-9A-F]{2}) IRQ11=([0-9A-F]{4})\s*$")
RE_VHDR = re.compile(r"^V(\d) STATE=(\S+) AT=([0-9A-F]{4}:[0-9A-F]{4}) KIND=(\w+) N=([0-9A-F]{2})\s*$")
RE_VDAT = re.compile(r"^V(\d) (ORIG|PRE|POST)=([0-9A-F]*)\s*$")


def hexbytes(s: str) -> list[int]:
    return [int(s[i:i + 2], 16) for i in range(0, len(s), 2)]


def parse(lines):
    sector = keys = None
    runs = []        # dicts: case, xfer, state, dst, len, dma, views{idx: {...}}
    cur = None
    misc = []
    for raw in lines:
        line = raw.rstrip("\r\n")
        m = RE_SECTOR.match(line)
        if m:
            sector = hexbytes(m.group(1))
            continue
        m = RE_KEYS.match(line)
        if m:
            keys = hexbytes(m.group(1))
            continue
        m = RE_RUN.match(line)
        if m:
            cur = {"case": m.group(1), "xfer": m.group(2), "state": m.group(3),
                   "dst": int(m.group(4), 16), "len": int(m.group(5), 16), "dma": None, "views": {}}
            runs.append(cur)
            continue
        m = RE_DMA.match(line)
        if m and cur is not None:
            cur["dma"] = {"bios": int(m.group(1), 16), "same": int(m.group(2), 16),
                          "rc": int(m.group(3), 16), "res": hexbytes(m.group(4)),
                          "st11_pre": int(m.group(5), 16), "st11": int(m.group(6), 16),
                          "msr": int(m.group(7), 16), "irq": int(m.group(8), 16)}
            continue
        m = RE_VHDR.match(line)
        if m and cur is not None:
            cur["views"][int(m.group(1))] = {"state": m.group(2), "at": m.group(3),
                                             "kind": m.group(4), "n": int(m.group(5), 16)}
            continue
        m = RE_VDAT.match(line)
        if m and cur is not None:
            cur["views"].setdefault(int(m.group(1)), {})[m.group(2).lower()] = hexbytes(m.group(3))
            continue
        if line.startswith(("FOUND", "FDC", "DISK", "DIRECT", "USING", "RESTORE", "NODISK", "DMA SKIPPED")):
            misc.append(line)
    return sector, keys, runs, misc


RE_DIRECT = re.compile(r"^DIRECT U=(\d) ST3=([0-9A-F]{2}) MOTOR=(\S+) ST3=([0-9A-F]{2})"
                       r" RECAL ST0=([0-9A-F]{2}) PCN=([0-9A-F]{2}) READID=([0-9A-F]{14}) (.*)$")
# INT 1Bh AH high nibble, as NP2kai's fdd_operate returns it (bios/bios1b.c): 0x60 when
# !fdd_diskready, 0x40 from setfdcmode or a masked FDC IRQ, 0xE0 a failed seek/ID, 0xC0 a
# short read, 0xD0 no parameter table; SENSE (04h) adds flags in the low nibble.
BIOS_AH = {0x00: "ok", 0x10: "ok, write protected", 0x40: "interface off / IRQ masked",
           0x60: "NOT READY", 0xC0: "read error", 0xD0: "no parameters", 0xE0: "seek/ID error"}


def st3_text(v):
    """uPD765 ST3: 7 FT, 6 WP, 5 RDY, 4 T0, 3 TS, 2 HD, 1:0 US."""
    if v == 0xFF:
        return "--"
    bits = [n for b, n in ((0x80, "FT"), (0x40, "WP"), (0x20, "RDY"), (0x10, "T0"), (0x08, "TS"))
            if v & b]
    return "|".join(bits) or "none"


def explain_scan(misc):
    """One line per DISK/DIRECT line of the drive scan."""
    out = []
    for l in misc:
        if l.startswith("DISK"):
            m = re.search(r"DA=([0-9A-F]{2}) SENSE=([0-9A-F]{2}) RECAL=([0-9A-F]{2})"
                          r" READID=([0-9A-F]{2})", l)
            if m:
                da, *codes = (int(x, 16) for x in m.groups())
                out.append("  DA %02X: BIOS sense/recal/readid = %s" % (da, " / ".join(
                    BIOS_AH.get(c & 0xF0, "%02X" % c) for c in codes)))
        m = RE_DIRECT.match(l)
        if m:
            out.append("  unit %s direct: ST3 %s -> (motor %s, 500 ms) %s; recal ST0=%s; %s" % (
                m.group(1), st3_text(int(m.group(2), 16)), m.group(3),
                st3_text(int(m.group(4), 16)), m.group(5), m.group(8).strip()))
    return out


def expected(sector, kind, n):
    if kind == "MEM":
        return sector[:n]
    return [sector[2 * j + 1] for j in range(n)]


def classify(data, exp, orig, keys, nviews):
    if data == exp:
        return "D"
    for k in range(nviews):
        if data == [b ^ keys[k] for b in exp]:
            return "P%d" % k
    if all(b == 0xFF for b in data):
        return "FF"
    if orig is not None and data == orig:
        return "ORIG"
    d = sum(1 for a, b in zip(data, exp) if a == b)
    return "MIX(d=%d/%d)" % (d, len(data))


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    with open(argv[1], "r", encoding="latin-1") as f:
        text = f.readlines()
    sector, keys, runs, misc = parse(text)
    complete = any(l.strip() == "END:DMAROUTE" for l in text)
    for l in misc:
        print(l)
    for l in explain_scan(misc):
        print(l)
    if sector is None or keys is None:
        print("no SECTOR/KEYS line: the probe did not get a DMA source")
        return 1
    if not complete:
        print("WARNING: no END:DMAROUTE - the capture is incomplete; the last BEGIN:CASE hung")
    if sum(1 for b in sector if b == 0xFF) > 4:
        print("WARNING: the sector's first bytes contain several 0xFF: D and FF can be confused")

    by_case = {}
    for r in runs:
        nv = len(r["views"])
        r["tags"] = []
        for i in range(nv):
            v = r["views"][i]
            exp = expected(sector, v["kind"], v["n"])
            v["exp"] = exp
            v["pre_tag"] = classify(v.get("pre", []), exp, v.get("orig"), keys, nv)
            v["post_tag"] = classify(v.get("post", []), exp, v.get("orig"), keys, nv)
            r["tags"].append(v["post_tag"])
        by_case.setdefault(r["case"], {})[r["xfer"]] = r

    print()
    print("%-3s %-38s %-22s %-22s %-8s %-10s %s" % ("", "case", "CPU POST", "DMA POST", "DMA=CPU",
                                                    "dma-route", "NP2kai"))
    rc_all = 0
    for name, d in by_case.items():
        cpu = d.get("CPU")
        dma = d.get("DMA")
        ctag = " ".join(cpu["tags"]) if cpu else "-"
        dtag = " ".join(dma["tags"]) if dma else "-"
        same = "-"
        if cpu and dma:
            diffs = [i for i in range(len(cpu["views"]))
                     if cpu["views"][i].get("post") != dma["views"].get(i, {}).get("post")]
            same = "yes" if not diffs else "NO:" + ",".join("V%d" % i for i in diffs)
        exp_lane = EXPECT_DMA_ROUTE.get(name)
        exp_np2 = NP2KAI.get(name)
        lane = "-" if not dma or exp_lane is None else ("match" if dma["tags"] == exp_lane else
                                                       "DIFF:" + " ".join(exp_lane))
        np2 = "-" if not dma or exp_np2 is None else ("match" if dma["tags"] == exp_np2 else
                                                     "DIFF:" + " ".join(exp_np2))
        print("%-3s %-38s %-22s %-22s %-8s %-10s %s" % (name, CASE_TEXT.get(name, "?"), ctag, dtag,
                                                        same, lane, np2))
        if dma and dma["dma"]:
            x = dma["dma"]
            st0, st1, st2 = x["res"][0], x["res"][1], x["res"][2]
            ok = x["rc"] == 0 and (st0 & 0xC0) == 0 and x["same"] == 1 and (x["bios"] & 0xF0) == 0
            if not ok:
                rc_all = 1
                print("    DMA RUN NOT CLEAN: BIOS=%02X SAME=%d RC=%02X ST0=%02X ST1=%02X ST2=%02X"
                      " (RC 1 FDC busy, 2 command, 3 no result, 4 result read)"
                      % (x["bios"], x["same"], x["rc"], st0, st1, st2))
            if not (x["st11"] & 0x04):
                print("    note: 0x11 bit 2 (ch 2 terminal count) clear after the transfer: %02X" % x["st11"])

    print()
    print("Per-view detail (PRE -> POST, the POST bytes):")
    for name, d in by_case.items():
        for xfer in ("CPU", "DMA"):
            r = d.get(xfer)
            if not r:
                continue
            for i in range(len(r["views"])):
                v = r["views"][i]
                print("  %s %s V%d %-12s %s %-4s %-6s -> %-10s %s" % (
                    name, xfer, i, v.get("state", "?"), v.get("at", "?"), v.get("kind", "?"),
                    v["pre_tag"], v["post_tag"], "".join("%02X" % b for b in v.get("post", []))[:32]))
    return rc_all


if __name__ == "__main__":
    sys.exit(main(sys.argv))

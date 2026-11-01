#!/usr/bin/env python3
"""ideprobe_decode.py - parse an IDEPROBE capture into readable tables.

Usage:
    python3 tools/hwprobe/ideprobe/ideprobe_decode.py IDE.TXT [IDE2.TXT ...]

IDEPROBE (tools/hwprobe/ideprobe/ideprobe.s) is the real-machine PC-9821 IDE/ATA probe.
It prints labelled hex records, one per line, under BEGIN:<section>/END:<section>
markers. This script turns that raw text into the tables read when
diffing the Xe10 against src/pc9821/storage/pc9821_ata.sv and its benches.

Sections handled: PORTMAP (registers, legacy bytes, the 0432 bank behaviour),
REG, TIME (the I/O wait-state class table, converted to x5F ratios and clk_sys),
IDENTIFY (the 256-word response, key words, geometry), RECAL (the status
transitions), IRQ (the PIC mask/IRR/ISR and the interrupt count), RESTORE.

Nothing here talks to hardware; it is a pure text parser.
"""

from __future__ import annotations

import argparse
import re
import sys

# The 0x5F I/O-wait port is the machine's documented 600 ns / 30 clk_sys class
# (the 0x5F wait as the machine documents it). Every other class's clk_sys is its excess over the
# interleaved control, as a fraction of that same excess.
WAIT_NS = 600
WAIT_CLK = 30

STATUS_BITS = [
    ("BSY", 0x80),
    ("DRDY", 0x40),
    ("DSC", 0x10),
    ("DRQ", 0x08),
    ("ERR", 0x01),
]


def sections(text: str) -> dict[str, list[str]]:
    """Split a capture into {section_name: [lines]} by BEGIN:/END: markers."""
    out: dict[str, list[str]] = {}
    cur: str | None = None
    for line in text.splitlines():
        m = re.search(r"BEGIN:([A-Z]+)", line)
        if m:
            cur = m.group(1)
            out.setdefault(cur, [])
            continue
        if re.search(r"END:([A-Z]+)", line):
            cur = None
            continue
        if cur is not None:
            out[cur].append(line)
    return out


PORT_RE = re.compile(r"\b([0-9A-Fa-f]{4})=([0-9A-Fa-f]{2}|--)(?![0-9A-Fa-f])")


def parse_ports(lines: list[str]) -> dict[int, str]:
    out: dict[int, str] = {}
    for line in lines:
        for port, value in PORT_RE.findall(line):
            out[int(port, 16)] = value
    return out


def bank_lines(lines: list[str]) -> dict[str, str]:
    """Pull the pm_bank labelled values out of the PORTMAP section."""
    out: dict[str, str] = {}
    pats = [
        (r"BANK 0432 as found =\s*([0-9A-Fa-f]+)", "found"),
        (r"BANK 0432<-01 rb=([0-9A-Fa-f]+) st=([0-9A-Fa-f]+)", "b01"),
        (r"BANK 0432<-80 rb=([0-9A-Fa-f]+) st=([0-9A-Fa-f]+)", "b80"),
        (r"BANK 0432<-81 status=([0-9A-Fa-f]+)", "b81"),
        (r"BANK 0432 restored rb=([0-9A-Fa-f]+)", "restored"),
    ]
    for line in lines:
        for pat, key in pats:
            m = re.search(pat, line)
            if m:
                out[key] = " ".join(m.groups())
    return out


def cmd_status(port: int, status: str) -> str:
    if status == "--":
        return "no read (data pending)"
    v = int(status, 16)
    return " ".join(f"{n}={'1' if v & b else '0'}" for n, b in STATUS_BITS)


# --------------------------------------------------------------------------
# TIME
# --------------------------------------------------------------------------
TIME_RE = re.compile(
    r"^\s*(?P<label>\S+)\s+"
    r"port=(?P<port>[0-9A-Fa-f]{4})\s+"
    r"mode=(?P<mode>[RBW])\s+"
    r"pit=(?P<pit>[0-9A-Fa-f]+)\s+"
    r"base=(?P<base>[0-9A-Fa-f]+)\s+"
    r"artic=(?P<artic>[0-9A-Fa-f]+)"
)


def parse_time(lines: list[str]) -> tuple[list[dict], int | None]:
    rows = []
    divisor = None
    for line in lines:
        m = re.search(r"PIT channel-0 measured divisor =\s*([0-9A-Fa-f]+)", line)
        if m:
            divisor = int(m.group(1), 16)
            continue
        m = TIME_RE.match(line)
        if m:
            d = m.groupdict()
            rows.append(
                {
                    "label": d["label"],
                    "port": int(d["port"], 16),
                    "mode": d["mode"],
                    "pit": int(d["pit"], 16),
                    "base": int(d["base"], 16),
                    "artic": int(d["artic"], 16),
                }
            )
    return rows, divisor


def excess(row: dict) -> int:
    return max(row["pit"] - row["base"], 0)


def print_time(rows: list[dict], divisor: int | None) -> None:
    if not rows:
        print("  (no TIME rows)")
        return
    if divisor is not None:
        print(
            f"  PIT channel-0 divisor = 0x{divisor:04X} "
            f"(documented 0x6000 = 2.4576 MHz, 0x4E00 = 1.9968 MHz)"
        )
    wait = next((r for r in rows if r["label"].startswith("WAIT")), None)
    w_ex = excess(wait) if wait else 0
    print(
        f"  {'class':8} {'port':6} {'mode':4} {'pit':>6} {'base':>6} "
        f"{'excess':>6} {'base_ratio':>10} {'x5F':>6} {'clk_sys':>7} {'ns':>7}"
    )
    for r in rows:
        ex = excess(r)
        if r["label"].startswith("BASE"):
            br = "-"
        elif r["base"]:
            br = f"{100.0 * r['pit'] / r['base']:.0f}%"
        else:
            br = "-"
        if r["mode"] != "B" and w_ex > 0 and ex:
            x5f = 100.0 * ex / w_ex
            clk = WAIT_CLK * ex / w_ex
            ns = WAIT_NS * ex / w_ex
            x5f_s, clk_s, ns_s = f"{x5f:.0f}", f"{clk:.1f}", f"{ns:.0f}"
        else:
            x5f_s = clk_s = ns_s = "-"
        print(
            f"  {r['label']:8} {r['port']:04X}   {r['mode']:4} {r['pit']:6d} "
            f"{r['base']:6d} {ex:6d} {br:>10} {x5f_s:>6} {clk_s:>7} {ns_s:>7}"
        )
    if wait:
        print(
            "  Read the row for the port the core's class table names: the "
            "x5F/clk_sys columns are its ratio to the machine's own\n"
            "  0x5F wait (documented 600 ns = 30 clk_sys), so clk_sys is the "
            "number pc9821_iobus.sv's io_access_cycles should return."
        )


# --------------------------------------------------------------------------
# IDENTIFY
# --------------------------------------------------------------------------
IDKEY_RE = re.compile(r"IDKEY\s+(.*)$")
KEY_RE = re.compile(r"(w\d+)=([0-9A-Fa-f]{4})")
IDW_RE = re.compile(r"IDW\s+(\d+)\s+([0-9A-Fa-f]{4})")


def parse_identify(lines: list[str]) -> dict:
    keys: dict[int, int] = {}
    words: dict[int, int] = {}
    status = wait = None
    for line in lines:
        m = IDKEY_RE.search(line)
        if m:
            for name, value in KEY_RE.findall(m.group(1)):
                keys[int(name[1:])] = int(value, 16)
            continue
        m = IDW_RE.search(line)
        if m:
            words[int(m.group(1))] = int(m.group(2), 16)
            continue
        m = re.search(r"IDENTIFY status before/after =\s*([0-9A-Fa-f]+)\s+([0-9A-Fa-f]+)", line)
        if m:
            status = m.group(1), m.group(2)
            continue
        m = re.search(r"wait_ok=\s*([0-9A-Fa-f]+)", line)
        if m:
            wait = int(m.group(1), 16)
    return {"keys": keys, "words": words, "status": status, "wait": wait}


def ata_string(words: dict[int, int], first: int, count: int) -> str:
    """Recover an ATA string field from the words as the probe read them.

    The probe reads IDENTIFY with `in ax,0x0640` and stores AX unchanged, so these
    are the data port's own bytes: the FIRST character sits in the HIGH byte. That
    is the machine's order, not the usual ATA-string order - the BIOS's own reader
    corrects it with `in ax,dx; xchg ah,al; stosw` (the IDE ROM driver at
    `0x0952C`). The real capture confirms it: words 23-26 and 27-46 decode to
    'Ver2.35' and 'CF Card' only high-byte-first."""
    out = []
    for i in range(first, first + count):
        if i not in words:
            return "(missing words)"
        w = words[i]
        out.append(chr((w >> 8) & 0xFF))
        out.append(chr(w & 0xFF))
    return "".join(out).rstrip()


def print_identify(ident: dict) -> None:
    keys, words = ident["keys"], ident["words"]
    if ident["status"]:
        print(f"  status before/after = {ident['status'][0]} {ident['status'][1]}")
    if ident["wait"] is not None:
        print(f"  wait_ok = {ident['wait']} (0 = DRQ/ERR seen, 1 = timeout)")
    if not keys and not words:
        print("  (no IDENTIFY data: the read did not complete - see the status line)")
        return
    print("  key words:")
    for n in sorted(keys):
        print(f"    w{n:<3} = {keys[n]:04X}")
    cyl = keys.get(1, 0)
    heads = keys.get(3, 0)
    spt = keys.get(6, 0)
    print(
        f"  geometry: cylinders(w1)={cyl} heads(w3)={heads} sectors/track(w6)={spt}"
    )
    if cyl and heads and spt:
        print(
            f"            CHS capacity = {cyl * heads * spt} sectors "
            f"({cyl * heads * spt * 512 // (1024 * 1024)} MiB)"
        )
    w49 = keys.get(49, 0)
    caps = []
    if w49 & 0x0200:
        caps.append("LBA supported (w49 bit 9)")
    if w49 & 0x0100:
        caps.append("DMA supported (w49 bit 8)")
    if w49 & 0x8000:
        caps.append("w49 bit 15 set")
    print(f"  word 49 = {w49:04X}: " + (", ".join(caps) if caps else "no LBA/DMA bits"))
    w60, w61 = keys.get(60, 0), keys.get(61, 0)
    lba = (w61 << 16) | w60
    print(f"  LBA28 capacity (w60/w61) = {lba} sectors")
    w47 = keys.get(47, 0)
    print(
        f"  word 47 (multiple) = {w47:04X}"
        f" (low byte, after the ROM's byte swap, decides its multiple path)"
    )
    if words:
        for label, first, count in (("model(w27-46)", 27, 20), ("serial(w10-19)", 10, 10)):
            text = ata_string(words, first, count)
            if text and text != "(missing words)":
                print(f"  {label} = {text!r}")
        print(f"  ({len(words)} of 256 words present; re-run with the raw file for all)")
    print(
        "  diff: compare these words with pc9821_ata.sv's identify_word mux and "
        "tests/pc9821/tb_pc9821_ata.sv."
    )


# --------------------------------------------------------------------------
# RECAL
# --------------------------------------------------------------------------
RECAL_SEQ_RE = re.compile(
    r"RECAL poll\s+(\d+)\s+([0-9A-Fa-f]+)\s+BSY=(\d)\s+DRDY=(\d)\s+DSC=(\d)\s+DRQ=(\d)\s+ERR=(\d)"
)


def parse_recal(lines: list[str]) -> dict:
    before = after = polls = None
    seq = []
    for line in lines:
        m = re.search(
            r"RECALIBRATE 0x10 status before/after =\s*([0-9A-Fa-f]+)\s+([0-9A-Fa-f]+)"
            r"\s+polls =\s*(\d+)",
            line,
        )
        if m:
            before, after, polls = m.group(1), m.group(2), int(m.group(3))
            continue
        m = RECAL_SEQ_RE.search(line)
        if m:
            seq.append(m.groups())
    return {"before": before, "after": after, "polls": polls, "seq": seq}


def print_recal(rec: dict) -> None:
    if rec["before"] is None:
        print("  (no RECALIBRATE status line)")
        return
    print(f"  status before = {rec['before']}  after = {rec['after']}  polls = {rec['polls']}")
    print(f"  {'poll':>6} {'status':>6}  BSY DRDY DSC DRQ ERR")
    for n, status, bsy, drdy, dsc, drq, err in rec["seq"]:
        print(f"  {n:>6} {status:>6}   {bsy}   {drdy}    {dsc}   {drq}   {err}")
    if not rec["seq"]:
        print("  (the status register never changed: 0x0E/0xFF means no drive answered)")


# --------------------------------------------------------------------------
# IRQ
# --------------------------------------------------------------------------
def parse_irq(lines: list[str]) -> dict:
    out: dict[str, object] = {}
    for line in lines:
        m = re.search(r"vector 0x11 \(IRQ9\) as found =\s*([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})", line)
        if m:
            out["vector"] = f"{m.group(1)}:{m.group(2)}"
            continue
        m = re.search(r"PIC as found m_imr s_imr m_irr m_isr s_irr s_isr =\s*(.*)$", line)
        if m:
            out["found"] = m.group(1).split()
            continue
        m = re.search(r"during IDENTIFY s_irr s_isr m_irr m_isr =\s*(.*)$", line)
        if m:
            out["during"] = m.group(1).split()
            continue
        m = re.search(r"ISR status =\s*([0-9A-Fa-f]+)\s+count =\s*(\d+)\s+pre/final status =\s*([0-9A-Fa-f]+)\s+([0-9A-Fa-f]+)", line)
        if m:
            out["status"] = m.group(1)
            out["count"] = int(m.group(2))
            out["pre_final"] = (m.group(3), m.group(4))
    return out


def print_irq(irq: dict) -> None:
    if not irq:
        print("  (no IRQ section)")
        return
    print(f"  vector 0x11 as found = {irq.get('vector', '?')} (the owner: a DOS driver or the ROM ISR)")
    found = irq.get("found")
    if found and len(found) == 6:
        m_imr, s_imr, m_irr, m_isr, s_irr, s_isr = found
        print(
            f"  as found: master IMR={m_imr} slave IMR={s_imr} "
            f"master IRR={m_irr} master ISR={m_isr} slave IRR={s_irr} slave ISR={s_isr}"
        )
        print(
            f"    slave IMR bit 1 (0x02) {'SET: IRQ9 masked' if int(s_imr, 16) & 2 else 'CLEAR: IRQ9 unmasked'}; "
            f"master IMR bit 7 (0x80) cascade {'masked' if int(m_imr, 16) & 0x80 else 'unmasked'}"
        )
    during = irq.get("during")
    if during and len(during) == 4:
        s_irr, s_isr, m_irr, m_isr = during
        lvl = int(s_isr, 16)
        print(
            f"  during IDENTIFY: slave IRR={s_irr} slave ISR={s_isr} "
            f"master IRR={m_irr} master ISR={m_isr}"
        )
        if lvl & 0x02:
            print("    slave ISR bit 1 set -> the drive asserts IRQ9 (vector 0x11).")
        elif int(s_irr, 16) & 0x02:
            print("    slave IRR bit 1 set -> the request is latched but not yet in service.")
        else:
            print("    no slave bit 1 seen: the command raised no IRQ9, or a stub missed it.")
    if "count" in irq:
        print(
            f"  ISR entries (count) = {irq['count']}, last status = {irq.get('status', '?')}, "
            f"pre/final status = {irq.get('pre_final')}"
        )
    print(
        "  Note: the PC-98 slave 8259 is cascaded into master IRQ7, ICW2 = 0x10, so\n"
        "  slave IRQ1 = IRQ9 = vector 0x11. count > 0 means the hardware really does\n"
        "  interrupt; a bare prompt with the slave IMR bit 1 set means the resident DOS\n"
        "  driver owns the line, not that the drive is polled."
    )


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
def decode(text: str) -> None:
    sec = sections(text)

    if "PORTMAP" in sec:
        print("== PORTMAP: interface, task file as found, legacy bytes ==")
        ports = parse_ports(sec["PORTMAP"])
        for name, addrs in (
            ("interface", [0x0430, 0x0432, 0x0433, 0x0435, 0x1E8E]),
            ("task file", [0x0640, 0x0641, 0x0642, 0x0644, 0x0646, 0x0648, 0x064A, 0x064C, 0x064E]),
            ("alt channel", [0x0740, 0x0741, 0x0742, 0x0744, 0x0746, 0x0748, 0x074A, 0x074C, 0x074E]),
            ("legacy (ARTIC)", [0x005C, 0x005D, 0x005E, 0x005F]),
        ):
            row = "  ".join(
                f"{a:04X}={ports.get(a, '??')}" for a in addrs
            )
            print(f"  {name:14} {row}")
        bank = bank_lines(sec["PORTMAP"])
        if bank:
            print("  BANK 0432 (the crux: the core gates the block on bit 7):")
            print(f"    as found = {bank.get('found', '?')}")
            print(f"    0432<-01 rb/st = {bank.get('b01', '?')}")
            print(f"    0432<-80 rb/st = {bank.get('b80', '?')}")
            print(f"    0432<-81 st    = {bank.get('b81', '?')}")
            print(f"    restored  = {bank.get('restored', '?')}")
            print(
                "    NP2kai (cbus/ideio.c ideio_o430) latches dat & 0x71 ONLY when bit 7\n"
                "    is clear, and getidedev uses bank[1] & 0x7f: value 01 = the built-in\n"
                "    IDE, and a write with bit 7 set is a NO-OP. The core's pc9821_ata.sv\n"
                "    wire ide_block_mapped = channel_reg[7] is the reverse of that: if the\n"
                "    0432<-01 status above is 0x50 (live) and the core answers 0x0E, the\n"
                "    core's gate is the boot blocker."
            )

    if "REG" in sec:
        print("\n== REG: task file with 0432=01 ==")
        ports = parse_ports(sec["REG"])
        for a in [0x0430, 0x0432, 0x0433, 0x0435, 0x0640, 0x0641, 0x0642, 0x0644,
                  0x0646, 0x0648, 0x064A, 0x064C, 0x064E, 0x0740, 0x0741, 0x0742,
                  0x0744, 0x0746, 0x0748, 0x074A, 0x074C, 0x074E, 0x1E8E]:
            if a in ports:
                extra = cmd_status(a, ports[a]) if a in (0x064E, 0x074C) else ""
                print(f"  {a:04X}={ports[a]}   {extra}".rstrip())

    if "TIME" in sec:
        print("\n== TIME: the I/O wait-state class table ==")
        rows, divisor = parse_time(sec["TIME"])
        print_time(rows, divisor)

    if "IDENTIFY" in sec:
        print("\n== IDENTIFY (0xEC) ==")
        print_identify(parse_identify(sec["IDENTIFY"]))

    if "RECAL" in sec:
        print("\n== RECALIBRATE (0x10) ==")
        print_recal(parse_recal(sec["RECAL"]))

    if "IRQ" in sec:
        print("\n== IRQ ==")
        print_irq(parse_irq(sec["IRQ"]))

    if "RESTORE" in sec:
        print("\n== RESTORE ==")
        for line in sec["RESTORE"]:
            if "0432" in line:
                print("  " + line.strip())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("captures", nargs="+", help="IDEPROBE capture file(s)")
    args = ap.parse_args()
    for path in args.captures:
        try:
            text = open(path, "r", errors="replace").read()
        except OSError as exc:
            print(f"cannot read {path}: {exc}", file=sys.stderr)
            return 1
        print(f"### {path}")
        decode(text)
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())

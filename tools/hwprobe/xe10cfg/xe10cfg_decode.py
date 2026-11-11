#!/usr/bin/env python3
"""xe10cfg_decode.py - decode XE10CFG captures and RBOOT /S + /R files.

    xe10cfg_decode.py CFG.TXT               the record, the software DIPs, the mirror and
                                            the ports a SETUP item drives, with the checks
                                            the firmware itself makes
    xe10cfg_decode.py --diff A.TXT B.TXT    every value that differs between two captures
                                            (one SETUP change per boot -> which bits moved)
    xe10cfg_decode.py --rboot RBOOT.TXT     the RBOOT reset-set file as a table
    xe10cfg_decode.py [--font FONT.ROM] CG.TXT
                                            a /CG, /CGWR, /IDE or /W4A0 capture too: the record
                                            read through the 0xA4000 window, the saved-table
                                            length, window vs port, even offsets, the 4 KiB
                                            repeat, the two-byte ten < 0x20 table (with --font,
                                            each CRC is located in the user's FONT.ROM and
                                            compared with the core's address function)
    xe10cfg_decode.py --diff-cg A.TXT B.TXT  the user-CG cells (CGS lines) that differ
    xe10cfg_decode.py --selftest

Facts used (docs/bios-setup.md): the configuration record is CG code 0x2056 rows 0..0xD
(A1=0x20, A3=0x56, A5=row; BANK3@0x2322); rows 1-4 are stored inverted; rows 1..0xA sum to
zero (BANK3@0x21CB-0x21EC: row 0xA = -(rows 1..9)); rows 8/9 are AA 55 (BANK4@0x4677-0x46B5);
record rows 0x13/0x14 are code 0x2156 rows 3/4; the software-DIP mirror is code 0x0156 rows
0x00-0x0B (bank A) and 0x20-0x2B (bank B). The ITF writes the inverted record row 2 to port
0x31 (BANK4@0x46A9); whether the port answers it is the dip-audit P2 question.
"""
from __future__ import annotations

import re
import sys

# the probe's remaining line labels, longest first (each is followed by its values)
OTHER_LABELS = ['MODE68OFF before/after-0E/after-0E-20ms/after-0F', 'MODE68 before/after-0D/after-0C', 'MODE68 before/after-0C', 'DC000 1E8E was/gate/back',
                'DC000 asfound', 'DC000 gate81', 'DC000 marked', 'DC000 restored', 'MSW5 A3FF2',
                'MSWCELLS', 'CGREGS']
SDIP_PORTS = [0x841E + 0x100 * i for i in range(12)]


def parse(text: str) -> dict:
    """Every value as key -> string, plus structured views."""
    d = {'ports': {}, 'cg': {}, 'sdip': {}, 'mem': {}, 'rt': {}, 'other': {},
         'cgs': {}, 'cgw': {}, 'cgp': {}, 'cgrep': {}, 'cgword': {}, 'cgx': {}, 'cgxraw': {},
         'cgwr': {}, 'ide': [], 'cpu': None, 'w4a0': [], 'kit2': []}
    for raw in text.splitlines():
        ln = raw.strip()
        m = re.match(r'(CGS|CGW|CGP) ([0-9A-F]{4}) ([0-9A-F]{2}) ([0-9A-F]+)$', ln)
        if m:
            d[m[1].lower()][(int(m[2], 16), int(m[3], 16))] = bytes.fromhex(m[4])
            continue
        m = re.match(r'CGREP ([0-9A-F]{4}) ([0-9A-F]{2}) diff=([0-9A-F]{4}) first=([0-9A-F]{4})$', ln)
        if m:
            d['cgrep'][(int(m[1], 16), int(m[2], 16))] = (int(m[3], 16), int(m[4], 16))
            continue
        m = re.match(r'CGWORD ([0-9A-F]{4}) ([0-9A-F]{2}) (.*)$', ln)
        if m:
            d['cgword'][(int(m[1], 16), int(m[2], 16))] = dict(re.findall(r'(\w+)=([0-9A-F]+)', m[3]))
            continue
        m = re.match(r'CGX ([0-9A-F]{4}) (.*)$', ln)
        if m:
            d['cgx'][int(m[1], 16)] = {k: int(v, 16) for k, v in re.findall(r'(\w+)=([0-9A-F]{4})', m[2])}
            continue
        m = re.match(r'CGXRAW ([0-9A-F]{4}) ([0-9A-F]{192})$', ln)
        if m:
            d['cgxraw'][int(m[1], 16)] = bytes.fromhex(m[2])
            continue
        m = re.match(r'CGWR 7E57 (PRE|POST|PORT)\s+\(.*\) ([0-9A-F]+)$', ln)
        if m:
            d['cgwr'][m[1]] = bytes.fromhex(m[2])
            continue
        m = re.match(r'CGWR (CHANGED|RESTORE) (.*)$', ln)
        if m:
            d['cgwr'].setdefault(m[1], []).append(m[2])
            continue
        m = re.match(r'CPU (.*)$', ln)
        if m:
            d['cpu'] = dict(re.findall(r'(\w+)=([0-9A-F:]+)', m[1]))
            continue
        if ln.startswith(('IDE', 'IDEB', 'IDES', 'IDEI', 'ROW IDE')):
            d['ide'].append(ln)
            continue
        if ln.startswith(('FDBDA', 'FDVFO', 'P6C', 'ROW FD', 'ROW 6C')):
            d['kit2'].append(ln)
            continue
        if ln.startswith(('W4A0', 'ROW W4A0')):
            d['w4a0'].append(ln)
            continue
        m = re.match(r'PORT ([0-9A-F]{4})=([0-9A-F]{2}) ([0-9A-F]{2})$', ln)
        if m:
            d['ports'][int(m[1], 16)] = (int(m[2], 16), int(m[3], 16))
            continue
        m = re.match(r'(SDIPA0|SDIPA1|SDIPB|SDIPA2) ((?:[0-9A-F]{2} ?){12})$', ln)
        if m:
            d['sdip'][m[1]] = [int(x, 16) for x in m[2].split()]
            continue
        m = re.match(r'CG ([0-9A-F]{4}) ([0-9A-F]{2}):((?: [0-9A-F]{2})+)$', ln)
        if m:
            d['cg'][(int(m[1], 16), int(m[2], 16))] = [int(x, 16) for x in m[3].split()]
            continue
        m = re.match(r'MEM ([0-9A-F]{4})=([0-9A-F]{2})$', ln)
        if m:
            d['mem'][int(m[1], 16)] = int(m[2], 16)
            continue
        m = re.match(r'RT ([0-9A-F]{4}) was=(..) wrote=(..) got=(..) p31=(..) back=(..) p31=(..)', ln)
        if m:
            d['rt'][int(m[1], 16)] = dict(was=int(m[2], 16), wrote=int(m[3], 16),
                                          got=int(m[4], 16), p31a=int(m[5], 16),
                                          back=int(m[6], 16), p31b=int(m[7], 16),
                                          restored='NOT-RESTORED' not in ln)
            continue
        for label in OTHER_LABELS:
            if ln.startswith(label):
                d['other'][label] = ln[len(label):].strip()
                break
    return d


def flat(d: dict) -> dict:
    """One key per value, for --diff."""
    out = {}
    for p, (a, b) in d['ports'].items():
        out[f'PORT {p:04X}'] = f'{a:02X} {b:02X}'
    for k, v in d['sdip'].items():
        for i, x in enumerate(v):
            out[f'{k} {SDIP_PORTS[i]:04X}'] = f'{x:02X}'
    for (code, row0), v in d['cg'].items():
        for i, x in enumerate(v):
            out[f'CG {code:04X} row {row0 + i:02X}'] = f'{x:02X}'
    for a, v in d['mem'].items():
        out[f'MEM {a:04X}'] = f'{v:02X}'
    for p, r in d['rt'].items():
        out[f'RT {p:04X}'] = ' '.join(f'{k}={v:02X}' if isinstance(v, int) else f'{k}={v}'
                                       for k, v in r.items())
    for k, v in d['other'].items():
        out[k] = v
    for (code, h), v in d['cgs'].items():
        for i, x in enumerate(v):
            out[f'CGS {code:04X} {h:02X} row {i:X}'] = f'{x:02X}'
    if d['cpu']:
        for k, v in d['cpu'].items():
            out[f'CPU {k}'] = v
    return out


def record(d: dict):
    """Record rows 0..0x1F as stored (None where not captured)."""
    rows = [None] * 0x20
    for (code, row0), v in d['cg'].items():
        if code == 0x2056 and row0 == 0x00:
            for i, x in enumerate(v):
                rows[i] = x
        if code == 0x2156 and row0 == 0x00:
            for i, x in enumerate(v):
                rows[0x10 + i] = x
    return rows


def report(d: dict) -> list[str]:
    o = []
    rows = record(d)
    if rows[0] is not None:
        o.append('RECORD (CG 0x2056 rows 0..0xF, 0x2156 rows 0..0xF; rows 1-4 also shown un-inverted):')
        o.append('  ' + ' '.join(f'{r:02X}' for r in rows[:16]))
        o.append('  rows 1-4 as the item sees them: ' + ' '.join(f'{(~rows[i]) & 0xFF:02X}' for i in range(1, 5)))
        o.append(f'  rows 0x13/0x14: {rows[0x13]:02X} {rows[0x14]:02X}' if rows[0x13] is not None else '  rows 0x13/0x14: not captured')
        s = sum(rows[1:0x0B]) & 0xFF
        o.append(f'  rows 8/9 = {rows[8]:02X} {rows[9]:02X} ({"AA55 valid" if (rows[8], rows[9]) == (0xAA, 0x55) else "NOT AA55"});'
                 f' sum rows 1..0xA = {s:02X} ({"ok" if s == 0 else "BAD"})')
        p31 = d['ports'].get(0x31)
        if p31:
            inv = (~rows[2]) & 0xFF
            o.append(f'  port 0x31 = {p31[0]:02X}; the ITF writes ~row2 = {inv:02X} there (BANK4@0x46A9):'
                     f' {"the port answers the record" if p31[0] == inv else "the port does NOT follow the record"}')
            o.append(f'  0x31 bits: 7 (GDC clock) = {p31[0] >> 7 & 1}, 4 (memory switch init) = {p31[0] >> 4 & 1},'
                     f' 3 (text lines) = {p31[0] >> 3 & 1}')
    a = d['sdip'].get('SDIPA0')
    if a:
        o.append('SDIP bank A as found: ' + ' '.join(f'{x:02X}' for x in a))
        for k in ('SDIPA1', 'SDIPA2'):
            if k in d['sdip'] and d['sdip'][k] != a:
                o.append(f'  {k} differs from SDIPA0: ' + ' '.join(f'{x:02X}' for x in d['sdip'][k]))
        o.append(f'  0x861E bits 1:0 (floppy mode: 0 640K, 1 auto 640K, 2 1M, 3 auto 1M) = {a[2] & 3};'
                 f' 0x871E bit 5 (memory switch) = {a[3] >> 5 & 1}; 0x881E bit 5 (sound off) = {a[4] >> 5 & 1}')
    b = d['sdip'].get('SDIPB')
    if b:
        o.append('SDIP bank B: ' + ' '.join(f'{x:02X}' for x in b))
    for half, key, name in ((0x00, 'SDIPA0', 'bank A'), (0x20, 'SDIPB', 'bank B')):
        m = d['cg'].get((0x0156, half))
        s = d['sdip'].get(key)
        if m and s:
            same = m[:12] == s
            o.append(f'MIRROR {name} (CG 0x0156 rows {half:02X}..): ' + ' '.join(f'{x:02X}' for x in m[:12])
                     + ('  = the ports' if same else '  differs from the ports'))
    be = d['ports'].get(0xBE)
    if be:
        o.append(f'PORT 0x00BE = {be[0]:02X}: bit 0 (1 MB I/F) = {be[0] & 1}, bit 1 (2HD) = {be[0] >> 1 & 1},'
                 f' bit 2 (fixed) = {be[0] >> 2 & 1}')
    for p in (0x7FDB, 0x7FDD, 0x7FDF):
        if p in d['ports']:
            v = d['ports'][p]
            o.append(f'PORT {p:04X} = {v[0]:02X} {v[1]:02X}' + (' (bit 6, the 640 KB strap SW3-6, = %d)' % (v[0] >> 6 & 1) if p == 0x7FDB else ''))
    for p, r in d['rt'].items():
        verdict = 'latches' if r['got'] == r['wrote'] else ('ignored' if r['got'] == r['was'] else 'partial')
        extra = ''
        if p == 0x871E:
            extra = f'; port 0x31 {r["p31a"]:02X} after, {r["p31b"]:02X} restored' + \
                    (' -> 0x31 bit 4 FOLLOWS 0x871E bit 5 (NP2kai io/dipsw.c)' if (r['p31a'] ^ r['p31b']) & 0x10 else ' -> 0x31 does not follow')
        o.append(f'RT {p:04X}: was {r["was"]:02X} wrote {r["wrote"]:02X} got {r["got"]:02X} ({verdict}), back {r["back"]:02X}'
                 f'{"" if r["restored"] else " NOT RESTORED"}{extra}')
    for k, v in d['other'].items():
        if not k.startswith('MODE68OFF'):
            o.append(f'{k} {v}')
    return o


def crc16(data: bytes) -> int:
    """CRC-16/CCITT-FALSE, xe10cfg_ext.inc crc16."""
    c = 0xFFFF
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def core_jis_addr(a1: int, a3: int) -> int:
    """pc9821_cg.sv cg_jis_base: 0x1800 + (ku-0x21)*0xC00 + ((ten-0x20) & 0xFF)*0x20, 19 bits.
    ten = A1 & 0x7F raised to 0x20 when below it (cg_ten7: a column below 0x20 reads column
    0x20's slot), ku - 0x20 = A3 & 0x7F. This is OUR RTL, the thing being checked."""
    ku_i = ((a3 & 0x7F) - 1) & 0xFF
    ten_i = (max(a1 & 0x7F, 0x20) - 0x20) & 0xFF
    return (0x1800 + ku_i * 0x800 + ku_i * 0x400 + ten_i * 0x20) & 0x7FFFF


def cg_record_rows(d: dict):
    """The record as the ITF reads it: CG code 0x2056 with A5 bit 5 clear, odd window offsets."""
    r = d['cgs'].get((0x2056, 0x00))
    r2 = d['cgs'].get((0x2156, 0x00))
    if r is None:
        return None
    rows = list(r) + (list(r2) if r2 is not None else [None] * 16)
    return rows


def font_index(font: bytes) -> dict:
    """CRC of every 16-byte block at 16-byte alignment -> offsets."""
    idx = {}
    for off in range(0, len(font) - 15, 16):
        idx.setdefault(crc16(font[off:off + 16]), []).append(off)
    return idx


def cg_report(d: dict, font: bytes | None = None) -> list[str]:
    o = []
    if d['cpu']:
        c = d['cpu']
        o.append('CPU ' + ' '.join(f'{k}={v}' for k, v in c.items()))
        fs, fc = c.get('fpu_sw'), c.get('fpu_cw')
        if fs and fc:
            o.append('  FPU: ' + ('answers FNINIT (sw 0000, cw 037F)' if (fs, fc) == ('0000', '037F')
                                  else 'no FPU answer (sentinel kept)' if fs == '5A5A' else f'odd answer sw={fs} cw={fc}'))
        if 'cr0' in c and c['cr0'] != 'FFFFFFFF':
            v = int(c['cr0'], 16)
            o.append(f'  CR0 bits: PE={v & 1} MP={v >> 1 & 1} EM={v >> 2 & 1} TS={v >> 3 & 1} ET={v >> 4 & 1}'
                     f' NE={v >> 5 & 1} WP={v >> 16 & 1} AM={v >> 18 & 1} NW={v >> 29 & 1} CD={v >> 30 & 1} PG={v >> 31 & 1}')
    m68 = d['other'].get('MODE68OFF before/after-0E/after-0E-20ms/after-0F')
    if m68:
        b = [int(x, 16) for x in m68.split()]
        if len(b) == 4:
            o.append(f'MODE68OFF: 0x68 = {b[0]:02X} on, {b[1]:02X}/{b[2]:02X} with DISP off, {b[3]:02X} on again:'
                     f' bit 7 with the display off = {b[1] >> 7 & 1}/{b[2] >> 7 & 1}'
                     f' ({"reads 0 either way" if not (b[1] | b[2]) & 0x80 else "reads 1 = ~DISP"});'
                     f' the core reads 0x68 as the flip-flops with bit 7 = 0 while DISP is set')
    rows = cg_record_rows(d)
    if rows is not None:
        o.append('RECORD through the 0xA4000 window (CGS 2056 00: the ITF\'s read, BANK4@0x4677):')
        o.append('  rows 0..F: ' + ' '.join(f'{x:02X}' for x in rows[:16]))
        s_ = sum(rows[1:0x0B]) & 0xFF
        o.append(f'  rows 8/9 = {rows[8]:02X} {rows[9]:02X} ({"AA55 valid" if (rows[8], rows[9]) == (0xAA, 0x55) else "NOT AA55"});'
                 f' sum rows 1..0xA = {s_:02X} ({"ok" if s_ == 0 else "BAD"})')
        o.append('  rows 1-4 as SETUP sees them (inverted): ' + ' '.join(f'{(~rows[i]) & 0xFF:02X}' for i in range(1, 5)))
        if rows[0x13] is not None:
            o.append(f'  rows 0x13/0x14 (CGS 2156 00 rows 3/4): {rows[0x13]:02X} {rows[0x14]:02X}')
        core = [0x04, 0xC1, 0x0C, 0x80, 0xCF, 0xFF, 0x00, 0x00, 0xAA, 0x55, 0xE6, 0x86, 0x8A, 0xFF]
        diffs = [f'{i:X}:{rows[i]:02X}/core {core[i]:02X}' for i in range(14) if rows[i] != core[i]]
        o.append('  vs the core\'s default record (pc9821_cg.sv cg_record_row, OSD defaults; row A is the sum): '
                 + ('identical' if not diffs else 'differs at ' + ', '.join(diffs)))
        port = d['cg'].get((0x2056, 0x00))
        if port:
            o.append('  the same rows through 0xA9 (default dump CG 2056 00): ' + ' '.join(f'{x:02X}' for x in port))
    # The record is valid when rows 8/9 are AA55 and rows 1..0xA sum to 0 (the checks above). An
    # invalid record means the store holds no state the ITF wrote (the kit-1 Xe10's backup battery
    # is dead), so the length word beside it is power-up junk, not a saved table.
    rec_ok = rows is None or ((rows[8], rows[9]) == (0xAA, 0x55) and sum(rows[1:0x0B]) & 0xFF == 0)
    ln = d['cgs'].get((0x1056, 0x20))
    if ln is not None:
        n = ln[0] | ln[1] << 8
        if n == 0:
            note = ' (none kept: the next POST rebuilds the table, the core\'s CG_RESTORE_LEN state)'
        elif rec_ok:
            note = ' (kept: BANK4@0x1D64 takes the fast path)'
        else:
            note = (' (UNRELIABLE, junk: the CG record is invalid, so the store holds no saved state;'
                    ' a dead backup battery leaves it as it powered up)')
        o.append(f'SAVED TABLE length word (CGS 1056 20 rows 0/1) = {n:04X}' + note)
        if n:
            data = b''
            for a1 in range(0x10, 0x80):
                data += d['cgs'].get((a1 << 8 | 0x56, 0x20), b'') + d['cgs'].get((a1 << 8 | 0x56, 0x00), b'')
            o.append(f'  the {"table " if rec_ok else "(junk) "}bytes from code 0x1056 (A5=20 then 00 per code), first {min(n, 64)}: '
                     + data[:min(n, 64)].hex(' ').upper())
    mb = d['cgs'].get((0x1256, 0x00))
    if mb is not None:
        o.append(f'MODE BYTE (CGS 1256 00 row 7) = {mb[7]:02X} (bit 2 clear = the ITF\'s normal branch)')
    for half, key in ((0x00, 'SDIPA0'), (0x20, 'SDIPB')):
        m = d['cgs'].get((0x0156, half))
        if m is not None:
            s2 = d['sdip'].get(key)
            o.append(f'MIRROR 0156 {half:02X} (window): ' + ' '.join(f'{x:02X}' for x in m[:12])
                     + ('' if not s2 else ('  = the ports' if list(m[:12]) == s2 else '  differs from the ports')))
    for (code, h), w in sorted(d['cgw'].items()):
        ev, od = w[0::2], w[1::2]
        p = d['cgp'].get((code, h))
        txt = f'CGW {code:04X} {h:02X}: even offsets ' + ('all 00' if not any(ev) else ('all 8F (the low page constant of docs/probes/VRAM.TXT)' if set(ev) == {0x8F} else ('all FF' if set(ev) == {0xFF} else 'carry data: ' + ev.hex().upper())))
        if p is not None:
            txt += '; odd = 0xA9 port' if od == p else f'; odd {od.hex().upper()} vs 0xA9 {p.hex().upper()}'
        if (code, h) in d['cgs']:
            txt += '' if d['cgs'][(code, h)] == od else ' (odd differs from its CGS line)'
        o.append(txt)
    for (code, h), (n, first) in sorted(d['cgrep'].items()):
        o.append(f'CGREP {code:04X} {h:02X}: ' + ('the 4 KiB window repeats its 32 bytes exactly' if n == 0
                                                  else f'{n} bytes differ from the first 32, first at +{first:03X}'))
        wd = d['cgword'].get((code, h))
        w = d['cgw'].get((code, h))
        if wd and w is not None and len(w) == 32:
            exp = {'w0': w[0] | w[1] << 8, 'w1': w[1] | w[2] << 8, 'w1E': w[0x1E] | w[0x1F] << 8,
                   'w1F': w[0x1F] | w[0] << 8,
                   'd0': w[0] | w[1] << 8 | w[2] << 16 | w[3] << 24, 'd1': w[1] | w[2] << 8 | w[3] << 16 | w[4] << 24}
            bad = [f'{k}={wd[k]} (bytes say {exp[k]:0{len(wd[k])}X})' for k in exp if k in wd and int(wd[k], 16) != exp[k]]
            o.append(f'  word/dword reads ' + ('equal their byte reads (+1F wraps to +00 of the next 32)' if not bad else 'DIFFER: ' + ', '.join(bad)))
    if d['cgx']:
        o.append('TWO-BYTE WRAP TABLE (CGX): ten (A1) 0x00..0x2F per ku; P20/P00 = 0xA9 with A5 bit 5 set/clear,'
                 ' W..E/W..O = window even/odd bytes')
        fidx = font_index(font) if font else None
        for key in sorted(d['cgx']):
            a1, a3 = key >> 8, key & 0xFF
            v = d['cgx'][key]
            note = []
            if v.get('P20') == v.get('W20E') and v.get('P00') == v.get('W20O'):
                note.append('window = port')
            # the port's two halves (P20/P00) for every two-byte class that reads the font; the
            # ver0.78 rows 0x09-0x0B answer 0 for one half, so they are left out
            if font and a1 and not (0x09 <= a3 < 0x0C) and (a3 & 0x7F) not in (0x56, 0x57):
                base = core_jis_addr(a1, a3)
                el, er = crc16(font[base:base + 16]), crc16(font[base + 16:base + 32])
                ok = v.get('P20') == el and v.get('P00') == er
                note.append(f'core {base:05X} ' + ('MATCH' if ok else 'MISMATCH'))
            if fidx is not None:
                for k in ('P20', 'P00'):
                    hits = fidx.get(v.get(k, -1), [])
                    note.append(f'{k}@' + ('/'.join(f'{x:05X}' for x in hits[:3]) if hits else '?'))
            o.append(f'  {key:04X} ' + ' '.join(f'{k}={v[k]:04X}' for k in v) + ('  ' + '; '.join(note) if note else ''))
    if d['cgwr']:
        pre, post, port = d['cgwr'].get('PRE'), d['cgwr'].get('POST'), d['cgwr'].get('PORT')
        if post and port:
            for h, base in ((0, 0xA0), (1, 0x50)):
                w = post[h * 32:(h + 1) * 32]
                ev, od = w[0::2], w[1::2]
                exp_od = bytes(base + i for i in range(1, 32, 2))
                exp_ev = bytes(base + i for i in range(0, 32, 2))
                o.append(f'CGWR A5={h * 0x20:02X}: odd offsets ' + ('land (NP2kai, QEMU, the core)' if od == exp_od else f'read {od.hex().upper()}')
                         + '; even offsets ' + ('round-trip (QEMU)' if ev == exp_ev else ('read 8F (dropped; the low page reads 8F: docs/probes/VRAM.TXT, the core\'s CG_LOW_DUMMY)' if set(ev) == {0x8F} else 'read 00 (dropped: NP2kai\'s zeroed low page)' if not any(ev) else f'read {ev.hex().upper()}'))
                         + ('; 0xA9 = odd bytes' if port[h * 16:(h + 1) * 16] == od else f'; 0xA9 reads {port[h * 16:(h + 1) * 16].hex().upper()}'))
        for x in d['cgwr'].get('CHANGED', []):
            o.append(f'CGWR CHANGED {x}')
        for x in d['cgwr'].get('RESTORE', []):
            o.append(f'CGWR RESTORE {x}')
    for x in d['ide'] + d['w4a0']:
        o.append(x)
    o += kit2_report(d)
    return o


def diff_cg(a: dict, b: dict) -> list[str]:
    out = []
    for k in sorted(set(a['cgs']) | set(b['cgs'])):
        va, vb = a['cgs'].get(k), b['cgs'].get(k)
        if va != vb:
            out.append(f'CGS {k[0]:04X} {k[1]:02X}: {va.hex().upper() if va else "-"} -> {vb.hex().upper() if vb else "-"}')
    return out


def diff(a: dict, b: dict) -> list[str]:
    fa, fb = flat(a), flat(b)
    out = []
    for k in sorted(set(fa) | set(fb)):
        if fa.get(k) != fb.get(k):
            out.append(f'{k}: {fa.get(k, "-")} -> {fb.get(k, "-")}')
    return out


def rboot(text: str) -> list[str]:
    rows = {}
    order = []
    for ln in text.splitlines():
        m = re.match(r'RB (BEFORE|SET|RESTORED|AFTER)\s+(.*)$', ln.strip())
        if not m:
            continue
        vals = dict(re.findall(r'([0-9A-F]{4,5})=([0-9A-F]{2}(?: [0-9A-F]{2} [0-9A-F]{2})?)', m[2]))
        if m[1] not in rows:
            order.append(m[1])
        rows[m[1]] = vals
    if not rows:
        return ['no RB lines']
    keys = list(next(iter(rows.values())).keys())
    out = ['field   ' + ' '.join(f'{t:>9}' for t in order) + '  verdict']
    for k in keys:
        v = {t: rows[t].get(k, '-') for t in order}
        verdict = ''
        if 'BEFORE' in v and 'AFTER' in v:
            if v['AFTER'] == v['BEFORE']:
                verdict = 'as cold'
            elif 'SET' in v and v['AFTER'] == v['SET']:
                verdict = 'KEPT across the reboot'
            else:
                verdict = 'differs from cold'
        if 'RESTORED' in v and 'BEFORE' in v and v['RESTORED'] != v['BEFORE']:
            verdict += ' (restore mismatch)'
        out.append(f'{k:<7} ' + ' '.join(f'{v[t]:>9}' for t in order) + f'  {verdict}')
    return out


SAMPLE = """XE10CFG configuration stores (tools/hwprobe/xe10cfg)\r
PORT 0031=F3 F3\r
PORT 00BE=FF FF\r
PORT 7FDB=40 40\r
SDIPA0 7C 02 76 3E 7C 7F FF BF 7F 7F 49 98 \r
SDIPA1 7C 02 76 3E 7C 7F FF BF 7F 7F 49 98 \r
SDIPB 8F 80 80 80 80 80 80 80 80 80 80 80 \r
SDIPA2 7C 02 76 3E 7C 7F FF BF 7F 7F 49 98 \r
CG 2056 00: 00 3E 73 7E 32 FF 00 00 AA 55 A1 00 8A 00 00 00\r
CG 2156 00: 00 00 00 B0 80 00 00 00 00 00 00 00 00 00 00 00\r
CG 0156 00: 7C 02 76 3E 7C 7F FF BF 7F 7F 49 98 00 00 00 00\r
MSWCELLS 48 05 0C 00 01 00 00 81 \r
RT 0031 was=F3 wrote=0C got=F3 p31=F3 back=F3 p31=F3\r
RT 871E was=3E wrote=1E got=1E p31=E3 back=3E p31=F3\r
MODE68 before/after-0C 18 18\r
DC000 1E8E was/gate/back FE FF FE\r
XE10CFG DONE\r
"""


def kit2_report(d: dict) -> list[str]:
    """The kit-2 rows: /FD (items 59, 190) and /6C (item 36); /IDE2 rows are listed with /IDE."""
    o = []
    for ln in d['kit2']:
        if ln.startswith('ROW'):
            continue
        o.append(ln)
        m = re.search(r'rise=([0-9A-F]{8})', ln)
        if ln.startswith('FDVFO') and m:
            t = int(m[1], 16)
            o.append('  item 190 corner: ' + ('IR11 never rose within 400 ms of the 0x0C write' if t == 0xFFFFFF
                                              else f'IR11 rose {t} ARTIC ticks ({t / 307.2:.2f} ms) after the 0x0C write'))
        m = re.match(r'P6C w=([0-9A-F]{2}) r=([0-9A-F]{2})', ln)
        if m:
            w, r = int(m[1], 16), int(m[2], 16)
            o.append(f'  item 36: wrote {w:02X} read {r:02X}: ' + ('bits 7-4 latch, 3-0 read 0' if r == (w & 0xF0)
                                                               else 'reads FF (unattached)' if r == 0xFF else 'other'))
    return o


def selftest() -> int:
    fails = 0

    def check(name, cond):
        nonlocal fails
        print(f'{"PASS" if cond else "FAIL"} {name}')
        fails += 0 if cond else 1

    k2 = parse('FDVFO preirr/preisr/premsr/irr09-08/msr09-08/irr200ms/irr0C/msr0C/irrdrain 10 00 80 10 80 90 98 80 90 rise=00000F00 sis=C0 00\r\n'
               'P6C w=70 r=70\r\nP6C w=FF r=FF\r\n')
    r2 = '\n'.join(kit2_report(k2))
    check('kit2: FDVFO rise in ms', '12.50 ms' in r2)
    check('kit2: P6C latch vs FF', 'bits 7-4 latch' in r2 and 'unattached' in r2)
    d = parse(SAMPLE)
    check('ports parsed', d['ports'][0x31] == (0xF3, 0xF3) and d['ports'][0x7FDB] == (0x40, 0x40))
    check('sdip parsed', d['sdip']['SDIPA0'][3] == 0x3E and d['sdip']['SDIPB'][0] == 0x8F)
    check('cg parsed', d['cg'][(0x2056, 0)][8:10] == [0xAA, 0x55])
    rows = record(d)
    check('record sum (rows 1..0xA sum to zero)', sum(rows[1:0x0B]) & 0xFF == 0)
    rep = '\n'.join(report(d))
    check('report: ~row2 = 8C vs port F3 does not follow', 'does NOT follow' in rep and '8C' in rep)
    check('report: 0x31 follows 0x871E bit 5', 'FOLLOWS' in rep)
    check('report: P2 write ignored', 'RT 0031: was F3 wrote 0C got F3 (ignored)' in rep)
    check('report: mirror equals ports', '= the ports' in rep)
    check('other labels kept whole', d['other'].get('DC000 1E8E was/gate/back') == 'FE FF FE'
          and d['other'].get('MODE68 before/after-0C') == '18 18')
    b = parse(SAMPLE.replace('PORT 0031=F3 F3', 'PORT 0031=73 73').replace('CG 2056 00: 00 3E 73', 'CG 2056 00: 00 3E F3'))
    dl = diff(d, b)
    check('diff finds the two changes', 'PORT 0031: F3 F3 -> 73 73' in dl and 'CG 2056 row 02: 73 -> F3' in dl and len(dl) == 2)
    rb = ('RB BEFORE  053D=1F 063C=FC 1E8E=FE F8E8F=57 04 00\r\n'
          'RB SET      053D=1F 063C=FE 1E8E=FF F8E8F=57 A5 00\r\n'
          'RB RESTORED 053D=1F 063C=FC 1E8E=FE F8E8F=57 04 00\r\n'
          'RB AFTER    053D=1F 063C=FE 1E8E=FE F8E8F=57 04 00\r\n')
    t = '\n'.join(rboot(rb))
    check('rboot: 063C kept', re.search(r'063C .*KEPT', t) is not None)
    check('rboot: 1E8E as cold', re.search(r'1E8E .*as cold', t) is not None)
    check('rboot: F8E8F triple parsed', '57 04 00' in t)
    # the 2026-11 kit lines
    rec = bytes([0x04, 0xC1, 0x0C, 0x80, 0xCF, 0xFF, 0x00, 0x00, 0xAA, 0x55, 0xE6, 0x86, 0x8A, 0xFF, 0, 0])
    font = bytes(range(256)) * 0x400
    a1, a3 = 0x1F, 0x10
    base = core_jis_addr(a1, a3)
    left, right = crc16(font[base:base + 16]), crc16(font[base + 16:base + 32])
    cg = ('CPU msw=0030 cr0=00000032 idt=03FF:00000000 gdt=03FF:00000000 fpu_sw=0000 fpu_cw=037F\r\n'
          'MODE68OFF before/after-0E/after-0E-20ms/after-0F 18 18 18 18\r\n'
          'CGS 2056 00 ' + rec.hex().upper() + '\r\n'
          'CGS 1056 20 ' + '7F01' + '00' * 14 + '\r\n'
          'CGW 2056 00 ' + ''.join(f'8F{b:02X}' for b in rec) + '\r\n'
          'CGP 2056 00 ' + rec.hex().upper() + '\r\n'
          'CGREP 2056 00 diff=0000 first=FFFF\r\n'
          f'CGX {a1:02X}{a3:02X} P20={left:04X} P00={right:04X} W20E={left:04X} W20O={right:04X} W00E={left:04X} W00O={right:04X}\r\n'
          'CGWR 7E57 POST  (wrote) ' + ''.join(f'8F{0xA0 + i:02X}' for i in range(1, 32, 2)) + ''.join(f'8F{0x50 + i:02X}' for i in range(1, 32, 2)) + '\r\n'
          'CGWR 7E57 PORT (lines) ' + ''.join(f'{0xA0 + i:02X}' for i in range(1, 32, 2)) + ''.join(f'{0x50 + i:02X}' for i in range(1, 32, 2)) + '\r\n'
          'CGWR RESTORE diff=0000\r\n')
    d2 = parse(cg)
    r2 = '\n'.join(cg_report(d2, font))
    check('cpu: FPU answers', 'answers FNINIT' in r2 and 'MP=1' in r2)
    check('mode68off: bit 7 reads 0', 'reads 0 either way' in r2)
    check('record through the window: identical to the core default', 'AA55 valid' in r2 and 'identical' in r2)
    check('saved-table length 017F kept', 'length word (CGS 1056 20 rows 0/1) = 017F (kept' in r2)
    check('window even offsets 8F, odd = port', 'all 8F' in r2 and 'odd = 0xA9 port' in r2)
    check('repeat', 'repeats its 32 bytes exactly' in r2)
    check('wrap table: core address matches the font', 'MATCH' in r2 and 'MISMATCH' not in r2)
    check('cgwr: odd land, even read 8F', 'odd offsets land' in r2 and 'read 8F' in r2 and '0xA9 = odd bytes' in r2)
    check('crc16 check value', crc16(b'123456789') == 0x29B1)
    r4 = '\n'.join(cg_report(parse(cg.replace('CGS 2056 00 ' + rec.hex().upper(), 'CGS 2056 00 ' + '00' * 16)), font))
    check('saved-table length with an invalid record is junk', '= 017F (UNRELIABLE, junk' in r4 and '(kept' not in r4)
    d3 = parse(cg.replace('CGS 2056 00 04C1', 'CGS 2056 00 00C1'))
    check('diff-cg finds the changed record row', len(diff_cg(d2, d3)) == 1)
    print(f'{"PASS" if not fails else "FAIL"}: xe10cfg_decode selftest ({fails} failing)')
    return 1 if fails else 0


def main(argv) -> int:
    if argv[1:] == ['--selftest']:
        return selftest()
    if len(argv) == 4 and argv[1] == '--diff':
        a = parse(open(argv[2], encoding='latin-1').read())
        b = parse(open(argv[3], encoding='latin-1').read())
        for ln in diff(a, b) or ['no differences']:
            print(ln)
        return 0
    if len(argv) == 3 and argv[1] == '--rboot':
        for ln in rboot(open(argv[2], encoding='latin-1').read()):
            print(ln)
        return 0
    if len(argv) == 4 and argv[1] == '--diff-cg':
        a = parse(open(argv[2], encoding='latin-1').read())
        b = parse(open(argv[3], encoding='latin-1').read())
        for ln in diff_cg(a, b) or ['no CGS differences']:
            print(ln)
        return 0
    font = None
    if len(argv) == 4 and argv[1] == '--font':
        font = open(argv[2], 'rb').read()
        argv = [argv[0], argv[3]]
    if len(argv) == 2:
        d = parse(open(argv[1], encoding='latin-1').read())
        for ln in report(d) + cg_report(d, font):
            print(ln)
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))

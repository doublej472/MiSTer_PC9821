#!/usr/bin/env python3
"""integ_selftest.py - EXECUTE integ.com against a model of DOS, with faults injected.

INTEG exists to catch storage corruption, so a probe that cannot see a planted corruption
is worse than none. This runs the REAL built .COM (not a Python port of its algorithm) in
Unicorn's 16-bit x86 emulation, with INT 21h / INT 2Fh answered by a small model of DOS and
MSCDEX over an in-memory volume, and requires:

  * a clean volume gives FAILS=0, every FILE row OK, exit code 0;
  * a planted corruption (4 foreign bytes, as the CD-DA words were) in a file is reported as
    a BAD row at the exact 512-byte-block offset, and the file's FAIL row, exit code 1;
  * a short file, a missing file, a truncated manifest and a write whose read-back differs
    are each reported, the write one with its offset;
  * the W mode writes ONLY its scratch file and deletes it (the model records every create,
    write and delete);
  * /PLAY and P issue exactly one MSCDEX PLAY AUDIO (command 132) for the first AUDIO track
    through the lead-out (a data track 1, audio tracks 2-3 in the model), and stop it after;
  * the image is smaller than the buffers it must not overlap.

The model is the documented DOS/MSCDEX surface; it is NOT evidence of what the Xe10's DOS
does (that is the hardware run). Needs `unicorn` (pip install unicorn); without it the test
SKIPs loudly (exit 2) and is never a silent pass.

Usage: integ_selftest.py [--com PATH]       exit 0 = pass, 1 = fail, 2 = could not run
"""
from __future__ import annotations

import argparse
import os
import struct
import sys
import zlib
from pathlib import Path

try:
    from unicorn import UC_ARCH_X86, UC_HOOK_INTR, UC_MODE_16, Uc, UcError
    from unicorn.x86_const import (UC_X86_REG_AX, UC_X86_REG_BX, UC_X86_REG_CS, UC_X86_REG_CX,
                                   UC_X86_REG_DS, UC_X86_REG_DX, UC_X86_REG_EAX, UC_X86_REG_EFLAGS,
                                   UC_X86_REG_EIP, UC_X86_REG_ES, UC_X86_REG_ESP, UC_X86_REG_SS,
                                   UC_X86_REG_DI, UC_X86_REG_SI)
except ImportError:
    print("SKIP: unicorn is not installed (pip install unicorn)")
    sys.exit(2)

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import integ_manifest as im  # noqa: E402

SEG = 0x1000
BASE = SEG << 4


class Dos:
    """A tiny DOS + MSCDEX over an in-memory volume. Records everything it is asked to write."""

    def __init__(self, files: dict[str, bytes], free_bytes=10 << 20):
        self.files = {k.upper(): bytearray(v) for k, v in files.items()}
        self.handles: dict[int, list] = {}
        self.next_h = 5
        self.out = bytearray()
        self.exit_code = None
        self.free = free_bytes
        self.created, self.deleted, self.wrote = [], [], []
        self.read_fault = None        # fn(path, offset, data)->data  applied to every read
        self.write_fault = None       # fn(path, offset, data)->data  applied to every write
        self.max_file_chunk = None
        self.mscdex = True
        self.requests = []            # every MSCDEX request header+body bytes
        self.tracks = {1: (0x00, 0x02, 0, 0x40), 2: (0, 0x10, 0x05, 0x00), 3: (0, 0x30, 0x0A, 0x00)}
        self.lead = (0, 0x00, 0x14)   # frame, sec, min
        self.reads = 0

    # -- helpers
    @staticmethod
    def cstr(uc, off):
        out = bytearray()
        while True:
            b = uc.mem_read(BASE + off + len(out), 1)[0]
            if not b:
                return out.decode('ascii')
            out.append(b)

    def intr(self, uc, intno):
        ax = uc.reg_read(UC_X86_REG_AX)
        bx = uc.reg_read(UC_X86_REG_BX)
        cx = uc.reg_read(UC_X86_REG_CX)
        dx = uc.reg_read(UC_X86_REG_DX)
        ah, al = ax >> 8, ax & 0xFF
        fl = uc.reg_read(UC_X86_REG_EFLAGS)

        def ret(ax_=None, cf=False, bx_=None, cx_=None, dx_=None):
            if ax_ is not None:
                uc.reg_write(UC_X86_REG_AX, ax_ & 0xFFFF)
            if bx_ is not None:
                uc.reg_write(UC_X86_REG_BX, bx_ & 0xFFFF)
            if cx_ is not None:
                uc.reg_write(UC_X86_REG_CX, cx_ & 0xFFFF)
            if dx_ is not None:
                uc.reg_write(UC_X86_REG_DX, dx_ & 0xFFFF)
            uc.reg_write(UC_X86_REG_EFLAGS, (fl | 1) if cf else (fl & ~1))

        if intno == 0x2F:
            if ax == 0x1500:
                return ret(bx_=1 if self.mscdex else 0, cx_=4)
            if ax == 0x1510:
                return self.mscdex_req(uc, cx, bx)
            return ret()
        if intno != 0x21:
            raise SystemExit(f"unexpected INT {intno:02X}")
        if ah == 0x02:
            self.out.append(dx & 0xFF)
            return ret()
        if ah == 0x0D:
            return ret()
        if ah == 0x25:
            self.vectors = getattr(self, 'vectors', {})
            self.vectors[al] = dx
            return ret()
        if ah == 0x36:
            if (dx & 0xFF) == 0 or self.free is None:
                return ret(0xFFFF)
            return ret(ax_=1, bx_=self.free // 512, cx_=512, dx_=self.free // 512)
        if ah == 0x3C:
            p = self.cstr(uc, dx).upper()
            self.created.append(p)
            self.files[p] = bytearray()
            return self.open_h(p, ret)
        if ah == 0x3D:
            p = self.cstr(uc, dx).upper()
            if p not in self.files:
                return ret(2, cf=True)
            return self.open_h(p, ret)
        if ah == 0x3E:
            self.handles.pop(bx, None)
            return ret()
        if ah == 0x3F:
            h = self.handles.get(bx)
            if h is None:
                return ret(6, cf=True)
            path, pos = h
            data = bytes(self.files[path][pos:pos + cx])
            if self.max_file_chunk:
                data = data[:self.max_file_chunk]
            if self.read_fault:
                data = self.read_fault(path, pos, data)
            h[1] += len(data)
            uc.mem_write(BASE + dx, data)
            self.reads += 1
            return ret(len(data))
        if ah == 0x40:
            h = self.handles.get(bx)
            if h is None:
                return ret(6, cf=True)
            path, pos = h
            data = bytes(uc.mem_read(BASE + dx, cx))
            if self.write_fault:
                data = self.write_fault(path, pos, data)
            self.wrote.append((path, pos, len(data)))
            f = self.files[path]
            if len(f) < pos + len(data):
                f.extend(b'\0' * (pos + len(data) - len(f)))
            f[pos:pos + len(data)] = data
            h[1] += len(data)
            return ret(len(data))
        if ah == 0x41:
            p = self.cstr(uc, dx).upper()
            self.deleted.append(p)
            self.files.pop(p, None)
            return ret()
        if ah == 0x4C:
            self.exit_code = al
            uc.emu_stop()
            return
        raise SystemExit(f"unmodelled INT 21h AH={ah:02X}")

    def open_h(self, path, ret):
        h = self.next_h
        self.next_h += 1
        self.handles[h] = [path, 0]
        return ret(h)

    def mscdex_req(self, uc, drive, bx):
        es = uc.reg_read(UC_X86_REG_ES)
        base = (es << 4) + bx
        req = bytearray(uc.mem_read(base, 40))
        cmd = req[2]
        self.requests.append((drive, bytes(req)))
        status = 0x0100
        if cmd == 3:                       # IOCTL input
            tptr_off, tptr_seg = struct.unpack_from('<HH', req, 14)
            tbase = (tptr_seg << 4) + tptr_off
            code = uc.mem_read(tbase, 1)[0]
            if code == 10:
                uc.mem_write(tbase, bytes([10, 1, 3, self.lead[0], self.lead[1], self.lead[2], 0]))
            elif code == 11:
                t = uc.mem_read(tbase + 1, 1)[0]
                fr, sc, mn, ctl = self.tracks[t]
                uc.mem_write(tbase, bytes([11, t, fr, sc, mn, 0, ctl]))
            else:
                status = 0x8103
        elif cmd in (132, 133):
            pass
        else:
            status = 0x8103
        struct.pack_into('<H', req, 3, status)
        uc.mem_write(base, bytes(req))
        fl = uc.reg_read(UC_X86_REG_EFLAGS)
        uc.reg_write(UC_X86_REG_EFLAGS, fl & ~1)


def file_ok_rows(t: str) -> int:
    """The FILE rows that end in OK (not any ' OK' in the text)."""
    return sum(1 for ln in t.splitlines() if ln.startswith('FILE ') and ln.rstrip().endswith(' OK'))


# Request header lengths per MSCDEX command, as integ.s builds them (integ.s:1305/1328 IOCTL
# input 26, :1355 PLAY AUDIO 22, :1426 STOP AUDIO 13; MSCDEX 2.x device-driver request
# layouts: a 13-byte static header, IOCTL input +13, PLAY AUDIO +9, STOP AUDIO none).
REQ_LEN = {3: 26, 132: 22, 133: 13}


def run(com: bytes, dos: Dos, tail: str, max_ins=200_000_000):
    uc = Uc(UC_ARCH_X86, UC_MODE_16)
    uc.mem_map(0, 0x200000)
    uc.mem_write(BASE + 0x100, com)
    tail_b = (' ' + tail).encode() if tail else b''
    uc.mem_write(BASE + 0x80, bytes([len(tail_b)]) + tail_b + b'\r')
    for r in (UC_X86_REG_CS, UC_X86_REG_DS, UC_X86_REG_ES, UC_X86_REG_SS):
        uc.reg_write(r, SEG)
    uc.reg_write(UC_X86_REG_ESP, 0xFFFE)
    uc.reg_write(UC_X86_REG_EIP, 0x100)
    uc.hook_add(UC_HOOK_INTR, lambda u, n, _: dos.intr(u, n))
    try:
        uc.emu_start(BASE + 0x100, 0, count=max_ins)
    except UcError as e:
        raise SystemExit(f"emulation error {e} at {uc.reg_read(UC_X86_REG_CS):04X}:{uc.reg_read(UC_X86_REG_EIP):04X}")
    if dos.exit_code is None:
        raise SystemExit("integ.com did not exit (instruction budget exhausted)")
    return dos.out.decode('ascii', 'replace').replace('\r\n', '\n')


FAILS = 0


def check(cond, what, text=''):
    global FAILS
    if not cond:
        FAILS += 1
        print(f"FAIL: {what}")
        if text:
            print('      ' + text.replace('\n', '\n      '))
    else:
        print(f"ok:   {what}")


def mk_files():
    rnd = lambda n, s: bytes((i * s + (i >> 8) * 7 + 3) & 0xFF for i in range(n))
    return {'GAME\\BIG.DAT': rnd(70000, 31), 'GAME\\ODD.BIN': rnd(1283, 5), 'SMALL.TXT': rnd(100, 9),
            'EMPTY.DAT': b''}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--com', default=str(HERE / 'integ.com'))
    a = ap.parse_args()
    if not os.path.exists(a.com):
        print(f"SKIP: {a.com} not built (make -C tools/hwprobe integ/integ.com)")
        return 2
    com = Path(a.com).read_bytes()
    check(len(com) + 0x100 < 0x4000, f"image ({len(com)} bytes) ends below the buffers at 0x4000")

    files = mk_files()
    man = im.manifest_text(((p, d) for p, d in files.items()), 'C:').encode()

    def vol(extra=None):
        v = {'C:\\' + p: d for p, d in files.items()}
        v['INTEG.MAN'] = man
        v.update(extra or {})
        return v

    # ---- V1: a clean volume
    d = Dos(vol())
    t = run(com, d, 'V')
    check(d.exit_code == 0 and 'INTEG END FAILS=0000' in t, "V clean: FAILS=0, exit 0", t)
    check(file_ok_rows(t) == 4 and 'BAD  ' not in t, "V clean: four FILE rows OK, no BAD row", t)
    check(d.wrote == [] and d.created == [], "V writes nothing")
    check(getattr(d, 'vectors', {}).get(0x24) is not None, "INT 24h is hooked (a Not-ready drive must not block on Abort/Retry/Fail)")

    # ---- V1b: one manifest for any drive letter ('*:' + /D:x)
    starman = im.manifest_text(((p, d_) for p, d_ in files.items()), '*:').encode()
    d = Dos(dict(vol(), **{'INTEG.MAN': starman}))
    t = run(com, d, 'V /D:C')
    check(d.exit_code == 0 and file_ok_rows(t) == 4 and 'FILE C:\\GAME\\BIG.DAT' in t, "V /D:C resolves '*:' paths to C:", t)
    # the same with LF-only line ends: the '*' substitution must not lose the path's terminator
    # (it used AL, so the LF that ended the path was forgotten and the next 'B' line skipped)
    lfman = starman.replace(b'\r\n', b'\n')
    d = Dos(dict(vol(), **{'INTEG.MAN': lfman}))
    t = run(com, d, 'V /D:C')
    check(d.exit_code == 0 and file_ok_rows(t) == 4 and 'INTEG END FAILS=0000' in t,
          "V /D:C with an LF-only '*:' manifest: every FILE row OK", t)
    d = Dos(dict(vol(), **{'INTEG.MAN': starman}))
    t = run(com, d, 'V')
    check(d.exit_code != 0 and 'OPENFAIL' in t, "V with '*:' paths and no /D: fails loudly", t)

    # ---- V2: planted corruption, as foreign words in a sector (offset 0x4203, 4 bytes)
    def fault(path, pos, data):
        if path == 'C:\\GAME\\BIG.DAT' and pos <= 0x4203 < pos + len(data):
            b = bytearray(data)
            b[0x4203 - pos:0x4203 - pos + 4] = b'\xDE\xAD\xBE\xEF'
            return bytes(b)
        return data
    d = Dos(vol())
    d.read_fault = fault
    t = run(com, d, 'V')
    check(d.exit_code == 1 and 'INTEG END FAILS=0001' in t, "V corrupt: exit 1, FAILS=1", t)
    check('BAD  C:\\GAME\\BIG.DAT OFF=00004200 BLK=00000021' in t, "V corrupt: BAD row names offset 0x4200 / block 0x21", t)
    check('DATA=' in t and 'FAIL' in t, "V corrupt: the block's bytes and a FAIL row are printed", t)

    # ---- V3: many bad blocks are capped but counted
    def fault_all(path, pos, data):
        if path.endswith('BIG.DAT'):
            return bytes(b ^ 0xFF for b in data)
        return data
    d = Dos(vol())
    d.read_fault = fault_all
    t = run(com, d, 'V')
    nbad = t.count('BAD ')
    check(nbad == 8, f"V all-bad: BAD rows capped at 8 (got {nbad})", t)
    check('BADBLK=00000089' in t, "V all-bad: 0x89 (137) bad blocks counted", t)

    # ---- V4: short file, missing file
    v = vol()
    v['C:\\GAME\\BIG.DAT'] = v['C:\\GAME\\BIG.DAT'][:50000]
    del v['C:\\SMALL.TXT']
    d = Dos(v)
    t = run(com, d, 'V')
    check('SHORT=01' in t, "V short file: SHORT reported", t)
    check('C:\\SMALL.TXT OPENFAIL AX=0002' in t, "V missing file: OPENFAIL reported", t)
    check(d.exit_code == 2, "V short + missing: exit 2", t)

    # ---- V5: a DOS that returns short reads (floppy/CD track-bounded reads) still verifies
    d = Dos(vol())
    d.max_file_chunk = 1000
    t = run(com, d, 'V')
    check(d.exit_code == 0, "V with 1000-byte reads: clean", t)

    # ---- V6: truncated manifest (block list ends early)
    short = man.split(b'\r\nB ')
    trunc = b'\r\nB '.join(short[:2]) + b'\r\n'
    v = vol()
    v['INTEG.MAN'] = trunc
    d = Dos(v)
    t = run(com, d, 'V')
    check('MANIFEST-SHORT' in t and d.exit_code != 0, "V truncated manifest: reported", t)

    # ---- W1: clean write/read-back
    d = Dos({}, free_bytes=4 << 20)
    t = run(com, d, 'W A: /K:64')
    check(d.exit_code == 0 and t.count(' OK') == 2, "W clean: two passes OK, exit 0", t)
    check(d.created == ['A:\\INTEGTMP.DAT'] * 2 and d.deleted == ['A:\\INTEGTMP.DAT'], "W creates only its scratch file and deletes it", f"{d.created} {d.deleted}")
    check(len(d.wrote) == 32 and all(w[0] == 'A:\\INTEGTMP.DAT' for w in d.wrote), "W: 2 passes x 16 chunks written, all to the scratch file")
    check('A:\\INTEGTMP.DAT' not in d.files, "W: the scratch file is gone")

    # ---- W2: the medium returns different bytes than were written (a corrupt sector 5 of 128)
    def rfault(path, pos, data):
        if pos <= 5 * 512 + 8 < pos + len(data):
            b = bytearray(data)
            b[5 * 512 + 8 - pos] ^= 0x40
            return bytes(b)
        return data
    d = Dos({}, free_bytes=4 << 20)
    d.read_fault = rfault
    t = run(com, d, 'W C: /K:64')
    check(d.exit_code == 2 and 'BAD  C:\\INTEGTMP.DAT OFF=00000A08 BLK=00000005' in t, "W corrupt read-back: BAD row at offset 0xA08, block 5", t)
    check(t.count('BAD ') == 2 and 'BADBLK=00000001 FAIL' in t, "W corrupt: both passes caught", t)

    # ---- W3: a write that lands wrong (the write path corrupts), caught on read-back of the pass
    def wfault(path, pos, data):
        if pos == 4096:
            b = bytearray(data)
            b[100] ^= 1
            return bytes(b)
        return data
    d = Dos({}, free_bytes=4 << 20)
    d.write_fault = wfault
    t = run(com, d, 'W B: /K:64')
    check('BAD  B:\\INTEGTMP.DAT OFF=00001064 BLK=00000008' in t, "W corrupt write: BAD row at 0x1064, block 8", t)

    # ---- W4: no space / no drive
    d = Dos({}, free_bytes=8 << 10)
    t = run(com, d, 'W A:')
    check('WFAIL NOSPACE' in t and d.exit_code == 1, "W on a full disk: NOSPACE", t)
    d = Dos({}, free_bytes=None)
    t = run(com, d, 'W Q:')
    check('WFAIL NODRIVE' in t, "W on an absent drive: NODRIVE", t)

    # ---- CD-DA
    d = Dos(vol())
    t = run(com, d, 'V /PLAY')
    plays = [r for _, r in d.requests if r[2] == 132]
    stops = [r for _, r in d.requests if r[2] == 133]
    check(len(plays) == 1 and len(stops) == 1, "V /PLAY: one PLAY AUDIO, one STOP", t)
    if plays:
        r = plays[0]
        start = struct.unpack_from('<I', r, 14)[0]
        n = struct.unpack_from('<I', r, 18)[0]
        # track 2 starts 05:10:00? (frame 0, sec 0x10, min 5), lead-out 0x14 min
        want_start = bytes([0, 0x10, 5, 0])
        want_n = (0x14 * 4500) - (5 * 4500 + 0x10 * 75)
        check(r[0] == 22 and r[13] == 1 and r[14:18] == want_start and n == want_n,
              f"PLAY AUDIO: Red Book, first AUDIO track (2), start {start:08X}, {n} sectors to the lead-out", t)
    check(bool(d.requests) and all(REQ_LEN.get(r[2]) == r[0] for _, r in d.requests),
          "every request length is the documented one: "
          + ", ".join(f"cmd {r[2]} len {r[0]}" for _, r in d.requests))
    check('PLAY OK DRV=04 TRACK=02' in t, "PLAY row names the drive and track", t)
    check(d.exit_code == 0, "V /PLAY on a clean volume: exit 0", t)

    d = Dos(vol())
    t = run(com, d, 'P')
    check(len([1 for _, r in d.requests if r[2] == 132]) == 1 and not [1 for _, r in d.requests if r[2] == 133], "P: plays and does NOT stop", t)
    d = Dos(vol())
    t = run(com, d, 'S')
    check(len([1 for _, r in d.requests if r[2] == 133]) == 1, "S: stops", t)

    d = Dos(vol())
    d.mscdex = False
    t = run(com, d, 'V /PLAY')
    check('PLAY NOMSCDEX' in t and d.exit_code == 0, "no MSCDEX: reported, the verify still runs", t)

    print(f"\n{'PASS' if FAILS == 0 else 'FAIL'}: {FAILS} failed checks")
    return 0 if FAILS == 0 else 1


if __name__ == '__main__':
    sys.exit(main())

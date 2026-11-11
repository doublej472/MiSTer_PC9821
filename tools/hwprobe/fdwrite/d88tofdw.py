#!/usr/bin/env python3
"""d88tofdw.py - D88 floppy images to and from FDWRITE.COM's track container (.FDW).

  d88tofdw.py info    IMAGE.d88                 per-track geometry, irregularities
  d88tofdw.py convert IMAGE.d88 OUT.FDW         the container FDWRITE writes from
  d88tofdw.py compare SOURCE.d88 WRITTEN.d88    per track: sector ID list (order too), N,
                                                density, deleted/status flags, data bytes
  d88tofdw.py blank   SOURCE.d88 OUT.d88        SOURCE's exact track layout, data zeroed
                                                (a pre-formatted target for FDWRITE /NF)
  d88tofdw.py empty   OUT.d88                   an unformatted 2HD D88 (header only)
  d88tofdw.py --selftest

THE D88 LAYOUT (NP2kai fdd/d88head.h, read by diskimage/fd/fdd_d88.c): a 0x2B0-byte header -
name[17], reserved[9], protect (0x1A), media type (0x1B: 0x20 = 2HD), file size (0x1C, LE32),
then 164 LE32 track offsets at 0x20, track index = C * 2 + H (fdd_seek_d88
`trkseek(fdd, (fdc.ncn << 1) + fdc.hd)`). Each track is a run of a 16-byte sector header
(c, h, r, n, sectors LE16, mfm_flg, del_flg, stat, reserved[5], size LE16) and its data.
mfm_flg 0x40 is single density (FM): NP2kai's searchsector_d88 refuses a sector whose flag
disagrees with the command's MF bit (`!((fdc.mf ^ mfm_flg) & 0x40)`).

THE CONTAINER (.FDW, little-endian), read sequentially by fdwrite.s:
  header, 16 bytes: "FDWIMG1" 0x1A, ntracks (LE16), media type (the D88's byte 0x1B),
                    0, reserved (4 bytes, 0)
  then per track, in D88 track-index order (C0H0, C0H1, C1H0, ...):
    8 bytes: C, H, nsec, N, MF (0x40 MFM / 0x00 FM), format fill byte, CRC-16 of the data (LE16)
    nsec * 4 bytes: the sector IDs C, H, R, N in the D88's (physical) order - the format list
    nsec * (128 << N) bytes: the sector data in R order, R = 1 .. nsec
  CRC-16 is CCITT (poly 0x1021, init 0xFFFF, no reflection), the same loop as fdwrite.s crc16.

WHAT FDWRITE CAN WRITE, and so what `convert` refuses. FDWRITE formats a track with the DISK
BIOS (INT 1Bh 0Dh), which takes the sectors-per-track count from its own parameter table for
the track's N and density, not from the caller (NP2kai bios/bios1b.c fdfmt_biospara reads SC
from the table; bios/fdfmt.h fdfmt2hd: MFM N=1 SC 0x1A, N=2 0x0F, N=3 0x08; FM N=0 0x1A, N=1
0x0F, N=2 0x08), and then writes and reads the track as ONE multi-sector call from R = 1 up to
the table's EOT (the same rows). So a track must have exactly that many sectors, IDs R = 1..SC
(in any physical order: the interleave is kept), C and H equal to the physical cylinder and
head, one N and one density for the whole track, no deleted-data mark, no recorded CRC error,
and every sector stored at its full 128 << N bytes. Anything else (a copy-protection track)
is reported by `info` and refused by `convert`, rather than written wrongly.
"""
import struct
import sys

D88_HDR = 0x2B0
D88_SEC = struct.Struct('<BBBBHBBB5sH')
MAGIC = b'FDWIMG1\x1a'
FILL = 0xE5

# 2HD (1 MB interface) BIOS format table: (N, MF) -> SC. NP2kai bios/fdfmt.h fdfmt2hd, rows
# N = 0..3, columns "MFM FMT SC" and "FM FMT SC" (0x00 = not formattable).
BIOS_SC_2HD = {(0, 0x40): 0x00, (1, 0x40): 0x1A, (2, 0x40): 0x0F, (3, 0x40): 0x08,
               (0, 0x00): 0x1A, (1, 0x00): 0x0F, (2, 0x00): 0x08, (3, 0x00): 0x00}


def crc16(data):
    c = 0xFFFF
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def read_d88(blob):
    """-> (header dict, list of 164 entries: None or a list of sector dicts in file order)."""
    if len(blob) < D88_HDR:
        raise ValueError('shorter than a D88 header')
    hdr = {'name': blob[:17].split(b'\0')[0], 'protect': blob[0x1A], 'media': blob[0x1B],
           'size': struct.unpack_from('<I', blob, 0x1C)[0]}
    offs = struct.unpack_from('<164I', blob, 0x20)
    tracks = []
    for t, o in enumerate(offs):
        if not o:
            tracks.append(None)
            continue
        secs = []
        p = o
        n = struct.unpack_from('<H', blob, p + 4)[0]
        for _ in range(n):
            c, h, r, nn, ns, dens, dele, st, res, sz = D88_SEC.unpack_from(blob, p)
            secs.append({'c': c, 'h': h, 'r': r, 'n': nn, 'sectors': ns, 'fm': dens & 0x40,
                         'dens': dens, 'del': dele, 'stat': st, 'res': res, 'size': sz,
                         'data': blob[p + 16:p + 16 + sz]})
            p += 16 + sz
        tracks.append(secs)
    return hdr, tracks


def track_problems(t, secs):
    """Why FDWRITE could not write this track exactly; [] when it can."""
    cyl, head = t >> 1, t & 1
    out = []
    ns = set(s['n'] for s in secs)
    fm = set(s['fm'] for s in secs)
    if len(ns) != 1:
        out.append('mixed N %s' % sorted(ns))
    if len(fm) != 1:
        out.append('mixed FM/MFM')
    if len(ns) == 1 and len(fm) == 1:
        n = ns.pop()
        mf = 0x00 if fm.pop() else 0x40
        sc = BIOS_SC_2HD.get((n, mf), 0)
        if not sc:
            out.append('N=%d %s is not in the BIOS 2HD format table' % (n, 'MFM' if mf else 'FM'))
        elif len(secs) != sc:
            out.append('%d sectors, the BIOS formats %d for this N' % (len(secs), sc))
        if sorted(s['r'] for s in secs) != list(range(1, len(secs) + 1)):
            out.append('R IDs %s are not 1..%d' % ([s['r'] for s in secs], len(secs)))
    if any(s['c'] != cyl or s['h'] != head for s in secs):
        out.append('C/H IDs differ from the physical track')
    if any(s['del'] for s in secs):
        out.append('deleted-data marks')
    if any(s['stat'] for s in secs):
        out.append('recorded status (CRC error etc.) %s' % sorted(set(s['stat'] for s in secs)))
    if any(s['size'] != 128 << s['n'] for s in secs):
        out.append('stored size differs from 128 << N')
    if any(s['sectors'] != len(secs) for s in secs):
        out.append('sector-count field disagrees')
    return out


def cmd_info(path):
    hdr, tracks = read_d88(open(path, 'rb').read())
    print('%s: name=%r protect=%02X media=%02X size=%d' % (path, hdr['name'], hdr['protect'],
                                                        hdr['media'], hdr['size']))
    present = [t for t, s in enumerate(tracks) if s is not None]
    print('tracks present: %d (index %d..%d), unformatted slots: %d' % (
        len(present), present[0] if present else -1, present[-1] if present else -1,
        164 - len(present)))
    shapes = {}
    for t in present:
        secs = tracks[t]
        key = ('FM' if secs[0]['fm'] else 'MFM', len(secs), secs[0]['n'], 128 << secs[0]['n'],
               tuple(s['r'] for s in secs))
        shapes.setdefault(key, []).append(t)
    for (dens, n, nn, sz, order), ts in shapes.items():
        print('  %-3s %2d x %4d (N=%d)  R order %s  tracks %s' % (
            dens, n, sz, nn, ','.join(str(r) for r in order),
            ('%d..%d' % (ts[0], ts[-1]) if ts == list(range(ts[0], ts[-1] + 1)) and len(ts) > 1
             else ','.join(map(str, ts)))))
    bad = 0
    for t in present:
        p = track_problems(t, tracks[t])
        if p:
            bad += 1
            print('  IRREGULAR track %d (C%d H%d): %s' % (t, t >> 1, t & 1, '; '.join(p)))
    print('irregular tracks: %d' % bad)
    return bad


def cmd_convert(src, dst):
    blob = open(src, 'rb').read()
    hdr, tracks = read_d88(blob)
    if hdr['media'] != 0x20:
        sys.exit('media type %02X: FDWRITE writes 2HD (0x20) images only' % hdr['media'])
    present = [t for t, s in enumerate(tracks) if s is not None]
    if present != list(range(len(present))):
        sys.exit('the image has unformatted tracks between formatted ones; not supported')
    out = bytearray(MAGIC + struct.pack('<HBB4x', len(present), hdr['media'], 0))
    for t in present:
        secs = tracks[t]
        p = track_problems(t, secs)
        if p:
            sys.exit('track %d (C%d H%d) cannot be written by the BIOS: %s' % (
                t, t >> 1, t & 1, '; '.join(p)))
        n = secs[0]['n']
        mf = 0x00 if secs[0]['fm'] else 0x40
        data = b''.join(s['data'] for s in sorted(secs, key=lambda s: s['r']))
        out += struct.pack('<6BH', t >> 1, t & 1, len(secs), n, mf, FILL, crc16(data))
        out += b''.join(bytes((s['c'], s['h'], s['r'], s['n'])) for s in secs)
        out += data
    open(dst, 'wb').write(out)
    print('%s: %d tracks, %d bytes' % (dst, len(present), len(out)))


def read_fdw(blob):
    """-> list of (C, H, MF, fill, [ids], data)."""
    if blob[:8] != MAGIC:
        raise ValueError('not an FDW container')
    ntr = struct.unpack_from('<H', blob, 8)[0]
    p = 16
    out = []
    for _ in range(ntr):
        c, h, ns, n, mf, fill, crc = struct.unpack_from('<6BH', blob, p)
        p += 8
        ids = [tuple(blob[p + 4 * i:p + 4 * i + 4]) for i in range(ns)]
        p += 4 * ns
        data = blob[p:p + ns * (128 << n)]
        p += ns * (128 << n)
        if crc16(data) != crc:
            raise ValueError('track C%d H%d: CRC mismatch' % (c, h))
        out.append((c, h, mf, fill, ids, data))
    if p != len(blob):
        raise ValueError('trailing bytes after the last track')
    return out


def cmd_compare(src, got):
    _, a = read_d88(open(src, 'rb').read())
    _, b = read_d88(open(got, 'rb').read())
    bad = 0
    nsec = 0
    for t in range(164):
        sa, sb = a[t], b[t]
        if sa is None and sb is None:
            continue
        if sa is None or sb is None:
            print('track %3d: %s' % (t, 'missing in WRITTEN' if sb is None else 'extra in WRITTEN'))
            bad += 1
            continue
        msgs = []
        ida = [(s['c'], s['h'], s['r'], s['n']) for s in sa]
        idb = [(s['c'], s['h'], s['r'], s['n']) for s in sb]
        if ida != idb:
            msgs.append('ID list differs%s' % (' (order only)' if sorted(ida) == sorted(idb) else ''))
        if [s['fm'] for s in sa] != [s['fm'] for s in sb]:
            msgs.append('density flags differ (src %s, written %s)' % (
                sorted(set(s['fm'] for s in sa)), sorted(set(s['fm'] for s in sb))))
        if [(s['del'], s['stat']) for s in sa] != [(s['del'], s['stat']) for s in sb]:
            msgs.append('deleted/status flags differ')
        byid = {(s['c'], s['h'], s['r'], s['n']): s['data'] for s in sb}
        for s in sa:
            nsec += 1
            k = (s['c'], s['h'], s['r'], s['n'])
            if k not in byid:
                msgs.append('sector %s missing' % (k,))
            elif byid[k] != s['data']:
                msgs.append('sector R=%d data differs' % s['r'])
        if msgs:
            bad += 1
            print('track %3d (C%d H%d): %s' % (t, t >> 1, t & 1, '; '.join(msgs)))
    print('compare %s vs %s: %d sectors checked, %d tracks differ -> %s' % (
        src, got, nsec, bad, 'MATCH' if not bad else 'DIFFER'))
    return 1 if bad else 0


def write_d88(path, media, tracks):
    body = bytearray()
    offs = [0] * 164
    for t, secs in enumerate(tracks):
        if secs is None:
            continue
        offs[t] = D88_HDR + len(body)
        for s in secs:
            body += D88_SEC.pack(s['c'], s['h'], s['r'], s['n'], len(secs), s['dens'],
                                 s['del'], s['stat'], b'\0' * 5, len(s['data']))
            body += s['data']
    hdr = bytearray(D88_HDR)
    hdr[0x1B] = media
    struct.pack_into('<I', hdr, 0x1C, D88_HDR + len(body))
    struct.pack_into('<164I', hdr, 0x20, *offs)
    open(path, 'wb').write(hdr + body)


def cmd_blank(src, dst):
    hdr, tracks = read_d88(open(src, 'rb').read())
    for secs in tracks:
        for s in secs or ():
            s['data'] = bytes(len(s['data']))
    write_d88(dst, hdr['media'], tracks)
    print('%s: %s layout, data zeroed' % (dst, src))


def cmd_empty(dst):
    write_d88(dst, 0x20, [None] * 164)
    print('%s: unformatted 2HD D88' % dst)


def selftest():
    import os
    import tempfile
    assert crc16(b'123456789') == 0x29B1  # CRC-16/CCITT-FALSE check value
    d = tempfile.mkdtemp()
    order = [1, 14, 2, 15, 3, 16, 4, 17, 5, 18, 6, 19, 7, 20, 8, 21, 9, 22, 10, 23, 11, 24,
             12, 25, 13, 26]
    tracks = []
    for t in range(4):
        n = 0 if t == 0 else 1
        tracks.append([{'c': t >> 1, 'h': t & 1, 'r': r, 'n': n, 'dens': 0x40 if t == 0 else 0,
                        'fm': 0x40 if t == 0 else 0, 'sectors': 26, 'size': 128 << n,
                        'del': 0, 'stat': 0, 'data': bytes((t * 7 + r + i) & 0xFF
                                                           for i in range(128 << n))}
                       for r in order])
    src = os.path.join(d, 's.d88')
    write_d88(src, 0x20, tracks + [None] * 160)
    _, back = read_d88(open(src, 'rb').read())
    assert all(not track_problems(t, back[t]) for t in range(4))
    fdw = os.path.join(d, 's.fdw')
    cmd_convert(src, fdw)
    trk = read_fdw(open(fdw, 'rb').read())
    assert len(trk) == 4 and trk[0][2] == 0x00 and trk[1][2] == 0x40
    assert trk[1][5][:256] == back[1][0]['data']           # R order: R=1 first
    assert [i[2] for i in trk[2][4]] == order               # physical ID order kept
    assert cmd_compare(src, src) == 0
    blank = os.path.join(d, 'b.d88')
    cmd_blank(src, blank)
    assert cmd_compare(src, blank) == 1
    tracks[3][5]['del'] = 0x10
    assert track_problems(3, tracks[3])
    tracks[3][5]['del'] = 0
    assert track_problems(2, tracks[2][:25])
    import shutil
    shutil.rmtree(d)
    print('d88tofdw selftest: PASS')
    return 0


def main(a):
    if a[:1] == ['--selftest']:
        return selftest()
    cmds = {'info': (1, cmd_info), 'convert': (2, cmd_convert), 'compare': (2, cmd_compare),
            'blank': (2, cmd_blank), 'empty': (1, cmd_empty)}
    if not a or a[0] not in cmds or len(a) != cmds[a[0]][0] + 1:
        print(__doc__)
        return 2
    r = cmds[a[0]][1](*a[1:])
    return r if isinstance(r, int) and a[0] == 'compare' else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

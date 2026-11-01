#!/usr/bin/env python3
"""Parse and check an SNDTEST transcript (tools/hwprobe/sndtest/sndtest.s).

Two jobs, both on the SAME manifest the probe prints:

1. VALIDATE it against the references.  For every segment it recomputes the
   tone frequency from the register values the write log actually contains and
   compares it with the header's `freq=`, and it recomputes the register-level
   gain in dB and compares it with the header's dB - so a header that disagrees
   with the writes it introduces, or a write program that disagrees with the
   law it claims, is a failure.  The laws, all from the references (see
   sndtest.s's citations):
     FM   f = fnum * 2^block * MULTI * (7987200/144) / 2^21   (the chip doubles
          the F-NUM first: ymfm ymfm_opn.cpp:354-387 `(fnum<<1)<<block>>2`;
          the die fmopna_impl.c:1270/:1358; measured against NP2kai fmgen, whose
          phase generator gives 880.7 Hz for fnum 1040 / block 5 / MULTI 1)
          attenuation = TL * 0.7526 dB (the die's eg_tl<<3 into the
          eg_out<<2 index against a 256-unit-per-octave table)
     SSG  f = 124800 / TP                                    (ssg clock
          master/4, square clock/(16*TP); NP2kai keydisp_bindpsg)
          level = the die's 32-entry table, index (level<<1)|1
     DRUM vol = 94 - IL - TL, mul = 15 - (vol & 7), shift = vol >> 3,
          gain = mul / 2^(1+shift) (die == ymfm == ours)

2. EMIT the segment table: one row per segment with the class, the frequency,
   the register-level gain and the MEASURED duration (the ARTIC delta the probe
   printed, 307200 Hz), plus a start/end offset in milliseconds from the first
   segment - which is what aligns a raw line-out recording segment by segment.

Nothing here is evidence about hardware: it checks the probe's OWN arithmetic
and turns its output into a table.
"""
import argparse
import math
import re
import struct
import sys

FM_CLK = 7987200.0
FM_RATE_DIV = 144.0            # FM sample rate = master/144 (ymfm, jt12)
SSG_DIV = 64.0                 # SSG tone = (master/64)/TP = 124800/TP
ARTIC_HZ = 307200.0
# The OPN MULTI table (register value -> frequency multiple).  THE CHIP DOUBLES
# THE F-NUM FIRST: ymfm's compute_phase_step takes `fnum = block_freq & 0x7ff`
# << 1 and then `phase_step = (fnum << block) >> 2`, i.e.
#   phase step per operator sample = (fnum << block) / 2 * MULTI
# so with the FM sample rate master/144 the tone is
#   f = fnum * 2^block * MULTI * (master/144) / 2^21
# The die agrees (`lfo_fnum = (fnum << 1) + pm`, `pg_freq = (lfo_fnum << block)
# >> 2`, fmopna_impl.c:1270/:1358) and NP2kai's opngenc.c:571/:398 does too.
# An earlier revision of this checker used (fnum<<block)/4 and was one octave
# low - which made the check circular on that axis.
MULTI = [0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 12, 12, 15, 15]
FM_PHASE_DIV = 2.0             # (fnum << block) / 2, the chip's doubled F-NUM
FM_TL_DB = 6.0206 / 8.0        # per TL step: 32 index units of 256/octave
SSG_LUT = [0.0000, 0.0000, 0.0049, 0.0075, 0.0105, 0.0131, 0.0156, 0.0183,
           0.0228, 0.0276, 0.0321, 0.0367, 0.0448, 0.0535, 0.0626, 0.0713,
           0.0884, 0.1057, 0.1225, 0.1392, 0.1691, 0.2013, 0.2348, 0.2670,
           0.3307, 0.3951, 0.4573, 0.5196, 0.6316, 0.7528, 0.8787, 1.0000]

SEG_RE = re.compile(r'^SEG ([0-9A-F]{2}) (\S+)(.*)$')
W_RE = re.compile(r'^\s+W ([0-9A-F]{2}) ([0-9A-F]{2})$')
T_RE = re.compile(r'^\s+T art=([0-9A-F]{6})$')
END_RE = re.compile(r'^\s+ENDSEG art=([0-9A-F]{6}) bio=([0-9A-F]{4})$')
KV_RE = re.compile(r'(\w+)=([^\s]+)')


def fm_hz(fnum, block, multi):
    return (fnum << block) / FM_PHASE_DIV * MULTI[multi] \
        * (FM_CLK / FM_RATE_DIV) / (2 ** 20)


def fm_tl_db(tl):
    return -tl * FM_TL_DB


def ssg_hz(tp):
    return (FM_CLK / SSG_DIV) / tp


def ssg_db(level):
    return 20 * math.log10(SSG_LUT[(level << 1) | 1]) if level else -999.0


def drum_db(il, tl):
    vol = 94 - il - tl
    if il + tl < 32 or vol > 62:
        return -999.0
    return 20 * math.log10((15 - (vol & 7)) / 2.0 ** (1 + (vol >> 3)) / 7.5)


class Fail(Exception):
    pass


def parse(text):
    """-> list of segments: dict(idx, cls, label, kv, writes, hits, art, bio)"""
    segs = []
    cur = None
    state = None
    for line in text.splitlines():
        if line.startswith('BEGIN:SEGMENTS'):
            state = 'segments'
            continue
        if line.startswith('BEGIN:RESTORE'):
            state = 'restore'
            continue
        if state != 'segments':
            continue
        m = SEG_RE.match(line)
        if m:
            cur = {'idx': int(m.group(1), 16), 'cls': m.group(2).strip(),
                   'kv': dict(KV_RE.findall(m.group(3))), 'writes': [],
                   'hits': [], 'art': None, 'bio': None}
            segs.append(cur)
            continue
        if cur is None:
            continue
        m = W_RE.match(line)
        if m:
            cur['writes'].append((int(m.group(1), 16), int(m.group(2), 16)))
            continue
        m = T_RE.match(line)
        if m:
            cur['hits'].append(int(m.group(1), 16))
            continue
        m = END_RE.match(line)
        if m:
            cur['art'] = int(m.group(1), 16)
            cur['bio'] = int(m.group(2), 16)
            continue
    return segs


SEG_GAP_S = 0.5            # the written silence at the END of most segments
DRUM_SETTLE_S = 0.001      # the key-off -> key-on settle per drum hit


def expected_s(seg):
    """The segment's DESIGNED duration in seconds, as the ENDSEG delta measures
    it: the hold PLUS the 0.5 s silence gap for every class except the marker
    (which has no gap - its tail is inside its own 1 s wait).  This is the line
    operators quote, so it is computed, not asserted by hand."""
    cls, kv = seg['cls'], seg['kv']
    if cls == 'MARK':
        return 0.100 + 0.150 + 0.100 + 1.000
    if 'hold' in kv:
        return float(kv['hold'].rstrip('s')) + SEG_GAP_S
    if cls == 'QL':
        # the pair is a 0.9 s hit spacing then a 0.6 s tail: NOT hits x spacing,
        # even though the header also carries hits=/spacing= for the kit
        return DRUM_SETTLE_S + 0.900 + DRUM_SETTLE_S + 0.600 + SEG_GAP_S
    if 'hits' in kv and 'spacing' in kv:
        # each hit: its settle then the spacing wait; then the gap
        return int(kv['hits']) * (DRUM_SETTLE_S + float(kv['spacing'].rstrip('s'))) \
            + SEG_GAP_S
    return None


def check_duration(seg, errors, tol_s):
    if seg['art'] is None:
        return
    got = seg['art'] / ARTIC_HZ
    want = expected_s(seg)
    if want is None:
        return
    if abs(got - want) > tol_s:
        errors.append('SEG %02X: measured %.3f s, designed %.3f s (hold+gap) - '
                      'the pacing clock or a register program took a different '
                      'time than the design (tol %.3f s)'
                      % (seg['idx'], got, want, tol_s))


def check(seg, errors):
    """recompute the header fields from the actual writes; raise on mismatch"""
    idx, cls, kv = seg['idx'], seg['cls'], seg['kv']
    regs = {}
    for sel, dat in seg['writes']:
        regs[sel] = dat
    if 'hits' in kv and len(seg['hits']) != int(kv['hits']):
        errors.append('SEG %02X: %d drum hits logged, header says %s'
                      % (idx, len(seg['hits']), kv.get('hits')))
    if seg['art'] is None:
        errors.append('SEG %02X: no ENDSEG line' % idx)

    if cls == 'FM' or 'blk' in kv:
        blk = int(kv['blk'])
        fnum = int(kv['fnum'], 16)
        mul = int(kv['mul'])
        want = fm_hz(fnum, blk, mul)
        # the register pair the write log holds must encode (blk, fnum)
        enc = ((regs.get(0xA4, 0) & 7) << 8) | regs.get(0xA0, 0)
        if enc != fnum:
            errors.append('SEG %02X: log encodes fnum 0x%03X, header says 0x%03X'
                          % (idx, enc, fnum))
        if (regs.get(0xA4, 0) >> 3) != blk:
            errors.append('SEG %02X: log encodes block %d, header says %d'
                          % (idx, regs.get(0xA4, 0) >> 3, blk))
        # the MULTI the log holds must be the header's
        if (regs.get(0x30, 0) & 0x0F) != mul:
            errors.append('SEG %02X: log MULTI %d, header says %d'
                          % (idx, regs.get(0x30, 0) & 0x0F, mul))
        # the tuned frequency, from the log's encoding
        got = fm_hz(enc, blk, regs.get(0x30, 0) & 0x0F)
        if abs(20 * math.log10(got / float(kv['freq'].rstrip('Hz')))) > 0.001:
            errors.append('SEG %02X: freq %s Hz, recomputed %.3f Hz'
                          % (idx, kv['freq'], got))
        tl = int(kv['tl'], 16)
        if regs.get(0x40) != tl:
            errors.append('SEG %02X: log TL 0x%02X, header says 0x%02X'
                          % (idx, regs.get(0x40, -1), tl))
        want_db = fm_tl_db(tl)
        if abs(want_db - float(kv['atten'].rstrip('dB'))) > 0.02:
            errors.append('SEG %02X: atten %s, law says %.3f'
                          % (idx, kv['atten'], want_db))

    if cls == 'SSG' or cls == 'SSWP' or cls == 'MARK':
        tp = int(kv['tp'], 16)
        log_tp = regs.get(0x00, 0) | ((regs.get(0x01, 0) & 0x0F) << 8)
        if log_tp != tp:
            errors.append('SEG %02X: log tone period 0x%03X, header says 0x%03X'
                          % (idx, log_tp, tp))
        got = ssg_hz(log_tp)
        if abs(20 * math.log10(got / float(kv['freq'].rstrip('Hz')))) > 0.001:
            errors.append('SEG %02X: freq %s, recomputed %.3f' % (idx, kv['freq'], got))
        if 'vol' in kv:
            vol = int(kv['vol'])
            if (regs.get(0x08, 0) & 0x0F) != vol:
                errors.append('SEG %02X: log volume %d, header says %d'
                              % (idx, regs.get(0x08, 0) & 0x0F, vol))
            if 'lvl' in kv:
                want_db = ssg_db(vol)
                if abs(want_db - float(kv['lvl'].rstrip('dB'))) > 0.02:
                    errors.append('SEG %02X: lvl %s, die table says %.2f'
                                  % (idx, kv['lvl'], want_db))

    if cls == 'QL':
        tl = int(kv['fm_tl'], 16)
        vol = int(kv['ssg_vol'])
        il = int(kv['drum_il'], 16)
        if regs.get(0x40) != tl:
            errors.append('SEG %02X: log FM TL 0x%02X, header says 0x%02X'
                          % (idx, regs.get(0x40, -1), tl))
        if abs(fm_tl_db(tl) - float(kv['fm_att'].rstrip('dB'))) > 0.02:
            errors.append('SEG %02X: fm_att %s, law says %.2f' % (idx, kv['fm_att'], fm_tl_db(tl)))
        if (regs.get(0x08, 0) & 0x0F) != vol:
            errors.append('SEG %02X: log SSG volume %d, header says %d'
                          % (idx, regs.get(0x08, 0) & 0x0F, vol))
        if abs(ssg_db(vol) - float(kv['ssg'].rstrip('dB'))) > 0.02:
            errors.append('SEG %02X: ssg %s, die table says %.2f' % (idx, kv['ssg'], ssg_db(vol)))
        for r in range(0x18, 0x1E):
            got = regs.get(r)
            if got is None or (got & 0x1F) != il or (got & 0xC0) != 0xC0:
                errors.append('SEG %02X: reg 0x%02X = %s, header says IL 0x%02X pan both'
                              % (idx, r, got, il))
        if abs(drum_db(il, 0x3F) - float(kv['drum'].rstrip('dB'))) > 0.02:
            errors.append('SEG %02X: drum %s, law says %.2f'
                          % (idx, kv['drum'], drum_db(il, 0x3F)))
        # the FM key-on and the SSG mixer-on must both be in the log
        if (0x28, 0xF0) not in seg['writes']:
            errors.append('SEG %02X: no FM key-on (0x28 <- F0)' % idx)
        if (0x07, 0xBE) not in seg['writes']:
            errors.append('SEG %02X: no SSG tone-A mixer-on (0x07 <- BE)' % idx)

    if cls == 'DRUM':
        il = int(kv['il'], 16)
        tl = int(kv['tl'], 16)
        if regs.get(0x11) != tl:
            errors.append('SEG %02X: log rhythm TL 0x%02X, header says 0x%02X'
                          % (idx, regs.get(0x11, -1), tl))
        for r in range(0x18, 0x1E):
            got = regs.get(r)
            if got is None or (got & 0x1F) != il or (got & 0xC0) != 0xC0:
                errors.append('SEG %02X: reg 0x%02X = %s, header says IL 0x%02X '
                              'pan both' % (idx, r, got, il))
        want_db = drum_db(il, tl)
        if abs(want_db - float(kv['gain'].rstrip('dB'))) > 0.02:
            errors.append('SEG %02X: gain %s, law says %.2f' % (idx, kv['gain'], want_db))
        # the key-on writes must be exactly the header's drum mask
        mask = 0
        for sel, dat in seg['writes']:
            if sel == 0x10 and not (dat & 0x80):
                mask |= dat
        if 'full-kit' in kv.get('label', ''):
            want_mask = 0x3F
        elif 'hot-triple' in kv.get('label', ''):
            want_mask = 0x13
        else:
            want_mask = None
        if want_mask is not None and mask != want_mask:
            errors.append('SEG %02X: key-on mask 0x%02X, expected 0x%02X'
                          % (idx, mask, want_mask))
    return


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('transcript')
    ap.add_argument('--csv', help='write the segment table here')
    ap.add_argument('--wav', help='split this recording by the segment table')
    ap.add_argument('--wav-outdir', default='.')
    ap.add_argument('--quiet', action='store_true')
    ap.add_argument('--no-pacing', action='store_true',
                    help='skip the ARTIC duration/ratio checks: use ONLY for the '
                         'emulator fixture, whose clock is a model (one tick per '
                         'three instructions) and whose absolute durations are '
                         'therefore not trustworthy. A real capture MUST be '
                         'checked with pacing on (the default).')
    ap.add_argument('--dur-tol', type=float, default=0.05,
                    help='per-segment duration tolerance in seconds (default '
                         '0.05: the register program and the DOS write log run '
                         'inside the delta, bounded by the printed residual)')
    args = ap.parse_args()

    text = open(args.transcript, 'r', errors='replace').read()
    segs = parse(text)
    if not segs:
        raise Fail('no SEGMENTS section found (is this an SNDTEST transcript?)')
    errors = []
    check_order = [s['idx'] for s in segs]
    if check_order != sorted(check_order) or len(set(check_order)) != len(check_order):
        errors.append('segment indices are not 00..%02X in order: %s'
                      % (len(segs) - 1, check_order))
    if len(segs) != 45:
        errors.append('expected 45 segments, found %d' % len(segs))
    for s in segs:
        try:
            check(s, errors)
            if not args.no_pacing:
                check_duration(s, errors, args.dur_tol)
        except Exception as e:                       # noqa: BLE001 - report, keep going
            errors.append('SEG %02X: checker error: %s' % (s['idx'], e))

    # ARTIC vs BIOS-tick consistency.  The probe paces on ARTIC and prints the
    # BIOS tick only as a cross-check, so this asserts no absolute rate: it
    # checks that art/bio is CONSTANT across segments (the two counters track
    # the same clock) and reports the implied tick period for the reader.
    ratios = [(s['idx'], s['art'] / s['bio']) for s in segs
              if s.get('bio') and s.get('art')]
    if args.no_pacing:
        ratios = []
        worst = max((abs(s['art'] / ARTIC_HZ - expected_s(s)), s['idx'])
                    for s in segs if s['art'] is not None and expected_s(s))
        print('pacing: SKIPPED (--no-pacing; the emulator fixture clock is a '
              'model - worst segment %02X is %.3f s off its design)'
              % (worst[1], worst[0]))
        print('BIOS tick: SKIPPED (--no-pacing)')
        return 1 if errors else 0
    bio_note = 'BIOS tick: not usable (a zero delta in this capture)'
    if ratios and len(ratios) == len(segs):
        vals = sorted(r[1] for r in ratios)
        med = vals[len(vals) // 2]
        spread = (vals[-1] - vals[0]) / med
        bio_note = ('BIOS tick cross-check: art/bio median %.0f ticks (implied '
                    'tick period %.2f ms), spread %.1f%% over %d segments'
                    % (med, med / ARTIC_HZ * 1000.0, spread * 100.0, len(ratios)))
        if spread > 0.20:
            errors.append('ARTIC/BIOS-tick ratio is NOT constant (%.1f%% spread '
                          'over %d segments): the two clocks disagree, so one of '
                          'them is not the device clock it is documented as'
                          % (spread * 100.0, len(ratios)))
    elif ratios:
        bio_note = ('BIOS tick cross-check: only %d/%d segments carry a nonzero '
                    'bio delta, so it is reported, not checked'
                    % (len(ratios), len(segs)))

    # the segment table: offsets accumulate the measured ARTIC deltas
    rows = []
    off = 0
    for s in segs:
        kv, cls = s['kv'], s['cls']
        freq = kv.get('freq', '')
        level = kv.get('atten', kv.get('lvl', kv.get('gain', '')))
        dur_ms = (s['art'] or 0) / ARTIC_HZ * 1000.0
        rows.append((s['idx'], cls, kv.get('label', ''), freq, level,
                     off / ARTIC_HZ * 1000.0, dur_ms,
                     ','.join('%02X%02X' % w for w in s['writes'])))
        off += (s['art'] or 0)

    if not args.quiet:
        print('%-4s %-5s %-34s %-12s %-9s %9s %9s' %
              ('seg', 'class', 'label', 'freq', 'level', 't0_ms', 'dur_ms'))
        for r in rows:
            print('%02X   %-5s %-34s %-12s %-9s %9.1f %9.1f' %
                  (r[0], r[1], r[2], r[3], r[4], r[5], r[6]))
        print('%d segments, total %.1f s' % (len(rows), off / ARTIC_HZ))
        print(bio_note)
        worst = max((abs(s['art'] / ARTIC_HZ - expected_s(s)), s['idx'])
                    for s in segs if s['art'] is not None and expected_s(s))
        print('pacing: worst segment is %02X, %.3f s off its designed hold+gap '
              '(tolerance %.3f s)' % (worst[1], worst[0], args.dur_tol))
        if errors:
            print('\n%d CHECK FAILURE(S):' % len(errors))
            for e in errors:
                print('  ' + e)
        else:
            print('\nall %d segments: header <-> write log <-> reference law agree'
                  % len(rows))

    if args.csv:
        with open(args.csv, 'w') as f:
            f.write('seg,class,label,freq_hz,level_db,t0_ms,dur_ms,writes\n')
            for r in rows:
                f.write('%02X,%s,%s,%s,%s,%.1f,%.1f,%s\n' % r)

    if args.wav:
        split_wav(args.wav, rows, args.wav_outdir)

    return 1 if errors else 0


def split_wav(path, rows, outdir):
    """One WAV per segment. Needs only the standard library; the manifest's
    offsets are ARTIC-based, so an exact clock match is not required (the probe
    and the recorder share the machine's own time)."""
    import wave
    w = wave.open(path, 'rb')
    params = w.getparams()
    rate = w.getframerate()
    n = w.getnframes()
    data = w.readframes(n)
    w.close()
    sampwidth = params.sampwidth
    channels = params.nchannels
    frame = sampwidth * channels
    for r in rows:
        start = int(r[5] / 1000.0 * rate) * frame
        end = min(len(data), start + int(r[6] / 1000.0 * rate) * frame)
        out = '%s/seg%02X_%s.wav' % (outdir, r[0], r[1])
        with wave.open(out, 'wb') as o:
            o.setparams(params)
            o.writeframes(data[start:end])
    print('wrote %d segment WAVs to %s' % (len(rows), outdir))


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Fail as e:
        sys.stderr.write('FAIL: %s\n' % e)
        sys.exit(2)

#!/usr/bin/env python3
"""rwipe_decode.py - tabulate RWIPE.TXT (tools/hwprobe/rwipe/rwipe.s) runs.

    rwipe_decode.py RWIPE.TXT [--steps] [--events] [--compare OTHER.TXT]

Per run: the CLABLOGO bracket (EXEC), its phases (start -> AH=41h mode set -> wipe start, the
wipe, the wipe end -> exit), the wipe in ms and per step (fill / rows / GRCG-off+flip, medians),
the interrupt time inside the wipe per vector, the INT 60h/64h calls (music start, the PPS voice)
relative to the program start, the dec/jnz loop (ns per iteration) and the frame period.
All times come from the ARTIC counter (307200 Hz, 24-bit).

/P rows (OP.COM run to its music stop): OP.COM's milestones in ms from its EXEC (its first logged
DOS call, the CHDIR loop, the critical errors, the mode set, each file open, the CG glyph upload
bracketed by INT 18h AH=0Dh..0Ch, the music stop INT 60h AH=01h and the PPS stop INT 64h AH=00h),
the disk BIOS calls by drive, and, when the row also holds the logo's voice start (INT 64h
AH=01h), the voice played = its stop - its start (at most the sample's 2.712 s).
"""
from __future__ import annotations

import argparse
import re
import statistics
import sys

HZ = 307200.0
CLS = {1: 'I18', 2: 'PATCH', 3: 'NOMATCH', 4: 'I60', 5: 'I64', 6: 'S60', 7: 'S64', 8: 'EXEC',
       9: 'EXIT', 10: 'STOP', 0x0B: 'OPPATCH', 0x0C: 'OPNOMATCH', 0x0D: 'OPEXIT', 0x0E: 'D21',
       0x0F: 'R21', 0x10: 'R21C', 0x11: 'D1B', 0x12: 'R1B', 0x13: 'R1BC', 0x14: 'I24'}
# the PPS voice: 10892 bytes of 4-bit samples at 34650/306 Hz (PDR.COM's divisor) = 2.712 s
VOICE_S = 21784 / 8031.4


def d24(a: int, b: int) -> int:
    return (b - a) & 0xFFFFFF


def ms(t: float) -> float:
    return t * 1000.0 / HZ


def parse(path: str) -> list[dict]:
    runs, cur = [], None
    for ln in open(path, 'rb').read().decode('latin-1').splitlines():
        if not ln.startswith('RWIPE '):
            continue
        f = ln.split()
        kv = dict(x.split('=', 1) for x in f[2:] if '=' in x)
        k = f[1]
        if k == 'BEGIN':
            cur = {'kv': kv, 'ev': [], 'steps': [], 'isr': []}
            runs.append(cur)
        elif cur is None:
            continue
        elif k == 'EV':
            cur['ev'].append(kv)
        elif k == 'STEP':
            cur['steps'].append({x: int(kv[x], 16) for x in 'SFRE'} | {'I': int(kv['I'])})
        elif k == 'ISR':
            cur['isr'].append(kv)
        elif k == 'VEC':
            cur['vec'] = ln
        else:
            cur[k] = kv
    return runs


def summary(r: dict) -> dict:
    out = {'tag': r['kv'].get('TAG', '?'), 'opt': r['kv'].get('OPT', '')}
    cal = r.get('CAL', {})
    if cal.get('LOOP1M'):
        out['loop_ns'] = int(cal['LOOP1M']) / HZ * 1e9 / 1e6
    if cal.get('FRAME30') and int(cal['FRAME30']):
        out['frame_ms'] = ms(int(cal['FRAME30'])) / 30
    out['free'] = r.get('ENV', {}).get('FREE')
    out['p31'] = r.get('ENV', {}).get('P31')
    ex = r.get('EXEC', {})
    t0 = int(ex.get('T0', '0'), 16)
    t1 = int(ex.get('T1', '0'), 16)
    # the logo program's own bracket: EXEC..EXIT events in /B, the wrapper's EXEC otherwise
    evs = [(int(e['T'], 16), CLS.get(int(e['CLS'], 16), e['CLS']), int(e['AX'], 16), e.get('NAME', ''))
           for e in r['ev']]
    c0, c1 = t0, t1
    for t, c, ax, nm in evs:
        if c == 'EXEC' and nm.startswith('CLABLOGO'):
            c0 = t
        if c == 'EXIT':
            c1 = t
    out['clab_ms'] = ms(d24(c0, c1))
    out['exec_ms'] = ms(d24(t0, t1))
    first41 = next((t for t, c, ax, nm in evs if c == 'I18' and ax >> 8 == 0x41), None)
    out['events'] = [(ms(d24(c0, t)), c, ax, nm) for t, c, ax, nm in evs]
    w = r.get('WIPE')
    if w:
        w0, w1 = int(w['T0'], 16), int(w['T1'], 16)
        out['wipe_ms'] = ms(d24(w0, w1))
        out['pre_ms'] = ms(d24(c0, w0))
        out['post_ms'] = ms(d24(w1, c1))
        if first41 is not None:
            out['start_to_41_ms'] = ms(d24(c0, first41))
            out['41_to_wipe_ms'] = ms(d24(first41, w0))
        st = r['steps']
        out['fill'] = [ms(d24(s['S'], s['F'])) for s in st]
        out['rows'] = [ms(d24(s['F'], s['R'])) for s in st]
        out['flip'] = [ms(d24(s['R'], s['E'])) for s in st]
        out['step'] = [ms(d24(s['S'], s['E'])) for s in st]
        out['flags'] = w.get('FLAGS')
        out['imr'] = w.get('IMR')
        isr = []
        for i in r['isr']:
            isr.append((i['V'], int(i['N']), ms(int(i['TICKS']))))
        out['isr'] = isr
    out['op'] = op_summary(evs, r.get('OP', {}))
    out['patch'] = r.get('PATCH', {}).get('ST')
    out['boot'] = r.get('BOOT', {})
    out['music'] = r.get('MUSIC', {})
    return out


def op_summary(evs: list, oprow: dict) -> dict | None:
    """OP.COM's milestones (/P): ms from its EXEC; the voice start/stop when present."""
    i0 = next((i for i, (t, c, ax, nm) in enumerate(evs) if c == 'EXEC' and nm == 'OP'), None)
    if i0 is None or oprow.get('SEEN') != '01':
        return None
    t0 = evs[i0][0]
    rel = lambda t: ms(d24(t0, t))
    o = {'patch': oprow.get('PATCH'), 'n1b': int(oprow.get('N1B', 0)), 't1b_ms': ms(int(oprow.get('T1B', 0))),
         'n24': int(oprow.get('N24', 0)), 'mile': []}
    op = evs[i0 + 1:]
    end = next((k for k, e in enumerate(op) if e[1] in ('OPEXIT', 'STOP')), len(op))
    op = op[:end + 1]
    m = o['mile']
    first = next((e for e in op if e[1] == 'D21'), None)
    if first:
        m.append(('first DOS call', rel(first[0]), f'AH={first[2] >> 8:02X}'))
    # CHDIR calls and their returns (the next R21/R21C after each)
    cds = []
    for k, e in enumerate(op):
        if e[1] == 'D21' and e[2] >> 8 == 0x3B:
            r = next((x for x in op[k + 1:] if x[1] in ('R21', 'R21C')), None)
            cds.append((e, r))
    if cds:
        ok = ''.join(chr(e[2] & 0xFF) for e, r in cds if r and r[1] == 'R21')
        t_end = cds[-1][1][0] if cds[-1][1] else cds[-1][0][0]
        m.append((f'CHDIR loop {len(cds)}x ({chr(cds[0][0][2] & 0xFF)}..{chr(cds[-1][0][2] & 0xFF)}, '
                  f'{"ok " + ok if ok else "all failed"})', rel(cds[0][0][0]),
                  f'{ms(d24(cds[0][0][0], t_end)):.1f} ms'))
        o['chdir_ms'] = ms(d24(cds[0][0][0], t_end))
    for t, c, ax, nm in op:
        h = ax >> 8
        if c == 'I24':
            m.append(('critical error', rel(t), f'AX={ax:04X}'))
        elif c == 'I18' and h in (0x41, 0x42, 0x40, 0x0C, 0x0D):
            m.append(({0x41: 'INT 18h 41h graphics off', 0x42: 'INT 18h 42h mode', 0x40: 'INT 18h 40h graphics on',
                       0x0D: 'INT 18h 0Dh text off (CG upload starts)', 0x0C: 'INT 18h 0Ch text on'}[h], rel(t), ''))
        elif c == 'D21' and h == 0x3D:
            m.append((f'open {nm}', rel(t), ''))
        elif c == 'D21' and h == 0x3E:
            m.append(('close', rel(t), ''))
        elif c == 'I60' and h == 0x01:
            m.append(('INT 60h 01h music stop', rel(t), ''))
        elif c == 'S60' and h == 0x09:
            m.append(('INT 60h 09h driver check (stubbed: no driver, the stop is skipped)', rel(t), ''))
        elif c == 'I64' and h == 0x00:
            m.append(('INT 64h 00h PPS stop', rel(t), f'AX={ax:04X}'))
        elif c == 'D21' and h == 0x4C:
            m.append(('exit', rel(t), f'AL={ax & 0xFF:02X}'))
        elif c in ('OPPATCH', 'OPNOMATCH'):
            m.append((c, rel(t), ''))
    cg0 = next((t for t, c, ax, nm in op if c == 'I18' and ax >> 8 == 0x0D), None)
    cg1 = next((t for t, c, ax, nm in op if c == 'I18' and ax >> 8 == 0x0C), None)
    if cg0 is not None and cg1 is not None:
        o['cg_ms'] = ms(d24(cg0, cg1))
    stop = next((t for t, c, ax, nm in op if c == 'I60' and ax >> 8 == 0x01), None)
    if stop is None:   # /S: the driver check (INT 60h AH=09h, answered 'absent') is the stop's place
        stop = next((t for t, c, ax, nm in op if c == 'S60' and ax >> 8 == 0x09), None)
    if stop is not None:
        o['stop_ms'] = rel(stop)
    # disk BIOS calls by DA/UA: entry D1B, the next R1B/R1BC is its return
    disk, pend = {}, None
    for t, c, ax, nm in op:
        if c == 'D1B':
            pend = (t, ax)
        elif c in ('R1B', 'R1BC') and pend:
            d = disk.setdefault(pend[1] & 0xFF, [0, 0.0, 0])
            d[0] += 1
            d[1] += ms(d24(pend[0], t))
            d[2] += c == 'R1BC'
            pend = None
    o['disk'] = disk
    vs = next((t for t, c, ax, nm in evs[:i0] if c == 'I64' and ax >> 8 == 0x01), None)
    if vs is not None:
        vstop = next((t for t, c, ax, nm in op if c == 'I64' and ax >> 8 == 0x00), None)
        o['voice_start_to_op_ms'] = ms(d24(vs, t0))
        if vstop is not None:
            o['voice_stop_ms'] = rel(vstop)
            o['voice_ms'] = min(ms(d24(vs, vstop)), VOICE_S * 1000)
            o['voice_cut'] = ms(d24(vs, vstop)) < VOICE_S * 1000
    return o


def show_op(s: dict, events: bool) -> None:
    o = s.get('op')
    if not o:
        return
    line = f"  {s['tag']} OP.COM: patch={o['patch']}"
    if 'stop_ms' in o:
        line += f", EXEC -> music stop {o['stop_ms']:.1f} ms"
    if 'cg_ms' in o:
        line += f", CG upload {o['cg_ms']:.1f} ms"
    if 'chdir_ms' in o:
        line += f", CHDIR loop {o['chdir_ms']:.1f} ms"
    line += f", disk BIOS {o['n1b']} calls {o['t1b_ms']:.1f} ms, critical errors {o['n24']}"
    print(line)
    if 'voice_ms' in o:
        print(f"  {s['tag']} VOICE: start -> OP.COM EXEC {o['voice_start_to_op_ms']:.1f} ms, + EXEC -> PPS stop "
              f"{o['voice_stop_ms']:.1f} ms = played {o['voice_ms'] / 1000:.3f} s of {VOICE_S:.3f} s"
              f"{' (cut)' if o['voice_cut'] else ' (complete)'}")
    if o['disk']:
        print('    disk ' + ', '.join(f'DA/UA {k:02X}: {v[0]}x {v[1]:.1f} ms{f" ({v[2]} errors)" if v[2] else ""}'
                                   for k, v in sorted(o['disk'].items())))
    if events:
        for name, t, x in o['mile']:
            print(f'    {t:8.1f} ms  {name} {x}')


def show(path: str, steps: bool, events: bool = False) -> list[dict]:
    rs = [summary(r) for r in parse(path)]
    print(f'== {path}')
    print(f"{'tag':6} {'opt':5} {'patch':5} {'logo ms':>8} {'pre':>7} {'wipe ms':>8} {'ms/step':>7} "
          f"{'fill':>6} {'rows':>6} {'flip':>5} {'isr ms':>7} {'post':>8} {'loop ns':>7} {'frame':>6} free")
    for s in rs:
        if 'wipe_ms' in s:
            isr_ms = sum(x[2] for x in s['isr'])
            print(f"{s['tag']:6} {s['opt']:5} {s['patch'] or '-':5} {s['clab_ms']:8.1f} {s['pre_ms']:7.1f} "
                  f"{s['wipe_ms']:8.1f} {statistics.median(s['step']):7.3f} {statistics.median(s['fill']):6.3f} "
                  f"{statistics.median(s['rows']):6.3f} {statistics.median(s['flip']):5.3f} {isr_ms:7.2f} "
                  f"{s['post_ms']:8.1f} {s.get('loop_ns', 0):7.2f} {s.get('frame_ms', 0):6.3f} {s['free']}")
        else:
            print(f"{s['tag']:6} {s['opt']:5} {s['patch'] or '-':5} {s['clab_ms']:8.1f}   (no wipe stamps)"
                  f"{'':40} {s.get('loop_ns', 0):7.2f} {s.get('frame_ms', 0):6.3f} {s['free']}")
    for s in rs:
        extra = []
        if s.get('isr'):
            extra.append('isr ' + ' '.join(f'{v}:{n}/{t:.2f}ms' for v, n, t in s['isr']))
        if 'flags' in s:
            extra.append(f"wipe FLAGS={s['flags']} (IF={(int(s['flags'], 16) >> 9) & 1}) IMR={s['imr']}")
        if 'start_to_41_ms' in s:
            extra.append(f"start->AH41 {s['start_to_41_ms']:.1f} ms, AH41->wipe {s['41_to_wipe_ms']:.1f} ms")
        mus = [f'{c}:{ax:04X}@{t:.0f}ms' for t, c, ax, nm in s['events'] if c in ('I60', 'I64')]
        if mus:
            extra.append('calls ' + ' '.join(mus[:12]) + (' ...' if len(mus) > 12 else ''))
        ex = [f'{nm}@{t:.0f}' for t, c, ax, nm in s['events'] if c == 'EXEC']
        if ex:
            extra.append('exec ' + ' '.join(ex))
        if s['boot'].get('STOP') == '01' or s['boot'].get('NOMEM') == '01':
            extra.append('boot ' + ' '.join(f'{k}={v}' for k, v in s['boot'].items()))
        print(f"  {s['tag']}: " + '; '.join(extra))
        show_op(s, events)
        if steps and 'step' in s:
            for i in range(len(s['step'])):
                print(f"    step {i + 1:2d} {s['step'][i]:.3f} fill {s['fill'][i]:.3f} rows {s['rows'][i]:.3f} "
                      f"flip {s['flip'][i]:.3f}")
    return rs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('log')
    ap.add_argument('--steps', action='store_true')
    ap.add_argument('--events', action='store_true', help='list OP.COM milestones')
    ap.add_argument('--compare')
    a = ap.parse_args()
    ra = show(a.log, a.steps, a.events)
    if a.compare:
        rb = show(a.compare, a.steps, a.events)
        print('== B / A (wipe ms, by tag)')
        bt = {s['tag']: s for s in rb}
        for s in ra:
            o = bt.get(s['tag'])
            if o and 'wipe_ms' in s and 'wipe_ms' in o:
                print(f"{s['tag']:6} A {s['wipe_ms']:8.1f}  B {o['wipe_ms']:8.1f}  B/A {o['wipe_ms'] / s['wipe_ms']:.2f}")
    return 0


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Parse a Quartus report_timing -detail path_only/full_path .rpt into per-path chains.

usage: pathchain.py RPT [--top N] [--sig] [--show K]
  --sig   : group paths by their module-hop signature (sequence of distinct modules along the
            data path) and print count / worst slack / mean levels per signature
  --show K: print the node chain of path K (1-based)
"""
import re, sys, collections, argparse

def short(n):
    n = n.replace('emu|core|', '').replace('emu:emu|pc9821_system:core|', '')
    return n

def modof(el):
    el = short(el)
    el = re.sub(r'\|(combout|cout|sumout|q|d|data[a-f]|cin|shareout|sharein|portadataout\[\d+\]|portb?[a-z_]*address[a-z_]*\d*|port[ab][a-z_]*\d*)$', '', el)
    parts = el.split('|')
    parts = [p.split(':')[-1] for p in parts]
    return '/'.join(parts[:-1]) if len(parts) > 1 else parts[0]

def parse(fn):
    t = open(fn, errors='replace').read()
    paths = []
    for k, blk in enumerate(re.split(r'\nPath #\d+: ', t)[1:], 1):
        try:
            paths.append(parse_block(blk))
        except (AttributeError, IndexError, ValueError) as e:
            raise SystemExit(f"pathchain: {fn}: path #{k} is not a report_timing -detail "
                             f"path_only/full_path setup block ({e})")
    return paths


def parse_block(blk):
    """One `Path #N:` block -> its path dict; a missing field raises."""
    m = re.match(r'Setup slack is (-?[\d.]+)', blk)
    slack = float(m.group(1))
    lv = re.search(r'Number of Logic Levels\s*;\s*;\s*(\d+)', blk)
    ic = re.search(r';\s+IC\s+;\s*;\s*(\d+)\s*;\s*([\d.]+)', blk)
    cell = re.search(r';\s+Cell\s+;\s*;\s*(\d+)\s*;\s*([\d.]+)', blk)
    dd = re.search(r'; Data Delay\s+;\s*(-?[\d.]+)', blk)
    sk = re.search(r'; Clock Skew\s+;\s*(-?[\d.]+)', blk)
    arr = blk.split('; Data Arrival Path')[1].split('; Data Required Path')[0]
    rows = re.findall(r'^;\s+([\d.]+)\s+;\s+(-?[\d.]+)\s+;\s*(\w*)\s*;\s*(\w*)\s*;\s*(\d*)\s*;\s*(\S*)\s*;\s*(\S+)\s*;', arr, re.M)
    chain = [(float(a), float(b), ty, fo, loc, el) for a, b, rf, ty, fo, loc, el in rows if ty in ('CELL', 'IC', 'uTco')]
    frm = re.search(r'; From Node\s+;\s*(\S+)', blk).group(1)
    to = re.search(r'; To Node\s+;\s*(\S+)', blk).group(1)
    return dict(slack=slack, levels=int(lv.group(1)) if lv else -1,
                ic=float(ic.group(2)) if ic else 0, cell=float(cell.group(2)) if cell else 0,
                dd=float(dd.group(1)) if dd else 0, skew=float(sk.group(1)) if sk else 0,
                chain=chain, frm=frm, to=to)

def sig(p):
    mods = []
    for _, _, ty, fo, loc, el in p['chain']:
        if ty != 'CELL':
            continue
        m = modof(el)
        # collapse to two trailing components
        m = '/'.join(m.split('/')[-2:])
        if not mods or mods[-1] != m:
            mods.append(m)
    return tuple(mods)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rpt'); ap.add_argument('--sig', action='store_true'); ap.add_argument('--show', type=int, default=0)
    ap.add_argument('--top', type=int, default=0)
    a = ap.parse_args()
    ps = parse(a.rpt)
    if a.top: ps = ps[:a.top]
    print(f"{a.rpt}: {len(ps)} paths, worst {ps[0]['slack']}, slack@50 {ps[min(49,len(ps)-1)]['slack']}, @{len(ps)} (the last) {ps[-1]['slack']}")
    if a.sig:
        g = collections.OrderedDict()
        for p in ps:
            g.setdefault(sig(p), []).append(p)
        for s, L in sorted(g.items(), key=lambda kv: kv[1][0]['slack']):
            w = L[0]
            print(f"\n[{len(L):3d}] worst {w['slack']:.3f} lv {w['levels']} dd {w['dd']:.2f} ic {w['ic']:.2f} cell {w['cell']:.2f}")
            print('   ' + ' -> '.join(s))
    if a.show:
        p = ps[a.show - 1]
        print(f"slack {p['slack']} levels {p['levels']} dd {p['dd']} ic {p['ic']} cell {p['cell']} skew {p['skew']}")
        for tot, inc, ty, fo, loc, el in p['chain']:
            if ty == 'CELL':
                print(f"  {tot:7.3f} +{inc:5.3f} fo{fo:>3} {loc:22s} {short(el)}")
            else:
                print(f"  {'':7s} ic{inc:5.3f}")

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""tools/timing/census.py: classify every endpoint's worst clk_sys (general[0]) setup path into cones.

usage: census.py table    ENDS_RPT...        per fit: per cone worst slack, gap to WNS, endpoints <=0.3/<=1.0 ns
       census.py ladder   ENDS_RPT...        WNS as cone groups are removed in order (per fit + mean)
       census.py skew     ENDS_RPT...        clock skew by launch/latch domain (gated CPU clock vs platform)
       census.py show     ENDS_RPT CONE [K]  the K worst paths of a cone with the node chain
       census.py families CONE ENDS_RPT...   per fit, the 4 worst distinct endpoint families of a cone
       census.py md       ENDS_RPT...        the table as markdown (gap per fit, mean, limiter count)
       census.py warm     ENDS_RPT           parse one report into its cache and exit

A parsed report is cached beside it (ENDS_RPT.pkl), keyed on the report's mtime and on
pathchain.py's own text, so a parser change re-parses instead of serving old fields.

Cones (docs/timing.md describes them): C1-C7 are the CPU and platform cones of the earlier
split-clock path study; the families added since then:
  SP  the speculative-fetch attribute check (pf_spec_attr_ok / pf_spec_* -> icache request)
  S2  the SDRAM controller on clk_sys (sdram:ctrl - gk_wmap, rc_*_buf, a[], dq_out, the arbiter)
  TB  the throttle bridge and gate (pc9821_cpu_bus_bridge u_cpu_bridge, cpu_throttle, cpu_clk)
  CD  the ATAPI drive (pc9821_atapi)
  C4x the load-op result forwarded into the EX view (the C4 path at the overclocks: flag forward -> Add10 -> gpr_merge.ex_value -> ALU/shifter), named now
  D2  the VIPT TLB M10K -> vipt_hit -> vipt_load_ex_hit -> i_issue -> seg_cmd_target tier
  D2s the issue/stall decision (pb_issue, d2_ea_split_wait, pend_write_mask) into the segment unit
      (the residual CPU tier, its own rows)
  R1  ext_addr_r -> memory map -> mem_valid -> z_ready -> the CPU's fill/response (a round trip)
  V1  the CRTC raster from the guest's SYNC block (v_sync -> HACTIVE/htotal adders -> HS/VS flops)
  FD  the FDD media seek-offset arithmetic (rq_c -> seek_off -> img_left/foff)
  C7b the GVRAM arbiter / GRCG endpoints that are not the M10K itself (lane_live, gstate, ...)
  P0  (a LABEL, not a cone) the path starts at bus_unit ext_addr_r and crosses the memory map
S2/TB/CD take their own ENDPOINTS first (ENDPOINT_FIRST); otherwise the first match wins, in
the order below.
"""
import sys, re, collections, statistics as st
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import pathchain as pc

CONES = [
    ('C1 limit/seg_fault->req', r'seg_unit\|(size_fault|seg_fault)'),
    ('C2 fetch_limit_rem->prefetch', r'prefetch_inst\|(k1q_avail|LessThan0)|fetch_limit_rem|WideOr113'),
    ('C3 shifter size->GPR read', r'shifter_inst\|(use_captured_source|data_size)'),
    ('SP spec-fetch attr check', r'pf_spec|fast_pf_candidate|icache_req_spec_ok'),
    ('C4 flag/EA/ALU forward', r'eflags_fwd|gpr_merge\|(ea_value|pv3)|address_unit_inst\|ea_add'),
    ('C4x EX-view load-op forward', r'gpr_merge\|ex_value|load_wb_alu_result'),
    ('D2 VIPT hit/issue -> seg', r'vipt_hit|vipt_load_ex_hit|vipt_tlb'),
    ('D2s issue/stall decision', r'pb_issue|d2_ea_split_wait|i_issue|pend_write_mask'),
    ('C7 GVRAM M10K (mem0-3)', r'mem[0-3]_rtl'),
    ('C5 PEGC storebuf', r'u_storebuf'),
    ('R1 map -> z_ready -> CPU fill', r'z_ready'),
    ('S2 SDRAM ctrl (clk_sys)', r'sdram:ctrl|\|ctrl\|'),
    ('TB throttle bridge/gate', r'u_cpu_bridge|u_cpu_throttle|u_cpu_clk|cpu_pulse_hold'),
    ('CD ATAPI', r'atapi'),
    ('C7b GVRAM arb/GRCG', r'u_gvram_arb|u_grcg'),
    ('C6 GDC line base', r'u_gdc2'),
    ('V1 CRTC SYNC-block raster -> HS/VS', r'u_crtc'),
    ('FD FDD media seek offset', r'fdd_media'),
    ('ucode ROM / decoder', r'microcode_rom|decoder_inst'),
    ('other CPU', r'z486:cpu|cpu\|'),
    ('other platform', r'.'),
]
GROUP_ORDER = ['C5 PEGC storebuf', 'C7 GVRAM M10K (mem0-3)', 'C7b GVRAM arb/GRCG', 'R1 map -> z_ready -> CPU fill', 'V1 CRTC SYNC-block raster -> HS/VS',
               'FD FDD media seek offset', 'S2 SDRAM ctrl (clk_sys)',
               'C4 flag/EA/ALU forward', 'C4x EX-view load-op forward', 'D2 VIPT hit/issue -> seg',
               'D2s issue/stall decision', 'C1 limit/seg_fault->req', 'C3 shifter size->GPR read',
               'C2 fetch_limit_rem->prefetch', 'SP spec-fetch attr check', 'TB throttle bridge/gate',
               'C6 GDC line base', 'ucode ROM / decoder', 'CD ATAPI', 'other platform', 'other CPU']


def text(p):
    return p['frm'] + '|' + '|'.join(el for *_, el in p['chain']) + '|' + p['to']


ENDPOINT_FIRST = [  # a NEW block's own endpoints are its cone whatever the path crossed on the way
    ('S2 SDRAM ctrl (clk_sys)', r'sdram:ctrl'),
    ('TB throttle bridge/gate', r'u_cpu_bridge|u_cpu_throttle|u_cpu_clk'),
    ('CD ATAPI', r'atapi'),
]


def cone(p):
    for name, rx in ENDPOINT_FIRST:
        if re.search(rx, p['to']):
            return name
    s = text(p)
    for name, rx in CONES:
        if re.search(rx, s):
            return name


def is_p0(p):
    return 'bus_unit_inst|ext_addr_r' in p['frm'] and re.search(r'memory\|(mapper|bios_top|peg_high|eff_addr)', text(p))


def is_cpu(n):
    return '|z486:cpu|' in n


def label(fn):
    m = re.search(r'timing-census/([^/]+)/seed0*(\d+)/', fn)
    return f"{m.group(1)}-s{m.group(2)}" if m else fn


def parser_key():
    """The parser's identity: a cache written by another pathchain.py is stale."""
    import hashlib
    with open(pc.__file__, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


def load(fn):
    import os, pickle
    pk = fn + '.pkl'   # parse cache beside the (git-ignored) report
    ps, key = None, parser_key()
    if os.path.exists(pk) and os.path.getmtime(pk) > os.path.getmtime(fn):
        try:
            with open(pk, 'rb') as f:
                cached = pickle.load(f)
            if isinstance(cached, dict) and cached.get('parser') == key:
                ps = cached['paths']
        except (OSError, EOFError, pickle.UnpicklingError):
            ps = None
    if ps is None:
        ps = pc.parse(fn)
        try:
            with open(pk, 'wb') as f:
                pickle.dump({'parser': key, 'paths': ps}, f)
        except OSError:
            pass    # a read-only report directory: parse every time
    if not ps:
        raise SystemExit(f"census: {fn} holds no timing paths")
    for p in ps:
        p['cone'] = cone(p)
    return ps


def table(fns):
    agg = collections.defaultdict(list)
    for fn in fns:
        ps = load(fn); w = ps[0]['slack']
        best = {}; n03 = collections.Counter(); n10 = collections.Counter()
        p0_03 = sum(1 for p in ps if p['slack'] <= w + 0.3 and is_p0(p))
        p0_10 = sum(1 for p in ps if p['slack'] <= w + 1.0 and is_p0(p))
        for p in ps:
            c = p['cone']; best[c] = min(best.get(c, 99), p['slack'])
            if p['slack'] <= w + 0.3: n03[c] += 1
            if p['slack'] <= w + 1.0: n10[c] += 1
        print(f"\n{label(fn)}: WNS {w:.3f}  ({len(ps)} endpoints, last {ps[-1]['slack']:.3f}; P0 ext_addr_r->map label: {p0_03} <=0.3, {p0_10} <=1.0)")
        print(f"  {'cone':32s} {'worst':>8s} {'gap':>7s} {'<=0.3':>6s} {'<=1.0':>6s}")
        for c in GROUP_ORDER:
            if c in best:
                print(f"  {c:32s} {best[c]:8.3f} {best[c]-w:+7.3f} {n03[c]:6d} {n10[c]:6d}")
                agg[c].append(best[c] - w)
            else:
                print(f"  {c:32s} {'-':>8s} {'(>'+format(ps[-1]['slack']-w, '.1f')+')':>7s}")
    print("\nmean gap to WNS over fits (fits where the cone is among the report's endpoints):")
    for c in GROUP_ORDER:
        if agg[c]:
            L = agg[c]
            print(f"  {c:32s} mean {st.mean(L):+.3f}  min {min(L):+.3f}  limiter in {sum(1 for x in L if x == 0)}/{len(fns)}  n={len(L)}")


def ladder(fns):
    order = GROUP_ORDER[:-2]
    rows = collections.defaultdict(list)
    for fn in fns:
        ps = load(fn); w = ps[0]['slack']
        worst = {}
        for p in ps:
            worst[p['cone']] = min(worst.get(p['cone'], 99), p['slack'])
        print(f"\n{label(fn)}: WNS {w:.3f}")
        removed = set()
        for c in ['(none)'] + order:
            if c != '(none)':
                removed.add(c)
            rest = [v for k, v in worst.items() if k not in removed]
            nw = min(rest) if rest else ps[-1]['slack']
            nxt = min((k for k in worst if k not in removed), key=lambda k: worst[k], default='-')
            print(f"  - {c:32s} WNS {nw:8.3f} ({nw-w:+.3f})  next: {nxt}")
            rows[c].append(nw - w)
    print("\nmean gain over fits:")
    for c in ['(none)'] + order:
        print(f"  cumulative through {c:32s} {st.mean(rows[c]):+.3f}")


def skew(fns):
    for fn in fns:
        ps = load(fn); d = collections.defaultdict(list)
        for p in ps:
            d[(('cpu' if is_cpu(p['frm']) else 'plat'), ('cpu' if is_cpu(p['to']) else 'plat'))].append(p['skew'])
        print(f"\n{label(fn)}: clock skew by launch->latch domain (gated CPU clock = 'cpu')")
        for k, L in sorted(d.items()):
            print(f"  {k[0]:4s}->{k[1]:4s} n={len(L):5d} mean {st.mean(L):+.3f} min {min(L):+.3f} max {max(L):+.3f}")


def show(fn, cname, k):
    ps = [p for p in load(fn) if p['cone'].startswith(cname)]
    for p in ps[:k]:
        print(f"\nslack {p['slack']} lv {p['levels']} dd {p['dd']:.2f} ic {p['ic']:.2f} cell {p['cell']:.2f} skew {p['skew']}")
        print(f"  from {pc.short(p['frm'])}\n  to   {pc.short(p['to'])}")
        prev = None
        for tot, inc, ty, fo, loc, el in p['chain']:
            if ty == 'CELL':
                print(f"    {tot:7.3f} +{inc:5.3f} ic{prev:5.3f} fo{fo:>3} {loc:22s} {pc.short(el)}" if prev is not None else
                      f"    {tot:7.3f} +{inc:5.3f}        fo{fo:>3} {loc:22s} {pc.short(el)}")
            else:
                prev = inc


def brief(p, k=9):
    cells = [re.sub(r'\|(combout|cout|sumout|q)$', '', pc.short(el)).replace('cpu|', '')
             for _tot, _inc, ty, _fo, _loc, el in p['chain'] if ty == 'CELL']
    mid = [c.split('~')[0] for c in cells]
    mid = [m for i, m in enumerate(mid) if i == 0 or m != mid[i - 1]]
    step = max(1, len(mid) // k)
    return ' -> '.join(mid[::step]) + ' => ' + pc.short(p['to'])[-60:]


def families(fns, cname, n=4):
    for fn in fns:
        ps = [p for p in load(fn) if p['cone'].startswith(cname)]
        print(f"\n== {label(fn)} [{cname}]")
        seen = set()
        for p in ps:
            key = re.sub(r'\[\d+\]', '[]', pc.short(p['to'])).split('~')[0]
            if key in seen: continue
            seen.add(key)
            print(f"  {p['slack']:.3f} lv{p['levels']} ic{p['ic']:.1f}/cell{p['cell']:.1f} skew{p['skew']:+.2f}: {brief(p)}")
            if len(seen) >= n: break


def mdtable(fns):
    """Markdown: per cone, its gap to each fit's WNS (0 = the limiter), the mean gap, how often it
    is the limiter, and its endpoint counts within 0.3 / 1.0 ns of WNS summed over the fits."""
    cols = []; data = {}
    for fn in fns:
        ps = load(fn); w = ps[0]['slack']; lab = label(fn); cols.append((lab, w, ps[-1]['slack']))
        for p in ps:
            d = data.setdefault(p['cone'], {}).setdefault(lab, [99, 0, 0])
            d[0] = min(d[0], p['slack'])
            if p['slack'] <= w + 0.3: d[1] += 1
            if p['slack'] <= w + 1.0: d[2] += 1
    print('| cone | ' + ' | '.join(f"{l} ({w:.3f})" for l, w, _ in cols) + ' | mean gap | limiter | ep<=0.3 | ep<=1.0 |')
    print('|---' * (len(cols) + 5) + '|')
    for cn in GROUP_ORDER:
        if cn not in data: continue
        gaps = []; cells = []
        for l, w, last in cols:
            if l in data[cn]:
                g = data[cn][l][0] - w; gaps.append(g); cells.append('**0**' if g == 0 else f"+{g:.2f}")
            else:
                g = last - w; gaps.append(g); cells.append(f">{g:.1f}")
        n03 = sum(v[1] for v in data[cn].values()); n10 = sum(v[2] for v in data[cn].values())
        print(f"| {cn} | " + ' | '.join(cells) + f" | +{sum(gaps)/len(gaps):.2f} | {sum(1 for g in gaps if g == 0)}/{len(cols)} | {n03} | {n10} |")


COMMANDS = {
    # name: (minimum arguments after the command, runner)
    'table': (1, lambda a: table(a)),
    'ladder': (1, lambda a: ladder(a)),
    'skew': (1, lambda a: skew(a)),
    'show': (2, lambda a: show(a[0], a[1], int(a[2]) if len(a) > 2 else 1)),
    'families': (2, lambda a: families(a[1:], a[0], 4)),
    'md': (1, lambda a: mdtable(a)),
    'warm': (1, lambda a: [load(fn) for fn in a]),
}


def main(argv):
    if not argv or argv[0] not in COMMANDS or len(argv) - 1 < COMMANDS[argv[0]][0]:
        print(__doc__[__doc__.index('usage:'):].split('\n\n')[0], file=sys.stderr)
        return 2
    COMMANDS[argv[0]][1](argv[1:])
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

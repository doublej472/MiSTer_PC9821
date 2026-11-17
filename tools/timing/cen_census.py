#!/usr/bin/env python3
"""tools/timing/cen_census.py: which failing clk_sys paths sit between registers on one clock enable.

usage: cen_census.py [--clk-mhz F] [--show GEN] [--show-k K] PATH...
  PATH is a sweep run dir, a seed dir or an ena_paths.tsv (tools/timing/cen_census.tcl, run by
  tools/timing/census.tcl as the fit's post-STA script).

A `set_multicycle_path -setup N -hold N-1` between two registers is exact only when
  (1) the source changes only on the enable's pulses (its ENA pin is gated by the enable, and its
      synchronous clear/load is reset alone), and
  (2) the destination captures only on the enable's pulses (its ENA is gated by the enable), and
  (3) two pulses are always at least N clk_sys cycles apart, which only the generator's RTL says.
The census reads (1) and (2) from the FITTED netlist: each end's ENA driver and the registers in
its fan-in cone. A generator below is "in" an end's cone when one of its registers is; an end is
"pure" when its cone holds nothing but the generator's registers (and the reset) and neither end
is a retimed register (_OTERM/_NEW_REG), which is the
structural form of "captures only on the pulse". Purity is necessary, not sufficient: the cone
does not say whether the enable is ANDed in, so every candidate still needs the RTL read that
the report records. (3) is the table below, each with its RTL citation; N is for --clk-mhz.

Per generator it prints, over every seed found: failing paths with the generator in BOTH ends'
cones, how many of those have both ends pure, the worst slack, the endpoints, the seeds, and the
exact multicycle a pure group would take. Then the largest groups of failing paths whose two ends
share one ENA net with no known generator (for discovery), and the exclusions: an end with no
clock enable (it loads every cycle) or a path launched by the reset synchroniser.
"""
import argparse
import collections
import glob
import math
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import profile_gen  # noqa: E402  (the video PLL settings the RTL programs: pc9821_vclk_pkg)

# A register synthesis or the fitter retimed (`_OTERM`/`_NEW_REG`) is not the RTL register the
# proof reads: a retimed chain can load every cycle from enabled neighbours (pc9821_crtc's s_lc80_r
# on the sdc-32503923 fits), so such an end is never pure.
RETIMED_RX = re.compile(r"_OTERM\d|_NEW_REG\d")
RESET_RX = re.compile(r"reset_sync_r|rst_n|op_rst|release_sync|\|rst\b|reset|loader\|cpu_run|raster_cpu_run_d")


def gens(f_hz):
    """(id, cone regex, extra registers allowed in a pure cone, N at f_hz, why, citation)."""
    # pixel_ce: ce = (acc + NUM >= DEN), acc < NUM after a pulse, so the next pulse is
    # floor(DEN / NUM) cycles on at least, at either select; NUM31 is the faster rate.
    # The dot rate is half CLK_VIDEO at the 31 kHz setting (profile_gen.VCLK_SETTINGS, which
    # profile_gen.vclk_pkg_problems holds equal to pc9821_vclk_pkg).
    dot31 = float(profile_gen.vclk_hz("31k")) / 2
    cen_step = (2 ** 32 * 7_987_200) // int(f_hz)
    opna = 2 ** 32 // cen_step
    return [
        ("pixel_ce (dot_ce)", r"\|dot_ce\|acc\[", r"iobus\|gdc_9a8_31k", math.floor(f_hz / dot31),
         "DDS, 31 kHz rate the faster: >= floor(f_sys / 25.175 MHz) cycles apart",
         "src/pc9821/video/pc9821_dot_ce.sv `assign ce = (sum >= W'(DEN));`"),
        ("OPNA cen", r"core\|sound\|cen\|q|cen_acc_ahead", r"^$", opna,
         "DDS at 7.9872 MHz: >= floor(2^32 / CEN_STEP) cycles apart",
         "src/opna/pc9821_opna.sv `cen           <= cen_sum[32];`"),
        ("jt12 clk_en (FM prescaler)", r"u_div\|clk_en", r"u_div\|opn_cnt|core\|sound\|cen\|q", 6 * opna,
         "cen / 6: jt12_mmr's mask_div=1 keeps div_setting at its reset 1/6 (the guest's 2D-2F writes are masked); "
         "every clk_en is also a cen, so a cen-subset pair needs only the cen spacing",
         "src/opna/jt12/hdl/jt12_div.v `clk_en     <= cen_nx & (opn_cnt == 4'd0);`"),
        ("jt10 ADPCM cen_pcm", r"cen_pcm_[ab]", r"core\|sound\|cen\|q", opna,
         "gated by cen", "src/opna/jt12/hdl/jt08_acc.v `assign int_clk_en = clk_en | (cen & cen_pcm_a)`"),
        ("PIT input clock", r"pit\|pit_phase", r"^$", math.floor(f_hz / 2_457_600),
         "DDS at 2.4576 MHz", "src/pc9821/timers/pc9821_pit.sv `if (pit_tick) pit_phase <= pit_diff`"),
        ("PCM86 sample clock", r"pcm86\|(phase|count)\[", r"^$", math.floor(f_hz / 44_100),
         "DDS, 44.1 kHz the fastest rate", "src/pcm86/pc9821_pcm86.sv `localparam [31:0] STEP0`"),
        ("MPU H.CLK tick", r"u_mpu\|(hclk_tick|hclk_sub|phase)", r"^$", 0,
         "stepclock count; also kicked by a command (hclk_kick), so no fixed N",
         "src/pc9821/core/pc9821_mpu.sv `wire hclk_fire   = hclk_kick || hclk_tick_now;`"),
        ("keyboard transfer pace", r"keyboard\|(pace_div|xfer_div)", r"^$", math.floor(f_hz / 1280),
         "SYS_CLOCK_HZ / 1280 per tick", "src/pc9821/input/pc9821_kbd.sv `XFER_TICK_CYCLES = 26'(SYS_CLOCK_HZ / 1280)`"),
        ("calendar 1 Hz", r"calendar\|hz_div", r"^$", int(f_hz),
         "one pulse a second, but the time registers are also written by the guest's serial set",
         "src/pc9821/rtc/pc9821_calendar.sv `localparam [26:0] HZ_DIV_MAX`"),
        ("GDC figure pace", r"u_gdc2\|f_pace", r"\|dot_ce\|acc\[|iobus\|gdc_9a8_31k", 0,
         "a step every FIG_PACE+1 dots, but a figure START restarts it at any cycle: no fixed N",
         "src/pc9821/video/pc9821_gdc2.sv `f_pace <= (f_start_w || f_adv_go_w) ? FIG_PACE :`"),
        ("GVRAM scan tick", r"scan_tick", r"\|dot_ce\|acc\[", 0,
         "derived from pixel_ce; not separately bounded", "src/pc9821/core/pc9821_gvram_scan.sv"),
    ]


def files_of(paths):
    out = []
    for p in paths:
        if os.path.isfile(p):
            out.append(p)
            continue
        out += sorted(glob.glob(os.path.join(p, "seed*", "output_files", "census", "ena_paths.tsv")))
        q = os.path.join(p, "output_files", "census", "ena_paths.tsv")
        if os.path.isfile(q):
            out.append(q)
    return out


def seed_of(path):
    m = re.search(r"seed0*(\d+)", path)
    return m.group(1) if m else os.path.basename(os.path.dirname(path))


def rows_of(path):
    for ln in open(path, errors="replace"):
        if ln.startswith("#"):
            continue
        f = ln.rstrip("\n").split("\t")
        if len(f) != 11:
            continue
        yield dict(slack=float(f[0]), frm=f[1], to=f[2], fena=f[3], tena=f[4], fsclr=f[5],
                   tsclr=f[6], fsload=f[7], tsload=f[8],
                   fcone=[x for x in f[9].split(",") if x], tcone=[x for x in f[10].split(",") if x])


def has_ena(e):
    return e not in ("", "<const>", "-")


def pure(cone, rx, allow):
    if "+" in cone:
        return False
    return all(rx.search(k) or allow.search(k) or RESET_RX.search(k) for k in cone)


def short(n):
    n = n.replace("emu:emu|pc9821_system:core|", "").replace("emu:emu|", "")
    n = re.sub(r"[A-Za-z0-9_]+:", "", n)
    return re.sub(r"\[\d+\]", "[*]", n)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--clk-mhz", type=float, default=90.0)
    ap.add_argument("--show", metavar="GEN", help="print the worst paths of the generator named GEN...")
    ap.add_argument("--show-k", type=int, default=10)
    ap.add_argument("paths", nargs="+")
    a = ap.parse_args(argv)
    f_hz = a.clk_mhz * 1e6
    G = gens(f_hz)
    files = files_of(a.paths)
    if not files:
        print("cen_census: no ena_paths.tsv found", file=sys.stderr)
        return 1
    comp = [(g, re.compile(g[1]), re.compile(g[2])) for g in G]
    stat = {g[0]: dict(n=0, pure=0, worst=0.0, ends=set(), seeds=set(), pairs=collections.Counter(),
                       one=0, ex=[]) for g in G}
    shared = collections.defaultdict(lambda: [0, 0.0, set(), set()])
    excl = collections.Counter()
    total = collections.Counter()
    for path in files:
        sd = seed_of(path)
        for r in rows_of(path):
            total[sd] += 1
            if "z486:cpu" in r["frm"] or "z486:cpu" in r["to"]:
                excl["CPU (runs on the gated cpu_clk: no enable to relax)"] += 1
                continue
            if RESET_RX.search(r["frm"].split("|")[-1]) and "reset_sync_r" in r["frm"]:
                excl["launched by the reset synchroniser"] += 1
                continue
            if "<const>" in (r["fena"], r["tena"]):
                # cen_census.tcl writes <const> for an ENA pin whose driver it could not walk
                # back to: a tied pin, or one fed from a node -synch_edges does not traverse.
                excl["an end whose ENA pin has no traced driver (<const>: tied, or not walked)"] += 1
                continue
            if not has_ena(r["fena"]) or not has_ena(r["tena"]):
                excl["an end with no clock enable (loads every cycle)"] += 1
                continue
            known = False
            for g, rx, allow in comp:
                fin = any(rx.search(k) for k in r["fcone"])
                tin = any(rx.search(k) for k in r["tcone"])
                s = stat[g[0]]
                if fin and tin:
                    known = True
                    s["n"] += 1
                    s["worst"] = min(s["worst"], r["slack"])
                    s["ends"].add((sd, r["to"]))
                    s["seeds"].add(sd)
                    s["pairs"][(short(r["frm"]), short(r["to"]))] += 1
                    if (pure(r["fcone"], rx, allow) and pure(r["tcone"], rx, allow)
                            and not RETIMED_RX.search(r["frm"]) and not RETIMED_RX.search(r["to"])):
                        s["pure"] += 1
                    s["ex"].append(r)
                elif fin or tin:
                    s["one"] += 1
            if not known and r["fena"] == r["tena"]:
                k = (short(r["frm"]).rsplit("|", 1)[0], short(r["to"]).rsplit("|", 1)[0], r["tena"])
                v = shared[k]
                v[0] += 1
                v[1] = min(v[1], r["slack"])
                v[2].add(sd)
                v[3].add(r["to"])
    nseeds = len(total)
    print(f"cen_census: {len(files)} file(s), seeds {' '.join(sorted(total))}; "
          f"{sum(total.values())} failing clk_sys setup paths (worst path per endpoint)\n")
    print(f"| generator | N at {a.clk_mhz:g} MHz | paths, gen in both cones | of them both ends pure "
          f"| worst | endpoints | seeds | one end only | exact form if pure | why N |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for g in G:
        s = stat[g[0]]
        form = (f"-setup {g[3]} -hold {g[3] - 1}" if g[3] >= 2 else "none (N < 2 or unbounded)")
        print(f"| {g[0]} | {g[3] if g[3] else 'unbounded'} | {s['n']} | {s['pure']} | "
              f"{s['worst']:.3f} | {len(s['ends'])} | {''.join(sorted(s['seeds'])) or '-'} | "
              f"{s['one']} | {form} | {g[4]}; {g[5]} |")
    print("\nPer generator, the source -> destination pairs (paths over all seeds):")
    for g in G:
        s = stat[g[0]]
        if not s["n"]:
            continue
        print(f"  {g[0]}:")
        for (fr, to), c in s["pairs"].most_common(12):
            print(f"    {c:5d}  {fr}  ->  {to}")
    print("\nFailing paths whose two ends share ONE ENA net and no generator above (largest 20):")
    for k, v in sorted(shared.items(), key=lambda kv: -kv[1][0])[:20]:
        print(f"  {v[0]:5d} worst {v[1]:7.3f} seeds {''.join(sorted(v[2])):6s} {k[0]} -> {k[1]}  "
              f"(ENA {k[2]})")
    print("\nExcluded (paths over all seeds):")
    for k, v in excl.most_common():
        print(f"  {v:6d}  {k}")
    if a.show:
        name, kk = a.show, a.show_k
        for g in G:
            if g[0].startswith(name):
                for r in sorted(stat[g[0]]["ex"], key=lambda r: r["slack"])[:kk]:
                    print(f"\n{r['slack']:.3f} {r['frm']} -> {r['to']}\n  from ENA {r['fena']} "
                          f"sclr {r['fsclr']} sload {r['fsload']}\n  from cone {r['fcone']}\n"
                          f"  to ENA {r['tena']} sclr {r['tsclr']} sload {r['tsload']}\n"
                          f"  to cone {r['tcone']}")
    return 0 if nseeds else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

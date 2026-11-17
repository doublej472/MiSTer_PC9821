#!/usr/bin/env python3
"""check_sdc_exceptions.py: every timing exception the build reads is registered, matched and counted.

An SDC exception (set_false_path, set_multicycle_path, set_max_delay, set_min_delay,
set_clock_groups) is a promise the tools never check: a pattern that silently stops matching leaves
a real requirement cut or a cut inert, and a new one widens what the fitter is told to ignore.
tools/timing/sdc_exceptions.tsv is the registry: one row per exception, with what it targets, the
count a fitted netlist must show and the proof that makes it safe.

  check_sdc_exceptions.py                 static: every exception line in the SDC sources
                                          (tools/profile/z486_mister.sdc.in, the blocks
                                          tools/profile_gen.py renders, sys/sys_top.sdc) has
                                          exactly one registry row, and every row's match starts
                                          exactly one line of its source
  check_sdc_exceptions.py --fit PATH...   also judge fitted netlists: PATH is a sweep run dir, a
                                          seed dir or an exceptions.txt (written by
                                          tools/timing/sdc_audit.tcl through census.tcl). Every
                                          row's object count must sit in its min..max and its
                                          line must be present once. Prints what each measured
                                          exception hides (the WOULD rows). The clk_sys <-> video
                                          crossing audit must have RUN: an XENDN row per direction
                                          (whose count matches its XEND rows), never XENDSKIP.
                                          A fit written before sdc_audit.tcl emitted XENDN is
                                          accepted only when it carries XEND rows in BOTH
                                          directions, the evidence its audit ran; a file with
                                          neither the markers nor those rows fails.
  check_sdc_exceptions.py --selftest      plants a stale registry, an unregistered exception and
                                          a drifted count, and checks each is caught
"""
import argparse
import glob
import os
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "tools" / "timing" / "sdc_exceptions.tsv"
TEMPLATE = ROOT / "tools" / "profile" / "z486_mister.sdc.in"
SYS_TOP = ROOT / "sys" / "sys_top.sdc"
EXC_RE = re.compile(r"^(set_false_path|set_multicycle_path|set_max_delay|set_min_delay|set_clock_groups)\b")
KINDS = {"registers", "registers_nodup", "sdcvar_nodup", "keepers", "pins", "ports", "clocks"}
SOURCES = {"template", "profile_gen", "sys_top", "hdl"}


def read_registry(path):
    rows, problems = [], []
    for n, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        f = line.split("\t")
        if len(f) != 10:
            problems.append(f"{path}:{n}: expected 10 TAB-separated fields, found {len(f)}")
            continue
        row = dict(zip(("id", "src", "when", "kind", "pattern", "min", "max", "measure", "match",
                        "proof"), f))
        row["line"] = n
        try:
            row["min"], row["max"] = int(row["min"]), int(row["max"])
        except ValueError:
            problems.append(f"{path}:{n}: min/max are not integers")
            continue
        if row["src"] not in SOURCES:
            problems.append(f"{path}:{n}: unknown source {row['src']!r}")
        if row["kind"] not in KINDS:
            problems.append(f"{path}:{n}: unknown kind {row['kind']!r}")
        if row["measure"] not in ("from", "to", "fall", "-"):
            problems.append(f"{path}:{n}: measure must be from, to, fall or -")
        if re.search(r"reset_sync_r", row["pattern"] + row["match"]):
            problems.append(f"{path}:{n} ({row['id']}): an exception on the reset synchroniser: the "
                            "release is a timed synchronous reset (z486_mister.sdc.in)")
        if row["min"] > row["max"]:
            problems.append(f"{path}:{n}: min > max")
        if len(row["proof"].strip()) < 10:
            problems.append(f"{path}:{n} ({row['id']}): no proof")
        if any(r["id"] == row["id"] for r in rows):
            problems.append(f"{path}:{n}: duplicate id {row['id']}")
        rows.append(row)
    return rows, problems


def profile_gen_text():
    sys.path.insert(0, str(ROOT / "tools"))
    import profile_gen as pg  # noqa: E402
    return "\n".join([pg.render_out_cut(True), pg.render_out_cut(False),
                      pg.render_dq_lo_cut(True), pg.render_dq_lo_cut(False),
                      pg.render_cen_multicycles(90_000_000)])


def exception_lines(text):
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        t = line.strip()
        if EXC_RE.match(t):
            out.append((n, t))
    return out


# The endpoints a clk_sys <-> video clock path may reach (the max-delay/hold-cut crossings of
# z486_mister.sdc.in; docs/clock-domains.md V2-V5 and "The framework and the HPS/SPI side").
# Each entry: (regex on the endpoint name, why that endpoint may take the crossing).
XEND_WHITELIST = {
    "s2v": [
        (r"pc9821_video_out:video_out\|(wg_s1|lv_s1)\[", "the core's Gray pointer / level synchronisers, stage 1 (V2, V3)"),
        (r"gamma_fast:gamma\|", "hps_io gamma_en into the gamma LUT: quasi-static framework level"),
        (r"^osd:(vga_osd|hdmi_osd)\|", "framework OSD config words (info, infoh, osd_enable): software-paced"),
        (r"^pll_hdmi_adj:pll_hdmi_adj\|", "framework cfg_done into the HDMI PLL adjuster: quasi-static"),
        (r"^(vmini|vmaxi|hmini|hmaxi|videow|state)\[", "framework LFB_EN/HDMI_PR/FREESCALE config: software-paced"),
        (r"^subcarrier_out", "framework subcarrier select: quasi-static"),
        (r"^ascal:ascal\|i_mode\[", "framework lowlat/LFB_EN into ascal's input mode: quasi-static"),
    ],
    "v2s": [
        (r"^(vs_d0|vs_d1|vsd)$", "HDMI_TX_VS synchroniser stages (V5)"),
        (r"hps_io:hps_io\|video_calc:video_calc\|dout\[", "video_calc counters read by the HPS, which re-polls: software-paced"),
        (r"^sl_r\[", "line-doubler active level into sys_top's scanline select: quasi-static"),
        (r"^(vs_r|vs_old)$", "sync_fix polarity into sys_top: quasi-static"),
    ],
}
# A falling-edge launch the DDIO cut may hide: the clk_sys clock itself (the cells' clock-phase mux
# select, a clock-as-data path) or an output DDIO half; never a fabric register.
XFALL_OK = re.compile(r"^emu\|pll\|pll_inst\|altera_pll_i\|(general\[0\]\.gpll~PLL_OUTPUT_COUNTER|"
                      r"cyclonev_pll\|counter\[0\]\.output_counter)\|divclk$"
                      r"|\|sdram:ctrl\|.*ddio_outa\[\d+\]~DFF(HI|LO)")


def static_check(rows, sources):
    """sources: {src: (label, text)}. Returns a list of problems."""
    problems = []
    for src, (label, text) in sources.items():
        mine = [r for r in rows if r["src"] == src]
        for n, t in exception_lines(text):
            hits = [r for r in mine if t.startswith(r["match"])]
            if len(hits) != 1:
                what = "no registry row" if not hits else "rows " + ", ".join(r["id"] for r in hits)
                problems.append(f"{label}:{n}: exception with {what}: {t[:90]}")
        lines = [ln.strip() for ln in text.splitlines()]
        for r in mine:
            k = sum(1 for t in lines if t.startswith(r["match"]))
            if k != 1:
                problems.append(f"{REGISTRY.name} {r['id']}: its match starts {k} lines of {label}, "
                                f"expected 1: {r['match']!r}")
    return problems


def find_exc_files(paths):
    out = []
    for p in paths:
        p = Path(p)
        if p.is_file():
            out.append(p)
            continue
        cands = [p / "output_files" / "census" / "exceptions.txt"]
        cands += [Path(x) for x in sorted(glob.glob(str(p / "seed*" / "output_files" / "census" /
                                                         "exceptions.txt")))]
        found = [c for c in cands if c.is_file()]
        if not found:
            out.append(p / "output_files" / "census" / "exceptions.txt")   # reported missing
        out.extend(found)
    return out


def fit_check(rows, path):
    problems, would = [], []
    if not path.is_file():
        return [f"{path}: missing (was the fit's post-STA script tools/timing/census.tcl?)"], would
    counts, lines = {}, {}
    xend = {"s2v": 0, "v2s": 0}         # XEND rows per direction
    xendn = {}                          # XENDN markers: direction -> the count the audit wrote
    xendskip = []
    files = {"z486_mister.sdc": ("template", "profile_gen"), "sys/sys_top.sdc": ("sys_top",)}
    for ln in path.read_text().splitlines():
        f = ln.split()
        if not f:
            continue
        if f[0] == "XENDN" and len(f) == 3 and f[1] in xend and f[2].isdigit():
            xendn[f[1]] = int(f[2])
            continue
        if f[0] == "XENDSKIP":
            xendskip.append(f[1] if len(f) > 1 else "?")
            continue
        if f[0] == "XEND" and len(f) >= 3:
            if f[1] in xend:
                xend[f[1]] += 1
            ok = any(re.search(rx, f[2]) for rx, _ in XEND_WHITELIST.get(f[1], []))
            if not ok:
                problems.append(f"{path}: a {f[1]} crossing reaches {f[2]} (from "
                                f"{f[3] if len(f) > 3 else '?'}), which XEND_WHITELIST does not list")
            continue
        if f[0] == "XFALL" and len(f) >= 3:
            if not XFALL_OK.search(f[2]):
                problems.append(f"{path}: {f[1]} hides a falling-edge launch that is not an output "
                                f"DDIO half: {f[2]}")
            continue
        if f[0] == "EXC" and len(f) >= 3 and f[1] in files:
            text = ln.split(None, 2)[2].strip()
            if not any(r["src"] in files[f[1]] and text.startswith(r["match"]) for r in rows):
                problems.append(f"{path}: unregistered exception in the fit's {f[1]}: {text[:90]}")
            continue
        if f[0] in ("COUNT", "LINES") and len(f) == (5 if f[0] == "COUNT" else 3):
            try:
                n = int(f[2])
            except ValueError:
                problems.append(f"{path}: an unreadable {f[0]} row: {ln.strip()[:90]}")
                continue
            (counts if f[0] == "COUNT" else lines)[f[1]] = n
        elif f[0] == "WOULD" and len(f) == 7:
            would.append(f[1:])
    # The crossing audit is a gate only if it ran: zero XEND rows is also what a skipped audit
    # (the video clock pattern matching no clock, or two) leaves, so the run is proved by its
    # XENDN markers. A fit from before the markers proves it by rows in both directions.
    if xendskip:
        problems.append(f"{path}: the clk_sys <-> video crossing audit did not run (XENDSKIP: the "
                        f"video clock pattern matched {xendskip[0]} clocks, not 1)")
    elif xendn:
        for tag in xend:
            if tag not in xendn:
                problems.append(f"{path}: no XENDN {tag} marker: the {tag} crossing audit did "
                                f"not finish")
            elif xendn[tag] != xend[tag]:
                problems.append(f"{path}: XENDN {tag} says {xendn[tag]} endpoints but the file "
                                f"holds {xend[tag]} XEND {tag} rows (truncated?)")
    elif not (xend["s2v"] and xend["v2s"]):
        problems.append(f"{path}: no evidence the clk_sys <-> video crossing audit ran (no XENDN "
                        f"marker, XEND rows s2v {xend['s2v']} / v2s {xend['v2s']})")
    for r in rows:
        if r["id"] not in counts:
            problems.append(f"{path}: {r['id']}: no COUNT row (a registry newer than the fit?)")
            continue
        n = counts[r["id"]]
        conditional = r["when"] != "always"
        # sdc_audit.tcl writes a LINES row for every row whose source is an SDC file (not
        # `hdl`): a missing one is a malformed file, not "present once".
        if r["src"] != "hdl" and r["id"] not in lines:
            problems.append(f"{path}: {r['id']}: no LINES row (its SDC line count is unknown)")
            continue
        present = lines.get(r["id"], 1)
        if conditional and present == 0:
            continue                                    # the build option is off in this fit
        if r["src"] != "hdl" and present != 1:
            problems.append(f"{path}: {r['id']}: its SDC line occurs {present} times in the fit")
        if not r["min"] <= n <= r["max"]:
            problems.append(f"{path}: {r['id']}: matches {n} objects, registry says "
                            f"{r['min']}..{r['max']} ({r['kind']} {r['pattern']})")
    return problems, would


def run_static(registry=REGISTRY, template=TEMPLATE, sys_top=SYS_TOP):
    rows, problems = read_registry(registry)
    sources = {"template": (str(template), Path(template).read_text()),
               "profile_gen": ("tools/profile_gen.py renders", profile_gen_text()),
               "sys_top": (str(sys_top), Path(sys_top).read_text())}
    return rows, problems + static_check(rows, sources)


def selftest():
    failures = []
    rows, problems = run_static()
    if problems:
        failures.append("the real tree is not clean: " + "; ".join(problems[:3]))
    text = TEMPLATE.read_text()
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        plants = {
            "an unregistered false path": (text + "\nset_false_path -from [get_registers {*reset_sync_r*}]\n", None),
            "a registered line removed": (text.replace("set_false_path -from $pc9821_sdramsz_regs", ""), None),
            "a registered line doubled": (text + "\nset_false_path -from $pc9821_status_regs\n", None),
        }
        for name, (t, _) in plants.items():
            tp = d / "t.sdc.in"
            tp.write_text(t)
            _, p = run_static(template=tp)
            if not p:
                failures.append(f"plant not caught: {name}")
        reg = REGISTRY.read_text().replace("\tset_false_path -from $pc9821_sdramsz_regs\t",
                                           "\tset_false_path -from $pc9821_sdramsz_regs_x\t")
        rp = d / "r.tsv"
        rp.write_text(reg)
        _, p = run_static(registry=rp)
        if not p:
            failures.append("plant not caught: a stale registry match")
        ex = d / "exceptions.txt"
        body = "".join(f"COUNT {r['id']} {r['min']} {r['min']} {r['max']}\nLINES {r['id']} 1\n"
                       for r in rows) + "XENDN s2v 0\nXENDN v2s 0\n"
        ex.write_text(body)
        p, _ = fit_check(rows, ex)
        if p:
            failures.append("a clean exceptions.txt failed: " + p[0])
        # the crossing audit must have run: markers, or (a pre-marker fit) rows both ways
        s2v = "XEND s2v emu:emu|pc9821_video_out:video_out|wg_s1[0] x\n"
        v2s = "XEND v2s vs_d0 x\n"
        bare = body.replace("XENDN s2v 0\nXENDN v2s 0\n", "")
        for name, text, caught in (
                ("no XENDN marker and no XEND rows", bare, True),
                ("XENDSKIP (the audit was skipped)", bare + "XENDSKIP 0\n", True),
                ("XENDN for one direction only", bare + "XENDN s2v 0\n", True),
                ("an XENDN count the rows do not match", bare + s2v + "XENDN s2v 2\nXENDN v2s 0\n",
                 True),
                ("a pre-marker fit with rows in one direction only", bare + s2v, True),
                ("a pre-marker fit with rows in both directions", bare + s2v + v2s, False),
                ("markers matching their rows", bare + s2v + v2s + "XENDN s2v 1\nXENDN v2s 1\n",
                 False)):
            ex.write_text(text)
            p, _ = fit_check(rows, ex)
            if caught and not p:
                failures.append(f"plant not caught: {name}")
            if not caught and p:
                failures.append(f"{name} failed: {p[0]}")
        ex.write_text(body.replace(f"COUNT sdramsz_from 2 ", "COUNT sdramsz_from 0 "))
        p, _ = fit_check(rows, ex)
        if not p:
            failures.append("plant not caught: an inert pattern (count 0)")
        ex.write_text(body.replace("LINES status_from 1", "LINES status_from 0"))
        p, _ = fit_check(rows, ex)
        if not p:
            failures.append("plant not caught: an always-row's line absent from the fit")
        ex.write_text(body.replace("LINES status_from 1\n", ""))
        p, _ = fit_check(rows, ex)
        if not any("no LINES row" in x for x in p):
            failures.append("plant not caught: an SDC row with no LINES row")
        ex.write_text(body.replace("COUNT status_from ", "COUNT status_from x", 1))
        try:
            p, _ = fit_check(rows, ex)
            if not any("unreadable COUNT" in x for x in p):
                failures.append("plant not caught: an unreadable COUNT row")
        except ValueError:
            failures.append("an unreadable COUNT row raised instead of being judged")
        ex.write_text(body + "EXC z486_mister.sdc set_false_path -to $pc9821_status_regs\n")
        p, _ = fit_check(rows, ex)
        if not p:
            failures.append("plant not caught: an unregistered exception in a fit's SDC")
        ex.write_text(body + "XEND s2v emu:emu|pc9821_system:core|pc9821_gfx_palette:pal|q[3] x\n")
        p, _ = fit_check(rows, ex)
        if not p:
            failures.append("plant not caught: a clk_sys -> clk_vid word off the whitelist")
        ex.write_text(body + "XFALL sdram_out_fall emu:emu|split_sdram_backend:m|sdram:ctrl|neg_q[0]\n")
        p, _ = fit_check(rows, ex)
        if not p:
            failures.append("plant not caught: a real falling-edge launch behind the DDIO cut")
        rp.write_text(REGISTRY.read_text() + "x_reset\ttemplate\talways\tregisters\t*reset_sync_r*\t3\t3\tfrom\t"
                      "set_false_path -from $x\ta plant to be caught here\n")
        _, p = run_static(registry=rp)
        if not p:
            failures.append("plant not caught: an exception on the reset synchroniser")
    for f in failures:
        print(f"check_sdc_exceptions --selftest: FAIL - {f}")
    if not failures:
        print("check_sdc_exceptions --selftest: PASS (17 plants caught, 2 accepted forms, the tree clean)")
    return 1 if failures else 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--fit", nargs="+", metavar="PATH")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--quiet", action="store_true", help="with --fit: no WOULD table")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    rows, problems = run_static()
    nfit = 0
    if a.fit:
        for path in find_exc_files(a.fit):
            p, would = fit_check(rows, path)
            problems += p
            nfit += 1
            if not a.quiet and would:
                print(f"== {path}: paths each measured exception covers, timed without the "
                      "measured exceptions (n / worst / negative)")
                for w in would:
                    print(f"   {w[0]:16s} {w[1]:5s} {w[2]:22s} {w[3]:>7s} {w[4]:>8s} {w[5]:>6s}")
    for p in problems:
        print(f"check_sdc_exceptions: FAIL - {p}")
    if problems:
        return 1
    print(f"check_sdc_exceptions: OK - {len(rows)} registered exceptions"
          + (f", {nfit} fitted netlist(s) in range" if a.fit else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

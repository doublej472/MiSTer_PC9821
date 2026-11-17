#!/usr/bin/env python3
"""pcm86ovf_decode.py - decode a PCMOVF stage-1 capture (tools/hwprobe/pcm86ovf/pcm86ovf.s): what the
PC-9801-86 PCM FIFO does when it is written past full, row by row, beside what the core and NP2kai
predict for that row.

    pcm86ovf_decode.py CAPTURE [CAPTURE2]   one capture, or two (core first, then the machine)
    pcm86ovf_decode.py --selftest           the classifiers on captures planted from each model

THE MODELS (what each predicts, not which is right):
  core     src/pcm86/pc9821_pcm86.sv: full (0xA466 bit 7) at count >= 0x8000; a byte written at
           count 0x8000 is stored and the OLDEST 4-byte group dropped (`count <= 16'h7FFD;   //
           rdptr steps 4 (the slip)`), so after k bytes past full the count is 32765 + (k-1) % 4:
           full reads 1 only after every 4th extra byte, and a drain after d >= 1 extra bytes holds
           32765 + (d - 1) % 4 bytes. IRQ flag (0xA468 bit 4) = (latched || count <= threshold)
           && bit 5; a bit-4-clear write clears the latch and re-asserts it while the level holds.
  NP2kai   cbus/pcm86io.c pcm86_oa46c: `if (g_pcm86.virbuf < PCM86_LOGICALBUF) { g_pcm86.virbuf++; }`
           - the flags' count SATURATES at 0x8000, so full stays 1 on every extra byte and a drain
           empties after 32768 bytes (the extra bytes go to its rescue margin, realbuf, which the
           flags never see). Its 0xA468 bit 4 read is gated by the write-to-IRQ delay heuristic
           (sound/pcm86c.c pcm86gen_intrq, `curclk - g_pcm86.lastclockforwait >= datawriteirqwait`)
           and reads 0 within it, which covers every THR row (each read follows a data write).
  The machine's OVF/PLAY rows are classified against: SATURATE (holds 32768, full stays 1: the
  excess dropped, or NP2kai's flag view), CORE-SLIP4, MORE (holds 32768 + d), WRAP (holds about d:
  the count wrapped), OTHER. Stage 1 cannot tell "the new byte dropped" from "the oldest byte
  overwritten" when both hold 32768: that is stage 2 (pcm86ovf_audio.py).

Times are ARTIC ticks (307200 Hz). The bytes a drain held are (t_empty - a) / b, a and b fitted
on the CAL rows (8-bit mono, one byte per frame).
"""
from __future__ import annotations

import re
import sys

ARTIC_HZ = 307200
FULL = 32768
DEPTHS = (0, 1, 2, 3, 4, 5, 8, 64)
DRAIN_THR = (0x3F + 1) * 128
THRS = {0x7F: 16384, 0xFE: 32640, 0xFF: 32764}

KV = re.compile(r"(\w+)=(\S+)")


def kv(line: str) -> dict:
    return dict(KV.findall(line))


def num(v):
    if v is None or v == "-":
        return None
    return int(v)


def parse(text: str) -> dict:
    cap = {"fill": [], "drain": [], "thr": [], "ovf": [], "play": None, "restore": [],
           "state": {}, "wcost": None, "lines": []}
    for raw in text.splitlines():
        line = raw.strip()
        cap["lines"].append(line)
        if line.startswith("STATE "):
            cap["state"] = kv(line)
        elif line.startswith("FILL "):
            cap["fill"].append(kv(line))
        elif line.startswith("WCOST "):
            cap["wcost"] = kv(line)
        elif line.startswith("DRAIN "):
            d = kv(line)
            d["tag"] = line.split()[1]
            d["skip"] = "SKIP" in line
            cap["drain"].append(d)
        elif line.startswith("THR "):
            cap["thr"].append(kv(line))
        elif line.startswith("PLAY") and " w=" not in line and "d=" in line and "ROW" not in line:
            cap["play"] = _row(line)
        elif line.startswith("OVF ") and "ROW" not in line and "SKIP" not in line:
            cap["ovf"].append(_row(line))
        elif line.startswith("RESTORE "):
            cap["restore"].append(line)
    cap["done"] = any(x == "PCMOVF DONE" for x in cap["lines"])
    cap["stall"] = any(x.startswith("PLAY STALL") for x in cap["lines"])
    return cap


def _row(line: str) -> dict:
    head, _, st = line.partition(" st=")
    r = kv(head)
    r["st"] = [int(x, 16) for x in st.split()] if st.strip() else []
    return r


# ---- the models ------------------------------------------------------------------------------
def core_count_after(k: int) -> int:
    """the core's count after k bytes written past a full FIFO (k >= 0)"""
    return FULL if k == 0 else 32765 + (k - 1) % 4


def core_status(k: int) -> int:
    return 0x80 if core_count_after(k) >= FULL else 0x00


def models_held(d: int) -> dict:
    return {"SATURATE": FULL, "CORE-SLIP4": core_count_after(d), "MORE": FULL + d, "WRAP": d}


# ---- the fit --------------------------------------------------------------------------------
def fit_cal(cap):
    """least squares t = a + b * n over the 8-bit-mono CAL rows -> (a, b, residual max) or None"""
    dac8 = cap["state"].get("dac8")
    pts = [(int(d["n"]), int(d["empty"])) for d in cap["drain"]
           if d["tag"] == "CAL" and not d["skip"] and d.get("dac") == dac8 and num(d.get("empty")) is not None
           and d.get("tmo") == "00"]
    if len({p[0] for p in pts}) < 2:
        return None
    n = len(pts)
    mx = sum(p[0] for p in pts) / n
    my = sum(p[1] for p in pts) / n
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    sxy = sum((p[0] - mx) * (p[1] - my) for p in pts)
    b = sxy / sxx
    a = my - b * mx
    res = max(abs(p[1] - (a + b * p[0])) for p in pts)
    return a, b, res


def held(d, fit, bias=0.0):
    if fit is None or num(d.get("empty")) is None:
        return None
    a, b, _ = fit
    return (int(d["empty"]) - a) / b - bias


def full_bias(cap, fit) -> float:
    """the drain-from-full offset, from the OVF d = 0 rows (exactly full: 32768 held by every model).
    A drain's first sample comes at a phase that depends on how long the fill took: the core's
    rate accumulator is zeroed by the FIFO reset (pc9821_pcm86.sv buf_rst `phase <= 32'd0;`) and
    free-runs through the fill, so a 32768-byte fill and a CAL fill start playback at different
    phases, up to one sample apart (on the core run k0-run1: +0.5..+0.9 byte). Subtracted from the
    OVF and PLAY rows; 0 when there is no d = 0 row."""
    hs = [held(x, fit) for x in cap["drain"] if x["tag"] == "OVF" and not x["skip"] and x.get("d") == "0"]
    hs = [h for h in hs if h is not None]
    return sum(hs) / len(hs) - FULL if hs and fit else 0.0


def classify(d: int, st: list, h: float, tol: float) -> str:
    """the OVF verdict: among the models whose status pattern fits, the one whose held count is
    nearest (within tol); "~" marks a runner-up within half a byte"""
    if h is None:
        return "NODATA"
    if d == 0:
        return "FULL-HOLDS-32768" if abs(h - FULL) <= tol else "OTHER"
    full_all = all(s & 0x80 for s in st)
    core_pat = all((s & 0xC0) == core_status(k + 1) for k, s in enumerate(st))
    fits = {"SATURATE": full_all, "CORE-SLIP4": core_pat, "MORE": full_all, "WRAP": True}
    cand = sorted((abs(h - hv), name) for name, hv in models_held(d).items() if fits[name])
    if not cand or cand[0][0] > tol:
        return "OTHER"
    if len(cand) > 1 and cand[1][0] - cand[0][0] < 0.5 and cand[1][0] <= tol:
        return "%s~%s" % (cand[0][1], cand[1][1])
    return cand[0][1]


# ---- the report ------------------------------------------------------------------------------
def report(cap) -> list:
    out = []
    st = cap["state"]
    out.append("STATE a460=%s a466=%s a468=%s a46a=%s imrs=%s dac8=%s" % tuple(
        st.get(k, "?") for k in ("a460", "a466", "a468", "a46a", "imrs", "dac8")))
    # FILL
    pred_fill = {"0": (0x40, 0x00), "1": (0x00, 0x00), "32767": (0x00, 0x00), "32768": (0x80, 0x00)}
    for f in cap["fill"]:
        if "first_full" in f:
            ff = num(f["first_full"])
            out.append("FILL first_full=%s (core 32768, NP2kai 32768) first_notempty=%s (core 1, NP2kai 1) "
                       "writes=%s art=%s (%.2f us/byte) tmo=%s" % (
                           f["first_full"], f["first_notempty"], f["writes"], f["art"],
                           1e6 * int(f["art"]) / ARTIC_HZ / max(1, int(f["writes"])), f["tmo"]))
            out.append("  verdict: full at %s" % ("32768 = the 32 KiB both models size" if ff == FULL else f"{ff}"))
        elif "n" in f:
            p = pred_fill.get(f["n"])
            a466 = f.get("a466")
            ok = "" if a466 == "-" or p is None else (
                "MATCH" if (int(a466, 16) & 0xFE) == p[0] else "DIFF")
            out.append("FILL n=%s a466=%s a468=%s  pred(core=NP2kai) a466=%02X(bit 0 = phase, masked) a468=%02X  %s" % (
                f["n"], a466, f.get("a468"), p[0], p[1], ok))
    wc = cap["wcost"]
    if wc:
        out.append("WCOST 1024 x (out A46C, in A466): art=%s = %.2f us/write" % (
            wc["art"], 1e6 * int(wc["art"]) / ARTIC_HZ / 1024))
    fit = fit_cal(cap)
    if fit:
        a, b, res = fit
        out.append("CAL fit: t_empty = %.1f + %.4f * n ticks -> %.1f bytes/s (nominal 44100), latency %.1f us, "
                   "worst residual %.1f ticks (%.2f bytes)" % (a, b, ARTIC_HZ / b, a * 1e6 / ARTIC_HZ, res, res / b))
        tol = max(1.0, 3 * res / b)
    else:
        out.append("CAL fit: not enough drains (nodrain?)")
        tol = 1.0
    bias = full_bias(cap, fit)
    out.append("full-drain offset from the d=0 rows: %+.2f byte (subtracted from the PLAY/OVF held counts)" % bias)
    for d in cap["drain"]:
        if d["tag"] != "CAL" or d["skip"]:
            continue
        h = held(d, fit)
        irq = num(d.get("irq"))
        emp = num(d.get("empty"))
        at_irq = ((emp - irq) / fit[1] if fit and irq is not None and emp is not None
                  and d.get("dac") == cap["state"].get("dac8") else None)
        n = int(d["n"])
        out.append("CAL dac=%s n=%d tr=%s empty=%s held=%s at_irq=%s (core %d) irr=%s tmo=%s" % (
            d["dac"], n, d["tr"], d.get("empty"), "%.1f" % h if h is not None else "-",
            "%.0f" % at_irq if at_irq is not None else "-", min(n, DRAIN_THR), d.get("irr"), d.get("tmo")))
        if fit and d.get("dac") != cap["state"].get("dac8") and h is not None and h > 0:
            out.append("  as-found format: %.2f bytes per frame (core/NP2kai B0 = 16-bit stereo: 4)" % (n / h))
    # THR
    out += thr_report(cap)
    # PLAY
    p = cap["play"]
    if p:
        dp = [d for d in cap["drain"] if d["tag"] == "PLAY" and not d["skip"]]
        h = held(dp[0], fit, bias) if dp else None
        w = int(p["d"])
        per = int(p["art"]) / w
        wcper = int(cap["wcost"]["art"]) / 1024 if cap["wcost"] else None
        out.append("PLAY %d writes while playing: %.2f us/write (WCOST %.2f) full after %s of them, first not-full "
                   "after write %s; held at the end %s" % (
                       w, 1e6 * per / ARTIC_HZ, 1e6 * wcper / ARTIC_HZ if wcper else 0, p["full"], p["fnf"],
                       "%.1f" % h if h is not None else "-"))
        out.append("  pred: core 32765..32768 held, full on about 1 write in 4; NP2kai/SATURATE 32768, full on "
                   "(nearly) every write; WRAP small; a write that WAITS for room shows as us/write >> WCOST%s" % (
                       "  -> STALL (OVF skipped)" if cap["stall"] else ""))
        if h is not None:
            if abs(h - FULL) <= tol and int(p["full"]) >= w * 0.9:
                v = "SATURATE"
            elif 32765 - tol <= h <= FULL + tol:
                v = "CORE-SLIP4" if int(p["full"]) < w * 0.5 else "HOLDS-ABOUT-32768"
            elif h < FULL / 2:
                v = "WRAP"
            elif h > FULL + tol:
                v = "MORE"
            else:
                v = "OTHER"
            out.append("  verdict: %s" % v)
    # OVF
    for o in cap["ovf"]:
        d = int(o["d"])
        dr = [x for x in cap["drain"] if x["tag"] == "OVF" and not x["skip"] and x["d"] == o["d"]
              and x["tr"] == o["tr"]]
        h = held(dr[0], fit, bias) if dr else None
        nf = num(dr[0].get("nf")) if dr else None
        pred_core = " ".join("%02X" % core_status(k + 1) for k in range(len(o["st"])))
        out.append("OVF d=%d tr=%s pre=%s a468=%s st=%s" % (
            d, o["tr"], o["pre"], o["a468"], " ".join("%02X" % s for s in o["st"]) or "-"))
        if o["st"]:
            out.append("  pred st: core %s | NP2kai %s" % (pred_core, " ".join("80" for _ in o["st"])))
        mh = models_held(d)
        out.append("  held=%s (core %d, NP2kai/SATURATE %d, MORE %d, WRAP %d) nf=%s -> %s" % (
            "%.1f" % h if h is not None else "-", mh["CORE-SLIP4"], mh["SATURATE"], mh["MORE"], mh["WRAP"],
            nf if nf is not None else "-", classify(d, o["st"], h, tol)))
    for r in cap["restore"]:
        out.append(r)
    out.append("DONE" if cap["done"] else "NOT DONE (the capture ends early: a hang at the last BEGIN)")
    return out


def thr_core_sim(T: int, ns: list):
    """the core's raw/clr bit 4 at the logged byte counts (IRQ enabled from the start, a clear
    write at each logged count): pending latches at count <= T after a write"""
    out = {}
    pending = False
    want = set(ns)
    for n in range(1, max(ns) + 1):
        if n <= T:
            pending = True      # irq_set: armed by the write, count <= T
        if n in want:
            raw = pending or n <= T
            pending = n <= T    # the clear, then the re-assert while the level holds
            out[n] = (raw, n <= T)
    return out


def thr_report(cap) -> list:
    out = []
    by = {}
    for r in cap["thr"]:
        by.setdefault(r["v"], []).append(r)
    for v, rows in by.items():
        T = int(rows[0]["t"])
        sim = thr_core_sim(T, [int(r["n"]) for r in rows])
        nmatch = 0
        out.append("THR v=%s threshold %d bytes: n a466 raw clr irr | core raw clr irr | NP2kai raw clr" % (v, T))
        out.append("  (the verdict is on raw/clr; irr is the slave IRR bit 4, which the OPNA shares: INT5 =")
        out.append("   pc9821_irq_share's OR of the OPNA line and this FIFO's, so the core predicts irr = 1")
        out.append("   whenever clr = 1, and irr = 1 above the threshold too while the OPNA line is up)")
        for r in rows:
            n = int(r["n"])
            raw = bool(int(r["raw"], 16) & 0x10)
            clr = bool(int(r["clr"], 16) & 0x10)
            irr = bool(int(r["irr"], 16) & 0x10)
            cr, cc = sim[n]
            m = (raw, clr) == (cr, cc)
            nmatch += m
            note = ""
            if irr and not clr:
                note = "  (IRR held by the other INT5 source)"
            elif clr and not irr:
                note = "  (flag set, IRR clear)"
            out.append("  %5d %s %d %d %d | %d %d %s | 0 0  %s%s" % (
                n, r["a466"], raw, clr, irr, cr, cc, "1" if cc else ">=0", "MATCH-CORE" if m else "DIFF", note))
        lvl = [int(r["n"]) for r in rows if int(r["clr"], 16) & 0x10]
        out.append("  verdict v=%s: %d/%d rows as the core; the flag after a clear holds up to n=%s" % (
            v, nmatch, len(rows), max(lvl) if lvl else "none"))
    return out


# ---- selftest ---------------------------------------------------------------------------------
def plant(model: str) -> str:
    """a capture as a machine following MODEL would print it (44100 B/s, latency 12 ticks)"""
    b = ARTIC_HZ / 44100.0
    a = 12.0

    def t(nbytes):
        return int(round(a + b * nbytes))

    def after(k):          # (count, status) after k bytes past full
        if model == "core":
            c = core_count_after(k)
        elif model == "saturate":
            c = FULL
        elif model == "more":
            c = FULL + k
        elif model == "wrap":
            c = k if k else FULL
        return c, (0x80 if (c >= FULL if model != "wrap" else k == 0) else 0x00)

    L = ["PCMOVF v1 rate=44100 thr_drain=3F play_w=2048 artic=307200",
         "STATE a460=40 a466=41 a468=08 a46a=B0 imrs=75 dac8=E0", "BEGIN:FILL",
         "FILL n=0 a466=41 a468=00", "FILL n=1 a466=00 a468=00", "FILL n=32767 a466=01 a468=00",
         "FILL n=32768 a466=80 a468=00",
         "FILL first_full=32768 first_notempty=1 writes=32768 art=18482 tmo=00", "END:FILL",
         "BEGIN:WCOST", "WCOST n=1024 art=520 full=0", "END:WCOST", "BEGIN:CAL"]

    def drain(tag, dac, n, d, tr, nbytes):
        irq = 0 if nbytes <= DRAIN_THR else t(nbytes - DRAIN_THR)
        return ("DRAIN %s dac=%s n=%d d=%d tr=%d st0=80 nf=%d irq=%d irr=%d empty=%d polls=999 tmo=00" % (
            tag, dac, n, d, tr, 8, irq, irq, t(nbytes)))
    for n, dac, scale in ((4096, "E0", 1), (16384, "E0", 1), (24576, "E0", 1), (16384, "B0", 4)):
        for tr in (1, 2):
            L.append(drain("CAL", dac, n, 0, tr, n // scale))
    L += ["END:CAL", "BEGIN:THR"]
    for v, T in THRS.items():
        ns = sorted({n for n in range(1, FULL + 1) if abs(n - T) <= 4 or n >= FULL - 4})
        sim = thr_core_sim(T, ns)
        for n in ns:
            raw, clr = sim[n] if model == "core" else (False, False)
            L.append("THR v=%02X t=%d n=%d a466=00 raw=%02X clr=%02X irr=%02X" % (
                v, T, n, 0x20 | (0x10 if raw else 0), 0x20 | (0x10 if clr else 0), 0x10 if clr else 0))
    L += ["END:THR", "BEGIN:PLAY"]
    if model == "core":
        pst, pfull, ph = [core_status(k + 1) for k in range(64)], 520, 32766
    elif model == "wrap":
        pst, pfull, ph = [0] * 64, 0, 1500
    elif model == "more":
        pst, pfull, ph = [0x80] * 64, 2048, FULL + 1900
    else:
        pst, pfull, ph = [0x80] * 64, 2048, FULL
    L.append("PLAY d=2048 tr=1 pre=80 a468=B0 art=1050 full=%d fnf=%d st=%s" % (
        pfull, 0 if pfull == 2048 else 1, " ".join("%02X" % s for s in pst)))
    L.append(drain("PLAY", "E0", FULL, 2048, 1, ph))
    L += ["END:PLAY", "BEGIN:OVF"]
    for d in DEPTHS:
        for tr in (1, 2):
            L.append("OVF ROW d=%d" % d)
            st = [after(k + 1)[1] for k in range(min(d, 64))]
            c = after(d)[0]
            L.append("OVF d=%d tr=%d pre=80 a468=00 art=%d full=%d fnf=0 st=%s" % (
                d, tr, d, sum(1 for s in st if s & 0x80), " ".join("%02X" % s for s in st)))
            L.append(drain("OVF", "E0", FULL, d, tr, c))
    L += ["END:OVF", "RESTORE A468 was=08 now=08 OK", "RESTORE A46A was=B0 now=B0 OK",
          "RESTORE IMRS was=75 now=75 OK", "RESTORE A466 now=41", "PCMOVF DONE"]
    return "\r\n".join(L) + "\r\n"


def selftest() -> int:
    want = {"core": "CORE-SLIP4", "saturate": "SATURATE", "more": "MORE", "wrap": "WRAP"}
    bad = 0
    for model, verdict in want.items():
        cap = parse(plant(model))
        rep = report(cap)
        ovf = [ln for ln in rep if ln.startswith("  held=")]
        for d, ln in zip([d for d in DEPTHS for _ in (1, 2)], ovf):
            exp = verdict if d else "FULL-HOLDS-32768"
            if model == "wrap" and d == 0:
                exp = "FULL-HOLDS-32768"
            got = ln.rsplit("-> ", 1)[1]
            if got != exp:
                print("selftest %s d=%d: got %s want %s" % (model, d, got, exp))
                bad += 1
        thr = [ln for ln in rep if ln.startswith("  verdict v=")]
        if model == "core" and not all(ln.split(": ")[1].split()[0].split("/")[0] ==
                                       ln.split(": ")[1].split()[0].split("/")[1] for ln in thr):
            print("selftest core THR rows not all MATCH-CORE")
            bad += 1
        fit = fit_cal(cap)
        if fit is None or abs(ARTIC_HZ / fit[1] - 44100) > 5:
            print("selftest %s: CAL fit off" % model)
            bad += 1
        if not cap["done"]:
            bad += 1
    print("selftest: %s" % ("PASS" if not bad else "FAIL"))
    return 1 if bad else 0


def main(argv) -> int:
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) not in (2, 3):
        print(__doc__)
        return 2
    for path in argv[1:]:
        with open(path, "rb") as f:
            cap = parse(f.read().decode("ascii", "replace"))
        print("==== %s" % path)
        print("\n".join(report(cap)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

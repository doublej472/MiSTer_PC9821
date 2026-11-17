#!/usr/bin/env python3
"""xe10z_decode.py - decode an XE10Z capture (tools/hwprobe/xe10z/xe10z.s) and state, per section,
which model the machine (or the core) follows.

    xe10z_decode.py CAPTURE [CAPTURE2]     one capture, or two side by side (core, machine)
    xe10z_decode.py --selftest             the classifiers on captures planted from each model

THE MODELS each section is judged against (what they are, not which is right). "The core" below
is the STEP-Z0 core, the build that took docs/probes/core/XE10Z-CORE-rs-8b71a248-s6.TXT; the
machine's capture (docs/probes/XE10Z-XE10.TXT) then moved the core on D29, SDIP, NMX, MPU and
CAL to the machine's model (PACKED, STORED, ABORT, 4-phase, the chip's fold), so a capture of
the current core reads "DIFFERS" from the step-Z0 model on those rows:
  SAL   per row (one form, operand and FLAGS image): SAME-AS-SHL when /6's result and its
        OF/SF/ZF/PF/CF equal /4's (AF is undefined for a shift and masked; OF is compared only for a
        count of 1, the count it is defined for, and FLAGS for a count of 0 must be unchanged),
        else DIFF naming the flag bits. The OLD z486 the core vendors leaves OF unchanged for /6
        by one (so its rows whose OF-in differs from CF XOR the result's top bit read DIFF on OF);
        the z486 fork's fix, the 80386EX SingleStepTests captures and NP2kai write OF as SHL does.
        /4 itself is checked against the SDM's SHL (result, CF = the last bit out, OF = CF XOR
        the top bit for a count of 1, SF/ZF/PF of the result).
  D29   CH0   a read of 0x29 returns channel 0's bound (the step-Z0 core)
        LAST  a read returns the bound of the channel the last write named
        PACKED a read returns all four channels' bounds, channel n in bits 2n+1:2n (the machine;
              the core since, pc9821_dmac.sv bound_rd)
  SDIP  per round trip: STORED (got == wrote), WITHHELD (got == was), OTHER. The core withholds
        bit 1 of 0x841E in BOTH banks (the step-Z0 core's sdip_data_mask); NP2kai is
        bankless and withholds bits 1:0 of 0x841E (io/dipsw.c `set = value & 0xfc;`); qemu-pc98
        stores every bit of both banks (pc98-sys.c pc98_sdip_write).
  NMX   ABORT (ERR, error ABRT: a device without the Host Protected Area feature, word 82 bit
        10 = 0, per the ATA spec), COUNT (the address read is the capacity: NP2kai ideio.c
        `drv->sn = sxsi->totals & 0xff;`, the core), MAXLBA (capacity - 1: the ATA spec's maximum
        address, qemu ide_set_sector(s, s->nb_sectors - 1)).
  MPU   the FD interval sequence per E7 data byte v = 4q + f, in internal clocks (the v=04 row's
        median interval is one clock): NP2kai cbus/mpu98ii.c hclk_step1 {0000, 1000, 1010,
        1110} indexed by a counter that wraps at 4 (`hclk_cnt & 3`), mean q + f/4; the core
        (pc9821_mpu.sv, a 3-bit hclk_phase) extras in phases 0..f-1 of an EIGHT-phase cycle, mean
        q + f/8, phase reset at the E7 write.
  CAL   per pattern: LOADED (the read at once equals the pattern), REFUSED (equals the BASE set
        just before it, seconds 00/01), OTHER (the chip normalised it). The core refuses a set
        whose byte compares fail (pc9821_calendar.sv CMD_TIMESET: sec/min <= 0x59, hour <= 0x23,
        day 0x01..0x31, month nibble 1..C); NP2kai's TIMESET does nothing (io/upd4990.c
        `case 0x02: uPD4990.regsft = 0;`); the uPD4990A datasheet describes a plain load.
"""
from __future__ import annotations

import re
import statistics
import sys

ARTIC_HZ = 307200
BASE = bytes([0x00, 0x00, 0x10, 0x10, 0xA1, 0x10])
PATS = [
    ("P0 valid 23:59:58 31 Dec 99", "585923 31C599"),
    ("P1 sec 5A", "5A3012 156320"),
    ("P2 sec 3F", "3F3012 156320"),
    ("P3 min 60", "586012 156320"),
    ("P4 hour 24", "585924 156320"),
    ("P5 day 32", "585923 326320"),
    ("P6 day 00", "003012 006320"),
    ("P7 Feb 30", "585923 302120"),
    ("P8 Feb 28 2021", "585923 282121"),
    ("P9 day 2A", "585923 2A6320"),
    ("P10 month 13", "003012 15D320"),
    ("P11 month 0", "003012 150320"),
    ("P12 year A0", "003012 1563A0"),
    ("P13 weekday 7", "003012 156720"),
]
PATS = [(n, bytes.fromhex(h.replace(" ", ""))) for n, h in PATS]
SDIP_CORE = {("80", "841E", 0x02): "WITHHELD", ("80", "841E", 0x01): "STORED",
             ("C0", "841E", 0x02): "WITHHELD", ("C0", "841E", 0x01): "STORED",
             ("C0", "851E", 0x10): "STORED", ("80", "861E", 0x80): "STORED",
             ("C0", "861E", 0x80): "STORED"}
STEP1 = [[0, 0, 0, 0], [1, 0, 0, 0], [1, 0, 1, 0], [1, 1, 1, 0]]


SAL_FI = (0x02D7, 0x0A02)
SAL_VALS = {8: (0xA5A5A540, 0xA5A5A5C0, 0xA5A5A580, 0xA5A5A501),
            16: (0xA5A54000, 0xA5A5C000, 0xA5A58000, 0xA5A50001),
            32: (0x40000000, 0xC0000000, 0x80000000, 0x00000001)}
SAL_FORMS = ["D0r8c1", "D0m8c1", "D1r16c1", "D1m16c1", "D1r32c1", "D1m32c1", "D2r8c1", "D2m8c1",
             "D3r16c1", "D3m16c1", "D3r32c1", "D3m32c1", "C0r8c1", "C0m8c1", "C1r16c1", "C1m16c1",
             "C1r32c1", "C1m32c1", "D2r8c2", "D2m8c0", "D2r8c0", "D3r16c2", "D3m16c0", "D3r32c2",
             "D3m32c2"]
FL_CF, FL_PF, FL_AF, FL_ZF, FL_SF, FL_OF = 0x001, 0x004, 0x010, 0x040, 0x080, 0x800
FL_NAMES = ((FL_OF, "OF"), (FL_SF, "SF"), (FL_ZF, "ZF"), (FL_AF, "AF"), (FL_PF, "PF"), (FL_CF, "CF"))


def sal_form(name):
    m = re.match(r"^(D0|D1|D2|D3|C0|C1)([rm])(8|16|32)c(\d+)$", name)
    return (m.group(1), m.group(2), int(m.group(3)), int(m.group(4))) if m else None


def shl_model(w, c, v, fin, of_mode="shl"):
    """(result, FLAGS) of SHL by c of the low w bits of v from FLAGS fin (bits above w kept).
    of_mode 'keep': OF left as it was for a count of 1 (the old z486's /6). AF is left as it was
    (undefined; the decoder masks it)."""
    mask = (1 << w) - 1
    c &= 31
    if c == 0:
        return v, fin
    x = v & mask
    res = (x << c) & mask
    cf = (x >> (w - c)) & 1 if c <= w else 0
    f = fin & ~(FL_CF | FL_PF | FL_ZF | FL_SF | (FL_OF if c == 1 else 0))
    f |= FL_CF if cf else 0
    f |= FL_ZF if res == 0 else 0
    f |= FL_SF if res >> (w - 1) else 0
    f |= FL_PF if bin(res & 0xFF).count("1") % 2 == 0 else 0
    if c == 1:
        of = cf ^ (res >> (w - 1))
        f |= (fin & FL_OF) if of_mode == "keep" else (FL_OF if of else 0)
    return (v & ~mask & 0xFFFFFFFF) | res, f


def sal_cmp_mask(c):
    """The FLAGS bits a /6-vs-/4 comparison holds for a count c: AF never (undefined), OF only
    for a count of 1 (undefined for a larger count; for 0 every flag is unchanged and compared)."""
    m = FL_CF | FL_PF | FL_ZF | FL_SF
    if c & 31 in (0, 1):
        m |= FL_OF
    return m


def flag_list(bits):
    return "+".join(n for b, n in FL_NAMES if bits & b) or "-"


def sal_verdicts(rows):
    out = []
    if not rows:
        return ["no SAL rows"]
    n_same = n_diff = n_shl_bad = 0
    diff_bits = 0
    diff_c1_only_of = True
    for r in rows:
        fm = sal_form(r["form"])
        if not fm:
            out.append("%s: unknown form" % r["form"])
            continue
        _op, _rm, w, c = fm
        mask = (1 << w) - 1
        cm = sal_cmp_mask(c)
        res_d = (r["r6"] ^ r["r4"]) & 0xFFFFFFFF
        fl_d = (r["f6"] ^ r["f4"]) & cm
        want_r, want_f = shl_model(w, c, r["v"], r["i"])
        shl_ok = r["r4"] == want_r and (r["f4"] & cm) == (want_f & cm)
        n_shl_bad += not shl_ok
        if res_d == 0 and fl_d == 0:
            v = "SAME-AS-SHL"
            n_same += 1
        else:
            n_diff += 1
            diff_bits |= fl_d
            if res_d or fl_d != FL_OF or c != 1:
                diff_c1_only_of = False
            v = "DIFF (%s)" % ", ".join(([flag_list(fl_d)] if fl_d else []) + (["result"] if res_d else []))
        out.append("%-8s v=%08X i=%04X /6 %08X %04X  /4 %08X %04X  %s%s" % (
            r["form"], r["v"], r["i"], r["r6"] & 0xFFFFFFFF, r["f6"], r["r4"] & 0xFFFFFFFF, r["f4"], v,
            "" if shl_ok else "  (/4 IS NOT THE SDM's SHL: want %08X %04X)" % (want_r, want_f & cm)))
    if n_diff == 0:
        summ = "SAME-AS-SHL in every row: /6 is SHL (the fixed z486 fork, NP2kai)"
    elif diff_c1_only_of:
        summ = "DIFF on OF only, count 1 only: /6 by one does not write OF as SHL does (the old z486)"
    else:
        summ = "DIFF on %s beyond OF-at-count-1: /6 is neither SHL nor the old z486" % flag_list(diff_bits)
    out.append("summary: %d rows, %d SAME-AS-SHL, %d DIFF; %s%s" % (
        len(rows), n_same, n_diff, summ, "; /4 differs from the SDM's SHL in %d rows" % n_shl_bad if n_shl_bad else ""))
    return out


def core_cal_valid(p: bytes) -> bool:
    s, m, h, d, mw = p[0], p[1], p[2], p[3], p[4]
    return s <= 0x59 and m <= 0x59 and h <= 0x23 and 0x01 <= d <= 0x31 and 1 <= (mw >> 4) <= 0xC


def parse(text: str) -> dict:
    cap = {"sal": [], "d29": None, "sdip": [], "nmx_id": None, "nmx": [], "mpu": [], "cal": [], "cal_live": None,
           "cal_rs": None, "begins": [], "ends": [], "done": False}
    for ln in text.splitlines():
        ln = ln.strip()
        if ln.startswith("BEGIN:"):
            cap["begins"].append(ln[6:])
        elif ln.startswith("END:"):
            cap["ends"].append(ln[4:])
        elif ln.startswith("XE10Z DONE"):
            cap["done"] = True
        elif ln.startswith("SAL "):
            m = re.match(r"SAL (\w+) v=(\w{8}) i=(\w{4}) r6=(\w{8}) f6=(\w{4}) r4=(\w{8}) f4=(\w{4})", ln)
            if m:
                cap["sal"].append({"form": m.group(1), "v": int(m.group(2), 16), "i": int(m.group(3), 16),
                                   "r6": int(m.group(4), 16), "f6": int(m.group(5), 16),
                                   "r4": int(m.group(6), 16), "f4": int(m.group(7), 16)})
        elif ln.startswith("D29 "):
            cap["d29"] = [int(x, 16) for x in ln.split("=", 1)[1].split()]
        elif ln.startswith("SDIP "):
            cap["sdip"].append(dict(kv.split("=") for kv in ln.split()[1:]))
        elif ln.startswith("NMX ID "):
            cap["nmx_id"] = dict(kv.split("=") for kv in ln.split()[2:])
        elif ln.startswith("NMX F8 "):
            m = re.match(r"NMX F8 dh=(\w+) tmo=(\w+) st0=(\w+) err=(\w+) sc_sn_cl_ch_dh= ((?:\w+ ){5}) ?st=(\w+)", ln)
            if m:
                tf = [int(x, 16) for x in m.group(5).split()]
                cap["nmx"].append({"dh": int(m.group(1), 16), "tmo": int(m.group(2), 16),
                                   "err": int(m.group(4), 16), "tf": tf, "st": int(m.group(6), 16)})
        elif ln.startswith("MPU v="):
            d = dict(kv.split("=") for kv in ln.split()[1:] if "=" in kv)
            row = {"v": int(d["v"], 16), "n": int(d["n"], 16), "tmo": int(d["tmo"], 16),
                   "first": int(d["first"], 16) if d.get("first") else None,
                   "d": [int(x, 16) for x in d["d"].split(",")] if d.get("d") else []}
            cap["mpu"].append(row)
        elif ln.startswith("CAL live"):
            m = re.match(r"CAL live t0=(\w{12}) t1=(\w{12})", ln)
            if m:
                cap["cal_live"] = (bytes.fromhex(m.group(1)), bytes.fromhex(m.group(2)))
        elif ln.startswith("CAL set="):
            m = re.match(r"CAL set=(\w{12}) r0=(\w{12}) r1=(\w{12}) r2=(\w{12})", ln)
            if m:
                cap["cal"].append(tuple(bytes.fromhex(m.group(i)) for i in range(1, 5)))
        elif ln.startswith("CAL restore"):
            cap["cal_rs"] = ln
    return cap


def d29_verdict(r):
    if not r or len(r) != 8:
        return "no D29 row"
    a = r[0] & 3
    ch0 = [a, a, a, 2, 2, 2, 0]
    last = [3, 0, 2, 2, 1, 1, 1]
    lo = [x & 3 for x in r[1:]]
    hi = any(x & 0xFC for x in r)
    # PACKED: replay the writes (0D 02 0B 08 05, none, then 00 01 06 07) into four 2-bit bounds
    # starting from the as-found byte, and pack them channel 0 lowest.
    b = [(r[0] >> (2 * c)) & 3 for c in range(4)]
    packed = []
    for ws in ([0x0D], [0x02], [0x0B], [0x08], [0x05], [], [0x00, 0x01, 0x06, 0x07]):
        for w in ws:
            b[w & 3] = (w >> 2) & 3
        packed.append(b[0] | b[1] << 2 | b[2] << 4 | b[3] << 6)
    v = ("PACKED (all four bounds, channel 0 lowest)" if list(r[1:]) == packed
         else "CH0 (the step-Z0 core)" if lo == ch0 and not hi
         else "LAST (the last write's channel)" if lo == last and not hi else "OTHER")
    return "%s; reads %s%s" % (v, " ".join("%02X" % x for x in r), "; UPPER BITS SET" if hi else "")


def sdip_verdicts(rows):
    out = []
    for r in rows:
        was, wrote, got, back = (int(r[k], 16) for k in ("was", "wrote", "got", "back"))
        mask = was ^ wrote
        cls = "STORED" if got == wrote else "WITHHELD" if got == was else "OTHER"
        key = (r["bank"], r["port"], mask)
        core = SDIP_CORE.get(key, "?")
        out.append("bank %s %s bit %02X: %-8s (core %s%s)%s" % (
            "A" if r["bank"] == "80" else "B", r["port"], mask, cls, core,
            "" if core == cls else ", DIFFERS", "" if back == was else "  RESTORE FAILED back=%02X" % back))
    return out


def nmx_verdicts(cap):
    out = []
    idd = cap["nmx_id"]
    if not idd:
        return ["no NMX rows"]
    cap_n = (int(idd["w61"], 16) << 16) | int(idd["w60"], 16)
    hpa = (int(idd["w82"], 16) >> 10) & 1
    out.append("capacity %d sectors, word 82 = %s (HPA %s)" % (cap_n, idd["w82"], "supported" if hpa else "NOT supported"))
    for r in cap["nmx"]:
        sc, sn, cl, ch, dh = r["tf"]
        if r["tmo"]:
            out.append("F8 dh=%02X: TIMEOUT (tmo=%d)" % (r["dh"], r["tmo"]))
            continue
        if (r["st"] & 1) and (r["err"] & 4):
            out.append("F8 dh=%02X: ABORT st=%02X err=%02X" % (r["dh"], r["st"], r["err"]))
            continue
        lba = ((dh & 0x0F) << 24) | (ch << 16) | (cl << 8) | sn
        v = "COUNT (NP2kai, the core)" if lba == cap_n else "MAXLBA (ATA spec, qemu)" if lba == cap_n - 1 else "OTHER"
        out.append("F8 dh=%02X: st=%02X address %d = %s" % (r["dh"], r["st"], lba, v))
    return out


def mpu_models(v, n):
    q = v >> 2 or 64
    f = v & 3
    np2 = [q + STEP1[f][i & 3] for i in range(n)]
    core = [q + (1 if (i & 7) < f else 0) for i in range(n)]
    return q, f, np2, core


def mpu_verdicts(rows):
    out = []
    base = next((r for r in rows if r["v"] == 4 and len(r["d"]) >= 4), None)
    if not base:
        return ["no MPU v=04 row with intervals (no clock-to-host on this card?)"]
    unit = statistics.median(base["d"])
    out.append("one internal clock = %.0f ARTIC ticks = %.3f ms (v=04 median)" % (unit, unit * 1e3 / ARTIC_HZ))
    for r in rows:
        if not r["d"]:
            out.append("v=%02X: n=%d tmo=%d, no intervals" % (r["v"], r["n"], r["tmo"]))
            continue
        k = [round(x / unit) for x in r["d"]]
        q, f, np2, core = mpu_models(r["v"], len(k))
        # The first interval follows the 0x95 kick (the core ticks at once on it), so the pattern
        # is judged on the intervals after it, at any phase of each model's cycle.
        t = k[1:]
        rot_np2 = any(t == [q + STEP1[f][(i + s) & 3] for i in range(len(t))] for s in range(4))
        is_core = any(t == [q + (1 if ((i + s) & 7) < f else 0) for i in range(len(t))] for s in range(8))
        mean = sum(k) / len(k)
        out.append("v=%02X: mean %.3f clocks (NP2kai q+f/4 = %.3f, core q+f/8 = %.3f) seq %s -> %s" % (
            r["v"], mean, q + f / 4, q + f / 8, "".join(str(x - q) if 0 <= x - q <= 9 else "?" for x in k[:16]),
            "NP2KAI (4-phase)" if rot_np2 and not is_core else "CORE (8-phase)" if is_core and not rot_np2
            else "BOTH" if is_core else "OTHER"))
    return out


def cal_verdicts(cap):
    out = []
    if cap["cal_live"]:
        t0, t1 = cap["cal_live"]
        out.append("live: t0 %s t1 %s -> the counters %s before any set" % (
            t0.hex().upper(), t1.hex().upper(), "RUN" if t0 != t1 else "DO NOT RUN"))
    for (name, pat), row in zip(PATS, cap["cal"]):
        p, r0, r1, r2 = row
        if p != pat:
            out.append("%s: the row's pattern %s is not the table's" % (name, p.hex().upper()))
            continue
        if r0 == p:
            cls = "LOADED"
        elif r0[1:] == BASE[1:] and r0[0] in (0x00, 0x01):
            cls = "REFUSED"
        else:
            cls = "OTHER"
        core = "LOADED" if core_cal_valid(p) else "REFUSED"
        tick = "counts" if r1 != r0 else "held"
        out.append("%-26s %-7s (core %s%s); r0 %s r1 %s r2 %s (%s)" % (
            name, cls, core, "" if cls == core else ", DIFFERS", r0.hex().upper(), r1.hex().upper(),
            r2.hex().upper(), tick))
    if cap["cal_rs"]:
        out.append(cap["cal_rs"])
    return out


def report(cap) -> list[str]:
    lines = []
    missing = [b for b in cap["begins"] if b not in cap["ends"]]
    if missing:
        lines.append("HUNG in section %s (BEGIN with no END)" % missing[0])
    if not cap["done"]:
        lines.append("no XE10Z DONE row: the run did not finish")
    lines += ["[SAL]  " + x for x in sal_verdicts(cap["sal"])]
    lines.append("[D29]  " + d29_verdict(cap["d29"]))
    lines += ["[SDIP] " + x for x in sdip_verdicts(cap["sdip"])]
    lines += ["[NMX]  " + x for x in nmx_verdicts(cap)]
    lines += ["[MPU]  " + x for x in mpu_verdicts(cap["mpu"])]
    lines += ["[CAL]  " + x for x in cal_verdicts(cap)]
    return lines


# ---- selftest: captures planted from each model --------------------------------------------
def plant(model: str) -> str:
    """A capture as the core (model 'core') or as the alternative models ('alt') would print it."""
    core = model == "core"
    L = ["XE10Z v2 sel=3F", "BEGIN:SAL"]
    for name in SAL_FORMS:
        _op, _rm, w, c = sal_form(name)
        for v in SAL_VALS[w]:
            for fi in SAL_FI:
                r4, f4 = shl_model(w, c, v, fi)
                r6, f6 = shl_model(w, c, v, fi, "keep" if core else "shl")
                # AF is undefined: plant a /6 AF unlike /4's, which the comparison must ignore
                f6 ^= FL_AF if c else 0
                L.append("SAL %s v=%08X i=%04X r6=%08X f6=%04X r4=%08X f4=%04X" % (name, v, fi, r6, f6, r4, f4))
    L += ["END:SAL", "BEGIN:D29"]
    r = [0, 0, 0, 0, 2, 2, 2, 0] if core else [0, 3, 0, 2, 2, 1, 1, 1]
    L += ["D29 asfound w0D w02 w0B w08 w05 again final = " + " ".join("%02X" % x for x in r) + " ", "END:D29"]
    L.append("BEGIN:SDIP")
    for (b, p, m), c in SDIP_CORE.items():
        was = 0x8F if (b, p) == ("C0", "841E") else 0x7C if p == "841E" else 0x76
        cls = c if core else "STORED"
        got = (was ^ m) if cls == "STORED" else was
        L.append("SDIP bank=%s port=%s was=%02X wrote=%02X got=%02X back=%02X" % (b, p, was, was ^ m, got, was))
    L += ["END:SDIP", "BEGIN:NMX",
          "NMX ID bank=00 dh0=A0 idok=01 st=50 w60=3520 w61=0000 w82=4200 w83=4000 w86=0000"]
    cap_n = 0x3520 if core else 0x3520 - 1
    sn, cl, ch = cap_n & 0xFF, (cap_n >> 8) & 0xFF, (cap_n >> 16) & 0xFF
    for dh in (0xE0, 0xA0):
        L.append("NMX F8 dh=%02X tmo=00 st0=50 err=00 sc_sn_cl_ch_dh= 01 %02X %02X %02X %02X  st=50" % (
            dh, sn, cl, ch, dh))
    L += ["END:NMX", "BEGIN:MPU", "MPU reset ack=FE"]
    for v in range(4, 12):
        q, f, np2, cm = mpu_models(v, 32)
        seq = cm if core else np2
        L.append("MPU v=%02X ack=FE n=21 oth=00 tmo=00 first=0010 d=%s" % (v, ",".join("%04X" % (1536 * k) for k in seq)))
    L += ["END:MPU", "BEGIN:CAL", "CAL live t0=000010101A10 t1=010010101A10"]
    for name, p in PATS:
        loaded = core_cal_valid(p) if core else True
        r0 = p if loaded else BASE
        L.append("CAL set=%s r0=%s r1=%s r2=%s" % (p.hex().upper(), r0.hex().upper(), r0.hex().upper(), r0.hex().upper()))
    L += ["CAL restore secs=0022 set=000000000000 r0=000000000000", "END:CAL", "XE10Z DONE"]
    return "\r\n".join(L) + "\r\n"


def selftest() -> int:
    bad = 0
    c = report(parse(plant("core")))
    a = report(parse(plant("alt")))
    sal_c = [x for x in c if x.startswith("[SAL]")]
    sal_a = [x for x in a if x.startswith("[SAL]")]
    # a planted /6 that differs from SHL on a result bit (and so on ZF too) must not pass as either model
    bad_sal = plant("alt").replace("SAL D1r16c1 v=A5A54000 i=02D7 r6=A5A58000", "SAL D1r16c1 v=A5A54000 i=02D7 r6=A5A50000")
    sal_b = [x for x in report(parse(bad_sal)) if x.startswith("[SAL]")]
    n_rows = sum(len(SAL_VALS[sal_form(f)[2]]) * len(SAL_FI) for f in SAL_FORMS)
    # the core's DIFF rows: count 1, OF-in unlike CF XOR the top bit (two of the four values per image)
    n_c1 = sum(1 for f in SAL_FORMS if sal_form(f)[3] == 1) * 4
    checks = [
        ("core SAL rows parsed", sum(1 for x in sal_c if " v=" in x) == n_rows),
        ("core SAL DIFF on OF at count 1", sum("DIFF (OF)" in x for x in sal_c) == n_c1
         and any("DIFF on OF only, count 1 only" in x for x in sal_c)),
        ("core SAL count 0/2 rows SAME", all("SAME-AS-SHL" in x for x in sal_c if re.search(r"c[02] ", x))),
        ("alt SAL all SAME (AF masked)", any("SAME-AS-SHL in every row" in x for x in sal_a)),
        ("SAL /4 checked against the SDM", not any("NOT THE SDM" in x for x in sal_c + sal_a)),
        ("bad SAL result flagged", any("neither SHL nor the old z486" in x for x in sal_b)
         and any("DIFF (result)" in x for x in sal_b)),
        ("core D29", any("CH0 (the step-Z0 core)" in x for x in c)),
        ("alt D29", any("LAST" in x for x in a)),
        ("machine D29 PACKED", "PACKED" in d29_verdict(bytes([0x00, 0x0C, 0x0C, 0x8C, 0x8E, 0x86, 0x86, 0x50]))),
        ("core SDIP all agree", not any("DIFFERS" in x for x in c if x.startswith("[SDIP]"))),
        ("alt SDIP bank B 841E differs", any("bank B 841E bit 02: STORED" in x and "DIFFERS" in x for x in a)),
        ("core NMX COUNT", sum("COUNT" in x for x in c) == 2),
        ("alt NMX MAXLBA", sum("MAXLBA" in x for x in a) == 2),
        ("core MPU 8-phase", sum("CORE (8-phase)" in x for x in c) == 6),
        ("alt MPU 4-phase", sum("NP2KAI (4-phase)" in x for x in a) == 6),
        ("core CAL agrees", not any("DIFFERS" in x for x in c if x.startswith("[CAL]"))),
        ("alt CAL differs on P1", any(x.startswith("[CAL]  P1 ") and "DIFFERS" in x for x in a)),
        ("no hang flagged", not any("HUNG" in x for x in c + a)),
    ]
    for name, ok in checks:
        print("%s %s" % ("ok  " if ok else "FAIL", name))
        bad += not ok
    print("selftest: %s" % ("PASS" if not bad else "FAIL"))
    return 1 if bad else 0


def main(argv) -> int:
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) not in (2, 3):
        print(__doc__)
        return 2
    reps = []
    for p in argv[1:]:
        with open(p, "rb") as fh:
            reps.append(report(parse(fh.read().decode("ascii", "replace"))))
    for i, rep in enumerate(reps):
        print("== %s" % argv[1 + i])
        for x in rep:
            print("  " + x)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

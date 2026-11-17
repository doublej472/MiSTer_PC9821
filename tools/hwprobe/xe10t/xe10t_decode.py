#!/usr/bin/env python3
"""xe10t_decode.py - decode, check and compare XE10T captures (tools/hwprobe/xe10t/xe10t.s).

Usage:
    python3 tools/hwprobe/xe10t/xe10t_decode.py XE10T.TXT                 # check + tables
    python3 tools/hwprobe/xe10t/xe10t_decode.py MACHINE.TXT CORE.TXT      # side by side
            [--band PCT] [--force]
    python3 tools/hwprobe/xe10t/xe10t_decode.py XE10T.TXT --emit-expect OUT.expect
    python3 tools/hwprobe/xe10t/xe10t_decode.py XE10T.TXT --binary XE10T.COM
    python3 tools/hwprobe/xe10t/xe10t_decode.py --stamp XE10T.COM         # build step
    python3 tools/hwprobe/xe10t/xe10t_decode.py --check-source xe10t.s    # build step
    python3 tools/hwprobe/xe10t/xe10t_decode.py --selftest

The capture grammar (header, BEGIN/END sections with a CRC-16 per section, R/P/T/X rows, the
CRC-32 DONE line, the stamp block) is written out in tools/hwprobe/xe10t/README.md; this file
implements it. The decoder never parses RTL: its machine-side output is the `.expect` file
(`--emit-expect`), one derived quantity per line with the capture line it comes from.

What it does with a capture:
  * integrity: grammar, BEGIN/END pairing, each section's rows= and sum= (CRC-16/CCITT-FALSE),
    the DONE line's CRC-32, truncation by section (naming the section's last `ROW` line, which
    the probe commits before each device row, so a hang's culprit is the last one written),
    IMAGE-CORRUPT (header crc != imgcrc);
    every TIMEOUT / WATCHDOG / RESTORE FAIL / SKIP / FAULT is listed;
  * CAL: PIT counts per ARTIC tick (sum of the PITWIN windows), the PIT modulus, VSYNC ticks
    per frame (flagging an edge window that is not a whole number of frames - the probe2 W5
    fencepost), TSC MHz and the probe's own verdict; a CAL FAIL marks every timed row untrusted;
  * R rows: gross ns/unit from the ARTIC median, the PIT cross-check after unwrapping, net
    (body - control medians) for nop=0 rows, spread and plausibility flags, CONTROL-MISMATCH
    (shell != bshell: the control is not the body minus its access, R3) refuses the row;
  * spacing sweeps (one TAG at several nop values): the device period (gross plateau while
    gross exceeds control + the access's issue cost), the shell, the issue cost, the knee
    and the fit residual;
  * T rows: min/med/max with ns conversions.

Exit status: 0 clean, 1 an integrity/trust flag was raised, 2 usage or a refused comparison.
A `--legacy` parser for the superseded timing probes' captures is future work.
"""
import functools
import hashlib
import re
import statistics
import sys
import zlib

ARTIC_HZ = 307_200
TICK_NS = 1e9 / ARTIC_HZ             # 3255.208 ns
NOM_RATIO = 8.0                      # PIT counts per ARTIC tick at 2.4576 MHz
NOM_FRAMES = (5445.0, 4384.7)        # ARTIC ticks per frame: 24 kHz (CRT31K.TXT), 31 kHz
STAMP_MARK = b"XE10T-STAMP-V1:#"
STAMP_LEN = 24                       # 16 sha hex + 8 crc hex

SECTIONS = ("SELFTEST DRY ID CAL CPU GVRAM GRCG EGC PEGC TEXT IO PAL IRQ OPNA PCM86 IDE FDC FDC2 "
            "CD OPNA2 BIOS RASTER OPNA3 AUDIT OPNA4 AUDIT2 MISAL MISAL2 RDLAT PKAB CELLS K3M RESTORE").split()
# /RASTER's raster geometry: the 24 kHz SYNC block is 400 active lines + 7 front porch + 8
# VSYNC + 25 back porch = 440 lines, VSYNC rising after line 406 (NP2kai io/gdc.c defsyncm24
# {0x10,0x4e,0x07,0x25,0x07,0x07,0x90,0x65}: VS 8, VFP 7, AL 400, VBP 25), and an 848-dot
# line of the 21.0526 MHz dot clock (CRT31K.TXT calibrates it against 5445 ticks/frame).
RASTER_LINES = 440
RASTER_VSYNC_LINE = 407
DOT_NS = 1e9 / 21_052_600
MEAS = ("R", "P", "T", "X")
OTHER = ("I", "STATE", "SKIP", "TIMEOUT", "WATCHDOG", "RESTORE", "FAULT", "SELF", "PLAN", "ROW")


def last_row(sec):
    """The last `ROW <SEC> <tag> [port=..]` line of a section: the probe writes and commits
    it before the row runs, so in a section cut off by a hang it names the culprit."""
    rows = [l for l in sec["lines"] if l.text.startswith("ROW ")]
    return (" (last %s, line %d)" % (rows[-1].text, rows[-1].no)) if rows else ""
# flags that make the capture (or a row) unusable as evidence -> exit 1
ERRORS = {"TRUNCATED", "SUM-BAD", "ROWS-MISMATCH", "DONE-MISSING", "DONE-BAD", "IMAGE-CORRUPT",
          "GRAMMAR", "NESTING", "CONTROL-MISMATCH", "RESTORE-FAIL", "WATCHDOG", "CAL-FAIL",
          "GARBAGE", "PHASE-MISALIGNED", "HEADER-MISSING"}

HEADER_RE = re.compile(r"^XE10T v(\S+) sha=([0-9a-fA-F]{16}) crc=([0-9a-fA-F]{8}) "
                       r"imgcrc=([0-9a-fA-F]{8}) size=(\d+) build=(.*?) args=(.*) tag=(.*)$")
DONE_RE = re.compile(r"^XE10T DONE sections=(\d+) sum=([0-9a-fA-F]{8})$")
END_RE = re.compile(r"^END:(\S+) rows=(\d+) sum=([0-9a-fA-F]{4})$")


# ----------------------------------------------------------------------------- checksums
def crc16(data, crc=0xFFFF):
    """CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no xorout."""
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def to_crlf(b):
    return b.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")


def crc_ok(raw, want, fn):
    """Check a CRC over raw bytes; a capture converted to LF is re-tried as CRLF."""
    if fn(raw) == want:
        return True
    return b"\r" not in raw and fn(to_crlf(raw)) == want


# ----------------------------------------------------------------------------- stamp
def stamp_fields(img):
    i = img.find(STAMP_MARK)
    if i < 0 or img.find(STAMP_MARK, i + 1) >= 0:
        raise ValueError("stamp marker %r missing or not unique" % STAMP_MARK)
    j = i + len(STAMP_MARK)
    zeroed = img[:j] + b"0" * STAMP_LEN + img[j + STAMP_LEN:]
    sha = hashlib.sha256(zeroed).hexdigest()[:16]
    # the CRC covers the constant part only: the little-endian word after the digits is its
    # length (the program's mutable variables follow it, so a run-time CRC can match)
    n = int.from_bytes(img[j + STAMP_LEN:j + STAMP_LEN + 2], "little")
    if not 0 < n <= len(img):
        n = len(img)
    crc = "%08X" % crc32(zeroed[:n])
    return j, sha, crc


def stamp_bytes(img):
    j, sha, crc = stamp_fields(img)
    return img[:j] + (sha + crc).encode() + img[j + STAMP_LEN:], sha, crc


def do_stamp(path):
    img = open(path, "rb").read()
    out, sha, crc = stamp_bytes(img)
    if out != img:
        open(path, "wb").write(out)
    print("stamped %s sha=%s crc=%s size=%d" % (path, sha, crc, len(out)))
    return 0


# ----------------------------------------------------------------------------- parsing
def num(v):
    """An int field; '-' (unmeasured) or a missing/garbled value -> None."""
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def triple(s):
    a = s.split("/")
    if len(a) != 3:
        raise ValueError(s)
    return tuple(int(x) for x in a)


def kv(tokens):
    d = {}
    for t in tokens:
        if "=" in t:
            k, v = t.split("=", 1)
            d[k] = v
    return d


class Line:
    __slots__ = ("no", "text", "start", "end")

    def __init__(self, no, text, start, end):
        self.no, self.text, self.start, self.end = no, text, start, end


class Capture:
    def __init__(self, name):
        self.name = name
        self.header = None
        self.flags = []            # (lineno, code, detail)
        self.sections = []         # dicts: name, begin, end, lines, closed
        self.rows = []             # parsed measurement / info rows
        self.done = None
        self.cal = {}
        self.untrusted = False
        self.analysed = {}         # analyser name -> its (text, expect) result, see analyser()

    def flag(self, no, code, detail=""):
        self.flags.append((no, code, detail))

    def errors(self):
        return [f for f in self.flags if f[1] in ERRORS]


ANALYSER_ERRORS = (KeyError, TypeError, ValueError, IndexError, ZeroDivisionError)


def analyser(fn):
    """A section analyser runs ONCE per capture: report(), expect_lines() and compare() each ask
    for its result, and the flags it raises (PAST-BLANK, SYNC-TIMEOUT, REP-SPREAD, ...) must land
    once, not once per caller. A malformed row it cannot read (a field missing or not a number,
    in a hung or noisy capture) costs that section only: GRAMMAR is flagged at the section's
    BEGIN and the analyser yields no text and no expect tuples, instead of aborting the whole
    report."""
    name = fn.__name__

    @functools.wraps(fn)
    def run(cap):
        memo = cap.analysed
        if name not in memo:
            try:
                memo[name] = fn(cap)
            except ANALYSER_ERRORS as e:
                sec = next((x for x in cap.sections if x["name"].lower() == name), None)
                cap.flag(sec["begin"].no if sec else 0, "GRAMMAR",
                         "%s analyser: %s: %s (section not decoded)" % (name, type(e).__name__, e))
                memo[name] = ([], [])
        return memo[name]
    return run


def split_lines(data):
    """-> list of Line; trailing ^Z/NULs stripped; a final unterminated line is kept."""
    end = len(data)
    while end and data[end - 1] in (0x1A, 0x00):
        end -= 1
    lines, pos, no = [], 0, 0
    while pos < end:
        nl = data.find(b"\n", pos, end)
        no += 1
        if nl < 0:
            lines.append((no, data[pos:end], pos, end, False))
            break
        stop = nl - 1 if nl > pos and data[nl - 1] == 0x0D else nl
        lines.append((no, data[pos:stop], pos, nl + 1, True))
        pos = nl + 1
    return lines


def parse_row(cap, ln, sec):
    t = ln.text.split()
    kind = t[0]
    row = {"kind": kind, "line": ln.no, "sec": t[1] if len(t) > 1 else "?", "flags": []}
    if kind in ("R", "P", "T", "X"):
        if len(t) < 3:
            cap.flag(ln.no, "GRAMMAR", ln.text)
            return None
        row["tag"] = t[2]
        row["kv"] = kv(t[3:])
    else:
        row["tag"] = t[2] if len(t) > 2 and "=" not in t[2] else ""
        row["kv"] = kv(t[2:])
        row["text"] = ln.text
    if kind == "SELF":                       # SELF <check> <OK|FAIL>: no section word
        row["sec"], row["tag"] = sec, t[1] if len(t) > 1 else ""
    if row["sec"] != sec and kind != "PLAN":   # PLAN <SEC> names the planned section
        cap.flag(ln.no, "GRAMMAR", "row section %s inside %s" % (row["sec"], sec))
    if kind == "R":
        d = row["kv"]
        try:
            row["n"] = int(d["n"])
            row["nop"] = int(d["nop"])
            row["rep"] = int(d["rep"])
            for f in ("art", "pit", "ctl_art", "ctl_pit"):
                row[f] = triple(d[f])
            row["shell"], row["bshell"] = d["shell"].upper(), d["bshell"].upper()
            row["to"] = int(d.get("to", "0"))
            row["if1"] = int(d["if1"]) if d.get("if1", "-").isdigit() else None
            row["unit"] = d["unit"]
        except (KeyError, ValueError) as e:
            cap.flag(ln.no, "GRAMMAR", "R row: %s" % e)
            return None
        if row["n"] <= 0:
            cap.flag(ln.no, "GRAMMAR", "n=0")
            return None
    elif kind == "T":
        row["fields"] = {}
        for k, v in row["kv"].items():
            if "/" in v:
                try:
                    row["fields"][k] = triple(v)
                except ValueError:
                    cap.flag(ln.no, "GRAMMAR", "T field %s=%s" % (k, v))
    return row


def parse(data, name="capture"):
    cap = Capture(name)
    raw = split_lines(data)
    if not raw:
        cap.flag(0, "TRUNCATED", "empty capture")
        return cap
    cur = None
    for no, b, start, end, term in raw:
        try:
            text = b.decode("ascii")
        except UnicodeDecodeError:
            cap.flag(no, "GARBAGE", "non-ASCII bytes")
            continue
        if not term:
            cap.flag(no, "TRUNCATED", "unterminated last line %r" % text[:40])
            continue
        ln = Line(no, text, start, end)
        if text.startswith("XE10T DONE"):
            m = DONE_RE.match(text)
            if not m:
                cap.flag(no, "GRAMMAR", text)
                continue
            if cur:
                cap.flag(cur["begin"].no, "TRUNCATED", "BEGIN:%s has no END%s" % (cur["name"], last_row(cur)))
                cur = None
            cap.done = (ln, int(m.group(1)), int(m.group(2), 16))
            continue
        if text.startswith("XE10T "):
            m = HEADER_RE.match(text)
            if not m or cap.header:
                cap.flag(no, "GRAMMAR", "header: " + text)
                continue
            cap.header = dict(zip(("ver", "sha", "crc", "imgcrc", "size", "build", "args", "tag"),
                                  m.groups()), line=no)
            continue
        if text.startswith("BEGIN:"):
            if cur:
                cap.flag(cur["begin"].no, "TRUNCATED", "BEGIN:%s has no END%s" % (cur["name"], last_row(cur)))
            nm = text[6:]
            if nm not in SECTIONS:
                cap.flag(no, "GRAMMAR", "unknown section " + nm)
            cur = {"name": nm, "begin": ln, "lines": [], "closed": False, "fault": False,
                   "pass": sum(1 for x in cap.sections if x["name"] == nm)}   # XE10Y /REP n
            cap.sections.append(cur)
            continue
        if text.startswith("END:"):
            m = END_RE.match(text)
            if not m or not cur or m.group(1) != cur["name"]:
                cap.flag(no, "NESTING", text)
                cur = None
                continue
            cur["closed"] = True
            cur["end"] = ln
            if "wd_test" in cur:            # a SELFTEST watchdog with no SELF WATCHDOG OK
                cap.flag(cur["wd_test"], "WATCHDOG", "SELFTEST watchdog without SELF OK")
            body = data[cur["begin"].end:start]
            if not crc_ok(body, int(m.group(3), 16), crc16):
                cap.flag(no, "SUM-BAD", "section %s sum=%s computed %04X" %
                         (cur["name"], m.group(3), crc16(body)))
            nrows = sum(1 for l in cur["lines"] if l.text.split(" ", 1)[0] in MEAS)
            if nrows != int(m.group(2)):
                cap.flag(no, "ROWS-MISMATCH", "%s rows=%s counted %d" %
                         (cur["name"], m.group(2), nrows))
            cur = None
            continue
        if cur is None:
            if text.strip():
                cap.flag(no, "GRAMMAR", "outside a section: " + text[:60])
            continue
        cur["lines"].append(ln)
        kind = text.split(" ", 1)[0]
        if kind not in MEAS + OTHER:
            cap.flag(no, "GRAMMAR", text[:60])
            continue
        row = parse_row(cap, ln, cur["name"])
        if row is None:
            continue
        row["section"] = cur
        row["pass"] = cur["pass"]
        cap.rows.append(row)
        if kind == "FAULT":
            cur["fault"] = True
            cap.flag(no, "FAULT", text)
        elif kind == "WATCHDOG":
            if cur["name"] == "SELFTEST":
                cur["wd_test"] = no         # the self-test's intended watchdog: needs SELF OK
            else:
                cap.flag(no, "WATCHDOG", text)
        elif kind == "TIMEOUT":
            cap.flag(no, "TIMEOUT", text)
        elif kind == "SKIP":
            cap.flag(no, "SKIP", text)
        elif kind == "RESTORE" and text.rstrip().endswith("FAIL"):
            cap.flag(no, "RESTORE-FAIL", text)
        elif kind == "SELF" and " FAIL" in text:
            cap.flag(no, "SELF-FAIL", text)
        elif kind == "SELF" and text.startswith("SELF WATCHDOG OK"):
            cur.pop("wd_test", None)
    if cur:
        cap.flag(cur["begin"].no, "TRUNCATED", "BEGIN:%s has no END%s" % (cur["name"], last_row(cur)))
    if cap.header is None:
        cap.flag(0, "HEADER-MISSING", "no XE10T header line")
    elif cap.header["crc"].upper() != cap.header["imgcrc"].upper():
        cap.flag(cap.header["line"], "IMAGE-CORRUPT",
                 "crc=%s imgcrc=%s" % (cap.header["crc"], cap.header["imgcrc"]))
    # /REP n (XE10Y): every analysis reads the first pass (cap.rows); cap.all_rows keeps every
    # pass for the spread table (rep_spread) and the sections that read across passes
    cap.all_rows = cap.rows
    cap.rows = [r for r in cap.all_rows if r["pass"] == 0]
    if cap.done is None:
        cap.flag(0, "DONE-MISSING", "no XE10T DONE line: the run was truncated")
    else:
        ln, nsec, want = cap.done
        if not crc_ok(data[:ln.start], want, crc32):
            cap.flag(ln.no, "DONE-BAD", "sum=%08X computed %08X" % (want, crc32(data[:ln.start])))
        closed = sum(1 for s in cap.sections if s["closed"])
        if nsec != closed:
            cap.flag(ln.no, "DONE-BAD", "sections=%d, %d closed" % (nsec, closed))
    analyse(cap)
    return cap


# ----------------------------------------------------------------------------- analysis
def analyse(cap):
    cal_calibrate(cap)
    for r in getattr(cap, "all_rows", cap.rows):
        if r["kind"] == "R":
            r_row(cap, r)
        if r["kind"] in ("R", "T"):
            if r["section"]["fault"]:
                r["flags"].append("AFTER-FAULT")
            if cap.untrusted:
                r["flags"].append("UNTRUSTED")
    cap.sweeps = sweeps(cap)


def cal_calibrate(cap):
    c = cap.cal
    info = [r for r in cap.rows if r["kind"] == "I" and r["sec"] == "CAL"]
    for r in info:
        c.update(r["kv"])
        c["info_line"] = r["line"]
    pw = [r for r in cap.rows if r["kind"] == "P" and r["sec"] == "CAL" and r["tag"] == "PITWIN"]
    pw = [r for r in pw if num(r["kv"].get("art")) and num(r["kv"].get("pit")) is not None]
    sa = sum(num(r["kv"]["art"]) for r in pw)
    sp = sum(num(r["kv"]["pit"]) for r in pw)
    if sa > 0:
        c["ratio"] = sp / sa
        c["ratio_line"] = pw[0]["line"]
    elif "ratio_x1000" in c and c["ratio_x1000"].isdigit():
        c["ratio"] = int(c["ratio_x1000"]) / 1000.0
    c["mod"] = num(c.get("pit_mod")) or 65536
    vs = []
    for r in cap.rows:
        if r["kind"] != "P" or r["sec"] != "CAL":
            continue
        d = r["kv"]
        art, edges = num(d.get("art")), num(d.get("edges"))
        if r["tag"] == "PITEDGE" and edges and art:
            per = art / edges          # edges = full periods between first and last edge
            c["pitedge_ticks"] = per
            c["pitedge_mod"] = per * c.get("ratio", NOM_RATIO)
        elif r["tag"] == "VSYNC" and edges and art:
            tpf = art / edges
            vs.append((r, art, edges, tpf))
            c.setdefault("vsync_ticks", tpf)
            c.setdefault("vsync_line", r["line"])
            c.setdefault("vsync_hz", ARTIC_HZ / tpf)
            ts = num(d.get("tsc"))
            if ts:
                c["vsync_tsc_mhz"] = ts / (art / ARTIC_HZ) / 1e6
        elif r["tag"] == "TSC" and art and num(d.get("tsc")):
            c["tsc_mhz"] = num(d["tsc"]) / (art / ARTIC_HZ) / 1e6
    # A window that does not hold `edges` whole periods (an arbitrary-phase start: the probe2
    # W5 fencepost) shows as a ticks/period off the frame by more than 0.5%, or off another
    # VSYNC row of the same capture by more than 0.5%.
    for r, art, edges, tpf in vs:
        nom = min(NOM_FRAMES, key=lambda f: abs(f - tpf))
        others = [t for q, _, _, t in vs if q is not r]
        if abs(tpf - nom) / nom > 0.005 or any(abs(tpf - t) / t > 0.005 for t in others):
            cap.flag(r["line"], "PHASE-MISALIGNED",
                     "VSYNC art=%d edges=%d -> %.2f ticks/period (%.2f periods of %.1f)" %
                     (art, edges, tpf, art / nom, nom))
        elif abs(tpf - nom) > 2:
            cap.flag(r["line"], "VSYNC-OFF-NOMINAL", "%.2f ticks/frame against %.1f" % (tpf, nom))
    if c.get("verdict", "OK") != "OK" and info:
        cap.untrusted = True
        cap.flag(c["info_line"], "CAL-FAIL", "verdict=%s why=%s" % (c["verdict"], c.get("why", "?")))


def ratio_of(cap):
    return cap.cal.get("ratio", NOM_RATIO)


def unwrap(cap, art, pit):
    mod, ratio = cap.cal.get("mod", 65536), ratio_of(cap)
    if mod <= 0:
        return pit
    k = round((art * ratio - pit) / mod)
    return pit + max(k, 0) * mod


def r_row(cap, r):
    n, f = r["n"], r["flags"]
    a, c = r["art"], r["ctl_art"]
    r["gross_ns"] = a[1] * TICK_NS / n
    r["ctl_ns"] = c[1] * TICK_NS / n
    ratio = ratio_of(cap)
    pu = unwrap(cap, a[1], r["pit"][1])
    r["pit_ns"] = pu * 1e9 / (ratio * ARTIC_HZ) / n
    # The two time bases are compared on the body-minus-control difference: each window's
    # ARTIC column starts on an edge and its PIT column a few microseconds later (the reads
    # are sequential), a constant offset that cancels in the difference. Tolerance: 0.1 %
    # of a long window, else 2 ARTIC ticks (each column quantizes to one tick).
    pc = unwrap(cap, c[1], r["ctl_pit"][1])
    r["ctl_pit_ns"] = pc * 1e9 / (ratio * ARTIC_HZ) / n
    d_art, d_pit = a[1] - c[1], pu - pc
    exp = d_art * ratio
    tol = max(0.001 * abs(exp), 2 * ratio)
    if abs(d_pit - exp) > tol:
        f.append("PIT-DISAGREE")
    if (a[2] - a[0]) > max(0.02 * a[1], 1) or (c[2] - c[0]) > max(0.02 * c[1], 1):
        f.append("SPREAD")
    if r["shell"] != r["bshell"]:
        f.append("CONTROL-MISMATCH")
        r["refused"] = True
        cap.flag(r["line"], "CONTROL-MISMATCH", "%s %s shell=%s bshell=%s" %
                 (r["sec"], r["tag"], r["shell"], r["bshell"]))
    if r["to"]:
        f.append("POLL-TIMEOUT")
    i1 = r.get("if1")
    if i1 is not None and abs(i1 - a[1]) > max(0.02 * a[1], 1):
        f.append("IF1-NOISE")                # the IF=1 window differs from the cli median
    if r["nop"] == 0:
        r["net_ns"] = (a[1] - c[1]) * TICK_NS / n
        if a[1] - c[1] < -1:
            f.append("NET-NEGATIVE")
        if r["net_ns"] > 50_000 and "KiB" not in r["unit"]:
            f.append("NET-HUGE")


def fit_sweep(points):
    """points: [(k, gross_ns, ctl_ns, tick_ns_per_unit)] sorted by k.
    -> dict(period, shell, issue, knee, residual, flag).

    The excess d = gross - control is the device wait plus the access's own issue cost: the
    control leaves the access instruction out, so once the CPU side (shell + k nops + the
    access) is longer than the device period, gross follows control + issue, not control.
    The issue cost is the excess at the largest k, trusted only when the two largest k agree
    (within 2 % of gross or one tick per unit) or it is nil (gross = control); then the plateau is every point whose excess
    is above it, the period its median gross, and the knee the first k past the plateau. A
    sweep whose last two excesses disagree never left the plateau (KNEE-NOT-FOUND: the period
    is the median gross of the whole sweep); points above the line whose gross climbs with k
    are an issue-cost wobble, not a device wait (PLATEAU-NOT-FLAT); one with no point above the issue line has no
    visible device period (NO-PLATEAU: the period is at most the k=0 gross)."""
    tol = [max(0.02 * g, q) for _, g, _, q in points]
    d = [g - c for _, g, c, _ in points]
    res = {"shell": points[0][2], "knee": None, "flag": "", "issue": None, "bound": ""}
    if len(points) >= 2 and (abs(d[-1] - d[-2]) <= max(tol[-1], tol[-2]) or d[-1] <= tol[-1]):
        e = d[-1]
        res["issue"] = e
        over = [i for i in range(len(points)) if d[i] > e + tol[i]]
        if not over:
            res.update(period=points[0][1], flag="NO-PLATEAU", bound="<=")
        else:
            res["period"] = statistics.median(points[i][1] for i in over)
            res["knee"] = points[over[-1] + 1][0]
            pg = [points[i][1] for i in over]
            if max(pg) - min(pg) > 2 * max(0.02 * res["period"], max(tol[i] for i in over)):
                res["flag"] = "PLATEAU-NOT-FLAT"     # gross climbs with k: no device period
        model = [max(res["period"], c + e) for _, _, c, _ in points]
    else:
        res.update(period=statistics.median(g for _, g, _, _ in points), flag="KNEE-NOT-FOUND")
        model = [res["period"]] * len(points)
    errs = [(m - g) / g for m, (_, g, _, _) in zip(model, points) if g > 0]
    res["residual"] = (sum(e * e for e in errs) / len(errs)) ** 0.5 if errs else 0.0
    return res


def sweeps(cap):
    groups = {}
    for r in cap.rows:
        if r["kind"] == "R" and not r.get("refused"):
            groups.setdefault((r["sec"], r["tag"]), []).append(r)
    out = {}
    for key, rows in groups.items():
        if len({r["nop"] for r in rows}) < 2:
            continue
        rows.sort(key=lambda r: r["nop"])
        pts = [(r["nop"], r["gross_ns"], r["ctl_ns"], TICK_NS / r["n"]) for r in rows]
        res = fit_sweep(pts)
        res["line"] = rows[0]["line"]
        res["rows"] = rows
        out[key] = res
        if res["flag"]:
            cap.flag(rows[0]["line"], res["flag"], "%s %s" % key)
    return out


def raster_rows(cap):
    """/RASTER's P rows -> derived dicts: where the phase's writes landed (in raster lines
    after the VSYNC rising edge, and as the display line that is), how long a write burst
    took, and for the toggle phases the length of one `out` in dots - the dash a
    dot-immediate palette paints. The picture itself is the evidence; these say where to
    look and what size the features should be."""
    out = []
    tpf = cap.cal.get("vsync_ticks", NOM_FRAMES[0])
    line_ticks = tpf / RASTER_LINES
    for r in cap.rows:
        if r["kind"] != "P" or r["sec"] != "RASTER":
            continue
        d = r["kv"]
        n = num(d.get("frames")) or 0
        res = {"tag": r["tag"], "line": r["line"], "frames": n, "to": num(d.get("to")) or 0}
        if n:
            at = num(d["at_sum"]) / n
            dur = num(d["dur_sum"]) / n
            res["at_lines"] = at / line_ticks
            res["display_line"] = (RASTER_VSYNC_LINE + res["at_lines"]) % RASTER_LINES
            res["jitter_lines"] = (num(d["at_max"]) - num(d["at_min"])) / line_ticks
            res["burst_us"] = dur * TICK_NS / 1000
            res["band_lines"] = dur / line_ticks
            outs = num(d.get("outs")) or 0
            if r["tag"] != "SPLIT" and outs:
                res["ns_per_out"] = dur * TICK_NS / outs
                res["dots_per_out"] = res["ns_per_out"] / DOT_NS
        out.append(res)
    return out


RASTER_LOOK = {
    "SPLIT": "red above the split line, green below; a single colour for the whole screen = "
             "the palette is latched per frame; a short yellow dash ON the split line = the "
             "DAC takes each write at once (G=F lands one `out` before R=0); a clean edge = "
             "it takes writes at a line boundary",
    "TOGGLE": "a band of the given height in grey; inside it dashes of light blue and olive, "
              "each ~dots_per_out long, staggered line to line = dot-immediate; whole lines "
              "of one colour = latched at each line; no band (plain grey) = latched per frame",
    "DTOGGLE": "the same three pictures for the 8-colour DIGITAL palette (blue/black dashes, "
               "whole blue/black lines, or plain black)",
}


# ----------------------------------------------------------------------------- /OPNA2
# Reference facts the /OPNA2 verdicts use (the probe records raw values only):
#  * register 0xFF: YM2608 answers 01, YMF288 02, YM2203 has no ID register and answers 0
#    above 0x0F (ymfm src/ymfm_opn.cpp ym2608::read_data `// FF: ID code` result = 1,
#    ymf288::read_data result = 2, ym2203::read_data `if (m_address < 0x10)` else 0); NP2kai's
#    -86 glue answers 1 (cbus/board86.c opna_i18a `else if (nAddress == 0xff) return 1;`),
#    its 26K glue the last byte written (cbus/board26k.c opn_i18a `return g_opna[0].s.data;`);
#  * status 0 of both chips carries only BUSY (bit 7) and the two timer flags (ymfm
#    ym2608::read_status masks to STATUS_TIMERA | STATUS_TIMERB, ymfm_opn.h STATUS_BUSY 0x80);
#  * status 1 (+4, YM2608 only): EOS 0x04, BRDY 0x08, ZERO 0x10, PCM busy 0x20 (ymfm_opn.h
#    STATUS_ADPCM_B_*);
#  * timer A counts 72 master clocks of 3.9936 MHz per step = 18.029 us (NP2kai
#    sound/opntimer.c `l = 18 * (1024 - ...)` in us units), timer B 16 times that = 288.46 us
#    (`l = 288 * (256 - opna->s.reg[0x26])`).
O2_TA_US = 72e6 / 3_993_600          # 18.029 us per timer-A count
O2_TB_US = 16 * O2_TA_US             # 288.46 us per timer-B count
AU_SAMP_TICKS = 30720               # /AUDIT's IRR sampling window (sec_audit.inc AU_SAMP)
O2_POLL_BINS = ("1", "2", "3", "4", "5-8", "9-16", "17-32", "33-64", "65+")


def hx(v):
    try:
        return int(v, 16)
    except (TypeError, ValueError):
        return None


def o2_timer_fit(T, us, kind, base):
    """-> (slope us/count, intercept us, per-read us, points) from the TMRx_ T rows, or None.

    The points are (counts, start-to-flag median us, line). The per-read time is the
    least-squares slope of the start-to-flag medians on the flag-poll read medians: the
    o2_tmr loop polls the status from the 0x27 start write to the flag, so reads x that
    time is the start-to-flag time of a trial whose own clock started earlier."""
    pts, rds = [], []
    for tag, r in T.items():
        if tag.startswith(kind) and "_288" not in tag and "_088" not in tag:
            t = r["fields"]["start_pit"][1] * us
            pts.append((base - int(tag[len(kind):], 16), t, r["line"]))
            if "reads" in r["fields"]:
                rds.append((r["fields"]["reads"][1], t))
    if len(pts) < 2:
        return None

    def ls(xy):
        n = len(xy)
        mx, my = sum(p[0] for p in xy) / n, sum(p[1] for p in xy) / n
        sxx = sum((p[0] - mx) ** 2 for p in xy)
        k = sum((p[0] - mx) * (p[1] - my) for p in xy) / sxx if sxx else 0.0
        return k, my - k * mx

    pts.sort()
    slope, icpt = ls([(c, t) for c, t, _ in pts])
    per_read = ls(rds)[0] if len(rds) >= 2 else None
    return slope, icpt, per_read, pts


def busy_class(sec, tag, r, xs, us, txt, exp, hsel=None):
    """One BUSY class (a T row with busy_pit/polls and its i=H histogram row, /OPNA2's and
    /OPNA3's format): a text line into txt, the first-poll-clear share into exp. hsel picks
    the histogram row among several (a kv dict subset); default the first i=H row."""
    h = [x for x in xs if x["kv"].get("i") == "H" and
         all(x["kv"].get(k) == v for k, v in (hsel or {}).items())]
    line = "%s: busy med %.2f us max %.2f us, polls %s" % (
        tag, r["fields"]["busy_pit"][1] * us, r["fields"]["busy_pit"][2] * us,
        "/".join(map(str, r["fields"]["polls"])))
    if h:
        ph = [int(v) for v in h[0]["kv"].get("polls_h", "").split(",") if v.isdigit()]
        th = h[0]["kv"].get("pit_h", "")
        n = sum(ph) or 1
        line += "; polls hist %s; pit hist(8) %s; first poll clear %.1f%%" % (
            " ".join("%s:%d" % (O2_POLL_BINS[i], c) for i, c in enumerate(ph) if c), th,
            100.0 * ph[0] / n if ph else 0)
        if ph:
            exp.append(("%s.%s.first_clear_pct" % (sec, tag), "%.1f" % (100.0 * ph[0] / n), "pct",
                        h[0]["line"], "histogram"))
    txt.append(line)


@analyser
def opna2(cap):
    """-> (text lines, expect tuples (name, value, unit, line, method)) for the OPNA2 rows."""
    rows = [r for r in cap.rows if r["sec"] == "OPNA2" and r["kind"] in ("X", "T")]
    if not rows:
        return [], []
    us = 1.0 / (ratio_of(cap) * ARTIC_HZ / 1e6)
    txt, exp = [], []
    T = {r["tag"]: r for r in rows if r["kind"] == "T"}

    def X(tag):
        return [r for r in rows if r["kind"] == "X" and r["tag"] == tag]

    # 1. identity per base
    for idr in X("ID"):
        d = idr["kv"]
        b = d.get("b", "?")
        st = hx(d.get("st"))
        idc = {r["kv"].get("ext"): r["kv"] for r in X("IDC") if r["kv"].get("b") == b}
        notes = []
        if st == 0xFF:
            verdict = "absent (status reads FF; +2/+4/+6 %s/%s/%s)" % (d.get("d"), d.get("e"), d.get("f"))
        else:
            ids = sorted({v.get("id") for v in idc.values()})
            idv = hx(ids[0]) if len(ids) == 1 else None
            if len(ids) > 1:
                notes.append("ID differs with the extension: %s" % "/".join(ids))
            chip = {0x01: "YM2608", 0x02: "YMF288", 0x00: "YM2203 (no ID register)",
                    0xFF: "echoes the select (26K-glue-like)"}.get(idv, "unknown ID %s" % ids)
            ssg = all(v.get("w5a") == "5A" and v.get("wa5") == "A5" for v in idc.values()) and idc
            notes.append("SSG read-back %s" % ("yes" if ssg else "NO"))
            if st is not None and st & 0x7C:
                notes.append("status bits 6-2 set (%02X): not a lone YM2608/YM2203" % st)
            e0, e1 = idc.get("0", {}), idc.get("1", {})
            s40, s41 = e0.get("s4"), e1.get("s4")
            if s40 == "FF" and s41 not in (None, "FF"):
                notes.append("0xA460 bit 0 opens +4/+6 (86-board extension gate)")
            elif s40 == "FF" and s41 == "FF":
                notes.append("+4/+6 never answer")
            elif s40 is not None:
                notes.append("+4/+6 answer with the extension closed (s4=%s/%s)" % (s40, s41))
            if e0.get("st") and e1.get("st") and e0["st"] != e1["st"]:
                notes.append("status at +0 moves with the extension (%s/%s)" % (e0["st"], e1["st"]))
            verdict = chip
            exp.append(("OPNA2.BASE%s.id" % b, ids[0] if ids else "-", "hex", idr["line"], "raw"))
        exp.append(("OPNA2.BASE%s.status" % b, d.get("st", "-"), "hex", idr["line"], "raw"))
        txt.append("base %s: %s%s" % (b, verdict, "; " + "; ".join(notes) if notes else ""))
    for tag in sorted(T):
        if "_288" in tag or "_088" in tag:
            r = T[tag]
            f = r["fields"].get("busy_pit") or r["fields"].get("start_pit")
            if f:
                txt.append("  %s: %s med %.2f us" % (tag, "busy" if "busy_pit" in r["fields"] else
                                                    "start-to-flag", f[1] * us))
    # ADPCM-B
    w = X("ADB_W")
    if w:
        brdy = [r for r in w if num(r["kv"].get("reads")) is not None and num(r["kv"]["reads"]) < 4096
                and (hx(r["kv"].get("st")) or 0) & 0x08]
        eos = [r for r in w + X("ADB_END") if (hx(r["kv"].get("st")) or 0) & 0x04]
        txt.append("ADPCM-B: BRDY after %d of %d data writes (%s)%s" % (
            len(brdy), len(w), "present: a YM2608" if brdy else "never: no ADPCM-B",
            "; EOS first at %s line %d" % (eos[0]["tag"] + " i=" + eos[0]["kv"].get("i", "-"),
                                           eos[0]["line"]) if eos else "; EOS never set"))
        exp.append(("OPNA2.ADB_W.brdy_writes", len(brdy), "count", w[0]["line"], "count"))
        setup = X("ADB_SETUP")
        if setup:
            k = setup[0]["kv"]
            txt.append("  ADPCM-B status: entered %s, after reset %s, after memory-write setup %s" %
                       (k.get("st0"), k.get("s_rst"), k.get("s_set")))
    fr = X("FR_ADB")
    if fr:
        first = sum(1 for r in fr if not (hx(r["kv"].get("st1")) or 0) & 0x0C)
        pits = sorted(num(r["kv"].get("pit")) or 0 for r in fr)
        txt.append("ADPCM-B 0x110<-80: flags clear at the first read in %d/%d; med %.2f us" %
                   (first, len(fr), pits[len(pits) // 2] * us))
        exp.append(("OPNA2.FR_ADB.first_read_clear", "%d/%d" % (first, len(fr)), "trials",
                    fr[0]["line"], "count"))
    # 2. BUSY classes
    for tag in [t for t in T if t.startswith("BUSY_")]:
        busy_class("OPNA2", tag, T[tag], X(tag), us, txt, exp)
    # back to back
    b2 = X("B2B_SSG")
    if b2:
        ok = sum(1 for r in b2 if r["kv"].get("r0b") == r["kv"].get("v1") and
                 r["kv"].get("r0c") == r["kv"].get("v2"))
        txt.append("B2B SSG pair: both writes landed in %d/%d" % (ok, len(b2)))
        exp.append(("OPNA2.B2B_SSG.both_landed", "%d/%d" % (ok, len(b2)), "trials", b2[0]["line"],
                    "count"))
    # The timer A fit (section 4's rows) times the B2B trials from their own start write.
    fa = o2_timer_fit(T, us, "TMRA_", 1024)
    for tag in ("B2B_TMR", "B2B_TMR3"):
        b = X(tag)
        if not b:
            continue
        cls = {}
        for r in b:
            t_us = (num(r["kv"].get("art")) or 0) * TICK_NS / 1000
            if not (hx(r["kv"].get("st")) or 0) & 0x01:
                n = 0           # the poll ran to its 30 ms bound: no flag (the start lost)
            elif t_us < 2000:   # short: 6 or 8 counts
                # The row's clock starts BEFORE the two load writes, and on B2B_TMR the
                # 0x27 start is BUSY-polled, so a write delayed by BUSY (about 29 us on the
                # machine for a quarter of its data writes) adds its wait to pit= and reads
                # as 8 counts. The flag-poll reads count only from the start write: at the
                # TMRA rows' per-read time they give the start-to-flag time, which the TMRA
                # fit turns into counts.
                if fa and fa[2] and fa[0] > 0:
                    t_st = (num(r["kv"].get("reads")) or 0) * fa[2]
                    n_est = (t_st - fa[1]) / fa[0]
                else:
                    n_est = (num(r["kv"].get("pit")) or 0) * us / O2_TA_US
                n = min((6, 8), key=lambda c: abs(c - n_est))
            else:               # long: 1022 or 1024 counts, or neither
                # Nominal counts: the fit's slope comes from 1-64 counts and its poll-phase
                # spread does not extrapolate to 1024 (the machine's 1024-count trials read
                # 18.05 us/count against the fit's 17.94).
                n_est = t_us / O2_TA_US
                n = min((1022, 1024), key=lambda c: abs(c - n_est))
                if abs(n - n_est) > 8:
                    n = -int(round(n_est))
            cls[n] = cls.get(n, 0) + 1
        names = {6: "both landed", 8: "0x25 lost", 1022: "0x24 lost", 1024: "both lost",
                 0: "no flag (start lost)"}
        txt.append("%s: %s" % (tag, ", ".join(
            "%s %d" % (names.get(k, "other (%d counts)" % -k), v)
            for k, v in sorted(cls.items(), key=lambda kv: abs(kv[0])))))
        exp.append(("OPNA2.%s.both_landed" % tag, "%d/%d" % (cls.get(6, 0), len(b)), "trials",
                    b[0]["line"], "count"))
    # 3. flag reset
    for tag, mask in (("FR_TMRA", 1), ("FR_TMRB", 2)):
        f = X(tag)
        if not f:
            continue
        first = sum(1 for r in f if not (hx(r["kv"].get("st1")) or 0) & mask)
        irq_up = sum(1 for r in f if (hx(r["kv"].get("irr0")) or 0) & 0x10)
        irq_after = sum(1 for r in f if (hx(r["kv"].get("irr1")) or 0) & 0x10)
        tr = T.get(tag, {"fields": {}})["fields"]
        msg = "%s: flag clear at the first read in %d/%d" % (tag, first, len(f))
        if "busy_pit" in tr:
            msg += ", reset med %.2f us" % (tr["busy_pit"][1] * us)
        msg += "; IRQ12 (slave IRR bit 4) up before %d/%d, still up at the first IRR read after %d/%d" % (
            irq_up, len(f), irq_after, len(f))
        if "irr_pit" in tr:
            msg += ", drop med %.2f us (%s IRR reads)" % (tr["irr_pit"][1] * us,
                                                         "/".join(map(str, tr["irr_reads"])))
        txt.append(msg)
        exp.append(("OPNA2.%s.first_read_clear" % tag, "%d/%d" % (first, len(f)), "trials",
                    f[0]["line"], "count"))
        exp.append(("OPNA2.%s.irq_up_after_reset" % tag, "%d/%d" % (irq_after, len(f)), "trials",
                    f[0]["line"], "count"))
        if "irr_pit" in tr:
            exp.append(("OPNA2.%s.irq_drop_us" % tag, "%.2f" % (tr["irr_pit"][1] * us), "us",
                        T[tag]["line"], "median"))
    # 4. timer start: least squares of the start-to-flag medians on the count
    for kind, per, base in (("TMRA_", O2_TA_US, 1024), ("TMRB_", O2_TB_US, 256)):
        f = o2_timer_fit(T, us, kind, base)
        if not f:
            continue
        slope, icpt, _, pts = f
        txt.append("%s start-to-flag: %s; fit %.3f us/count (nominal %.3f), intercept %.2f us "
                   "(start latency + poll)" % (kind.rstrip("_"), ", ".join(
                       "%d:%.1f" % (c, t) for c, t, _ in pts), slope, per, icpt))
        exp.append(("OPNA2.%s.period_us" % kind.rstrip("_"), "%.3f" % slope, "us", pts[0][2], "fit"))
        exp.append(("OPNA2.%s.start_us" % kind.rstrip("_"), "%.2f" % icpt, "us", pts[0][2], "fit"))
    return txt, exp


# ----------------------------------------------------------------------------- /OPNA3
# /OPNA3 writes the rhythm instrument levels 0x18-0x1D the way MDRV2 3.4F does (one BUSY poll,
# select, data, next). The rows are raw; what decides the question the section was written for
# (does the chip keep every one of six back-to-back level writes?) is the /LISTEN phases, by
# ear: the rhythm registers have no read-back. The references disagree on the mechanism:
# NP2kai sound/rhythmc.c rhythm_setreg applies every 0x18-0x1D write at once, ymfm
# adpcm_a_engine::write stores every register, the vendored jt12 keeps ONE pending level word
# (jt12_mmr `lracl`/`up_lracl`) that the rhythm gain ring takes when it reaches the drum.
O3_LISTEN_LOOK = {
    "LISTEN_SLOW": "the reference: the bass drum at level 1F, 8 hits",
    "LISTEN_B2B": "as loud as PHASE 1 = every back-to-back level write kept; quiet (about 23 dB "
                  "down, level 0) = the first write (0x18) lost",
    "LISTEN_B2B_REV": "the bass-drum write last: loud in any model; if PHASE 2 was quiet and "
                      "this is loud, the chip holds one pending level word (jt12-like)",
}


def _ints(v):
    try:
        return [int(x) for x in (v or "").split(",")]
    except ValueError:
        return []


@analyser
def opna3(cap):
    """-> (text lines, expect tuples (name, value, unit, line, method)) for the OPNA3 rows."""
    rows = [r for r in cap.rows if r["sec"] == "OPNA3" and r["kind"] in ("X", "T")]
    if not rows:
        return [], []
    us = 1.0 / (ratio_of(cap) * ARTIC_HZ / 1e6)
    txt, exp = [], []
    T = {r["tag"]: r for r in rows if r["kind"] == "T"}

    def X(tag):
        return [r for r in rows if r["kind"] == "X" and r["tag"] == tag]

    if "BUSY_RHY18" in T:
        busy_class("OPNA3", "BUSY_RHY18", T["BUSY_RHY18"], X("BUSY_RHY18"), us, txt, exp)
    o3_spacing(cap, rows, txt)
    for tag in ("B2B_RHYLVL", "B2B_RHYKEY"):
        raw = [r for r in X(tag) if (r["kv"].get("i") or "").isdigit()]
        if not raw:
            continue
        regs = {}
        for r in X(tag):
            if r["kv"].get("i") == "H" and (r["kv"].get("w") or "").isdigit():
                regs[int(r["kv"]["w"])] = r["kv"].get("reg", "?")
        polls = [_ints(r["kv"].get("polls")) for r in raw]
        pits = [_ints(r["kv"].get("pit")) for r in raw]
        dds = [_ints(r["kv"].get("dd")) for r in raw]
        nw = max(len(p) for p in polls)
        allp = [v for p in polls for v in p]
        allt = [v for p in pits for v in p]
        busy = sum(1 for v in allp if v > 1)
        n = len(allp) or 1
        spacing = sorted(v for d in dds for v in d[1:])
        msg = ("%s: %d trials x %d writes; BUSY seen after %d/%d data writes (first poll clear "
               "%.1f%%), wait med %.2f us max %.2f us" % (
                   tag, len(raw), nw, busy, len(allp), 100.0 * (len(allp) - busy) / n,
                   sorted(allt)[len(allt) // 2] * us if allt else 0, max(allt or [0]) * us))
        if spacing:
            msg += "; data-to-data spacing med %.2f us (min %.2f)" % (
                spacing[len(spacing) // 2] * us, spacing[0] * us)
        txt.append(msg)
        per = []
        for k in range(nw):
            pk = [p[k] for p in polls if len(p) > k]
            tk = sorted(t[k] for t in pits if len(t) > k)
            per.append("%s busy %d/%d max %.2f us" % (
                regs.get(k, "w%d" % k), sum(1 for v in pk if v > 1), len(pk),
                (tk[-1] if tk else 0) * us))
        txt.append("  per write: " + "; ".join(per))
        exp.append(("OPNA3.%s.busy_writes" % tag, "%d/%d" % (busy, len(allp)), "writes",
                    raw[0]["line"], "count"))
        exp.append(("OPNA3.%s.first_clear_pct" % tag, "%.1f" % (100.0 * (len(allp) - busy) / n),
                    "pct", raw[0]["line"], "count"))
        exp.append(("OPNA3.%s.busy_max_us" % tag, "%.2f" % (max(allt or [0]) * us), "us",
                    raw[0]["line"], "max"))
        if spacing:
            exp.append(("OPNA3.%s.spacing_us" % tag, "%.2f" % (spacing[len(spacing) // 2] * us),
                        "us", raw[0]["line"], "median"))
    for tag in ("LISTEN_SLOW", "LISTEN_B2B", "LISTEN_B2B_REV"):
        for r in X(tag):
            p = _ints(r["kv"].get("polls"))
            t = _ints(r["kv"].get("pit"))
            pre = r["kv"].get("pre_polls")
            txt.append("%s: regs %s, %s, polls %s (busy %d/%d, max %.2f us)%s, keys %s" % (
                tag, r["kv"].get("regs", "?"),
                "200 us apart" if r["kv"].get("slow") == "1" else "back to back",
                ",".join(map(str, p)), sum(1 for v in p if v > 1), len(p),
                max(t or [0]) * us, "; the slow C0 preset polls %s" % pre if pre else "",
                r["kv"].get("keys", "?")))
            txt.append("  listen: %s" % O3_LISTEN_LOOK[tag])
    o3_sweep(cap, us, X("SWEEP"), txt, exp)
    return txt, exp


def o3_spacing(cap, rows, txt):
    """The select-to-data spacing the binary used. A STATE OPNA3 `sd5f=N` names the `out 5Fh`
    written between every select and its data (O3_SD5F in sec_opna3.inc). A capture without it
    comes from an earlier binary: its SWEEP pair wrote each data one I/O access after its select
    (about 0.85 us on the Xe10), inside the YM2608's select synchronizer (YM2608-LLE
    fmopna_impl.c `write0_en`, 1-2 clocks of 0.75 us), so on the chip the data byte could become
    the address and the 0x18 level write go nowhere whatever the gap; its B2B and LISTEN writes
    had a PIT read (about 2.5 us on the Xe10) between select and data."""
    st = [r for r in cap.rows if r["sec"] == "OPNA3" and r["kind"] == "STATE"]
    sd = st[0]["kv"].get("sd5f") if st else None
    if sd is not None:
        txt.append("select-to-data: %s `out 5Fh` between every select and its data (sd5f=%s)"
                   % (sd, sd))
    elif any(r["tag"] == "SWEEP" for r in rows):
        txt.append("select-to-data: PRE-FIX binary (no sd5f=): the SWEEP pair's data followed "
                   "its select by one I/O access, short of the YM2608's select synchronizer; "
                   "on the chip a step can be quiet whatever its gap")
    else:
        txt.append("select-to-data: pre-sd5f binary: a PIT read between select and data")


def o3_sweep(cap, us, rows, txt, exp):
    """/OPNA3 /SWEEP: one row per step, 0x18 <- DF, the gap, 0x19 <- C0, 4 bass-drum hits.
    `pit` is the measured gap (PIT counts from the latch after the 0x18 data write to the
    latch after the 0x19 data write; the same two instructions follow each data write, so
    it is the data-to-data gap), `tgt` the target it had to reach, `fit` 1 = the fewest
    `out 5Fh` reaching the target, 2 = kept after four attempts BUSY lengthened, 0 = out of
    attempts. The answer is the ear's: the first step whose hits were loud."""
    if not rows:
        return
    plan = [r for r in cap.rows if r["sec"] == "OPNA3" and r["kind"] == "I"
            and r["tag"] == "SWEEP_PLAN"]
    pk = plan[0]["kv"] if plan else {}
    txt.append("SWEEP: %d steps (plan from=%s to=%s, ratio_x1000=%s); gap = 0x18 data write to "
               "0x19 data write" % (len(rows), pk.get("from", "?"), pk.get("to", "?"),
                                    pk.get("ratio_x1000", "?")))
    txt.append("  step target_us actual_us  pit  tgt  n5f tries busy fit  p18  p19   pa pa_us")
    bad = []
    for r in rows:
        d = r["kv"]
        step, gap, pit, tgt = num(d.get("step")), num(d.get("gap_us")), num(d.get("pit")), \
            num(d.get("tgt"))
        fit, papit = num(d.get("fit")), num(d.get("pa_pit"))
        if None in (step, gap, pit, tgt):
            cap.flag(r["line"], "GRAMMAR", "SWEEP row without step/gap_us/pit/tgt")
            continue
        note = ""
        if fit == 2:
            note = "  BUSY lengthened the gap"
        elif fit != 1:
            note = "  no fit: the last attempt stands"
        if pit < tgt:
            note += "  SHORT of the target"
            bad.append(step)
        txt.append("  %4d %9s %9.2f %4d %4d %4s %5s %4s %3s %4s %4s %4s %5s%s" % (
            step, "MIN" if gap == 0 else str(gap), pit * us, pit, tgt, d.get("n5f", "?"),
            d.get("tries", "?"), d.get("busy_tries", "?"), d.get("fit", "?"),
            d.get("p18", "?"), d.get("p19", "?"), d.get("pa", "?"),
            "%.2f" % (papit * us) if papit is not None else "?", note))
        exp.append(("OPNA3.SWEEP.step%02d.gap_us" % step, "%.2f" % (pit * us), "us",
                    r["line"], "single"))
    txt.append("  listen: at the first step whose 4 hits were LOUD the chip kept the 0x18 write; "
               "the gap that loses it lies between the previous step's actual gap and this "
               "one's. Loud, then quiet again at a longer gap, means the outcome depends on the "
               "write's phase: repeat around it with /STEP n /TO m.")
    if bad:
        txt.append("  steps short of their target: %s" % ",".join(map(str, bad)))


# ----------------------------------------------------------------------------- /AUDIT
# NP2kai's word-read table (io/iocore16.tbl; applied by io/iocore.c iocore_inp16 only when
# `!(port & 0x0c00)`, to `port & 0xff`; `(port & 0xfffc) == 0x005c` is the ARTIC's own word
# read). The probe records raw bytes; this is the reference prediction printed beside them.
AU_NP2_TERM = {}
for _c, _ps in (("2588", (0x01, 0x03, 0x05, 0x07, 0x09, 0x0B, 0x0D, 0x0F, 0x15, 0x19, 0x1F,
                          0x21, 0x23, 0x25, 0x27, 0x29, 0xF2, 0xF6)),
                ("AH=old", (0xD0, 0xD2, 0xD4, 0xD6, 0xD8, 0xDC, 0xDE)),
                ("AH=FF", (0x30, 0x32, 0x34, 0x36, 0x40, 0x42, 0x44, 0x46, 0x71, 0x75, 0x79,
                           0xAD, 0xAF)),
                ("AH=00", (0x60, 0x62, 0x64, 0x68, 0x6A, 0x6C, 0x70, 0x72, 0x74, 0x76, 0x7A,
                           0x7C, 0xA0, 0xA2, 0xA4, 0xA6, 0xA8, 0xAC)),
                ("AH=08", (0x20, 0x22, 0x24, 0x26))):
    for _p in _ps:
        AU_NP2_TERM[_p] = _c
AU_PIT_SPAN = 0x100                  # counts a /AUDIT PIT row can take (a few us at 2.4576 MHz)
AU_MAGIC_AH = 0xC3                   # EAX = A55AC33C before every wide read


def au_np2(port):
    if (port & 0xFFFC) == 0x005C:
        return "artic"
    if port & 0x0C00:
        return "split"
    return AU_NP2_TERM.get(port & 0xFF, "split")


def au_wclass(b0, b1, w):
    """the shapes of NP2kai's table one `in ax,P` is consistent with, against the byte reads
    of P and P+1 (several when the bytes cannot tell them apart, e.g. FF FF)"""
    hi, lo = w >> 8, w & 0xFF
    shapes = []
    if w == 0x2588:
        shapes.append("2588")
    if lo == b0:
        if hi == AU_MAGIC_AH:
            shapes.append("AH=old")
        if hi == b1:
            shapes.append("split")
        for c in (0xFF, 0x00, 0x08):
            if hi == c:
                shapes.append("AH=%02X" % c)
    return shapes or ["other"]


def au_down(a, b):
    """counts a down-counter moved from a to b (mod 65536)"""
    return (a - b) & 0xFFFF


@analyser
def audit(cap):
    """-> (text lines, expect tuples (name, value, unit, line, method)) for the AUDIT rows."""
    rows = [r for r in cap.rows if r["sec"] == "AUDIT" and r["kind"] == "X"]
    if not rows:
        return [], []
    txt, exp = [], []
    st = next((r for r in cap.rows if r["sec"] == "AUDIT" and r["kind"] == "STATE"), None)
    swap = st and st["kv"].get("pit_order") == "1"
    ratio = ratio_of(cap)

    def pair(first, second):
        return (first << 8 | second) if swap else (second << 8 | first)

    for r in rows:
        tag, d, ln = r["tag"], r["kv"], r["line"]
        h = {k: hx(v) for k, v in d.items()}
        if tag.startswith("W") and len(tag) == 5:
            p = int(tag[1:], 16)
            shapes = au_wclass(h["b0"], h["b1"], h["w1"])
            cls = "|".join(shapes)
            np2 = au_np2(p)
            txt.append("%s in ax=%04X (bytes %02X %02X) -> %s; NP2kai %s%s%s" % (
                tag, h["w1"], h["b0"], h["b1"], cls, np2,
                "" if np2 == "artic" else "  ** differs" if np2 not in shapes else
                "  (bytes cannot tell)" if len(shapes) > 1 else "",
                "" if d.get("d", "-") == "-" else "; in eax=%s" % d["d"]))
            exp.append(("AUDIT.%s.w" % tag, "%04X" % h["w1"], "hex", ln, "raw"))
            exp.append(("AUDIT.%s.class" % tag, cls, "shape", ln, "raw"))
            if d.get("d", "-") != "-":
                exp.append(("AUDIT.%s.d" % tag, d["d"].upper(), "hex", ln, "raw"))
        elif tag.startswith("B") and len(tag) == 5:
            txt.append("%s reads %s (again %s)" % (tag, d["v"], d["v2"]))
            exp.append(("AUDIT.%s.v" % tag, d["v"].upper(), "hex", ln, "raw"))
        elif tag in ("P0070", "P0071"):
            # ch0 runs from a known count (sec_audit.inc AU_PITKNOWN 0x80F0), so the latch's
            # two bytes differ and both candidates cannot fit within AU_PIT_SPAN counts
            v0, v1 = pair(h["a0"], h["a1"]), h["v1"]
            lo = h["w"] & 0xFF if tag == "P0071" else h["w"] >> 8
            cand = {"untouched": pair(h["x1"], h["x2"]), "consumed": pair(lo, h["x1"])}
            fit = [k for k, x in cand.items() if au_down(v0, x) <= AU_PIT_SPAN]
            v = fit[0] if len(fit) == 1 else ("inconclusive" if not fit else "both-fit")
            txt.append("%s in ax=%04X with ch0 latched: the latch was %s by the word read "
                       "(v0=%04X, next 0x71 bytes %02X %02X, v1=%04X after the reload)" % (
                           tag, h["w"], v, v0, h["x1"], h["x2"], v1))
            exp.append(("AUDIT.%s.latch" % tag, v, "verdict", ln, "raw"))
            exp.append(("AUDIT.%s.w" % tag, "%04X" % h["w"], "hex", ln, "raw"))
        elif tag in ("D0001", "D0000"):
            if h["r0"] == h["r1"]:
                v = "ambiguous"
            elif (h["x1"], h["x2"]) == (h["r0"], h["r1"]):
                v = "untouched"
            elif (h["x1"], h["x2"]) == (h["r1"], h["r0"]):
                v = "toggled"
            else:
                v = "other"
            txt.append("%s in ax=%04X: DMA byte flip-flop %s (probe register %s: %s %s -> %s %s)"
                       % (tag, h["w"], v, d["q"], d["r0"], d["r1"], d["x1"], d["x2"]))
            exp.append(("AUDIT.%s.ff" % tag, v, "verdict", ln, "raw"))
            exp.append(("AUDIT.%s.w" % tag, "%04X" % h["w"], "hex", ln, "raw"))
        elif tag in ("IRQ0WD_M", "IRQ0WD_U"):
            n = {k: int(d[k]) for k in ("samples", "ones", "rises", "falls")}
            per = AU_SAMP_TICKS * ratio / int(d["cnt"])
            if n["ones"] == 0:
                v = "never-set"
            elif n["falls"] == 0:
                v = "held"
            elif n["falls"] >= per / 2:
                v = "withdrawn"
            else:
                v = "falls-%d" % n["falls"]
            txt.append("%s (IRQ0 %s, IF=0): IRR bit 0 rose %d, fell %d times over ~%.0f OUT0 "
                       "periods, set in %.1f%% of %d samples -> %s" % (
                           tag, "masked" if tag.endswith("M") else "UNMASKED", n["rises"],
                           n["falls"], per, 100.0 * n["ones"] / max(n["samples"], 1),
                           n["samples"], v))
            exp.append(("AUDIT.%s.falls" % tag, n["falls"], "count", ln, "count"))
            exp.append(("AUDIT.%s.verdict" % tag, v, "verdict", ln, "count"))
        elif tag == "IRQ0OUT":
            txt.append("IRQ0OUT (control): OUT0 status %s rose %s, fell %s times (resync %s)" % (
                d["status"], d["rises"], d["falls"], d.get("sync")))
            exp.append(("AUDIT.IRQ0OUT.rises", d["rises"], "count", ln, "count"))
        elif tag == "IRQ0SLOW":
            dly, n, win, cnt = int(d["dly"]), int(d["n"]), int(d["win"]), int(d["cnt"])
            p = cnt / ratio                      # one period in ARTIC ticks
            periods = win / p
            held = periods if dly < p else periods * p / dly
            wdr = held if dly <= 1.5 * p else periods / 2
            if abs(held - wdr) < 0.05 * periods:
                v = "control"
            elif n < 0.4 * periods:
                v = "too-few"
            else:
                v = "held" if abs(n - held) < abs(n - wdr) else "withdrawn"
            txt.append("IRQ0SLOW handler IF=0 for %.2f periods: %d deliveries of %.1f periods "
                       "(held predicts %.1f, withdrawn %.1f) -> %s; INT 0Fh %s" % (
                           dly / p, n, periods, held, wdr, v, d["n0f"]))
            exp.append(("AUDIT.IRQ0SLOW.d%d.n" % dly, n, "count", ln, "count"))
            if v != "control":
                exp.append(("AUDIT.IRQ0SLOW.d%d.verdict" % dly, v, "verdict", ln, "count"))
        elif tag == "CALBDA":
            txt.append("CALBDA the BIOS 1/32 s counter moved %s in 0.25 s as found (%.0f Hz; "
                       "IMR_S %s)" % (d["d"], int(d["d"]) * 4, d["imr_s"]))
            exp.append(("AUDIT.CALBDA.d", d["d"], "count", ln, "count"))
        elif tag == "CAL128":
            txt.append("CAL128 0x128 reads %s as found" % d["v"])
            exp.append(("AUDIT.CAL128.v", d["v"].upper(), "hex", ln, "raw"))
        elif tag == "CAL":
            txt.append("CAL cfg=%s mode=%s (%s 0x128 in the handler): %s INT 17h in %.2f s, "
                       "0x128 after=%s isr_s=%s" % (
                           d["cfg"], d["mode"], "reads" if d["mode"] == "R" else "never reads",
                           d["n"], int(d["win"]) / ARTIC_HZ, d["v"], d["isr_s"]))
            exp.append(("AUDIT.CAL.%s.%s.n" % (d["cfg"], d["mode"]), d["n"], "count", ln,
                        "count"))
        elif tag in ("CASC_CTL", "CASC", "CASC_DEV"):
            on, off, off2 = h["m_on"], h["m_off"], h["m_off2"]
            txt.append("%s slave IRR %s, master IRR %s with IRQ12 open, %s / %s after (100 us), "
                       "slave IRR %s; then STI: INT 14h %s, INT 17h %s (isr_s %s isr_m %s), "
                       "INT 0Fh %s" % (tag, d["s_irr"], d["m_on"], d["m_off"], d["m_off2"],
                                       d["s_irr1"], d["n14"], d["n17"], d["isr_s"], d["isr_m"],
                                       d["n0f"]))
            if tag != "CASC_CTL" and on & 0x80:
                v = "IR7 withdrawn" if not off2 & 0x80 else "IR7 held"
                if int(d["n17"]) and not h["isr_s"] & 0x80:
                    v += ", spurious INT 17h"
                txt.append("   -> %s: master %s when the slave's request went away" % (tag, v))
                exp.append(("AUDIT.%s.m_ir7" % tag, "held" if off2 & 0x80 else "withdrawn",
                            "verdict", ln, "raw"))
            exp.append(("AUDIT.%s.n17" % tag, d["n17"], "count", ln, "count"))
            exp.append(("AUDIT.%s.n14" % tag, d["n14"], "count", ln, "count"))
    cal = {}
    for r in rows:
        if r["tag"] == "CAL":
            cal.setdefault(r["kv"]["cfg"], {})[r["kv"]["mode"]] = int(r["kv"]["n"])
    for cfg, m in cal.items():
        if m.get("R") == 0 and m.get("N") == 0:
            txt.append("CAL cfg=%s: no tick in either mode -> stopped" % cfg)
            exp.append(("AUDIT.CAL.%s.verdict" % cfg, "stopped", "verdict", 0, "count"))
        elif "R" in m and "N" in m and m["R"] > 2:
            v = ("one-request-per-tick" if m["N"] >= 0.8 * m["R"] else
                 "held-until-0x128-read" if m["N"] <= 1 else "partial")
            txt.append("CAL cfg=%s: %d ticks reading 0x128, %d not reading -> %s" % (
                cfg, m["R"], m["N"], v))
            exp.append(("AUDIT.CAL.%s.verdict" % cfg, v, "verdict", 0, "count"))
    return txt, exp


# ----------------------------------------------------------------------------- output
# ----------------------------------------------------------------------------- /FDC2
# Each X FDC2 row's fields against three expectations: NP2kai io/fdc.c (the primary software
# reference, for a raw HDM/XDF image), the core's RTL (src/pc9821/storage/pc9821_fdc.sv, read and
# confirmed by the core capture of the same binary) and the uPD765A datasheet / MAME upd765.cpp
# with undoc98 io_fdd.txt's "on the 1MB I/F the FDC RDY input is pulled up permanently". An entry is
# (label, test): test is the exact text or a predicate on the text. Values are hex as printed
# (st0=C1), times ARTIC ticks (3.255 us). u = the row's unit (da & 3).
def _rng(lo, hi):
    def f(v):
        n = num(v)
        return n is not None and lo <= n <= hi
    return f


def _sis(*codes):
    return ",".join(codes)


def fdc2_expect(tag, d):
    u = (hx(d.get("da", "90")) or 0x90) & 3
    hd = lambda b: "%02X" % (b | u)
    E = {}
    if tag == "UNIT":
        if d.get("cls") == "D":
            E["recal_st0"] = ((hd(0x20), hd(0x20)), (hd(0x20), hd(0x20)), (hd(0x20), hd(0x20)))
            E["st3_spun"] = ((hd(0x38), hd(0x38)), (hd(0x38), hd(0x38)), (hd(0x38), hd(0x38)))
        else:   # an equipped, powered, empty drive (item 59)
            E["recal_st0"] = ((hd(0x28) + " SE|NR", hd(0x28)), (hd(0x28), hd(0x28)),
                              (hd(0x20) + " RDY pulled up", hd(0x20)))
            E["st3_spun"] = ((hd(0x18), hd(0x18)), (hd(0x18), hd(0x18)),
                             (hd(0x38) + " RDY pulled up", hd(0x38)))
    elif tag in ("TC_R3", "TC_MT0", "TC_MT1"):
        chr_ = {"TC_R3": ("00", "00", "01", "04"), "TC_MT0": ("00", "01", "01", "01"),
                "TC_MT1": ("01", "00", "01", "01")}[tag]
        st0 = hd(0x04) if tag == "TC_MT1" else hd(0)
        E["st0"] = ((st0, st0), (st0, st0), (st0, st0))
        E["c"] = ((chr_[0], chr_[0]), (chr_[0], chr_[0]), (chr_[0], chr_[0]))
        E["h"] = ((chr_[1], chr_[1]), (chr_[1], chr_[1]), (chr_[1], chr_[1]))
        E["r"] = ((chr_[2] + " (R forced to 1)" if tag == "TC_R3" else chr_[2], chr_[2]),
                  (chr_[3], chr_[3]), (chr_[3], chr_[3]))
    elif tag in ("EOT_NT", "EOT_MT"):
        E["st0"] = ((hd(0), hd(0)), (hd(0), hd(0)), (hd(0x40) + " IC=01", hd(0x40)))
        E["st1"] = (("00", "00"), ("00", "00"), ("80 EN", "80"))
        E["c"] = (("01", "01"), ("01", "01"), ("-", lambda v: True))
        E["r"] = (("01", "01"), ("01", "01"), ("-", lambda v: True))
        E["dmacnt"] = (("03FF", "03FF"), ("03FF", "03FF"), ("03FF", "03FF"))
    elif tag == "IRQHOLD":
        E["irq_unmask"] = (("1 (IRR latched, never withdrawn)", "1"), ("0 (withdrawn)", "0"),
                           ("0 (INT falls at the result read)", "0"))
        E["r"] = (("01", "01"), ("02", "02"), ("02", "02"))
    elif tag == "VFO":
        E["rises"] = (("0", "0"), ("0", "0"), ("1 (undoc98: IRQ 100 ms after TTRG)", "1"))
        E["t_irq_art"] = (("-", "-"), ("-", "-"), ("~30720", _rng(25000, 37000)))
    elif tag == "DMA_MSR":
        E["msr"] = (("D%X only" % (1 << u), lambda v: v.split(":")[0] == "D%X" % (1 << u)),
                    ("D%X only" % (1 << u), lambda v: v.split(":")[0] == "D%X" % (1 << u)),
                    ("1%X (RQM low in DMA mode)" % (1 << u),
                     lambda v: "1%X" % (1 << u) in [x.split(":")[0] for x in v.split(",")]))
        E["diff"] = (("0", "0"), ("0", "0"), ("0", "0"))
    elif tag == "DMA_92":
        E["diff"] = ((">0 (each read takes a byte)", lambda v: (num(v) or 0) > 0),
                     ("0 (measured: the read peeks)", "0"), ("0", "0"))
        E["dmacnt"] = (("0003 (4 bytes taken, EOT end)", "0003"), ("FFFF", "FFFF"),
                       ("FFFF", "FFFF"))
    elif tag in ("NRID", "NRRD", "NRID_U2"):
        cls = 0x48 if tag == "NRRD" else 0x40
        E["end"] = (("D (7-byte result)", "D"), ("I (no result phase)", "I"),
                    ("T? (RDY pulled up: no NR; no index)", lambda v: True))
        E["nres"] = (("7", "7"), ("0", "0"), ("-", lambda v: True))
        E["st0"] = ((hd(cls), hd(cls)), ("FF (none)", "FF"), ("-", lambda v: True))
        E["sis"] = (("80", "80"), (_sis(hd(cls) + "00", "80"), _sis(hd(cls) + "00", "80")),
                    ("-", lambda v: True))
    elif tag in ("RST_M", "RST_NM", "RST640", "NRREC"):
        if tag == "RST_NM":
            np2 = (("none", "-"), ("none", "-"), ("0", "0"))
            rtl = (("none", "-"), ("none", "-"), ("0", "0"))
        else:
            np2 = (("~107 ms (6 frames from the 0x98)", _rng(28000, 40000)), ("80", "80"),
                   ("1", "1"))
            rtl = (("~315 if a drive holds a medium", lambda v: v == "-" or 300 <= (num(v) or 0) <= 640),
                   ("C0|unit per medium, 80", lambda v: v == "-" or v.endswith("80")),
                   ("0-1", lambda v: v in ("0", "1")))
        if tag == "RST640":     # the 640 KB interface carries each drive's own RDY
            sheet = (("<= 315 (1.024 ms poll)", _rng(0, 640)),
                     ("C0|unit per ready drive, 80", lambda v: v.endswith("80")), ("1", "1"))
        else:                   # the 1 MB interface: RDY pulled up, every unit polls ready
            sheet = (("<= 315 (1.024 ms poll)", _rng(0, 640)),
                     ("C000,C100,C200,C300,80", "C000,C100,C200,C300,80"), ("1", "1"))
        E["t_irq_art"] = (np2[0], rtl[0], sheet[0])
        E["sis"] = (np2[1], rtl[1], sheet[1])
        E["rises"] = (np2[2], rtl[2], sheet[2])
    elif tag == "M640":
        on = "74"
        E["cc"] = (("74 always (fdc_i94 0x74)", lambda v: all(x.split(":")[0] == on for x in v.split(","))),
                   ("74 for ~315 after SDS if a medium, then 64; 64 if empty",
                    lambda v: v.split(",")[0].split(":")[0] in ("74", "64")),
                   ("RDY follows the drive", lambda v: True))
    return E


@analyser
def fdc2(cap):
    """-> (text lines, expect tuples) for the /FDC2 rows."""
    rows = [r for r in cap.rows if r["sec"] == "FDC2" and r["kind"] in ("X", "STATE", "I", "SKIP")]
    if not rows:
        return [], []
    txt, exp = [], []
    for r in rows:
        if r["kind"] != "X":
            txt.append(r["text"])
            continue
        tag, d, ln = r["tag"], r["kv"], r["line"]
        txt.append("%s %s" % (tag, " ".join("%s=%s" % i for i in d.items())))
        key = "FDC2.%s.%s" % (tag, d.get("da", "-"))
        if tag == "M640":
            key += ".m%s" % d.get("motor", "-")
        for f, (np2, rtl, sheet) in fdc2_expect(tag, d).items():
            v = d.get(f, "-")
            marks = []
            for nm, (lab, t) in (("NP2kai", np2), ("RTL", rtl), ("datasheet", sheet)):
                ok = t(v) if callable(t) else v.upper() == t.upper()
                marks.append("%s %s%s" % (nm, lab, " =" if ok else " x"))
            txt.append("    %-10s %-26s | %s" % (f, v, " | ".join(marks)))
            exp.append(("%s.%s" % (key, f), v, "raw", ln, "raw"))
        if tag in ("RST_M", "RST_NM", "RST640", "NRREC") and num(d.get("t_irq_art")) is not None:
            txt.append("    t_irq = %.3f ms after the release" % (num(d["t_irq_art"]) * TICK_NS / 1e6))
        if tag == "M640":
            ch = [x.split(":") for x in d.get("cc", "").split(",") if ":" in x]
            if len(ch) > 1:
                txt.append("    0xCC bit 4 window = %.3f ms after the ST3 byte" %
                           (int(ch[1][1]) * TICK_NS / 1e6))
    return txt, exp


# ----------------------------------------------------------------------------- XE10U: /OPNA4, /AUDIT2
# The machine's 1-count start-to-flag bounds from an idle chip, PIT counts:
# docs/probes/XE10T-XE10-OPNA2.TXT `T OPNA2 TMRA_3FF trials=8 start_pit=70/78/101` and
# `T OPNA2 TMRB_FF trials=8 start_pit=101/105/751`.
O4_BOUNDS = {"A": (70, 101), "B": (101, 751)}
O4_BOUNDS_SRC = ("docs/probes/XE10T-XE10-OPNA2.TXT", {"A": "TMRA_3FF", "B": "TMRB_FF"})


def pit_us(cap, counts):
    return counts / (ratio_of(cap) * ARTIC_HZ) * 1e6


@analyser
def opna4(cap):
    """-> (text lines, expect tuples) for the /OPNA4 T rows (item 155)."""
    T = {r["tag"]: r for r in cap.rows if r["sec"] == "OPNA4" and r["kind"] == "T"}
    X = [r for r in cap.rows if r["sec"] == "OPNA4" and r["kind"] == "X"]
    if not T and not X:
        return [], []
    txt, exp = [], []
    # the read maps (items 187): per register, the closed and open answers
    maps = {}
    for r in X:
        if r["tag"] in ("RMAP_C", "RMAP_O"):
            for k, v in r["kv"].items():
                if k.startswith("r") and len(v) == 32:
                    base = int(k[1:], 16)
                    for i in range(16):
                        maps.setdefault(r["tag"][-1], {})[base + i] = int(v[2 * i:2 * i + 2], 16)
    for side in ("C", "O"):
        m = maps.get(side)
        if not m:
            continue
        cls = {}
        for reg, v in sorted(m.items()):
            c = "%02X" % v if v in (0x00, 0xFF) else "sel" if v == reg else "val"
            cls.setdefault(c, []).append(reg)
        def rng(regs):
            out, st = [], None
            for i, x in enumerate(regs):
                if st is None:
                    st = x
                if i + 1 == len(regs) or regs[i + 1] != x + 1:
                    out.append("%02X" % st if st == x else "%02X-%02X" % (st, x))
                    st = None
            return " ".join(out)
        txt.append("RMAP_%s (extension %s): %s" % (side, "closed" if side == "C" else "open",
                   "; ".join("%s: %s" % (c, rng(v)) for c, v in sorted(cls.items()))))
        for reg in (0x10, 0x11, 0x1F, 0x22, 0x29, 0x30, 0xB4, 0xFF):
            if reg in m:
                ln = next(r["line"] for r in X if r["tag"] == "RMAP_" + side)
                exp.append(("OPNA4.RMAP_%s.r%02X" % (side, reg), "%02X" % m[reg], "hex", ln, "read"))
    for r in X:
        d = r["kv"]
        if r["tag"] == "RD29_O":
            txt.append("RD29_O (extension open) write %s: 0x29 read %s before, %s after" % (
                d.get("v29"), d.get("pre"), d.get("post")))
            exp.append(("OPNA4.RD29_O.%s.post" % d.get("v29"), d.get("post"), "hex", r["line"], "read"))
        elif r["tag"].startswith("S3A_"):
            st, sth = hx(d.get("st188")), hx(d.get("st18C"))
            txt.append("%s seen=%s 0x188=%s 0x18C=%s: timer A flag %s/%s" % (
                r["tag"], d.get("seen"), d.get("st188"), d.get("st18C"),
                "-" if st is None else st & 1, "-" if sth is None else sth & 1))
            exp.append(("OPNA4.%s.st188" % r["tag"], d.get("st188"), "hex", r["line"], "read"))
            exp.append(("OPNA4.%s.st18C" % r["tag"], d.get("st18C"), "hex", r["line"], "read"))
    for tag in sorted(T, key=lambda t: (t[1], int(t[3:]) if t[3:].isdigit() else 0)):
        r = T[tag]
        f = r["fields"]
        if "start_pit" not in f:
            continue
        k, n = tag[1], int(tag[3:]) if tag[3:].isdigit() else 0
        lo, hi = O4_BOUNDS.get(k, (0, 0))
        smin, smed, smax = f["start_pit"]
        ctl = T.get("B%s_000" % k)
        b = f.get("burst_pit", (0, 0, 0))
        per = pit_us(cap, b[1]) / n if n else 0.0
        if smax <= hi:
            v = "within"
        elif smin <= hi:
            v = "partly-above"
        else:
            v = "above"
        add = ""
        if ctl and n and "start_pit" in ctl["fields"]:
            add = "; vs the n=0 control %+.1f us (median)" % pit_us(cap, smed - ctl["fields"]["start_pit"][1])
        txt.append("%s timer %s after %3d BUSY-polled writes (burst %.1f us/write): start->flag "
                   "%.1f/%.1f/%.1f us; the machine's idle bound %.1f..%.1f us -> %s%s" % (
                       tag, k, n, per, pit_us(cap, smin), pit_us(cap, smed), pit_us(cap, smax),
                       pit_us(cap, lo), pit_us(cap, hi), v, add))
        exp.append(("OPNA4.%s.start_us_max" % tag, "%.1f" % pit_us(cap, smax), "us", r["line"], "max"))
        exp.append(("OPNA4.%s.bound" % tag, v, "class", r["line"], "vs XE10T-XE10-OPNA2 TMR%s" %
                    ("A_3FF" if k == "A" else "B_FF")))
        if n:
            exp.append(("OPNA4.%s.us_per_write" % tag, "%.2f" % per, "us", r["line"], "median/n"))
    return txt, exp


def a2_cal_rows(cap):
    out = {}
    for r in cap.rows:
        if r["sec"] == "AUDIT2" and r["kind"] == "X" and r["tag"] == "CALIRR":
            d = r["kv"]
            edges = []
            for e in d.get("e", "").split(","):
                if e[:1] in "+-" and e[1:].isdigit():
                    edges.append((e[0], int(e[1:])))
            highs = []
            for i, (s_, t) in enumerate(edges):
                if s_ == "+" and i + 1 < len(edges) and edges[i + 1][0] == "-":
                    highs.append(edges[i + 1][1] - t)
            out[(d.get("cfg"), d.get("mode"))] = dict(
                line=r["line"], samples=int(d.get("samples", 0)), ones=int(d.get("ones", 0)),
                rises=int(d.get("rises", 0)), falls=int(d.get("falls", 0)),
                first=d.get("first"), r128=d.get("r128"), highs=highs)
    return out


@analyser
def audit2(cap):
    """-> (text lines, expect tuples) for the /AUDIT2 X rows (items 114, 42)."""
    rows = [r for r in cap.rows if r["sec"] == "AUDIT2" and r["kind"] == "X"]
    if not rows:
        return [], []
    txt, exp = [], []
    ms = TICK_NS / 1e6
    cal = a2_cal_rows(cap)
    for cfg in sorted({k[0] for k in cal}):
        res = {}
        for mode in ("N", "R"):
            c = cal.get((cfg, mode))
            if not c:
                continue
            duty = c["ones"] / c["samples"] if c["samples"] else 0.0
            hm = statistics.median(c["highs"]) * ms if c["highs"] else None
            res[mode] = (duty, hm, c)
            txt.append("CALIRR cfg=%s mode=%s: duty %.3f, rises %d falls %d, high %s ms (%d measured)%s" % (
                cfg, mode, duty, c["rises"], c["falls"], "-" if hm is None else "%.2f" % hm,
                len(c["highs"]), "" if mode == "N" else ", 0x128 read at the rise = %s" % c["r128"]))
            exp.append(("AUDIT2.CALIRR.%s.%s.duty" % (cfg, mode), "%.3f" % duty, "ratio", c["line"], "ones/samples"))
            if hm is not None:
                exp.append(("AUDIT2.CALIRR.%s.%s.high_ms" % (cfg, mode), "%.2f" % hm, "ms", c["line"], "median"))
        if "N" in res and "R" in res:
            (dn, hn, cn), (dr, hr, cr) = res["N"], res["R"]
            if cn["rises"] == 0 and cr["rises"] == 0 and dn < 0.5:
                v = "no-request"
            elif dn > 0.95 and cn["falls"] == 0:
                v = "held-until-read" if dr < 0.5 else "held"
            elif hn is not None and hr is not None and hr < 0.5 * hn:
                v = "read-lowers"
            else:
                v = "falls-by-itself"
            txt.append("CALIRR cfg=%s -> %s (NP2kai/undoc98: the 0x128 read lowers it; core: drops "
                       "half a period after the tick)" % (cfg, v))
            exp.append(("AUDIT2.CALIRR.%s.verdict" % cfg, v, "class", cn["line"], "N vs R"))
    for r in rows:
        tag, d, ln = r["tag"], r["kv"], r["line"]
        h = {k: hx(v) for k, v in d.items()}
        if tag in ("WO0009", "WO000A"):
            i0, i1, x1, x2 = h.get("i0"), h.get("i1"), h.get("x1"), h.get("x2")
            if tag == "WO0009":
                low = x1 == 0x5A
                both_p = low and x2 == 0xFF
                high = i1 == 0xFF and i0 != 0xFF
                np2 = "dropped"
            else:
                low = i1 == 0xFF and i0 != 0xFF
                high = x1 == 0x5A
                both_p = False
                np2 = "split"
            shape = ("both-at-P" if both_p else "split" if low and high else
                     "low-only" if low else "high-only" if high else "dropped")
            txt.append("%s out %s,ax -> %s (NP2kai %s)%s" % (
                tag, "09h" if tag == "WO0009" else "0Ah", shape, np2, "" if shape == np2 else "  ** differs"))
            exp.append(("AUDIT2.%s.shape" % tag, shape, "class", ln, "read-back of P and P+1"))
        elif tag == "WO006C":
            b0, a0 = h.get("b0"), h.get("a0")
            shape = ("low-landed" if a0 == 0x70 else "cannot-tell" if a0 == b0 else "other")
            txt.append("WO006C out 6Ch,ax (AL=70): 0x6C %02X -> %02X: %s (NP2kai low byte only)" % (
                b0 or 0, a0 or 0, shape))
            exp.append(("AUDIT2.WO006C.low", shape, "class", ln, "0x6C read-back"))
        elif tag.startswith("W") and len(tag) == 5:
            p = int(tag[1:], 16)
            shapes = au_wclass(h["b0"], h["b1"], h["w1"])
            np2 = au_np2(p)
            txt.append("%s in ax=%04X (bytes %02X %02X) -> %s; NP2kai %s%s" % (
                tag, h["w1"], h["b0"], h["b1"], "|".join(shapes), np2,
                "  ** differs" if np2 not in shapes else
                "  (bytes cannot tell)" if len(shapes) > 1 else ""))
            exp.append(("AUDIT2.%s.class" % tag, "|".join(shapes), "class", ln, "bytes vs word"))
        elif tag.startswith("T") and len(tag) == 5:
            b, w = int(d.get("b", "0")), int(d.get("w", "0"))
            # the controls: 0x60 one bus cycle (minus_term, /AUDIT W0060), 0x0A two (split)
            ctl = {x["tag"]: int(x["kv"].get("w", "0")) - int(x["kv"].get("b", "0")) for x in rows
                   if x["tag"] in ("T0060", "T000A")}
            dd = w - b
            if len(ctl) < 2 or ctl["T000A"] - ctl["T0060"] < 0.1 * max(b, 1):
                v = "cannot-tell"
            else:
                v = ("two-cycles" if abs(dd - ctl["T000A"]) < abs(dd - ctl["T0060"]) else "one-cycle")
            txt.append("%s 1024 in ax vs in al: w-b = %d PIT (controls: 0x60 one cycle %s, 0x0A two "
                       "%s) -> %s" % (tag, dd, ctl.get("T0060", "-"), ctl.get("T000A", "-"), v))
            exp.append(("AUDIT2.%s.w_minus_b" % tag, dd, "pit", ln, "best of 3"))
            exp.append(("AUDIT2.%s.cycles" % tag, v, "class", ln, "nearer control"))
    return txt, exp


# ----------------------------------------------------------------------------- XE10V: /MISAL
# /MISAL's windows (sec_misal.inc): _A starts MS_ADELAY ARTIC ticks after the VSYNC fall, _V at
# the VSYNC rise. The raster is the 24 kHz SYNC block RASTER_LINES cites: from the rise, 8 lines
# of VSYNC and the 25-line back porch are blank (33 lines); from the fall, 25 blank lines, then
# the 400 active ones. The core's Xe10 store table (pc9821_gvram_arb.sv) prices a misaligned
# word one period inside a dword and two across a dword boundary: MS_TABLE is that prediction,
# printed beside the measured ratio; the capture, not this constant, is the evidence.
MS_ADELAY = 614
MS_VBLANK_LINES = 8 + 25
MS_ACTIVE_END_LINES = 25 + 400
MS_MODES = ("RMW", "TDW", "PLN")
MS_PHASES = (("O", "graphics display stopped"), ("A", "graphics on, active lines"),
             ("V", "graphics on, vertical blank"))
MS_TABLE = {"W1": 1.0, "W3": 2.0}


def ms_ns(cap, r):
    """Per unit ns of a /MISAL R row from the PIT median (0.41 us per count, unwrapped with the
    ARTIC): a 1024-store window is about 100-1000 PIT counts, the ARTIC only 30-200 ticks."""
    return r["pit_ns"]


@analyser
def misal(cap):
    """-> (text lines, expect tuples) for /MISAL (the misaligned-word charge, graphics on/off)."""
    R = [r for r in cap.rows if r["sec"] == "MISAL" and r["kind"] == "R" and not r.get("refused")]
    P = {r["tag"]: r for r in cap.rows if r["sec"] == "MISAL" and r["kind"] == "P"}
    if not R and not P:
        return [], []
    txt, exp = [], []
    by = {}
    for r in R:
        by.setdefault(r["tag"], {})[r["nop"]] = r
    tpf, lt = cap.cal.get("vsync_ticks", NOM_FRAMES[0]), None
    for t in ("RASTER_O", "RASTER_G"):
        r = P.get(t)
        if not r:
            continue
        d = r["kv"]
        fr, art, hi, to = (num(d.get(k)) or 0 for k in ("frames", "art", "hi", "to"))
        if fr and art:
            lt = art / fr / RASTER_LINES
            txt.append("%s: %.1f ARTIC ticks/frame, VSYNC high %.1f ticks = %.1f lines%s" % (
                t, art / fr, hi / fr, hi / fr / lt, "" if not to else "  ** %d poll timeouts" % to))
            exp.append(("MISAL.%s.frame_ticks" % t, "%.1f" % (art / fr), "ticks", r["line"], "mean"))
            exp.append(("MISAL.%s.vsync_lines" % t, "%.2f" % (hi / fr / lt), "lines", r["line"], "mean"))
            if to:
                cap.flag(r["line"], "SYNC-TIMEOUT", "%s to=%d" % (t, to))
    if lt is None:
        lt = tpf / RASTER_LINES
    for r in cap.rows:
        if r["sec"] == "MISAL" and r["kind"] == "I" and "sync_to" in r["kv"]:
            if (num(r["kv"]["sync_to"]) or 0) > 0:
                cap.flag(r["line"], "SYNC-TIMEOUT", "sync_to=%s: some windows started unsynced" %
                         r["kv"]["sync_to"])
    # the windows against the raster
    for r in R:
        ph = r["tag"].rsplit("_", 1)[-1]
        longest = max(r["art"][2], r["ctl_art"][2])
        if ph == "V" and longest > MS_VBLANK_LINES * lt:
            r["flags"].append("PAST-BLANK")
            cap.flag(r["line"], "PAST-BLANK", "%s: a %d-tick window from the VSYNC rise outlasts "
                     "the %d-line blank (%.0f ticks)" % (r["tag"], longest, MS_VBLANK_LINES,
                                                          MS_VBLANK_LINES * lt))
        if ph == "A" and MS_ADELAY + longest > MS_ACTIVE_END_LINES * lt:
            r["flags"].append("PAST-ACTIVE")
            cap.flag(r["line"], "PAST-ACTIVE", "%s: window ends past the active lines" % r["tag"])

    def val(tag):
        x = by.get(tag, {}).get(0)
        return None if x is None else (ms_ns(cap, x), x["line"])

    for mode in MS_MODES:
        for ph, what in MS_PHASES:
            sfx = "_" + ph
            w = {k: val("%s_%s%s" % (mode, k, sfx)) for k in
                 ("W0", "W1", "W2", "W3", "WA", "B0", "D0", "SW0", "SW1", "SW3", "MW0", "MW1",
                  "MW3", "BL0", "BL1")}
            if w["W0"] is None:
                continue
            c0, ln = w["W0"]
            base = "MISAL.%s.%s" % (mode, ph)
            parts = []
            for k in ("W0", "W1", "W2", "W3", "WA", "B0", "D0"):
                if w[k]:
                    parts.append("%s %.1f" % (k, w[k][0]))
                    exp.append(("%s.%s_ns" % (base, k.lower()), "%.1f" % w[k][0], "ns", w[k][1],
                                "pit nop=0"))
            txt.append("%s %s (%s): mov per store, ns: %s" % (mode, ph, what, ", ".join(parts)))
            if w["W1"] and w["W3"] and c0 > 0:
                r1, r3 = w["W1"][0] / c0, w["W3"][0] / c0
                txt.append("%s %s: W1/W0 = %.3f (inside a dword; the core table %.0f), W3/W0 = %.3f "
                           "(across a dword; the table %.0f); excess %+.1f / %+.1f ns" % (
                               mode, ph, r1, MS_TABLE["W1"], r3, MS_TABLE["W3"],
                               w["W1"][0] - c0, w["W3"][0] - c0))
                exp.append(("%s.w1_over_w0" % base, "%.3f" % r1, "ratio", w["W1"][1], "pit nop=0"))
                exp.append(("%s.w3_over_w0" % base, "%.3f" % r3, "ratio", w["W3"][1], "pit nop=0"))
                mix = (w["W1"][0] + w["W3"][0]) / 2
                for k in ("WA", "SW1", "SW3", "MW1", "MW3"):
                    if w[k]:
                        txt.append("%s %s: %s %.1f ns/word against the W1/W3 mean %.1f (%+.1f%%)" % (
                            mode, ph, k, w[k][0], mix, 100 * (w[k][0] / mix - 1)))
            for k in ("SW0", "SW1", "SW3", "MW0", "MW1", "MW3"):
                if w[k]:
                    exp.append(("%s.%s_ns" % (base, k.lower()), "%.1f" % w[k][0], "ns", w[k][1],
                                "pit gross"))
            if w["BL0"] and w["BL1"]:
                b0, b1 = w["BL0"][0] / 20, w["BL1"][0] / 20
                txt.append("%s %s: Rusty's row (20 words): %.1f ns/word aligned, %.1f odd (x%.3f)" % (
                    mode, ph, b0, b1, b1 / b0))
                exp.append(("%s.bl0_ns_per_word" % base, "%.1f" % b0, "ns", w["BL0"][1], "pit/20"))
                exp.append(("%s.bl1_ns_per_word" % base, "%.1f" % b1, "ns", w["BL1"][1], "pit/20"))
    # graphics on against off, per shape
    for mode in MS_MODES:
        for k in ("W0", "W1", "W3", "B0", "D0", "SW1", "MW1"):
            o, a, v = (val("%s_%s_%s" % (mode, k, ph)) for ph in ("O", "A", "V"))
            if o and a and v:
                txt.append("%s %s: off %.1f, active %.1f (x%.3f), blank %.1f (x%.3f) ns" % (
                    mode, k, o[0], a[0], a[0] / o[0], v[0], v[0] / o[0]))
    return txt, exp



# ----------------------------------------------------------------------------- XE10W: /MISAL2
# /MISAL2's tags are <FAMILY>_<K>[_<PHASE>] (sec_misal2.inc): K is the access's byte offset, the
# K = 0 row (IOOW: K = 4, the aligned word OUT) is the family's base. What the core charges for
# each class is the same row of a core capture of this binary: in a comparison both are printed.
M2_TAG = re.compile(r"^([A-Z]+)_(\d+)(?:_([OAV]))?$")
M2_BASE = {"IOOW": 4, "IOOB": None, "IOIB": None, "BLSS": None}
M2_WHAT = {
    "RLWH": "RAM word load, warm", "RLWM": "RAM word load, missing", "RLDH": "RAM dword load, warm",
    "RLDM": "RAM dword load, missing", "RSWH": "RAM word store, warm", "RSWM": "RAM word store, missing",
    "RSDH": "RAM dword store, warm", "RSDM": "RAM dword store, missing", "RLBH": "RAM byte load",
    "RSBH": "RAM byte store", "RMSW": "RAM rep movsw, dst +K", "RMSS": "RAM rep movsw, src +K",
    "RMSD": "RAM rep movsd, dst +K", "GRW": "GVRAM word load", "GRD": "GVRAM dword load",
    "GRB": "GVRAM byte load", "GLSW": "GVRAM rep lodsw", "GLSD": "GVRAM rep lodsd",
    "GMVR": "rep movsw GVRAM->RAM", "GMVV": "rep movsw GVRAM->GVRAM", "TCRW": "GRCG TCR word",
    "TCRB": "GRCG TCR byte", "BLSS": "wipe row RAM src+1 -> GVRAM (K: dst; 9 = src 0 dst 1)",
    "XCW": "text code word store", "XCB": "text code byte store", "XCR": "text code word load",
    "XAW": "text attr word store", "XAR": "text attr word load", "PKW": "PEGC word store",
    "PKD": "PEGC dword store", "PKR": "PEGC word load", "IOIW": "in ax at 0x30+K",
    "IOIB": "in al 0x33 + in al 0x34", "IOOW": "out ax at 0xA0+K (K=3: 0xA3)",
    "IOOB": "out al 0xA3 + out al 0xA4"}


def misal2_values(cap):
    """{(family, phase): {K: (ns per unit from the PIT at nop=0, line)}}"""
    out = {}
    for r in cap.rows:
        if r["sec"] != "MISAL2" or r["kind"] != "R" or r.get("refused") or r["nop"] != 0:
            continue
        m = M2_TAG.match(r["tag"])
        if not m:
            continue
        out.setdefault((m.group(1), m.group(3) or "-"), {})[int(m.group(2))] = (r["pit_ns"], r["line"])
    return out


@analyser
def misal2(cap):
    """-> (text lines, expect tuples): per family and phase the ns per unit at each offset and
    the ratio to the family's base offset."""
    v = misal2_values(cap)
    if not v:
        return [], []
    txt, exp = [], []
    ras = [r for r in cap.rows if r["sec"] == "MISAL2" and r["kind"] == "P" and r["tag"] == "RASTER_G"]
    lt = cap.cal.get("vsync_ticks", NOM_FRAMES[0]) / RASTER_LINES
    if ras and num(ras[0]["kv"].get("frames")) and num(ras[0]["kv"].get("art")):
        lt = num(ras[0]["kv"]["art"]) / num(ras[0]["kv"]["frames"]) / RASTER_LINES
    for r in cap.rows:
        if r["sec"] != "MISAL2" or r["kind"] != "R" or "PAST-" in ",".join(r["flags"]):
            continue
        ph = r["tag"].rsplit("_", 1)[-1]
        longest = max(r["art"][2], r["ctl_art"][2])
        if ph == "V" and longest > MS_VBLANK_LINES * lt:
            r["flags"].append("PAST-BLANK")
            cap.flag(r["line"], "PAST-BLANK", "%s: %d ticks from the VSYNC rise" % (r["tag"], longest))
        if ph == "A" and MS_ADELAY + longest > MS_ACTIVE_END_LINES * lt:
            r["flags"].append("PAST-ACTIVE")
            cap.flag(r["line"], "PAST-ACTIVE", "%s: window ends past the active lines" % r["tag"])
    for r in cap.rows:
        if (r["sec"] == "MISAL2" and r["kind"] == "I" and (num(r["kv"].get("sync_to")) or 0) > 0
                and not r.get("m2_flagged")):
            r["m2_flagged"] = True
            cap.flag(r["line"], "SYNC-TIMEOUT", "sync_to=%s" % r["kv"]["sync_to"])
    for (fam, ph) in sorted(v):
        ks = v[(fam, ph)]
        bk = M2_BASE.get(fam, 0)
        base = ks.get(bk) if bk is not None else None
        parts = []
        for k in sorted(ks):
            ns, ln = ks[k]
            rat = "" if not base or k == bk else " (x%.3f)" % (ns / base[0])
            parts.append("K%d %.1f%s" % (k, ns, rat))
            exp.append(("MISAL2.%s.%s.k%d_ns" % (fam, ph, k), "%.1f" % ns, "ns", ln, "pit nop=0"))
            if base and k != bk:
                exp.append(("MISAL2.%s.%s.k%d_over_k%d" % (fam, ph, k, bk), "%.3f" % (ns / base[0]),
                            "ratio", ln, "pit nop=0"))
        txt.append("%-5s %s %-46s %s" % (fam, ph, M2_WHAT.get(fam, ""), ", ".join(parts)))
    return txt, exp


# ----------------------------------------------------------------------------- XE10X: /RDLAT
# /RDLAT's tags are <FAMILY>_<MODE><PHASE> (sec_rdlat.inc): MODE 24 = 640x400 at 24 kHz, 31 = 640x400
# at 31 kHz, 48 = the 640x480 256-colour mode; PHASE as /MISAL. Every swept row is a nop sweep; the
# question is whether the CPU work between two accesses ADDS to the access (latency: the CPU waits
# for each access) or HIDES inside it (rate: the next access waits out a period the work overlaps).
# With g(k) the ns per access at nop k (PIT median) and c(k) the control's, the work added by the
# nops is c(k) - c(0) and the part of it the access hid is h(k) = (c(k) - c(0)) - (g(k) - g(0)).
# A latency access hides nothing (h = 0 at every k); a rate access hides the work up to its period
# (h climbs with k until the knee, then stays at the period less the shell and the issue cost).
# hidden_frac is the largest h over the access's own cost a0 = g(0) - c(0): about 0 for latency,
# towards 1 for rate. The verdict bands are wide on purpose: the two models differ by the whole
# access (hundreds of ns against a PIT resolution of 0.8 ns per access at n = 512).
RD_TAG = re.compile(r"^([A-Z]+)_(24|31|48)([OAV])$")
# Raster geometry per mode: (lines per frame, blank lines from the VSYNC rise = VS + VBP, lines
# from the VSYNC fall to the last active line = VBP + AL), from the BIOS's GDC SYNC blocks as
# NP2kai bios/bios18.c carries them (P3/P4 VS, P6 VFP, P7/P8 AL and VBP):
#   24  gdcmastersync "24" {0x10,0x4e,0x07,0x25,0x07,0x07,0x90,0x65}: VS 8, VFP 7, AL 400, VBP 25
#   31  gdcmastersync "31" {0x10,0x4e,0x47,0x0c,0x07,0x0d,0x90,0x89}: VS 2, VFP 13, AL 400, VBP 34
#   48  gdcslavesync "31-H" {0x02,0x4e,0x4b,0x0c,0x83,0x06,0xe0,0x95}: VS 2, VFP 6, AL 480, VBP 37
#       (the master's "31-480:25" block, AL 475 VFP 11 VBP 37, ends its VSYNC on the same line)
RD_GEOM = {"24": (440, 33, 425), "31": (449, 36, 434), "48": (525, 39, 517)}
# ARTIC ticks per frame: the measured 24 and 31 kHz frames (NOM_FRAMES), 525 lines at the 31 kHz
# line rate for 48.
RD_FRAME = {"24": NOM_FRAMES[0], "31": NOM_FRAMES[1], "48": NOM_FRAMES[1] * 525 / 449}
RD_WHAT = {
    "GRW": "GVRAM word load", "GRD": "GVRAM dword load", "GW": "GVRAM word store",
    "GLSW": "GVRAM rep lodsw", "GMVR": "rep movsw GVRAM->RAM", "TCRW": "GRCG TCR word read",
    "TDW": "GRCG TDW word store", "RMW": "GRCG RMW word store", "XCR": "text code load, off-screen",
    "XCW": "text code store, off-screen", "XCRS": "text code load, on screen",
    "XCWS": "text code store, on screen", "XARS": "text attr load, on screen",
    "XAWS": "text attr store, on screen", "PKR": "PEGC packed word load", "PKW": "PEGC packed word store"}
RD_LAT, RD_RATE = 0.2, 0.5            # hidden_frac at or below: LATENCY; at or above: RATE


def rd_shape(pts):
    """pts: [(k, g, c)] sorted by k -> dict(g0, a0, kmax, gmax, h, hk, frac, verdict)."""
    k0, g0, c0 = pts[0]
    a0 = g0 - c0
    hs = [((c - c0) - (g - g0), k) for k, g, c in pts[1:]]
    h, hk = max(hs) if hs else (0.0, 0)
    frac = h / a0 if a0 > 0 else 0.0
    verdict = "LATENCY" if frac <= RD_LAT else "RATE" if frac >= RD_RATE else "MIXED"
    return {"g0": g0, "a0": a0, "kmax": pts[-1][0], "gmax": pts[-1][1], "cmax": pts[-1][2] - c0,
            "h": h, "hk": hk, "frac": frac, "verdict": verdict}


@analyser
def rdlat(cap):
    """-> (text lines, expect tuples) for /RDLAT."""
    R = [r for r in cap.rows if r["sec"] == "RDLAT" and r["kind"] == "R" and not r.get("refused")]
    P = {r["tag"]: r for r in cap.rows if r["sec"] == "RDLAT" and r["kind"] == "P"}
    if not R and not P:
        return [], []
    txt, exp = [], []
    lt = {}
    for t, r in sorted(P.items()):
        d = r["kv"]
        fr, art, hi, to = (num(d.get(k)) or 0 for k in ("frames", "art", "hi", "to"))
        m = t[len("RASTER_"):len("RASTER_") + 2]
        if not (fr and art) or m not in RD_GEOM:
            continue
        tpf = art / fr
        lines = RD_GEOM[m][0]
        if not t.endswith("O"):
            lt[m] = tpf / lines
        txt.append("%s: %.1f ARTIC ticks/frame (mode %s nominal %.1f), VSYNC high %.2f lines%s" % (
            t, tpf, m, RD_FRAME[m], hi / fr / (tpf / lines), "" if not to else "  ** %d poll timeouts" % to))
        exp.append(("RDLAT.%s.frame_ticks" % t, "%.1f" % tpf, "ticks", r["line"], "mean"))
        exp.append(("RDLAT.%s.vsync_lines" % t, "%.2f" % (hi / fr / (tpf / lines)), "lines", r["line"], "mean"))
        if abs(tpf / RD_FRAME[m] - 1) > 0.03:
            cap.flag(r["line"], "MODE-NOT-SET", "%s: %.1f ticks/frame, mode %s is %.1f" % (t, tpf, m, RD_FRAME[m]))
        if to:
            cap.flag(r["line"], "SYNC-TIMEOUT", "%s to=%d" % (t, to))
    for r in cap.rows:
        if r["sec"] == "RDLAT" and r["kind"] == "I" and (num(r["kv"].get("sync_to")) or 0) > 0:
            cap.flag(r["line"], "SYNC-TIMEOUT", "sync_to=%s: some windows started unsynced" % r["kv"]["sync_to"])
        if r["sec"] == "RDLAT" and r["kind"] == "SKIP":
            txt.append("skipped: %s" % r["text"])
    groups = {}
    for r in R:
        m = RD_TAG.match(r["tag"])
        if not m:
            continue
        fam, mode, ph = m.groups()
        g = RD_GEOM[mode]
        l_t = lt.get(mode, RD_FRAME[mode] / g[0])
        longest = max(r["art"][2], r["ctl_art"][2])
        if ph == "V" and longest > g[1] * l_t:
            r["flags"].append("PAST-BLANK")
            cap.flag(r["line"], "PAST-BLANK", "%s nop=%d: %d ticks from the VSYNC rise, the blank is "
                     "%.0f" % (r["tag"], r["nop"], longest, g[1] * l_t))
        if ph == "A" and MS_ADELAY + longest > g[2] * l_t:
            r["flags"].append("PAST-ACTIVE")
            cap.flag(r["line"], "PAST-ACTIVE", "%s nop=%d: window ends past the active lines" % (r["tag"], r["nop"]))
        groups.setdefault((fam, mode, ph), []).append(r)
    g0s = {}
    for key in sorted(groups, key=lambda x: (list(RD_WHAT).index(x[0]) if x[0] in RD_WHAT else 99, x[1], "OAV".index(x[2]))):
        fam, mode, ph = key
        rows = sorted(groups[key], key=lambda r: r["nop"])
        base = "RDLAT.%s.%s%s" % (fam, mode, ph)
        if rows[0]["nop"] != 0:
            continue
        ln = rows[0]["line"]
        g0s[key] = rows[0]["pit_ns"]
        exp.append((base + ".k0_ns", "%.1f" % rows[0]["pit_ns"], "ns", ln, "pit nop=0"))
        if len(rows) < 2:
            txt.append("%-5s %s%s %-28s %7.1f ns (one point)" % (fam, mode, ph, RD_WHAT.get(fam, ""),
                                                              rows[0]["pit_ns"]))
            continue
        sh = rd_shape([(r["nop"], r["pit_ns"], r["ctl_pit_ns"]) for r in rows])
        for r in rows[1:]:
            if r["nop"] in (32, 64):
                exp.append((base + ".k%d_ns" % r["nop"], "%.1f" % r["pit_ns"], "ns", r["line"], "pit"))
        exp.append((base + ".hidden_ns", "%.1f" % sh["h"], "ns", ln, "sweep"))
        exp.append((base + ".hidden_frac", "%.3f" % sh["frac"], "ratio", ln, "sweep"))
        exp.append((base + ".shape", sh["verdict"], "class", ln, "sweep"))
        txt.append("%-5s %s%s %-28s k0 %7.1f ns (access %6.1f); k%d %7.1f (+%6.1f ns of work): "
                   "hid %6.1f ns at k%d, %.2f of the access -> %s" % (
                       fam, mode, ph, RD_WHAT.get(fam, ""), sh["g0"], sh["a0"], sh["kmax"], sh["gmax"],
                       sh["cmax"], sh["h"], sh["hk"], sh["frac"], sh["verdict"]))
    # the raster penalty: on the active lines against the blank, per mode; each mode against 24
    for fam in RD_WHAT:
        parts = []
        for mode in ("24", "31", "48"):
            a, v = g0s.get((fam, mode, "A")), g0s.get((fam, mode, "V"))
            if a and v:
                parts.append("%s: A %.1f V %.1f (x%.3f)" % (mode, a, v, a / v))
                ln = groups[(fam, mode, "A")][0]["line"]
                exp.append(("RDLAT.%s.%s.a_over_v" % (fam, mode), "%.3f" % (a / v), "ratio", ln, "pit nop=0"))
        if parts:
            txt.append("%-5s raster at nop 0: %s" % (fam, "; ".join(parts)))
    return txt, exp


# ----------------------------------------------------------------------------- XE10Y (kit 3)
REP_BAND = 0.03                      # a row whose passes spread more than this is flagged


@analyser
def rep_spread(cap):
    """/REP n: per (section, tag, nop) R row the pit ns of every pass, the spread (max - min)
    over the median; REP-SPREAD past REP_BAND. -> (text lines, expect tuples)."""
    rows = getattr(cap, "all_rows", cap.rows)
    if not any(r.get("pass") for r in rows):
        return [], []
    g = {}
    for r in rows:
        if r["kind"] == "R" and not r.get("refused") and "pit_ns" in r:
            g.setdefault((r["sec"], r["tag"], r["nop"]), {})[r["pass"]] = r
    txt, exp, nflag = [], [], 0
    for (sec, tag, nop), by in g.items():
        if len(by) < 2:
            continue
        v = [by[p]["pit_ns"] for p in sorted(by)]
        med = statistics.median(v)
        spr = (max(v) - min(v)) / med if med > 0 else 0.0
        mark = ""
        if spr > REP_BAND:
            nflag += 1
            mark = "  ** REP-SPREAD"
            cap.flag(by[min(by)]["line"], "REP-SPREAD", "%s %s nop=%d %.1f%% over %d passes" % (
                sec, tag, nop, 100 * spr, len(v)))
        if nop == 0 or mark:
            txt.append("%-7s %-14s nop=%-3d %s  spread %5.2f%%%s" % (
                sec, tag, nop, " ".join("%7.1f" % x for x in v), 100 * spr, mark))
        exp.append(("REP.%s.%s.k%d.spread" % (sec, tag, nop), "%.4f" % spr, "ratio", by[min(by)]["line"], "pit"))
    txt.insert(0, "%d rows over %d passes; %d past %.0f %%" % (
        len(exp), 1 + max(r.get("pass", 0) for r in rows), nflag, 100 * REP_BAND))
    return txt, exp


def _state_rows(cap, sec):
    """STATE row=<tag> lines of a section (every pass) -> {tag: [kv dict per occurrence]}"""
    out = {}
    for r in getattr(cap, "all_rows", cap.rows):
        if r["sec"] == sec and r["kind"] == "STATE" and r["kv"].get("row"):
            out.setdefault(r["kv"]["row"], []).append(r["kv"])
    return out


PK_FACTOR_BAND = 0.05                # two figures that differ by more than this differ


def _k0(cap, sec, tag):
    """the nop-0 pit ns of every R row tagged tag in sec (every pass)"""
    return [r["pit_ns"] for r in getattr(cap, "all_rows", cap.rows)
            if r["sec"] == sec and r["kind"] == "R" and r["tag"] == tag and r["nop"] == 0
            and not r.get("refused")]


def _mean(v):
    return sum(v) / len(v) if v else None


def _differ(a, b):
    return a is not None and b is not None and abs(a - b) / min(a, b) > PK_FACTOR_BAND


@analyser
def pkab(cap):
    """/PKAB: the PEGC store A/B. Every PKW figure by sequence (M = /MISAL2's, R = /RDLAT's),
    factor row and cache/drain pass, round by round, and the factor that moves the figure."""
    R = [r for r in getattr(cap, "all_rows", cap.rows) if r["sec"] == "PKAB" and r["kind"] == "R"]
    if not R:
        return [], []
    rounds = sorted({int(m.group(1)) for r in R for m in [re.search(r"_[A-Z]+(\d)$", r["tag"])] if m})
    fam = [("M  PKW_0 (MISAL2's row)", "PKW_0_M%d"), ("M  PKW_1 (DI=1)", "PKW_1_M%d"),
           ("M  PKD_0 (dword)", "PKD_0_M%d"), ("R  PKW (RDLAT's row)", "PKW_R%d"),
           ("F  PKW1ST after pegc on", "PKW1ST_FA%d"), ("F  PKWAFT after PKR", "PKWAFT_FA%d"),
           ("F  PKWLATE 60 frames on", "PKWLATE_FA%d"), ("F  PKWODD DI=1", "PKWODD_FA%d"),
           ("F  PKWHI DI=4000", "PKWHI_FA%d"), ("F  PKDF dword", "PKDF_FA%d"),
           ("FV PKW1ST (blank)", "PKW1ST_FV%d"), ("FV PKWLATE (blank)", "PKWLATE_FV%d"),
           ("C  PKW cache as found", "PKW_C%d"), ("N  PKW cache off", "PKW_N%d"),
           ("D  PKW drain read", "PKW_D%d"), ("C  GW plane B", "GW_C%d"), ("N  GW cache off", "GW_N%d"),
           ("C  GRW (read, DI+=4)", "GRW_C%d"), ("C  GRS (one address)", "GRS_C%d"),
           ("N  GRS cache off", "GRS_N%d"), ("C  RLWH main memory", "RLWH_C%d"),
           ("N  RLWH cache off", "RLWH_N%d"), ("C  PKR", "PKR_C%d"), ("C  PKRS (one address)", "PKRS_C%d"),
           ("N  PKRS cache off", "PKRS_N%d")]
    txt, exp, m = [], [], {}
    txt.append("ns per access at nop 0, round %s" % " ".join(str(x) for x in rounds))
    for name, pat in fam:
        per = [_mean(_k0(cap, "PKAB", pat % rd)) for rd in rounds]
        if not any(per):
            continue
        key = pat.replace("%d", "")
        m[key] = _mean([x for x in per if x])
        txt.append("%-28s %s  mean %7.1f" % (name, " ".join("%7.1f" % x if x else "      -" for x in per), m[key]))
        exp.append(("PKAB.%s.k0_ns" % key, "%.1f" % m[key], "ns", R[0]["line"], "pit nop=0 mean of rounds"))
    st = _state_rows(cap, "PKAB")

    def sfield(tag, f):
        return [d.get(f) for d in st.get(tag, [])]
    for tag in ("PKW_0_M1", "PKW_R1", "PKW1ST_FA1", "PKWLATE_FA1"):
        if tag in st:
            d = st[tag][0]
            txt.append("state before %-12s %s" % (tag, " ".join("%s=%s" % (k, d[k]) for k in (
                "q04", "q07", "q0A", "bda054C", "bda054D", "e0100", "e0102", "since_pegc", "dst", "al4",
                "drain", "cr0") if k in d)))
    if "PKW_0_M1" in st and "PKW_R1" in st:
        a, b = st["PKW_0_M1"][0], st["PKW_R1"][0]
        dif = [k for k in a if k not in ("row", "since_pegc") and a.get(k) != b.get(k)]
        txt.append("M and R state before their PKW rows differs in: %s" % (", ".join(dif) or "nothing"))
    # the verdict
    v = []
    pm, pr = m.get("PKW_0_M"), m.get("PKW_R")
    if pm and pr:
        if _differ(pm, pr):
            v.append("SEQUENCE: in one binary the MISAL2 sequence reads %.1f and the RDLAT one %.1f" % (pm, pr))
        else:
            v.append("NOT THE SEQUENCE: in one binary both sequences read %.1f / %.1f (the two "
                     "captures' difference is their binary or boot)" % (pm, pr))
    f1, fa, fl = m.get("PKW1ST_FA"), m.get("PKWAFT_FA"), m.get("PKWLATE_FA")
    if f1 and fl:
        if _differ(f1, fl):
            v.append("TIME SINCE THE 256-COLOUR MODE TURNED ON: %.1f straight after, %.1f 60 frames later" % (f1, fl))
        else:
            v.append("not the time since the 256-colour mode turned on (%.1f / %.1f)" % (f1, fl))
    if f1 and fa and fl and _differ(fa, f1) and not _differ(f1, fl):
        v.append("A PRECEDING PKR row: %.1f after it, %.1f without" % (fa, f1))
    fo, fh = m.get("PKWODD_FA"), m.get("PKWHI_FA")
    if fl and fh and _differ(fl, fh):
        v.append("THE DESTINATION: DI=0 %.1f, DI=4000 %.1f" % (fl, fh))
    c, n, d = m.get("PKW_C"), m.get("PKW_N"), m.get("PKW_D")
    # with CR0.CD set the loop's own code is fetched uncached too and shares the bus with the
    # stores, so the cache-off figure is compared on the net (the row less its control) as well
    def k0net(tag):
        return _mean([r["pit_ns"] - r["ctl_pit_ns"] for r in getattr(cap, "all_rows", cap.rows)
                      if r["sec"] == "PKAB" and r["kind"] == "R" and re.fullmatch(tag + r"\d", r["tag"])
                      and r["nop"] == 0 and not r.get("refused")])
    cn, nn = k0net("PKW_C"), k0net("PKW_N")
    if c and n and cn and nn:
        if _differ(cn, nn):
            v.append("THE L1 CACHE: %.1f on, %.1f off (net of the loop %.1f / %.1f)" % (c, n, cn, nn))
        else:
            v.append("not the L1 cache: %.1f on, %.1f off, but net of the loop %.1f / %.1f (the "
                     "uncached loop's own fetches)" % (c, n, cn, nn))
    if c and d:
        v.append(("THE WRITE BUFFER: %.1f, %.1f with a drain read" if _differ(c, d) else
                  "not the write buffer (%.1f, %.1f with a drain read)") % (c, d))
    rc, rn = m.get("RLWH_C"), m.get("RLWH_N")
    if rc and rn:
        v.append("cache off %s: main memory %.1f ns on, %.1f off" % (
            "TOOK EFFECT" if rn > 1.5 * rc else "DID NOT TAKE EFFECT", rc, rn))
    gs, gw = m.get("GRS_C"), m.get("GRW_C")
    if gs and gw:
        cached = gs < 0.5 * gw
        v.append("GVRAM reads are %s: one address %.1f ns, DI+=4 %.1f" % (
            "CACHED" if cached else "NOT CACHED", gs, gw))
        exp.append(("PKAB.gvram_read_cached", "yes" if cached else "no", "class", R[0]["line"], "GRS vs GRW"))
    ps, pr_ = m.get("PKRS_C"), m.get("PKR_C")
    if ps and pr_:
        v.append("PEGC reads are %s: one address %.1f ns, DI+=4 %.1f" % (
            "CACHED" if ps < 0.5 * pr_ else "NOT CACHED", ps, pr_))
    for x in v:
        txt.append("VERDICT " + x)
    return txt, exp


CELLS_TAG = re.compile(r"^([A-Z]+)_(31|2P|3P|48)([AV])$")
CELLS_MODE = {"31": "31", "2P": "24", "3P": "31", "48": "48"}     # the raster geometry each runs on


@analyser
def cells(cap):
    """/CELLS (item 197): per row FAM_<MODE><PH> the nop-0 ns, the net and the sweep's shape
    (rd_shape, as /RDLAT), the X B8 and X APER rows."""
    R = [r for r in cap.rows if r["sec"] == "CELLS" and r["kind"] == "R" and not r.get("refused")]
    X = [r for r in cap.rows if r["sec"] == "CELLS" and r["kind"] in ("X", "P")]
    if not R and not X:
        return [], []
    txt, exp = [], []
    for r in X:
        d = r["kv"]
        if r["tag"] == "B8":
            txt.append("B8 (0xB8000 with the 256-colour mode on): written A55A off, read %s on; "
                       "written 3CC3 on, read %s on and %s off -> %s" % (
                           d.get("on_rb"), d.get("on_rb2"), d.get("off_rb2"),
                           "- (row incomplete: no on_rb2)" if d.get("on_rb2") is None else
                           "the plane is reachable" if d.get("on_rb2") == "3CC3" else
                           "no plane store lands"))
        elif r["tag"] == "APER":
            ok = d.get("f0_rb") == "1357" and d.get("a8_rb") == "2468"
            okw = d.get("f0_rbw", d.get("f0_rb")) == "1357" and d.get("a8_rbw", d.get("a8_rb")) == "2468"
            txt.append("APER: 0x043B %s -> %s, A20 masked %s, E0102 was %s: 0xF00000 reads %s (%s after WBINVD; "
                       "A8000 wrote 1357), 0xA8002 reads %s (%s after WBINVD; F00002 wrote 2468, which reads %s "
                       "back there) -> %s" % (
                           d.get("43b"), d.get("43b_now"), d.get("a20_masked"), d.get("e0102_was"),
                           d.get("f0_rb"), d.get("f0_rbw", "-"), d.get("a8_rb"), d.get("a8_rbw", "-"),
                           d.get("f0_rb2", "-"), "the aperture is the packed VRAM" if ok else
                           "the aperture is the packed VRAM once the L1 is emptied (the aperture is cached)"
                           if okw else "** the aperture does NOT map the packed VRAM: the PA rows time something else"))
            exp.append(("CELLS.aperture_maps", "yes" if ok else "no", "class", r["line"], "X APER"))
        elif r["kind"] == "P" and r["tag"].startswith("RASTER_"):
            fr, art = num(d.get("frames")) or 0, num(d.get("art")) or 0
            if fr:
                txt.append("%s: %.1f ARTIC ticks/frame" % (r["tag"], art / fr))
    groups = {}
    for r in R:
        mt = CELLS_TAG.match(r["tag"])
        if mt:
            groups.setdefault(mt.groups(), []).append(r)
    for key in sorted(groups):
        fam, mode, ph = key
        rows = sorted(groups[key], key=lambda r: r["nop"])
        if rows[0]["nop"] != 0:
            continue
        r0 = rows[0]
        base = "CELLS.%s.%s%s" % (fam, mode, ph)
        net = r0["pit_ns"] - r0["ctl_pit_ns"]
        exp.append((base + ".k0_ns", "%.1f" % r0["pit_ns"], "ns", r0["line"], "pit nop=0"))
        exp.append((base + ".net_ns", "%.1f" % net, "ns", r0["line"], "pit - ctl_pit nop=0"))
        if len(rows) >= 2:
            sh = rd_shape([(r["nop"], r["pit_ns"], r["ctl_pit_ns"]) for r in rows])
            exp.append((base + ".shape", sh["verdict"], "class", r0["line"], "sweep"))
            txt.append("%-6s %s%s k0 %7.1f ns net %7.1f: hid %6.1f ns at k%d, %.2f -> %-7s (line %d)" % (
                fam, mode, ph, r0["pit_ns"], net, sh["h"], sh["hk"], sh["frac"], sh["verdict"], r0["line"]))
        else:
            txt.append("%-6s %s%s k0 %7.1f ns net %7.1f (one point, line %d)" % (fam, mode, ph, r0["pit_ns"], net, r0["line"]))
    return txt, exp


def hbl_decode(runs, polls, art):
    """runs: [(state, len)], state bit 0 = VSYNC (status bit 5), bit 1 = HBLANK (bit 6), from the
    VSYNC rise. -> dict(period polls, high fraction, phase of the first H rise after the start
    in lines, the VSYNC fall's position and the H phase relative to it, poll_ns)."""
    pos, rises, falls, vfall, hruns = 0, [], [], None, []
    prev = None
    for st, n in runs:
        if prev is not None:
            if (st & 2) and not (prev & 2):
                rises.append(pos)
            if not (st & 2) and (prev & 2):
                falls.append(pos)
            if (prev & 1) and not (st & 1) and vfall is None:
                vfall = pos
        if st & 2:
            hruns.append(n)
        prev, pos = st, pos + n
    res = {"poll_ns": art * TICK_NS / polls if polls else 0.0, "rises": len(rises)}
    if len(rises) >= 3:
        d = [b - a for a, b in zip(rises, rises[1:])]
        per = statistics.median(d)
        res["period"] = per
        hi = [b - a for a in rises for b in falls if b > a][:1]
        full = [n for n in hruns[1:-1]]
        res["high_frac"] = (statistics.median(full) / per) if full else None
        res["phase0"] = (rises[0] % per) / per
        if vfall is not None:
            after = [x for x in rises if x >= vfall]
            if after:
                res["vfall"] = vfall
                res["phase_vfall"] = ((after[0] - vfall) % per) / per
        res["line_us"] = per * res["poll_ns"] / 1000
    return res


@analyser
def k3m(cap):
    """/K3M: IDIV, E0000, PIT one-byte writes, the GDC blank in the line, IDENTIFY read-back."""
    X = [r for r in cap.rows if r["sec"] == "K3M" and r["kind"] == "X"]
    if not X:
        return [], []
    txt, exp = [], []
    pit = {}
    for r in X:
        d = r["kv"]
        if r["tag"] == "IDIV":
            ax = d.get("ax", "")
            txt.append("IDIV B0F8h/1Eh: de=%s AX=%s -> %s" % (d.get("de"), ax,
                       "#DE" if d.get("de") == "1" else "AL=%s AH=%s (z486 / the silicon rule: AL=80 AH=F8; "
                       "the patent's printed AH=36)" % (ax[2:], ax[:2])))
            exp.append(("K3M.IDIV.ax", ax if d.get("de") == "0" else "DE", "hex", r["line"], "X IDIV"))
        elif r["tag"] == "E0000":
            plane = d.get("m16_rb") == "AA55FF00"
            txt.append("E0000: as found (q04=%s) %s; 16-colour mode read %s, wrote AA55FF00 read %s -> %s; put back %s" % (
                d.get("q04"), d.get("asfound"), d.get("m16"), d.get("m16_rb"),
                "the E plane answers" if plane else "NOT a plane", d.get("m16_put")))
            exp.append(("K3M.E0000.m16_plane", "yes" if plane else "no", "class", r["line"], "X E0000"))
        elif r["tag"] == "PIT":
            c = d.get("case")
            pit[c] = num(d.get("out_art")), num(d.get("irr_art")), d.get("st0"), r["line"]
            txt.append("PIT %-9s st0=%s irr0=%s to OUT %s ticks, to IRR %s ticks" % (
                c, d.get("st0"), d.get("irr0"), d.get("out_art"), d.get("irr_art")))
        elif r["tag"] == "HBL":
            runs = []
            for t in d.get("runs", "").strip(",").split(","):
                if len(t) >= 2 and t[0].isdigit():
                    runs.append((int(t[0]), int(t[1:])))
            h = hbl_decode(runs, num(d.get("polls")) or 0, num(d.get("art")) or 0)
            if "period" in h:
                txt.append("HBL port %s: poll %.0f ns, line %.1f polls (%.2f us), blank high %.3f of a line, "
                           "first blank rise %.3f of a line after the VSYNC rise%s" % (
                               d.get("port"), h["poll_ns"], h["period"], h["line_us"],
                               h["high_frac"] or 0, h["phase0"],
                               ", %.3f after the VSYNC fall (poll %d)" % (h["phase_vfall"], h["vfall"])
                               if "phase_vfall" in h else ""))
                pfx = "K3M.HBL.%s" % d.get("port")
                exp.append((pfx + ".high_frac", "%.3f" % (h["high_frac"] or 0), "ratio", r["line"], "runs"))
                exp.append((pfx + ".phase_vrise", "%.3f" % h["phase0"], "line", r["line"], "runs"))
                if "phase_vfall" in h:
                    exp.append((pfx + ".phase_vfall", "%.3f" % h["phase_vfall"], "line", r["line"], "runs"))
            else:
                txt.append("HBL port %s: fewer than three blank rises in %s polls" % (d.get("port"), d.get("polls")))
        elif r["tag"] == "IDEINIT":
            txt.append("IDEINIT (INITIALIZE DEVICE PARAMETERS, the BIOS geometry back): %s" %
                       " ".join("%s=%s" % i for i in d.items()))
        elif r["tag"] == "IDENT":
            nid = sum(1 for x in X if x["tag"] == "IDENT" and x["line"] < r["line"] and x["kv"].get("cmd") == d.get("cmd"))
            f = {}
            for k in ("tf0", "tf1", "tf2"):
                b = d.get(k, "").split(".")
                f[k] = dict(zip("er sc sn cl ch dh alt r433 st".split(), b)) if len(b) == 9 else {}
            t2 = f["tf2"]
            txt.append("IDENT cmd=%s bank=%s: loaded sc=%s sn=%s cl=%s ch=%s; at DRQ/BSY-clear st=%s er=%s "
                       "sc=%s; after the block st=%s er=%s sc=%s sn=%s cl=%s ch=%s dh=%s (words=%s crc=%s)" % (
                           d.get("cmd"), d.get("bank"), f["tf0"].get("sc"), f["tf0"].get("sn"),
                           f["tf0"].get("cl"), f["tf0"].get("ch"), f["tf1"].get("st"), f["tf1"].get("er"),
                           f["tf1"].get("sc"), t2.get("st"), t2.get("er"), t2.get("sc"), t2.get("sn"),
                           t2.get("cl"), t2.get("ch"), t2.get("dh"), d.get("words"), d.get("crc")))
            for k in ("er", "sc", "sn", "cl", "ch", "dh", "st"):
                if k in t2:
                    exp.append(("K3M.IDENT_%s%s.after.%s" % (d.get("cmd"), "" if not nid else "_%d" % (nid + 1), k),
                                t2[k], "hex", r["line"], "X IDENT tf2"))
            if d.get("w54"):
                txt.append("IDENT cmd=%s: current geometry (words 53-56) %s cyl %d heads %d sectors %d" % (
                    d.get("cmd"), d.get("w53"), int(d["w54"], 16), int(d["w55"], 16), int(d["w56"], 16)))
    # PIT retention: the one-byte write's time against its two candidate counts' controls
    for case, keep, zero, what in (("L1234_56", "C1256", "C0056", "an LSB-only write"),
                                   ("M12F0_01", "C01F0", "C0100", "an MSB-only write")):
        if case in pit and keep in pit and zero in pit:
            # the read-back status's OUT bit when the PIT answers the read-back command, else
            # the master IRR bit 0 (both polled in the same loop; 65535 = not seen in 10 ms)
            src = 0 if all(pit[c][0] not in (None, 0xFFFF) for c in (case, keep, zero)) else 1
            t, k, z = pit[case][src], pit[keep][src], pit[zero][src]
            if None in (t, k, z) or 0xFFFF in (t, k, z):
                verdict = "UNDECIDED (OUT and IRR not seen)"
            else:
                verdict = "KEEPS the other byte" if abs(t - k) < abs(t - z) else "ZEROES the other byte"
            txt.append("PIT %s: %s ticks (%s) against %s (kept) and %s (zeroed) -> %s" % (
                what, t, "OUT" if src == 0 else "IRR", k, z, verdict))
            exp.append(("K3M.PIT.%s" % case, verdict.split()[0], "class", pit[case][3], "X PIT"))
    return txt, exp


def x_compare(a, b, sec, out):
    """Machine (a) vs core (b): every X row of section sec, field by field."""
    def keyed(cap):
        k, seen = {}, {}
        for r in cap.rows:
            if r["sec"] == sec and r["kind"] == "X":
                key = (r["tag"], r["kv"].get("cfg", ""), r["kv"].get("mode", ""))
                seen[key] = seen.get(key, 0) + 1
                k[key + (seen[key],)] = r
        return k
    ka, kb = keyed(a), keyed(b)
    if not ka and not kb:
        return
    out.write("%s %-30s %-22s %-22s\n" % (sec, "row.field", a.name[-22:], b.name[-22:]))
    for k in list(ka) + [k for k in kb if k not in ka]:
        x, y = ka.get(k), kb.get(k)
        r = x or y
        for f in r["kv"]:
            va = x["kv"].get(f, "-") if x else "(absent)"
            vb = y["kv"].get(f, "-") if y else "(absent)"
            out.write("%s %-30s %-22s %-22s%s\n" % (sec, "%s%s.%s" % (k[0], "." + k[1] + k[2] if k[1] else "", f),
                                                   va[:22], vb[:22], "" if va == vb else "  *"))


def fdc2_compare(a, b, out):
    """Machine (a) vs core (b) for the FDC2 X rows, with NP2kai's expectation beside them."""
    ra = [r for r in a.rows if r["sec"] == "FDC2" and r["kind"] == "X"]
    rb = [r for r in b.rows if r["sec"] == "FDC2" and r["kind"] == "X"]
    if not ra and not rb:
        return

    def keyed(rows):
        out_, seen = {}, {}
        for r in rows:
            k = (r["tag"], r["kv"].get("da", "-"), r["kv"].get("motor", ""))
            seen[k] = seen.get(k, 0) + 1
            out_[k + (seen[k],)] = r
        return out_

    ka, kb = keyed(ra), keyed(rb)
    out.write("FDC2 %-28s %-22s %-22s %s\n" % ("row.field", a.name[-22:], b.name[-22:], "NP2kai"))
    for k in list(ka) + [k for k in kb if k not in ka]:
        x, y = ka.get(k), kb.get(k)
        r = x or y
        fields = list(fdc2_expect(r["tag"], r["kv"])) or [f for f in r["kv"] if f != "da"]
        for f in fields:
            va = x["kv"].get(f, "-") if x else "(absent)"
            vb = y["kv"].get(f, "-") if y else "(absent)"
            e = fdc2_expect(r["tag"], r["kv"]).get(f)
            out.write("FDC2 %-28s %-22s %-22s %s%s\n" % (
                "%s.%s.%s" % (k[0], k[1], f), va, vb, e[0][0] if e else "-",
                "" if va == vb else "  *"))


def fmt_t(cap, name, v):
    if name.endswith("_pit"):
        s = 1e9 / (ratio_of(cap) * ARTIC_HZ)
        return "%s=%d/%d/%d (%.2f us med)" % (name, v[0], v[1], v[2], v[1] * s / 1000)
    if name.endswith("_art"):
        return "%s=%d/%d/%d (%.2f us med)" % (name, v[0], v[1], v[2], v[1] * TICK_NS / 1000)
    return "%s=%d/%d/%d" % (name, v[0], v[1], v[2])


# The per-section analysers: name -> fn(cap) -> (text lines, expect tuples). report() prints each
# one's text under its section and expect_lines() merges every one's tuples, in this order, from
# this one list (they were a report() if-chain and a hand-kept expect list that had lost PKAB,
# CELLS and K3M). rep_spread (the /REP passes, not a section) is added after them.
SECTION_ANALYSERS = (
    ("OPNA2", opna2), ("OPNA3", opna3), ("AUDIT", audit), ("FDC2", fdc2), ("OPNA4", opna4),
    ("AUDIT2", audit2), ("MISAL", misal), ("MISAL2", misal2), ("RDLAT", rdlat), ("PKAB", pkab),
    ("CELLS", cells), ("K3M", k3m),
)


def report(cap, out=None):
    out = out or sys.stdout
    w = out.write
    h = cap.header or {}
    w("== %s: XE10T v%s sha=%s args=%s tag=%s\n" % (cap.name, h.get("ver", "?"), h.get("sha", "?"),
                                                   h.get("args", "?"), h.get("tag", "?")))
    c = cap.cal
    if c:
        w("-- CAL: ratio=%s pit/artic (nominal 8.000)  pit_mod=%s  pitedge_mod=%s  "
          "vsync=%s ticks/frame (%s Hz)  tsc=%s MHz  verdict=%s why=%s strap0501=%s\n" % (
              "%.4f" % c["ratio"] if "ratio" in c else "-", c.get("pit_mod", "-"),
              "%.1f" % c["pitedge_mod"] if "pitedge_mod" in c else "-",
              "%.2f" % c["vsync_ticks"] if "vsync_ticks" in c else "-",
              "%.3f" % c["vsync_hz"] if "vsync_hz" in c else "-",
              "%.2f" % c["tsc_mhz"] if "tsc_mhz" in c else "-",
              c.get("verdict", "-"), c.get("why", "-"), c.get("strap0501", "-")))
    for s in cap.sections:
        w("-- %s%s%s\n" % (s["name"], " (pass %d)" % (s["pass"] + 1) if s.get("pass") else "",
                           "" if s["closed"] else "  ** TRUNCATED (no END) **"))
        if s.get("pass"):
            continue                        # a later /REP pass: the spread table below reads it
        rs = [r for r in cap.rows if r["section"] is s]
        if any(r["kind"] == "R" for r in rs):
            w("   %-14s %4s %6s %10s %10s %10s %10s  %s\n" %
              ("tag", "nop", "n", "gross_ns", "ctl_ns", "net_ns", "pit_ns", "flags"))
        for r in rs:
            k = r["kind"]
            if k == "R":
                w("   %-14s %4d %6d %10.1f %10.1f %10s %10.1f  %s\n" % (
                    r["tag"], r["nop"], r["n"], r["gross_ns"], r["ctl_ns"],
                    "%.1f" % r["net_ns"] if "net_ns" in r else "-", r["pit_ns"],
                    ",".join(r["flags"])))
            elif k == "T":
                w("   T %-12s %s %s\n" % (r["tag"], " ".join(fmt_t(cap, n, v) for n, v in
                                                            r["fields"].items()),
                                         ",".join(r["flags"])))
            elif k in ("P", "X"):
                w("   %s %-12s %s\n" % (k, r["tag"], " ".join("%s=%s" % i for i in r["kv"].items())))
            else:
                w("   %s\n" % r["text"])
        for nm, fn in SECTION_ANALYSERS:
            if s["name"] == nm:
                for t in fn(cap)[0]:
                    w("   %s %s\n" % (nm, t))
        for (sec, tag), res in cap.sweeps.items():
            if sec == s["name"]:
                w("   SWEEP %-10s period %s%.1f ns  shell %.1f ns  issue %s ns  knee nop=%s  "
                  "resid %.3f %s\n" % (
                    tag, res["bound"], res["period"], res["shell"],
                    "-" if res["issue"] is None else "%.1f" % res["issue"], res["knee"],
                    res["residual"], res["flag"]))
    sp = rep_spread(cap)[0]
    if sp:
        w("-- REP: the spread of every row across the /REP passes\n")
        for t in sp:
            w("   %s\n" % t)
    ras = raster_rows(cap)
    if ras:
        w("-- RASTER (visual: compare these with the photograph / capture of each phase)\n")
        for x in ras:
            if not x["frames"]:
                w("   %-8s no frames (VSYNC timeouts=%d)\n" % (x["tag"], x["to"]))
                continue
            w("   %-8s frames=%d at %.1f lines after VSYNC (display line ~%.0f, jitter %.1f "
              "lines) burst %.1f us = %.1f lines%s\n" % (
                  x["tag"], x["frames"], x["at_lines"], x["display_line"], x["jitter_lines"],
                  x["burst_us"], x["band_lines"],
                  "  one out = %.0f ns = %.1f dots" % (x["ns_per_out"], x["dots_per_out"])
                  if "ns_per_out" in x else ""))
            w("            look for: %s\n" % RASTER_LOOK.get(x["tag"], "-"))
    w("-- flags (%d):\n" % len(cap.flags))
    for no, code, det in cap.flags:
        w("   line %d %s %s\n" % (no, code, det))


def expect_lines(cap):
    src = cap.name.replace("\\", "/").rsplit("/", 1)[-1]
    out, seen = [], set()

    def add(name, val, unit, line, method):
        if name in seen:
            return
        seen.add(name)
        trust = " trust=untrusted" if cap.untrusted else ""
        out.append("%s %s %s source=%s:%d method=%s%s" % (name, val, unit, src, line, method, trust))

    c = cap.cal
    if "ratio" in c:
        add("CAL.pit_per_artic", "%.5f" % c["ratio"], "ratio", c.get("ratio_line", 0), "median")
    if num(c.get("pit_mod")):
        add("CAL.pit_mod", c["pit_mod"], "counts", c.get("info_line", 0), "median")
    if "vsync_ticks" in c:
        add("CAL.vsync_ticks", "%.2f" % c["vsync_ticks"], "ticks", c["vsync_line"], "period")
        add("CAL.vsync_hz", "%.4f" % c["vsync_hz"], "Hz", c["vsync_line"], "period")
    if "tsc_mhz" in c:
        add("CAL.tsc_mhz", "%.3f" % c["tsc_mhz"], "MHz", c.get("info_line", 0), "median")
    for x in raster_rows(cap):
        if not x["frames"]:
            continue
        base = "RASTER.%s" % x["tag"]
        add(base + ".display_line", "%.1f" % x["display_line"], "line", x["line"], "mean")
        add(base + ".burst_us", "%.2f" % x["burst_us"], "us", x["line"], "mean")
        if "ns_per_out" in x:
            add(base + ".ns_per_out", "%.1f" % x["ns_per_out"], "ns", x["line"], "mean")
            add(base + ".dots_per_out", "%.2f" % x["dots_per_out"], "dots", x["line"], "mean")
    for r in cap.rows:
        base = "%s.%s" % (r["sec"], r["tag"])
        if r["kind"] == "R" and not r.get("refused"):
            sw = cap.sweeps.get((r["sec"], r["tag"]))
            if r["nop"] == 0:
                add(base + ".gross_ns", "%.1f" % r["gross_ns"], "ns", r["line"], "gross")
                if not sw:      # R1: a net figure only for blocking (unswept) rows
                    add(base + ".net_ns", "%.1f" % r["net_ns"], "ns", r["line"], "net")
            if sw and r["line"] == sw["line"]:
                if sw["flag"] not in ("NO-PLATEAU", "PLATEAU-NOT-FLAT"):
                    add(base + ".period_ns", "%.1f" % sw["period"], "ns", r["line"], "period")
                elif sw["flag"] == "NO-PLATEAU":
                    add(base + ".period_max_ns", "%.1f" % sw["period"], "ns", r["line"], "period")
                add(base + ".shell_ns", "%.1f" % sw["shell"], "ns", r["line"], "knee")
                if sw["issue"] is not None:
                    add(base + ".issue_ns", "%.1f" % sw["issue"], "ns", r["line"], "knee")
                if sw["knee"] is not None:
                    add(base + ".knee_nop", sw["knee"], "nops", r["line"], "knee")
        elif r["kind"] == "T":
            for fname, v in r["fields"].items():
                add("%s.%s_med" % (base, fname), v[1], fname.rsplit("_", 1)[-1] if "_" in fname
                    else "count", r["line"], "median")
    for _, fn in SECTION_ANALYSERS:
        for e in fn(cap)[1]:
            add(*e)
    for e in rep_spread(cap)[1]:
        add(*e)
    return out


def row_values(cap):
    """(key) -> (value, label) for side-by-side."""
    vals = {}
    for r in cap.rows:
        if r["kind"] == "R" and not r.get("refused"):
            key = "%s.%s.nop%d" % (r["sec"], r["tag"], r["nop"])
            vals[key + ".gross_ns"] = r["gross_ns"]
            if "net_ns" in r and (r["sec"], r["tag"]) not in cap.sweeps:
                vals[key + ".net_ns"] = r["net_ns"]
        elif r["kind"] == "T":
            for f, v in r["fields"].items():
                vals["%s.%s.%s_med" % (r["sec"], r["tag"], f)] = v[1]
    for (sec, tag), sw in cap.sweeps.items():
        vals["%s.%s.period_ns" % (sec, tag)] = sw["period"]
    for k in ("ratio", "vsync_ticks", "tsc_mhz"):
        if k in cap.cal:
            vals["CAL." + k] = cap.cal[k]
    return vals


def compare(a, b, band, force, out=None):
    out = out or sys.stdout
    ha, hb = a.header or {}, b.header or {}
    for f in ("sha", "args"):
        if ha.get(f) != hb.get(f) and not force:
            out.write("REFUSED: %s differs (%r vs %r); the two captures are not the same binary "
                      "and run (--force to override)\n" % (f, ha.get(f), hb.get(f)))
            return 2
    va, vb = row_values(a), row_values(b)
    out.write("%-44s %12s %12s %8s\n" % ("quantity", a.name[-12:], b.name[-12:], "B/A"))
    marked = 0
    for k in list(va) + [k for k in vb if k not in va]:
        x, y = va.get(k), vb.get(k)
        if x is None or y is None:
            out.write("%-44s %12s %12s %8s\n" % (k, "-" if x is None else "%.1f" % x,
                                                 "-" if y is None else "%.1f" % y, "-"))
            continue
        r = y / x if x else float("inf")
        m = "*" if abs(r - 1) * 100 > band else ""
        marked += bool(m)
        out.write("%-44s %12.1f %12.1f %8.3f %s\n" % (k, x, y, r, m))
    out.write("%d quantities outside +-%g%%\n" % (marked, band))
    fdc2_compare(a, b, out)
    x_compare(a, b, "AUDIT2", out)
    for t in opna4(a)[0] + opna4(b)[0]:
        out.write("OPNA4 %s\n" % t)
    ma, mb = misal(a), misal(b)
    m2a, m2b = misal2(a), misal2(b)
    rda, rdb = rdlat(a), rdlat(b)
    ma, mb = (ma[0], ma[1] + m2a[1] + rda[1]), (mb[0], mb[1] + m2b[1] + rdb[1])
    if ma[1] or mb[1]:
        ea, eb = dict((e[0], e[1]) for e in ma[1]), dict((e[0], e[1]) for e in mb[1])
        out.write("MISAL %-40s %10s %10s\n" % ("quantity", "A", "B"))
        for k in list(ea) + [k for k in eb if k not in ea]:
            out.write("MISAL %-40s %10s %10s\n" % (k, ea.get(k, "-"), eb.get(k, "-")))
    return 0


# ----------------------------------------------------------------------------- selftest
def synth(sections, sha="0123456789abcdef", crc="DEADBEEF", imgcrc=None, args="/ALL",
          bad_sum=None, bad_done=False, done=True):
    """Build a capture with correct CRCs. sections: [(name, [body lines])]."""
    out = b"XE10T v1 sha=%s crc=%s imgcrc=%s size=30000 build=selftest args=%s tag=-\r\n" % (
        sha.encode(), crc.encode(), (imgcrc or crc).encode(), args.encode())
    for name, body in sections:
        b = "".join(l + "\r\n" for l in body).encode()
        rows = sum(1 for l in body if l.split(" ", 1)[0] in MEAS)
        s = crc16(b) ^ (1 if bad_sum == name else 0)
        out += b"BEGIN:%s\r\n" % name.encode() + b + b"END:%s rows=%d sum=%04X\r\n" % (
            name.encode(), rows, s)
    if done:
        out += b"XE10T DONE sections=%d sum=%08X\r\n" % (
            len(sections), crc32(out) ^ (1 if bad_done else 0))
    return out


def rrow(sec, tag, n, nop, gross_ns, ctl_ns, shell="1A2B", bshell=None, cal_ratio=8.0, mod=24576):
    a = round(gross_ns * n / TICK_NS)
    c = round(ctl_ns * n / TICK_NS)
    p, cp = round(a * cal_ratio) % mod, round(c * cal_ratio) % mod
    return ("R %s %s unit=w n=%d nop=%d rep=5 art=%d/%d/%d pit=%d/%d/%d ctl_art=%d/%d/%d "
            "ctl_pit=%d/%d/%d shell=%s bshell=%s" % (sec, tag, n, nop, a, a, a, p, p, p, c, c, c,
                                                    cp, cp, cp, shell, bshell or shell))


CAL_OK = ["I CAL pit_order=0 strap0501=48 pit_mod=24576 ratio_x1000=8000 vsync_x10=54450 "
          "tsc_khz=- verdict=OK why=-",
          "P CAL PITWIN i=0 art=2500 pit=20000", "P CAL PITWIN i=1 art=2600 pit=20800",
          "P CAL PITEDGE edges=40 art=122880 vmax=24575 vmin=0",
          "P CAL VSYNC edges=60 art=326700 pit=2613600 tsc=-"]


def sweep_rows(tag, period, shell0, per_nop, n=8192, issue=0.0):
    return [rrow("GVRAM", tag, n, k, max(period, shell0 + per_nop * k + issue), shell0 + per_nop * k)
            for k in (0, 2, 4, 8, 16, 32)]


def codes(cap):
    return {f[1] for f in cap.flags}


def selftest():
    fails = []

    def check(name, cond):
        print("  %-48s %s" % (name, "ok" if cond else "FAIL"))
        if not cond:
            fails.append(name)

    gv = sweep_rows("W16SEQ", 290.0, 100.0, 10.0)
    io = [rrow("IO", "R0060", 1024, 0, 900.0, 80.0)]
    tl = ["T OPNA BUSY_FM trials=32 busy_pit=50/60/70 polls=5/6/7", "I OPNA vec60=0000:0000",
          "RESTORE OPNA reg30 was=- now=- kind=default OK"]
    base = [("ID", ["I ID cpuid=no"]), ("CAL", CAL_OK), ("GVRAM", gv), ("IO", io), ("OPNA", tl)]
    clean = synth(base)
    cap = parse(clean, "CLEAN.TXT")
    check("clean capture: no flags", cap.flags == [])
    sw = cap.sweeps.get(("GVRAM", "W16SEQ"))
    check("sweep period 290 ns within 1%", sw is not None and abs(sw["period"] - 290) / 290 < 0.01)
    check("sweep shell 100 ns within 1%", sw is not None and abs(sw["shell"] - 100) / 100 < 0.01)
    check("sweep knee at nop=32", sw is not None and sw["knee"] == 32)
    io_r = [r for r in cap.rows if r["kind"] == "R" and r["sec"] == "IO"][0]
    check("net = gross - control (820 ns)", abs(io_r["net_ns"] - 820) < 5)
    check("CAL ratio 8.000 from PITWIN", abs(cap.cal["ratio"] - 8.0) < 1e-9)
    check("CAL vsync 5445 ticks", abs(cap.cal["vsync_ticks"] - 5445) < 0.01)
    exp = expect_lines(cap)
    check("expect: GVRAM.W16SEQ.period_ns emitted",
          any(l.startswith("GVRAM.W16SEQ.period_ns 2") for l in exp))
    check("expect: OPNA.BUSY_FM.busy_pit_med 60",
          any(l.startswith("OPNA.BUSY_FM.busy_pit_med 60 ") for l in exp))
    check("expect: no net for a swept (posted) row",
          not any(l.startswith("GVRAM.W16SEQ.net_ns") for l in exp) and
          any(l.startswith("IO.R0060.net_ns 82") for l in exp))
    check("expect: source line cited", all(":%d " % 0 not in l for l in exp if "GVRAM" in l))

    # ROW lines: legal, not counted as rows; a hang after one is reported with it
    rw = synth([("CAL", CAL_OK), ("IO", ["ROW IO R8_0060 port=0060"] + io +
                                  ["ROW IO R8_04A1 port=04A1"])])
    check("ROW lines: no flags, not counted", parse(rw).flags == [])
    cutr = rw.index(b"ROW IO R8_04A1") + len(b"ROW IO R8_04A1 port=04A1\r\n")
    tr = parse(rw[:cutr], "HANG.TXT")
    check("truncation names the last ROW (R8_04A1)",
          any(f[1] == "TRUNCATED" and "R8_04A1" in f[2] for f in tr.flags))
    # truncated mid-section
    cut = clean.index(b"BEGIN:IO") + 40
    t = parse(clean[:cut] + b"\x1a\x00\x00", "TRUNC.TXT")
    check("truncation reported at IO", any(f[1] == "TRUNCATED" and "IO" in f[2] for f in t.flags)
          and "DONE-MISSING" in codes(t))
    check("truncated capture keeps earlier sections", any(s["name"] == "GVRAM" and s["closed"]
                                                           for s in t.sections))
    # bad section sum, bad done
    check("bad section sum flagged", "SUM-BAD" in codes(parse(synth(base, bad_sum="GVRAM"))))
    check("bad DONE crc flagged", "DONE-BAD" in codes(parse(synth(base, bad_done=True))))
    check("LF-converted capture still verifies",
          parse(clean.replace(b"\r\n", b"\n")).flags == [])
    # control mismatch
    cm = parse(synth([("IO", [rrow("IO", "R0062", 1024, 0, 900, 80, shell="1111",
                                    bshell="2222")])]))
    check("CONTROL-MISMATCH refused", "CONTROL-MISMATCH" in codes(cm) and
          all(r.get("refused") for r in cm.rows if r["kind"] == "R"))
    # no plateau / knee not found
    np_ = parse(synth([("CAL", CAL_OK), ("GVRAM", sweep_rows("HIDDEN", 50.0, 100.0, 10.0))]))
    check("NO-PLATEAU flagged", "NO-PLATEAU" in codes(np_))
    kn = parse(synth([("CAL", CAL_OK), ("GVRAM", sweep_rows("SLOW", 1000.0, 100.0, 10.0))]))
    check("KNEE-NOT-FOUND flagged", "KNEE-NOT-FOUND" in codes(kn))
    # the access's own issue cost: past the knee gross follows control + issue, not control
    # (a core capture, 2026-11-01: W16 145.8 ns flat to k=8, then ctl + 33.4 ns)
    ic = parse(synth([("CAL", CAL_OK), ("GVRAM", sweep_rows("ISSUE", 145.8, 20.7, 11.1, issue=33.4))]))
    isw = ic.sweeps.get(("GVRAM", "ISSUE"))
    check("issue cost: period 145.8 ns, knee nop=8, no flag",
          isw is not None and abs(isw["period"] - 145.8) < 0.5 and isw["knee"] == 8
          and abs(isw["issue"] - 33.4) < 0.5 and not codes(ic))
    bl = parse(synth([("CAL", CAL_OK), ("GVRAM", sweep_rows("BLOCK", 0.0, 20.0, 11.0, issue=130.0))]))
    check("blocking access (constant excess): NO-PLATEAU", "NO-PLATEAU" in codes(bl))
    sl = parse(synth([("CAL", CAL_OK), ("GVRAM", [rrow("GVRAM", "SLOPE", 4096, k, c + e, c)
                       for k, c, e in ((0, 22.3, 39.7), (2, 44.5, 40.5), (4, 66.8, 40.5),
                                       (8, 110.5, 38.1), (16, 199.5, 33.4), (32, 377.5, 33.4))])]))
    check("excess wobble above the issue line: PLATEAU-NOT-FLAT", "PLATEAU-NOT-FLAT" in codes(sl))
    # side by side refuses a different binary
    other = parse(synth(base, sha="fedcba9876543210"))
    import io as _io
    sink = _io.StringIO()
    check("side by side refuses different sha", compare(cap, other, 10, False, sink) == 2)
    check("side by side runs on same sha", compare(cap, parse(synth(base)), 10, False, sink) == 0)
    # CAL FAIL
    cf = [l.replace("verdict=OK why=-", "verdict=FAIL why=ratio") for l in CAL_OK]
    cfc = parse(synth([("CAL", cf), ("GVRAM", gv)]))
    check("CAL FAIL marks rows untrusted", "CAL-FAIL" in codes(cfc) and
          all("UNTRUSTED" in r["flags"] for r in cfc.rows if r["kind"] == "R"))
    # phase-misaligned VSYNC window (the probe2 W5 fencepost: 63.2 frames reported as 64)
    pm = [l if not l.startswith("P CAL VSYNC") else
          "P CAL VSYNC edges=64 art=%d pit=0 tsc=-" % round(63.2 * 5445) for l in CAL_OK]
    check("phase-misaligned VSYNC flagged", "PHASE-MISALIGNED" in codes(parse(synth([("CAL", pm)]))))
    two = CAL_OK + ["P CAL VSYNC edges=60 art=%d pit=0 tsc=-" % round(60 * 5445 * 1.01)]
    check("VSYNC row 1% off its sibling flagged", "PHASE-MISALIGNED" in codes(parse(synth([("CAL", two)]))))
    dash = [l.replace("pit_mod=24576", "pit_mod=-") for l in CAL_OK]
    dc = parse(synth([("CAL", dash), ("GVRAM", gv)]))
    check("'-' for an unmeasured CAL value tolerated", dc.flags == [] and dc.cal["mod"] == 65536)
    sfx = parse(synth([("EGC", [rrow("EGC", "EGCWP1", 4096, 0, 300, 100).replace("unit=w", "unit=grp")])]))
    check("suffixed tag and free unit word parsed", sfx.flags == [] and sfx.rows[0]["tag"] == "EGCWP1")
    # image corrupt, watchdog, restore fail, fault
    check("IMAGE-CORRUPT flagged", "IMAGE-CORRUPT" in codes(parse(synth(base, imgcrc="00000000"))))
    wd = parse(synth([("EGC", ["WATCHDOG EGC elapsed=3072000",
                               "RESTORE EGC 006A was=00 now=04 kind=readback FAIL"]),
                      ("PEGC", ["FAULT PEGC after=EGC", rrow("PEGC", "W8", 4096, 0, 300, 100)])]))
    check("WATCHDOG / RESTORE FAIL / FAULT reported",
          {"WATCHDOG", "RESTORE-FAIL", "FAULT"} <= codes(wd) and
          all("AFTER-FAULT" in r["flags"] for r in wd.rows if r["kind"] == "R"))
    # PIT unwrap on a window longer than one PIT period
    long_ = parse(synth([("CAL", CAL_OK), ("EGC", [rrow("EGC", "RD", 16384, 0, 900, 100)])]))
    lr = [r for r in long_.rows if r["kind"] == "R"][0]
    check("PIT unwrapped past the modulus", "PIT-DISAGREE" not in lr["flags"] and
          abs(lr["pit_ns"] - lr["gross_ns"]) / lr["gross_ns"] < 0.001)
    # stamp round trip
    img = b"\x90" * 100 + STAMP_MARK + b"0" * STAMP_LEN + (190).to_bytes(2, "little") + b"\xc3" * 50
    s1, sha, crc = stamp_bytes(img)
    s2, sha2, crc2 = stamp_bytes(s1)
    check("stamp idempotent", s1 == s2 and sha == sha2 and crc == crc2 and s1 != img)
    j = s1.find(STAMP_MARK) + len(STAMP_MARK)
    zeroed = s1[:j] + b"0" * STAMP_LEN + s1[j + STAMP_LEN:]
    check("stamp = sha256/crc32 of the zeroed image",
          sha == hashlib.sha256(zeroed).hexdigest()[:16] and crc == "%08X" % crc32(zeroed[:190])
          and s1[j:j + 24] == (sha + crc).encode())
    # /RASTER: the visual section's P rows. 300 frames, the split 2722 ticks after the edge
    # (half of 5445: 220 lines, display line (407 + 220) % 440 = 187), the toggle band
    # 1024 outs in 330 ticks (1074.2 us; 1049 ns per out = 22.1 dots)
    rs = ["STATE RASTER visual q04=00 lines_per_frame=440 vsync_line=407",
          "P RASTER SPLIT frames=300 to=0 target=2722 at_min=2722 at_max=2724 at_sum=%d "
          "dur_min=1 dur_max=2 dur_sum=450 outs=1024" % (300 * 2722 + 300),
          "P RASTER TOGGLE frames=300 to=0 target=1800 at_min=1800 at_max=1801 at_sum=540000 "
          "dur_min=330 dur_max=330 dur_sum=99000 outs=1024",
          "P RASTER DTOGGLE frames=0 to=300 target=1800 at_min=4294967295 at_max=0 at_sum=0 "
          "dur_min=4294967295 dur_max=0 dur_sum=0 outs=1024",
          "RESTORE RASTER q04_colour_mode was=00 now=00 kind=readback OK"]
    rc = parse(synth([("CAL", CAL_OK), ("RASTER", rs)]), "RASTER.TXT")
    rr = {x["tag"]: x for x in raster_rows(rc)}
    check("RASTER section parses clean", rc.flags == [])
    check("RASTER SPLIT at display line 187",
          abs(rr["SPLIT"]["at_lines"] - 220.0) < 0.1 and round(rr["SPLIT"]["display_line"]) == 187)
    check("RASTER TOGGLE: 1049 ns = 22.1 dots per out",
          abs(rr["TOGGLE"]["ns_per_out"] - 330 * TICK_NS / 1024) < 0.01 and
          abs(rr["TOGGLE"]["dots_per_out"] - 22.08) < 0.05 and
          abs(rr["TOGGLE"]["band_lines"] - 26.67) < 0.05)
    check("RASTER phase with no frames reported, not derived", rr["DTOGGLE"]["frames"] == 0
          and "at_lines" not in rr["DTOGGLE"])
    rx = expect_lines(rc)
    check("expect: RASTER.TOGGLE.dots_per_out 22.09",
          any(l.startswith("RASTER.TOGGLE.dots_per_out 22.09 dots") for l in rx))
    # garbage after a valid run is tolerated only as trailing ^Z/NUL
    check("trailing ^Z/NUL tolerated", parse(clean + b"\x1a\x00", "Z").flags == [])
    # /OPNA2: synthetic records of a YM2608 at 0x188, nothing at 0x288, a YM2203-like
    # device at 0x088 (no ID register), timers at 18.029 us/count with a 5 us start latency
    pc = lambda t_us: round(t_us * 2.4576)          # PIT counts at the nominal 8.000 ratio
    o2 = ["STATE OPNA2 a460=40 imr_s=75 imr_m=00 vec60=00603673 builtin=see-run-notes",
          "X OPNA2 ID b=0188 st=00 st2=00 d=00 e=FF f=FF"]
    for e, s4 in (("0", "FF"), ("1", "00")):
        o2.append("X OPNA2 IDC b=0188 ext=%s a460=4%s id=01 id2=01 r0e=FF r0f=FF r10=00 r20=00 "
                  "w5a=5A wa5=A5 st=00 s4=%s s6=%s x00=00 xff=00" % (e, e, s4, s4))
    o2 += ["X OPNA2 ID b=0288 st=FF st2=FF d=FF e=FF f=FF",
           "X OPNA2 ID b=0088 st=00 st2=00 d=00 e=FF f=FF"]
    for e in ("0", "1"):
        o2.append("X OPNA2 IDC b=0088 ext=%s a460=4%s id=00 id2=00 r0e=FF r0f=FF r10=00 r20=00 "
                  "w5a=5A wa5=A5 st=00 s4=FF s6=FF x00=FF xff=FF" % (e, e))
    o2 += ["X OPNA2 BUSY_FM30_088 i=H polls_h=16,0,0,0,0,0,0,0,0 pit_h=0,16,0,0,0,0,0,0,0,0,0,0,0,0,0,0",
           "T OPNA2 BUSY_FM30_088 trials=16 busy_pit=11/12/14 polls=1/1/1",
           "T OPNA2 TMRA_3F0_088 trials=4 start_pit=%d/%d/%d reads=100/100/100" % ((pc(16 * 18.029 + 5),) * 3)]
    o2 += ["X OPNA2 BUSY_FM30 i=%d dly=%d polls=1 pit=13" % (i, i * 37 & 127) for i in range(32)]
    o2 += ["X OPNA2 BUSY_FM30 i=H polls_h=124,0,0,0,0,0,0,4,0 pit_h=0,124,0,0,0,0,0,0,4,0,0,0,0,0,0,0",
           "T OPNA2 BUSY_FM30 trials=128 busy_pit=11/13/73 polls=1/1/29"]
    o2 += ["X OPNA2 B2B_SSG i=%d v1=%02X v2=%02X st=00 r0b=%02X r0c=%02X" % (
        i, 0x11 + i, 0x22 + i, 0x11 + i, 0x22 + i if i else 0x00) for i in range(8)]
    # B2B_TMR: six trials land both loads but wait out a 29 us BUSY before the polled start
    # (their whole-trial time is nearer 8 counts than 6: the old decoder called them
    # "0x25 lost"; the flag-poll reads, 0.25 us each in the TMRA rows below, time 6 counts
    # from the start write), one genuine 8-count trial and one 1022-count one.
    o2 += ["X OPNA2 B2B_TMR i=%d reads=%d pit=%d art=%d st=01" % (
        i, round((6 * 18.029 + 5) / 0.25), pc(6 * 18.029 + 5 + 29 + 4),
        round((6 * 18.029 + 38) / 3.2552)) for i in range(6)]
    o2 += ["X OPNA2 B2B_TMR i=6 reads=%d pit=%d art=%d st=01" % (
        round((8 * 18.029 + 5) / 0.25), pc(8 * 18.029 + 9), round((8 * 18.029 + 9) / 3.2552))]
    o2 += ["X OPNA2 B2B_TMR i=7 reads=9000 pit=0 art=%d st=01" % round(1022 * 18.029 / 3.2552)]
    o2 += ["X OPNA2 B2B_TMR3 i=0 reads=33536 pit=8688 art=9279 st=00"]
    o2 += ["X OPNA2 FR_TMRA i=%d st0=01 st1=00 stl=00 reads=1 pit=5 irr0=10 irr1=%s irrn=%d irrpit=%d"
           % (i, "10" if i < 4 else "00", 3 if i < 4 else 1, 9) for i in range(32)]
    o2 += ["T OPNA2 FR_TMRA trials=32 reads=1/1/1 busy_pit=5/5/5 irr_reads=1/1/3 irr_pit=9/9/9"]
    o2 += ["X OPNA2 FR_TMRB i=%d st0=02 st1=02 stl=00 reads=2 pit=7 irr0=10 irr1=10 irrn=2 irrpit=12"
           % i for i in range(32)]
    o2 += ["T OPNA2 FR_TMRB trials=32 reads=2/2/2 busy_pit=7/7/7 irr_reads=2/2/2 irr_pit=12/12/12"]
    for na in (0x3FF, 0x3FC, 0x3F0, 0x3C0):
        v = pc((1024 - na) * 18.029 + 5)
        rd = round(((1024 - na) * 18.029 + 5) / 0.25)
        o2.append("T OPNA2 TMRA_%03X trials=8 start_pit=%d/%d/%d reads=%d/%d/%d" % (
            na, v, v, v, rd, rd, rd))
    for nb in (0xFF, 0xFC):
        v = pc((256 - nb) * 288.46 + 5)
        o2.append("T OPNA2 TMRB_%02X trials=8 start_pit=%d/%d/%d reads=9/9/9" % (nb, v, v, v))
    o2 += ["X OPNA2 ADB_SETUP st0=00 s_rst=08 sb=08 st1=00 stl=00 reads=1 pit=5 s_set=08"]
    o2 += ["X OPNA2 ADB_W i=%d reads=3 pit=9 st=%s" % (i, "0C" if i >= 32 else "08") for i in range(40)]
    o2 += ["X OPNA2 ADB_END st=0C s6=00",
           "X OPNA2 FR_ADB i=0 sb=0C st1=00 stl=00 reads=1 pit=5"]
    o2c = parse(synth([("CAL", CAL_OK), ("OPNA2", o2)]), "OPNA2.TXT")
    txt, oexp = opna2(o2c)
    joined = "\n".join(txt)
    check("OPNA2: grammar clean", o2c.flags == [])
    check("OPNA2: 0x188 is a YM2608 with the 0xA460 gate",
          any(t.startswith("base 0188: YM2608") and "86-board extension gate" in t for t in txt))
    check("OPNA2: 0x288 absent, 0x088 YM2203-like",
          any(t.startswith("base 0288: absent") for t in txt) and
          any(t.startswith("base 0088: YM2203") and "never answer" in t for t in txt))
    check("OPNA2: ADPCM-B present, EOS first at byte 32",
          "BRDY after 40 of 40" in joined and "ADB_W i=32" in joined)
    check("OPNA2: BUSY_FM30 first poll clear 96.9%",
          ("OPNA2.BUSY_FM30.first_clear_pct", "96.9") in [e[:2] for e in oexp])
    check("OPNA2: B2B SSG 7/8; B2B timer: a BUSY-delayed start still 'both landed' (6), "
          "one 0x25 lost, one 0x24 lost; an unflagged trial is 'no flag'",
          "both writes landed in 7/8" in joined and
          "B2B_TMR: both landed 6, 0x25 lost 1, 0x24 lost 1" in joined and
          "B2B_TMR3: no flag (start lost) 1" in joined)
    check("OPNA2: FR_TMRA 32/32 at the first read, IRQ12 still up in 4/32",
          "FR_TMRA: flag clear at the first read in 32/32" in joined and "after 4/32" in joined)
    check("OPNA2: FR_TMRB 0/32 at the first read", "FR_TMRB: flag clear at the first read in 0/32" in joined)
    pa = dict((e[0], float(e[1])) for e in oexp if e[0].endswith(("period_us", "start_us")))
    check("OPNA2: timer A fit 18.03 us/count, start 5 us",
          abs(pa.get("OPNA2.TMRA.period_us", 0) - 18.029) < 0.05 and
          abs(pa.get("OPNA2.TMRA.start_us", 0) - 5) < 0.5)
    check("OPNA2: timer B fit 288.5 us/count", abs(pa.get("OPNA2.TMRB.period_us", 0) - 288.46) < 0.5)
    oe = expect_lines(o2c)
    check("OPNA2: expect lines carry the identity and the latencies",
          any(l.startswith("OPNA2.BASE0188.id 01 hex") for l in oe) and
          any(l.startswith("OPNA2.FR_TMRA.irq_drop_us ") for l in oe) and
          any(l.startswith("OPNA2.BUSY_FM30.busy_pit_med 13 ") for l in oe))
    # /OPNA3: BUSY_RHY18, MDRV2's six level writes back to back (the 0x18 write busy for 72
    # PIT counts in trials 0-7, every other write clear at the first poll, writes 40 counts
    # apart), the key pairs never busy, and the three /LISTEN phase rows.
    o3 = ["STATE OPNA3 a460=40 st=00 listen=1 vec60=00603673"]
    o3 += ["X OPNA3 BUSY_RHY18 i=%d dly=%d polls=1 pit=12" % (i, i * 37 & 127) for i in range(32)]
    o3 += ["X OPNA3 BUSY_RHY18 i=H polls_h=96,0,0,0,0,0,32,0,0 pit_h=0,96,0,0,0,0,0,0,32,0,0,0,0,0,0,0",
           "T OPNA3 BUSY_RHY18 trials=128 busy_pit=10/12/73 polls=1/1/29"]
    lv = ("18", "19", "1A", "1B", "1C", "1D")
    for i in range(32):
        b = i < 8
        o3.append("X OPNA3 B2B_RHYLVL i=%d dly=%d polls=%d,1,1,1,1,1 pit=%d,12,12,12,12,12 "
                  "dd=0,40,40,40,40,40" % (i, i * 37 & 127, 29 if b else 1, 72 if b else 12))
    for w_ in range(6):
        o3.append("X OPNA3 B2B_RHYLVL i=H w=%d reg=%s polls_h=%s pit_h=x" % (
            w_, lv[w_], "24,0,0,0,0,0,8,0,0" if w_ == 0 else "32,0,0,0,0,0,0,0,0"))
    o3 += ["X OPNA3 B2B_RHYLVL i=H w=all polls_h=184,0,0,0,0,0,8,0,0 pit_h=x",
           "T OPNA3 B2B_RHYLVL trials=32 writes=192 busy_pit=12/12/72 polls=1/1/29"]
    o3 += ["X OPNA3 B2B_RHYKEY i=%d dly=%d polls=1,1,1,1,1,1 pit=12,12,12,12,12,12 "
           "dd=0,40,40,40,40,40" % (i, i * 37 & 127) for i in range(32)]
    o3 += ["T OPNA3 B2B_RHYKEY trials=32 writes=192 busy_pit=12/12/12 polls=1/1/1"]
    o3 += ["X OPNA3 LISTEN_SLOW regs=18,19,1A,1B,1C,1D slow=1 polls=1,1,1,1,1,1 pit=12,12,12,12,12,12 "
           "dd=0,600,600,600,600,600 keys=8",
           "X OPNA3 LISTEN_B2B regs=18,19,1A,1B,1C,1D slow=0 polls=29,1,1,1,1,1 pit=72,12,12,12,12,12 "
           "dd=0,90,40,40,40,40 pre_polls=1,1,1,1,1,1 keys=8",
           "X OPNA3 LISTEN_B2B_REV regs=1D,1C,1B,1A,19,18 slow=0 polls=1,1,1,1,1,1 pit=12,12,12,12,12,12 "
           "dd=0,40,40,40,40,40 pre_polls=1,1,1,1,1,1 keys=8",
           "RESTORE OPNA3 PA460 was=40 now=40 kind=readback OK",
           "RESTORE OPNA3 OPNA3_REGS was=- now=- kind=default OK"]
    o3c = parse(synth([("CAL", CAL_OK), ("OPNA3", o3)], args="/OPNA3"), "OPNA3.TXT")
    t3, e3 = opna3(o3c)
    j3 = "\n".join(t3)
    e3d = dict((e[0], e[1]) for e in e3)
    check("OPNA3: grammar clean", o3c.flags == [])
    check("OPNA3: BUSY_RHY18 first poll clear 75.0%",
          e3d.get("OPNA3.BUSY_RHY18.first_clear_pct") == "75.0")
    check("OPNA3: B2B levels busy 8/192, all at 0x18",
          e3d.get("OPNA3.B2B_RHYLVL.busy_writes") == "8/192" and "18 busy 8/32" in j3 and
          "19 busy 0/32" in j3)
    check("OPNA3: B2B busy max 29.30 us, spacing 16.28 us",
          e3d.get("OPNA3.B2B_RHYLVL.busy_max_us") == "29.30" and
          e3d.get("OPNA3.B2B_RHYLVL.spacing_us") == "16.28")
    check("OPNA3: B2B keys never busy", e3d.get("OPNA3.B2B_RHYKEY.busy_writes") == "0/192")
    check("OPNA3: LISTEN phases reported with the ear guide",
          "LISTEN_B2B: regs 18,19,1A,1B,1C,1D, back to back, polls 29,1,1,1,1,1 (busy 1/6" in j3
          and "LISTEN_SLOW: regs 18,19,1A,1B,1C,1D, 200 us apart" in j3 and
          "one pending level word" in j3)
    l3 = expect_lines(o3c)
    check("OPNA3: expect lines carry the B2B counts and the T medians",
          any(l.startswith("OPNA3.B2B_RHYLVL.busy_writes 8/192 writes") for l in l3) and
          any(l.startswith("OPNA3.B2B_RHYLVL.busy_pit_med 12 ") for l in l3))
    # /OPNA3 /SWEEP: steps 1-3 of the plan, the first BUSY-lengthened (fit=2), the third
    # short of its target (fit=0); 1 PIT count = 0.4069 us at the nominal ratio.
    sw = ["STATE OPNA3 a460=40 st=00 listen=0 sweep=1 vec60=00603673",
          "I OPNA3 SWEEP_PLAN ratio_x1000=8000 from=1 to=3 gaps_us=0,4,6",
          "ROW OPNA3 SWEEP port=0188",
          "X OPNA3 SWEEP step=1 gap_us=0 tgt=0 pit=72 n5f=0 tries=4 busy_tries=4 fit=2 p18=1 "
          "p19=28 pa=1 pa_pit=10 keys=4",
          "ROW OPNA3 SWEEP port=0188",
          "X OPNA3 SWEEP step=2 gap_us=4 tgt=10 pit=15 n5f=0 tries=1 busy_tries=0 fit=1 p18=1 "
          "p19=1 pa=18 pa_pit=46 keys=4",
          "ROW OPNA3 SWEEP port=0188",
          "X OPNA3 SWEEP step=3 gap_us=6 tgt=15 pit=14 n5f=2 tries=32 busy_tries=0 fit=0 p18=1 "
          "p19=1 pa=1 pa_pit=10 keys=4",
          "RESTORE OPNA3 PA460 was=40 now=40 kind=readback OK",
          "RESTORE OPNA3 OPNA3_REGS was=- now=00 kind=default OK"]
    swc = parse(synth([("CAL", CAL_OK), ("OPNA3", sw)], args="/OPNA3 /SWEEP"), "SWEEP.TXT")
    ts, es = opna3(swc)
    js = "\n".join(ts)
    esd = dict((e[0], e[1]) for e in es)
    check("OPNA3 SWEEP: grammar clean", swc.flags == [])
    check("OPNA3 SWEEP: header with the plan",
          "SWEEP: 3 steps (plan from=1 to=3, ratio_x1000=8000)" in js)
    check("OPNA3 SWEEP: the per-step table (MIN, us, BUSY note)",
          "     1       MIN     29.30   72    0" in js and "BUSY lengthened the gap" in js and
          "     2         4      6.10   15   10" in js and "18.72" in js)
    check("OPNA3 SWEEP: a step short of its target is named",
          "no fit: the last attempt stands  SHORT of the target" in js and
          "steps short of their target: 3" in js)
    check("OPNA3 SWEEP: an expect line per step",
          esd.get("OPNA3.SWEEP.step02.gap_us") == "6.10" and
          esd.get("OPNA3.SWEEP.step03.gap_us") == "5.70")
    check("OPNA3 SWEEP: the ear guide", "first step whose 4 hits were LOUD" in js)
    check("OPNA3 SWEEP: a capture without sd5f= is named pre-fix",
          "select-to-data: PRE-FIX binary (no sd5f=)" in js)
    sw1 = [sw[0].replace("sweep=1", "sweep=1 sd5f=1")] + sw[1:]
    sw1c = parse(synth([("CAL", CAL_OK), ("OPNA3", sw1)], args="/OPNA3 /SWEEP"), "SWEEP1.TXT")
    js1 = "\n".join(opna3(sw1c)[0])
    check("OPNA3 SWEEP: sd5f=1 decodes, the rows as before",
          sw1c.flags == [] and "select-to-data: 1 `out 5Fh`" in js1 and "PRE-FIX" not in js1 and
          "     2         4      6.10   15   10" in js1)
    # /AUDIT: synthetic records (a word read that splits, one that terminates as NP2kai's
    # table, a PIT latch consumed by `in ax,70h`, a DMA flip-flop toggled, an unmasked IRQ0
    # request withdrawn at every OUT0 fall, the slow handler losing it, a calendar that
    # raises one request per tick, the master IR7 withdrawn after the slave mask)
    au = ["STATE AUDIT imr_m=7D imr_s=75 pit_order=0 magic=A55AC33C",
          "ROW AUDIT B1480 port=1480", "X AUDIT B1480 v=FF v2=FF",
          "X AUDIT W0060 b0=04 b1=FF w1=0004 w2=0004 d=FFFFFF04 b2=04",
          "X AUDIT W0188 b0=00 b1=01 w1=0100 w2=0100 d=FFFF0100 b2=00",
          "X AUDIT W00D0 b0=FF b1=FF w1=C3FF w2=C3FF d=- b2=FF",
          "X AUDIT P0070 a0=E0 a1=80 w=D800 x1=80 x2=D0 v1=80EE sync=0",
          "X AUDIT P0071 a0=E0 a1=80 w=FFD8 x1=80 x2=D0 v1=80EE sync=0",
          "X AUDIT P0070 a0=E0 a1=80 w=0500 x1=D8 x2=80 v1=80EE sync=0",
          "X AUDIT D0000 q=09 r0=3C r1=C3 w=7D00 x1=C3 x2=3C was=0000",
          "X AUDIT D0001 q=09 r0=3C r1=C3 w=2588 x1=3C x2=C3 was=0000",
          "X AUDIT IRQ0WD_M first=1 samples=40960 ones=20480 rises=30 falls=30 cnt=8192",
          "X AUDIT IRQ0WD_U first=0 samples=40960 ones=20000 rises=30 falls=30 cnt=8192",
          "X AUDIT IRQ0OUT status=B6 samples=20480 ones=10240 rises=30 falls=30 v1=1000 sync=0",
          "X AUDIT IRQ0SLOW dly=0 n=150 n0f=0 win=153600 cnt=8192",
          "X AUDIT IRQ0SLOW dly=1638 n=75 n0f=0 win=153600 cnt=8192",
          "X AUDIT CALBDA d=8 art=76800 imr_s=75 imr_m=7D",
          "X AUDIT CAL128 v=81",
          "X AUDIT CAL cfg=AF mode=R n=16 win=153600 v=81 isr_s=80",
          "X AUDIT CAL cfg=AF mode=N n=16 win=153600 v=81 isr_s=80",
          "X AUDIT CAL cfg=81 mode=R n=16 win=153600 v=81 isr_s=80",
          "X AUDIT CAL cfg=81 mode=N n=1 win=153600 v=81 isr_s=80",
          "X AUDIT CAL cfg=82 mode=R n=0 win=153600 v=82 isr_s=00",
          "X AUDIT CAL cfg=82 mode=N n=0 win=153600 v=82 isr_s=00",
          "X AUDIT CASC_CTL s_irr=10 m_on=80 m_off=00 m_off2=00 s_irr1=00 n14=1 n17=0 n0f=0 "
          "isr_s=00 isr_m=00",
          "X AUDIT CASC s_irr=10 m_on=80 m_off=00 m_off2=00 s_irr1=10 n14=0 n17=0 n0f=0 "
          "isr_s=00 isr_m=00",
          "X AUDIT CASC_DEV s_irr=10 m_on=80 m_off=80 m_off2=80 s_irr1=10 n14=0 n17=1 n0f=0 "
          "isr_s=00 isr_m=80",
          "RESTORE AUDIT IMR_M was=7D now=7D kind=readback OK"]
    ac = parse(synth([("CAL", CAL_OK), ("AUDIT", au)]), "AUDIT.TXT")
    atxt, aexp = audit(ac)
    ajoin = "\n".join(atxt)
    ae = dict((e[0], str(e[1])) for e in aexp)
    check("AUDIT: grammar clean", ac.flags == [])
    check("AUDIT: 0x60 word read is AH=00 as NP2kai, 0x188 splits",
          ae.get("AUDIT.W0060.class") == "AH=00" and ae.get("AUDIT.W0188.class") == "split")
    check("AUDIT: 0xD0 keeps the old AH", ae.get("AUDIT.W00D0.class") == "AH=old")
    check("AUDIT: FF FF bytes and FFFF cannot tell split from AH=FF",
          au_wclass(0xFF, 0xFF, 0xFFFF) == ["split", "AH=FF"])
    check("AUDIT: in ax,71h consumed the latch's first byte; a second in ax,70h row left it",
          ae.get("AUDIT.P0071.latch") == "consumed" and "P0070 in ax=D800 with ch0 latched: "
          "the latch was consumed" in ajoin and "the latch was untouched" in ajoin)
    check("AUDIT: calendar 82 with no tick in either mode is stopped",
          ae.get("AUDIT.CAL.82.verdict") == "stopped")
    check("AUDIT: DMA flip-flop toggled by in ax,00h, untouched by in ax,01h",
          ae.get("AUDIT.D0000.ff") == "toggled" and ae.get("AUDIT.D0001.ff") == "untouched")
    check("AUDIT: IRQ0 withdrawn unmasked", ae.get("AUDIT.IRQ0WD_U.verdict") == "withdrawn")
    check("AUDIT: slow handler at 1.6 periods loses the request",
          ae.get("AUDIT.IRQ0SLOW.d1638.verdict") == "withdrawn" and
          "AUDIT.IRQ0SLOW.d0.verdict" not in ae)
    check("AUDIT: calendar as found one request per tick, at 81 held until read",
          "cfg=AF: 16 ticks reading 0x128, 16 not reading -> one-request-per-tick" in ajoin and
          "cfg=81: 16 ticks reading 0x128, 1 not reading -> held-until-0x128-read" in ajoin)
    check("AUDIT: master IR7 withdrawn by the slave mask, held after a device reset",
          ae.get("AUDIT.CASC.m_ir7") == "withdrawn" and ae.get("AUDIT.CASC_DEV.m_ir7") == "held")
    check("AUDIT: expect lines carry the raw bytes",
          any(l.startswith("AUDIT.B1480.v FF hex") for l in expect_lines(ac)))
    f2 = ["STATE FDC2 imr_s=75 bda055C=03 p00BE=FB",
          "X FDC2 UNIT da=91 cls=E st3=19 st3_spun=19 recal_st0=29 pcn=00",
          "X FDC2 TC_R3 da=90 r0=03 mt=00 eot=08 sectors=1 end=I irr_pre=10 t_irq_art=313 "
          "t_tc_art=312 dmacnt=FFFF nres=7 st0=00 st1=00 st2=00 c=00 h=00 r=04 n=03",
          "X FDC2 NRRD da=91 end=I t_end_art=4 irr_pre=10 msr0=12 msr_end=82 msr=82:1:2 "
          "sis=4900,80 dmacnt=03FF nres=0 st0=FF st1=FF st2=FF c=FF h=FF r=FF n=FF",
          "X FDC2 RST_M da=90 w=98/18 irr_pre=10 t_irq_art=316 rises=1 t_irq2_art=- sis=C000,80 "
          "sis2=- irr_end=10 msr=80:65535:2",
          "X FDC2 M640 da=90 motor=01 st3=38 msr_end=80 cc=74:1,64:316"]
    fc = parse(synth([("CAL", CAL_OK), ("FDC2", f2)]), "FDC2.TXT")
    ftxt, fexp = fdc2(fc)
    fj = "\n".join(ftxt)
    fe = dict((e[0], str(e[1])) for e in fexp)
    check("FDC2: grammar clean", fc.flags == [])
    check("FDC2: TC before EOT, R+1 is the RTL's and the datasheet's, not NP2kai's",
          "r          04" in fj and "NP2kai 01 (R forced to 1) x | RTL 04 = | datasheet 04 =" in fj)
    check("FDC2: the empty unit's READ DATA deferred to SENSE INTERRUPT STATUS (RTL)",
          fe.get("FDC2.NRRD.91.sis") == "4900,80" and "RTL 4900,80 =" in fj)
    check("FDC2: the reset poll at 1.029 ms", "t_irq = 1.029 ms" in fj and
          "datasheet C000,C100,C200,C300,80 x" in fj)
    check("FDC2: the 640K RDY window", "0xCC bit 4 window = 1.029 ms" in fj and
          fe.get("FDC2.M640.90.m01.cc") == "74:1,64:316")
    o4 = ["STATE OPNA4 imr_s=75 st188=00", "ROW OPNA4 BA_000",
          "X OPNA4 BA_000 i=0 reads=30 pit=75 bpit=0",
          "T OPNA4 BA_000 trials=8 start_pit=70/76/80 reads=28/30/33 burst_pit=0/0/0",
          "T OPNA4 BA_064 trials=8 start_pit=72/90/140 reads=28/40/60 burst_pit=4000/4100/4200",
          "T OPNA4 BB_000 trials=8 start_pit=101/105/700 reads=42/44/300 burst_pit=0/0/0",
          "X OPNA4 RMAP_C r00=" + "00" * 14 + "FFFF", "X OPNA4 RMAP_C r20=" + "2021FF232425262728FF2A2B2C2D2E2F",
          "X OPNA4 RD29_O v29=1F pre=FF post=FF",
          "X OPNA4 S3A_A0 seen=1 st188=01 st18C=01", "X OPNA4 S3A_B0 seen=1 st188=00 st18C=00",
          "RESTORE OPNA4 IMR_S was=75 now=75 kind=readback OK"]
    a2 = ["STATE AUDIT2 imr_m=7D imr_s=75 p128=91 pit_order=0",
          "X AUDIT2 CALIRR cfg=81 mode=N first=1 samples=90000 ones=89900 rises=0 falls=0 r128=EE e=",
          "X AUDIT2 CALIRR cfg=81 mode=R first=0 samples=90000 ones=300 rises=3 falls=3 r128=81 "
          "e=+1000,-1002,+10600,-10602,+20200,-20202",
          "X AUDIT2 CALIRR cfg=80 mode=N first=0 samples=90000 ones=45000 rises=6 falls=6 r128=EE "
          "e=+100,-2500,+4900,-7300",
          "X AUDIT2 CALIRR cfg=80 mode=R first=0 samples=90000 ones=45000 rises=6 falls=6 r128=90 "
          "e=+100,-2500,+4900,-7300",
          "X AUDIT2 WO0009 ax=FF5A r=C33C i0=75 i1=75 x1=3C x2=C3",
          "X AUDIT2 WO000A ax=5AFF r=C33C i0=75 i1=FF x1=5A x2=C3",
          "X AUDIT2 WO006C b0=00 b1=FF ax=FF70 a0=70 a1=FF",
          "X AUDIT2 W0072 b0=FF b1=FF w1=00FF w2=00FF d=- b2=FF",
          "X AUDIT2 T007C n=1024 b=2400 w=4850",
          "X AUDIT2 T0060 n=1024 b=2400 w=2410", "X AUDIT2 T000A n=1024 b=2400 w=4800"]
    oc = parse(synth([("CAL", CAL_OK), ("OPNA4", o4), ("AUDIT2", a2)]), "XE10U.TXT")
    otxt, oexp = opna4(oc)
    oe = dict((e[0], str(e[1])) for e in oexp)
    a2txt, a2exp = audit2(oc)
    a2e = dict((e[0], str(e[1])) for e in a2exp)
    check("OPNA4/AUDIT2: grammar clean", oc.flags == [])
    check("OPNA4: the control within the machine's idle bound, the burst row above it",
          oe.get("OPNA4.BA_000.bound") == "within" and oe.get("OPNA4.BA_064.bound") == "partly-above"
          and oe.get("OPNA4.BB_000.bound") == "within")
    check("OPNA4: the read map classes and RD29/S3A rows",
          oe.get("OPNA4.RMAP_C.r29") == "FF" and oe.get("OPNA4.RMAP_C.r22") == "FF" and
          any(t.startswith("RMAP_C (extension closed): 00: 00-0D; FF: 0E-0F 22 29; sel: 20-21 23-28 2A-2F")
              for t in otxt) and oe.get("OPNA4.RD29_O.1F.post") == "FF" and oe.get("OPNA4.S3A_B0.st18C") == "00")
    check("OPNA4: burst us per write", abs(float(oe.get("OPNA4.BA_064.us_per_write", "0")) - 26.1) < 0.2)
    check("AUDIT2: a line held until 0x128 is read",
          a2e.get("AUDIT2.CALIRR.81.verdict") == "held-until-read")
    check("AUDIT2: a line that falls by itself", a2e.get("AUDIT2.CALIRR.80.verdict") == "falls-by-itself")
    check("AUDIT2: word OUT 09 dropped (NP2kai), 0A split",
          a2e.get("AUDIT2.WO0009.shape") == "dropped" and a2e.get("AUDIT2.WO000A.shape") == "split")
    check("AUDIT2: 0x6C took the low byte", a2e.get("AUDIT2.WO006C.low") == "low-landed")
    check("AUDIT2: in ax,7Ch two cycles, in ax,60h one",
          a2e.get("AUDIT2.T007C.cycles") == "two-cycles" and a2e.get("AUDIT2.T0060.cycles") == "one-cycle")
    check("AUDIT2: 0x72 word read AH=00 is NP2kai's minus_term", a2e.get("AUDIT2.W0072.class") == "AH=00")
    # /MISAL (XE10V): the misaligned-word ratios, the odd-DI string row against the W1/W3
    # mean, Rusty's row per word, and a vertical-blank window that outlasts the blank
    ms = ["STATE MISAL as_found bda054C=4F bda054D=50 p31=FF adelay=614",
          "P MISAL RASTER_G frames=8 art=43560 hi=792 to=0"]
    for tag, ns in (("RMW_W0_O", 256.0), ("RMW_W1_O", 384.0), ("RMW_W2_O", 256.0),
                    ("RMW_W3_O", 512.0), ("RMW_SW1_O", 450.0), ("RMW_BL0_O", 20 * 260.0),
                    ("RMW_BL1_O", 20 * 390.0), ("RMW_W0_A", 300.0)):
        ms.append(rrow("MISAL", tag, 50 if "BL" in tag else 1024, 0, ns, 20.0))
    ms.append(rrow("MISAL", "RMW_W3_V", 4096, 0, 512.0, 20.0))   # 644 ticks > 33 lines
    ms.append("I MISAL sync_to=0")
    mc = parse(synth([("CAL", CAL_OK), ("MISAL", ms)]), "XE10V.TXT")
    mtxt, mexp = misal(mc)
    me = dict((e[0], str(e[1])) for e in mexp)
    def near_(k, want, tol):
        try:
            return abs(float(me.get(k, "nan")) - want) <= tol
        except ValueError:
            return False
    # rrow quantizes each window to whole ARTIC ticks: 1024 stores give 3.2 ns per tick
    check("MISAL: W1/W0 and W3/W0 in periods", near_("MISAL.RMW.O.w1_over_w0", 1.5, 0.02) and
          near_("MISAL.RMW.O.w3_over_w0", 2.0, 0.02))
    check("MISAL: the odd-DI string row against the W1/W3 mean",
          any(t.startswith("RMW O: SW1 ") and "against the W1/W3 mean 44" in t for t in mtxt))
    check("MISAL: Rusty's row per word", near_("MISAL.RMW.O.bl1_ns_per_word", 390.0, 4.0) and
          near_("MISAL.RMW.O.bl0_ns_per_word", 260.0, 4.0))
    check("MISAL: the raster row (5445 ticks/frame, 8 VSYNC lines)",
          me.get("MISAL.RASTER_G.frame_ticks") == "5445.0" and me.get("MISAL.RASTER_G.vsync_lines") == "8.00")
    check("MISAL: a _V window past the blank is flagged, the others are not",
          [f[1] for f in mc.flags] == ["PAST-BLANK"])
    # /MISAL2 (XE10W): the per-family ratio to the base offset, the I/O base (K = 4)
    m2 = []
    for tag, n, ns in (("RLWH_0", 4096, 10.0), ("RLWH_1", 4096, 20.0), ("GRW_0_A", 512, 500.0),
                       ("GRW_3_A", 512, 1000.0), ("IOOW_4", 1024, 800.0), ("IOOW_3", 1024, 1600.0)):
        m2.append(rrow("MISAL2", tag, n, 0, ns, 5.0))
    c2 = parse(synth([("CAL", CAL_OK), ("MISAL2", m2)]), "XE10W.TXT")
    t2, e2 = misal2(c2)
    d2 = dict((e[0], float(e[1])) for e in e2)
    check("MISAL2: ratios to the base offset (RAM, GVRAM by phase, word OUT base K=4)",
          abs(d2.get("MISAL2.RLWH.-.k1_over_k0", 0) - 2.0) < 0.35 and
          abs(d2.get("MISAL2.GRW.A.k3_over_k0", 0) - 2.0) < 0.05 and
          abs(d2.get("MISAL2.IOOW.-.k3_over_k4", 0) - 2.0) < 0.05 and c2.flags == [])
    # /RDLAT (XE10X): a latency-shaped read (the work adds), a rate-shaped one (the work hides
    # until the knee), a raster row per mode, a mode whose frame is not the mode's, and a _V
    # window that outlasts the 31 kHz blank
    rl = ["P RDLAT RASTER_24 frames=8 art=43560 hi=792 to=0",
          "P RDLAT RASTER_31 frames=8 art=35078 hi=160 to=0",
          "P RDLAT RASTER_48 frames=8 art=43560 hi=160 to=0"]
    for k in (0, 2, 4, 8, 16, 32, 64):
        c = 20.0 + 10.0 * k
        rl.append(rrow("RDLAT", "GRW_24A", 512, k, c + 700.0, c))
        rl.append(rrow("RDLAT", "GRW_24V", 512, k, c + 650.0, c))
        rl.append(rrow("RDLAT", "GW_31A", 512, k, max(650.0, c + 40.0), c))
    rl.append(rrow("RDLAT", "XCR_31V", 512, 0, 2500.0, 20.0))
    rl.append(rrow("RDLAT", "XCR_31V", 512, 2, 2520.0, 40.0))
    rl.append("I RDLAT sync_to=0")
    rc = parse(synth([("CAL", CAL_OK), ("RDLAT", rl)]), "XE10X.TXT")
    rtxt, rexp = rdlat(rc)
    re_ = dict((e[0], str(e[1])) for e in rexp)
    check("RDLAT: the work adds to a latency read (hidden ~0)",
          re_.get("RDLAT.GRW.24A.shape") == "LATENCY" and abs(float(re_.get("RDLAT.GRW.24A.hidden_ns", "99"))) < 8)
    check("RDLAT: the work hides in a rate access up to its period",
          re_.get("RDLAT.GW.31A.shape") == "RATE" and abs(float(re_.get("RDLAT.GW.31A.hidden_ns", "0")) - 590) < 10)
    check("RDLAT: the raster penalty A over V", abs(float(re_.get("RDLAT.GRW.24.a_over_v", "0")) - 720 / 670) < 0.02)
    check("RDLAT: a mode not set and a window past the 31 kHz blank are flagged",
          sorted(set(f[1] for f in rc.flags) - {"PLATEAU-NOT-FLAT", "KNEE-NOT-FOUND", "NO-PLATEAU"}) ==
          ["MODE-NOT-SET", "PAST-BLANK"] and any("RASTER_48" in f[2] for f in rc.flags if f[1] == "MODE-NOT-SET"))
    # XE10Y (kit 3): /REP passes, the /PKAB verdict, /CELLS shapes, /K3M rows
    pk = []
    for rd in (1, 2, 3):
        pk += [rrow("PKAB", "PKW_0_M%d" % rd, 512, 0, 145.0, 13.0, shell="BDFC"),
               rrow("PKAB", "PKW_R%d" % rd, 512, 0, 183.0, 13.0, shell="BDFC"),
               rrow("PKAB", "PKW1ST_FA%d" % rd, 512, 0, 145.0, 13.0, shell="BDFC"),
               rrow("PKAB", "PKWAFT_FA%d" % rd, 512, 0, 183.0, 13.0, shell="BDFC"),
               rrow("PKAB", "PKWLATE_FA%d" % rd, 512, 0, 183.0, 13.0, shell="BDFC"),
               rrow("PKAB", "PKW_C%d" % rd, 512, 0, 183.0, 13.0, shell="BDFC"),
               rrow("PKAB", "PKW_N%d" % rd, 512, 0, 183.0, 13.0, shell="BDFC"),
               rrow("PKAB", "PKW_D%d" % rd, 512, 0, 183.0, 13.0, shell="BDFC"),
               rrow("PKAB", "RLWH_C%d" % rd, 4096, 0, 10.0, 5.0),
               rrow("PKAB", "RLWH_N%d" % rd, 4096, 0, 60.0, 5.0),
               rrow("PKAB", "GRW_C%d" % rd, 512, 0, 700.0, 13.0),
               rrow("PKAB", "GRS_C%d" % rd, 512, 0, 690.0, 13.0)]
    pk.append("STATE PKAB row=PKW_0_M1 q04=01 q0A=01 since_pegc=467 dst=A800:00000000 al4=0")
    pk.append("STATE PKAB row=PKW_R1 q04=01 q0A=01 since_pegc=267140 dst=A800:00000000 al4=0")
    pc = parse(synth([("CAL", CAL_OK), ("PKAB", pk)]), "PKAB.TXT")
    vt = [t for t in pkab(pc)[0] if t.startswith("VERDICT")]
    check("PKAB: the sequence and the time since the 256-colour mode are named",
          any(t.startswith("VERDICT SEQUENCE") for t in vt) and
          any(t.startswith("VERDICT TIME SINCE") for t in vt) and
          any("not the L1 cache" in t for t in vt) and any("TOOK EFFECT" in t for t in vt) and
          any("NOT CACHED" in t for t in vt))
    rp = [rrow("RDLAT", "GRW_24A", 512, 0, 700.0, 20.0)]
    rp2 = [rrow("RDLAT", "GRW_24A", 512, 0, 760.0, 20.0)]
    rc2 = parse(synth([("CAL", CAL_OK), ("RDLAT", rp), ("RDLAT", rp2)], args="/RDLAT /REP 2"), "REP.TXT")
    st, se = rep_spread(rc2)
    check("REP: the first pass is analysed, the spread flagged across passes",
          len([r for r in rc2.rows if r["kind"] == "R"]) == 1 and "REP-SPREAD" in codes(rc2) and
          abs(float(dict((e[0], e[1]) for e in se)["REP.RDLAT.GRW_24A.k0.spread"]) - 60 / 730) < 0.01)
    cl = [rrow("CELLS", "TCRWM_31A", 512, k, 1000.0 + 10.0 * k, 20.0 + 10.0 * k) for k in (0, 2, 4, 8, 16, 32, 64)]
    cl.append("X CELLS APER 43b=FB 43b_now=FF a20_masked=1 e0102_was=00 a8_wr=1357 f0_rb=1357 f0_wr=2468 a8_rb=2468")
    cc = parse(synth([("CAL", CAL_OK), ("CELLS", cl)]), "CELLS.TXT")
    ce = dict((e[0], e[1]) for e in cells(cc)[1])
    check("CELLS: a two-word 31 kHz read is LATENCY, the aperture proof read",
          ce.get("CELLS.TCRWM.31A.shape") == "LATENCY" and ce.get("CELLS.aperture_maps") == "yes")
    hb = "X K3M HBL port=0060 polls=2048 art=503 runs=" + "".join("1%d,3%d," % (38, 12) for _ in range(40))
    km = ["X K3M IDIV ax_in=B0F8 bl=1E de=0 ax=F880 flags=0046",
          "X K3M PIT case=C0056 st0=30 irr0=0 out_art=11 irr_art=11",
          "X K3M PIT case=C1256 st0=30 irr0=0 out_art=588 irr_art=588",
          "X K3M PIT case=L1234_56 st0=10 irr0=0 out_art=587 irr_art=588", hb]
    kc = parse(synth([("CAL", CAL_OK), ("K3M", km)]), "K3M.TXT")
    ke = dict((e[0], e[1]) for e in k3m(kc)[1])
    check("K3M: IDIV AX, the LSB-only write kept, the blank fraction",
          ke.get("K3M.IDIV.ax") == "F880" and ke.get("K3M.PIT.L1234_56") == "KEEPS" and
          abs(float(ke.get("K3M.HBL.0060.high_frac", "0")) - 0.24) < 0.01)
    # --emit-expect carries every analyser's tuples (PKAB, CELLS, K3M and the /REP spread were
    # computed and dropped), from the one SECTION_ANALYSERS list report() also prints from
    def expect_has(c, prefix):
        return any(l.startswith(prefix) for l in expect_lines(c))
    check("expect: PKAB, CELLS, K3M and REP rows reach the .expect file",
          expect_has(pc, "PKAB.") and expect_has(cc, "CELLS.TCRWM.31A.shape LATENCY ") and
          expect_has(kc, "K3M.IDIV.ax F880 ") and expect_has(rc2, "REP.RDLAT.GRW_24A.k0.spread "))
    check("every report() section analyser is in SECTION_ANALYSERS",
          {n for n, _ in SECTION_ANALYSERS} == {"OPNA2", "OPNA3", "AUDIT", "FDC2", "OPNA4", "AUDIT2",
                                                "MISAL", "MISAL2", "RDLAT", "PKAB", "CELLS", "K3M"})
    # an analyser runs once per capture: report() then expect_lines() must not flag twice
    import io as _io
    report(mc, _io.StringIO())
    expect_lines(mc)
    check("MISAL: report + expect_lines flag PAST-BLANK once", [f[1] for f in mc.flags] == ["PAST-BLANK"])
    # a malformed row costs its section, not the report
    bad = parse(synth([("CAL", CAL_OK), ("K3M", ["X K3M HBL port=0060 polls=2048 art=503 runs=1x,"]),
                       ("CELLS", cl)]), "BAD.TXT")
    buf = _io.StringIO()
    report(bad, buf)
    check("a malformed K3M row: GRAMMAR on that section, CELLS still decoded",
          any(f[1] == "GRAMMAR" and "k3m analyser" in f[2] for f in bad.flags) and
          "CELLS TCRWM" in buf.getvalue() and expect_has(bad, "CELLS.TCRWM.31A.shape"))
    b8 = parse(synth([("CAL", CAL_OK), ("CELLS", ["X CELLS B8 on_rb=A55A off_rb2=FFFF"])]), "B8.TXT")
    check("CELLS B8: a row without on_rb2 is incomplete, not 'no plane store lands'",
          any("row incomplete" in t for t in cells(b8)[0]) and
          not any("no plane store lands" in t for t in cells(b8)[0]))
    # two captures: an integrity flag on either side is exit 1; one-capture options refused
    import os as _os
    import tempfile as _tf
    good = synth([("CAL", CAL_OK), ("CELLS", cl)])
    torn = synth([("CAL", CAL_OK), ("CELLS", cl)], done=False)
    with _tf.TemporaryDirectory() as td:
        pa, pb = _os.path.join(td, "A.TXT"), _os.path.join(td, "B.TXT")
        open(pa, "wb").write(good)
        open(pb, "wb").write(torn)
        import contextlib as _cl
        with _cl.redirect_stdout(_io.StringIO()):
            r_same = main([pa, pa])
            r_torn = main([pa, pb])
            r_opt = main([pa, pa, "--emit-expect", _os.path.join(td, "x.expect")])
    check("two captures: clean 0, a torn one 1, --emit-expect refused 2",
          (r_same, r_torn, r_opt) == (0, 1, 2))
    # O4_BOUNDS are copied from a capture: they must still be its T rows' min and max
    import pathlib as _pl
    src_path = _pl.Path(__file__).resolve().parents[3] / O4_BOUNDS_SRC[0]
    got = {}
    if src_path.exists():
        for k, tag in O4_BOUNDS_SRC[1].items():
            m = re.search(r"^T OPNA2 %s trials=\d+ start_pit=(\d+)/\d+/(\d+)" % tag,
                          src_path.read_text(errors="replace"), re.M)
            if m:
                got[k] = (int(m.group(1)), int(m.group(2)))
    check("O4_BOUNDS match %s's start_pit min/max" % O4_BOUNDS_SRC[0], got == O4_BOUNDS)
    print("SELFTEST %s" % ("PASS" if not fails else "FAIL (%d)" % len(fails)))
    return 0 if not fails else 1


# ----------------------------------------------------------------------------- main
def check_source(path):
    """The build's forward-.equ guard (R14): GAS assembles an Intel-syntax operand naming a
    symbol that is not yet defined as a MEMORY operand, so `add si, SIZE` before
    `.equ SIZE, 10` silently becomes `add si, [10]`. Expand the .include tree in assembly
    order and fail on any use of an .equ name before its definition."""
    import os
    lines = []

    def expand(p):
        base = os.path.dirname(p)
        for n, raw in enumerate(open(p, encoding="ascii", errors="replace"), 1):
            m = re.match(r'\s*\.include\s+"([^"]+)"', raw)
            if m:
                expand(os.path.join(base, m.group(1)))
            else:
                lines.append((p, n, raw))
    expand(path)
    defs = {}
    for i, (_, _, raw) in enumerate(lines):
        m = re.match(r"\s*\.equ\s+(\w+)\s*,", raw)
        if m and m.group(1) not in defs:
            defs[m.group(1)] = i
    bad = 0
    in_comment = False
    for i, (p, n, raw) in enumerate(lines):
        code = raw
        if in_comment:
            if "*/" not in code:
                continue
            code = code.split("*/", 1)[1]
            in_comment = False
        code = re.sub(r"/\*.*?\*/", " ", code)
        if "/*" in code:
            code, in_comment = code.split("/*", 1)[0], True
        code = re.sub(r'"[^"]*"', " ", code)
        for w in set(re.findall(r"\b[A-Za-z_]\w*\b", code)):
            if w in defs and defs[w] > i:
                print("%s:%d: %s used before its .equ (line %s)" % (p, n, w, lines[defs[w]][1]))
                bad += 1
    print("check-source %s: %d .equ names, %s" % (path, len(defs),
                                                 "OK" if not bad else "%d forward uses" % bad))
    return 1 if bad else 0


def main(argv):
    args, opts = [], {"band": 10.0}
    it = iter(argv)
    for a in it:
        if a == "--selftest":
            return selftest()
        if a == "--stamp":
            return do_stamp(next(it))
        if a == "--check-source":
            return check_source(next(it))
        if a in ("--emit-expect", "--binary", "--band"):
            opts[a[2:]] = next(it)
        elif a == "--force":
            opts["force"] = True
        elif a.startswith("-"):
            print(__doc__)
            return 2
        else:
            args.append(a)
    if not args or len(args) > 2:
        print(__doc__)
        return 2
    if len(args) == 2 and ("emit-expect" in opts or "binary" in opts):
        print("--emit-expect and --binary take ONE capture (two captures are compared)")
        return 2
    caps = [parse(open(p, "rb").read(), p) for p in args]
    if len(caps) == 2:
        for c in caps:
            for f in c.errors():
                print("%s: line %d %s %s" % (c.name, *f))
        rc = compare(caps[0], caps[1], float(opts["band"]), opts.get("force", False))
        # an integrity or trust flag on either side is exit 1, as for one capture
        return rc if rc else (1 if any(c.errors() for c in caps) else 0)
    cap = caps[0]
    if "binary" in opts:
        _, sha, crc = stamp_fields(open(opts["binary"], "rb").read())
        h = cap.header or {}
        ok = h.get("sha", "").lower() == sha and h.get("crc", "").upper() == crc
        print("binary %s sha=%s crc=%s: %s" % (opts["binary"], sha, crc,
                                               "MATCHES the capture" if ok else "DOES NOT MATCH"))
        if not ok:
            cap.flag(0, "IMAGE-CORRUPT", "capture sha/crc differ from %s" % opts["binary"])
    report(cap)
    if "emit-expect" in opts:
        lines = expect_lines(cap)
        with open(opts["emit-expect"], "w") as f:
            f.write("# derived from %s by xe10t_decode.py; name value unit source method\n" %
                    cap.name.rsplit("/", 1)[-1])
            f.write("".join(l + "\n" for l in lines))
        print("wrote %d expect lines to %s" % (len(lines), opts["emit-expect"]))
    return 1 if cap.errors() else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

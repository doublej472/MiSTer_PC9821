#!/usr/bin/env python3
"""mister_regress.py - the automated hardware regression run on a MiSTer.

WHY. The Policenauts intro stall was hard-disk corruption caused by CD-DA traffic on a shared
hps_io word bus. It was found through a game symptom after a day of tracing. This runner is the
repeatable form of that investigation: deploy a test RBF under test names, boot a COPY of the
user's disk, drive the guest by keyboard/mouse, watch the screen, read the integrity probe's
own output out of the disk copy, and delete everything it created.

THE SCRIPTED SET (--items, default all)
  probe        INTEG.COM (tools/hwprobe/integ): verify the HDD / floppy / CD files against manifests
               made on the host from the same images, plus the write/read-back, no CD-DA
  probe-cda    the same WHILE CD-DA plays (INTEG P ... INTEG S; needs --cd and MSCDEX in the guest)
  doom         DOOM's start       }  the game items run a command list from the scenarios file
  th05         Touhou 5's start   }  (--scenarios; tools/mister/regress_scenarios.example.json is the
  rusty        Rusty's start      }  shape), take a screenshot every N seconds and check
  policenauts  the Policenauts intro, to the logo
  flamezap     Flame Zapper Kotsujin's attract/play (EGC-heavy sprite blits; EMS profile)
  cpusuite     CPUSUITE.COM (tools/hwprobe/cpusuite): z486's own self-checking test programs, run from
               DOS on the core (a CPU-correctness stress test for clocks past timing closure); boots
               the CONFIG.SYS profile 0 (noemm: HIMEM, no EMM386) unless the scenarios file says
               otherwise. ~1.5 min including the boot (256 programs in under 30 s); --cpusuite-passes N
               loops the pack for a longer stress run
  crt31k       CRT31K.COM (tools/hwprobe/crt31k): times the 24 kHz raster, switches to the 31 kHz dot clock
               (0x09A8 bit 0 + the BIOS 31 kHz master SYNC), times it, restores; screenshots every 3 s
               show the switch on HDMI. Not in the default set (run it with --items crt31k)
  PASS CHECKS  probe items: every INTEG_*.TXT ends 'INTEG END FAILS=0000', INTEG_OK.TXT exists, and
               for probe-cda the PLAY row says 'PLAY OK' (a probe that could not play audio proved nothing
               about CD-DA).  Game items: the screen is not frozen (frame-diff between consecutive
               screenshots), and a known frame is reached (downscaled difference to a reference image).
               crt31k: CRT31K.TXT reaches END:CRT31K with no TIMEOUT, 0x09A8 reads 01 after the set and is
               restored, and the 31 kHz dot clock (calibrated by the run's own 24 kHz rows, as
               crt31k_decode.py does) is within 10 ppm of the Xe10's 25 168 031 Hz (docs/probes/CRT31K.TXT).
               cpusuite: CPUSUITE.TXT ends 'CPUSUITE END ... FAIL=0', ran every program the pack holds
               (its build/manifest.json) on every pass, and each one has a PASS row; a run that stops
               early names the program it stopped in (the harness commits each name before running it).

NOTHING OF THE USER'S IS EVER COMMITTED. The images are arguments; reference frames live in --refs
(a directory of the user's choosing, outside any commit); the patched image copies live under
the run's --out directory (default .build/mister-regress/, git-ignored) and on the MiSTer only for
the run.

THE MiSTer IS SHARED. Without --go this prints the plan and touches nothing. With --go it takes a lock
(/tmp/zreg.lock on the MiSTer; an existing lock aborts the run and says who holds it,
or with --lock-wait S waits that long for it; only the lock's holder ever cleans up), uses only names
that contain 'zreg', and a `finally` removes every file it created and verifies the removal.

    # plan only
    tools/mister_regress.py --rbf out.rbf --hdd-image <your-disk>.img --cd GAME.pcd --cd-drive E:
    # run it
    tools/mister_regress.py --go --rbf out.rbf --hdd-image <your-disk>.img --fdd0 A.hdm --cd GAME.pcd \
        --cd-drive E: --scenarios my_scenarios.json --refs ~/regress-refs --items probe,probe-cda,policenauts
    # record the known frames from a good build instead of checking them
    tools/mister_regress.py --go ... --items policenauts --record-refs

    tools/mister_regress.py --selftest      # hardware-free: frame-diff, parsing, plan, image patching
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools/hwprobe/integ"))
import fatimg  # noqa: E402
import integ_manifest as im  # noqa: E402

TAG = "zreg"                                   # every remote name contains this
CORE = "PC9821Z486"
SETNAME = "PC9821"
GAMES = "/media/fat/games/PC9821"
REMOTE_TMP = f"/tmp/{TAG}"
LOCK = f"/tmp/{TAG}.lock"
REMOTE_RBF = f"/media/fat/_Computer/{CORE}-{TAG}.rbf"
REMOTE_MGL = f"/media/fat/{TAG.upper()}.mgl"
SHOTS = f"/media/fat/screenshots/{SETNAME}"

ITEMS = ("keymap", "probe", "probe-cda", "doom", "th05", "rusty", "policenauts", "flamezap", "cpusuite", "crt31k")
# The set a run without --items gets (tools/mister_multi.py DEFAULT_ITEMS is the same list): all
# of them but crt31k (cpusuite takes ~1.5 min on the card, boot included; measured 2026-10-14).
DEFAULT_ITEMS = tuple(i for i in ITEMS if i != "crt31k")
CPUSUITE = ROOT / "tools/hwprobe/cpusuite"
CRT31K = ROOT / "tools/hwprobe/crt31k"
CRT31K_CAPTURE_HZ = 25_168_031     # docs/probes/CRT31K.TXT, calibrated (crt31k_decode.py)
GAME_ITEMS = ("keymap", "doom", "th05", "rusty", "policenauts", "flamezap")

STATIC_DIFF = 0.2          # mean abs diff (0-255) below which two screenshots are 'the same frame'
THUMB = (80, 50)


# ---------------------------------------------------------------------------------------------
# pure logic (the part --selftest exercises without a MiSTer)
# ---------------------------------------------------------------------------------------------
BLACK_MAX = 8              # a frame whose brightest sample is at or below this (0-255) has no content


def _png_samples(data: bytes):
    """Stdlib decode of an 8-bit, non-interlaced PNG -> (samples bytes, channels) with alpha dropped,
    or None when the PNG is another kind (the caller then tries PIL)."""
    import zlib
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    pos, idat, plte, hdr = 8, [], None, None
    while pos + 8 <= len(data):
        ln, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if typ == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", body)
        elif typ == b"PLTE":
            plte = body
        elif typ == b"IDAT":
            idat.append(body)
        elif typ == b"IEND":
            break
    if not hdr:
        return None
    w, h, depth, ctype, _, _, interlace = hdr
    chans = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(ctype)
    if depth != 8 or interlace or chans is None or (ctype == 3 and not plte):
        return None
    raw = zlib.decompress(b"".join(idat))
    stride = w * chans
    prev = bytearray(stride)
    out = bytearray()
    i = 0
    for _ in range(h):
        f = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        if f == 1:
            for x in range(chans, stride):
                line[x] = (line[x] + line[x - chans]) & 255
        elif f == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride):
                a = line[x - chans] if x >= chans else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x - chans] if x >= chans else 0
                b = prev[x]
                c = prev[x - chans] if x >= chans else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        elif f != 0:
            return None
        out += line
        prev = line
    if ctype == 3:
        return bytes(plte[3 * v + k] for v in out for k in range(3) if 3 * v + k < len(plte)), 3
    if ctype in (4, 6):
        keep = chans - 1
        return bytes(v for j, v in enumerate(out) if j % chans < keep), keep
    return bytes(out), chans


def frame_stats(path):
    """(min, max, mean) over every colour sample of a screenshot, or None when it cannot be decoded.
    Stdlib first (the tools must run wherever python3 does), PIL for PNGs the decoder declines."""
    path = Path(path)
    try:
        dec = _png_samples(path.read_bytes())
    except Exception:
        dec = None
    if dec is not None:
        smp = dec[0]
        return (min(smp), max(smp), sum(smp) / len(smp)) if smp else None
    try:
        from PIL import Image, ImageStat
        im = Image.open(path).convert("RGB")
        lo, hi = zip(*im.getextrema())
        return min(lo), max(hi), sum(ImageStat.Stat(im).mean) / 3
    except Exception:
        return None


def is_black(stats) -> bool:
    """No content: the brightest sample is at most BLACK_MAX, or the frame is one flat colour."""
    return stats is not None and (stats[1] <= BLACK_MAX or stats[0] == stats[1])


def check_content(paths):
    """A screenshot sequence whose every frame is blank (no video ever reached the scaler) fails,
    whatever else it satisfies: a static black screen is 'not frozen' only vacuously."""
    st = [frame_stats(p) for p in paths]
    known = [x for x in st if x is not None]
    if not known:
        return True, "content not checked (screenshots not decodable)"
    nb = sum(1 for x in known if is_black(x))
    ok = nb < len(known)
    return ok, f"{len(known) - nb}/{len(known)} frames have content (max pixel {max(x[1] for x in known)})"


def thumb(path):
    from PIL import Image
    return Image.open(path).convert("L").resize(THUMB)


def mean_abs_diff(a, b) -> float:
    from PIL import ImageChops, ImageStat
    return ImageStat.Stat(ImageChops.difference(a, b)).mean[0]


def frame_diffs(paths):
    """Mean abs difference between consecutive screenshots (same measure as the pn-stall grid)."""
    ts = [thumb(p) for p in paths]
    return [mean_abs_diff(ts[i - 1], ts[i]) for i in range(1, len(ts))]


def longest_static_run(diffs, gaps=None) -> float:
    """Longest run of consecutive near-identical screenshot pairs: in INTERVALS, or in seconds
    when gaps (the time between each pair, same length as diffs) is given."""
    best = cur = 0
    for i, d in enumerate(diffs):
        cur = cur + (1 if gaps is None else gaps[i]) if d < STATIC_DIFF else 0
        best = max(best, cur)
    return best


def check_motion(paths, max_static_s: float, every_s: float, min_changes: int, times=None):
    """times: each shot's time in seconds (shot_times); without it the shots are every_s apart."""
    diffs = frame_diffs(paths)
    if times is not None:
        run = longest_static_run(diffs, [times[i] - times[i - 1] for i in range(1, len(times))])
    else:
        run = longest_static_run(diffs) * every_s
    changes = sum(1 for d in diffs if d >= STATIC_DIFF)
    ok = run <= max_static_s and changes >= min_changes
    return ok, f"{len(paths)} shots, {changes} changes, longest static run {run:.0f}s (limit {max_static_s:.0f}s, need {min_changes} changes)"


def check_known_frame(paths, ref_path, max_diff: float, every_s: float, not_before_s: float = 0.0,
                      until_s: float | None = None, times=None):
    """PASS when ANY shot taken in [not_before_s, until_s] is within max_diff of the reference
    (the best of them is reported). times: each shot's time (shot_times), else i * every_s.
    A transient frame (an intro scene a second or two long) needs shots dense enough to land on
    it whatever the launch jitter: the scenario's `dense` windows supply them."""
    ref = thumb(ref_path)
    best = (1e9, -1)
    for i, p in enumerate(paths):
        t = times[i] if times is not None else i * every_s
        if t < not_before_s or (until_s is not None and t > until_s):
            continue
        d = mean_abs_diff(thumb(p), ref)
        best = min(best, (d, i))
    if best[1] < 0:
        return False, f"no screenshot inside the allowed window for {Path(ref_path).name}"
    t = times[best[1]] if times is not None else best[1] * every_s
    win = f", window {not_before_s:g}-{until_s:g}s" if until_s is not None else ""
    return best[0] <= max_diff, f"closest to {Path(ref_path).name}: shot {best[1]} (~{t:.0f}s{win}), diff {best[0]:.2f} (limit {max_diff})"


def shot_schedule(s: dict):
    """The times (s after the steps) at which a game item takes its screenshots: every
    `shot_every` up to `run`, and inside each `dense` window {from_s, to_s, every_s} every
    every_s instead (a transient known frame needs dense shots to be caught reliably)."""
    every = s.get("shot_every", 15)
    run = s.get("run", 180)
    times = [every * k for k in range(1, int(run // every) + 1)]
    for w in s.get("dense") or []:
        lo, hi, st = float(w["from_s"]), float(w["to_s"]), float(w.get("every_s", 1))
        if st <= 0 or hi < lo:
            raise SystemExit(f"scenario: bad dense window {w}")
        times = [t for t in times if not lo <= t <= hi]
        k = 0
        while lo + k * st <= hi + 1e-9:
            times.append(round(lo + k * st, 3))
            k += 1
    return sorted(set(times))


SHOT_TS = "%Y%m%d_%H%M%S"


def shot_times(paths, card_t0: str, fallback):
    """Each shot's time in seconds after card_t0 (the card's `date +%Y%m%d_%H%M%S` when the shot
    loop began), from the timestamp Main_MiSTer puts in the name; the fallback (the schedule)
    when a stamp is unreadable."""
    import datetime
    try:
        t0 = datetime.datetime.strptime(card_t0, SHOT_TS)
        return [(datetime.datetime.strptime(Path(p).name[:15], SHOT_TS) - t0).total_seconds() for p in paths]
    except (ValueError, TypeError):
        return list(fallback[:len(paths)]) + [fallback[-1] if fallback else 0.0] * max(0, len(paths) - len(fallback))


def parse_integ(text: str) -> dict:
    """One INTEG capture -> {'fails': int|None, 'bad': [rows], 'play': row|None, 'files': n}."""
    fails = None
    m = re.findall(r"INTEG END FAILS=([0-9A-F]{4})", text)
    if m:
        fails = int(m[-1], 16)
    return {
        "fails": fails,
        "bad": [l.strip() for l in text.splitlines() if l.startswith("BAD ") or l.startswith("WFAIL") or " OPENFAIL" in l
                or " READFAIL" in l or "MANIFEST" in l],
        "play": next((l.strip() for l in text.splitlines() if l.startswith("PLAY ")), None),
        "files": text.count("\nFILE ") + text.count("\nWFILE "),
    }


def judge_probe(captures: dict, expect: list, want_play: bool):
    """captures: {'INTEG_C.TXT': text|None}. expect: the capture names that must exist and pass."""
    problems = []
    if captures.get("INTEG_OK.TXT") is None:
        problems.append("INTEG_OK.TXT missing: the run did not finish")
    for name in expect:
        t = captures.get(name)
        if t is None:
            problems.append(f"{name} missing")
            continue
        r = parse_integ(t)
        if r["fails"] is None:
            problems.append(f"{name}: no 'INTEG END' row (the probe died)")
        elif r["fails"] != 0:
            problems.append(f"{name}: FAILS={r['fails']:04X}: " + " | ".join(r["bad"][:3]))
    if want_play:
        t = captures.get("INTEG_P.TXT")
        r = parse_integ(t) if t else None
        if not r or not r["play"] or not r["play"].startswith("PLAY OK"):
            problems.append("INTEG_P.TXT: CD-DA was not playing (" + (r["play"] if r and r["play"] else "no PLAY row") + ")")
    return (not problems), ("; ".join(problems) if problems else "all INTEG captures FAILS=0000")


def parse_cpusuite(text: str) -> dict:
    """CPUSUITE.TXT -> {'begin': (programs, passes)|None, 'rows': [(name, verdict, detail)],
    'pending': name|None (the program the run stopped in), 'end': {PASSES,RUN,PASS,FAIL}|None}."""
    r = {"begin": None, "rows": [], "pending": None, "end": None}
    for line in text.replace("\r", "").split("\n"):
        m = re.match(r"CPUSUITE BEGIN V1 PROGRAMS=(\d+) PASSES=(\d+)", line)
        if m:
            r["begin"] = (int(m.group(1)), int(m.group(2)))
            continue
        m = re.match(r"CPUSUITE END PASSES=(\d+) RUN=(\d+) PASS=(\d+) FAIL=(\d+)", line)
        if m:
            r["end"] = dict(zip(("PASSES", "RUN", "PASS", "FAIL"), map(int, m.groups())))
            continue
        m = re.match(r"(\S+) (PASS|FAIL)\b ?(.*)", line)
        if m:
            r["rows"].append((m.group(1), m.group(2), m.group(3).strip()))
        elif line.strip():
            r["pending"] = line.split()[0]     # a name with no verdict: the run stopped there
    return r


def judge_cpusuite(text, expect: list, passes: int):
    """-> (ok, detail). expect: the program names the pack holds (its manifest)."""
    if text is None:
        return False, "CPUSUITE.TXT missing: the harness did not start (no XMS? EMM386 loaded? see the screenshot)"
    r = parse_cpusuite(text)
    fails = [f"{n} ({d or v})" for n, v, d in r["rows"] if v != "PASS"]
    problems = []
    if r["end"] is None:
        where = f"stopped in {r['pending']}" if r["pending"] else "no END row"
        problems.append(f"did not finish: {where} after {len(r['rows'])} results (a hang: the machine did not come back)")
    else:
        want = len(expect) * passes
        if r["end"]["RUN"] != want or r["end"]["PASSES"] != passes:
            problems.append(f"ran {r['end']['RUN']} programs in {r['end']['PASSES']} passes, want {want} in {passes}")
        if r["end"]["FAIL"] != 0:
            problems.append(f"FAIL={r['end']['FAIL']}")
    counts = {}
    for n, v, _ in r["rows"]:
        if v == "PASS":
            counts[n] = counts.get(n, 0) + 1
    missing = [n for n in expect if counts.get(n, 0) < passes]
    if r["end"] is not None and missing:
        problems.append(f"{len(missing)} programs without a PASS on every pass (first: {missing[0]})")
    if fails:
        problems.append(f"{len(fails)} failed: " + ", ".join(fails[:12]) + (" ..." if len(fails) > 12 else ""))
    npass = sum(1 for _, v, _ in r["rows"] if v == "PASS")
    if problems:
        return False, f"{npass}/{len(r['rows'])} rows PASS; " + "; ".join(problems)
    return True, f"{npass}/{len(r['rows'])} PASS ({len(expect)} programs x {passes} pass{'es' if passes > 1 else ''})"


def cpusuite_files() -> tuple[dict, list]:
    """Build CPUSUITE.COM and its pack (make; the pack is generated from src/z486/tests/programs)
    -> ({DOS name: bytes}, the program names the pack holds)."""
    subprocess.run(["make", "-C", str(ROOT / "tools/hwprobe"), "cpusuite"], check=True)
    man = json.loads((CPUSUITE / "build/manifest.json").read_text())
    return ({"CPUSUITE.COM": (CPUSUITE / "cpusuite.com").read_bytes(),
             "CPUSUITE.BIN": (CPUSUITE / "build/CPUSUITE.BIN").read_bytes()}, man["run"])


def crt31k_files() -> dict:
    """Build CRT31K.COM (make) -> {DOS name: bytes}."""
    subprocess.run(["make", "-C", str(ROOT / "tools/hwprobe"), "crt31k/crt31k.com"], check=True)
    return {"CRT31K.COM": (CRT31K / "crt31k.com").read_bytes()}


def judge_crt31k(text):
    """CRT31K.TXT -> (ok, detail): the run finished and restored 0x09A8, and the 31 kHz dot clock
    (calibrated by the same run's 24 kHz rows) is the Xe10's within 10 ppm."""
    if not text or "END:CRT31K" not in text:
        return False, "no END:CRT31K row (the probe did not finish; see the screenshots)"
    sys.path.insert(0, str(CRT31K))
    import crt31k_decode
    artic, modes = crt31k_decode.decode(text)
    problems = []
    if "TIMEOUT" in text:
        problems.append("a run TIMED OUT (no VSYNC edge)")
    if "after_set31=01" not in text:
        problems.append("0x09A8 does not read 01 after the set")
    m = re.search(r"RESTORE 09A8 was=(\w\w) now=(\w\w)", text)
    if not m or m.group(1) != m.group(2):
        problems.append("0x09A8 not restored")
    dot = {}
    for md in modes:
        if md["runs"]:
            dot[md["name"]] = sum(artic * n / t * md["v"] * md["h"] for n, t in md["runs"]) / len(md["runs"])
    d24 = next((v for k, v in dot.items() if k.startswith("24K")), None)
    d31 = next((v for k, v in dot.items() if k.startswith("31K")), None)
    if d24 is None or d31 is None:
        return False, "; ".join(problems + ["no 24K or 31K rows"])
    cal = crt31k_decode.NOMINAL_24K_DOT / d24
    ppm = (d31 * cal - CRT31K_CAPTURE_HZ) / CRT31K_CAPTURE_HZ * 1e6
    detail = f"31 kHz dot {d31 * cal:.0f} Hz calibrated ({d31:.0f} raw), {ppm:+.2f} ppm from the Xe10's {CRT31K_CAPTURE_HZ}"
    if not -10.0 < ppm < 10.0:
        problems.append("the 31 kHz dot clock is not the Xe10's")
    return (not problems), "; ".join(problems + [detail])


def load_scenarios(path):
    sc = json.load(open(path))
    for k in GAME_ITEMS:
        if k in sc:
            s = sc[k]
            for step in s.get("steps", []):
                if step[0] not in ("type", "wait", "click", "key"):
                    raise SystemExit(f"scenario {k}: unknown step {step!r}")
    return sc


def set_default_profile(config_sys: bytes, n: int) -> bytes:
    """Rewrite SELSYS's `REM DEFAULTn` line (CRLF kept; every other byte untouched)."""
    new, k = re.subn(rb"(?m)^REM DEFAULT\d+(\r?)$", lambda m: b"REM DEFAULT%d%s" % (n, m.group(1)), config_sys, count=1)
    if k != 1:
        raise SystemExit("CONFIG.SYS has no 'REM DEFAULTn' line to rewrite")
    return new


def item_needs(item, sc):
    """None if the item is runnable, else the reason it is not (a SKIP, not a pass)."""
    if item in GAME_ITEMS:
        if item not in sc:
            return f"no '{item}' entry in the scenarios file"
        for step in sc[item].get("steps", []):
            if any(str(x).startswith("?") for x in step[1:]):
                return f"'{item}' still has a '?' placeholder command (the scenarios file must supply it)"
    return None


# ---------------------------------------------------------------------------------------------
# preparing the guest-visible files (host side, on COPIES)
# ---------------------------------------------------------------------------------------------

def container_skip(path: Path) -> int:
    """Bytes of container header before the disk data: an HDI/FDI image's HeaderSize, else 0.

    The core recognises an HDI by content too (pc9821_hdd_image.sv), because hps_io gives it
    a size and a pulse, never a name. This mirrors that validation so the runner can patch and
    read the guest's files through the header: reserved 0, HeaderSize [32, 1 MiB] and a whole
    sector, 512 bytes/sector, and each geometry field inside NP2kai's bounds (fdd/sxsihdd.c:
    0 < sectors, heads < 256, 0 < cylinders < 65536). DataSize and the file size are not
    checked, as NP2kai does not check them. Anything else is a raw image and its data starts
    at 0, which is what the core does with it.
    """
    try:
        with open(path, "rb") as f:
            h = f.read(32)
    except OSError:
        return 0
    if len(h) < 32:
        return 0
    rsv, _ftype, hs, _ds, bps, spt, heads, cyls = struct.unpack("<8I", h)
    if rsv or not (32 <= hs <= (1 << 20)) or hs % 512 or bps != 512:
        return 0
    if not (0 < spt < 256 and 0 < heads < 256 and 0 < cyls < 65536):
        return 0
    return hs


def manifest_for(img: Path, drive: str, kind: str, select: dict) -> str:
    with open(img, "rb") as f:
        if kind == "cd":
            fs = fatimg.Iso(f, select.get("layout", "iso"))
            read = lambda e: fs.read(e.start, min(e.size, select["max_bytes"]))
        else:
            fs = fatimg.Fat(f, fatimg.locate_volume(f, select.get("partition"), select.get("offset"), select.get("skip", 0)))
            read = lambda e: fs.read_file(e, select["max_bytes"])
        ents = [e for e in fs.walk() if e.size > 0 and e.path.isascii()]   # Shift-JIS names cannot be typed into a manifest
        if select.get("under"):
            u = select["under"].upper().strip("\\/") + "\\"
            ents = [e for e in ents if e.path.upper().startswith(u)]
        ents = sorted(ents, key=lambda e: -e.size)[: select["largest"]]
        if not ents:
            raise SystemExit(f"{img}: no files selected for {drive}")
        return im.manifest_text(((e.path, read(e)) for e in ents), drive)


def patch_hdd(src: Path, dst: Path, files: dict, partition, offset, skip):
    """Copy the image and put the probe's files in its root. A COPY only."""
    shutil.copyfile(src, dst)
    with open(dst, "r+b") as f:
        fs = fatimg.Fat(f, fatimg.locate_volume(f, partition, offset, skip))
        for name, data in files.items():
            fs.put(name, data)


def bat_text(manifests: dict) -> bytes:
    """RUNINTEG.BAT for exactly the drives this run has manifests for (CRLF). Same shape as the
    shipped tools/hwprobe/integ/RUNINTEG.BAT, which hard-codes C:/A:/E:."""
    L = ["@ECHO OFF", 'IF "%1"=="/PLAY" INTEG P > INTEG_P.TXT']
    for drive in manifests:
        L.append(f"INTEG V {drive[0]}_INTEG.MAN > INTEG_{drive[0]}.TXT")
    hdd = next(iter(manifests))               # the first manifest is the hard disk's
    L.append(f"INTEG W {hdd} /K:512 > INTEG_W{hdd[0]}.TXT")
    if "A:" in manifests and hdd != "A:":
        L.append("INTEG W A: /K:256 > INTEG_WA.TXT")
    L += ['IF "%1"=="/PLAY" INTEG S >> INTEG_P.TXT', "ECHO done > INTEG_OK.TXT"]
    return ("\r\n".join(L) + "\r\n").encode()


def probe_files(manifests: dict) -> dict:
    com = ROOT / "tools/hwprobe/integ/integ.com"
    if not com.exists():
        subprocess.run(["make", "-C", str(ROOT / "tools/hwprobe"), "integ/integ.com"], check=True)
    files = {"INTEG.COM": com.read_bytes(), "RUNINTEG.BAT": bat_text(manifests)}
    for drive, text in manifests.items():
        files[f"{drive[0]}_INTEG.MAN"] = text.encode()
    return files


def expected_captures(manifests: dict, want_play: bool):
    exp = []
    for drive in manifests:
        exp.append(f"INTEG_{drive[0]}.TXT")
    exp.append(f"INTEG_W{next(iter(manifests))[0]}.TXT")
    if "A:" in manifests and next(iter(manifests)) != "A:":
        exp.append("INTEG_WA.TXT")
    return exp


def mgl_text(hdd=None, fdd0=None, fdd1=None, cd=None, pack="pc98pack-xe10.bin") -> str:
    """The same shape tools/mister_load.sh writes; an S entry's index is the hps_io slot."""
    lines = ["<mistergamedescription>", f"\t<rbf>_Computer/{CORE}-{TAG}</rbf>", f"\t<setname>{SETNAME}</setname>"]
    for idx, p in ((0, hdd), (1, fdd0), (2, fdd1), (4, cd)):
        if p:
            lines.append(f'\t<file delay="1" type="s" index="{idx}" path="{p}"/>')
    lines.append(f'\t<file delay="1" type="f" index="0" path="{pack}"/>')
    lines.append("</mistergamedescription>")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------------------------
# the MiSTer
# ---------------------------------------------------------------------------------------------
class Mister:
    def __init__(self, host, password, dry):
        # host is the ssh destination; a bare host name gets root@. Authentication is ssh keys
        # unless a password is given, which goes through sshpass -e (SSHPASS in the environment,
        # never on a command line).
        self.host = host if "@" in host else f"root@{host}"
        self.dry = dry
        self.env = dict(os.environ, SSHPASS=password) if password else dict(os.environ)
        self.auth = ["sshpass", "-e"] if password else []
        # UserKnownHostsFile=/dev/null: a card that was re-flashed (same address, new host key) or two
        # cards that once shared an address must not make ssh refuse.
        self.opts = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                     "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10"]
        self.created = []          # remote paths, for the cleanup verification
        self.plan = []
        self.uart_pids = []        # the ttyS1 readers this run started (only these are killed)
        self.shot_stems = set()    # the screenshot name stems this run's files carry

    def sh(self, cmd, check=True, timeout=600):
        self.plan.append(("ssh", cmd))
        if self.dry:
            return ""
        r = subprocess.run(self.auth + ["ssh"] + self.opts + [self.host, cmd], env=self.env,
                           capture_output=True, text=True, timeout=timeout)
        if check and r.returncode != 0:
            raise RuntimeError(f"ssh failed ({r.returncode}): {cmd}\n{r.stderr.strip()}")
        return r.stdout

    def put(self, local, remote):
        assert TAG in remote.lower(), f"refusing to write outside the {TAG} namespace: {remote}"
        self.plan.append(("scp-put", f"{local} -> {remote}"))
        self.created.append(remote)
        if not self.dry:
            subprocess.run(self.auth + ["scp", "-O"] + self.opts + [str(local), f"{self.host}:{remote}"],
                           env=self.env, check=True)

    def get(self, remote, local):
        self.plan.append(("scp-get", f"{remote} -> {local}"))
        if not self.dry:
            subprocess.run(self.auth + ["scp", "-O"] + self.opts + [f"{self.host}:{remote}", str(local)],
                           env=self.env, check=True)

    def write(self, text, remote):
        with tempfile.NamedTemporaryFile("w", delete=False) as t:
            t.write(text)
        try:
            self.put(t.name, remote)
        finally:
            os.unlink(t.name)


def host_slug(host: str) -> str:
    """A filesystem-safe name for an ssh destination (used in per-run local paths)."""
    h = host.split("@", 1)[-1]
    return "".join(c if c.isalnum() or c in "-_." else "_" for c in h) or "host"


def take_lock(m: Mister, wait_s: int, say, poll_s: float = 30) -> str:
    """Take the card's lock, waiting up to wait_s seconds for another holder. Returns "got" or
    "held: <owner>" (the caller refuses on the latter)."""
    deadline = time.time() + wait_s
    # poll_s below 1: the mkdir is retried ON the card (every poll_s, for up to a minute per ssh
    # call), so a loop that releases and re-takes the lock back to back can still be interleaved
    tries = int(60 / poll_s) if 0 < poll_s < 1 else 1
    owner = f"{os.uname().nodename} pid {os.getpid()} {time.ctime()}"
    while True:
        held = m.sh(f"g=0; t=0; while [ $t -lt {tries} ]; do if mkdir {LOCK} 2>/dev/null; then g=1; break; fi; "
                    f"t=$((t+1)); [ $t -lt {tries} ] && sleep {poll_s}; done; "
                    f"if [ $g = 1 ]; then echo '{owner}' > {LOCK}/owner; echo got; "
                    f"else echo held: $(cat {LOCK}/owner 2>/dev/null); fi", check=False, timeout=120).strip()
        if held.startswith("got") or time.time() >= deadline:
            return held
        say(f"locked by another run ({held}); waiting")
        time.sleep(poll_s)


def log(out, msg):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    with open(out / "log.txt", "a") as f:
        f.write(line + "\n")


def shot_stems(a) -> set:
    """The name stems this run's screenshots can carry. Main_MiSTer names a screenshot
    <YYYYMMDD_HHMMSS>-<stem>.png after the last file loaded through the core's ROM loader: the
    pack, which this run's MGL loads last (every regression capture so far is
    `..-pc98pack-xe10.png`), or the core's own name when nothing was loaded."""
    return {Path(a.pack).stem, f"{CORE}-{TAG}"}


def own_shot(name: str, stems, since: str) -> bool:
    """A screenshot this run caused: named <stamp>-<one of stems>.png with a stamp at or after
    `since` (the card's clock when the item began). Anything else in SHOTS is someone else's.
    stems None accepts any stem (a core whose naming is unknown; the stamp still bounds it)."""
    m = re.fullmatch(r"(\d{8}_\d{6})-(.+)\.png", name)
    return bool(m and (stems is None or m.group(2) in stems) and (not since or m.group(1) >= since))


def card_now(m: Mister) -> str:
    return m.sh(f"date +{SHOT_TS}", check=False).strip()


def collect_shots(m: Mister, a, before: set, since: str, itemdir: Path):
    """Fetch this item's own new screenshots (own_shot), record them for the cleanup, and
    return their local paths in time order. Other files in SHOTS are left alone."""
    stems = shot_stems(a)
    m.shot_stems |= stems
    out = []
    for f in sorted(set(m.sh(f"ls {SHOTS} 2>/dev/null || true").split()) - before):
        if not own_shot(f, stems, since):
            continue
        m.get(f"{SHOTS}/{f}", itemdir / f)
        m.created.append(f"{SHOTS}/{f}")          # a screenshot the run made: removed in cleanup
        out.append(itemdir / f)
    return out


def start_uart(m: Mister):
    """Start this run's ttyS1 reader and record its PID (the sh exec's into cat, so $! is cat)."""
    pid = m.sh("stty -F /dev/ttyS1 115200 raw -echo; rm -f /tmp/zreg/uart.bin; "
               "nohup sh -c 'exec cat /dev/ttyS1 > /tmp/zreg/uart.bin' </dev/null >/dev/null 2>&1 & echo $!").strip()
    if pid.isdigit():
        m.uart_pids.append(int(pid))


def stop_uart(m: Mister):
    """Kill only the readers this run started, and only while each PID is still a cat on ttyS1
    (a PID reused by another process is left alone)."""
    for pid in m.uart_pids:
        m.sh(f"[ \"$(cat /proc/{pid}/comm 2>/dev/null)\" = cat ] && ls -l /proc/{pid}/fd 2>/dev/null "
             f"| grep -q ttyS1 && kill {pid}", check=False)
    m.uart_pids = []


def cat_cmd(a, hskip: int, name: str) -> str:
    """Read one capture file out of the card-side image copy (an HDI's header is skipped)."""
    return (f"python3 {REMOTE_TMP}/integ_manifest.py --image {GAMES}/{TAG}-hdd.img "
            f"{'--partition %d ' % a.partition if a.partition is not None else ''}"
            f"{'--skip %d ' % hskip if hskip else ''}--cat {name} 2>/dev/null")


def run_item(m: Mister, item, a, sc, prep, out):
    """Boot the core on a fresh image copy, drive it, collect. Returns (verdict, detail)."""
    hskip = prep.get("skip", 0)          # an HDI container's front header, for the guest-side reads
    itemdir = out / item
    itemdir.mkdir(parents=True, exist_ok=True)
    # a fresh copy of the patched image for this item (items must not contaminate each other)
    m.sh(f"cp {GAMES}/{TAG}-hdd.base {GAMES}/{TAG}-hdd.img")
    m.created.append(f"{GAMES}/{TAG}-hdd.img")
    for n, base in (("fdd0", prep.get("fdd0")), ("fdd1", prep.get("fdd1"))):
        if base:
            m.sh(f"cp {GAMES}/{TAG}-{n}.base {GAMES}/{TAG}-{n}.img")
            m.created.append(f"{GAMES}/{TAG}-{n}.img")
    cfg = (sc.get(item, {}) if sc else {}).get("config_default")
    if cfg is None and item == "cpusuite" and re.search(rb"(?m)^REM DEFAULT\d+\r?$", prep["config_sys"]):
        cfg = 0          # the programs enter protected mode themselves: no EMM386 (profile 0, noemm)
    if cfg is not None:
        # a per-item boot profile: CONFIG.SYS of THIS item's image copy (SELSYS `REM DEFAULTn`, 0-based:
        # 0 = noemm, 1 = himem, 2 = emm386, 3 = full/NECCD), patched on the MiSTer with the shipped fatimg
        local = itemdir / "CONFIG.SYS"
        local.write_bytes(set_default_profile(prep["config_sys"], cfg))
        m.put(local, f"{REMOTE_TMP}/CONFIG.{item}")
        m.sh(f"python3 {REMOTE_TMP}/fatimg.py {GAMES}/{TAG}-hdd.img "
             f"{'--partition %d ' % a.partition if a.partition is not None else ''}"
             f"{'--skip %d ' % hskip if hskip else ''}--put CONFIG.SYS {REMOTE_TMP}/CONFIG.{item}")
    mgl = mgl_text(f"{TAG}-hdd.img", f"{TAG}-fdd0.img" if prep.get("fdd0") else None,
                   f"{TAG}-fdd1.img" if prep.get("fdd1") else None,
                   f"{TAG}-cd.img" if prep.get("cd") else None, a.pack)
    m.write(mgl, REMOTE_MGL)
    since = card_now(m)
    before = set(m.sh(f"ls {SHOTS} 2>/dev/null || true").split())
    if a.uart:
        start_uart(m)
    log(out, f"{item}: load_core")
    m.sh(f"echo 'load_core {REMOTE_MGL}' > /dev/MiSTer_cmd")
    boot = (sc.get(item, {}).get("boot_wait") if sc else None) or a.boot_wait
    time.sleep(0 if m.dry else boot)
    verdict, detail = "PASS", ""

    def type_(s):
        m.sh(f"python3 {REMOTE_TMP}/ztype.py {shlex.quote(s)}")

    if item in ("probe", "probe-cda"):
        # AUTOEXEC may leave the guest in another directory; the batch writes its captures to the cwd
        type_("cd \\\n")
        type_("RUNINTEG /PLAY\n" if item == "probe-cda" else "RUNINTEG\n")
        deadline = time.time() + a.probe_timeout
        exp = expected_captures(prep["manifests"], item == "probe-cda")
        cdcap = f"INTEG_{a.cd_drive[0].upper()}.TXT" if a.cd else None
        names = exp + ["INTEG_OK.TXT"] + (["INTEG_P.TXT"] if item == "probe-cda" else [])
        if item == "probe-cda" and cdcap in exp:
            # With CD-DA playing, NECCD.SYS fails every data read with 'Not ready' (the guest shows
            # "CDR101: Not ready", reading drive Q, translated; INTEG's INT 24h FAIL turns it into OPENFAIL AX=0005).
            # That is the guest stack's documented answer, not the drive's: the MS-DOS CD-ROM Extensions
            # 2.1 driver spec has the driver "fail all requests to the physical device that require head
            # movement when the device is playing" with the busy and error bits and an error code, and
            # the --dbg-cd trail of this item (2026-10-12) shows NECCD.SYS deciding each open from READ
            # SUB-CHANNEL's audio status 0x11 and sending no READ(10) while the drive plays
            # (docs/pc9821-port-status.md, CD-ROM). So the CD's own verify cannot be a pass criterion
            # here; the HDD verify and write/read-back under CD-DA are. The CD capture is reported.
            exp = [e for e in exp if e != cdcap]
        caps = {}
        while True:
            time.sleep(0 if m.dry else 20)
            m.sh("echo screenshot > /dev/MiSTer_cmd")      # what the guest shows while INTEG runs (a hang is visible)
            caps = {}
            for n in names:
                t = m.sh(cat_cmd(a, hskip, n), check=False)
                caps[n] = t or None
            if m.dry or caps.get("INTEG_OK.TXT") or time.time() > deadline:
                break
        for n, t in caps.items():
            if t:
                (itemdir / n).write_text(t)
        if not m.dry:
            collect_shots(m, a, before, since, itemdir)
        ok, detail = judge_probe(caps, exp, item == "probe-cda") if not m.dry else (True, "dry run")
        if item == "probe-cda" and not m.dry and cdcap and caps.get(cdcap):
            r = parse_integ(caps[cdcap])
            detail += (f"; CD verify under CD-DA (informational - NECCD.SYS refuses data reads while audio plays, "
                       f"as the MSCDEX driver spec requires): FAILS={r['fails']}, " + ((r['bad'][0] if r['bad'] else 'no rows')))
        verdict = "DRY" if m.dry else ("PASS" if ok else "FAIL")
    elif item == "crt31k":
        type_("cd \\\n")
        type_("CRT31K > CRT31K.TXT\n")
        t0 = time.time()
        text = None
        while True:
            time.sleep(0 if m.dry else 3)
            m.sh("echo screenshot > /dev/MiSTer_cmd")     # the 24 -> 31 -> 24 kHz switches on HDMI
            if time.time() - t0 > 25 or m.dry:
                text = m.sh(cat_cmd(a, hskip, "CRT31K.TXT"), check=False) or None
                if m.dry or (text and "END:CRT31K" in text) or time.time() - t0 > 90:
                    break
        if text:
            (itemdir / "CRT31K.TXT").write_text(text)
        if not m.dry:
            collect_shots(m, a, before, since, itemdir)
        ok, detail = judge_crt31k(text) if not m.dry else (True, "dry run")
        verdict = "DRY" if m.dry else ("PASS" if ok else "FAIL")
    elif item == "cpusuite":
        type_("cd \\\n")
        # /Pn, not /P:n (ztype typed ':' as '+' before it mapped ':' to the PC-98 colon key; /Pn still works)
        type_("CPUSUITE\n" if a.cpusuite_passes == 1 else f"CPUSUITE /P{a.cpusuite_passes}\n")
        t0 = time.time()
        deadline = t0 + a.cpusuite_timeout
        text = None
        while True:
            time.sleep(0 if m.dry else 15)
            m.sh("echo screenshot > /dev/MiSTer_cmd")
            text = m.sh(cat_cmd(a, hskip, "CPUSUITE.TXT"), check=False) or None
            # the header row is written before the first program runs: no file after 90 s means
            # the harness refused to start (its message is on the screenshot)
            if m.dry or (text and "CPUSUITE END" in text) or time.time() > deadline or \
                    (not text and time.time() - t0 > 90):
                break
        if text:
            (itemdir / "CPUSUITE.TXT").write_text(text)
        if not m.dry:
            collect_shots(m, a, before, since, itemdir)
        ok, detail = judge_cpusuite(text, prep["cpusuite"], a.cpusuite_passes) if not m.dry else (True, "dry run")
        verdict = "DRY" if m.dry else ("PASS" if ok else "FAIL")
    else:
        s = sc[item]
        every = s.get("shot_every", 15)
        sched = shot_schedule(s)
        for step in s["steps"]:
            op = step[0]
            if op == "type":
                type_(step[1])
            elif op == "wait":
                time.sleep(0 if m.dry else float(step[1]))
            elif op == "click":
                m.sh(f"python3 {REMOTE_TMP}/zclick.py " + " ".join(str(x) for x in step[1:]))
            elif op == "key":
                type_(f"~k{int(step[1])};")
        n = len(sched)
        card_t0 = card_now(m)
        t0 = time.time()
        for t in sched:          # an absolute schedule: ssh latency does not accumulate
            time.sleep(0 if m.dry else max(0.0, t0 + t - time.time()))
            m.sh("echo screenshot > /dev/MiSTer_cmd")
        time.sleep(0 if m.dry else 3)
        shots = collect_shots(m, a, before, since, itemdir)
        if m.dry:
            return "DRY", "dry run"
        times = shot_times(shots, card_t0, sched)
        # the screenshots taken before the steps finished (the boot) are part of the sequence
        if len(shots) < max(3, n // 2):
            return "FAIL", f"only {len(shots)} screenshots came back of {n} requested"
        ok1, d1 = check_motion(shots, s.get("max_static_s", 60), every, s.get("min_changes", 3), times)
        detail = d1
        if not ok1:
            verdict = "FAIL"
        okc, dc = check_content(shots)
        if not okc:
            verdict = "FAIL"
            detail += f"; BLACK: {dc}"
        # `known_frame` is one reference; `known_frames` a list, every one of which must be reached
        refs = list(s.get("known_frames") or []) + ([s["known_frame"]] if s.get("known_frame") else [])
        for ref in refs:
            refp = Path(a.refs or ".") / ref["ref"]
            if a.record_refs:
                by = ref.get("by_s", s.get("run", 180))
                idx = min(range(len(shots)), key=lambda i: abs(times[i] - by))
                Path(a.refs).mkdir(parents=True, exist_ok=True)
                shutil.copyfile(shots[idx], refp)
                detail += f"; RECORDED {refp.name} from shot {idx} (look at it before trusting it)"
            elif not refp.exists():
                detail += f"; known frame SKIPPED: {refp} does not exist (--record-refs from a good build)"
                if verdict == "PASS":
                    verdict = "SKIP-FRAME"
            else:
                ok2, d2 = check_known_frame(shots, refp, ref.get("max_diff", 12.0), every,
                                            ref.get("not_before_s", 0), ref.get("until_s"), times)
                detail += "; " + d2
                if not ok2:
                    verdict = "FAIL"
    if a.uart:
        m.get(f"{REMOTE_TMP}/uart.bin", itemdir / "uart.bin")
        stop_uart(m)
    return verdict, detail


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rbf", help="the test RBF")
    ap.add_argument("--hdd-image", help="your HDD image (host path; a COPY is patched and uploaded)")
    ap.add_argument("--partition", type=int, default=None, help="MBR partition holding the DOS volume (default: auto - a bare volume, else partition 0)")
    ap.add_argument("--hdd-drive", default="C:", help="the letter the guest gives the HDD (a disk that boots as A: needs --hdd-drive A:)")
    ap.add_argument("--hdd-under", help="restrict the HDD manifest to a directory (e.g. GAMES\\DOOM)")
    ap.add_argument("--hdd-largest", type=int, default=8)
    ap.add_argument("--fdd0", help="a floppy image (raw; mounted as drive A:)")
    ap.add_argument("--fdd1", help="a second floppy image (drive B:)")
    ap.add_argument("--cd", help="a CD image (iso/pcd/raw) mounted on hps_io slot 4")
    ap.add_argument("--cd-layout", choices=("iso", "pcd", "raw"), default="pcd")
    ap.add_argument("--cd-drive", default="E:", help="the letter MSCDEX gives the CD in the guest")
    ap.add_argument("--max-bytes", type=int, default=2 << 20, help="bytes checked per file")
    ap.add_argument("--pack", default="pc98pack-xe10.bin", help="the pack already on the MiSTer (games/PC9821/)")
    ap.add_argument("--items", default=",".join(DEFAULT_ITEMS), help=f"comma list (default {','.join(DEFAULT_ITEMS)})")
    ap.add_argument("--scenarios", help="JSON: per game item boot_wait/steps/run/checks")
    ap.add_argument("--refs", help="directory of known-frame reference PNGs (yours; never committed)")
    ap.add_argument("--record-refs", action="store_true", help="write the known frames instead of checking them")
    ap.add_argument("--uart", action="store_true", help="capture /dev/ttyS1 (trace builds)")
    ap.add_argument("--boot-wait", type=int, default=40, help="seconds from load_core to the DOS prompt")
    ap.add_argument("--probe-timeout", type=int, default=900)
    ap.add_argument("--cpusuite-passes", type=int, default=1, help="cpusuite: run the whole pack N times (CPUSUITE /P:N)")
    ap.add_argument("--cpusuite-timeout", type=int, default=600,
                    help="cpusuite: seconds from typing CPUSUITE to giving up on its END row")
    ap.add_argument("--host", default=os.environ.get("MISTER_HOST", "root@MiSTer"),
                    help="ssh destination (default $MISTER_HOST, else root@MiSTer)")
    ap.add_argument("--password", default=os.environ.get("MISTER_PASS", "1"),
                    help="password auth via sshpass (default $MISTER_PASS, else 1 - the stock MiSTer "
                         "root password; an empty value uses ssh keys)")
    ap.add_argument("--out", help="results directory (default .build/mister-regress/<time>)")
    ap.add_argument("--lock-wait", type=int, default=0, metavar="SECONDS",
                    help="wait up to this long for another run's lock on the card (default: refuse)")
    ap.add_argument("--lock-poll", type=float, default=30, metavar="SECONDS",
                    help="how often --lock-wait asks for the lock (default 30; a back-to-back loop on the card "
                         "re-takes it within seconds of releasing it)")
    ap.add_argument("--go", action="store_true", help="actually touch the MiSTer (otherwise: print the plan)")
    ap.add_argument("--keep", action="store_true", help="do not clean up (debugging)")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    if not (a.rbf and a.hdd_image):
        ap.error("--rbf and --hdd-image are required")
    if a.fdd0 and a.hdd_drive.upper() == "A:":
        ap.error("the HDD is drive A: here, which the floppy would also be; no floppy with --hdd-drive A:")
    items = [i for i in a.items.split(",") if i]
    for i in items:
        if i not in ITEMS:
            ap.error(f"unknown item {i}")
    sc = load_scenarios(a.scenarios) if a.scenarios else {}
    # the default results directory names the host and the pid: two runs started in the same
    # second (two cards, or two shells) must not share one
    out = Path(a.out) if a.out else ROOT / ".build/mister-regress" / (
        f"{time.strftime('%Y%m%d-%H%M%S')}-{host_slug(a.host)}-{os.getpid()}")
    out.mkdir(parents=True, exist_ok=True)

    # ---- host-side preparation (no MiSTer involved)
    skip = container_skip(Path(a.hdd_image))
    if skip:
        log(out, f"{a.hdd_image}: HDI container, data starts at {skip} bytes")
    sel = {"largest": a.hdd_largest, "max_bytes": a.max_bytes, "under": a.hdd_under,
           "partition": a.partition, "skip": skip}
    manifests = {a.hdd_drive.upper(): manifest_for(Path(a.hdd_image), a.hdd_drive.upper(), "fat", sel)}
    if a.fdd0:
        manifests["A:"] = manifest_for(Path(a.fdd0), "A:", "fat", {"largest": 99, "max_bytes": a.max_bytes})
    if a.cd:
        manifests[a.cd_drive.upper()] = manifest_for(
            Path(a.cd), a.cd_drive.upper(), "cd", {"largest": 6, "max_bytes": a.max_bytes, "layout": a.cd_layout})
    # per run, so runs against two MiSTers at once never share the patched copy
    patched = out / "hdd.patched.img"
    files = probe_files(manifests)
    cpus_names = []
    if "cpusuite" in items:
        cf, cpus_names = cpusuite_files()
        files.update(cf)
    if "crt31k" in items:
        files.update(crt31k_files())
    if a.go:
        log(out, f"patching a COPY of {a.hdd_image} -> {patched}")
        patch_hdd(Path(a.hdd_image), patched, files, a.partition, None, skip)
    else:
        log(out, f"(dry run) would patch a COPY of {a.hdd_image} -> {patched} with {sorted(files)}")
    with open(a.hdd_image, "rb") as f:
        cfg_sys = fatimg.Fat(f, fatimg.locate_volume(f, a.partition, None, skip)).cat("CONFIG.SYS")
    prep = {"config_sys": cfg_sys, "manifests": manifests, "cd": bool(a.cd), "fdd0": bool(a.fdd0), "fdd1": bool(a.fdd1),
            "cpusuite": cpus_names, "skip": skip}

    # ---- the plan
    runnable, skipped = [], []
    for it in items:
        why = None
        if it == "probe-cda" and not a.cd:
            why = "needs --cd"
        why = why or item_needs(it, sc)
        (skipped if why else runnable).append((it, why))
    log(out, "plan: run " + (", ".join(i for i, _ in runnable) or "nothing") +
        ("; skip " + "; ".join(f"{i} ({w})" for i, w in skipped) if skipped else ""))
    m = Mister(a.host, a.password, dry=not a.go)
    results = {i: ("SKIP", w) for i, w in skipped}

    locked = False
    try:
        if a.go:
            held = take_lock(m, a.lock_wait, lambda msg: log(out, msg), a.lock_poll)
            if not held.startswith("got"):
                raise SystemExit(f"the MiSTer is locked by another run ({held}); not touching it")
            locked = True
            busy = m.sh("ls /dev/MiSTer_cmd >/dev/null 2>&1 && echo ok", check=False).strip()
            if busy != "ok":
                raise SystemExit("/dev/MiSTer_cmd missing: is Main_MiSTer running?")
        # a fresh card has none of these (the screenshots directory appears with the first
        # screenshot and is listed tolerantly everywhere)
        m.sh(f"mkdir -p {REMOTE_TMP} {GAMES} /media/fat/_Computer")
        for f in ("ztype.py", "zclick.py"):
            m.put(ROOT / "tools/mister" / f, f"{REMOTE_TMP}/{f}")
        for f in ("fatimg.py", "integ_manifest.py"):
            m.put(ROOT / "tools/hwprobe/integ" / f, f"{REMOTE_TMP}/{f}")
        m.put(a.rbf, REMOTE_RBF)
        m.put(patched, f"{GAMES}/{TAG}-hdd.base")
        if a.fdd0:
            m.put(a.fdd0, f"{GAMES}/{TAG}-fdd0.base")
        if a.fdd1:
            m.put(a.fdd1, f"{GAMES}/{TAG}-fdd1.base")
        if a.cd:
            m.put(a.cd, f"{GAMES}/{TAG}-cd.img")
        for it, _ in runnable:
            try:
                results[it] = run_item(m, it, a, sc, prep, out)
            except Exception as e:                       # one item's failure must not skip the cleanup
                results[it] = ("FAIL", f"runner error: {e}")
            log(out, f"{it}: {results[it][0]} - {results[it][1]}")
    finally:
        # Only the holder of the lock cleans up: a run refused by another run's lock must not
        # remove that run's files (the namespace is shared) or kill its UART reader.
        if a.go and locked and not a.keep:
            leftovers = cleanup(m, out)
            if leftovers:
                results["cleanup"] = ("FAIL", "left on the MiSTer: " + ", ".join(leftovers))
        if a.go and locked and not a.keep:
            m.sh(f"rm -rf {LOCK}", check=False)
        if not a.go:
            (out / "plan.txt").write_text("\n".join(f"{k}: {v}" for k, v in m.plan) + "\n")
            print(f"\ndry run: {len(m.plan)} remote actions listed in {out / 'plan.txt'}; nothing was touched (add --go)")
    (out / "results.json").write_text(json.dumps(results, indent=1))
    print("\n== mister_regress ==")
    for k, (v, d) in results.items():
        print(f"{v:10s} {k:12s} {d}")
    bad = [k for k, (v, _) in results.items() if v == "FAIL"]
    return 1 if bad else 0


def cleanup(m: Mister, out: Path):
    """Remove everything the run created and VERIFY it is gone. Returns what is still there."""
    log(out, "cleanup")
    stop_uart(m)
    paths = sorted(set(m.created))
    for p in paths:
        # a test-named file, or one of this run's own screenshots (directly in SHOTS, named by
        # own_shot's pattern with a stem this run loaded); nothing else is ever removed
        assert TAG in Path(p).name.lower() or p.startswith(REMOTE_TMP + "/") or (
            str(Path(p).parent) == SHOTS and own_shot(Path(p).name, m.shot_stems, "")), p
    # the run's own screenshots are listed by name in m.created; the test files carry the tag
    m.sh("rm -f " + " ".join(shlex.quote(p) for p in paths) + f" {REMOTE_MGL}", check=False)
    m.sh(f"rm -rf {REMOTE_TMP}", check=False)
    left = []
    for p in paths + [REMOTE_MGL, REMOTE_TMP]:
        if m.sh(f"test -e {shlex.quote(p)} && echo there", check=False).strip():
            left.append(p)
    return left


# ---------------------------------------------------------------------------------------------
def selftest() -> int:
    from PIL import Image, ImageDraw
    rc = 0

    def check(c, what):
        nonlocal rc
        print(("ok:   " if c else "FAIL: ") + what)
        rc |= 0 if c else 1

    with tempfile.TemporaryDirectory() as d:
        d = Path(d)

        def shot(i, kind):
            im = Image.new("RGB", (640, 400), (10, 10, 10))
            dr = ImageDraw.Draw(im)
            if kind == "moving":
                dr.rectangle([i * 17 % 600, 50, i * 17 % 600 + 30, 90], fill=(255, 255, 255))
            elif kind == "logo":
                dr.rectangle([100, 100, 540, 300], fill=(200, 30, 30))
            p = d / f"2026{i:04d}.png"
            im.save(p)
            return p

        moving = [shot(i, "moving") for i in range(12)]
        ok, msg = check_motion(moving, 60, 15, 3)
        check(ok, f"a moving sequence is not frozen ({msg})")
        frozen = [shot(100, "frozen")] * 12
        ok, msg = check_motion(frozen, 60, 15, 3)
        check(not ok, f"an identical-shot sequence IS frozen ({msg})")
        stall = moving[:4] + [moving[3]] * 8
        ok, msg = check_motion(stall, 60, 15, 3)
        check(not ok, f"a stall after motion is caught ({msg})")
        ok, msg = check_motion(stall, 150, 15, 3)
        check(ok, "the same stall passes with a longer allowance (the limit is per scenario)")
        blk = Image.new("RGB", (640, 400), (0, 0, 0))
        blk.save(d / "blk.png")
        check(not check_content([d / "blk.png"] * 12)[0], "an all-black sequence fails the content check")
        check(check_content([d / "blk.png", moving[0]])[0] and check_content(moving)[0],
              "a sequence with content passes the content check")
        flat = Image.new("RGB", (64, 40), (90, 90, 90))
        flat.save(d / "flat.png")
        check(is_black(frame_stats(d / "flat.png")), "a single-colour frame counts as blank")
        pal = Image.new("P", (16, 16)); pal.putpalette([0, 0, 0, 200, 0, 0] + [0] * 750); pal.putpixel((3, 3), 1)
        pal.save(d / "pal.png")
        check(frame_stats(d / "pal.png")[1] == 200, "a palette PNG decodes")
        ref = shot(200, "logo")
        ok, msg = check_known_frame(moving + [ref], ref, 12.0, 15)
        check(ok, f"the known frame is found among the shots ({msg})")
        ok, msg = check_known_frame(moving, ref, 12.0, 15)
        check(not ok, f"a sequence without it is rejected ({msg})")

        good = "INTEG BEGIN V1\r\nFILE C:\\A SIZE=1 CRC=1 WANT=1 BADBLK=00000000 OK\r\nINTEG END FAILS=0000\r\n"
        bad = ("INTEG BEGIN V1\r\nBAD  C:\\A OFF=00004200 BLK=00000021 GOT=1 WANT=2 DATA=00\r\n"
               "FILE C:\\A SIZE=1 CRC=1 WANT=1 BADBLK=00000001 FAIL\r\nINTEG END FAILS=0001\r\n")
        names = ["INTEG_C.TXT", "INTEG_WC.TXT"]
        caps = {"INTEG_C.TXT": good, "INTEG_WC.TXT": good, "INTEG_OK.TXT": "done"}
        check(judge_probe(caps, names, False)[0], "judge: clean captures pass")
        caps2 = dict(caps, **{"INTEG_C.TXT": bad})
        ok, msg = judge_probe(caps2, names, False)
        check(not ok and "OFF=00004200" in msg, f"judge: a BAD row fails the run and names the offset ({msg})")
        check(not judge_probe(dict(caps, **{"INTEG_OK.TXT": None}), names, False)[0], "judge: a run with no INTEG_OK.TXT fails")
        check(not judge_probe(dict(caps, **{"INTEG_WC.TXT": "INTEG BEGIN V1\r\n"}), names, False)[0], "judge: a capture with no END row (probe died) fails")
        capsp = dict(caps, **{"INTEG_P.TXT": "PLAY NOMSCDEX\r\n"})
        check(not judge_probe(capsp, names, True)[0], "judge: CD-DA that never played fails the cda item")
        capsp = dict(caps, **{"INTEG_P.TXT": "PLAY OK DRV=04 TRACK=02 START=00051000 SECTORS=00000100\r\nINTEG END FAILS=0000\r\n"})
        check(judge_probe(capsp, names, True)[0], "judge: CD-DA playing passes")


        # ---- an HDI container: recognised by content, and patching/reading skips its header
        raw = d / "raw.img"
        payload = bytes((i * 3 + 7) & 0xFF for i in range(512 * 17 * 2 * 1))
        raw.write_bytes(payload)
        check(container_skip(raw) == 0, "container: a raw image with no header has no skip")
        hdr = bytearray(4096)
        struct.pack_into("<8I", hdr, 0, 0, 0, 4096, len(payload), 512, 17, 2, 1)
        hdi = d / "good.hdi"
        hdi.write_bytes(bytes(hdr) + payload)
        check(container_skip(hdi) == 4096, "container: a valid HDI reports its HeaderSize")
        bad = bytearray(hdr)
        struct.pack_into("<I", bad, 0, 1)
        (d / "rsv.hdi").write_bytes(bytes(bad) + payload)
        check(container_skip(d / "rsv.hdi") == 0, "container: reserved != 0 falls back to raw")
        bad = bytearray(hdr)
        struct.pack_into("<I", bad, 8, 4097)
        (d / "odd.hdi").write_bytes(bytes(bad) + payload)
        check(container_skip(d / "odd.hdi") == 0, "container: a HeaderSize that is not whole sectors falls back")
        bad = bytearray(hdr)
        struct.pack_into("<I", bad, 12, len(payload) + 512)
        (d / "size.hdi").write_bytes(bytes(bad) + payload)
        check(container_skip(d / "size.hdi") == 4096, "container: a DataSize that disagrees is still an HDI (NP2kai)")
        bad = bytearray(hdr)
        struct.pack_into("<I", bad, 28, 2)
        (d / "geom.hdi").write_bytes(bytes(bad) + payload)
        check(container_skip(d / "geom.hdi") == 4096, "container: a geometry that disagrees with DataSize is still an HDI (NP2kai)")
        bad = bytearray(hdr)
        struct.pack_into("<I", bad, 24, 0)
        (d / "heads0.hdi").write_bytes(bytes(bad) + payload)
        check(container_skip(d / "heads0.hdi") == 0, "container: a zero geometry field falls back")
        # ---- cpusuite: the result file's parse and verdict
        ok_txt = ("CPUSUITE BEGIN V1 PROGRAMS=2 PASSES=1\r\naaa PASS\r\nbbb PASS triple fault\r\n"
                  "CPUSUITE END PASSES=1 RUN=2 PASS=2 FAIL=0\r\n")
        check(judge_cpusuite(ok_txt, ["aaa", "bbb"], 1)[0], "cpusuite: every program PASS and the END row passes")
        bad_txt = ok_txt.replace("bbb PASS triple fault", "bbb FAIL verdict=FF").replace("PASS=2 FAIL=0", "PASS=1 FAIL=1")
        ok, msg = judge_cpusuite(bad_txt, ["aaa", "bbb"], 1)
        check(not ok and "bbb (verdict=FF)" in msg, f"cpusuite: a FAIL row fails the item and names it ({msg})")
        hang = "CPUSUITE BEGIN V1 PROGRAMS=2 PASSES=1\r\naaa PASS\r\nbbb "
        ok, msg = judge_cpusuite(hang, ["aaa", "bbb"], 1)
        check(not ok and "stopped in bbb" in msg, f"cpusuite: a run that hangs names the program it hung in ({msg})")
        short = ok_txt.replace("RUN=2", "RUN=1")
        check(not judge_cpusuite(short, ["aaa", "bbb"], 1)[0], "cpusuite: an END row with too few programs fails")
        check(not judge_cpusuite(ok_txt, ["aaa", "bbb", "ccc"], 1)[0], "cpusuite: a program of the pack with no row fails")
        two = ("CPUSUITE BEGIN V1 PROGRAMS=1 PASSES=2\r\naaa PASS\r\naaa PASS\r\nCPUSUITE END PASSES=2 RUN=2 PASS=2 FAIL=0\r\n")
        check(judge_cpusuite(two, ["aaa"], 2)[0] and not judge_cpusuite(two, ["aaa"], 3)[0], "cpusuite: passes are counted")
        check(not judge_cpusuite(None, ["aaa"], 1)[0], "cpusuite: no result file fails")
        check("cpusuite" in DEFAULT_ITEMS, "cpusuite: in the default set")
        # ---- crt31k: the capture itself passes; the core before the 31 kHz clock fails
        cap = (ROOT / "docs/probes/CRT31K.TXT").read_text()
        ok, msg = judge_crt31k(cap)
        check(ok, f"crt31k: the Xe10's own capture passes ({msg})")
        old = cap.replace("ticks=306930", "ticks=366433")      # 31K rows at the 21.05 MHz clock
        check(not judge_crt31k(old)[0], "crt31k: a 31 kHz run at the 24 kHz dot clock fails")
        check(not judge_crt31k(cap.replace("END:CRT31K", ""))[0], "crt31k: an unfinished run fails")
        check(not judge_crt31k(cap.replace("now=00", "now=01"))[0], "crt31k: an unrestored 0x09A8 fails")
        check("crt31k" not in DEFAULT_ITEMS, "crt31k: not in the default set")

        cs = b"DEVICE=X\r\nREM DEFAULT3\r\nREM WAIT5\r\n"
        check(set_default_profile(cs, 0) == b"DEVICE=X\r\nREM DEFAULT0\r\nREM WAIT5\r\n", "config: DEFAULTn rewritten, CRLF and every other byte kept")
        try:
            set_default_profile(b"nothing\r\n", 0)
            check(False, "config: a CONFIG.SYS without the line is refused")
        except SystemExit:
            check(True, "config: a CONFIG.SYS without the line is refused")
        sc = {"doom": {"steps": [["type", "?"]]}, "th05": {"steps": [["type", "th5\n"]]}}
        check(item_needs("doom", sc) is not None, "scenario: a '?' placeholder is a SKIP, not a pass")
        check(item_needs("th05", sc) is None and item_needs("rusty", sc) is not None, "scenario: filled items run, absent ones skip")

        # ---- the image patching: put the probe's files in a COPY of a synthetic volume, read back
        if shutil.which("mformat"):
            img = d / "disk.img"
            subprocess.run(["mformat", "-C", "-i", str(img), "-t", "400", "-h", "4", "-s", "32", "::"], check=True, capture_output=True)
            src = d / "game.bin"
            src.write_bytes(os.urandom(70_000))
            subprocess.run(["mcopy", "-i", str(img), str(src), "::GAME.BIN"], check=True, capture_output=True)
            orig = img.read_bytes()
            man = {"C:": manifest_for(img, "C:", "fat", {"largest": 4, "max_bytes": 1 << 20, "under": None, "partition": None})}
            files = probe_files(man)
            cp = d / "copy.img"
            patch_hdd(img, cp, files, None, None, 0)
            check(img.read_bytes() == orig, "patch: the ORIGINAL image is byte-identical after patching")
            with open(cp, "rb") as f:
                fs = fatimg.Fat(f, 0)
                got = {n: fs.cat(n) for n in files}
            check(got == files, "patch: every probe file reads back from the copy")
            fsck = shutil.which("fsck.fat")
            if fsck:
                check(subprocess.run([fsck, "-n", str(cp)], capture_output=True).returncode == 0, "patch: fsck.fat accepts the patched copy")
            check("F 00011170" in man["C:"] and "C:\\GAME.BIN" in man["C:"], "manifest: the file, its size and drive")

        # ---- the plan: dry run touches nothing and stays in the test namespace
        m = Mister("nowhere", "x", dry=True)
        mgl = mgl_text("zreg-hdd.img", "zreg-fdd0.img", None, "zreg-cd.img")
        check('index="0" path="zreg-hdd.img"' in mgl and 'index="4" path="zreg-cd.img"' in mgl and 'index="1"' in mgl,
              "mgl: HDD slot 0, FDD0 slot 1, CD slot 4, pack last")
        check(mgl.rstrip().endswith("</mistergamedescription>") and mgl.index('type="f"') > mgl.index('index="4"'), "mgl: the pack entry is last (images mount before the CPU runs)")
        try:
            m.put("x", "/media/fat/_Computer/PC9821Z486.rbf")
            check(False, "put: refuses a path outside the test namespace")
        except AssertionError:
            check(True, "put: refuses a path outside the test namespace (a real, non-test RBF)")
        m.put("x", REMOTE_RBF)
        check(all(TAG in r.lower() for _, r in [(k, v.split("-> ")[-1]) for k, v in m.plan if k == "scp-put"]), "plan: every uploaded name carries the test tag")
        # cleanup must list exactly what was created
        m2 = Mister("nowhere", "x", dry=True)
        m2.put("x", REMOTE_RBF)
        m2.created.append(f"{GAMES}/{TAG}-hdd.img")
        cleanup(m2, Path(tempfile.mkdtemp()))
        rm = [v for k, v in m2.plan if k == "ssh" and v.startswith("rm -f")][0]
        check(REMOTE_RBF in rm and f"{GAMES}/{TAG}-hdd.img" in rm and REMOTE_MGL in rm, "cleanup: removes the RBF, the image copy and the MGL")
        check(not any("pidof" in v or ("kill" in v and "/proc/" not in v) for k, v in m2.plan if k == "ssh"),
              "cleanup: kills no ttyS1 reader it did not start (no pidof sweep)")
        m2.uart_pids = [4242]
        stop_uart(m2)
        kills = [v for k, v in m2.plan if k == "ssh" and "kill" in v]
        check(len(kills) == 1 and "kill 4242" in kills[0] and "/proc/4242/comm" in kills[0] and m2.uart_pids == []
              and "pidof" not in kills[0],
              "uart: only the recorded reader PID is killed, after checking it is still a cat on ttyS1")
        m3 = Mister("nowhere", "x", dry=True)
        m3.shot_stems = {"pc98pack-xe10"}
        m3.created.append(f"{SHOTS}/20261031_023224-OtherCore.png")
        try:
            cleanup(m3, Path(tempfile.mkdtemp()))
            check(False, "cleanup: refuses to remove a screenshot that is not this run's")
        except AssertionError:
            check(True, "cleanup: refuses to remove a screenshot that is not this run's")
        m3.created = [f"{SHOTS}/20261031_023224-pc98pack-xe10.png"]
        cleanup(m3, Path(tempfile.mkdtemp()))
        check(any(f"{SHOTS}/20261031_023224-pc98pack-xe10.png" in v for k, v in m3.plan if v.startswith("rm -f")),
              "cleanup: removes this run's own screenshot")

        # ---- only this run's screenshots are fetched and deleted
        an = argparse.Namespace(pack="pc98pack-xe10.bin", partition=None)
        st = shot_stems(an)
        check(own_shot("20261031_023224-pc98pack-xe10.png", st, "20261031_023200"),
              "shots: a new shot named after the pack this run loaded, after the item began, is the run's")
        check(not own_shot("20261031_023124-pc98pack-xe10.png", st, "20261031_023200"),
              "shots: a shot stamped before the item began is not the run's")
        check(not own_shot("20261031_023224-SomeImage.png", st, "20261031_023200")
              and not own_shot("20261031_023224-pc98pack-xe10.png.bak", st, "")
              and not own_shot("notes.txt", st, ""),
              "shots: another core's or another file's screenshot is never the run's")

        class ListingMister(Mister):
            """A card whose SHOTS listing is fixed; fetches are recorded, nothing is run."""
            def __init__(self, listing):
                super().__init__("nowhere", "x", dry=True)
                self.listing = listing

            def sh(self, cmd, check=True, timeout=600):
                self.plan.append(("ssh", cmd))
                return " ".join(self.listing) if cmd.startswith(f"ls {SHOTS}") else ""

        lm = ListingMister(["20261031_020000-pc98pack-xe10.png", "20261031_023224-pc98pack-xe10.png",
                            "20261031_023225-SomeGame.png", "20261031_023226-pc98pack-xe10.png"])
        got = collect_shots(lm, an, {"20261031_020000-pc98pack-xe10.png"}, "20261031_023200", d)
        check([p.name for p in got] == ["20261031_023224-pc98pack-xe10.png", "20261031_023226-pc98pack-xe10.png"]
              and lm.created == [f"{SHOTS}/{p.name}" for p in got],
              "shots: only the run's own new screenshots are fetched and marked for removal")

        # ---- B1: every capture read-back of an HDI image skips its header (cpusuite included)
        for item in ("probe", "crt31k", "cpusuite"):
            mi = Mister("nowhere", "x", dry=True)
            ai = argparse.Namespace(partition=None, pack="pc98pack-xe10.bin", uart=False, boot_wait=0,
                                    cpusuite_passes=1, cpusuite_timeout=1, probe_timeout=1, cd=None,
                                    cd_drive="E:")
            prep_i = {"skip": 4096, "config_sys": b"REM DEFAULT3\r\n", "cpusuite": ["aaa"],
                      "manifests": {"C:": "x"}}
            run_item(mi, item, ai, {}, prep_i, d)
            cats = [v for k, v in mi.plan if k == "ssh" and "integ_manifest.py" in v and "--cat" in v]
            check(cats and all("--skip 4096 " in v for v in cats),
                  f"{item}: every capture read of an HDI image copy passes --skip 4096 ({len(cats)} reads)")
            ai.partition = 1
            check("--partition 1 --skip 4096 --cat X" in cat_cmd(ai, 4096, "X") and "--skip" not in cat_cmd(ai, 0, "X"),
                  f"{item}: cat_cmd carries --partition and --skip only when set")

        # ---- dense shots and the known-frame window
        sc_fz = {"shot_every": 3, "run": 30, "dense": [{"from_s": 4, "to_s": 10, "every_s": 1}]}
        sched = shot_schedule(sc_fz)
        check(sched == [3, 4, 5, 6, 7, 8, 9, 10, 12, 15, 18, 21, 24, 27, 30],
              f"schedule: every 3 s, every 1 s inside the dense window ({sched})")
        check(shot_schedule({"shot_every": 10, "run": 30}) == [10, 20, 30], "schedule: no dense window, the old grid")
        check(shot_times([d / "20261031_023230-p.png", d / "20261031_023301-p.png"], "20261031_023224", [3, 6]) == [6.0, 37.0],
              "shot times come from the card's stamps, not the request order")
        check(shot_times([d / "x.png"], "", [3, 6]) == [3], "shot times fall back to the schedule without stamps")
        # a transient frame present only between the 3 s grid points (the launch ran 1.5 s early)
        ref2 = shot(300, "logo")
        seq = [shot(400 + i, "moving") for i in range(len(sched))]
        seq_times = list(sched)
        seq[sched.index(7)] = ref2
        grid_only = [p for p, t in zip(seq, seq_times) if t % 3 == 0]
        grid_t = [t for t in seq_times if t % 3 == 0]
        check(not check_known_frame(grid_only, ref2, 5.0, 3, 4, 20, grid_t)[0],
              "known frame: a transient frame between 3 s shots is missed by the grid alone")
        ok, msg = check_known_frame(seq, ref2, 5.0, 3, 4, 20, seq_times)
        check(ok, f"known frame: the dense window catches it on ANY shot in the window ({msg})")
        check(not check_known_frame(seq, ref2, 5.0, 3, 8, 20, seq_times)[0],
              "known frame: a match outside [not_before_s, until_s] does not count")
        frozen2 = [seq[0]] * len(seq)
        check(not check_known_frame(frozen2, ref2, 5.0, 3, 4, 20, seq_times)[0] and
              not check_motion(frozen2, 6, 3, 3, seq_times)[0],
              "known frame: a frozen intro fails both the frame and the motion check")
        check(not check_known_frame([d / "blk.png"] * len(seq), ref2, 5.0, 3, 4, 20, seq_times)[0],
              "known frame: a black intro fails")
        stall_t = [0, 1, 2, 3, 4, 5, 6, 30]
        check(check_motion([seq[0]] * 7 + [seq[1]], 6, 3, 1, stall_t)[0] and
              not check_motion([seq[0]] * 8, 6, 3, 1, stall_t)[0],
              "motion: a static run is measured in the shots' real seconds, dense shots included")

    check(host_slug("root@my-card.lan") == "my-card.lan" and host_slug("a b") == "a_b",
          "host_slug: the user@ prefix is dropped and unsafe characters replaced")
    t0 = time.time()
    got = take_lock(Mister("nowhere", "x", dry=True), 0, lambda msg: None)
    check(not got.startswith("got") and time.time() - t0 < 5, "lock: wait 0 on a lock that is not granted returns at once")
    print("PASS" if rc == 0 else "FAIL")
    return rc


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Load a core over and over on a MiSTer and check that every load can still take a screenshot.

The "scaler wedge" (docs/mister-testing.md, Screenshots) is a card state in which `echo screenshot >
/dev/MiSTer_cmd` writes nothing, for any core including Menu, until the card is rebooted. This tool
counts loads-to-wedge per build: it deploys one or more RBFs under zreg names, loads them in
interleaved blocks through their own MGLs, waits, asks for a screenshot and checks that a new file
appeared. On a wedge it collects what the card can tell (Main_MiSTer's scaler header at the
physical address scaler.cpp maps, dmesg, Main's own log with --debug-log, Main's threads, a
frame from a local HDMI capture device) and, with --reboot-on-wedge, reboots the card, proves a
Menu screenshot works again and carries on.

  python3 tools/mister_load_loop.py --host root@MiSTer \\
      --build A=path/a.rbf --build B=path/b.rbf --loads 40 --block 5 --wait 25 \\
      --hdd-from /media/fat/games/PC9821/<your-image>.img --reboot-on-wedge \\
      --capture-dev /dev/video0 --go

Without --go it prints the plan and touches nothing. With --go it takes the card's zreg lock
(the same /tmp/zreg.lock tools/mister_regress.py uses), uses only names containing "zreg", and in a
finally removes every file it created, loads --final-mgl and releases the lock. Each screenshot it
caused is fetched into --out and deleted on the card right away; a screenshot is the run's only when
it is new, stamped at or after the request, and named after what the run loaded
(<stamp>-<pack>.png for a zreg build, <stamp>-screen.png for Menu). --reboot-on-wedge reboots the
card: use it only on a card you may reboot.

MiSTer.ini is never changed (docs/mister-testing.md, rules). --debug-log only collects Main's
/tmp/debug.txt, which exists when the card's owner has set debug=2; without it there is no log.

Output (--out, default .build/mister-load-loop/<time>): log.txt, loads.csv (one row per load),
summary.txt (per build: loads, wedges, black loads, loads-to-wedge), wedge-NN/ (the characterisation),
shots/.

Each core load is classified: wedge (no screenshot file), black (a file whose frame has no content:
brightest pixel <= 8, or one flat colour - the core never put video on the scaler) or ok. Any black
load fails that build (summary line BLACK-FAIL, exit status 1): a just-loaded core shows the BIOS
boot screen well inside --wait, so a healthy build is never black at the screenshot. loads.csv's
`result` is ok/wedge/black; the columns `pmax` and `pmean` (frame statistics) are appended.
Menu-core screenshots are not classified (a Menu frame may legitimately be dark).
"""
import argparse
import csv
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from mister_regress import (CORE, GAMES, LOCK, MENU, SETNAME, SHOT_TS, TAG, Mister,  # noqa: E402
                            frame_stats, is_black, own_shot, take_lock)

SHOT_ROOT = "/media/fat/screenshots"
INI_BAK = f"/media/fat/MiSTer.ini.{TAG}-bak"  # left by an earlier version's --debug-log: reported, never touched
DBG = "/tmp/debug.txt"                       # Main_MiSTer cfg.cpp: debug=2 writes stdout here ("w")
DBG_KEEP = f"/media/fat/{TAG}-dbg"           # rotated copies survive Main's restart on each load
SCALER_BASE = 0x20000000                     # Main_MiSTer scaler.h MISTER_SCALER_BASEADDR


def remote_rbf(label):
    return f"/media/fat/_Computer/{CORE}-{TAG}{label}.rbf"


def remote_mgl(label):
    return f"/media/fat/{TAG.upper()}{label}.mgl"


def remote_hdd():
    return f"{GAMES}/{TAG}-loop-hdd.img"


def mgl_text(label, hdd=None, pack="pc98pack-xe10.bin"):
    lines = ["<mistergamedescription>", f"\t<rbf>_Computer/{CORE}-{TAG}{label}</rbf>",
             f"\t<setname>{SETNAME}</setname>"]
    if hdd:
        lines.append(f'\t<file delay="1" type="s" index="0" path="{hdd}"/>')
    lines.append(f'\t<file delay="1" type="f" index="0" path="{pack}"/>')
    lines.append("</mistergamedescription>")
    return "\n".join(lines) + "\n"


def parse_build(spec):
    """LABEL=PATH -> (label, Path). A label is short and alphanumeric (it becomes part of a name).
    PATH `menu` is the card's own Menu core and `card:/media/fat/_Computer/X.rbf` (or .mgl) a core already
    on the card: nothing is deployed for either, they are controls that contain no core of ours."""
    if "=" not in spec:
        raise argparse.ArgumentTypeError(f"--build wants LABEL=PATH, got {spec!r}")
    label, path = spec.split("=", 1)
    if not re.fullmatch(r"[A-Za-z0-9]{1,8}", label):
        raise argparse.ArgumentTypeError(f"label {label!r}: 1-8 letters/digits")
    if path.lower() == "menu":
        return label, MENU_BUILD
    if path.startswith("card:"):
        return label, path            # a core already on the card (e.g. a stock core), loaded as is
    return label, Path(path)


MENU_BUILD = "menu"


def on_card(path):
    return path == MENU_BUILD or (isinstance(path, str) and path.startswith("card:"))


def load_target(label, builds):
    p = builds[label]
    if p == MENU_BUILD:
        return MENU
    if on_card(p):
        return p[len("card:"):]
    return remote_mgl(label)


def schedule(labels, loads, block):
    """Interleaved blocks: block loads of each label in turn until each label has `loads`."""
    left = {lb: loads for lb in labels}
    seq = []
    while any(left.values()):
        for lb in labels:
            n = min(block, left[lb])
            seq += [lb] * n
            left[lb] -= n
    return seq


def parse_header(words):
    """Four devmem 32-bit reads (little-endian) of the scaler header -> (bytes, dict)."""
    b = b"".join(int(w, 16).to_bytes(4, "little") for w in words)
    # scaler.cpp: magic buffer[0]==1 && buffer[1]==1, then header/width/height/line/output size
    info = {"magic_ok": b[0] == 1 and b[1] == 1, "header": b[2] << 8 | b[3],
            "width": b[6] << 8 | b[7], "height": b[8] << 8 | b[9], "line": b[10] << 8 | b[11],
            "out_w": b[12] << 8 | b[13], "out_h": b[14] << 8 | b[15]}
    return b, info


def new_files(before, after):
    return sorted(set(after) - set(before))


# Main_MiSTer names a screenshot <YYYYMMDD_HHMMSS>-<stem>.png in screenshots/<core>/: the stem is
# the last file loaded through the core's ROM loader (this tool's MGLs load the pack last: every
# capture so far is `-pc98pack-xe10.png`), and `screen` when none was (every Menu capture so far).
MENU_STEMS = {"screen"}


def load_stems(label, builds, pack):
    """The stems a screenshot of this load may carry; None (any stem, the stamp still bounds it)
    for a core already on the card, whose naming this tool does not know."""
    p = builds[label]
    if p == MENU_BUILD:
        return MENU_STEMS
    if on_card(p):
        return None
    return {Path(pack).stem, f"{CORE}-{TAG}{label}", "screen"}


def own_shot_path(path, stems, since):
    """A screenshot this run caused: SHOT_ROOT/<core dir>/<own_shot name>."""
    pp = Path(path)
    return str(pp.parent.parent) == SHOT_ROOT and own_shot(pp.name, stems, since)


def summarize(rows, labels):
    """Per label: loads, wedges and the loads-to-wedge counts (loads of that label since the last
    reboot/start, and loads of any label since the last reboot/start, at each wedge)."""
    out = {lb: {"loads": 0, "wedges": 0, "black": 0, "to_wedge_own": [], "to_wedge_any": []} for lb in labels}
    own = {lb: 0 for lb in labels}
    anyc = 0
    for r in rows:
        lb = r["label"]
        if lb not in out:
            continue
        out[lb]["loads"] += 1
        out[lb]["black"] += r["result"] == "black"
        own[lb] += 1
        anyc += 1
        if r["result"] == "wedge":
            out[lb]["wedges"] += 1
            out[lb]["to_wedge_own"].append(own[lb])
            out[lb]["to_wedge_any"].append(anyc)
            own = {k: 0 for k in own}
            anyc = 0
    return out


def classify(paths):
    """Local screenshot files of one core load -> (result, pmax, pmean). No file: wedge. A file is black
    when every decodable frame is; an undecodable file counts ok (it is not evidence of black)."""
    if not paths:
        return "wedge", "", ""
    st = [frame_stats(p) for p in paths]
    known = [x for x in st if x is not None]
    pmax = max((x[1] for x in known), default="")
    pmean = f"{max(x[2] for x in known):.2f}" if known else ""
    return ("black" if known and all(is_black(x) for x in known) else "ok"), pmax, pmean


def black_failures(s):
    return {lb: d["black"] for lb, d in s.items() if d["black"]}


def summary_text(rows, labels, builds):
    s = summarize(rows, labels)
    lines = []
    for lb in labels:
        d = s[lb]
        lines.append(f"{lb}: {builds.get(lb, '')}")
        lines.append(f"  loads={d['loads']} wedges={d['wedges']} black={d['black']} "
                     f"loads-to-wedge (this build since reboot)={d['to_wedge_own']} "
                     f"(any build since reboot)={d['to_wedge_any']}")
        if d["black"]:
            lines.append(f"  BLACK-FAIL: {d['black']} of {d['loads']} loads produced a frame with no content")
    return "\n".join(lines) + "\n"


class Loop:
    def __init__(self, a, m: Mister, out: Path):
        self.a, self.m, self.out = a, m, out
        self.rows = []
        self.created_shots = []
        self.wedges = 0
        self.load_no = 0

    def log(self, msg):
        line = f"[{time.strftime('%H:%M:%S')}] {msg}"
        print(line, flush=True)
        with open(self.out / "log.txt", "a") as f:
            f.write(line + "\n")

    def shots(self):
        return [p for p in self.m.sh(f"find {SHOT_ROOT} -type f 2>/dev/null", check=False).split("\n") if p]

    def try_shot(self, timeout, stems=None):
        """Ask for a screenshot; return the new file paths this request caused (own_shot_path:
        stamped at or after the request, named after `stems`; empty: none within timeout)."""
        since = self.m.sh(f"date +{SHOT_TS}", check=False).strip()
        before = self.shots()
        self.m.sh("echo screenshot > /dev/MiSTer_cmd")
        t0 = time.time()
        while time.time() - t0 < timeout:
            time.sleep(1)
            got = [p for p in new_files(before, self.shots()) if own_shot_path(p, stems, since)]
            if got:
                time.sleep(1)      # Main_MiSTer writes the PNG asynchronously; let it finish
                return got
        return []

    def keep_shots(self, paths, tag):
        d = self.out / "shots"
        d.mkdir(exist_ok=True)
        local = []
        for p in paths:
            assert own_shot_path(p, None, ""), p
            self.created_shots.append(p)
            try:
                self.m.get(p, d / f"{tag}-{Path(p).name}")
                local.append(d / f"{tag}-{Path(p).name}")
            except subprocess.CalledProcessError:
                self.log(f"could not fetch {p}")
            self.m.sh(f"rm -f {shlex.quote(p)}", check=False)
        return local

    def main_cmdline(self):
        return self.m.sh("p=$(pidof MiSTer); [ -n \"$p\" ] && tr '\\0' ' ' < /proc/$p/cmdline", check=False).strip()

    def header(self):
        words = self.m.sh(" ; ".join(f"devmem {SCALER_BASE + 4 * i:#x} 32" for i in range(4)), check=False).split()
        try:
            return parse_header(words)
        except (ValueError, IndexError):
            return b"", {"raw": words}

    def rotate_dbg(self):
        """Keep the last two loads' /tmp/debug.txt (Main_MiSTer writes it only when the card's own
        MiSTer.ini has debug=2; this tool never changes MiSTer.ini)."""
        if self.a.debug_log:
            self.m.sh(f"mkdir -p {DBG_KEEP}; mv -f {DBG_KEEP}/prev1.txt {DBG_KEEP}/prev2.txt 2>/dev/null; "
                      f"cp -f {DBG} {DBG_KEEP}/prev1.txt 2>/dev/null; true", check=False)

    def grab(self, path):
        dev = self.a.capture_dev
        if not dev or self.m.dry:
            return "no capture device"
        busy = subprocess.run(["fuser", dev], capture_output=True, text=True)
        if busy.stdout.strip():
            return f"{dev} busy ({busy.stdout.strip()}), not grabbed"
        r = subprocess.run(["timeout", "25", "ffmpeg", "-loglevel", "error", "-f", "v4l2", "-i", dev,
                            "-vf", r"select=gte(n\,45)", "-frames:v", "1", "-y", str(path)],
                           capture_output=True, text=True)
        return f"grab rc={r.returncode} {r.stderr.strip()[:200]}"

    def menu_check(self, tag, wait=12):
        self.m.sh(f"echo 'load_core {MENU}' > /dev/MiSTer_cmd")
        time.sleep(wait)
        got = self.try_shot(self.a.shot_timeout, MENU_STEMS)
        self.keep_shots(got, tag)
        return bool(got)

    def characterise(self, n, label):
        d = self.out / f"wedge-{n:02d}"
        d.mkdir(exist_ok=True)
        m = self.m
        hb, hinfo = self.header()
        rep = [f"load {self.load_no} build {label} at {time.ctime()}",
               f"scaler header bytes: {hb.hex(' ')}", f"scaler header: {hinfo}",
               f"Main cmdline: {self.main_cmdline()}",
               "uptime: " + m.sh("uptime", check=False).strip()]
        # read-only: the HPS SDRAM controller's FPGA-port configuration and port-reset registers
        # (Cyclone V HPS TRM sdr.ctrlgrp: portcfg 0x7C, fpgaportrst 0x80 at 0xFFC25000) - the
        # f2sdram ports the scaler's frame buffer is written through
        rep.append("sdr ctrlgrp portcfg/fpgaportrst: " + m.sh(
            "devmem 0xFFC2507C 32; devmem 0xFFC25080 32", check=False).replace("\n", " "))
        rep.append("threads:\n" + m.sh(
            "p=$(pidof MiSTer); for t in /proc/$p/task/*; do echo \"$t $(cat $t/comm) "
            "$(cut -d' ' -f3 $t/stat) wchan=$(cat $t/wchan)\"; done", check=False))
        (d / "dmesg.txt").write_text(m.sh("dmesg | tail -80", check=False))
        (d / "free.txt").write_text(m.sh("free; cat /proc/loadavg; ps", check=False))
        if self.a.debug_log:
            for src, dst in ((DBG, "debug-now.txt"), (f"{DBG_KEEP}/prev1.txt", "debug-prev1.txt"),
                             (f"{DBG_KEEP}/prev2.txt", "debug-prev2.txt")):
                (d / dst).write_text(m.sh(f"cat {src} 2>/dev/null", check=False))
        rep.append("capture (wedged core): " + self.grab(d / "hdmi-core.png"))
        menu_ok = self.menu_check(f"wedge{n:02d}-menu")
        rep.append(f"Menu screenshot after the wedge: {'OK' if menu_ok else 'NONE'}")
        hb2, hinfo2 = self.header()
        rep.append(f"scaler header on Menu: {hb2.hex(' ')} {hinfo2}")
        rep.append("capture (Menu): " + self.grab(d / "hdmi-menu.png"))
        if self.a.debug_log:
            (d / "debug-menu.txt").write_text(m.sh(f"cat {DBG} 2>/dev/null", check=False))
        (d / "report.txt").write_text("\n".join(rep) + "\n")
        self.log(f"wedge {n}: " + " | ".join(rep[:4]))
        return menu_ok

    def reboot(self):
        self.log("rebooting the card")
        self.m.sh("sync; (sleep 1; reboot) >/dev/null 2>&1 &", check=False, timeout=30)
        time.sleep(45)
        t0 = time.time()
        while time.time() - t0 < 300:
            try:
                if self.m.sh("echo up", check=False, timeout=20).strip() == "up":
                    break
            except subprocess.TimeoutExpired:
                pass
            time.sleep(10)
        else:
            raise SystemExit("the card did not come back within 5 min of the reboot")
        # the reboot cleared /tmp and the lock with it: take it back at once (other runs poll for it)
        held = take_lock(self.m, 0, self.log)
        if not held.startswith("got"):
            raise SystemExit(f"after the reboot the lock is held by another run ({held})")
        time.sleep(20)
        ok = self.menu_check("reboot-menu", wait=5)
        self.log(f"after reboot: Menu screenshot {'OK' if ok else 'NONE'}")
        if not ok:
            raise SystemExit("Menu screenshot fails after a reboot: the card needs a power cycle")

    def record(self, w, csvf, n, lb, prev, result, pmax, pmean, got, up, main):
        hb, _ = self.header()
        row = {"n": n, "time": time.strftime("%H:%M:%S"), "label": lb, "prev": prev,
               "result": result, "shot": " ".join(Path(p).name for p in got),
               "uptime": up, "main": main, "header": hb.hex(), "pmax": pmax, "pmean": pmean}
        self.rows.append(row)
        w.writerow(row)
        csvf.flush()
        self.log(f"load {n} {lb}: {row['result']} {row['shot']} (max {pmax} mean {pmean}) (uptime {up}s)")

    def after_wedge(self, lb):
        """Characterise and (with --reboot-on-wedge) reboot; False = stop the run."""
        self.wedges += 1
        self.characterise(self.wedges, lb)
        if not self.a.reboot_on_wedge:
            self.log("wedge and no --reboot-on-wedge: stopping")
            return False
        self.reboot()
        return True

    def run(self, builds):
        a, m = self.a, self.m
        seq = schedule(list(builds), a.loads, a.block)
        self.log(f"schedule ({len(seq)} loads): {''.join(seq) if all(len(x) == 1 for x in seq) else seq}")
        csvf = open(self.out / "loads.csv", "a", newline="")
        w = csv.DictWriter(csvf, fieldnames=["n", "time", "label", "prev", "result", "shot", "uptime", "main", "header", "pmax", "pmean"])
        w.writeheader()
        prev = "?"
        try:
            for lb in seq:
                self.load_no += 1
                n = self.load_no
                up = m.sh("cut -d' ' -f1 /proc/uptime", check=False).strip()
                self.rotate_dbg()
                if a.menu_every and n % a.menu_every == 0:
                    # the core -> Menu transition is checked too: a wedge here belongs to "menu"
                    got = self.menu_check(f"{n:03d}-menu", wait=10)
                    self.log(f"load {n}: Menu interlude screenshot {'OK' if got else 'NONE'}")
                    if not got:
                        self.record(w, csvf, n, "menu", prev, "wedge", "", "", [], up, self.main_cmdline())
                        if not self.after_wedge("menu"):
                            break
                    prev = "menu"
                m.sh(f"echo 'load_core {load_target(lb, builds)}' > /dev/MiSTer_cmd")
                time.sleep(a.wait)
                main = self.main_cmdline()
                stems = load_stems(lb, builds, a.pack)
                got = self.try_shot(a.shot_timeout, stems)
                if not got:
                    time.sleep(5)
                    got = self.try_shot(a.shot_timeout, stems)
                local = self.keep_shots(got, f"{n:03d}-{lb}")
                result, pmax, pmean = classify(local) if got else ("wedge", "", "")
                self.record(w, csvf, n, lb, prev, result, pmax, pmean, got, up, main)
                prev = lb
                if not got:
                    if not self.after_wedge(lb):
                        break
                    prev = "reboot"
                if (self.out / "STOP").exists():
                    self.log("STOP file found: stopping")
                    break
        finally:
            csvf.close()
            (self.out / "summary.txt").write_text(summary_text(self.rows, list(builds),
                                                               {k: str(v) for k, v in builds.items()}))


def setup(lp: Loop, builds):
    a, m = lp.a, lp.m
    m.sh(f"echo 'load_core {MENU}' > /dev/MiSTer_cmd")      # release the main core's image
    time.sleep(8)
    # a card that is already wedged would charge its wedge to the first build loaded
    got = lp.try_shot(a.shot_timeout, MENU_STEMS)
    lp.keep_shots(got, "000-start-menu")
    if not got:
        raise SystemExit("the card is wedged before the run (no Menu screenshot): reboot it first")
    lp.log("start: Menu screenshot OK")
    for lb, path in builds.items():
        if not on_card(path):
            m.put(path, remote_rbf(lb))
    hdd = None
    if a.hdd_from:
        m.sh(f"cp {shlex.quote(a.hdd_from)} {remote_hdd()}", timeout=1200)
        m.created.append(remote_hdd())
        hdd = Path(remote_hdd()).name
    for lb in builds:
        if not on_card(builds[lb]):
            m.write(mgl_text(lb, hdd, a.pack), remote_mgl(lb))
    if m.sh(f"[ -e {INI_BAK} ] && echo there", check=False).strip():
        lp.log(f"WARNING: {INI_BAK} exists (left by an earlier version of this tool, which edited "
               "MiSTer.ini for --debug-log): MiSTer.ini may still say debug=2. This tool does not touch "
               "either file; compare them and restore MiSTer.ini by hand.")
    if a.debug_log:
        if not m.sh("grep -q '^debug=2' /media/fat/MiSTer.ini && echo on", check=False).strip():
            lp.log("--debug-log: the card's MiSTer.ini does not set debug=2, so Main writes no "
                   "/tmp/debug.txt; MiSTer.ini is not changed, no log will be collected")


def own_lock(owner_text):
    """The lock file's owner line is ours (take_lock writes '<node> pid <pid> <time>')."""
    return f"{os.uname().nodename} pid {os.getpid()} " in owner_text + " "


def cleanup(lp: Loop, builds):
    a, m = lp.a, lp.m
    # A reboot clears /tmp and with it the lock: another run may hold the card now. Then only our
    # own files and MiSTer.ini are touched - never the running core or the other run's lock.
    mine = own_lock(m.sh(f"cat {LOCK}/owner 2>/dev/null", check=False))
    if not mine:
        lp.log("cleanup: the lock is not ours (lost across a reboot): leaving the card's core and lock alone")
    else:
        m.sh(f"echo 'load_core {MENU}' > /dev/MiSTer_cmd", check=False)
        time.sleep(6)
    paths = [remote_rbf(lb) for lb in builds] + [remote_mgl(lb) for lb in builds] + [remote_hdd()]
    for p in lp.created_shots:
        assert own_shot_path(p, None, ""), p           # only screenshots this run caused
    m.sh("rm -f " + " ".join(shlex.quote(p) for p in paths + lp.created_shots) + f"; rm -rf {DBG_KEEP}", check=False)
    left = m.sh("for p in " + " ".join(shlex.quote(p) for p in paths + lp.created_shots + [DBG_KEEP])
                + "; do [ -e \"$p\" ] && echo \"$p\"; done; true", check=False).split()
    lp.log("cleanup: " + ("all removed" if not left else f"LEFT ON CARD: {left}"))
    if mine:
        if a.final_mgl:
            m.sh(f"echo 'load_core {a.final_mgl}' > /dev/MiSTer_cmd", check=False)
        m.sh(f"rm -rf {LOCK}", check=False)


def selftest():
    fails = 0

    def check(c, what):
        nonlocal fails
        print(("ok   " if c else "FAIL ") + what)
        fails += not c

    check(schedule(["A", "B"], 3, 2) == ["A", "A", "B", "B", "A", "B"], "schedule: blocks interleave, remainder last")
    check(schedule(["A"], 2, 5) == ["A", "A"], "schedule: one build")
    check(parse_build("A=x.rbf") == ("A", Path("x.rbf")), "build: LABEL=PATH")
    check(parse_build("M=menu") == ("M", MENU_BUILD) and load_target("M", {"M": MENU_BUILD}) == MENU
          and load_target("A", {"A": Path("x")}) == remote_mgl("A"), "build: M=menu loads the card's Menu, nothing deployed")
    _, cp = parse_build("S=card:/media/fat/_Computer/ao486.rbf")
    check(on_card(cp) and load_target("S", {"S": cp}) == "/media/fat/_Computer/ao486.rbf",
          "build: card:PATH loads a core already on the card, nothing deployed")
    for bad in ("x.rbf", "A-1=x", "=x"):
        try:
            parse_build(bad)
            check(False, f"build: {bad!r} refused")
        except argparse.ArgumentTypeError:
            check(True, f"build: {bad!r} refused")
    # a healthy card's header read (2026-10-21): 640x400, header 256
    b, h = parse_header(["0x00010101", "0x80029000", "0x00089001", "0x3804A005"])
    check(h["magic_ok"] and h["width"] == 640 and h["height"] == 400 and h["header"] == 256, "header: magic and 640x400")
    _, h = parse_header(["0x00000000", "0x0", "0x0", "0x0"])
    check(not h["magic_ok"], "header: a zero header is not the magic")
    check(new_files(["/a", "/b"], ["/a", "/b", "/c"]) == ["/c"], "shots: the new file is found")
    check(new_files(["/a"], ["/a"]) == [], "shots: none new")
    sr = SHOT_ROOT
    st = load_stems("A", {"A": Path("x.rbf")}, "pc98pack-xe10.bin")
    check(own_shot_path(f"{sr}/PC9821/20261031_014823-pc98pack-xe10.png", st, "20261031_014820"),
          "shots: a new shot named after the pack, stamped after the request, is the run's")
    check(not own_shot_path(f"{sr}/PC9821/20261031_014810-pc98pack-xe10.png", st, "20261031_014820"),
          "shots: a shot stamped before the request is not the run's")
    check(not own_shot_path(f"{sr}/SNES/20261031_014823-Some Game.png", st, "20261031_014820")
          and not own_shot_path(f"{sr}/20261031_014823-pc98pack-xe10.png", st, "")
          and not own_shot_path(f"{sr}/PC9821/sub/20261031_014823-pc98pack-xe10.png", st, "")
          and not own_shot_path(f"{sr}/PC9821/notes.txt", None, ""),
          "shots: another core's file, a file outside a core directory or a non-screenshot is never the run's")
    check(own_shot_path(f"{sr}/Menu/20261031_014838-screen.png", MENU_STEMS, "20261031_014830")
          and not own_shot_path(f"{sr}/Menu/20261031_014838-pc98pack-xe10.png", MENU_STEMS, ""),
          "shots: a Menu shot is <stamp>-screen.png")
    check(load_stems("S", {"S": "card:/media/fat/_Computer/ao486.rbf"}, "p.bin") is None
          and own_shot_path(f"{sr}/AO486/20261031_014838-anything.png", None, "20261031_014830"),
          "shots: a card core's shot is bounded by its stamp only")
    mgl = mgl_text("A", "zreg-loop-hdd.img")
    check(f"_Computer/{CORE}-{TAG}A</rbf>" in mgl and 'index="0" path="zreg-loop-hdd.img"' in mgl
          and mgl.rstrip().endswith("</mistergamedescription>"), "mgl: zreg rbf, HDD slot 0")
    check(all(TAG in p.lower() for p in (remote_rbf("A"), remote_mgl("B"), remote_hdd(), DBG_KEEP)),
          "names: every remote file this tool creates contains zreg")
    rows = [{"label": l, "result": r} for l, r in
            [("A", "ok"), ("A", "ok"), ("B", "ok"), ("A", "wedge"), ("B", "ok"), ("B", "wedge"), ("A", "ok")]]
    s = summarize(rows, ["A", "B"])
    check(s["A"] == {"loads": 4, "wedges": 1, "black": 0, "to_wedge_own": [3], "to_wedge_any": [4]}, "summary: A to-wedge counts")
    check(s["B"] == {"loads": 3, "wedges": 1, "black": 0, "to_wedge_own": [2], "to_wedge_any": [2]}, "summary: counts reset at a wedge")
    # black / content / missing classification on tiny in-memory PNGs
    import zlib
    import struct as st

    def png(w, h, px):
        def chunk(t, b):
            return st.pack(">I", len(b)) + t + b + st.pack(">I", zlib.crc32(t + b))
        raw = b"".join(b"\x00" + b"".join(bytes(px(x, y)) for x in range(w)) for y in range(h))
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", st.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        (td / "black.png").write_bytes(png(8, 4, lambda x, y: (0, 0, 0)))
        (td / "dim.png").write_bytes(png(8, 4, lambda x, y: (3, 2, 1)))
        (td / "flat.png").write_bytes(png(8, 4, lambda x, y: (90, 90, 90)))
        (td / "content.png").write_bytes(png(8, 4, lambda x, y: (255, 255, 255) if (x, y) == (2, 1) else (0, 0, 0)))
        (td / "junk.png").write_bytes(b"not a png")
        check(classify([td / "black.png"])[0] == "black", "classify: an all-zero frame is black")
        check(classify([td / "dim.png"])[0] == "black", "classify: a frame at or below the threshold is black")
        check(classify([td / "flat.png"])[0] == "black", "classify: one flat colour is black")
        r, mx, _ = classify([td / "content.png"])
        check(r == "ok" and mx == 255, "classify: a mostly-black frame with a bright pixel is ok (the control's real shape)")
        check(classify([])[0] == "wedge", "classify: no file is a wedge")
        check(classify([td / "junk.png"])[0] == "ok", "classify: an undecodable file is not called black")
        check(classify([td / "black.png", td / "content.png"])[0] == "ok", "classify: black only when every file is")
    rows = [{"label": "X", "result": "black"}, {"label": "X", "result": "ok"}, {"label": "G", "result": "ok"}]
    sm = summarize(rows, ["X", "G"])
    check(black_failures(sm) == {"X": 1} and "BLACK-FAIL" in summary_text(rows, ["X", "G"], {}),
          "summary: one black load fails build X and not G")
    m = Mister("nowhere", "x", dry=True)
    try:
        m.put("/dev/null", "/media/fat/_Computer/PC9821Z486.rbf")
        check(False, "names: a put outside zreg is refused")
    except AssertionError:
        check(True, "names: a put outside zreg is refused")
    # setup + cleanup with --debug-log against a fake card: MiSTer.ini is only read, and the
    # owner's screenshot taken during the run (another name) is neither fetched nor deleted
    class FakeCard(Mister):
        def __init__(self):
            super().__init__("nowhere", "x", dry=True)
            self.files = [f"{SHOT_ROOT}/PC9821/20261030_120000-pc98pack-xe10.png"]

        def sh(self, cmd, check=True, timeout=600):
            self.plan.append(("ssh", cmd))
            if cmd.startswith("date"):
                return "20261031_000000\n"
            if cmd.startswith("echo screenshot"):
                self.files += [f"{SHOT_ROOT}/Menu/20261031_000001-screen.png",
                               f"{SHOT_ROOT}/Menu/20261031_000001-OwnerShot.png"]
            if cmd.startswith("find "):
                return "\n".join(self.files)
            return ""

        def get(self, remote, local):
            self.plan.append(("scp-get", remote))

    fc = FakeCard()
    la = argparse.Namespace(shot_timeout=3, debug_log=True, hdd_from=None, pack="pc98pack-xe10.bin",
                            final_mgl="", reboot_on_wedge=False, capture_dev=None)
    with tempfile.TemporaryDirectory() as td2:
        lp = Loop(la, fc, Path(td2))
        real_sleep = time.sleep
        time.sleep = lambda s: None
        try:
            setup(lp, {"A": MENU_BUILD})
            cleanup(lp, {"A": MENU_BUILD})
        finally:
            time.sleep = real_sleep
    cmds = [v for k, v in fc.plan if k == "ssh"]
    writes_ini = [c for c in cmds if "MiSTer.ini" in c and re.search(r"sed -i|cp |mv |>|tee", c)]
    check(not writes_ini, f"debug-log: MiSTer.ini is never written ({writes_ini})")
    check(lp.created_shots == [f"{SHOT_ROOT}/Menu/20261031_000001-screen.png"]
          and not any("OwnerShot" in v for _, v in fc.plan),
          "shots: only the run's own new screenshot is fetched and deleted, not another one taken meanwhile")
    me = f"{os.uname().nodename} pid {os.getpid()} Wed Oct 21 09:54:59 2026"
    check(own_lock(me) and not own_lock(me.replace(f"pid {os.getpid()} ", f"pid {os.getpid()}1 "))
          and not own_lock(""), "lock: only our own owner line is ours (pid 12 is not pid 123)")
    print("SELFTEST", "PASS" if not fails else f"FAIL ({fails})")
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default=os.environ.get("MISTER_HOST", "root@MiSTer"))
    ap.add_argument("--password", default=os.environ.get("MISTER_PASS", "1"))
    ap.add_argument("--build", action="append", type=parse_build, default=[], metavar="LABEL=RBF")
    ap.add_argument("--loads", type=int, default=40, help="loads per build (default 40)")
    ap.add_argument("--block", type=int, default=5, help="consecutive loads of one build (default 5)")
    ap.add_argument("--wait", type=float, default=25, help="seconds from load to screenshot (default 25)")
    ap.add_argument("--shot-timeout", type=float, default=10, help="seconds to wait for the file (default 10)")
    ap.add_argument("--menu-every", type=int, default=0, help="load Menu (and check a screenshot) before every Nth load")
    ap.add_argument("--hdd-from", help="card path of an HDD image to COPY to a zreg name and mount (default: none)")
    ap.add_argument("--pack", default="pc98pack-xe10.bin")
    ap.add_argument("--debug-log", action="store_true",
                    help="collect Main's /tmp/debug.txt on a wedge; it exists only when the card's own MiSTer.ini "
                         "has debug=2 (this tool never changes MiSTer.ini)")
    ap.add_argument("--capture-dev", help="local V4L2 HDMI capture device to grab a frame from on a wedge")
    ap.add_argument("--reboot-on-wedge", action="store_true", help="reboot the card after a wedge and continue")
    ap.add_argument("--final-mgl", default=f"/media/fat/{CORE}.mgl", help="loaded at the end ('' = none)")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--go", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.build:
        ap.error("at least one --build LABEL=RBF")
    builds = dict(a.build)
    if len(builds) != len(a.build):
        ap.error("duplicate build label")
    for lb, p in builds.items():
        if not on_card(p) and not p.is_file():
            ap.error(f"{lb}: no such RBF {p}")
    out = a.out or ROOT / ".build/mister-load-loop" / time.strftime("%Y%m%d-%H%M%S")
    out.mkdir(parents=True, exist_ok=True)
    m = Mister(a.host, a.password, dry=not a.go)
    lp = Loop(a, m, out)
    if not a.go:
        print(f"plan for {m.host}: {len(schedule(list(builds), a.loads, a.block))} loads, "
              f"order {''.join(schedule(list(builds), a.loads, a.block))}")
        for lb, p in builds.items():
            print(f"  {lb}: {p} -> {remote_rbf(lb)} via {remote_mgl(lb)}")
        print("dry run: nothing touched (add --go)")
        return 0
    held = take_lock(m, 0, lp.log)
    if not held.startswith("got"):
        raise SystemExit(f"the MiSTer is locked by another run ({held}); not touching it")
    try:
        setup(lp, builds)
        lp.run(builds)
    finally:
        cleanup(lp, builds)
        print((out / "summary.txt").read_text() if (out / "summary.txt").exists() else "")
        lp.log(f"output: {out}")
    bad = black_failures(summarize(lp.rows, list(builds)))
    if bad:
        print(f"BLACK-FAIL: {bad}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

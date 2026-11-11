#!/usr/bin/env python3
"""mkkit2.py - build the 2026-11 Xe10 capture kit 2 and its CF image.

    mkkit2.py --base BASE.img --out KIT.img --xe10u XE10U.COM --games GAMEDIR [--kitdir DIR]
              [--xe10t XE10T.COM]

BASE.img is kit 1's raw CF image (tools/hwprobe/xe10kit1/mkkit1.py: the Xe10 IDE BIOS layout,
8 heads x 17 sectors, the DOS partition at byte 69632, the user's own NEC MS-DOS 6.20). The
image holds NEC's DOS and the games, so it is NEVER committed; this script and the batch texts
below are the kit's source.

GAMEDIR holds the game files the kit runs, extracted from the user's own library images with
mtools (the parent of each folder below is the game image's DOS partition): OLIV, RIQL, FA,
METAJO and the packager's TOOLS (VEM486, QMOUSE), and DOS/HIMEM.SYS for Metajo (its own image
boots FreeDOS(98), whose XMS driver it replaces). They are copied to the root of the CF, where
each image's own AUTOEXEC.BAT ran them, and each game step uses that image's CONFIG.SYS lines
(VEM486 /U for UMBs, VEMEMM for Riql's EMS).

THE KIT RUNS ITSELF, as kit 1 did. AUTOEXEC.BAT stamps the boot (STAMP B) and calls RUN.BAT, a
state machine over the steps below: the first step whose flag file Snn.FLG does not exist is
run. Before its flag is written, RUN.BAT makes sure the CONFIG.SYS the step needs is the one the
machine booted with (a marker file C_<tag>.ON names it); if not, it copies KIT2\\CFG_<tag>.SYS to
A:\\CONFIG.SYS, moves the marker and reboots in software (RBOOT /Y) without marking the step,
so a step that hangs and is power-cycled still gets its own CONFIG next time. A step's batch
ends with a time stamp and the software reboot, or with a POWER-CYCLE prompt (the risky steps),
or, for a game, the game never returns: GTIMER (tools/hwprobe/gtimer) reboots after a fixed
time. A step that hangs is skipped after a power-cycle (its flag already exists).
DEL A:\\KIT2\\S*.FLG starts the sequence again.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HW = os.path.dirname(HERE)
OFF = 69632                      # the DOS partition's byte offset in the image

COMS = {  # DOS name -> built file (relative to tools/hwprobe)
    'SPEED.COM': 'speed/speed.com',
    'RISKY.COM': 'risky/risky.com',
    'TXTMODE.COM': 'txtmode/txtmode.com',
    'RBOOT.COM': 'rboot/rboot.com',
    'STAMP.COM': 'stamp/stamp.com',
    'GTIMER.COM': 'gtimer/gtimer.com',
    'XE10CFG.COM': 'xe10cfg/xe10cfg.com',
    'RSTDTR.COM': 'rstdtr/rstdtr.com',
    'SELFMOD.COM': 'selfmod/selfmod.com',
}

GAME_SECS = 150                  # how long each game runs before GTIMER reboots
# GTIMER's own PIT tick ends Olivia's Mystery and Riql (neither calls a wrapped vector often enough:
# core runs gt*/r2); Metajo goes black under the tick (core run gtm) and runs with /N (wrapped vectors
# only, core run m2), where it calls INT 18h/21h/1Bh throughout.

# CONFIG.SYS per tag (CRLF added on write). PLAIN is kit 1's.
PLAIN = 'FILES=30\nBUFFERS=10\nSHELL=A:\\COMMAND.COM A:\\ /P\n'
GAMEBASE = 'FILES=30\nBUFFERS=10\nSHELL=A:\\COMMAND.COM A:\\ /P /E:1024\n'
CONFIGS = {
    'PLN': PLAIN,
    # the packager's CONFIG.SYS of the Olivia's Mystery / Fanta Angel images: VEM486 /U
    'VEM': GAMEBASE + 'DOS=HIGH,UMB\nDEVICE=A:\\TOOLS\\VEM486.EXE /U\n',
    # the Riql image's: VEM486 /U plus its EMS driver
    'VEMS': GAMEBASE + 'DOS=HIGH,UMB\nDEVICE=A:\\TOOLS\\VEM486.EXE /U\nDEVICEHIGH=A:\\TOOLS\\VEMEMM.SYS\n',
    # Metajo: its image's FreeDOS CONFIG loads an XMS driver and DOS=HIGH; NEC DOS's HIMEM here
    'XMS': GAMEBASE + 'DEVICE=A:\\DOS\\HIMEM.SYS\nDOS=HIGH\n',
}

CFG = 'XE10T DONE'
SOFT = 'soft'      # end: stamp + software reboot
POWER = 'power'    # end: stamp + POWER-CYCLE prompt (held; a key does nothing)
GAME = 'game'      # the game never returns; GTIMER reboots
STOP = 'stop'


def check(marker: str, out: str) -> str:
    return (f'FIND "{marker}" {out} > NUL\n'
            f'IF ERRORLEVEL 1 ECHO    {out}  INCOMPLETE\n'
            f'IF NOT ERRORLEVEL 1 ECHO    {out}  ok\n')


def run(cmd: str, out: str, marker: str) -> str:
    return f'{cmd} > {out}\n' + check(marker, out)


def banner(*lines: str) -> str:
    t = 'ECHO.\nECHO ****************************************************************\n'
    for ln in lines:
        t += f'ECHO   {ln}\n'
    return t + 'ECHO ****************************************************************\nECHO.\n'


def game(title: str, look: str, run_lines: str, gt: str = '') -> str:
    # drivers (LH lines) load before GTIMER, so GTIMER can wrap the mouse driver's INT 33h
    return (banner(f'GAME: {title}', f'It runs {GAME_SECS} s, then the machine reboots by itself.',
                   'Do not press any key. Keep filming.', look)
            + 'CALL WAIT5\n' + ''.join(ln + '\n' for ln in run_lines.splitlines() if ln.startswith('LH '))
            + 'GTIMER %d%s\n' % (GAME_SECS, gt)
            + ''.join(ln + '\n' for ln in run_lines.splitlines() if not ln.startswith('LH ')))


# (title, CONFIG tag, body, how it ends, why)
STEPS = [
    ('cold boot: XE10CFG /FD (BDA, VFO corner), SPEED (the gate Dhrystone, timing loops)', 'PLN',
     run('XE10CFG /FD', 'FD0.TXT', 'XE10CFG DONE') + run('SPEED', 'SPEED.TXT', 'END:SPEED'), SOFT,
     'the BDA as the cold boot left it (drives empty); the speed reference wants a fresh boot'),
    ('XE10U /OPNA4 (silent), RSTDTR (IDTR/GDTR after a CPU reset)', 'PLN',
     'XE10U /OPNA4 /O OPNA4.TXT\n' + check(CFG, 'OPNA4.TXT') + run('RSTDTR', 'RSTDTR.TXT', 'END:RSTDTR'), SOFT,
     'first-touch OPNA state; leaves timers set; RSTDTR makes a CPU-only reset (item 53)'),
    ('XE10U /AUDIT2, XE10CFG /CG (CG rows for the video lane), SELFMOD /2 (item 141)', 'PLN',
     'XE10U /AUDIT2 /O AUDIT2.TXT\n' + check(CFG, 'AUDIT2.TXT') + run('XE10CFG /CG', 'CG2.TXT', 'XE10CFG DONE')
     + run('SELFMOD /2', 'SM2.TXT', 'END:SELFMOD'),
     SOFT, 'writes real ports (restored); /CG only reads'),
    ('FILM: XE10CFG /6C (12 s), TXTMODE /D, the text geometry steps (about 3.5 min)', 'PLN',
     banner('START FILMING THE SCREEN NOW (one video, about 15 minutes),',
            'with the scaler\'s mode read-out visible, then press a key.',
            'Keep filming through the three games until STOP FILMING.') + 'PAUSE\n'
     'ECHO Port 0x6C: 80, F0, FF, 70, 3 s each (a border colour?)\n' + run('XE10CFG /6C', 'P6C.TXT', 'XE10CFG DONE') +
     'CLS\nTXTMODE /D > TXTD.TXT\nCLS\n' + check('END:TXTMODE', 'TXTD.TXT'), SOFT, 'the text mode is restored by a reboot'),
    ("GAME 1: Olivia's Mystery", 'VEM',
     game("Olivia's Mystery (title screen)", 'Look for: black holes / displaced tiles in the title picture.',
          'LH /L:2 QMOUSE -z\nCD \\OLIV\nOLIV\n'), GAME, 'its own CONFIG (VEM486)'),
    ('GAME 2: Riql (Atelier OZ)', 'VEMS',
     game('Riql (menu select screen)', 'Look for: does the menu box fill with items?',
          'LH /L:2 QMOUSE -z\nCD \\RIQL\nFPDRIQL\n'), GAME, 'its own CONFIG (VEM486 + VEMEMM)'),
    ('GAME 3: Metajo SP', 'XMS',
     game('Metajo SP (intro, R-FORCE logo, then?)', 'Look for: what follows the R-FORCE logo.',
          'CD \\METAJO\nMTJ\n', ' /N'), GAME, 'its own CONFIG (HIMEM)'),
    ('XE10CFG /IDE2: the IDE bank select states and CHECK POWER MODE (items 21, 27)', 'PLN',
     banner('STOP FILMING.') + run('XE10CFG /IDE2', 'IDE2.TXT', 'XE10CFG DONE'), SOFT,
     'moves the IDE bank select the CF sits behind (restored in every row)'),
    ('RISKY 1: 0x989x write/read (item 35)', 'PLN',
     'RISKY /989 /O R989.TXT\n' + check('END:RISKY', 'R989.TXT'), POWER, 'unknown ports written'),
    ('RISKY 2: the 0x0461 window page 0 (item 97)', 'PLN',
     'RISKY /461 /O R461.TXT\n' + check('END:RISKY', 'R461.TXT'), POWER, 'moves a memory window under DOS'),
    ('RISKY 3: 0x043B bit 2, the 15-16 MiB space (item 98)', 'PLN',
     'RISKY /43B /O R43B.TXT\n' + check('END:RISKY', 'R43B.TXT'), POWER, 'moves memory above 1 MiB'),
    ('RISKY 4: 0x043F write/read sweep (item 28)', 'PLN',
     'RISKY /43F /O R43F.TXT\n' + check('END:RISKY 43F', 'R43F.TXT'), POWER, 'moves the EMS page register, 256 values'),
    ('RISKY 4b: the 0x043F sweep resumed past a hang (only if step 4 did not finish)', 'PLN',
     'FIND "END:RISKY 43F" R43F.TXT > NUL\nIF NOT ERRORLEVEL 1 GOTO SKIP\n'
     'RISKY /43F /O R43F.TXT\n' + check('END:RISKY 43F', 'R43F.TXT'), POWER,
     'RISKY appends a RESUME line and goes on after the value that hung'),
]

POWER_MSG = ('POWER-CYCLE NOW: switch the machine OFF, wait 10 s, switch it ON.',
             '(Do not press a key. The kit goes on by itself after the power-on.)')


def step_bat(i: int, title: str, body: str, end: str) -> str:
    n = len(STEPS)
    t = f'@ECHO OFF\nREM step {i}: {title}\nCD \\KIT2\nECHO.\nECHO KIT 2 STEP {i} of {n}: {title}\n' + body
    if end == SOFT:
        t += f'STAMP SW{i}\nRBOOT /Y\n'
    elif end == POWER:
        t += f'STAMP PC{i}\n' + banner(*POWER_MSG) + ':HOLD\nGOTO HOLD\n'
        if 'GOTO SKIP' in body:
            t += f':SKIP\nECHO    nothing to resume\nSTAMP SK{i}\nRBOOT /Y\n'
    elif end == GAME:
        t += f'STAMP GX{i}\nRBOOT /Y\n'    # the game returned to DOS: note it, go on
    return t


def run_bat() -> str:
    t = ('@ECHO OFF\nREM the kit state machine: the first step without its flag runs;\n'
         'REM its CONFIG.SYS is put in place first (a software reboot), then its flag is written\n')
    for i in range(1, len(STEPS) + 1):
        t += f'IF NOT EXIST S{i:02d}.FLG GOTO B{i:02d}\n'
    t += 'GOTO DONE\n'
    for i, (_, tag, _, _, _) in enumerate(STEPS, 1):
        t += (f':B{i:02d}\nIF NOT EXIST C_{tag}.ON CALL SETCFG {tag}\n'
              f'ECHO started > S{i:02d}.FLG\nECHO STEP {i:02d} >> RUNLOG.TXT\n'
              f'CALL B{i:02d}.BAT\nGOTO END\n')
    t += ':DONE\nIF NOT EXIST C_PLN.ON CALL SETCFG PLN\n' + banner(
        'KIT 2 FINISHED. Power off. Send back the CF card and the video.',
        '(Optional 640K floppy pass: see README.TXT.)') + ':END\n'
    return t


SETCFG = ('@ECHO OFF\nREM SETCFG tag: CFG_tag.SYS becomes A:\\CONFIG.SYS, then a software reboot\n'
          'CD \\KIT2\nCOPY CFG_%1.SYS A:\\CONFIG.SYS > NUL\nIF EXIST C_*.ON DEL C_*.ON\n'
          'ECHO %1 > C_%1.ON\nECHO CONFIG %1 >> RUNLOG.TXT\nSTAMP CF%1\nRBOOT /Y\n')

# WAIT5: about 5 s so the banner is on the video before the game takes the screen
WAIT5 = '@ECHO OFF\nSTAMP W\nSTAMP W\nSTAMP W\nSTAMP W\nSTAMP W\n'


def batches() -> dict:
    b = {f'B{i:02d}.BAT': step_bat(i, t, body, end) for i, (t, _, body, end, _) in enumerate(STEPS, 1)}
    b['RUN.BAT'] = run_bat()
    b['SETCFG.BAT'] = SETCFG
    b['WAIT5.BAT'] = WAIT5
    for tag, text in CONFIGS.items():
        b[f'CFG_{tag}.SYS'] = text
    b['OPTFD.BAT'] = ('@ECHO OFF\nREM optional: booted with the kit-1 floppy in drive 1 (item 59)\nCD \\KIT2\n'
                      + run('XE10CFG /FD', 'FD1.TXT', 'XE10CFG DONE') + 'ECHO Done. Leave the floppy in; go on with the 640K pass.\n')
    b['OPT640.BAT'] = ('@ECHO OFF\nREM optional: AFTER SETUP floppy mode = 640K, kit-1 floppy at hand\nCD \\KIT2\n'
                       'ECHO   *** PUT THE KIT-1 FLOPPY INTO DRIVE 1, then press a key ***\nPAUSE\n'
                       'XE10T /FDC2 /M640 /O FDC2M.TXT\n' + check(CFG, 'FDC2M.TXT') +
                       'ECHO Take the floppy out. Set SETUP back to the floppy mode you wrote down. Done.\n')
    return b


def step_table() -> str:
    rows = []
    for i, (t, tag, _, end, why) in enumerate(STEPS, 1):
        how = {SOFT: 'software reboot', POWER: 'YOU POWER-CYCLE', GAME: f'reboots itself after {GAME_SECS} s',
               STOP: 'end'}[end]
        rows.append(f' {i:2d}  {t}\n       -> {how}; {why}')
    return '\n'.join(rows)


MENU = """XE10 KIT 2 (2026-11): it runs by itself (A:\\KIT2\\RUN.BAT, one step per boot).
Watch the screen: it tells you when to film and when to power-cycle.
README.TXT has everything (TYPE A:\\KIT2\\README.TXT | MORE).
"""

README = """XE10 CAPTURE KIT 2 (2026-11) - it runs itself
==================================================

WHAT YOU NEED
- this CF card, fitted as for kit 1; the machine as found (SETUP: Sound
  "not used", the -86 board fitted). Both floppy drives EMPTY.
- a phone to film the screen once (about 15 minutes), with the scaler's
  mode read-out visible
- about 35 minutes

WHAT YOU DO (everything else is automatic)
 1. Power the machine OFF, wait 30 s, power ON. Steps 1-3 run by themselves
    (about 3 minutes, several reboots).
 2. When it says  START FILMING : start the video, press a key. Keep filming:
    the text screens (about 3 minutes), then three games, each about 2.5 min,
    the machine rebooting itself between them. Press nothing.
    If the machine has not rebooted 4 minutes after a game's banner (a
    frozen or black screen), press RESET once: the kit goes on.
 3. When it says  STOP FILMING : stop the video.
 4. Four (rarely five) times the screen says  POWER-CYCLE NOW : switch
    off, wait 10 s, switch on.
 5. When it says  KIT 2 FINISHED : power off. Send back the CF card (or every
    A:\\KIT2\\*.TXT file) and the video.

IF SOMETHING HANGS (nothing changes for 3 minutes, outside a game): power
off, wait 10 s, power on. The kit skips the step that hung and goes on; the
hang is itself a result. The RISKY steps at the end may hang the machine.

OPTIONAL, AT THE END (5 minutes, needs the floppy kit 1 wrote):
 a. Put the kit-1 floppy into drive 1, press RESET (it boots the CF as in
    kit 1). At the prompt type  OPTFD .
 b. Enter SETUP, WRITE DOWN the floppy disk mode, set it to 640K, save, boot
    with the drives empty, type  OPT640  (it asks for the floppy in drive 1).
    Then set SETUP back to the mode you wrote down.

THE STEPS
""" + step_table() + """

SAFETY
- Nothing writes to the hard disk except the result files (and the kit's
  own CONFIG.SYS switches between steps).
- No floppy is written.
- To start the whole sequence again: DEL A:\\KIT2\\S*.FLG
"""

AUTOEXEC = '@ECHO OFF\nPATH A:\\DOS;A:\\;A:\\KIT2;A:\\TOOLS\nCD \\KIT2\nSTAMP B\nTYPE A:\\MENU.TXT\nCALL RUN.BAT\n'


def crlf(t: str) -> bytes:
    return t.replace('\r\n', '\n').replace('\n', '\r\n').encode('ascii')


def sh(*a, **k):
    return subprocess.run(list(a), check=True, **k)



# ---- game folders: copied with their 8.3 names byte for byte -------------------------------
# The games keep Shift-JIS file names (Fanta Angel's 第１話.GRA, Riql's ｱﾄﾘOZ.DOC). mtools reads them
# as code page 850 text (mtools' default) and, writing them back, upper-cases the "letters" and adds a VFAT long
# name - a different 8.3 name, so the game cannot open the file (seen on the core: "File:第１話.GRA
# が読み込み出来ません", then a fault). Such a file is copied under a plain placeholder name and its
# directory entry's 11 name bytes are then written raw (the cp850 encoding of the name mtools
# printed is the original byte string; checked against the source images' raw entries).

def _plain(name: str) -> bool:
    stem, _, ext = name.partition('.')
    ok = set('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-#$!@%&()~')
    return 0 < len(stem) <= 8 and len(ext) <= 3 and set(stem + ext) <= ok


def _raw83(name: str) -> bytes:
    stem, _, ext = name.partition('.')
    b = stem.encode('cp850').ljust(8, b' ') + ext.encode('cp850').ljust(3, b' ')
    if len(b) != 11:
        raise SystemExit(f'{name!r}: not an 8.3 name')
    return b'\x05' + b[1:] if b[0] == 0xE5 else b     # FAT stores a leading 0xE5 as 0x05


class Fat12:
    def __init__(self, path: str, off: int):
        self.f = open(path, 'r+b')
        self.off = off
        self.f.seek(off)
        bs = self.f.read(64)
        (self.bps, self.spc, rsv, nf, rootn, _tot, _med, spf) = __import__('struct').unpack('<HBHBHHBH', bs[11:24])
        if bs[54:59] != b'FAT12':
            raise SystemExit('the kit partition is not FAT12')
        self.fat0 = off + rsv * self.bps
        self.root = self.fat0 + nf * spf * self.bps
        self.rootlen = rootn * 32
        self.data = self.root + self.rootlen
        self.f.seek(self.fat0)
        self.fat = self.f.read(spf * self.bps)

    def _next(self, c: int) -> int:
        v = int.from_bytes(self.fat[c * 3 // 2:c * 3 // 2 + 2], 'little')
        return (v >> 4) if c & 1 else (v & 0xFFF)

    def _dir_spans(self, cluster):
        if cluster is None:
            return [(self.root, self.rootlen)]
        spans, c = [], cluster
        while 2 <= c < 0xFF8:
            spans.append((self.data + (c - 2) * self.spc * self.bps, self.spc * self.bps))
            c = self._next(c)
        return spans

    def _find(self, cluster, raw: bytes):
        for base, ln in self._dir_spans(cluster):
            self.f.seek(base)
            blk = self.f.read(ln)
            for i in range(0, ln, 32):
                if blk[i:i + 11] == raw and blk[i + 11] != 0x0F:
                    return base + i, int.from_bytes(blk[i + 26:i + 28], 'little')
        raise SystemExit(f'{raw!r} not found')

    def rename(self, dirpath: list, old: str, new_raw: bytes):
        cl = None
        for d in dirpath:
            _, cl = self._find(cl, _raw83(d))
        pos, _ = self._find(cl, _raw83(old))
        self.f.seek(pos)
        self.f.write(new_raw)

    def close(self):
        self.f.close()


def copy_game_dir(img: str, src: str, env: dict) -> int:
    """mcopy SRC (a folder) to the image root, keeping every 8.3 name byte for byte."""
    top = os.path.basename(src.rstrip('/'))
    fix = []
    for root, dirs, files in os.walk(src):
        rel = os.path.relpath(root, os.path.dirname(src.rstrip('/'))).split(os.sep)
        for d in dirs:
            if not _plain(d):
                raise SystemExit(f'{d!r}: a folder with a non-ASCII name is not handled')
        sh('mmd', '-i', img, '::/' + '/'.join(rel), env=env)
        for fn in sorted(files):
            dst = fn
            if not _plain(fn):
                dst = 'ZQ%06d' % len(fix) + ('.' + fn.partition('.')[2] if '.' in fn else '')
                fix.append((rel, dst, _raw83(fn)))
            sh('mcopy', '-i', img, os.path.join(root, fn), '::/' + '/'.join(rel) + '/' + dst, env=env)
    if fix:
        path, off = img.split('@@')
        fat = Fat12(path, int(off))
        for rel, dst, raw in fix:
            fat.rename(rel, dst, raw)
        fat.close()
    return len(fix)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--kitdir')
    ap.add_argument('--xe10u', required=True)
    ap.add_argument('--xe10t', help='XE10T.COM for the optional /M640 pass (kit 1\'s binary)')
    ap.add_argument('--games', required=True)
    ap.add_argument('--partial', action='store_true', help='test builds: skip a probe that does not build')
    ap.add_argument('--preflag', type=int, default=0, help='test builds: mark steps 1..N as done')
    a = ap.parse_args()
    out = os.path.abspath(a.out)
    kitdir = os.path.abspath(a.kitdir or os.path.join(os.path.dirname(out), 'kit'))
    shutil.rmtree(kitdir, ignore_errors=True)
    k2 = os.path.join(kitdir, 'KIT2')
    os.makedirs(k2)
    for dosname, src in COMS.items():
        r = subprocess.run(['make', '-C', HW, src])
        if r.returncode and a.partial:
            print(f'PARTIAL: {dosname} left out')
            continue
        r.check_returncode()
        shutil.copyfile(os.path.join(HW, src), os.path.join(k2, dosname))
    if os.path.exists(a.xe10u):
        shutil.copyfile(a.xe10u, os.path.join(k2, 'XE10U.COM'))
    elif not a.partial:
        raise SystemExit(f'{a.xe10u} missing')
    for i in range(1, a.preflag + 1):
        open(os.path.join(k2, f'S{i:02d}.FLG'), 'wb').write(b'started\r\n')
    if a.xe10t:
        shutil.copyfile(a.xe10t, os.path.join(k2, 'XE10T.COM'))
    for name, text in batches().items():
        open(os.path.join(k2, name), 'wb').write(crlf(text))
    open(os.path.join(k2, 'README.TXT'), 'wb').write(crlf(README))
    open(os.path.join(k2, 'C_PLN.ON'), 'wb').write(crlf('PLAIN\n'))
    open(os.path.join(kitdir, 'MENU.TXT'), 'wb').write(crlf(MENU))
    open(os.path.join(kitdir, 'AUTOEXEC.BAT'), 'wb').write(crlf(AUTOEXEC))
    open(os.path.join(kitdir, 'CONFIG.SYS'), 'wb').write(crlf(PLAIN))
    shutil.copyfile(a.base, out)
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    img = f'{out}@@{OFF}'
    listing = subprocess.run(['mdir', '-b', '-i', img, '::/'], env=env, capture_output=True, text=True).stdout
    for d in ('KIT', 'KIT1', 'W95', 'YM29', 'GALF', 'KIT2', 'OLIV', 'RIQL', 'FA', 'METAJO', 'TOOLS'):
        if f'::/{d}/' in listing or f'::/{d}' in listing.split():
            sh('mdeltree', '-i', img, f'::/{d}', env=env)
    sh('mcopy', '-o', '-i', img, os.path.join(kitdir, 'AUTOEXEC.BAT'), os.path.join(kitdir, 'MENU.TXT'),
       os.path.join(kitdir, 'CONFIG.SYS'), '::/', env=env)
    sh('mcopy', '-s', '-i', img, k2, '::/', env=env)
    for d in ('OLIV', 'RIQL', 'METAJO', 'TOOLS'):
        n = copy_game_dir(img, os.path.join(a.games, d), env)
        if n:
            print(f'{d}: {n} Shift-JIS name(s) written byte for byte')
    sh('mcopy', '-o', '-i', img, os.path.join(a.games, 'DOS', 'HIMEM.SYS'), '::/DOS/', env=env)
    free = subprocess.run(['mdir', '-i', img, '::/'], env=env, capture_output=True, text=True).stdout.strip().splitlines()[-1]
    sums = []
    for root, _, files in os.walk(kitdir):
        for f in sorted(files):
            p = os.path.join(root, f)
            sums.append((hashlib.sha256(open(p, 'rb').read()).hexdigest(), os.path.relpath(p, os.path.dirname(out))))
    sums.append((hashlib.sha256(open(out, 'rb').read()).hexdigest(), os.path.basename(out)))
    with open(os.path.join(os.path.dirname(out), 'SHA256SUMS'), 'w') as f:
        for h, p in sorted(sums, key=lambda x: x[1]):
            f.write(f'{h}  {p}\n')
    print(f'kit {kitdir}, image {out} ({free.strip()})')
    return 0


if __name__ == '__main__':
    sys.exit(main())

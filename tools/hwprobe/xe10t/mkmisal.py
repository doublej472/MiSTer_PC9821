#!/usr/bin/env python3
"""mkmisal.py - build the MISAL kit's CF image: XE10V /MISAL, the GVRAM store cost by alignment
(or with --kit misal2: XE10W /MISAL2, the other misaligned access paths, in A:\\MISAL2; or with
--kit rdlat: XE10X /RDLAT, reads under a nop sweep and the 31 kHz / 640x480 modes, in A:\\RDLAT).

    mkmisal.py --base BASE.img --out KIT.img [--xe10v XE10V.COM] [--runs N] [--selftest]
    mkmisal.py --kit misal2 --base BASE.img --out KIT.img [--xe10w XE10W.COM] [--runs N] [--selftest]
    mkmisal.py --kit rdlat --base BASE.img --out KIT.img [--xe10x XE10X.COM] [--runs N] [--selftest]

BASE.img is an earlier kit's raw CF image (the Xe10 IDE BIOS layout, 8 heads x 17 sectors, the DOS
partition at byte 69632, the user's own NEC MS-DOS 6.20). Every top-level folder of it except DOS
is removed. The image holds NEC's DOS, so it is NEVER committed.

THE KIT RUNS ITSELF in one boot (AUTOEXEC.BAT -> \\MISAL\\RUN.BAT), no keys, and writes each run to
\\MISAL\\MISALn.TXT (the probe writes the file itself and commits it after every section). Each
step writes its flag file Snn.FLG before it runs, so a step that hangs is skipped after a reset;
DONE.FLG ends the sequence (DEL \\MISAL\\*.FLG starts it again). Plain DOS: no HIMEM, no EMM386,
no sound driver (XE10V refuses V86 mode).
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OFF = 69632

CONFIG = 'FILES=20\nBUFFERS=8\nSHELL=A:\\COMMAND.COM A:\\ /P\n'

AUTOEXEC = r'''@ECHO OFF
PATH A:\;A:\DOS
CD \MISAL
IF EXIST DONE.FLG GOTO DONE
CALL RUN.BAT
GOTO END
:DONE
TYPE DONE.TXT
:END
'''

DONE = r'''
 MISAL kit: all steps are done.

 Switch the machine off, take the CF card out and bring it back (or copy
 the folder A:\MISAL - MISAL1.TXT and MISAL2.TXT are the results).

 To run the kit again: DEL A:\MISAL\*.FLG and A:\MISAL\MISAL?.TXT, then reboot.
'''

README = r'''MISAL kit (2026-11): times graphics-memory stores at every byte alignment,
with the GRCG in its two modes and off, with the graphics screen off and on.

It runs by itself at boot, no keys. The screen shows the probe's progress; for
part of each run the graphics screen is on and shows blue stripes at the top
(that is the test writing to it). When the screen says "all steps are done",
switch off and bring back the CF card.

Do not change the SETUP or the switches. If the machine hangs on a step for
more than a minute, press RESET: the kit skips that step and goes on.
'''


# --kit misal2: the second kit (A:\MISAL2, XE10W.COM, results MIS2RUNn.TXT)
DONE2 = r'''
 MISAL2 kit: all steps are done.

 Switch the machine off, take the CF card out and bring it back (or copy
 the folder A:\MISAL2 - MIS2RUN1.TXT, MIS2RUN2.TXT and SELF.TXT are the results).

 To run the kit again: DEL A:\MISAL2\*.FLG and A:\MISAL2\MIS2RUN?.TXT, then reboot.
'''

README2 = r'''MISAL2 kit (2026-11): times memory and I/O accesses at every byte alignment:
main memory, graphics-memory reads, the text and 256-colour memory, word I/O.

It runs by itself at boot, no keys. The screen shows the probe's progress; for
part of each run the graphics screen is on and shows stripes or coloured noise
(that is the test writing to it). When the screen says "all steps are done",
switch off and bring back the CF card.

Do not change the SETUP or the switches. If the machine hangs on a step for
more than a minute, press RESET: the kit skips that step and goes on.
'''

# --kit rdlat: the third kit (A:\RDLAT, XE10X.COM, results RDLATn.TXT)
DONE3 = r'''
 RDLAT kit: all steps are done.

 Switch the machine off, take the CF card out and bring it back (or copy
 the folder A:\RDLAT - RDLAT1.TXT, RDLAT2.TXT and SELF.TXT are the results).

 To run the kit again: DEL A:\RDLAT\*.FLG and A:\RDLAT\RDLAT?.TXT, then reboot.
'''

README3 = r'''RDLAT kit (2026-11): times graphics-memory and text-memory reads and stores
with a growing number of instructions between them, in three display modes:
640x400 at 24 kHz, 640x400 at 31 kHz and 640x480 with 256 colours.

It runs by itself at boot, no keys, about 3 minutes a run. The screen shows the
probe's progress. During each run the display switches to the 31 kHz modes and
back: the monitor may lose the picture or show "out of range" for a while, and
the top of the screen shows stripes, coloured noise and blanked text (that is
the test writing to it). The text screen is put back at the end of each run.
When the screen says "all steps are done", switch off and bring back the CF card.

Do not change the SETUP or the switches. If the machine hangs on a step for
more than two minutes (the monitor shows nothing new and the drive light stays
off), press RESET: the kit skips that step and goes on.
'''

KITS = {'misal': ('XE10V', 'MISAL', 'MISAL%d.TXT', DONE, README),
        'misal2': ('XE10W', 'MISAL2', 'MIS2RUN%d.TXT', DONE2, README2),
        'rdlat': ('XE10X', 'RDLAT', 'RDLAT%d.TXT', DONE3, README3)}


def run_bat(runs: int, selftest: bool, kit: str = 'misal') -> str:
    com, sec, res = KITS[kit][:3]
    out = ['@ECHO OFF', f'REM {sec} kit: generated by tools/hwprobe/xe10t/mkmisal.py', '']
    if selftest:
        out += ['IF EXIST S00.FLG GOTO XS00', 'ECHO S00.FLG> S00.FLG',
                f'ECHO === {sec} S00: {com} /SELFTEST', f'{com} /SELFTEST /O SELF.TXT', ':XS00', '']
    for i in range(1, runs + 1):
        flag = 'S%02d' % i
        out += [f'IF EXIST {flag}.FLG GOTO X{flag}',
                f'ECHO {flag}.FLG> {flag}.FLG',
                f'ECHO === {sec} {flag}: {com} /{sec}, run {i} of {runs}',
                f'{com} /{sec} /O {res % i}',
                f':X{flag}', '']
    out += ['ECHO DONE> DONE.FLG', 'TYPE DONE.TXT', '']
    return '\n'.join(out)


def crlf(t: str) -> bytes:
    return t.replace('\r\n', '\n').replace('\n', '\r\n').encode('ascii')


def sh(*a, **k):
    subprocess.run(a, check=True, **k)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--kit', choices=tuple(KITS), default='misal')
    ap.add_argument('--xe10v', default=os.path.join(HERE, 'xe10v.com'))
    ap.add_argument('--xe10w', default=os.path.join(HERE, 'xe10w.com'))
    ap.add_argument('--xe10x', default=os.path.join(HERE, 'xe10x.com'))
    ap.add_argument('--runs', type=int, default=2)
    ap.add_argument('--selftest', action='store_true', help='step S00: XE10V /SELFTEST to SELF.TXT')
    ap.add_argument('--work', default=None)
    a = ap.parse_args()
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1', MTOOLS_NO_VFAT='1')
    work = a.work or a.out + '.d'
    shutil.rmtree(work, ignore_errors=True)
    com0, d, _, done_t, readme_t = KITS[a.kit]
    com, src = com0 + '.COM', {'misal': a.xe10v, 'misal2': a.xe10w, 'rdlat': a.xe10x}[a.kit]
    os.makedirs(os.path.join(work, d))
    shutil.copy(src, os.path.join(work, d, com))
    texts = {'RUN.BAT': run_bat(a.runs, a.selftest, a.kit), 'DONE.TXT': done_t, 'README.TXT': readme_t}
    for n, t in texts.items():
        open(os.path.join(work, d, n), 'wb').write(crlf(t))
    open(os.path.join(work, 'CONFIG.SYS'), 'wb').write(crlf(CONFIG))
    open(os.path.join(work, 'AUTOEXEC.BAT'), 'wb').write(crlf(AUTOEXEC.replace('CD \\MISAL', 'CD \\' + d)))
    shutil.copy(a.base, a.out)
    img = f'{a.out}@@{OFF}'
    ls = subprocess.run(['mdir', '-b', '-i', img, '::/'], env=env, check=True,
                        capture_output=True, text=True).stdout.split()
    for p in ls:
        name = p.rstrip('/').split('/')[-1].upper()
        if name in ('DOS', 'COMMAND.COM', 'IO.SYS', 'MSDOS.SYS'):
            continue
        if p.endswith('/'):
            sh('mdeltree', '-i', img, '::/' + name, env=env)
        elif name in ('CONFIG.SYS', 'AUTOEXEC.BAT', 'MENU.TXT'):
            sh('mdel', '-i', img, '::/' + name, env=env)
    sh('mcopy', '-o', '-i', img, os.path.join(work, 'CONFIG.SYS'), os.path.join(work, 'AUTOEXEC.BAT'),
       '::/', env=env)
    sh('mcopy', '-s', '-i', img, os.path.join(work, d), '::/', env=env)
    sh('mdir', '-i', img, '::/' + d, env=env)
    h = hashlib.sha256(open(a.out, 'rb').read()).hexdigest()
    print(f'built {a.out} sha256 {h}')
    return 0


if __name__ == '__main__':
    sys.exit(main())

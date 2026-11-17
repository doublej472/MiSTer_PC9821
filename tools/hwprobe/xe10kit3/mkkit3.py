#!/usr/bin/env python3
"""mkkit3.py - build the 2026-11 kit-3 CF image: the open follow-ups an Xe10 probe can answer, in
one boot with no keys (results in A:\\KIT3).

    mkkit3.py --base BASE.img --out KIT.img [--xe10y XE10Y.COM] [--xe10cg3 XE10CG3.COM] [--quick]

BASE.img is an earlier kit's raw CF image (the Xe10 IDE BIOS layout, 8 heads x 17 sectors, the DOS
partition at byte 69632, the user's own NEC MS-DOS 6.20). Every top-level folder of it except DOS
is removed. The image holds NEC's DOS, so it is NEVER committed.

THE STEPS of --run 1, the first image (--run 2, the default, is STEPS2 below) (KIT3\\RUN.BAT; each writes its flag Snn.FLG before it runs, so a step that hangs is
skipped after a RESET; DONE.FLG ends the sequence, DEL A:\\KIT3\\*.FLG starts it again):
  S00  XE10Y /SELFTEST                       SELF.TXT   the harness checks
  S01  XE10Y /K3M                            K3M.TXT    PIT one-byte writes (first: the boot's own
                                                        PIT state), IDIV B0F8h/1Eh, 0xE0000 in the
                                                        16-colour mode, the GDC blank in the line,
                                                        IDENTIFY DEVICE / PACKET task-file read-back
  S02  XE10Y /PKAB                           PKAB.TXT   the PEGC store A/B (three rounds)
  S03  XE10Y /CELLS                          CELLS.TXT  item 197's class-table cells
  S04  XE10Y /MISAL2 /RDLAT /REP 2           REP.TXT    both earlier kits' sections in one binary,
                                                        twice, interleaved (the /REP spread)
  S05  XE10CG3 /CG                           CG.TXT     the CG window, read-only (XE10CFG with
                                                        the kit-3 CGX rows)
  S06  XE10W /MISAL2                         M2OLD.TXT  the binaries of the XE10W-XE10-MIS2RUN* and
  S07  XE10X /RDLAT                          RDOLD.TXT  XE10X-XE10-RDLAT* captures, in this boot:
                                                        with /PKAB they tell the binary from the boot
--quick (the core side): /QUICK (3 repeats) on every XE10Y step.
Plain DOS: no HIMEM, no EMM386, no sound driver (XE10Y refuses V86 mode).
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
XE10T = os.path.join(os.path.dirname(HERE), 'xe10t')
OFF = 69632
KD = 'KIT3'

CONFIG = 'FILES=20\nBUFFERS=8\nSHELL=A:\\COMMAND.COM A:\\ /P\n'

AUTOEXEC = r'''@ECHO OFF
PATH A:\;A:\DOS
CD \KIT3
IF EXIST DONE.FLG GOTO DONE
CALL RUN.BAT
GOTO END
:DONE
TYPE DONE.TXT
:END
'''

DONE = r'''
 KIT3: all steps are done.

 Switch the machine off, take the CF card out and bring it back (or copy
 the whole folder A:\KIT3 - every .TXT file in it but DONE.TXT and
 README.TXT is a result).

 To run the kit again: DEL A:\KIT3\*.FLG and the result files
{dels}
 then reboot (DONE.TXT and README.TXT are the kit's own: keep them).
'''


def done_txt(steps) -> str:
    """DONE.TXT with the restart instruction naming this run's result files: a *.TXT wildcard
    would delete DONE.TXT and README.TXT too, and RUN.BAT ends with TYPE DONE.TXT."""
    names = sorted({res for _, _, res, _ in steps})
    rows, row = [], ''
    for n in names:
        if row and len(row) + len(n) + 1 > 60:
            rows.append(row)
            row = ''
        row += (' ' if row else '') + n
    rows.append(row)
    return DONE.format(dels='\n'.join(' (in A:\\KIT3) ' + r if i == 0 else '               ' + r
                                       for i, r in enumerate(rows)))

README = r'''KIT3 (2026-11): timing and read-back rows for the open follow-ups.

It runs by itself at boot, no keys, about 20 minutes. The screen shows the
probe's progress. During the run the display switches between 24 kHz and
31 kHz modes many times: the monitor may lose the picture or show "out of
range" for a while, and the screen shows stripes, coloured noise and blanked
text (that is the test writing to it). The text screen is put back after each
step. When the screen says "all steps are done", switch off and bring back the
CF card.

Do not change the SETUP or the switches. If the machine hangs on a step for
more than five minutes (nothing on the screen changes and the drive light stays
off), write down the last line on the screen, then press RESET: the kit skips
that step and goes on. Every result line is already on the card.
'''

STEPS1 = [
    ('XE10Y', '/SELFTEST', 'SELF.TXT', 'the harness self-test'),
    ('XE10Y', '/K3M', 'K3M.TXT', 'PIT, IDIV, E0000, GDC blank, IDE read-back'),
    ('XE10Y', '/PKAB', 'PKAB.TXT', 'the PEGC store A/B'),
    ('XE10Y', '/CELLS', 'CELLS.TXT', 'the class-table cells'),
    ('XE10Y', '/MISAL2 /RDLAT /REP 2', 'REP.TXT', 'MISAL2 and RDLAT twice'),
    ('XE10CG3', '/CG', 'CG.TXT', 'the CG window (read-only)'),
    ('XE10W', '/MISAL2', 'M2OLD.TXT', 'the MISAL2 kit binary again'),
    ('XE10X', '/RDLAT', 'RDOLD.TXT', 'the RDLAT kit binary again'),
]

# --run 2 (the default): the Xe10 froze at run 1's S02 before XE10Y /PKAB printed or wrote anything
# (no header on the card, the screen still on the S02 banner), straight after /K3M. Run 2 leaves
# out S00/S01 (captured), puts the A/B's safe part first, every risky part in a step of its own
# with the riskiest last, and ends with run 1's /K3M -> next-program order to reproduce the freeze.
# XE10Y now writes, commits (AH=68h) and flushes DOS's buffers (AH=0Dh) after every row and
# before every case, and the screen names each case as it starts.
STEPS2 = [
    ('XE10Y', '/PKAB /AB', 'PKAB_AB.TXT', 'the PEGC store A/B: both sequences and the factor rows'),
    ('XE10W', '/MISAL2', 'M2OLD.TXT', 'the MISAL2 kit binary again'),
    ('XE10X', '/RDLAT', 'RDOLD.TXT', 'the RDLAT kit binary again'),
    ('XE10Y', '/CELLS /NOAPER', 'CELLS.TXT', 'the class-table cells'),
    ('XE10Y', '/MISAL2 /RDLAT /REP 2', 'REP.TXT', 'MISAL2 and RDLAT twice'),
    ('XE10CG3', '/CG', 'CG.TXT', 'the CG window (read-only)'),
    ('XE10Y', '/PKAB /DRAIN', 'PKAB_D.TXT', 'the A/B with a drain read before every window'),
    ('XE10Y', '/PKAB /L1OFF', 'PKAB_N.TXT', 'the A/B with the L1 cache off'),
    ('XE10Y', '/CELLS /APER', 'APER.TXT', 'the 0xF00000 aperture'),
    ('XE10Y', '/K3M', 'K3M2.TXT', 'run 1 S01 again (fixed PIT/PIC restore)'),
    ('XE10Y', '/SELFTEST', 'SELF2.TXT', 'the program after /K3M (run 1 froze here)'),
]

# --run 3: run 2 found the cause (the CF card resets to its default 16 x 63 translation on IDENTIFY
# PACKET; docs/probes/XE10Y-XE10-K3M2.TXT) and that the aperture rows had set 0x043B bit 2, which
# puts plain RAM at 0xF00000 on the Xe10. Two short steps: the aperture with 0x043B as found, and
# /K3M /ATA (INITIALIZE DEVICE PARAMETERS after IDENTIFY PACKET), then a program that must still
# load from the card.
STEPS3 = [
    ('XE10Y', '/CELLS /APER', 'APER2.TXT', 'the 0xF00000 aperture, 0x043B as found'),
    ('XE10Y', '/K3M /ATA', 'KATA.TXT', 'IDENTIFY, IDENTIFY PACKET, the drive geometry put back'),
    ('XE10Y', '/SELFTEST', 'SELF3.TXT', 'the next program still loads from the card'),
]


def run_bat(steps, quick: bool) -> str:
    out = ['@ECHO OFF', 'REM KIT3: generated by tools/hwprobe/xe10kit3/mkkit3.py', '']
    for i, (com, args, res, what) in enumerate(steps):
        flag = 'S%02d' % i
        q = ' /QUICK' if quick and com.startswith('XE10') and com != 'XE10CG3' and args != '/SELFTEST' else ''
        if com == 'XE10CG3':
            cmd = f'{com} {args} > {res}'
        else:
            cmd = f'{com} {args}{q} /O {res}'
        out += [f'IF EXIST {flag}.FLG GOTO X{flag}',
                f'ECHO {flag}.FLG> {flag}.FLG',
                f'ECHO === KIT3 {flag} of {len(steps) - 1}: {what}',
                cmd,
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
    ap.add_argument('--xe10y', default=os.path.join(XE10T, 'xe10y.com'))
    ap.add_argument('--xe10w', default=os.path.join(XE10T, 'xe10w.com'))
    ap.add_argument('--xe10x', default=os.path.join(XE10T, 'xe10x.com'))
    ap.add_argument('--xe10cg3', default=os.path.join(os.path.dirname(HERE), 'xe10cfg', 'xe10cg3.com'))
    ap.add_argument('--run', type=int, choices=(1, 2, 3), default=2, help='the step list (run 1: the first image)')
    ap.add_argument('--quick', action='store_true', help='/QUICK on the XE10Y steps (the core side)')
    ap.add_argument('--work', default=None)
    a = ap.parse_args()
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1', MTOOLS_NO_VFAT='1')
    work = a.work or a.out + '.d'
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(os.path.join(work, KD))
    steps = list({1: STEPS1, 2: STEPS2, 3: STEPS3}[a.run])
    shutil.copy(a.xe10y, os.path.join(work, KD, 'XE10Y.COM'))
    shutil.copy(a.xe10cg3, os.path.join(work, KD, 'XE10CG3.COM'))
    shutil.copy(a.xe10w, os.path.join(work, KD, 'XE10W.COM'))
    shutil.copy(a.xe10x, os.path.join(work, KD, 'XE10X.COM'))
    texts = {'RUN.BAT': run_bat(steps, a.quick), 'DONE.TXT': done_txt(steps), 'README.TXT': README}
    for n, t in texts.items():
        open(os.path.join(work, KD, n), 'wb').write(crlf(t))
    open(os.path.join(work, 'CONFIG.SYS'), 'wb').write(crlf(CONFIG))
    open(os.path.join(work, 'AUTOEXEC.BAT'), 'wb').write(crlf(AUTOEXEC))
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
    sh('mcopy', '-s', '-i', img, os.path.join(work, KD), '::/', env=env)
    sh('mdir', '-i', img, '::/' + KD, env=env)
    h = hashlib.sha256(open(a.out, 'rb').read()).hexdigest()
    print(f'built {a.out} sha256 {h}')
    return 0


if __name__ == '__main__':
    sys.exit(main())

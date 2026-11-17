#!/usr/bin/env python3
"""mkxe10z.py - build the XE10Z kit's CF image for the real PC-9821Xe10.

    mkxe10z.py --base BASE.img --out KIT.img [--com xe10z.com]

BASE.img is an earlier kit's raw CF image (the Xe10 IDE BIOS layout: 8 heads x 17 sectors x 512
bytes, the DOS volume at cylinder 1 = byte 69632, the user's own NEC MS-DOS 6.20 with its system
files and \\DOS), for example the one tools/hwprobe/xe10kit/mkimg.sh writes. Every top-level folder
except DOS is removed, and CONFIG.SYS/AUTOEXEC.BAT are replaced by plain ones (no HIMEM, no EMM386,
no sound or MIDI driver). The image holds NEC's DOS, so it is NEVER committed.

The kit does NOT run by itself: the boot ends at the prompt in A:\\XE10Z, and the user types RUNZ
(XE10Z > XE10Z.TXT). README.TXT holds the steps. The same image boots on the core (step Z0), where
the probe is run the same way.
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
CD \XE10Z
ECHO XE10Z kit. Type RUNZ and wait for the prompt (about 1 minute).
ECHO The steps are in README.TXT (TYPE README.TXT).
'''

README = r'''XE10Z kit (v1): six small hardware questions, one program, about 1 minute.

1. Boot this CF card to plain DOS (this card's own CONFIG.SYS and
   AUTOEXEC.BAT load no drivers). If you have the MPU-PC98 MIDI card,
   fit it first, at the same I/O address as before (E0D0).
2. At the A:\XE10Z> prompt type RUNZ and press Enter. No other keys are
   needed. The screen stays quiet while it runs (about 40 s). When the
   prompt comes back it is finished; XE10Z.TXT should end "XE10Z DONE"
   (TYPE XE10Z.TXT).
3. Type TIME and DATE and check them. The program sets the clock chip
   several times and puts it back at the end (to the second). Set them
   again if they are wrong, and note it.
4. Reboot once and check that the SETUP menu settings are
   unchanged. The program changes a SETUP switch for a few
   microseconds and puts it back; this is only a check.
5. Bring back A:\XE10Z\XE10Z.TXT (or the whole CF card). If the program
   stops or the machine hangs, note where, reboot, and bring back
   XE10Z.TXT as it is.

What it does: shift instructions (CPU only), the DMA bank register 29h,
the software DIP switch store, the hard disk's READ NATIVE MAX command,
the MPU-PC98 clock messages (if fitted) and the calendar clock chip.
'''


def crlf(t: str) -> bytes:
    return t.replace('\r\n', '\n').replace('\n', '\r\n').encode('ascii')


def sh(*a, **k):
    subprocess.run(a, check=True, **k)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--com', default=os.path.join(HERE, 'xe10z.com'))
    a = ap.parse_args()
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1', MTOOLS_NO_VFAT='1')
    work = a.out + '.d'
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(os.path.join(work, 'XE10Z'))
    shutil.copy(a.com, os.path.join(work, 'XE10Z', 'XE10Z.COM'))
    with open(os.path.join(HERE, 'RUNZ.BAT'), 'rb') as f:
        runz = f.read()
    open(os.path.join(work, 'XE10Z', 'RUNZ.BAT'), 'wb').write(crlf(runz.decode('ascii')))
    open(os.path.join(work, 'XE10Z', 'README.TXT'), 'wb').write(crlf(README))
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
    sh('mcopy', '-s', '-i', img, os.path.join(work, 'XE10Z'), '::/', env=env)
    sh('mdir', '-i', img, '::/', env=env)
    sh('mdir', '-i', img, '::/XE10Z', env=env)
    h = hashlib.sha256(open(a.out, 'rb').read()).hexdigest()
    c = hashlib.sha256(open(a.com, 'rb').read()).hexdigest()
    print(f'built {a.out} sha256 {h}  XE10Z.COM sha256 {c}')
    return 0


if __name__ == '__main__':
    sys.exit(main())

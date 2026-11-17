#!/usr/bin/env python3
"""mkpcmkit.py - build the PCMKIT CF image for the real PC-9821Xe10: one boot, one batch for the
no-recording probes (PICROT, IDE640, PCMOVF stage 1, OPNAX /G, SHBANK, then OPNAX /J, the one step
that asks for input), and a second batch for PCMOVF stage 2 (the line-out recording).

    mkpcmkit.py --base BASE.img --out KIT.img

BASE.img is an earlier kit's raw CF image (the Xe10 IDE BIOS layout: 8 heads x 17 sectors x 512
bytes, the DOS volume at byte 69632, the user's own NEC MS-DOS 6.20 with \\DOS), for example the
XE10Z kit's image (tools/hwprobe/xe10z/mkxe10z.py). Every top-level folder except DOS is removed,
and CONFIG.SYS/AUTOEXEC.BAT are replaced by plain ones (no HIMEM, no EMM386, no sound driver).
The image holds NEC's DOS, so it is NEVER committed. The .COM files are taken from the tree
(`make -C tools/hwprobe` first). The same image boots on the core (run there first).
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
OFF = 69632
COMS = {"PCMOVF.COM": "pcm86ovf/pcmovf.com", "PICROT.COM": "picrot/picrot.com",
        "SHBANK.COM": "shbank/shbank.com", "OPNAX.COM": "opnax/opnax.com",
        "IDE640.COM": "ide640/ide640.com"}

CONFIG = 'FILES=20\nBUFFERS=8\nSHELL=A:\\COMMAND.COM A:\\ /P\n'

AUTOEXEC = r'''@ECHO OFF
PATH A:\;A:\DOS
CD \PCMKIT
ECHO PCMKIT. Type RUN (about 1 minute; one step at the end asks for the joystick).
ECHO Then, with the recorder ready, type RUNA (the audio recording, about 1 minute).
ECHO The steps are in README.TXT (TYPE README.TXT).
'''

README = r'''PCMKIT (v1): built-in sound (PCM FIFO, OPNA), interrupt controller,
ROM bank and IDE checks. One boot; two batches.

PART 1 - RUN (about 1 minute; the last step needs the joystick pad)
1. Boot this CF card to plain DOS (its own CONFIG.SYS and AUTOEXEC.BAT
   load no drivers). Connect the joystick pad to joystick port 1 if you
   have one.
2. At the A:\PCMKIT> prompt type RUN and press Enter. Steps 1-5 need no
   keys; the PCM step is quiet (no sound is played in part 1).
3. Step 6 asks for input on the screen:
     first prompt:  let go of every pad button and the stick, then press
                    SPACE on the keyboard;
     second prompt: HOLD pad button A (trigger 1) and keep holding it,
                    then press SPACE with the other hand; let go after
                    "done, you can let go".
   No pad: press Esc at the first prompt.
4. If the machine hangs at step 5 (SHBANK), power-cycle, boot the card
   again and type RUNJ (step 6 only). Note where it hung.

PART 2 - RUNA, the line-out recording (about 1 minute of sound)
The probe plays short, loud 2 kHz buzzing tones (about 2 seconds each,
two sets of nine, each set after three short "beeps"). Do not listen on
headphones at full volume.
1. Connect the Xe10's sound LINE OUT to the computer's LINE IN with a
   STEREO cable (left and right carry different signals: a mono cable or
   a mono recording cannot be decoded).
2. Recorder settings: STEREO, 44100 Hz or 48000 Hz, 16-bit or 24-bit,
   saved as an uncompressed WAV file. Turn OFF every automatic gain,
   noise suppression, "enhancement", limiter and compressor.
3. Level check first: type RUNA, let it play (the recorder may monitor
   without saving), and set the input level so the loudest parts peak
   around -6 dB (never 0 dB / clipping). The level must then stay fixed.
4. The take: start recording, type RUNA, press a key at its PAUSE, and
   let it run until RUNA prints "finished" (about 60 s); wait 2 more
   seconds, then stop. Do not touch the machine while it plays.
5. Name the file PCMAUD-XE10.WAV (if you record more than one take:
   PCMAUD-XE10-2.WAV, ...).

AFTERWARDS
- Reboot before using sound software (OPNAX leaves an OPNA register at
  its reset value). Check TIME and DATE (nothing here changes them).
- Bring back every .TXT file in A:\PCMKIT (PICROT, IDE640, PCMOVF,
  OPNAXG, SHBANK, OPNAXJ, PCMAUD) and the WAV file(s), or the whole card.
'''


def crlf(t: str) -> bytes:
    return t.replace('\r\n', '\n').replace('\n', '\r\n').encode('ascii')


def sh(*a, **k):
    subprocess.run(a, check=True, **k)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1', MTOOLS_NO_VFAT='1')
    work = a.out + '.d'
    shutil.rmtree(work, ignore_errors=True)
    kd = os.path.join(work, 'PCMKIT')
    os.makedirs(kd)
    sums = {}
    for dos, src in COMS.items():
        p = os.path.join(HW, src)
        if not os.path.exists(p):
            print('missing %s: make -C tools/hwprobe first' % p)
            return 1
        shutil.copy(p, os.path.join(kd, dos))
        sums[dos] = hashlib.sha256(open(p, 'rb').read()).hexdigest()
    for name in ('RUN.BAT', 'RUNJ.BAT', 'RUNA.BAT'):       # the batches beside this script
        with open(os.path.join(HERE, name)) as f:
            open(os.path.join(kd, name), 'wb').write(crlf(f.read()))
    open(os.path.join(kd, 'README.TXT'), 'wb').write(crlf(README))
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
    sh('mcopy', '-s', '-i', img, kd, '::/', env=env)
    sh('mdir', '-i', img, '::/PCMKIT', env=env)
    h = hashlib.sha256(open(a.out, 'rb').read()).hexdigest()
    print(f'built {a.out} sha256 {h}')
    for dos, s in sums.items():
        print(f'  {dos} sha256 {s}')
    return 0


if __name__ == '__main__':
    sys.exit(main())

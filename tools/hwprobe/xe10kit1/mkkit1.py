#!/usr/bin/env python3
"""mkkit1.py - build the 2026-11 Xe10 capture kit (part 1) and its CF image.

    mkkit1.py --base BASE.img --out KIT.img --xe10t XE10T.COM --fdwrite FDWRITE.COM
              --fdw BLANK12.FDW [--kitdir DIR]

BASE.img is an earlier kit's raw CF image (the Xe10 IDE BIOS layout, 8 heads x 17 sectors,
the DOS partition at byte 69632, booting the user's own NEC MS-DOS 6.20; see
tools/hwprobe/xe10kit/mkimg.sh). The image holds NEC's DOS, so it is NEVER committed; this
script and the batch texts below are the kit's source.

THE KIT RUNS ITSELF. AUTOEXEC.BAT stamps the boot (STAMP B) and calls RUN.BAT, a state machine
over the steps below: the first step whose flag file Snn.FLG does not exist is marked started
(the flag is written and closed BEFORE the step runs) and run; its batch ends with a time stamp
and a software reboot (RBOOT /Y: the reset Windows 95 uses, measured on the Xe10 in
docs/probes/RBOOT... captures, and the path the core's regression boot-loop uses), or, for
the three steps that measure the RESET BUTTON, with STAMP's PRESS RESET prompt. A step that
hangs is skipped after a power-cycle (its flag already exists). The owner powers on, watches,
presses RESET three times when told, inserts the floppy once, moves it once, and films one
block. DEL A:\\KIT1\\S*.FLG starts the sequence again.

Inputs that are build products of other lanes, copied as they are: XE10T.COM with /FDC2
(lane/xe10kit-fdc2: its decoder compares only captures of the same binary) and FDWRITE.COM
(lane/galf-xe10, the binary the Xe10 already ran); BLANK12.FDW is d88tofdw.py's container of a
PC-98 1.2 MB disk (77 x 2 x 8 x 1024) as NEC FORMAT makes it (NEC FORMAT B:, type 2, on an
empty 2HD D88 in NP2kai), with ONE byte changed: the boot sector's code entry (offset 0x3E,
where its EB 3C jump lands) is CB, a far return. NEC FORMAT's own non-system IPL prints "No
system files" and stops, so with that disk in drive 1 the machine would not boot the CF (seen on
the core, which runs the Xe10's own BIOS ROM); the BIOS takes the return from an IPL as "try the
next device" and boots the hard disk (the same core, the same ROM), so the floppy can stay in
its drive through every reboot.
The script builds the probes, writes KIT1/ (CRLF ASCII), copies BASE.img to KIT.img and with
mtools removes the old kit folders (KIT, W95, YM29, GALF), adds KIT1\\, AUTOEXEC.BAT and
MENU.TXT, and writes SHA256SUMS.TXT beside KIT.img.
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
    'XE10CFG.COM': 'xe10cfg/xe10cfg.com',
    'SELFMOD.COM': 'selfmod/selfmod.com',
    'YM29.COM': 'ym29/ym29.com',
    'OPNAPRO.COM': 'opnapro/opnapro.com',
    'PEGCRD.COM': 'pegcrd/pegcrd.com',
    'PROBE2.COM': 'probe2/probe2.com',
    'TXTMODE.COM': 'txtmode/txtmode.com',
    'GDCFIG.COM': 'gdcfig/gdcfig.com',
    'FDMODE.COM': 'fdmode/fdmode.com',
    'DMAROUTE.COM': 'dmaroute/dmaroute.com',
    'IDEPROBE.COM': 'ideprobe/ideprobe.com',
    'RBOOT.COM': 'rboot/rboot.com',
    'STAMP.COM': 'stamp/stamp.com',
    'GVDUMP.COM': 'gvdump/gvdump.com',
}


def check(marker: str, out: str) -> str:
    return (f'FIND "{marker}" {out} > NUL\n'
            f'IF ERRORLEVEL 1 ECHO    {out}  INCOMPLETE\n'
            f'IF NOT ERRORLEVEL 1 ECHO    {out}  ok\n')


def run(cmd: str, out: str, marker: str) -> str:
    return f'{cmd} > {out}\n' + check(marker, out)


CFG = 'XE10CFG DONE'
SOFT = 'soft'      # end: stamp + software reboot
RESET = 'reset'    # end: stamp + PRESS RESET prompt (Esc = software reboot)
STOP = 'stop'      # end: nothing (the last step)

# (title shown on screen, body, how the boot ends, why it is its own boot)
STEPS = [
    ('cold power-on: the CG RAM first, then the stores and the CPU',
     run('XE10CFG /CG', 'CG0.TXT', CFG) + run('XE10CFG', 'CFG0.TXT', CFG) + run('SELFMOD', 'SM.TXT', 'END:SELFMOD'),
     RESET, 'needs a cold power-on (items 94b/181: the CG RAM before any reset)'),
    ('after RESET 1: the CG RAM', run('XE10CFG /CG', 'CGR1.TXT', CFG), RESET,
     'item 181 asks what the RESET BUTTON does (all chips reset, not only the CPU)'),
    ('after RESET 2: the CG RAM', run('XE10CFG /CG', 'CGR2.TXT', CFG), RESET, 'the same'),
    ('after RESET 3: the CG RAM', run('XE10CFG /CG', 'CGR3.TXT', CFG), SOFT, 'the same'),
    ('after a software reboot: the CG RAM, then the /WR round trips',
     run('XE10CFG /CG', 'CGSW.TXT', CFG) + run('XE10CFG /WR', 'CFGWR.TXT', CFG), SOFT,
     'the CG RAM after the software reboot, compared with the RESETs'),
    ('sound: OPNAPRO (first touch), PEGCRD, YM29 v3',
     run('OPNAPRO', 'OPNA.TXT', 'OPNAPRO DONE') + run('PEGCRD', 'PEGCRD.TXT', 'END:PEGCRD') +
     run('YM29', 'YM29.TXT', 'END:YM29'), SOFT, 'OPNAPRO needs first-touch OPNA state; YM29 leaves 0x29 at 1F'),
    ('PROBE2 /GDC three times, PROBE2 /PIT, FDMODE (drives empty)',
     run('PROBE2 /GDC', 'GDC1.TXT', 'END:GDC') + run('PROBE2 /GDC', 'GDC2.TXT', 'END:GDC') +
     run('PROBE2 /GDC', 'GDC3.TXT', 'END:GDC') + run('PROBE2 /PIT', 'PIT.TXT', 'END:PIT') +
     run('FDMODE', 'FDMODE.TXT', 'AFTER SENSE'), SOFT, 'the PIT and floppy reads need a fresh boot'),
    ('XE10T /FDC2 with both floppy drives EMPTY (F1)',
     'XE10T /FDC2 /O FDC2B.TXT\n' + check('XE10T DONE', 'FDC2B.TXT'), SOFT,
     '/FDC2 resets the controller: a reboot after every run'),
    ('make the floppy: FDWRITE writes the PC-98 1.2 MB format (about 3 minutes)',
     'ECHO.\nECHO   *** PUT THE BLANK FLOPPY INTO DRIVE 1, then press a key ***\nECHO.\nPAUSE\n'
     'ECHO Writing the floppy (format, write, verify; about 3 minutes)...\n'
     'FDWRITE BLANK12.FDW 1 /Y > FDW.TXT\n'
     'IF ERRORLEVEL 1 FDWRITE BLANK12.FDW 1 /Y /NF > FDWNF.TXT\n'
     'FDWRITE BLANK12.FDW 1 /V /Y > FDWV.TXT\n'
     'IF ERRORLEVEL 1 ECHO    FDWV.TXT  the floppy did NOT verify\n'
     'IF NOT ERRORLEVEL 1 ECHO    FDWV.TXT  ok\n', SOFT, 'the floppy stays in drive 1 from here'),
    ('XE10T /FDC2 with the disk in drive 1 (F2)',
     'XE10T /FDC2 /O FDC2A.TXT\n' + check('XE10T DONE', 'FDC2A.TXT'), SOFT, 'a reboot after every /FDC2 run'),
    ('FDMODE with the disk in drive 1, DMAROUTE (reads the disk)',
     run('FDMODE', 'FDMODE1.TXT', 'AFTER SENSE') + run('DMAROUTE', 'DMAROUTE.TXT', 'END:DMAROUTE'), SOFT,
     'DMAROUTE switches memory windows: its own boot'),
    ('XE10T /FDC2 with the disk in drive 2 (F3)',
     'ECHO.\nECHO   *** MOVE THE FLOPPY FROM DRIVE 1 TO DRIVE 2, then press a key ***\nECHO.\nPAUSE\n'
     'XE10T /FDC2 /O FDC2C.TXT\n' + check('XE10T DONE', 'FDC2C.TXT'), SOFT, 'a reboot after every /FDC2 run'),
    ('the visual block: TXTMODE, GDCFIG (saved to GDCFIG.BIN), XE10T /RASTER - FILM IT',
     'ECHO.\nECHO   *** START FILMING THE SCREEN NOW (about 90 s), then press a key ***\nECHO.\nPAUSE\n'
     'TXTMODE /T > TXTMODE.TXT\nCLS\nGDCFIG < KEY.TXT\nGVDUMP GDCFIG.BIN\nCLS\n'
     'XE10T /RASTER /O RASTER.TXT\nCLS\n' + check('END:RASTER', 'RASTER.TXT') +
     'ECHO.\nECHO   *** STOP FILMING ***\n', SOFT, 'the display modes are restored by a reboot'),
    ('risky: XE10CFG /IDE (IDE bank select, CHECK POWER MODE)', run('XE10CFG /IDE', 'IDE1.TXT', CFG), SOFT,
     'moves the IDE bank select the CF itself sits behind'),
    ('risky: IDEPROBE', run('IDEPROBE', 'IDE.TXT', 'END:RESTORE'), SOFT, 'first-touch IDE state'),
    ('risky: XE10CFG /CGWR (one user glyph written and put back)', run('XE10CFG /CGWR', 'CGWR.TXT', CFG), SOFT,
     'writes the battery-backed CG RAM; checked after the reboot'),
    ('the CG RAM re-check after /CGWR', run('XE10CFG /CG', 'CGCHK.TXT', CFG), SOFT, 'after a reboot'),
    ('LAST: XE10CFG /W4A0, the EGC word read that froze the machine once',
     'ECHO If the screen stops here for more than 30 s the machine froze: that is a result.\n'
     'ECHO Then power off, wait 5 s, power on: the kit finishes by itself.\n' + run('XE10CFG /W4A0', 'W4A0.TXT', CFG),
     STOP, 'may freeze the machine: last'),
]


def step_bat(i: int, title: str, body: str, end: str) -> str:
    n = len(STEPS)
    t = f'@ECHO OFF\nREM step {i}: {title}\nCD \\KIT1\nECHO.\nECHO KIT STEP {i} of {n}: {title}\n' + body
    if end == SOFT:
        t += f'STAMP SW{i}\nRBOOT /Y\n'
    elif end == RESET:
        t += f'STAMP RST{i} /R\nRBOOT /Y\n'
    return t


def run_bat() -> str:
    n = len(STEPS)
    t = '@ECHO OFF\nREM the kit state machine: the first step without its flag runs; the flag is written first\n'
    for i in range(1, n + 1):
        t += f'IF NOT EXIST S{i:02d}.FLG GOTO B{i:02d}\n'
    t += 'GOTO DONE\n'
    for i in range(1, n + 1):
        t += (f':B{i:02d}\nECHO started > S{i:02d}.FLG\nECHO STEP {i:02d} >> RUNLOG.TXT\n'
              f'CALL B{i:02d}.BAT\nGOTO END\n')
    t += (':DONE\nECHO.\nECHO ****************************************************************\n'
          'ECHO   KIT 1 FINISHED. Take the floppy out of drive 2. Power off.\n'
          'ECHO   (Optional 640K pass: see README.TXT.)\n'
          'ECHO ****************************************************************\n:END\n')
    return t


def batches() -> dict:
    b = {f'B{i:02d}.BAT': step_bat(i, t, body, end) for i, (t, body, end, _) in enumerate(STEPS, 1)}
    b['RUN.BAT'] = run_bat()
    b['OPT640.BAT'] = ('@ECHO OFF\nREM optional: AFTER SETUP floppy mode = 640K (F4), disk in drive 1\nCD \\KIT1\n'
                       + run('XE10CFG /CG', 'CG640.TXT', CFG) + run('XE10CFG', 'CFG640.TXT', CFG) +
                       'ECHO   *** PUT THE FLOPPY INTO DRIVE 1, then press a key ***\nPAUSE\n'
                       'XE10T /FDC2 /M640 /O FDC2M.TXT\n' + check('XE10T DONE', 'FDC2M.TXT') +
                       'ECHO Now set SETUP back to the floppy mode you wrote down; boot; type OPTBACK\n')
    b['OPTBACK.BAT'] = ('@ECHO OFF\nREM optional: after SETUP was set back\nCD \\KIT1\n'
                        + run('XE10CFG /CG', 'CGBACK.TXT', CFG) + run('XE10CFG', 'CFGBACK.TXT', CFG) +
                        'ECHO Optional pass done. Power off.\n')
    b['KEY.TXT'] = ' '
    return b


def step_table() -> str:
    rows = []
    for i, (t, _, end, why) in enumerate(STEPS, 1):
        how = {SOFT: 'software reboot', RESET: 'YOU PRESS RESET', STOP: 'end'}[end]
        rows.append(f' {i:2d}  {t}\n       -> {how}; {why}')
    return '\n'.join(rows)


MENU = """XE10 KIT 1 (2026-11): it runs by itself (A:\\KIT1\\RUN.BAT, one step per boot).
Watch the screen: it tells you when to press RESET, insert or move the floppy,
or start the video. README.TXT has everything (TYPE A:\\KIT1\\README.TXT | MORE).
"""

README = """XE10 CAPTURE KIT 1 (2026-11-07) - it runs itself
====================================================

WHAT YOU NEED
- this CF card, fitted as for the earlier kits; the machine as found
  (SETUP: Sound "not used", the -86 board fitted, nothing else changed)
- ONE blank 3.5" HD floppy disk (any; it gets written in step 9)
- a phone to film the screen once (about 90 seconds)
- about 45 minutes, mostly waiting

WHAT YOU DO (everything else is automatic: the kit reboots the machine
itself between its 18 steps and writes every result to A:\\KIT1)
 1. Both floppy drives EMPTY. Power the machine OFF, wait 30 s, power ON.
 2. Three times the screen says  PRESS THE RESET BUTTON NOW : press RESET.
    (Press it promptly: the time from that message to the next boot is
    the boot time being measured. Nothing to write down.)
 3. When it says  PUT THE BLANK FLOPPY INTO DRIVE 1 : insert the disk as it
    is (do not touch the write-protect tab; the kit writes it once), press
    a key. Leave it in: the kit reboots with it in the drive.
 4. When it says  MOVE THE FLOPPY FROM DRIVE 1 TO DRIVE 2 : do that, press
    a key.
 5. When it says  START FILMING : start the phone video of the whole screen,
    press a key; stop when it says  STOP FILMING  (about 90 s).
 6. When it says  KIT 1 FINISHED : take the floppy out and power off.
 7. Send back the CF card (or every A:\\KIT1\\*.TXT and *.BIN file) and the
    video.

IF SOMETHING HANGS (the screen does not change for 2 minutes): power off,
wait 5 s, power on. The kit skips the step that hung and goes on; the hang
is itself a result. The last step may freeze the machine on purpose.

OPTIONAL, AT THE END (5 minutes): enter SETUP (HELP held at power-on),
WRITE DOWN the floppy disk mode shown, set it to 640K, save, boot with the
drives empty, type  OPT640  (it asks for the floppy in drive 1). Then set
SETUP back to the mode you wrote down, boot, type  OPTBACK . Send back the
mode you wrote down.

THE STEPS (why a step ends with a RESET or a software reboot)
""" + step_table() + """

SAFETY
- Nothing writes to the hard disk except the result files.
- The floppy is written once (step 9: format, write, verify); every later
  step only reads it.
- Every probe puts back what it changes; the reboots clean up the rest.
- To start the whole sequence again: DEL A:\\KIT1\\S*.FLG
"""

AUTOEXEC = '@ECHO OFF\nPATH A:\\DOS;A:\\;A:\\KIT1\nCD \\KIT1\nSTAMP B\nTYPE A:\\MENU.TXT\nCALL RUN.BAT\n'


def crlf(t: str) -> bytes:
    t = t.replace('\r\n', '\n').replace('\n', '\r\n')
    b = t.encode('ascii')
    return b


def sh(*a, **k):
    return subprocess.run(list(a), check=True, **k)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--kitdir')
    ap.add_argument('--xe10t', required=True)
    ap.add_argument('--fdwrite', required=True)
    ap.add_argument('--fdw', required=True)
    a = ap.parse_args()
    out = os.path.abspath(a.out)
    kitdir = os.path.abspath(a.kitdir or os.path.join(os.path.dirname(out), 'kit'))
    sh('make', '-C', HW, *COMS.values())
    shutil.rmtree(kitdir, ignore_errors=True)
    k1 = os.path.join(kitdir, 'KIT1')
    os.makedirs(k1)
    for dosname, src in COMS.items():
        shutil.copyfile(os.path.join(HW, src), os.path.join(k1, dosname))
    shutil.copyfile(a.xe10t, os.path.join(k1, 'XE10T.COM'))
    shutil.copyfile(a.fdwrite, os.path.join(k1, 'FDWRITE.COM'))
    shutil.copyfile(a.fdw, os.path.join(k1, 'BLANK12.FDW'))
    for name, text in batches().items():
        open(os.path.join(k1, name), 'wb').write(crlf(text))
    open(os.path.join(k1, 'README.TXT'), 'wb').write(crlf(README))
    open(os.path.join(kitdir, 'MENU.TXT'), 'wb').write(crlf(MENU))
    open(os.path.join(kitdir, 'AUTOEXEC.BAT'), 'wb').write(crlf(AUTOEXEC))
    shutil.copyfile(a.base, out)
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    img = f'{out}@@{OFF}'
    listing = subprocess.run(['mdir', '-b', '-i', img, '::/'], env=env, capture_output=True, text=True).stdout
    for d in ('KIT', 'W95', 'YM29', 'GALF'):
        if f'::/{d}/' in listing or f'::/{d}' in listing.split():
            sh('mdeltree', '-i', img, f'::/{d}', env=env)
    sh('mcopy', '-o', '-i', img, os.path.join(kitdir, 'AUTOEXEC.BAT'), os.path.join(kitdir, 'MENU.TXT'), '::/', env=env)
    sh('mcopy', '-s', '-i', img, k1, '::/', env=env)
    sums = []
    for root, _, files in os.walk(kitdir):
        for f in sorted(files):
            p = os.path.join(root, f)
            sums.append((hashlib.sha256(open(p, 'rb').read()).hexdigest(), os.path.relpath(p, os.path.dirname(out))))
    sums.append((hashlib.sha256(open(out, 'rb').read()).hexdigest(), os.path.basename(out)))
    with open(os.path.join(os.path.dirname(out), 'SHA256SUMS.TXT'), 'w') as f:
        for h, p in sorted(sums, key=lambda x: x[1]):
            f.write(f'{h}  {p}\n')
    print(f'kit {kitdir}, image {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())

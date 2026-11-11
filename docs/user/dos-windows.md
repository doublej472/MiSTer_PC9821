# DOS and Windows 95

Setting up NEC MS-DOS on a new hard disk, the `CONFIG.SYS` and `AUTOEXEC.BAT` lines the core
needs, and the PC-98 version of Windows 95. The drivers named here come with NEC MS-DOS or with the
software that uses them. Which drivers and memory managers each tested title needs is in the
[compatibility list](compatibility.md#dos-utilities-and-drivers).

## Setting up DOS on a new hard disk

Checked with NEC MS-DOS 6.20.

1. Make a blank image on a computer: `python3 tools/pc98_hdd_convert.py --new 500 NEW.img`
   ([sizes](images.md#making-a-new-hard-disk)) and copy it to the SD card.
2. **Mount HDD** the new image and **Mount FDD1** an NEC MS-DOS boot floppy with `FORMAT.EXE`.
3. Run `FORMAT`, choose the fixed disk (固定ディスク, listed as `1: 固定ディスク #1`) and confirm.
4. Choose initialize (初期化), then allocate (領域確保): accept the size and start cylinder, keep
   "transfer the system" (システム: 転送する) and run it (実行).
5. Leave `FORMAT` (Esc, then yes) and restart. Booted from the floppy, the hard disk is C:; copy
   files to it.
6. Eject the floppy and reset: DOS starts from the hard disk, now A:. Without `CONFIG.SYS` and
   `AUTOEXEC.BAT` it asks for the date and time first.

## CONFIG.SYS and AUTOEXEC.BAT

With this configuration the hard disk is `A:` and the CD is `Q:`:

```
REM CONFIG.SYS
DOS=HIGH
DEVICE=A:\DOS\HIMEM.SYS
DEVICE=A:\DOS\EMM386.EXE /UMB
DEVICE=A:\DOS\NECCD.SYS /D:CD_101
LASTDRIVE=Z

REM AUTOEXEC.BAT
LH A:\DOS\MSCDEX.EXE /D:CD_101 /L:Q
```

- **Memory:** `HIMEM.SYS` is needed by almost everything. `EMM386.EXE /UMB` (NEC MS-DOS 6.2)
  provides EMS and upper memory. `VEM486.EXE /U` also works (plain `/U`: an address range after
  it stops VEM486 with a general protection error); software needing EMS under it also needs
  `VEMEMM.SYS`. NEC's `EMM.SYS` works, but `EMM386.EXE /UMB` is preferred. A DOS extender that
  refuses to run in virtual-86 mode needs a boot with `HIMEM.SYS` only.
- **CD-ROM:** `NECCD.SYS` with `MSCDEX.EXE` as above (the `/D:` name must match on both lines).
  `NECCDD.SYS`, `NECCDM.SYS` and the Oak OTI-011 driver also work. `PATACD.SYS` reads files and
  plays CD audio but rejects some direct driver calls. While a CD audio track plays, `NECCD.SYS`
  refuses file reads (`CDR101: Not ready`), as on the real machine.
- **Mouse:** `QMOUSE` works; some games read the mouse directly and need no driver.

## Playing a CD title

1. Convert a CUE/BIN or CloneCD set to `.pcd` ([Converting CD images](images.md#converting-cd-images));
   an `.iso` needs no conversion.
2. Boot DOS from the hard disk with the CD driver and `MSCDEX` loaded (above).
3. **Mount CD-ROM** the image; mounting or ejecting a CD does not restart the machine.
4. Start the title from its drive letter (`Q:` above).

The OSD's **IDE bank 1** must be `CD-ROM` (the default). CD audio has its own level on the OSD's
Audio page.

## Windows 95

The PC-98 version of Windows 95, installed on the hard-disk image, runs with the memory lines from
[CONFIG.SYS and AUTOEXEC.BAT](#configsys-and-autoexecbat) (`HIMEM.SYS` and `EMM386.EXE /UMB`) in
`CONFIG.SYS`. The 640x480 and 640x400 256-colour and the 640x400 16-colour display drivers work
(with the 640x400 256-colour one Windows shows its own display-settings message). Restart, Shut
down, and MS-DOS mode (with `exit` back to Windows) work.

**If `CONFIG.SYS` loads `NECCDM.SYS`**, add it to Windows' safe list, or the first access to a
720 KB floppy hangs Windows (a real Xe10 does the same): open `C:\WINDOWS\IOS.INI`, add the line
`NECCDM.SYS` under `[SafeList]`, and restart. The CD-ROM keeps working.

@ECHO OFF
REM RUNXE.BAT - run XE10T, the unified timing probe. XE10T.COM writes XE10T.TXT itself.
REM   RUNXE                    every media-free section (/ALL), about a minute
REM   RUNXE /FDC DA 91 /CD     the opt-in media sections (a readable 2HD disk in 0x91)
REM   CLS, then RUNXE /RASTER  the visual palette-timing picture (photograph each phase)
REM   RUNXE /SELFTEST          the internal checks;  RUNXE /DRY  the plan only
REM   RUNXE /ALL /SKIP IO      bypass a section;  RUNXE /ALL /FROM IRQ  resume after one
REM   RUNXE /OPNA2 /O OPNA2.TXT  the sound-chip section (opt-in; no sound driver loaded).
REM     Write the BIOS setup's built-in sound setting (enabled/disabled) in the run notes.
REM   RUNXE /OPNA3 /O OPNA3.TXT  rhythm writes back to back (silent; no sound driver loaded).
REM   RUNXE /OPNA3 /LISTEN /O OPNA3L.TXT  the same, then 3 labelled phases of bass-drum hits:
REM     write in the run notes whether PHASE 2 was as loud as PHASE 1, and PHASE 3.
REM   RUNXE /OPNA3 /SWEEP /O OPNA3S.TXT  the gap sweep: 20 numbered steps of 4 bass-drum hits,
REM     about 45 s; write down the first STEP whose hits were LOUD (and any quiet one after it).
REM     RUNXE /OPNA3 /SWEEP /STEP 7 /TO 9 /O OPNA3S2.TXT  repeats steps 7-9 only.
REM   RUNXE /AUDIT /O AUDIT.TXT  word reads, open ports, IRQ0/IRQ15/cascade lines (opt-in;
REM     no sound driver, no key presses while it runs, about 20 s).
REM   RUNXE /FDC2 /O FDC2A.TXT  the floppy controller rows (todo 59/162/164/165/176/177),
REM     about 30 s; disks inserted only at the DOS prompt, READ commands only; reboot after.
REM   RUNXE /FDC2 /M640 /O FDC2M.TXT  the 640K-mode rows (SETUP floppy disk mode 640K).
REM XE10U.COM (the kit-2 build of the same source): XE10U /OPNA4 /O OPNA4.TXT (timer start
REM   after an FM burst, silent) and XE10U /AUDIT2 /O AUDIT2.TXT (IRQ15 line, word OUT); reboot after.
REM COMMAND.COM splits batch arguments at "=", so XE10T also takes "/TAG xe10" and "DA 91".
IF "%1"=="" GOTO ALL
XE10T %1 %2 %3 %4 %5 %6 %7 %8 %9
GOTO END
:ALL
XE10T /ALL
:END

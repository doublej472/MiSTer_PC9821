@ECHO OFF
REM RUNYM29 - YM29 v3: does YM2608 register 0x29 (the IRQ enable) gate the
REM Timer A and Timer B IRQs, bit by bit? v3 adds the register read map, the
REM 0x29 read around each write and 2 s IRR histograms (masked, as found).
REM
REM Copy YM29.COM and this file to the machine, then:
REM     RUNYM29
REM and send back YM29.TXT.
REM
REM Run from a freshly booted plain DOS prompt (no sound driver loaded). The
REM probe takes about 10 seconds and makes no sound. It writes OPNA registers
REM 0x24-0x27/0x29, the INT 14h vector and the PIC masks, and puts them
REM back (the RESTORE line proves it); 0x29 is left at its reset value 1F,
REM so REBOOT before running anything else. The disk is only written by the
REM redirection below.

IF NOT EXIST YM29.COM GOTO NOPROG

ECHO Running the YM2608 0x29 timer-IRQ probe (v3, Timers A and B)...
YM29 > YM29.TXT

FIND "END:YM29" YM29.TXT > NUL
IF ERRORLEVEL 1 ECHO    YM29.TXT  INCOMPLETE - no END:YM29 marker
IF NOT ERRORLEVEL 1 ECHO    YM29.TXT  ok
ECHO Send YM29.TXT back. Decode with: python3 tools/hwprobe/ym29/ym29_decode.py YM29.TXT
ECHO Now reboot the machine.
GOTO END

:NOPROG
ECHO YM29.COM is not in this directory.
ECHO Copy YM29.COM here first, then run RUNYM29 again.

:END

@ECHO OFF
REM RUNPEGC - the PEGC 256-colour palette read-back.
REM
REM Copy PEGCRD.COM and this file to the machine, then:
REM     RUNPEGC
REM and send back PEGCRD.TXT.
REM
REM Run from a freshly booted plain DOS prompt (0x6A = 00 there). The probe
REM changes display modes for a second: the screen may change colour or go
REM blank, which is why stdout MUST go to a file. It restores the modes and
REM the 16-colour power-on palette; the screen may stay at the restored
REM digital mode. The disk is never written (INT 21h AH=02/4C only).

IF NOT EXIST PEGCRD.COM GOTO NOPROG

ECHO Running the PEGC palette read-back...
PEGCRD > PEGCRD.TXT

FIND "END:PEGCRD" PEGCRD.TXT > NUL
IF ERRORLEVEL 1 ECHO    PEGCRD.TXT  INCOMPLETE - no END:PEGCRD marker
IF NOT ERRORLEVEL 1 ECHO    PEGCRD.TXT  ok
ECHO Send PEGCRD.TXT back. Decode with: python3 tools/hwprobe/pegcrd/pegcrd_decode.py PEGCRD.TXT
GOTO END

:NOPROG
ECHO PEGCRD.COM is not in this directory.
ECHO Copy PEGCRD.COM here first, then run RUNPEGC again.

:END

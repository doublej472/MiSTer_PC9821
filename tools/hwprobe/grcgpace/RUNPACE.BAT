@ECHO OFF
REM RUNPACE - the walk-bound GRCG store shapes (16- and 32-bit), 3 runs each.
REM
REM Copy GRCGPACE.COM and this file to the machine, then:
REM     RUNPACE
REM and send back GRCGPACE.TXT.
REM
REM Run from a freshly booted plain DOS prompt, no EMM386. The probe writes
REM the GVRAM plane-0 window 0xA8000-0xAFFFF only: redirect stdout, because
REM the screen may change. It leaves the GRCG off and restores the EGC bit.
REM The disk is never written (INT 21h AH=02/4C only).

IF NOT EXIST GRCGPACE.COM GOTO NOPROG

ECHO Running the GRCG store-pace measurement...
GRCGPACE > GRCGPACE.TXT

FIND "END:GRCGPACE" GRCGPACE.TXT > NUL
IF ERRORLEVEL 1 ECHO    GRCGPACE.TXT  INCOMPLETE - no END:GRCGPACE marker
IF NOT ERRORLEVEL 1 ECHO    GRCGPACE.TXT  ok
ECHO Send GRCGPACE.TXT back. Decode with: python3 tools/hwprobe/grcgpace/grcgpace_decode.py GRCGPACE.TXT
GOTO END

:NOPROG
ECHO GRCGPACE.COM is not in this directory.
ECHO Copy GRCGPACE.COM here first, then run RUNPACE again.

:END

@ECHO OFF
REM RUNGFXB.BAT - collect the raw-window GVRAM/TRAM bandwidth comparator.
REM
REM Copy GFXBENCH.COM and this file to the machine, then:
REM     RUNGFXB
REM and send back GFXB.TXT.
REM
REM Run it on the reference Xe10 (100 MHz): its GVRAM0(A8000) WRITE row refreshes
REM the plain-fill anchor (the legacy 13.8 MB/s = 0.145 us/word has no archived
REM capture and no named machine). The output MUST be redirected: the TRAM
REM window is the visible console and is scribbled by the fill. The GVRAM is
REM scribbled by design. The disk is never written (INT 21h AH=02/4C only).
REM
REM Decode with: python3 tools/hwprobe/gfxbench/gfxbench_decode.py GFXB.TXT

IF NOT EXIST GFXBENCH.COM GOTO NOPROG

ECHO Running the raw-window bandwidth comparator (a few seconds)...
GFXBENCH > GFXB.TXT

FIND "END:GFXBENCH" GFXB.TXT > NUL
IF ERRORLEVEL 1 ECHO    GFXB.TXT  INCOMPLETE - no END:GFXBENCH marker
IF NOT ERRORLEVEL 1 ECHO    GFXB.TXT  ok
ECHO Send GFXB.TXT back. Decode with:
ECHO    python3 tools/hwprobe/gfxbench/gfxbench_decode.py GFXB.TXT
GOTO END

:NOPROG
ECHO GFXBENCH.COM is not in this directory.
ECHO Copy GFXBENCH.COM here first, then run RUNGFXB again.

:END

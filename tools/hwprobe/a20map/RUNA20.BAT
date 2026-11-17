@ECHO OFF
REM ============================================================
REM  A20MAP - does the A20 mask clear ONLY address bit 20, or wrap
REM  everything into the first MiB?  Copy A20MAP.COM + this file to a
REM  PLAIN DOS disk (no EMM386/VEM486; HIMEM.SYS is fine) and run: RUNA20
REM  Run it on the Xe10 and on the core, then compare the two captures.
REM  WRITES: A20 (0xF2/0xF6, restored), CPU cache/CR0 (restored), the
REM  PIC masks (restored), and up to six dwords at X+0/1/2/3/16/17 MiB
REM  (each saved first and restored). Do not run under a V86 manager.
REM ============================================================

IF NOT EXIST A20MAP.COM GOTO NOPROG
ECHO Running A20MAP...
A20MAP > A20MAP.TXT
IF ERRORLEVEL 1 GOTO REFUSED
ECHO.
ECHO Done. Send back A20MAP.TXT (its last VERDICT line is the answer).
GOTO END

:REFUSED
ECHO.
ECHO A20MAP refused to run; nothing was measured. Its reason:
TYPE A20MAP.TXT
GOTO END

:NOPROG
ECHO A20MAP.COM is not in this directory.
ECHO Copy A20MAP.COM here first, then run RUNA20 again.

:END

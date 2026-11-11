@ECHO OFF
REM ============================================================
REM  MPUTEST - MPU-401-family MIDI card probe (MPU-PC98/II)
REM  Copy MPUTEST.COM + this file to a DOS disk. Run:
REM     RUNMPU          detect, measure, play the labelled
REM                     sequences (about 75 s), then RAW
REM     RUNMPU BYTES    the fixed /BYTES table only (stage A)
REM  Send back MPUTEST.TXT (and MPUBYTES.TXT for BYTES).
REM  Plain DOS, no MIDI driver resident. ESC during a pause
REM  skips the rest of the music and goes to the closing reset.
REM ============================================================

IF NOT EXIST MPUTEST.COM GOTO NOPROG
IF "%1"=="BYTES" GOTO BYTES
IF "%1"=="bytes" GOTO BYTES

MPUTEST /RAW /O:MPUTEST.TXT
FIND "MPUTEST DONE" MPUTEST.TXT > NUL
IF ERRORLEVEL 1 GOTO INCOMPLETE
ECHO MPUTEST DONE. Send MPUTEST.TXT back.
GOTO END

:BYTES
MPUTEST /BYTES /O:MPUBYTES.TXT
FIND "MPUTEST DONE" MPUBYTES.TXT > NUL
IF ERRORLEVEL 1 GOTO INCOMPLETE
ECHO MPUTEST /BYTES DONE. Send MPUBYTES.TXT and the wire capture back.
GOTO END

:INCOMPLETE
ECHO INCOMPLETE: no "MPUTEST DONE" - the last BEGIN: line with no
ECHO END: names the section that hung. Power-cycle and send the file.
GOTO END

:NOPROG
ECHO MPUTEST.COM is not in this directory.

:END

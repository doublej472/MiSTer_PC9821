@ECHO OFF
REM ============================================================
REM  PC-9821 OPNA / PC-9801-86 sound-register read-back probe
REM  (the 0x18E A/D read and the register read-back: docs/probes/OPNA.TXT)
REM  Copy OPNAPRO.COM + this file to a DOS disk. Run:  RUNOPNA
REM  Send back OPNA.TXT (or the last BEGIN: marker on screen).
REM
REM  RUN IT FROM A FRESHLY BOOTED DOS PROMPT: the SETUP block is
REM  the as-found (first-touch) port state, and anything that
REM  writes a register destroys it.
REM
REM  WHAT IT ANSWERS
REM    0x18E after 0x18C=0F: the YM2608 A/D register.
REM        qemu = the constant 80, NP2kai = the register shadow.
REM    0x18A after 0x188=08 and after 0x188=0F: the register
REM        shadow vs the ADPCM-B data bus.
REM    status-2 (0x18C) TIMER bits vs the extended register 0110
REM        flag mask: qemu masks them, NP2kai does not.
REM
REM  Every section is bracketed BEGIN:<name> / END:<name>, so a
REM  hang is the section with no END: and the ones before it are
REM  still valid. Power-cycle after a hang and send OPNA.TXT.
REM  The probe restores 0xA460 and the 8259 slave IMR exactly; the
REM  four write-only host ports are left in the neutral select 00 /
REM  data 00 state egcport.com leaves. See the RESTORE block.
REM  No disk access (INT 21h AH=02/09/4C only).
REM ============================================================

IF NOT EXIST OPNAPRO.COM GOTO NOPROG

ECHO Running OPNAPRO (about a second)...
OPNAPRO > OPNA.TXT

ECHO.
FIND "OPNAPRO DONE" OPNA.TXT > NUL
IF ERRORLEVEL 1 GOTO INCOMPLETE
ECHO OPNAPRO DONE - every section completed.
ECHO Send OPNA.TXT back.
GOTO END

:INCOMPLETE
ECHO INCOMPLETE - the capture has no "OPNAPRO DONE", so a section hung.
FIND "END:SETUP" OPNA.TXT > NUL
IF ERRORLEVEL 1 ECHO    missing END:SETUP     - hung in SETUP
FIND "END:CHIPID" OPNA.TXT > NUL
IF ERRORLEVEL 1 ECHO    missing END:CHIPID   - hung in CHIPID
FIND "END:EXT0F" OPNA.TXT > NUL
IF ERRORLEVEL 1 ECHO    missing END:EXT0F    - hung in EXT0F
FIND "END:BASE08" OPNA.TXT > NUL
IF ERRORLEVEL 1 ECHO    missing END:BASE08   - hung in BASE08
FIND "END:STATUS2" OPNA.TXT > NUL
IF ERRORLEVEL 1 ECHO    missing END:STATUS2  - hung in STATUS2
FIND "END:RESTORE" OPNA.TXT > NUL
IF ERRORLEVEL 1 ECHO    missing END:RESTORE  - hung in RESTORE
ECHO The BEGIN:/END: pairs before the missing one are still valid.
ECHO Power-cycle the machine and send OPNA.TXT.
GOTO END

:NOPROG
ECHO OPNAPRO.COM is not in this directory.
ECHO Copy OPNAPRO.COM here first, then run RUNOPNA again.

:END

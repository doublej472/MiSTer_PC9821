@ECHO OFF
REM ============================================================
REM  PC-9821 real-machine IDE READ latency probe  (th5-ide targets)
REM  Copy IDELAT.COM + this file to a DOS disk. Run:  RUNLAT
REM  Send back IDELAT.TXT (or the raw capture if a section hung).
REM
REM  IDELAT measures the numbers the core's IDE path should aim for:
REM    SETUP    bank + PIT telemetry + IDENTIFY geometry (read-only)
REM    CAL      the status-poll cost shape (one bare status read vs
REM             one full poll-loop iteration), the word-read cost,
REM             the timestamp overhead, and the 005F anchor
REM    READN    READ SECTORS count=N (1 command, N sectors): command
REM             issue -> first DRQ, per-sector DRQ gap and transfer
REM    READ1    READ SECTORS count=1: cold singles + warm re-reads
REM    RESTORE  the 0432 bank byte back + the write ledger
REM
REM  READ-ONLY on disk: the only ATA commands are IDENTIFY 0xEC and
REM  READ SECTORS 0x20 on cylinder 0 / head 0 / sectors 1..S (one
REM  track).  Nothing is written to the disk.
REM
REM  Every section prints BEGIN:<name> / END:<name>, so a section
REM  that hangs is the one with no END: and the capture before it is
REM  still valid.  Power-cycle, then send IDELAT.TXT.
REM
REM  Decode it with:
REM    python3 tools/hwprobe/idelat/idelat_decode.py IDELAT.TXT
REM ============================================================

IF NOT EXIST IDELAT.COM GOTO NOPROG

ECHO Running IDELAT (a section that hangs leaves BEGIN: with no END:)...
IDELAT > IDELAT.TXT

ECHO.
ECHO Section completion:
FIND "END:SETUP"   IDELAT.TXT > NUL
IF ERRORLEVEL 1 ECHO    SETUP   INCOMPLETE - no END:SETUP marker
IF NOT ERRORLEVEL 1 ECHO    SETUP   ok
FIND "END:CAL"     IDELAT.TXT > NUL
IF ERRORLEVEL 1 ECHO    CAL     INCOMPLETE - no END:CAL marker
IF NOT ERRORLEVEL 1 ECHO    CAL     ok
FIND "END:READN"   IDELAT.TXT > NUL
IF ERRORLEVEL 1 ECHO    READN   INCOMPLETE - no END:READN marker
IF NOT ERRORLEVEL 1 ECHO    READN   ok
FIND "END:READ1"   IDELAT.TXT > NUL
IF ERRORLEVEL 1 ECHO    READ1   INCOMPLETE - no END:READ1 marker
IF NOT ERRORLEVEL 1 ECHO    READ1   ok
FIND "END:RESTORE" IDELAT.TXT > NUL
IF ERRORLEVEL 1 ECHO    RESTORE INCOMPLETE - no END:RESTORE marker
IF NOT ERRORLEVEL 1 ECHO    RESTORE ok

ECHO.
ECHO Send IDELAT.TXT back. Decode it with:
ECHO    python3 tools/hwprobe/idelat/idelat_decode.py IDELAT.TXT
ECHO If a section hung, the capture up to that section is still valid.
GOTO END

:NOPROG
ECHO IDELAT.COM is not in this directory.
ECHO Copy IDELAT.COM here first, then run RUNLAT again.

:END

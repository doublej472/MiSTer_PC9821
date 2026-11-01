@ECHO OFF
REM ============================================================
REM  PC-9821 real-machine IDE/ATA probe
REM  Copy IDEPROBE.COM + this file to a DOS disk. Run:  RUNIDE
REM  Send back IDE.TXT (or the raw capture if a section hung).
REM
REM  IDEPROBE measures the machine's own IDE/ATA behaviour so the
REM  core's pc9821_ata.sv can be diffed against it:
REM    PORTMAP  the 0432 bank behaviour (the core gates the block on
REM             bit 7; the machine answers with bit 7 CLEAR)
REM    REG      the task-file register read-back
REM    TIME     the I/O wait-state per IDE port (base vs the 005F
REM             600 ns reference, so the core's class table can be
REM             checked)
REM    IDENTIFY the ATA IDENTIFY response, all 256 words
REM    RECAL    the RECALIBRATE 0x10 status sequence
REM    IRQ      the PIC mask/IRR/ISR and whether IRQ9 is asserted
REM
REM  Run it from a freshly booted prompt: the 0432 line and the
REM  task-file dump are first-touch state and only first touch once
REM  per boot. Every section prints BEGIN:<name> / END:<name>, so a
REM  section that hangs is the one with no END: and the capture
REM  before it is still valid. Power-cycle, then send IDE.TXT.
REM ============================================================

IF NOT EXIST IDEPROBE.COM GOTO NOPROG

ECHO Running IDEPROBE (a section that hangs leaves BEGIN: with no END:)...
IDEPROBE > IDE.TXT

ECHO.
ECHO Section completion:
FIND "END:PORTMAP"  IDE.TXT > NUL
IF ERRORLEVEL 1 ECHO    PORTMAP   INCOMPLETE - no END:PORTMAP marker
IF NOT ERRORLEVEL 1 ECHO    PORTMAP   ok
FIND "END:REG"      IDE.TXT > NUL
IF ERRORLEVEL 1 ECHO    REG       INCOMPLETE - no END:REG marker
IF NOT ERRORLEVEL 1 ECHO    REG       ok
FIND "END:TIME"     IDE.TXT > NUL
IF ERRORLEVEL 1 ECHO    TIME      INCOMPLETE - no END:TIME marker
IF NOT ERRORLEVEL 1 ECHO    TIME      ok
FIND "END:IDENTIFY" IDE.TXT > NUL
IF ERRORLEVEL 1 ECHO    IDENTIFY  INCOMPLETE - no END:IDENTIFY marker
IF NOT ERRORLEVEL 1 ECHO    IDENTIFY  ok
FIND "END:RECAL"    IDE.TXT > NUL
IF ERRORLEVEL 1 ECHO    RECAL     INCOMPLETE - no END:RECAL marker
IF NOT ERRORLEVEL 1 ECHO    RECAL     ok
FIND "END:IRQ"      IDE.TXT > NUL
IF ERRORLEVEL 1 ECHO    IRQ       INCOMPLETE - no END:IRQ marker
IF NOT ERRORLEVEL 1 ECHO    IRQ       ok
FIND "END:RESTORE"  IDE.TXT > NUL
IF ERRORLEVEL 1 ECHO    RESTORE   INCOMPLETE - no END:RESTORE marker
IF NOT ERRORLEVEL 1 ECHO    RESTORE   ok

ECHO.
ECHO Send IDE.TXT back. Decode it with:
ECHO    python3 tools/hwprobe/ideprobe/ideprobe_decode.py IDE.TXT
ECHO If a section hung, the capture up to that section is still valid.
GOTO END


:NOPROG
ECHO IDEPROBE.COM is not in this directory.
ECHO Copy IDEPROBE.COM here first, then run RUNIDE again.

:END

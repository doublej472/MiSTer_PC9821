@ECHO OFF
REM ============================================================
REM  RUNPEGC.BAT - which half of PEGC does DOOM actually need?
REM
REM  Copy PEGCW.COM and this file into the DIRECTORY HOLDING THE
REM  GAME (DOS resolves the child from the current directory), then:
REM
REM     RUNPEGC DOOM.EXE
REM     RUNPEGC DOOM2.EXE
REM
REM  and send back PEGC.TXT (copy it OFF the machine before rebooting).
REM  Run from a FRESHLY BOOTED prompt, one wrapped game per boot, and give
REM  the game as long as it takes to reach its title screen / a level - the
REM  mode set happens at start-up, but the in-level state is what the plane
REM  sampling needs time to see.
REM
REM  WHAT IT DOES. PEGCWATCH is an EXEC wrapper: it hooks INT 18h (the BIOS
REM  graphics entry) and INT 1Ch (the BIOS tick), chains both, runs the game
REM  byte-identical to a direct load, and prints the PEGC state it found, the
REM  state it left, and every change in between. It writes NOTHING to disk
REM  (stdout only), patches nothing in the child, and restores every vector
REM  it touched - the PEGCWATCH VEC rows are the as-found -> read-back proof.
REM
REM  READ PEGC.TXT FOR THESE THREE LINES FIRST:
REM    PEGCWATCH END V=1        present = the wrapper and the game both finished
REM    PEGCWATCH POST ...       A0A=01 means the game DID enter PEGC 256-colour
REM                             (A0A=00 means it did not, and nothing else in
REM                             the file will settle the question)
REM    PEGCWATCH SAMP ...       VIEWON= is how many samples were taken with the
REM                             PEGC registers visible. VIEWON=0000 with a
REM                             game that DID set 256-colour means the plane
REM                             engine question was NOT observed - say so in the
REM                             report, do not read it as "the engine is unused".
REM
REM  Decode on the host:
REM     python3 tools/hwprobe/pegcwatch/pegcwatch_decode.py PEGC.TXT
REM  It prints the state table, the transition timeline, the INT 18h calls and
REM  the verdict (DISPLAY HALF ONLY / DISPLAY + PLANE ENGINE / no PEGC / the
REM  plane question unobserved). Exit 0/2/3 mirrors the verdict.
REM
REM  CALIBRATION FIRST (worth 10 seconds): run it with NO argument on the same
REM  freshly-booted machine -
REM     RUNPEGC
REM  - which prints the DOS-prompt state without running a child (and keeps
REM  it in PEGCCAL.TXT, so PEGC.TXT is not overwritten). On this
REM  machine PEGCWATCH BASE should read A0A=00, P6A=00; if it does not, the
REM  readback rows are suspect and that is the finding to send.
REM
REM  /NOP: RUNPEGC /NOP DOOM.EXE skips the plane-register sampling (the only
REM  part of the probe that reads a window the game may be using). Use it if a
REM  run behaves oddly with the sampler on; the mode rows are unaffected.
REM
REM  Requires PEGCW.COM: build it with
REM     make -C tools/hwprobe pegcwatch/pegcw.com
REM ============================================================

IF NOT EXIST PEGCW.COM GOTO NOPROG

IF "%1"=="" GOTO NOARG

ECHO Working directory (the game must be HERE - DOS resolves it from the cwd):
CD
REM  /NOP is an option, not the program: the program is then the second argument
IF "%1"=="/NOP" GOTO CHKNOP
IF "%1"=="/nop" GOTO CHKNOP
IF NOT EXIST %1 ECHO *** NOT IN THIS DIRECTORY: %1 - a COMMAND.COM 'file not found' would follow ***
GOTO RUN
:CHKNOP
IF "%2"=="" GOTO NOARG
IF NOT EXIST %2 ECHO *** NOT IN THIS DIRECTORY: %2 - a COMMAND.COM 'file not found' would follow ***
:RUN
ECHO Running: PEGCW %1 %2 %3 %4 %5 %6 %7 %8 %9
ECHO (the game's screen is its own; the PEGCWATCH rows are printed after it returns)
PEGCW %1 %2 %3 %4 %5 %6 %7 %8 %9 > PEGC.TXT

ECHO.
FIND "PEGCWATCH END V=1" PEGC.TXT > NUL
IF ERRORLEVEL 1 ECHO (no PEGCWATCH END marker - the capture is valid to its last row; re-run UNREDIRECTED to see which row stopped it)
ECHO Capture written to PEGC.TXT for: %1 %2 %3 %4 %5 %6 %7 %8 %9
ECHO Copy PEGC.TXT off the machine NOW, then reboot before the next wrapped run.
GOTO END

:NOARG
ECHO No program was given.  Usage:  RUNPEGC [/NOP] <program> [args]
ECHO.
ECHO With no argument this is the CALIBRATION run: it prints this machine's PEGC
ECHO state at the DOS prompt without running anything, which is what makes the
ECHO readback rows believable (expect A0A=00 and P6A=00 on a fresh boot).
ECHO.
ECHO To answer the DOOM question, run it from the game's own directory:
ECHO   RUNPEGC DOOM.EXE        (then, on a fresh boot,)
ECHO   RUNPEGC DOOM2.EXE
ECHO.
ECHO Calibration rows (also written to PEGCCAL.TXT):
PEGCW > PEGCCAL.TXT
TYPE PEGCCAL.TXT
GOTO END

:NOPROG
ECHO PEGCW.COM is not in this directory - copy it here first.
ECHO Build it with:  make -C tools/hwprobe pegcwatch/pegcw.com
:END

@ECHO OFF
REM ============================================================
REM  PC-9821 real-machine I/O wait-state probe
REM  Copy IOPROBE.COM + this file to a DOS disk. Run:  RUNIO
REM  Send back IO.TXT (or the last BEGIN: marker on screen).
REM
REM  IOPROBE measures the cost of one I/O access to EVERY port
REM  class the core's class table names, so pc9821_iobus.sv's
REM  io_access_cycles can be corrected from the machine:
REM    0x005F   the I/O-wait anchor (documented 600 ns / 30 clk)
REM    0x60/62   text GDC    0xA0/A2  graphics GDC
REM    0x4A0-AE  EGC file    0x6A/7C/A6  EGC mode / GRCG / page
REM    0x64x     the IDE task file     0x188/18A  the -86 OPNA
REM    0x71/77   PIT          0x00/02   PIC          0x74x ATA
REM    0x20/22   calendar     0x41/43   keyboard     0x148x game
REM    plus one representative of every other decoded port.
REM
REM  Every READ row now also prints val=HH, the byte the port answered.
REM  The FDC's TWO port windows are in there: 0x90/0x92/0x94 (2HD) and
REM  0xC8/0xCA/0xCC (2DD), each timed while SELECTED (FDC90/FDC2DC8) and
REM  while NOT (FDC2HC8/FDC2D90), so one capture answers what the
REM  unselected window returns (0xFF vs an alias) and what the control
REM  port reads at 0x94 vs 0xCC. Those rows read-modify-write the
REM  0x00BE strap's BIT 0 only - saved in BEGIN:FDCSTRAP and put back
REM  after the last row; the capture prints both values.
REM
REM  Every row is bracketed BEGIN:IO<port><mode> / END:IO<port><mode>,
REM  so a port that hangs is the one whose BEGIN: has no END:. The
REM  write rows write the constant 0x00 (the EGC/GRCG/mode off state,
REM  the -86 register 0, the PIT latch command), never the PIC, the
REM  calendar, the GDC command registers or the ATA task file.
REM  Run it from a freshly booted prompt, then decode:
REM    python3 tools/hwprobe/ioprobe/ioprobe_decode.py IO.TXT
REM ============================================================

IF NOT EXIST IOPROBE.COM GOTO NOPROG

ECHO Running IOPROBE (a port that hangs leaves BEGIN: with no END:)...
IOPROBE > IO.TXT

ECHO.
FIND "IOPROBE DONE" IO.TXT > NUL
IF ERRORLEVEL 1 GOTO INCOMPLETE
ECHO IOPROBE DONE - every port completed.
ECHO Send IO.TXT back and decode it with:
ECHO    python3 tools/hwprobe/ioprobe/ioprobe_decode.py IO.TXT
GOTO END

:INCOMPLETE
ECHO INCOMPLETE - the capture has no "IOPROBE DONE": a port hung.
ECHO The capture up to the missing END: is still valid, and
ECHO    python3 tools/hwprobe/ioprobe/ioprobe_decode.py IO.TXT
ECHO names the hung BEGIN: section (its port). Power-cycle and send IO.TXT.
GOTO END

:NOPROG
ECHO IOPROBE.COM is not in this directory.
ECHO Copy IOPROBE.COM here first, then run RUNIO again.

:END

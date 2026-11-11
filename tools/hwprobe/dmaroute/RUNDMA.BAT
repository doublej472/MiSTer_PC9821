@ECHO OFF
REM RUNDMA - where a uPD71071 DMA byte lands in a memory window (DMAROUTE).
REM
REM Copy DMAROUTE.COM and this file to the machine, put a disk whose first
REM sector (C0 H0 R1) reads (any formatted 2HD, 1.44 MB or 2DD disk; the probe
REM ONLY READS it) in drive 0 or 1, then:
REM     RUNDMA            (or RUNDMA DA=91 to try that DA/UA first)
REM The probe scans DA/UA 90 91 30 31 10 11 until one reads, and prints a DISK
REM and a DIRECT line (ST3, recalibrate, READ ID) for each try.
REM and send back DMAROUTE.TXT.
REM
REM Run from a freshly booted plain DOS prompt: HIMEM is fine, EMM386 is NOT
REM (WBINVD and the 0x043F window need real mode). Run it from the HARD DISK,
REM not from the floppy being read. The probe switches the 256-colour mode on
REM and off and touches the EMS window, the 0x0461 window and the CG RAM with
REM interrupts off; the screen may flicker. It restores every mapping, every
REM byte it touched and the interrupt vector, and prints the restore report.
REM stdout MUST go to a file.

IF NOT EXIST DMAROUTE.COM GOTO NOPROG

ECHO Running the DMA routing probe (about a minute)...
DMAROUTE %1 %2 > DMAROUTE.TXT

FIND "END:DMAROUTE" DMAROUTE.TXT > NUL
IF ERRORLEVEL 1 ECHO    DMAROUTE.TXT  INCOMPLETE - no END:DMAROUTE marker
IF NOT ERRORLEVEL 1 ECHO    DMAROUTE.TXT  ok
ECHO Send DMAROUTE.TXT back. Decode with: python3 tools/hwprobe/dmaroute/dmaroute_decode.py DMAROUTE.TXT
GOTO END

:NOPROG
ECHO DMAROUTE.COM is not in this directory.
ECHO Copy DMAROUTE.COM here first, then run RUNDMA again.

:END

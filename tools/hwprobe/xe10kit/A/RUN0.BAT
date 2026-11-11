@ECHO OFF
REM XE10 KIT step 1: the machine as found, right after switching on.
REM Read-only, except XE10CFG /WR, whose writes are each put back at once
REM (CFG0B.TXT must equal CFG0.TXT).
IF NOT EXIST XE10CFG.COM GOTO NOPROG
ECHO [1/5] XE10CFG
XE10CFG > CFG0.TXT
ECHO [2/5] XE10CFG /WR
XE10CFG /WR > CFGWR.TXT
ECHO [3/5] XE10CFG again
XE10CFG > CFG0B.TXT
ECHO [4/5] FDMODE
FDMODE > FDM0.TXT
ECHO [5/5] PROBE2 /MEMSW
PROBE2 /MEMSW > MEMSW0.TXT
ECHO RUN0 DONE. Next: RUNMPU (step 2).
GOTO END
:NOPROG
ECHO Run this from the KIT directory.
:END

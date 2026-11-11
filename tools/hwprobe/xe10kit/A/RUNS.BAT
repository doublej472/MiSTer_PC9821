@ECHO OFF
REM XE10 KIT: one capture after a SETUP change. RUNS tag (up to 5 letters)
REM writes CFGtag.TXT and FDMtag.TXT. Read-only.
IF "%1"=="" GOTO USAGE
IF NOT EXIST XE10CFG.COM GOTO NOPROG
XE10CFG > CFG%1.TXT
FDMODE > FDM%1.TXT
ECHO RUNS %1 DONE.
GOTO END
:USAGE
ECHO USAGE: RUNS tag   (for example RUNS F3)
GOTO END
:NOPROG
ECHO Run this from the KIT directory.
:END

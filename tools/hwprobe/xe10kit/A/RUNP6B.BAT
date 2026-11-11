@ECHO OFF
REM XE10 KIT step 4b: after RESET with memory switch = keep. Is A1 kept?
REM Then puts the measured value 01 back.
IF NOT EXIST XE10CFG.COM GOTO NOPROG
PROBE2 /MEMSW > P6KEPT.TXT
XE10CFG > CFGS1B.TXT
XE10CFG /MSW5 01 > P6REST.TXT
TYPE P6REST.TXT
ECHO RUNP6B DONE. Next: SETUP (step 5).
GOTO END
:NOPROG
ECHO Run this from the KIT directory.
:END

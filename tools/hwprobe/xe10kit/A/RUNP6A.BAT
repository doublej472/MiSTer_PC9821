@ECHO OFF
REM XE10 KIT step 4a: SETUP has memory switch = keep, GDC clock = 5 MHz and
REM 20 text lines. Captures that state, then sets memory switch 5 to A1
REM (boot from the hard disk only) for the reset that follows.
IF NOT EXIST XE10CFG.COM GOTO NOPROG
XE10CFG > CFGS1.TXT
FDMODE > FDMS1.TXT
XE10CFG /MSW5 A1 > P6SET.TXT
TYPE P6SET.TXT
ECHO Now press the RESET button. At the DOS prompt: CD \KIT, then RUNP6B.
GOTO END
:NOPROG
ECHO Run this from the KIT directory.
:END

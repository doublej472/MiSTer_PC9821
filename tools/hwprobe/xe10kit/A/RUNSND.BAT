@ECHO OFF
REM XE10 KIT step 8: SETUP has Sound = used. Captures the sound ports, then
REM plays the -86 board's test tones (about 2 minutes; the first sound, two
REM short beeps, comes within a few seconds).
IF NOT EXIST XE10CFG.COM GOTO NOPROG
XE10CFG > CFGSND.TXT
FDMODE > FDMSND.TXT
ECHO Listen now: beeps and tones from the sound board (about 2 minutes).
SNDTEST > SNDTEST.TXT
ECHO RUNSND DONE. Did you hear the tones? Write it down.
GOTO END
:NOPROG
ECHO Run this from the KIT directory.
:END

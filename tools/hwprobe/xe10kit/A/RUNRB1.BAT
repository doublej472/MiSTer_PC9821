@ECHO OFF
REM XE10 KIT step 3a: the software reboot. Sets memory switch 5 to A1 (the
REM memory-switch "initialise" setting should put 01 back at the next POST),
REM saves the reset set to RBOOT.TXT and reboots the machine by itself.
IF NOT EXIST RBOOT.COM GOTO NOPROG
XE10CFG /MSW5 A1 > P6INIT.TXT
ECHO The machine now reboots by itself (black screen for about 10 s).
ECHO At the DOS prompt: CD \KIT, then RUNRB2.
RBOOT /S
GOTO END
:NOPROG
ECHO Run this from the KIT directory.
:END

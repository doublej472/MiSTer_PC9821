@ECHO OFF
ECHO PCMKIT RUN: six steps. Steps 1-5 need no input.
ECHO Step 1/6 PICROT (2 s)
PICROT > PICROT.TXT
ECHO Step 2/6 IDE640 (instant)
IDE640 > IDE640.TXT
ECHO Step 3/6 PCMOVF stage 1 (about 30 s, quiet)
PCMOVF > PCMOVF.TXT
ECHO Step 4/6 OPNAX /G (2 s)
OPNAX /G > OPNAXG.TXT
ECHO Step 5/6 SHBANK (a few s). If the machine hangs here: power-cycle, then type RUNJ.
SHBANK > SHBANK.TXT
ECHO.
ECHO ************************************************************
ECHO Step 6/6 INPUT NEEDED: the joystick pad in joystick port 1.
ECHO Follow the two prompts on the screen. Esc skips (no pad).
ECHO ************************************************************
OPNAX /J > OPNAXJ.TXT
ECHO.
ECHO RUN finished. Next: RUNA (the recording), see README.TXT.

@ECHO OFF
REM CRT31K: measures the 31 kHz dot clock (0x09A8 bit 0).
REM Run from a freshly booted plain DOS prompt. The screen may lose
REM sync for a few seconds while 31 kHz is timed; that is expected.
REM Send back CRT31K.TXT. REBOOT afterwards.
CRT31K > CRT31K.TXT
TYPE CRT31K.TXT

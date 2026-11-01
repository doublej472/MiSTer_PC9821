@ECHO OFF
REM RUN24K - the 24 kHz guest frame against the ARTIC and the PIT.
REM
REM Copy CRT24K.COM and this file to the machine, then:
REM     RUN24K
REM and send back CRT24K.TXT.
REM
REM Run from a freshly booted plain DOS prompt in the 24 kHz text mode. The
REM probe reprograms nothing; each of the three 60-frame runs holds interrupts
REM off for about 1.06 s, which is normal for this measurement. The disk is
REM never written (INT 21h AH=02/4C only).

IF NOT EXIST CRT24K.COM GOTO NOPROG

ECHO Running the 24 kHz frame measurement (about 4 seconds)...
CRT24K > CRT24K.TXT

FIND "END:CRT24K" CRT24K.TXT > NUL
IF ERRORLEVEL 1 ECHO    CRT24K.TXT  INCOMPLETE - no END:CRT24K marker
IF NOT ERRORLEVEL 1 ECHO    CRT24K.TXT  ok
ECHO Send CRT24K.TXT back. Decode with: python3 tools/hwprobe/crt24k/crt24k_decode.py CRT24K.TXT
GOTO END

:NOPROG
ECHO CRT24K.COM is not in this directory.
ECHO Copy CRT24K.COM here first, then run RUN24K again.

:END

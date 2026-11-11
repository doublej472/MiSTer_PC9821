# Galf Streem intro against CPU speed

Card runs of the core, emulator runs of NP2kai and one observation of a real PC-9821Xe10:
whether one title's intro plays through depends on the effective CPU speed, in narrow windows,
and not on the build's timing margin. `docs/user/compatibility.md` (Galf Streem) cites this file.

## Real PC-9821Xe10 (observation, 2026-11-07)

The same two disk images, written to 3.5" 2HD disks on the machine itself and booted from its
floppy drives: the intro plays through every scene with its music, but the game runs far too
fast on this machine - too fast to use its main menu. The title wants a slower CPU than the
Xe10's, so on the core it is run at a lower OSD CPU Speed, which also moves it out of the
intro-hang windows below.

## Recipe

Galf Streem, disk A in floppy drive 1 and disk B in drive 2, booted from the floppy; Enter
pressed at 55, 95 and 135 s; a screenshot about every 20 s from 10 s to about 195 s. A run is
GOOD when the intro keeps changing scene through the window (press conference, face, city,
train, then the intro's text screen) and BAD when it shows one or two scenes (first scene at
about 15 s) and is then black to the end, Enter changing nothing. The same recipe and media were
used for every row. "Full" is the OSD CPU Speed default.

## The mechanism

Found by tracing NP2kai at a bad multiplier (CPU multiplier 52, and again at 30):
- From the stall on there is no I/O and no interrupt. The CPU is inside the timer-interrupt
  (IRQ0) handler with interrupts off (FLAGS IF=0, PIC in-service register bit 0 set), executing
  data, so the keyboard, vertical sync and the floppy controller never run again.
- The IRQ0 handler is the game's music driver. Its channel sequencer reads its next command byte
  from the song's sequence buffer, turns it into a jump-table index and returns into the table's
  entry. In the bad run the byte is 0xF6, which the table does not hold, so the driver jumps into
  data.
- At each scene change the game loads the next scene's music sequence from disk into the same
  buffer (3915 bytes, the same load every scene), without stopping the driver. In the bad run the
  load overwrote the buffer 0.4 ms before the driver's last sound-chip write (3.8 ms in the
  other bad run), and the driver's pointer was inside the reloaded range. If the driver reads a
  command after the reload while its pointer still sits where the old song was, it reads a byte of
  the new song, and when that byte is not a valid command the dispatch jumps into data.
- Scenes are paced by the CPU (drawing, decompression) and the music by the timer, so the
  pointer position at the reload is a function of the effective CPU speed. Only some positions
  land on a byte invalid in the new song. The result is narrow, deterministic, non-monotonic
  speed windows, about 2-3 % wide. This is a race in the game; neither the core nor NP2kai is
  wrong.

## NP2kai (base clock 2.4576 MHz; 60 emulated seconds, 3 runs per point)

| CPU multiplier | 28 | 29 | 30 | 31 | 32 | 50 | 51 | 52 | 53 |
|---|---|---|---|---|---|---|---|---|---|
| result | 3/3 GOOD | 3/3 GOOD (last frame black, not checked) | 3/3 BAD | 3/3 GOOD | 3/3 GOOD | 3/3 GOOD | 3/3 GOOD | 3/3 BAD | 3/3 GOOD |

## Core, on two MiSTer cards

Release candidate e6db0f05, fit seed 3 (hangs at Full):

| OSD CPU Speed | card 1 run 1 | card 1 run 2 | card 2 run 1 | card 2 run 2 |
|---|---|---|---|---|
| Full | BAD | not repeated | BAD | not repeated |
| 33 MHz | GOOD | GOOD | GOOD | GOOD |
| 25 MHz | GOOD | GOOD | GOOD | GOOD |

At Full the stall is a first scene at about 15 s and black from about 34 s, on every run on both
cards (several earlier runs of the same bitstream, not tabulated).

First release 09a16b4b, fit seed 2 (plays at Full, 7 of 7 runs):

| OSD CPU Speed | card 1 run 1 | card 1 run 2 | card 2 run 1 | card 2 run 2 |
|---|---|---|---|---|
| 33 MHz | GOOD | BAD (three scenes to about 53 s, black from about 75 s) | GOOD | GOOD |
| 25 MHz | GOOD | GOOD | GOOD | GOOD |

So a CPU Speed setting is not a guaranteed workaround on every build: it moves the timing, and
33 MHz hung once on the build that plays at Full.

Other points (all at Full, single seed 2 unless noted):

| build | runs | result |
|---|---|---|
| e6db0f05 with `clk_sys` 50 MHz (CPU about 0.56 x slower, another speed point) | 5 | GOOD |
| e6db0f05 with the SDRAM write-exit trim off | 3 + 1, two cards | BAD |
| c8a273ae, the commit that added the trim | 1 | BAD |
| c8a273ae with the trim off | 2 | GOOD |

Every seed of the release-candidate source that was tried stalled at Full; the seed does not
matter, the effective CPU speed does. The earlier builds were good or bad at Full without a
pattern along the history (one build was good on one run and bad on the next, with the same
bitstream, which this mechanism does not explain and which was not investigated further), which
is how a window crossed by small changes in memory timing looks. Turning the SDRAM write-exit trim
off changed the CPU's effective speed and moved the build across a window.

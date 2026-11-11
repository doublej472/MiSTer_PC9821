# Installing and starting the core

What the core needs, building the BIOS pack from your own dumps, where each file goes on the SD
card and the first start.

## What you need

- **Current MiSTer firmware** (run the update script). Older Main_MiSTer releases are not
  supported.
- **An SDRAM board**: a standard two-chip 128 MB board or the MiSTer Pi's 128 MB board; a
  one-chip 32 MB or 64 MB board also works, with a lower **RAM Size** limit (16 MB on 32 MB,
  32 MB on 64 MB, 96 MB on 128 MB). Not supported: boards built from pairs of 8-bit chips, slower
  speed grades, low-power, remarked or counterfeit chips, and boards that load the memory bus
  more than a two-chip 128 MB board.
- **The Xe10 BIOS pack** (not included): download it from
  <https://archive.org/download/PC9821-xe-xe10-bios>, or
  [build it from your own Xe10 ROM dumps](#building-the-bios-pack-from-your-own-dumps).
- **A PC-98 hard-disk image** with NEC MS-DOS installed, or a
  [blank one](images.md#making-a-new-hard-disk) and an NEC MS-DOS boot floppy.

You supply the BIOS, font and YM2608 rhythm ROMs and the disk images yourself.

## Building the BIOS pack from your own dumps

Skip this if you downloaded the pack. You need a computer with Python 3 and a copy of
this repository.

1. Put your Xe10's dumps in one folder under these names (upper or lower case):

   | file | size (bytes) | what |
   |---|---|---|
   | `BANK0.BIN` ... `BANK7.BIN` | 32,768 each | the eight ROM banks |
   | `BIOS.ROM` | 98,304 | the main BIOS |
   | `FONT.ROM` | 288,768 | the text and kanji font |
   | `OPNA_ADPCM.ROM` | 8,192 | the YM2608's rhythm (drum) ROM: **required**, see below |
   | `SOUND.ROM` | 16,384 | optional: the PC-9801-86 board's ROM |

2. From the repository's folder, with `DUMPS` the folder:

   ```
   python3 tools/build_pack.py --dumps DUMPS --out boot0.rom
   python3 tools/check_pack.py --pack boot0.rom --dumps DUMPS
   ```

   The first writes the pack and names each file it used; the second checks it against the dumps
   and reports any missing region. Copy `boot0.rom` to `games/PC9821/` on the SD card.
   `build_pack.py --list` shows the pack layout.

**The rhythm ROM** sits inside the YM2608 chip, so it is not in the BIOS dumps. Supply the chip's
8 KiB rhythm ROM as `OPNA_ADPCM.ROM` (or with `--rhythm FILE`; a Quartus `.mif` of 8,192 8-bit
words also works), with the first of each byte's two 4-bit samples in the high half. Without it
the build prints `WARNING: no rhythm image`, and every drum hit plays as a loud buzz instead of
silence. Without `SOUND.ROM` the pack works; the build prints a `note:` line.

## Files on the SD card

| file | where |
|---|---|
| the core, `PC9821Z486.rbf` | `_Computer/PC9821Z486.rbf` |
| the BIOS pack, loaded automatically at every core start | `games/PC9821/boot0.rom` |
| hard-disk, CD and floppy images | anywhere; the file browser opens in `games/PC9821/` |

Nothing else is installed on the MiSTer. The [image converters](images.md#converting-images) run
on a computer.

## First start

1. Choose **PC9821Z486** under **Computer**. The core loads `games/PC9821/boot0.rom` by itself.
2. Choose **Mount HDD** and pick your hard-disk image. The machine restarts and boots from it.

To keep OSD changes, use **Save settings** ([Saving the settings](options.md#saving-the-settings)).

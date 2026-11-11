# PC-9821 z486 MiSTer core

A PC-9821 (NEC Xe10) core for [MiSTer](https://github.com/MiSTer-devel/Main_MiSTer), built on
the z486 486 CPU. It boots NEC's own Xe10 firmware to MS-DOS and runs PC-98 DOS software and
Windows 95, from hard-disk, CD-ROM and floppy images.

Screenshots and video clips of software running on the core: <https://pc98.doublej472.com>.

## Hardware features

Each line links to the details.

- **Machine**: the PC-9821Xe10 with its own firmware (the Xe set does not boot yet), 1-96 MB of
  RAM, calendar clock, the DIP switches and SETUP items on an OSD page
  ([machine](docs/user/hardware.md#machine-and-cpu)).
- **CPU**: the z486, a 486-class CPU without an FPU; **CPU Speed** slows it from `Full` to
  0.5 MHz for software that runs too fast ([CPU](docs/user/hardware.md#machine-and-cpu)).
- **Graphics**: text with ANK and JIS kanji, 640x400 8/16-colour graphics, the GDC drawing
  commands, GRCG and EGC, PEGC 256-colour display at 640x400 and 640x480, the 31 kHz mode
  ([graphics](docs/user/hardware.md#graphics)).
- **Sound**: the PC-9801-86 board (YM2608 OPNA: FM, SSG, rhythm, ADPCM; and its PCM), the beeper
  and CD audio, each with its own level ([sound](docs/user/hardware.md#sound)).
- **MIDI**: an MPU-PC98II interface played through MiSTer's MidiLink: software synths, a USB MIDI
  device or the network ([MIDI](docs/user/hardware.md#midi)).
- **Storage**: an IDE hard disk, an ATAPI CD-ROM drive with CD audio (or a second hard disk in its
  place) and two floppy drives, from raw, HDI, VHD, D88, HDM, FDI, ISO and PCD images
  ([storage](docs/user/hardware.md#storage), [formats](docs/user/images.md#formats)).
- **Input**: the PC-98 keyboard with a US or JIS layout, the bus mouse and a two-button joypad
  ([input](docs/user/input.md)).
- **Video output**: HDMI through MiSTer's scaler with integer scaling; analog VGA at the native
  24 kHz or scan-doubled to 49 kHz, with scanlines
  ([video output](docs/user/hardware.md#video-output)).
- **OSD pages**: the main page, **DIP Switch**, **Audio**, and the **I/O timing** option for
  software that times itself by the machine's port speed ([options](docs/user/options.md)).

[`docs/user/compatibility.md`](docs/user/compatibility.md) lists every title tested on the core,
with the setup each one needs.

## What you need

- **Current MiSTer firmware** (run the update script).
- **An SDRAM board**: a two-chip 128 MB board, the MiSTer Pi's 128 MB board, or a one-chip 32 MB
  or 64 MB board (with less guest RAM). Boards built from pairs of 8-bit chips and slower or
  low-power chips are not supported ([details](docs/user/setup.md#what-you-need)).
- **The Xe10 BIOS pack** (not included): download it from
  <https://archive.org/download/PC9821-xe-xe10-bios>, or build it from your own Xe10 ROM dumps
  ([Building the BIOS pack](docs/user/setup.md#building-the-bios-pack-from-your-own-dumps)).
- **A PC-98 hard-disk image** with NEC MS-DOS installed, or a blank one and an NEC MS-DOS boot
  floppy.

## Install and first start

1. Copy `PC9821Z486.rbf` to `_Computer/`, and save the BIOS pack as `games/PC9821/boot0.rom` on
   the SD card: the core loads it automatically at every start. Images can go anywhere; the file
   browser opens in `games/PC9821/`.
2. Choose **PC9821Z486** under **Computer**.
3. Choose **Mount HDD** and pick your hard-disk image. The machine restarts and boots from it.
4. To keep OSD changes, choose **Save settings** on the system page (F12, then Right).

## Recipes

**Set up DOS on a blank hard disk** ([full steps](docs/user/dos-windows.md#setting-up-dos-on-a-new-hard-disk))

1. On a computer: `python3 tools/pc98_hdd_convert.py --new 500 NEW.img`.
2. **Mount HDD** the new image and **Mount FDD1** an NEC MS-DOS boot floppy.
3. Run `FORMAT` on the fixed disk: initialize, allocate, transfer the system.
4. Eject the floppy and reset: DOS starts from the hard disk.

**Use an existing hard-disk image** ([converting](docs/user/images.md#converting-hard-disk-images))

1. Check it: `python3 tools/pc98_hdd_convert.py --info IMAGE`.
2. If it is not 512-byte sectors in 8 heads x 17 sectors, convert it:
   `python3 tools/pc98_hdd_convert.py OLD.hdi NEW.img`.
3. **Mount HDD** the result.

**Play a CD title** ([full steps](docs/user/dos-windows.md#playing-a-cd-title))

1. On a computer, convert a CUE/BIN set for CD audio: `python3 tools/cue2pcd.py GAME.cue`.
2. Load `NECCD.SYS` in `CONFIG.SYS` and `MSCDEX.EXE` in `AUTOEXEC.BAT`
   ([DOS setup](docs/user/dos-windows.md#configsys-and-autoexecbat)).
3. **Mount CD-ROM** the `.pcd` (or `.iso`) and start the title from the CD's drive letter.

**Use MIDI with MidiLink** ([details](docs/user/hardware.md#midi))

1. On the system page, set **UART mode** to `MIDI` and choose **Save**.
2. Choose MidiLink's output: a software synth, a USB MIDI device or the network.
3. Pick the MPU-PC98II in the program's sound setup.

**Windows 95** ([details](docs/user/dos-windows.md#windows-95))

1. Use a hard-disk image with the PC-98 version of Windows 95 installed.
2. Load `HIMEM.SYS` and `EMM386.EXE /UMB` in `CONFIG.SYS`.
3. If `CONFIG.SYS` loads `NECCDM.SYS`, add it under `[SafeList]` in `C:\WINDOWS\IOS.INI`.

**Floppy titles** ([formats](docs/user/images.md#formats))

1. Convert NFD and Virtual98 images on a computer: `python3 tools/fdconv.py DISK.nfd`.
2. **Mount FDD1** (and **FDD2**) and reset; when the title asks for another disk, mount it from
   the OSD.
3. Leave **DIP Switch > Floppy mode** at its default `Auto (1M)`: some 2DD boot disks stay black
   at `1M`.

## Documentation

| | |
|---|---|
| [Troubleshooting](docs/user/troubleshooting.md) | common problems by symptom, and the known issues |
| [Compatibility](docs/user/compatibility.md) | every tested title and what it needs |
| [Installing and starting](docs/user/setup.md) | requirements, building the BIOS pack, SD card layout |
| [OSD options](docs/user/options.md) | every option, its values and defaults, saving settings |
| [Disk and CD images](docs/user/images.md) | formats and the image converters |
| [DOS and Windows 95](docs/user/dos-windows.md) | `FORMAT`, `CONFIG.SYS`, drivers, Windows 95 |
| [Keyboard, mouse and joypad](docs/user/input.md) | the key table for both layouts |
| [Hardware](docs/user/hardware.md) | the emulated hardware in detail, MIDI, video output, LEDs |
| [All documentation](docs/README.md) | the index, including the contributor docs |

Contributors start at [`AGENTS.md`](AGENTS.md): the repository layout, the build, the tests and
testing on a real MiSTer.

## Licensing

No NEC, Yamaha or other copyrighted firmware is included: you supply the BIOS, font and YM2608
rhythm ROMs and the disk images yourself.

See [`LICENSE`](LICENSE) for this project's own code and [`NOTICE`](NOTICE) for the third-party
parts and their licences.

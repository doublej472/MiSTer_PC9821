# PC-9821 z486 MiSTer core

A PC-9821 (NEC Xe10) core for [MiSTer](https://github.com/MiSTer-devel/Main_MiSTer), built on
the z486 486 CPU. It boots NEC's Xe10 firmware to MS-DOS and runs PC-98 DOS software, including
CD-ROM titles with CD audio.

## What works

- The NEC Xe10 firmware set boots to DOS. The Xe firmware set does not work yet.
- PC-98 games run, including sprite-heavy ones; see [Compatibility](#compatibility).
- 640x400 16-colour graphics with GRCG/EGC drawing, ANK and JIS kanji text.
- YM2608 sound (FM, SSG, ADPCM rhythm) and the PC-9801-86 PCM.
- An MPU-PC98II MIDI interface: set the UART mode to MIDI (on MiSTer's system page: press Right
  on the core menu's first page, then **UART mode**) and use MiSTer's MidiLink
  (its software synths, a USB MIDI device or an external synth). Software sees the card only
  while the UART mode is MIDI; in any other mode it is absent, so programs that would choose
  MIDI when they find one keep their FM music. Changing the mode removes or re-inserts the card
  (it comes back reset), so set it before starting a program.
- An IDE hard disk, an ATAPI CD-ROM drive with CD audio and two floppy drives, each from an image
  file (see [Disk and CD images](#disk-and-cd-images)).
- PC-98 keyboard, bus mouse (the mouse connected to the MiSTer), two-button joystick and the
  real-time clock.

## What you need

- Up-to-date MiSTer firmware: only current Main_MiSTer releases are supported (run the
  update script). Older ones differ in ways the core does not work around. One difference is
  still in the current release (MiSTer_20261010): the Japanese keyboard's ろ (`_`) key arrives
  as the カナ key, so it toggles kana input instead of typing `_`. Main_MiSTer fixed this on
  18 October 2026, and the fix arrives with its next release. The core follows only the current
  key codes and does not accept the old one.
- A MiSTer with an SDRAM board:
  - a standard 128 MB board (two chips), or the 128 MB board that comes with the MiSTer Pi. The
    core's memory timing was measured on both, with a wide margin;
  - a 32 MB or 64 MB board (one chip) is also supported, with a lower **RAM Size** limit: 16 MB
    on a 32 MB board, 32 MB on a 64 MB board (96 MB on a 128 MB board);
  - very cheap or slow modules are not supported: boards built from pairs of 8-bit chips, slower
    speed grades, low-power chips, remarked or counterfeit chips, and boards that load the
    memory bus more heavily than a two-chip 128 MB board.
- The Xe10 BIOS pack, which is **not included**. Download `pc98pack-xe10.bin` from
  <https://archive.org/download/PC9821-xe-xe10-bios>. Only that file is needed; the Xe pack
  does not run yet.
- A PC-98 hard-disk image with NEC MS-DOS installed (see [Disk and CD images](#disk-and-cd-images)).
  The DOS drivers mentioned below come with NEC MS-DOS or with the software that uses them, and
  are not included.

### Disk and CD images

The core recognises each format from the file's contents, not from its name. Each OSD
**Mount** entry offers the extensions in the table.

| drive | format | extension | notes |
|---|---|---|---|
| hard disk | raw | `.img` | 512-byte sectors; the BIOS boots a disk laid out as 8 heads x 17 sectors (see below) |
| | HDI | `.hdi` | 512-byte sectors; the header must be a whole number of 512-byte sectors (Anex86's default 4096-byte header works, a 32-byte header does not) and its first four bytes zero; the disk's size is the header's geometry; otherwise the image is read as raw |
| | fixed VHD | `.vhd` | the 512-byte footer at the end must be a valid fixed-disk footer; a dynamic or differencing VHD is read as raw (not supported) |
| floppy | D88 | `.d88` | 2DD and 2HD disks; read and written, but cannot be formatted |
| | raw | `.hdm`, `.fdd` | the file size picks the layout (sizes below); a size not listed leaves the drive empty |
| CD-ROM | ISO | `.iso` | 2048-byte sectors, data only, one track |
| | PCD | `.pcd` | data and CD audio tracks; made from a CUE/BIN set (below) |

Raw floppy sizes (cylinders x heads x sectors x bytes per sector):

- 2HD: 1,261,568 bytes (77 x 2 x 8 x 1024, the usual 1.25 MB disk), and the same layout with 78,
  79 or 80 cylinders (1,277,952, 1,294,336 and 1,310,720 bytes); 1,228,800 bytes (80 x 2 x 15 x
  512, 1.2 MB 2HC); 1,474,560 bytes (80 x 2 x 18 x 512, 1.44 MB); 1,720,320 bytes (80 x 2 x 21 x
  512, DMF); 1,025,024 bytes (77 x 2 x 26 x 256); 1,419,264 bytes (77 x 2 x 9 x 1024).
- 2DD: 655,360 bytes (80 x 2 x 8 x 512, 640 KB) and 737,280 bytes (80 x 2 x 9 x 512, 720 KB). A
  BASIC 2DD image (80 x 2 x 16 x 256) has the same size as the 640 KB one and is read with the
  640 KB layout, so it does not work.

Not supported: NHD hard-disk images (convert them as below); NFD, FDI and Virtual98 FDD floppy
images (a `.fdd` with a header: the core reads a `.fdd` only as a raw image of a size above);
CD images with raw 2352-byte sectors as an `.iso` (convert the CUE/BIN set to PCD, below); and
CloneCD (`.ccd`/`.img`/`.sub`) CD images.

**CUE/BIN to PCD.** The core cannot open a `.cue`/`.bin` set directly. Put the `.cue` and its
`.bin` files under `games/PC9821/` and run `pc9821_cue2pcd` from the MiSTer menu's Scripts entry
(installed as below): it writes a `.pcd` next to each `.cue` and leaves the originals alone. On a
PC, `python3 tools/cue2pcd.py GAME.cue` does the same.

### Converting other hard-disk images

The core's IDE BIOS boots a disk with 512-byte sectors laid out as 8 heads x 17 sectors. Many
HDI images are SASI disks (256-byte sectors) or IDE disks with 4 heads: on the core the first
stops at the BIOS "insert system disk" message and the second shows a black screen. Convert
them on a PC (Python 3):

```
python3 tools/pc98_hdd_convert.py OLD.hdi NEW.img
```

It reads HDI and NHD images. It keeps the partitions and files unchanged, rewrites the disk
addresses for the new layout, and then checks that every file in every FAT12/FAT16 partition
still matches. It writes a raw image for a `.img` name and an HDI image for a `.hdi` name.
`--info IMAGE` shows an image's layout. The original file is never modified: the new image is
written under a temporary name and renamed only after the check passes, and an output name that
is the input file is refused. A disk with a FAT32 partition is refused, and a partition that is
not FAT is moved byte for byte, its boot sector not patched. The tool holds the whole image in
memory, so a 2 GB image needs several GB of RAM.

## Installing

Copy these to the SD card:

| file | where |
|---|---|
| the core, `PC9821Z486.rbf` | `_Computer/PC9821Z486.rbf` |
| the BIOS pack | `games/PC9821/pc98pack-xe10.bin` |
| your hard-disk image | anywhere; `games/PC9821/` is where the file browser opens |
| optional: the CUE/BIN converter, `tools/mister/pc9821_cue2pcd.sh` | `Scripts/pc9821_cue2pcd.sh` |
| and its helper, `tools/cue2pcd.py` | `Scripts/.pc9821/cue2pcd.py` |

## Running

1. Choose **PC9821Z486** under **Computer** in the MiSTer menu. The screen stays black until a
   BIOS pack is loaded.
2. Open the OSD (F12), choose **Load BIOS ROM** and pick `pc98pack-xe10.bin`.
3. Choose **Mount HDD** and pick your hard-disk image. Mounting it restarts the machine, which
   then boots from that disk.

Useful OSD settings:

- **Load BIOS ROM**: loads the BIOS pack; needed each time the core is started.
- **Mount CD-ROM**, **Mount FDD1/FDD2**: insert a CD or floppy image. Each drive's **Eject**
  entry sits directly below its **Mount** entry.
- **CD audio volume**: the level of CD audio tracks against the rest of the sound, like the
  volume wheel on a CD drive: 0 dB by default, 0 dB to -12 dB in 2 dB steps, or Off.
- **RAM Size**: 16 MB by default.
- **CPU Speed**: slows the CPU for software that runs too fast. The speeds are approximate,
  not period-accurate; `Full` is normal.
- **Keyboard**: `US` (default) or `JIS`, the layout of the keyboard plugged into the MiSTer; see
  [Keyboard](#keyboard).
- **DIP Switch > FDD mode**: `Auto` (default) also sets up the 640 KB floppy interface that some
  2DD boot disks use; `Fixed` matches a machine with that switch set. Applies at the next reset.
- **Analog video** (the VGA port of the I/O board): `Native 24kHz` is the machine's own
  640x400 signal at 24.8 kHz / 56.4 Hz, which needs a multisync monitor. `Doubled 49kHz` sends
  every line twice (640x800 at 49.7 kHz / 56.4 Hz) for VGA monitors that cannot sync to 24 kHz;
  `forced_scandoubler=1` in MiSTer.ini selects it automatically. **Scanlines (doubled)** darkens
  every other line of the doubled picture, on the HDMI output as well while the picture is doubled.
  Apart from that, the Analog video setting does not change the HDMI picture. Software
  that switches the machine to its 31 kHz mode (port `0x09A8`, e.g. `HSB.EXE IGDC:31`) gets the
  machine's 31.5 kHz / 70 Hz signal on the VGA port in every setting: it is already VGA-rate, so
  `Doubled` passes it through undoubled.
- Monitors that accept neither signal can use the MiSTer scaler on the VGA port instead:
  `vga_scaler=1` in MiSTer.ini.

## Keyboard

The PC-98 has a Japanese (JIS) keyboard with a few keys a PC keyboard lacks. Each PC key gives
the PC-98 key at the same place, so Shift gives what the PC-98 prints on that key: Shift+`2` is
`"`, Shift+`-` is `=`, and `:` is the key right of `;` (`'` on a US keyboard). Set the OSD's
**Keyboard** option to your keyboard's layout; it changes only the four keys whose symbols differ
between US and Japanese keyboards, and takes effect on the next key press:

- `US`: `[`, `]` and `\` type `[`, `]` and `¥` (DOS's `\`, as in `cd \DOS`), and `` ` `` types `@`.
- `JIS`: every key types its own label, including `]`, `@` and `¥`.

<!-- keymap:begin -->
<!-- generated by tools/gen_keymap_table.py from pc9821_kbd.sv; do not edit by hand -->

| PC key | PC-98 key, US layout | PC-98 key, JIS layout |
|---|---|---|
| Any key not listed: letters, digits, F1-F10, Esc, Enter, Shift, arrows, keypad | the same key | the same key |
| `` ` `` (JIS: 半角/全角) | `@` `~` | nothing |
| `=` (JIS: `^`) | `^` `` ` `` | `^` `` ` `` |
| JIS `¥` | `¥` `\|` (`¥` is the `\` of DOS paths) | `¥` `\|` (`¥` is the `\` of DOS paths) |
| `[` (JIS: `@`) | `[` `{` | `@` `~` |
| `]` (JIS: `[`) | `]` `}` | `[` `{` |
| `\` (JIS: `]`) | `¥` `\|` (`¥` is the `\` of DOS paths) | `]` `}` |
| `'` (JIS: `:`) | `:` `*` | `:` `*` |
| ISO key left of Z | RO: Shift gives `_` | RO: Shift gives `_` |
| JIS `ろ` | RO: Shift gives `_` | RO: Shift gives `_` |
| left Alt | NFER | NFER |
| JIS 無変換 | NFER | NFER |
| JIS 変換 | XFER | XFER |
| JIS カタカナ/ひらがな | KANA | KANA |
| right Alt | XFER | XFER |
| Menu | KANA | KANA |
| right Ctrl | GRPH | GRPH |
| F11 | VF1 | VF1 |
| F12 (opens the MiSTer menu) | VF2 | VF2 |
| Print Screen | COPY | COPY |
| Scroll Lock | keypad `,` | keypad `,` |
| Pause | STOP | STOP |
| Home | HOME/CLR | HOME/CLR |
| End | HELP | HELP |
| Page Up | ROLL UP | ROLL UP |
| Page Down | ROLL DOWN | ROLL DOWN |
| Num Lock | keypad `=` | keypad `=` |

No PC key gives VF3, VF4, VF5, APP.
<!-- keymap:end -->

## DOS setup

Inside DOS, with the configuration below, the hard disk is `A:` and the CD is `Q:`. The drivers
named here are the ones checked on the core; [`docs/compatibility.md`](docs/compatibility.md)
lists which setup each tested title needs.

```
REM CONFIG.SYS
DOS=HIGH
DEVICE=A:\DOS\HIMEM.SYS
DEVICE=A:\DOS\EMM386.EXE /UMB
DEVICE=A:\DOS\NECCD.SYS /D:CD_101
LASTDRIVE=Z

REM AUTOEXEC.BAT
LH A:\DOS\MSCDEX.EXE /D:CD_101 /L:Q
```

**Memory**

- `HIMEM.SYS` is needed by almost everything (`DOS=HIGH`).
- `EMM386.EXE /UMB` (NEC MS-DOS 6.2) provides EMS and upper memory.
- `VEM486.EXE /U` also works; software that needs EMS under it also needs `VEMEMM.SYS` loaded
  (without it, such programs report that there is not enough free memory). Use plain `/U`: an
  address range after it (`/U=A5-A7,...`, written for an emulator) makes VEM486 stop with a
  general protection error.
- NEC's 1989 `EMM.SYS` works, but one title's intro runs slowly with sprites left uncleared (or
  stays black) under it; it runs correctly under `EMM386.EXE /UMB`.
- Some DOS extenders refuse to start under EMM386 or VEM486; see [Known issues](#known-issues).

**CD-ROM**

- NEC's `NECCD.SYS` with Microsoft's `MSCDEX.EXE`, as above. The `/D:` name must be the same on
  both lines.
- `NECCDD.SYS` and `NECCDM.SYS` also work.
- `PATACD.SYS` reads files and plays CD audio, but rejects some calls that programs make to the
  driver directly.
- The Oak OTI-011 CD driver, which several CD software images use, works with `MSCDEX.EXE`.

**Mouse**

- `QMOUSE`, which most of the tested hard-disk images load, works. Some games read the mouse
  directly and need no driver.

## Compatibility

[`docs/compatibility.md`](docs/compatibility.md) lists every title and DOS program run on the
core, with its media (hard disk, CD or floppy), a status (works, works with notes, partial,
fails, not a core bug) and the driver, memory setup, key or extra disk it needs. Each title was
started on a real MiSTer (a few noted ones in simulation) and judged from screenshots; sound was
judged only where a row says so. A title that was never run is not listed. Its "How to read it" section explains the
statuses and which core build the results are for.

## Known issues

- Only the Xe10 firmware set works.
- A DOS extender that refuses to run under a V86-mode memory manager ("already running in
  virtual-86 mode") needs HIMEM only: boot without EMM386 or VEM486.
- While a CD audio track plays, `NECCD.SYS` refuses file reads (`CDR101: Not ready`). NEC's
  driver does this on real hardware too.
- Floppy: formatting a D88 image fails (MS-DOS FORMAT reports that it cannot format the disk);
  the core does not rebuild a D88 image's tracks. Format a raw (`.hdm`) image instead.
- Hard disk: the core recognises an HDI image by its header, not its name, and reads it as a raw
  image (so the disk does not boot) when the header is 32 bytes (the format's unpadded minimum) or
  is not a whole 512-byte sector, when its first four bytes (reserved) are not zero, when it
  declares 256-byte sectors, or when a geometry field is zero or out of range (256 or more heads
  or sectors per track, 65536 or more cylinders). Anex86's default 4096-byte header works. The
  disk's size is the header's cylinders x heads x sectors; the DataSize field and trailing bytes
  after the data are ignored. A file shorter than its geometry is cut to the sectors it holds.
  Dynamic and differencing VHD images are not supported (only fixed VHD); they fall back to raw,
  so mount a fixed VHD or a raw image instead.
- A key already held when the core starts is never reported by the framework (it sends one event
  per press), so holding HELP through a boot does not enter the BIOS SETUP. Use the OSD's
  **Enter BIOS setup (hold HELP)** option instead: it holds HELP for the POST and enters SETUP.
- No PC key gives the PC-98's VF3-VF5 keys (the MiSTer firmware sends nothing for F13-F15), and
  VF2 is on F12, which opens the MiSTer menu.
- Not implemented: 16-bit WSS/MSS audio, the PC-98's RS-232C serial port, the 15 kHz display mode, the monochrome
  graphics mode, and PEGC 256-colour drawing (256-colour display works, at 640x400 and at 31 kHz
  640x480). The 31 kHz display mode is implemented and has not yet been checked on an analog VGA
  monitor (its sync polarity is still an open decision).

## Development

Start with [`AGENTS.md`](AGENTS.md): the repository layout, the containerised Quartus build, the
build profiles, the test gates, and how to test on a real MiSTer. The basic build is:

```sh
make base     # apply the default 90 MHz build profile
make build    # fit the core -> output_files/z486_mister.rbf (install it as PC9821Z486.rbf)
make bench    # run the simulation benches
```

`make pack PC98_DUMPS=<dir>` builds a BIOS pack from your own Xe10 ROM dumps.

## Licensing

The licence for this project's own code has not been decided yet; until it is, no licence is
granted for it beyond what the third-party parts carry for their own code.

The repository contains files from other projects that keep their own licences, listed in
[`NOTICE`](NOTICE): the z486 CPU in `src/z486/` (Apache-2.0, with its microcode image excluded),
the MiSTer framework in `sys/` (GPL), the JT12/JT49 sound cores in `src/opna/` (GPL v3), a few
BSD-licensed modules from ao486_MiSTer, an MIT-licensed SDRAM model used only by the simulation
benches, the Altera PLL templates in `tools/profile/` (under Altera's own notice), and a few small
data tables transcribed from NP2kai (MIT) and Main_MiSTer's key-code table (GPL v3). Parts that
come from the original z486 MiSTer port are listed in `NOTICE` too; their licence is still to be
confirmed.

The FPGA bitstream (`.rbf`) combines these parts with the project's own code. It includes GPL-3
code and the GPL framework, whose terms apply to the bitstream; this repository is its
corresponding source.

No NEC, Yamaha or other copyrighted firmware is included: you supply the BIOS, font and YM2608
rhythm ROMs and the disk images yourself.

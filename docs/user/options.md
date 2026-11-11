# OSD option reference

Every entry of the core's OSD menu. Open it with F12; press Right on its first page for MiSTer's
system page (**UART mode**, **Save settings**). Mounting or ejecting a hard disk restarts the
machine; a floppy or CD does not. On a **Mount** entry, the `` ` `` key lists recently mounted
files.

## Main page

| option | values (default first) | what |
|---|---|---|
| **Load BIOS ROM** | | load a BIOS pack by hand (normally not needed: `boot0.rom` loads at every start) |
| **Mount / Eject HDD**, **HDD2**, **CD-ROM**, **FDD1**, **FDD2** | | insert or remove an image; each Eject is below its Mount ([image formats](images.md)) |
| **IDE bank 1** | `CD-ROM`, `HDD2` | what the second IDE connector holds ([A second hard disk](images.md#a-second-hard-disk)) |
| **RAM Size** | `16M`, `32M`, `64M`, `96M`, `1M`, `2M`, `4M`, `8M` | guest memory, capped by the SDRAM board (16 MB on 32 MB, 32 MB on 64 MB, 96 MB on 128 MB); applies at reset |
| **CPU Speed** | `Full`, `33 MHz` ... `0.5 MHz` | slows the CPU for software that runs too fast (approximate speeds; device timers keep real time) |
| **I/O timing** | `Fast`, `Xe10` | how long an I/O port access and a graphics-memory store take: `Fast` is the shortest wait the core allows; `Xe10` is the measured PC-9821Xe10's time per port and its graphics-memory store rate (GRCG drawing, 32-bit stores), for software that times itself by its port accesses or its drawing; applies at once |
| **Keyboard** | `US`, `JIS` | your keyboard's layout ([Keyboard](input.md#keyboard)) |
| **DIP Switch** | | the [DIP Switch page](#dip-switch-page) |
| **Audio** | | the [Audio page](#audio-page) |
| **Aspect ratio** | `Original`, `Full Screen`, and MiSTer's custom ratios | HDMI aspect ratio: `Original` is the shape of NEC's own monitors (square dots), 16:10 for a 640x400 (or 200-line) picture and 4:3 for a 640x480 one, following the mode the software sets |
| **Scale** | `Normal`, `V-Integer`, `Narrower HV-Integer`, `Wider HV-Integer` | HDMI scaling (integer scaling) |
| **Analog video** | `Native 24kHz`, `Doubled 49kHz` | the VGA port's signal ([Analog video](#analog-video)) |
| **Scanlines (doubled)** | `None`, `25%`, `50%`, `75%` | darkens every other line of the doubled picture, on HDMI too while doubled |
| **Reset**, **Reset and close OSD** | | restart the machine |

### Analog video

`Native 24kHz` is the machine's own 640x400 signal (24.8 kHz / 56.4 Hz) for a multisync monitor.
`Doubled 49kHz` sends each line twice (640x800, 49.7 kHz) for VGA monitors that cannot sync to
24 kHz; `forced_scandoubler=1` in `MiSTer.ini` selects it. Software that switches to the machine's
31 kHz mode gets 31.5 kHz / 70 Hz in either setting (it is never doubled). For monitors that take
neither, set `vga_scaler=1` in `MiSTer.ini`. Apart from **Scanlines (doubled)**, these settings do
not change the HDMI picture. There is no 15 kHz output.

## DIP Switch page

The machine's switches and the settings its BIOS SETUP menu would store (set them here; the core
does not use SETUP). **Every option takes effect at the next reset.**

| option | values (default first) | what |
|---|---|---|
| **Machine** | `Xe10`, `Xe (not working)` | the firmware set; leave it on `Xe10` |
| **GDC Clock** | `2.5 MHz`, `5 MHz` | some games refuse to run, or scroll differently, at the other setting |
| **Text lines** | `25`, `20` | lines on the BIOS screens; DOS keeps its own 25 lines |
| **Memory switch** | `Initialise`, `Keep` | reset the memory switches (DOS `SWITCH` settings) at every start, or keep what software set; a **Boot order** other than `Auto` always keeps them |
| **Floppy mode** | `Auto (1M)`, `1M`, `Auto (640K)`, `640K` | start the floppy drives as 1 MB or 640 KB (2DD) drives; the `Auto` entries also set up the other floppy interface, which some 2DD boot disks need (they show a black screen with `1M`) |
| **Boot order** | `Auto`, `640K`, `1M`, `MO`, `SASI1`, `SASI2`, `SCSI` | `Auto` tries every drive; any other entry boots only that device, with no fallback: `640K`/`1M` the floppies in that mode (this also sets the floppy interface, whatever **Floppy mode** says), `SASI1` the first two hard disks, `SASI2` the next two, `MO` the ATAPI drives, `SCSI` nothing (no SCSI board) |

## Audio page

Each source's level against the others: `0 dB` (default), `-2 dB` to `-12 dB` in 2 dB steps, or
`Off`. Changes apply at once; a program's own volume settings still apply on top.

| option | what |
|---|---|
| **PC-9801-86** | the whole sound board: FM, SSG, rhythm, ADPCM and PCM |
| **Beeper** | the built-in beeper |
| **CD audio** | CD audio tracks |

MIDI from MidiLink's software synths is mixed in by MiSTer after the core: set its level with
`FSYNTH_VOLUME` / `MUNT_VOLUME` in `MidiLink.INI` and MiSTer's own volume control.

## System page: UART mode

**UART mode** on MiSTer's system page selects `MIDI` for the core's MPU-PC98II MIDI interface
([MIDI](hardware.md#midi)). Save it with that page's **Save** entry. Changing the mode removes or
re-inserts the MIDI card (a reset), so set it before starting a program.

## Saving the settings

OSD changes last until the core is loaded again. To keep them, choose **Save settings** on the
system page: every OSD option (including the DIP Switch and Audio pages) is written to
`config/PC9821.CFG` and read at every start. **Reset settings** restores and saves the defaults.
The UART mode is saved by its own page's **Save** entry.

Mounted images are not saved: mount them again after a restart. The BIOS pack loads from
`boot0.rom` at every start.

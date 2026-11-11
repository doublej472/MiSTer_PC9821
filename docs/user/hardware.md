# Hardware the core provides

What the core emulates, as a user sees it. How each part is built and measured is in the
contributor reference, [`../pc9821-port-status.md`](../pc9821-port-status.md); what is missing is
under [Known issues](troubleshooting.md#known-issues).

## Machine and CPU

- **The NEC PC-9821Xe10**, running NEC's own Xe10 firmware (the BIOS pack). The Xe firmware set
  does not boot yet. There is no PCI bus, as on the Xe10.
- **CPU**: the z486, a 486-class CPU, without an x87 FPU. The OSD's **CPU Speed** slows it from
  `Full` down to 0.5 MHz for software that runs too fast; the settings approximate the named clock,
  and every timer and device keeps real time.
- **Memory**: 1 MB to 96 MB, set by **RAM Size** and capped by the SDRAM board.
- **I/O timing**: `Fast`, or the measured Xe10's port and graphics-memory timing (`Xe10`), for
  software that times itself by its port accesses or its drawing.
- **Calendar clock**: the uPD4990A, set from MiSTer's clock.
- **Settings**: the machine's DIP switches and BIOS SETUP items are set on the OSD's
  [DIP Switch page](options.md#dip-switch-page); the BIOS SETUP menu is not used.

## Graphics

- **Text**: 80- and 40-column ANK and JIS kanji text from the font ROM, user-defined characters,
  colour, reverse, underline, blink and the cursor, 25 or 20 lines.
- **Graphics**: 640x400 in 8 or 16 colours (digital and analogue palettes), two pages, 640x200
  modes line-doubled; the graphics GDC's drawing commands (lines, arcs, rectangles, fills,
  characters).
- **GRCG and EGC** drawing hardware.
- **PEGC 256-colour display**: the packed 256-colour mode at 640x400 and at 640x480 (the 31 kHz
  mode Windows 95 uses). The PEGC's plane mode is not implemented.
- **The 31 kHz display mode** for software that switches to it.

## Sound

- **The PC-9801-86 sound board**: the YM2608 (OPNA) with FM, SSG, the ADPCM rhythm drums (from the
  rhythm ROM in the BIOS pack) and ADPCM, and the board's PCM.
- **The built-in beeper.**
- **CD audio** from the CD-ROM drive.

Each of the three has its own level on the OSD's [Audio page](options.md#audio-page).

## MIDI

An **MPU-PC98II** MIDI interface (ports `0xE0D0`/`0xE0D2`, IRQ 6), played through MiSTer's
[MidiLink](https://github.com/bbond007/MiSTer_MidiLink): its software synths (FluidSynth or MUNT),
a USB MIDI device, or a MIDI peer on the network.

1. On the OSD's system page (F12, then Right), set **UART mode** to `MIDI`.
2. Save it with that page's **Save** entry.
3. Choose where MidiLink sends the MIDI (a software synth, a USB MIDI device or the network) as
   MidiLink's own documentation describes.
4. Pick the MPU-PC98II (or "MIDI") in the program's sound setup.

Software sees the card only while the mode is `MIDI`; otherwise programs that would pick MIDI keep
their FM music. Changing the mode removes or re-inserts the card (a reset), so set it before
starting a program. A software synth's level is set by `FSYNTH_VOLUME` / `MUNT_VOLUME` in
`MidiLink.INI` and MiSTer's volume control, not by the core's Audio page.

## Storage

- **IDE hard disk** on the first IDE connector; the second connector holds the **ATAPI CD-ROM
  drive** or a **second hard disk** (the OSD's **IDE bank 1**).
- **CD-ROM** with CD audio tracks (from `.pcd` images), and ISO data images.
- **Two floppy drives**, 2HD (1.2/1.25 MB), 1.44 MB and 2DD (640/720 KB); images are read and
  written.
- Images are files on the SD card; the [formats and converters](images.md) are listed separately.

## Input

- **Keyboard**: the PC-98 keyboard, with a US or JIS layout for your keyboard and every PC-98 key
  reachable except VF3-VF5 and APP ([key table](input.md#keyboard)).
- **Mouse**: the PC-98 bus mouse ([Mouse](input.md#mouse)).
- **Joypad**: a two-button PC-98 joypad ([Joypad](input.md#joypad)).

## Video output

- **HDMI** through MiSTer's scaler, with the **Aspect ratio** and **Scale** (integer scaling)
  options. `Original` shows the picture at the shape of NEC's monitors: 16:10 for 640x400, 4:3 for
  640x480.
- **Analog VGA**: the machine's own 24 kHz signal for a multisync monitor, or **scan doubling** to
  49 kHz for VGA monitors that cannot sync to 24 kHz. The 31 kHz mode leaves at 31.5 kHz either
  way. `vga_scaler=1` in `MiSTer.ini` puts the scaler's output on the VGA port instead.
- **Scanlines** on the doubled picture (also on HDMI while doubled).
- No 15 kHz TV, composite or S-Video output.

Details: [Analog video](options.md#analog-video).

## LEDs

| LED | lights while |
|---|---|
| disk | a hard disk, the CD drive or a floppy drive moves data |
| user | a floppy drive moves data |
| power | the BIOS pack is loaded |

The disk and user LEDs stay on briefly after each access.

# Troubleshooting

Common problems, by what you see, and the core's known issues. Per-title notes are in the
[compatibility list](compatibility.md).

## Black screen or no boot

| what you see | likely cause | what to do |
|---|---|---|
| black screen after the core starts | no BIOS pack loaded, or the wrong file | save the pack as `games/PC9821/boot0.rom` (exactly 1,048,576 bytes) and load the core again; check **DIP Switch > Machine** is `Xe10` |
| "insert system disk" with a hard disk mounted | a SASI image (256-byte sectors) | [convert it](images.md#converting-hard-disk-images) |
| black screen with a hard disk mounted | an IDE image with 4 heads | [convert it](images.md#converting-hard-disk-images) |
| an HDI image does not boot | its header is not a whole number of 512-byte sectors (or is otherwise not accepted), so it is read as a raw image | [convert it](images.md#converting-hard-disk-images) |
| `No system files`, or a black screen, after the memory count with a hard disk mounted | a floppy that is not a boot disk in drive 1: the machine runs the floppy's own boot code, which stops there (a disk formatted on a PC/AT leaves the screen black) | eject the floppy and reset, or set **Boot order** to `SASI1` |
| a 2DD boot floppy shows a black screen | **Floppy mode** is `1M` | set it to `Auto (1M)` and reset |
| no picture on an analog VGA monitor | the monitor cannot sync to 24 kHz | set **Analog video** to `Doubled 49kHz`, or `vga_scaler=1` in `MiSTer.ini` ([Analog video](options.md#analog-video)) |

## Disks and drives

| what you see | likely cause | what to do |
|---|---|---|
| second disk listed by the BIOS but an invalid drive in DOS | not laid out as 8 heads x 17 sectors | [convert it](images.md#converting-hard-disk-images) |
| no CD-ROM drive in DOS | **IDE bank 1** is `HDD2`, or the CD driver and `MSCDEX` are not loaded | set **IDE bank 1** to `CD-ROM`; see [DOS setup](dos-windows.md#configsys-and-autoexecbat) |
| a CD plays no audio tracks | a `.bin` or `.iso` mounted on its own carries only the data track | convert the CUE/BIN set to `.pcd` ([Converting CD images](images.md#converting-cd-images)) |
| `CDR101: Not ready` while CD audio plays | the CD driver refuses file reads during audio, as on the real machine | stop the audio first; not a core fault |
| a floppy image is not in the file browser | an unlisted extension | rename it ([Formats](images.md#formats)) |
| a floppy drive stays empty after mounting | an unsupported raw size, or a Virtual98 `.fdd` | [convert it](images.md#converting-floppy-images) |
| formatting a floppy image fails | D88 images cannot be formatted | format a raw `.hdm` image instead |

## Sound

| what you see | likely cause | what to do |
|---|---|---|
| drums play as a loud buzz | a pack built without the rhythm ROM | rebuild it with `OPNA_ADPCM.ROM` ([Building the BIOS pack](setup.md#building-the-bios-pack-from-your-own-dumps)) |
| a program finds no MIDI device, or plays FM instead | **UART mode** is not `MIDI` | set it on the system page and save it ([MIDI](hardware.md#midi)) |
| MIDI too loud or too quiet against the rest | MidiLink's synths are mixed after the core | set `FSYNTH_VOLUME` / `MUNT_VOLUME` in `MidiLink.INI` |

## DOS and Windows 95

| what you see | likely cause | what to do |
|---|---|---|
| "already running in virtual-86 mode" | a DOS extender that refuses EMM386/VEM486 | boot with `HIMEM.SYS` only |
| a general protection error from `VEM486` | an address range after `/U` | use plain `/U` ([DOS setup](dos-windows.md#configsys-and-autoexecbat)) |
| Windows 95 hangs on a 720 KB floppy | `NECCDM.SYS` not on the safe list | see [Windows 95](dos-windows.md#windows-95) |
| software runs too fast | it times itself by the CPU | lower **CPU Speed**, or try **I/O timing** `Xe10` |
| a game refuses to run, or scrolls wrongly | it expects the other GDC clock | change **GDC Clock** and reset |

## Settings

| what you see | likely cause | what to do |
|---|---|---|
| OSD changes are gone after reloading the core | not saved | **Save settings** on the system page ([Saving the settings](options.md#saving-the-settings)) |
| a DIP Switch change has no effect | the page applies at the next reset | reset the machine |
| a setting made in BIOS SETUP or by a program is lost after a reset | the core does not use SETUP: the **DIP Switch** page's settings apply again at every reset | set it on the DIP Switch page |

## Known issues

- Only the Xe10 firmware set works.
- Formatting a D88 floppy image fails; format a raw `.hdm` image instead.
- An HDI image is read as raw (and does not boot) if its header is not a whole number of
  512-byte sectors, its first four bytes are not zero, it declares 256-byte sectors, or a geometry
  field is zero or out of range; convert such an image.
- The BIOS SETUP menu is not used: settings SETUP or any program writes last only until the next
  reset, then the **DIP Switch** page's settings apply again. SETUP items for hardware the core
  lacks (built-in PCM sound, serial port, window accelerator, power management) do nothing; the
  PC-9801-86 board is always present.
- No PC key gives VF3-VF5, and VF2 is on F12, which opens the MiSTer menu.
- In MiSTer release 20261010, the Japanese keyboard's ろ (`_`) key arrives as カナ, toggling kana
  input; this is fixed in the next Main_MiSTer release.
- Not implemented: 16-bit WSS/MSS audio, the RS-232C serial port, the 15 kHz display mode, the
  monochrome graphics mode, and the PEGC's plane-mode drawing engine (the packed 256-colour mode
  works). The 31 kHz
  mode has not yet been checked on an analog VGA monitor.

Behaviour the real machine shares is not listed as an issue: for example, while a CD audio track
plays `NECCD.SYS` refuses file reads (`CDR101: Not ready`), as on real hardware.

# Disk and CD images

Which image formats the core mounts, how to convert the ones it does not, how to make a blank hard
disk and how to use a second one. Setting up DOS on a new disk is in
[DOS and Windows 95](dos-windows.md#setting-up-dos-on-a-new-hard-disk).

## Formats

The core recognises each format from the file's contents, not its name. The OSD's file browser
lists at most four extensions per entry, so rename other names as noted.

| drive | format | extension | notes |
|---|---|---|---|
| hard disk | raw | `.img` | 512-byte sectors, laid out as 8 heads x 17 sectors (else [convert it](#converting-hard-disk-images)) |
| | HDI | `.hdi` | 512-byte sectors; the header must be a whole number of 512-byte sectors (Anex86's default 4096-byte header works, a 32-byte one does not: convert it) |
| | fixed VHD | `.vhd` | fixed disks only; dynamic and differencing VHDs are not supported |
| floppy | D88 | `.d88` | 2DD and 2HD; read and written, but not formatted. Rename `.d98`, `.88d`, `.98d` to `.d88` |
| | raw | `.hdm`, `.fdd` | the file size picks the layout ([sizes below](#raw-floppy-sizes)). Rename `.xdf`, `.2hd` and other headerless images to `.hdm`. A Virtual98 `.fdd` is not raw: [convert it](#converting-floppy-images), or the drive stays empty |
| | FDI | `.fdi` | 2DD, 2HD or 1.44 MB; the header must be a whole number of 512-byte sectors and match the file size, else convert it |
| CD-ROM | ISO | `.iso` | 2048-byte sectors, one data track |
| | raw 2352 | `.iso`, `.bin` | raw 2352-byte MODE1 or MODE2 form 1 sectors, read as one data track |
| | PCD | `.pcd` | data and CD audio tracks; made from CUE/BIN or CloneCD ([below](#converting-cd-images)) |

Mounting or ejecting a hard disk restarts the machine; a floppy or a CD does not. An image over
4 GiB needs an exFAT SD card.

### Raw floppy sizes

Bytes; cylinders x heads x sectors x bytes per sector. A size not listed leaves the drive empty.

- 2HD: 1,261,568 (77x2x8x1024, the usual 1.25 MB disk) and the same with 78-80 cylinders
  (1,277,952 / 1,294,336 / 1,310,720); 1,228,800 (80x2x15x512, 1.2 MB 2HC); 1,474,560
  (80x2x18x512, 1.44 MB); 1,720,320 (80x2x21x512, DMF); 1,025,024 (77x2x26x256); 1,419,264
  (77x2x9x1024).
- 2DD: 655,360 (80x2x8x512, 640 KB) and 737,280 (80x2x9x512, 720 KB). A BASIC 2DD image
  (80x2x16x256) has the 640 KB size and does not work.

## Converting images

The converters are Python 3 programs in `tools/`: run them on a computer, then copy the result to
the SD card. They never modify the original file. Nothing is installed on the MiSTer.

### Converting CD images

CUE/BIN and CloneCD sets become one `.pcd` file. This is needed for CD audio: a `.bin` mounted
alone gives only its data.

```
python3 tools/cue2pcd.py GAME.cue              # writes GAME.pcd beside it
python3 tools/cue2pcd.py GAME.ccd              # a CloneCD set (single session; .sub unused)
python3 tools/cue2pcd.py --batch FOLDER        # every .cue and .ccd under FOLDER; safe to rerun
```

Only the `.pcd` goes on the SD card.

### Converting floppy images

NFD, Virtual98 FDD and unsupported FDI floppies become HDM or D88:

```
python3 tools/fdconv.py DISK.nfd               # writes DISK.hdm, or DISK.d88 if raw cannot hold it
python3 tools/fdconv.py DISK.nfd OUT.d88       # a chosen output name and format
python3 tools/fdconv.py --info DISK.nfd        # describe the disk; writes nothing
python3 tools/fdconv.py --batch FOLDER         # every .nfd, .fdi and .fdd under FOLDER
```

Some NFD r1 images carry copy-protection data a D88 cannot hold; the tool refuses them and lists
what would be lost. `--lossy` converts anyway, but such a disk may not run.

### Converting hard-disk images

The BIOS boots only disks with 512-byte sectors laid out as 8 heads x 17 sectors. Many HDI images
are SASI disks (256-byte sectors: the BIOS shows "insert system disk") or IDE disks with 4 heads
(black screen). Convert them:

```
python3 tools/pc98_hdd_convert.py OLD.hdi NEW.img                          # HDI or NHD in
python3 tools/pc98_hdd_convert.py --src-geometry 512,8,32 OLD.img NEW.img  # raw in: bytes,heads,sectors
python3 tools/pc98_hdd_convert.py --info IMAGE                             # show the layout
```

A `.img` output name writes a raw image, a `.hdi` name an HDI with a 4096-byte header (which also
fixes a short HDI header). Files and partitions are kept and checked after conversion. Disks with
a FAT32 partition are refused; non-FAT partitions are copied unchanged. The whole image is held in
memory (a 2 GB image needs several GB of RAM).

## Making a new hard disk

```
python3 tools/pc98_hdd_convert.py --new 500 NEW.img      # 500 MB (up to 4351)
python3 tools/pc98_hdd_convert.py --new 7500c NEW.img    # in cylinders (up to 65535, ~4.25 GiB)
```

The new disk is blank: partition and format it with NEC MS-DOS `FORMAT`
([Setting up DOS on a new hard disk](dos-windows.md#setting-up-dos-on-a-new-hard-disk)).

## A second hard disk

The second IDE connector holds the CD-ROM drive by default, or a second hard disk:

1. **Mount HDD2** the second image (same formats and 8 x 17 layout as the first).
2. Set **IDE bank 1** to `HDD2` (this restarts the machine).

DOS gives its partitions the letters after the first disk's. With `HDD2` selected there is no
CD-ROM drive; set it back to `CD-ROM` to use CDs (the HDD2 image stays mounted, disconnected).

#!/bin/bash
# mkimg.sh - the Xe10 kit as a bootable hard-disk image (8 heads x 17 sectors x 512 bytes, the
# core's and the Xe10 IDE BIOS's layout), so the machine boots straight into the kit.
#
#   mkimg.sh FORMATTED.hdi DOSDISK1.hdm DOSDISK4.hdm KIT_DIR OUT.img
#
# FORMATTED.hdi: a blank disk (`tools/pc98_hdd_convert.py --new 40 blank.hdi`) partitioned and
#   formatted by NEC MS-DOS 6.20's FORMAT with the system transferred. NEC's DOS is the user's
#   own and is never committed; FORMAT needs a PC-98, so it was run in NP2kai with the disk as
#   HDD1 and "MS-DOS 6.20 (installed with update) (Working disk #1)" in drive 1: FORMAT, Fixed
#   disk (固定ディスク), continue, Initialize (初期化) yes, Allocate (領域確保) whole disk from
#   cylinder 1 with System = transfer (転送する), volume label XE10KIT, execute, then quit.
# DOSDISK1.hdm: Working disk #1, for FORMAT.EXE (the 720 KB floppy, RUNLIST.TXT).
# DOSDISK4.hdm: Working disk #4, for FIND.EXE (RUNMPU.BAT), MEM.EXE and MORE.COM.
# KIT_DIR: the output of `make -C tools/hwprobe kit` (A/, W95/, RUNLIST.TXT).
# OUT.img: raw image (the HDI's 4096-byte header stripped); the DOS volume starts at
#   cylinder 1 = byte 69632.
set -euo pipefail
HDI=$1; DOS1=$2; DOS4=$3; KIT=$4; OUT=$5
HERE=$(cd "$(dirname "$0")" && pwd)
export MTOOLS_SKIP_CHECK=1
dd if="$HDI" of="$OUT.tmp" bs=4096 skip=1 status=none
V="$OUT.tmp@@69632"
mcopy -o -i "$V" "$HERE/IMG/CONFIG.SYS" "$HERE/IMG/AUTOEXEC.BAT" "$HERE/IMG/MENU.TXT" ::/
mmd -i "$V" ::/DOS ::/KIT ::/W95
for f in FIND.EXE MEM.EXE MORE.COM; do mcopy -o -i "$DOS4" ::/$f /tmp/mkimg.$$ && mcopy -o -i "$V" /tmp/mkimg.$$ ::/DOS/$f; done
mcopy -o -i "$DOS1" ::/FORMAT.EXE /tmp/mkimg.$$ && mcopy -o -i "$V" /tmp/mkimg.$$ ::/DOS/FORMAT.EXE
rm -f /tmp/mkimg.$$
mcopy -o -i "$V" "$KIT"/A/* "$KIT/RUNLIST.TXT" ::/KIT/
mcopy -o -i "$V" "$KIT"/W95/* ::/W95/
mv "$OUT.tmp" "$OUT"
mdir -/ -i "$OUT@@69632" ::

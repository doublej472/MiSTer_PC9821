#!/usr/bin/env bash
# Stage the MiSTer load set for the PC-9821 z486 core into mister_deploy/.
#
# ONE JOB: OFFLINE STAGING. It writes the same files tools/mister_load.sh provisions onto
# the card, but into a local directory for you to copy by hand. It never opens a connection
# and never touches the card, which is what makes it the alternative for a host without ssh
# access to the MiSTer. If the card is reachable, tools/mister_load.sh is the tool to use:
# it also verifies each pack against your dumps before writing it.
#
# Layout copied to the MiSTer SD card root, under the names the tools use on the card -
# which are NOT the Quartus project's. The deployed core is PC9821Z486.rbf, its
# MGL sits at the card root rather than under _Computer/, and setname PC9821 resolves the
# pack and image relative to games/PC9821/.
#   _Computer/PC9821Z486.rbf        - the compiled core
#   PC9821Z486.mgl                  - the MGL descriptor (menu entry "PC9821")
#   games/PC9821/pc98pack-xe10.bin  - firmware pack, from your dumps (F0,BIN)
#   games/PC9821/hdd.img            - your PC-98 HDD image (S0,IMG)
#   Scripts/pc9821_cue2pcd.sh       - Scripts-menu entry: CUE/BIN -> PCD on the card
#   Scripts/.pc9821/cue2pcd.py      - the converter it runs (tools/cue2pcd.py)
#
# setname PC9821 makes MiSTer resolve file paths relative to the PC9821/
# games folder, so the pack and image live there.
set -euo pipefail
cd "$(dirname "$0")/.."

deploy=mister_deploy
# The MGL's <setname> is what MiSTer names the core's per-core config file after, and what
# it resolves relative file paths against. This one value decides the games directory, the
# MGL written below, AND the name of the config file this script deliberately does not
# stage: the card's config directory is keyed by setname (it holds Genesis.CFG, SNES.CFG and
# MegaCD.CFG for those cores), so this core's is PC9821.CFG. It is NOT the RBF's name, and
# PC9821Z486.CFG has never existed; tools/check_mister_layout.py fails if the two disagree.
SETNAME=PC9821
games="$deploy/games/$SETNAME"
mkdir -p "$games" "$deploy/_Computer"

rbf=output_files/z486_mister.rbf
pack=${PC98_PACK:-build/pc98pack.bin}

if [ ! -f "$rbf" ]; then
    echo "error: $rbf not built; run the Quartus build first" >&2
    exit 1
fi
if [ ! -f "$pack" ]; then
    echo "error: $pack not found. Build it from your own dumps with" >&2
    echo "       PC98_ITF=... PC98_BIOS=... PC98_FONT=... PC98_IDE=... make pack" >&2
    exit 1
fi

cp -f "$rbf"  "$deploy/_Computer/PC9821Z486.rbf"
cp -f "$pack" "$games/pc98pack-xe10.bin"
# The Scripts-menu CUE/BIN converter (tools/mister/pc9821_cue2pcd.sh runs .pc9821/cue2pcd.py).
mkdir -p "$deploy/Scripts/.pc9821"
cp -f tools/mister/pc9821_cue2pcd.sh "$deploy/Scripts/pc9821_cue2pcd.sh"
cp -f tools/cue2pcd.py "$deploy/Scripts/.pc9821/cue2pcd.py"

# CONF_STR: "F0,BIN,Load BIOS ROM;" and "S0,IMG,Mount HDD;".
# F0 -> file type f at index 0; S0 -> mount type s at index 0.
{
    echo '<mistergamedescription>'
    echo '	<rbf>_Computer/PC9821Z486</rbf>'
    echo "	<setname>$SETNAME</setname>"
    # The disk entry must come first and the pack second. cpu_run is released
    # by the pack download, and the guest probes the drive once while the ITF
    # and BIOS start up, latching "no disk" if the image has not mounted yet.
    # mister_load.sh has always emitted this order; this script had it
    # backwards, which reproduces the M=0 K=00 no-media failure.
    echo '	<file delay="1" type="s" index="0" path="hdd.img"/>'
    echo '	<file delay="1" type="f" index="0" path="pc98pack-xe10.bin"/>'
    echo '</mistergamedescription>'
} > "$deploy/PC9821Z486.mgl"

# A STAGED CONFIG FILE MUST NOT SURVIVE A RUN OF THIS SCRIPT, and this is not hypothetical.
# mister_deploy/ is gitignored and nothing ever cleaned it, so it held
# config/PC9821Z486.CFG - 10 00 00 00 00 00 00 80 00 ... - written by an earlier version of
# this script, when the OSD lists were ascending and 16 MB had to be installed as a stored
# selection. The commit that stopped staging one could not remove what a previous run had
# already written, so the file outlived its design, and this script went on printing that
# none was staged.
#
# It is dangerous now, and correcting the config NAME is what would arm it. Byte 7 is
# status[63:61], and post-rotation list entry 4 is 1 MB - which cannot boot the Xe10 BIOS and
# freezes with a blank screen, the exact defect the rotation removed. The file is inert only
# while its name is the WRONG one: MiSTer keys the config on the MGL's <setname> = PC9821, so
# PC9821Z486.CFG is ignored. Rename it to the correct PC9821.CFG and it becomes live, and
# anyone following the README's "offline alternative: stage mister_deploy/" would copy a 1 MB
# RAM selection onto a card and freeze it.
#
# So the staged tree is swept AND THEN CHECKED. A printed assurance that nothing verifies is
# how the file survived in the first place.
mapfile -t stale_cfg < <(find "$deploy" -type f -iname '*.cfg' 2>/dev/null | sort)
if [ "${#stale_cfg[@]}" -gt 0 ]; then
    echo "removing staged config file(s) - this tool never stages one:"
    for f in "${stale_cfg[@]}"; do
        echo "  $f"
        echo "    was: $(od -An -tx1 "$f" | tr -s ' ' | sed 's/^ //')"
        rm -f "$f"
    done
    # the directory that held them is not part of the load set either
    find "$deploy" -type d -name config -empty -delete 2>/dev/null || true
    echo
fi

remaining_cfg=$(find "$deploy" -type f -iname '*.cfg' 2>/dev/null || true)
if [ -n "$remaining_cfg" ]; then
    echo "ERROR: $deploy still holds a config file; refusing to report a clean stage:" >&2
    printf '%s\n' "$remaining_cfg" | sed 's/^/  /' >&2
    exit 1
fi

# What is actually staged, listed from the tree rather than asserted.
echo "Staged MiSTer load set in $deploy/:"
find "$deploy" -type f | sort | sed "s|^$deploy/|  |"
echo

# CONF_STR: "F0,BIN,Load BIOS ROM;" and "S0,IMG,Mount HDD;".
# F0 -> file type f at index 0; S0 -> mount type s at index 0.
#
# WHY NO CONFIG IS STAGED, and why the check above is the point. MiSTer gives a CONF_STR option
# no default entry, so a card with no stored selection passes 0 for every field; the OSD lists
# were rotated so that entry 0 IS the wanted default - 16 MB of RAM - which makes a missing file
# correct rather than a compromise. Until the rotation entry
# 0 was the ascending list's 1 MB, a 1 MB guest cannot run the Xe10 BIOS at all, and the core
# froze with nothing on screen, indistinguishable from broken RTL; the workaround was to
# install a config, which only worked when someone remembered to.
#
# AND A STAGED CONFIG WOULD BE WORSE THAN USELESS, because copying this tree onto a card would
# overwrite /media/fat/config/PC9821.CFG and destroy whatever RAM size the user selected in
# the OSD. tools/mister_load.sh is the one place that handles that file, and it only reports
# on it. This script stages files the card does not already own.
echo "NO *.CFG is staged anywhere under $deploy - the listing above is the check, not a claim."
echo "That matters because MiSTer keys the core's config on the MGL's <setname>, so this"
echo "core's file is /media/fat/config/PC9821.CFG, and a staged one would overwrite the RAM"
echo "size you selected in the OSD. Do NOT copy one onto a card; with the rotated OSD"
echo "lists a MISSING file IS the default. tools/mister_load.sh reports on that file and warns"
echo "if it predates the rotation."
echo
echo "Copy your PC-98 HDD image into the games folder as:"
echo "  games/PC9821/hdd.img"
echo
echo "Select the PC9821 entry in the MiSTer menu. The MGL loads the ROM pack,"
echo "mounts hdd.img, and the core boots the disk."

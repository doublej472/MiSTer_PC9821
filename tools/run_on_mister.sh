#!/usr/bin/env bash
# Run the core on the MiSTer and read its telemetry, over SSH. No physical access needed.
#
# ONE JOB: START THE CORE AND READ IT. This script writes no file to the card - the only
# thing it sends is the load_core command. Provisioning (the RBF, the firmware packs, the
# MGLs, the disk image) is tools/mister_load.sh's job; staging the same set offline is
# tools/deploy_mister.sh's; rearranging the pack files already on the card is
# tools/mister_packs.sh's. Run tools/mister_load.sh first, then this.
#
# THE DEVICE. MISTER_HOST is the ssh destination (default root@MiSTer; a bare host name gets
# root@). password 1 (the stock root password) by default via sshpass -e; MISTER_PASS= uses ssh keys. The SD card is
# /media/fat.
#
# HOW THE CORE IS CONTROLLED. The MiSTer binary creates /dev/MiSTer_cmd as a FIFO, and writing a
# command to it is the supported remote-control path:
#
#     echo "load_core /media/fat/PC9821Z486.mgl" > /dev/MiSTer_cmd
#
# The MGL carries the disk and the firmware pack, so loading the MGL gives the guest its drive.
#
# HOW THE CORE IS READ. The core emits ONE LINE per trigger over its debug UART: a 277-character
# stall record, then a 40-byte PRF record with the interval's memory-wait and SDRAM transaction
# counters, each line ended by a single LF. The UART appears on the HPS as /dev/ttyS1 at 115200
# 8N1. Reading it is a plain cat:
#
#     timeout 12 cat /dev/ttyS1
#
# The stall record's LAST byte is the LF that ends the line; the byte BEFORE it says WHICH trigger
# fired, which is the whole reason the field exists. That byte names WHICH of three conditions the
# machine was in, and this is the one thing in the record that separates a stopped machine from a
# healthy one (the trigger is emitted before the newline, so a tty's CR-to-LF translation
# can never glue it to the next record's start):
#
#   W  a request is OUTSTANDING and has not completed for 200 ms  - THE WEDGE. It has stopped.
#   S  no request for 200 ms                                      - halted, or a long I/O wait.
#   P  the 2 s heartbeat                                          - says NOTHING on its own.
#
# P IS NOT EVIDENCE OF PROGRESS, and this file used to say the opposite. A wedged CPU holds its
# request valid (z_valid is a level), so the old stall condition, `!z_valid && ...`, was gated
# out by the very failure it was added to report, and every capture read P - which was then read
# as "the CPU is still issuing requests". An all-P capture is exactly what a wedge looks like.
# The stall condition now keys on a request COMPLETING, not arriving.
#
# Usage:
#   tools/run_on_mister.sh state             what the card runs, what it holds, and what is local
#   tools/run_on_mister.sh load              load the MGL through /dev/MiSTer_cmd
#   tools/run_on_mister.sh capture [seconds] capture the serial only
#   tools/run_on_mister.sh decode FILE       decode a capture
#   tools/run_on_mister.sh boot [seconds]    load, wait, capture, and decode
#   tools/run_on_mister.sh loop [seconds]    boot, but REFUSE if the card is not running the
#                                            local RBF - the hardware iteration loop
#
# It does NOT build and it does NOT deploy. Build with tools/container_build.sh, ideally ALONE:
# a fit that dies with dyn_enum.cpp is the machine, and a fit that dies in Analysis and Synthesis
# is usually non-ASCII in a comment - two different failures, two different responses.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${MISTER_HOST:-root@MiSTer}"
case $HOST in *@*) ;; *) HOST=root@$HOST ;; esac
# Authentication: password "1" (the stock MiSTer root password) by default, through sshpass -e (it reads
# SSHPASS from the environment, so the password never appears on a command line).
SSHPASS_CMD=()
MISTER_PASS="${MISTER_PASS-1}"   # the stock MiSTer root password; MISTER_PASS= (empty) uses ssh keys
if [ -n "$MISTER_PASS" ]; then export SSHPASS="$MISTER_PASS"; SSHPASS_CMD=(sshpass -e); fi

CARD_CORE="/media/fat/_Computer/PC9821Z486.rbf"
CARD_MGL="/media/fat/PC9821Z486.mgl"
RBF="$REPO/output_files/z486_mister.rbf"

SSH=("${SSHPASS_CMD[@]}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$HOST")
# Local scratch is per card: two runs against two cards must not share a capture file.
HOST_SLUG="$(printf '%s' "${HOST#*@}" | tr -c 'A-Za-z0-9._-' '_')"
SCRATCH="${MISTER_SCRATCH:-$REPO/.build/mister/$HOST_SLUG}"
mkdir -p "$SCRATCH"
CAPTURE_FILE="$SCRATCH/capture.txt"

# sshd on the card prints a post-quantum warning to stderr on every connection; it is not ours.
quiet() { grep -viE 'WARNING|vulnerable|store now|upgraded|openssh.com/pq' || true; }

cmd_state() {
    echo "== what the card is running"
    "${SSH[@]}" 'ps -eo args 2>/dev/null | grep -E "^/media/fat/MiSTer" | head -1' 2>&1 | quiet | sed 's/^/  /'
    echo "== the core on the card"
    "${SSH[@]}" "ls -la $CARD_CORE 2>/dev/null; echo -n '  sha256: '; sha256sum $CARD_CORE 2>/dev/null | cut -d' ' -f1" 2>&1 | quiet | sed 's/^/  /'

    # MISTER KEYS THE CONFIG FILE ON THE MGL'S <setname>, NOT ON THE RBF'S NAME. The card's
    # config directory holds <setname>.CFG for every core (Genesis.CFG, SNES.CFG, MegaCD.CFG
    # and so on), so this core's is PC9821.CFG - and PC9821Z486.CFG has never existed. A check
    # built on the RBF name inspects a file that is never there and reports "absent - correct"
    # whatever the card actually holds, which is exactly how the pre-rotation warning this
    # block exists to give went silent. So read the setname off the MGL that is loaded.
    echo "== the MGL, and the config file its setname selects"
    local setname
    setname="$("${SSH[@]}" "sed -n 's|.*<setname>\([^<]*\)</setname>.*|\1|p' $CARD_MGL 2>/dev/null | head -1 | tr -d '\r'" 2>/dev/null || true)"
    if [ -n "$setname" ]; then
        echo "  $CARD_MGL declares <setname>$setname</setname>"
    else
        setname=PC9821
        echo "  could NOT read $CARD_MGL; falling back to setname $setname"
    fi
    local cfg="/media/fat/config/$setname.CFG"
    local bytes
    bytes="$("${SSH[@]}" "test -f '$cfg' && od -An -tx1 '$cfg' | tr -d ' \n'" 2>/dev/null || true)"
    if [ -z "$bytes" ]; then
        echo "  $cfg  ABSENT - and that is correct: with the rotated OSD lists a missing"
        echo "     file IS the default (16 MB of RAM)"
    else
        echo "  $cfg  present, $((${#bytes} / 2)) bytes: $(echo "$bytes" | sed 's/../& /g')"
        case "$bytes" in
            *[!0]*)
                echo "     ^ NON-ZERO. If this predates the OSD rotation it now selects a"
                echo "       DIFFERENT size: the old 16 MB value is list entry 4, which is 1 MB,"
                echo "       and a 1 MB guest cannot boot the Xe10 BIOS - it freezes with a blank"
                echo "       screen. Fix it on the card (either is enough):"
                echo "         ssh root@<mister> 'rm $cfg'"
                echo "         ssh root@<mister> 'dd if=/dev/zero of=$cfg bs=16 count=1'"
                echo "       or re-select the size in the OSD, which rewrites the file." ;;
            *)
                echo "     all zero: that IS the default now (16 MB)" ;;
        esac
    fi

    echo "== the MGL and the packs it loads"
    "${SSH[@]}" "if [ -f $CARD_MGL ]; then wc -c < $CARD_MGL | sed 's/^/  mgl bytes: /'; else echo '  (no MGL on the card yet: run tools/mister_load.sh)'; fi
       sed -n 's|.*<file[^>]*type=\"f\"[^>]*path=\"\([^\"]*\)\".*|  pack the MGL names: \1|p' $CARD_MGL 2>/dev/null
       ls -l /media/fat/games/PC9821/*.bin 2>/dev/null | awk '{printf \"  %-44s %s bytes\n\", \$NF, \$5}'" 2>&1 | quiet | sed 's/^/  /'

    # output_files/ IS A COPY DESTINATION, NOT A SOURCE OF TRUTH: a build that ran in a lane
    # leaves its artefact there and never touches this tree, so the file can be arbitrarily old.
    # fit-source.sha256 describes the RTL a fit was built FROM and cannot identify a bitstream,
    # so this reports what is known rather than pretending to verify it.
    echo "== the local build"
    if [ -f "$RBF" ]; then
        echo "  $RBF  $(stat -c%s "$RBF") bytes"
        echo "  sha256 $(sha256sum "$RBF" | cut -d' ' -f1)"
        if [ -f "$REPO/output_files/fit-source.sha256" ]; then
            echo "  built in  $(sed -n 's/^tree: //p' "$REPO/output_files/fit-source.sha256")"
            echo "  rtl-hash  $(sed -n 's/^rtl-hash: //p' "$REPO/output_files/fit-source.sha256")"
            # The clock is not in the RTL hash and never was: a profile switch rewrites both
            # the localparam and the generated PLL. A bitstream that cannot name its clock is
            # one you cannot compare with another.
            echo "  profile   $(sed -n 's/^profile: //p' "$REPO/output_files/fit-source.sha256"), clock $(sed -n 's/^clock: //p' "$REPO/output_files/fit-source.sha256") Hz"
            echo "  (that evidence describes the RTL, not this bitstream: if the RBF was copied"
            echo "   here by hand, confirm it came from the tree named above)"
        else
            echo "  no fit-source.sha256 beside it - this RBF has no recorded provenance"
        fi
        if [ -f "$REPO/output_files/artifact-timing.json" ]; then
            python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
v=d.get("hdmi_setup", d.get("other_setup"))
t=d.get("hdmi_tns", d.get("other_tns"))
print("  pll_hdmi %s ns (seed %s, TNS %s)" % ("-" if v is None else "%+.3f" % v,
      d.get("seed", "?"), "-" if t is None else "%.3f" % t))' \
                "$REPO/output_files/artifact-timing.json" 2>/dev/null || true
        fi
        echo "  to put it on the card:  tools/mister_load.sh"
    else
        echo "  NO LOCAL RBF - build first with tools/container_build.sh"
    fi
}

cmd_load() {
    echo "== load_core $CARD_MGL"
    "${SSH[@]}" "echo 'load_core $CARD_MGL' > /dev/MiSTer_cmd && echo '  sent'" 2>&1 | quiet | sed 's/^/  /'
}

cmd_capture() {
    local secs="${1:-12}"
    echo "== capturing /dev/ttyS1 for ${secs}s"
    "${SSH[@]}" "stty speed 115200 -F /dev/ttyS1" 2>/dev/null || true
    "${SSH[@]}" "timeout $secs cat /dev/ttyS1" 2>/dev/null > "$CAPTURE_FILE" || true
    echo "  $(stat -c%s "$CAPTURE_FILE") bytes -> $CAPTURE_FILE"
    if [ ! -s "$CAPTURE_FILE" ]; then
        echo "  NOTHING CAPTURED. Either the core is not running, or it has not reached a trigger."
        echo "  Check 'state', and give the guest longer - the first message is usually at ~2 s."
    fi
}

cmd_boot() {
    local secs="${1:-12}"
    cmd_load
    echo "== waiting 25s for the guest to reach its stall"
    sleep 25
    cmd_capture "$secs"
    echo
    cmd_decode "$CAPTURE_FILE"
}

# THE HARDWARE LOOP, AND THE ONE THING IT MUST NOT DO IS MEASURE THE WRONG BITSTREAM.
# A measurement of an artifact you did not just build is worse than no measurement, because it
# reads as a result. out-of-tree tooling and fit reports have each bitten this
# tree that way: a
# report for one tree was read as another's. So compare the card's RBF against the local one and
# stop on a mismatch, naming both hashes. PC9821_ALLOW_STALE=1 overrides, deliberately loudly,
# for the case where the card is running something you built elsewhere and mean to measure.
cmd_loop() {
    local secs="${1:-12}"
    if [ ! -f "$RBF" ]; then
        echo "NO LOCAL RBF at $RBF" >&2
        echo "  build it first:  tools/container_build.sh" >&2
        return 1
    fi
    local local_sha card_sha
    local_sha="$(sha256sum "$RBF" | cut -d' ' -f1)"
    card_sha="$("${SSH[@]}" "sha256sum $CARD_CORE 2>/dev/null | cut -d' ' -f1" 2>/dev/null | tr -d '\r' || true)"
    echo "== the bitstreams"
    echo "  local $local_sha"
    echo "  card  ${card_sha:-(could not read $CARD_CORE)}"
    if [ "$local_sha" != "$card_sha" ]; then
        echo
        echo "  THEY DIFFER - the card is not running the tree you just built." >&2
        echo "  Deploy it:  tools/mister_load.sh" >&2
        echo "  Or measure what is on the card anyway:  PC9821_ALLOW_STALE=1 $0 loop $secs" >&2
        if [ "${PC9821_ALLOW_STALE:-0}" != "1" ]; then
            return 1
        fi
        echo "  PC9821_ALLOW_STALE=1 is set: measuring what is on the card, which may not be" >&2
        echo "  the local build. Every number below is about THAT artifact." >&2
    fi
    if [ -f "$REPO/output_files/fit-source.sha256" ]; then
        local prof clk
        prof="$(sed -n 's/^profile: //p' "$REPO/output_files/fit-source.sha256")"
        clk="$(sed -n 's/^clock: //p' "$REPO/output_files/fit-source.sha256")"
        if [ -n "$prof" ] && [ -n "$clk" ]; then
            echo "  profile $prof, clock $clk Hz"
        else
            # An attribution written before the profile/clock fields existed. Say so rather
            # than printing an empty pair, which reads like a real reading of nothing.
            echo "  profile and clock NOT RECORDED (this attribution predates those fields);"
            echo "    the running clock cannot be read from it, so do not assume the base 50 MHz"
        fi
    fi
    echo
    cmd_boot "$secs"
}

cmd_decode() {
    local f="${1:?usage: decode FILE}"
    python3 "$REPO/tools/decode_telemetry.py" "$f"
}

case "${1:-}" in
    load)    cmd_load ;;
    capture) cmd_capture "${2:-12}" ;;
    boot)    cmd_boot "${2:-12}" ;;
    loop)    cmd_loop "${2:-12}" ;;
    decode)  cmd_decode "${2:-}" ;;
    state)   cmd_state ;;
    *)
        sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 2 ;;
esac

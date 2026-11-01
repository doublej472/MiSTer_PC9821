#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
BUILD=tests/pc9821/build
RUN_DIR=$BUILD/userdisk
OBJ=$RUN_DIR/obj
mkdir -p "$RUN_DIR"

# The DISK is the argument, or PC98_USERDISK. A disk is not firmware, so it has no
# pack and stays a separate input; the firmware is PC98_PACK, further down.
IMAGE=${PC98_USERDISK:-}
SECTORS=32768
COMPILE_ONLY=0
# IMAGE_FROM_ARG, not `-z "$IMAGE"`: pre-seeding IMAGE from PC98_USERDISK made the first
# POSITIONAL image fall through to SECTORS, so "run_userdisk.sh $IMG" computed WORDS from
# an arithmetic expression containing a path. Every caller that passed the image BOTH ways
# (run.sh, measure.sh) hit it; it was invisible while the disk tier was skipped.
IMAGE_FROM_ARG=0
for arg in "$@"; do
  case "$arg" in
    --compile-only) COMPILE_ONLY=1 ;;
    *)
      if [[ $IMAGE_FROM_ARG == 0 ]]; then IMAGE=$arg; IMAGE_FROM_ARG=1; else SECTORS=$arg; fi
      ;;
  esac
done
# +banks is unconditionally on: the pack always carries the eight 32 KiB ROM banks
# (see the FIRMWARE note below), and the TB loads them from the pack's own area.
RUN_ARGS=(+USERDISK +banks)
# CYCLES=<n> shortens the run for a boot trace (the TB dumps TRAM + a screen PPM at the end).
if [[ -n "${CYCLES:-}" ]]; then RUN_ARGS+=(+CYCLES=$CYCLES); fi
# Extra plusargs, so runtime measurement controls and probes need no edit here:
#   TB_ARGS="+STOP_AT_PC=000fc6b5" bash tests/pc9821/run_userdisk.sh <image>
if [[ -n "${TB_ARGS:-}" ]]; then read -r -a _extra <<< "$TB_ARGS"; RUN_ARGS+=("${_extra[@]}"); fi
# USERDISK_IMG_FILE=1: serve sectors from the image FILE at run time (+IMG_FILE), so an
# image of any size boots whole; the .mem then only carries the first SECTORS for the
# bench's IPL-data check.
USERDISK_IMG_FILE=${USERDISK_IMG_FILE:-0}

# A late-mount variant: the image arrives only after the guest has started
# (USERDISK_LATE_MOUNT=1). It uses its own build directory so the two variants
# cannot share a Verilator cache.
LATE_MOUNT=${USERDISK_LATE_MOUNT:-0}

# The I/O-latency profile variant (USERDISK_IO=faithful): the same source built with
# -DIO_FAITHFUL, which selects IO_LATENCY_PROFILE 2 - the machine's measured access
# TIMES from docs/probes/IO.TXT - for the tier's pc9821_system. It is the compile-time
# devkit switch (build_profile.py's 'iofaithful' profile is the same one variable at
# the top level), so the two sides of a boot A/B differ in exactly that one constant -
# which is what makes the delta attributable rather than a two-variable comparison.
# Its own build directory, for the same reason LATE_MOUNT has one.
IO_VARIANT=${USERDISK_IO:-min}
IO_DEFINE=()
VARIANT_SUFFIX=""
if [[ $LATE_MOUNT == 1 ]]; then
  VARIANT_SUFFIX="-late"
fi
if [[ $IO_VARIANT == faithful ]]; then
  VARIANT_SUFFIX="$VARIANT_SUFFIX-faithful"
  IO_DEFINE=(-DIO_FAITHFUL)
fi
# USERDISK_CD=1: the CD-ROM build (-DUSERDISK_CD; CD image via TB_ARGS="+CD_FILE=<path>").
if [[ ${USERDISK_CD:-0} == 1 ]]; then
  VARIANT_SUFFIX="$VARIANT_SUFFIX-cd"
fi
# USERDISK_SDPH=1: the run-time SDRAM_CLK phase instrument's build (-DUSERDISK_SDPH): the guest
# ports 0x5FF0/0x5FF2 exist and step a PLL MODEL (no real phase moves), so a DOS program that
# drives them (tools/hwprobe/sdshmoo) runs its whole control path here.
if [[ ${USERDISK_SDPH:-0} == 1 ]]; then
  VARIANT_SUFFIX="$VARIANT_SUFFIX-sdph"
fi
# USERDISK_SYSFREQ=<hz> / USERDISK_CACHE_BITS=<n>: the system's clk_sys and cache set bits
# (default 50 MHz, 4); the card runs CLOCK_RATE_HZ and z486_mister.sv's *_SET_BITS.
FREQ_DEFINE=()
if [[ -n ${USERDISK_SYSFREQ:-} ]]; then
  VARIANT_SUFFIX="$VARIANT_SUFFIX-f$USERDISK_SYSFREQ"; FREQ_DEFINE+=(-DTB_SYS_FREQ="$USERDISK_SYSFREQ")
fi
if [[ -n ${USERDISK_CACHE_BITS:-} ]]; then
  VARIANT_SUFFIX="$VARIANT_SUFFIX-c$USERDISK_CACHE_BITS"; FREQ_DEFINE+=(-DTB_CACHE_BITS="$USERDISK_CACHE_BITS")
fi
if [[ -n $VARIANT_SUFFIX ]]; then
  RUN_DIR=$BUILD/userdisk$VARIANT_SUFFIX
  OBJ=$RUN_DIR/obj
  mkdir -p "$RUN_DIR"
fi

# FIRMWARE IS THE PACK, AND NOTHING ELSE. The core has exactly one firmware input:
# pc9821_rom_loader.sv ingests the ioctl stream that a .bin in the MGL drives. So
# this bench reads the same file the core reads, and there is nothing else to point
# at - no separate ITF, BIOS, font or IDE ROM, because the pack already carries the
# reset ITF (bank 4), both halves of the main BIOS, the ANK window, the IDE option
# ROM (bank 3), the eight 32 KiB banks and the character generator.
#
#   PC98_PACK   the pack. Defaults to build/pc98pack.bin, which is where
#               'make pack' puts it, so the usual run needs no variable at all.
#
# The banks are the part that matters most. The ITF and main BIOS select them
# through port 0x043F and then execute what 0xF8000 shows (BANK4@0x253E/0x2551
# select bank 3/4, BANK6@0x5308 writes 0xE2 and copies 0x21F8 words out of the
# window), so a pack built without them hands the guest 0xFF where its own code
# should be, and nothing downstream can tell that from a core bug.
PACK=${PC98_PACK:-build/pc98pack.bin}
if [[ ! -f "$PACK" ]] && [[ $COMPILE_ONLY == 1 ]]; then
  # --compile-only answers a different question - does this tree still ELABORATE - and
  # the pack is a RUNTIME input ($readmemh), so its absence cannot fail a build. Said
  # out loud rather than assumed, and only on this path: a run without a pack above
  # still skips.
  echo "note: compile-only, and no pack at $PACK: not needed to elaborate the tier" >&2
elif [[ ! -f "$PACK" ]]; then
  # A missing pack is the EXPECTED state of a fresh checkout: the ROMs are runtime
  # inputs and none are vendored. So this skips - but loudly, naming the command
  # that fixes it. Never a pass, and never a silent exit 0.
  echo "SKIPPED (no firmware pack): $PACK does not exist." >&2
  echo "Build one from your own dumps, then re-run:" >&2
  echo "  make pack PC98_DUMPS=/path/to/your/dumps" >&2
  echo "or point PC98_PACK at a pack you already have." >&2
  exit 77
fi
# The benches $readmemh the pack's 16-bit image rather than the .bin, so 'make pack'
# writes both beside each other. A pack without its .mem is an incomplete pack.
PACK_MEM=${PACK%.*}.mem
if [[ ! -f "$PACK_MEM" ]] && [[ $COMPILE_ONLY == 0 ]]; then
  echo "$PACK_MEM is missing: it is the benches' view of $PACK, written by 'make pack'." >&2
  echo "Rebuild the pair together:  make pack PC98_DUMPS=/path/to/your/dumps" >&2
  exit 77
fi
if [[ -f "$PACK" ]] && [[ -f "$PACK_MEM" ]]; then
ln -sfn "$(cd "$(dirname "$PACK")" && pwd)/$(basename "$PACK")" "$RUN_DIR/pc98pack.bin"
ln -sfn "$(cd "$(dirname "$PACK_MEM")" && pwd)/$(basename "$PACK_MEM")" "$RUN_DIR/pc98pack.mem"
echo "firmware pack: $PACK ($(stat -c %s "$PACK") bytes, sha256 $(sha256sum "$PACK" | cut -c1-16)...)"
fi

# Verify the pack against the dumps WHEN THEY ARE AT HAND. This is the one place
# both the pack and the dumps are known, and it catches the failure that looks
# exactly like a core bug: a pack built from another machine's dump, or edited
# after the fact. It is optional because PC98_PACK alone is a complete input, and
# 'make pack' already verified the pack it wrote.
DUMPS=${PC98_DUMPS:-${PC98_BANKS:-}}
if [[ -n "$DUMPS" ]] && [[ -f "$PACK" ]] && [[ -f "$PACK_MEM" ]]; then
  rhythm_args=()
  if [[ -n "${PC98_RHYTHM:-}" ]]; then rhythm_args=(--rhythm "$PC98_RHYTHM"); fi
  python3 tools/check_pack.py \
    --pack "$PACK" \
    --mem "$PACK_MEM" \
    --itf "$DUMPS/BANK4.BIN" \
    --bios "$DUMPS/BIOS.ROM" \
    --ide "$DUMPS/BANK3.BIN" \
    --font "$DUMPS/FONT.ROM" \
    --banks "$DUMPS" \
    "${rhythm_args[@]}"
else
  echo "note: PC98_DUMPS/PC98_BANKS unset, so this run does not cross-check the pack"
  echo "      against your dumps; set it (or use 'make pack') to have it verified."
fi

if [[ -z "$IMAGE" ]] && [[ $COMPILE_ONLY == 0 ]]; then
  echo "usage: $0 <disk-image> [sectors] [--compile-only]" >&2
  echo "   or:  PC98_USERDISK=/path/to/disk.img $0" >&2
  echo "example: $0 /path/to/<your-disk>.img 32768" >&2
  echo "firmware comes from build/pc98pack.bin ('make pack'); PC98_PACK overrides it." >&2
  exit 2
fi
if [[ -n "$IMAGE" ]] && [[ ! -f "$IMAGE" ]]; then
  echo "$0: no such disk image: $IMAGE" >&2
  exit 2
fi

WORDS=$((SECTORS * 256))

DISK_MEM=$RUN_DIR/userdisk.mem
MEMKEY=$RUN_DIR/userdisk.mem.key
KEY="$(stat -c '%n %s %Y' "$IMAGE" 2>/dev/null || echo missing) sectors=$SECTORS words=$WORDS"
if [[ $COMPILE_ONLY == 1 ]]; then
  # The disk is a runtime input too ($readmemh), and its .mem is generated FROM the image,
  # so neither is needed to elaborate this tier.
  echo "note: compile-only, so the disk image and its .mem are not consulted" >&2
elif [[ -f "$DISK_MEM" && -f "$MEMKEY" && "$(cat "$MEMKEY" 2>/dev/null)" == "$KEY" ]]; then
  echo "==> reusing userdisk.mem ($SECTORS sectors; image unchanged since it was written)"
else
  echo "==> generating userdisk.mem from $IMAGE ($SECTORS sectors, $WORDS words)"
  python3 - "$IMAGE" "$SECTORS" "$DISK_MEM" <<'PY'
import sys
img, sectors, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(img, "rb") as f:
    data = f.read(sectors * 512)
with open(out, "w") as o:
    for i in range(len(data) // 2):
        o.write(format(int.from_bytes(data[2*i:2*i+2], "little"), "04x") + "\n")
PY
  echo "$KEY" > "$MEMKEY"
fi

for hex in ucode.hex pla_entry_rom.hex pla_group_entry.hex; do
  ln -sfn "$ROOT/src/z486/$hex" "$RUN_DIR/$hex"
done

source tests/pc9821/z486_rtl.sh
RTL=("${PC9821_Z486_RTL[@]}" tests/pc9821/tb_pc9821_userdisk.sv)
if [[ ${USERDISK_SDPH:-0} == 1 ]]; then
  RTL+=(src/pc9821/core/pc9821_sdram_phase_ctl.sv src/pc9821/core/pc9821_sdram_dps.sv)
fi

# Bounded on purpose, not -j 0: this is the integrated tier and several lanes may
# run it at once, so N lanes each taking every core on one machine is
# thrashing rather than parallelism. Same variable and default as the other runners;
# VERILATOR_JOBS=0 takes everything for a lane
# that has the machine to itself.
verilator --binary --timing -j "${VERILATOR_JOBS:-8}" -O2 -Wall -Wno-fatal \
  -Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -Wno-SYNCASYNCNET \
  -DIMG_WORDS="$WORDS" \
  "${IO_DEFINE[@]}" "${FREQ_DEFINE[@]}" \
  $([[ $LATE_MOUNT == 1 ]] && echo -DLATE_MOUNT) \
  $([[ ${USERDISK_CD:-0} == 1 ]] && echo -DUSERDISK_CD) \
  $([[ ${USERDISK_SDPH:-0} == 1 ]] && echo -DUSERDISK_SDPH) \
  -I"$Z" -I"$X" --top-module tb_pc9821_userdisk --Mdir "$OBJ" "${RTL[@]}"

if [[ $COMPILE_ONLY == 1 ]]; then
  # The tier's own compile-only verdict line, so a caller (and the gate that runs all
  # three) can read the result without parsing verilator's log.
  echo "USERDISK: COMPILE OK  (elaborated, not run)"
else
  # 600 s, not 1800: the bench's own budget is 100M cycles (~300 s at the measured
  # throughput) and it now stops on success, so a hang here is a bug, not patience.
  if [[ $USERDISK_IMG_FILE == 1 ]]; then RUN_ARGS+=("+IMG_FILE=$(cd "$(dirname "$IMAGE")" && pwd)/$(basename "$IMAGE")"); fi
  (cd "$RUN_DIR" && timeout "${BENCH_TIMEOUT_INT:-600}" ./obj/Vtb_pc9821_userdisk "${RUN_ARGS[@]}")
fi

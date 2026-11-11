#!/usr/bin/env bash
# The integrated boot tier: the diagnostic pack through the real CPU/memory/IO path.
#
#   bash tests/pc9821/run_boot.sh                 build and run (golden CYCLES used=930528)
#   bash tests/pc9821/run_boot.sh --compile-only  elaborate the tier only, no run
#
# --compile-only exists because this tier is outside `tools/bench.py --all` (it needs no
# external input at all, but it is slow), so a hierarchy rename can break it with every
# bench in the battery still green - which is exactly what happened to `userdisk`
# (AGENTS.md, "the integrated benches are outside the battery"). The compile is the cheap
# half and it is the half that catches that class.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
BUILD=tests/pc9821/build
OBJ=$BUILD/obj_boot
mkdir -p "$BUILD"
COMPILE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --compile-only) COMPILE_ONLY=1 ;;
    *) echo "$0: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

./firmware/diagnostic/build.py \
  --out "$BUILD/diagnostic_pack.bin" \
  --mem "$BUILD/diagnostic_pack.mem"
for hex in ucode.hex pla_entry_rom.hex pla_group_entry.hex; do
  ln -sfn "$ROOT/src/z486/$hex" "$BUILD/$hex"
done

source tests/pc9821/z486_rtl.sh
RTL=("${PC9821_Z486_RTL[@]}" tests/pc9821/tb_pc9821_boot.sv \
     tests/pc9821/sdram_backend_model.sv)

# Bounded on purpose, not -j 0. Many lanes build benches concurrently in their own
# checkouts on one machine, and N lanes each taking every core is thrashing
# rather than parallelism - it was -j 0 here and that is the real reason concurrent
# work looked fragile. Same variable and same default as the other runners;
# VERILATOR_JOBS=0 takes everything for a lane that has
# the machine to itself.
verilator --binary --timing -j "${VERILATOR_JOBS:-8}" -O2 -Wall -Wno-fatal \
  -Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -Wno-SYNCASYNCNET \
  -I"$Z" -I"$X" --top-module tb_pc9821_boot --Mdir "$OBJ" "${RTL[@]}"

BOOT_LOG="$BUILD/boot.log"
if [[ $COMPILE_ONLY == 1 ]]; then
  echo "BOOT: COMPILE OK  (elaborated, not run)"
  exit 0
fi
(cd "$BUILD" && timeout "${BENCH_TIMEOUT_INT:-300}" ./obj_boot/Vtb_pc9821_boot) | tee "$BOOT_LOG"

# The boot's cycle count is the project's timing regression guard. The
# bench $fatal(1)s on any deviation (which fails this script through pipefail), and this
# asserts the printed line too, so a future refactor that turned that fatal back into a
# display cannot leave the tier green while the boot has moved.
if ! grep -qE '^CYCLES used=930528 of 20000000 .*backend= *real timing$' "$BOOT_LOG"; then
  echo "run_boot.sh: the boot did not report the required 'CYCLES used=930528 ... backend=real timing' line" >&2
  exit 1
fi

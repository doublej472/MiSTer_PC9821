#!/usr/bin/env bash
# The integrated boot tier on the REAL SDRAM controller (tb_pc9821_boot.sv with BOOT_REAL_SDRAM):
# the same diagnostic-pack boot as run_boot.sh, with every memory access through the core's SDRAM
# backend (split_sdram_backend over sdram_sync_bridge over src/memory/sdram.v) and sdram_chip_model
# checking every protocol, -7 AC and tREFI rule, so a controller change shows up as a cycle count
# here where the boot golden (run_boot.sh, a fixed-latency model) cannot see it.
#
#   bash tests/pc9821/run_boot_real.sh                 build and run
#   bash tests/pc9821/run_boot_real.sh --compile-only  elaborate only
#
# The count is pinned by BOOT_CYCLES_REAL_SDRAM in the bench (CYCLES used=942542): any other
# count is fatal there, and this script also requires the bench's "CYCLES ASSERTED" line. Its own
# object directory (obj_boot_real), but still a heavy job: run it beside no other boot tier.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
BUILD=tests/pc9821/build
OBJ=$BUILD/obj_boot_real
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
     tests/pc9821/sdram_backend_model.sv \
     src/memory/sdram.v src/memory/sdram_sync_bridge.sv src/memory/split_sdram_backend.sv \
     tests/pc9821/sdram_chip_model.sv)

verilator --binary --timing -j "${VERILATOR_JOBS:-8}" -O2 -Wall -Wno-fatal \
  -Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -Wno-SYNCASYNCNET +define+BOOT_REAL_SDRAM \
  -I"$Z" -I"$X" --top-module tb_pc9821_boot --Mdir "$OBJ" "${RTL[@]}"

BOOT_LOG="$BUILD/boot_real.log"
if [[ $COMPILE_ONLY == 1 ]]; then
  echo "BOOT_REAL: COMPILE OK  (elaborated, not run)"
  exit 0
fi
(cd "$BUILD" && timeout "${BENCH_TIMEOUT_INT:-300}" ./obj_boot_real/Vtb_pc9821_boot) | tee "$BOOT_LOG"

if ! grep -qE '^CYCLES used=[0-9]+ of 20000000 .*backend=real controller$' "$BOOT_LOG" ||
   ! grep -qE '^CYCLES ASSERTED' "$BOOT_LOG" ||
   ! grep -qE '^TB_PC9821_BOOT: PASS' "$BOOT_LOG"; then
  echo "run_boot_real.sh: the real-controller boot did not complete with its CYCLES line" >&2
  exit 1
fi

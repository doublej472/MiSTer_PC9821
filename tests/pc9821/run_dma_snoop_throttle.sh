#!/usr/bin/env bash
# The DMA-snoop throttle tier: DMA writes the backend accepts in a gated (cpu_ce=0) CPU run
# still invalidate every line they land in - one FDC byte held for the CPU's next enabled
# edge, then two back-to-back software-request bytes accepted inside ONE disabled
# run (the hold is one deep, so the platform back-pressures the DMAC's writes
# until the CPU has taken the held snoop).
#
#   bash tests/pc9821/run_dma_snoop_throttle.sh                 build and run (TB_PC9821_DMA_SNOOP_THROTTLE: PASS)
#   bash tests/pc9821/run_dma_snoop_throttle.sh --compile-only  elaborate the tier only, no run
#
# Like the boot/throttle tiers it is outside `tools/bench.py --all` (it builds the real
# z486), so run_integrated_build.sh compiles it to catch a hierarchy rename.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
BUILD=tests/pc9821/build
OBJ=$BUILD/obj_dma_snoop_throttle
mkdir -p "$BUILD"
COMPILE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --compile-only) COMPILE_ONLY=1 ;;
    *) echo "$0: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

./firmware/diagnostic/build.py --itf-src tests/pc9821/dma_snoop_guest.s \
  --out "$BUILD/dma_snoop_pack.bin" --mem "$BUILD/dma_snoop_pack.mem"
for hex in ucode.hex pla_entry_rom.hex pla_group_entry.hex; do
  ln -sfn "$ROOT/src/z486/$hex" "$BUILD/$hex"
done

source tests/pc9821/z486_rtl.sh
RTL=("${PC9821_Z486_RTL[@]}" tests/pc9821/tb_pc9821_dma_snoop_throttle.sv \
     tests/pc9821/sdram_backend_model.sv)

# Bounded on purpose, not -j 0: the same variable and default as run_boot.sh.
verilator --binary --timing -j "${VERILATOR_JOBS:-8}" -O2 -Wall -Wno-fatal \
  -Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -Wno-SYNCASYNCNET \
  -I"$Z" -I"$X" --top-module tb_pc9821_dma_snoop_throttle --Mdir "$OBJ" "${RTL[@]}"

if [[ $COMPILE_ONLY == 1 ]]; then
  echo "DMA_SNOOP_THROTTLE: COMPILE OK  (elaborated, not run)"
  exit 0
fi
LOG="$BUILD/dma_snoop_throttle.log"
(cd "$BUILD" && timeout "${BENCH_TIMEOUT_INT:-1800}" ./obj_dma_snoop_throttle/Vtb_pc9821_dma_snoop_throttle) | tee "$LOG"
grep -qx 'TB_PC9821_DMA_SNOOP_THROTTLE: PASS' "$LOG"

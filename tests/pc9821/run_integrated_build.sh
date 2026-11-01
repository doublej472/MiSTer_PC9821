#!/usr/bin/env bash
# Compile the four INTEGRATED tiers (boot, portharness, userdisk, throttle) and stop. No simulation, no disk, no pack.
#
# WHY THIS EXISTS. `boot`, `portharness` and `userdisk` are declared to
# tools/check_tests.py but are deliberately NOT in `tools/bench.py --all`: they are slow
# and the disk tier needs a user-supplied disk image. So they are the only testbenches in
# `tests/pc9821/` that no gate builds - and that is not a hypothetical: `userdisk` did not
# compile for days after a hierarchy rename (`dut.memory.gvram` -> `u_gvram_arb`,
# `grcg` -> `u_grcg`, `gdc_text` -> `u_cg`, `dut.block_io` -> `block_share.a_req_done`)
# while 221 benches stayed green, which is why the EMM386 boot freeze stayed
# un-reproducible. AGENTS.md carries the rule; this is the command that runs it.
#
# It is compile-only on purpose: a Verilator build is the half that catches a rename, it
# needs no runtime input at all (the pack and the disk image are $readmemh inputs), and a
# RUN of the four tiers is minutes of simulation that the other gates already spend
# deliberately. The tiers share the runners' own build directories, so a second run is
# nearly free.
#
#   bash tests/pc9821/run_integrated_build.sh
#
# Exit: 0 every tier elaborated; 1 a tier did not (its log tail is printed); 2 a runner is
# missing. VERILATOR_JOBS is forwarded to each runner (the runners' own default is 8).
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD

FAILED=()
echo "==> compile-only: the integrated tiers, which tools/bench.py --all cannot build"

build_tier() {
  local name=$1 runner=$2 log start
  log=$(mktemp)
  start=$SECONDS
  if bash "tests/pc9821/$runner" --compile-only >"$log" 2>&1; then
    printf '%-13s %s (%ss)\n' "$name" "COMPILE OK" "$((SECONDS - start))"
  else
    printf '%-13s %s (%ss)\n' "$name" "COMPILE FAILED" "$((SECONDS - start))"
    tail -40 "$log" | sed 's/^/    /'
    FAILED+=("$name")
  fi
  rm -f "$log"
}

for pair in "boot run_boot.sh" "portharness run_portharness.sh" "userdisk run_userdisk.sh" \
            "throttle run_throttle.sh" "dma_snoop_throttle run_dma_snoop_throttle.sh"; do
  # shellcheck disable=SC2086 # the pair is the point: a tier name and its runner
  set -- $pair
  if [[ ! -f "tests/pc9821/$2" ]]; then
    echo "no such runner: tests/pc9821/$2" >&2
    exit 2
  fi
  build_tier "$1" "$2"
done

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "INTEGRATED BUILD: FAIL (${#FAILED[@]} of 5 tiers did not elaborate: ${FAILED[*]})"
  exit 1
fi
echo "INTEGRATED BUILD: PASS (5 of 5 tiers elaborated: boot, portharness, userdisk, throttle, dma_snoop_throttle)"

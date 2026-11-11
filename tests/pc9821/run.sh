#!/usr/bin/env bash
# The unit tier: every Verilator bench, the diagnostic boot and z486's own suite.
#
# This path is kept so `tests/pc9821/run.sh` is one command for the tiers that
# need no inputs of their own:
#
#   tools/bench.py --all              every Verilator unit bench (223 in the manifest)
#   tests/pc9821/run_boot.sh          the diagnostic-pack boot tier
#   tests/pc9821/run_z486_suite.sh    z486's own protected-mode suite
#
# The three INTEGRATED tiers (boot, portharness, userdisk) are deliberately not in the
# battery, so nothing here builds them: use
# `bash tests/pc9821/run_integrated_build.sh` after a rename (it compiles all three and
# says so per tier), and tests/pc9821/run_*.sh --compile-only for one of them.
#
# The integrated disk acceptance needs a firmware pack and a disk image, so it is
# not part of this tier; run tests/pc9821/run_userdisk.sh directly (docs/testing.md has
# the command).
set -euo pipefail
cd "$(dirname "$0")/../.."

python3 tools/bench.py --all
bash tests/pc9821/run_boot.sh
bash tests/pc9821/run_z486_suite.sh

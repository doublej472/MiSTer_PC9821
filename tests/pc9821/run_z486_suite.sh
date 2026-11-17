#!/usr/bin/env bash
# z486's OWN Verilator suite (src/z486/tests), run against the vendored CPU: a plain copy of the
# z486 fork (AGENTS.md, "The CPU: fork first").
#
# The rest of this gate measures the CPU through the PC-98 fabric: one end-to-end verdict per
# bench, far from the instruction that produced it. This tier reports a CPU regression by a test
# that names the instruction. Per-program rationale lives with each program in the fork
# (src/z486/tests/programs/); REQUIRED below only lists the fail-first programs a re-vendor must
# not drop.
#
# Fails on any of: a test that fails (the runner exits non-zero), a run that does not end at
# 100%, a run whose total is below MIN_TESTS (so a runner that silently ran nothing cannot pass),
# a REQUIRED program that did not run and pass, or any pass that was a SKIP.
#
# The runner is hermetic: it reads SIM_PLUSARGS (a cache-off or throttle plusarg there turns the
# fast-path and clock-count programs into SKIPs, which it counts as passes), Z486_TESTBENCH (a
# different binary from the one built below) and Z486_ENABLE_X87 / Z486_PC98_MAP / Z486_BIGMEM
# (other test selections) from the environment, so all five are cleared for this run, and it
# runs with --strict, as the fork's release gate does (an expect_fail program is not a pass).
#
# Requires nasm, the suite's own declared assembler: a missing toolchain is an error, not a skip,
# because a tier that did not run must not read as a tier that passed.
set -euo pipefail
cd "$(dirname "$0")/../.."

SUITE=src/z486/tests
LOG=${Z486_SUITE_LOG:-.build/z486-suite/protected_mode.log}
mkdir -p "$(dirname "$LOG")"
# A floor, not the exact count: the suite grows upstream, and demanding equality
# would turn an upstream test addition into a gate failure, while dropping to 1/1
# (one test still passing after the rest stopped being discovered) must fail.
MIN_TESTS=${Z486_SUITE_MIN:-309}

command -v nasm >/dev/null || {
  echo "nasm is not installed: z486's suite assembles its own test programs" >&2
  exit 1
}

# src/z486 is a plain copy of the fork and every program is fork-tracked under
# src/z486/tests/programs/, so nothing is installed: the runner discovers them itself.

make -C "$SUITE" obj_dir/Vtb_protected_mode

# The runner's exit status carries the verdict, and `set -e` would end the script
# on it before the checks below can say which test failed, so collect it first.
set +e
( cd "$SUITE" && env -u SIM_PLUSARGS -u Z486_TESTBENCH -u Z486_ENABLE_X87 -u Z486_PC98_MAP \
    -u Z486_BIGMEM ./test_protected_mode.py --strict ) 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e

# The runner colors its verdict lines; strip the escapes so the checks read text.
PLAIN=$LOG.plain
sed -e 's/\x1b\[[0-9;]*m//g' "$LOG" > "$PLAIN"

[ "$rc" -eq 0 ] || {
  echo "FAIL: z486's protected-mode suite exited $rc; the failing test is in $PLAIN" >&2
  exit 1
}

# The named programs: fail-first regressions and probes each re-vendor brought in, all
# fork-tracked under src/z486/tests/programs/ (git add -f). A 100% summary without one of them
# means a re-vendor dropped it, the missing-file failure mode this tier exists for. The PASS
# banner below is printed from this same list, so it names only programs this script checked.
REQUIRED=(
  # the named regressions
  seg_limit_dcache_miss sreg_absent_gdt_load gp_double_fault_deliver div_cyrix_probe
  spec_fetch_cpl_leak wb_order_same_dst
  # the real-mode PC-98 diagnostics
  seg_verdict_real ed_stack_real mcb_walk_real
  # the Zet98-cross-referenced CPU tests
  div_edges divtest_ref cs_indirect_call flags_restore
  # c244785: the two fail-first seg programs
  seg_limit_older_commit seg_limit_stall_d2
  # bdca3b9: eight regression programs
  aaa_halfcarry aas_halfborrow bittst_after_wide_shift ed_seg_limit_check
  enter_check_cross_pf neg_size_carry rcl_count shld_overflow
  # e5120a2: seven programs
  partial_reg flag_sequences far_jump_pm far_jump_real smc_basic smc_same_line
  smc_store_patch_stress
  # 4c8ebc3: five programs
  seg_limit_edge seg_stack_wrap_rm store_fwd_word store_fwd_word_rm
  # the long-REP watchdog regressions
  rep_stosd_4k rep_stosd_16k rep_stosd_64k
  # 186a30c: eight round-2 programs
  xadd_cmpxchg min_cmp min_xadd jcc_then_fault of_stack_vs_ds pe_cpl0 pe_cs_visible
  shl1_overflow
  # 3cdb73c: six round-3 programs
  merge_collision probe_arpl probe_bcd probe_bsf_bsr probe_invd probe_xchg
  # named in the PASS banner before this list existed but never checked
  cpl3_retry cpl3_call_retry cpl3_enter_retry cpl3_push_retry cpl3_pushw_retry
  expand_down_b_bit expand_down_stack paging_grace pf_store_held pf_store_jcc
  shifter_stack_flags unreal_cs_cpl v86_user_page
)
# A SKIP counts toward the runner's pass total, so a 100% summary can hide programs that never
# ran; the runner says so on a line of its own.
if grep -qE "^[0-9]+ of the [0-9]+ passes were skipped, not run$" "$PLAIN"; then
  echo "FAIL: $(grep -E 'passes were skipped, not run$' "$PLAIN"); see $PLAIN" >&2
  exit 1
fi
for name in "${REQUIRED[@]}"; do
  # the name ends at whitespace, so store_fwd_word is not satisfied by store_fwd_word_rm
  grep -qE "^PASS +${name}([[:space:]]|$)" "$PLAIN" || {
    echo "FAIL: the suite did not run and pass $name" >&2
    exit 1
  }
done
summary=$(sed -n 's/^Summary: \([0-9]*\)\/\([0-9]*\) tests passed (\(100\.0%\))$/\1 \2/p' "$PLAIN")
[ -n "$summary" ] || {
  echo "FAIL: the suite did not report 100.0% (see $PLAIN)" >&2
  exit 1
}
read -r passed total <<<"$summary"
[ "$total" -ge "$MIN_TESTS" ] || {
  echo "FAIL: the suite ran only $total test(s) (< $MIN_TESTS)" >&2
  exit 1
}

named=$(IFS=,; echo "${REQUIRED[*]}")
echo "Z486 PROTECTED-MODE SUITE: PASS ($passed/$total, incl. ${named//,/, })"

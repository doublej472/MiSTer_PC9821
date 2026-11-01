#!/usr/bin/env bash
# z486's OWN Verilator suite, run against the PATCHED submodule.
#
# The rest of this gate measures the CPU through the PC-98 fabric: one end-to-end
# verdict per bench, hundreds of thousands of cycles away from the instruction that
# produced it. z486 ships the CPU's own contract tests, and the fork's PC-98 changes
# (docs/z486-local-patch.md) alter CPU behaviour, so a regression in them has to be
# reported by a test that names the instruction. That is
# this tier. It is Verilator-only, like the rest of the gate.
#
# The regression tests for the fourth, fifth and sixth changes are
# `seg_limit_dcache_miss`, `sreg_absent_gdt_load` and `gp_double_fault_deliver`,
# the seventh change's is `div_cyrix_probe`, and the eighth change's (upstream
# PR #2) is `spec_fetch_cpl_leak`. All are fork-tracked under src/z486/tests/programs/.
#
# `sreg_absent_gdt_load` is the fifth change's regression test: a segment-register
# load whose GDT descriptor is absent (all zeros) with an all-zero IDT must escalate
# to the triple fault, not livelock.
#
# `gp_double_fault_deliver` is the sixth change's: an absent #GP gate (vector 13)
# with a USABLE #DF gate (vector 8) must deliver #DF through gate 8, the way a real
# 486 does, rather than escalating to a processor reset.
#
# `div_cyrix_probe` is the seventh change's (upstream PR #1): real Intel/AMD 486
# silicon perturbs SF/ZF/PF/AF as an undocumented side effect of unsigned DIV and
# Cyrix leaves them unchanged, so pre-CPUID detection software uses that to
# discriminate. It is carried verbatim from the PR.
#
# `spec_fetch_cpl_leak` is the eighth change's (upstream PR #2): z486's
# branch-target line buffer survived a front-end flush keyed only on its linear
# address, so a line buffered at CPL 0 could be re-owned by a ring-3 branch to
# the same address and execute supervisor-only code at ring 3. The test drives a
# ring-0 buffer fill, an outer-level IRET to ring 3, and a ring-3 branch to the
# buffered line: pre-fix ring 3 runs the trap and reports failure, post-fix the
# fetch faults with a user-protection #PF.
#
# `wb_order_same_dst` is NOT a local-patch test: it is the regression test for a
# REPORTED (and here refuted) upstream write-ordering bug -- two back-to-back
# memory-writing instructions naming the same register (`mov eax,[mem]` then
# `add eax,[mem]`, the Doom 1 1992-compiler pattern), which an outside developer
# suspected of landing in the same cycle with the OLDER write winning. It runs 27
# slots (both first-operand encodings, 8/16/32-bit, add/or/sub, base-register and
# ES-override EAs, cold-cache second operands, plus the different-destination and
# separated controls), twice (cold and warm), against a hand-computed table.
# Keep it in this tier: it is the cheapest workload that
# reaches the deferred-load / registered-writeback interlock from a real program.
#
# Fails on any of: a test that fails (the runner exits non-zero), a run that does
# not end at 100%, or a run whose total is implausibly small -- so a runner that
# silently ran nothing (a missing .json, a stale binary) cannot pass.
#
# MIN_TESTS below is the program count measured at the re-vendor that last raised it. The
# named programs grepped after the run are fail-first regressions: a 100% summary without one
# of them means a re-vendor dropped it.
#
# Requires nasm: it is the suite's own declared assembler dependency (the runners
# assemble each program before simulating it), and a missing toolchain is a loud
# error here rather than a skip, because a tier that did not run must not read as a
# tier that passed.
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
( cd "$SUITE" && ./test_protected_mode.py ) 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e

# The runner colors its verdict lines; strip the escapes so the checks read text.
PLAIN=$LOG.plain
sed -e 's/\x1b\[[0-9;]*m//g' "$LOG" > "$PLAIN"

[ "$rc" -eq 0 ] || {
  echo "FAIL: z486's protected-mode suite exited $rc; the failing test is in $PLAIN" >&2
  exit 1
}

# The named regression test first: a summary of 100% that does not include it means
# the test file went missing, which is the failure mode this tier exists for.
grep -qE '^PASS +seg_limit_dcache_miss' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass seg_limit_dcache_miss" >&2
  exit 1
}
grep -qE '^PASS +sreg_absent_gdt_load' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass sreg_absent_gdt_load" >&2
  exit 1
}
grep -qE '^PASS +gp_double_fault_deliver' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass gp_double_fault_deliver" >&2
  exit 1
}
grep -qE '^PASS +div_cyrix_probe' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass div_cyrix_probe" >&2
  exit 1
}
grep -qE '^PASS +spec_fetch_cpl_leak' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass spec_fetch_cpl_leak" >&2
  exit 1
}
grep -qE '^PASS +wb_order_same_dst' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass wb_order_same_dst" >&2
  exit 1
}
# The real-mode PC-98 diagnostics: a 100% summary without one of them means a
# re-vendor dropped it, this tier's missing-file failure mode.
grep -qE '^PASS +seg_verdict_real' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass seg_verdict_real" >&2
  exit 1
}
grep -qE '^PASS +ed_stack_real' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass ed_stack_real" >&2
  exit 1
}
grep -qE '^PASS +mcb_walk_real' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass mcb_walk_real" >&2
  exit 1
}
# The Zet98-cross-referenced CPU tests: a 100% summary without one of them means a
# re-vendor dropped it, this tier's missing-file failure mode.
grep -qE '^PASS +div_edges' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass div_edges" >&2
  exit 1
}
grep -qE '^PASS +divtest_ref' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass divtest_ref" >&2
  exit 1
}
grep -qE '^PASS +cs_indirect_call' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass cs_indirect_call" >&2
  exit 1
}
grep -qE '^PASS +flags_restore' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass flags_restore" >&2
  exit 1
}
# The c244785 re-vendor's two fail-first seg programs are fork-tracked under
# src/z486/tests/programs/ (git add -f): a 100% summary without them means the
# re-vendor dropped them, which is this tier's missing-file failure mode again.
grep -qE '^PASS +seg_limit_older_commit' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass seg_limit_older_commit" >&2
  exit 1
}
grep -qE '^PASS +seg_limit_stall_d2' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass seg_limit_stall_d2" >&2
  exit 1
}
# The bdca3b9 re-vendor's eight regression programs are fork-tracked under
# src/z486/tests/programs/ (git add -f): a 100% summary without one of them means
# the re-vendor dropped it, which is this tier's missing-file failure mode again.
grep -qE '^PASS +aaa_halfcarry' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass aaa_halfcarry" >&2
  exit 1
}
grep -qE '^PASS +aas_halfborrow' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass aas_halfborrow" >&2
  exit 1
}
grep -qE '^PASS +bittst_after_wide_shift' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass bittst_after_wide_shift" >&2
  exit 1
}
grep -qE '^PASS +ed_seg_limit_check' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass ed_seg_limit_check" >&2
  exit 1
}
grep -qE '^PASS +enter_check_cross_pf' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass enter_check_cross_pf" >&2
  exit 1
}
grep -qE '^PASS +neg_size_carry' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass neg_size_carry" >&2
  exit 1
}
grep -qE '^PASS +rcl_count' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass rcl_count" >&2
  exit 1
}
grep -qE '^PASS +shld_overflow' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass shld_overflow" >&2
  exit 1
}
# The e5120a2 re-vendor's seven new programs are fork-tracked under
# src/z486/tests/programs/ (git add -f): a 100% summary without one of them means
# the re-vendor dropped it, which is this tier's missing-file failure mode again.
grep -qE '^PASS +partial_reg' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass partial_reg" >&2
  exit 1
}
grep -qE '^PASS +flag_sequences' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass flag_sequences" >&2
  exit 1
}
grep -qE '^PASS +far_jump_pm' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass far_jump_pm" >&2
  exit 1
}
grep -qE '^PASS +far_jump_real' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass far_jump_real" >&2
  exit 1
}
grep -qE '^PASS +smc_basic' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass smc_basic" >&2
  exit 1
}
grep -qE '^PASS +smc_same_line' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass smc_same_line" >&2
  exit 1
}
grep -qE '^PASS +smc_store_patch_stress' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass smc_store_patch_stress" >&2
  exit 1
}
# The 4c8ebc3 re-vendor's five new programs are fork-tracked under
# src/z486/tests/programs/ (git add -f): a 100% summary without one of them means
# the re-vendor dropped it, which is this tier's missing-file failure mode again.
grep -qE '^PASS +seg_limit_edge' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass seg_limit_edge" >&2
  exit 1
}
grep -qE '^PASS +seg_stack_wrap_rm' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass seg_stack_wrap_rm" >&2
  exit 1
}
grep -qE '^PASS +store_fwd_word ' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass store_fwd_word" >&2
  exit 1
}
grep -qE '^PASS +store_fwd_word_rm' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass store_fwd_word_rm" >&2
  exit 1
}
# The long-REP watchdog regressions: named, so a summary of 100% that no longer
# contains them (a lost install line, a deleted source) cannot read as a pass.
grep -qE '^PASS +rep_stosd_4k' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass rep_stosd_4k" >&2
  exit 1
}
grep -qE '^PASS +rep_stosd_16k' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass rep_stosd_16k" >&2
  exit 1
}
grep -qE '^PASS +rep_stosd_64k' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass rep_stosd_64k" >&2
  exit 1
}
# The 186a30c re-vendor's eight round-2 programs are fork-tracked under
# src/z486/tests/programs/ (git add -f): a 100% summary without one of them means
# the re-vendor dropped it, which is this tier's missing-file failure mode again.
grep -qE '^PASS +xadd_cmpxchg' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass xadd_cmpxchg" >&2
  exit 1
}
grep -qE '^PASS +min_cmp' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass min_cmp" >&2
  exit 1
}
grep -qE '^PASS +min_xadd' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass min_xadd" >&2
  exit 1
}
grep -qE '^PASS +jcc_then_fault' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass jcc_then_fault" >&2
  exit 1
}
grep -qE '^PASS +of_stack_vs_ds' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass of_stack_vs_ds" >&2
  exit 1
}
grep -qE '^PASS +pe_cpl0' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass pe_cpl0" >&2
  exit 1
}
grep -qE '^PASS +pe_cs_visible' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass pe_cs_visible" >&2
  exit 1
}
grep -qE '^PASS +shl1_overflow' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass shl1_overflow" >&2
  exit 1
}
# The 3cdb73c re-vendor's six round-3 programs are fork-tracked under
# src/z486/tests/programs/ (git add -f): a 100% summary without one of them means
# the re-vendor dropped it, which is this tier's missing-file failure mode again.
grep -qE '^PASS +merge_collision' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass merge_collision" >&2
  exit 1
}
grep -qE '^PASS +probe_arpl' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass probe_arpl" >&2
  exit 1
}
grep -qE '^PASS +probe_bcd' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass probe_bcd" >&2
  exit 1
}
grep -qE '^PASS +probe_bsf_bsr' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass probe_bsf_bsr" >&2
  exit 1
}
grep -qE '^PASS +probe_invd' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass probe_invd" >&2
  exit 1
}
grep -qE '^PASS +probe_xchg' "$PLAIN" || {
  echo "FAIL: the suite did not run and pass probe_xchg" >&2
  exit 1
}
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

echo "Z486 PROTECTED-MODE SUITE: PASS ($passed/$total, incl. seg_limit_dcache_miss, sreg_absent_gdt_load, gp_double_fault_deliver, div_cyrix_probe, spec_fetch_cpl_leak, wb_order_same_dst, seg_limit_older_commit, seg_limit_stall_d2, aaa_halfcarry, aas_halfborrow, bittst_after_wide_shift, ed_seg_limit_check, enter_check_cross_pf, neg_size_carry, rcl_count, shld_overflow, partial_reg, flag_sequences, far_jump_pm, far_jump_real, smc_basic, smc_same_line, smc_store_patch_stress, seg_verdict_real, ed_stack_real, mcb_walk_real, seg_limit_edge, seg_stack_wrap_rm, store_fwd_word, store_fwd_word_rm, div_edges, divtest_ref, cs_indirect_call, flags_restore, rep_stosd_4k, rep_stosd_16k, rep_stosd_64k, xadd_cmpxchg, min_cmp, min_xadd, jcc_then_fault, of_stack_vs_ds, pe_cpl0, pe_cs_visible, shl1_overflow, merge_collision, probe_arpl, probe_bcd, probe_bsf_bsr, probe_invd, probe_xchg, cpl3_retry, cpl3_call_retry, cpl3_enter_retry, cpl3_push_retry, cpl3_pushw_retry, expand_down_b_bit, expand_down_stack, paging_grace, pf_store_held, pf_store_jcc, shifter_stack_flags, unreal_cs_cpl, v86_user_page)"

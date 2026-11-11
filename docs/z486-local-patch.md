# z486: the vendored CPU and its diff map

`src/z486/` is a **plain copy** of a curated fork of
[nand2mario/z486](https://github.com/nand2mario/z486): a linear series of single-purpose
`fix(...)` / `pc98(...)` / `tests:` / `docs:` / `chore:` commits on upstream, each with its
reason. The fork's `docs/fork-rebase-policy.md` (inside `src/z486/docs/`) records how the
series is kept: a correction is folded into the commit it corrects, and a fork fix is dropped
when upstream's own implementation passes its fail-first test.

**Vendored commit:** the fork's `d5cf5bd` (branch `xe10-reset-dtr`: the IDTR/GDTR reset limit FFFFh, one commit on `bbe0e95`), which carries its `main` at `bbe0e95` (one testbench-only commit on `8b8fceb`,
the CPU fixes on `d5d0974`, and the performance series on `6833250`), a plain copy. The tree carries no local patch: the diff map below is the explicit `(none)` row.
What each fork commit changes, and why, is in the fork's own log.

What the fork carries, in outline:

- **PC-98 memory-map template** (`z486_cache_map_pkg`): the compile-time classes of the PC-98
  windows (device apertures uncached and ordered, RAM cacheable), with stores to the template's
  RAM pages posted through the direct store port (`TEMPLATE_STORE_POST`) and device-window stores
  kept on the ordered demand path, so no device sees a merged or reordered store.
- **Correctness fixes** with fail-first programs under `src/z486/tests/programs/`, for example a
  faulting LFS/LGS keeping the old FS/GS selector (`seg_load_np_keeps_segreg`), and the 486 AC
  flag kept across protected-mode interrupt entry while real-mode delivery clears it
  (`ac_int_keep`, `ac_int_real`).
- **Per-instruction outlier cuts** (todo item 160), each with a fail-first timing program: a
  direct load crossing a dword inside one line reads both dwords on the probe pipeline
  (`misaligned_load_inline`), CLI/STI and a LOOP that falls through skip the 386's refetch
  (`cli_sti_loop_timing`, with `sti_cli_boundary` pinning the interrupt boundary), and the
  real-mode far-transfer tail drops its CS-limit restore (`real_far_tail`).
- **Zero-cycle timing and area cuts**, each proven value-identical by a yosys SAT file under
  `src/z486/tests/equiv/` and cycle-identical over the fork's test programs.

## CPU behaviour taken from the real machine

The Xe10's CPU (reset signature `0x0432`, no CPUID; an Am486-class part) ran the z486 test
programs as CPUSUITE (`docs/probes/CPUSUITE-XE10-run1.TXT` .. `run5.TXT`) and then a triage pack
of variants of the failing ones (`docs/probes/CPUSUITE-XE10-triage.TXT`, program sources in
`tools/hwprobe/cpusuite/triage/`). The behaviours below were adopted in the fork (at `9a40dcd`,
the r16/r32 IDIV at `dcd6caa`, the last five at `140ceb5`..`8b8fceb`), each with a fail-first
program; the last five only because an independent source corroborates the capture:

- **IDIV r8, r16 and r32 complete the overflows the 486 divider misses.** A negative-quotient
  IDIV whose quotient is just out of range (signs differ, |dividend| = 2^(2n-2) +
  2^(n-1)*|divisor| + r, 0 <= r < |divisor|, n = 8/16/32) completes with quotient 2^(n-1) (80h,
  8000h, 80000000h) instead of #DE: the non-restoring divider of US 5,689,721 infers the
  partial-remainder sign from the carry and loses the overflow. Xe10, r8: `idiv_quotient_bounds`
  741Eh / 98h ran without #DE (`data=00001E07`, run3) and `div_edges` case 231 (7F81h / 81h,
  `data=000000E7`, run2); nine SingleStepTests 80386 IDIV r8 captures give the same values.
  r16/r32: `tri_idiv1632` (`data=01E201E2 eax=F00300FF`, triage: r16 7FFF8001h / 8001h and
  BFCBFFE2h / 68h, r32 7FFFFFFF80000001h / 80000001h and BFFFFFCBFFFFFFE2h / 68h complete with
  the predicted quotient and remainder; the two band edges beyond still raise #DE), and
  `tri_div_edges` fails exactly the cases 231, 569 and 927 (r8, r16, r32) of the old expectations
  (`data=000300E7`, the count and the first case).
- **A debug exception pushes RF=0.** Every #DB, the instruction breakpoint and DR7.GD included,
  pushes EFLAGS.RF as found; a handler that resumes at a breakpoint sets RF in its frame. Xe10:
  `fault_rf_gd` `data=F0000002` (run2: site 1's RF wrong, vector, error code and EIP right) and the
  breakpoint programs resetting (run1) because their handlers relied on a pushed RF=1; `tri_db_rf`
  (triage) pushes EFLAGS 00000046h from the instruction breakpoint.
- **#SS(new SS) on any privilege switch's new-stack overflow.** An INT n or exception whose
  inner stack cannot hold the frame raises #SS with the new SS selector (RPL cleared) plus EXT,
  as a CALL gate already did. Xe10: `int_newstack_ss` `data=55000038` (run3, INT n: 38h) and
  `exc_newstack_ss` `data=55000039` (run2, an exception: 39h with EXT).
- **DR6 bit 12 keeps a written one.** Intel SDM vol. 3, Architecture Compatibility,
  "Differences in Debug Register DR6": "it is possible to write a 1 in this bit on the Intel486
  processor"; Bochs `cpu/crregs.cc` `MOV_DdRd` keeps it settable at CPU level 4 and below.
  Xe10: `tri_dr6dr7` `data=FFFFFFFF`. Programs: `dr_regs`, `mov_dr_cr3_preserve`.
- **A REPE/REPNE CMPS/SCAS fault on a later element pushes the flags from before the
  instruction**, ECX and the index registers committed. Intel SDM vol. 2, REP/REPE/REPZ/REPNE/
  REPNZ: "the EFLAGS value is restored to the state prior to the execution of the instruction".
  Xe10: `tri_rep_flags` `data=00440400` (slots 2, 4, 5). Program: `rep_string_fault_progress`.
  The 386EX SingleStepTests captures push the first compare's flags instead (A7.MOO[2010] and
  one AF.MOO case); the fork's runner expects the 486 result there.
- **An error code is a 2-byte write into its 4-byte stack slot.** Intel SDM vol. 3, Architecture
  Compatibility, "Error Code Pushes": "When pushed onto a 32-bit stack, the Intel486 processor
  only pushes 2 bytes and updates ESP by 4"; the slot's upper half keeps what the stack held.
  Xe10: `callgate_newstack_ss` `data=55000038`, and `ac_v86_iret` `data=00004400`, which z486 now
  reproduces (its handler compares the low word). Program: `errcode_word_push` (same privilege,
  privilege switch, task gate).
- **DR6.B0-B3 report only enabled breakpoints.** The Intel486 PRM 11.2.3 sets them for a
  disabled match, the Intel SDM's DR6 text says "may or may not", AMD APM 24593 13.1.1.3 sets a
  bit only for "an enabled breakpoint condition"; the fork follows the AMD text and the part.
  Xe10: `debug_bn_noenable`, `debug_bn_noenable_dr123` `data=00004000`. Program:
  `debug_bn_disabled_clear`; the suite's other breakpoint programs accept either value.
- **UMOV (0F 10-13) runs as MOV** (z486 already did; the opcode sweep now checks it). R.
  Collins, "Undocumented OpCodes: UMOV": "Available on all 80386/80486 processors", "If UMOV is
  executed by a user program, it will appear it is a alias for MOV". Xe10: `tri_umov` raises no
  #UD and its register form moves the byte; its memory forms' odd results are not modelled.

Four fork test programs were corrected where the part's result is permitted or the program was
wrong, without changing z486 (fork `75603b8`..`03cbac7`): the three `*_newstack_ss` programs
compare only the error code's low word (the upper half is reserved, and the part pushes it
nonzero: `callgate_newstack_ss` `data=55000038`, triage); `nw_lock` accepts the part's 11 (run4)
beside z486's 12; `cr3_walk_race_fault`'s stack lies inside its mapped page; `paging_grace`
accepts the part's line-granular grace (16 - offset bytes, `tri_pg_grace0/8/13`, triage) beside
z486's 32 - offset.

Not adopted (eight differences, each pending an Intel 486 data point and an owner decision):
todo item 168.

## The fork-first rule

CPU changes are made in the fork **first**, then re-vendored. Nothing lives only in this tree.

- `src/z486/` may change - area, timing and simplifying emulated hardware are in scope - but
  through the fork, so the next re-vendor never has to re-apply anything.
- **Emergency only:** a change that must land here before the fork is a marked
  `LOCAL PATCH (PC-9821 core)` block in the file plus a numbered entry in this document and a row
  in the diff map. It is owed to the fork, and the next re-vendor should leave the map empty
  again.
- The contract a change must keep or re-report with per-change attribution:
  `bash tests/pc9821/run_z486_suite.sh` (335/335 at this vendoring; the runner floor is 309), Dhrystone
  `242611 cy / 121837 instr / CPI 1.991` (`docs/dhrystone-numbers.md`) and the boot golden
  (`CYCLES used=930528`). A latency-visible change that costs cycles is raised in
  `docs/trade-candidates.md`.

## Re-vendoring

1. In the fork, run its release gate: `make -C tests test-release JOBS=4`.
2. Remove the tracked tree and unpack the fork commit:
   `git rm -r -q src/z486 && mkdir -p src/z486 && git -C <fork> archive <sha> | tar -x -C src/z486`.
3. `git add -f` every path the fork tracks (`git -C <fork> ls-tree -r --name-only <sha>`):
   `src/z486/.gitignore` would otherwise silently skip some tracked files.
4. Check the map against a checkout of the fork at that commit:
   `python3 tools/check_z486_patch_diff.py --upstream <fork checkout>` (or set
   `$Z486_UPSTREAM`). Without a baseline the check prints a loud SKIP (exit 2) - never a pass.
5. Run the gates in `AGENTS.md` (the z486 suite, Dhrystone, the boot golden, the bench
   battery, lint, the integrated build), update the vendored-commit line above and the map's
   heading, and report any moved number with its attribution. **Never relax the map** to make
   the checker pass.

`tools/check_z486_patch_diff.py --selftest` proves the checker can still fail (it plants an
undocumented delta and a stale row in temporary copies); it needs no external checkout.

## Local patches

None.

### Verified diff map (the fork at the vendored commit)

`tools/check_z486_patch_diff.py --upstream <fork checkout at the vendored commit>` reports
`Z486 PATCH MAP: PASS (0 documented files, 0 deliberately not carried, 0 tree-only, ...)`.

| file | entries |
|---|---|
| (none) | the tree is a plain copy of the fork: no LOCAL PATCH/ADD, nothing only in upstream, nothing only in the tree |

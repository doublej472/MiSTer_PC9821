# i486 RTL hardening status

Review baseline: `origin/main` 098ab92; fork head before this work: c7157c7.
The fork is reviewed as logical correctness/ISA/integration changes over that
baseline, not as a collection of commit messages presumed correct.

## Current assessment

The known **reproduced** defects from the review and the additional coherence
failures below are fixed, and the self-contained RTL release gate passes.
This is a good local RTL regression state, **not** a claim of complete Intel
486 conformance, FPGA timing closure, or validated NEC firmware/game boot.
No history was rebased or rewritten by this hardening pass.

## Logical changes and their proofs

| change | fail-first observation | permanent test |
| --- | --- | --- |
| End entry-CPL0 at internal COPY_STACK_DPL | outer IRET without initial far CS reload raises unexpected #GP instead of entering CPL3; failure code 21 | `pe_entry_iret` |
| Defer D$ final tag install while a snoop owns its way port | different-set fill drops way-0 clear; read returns 11223344 instead of DEADBEEF | `tb_l1_cache`, both fill widths, snoop trains and later cancellation |
| Mask VIPT hit in registered snoop clear cycle | hit remains asserted while the probe's set is being cleared | `tb_l1_cache` registered probe race |
| Event-qualify I$ snoop matches | idle clocks re-clear a newly refilled line; later read needs another external request | `tb_l1_icache` four-way residency case |
| Arbitrate D-store patch against merged invalidate input | patch becomes consumable while a queued DIRECT invalidate still owns the port | `tb_memory_order` external + DIRECT collision |
| Apply patch backpressure to idle stores too | idle write ready remains asserted while older patch is unconsumed | `tb_l1_cache`; overwrite fuse in `cache_unit` |
| Close all L1 openings at flush arm | pipelined write opening stays ready; separately removing probe masks lets a shared probe remain usable during flush | `tb_l1_cache`; read acceptance masked in both L1s |
| Make physical tag-width macro control the actual tags | with macro=32 but old literal-27 tags, 08000040 aliases 00000040 and reads 44332211 instead of 9ABCDEF0 | `test-l1-tags-wide` |
| Make reset dominate live restart captures | a one-cycle reset on an actual issued instruction leaves TMPeSP=1234 rather than zero | `test-reset-restart`: captures stay in the non-reset arm |
| Repair reset audit and initialize small omitted state | scanner truncates at endcase and reports no omission after it | 14 parser fixtures, explicit 64-item payload inventory |
| Harden release result interpretation | a PASS banner can coexist with a nonzero exit or expected failure | 4 runner fixtures; release uses `--strict` |

The cache writer/flush fixes preserve the single tag-RAM write-port structure.
The D$ stays in S_FILL during deferred tag installation, so no reader can see
old victim tags paired with newly written data. A same-set snoop or flush still
cancels that install. The default physical tag reach remains 27 bits/128 MiB;
32-bit tags are a separately tested configuration, not a default area increase.

Small reset omissions were initialized in scratch registers, width-restore
state, fault latches, restart EIP/ESP, paging request kind, and fill-kill control.
RAMs and valid-gated payloads are not blindly reset; each exception has a named
reason. The scanner audits explicit reset branches, not general four-state
reachability or reset-less pipelines.

## Added instruction/integration guards

- `xadd_cmpxchg_lanes`: AL/AH aliasing, same-register XADD, word memory forms,
  upper-lane preservation, sized arithmetic flags, LOCK memory forms.
- `xadd_cmpxchg_fault`: XADD and both CMPXCHG outcomes on a read-only page; #PF
  code/CR2/EIP, unchanged source/accumulator, restored flags and unchanged memory.
  Invalid register LOCK forms must #UD.
- `pte_cache_coherence`: PTE modification through D$, INVLPG, new-frame read/write,
  and old-frame preservation.
- `rom_pop_vipt_alu`: cold non-flat-SS ROM POP followed by warm VIPT ALU on the
  same destination; result and ESP are checked.
- `test-data-access`: unit-injected older deferred-token condition must bypass a
  nominal hit, wait behind the older demand and return the younger demand's own
  data. Removing the stale-token gate fails this test. It does **not** prove
  that the exact overlap occurs in an integrated instruction sequence.
- `test-pc98-map`: execute and modify code in the DIRECT aperture and NO_ALLOC
  window-0 overlay, plus execute the high firmware alias above the tag reach.
  Both fill widths run. Profile-specific counters prevent an ordinary-map
  simulator from passing these tests accidentally. High alias writes are
  ignored by the test ROM model; no proprietary firmware is supplied.

The missing 486 instructions XADD/CMPXCHG, INVD/WBINVD, INVLPG and BSWAP are
upstream's routines; the fork changes only INVD/WBINVD, which enter the
whole-L1 flush instead of upstream's no-op. This pass extends their proof where
specified above; it does not claim an exhaustive opcode/exception survey.

## 486SX feature level (second pass)

The target is the Intel486 SX programming model (no FPU, no CPUID). The 80386
CROM, upstream and earlier fork already supplied XADD, CMPXCHG, BSWAP, INVD/WBINVD,
INVLPG, CR0.WP, EFLAGS.AC toggling and the GD/BS/BT debug traps. The remaining
architectural gaps were implemented; every row's test fails on the tree at the
start of this pass (the baseline tree, `c7157c7` plus the first pass) and passes
now, except the two guards marked.

| feature | change | test |
| --- | --- | --- |
| DR0-DR3, DR4/DR5 | DR0-DR3 were dropped; MOV DRn,ECX/EDX/EBX also **overwrote EAX** (IRF index 0x70 aliased GPR 0). Real DR0-DR3; DR4/DR5 alias DR6/DR7; 486 fixed bits (DR6 FFFF0FF0, DR7 bit 10) | `dr_regs` |
| CR0 | ET hardwired 1, reserved bits read 0; NW=1 with CD=0 → #GP(0) through the CROM's own invalid-CR0 path; `RESET_CACHE_DISABLED` parameter for the 60000010h reset | `cr0_486` |
| privilege #GP vector | INVLPG/INVD/WBINVD/MOV CRn/DRn/TRn at CPL3 raised **#SS** whenever the last access segment was SS | `cpl3_priv_gp` |
| CR0.CD / CR0.NW / PCD | CD: no allocation, hits kept; NW: write hits stay in the L1, snoops ignored; PTE/PDE/CR3 PCD: uncached miss (single bus read) for data, unallocated fetch for code and the prefetcher's branch-target buffer; walker reads honor CR3/PDE.PCD | `cache_ctrl_486`; `tb_l1_cache`, `tb_l1_icache` |
| #AC alignment check | CR0.AM + EFLAGS.AC + CPL3; word/dword misalignment by linear address, error code 0, restartable; descriptor/TSS/LDT references exempt; limit faults win; new optimizer-owned entry at 9F6 | `align_check` |
| hardware breakpoints | execution breakpoints (fault, RF resumes once), data write and read/write breakpoints (trap; LEN masking, crossing accesses, REP iterations), B0-B3 for enabled matches only (disabled ones clear, as AMD APM 24593 13.1.1.3 and an Am486DX4), BS+Bn together | `debug_bp`, `debug_bp2`, `debug_bn_disabled_clear` |
| RF in fault frames | faults now push RF=1 (the CROM sets it but pushed the pre-instruction FLAGSB) except a debug exception (instruction breakpoint, general detect), which pushes RF=0 as a real Am486DX4 does; traps and interrupts unchanged | `fault_rf`, `fault_rf_gd` |
| task-switch debug state | L0-L3 cleared, T bit raises #DB with BT (existing CROM; guard) | `debug_task` (guard) |
| LOCK# | new `lock` output; LOCK prefix, XCHG mem, TSS busy update, INTA pair; locked reads bypass the L1 behind the store queue | `lock_rmw` (+`expect_lock`), `hlt_wakeup_intr_pm` (+`expect_inta_lock`), `tb_l1_cache` |
| test registers | TR3-TR5 no longer #UD; TR6/TR7 drive a real TLB test port (write with way select, lookup with attribute pairs, PL/REP/LRU/PCD/PWT readback); TR5 CTL=11 invalidates the L1s | `test_regs` |
| LOADALL | 0F 07 executed the 80386 LOADALL microcode (hung the CPU); now #UD | `loadall_ud` |
| conforming transfers | entry-CPL0, RPL 3/RPL 0 selectors into conforming code keep the CPL (guard; no change) | `conforming_xfer` (guard) |

Debug slow mode: while any DR7 L/G bit is set the direct load/RMW pipelines
and dead-slot issue are held off and code-breakpoint mode issues only from a
settled idle sequencer, as the 486 itself slows with breakpoints enabled.
Alignment-check mode holds off the direct pipelines the same way. Neither
mode is entered by ordinary code, and Dhrystone is unchanged.

Deliberate limits, all documented where they apply:

- TR3/TR4 and the TR5 line read/write commands are stored but do not access
  the split L1s (the 486's unified cache-test model has no single equivalent).
- NW=1 write hits update the D-cache and patch a resident I-cache line; a later
  I-cache miss reads memory, not the D-cache.
- A data breakpoint on the instruction after MOV SS, or inside INT n, is
  dropped with the suppressed trap rather than delayed.
- UMOV (0F 10-13), SALC and ICEBP behave as on a 486; CPUID, RDTSC/RDMSR/
  WRMSR, RSM, CMOV and CR4 raise #UD (486SX without CPUID).

## Sibling-bug audit (third pass)

Five audits looked for siblings of the defects fixed above: cache coherence,
fault delivery, debug/system registers, bus locking and paging, and test
coverage (mutation testing). Every confirmed defect was reproduced with a
directed program or bench case that fails before its fix and passes after it.

| defect | fix | test |
| --- | --- | --- |
| #AC on the frame pushes to a ring-0 stack from CPL3 (INT n, call gate) livelocked | SS references through the stack switch or with SS.DPL < 3 are privilege-0 references | `ac_supervisor_push`, `ac_supervisor_callgate` |
| a fault after a task switch commits pushed and restored the old task's EFLAGS (IOPL, VM) | FLAGSB loads at 788/789 always take effect | `ts_commit_fault_eflags` |
| RF=0 in the frames of faults raised during a task switch and of the GD #DB | RF also set at 893 (TSS skip) and 3A5 (GD) | `fault_rf_classes`, `ts_commit_fault_rf`, `fault_rf_gd` |
| RF not cleared after a direct-path load/RMW, leaking into the next interrupt frame | RF also clears at the next issue; the issue captures see it | `rf_clear_after_insn` |
| INVLPG was segment-checked: #SS at CPL3, #SS(0) at CPL0 beyond the limit | INVLPG is not a memory operand for the segment check | `invlpg_ss_limit_gp`, `invlpg_no_limit_cpl0` |
| a page-crossing write wrote its first half before page 2 faulted; the restarted RMW applied it twice | both pages are translated and checked before any byte is written | `split_rmw_fault`, `split_rmw_fault_lock`, `split_write_fault_np` |
| walker A/D updates were unlocked whole-entry rewrites, losing another master's write | locked re-read, re-check, then write `fresh|A|D` under LOCK# | `lock_walker_ad` (+ `_ctl`), `tb_paging_walker` |
| TR7.PWT read 0 for walked TLB entries | PTE.PWT kept for the TR7 readback | `tlb_pwt` |
| self-modifying code through RMW stores or a linear alias ran stale code from the prefetcher's branch-target buffer | every store kills the buffered line by page-offset bits | `smc_spec_buffer`, `smc_spec_buffer_rm` |
| the I-cache patch queue survived a whole-L1 flush and merged stale bytes into post-DMA fills | the queue is retired when the flush starts | `dma_flush_patchq`, `tb_cache_coherence` |
| the branch-target buffer refilled from the pre-flush I-cache during a flush drain | it stays killed for the whole flush window | `flush_async_spec` |
| a store patch held behind an invalidate let the I-cache serve the old line | a held patch blocks I-cache hits | `tb_cache_coherence` cases 2/3 |
| ARPL followed by a slow next issue froze the microcode ROM on a stale RPT word (hang at memory latency >= 10) | only an executing word may repeat | `arpl_idle_rpt`; `opcode_sweep_486` under narrow responses |
| ALU r/m,reg, FF/0 and F7/2 RMWs read memory three times when RMW_FAST was refused (device apertures) | the refused operand is read once | `rmw_reads`, `rmw_read_forms`, PC-98 `rmw_device_reads`, `lock_window` |
| LOCK-prefixed RMW_FAST forms neither locked nor read memory | no RMW_FAST for LOCK | `lock_rmw_forms`, `nw_lock` |
| LOCK# dropped between back-to-back locked instructions, and was held through fault/interrupt delivery | priority to the next locked read; delivery is not locked | `lock_b2b`, `intr_after_lock`, `lock_ud` |
| matching but unenabled data breakpoints were not reported in DR6 | breakpoint mode also runs while a data breakpoint is programmed | `debug_bn_noenable` |
| every segment load rewrote its descriptor (a read-only GDT with WP=1 shut the CPU down); TSS busy set unlocked | write only to set a clear A bit, and set B, with locked read-modify-writes | `desc_ro_gdt`, `lock_desc_abit`, `lock_tss_busy` (+ `_ctl`), `null_gdt_write` |
| a TSS below its minimum limit raised #GP(0) and left the new TSS busy | #TS(TSS selector) before the switch | `ts_short_limit` |
| faults later in a CALL through a gate reported EXT=1 | EXT has its own flag; the CALL dispatch does not set it | `far_xfer_restart` |
| a CALL gate's too-small new stack raised #SS(0) | #SS(new SS selector) (INT n keeps #SS(0)) | `callgate_newstack_ss`, `int_newstack_ss` |
| x87 build: an ESC right behind MOV CR0 setting EM/TS executed instead of raising #NM | no direct x87 path while CR0 is written | `x87_em_nm`; `opcode_sweep_486` with x87 |
| an IRETD to V86 with AC=1 onto a misaligned ESP0 raised #AC on its own frame pops and looped (introduced by the first #AC fix's V86 exclusion) | V86 stack accesses use the same SS.DPL test | `ac_v86_iret` (+ `ac_v86_stack`, `ac_v86_task`) |
| an instruction running past the CS limit (real-mode 64 KiB wrap, or any segment) executed instead of raising #GP(0) | instruction fetch is checked against the CS limit; sequential EIP is 32 bits | `cs_limit_fetch_real`; 83 SingleStepTests cases |
| LOCK on a string instruction after REP/REPNE ran as a plain REP string | LOCK sticks against a later F2/F3 and raises #UD | `lock_rep_ud`; 26 SingleStepTests cases |
| a faulting REPNE STOS lost the ECX of completed elements; a faulting REPE/REPNE CMPS/SCAS pushed the instruction-start FLAGS | ECX and the FLAGS backup advance with each committed element | `rep_string_fault_progress`; 53 SingleStepTests cases |

Mutation testing of the fix commits (72 mutants) left 28 alive at first; 17
were killed by new programs and two repaired benches (the walker bench's
locked-update check had been a no-op), 10 are equivalent or redundant (each
recorded with its reason), and one exposed the V86 #AC bug above.

Guards added by the audit (all pass): `opcode_sweep_486` (422 entries of the
0F map, LOCK forms, FPU escapes and invalid forms against the Intel486 table),
`debug_kinds` (data breakpoints on 37 access kinds), `restart_cpl3_pf` (18
#PF restart sites), `seg_fault_vectors`, `cr0_ops`, `tlb_test2`, `lock_forms`,
`pte_snoop_*` and others listed in the commits.

The walker's locked A/D update costs Dhrystone 74 cycles (five first stores to
clean pages each pay a locked PTE read); the baseline is deliberately moved to
the value in the gate table below.

Deliberate limits found by the audit:

- Same-level exception/interrupt frame pushes at CPL3 (a conforming handler,
  no stack switch) are not alignment-checked, so #AC is never raised during
  delivery (and the #AC-versus-#DF class question cannot arise).
- A CALL gate whose new stack is too small writes the part of the frame that
  fits before raising #SS(new SS selector); a 486 checks the room first. Only
  inner-stack scratch is written and the CALL restarts.
- Unenabled instruction breakpoints (RW = 00) are not reported in DR6.
- With CR0.NW=1, self-modifying code whose new bytes are still only in the
  D-cache runs the old code (split L1s; see `docs/coherency-audit.md`).

## Measured local release gate

Run from the repository root:

```
make -C tests test-release
```

The gate serializes builds because several targets share Verilator support
objects, and tests run under both response models. Latest measured results:

| check | result |
| --- | --- |
| integer/protected directed programs, whole-line responses | 247/247 PASS |
| same programs, narrow responses | 247/247 PASS |
| directed programs with x87 enabled | 255/255 PASS |
| simple instruction cases | 26/26 PASS |
| PC-98 map programs | 5/5 whole-line + 5/5 narrow PASS |
| seeded pipeline fuzz (`test-fuzz`, 12 seeds x 3 latencies) | 36/36 PASS, self-test rejects a corrupted expectation |
| unit/survey/reset benches | 13/13 PASS (incl. `test-cache-coherence`); GPR survey has no new findings |
| additional 32-bit-tag L1 benches | 2/2 PASS |
| reset-audit and runner fixtures | 14 + 4 PASS |
| pragma / consumed ROM columns / SHIFT pairing checks | PASS |
| generated microcode/recipes | up to date |
| committed PLA vs fresh generation | 1024 words match, all 4096 mode lanes verified |
| Dhrystone | PASS, **253251 cycles / 121837 instructions / CPI 2.079** (re-baselined: +74 locked walker A/D update, -6 RMW read-once) |

Expected failures cannot be used as release passes. The PLA check generates
into a temporary directory and compares the committed image; regenerating and
then comparing the new image to itself is not the release check.

## External conformance (third pass)

Run with `tests/prepare.sh` data, `--cpu 486`, on the RTL at commit 1c3f590:

| suite | result |
| --- | --- |
| SingleStepTests 80386 real mode, all 1,758,700 vectors | 1,758,700/1,758,700 after the fixes above; the remaining differences are documented 386-vs-486 rules in `test_singlestep_real.py` (EFLAGS AC and reserved bits, AC cleared by real-mode interrupts, undefined flags of a faulting AAM and of a trailing fault's frame, a RET returning to itself, the 386EX's on-chip REMAPCFG ports) |
| SingleStepTests protected mode (86Box), 6100 vectors | 6100/6100 (`--cpu 486`: RF=1 in fault frames, i486 PRM 11.3.1.1) |
| test386.asm (CPU_FAMILY=4) | complete: every self-checking POST (00h-1Ch, E0h) passes, POST 0xFF reached, and all 44,926 POST 0xEE result lines match `test386-EE-reference.txt` |

## Out-of-context timing (Cyclone V, 85 MHz)

CPU-only Quartus 17.0.2 fits (`boards/de10nano/scripts/build_cpu.tcl 0 85`,
x87 off) of the tree before this work (`cur0`) and of the 486SX tree, same
seeds. The core missed 85 MHz OOC before this work; the question here is
whether the changes made it worse.

| tree | seeds | worst setup slack (ns) | mean | setup TNS (ns) | ALMs |
| --- | --- | --- | --- | --- | --- |
| before | 1-5 | -7.82, -8.43, -8.39, -8.21, -8.28 | -8.22 | -32.7k to -37.7k | 19,066-19,141 |
| 486SX, defaults | 1-5 | -8.53, -8.47, -8.56, -8.35, -8.12 | -8.40 | -36.1k to -41.7k | 19,965-20,014 |
| 486SX, `ENABLE_HW_BREAKPOINTS=0 ENABLE_TLB_TEST=0` | 1-2 | -7.94, -7.91 | -7.92 | -35.7k to -37.3k | 19,422-19,695 |
| end of second pass (563970b), re-fit | 1-3 | -8.53, -8.47, -8.56 | -8.52 | -40.3k to -41.7k | 19,984-20,011 |
| after the third-pass audit fixes (9126bfc) | 1-3 | -8.10, -8.17, -8.40 | -8.22 | -35.0k to -37.3k | 19,670-19,716 |

- The mean worst-slack difference (0.18 ns) is inside the seed spread
  (0.6 ns within one tree). The critical paths are the same families as
  before (shifter flags → D-cache address, prefetch → `pb_b1_ok_r`); none of
  the new logic is on them. TNS rises about 12% because the breakpoint
  comparators and the TLB test port add near-critical endpoints.
- Area: +900 ALMs (+4.7%) at the defaults. Sharing the TLB walker write index
  with the TR6 write removed about 700 ALMs from an earlier version, and the
  instruction-breakpoint decision is registered off the issue cone.
- Third pass: the audit fixes did not cost slack or area. Worst slack
  moved from -8.52 to -8.22 ns (mean of three seeds; inside the seed spread),
  TNS improved by about 13% and area fell by about 300 ALMs (1.5%), mostly
  from narrowing the branch-target-buffer kill compare from 28 to 8 bits.
  The per-path breakdown of these fits was not extracted; the claim is only
  that worst slack, TNS and area did not get worse.
- Builds that need the area or slack back can set `ENABLE_HW_BREAKPOINTS=0`
  and/or `ENABLE_TLB_TEST=0`. The debug/test registers, GD/BS/BT/T-bit
  traps, cache controls, #AC and LOCK# remain. With both off (measured at
  the end of the second pass), exactly `debug_bp`, `debug_bp2` and
  `test_regs` fail; every other directed test passes.
- Performance at the end of the second pass: Dhrystone cycle count
  identical (253183). Ordinary code does not enter debug or alignment-check
  slow mode.

## What this does not establish

- The external suites are downloaded by `tests/prepare.sh`, not bundled, and
  are not part of `test-release`. Their datasets come from a real 80386
  (real mode) and the 86Box emulator (protected mode), so 486-specific
  behaviour is only checked through the runners' documented `--cpu 486`
  rules and the directed programs.
- The OOC fits above are the CPU alone with virtual pins; they are not a
  full-SoC timing closure, and the core already missed 85 MHz OOC before this
  work. No full-SoC clock-rate guarantee is being made.
- The recorded PC-98 boot-stuck trace describes a refused downstream RAM write;
  these CPU fixes are not proof that that workload is resolved. Real firmware,
  platform/SDRAM admission and game reproductions remain separate validation.
- A7's delay-slot/token collision and A8's stale-token window were never
  reached by the directed suite or the fuzzer's window monitors; they remain
  *not reproduced*, not *proven unreachable*. The A8 rule keeps its
  unit/mutation evidence. The conforming-transition DPL question is now a
  guard (`conforming_xfer`, `conforming_xfer_rpl`; the mutated value is
  unobservable on those paths).

The next evidence step is to run the external architectural datasets and the
owner's full PC-98 boot/game harness with this exact RTL set, then perform the
corresponding timing build. A green local gate must not silently rebaseline
those workload or clock contracts.

# Testing: gate rules, static checks and hand-run proofs

The gate command list is in [`AGENTS.md`](../AGENTS.md#gates-run-before-declaring-a-change-done);
this page holds the mutation rule and ledgers, what each static check proves, the proofs run by hand, and
the userdisk instrument. Hardware testing is in [`mister-testing.md`](mister-testing.md).

## Mutation testing and ledgers

**A bench must be able to FAIL.** `python3 tools/mutate_bench.py BENCH --file SRC --from OLD --to
NEW` plants a defect in a COPY of one source and requires the bench to fail through the gate's own
verdict rule (the unmutated control must pass first). Run it when you write or strengthen a bench,
with a defect in the code path its claim covers. `tests/pc9821/mutations.json` is the record of
mutants each named bench kills; `--plan tests/pc9821/mutations.json` re-runs it (slow: one build per
bench plus one per mutant), and an entry whose `from` text no longer matches is re-pointed, not
deleted. A bench `tools/bench.py` passes also prints no line opening with `FAIL` or `MISMATCH`.

`tools/check_tests.py` and `tools/check_tool_citations.py` carry visible, shrink-only ledgers: an
entry that stops being true fails the check, so a ledger can only get shorter.

## The static contract checks

The static contract checks take seconds and hold two files (or the tree and a claim) together -
the class of defect no bench sees:

```
python3 build_profile.py --check             # top level, qsf record, generated PLL and SDC agree
python3 build_profile.py --selftest          # and the guard can still fail; sdram.v's timing
                                             # table passes its elaboration checks at every MHz of
                                             # the legal clock range, and equals build_profile's
                                             # model there (Verilator --json-only; needs verilator)
python3 tools/check_wiring.py                # bench manifest/sources/ports, reset and speaker paths
python3 tools/check_egc_snapshot.py          # the EGC's narrowed accept image == the full-width
                                             # image (SAT + induction) (+ --selftest)
python3 tools/check_tests.py                 # every bench's structure and verdict (+ --selftest)
python3 tools/bench.py --selftest            # the runner's verdict rules on planted outputs
python3 tools/gen_egc_compare_vectors.py --check   # the EGC capture vectors are the generator's output
python3 tools/gen_gdc_compare_vectors.py --check   # and the GDC conformance clusters
python3 tools/gen_gdc_draw_vectors.py --check      # and the GDC figure-drawing replay rows
python3 tools/gen_keymap_table.py --check    # README's keyboard table is translate()'s, remap_slot() names
                                             # exactly the rows the two layouts differ in
python3 tools/mutate_bench.py --plan tests/pc9821/mutations.json --check-plan   # the mutation record still applies
python3 tools/check_dbglog_contract.py       # the debug-UART record table (+ --selftest)
python3 tools/check_telemetry_contract.py    # the WDG/PRF/GFX telemetry records vs their decoder
python3 tools/check_osd_contract.py          # CONF_STR vs pc9821_osd.sv vs pc9821_system.sv, and the
                                             # root menu's layout (ROOT_LAYOUT) and each Mount
                                             # entry's image formats (MOUNT_EXTS) (+ --selftest)
python3 tools/check_port_lists.py            # every instantiation against its module's ports, and every
                                             # parameter both sides declare passed in its #() (+ --selftest)
python3 tools/check_route_pairs.py           # every memory-route pair named in the checks
python3 tools/check_shared_strobes.py        # every use of a shared strobe is qualified by its select (+ --selftest)
python3 tools/check_cpu_domain.py            # every gated-CPU pulse input held, every hold back-pressured
                                             # (+ --selftest)
python3 tools/check_mister_layout.py         # setname / config path / pack name agree
python3 tools/check_dead_files.py            # every src/ file is named by a build list
python3 tools/check_iobus_hit_equiv.py      # pc9821_iobus's predecoded hit[] lines == the full port compares (yosys; --old REV)
python3 tools/check_tool_citations.py        # every cited tools/ path exists (+ --selftest)
python3 tools/check_line_citations.py        # every in-repo file:LINE citation resolves, its quote nearby (+ --selftest)
python3 tools/check_z486_patch_diff.py       # src/z486 vs the fork at the vendored commit (+ --selftest;
                                             # exit 2 = SKIP without --upstream/$Z486_UPSTREAM)
python3 tools/check_opna_vendor_diff.py    # src/opna vs the PC88_MiSTer commit LICENSE-SCOPE.md pins (+ --selftest;
                                             # exit 2 = SKIP without --upstream/$OPNA_UPSTREAM)
python3 tools/check_todo_split.py            # todo/ items, the index, and every `item NN` reference
python3 tools/pc98_hdd_convert.py --selftest # the HDD-image converter on synthetic SASI/IDE disks
python3 tools/mister/zclick.py --selftest   # the uinput mouse helper's event streams (no device)
python3 tools/mister/ztype.py --selftest    # every typed character of both layouts through Main_MiSTer's
                                             # set-2 table, translate() and the BIOS table (no device)
python3 tools/decode_cdlog.py --selftest     # the CD-log decoder: record framing and the 16-bit ms timer's unwrap
python3 tools/mister_load_loop.py --selftest # the load screen's schedule, build labels, frame header and own-shot test (no card)
python3 tools/check_win0_moved_inv.py        # iobus win0_sel_moved == (win0_sel != 8'h08) every cycle (+ --selftest)
python3 tools/check_iobus_lane_inv.py        # iobus: in S_DEVWAIT the lane is the one S_BYTE presented (+ --selftest)
python3 tools/check_arb_resp_inv.py          # the GVRAM arbiter's response-routing state invariants (+ --selftest)
python3 tools/check_gdc_egc_gate_inv.py      # the registered EGC memory gate == mode2_egc && GRCG mode[7] (+ --selftest)
python3 tools/check_storebuf_head_inv.py     # the PEGC store buffer's registered head facts == the window compares
                                             # (+ --selftest)
python3 tools/check_cpu_run_inv.py           # the loader's registered cpu_run == rom_ready && !load_error (+ --selftest)
python3 tools/check_micro_equiv.py           # each tools/equiv/*.sv rewrite == its earlier form, by SAT (+ --selftest)
python3 tools/check_fir_acc_bound.py         # the FIR accumulator (ACCW) holds every stage's worst sum (+ --selftest)
python3 tools/check_powerup_init.py          # no output-port initializer, nor `initial` block on an output port,
                                             # Quartus would ignore or fold (+ --selftest;
                                             # --map-rpt <fit>/output_files/z486_mister.map.rpt checks a fit's ties)
```

The yosys proofs above are induction from a reset over the real module text (pasted into a copy)
with every input free; each finishes in seconds under 1.1 GB, except `check_micro_equiv` (~95 s,
many small proofs). Their `--selftest` runs take up to ~3.5 min and ~3.5 GB (`check_arb_resp_inv`).
Run a SAT proof under a memory cap (`systemd-run --user --scope -p MemoryMax=8G -p MemorySwapMax=0
...`): a proof that maps a large RAM into the SAT model can take tens of GB.

## Proofs run by hand

By hand, outside the gates: `python3 tools/check_4state_xlock.py` runs the X-lock benches under
iverilog (4-state; Verilator is 2-state and cannot show an X-lock), and
`python3 tools/check_decode_equiv.py` proves a decode rewrite. A front end that moved between two
files is proved by `python3 tools/check_cpu_addr_front_equiv.py --old <rev>` (required, no
default, so the proof cannot silently become a self-comparison): it extracts the window-0 bias
arithmetic from both revisions' text and proves the exported pair equal by SAT over every 32-bit
address and both window-0 flags (`--selftest` plants four known errors). What Quartus BUILT can
differ from what Verilator simulates (a fork commit once carried a value-identical split that
Quartus 17.0 synthesized wrong: black screen on hardware, every sim green): `python3 tools/check_cls_netlist.py`
synthesizes cache_unit alone and proves its split routing class in the netlist, and
`python3 tools/vqm_equiv.py regs A.vqm B.vqm --filter <hier> --rpt <A map.rpt> [--each]` proves
two post-map netlists (`quartus_cdb <rev> --vqm=<file>` after `quartus_map`) compute the same
next state for every register - run it on a rewrite claimed value-identical before a fit.

Also by hand: the records of past cuts proven against their pre-cut revision. They need the full
history (absent from a squashed clone) and hold only until the module next changes:
`python3 tools/check_memmap_addr_equiv.py` (default `--old ac2538dc`), `python3
tools/check_seq_equiv.py` (`--selftest`, `--proof all`, `--pair`; its `--pair` record against
6b457f7f no longer matches the current GRCG/arbiter pair), and the `--history` parts of
`check_cpu_run_inv`, `check_storebuf_head_inv` and `check_gdc_egc_gate_inv` (exit 2 = SKIP when
the revision is absent; the last one's crtc/grcg records no longer match either module).

## The userdisk instrument

`tests/pc9821/run_userdisk.sh` runs the real pack and a real disk image through the whole core in
simulation - the instrument for a guest that hangs on a real disk. Run it as
`PC98_PACK=<pack.bin> USERDISK_IMG_FILE=1 TB_ARGS="+IMG_RW +PAST_IPL ..." CYCLES=<n> bash
tests/pc9821/run_userdisk.sh <image>` (the `.mem` beside the pack comes from `build_pack.py`'s
`--mem`). `+IMG_RW` makes the image writable through an in-memory overlay, `+PAST_IPL` keeps
running after the boot sector, `+KEYSEQ`/`+KEYSEQ_N`/`+KEYSEQ_AT` type scancodes, and the traps
stop at an event: `+TRAP_CSEIP=<cs:eip>`, `+TRAP_LIN=<linear>`, `+TRAP_AFTER=<cycle>`,
`+TRAP_HITS=<n>`, `+TRAP_WIDE`, `+TRAP_RAMFILE=<path>`, `+PC_SEQ_N=<n>`. It runs ~210 k cycles/s,
so edit the image's CONFIG.SYS to reach the case directly rather than simulating a menu timeout.
Trust its PC trail and RAM dump over the trap registers, which can lag by a few cycles.

## Real-controller measurements

The boot golden (`run_boot.sh`, 930533) and the CPU's Dhrystone (242611) both run a fixed-latency
memory model, so an SDRAM controller change cannot move them. Two runs put the real controller
(`split_sdram_backend` over `sdram_sync_bridge` over `src/memory/sdram.v`, ADQM=1, FAST_GRADE=0)
and `tests/pc9821/sdram_chip_model.sv`, with its protocol, -7 AC and tREFI checks, under the same
programs:

```
bash tests/pc9821/run_boot_real.sh           # the boot tier (50 MHz clk_sys): CYCLES used=942542
python3 tools/dhrystone_real.py              # Dhrystone at 90 MHz: 271807 cycles
```

Both are pinned gates (`BOOT_CYCLES_REAL_SDRAM` in `tests/pc9821/tb_pc9821_boot.sv`, `PINNED` in
`tools/dhrystone_real.py`): any other count fails, as the boot golden does, and a controller change
that moves one reports the new value with its attribution. The same-row write chain (item 143,
not in this tree) would move both. The boot tier runs the controller at 50 MHz, where tWR is one
clock and the trimmed write exit puts a store's next ACT three clocks (60 ns) after its
auto-precharged WRITE; the chip model judges that from nanoseconds (Table 16: tWR + tRP = 35 ns),
and `tb_pc9821_sdram_chain` and `tb_pc9821_sdram_strict` each carry a 50 MHz rig for it.
`run_boot_real.sh` uses its own object directory (`obj_boot_real`) but is still a heavy job: do
not overlap it with the other boot tiers.

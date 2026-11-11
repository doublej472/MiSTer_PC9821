# AGENTS.md - working in this repository

The guide for contributors and coding agents. [`README.md`](README.md) is the user's view (what
the core provides, what it needs, short recipes), with the user guides under `docs/user/`
(setup, options, images, DOS, troubleshooting and known issues, compatibility); this file is how
the tree is built, tested and changed. The explanations, measurements and tool reference behind it
live in `docs/` ([`docs/README.md`](docs/README.md) is the index; the contributor docs are below).

## What the project is

A PC-9821 (NEC Xe10/Xe) core for MiSTer, built on the vendored z486 CPU (`src/z486/`). It boots
the user's own NEC Xe10/Xe ROM dumps to DOS and runs Touhou 1-5, DOOM, Policenauts and other
PC-98 software. No firmware is redistributed: the ROMs, the YM2608 rhythm ROM and disk images
are runtime inputs the user supplies.

## Repository layout

| path | what |
|---|---|
| `z486_mister.sv` | the top level (CONF_STR/OSD, hps_io, video/audio out, debug UART) |
| `z486_mister.qsf`, `.qpf` | Quartus project; the qsf ends in a block `build_profile.py` manages |
| `build_profile.py` | applies a build configuration (preset + overrides); generates the PLL and SDC |
| `src/z486/` | the 486 CPU: a plain copy of its fork (see "The CPU: fork first") |
| `src/pc9821/` | the PC-98 core: system, I/O bus, memory map, CRTC/GDC/GRCG/EGC/PEGC, keyboard, mouse, ATA/ATAPI, FDC, DMA, PIC/PIT, calendar, audio, debug instruments |
| `src/opna/` | YM2608 sound: jt12/jt49/jt08, vendored from PC88_MiSTer (frozen, see below) |
| `src/pcm86/` | the PC-9801-86 PCM block |
| `src/memory/` | the SDRAM controller and its requester bridges |
| `src/soc/`, `src/common/` | shared glue |
| `sys/` | the Template_MiSTer framework, byte-identical to upstream (frozen) |
| `rtl/` | the active configuration's generated PLL (git-ignored; only `rtl/pll/pll_0002.qip` is tracked) |
| `tools/` | build, bench, lint, contract checks, firmware pack, MiSTer deploy/test, decoders |
| `tools/profile/` | the PLL and SDC templates the configuration is generated from |
| `tools/timing/` | the path census and `pll_hdmi` placement scripts (`QUARTUS_POST_STA_TCL`) |
| `tools/equiv/` | yosys equivalence harnesses for value-identical rewrites (`tools/check_micro_equiv.py`) |
| `tools/hwprobe/` | DOS probe programs that measure a real PC-9821 |
| `tools/mister/` | test helpers that run ON the MiSTer (uinput keyboard/mouse) and the regression scenario example; nothing user-facing is installed on the card (the image converters `tools/cue2pcd.py`, `tools/fdconv.py` and `tools/pc98_hdd_convert.py` run on a computer) |
| `tests/pc9821/` | Verilator benches, the integrated boot/userdisk/portharness tiers, the z486 suite runner |
| `firmware/` | the in-tree diagnostic test pack (no NEC code) |
| `docs/` | `README.md` (the index of everything below), the contributor docs indexed below, port status, the single-cycle event rule (and `CONTRIBUTING.md`, its entry point), timing paths, the clock-domain crossing map, trade candidates, Dhrystone numbers, the z486 vendoring map, the BIOS SETUP decode |
| `docs/user/` | the user guides README links: setup, OSD options, images, input, DOS and Windows 95, hardware, troubleshooting and known issues, the compatibility list |
| `docs/probes/` | raw captures from a real Xe10: the source of the hardware facts benches assert |
| `todo/`, `TODO.md` | the open-work list, one file per theme; `TODO.md` is the index |

The repo root holds only `README.md`, `AGENTS.md`, `TODO.md`, `LICENSE`, `NOTICE` and the build
files (`Makefile`, `build_profile.py`, the Quartus project, the top level, `backend.qip` and
`z486_mister.clk_sys_top_setup.tcl`, a minimal STA session). Build
output goes under `.build/` (Quartus, scratch) or `tests/pc9821/build/` (Verilator); both are
ignored. Put temporary files in `.build/<task>/` or an ignored `scratch/`, never in the tree.

| doc | what |
|---|---|
| [`docs/README.md`](docs/README.md) | the index of every document under `docs/`, user and contributor |
| [`docs/policies.md`](docs/policies.md) | every binding rule in full, the performance/latency/area policy, documentation and wording, fixed design decisions |
| [`docs/build.md`](docs/build.md) | the Quartus build, build profiles, SDRAM I/O registers, analog video, CD-ROM, the generated PLL and SDC |
| [`docs/fitting.md`](docs/fitting.md) | seed sweeps, remote fitting, timing and area facts, the `pll_hdmi` deploy gate and load screen |
| [`docs/sdram.md`](docs/sdram.md) | the supported SDRAM modules, their timing and the DQM-on-address wiring |
| [`docs/sdram-margin.md`](docs/sdram-margin.md) | the SDRAM I/O corner gate (`--min-sdram-io`), the run-time phase instrument (`--dbg-sdram-phase`), the shmoo and its run procedure |
| [`docs/testing.md`](docs/testing.md) | mutation testing, what each static check proves, hand-run proofs, the userdisk instrument |
| [`docs/mister-testing.md`](docs/mister-testing.md) | testing on a real MiSTer: deploying, screenshots, input, the debug UART, the regression runner, the rules |
| [`docs/lanes.md`](docs/lanes.md) | working habits for parallel lanes |
| [`docs/debug-instruments.md`](docs/debug-instruments.md) | the compile-time debug-UART instruments (`--dbg-*`) |
| [`tools/hwprobe/README.md`](tools/hwprobe/README.md) | the real-hardware probes and how to run them |

## Evidence: where expected values come from

Every behavioural claim, and every bench's expected value, comes from the strongest available
source, in this order:

1. real-hardware captures (`docs/probes/`) and logic-analyzer traces;
2. observations of the real machine;
3. NP2kai (the primary software reference);
4. qemu-pc98;
5. MAME / ymfm;
6. ReC98.

Our own RTL and benches are never evidence of what the hardware does. Die-level models, how to
cite, disagreeing references and comparing captures across machines:
[`docs/policies.md`](docs/policies.md#evidence-where-expected-values-come-from).

## The rules that bind every change

Each line is binding; the linked section carries the rule in full.
- **Fail-first benches.** Every behavioural fix ships with a bench that FAILS before the fix
  and PASSES after, with expected values from the reference, never from our RTL.
- **The Single-Cycle Event Discipline** is mandatory for every pulse, strobe and one-shot event:
  read [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) and
  [`docs/single-cycle-event-discipline.md`](docs/single-cycle-event-discipline.md) before adding
  one.
- **Rates come from the device, not from `clk_sys` counts** ([policies](docs/policies.md#the-rules-that-bind-every-change)).
- **The read-back side is the weak spot.** When touching a device register, verify what its READ
  ports return, not only what writes do.
- **One clamp at the authentic junction** in the audio sum ([policies](docs/policies.md#the-rules-that-bind-every-change)).
- **A knob that changes constants is a compile-time parameter, not a runtime mux** ([policies](docs/policies.md#the-rules-that-bind-every-change)).
- **Comments carry hardware facts**, cited; a `file:NNN` citation quotes its target ([policies](docs/policies.md#the-rules-that-bind-every-change)).
- **Latency and performance trades are raised, not decided by a contributor** ([policies](docs/policies.md#the-rules-that-bind-every-change)).
- **The boot golden is a canary, not a constant** (`CYCLES used=930528`; [policies](docs/policies.md#the-rules-that-bind-every-change)).
- **Generated files: fix the generator, then regenerate** ([policies](docs/policies.md#the-rules-that-bind-every-change)).
- **A power-up value lives on an internal register, never on an output-port initializer**
  (Quartus ignores those; [policies](docs/policies.md#the-rules-that-bind-every-change)).
- **Licence: the project's own code is Apache-2.0** (`LICENSE`); code or data taken from another
  project keeps its licence and is listed in `NOTICE` ([policies](docs/policies.md#fixed-design-decisions)).
- **Never `git add -A`.** Name the paths you mean; build trees have slipped into the index that
  way before.
- **No AI co-author attribution.** Commits carry no `Co-Authored-By:` trailer (or any other
  attribution) naming an AI model or agent; the human who commits is the author.
- **Never reduce performance to meet timing**, nor add guest-visible latency ([policies](docs/policies.md#performance-latency-and-area-policy)).
- **README is user-only; wording is neutral** ([policies](docs/policies.md#documentation-and-wording)).
- **Defaults favour running software**: an OSD default is the value that runs the most programs
  and games, not merely one machine's factory setting ([policies](docs/policies.md#fixed-design-decisions)).
- **Fixed design decisions** are not reopened by a change ([policies](docs/policies.md#fixed-design-decisions)).
- **SDRAM timings meet the slowest supported module** ([`docs/sdram.md`](docs/sdram.md)).
- **Never quote a single fit; the `pll_hdmi` floor and load screen gate a deploy** ([fitting](docs/fitting.md#timing-and-area-facts)).
- **Hardware tests run on copies and are viewed by eye** ([MiSTer rules](docs/mister-testing.md#rules-for-testing-on-a-mister)).

### Frozen and vendored trees

- `sys/` is byte-identical to Template_MiSTer (upstream commit 76dd8f5, the one NOTICE part 2
  records; a sync is a verbatim `cp -r` of upstream `sys/` and moves both records). Never edit
  it; report bugs upstream.
- `src/opna/` (jt12/jt49/jt08) is vendored from PC88_MiSTer at the commit
  `src/opna/LICENSE-SCOPE.md` pins (`tools/check_opna_vendor_diff.py --upstream <checkout>` proves the ten recorded deltas). Do not refactor it. A change is a marked, reference-backed
  `LOCAL CHANGE`/`LOCAL FIX`/`LOCAL PATCH` block added to that file's list of local changes, so a
  diff against the pinned upstream reports exactly that list.

### The CPU: fork first

`src/z486/` is a plain copy of the z486 fork (a curated series on upstream nand2mario/z486), and
its diff map in [`docs/z486-local-patch.md`](docs/z486-local-patch.md) is empty. CPU changes are
made in the fork FIRST, pass the fork's own release gate (`make -C tests test-release JOBS=4` in
the fork), and are then re-vendored here as a plain copy:

```
git rm -r -q src/z486 && rm -rf src/z486 && mkdir -p src/z486   # rm -rf: gate runs leave untracked build output there
git -C <fork> archive <sha> | tar -x -C src/z486
git add -f src/z486          # every path the fork tracks
```

then the gates below. Do not edit `src/z486/` directly, not even comments. An emergency fix that
must land here first is a marked `LOCAL PATCH (PC-9821 core)` block plus a numbered entry in the
map, and it is owed to the fork. `tools/check_z486_patch_diff.py --upstream <fork checkout at the
vendored commit>` (or `$Z486_UPSTREAM`) proves the tree matches the map; without a baseline it
prints a loud SKIP (exit 2), never a pass.

The CPU contract: `bash tests/pc9821/run_z486_suite.sh` passes every program (335/335 today; the runner fails below 309), and
`make -C src/z486/tests dhrystone JOBS=4` reads exactly `242611 cy / 121837 instr / CPI 1.991`
([`docs/dhrystone-numbers.md`](docs/dhrystone-numbers.md)). A change may move these, but must
report the new values with per-change attribution.

## Firmware pack (runtime inputs)

The core loads one 1 MiB pack built from the user's dumps by `tools/build_pack.py` (layout in
`tools/pack_layout.py`; `make pack PC98_DUMPS=<dir>`). The pack, disk images and any guest
binaries are never committed (`.gitignore` covers `pc98pack*.bin`, `*.img`, `*.EXE`).

- **The YM2608 ADPCM-A rhythm image must be in the pack** (`--rhythm FILE`, or `OPNA_ADPCM.ROM`
  beside the dumps, which `--dumps` finds). A zero-filled region is NOT silence: an all-zero
  ADPCM-A nibble steps +2 per sample, so every drum becomes a loud DC-carrying sawtooth.
  `build_pack.py` warns on an all-zero region and `tools/check_pack.py` fails a pack that lacks an
  image its dump directory holds.
- The shipped rhythm image is the genuine die ROM (YM2608-LLE's `rss_rom[]` with each byte's
  nibbles swapped); the reader takes the high nibble first.

## Building

Quartus runs in a container (`CONTAINER_RUNTIME`, default `podman`). Any RTL change needs a
Quartus compile - Verilator-clean is not Quartus-clean:

```
rm -rf .build/quartus && python3 build_profile.py base && \
  timeout 300 python3 tools/build.py --log .build/compile.log; grep -cE "^Error" .build/compile.log
```

Zero `^Error` lines means analysis, synthesis and map passed, not that the design fits: LABs bind,
and only a real fit judges area or timing. Profiles (`base` ships), full fits and the generated
PLL/SDC: [`docs/build.md`](docs/build.md). Seed sweeps (bulk fits run on a fit host through
`tools/remote_fit.py`) and the timing and area rules: [`docs/fitting.md`](docs/fitting.md).

## Gates (run before declaring a change done)

Run the heavyweight gates sequentially and bound their memory: `VERILATOR_JOBS=2 BENCH_JOBS=1`
for the battery, `JOBS=4` for the z486 Makefile (never a bare `-j`), and never overlap
`run_boot.sh` with `run_integrated_build.sh` (they share an object directory), `run_boot_real.sh`
with either, or any of them with a Quartus fit. The two real-controller lines
([`docs/testing.md`](docs/testing.md#real-controller-measurements)) are the gates an SDRAM
controller change shows in as a cycle count (the boot golden and the CPU Dhrystone cannot see one).

```
python3 tools/bench.py --all                 # the Verilator battery
python3 tools/check_lint.py
python3 tools/gen_bench_sources.py --check
bash tests/pc9821/run_z486_suite.sh          # 335/335
timeout 2400 bash tests/pc9821/run_boot.sh   # boot golden: CYCLES used=930528
bash tests/pc9821/run_integrated_build.sh    # compile-only: the boot, portharness, userdisk,
                                             # throttle and dma_snoop_throttle tops the battery
                                             # cannot build
make -C src/z486/tests dhrystone JOBS=4      # 242611 cy / 121837 instr / CPI 1.991, exact
bash tests/pc9821/run_boot_real.sh           # boot on the real SDRAM controller: CYCLES used=942534
python3 tools/dhrystone_real.py              # Dhrystone on the real SDRAM controller: 271807, exact
```

A gate PASS comes from `tools/bench.py`'s verdict - the strict `TB_<NAME>: PASS` marker alone on
a line - never from reading simulation output. A bench must `$fatal(1, ...)` on failure (a
Verilator `$finish` after a FAIL message exits zero), and must carry its manifest claim verbatim
on ONE line; `tools/check_tests.py` enforces both. The integrated tiers are outside the battery,
so after renaming or re-parenting a module, run `run_integrated_build.sh`: a green battery says
nothing about them. `tools/bench.py` takes one bench name or `--all`. A bench must be able to
FAIL: prove a new or strengthened one with `tools/mutate_bench.py`
([`docs/testing.md`](docs/testing.md#mutation-testing-and-ledgers)).

The static contract checks take seconds; run each as `python3 <check>` (what each proves, and the
SAT proofs' memory caps, are in [`docs/testing.md`](docs/testing.md#the-static-contract-checks)):
`build_profile.py --check`, `build_profile.py --selftest`, and under `tools/`: `check_wiring.py`,
`check_egc_snapshot.py`, `check_tests.py`, `bench.py --selftest`,
`gen_egc_compare_vectors.py --check`, `gen_gdc_compare_vectors.py --check`,
`gen_gdc_draw_vectors.py --check`, `gen_keymap_table.py --check`,
`mutate_bench.py --plan tests/pc9821/mutations.json --check-plan`, `check_dbglog_contract.py`,
`check_telemetry_contract.py`, `check_osd_contract.py`, `check_port_lists.py`,
`check_route_pairs.py`, `check_shared_strobes.py`, `check_cpu_domain.py`,
`check_mister_layout.py`, `check_dead_files.py`, `check_iobus_hit_equiv.py`,
`check_tool_citations.py`, `check_line_citations.py`, `check_z486_patch_diff.py`,
`check_opna_vendor_diff.py`, `check_todo_split.py`, `pc98_hdd_convert.py --selftest`,
`cue2pcd.py --selftest`, `fdconv.py --selftest`,
`mister/zclick.py --selftest`, `mister/ztype.py --selftest`, `decode_cdlog.py --selftest`,
`mister_load_loop.py --selftest`, `hwprobe/xe10t/xe10t_decode.py --selftest`,
`hwprobe/mputest/mputest_decode.py --selftest`,
`check_win0_moved_inv.py`, `check_iobus_lane_inv.py`, `check_arb_resp_inv.py`,
`check_gdc_egc_gate_inv.py`, `check_storebuf_head_inv.py`, `check_cpu_run_inv.py`,
`check_micro_equiv.py`, `check_fir_acc_bound.py`, `check_powerup_init.py`. Proofs run by hand (X-lock, decode and netlist
equivalence) and the userdisk instrument are in [`docs/testing.md`](docs/testing.md).

## Testing on a real MiSTer

A change to anything the guest can see also passes the scripted hardware regression on a real
MiSTer (`tools/mister_regress.py --go`), over ssh, with the card from `MISTER_HOST`. Deploying
(`tools/mister_load.sh`; load the MGL, not the RBF), screenshots, typing and clicking, the debug
UART, the regression runner, several cards and the rules for a shared card are in
[`docs/mister-testing.md`](docs/mister-testing.md). Real-hardware probes are built and run as
[`tools/hwprobe/README.md`](tools/hwprobe/README.md) describes: on the core first, then on the
real machine, the SAME binary on both sides, raw captures committed under `docs/probes/`.

## Working with several agents (worktrees)

Parallel work runs in git worktrees inside the repo: `tools/worktree.py new|status|diff|merge
--apply|rm`, at `.worktrees/<name>` on a `lane/<name>` branch, one writer per worktree. Such a
branch of parallel work is called a lane below. More working habits: [`docs/lanes.md`](docs/lanes.md).

- **Commit incrementally**, before slow validation, with specific paths. Pass each worker an
  explicit working directory, a deadline, and an absolute path for its report.
- Workers run focused benches (`python3 tools/bench.py <name>`, one name per call), `check_lint`
  and `gen_bench_sources --check`; the integrator runs the full battery and the Quartus fits.
  Don't merge into the main tree while a gate run is in progress: it voids the run.
- A lane that changes anything the guest can see boots the hard disk on a card before it is
  merged, and a release candidate is cut only from a merged head the full battery passed
  ([`docs/lanes.md`](docs/lanes.md)).
- Merge lanes sequentially. Conflicts cluster in `pc9821_system.sv`, `pc9821_iobus.sv`,
  `pc9821_crtc.sv`, `z486_mister.sv`, the audio chain, the `todo/` theme files and
  `tools/gen_bench_sources.py` (take the union, regenerate).
- **Bound every heavy job's memory**: run simulations, the battery, the boot golden, SAT proofs
  and Quartus maps inside `systemd-run --user --scope -p MemoryMax=<8-16>G -p MemorySwapMax=0`,
  one heavy job per lane at a time. Several lanes on one machine can otherwise exhaust its memory
  and the OOM killer takes every running session with it.
- **Keep every relevant fit's whole `output_files/`** (RBF, SOF, every report): it is the only
  record of that placement. Clean `tests/pc9821/build/` and sweep `tree/` copies freely; delete
  `output_files/` only in an occasional cleanup of fits that no longer matter
  ([fitting](docs/fitting.md#keeping-fit-results)).

## Releases

The public repository's `main` holds one squashed commit per release; the development branch and
its history are never pushed there. A release candidate passes, on its exact tree and bitstream:
the full gate; a 6-seed sweep with the chosen seed clearing the `pll_hdmi` floor and the SDRAM I/O
gate (`--min-sdram-io`, [`docs/sdram-margin.md`](docs/sdram-margin.md)); the 10-load screen and the scripted regression on every test card, its
`boot-loop` item included (`--boot-count 6` or more, the boot after the load counted) and its `speeds`
item (a boot at CPU Speed 33, 25 and 16 MHz); and a representative sample
of the game list (hard-disk, CD and floppy titles, the mouse-driven and CD-audio ones, and Windows 95)
checked by eye, with screenshots kept for every title
([`docs/mister-testing.md`](docs/mister-testing.md#game-test-sets)). Before the push: no game names in
README, no machine names or private paths anywhere, and the maintainer reviews the squashed commit.
A CPU fork commit is pushed to the fork only after a hardware run of a core that vendors it.

## The open-work list

[`TODO.md`](TODO.md) is the index; items live one file per theme under `todo/`, with the
status-tag legend in `todo/README.md`. Item numbers are stable IDs cited as `item NN` across the
tree: never renumber or reuse one. A closed item is deleted and its number retired;
`python3 tools/check_todo_split.py` holds the files, the index and every reference together.
`todo/` holds only work still to follow up or verify (a capture whose answer would change guest-
visible behaviour, a divergence, a re-check, an open owner decision): a known limitation with no
plan goes in `docs/user/troubleshooting.md`'s "Known issues", a latency/area trade in
`docs/trade-candidates.md`, a standing rule here - otherwise the list fills with finished history
and stops being a work list.

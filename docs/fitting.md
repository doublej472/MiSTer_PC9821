# Fitting: seed sweeps, timing and area

How fits are run and judged. The build itself is in [`build.md`](build.md); where the critical
paths are is in [`timing.md`](timing.md).

## Seed sweeps

**Bulk fits run on the fit host, not this machine.** A multi-seed local sweep once ran
twelve Quartus containers (~3.4 GB each) and took the host to 0 GB free; the sweeps had to be
killed. Multi-seed sweeps and A/Bs go through `FIT_HOST=<fit-host> python3 tools/remote_fit.py
run ...` (the fit host's shared slots coordinate every run), and the local machine is for the
gate and single `tools/build.py` A&S/map checks. A local sweep is only for a one-off when no
host is reachable, and then bounded by `FIT_SLOT_MAX` and watched.

`python3 tools/seed_sweep.py --profile <p> --count N --jobs N` (`--seeds 1,5-8` for specific
seeds, `--report` to rank, `--dir` for a fresh directory). Each seed's `summary.txt` (written last, atomically, after
`output_files/` and `metrics.json`) records an `identity=` hash of {resolved configuration, RTL source
hash, fit knobs such as `QUARTUS_FIT_SETTINGS`}, plus the framework clock margins
(`other_setup`/`other_tns` and `hdmi_setup`/`hdmi_tns`); `--report` ranks by `clk_sys` only
among the seeds that clear the `pll_hdmi` floor and exits nonzero when none do (see "Timing and
area facts" for the floor, the flags `--min-other-setup` / `--min-positive` / `--min-seeds`, and
the 6-seeds-per-side rule). A re-run skips only seeds whose identity matches and
REFUSES (exit 1) when it finds a seed of another source/profile, instead of mixing designs in one
ranking: `--restart-stale` renames those to `seedNNN.stale-<time>` (kept) and refits, `--retry-failed`
does the same for `verdict=failed` seeds, `--trust-existing` accepts summaries that predate
identities. `--selftest` covers the logic. `--slot-dir DIR --slot-max N` (env `FIT_SLOT_DIR` /
`FIT_SLOT_MAX`) makes each seed hold a `tools/host_slots.py` slot while it fits (`--slot-all` also
counts containers other launchers started, `--max-load L` waits on host load). `tools/build.py`
refuses to start when a live build of the same tree owns `.build/quartus`. `tools/host_slots.py` caps concurrent fits on a
shared host. Every fit runs at the lowest CPU priority with idle I/O (`tools/build.py`, `QUARTUS_NICE`,
default 19; 0 = normal), so it yields to other work on a shared machine. A sweep's `seedNNN/output_files/` is that placement's only record (the RBF and the
fit/STA reports); clean the `seedNNN/tree/` copies freely, and `output_files/` only as below.

### Keeping fit results

Delete `output_files/` only in an occasional cleanup (when disk space runs short, not routinely),
and only for fits that no longer matter. A fit still matters when it is:

- the bitstream deployed on a test card, or the one behind a public release or the current
  release baseline;
- a fit of the current code, or a comparison a still-open lane or todo item relies on (a lane's
  A/B sweeps until it merges or is dropped; the shmoo test builds while the margin work is open);
- a placement a doc or todo item cites as evidence that has not been re-measured since.

Anything fitted from code older than the last merged structural change, whose figures are already
recorded in the docs or todo items, can go. Keep a list of the directories removed.

## Fitting on another machine (`tools/remote_fit.py`)

`FIT_HOST=<ssh host> tools/remote_fit.py run --label X --slot-max N -- --profile base --seeds 2,3
--jobs 2` snapshots the working tree (tracked files as on disk, uncommitted edits included, plus
untracked non-ignored files under 1 MiB) to `<host>:~/fits/<run-id>/tree`, starts `seed_sweep.py`
there in its own session under a shared `host_slots` ceiling (`--slot-max`, default 12, with a load gate at the host's core count, `--max-load`; slots in
`~/.fit-slots`, counting every running container), waits, then rsyncs the whole `sweep/` back to
`.build/remote-fit/<run-id>/` (every `seedNNN/output_files`, `summary.txt`, `metrics.json`, logs) and
prints the ranking. Nothing is deleted on either side. `--no-wait` returns at once; `status`,
`fetch`, `report` and `list` take `--run-id` (default: the last launch); `--selftest` covers the
snapshot and argument logic. The `pll_hdmi` deploy gate (`--min-other-setup`, `--min-positive`,
`--min-seeds`) is forwarded to the sweep on the host AND applied to the report fetched back, and
the run exits nonzero when either fails, so a remote sweep is judged exactly like a local one.
Needs keys-only ssh, python3, rsync and the container runtime on the
host (`--remote-env CONTAINER_RUNTIME=docker`). Local fits obey the machine ceiling the same way:
`FIT_SLOT_DIR=<dir> FIT_SLOT_MAX=3 python3 tools/seed_sweep.py ...`.

## Timing and area facts

[`docs/timing.md`](timing.md) records where the clk_sys critical paths are (the CPU's
datapath; the platform cones sit behind it), the landed zero-cycle cuts and why no further one is
worth taking, and the path-census tools (`tools/timing/`, run as `QUARTUS_POST_STA_TCL` in a fit).

- **Every build runs past timing closure.** The worst cones carry ~17.2-17.8 ns of data, about
  54-55 MHz of real closure, and `base` runs at 90 MHz. On the current tree the 90 MHz build's
  clk_sys slack lands at -4.85 to -5.90 ns over 6 seeds (2026-10-28 sweep); 95 MHz seeds were
  hardware-clean but closer to the margin, and 100 MHz is seed-dependent (one of its seeds
  GP-faults a game). Past about -8 ns a sweep's STA ranking is a shortlist for hardware testing, not a
  verdict.
- **Never quote a single fit.** The placer's noise floor is about 1 ns of WNS and ~30-50 LABs
  over seeds of unchanged source, so a small area or timing question needs a seed sweep per side.
  A one-fit delta must be labelled as such.
- **The framework `pll_hdmi` margin is a deploy gate.** The HDMI scaler/OSD domain is frozen
  framework logic pinned to one quadrant; its seed-to-seed spread is 0.11-0.41 ns and a bad draw
  can wedge the scaler on load (the card then cannot screenshot even the Menu core until it is
  rebooted). The rule comes from the framework `pll_hdmi` margin study:
  - **Deploy floor `other_setup >= -0.35 ns`** (`other_setup` in `metrics.json` is the worst
    framework clock, `pll_hdmi` in every fit of this tree). Target `>= 0` (TNS 0: no failing
    path). Every hardware-verified good placement reaches -0.33 ns and every known wedge is far
    below the floor. A seed below the floor is never BEST, and a sweep with no seed above it
    fails; ship below it only with the maintainer's sign-off and a hardware keymap smoke test.
  - **`pll_hdmi` TNS < -5 ns is a caution.** The one hardware-confirmed wedge is TNS -23.1, but
    a WNS inside the floor can still carry a failing cluster (-0.333/TNS -11.0 has never been
    hardware-tested). Prefer a seed with TNS 0; do not quote TNS as a proven mechanism.
  - **Judge a change on 6 seeds per side minimum**, same profile/clock, both sides fitted in
    the same session on the same host: accept it only if mean and worst `other_setup` are within
    0.2 ns of the baseline, the count clearing the floor does not drop, and no new seed falls
    below it. Six seeds resolve a ~0.4-0.5 ns shift; a smaller claim is not measurable and is
    not made.
  The tools enforce the distribution: `tools/seed_sweep.py` records `other_setup`/`other_tns`
  and `hdmi_setup`/`hdmi_tns` in every `summary.txt` and flags/gates on them
  (`--min-other-setup`, `--min-positive`, `--min-seeds`), `tools/remote_fit.py` forwards the
  same three flags (and `--min-sdram-io`, below) and applies them to the fetched report, and
  `tools/fit_matrix.py report --baseline` runs the non-inferiority check. `tools/build.py` writes the chosen seed and its
  margin to `output_files/artifact-timing.json` beside the RBF, with the RBF's own sha256
  (`rbf_sha256`), and `tools/mister_load.sh` refuses an RBF below the floor, a record it cannot
  parse, and a record whose `rbf_sha256` is another RBF's, unless `--allow-marginal-hdmi` is
  passed. An RBF without that file (or a record without a margin) is unrecorded, not verified:
  the loader says so and the margin is unknown.
- **The SDRAM pin interface is a second deploy gate.** Every fit records the output and DQ
  read-capture setup/hold slacks at every timing corner (`output_files/sdram_io.txt`, by
  `tools/timing/sdram_io.tcl`; `sdram_out_setup`/`sdram_out_hold`/`sdram_in_setup`/`sdram_in_hold`
  and their minimum `sdram_io_min` in `metrics.json`, `summary.txt` and `artifact-timing.json`).
  `seed_sweep.py --min-sdram-io NS` (default 0 ns: the SDC's constraints are the supported modules'
  datasheet limits; `none` disables) refuses a seed below it or without the record, and
  `remote_fit.py` forwards it like the `pll_hdmi` flags. Why 0, and how the hardware window is
  measured: [`sdram-margin.md`](sdram-margin.md).
- **A deployed RBF also passes a load screen.** The scaler wedge is also a per-bitstream fault
  that no STA corner predicts: in a load study (about 1,550 loads, two cards), seeds of
  one source ran 89 % and 0/179, a shipping seed with `pll_hdmi` +0.068 ran 2.5 %, and the
  0-wedge control sat at -0.088 (four-corner STA separated none of them). Among seeds that clear
  the floor, deploy only one that passes `tools/mister_load_loop.py --build X=<rbf> --build
  B=<known-good rbf> --loads 10 --block 1 --menu-every 2 --reboot-on-wedge --go` on each of two
  cards with 0 wedges in X's 20 loads. This is a stability check, not a wedge-rate measurement (the
  maintainer's standard since 2026-10-30): a 2.5 % build still passes it 60 % of the time, so a build
  suspected of wedging (a floor-marginal `pll_hdmi`, or a wedge seen in use) gets a longer screen,
  e.g. `--loads 50` per card (8 % for that build). A
  regression run loads a core a few times and cannot see this fault. A wedge is a verdict on the RBF
  loaded just before it (that load can be the previous item's), never on the card's uptime.
  The loop also classifies each core load's frame: a black frame (brightest pixel <= 8, or one flat colour) is a failure of that build (exit 1), so a core that never produces video cannot pass as "ok", and `mister_regress.py` fails any game item whose screenshots are all black.
- **LABs bind, not ALMs**: ~9.2-9.5 ALMs per LAB in practice, so an ALM percentage overstates
  headroom. The design is close to the device's 4,191 LABs with the CD built in.
- **A whole-design A&S A/B is not a price**: parallel synthesis and design-wide resynthesis move
  hundreds of ALMs on a change with provably zero logic. Price a change module-alone with
  `tools/res_exp_map.py` (both variants wired to real ports; an unwired instance is pruned), or
  run the whole design with `NUM_PARALLEL_PROCESSORS 1` and say so.
- **A fit's ALM total is two numbers; seeds average only one.** `tools/fit_area.py compare` splits
  `alms_needed` into `map_alms` (the A&S estimate: identical over every seed of one source) and
  `psyn_alms` (the fitter's physical synthesis, retiming and duplication on top of it, mostly in the
  CPU). Within one source psyn's seed sd is ~50-150 ALMs; across neighbouring sources it moves by
  hundreds (sd ~330 over nine one-cut variants of one tree, -165..+957) and is deterministic per
  netlist, so no seed count resolves a 100-200 ALM change in the total, and LABs follow it. Read a
  cut's own price from the touched entities (`compare`'s map and fit entity rows: exact, or 2SE of a
  few ALMs), and its design-level effect from clk_sys and `pll_hdmi`, not from the ALM total.
- **Count flops, not declarations**: size a candidate from the fit's per-entity register count.
- Moving flops into memory frees LABs; moving an M10K array into MLAB spends LABs (a loss).
- **Silent inference traps no bench can see:** a power-up value or reset on the register that
  captures a memory read makes Quartus build the memory from LUTs; a tautological guard can let
  synthesis delete the logic it protects; a read and a write of the same RAM in one `always`
  block reads as an asynchronous port and never infers. An asynchronous read cannot move to any
  memory. Keep the `map.rpt` RAM Summary row as the evidence that a memory inferred.
- **A rewritten decode ships its proof:** `tools/check_decode_equiv.py --old <rev> --new <rev>`
  proves every changed address predicate equivalent by SAT over every free input bit (with
  `--selftest` planting known errors). Run it whenever a predicate's form changes.

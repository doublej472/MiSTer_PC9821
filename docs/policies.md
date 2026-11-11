# Project policies

The rules that bind every change, in full. [`AGENTS.md`](../AGENTS.md#the-rules-that-bind-every-change)
lists each one in a line and links here; a rule stated here is as binding as one stated there. The
rules that fit in one line (fail-first benches, the Single-Cycle Event Discipline, the read-back
side, never `git add -A`) are stated only there.

## Evidence: where expected values come from

The source order itself is in [`AGENTS.md`](../AGENTS.md#evidence-where-expected-values-come-from).

For a chip's internals a die-level model outranks the behavioural ones: for the YM2608B,
nukeykt's YM2608-LLE (decoded from decapped silicon) is the primary chip-internal reference,
below real captures; it stops at the chip's pins, so the board's analog stage is
capture-only. **Our own RTL and benches are never evidence of what the hardware does** -
deriving an expected value from our RTL is circular. When references disagree, follow the
higher-ranked one and record the divergence in a comment. Cite references by project and file
(`NP2kai io/gdc.c`, `MAME src/mame/nec/pc9801.cpp`); third-party source is not vendored here.

A response measured on two machines is only comparable when the capture chains are equivalent
(an analog interface and an HDMI capture are not). What survives a chain mismatch is a
within-recording ratio. Validate the analysis (windows, alignment) before blaming the chain.

## The rules that bind every change

- **Rates come from the device, not from `clk_sys` counts.** Any guest-visible time derives from
  a real frequency (the device's own clock or a guest-programmed register), so changing `clk_sys`
  cannot change it. `tb_pc9821_sysclk_invariance` checks this at two clocks. The raster comes
  from the GDC's own SYNC parameters, not constants.
- **One clamp at the authentic junction.** The FM+ADPCM sum clamps once where the die does
  (`jt08_acc`, the YM2608B output shifter rails at +-32768); the six-drum bus is the die's 16-bit
  wrap, not a wide sum or a saturation. The SSG leaves the chip on a separate analog pin and joins
  zero-mean through the board's coupling cap, so it is not clamped with FM+ADPCM; its level is a
  capture-derived board factor (`docs/probes/SNDTEST-balance-2026-09-25.txt`) pinned by a bench.
- **A knob that changes constants is a compile-time parameter, not a runtime mux.** One place
  decides it (`build_profile.py` writes the value into `z486_mister.sv`), it travels down as a
  `parameter`, and the unselected branch const-folds away, so having the option costs nothing in
  a build that does not use it. A bench asserts the non-default value so a dropped connection
  cannot silently fall back to the default. **Exception (owner, 2026-11-08):** the I/O timing
  choice (item 82) is an OSD option, a runtime choice between "Fast" (as fast as timing allows,
  no defined cost table) and the measured Xe10 costs. The same exception covers the field's
  GVRAM half (owner, 2026-11-08): in Xe10 the GVRAM stores (GRCG read-modify-write and TDW,
  and plain dword stores) take the machine's measured sustained store period
  (`pc9821_gvram_arb.sv`'s Xe10 table, `tb_pc9821_gvram_xe10_store`); in Fast every GVRAM period
  is exactly what it was before the field existed.
- **Comments carry hardware facts and external assumptions** with their citation next to the
  claim, not narration of the next line. A `file:NNN` citation should quote a short fragment of
  the target line (`` `...` ``, `"..."` or `(...)`, at most 80 characters) so it can be checked by
  eye. `tools/check_line_citations.py` gates every citation of a file in this repository: the
  line must exist and a quoted fragment must sit within 3 lines of it, so re-point citations
  when you move their target (`--unquoted` lists the ones with no fragment to check by eye).
- **Latency and performance trades are raised, not decided by a contributor.** A change that saves
  area but costs cycles on a guest-visible path goes into
  [`docs/trade-candidates.md`](trade-candidates.md) with both sides priced. A value read
  differently, a feature removed, or a capture-pinned timing exceeded is not a trade.
- **The boot golden is a canary, not a constant.** `CYCLES used=930528` moves only with a reported,
  attributed reason and the maintainer's approval; it is never re-pinned silently (last move
  930533 -> 930528, a z486 re-vendor: -1 for CLI/STI and LOOP-not-taken without the 386
  refetch, -3 for the real-mode far-transfer tail without its CS-limit restore, -1 for
  real-mode interrupt delivery without its long jump back, 0 for misaligned direct loads on
  the probe pipeline). Its blind spots:
  it is VSYNC-locked at its endpoint (so it cannot see I/O exposure), runs with paging off, and
  uses a fixed-latency SDRAM model rather than `sdram.v` (a controller change cannot move it).
- **Generated files: fix the generator, then regenerate.** `tests/pc9821/bench_sources.sh`
  (`tools/gen_bench_sources.py`), the generated PLL/SDC (`build_profile.py`), the EGC/GDC
  compare vectors (`tools/gen_*_compare_vectors.py`) and the keyboard table in
  `docs/user/input.md` (`tools/gen_keymap_table.py`, from `pc9821_kbd.sv`'s `translate()`) are
  outputs. Resolve a merge conflict in the
  generator (take the union) and re-run it.
- **A power-up value lives on an internal register, never on an output port.** Quartus 17.0
  ignores an initializer in an ANSI output-port declaration (`output reg p = 1'b1` powers up 0),
  and under the qsf's `ALLOW_POWER_UP_DONT_CARE` a register with no kept power-up level whose data
  input is a constant (a set-only or clear-only flag) is replaced by that constant; Verilator keeps
  every initializer, so no bench sees it. An `initial` block that assigns an output-port register
  is the same request and is not measured either way, so it is held to the same rule. An internal
  `reg r = v;` keeps `v` (measured,
  [`sdram-margin.md`](sdram-margin.md#2-the-run-time-phase-instrument-test-builds-only)).
  `tools/check_powerup_init.py` holds the source to this, and with `--map-rpt` checks a fit's
  data_in ties against the initializers.

## Performance, latency and area policy

- **Never reduce performance to meet timing.** A timing cut must be cycle-identical; a cut that
  costs cycles is a trade (`docs/trade-candidates.md`), decided by the maintainer.
- **No guest-visible latency regression against the real Xe10.** An area or timing change that
  touches a peripheral needs a before/after cycle count on its guest-visible path, compared with
  the captures in `docs/probes/` (the boot golden alone is blind to I/O latency). Exception: the
  storage paths (IDE, CD-ROM, FDD) are variable and slow on the real machine, so they may take a
  small measured, reported increase without a trade.
- **Main RAM only needs the ballpark of a 486/33 with 60 ns FPM DRAM** (about 150-180 ns for a
  single miss, 270-330 ns for a 16-byte line fill); faster is fine, and no main-RAM capture is
  needed. Device timings pinned by captures are not covered by this.
- **Video scanout always has priority over the CPU at the SDRAM arbiter.** A late scanout burst
  can break the composited image outright, while a slower CPU access only costs throughput, so no
  arbitration change may delay or stretch a scanout request to speed the CPU up.
- **Keep zero-cycle ALM cuts even when the LAB count stays flat** (fewer ALMs leave the fitter
  routing room), and keep cycle-identical timing cuts that cost a little area. Judge an area series
  cut by cut (each cut's own entity price plus its effect on clk_sys and `pll_hdmi`), never as one
  bundle; drop only the cuts that cost timing.
- **CL3 is accepted on the >= 100 MHz overclock presets** (the SDRAM's CL2 rating ends there);
  the shipping clock stays at CL2.

## Documentation and wording

- `README.md` is for users only and stays short: what the core is, its hardware features (one
  line each, linked), what it needs, install and first start, short recipes, and links to the
  user guides in `docs/user/` and a pointer to `AGENTS.md`. The detail lives in those guides
  (setup, options, images, input, DOS and Windows 95, hardware, troubleshooting); the known issues
  are the "Known issues" section of [`docs/user/troubleshooting.md`](user/troubleshooting.md).
  README names no game or program titles: per-title results and the drivers or patches each needs
  live in [`docs/user/compatibility.md`](user/compatibility.md), which covers every title the tests
  run. Known issues are described generically, and behaviour the real machine shares (a driver
  refusing reads during CD-DA) is not a core issue.
- `docs/` keeps user guides under `docs/user/` and contributor and reference documents at the top
  level; [`docs/README.md`](README.md) indexes both, and `AGENTS.md`'s docs table lists the
  contributor set. A moved document has every reference in the tree re-pointed in the same change.
- The tree is published as-is, so comments, docs and messages use neutral wording: state the fact
  and the reason, with no attributions ("decided on <date>"), no internal work-branch, agent or
  review labels, no host or machine names, no personal paths and no private repository names.
- Durable knowledge belongs in this repository (`AGENTS.md`, `docs/`, `todo/`), not in an agent's
  private notes: only facts about one developer's environment (hosts, cards, local paths) live
  outside it.

## Fixed design decisions

- **Licence** (owner decision, 2026-11-04). The code and documentation written for this project
  are licensed under the Apache License 2.0 (root `LICENSE`); `NOTICE` states what that grant
  covers. Code or data copied or derived from another project keeps its own licence: it is listed
  in `NOTICE` (its part, the files, the licence text a permissive licence requires) in the same
  change that brings it in, and a change to a vendored or GPL-derived file is made under that
  file's licence. `src/z486/` (the fork's own terms), `sys/` and the vendored files of
  `src/opna/` are not relicensed.
- **The BIOS pack link** (owner decision, 2026-11-04). README's "What you need" keeps its link to
  an external archive of the Xe10 BIOS pack as a reference; building the pack from one's own
  dumps stays the documented route. The tree itself still holds no NEC or Yamaha firmware.
- **Defaults favour running software** (owner decision, 2026-11-04). An OSD field's default
  (its position 0) is the value that lets the most programs and games start without the user
  touching a setting. Matching one measured machine's factory setting is not, by itself, a
  reason for a default. GDC Clock defaults to 2.5 MHz for this reason. Floppy mode defaults to
  `Auto (1M)`, not the Xe10's factory `1M`, because some 2DD boot disks use the 640 KB
  interface and stay black at `1M`. Each field's default and its reason are registered in
  `tools/check_osd_contract.py` (`FIELD_DEFAULT`).
- The hard disk (hps_io slot 0) is always IDE bank 0's master. Bank 1's master is chosen in the
  OSD ("IDE bank 1"): the CD-ROM (the default, the stock CD-equipped Xe10's layout) or a second
  hard disk (hps_io slot 3, "Mount HDD2"); a build without the CD has only the second disk to put
  there. Nothing else about the layout is configurable: no slaves, no CD on bank 0. The two Mount
  entries stay on the OSD's main page whatever the field says, so every MGL keeps working.
- No in-core CUE parser: BIN/CUE support waits for Main_MiSTer to handle this core's CD images;
  `tools/cue2pcd.py` converts in the meantime.
- The `--hdmi-rclk` / `--hdmi-rclk-q2` options stay as off-by-default rescue tools for a seed
  whose `pll_hdmi` tail is a global-clock exile; Quartus Lite drops LogicLock regions, so
  clock-network assignments are the only floorplan tool.
- The keyboard translation follows only the key codes of the latest Main_MiSTer release; codes an
  older Main_MiSTer sent are not accepted as aliases (owner decision, 2026-10-31). The JIS `ろ` key
  is set-2 0x51 (Main_MiSTer 3967553, "map KEY_RO to PS/2 set 2 code 51h"), not the 0x13 that
  releases before it sent.
- The -86 board's OPNA (owner decision, 2026-11-01, item 155): the YM2608's ~25 us BUSY after a
  data write (the Xe10 shows it on about a quarter of data writes, XE10T `/OPNA2`) is not
  modelled - BUSY rises only when the board glue's write queue is half full, so the core is
  faster, never slower; and the timer registers (0x24-0x26, 0x27 bits 3-0) and flag resets act
  at the guest's write rather than behind that queue, while 0x27's CH3-mode bits stay ordered
  with the queued FM writes (`src/opna/pc9821_opna.sv` `host_tmr`, `host_clr_tmr`).

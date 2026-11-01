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
  cannot silently fall back to the default.
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
- **The boot golden is a canary, not a constant.** `CYCLES used=930533` moves only with a reported,
  attributed reason and the maintainer's approval; it is never re-pinned silently (last move
  930529 -> 930533, a z486 re-vendor: +1 for the real-mode AC-on-interrupt correction's extra cycle
  per real-mode INT, +3 for microcode reads probing the L1 from any microcode step). Its blind spots:
  it is VSYNC-locked at its endpoint (so it cannot see I/O exposure), runs with paging off, and
  uses a fixed-latency SDRAM model rather than `sdram.v` (a controller change cannot move it).
- **Generated files: fix the generator, then regenerate.** `tests/pc9821/bench_sources.sh`
  (`tools/gen_bench_sources.py`), the generated PLL/SDC (`build_profile.py`), the EGC/GDC
  compare vectors (`tools/gen_*_compare_vectors.py`) and README's keyboard table
  (`tools/gen_keymap_table.py`, from `pc9821_kbd.sv`'s `translate()`) are outputs. Resolve a merge conflict in the
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

- `README.md` is for users only: what the core needs, installing, running, DOS setup and known
  issues, plus a short pointer to `AGENTS.md`. It names no game or program titles: per-title results
  and the drivers or patches each needs live in [`docs/compatibility.md`](compatibility.md),
  which covers every title the tests run. Known issues are described generically, and behaviour the
  real machine shares (a driver refusing reads during CD-DA) is not a core issue.
- The tree is published as-is, so comments, docs and messages use neutral wording: state the fact
  and the reason, with no attributions ("decided on <date>"), no internal work-branch, agent or
  review labels, no host or machine names, no personal paths and no private repository names.
- Durable knowledge belongs in this repository (`AGENTS.md`, `docs/`, `todo/`), not in an agent's
  private notes: only facts about one developer's environment (hosts, cards, local paths) live
  outside it.

## Fixed design decisions

- The hard disk is always IDE bank 0's master and the CD-ROM always bank 1's master, whether or
  not the CD is built or a disk is mounted.
- No in-core CUE parser: BIN/CUE support waits for Main_MiSTer to handle this core's CD images;
  `tools/cue2pcd.py` converts in the meantime.
- The `--hdmi-rclk` / `--hdmi-rclk-q2` options stay as off-by-default rescue tools for a seed
  whose `pll_hdmi` tail is a global-clock exile; Quartus Lite drops LogicLock regions, so
  clock-network assignments are the only floorplan tool.
- The keyboard translation follows only the key codes of the latest Main_MiSTer release; codes an
  older Main_MiSTer sent are not accepted as aliases (owner decision, 2026-10-31). The JIS `ろ` key
  is set-2 0x51 (Main_MiSTer 3967553, "map KEY_RO to PS/2 set 2 code 51h"), not the 0x13 that
  releases before it sent.

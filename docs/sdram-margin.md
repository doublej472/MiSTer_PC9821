# SDRAM margin: the corner gate, the phase instrument and the shmoo

How the SDRAM interface's margin is measured, for the supported module set in
[`sdram.md`](sdram.md). Three tools: an STA record and deploy gate on every fit,
a test-only bitstream whose SDRAM_CLK phase the guest steps at run time, and a DOS program that
sweeps that phase under a whole-memory RAM stress.

## 1. The SDRAM I/O corner gate (every fit)

`tools/build.py` runs `tools/timing/sdram_io.tcl` after every successful fit, against the fitted
database with the SDCs loaded, and writes `output_files/sdram_io.txt`: the worst setup and hold
slack of the SDRAM **outputs** (paths to `PC9821_SDRAM_CLK`: command, address, BA, DQM, write
data) and of the **DQ read capture** (paths from it: the setup-2 pairing the SDC sets) at every
timing corner (slow/fast, 100C/-40C). The flow's own STA summary is the slow 100C corner and the
output paths only; the read capture binds at the fast corner, so before this record no sweep
saw half of the window.

`tools/fit_metrics.py` parses it into `metrics.json` (`sdram_out_setup`, `sdram_out_hold`,
`sdram_in_setup`, `sdram_in_hold`, each the worst over the corners; `sdram_io_min` and
`sdram_io_worst` = `group@corner`; the whole table as `sdram_io_corners`), `tools/seed_sweep.py`
records the same keys in each `summary.txt` and shows them in `--report` (`outS outH inS inH
sdIO`), and `artifact-timing.json` carries `sdram_io_min`/`sdram_io_worst` beside the RBF.

**The gate: `--min-sdram-io NS`, default 0 ns** (`tools/fit_metrics.py` `SDRAM_IO_FLOOR`; `none`
disables it), on `seed_sweep.py` and forwarded by `remote_fit.py` like `--min-other-setup`. A seed
is deployable only when `sdram_io_min >= NS`; a seed with no record (fitted before the script ran
in every fit) is not deployable while the gate is on. Why 0: the SDC's I/O constraints are the
supported set's datasheet limits (AS4C32M16SB-7, the slower of the supported -6/-7 grades: tAC
6.0 ns at CL2, tOH 2.5, tIS 1.5, tIH 0.8) applied at every FPGA corner at once, so a slack >= 0
means the placement meets every supported part's datasheet at every corner, and a negative one
names the corner and group where it does not. The model has no board flight time and no dual-chip
loading; those are what the hardware window below measures, so the gate does not try to stand in
for them with an invented margin. Raise the floor only from shmoo data (a window edge that tracks
an STA group).

Fits made before the record existed keep only `output_files` (no database, `.sdo` or per-corner
report), so they cannot be re-derived; they need a refit. The release sweep's seeds 2-5 were
refitted from a source that differs only in this test-only instrument (built off): every seed
reproduced its placement exactly (the same clk_sys and `pll_hdmi` slack and ALM count), so these
are the release seeds' figures, 90 MHz base (ns):

| seed | out setup | out hold | in setup | in hold | `sdram_io_min` (where) |
|---|---|---|---|---|---|
| 2 | +1.258 | +1.014 | +0.171 | +0.526 | +0.171 (in setup, slow 100C) |
| 3 | +1.161 | +1.215 | +0.797 | +0.372 | +0.372 (in hold, fast -40C) |
| 4 | +1.321 | +1.285 | +0.793 | +0.373 | +0.373 (in hold, fast -40C) |
| 5 | +1.309 | +1.016 | +0.177 | +0.512 | +0.177 (in setup, slow 100C) |

The read capture binds in every seed, never the outputs: in setup at the slow corner on the seeds
whose DQ input delay chains are empty (2, 5), in hold at the fast corner on the seeds the fitter gave
chains (3, 4), which carry about 0.6 ns more setup and 0.15 ns less hold. Every seed clears the
0 ns floor by at least 0.17 ns. For comparison, a 100 MHz CL2 build (section 3) fits at in setup
-0.695 ns: STA puts that clock outside the supported parts' read window before any board effect.

## 2. The run-time phase instrument (test builds only)

`build_profile.py ... --dbg-sdram-phase` (Config `sdram_phase_dyn`, `SDRAM_PHASE_DYN`; off in every
preset, refused at >= 100 MHz where SDRAM_CLK is the clk_sys DDIO and has no phase) generates the
main PLL with its dynamic-phase-shift ports in use and builds:

- `pc9821_sdram_dps` on the PLL's scan clock (the 50 MHz reference): one PLL phase step per
  request, PHASEEN held until PHASEDONE falls, then PHASEDONE awaited high (Intel Cyclone V Device
  Handbook, "Dynamic Phase Shift"). CNTSEL 1 is the SDRAM pin clock's logical output: in DPS mode
  altera_pll routes CNTSEL through LUTs the fitter rewrites to the physical counter it placed.
  One step is VCO/8: **154.3 ps at the 90 MHz build** (810 MHz VCO).
- `pc9821_sdram_phase_ctl` on clk_sys, on the device bus at **0x5FF0/0x5FF2** (unclaimed by this
  core and by the NP2kai/MAME port maps; only this build decodes them):
  - write 0x5FF2: the requested offset in signed steps, walked one step at a time; read 0x5FF2:
    the applied offset;
  - write 0x5FF0: 00 keepalive, 01 +1, 02 -1, 03 nominal, 04 clear `reverted`; read 0x5FF0:
    `0xA` in [7:4], [3] fault, [2] reverted, [1] busy, [0] armed;
  - **auto-revert**: while armed, no write to either port for 100 ms requests offset 0 and sets
    `reverted`; a core reset requests offset 0 too.
  - **fault**: a step the PLL did not finish within the timeout is acknowledged anyway, and status
    [3] is set and stepping stops (the applied offset may then be off by one per timed-out step);
    it is sticky on clk_sys until a core reset, which clears it so stepping resumes. The scan-clock
    half reports each step's outcome with its acknowledge and clears it at every accepted request,
    so no flag in the instrument is set-only: with no kept power-up level, the qsf's
    `ALLOW_POWER_UP_DONT_CARE` lets Quartus replace a register whose data input is a constant by
    that constant, which is how the first fitted builds came to read `fault` set at power-up and
    never step (map report: `sdph_dps|fault ; Stuck at VCC due to stuck port data_in`). A fitted
    build's
    `z486_mister.map.rpt` must have no `Stuck at` line for `sdph_dps` or `u_sdph` state registers.
  - **Why the initializer did not hold**: it was written in the output-port declaration
    (`output reg fault = 1'b0`), and Quartus 17.0 ignores those. Measured by synthesizing a probe
    module in the build container with `ALLOW_POWER_UP_DONT_CARE ON` (2026-10-29): `output reg p =
    1'b0` assigned only 1 was removed "Stuck at VCC due to stuck port data_in" and `output reg p =
    1'b1` assigned only 0 "Stuck at GND"; an internal `reg r = 1'b0` assigned only 1 stayed a
    register; and in quartus_cdb's VQM an internal `reg r = 1'b1` with a variable data input got
    NOT-gate push-back (powers up 1) while `output reg p = 1'b1` did not (powers up 0). So every
    instrument register is an internal declaration driving its port, and the rule is in
    [`policies.md`](policies.md#the-rules-that-bind-every-change) (`tools/check_powerup_init.py`).

With the knob off nothing is built: the generated PLL wrapper declares the five DPS ports tied off
(so `z486_mister.sv` instantiates it one way and the SDC's `emu|pll|pll_inst` path never moves),
the device decode is the base one (`tb_pc9821_device_select`), and `--check` holds the PLL,
the top level and the record together. `tb_pc9821_sdram_phase` drives both halves against a PLL
DPS model. The SDC stays at the build's nominal phase, so every step of a sweep is the same
placement and the same delay chains.

## 3. The 100 MHz CL2 test point (tRCD/tRP versus the I/O window)

Two more measurement overrides (sdram.v `DBG_CL` / `DBG_TRCD_TRP`, 0 in every preset):
`--dbg-sdram-cl2` keeps CL2, the phase-shifted SDRAM_CLK and the SDC's CL2 tAC at any clock (the
structure the old 100 MHz CL2 builds had; the derived 100 MHz structure is CL3 through the DDIO
cell), and `--dbg-sdram-trcd-cycles N` forces tRCD and tRP to N cycles. With the phase instrument
they make two bitstreams of one family that differ in one constant:

| build | profile arguments | tRCD/tRP at 100 MHz |
|---|---|---|
| `cl2-100-trcd2` | `--custom --clk-sys-mhz 100 --dbg-sdram-cl2 --dbg-sdram-trcd-cycles 2 --dbg-sdram-phase` | 20 ns, the old builds' value (violates the -7 part's 21 ns) |
| `cl2-100-trcd3` | `--custom --clk-sys-mhz 100 --dbg-sdram-cl2 --dbg-sdram-trcd-cycles 3 --dbg-sdram-phase` | 30 ns, what the 21 ns figure rounds to |

The one constant does not reach every access. At 100 MHz tRAS (42 ns) is 5 clocks, so under
tRCD 2 a two-half read segment (every single-dword read, and a one-dword segment of a split
burst) delays its first READ one clock for tRAS (sdram.v `RD_SHIFT2` = 1): its first CAS comes
30 ns after the ACT, as in `trcd3`. Line fills (eight halves) and writes do run at 20 ns, and
`trcd2` also keeps the speculative pre-ACT window that `trcd3`'s 3-clock tRCD empties. A
difference between the two that only single-dword reads show is not a 20 ns tRCD result.

`build_profile.py` refuses an N whose table sdram.v's elaboration checks refuse (tRP above CAS + 2
clocks, a store exit short of tRC, a two-half write or four-half read inside tRAS): at 100 MHz CL2
that is N = 1 and N >= 5.

Reading them: if `trcd3` shows a usable window on the card where 100 MHz CL2 failed and `trcd2`
does not (or fails across the whole sweep), tRCD/tRP is the cause; if both show the same narrow
or empty window, the I/O window is; if both are wide, neither (look at the placement). The phase
sweep is what separates them: a timing-table fault fails at every phase, an I/O fault only
outside the window.

## 4. The DOS program: `tools/hwprobe/sdshmoo`

`SDSHMOO [lo [hi [passes [maxMB [stop]]]]]` (defaults -36 36 1 0 4; `make -C tools/hwprobe
sdshmoo/sdshmoo.com`). From a freshly booted plain DOS (no HIMEM/EMM386: it uses all extended
memory directly from protected mode) it runs step 0, then +1, -1, +2, -2, ... and stops each
direction after `stop` consecutive failing steps or at lo/hi, then a FINAL step 0. At each step
it runs nine patterns over every byte of extended memory the BIOS reports (address and inverse,
walking 1/0 across DQ[15:0], two checkerboards that toggle every DQ every beat, a two-half
interleave that thrashes banks and, past 64 MiB, the two chips of a 128 MB module, a 4100-byte
row-thrash stride, mixed byte-enable writes including a misaligned word, hashed random data),
counting errors per chip half (address bit 26) with the failing DQ bits, the first failing address
and its XOR, and per pattern. Every verify read is an L1 line fill from SDRAM.

**What a run costs.** The program ALWAYS starts at step 0 and walks outward: the up direction
runs every step from +1 to `hi` and the down direction every step from -1 to `lo` (each until
`stop` consecutive failures), so `lo` and `hi` bound the walk, they do not select steps;
`SDSHMOO e e 3` runs every step from 0 to e (and nothing below 0 when e > 0). The FINAL step runs
the full `passes` count again, so a run is `passes` x (steps + 1) pattern sets: `SDSHMOO 0 0 20` is
40 nominal passes, about 2 h 40 min at 96 MB and 90 MHz (one 96 MB pass is about 4 min).

The step's code, stack and counters run from GVRAM (block RAM), so at a bad phase the only SDRAM
accesses are the test's; a 64 KiB canary written at nominal before the shift and checked after
the return catches stray writes a mis-taken command makes. Each line is appended to `SDSHMOO.TXT`
and the file closed before the next step (a `BEGIN` with no `STEP` is a hang). It restores the
phase, the borrowed GVRAM plane and the GRCG; extended memory is overwritten, so reboot after it.
On a build without the instrument (status reads 0xFF) it runs the pattern set at nominal only, a
plain whole-memory RAM test.

`tools/hwprobe/sdshmoo/sdshmoo_decode.py SDSHMOO.TXT [--step-ps 154.32] [--need-ns 1.0]` prints
every step, the contiguous passing window through step 0 for the module and per chip half (in
steps and ns, flagging an edge the sweep did not reach), and a verdict against the criterion below.
A step counts only where the phase really moved there: its `rb` (the applied offset read back after
the move) must equal the requested step, else it is listed as NOT APPLIED, with no ns offset, and
is never a window point. Data errors, the canary, a wait timeout and a watchdog revert fail a step;
the `fault` bit does not fail a step's data but makes the run INCONCLUSIVE (exit 3), as does a step
not applied or a window side short of the criterion whose edge was never measured (a nominal-only
run); PASS is 0, FAIL 1.

The userdisk tier runs the whole control path in simulation: `USERDISK_SDPH=1` builds the
instrument against a DPS model (no phase moves in simulation; the model counts steps and prints
`SDPH: pulses=.. net_steps=..` at the end).

## 5. Run procedure (for the integrator; needs card time on both test cards)

Rules as in [`mister-testing.md`](mister-testing.md#rules-for-testing-on-a-mister): the card's
zreg lock, zreg-named files, a COPY of the disk image, restore the config, never leave a reader on
the UART, reboot to clear a wedged scaler and prove a Menu screenshot before trusting any result.

1. **Builds** (fit host; `remote_fit.py`, each with `--seeds 2-4`): `base --dbg-sdram-phase`
   (90 MHz, the main sweep), and the two `cl2-100-trcd2/3` builds of section 3. Optional: 95 MHz
   (`--custom --clk-sys-mhz 95 --dbg-sdram-phase`) for the frequency margin. Pick per build the
   seed with the best `pll_hdmi` (the gate's floor applies; the SDRAM I/O floor does not apply to
   an off-nominal test build) and record its `sdram_io.txt` beside the results. The shmoo
   bitstreams are never shipped. Prefer, at 90 MHz, a seed whose DQ input delay chains are empty
   like the shipped seed's (read capture bound in setup at the slow corner); at 100 MHz, the same
   seed number for both `trcd` builds, so they share the I/O placement and differ in tRCD/tRP
   alone (the first fits did: each seed's I/O slacks matched to within 3 ps across the pair).
   Before taking a build to a card, `grep 'Stuck at' output_files/z486_mister.map.rpt | grep -E
   'sdph_dps|u_sdph'` must print nothing (section 2, fault).
2. **Disk**: a copy of a plain-DOS image whose CONFIG.SYS loads no memory manager and whose
   AUTOEXEC.BAT ends at the prompt (or runs `SDSHMOO > NUL` directly); put `SDSHMOO.COM` in its
   root (`tools/mister_regress.py`'s `patch_hdd`, or `tools/hwprobe/integ/fatimg.py`'s `Fat.put`).
   Set the OSD RAM size to the largest the module allows (96 MB on a 128 MB module, so both chips
   are tested).
3. **Baseline**: load the 90 MHz shmoo build under a zreg name, with the card's lock held:
   `MISTER_CORE=PC9821Z486-zreg MISTER_IMG=<path>/<name>-zreg.img tools/mister_load.sh` (a zreg
   core writes and deletes only zreg-named files: its RBF, its MGL and
   the image copy; it uses the card's pack read-only and deletes nothing unless `--clean-stale` is
   given, [`mister-testing.md`](mister-testing.md#deploying-and-loading-a-core)), or deploy the same
   files by hand as `tools/mister_regress.py` does. Boot, check that 0x5FF0 reads `A0` (the header's
   `st=`; `A8` is a set `fault` and the build cannot step), run `SDSHMOO 0 0 10` (nominal only:
   STEP 0 and FINAL, 10 passes each, so 20 nominal passes): it must report zero errors. Then
   reboot.
4. **The 90 MHz sweep**: `SDSHMOO -36 36 1 0 4` (a whole period each way at most; stops 4 steps
   past each edge). Reboot, fetch `SDSHMOO.TXT` (mount the image copy or scp it off the card), and
   decode with `--step-ps 154.32`; every step must be applied (`rb` = the step). Confirm both edges
   in one run with 3 passes: `SDSHMOO Ldn-1 Lup+1 3 0 1`, where Ldn and Lup are the last passing
   steps below and above 0. It walks the whole window again at 3 passes (the program always starts
   at 0) and stops each direction at its first failing step; `SDSHMOO e e 3` does NOT test step e
   alone (section 4).
5. **The 100 MHz test point**: the same sweep on `cl2-100-trcd2` and `cl2-100-trcd3`, on both
   cards, the DE10-Nano card first (where 100 MHz CL2 failed 9 of 11 placements). The step is the
   build's VCO/8, read from the fit report's main-PLL `PLL VCO Frequency`: 810 MHz at 90 MHz
   (154.3 ps, `--step-ps 154.32`, sweep -36..36), 400 MHz at 100 MHz (312.5 ps, `--step-ps
   312.5`, sweep -16..16 covers the 10 ns period), 950 MHz at 95 MHz (131.6 ps, `--step-ps
   131.58`, sweep -42..42).
6. **Both cards** (the MiSTer Pi card, with its bundled 128 MB BGA board; the DE10-Nano card, with
   a 128 MB Alliance module): steps 3-5 on each.
7. **Warm soak** (optional): cover the card for 30 minutes of `SDSHMOO 0 0 200`, then repeat the
   two edge steps; the shift of each edge is the temperature coefficient.

## 6. Criteria, for the supported set

The supported set ([`sdram.md`](sdram.md)): the Alliance AS4C32M16SB -6/-7 on single-chip and
dual-chip 128 MB boards, and the MiSTer Pi's bundled board. **Excluded**: x8 pairs (AS4C64M8SD),
-8 and slower grades, low-power parts rated below the clock (AS4C32M16SC at 133 MHz is rated, but
the reported problems with it are not designed for), remarked or counterfeit parts, and third-party
boards whose layout adds load beyond a dual-chip 128 MB board. Because the slow edge of the
supported set is already in the SDC (the -7 part's figures), the criteria need not reserve margin
for parts outside it:

- **Ship at 90 MHz**: on both cards, at least **1.0 ns of passing window on each side** of the
  shipped phase (7 steps of 154 ps), zero errors at nominal over 20 passes, FINAL clean. The
  1.0 ns covers a hot module and supply (about 0.7 + 0.15 ns, sd-margin survey) plus PLL
  quantisation and jitter (0.15 ns); for the supported set no further population allowance is
  reserved, the -7 part's datasheet edge being in the model already. If the two cards' edges
  differ by D on a side, the intersection window must still give 1.0 ns.
- **Re-centre** when both cards have at least 2.5 ns in total but one side is under 1.0 ns: move
  `--sdram-phase-ps` to the intersection's centre (free in area, a new placement: rerun the
  regression and the load screen).
- **Frequency margin**: 95 MHz must pass the nominal step on both cards; the 100 MHz test point
  attributes the old 100 MHz failure (section 3).
- **A failure confined to one DQ bit** is a board/trace fault to document, not a core change.

## 7. Results

### 90 MHz, both cards (2026-10-29/30)

The test build: `base --dbg-sdram-phase` at 90 MHz, seed 3 (nominal SDRAM_CLK phase 7263 ps, VCO
810 MHz, one step 154.32 ps). Its `sdram_io.txt`: out setup +1.324, out hold +1.306, in setup
+0.786, in hold +0.372 ns; `sdram_io_min` +0.372 ns (in hold, fast -40C), the read capture binding
in hold at the fast corner like release seeds 3 and 4 (section 1). The instrument read `st=A0`
(no fault) on both cards and every step's `rb` equalled the requested step. RAM size 96 MB, so
both chips of each 128 MB module were tested (extended memory to 0x06000000).

| run | the DE10-Nano card | the MiSTer Pi card |
|---|---|---|
| step proof, `SDSHMOO -2 2 1 8 1` (8 MB) | -2..+2 all pass, every `rb` applied | not run |
| nominal, `SDSHMOO 0 0 10` (20 passes, 96 MB) | zero errors, FINAL clean | not run |
| sweep, `SDSHMOO -36 36 1 0 4` (1 pass per step) | passing -19..+26 (-2.932 / +4.012 ns) | passing -23..+24 (-3.549 / +3.704 ns) |
| first failing steps of the sweep | -20 (chip 0, DQ[15:0]); +27 (chip 1, DQ 1, 2, 4, 9) | -24 (chip 1); +25 (both chips) |
| edge confirmation, 3 passes per step | `SDSHMOO -20 27 3 0 1`: passing -18..+20 (**-2.778 / +3.086 ns**, 5.864 ns total) | `SDSHMOO -24 25 3 0 1`: passing -23..+23 (**-3.549 / +3.549 ns**, 7.099 ns total) |
| first failing steps at 3 passes | -19 (5 errors, chip 0, DQ[7:0]); +21 (1 error, chip 1, DQ 15) | -24 (182 errors, chip 1, DQ[15:8]); +24 (3 errors, chip 1, DQ 4) |
| FINAL step 0 of each run | pass | pass |

**Verdict: PASS on both cards.** The narrower of the two, the DE10-Nano card at 3 passes, leaves
**at least 2.78 ns of passing window on each side** of the shipped phase (18 steps below, 20
above), against the 1.0 ns criterion of section 6; the intersection of the two cards' 3-pass
windows is -2.778 / +3.086 ns. No re-centre is needed (section 6). The first failure at an upper
edge is sometimes one bit (DQ 15 on the DE10-Nano card at 3 passes, DQ 4 on the MiSTer Pi card),
but the steps beyond it fail on several bits or whole byte lanes, so neither card shows the
one-bit board fault of section 6.

Observations:

- At 3 passes per step the DE10-Nano card's window is 1 step narrower below and 6 steps narrower
  above than at 1 pass: the edges are statistical, and the 3-pass figure is the one that counts.
  The MiSTer Pi card's lower edge did not move; its upper edge moved 1 step.
- Both 1-pass sweeps HUNG outside the window (the DE10-Nano card at +30 after three failing
  steps, the MiSTer Pi card at +27 after two: a `BEGIN` with no `STEP`), so a step that far out can
  stop the program. Both edges of each window had already been measured.
- The window belongs to this test build's placement (a measured window belongs to one bitstream,
  [`sdram.md`](sdram.md)); its read capture binds where release seeds 3 and 4 bind (in hold at
  the fast corner), at the same slack to within 1 ps.

### 95 MHz nominal, both cards (2026-10-31)

The frequency margin of section 6. The test build: `--custom --clk-sys-mhz 95 --dbg-sdram-phase`
from pc9821 817700bf, seed 3 (SDRAM pin-clock phase 6678 ps). Its `sdram_io.txt`: out setup
+1.050, out hold +1.159, in setup +0.612, in hold +0.250 ns; `sdram_io_min` +0.250 ns (in hold,
fast -40C). The instrument read `st=A0` (no fault) before and after every pass on both cards,
RAM size 96 MB.

| run | the DE10-Nano card | the MiSTer Pi card |
|---|---|---|
| nominal, `SDSHMOO 0 0 6` (6 passes, 96 MB) | zero errors, FINAL clean, `st=A0` | zero errors, FINAL clean, `st=A0` |

**Verdict: PASS on both cards.** The decoder prints INCONCLUSIVE for a nominal-only run because
it measures no window edge; the frequency criterion is the nominal step alone. An earlier 95 MHz
build (seed 2) also ran clean on both cards, but its instrument read `fault` stuck at power-up
(`st=A8`, section 2), so that run is superseded by this one.

### Still open

- **The 100 MHz test point** (section 3): the first `cl2-100-trcd2`/`trcd3` builds (whose
  instrument also read `fault` stuck) never ran SDSHMOO on the DE10-Nano card: `trcd2` stopped at a
  garbled POST memory count, `trcd3` went black or hung at the DOS banner, at 96 MB and at 32 MB.
  The rebuilt pair has not been run.
- The warm soak (section 5, step 7) was not run.

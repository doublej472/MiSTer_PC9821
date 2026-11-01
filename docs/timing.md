# Timing: where the critical paths are

The core runs past timing closure in every preset ([`fitting.md`](fitting.md), "Timing and area facts"). This page
records where the clk_sys critical paths are at the shipping 90 MHz, the tools that find them, which
zero-cycle cuts have landed (the code cites them by the names below), and why no further zero-cycle
cut is worth taking. The design is a single core clock: the platform, the SDRAM controller and,
through a `cyclonev_clkena` gate, the CPU all run on clk_sys.

## Current numbers (`base`, 90 MHz)

A six-seed fit of the current tree (2026-10-28):

| | |
|---|---|
| clk_sys setup slack (worst corner) | -4.85 to -5.90 ns |
| framework `pll_hdmi` setup slack | -0.64 to +0.30 ns; 4 of 6 seeds clear the -0.35 ns deploy floor |
| LABs | 4,125 of 4,191 (seed 4) |
| ALMs needed | 37,355 (seed 4) |

The worst cones carry about 17.2-17.8 ns of data, about 54-55 MHz of real closure. clk_sys hold
and the SDRAM pin I/O group are positive at every corner. A single fit is one placement draw: the
placer's noise is about 1 ns of WNS and 30-50 LABs over seeds of unchanged source, so compare
builds with a seed sweep per side ([`fitting.md`](fitting.md), "Seed sweeps").

## Always load the SDC before a timing query

A `quartus_sta` session must run `create_timing_netlist; read_sdc; update_timing_netlist` before it
reports anything. A raw `quartus_sta -t` session auto-derives clocks, mis-relates the PLL outputs and
reports phantom cross-domain "worst paths". STA names the PLL outputs `general[0]` (clk_sys: the
platform, the SDRAM controller and, through the gate, the CPU) and `general[1]` (the SDRAM pin
clock, from which the SDC derives `PC9821_SDRAM_CLK`; it has no register endpoints).
`z486_mister.clk_sys_top_setup.tcl` is the minimal correct session (the 80 worst clk_sys setup
paths).

Read slack at the worst corner: the fit summary reports the slow 100 C model, and the slow -40 C
corner can be up to ~0.3 ns worse.

## The tools

All of them run as `QUARTUS_POST_STA_TCL` (the script's absolute path) in a `tools/build.py` or
`tools/seed_sweep.py` fit, against the fitted database, so their output lands in each seed's
`output_files/`.

- `tools/timing/census.tcl` writes `output_files/census/`: one worst setup path per endpoint for the
  4,000 worst clk_sys endpoints at the worst corner (`ends_sys.rpt`), the worst hold endpoints
  (`ends_sys_hold.rpt`), every SDRAM I/O path at all four corners, a per-corner summary
  (`corners.txt`), and `keepdb.tar` (the fitted database, so later queries need no re-fit).
- `tools/timing/census.py table|ladder|skew|show|families|md ENDS_RPT...` classifies every endpoint
  into the cones below. `table` prints each cone's worst slack, its gap to WNS and its endpoint
  counts within 0.3 and 1.0 ns per fit; `ladder` the WNS as cone groups are removed in order;
  `skew` the clock skew by launch/latch domain (the gated CPU clock against the platform);
  `show ENDS_RPT CONE K` the K worst paths of one cone with their node chains.
- `tools/timing/p0.py ENDS_RPT...` measures the shared memory-map prefix P0 and the slack of
  `ext_addr_r`'s own D input. `tools/timing/pathchain.py RPT` parses a `report_timing` file into
  node chains (the census's parser).
- `tools/timing/hdmi_place.tcl` writes `output_files/hplace/` (the worst `pll_hdmi` paths with
  cell locations, every cell's location, the keepers of `pll_hdmi` and the video clock), and
  `tools/timing/hdmi_place.py` prints where the framework HDMI cone and the video cluster sit.
- `tools/fit_metrics.py` (the `metrics.json` every sweep seed carries: `clk_sys_setup`,
  `other_setup`, `hdmi_setup`, their TNS) and `tools/fit_area.py compare` (the ALM split into the
  A&S estimate and the fitter's physical synthesis, per entity) are the numbers a sweep ranks by.

## The cones

`census.py`'s names, by where the worst path of an endpoint runs:

| cone | what |
|---|---|
| other CPU | the CPU's datapath not named below; in practice a GPR read -> `gpr_merge`'s EX view -> the byte format -> the shifter's operand muxes -> the barrel -> `result` -> the deferred shift datum (`data_unit.recipe_shift_data`) or `sigma` |
| ucode ROM / decoder | the microcode ROM address and the decoder |
| C1, C2, C3 | segment limit -> request; fetch limit -> prefetch; shifter size -> GPR read |
| C4, C4x | the flag/EA/ALU forward; the load-op result forwarded into the EX view |
| D2, D2s | the VIPT TLB M10K -> hit -> issue; the issue/stall decision into the segment unit |
| SP | the speculative-fetch attribute check |
| TB | the throttle bridge, the clock gate and the GVRAM response route into `z_din` |
| P0 | a label, not a cone: the path starts at `bus_unit`'s `ext_addr_r` and crosses the memory map |
| R1 | `ext_addr_r` -> the memory map -> `z_ready` -> the CPU's fill/response |
| C5 | the PEGC store buffer (`u_storebuf`) |
| C7, C7b | the GVRAM M10K write port; the GVRAM arbiter and GRCG registers that are not the M10K |
| C6, V1, FD | the GDC line base; the CRTC raster from the guest's SYNC block; the FDD media seek offset |
| S2 | the SDRAM controller on clk_sys (its arbiter, row/bank arithmetic and pin registers) |
| CD | the ATAPI drive |

## Where the paths are

**The tree is CPU-bound and flat.** In a 12-seed census at 90 MHz the "other CPU" family set WNS in
10 of 12 seeds (mean gap +0.06 ns), C4 and C7 in one seed each (+0.33, +0.68); the microcode ROM sits
+0.41, C7b +0.70, D2 +0.85, TB +0.87, and every other platform cone +1.1 ns or more behind. Two
thirds of each critical CPU path is routing (10-12 ns of 15-16 ns).

A family ladder (removing each family's paths cumulatively; mean WNS gained): shifter +0.12, ALU
+0.15, EA +0.17, VIPT +0.23, TLB -> `ext_addr_r` +0.29, prefetch +0.34, D-cache +0.41, GVRAM
+0.49 ns. No one family is worth more than about 0.12 ns of the mean, and the shifter's share is
mostly one bad draw. **Only a set of cuts could move WNS**, and every member of that set is a CPU
cut.

P0, the memory-map decode that once set WNS, is no longer a rung: `ext_addr_r -> the memory map`
has no endpoint within 0.3 ns of WNS. V1, FD and S2 are 1.5-2 ns behind.

## The zero-cycle verdict

**No zero-cycle cut beats seed noise at 90 MHz.** Measured with 12 seeds per side on the CPU's
critical family: capturing `recipe_shift_data` every edge (it removes its endpoint from the critical
set, and WNS moves to the next family within 0.1-0.3 ns), picking SIGMA's next state last, and both
together moved the mean by -0.10, -0.07 and +0.18 ns, against a per-seed spread of 0.3-0.4 ns, and
each failed the `pll_hdmi` non-inferiority rule; the pair also cost +410 ALMs in the fit. Area does
not buy slack either: turning the whole physical-synthesis stack off frees ~1,490 ALMs and loses
0.5 ns; turning register retiming alone off is neutral. Quartus 17.0.2 Lite ignores
`OPTIMIZATION_TECHNIQUE SPEED` as an instance assignment on the CPU, and the global setting is
trade T40.

The remaining candidates that do move WNS cost cycles: registering the branch decision (T64), the
D1 direct launch (T65), the VIPT hit verdict (T66), re-opening a D2 pipeline stage (T30), the GRCG
presentation register (T28, T68). They are priced in [`trade-candidates.md`](trade-candidates.md),
together with the zero-cycle CPU cuts measured as fit-neutral or negative (T69-T74).

## Landed zero-cycle cuts

Each is cycle-identical (or, where stated, value-identical in every legal execution) and carries its
proof. The RTL comments cite them by these names.

- **P0.** The memory map decodes every window flag on both candidate addresses and lets
  `win0_moved` pick the finished flag; window bases are spliced (`peg_base | d_addr[18:0]`), not
  added; the RAM-bound compare is a 12-bit slice over `[31:20]` (every OSD guest size is a whole
  MiB). `pc9821_memory_map` exports the window-0 pair (`d_addr`, `win0_moved`) and the subsystem
  reads it, so the window-0 front end exists once. Proofs: `tools/check_decode_equiv.py`,
  `tools/check_memmap_addr_equiv.py`, `tools/check_cpu_addr_front_equiv.py`. **R1** is the same
  decode seen from the response side.
- **C7-head.** `pc9821_iobus` registers `win0_sel != 8'h08` (`win0_sel_moved`) on the edges that
  write `win0_sel` (`tools/check_win0_moved_inv.py`).
- **C7-tail.** `pc9821_grcg` exports both arms of its presentation mux and `pc9821_gvram_arb`
  elaborates its port-A presentation on each, with the capture select last (a Shannon expansion on
  `cl_cap`); the burst and owner routes are expanded the same way, and `pc9821_gvram_share` forms the
  datum's per-byte 0x00/0xFF flags before its owner select (`tools/check_seq_equiv.py --pair`,
  `tools/check_arb_resp_inv.py`).
- **TB.** The GVRAM arbiter's CPU response is routed by the response strobes themselves, not by the
  live owner mux, so every term into `z_din` is a register. The one state where this differs from
  the old mux (an EGC strobe after the owner has left the EGC) is unreachable under the bus
  handshake: z486 holds its request through the ready edge and the throttle bridge's hold is
  registered (`tools/check_arb_resp_inv.py`; `tools/equiv/arb_resp_route.sv`;
  `tb_pc9821_egc_resp_owner`).
- **C5-head, C5-free, C5-A.** The PEGC store buffer registers the facts about each held pair
  (e, e+1) when e+1 is allocated (a held entry's address never changes); writes the allocation slot
  on every post (nothing reads a free slot); and forms the `count`/`wp` candidates first, with the
  combine decision selecting last (`tools/check_storebuf_head_inv.py`, `tools/check_seq_equiv.py`).
- **The I/O FSM lane select.** `pc9821_iobus`'s device-bus lane is `first_lane(pending_be)` in every
  state: S_BYTE enters S_DEVWAIT without clearing its lane's enable, so the held `dev_lane` always
  equalled it (`tools/check_iobus_lane_inv.py`).
- **VID-1, the EGC memory gate.** `mode2_egc && grcg mode[7]` is a register
  (`pc9821_egc_mem_gate`) loaded from both sources' next state, so its value is bit-identical every
  cycle and the only `u_crtc`-launched GVRAM cone is cut (`tools/check_gdc_egc_gate_inv.py`).
- **V1, FD.** The CRTC registers its SYNC-block roots on the frame-boundary edge and every other
  compare operand from them one clk_sys behind (harmless at the one dot it lags,
  `tools/equiv/crtc_geom_lag.sv`); the FDD media latches `raw_off` at the request accept
  (`tools/equiv/fdd_raw_off.sv`).
- **S2.** The SDRAM controller forms the next-row field and the gather session's slot maps one
  cycle after the accept, from the accept's own latches; no reader can run in that cycle, and the
  RTL asserts both facts in simulation against the accept-time form.
- **The download gate.** `cpu_run` is a register of `pc9821_rom_loader` (`rom_ready &&
  !load_error`, written from the two flags' next state), and `loader_owns` is
  `load_valid || !rom_ready`; neither reads the live `ioctl_download` any more. The one cycle that
  changes: a reload started while the guest runs stops the machine one clk_sys after
  `ioctl_download` rises instead of in that cycle, which is the machine's answer to a download the
  host started one clk_sys later (the start is the HPS's, asynchronous to the guest). The first
  load, the end edge (`cpu_run` rises in the second cycle after the download falls), an OSD reset
  and `load_error` are cycle-identical (`tools/check_cpu_run_inv.py`;
  `tb_pc9821_memory_subsystem`, `tb_pc9821_rom_loader`).

## The `pll_hdmi` margin

The framework's HDMI scaler and OSD (`sys/`, frozen) run on `pll_hdmi` and sit pinned to one
quadrant beside the HPS, so the core's placement pressure shows up in their slack. Its seed-to-seed
spread is about 0.1-0.4 ns. A badly negative draw can wedge the scaler when the core loads, and the
card then cannot take a screenshot of any core until it reboots.

- The deploy floor is `other_setup >= -0.35 ns` (the worst framework clock in `metrics.json`,
  `pll_hdmi` in every fit of this tree); the target is `>= 0` with TNS 0. Every hardware-verified
  good placement reaches -0.33 ns, and every known wedge is far below the floor.
- `pll_hdmi` TNS below -5 ns is a caution, not a proven mechanism.
- The wedge is also a per-bitstream fault that no STA corner predicts, so a deployed RBF also passes
  the load screen (`tools/mister_load_loop.py`, 10 loads per card on two cards).
- A change is judged on six seeds per side: mean and worst `other_setup` within 0.2 ns of the
  baseline, and the count of seeds above the floor not lower.

The tools that enforce this (`tools/seed_sweep.py --min-other-setup`, `tools/remote_fit.py`,
`tools/fit_matrix.py report --baseline`, `tools/mister_load.sh`) are described in
[`fitting.md`](fitting.md), "Timing and area facts".

# Building the core

How the Quartus build runs, what each build profile carries, and how the SDRAM pins, the
analog video path, the CD-ROM and the generated PLL/SDC are put together.
[`AGENTS.md`](../AGENTS.md) has the one command a change needs; fitting, seed sweeps and the
timing and area rules are in [`fitting.md`](fitting.md), the SDRAM modules the controller
supports in [`sdram.md`](sdram.md).

## The Quartus build (podman or docker)

Quartus runs in a container: `CONTAINER_RUNTIME` selects it (default `podman`; `docker` works).
Any RTL change needs a Quartus compile - Verilator-clean is not Quartus-clean (for example,
non-ASCII in a comment fails Analysis & Synthesis). The analysis-and-synthesis check command is in
[`AGENTS.md`](../AGENTS.md#building).

Zero `^Error` lines before the timeout means analysis, synthesis and map passed; the 300 s cap
does not reach the fitter. **It does not mean the design fits.** LABs are the binding resource
(4,191 on the device) and the fitter states its own requirement:

```
Error (170012): Fitter requires 4408 LABs to implement the design, but the device contains only 4191 LABs
```

so a change is judged only from a real fit: read `output_files/z486_mister.fit.summary`
(`Total LABs`, `Logic utilization (in ALMs)`) and the fitter's `170012`/`171003` lines.

- **Full fits:** `python3 tools/build.py --detach --log <log>` and read the verdict with
  `python3 tools/wait_build.py` (exit 0/1) or `.build/quartus.status.json`'s `state`/`exit`. A
  detached build survives a killed launcher. Never poll a job with `pgrep -f <its command>`: the
  pattern matches the polling shell itself.
- Each fit writes `output_files/fit-source.sha256`; two fits whose files differ only in the files
  you changed are a one-variable A/B, and you can say so.
- After an interrupted build, remove leftover containers (`podman rm -f ...`) and
  `rm -rf .build/quartus` before a diagnostic build; stale scratch masks errors. Never redirect
  build output to `/dev/null`: the verdict line and the explaining error are in it.
- **Timing queries must load the SDC:** `create_timing_netlist; read_sdc; update_timing_netlist`
  (see `z486_mister.clk_sys_top_setup.tcl`). A raw `quartus_sta -t` session auto-derives clocks and
  reports phantom cross-domain paths. STA names the PLL outputs `general[0]` (clk_sys) and
  `general[1]` (the SDRAM pin clock, which has no register endpoints); `z486_mister.sdc` names
  them.
- `tools/quartus_gui.sh` opens the GUI in the same container.

## Build profiles

`build_profile.py` (repo root) applies a configuration: clk_sys, the SDRAM pin-clock phase,
`TRACE_EN`, `PERF_LOG_EN`, `IO_LATENCY_PROFILE`, `MPU_EN`, `SDRAM_DQ_DDIO`, `SDRAM_OUT_DDIO`, the CD-ROM fields, the framework
feature `alsa_en` and `MISTER_DISABLE_YC`, and the fit technique (`AREA` in every preset: the
design is LAB-bound and `AREA` frees LABs, `docs/trade-candidates.md` T40; `--fit-technique SPEED`
for an A/B). The SDRAM controller runs on
clk_sys in every build: one core clock, no SDRAM clock-domain crossing.

| profile | clk_sys = SDRAM | note |
|---|---|---|
| `base` | 90 MHz | the default and shipping build (90 rather than 95 MHz for margin across boards), hardware-verified; carries the MPU-PC98II MIDI card and the framework's HPS audio (ALSA) |
| `trace` | 90 MHz | the debug build: base + instruction-trace ring + perf telemetry, without the MIDI card and ALSA |
| `iofaithful` | 90 MHz | base + the machine-timed I/O class table |
| `mediumoc` | 100 MHz | overclock; builds the SDRAM at CL3 (CL2 runs only below 100 MHz, `docs/trade-candidates.md` T58); CL3 hardware-confirmed (4 seeds at -6.6 to -7.5 ns: the best seed passed the hardware regression on each of two MiSTers, while a 110 MHz build of the same source failed on both, so pick a sweep's best seed and hardware-test it); SDRAM_CLK through a clk_sys output DDIO (derived, see below) |
| `heavyoc` | 120 MHz | overclock at the board SDRAM's ~120 MHz limit; SDRAM_CLK through a clk_sys output DDIO |

**SDRAM_CLK structure is derived from clk_sys, not chosen**, one decision
(`profile_gen.sdram_clk_ddio`) written into `z486_mister.sv` and the SDC by `build_profile.py`.
Below 100 MHz SDRAM_CLK is PLL output 1, phase-shifted (`derive_sdram_phase`), with CL2 and an SDC
tAC of 6.0 ns. At and above 100 MHz (the CL3 builds) it leaves through an output DDIO cell clocked
by clk_sys (inverted, T/2), and the SDC forwards it from the clk_sys pin with `-invert` and the CL3
tAC of 5.4 ns. The DDIO form cannot hold below ~100 MHz (its hold extrapolates to -1.6 ns at
80 MHz).

Any field can be overridden or a custom configuration defined:
`python3 build_profile.py base --trace`, `python3 build_profile.py --custom --clk-sys-mhz 75`,
`--profile-file F` (JSON or TOML). `--print-config` prints the resolved configuration without
applying it; `--check` verifies the top level, the qsf record, and the generated PLL and SDC
agree; `--selftest` plants disagreements and must catch each. `tools/build.py` and
`tools/seed_sweep.py` accept the same `--profile <preset>` plus overrides.

## SDRAM I/O registers

**No SDRAM I/O register is a fabric register the fitter packs (and duplicates) into a pin.** The
read capture (`sdram_dq_ddio`, on in every preset; `--no-sdram-dq-ddio` builds the old packed
register for an A/B): `sdram.v`'s `dq_r` is the rising-edge half of `altddio_in`, the same cell and
cycle the qsf's `FAST_INPUT_REGISTER` used to pack a fabric register into. The outputs
(`sdram_out_ddio`, on in every preset; `--no-sdram-out-ddio` for the A/B): command, address, BA,
DQM and DQ data leave from `altddio_out` cells with both halves equal (a single-rate rising-edge
register), the DQ output enable from one `dont_merge` FABRIC register per pin, kept out of the I/O
cell (`build_profile.py` writes `FAST_OUTPUT_ENABLE_REGISTER OFF` for `SDRAM_DQ[*]` as the qsf's last
such line; the SDC's output delays time its path). Neither I/O-cell OE form works: a build whose DQ
OE came from a `cyclonev_ddio_oe` atom simulated and timed clean and was BLACK on hardware, and the
per-pin OE packed into the cells (hardware-good) still hit the DTM
crash on one seed of 12. `--check` forbids the atom and holds the qsf line, and
`tools/check_sdram_pins.py`, run by every `tools/build.py` fit, fails a fit whose SDRAM pins are not
driven by the intended registers in the intended place,
each loaded with the FSM's NEXT value (`sdram.v` computes its state as `*_n` for that),
so every pin changes on the same clk edge as before; the qsf's `FAST_OUTPUT_REGISTER` used to
pack the fabric registers there, and `FAST_OUTPUT_ENABLE_REGISTER` duplicated the one `dq_oen` into
all 16 pins. Both packed forms crash
Quartus 17.0.2's physical synthesis on some netlists (`Internal Error: Sub-system: DTM ...
dtm_node.cpp, Line: 772`, in `visit_atom_stratixv_style_io_ibuf` and its output twin
`visit_atom_stratixv_style_io_obuf`); which seeds crash moves with unrelated netlist changes, and
no single register group is "the" atom (on one crashing database, un-packing only the four
command registers or only the 27 HDMI ones cured it, the 16 DQ or 16 OE ones did not). The SDC is rendered from
the same fields: the capture collection (`profile_gen.DQ_CAPTURE_REGS`) and, for the outputs, a cut
of the output DDIO's falling-edge clock-mux path, which switches between two equal values
(`profile_gen.render_out_cut`); `--check` holds both parameters' paths from the top level to the
cells. The framework's HDMI output registers stay packed (`sys/` is frozen).

## Analog video

**The analog video converter** is a compile-time knob (`vga_dbl_en`, on in every preset) selected
at run time by the OSD's `Analog video` field: `pc9821_line_doubler` sends each GDC line twice at
49.7 kHz for VGA monitors (`forced_scandoubler=1` turns it on from Native). It runs on the video
PLL's clock (`CLK_VIDEO`, `rtl/vpll`, generated like the main PLL from
`tools/profile/vpll_template.v`), an exact multiple of the dot rate, so every analog pixel and sync
period is a constant number of clocks (`tb_pc9821_video_clk`). The video PLL is fractional-N and
reconfigurable in every build: `pc9821_vpll_ctl` moves it to twice the 31 kHz dot clock whenever
the guest sets port `0x09A8` bit 0 (`tb_pc9821_crt31k_video`); the settings live in
`src/pc9821/video/pc9821_vclk_pkg.sv`, and `tools/profile_gen.py` VCLK_SETTINGS must agree
(`build_profile.py --check`). A 31 kHz raster always leaves undoubled. There is no 15 kHz TV or
composite/S-Video output.

**Analog output timing:** the analog path keeps exactly the GDC raster's active resolution
(640x400) and refresh rate (56.42 Hz, frame-locked); porches, sync widths, line total, H rate and
doubling may change for monitor compatibility, with the most compatible choice as the default.
Doubled output uses a short (3-line) vertical sync, which some CRTs need to keep lock. An analog
change is verified by eye on a real monitor; an HDMI capture cannot show analog jitter.

## CD-ROM

**Every preset builds the ATAPI CD-ROM drive with CD-DA** (OSD `Mount CD-ROM`); `--no-cdrom` and
`--no-cdrom-audio` opt out. Turning the CD off is a deliberate decision, never a fallback for a
design that stops fitting. `pc9821_system`'s `CDROM_EN` parameter defaults to 0 for the unit
benches; the boot golden instantiates the CD build. The drive, the IDE layout and CD-DA are in
[`docs/pc9821-port-status.md`](pc9821-port-status.md).

## The generated PLL and SDC

**The PLL and the SDC are GENERATED** per configuration from `tools/profile/` (the PLL by
`qmegawiz` inside the Quartus container, cached under `.build/pll-cache/`; the SDRAM pin-clock
phase derived by `tools/profile_gen.py` from the SDC's own I/O model). Never edit `rtl/pll*`,
`z486_mister.sdc` or the qsf's managed block by hand: change a template or a field, and re-fit.

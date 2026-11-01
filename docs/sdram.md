# Supported SDRAM modules and their timing

The controller and the SDC I/O model are sized for a **supported set** of modules, not for every
chip ever fitted to a MiSTer SDRAM board: x16 parts, one chip per chip select, rated for CL2 at a
10 ns clock period, with tRCD/tRP <= 21 ns, tRC <= 68 ns and tWR <= 15 ns. That covers the Alliance
AS4C32M16SB (-6 and -7 grades) on the single-chip 32/64 MB boards and the dual-chip 128 MB boards
(two chips on complementary chip selects). A part outside the set (x8 pairs such as the
AS4C64M8SD, -8 grades, low-power parts rated below the clock) is excluded when supporting it would
cost guest-visible cycles. The README states the set and the exclusions in user terms, without
naming modules or chip markings; the hardware margin behind it, at least
2.78 ns on each side of the shipped phase on both test cards at 90 MHz, is in
[`sdram-margin.md`](sdram-margin.md#7-results).

- Every SDRAM timing constant meets the slowest part of the supported set at every preset's clock,
  in nanoseconds converted to cycles (`ceil(t / tCK)`), never one part's figure. tRCD and tRP are
  21 ns (the AS4C32M16SB-7's figure): 2 cycles at 90 MHz, 3 at 100 MHz. tRAS (42 ns) is met by
  every access's auto-precharge, which the datasheet does not lock out (`sdram.v`'s tRAS guards);
  the SDRAM benches check every Table 16 limit of the -7 (and -6) column from nanoseconds at
  their own clock.
- Margin is measured on hardware, not taken from the model: the SDC's I/O model gives the
  SDRAM_CLK phase, but the working phase window of each test card (a phase sweep under a RAM stress
  test, on each board type) decides whether a clock and phase ship. The target is at least 1 ns of
  window on each side of the shipped phase on every test card.
- The fitter places the DQ input delay chains differently per seed, so a measured window belongs
  to one bitstream: the shipped seed is the one that was hardware-tested.

How the window is measured - the per-corner SDRAM I/O record and `--min-sdram-io` gate on every
fit, the test-only run-time SDRAM_CLK phase instrument, the DOS sweep program, the run procedure
and the pass criteria for this set - is in [`sdram-margin.md`](sdram-margin.md).

How the SDRAM pins are clocked and registered per build is in [`build.md`](build.md).

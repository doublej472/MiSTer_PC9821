# Supported SDRAM modules, their timing and the DQM wiring

The controller and the SDC I/O model are sized for a **supported set** of modules, not for every
chip ever fitted to a MiSTer SDRAM board: x16 parts, one chip per chip select, rated for CL2 at a
10 ns clock period, with tRCD/tRP <= 21 ns, tRC <= 68 ns and tWR <= 15 ns. That covers the Alliance
AS4C32M16SB (-6 and -7 grades) on the single-chip 32/64 MB boards and the dual-chip 128 MB boards
(two chips on complementary chip selects). A part outside the set (x8 pairs such as the
AS4C64M8SD, -8 grades, low-power parts rated below the clock) is excluded when supporting it would
cost guest-visible cycles. README and [`user/setup.md`](user/setup.md#what-you-need) state the set and the
exclusions in user terms, without naming modules or chip markings; the hardware margin behind it, at least
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

## DQM wiring

How the byte mask reaches the SDRAM on the MiSTer module, and the per-command contract the
controller (`src/memory/sdram.v`) honours. The PEGC packed-store path relies on it for masked byte
writes (trade candidate T23).

### The module

The MiSTer 128 MB SDRAM add-on (the "XSDS" board and compatible boards) is **2 x AS4C32M16SB**,
two x16 chips of 64 MB each:

| property | value |
|---|---|
| per chip | 4 banks x 8192 rows x 1024 columns x 16 bits |
| bus width | 16 bits (DQ[15:0]) |
| CKE | tied to VCC on the board (no power-down or self-refresh) |
| CS | one connector line `CS1`; `CS2 = ~CS1` through an on-board inverter |

Sources: the official schematic (`MiSTer-devel/Hardware_MiSTer`, `releases/sdram_xsds_3.0.pdf`),
whose net labels connect both chips' `DQML`/`DQMH` to `A11`/`A12` at the connector;
`birdybro/SDRAMsim_MiSTer`'s `CONTROLLER_GUIDE.md` and its model
`xsds_128mbyte_sdram_model.sv` (`wire chip_ldqm = Addr[11]; wire chip_udqm = Addr[12];`); and
JTFRAME's `jtframe_sdram_bank_core.v`, whose `ADQM` mode is the same scheme
(`assign {sdram_dqmh, sdram_dqml} = ADQM ? sdram_a[12:11] : dqm;`, selected under `MISTER`).

### DQM is carried on A[11]/A[12]

There is no separate DQM pin: a controller masks bytes by putting the mask on `A[12:11]` during the
command. `sdram.v` drives `SDRAM_DQML`/`DQMH` from `dqm_a`, a register twin of `a[12:11]` (a
simulation assertion holds the two equal every cycle).

### The per-command A[12:11] contract

| command | A[12:11] carries | notes |
|---|---|---|
| ACT | row bits A12/A11 | DQM is don't-care (no data transfer) |
| READ | `00` | DQM has a 2-clock output-mask latency; this core never masks reads |
| WRITE | byte mask `{UDQM, LDQM}` | active high (1 = mask); captured with the write data |
| PRE | don't-care | A10 = all banks |
| MRS | `00` | per the datasheet |

### The controller as built

The top level builds the controller with `ADQM = 1` (`z486_mister.sv`, `.ADQM(1'b1)`): a partial
store is ONE masked WRITE, and the same-row gather sessions carry each slot's mask the same way.
With `ADQM = 0` (the parameter's default, for a module without the tie) a partial write takes
`RMW_READ -> RMW_ACT -> WRITE`, a read and a re-activated merge write. The top level builds
`ADQM = 1` unconditionally, so every module the core runs on must carry the standard tie.

### Verification

- `tests/pc9821/sdram_chip_model.sv` ties `LDQM = A[11]`, `UDQM = A[12]` and applies the mask on
  the WRITE command edge, so a masked-write bench is not vacuous.
- `tb_pc9821_sdram_adqm`: a masked WRITE changes exactly the enabled bytes for every byte-enable
  pattern, and the mask on `A[12:11]` does not alias a row.

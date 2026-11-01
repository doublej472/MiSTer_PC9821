# Dhrystone 2.1 numbers - the z486 CPU

The Dhrystone 2.1 port lives in `src/z486/tests/dhrystone/`. Its whole-run result is a gate
(`AGENTS.md`): a CPU change may move it, but must report the new value with per-change
attribution.

## The contract

```sh
make -C src/z486/tests dhrystone
```

At `--iters 200` (the gate's setting) the whole run - reset, init, the Dhrystone loop and
validation - is **242611 cycles / 121837 instructions / CPI 1.991**, exactly. The run is
deterministic. The direct form, in `src/z486/tests/dhrystone/`:

```sh
python3 run_dhrystone.py --iters 200  --cycles 2000000
python3 run_dhrystone.py --iters 500  --cycles 2000000    # a second point, for the loop slope
```

**The core's configuration.** `make -C src/z486/tests dhrystone-pc98` runs the same binary
on z486 built with the PC-98 memory-map template (`Z486_PC98_MAP_PARAMS`, the runtime RAM bound
at 32 MiB), which is what the core instantiates: **242611 cycles**, equal to the plain CPU (stores
to the template's RAM pages post through the direct store port, as without windows).

The reference anchor is **~680 Dhrystone/s/MHz on a real 486** (~0.387 DMIPS/MHz, with
1757 Dhrystone/s = 1 DMIPS). The loop is 568 instructions per iteration; the per-iteration
cycle slope of the current core has not been re-fitted with the two-point run above (an earlier,
slower core measured 1464 cycles/iteration = 683 Dhrystone/s/MHz, about the real-486 anchor).

## What the harness measures

The Verilator harness runs the **bare `z486` DUT on a fixed 10 ns testbench clock** with a
behavioural SDRAM-like memory model (`sdram_first_latency=5`, `sdram_gap_cycles=1`,
`sdram_write_busy=3`; `--mem-model simple` is faster). It does not read `z486_mister.sv`, the
PLL, the qsf or any build-profile setting, so **the result is profile-independent** (checked:
every profile produces a byte-identical harness binary and result). It is cycles and
instructions per Dhrystone on the simulated core - not a fitted or board-throughput number.
A Dhrystone/s figure for a profile is a linear projection (`clk_MHz x Dhrystone/s/MHz`) and
ignores the board's memory latency in core cycles, timing margin and I/O.

## The harness memory is faster than the board's

`tb_dhrystone`'s memory model (`src/z486/tests/dhrystone/tb_dhrystone.sv`,
`int sdram_first_latency = 5;`, `int sdram_write_busy = 3;`) returns a read's first beat 5 cycles
after the request and is busy for 3 cycles after a store. The board's SDRAM controller
(`src/memory/sdram.v` at 90 MHz, ADQM, behind `sdram_sync_bridge`) is slower on reads: a read's
first beat arrives about 8-9 cycles after the accept. Stores used to be slower too: a single-dword
store occupied it for 8 cycles (ACT, tRCD, two 16-bit halves, the write recovery), so 94 % of the
run's stores were accepted exactly 8 cycles apart and the real-controller run took 289,477 cycles
(+19 %; the harness reproduced it within 1 % with `+sdram_first_latency=8 +sdram_write_busy=6`,
287,101). The write exit trim (8 -> 7 cycles per store) brings it to 271,807. A same-row write
chain (a store presented in the row its predecessor left open is written without an ACT or a
precharge, 4 cycles apart; item 143) would bring it to 240,330; it is not in this tree.

## The second line: Dhrystone on the real controller

```sh
python3 tools/dhrystone_real.py [--expect N]
```

builds the fork's own `tb_dhrystone.sv`, patched at build time so every non-I/O access is timed
by the core's SDRAM backend (`split_sdram_backend` over `sdram_sync_bridge` over `sdram.v`, 90 MHz,
CL2, ADQM=1, FAST_GRADE=0) against `tests/pc9821/sdram_chip_model.sv` with its protocol, -7 AC and
tREFI checks on, and runs the gate's binary (`dhrystone-pc98`'s hex). The figure is counted from
the first accepted access, so the controller's 200 us power-up wait is not in it: **271807
cycles** (147 line reads, 27441 stores), exactly. It is a gate, pinned in the tool (`PINNED`;
`--expect N` checks another figure, `--expect 0` only reports): a controller change must report
the new value with attribution, as a CPU change does for the first line.

| controller | real-controller Dhrystone |
|---|---|
| before the 21 ns tRCD/tRP, the tRAS guards and the second chip's init (cycle-identical at 90 MHz) | 289,477 |
| + write exit trim (this tree, the pin) | 271,807 |
| + same-row write chain (item 143, pending: not merged) | 240,330 |

So **242611 is a contract for the CPU plus an idealised memory**, not the board's speed: it
isolates the CPU from the memory system and keeps every earlier CPU change comparable. A memory
or controller change does not move it, and a CPU change's effect on the board can differ from
its effect on this number.

## The last move

242611 / 121837 / 1.991 (from 246199 / 2.021) came from three upstream CPU changes taken by the
fork: a 32-bit DSP multiply in two cycles (-400), IMUL r,r/m(,imm) retiring straight from the
DSP product (-1000), and microcode reads probing the L1 from any microcode step (-2188). The
instruction count has not changed since the port was added.

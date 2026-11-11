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

## On the card, against a real Xe10

`tools/hwprobe/speed` (`SPEED`) runs the gate's own Dhrystone objects (-O2, 32-bit protected mode
from conventional memory, timed on the ARTIC) and a set of timing loops, the same binary on the
machine and on the core; `speed_decode.py A B` gives the ratios. The real Xe10
(`docs/probes/KIT2-XE10-SPEED.TXT`) against the core at OSD CPU Speed Full, 90 MHz `base`
(`docs/probes/core/KIT2-CORE-SPEED.TXT`):

| row | Xe10 | core | core / Xe10 |
|---|---|---|---|
| Dhrystone 2.1, 100000 iterations | 51,149 /s (29.1 DMIPS) | 69,227 /s (39.4 DMIPS) | 1.35x faster |
| `dec ecx / jnz` loop | 50.0 ns | 55.6 ns | 0.90x (5 clocks at 90 MHz on the core; 50.0 ns is 5 clocks at 100 MHz) |
| 4 register ALU ops (net) | 80.0 ns | 100.0 ns | 0.80x |
| `in al,dx` at 0x02 / 0xA0 (net) | 802 / 651 ns | 133 / 144 ns | 6.0x / 4.5x faster (item 82) |
| `rep movsd` / `rep stosd`, RAM | 15.2 / 41.1 MB/s | 30.6 / 50.2 MB/s | 2.0x / 1.2x faster |
| `rep lodsb`, RAM | 16.2 MB/s | 11.5 MB/s | 0.71x |
| `rep stos` to the blue plane, byte / word / dword | 7.05 / 14.1 / 14.4 MB/s | 6.9 / 13.9 / 27.7 MB/s | equal, equal, 1.9x faster |
| `rep stosw` to text VRAM | 14.1 MB/s | 16.4 MB/s | 1.16x faster |

So the CPU rows are within 10-20 % (the machine runs a higher clock), while memory-bound and
I/O-bound code runs faster on the core (the dword graphics store is one access on the core, two
16-bit ones on the machine); only byte string loads from RAM are slower. The machine's backup
battery was dead for that run (the calendar is not used by `SPEED`).

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

The re-vendor to the fork's `d5d0974` (the todo item 160 outlier cuts: a misaligned direct
load inside one line, CLI/STI and LOOP-not-taken without the refetch, the real-mode
far-transfer tail, real-mode interrupt delivery) leaves it at exactly 242611 / 121837 / 1.991,
after each of its four commits: the gcc Dhrystone loop runs none of those paths.
The re-vendor to `9a40dcd` (IDIV r8 missed overflow, #DB pushing RF=0, #SS(new SS) for a
privilege switch's new stack) leaves it at exactly 242611 / 121837 / 1.991, and the real-
controller line at 271807: the loop runs no IDIV r8, debug exception or privilege switch.
The re-vendor to `03cbac7` (IDIV r16/r32 missed overflow, test-only corrections) leaves both
lines unchanged too (242611 / 121837 / 1.991, 271807): no divide in the loop is out of range,
the only case the change touches.
The re-vendor to `8b8fceb` (DR6 bit 12, REP CMPS/SCAS fault flags, the 2-byte error-code
write, DR6.Bn for enabled breakpoints only) leaves both lines unchanged (242611 / 121837 /
1.991, 271807): the loop takes no fault, debug exception or MOV DR6.
The re-vendor to `bbe0e95` (testbench only: tb_dhrystone, tb_z486 and tb_test386 preload the
GPRs by forcing `data_unit`'s registers, the bench rule in `docs/testing.md`) leaves both lines
unchanged (242611 / 121837 / 1.991, 271807) under Verilator 5.052, and restores them under 5.054,
where the old preload missed ESP and the run timed out at the first CALL.
The re-vendor to `d5cf5bd` (IDTR and GDTR reset to limit FFFFh, `docs/probes/KIT1-XE10-CFG0.TXT:78`)
leaves both lines unchanged (242611 / 121837 / 1.991, 271807): the bench forces the IDTR and GDTR
before the loop, so it cannot see a reset value.

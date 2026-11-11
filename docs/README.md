# Documentation index

The repository's [`README.md`](../README.md) is the short user introduction. Everything else is
here, in three groups:

- **`docs/user/`**: guides for people running the core. Nothing in them needs the source tree
  except the image and pack tools, which run on a computer.
- **`docs/*.md`** (this directory): contributor and reference documents: the rules, the build,
  testing, timing, and how the core models the machine. [`AGENTS.md`](../AGENTS.md) is their
  entry point.
- **`docs/probes/`**: raw captures from a real PC-9821Xe10, the evidence the benches assert
  ([`probes/README.md`](probes/README.md) lists them). Captures are never edited.

## User guides

| doc | what |
|---|---|
| [`user/setup.md`](user/setup.md) | what you need, building the BIOS pack from your own dumps, files on the SD card, first start |
| [`user/hardware.md`](user/hardware.md) | the emulated hardware: machine and CPU, graphics, sound, MIDI (MidiLink), storage, input, video output, LEDs |
| [`user/options.md`](user/options.md) | every OSD option with its values and defaults, analog video, UART mode, saving settings |
| [`user/images.md`](user/images.md) | disk and CD image formats, the converters, making a new hard disk, a second hard disk |
| [`user/input.md`](user/input.md) | the keyboard layouts and key table (generated), mouse, joypad |
| [`user/dos-windows.md`](user/dos-windows.md) | setting up DOS on a new hard disk, `CONFIG.SYS`, drivers, playing a CD title, Windows 95 |
| [`user/troubleshooting.md`](user/troubleshooting.md) | common problems by symptom, and the known issues |
| [`user/compatibility.md`](user/compatibility.md) | every title tested on the core and what it needs |

## Contributor guides

| doc | what |
|---|---|
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | the entry point: the one non-negotiable design rule, then AGENTS.md |
| [`single-cycle-event-discipline.md`](single-cycle-event-discipline.md) | the rule for every pulse, strobe and one-shot event (R1-R8, audit checklist) |
| [`policies.md`](policies.md) | every binding rule in full, the performance/latency/area policy, documentation and wording, fixed design decisions |
| [`build.md`](build.md) | the Quartus build, build profiles, SDRAM I/O registers, analog video, CD-ROM, the generated PLL and SDC |
| [`fitting.md`](fitting.md) | seed sweeps, remote fitting, timing and area facts, the `pll_hdmi` deploy gate and load screen |
| [`testing.md`](testing.md) | mutation testing, what each static check proves, hand-run proofs, the userdisk instrument, real-controller measurements |
| [`mister-testing.md`](mister-testing.md) | testing on a real MiSTer: deploying, screenshots, input, the debug UART, the regression runner, the rules |
| [`debug-instruments.md`](debug-instruments.md) | the compile-time debug-UART instruments (`--dbg-*`) |
| [`lanes.md`](lanes.md) | working habits for parallel lanes (worktrees) |
| [`../tools/hwprobe/README.md`](../tools/hwprobe/README.md) | the real-hardware probes and how to run them |

## Reference and measurements

| doc | what |
|---|---|
| [`pc9821-port-status.md`](pc9821-port-status.md) | what the core implements, against which reference, and what it does not do |
| [`bios-setup.md`](bios-setup.md) | the Xe10 BIOS SETUP menu decoded: where each item is stored and what the core does with it |
| [`clock-domains.md`](clock-domains.md) | every clock domain and crossing, and the constraint guarding each |
| [`timing.md`](timing.md) | where the clk_sys critical paths are, the landed zero-cycle cuts, the `pll_hdmi` margin |
| [`trade-candidates.md`](trade-candidates.md) | area wins that cost latency or performance, priced for the maintainer's decision |
| [`sdram.md`](sdram.md) | the supported SDRAM modules, their timing, and the DQM-on-address wiring |
| [`sdram-margin.md`](sdram-margin.md) | the SDRAM I/O corner gate, the run-time phase instrument, the shmoo and its results |
| [`dhrystone-numbers.md`](dhrystone-numbers.md) | the CPU's Dhrystone gate, on the card against a real Xe10, and on the real controller |
| [`z486-local-patch.md`](z486-local-patch.md) | the vendored z486 CPU: the fork, the fork-first rule, re-vendoring and the diff map |

The open-work list is [`../TODO.md`](../TODO.md) (one file per theme under [`../todo/`](../todo/)).

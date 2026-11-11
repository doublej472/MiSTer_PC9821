# PC-9821 z486 port status

What this core implements, what is measured against the real machine, what it deliberately
does not do, and what is open. The live open-work list is [`TODO.md`](../TODO.md); this page
describes the core as it stands.

## Baseline

| | |
|---|---|
| Upstream base | `z486_MiSTer` (nand2mario) |
| CPU | z486, vendored in-tree as a plain copy of a curated fork ([`z486-local-patch.md`](z486-local-patch.md)) |
| FPU | x87 disabled (`ENABLE_X87 = 0`) |
| Platform | `src/pc9821/core/pc9821_system.sv`: z486, native PC-9821 memory and devices, explicit tie-offs for everything else |
| Clock | one core clock: clk_sys = the SDRAM controller's clock, 90 MHz in the shipping build (`base`) |

`src/pc9821/` is organised by feature: `core/`, `video/`, `audio/`, `interrupts/`, `timers/`,
`storage/`, `input/`, `rtc/`, `common/`.

## Running state

The core boots the authentic PC-9821Xe10 firmware (the user's own dumps, packed by
`tools/build_pack.py`; the Xe set does not boot yet) through the ITF and the BIOS POST to DOS, and runs Touhou 1-5, DOOM
(packed 256-colour mode), and a range of other PC-98 games on a real MiSTer at the shipping
90 MHz build. Sprites, the GRCG/EGC drawing engines and the analogue palette display correctly
on the real card.

### Simulation tiers

- **Unit benches** (`python3 tools/bench.py --all`): every bench's expected values come from
  a reference (a real-machine capture in `docs/probes/`, the firmware's own code, NP2kai,
  qemu-pc98, MAME), never from this RTL.
- **The z486 suite** (`bash tests/pc9821/run_z486_suite.sh`) and Dhrystone
  ([`dhrystone-numbers.md`](dhrystone-numbers.md)).
- **The diagnostic boot** (`bash tests/pc9821/run_boot.sh`): the in-tree diagnostic pack
  (`firmware/diagnostic/`, original code, no NEC bytes) boots through the real ioctl loader
  and asserts POST `10/20/30/5A`, the low-RAM signature `5A3C0BAD`, the TRAM banner, the
  memory switches, the VSYNC interrupt self-test and a non-black picture. Its cycle count
  (`CYCLES used=...`) is a whole-platform canary.
- **The integrated disk tier** (`PC98_PACK=<pack> bash tests/pc9821/run_userdisk.sh <image>`)
  runs the authentic pack against a real disk image and asserts the guest reaches the IPL at
  `1FC0:0000` with the boot sectors byte-exact. With `+PAST_IPL` and a writable overlay it
  can run on to DOS (slowly: ~210 k cycles/s). It skips loudly when its inputs are unset.

**The ITF's configuration record.** The core seeds the ITF's battery-backed configuration
record in the CG store, so a cold core passes the marker/sum check the machine passes by
holding the record in battery-backed memory. Without the seed the ITF installs the record
itself and prints `SET THE SOFTWARE DIP-SWITCH` until the next power-up.

### I/O access timing

The machine's I/O access time is not uniform, and `pc9821_iobus.sv`'s `io_access_cycles`
charges each access a per-port class from one of two tables, chosen at run time by the OSD's
**I/O timing** field (`status[79]`, `io_timing_xe10`; an owner exception to the compile-time-knob
rule, todo item 82):

- **Fast** (the default): every class is the short FSM floor except the two the
  firmware's own timing tests need - a port `0x005F` **write** (the I/O-wait port the
  firmware's delay loops are calibrated on), which is POSTED as on the machine: the CPU goes
  on at once and the next I/O access waits until **1744 ns** after it (the XE10T capture's
  write period, `docs/probes/XE10T-XE10.TXT` /IO W8_005F), and an 8253 **write** at one
  2.4576 MHz PIT tick (the ITF's port/counter walk fails if an access is shorter). A `0x005F`
  read is the default class.
- **Xe10**: the machine's measured per-class times, the `net_ns` of the Xe10's XE10T /IO rows
  (`docs/probes/XE10T-XE10.TXT`: default 792 ns R / 823 ns W, text GDC 414, graphics GDC 639,
  EGC 350 R, the fast write class 318 on 0x6A/0xA6/0x7C/0x7E/0x64/0xA4 and the EGC file, the
  EGC file's even read 5990, 0x09A0/0x09A8 353, 0x0FAA 255, `0x005F` 792 R / posted W), less the
  core CPU's own 8 clk_sys around an I/O instruction (`docs/probes/core/KIT2-CORE-SPEED.TXT`), so
  the whole `in`/`out` takes the machine's time; a 16-bit access pays one class (R16_005C,
  R16_0188, W16_04A8). Kit 2's SPEED cross-checks it: `in al,dx` 802 ns at 0x02 and 651 ns at
  0xA0 on the machine. The older ioprobe capture (`docs/probes/IO.TXT`) reads the same classes
  3-5 % higher and the EGC file's even read at 8.6-9.4 us; XE10T and SPEED agree, so XE10T is
  the table.

The Xe10 classes are real times, not `clk_sys` counts, so raising the clock does not change a
guest-visible time (`tb_pc9821_sysclk_invariance`); `tb_pc9821_io_latency_profile` pins both
tables and the run-time switch.

## Memory map and firmware pack

`src/pc9821/core/pc9821_memory_map.sv` preserves z486's valid/ready, byte-enable and burst
contracts and translates the PC-98 windows into hidden pack storage:

| CPU window | Pack storage |
|---|---|
| `D8000-D9FFF` when enabled (8 KiB) | `pack_base + 70000-71FFF` (banked by port `0x063C`) |
| `E8000-F7FFF` | `pack_base + 10000-1FFFF` |
| `F8000-FFFFF`, ITF bank | `pack_base + 00000-07FFF` |
| `F8000-FFFFF`, BIOS bank | `pack_base + 20000-27FFF` |
| `FFFF8000-FFFFFFFF` | the same selected 32 KiB bank |

The pack layout is owned by `tools/pack_layout.py`. The pack also carries:

- the **font** (`FONT.ROM`, 282 KiB) at `pack_base + 0x80000`; the JIS kanji classes read it,
  and the ANK class keeps its own block-RAM slice for the scanout;
- the **YM2608 ADPCM-A rhythm image** at offset `0x49000` (8 KiB). It is Yamaha's data, so it
  comes from the user (`--rhythm`, or `OPNA_ADPCM.ROM` beside the other dumps). **A
  zero-filled region is not silence**: an all-zero ADPCM-A nibble is a +2 step per sample, so
  every drum becomes a loud DC-carrying sawtooth. `build_pack.py` warns on it and
  `check_pack.py` fails a pack that lacks an image its dump directory holds.

`pack_base` is module-fixed: it equals the installed SDRAM module's guest-size ceiling, so the
1 MiB pack sits above the largest guest the module can serve, survives an OSD reset, and never
moves when the guest size changes. Directly above it sit the 86-PCM sample buffer, the EMS
page, the BIOS-top shadow and the 512 KiB PEGC extended VRAM (2 MiB in all). GVRAM's 256 KiB
lives in M10K, not SDRAM.

**RAM size.** The OSD field is `RAM Size,16M,32M,64M,96M,1M,2M,4M,8M` - rotated so list
position 0 (what a card with no `.CFG` passes) is 16 MB. `pc9821_osd.sv` maps list position
to size code; `tb_pc9821_osd` walks all eight positions. A 128 MB module offers up to 96 MB
(98 MB used, 30 MB reserved); 64 MB and 32 MB modules offer 32 MB and 16 MB. The size is
re-sampled on every OSD reset. **A config file written before the rotation now selects a
different size**, and a 1 MB guest cannot boot the Xe10 BIOS at all (a blank-screen freeze
that looks like a broken core); `tools/mister_load.sh` warns about such a file. The ITF's
memory test follows the mapped RAM (measured at 1, 8, 16 and 32 MiB).

### ROM banks and the window selectors

The `F8000-FFFFF` window has ten states: the eight 32 KiB ROM banks selected by port `0x043F`
(`0xE0 | bank << 1`, as QEMU's `mem_bankctl_write`) and the two states port `0x043D` selects
(ITF or the top BIOS bank). A cache flush runs only when the state actually changes.

**Machine (`O[31:28]`).** `Machine,Xe10,Xe (not working)` selects the port-`0x00F0` machine-ID strap to match
the loaded pack: `0xA9` for the Xe10 (measured, `docs/probes/PORTS.TXT`) and `0x89` for the Xe
(**derived**: `0xA9` with bit 5 cleared, from the Xe ITF's bit-5 test - a real Xe capture would
confirm it). It is latched at machine reset/reload only (`tb_pc9821_bios_select`). The Xe entry is labelled
"(not working)" rather than hidden, so the field's positions and a saved config keep their meaning.

### Address-map details

| Range | PC-98 | This core |
|---|---|---|
| `A5000-A7FFF` | a hole | a hole (not guest RAM) |
| `C0000-D7FFF` | ROM / expansion area | open bus: reads `0xFF`, stores swallowed (the PC-9801-86 `SOUND.ROM` window at `CC000-CFFFF` is served when the board is present) |
| `DA000-DBFFF` | IDE work RAM, gated by `0x1E8E` | identity RAM; the gate is latched but changes no mapping |
| `FA0000-FFFFFF` | mirror of `A0000-FFFFF` | guest RAM |
| 15-16 MiB | system space | per the `0x043B` strap; its polarity is capture-pending |

### Cache contract

The PC-98 device aperture is `A0000-FFFFF` plus the `FA0000-FFFFFF` mirror and the high
aliases; those accesses are ordered and uncached, and `0x80000-0x9FFFF` (main RAM) stays
cacheable. z486 has no uncached read path for RAM (every read miss allocates), so
correctness rests on: write-through with no write-allocate; a whole-L1 flush (`cache_flush`,
~136 cycles) on every ROM bank/gate change; the DMA's accepted writes driving z486's external
snoop (the 486's EADS#, one invalidate per byte, T24), held for the gated CPU clock by
`pc9821_cpu_bus_bridge` so an OSD CPU Speed below Full cannot drop it, with the DMAC's next
write byte back-pressured while a held snoop waits (the hold is one deep, so a second accepted
write would otherwise replace the waiting address), so a disk buffer stays
coherent; and nothing but the CPU writing a cacheable range. `PROTECT_UMA_ROM` must stay 0 (it
would write-protect graphics plane 3). `tools/check_cpu_domain.py` holds the wiring together:
every z486 pulse input is bridge-driven or a documented tied-off constant, and the snoop hold
gates both the DMA presentation and the accept the DMAC sees.

## Video

### Text and the GDCs

The text GDC renders the text plane (80- and 40-column ANK, JIS kanji pairs, the user CG,
colour/reverse/underline/blink/cursor and the simple-graphics cells of MODE FF1 bit 0) over
the graphics. **The raster is the guest's**: line length, frame length, porches and VSYNC width
come from the GDC's SYNC parameter block (`pc9821_crtc.sv`), not constants; the default BIOS
mode is 848x440 total / 640x400 active at ~56.4 Hz. As on the real Xe10 (`TXTMODE /D`,
`docs/probes/KIT2-XE10-TXTMODE.TXT`), a block narrower than 80 cells shortens the line (AW 64 runs
720 dots, 29.24 kHz; the 24 kHz x floor is the machine's 90, not NP2kai's 100), each line wraps
the text fetch at its own last cell, and the block's C/R byte loads the text pitch until a later
PITCH command overrides it. Text colour is the fixed 8-colour table
(`attr[7:5]`), matching NP2kai and QEMU; attribute bit 0 clears the cell. The `0xA4` display
page flip takes effect at the write (the real-machine probe shows the tear).

The **graphics GDC** implements SCROLL (four partitions), the display START/STOP latch (the
compositor's graphics enable), CSRFORM's line repeat (a 640x200 program is line-doubled into
the 400-line raster), and the **WRITE family** (WDAT/VECTW/CSRW/WRITE, the uPD7220's vector
path, `tb_pc9821_gdc2_write`), and the **figure engine**: FIGS/FIGD dot, line, arc and
rectangle, GCHRD character and area fill (ZOOM, slant), the TEXTW pattern, the four ROPs and the
GRCG/EGC routes, behind the uPD7220's 16-entry command FIFO with the DRAWING status bit, one step
per 14 dot clocks (`tb_pc9821_gdc2_figure_xe10` replays 1,450 Xe10 capture rows,
`tb_pc9821_gdc2_figure`; `tools/hwprobe/gdcfig` draws a comparison picture). The CURD read-back answers
the Xe10's five bytes ({EAD[7:0], EAD[15:8], 0xF0|EAD[17:16], MASK[7:0], MASK[15:8]},
`tb_pc9821_readback_gdc`), and the arc has no capture yet (item 126).

### Character generator

`0xA1`/`0xA3` (code), `0xA5` (row; bit 5 the other half of a kanji cell) and `0xA9` (pattern),
shared with the memory-mapped window at `A4000-A4FFF`. A single-byte code reads the pack's ANK
glyph, a two-byte code whose masked low byte is `0x56`/`0x57` the user CG store, and any other
two-byte code the JIS glyph from `FONT.ROM`. Writes are gated on the unmasked low byte, reads
mask to `0x7F` (NP2kai `io/cgrom.c`, QEMU `pc98-vga.c`).

### Graphics planes, GRCG, EGC, PEGC

`0xA4` selects the displayed page and `0xA6` the CPU's page. The four planes (`A8000` blue,
`B0000` red, `B8000` green, `E0000` intensity) live behind one datapath (`pc9821_gvram`) in
M10K (the `E0000` window is mapped only in the 16-colour mode, `0x6A` FF2 num 0: in the
digital mode it is open bus, as on the machine, `docs/probes/DMAROUTE-XE10.TXT` case P4), and the **GRCG** (`0x7C`/`0x7E`, tile direct-write and RMW) and the **EGC**
(`0x04A0-0x04AF`, gated by the guest's own enable bits) are clients of it. The scanout folds
the four planes through the digital/analogue palette and composites the text plane over them.

The EGC's per-plane work runs **plane-serially**: one 16-bit datapath steps the four planes of a
unit in turn (always four steps, whatever `0x4A0` enables), accumulates the write's four planes
and presents them as the same column requests the parallel engine issued, so every GVRAM word is
written whole in one clk_sys and the compare/pattern results appear only when all four planes are
in. It is bit-identical to the parallel engine (`tb_pc9821_egc_serial_equiv`) and stays under the
Xe10's own EGC cost (`tb_pc9821_egc_xe10_pace` against `docs/probes/EGCP.TXT`, run at 80 and
50 MHz clk_sys: writes cost the CPU nothing, and a same-page read+write row stays under the
machine's 677 ns); trade-candidates T41 carries the area and cycle numbers.

**PEGC 256-colour**: the display half is implemented (the `0xE0000` register file, the window
arms and the `0xE0102` aperture gate, the packed scanout, the 256-entry palette), and the
packed store path drains through a posted, byte-combining store buffer and same-row SDRAM
gather sessions with a byte mask on the module's DQM-on-address pins
([`sdram.md`](sdram.md#dqm-wiring)). The PEGC **plane-mode engine** is not
implemented ([known issues](user/troubleshooting.md#known-issues)).

**The 640x480 256-colour mode** (INT 18h AH=30h BH=0x31 on the 31 kHz raster, the mode the
Windows 95 PC-9821 driver `PEGCV8.DRV` sets) displays: the packed walk's stride is the slave's
own PITCH - PITCH words of 8 bytes with both FF2 clock bits set (5 MHz), twice that at 2.5 MHz,
`& 0xFE` (NP2kai `vram/makegrex.c`), so the driver's PITCH 0x80 is its 1024-byte pitch - the
displayed height is the taller of the two GDCs' windows (the BIOS programs the master with 475
lines and the slave with 480; NP2kai `dispsync_renewalvertical`), and the walker steps across
the wrap of an odd (525- or 449-line) frame. The planar walk steps the same PITCH byte, doubled
when the SCROLL partition's im bit is clear and masked to an even byte (NP2kai
`vram/makegrph.c`): the 2.5 MHz state (PITCH 40, im 0) and the 5 MHz state (PITCH 80, im 1) both
step one 640-dot line, and the planar fetch itself is unchanged (80 columns per line from the
M10K array). `tb_pc9821_pegc_480` scans a whole frame through the real modules at
90 MHz and requires every packed line fetch to finish inside the 31 kHz line (2860 clk_sys) under a
saturating CPU stream; `tb_pc9821_sdram_bw` asserts the same deadline.

### Pixel clock

The raster runs on `clk_sys`, gated by an EXACT dot enable (`pc9821_dot_ce`, a NUM/DEN accumulator
at any clk_sys), so everything the guest sees keeps one time base. Two dot clocks, as on the
machine: 400/19 MHz (21.0526 MHz, 50 MHz x 8/19) for the 24 kHz raster, and while port `0x09A8`
bit 0 is set the Xe10's SEPARATE 31 kHz oscillator, measured at 25 168 031 Hz
(`docs/probes/CRT31K.TXT`, the ARTIC calibrated by the same run's 24 kHz rows: a VGA-class part,
not NP2kai's 25.26 MHz); the core makes 25 168 007 Hz (-0.94 ppm). `0x09A8` also selects the
31 kHz monitor range for the clamp (NP2kai `gdcclk[2]`, minx 92 / maxx 108). The constants live
in one place, `src/pc9821/video/pc9821_vclk_pkg.sv`.

The picture leaves on its own clock: `CLK_VIDEO` is a second, fractional-N PLL (`rtl/vpll`,
generated from `tools/profile/vpll_template.v`), 50 MHz x (M + K/2^32) / 19 with N bypassed;
`pc9821_vpll_ctl` reprograms it (N, M, K, start, through the framework's cut-down `pll_cfg_hdmi`)
between M 16 = 42.105 MHz (2 x the 24 kHz dot) and M 19 + 523/4096 = 50.336 MHz (2 x the 31 kHz
dot). No integer PLL comes within 54 ppm of the 31 kHz clock, hence fractional mode, as the
framework's HDMI PLL. The PLL is generated at its fastest setting (31 kHz) so the fitter times the
video domain there. `pc9821_video_out` carries each dot across through a 16-entry Gray-pointer FIFO
that is frame-locked by construction (both sides' dot rates are the same exact ratio of 50 MHz); a
PLL switch flushes and re-primes it. A pixel is then a constant 2 video clocks (native: 24.83 kHz,
or 31.46 kHz in the 31 kHz mode) or 1 (the line doubler, 49.66 kHz). A 31 kHz raster always leaves
native: it is already VGA-rate, so the doubler stands aside whatever the OSD asks, and the 31 kHz
picture is never scan-doubled to 62.9 kHz. Because `CLK_VIDEO` is an exact multiple of the dot
rate, no analog pixel or sync edge jitters by a clk_sys period.
`video_cleaner` -> `gamma_fast` -> `video_freak` run on `CLK_VIDEO`. `video_off` is tied 0 (a 1
blanks every HDMI pixel under `MISTER_FB`).

Every clock domain and every crossing between them is mapped, with the constraint that guards each
one, in [`clock-domains.md`](clock-domains.md): the video FIFO's Gray pointer and level
synchronisers and their max-delay/hold bounds, the audio held-vector handshake and the 44.1 kHz
toggle and HDMI-vsync synchronisers, the video PLL's reconfiguration handshake and relock window,
the SDRAM output clock, the gated CPU clock, and the frozen framework groups.

### Analog video converter

The analog video converter is a compile-time knob selected at run time by the OSD's `Analog video`
field: `vga_dbl_en` (`--vga-dbl`, on in every preset) builds `pc9821_line_doubler` (each GDC line
sent twice at 49.7 kHz for VGA monitors; MiSTer.ini `forced_scandoubler=1` turns it on from
Native). The analog modes are VGA Native (24 or 31 kHz) and Doubled (49 kHz); there is no 15 kHz TV
or composite/S-Video output. The doubler runs on the video PLL's clock (`CLK_VIDEO`,
`rtl/vpll`, generated like the main PLL from `tools/profile/vpll_template.v`): an exact multiple of
the dot rate, so every analog pixel and sync period is a constant number of clocks
(`tb_pc9821_video_clk`). The video PLL is GENERATED as the RECONFIGURABLE fractional variant
(`pc9821_vpll_ctl`) in every build, because 0x09A8 bit 0 moves it between the 24 kHz and 31 kHz
clocks at run time (`tb_pc9821_crt31k_video`).

## Sound

The core implements the **PC-9801-86**: the YM2608 (OPNA, `src/opna/`, vendored from
PC88_MiSTer's JT12/JT49 with documented local changes, `src/opna/LICENSE-SCOPE.md`) clocked
from its own 7.9872 MHz enable, IRQ12 (INT5), and the board's PCM block (`src/pcm86/`, **PIO**,
not DMA). The FM+ADPCM sum clamps once where the die does; the six-drum bus is the die's
16-bit wrap; the SSG joins zero-mean through the board's coupling at a level pinned by paired
SNDTEST recordings (`docs/probes/SNDTEST-balance-2026-09-25.txt`). The rhythm image is a runtime
input (see the pack). An **MPU-PC98II** MIDI interface over the MiSTer UART is built in every
preset except `trace`, and is present to the guest (ports 0xE0D0/0xE0D2, IRQ6) only while the
OSD's UART mode is MIDI: otherwise its ports read open bus and it is held in reset, so it
reappears in its power-on state (`tb_pc9821_mpu_system`). The core's ADPCM-A rhythm sounds without a driver; the Xe10's `XE10T /OPNA3 /LISTEN` run also
plays the rhythm with no driver resident, so the earlier "machine silent" observation is being re-checked (TODO item 47).

**Write timing at the YM2608, and why the rhythm registers drain with the FM gap.** The board
glue feeds the chip through a write queue (`src/opna/pc9821_opna.sv`), and two die mechanisms set
how far apart the queue must space the writes it replays. Both come from YM2608-LLE
(`fmopna_impl.c` at commit 7a2aca7; the line numbers below refer to that file) and agree with
the Xe10's XE10T `/OPNA3` captures (`docs/probes/XE10T-XE10-OPNA3.TXT`,
`XE10T-XE10-OPNA3-LISTEN.TXT`, `XE10T-XE10-OPNA3-SWEEP.TXT`, `XE10T-XE10-OPNA3-SWEEP2.TXT`;
what was heard on each run is recorded in `docs/probes/README.md`).

- **The select synchronizer.** A register select passes a two-phase synchronizer on the chip's
  internal clock (`fmopna_impl.c:309-323`, `write0_en`), 1-2 internal clocks (0.75 us each),
  before the address latches from the shared bus-input latch (`:366-367`, `:425`). A data write
  that arrives first becomes the address. A select-to-data spacing of at least about 1.5 us is
  always safe; one Xe10 I/O access (about 0.85 us) is not, which is why the first `/OPNA3`
  sweep (select and data one access apart) played every step quiet whatever the gap it
  measured. Yamaha's documented wait after a select (17 master clocks, 2.1 us) covers it.
- **The pending level/key word.** 0x18-0x1D go through the chip's one pending FM data word and
  are copied into a drum's level ring only when the ring counter reaches that drum, once per
  9 us turn (`:437`, `:935-937`, `:789`). ANY next register select drops the pending word
  (`write_fm_data[0] = ... || (write_fm_data[1] && !write0_en)`, `:437`), not only the next
  level write. The rhythm key (0x10) is taken from the bus latch about 16-20 us after its write
  (`:2765`, `:2780`); a select inside that window loses it. `/OPNA3` /LISTEN PHASE 2 (a 0x18
  write followed about 6.4 us later by the 0x19 select) is quiet about one time in three on the
  Xe10, as LLE predicts for a drop window of one turn.

A driver that honours BUSY (about 24 us after a data write) clears both windows, so every
rhythm key and level write lands: MDRV2 3.4F (Touhou 1) polls BUSY, writes the select, waits 28
`out 5Fh`, writes the data and one more `out 5Fh`, so its next poll comes past the synchronizer
and sees BUSY. The queue reproduces that: 0x10 and 0x18-0x1D drain with the FM write's
`DRAIN_GAP` (216 cen, 27 us), which covers both the 9 us turn and the about 20 us key sample (a
gap sized only for the turn would still lose keys). The core keeps writes the die would lose in
out-of-spec sequences (select-to-data under about 1.5 us, or a select within one turn of a level
write): it latches a select on the bus write itself (`jt12_mmr.v` `selected_register <= din`)
and only a next LEVEL write replaces jt12's pending level word (`lracl`/`up_lracl`). No title
is known to write that way; `tb_pc9821_opna_rhythm_level` holds the BUSY-honouring case.

## Interrupts, timers, input, RTC

`pc9821_interrupts.sv`: master/slave 8259A at the PC-98 port stride, cascade on master IRQ7,
PIT IRQ0, keyboard IRQ1, VSYNC IRQ2, the two-cycle z486 INTA handshake. Load-bearing details:

- requests latch on the edge regardless of the mask; the mask applies to `pending`;
- **per-line falling-edge withdraw** (`WD_MASK` while masked, `WD_UNMASKED` also unmasked),
  measured on the Xe10 (`docs/probes/IRQWD.TXT`, the XE10T `/OPNA2`, `/FDC` and `/AUDIT` rows):
  while masked, IRQ0's IRR bit follows the PIT channel-0 OUT pin, the keyboard (IRQ1) and IDE
  (IRQ9) requests clear when their acking read lowers the line, and IRQ11, IRQ12 and IRQ15
  clear with their lines; unmasked, IRQ0, IRQ1, IRQ12 and the cascade do too (the master's IR7
  goes when the slave's request goes: `/AUDIT` CASC rows). IRQ2 (VSYNC) keeps the pure edge
  latch;
- INT deasserts when nothing is left to forward; a stray INTA returns the spurious vector
  `icw2 | 7`; in-service priority is enforced; single-mode ICW sequences are sized correctly.

`pc9821_pit.sv` is the 8253 at `0x71-0x77` plus the `0x3FD9-0x3FDF` mirrors; mode-3 read-back
decrements by two per source clock (the form the games' `(N - read) / 2` calibration expects).
**VSYNC** is armed by port `0x64` (one-shot, re-armed in the handler, as master.lib does).

`pc9821_kbd.sv` is the uPD8251-style `0x41/0x43` interface with MiSTer Set-2 translation and
NP2kai's delivery gate. **HELP** is mapped to End; a key held through a boot produces no event
(the framework does not report keys already down). The **bus mouse** is the uPD8255 at
`0x7FD9-0x7FDF` plus the `0xBFDB` timer port, fed by the MiSTer PS/2 mouse. The **joystick** is
the OPNA register `0x0E` switch lines (measured, `docs/probes/JOY.TXT`), the Xe10's own path; the
PC-9801-118 game port at `0x1480-0x1487` is a compile-time option (`GAMEPORT_118`, off: the Xe10
has no -118 and reads open bus there). There is no OSD selection for its button mode.

`pc9821_calendar.sv` is the uPD4990A with the uPD4993A extended format (ports `0x20`, `0x22`,
`0x128`, data on `0x33` bit 0, IRQ15), counting from the MiSTer RTC in BCD. `0x128` is the
interval interrupt as the Xe10 answers it (`docs/probes/XE10T-XE10-AUDIT.TXT`): bits 1:0 the rate
(64, 32, off, 16 Hz), bit 7 the IRQ15 enable, bit 4 a tick flag a read clears, and one request
per tick whether or not the handler reads the port. **Its bit order is
not hardware-verified**: the measurement machine's backup battery is dead (every bit reads 1);
the order follows the firmware's own reader and two references.

**CPU Speed.** The OSD's `CPU Speed` (Full, 33 MHz down to 0.5 MHz) drives z486's gated-clock
throttle: the CPU sees fewer clock edges, and every device timebase keeps real time. The low
settings are approximations of the named clock, not cycle-exact models of those CPUs.

## Storage

- **Hard disk** (`pc9821_ata.sv`): the PC-98 IDE channel and task file, IDENTIFY, INITIALIZE
  DEVICE PARAMETERS, CHS and LBA28, multi-sector PIO reads and writes, READ/WRITE MULTIPLE,
  FLUSH CACHE as a no-op, IRQ9, a read-only image rejected before any host transfer. The
  fixed-disk BIOS interface is INT 1Bh, and it belongs to the guest's BIOS.
- **HDI hard-disk images** (`pc9821_hdd_image.sv`, between the ATA and the shared block engine):
  the image is recognised by CONTENT at mount, because hps_io gives the core a size and a pulse,
  never a file name. A 32-byte little-endian Anex86/FDI header (https://www.pc98.org/project/doc/hdi.html;
  NP2kai `fdd/sxsihdd.h`'s `HDIHDR`) is accepted when reserved is 0, HeaderSize is
  [32, 1 MiB] and a multiple of 512, bytes/sector is 512, and each geometry field is inside
  NP2kai's bounds (0 < sectors, heads < 256, 0 < cylinders < 65536) - what NP2kai's
  `fdd/sxsihdd.c` checks, plus the reserved and whole-sector tests content detection needs in
  place of its extension test. DataSize and the file's exact size are not checked (NP2kai reads
  neither). Then the drive's capacity is NP2kai's `cylinders * heads * sectors`, clamped to the
  sectors the file holds after the header, and every guest LBA is translated by
  `HeaderSize/512` for reads AND writes; the
  header's own sectors are never named, so a write cannot touch them. The first sector is read
  through the same block port at mount, with the engine's read-ahead window tag low so a raw
  image's first guest access is the same miss it always was, and the drive reports not-present
  until that probe lands (a mount during a probe discards it and re-reads). Any validation
  failure - and any raw PC-98 image, whose first DWORD is the IPL/partition table rather than 0 -
  falls back to the old behaviour byte for byte: offset 0, capacity `file size / 512`. The parsed
  offset survives an OSD reset like the other medium latches; only an eject or a replacement mount
  clears it. An HDI with an unpadded 32-byte header (or any header that is not a whole sector)
  cannot be sector-addressed and falls back to raw ([known issues](user/troubleshooting.md#known-issues)).
  `tb_pc9821_hdi_img` is the fail-first bench.
- **Fixed VHD hard-disk images** (`pc9821_hdd_image.sv`, the same seam): a Microsoft Virtual PC
  fixed VHD has its guest data at file offset 0 and a 512-byte BIG-endian footer at the END of
  the file (NP2kai `fdd/hdd_vhd.h`: "a minimal support for VirtualPC VHD images (fixed disk
  image only, for now...)"). When the front sector is not an HDI, a second mount probe reads the
  image's LAST sector and accepts it only when the footer's cookie is "conectix", its data
  offset is all-ones (a fixed disk has no dynamic header), its disk type is 2 (fixed), its
  `current size` is a non-zero multiple of 512 with `current size + 512 <= file size`, and its
  checksum is the one's complement of the sum of the 512 footer bytes with the checksum field
  zeroed. Then the offset is 0 (a write lands at the guest LBA) and the guest capacity is
  `current size / 512`, so the footer's sector is never a guest LBA. Dynamic and differencing
  VHDs (disk type 3/4, the "cxsparse" header at offset 512) are not supported and fall back to
  raw. The two formats are mutually exclusive: an HDI is recognised by its front header and
  short-circuits the tail probe; a fixed VHD by its tail. `tb_pc9821_hdi_img` covers both.
- **IDE layout**: the hard disk (hps_io slot 0) is ALWAYS bank 0's master (IDE unit 0). Bank 1's
  master (unit 2) is the OSD's **IDE bank 1** field (`status[67]`, CD builds; entry 0 = the CD-ROM):
  the CD-ROM - the stock CD-equipped Xe10's layout and NP2kai's default (HDD at unit 0, CD at unit
  2) - or a second hard disk (hps_io slot 3, "Mount HDD2"). A build without the CD has no field and
  its bank 1 holds the second disk when one is mounted, else nothing. The field is latched at the
  platform reset (`pc9821_system`'s `ide_bank1_hdd_eff`), and a change, like a hard-disk mount,
  resets the platform (`pc9821_disk_change_reset`). With the second disk selected the CD drive gets
  no write, so it never answers. Nothing moves with a disc mount or eject. The measured Xe10 answers at
  bank 1 and floats bank 0 (`docs/probes/IDE.TXT`, `ATA.TXT`) only because its CF card sits in the
  CD connector; the core uses that machine's measured live-bank answers and empty-bank float (`0x0E`
  task file, `0x0F` at `0x74C`/`0x74E`) at its own banks. Port `0xF0` bits 5/6 are the two
  connectors' drive-present lines (active low; the ITF's IDE drive bitmap at BANK4@0x19DF-0x19F2 and
  its `0x457` byte): bit 5 clears while the first disk's image is mounted, and bit 6 is clear while
  bank 1's master exists - the CD drive in a CD build with the default field, else the second disk's
  image. The Xe10 strap reads `0x89` with a disk and the CD (the stock machine), `0xA9` with the CD
  alone, `0xC9` with the disk alone and `0xE9` with neither (`tb_pc9821_ide_layout`, both builds
  through the real `pc9821_system`), and `0x89` with two disks (`tb_pc9821_ide_bank1_hdd`).
  The Xe10 IDE ROM registers an ATA device at each master its bitmap holds (BANK3@0x0A0A, IDENTIFY,
  then `or [0x5ba],1<<slot` at @0x0A96) and numbers the disks in slot order (@0x0DC0-0x0DFB), so the
  second disk is DA/UA `0x81` behind the first, or `0x80` alone, and MS-DOS, which reaches hard
  disks through the BIOS (INT 1Bh, DISK_EQUIP `0x55D`), gives it the next drive letter (from the
  disassembly; the capture on the machine is todo item 167). NEC's CD drivers (`NECCD.SYS`, `NECCDD.SYS`) look for the CD on bank 1's master only, so
  there is no CD for DOS with the second disk selected.
  `pc9821_ata` serves both disks with ONE transfer engine and a second register context per bank
  (task file, STATUS/ERROR, interrupt pending, nIEN/SRST, IDP geometry, SET MULTIPLE), exchanged in
  the same edge as the `0x0432` write while the engine is idle; a bank selected while the other
  bank's transfer runs reads BSY (and its own registers) until the engine frees, a trade raised as
  `docs/trade-candidates.md` T76. Each bank's INTRQ, gated by its own nIEN, drives the one IDE
  interrupt line (NP2kai `setintr`). One `pc9821_hdd_image` detector serves both images (per-drive
  records, one probe at a time), and `pc9821_block_share` carries the disk's unit on its disk port
  (slot D for slot 3), flushing the read-ahead window when the served disk changes.
  `tb_pc9821_ide_bank1_hdd` covers the field, both banks' IDENTIFY/READ/WRITE, the per-bank task
  file and interrupt, and the CD's absence.
- **CD-ROM** (`pc9821_atapi.sv`, on in every preset): an ATAPI drive as bank 1's master with
  the hard disk on bank 0, ISO and PCD images (`tools/cue2pcd.py` converts BIN/CUE and CloneCD
  `.ccd`/`.img` sets, the latter read as NP2kai `diskimage/cd/cdd_ccd.c` reads them), and CD-DA
  playback, its level the OSD Audio page's "CD audio" field (default 0 dB, the unity level shipped
  before the field; NP2kai's default CD-DA level, -6 dB, is a step; `tb_pc9821_osd_cd_volume`). Expected values follow NP2kai's `cbus/ideio.c`/`atapicmd.c`. Verified with NEC's
  `NECCD.SYS` + MSCDEX. While CD-DA plays, every file read on the CD fails with the driver's
  "CDR101: Not ready" (DOS error 5 to a program whose INT 24h answers Fail). That is the guest
  stack's answer, not the drive's: the MS-DOS CD-ROM Extensions 2.1 device-driver spec has the
  driver fail every request that needs head movement while the drive plays, returning the busy
  and error bits and an error code, and a `--dbg-cd` trail of `mister_regress.py`'s `probe-cda`
  shows NECCD.SYS answering each open from READ SUB-CHANNEL (audio status 0x11) and
  TEST UNIT READY alone, with no READ(10) sent while the drive plays. A real drive reports the same
  0x11 during play, so the Xe10 is expected to give the same answer. A program that wants data
  stops the audio first. The drive
  itself follows NP2kai `cbus/atapicmd.c`: a READ(10) during play is served and the play goes on,
  TEST UNIT READY is GOOD, READ SUB-CHANNEL reports 0x11; MMC drives and MAME
  `machine/t10mmc.cpp` (`abort_audio()`) stop the play on a READ instead, which no NEC-driver path
  can observe.
- **Floppy** (`pc9821_fdc.sv`, `pc9821_fdd_media.sv`): two drives, D88, raw and FDI images, READ
  DATA/READ ID/WRITE DATA over DMA channel 2, raw FORMAT, live mount/eject with NP2kai's
  media-change interrupts, the uPD765A's drive-poll interrupt 1.024 ms after a 0x94 controller
  reset is released with the motor bit (AI|unit per ready drive; the Windows 95 floppy driver sleeps
  on it), the interrupt line as the uPD765A's INT flag (lowered by every data-port byte and by a
  reset, raised by each completion and ready change, a ready change presented only with the
  controller idle; MAME `upd765.cpp`), READ ID answering one sector period after the command,
  when its ID field has passed the head (the Xe10's back-to-back READ ID spacing,
  `docs/probes/XE10T-XE10-FDC.TXT`; MSR CB alone meanwhile), and NP2kai's media-mode gate (a D88's 2D/2DD/2HD class against the
  controller's 2HD/2DD mode and the unit's 0x04BE rpm bit, and for a 2HD D88 whose fd_type minor
  is non-zero each sector's `rpm_flg` against that bit, NP2kai `fdd_d88.c` rpmcheck). **D88
  FORMAT remains** ([known issues](user/troubleshooting.md#known-issues)), as does 2HS media. An FDI
  mounts directly with NP2kai's `fdd_set_fdi` acceptance (`diskimage/fd/fdd_xdf.c`: the header's
  geometry, its size equation exact) when its header is a whole number of 512-byte blocks and its
  sectors are 256/512/1024 bytes; a 2D FDI (which NP2kai mounts but its raw reader can never
  serve) and the other FDIs are left to `tools/fdconv.py`. The other
  PC-98 floppy formats (Virtual98 FDD, NFD r0/r1) are converted off the core to a raw image
  or a D88 by `tools/fdconv.py`, whose readers follow NP2kai's (`diskimage/fd/`); NFD r1 retry
  copies and special reads, which a D88 cannot hold, are dropped only with `--lossy`.
- **DMA**: the 8237-compatible DMA controller (`pc9821_dmac`) serves the FDC; the PCM
  board does not use DMA.

**Storage area pass (trade-candidates T37).** The storage paths were slimmed for LABs
with every guest-read value held identical, each change proven against the previous RTL by a
bench that passes on both and fails a mutant. Module-alone A&S (`tools/res_exp_map.py`):
`pc9821_ata` 924 -> 854 ALMs (the end-of-image test is one borrow of `capacity - lba`; LBAs are
28 bits, the task file cannot name more; the geometry divider runs continuously instead of
detecting changes, so a new capacity or IDP geometry reaches IDENTIFY words 1/54/57/58 within 96
clocks), `pc9821_fdd_media` 786 -> 695 (image extents are 21 bits plus a BIG flag: no servable
image reaches 2^21 bytes), `pc9821_dmac` 487 -> 445 (the autoinitialize copies sit in five
4x8 block RAMs; a CPU write to the active channel's copy in the one clock before its own
autoinitializing terminal count is seen a clock late), `pc9821_atapi` 1466 -> 1345 (MODE SENSE
pages addressed by concatenation, the sense key and ASC as codes, READ SUB-CHANNEL's scan keeping
the difference), `pc9821_fdc` 493 -> 452 (the result phase is `{ST0, ST1, 0, x_c, x_h, x_r, x_n}` read from
the sector registers). The only storage LATENCY added is the geometry divider's 96-clock window
after an IDP or a mount (the guest reads those words 50+ port accesses after the command that
asks for them); `tb_pc9821_ata_idcyl` waits 160 clocks per change. Things measured and NOT worth
it (module-alone, so do not retry): serialising PLAY AUDIO MSF through one converter (+34 ALMs:
the parallel form's constant multipliers are cheaper than a variable-operand datapath), one shared
subtractor for the MSF converter's two loops (+43), compacting the D88 header walk into
accumulators (+8 ALMs for -31 flops), and replacing flops with fewer flops alone (an ALM holds
two registers beside its LUT, so only removed LOGIC moves the count). `tb_pc9821_atapi_equiv`
(with `tests/pc9821/pc9821_atapi_ref.sv`, the drive as it was) is the harness for further CD
refactors.

Both media share one block adapter (`pc9821_block_share`) on the single `hps_io` block
channel. Mount state is latched outside the reset branch (the host keeps an image mounted
across resets), and the MGL must list the image before the pack so the guest's one-time
drive probe sees it.

## Timing and resources

The device is a Cyclone V 5CSEBA6 (DE10-Nano), and **LABs, not ALMs, are the binding resource**: the
shipping build with the CD-ROM uses all but a few dozen of the 4,191 LABs. Every preset runs past
timing closure; the clock, slack and `pll_hdmi` facts, the build profiles and the SDRAM_CLK
structure are in [`build.md`](build.md) ("Build profiles") and [`fitting.md`](fitting.md) ("Timing and area facts"), and where the critical
paths are is in [`timing.md`](timing.md). `tools/check_fit.py` re-derives the fit and the
inferred-RAM lines from a build's reports and fails a fit that did not close or that lost block-RAM
inference.

The SDRAM interface is source-synchronously constrained against the AS4C32M16SB limits, and its
pin-clock phase is derived per clock by `tools/profile_gen.py`. The module is stable to about
120 MHz in the MiSTer memory test, which is why there is no SDRAM clock crossing: the controller
always runs on clk_sys.

## Hardware debug surface

**LEDs** (`z486_mister.sv`): `LED_POWER[0] = rom_ready` (pack registered, CPU released);
`LED_DISK[0]` = the access lamp, lit while a hard disk, the CD drive or the floppy controller
moves data with its image (a sector or block transfer: pc9821_ata's and pc9821_atapi's `xfer`,
the FDC's media data path), never for a command that only polls (status, IDENTIFY, TEST UNIT
READY, SENSE DRIVE STATUS), as ao486 lights its lamp from the HPS block requests alone; it is the
lamp the I/O board shows (`LED_HDD`). `LED_USER` = the floppy's own lamp (its transfers alone),
on the DE10-Nano board LED. Each is held on for 50 ms after its activity ends
(`pc9821_disk_led`, `tb_pc9821_disk_led`). The disk LED is no longer a boot indicator: the CPU's first fetch (`debug_first_instruction`) is still a
`pc9821_system` output but drives no LED, so a hang before the first fetch shows only as
`LED_POWER` lit with no disk activity and no picture.

**`io_debug_status`** (port `0x0EE0`, the watchdog's `ST`): bit0 `rom_ready`, bit1
`ioctl_download`, bit2 `cpu_run`, bit3 loader owns the backend, bit4 `load_error`, bits 7:5
the RAM-size code actually in force.

Deploying to a MiSTer and the debug UART (the `trace` telemetry and the `--dbg-*` instruments,
[`debug-instruments.md`](debug-instruments.md)) are in [`mister-testing.md`](mister-testing.md).

## Target machine

A mid-range 486 PC-9821 (Xe10 / Xe), not a PCI-era model:

- **No PCI bus**: `0x0CF8-0x0CFF` read open bus, which is what makes the BIOS conclude there is
  no PCI (answering a host bridge diverts its IDE path).
- **Word `IN` at the 8-bit ports** answers as the Xe10 does (`docs/probes/XE10T-XE10-AUDIT.TXT`):
  two byte reads with their side effects, except at the even ports of NP2kai's terminated set,
  where `P + 1` is not read and the high byte is `0xFF` (0x30-0x36, 0x40-0x46, 0x7C) or `0x00`
  (0x20-0x26, 0x60-0x7A, 0xA0-0xAC); NP2kai's 0x2588 word terminator and its CPU-AH ports are
  not the machine.
- **The software DIP switches** (`0x8F1F` control, `0x841E-0x8F1E` data) are a 24-byte,
  two-bank, parity-protected writable store holding the measured power-up image with the OSD's
  SETUP memory-switch item (0x871E bit 5) and floppy disk mode (0x861E bits 1:0, which
  port 0x00BE bits 3:2 read back; the OSD default auto (1M) seeds 0xF7 where the measured
  image holds the factory 1M's 0x76) folded in; the ITF writes all 24 back
  and verifies them. The store, its CG mirror and the configuration record are re-seeded from the
  OSD at every reset and at the guest's 0x534 reboot, so SETUP is not used. Which SETUP item
  writes which bit, and what the core does with it, is in [`bios-setup.md`](bios-setup.md).
- Emulating more of a machine than the firmware expects is not automatically safer: a PCI
  space and an IDE slave bit were both removed once a measurement showed what the machine
  answers.

## Not implemented

- the PEGC plane-mode engine;
- the WSS/MSS 16-bit audio board;
- the serial port;
- x87 / FPU;
- FDC D88 FORMAT and 2HS media;
- the `0xDA000` IDE work-RAM paging (served as plain RAM) and the `FA0000-FFFFFF` mirror
  (served as RAM);
- reserved/open-bus decode is approximate outside the ranges the firmware exercises.

## Open hardware questions

The questions that need a capture on a real machine (the probes are in `tools/hwprobe/`) are
section 3 of [`TODO.md`](../TODO.md).

## Keeping this document honest

As part of any feature change, not after it: move the item from "Not implemented" into the
description, say which reference a behaviour follows when implementations differ, and say when
a claim comes from reading RTL rather than a measurement. "Verified" is reserved for what a
bench, a hardware capture or a cited source shows.

## Licensing

The project's own code and documentation are licensed under the Apache License 2.0 (root
`LICENSE`); `NOTICE` states what that grant covers and lists the third-party parts, which keep
their own licences. The code surviving from the original MiSTer port has no confirmed licence
yet (TODO item 140), so the grant covers only the project's contributions to those files. Upstream z486 is
Apache-2.0 with `src/z486/LICENSE-SCOPE.md` excluding `ucode.hex` from that grant, and
`src/opna/` keeps each vendored part's licence header with `src/opna/LICENSE-SCOPE.md` scoping it.
**No firmware is vendored in this tree, and none may be**: the ROMs, the font and the rhythm image
are the user's runtime inputs.

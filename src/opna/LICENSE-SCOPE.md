# Licence scope: `src/opna/`

This directory vendors the YM2608 (OPNA) sound-chip RTL that the PC-9801-86
support is built from, plus the glue this repository wrote. **Each vendored
subsystem keeps its own licence**; nothing here is relicensed, and the
top-level repository licence does not apply to the vendored files. The policy
that requires this file is in [README.md](../../README.md) ("Licensing").

## Upstream

`https://github.com/MiSTer-devel/PC88_MiSTer`, directory `rtl/sound/`, commit
`09e56f54b6d36b23a154fd3390d3f36160fce661` (2026-09-10).

Every file under `jt12/` and `jt49/` is a byte-identical copy of that tree
(`diff` clean), except **thirteen** files that carry documented local changes (each
marked in-file with a `LOCAL CHANGE`/`LOCAL FIX`/`LOCAL PATCH` comment, or
cross-referenced to one): `jtopna.v` (see below), `jt12/hdl/jt08.v`,
`jt12/hdl/jt12_top.v`, `jt12/hdl/jt08_acc.v`, the two ADPCM-A files
`jt12/hdl/adpcm/jt08_adpcm_drvA.v` and `jt12/hdl/adpcm/jt08_adpcm_acc.v`,
`jt12/hdl/adpcm/jt08_adpcm_cnt.v`, `jt12/hdl/jt12_timers.v`,
`jt12/hdl/jt12_mmr.v`, `jt12/hdl/jt12_div.v`, `jt12/hdl/jt12_rst.v`,
`jt12/hdl/adpcm/jt08_adpcm_drvB.v` and `jt49/hdl/jt49.v`. (A `diff -rq` against the pinned commit above reports exactly
these thirteen; 51 of the 63 files named by upstream's `jt08.qip`+`jt49.qip` are
byte-identical (the other twelve are the list above but for `jtopna.v`, which no qip names) and
none is missing. Do not add a fourteenth without a marked,
reference-backed reason.)

The `jt08.v`/`jt12_top.v`/`jt08_adpcm_drvA.v`/
`jt08_adpcm_acc.v` changes are one seam, split across the four files because
that is where the signals live: a `rhythm_gain_shift` input that attenuates each
ADPCM-A drum inside `jt08_adpcm_acc`, before the six-drum sum (upstream only
scaled the already-summed bus). On top of that seam, `jt08_adpcm_acc.v` is the
die's 16-BIT WRAPPING six-drum bus (`fmopna_impl.c:5370`,
`ac_rss_accm1[0] = accm1 & 0xffff`), and `jt08_adpcm_drvA.v`, `jt12_top.v` and
`jt08_acc.v` carry it sign-extended into the 20-bit FM+ADPCM-A+B junction, whose
only saturation is at `jt08_acc`'s output - the junction the real chip clamps
once (ymfm `m_last_fm.clamp16()`, and the die's own output-shifter rails) and
NP2kai saturates once
(`_saturation_s16`) - because upstream's 16-bit clamp inside `jt08_adpcm_acc`
flat-topped dense drum overlaps before the FM mix (the owner's "drums
clipping"). `jt08_adpcm_cnt.v` carries only a two-line reset typo fix (`clr2`
was reset twice and `clr5` never), marked `LOCAL FIX` at the site.
`jt12_timers.v` gates the timer STATUS-FLAG SET on the `0x27` enable bit, not
only the IRQ line (ymfm `engine_timer_expired`, NP2kai `opntimer.c`, qemu
`TimerAOver/TimerBOver` all gate the flag), marked `LOCAL CHANGE (A-2)` at the
site. `jt49.v` seeds the SSG's power-on registers to NP2kai's
`reg[0x07]=0xBF`/`reg[0x0F]=0xFF` instead of zero, so an SSG use that never
writes register 7 is silent rather than routing every tone and noise source into
every channel, marked `LOCAL PATCH` at the site. `jt12_mmr.v` deasserts the
SSG write strobe `psg_wr_n` on the host clock rather than the FM `clk_en`, so
the strobe is one host clock wide; upstream's `clk_en`-wide deassert (~37 host
clocks at our 50 MHz / 7.9872 MHz DDS) let a fast SSG-data-write ->
register-select sequence write the stale `psg_data` into the newly-selected SSG
register. The die gates the SSG write to the data-write bus cycle
(YM2608-LLE `fmopna_impl.c:301-302,:2144-2190`), which the one-host-clock
strobe reproduces; marked `LOCAL FIX (PC-98 core)` at the site.
`jtopna.v`, `jt08.v`, `jt12_top.v` and `jt12_mmr.v` also carry the flag-reset seam, marked
`LOCAL CHANGE (flag-reset seam)`: a `host_clr_tmr` input that resets the timer A/B flags on
the guest's own bus write, because the board glue feeds the register port through a queue
and the chip resets a flag at the write (ymfm `engine_mode_write`
`set_reset_status(0, reset_mask)`, `ym2608::write_data` `m_fm.set_reset_status(0, 0xff)`;
NP2kai `opna_settimer`). A queued reset landing late made PMD's IRQ12 handler run a tick twice
and wiped the other timer's overflows (`tb_pc9821_opna_flagsync` T2). The glue also holds
`host_clr_tmr[1]` (`[0]`) high, a level, while the guest's `0x110` Timer-B (Timer-A) mask
stands, because a real Xe10 keeps that flag clear under the mask while the timer runs
(`docs/probes/KIT1-XE10-OPNA.TXT` STATUS3, `docs/probes/KIT2-XE10-OPNA4.TXT` S3A,
`tb_pc9821_opna_kit1`); only the seam's port comments in `jtopna.v` and `jt12_top.v`
say so, no logic in the vendored files changed for it. With the seam,
`jt12_mmr.v`'s `0x110` bit-7 reset leaves the timer flags to the glue and resets only the
ADPCM flags, in order behind the queued ADPCM-B writes. The same seam carries the timer
registers (owner decision 2026-11-01, item 155): a `host_tmr` input (`{value_A, value_B,
enable B, enable A, load B, load A}`, the glue's copy of 0x24, 0x25, 0x26 and 0x27 bits 3-0
latched at the guest's write) that `jt12_top.v` feeds to `jt12_timers` and to the YM2608 IRQ
enables in place of `jt12_mmr`'s queued latches, because the chip starts and reloads a timer at
the write (ymfm `engine_mode_write` `update_timer(...)`; NP2kai `opna_settimer` on the register
write). 0x27 bits 7-6 (the CH3 mode, `jt12_mmr`'s `effect`/`csm`) stay on the register port, in
order with the queued FM writes; `jt12_mmr.v` is not changed by this part, its own timer latches
are simply no longer read in the YM2608 configuration (`tb_pc9821_opna_xe10_rows` TMRQ).
`jt12_top.v` also carries `LOCAL CHANGE (0x29 timer IRQ)`: register 0x29's bits 0 and 1 no longer
gate the Timer A/B terms of the YM2608 IRQ (upstream ANDed `irq_mask[0]`/`irq_mask[1]` into them),
because a real Xe10's -86 board interrupts on Timer A with 0x29 = 00 and 02 exactly as with 1F
(`docs/probes/YM29-XE10.TXT`, verdict NO-GATE) and NEC's own SOUND.ROM relies on it; Timer B
follows NP2kai (`sound/opntimer.c`, which never reads 0x29), as the die model's identical gate is
falsified for Timer A. `irq_mask[4:2]` still gates the ADPCM flags (`tb_pc9821_opna_timers` 9b,
`tb_pc9821_opna_regs` 9).
`jt12_div.v` carries `LOCAL PATCH (PC-98 core, timing)`, the eleventh file (owner decision
2026-11-12: "we can patch jt12 locally if needed, but we should make it clear"): its six clock
enables (`clk_en`, `clk_en_2`, `clk_en_ssg`, `clk_en_666`, `clk_en_111`, `clk_en_55`) are
registered on the RISING edge of clk from the next cycle's chip enable instead of on the FALLING
edge from the enable itself. Upstream's falling-edge stage gave the whole chip's enable net
(one direct clock-enable net of about 1000 loads in Quartus) half a clk_sys period to reach
those six flip-flops, and that path missed setup on 2 of 6 seeds of the timing-hygiene lane's
base sweep (seed 2 -0.21 ns, seed 4 -0.81 ns) and on the th05 release+fixes sweep's seed 4
(-1.64 ns); a missed enable desynchronises FM, SSG, ADPCM and the timers at once. Every reader
of the six is a rising-edge register, and each is loaded one edge earlier with the value
upstream's falling edge latched, so every rising edge reads what it read before. The next
cycle's enable arrives on a new `cen_nx` input, carried by `LOCAL PATCH (cen_nx seam, PC-98
core)` port lines in `jtopna.v`, `jt08.v`, `jt12_top.v` and `jt12_mmr.v` from `pc9821_opna.sv`
(the registered DDS's next carry). `tb_pc9821_opna_cen` holds the six enables equal to a verbatim
copy of the pinned upstream `jt12_div` at every rising edge (9.0 million edges, three mutations
killed).
`jt12_rst.v` carries `LOCAL PATCH (PC-98 core, timing)`, the twelfth file, for the same reason
and in the same way: upstream's two-stage ADPCM reset synchroniser (instantiated in `jt12_top.v`'s
`use_adpcm==2` branch, the YM2608's ADPCM-A and ADPCM-B reset `rst_n`) is registered on the
FALLING edge of clk from `rst`, which gave the `rst_n` net half a clk_sys period to reach its loads
across the ADPCM blocks (+0.55 ns and +0.60 ns of setup slack on two of six seeds of the base
build at 90 MHz, the narrowest half-cycle path left in the chip). Both stages now load on the
RISING edge from `rst_nx`, the value `rst` takes at that edge (`pc9821_opna.sv`'s `op_rst_nx`, the
stretched reset's next state), so every rising-edge reader sees the `rst_n` it saw before; it
reaches the module on `LOCAL PATCH (rst_nx seam, PC-98 core)` port lines in `jtopna.v`, `jt08.v`
and `jt12_top.v` (all three `jt12_rst` instances there are wired, two of them in branches this
build does not elaborate). `tb_pc9821_opna_cen` holds `rst_n` equal to a verbatim copy of the
pinned upstream `jt12_rst` at every rising edge through seven releases and six assertions (two
mutations killed), and a simulation assertion in the module holds `rst_nx` to `rst` one cycle
early.
`jt08_adpcm_drvB.v` carries `LOCAL FIX (PC-98 core, BRDY after a flag reset)`, the thirteenth file
(owner decision 2026-11-14: known issues are fixed for the release, as marked local blocks where the
capture establishes them): upstream sets the ADPCM-B BRDY flag whenever the memory port is idle, so a
`0x110 = 80` flag reset cleared it for one clock enable and the guest's next read found it set again.
On a real Xe10 the read after the reset finds it clear (`docs/probes/XE10T-XE10-OPNA2.TXT`
`ADB_SETUP ... st1=00 stl=00 reads=1`, `FR_ADB i=3..7 st1=00 ... reads=1`), and it is set again by a
`0x100` write, by a memory byte, or with the unit idle and out of reset some time later (the next
row's `sb=08`, kit 1's `C0 ... 018C=08`). The idle return waits two of the unit's 55.5 kHz enables
after the reset, inside the bounds the capture gives; playback keeps upstream's rule
(`tb_pc9821_opna_adpcmb_mem`, `tb_pc9821_opna_kit1`). The only
additions outside those trees are our own `RHYTHM_ROM.v`,
`pc9821_rhythm_loader.sv` (under `src/pc9821/core/`), `pc9821_opna.sv`,
`opna.qip` and this file. The file list is exactly the union
of upstream's `rtl/sound/jt08.qip` and `rtl/sound/jt49.qip` plus `jtopna.v`,
which is also what the resource measurement fitted.

## `jt12/` — JT12, including the YM2608 fork `jt08.v` (GPL-3.0-or-later)

A fork of `jotego/jt12` that upstream does not have: `jt08.v`, the
`jt08_adpcm_*.v` files and the YM2608 rhythm path are local to the PC88 tree.
`jt12/LICENSE` is the GNU General Public License, version 3.

**Every file listed in upstream's `jt08.qip` carries the per-file JT12 header
except one.** The header reads:

> This file is part of JT12. … the GNU General Public License as published by
> the Free Software Foundation, either version 3 of the License, or (at your
> option) any later version. … Author: Jose Tejada Gomez. Twitter: @topapate

The one exception is `jt12/hdl/jt12_pcm.v`: it carries **no per-file header**
(the file begins directly with `module jt12_pcm(`). It is conveyed under
`jt12/LICENSE` as part of that directory. It is instantiated only when
`use_pcm == 1` (`jt12_top.v`), and `jt08.v` sets `use_pcm(0)`, so it
contributes no logic to this build.

## `jt49/` — JT49, the SSG (GPL-3.0-or-later)

`jt49/LICENSE` is the GNU General Public License, version 3. All seven files
listed in upstream's `jt49.qip` carry the per-file JT49 header ("This file is
part of JT49 … either version 3 of the License, or (at your option) any later
version", author as above, "Based on sqmusic, by the same author"). `jt49` is
instantiated inside `jt12_top.v` for the OPNA's SSG.

## `jtopna.v` — the OPNA wrapper (GPL-2.0-or-later by repository declaration)

`jtopna.v` carries **no per-file header** (the file begins with the comment
`// OPNA with JT12`). Its source repository has **no root `LICENSE` file**; the
only licence statement in it is the repository-level notice in
`PC8801SR.sv:4-9`:

> either version 2 of the License, or (at your option) any later version

That repository-level grant is what is recorded here, in preference to
assuming a licence the file does not carry. GPL-2.0-or-later and GPL-3.0-or-later
are mutually compatible, so the combined work is conveyed as GPL-3.0.

**Local change.** Upstream's `jtopna.v` with: the `RHYTHM_ROM` write seam
(`rhythm_we`/`rhythm_waddr`/`rhythm_wdata` input ports wired to the `RHYTHM_ROM`
it instantiates - upstream leaves that write port unconnected, so the seam
always existed but had no driver, and the port cannot be reached from outside
this file because the instance lives here); the `fm_snd_left/right` outputs
widened `[15:0]` -> `[19:0]` for the 20-bit FM+ADPCM junction (A-1); the
`rhythm_gain_shift` input tied to `3'd0` (the 0 dB default) and the `ch3_mono`
input (B-4, the NP2kai 3-channel mono re-pan) wired through to `jt08`. An
earlier revision of this note called it "two hunks" and "byte for byte
otherwise"; the audit on 2026-09-23 found four changes plus a cosmetic `module
jtopna (` spacing change, all marked in-file. The read path is untouched and the
vendored logic is otherwise unchanged.

## `rhythm_rom/RHYTHM_ROM.v` — written here, not vendor code

A plain block-RAM wrapper regenerated in this repository. Upstream ships a
Quartus megafunction-wizard file for the same module carrying Intel's AMPP
boilerplate and an `init_file` pointing at Yamaha's rhythm sample data. The
module name and its read port (`address`/`clock`/`rden`/`q`) match upstream; the
write port (`we`/`waddr`/`wdata`) is driven by `pc9821_rhythm_loader`. With no
user-supplied image the contents are all zero, and **all-zero ADPCM codes are
NOT silence**: code 0 at step 0 is a +2 delta per 18.5 kHz sample, so the
12-bit accumulator ramps and wraps - a loud DC-carrying sawtooth on every
trigger (this shipped once and was the owner's percussion pop; see the in-file
note and `tools/build_pack.py`). The user-supplied 8 KiB image is the only data
source, stated once in
`tools/build_pack.py`. Both this file and the vendor wrapper's excluded contents
are covered by "Excluded" below.

## `pc9821_opna.sv` and `opna.qip` — written here

The PC-9801-86 board glue (port decode, the 0x0E joystick shadow, the 0xA460
extension gate, the 7.9872 MHz clock-enable DDS and the stereo output). Ours.

## Excluded from this directory

* `RHYTHM_ROM.mif`, `RHYTHM/{01BD,02SD,04TOP,08HH,10TOM,20RIM}.mif` and the six
  `ROM_*.vhd`/`ROM_*.qip` megafunction wrappers for them — **Yamaha YM2608
  rhythm sample data. Not committed**, under the repository's "no copyrighted
  data is committed" rule. The user supplies the 8 KiB image at runtime through
  the same OSD file path as the firmware (as `OPNA_ADPCM.ROM`, packed by
  `tools/build_pack.py`).
* `OPN/{OPNA,OPNFM,OPNREG,OPN}.vhd`, `OPNARHYTHM.vhd`, `OPNAADPCM/` — the VHDL
  alternative OPNA. **It carries no per-file licence or copyright header of any
  kind**, worse provenance than jt08; vendoring it would rest entirely on the
  repository-level statement above.
* `jt12/hdl/{alt,deprecated}/`, `jt12/doc/`, `jt12/ver/`, `jt12/hdl/jt12.v`,
  `jt12/hdl/jt12.vhd`, `*.yaml`, `*.mif` — not in the build.

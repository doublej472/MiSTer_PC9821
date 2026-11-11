# Clock domains and the crossings between them

This is the crossing map for the whole core: every clock domain, every signal that leaves one and
arrives in another, the mechanism that makes it safe, and the constraint that guards it. None of it
depends on which clock network (global or regional) the fitter gives a clock: the protection is the
mechanism and the constraint, not the placement.

Sources are the RTL, the two constraint files (`sys/sys_top.sdc` and the generated
`z486_mister.sdc`, whose template is `tools/profile/z486_mister.sdc.in`) and the benches named in
each row. Template citations quote the line, since the generated file is rendered per profile.

## The domains

| Clock | Source | Rate | What runs on it |
|---|---|---|---|
| `clk_sys` | main PLL output 0, `z486_mister.sv` (`.outclk_0 (clk_sys)`) | 90 MHz (`base`) | the platform, the CPU (through the gate below), the SDRAM controller and PHY, `pc9821_system`, `hps_io`, the debug UART, the SDRAM pin clock's launch registers |
| `cpu_clk` (gated `clk_sys`) | `pc9821_cpu_clk`, a `cyclonev_clkena` with `ena_register_mode("falling edge")` (`src/pc9821/core/pc9821_cpu_clk.sv:81-85`, `.ena_register_mode("falling edge")`) | clk_sys, enabled by `cpu_ce` | z486 and `pc9821_cpu_bus_bridge` only |
| `CLK_50M` = `FPGA_CLK2_50` | the framework's 50 MHz pin | 50 MHz | the main PLL's `refclk`, the video PLL's `refclk`, `pc9821_vpll_ctl`, `pll_cfg_hdmi` |
| `CLK_VIDEO` = `clk_vid` | video PLL `vpll` output 0, `z486_mister.sv` (`.outclk_0(clk_vid)`) | 42.105263 MHz (24 kHz config) or 50.336015 MHz (31 kHz config) | `pc9821_video_out`'s read side and converters, `pc9821_video_cleaner`, `gamma_fast`, `pc9821_aspect`, `video_freak`, `sys_top`'s analog/HDMI video path and `ascal` input |
| `CLK_AUDIO` = `clk_audio` | `pll_audio` output 0 (`sys/sys_top.v:1569-1574`) | 24.576 MHz | `cdda`'s sample side, `pc9821_audio_mix` (with its `pc9821_audio_volume`), `pc9821_audio_out`, the framework's `audio_out` |
| `PC9821_SDRAM_CLK` | generated clock on the `SDRAM_CLK` port, `z486_mister.sdc.in` (`create_generated_clock -name PC9821_SDRAM_CLK`) | clk_sys rate, phase-shifted (PLL output 1) or inverted (output DDIO at >= 100 MHz) | the SDRAM device only; no fabric register |
| `pll_hdmi` | framework HDMI PLL | 148.54 MHz | `ascal`, HDMI OSD, shadowmask; frozen |
| `spi_sck`, `hdmi_sck`, `h2f_user0_clk`, `FPGA_CLK1/3_50` | framework/HPS pins | 100/10/100/50 MHz | `hps_io`'s SPI side, HDMI I2C, the HPS bridge; frozen |

`CLK_50M`, `CLK_AUDIO`, `FPGA_CLK1/3_50` and the main PLL are clock *generators*; a PLL's
refclk-to-output path is inside the PLL primitive and is not a fabric crossing.

## The crossings

"2FF" is a two-flop synchroniser chain (`src/common/synchronizer.sv` or the hand-written pairs,
all carrying `SYNCHRONIZER_IDENTIFICATION`). "Async group" is `sys_top.sdc:13-22`'s
`set_clock_groups -exclusive`, plus the generated SDC's video group below.

### Video (`clk_sys` <-> `clk_vid`)

The two clocks are **not** in an asynchronous group: both come from the 50 MHz reference, and
TimeQuest relates them by their edges. The template therefore bounds every path in each direction
and drops only the hold checks (`z486_mister.sdc.in`, `set_max_delay -from $pc9821_clk_sys ...`):

```
set_max_delay -from $pc9821_clk_sys -to $pc9821_clk_vid 19.866   # one 31 kHz video period
set_max_delay -from $pc9821_clk_vid -to $pc9821_clk_sys 11.111   # one 90 MHz clk_sys period
set_false_path -hold -from $pc9821_clk_sys -to $pc9821_clk_vid
set_false_path -hold -from $pc9821_clk_vid -to $pc9821_clk_sys
```

(19.866 ns is the video clock's *fastest generated* configuration, the 31 kHz one; the 24 kHz
period is 23.750 ns, so the bound is conservative. The values are `VPLL_PERIOD_NS` and
`1e9 / clk_sys` from `tools/profile_gen.py:render_sdc`.)

| # | From -> to | Signal(s) | Mechanism | Constraint | Verdict |
|---|---|---|---|---|---|
| V1 | `clk_sys` -> `clk_vid` | the 27-bit dot word `{vs,hs,de,r,g,b}` | 16-entry simple-dual-port M10K, written on `clk_sys`, read on `clk_vid` (`pc9821_video_out.sv:88-91`, `mem[wptr[AW-1:0]] <=`; `:139`). The read address is the Gray-decoded write pointer minus `PRIME`=8, so the entry being read was written at least 8 dots earlier | no path from a `clk_sys` register to a `clk_vid` register through the RAM; the RAM ports are timed separately | sound |
| V2 | `clk_sys` -> `clk_vid` | `wgray[4:0]` | registered Gray code (`wgray`, `:87`, `:93`) through `wg_s1`/`wg_s2` (`:98-106`). Only one bit changes per write, so a late or metastable bit resolves to the old or new *valid* pointer | the `set_max_delay`/hold pair above | sound |
| V3 | `CLK_50M` / `clk_sys` -> `clk_vid` | `vclk_31`, `vid_rst` (from `CLK_50M`); `dbl_on` (from `clk_sys`, `video_dbl_on`) | three independent levels, each through `lv_s1`/`lv_s2` (`:98-110`). The vector is not a coherent word: each bit is a separate control | `vclk_31`/`vid_rst`: `set_clock_groups -asynchronous` puts the video clock against `FPGA_CLK1/2/3_50` (`z486_mister.sdc.in`, `set_clock_groups -asynchronous`). `dbl_on`: the `clk_sys -> clk_vid` max-delay | sound; the bits are independent, so a one-cycle mix is two valid settings |
| V4 | `clk_sys` -> `clk_vid` | hps_io's `status` fields: `ar`, `scale` sampled on `clk_vid` (`z486_mister.sv`, `scale <= status[46:45];`; `arx_i`/`ary_i` follow from `ar` on `clk_vid` in `pc9821_aspect`, with option 0's 16:10 or 4:3 chosen from the displayed line count, which `pc9821_aspect` measures on `clk_vid` from the `gamma_vs`/`gamma_de` picture and the `clk_vid` `dbl_active`, so that choice crosses no domain), and `VGA_SL` (`status[83:82]` gated by the `clk_vid` `dbl_active`). `dbl_active`, `VIDEO_ARX/ARY` and `fifo_ev` are `clk_vid` signals with `clk_vid` consumers | quasi-static OSD/aspect/scale/scanline levels. No coherent multi-bit word with an invalid state | the `set_max_delay`/hold pair above | sound; the worst case is one frame of a stale OSD setting while the OSD menu is open |
| V5 | `clk_vid` -> `clk_sys` | `HDMI_TX_VS` (`hdmi_out_vs`, `sys/sys_top.v:1300-1335`) | `vs_d0 -> vs_d1 -> vs_d2` with a stability filter (`sys_top.v:544-548`) and `vsd -> vsd2` (`:1088-1093`) | named `set_false_path -from $pc9821_clk_hdmi -to $pc9821_vs_sync1` (`z486_mister.sdc.in`, `set_false_path -from $pc9821_clk_hdmi`) for the `pll_hdmi` leg; the `clk_vid` leg (direct-video mode) by the `clk_vid -> clk_sys` max-delay | sound |
| V6 | `clk_sys` <-> `CLK_VIDEO` (frame timing) | the FIFO fill level | the write and read sides' dot enables are the *same rational rate* of the 50 MHz reference (`pc9821_dot_ce.sv`: 400/19 MHz or 25.168 MHz; the video PLL: 2 x those), so the fill only wobbles by the enable phase and the synchroniser latency, around `PRIME`; a PLL switch flushes and re-primes | the bench `tb_pc9821_video_clk` (100 frames, 0 FIFO events at each clk_sys it runs) | sound |

### Audio (`clk_sys` <-> `CLK_AUDIO`)

`sys_top.sdc` puts `pll_audio` in its own exclusive group, so the pair is a false path; the
guarantee is the mechanism, not the timing. The generated SDC adds the named, clock-scoped
exceptions for the two seams whose coverage was otherwise implicit (`z486_mister.sdc.in`,
`set_false_path -from $pc9821_clk_audio` and `set_false_path -from $pc9821_clk_hdmi`).

| # | From -> to | Signal(s) | Mechanism | Constraint | Verdict |
|---|---|---|---|---|---|
| A1 | `clk_sys` -> `CLK_AUDIO` | `{sample_86_l, sample_86_r}` (40 bits) | `cdc_vector_handshake_continuous`: the source latches the vector on a `clk_in` edge and raises `new_value`; 2FF to `clk_out`; the vector is held until the ack returns through a second 2FF (`src/common/cdc_vector_handshake_continuous.sv`). The value is stable for the whole round trip | async group (no timing required); `tb_pc9821_pcm86_cdc` (22/22 pairs in order, no half-mix, latency <= 321 ns) | sound |
| A2 | `clk_sys` -> `CLK_AUDIO` | `speaker_out` | `synchronizer` 2FF (`z486_mister.sv`, `synchronizer speaker_out_sync (`) | async group | sound |
| A3 | `clk_sys` -> `CLK_AUDIO` | `beep_vol[1:0]` (guest register 0x871E [3:2]) | **raw**, quasi-static, into `pc9821_audio_mix`'s beeper stage | async group | benign: all four codes are legal amplitudes, the value changes only when the guest writes the software DIP, and the worst case is one sample at a neighbouring step (a click), never a corrupted or out-of-range value. See "Quasi-static levels" |
| A4 | `CLK_AUDIO` -> `clk_sys` | `clk_44100` toggle | `clk_d1 -> clk_d2` 2FF, then accept only when both stages agree, then edge-detect (`src/soc/cdda.v:164-165`, `if(clk_d2 == clk_d1) old_clk <= clk_d2;`) | named `set_false_path -from $pc9821_clk_audio -to $pc9821_cdda_sync1` (`z486_mister.sdc.in`, guarded on `cdda_inst|clk_d1`); async group | sound |
| A5 | `clk_sys` -> `CLK_AUDIO` (CD samples) | `{audio_l, audio_r}` | the same held-vector handshake (`audio_cdc`, `src/soc/cdda.v:104-110`, `) audio_cdc (`) | async group | sound |
| A6 | `CLK_AUDIO` -> framework | `core_audio_l/r` | the framework's `audio_out` runs on the *same* `clk_audio` net (`sys/sys_top.v:1569-1580`); this is not a crossing | none needed; the framework false-paths the `AUDIO_L/R` output pins (`sys_top.sdc:30-31`) | sound |
| A7 | `clk_sys` -> `CLK_AUDIO` | the OSD Audio page's levels, one 20-bit word `{~snd86_level, vol_cd_l, vol_cd_r, ~beep_level}`: the PC-9801-86 and Beeper 5-bit gain codes (from `pc9821_osd`) and the CD audio code on both channels (`pc9821_system`'s `vol_cd_l/r`); the other `vol_*` inputs are constants | the same held-vector handshake (`level_cdc` inside `pc9821_audio_mix`, `src/pc9821/audio/pc9821_audio_mix.sv`, `cdc_vector_handshake_continuous #(.DATA_WIDTH(20)) level_cdc (`). The codes are words, not independent levels: neighbouring OSD steps flip several bits (28 -> 27 is `11100` -> `11011`), so a raw capture could assemble a code never selected (31, 0 dB); the handshake's `clk_sys` hold register captures all three whole and holds them for the destination's capture. The -86 and Beeper codes cross inverted, so the handshake's all-zero power-up output reads 0 dB on them (their level before the page) and Off on the CD (as its own crossing powered up) | async group; `tb_pc9821_audio_level_cdc` (each field and all three together stepped through every neighbouring pair of the eight codes with 0.3-8.3 ns per-bit skew: no intermediate code, no move in a field that did not step, every code arrives, power-up codes, latency printed; the raw-crossing mutations of the handshake fail it) | sound |

The CD-DA ring itself is entirely on `clk_sys`: its banks `g_bank[*].mem` with their read
registers `g_bank[*].q`, the bank select `read_bank_q`, `write_addr`, `read_addr`, `filled_cnt`
and the read-ahead's `CDDA_REQ4`/`CDDA_PLAYED`/`CDDA_FLUSH` (to and from `pc9821_atapi`, also on
`clk_sys`) are all in `always @(posedge CLK)` blocks (`src/soc/cdda.v:150-209`,
`always @(posedge CLK) begin`, and the bank generate after it); only the 44.1 kHz toggle and the
resampled samples leave the domain.

### PLL configuration and the relock path (`clk_sys`/`CLK_50M`/`clk_vid`)

| # | From -> to | Signal(s) | Mechanism | Constraint | Verdict |
|---|---|---|---|---|---|
| P1 | `clk_sys` -> `CLK_50M` | `core_31k` (0x09A8 bit 0) | `c31_s` 2FF (`pc9821_vpll_ctl.sv:70`, `reg [1:0] c31_s`) | main PLL vs `FPGA_CLK2_50` in `sys_top.sdc`'s exclusive group | sound |
| P2 | `vpll` (locked) -> `CLK_50M` | `vpll_locked` | `lock_s` 2FF (`pc9821_vpll_ctl.sv:89`, `lock_s <= {lock_s[0], pll_locked};`) | the same group | sound |
| P3 | `CLK_50M` -> `vpll` | `reconfig_to_pll[63:0]` / `reconfig_from_pll[63:0]` | the vendor `altera_pll_reconfig` core's serial DPRIO interface; the cut-down `pll_cfg_hdmi` is the framework's own write-only core, and it contains an `altera_std_synchronizer` for the PLL's status | vendor core; `tb_pc9821_pll_cfg_lockstep` proves the cut-down core produces the same management sequence and the same DPRIO register file as the full `pll_cfg` for the same `pc9821_vpll_ctl` stimulus | sound |
| P4 | PLL relock -> `clk_vid` | `vid_rst` (from `busy`) | P1/P2 + V3; the read side flushes while `v_rst` is high and waits for `level >= PRIME` after it falls | V2/V3; `tb_pc9821_vpll_ctl`, `tb_pc9821_crt31k_video`, `tb_pc9821_video_reprogram` | sound (see below) |

**Why a reconfiguration cannot race a transfer.** The guest write changes `core_31k` on
`clk_sys`, so `pc9821_dot_ce` switches the *write* dot rate on the next `clk_sys` edge. On the
same event `pc9821_vpll_ctl` 2FF-samples the request on `CLK_50M`, sets `vclk_31` to the new
value, raises `busy`, and starts a four-write management sequence: N (address 3), M (4), K (7),
then start (2), each held until `waitrequest` drops (`pc9821_vpll_ctl.sv:93-125`, `busy_r <= 1'b1;`). `busy` reaches
the video side through `lv_s1/lv_s2` and flushes the FIFO. The first management write is issued on
the same `CLK_50M` edge as `busy`, several 20 ns periods before the start, and the 2FF latency is
at most two old `clk_vid` clocks (47.5 ns at 24 kHz), so the flush is in effect before the PLL is
touched. While the PLL is between configurations the write side keeps running on `clk_sys`, but
`flush` makes `rptr` follow the synchronised `wbin` on every read enable and clears `primed`, so
the FIFO cannot overrun. After the start, lock falls; `S_SETTLE` counts only while
`waitrequest` is low and lock is high and releases `busy` after 4096 `CLK_50M` clocks (81.9 us);
`primed` then waits for eight freshly written dots before the first take. The rate mismatch during
the (much shorter) management window is at most about one dot, which the 8-entry prime and the
16-entry depth absorb; the transition frame itself is flushed and is not a picture. A request that
arrives while a sequence is running is latched in `c31_s`; `vclk_31` changes only at `S_IDLE`,
and `busy` stays high across the second sequence, because the `S_IDLE` change arm raises it and the
release arm is not taken.

### SDRAM (`clk_sys` -> `PC9821_SDRAM_CLK`)

The controller and PHY run on `clk_sys`; there is no second SDRAM clock and no fabric clock-domain
crossing (`z486_mister.sv`, `.FREQ(CLOCK_RATE_HZ),   // the controller runs on clk_sys`). What leaves the
chip is a *forwarded* clock:

| # | From -> to | Signal(s) | Mechanism | Constraint | Verdict |
|---|---|---|---|---|---|
| S1 | `clk_sys` -> the SDRAM device | `SDRAM_A/BA/CKE/DQMH/DQML/DQ/nCAS/nCS/nRAS/nWE` | the controller's `clk_sys` output DDIO cells (both halves equal; the DQ output enable from one fabric register per pin) launch against the phase-shifted (or DDIO-inverted) `SDRAM_CLK`; the device samples them against that clock | `create_generated_clock PC9821_SDRAM_CLK` from the PLL pin (or from `general[0]` with `-invert` for the DDIO-clock build); `set_output_delay` / `set_input_delay` at the device limits (`z486_mister.sdc.in`, `set_output_delay -clock PC9821_SDRAM_CLK`) | sound |
| S2 | the SDRAM device -> `clk_sys` | `SDRAM_DQ` -> `dq_r` | the device launches DQ against the forwarded clock; `dq_r` is the sole controller input register, the rising-edge half of an input DDIO cell | `set_input_delay -clock PC9821_SDRAM_CLK` and the documented setup-2 multicycle (`z486_mister.sdc.in`, `set_multicycle_path -from [get_ports SDRAM_DQ[*]]`): the edge the controller consumes is the first one at or after the data, not the preceding one; the default hold after `-setup 2` is the shifted check | sound; the template's comment records the measured 5.293 ns launch/capture path skew that makes a naive single-cycle pairing a false -8.0 ns |

The `set_multicycle_path -setup 2` is the one place a setup count differs from one, and it is not a
CDC exception: both sides are `clk_sys`, and the comment in the SDC shows the edge pairing from the
fitted database.

### The gated CPU clock (`clk_sys` -> `cpu_clk`)

`cpu_clk` is `clk_sys` through a `cyclonev_clkena` (`clock_type "Global Clock"`,
`ena_register_mode "falling edge"`), so it has the *same edges* as `clk_sys`, only fewer of them.
TimeQuest propagates `clk_sys` through the gate: the fit's clock list names `general[0]` for the
platform and the CPU, as [`timing.md`](timing.md) records. The crossing is therefore not a CDC
in the metastability sense, but the *pulse* discipline is still explicit: every one-cycle pulse
input of z486 is held until the next enabled edge by `pc9821_cpu_bus_bridge`, the snoop hold is
back-pressured on both the presentation and the accept, and `tools/check_cpu_domain.py` pins the
instantiation set and the wiring. A future module clocked by `cpu_clk` or
consuming `cpu_ce` without the bridge is a check failure, not something a bench would see.

**The enable into the clock-control block.** The block registers `ena` on the FALLING edge of
clk_sys, but TimeQuest (Quartus 17.0) times the path into it, `u_clkena~FF_0`, as a rising-edge
capture: a full 11.111 ns period at 90 MHz where the silicon has half of it. With `ena` fed
straight from cpu_throttle's rising-edge `cpu_ce` the fitter was therefore free to route it 6.3 ns
to the global-clock site (fit rs-fix seed 3: `IC 6.327`, reported slack +0.964 against the
11.111 ns latch; a booting placement of the RC had `IC 2.428`). Such a placement latches the
previous cycle's enable, so the CPU's edges miss the cycles the bridge holds its handshakes for
and the CPU stalls at once at every CPU Speed below Full, while Full (cpu_ce constant 1) is
untouched: 2 of 6 seeds of e961ee3c and the 2026-11-01 release core did not boot below Full.
`pc9821_cpu_clk` now stages the throttle's enable in a fabric falling-edge register (`ce_fall`)
one cycle ahead and the platform's `cpu_ce` is that enable registered once on the rising edge:
the silicon path into the block is then falling to falling, a full period, and the one TimeQuest
times (falling to its modelled rising edge) is half a period, conservative instead of optimistic.
`tools/check_cpu_domain.py` rule 4 pins the structure; `tb_pc9821_cpu_clk` shows the CPU's edges
stay on the `cpu_ce` cycles for any enable route up to 10.5 ns (the unstaged enable fails at 6 ns).

### The framework and the HPS/SPI side (frozen)

The core's own `hps_io` (`z486_mister.sv`, `) hps_io`) runs on `clk_sys`; its `HPS_BUS` comes from
`sys_top`'s SPI slave (`spi_sck`) and the HPS bridge (`h2f_user0_clk`). `sys/sys_top.sdc:13-22`
puts `spi_sck`, `hdmi_sck`, `h2f_user0_clk` and `FPGA_CLK1/2/3_50` in exclusive groups, so every
core-side path from those domains is cut; `hps_io` is the framework's frozen module and carries
its own input synchronisers. The core only consumes its `clk_sys` outputs (`status`, `sdram_sz`,
`ioctl_*`, `ps2_*`, `img_*`, `sd_*`). The generated SDC additionally false-paths the
quasi-static `hps_io|status` and `sdram_sz` words in both directions (`z486_mister.sdc.in`, `set_false_path -from $pc9821_status_regs`),
which is a software-pace cut (microseconds at the closest), not a handshake.

`pll_hdmi`, `pll_audio`, `spi_sck`, `hdmi_sck`, `h2f_user0_clk` and `FPGA_CLK1/3_50` are all in
the generated SDC's asynchronous group that contains the video clock
(`z486_mister.sdc.in`, `set_clock_groups -asynchronous -group $pc9821_clk_vid`); the framework's `ascal` input FIFO and OSD are the frozen logic that
uses those groups, and the core's `CLK_VIDEO`/`CE_PIXEL`/`VGA_*` and `AUDIO_L/R` are on the same
clocks as the framework's ports of those names (V4/A6).

## Quasi-static levels

Two levels and one OSD-paced lookup table cross raw (no synchroniser), by the standard MiSTer
convention, and none of them is a coherence path:

- **OSD fields.** `status[23:22]` (aspect), `status[46:45]` (scale), `status[81:80]` (analog
  video) and `status[83:82]` (scanlines) are written by `hps_io` on `clk_sys`; the top samples
  some of them into `clk_vid` registers (`z486_mister.sv`, `ar    <= status[23:22];`) or feeds them into the video path.
  They change only while the OSD is open, and a one-cycle mix can at worst select a neighbouring
  aspect/scale/scanline setting for one frame. `dbl_on` is *not* in this class: it is the
  synchronised `lv_s1/lv_s2` level (V3), because it changes the pixel stream itself.
  The Audio page's fields - `status[75:73]` (PC-9801-86), `status[78:76]` (Beeper) and
  `status[66:64]` (CD audio) - are *not* in this class: `pc9821_osd` decodes each to a 5-bit
  gain code whose neighbouring steps flip several bits at once, so the three cross together on
  the held handshake (A7), not raw. One crossing serves the set: the levels change only while
  the OSD is open, so a shared handshake costs nothing in responsiveness (latency <= 0.31 us).
- **`beep_vol[1:0]`.** The 2-bit BEEPER VOLUME from port `0x871E` bits [3:2] (`pc9821_iobus`)
  is a guest register, sampled on `CLK_AUDIO` in `spk` (`src/pc9821/audio/pc9821_audio_mix.sv`, `spk <= speaker ? beep_amp`). It is not
  synchronised. Unlike the OSD fields it can change while the machine runs, but like them it is a
  *code*, not a word with an invalid state: all four values are legal amplitudes, the beeper's
  own `speaker_out` tone is the synchronised signal (A2), and the value changes only when ITF
  SETUP writes the software DIP. The worst case is one `CLK_AUDIO` sample at a neighbouring
  amplitude (about 40 ns), a click; there is no corrupted or out-of-range value to protect
  against. A handshake here would buy nothing a two-cycle stable filter would not, for a control
  that is static in normal use.
- **The gamma lookup table (`gamma_fast`, framework).** `hps_io` drives the framework's
  `gamma_bus` with `{clk_sys, gamma_en, gamma_wr, gamma_wr_addr, gamma_value}`
  (`sys/hps_io.sv:267`, `gamma_bus[20:0] = ...`); `gamma_fast` writes its three
  `gamma_curve_{r,g,b}` arrays on that `clk_sys` and reads them on `clk_vid`
  (`sys/gamma_corr.sv:75-100`), so the arrays are a dual-clock LUT. The core only releases the
  bus (`z486_mister.sv`, `assign gamma_bus = 'z;`); `hps_io` owns it. The OSD writes one
  8-bit entry at a time and the read can return the old or new entry while a write is in flight
  (`ramstyle="no_rw_check"`). Every entry is a legal gamma byte, so the worst case is one pixel
  on the old curve while the OSD is changing gamma. No synchroniser is wanted (the LUT is
  OSD-paced, not a data stream); the `clk_sys -> clk_vid` max-delay covers the bus wiring, and
  the memory's ports are timed separately. The write port is the same `clk_sys` net as
  `hps_io`'s registers, routed through the framework's bus wire, so it adds no unconstrained clock. `gamma_en` is the same class of OSD level. This is frozen `sys/`
  logic, not a core crossing, but it is instantiated here and is listed so the map is complete.

## Evidence and what this does not cover

What holds the map together:

- `python3 build_profile.py --check` compares the generated SDC with the template's render for the
  active configuration (the video max-delay pair and hold false paths, the video async group, the
  audio and HDMI-vsync exceptions, the SDRAM generated clock); the render raises on a missing token
  (`tools/profile_gen.py`, `render_sdc`).
- The benches: `video_clk` (doubled frames at several clk_sys rates, 0 FIFO events, 0 VS edges off
  HS), `video_reprogram` (mid-frame GDC SYNC writes and a RESET), `vpll_ctl` (the N/M/K/start
  sequence, busy released only after continuous lock), `pll_cfg_lockstep` (the cut-down
  `pll_cfg_hdmi` against the full `pll_cfg`), `crt31k_video` (the switch to 2 x 25.168 MHz and
  back), `pcm86_cdc` (the held handshake: order, no half-mix, latency), `audio_level_cdc` (the
  Audio page's level codes: no intermediate code under per-bit skew), `audio_out_*` and
  `cdda_*`.
- `python3 tools/check_cpu_domain.py`: every gated-CPU pulse input held or documented, the snoop
  hold back-pressured on both sides.
- `python3 tools/check_4state_xlock.py` (needs iverilog) runs the X-lock claims in 4-state
  simulation; the video FIFO's power-up seeds (`wg_s1/wg_s2/lv_s1/lv_s2`, `primed = 0`,
  `rptr = 0`) make it X-free by construction, since no read is taken before eight written entries.
- A fit's TimeQuest report shows the pairs timed or false-pathed as the template says and
  `Unconstrained Clocks 0`; its metastability report counts the synchroniser chains.

**Not covered:** the real PLL's analog relock behaviour (the benches model `locked` and the
relock window; the frequency decode is exact, but lock time and output glitch shape are hardware
facts); the framework's `ascal`/OSD internals (frozen, and covered by `sys_top.sdc`'s groups);
the placement of the synchroniser chains on a given seed; and whether a seed meets the `pll_hdmi`
floor (that is the deploy-gate sweep's job, not a CDC question).

The core's clock-domain crossings are sound: every crossing ends in a 2FF/handshake, a held-vector
protocol, a quasi-static level with a stated worst case, or the SDRAM's device-side output timing,
and the SDC times or cuts each pair as the table says.

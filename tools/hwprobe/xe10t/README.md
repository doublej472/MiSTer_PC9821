# XE10T - the unified timing probe

`XE10T.COM` measures, in one run and with one harness, every guest-visible access cost the
core prices (or leaves free): the CPU's own rates, GVRAM/GRCG/EGC/PEGC/TEXT memory, every I/O
port class, IRQ entry, OPNA BUSY, the PCM86 FIFO, the IDE, and opt-in the floppy, the CD and
the palette. `xe10t_decode.py` checks a capture, turns it into tables, compares a core capture
with a machine capture of the SAME binary, and writes the `.expect` file benches cite.

It supersedes the timing probes `gfxbench`, `gfxbenc2`, `egcplane`, `grcgpace` (never run; it
is the `/GRCG` section here), `ioprobe`, `idelat` and the timing sections of `probe2`
(`/WIPE` W1/W5/W6, `/TIMEREF`). They stay until a machine capture of XE10T exists and their
citations have moved to its `.expect` file; their captures stay in `docs/probes/` as history.
Two old-probe defects are recorded here rather than fixed: probe2 `/WIPE` W5's 57.115 Hz is a
fencepost (63.2 frames counted as 64; the machine runs 5445 ARTIC ticks per frame, as
`CRT31K.TXT`), and `ioprobe_decode.py` crashes on the RTL's removed `IO_WAIT_5F` (todo items
159 and 160).

## Building

```
make -C tools/hwprobe xe10t/xe10t.com
```

The build assembles `xe10t.s` (which includes `lib.inc`, `selftest.inc` and the `sec_*.inc`
files), refuses a forward `.equ` (`xe10t_decode.py --check-source`: GAS reads a not-yet-defined
symbol in an Intel-syntax operand as a memory reference), refuses an image over 48,896 bytes
(the buffers live at 0xC000-0xFFFF of the program's segment), and stamps the identity block
(`--stamp`: SHA-256 prefix of the image and CRC-32 of its constant part). The build is
reproducible; the header line of every capture carries the stamp and the CRC the program
computed over itself at run time, and the decoder refuses to compare captures of different
binaries.

### XE10U.COM: the kit-2 sections

```
make -C tools/hwprobe xe10t/xe10u.com
```

`XE10U.COM` is the same source assembled with `XE10U` defined (`as --defsym XE10U=1`): the
harness, CAL, the media-free sections, `/OPNA2`, `/OPNA3` and `/AUDIT`, WITHOUT `/IDE`, `/FDC`,
`/CD`, `/RASTER` and `/FDC2` (`sec_storage.inc`, `sec_fdc2.inc`, `sec_raster.inc`), and WITH
`/OPNA4` (`sec_opna4.inc`) and `/AUDIT2` (`sec_audit2.inc`). XE10T.COM is at its size limit and
its `/FDC2` captures compare only against the same binary, so the new sections went into a
second binary and `xe10t.com` builds byte for byte as before. The header reads `build=gas-xe10u`
and the default output is `XE10U.TXT`; the decoder handles both binaries (and, as for XE10T,
compares only two captures of one binary).

| Command | What |
|---|---|
| `XE10U /OPNA4 /O OPNA4.TXT` | todo item 155: a timer A / timer B 1-count start written straight after 0, 8, 32, 64 and 128 BUSY-polled FM data writes (silent registers, no key-on), 8 trials each; then the opna-xe10 lane's rows: the 0x18A read map of 0x00-0xFF with the extension closed and open, 0x29 read around its writes (open), and STATUS3 with timer A; silent, about 6 s; plain DOS, no sound driver; reboot after (0x29 left at 1F) |
| `XE10U /AUDIT2 /O AUDIT2.TXT` | todo items 114 and 42: the calendar's IRQ15 line sampled masked for 100 ms per 0x128 setting with and without a 0x128 read at each rise; word `OUT` to 0x09 (word_term), 0x0A (no term) and 0x6C (minus_term) read back on P and P+1; word `IN` shapes of the ports `/AUDIT` did not take; `in ax,P` against `in al,P` timing (does a word read fetch P + 1); about 3 s; press no key |

Reboot after each (both restore what they write; the kit reboots between steps anyway).

## Running

Boot plain DOS (no EMM386, no sound driver: the probe refuses V86 mode unless `/FORCE`, and
`/OPNA` refuses a resident INT 60h driver), copy `XE10T.COM` and `RUNXE.BAT`, and run:

| Command | What |
|---|---|
| `RUNXE` (`XE10T /ALL`) | every media-free section: ID, CAL, CPU, GVRAM, GRCG, EGC, PEGC, TEXT, IO, IRQ, OPNA, PCM86, IDE, BIOS |
| `XE10T /FDC DA 91 /CD` | the opt-in media sections (a readable 2HD disk in the named drive; a CD for `/CD`) |
| `XE10T /PAL` | the opt-in palette write rows (digital palette written with its defaults) |
| `XE10T /OPNA2` | the opt-in sound-chip section: which chip answers at 0x188/0x288/0x088, BUSY per write class over 128 write phases, flag-reset and IRQ12 latency, timer start latency, ADPCM-B (writes 40 bytes of the board's ADPCM RAM) |
| `XE10T /OPNA3` | the opt-in rhythm section, silent: BUSY after one rhythm level write (0x18) over 128 write phases, and after each of six level writes 0x18-0x1D and six key writes 0x10 written back to back the way MDRV2 3.4F (Touhou 1's music driver) writes them |
| `XE10T /OPNA3 /LISTEN` | the same, then about 14 s of bass-drum hits in three labelled phases: whether the first of six back-to-back level writes takes effect (by ear; see below) |
| `XE10T /OPNA3 /SWEEP` | the gap sweep instead (about 45 s): 20 numbered steps, each 0x18 <- DF, a measured gap, 0x19 <- C0 and 4 bass-drum hits; the shortest gap at which the first level write survives (by ear; see below). `/STEP n` and `/TO n` run steps n..m only |
| `CLS`, then `XE10T /RASTER` | the opt-in VISUAL palette-timing picture (15 s; photograph or capture the screen, see below) |
| `XE10T /AUDIT /O AUDIT.TXT` | the opt-in read-side and interrupt-line audit: word/dword IN on 8-bit ports, open-port bytes, IRQ0 withdraw while unmasked, the calendar IRQ15 per tick, the master IR7 after a slave mask (about 20 s, silent; see below) |
| `XE10T /FDC2 /O FDC2A.TXT` | the opt-in floppy-controller rows (todo item 59, and the answers the core now follows): the controller's result after a terminal count, what holds IRQ11, the reset's interrupt, a command on an empty drive, MSR and 0x92 during a DMA data phase (about 30 s; see below) |
| `XE10T /FDC2 /M640 /O FDC2M.TXT` | the same section's 640K-mode rows (item 180), with SETUP's floppy disk mode at 640K: port 0xCC bit 4 after SENSE DRIVE STATUS, and the reset through 0xCC |
| `XE10T /SELFTEST` | the internal checks and the harness against a synthetic device |
| `XE10T /DRY` | the plan: every section, the ports it writes, every case; nothing runs |

Flags: any section name (`/CPU /GVRAM /GRCG /EGC /PEGC /TEXT /IO /PAL /IRQ /OPNA /PCM86 /IDE
/FDC /CD /OPNA2 /BIOS /RASTER /OPNA3 /AUDIT /FDC2`), `/M640` (`/FDC2`'s 640K rows), `/LISTEN` (`/OPNA3`'s audible phases), `/SWEEP` (`/OPNA3`'s gap sweep; it selects `/OPNA3`), `/STEP n` and `/TO n` (the sweep's first and last step, 1-20), `/REPS=n` (3-15, default 5), `/QUICK` (3 repeats, for the core), `/TAG=text`
(the build ID of a core run, e.g. its OSD build string), `/O=file` (default `XE10T.TXT`),
`DA=xx`, `/FORCE`, `/SKIP <SEC>` (leave a section out; repeatable) and `/FROM <SEC>` (leave
out every section before it in table order, to resume past one that hung: `XE10T /ALL /FROM
IRQ`). COMMAND.COM splits batch arguments at `=`, so `/TAG xe10`, `DA 91`, `DA91` and `/SKIP
IO` work too. ID and CAL always run, RESTORE always runs last.

The capture is written by the program to `XE10T.TXT` (no redirection) and committed to disk
after every section, so a hang loses nothing already measured. Before every row that touches a
device (each `/IO` port, each `/OPNA`, `/PCM86`, `/BIOS` case, the `/IRQ` trials, each `/IDE`
and `/CD` bank and the command phase, each `/FDC` drive and phase) it also writes and commits a
`ROW <SEC> <tag> [port=xxxx]` line: a bus cycle that never completes stops the CPU, so no
software watchdog can report it, and the last `ROW` line on disk names the row that hung (the
decoder prints it with the truncation). `/IDE` and `/CD` write those lines with the as-found
IDE bank selected and hold the rest of their output until the bank is back. The screen shows progress
(section names and case tags). There are no prompts and no keyboard reads. Expected run time:
`/ALL` about a minute on the machine (the PIT/VSYNC calibration takes about 2 s, each section a
few seconds); `/FDC` up to a minute.

`/OPNA2` is not part of `/ALL`; run it on its own (`RUNXE /OPNA2`) from plain DOS with no sound
driver. The Xe10 has two sound chips: the PC-9801-86 board (YM2608) and the built-in YM2203,
which the BIOS setup can enable or disable. No port the probe knows exposes that setting
(NP2kai models no PC-9821 built-in sound control), so **record the BIOS setup's built-in sound
setting in the run notes with every `/OPNA2` capture**, together with the 86 board's base and
IRQ jumpers if known. The section reads 0x088 and 0x288, which no earlier capture had read;
each base's first access is a status read behind a flushed `ROW` line, and a base whose status
reads FF gets no write.

Order (the hwprobe rule): `/SELFTEST` and `/ALL` on the core first (all END lines, every RESTORE
OK, CAL OK), then `/ALL` on the Xe10 with the same binary, then the core again only if the
binary changed. Captures go to `docs/probes/` unmodified (`XE10T-XE10.TXT`), with
`xe10t_decode.py XE10T-XE10.TXT --emit-expect docs/probes/XE10T-XE10.expect`.

## The method (the design rules)

- **One harness.** A case is a set of code templates (setup, access, address step, post). The
  harness assembles at run time the body `setup; L: {access; step; k x nop} x unroll; loop L;
  post` and the control: the same bytes with every access left out, so the control is
  byte-identical except the access by construction; both CRCs print (`shell=`/`bshell=`) and
  the decoder refuses a row where they differ.
- **Windows** run under `cli`, start on an ARTIC edge, and are timed by the ARTIC (307200 Hz)
  and by PIT channel 0 (latched; byte order, rate and modulus measured by CAL). Control and
  body alternate, `rep` times each; rows print min/median/max of raw counts only.
- **Posted accesses are swept**: k = 0, 2, 4, 8, 16, 32 nops after each access. While the
  device is the bottleneck the gross time stays at the device period; once the shell plus the
  nops is longer, it follows the control plus the access's own issue cost (the control leaves
  the access instruction out). The decoder takes the issue cost from the two largest k, the
  period from the points above that line, and the knee where they end: a period, never a
  shell-subtracted net. `NO-PLATEAU` (no point above the line: a blocking or free access),
  `KNEE-NOT-FOUND` (still on the plateau at the largest k) and `PLATEAU-NOT-FLAT` (the points
  above the line climb with k) are reported, not trust failures. Blocking accesses (reads,
  `in`, string moves) get net = body - control. No figure is derived by subtracting one
  shape from another (pairs are cross-checks only).
- **Calibration** (CAL): the PIT byte order, its rate in eight windows started just after a
  reload edge, the reload period over 0.5 s (so the modulus is measured, never assumed), the
  0x0501 strap, VSYNC over 60 edge-to-edge frames against the ARTIC, the PIT and the TSC, and
  the TSC rate. `verdict=OK` needs 8.000 PIT counts per ARTIC tick within 0.1 % and 5445 +- 2
  ticks per frame; a FAIL marks every timed row untrusted, the run continues.
- **Deadlines and the watchdog.** Every poll has an ARTIC deadline and prints `TIMEOUT`; a
  timed body that must poll a device (the GDC FIFO rows) bounds the poll by 65535 reads and
  reports expiries as `to=`. A section that runs past its budget (10-60 s) prints `WATCHDOG`,
  unwinds to its exit code (which restores) and the run continues with the next section.
- **Restore.** Every register a section writes is restored: read-back-proven ones from their
  read (`kind=readback`, checked), write-only ones to a documented default (`kind=default`),
  memory the probe saved itself (`kind=self`, verified). A failed restore prints `RESTORE ...
  FAIL` and the following sections print `FAULT`. RESTORE at the end checks the interrupt
  vectors, both PIC masks and the 0x9A0 mode bits against their as-found values.

## Sections

| Flag | Measures | Writes (restored) |
|---|---|---|
| `/ID` | CPUID (if EFLAGS.ID toggles), MSW/CR0 and V86, F000:FFF0-FFFF and the BIOS date, port 0xF0 (read only), BDA bytes, DOS version, as-found IMRs and mode bits | - |
| `/CAL` | the trust gate above | - |
| `/CPU` | dependent/independent ALU (WIPE W1's body), imul/idiv 16/32, rcl/rcr, load/store, segment load, push/pop, near/far call, loop vs dec/jnz, int/iret, pushf/popf, cli, sti+cli, a mixed group, main-RAM `rep stosd`/`movsd` 4 KiB, 32 KiB, 256 KiB, a stride-64 pointer chase | IVT 0xF5 (hooked to an IRET) |
| `/GVRAM` | plane-B word/byte/dword/odd/stride-80/three-plane writes (swept), word/byte/dword reads, write-read and read-write pairs (swept), `rep lodsw/lodsd/stosw/stosd/stosb`, `rep movsw` RAM->VRAM, VRAM->RAM, within a plane and across planes | GVRAM (scribbled) |
| `/GRCG` | RMW and TDW 8/16/32-bit stores (swept), `rep stosw/stosd`, TCR reads, the four-`out 7Eh`-plus-store tile reload | 0x7C, 0x7E |
| `/EGC` | the write shape at 1-4 planes (swept), the copy shape's read and read+write (swept), `out A6h` alone and before a read or a write, register-file write and even read | 0x6A, 0x7C, 0x4A0-0x4AE, 0xA6 |
| `/PEGC` | 256-colour packed bank 0: byte/word/dword writes (swept), reads, `rep stosd`, `rep movsd` from RAM (the DOOM blit). The 0xF00000 aperture is not reachable from real mode | 0x6A, E0004/E0006/E0100 |
| `/TEXT` | TRAM code and attribute writes (swept) and reads, the CG window read, `out A5h`+`in A9h` per glyph row, the A1/A3 code select | TRAM (saved, restored, verified), 0xA1/0xA3/0xA5 |
| `/IO` | byte reads of only the ports a machine capture already read (`IO.TXT`, `FDMODE-XE10.TXT`, `R10.TXT`; the list and the reason for each, and for each port left out, is in `sec_io.inc`), word reads at 0x5C and 0x188, the writes no capture has, both GDCs' MASK command FIFO-gated | listed by `/DRY` |
| `/IRQ` | PIT ch0 one-shot -> IRQ0 -> a stub ISR that latches ch0 (48 trials); the stub by `int 08h` (no PIC/INTA); a request held in the IRR while masked, delivered at the unmask (counter read unlatched there: NP2kai clears IRR bit 0 on any ch0 write to 0x77, the latch included) | PIT ch0, IVT 08h, IMR bit 0 |
| `/OPNA` | BUSY after an address write and after FM (0x30/0x40/0xA0/0xB0), SSG (0x08), rhythm (0x11) and ADPCM-B (ext 0x00) data writes: busy time in PIT counts and the poll count | those registers, silent values |
| `/PCM86` | FIFO data write with playback stopped, status/control reads, the FIFO-full point | 0xA468, 0xA46C |
| `/IDE` | READ SECTORS C0/H0/S1 on the first ATA disk (one that answers IDENTIFY DEVICE; an ATAPI unit aborts it) of bank 1, then bank 0 (the Xe10's CF card is on the second connector): 16 single-sector trials (command -> DRQ, the 256-word transfer; trial 0 is the cold read) and one 8-sector read | 0x432, IMR bit 1 (read-only on disk) |
| `/BIOS` | INT 18h AH=01/02/0Ch, INT 1Bh SENSE (DA 0x80), INT 21h AH=30h | - |
| `/PAL` (opt-in) | digital palette writes | 0xA8-0xAE (defaults) |
| `/FDC` (opt-in) | `DA=` (0x90-0x93) or 0x90 then 0x91: the motor on only as the BIOS does it (0x0480 bit 4), an ARTIC-timed spin-up, RECALIBRATE, then SEEK 0-40-0, 20 READ IDs (spacing), 20 single-sector and one 8-sector READ DATA by DMA channel 2; ST0-ST3 on every failure. Rows are in ARTIC ticks (longer than a PIT period) | IMR bit 3, IVT 13h (EOI stub), DMA ch2 (masked after), the motor handed back to the BIOS timeout; 0x00BE/0x04BE never written |
| `/FDC2` (opt-in) | the rows in "`/FDC2`: the floppy controller's answers" below | IMR bits 3 (and 2 under `/M640`), IVT 13h (EOI-counting stub), the slave PIC's read register (left at ISR), DMA ch2 (masked after), 0x94 (08 motor on, 09/0C the BIOS hand-back, 98/18 and 90/10 resets) or 0xCC under `/M640` (08, 00, 98/18, then the BIOS's 09/0C and 0x05D7), SPECIFY 03 C1 46 and RECALIBRATE of units 0/1 after a reset; 0x00BE/0x04BE never written |
| `/CD` (opt-in) | an ATAPI drive on bank 1 master/slave or bank 0 slave: TEST UNIT READY, READ(10) of LBA 16 cold and warm, READ TOC, PLAY AUDIO MSF of the first audio track (00:02:00 without one) -> playing, STOP; REQUEST SENSE on any error. The play is audible for up to 3 s | 0x432, IMR bit 1 |
| `/OPNA2` (opt-in) | 1. identity on every candidate base (the 86 board at 0x188 or 0x288, a 26K-style OPN at 0x188 or 0x088): the as-found status/data reads, then for a base that answers (status not FF) register 0xFF (the ID), 0x0E/0x0F, 0x10/0x20, an SSG write/read-back, the status at +0/+4/+6 and the extended data port, with 0xA460 bit 0 cleared and set; a reduced BUSY and timer trial on a second answering base. 2. on 0x188, extension open: BUSY after an address write and after FM 0x30/0x40/0xA0/0xB0/0x28, SSG 0x08, rhythm 0x10/0x11, ADPCM-B 0x100 and extended FM 0x130 data writes, 128 trials each, trial i delayed by (i x 37) mod 128 `out 5Fh` so the writes land at many chip phases: a T row, a histogram and the first 32 raw trials; back-to-back writes with no BUSY poll (an SSG pair read back, timer A's two load bytes timed to the flag). 3. flag reset: timer A and B flags reset through 0x27 with the timer kept running, the status polled until the flag clears and the slave PIC IRR (bit 4 = IRQ12) read before, right after and until it drops, 32 trials each. 4. timer A at 1/4/16/64 counts and timer B at 1/4, PIT time from the 0x27 start write to the flag (8 trials each). 5. ADPCM-B: reset, a timed 0x110 flag reset, a memory-write setup and 40 data bytes with a BRDY poll each, 8 timed EOS/BRDY resets | FM 24-28 30 40 A0 B0, SSG 08 0B 0C, rhythm 10 11, extended 00-05 08 0C 0D 10 30 (silent values; timers stopped, all keys off, rhythm dumped, ADPCM-B reset, flag mask 0x110 <- 1C), 40 bytes of ADPCM RAM, 0xA460 (read-back), IMR bit 4 (read-back), the slave PIC's OCW3 (left at ISR); 0x29 never written |
| `/OPNA3` (opt-in) | the rhythm writes MDRV2 3.4F makes at song start (`0x18..0x1D <- DF DE DF DA DF DD`, each behind one BUSY poll: poll, select, data, next), on 0x188 with the extension open, the rhythm dumped and its total level 0. 1. `BUSY_RHY18`: one level write (0x18 <- 00, pan off), 128 trials at the (i x 37) mod 128 phases, the `/OPNA2` format. 2. `B2B_RHYLVL`: the six level writes back to back, 32 trials (each after (i x 37) mod 128 `out 5Fh`): per write the polls and PIT time of the BUSY wait after its data write and `dd`, the PIT time since the previous data write; a histogram per write position (`i=H w=0..5 reg=`), one over all writes (`w=all`), a T row. 3. `B2B_RHYKEY`: the same for six key writes 0x10 <- BF 01 BF 08 BF 3F with every drum's pan off (silent). 4. `/LISTEN` only: 0x11 <- 36, then PHASE 1 SLOW (0x18 <- DF, 0x19-0x1D <- C0, each write then 200 us), PHASE 2 B2B (all six <- C0 slowly, then the same list back to back), PHASE 3 B2B-REV (all six <- C0 slowly, then 0x1D..0x19 <- C0 and 0x18 <- DF last back to back); each phase keys the bass drum alone 8 times (250 ms apart, the first 50 ms after its level writes) and logs a `LISTEN_*` row with its writes' polls. 5. `/SWEEP` only, instead of 1-4: 0x11 <- 36, then per step the gap sweep below, a `SWEEP` row per step | rhythm 10 11 18-1D (dumped, 0x11 <- 00, the levels <- DF: ymfm's reset value), 0xA460 (read-back) |
| `/AUDIT` (opt-in) | the rows in "`/AUDIT`: what each row settles" below: word/dword IN at about 40 ports and the PIT-latch and DMA flip-flop side effects, 16 open-port bytes, the IRQ0 request with OUT0 falling (IF=0, masked and unmasked; a slow handler), the calendar IRQ15 per tick with and without the 0x128 read, the master IR7 after a slave mask | IVT 08/0F/14/17 (self), both IMRs (readback), PIT ch0 (mode 0 with CAL's modulus: default), 0x128 (readback), the uPD4993A TP = 64 Hz command (the power-on default), OPNA 0x26 <- FF and 0x27 <- 30 (default), OCW3 IRR on both PICs, the 8237 flip-flop cleared and DMA channel 2 masked (default), its address written back (readback) |
| `/RASTER` (opt-in, visual) | when a palette write reaches the screen (the Xe10's run: docs/probes/XE10T-XE10-RASTER.TXT, both palettes take a write at once): three 5 s phases, each frame cli + the master GDC's VSYNC edge + timed writes to palette entry 0 over a cleared GVRAM (all graphics dots are entry 0). SPLIT: red, then green half a frame later (G, R, B written in turn); TOGGLE: grey, then a 1024-write burst toggling the blue channel; DTOGGLE: the same burst on the 8-colour digital palette (0xAE 0x14/0x04). Logs, per phase, the write offset after the edge and the burst time; the decoder turns them into the display line and the length of one `out` in dots | GVRAM pages 0/1 (cleared), 0xA2 START, 0x6A, entry 0 (ITF 000 after), the digital bytes (37/15/26/04 after), the colour mode (readback) |

Safety: nothing writes a disk (`/IDE` issues only IDENTIFY DEVICE and READ SECTORS; `/CD` only TEST UNIT READY,
READ(10), READ SUB-CHANNEL, REQUEST SENSE, PLAY AUDIO MSF and STOP; `/FDC` only SENSE,
RECALIBRATE, SEEK, READ ID and READ DATA). Port 0xF0 is only read (a write resets the CPU).
The keyboard data port is never read. `/IO` reads no data or command port (IDE/ATAPI 0x640,
FDC 0x92, keyboard 0x41, DMA status 0x11) and nothing a machine capture has not read: the first
Xe10 run of `/ALL` (binary 678d4070) froze hard in `/IO` at the EGC file's even/odd byte
alternation (0x4A0/0x4A1), a row no capture had, and that row is gone. GVRAM and PEGC memory are overwritten; reboot or clear
the screen afterwards if the picture matters.

In NP2kai the FDC timings are not rotation-accurate (its READ ID steps through sectors, its
READ DATA is not timed by the disk), so only the core and the machine give usable `/FDC`
numbers; and the sweeps are flat: its `NOP` costs no cycles (`i386c/ia32/instructions/misc_inst.c`
`_NOP` has no `CPU_WORKCLOCK`), so an emulator capture shows no knee. That is the emulator,
not the probe.

## `/OPNA3 /LISTEN`: what to listen for

The rhythm registers have no read-back, so whether a back-to-back level write took effect is
heard, not read. Run `XE10T /OPNA3 /LISTEN` with the sound audible (the screen labels each
phase as it starts) and write what each phase sounded like into the run notes:

| PHASE | writes | if the chip keeps every level write | if it holds one pending level word (as the vendored jt12) |
|---|---|---|---|
| 1 SLOW | 0x18 <- DF first, 200 us between writes | 8 loud bass-drum hits (the reference) | the same |
| 2 B2B | 0x18 <- DF first, back to back | as loud as PHASE 1 | quiet (the drum left at level 0, about 23 dB down) |
| 3 B2B-REV | 0x18 <- DF last, back to back | as loud as PHASE 1 | as loud as PHASE 1 |

PHASE 2 and 3 first set all six levels to C0 one at a time, so a lost 0x18 write leaves the
drum quiet rather than at an earlier loud value. The `LISTEN_*` rows record whether any of the
writes met BUSY (`polls` above 1): a phase whose writes all read BUSY clear at the first poll
was written at bus rate.

## `/OPNA3 /SWEEP`: finding the gap

The `/LISTEN` run on the Xe10 had PHASE 1 loud, PHASE 2 quiet and PHASE 3 loud: the chip keeps
one pending level word, and the 0x18 write is lost when the next level write follows about 10 us
later (24 PIT counts, BUSY polled). `XE10T /OPNA3 /SWEEP` finds the gap at which it stops
being lost. It clears the screen, prints "Listen for the step where the drum turns LOUD", and
runs 20 steps (about 45 s), each:

1. all six levels 0x18-0x1D <- C0 (L+R, level 0), 200 us apart;
2. 0x18 <- DF (the bass drum at level 1F), the gap, 0x19 <- C0;
3. the screen line, in reverse video, `STEP 07  GAP  16 us (actual  16.3 us)`, then 50 ms
   later 4 bass-drum hits 250 ms apart, then a 1 s pause.

Targets: MIN (the smallest gap the program makes), 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 27,
30, 35, 40, 50, 60, 80, 100 us. The gap is measured from the 0x18 data write to the 0x19 data
write: each data write is followed by the same two instructions, `mov al, 0` and `out 77h`
(latch PIT ch0), so the two latched counts are one gap apart, to one PIT count (0.41 us). The
gap holds the first count's two reads, N `out 5Fh`, the BUSY poll, the 0x19 select and its
select-to-data spacing (below); N is
found per step by measuring silent attempts (level writes make no sound without a key) and
keeping the fewest N whose gap reaches the target, so the target is a minimum and the
actual gap is what was measured. An attempt the BUSY poll lengthened is repeated, and kept after
four (the line then ends `BUSY`); `NO-FIT` means 32 attempts did not settle. Targets below MIN
run at MIN. At the end the screen lists every step with its actual gap.

Write down the first step whose hits were LOUD (as PHASE 1), and any quiet step after it. If
the steps turn loud and quiet again, the outcome depends on the write's phase: repeat the steps
around it, e.g. `XE10T /OPNA3 /SWEEP /STEP 7 /TO 10 /O OPNA3S2.TXT`.

**Select-to-data spacing.** Every `/OPNA3` select is followed by `O3_SD5F` (1) `out 5Fh`
before its data write (`sec_opna3.inc`), and the STATE line prints it as `sd5f=`. The YM2608
takes a select through a synchronizer on its internal clock (1-2 clocks of 0.75 us;
YM2608-LLE `fmopna_impl.c` `write0_en`) and latches the address from the last byte on its bus
input, so a data write that follows its select by one I/O access (0.84 us on the Xe10) can
become the address; Yamaha's wait after an address write is 17 master clocks (2.1 us). One
posted `out 5Fh` holds the next access 1744 ns, so the data follows by about 2.6 us. The first
`/SWEEP` binary had no spacing in its pair (no `sd5f=`; the decoder names such a capture
PRE-FIX): on the Xe10 every step was quiet whatever its gap, because the 0x18 select itself was
lost (`docs/probes/XE10T-XE10-OPNA3-SWEEP.TXT`). The B2B and `/LISTEN` writes already had a PIT
read (about 2.5 us) there. With the spacing, what the sweep measures is the chip's pending
level word, which the next register select of any kind drops if the rhythm unit's 9 us turn
has not taken it yet.

## `/RASTER`: reading the picture

The palette is not read back, so `/RASTER`'s evidence is the screen: run `CLS` then `XE10T
/RASTER`, and photograph or capture each 5 s phase (the console shows the phase name as it
starts). `xe10t_decode.py` prints, per phase, the display line its writes land on and, for the
toggle phases, the length of one `out` in dots. What each phase shows under each model:

| Phase | dot-immediate DAC | latched at a line boundary | latched per frame (the core's analogue table until it took writes at once; its digital bytes still) |
|---|---|---|---|
| SPLIT | red above, green below; a short yellow dash on the split line (G=F lands one `out` before R=0) | red above, green below, a clean edge | one colour, whole screen |
| TOGGLE | a grey screen with a band of light-blue/olive dashes, each about one `out` long, staggered from line to line | the band made of whole light-blue or olive lines | plain grey |
| DTOGGLE | a black screen with a band of blue/black dashes | the band made of whole blue or black lines | plain black |

Run it on the core first (the same binary), then on the Xe10 with an analog capture or a
photograph of each phase; commit the capture `.TXT` and the images under `docs/probes/`.

## `/AUDIT`: what each row settles

`/AUDIT` is opt-in (it hooks INT 08h/0Fh/14h/17h and reprograms PIT channel 0, the 0x128 tick
rate and the OPNA's timer B); run it from plain DOS with no sound driver and no resident
timer user, and press no key while it runs (it reads the keyboard data port as a word). It
is refused piecewise: the IRQ0 rows when IRQ0 is unmasked as found, the cascade rows when the
OPNA is absent or INT 60h is hooked. Every value is raw; `xe10t_decode.py` prints the verdict
beside it and NP2kai's prediction where NP2kai has one (`sec_audit.inc` has the references).

| Row | Settles | How to read it |
|---|---|---|
| `W<port>` | what `in ax,P` (and `in eax,P` where `d` is not `-`) returns on an 8-bit port, one port per class of NP2kai's word-read table (`io/iocore16.tbl`) plus the ports guests read as words (0x41/0x43, 0x90, 0x188, 0x642, 0x7FD9, 0xA460, 0x640 last) | `b0`/`b1` = byte reads of P and P+1, `w1`/`w2` = the word, `b2` = P again. EAX holds A55AC33C before each wide read, so an untouched AH reads C3. The decoder lists the shapes the bytes allow (`split` = P then P+1, `AH=FF/00/08`, `AH=old`, `2588`) and marks a row where NP2kai's shape is not among them |
| `P0070`, `P0071` | whether `in ax,70h` / `in ax,71h` consumes a latched PIT count byte | ch0 is loaded in mode 0 with 0x80F0 (so the latch reads 80xx with two different bytes), latched, word-read, then 0x71 read twice; a control word then resets the read sequence. `latch` = `untouched` (x1 is the LSB) or `consumed` (x1 is the MSB 80: AH or AL took the LSB). Refused with the IRQ0 rows |
| `D0001`, `D0000` | whether `in ax,01h` / `in ax,00h` toggles the 8237 byte flip-flop | DMA channel 2 masked and its address loaded with C33C, the flip-flop cleared, the word read, then 0x09 read twice: `ff` = `untouched` (x1 = 3C) / `toggled` (x1 = C3). The address is written back (`was=`, checked by a RESTORE line); the channel stays masked, as the BIOS leaves it |
| `B<port>` | the byte the port reads: 0x1480-0x1487 (the -118 game port), 0x0534, 0xA462/A464/A46C/A46E, 0x043B (after the BIOS's writes), 0x0EE0, 0xE0D2 (MPU-PC98II status: FF = no card) | `v`, `v2` = two reads |
| `IRQ0WD_M`, `IRQ0WD_U` | is a timer request withdrawn when OUT0 falls, masked (IRQWD's case) and UNMASKED with IF=0 | ch0 in mode 3 (8192 counts, about 30 periods in the 100 ms): `withdrawn` = IRR bit 0 rises and falls once a period, `held` = it rises once and stays |
| `IRQ0OUT` | the control: OUT0 itself toggles | rises/falls of the read-back status bit 7 |
| `IRQ0SLOW` | the same seen as lost ticks: deliveries in 0.5 s with a handler that keeps IF=0 for 0, 0.6, 1.2, 1.6, 1.8 periods after its EOI | `held` delivers periods/1.6 (/1.8) at the long delays, `withdrawn` periods/2; the short delays are controls |
| `CALBDA`, `CAL128` | whether the BIOS's 1/32 s counter (0:04F1, INT 17h) runs as found; the as-found 0x128 byte | `d` counts in 0.25 s (8 = 32 Hz) |
| `CAL` | the calendar interval interrupt (IRQ15): deliveries in 0.5 s per 0x128 setting (`AF` as found, 81 80 83 82 00 01, `TP` = the BIOS's power-on TP = 64 Hz command then 81), with a handler that reads 0x128 (`R`) and one that does not (`N`) | the decoder's per-setting line: `one-request-per-tick` (N as many as R: NP2kai), `held-until-0x128-read` (N = 1: the line stays up until the read) or `stopped` (none in either mode, e.g. 82). All zero = the tick never reached the PIC on this machine (IRQWD's IRQ15 row never triggered either) |
| `CASC_CTL`, `CASC`, `CASC_DEV` | does the master withdraw IR7 when the slave's INT drops | `m_on` = master IRR with IRQ12 open (bit 7 set), `m_off`/`m_off2` = after the slave IMR closes it (CASC) or the OPNA flag is reset at the chip (CASC_DEV); after STI, `n17` with `isr_s` bit 7 clear = the slave's spurious IR7 (INT 17h), `n0f` = the master's (INT 0Fh). CASC_CTL is the control: the request delivered as INT 14h |

## `/OPNA4` and `/AUDIT2` (XE10U.COM): what each row settles

| Row | Settles | How to read it |
|---|---|---|
| `OPNA4 BA_nnn`, `BB_nnn` | 155: a timer start written right after nnn BUSY-polled data writes (PMD's opnset44 shape) acts within the machine's idle bound | `pit` = PIT counts from the 0x27 start write to the flag, `bpit` = the burst's duration; the decoder converts to us and holds the start against `/OPNA2`'s TMRA_3FF (70..101 PIT) and TMRB_FF (101..751) on the Xe10: `within`, `partly-above`, `above`; `bpit/nnn` is the machine's per-write BUSY cost |
| `OPNA4 RMAP_C`, `RMAP_O` | 187: what the base data port 0x18A answers for every register 0x00-0xFF, extension closed (0xA460 bit 0 clear) and open | `r<h>0=` 16 bytes per row; the decoder groups the registers into `00`, `FF`, `sel` (the select echoed) and `val` |
| `OPNA4 RD29_O` | 187: 0x29 read before and after each write (1F 03 02 01 00 1F) with the extension open | `pre`/`post`; 0x29 is left at 1F (reboot after) |
| `OPNA4 S3A_A0`..`S3A_C1` | 18 (c) for timer A: `opnapro` STATUS3's rows with timer A running (NA 0, 0x27 <- 15) and 0x110 <- 00 / 1F / 00 | `st188`/`st18C` at once and 100 ms later; bit 0 = the timer A flag; `seen` = the flag rose before A0 |
| `AUDIT2 CALIRR cfg mode` | 114: how long an unread calendar request stays high, and whether the 0x128 read lowers it | `ones/samples` = duty, `e` = the first 12 edges (ARTIC ticks, + rise, - fall), `r128` the 0x128 byte read at the rise (mode R). The decoder's verdict per setting: `held-until-read` (N stays up, R short), `read-lowers` (R highs shorter), `falls-by-itself` (the same in both), `no-request` |
| `AUDIT2 WO0009`, `WO000A`, `WO006C` | 42 (a): where a word OUT's two bytes land | `i0/i1` = the slave IMR before/after, `x1 x2` = the DMA ch2 register read back; shapes `dropped` (NP2kai's word_term), `low-only`, `split` (P then P+1, the core), `both-at-P`. `WO006C`: `a0` = 70 when the low byte reached 0x6C |
| `AUDIT2 W<port>` | 42 (b), (d): as `/AUDIT`'s W rows, for 0x24 0x26 0x34 0x36 0x44 0x46 0x72 0x74 0x75 0x76 0x79 0xA2 0xAF 0x0C24 0x0422 | as `/AUDIT` |
| `AUDIT2 T<port>` | 42 (c): does `in ax,P` fetch P + 1 | `b`/`w` = PIT counts for 1024 byte / word reads (best of 3): `w/b` near 2 = two bus cycles, near 1 = one. 0x0A (two) and 0x60 (one) are the controls |

## `/FDC2`: the floppy controller's answers

`/FDC2` measures what `pc9821_fdc.sv` infers about the uPD765A behind the 1 MB and 640 KB windows
(todo items 59 and 180; its 1 MB rows also settled what the core now answers for a terminal
count, an EOT with none, the reset's interrupt, a command on an empty drive, the DMA-mode MSR and the VFO timer).
Nothing writes a disk: the only commands are SENSE
DRIVE STATUS, SENSE INTERRUPT STATUS, SPECIFY (after a reset only), RECALIBRATE, READ ID and READ
DATA. It first asks the BIOS (INT 1Bh AH=04h SENSE on DA/UA 0x90 and 0x91, with its own IRQ11
handler) which drive holds a diskette (`cls=D`, CF=0) and which is empty (`cls=E`), then masks
IR11 and puts an EOI-counting stub on vector 0x13. `DA 90` / `DA 91` names the disk drive instead.
The disk is any PC-98 1.2 MB 2HD diskette (8 sectors of 1024 bytes); insert it at the DOS prompt
(a disk in the drive at power-on would be booted). Every row is behind its own ROW line; times are
ARTIC ticks from the named write; reboot after a run (the reset rows leave HSFLOP.PDR's SPECIFY).

| Row | Settles | How to read it |
|---|---|---|
| `STATE` | 59: `bda055C` (the BIOS's drive-present bits), both windows' ports in the active mode | 0x055C = 03: both drives present |
| `SENSE`, `UNIT` | 59: an equipped, powered, empty drive | `recal_st0` 28/29 = SE\|NR (NP2kai, the core); 20/21 = the 1 MB interface's RDY pulled up (undoc98) |
| `GEOM` | the disk's N and sectors per track (EOT of the rows below) | `n=03 spt=08` for a 1.2 MB disk |
| `TC_R3`, `TC_MT0`, `TC_MT1` | the result when the DMA's terminal count ends a READ DATA before EOT (R3, a 1-sector count), at side 0's EOT under MT, at side 1's EOT under MT | `c h r`: NP2kai 00 00 01 / the datasheet and the core 00 00 04 for `TC_R3` |
| `EOT_NT`, `EOT_MT` | a count larger than the track: EOT reached with no terminal count | `st0 st1`: 00 00 (NP2kai, the core) or 40 80 (IC=01 EN, the datasheet); `dmacnt=03FF` = one sector left |
| `IRQHOLD` | after a READ DATA's result is read with no SENSE INTERRUPT STATUS, is IRQ11 still requested | `irr_res`/`irr_10ms` bit 3, `irq_unmask` = deliveries in 10 ms unmasked: 1 = held (NP2kai's latched IRR), 0 = withdrawn (the core) |
| `VFO` | the BIOS's hand-back 0x94 <- 09, 0C alone (TTRG then TMSK) | `rises`/`t_irq_art` in 400 ms: undoc98's VFO timer interrupt 100 ms later would read ~30720; `sis` says whether the FDC had a status |
| `DMA_REF`, `DMA_MSR`, `DMA_92` | MSR and the data port during a DMA-mode data phase | `msr=vv:count:first_t,...` every distinct MSR value; `diff`/`first` = bytes differing from `DMA_REF`; `rd92=value@count` the four 0x92 reads; `dmacnt` FFFF = every byte reached the DMA |
| `NRID`, `NRRD`, `NRID_U2` | READ ID / READ DATA on the empty drive, READ ID on unit 2 | `end` I (IRQ11) / D (a result phase) / T (2 s, neither: then an `NRREC` reset row); `nres` result bytes, `sis` the SENSE INTERRUPT STATUS answers |
| `RST_M`, `RST_NM` | 0x94 <- 98, ten 0x5F, 18 (HSFLOP.PDR's reset) and 90/10 (motor bit clear) | `t_irq_art` from the 18/10 write (315 = the datasheet's 1.024 ms poll, ~33000 = NP2kai's 6 frames), `sis` until 80 (C0..C3 = every unit polled ready), `rises` within 500 ms |
| `M640` (`/M640`) | 180: port 0xCC bit 4 after SENSE DRIVE STATUS, per unit, motor on (0xCC <- 08) and off (00) | `cc=value:t,...` 0xCC at once and at each change for 20 ms (74 = bit 4 set) |
| `RST640` (`/M640`) | the reset's interrupt on the 640 KB window (IRQ10) | as `RST_M` |

The decoder prints each row's fields beside NP2kai's, the core RTL's and the datasheet's value
(`=` match, `x` differs), and in a machine-vs-core comparison a `FDC2` table with NP2kai's value
beside both captures. The core's captures of the same binary are in `docs/probes/core/`
(`XE10T-FDC2-CORE-*.TXT`).

## The capture grammar

```
XE10T v1 sha=<16 hex> crc=<8 hex> imgcrc=<8 hex> size=<n> build=<text> args=<tail> tag=<text|->
BEGIN:<SEC>
R <SEC> <TAG> unit=<u> n=<units> nop=<k> rep=<r> art=<min>/<med>/<max> pit=<...> ctl_art=<...> ctl_pit=<...> shell=<4 hex> bshell=<4 hex> if1=<ticks> [to=<n>]
P <SEC> <TAG> key=value ...        period / edge measurements (CAL)
T <SEC> <TAG> trials=<n> <field>=<min>/<med>/<max> ...
X <SEC> <TAG> i=<k> key=value ...  a raw trial
I / STATE / SKIP <SEC> reason=.. / TIMEOUT <SEC> <what> elapsed=<ticks> / WATCHDOG <SEC> elapsed=..
ROW <SEC> <tag> [port=<4 hex>]     written and committed before the row runs (not counted in rows=)
RESTORE <SEC> <what> was=<hex|-> now=<hex|-> kind=<readback|default|self> <OK|FAIL>
FAULT <SEC> after=<SEC> / SELF <name> <OK|FAIL> / PLAN <SEC> ...
END:<SEC> rows=<n> sum=<4 hex>
XE10T DONE sections=<n> sum=<8 hex>
```

- `art` = ARTIC ticks (3255.208 ns), `pit` = PIT ch0 counts reduced modulo CAL's `pit_mod`
  (the decoder unwraps a longer window with the ARTIC). `n` = accesses per window; gross
  ns/unit = art x 3255.208 / n. `if1` = one more body window with interrupts ON (R18): the
  decoder flags IF1-NOISE when it differs from the `cli` median by more than 2 %.
- In P rows `edges=<n>` is the number of whole periods between the first and the last edge.
- `/OPNA2` rows are X/T rows with raw hex bytes (`st=`, `id=`, `irr0=` ...) and counts. A BUSY
  class prints `X OPNA2 <tag> i=H polls_h=<9 counts> pit_h=<16 counts>`: the poll bins are 1, 2,
  3, 4, 5-8, 9-16, 17-32, 33-64, 65+ (a timed-out trial, 65535, falls in the last), the
  `busy_pit` bins are 8 PIT counts wide with the last one 120+. A second base's rows carry the
  base as a tag suffix (`BUSY_FM30_288`, `TMRA_3F0_088`). The decoder prints a verdict per base
  (YM2608 / YMF288 / YM2203-like / absent, the 0xA460 gate, stray status bits), the per-class
  histograms, the flag-reset and IRQ12 times in us, the timer fit (us per count against the
  nominal 18.029 / 288.46 us, intercept = start latency plus one poll) and the ADPCM-B response,
  and emits them as `.expect` lines.
- `/OPNA3` rows: `BUSY_RHY18` in the `/OPNA2` BUSY format; `X OPNA3 B2B_RHYLVL i=<k> dly=<d>
  polls=<6> pit=<6> dd=<6>` per trial (comma lists in write order; `dd` of the first write is
  0), `i=H w=<0-5> reg=<xx>` and `i=H w=all` histograms in `/OPNA2`'s bins, `T ... trials=32
  writes=192 busy_pit= polls=`; `X OPNA3 LISTEN_<phase> regs=<6> slow=<0|1> polls= pit= dd=
  [pre_polls=] keys=8`; with `/SWEEP`, `I OPNA3 SWEEP_PLAN ratio_x1000= from= to= gaps_us=<20>`
  and per step `X OPNA3 SWEEP step= gap_us= tgt= pit= n5f= tries= busy_tries= fit= p18= p19=
  pa= pa_pit= keys=4` (`pit` the measured gap and `tgt` its target in PIT counts, `n5f` the
  `out 5Fh` in the gap, `fit` 1 = the fewest reaching the target, 2 = kept after four
  BUSY-lengthened attempts, 0 = out of attempts; `p18`/`p19` the polls before each select, `pa`
  and `pa_pit` the BUSY wait after the 0x19 data write). The decoder prints the BUSY share per write position, the write
  spacing and, per `/LISTEN` phase, what each sound means, and the `/SWEEP` steps as a table
  (target, actual gap in us and counts, attempts, BUSY); `.expect` lines carry
  `OPNA3.<tag>.busy_writes`, `first_clear_pct`, `busy_max_us`, `spacing_us` and
  `OPNA3.SWEEP.stepNN.gap_us`.
- `sum` of a section = CRC-16/CCITT-FALSE over its body lines (after the BEGIN line, before
  `END:`), CRLFs included; `rows` counts the R/P/T/X lines. The DONE `sum` = CRC-32 (zlib) over
  every byte before `XE10T DONE`.
- The stamp block in the image: `XE10T-STAMP-V1:#`, 16 sha digits, 8 crc digits (ASCII `0` in
  the assembled image), then a little-endian word L. sha = SHA-256 of the image with the 24
  digits as `0`; crc = CRC-32 of the first L bytes of that image (the constant part; the
  program's variables follow it, so its run-time `imgcrc` covers the same bytes).

## The decoder

```
python3 tools/hwprobe/xe10t/xe10t_decode.py XE10T.TXT                 # check + tables
python3 tools/hwprobe/xe10t/xe10t_decode.py MACHINE.TXT CORE.TXT      # side by side (--band 10)
python3 tools/hwprobe/xe10t/xe10t_decode.py XE10T.TXT --emit-expect XE10T-XE10.expect
python3 tools/hwprobe/xe10t/xe10t_decode.py XE10T.TXT --binary XE10T.COM
python3 tools/hwprobe/xe10t/xe10t_decode.py --selftest
```

It never parses RTL; benches cite the `.expect` file (`name value unit source=<capture>:<line>
method=<...>`). Exit 0 = clean, 1 = an integrity or trust flag (truncation, a bad checksum, a
control mismatch, a failed restore, a watchdog, CAL FAIL), 2 = usage or a refused comparison.

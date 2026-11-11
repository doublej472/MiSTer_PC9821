# hwprobe - measuring a real PC-9821

DOS `.COM` programs that measure a real PC-9821, so the core's behaviour can be checked
against the machine rather than against an emulator. Their captures are kept in
[`docs/probes/`](../../docs/probes/), and benches cite those captures as the source of
their expected values. Only the probes whose captures (or whose decoders) are still cited
are kept here.

## Building

```
make -C tools/hwprobe            # every probe; or e.g. make -C tools/hwprobe ioprobe/ioprobe.com
make -C tools/hwprobe clean
```

GNU `as`/`ld`/`objcopy` (32-bit i386 support) are all that is needed. The build is
reproducible (same source, same bytes), and it refuses an image over the 65,280-byte DOS
`.COM` limit. The binaries are not committed. `pegcwatch` builds as `PEGCW.COM` (8.3 name).
`cpusuite` is the exception to the toolchain: it is NASM (as z486's test programs are), and its
pack is generated from the suite by `cpusuite/gen_cpusuite.py` into `cpusuite/build/` (ignored).

## The probes

Each tool lives in its own folder: `<tool>/<tool>.s`, an optional `<tool>_decode.py`
(the capture decoder) and a `RUN*.BAT` (the DOS batch that runs it and redirects its output).

| Probe | What it measures | Capture |
|---|---|---|
| `probe2` | the general section-selectable probe: port sweep, memory windows, ROM shadow, VRAM/CG, GDC, EMS, game port, memory switches; write-then-read sections (`/RDBACK`, `/PIT`, `/VSYNC`, `/WIPE`) are opt-in and print a `PORT: was -> now` restore report. `wipe_decode.py` decodes `/WIPE` | `R10`, `PORTS`, `WIN`, `SHADOW*`, `VRAM*`, `GDC`, `RDBACK`, `PIT*`, `VSYNC`, `WIPE-rerun`, `EMS`, `JOY`, `MEMSW`, `ATA`, `TIME`, `TRS` |
| `ioprobe` | per-port I/O access cost for every class the core's I/O wait table names, each beside an interleaved control row; absolute ns against the ARTIC counter | `IO.TXT` |
| `ideprobe` | the IDE/ATA interface: bank select, task-file read-back, IDENTIFY, DIAG/reset error bytes, the IDE IRQ | `IDE.TXT` |
| `idelat` | IDE READ latency: command -> first DRQ, per-sector PIO, throughput, poll cost; read-only on disk; self-checks its two time bases | `IDELAT*.TXT` |
| `gfxbench` | raw VRAM/TRAM window bandwidth (`rep stosw`/`rep lodsw`) | `GFXB.TXT` |
| `gfxbenc2` | per-operation GVRAM drawing latency: plane writes, GRCG, EGC, text, net of loop-shell controls | `GFX2*.TXT` |
| `egcplane` | EGC time vs enabled planes: 0x4A0 set to 1/2/3/4 planes on fill, ROP-feed, put and shifted-copy shapes, net of loop-shell controls; decides plane-serial vs plane-parallel (`egcplane_decode.py`) | `EGCP.TXT` |
| `irqwd` | whether a masked 8259 request is withdrawn or held after the device is acked (keyboard, IDE, OPNA, calendar, PIT) | `IRQWD.TXT` |
| `opnapro` | PC-9801-86 OPNA register read-back | `OPNA.TXT` |
| `sndtest` | the OPNA audio-calibration stimulus: fixed segments of known register state (FM/SSG level and frequency sweeps, rhythm) paced by the ARTIC counter; record the line-out while it runs. `tools/sndtest_check.py` checks a transcript, `tools/sndtest_balance.py` measures recordings | `SNDTEST-*.txt` |
| `pegcwatch` | `PEGCW <program>`: runs a child and reports the PEGC (256-colour) state it leaves behind | `PEGC.TXT` |
| `memmap` | what the memory-size chain tells a DOS extender (BDA, XMS/EMS/VCPI/DPMI answers, the 15-16 MiB system space) | - |
| `txtmode` | the text plane's row geometry, as PICTURES: one fixed TRAM pattern shown in seven states (25/20/30 lines, 2 and 4 display partitions, a smooth scroll held at start word 240 + SSL 7, a SUR/SDR scroll region), a key per state; photograph each state on the machine and compare with the core's screenshot. `/T` holds each state 450 VSYNCs; `/D` (`txtmode_d.inc`, todo item 128; no keys, about 2 min 20 s, for a film with the scaler's mode overlay) first asks what loads the text pitch (P1-P7: SYNC with C/R 0x4E/0x4C/0x3E, the display-off SYNC, PITCH before and after SYNC, INT 18h after both), then shows states 3-7 with PITCH 80 after every SYNC block and an SSL sweep under SUR 29 / SDR 9, each step named in rows 0 and 3, and logs per step the bytes it sent, the CRTC and BIOS work bytes, the GDC status and CSRR answer, the frame and line rates and TRAM CRCs (`txtmode_decode.py`) | `KIT2-*-TXTMODE.TXT` |
| `a20map` | how the A20 mask treats physical addresses above 1 MiB | `A20MAP-XE10.TXT` |
| `d8bank` | what the `0xD8000` window holds for each `0x063C` bank select | `D8BANK-XE10.TXT` |
| `fdmode` | the floppy interface mode after boot (0x00BE, the PIC masks, the 0xC8/0xCC window, the disk work bytes) and INT 1Bh SENSE on DA/UA 0x90 and 0x70 | `FDMODE-XE10.TXT` |
| `dmaroute` | where a uPD71071 DMA byte lands when its address is in a window that is not plain RAM (the DMA-routing entries of `todo/6-memory.md`): the 0x043F EMS page and its unmapped state, the PEGC 256-colour packed banks, B8000 and the E0004 bank registers, the 0x0461 window at 0x0A and 0x10, the CG window over a user glyph, and a plain-RAM control. The DMA source is the floppy (READ DATA of C0 H0 R1, channel 2, cut short by the DMA's terminal count; the disk is only READ). Each case runs once with a CPU copy and once with the DMA, and reads every view (the window, an alias, the storage under it) before and after; `dmaroute_decode.py` classifies each view and says whether the DMA went where the CPU went. Plain DOS, no EMM386; run from the hard disk with any readable disk (2HD, 1.44 MB or 2DD) in drive 0 or 1: the probe scans DA/UA 0x90, 0x91, 0x30, 0x31, 0x10, 0x11 (`DA=xx` first), each through the BIOS and then the controller by hand (ST3 before and after the motor-on and a 500 ms ARTIC spin-up, RECALIBRATE, READ ID), prints a DISK and a DIRECT line per try and USING DA=xx, and hands the motor back to the BIOS's own timeout | - |
| `cpusuite` | CPU correctness: runs z486's own self-checking test programs (`src/z486/tests/programs`) on the machine, each entered in the bench's start state with all of DOS below 0x9F000 moved to XMS and back; the verdict returns through the CPU-reset path (port 0xF0 + `0000:0404`). NASM; the pack `CPUSUITE.BIN` is generated by `gen_cpusuite.py` (classification in `build/CPUSUITE.LST`). Needs HIMEM and no EMM386. FAIL rows carry the program's last port-0xE4 value and its EAX at the verdict; a `CPUSUITE CPU` row records the reset signature (EDX) and CPUID. `/FROM` and `/SKIP` resume past a lock-up (below). Used by `tools/mister_regress.py`'s `cpusuite` item | - |
| `crt31k` | the 31 kHz dot clock: times VSYNC (master GDC status bit 5) against the ARTIC in the as-found 24 kHz mode, then with 0x09A8 bit 0 set and the BIOS's 31 kHz master SYNC table (HSB.EXE `IGDC:31`'s sequence), then restored; `crt31k_decode.py` gives frame/line/dot rates, the 24 kHz rows calibrating the method against 21 052 600 Hz. Reboot after running | - |
| `crt24k` | the 24 kHz guest frame against TWO references in the same run: VSYNC timed with the ARTIC and with PIT channel 0 (its counting modulus, element/ARTIC ratio and the 0x0501 strap measured, so a free-running 65536 counter and the 0x6000/0x4E00 divisors both work), 60 frames x 3; `crt24k_decode.py` prints both frame rates and the PIT-vs-ARTIC ppm, which says whether an ARTIC-only frame reading (`crt31k`) is the frame or the ARTIC crystal | - |
| `pegcrd` | the PEGC 256-colour palette read-back: writes a six-entry pattern in the 16-colour analogue and `0x6A` dat `0x21` 256-colour modes, reads 0xAA/0xAC/0xAE back, prints the mode/0x9A0 readbacks; `pegcrd_decode.py` classifies byte vs 0 (NP2kai vs MAME; the Xe10 capture in `docs/probes/PEGCRD-XE10.TXT`) | - |
| `grcgpace` | the walk-bound GRCG shapes: 16- and 32-bit RMW stores and TDW `rep stos` bursts, with the plain 16-/32-bit stores and a loop-shell control, 65 536 stores x 3; ns per store beside the core's T68 numbers (`grcgpace_decode.py`) | - |
| `tcrpm` | the GRCG store/tile-reload order in Viper CTR's protected-mode column RLE loop (TDW `stosb`, four `outsb` to 0x7E, a TCR compare of the byte just written): 2000 columns of known tiles, the loop's exit and every written row's planes checked, in six loop shapes; a correct core prints zero errors (an earlier core failed ~98% of columns from 80 MHz up). NASM, 32-bit protected mode; plain DOS, no HIMEM/EMM386 | - |
| `sdshmoo` | the SDRAM window on the card it runs on: on a `--dbg-sdram-phase` build, steps the SDRAM_CLK phase outward from nominal (ports 0x5FF0/0x5FF2) and runs a nine-pattern stress over all extended memory at each step from GVRAM-resident protected-mode code, logging errors per chip half and failing DQ bits to `SDSHMOO.TXT`; on any other build, a nominal-phase whole-memory RAM test. `sdshmoo_decode.py` gives the window per chip half; procedure in `docs/sdram-margin.md`. NASM; plain DOS, no HIMEM/EMM386. Runs on the core only (the ports exist only in that test build) | - |
| `gdcfig` | the graphics GDC's figure drawing: a deterministic picture of lines, octant-arc circles and DM partial arcs, rectangles (straight and turned), an area fill crossed by COMPLEMENT/CLEAR/REPLACE lines, patterned lines, dots and 8x8 GCHRD characters (zoom 1/2/4, slanted, two directions, through the GRCG), drawn with FIGS/FIGD/GCHRD and left on screen until a key. `gdcfig.s` is GENERATED by `gdcfig_gen.py` (every figure's datasheet parameters); compare a photo or capture of the machine's screen with the core's screenshot (todo item 126) | - |
| `xe10t` | the unified timing probe (`XE10T.COM`, several include files): one harness and one timer library for every guest-visible access cost - CPU rates, GVRAM/GRCG/EGC/PEGC/TEXT memory (posted writes as nop spacing sweeps, controls generated byte-identical minus the access), every I/O port class, IRQ entry, OPNA BUSY, the PCM86 FIFO, the IDE, and opt-in the floppy, the CD, the palette and `/OPNA2` (which sound chip answers at 0x188/0x288/0x088, BUSY per write class, flag-reset/IRQ12 and timer-start latency, ADPCM-B) and `/FDC2` (the floppy controller's answers: the result after a terminal count, what holds IRQ11, the reset's interrupt, a command on an empty drive, MSR during a DMA data phase, port 0xCC's RDY in 640K mode) and `/OPNA3` (the rhythm level and key writes back to back as MDRV2 writes them, BUSY per write; `/LISTEN` adds bass-drum phases that tell by ear whether every back-to-back level write lands; `/SWEEP` steps the gap between two level writes to find, by ear, the shortest at which the first one survives); a calibration gate (ARTIC vs PIT vs VSYNC vs TSC), per-section CRCs, an identity stamp, ARTIC deadlines, a watchdog and a RESTORE report. `/ALL`, per-section flags, `/SELFTEST`, `/DRY`; opt-in `/RASTER` paints the visual raster-palette test (when a palette write reaches the screen; the Xe10's run is docs/probes/XE10T-XE10-RASTER.TXT). Supersedes the timing probes `gfxbench`, `gfxbenc2`, `egcplane`, `grcgpace`, `ioprobe`, `idelat` and `probe2`'s `/WIPE` W1/W5/W6 and `/TIMEREF`, which are retired once an Xe10 capture exists and their citations have moved to its `.expect` file. `xe10t_decode.py` checks, tabulates, compares (core vs machine, same binary only) and emits the `.expect` file; details in [`xe10t/README.md`](xe10t/README.md) | - |
| `integ` | storage-path integrity: hashes files on the hard disk, floppy and CD and compares them with a manifest built from the image (`integ_manifest.py`). Used by `tools/mister_regress.py`'s `probe` mode | - |
| `rstdtr` | IDTR/GDTR (and EDX, CR0) straight after the PC-98 CPU-only reset (out 0xF0, SHUT0 clear, the firmware's return through 0000:0404), without the POST (todo item 53); everything put back; `rstdtr_decode.py` | - |
| `rboot` | the software reboot Windows 95's WIN.COM performs (leaving MS-DOS mode, Shut Down > Restart), byte for byte: the 8255 mode word and BSR bytes that set SHUT0/SHUT1, NMI off, both GDCs blanked, a settle loop and `out 0xF0`. `RBOOT` asks for a key first (Esc quits), `RBOOT /Y` does not. A correct machine or core re-runs its POST and boots again; a screen that stays black is the failure. Plain DOS, any memory manager. The reset-set variant (todo item 170): `RBOOT /S` saves the 0x053D/0x043F/0x0461/0x0463/0x063C/0x1E8E/0x0432/0x0642/0x074C/0x0534 read-backs and the 0xF8E8F-0xF8E91 bytes to `RBOOT.TXT`, moves 0x063C, 0x1E8E and a 0xF8E90 marker (read back, put back, read again), and reboots with them moved; `RBOOT /R` at the next DOS prompt appends the same set. No SMARTDRV (the file must reach the disk before the reboot). `xe10cfg/xe10cfg_decode.py --rboot` tabulates it | `RBOOT.TXT` |
| `xe10cfg` | the configuration stores (todo items 172, 94, 110; the DIP-switch questions): the BIOS SETUP record and the software-DIP mirror in CG RAM (read through 0xA1/0xA3/0xA5 -> 0xA9, SETUP's own addressing), both software-DIP banks (0x8F1F bank select, left at the firmware's resting 0x80), the DIP-switch and SETUP-driven ports (0x31, 0x42, 0x00BE, 0x7FDB/0x7FDD/0x7FDF, 0xA460, 0x0C24/0x0C2B/0x0C2D, 0x0F40-0x0F4F, 0x188-0x18E, ...), the memory-switch cells. Read-only by default; `/WR` makes the write-then-read round trips (0x31, 0x871E, 0x851E, 0x881E, 0x8B1E, 0x9A8, a 0x68 mode write, the 0xDC000 work RAM under 0x1E8E = 0x81), each put back at once; `/MSW5 xx` writes memory switch 5 on purpose (it is meant to survive a reset; `/MSW5 01` puts the measured value back). `xe10cfg_decode.py` decodes a capture (the record checks, ~row 2 vs port 0x31, the mirror vs the ports) and `--diff A B` lists what one SETUP change moved. The 2026-11 kit added (`xe10cfg_ext.inc`): a CPU line (MSW, CR0, SIDT/SGDT, the FPU's FNINIT answer), `[0:59A]`, `/WR` rows for 0x68 with the display off and 0x6C; `/CG` (read-only: the whole user-CG store through the 0xA4000 window, the record as the ITF reads it, the saved-table length, even offsets, the 4 KiB repeat, word reads, port vs window, and the two-byte ten < 0x20 table as CRCs that `--font FONT.ROM` locates); `/CGWR` (writes code 0x7E57 at every window offset, puts it back, proves the store unchanged); `/IDE` (0x0432 sweep, 0x074E with the slave selected, 0x0433 with an interrupt pending); `/W4A0` (the EGC word read, flagged: run last, power-cycle after). Kit 2 added: `/CG`'s two-byte table also at ku 0x29/0x2C/0x78 (the video-xe10 lane's CG rows); `/IDE2` (0x0432 <- 04 06 07 10 20 22 23 40 with the task file read at each, CHECK POWER MODE with 0x0432 = 02, 07, 01 (0x0433 read at 01 and 00 while it pends) and on bank 0 with nIEN set; only the command register of a task file is written, the bank put back in every row); `/6C` (0x6C <- 80 F0 FF 70, each read back and held 3 s for the camera, then 00); `/FD` (BDA 0x055C and 0x0564-0x0583 as the boot left them, then 0x94 <- 09, 08, 200 ms, 0C: does IR11 rise; reboot after) | `CFG*.TXT` |
| `mputest` | the MIDI card (MPU-PC98 / MPU-PC98II, the core's MPU-PC98II model): the option-window scan, reset ACK and latency, the card's IRQ line (IRR with the ACK pending), DRR/BUSY while a UART-mode stream is written at full rate, labelled MIDI sequences to follow on a GS synth (GS reset, SC-88 Pro display text, scale, chords, running status, drums, long SysEx, pitch bend, all notes off, intelligent-mode 0xD0/0xDF), `/BYTES` (a fixed table for a byte-exact MIDI OUT comparison) and `/RAW` (a blind burst). Its op tables are generated by `mputest_decode.py`, which also decodes the capture and compares a wire capture with the NP2kai reference stream; `tests/pc9821/tb_pc9821_mpu_probe.sv` runs the same `/BYTES` script on the core. Details, the expected differences and the MPU-PC98 vs MPU-PC98II notes in [`mputest/README.md`](mputest/README.md) | `MPUTEST.TXT`, `MPUBYTES.TXT` |
| `risky` | the write-then-read rows earlier kits left out (todo items 28, 35, 97, 98), one item per run, a power-cycle after each: `/43F` writes 0x043F with every value (the read-back, the F8000 bank and B0000 views, the firmware state put back; ROW lines committed first, so a re-run with the same `/O` file resumes after a value that hung), `/989` writes 0x9890/9892/9894/9896 and then the ITF's 0x98E0 <- 05 and times a CPU loop after each (a moved clock), `/461` compares the 0x0461 window at low pages with the same memory read directly (alias or hole), `/43B` reads the 15-16 MiB system space in unreal mode with 0x043B bit 2 and bit 3 flipped. `risky_decode.py` tabulates a capture | `KIT2-*-RISKY-*.TXT` |
| `selfmod` | a store into the prefetch window (todo item 141): for each store form (`mov byte [imm]`, `mov [bx],ah`), start alignment 0-15 and distance 1-40, generates `store; nops; mov al,imm8; ret` and reports whether the old or the new immediate ran (O/N), fresh and warm. CPU only; run the same binary on the core at each clock ratio. `selfmod_decode.py` gives the first distance the store is seen and `--compare` two captures | - | `SELFMOD /2` (kit 2, the cpu-xe10 lane's rows) runs the other store forms: A2D `mov [disp16],al`, BI8 `mov byte [bx],imm8`, BD8 `mov byte [bx+d8],imm8`, W16 `mov word [disp16],imm16`, and P1I/P2I/P3I the IMM form after 1/2/3 register-only instructions |
| `ym29` | whether YM2608 register 0x29 (the IRQ enable) gates the timer interrupts, bit by bit (answered NO-GATE for both timers on the Xe10: v1 `docs/probes/YM29-XE10.TXT` for Timer A, v2 `docs/probes/YM29B-XE10.TXT` for both): finds the OPNA at 0x188/0x288 (status, chip ID at register 0xFF, the 0x0E/0x0F/0x29 data-port reads), then for 0x29 = 1F (control), 03, 02, 01, 00 (and the as-found read when it is a value) and 1F again runs Timer A (NA 0x200) and then Timer B (NB 0xE0, the same ~9.5 ms period) for two 61440-ARTIC-tick windows each: one with INT 14h hooked and IRQ12 open (interrupts counted), one masked with the status flag and the slave IRR bit 4 polled; PIT channel 0 is latched raw at each window's ends. Saves and restores the vector, both IMRs and the OPNA timer registers (0x29 is left at its reset value 1F: reboot after it). `ym29_decode.py` prints a verdict per timer (GATES: the die model, qemu and ymfm; NO-GATE: NP2kai) and reads v1 captures too | `YM29.TXT` |
| `fdwrite` | not a probe: a floppy WRITER for the real machine. `FDWRITE image.FDW 1|2 [/Y] [/NF] [/V]` formats each track of a 2HD disk through the DISK BIOS (INT 1Bh 0Dh) with the image's own sector IDs, order, N and density (FM or MFM), writes it, reads it back and compares, three attempts per track, and stops on the first failure; only floppy units 1 and 2 (DA/UA 0x90/0x91) can be named. `/NF` writes into an existing format (the core's D88 media cannot be FORMATted), `/V` only verifies. `d88tofdw.py` converts a D88 into its `.FDW` track container and refuses a track the BIOS cannot format (sector count other than the BIOS table's, R not 1..n, mixed N/density, deleted marks, recorded errors); `info`, `compare` (two D88s, per sector ID/order/density/data), `blank`, `empty`, `--selftest` | - |
| `rwipe` | a game's own phase timeline in its real environment: `RWIPE [/T:tag] [/N] [/C] [/S] [/B] [/P] prog` runs the program, and at its first INT 18h AH=41h, when five hashed code windows match, patches three far calls into a RAM copy of the C-Lab logo program so each of its 99 sine-wipe steps is stamped with the ARTIC (start, after the GVRAM fill, after the 100 rows, after the flip); the hardware IRQ vectors 08h-17h are wrapped during the wipe (count and time per vector), INT 60h/64h calls are logged. `/B` runs the game's shell and ends it at the next program's EXEC, so the shell's own driver chain is resident; `/P` also runs the opening program (OP.COM) up to just after its music stop, logging its DOS calls (CHDIR, open, read), INT 18h mode/text calls (the 0Dh..0Ch bracket is its CG glyph upload), every disk BIOS call and critical error, and its INT 60h/64h calls, so the logo voice's start and stop are in one row (one hashed-window patch turns its post-load `jnc` into its own error exit); `/S` stubs the music driver; `/C` runs the wipe with interrupts off; `/N` patches nothing. Appends to `RWIPE.TXT`; `rwipe_decode.py` tabulates it. `mkrwipe.py` builds the one-boot CF kit image (the user's game files, never committed) | - |
| `speed` | the core's effective speed against the machine's, the SAME binary on both (`SPEED > SPEED.TXT`, about 10 s, plain DOS, no EMM386): the gate's own Dhrystone 2.1 (`src/z486/tests/dhrystone`, built by its Makefile with its CFLAGS at 10000 and 100000 iterations; `speed/spd_start.S` replaces the bench's port-signalling startup and `speed/mkblob.py` turns its two MARK port writes into INT 40h) run in 32-bit protected mode from conventional memory and timed between its own marks, with its own validation result; then loop rows timed with the ARTIC, three trials each: a dec/jnz shell, 4 register ops, `in al,dx` at 0x02 and 0xA0, `rep movsd`/`stosd`/`lodsb` in RAM, `rep stosb/w/d` over the 32 KiB blue plane and `rep stosw` over 4 KiB of text VRAM below the 25 visible lines (both saved and put back); a PITCAL row checks the ARTIC against PIT channel 0. `speed_decode.py` gives Dhrystone/s (and the slope between the two counts), ns/op net of the shell, MB/s, and B's speed relative to A's for two captures of the same binary | `KIT2-*-SPEED.TXT` |

## The Xe10 kit

`tools/hwprobe/xe10kit1/mkkit1.py --base <earlier kit image> --out <new image> [--xe10t <XE10T.COM>]` builds the 2026-11 kit 1 (its batches, MENU and owner README are in the script; the image holds NEC's DOS and is never committed).

`tools/hwprobe/xe10kit2/mkkit2.py --base <kit 1 image> --out <new image> --xe10u <XE10U.COM> --games <dir> [--xe10t <XE10T.COM>]` builds kit 2: the SPEED reference, XE10U `/OPNA4` and `/AUDIT2`, `TXTMODE /D` and three games filmed in one video, then the RISKY writers, each followed by a power-cycle prompt. Its state machine is kit 1's plus a CONFIG.SYS per step (a game runs under its own image's drivers: `SETCFG` copies the step's CONFIG and reboots before the step's flag is written). `<dir>` holds the game folders the user extracts from their own library images (the script's header names them); the image holds NEC's DOS and the games, so it is never committed. `gtimer` (`GTIMER n`, not a probe) ends a game step: it stays resident with its own tick (PIT channel 0 on INT 08h, IR0 unmasked) and also wraps INT 0Ah/15h/18h/1Bh/21h/33h, and after n seconds of ARTIC time, at a call made while DOS and the disk BIOS are idle, makes RBOOT's software reboot.

`make -C tools/hwprobe kit KIT_DIR=<dir>` assembles one session's worth of probes for the real
machine: `A/` (the DOS session: XE10CFG, RBOOT, FDMODE, PROBE2, MPUTEST, SNDTEST and the
`xe10kit/A/RUN*.BAT` batches, one per step), `W95/` (the files for the 720 KB disk of the
Windows 95 floppy checks) and `RUNLIST.TXT` (`xe10kit/RUNLIST.TXT`: what to copy and connect,
the SETUP change before each boot, the batch to run after it, what to listen for, and the files
to bring back). The kit is build output and is not committed. `xe10kit/mkimg.sh` turns it into a bootable
hard-disk image (8 heads x 17 sectors, the Xe10 IDE BIOS's layout) from a disk the user's NEC
MS-DOS 6.20 FORMAT has partitioned and made bootable (the steps are in the script's header):
it boots into `A:\KIT` and prints `xe10kit/IMG/MENU.TXT`. The image holds NEC's DOS, so it is
never committed.

## Running a probe

1. **Run a new or changed probe on the core first.** It must finish and restore what it
   touches; only then is it fit for the real machine.
2. Boot the machine fresh to a plain DOS prompt (no EMM386 unless the probe says otherwise),
   copy the `.COM` and its `RUN*.BAT` to the disk, and run the batch; it redirects stdout to a
   `.TXT`. DOS filenames are 8.3 and `.BAT` files must be CRLF (`unix2dos`).
3. Copy the capture off before the next step, and run the SAME binary on the core so the two
   captures are comparable. A probe that wraps another program (`pegcwatch`) must be run from
   that program's own directory.
4. Commit raw captures under `docs/probes/` unmodified (CRLF and all) and decode them with the
   tool's `_decode.py`.

Write DOS files as bytes. Audio comparisons need a recording discipline: set levels before the
run, keep AGC/limiters off, and compare within-recording ratios (`tools/sndtest_plateaus.py`,
`tools/sndtest_balance.py`).

### CPUSUITE on the real machine

`CPUSUITE [/P:n] [/A] [/FROM:name] [/SKIP:name ...] [name]` (the usage comment at the top of
`cpusuite/cpusuite.asm` is the full reference). Copy `CPUSUITE.COM` and `CPUSUITE.BIN` to the
disk and boot without EMM386 (HIMEM only). Each row of `CPUSUITE.TXT` is committed before its
program starts, so a program that locks the machine leaves its name as the last row with no
verdict. To run the rest of the pack after that, reboot and resume from it and skip it:

```
CPUSUITE /FROM:debug_task_ibp /SKIP:debug_task_ibp
```

`/FROM`, `/SKIP` and `/A` APPEND to the existing `CPUSUITE.TXT` (a new `BEGIN ... FROM=name`
row), so the first run's rows stay in the file; a plain `CPUSUITE` replaces it. Every program
named in a `/SKIP` gets the row `<name> SKIP` and the END row ends ` SKIP=s`. Up to 16 `/SKIP`s;
a value follows `:`, `=` or a blank; an unknown name stops CPUSUITE before it writes anything.
Copy `CPUSUITE.TXT` off the machine between runs anyway.

A FAIL row reads `<name> FAIL verdict=FF data=xxxxxxxx eax=xxxxxxxx`: `data` is the whole EAX
at the program's last write to the bench's data port 0xE4 (`none`: it wrote none; an 8- or
16-bit write is its low byte or word), `eax` the EAX the verdict write was made with (absent
when the program reset without a verdict). Both travel through DMA channels 0/1's address and
count registers, which the harness restores (`cpusuite/prelude.inc`, "THE DETAIL REGISTERS").
The `CPUSUITE CPU` row after BEGIN gives `ac` (EFLAGS.AC toggles: a 486), `cpuid`
(`none`, or the vendor and leaf-1 signature), `bda486` (the firmware's boot-time copy of the
reset DX at 0000:0486), `detail` (`dma`, or `none` when the DMA registers do not read back)
and `resetdx` (EDX after a CPU reset: the component ID); a row ends ` resetdx=` only when a
program's reset gave a different EDX.

`cpusuite/triage/` holds the sources of the `tri_*` programs that
`docs/probes/CPUSUITE-XE10-triage.TXT` names: variants of suite programs and new probes, each
made to end FAIL so its row carries `data=`/`eax=` (the first comment line of each says what
they hold). The 26-program pack of that capture was built by copying them into the
`tests/programs/` of a z486 checkout at the fork commit 6833250, pointing `SUITE` in
`gen_cpusuite.py` at that checkout's `tests/`, and running
`gen_cpusuite.py --only <the 20 tri_* names>,ac_v86_iret,bswap_486,callgate_newstack_ss,cpl3_priv_gp,debug_bn_noenable,debug_bn_noenable_dr123`
(the six suite programs as they were at that commit). The capture's `out dx, al` rows predate
the prelude's whole-EAX fix (`docs/probes/README.md`).

Writing sections are opt-in, run under `cli`, save every as-found byte and print the
restore proof. A section that hangs is identified by a `BEGIN:` line with no matching `END:`.

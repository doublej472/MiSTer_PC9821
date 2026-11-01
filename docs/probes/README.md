# Machine probe captures

Raw captures from a real NEC PC-9821Xe10, taken with the DOS probe programs in
[`tools/hwprobe/`](../../tools/hwprobe/) (and, for the conformance suites, the third-party
test programs named in their own READMEs). They are **primary evidence**: a bench whose
expected value is a hardware fact cites one of these files, and only the captures that a
bench, tool or RTL comment still cites are kept here.

The files are byte-for-byte what the probe printed (DOS text, CRLF). Do not normalise them.

| File | Subject |
|---|---|
| `R10.TXT` | the hardened `probe2` pass: five snapshots plus the `MODE`, `INT1B`, `WIN` and `D8` sections |
| `PORTS.TXT` | the I/O port sweep, including the `0xA4000` CG window across the TRAM boundary and the software-DIP ports |
| `WIN.TXT` | the memory-window sweep: `0x461`/`0x463` across their range and the first-touch window register reads |
| `SHADOW.TXT`, `SHADOWW.TXT` | the writable-shadow captures: the `0xF8E90` drive byte, the `0xC0000-0xD7FFF` ROM area (and the PC-9801-86 `SOUND.ROM` at `0xCC000`), and the shadow's read/write rule |
| `VRAM.TXT`, `VRAM2.TXT` | the VRAM and CG-window reads (two runs) |
| `GDC.TXT` | the GDC status and register reads |
| `ATA.TXT`, `IDE.TXT` | the ATA task file as the machine presents it; the full `ideprobe` run including DIAG |
| `RDBACK.TXT` | the write/read/restore sweep (port read-back values) |
| `PITPH.TXT`, `PIT-fixed.TXT` | `probe2 /PIT`: the first attempt (self-rejected) and the phase-fixed run (8:1 PIT:ARTIC ratio) |
| `VSYNC.TXT` | `probe2 /VSYNC` (VSYNC interrupt hold behaviour) |
| `WIPE-rerun.TXT` | `probe2 /WIPE`: a game's GRCG wipe step replayed in 640x400 mode, with the CG/GDC side reads |
| `EMS.TXT` | the EMS page window and `0x043F` behaviour |
| `JOY.TXT` | the sound board's game port (`0x188`/`0x18A`) and its work area |
| `MEMSW.TXT` | the memory-switch view: `0x530`/`0x531`, the TRAM tail's switch cells and the CG rows the ITF reads |
| `PROBE.TXT`, `T.TXT` | a small early capture (byte-identical; kept under both names it is cited by) |
| `TIME.TXT`, `TRS.TXT` | the early timing ladder and the calendar `/TIMEREF /TIMESET` stream (use the calendar rows; the ladder's ns are not comparable between runs) |
| `IO.TXT` | the self-calibrating I/O class ladder (`ioprobe`): per-port access cost with a paired control row |
| `IDELAT.TXT`, `IDELAT-clean.TXT` | the IDE READ latency set (`idelat`): command -> first DRQ, per-sector PIO, throughput (the clean-tally run is the reference) |
| `GFXB.TXT` | `gfxbench`: plain-fill bandwidth per VRAM window |
| `GFX2.TXT`, `GFX2-rerun.TXT` | `gfxbenc2`: per-operation GVRAM drawing latency (GRCG RMW, plane writes, copies) |
| `EGCP.TXT` | `egcplane`: EGC fill/ROP/copy time at 1-4 enabled planes (0x4A0), net of loop controls: flat on the Xe10 (writes ~0.7 ns net, same-page read+write ~677 ns net) |
| `IRQWD.TXT` | `irqwd`: masked-ack / request-withdraw behaviour of the 8259 lines |
| `OPNA.TXT` | `opnapro`: PC-9801-86 OPNA register read-back |
| `PEGC.TXT` | `pegcwatch`: the PEGC register state a game leaves behind |
| `A20MAP-XE10.TXT` | `a20map`: how the A20 mask treats physical addresses |
| `D8BANK-XE10.TXT` | `d8bank`: the `0xD8000` window per `0x063C` bank select |
| `FDMODE-XE10.TXT` | `fdmode` (binary sha f0394f9bdd53e691), from a DOS prompt after a hard-disk boot, floppy drives empty: the FDD interface ports (0x00BE/0x00BF read FF), the PIC masks, the disk work bytes and INT 1Bh SENSE on DA/UA 0x90 and 0x70 |
| `FLIP.TXT` | the `0xA4` display-page flip latch timing |
| `KTDEMO-XE10.jpg` | a photograph of a text-mode demo on the machine (the reference for a CRTC attribute case) |
| `SNDTEST-xe10.TXT` | `sndtest`: the OPNA calibration stimulus's transcript on the machine |
| `SNDTEST-balance-2026-09-25.txt` | the SSG:FM within-recording balance table measured from paired SNDTEST recordings (`tools/sndtest_balance.py`); the recordings themselves are not committed |
| `egc-conformance/` | the PC98_EGC_CONFORMANCE suite's CSVs on the Xe10 and on this core (see its README) - the oracle for `tools/gen_egc_compare_vectors.py` |
| `gdc-conformance/` | the GDC conformance suite's CSVs at 2.5 MHz on the Xe10 and on this core (see its README) - the oracle for `tools/gen_gdc_compare_vectors.py` |
| `itf-paired-7287bed6/` | the `D2` conventional-memory snapshot, cold and warm boot, on the Xe10 and on this core |

## Reading the timing captures

Every `exc_ns` in the `probe2` timing captures (`TIME.TXT`, `TRS.TXT`) is printed at half the
real value (the probe assumed a /2 in the PIT's mode 3 that the machine does not have), so
double it before comparing. The self-calibrating probes (`ioprobe`, `idelat`, `gfxbenc2`)
report absolute times against the ARTIC counter and need no correction.

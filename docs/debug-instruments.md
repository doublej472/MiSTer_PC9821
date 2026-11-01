# Debug-UART instruments (`--dbg-*`)

Feature reference for the compile-time debug instruments. They are off in every preset (the
preset contract requires `dbg` empty), selected on any profile by `build_profile.py`, and they
need `trace_en`/`perf_log_en` off (the `trace` profile's telemetry shares the same UART, see
[`mister-testing.md`](mister-testing.md#the-debug-uart)).

All of them write records to the debug UART through `pc9821_dbg_mux` (round-robin, a grant held
for a whole record), and `tools/decode_dbglog.py` reads them all. How to build, capture and decode
them on a card is in [`mister-testing.md`](mister-testing.md#the-debug-uart), "The debug UART".
None of them builds beside `--trace` or `--perf-log`, which share that UART arm (their bytes would
cut a record in two): `build_profile.py` refuses the pair, and `--dbg-cd` also needs the CD drive.

| option | what it builds |
|---|---|
| `--dbg-cpu` (`--dbg-sample-ms N`) | a sampler: CS:EIP, mode bits, INTA counts per vector, PIC IMR/IRR/ISR, VSYNC and port events, every N ms (10) |
| `--dbg-snoop LO:HI` | a physical-address memory snoop: every CPU write and read-response beat in `[LO,HI)` (hex) |
| `--dbg-trig SPEC` (`--dbg-trig2 LO:HI`, `--dbg-arm-s N`, `--dbg-post N`) | a frozen instruction trace `{CS, EIP, SP, EFLAGS}` and its trigger: `pc:CS:EIP`, `wr:ADDR`, or `reload:ADDR`; the optional second stage freezes on the first CPU write into `[LO,HI)` after it |
| `--dbg-gdc` (alias `--gdc-log`) | the display programming log (both GDCs, the mode registers, text-attribute runs) |
| `--dbg-cd` (alias `--cdrom-log`) | the ATAPI drive's command log (`tools/decode_cdlog.py` also reads it) |

The record-length table (`pc9821_dbg_mux.sv dbg_rec_len` = `tools/decode_dbglog.py LEN` = the
emitters) is held by `tools/check_dbglog_contract.py`. The instruments are not reset by a guest
reset, so the core's reset banner can land inside a record; the decoder removes it.
`bash tests/pc9821/run_dbglog_e2e.sh` runs RTL bytes through the decoder.

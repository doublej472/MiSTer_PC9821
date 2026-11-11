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
| `--dbg-trig SPEC` (`--dbg-trig2 LO:HI`, `--dbg-arm-s N`, `--dbg-post N`, `--dbg-last-ms N`, `--dbg-trace-aw N`) | a frozen instruction trace `{CS, EIP, SP, EFLAGS}` (2^N issues, `--dbg-trace-aw` 4..12, default 9 = 512; the LAST mode keeps two such banks, so 12 costs 2 x 4096 x 80 bits of M10K) and its trigger: `pc:CS:EIP` (CS is the selector register, so a V86 address is its segment value, e.g. `pc:FD80:1A82`), `wr:ADDR`, `reload:ADDR`, or `io:PORT[:VAL]` (the first CPU OUT of VAL to PORT, any byte without VAL, seen on the iobus's last-access latch, so the FDC's ports count); the optional second stage freezes on the first CPU write into `[LO,HI)` after it; `--dbg-last-ms N` takes the LAST match instead of the first (`pc`, `wr` or `io`, single stage): every match re-arms and records POST issues into one of two ring banks, and the latest capture is dumped once N ms pass with no further match |
| `--dbg-gdc` (alias `--gdc-log`) | the display programming log (both GDCs, the mode registers, text-attribute runs) |
| `--dbg-cd` (alias `--cdrom-log`) | the ATAPI drive's command log (`tools/decode_cdlog.py` also reads it) |
| `--dbg-fdc` | the floppy controller's log: every FDC data-port byte both ways with the controller state, MSR value changes (with the count of identical polls), the interrupt line's edges, 0x94/0xCC/0xBE/0xBF/0x4BE accesses and the DMA channel-2 programming, on a 10 us clock (`decode_dbglog.py --fdc`) |

The trigger record (0x44) names an `io:` trigger by the tag 4 in its stage byte, with the port, the
byte and the number of matches since `--dbg-arm-s`; `--dbg-last-ms` sets its `last` bit
(`decode_dbglog.py --trace` prints both). A last-occurrence dump holds only the issues recorded
since its bank was started, so it can be shorter than 512 entries.

The record-length table (`pc9821_dbg_mux.sv dbg_rec_len` = `tools/decode_dbglog.py LEN` = the
emitters) is held by `tools/check_dbglog_contract.py`. The instruments are not reset by a guest
reset, so the core's reset banner can land inside a record; the decoder removes it.
`bash tests/pc9821/run_dbglog_e2e.sh` runs RTL bytes through the decoder.

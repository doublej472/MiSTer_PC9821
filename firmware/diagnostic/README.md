# Redistributable native-platform diagnostic

`post.s` is an original, minimal real-mode payload for validating this core. It
contains no NEC firmware. `build.py` uses GNU `as` and `objcopy` to produce a
32 KiB ITF image in a 512 KiB ROM pack and generates deterministic synthetic
ANK glyph patterns without reading any external font. The extracted ANK window
occupies pack offsets `0x30000-0x30FFF`, separate from both BIOS banks.

```sh
./firmware/diagnostic/build.py --out /tmp/pc9821-diagnostic.bin
```

POST port `0x0EE0` values, in the order `post.s` emits them (a failure code parks the
payload in its idle loop, so the last code written names the stage that broke):

| Code | Meaning |
|---|---|
| `E6` | the triple-fault shutdown (absent-selector `#GP` -> `#DF` -> shutdown) did not reset the CPU |
| `10` | real-mode entry reached; emitted twice, once after the triple-fault reset and once after the `out 0xF0` reset, each re-entering through the reset vector |
| `E3` | the A20 control failed: with A20 masked, a write at physical 1 MiB did not wrap to `0x00000` (with either PPI port-C bit-0 direction) |
| `5E` | the A20 wrap control and the PPI stage passed; `out 0xF0` (CPU-mode reset) follows |
| `70` | the second pass after the `out 0xF0` reset (only reachable with the 1 MiB wrap in place) |
| `E5` | after that reset, port `0x9894` bit 3 (the CPU-mode report) was set |
| `71` | port `0x9894` bit 3 is clear after the reset, as the ITF's own gate expects |
| `E1` | the low-RAM DWORD write/read failed |
| `20` | the low-RAM DWORD write/read passed |
| `30` | text-GDC start and TRAM banner writes completed |
| `5A` | the banner stage is complete; the interrupt self-test follows |
| `E2` | no VSYNC interrupt (IRQ2, `INT 0Ah`) arrived within the wait |
| `60` | the VSYNC interrupt self-test passed: the final code, the payload is in its idle loop |

The full-system regression builds and loads this pack through the real ioctl
loader:

```sh
./tests/pc9821/run_boot.sh
```

It verifies POST progression, low-RAM signature `5A3C0BAD`, the first TRAM
character/attribute bytes and the VSYNC interrupt stage after z486 execution.

These are **test programs, not firmware**: they exist to drive the CPU, memory
and I/O paths from a known stimulus, and they never stand in for the machine's
BIOS. `ipl.s` is an original 512-byte PC-98 fixed-disk IPL carrying the `IPL1`
marker at bytes 4-7; it emits POST `A5`, writes low-RAM signature `0D05B007`,
updates TRAM, and enters a stable loop. Build it with:

```sh
./firmware/diagnostic/build.py --out /tmp/diag.bin \
  --disk-out /tmp/pc98-ipl.img
```

The end-to-end disk test mounts your own image through the MiSTer image
protocol, against the authentic firmware pack:

```sh
PC98_PACK=/path/to/pc98pack.bin PC98_USERDISK=/path/to/image.img \
  ./tests/pc9821/run_userdisk.sh
```

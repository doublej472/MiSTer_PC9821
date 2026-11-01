# GDC characterization / conformance suite v1.0-rc6 — real-hardware captures

These are **real PC-9821 hardware** captures, so they sit at the TOP of this
repo's evidence hierarchy (AGENTS.md, "Evidence": real hardware beats
NP2kai, qemu-pc98, MAME and our own RTL). They are the oracle for the graphics
GDC (the uPD7220-compatible *slave* on ports `0xA0`/`0xA2`) command/drawing
work, including the figure drawing (FIGD/GCHRD) whose GDCDRAW/GDCGCHR/GDCROP rows
`tools/gen_gdc_draw_vectors.py` turns into `tb_pc9821_gdc2_figure_xe10`'s replay.

## What ran, on what

`pc98-gdc-tests-v1.0-rc6`, run as `RUNFULL.BAT` (every safe profile) at
**GDC clock 2.5 MHz**. The suite is a binary-only distribution: the DOS
programs (`GDC*.EXE`, not committed) and its `README_.TXT` are the only
delivered artifacts — no sources, no register listings, no host-side decoders.

| directory | side |
|---|---|
| `xe10-2.5MHz/` | a real PC-9821 Xe10, **the oracle** |
| `mister/` | this core (MiSTer) on the same binaries, the baseline for the gap |

`RUNINFO.TXT` in each directory is the suite's own per-profile banner;

```
pc98-gdc-tests-v1.0-rc6 profile=<name> clock=2.5MHz BIOS054D=50 BIOS054C=4F   # xe10
pc98-gdc-tests-v1.0-rc6 profile=<name> clock=2.5MHz BIOS054D=10 BIOS054C=4F   # mister
```

**A measured configuration confound: `bios054d=50` on the Xe10 against
`bios054d=10` here.** 0x50 is bits 4+6, 0x10 is bit 4 alone, so **bit 6
differs** and this core does not reproduce the machine's 0x054D. Bit 2 (the
"display address increment time" flag) and bit 5 agree, so the GDC-clock flag is
right. Every gap count below is therefore an **upper bound**, and a case whose
expectation looks mode-dependent is not evidence against this core on its own.
Port 0x31/0x054D is a separate question; this capture records the divergence and
nothing here chases it.

`MACHINE.TXT` is the suite's template (the run did not fill it in);
`README.TXT` is the suite's own packaging note.

## CSV format

Every `GDC*.CSV` starts with two `#` comments (a title and the config banner)
and then one column-name line. The columns are per group, e.g.

```
GDCADDR: case,class,expect,outcome,params,changes,curd,detail
GDCCURS: case,class,expect,outcome,input_ead,input_dad,raw_curd,decoded_ead,decoded_dad,word,detail
GDCWDAT: case,class,expect,outcome,rop,xfer,old,src,mask,got,expected,changes,curd,detail
GDCWG:   case,class,expect,outcome,wg,rop,old,src,mask,got,expected,changes,curd,detail
GDCROP:  case,class,expect,outcome,rop,old,pattern,dad,got,expected,changes,curd,detail
GDCDRAW: case,class,expect,outcome,kind,p1,dc,d,d2,d1,dm,dgd,start_ead,start_dad,changes,curd
```

`expect` is `STRICT` for the documented invariants and `INFO` for fingerprints
(the suite's own text: "`INFO` ... preserves behaviour the suite does not claim
one model for"). `outcome` is the suite's PASS/FAIL per case. `changes` is a
human-readable summary of the GVRAM words the case changed (the exhaustive
before/after record is in the `.VRD` binary dumps, which are **not** committed:
`GDCDRAW.VRD` alone is 2 MB).

## Oracle size and the gap

**3,118 case rows per side, with IDENTICAL case ids and identical row counts in
every group** (GDCDRAW 455/455, GDCWDAT 914/914, GDCROP 517/517, GDCCURS 95/95,
GDCADDR 107/107, GDCWG 180/180, GDCGCHR 555/555, GDCRDX 161/161, GDCTIME 95/95,
GDCSTATE 16/16, GDCFIFO 7/7, GDCRDAT 15/15, GDCQUIRK 10/10, GDCRESET 5/5) — so
every case on one side is directly comparable to the same case on the other, and
nothing stopped early.

`tools/gen_gdc_compare_vectors.py` re-derives the accounting from these files
(it is the only thing that writes `CLUSTERS.CSV`). The numbers:

```
Xe10 PASS rows                                        : 842
gap (Xe10 PASS, this core not PASS)                   : 461
reverse gap (Xe10 not PASS, this core PASS)           :   4   (GDCSTATE FIGS_DEFAULT)
```

| cluster (`class`) | gap | Xe10 PASS | first failing detail |
|---|---:|---:|---|
| `WDAT_WORD` | 136 | 384 | GDC's own word write / RMW / mask / DC-DIR stepping |
| `FIGD_ROP` | 120 | 192 | figure drawing under all 16 ROPs |
| `ADDR_PLANE` | 64 | 64 | plane/EAD mapping of a GDC word write |
| `CURD` | 56 | 56 | the cursor register block read back |
| `WDAT_WG0` | 30 | 80 | uPD7220A `CURS.WG` bit0-replicate WDAT model |
| `CURS_MASK` | 16 | 16 | the cursor's implicit one-hot mask |
| `MASK_ORDER` | 16 | 16 | `MASK` then `CURS`: the cursor restores its one-hot |
| `DOT` | 16 | 16 | `FIGD` dot |
| `MASK` | 5 | 6 | the `MASK` register (0x4A) reaching the drawing path |
| `FIFO_TURN` | 1 | 1 | `RDAT`/FIFO turnaround |
| `STATE` | 1 | 1 | `FIGS` defaults (see the reverse gap) |

**The failure signature is "not implemented", not "subtly wrong".** The clearest
witness is `GDCADDR`'s first row: the Xe10 reports
`bitmatch=1,1 / E:0123:0000>0080 / 4B-01-F0-01-00 / 0014B / M0001 / D0 /
total_words=1 bits=1` (one word actually written to the GVRAM plane), while this
core reports `bitmatch=0,0 / / / M0000 / D- / total_words=0 bits=0` — **zero
words were written through the GDC**, and the cursor register block does not
even latch. `GDCCURS`'s 56 `CURD` rows return the empty `0xA2` read-back queue
here (`raw_curd` `00-00-00-00-00`, `01-00-00-00-00`, ... — the EAD low byte and
zeros after it) against the machine's `XX-XX-Fn-XX-XX`, and the harness decodes
`DAD` as `255` (0xFF) on every one of them.

### Failures shared with the machine are NOT defects

`GDCRDX` = 2 and `GDCRDAT` = 2 and `GDCSTATE` = 1 fail on BOTH sides;
**only 16 of GDCDRAW's 454 rows PASS on the machine either** (367 `OBS`, 71
`ERROR`) — the Xe10's DRAW run is explicitly best-effort (the machine
locked up during `GDCDRAW`, and the suite's own recovery text says so). Check
the Xe10 column before treating any case as a bug.

Conversely this core **passes 4 `GDCSTATE` `FIGS_DEFAULT` rows the Xe10 fails** —
i.e. our default `FIGS` state is *more* conformant than the real chip's. That is
a fidelity divergence in the opposite direction and is recorded, not fixed here.

## The register protocol, decoded from the suite's own binary

The suite's sources are not distributed, so the register program was recovered
by disassembling `GDCCURS.EXE` (MZ, 19,764-byte load image, entry
`0000:1B96`, four relocations all `0x0466`). The **data segment base is module
offset `0x4660`** (`mov dx,0x466; mov ds,dx` after relocation), which is what
made the tables readable; the CURD EAD table lives at `DS:0x474`
(`00000, 00001, 03FFE, 03FFF, 04000, 04001, 07FFF, 08000, 0BFFF, 0C000, 0FFFE,
0FFFF, 10000, 1FFFF, 20000, 3FFFF`).

The helper functions, by module offset (all reachable by straight `call` from
the CURD driver at `0x32`-`0x1C8`):

| helper | what it does |
|---|---|
| `0x4AB` | send one parameter byte to `0xA0` after a status poll |
| `0x759` | send one command byte to `0xA2` after a status poll |
| `0x618` / `0x692` | `CURS`: cmd `0x49`, then **three** parameter bytes (below) |
| `0x6B9` | `MASK`: cmd `0x4A`, then two bytes `{lo, hi}` |
| `0x8B5` | `CURD` read: cmd `0xE0`, then five bytes into the caller's buffer |

`CURS` (`0x49`) parameter layout, from `0x618`: parameter 0 = `arg1 & 0xFF`,
parameter 1 = `arg1 >> 8`, parameter 2 =
`(arg3 ? 0x08 : (arg1 >> 8)) | ((arg4 & 0xF) << 4) | (arg2 & 3)`; the CURD
driver calls it with `arg1 = EAD[15:0]`, `arg2 = EAD[17:16]`, `arg3 = 0`,
`arg4 = DAD`.

The `CURD` read-back is five bytes, and `0x8B5` decodes them as
`EAD = b0 | b1<<8 | (b2 & 3)<<16`, `MASK = b3 | b4<<8`, with `b2 & 3` holding
`EAD[17:16]`. The Xe10's own column confirms the rest of `b2` is a fixed `0xF0`
("cursor format"), independent of `arg3`/`arg4`:

```
00-00-F0-01-00  ead=00000 mask=0001 dad=0
00-00-F1-01-00  ead=10000 mask=0001 dad=0
FF-FF-F3-00-80  ead=3FFFF mask=8000 dad=15
```

The harness computes `word` (the `CURS_MASK` / `MASK` / `MASK_ORDER` classes)
as the cursor mask mapped into **CPU-visible bit order — bit-reverse within each
byte**: `0x0001 -> 0x0080`, `0x8000 -> 0x0100`, `0x00F0 -> 0x000F`,
`0xA55A -> 0xA55A`. All 37 of those rows reproduce from the mask alone.

### Open question: the source of the read-back MASK

The `MASK` value the Xe10 returns for the 56 `CURD` rows is `1 << DAD` for every
one of them, and `DAD` is the driver's loop variable (0, 5, 10, 15, stepping by
15 past `si = 0x0B`). That loop variable reaches the GDC **only** through
`arg4` in parameter 2's bits 7:4. But parameter 2 also ORs in `arg1 >> 8`, the
EAD's high byte, so for every EAD >= 0x1000 the two collide:

```
CURD_0FFFE_10 : EAD=0FFFE, DAD=10  ->  CURS params {FE, FF, FF}  -> machine mask 0400
CURD_0FFFE_15 : EAD=0FFFE, DAD=15  ->  CURS params {FE, FF, FF}  -> machine mask 8000
```

Byte-identical writes, different masks, both STRICT PASS on the machine — so the
read-back `MASK` is **not** a function of the three `CURS` bytes as this decode
reads them, and the `0x4A MASK` helper has only two call sites (`0x2CB`,
`0x358`), neither inside the CURD driver. `tools/gen_gdc_compare_vectors.py`
reports the affected set: **29 of the 56 `CURD` rows**, the ones whose
`EAD[15:8] >= 0x10` (`EAD` in `{03FFE, 03FFF, 04000, 04001, 07FFF, 08000,
0BFFF, 0C000, 0FFFE, 0FFFF}`); the other 27 are consistent with
`mask = 1 << (param2 >> 4)` and are not evidence either way.

Reading parameter 2's base as a fixed `0x08` instead of `arg1>>8` reproduces
**all 56** rows exactly (`0x08 >> 4 == 0`, so the OR can no longer collide with
the DAD nibble) — but no decode of the driver's call path through `0x692` gives
`arg3 != 0` on every row, so that is a *candidate*, not the answer. This is
recorded as an open question rather than guessed: a 27/56-exact stage machine
would be a half-landed register file, and the hardware is the oracle.

### The cursor's GVRAM overlay

The `CURS_MASK` / `MASK` / `MASK_ORDER` drivers (module offset `0x2A0`-`0x3C0`)
clear plane G word `0x800`, position the cursor at `EAD = 0x8800` with
`DAD = 7`, write `MASK`, and then read plane G word `0x800` back — so those
`word` values are plausibly the cursor **drawn into GVRAM**, not merely a decode
of the register. `EAD = 0x8800` with the driver's read at `0x800` is consistent
with an 18-bit word address whose low 14 bits index the 16 KiB plane bank. This
is not settled here; the suite has no `changes` column for `GDCCURS`, so the
capture cannot distinguish "drawn" from "decoded" for those 37 rows.

## What this capture does NOT contain

- No `*.VRD` (the exhaustive per-word before/after dumps; `GDCDRAW.VRD` is 2 MB).
- No `GDC*.EXE` — the suite is a separate binary distribution and is not
  redistributed (only the two `.TXT` files it ships are kept).
- No GDC execution timing beyond `GDCTIME`/`GDCTRAW`'s PIT-tick fingerprints,
  and no raster/display characterisation (the suite disables the display).

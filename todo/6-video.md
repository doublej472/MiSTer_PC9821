# 6. Video: display, GDC/CRTC raster

36. **`0x6C`: what the latch drives.** **WORK.** The core answers 0x6C from a latch of bits 7-4
    (reset 00; `pc9821_iobus.sv`, `tb_pc9821_readback_sysports`), as the machine reads it:
    `docs/probes/KIT1-XE10-CFGWR.TXT` (`70` after 70, `50` after 5A) and kit 2's
    `docs/probes/KIT2-XE10-P6C.TXT:4-10`, `P6C w=80 r=80`: `80` after 80, `F0` after F0, `F0` after
    FF, `70` after 70, so bit 7 latches too. Kit 2 filmed each value for 3 s: no colour change anywhere on the
    screen through the OSSC (mean RGB of the background, the left edge and the top strip steady to
    +-0.5), so no visible border effect was found (MAME maps 0x6C as `border_color_w`; the scaler
    may crop the overscan). Nothing on the core consumes the latch either. **Done when:** the
    comment at `pc9821_iobus.sv` that cites this item cites `KIT2-XE10-P6C.TXT` instead (an RTL
    edit: the next change to that file), and the item is retired.

85. **GDC SYNC raster residuals.** **UNVERIFIED (INFERRED).** `pc9821_crtc.sv` derives the
    raster from the master GDC's SYNC bytes with NP2kai's `gdc_updateclock()` arithmetic and its
    24 kHz clamp (`tb_pc9821_gdc_sync_raster`), the x floor lowered to the machine's measured 90:
    the real Xe10 runs an AW 64 block (x = 90) as a 720-dot line, 29.24 kHz
    (`docs/probes/KIT2-XE10-TXTMODE.TXT:36` `FRAME 16 VSYNC ticks=000120F1 lines=01B8`). Open:
    (a) the clamp does not rescale the active counts as NP2kai does (identical for every in-range
    block); (b) the slave GDC's SYNC block sets the graphics window's vertical placement from its AL and
    VBP bytes, as NP2kai's `dispsync.c` does (`pc9821_gdc2.sv` `gdc2_sal`/`gdc2_svbp`), with no Xe10
    capture, and its other six bytes have no consumer; (c) the
    limits themselves are not measured: a block below x = 90 is held at 90, above x = 112 at 112,
    and the 31 kHz range (92..108) is NP2kai's; (d) a line wider than 80 cells keeps the text
    fetch's fixed column-79 wrap (no capture of AW above 80; the kanji row cache holds 80 cells).
    **Done when:** the SYNC bytes other titles program are trapped (the eight bytes after
    `out 0x62,0Fh`) and any out-of-range or slave-only case is either matched or shown not to
    occur; for (c) and (d), a `TXTMODE`-style step with C/R 0x36 (x = 82) and 0x56 (AW 88, x = 114)
    timed and filmed on the machine.

128. **TXTMODE residuals: CSRR's last two bytes, BDA 0x0716, a CRTC write mid-picture.**
    **VERIFIED (HW)** for the first two. Kit 2's `TXTMODE /D` (`docs/probes/KIT2-XE10-TXTMODE.TXT`,
    the owner's film beside it) settled the text pitch - a SYNC block's C/R byte loads it, a later
    PITCH overrides it, which `pc9821_crtc.sv` now does (`tb_pc9821_text_modes` P1-P6) - and with
    the pitch the geometry states match the core: 30 lines, two and four partitions, the held
    scroll, and the SUR 29 / SDR 9 region, which scrolls as a block by SSL lines (kit 1's "glyph
    lines rotated inside the row" was the pitch shear seen through that scroll). Left in the log:
    CSRR's last two bytes read `FF FF` on the machine, `00 00` on the core
    (`docs/probes/KIT2-XE10-TXTMODE.TXT:8` `CSRR 00 00 00 FF FF`, every step; NP2kai's zeros), and
    the BIOS work byte 0x0716 reads 82 where the core's reads 00 (the same file's `BDA` lines, the
    seventh byte after the bar). Not captured: the core's frames of the SSL 0-12 steps (its k3 run
    filmed 15 s apart), and a CRTC write landing mid-picture (the core reads 0x70-0x7A live,
    NP2kai once per frame; `pc9821_crtc.sv`). **Done when:** the two read-back bytes are traced to
    their source (the GDC's parameter read-back queue past CSRR's three bytes, item 13's pattern;
    which BIOS path writes 0x0716) and matched with fail-first benches, and a core run films the
    SSL 0-12 steps.

151. **GVRAM store period: the residuals of the Xe10 table.** **DECISION (OWNER).** OSD I/O timing = Xe10
    prices every GVRAM store by mode (GRCG RMW, TDW, plain), width (one 16-bit GVRAM word or two:
    a dword, or a word at dword offset 1) and raster (on a graphics line or not), from XE10V
    `/MISAL` on the machine (`docs/probes/XE10V-XE10-MISAL1.TXT`, `-MISAL2.TXT`; the generated
    class table `tools/xe10_classes.csv`, `tb_pc9821_gvram_xe10_store`). The core's run of the same
    kit (`docs/probes/core/XE10V-CORE-grcgmis-2a8b78b5-s2-XE10-MISAL1.TXT`) lands within 3.4 % of
    every fixed-offset row and every RMW and plain string row. Open: (a) the TDW word string from
    an odd DI (offsets 1 and 3 alternating: `TDW_SW1`, `TDW_MW1`) costs 298 ns a word on the
    machine (348 on a graphics line) and 276 (315) on the core: a word after a split pair costs
    about 45 ns more than either alone, an order effect the per-access table does not model;
    (b) the plain two-word store is bimodal on the machine (about 200 or 282 ns, 228 or 322 on a
    graphics line, changing with the loop shape and between runs); the table charges the upper
    mode. **Done when:** the owner decides whether (a) and (b) are modelled, and if so a capture
    names the rule (the store before and after, the loop phase) and a bench holds it.

197. **Xe10 class table: the aperture's own read class.** **WORK.** OSD I/O timing =
    Xe10 prices every GVRAM, text-RAM and PEGC packed access from `tools/xe10_classes.csv` by
    display mode (24 kHz, 31 kHz, 31 kHz with the 256-colour display on) and raster phase. XE10X
    `/RDLAT` (`docs/probes/XE10X-XE10-RDLAT1.TXT`) measures the one-word classes in every mode; the
    cells marked `fallback-24`/`fallback-31` there carry another mode's row: the 31 kHz two-word
    classes (GVRAM TCR reads and stores, text reads and stores), and every GVRAM class with the
    256-colour display on. Two states are not columns at all: the GVRAM and text RAM at 24 kHz with
    the 256-colour display on (priced as 24 kHz, though the PEGC packed read there costs 761.4 ns net
    on a graphics line, `:216`, against the text read's 692.2, `:174`), and the 0xF00000 linear PEGC
    aperture (not priced). **Kit 3 measured them** (`XE10Y /CELLS`, `docs/probes/XE10Y-XE10-CELLS.TXT`, tags `FAM_<31|2P|3P|48><A|V>`): the 31 kHz two-word TCR and text reads and TDW/RMW stores are now `measured` cells (GV_RD_TCR_2W_31*, TX_RD_2W_31*/48*, GV_WR_TDW_2W_31*, GV_WR_RMW_2W_31*; the 48 GRCG cells their fallback-31 copies), with `tb_pc9821_xe10_latency` rows. Still fallbacks, on purpose: the plain two-word store at 31 kHz (GD reads 205.0 ns on graphics lines and 242.4 in the blank, `:313`/`:393`, the A cell below the V one) and the two-word text store at 31 kHz and 48 (XCWM 200.3/170.1 and 149.4/139.1, `:329`/`:409`/`:558`/`:606`, the lower mode of the bimodal two-word text store the table does not charge). The GVRAM cells with the 256-colour display on cannot be reached: 0xB8000 reads FFFF and drops a store with the mode on (`X B8`), and 0xA8000-0xB7FFF are the packed banks. 24 kHz with the 256-colour display on (`2P`) differs on graphics lines: the text read is 759.0 ns net (`:31` XCR_2PA) against the table's 692.2, the two-word text read 995.8 (`:79`): the table now has the fourth column, 24P (its text reads measured from CELLS, its other cells declared fallback-24: the GVRAM is unreachable there, the PEGC 24 column already is that state, and the text stores' rows sit inside the bimodal spread the table charges by its upper mode), selected by `pc9821_memory_subsystem`'s xe10_mode 3 (`tb_pc9821_xe10_latency`, `tb_pc9821_xe10_aperture`). The aperture is **measured** (kit 3's third image, 0x043B left as found: `docs/probes/XE10Y-XE10-RUN3-APER2.TXT`): `X APER` proves 0xF00000 is the packed bank 0 on the machine (a word stored at 0xA8000 reads at 0xF00000 and back, also after WBINVD), and it costs what the packed bank costs: loads LATENCY 731.2 / 591.3 ns net at 24 kHz with 256 colours (`:40` PAR_2PA, `:64` PAR_2PV) and 657.3 / 544.4 in 640x480 (`:99`, `:123`); stores RATE 144.6 / 135.9 and 163.7 / 135.1 ns per word (`:32`, `:56`, `:91`, `:115`), dwords 181.2 / 140.7 and 139.9 / 136.7 (`:48`, `:72`, `:107`, `:131`). The core answers the aperture unpaced (PAR 228 ns, PAW 77; `docs/probes/core/XE10Y-CORE-xt-3409ab24-s3-XE10-RUN3-APER2.TXT`): `pc9821_memory_subsystem` now routes the open aperture through `pc9821_pegc_xe10_pace` with the packed classes (`tb_pc9821_xe10_aperture`), in Xe10 only. The PEGC store PK_WR_24A is bistable on the machine: 145 or 181-183 ns per store, fixed within a row and chosen by the state before it (`docs/probes/XE10Y-XE10-PKAB_AB.TXT`; /MISAL2's sequence always reads the low mode and /RDLAT's the high one, in every binary and both /REP passes, `XE10Y-XE10-REP.TXT`); the table keeps the high mode 182.8, as it does for the bimodal GVRAM and text stores (the owner's decision, item 199). Every cell still declared a fallback is
    so on purpose (unreachable, or an upper-mode choice of a bimodal store, item 199), so no capture
    is owed. Left: the aperture reuses the packed classes, and its measured loads at 24 kHz with 256
    colours (731.2 / 591.3 ns net) sit 4-5 % below the table's PK_RD_24PA/PK_RD_24PV (761.4 / 622.3,
    `tools/xe10_classes.csv`), so the core's aperture read is slower than the machine's there.
    **Done when:** the aperture's loads get their own measured cells (from `XE10Y-XE10-RUN3-APER2.TXT`)
    with a bench row, or the owner accepts the 4-5 % as within the table's tolerance.

202. **GDCFIG's last graphics character: plane B only on the Xe10.** **NEEDS RE-VERIFICATION.**
    In `tools/hwprobe/gdcfig`'s picture the last character, GCHRD zoom 2 direction 0 at (360,372)
    (`gdcfig_gen.py` `char(360, 372, 2, direction=0)`, drawn through the GRCG just before
    `GRCG off`), is on plane B only on the Xe10 (`docs/probes/KIT1-XE10-GDCFIG.BIN`) but on planes
    B, R and G in the core's capture (`docs/probes/core/KIT1-CORE-rc-e6db0f05-s3-GDCFIG.BIN`; 28
    bytes each on R and G, rows 372-385); the four characters before it match on every plane.
    Either the machine drew it after the probe's idle wait returned and the GRCG was turned off
    (the core raising DRAWING or emptying its FIFO too early), or direction 0 bypasses the GRCG.
    **Done when:** the core's GDCFIG capture is re-taken on the current build, and a GDCFIG run on
    the Xe10 with a delay before `GRCG off` (or the GDC status timing around the last command)
    says which; the core follows it with a fail-first bench.
227. **CRTC: the 31 kHz text shift and the two-byte simple-graph cell.** **UNVERIFIED (INFERRED).**
    `pc9821_crtc.sv` latches MODE FF2's text shift (num 0x20/0x40) and reads it back through the
    0x9A0 query, but does not shift the text; and the two-byte (kanji-pair) arm of SIMPLE GRAPHICS
    (NP2kai `maketext.c`, the doubled cell) is not modelled, so such a code draws as ordinary kanji.
    No capture covers either. **Done when:** a capture or reference reading shows what each does in
    the picture and a fail-first bench pins it, or both are listed in
    `docs/user/troubleshooting.md`'s known issues (or shown unused by the software in the
    compatibility list).

260. **EGC shifter rows that rest on NP2kai alone.** **WORK.** `tb_pc9821_egc` sections 10-11 (a
    multi-unit word feed at srcbit 8-15, including NP2kai's `if (srcbit >= 8) outptr++` window
    offset) and `tb_pc9821_egc_shift` sections 3, 7 and 8 (the descending direction, and a byte
    produce at dstbit 9-15 gated forever because NP2kai's `(UINT)(8 - dstbit)` wraps) take their
    expected values from a port of NP2kai's `memegc.c`. The Xe10's
    `docs/probes/egc-conformance/xe10/EGCSHFT.CSV` covers srcbit 8-15 only as single-unit copies
    (S02_A rows), and its decrement-direction fingerprint rows S05_DIR_DEC_FP0/FP1 are INFO rows no
    bench or tool replays. **Done when:** the two S05_DIR_DEC rows are replayed as asserted cases,
    the claims of both benches mark the NP2kai-only sections as such, and a multi-unit srcbit 8-15
    copy and a dstbit > 8 byte feed are added to the next EGC conformance capture, with the benches
    following its rows.

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
    block); (b) the slave GDC's SYNC block drives nothing, unverified against the chip; (c) the
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

151. **GVRAM store period: the graphics-display rows.** **CAPTURE-PENDING.** The owner's
    decision (2026-11-08) is in: OSD I/O timing = Xe10 charges the machine's sustained store
    periods (`pc9821_gvram_arb.sv`'s Xe10 table, `tb_pc9821_gvram_xe10_store`); Fast keeps
    `GVRAM_GR_HOLD` (104 ns). The GRCG RMW byte/word store is measured in both raster states: 299.5
    ns on a graphics line (`docs/probes/RWIPE-XE10.TXT`, the wipe's fill) and 255.3 ns outside
    them (`docs/probes/XE10T-XE10.TXT:141` RMWSTOSW, and the wipe's fills inside the vertical
    blank). Open: the TDW (168.3/210.6 ns), plain dword (280.9) and RMW dword (497.5) rows are
    prompt-time only (graphics display stopped), so Xe10 charges them on every line and scales
    only the RMW dword to the graphics line; and a misaligned GRCG word store is charged per
    z486 access, bounded only by the wipe's rows aggregate. **Done when:** an XE10T `/GRCG` and
    `/GVRAM` pass with the graphics display started (INT 18h AH=40h) and an RMW16 row at an odd
    DI are captured on the machine, the Xe10 table takes their rows, and the same section is run
    on the core in Xe10 mode and compared.

153. **EGC read pace.** **VERIFIED (HW).** The machine's same-page EGC read+write costs 677 ns net
    (`docs/probes/EGCP.TXT`); the core measured about 239 (`docs/probes/core/EGCP-core.TXT`, an
    older 80 MHz build), and `tb_pc9821_egc_xe10_pace` bounds it from above only. The machine half of the
    XE10T `/EGC` section is captured (`docs/probes/XE10T-XE10.TXT:172-219`). **Done when:** the owner decides whether
    the EGC read is paced, and a current-core capture of that section is compared with it.

189. **CG window even page for the uncaptured classes.** **CAPTURE-PENDING.** The window's even
    (low) page is keyed on the code's ROW on the real Xe10, and `pc9821_cg.sv` answers every
    measured row (`tb_pc9821_cg_ten_low`): 0x8F for the user-CG codes (`docs/probes/VRAM.TXT`) and
    row 0x58 (`docs/probes/KIT2-XE10-CG2-USERCG.TXT:822` `CGX 0158 ... W20E=A0DD`, 16 x 8F), 0xFF
    for one-byte codes, row 0x5C (`docs/probes/KIT1-XE10-CG0-USERCG.TXT`, CGX `W20E=6A4B`), row
    0x09 and row 0x0C (`KIT2-XE10-CG2-USERCG.TXT:758`, `:806`, both 0xA5 halves), and row 0x09's
    odd page with bit 5 clear reads 0x00 (`W00O=6A0A`). So 0x58 and 0x5C, one class in both
    references, differ on the machine; row 0x58's odd page and port reads are unstable (the window
    and the port disagree on 20 of 48 codes), like CG RAM. The unmeasured rows keep the answers
    they had, which are guesses: 0x0A, 0x0B (ver0.78: even page 0x8F, odd page with bit 5 clear
    0x8F), 0x0D-0x0F (0x8F) and 0x59-0x5B, 0x5D-0x5F (0xFF, row 0x5C's). **Done when:** XE10CFG
    `/CG`'s CGX table is run on the machine for 0xA3 = 0x0A, 0x0B, 0x0D, 0x0E, 0x0F, 0x59, 0x5A,
    0x5B, 0x5D, 0x5E and 0x5F (0xA1 = 0x00..0x2F, the W20E/W20O/W00E/W00O columns), and
    `pc9821_cg.sv` answers what it reads, with fail-first rows.

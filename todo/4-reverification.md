# 4. Re-verification items

Claims that rest on a single sample, or a divergence whose cause is still unknown.

42. **16-bit word I/O at byte ports: what XE10T `/AUDIT` and `/AUDIT2` leave open.**
    **VERIFIED (HW)** for one port. Word `IN` is measured (`docs/probes/XE10T-XE10-AUDIT.TXT`, W/P/D
    rows) and `pc9821_iobus.sv` follows it: odd-start words and every port outside NP2kai's even
    terminations split into two byte reads, 0x30-0x36/0x40-0x46 even and 0x7C answer 0xFF above P,
    0x20-0x26/0x60-0x7A/0xA0-0xAC even answer 0x00. Kit 2's `/AUDIT2`
    (`docs/probes/KIT2-XE10-AUDIT2.TXT`; the core: `docs/probes/core/KIT2-CORE-AUDIT2.TXT`):
    (a) word `OUT` writes both bytes on the machine, as on the core and unlike NP2kai: `out 09h,ax`
    lands 5A at 0x09 and FF at 0x0A (`WO0009 ... i1=FF x1=5A`), `out 0Ah,ax` both bytes, `out
    6Ch,ax` the low byte at 0x6C (`WO006C ... a0=70 a1=FF`) - MATCHES. (b) The new word reads match
    their class (0x26, 0x34/0x36, 0x44/0x46, 0x72-0x76, 0xA2, 0x75/0x79/0xAF) except 0x24, which
    splits on the machine (`docs/probes/KIT2-XE10-AUDIT2.TXT:54`, `W0024 b0=FF b1=0E w1=0EFF`: P + 1
    read); the core now splits it too (`tb_pc9821_iobus_word_term`). 0x20, 0x22 and 0x26 cannot
    tell a split from the 00 term (P + 1 reads 00 there) and keep it. (c) Inconclusive: the timing rows cannot tell a
    one-cycle word from a split one on the machine, because even the split control 0x0A costs the
    same as a byte read (`T000A n=1024 b=2027 w=2027`; 0x7C/0x20/0x22 likewise), so whether `in
    ax,7Ch`/`20h`/`22h` fetch P + 1 stays open. (d) Inconclusive: 0x0C24 is a live port on the machine
    (reads `5C`, `W0C24 b0=5C`; the built-in sound's decoder port, `docs/bios-setup.md`), open bus FF
    on the core, and 0x0C25 reads FF, so its word read cannot show the qualifier; 0x0422 reads FFFF
    on both. (e) Bytes the rows read that the core answers differently, with no model yet: 0x35 reads
    `B8` (`W0034 b0=FF b1=B8`; the core `BF`, the low three bits set; both kits read B8): 0x35 is
    the system PPI's port C, a latch the core keeps (`system_port_c`), and bits 0-2 are the
    RS-232C interrupt enables software sets through it, so the difference is the session's state
    (something in the core's boot sets them), not a constant; 0xD0 reads 0x21 (core FF),
    0x640 with no DRQ 0x06 / 0x641 0xFF (core 00 00), 0xA46C 0xEE (now a constant: whether it moves
    with the 86 board's state is unmeasured). **Done when:** (c) and (d) are settled by a read-side-effect row (0x7D/0x21 state changed by
    the word read) and a 0x0C2x word row with the built-in sound enabled, and (e) has a model or a
    reason to leave it.

43. **DMA bank ports `0x21/0x23/0x25/0x27`: low-nibble width.** **NEEDS RE-VERIFICATION.** The
    latch masks with `& 0x0F` from one capture (`docs/probes/RDBACK.TXT`: `A5 -> 05`); NP2kai's
    IA32 build stores the byte unmasked. **Done when:** a second marker (e.g. `0x5A`) confirms the
    mask is exactly the low nibble.

47. **ADPCM-A rhythm without a driver: is the machine silent?** **NEEDS RE-VERIFICATION.** The
    earlier comparison recorded the machine silent with no driver and the core playing (with PMD
    resident the drum levels agree within 0.9 dB, -35.8 vs -34.9 dBFS). The Xe10's `XE10T
    /OPNA3 /LISTEN` run contradicts the premise: at a plain DOS prompt, no driver, it writes
    `0x11 <- 36` and the bass-drum key-ons itself and the drum is audible (`tools/hwprobe/xe10t/
    README.md` "`/OPNA3 /LISTEN`": PHASE 1 loud, PHASE 2 quiet, PHASE 3 loud; the writes are
    `docs/probes/XE10T-XE10-OPNA3-LISTEN.TXT:143-148`). So the rhythm needs no PMD-only enable
    beyond register writes. **Done when:** the original silent observation is re-identified
    (which probe, which registers it wrote; a probe that never writes the rhythm total level
    `0x11` is silent on any chip) or re-run, and `docs/pc9821-port-status.md` states the result.

141. **Self-modifying code inside the prefetch window.** **VERIFIED (HW)** (a fork change).
    Star Cruiser's drawing routine patches an immediate 18-20 bytes ahead of the executing
    instruction with no jump in between (0060:0D40 writes into 0060:0D54, 0060:0D3B into
    0060:0D4D); the 50 MHz userdisk simulation stays black where the card at 90 MHz plays.
    SELFMOD on the machine (`docs/probes/KIT1-XE10-SM.TXT`, `selfmod_decode.py`): a store by the
    5-byte `mov byte [imm],imm` is not seen up to the end of the second 16-byte line from the
    routine's start (first NEW at offset 32), a store by the 2-byte `mov [bx],ah` up to the end of
    the first line (offset 16). Kit 2's other forms (`docs/probes/KIT2-XE10-SM2.TXT`): with the store
    inside line 0, the forms with BOTH a displacement and an immediate are stale one line further
    (offset 32: `mov byte [bx+d8],imm8`, `mov word [disp16],imm16`, and the IMM form after 1, 2 or 3
    register-only instructions), the forms with only one (`mov [disp16],al`, `mov byte [bx],imm8`)
    stop at offset 16 like the REG form: Intel's "one clock for using both displacement and
    immediate" (Intel486 PRM, instruction timing footnote 22) fits, and the extra register
    instructions add nothing (the 32-byte queue holds two lines). When the store crosses into line
    1 the extra line usually holds (first NEW at 48), but not when a 16-bit field straddles the line
    boundary - the IMM form's A = 0Dh (its disp16 at bytes 15-16), the same position in the P1I-P3I
    and W16 rows, W16's imm16 at A = 0Bh - and the one-field forms gain it at one crossing each
    (`mov [disp16],al` at A = 0Fh, `mov byte [bx],imm8` at A = 0Eh): no documented mechanism, so a
    rule fitted to these rows is inference. The core is stale only through the line that holds the
    store's last byte in every form, so it matches the one-field forms in line 0 and never shows the
    extra line (`docs/probes/core/KIT2-CORE-KIT-SM2.TXT`); its table is the same at OSD CPU Speed
    33 MHz (`docs/probes/core/KIT2-CORE-SM2-CPU33.TXT`). At Star Cruiser's distances the machine runs
    the OLD immediate at most alignments, the core the NEW at all. **Done when:** z486 reproduces the
    machine's tables in the fork (the disp+imm clock at least) or the owner accepts the difference.

152. **GVRAM plain read period.** **NEEDS RE-VERIFICATION.** `GVRAM_RD_HOLD` (478 ns) assumes the
    write half of a read+write pair is fully serial (142 ns). `rep lodsw` (613 ns gross,
    `docs/probes/GFXB.TXT`) and the PW4RW read half (604 ns gross, `docs/probes/GFX2.TXT`) put a
    pure read at about 560-580 ns. The machine half of the XE10T `/GVRAM` section is captured
    (`docs/probes/XE10T-XE10.TXT:54-119`, e.g. R16 `art=1622/1622/1625` at `:92`). **Done when:** its read-only and pair
    sweep rows, analysed and compared with the core's run, decide the read and write periods
    separately.

193. **Metajo SP from its own FreeDOS(98) hard-disk image stops after the R-FORCE logo.**
    **WORK.** Booted from the image it ships on, the game shows the R-FORCE logo and then a black
    screen with a text cursor, before and after the INT5 junction fix; NP2kai reaches the title
    menu with the same image. A `--dbg-cpu` capture puts the CPU from about 80 s in the vendor
    shell's own stop loop (`jmp $` after a call with 0x7F, 0), so the shell failed to start the
    menu program; NP2kai loads it and streams PC-9801-86 PCM data at that point, where the core
    takes IRQ0 at about 14 kHz. The same game's files run from an NEC MS-DOS 6.20 boot
    (`docs/user/compatibility.md`). **Done when:** the step the shell fails is found (its DOS calls
    against NP2kai's) and either fixed with a bench or shown not to be a core bug.

/* probe2.s - first-touch hardware measurement for the PC-9821 (round 2).
 *
 * probe.s is frozen as the round-1 comparator: it writes before it reads
 * (so PROBE.TXT's 0x22/0x9A0 values are its own residue), it reprograms the DOS
 * tick and never restores it, and it flips the F8000 bank with interrupts
 * enabled. This program is read-first, section-selectable, and restores every
 * latch it touches.
 *
 *   PROBE2 > OUT.TXT          read-only snapshot (default: no writes at all)
 *   PROBE2 /PORTS > OUT.TXT   the read-only snapshot plus a wide port scan
 *   PROBE2 /ATA > OUT.TXT     bank/drive select, IDENTIFY, LBA 0 read
 *   PROBE2 /CAL > OUT.TXT     calendar mode latch and raw read stream
 *   PROBE2 /GDC > OUT.TXT     GDC status bit histograms
 *   PROBE2 /PCI > OUT.TXT     PCI config space probe
 *   PROBE2 /VRAM > OUT.TXT    GVRAM window read-after-write (restores)
 *   PROBE2 /SRST > OUT.TXT    ATA soft reset signature (restores)
 *   PROBE2 /WIN > OUT.TXT     0x461 / 0x463 window read (no writes)
 *   PROBE2 /WIN WRITE > O.TXT  ... plus the marker sweep (moves 0x461/0x463)
 *   PROBE2 /EMS > OUT.TXT     the 0x43F 0x2x window and read-back (restores)
 *   PROBE2 /D8 > OUT.TXT      0xD8000 option-ROM window (read-only)
 *   PROBE2 /D8 WRITE > O.TXT  ... plus the 0x53D states (KNOWN HAZARD: hangs a
 *                             machine with the IDE driver loaded - see README)
 *   PROBE2 /JOY > OUT.TXT     sound-board joystick register-select (restores)
 *   PROBE2 /INT1B > OUT.TXT   INT 1Bh vector/work-area read (no calls)
 *   PROBE2 /INT1B CALL > O.TXT ... plus the AH=8E/84/14/B0/24 calls (opt-in)
 *   PROBE2 /MODE > OUT.TXT    the 0x989x register file and the CPU-MODE SDIP
 *                             straps, each read twice (no writes)
 *   PROBE2 /ROMCK > OUT.TXT   the two ROM windows the ITF checksums (no writes)
 *   PROBE2 /MEMSW > OUT.TXT   the machine's memory-switch view: the 0530/0531
 *                             pair (read-only), the CG-window rows the ITF
 *                             reads, and the TRAM tail cells (CG regs restored)
 *   PROBE2 /MEMCNT > OUT.TXT  the memory-count instrument: the same pair
 *                             (read-only) plus the CG rows the ITF decodes for
 *                             its extended-size belief
 *   PROBE2 /MEMCNT WRITE > O  ... plus 0531 dumped at every 0530 index 00..FF
 *                             (writes only the 0530 address latch, restores it)
 *   PROBE2 /SHADOW > OUT.TXT  the writable ROM shadow F8000-FFFFF read under
 *                             several bank selections, the absent C0000-D7FFF
 *                             ROM area and the DA000 work-RAM window (no writes)
 *   PROBE2 /SHADOW WRITE > O  ... plus a marker byte at F8E90 and a 0xDA000
 *                             marker (KNOWN HAZARD: writes the running BIOS's
 *                             own shadow - see README)
 *   PROBE2 /XPORT > OUT.TXT   the six firmware-only port families and the ports
 *                             the machine answers where the core floats (no writes)
 *   PROBE2 /TIME > OUT.TXT    the timing ladder's ratios: the ARTIC counter,
 *                             the PIT counter-latch read, the I/O access time
 *                             per port class, the raster edge rates and the CPU
 *                             loop rate (writes only the stateless latch command
 *                             and the I/O-wait port)
 *   PROBE2 /TIME /TIMEREF > O the calendar as an absolute reference: the PIT and
 *                             ARTIC frequencies measured against its second, and
 *                             every /TIME ratio converted to Hz, ns and 50 MHz
 *                             core cycles (writes the calendar's command latch,
 *                             as the BIOS's own clock reader does)
 *   PROBE2 /TIME /TIMEREF /TIMESET > O
 *                             ... plus the ITF's TIMESET sequence, which writes
 *                             the calendar's own counters (KNOWN HAZARD for the
 *                             clock: replaces the time, not restorable)
 *   PROBE2 /RDBACK > O.TXT    write-then-read round-trips for the read-back
 *                             divergences found in the model (palette, GRCG,
 *                             DMA, 0x9A8/0x9A0/0x610/0x871E, 0x43D window, and
 *                             the GDC LPEN queue arms) - read-first, every
 *                             latch restored, several KNOWN-HAZARD writes
 *   PROBE2 /PIT > O.TXT        the PIT read byte-phase: latch vs control-word
 *                             reset, and LSB/MSB-only count-write round-trips
 *                             (reprograms ch0 to its measured divisor and
 *                             restores it)
 *   PROBE2 /VSYNC > VSYNC.TXT  VSYNC/IRQ2 delivery: unmaskes IRQ2 (master IMR
 *                             bit 2) for the window, counts delivered VSYNCs
 *                             against polled frames, forces edge-during-in-
 *                             service cases (drop-vs-hold, labelled directly),
 *                             and restores the IMR + INT 0Ah vector exactly.
 *                             ITS OWN BOOT (it reprograms interrupt state).
 *   PROBE2 /WIPE > WIPE.TXT    the C-Lab logo's wipe step (CS:0x2C0), replicated
 *                             in the game's own 640x400 mode: the CPU term
 *                             measured, 10 bracketed step replays (W2), the same
 *                             arm with the display blanked (W3) and with IRQ2
 *                             unmasked (W4), the raster period and line count
 *                             (W5) and the BIOS mode-set timeline (W6). Writes
 *                             GVRAM (scribbled, by design), the mode/GRCG/page
 *                             latches, and masters the IMR for W4C - all
 *                             restored from their saves. See
 *                             tools/hwprobe/probe2/wipe_decode.py.
 *   PROBE2 /ALL > OUT.TXT     snapshot + ports (read-only)
 *
 * The three most dangerous sections are inert unless their opt-in word is given:
 * /INT1B only inspects (CALL enters the option ROM), /WIN only reads (WRITE
 * moves the window), /D8 only reads (WRITE moves the ROM gate). /EMS and /JOY
 * write a latch, restore it, and are still opt-in relative to /ALL; /SHADOW
 * writes one byte of the running BIOS's own shadow and is also opt-in. No
 * writing section is part of /ALL: each one moves live memory (0x461),
 * re-points a loaded driver's window (0x43F), gates the option ROM (0x53D),
 * gates the work RAM (0x1E8E) or writes the BIOS shadow (0xF8E90). They are
 * opt-in and each restores and reports what it touched, so a crash can be
 * blamed on one line.
 *
 * The fingerprint tables never read a consume-on-read port: 0x41 (8251
 * keyboard data), 0x62 (GDC1 data) and 0x640/0x740 (ATA data) are sampled only
 * when their status register says nothing is pending, and otherwise print `--`.
 *
 * Every section prints BEGIN:<name> / END:<name>, so if a section hangs or
 * crashes the capture before it is still known to be valid. Output is plain
 * text on stdout; nothing is written to disk.
 *
 * Two assembler traps bit the round-1 probe: an 8-bit `out` with an immediate
 * above 0xFF silently truncates (0x043D became 0x3D, 0x09A0 became 0xA0), and
 * `in`/`out` with DX is the only safe form. Every port access here goes through
 * DX, including the low ones.
 */
    .code16
    .intel_syntax noprefix

    .section .text
    .global _start

/* ------------------------------------------------------------------ */
/* start                                                              */
/* ------------------------------------------------------------------ */
_start:
    /* The DOS console writes text VRAM, so the VRAM snapshot must be taken
     * before the first character of output exists. It is buffered and printed
     * later, after the work-area and latch reads. */
    call    snap_tram
    call    snap_workarea

    mov     ax, 0x3300          /* Ctrl-Break off: a ^C must not abandon a restore */
    int     0x21
    call    install_handlers

    /* Argument parsing reads the PSP tail directly, so no DOS call is needed
     * and no output is produced before the TRAM read above. */
    call    parse_args

    mov     si, offset msg_banner
    call    puts

    /* Read-only sections first, always, and in this order: they must run before
     * anything writes a latch, which is what makes them first-touch values. */
    mov     al, [flags]
    test    al, 0x01
    jz      1f
    call    sec_snapshot
1:  mov     al, [flags]
1:  test    al, 0x02
    jz      2f
    call    sec_ports
2:  mov     al, [flags]
2:  test    al, 0x20
    jz      3f
    call    sec_pci
3:  mov     al, [flags]
3:  test    al, 0x10
    jz      4f
    call    sec_gdc
4:  mov     al, [flags]
4:  test    al, 0x08
    jz      5f
    call    sec_cal
5:  mov     al, [flags]
5:  test    al, 0x04
    jz      6f
    call    sec_ata
6:  mov     al, [flags]
6:  test    al, 0x40
    jz      7f
    call    sec_vram
7:
    /* Round-10 sections. They run before /SRST, which must stay last because
     * it can leave a drive busy. */
    mov     al, [flags2]
    test    al, 0x01
    jz      11f
    call    sec_win
11: mov     al, [flags2]
    test    al, 0x02
    jz      12f
    call    sec_ems
12: mov     al, [flags2]
    test    al, 0x04
    jz      13f
    call    sec_d8
13: mov     al, [flags2]
    test    al, 0x08
    jz      14f
    call    sec_joy
14: mov     al, [flags2]
    test    al, 0x10
    jz      15f
    call    sec_int1b
15: mov     al, [flags2]
    test    al, 0x80            /* FLAG2_MODE: the 0x989x register file */
    jz      16f
    call    sec_mode
16: mov     al, [flags3]
    test    al, 0x01            /* FLAG3_ROMCK: the /ROMCK section */
    jz      17f
    call    sec_romck
17: mov     al, [flags3]
    test    al, 0x02            /* FLAG3_MEMSW: the /MEMSW section */
    jz      18f
    call    sec_memsw
18: mov     al, [flags3]
    test    al, 0x04            /* FLAG3_SHADOW: the /SHADOW section */
    jz      19f
    call    sec_shadow
19: mov     al, [flags3]
    test    al, 0x08            /* FLAG3_XPORT: the /XPORT section */
    jz      xport_done
    call    sec_xport
xport_done:
    /* The isolated families. Each runs alone so a hang names the family (the
     * block with no END:<tag>); /XPORT above runs them all in this order.
     *
     * BUG FIXED 2026-09: the flag bit is written as a bare hex literal, NOT the
     * `.equ` name. These `.equ`s are defined further down the file, and GNU as
     * assembles a *forward-referenced* `.equ` name in an operand as a MEMORY
     * reference: `test al, FLAG3_XP411` assembled to `test [0x10],al`. That is
     * (DS:0x0010) & AL, not AL & 0x10, so whether a family ran depended on a
     * DS-relative byte (the PSP, or whatever segment the previous section left
     * in DS) instead of its own flag - one keyword could run several families or
     * none, which is exactly the isolation this block exists to give. The
     * `or al, 0xNN` setters in the pa_* handlers below are *backward* references
     * and were always correct (`or al,0x10`). build2.sh now fails the build if a
     * `test al,<name>` reappears in this dispatch block. */
    mov     al, [flags3]
    test    al, 0x10            /* FLAG3_XP411 */
    jz      xp411_done
    call    sec_xp411
xp411_done:
    mov     al, [flags3]
    test    al, 0x20            /* FLAG3_XP0B0 */
    jz      xp0b0_done
    call    sec_xp0b0
xp0b0_done:
    mov     al, [flags3]
    test    al, 0x40            /* FLAG3_XP467 */
    jz      xp467_done
    call    sec_xp467
xp467_done:
    mov     al, [flags3]
    test    al, 0x80            /* FLAG3_XP535 */
    jz      xp535_done
    call    sec_xp535
xp535_done:
    mov     al, [flags4]
    test    al, 0x01            /* FLAG4_XP238 */
    jz      xp238_done
    call    sec_xp238
xp238_done:
    mov     al, [flags4]
    test    al, 0x02            /* FLAG4_XP18F */
    jz      xp18f_done
    call    sec_xp18f
xp18f_done:
    mov     al, [flags4]
    test    al, 0x04            /* FLAG4_XPFLT */
    jz      xpflt_done
    call    sec_xpflt
xpflt_done:
    mov     al, [flags4]
    test    al, 0x08            /* FLAG4_MEMCNT */
    jz      memcnt_done
    call    sec_memcnt
memcnt_done:
    mov     al, [flags4]
    test    al, 0x80            /* FLAG4_MEMRW */
    jz      memrw_done
    call    sec_memrw
memrw_done:
    /* The timing ladder. /TIME runs first because /TIMEREF converts its
     * rows with the rates /TIMEREF measures, so the two in one invocation give
     * nanosecond and hertz answers out of the run. The bits are bare hex
     * literals for the same reason as the six /XP* flags above: these .equ names
     * are defined below, and a forward-referenced .equ in an operand assembles
     * as a memory reference (build2.sh fails the build if that reappears). */
    mov     al, [flags4]
    test    al, 0x10            /* FLAG4_TIME */
    jz      time_done
    call    sec_time
time_done:
    mov     al, [flags4]
    test    al, 0x20            /* FLAG4_TIMEREF */
    jz      timeref_done
    call    sec_timeref
timeref_done:
    mov     al, [flags4]
    test    al, 0x40            /* FLAG4_TIMESET: /TIMEREF writes the calendar */
    jz      timeset_done
    /* The word on its own does nothing: /TIMESET is an opt-in modifier for
     * /TIMEREF, exactly as CALL modifies /INT1B. Saying so out loud is one
     * line and saves the reader a silent no-op. */
    mov     al, [flags4]
    test    al, 0x20
    jnz     timeset_done
    mov     si, offset msg_timeset_alone
    call    puts
timeset_done:
20:

    /* r13/hwprobe-followups: the write-then-read round-trips. They run before
     * /SRST (which must stay last) and after the read-only sections, so the
     * snapshot's first-touch values are untouched. */
    mov     al, [flags5]
    test    al, 0x01            /* FLAG5_RDBACK */
    jz      rdbk_done
    call    sec_rdback
rdbk_done:
    mov     al, [flags5]
    test    al, 0x02            /* FLAG5_PIT */
    jz      pitsec_done
    call    sec_pit
pitsec_done:
    mov     al, [flags5]
    test    al, 0x04            /* FLAG5_VSYNC */
    jz      vsyncsec_done
    call    sec_vsync
vsyncsec_done:
    mov     al, [flags5]
    test    al, 0x10            /* FLAG5_XP0BR: the 0B00/0B02 read-back */
    jz      xp0br_done
    call    sec_xp0br
xp0br_done:
    mov     al, [flags5]
    test    al, 0x08            /* FLAG5_WIPE: the C-Lab wipe-step replica */
    jz      wipesec_done
    call    sec_wipe
wipesec_done:

    mov     al, [flags]
    test    al, 0x80
    jz      8f
    call    sec_srst
8:
    call    report_restores

    mov     si, offset msg_done
    call    puts
    /* A failed self-check sets the DOS exit code, so a batch that redirects the
     * capture can tell a broken run from a good one without reading the file. */
    mov     al, 0
    cmp     byte ptr [run_fail], 0
    je      exit_code_ok
    mov     si, offset msg_runfail
    call    puts
    mov     al, 1
exit_code_ok:
    mov     ah, 0x4C
    int     0x21
    hlt

/* ------------------------------------------------------------------ */
/* section constants used in the CODE above their data section        */
/* ------------------------------------------------------------------ */
/* A bare `.equ` name in an operand assembles as a MEMORY reference when the
 * name is still undefined at that point (see the FLAG3_XP411 note in the
 * dispatch block): `mov cx, MRW_N` would assemble to `mov cx, ds:0x6`. These
 * two are defined here, above every use, so their operands are immediates. */
    .equ RESTORE_MAX, 32   /* restore-table entries (record_restore's overflow guard) */
    .equ MRW_N,      6     /* the six 0x530 indices /MEMRW walks */

/* ------------------------------------------------------------------ */
/* argument parsing: PSP:0x80 holds a length byte then the text       */
/* ------------------------------------------------------------------ */
    .equ FLAG_SNAP,  0x01
    .equ FLAG_PORTS, 0x02
    .equ FLAG_ATA,   0x04
    .equ FLAG_CAL,   0x08
    .equ FLAG_GDC,   0x10
    .equ FLAG_PCI,   0x20
    .equ FLAG_VRAM,  0x40
    .equ FLAG_SRST,  0x80

/* flags2: the round-10 sections plus their explicit opt-in words. A writing
 * sweep is inert unless its opt-in is present, so every section can be run on
 * its own without moving a latch -- which is what makes a crash attributable
 * to one probe. */
    .equ FLAG2_WIN,       0x01
    .equ FLAG2_EMS,       0x02
    .equ FLAG2_D8,        0x04
    .equ FLAG2_JOY,       0x08
    .equ FLAG2_INT1B,     0x10
/* One shared opt-in for the sections whose writes move live state. /WIN WRITE
 * sweeps the 0x461/0x463 window, /D8 WRITE sweeps the 0x53D states. */
    .equ FLAG2_WRITE,     0x20
    .equ FLAG2_INT1BCALL, 0x40
/* /ROMCK is read-only too (it reads the two ROM windows and the 0x43D
 * strap), so flags2 is full and it gets a third flags byte with bit 0 as its
 * flag. The flag is written as a bare hex literal: a bare `.equ` name in an
 * operand assembles as a memory reference, not an immediate. */
    .equ FLAG2_MODE,      0x80
    .equ FLAG3_ROMCK,     0x01
/* /MEMSW is read-only for the memory-switch pair: it reads 0x530/0x531 and the
 * TRAM tail cells, and its only writes are the ordinary CG code/line registers
 * 0xA1/0xA3/0xA5, which it puts back. It gets flags3 bit 1. */
    .equ FLAG3_MEMSW,     0x02
/* /SHADOW is read-only on its own (it reads the window and the two memory
 * ranges the shadow question asks about); its single marker write and the 0xDA000
 * work-RAM write are behind the same FLAG2_WRITE word as /WIN and /D8, because
 * the window holds the running BIOS. /XPORT is read-only with no opt-in at all:
 * it only reads ports. */
    .equ FLAG3_SHADOW,    0x04
    .equ FLAG3_XPORT,     0x08
/* The six firmware-only families are read behind one keyword each, so a run
 * that hangs is attributed to a family (the file with no END:XPnn) and, because
 * every port prints its own address before its first read, to the exact port
 * too. /XPORT still reads all of them, but it is the union and it will hang in
 * whichever family does; the isolated keywords are the recommended path.
 * flags3 is full after bit 3, so the rest live in flags4. */
    .equ FLAG3_XP411,     0x10
    .equ FLAG3_XP0B0,     0x20
    .equ FLAG3_XP467,     0x40
    .equ FLAG3_XP535,     0x80
    .equ FLAG4_XP238,     0x01
    .equ FLAG4_XP18F,     0x02
    .equ FLAG4_XPFLT,     0x04
/* /MEMCNT is the memory-count investigation's own instrument: it
 * reads the 0x530/0x531 pair and the user-CG rows the ITF decodes for its
 * extended-size belief, and with WRITE it dumps 0x531 across the whole 0x530
 * index range. It gets flags4 bit 3. */
    .equ FLAG4_MEMCNT,    0x08
/* The timing ladder. /TIME is the read-only ratio pass; /TIMEREF adds
 * the calendar-referenced absolute block (it writes the calendar's command
 * latch, which is what the ITF's own clock read does); /TIMESET is the opt-in
 * word that makes /TIMEREF write the calendar's COUNTERS as well, for a machine
 * whose backup battery is dead. flags4 bit 4 is the next free bit. */
    .equ FLAG4_TIME,      0x10
    .equ FLAG4_TIMEREF,   0x20
    .equ FLAG4_TIMESET,   0x40

    /* /MEMRW, the 0530/0531 pair's read/write test. This is the last
     * free bit in the flag words; a further section needs a fifth word. */
    .equ FLAG4_MEMRW,     0x80

    /* r13/hwprobe-followups: the read-back round-trip sections. flags4 is full,
     * so these take a fifth word. /RDBACK writes and restores latches (and, for
     * 0x43D and the two GDC command ports, issues the commands under test);
     * /PIT writes the PIT's control and count ports and reprograms channel 0 to
     * its measured divisor; /VSYNC unmaskes IRQ2 for its window and restores
     * the master IMR and the INT 0Ah vector exactly. */
    .equ FLAG5_RDBACK,    0x01
    .equ FLAG5_PIT,       0x02
    .equ FLAG5_VSYNC,     0x04

    /* The C-Lab wipe round: /WIPE replicates the game's own step (CS:0x2C0) in the
     * game's mode and prices it phase by phase, with the display contention, the
     * interrupt cost, the raster period and the mode-set timeline measured beside it.
     * It writes GVRAM, the mode/GRCG/page latches and (for W4C) the master IMR, so it
     * is opt-in like the other writing sections and must never join /ALL. */
    .equ FLAG5_WIPE,      0x08

    /* /XP0BR: the 0B00/0B02 index/data pair's write-then-read-back. It is an
     * opt-in writing section (it writes the 0B00 index word and the 0B02 data
     * byte and puts both back), so it does not join /XPORT, which is read-only. */
    .equ FLAG5_XP0BR,     0x10
    .equ XBR_N,           6      /* the six indices the ITF writes to 0B00 */

    /* /WIPE's own constants (the replica's shapes; the source header says which
     * game constants they stand in for). */
    .equ WIPE_STEPS,        10     /* steps per arm */
    .equ WIPE_ROWS,         100    /* the step's row count (0x376 cmp ...,0x63) */
    .equ WIPE_FILL_WORDS,   4000   /* the 0xFFFF fill's word count (0x2D6 push 0x1f40) */
    .equ WIPE_BLIT_WORDS,   20     /* per-row movsw words (0x370 push 0x28, shr cx,1) */
    .equ WIPE_ROW_STRIDE,   80     /* one GDC line of one plane */
    .equ WIPE_BLIT_BASE,    0x2EE0 /* the fill's own base in the 0xA8000 window */
    .equ WIPE_DIV,          0xC4   /* the row body's idiv divisor (safe; see the header) */
    .equ WIPE_ARITH_MASK,   0x7F   /* a no-op for the game's 0..99 index */
    .equ WIPE_ALU_OUTER,    0x100
    .equ WIPE_ALU_INNER,    0x1000
    .equ WIPE_W1_ROWS,      9900   /* 100 rows x 99 steps */
    .equ WIPE_RASTER_FRAMES, 64    /* W5's window: 64 frames = ~1.13 s */
    .equ WP_ARM_W2,  0
    .equ WP_ARM_W3,  1
    .equ WP_ARM_W3B, 2
    .equ WP_ARM_W4A, 3
    .equ WP_ARM_W4B, 4
    .equ WP_ARM_W4C, 5
    .equ WP_MODE_DISPON,   0
    .equ WP_MODE_BLANK,    1
    .equ WP_MODE_DISPON2,  2
    .equ WP_MODE_IRQMASK,  3
    .equ WP_MODE_IRQNORM,  4
    .equ WP_MODE_IRQ2,     5

    /* /VSYNC's window sizes. VS_FRAMES is the idle and load phase length (30
     * frames = 0.53 s each, the length the 2026-09-23 run used);
     * VS_HOLD_EDGES is how many edges land inside the forced in-service window;
     * VS_LOAD_WORDS is the load burst (512 words ~20 us, against a ~320 us
     * VSYNC pulse); VS_SETTLE is the PIT-independent post-EOI pause. */
    .equ VS_FRAMES,       30
    .equ VS_HOLD_EDGES,   3
    .equ VS_LOAD_WORDS,   512
    .equ VS_SETTLE,       0x400

    /* The bound on phase C's last edge wait (vs_wait_edge_to). 4 x 65535 polls, and
     * a poll is one 0xA0 read at the measured >= 600 ns I/O class floor, so it cannot
     * expire in under ~150 ms - several frames at the 17.7 ms this machine runs. It is
     * there so a stopped raster cannot leave INT 0Ah pointing into the probe with the
     * masked IMR still cleared, not to measure anything. */
    .equ VS_EDGE_TIMEOUT, 4
/* 0x0461's identity value: writing 0x08 makes the 80000-9FFFF window map to
 * itself (measured, /WIN: `0461=08 ... p=08 q=09`), so 98E8:0010 then reads
 * true physical 0x98E90. */
    .equ SH_461_IDENTITY, 0x08

parse_args:
    push    ax
    push    bx
    push    cx
    push    si
    /* Default with no arguments is the read-only snapshot only: the safest
     * useful measurement, and the one that must not be contaminated. */
    mov     byte ptr [flags], FLAG_SNAP
    mov     bx, 0x80
    mov     cl, [bx]            /* length of the tail */
    xor     ch, ch
    inc     bx
    test    cx, cx
    jz      pa_done
pa_scan:
    mov     al, [bx]
    /* A section name is introduced by '/' (or '-' if DOS's swchar was changed). */
    cmp     al, '/'
    je      pa_slash
    cmp     al, '-'
    je      pa_slash
    /* The two opt-in words are also accepted without a slash, so the command
     * line reads naturally: PROBE2 /INT1B CALL, PROBE2 /WIN WRITE. */
    cmp     al, 'C'
    je      pa_bare
    cmp     al, 'c'
    je      pa_bare
    cmp     al, 'W'
    je      pa_bare
    cmp     al, 'w'
    je      pa_bare
pa_next:
    inc     bx
    dec     cx
    jnz     pa_scan
pa_done:
    /* /ALL is the read-only convenience: the snapshot plus the port fingerprint.
     * Every section that writes a latch, issues a command or enters firmware
     * stays opt-in, so /ALL cannot be the section that crashes and every writing
     * section can be blamed on its own. In particular /ALL must never enable
     * /D8: its 0x53D write hangs a machine with the IDE driver loaded, and
     * build2.sh enforces that only sec_d8 contains a 0x53D writer. */
    cmp     byte ptr [all_seen], 0
    jz      pa_ret
    mov     al, [flags]
    or      al, 0x02
    mov     [flags], al
pa_ret:
    pop     si
    pop     cx
    pop     bx
    pop     ax
    ret
pa_slash:
    push    bx
    mov     si, bx
    inc     si
    jmp     pa_word
pa_bare:
    push    bx
    mov     si, bx
pa_word:
    /* Compare the characters at DS:SI against the known names. CALL is
     * checked before CAL and WRITE before WIN: arg_match is a prefix match, so
     * the longer names must come first or `/CAL` would swallow `/CALL`. */
    mov     di, offset arg_call
    call    arg_match
    jc      pa_call
    mov     di, offset arg_write
    call    arg_match
    jc      pa_write
    mov     di, offset arg_all
    call    arg_match
    jc      pa_all
    mov     di, offset arg_ports
    call    arg_match
    jc      pa_ports
    mov     di, offset arg_ata
    call    arg_match
    jc      pa_ata
    mov     di, offset arg_cal
    call    arg_match
    jc      pa_cal
    mov     di, offset arg_gdc
    call    arg_match
    jc      pa_gdc
    mov     di, offset arg_pci
    call    arg_match
    jc      pa_pci
    mov     di, offset arg_vram
    call    arg_match
    jc      pa_vram
    mov     di, offset arg_srst
    call    arg_match
    jc      pa_srst
    /* The timing sections. TIMESET and TIMEREF are checked before TIME
     * because arg_match is a prefix match: "TIME" is a prefix of both, so the
     * longer names must come first or `/TIMEREF` would be read as `/TIME` (the
     * same trap that puts CALL before CAL). */
    mov     di, offset arg_timeset
    call    arg_match
    jc      pa_timeset
    mov     di, offset arg_timeref
    call    arg_match
    jc      pa_timeref
    mov     di, offset arg_time
    call    arg_match
    jc      pa_time
    mov     di, offset arg_wipe
    call    arg_match
    jc      pa_wipe
    mov     di, offset arg_win
    call    arg_match
    jc      pa_win
    mov     di, offset arg_ems
    call    arg_match
    jc      pa_ems
    mov     di, offset arg_d8
    call    arg_match
    jc      pa_d8
    mov     di, offset arg_joy
    call    arg_match
    jc      pa_joy
    mov     di, offset arg_int1b
    call    arg_match
    jc      pa_int1b
    mov     di, offset arg_mode
    call    arg_match
    jc      pa_mode
    mov     di, offset arg_romck
    call    arg_match
    jc      pa_romck
    mov     di, offset arg_memsw
    call    arg_match
    jc      pa_memsw
    /* MEMCNT: /MEMSW's name is not a prefix of it and it is not a prefix of
     * /MEMSW, so their order does not matter. */
    mov     di, offset arg_memcnt
    call    arg_match
    jc      pa_memcnt
    /* MEMRW: neither name is a prefix of the other - they diverge at the
     * fourth character ("MEMC" against "MEMR") - so their order here does not
     * matter. */
    mov     di, offset arg_memrw
    call    arg_match
    jc      pa_memrw
    mov     di, offset arg_rdback
    call    arg_match
    jc      pa_rdback
    mov     di, offset arg_pit
    call    arg_match
    jc      pa_pit
    mov     di, offset arg_vsync
    call    arg_match
    jc      pa_vsync
    mov     di, offset arg_shadow
    call    arg_match
    jc      pa_shadow
    mov     di, offset arg_xport
    call    arg_match
    jc      pa_xport
    /* The isolated /XPORT families. None of these names is a prefix of another
     * (or of XPORT), so their order among themselves does not matter. */
    mov     di, offset arg_xp411
    call    arg_match
    jc      pa_xp411
    mov     di, offset arg_xp0b0
    call    arg_match
    jc      pa_xp0b0
    mov     di, offset arg_xp0br
    call    arg_match
    jc      pa_xp0br
    mov     di, offset arg_xp467
    call    arg_match
    jc      pa_xp467
    mov     di, offset arg_xp535
    call    arg_match
    jc      pa_xp535
    mov     di, offset arg_xp238
    call    arg_match
    jc      pa_xp238
    mov     di, offset arg_xp18f
    call    arg_match
    jc      pa_xp18f
    mov     di, offset arg_xpflt
    call    arg_match
    jc      pa_xpflt
    pop     bx
    jmp     pa_next
pa_all:
    mov     byte ptr [all_seen], 1
    pop     bx
    jmp     pa_next
pa_ports:
    mov     al, [flags]
    or      al, 0x02
    mov     [flags], al
    pop     bx
    jmp     pa_next
pa_ata:
    mov     al, [flags]
    or      al, 0x04
    mov     [flags], al
    pop     bx
    jmp     pa_next
pa_cal:
    mov     al, [flags]
    or      al, 0x08
    mov     [flags], al
    pop     bx
    jmp     pa_next
pa_gdc:
    mov     al, [flags]
    or      al, 0x10
    mov     [flags], al
    pop     bx
    jmp     pa_next
pa_pci:
    mov     al, [flags]
    or      al, 0x20
    mov     [flags], al
    pop     bx
    jmp     pa_next
pa_vram:
    mov     al, [flags]
    or      al, 0x40
    mov     [flags], al
    pop     bx
    jmp     pa_next
pa_srst:
    mov     al, [flags]
    or      al, 0x80
    mov     [flags], al
    pop     bx
    jmp     pa_next
pa_win:
    mov     al, [flags2]
    or      al, 0x01
    mov     [flags2], al
    pop     bx
    jmp     pa_next
pa_ems:
    mov     al, [flags2]
    or      al, 0x02
    mov     [flags2], al
    pop     bx
    jmp     pa_next
pa_d8:
    mov     al, [flags2]
    or      al, 0x04
    mov     [flags2], al
    pop     bx
    jmp     pa_next
pa_joy:
    mov     al, [flags2]
    or      al, 0x08
    mov     [flags2], al
    pop     bx
    jmp     pa_next
pa_int1b:
    mov     al, [flags2]
    or      al, FLAG2_INT1B
    mov     [flags2], al
    pop     bx
    jmp     pa_next
pa_mode:
    mov     al, [flags2]
    or      al, FLAG2_MODE
    mov     [flags2], al
    pop     bx
    jmp     pa_next
pa_romck:
    mov     al, [flags3]
    or      al, 0x01            /* FLAG3_ROMCK */
    mov     [flags3], al
    pop     bx
    jmp     pa_next
pa_memsw:
    mov     al, [flags3]
    or      al, 0x02            /* FLAG3_MEMSW */
    mov     [flags3], al
    pop     bx
    jmp     pa_next
pa_memcnt:
    mov     al, [flags4]
    or      al, FLAG4_MEMCNT
    mov     [flags4], al
    pop     bx
    jmp     pa_next
pa_memrw:
    mov     al, [flags4]
    or      al, FLAG4_MEMRW
    mov     [flags4], al
    pop     bx
    jmp     pa_next
pa_shadow:
    mov     al, [flags3]
    or      al, 0x04            /* FLAG3_SHADOW */
    mov     [flags3], al
    pop     bx
    jmp     pa_next
pa_xport:
    mov     al, [flags3]
    or      al, 0x08            /* FLAG3_XPORT */
    mov     [flags3], al
    pop     bx
    jmp     pa_next
pa_xp411:
    mov     al, [flags3]
    or      al, FLAG3_XP411
    mov     [flags3], al
    pop     bx
    jmp     pa_next
pa_xp0b0:
    mov     al, [flags3]
    or      al, FLAG3_XP0B0
    mov     [flags3], al
    pop     bx
    jmp     pa_next
pa_xp467:
    mov     al, [flags3]
    or      al, FLAG3_XP467
    mov     [flags3], al
    pop     bx
    jmp     pa_next
pa_xp535:
    mov     al, [flags3]
    or      al, FLAG3_XP535
    mov     [flags3], al
    pop     bx
    jmp     pa_next
pa_xp238:
    mov     al, [flags4]
    or      al, FLAG4_XP238
    mov     [flags4], al
    pop     bx
    jmp     pa_next
pa_xp18f:
    mov     al, [flags4]
    or      al, FLAG4_XP18F
    mov     [flags4], al
    pop     bx
    jmp     pa_next
pa_xpflt:
    mov     al, [flags4]
    or      al, FLAG4_XPFLT
    mov     [flags4], al
    pop     bx
    jmp     pa_next
pa_call:
    mov     al, [flags2]
    or      al, FLAG2_INT1BCALL
    mov     [flags2], al
    pop     bx
    jmp     pa_next
pa_write:
    mov     al, [flags2]
    or      al, FLAG2_WRITE
    mov     [flags2], al
    pop     bx
    jmp     pa_next
pa_time:
    mov     al, [flags4]
    or      al, FLAG4_TIME
    mov     [flags4], al
    pop     bx
    jmp     pa_next
pa_timeref:
    mov     al, [flags4]
    or      al, FLAG4_TIMEREF
    mov     [flags4], al
    pop     bx
    jmp     pa_next
pa_timeset:
    mov     al, [flags4]
    or      al, FLAG4_TIMESET
    mov     [flags4], al
    pop     bx
    jmp     pa_next
pa_rdback:
    mov     al, [flags5]
    or      al, FLAG5_RDBACK
    mov     [flags5], al
    pop     bx
    jmp     pa_next
pa_pit:
    mov     al, [flags5]
    or      al, FLAG5_PIT
    mov     [flags5], al
    pop     bx
    jmp     pa_next
pa_vsync:
    mov     al, [flags5]
    or      al, FLAG5_VSYNC
    mov     [flags5], al
    pop     bx
    jmp     pa_next
pa_wipe:
    mov     al, [flags5]
    or      al, FLAG5_WIPE
    mov     [flags5], al
    pop     bx
    jmp     pa_next
pa_xp0br:
    mov     al, [flags5]
    or      al, FLAG5_XP0BR
    mov     [flags5], al
    pop     bx
    jmp     pa_next

/* arg_match: DS:SI = text after the slash, DS:DI = candidate name (NUL ended).
 * Returns CF set when the candidate matches case-insensitively. */
arg_match:
    push    ax
    push    si
    push    di
am_loop:
    mov     al, [di]
    test    al, al
    jz      am_hit
    mov     ah, [si]
    /* Fold to upper case so /ata and /ATA both work. */
    cmp     ah, 'a'
    jb      1f
    cmp     ah, 'z'
    ja      1f
    sub     ah, 0x20
1:  cmp     al, ah
    jne     am_miss
    inc     si
    inc     di
    jmp     am_loop
am_hit:
    pop     di
    pop     si
    pop     ax
    stc
    ret
am_miss:
    pop     di
    pop     si
    pop     ax
    clc
    ret

/* ------------------------------------------------------------------ */
/* output helpers (all output goes through INT 21h, so it is           */
/* redirectable, and none of them touch VRAM directly)                 */
/* ------------------------------------------------------------------ */
putc:                           /* DL */
    push    ax
    mov     ah, 0x02
    int     0x21
    pop     ax
    ret

putnl:
    push    dx
    mov     dl, 0x0D
    call    putc
    mov     dl, 0x0A
    call    putc
    pop     dx
    ret

putsp:
    push    dx
    mov     dl, ' '
    call    putc
    pop     dx
    ret

puts:                           /* DS:SI, NUL terminated */
    push    ax
    push    si
ps_loop:
    mov     al, [si]
    test    al, al
    jz      ps_done
    mov     dl, al
    call    putc
    inc     si
    jmp     ps_loop
ps_done:
    pop     si
    pop     ax
    ret

puthex8:                        /* AL */
    push    ax
    push    cx
    mov     cl, al
    shr     al, 4
    call    puthexdig
    mov     al, cl
    and     al, 0x0F
    call    puthexdig
    pop     cx
    pop     ax
    ret

puthexdig:                      /* AL = 0..15 */
    push    dx
    and     al, 0x0F
    cmp     al, 10
    jb      1f
    add     al, 'A' - 10
    jmp     2f
1:  add     al, '0'
2:  mov     dl, al
    call    putc
    pop     dx
    ret

puthex16:                       /* AX */
    push    ax
    mov     al, ah
    call    puthex8
    pop     ax
    call    puthex8
    ret

puthex32:                       /* EAX */
    push    eax
    shr     eax, 16
    call    puthex16
    pop     eax
    call    puthex16
    ret

/* putport: DX = port, AL = value -> "PPPP=VV" */
putport:                        /* DX = port, AL = value -> "PPPP=VV" */
    push    ax
    push    bx
    push    dx
    mov     bx, ax              /* keep the value */
    mov     ax, dx              /* the port */
    xchg    al, ah              /* print the high byte first */
    call    puthex8
    mov     al, ah
    call    puthex8
    mov     dl, '='             /* putc writes DL, so the old AL form printed
                                   the port's low byte as the separator */
    call    putc
    mov     al, bl
    call    puthex8
    pop     dx
    pop     bx
    pop     ax
    ret

/* read_byte: DX = port -> AL. CF set means the read was deliberately skipped.
 *
 * Three families of port consume state when read, so the fingerprint tables
 * must never touch them: 0x41 is the 8251 keyboard data register (a read eats
 * a scancode, so the DOS session loses a keystroke), 0x62 is the GDC1 text
 * data register (a read drains its read FIFO), and 0x640/0x740 are the ATA
 * data registers (a read drains a word if a transfer is in flight). Each is
 * read only when its owning status register says no data is pending. */
read_byte:
    cmp     dx, 0x0041
    je      rb_kbd
    cmp     dx, 0x0062
    je      rb_gdc
    cmp     dx, 0x0640
    je      rb_ata0
    cmp     dx, 0x0641
    je      rb_ata0
    cmp     dx, 0x0740
    je      rb_ata1
    cmp     dx, 0x0741
    je      rb_ata1
    in      al, dx
    clc
    ret
rb_kbd:
    push    dx
    mov     dx, 0x0043          /* 8251 status: bit 1 = RxRDY */
    in      al, dx
    test    al, 0x02
    pop     dx
    jnz     rb_skip
    in      al, dx
    clc
    ret
rb_gdc:
    push    dx
    mov     dx, 0x0060          /* GDC1 status: bit 0 = data ready */
    in      al, dx
    test    al, 0x01
    pop     dx
    jnz     rb_skip
    in      al, dx
    clc
    ret
rb_ata0:
    push    dx
    mov     dx, 0x064E          /* ATA status: BSY or DRQ = data pending */
    in      al, dx
    test    al, 0x88
    pop     dx
    jnz     rb_skip
    in      al, dx
    clc
    ret
rb_ata1:
    push    dx
    mov     dx, 0x074E
    in      al, dx
    test    al, 0x88
    pop     dx
    jnz     rb_skip
    in      al, dx
    clc
    ret
rb_skip:
    mov     al, 0xFF
    stc
    ret

/* write_byte: DX = port, AL = value. Records (port, old value) so the restore
 * report can prove the machine was put back. Every caller of this must have a
 * matching restore entry, and none of them may write a port that is not in the
 * latch set the round-1 audit listed. */
write_byte:
    push    ax
    push    bx
    push    dx
    mov     bl, al
    in      al, dx              /* first-touch value, before the write */
    mov     bh, al
    mov     al, bl
    out     dx, al
    pop     dx
    push    dx
    call    record_restore      /* DX = port, BH = original */
    pop     dx
    pop     bx
    pop     ax
    ret

record_restore:                 /* DX = port, BH = original value */
    push    ax
    push    bx
    push    si
    push    di
    mov     si, [restore_n]
    /* One entry per port. The first write to a port captured the true
     * pre-probe value; a later duplicate would record a value this probe
     * itself wrote, so the restore would put back the probe's residue. */
    xor     di, di
rr_scan:
    cmp     di, si
    jae     rr_add
    push    di
    shl     di, 2
    cmp     dx, [restore_tab + di]
    pop     di
    je      rr_done
    inc     di
    jmp     rr_scan
rr_add:
    cmp     si, RESTORE_MAX
    jae     rr_full
    mov     di, si
    shl     di, 2               /* four bytes per entry */
    mov     [restore_tab + di], dx
    mov     [restore_tab + di + 2], bx
    inc     word ptr [restore_n]
    jmp     rr_done
rr_full:
    inc     word ptr [restore_dropped]
rr_done:
    pop     di
    pop     si
    pop     bx
    pop     ax
    ret

/* rrs_mute: DX = port, BH = the recorded value. The 8251/calendar command
 * register and the two ATA command/control registers do not read back what was
 * written: 0x20 reads the calendar data port, 0x64E reads ATA status and
 * 0x74C reads alternate status, so writing the read-back there would issue a
 * command (0x50 is FORMAT TRACK) or assert SRST. Those are reported, not
 * replayed. */
rrs_mute:
    cmp     dx, 0x0020
    je      rrs_mute_hit
    cmp     dx, 0x064E
    je      rrs_mute_hit
    cmp     dx, 0x074C
    je      rrs_mute_hit
    clc
    ret
rrs_mute_hit:
    stc
    ret

/* report_restores: replay the saved values in reverse and print was -> now. */
report_restores:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    mov     si, offset msg_restore
    call    puts
    mov     cx, [restore_n]
    test    cx, cx
    jz      rrs_none
rrs_loop:
    dec     cx
    push    cx
    mov     si, cx
    shl     si, 2
    mov     dx, [restore_tab + si]
    mov     bx, [restore_tab + si + 2]
    call    rrs_mute
    jc      rrs_muted
    mov     al, bh              /* put the original back (write_byte stored the
                                   first-touch read in BH, note_restore the
                                   value the section already restored) */
    out     dx, al
    in      al, dx
    mov     bl, al              /* now */
    mov     al, bh
    call    putport             /* prints port=original */
    mov     si, offset msg_arrow
    call    puts
    mov     al, bl
    call    puthex8
    call    putnl
    jmp     rrs_next
rrs_muted:
    mov     al, bh
    call    putport
    mov     si, offset msg_mute
    call    puts
rrs_next:
    pop     cx
    test    cx, cx
    jnz     rrs_loop
    jmp     rrs_done
rrs_none:
    cmp     byte ptr [inline_used], 0
    jne     rrs_inline
    mov     si, offset msg_none
    call    puts
    jmp     rrs_done
rrs_inline:
    mov     si, offset msg_inline_note
    call    puts
rrs_done:
    cmp     word ptr [restore_dropped], 0
    jz      rrs_nofull
    mov     si, offset msg_restore_full
    call    puts
    mov     ax, [restore_dropped]
    call    puthex16
    call    putnl
rrs_nofull:
    /* The PIT counter-latch command is the one write the report cannot carry: it
     * is stateless, and 0077's read-back (FF) is a PIT mode word, so replaying
     * it would reprogram the part. /TIME says so itself, and this repeats it in
     * the block a reader checks for residue. */
    cmp     byte ptr [tm_used], 0
    jz      rrs_no_latch
    mov     si, offset msg_time_latch
    call    puts
rrs_no_latch:
    /* The calendar's command latch is the other write the report cannot carry:
     * 0020 is write-only, its read-back is FF, and replaying FF would pulse STB
     * with DATA = 1 - a command, not a restore. The sequence leaves the latch at
     * 07, which is where the ITF's own reader leaves it. */
    cmp     byte ptr [tr_used], 0
    jz      rrs_no_cal
    mov     si, offset msg_tr_latch
    call    puts
rrs_no_cal:
    /* /VSYNC is the one write section whose latch write the ledger CAN carry:
     * the master IMR (0002) goes through write_byte, so the row above proves it
     * went back. Its stateless writes cannot be replayed and are named here, as
     * idelat's task-file writes and /TIME's PIT latch command are. */
    cmp     byte ptr [vs_used], 0
    jz      rrs_no_vs
    mov     si, offset msg_vs_latch
    call    puts
rrs_no_vs:
    cmp     byte ptr [wp_used], 0
    jz      rrs_no_wp
    mov     si, offset msg_wp_latch
    call    puts
rrs_no_wp:
    /* 0x43F/0x461/0x463/0x53D answer with a strap state, not a mirror of the
     * byte written, so their read-back cannot prove the restore either way. */
    mov     si, offset msg_strap
    call    puts
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* ------------------------------------------------------------------ */
/* snapshots that must happen before any output                       */
/* ------------------------------------------------------------------ */
/* snap_tram: copy the machine's text VRAM into tram_buf.
 *
 * DIRECTION BUG (fixed). This
 * routine used to set ES = 0xA000 with DI = offset tram_buf and then run
 * `rep movsb`, which moves DS:SI -> ES:DI: with the VRAM segment as the
 * DESTINATION it never read TRAM at all. It wrote 320 bytes of the PROBE's own
 * data segment into 0xA0000 and 0xA2000 -- so every TRAM "capture" in the
 * round-1/round-2 files is the probe's own memory, and the probe was silently
 * corrupting the machine's first text rows while the capture header claimed
 * "no writes were made". Do not trust any TRAM or work-area reading taken
 * before this fix; re-measure before relying on the memory-switch seeds.
 *
 * Correct form: DS = VRAM (source), ES = the probe's own segment (destination).
 */
snap_tram:
    push    ax
    push    cx
    push    si
    push    di
    push    ds
    push    es
    mov     ax, ds              /* ES = the probe's data segment */
    mov     es, ax
    mov     ax, 0xA000
    mov     ds, ax              /* DS = VRAM: this is the SOURCE */
    xor     si, si              /* 0xA0000: character plane */
    mov     di, offset tram_buf
    mov     cx, 160
    cld
    rep     movsb
    mov     si, 0x2000          /* 0xA2000: attribute plane */
    mov     cx, 160
    rep     movsb
    /* The TRAM tail. This is the whole point of the 2026-09-12 revision: the
     * RTL seeds the ITF's row counter at 0xA3FE0 and the eight memory-switch
     * cells at 0xA3FE2+i*4 from values quoted as measured, but snap_tram used
     * to stop after 160 cells of each plane and NO routine in this probe ever
     * touched 0xA3Fxx at all -- so those seeds never had a measurement behind
     * them. Read-only: nothing here writes. */
    mov     si, 0x3FE0
    mov     di, offset tram_tail_buf
    mov     cx, 32
    rep     movsb
    /* The switch cells are quoted as 0xA3FE2+i*4, which runs past 0xA3FFF into
     * the CG window at 0xA4000. Read across the boundary so the next run can
     * say which side actually holds machine-description bytes. */
    mov     si, 0x4000
    mov     di, offset cg_head_buf
    mov     cx, 16
    rep     movsb
    pop     es
    pop     ds
    pop     di
    pop     si
    pop     cx
    pop     ax
    ret

snap_workarea:
    push    ax
    push    cx
    push    si
    push    di
    push    ds
    push    es
    /* SAME DIRECTION BUG as snap_tram (fixed 2026-09-12): this used to set BOTH
     * DS and ES to 0 and then run `rep movsb`, which copies 0000:0400 ->
     * 0000:wa_buf -- it never filled wa_buf at all, and it scribbled 512 bytes
     * of the BIOS work area over low memory (offset wa_buf, i.e. near the IVT
     * and BDA, or over the probe's own image). DS = 0 is the source; ES must
     * stay the probe's own segment for the destination. */
    xor     ax, ax
    mov     ds, ax              /* the BIOS work area is at 0000:0400 */
    mov     si, 0x0400
    mov     di, offset wa_buf
    mov     cx, 512
    cld
    rep     movsb
    pop     es
    pop     ds
    pop     di
    pop     si
    pop     cx
    pop     ax
    ret

/* ------------------------------------------------------------------ */
/* section: read-only snapshot                                        */
/* ------------------------------------------------------------------ */
sec_snapshot:
    mov     si, offset msg_begin_snap
    call    puts

    mov     si, offset msg_wa
    call    puts
    call    dump_hexblock       /* wa_buf is already in memory: 512 bytes */

    mov     si, offset msg_tram
    call    puts
    mov     si, offset tram_buf
    mov     cx, 320
    call    dump_mem
    mov     si, offset msg_tram_tail
    call    puts
    mov     si, offset tram_tail_buf
    mov     cx, 32
    call    dump_mem
    mov     si, offset msg_cg_head
    call    puts
    mov     si, offset cg_head_buf
    mov     cx, 16
    call    dump_mem

    /* Latches, first-touch, byte and its odd partner so a 16-bit decode can be
     * told from two independent byte registers. */
    mov     si, offset tab_latches
    call    dump_port_table
    mov     si, offset msg_port_note
    call    puts

    /* The ATA command block without selecting anything first: this is what the
     * POST and DOS left pointed at, and it is the only reading that can say
     * whether the block is live or floating. */
    mov     si, offset msg_ata_block
    call    puts
    mov     si, offset tab_ata
    call    dump_port_table

    mov     si, offset msg_window
    call    puts
    mov     dx, 0x043D
    call    read_byte
    push    ax
    mov     si, offset msg_43d
    call    puts
    pop     ax
    call    puthex8
    call    putsp
    mov     dx, 0x043F
    call    read_byte
    push    ax
    mov     si, offset msg_43f
    call    puts
    pop     ax
    call    puthex8
    call    putnl
    /* The window byte in whatever bank is currently selected. */
    push    es
    mov     ax, 0xF800
    mov     es, ax
    xor     si, si
    mov     al, es:[si]
    pop     es
    push    ax
    mov     si, offset msg_f8000
    call    puts
    pop     ax
    call    puthex8
    call    putnl

    /* 0xF8E90: the IDE option ROM's drive-candidate bitmap. BANK3@0x19D2 reads
     * physical 0xF8E90 (mov ax,0xF8E8; mov al,es:0x10) to decide which slots to
     * probe; the shipped BIOS.ROM has 0x04 there and BANK7.BIN has 0x00, because
     * the ITF rewrites the writable shadow copy at runtime. Reading it at the
     * DOS prompt settles which value the running ITF left. Read-only. */
    push    es
    mov     ax, 0xF8E9
    mov     es, ax
    mov     al, es:[0]
    mov     [f8e90_b], al
    mov     al, es:[1]
    mov     [f8e90_b1], al
    mov     ax, es:[0]
    mov     [f8e90_w], ax
    pop     es
    mov     si, offset msg_f8e90
    call    puts
    mov     al, [f8e90_b]
    call    puthex8
    call    putsp
    mov     al, [f8e90_b1]
    call    puthex8
    call    putsp
    mov     ax, [f8e90_w]
    call    puthex16
    call    putnl

    mov     si, offset msg_end_snap
    call    puts
    ret

/* dump_port_table: DS:SI = table of words, 0xFFFF terminated. Prints each port
 * and its odd partner. No writes, so first-touch values survive. A consume-on-
 * read port (see read_byte) prints `--` instead of a value it never sampled. */
dump_port_table:
    push    ax
    push    dx
    push    si
dpt_loop:
    mov     dx, [si]
    cmp     dx, 0xFFFF
    je      dpt_done
    add     si, 2
    call    dpt_one
    call    putsp
    inc     dx
    call    dpt_one
    call    putnl
    jmp     dpt_loop
dpt_done:
    pop     si
    pop     dx
    pop     ax
    ret

dpt_one:                        /* DX = port */
    call    read_byte
    jc      dpt_skip
    call    putport
    ret
dpt_skip:
    push    dx                  /* the port digits are printed by hand; putc
                                   writes DL, so DX must survive */
    mov     ax, dx
    xchg    al, ah
    call    puthex8
    mov     al, ah
    call    puthex8
    mov     dl, '='
    call    putc
    mov     dl, '-'
    call    putc
    mov     dl, '-'
    call    putc
    pop     dx
    ret

/* dump_mem: DS:SI = bytes, CX = count, 16 per line. */
dump_mem:
    push    ax
    push    bx
    push    cx
    push    si
dm_loop:
    test    cx, cx
    jz      dm_done
    mov     al, [si]
    call    puthex8
    call    putsp
    inc     si
    dec     cx
    mov     bx, si
    and     bx, 0x0F
    jnz     dm_loop
    call    putnl
    jmp     dm_loop
dm_done:
    call    putnl
    pop     si
    pop     cx
    pop     bx
    pop     ax
    ret

dump_hexblock:
    push    cx
    push    si
    mov     si, offset wa_buf
    mov     cx, 512
    call    dump_mem
    pop     si
    pop     cx
    ret

/* ------------------------------------------------------------------ */
/* section: wide port scan (read-only)                                */
/* ------------------------------------------------------------------ */
sec_ports:
    mov     si, offset msg_begin_ports
    call    puts
    mov     si, offset tab_ports
    call    dump_port_table
    mov     si, offset msg_sdip
    call    puts
    /* The SDIP switch latches are at 0x841E + n*0x100; read the first 16 and
     * the 0x8F1F terminator, which is where the firmware finds them. */
    mov     bx, 0
sp_sdip:
    push    bx
    mov     dx, 0x841E
    mov     ax, bx
    mov     cl, 8
    shl     ax, cl
    add     dx, ax
    call    read_byte
    call    putport
    call    putsp
    pop     bx
    inc     bx
    cmp     bx, 16
    jb      sp_sdip
    call    putnl
    mov     dx, 0x8F1F
    call    read_byte
    call    putport
    call    putnl
    mov     si, offset msg_end_ports
    call    puts
    ret

/* ------------------------------------------------------------------ */
/* section: PCI config space probe                                    */
/* ------------------------------------------------------------------ */
sec_pci:
    mov     si, offset msg_begin_pci
    call    puts
    /* Read the address and data ports first, then ask for bus 0 device 0
     * function 0 register 0. A vendor id of 0xFFFF means nothing answered, but
     * any non-0xFFFFFFFF data read means a config space exists. */
    mov     si, offset tab_pci
    call    dump_port_table
    /* 0xCF8 is a register, not a mirror of the value just written: save what
     * it held and put it back, so the section leaves no write behind. */
    mov     dx, 0x0CF8
    call    read_dword
    mov     [pci_cf8_was], eax
    mov     dx, 0x0CF8
    mov     eax, 0x80000000
    call    write_dword
    mov     dx, 0x0CFC
    call    read_dword
    push    eax
    mov     si, offset msg_pci0
    call    puts
    pop     eax
    call    puthex32
    call    putnl
    mov     dx, 0x0CF8
    xor     eax, eax
    call    write_dword
    mov     dx, 0x0CFC
    call    read_dword
    push    eax
    mov     si, offset msg_pci_r
    call    puts
    pop     eax
    call    puthex32
    call    putnl
    mov     dx, 0x0CF8
    mov     eax, [pci_cf8_was]
    call    write_dword
    mov     si, offset msg_pci_was
    call    puts
    mov     eax, [pci_cf8_was]
    call    puthex32
    call    putnl
    mov     si, offset msg_end_pci
    call    puts
    ret

read_dword:                     /* DX = port -> EAX */
    in      eax, dx
    ret

write_dword:                    /* DX = port, EAX = value */
    out     dx, eax
    ret

/* ------------------------------------------------------------------ */
/* section: GDC status histograms                                     */
/* ------------------------------------------------------------------ */
    .equ HIST_ITERS, 0x200000
sec_gdc:
    mov     si, offset msg_begin_gdc
    call    puts
    mov     byte ptr [hist_sel], 0      /* 0x60 */
    call    hist_run
    mov     byte ptr [hist_sel], 1      /* 0xA0 */
    call    hist_run
    mov     byte ptr [hist_sel], 2      /* 0x43 keyboard status */
    call    hist_run
    mov     byte ptr [hist_sel], 3      /* 0x128 calendar tick */
    call    hist_run
    mov     si, offset msg_end_gdc
    call    puts
    ret

/* hist_run: samples the selected port and prints the set-count of every bit.
 * This converts a single ambiguous sample (probe.s saw 0x60 = 0x44 once) into
 * a per-bit answer, which is what tells a live HBLANK from a strap. */
hist_run:
    push    eax
    push    ebx
    push    ecx
    push    dx
    push    si
    push    di
    mov     al, [hist_sel]
    call    sel_port            /* -> DX */
    push    dx
    /* Clear the eight counters. */
    xor     bx, bx
    mov     cx, 8
    mov     di, offset hist_bits
    xor     ax, ax
    cld
hr_clear:
    mov     [di], eax
    add     di, 4
    loop    hr_clear
    /* Sample. */
    mov     ecx, 0x200000
    pop     dx
hr_loop:
    in      al, dx
    push    ax
    mov     ah, al
    mov     di, offset hist_bits
    mov     bx, 0
1:  test    ah, 1
    jz      2f
    inc     dword ptr [di]
2:  shr     ah, 1
    add     di, 4
    inc     bx
    cmp     bx, 8
    jb      1b
    pop     ax
    dec     ecx
    jnz     hr_loop
    /* Print. */
    mov     si, offset msg_port
    call    puts
    mov     al, [hist_sel]
    call    sel_port
    call    putport
    call    putnl
    mov     di, offset hist_bits
    mov     cx, 0
hr_print:
    mov     si, offset msg_bit
    call    puts
    mov     ax, cx
    call    puthex8
    mov     si, offset msg_count
    call    puts
    mov     eax, [di]
    call    puthex32
    call    putnl
    add     di, 4
    inc     cx
    cmp     cx, 8
    jb      hr_print
    pop     di
    pop     si
    pop     dx
    pop     ecx
    pop     ebx
    pop     eax
    ret

/* sel_port: AL = selector -> DX = port. AL is preserved. */
sel_port:
    push    ax
    and     al, 0x0F
    mov     dx, 0x0060
    test    al, al
    jz      sp_done
    mov     dx, 0x00A0
    cmp     al, 1
    je      sp_done
    mov     dx, 0x0043
    cmp     al, 2
    je      sp_done
    mov     dx, 0x0128
sp_done:
    pop     ax
    ret

/* ------------------------------------------------------------------ */
/* section: calendar                                                  */
/* ------------------------------------------------------------------ */
sec_cal:
    mov     si, offset msg_begin_cal
    call    puts
    /* First touch: the mode latch before anything writes it. probe.s wrote
     * 0x22 = 0xEF before ever reading it, so PROBE.TXT's 0xEF is its own byte;
     * bit 5 of the real value says whether the part is in the uPD4993A
     * extended format. */
    mov     dx, 0x0022
    call    read_byte
    push    ax
    mov     si, offset msg_cal_mode
    call    puts
    pop     ax
    call    puthex8
    call    putnl

    /* Raw 52-bit stream: TIMEREAD, then read 52 bits from bit 0 of 0x33.
     * This is the measurement that settles the bit order, because the seconds
     * byte of a known time is recognisable in one direction only. */
    mov     si, offset msg_cal_stream
    call    puts
    mov     dx, 0x0020
    mov     al, 8               /* command 1000 = TIMEREAD (shift out) */
    call    write_byte
    mov     cx, 52
    xor     bx, bx              /* bit accumulator */
    xor     bp, bp              /* bits collected */
    mov     si, offset cal_bits
    xor     di, di
sc_bit:
    push    cx
    mov     dx, 0x0033
    in      al, dx
    and     al, 1
    pop     cx
    mov     dl, al
    /* Print each bit as a character so the stream is directly readable. */
    push    ax
    mov     al, dl
    add     al, '0'
    mov     dl, al
    call    putc
    pop     ax
    /* Also assemble nibbles, four bits per hex digit, in stream order. */
    shl     bl, 1
    or      bl, al
    inc     bp
    cmp     bp, 4
    jb      sc_next
    push    ax
    mov     al, bl
    call    puthexdig
    pop     ax
    xor     bp, bp
sc_next:
    loop    sc_bit
    call    putnl
    mov     dx, 0x0020
    mov     al, 0               /* register hold: stop shifting */
    call    write_byte
    mov     si, offset msg_end_cal
    call    puts
    ret

/* ------------------------------------------------------------------ */
/* section: ATA - bank and drive selection, IDENTIFY, LBA 0 read       */
/* ------------------------------------------------------------------ */
sec_ata:
    mov     si, offset msg_begin_ata
    call    puts

    /* The block as found, before selecting anything. */
    mov     si, offset msg_ata_before
    call    puts
    mov     si, offset tab_ata
    call    dump_port_table

    /* 0x432 chooses the channel register bank; 0x430 reports the connection.
     * Both references latch writes to 0x430 and compute bit 6 from the selected
     * channel's slave; our RTL drops the write and always clears bit 6. */
    mov     dx, 0x0432
    call    read_byte
    push    ax
    mov     si, offset msg_432_before
    call    puts
    pop     ax
    call    puthex8
    call    putnl
    /* 0x0430 and 0x0432 are reported as found and NEVER written. 0x0430 is the
     * IDE connection register, which the round-1 probe only ever read, and a
     * write to 0x0432 re-points the bank a loaded driver is using; a write test
     * here is what crashed this machine once, and the decode question is
     * answered by the read values on their own. */
    mov     dx, 0x0430
    call    read_byte
    push    ax
    mov     si, offset msg_430_first
    call    puts
    pop     ax
    call    puthex8
    call    putnl

    /* Sweep the two channel banks. The real IDE option ROM (bank 3 of the
     * firmware set) issues nine writes to 0x0432, so switching banks is normal
     * use rather than a hazard; what is a hazard is letting a timer or keyboard
     * interrupt interleave the DOS driver's task-file access with ours, so the
     * switch and the reads happen with interrupts disabled and the results are
     * buffered for printing afterwards. The original bank is restored before
     * this function returns, so DOS sees what it left. */
    mov     dx, 0x0432
    call    read_byte
    mov     [ata_bank_save], al
    mov     byte ptr [ata_bank_arg], 0
    call    ata_block_probe
    mov     byte ptr [ata_bank_arg], 1
    call    ata_block_probe
    mov     dx, 0x0432
    mov     al, [ata_bank_save]
    call    write_byte

    /* Select the master in CHS mode and dump the block: a live task file
     * shows distinct registers, a floating one repeats a single byte. */
    /* The bank sweep proved the task file only answers with 0x0432 = 1 (the
     * machine's built-in IDE), and that DOS leaves the register at 0. Select the
     * live bank before anything that issues a command, or IDENTIFY drains
     * floating 0x0EFF from an interface that is not there. */
    cli
    mov     dx, 0x0432
    mov     al, 1
    call    write_byte
    mov     dx, 0x064C
    mov     al, 0xA0
    call    write_byte
    call    ata_delay
    sti
    mov     si, offset msg_ata_sel
    call    puts
    mov     si, offset tab_ata
    call    dump_port_table

    /* IDENTIFY: drain all 256 words. Printing everything removes the need to
     * guess which words matter, and it is the reference our identify_word
     * function should be diffed against. */
    mov     si, offset msg_identify
    call    puts
    call    ata_identify
    jc      sa_id_fail
    mov     si, offset id_buf
    mov     cx, 512
    call    dump_words
    jmp     sa_id_done
sa_id_fail:
    mov     si, offset msg_id_fail
    call    puts
sa_id_done:
    mov     si, offset msg_ata_after
    call    puts
    mov     si, offset tab_ata
    call    dump_port_table

    /* LBA 0, CHS addressing (drive/head bit 6 clear). */
    mov     si, offset msg_read_chs
    call    puts
    cli
    mov     dx, 0x0644
    mov     al, 1
    call    write_byte
    mov     dx, 0x0646
    mov     al, 1               /* sector 1 */
    call    write_byte
    mov     dx, 0x0648
    mov     al, 0
    call    write_byte
    mov     dx, 0x064A
    mov     al, 0
    call    write_byte
    mov     dx, 0x064C
    mov     al, 0xA0
    call    write_byte
    call    ata_read_lba0
    sti
    jc      sa_r_chs_fail
    mov     si, offset rd_buf
    mov     cx, 128             /* enough to compare against the image's IPL */
    call    dump_mem
    jmp     sa_r_chs_done
sa_r_chs_fail:
    mov     si, offset msg_read_fail
    call    puts
sa_r_chs_done:

    /* The same sector with LBA28 (drive/head bit 6 set). */
    mov     si, offset msg_read_lba
    call    puts
    cli
    mov     dx, 0x0644
    mov     al, 1
    call    write_byte
    mov     dx, 0x0646
    mov     al, 0
    call    write_byte
    mov     dx, 0x0648
    mov     al, 0
    call    write_byte
    mov     dx, 0x064A
    mov     al, 0
    call    write_byte
    mov     dx, 0x064C
    mov     al, 0xE0
    call    write_byte
    call    ata_read_lba0
    sti
    jc      sa_r_lba_fail
    mov     si, offset rd_buf
    mov     cx, 128
    call    dump_mem
    jmp     sa_r_lba_done
sa_r_lba_fail:
    mov     si, offset msg_read_fail
    call    puts
sa_r_lba_done:
    mov     si, offset msg_end_ata
    call    puts
    ret

/* ata_block_probe: [ata_bank_arg] selects the bank. Writes 0x0432 under cli,
 * reads the ten command-block registers into ata_blk, re-enables interrupts,
 * then prints them one per line as port=value. Reads only apart from the bank
 * write, which the restore list puts back as well. */
ata_block_probe:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    es
    push    ds
    pop     es                  /* ES = DS for the buffer */
    cli
    mov     dx, 0x0432
    mov     al, [ata_bank_arg]
    call    write_byte
    mov     si, offset tab_ata
    mov     di, offset ata_blk
    mov     cx, 10
abp_read:
    mov     dx, [si]
    call    read_byte
    stosb
    add     si, 2
    loop    abp_read
    sti
    mov     si, offset msg_ata_banked
    call    puts
    mov     al, [ata_bank_arg]
    call    puthex8
    call    putnl
    mov     si, offset tab_ata
    mov     bx, offset ata_blk
    mov     cx, 10
abp_print:
    mov     dx, [si]
    mov     al, [bx]
    call    putport
    call    putsp
    add     si, 2
    inc     bx
    loop    abp_print
    call    putnl
    pop     es
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* ata_delay: short settle after a register write (a few I/O reads). */
ata_delay:
    push    ax
    push    cx
    push    dx
    mov     cx, 20
    mov     dx, 0x0060
1:  in      al, dx
    loop    1b
    pop     dx
    pop     cx
    pop     ax
    ret

/* ata_wait_drq: waits for DRQ or ERR with a bounded poll. CF set on error or
 * timeout. */
ata_wait_drq:
    push    ax
    push    cx
    push    dx
    mov     cx, 0xFFFF
1:  mov     dx, 0x064E
    in      al, dx
    test    al, 0x08            /* DRQ */
    jnz     aw_ok
    test    al, 0x01            /* ERR */
    jnz     aw_err
    loop    1b
aw_err:
    pop     dx
    pop     cx
    pop     ax
    stc
    ret
aw_ok:
    pop     dx
    pop     cx
    pop     ax
    clc
    ret

/* ata_identify: issue 0xEC and store 512 bytes at id_buf. CF on failure. */
ata_identify:
    push    ax
    push    cx
    push    dx
    push    di
    push    es
    push    ds
    pop     es                  /* ES = DS for the buffer */
    /* Command sequences are interrupt-guarded. INT 21h may not be called with
     * interrupts disabled, so these windows contain port I/O only and the
     * results are printed after the sti. Without this a DOS timer or keyboard
     * interrupt can drive the task file with its own driver mid-command, which
     * hangs the drive and the machine with it. */
    cli
    mov     dx, 0x064E
    mov     al, 0xEC
    call    write_byte
    call    ata_wait_drq
    jc      ai_out
    mov     dx, 0x0640
    mov     di, offset id_buf
    mov     cx, 256
    cld
ai_loop:
    in      ax, dx
    stosw
    loop    ai_loop
    clc
ai_out:
    sti                       /* both exits pass through here */
    pop     es
    pop     di
    pop     dx
    pop     cx
    pop     ax
    ret

/* ata_read_lba0: issue 0x20 for the task file as set up by the caller and
 * store 512 bytes at rd_buf. CF on failure. */
ata_read_lba0:
    push    ax
    push    cx
    push    dx
    push    di
    push    es
    push    ds
    pop     es
    cli
    mov     dx, 0x064E
    mov     al, 0x20
    call    write_byte
    call    ata_wait_drq
    jc      ar_out
    mov     dx, 0x0640
    mov     di, offset rd_buf
    mov     cx, 256
    cld
ar_loop:
    in      ax, dx
    stosw
    loop    ar_loop
    clc
ar_out:
    sti
    pop     es
    pop     di
    pop     dx
    pop     cx
    pop     ax
    ret

/* dump_words: DS:SI = 512 bytes, prints 16-bit words, 8 per line, so IDENTIFY
 * output lines up with the word numbering used by every reference. */
dump_words:
    push    ax
    push    bx
    push    cx
    push    si
    mov     bx, 0
dw_loop:
    test    cx, cx
    jz      dw_done
    mov     ax, [si]
    xchg    al, ah              /* little endian word: print high byte first */
    call    puthex16
    call    putsp
    add     si, 2
    sub     cx, 2
    inc     bx
    cmp     bx, 8
    jb      dw_loop
    call    putnl
    xor     bx, bx
    jmp     dw_loop
dw_done:
    call    putnl
    pop     si
    pop     cx
    pop     bx
    pop     ax
    ret

/* ------------------------------------------------------------------ */
/* section: GVRAM read-after-write                                    */
/* ------------------------------------------------------------------ */
sec_vram:
    mov     si, offset msg_begin_vram
    call    puts
    mov     si, offset tab_vram
sv_next:
    mov     ax, [si]
    cmp     ax, 0xFFFF
    je      sv_done
    add     si, 2
    mov     [vram_seg], ax
    call    vram_probe
    jmp     sv_next
sv_done:
    mov     si, offset msg_end_vram
    call    puts
    ret

/* vram_probe: writes 0x00,0xFF,0x55,0xAA into the first four bytes of the
 * window at [vram_seg]:0000, reads each back, restores the original bytes, and
 * prints the four results. A window that is plain RAM echoes all four; a
 * read-only or gated window does not. */
vram_probe:
    push    ax
    push    cx
    push    si
    push    di
    push    es
    push    ds
    mov     ax, [vram_seg]
    mov     es, ax
    xor     di, di
    /* save */
    mov     si, offset vram_save
    mov     cx, 8
    cld
vp_save:
    mov     al, es:[di]
    mov     [si], al
    inc     si
    inc     di
    loop    vp_save
    /* write the pattern */
    xor     di, di
    mov     si, offset vram_pat
    mov     cx, 8
vp_write:
    mov     al, [si]
    mov     es:[di], al
    inc     si
    inc     di
    loop    vp_write
    /* read back */
    xor     di, di
    mov     si, offset vram_got
    mov     cx, 8
vp_read:
    mov     al, es:[di]
    mov     [si], al
    inc     si
    inc     di
    loop    vp_read
    /* restore */
    xor     di, di
    mov     si, offset vram_save
    mov     cx, 8
vp_restore:
    mov     al, [si]
    mov     es:[di], al
    inc     si
    inc     di
    loop    vp_restore
    pop     ds
    pop     es
    /* print "SEG: wrote=.. got=.." */
    push    es
    mov     si, offset msg_vram_row
    call    puts
    mov     ax, [vram_seg]
    call    puthex16
    mov     si, offset msg_wrote
    call    puts
    mov     si, offset vram_pat
    mov     cx, 4
    call    dump_mem
    mov     si, offset msg_got
    call    puts
    mov     si, offset vram_got
    mov     cx, 4
    call    dump_mem
    pop     es
    pop     di
    pop     si
    pop     cx
    pop     ax
    ret

/* ------------------------------------------------------------------ */
/* round-10 helpers: latches that a section sweeps many times, and a    */
/* read-only page finder                                                */
/* ------------------------------------------------------------------ */
/* latch_set: DX = port, AL = value. A raw latch write for sections that
 * change a register many times; the section restores the register itself
 * and adds a single entry to the restore report with note_restore. */
latch_set:
    out     dx, al
    ret

/* io_delay: reads of the I/O-wait port so a chipset latch settles before the
 * next memory access. Reading an undecoded port is harmless, and the games
 * write the wait port for exactly this purpose. */
io_delay:
    push    ax
    push    cx
    push    dx
    mov     dx, 0x005F
    mov     cx, 8
1:  in      al, dx
    loop    1b
    pop     dx
    pop     cx
    pop     ax
    ret

/* note_restore: DX = port, AL = the value the section has already put back.
 * Records (port, value) for the restore report without writing the port now. */
note_restore:
    push    ax
    push    bx
    /* BH is the byte the section put back; report_restores re-reads the port
     * after writing BH and prints it as `now`. The value is in AL, and
     * `mov bx,ax` looked right and is wrong: it puts AH in BH, and AH is
     * whatever the last 16-bit load left there - on /SHADOW that was 0x5A from
     * the 0x5AA5 work marker two calls earlier, so every latch /SHADOW touched
     * was recorded AND REPLAYED as 0x5A instead of its first-touch byte
     * (SHADOWW.TXT `1E8E=5A -> 7E` where the first-touch line says 1E8E=FE).
     * The replayed 0x5A also wrote bit 4 = 0 to 0x053D, the exact option-ROM
     * gate write that hangs a machine with the IDE driver loaded. */
    mov     bh, al
    call    record_restore
    pop     bx
    pop     ax
    ret

/* scan_marker: AX = a marker word. Searches the 16 physical pages 0x00000..
 * 0xF0000, each read at its base through a flat segment, for that word.
 * Returns BX = the page number 0..15, or 0xFFFF when no page holds it. The
 * caller keeps both window registers at their identity values so the pages
 * the windows own read the memory the window would show. Read-only. */
scan_marker:
    push    ax
    push    cx
    push    si
    push    di
    push    es
    mov     di, ax
    mov     bx, 0xFFFF
    mov     si, offset win_pages
sm_loop:
    mov     al, [si]
    cmp     al, 0xFF
    je      sm_done
    inc     si
    push    si
    xor     ah, ah
    mov     cl, 12
    shl     ax, cl
    mov     es, ax
    mov     ax, es:[0]
    cmp     ax, di
    jne     sm_next
    mov     bx, es
    mov     cl, 12
    shr     bx, cl
sm_next:
    pop     si
    jmp     sm_loop
sm_done:
    pop     es
    pop     di
    pop     si
    pop     cx
    pop     ax
    ret

/* sw_marker_ok: AL = candidate window-register value. CF clear only when a
 * marker for it can be written safely. Pages 0 and 1 hold the IVT and the BIOS
 * data area, and the probe's own pages are [sw_own_lo, sw_own_hi]; the marker
 * at the window base lands in page `cand` and the base+0x10000 one in `cand+1`. */
sw_marker_ok:
    cmp     al, 2
    jb      smo_no
    mov     ah, al
    inc     ah                  /* cand+1: the second marker's page */
    mov     dl, [sw_own_lo]
    cmp     ah, dl
    jb      smo_yes             /* both markers are below the probe */
    mov     dl, [sw_own_hi]
    cmp     al, dl
    ja      smo_yes             /* both markers are above the probe */
    jmp     smo_no
smo_yes:
    clc
    ret
smo_no:
    stc
    ret

/* sweep_window: measures one window register by observable mapping.
 * Inputs (variables): sw_port = the 8-bit register, sw_base = the segment of
 * the window base (0x8000 or 0xA000), sw_ident = the register's identity
 * value, sw_cands = a candidate table, sw_n = the entry count, sw_res = the
 * result block (8 bytes per entry: candidate, register read-back, landing
 * page of the base marker, landing page of the base+0x10000 marker, the word
 * read at the base before the write and after it).
 * For each candidate it selects the register, reads the two window banks,
 * writes two distinct markers (base and base+0x10000), reads them back, sets
 * the identity value and finds which physical page each marker landed in,
 * then writes the two original words back and re-selects the identity.
 * Interrupts must already be off (the caller owns that). */
sweep_window:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    bp
    push    es
    /* The probe is one 64 KiB .COM segment: its code, data and (for a .COM)
     * stack all live in pages page(CS) and page(CS)+1, so those pages must never
     * receive a marker. own_hi catches a non-page-aligned load segment, whose
     * top crosses into the next page. */
    mov     ax, cs
    mov     bx, ax
    mov     cl, 12
    shr     ax, cl
    mov     [sw_own_lo], al
    and     bx, 0x0FFF
    jz      1f
    inc     ax
1:  mov     [sw_own_hi], al
    mov     bp, [sw_res]
    mov     si, [sw_cands]
    mov     cx, [sw_n]
sw_loop:
    test    cx, cx
    jz      sw_done
    push    cx
    push    si
    mov     al, [si]
    mov     [bp+0], al
    mov     dx, [sw_port]
    call    latch_set
    call    io_delay
    call    read_byte
    mov     [bp+1], al
    /* before: the two window banks */
    mov     ax, [sw_base]
    mov     es, ax
    mov     ax, es:[0]
    mov     [bp+4], ax
    push    ax                  /* b0, for the put-back */
    mov     ax, [sw_base]
    add     ax, 0x1000
    mov     es, ax
    mov     ax, es:[0]
    push    ax                  /* b1, for the put-back */
    /* Markers, unless this candidate would alias the IVT/BIOS data area (pages
     * 0 and 1) or the probe's own pages. A marker that lands on the code or
     * stack still executing could be fetched before the put-back below restores
     * it, so those candidates are measured read-only and report p=q=FD. */
    mov     al, [bp+0]
    call    sw_marker_ok
    jc      sw_no_marker
    mov     word ptr es:[0], 0x3CC3
    mov     ax, [sw_base]
    mov     es, ax
    mov     word ptr es:[0], 0x5AA5
    mov     ax, es:[0]
    mov     [bp+6], ax
    /* identity, then find the pages the markers landed in */
    mov     dx, [sw_port]
    mov     al, [sw_ident]
    call    latch_set
    call    io_delay
    mov     ax, 0x5AA5
    call    scan_marker
    mov     [bp+2], bl
    mov     ax, 0x3CC3
    call    scan_marker
    mov     [bp+3], bl
    jmp     sw_after_marker
sw_no_marker:
    mov     ax, [bp+4]          /* nothing was written, so a = b */
    mov     [bp+6], ax
    mov     byte ptr [bp+2], 0xFD
    mov     byte ptr [bp+3], 0xFD
sw_after_marker:
    /* put the two words back under the candidate, then identity again */
    mov     dx, [sw_port]
    mov     al, [bp+0]
    call    latch_set
    call    io_delay
    mov     ax, [sw_base]
    add     ax, 0x1000
    mov     es, ax
    pop     ax
    mov     es:[0], ax
    mov     ax, [sw_base]
    mov     es, ax
    pop     ax
    mov     es:[0], ax
    mov     dx, [sw_port]
    mov     al, [sw_ident]
    call    latch_set
    call    io_delay
    pop     si
    add     bp, 8
    inc     si
    pop     cx
    dec     cx
    jmp     sw_loop
sw_done:
    pop     es
    pop     bp
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* print_win_res: DS:SI = result block, CX = entries, [sw_port] = the label.
 * One line per candidate: `PPPP=VV rb=RR b=WWWW a=WWWW p=PP q=QQ`, where rb
 * is the register read-back, b/a the word at the window base before/after the
 * marker write, and p/q the physical page the base / base+0x10000 marker was
 * found in (0xFF = none, i.e. the write was discarded or landed above 1 MiB). */
print_win_res:
    push    ax
    push    bx
    push    cx
    push    dx
    push    di
    mov     di, si
pwr_loop:
    test    cx, cx
    jz      pwr_done
    push    cx
    mov     dx, [sw_port]
    mov     ax, dx
    xchg    al, ah
    call    puthex8
    mov     al, ah
    call    puthex8
    mov     dl, '='
    call    putc
    mov     al, [di+0]
    call    puthex8
    mov     si, offset msg_win_rb
    call    puts
    mov     al, [di+1]
    call    puthex8
    mov     si, offset msg_win_b
    call    puts
    mov     ax, [di+4]
    call    puthex16
    mov     si, offset msg_win_a
    call    puts
    mov     ax, [di+6]
    call    puthex16
    mov     si, offset msg_win_p
    call    puts
    mov     al, [di+2]
    call    puthex8
    mov     si, offset msg_win_q
    call    puts
    mov     al, [di+3]
    call    puthex8
    call    putnl
    add     di, 8
    pop     cx
    dec     cx
    jmp     pwr_loop
pwr_done:
    pop     di
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* ------------------------------------------------------------------ */
/* section: /WIN - 0x461 and 0x463 window geometry (restores)          */
/* ------------------------------------------------------------------ */
sec_win:
    mov     si, offset msg_begin_win
    call    puts
    /* First touch, before anything in this probe writes these ports. */
    mov     dx, 0x0461
    call    read_byte
    mov     [win_was461], al
    mov     dx, 0x0463
    call    read_byte
    mov     [win_was463], al
    mov     dx, 0x043F
    call    read_byte
    mov     [win_was43f], al
    mov     dx, 0x043B
    call    read_byte
    mov     [win_was43b], al
    mov     dx, 0x063C
    call    read_byte
    mov     [win_was63c], al
    mov     dx, 0x063D
    call    read_byte
    mov     [win_was63d], al
    mov     dx, 0x063E
    call    read_byte
    mov     [win_was63e], al
    mov     si, offset msg_win_was
    call    puts
    mov     al, [win_was461]
    call    puthex8
    call    putsp
    mov     al, [win_was463]
    call    puthex8
    call    putsp
    mov     al, [win_was43f]
    call    puthex8
    call    putsp
    mov     al, [win_was43b]
    call    puthex8
    call    putsp
    mov     al, [win_was63c]
    call    puthex8
    call    putsp
    mov     al, [win_was63d]
    call    puthex8
    call    putsp
    mov     al, [win_was63e]
    call    puthex8
    call    putnl

    /* Read-only inspection: the window words under whatever 0x461/0x463 are
     * already selecting. These reads alias DOS memory or VRAM; reading them
     * cannot move the window. */
    mov     ax, 0x8000
    mov     es, ax
    mov     ax, es:[0]
    mov     [win_ro80], ax
    mov     ax, 0x9000
    mov     es, ax
    mov     ax, es:[0]
    mov     [win_ro90], ax
    mov     ax, 0xA000
    mov     es, ax
    mov     ax, es:[0]
    mov     [win_roA0], ax
    mov     ax, 0xB000
    mov     es, ax
    mov     ax, es:[0]
    mov     [win_roB0], ax
    mov     dx, 0x0461
    call    read_byte
    mov     [win_rb461], al
    mov     dx, 0x0463
    call    read_byte
    mov     [win_rb463], al
    mov     si, offset msg_win_ro
    call    puts
    mov     ax, [win_ro80]
    call    puthex16
    call    putsp
    mov     ax, [win_ro90]
    call    puthex16
    call    putsp
    mov     ax, [win_roA0]
    call    puthex16
    call    putsp
    mov     ax, [win_roB0]
    call    puthex16
    mov     si, offset msg_win_rrb
    call    puts
    mov     al, [win_rb461]
    call    puthex8
    call    putsp
    mov     al, [win_rb463]
    call    puthex8
    call    putnl

    /* The sweep moves 0x461/0x463 and writes markers into whatever physical
     * page the window then aliases (page 0 and DOS's own RAM included), so it
     * is opt-in: /WIN alone only reads. */
    mov     al, [flags2]
    test    al, FLAG2_WRITE
    jnz     win_sweep
    mov     si, offset msg_win_inert
    call    puts
    jmp     win_done
win_sweep:
    mov     si, offset msg_win_write
    call    puts
    /* From here to the sti nothing calls DOS. 0x461 moves the memory DOS keeps
     * its buffers in, so output only happens after the restore. */
    cli
    /* U1/U2: does 0x461 store bit 0? */
    mov     dx, 0x0461
    mov     al, [win_was461]
    or      al, 0x01
    call    latch_set
    call    io_delay
    mov     dx, 0x0461
    call    read_byte
    mov     [win_bit0], al

    /* window 0: decode through 0x461 = 0x08 (identity); 0x463 stays first-touch */
    mov     dx, 0x0461
    mov     al, 0x08
    call    latch_set
    call    io_delay
    mov     word ptr [sw_port], 0x0461
    mov     word ptr [sw_base], 0x8000
    mov     byte ptr [sw_ident], 0x08
    mov     word ptr [sw_cands], offset win_cand0
    mov     word ptr [sw_res], offset win_res0
    mov     word ptr [sw_n], 10
    call    sweep_window

    /* window 1: 0x461 pinned to 0x08 so the pages 8/9 scan as RAM */
    mov     word ptr [sw_port], 0x0463
    mov     word ptr [sw_base], 0xA000
    mov     byte ptr [sw_ident], 0x0A
    mov     word ptr [sw_cands], offset win_cand1
    mov     word ptr [sw_res], offset win_res1
    mov     word ptr [sw_n], 8
    call    sweep_window

    /* restore 0x463 then 0x461, then record what 0x80000/0x90000 read as with
     * the first-touch values back: that answers whether 0x80000 still aliases
     * guest RAM. */
    mov     dx, 0x0463
    mov     al, [win_was463]
    call    latch_set
    call    io_delay
    mov     dx, 0x0461
    mov     al, [win_was461]
    call    latch_set
    call    io_delay
    mov     ax, 0x8000
    mov     es, ax
    mov     ax, es:[0]
    mov     [win_after80], ax
    mov     ax, 0x9000
    mov     es, ax
    mov     ax, es:[0]
    mov     [win_after90], ax
    sti

    mov     word ptr [sw_port], 0x0461
    mov     si, offset win_res0
    mov     cx, 10
    call    print_win_res
    mov     word ptr [sw_port], 0x0463
    mov     si, offset win_res1
    mov     cx, 8
    call    print_win_res

    mov     si, offset msg_win_bit0
    call    puts
    mov     al, [win_bit0]
    call    puthex8
    call    putnl
    mov     si, offset msg_win_after
    call    puts
    mov     ax, [win_after80]
    call    puthex16
    call    putsp
    mov     ax, [win_after90]
    call    puthex16
    call    putnl
    mov     dx, 0x0461
    mov     al, [win_was461]
    call    note_restore
    mov     dx, 0x0463
    mov     al, [win_was463]
    call    note_restore
win_done:
    mov     si, offset msg_end_win
    call    puts
    ret

/* ------------------------------------------------------------------ */
/* section: /EMS - the 0x43F 0x2x B0000 window (restores)              */
/* ------------------------------------------------------------------ */
sec_ems:
    mov     si, offset msg_begin_ems
    call    puts
    mov     dx, 0x043F
    call    read_byte
    mov     [ems_was], al
    cli
    /* Save the 16 bytes at B000:0 and the eight words the extent test uses. */
    mov     ax, 0xB000
    mov     es, ax
    mov     si, 0
    mov     di, offset ems_save
    mov     cx, 16
    cld
em_save:
    mov     al, es:[si]
    mov     [di], al
    inc     si
    inc     di
    loop    em_save
    /* The eight words the extent test writes, at 0, 0x2000 .. 0xE000. */
    mov     bx, 0
    mov     di, offset ems_ext_save
    mov     cx, 8
em_save_ext:
    mov     ax, es:[bx]
    mov     [di], ax
    add     di, 2
    add     bx, 0x2000
    loop    em_save_ext

    /* The ITF's own test: write 0xAA55 under 0x22, ask for 0x20, re-read. */
    mov     dx, 0x043F
    mov     al, 0x22
    call    latch_set
    call    io_delay
    mov     word ptr es:[0], 0xAA55
    mov     dx, 0x043F
    mov     al, 0x20
    call    latch_set
    call    io_delay
    mov     ax, es:[0]
    mov     [ems_itf], ax
    mov     dx, 0x043F
    call    read_byte
    mov     [ems_rb20], al

    /* Page 0, page 1 (0x22) and page 2 (0x24 if bits 3:1 are the page): one
     * distinct marker each, then read page 0 back first. */
    mov     dx, 0x043F
    mov     al, 0x20
    call    latch_set
    call    io_delay
    mov     word ptr es:[0], 0x1111
    mov     dx, 0x043F
    mov     al, 0x22
    call    latch_set
    call    io_delay
    mov     word ptr es:[0], 0x2222
    mov     dx, 0x043F
    mov     al, 0x24
    call    latch_set
    call    io_delay
    mov     word ptr es:[0], 0x4444
    mov     dx, 0x043F
    mov     al, 0x20
    call    latch_set
    call    io_delay
    mov     ax, es:[0]
    mov     [ems_p20], ax
    mov     dx, 0x043F
    call    read_byte
    mov     [ems_rb20b], al
    mov     dx, 0x043F
    mov     al, 0x22
    call    latch_set
    call    io_delay
    mov     ax, es:[0]
    mov     [ems_p22], ax
    mov     dx, 0x043F
    mov     al, 0x24
    call    latch_set
    call    io_delay
    mov     ax, es:[0]
    mov     [ems_p24], ax

    /* Is bit 0 a page bit? Write under 0x21, read under 0x20. */
    mov     dx, 0x043F
    mov     al, 0x21
    call    latch_set
    call    io_delay
    mov     word ptr es:[0], 0x2121
    mov     dx, 0x043F
    mov     al, 0x20
    call    latch_set
    call    io_delay
    mov     ax, es:[0]
    mov     [ems_p20c], ax

    /* Extent: mark every 8 KiB of the window under 0x22, read under 0x20/0x22. */
    mov     dx, 0x043F
    mov     al, 0x22
    call    latch_set
    call    io_delay
    mov     bx, 0
    mov     cx, 8
    mov     si, 0
em_mark:
    mov     ax, 0x7700
    add     ax, si
    mov     word ptr es:[bx], ax
    add     bx, 0x2000
    inc     si
    loop    em_mark
    mov     dx, 0x043F
    mov     al, 0x20
    call    latch_set
    call    io_delay
    mov     bx, 0
    mov     di, offset ems_ext20
    mov     cx, 8
em_ext20:
    mov     ax, es:[bx]
    mov     [di], ax
    add     di, 2
    add     bx, 0x2000
    loop    em_ext20
    mov     dx, 0x043F
    mov     al, 0x22
    call    latch_set
    call    io_delay
    mov     bx, 0
    mov     di, offset ems_ext22
    mov     cx, 8
em_ext22:
    mov     ax, es:[bx]
    mov     [di], ax
    add     di, 2
    add     bx, 0x2000
    loop    em_ext22

    /* 0x80/0x82: report the read-back and the F8000 word; do NOT write the
     * ROM storage (a shadow test would write live BIOS bytes). */
    mov     dx, 0x043F
    mov     al, 0x80
    call    latch_set
    call    io_delay
    mov     dx, 0x043F
    call    read_byte
    mov     [ems_rb80], al
    mov     ax, 0xF800
    mov     es, ax
    mov     ax, es:[0]
    mov     [ems_f8_80], ax
    mov     dx, 0x043F
    mov     al, 0x82
    call    latch_set
    call    io_delay
    mov     dx, 0x043F
    call    read_byte
    mov     [ems_rb82], al
    mov     ax, 0xF800
    mov     es, ax
    mov     ax, es:[0]
    mov     [ems_f8_82], ax

    /* Restore 0x43F, then the storage it was pointing at. */
    mov     dx, 0x043F
    mov     al, [ems_was]
    call    latch_set
    call    io_delay
    mov     dx, 0x043F
    call    read_byte
    mov     [ems_rb_was], al
    mov     ax, 0xB000
    mov     es, ax
    mov     si, 0
    mov     di, offset ems_save
    mov     cx, 16
em_restore:
    mov     al, [di]
    mov     es:[si], al
    inc     si
    inc     di
    loop    em_restore
    mov     ax, 0xB000
    mov     es, ax
    mov     si, offset ems_ext_save
    mov     bx, 0
    mov     cx, 8
em_ext_restore:
    mov     ax, [si]
    mov     es:[bx], ax
    add     si, 2
    add     bx, 0x2000
    loop    em_ext_restore
    sti

    mov     si, offset msg_ems_was
    call    puts
    mov     al, [ems_was]
    call    puthex8
    call    putnl
    mov     si, offset msg_ems_itf
    call    puts
    mov     ax, [ems_itf]
    call    puthex16
    call    putnl
    mov     si, offset msg_ems_rb20
    call    puts
    mov     al, [ems_rb20]
    call    puthex8
    call    putsp
    mov     al, [ems_rb20b]
    call    puthex8
    call    putsp
    mov     al, [ems_rb80]
    call    puthex8
    call    putsp
    mov     al, [ems_rb82]
    call    puthex8
    call    putsp
    mov     al, [ems_rb_was]
    call    puthex8
    call    putnl
    mov     si, offset msg_ems_pages
    call    puts
    mov     ax, [ems_p20]
    call    puthex16
    call    putsp
    mov     ax, [ems_p22]
    call    puthex16
    call    putsp
    mov     ax, [ems_p24]
    call    puthex16
    call    putnl
    mov     si, offset msg_ems_p21
    call    puts
    mov     ax, [ems_p20c]
    call    puthex16
    call    putnl
    mov     si, offset msg_ems_f8
    call    puts
    mov     ax, [ems_f8_80]
    call    puthex16
    call    putsp
    mov     ax, [ems_f8_82]
    call    puthex16
    call    putnl
    mov     si, offset msg_ems_ext20
    call    puts
    mov     si, offset ems_ext20
    mov     cx, 16
    call    dump_words
    mov     si, offset msg_ems_ext22
    call    puts
    mov     si, offset ems_ext22
    mov     cx, 16
    call    dump_words
    mov     si, offset msg_end_ems
    call    puts
    mov     dx, 0x043F
    mov     al, [ems_was]
    call    note_restore
    ret

/* ------------------------------------------------------------------ */
/* section: /D8 - the 0xD8000 option-ROM window (restores)             */
/* ------------------------------------------------------------------ */
/* d8_capture: ES = 0xD800 already, DI = destination. Stores the word at
 * offset 9 (the 0xAA55 signature of BANK3) then the first 32 bytes. */
d8_capture:
    mov     bx, 0x0009
    mov     ax, es:[bx]
    mov     [di], ax
    add     di, 2
    mov     bx, 0
    mov     dx, 32
1:  mov     al, es:[bx]
    mov     [di], al
    inc     bx
    inc     di
    dec     dx
    jnz     1b
    ret

sec_d8:
    mov     si, offset msg_begin_d8
    call    puts
    mov     dx, 0x053D
    call    read_byte
    mov     [d8_was], al
    /* First touch, no write: this is the state the BIOS is in when it calls
     * D800:000C, so it already answers the D800 question when the ROM is visible. */
    mov     ax, 0xD800
    mov     es, ax
    mov     di, offset d8_first
    call    d8_capture

    /* The three 0x53D states are opt-in and are a known way to hang the machine.
     * 0x53D bit 4 gates the D8000 window that the option ROM's own INT 1Bh
     * handler (D800:0018) runs from; the IDE driver is resident while DOS is
     * loaded, so writing 0x00/0x02 un-maps the driver out from under the next
     * interrupt into it. Confirmed on hardware 2026-09-13: PROBE2 /D8 (which
     * wrote these three states) locked the machine up reproducibly, while the
     * read-only form is safe. bit 1 is the writable-BIOS-copy gate. */
    mov     al, [flags2]
    test    al, FLAG2_WRITE
    jnz     sd_sweep
    mov     si, offset msg_d8_inert
    call    puts
    jmp     sd_print
sd_sweep:
    mov     si, offset msg_d8_write
    call    puts
    cli
    mov     si, offset d8_state_tab
    mov     bp, offset d8_blk
    mov     cx, 3
sd_loop:
    push    cx
    mov     al, [si]
    mov     [bp+0], al
    mov     dx, 0x053D
    call    latch_set
    call    io_delay
    mov     dx, 0x053D
    call    read_byte
    mov     [bp+1], al
    mov     ax, 0xD800
    mov     es, ax
    mov     di, bp
    add     di, 2
    call    d8_capture
    pop     cx
    add     bp, 36
    inc     si
    dec     cx
    jnz     sd_loop
    mov     dx, 0x053D
    mov     al, [d8_was]
    call    latch_set
    call    io_delay
    sti
    mov     dx, 0x053D
    mov     al, [d8_was]
    call    note_restore

sd_print:
    mov     si, offset msg_d8_was
    call    puts
    mov     al, [d8_was]
    call    puthex8
    call    putnl
    mov     si, offset msg_d8_first
    call    puts
    mov     ax, [d8_first]
    call    puthex16
    call    putnl
    mov     si, offset d8_first
    add     si, 2
    mov     cx, 32
    call    dump_mem

    mov     al, [flags2]
    test    al, FLAG2_WRITE
    jz      sd_done
    mov     bp, offset d8_blk
    mov     cx, 3
sd_print_state:
    push    cx
    mov     si, offset msg_d8_state
    call    puts
    mov     al, [bp+0]
    call    puthex8
    mov     si, offset msg_d8_rb
    call    puts
    mov     al, [bp+1]
    call    puthex8
    mov     si, offset msg_d8_sig
    call    puts
    mov     ax, [bp+2]
    call    puthex16
    call    putnl
    mov     si, bp
    add     si, 4
    mov     cx, 32
    call    dump_mem
    pop     cx
    add     bp, 36
    dec     cx
    jnz     sd_print_state
sd_done:
    mov     si, offset msg_end_d8
    call    puts
    ret

/* ------------------------------------------------------------------ */
/* section: /JOY - the sound-board joystick register-select (restores) */
/* ------------------------------------------------------------------ */
sec_joy:
    mov     si, offset msg_begin_joy
    call    puts
    /* Bare reads first: what the DOS prompt leaves on the two ports. */
    mov     dx, 0x018A
    call    read_byte
    mov     [joy_a0], al
    mov     dx, 0x0188
    call    read_byte
    mov     [joy_188a], al
    /* The games' own sequence: SOUND_O(0x0F) then register 0x0E. */
    cli
    mov     dx, 0x0188
    mov     al, 0x0F
    call    latch_set
    call    io_delay
    mov     dx, 0x0188
    mov     al, 0x0E
    call    latch_set
    call    io_delay
    mov     dx, 0x018A
    call    read_byte
    mov     [joy_a1], al
    mov     dx, 0x018A
    call    read_byte
    mov     [joy_a2], al
    mov     dx, 0x0188
    call    read_byte
    mov     [joy_188b], al
    mov     dx, 0x0188
    mov     al, [joy_188a]
    call    latch_set
    call    io_delay
    sti
    mov     si, offset msg_joy_bare
    call    puts
    mov     al, [joy_a0]
    call    puthex8
    call    putsp
    mov     al, [joy_188a]
    call    puthex8
    call    putnl
    mov     si, offset msg_joy_seq
    call    puts
    mov     al, [joy_a1]
    call    puthex8
    call    putsp
    mov     al, [joy_a2]
    call    puthex8
    call    putsp
    mov     al, [joy_188b]
    call    puthex8
    call    putnl
    mov     si, offset msg_end_joy
    call    puts
    mov     dx, 0x0188
    mov     al, [joy_188a]
    call    note_restore
    ret

/* ------------------------------------------------------------------ */
/* section: /INT1B - the INT 1Bh services the boot chain uses          */
/* ------------------------------------------------------------------ */
/* The work area the disk BIOS keeps its state in. A INT 1Bh call can
 * republish 0x4AC/0x4AE and update the device records, so these are
 * snapshotted around every call and put back. */
i1_save:
    push    ax
    push    cx
    push    si
    push    di
    push    es
    xor     ax, ax
    mov     es, ax
    mov     ax, es:[0x04AC]
    mov     [i1_4AC], ax
    mov     ax, es:[0x04AE]
    mov     [i1_4AE], ax
    mov     al, es:[0x0584]
    mov     [i1_584], al
    /* The option ROM increments [0x456] (its busy flag), refreshes the
     * present-drive bitmap [0x55D] and sets the IRQ flag [0x55F] bit 0, so
     * those are part of the state an INT 1Bh call can dirty. */
    mov     al, es:[0x0456]
    mov     [i1_456], al
    mov     al, es:[0x055D]
    mov     [i1_55D], al
    mov     al, es:[0x055F]
    mov     [i1_55F], al
    mov     si, 0x04B0
    mov     di, offset i1_4B0
    mov     cx, 8
    cld
1:  mov     al, es:[si]
    mov     [di], al
    inc     si
    inc     di
    loop    1b
    mov     si, 0x0460
    mov     di, offset i1_460
    mov     cx, 32
2:  mov     al, es:[si]
    mov     [di], al
    inc     si
    inc     di
    loop    2b
    pop     es
    pop     di
    pop     si
    pop     cx
    pop     ax
    ret

i1_restore:
    push    ax
    push    cx
    push    si
    push    di
    push    es
    xor     ax, ax
    mov     es, ax
    mov     ax, [i1_4AC]
    mov     es:[0x04AC], ax
    mov     ax, [i1_4AE]
    mov     es:[0x04AE], ax
    mov     al, [i1_584]
    mov     es:[0x0584], al
    mov     al, [i1_456]
    mov     es:[0x0456], al
    mov     al, [i1_55D]
    mov     es:[0x055D], al
    mov     al, [i1_55F]
    mov     es:[0x055F], al
    mov     si, offset i1_4B0
    mov     di, 0x04B0
    mov     cx, 8
    cld
1:  mov     al, [si]
    mov     es:[di], al
    inc     si
    inc     di
    loop    1b
    mov     si, offset i1_460
    mov     di, 0x0460
    mov     cx, 32
2:  mov     al, [si]
    mov     es:[di], al
    inc     si
    inc     di
    loop    2b
    pop     es
    pop     di
    pop     si
    pop     cx
    pop     ax
    ret

/* i1_do: performs one INT 1Bh with the registers in i1_in_ax/bx/cx/dx/si and
 * stores AX,BX,CX,DX,FLAGS and the published 0x4AC/0x4AE cell in i1_out
 * (8 words: ax,bx,cx,dx,flags,4ac,4ae,sent-ah). The BIOS runs with interrupts
 * enabled, exactly as the boot chain calls it. */
i1_do:
    push    es
    push    si
    push    di
    push    bp
    push    ds
    mov     ax, [i1_in_ax]
    mov     [i1_out+14], ax
    mov     bx, [i1_in_bx]
    mov     cx, [i1_in_cx]
    mov     dx, [i1_in_dx]
    mov     si, [i1_in_si]
    /* The BIOS's own thunk enters the ROM through a synthetic frame with the
     * flags word 0x00F8 (DF=0, IF=1). `int` pushes the live flags, so set DF
     * and IF explicitly: a caller that left DF set would make the ROM's rep
     * movs run backwards and corrupt the work RAM. */
    cld
    sti
    int     0x1B
    push    cs
    pop     ds              /* the disk BIOS preserves DS, but a buggy handler
                               must not be able to steer the stores below */
    mov     [i1_out+0], ax
    mov     [i1_out+2], bx
    mov     [i1_out+4], cx
    mov     [i1_out+6], dx
    pushf
    pop     ax
    mov     [i1_out+8], ax
    push    es
    xor     ax, ax
    mov     es, ax
    mov     ax, es:[0x04AC]
    mov     [i1_out+10], ax
    mov     ax, es:[0x04AE]
    mov     [i1_out+12], ax
    pop     es
    pop     ds
    pop     bp
    pop     di
    pop     si
    pop     es
    ret

/* i1_copy: BP = destination block. Copies the eight i1_out words there and
 * advances BP to the next block. */
i1_copy:
    push    ax
    push    cx
    push    si
    push    di
    mov     si, offset i1_out
    mov     di, bp
    mov     cx, 8
    cld
1:  mov     ax, [si]
    mov     [di], ax
    add     si, 2
    add     di, 2
    loop    1b
    add     bp, 16
    pop     di
    pop     si
    pop     cx
    pop     ax
    ret

sec_int1b:
    mov     si, offset msg_begin_int1b
    call    puts
    /* Read-only first, and only this unless CALL is given: the vector, the
     * boot device, the far pointer the dispatcher published, and the disk
     * work area. Nothing here enters firmware, so /INT1B alone cannot crash. */
    xor     ax, ax
    mov     es, ax
    mov     ax, es:[0x006C]
    mov     [i1_vec_off], ax
    mov     ax, es:[0x006E]
    mov     [i1_vec_seg], ax
    mov     al, es:[0x0584]
    mov     [i1_584_orig], al
    mov     ax, es:[0x04AC]
    mov     [i1_4AC_orig], ax
    mov     ax, es:[0x04AE]
    mov     [i1_4AE_orig], ax
    call    i1_save              /* fills the work-area buffers, reads only */
    mov     si, offset msg_int1b_vec
    call    puts
    mov     ax, [i1_vec_seg]
    call    puthex16
    mov     dl, ':'
    call    putc
    mov     ax, [i1_vec_off]
    call    puthex16
    mov     si, offset msg_int1b_dev
    call    puts
    mov     al, [i1_584_orig]
    call    puthex8
    mov     si, offset msg_int1b_ptr
    call    puts
    mov     ax, [i1_4AE_orig]
    call    puthex16
    mov     dl, ':'
    call    putc
    mov     ax, [i1_4AC_orig]
    call    puthex16
    call    putnl
    mov     si, offset msg_int1b_wa
    call    puts
    mov     al, [i1_456]
    call    puthex8
    call    putsp
    mov     al, [i1_55D]
    call    puthex8
    call    putsp
    mov     al, [i1_55F]
    call    puthex8
    call    putnl
    mov     si, offset msg_int1b_4b0
    call    puts
    mov     si, offset i1_4B0
    mov     cx, 8
    call    dump_mem
    mov     si, offset msg_int1b_460
    call    puts
    mov     si, offset i1_460
    mov     cx, 32
    call    dump_mem

    mov     al, [flags2]
    test    al, FLAG2_INT1BCALL
    jnz     i1_call
    mov     si, offset msg_int1b_inert
    call    puts
    jmp     i1_done

i1_call:
    /* Entering the ROM is opt-in. Refuse unless a live INT 1Bh vector and a
     * hard-disk device number exist: with no disk BIOS the vector can be
     * 0000:0000, and a call there executes the IVT. The MBR passes AL=[0x584]
     * exactly (bit 7 selects CHS), so the probe does too. */
    cmp     word ptr [i1_vec_seg], 0
    je      i1_refuse
    cmp     word ptr [i1_vec_seg], 0xFFFF
    je      i1_refuse
    cmp     word ptr [i1_vec_off], 0xFFFF
    je      i1_refuse
    test    byte ptr [i1_584_orig], 0x80
    jz      i1_refuse
    mov     si, offset msg_int1b_call
    call    puts

    mov     bp, offset i1_blk

    /* AH=0x84: geometry (BX=bytes/sector, CX=cyl, DH=head, DL=sectors). */
    call    i1_save
    mov     al, [i1_584_orig]
    mov     ah, 0x84
    mov     [i1_in_ax], ax
    mov     word ptr [i1_in_bx], 0
    mov     word ptr [i1_in_cx], 0
    mov     word ptr [i1_in_dx], 0
    mov     word ptr [i1_in_si], 0
    call    i1_do
    call    i1_copy
    call    i1_restore

    /* AH=0x8E: extended sense (returns AL). */
    call    i1_save
    mov     al, [i1_584_orig]
    mov     ah, 0x8E
    mov     [i1_in_ax], ax
    mov     word ptr [i1_in_bx], 0
    mov     word ptr [i1_in_cx], 0
    mov     word ptr [i1_in_dx], 0
    mov     word ptr [i1_in_si], 0
    call    i1_do
    call    i1_copy
    call    i1_restore

    /* AH=0x14: the save/sense the MBR calls with BL=0. */
    call    i1_save
    mov     al, [i1_584_orig]
    mov     ah, 0x14
    mov     [i1_in_ax], ax
    mov     word ptr [i1_in_bx], 0
    mov     word ptr [i1_in_cx], 0
    mov     word ptr [i1_in_dx], 0
    mov     word ptr [i1_in_si], 0
    call    i1_do
    call    i1_copy
    call    i1_restore

    /* AH=0xB0: the MBR's parameter handshake, SI=scratch, DX=6. */
    call    i1_save
    mov     al, [i1_584_orig]
    mov     ah, 0xB0
    mov     [i1_in_ax], ax
    mov     word ptr [i1_in_bx], 0
    mov     word ptr [i1_in_cx], 0
    mov     word ptr [i1_in_dx], 6
    mov     word ptr [i1_in_si], offset i1_b0buf
    call    i1_do
    call    i1_copy
    call    i1_restore

    /* AH=0x24: the MBR's own arguments. */
    call    i1_save
    mov     al, [i1_584_orig]
    mov     ah, 0x24
    mov     [i1_in_ax], ax
    mov     word ptr [i1_in_bx], 0x0400
    mov     word ptr [i1_in_cx], 0x1230
    mov     word ptr [i1_in_dx], 0x0140
    mov     word ptr [i1_in_si], 0
    call    i1_do
    call    i1_copy
    call    i1_restore

    /* Print one line per service, then the 0xB0 handshake buffer. */
    mov     bp, offset i1_blk
    mov     cx, 5
si_print:
    push    cx
    mov     si, offset msg_int1b_ah
    call    puts
    mov     al, [bp+15]
    call    puthex8
    mov     si, offset msg_int1b_ax
    call    puts
    mov     ax, [bp+0]
    call    puthex16
    mov     si, offset msg_int1b_bx
    call    puts
    mov     ax, [bp+2]
    call    puthex16
    mov     si, offset msg_int1b_cx
    call    puts
    mov     ax, [bp+4]
    call    puthex16
    mov     si, offset msg_int1b_dx
    call    puts
    mov     ax, [bp+6]
    call    puthex16
    mov     si, offset msg_int1b_f
    call    puts
    mov     ax, [bp+8]
    call    puthex16
    mov     si, offset msg_int1b_4ac
    call    puts
    mov     ax, [bp+12]
    call    puthex16
    mov     dl, ':'
    call    putc
    mov     ax, [bp+10]
    call    puthex16
    call    putnl
    pop     cx
    add     bp, 16
    dec     cx
    jnz     si_print

    mov     si, offset msg_int1b_b0
    call    puts
    mov     si, offset i1_b0buf
    mov     cx, 16
    call    dump_words
    jmp     i1_done

i1_refuse:
    mov     si, offset msg_int1b_refuse
    call    puts
i1_done:
    mov     si, offset msg_end_int1b
    call    puts
    ret

/* ------------------------------------------------------------------ */
/* section: /MODE - the 0x989x register file and the CPU-MODE straps  */
/* ------------------------------------------------------------------ */
/* The ITF reads port 0x9894 at BANK4@0xFCAED and takes the fatal
 * clock-reprogram and the `out` to `0xF0` branch unless bit 3 is 0; the main BIOS forwards
 * the same bit to 0xF0 (BANK7@0xFD867). QEMU answers the hardcoded 0x90, but
 * that byte is chosen, not measured: only bit 3 = 0 is proven, from the dump.
 * This section measures the machine's byte, and the 0x8E1E/0x8F1E software-DIP
 * straps the firmware prints "CPU MODE  High" from (BANK4@0xFA7EB: 0x8F1E bit 2
 * clear -> High), so the capture says which CPU mode the 0x9894 reading came
 * from. Every port is read twice, so a stable strap can be told from a port
 * that consumes state when read. No port is written: the restore report below
 * is the explicit "none (no writes were made)". */
sec_mode:
    mov     si, offset msg_begin_mode
    call    puts
    mov     si, offset msg_mode_hdr
    call    puts
    mov     si, offset tab_mode
    call    dump_port_twice
    mov     si, offset msg_mode_hint
    call    puts
    mov     si, offset msg_mode_ro
    call    puts
    mov     si, offset msg_end_mode
    call    puts
    ret

/* dump_port_twice: DS:SI = table of words, 0xFFFF terminated. Prints each port
 * and two consecutive reads of it as `PPPP=V1 V2`, so a port that consumed
 * state on the first read would show a different V2. Read-only, so first-touch
 * values survive; none of these ports is a consume-on-read port, so read_byte
 * never skips one. */
dump_port_twice:
    push    ax
    push    dx
    push    si
dptw_loop:
    mov     dx, [si]
    cmp     dx, 0xFFFF
    je      dptw_done
    add     si, 2
    call    dptw_one
    call    putnl
    jmp     dptw_loop
dptw_done:
    pop     si
    pop     dx
    pop     ax
    ret

dptw_one:                       /* DX = port */
    call    read_byte
    mov     [mode_r1], al
    call    read_byte
    mov     [mode_r2], al
    push    dx                  /* putc writes DL, so DX must survive */
    mov     ax, dx
    xchg    al, ah
    call    puthex8
    mov     al, ah
    call    puthex8
    mov     dl, '='
    call    putc
    pop     dx
    mov     al, [mode_r1]
    call    puthex8
    call    putsp
    mov     al, [mode_r2]
    call    puthex8
    ret

/* ------------------------------------------------------------------ */
/* section: /ROMCK - the two ROM windows the ITF checksums             */
/* ------------------------------------------------------------------ */
/* The ITF's RAM-resident stage-1C code, relocated to physical 0, writes
 * 0x43D=2 to put the main-BIOS top bank into the 0xF8000 window and then sums
 * 0x4000 words of DS=0xF800 and 0x8000 words of DS=0xE800:
 *
 *   043D <- 2                                (BANK4@0x0188)
 *   xor dx,dx ; lodsw ; add dl,al ; add dh,ah ; loop   (BANK4@0x019B/0x01B6)
 *   or dx,dx ; stc ; je ok                   (BANK4@0x01A2/0x01BD)
 *
 * `or dx,dx` is zero only when the low-byte 8-bit sum (DL) and the high-byte
 * 8-bit sum (DH) are both zero; it is not the plain 16-bit word sum, because
 * the carry out of DL is discarded. A mismatch halts at "ROM SUM ERROR"
 * (BANK4@0xF8278). This section reads the same two windows through the same
 * segment:offset with the same 16-bit reads and prints each window's 8-bit
 * byte sum, 16-bit word sum, byte count and first/last bytes, so the transcript
 * shows what was summed.
 *
 * READ-ONLY: no port is written. That matters for the F8000 window: the
 * firmware's own path forces the bank with 0x43D=2, and 0x43D's read is a strap
 * (`0xFF`), so a read-only probe cannot select the bank nor confirm which one it
 * summed - it reads whatever bank the DOS prompt left there. On a booted machine
 * that window is the writable BIOS copy (0x53D bit 1 / 0x43F 0x8x), which the
 * ITF itself has already modified: BANK4@0x19D4 writes its drive byte to
 * 0xF8E90, so the byte at window offset 0xE90 is read and printed explicitly and
 * the result is labelled as the ITF's runtime image rather than as the raw-ROM
 * checksum input. A constant window (every byte identical) is reported as open
 * bus, not as a sum. */
sec_romck:
    mov     si, offset msg_begin_romck
    call    puts
    mov     si, offset msg_romck_hdr
    call    puts
    mov     si, offset msg_romck_pass
    call    puts

    /* 0x043D gates the F8000 window between the ITF bank and the main-BIOS
     * top; its read-back is a strap, so it is reported and not interpreted. */
    mov     dx, 0x043D
    call    read_byte
    push    ax
    mov     si, offset msg_romck_43d
    call    puts
    pop     ax
    call    puthex8
    call    putnl

    /* F8000 window: 32 KiB = 0x4000 words, the bank the firmware's 043D=2
     * selects. */
    mov     si, offset msg_romck_f8
    call    puts
    mov     ax, 0xF800
    mov     cx, 0x4000
    mov     bp, 0x7FF8
    mov     byte ptr [rc_f800], 1
    call    romck_one
    call    romck_report

    /* E8000 window: 64 KiB = 0x8000 words, the fixed ROM view (BANK5|BANK6).
     * The ITF reads it with no bank change and writes nothing inside it. */
    mov     si, offset msg_romck_e8
    call    puts
    mov     ax, 0xE800
    mov     cx, 0x8000
    mov     bp, 0xFFF8
    mov     byte ptr [rc_f800], 0
    call    romck_one
    call    romck_report

    mov     si, offset msg_romck_ro
    call    puts
    mov     si, offset msg_end_romck
    call    puts
    ret

/* romck_one: AX = window segment, CX = word count, BP = offset of the last 8
 * bytes. Sums the window the way the ITF does and stores the result in the
 * rc_* cells. Every access is a 16-bit read of ES; DS (the probe's data) is
 * never changed. */
romck_one:
    push    ax
    push    bx
    push    cx
    push    dx
    push    di
    push    si
    push    bp
    push    es
    mov     es, ax
    mov     [rc_words], cx
    movzx   eax, cx
    shl     eax, 1              /* bytes = words * 2; 0x8000 words = 0x10000 */
    mov     [rc_bytes], eax
    mov     word ptr [rc_s16], 0
    mov     byte ptr [rc_min], 0xFF
    mov     byte ptr [rc_max], 0x00
    xor     dx, dx
    xor     si, si
ro_loop:
    mov     ax, es:[si]
    add     si, 2
    add     dl, al
    add     dh, ah
    add     word ptr [rc_s16], ax
    cmp     al, [rc_min]
    jae     ro_min1
    mov     [rc_min], al
ro_min1:
    cmp     al, [rc_max]
    jbe     ro_max1
    mov     [rc_max], al
ro_max1:
    cmp     ah, [rc_min]
    jae     ro_min2
    mov     [rc_min], ah
ro_min2:
    cmp     ah, [rc_max]
    jbe     ro_max2
    mov     [rc_max], ah
ro_max2:
    loop    ro_loop
    mov     [rc_lo], dl
    mov     [rc_hi], dh
    mov     si, 0x0E90
    mov     al, es:[si]
    mov     [rc_e90], al
    xor     si, si
    mov     di, offset rc_first
    mov     bx, 8
ro_first:
    mov     al, es:[si]
    mov     [di], al
    inc     si
    inc     di
    dec     bx
    jnz     ro_first
    mov     si, bp
    mov     di, offset rc_last
    mov     bx, 8
ro_last:
    mov     al, es:[si]
    mov     [di], al
    inc     si
    inc     di
    dec     bx
    jnz     ro_last
    pop     es
    pop     bp
    pop     si
    pop     di
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* romck_report: print the rc_* cells as one labelled block. Read-only. */
romck_report:
    push    ax
    push    cx
    push    si
    mov     si, offset msg_romck_words
    call    puts
    mov     ax, [rc_words]
    call    puthex16
    mov     si, offset msg_romck_bytes
    call    puts
    mov     eax, [rc_bytes]
    call    puthex32
    call    putnl

    mov     si, offset msg_romck_s8
    call    puts
    mov     al, [rc_lo]
    add     al, [rc_hi]         /* total byte sum mod 256 = (lo + hi) mod 256 */
    call    puthex8
    call    putnl

    mov     si, offset msg_romck_s16
    call    puts
    mov     ax, [rc_s16]
    call    puthex16
    call    putnl

    mov     si, offset msg_romck_itf
    call    puts
    mov     al, [rc_lo]
    call    puthex8
    call    putsp
    mov     al, [rc_hi]
    call    puthex8
    call    putnl

    mov     si, offset msg_romck_first
    call    puts
    mov     si, offset rc_first
    mov     cx, 8
    call    dump_ds_hex
    mov     si, offset msg_romck_last
    call    puts
    mov     si, offset rc_last
    mov     cx, 8
    call    dump_ds_hex

    /* Offset 0xE90 is the one byte where BANK7.BIN (raw ROM, 0x00) and
     * BIOS.ROM (the ITF's runtime image, 0x04) differ. Only meaningful for the
     * F8000 window, so the line is printed there only. */
    cmp     byte ptr [rc_f800], 0
    je      rc_note_done
    mov     si, offset msg_romck_e90
    call    puts
    mov     al, [rc_e90]
    call    puthex8
    call    putnl
    cmp     byte ptr [rc_e90], 0x04
    jne     rc_note_done
    mov     si, offset msg_romck_shadow
    call    puts
rc_note_done:

    /* A constant window is open bus or storage that is not decoded through this
     * path; its sums are not a checksum, so say so rather than report them. */
    mov     al, [rc_min]
    cmp     al, [rc_max]
    jne     rc_verdict
    mov     si, offset msg_romck_const1
    call    puts
    mov     al, [rc_min]
    call    puthex8
    mov     si, offset msg_romck_const2
    call    puts
    jmp     rc_done
rc_verdict:
    /* The F8000 window can read the ITF's already-written runtime image; then
     * the raw-ROM pass condition is not what these bytes show. */
    cmp     byte ptr [rc_f800], 0
    je      rc_plain
    cmp     byte ptr [rc_e90], 0x04
    jne     rc_plain
    mov     si, offset msg_romck_na
    call    puts
    jmp     rc_done
rc_plain:
    mov     al, [rc_lo]
    or      al, [rc_hi]
    jnz     rc_bad
    mov     si, offset msg_romck_zero
    call    puts
    jmp     rc_done
rc_bad:
    mov     si, offset msg_romck_nonzero
    call    puts
rc_done:
    pop     si
    pop     cx
    pop     ax
    ret

/* dump_ds_hex: DS:SI = bytes, CX = count; prints "XX " per byte and a newline. */
dump_ds_hex:
    push    ax
    push    cx
    push    si
ddh_loop:
    mov     al, [si]
    call    puthex8
    call    putsp
    inc     si
    dec     cx
    jnz     ddh_loop
    call    putnl
    pop     si
    pop     cx
    pop     ax
    ret

/* ------------------------------------------------------------------ */
/* section: /MEMSW - the machine's own memory-switch view              */
/* ------------------------------------------------------------------ */
/* The ITF's protected-mode block (BANK4@0xF8A1F) builds its memory-switch
 * image from two surfaces this core does not model:
 *
 *   - the port pair 0x530 (address) / 0x531 (data), driven in a loop at
 *     BANK4@0xF8DC8-0xF8DF6. This section reads each twice and NEVER writes
 *     them: they are the memory-switch configuration and a write could change
 *     how the machine sees its own memory.
 *   - the CG window: the firmware selects a code through 0xA1 (high byte) and
 *     0xA3 (low byte), a row through 0xA5, and reads the pattern byte from
 *     0xA9 at BANK4@0x8BC0 (code 0x7157, row 0x27) and BANK4@0x8E3F/0x8EBD
 *     (code 0x7157/0x7257, rows 0x2D-0x2F). 0xA1/0xA3/0xA5 are ordinary CG
 *     registers (the snapshot already reads them; probes/R10.TXT shows the
 *     readable latches 00A1=2F, 00A3=57, 00A5=0F), so this section writes
 *     them, reads 0xA9, and puts them back.
 *
 * The TRAM tail (0xA3FE0 upward) is the OTHER memory-switch surface - the
 * machine's stored switch image the ITF's 0x16 block reads at 0xA3FE2+4i
 * (BANK4@0xFDAF8) - and is printed here beside the ports so the two views sit
 * in one transcript; the snapshot prints it too. All of this is read-only
 * except the three CG registers, whose restore is reported globally. */
sec_memsw:
    mov     si, offset msg_begin_memsw
    call    puts
    mov     si, offset msg_memsw_hdr
    call    puts

    /* 0x530/0x531 read twice each, and never written. The stability of the
     * two reads is the only thing a read-only probe can say about this pair. */
    mov     dx, 0x0530
    call    read_byte
    mov     [msw_530a], al
    mov     dx, 0x0530
    call    read_byte
    mov     [msw_530b], al
    mov     dx, 0x0531
    call    read_byte
    mov     [msw_531a], al
    mov     dx, 0x0531
    call    read_byte
    mov     [msw_531b], al

    /* The TRAM tail, read-only, through the same A000 segment the snapshot
     * uses. 0xA3FE2+4i runs to 0xA3FFE, inside this 32-byte window. */
    push    es
    mov     ax, 0xA000
    mov     es, ax
    mov     si, 0x3FE0
    mov     di, offset msw_tram
    mov     cx, 32
msw_tram_loop:
    mov     al, es:[si]
    mov     [di], al
    inc     si
    inc     di
    dec     cx
    jnz     msw_tram_loop
    pop     es

    /* First-touch of the three CG registers so the restore report can prove
     * the machine was put back. */
    mov     dx, 0x00A1
    call    read_byte
    mov     [msw_a1], al
    mov     dx, 0x00A3
    call    read_byte
    mov     [msw_a3], al
    mov     dx, 0x00A5
    call    read_byte
    mov     [msw_a5], al

    /* The firmware's exact sequence: A1 <- code high, A3 <- code low (0x57),
     * A5 <- row, read A9. Interrupts are off across the CG writes so a timer or
     * keyboard handler's own CG access cannot interleave with ours. */
    cli
    mov     si, offset msw_codes
    mov     bp, offset msw_cg
    mov     cx, 2
msw_code_loop:
    push    cx
    mov     al, [si]
    mov     dx, 0x00A1
    call    latch_set
    call    io_delay
    mov     dx, 0x00A3
    mov     al, 0x57
    call    latch_set
    call    io_delay
    mov     bx, offset msw_rows
    mov     di, bp
    mov     cx, 4
msw_row_loop:
    mov     al, [bx]
    mov     [di+1], al          /* the row written to A5 */
    mov     dx, 0x00A5
    call    latch_set
    call    io_delay
    mov     dx, 0x00A9
    call    read_byte
    mov     [di+2], al          /* the pattern byte read from A9 */
    mov     al, [si]
    mov     [di+0], al          /* the A1 code high byte */
    add     di, 3
    inc     bx
    dec     cx
    jnz     msw_row_loop
    add     bp, 12
    inc     si
    pop     cx
    dec     cx
    jnz     msw_code_loop
    /* Put the three CG registers back before interrupts are re-enabled. */
    mov     dx, 0x00A1
    mov     al, [msw_a1]
    call    latch_set
    call    io_delay
    mov     dx, 0x00A3
    mov     al, [msw_a3]
    call    latch_set
    call    io_delay
    mov     dx, 0x00A5
    mov     al, [msw_a5]
    call    latch_set
    call    io_delay
    sti

    /* ---- print ---- */
    mov     si, offset msg_memsw_530
    call    puts
    mov     al, [msw_530a]
    call    puthex8
    call    putsp
    mov     al, [msw_530b]
    call    puthex8
    mov     si, offset msg_memsw_stab
    call    puts
    mov     al, [msw_530a]
    cmp     al, [msw_530b]
    jne     msw_530_chg
    mov     si, offset msg_memsw_same
    jmp     msw_530_out
msw_530_chg:
    mov     si, offset msg_memsw_changed
msw_530_out:
    call    puts
    call    putnl

    mov     si, offset msg_memsw_531
    call    puts
    mov     al, [msw_531a]
    call    puthex8
    call    putsp
    mov     al, [msw_531b]
    call    puthex8
    mov     si, offset msg_memsw_stab
    call    puts
    mov     al, [msw_531a]
    cmp     al, [msw_531b]
    jne     msw_531_chg
    mov     si, offset msg_memsw_same
    jmp     msw_531_out
msw_531_chg:
    mov     si, offset msg_memsw_changed
msw_531_out:
    call    puts
    call    putnl

    mov     si, offset msg_memsw_tram
    call    puts
    mov     si, offset msw_tram
    mov     cx, 32
    call    dump_mem

    mov     si, offset msg_memsw_cells
    call    puts
    mov     si, offset msw_tram
    add     si, 2               /* 0xA3FE2 */
    mov     cx, 8
msw_cells_loop:
    mov     al, [si]
    call    puthex8
    call    putsp
    add     si, 4
    dec     cx
    jnz     msw_cells_loop
    call    putnl

    mov     si, offset msg_memsw_cg_hdr
    call    puts
    mov     bp, offset msw_cg
    mov     cx, 8
msw_print_cg:
    push    cx
    mov     si, offset msg_memsw_cg_code
    call    puts
    mov     al, [bp+0]
    call    puthex8
    mov     al, 0x57
    call    puthex8
    mov     si, offset msg_memsw_cg_row
    call    puts
    mov     al, [bp+1]
    call    puthex8
    mov     si, offset msg_memsw_cg_a9
    call    puts
    mov     al, [bp+2]
    call    puthex8
    call    putnl
    add     bp, 3
    pop     cx
    dec     cx
    jnz     msw_print_cg

    mov     si, offset msg_memsw_ronote
    call    puts
    mov     si, offset msg_memsw_latch
    call    puts
    mov     si, offset msg_end_memsw
    call    puts

    /* The three CG registers were put back above; record that for the global
     * restore report (note_restore does not write them again). 0x530/0x531 are
     * deliberately absent: nothing was written to them. */
    mov     dx, 0x00A1
    mov     al, [msw_a1]
    call    note_restore
    mov     dx, 0x00A3
    mov     al, [msw_a3]
    call    note_restore
    mov     dx, 0x00A5
    mov     al, [msw_a5]
    call    note_restore
    ret

/* ------------------------------------------------------------------ */
/* section: /MEMCNT - the memory count's own instrument                 */
/* ------------------------------------------------------------------ */
/* The card prints `MEMORY 640KB +14336KB OK` where the machine prints
 * `+30720KB OK`. The machine's extended-size belief is built by the ITF
 * (BANK4@0xF8A1F, the protected-mode block the stage-0x25 pass hands on to)
 * from two surfaces, both decoded from the firmware:
 *   - the user-CG store, read through A1/A3/A5 -> A9: the memory-switch image
 *     high nibble at code 0x7157 row 0x27 (BANK4@0xF8BC0), the gates at codes
 *     0x7157/0x7257 rows 0x27/0x28 (BANK4@0xF8A54/0xF8A7E), and the size decode
 *     at code 0x7157 rows 0x27/0x2D/0x2E/0x2F (BANK4@0xF8E3F/0xF8EBD);
 *   - the pair 0x530 (address) / 0x531 (data), driven in a loop at
 *     BANK4@0xF8DC8-0xF8DF6 (`out dx,al; inc dx; in al,dx`).
 * This section reads both so the core's memory count can match the machine
 * instead of guessing. /MEMSW is the read-only memory-switch view; the
 * extra thing here is the index dump of 0x531 across 0x530 = 00..FF, which is
 * what says whether the pair is a real indexed register file on the machine.
 *
 * READ-FIRST. The default form writes no memory-switch port: it reads the
 * resting 0x530/0x531 and the user-CG rows, writing only the ordinary CG
 * selection registers A1/A3/A5 exactly as /MEMSW does, and putting them back.
 * The index dump is /MEMCNT WRITE: it writes ONLY the 0x530 address latch,
 * never a 0x531 data byte, so the machine's memory-switch configuration values
 * are not modified - but 0x530 is half of the pair, so per the project's own
 * hazard rule its writes stay opt-in. The index is read
 * before the sweep, restored after it under cli, and reported in RESTORE. */
sec_memcnt:
    mov     si, offset msg_begin_memcnt
    call    puts
    mov     si, offset msg_memcnt_hdr
    call    puts

    /* (A) The resting 0x530/0x531 pair, read twice each. */
    mov     dx, 0x0530
    call    read_byte
    mov     [mcnt_530a], al
    mov     dx, 0x0530
    call    read_byte
    mov     [mcnt_530b], al
    mov     dx, 0x0531
    call    read_byte
    mov     [mcnt_531a], al
    mov     dx, 0x0531
    call    read_byte
    mov     [mcnt_531b], al

    mov     si, offset msg_memcnt_530
    call    puts
    mov     al, [mcnt_530a]
    call    puthex8
    call    putsp
    mov     al, [mcnt_530b]
    call    puthex8
    mov     si, offset msg_memsw_stab
    call    puts
    mov     al, [mcnt_530a]
    cmp     al, [mcnt_530b]
    jne     mcnt_530_chg
    mov     si, offset msg_memsw_same
    jmp     mcnt_530_out
mcnt_530_chg:
    mov     si, offset msg_memsw_changed
mcnt_530_out:
    call    puts
    call    putnl

    mov     si, offset msg_memcnt_531
    call    puts
    mov     al, [mcnt_531a]
    call    puthex8
    call    putsp
    mov     al, [mcnt_531b]
    call    puthex8
    mov     si, offset msg_memsw_stab
    call    puts
    mov     al, [mcnt_531a]
    cmp     al, [mcnt_531b]
    jne     mcnt_531_chg
    mov     si, offset msg_memsw_same
    jmp     mcnt_531_out
mcnt_531_chg:
    mov     si, offset msg_memsw_changed
mcnt_531_out:
    call    puts
    call    putnl

    /* (B) The user-CG rows the ITF reads for its memory-switch image and its
     * size decode. Same sequence as /MEMSW: A1 = code high, A3 = 0x57,
     * A5 = row, read A9; the three registers are saved and put back under cli. */
    mov     dx, 0x00A1
    call    read_byte
    mov     [mcnt_a1], al
    mov     dx, 0x00A3
    call    read_byte
    mov     [mcnt_a3], al
    mov     dx, 0x00A5
    call    read_byte
    mov     [mcnt_a5], al

    cli
    mov     si, offset mcnt_cg_pairs
    mov     bp, offset mcnt_cg
    mov     cx, 9
mcnt_cg_loop:
    mov     al, [si+0]
    mov     dx, 0x00A1
    call    latch_set
    call    io_delay
    mov     al, 0x57
    mov     dx, 0x00A3
    call    latch_set
    call    io_delay
    mov     al, [si+1]
    mov     dx, 0x00A5
    call    latch_set
    call    io_delay
    mov     dx, 0x00A9
    call    read_byte
    mov     [bp+2], al
    mov     al, [si+0]
    mov     [bp+0], al
    mov     al, [si+1]
    mov     [bp+1], al
    add     si, 2
    add     bp, 3
    dec     cx
    jnz     mcnt_cg_loop
    mov     dx, 0x00A1
    mov     al, [mcnt_a1]
    call    latch_set
    call    io_delay
    mov     dx, 0x00A3
    mov     al, [mcnt_a3]
    call    latch_set
    call    io_delay
    mov     dx, 0x00A5
    mov     al, [mcnt_a5]
    call    latch_set
    call    io_delay
    sti

    mov     si, offset msg_memcnt_cg_hdr
    call    puts
    mov     bp, offset mcnt_cg
    mov     cx, 9
mcnt_cg_print:
    push    cx
    mov     si, offset msg_memsw_cg_code
    call    puts
    mov     al, [bp+0]
    call    puthex8
    mov     si, offset msg_memsw_cg_row
    call    puts
    mov     al, [bp+1]
    call    puthex8
    mov     si, offset msg_memsw_cg_a9
    call    puts
    mov     al, [bp+2]
    call    puthex8
    call    putnl
    add     bp, 3
    pop     cx
    dec     cx
    jnz     mcnt_cg_print

    /* (C) The index dump, opt-in behind WRITE. */
    mov     al, [flags2]
    test    al, FLAG2_WRITE
    jnz     mcnt_sweep
    mov     si, offset msg_memcnt_ro
    call    puts
    jmp     mcnt_done

mcnt_sweep:
    mov     si, offset msg_memcnt_sweep
    call    puts
    cli
    mov     dx, 0x0530
    call    read_byte
    mov     [mcnt_530_was], al
    xor     bx, bx
    mov     bp, offset mcnt_sweepv
mcnt_sw_loop:
    mov     dx, 0x0530
    mov     al, bl
    call    latch_set
    call    io_delay
    mov     dx, 0x0531
    call    read_byte
    mov     [bp+0], al
    inc     bp
    inc     bx
    cmp     bx, 0x0100
    jne     mcnt_sw_loop
    /* The 0x530 read-back after three fixed index writes: a latch returns the
     * last index, a strap returns a constant. Then the as-found index goes back. */
    mov     dx, 0x0530
    mov     al, 0x00
    call    latch_set
    call    io_delay
    mov     dx, 0x0530
    call    read_byte
    mov     [mcnt_rb00], al
    mov     dx, 0x0530
    mov     al, 0x55
    call    latch_set
    call    io_delay
    mov     dx, 0x0530
    call    read_byte
    mov     [mcnt_rb55], al
    mov     dx, 0x0530
    mov     al, 0xAA
    call    latch_set
    call    io_delay
    mov     dx, 0x0530
    call    read_byte
    mov     [mcnt_rbaa], al
    mov     dx, 0x0530
    mov     al, [mcnt_530_was]
    call    latch_set
    call    io_delay
    sti

    mov     si, offset msg_memcnt_dump
    call    puts
    mov     si, offset mcnt_sweepv
    mov     cx, 0x0100
    mov     byte ptr [mcnt_col], 0
mcnt_sw_print:
    test    cx, cx
    jz      mcnt_sw_pdone
    mov     al, [si]
    call    puthex8
    call    putsp
    inc     si
    dec     cx
    inc     byte ptr [mcnt_col]
    cmp     byte ptr [mcnt_col], 16
    jb      mcnt_sw_print
    mov     byte ptr [mcnt_col], 0
    call    putnl
    jmp     mcnt_sw_print
mcnt_sw_pdone:
    call    putnl

    mov     si, offset msg_memcnt_rb
    call    puts
    mov     al, [mcnt_rb00]
    call    puthex8
    call    putsp
    mov     al, [mcnt_rb55]
    call    puthex8
    call    putsp
    mov     al, [mcnt_rbaa]
    call    puthex8
    call    putnl

    mov     dx, 0x0530
    mov     al, [mcnt_530_was]
    call    note_restore

mcnt_done:
    mov     dx, 0x00A1
    mov     al, [mcnt_a1]
    call    note_restore
    mov     dx, 0x00A3
    mov     al, [mcnt_a3]
    call    note_restore
    mov     dx, 0x00A5
    mov     al, [mcnt_a5]
    call    note_restore
    mov     si, offset msg_end_memcnt
    call    puts
    ret

/* ------------------------------------------------------------------ */
/* section: /MEMRW - the 0530/0531 pair's read/write test               */
/* ------------------------------------------------------------------ */
/* Why the answer is load-bearing: the pair is either a WRITABLE REGISTER FILE that the
 * firmware programmes itself, or a READ-ONLY STRAP carrying the machine's
 * configuration. The firmware's own use cannot tell the two apart. It writes
 * the pair at BANK4@0x8C12 (`out dx,al; inc dx; out dx,al`) and at
 * BANK4@0x9146 (the register test, which writes the loop index as data), and it
 * reads it back at BANK4@0x8DC8 - and a latch and a strap that ignores writes
 * satisfy both. The resting byte a read-only capture sees is consistent with
 * both readings too, which is exactly why a read-only capture leaves the question open.
 *
 * The discriminator is one WRITE FOLLOWED BY A READ-BACK at the same index:
 *   - a read-only strap returns the SAME byte it returned before the write, and
 *     neither marker appears;
 *   - a writable register returns each marker in turn.
 * TWO markers are used rather than one, because a single marker that happens to
 * equal the resting byte proves nothing.
 *
 * Index 0x79 is first because it is the one index whose value is already
 * interpretable: one reading takes the machine's resting 0x1E there as the
 * extended size in MiB - 30 on the reference 32 MB machine, matching that
 * machine's own `+30720KB` - so the read-back line for 0x79 is the decisive one
 * and a sweep that dies later still has it.
 *
 * READ-ONLY BY DEFAULT. The default form moves no 0531 data byte and leaves no
 * 0530 index changed: it selects six indices and reads 0531 at each, which
 * moves only the address latch and puts it back. The WRITE word adds the marker
 * test, which DOES write 0531 data bytes - the most invasive thing in this
 * probe set - so it is a separate word rather than part of /MEMCNT WRITE, whose
 * README entry promises "never a 0531 data byte".
 *
 * Every byte the marker test writes is read back first, both markers are tried,
 * and the as-found byte is written back per index - which is what makes the
 * global restore correct rather than merely recorded. `record_restore` keeps ONE
 * entry per port and replays it at whatever index the latch then holds, so a
 * section that touched six registers and recorded only one byte would leave the
 * other five holding probe residue. Here each register is put back as the loop
 * goes, the as-found index is restored at the end, and only THEN are 0530 and
 * 0531 recorded - 0531 with the byte the as-found index held on entry - so the
 * replay lands in the right register with the right value. */
sec_memrw:
    mov     si, offset msg_begin_memrw
    call    puts
    mov     si, offset msg_memrw_hdr
    call    puts

    /* (A) The as-found state before anything moves: the 0530 index, and the
     * 0531 data AT that index - the byte the global restore must put back. */
    cli
    mov     dx, 0x0530
    call    read_byte
    mov     [mrw_530_was], al
    mov     dx, 0x0531
    call    read_byte
    mov     [mrw_531_was], al
    sti

    /* (B) 0531 at the six indices, 0x79 first. Reads only. */
    cli
    mov     si, offset mrw_idx
    mov     bp, offset mrw_rd
    mov     cx, MRW_N
mrw_rd_loop:
    mov     al, [si]
    mov     dx, 0x0530
    call    latch_set
    call    io_delay
    mov     dx, 0x0531
    call    read_byte
    mov     [bp+1], al
    mov     al, [si]
    mov     [bp+0], al
    add     si, 1
    add     bp, 2
    dec     cx
    jnz     mrw_rd_loop
    mov     dx, 0x0530
    mov     al, [mrw_530_was]
    call    latch_set
    call    io_delay
    sti

    mov     si, offset msg_memrw_rd_hdr
    call    puts
    mov     bp, offset mrw_rd
    mov     cx, MRW_N
mrw_rd_print:
    push    cx
    mov     si, offset msg_memrw_idx
    call    puts
    mov     al, [bp+0]
    call    puthex8
    mov     si, offset msg_memrw_val
    call    puts
    mov     al, [bp+1]
    call    puthex8
    call    putnl
    add     bp, 2
    pop     cx
    dec     cx
    jnz     mrw_rd_print

    /* (C) The marker test, opt-in behind WRITE. */
    mov     al, [flags2]
    test    al, FLAG2_WRITE
    jnz     mrw_mk
    mov     si, offset msg_memrw_ro
    call    puts
    jmp     mrw_done

mrw_mk:
    mov     si, offset msg_memrw_mk_hdr
    call    puts
    mov     si, offset mrw_idx
    mov     bp, offset mrw_mkres
    mov     cx, MRW_N
mrw_mk_loop:
    mov     al, [si]
    mov     [bp+0], al
    cli
    mov     dx, 0x0530
    call    latch_set
    call    io_delay
    mov     dx, 0x0531
    call    read_byte
    mov     [bp+1], al              /* as found */
    mov     [mrw_was], al
    mov     dx, 0x0531
    mov     al, 0x5A
    call    latch_set
    call    io_delay
    mov     dx, 0x0531
    call    read_byte
    mov     [bp+2], al              /* after marker 5A */
    mov     dx, 0x0531
    mov     al, 0xA5
    call    latch_set
    call    io_delay
    mov     dx, 0x0531
    call    read_byte
    mov     [bp+3], al              /* after marker A5 */
    mov     dx, 0x0531
    mov     al, [mrw_was]
    call    latch_set
    call    io_delay
    mov     dx, 0x0531
    call    read_byte
    mov     [bp+4], al              /* put back: the per-index restore's proof */
    sti
    add     si, 1
    add     bp, 5
    dec     cx
    jnz     mrw_mk_loop

    /* The as-found index goes back, and only then are the two ports recorded
     * for the global restore. */
    cli
    mov     dx, 0x0530
    mov     al, [mrw_530_was]
    call    latch_set
    call    io_delay
    sti
    mov     dx, 0x0530
    mov     al, [mrw_530_was]
    call    note_restore
    mov     dx, 0x0531
    mov     al, [mrw_531_was]
    call    note_restore

    mov     bp, offset mrw_mkres
    mov     cx, MRW_N
mrw_mk_print:
    push    cx
    mov     si, offset msg_memrw_idx
    call    puts
    mov     al, [bp+0]
    call    puthex8
    mov     si, offset msg_memrw_was_s
    call    puts
    mov     al, [bp+1]
    call    puthex8
    mov     si, offset msg_memrw_after
    call    puts
    mov     al, [bp+2]
    call    puthex8
    call    putsp
    mov     al, [bp+3]
    call    puthex8
    mov     si, offset msg_memrw_put
    call    puts
    mov     al, [bp+4]
    call    puthex8
    call    putnl
    add     bp, 5
    pop     cx
    dec     cx
    jnz     mrw_mk_print

    mov     si, offset msg_memrw_howto
    call    puts

mrw_done:
    mov     si, offset msg_end_memrw
    call    puts
    ret

/* ------------------------------------------------------------------ */
/* section: /SHADOW - the writable ROM shadow                           */
/* ------------------------------------------------------------------ */
/* The shadow question is the question this section is the instrument for: is
 * the 32 KiB store under the 0xF8000-0xFFFFF window ONE writable shadow that a
 * store made with any bank selected lands in, or does it follow the bank
 * selection? The ITF stores its IDE drive-candidate bitmap at physical 0xF8E90
 * while it is executing from the ITF window (BANK4@0x19D4, ES=0x98E8 with
 * 0x461=0x0E), and the IDE option ROM reads that physical byte back with the
 * main BIOS's top bank selected (BANK3@0x078E). A per-bank store model cannot
 * produce the machine's measured 0xF8E90 = 0x04, so which model is right
 * decides the write rule of the fix.
 *
 * The section answers it by writing one marker byte at physical 0xF8E90 with
 * the writable-copy gate set and the ITF bank selected - exactly the ITF's own
 * store - and then reading that physical byte back under the ITF bank, the
 * BIOS-top bank, a bank selected through 0x043F, and the same selections with
 * the gate cleared. The byte at 0xF8E90 is the right place to write: its value
 * on this machine is known (0x04), it is a data byte the option ROM only reads
 * during POST, and its neighbours discriminate a byte store from a word store.
 * 0xC0000-0xD7FFF (an absent ROM area on a non-PCI machine) and
 * 0xDA000-0xDFFFF (work RAM paged by 0x1E8E) are Q5 of the same report and are
 * read here with the 0x1E8E marker test.
 *
 * SAFETY. The window holds the running BIOS, so:
 *   - the read-only form is the default and writes nothing at all;
 *   - the writing form runs cli from its first latch write to its last restore
 *     and puts back the interrupt flag it found (IF is bit 1 of AH after
 *     pushf/pop ax), and calls no DOS function inside that window;
 *   - the only 0x053D writer is sh_gate_set, whose byte is computed from the
 *     first-touch read as (was | 0x02) or (was & ~0x02): bit 4 - the D8000 gate
 *     the resident IDE driver's INT 1Bh handler executes from, clearing which
 *     locked this machine up on 2026-09-13 - always keeps its as-found value;
 *   - the marker byte is saved, put back through the same physical address and
 *     read back before sti, and the bank selection is restored by searching for
 *     the 0x043D value that reproduces the bank byte found at 0xF8000:0000
 *     (0x043D reads back a strap, 0xFF, so it cannot be replayed); the result
 *     of both is printed as a `MEM:` was -> now report;
 *   - 0x0461 is moved only when that cannot hide this program's own pages (the
 *     window is 0x80000-0x9FFFF = pages 8 and 9; a .COM's code and stack live
 *     in page(CS) and page(CS)+1), and it is put back immediately after the
 *     store;
 *   - the 0xDA000 marker saves 16 bytes, writes 2 under each gate value, and
 *     puts the 16 back under both gate values, so the transcript proves the
 *     restore whichever value turns out to be the live one.
 */
sec_shadow:
    mov     si, offset msg_begin_shadow
    call    puts
    mov     si, offset msg_shadow_hdr
    call    puts

    /* The interrupt flag as found: the writing form restores exactly this. */
    pushf
    pop     ax
    mov     [sh_if_was], ah

    /* First touch of every latch this section can move. */
    mov     dx, 0x043D
    call    read_byte
    mov     [sh_was43d], al
    mov     dx, 0x043F
    call    read_byte
    mov     [sh_was43f], al
    mov     dx, 0x0461
    call    read_byte
    mov     [sh_was461], al
    mov     dx, 0x053D
    call    read_byte
    mov     [sh_was53d], al
    mov     dx, 0x1E8E
    call    read_byte
    mov     [sh_was1e8e], al
    mov     dx, 0x1E8E
    call    read_byte
    mov     [sh_1e8e_b], al

    /* The two 0x053D bytes this section may write: bit 1 toggled, every other
     * bit exactly as found, so bit 4 can never be cleared here. */
    mov     al, [sh_was53d]
    mov     ah, al
    or      ah, 0x02
    mov     [sh_gate_on], ah
    and     al, 0xFD
    mov     [sh_gate_off], al

    mov     si, offset msg_shadow_was
    call    puts
    mov     al, [sh_was43d]
    call    puthex8
    call    putsp
    mov     al, [sh_was43f]
    call    puthex8
    call    putsp
    mov     al, [sh_was461]
    call    puthex8
    call    putsp
    mov     al, [sh_was53d]
    call    puthex8
    call    putsp
    mov     al, [sh_was1e8e]
    call    puthex8
    call    putnl

    mov     si, offset msg_shadow_gate
    call    puts
    mov     al, [sh_gate_on]
    call    puthex8
    call    putsp
    mov     al, [sh_gate_off]
    call    puthex8
    call    putnl

    mov     si, offset msg_shadow_if
    call    puts
    mov     al, [sh_if_was]
    call    puthex8
    call    putnl

    /* As found: the byte at the window base identifies the selection (the ROM
     * bank image in the window), 0xF8E8F/0xF8E90/0xF8E91 are the marker's own
     * neighbourhood. Segment F8E8 offset 0x10 is physical 0xF8E90 - the same
     * physical address the ITF's ES=98E8 with 0x461=0x0E reaches - so these
     * reads are bank- and window-register independent. */
    mov     ax, 0xF800
    mov     es, ax
    mov     al, es:[0]
    mov     [sh_rd_id], al
    mov     ax, 0xF8E8
    mov     es, ax
    mov     al, es:[0x0F]
    mov     [sh_rd_e8f], al
    mov     al, es:[0x10]
    mov     [sh_rd_e90], al
    mov     al, es:[0x11]
    mov     [sh_rd_e91], al
    mov     ax, es:[0x10]
    mov     [sh_rd_ew], ax

    mov     si, offset msg_shadow_found
    call    puts
    mov     al, [sh_rd_id]
    call    puthex8
    call    putsp
    mov     al, [sh_rd_e8f]
    call    puthex8
    call    putsp
    mov     al, [sh_rd_e90]
    call    puthex8
    call    putsp
    mov     al, [sh_rd_e91]
    call    puthex8
    call    putsp
    mov     ax, [sh_rd_ew]
    call    puthex16
    call    putnl
    cmp     byte ptr [sh_rd_id], 0xEB
    jne     sh_id_not_itf
    mov     si, offset msg_shadow_id_itf
    call    puts
    jmp     sh_id_done
sh_id_not_itf:
    cmp     byte ptr [sh_rd_id], 0xA1
    jne     sh_id_done
    mov     si, offset msg_shadow_id_bios
    call    puts
sh_id_done:

    /* Q5: the two ranges the map audit could not answer. Read-only. */
    mov     word ptr [rr_label], offset msg_shadow_rc
    mov     word ptr [rr_seg], 0xC000
    mov     word ptr [rr_blocks], 48
    call    region_scan
    mov     word ptr [rr_label], offset msg_shadow_rd
    mov     word ptr [rr_seg], 0xDA00
    mov     word ptr [rr_blocks], 12
    call    region_scan

    mov     si, offset msg_shadow_1e8e
    call    puts
    mov     al, [sh_was1e8e]
    call    puthex8
    call    putsp
    mov     al, [sh_1e8e_b]
    call    puthex8
    mov     si, offset msg_memsw_stab
    call    puts
    mov     al, [sh_was1e8e]
    cmp     al, [sh_1e8e_b]
    jne     sh_1e8e_chg
    mov     si, offset msg_memsw_same
    call    puts
    jmp     sh_1e8e_out
sh_1e8e_chg:
    mov     si, offset msg_memsw_changed
    call    puts
sh_1e8e_out:
    call    putnl

    mov     al, [flags2]
    test    al, FLAG2_WRITE
    jnz     sh_write
    mov     si, offset msg_shadow_ro
    call    puts
    jmp     sh_done

sh_write:
    mov     si, offset msg_shadow_write
    call    puts
    cli

    /* (0) The flat-0x98E90 discriminator. The marker write below goes
     * through the ITF's own 0x0461=0x0E alias, logical 98E8:0010. The last run's
     * sweep read A5 in no state at all, so either the store only lands in the
     * BIOS-top bank, or the 0x0461 bias applies to reads but not to writes and
     * the marker went to flat physical 0x98E90. Save that flat byte now, read it
     * back after the write, and print both: A5 there after the write is the
     * bias-does-not-apply-to-writes answer. The save is also what lets the
     * restore put the flat byte back if the store really did land there. Both
     * reads set 0x0461 to identity (0x08 maps 80000-9FFFF to itself) and restore
     * it, so neither read can be hidden by the window. */
    call    sh_read_98e90
    mov     [sh_98e90_was], al

    /* (1) The state the ITF's own store runs in: writable-copy gate set, the
     * ITF bank selected through 0x043D, 0x043F left at whatever the firmware
     * left there. */
    mov     al, [sh_gate_on]
    mov     [sh_gate_now], al
    call    sh_gate_set
    call    io_delay
    mov     dx, 0x043D
    xor     al, al
    call    latch_set
    call    io_delay

    /* (2) Save the byte about to move, then choose the addressing path: the
     * ITF's own alias (0x461=0x0E with ES=0x98E8, exactly BANK4@0x19D4) when
     * that cannot hide this program's own pages (CF clear), otherwise the flat
     * segment F8E8 offset 0x10 - the same physical address either way. */
    mov     ax, 0xF8E8
    mov     es, ax
    mov     al, es:[0x10]
    mov     [sh_mark_was], al
    call    sh_own_pages_ok
    jc      sh_path_direct
    mov     dx, 0x0461
    mov     al, 0x0E
    call    latch_set
    call    io_delay
    mov     ax, 0x98E8
    mov     [sh_wseg], ax
    mov     word ptr [sh_woff], 0x0010
    mov     byte ptr [sh_alias], 1
    jmp     sh_path_done
sh_path_direct:
    mov     ax, 0xF8E8
    mov     [sh_wseg], ax
    mov     word ptr [sh_woff], 0x0010
    mov     byte ptr [sh_alias], 0
sh_path_done:
    mov     ax, [sh_wseg]
    mov     es, ax
    mov     si, [sh_woff]
    mov     al, 0xA5            /* the marker: not 04, 00, 56, 57 or FF */
    mov     es:[si], al
    /* 0x0461 goes back at once: it is the memory DOS keeps its buffers in. */
    cmp     byte ptr [sh_alias], 0
    je      sh_win_back
    mov     dx, 0x0461
    mov     al, [sh_was461]
    call    latch_set
    call    io_delay
sh_win_back:
    /* The discriminator read: what flat physical 0x98E90 holds now, after the
     * marker write. A5 = the store went to the flat address, not F8E90. */
    call    sh_read_98e90
    mov     [sh_98e90], al

    /* (3) Read the same physical byte back under each selection. Every state
     * writes the latches it names, so no state depends on the one before it;
     * states 1 and 2 are the only ones that leave 0x043F alone, and they come
     * first, so it is still the firmware's value there. */
    mov     bp, offset sh_blk
    mov     si, offset sh_tab
sh_st_loop:
    mov     al, [si]
    cmp     al, 0xFF
    je      sh_st_done
    mov     al, [si+3]
    test    al, al
    jz      sh_st_off
    mov     al, [sh_gate_on]
    jmp     sh_st_gate
sh_st_off:
    mov     al, [sh_gate_off]
sh_st_gate:
    mov     [sh_gate_now], al
    call    sh_gate_set
    call    io_delay
    mov     al, [si+1]
    cmp     al, 0xFF
    je      sh_st_no43d
    mov     dx, 0x043D
    call    latch_set
    call    io_delay
sh_st_no43d:
    mov     al, [si+2]
    cmp     al, 0xFF
    je      sh_st_no43f
    mov     dx, 0x043F
    call    latch_set
    call    io_delay
sh_st_no43f:
    mov     al, [si+0]
    mov     [bp+0], al
    mov     al, [si+1]
    mov     [bp+1], al
    mov     al, [si+2]
    mov     [bp+2], al
    mov     dx, 0x053D
    call    read_byte
    mov     [bp+3], al
    mov     ax, 0xF800
    mov     es, ax
    mov     al, es:[0]
    mov     [bp+4], al
    mov     ax, 0xF8E8
    mov     es, ax
    mov     al, es:[0x0F]
    mov     [bp+6], al
    mov     al, es:[0x10]
    mov     [bp+5], al
    mov     ax, es:[0x10]
    mov     [bp+8], ax
    add     bp, 16
    add     si, 4
    jmp     sh_st_loop
sh_st_done:

    /* (4) Put the marker byte back through the same physical address, with the
     * gate set and the ITF bank selected exactly as in (1), then read it back
     * under the BIOS-top selection, where the writable copy is in front of the
     * ROM. */
    mov     al, [sh_gate_on]
    mov     [sh_gate_now], al
    call    sh_gate_set
    call    io_delay
    mov     dx, 0x043D
    xor     al, al
    call    latch_set
    call    io_delay
    mov     ax, 0xF8E8
    mov     es, ax
    mov     al, [sh_mark_was]
    mov     es:[0x10], al
    mov     dx, 0x043D
    mov     al, 0x02
    call    latch_set
    call    io_delay
    mov     al, es:[0x10]
    mov     [sh_mark_now], al

    /* (5) The Q5 half: the 0xDA000 work-RAM marker with 0x1E8E both ways. */
    call    sh_work_test

    /* (6) Restore every latch, then verify the window rather than trusting the
     * writes. 0x053D and 0x043F go back to their as-found bytes; 0x043D cannot
     * (its read is a strap), so sh_restore_bank searches for a value that
     * reproduces the bank byte this section found. */
    mov     al, [sh_was53d]
    mov     [sh_gate_now], al
    call    sh_gate_set
    call    io_delay
    mov     dx, 0x043F
    mov     al, [sh_was43f]
    call    latch_set
    call    io_delay
    mov     dx, 0x0461
    mov     al, [sh_was461]
    call    latch_set
    call    io_delay
    /* The flat 0x98E90 put-back: if the marker store ignored the 0x0461 window
     * bias and landed there, this is the only place it can be undone. Writing
     * the saved byte back when it did not move is a no-op; when it did, the
     * print below reports it. Under cli, with 0x0461 at identity for the write. */
    mov     dx, 0x0461
    mov     al, SH_461_IDENTITY
    call    latch_set
    call    io_delay
    mov     ax, 0x98E8
    mov     es, ax
    mov     al, [sh_98e90_was]
    mov     es:[0x10], al
    mov     dx, 0x0461
    mov     al, [sh_was461]
    call    latch_set
    call    io_delay
    mov     dx, 0x1E8E
    mov     al, [sh_was1e8e]
    call    latch_set
    call    io_delay
    call    sh_restore_bank
    mov     ax, 0xF800
    mov     es, ax
    mov     al, es:[0]
    mov     [sh_ver_id], al
    mov     ax, 0xF8E8
    mov     es, ax
    mov     al, es:[0x10]
    mov     [sh_ver_e90], al
    /* The interrupt flag this section found: put it back rather than assuming
     * interrupts were on. */
    mov     al, [sh_if_was]
    test    al, 0x02
    jz      sh_no_sti
    sti
sh_no_sti:

    /* ---- print the buffered results ---- */
    mov     si, offset msg_shadow_mark1
    call    puts
    mov     al, [sh_mark_was]
    call    puthex8
    mov     si, offset msg_shadow_mark2
    call    puts
    cmp     byte ptr [sh_alias], 0
    je      sh_p_direct
    mov     si, offset msg_shadow_alias
    call    puts
    jmp     sh_p_mark3
sh_p_direct:
    mov     si, offset msg_shadow_direct
    call    puts
sh_p_mark3:
    mov     si, offset msg_shadow_mark3
    call    puts
    mov     al, [sh_mark_now]
    call    puthex8
    call    putnl

    /* The discriminator line: one byte separates the two candidate write
     * rules. `was` is physical 98E90 before the marker, `now` after it. */
    mov     si, offset msg_shadow_flat
    call    puts
    mov     al, [sh_98e90_was]
    call    puthex8
    mov     si, offset msg_shadow_flat2
    call    puts
    mov     al, [sh_98e90]
    call    puthex8
    call    putnl
    mov     si, offset msg_shadow_flat_note
    call    puts

    /* one line per state of the sweep */
    mov     bp, offset sh_blk
    mov     cx, 8
sh_pr_loop:
    push    cx
    mov     si, offset msg_shadow_state
    call    puts
    mov     al, [bp+0]
    call    puthex8
    mov     si, offset msg_shadow_s43d
    call    puts
    mov     al, [bp+1]
    call    puthex8
    mov     si, offset msg_shadow_s43f
    call    puts
    mov     al, [bp+2]
    call    puthex8
    mov     si, offset msg_shadow_s53d
    call    puts
    mov     al, [bp+3]
    call    puthex8
    mov     si, offset msg_shadow_sid
    call    puts
    mov     al, [bp+4]
    call    puthex8
    mov     si, offset msg_shadow_se90
    call    puts
    mov     al, [bp+6]
    call    puthex8
    mov     dl, '/'
    call    putc
    mov     al, [bp+5]
    call    puthex8
    mov     si, offset msg_shadow_sew
    call    puts
    mov     ax, [bp+8]
    call    puthex16
    call    putnl
    add     bp, 16
    pop     cx
    dec     cx
    jnz     sh_pr_loop

    mov     si, offset msg_shadow_statenote
    call    puts

    /* The Q5 work-RAM result: the gate read-back in each state and the marker
     * in each state. */
    mov     si, offset msg_shadow_work
    call    puts
    mov     al, [sh_g80]
    call    puthex8
    call    putsp
    mov     al, [sh_g81]
    call    puthex8
    call    putsp
    mov     al, [sh_g_end]
    call    puthex8
    call    putnl
    mov     si, offset msg_shadow_workm
    call    puts
    mov     ax, [sh_work_80w]
    call    puthex16
    call    putsp
    mov     ax, [sh_work_81w]
    call    puthex16
    call    putnl

    /* MEM: reports - every byte this section wrote, and the two addresses that
     * prove the restore. */
    mov     al, [sh_mark_was]
    mov     [sh_mb_was], al
    mov     al, [sh_mark_now]
    mov     [sh_mb_now], al
    mov     word ptr [mr_label], offset msg_shadow_mem0
    mov     word ptr [mr_was], offset sh_mb_was
    mov     word ptr [mr_now], offset sh_mb_now
    mov     word ptr [mr_len], 1
    call    mem_report

    mov     word ptr [mr_label], offset msg_shadow_mem80
    mov     word ptr [mr_was], offset sh_work_was
    mov     word ptr [mr_now], offset sh_work_80
    mov     word ptr [mr_len], 16
    call    mem_report
    mov     word ptr [mr_label], offset msg_shadow_mem81
    mov     word ptr [mr_was], offset sh_work_was
    mov     word ptr [mr_now], offset sh_work_81
    mov     word ptr [mr_len], 16
    call    mem_report
    mov     word ptr [mr_label], offset msg_shadow_memend
    mov     word ptr [mr_was], offset sh_work_was
    mov     word ptr [mr_now], offset sh_work_end
    mov     word ptr [mr_len], 16
    call    mem_report

    /* The window and the marker, read back after the restore. */
    mov     si, offset msg_shadow_verify
    call    puts
    mov     al, [sh_rd_id]
    call    puthex8
    mov     si, offset msg_arrow
    call    puts
    mov     al, [sh_ver_id]
    call    puthex8
    call    putsp
    mov     al, [sh_rd_e90]
    call    puthex8
    mov     si, offset msg_arrow
    call    puts
    mov     al, [sh_ver_e90]
    call    puthex8
    call    putnl
    mov     si, offset msg_shadow_bank
    call    puts
    mov     al, [sh_43d_restored]
    call    puthex8
    cmp     byte ptr [sh_bank_ok], 0
    jne     sh_bank_ok_out
    mov     si, offset msg_shadow_bank_bad
    call    puts
    jmp     sh_bank_out
sh_bank_ok_out:
    mov     si, offset msg_shadow_bank_ok
    call    puts
sh_bank_out:
    call    putnl

    /* The interrupts the section found are already back; say so, and say which
     * of the writes the global restore report can and cannot prove. */
    mov     si, offset msg_shadow_ifback
    call    puts

    mov     dx, 0x043D
    mov     al, [sh_43d_restored]
    call    note_restore
    mov     dx, 0x043F
    mov     al, [sh_was43f]
    call    note_restore
    mov     dx, 0x0461
    mov     al, [sh_was461]
    call    note_restore
    mov     dx, 0x053D
    mov     al, [sh_was53d]
    call    note_restore
    mov     dx, 0x1E8E
    mov     al, [sh_was1e8e]
    call    note_restore
sh_done:
    mov     si, offset msg_end_shadow
    call    puts
    ret

/* sh_gate_set: writes 0x053D from sh_gate_now. This is the ONLY 0x053D writer
 * in this section, and its byte is never an immediate: it is
 * (first-touch | 0x02) or (first-touch & ~0x02), so bit 4 - the 0xD8000
 * option-ROM gate the resident IDE driver's INT 1Bh handler executes from -
 * always keeps the value it was found with. Clearing it is what locked this
 * machine up (README, `/D8`), and build2.sh checks both halves of that (this
 * routine is the only place outside sec_d8 that may name 0x053D, and it must
 * load the byte from sh_gate_now). */
sh_gate_set:
    mov     dx, 0x053D
    mov     al, [sh_gate_now]
    out     dx, al
    ret
sh_gate_set_end:

/* sh_read_98e90: AL = the byte at physical 0x98E90. Puts 0x0461 at identity so
 * the 80000-9FFFF window maps to itself (0x08, measured in /WIN), reads
 * 98E8:0010, then puts 0x0461 back to its as-found byte. Identity cannot hide
 * anything, and it is the only value at which that read is a true flat read of
 * 0x98E90 rather than of the window the register selects. Called under cli. */
sh_read_98e90:
    push    bx
    push    dx
    push    es
    mov     dx, 0x0461
    mov     al, SH_461_IDENTITY
    call    latch_set
    call    io_delay
    mov     ax, 0x98E8
    mov     es, ax
    mov     al, es:[0x10]
    mov     bl, al
    mov     dx, 0x0461
    mov     al, [sh_was461]
    call    latch_set
    call    io_delay
    mov     al, bl
    pop     es
    pop     dx
    pop     bx
    ret

/* sh_own_pages_ok: CF clear only when moving 0x0461 cannot hide this program
 * (the same CF-clear-is-ok convention as sw_marker_ok). The window is
 * 0x80000-0x9FFFF, i.e. 64 KiB pages 8 and 9 of the first MiB, and a .COM's
 * code, data and stack live in page(CS) and (when CS is not page-aligned)
 * page(CS)+1. Those two pages must not overlap 8 or 9 or the move would replace
 * the program's own memory with the ROM window, so the caller keeps both
 * 0x0461 and 0x043F at their first-touch values instead. */
sh_own_pages_ok:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     ax, cs
    mov     bx, ax
    mov     cl, 12
    shr     ax, cl              /* AX = page(CS) */
    mov     dl, al              /* DL = own_lo */
    and     bx, 0x0FFF
    jz      sop_pages_done
    inc     al                  /* own_hi = own_lo + 1 */
sop_pages_done:
    cmp     al, 8
    jb      sop_yes             /* own_hi <= 7: both pages below the window */
    cmp     dl, 9
    ja      sop_yes             /* own_lo >= 10: both pages above it */
    stc
    jmp     sop_out
sop_yes:
    clc
sop_out:
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* sh_restore_bank: restores 0x043D. Its read-back is a strap (0xFF, and the
 * value written is not what it returns), so the held value cannot be replayed:
 * the routine instead searches the values the firmware and the references use
 * for the first that reproduces the bank byte this section found at
 * F8000:0000, and leaves that one written. Called under cli, after 0x043F and
 * 0x053D are back at their as-found bytes. If none reproduces the byte, 0x02
 * (the BIOS-top selection the ITF hands over with) is left in place and
 * sh_bank_ok stays 0, which the section prints as a warning. */
sh_restore_bank:
    push    ax
    push    dx
    push    si
    push    es
    mov     byte ptr [sh_bank_ok], 0
    mov     byte ptr [sh_43d_restored], 0xFF
    mov     si, offset sh_43d_cands
srb_loop:
    mov     al, [si]
    cmp     al, 0xFF
    je      srb_fallback
    mov     dx, 0x043D
    call    latch_set
    call    io_delay
    mov     ax, 0xF800
    mov     es, ax
    mov     al, es:[0]
    cmp     al, [sh_rd_id]
    jne     srb_next
    mov     al, [si]
    mov     [sh_43d_restored], al
    mov     byte ptr [sh_bank_ok], 1
    jmp     srb_out
srb_next:
    inc     si
    jmp     srb_loop
srb_fallback:
    mov     dx, 0x043D
    mov     al, 0x02
    call    latch_set
    call    io_delay
    mov     byte ptr [sh_43d_restored], 0x02
srb_out:
    pop     es
    pop     si
    pop     dx
    pop     ax
    ret

/* sh_work_test: the Q5 half of the section. 0xDA000-0xDFFFF is the IDE option
 * ROM's work RAM, paged in by 0x1E8E (the machine reads 0xFE there at a DOS
 * prompt; QEMU's non-PCI path treats 0x80/0x81 as the gate). 16 bytes at
 * 0xDA000 are saved, a distinct marker word is written and read back under each
 * gate value, then the 16 saved bytes are written back under BOTH values and
 * read back under each, and read again after the as-found gate value returns.
 * Called under cli; the two copies use the DS=window / ES=window directions
 * that snap_tram got backwards once, so check them in the disassembly. */
sh_work_test:
    push    ax
    push    dx
    push    di
    mov     di, offset sh_work_was
    call    sh_work_read16
    /* gate 0x80 */
    mov     dx, 0x1E8E
    mov     al, 0x80
    call    latch_set
    call    io_delay
    mov     dx, 0x1E8E
    call    read_byte
    mov     [sh_g80], al
    mov     di, offset sh_work_80
    call    sh_work_read16
    mov     ax, 0xDA00
    mov     es, ax
    mov     ax, 0xA55A
    mov     es:[0], ax
    mov     ax, es:[0]
    mov     [sh_work_80w], ax
    /* gate 0x81 */
    mov     dx, 0x1E8E
    mov     al, 0x81
    call    latch_set
    call    io_delay
    mov     dx, 0x1E8E
    call    read_byte
    mov     [sh_g81], al
    mov     di, offset sh_work_81
    call    sh_work_read16
    mov     ax, 0xDA00
    mov     es, ax
    mov     ax, 0x5AA5
    mov     es:[0], ax
    mov     ax, es:[0]
    mov     [sh_work_81w], ax
    /* put the saved bytes back under both gate values */
    mov     dx, 0x1E8E
    mov     al, 0x80
    call    latch_set
    call    io_delay
    mov     si, offset sh_work_was
    call    sh_work_write16
    mov     dx, 0x1E8E
    mov     al, 0x81
    call    latch_set
    call    io_delay
    mov     si, offset sh_work_was
    call    sh_work_write16
    /* and read again with the as-found gate value back */
    mov     dx, 0x1E8E
    mov     al, [sh_was1e8e]
    call    latch_set
    call    io_delay
    mov     dx, 0x1E8E
    call    read_byte
    mov     [sh_g_end], al
    mov     di, offset sh_work_end
    call    sh_work_read16
    pop     di
    pop     dx
    pop     ax
    ret

/* sh_work_read16: copies the 16 bytes at 0xDA000 into the buffer DS:DI.
 * DIRECTION: the window is the SOURCE, so DS becomes 0xDA00 and ES must stay
 * the probe's own segment (the snap_tram direction bug). */
sh_work_read16:
    push    ax
    push    cx
    push    si
    push    di
    push    ds
    push    es
    mov     ax, ds              /* ES = the probe's data segment */
    mov     es, ax
    mov     ax, 0xDA00
    mov     ds, ax              /* DS = the window: the SOURCE */
    xor     si, si
    mov     cx, 16
    cld
    rep     movsb
    pop     es
    pop     ds
    pop     di
    pop     si
    pop     cx
    pop     ax
    ret

/* sh_work_write16: copies 16 bytes from the buffer DS:SI to 0xDA000.
 * DIRECTION: the window is the DESTINATION, so ES becomes 0xDA00. */
sh_work_write16:
    push    ax
    push    cx
    push    si
    push    di
    push    ds
    push    es
    mov     ax, 0xDA00
    mov     es, ax              /* ES = the window: the DESTINATION */
    xor     di, di
    mov     cx, 16
    cld
    rep     movsb
    pop     es
    pop     ds
    pop     di
    pop     si
    pop     cx
    pop     ax
    ret

/* region_scan: prints one line per 2 KiB block of a region (the block's offset
 * from the region base and its first 8 bytes) and a summary over every byte:
 * min, max, the number of blocks that are entirely 0xFF, and the number whose
 * first two bytes are FF,CB (the pattern QEMU's non-PCI C-Bus ROM filler uses,
 * which is what an absent ROM area should look like). Inputs: rr_label (a
 * message), rr_seg (the region base as a segment), rr_blocks (2 KiB blocks).
 * READ-ONLY: it reads and prints, nothing else. */
region_scan:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    es
    mov     si, [rr_label]
    call    puts
    mov     byte ptr [rr_min], 0xFF
    mov     byte ptr [rr_max], 0x00
    mov     word ptr [rr_ffblk], 0
    mov     word ptr [rr_fccb], 0
    mov     word ptr [rr_off], 0
    mov     bx, [rr_blocks]
rs_blk:
    /* the line: offset and the block's first 8 bytes, copied out of the region
     * into a buffer first so no DOS call sits between two reads of it */
    mov     si, offset msg_rr_off
    call    puts
    mov     ax, [rr_off]
    call    puthex16
    mov     dl, ':'
    call    putc
    mov     dl, ' '
    call    putc
    mov     ax, [rr_seg]
    mov     es, ax
    mov     di, [rr_off]
    mov     si, offset rr_line
    mov     cx, 8
rs_head:
    mov     al, es:[di]
    mov     [si], al
    inc     di
    inc     si
    loop    rs_head
    mov     si, offset rr_line
    mov     cx, 8
    call    dump_hex_run
    call    putnl
    /* the whole 2 KiB block: min, max, and whether it is all 0xFF */
    mov     ax, [rr_seg]
    mov     es, ax
    mov     di, [rr_off]
    mov     cx, 0x800
    mov     byte ptr [rr_ffcur], 0
rs_bytes:
    mov     al, es:[di]
    cmp     al, [rr_min]
    jae     rs_min_done
    mov     [rr_min], al
rs_min_done:
    cmp     al, [rr_max]
    jbe     rs_max_done
    mov     [rr_max], al
rs_max_done:
    cmp     al, 0xFF
    je      rs_next_byte
    mov     byte ptr [rr_ffcur], 1
rs_next_byte:
    inc     di
    loop    rs_bytes
    /* the FF,CB pattern of an absent ROM area */
    mov     ax, [rr_seg]
    mov     es, ax
    mov     di, [rr_off]
    mov     al, es:[di]
    cmp     al, 0xFF
    jne     rs_no_fccb
    inc     di
    mov     al, es:[di]
    cmp     al, 0xCB
    jne     rs_no_fccb
    inc     word ptr [rr_fccb]
rs_no_fccb:
    cmp     byte ptr [rr_ffcur], 0
    jne     rs_not_ff
    inc     word ptr [rr_ffblk]
rs_not_ff:
    add     word ptr [rr_off], 0x800
    dec     bx
    jnz     rs_blk
    /* summary */
    mov     si, offset msg_rr_sum
    call    puts
    mov     ax, [rr_blocks]
    call    puthex16
    mov     si, offset msg_rr_bytes
    call    puts
    movzx   eax, word ptr [rr_blocks]
    shl     eax, 11             /* blocks * 2 KiB */
    call    puthex32
    mov     si, offset msg_rr_min
    call    puts
    mov     al, [rr_min]
    call    puthex8
    mov     si, offset msg_rr_max
    call    puts
    mov     al, [rr_max]
    call    puthex8
    mov     si, offset msg_rr_ffb
    call    puts
    mov     ax, [rr_ffblk]
    call    puthex16
    mov     si, offset msg_rr_fccb
    call    puts
    mov     ax, [rr_fccb]
    call    puthex16
    call    putnl
    pop     es
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* dump_hex_run: DS:SI = bytes, CX = count. `XX ` per byte with a trailing
 * space, no newline, so a `was ... -> now ...` line can be built from two runs
 * and a block line can be terminated by the caller. */
dump_hex_run:
    push    ax
    push    cx
    push    si
    push    dx
shr_loop:
    mov     al, [si]
    call    puthex8
    call    putsp
    inc     si
    dec     cx
    jnz     shr_loop
    pop     dx
    pop     si
    pop     cx
    pop     ax
    ret

/* mem_report: prints `LABEL was <was bytes> -> now <now bytes>`. Inputs:
 * mr_label (a message), mr_was, mr_now (buffers), mr_len. */
mem_report:
    push    ax
    push    cx
    push    si
    mov     si, [mr_label]
    call    puts
    mov     si, offset msg_mem_was
    call    puts
    mov     si, [mr_was]
    mov     cx, [mr_len]
    call    dump_hex_run
    mov     si, offset msg_mem_arrow
    call    puts
    mov     si, [mr_now]
    mov     cx, [mr_len]
    call    dump_hex_run
    call    putnl
    pop     si
    pop     cx
    pop     ax
    ret

/* ------------------------------------------------------------------ */
/* section: /XPORT - the firmware-only and measured-float port families */
/* ------------------------------------------------------------------ */
/* Six port families that only the machine's own firmware
 * evidences: no reference models them and no capture has read them, which is
 * why that report calls them where a real bug is most likely hiding. Section 2
 * lists the ports the machine is measured to answer and the core answers with
 * open bus 0xFF; reading those here is what the core's fix is checked against.
 *
 * READ-ONLY: this section writes no port of its own, so the global restore
 * report stays `none (no writes were made)` when it runs alone. (xpd_addr calls
 * INT 21h/68h to commit the redirected transcript after each address; that is a
 * DOS call, not a port write.) Two byte reads plus one
 * 16-bit read of each address separate a latch from a wide register from a
 * consume-on-read data port; nothing here is written so a latch cannot be told
 * from a strap, which is why the section prints what the firmware does with each
 * port (the branch operand matters more than the byte). */
/* xp_emit: print one isolated family block. BX = the tag ("XP411"), SI = the
 * family's prose header, DI = its port table. Prints BEGIN:<tag>, the prose,
 * the per-port table and END:<tag>. dump_port_xp prints each port's address
 * BEFORE its first read, so a block with no END:<tag> names the family (the
 * tag), and the last PPPP printed names the port, if a read hangs the machine. */
xp_emit:
    mov     [xp_tag], bx
    mov     [xp_hdr], si
    mov     [xp_tab], di
    mov     si, offset msg_begin_colon
    call    puts
    mov     si, [xp_tag]
    call    puts
    call    putnl
    mov     si, [xp_hdr]
    call    puts
    mov     si, [xp_tab]
    call    dump_port_xp
    mov     si, offset msg_xport_ro
    call    puts
    mov     si, offset msg_end_colon
    call    puts
    mov     si, [xp_tag]
    call    puts
    call    putnl
    ret

/* One routine per family. The six firmware-only families are the ones that can
 * hang (a read-only section can only hang on a port with a handshake), so each
 * gets its own keyword; /XPORT calls all of them and therefore hangs too. */
sec_xp411:
    mov     bx, offset tag_xp411
    mov     si, offset msg_xp411_hdr
    mov     di, offset tab_xp411
    call    xp_emit
    ret
sec_xp0b0:
    mov     bx, offset tag_xp0b0
    mov     si, offset msg_xp0b0_hdr
    mov     di, offset tab_xp0b0
    call    xp_emit
    ret
sec_xp467:
    mov     bx, offset tag_xp467
    mov     si, offset msg_xp467_hdr
    mov     di, offset tab_xp467
    call    xp_emit
    ret
sec_xp535:
    mov     bx, offset tag_xp535
    mov     si, offset msg_xp535_hdr
    mov     di, offset tab_xp535
    call    xp_emit
    ret
sec_xp238:
    mov     bx, offset tag_xp238
    mov     si, offset msg_xp238_hdr
    mov     di, offset tab_xp238
    call    xp_emit
    ret
sec_xp18f:
    mov     bx, offset tag_xp18f
    mov     si, offset msg_xp18f_hdr
    mov     di, offset tab_xp18f
    call    xp_emit
    ret
sec_xpflt:
    mov     bx, offset tag_xpflt
    mov     si, offset msg_xpflt_hdr
    mov     di, offset tab_xpflt
    call    xp_emit
    ret

/* /XP0BR: the 0B00/0B02 index/data pair's write-then-read-back. The cold
 * /XP0B0 family reads 0B00/0B01/0B02/0B03 as found; it cannot see the value the
 * ITF actually branches on, because the ITF writes the index first. At
 * BANK4@0xF9E50-0xF9E5D the ITF runs `mov dx,0B00 / mov ax,69 / out dx,ax /
 * add dl,2 / in al,dx / test al,8 / jne` - the branch operand is 0B02 READ BACK
 * AFTER 0B00 <- 0x0069, bit 3. This section replicates that for the six indices
 * the ITF writes (69, 50, 55, 59, 5C, 00), reads back 0B02 and the neighbours
 * 0B00/0B01/0B03, then does the ITF's own 0B02 bit-7 RMW (`in al / or al,80 /
 * out`) and reads that back too, so the capture shows whether the machine's data
 * port latches bit 7 and bit 3. The as-found 0B00 word and 0B02 byte are put
 * back under cli and recorded for the global restore report.
 *
 * OPT-IN WRITE: it writes the 0B00 index word and the 0B02 data byte (both the
 * ITF's own operating writes), so it is a separate keyword, not part of /XPORT
 * (which is read-only). It runs cli from the first index write to the restore,
 * calls no DOS function inside that window, and puts the pair back before sti. */
sec_xp0br:
    mov     si, offset msg_begin_xp0br
    call    puts
    mov     si, offset msg_xp0br_hdr
    call    puts

    /* (A) The as-found state: the 0B00 index word and the 0B02 data byte. */
    cli
    mov     dx, 0x0B00
    in      ax, dx
    mov     [xbr_idx_was], ax
    mov     dx, 0x0B02
    in      al, dx
    mov     [xbr_dat_was], al
    sti

    mov     si, offset msg_xp0br_cold
    call    puts
    mov     ax, [xbr_idx_was]
    call    puthex16
    mov     si, offset msg_xp0br_cold_dat
    call    puts
    mov     al, [xbr_dat_was]
    call    puthex8
    call    putnl

    /* (B) Per-index write-then-read-back. The reads are buffered and printed
     * after sti, so no DOS call sits inside the cli window. */
    mov     si, offset xbr_idx
    mov     bp, offset xbr_res
    mov     cx, XBR_N
xbr_loop:
    mov     al, [si]
    mov     [bp+0], al              /* index */
    cli
    mov     dx, 0x0B00
    xor     ah, ah
    out     dx, ax                  /* 0B00 <- 0x00xx (16-bit, the ITF's shape) */
    call    io_delay
    mov     dx, 0x0B02
    in      al, dx
    mov     [bp+1], al              /* 0B02 read-back = the branch operand */
    mov     dx, 0x0B00
    in      al, dx
    mov     [bp+2], al              /* 0B00 low byte read-back */
    mov     dx, 0x0B01
    in      al, dx
    mov     [bp+3], al              /* 0B01 read-back */
    mov     dx, 0x0B03
    in      al, dx
    mov     [bp+4], al              /* 0B03 read-back */
    mov     dx, 0x0B02
    mov     al, [bp+1]
    or      al, 0x80
    out     dx, al                  /* the ITF's 0B02 bit-7 RMW */
    call    io_delay
    in      al, dx
    mov     [bp+5], al              /* 0B02 after OR 80 */
    sti
    add     si, 1
    add     bp, 6
    dec     cx
    jnz     xbr_loop

    /* Restore the as-found pair, then record it for the global footer. */
    cli
    mov     dx, 0x0B00
    mov     ax, [xbr_idx_was]
    out     dx, ax
    call    io_delay
    mov     dx, 0x0B02
    mov     al, [xbr_dat_was]
    out     dx, al
    call    io_delay
    sti
    mov     dx, 0x0B00
    mov     ax, [xbr_idx_was]
    call    note_restore            /* DX=0B00, AL = the low byte */
    mov     dx, 0x0B01
    mov     al, ah
    call    note_restore            /* DX=0B01, AL = the high byte */
    mov     dx, 0x0B02
    mov     al, [xbr_dat_was]
    call    note_restore

    /* Print the buffered rows. */
    mov     bp, offset xbr_res
    mov     cx, XBR_N
xbr_print:
    push    cx
    mov     si, offset msg_xp0br_idx
    call    puts
    mov     al, [bp+0]
    call    puthex8
    mov     si, offset msg_xp0br_b02
    call    puts
    mov     al, [bp+1]
    call    puthex8
    mov     si, offset msg_xp0br_b3
    call    puts
    mov     al, [bp+1]
    and     al, 0x08
    jz      xbr_b3_0
    mov     si, offset msg_xp0br_b3_1
    jmp     xbr_b3_out
xbr_b3_0:
    mov     si, offset msg_xp0br_b3_0
xbr_b3_out:
    call    puts
    mov     si, offset msg_xp0br_near
    call    puts
    mov     al, [bp+2]
    call    puthex8
    call    putsp
    mov     al, [bp+3]
    call    puthex8
    call    putsp
    mov     al, [bp+4]
    call    puthex8
    mov     si, offset msg_xp0br_or80
    call    puts
    mov     al, [bp+5]
    call    puthex8
    call    putnl
    add     bp, 6
    pop     cx
    dec     cx
    jnz     xbr_print

    mov     si, offset msg_end_xp0br
    call    puts
    ret

/* /XPORT: the union. It reads the families in the order above; the isolated
 * keywords are the recommended path because a family that does hang would take
 * the whole union down with it. */
sec_xport:
    call    sec_xp411
    call    sec_xp0b0
    call    sec_xp467
    call    sec_xp535
    call    sec_xp238
    call    sec_xp18f
    call    sec_xpflt
    ret

/* dump_port_xp: DS:SI = table of words, 0xFFFF terminated. Per port
 * `PPPP=V1 V2 W=WWWW`: the address first, then two byte reads of the port and one
 * 16-bit read of the same address. V1 != V2 means the port consumed state or
 * auto-incremented on the first read; a live high byte in the word read means a
 * wide register rather than two independent bytes. A consume-on-read port is
 * skipped by read_byte and prints `-- --`, and 0x0640/0x0641/0x0740/0x0741 get no
 * 16-bit read either (a word read there would drain two words from the ATA data
 * register). READ-ONLY.
 *
 * BUG FIXED 2026-09: xpd_one's print path loads SI with msg_xp_w/msg_xp_dashes
 * (`mov si,offset msg_xp_w`), so this loop's table pointer in SI was destroyed
 * after the FIRST port. The next `mov dx,[si]` read the message string instead of
 * the table, and because xpd_one re-clobbers SI the same way every time, the loop
 * never reached the 0xFFFF terminator: it spun forever reading port 0x3D57 (the
 * bytes `W=`) and writing a line each iteration. The redirected transcript is only
 * closed - and so given a size - when the program ends, which is why the last run's
 * XPORT.TXT came back 0 bytes. SI is now saved across the call. */
dump_port_xp:
    push    ax
    push    dx
    push    si
xpd_loop:
    mov     dx, [si]
    cmp     dx, 0xFFFF
    je      xpd_done
    add     si, 2
    push    si                  /* xpd_one clobbers SI: keep the table pointer */
    call    xpd_one
    pop     si
    call    putnl
    jmp     xpd_loop
xpd_done:
    pop     si
    pop     dx
    pop     ax
    ret

/* xpd_addr: DX = port. Prints the four hex digits of the port and commits the
 * standard output. Called BEFORE the first read of the port: if that read hangs
 * the machine, the address is already in the transcript - and INT 21h/68h
 * (DOS 3.3+, a harmless CF-set failure on a character device) pushes it into
 * the file's directory entry, which DOS otherwise writes only on close, so a
 * redirected capture survives a freeze. */
xpd_addr:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     ax, dx
    xchg    al, ah
    call    puthex8
    mov     al, ah
    call    puthex8
    mov     bx, 1               /* handle 1 = stdout */
    mov     ah, 0x68            /* commit file: flush the redirected file */
    int     0x21
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

xpd_one:                        /* DX = port */
    mov     byte ptr [xp_skip], 0
    mov     byte ptr [xp_havew], 0
    call    xpd_addr            /* address before the first read (see above) */
    call    read_byte
    jc      xpd_skipped
    mov     [xp_v1], al
    call    read_byte
    mov     [xp_v2], al
    call    xp_word_ok
    jc      xpd_print
    in      ax, dx
    mov     [xp_w], ax
    mov     byte ptr [xp_havew], 1
    jmp     xpd_print
xpd_skipped:
    mov     byte ptr [xp_skip], 1
xpd_print:
    push    dx                  /* putc writes DL, so DX must survive */
    mov     dl, '='
    call    putc
    pop     dx
    cmp     byte ptr [xp_skip], 0
    je      xpd_values
    mov     dl, '-'
    call    putc
    mov     dl, '-'
    call    putc
    call    putsp
    mov     dl, '-'
    call    putc
    mov     dl, '-'
    call    putc
    jmp     xpd_word
xpd_values:
    mov     al, [xp_v1]
    call    puthex8
    call    putsp
    mov     al, [xp_v2]
    call    puthex8
xpd_word:
    call    putsp
    mov     si, offset msg_xp_w
    call    puts
    cmp     byte ptr [xp_havew], 0
    jne     xpd_word_val
    mov     si, offset msg_xp_dashes
    call    puts
    ret
xpd_word_val:
    mov     ax, [xp_w]
    call    puthex16
    ret

/* xp_word_ok: CF clear when a 16-bit read of DX is safe. The ATA data ports
 * consume a word per read, so the word read is skipped for them (a 16-bit read
 * would take two). */
xp_word_ok:
    cmp     dx, 0x0640
    je      xpw_no
    cmp     dx, 0x0641
    je      xpw_no
    cmp     dx, 0x0740
    je      xpw_no
    cmp     dx, 0x0741
    je      xpw_no
    clc
    ret
xpw_no:
    stc
    ret

/* ================================================================== */
/* The timing ladder - /TIME, /TIMEREF, /TIMESET                       */
/*                                                                    */
/* /TIME      the RATIOS. The only clock a 486 offers a DOS program is */
/*            a counter it can read, so this section uses two: the     */
/*            free-running counter at 005C (bits 15:0) / 005F (bits 23:16) */
/*            (005D/005E mirror cnt[15:8]), and the PIT's channel 0 read     */
/*            through its own counter-latch command. It measures the I/O     */
/*            access time per port class, the raster edge rates and the CPU  */
/*            rate as ratios against those two counters.               */
/* /TIMEREF   the ABSOLUTE reference. Two are provided, because      */
/*            the machine's uPD4993 calendar does not run and the    */
/*            calendar's 32.768 kHz second is therefore unavailable. */
/*            (1) OPNA Timer B on the PC-9801-86: 0188/018A register */
/*                writes, period = (256-NB)*2304/7.9872e6 s. It is   */
/*                the RTC-independent reference and the fallback.    */
/*            (2) the calendar's own six time fields, read through   */
/*                the ITF's serial sequence (BANK7@0x5D22-0x5D5A),   */
/*                with the counters' liveness proved before use.     */
/*            Either measures the PIT and ARTIC frequencies and      */
/*            converts every /TIME ratio into Hz, ns and core cycles.*/
/* /TIMESET   opt-in word for /TIMEREF: ALSO writes the calendar's own */
/*            counters with the ITF's TIMESET sequence                 */
/*            (BANK7@0x5D62-0x5D9F), which is what makes the reference */
/*            usable on a machine whose backup battery is dead. It     */
/*            replaces the machine's clock and cannot be restored; the */
/*            output prints what it wrote.                             */
/*                                                                    */
/* Every port access is the DX form (build2.sh refuses the short forms */
/* above 0xFF), and no DOS call is made inside a cli window: the class */
/* loops and the calendar bit sequences buffer nothing and call nothing */
/* but each other.                                                     */
/* ================================================================== */

/* ------------------------------------------------------------------ */
/* decimal output                                                     */
/* ------------------------------------------------------------------ */
/* putdec32: EAX in decimal, right-aligned in a field of [pd_w] characters
 * (0 = none). Clobbers EAX, EBX, ECX, EDX, DI. */
putdec32:
    push    eax
    push    ebx
    push    cx
    push    dx
    push    di
    mov     di, offset dec_buf
    xor     cx, cx
    mov     ebx, 10
pdc_loop:
    xor     edx, edx
    div     ebx
    add     dl, '0'
    mov     [di], dl
    inc     di
    inc     cx
    test    eax, eax
    jnz     pdc_loop
    mov     dx, cx
    cmp     dx, [pd_w]
    jae     pdc_out
    push    cx
    mov     cx, [pd_w]
    sub     cx, dx
pdc_pad:
    push    dx
    mov     dl, ' '
    call    putc
    pop     dx
    loop    pdc_pad
    pop     cx
pdc_out:
    dec     di
    mov     dl, [di]
    call    putc
    loop    pdc_out
    pop     di
    pop     dx
    pop     cx
    pop     ebx
    pop     eax
    ret

putdec16:                       /* AX, padded to [pd_w] */
    push    eax
    movzx   eax, ax
    call    putdec32
    pop     eax
    ret

/* putsdelta: AX = a signed 16-bit delta -> `+N`, `-N` or `0` (no padding), so a
 * row's short/long delivery count is readable straight out of the capture. */
putsdelta:
    push    eax
    movsx   eax, ax
    call    putdecs32
    pop     eax
    ret

/* putdecs32: as putdec32, with a leading '-' for a negative signed value. */
putdecs32:
    push    eax
    test    eax, eax
    jns     pds_pos
    push    eax
    mov     dl, '-'
    call    putc
    pop     eax
    neg     eax
pds_pos:
    call    putdec32
    pop     eax
    ret

/* muldiv32: EAX = (EAX * EBX) / ECX with a 64-bit intermediate. Every rate and
 * nanosecond conversion below needs it: an edge count times a frequency
 * overflows 32 bits while the quotient never does. EDX is preserved so a caller
 * can carry a sign across the call. */
muldiv32:
    push    edx
    mul     ebx
    div     ecx
    pop     edx
    ret

/* ------------------------------------------------------------------ */
/* the two clock counters                                             */
/* ------------------------------------------------------------------ */
/* pit_latch: the PIT counter-latch command, 0077 <- 00. It copies the selected
 * counter into the latch register and changes no state; it is not a mode word.
 * Deliberately NOT routed through write_byte/record_restore: 0077 is
 * write-only, its read-back is 0xFF, and replaying that byte would write a PIT
 * MODE word (counter 2, RL = 11, mode 3, BCD) and reprogram the part. The ITF's
 * own PIT self-test issues exactly this byte (BANK4@0x038F: `out dx,al` with
 * dx = 0x77 and al = 0x00), so it is the machine's own idiom. */
pit_latch:
    push    dx
    push    ax
    mov     dx, 0x0077
    mov     al, 0x00
    out     dx, al
    pop     ax
    pop     dx
    ret

/* pit_read: AX = channel 0's latched count, in the byte order pit_cal measured.
 * cli covers the latch, the two reads and the one-time calibration, so a DOS
 * interrupt's own 0071 read cannot move the pointer between them; the
 * interrupt flag is restored exactly. */
pit_read:
    push    dx
    push    cx
    pushf
    cli
    cmp     byte ptr [pit_cal_ok], 0
    jne     pr_go
    call    pit_cal
pr_go:
    call    pit_word
    popf
    pop     cx
    pop     dx
    ret

/* pit_word: one latched pair -> AX, in the byte order pit_cal decided. The
 * 8253 latch command does NOT restore the two-byte read pointer on this
 * machine: every real capture shows the order flip between runs (TIME.TXT's
 * three samples E210 E207 E1FD have the low byte ramping and a constant high
 * byte; TR.TXT's 388B 2D8B 238B have the high byte ramping instead), and a
 * mode-3 count from a 0x6000 divisor is even and never above 0x6000, so a
 * swapped word (0xE210 for 0x10E2) is exactly the PITDIV=0xFFFA defect. The
 * order is measured, not assumed.
 *
 * The mechanism is the reference's: NP2kai io/pit.c:224-239 (latchcmd) latches
 * the count and sets PIT_FLAG_C without touching PIT_FLAG_R, io/pit.c:314-360
 * (pit_getstat) uses PIT_FLAG_R as the read byte pointer and toggles it per read
 * (:352-358), and only a control word with RL != 0 clears it (io/pit.c:244-253,
 * pit_setflag). #define uPD71054 at io/pit.c:16-18 is on for CPUCORE_IA32, the
 * PC-9821 case.  That is also why sec_pit must re-run pit_cal after Experiment 1
 * consumes a raw byte: the raw read moves PIT_FLAG_R. */
pit_word:
    call    pit_bytes
    mov     al, [pit_b1]
    mov     ah, [pit_b2]
    cmp     byte ptr [pit_swap], 0
    je      pw_done
    xchg    al, ah
pw_done:
    ret

/* pit_bytes: latch channel 0, then the two bytes 0071 returns into pit_b1
 * (first) and pit_b2 (second). */
pit_bytes:
    push    dx
    call    pit_latch
    mov     dx, 0x0071
    in      al, dx
    mov     [pit_b1], al
    in      al, dx
    mov     [pit_b2], al
    pop     dx
    ret

/* pit_cal: set pit_swap by watching which of the two bytes 0071 returns moves.
 * Mode 3 decrements the count every oscillator clock, so over 32 paired reads
 * the LSB falls on almost every sample and the MSB on almost none; the byte
 * that falls more often is the LSB. A latch that restored the read pointer
 * would make this unnecessary - and would also make the byte order stable
 * between runs, which it is not. */
pit_cal:
    push    ax
    push    cx
    push    dx
    mov     word ptr [pit_d1], 0
    mov     word ptr [pit_d2], 0
    call    pit_bytes
    mov     al, [pit_b1]
    mov     [pit_pb1], al
    mov     al, [pit_b2]
    mov     [pit_pb2], al
    mov     cx, 32
pc_loop:
    call    pit_bytes
    mov     al, [pit_b1]
    cmp     al, [pit_pb1]
    jae     pc_n1
    inc     word ptr [pit_d1]
pc_n1:
    mov     [pit_pb1], al
    mov     al, [pit_b2]
    cmp     al, [pit_pb2]
    jae     pc_n2
    inc     word ptr [pit_d2]
pc_n2:
    mov     [pit_pb2], al
    loop    pc_loop
    mov     byte ptr [pit_swap], 0
    mov     ax, [pit_d2]
    cmp     ax, [pit_d1]
    jbe     pc_done
    mov     byte ptr [pit_swap], 1
pc_done:
    mov     byte ptr [pit_cal_ok], 1
    pop     dx
    pop     cx
    pop     ax
    ret

/* artic_read: EAX = the free-running counter at 005C (bits 15:0) / 005F
 * (bits 23:16). The port block is NOT four adjacent bytes: 005D and 005E both
 * carry cnt[15:8] and 005F carries cnt[23:16] (pc9821_iobus.sv HX_005C..005F;
 * NP2kai io/artic.c artic_bind attaches 005D and 005E to the same handler,
 * `cnt >> 8`, and 005F to `cnt >> 16`). Reading 005E as if it were cnt[23:16]
 * mixes cnt[23:8] into the high half and inflates every delta ~513x - which is
 * exactly the unusable per-class ARTIC column the 2026-09-14 /TIME captures
 * printed. 005F is a single byte, not a word: 0060 is the GDC status. The low
 * word wraps every 213 ms at the documented 307200 Hz, so it is read again
 * after the high byte and a wrap (lo2 < lo1) bumps the high byte. Read-only. */
artic_read:
    push    dx
    push    bx
    push    cx
    mov     dx, 0x005c
    in      ax, dx
    movzx   ebx, ax
    mov     dx, 0x005f
    in      al, dx
    movzx   ecx, al
    mov     dx, 0x005c
    in      ax, dx
    cmp     ax, bx
    jae     ar_nowrap
    inc     ecx
ar_nowrap:
    movzx   eax, ax
    shl     ecx, 16
    or      eax, ecx
    pop     cx
    pop     bx
    pop     dx
    ret

/* ------------------------------------------------------------------ */
/* the OPNA (YM2608) Timer B, an RTC-independent absolute reference    */
/* ------------------------------------------------------------------ */
/* The machine's calendar (uPD4993) is the tree's other independent time
 * base, and on this machine it does not run, so /TIMEREF's calendar second
 * is unavailable. Timer B on the PC-9801-86's OPNA does not depend on the
 * calendar. Its board interface is two ports: 0188 write = register select,
 * 018A write = data, 0188 read = chip status (bit 1 = Timer B flag, bit 7 =
 * BUSY). Register 026 is the period and 027 the control - bit 1 starts
 * Timer B, bit 3 is its IRQ enable, bit 5 clears its flag (NP2kai
 * cbus/board86.c opna_o188/opna_o18a, sound/opntimer.c opna_settimer). The
 * enable bit is SET here: QEMU (hw/audio/fmopn.c TimerBOver), NP2kai
 * (sound/opntimer.c fmport_b) and MAME all set the status flag only while the
 * enable is on, so the flag would never read without it. Period = (256-NB) * 2304 / 7987200 s
 * (jt12_timers.v header; NP2kai set_fmtimerbevent reduces to 288.46 us per
 * count), so the reference is the documented 7.9872 MHz OPNA clock. IRQ12 is
 * masked at a bare DOS prompt (no -86 driver has run).
 *
 * tb_present: select register 0xff and read 018A - the -86 answers 0x01,
 * its chip ID (NP2kai opna_i18a). AL = 1 when the card is there. Also
 * samples SSG register 7, whose reset byte is 0xbf on a real card. */
tb_present:
    push    dx
    mov     dx, 0x0188
    mov     al, 0xff
    out     dx, al
    mov     dx, 0x018a
    in      al, dx
    mov     [tb_id], al
    mov     dx, 0x0188
    mov     al, 0x07
    out     dx, al
    mov     dx, 0x018a
    in      al, dx
    mov     [tb_ssg7], al
    mov     al, [tb_id]
    cmp     al, 0x01
    sete    al
    pop     dx
    ret

/* tb_prog: period [tb_nb], clear the flag and run Timer B. Select/data writes
 * are back-to-back, as the card's own drivers issue them. */
tb_prog:
    push    ax
    push    dx
    mov     dx, 0x0188
    mov     al, 0x26
    out     dx, al
    mov     dx, 0x018a
    mov     al, [tb_nb]
    out     dx, al
    mov     dx, 0x0188
    mov     al, 0x27
    out     dx, al
    mov     dx, 0x018a
    mov     al, 0x2a            /* bit 1 = run B, bit 3 = IRQ B enable, bit 5 = clear flag B */
    out     dx, al
    pop     dx
    pop     ax
    ret

/* tb_clear: clear the Timer B flag and keep it running (027 <- 2a). */
tb_clear:
    push    ax
    push    dx
    mov     dx, 0x0188
    mov     al, 0x27
    out     dx, al
    mov     dx, 0x018a
    mov     al, 0x2a
    out     dx, al
    pop     dx
    pop     ax
    ret

/* tb_stop: stop both OPNA timers and clear both flags (027 <- 30), the state a
 * DOS prompt leaves the card in. */
tb_stop:
    push    ax
    push    dx
    mov     dx, 0x0188
    mov     al, 0x27
    out     dx, al
    mov     dx, 0x018a
    mov     al, 0x30
    out     dx, al
    pop     dx
    pop     ax
    ret

/* tb_flag: AL = 1 when the Timer B flag (0188 bit 1) is set. */
tb_flag:
    push    dx
    mov     dx, 0x0188
    in      al, dx
    and     al, 0x02
    shr     al, 1
    pop     dx
    ret

/* tb_window: count [tb_novf] Timer B overflows while sampling the PIT. The
 * shape cal_window uses against the calendar's second: the PIT is sampled
 * [tb_batch] times between two flag polls (~70 us against one 73.8 ms Timer B
 * period), so every PIT reload is seen, and one flag test per batch cannot
 * miss an overflow. Timer B must already be running. */
tb_window:
    push    ax
    push    cx
    push    dx
    mov     word ptr [tb_ovf], 0
    mov     dword ptr [tb_reloads], 0
    mov     byte ptr [tb_tmo], 0
    mov     word ptr [tb_guard], 0x4000
    call    artic_read
    mov     [tb_a0], eax
    call    pit_read
    mov     [tb_p0], ax
    mov     [tb_pv], ax
tw_outer:
    mov     cx, [tb_batch]
tw_pit:
    call    pit_read
    cmp     ax, [tb_pv]
    jbe     tw_noreload
    inc     dword ptr [tb_reloads]
tw_noreload:
    mov     [tb_pv], ax
    loop    tw_pit
    call    tb_flag
    test    al, al
    jz      tw_next
    call    tb_clear
    inc     word ptr [tb_ovf]
    mov     ax, [tb_ovf]
    cmp     ax, [tb_novf]
    jae     tw_done
tw_next:
    /* The watchdog is the ARTIC delta (3 s), not the poll count: a machine
     * whose poll loop is faster than expected would otherwise expire its guard
     * before the first 73.8 ms period. The count is the backstop for a dead
     * ARTIC. */
    call    artic_read
    sub     eax, [tb_a0]
    cmp     eax, [tb_tmax]
    jae     tw_timeout
    dec     word ptr [tb_guard]
    jnz     tw_outer
tw_timeout:
    mov     byte ptr [tb_tmo], 1
tw_done:
    call    pit_read
    mov     [tb_p1], ax
    call    artic_read
    sub     eax, [tb_a0]
    mov     [tb_artic], eax
    pop     dx
    pop     cx
    pop     ax
    ret

/* tb_pclocks: [tb_p0]/[tb_p1] first/last latched PIT counts and [tb_reloads]
 * reloads seen -> EAX = the counts moved, in pit_clocks' HALVED-ERA unit.
 * CAUTION: the /2 below is the refuted mode-3 claim
 * (the machine counts once per oscillator clock), so
 * every Timer-B-derived PIT figure this feeds is 2x small,
 * exactly like pit_clocks and tm_run.  It is kept only so the
 * printed columns stay comparable with the archived captures; quote xBASE
 * ratios, and absolute ns only from idelat/ioprobe (raw counts). */
tb_pclocks:
    mov     eax, [tb_reloads]
    movzx   ebx, word ptr [tm_div]
    mul     ebx
    push    eax
    movzx   eax, word ptr [tb_p0]
    movzx   ecx, word ptr [tb_p1]
    sub     eax, ecx
    jns     tpc_pos
    movzx   ecx, word ptr [tm_div]
    add     eax, ecx
tpc_pos:
    pop     ebx
    add     eax, ebx
    shr     eax, 1
    ret

/* tb_report: run the Timer B reference and print it. [tb_ok] = 1 and the four
 * rates are set when it measured something. Called by /TIMEREF before the
 * calendar, so a machine whose calendar is dead still has an absolute
 * reference. */
tb_report:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     byte ptr [tb_ok], 0
    mov     si, offset msg_tb_hdr
    call    puts
    call    tb_present
    mov     si, offset msg_tb_id
    call    puts
    mov     al, [tb_id]
    call    puthex8
    mov     si, offset msg_tb_ssg
    call    puts
    mov     al, [tb_ssg7]
    call    puthex8
    call    putnl
    /* The chip-ID read is informational, NOT a gate. This machine does not
     * answer 018A with the -86's 01, and R10.TXT /PORTS sees a device at the
     * 0188/018A pair anyway, so a returned 0xFF means "the chip-ID register is
     * not readable", not "no card". The window is attempted regardless and the
     * flag B overflow count decides whether Timer B ran. */
    cmp     byte ptr [tb_id], 0x01
    je      tbr_go
    mov     si, offset msg_tb_id_unread
    call    puts
tbr_go:
    call    tb_prog
    call    tb_window
    call    tb_stop
    mov     si, offset msg_tb_per
    call    puts
    mov     al, [tb_nb]
    call    puthex8
    mov     si, offset msg_tb_per2
    call    puts
    movzx   eax, word ptr [tb_ovf]
    mov     word ptr [pd_w], 0
    call    putdec32
    mov     si, offset msg_tb_per3
    call    puts
    movzx   eax, word ptr [tb_ovf]
    mov     ebx, [tb_clocks]
    mul     ebx
    mov     [tb_dur], eax
    call    putdec32
    mov     si, offset msg_tb_ns
    call    puts
    cmp     byte ptr [tb_tmo], 0
    jz      tbr_ran
    mov     si, offset msg_tb_dead
    call    puts
    jmp     tbr_out
tbr_ran:
    mov     si, offset msg_tb_ran
    call    puts
    cmp     dword ptr [tb_dur], 0
    je      tbr_out
    call    tb_pclocks
    mov     ebx, 1000000000
    mov     ecx, [tb_dur]
    call    muldiv32
    mov     [tb_fpit], eax
    mov     eax, [tb_artic]
    mov     ebx, 1000000000
    mov     ecx, [tb_dur]
    call    muldiv32
    mov     [tb_fartic], eax
    mov     eax, 1000000000
    xor     edx, edx
    mov     ebx, [tb_fpit]
    test    ebx, ebx
    jz      tbr_no_pit
    div     ebx
    mov     [tb_nspit], eax
tbr_no_pit:
    mov     eax, 1000000000
    xor     edx, edx
    mov     ebx, [tb_fartic]
    test    ebx, ebx
    jz      tbr_no_art
    div     ebx
    mov     [tb_nsartic], eax
tbr_no_art:
    mov     si, offset msg_tb_fpit
    call    puts
    mov     eax, [tb_fpit]
    mov     word ptr [pd_w], 9
    call    putdec32
    mov     word ptr [pd_w], 0
    mov     si, offset msg_tb_fpit2
    call    puts
    mov     ax, [tm_div]
    call    puthex16
    call    putnl
    mov     si, offset msg_tb_fartic
    call    puts
    mov     eax, [tb_fartic]
    mov     word ptr [pd_w], 9
    call    putdec32
    mov     word ptr [pd_w], 0
    mov     si, offset msg_tb_fartic2
    call    puts
    mov     eax, [tb_fartic]
    mov     ebx, 1000
    mov     ecx, 307200
    call    muldiv32
    sub     eax, 1000
    call    putdecs32
    mov     si, offset msg_tb_fartic3
    call    puts
    mov     eax, [tb_nspit]
    call    putdec32
    mov     si, offset msg_tb_nspit
    call    puts
    mov     eax, [tb_nsartic]
    call    putdec32
    mov     si, offset msg_tb_nsartic
    call    puts
    mov     byte ptr [tb_ok], 1
tbr_out:
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* ------------------------------------------------------------------ */
/* the calendar's serial channel, in the ITF's own sequences           */
/* ------------------------------------------------------------------ */
/* cal_wait: the ITF's own bit delay, three writes to the I/O-wait port 005F
 * (BANK7@0x5E3D). 005F has no state on any reference - QEMU's
 * pc98_wait_write is empty, NP2kai does not decode it, and the hardware notes call it
 * "write = I/O wait" - so this is the machine's own idiom. */
cal_wait:
    push    ax
    push    dx
    mov     dx, 0x005f
    xor     al, al
    out     dx, al
    out     dx, al
    out     dx, al
    pop     dx
    pop     ax
    ret

/* cal_send: AH = a 4-bit opcode. The ITF's own serial command sender
 * (BANK7@0x5DA2): hold the field at 7, shift the opcode out LSB-first on DATA
 * with one CLK edge per bit, then pulse STB - the command is taken on the STB
 * rising edge. It leaves the command latch at 0x07, exactly the state the ITF's
 * own reader leaves behind (BANK7@0x5D5A), so a DOS clock read afterwards
 * behaves as it did before the probe ran. */
cal_send:
    push    ax
    push    cx
    push    dx
    mov     dx, 0x0020
    mov     cx, 4
cs_bit:
    push    cx
    shr     ah, 1
    mov     al, 0x07            /* field 7, CLK low, DATA 0, STB low */
    jae     cs_zero
    mov     al, 0x27            /* field 7, DATA 1 */
cs_zero:
    out     dx, al
    call    cal_wait
    or      al, 0x10            /* CLK: the rising edge shifts the opcode in */
    out     dx, al
    call    cal_wait
    pop     cx
    loop    cs_bit
    mov     al, 0x07
    out     dx, al
    call    cal_wait
    mov     al, 0x0f            /* STB: the rising edge latches the command */
    out     dx, al
    call    cal_wait
    mov     al, 0x07
    out     dx, al
    call    cal_wait
    pop     dx
    pop     cx
    pop     ax
    ret

/* cal_settle: the ITF's own settle after the SHIFT command, 36 writes to the
 * I/O-wait port (BANK7@0x5D2D). */
cal_settle:
    push    ax
    push    cx
    push    dx
    mov     cx, 0x24
    mov     dx, 0x005f
    xor     al, al
cst_loop:
    out     dx, al
    loop    cst_loop
    pop     dx
    pop     cx
    pop     ax
    ret

/* cal_clock: CX = how many bits to walk out of 0033 bit 0. Stores them as ASCII
 * '0'/'1' in cal_str and returns AL = the last eight bits, assembled LSB-first
 * exactly as the ITF's reader assembles a byte (BANK7@0x5D3D: `in al,0x33` /
 * `shr al,1` / `rcr ah,1`). A CLK rising edge on 0020 advances the shift, and
 * the read happens before the edge, as in the ITF's own loop. */
cal_clock:
    push    bx
    push    cx
    push    dx
    push    si
    mov     si, offset cal_str
    xor     ah, ah
cc_bit:
    mov     dx, 0x0033
    in      al, dx
    shr     al, 1               /* CF = bit 0 = the serial data bit */
    setc    bl
    rcr     ah, 1               /* the bits arrive LSB-first */
    mov     al, bl
    add     al, '0'
    mov     [si], al
    inc     si
    mov     dx, 0x0020
    mov     al, 0x17            /* CLK high, field 7 */
    out     dx, al
    call    cal_wait
    mov     al, 0x07            /* CLK low */
    out     dx, al
    call    cal_wait
    loop    cc_bit
    mov     byte ptr [si], 0
    mov     al, ah
    pop     si
    pop     dx
    pop     cx
    pop     bx
    ret

/* cal_head: TIMEREAD, SHIFT and the ITF's settle. Shared by the full read and by
 * the poll so both talk to the part the same way. */
cal_head:
    mov     ah, 3               /* opcode 3: TIMEREAD latches the counters */
    call    cal_send
    mov     ah, 1               /* opcode 1: SHIFT arms the output walk */
    call    cal_send
    call    cal_settle
    ret

/* cal_full: 52 bits out of the calendar. The ITF reads 48; 52 covers the
 * uPD4993A four-bit prefix our RTL models (pc9821_calendar.sv:256-259), so both
 * alignments can be printed from one read and the prefix question is
 * settled by the capture. cli covers the whole sequence. */
cal_full:
    push    cx
    pushf
    cli
    call    cal_head
    mov     cx, 52
    call    cal_clock
    popf
    pop     cx
    ret

/* cal_byte_at: BX = a bit offset into cal_str -> AL = the byte assembled from
 * those eight bits, LSB-first. */
cal_byte_at:
    push    bx
    push    cx
    push    dx
    push    si
    mov     si, offset cal_str
    add     si, bx
    xor     ah, ah
    mov     cx, 8
cba_loop:
    mov     al, [si]
    sub     al, '0'
    shr     al, 1
    rcr     ah, 1
    inc     si
    loop    cba_loop
    mov     al, ah
    pop     si
    pop     dx
    pop     cx
    pop     bx
    ret

/* cal_decode: DI = the payload bit offset (0 or 4), SI = a six-byte buffer.
 * Decodes six bytes from cal_str: seconds first, each byte LSB-first, the order
 * and direction of the ITF's own reader (BANK7@0x5D37-0x5D58 stores the first
 * byte read at es:[bx+5], and the structure reads as seconds first, year
 * last). */
cal_decode:
    push    ax
    push    bx
    push    cx
    push    si
    push    di
    mov     bx, offset cal_str
    add     bx, di
    mov     cx, 6
cd_byte:
    push    cx
    xor     ah, ah
    mov     cx, 8
cd_bit:
    mov     al, [bx]
    sub     al, '0'
    shr     al, 1               /* CF = the bit */
    rcr     ah, 1               /* LSB first */
    inc     bx
    loop    cd_bit
    mov     [si], ah
    inc     si
    pop     cx
    loop    cd_byte
    pop     di
    pop     si
    pop     cx
    pop     bx
    pop     ax
    ret

/* cal_bcd_ok: DS:SI = six decoded bytes -> AL = 1 when every nibble is 0..9 and
 * the seconds, minutes and hours are in range, else 0. It exists to say which
 * payload alignment looks like a real time; the verdict is printed either way,
 * and it deliberately does not judge the day/month packing, whose placement of
 * the weekday is a reference disagreement rather than a measurement. */
cal_bcd_ok:
    push    bx
    push    cx
    push    dx
    mov     bx, si
    mov     cx, 6
cbo_nib:
    mov     al, [bx]
    mov     dl, al
    and     dl, 0x0f
    cmp     dl, 9
    ja      cbo_no
    shr     al, 4
    cmp     al, 9
    ja      cbo_no
    inc     bx
    loop    cbo_nib
    mov     al, [si+0]
    cmp     al, 0x59
    ja      cbo_no
    mov     al, [si+1]
    cmp     al, 0x59
    ja      cbo_no
    mov     al, [si+2]
    cmp     al, 0x23
    ja      cbo_no
    mov     al, 1
    jmp     cbo_out
cbo_no:
    xor     al, al
cbo_out:
    pop     dx
    pop     cx
    pop     bx
    ret

/* cal_set: write the calendar's own counters with the ITF's TIMESET sequence
 * (BANK7@0x5D62-0x5D9F): opcode 1 arms the shift, 48 bits follow LSB-first in
 * wire order seconds..year, then opcode 2 (time set) and opcode 0 (register
 * hold). The pattern is cal_setpat, a valid but non-palindromic BCD value, so a
 * read-back that matches proves the path and one that does not is visible
 * instead of plausible. Irreversible: it replaces the machine's clock. */
cal_set:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    pushf
    cli
    mov     ah, 1
    call    cal_send
    mov     si, offset cal_setpat
    mov     bx, 6
csb_byte:
    mov     ah, [si]
    inc     si
    mov     cx, 8
csb_bit:
    shr     ah, 1
    mov     al, 0x07
    jae     csb_zero
    mov     al, 0x27
csb_zero:
    mov     dx, 0x0020
    out     dx, al
    call    cal_wait
    or      al, 0x10
    out     dx, al
    call    cal_wait
    loop    csb_bit
    dec     bx
    jnz     csb_byte
    mov     al, 0x07            /* CLK low, as the ITF's writer does */
    out     dx, al
    call    cal_wait
    mov     ah, 2               /* opcode 2: time set */
    call    cal_send
    mov     ah, 0               /* opcode 0: register hold */
    call    cal_send
    popf
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* cal_print_fields: DS:SI = six decoded bytes -> "sec=.. min=.. hour=.. day=..
 * mon/wday=.. year=.. (valid BCD|NOT valid BCD)". */
cal_print_fields:
    push    ax
    push    si
    mov     si, offset msg_cf_sec
    call    puts
    pop     si
    mov     al, [si+0]
    call    puthex8
    push    si
    mov     si, offset msg_cf_min
    call    puts
    pop     si
    mov     al, [si+1]
    call    puthex8
    push    si
    mov     si, offset msg_cf_hour
    call    puts
    pop     si
    mov     al, [si+2]
    call    puthex8
    push    si
    mov     si, offset msg_cf_day
    call    puts
    pop     si
    mov     al, [si+3]
    call    puthex8
    push    si
    mov     si, offset msg_cf_mon
    call    puts
    pop     si
    mov     al, [si+4]
    call    puthex8
    push    si
    mov     si, offset msg_cf_year
    call    puts
    pop     si
    mov     al, [si+5]
    call    puthex8
    call    cal_bcd_ok
    push    si
    test    al, al
    jz      cpf_bad
    mov     si, offset msg_cf_ok
    call    puts
    jmp     cpf_done
cpf_bad:
    mov     si, offset msg_cf_bad
    call    puts
cpf_done:
    pop     si
    pop     ax
    ret

/* cal_poll: read 12 bits and look for a one-second change. The byte at bit
 * offset 0 and the byte at offset 4 are both candidates for the seconds field
 * (they differ by the uPD4993A four-bit prefix that is still open).
 * Whichever candidate changes while the other holds still IS the seconds field,
 * so the alignment is decided by the ticking itself rather than by a decode of
 * counters that may never have been set. [cal_hit] = 1 when a change was seen. */
cal_poll:
    push    ax
    push    bx
    push    cx
    push    dx
    pushf
    cli
    call    cal_head
    mov     cx, 12
    call    cal_clock
    popf
    mov     bx, 0
    call    cal_byte_at
    mov     [cal_n0], al
    mov     bx, 4
    call    cal_byte_at
    mov     [cal_n4], al
    mov     byte ptr [cal_hit], 0
    cmp     byte ptr [cal_have], 0
    jne     cpl_cmp
    mov     byte ptr [cal_have], 1
    jmp     cpl_store
cpl_cmp:
    xor     dx, dx              /* bit 0 = offset 0 moved, bit 1 = offset 4 moved */
    mov     al, [cal_n0]
    cmp     al, [cal_b0]
    je      cpl_no0
    or      dl, 1
cpl_no0:
    mov     al, [cal_n4]
    cmp     al, [cal_b4]
    je      cpl_no4
    or      dl, 2
cpl_no4:
    test    dl, dl
    jz      cpl_store
    /* Once the alignment is known, count the seconds field and only that field:
     * the four-bit-shifted neighbour changes every ten seconds (at the tens
     * digit), and counting it once a second as well would undercount the
     * window by 10 %. While the alignment is still undecided, either change is
     * evidence that the counters are running. */
    cmp     byte ptr [cal_align], 0
    jne     cpl_maybe4
    test    dl, 1
    jz      cpl_store
    jmp     cpl_hit
cpl_maybe4:
    cmp     byte ptr [cal_align], 4
    jne     cpl_hit
    test    dl, 2
    jz      cpl_store
cpl_hit:
    mov     byte ptr [cal_hit], 1
    cmp     byte ptr [cal_align], 0xFF
    jne     cpl_store
    cmp     dl, 1
    je      cpl_a0
    cmp     dl, 2
    je      cpl_a4
    jmp     cpl_store          /* both moved: either alignment counts seconds */
cpl_a0:
    mov     byte ptr [cal_align], 0
    jmp     cpl_store
cpl_a4:
    mov     byte ptr [cal_align], 4
cpl_store:
    mov     al, [cal_n0]
    mov     [cal_b0], al
    mov     al, [cal_n4]
    mov     [cal_b4], al
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* cal_sync: wait for the next seconds-field change. Bounded by [cal_tmax] ARTIC
 * ticks and by a poll-count guard, so a calendar whose counters are not running
 * returns instead of hanging. CF = 1 on timeout. */
cal_sync:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     byte ptr [cal_have], 0
    mov     word ptr [cal_guard], 0xFFFF
    call    artic_read
    mov     [cal_a0], eax
cs_loop:
    call    cal_poll
    cmp     byte ptr [cal_hit], 0
    jne     cs_found
    call    artic_read
    sub     eax, [cal_a0]
    cmp     eax, [cal_tmax]
    jae     cs_timeout
    dec     word ptr [cal_guard]
    jnz     cs_loop
cs_timeout:
    stc
    jmp     cs_out
cs_found:
    clc
cs_out:
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* cal_window: count [cal_secs] calendar seconds while sampling the PIT counter.
 * Each outer iteration samples the PIT [tm_batch] times - a reload is one per
 * ~10 ms and a batch is ~70 us, so every reload is seen - and then reads the
 * seconds field once. [cal_tmo] is set when the guard expires, and the window's
 * ARTIC delta lands in [cal_ticks]. */
cal_window:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     byte ptr [cal_have], 0
    mov     byte ptr [cal_hit], 0
    mov     byte ptr [cal_tmo], 0
    mov     word ptr [cal_count], 0
    mov     dword ptr [cal_reloads], 0
    mov     word ptr [cal_guard], 0xFFF0
    call    artic_read
    mov     [cal_a0], eax
    call    pit_read
    mov     [cal_p0], ax
    mov     [cal_pv], ax
cw_outer:
    mov     cx, [tm_batch]
cw_pit:
    call    pit_read
    cmp     ax, [cal_pv]
    jbe     cw_noreload
    inc     dword ptr [cal_reloads]
cw_noreload:
    mov     [cal_pv], ax
    loop    cw_pit
    call    cal_poll
    cmp     byte ptr [cal_hit], 0
    je      cw_next
    inc     word ptr [cal_count]
    mov     ax, [cal_count]
    cmp     ax, [cal_secs]
    jae     cw_done
cw_next:
    dec     word ptr [cal_guard]
    jnz     cw_outer
    mov     byte ptr [cal_tmo], 1
cw_done:
    call    pit_read
    mov     [cal_p1], ax
    call    artic_read
    sub     eax, [cal_a0]
    mov     [cal_ticks], eax
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* pit_clocks: [cal_p0] and [cal_p1] are the first and last latched counts of a
 * window and [cal_reloads] the reloads seen -> EAX = the counts moved, in the
 * HALVED-ERA "oscillator clocks" unit.  CAUTION: the /2 below
 * implements the refuted mode-3 claim - a raster check on the machine measured the
 * machine's channel 0 counting ONCE per oscillator clock (8 raw counts per
 * ARTIC tick), so every printed PIT ns from /TIME/pit_clocks is 2x small.
 * The halve is kept only so /TIME's printed
 * columns stay comparable with the archived captures (docs/probes/T*.TXT);
 * quote xBASE ratios from /TIME, and absolute ns only from idelat/ioprobe,
 * which print raw counts.  One reload is a full divisor sweep of counts, the
 * partial sweep is taken modulo the divisor with one reload correction, and
 * the halve is last (the old order - halving the partial term before adding
 * the divisor - put a reloaded window ~2x too high). */
pit_clocks:
    mov     eax, [cal_reloads]
    movzx   ebx, word ptr [tm_div]
    mul     ebx
    push    eax
    movzx   eax, word ptr [cal_p0]
    movzx   ecx, word ptr [cal_p1]
    sub     eax, ecx
    jns     pc_pos
    movzx   ecx, word ptr [tm_div]
    add     eax, ecx
pc_pos:
    pop     ebx
    add     eax, ebx
    shr     eax, 1
    ret

/* ------------------------------------------------------------------ */
/* the timed class loop                                               */
/* ------------------------------------------------------------------ */
/* tm_run: DS:SI -> a tm_tab entry {port word, kind byte, pad, label word}. Runs
 * [tm_n] back-to-back accesses of that class inside one cli window and stores
 * the ARTIC delta in [tm_ad] and the PIT oscillator counts in [tm_pd].
 *
 * kind 0 = the baseline: the same dispatch and the same loop, with the bus
 * access replaced by a register move of the same length, so a class's excess
 * over BASE is the access itself.
 * kind 1 = in al,dx     kind 2 = out dx,al     kind 3 = a memory read (ES:DI)
 *
 * The PIT arithmetic is the HALVED-ERA convention (the mode-3 /2
 * below is refuted by a raster check on the machine - the machine counts once per
 * oscillator clock - and is kept only so /TIME's printed columns match the
 * archived captures; every printed PIT ns is 2x small). The signed 16-bit
 * difference ps-pe is treated as twice the clocks moved inside one period,
 * and a negative difference means the counter reloaded - one divisor more. A
 * 1 ms window on a 100 Hz channel can contain at most one reload. [tm_div] is
 * the divisor measured by tm_div_probe. */
tm_run:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    es
    mov     ax, [si]
    mov     [tm_port], ax
    mov     dl, [si+2]
    mov     [tm_kind], dl
    cmp     dl, 3
    jne     tm_notmem
    mov     es, ax              /* a memory class: ES = its segment */
    jmp     tm_haveseg
tm_notmem:
    mov     ax, ds
    mov     es, ax
tm_haveseg:
    mov     dx, [tm_port]
    xor     di, di
    pushf
    cli
    call    artic_read
    mov     [tm_a0], eax
    call    pit_read
    mov     [tm_p0], ax
    mov     cx, [tm_n]
tm_l1:
    mov     al, [tm_kind]
    test    al, al
    jz      tm_k_none
    cmp     al, 2
    je      tm_k_out
    cmp     al, 3
    je      tm_k_mem
    in      al, dx
    jmp     tm_k_done
tm_k_out:
    out     dx, al
    jmp     tm_k_done
tm_k_mem:
    mov     al, es:[di]
    jmp     tm_k_done
tm_k_none:
    mov     al, bl
tm_k_done:
    dec     cx
    jnz     tm_l1
    call    pit_read
    mov     [tm_p1], ax
    call    artic_read
    mov     [tm_a1], eax
    popf
    mov     eax, [tm_a1]
    sub     eax, [tm_a0]
    mov     [tm_ad], eax
    /* PIT: the count distance modulo the divisor is one mode-3 sweep; a
     * negative raw difference means the counter reloaded once, and adding the
     * divisor once recovers it. The halve below is the halved-era unit (see the
     * tm_run header comment: the printed PIT ns
     * are 2x small); it is kept for capture comparability only. */
    movzx   eax, word ptr [tm_p0]
    movzx   ecx, word ptr [tm_p1]
    sub     eax, ecx
    jns     tm_pd_half
    cmp     byte ptr [tm_divok], 0
    je      tm_pd_half
    movzx   ecx, word ptr [tm_div]
    add     eax, ecx
tm_pd_half:
    shr     eax, 1
    mov     [tm_pd], eax
    pop     es
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* tm_div_probe: measure the PIT's own divisor by watching the counter over a
 * window bounded by the ARTIC counter (9216 ticks = 30 ms at the documented
 * 307200 Hz, longer than any possible 16-bit count period).  The absolute
 * latch word tears (scans returned 0xFFFA/0xFFEA-class
 * words that cannot be a count of the BIOS's 0x6000 divisor - item 10's
 * self-rejected /PIT run), so each candidate is now sampled TWICE back to
 * back and only a coherent pair (words within 64 counts) is accepted; the
 * largest accepted word is the divisor or one step below it.  [tm_divok] is
 * set only when at least half the attempts were coherent, so a still-tearing
 * run cannot corrupt tm_run's one-reload wrap correction.  Prints
 * accepted/attempted beside the value so a broken run is visible at a glance. */
tm_div_probe:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     word ptr [tm_dimax], 0
    mov     word ptr [tm_dtry], 0
    mov     word ptr [tm_daccept], 0
    mov     byte ptr [tm_divok], 0
    call    artic_read
    mov     [tm_a0], eax
    mov     word ptr [tm_guard], 0x4000
tdp_loop:
    call    pit_read
    mov     bx, ax
    call    pit_read
    mov     cx, ax
    inc     word ptr [tm_dtry]
    mov     ax, bx
    sub     ax, cx
    jns     tdp_d1
    neg     ax
tdp_d1:
    cmp     ax, 64
    ja      tdp_next
    inc     word ptr [tm_daccept]
    cmp     bx, [tm_dimax]
    jbe     tdp_next
    mov     [tm_dimax], bx
tdp_next:
    call    artic_read
    sub     eax, [tm_a0]
    cmp     eax, 9216
    jae     tdp_done
    dec     word ptr [tm_guard]
    jnz     tdp_loop
tdp_done:
    mov     ax, [tm_dtry]
    shr     ax, 1
    cmp     ax, [tm_daccept]
    ja      tdp_out
    cmp     word ptr [tm_dimax], 0
    je      tdp_out
    mov     byte ptr [tm_divok], 1
tdp_out:
    mov     ax, [tm_dimax]
    mov     [tm_div], ax
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* tm_div_check: the measured divisor must be one of the two the BIOS can
 * program - 0x6000 at 2.4576 MHz or 0x4E00 at 1.9968 MHz, selected by BIOS
 * work-area byte 0501 bit 7 (BANK7@0x5DE3, both ROM banks) - so the mode-3
 * scan must land in
 * 0x4000..0x7000. Anything else is not a mode-3 count: it is the latch read
 * failing (the capture's 0xFFFA is -6 as a signed word), and every absolute PIT
 * figure a run prints inherits it. The run is marked FAILED (exit 1) and says
 * so loudly, so a broken capture cannot masquerade as data. */
tm_div_check:
    push    ax
    push    si
    mov     byte ptr [tm_divbad], 0
    mov     ax, [tm_div]
    cmp     ax, 0x4000
    jb      tdc_bad
    cmp     ax, 0x7000
    jbe     tdc_done
tdc_bad:
    mov     byte ptr [tm_divbad], 1
    mov     byte ptr [run_fail], 1
    mov     si, offset msg_divbad
    call    puts
tdc_done:
    pop     si
    pop     ax
    ret

/* tm_excess: EAX = a class delta, EBX = the BASE delta, [tm_ns] = ns per tick of
 * the column, [tm_n] = the iteration count -> EAX = the signed excess in
 * nanoseconds. The sign is taken before the unsigned multiply. */
tm_excess:
    push    ebx
    push    ecx
    push    edx
    sub     eax, ebx
    jns     tme_pos
    neg     eax
    mov     edx, 1
    jmp     tme_go
tme_pos:
    xor     edx, edx
tme_go:
    push    edx
    mov     ebx, [tm_ns]
    movzx   ecx, word ptr [tm_n]
    call    muldiv32
    pop     edx
    test    edx, edx
    jz      tme_out
    neg     eax
tme_out:
    pop     edx
    pop     ecx
    pop     ebx
    ret

/* tm_print_row: one class line for /TIME. [tm_cur] is its table entry, [tm_idx]
 * its index in tm_rowa/tm_rowc. Columns: the raw deltas, then the EXCESS over
 * the BASE row in nanoseconds per access, from [tm_ns_a] and [tm_ns_p] (the
 * nanoseconds in one ARTIC tick and in one PIT count). */
tm_print_row:
    push    ax
    push    bx
    push    dx
    push    si
    push    di
    mov     bx, [tm_cur]
    mov     si, [bx+4]
    call    puts
    mov     al, [tm_kind]
    test    al, al
    jz      tpr_dashes
    mov     ax, [bx]
    call    puthex16
    jmp     tpr_deltas
tpr_dashes:
    mov     si, offset msg_tm_dashes
    call    puts
tpr_deltas:
    call    putsp
    mov     eax, [tm_ad]
    call    puthex32
    call    putsp
    mov     eax, [tm_pd]
    call    puthex32
    /* xBASE: this class's own PIT delta over the baseline measured BESIDE it, as
     * a ratio x100. Interleaving is what makes it well defined, and the ratio is
     * the point of it: the run's own scale cancels, so a class reads the same on
     * a run 9x slower than another. A class whose xBASE STILL moves between runs
     * is not scale-affected at all - it is the device itself varying, which is a
     * different defect and needs a different answer. This column replaces the
     * calculated exc_ns(artic): the raw artic_d stays for diagnosis, but every
     * ARTIC-derived figure from a run whose ARTIC per-mille check failed is
     * unusable, and the ARTIC check fails on this machine (see the README). */
    mov     di, [tm_idx]
    shl     di, 2
    mov     eax, [tm_rowc+di]
    mov     ebx, 100
    mov     ecx, [tm_basep]
    test    ecx, ecx
    jz      tpr_ratio_na
    call    muldiv32
    mov     word ptr [pd_w], 5
    call    putdecs32
    jmp     tpr_ratio_done
tpr_ratio_na:
    mov     si, offset msg_tm_dashes
    call    puts
tpr_ratio_done:
    mov     eax, [tm_rowc+di]
    mov     ebx, [tm_basep]
    mov     ecx, [tm_ns_p]
    mov     [tm_ns], ecx
    call    tm_excess
    mov     word ptr [pd_w], 8
    call    putdecs32
    mov     word ptr [pd_w], 0
    call    putnl
    pop     di
    pop     si
    pop     dx
    pop     bx
    pop     ax
    ret

/* tm_derive_row: the same row with the MEASURED PIT rate, plus the column the
 * RTL fix wants - core cycles at 50 MHz, where one cycle is 20 ns. The PIT
 * column is the one to trust: it uses no ARTIC rate and no CPU timing, only the
 * reload count, the divisor and the calendar's second. */
tm_derive_row:
    push    ax
    push    bx
    push    dx
    push    si
    push    di
    mov     bx, [tm_cur]
    mov     si, [bx+4]
    call    puts
    mov     al, [tm_kind]
    test    al, al
    jz      tdr_dashes
    mov     ax, [bx]
    call    puthex16
    jmp     tdr_calc
tdr_dashes:
    mov     si, offset msg_tm_dashes
    call    puts
tdr_calc:
    mov     di, [tm_idx]
    shl     di, 2
    mov     eax, [tm_rowc+di]
    mov     ebx, [tm_basep]
    mov     ecx, [tm_ns_p]
    mov     [tm_ns], ecx
    call    tm_excess
    push    eax
    mov     si, offset msg_tdr_ns
    call    puts
    mov     word ptr [pd_w], 8
    call    putdecs32
    mov     si, offset msg_tdr_cyc
    call    puts
    pop     eax
    add     eax, 10             /* round to the nearest core cycle */
    test    eax, eax
    jns     tdr_cycok
    xor     eax, eax
tdr_cycok:
    mov     ebx, 20
    xor     edx, edx
    div     ebx
    mov     word ptr [pd_w], 5
    call    putdec32
    mov     si, offset msg_tdr_cycend
    call    puts
    mov     word ptr [pd_w], 0
    call    putnl
    pop     di
    pop     si
    pop     dx
    pop     bx
    pop     ax
    ret

/* tm_class_loop: walk tm_tab. [tm_rerun] = 1 measures each class, 0 reuses the
 * rows /TIME stored (which is what /TIMEREF does when it reprints them with the
 * measured rates). [tm_print] selects the printer. */
tm_class_loop:
    push    ax
    push    bx
    push    si
    push    di
    mov     word ptr [tm_idx], 0
    mov     word ptr [tm_have_base], 0
    mov     si, offset tm_tab
tcl_next:
    mov     ax, [si]
    cmp     ax, 0xFFFF
    je      tcl_done
    mov     [tm_cur], si
    cmp     byte ptr [tm_rerun], 0
    je      tcl_have
    call    tm_run
    mov     di, [tm_idx]
    shl     di, 2
    mov     eax, [tm_ad]
    mov     [tm_rowa+di], eax
    mov     eax, [tm_pd]
    mov     [tm_rowc+di], eax
    /* The control row is the denominator of every neighbouring class's xBASE,
     * and a control measurement can only be inflated (an interrupt, a refresh,
     * a DMA burst) - never run faster than its own floor. So it is measured
     * twice and the smaller PIT delta is kept, which is what makes the ratio
     * repeat between runs; each class itself is still measured once. */
    mov     bx, [tm_cur]
    cmp     byte ptr [bx+2], 0
    jne     tcl_have
    call    tm_run
    mov     eax, [tm_pd]
    cmp     eax, [tm_rowc+di]
    jae     tcl_have
    mov     [tm_rowc+di], eax
    mov     eax, [tm_ad]
    mov     [tm_rowa+di], eax
tcl_have:
    mov     di, [tm_idx]
    shl     di, 2
    mov     eax, [tm_rowa+di]
    mov     [tm_ad], eax
    mov     eax, [tm_rowc+di]
    mov     [tm_pd], eax
    /* The baseline is INTERLEAVED, so every kind-0 row becomes the reference for
     * the classes beside it, not only the first one. The kind is read from the
     * table entry rather than [tm_kind], because /TIMEREF's reuse pass never
     * calls tm_run and so never sets [tm_kind]. */
    mov     bx, [tm_cur]
    cmp     byte ptr [bx+2], 0
    jne     tcl_notbase
    mov     eax, [tm_pd]
    mov     [tm_basep], eax
    mov     eax, [tm_ad]
    mov     [tm_basea], eax
    mov     word ptr [tm_have_base], 1
    /* This run's OWN control spread. A run whose baseline moves within itself is
     * not trustworthy at any ratio, and this is the in-run version of the
     * between-run spread the 2026-09-14 captures showed. */
    mov     eax, [tm_pd]
    cmp     eax, [tm_bmin]
    jae     tcl_bmin_ok
    mov     [tm_bmin], eax
tcl_bmin_ok:
    cmp     eax, [tm_bmax]
    jbe     tcl_bmax_ok
    mov     [tm_bmax], eax
tcl_bmax_ok:
    inc     word ptr [tm_bcount]
tcl_notbase:
    /* 005F is the one class with a DOCUMENTED value - the machine's own 0.6 us
     * I/O wait - so it is the row that says whether the whole run's time base is
     * right. Read the port from the table, for the same reuse-pass reason. */
    mov     ax, [bx]
    cmp     ax, 0x005f
    jne     tcl_nowait
    mov     eax, [tm_pd]
    mov     [tm_waitp], eax
tcl_nowait:
tcl_print:
    call    word ptr [tm_print]
    inc     word ptr [tm_idx]
    mov     si, [tm_cur]
    add     si, 6
    jmp     tcl_next
tcl_done:
    pop     di
    pop     si
    pop     bx
    pop     ax
    ret

/* tm_raster: count the rising edges of 00A0 bit 5 and bit 6 over a window
 * bounded by the ARTIC counter. 00A0 is the graphics GDC's status register; the
 * machine's own capture (probes/GDC.TXT) shows bit 5 high 1.7% of the time and
 * bit 6 23.4%, which read as a vertical sync pulse and a horizontal blanking
 * interval - and which is which is settled by the rates themselves, so this
 * prints two counts and does not have to guess. */
tm_raster:
    push    ax
    push    cx
    push    dx
    mov     dword ptr [tm_n5], 0
    mov     dword ptr [tm_n6], 0
    mov     dword ptr [tm_epolls], 0
    mov     byte ptr [tm_prev5], 0
    mov     byte ptr [tm_prev6], 0
    call    artic_read
    mov     [tm_art0], eax
    mov     dx, 0x00a0
    mov     word ptr [tm_guard], 0x0800
tr_outer:
    mov     cx, 0x0400
tr_poll:
    in      al, dx
    mov     ah, al
    and     al, 0x20
    cmp     al, [tm_prev5]
    je      tr_b6
    mov     [tm_prev5], al
    test    al, al
    jz      tr_b6
    inc     dword ptr [tm_n5]
tr_b6:
    mov     al, ah
    and     al, 0x40
    cmp     al, [tm_prev6]
    je      tr_next
    mov     [tm_prev6], al
    test    al, al
    jz      tr_next
    inc     dword ptr [tm_n6]
tr_next:
    inc     dword ptr [tm_epolls]
    loop    tr_poll
    call    artic_read
    sub     eax, [tm_art0]
    mov     [tm_ed], eax
    cmp     eax, [tm_rticks]
    jae     tr_done
    dec     word ptr [tm_guard]
    jnz     tr_outer
tr_done:
    pop     dx
    pop     cx
    pop     ax
    ret

/* tm_cpu: the CPU-rate loop, timed by the ARTIC counter only (/TIMEREF measures
 * the same loop against a calendar second). The body is six instructions - four
 * `add`, `dec cx`, `jnz` - repeated 4096 times per batch, and the batch count is
 * added to a 32-bit total, so the loop carries no memory write per iteration.
 * The instruction list is in the README: the reader who wants an effective
 * clock divides. */
tm_cpu:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     dword ptr [tm_cpu_iters], 0
    call    artic_read
    mov     [tm_art0], eax
    mov     word ptr [tm_guard], 0x2000
tc_outer:
    mov     cx, 0x1000
tc_inner:
    add     al, 1
    add     bl, 1
    add     al, 1
    add     bl, 1
    dec     cx
    jnz     tc_inner
    add     dword ptr [tm_cpu_iters], 0x1000
    call    artic_read
    sub     eax, [tm_art0]
    mov     [tm_cpu_ad], eax
    cmp     eax, [tm_cputicks]
    jae     tc_done
    dec     word ptr [tm_guard]
    jnz     tc_outer
tc_done:
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* tm_align_report: print the seconds-field alignment cal_align picked, or say it
 * is not yet decided. */
tm_align_report:
    push    ax
    mov     si, offset msg_tr_align
    call    puts
    mov     al, [cal_align]
    cmp     al, 0
    jne     tar_4
    mov     si, offset msg_tr_align_0
    call    puts
    jmp     tar_out
tar_4:
    cmp     al, 4
    jne     tar_unk
    mov     si, offset msg_tr_align_4
    call    puts
    jmp     tar_out
tar_unk:
    mov     si, offset msg_tr_align_unk
    call    puts
tar_out:
    pop     ax
    ret

/* cal_match_set: pick the payload alignment from the TIMESET read-back by
 * counting how many of the six fields equal the pattern written. Sets cal_align
 * to 0 or 4, and leaves 0xFF with a warning when neither matches. */
cal_match_set:
    push    ax
    push    bx
    push    dx
    xor     dx, dx
    xor     bx, bx
cms_loop0:
    mov     al, [cal_fld0+bx]
    cmp     al, [cal_setpat+bx]
    jne     cms_n0
    inc     dl
cms_n0:
    inc     bx
    cmp     bx, 6
    jb      cms_loop0
    mov     [cal_m0], dl
    xor     dx, dx
    xor     bx, bx
cms_loop4:
    mov     al, [cal_fld4+bx]
    cmp     al, [cal_setpat+bx]
    jne     cms_n4
    inc     dl
cms_n4:
    inc     bx
    cmp     bx, 6
    jb      cms_loop4
    mov     [cal_m4], dl
    mov     si, offset msg_tr_match
    call    puts
    mov     al, [cal_m0]
    call    puthex8
    call    putsp
    mov     al, [cal_m4]
    call    puthex8
    mov     si, offset msg_tr_match2
    call    puts
    cmp     byte ptr [cal_m0], 6
    jne     cms_try4
    mov     byte ptr [cal_align], 0
    jmp     cms_out
cms_try4:
    cmp     byte ptr [cal_m4], 6
    jne     cms_none
    mov     byte ptr [cal_align], 4
    jmp     cms_out
cms_none:
    mov     si, offset msg_tr_set_nomatch
    call    puts
cms_out:
    call    tm_align_report
    pop     dx
    pop     bx
    pop     ax
    ret

/* ------------------------------------------------------------------ */
/* section: /TIME                                                     */
/* ------------------------------------------------------------------ */
sec_time:
    mov     si, offset msg_begin_time
    call    puts
    mov     si, offset msg_time_hdr
    call    puts
    mov     byte ptr [tm_used], 1
    mov     si, offset msg_time_writes
    call    puts

    /* The two reference counters, read twice around three PIT samples so the
     * reader can see both of them move. */
    call    artic_read
    mov     [tm_art0], eax
    mov     si, offset msg_time_artic
    call    puts
    call    puthex32
    call    pit_read
    mov     [tm_pit1], ax
    call    pit_read
    mov     [tm_pit2], ax
    call    pit_read
    mov     [tm_pit3], ax
    call    artic_read
    mov     [tm_art1], eax
    mov     si, offset msg_time_artic2
    call    puts
    call    puthex32
    mov     si, offset msg_time_artic3
    call    puts
    mov     eax, [tm_art1]
    sub     eax, [tm_art0]
    call    puthex32
    mov     si, offset msg_time_artic4
    call    puts

    /* The BIOS's own PIT strap, out of the work-area snapshot taken before the
     * first character of output. */
    mov     si, offset msg_time_strap
    call    puts
    mov     al, [wa_buf + 0x101]
    mov     ah, al
    shr     al, 7
    and     al, 1
    call    puthex8
    mov     si, offset msg_time_strapb
    call    puts
    test    ah, 0x80
    jz      st_div6000
    mov     si, offset msg_time_div4e00
    call    puts
    jmp     st_div_done
st_div6000:
    mov     si, offset msg_time_div6000
    call    puts
st_div_done:
    call    putnl

    /* The PIT counter itself, and the divisor it is running at. */
    mov     si, offset msg_time_pits
    call    puts
    mov     ax, [tm_pit1]
    call    puthex16
    call    putsp
    mov     ax, [tm_pit2]
    call    puthex16
    call    putsp
    mov     ax, [tm_pit3]
    call    puthex16
    mov     si, offset msg_time_pitmax
    call    puts
    call    tm_div_probe
    mov     ax, [tm_div]
    call    puthex16
    cmp     word ptr [tm_div], 0
    jne     st_div_ok
    mov     si, offset msg_time_divzero
    call    puts
st_div_ok:
    call    tm_div_check
    mov     si, offset msg_time_pitd
    call    puts

    /* The GDC clock strap the BIOS published (work-area 054D bit 2). */
    mov     si, offset msg_time_54d
    call    puts
    mov     al, [wa_buf + 0x14d]
    shr     al, 2
    and     al, 1
    call    puthex8
    call    putnl

    /* The class table. */
    mov     word ptr [pd_w], 0
    mov     si, offset msg_time_cls
    call    puts
    mov     ax, [tm_n]
    call    putdec16
    mov     si, offset msg_time_clsn
    call    puts
    mov     si, offset msg_time_cols
    call    puts
    mov     dword ptr [tm_ns_a], 3255   /* 1e9 / 307200 ns per ARTIC tick */
    mov     dword ptr [tm_ns_p], 407    /* 1e9 / 2457600 ns per PIT count */
    mov     word ptr [tm_print], offset tm_print_row
    mov     byte ptr [tm_rerun], 1
    call    tm_class_loop

    /* THE SCALE CHECK, and the reason the table above is shaped the way it is.
     *
     * 005F is the machine's documented 0.6 us I/O wait - the one class whose
     * value is known independently of this probe - so it is what says whether
     * this run's time base is right. Every magnitude above inherits it: if this
     * row is 2x out, so is the whole table, whatever the rows say. The three
     * 2026-09-14 captures read 1478, 1376 and 819 ns here, i.e. up to 2.5x the
     * documented value, and the same classes moved 9x between those runs.
     *
     * That is what the interleaved baseline and the xBASE column are for: the
     * RATIO survives a scale error, the nanoseconds do not. A run that fails
     * this check must not have its magnitudes quoted - its ratios still stand.
     */
    mov     word ptr [pd_w], 0
    mov     si, offset msg_time_scale
    call    puts
    mov     eax, [tm_waitp]
    mov     ebx, [tm_ns_p]
    movzx   ecx, word ptr [tm_n]
    test    ecx, ecx
    jz      st_scale_skip
    call    muldiv32                    /* eax = this row's ns per access */
    mov     [tm_scale], eax
    call    putdec32
    mov     si, offset msg_time_scale2
    call    puts
    mov     eax, [tm_scale]
    mov     ebx, 100                    /* as a percentage, so the reader sees */
    mov     ecx, 600                    /* 137 rather than having to divide */
    call    muldiv32
    mov     [tm_scale], eax
    call    putdec32
    mov     si, offset msg_time_scale3
    call    puts
    cmp     dword ptr [tm_scale], 200
    jb      st_scale_ok
    mov     si, offset msg_time_scalefail
    call    puts
st_scale_ok:

    /* The baseline's own spread WITHIN this run. A control row that moves inside
     * one run cannot calibrate anything, and this is the in-run form of the
     * between-run spread the captures showed. 100 means no spread. */
    mov     si, offset msg_time_bspread
    call    puts
    mov     ax, [tm_bcount]
    call    putdec16
    mov     si, offset msg_time_bspread2
    call    puts
    mov     eax, [tm_bmax]
    mov     ebx, 100
    mov     ecx, [tm_bmin]
    test    ecx, ecx
    jz      st_bskip
    test    eax, eax
    jz      st_bskip
    call    muldiv32
    mov     [tm_scale], eax
    call    putdec32
    mov     si, offset msg_time_bspread3
    call    puts
    cmp     dword ptr [tm_scale], 200
    jb      st_bskip
    mov     si, offset msg_time_bsfail
    call    puts
st_bskip:
st_scale_skip:

    /* The raster, then the CPU loop. */
    mov     word ptr [pd_w], 0
    mov     si, offset msg_time_raster
    call    puts
    mov     eax, [tm_rticks]
    call    putdec32
    mov     si, offset msg_time_raster2
    call    puts
    call    tm_raster
    mov     si, offset msg_time_rast5
    call    puts
    mov     eax, [tm_n5]
    call    putdec32
    mov     si, offset msg_time_rast6
    call    puts
    mov     eax, [tm_n6]
    call    putdec32
    mov     si, offset msg_time_rastd
    call    puts
    mov     eax, [tm_epolls]
    call    putdec32
    mov     si, offset msg_time_rastd2
    call    puts

    mov     si, offset msg_time_cpu
    call    puts
    call    tm_cpu
    mov     eax, [tm_cpu_iters]
    call    putdec32
    mov     si, offset msg_time_cpu2
    call    puts
    mov     eax, [tm_cpu_ad]
    call    putdec32
    mov     si, offset msg_time_cpu3
    call    puts

    mov     si, offset msg_end_time
    call    puts
    ret

/* ------------------------------------------------------------------ */
/* section: /TIMEREF                                                  */
/* ------------------------------------------------------------------ */
sec_timeref:
    mov     si, offset msg_begin_timeref
    call    puts
    mov     si, offset msg_timeref_hdr
    call    puts
    mov     byte ptr [tr_used], 1

    /* /TIMEREF can run on its own, and the PIT arithmetic needs the divisor:
     * measure it here when /TIME did not. */
    cmp     word ptr [tm_div], 0
    jne     tr_div_ok
    call    tm_div_probe
tr_div_ok:
    call    tm_div_check

    /* The RTC-independent reference, before the calendar. The machine's
     * uPD4993 calendar does not run, so Timer B is what /TIMEREF falls back to.
     * It is also the reference the DERIVED block uses when the calendar is dead. */
    call    tb_report

    /* The two calendar latches and the tick rate. 0128's read clears a pending
     * tick, which is why it is read here, in an opt-in section, and not in
     * /TIME. */
    mov     dx, 0x0022
    call    read_byte
    push    ax
    mov     si, offset msg_tr_mode
    call    puts
    pop     ax
    call    puthex8
    call    putnl
    mov     dx, 0x0128
    call    read_byte
    push    ax
    mov     si, offset msg_tr_128
    call    puts
    pop     ax
    call    puthex8
    mov     si, offset msg_tr_128b
    call    puts

    /* The first full read, and both decodings of it. */
    mov     si, offset msg_tr_read1
    call    puts
    call    cal_full
    mov     si, offset cal_str
    call    puts
    call    putnl
    xor     di, di
    mov     si, offset cal_fld0
    call    cal_decode
    mov     si, offset cal_fld0
    call    cal_bcd_ok
    mov     [cal_f0ok], al
    mov     di, 4
    mov     si, offset cal_fld4
    call    cal_decode
    mov     si, offset cal_fld4
    call    cal_bcd_ok
    mov     [cal_f4ok], al
    mov     si, offset msg_tr_at0
    call    puts
    mov     si, offset cal_fld0
    call    cal_print_fields
    call    putnl
    mov     si, offset msg_tr_at4
    call    puts
    mov     si, offset cal_fld4
    call    cal_print_fields
    call    putnl

    /* The opt-in TIMESET, which is what makes a machine with a dead battery
     * measurable at all. cal_align stays 0xFF (undecided) unless the pattern
     * read-back names it; the ticking itself then decides. */
    mov     byte ptr [cal_align], 0xFF
    mov     al, [flags4]
    test    al, 0x40            /* FLAG4_TIMESET */
    jz      tr_no_set
    mov     si, offset msg_tr_set
    call    puts
    call    cal_set
    mov     si, offset msg_tr_set2
    call    puts
    call    cal_full
    mov     si, offset cal_str
    call    puts
    call    putnl
    xor     di, di
    mov     si, offset cal_fld0
    call    cal_decode
    mov     di, 4
    mov     si, offset cal_fld4
    call    cal_decode
    mov     si, offset msg_tr_setat0
    call    puts
    mov     si, offset cal_fld0
    call    cal_print_fields
    call    putnl
    mov     si, offset msg_tr_setat4
    call    puts
    mov     si, offset cal_fld4
    call    cal_print_fields
    call    putnl
    call    cal_match_set
    jmp     tr_live
tr_no_set:
    mov     si, offset msg_tr_align_none
    call    puts
tr_live:

    /* Is the calendar running at all? That, and not the value of the fields, is
     * what the reference needs. */
    mov     si, offset msg_tr_live
    call    puts
    call    cal_sync
    jc      tr_dead
    mov     si, offset msg_tr_live_ok
    call    puts
    call    tm_align_report
    mov     si, offset msg_tr_sync
    call    puts
    mov     al, [cal_n0]
    call    puthex8
    call    putsp
    mov     al, [cal_n4]
    call    puthex8
    call    putnl

    /* The window: [cal_secs] calendar seconds, with the PIT sampled between
     * every pair of calendar reads. */
    mov     word ptr [pd_w], 0
    mov     si, offset msg_tr_win
    call    puts
    mov     ax, [cal_secs]
    call    putdec16
    mov     si, offset msg_tr_win2
    call    puts
    call    cal_window
    cmp     byte ptr [cal_tmo], 0
    jnz     tr_dead
    mov     si, offset msg_tr_wline
    call    puts
    mov     ax, [cal_secs]
    call    putdec16
    mov     si, offset msg_tr_wart
    call    puts
    mov     eax, [cal_ticks]
    call    putdec32
    mov     si, offset msg_tr_wrel
    call    puts
    mov     eax, [cal_reloads]
    call    putdec32
    mov     si, offset msg_tr_wcnt
    call    puts
    call    pit_clocks
    mov     [cal_counts], eax
    call    putdec32
    mov     si, offset msg_tr_wdiv
    call    puts
    mov     ax, [tm_div]
    call    putdec16
    call    putnl

    /* The two frequencies, measured against the calendar's second. */
    movzx   ecx, word ptr [cal_secs]
    mov     eax, [cal_counts]
    xor     edx, edx
    div     ecx
    mov     [f_pit], eax
    mov     eax, [cal_ticks]
    xor     edx, edx
    div     ecx
    mov     [f_artic], eax
    mov     eax, 1000000000
    xor     edx, edx
    mov     ebx, [f_pit]
    test    ebx, ebx
    jz      tr_nopit
    div     ebx
    mov     [ns_pit], eax
tr_nopit:
    mov     eax, 1000000000
    xor     edx, edx
    mov     ebx, [f_artic]
    test    ebx, ebx
    jz      tr_noartic
    div     ebx
    mov     [ns_artic], eax
tr_noartic:
    mov     word ptr [pd_w], 0
    mov     si, offset msg_tr_res
    call    puts
    mov     si, offset msg_tr_fpit
    call    puts
    mov     eax, [f_pit]
    mov     word ptr [pd_w], 9
    call    putdec32
    mov     si, offset msg_tr_fpit2
    call    puts
    mov     word ptr [pd_w], 0
    mov     ax, [tm_div]
    call    putdec16
    mov     si, offset msg_tr_fpit3
    call    puts
    mov     si, offset msg_tr_fartic
    call    puts
    mov     eax, [f_artic]
    mov     word ptr [pd_w], 9
    call    putdec32
    mov     si, offset msg_tr_fartic2
    call    puts
    /* the deviation from the documented 307200 Hz, in parts per thousand */
    mov     eax, [f_artic]
    mov     ebx, 1000
    mov     ecx, 307200
    call    muldiv32
    mov     ebx, 1000
    sub     eax, ebx
    mov     word ptr [pd_w], 0
    call    putdecs32
    mov     si, offset msg_tr_fartic3
    call    puts
    mov     si, offset msg_tr_nst
    call    puts
    mov     eax, [ns_artic]
    call    putdec32
    mov     si, offset msg_tr_nst2
    call    puts
    mov     eax, [ns_pit]
    call    putdec32
    mov     si, offset msg_tr_nst3
    call    puts

    /* The ARTIC sanity check: if the rate is nowhere near the documented one,
     * the seconds field being counted may not be a one-second field. */
    mov     eax, [f_artic]
    mov     ebx, 1000
    mov     ecx, 307200
    call    muldiv32
    cmp     eax, 700
    jb      tr_artic_warn
    cmp     eax, 1300
    ja      tr_artic_warn
    jmp     tr_after_warn
tr_artic_warn:
    mov     si, offset msg_tr_warn
    call    puts
tr_after_warn:

tr_derived:
    /* The derived rows, with the measured rates in place of the documented
     * ones. */
    cmp     byte ptr [tm_used], 0
    jz      tr_no_rows
    mov     si, offset msg_tr_der
    call    puts
    mov     word ptr [tm_print], offset tm_derive_row
    mov     eax, [ns_pit]
    mov     [tm_ns_p], eax
    mov     byte ptr [tm_rerun], 0
    call    tm_class_loop
    mov     si, offset msg_tr_ras
    call    puts
    mov     si, offset msg_tr_ras5
    call    puts
    mov     eax, [tm_n5]
    mov     ebx, [f_artic]
    mov     ecx, [tm_ed]
    test    ecx, ecx
    jz      tr_ras5_zero
    call    muldiv32
    jmp     tr_ras5_out
tr_ras5_zero:
    xor     eax, eax
tr_ras5_out:
    mov     word ptr [pd_w], 7
    call    putdec32
    mov     si, offset msg_tr_ras6
    call    puts
    mov     eax, [tm_n6]
    mov     ebx, [f_artic]
    mov     ecx, [tm_ed]
    test    ecx, ecx
    jz      tr_ras6_zero
    call    muldiv32
    jmp     tr_ras6_out
tr_ras6_zero:
    xor     eax, eax
tr_ras6_out:
    mov     word ptr [pd_w], 7
    call    putdec32
    mov     word ptr [pd_w], 0
    mov     si, offset msg_tr_rasend
    call    puts
    mov     si, offset msg_tr_cpu
    call    puts
    mov     eax, [tm_cpu_iters]
    mov     ebx, [f_artic]
    mov     ecx, [tm_cpu_ad]
    test    ecx, ecx
    jz      tr_cpu_zero
    call    muldiv32
    jmp     tr_cpu_out
tr_cpu_zero:
    xor     eax, eax
tr_cpu_out:
    mov     word ptr [pd_w], 10
    call    putdec32
    mov     word ptr [pd_w], 0
    mov     si, offset msg_tr_cpuend
    call    puts
    jmp     tr_notes
tr_no_rows:
    mov     si, offset msg_tr_norows
    call    puts
tr_notes:
    mov     si, offset msg_tr_notes
    call    puts
    mov     si, offset msg_end_timeref
    call    puts
    ret

tr_dead:
    mov     si, offset msg_tr_dead
    call    puts
    /* The calendar is dead, but Timer B above is the fallback: hand its measured
     * rates to the DERIVED block so /TIME's rows still convert into ns. */
    cmp     byte ptr [tb_ok], 0
    je      tr_notes
    mov     si, offset msg_tr_tbfallback
    call    puts
    mov     eax, [tb_fpit]
    mov     [f_pit], eax
    mov     eax, [tb_fartic]
    mov     [f_artic], eax
    mov     eax, [tb_nspit]
    mov     [ns_pit], eax
    mov     eax, [tb_nsartic]
    mov     [ns_artic], eax
    jmp     tr_derived

/* ------------------------------------------------------------------ */
/* section: /RDBACK - write-then-read round-trips for the read-back    */
/* divergences (r13/hwprobe-followups)                                 */
/* ------------------------------------------------------------------ */
/* Each simple port is one rdback_round call: read-before, write marker,
 * read-after, write-before back, re-read-after-restore, then print. The
 * helper does its own cli/sti so DOS is never called inside the latch window,
 * and it restores inline (the global restore table is NOT used here: the
 * re-read is printed as `back=` and is the proof). */
rdback_round:                   /* DX = port, BL = marker */
    push    ax
    push    bx
    push    dx
    mov     [rb2_port], dx
    cli
    in      al, dx
    mov     bh, al              /* before */
    mov     al, bl
    out     dx, al
    in      al, dx
    mov     [rb2_after], al
    mov     al, bh
    out     dx, al              /* restore */
    in      al, dx
    mov     [rb2_back], al
    sti
    mov     si, offset msg_rb2_port
    call    puts
    mov     ax, [rb2_port]
    call    puthex16
    mov     si, offset msg_rb2_before
    call    puts
    mov     al, bh
    call    puthex8
    mov     si, offset msg_rb2_wrote
    call    puts
    mov     al, bl
    call    puthex8
    mov     si, offset msg_rb2_after
    call    puts
    mov     al, [rb2_after]
    call    puthex8
    mov     si, offset msg_rb2_back
    call    puts
    mov     al, [rb2_back]
    call    puthex8
    call    putnl
    pop     dx
    pop     bx
    pop     ax
    ret

/* rb2_19: 0x19 is the uPD71071 clear-byte-pointer port (write-only, stateless). */
rb2_19:
    mov     dx, 0x0019
    in      al, dx
    mov     [rb2_19_before], al
    cli
    mov     al, 0x00
    out     dx, al
    in      al, dx
    mov     [rb2_19_after], al
    sti
    mov     si, offset msg_rb2_19
    call    puts
    mov     al, [rb2_19_before]
    call    puthex8
    mov     si, offset msg_rb2_after
    call    puts
    mov     al, [rb2_19_after]
    call    puthex8
    call    putnl
    ret

/* rb2_29: the DMA bound register's channel-select write-then-read. */
rb2_29:
    mov     dx, 0x0029
    in      al, dx
    mov     [rb2_29_before], al
    cli
    mov     al, 0x04
    out     dx, al
    in      al, dx
    mov     [rb2_29_a], al
    mov     al, 0x08
    out     dx, al
    in      al, dx
    mov     [rb2_29_b], al
    mov     al, 0x0C
    out     dx, al
    in      al, dx
    mov     [rb2_29_c], al
    mov     al, [rb2_29_before]
    out     dx, al
    sti
    mov     si, offset msg_rb2_29
    call    puts
    mov     al, [rb2_29_before]
    call    puthex8
    mov     si, offset msg_rb2_29c
    call    puts
    mov     al, [rb2_29_a]
    call    puthex8
    call    putsp
    mov     al, [rb2_29_b]
    call    puthex8
    call    putsp
    mov     al, [rb2_29_c]
    call    puthex8
    call    putnl
    ret

/* rb2_43d: 0x43D's read-back is a strap (0xFF), so a plain round-trip cannot
 * prove restore. This writes the five candidates the firmware/references use,
 * records the F8000:0000 bank byte each moves, then restores by searching for
 * the value that reproduces the as-found bank byte. Under cli, no DOS call. */
rb2_43d:
    mov     dx, 0x043D
    in      al, dx
    mov     [rb2_43d_before], al
    mov     ax, 0xF800
    mov     es, ax
    mov     al, es:[0]
    mov     [rb2_f8_before], al

    mov     word ptr [rb2_43d_n], 0
    mov     di, offset rb2_43d_res
    mov     si, offset rb2_43d_cands
    cli
rb2_43d_test:
    mov     al, [si]
    cmp     al, 0xFF
    je      rb2_43d_find
    mov     [rb2_43d_cand], al
    mov     dx, 0x043D
    out     dx, al
    call    io_delay
    mov     ax, 0xF800
    mov     es, ax
    mov     al, es:[0]
    mov     [di], al
    inc     di
    mov     al, [rb2_43d_cand]
    mov     [di], al
    inc     di
    inc     word ptr [rb2_43d_n]
    inc     si
    jmp     rb2_43d_test
rb2_43d_find:
    mov     byte ptr [rb2_43d_restored], 0xFF
    mov     si, offset rb2_43d_cands
rb2_43d_scan:
    mov     al, [si]
    cmp     al, 0xFF
    je      rb2_43d_fallback
    mov     dx, 0x043D
    out     dx, al
    call    io_delay
    mov     ax, 0xF800
    mov     es, ax
    mov     al, es:[0]
    cmp     al, [rb2_f8_before]
    jne     rb2_43d_next
    mov     al, [si]
    mov     [rb2_43d_restored], al
    jmp     rb2_43d_done
rb2_43d_next:
    inc     si
    jmp     rb2_43d_scan
rb2_43d_fallback:
    mov     dx, 0x043D
    mov     al, 0x02
    out     dx, al
    call    io_delay
    mov     [rb2_43d_restored], al
rb2_43d_done:
    sti
    mov     si, offset msg_rb2_43d_before
    call    puts
    mov     al, [rb2_43d_before]
    call    puthex8
    mov     si, offset msg_rb2_43d_f8
    call    puts
    mov     al, [rb2_f8_before]
    call    puthex8
    call    putnl
    mov     si, offset msg_rb2_43d_hdr
    call    puts
    mov     cx, [rb2_43d_n]
    mov     di, offset rb2_43d_res
rb2_43d_pr:
    test    cx, cx
    jz      rb2_43d_prdone
    push    cx
    mov     si, offset msg_rb2_43d_wrote
    call    puts
    mov     al, [di+1]
    call    puthex8
    mov     si, offset msg_rb2_43d_f8
    call    puts
    mov     al, [di]
    call    puthex8
    call    putnl
    add     di, 2
    pop     cx
    dec     cx
    jmp     rb2_43d_pr
rb2_43d_prdone:
    mov     si, offset msg_rb2_43d_restored
    call    puts
    mov     al, [rb2_43d_restored]
    call    puthex8
    call    putnl
    ret

/* rb2_lpen_master: GDC master (text GDC) LPEN arm - out 0x62,0xC0, poll 0x60
 * bit 0, pop 0x62 x3. Settles whether the master echoes CSRFORM or the LPEN
 * slots. */
rb2_lpen_master:
    mov     dx, 0x0060
    in      al, dx
    mov     [rb2_m_st0], al
    cli
    mov     dx, 0x0062
    mov     al, 0xC0
    out     dx, al
    mov     cx, 0x8000
rb2_m_poll:
    mov     dx, 0x0060
    in      al, dx
    test    al, 0x01
    jnz     rb2_m_rdy
    loop    rb2_m_poll
rb2_m_rdy:
    mov     [rb2_m_st1], al
    mov     dx, 0x0062
    in      al, dx
    mov     [rb2_m_b0], al
    in      al, dx
    mov     [rb2_m_b1], al
    in      al, dx
    mov     [rb2_m_b2], al
    sti
    mov     si, offset msg_rb2_m_hdr
    call    puts
    mov     al, [rb2_m_st0]
    call    puthex8
    mov     si, offset msg_rb2_m_st1
    call    puts
    mov     al, [rb2_m_st1]
    call    puthex8
    mov     si, offset msg_rb2_m_pops
    call    puts
    mov     al, [rb2_m_b0]
    call    puthex8
    call    putsp
    mov     al, [rb2_m_b1]
    call    puthex8
    call    putsp
    mov     al, [rb2_m_b2]
    call    puthex8
    call    putnl
    ret

/* rb2_lpen_slave: GDC slave (graphics GDC) read-back arms at 0xA0/0xA2. */
rb2_lpen_slave:
    mov     dx, 0x00A0
    in      al, dx
    mov     [rb2_s_st0], al
    cli
    mov     dx, 0x00A2
    mov     al, 0xE0
    out     dx, al
    mov     cx, 0x8000
rb2_s_poll_e0:
    mov     dx, 0x00A0
    in      al, dx
    test    al, 0x01
    jnz     rb2_s_e0rdy
    loop    rb2_s_poll_e0
rb2_s_e0rdy:
    mov     [rb2_s_st1], al
    mov     dx, 0x00A2
    in      al, dx
    mov     [rb2_s_e0b0], al
    in      al, dx
    mov     [rb2_s_e0b1], al
    in      al, dx
    mov     [rb2_s_e0b2], al
    in      al, dx
    mov     [rb2_s_e0b3], al
    in      al, dx
    mov     [rb2_s_e0b4], al
    mov     dx, 0x00A2
    mov     al, 0xC0
    out     dx, al
    mov     cx, 0x8000
rb2_s_poll_c0:
    mov     dx, 0x00A0
    in      al, dx
    test    al, 0x01
    jnz     rb2_s_c0rdy
    loop    rb2_s_poll_c0
rb2_s_c0rdy:
    mov     [rb2_s_st2], al
    mov     dx, 0x00A2
    in      al, dx
    mov     [rb2_s_c0b0], al
    in      al, dx
    mov     [rb2_s_c0b1], al
    in      al, dx
    mov     [rb2_s_c0b2], al
    sti
    mov     si, offset msg_rb2_s_hdr
    call    puts
    mov     al, [rb2_s_st0]
    call    puthex8
    mov     si, offset msg_rb2_s_st1
    call    puts
    mov     al, [rb2_s_st1]
    call    puthex8
    mov     si, offset msg_rb2_s_pops
    call    puts
    mov     al, [rb2_s_e0b0]
    call    puthex8
    call    putsp
    mov     al, [rb2_s_e0b1]
    call    puthex8
    call    putsp
    mov     al, [rb2_s_e0b2]
    call    puthex8
    call    putsp
    mov     al, [rb2_s_e0b3]
    call    puthex8
    call    putsp
    mov     al, [rb2_s_e0b4]
    call    puthex8
    call    putnl
    mov     si, offset msg_rb2_s_st2
    call    puts
    mov     al, [rb2_s_st2]
    call    puthex8
    mov     si, offset msg_rb2_s_pops
    call    puts
    mov     al, [rb2_s_c0b0]
    call    puthex8
    call    putsp
    mov     al, [rb2_s_c0b1]
    call    puthex8
    call    putsp
    mov     al, [rb2_s_c0b2]
    call    puthex8
    call    putnl
    ret

sec_rdback:
    mov     byte ptr [inline_used], 1
    mov     si, offset msg_begin_rdback
    call    puts
    mov     si, offset msg_rdback_hdr
    call    puts

    mov     si, offset msg_rb2_mode
    call    puts
    mov     dx, 0x0068
    in      al, dx
    mov     [rb2_68], al
    mov     dx, 0x006A
    in      al, dx
    mov     [rb2_6a], al
    mov     al, [rb2_68]
    call    puthex8
    call    putsp
    mov     al, [rb2_6a]
    call    puthex8
    call    putnl

    /* Palette: index first so the data bytes are restored onto the original
     * entry. */
    mov     dx, 0x00A8
    mov     bl, 0xAB
    call    rdback_round
    mov     dx, 0x00AA
    mov     bl, 0xFF
    call    rdback_round
    mov     dx, 0x00AC
    mov     bl, 0xFF
    call    rdback_round
    mov     dx, 0x00AE
    mov     bl, 0xFF
    call    rdback_round

    /* GRCG mode register (write a distinctive non-FF byte, read back). */
    mov     dx, 0x007C
    mov     bl, 0x5A
    call    rdback_round

    /* DMA bank registers. */
    mov     dx, 0x0021
    mov     bl, 0xA5
    call    rdback_round
    mov     dx, 0x0023
    mov     bl, 0xA5
    call    rdback_round
    mov     dx, 0x0025
    mov     bl, 0xA5
    call    rdback_round
    mov     dx, 0x0027
    mov     bl, 0xA5
    call    rdback_round
    call    rb2_29
    call    rb2_19

    /* 0x9A8, 0x9A0, 0x610, 0x871E. */
    mov     dx, 0x09A8
    mov     bl, 0x01
    call    rdback_round
    mov     dx, 0x09A0
    mov     bl, 0x0B
    call    rdback_round
    mov     dx, 0x0610
    mov     bl, 0x1A
    call    rdback_round
    mov     dx, 0x871E
    mov     bl, 0x0C
    call    rdback_round

    /* 0x43D window test. */
    call    rb2_43d

    /* The two GDC read-back arms. */
    call    rb2_lpen_master
    call    rb2_lpen_slave

    mov     si, offset msg_end_rdback
    call    puts
    ret

/* ------------------------------------------------------------------ */
/* section: /PIT - the PIT read byte-phase and byte-only count writes  */
/* ------------------------------------------------------------------ */
/* Reuses pit_cal/pit_latch/pit_bytes and tm_div_probe. The only state-changing
 * writes are the control-word + count reprogramming of channel 0.  Gate:
 * the reprogramming tests run ONLY when the coherent-pair scan
 * is confident (tm_divok, the >=50% coherence gate) AND tm_div_check accepts
 * the range - the coherent filter can false-accept two identically-torn words,
 * so a range pass alone must never authorize a write.  And the restore writes
 * the STRAP-DERIVED divisor (work-area 0501 bit 7 -> 0x6000/0x4E00), never the
 * measured one: restoring a torn measurement would leave the DOS tick wrong
 * until reboot. */
sec_pit:
    mov     byte ptr [inline_used], 1
    mov     si, offset msg_begin_pitsec
    call    puts
    mov     si, offset msg_pitsec_hdr
    call    puts

    call    pit_cal
    mov     si, offset msg_pitsec_swap
    call    puts
    mov     al, [pit_swap]
    call    puthex8
    mov     si, offset msg_pitsec_swap2
    call    puts

    /* Experiment 1 (no reprogramming): does a latch reset the read phase?  The
     * raw `in` below MOVES the phase one step - that is what the experiment is
     * for - so everything after it (the divisor scan and the reprogramming
     * tests) must re-measure the byte order: pit_swap describes the phase as it
     * was BEFORE this read, and a word assembled with the wrong order turns a
     * two-count difference between two samples into ~256 counts, which is why
     * the coherent-pair filter then accepts NOTHING (the 2026-09-25 PIT.TXT:
     * `measured channel-0 divisor = 0000` + FAIL, on a machine where the same
     * helper accepted ~100% of its pairs in idelat and ioprobe). */
    cli
    mov     dx, 0x0071
    in      al, dx              /* consume one byte: the phase moves one step */
    call    pit_latch
    call    pit_bytes
    mov     al, [pit_b1]
    mov     [p2_n1_b1], al
    mov     al, [pit_b2]
    mov     [p2_n1_b2], al
    sti
    mov     si, offset msg_pitsec_n1
    call    puts
    mov     al, [p2_n1_b1]
    call    puthex8
    call    putsp
    mov     al, [p2_n1_b2]
    call    puthex8
    call    putnl

    call    pit_cal             /* re-measure for the phase this read left */
    mov     si, offset msg_pitsec_swap3
    call    puts
    mov     al, [pit_swap]
    call    puthex8
    mov     si, offset msg_pitsec_swap2
    call    puts

    /* Measure the divisor; reprogram only on a coherent AND in-range scan. */
    call    tm_div_probe
    call    tm_div_check
    mov     ax, [tm_div]
    mov     [p2_div], ax
    mov     si, offset msg_pitsec_div
    call    puts
    mov     ax, [p2_div]
    call    puthex16
    mov     si, offset msg_pitsec_divacc /* ACC/TRY: the scan's own evidence, so a
                                          * capture distinguishes a torn read from
                                          * the machine's real band */
    call    puts
    mov     ax, [tm_daccept]
    call    puthex16
    mov     si, offset msg_pitsec_divslash
    call    puts
    mov     ax, [tm_dtry]
    call    puthex16
    call    putnl
    cmp     byte ptr [tm_divbad], 0
    je      pitsec_divok
    mov     si, offset msg_divbad_note
    call    puts
    jmp     pitsec_skip
pitsec_divok:
    cmp     byte ptr [tm_divok], 0
    je      pitsec_skip

    /* Experiment 2: a control word (with the same divisor) resets the phase. */
    cli
    mov     dx, 0x0071
    in      al, dx              /* leave the phase at the MSB again */
    mov     dx, 0x0077
    mov     al, 0x36
    out     dx, al
    mov     dx, 0x0071
    mov     ax, [p2_div]
    out     dx, al
    mov     al, ah
    out     dx, al
    in      al, dx              /* first byte after the control word */
    mov     [p2_cw_b1], al
    in      al, dx
    mov     [p2_cw_b2], al
    sti
    mov     si, offset msg_pitsec_cw
    call    puts
    mov     al, [p2_cw_b1]
    call    puthex8
    call    putsp
    mov     al, [p2_cw_b2]
    call    puthex8
    call    putnl

    /* Experiment 3: LSB-only count write. Word mode with
     * 0x1234, then LSB-only control 0x14, write 0x56, latch+read. */
    cli
    mov     dx, 0x0077
    mov     al, 0x36
    out     dx, al
    mov     dx, 0x0071
    mov     al, 0x34
    out     dx, al
    mov     al, 0x12
    out     dx, al
    mov     dx, 0x0077
    mov     al, 0x14
    out     dx, al
    mov     dx, 0x0071
    mov     al, 0x56
    out     dx, al
    call    pit_latch
    call    pit_bytes
    mov     al, [pit_b1]
    mov     [p2_lsb_b1], al
    mov     al, [pit_b2]
    mov     [p2_lsb_b2], al
    sti
    mov     si, offset msg_pitsec_lsb
    call    puts
    mov     al, [p2_lsb_b1]
    call    puthex8
    call    putsp
    mov     al, [p2_lsb_b2]
    call    puthex8
    call    putnl

    /* Experiment 4: MSB-only count write. */
    cli
    mov     dx, 0x0077
    mov     al, 0x36
    out     dx, al
    mov     dx, 0x0071
    mov     al, 0x34
    out     dx, al
    mov     al, 0x12
    out     dx, al
    mov     dx, 0x0077
    mov     al, 0x24
    out     dx, al
    mov     dx, 0x0071
    mov     al, 0x56
    out     dx, al
    call    pit_latch
    call    pit_bytes
    mov     al, [pit_b1]
    mov     [p2_msb_b1], al
    mov     al, [pit_b2]
    mov     [p2_msb_b2], al
    sti
    mov     si, offset msg_pitsec_msb
    call    puts
    mov     al, [p2_msb_b1]
    call    puthex8
    call    putsp
    mov     al, [p2_msb_b2]
    call    puthex8
    call    putnl

    /* Restore channel 0 to the STRAP-DERIVED divisor - never the measured
     * value: work-area 0501 bit 7 selects exactly one of the two
     * documented divisors and cannot tear, while [p2_div] can. */
    mov     ax, 0x6000
    test    byte ptr [wa_buf + 0x101], 0x80
    jz      pitsec_div6000
    mov     ax, 0x4E00
pitsec_div6000:
    mov     [p2_strap], ax
    cli
    mov     dx, 0x0077
    mov     al, 0x36
    out     dx, al
    mov     dx, 0x0071
    mov     ax, [p2_strap]
    out     dx, al
    mov     al, ah
    out     dx, al
    sti
    mov     si, offset msg_pitsec_restored
    call    puts
    mov     ax, [p2_strap]
    call    puthex16
    mov     si, offset msg_pitsec_restored2
    call    puts
    jmp     pitsec_end
pitsec_skip:
    mov     si, offset msg_pitsec_skip
    call    puts
pitsec_end:
    mov     si, offset msg_end_pitsec
    call    puts
    ret

/* ------------------------------------------------------------------ */
/* section: /VSYNC - VSYNC/IRQ2 delivery (and frame drops)            */
/* ------------------------------------------------------------------ */
/* IRQ2 (INT 0Ah) is the CRTC's VSYNC interrupt and the vector OP.COM and
 * CLABLOGO.EXE pace their frames on. The 2026-09-23 run of this
 * section proved nothing: the master IMR read 7D, i.e. bit 2 SET, and bit 2 set
 * means MASKED. 0002 is the master IMR (NP2kai io/pic.c pic_i02; its reset
 * default is 0x7d, pic_o02 unmasks the bits the write CLEARS), so both phases
 * recorded 0 IRQs.
 *
 * This revision clears bit 2 for its window and puts the as-found byte back from
 * a save, so one run answers two questions. The exact form is the one OP.COM's own
 * install stub uses (its disassembly, 0x0333-0x0343:
 * `in al,2` / save / `and al,0xfb` / `out 2,al`, then `out 0x64,al`): 0002 is the
 * master IMR, bit 2 is IRQ2, and the arm port's VALUE is irrelevant - OP.COM
 * writes whatever AL holds, NP2kai's gdc_o64 (io/gdc.c) ignores dat, and this
 * core's arm decode is address-only (pc9821_system.sv gdc_vsync_arm).
 *
 *   - is a VSYNC that arrives while IRQ2 is in service delivered at the
 *     EOI (the 8259A's one-bit IRR latch holds the edge - this core's model,
 *     pc9821_pic.sv `pending = ir_latch & ~imr & ~isr_block`) or NOT delivered at
 *     the EOI? NP2kai does not hold it: its in-service arm is a SIBLING of the imr
 *     test (io/pic.c:254-259, inside `if (!(irq & 8))` at :237, after the imr test
 *     closes at :253), so it fires with IRQ2 masked OR unmasked, clears the latched
 *     CRTV bit and re-arms gdc.vsyncint; its mid-frame screendisp defers a still-
 *     latched request the same way (pccore.c:1633-1636), and the re-armed request
 *     is issued at the NEXT frame's screenvsync (pccore.c:1647-1649). NP2kai
 *     therefore predicts NOT delivered at the EOI, deferred by one frame - not a
 *     hold. Phase C reads irqs_post_eoi AND irqs_next_edge, so it separates that
 *     deferral from an edge that never comes back.
 *   - frame pacing: f_drop, the delivered-IRQ : counted-edge ratio, idle and with the
 *     CPU and the bus busy.
 *
 * Phase C forces the in-service case WITHOUT holding up the poll: the handler
 * counts and re-arms 0064 but sends no EOI, so IRQ2 stays in service (the 8259
 * blocks bit 2 there) while the main loop keeps sampling 0xA0 bit 5 and counting
 * the edges that arrive inside that window; the one EOI sent after them is what
 * releases the pending delivery. The older handler shape (hold the ISR across an
 * edge with a delayed EOI) cannot be counted: the poll is suspended for the whole
 * hold, so the edges either side of it collapse into one polled frame.
 *
 * Writes: master IMR 0002 (through write_byte, so the restore ledger carries it),
 * 0064 (the one-shot VSYNC IRQ arm - stateless, re-armed by each handler while phases
 * A, B and C's window run) and 0000 <- 0x62 (the master specific EOI for level 2 -
 * write-only). 0064's READ-BACK is not state: NP2kai has no read handler for it
 * (io/gdc.c gdci60[2] = NULL) and this core answers the constant 0x1F
 * (pc9821_crtc.sv), so the as-found/after bytes there are printed for the record only -
 * the no-armed-request-at-exit claim rests on phase C's consume step, not on that byte.
 * That step is: vs_rearm is cleared before the release EOI, so the last arm fires inside
 * the window and the extra edge taken before the masked IMR goes back can only consume a
 * request the machine itself kept (its own re-arm would be the only way this section
 * could arm one). The RESTORE footer carries this ledger. */
vs_isr:
    push    ax
    push    dx
    push    ds
    push    cs
    pop     ds
    inc     word ptr [vs_count]
    cmp     byte ptr [vs_rearm], 0
    je      vs_isr_noarm
    mov     dx, 0x0064
    mov     al, 0x00
    out     dx, al              /* re-arm BEFORE the EOI: OP.COM's 0x039A runs before
                                   its chain to the BIOS handler that EOIs */
vs_isr_noarm:
    cmp     byte ptr [vs_noeoi], 0
    jne     vs_isr_done         /* phase C: the main loop owns the EOI */
    mov     dx, 0x0000
    mov     al, 0x62            /* specific EOI, master level 2 */
    out     dx, al
vs_isr_done:
    pop     ds
    pop     dx
    pop     ax
    iret

/* vs_wait_edge: wait for the next rising edge of 0xA0 bit 5 (VSYNC pulse). */
vs_wait_edge:
    push    ax
    push    cx
    push    dx
vs_wait_low:
    mov     dx, 0x00A0
    in      al, dx
    test    al, 0x20
    jnz     vs_wait_low
vs_wait_high:
    mov     dx, 0x00A0
    in      al, dx
    test    al, 0x20
    jz      vs_wait_high
    pop     dx
    pop     cx
    pop     ax
    ret

/* vs_wait_edge_to: vs_wait_edge with a bound. CF clear = the edge was seen inside
 * the bound, CF set = the bound expired first. Only phase C's LAST wait uses it: it
 * sits between the release EOI and the restore, and a hang there would leave INT 0Ah
 * pointing into this program with master IMR bit 2 cleared until the power-cycle.
 * The earlier waits (phases A and B and phase C's window) spin on the plain helper
 * as before: they are not the last thing before a restore.
 *
 * The bound is VS_EDGE_TIMEOUT x 65535 polls: the two half-loops share the outer
 * counter, so a level that never changes exhausts CX, decrements it, and a change either
 * ends the wait or moves to the other half. One poll is one 0xA0 read, and the measured
 * I/O class floor is 600 ns, so the bound cannot expire in under ~150 ms. The machine's
 * frame is 17.7 ms (56.4 Hz at the ITF default raster), so a merely slow raster cannot
 * expire it while a stopped one can. */
vs_wait_edge_to:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     bx, VS_EDGE_TIMEOUT
vset_low:
    mov     cx, 0xFFFF
vset_low_in:
    mov     dx, 0x00A0
    in      al, dx
    test    al, 0x20
    jz      vset_high
    loop    vset_low_in
    dec     bx
    jnz     vset_low
    jmp     vset_expired
vset_high:
    mov     cx, 0xFFFF
vset_high_in:
    mov     dx, 0x00A0
    in      al, dx
    test    al, 0x20
    jnz     vset_seen
    loop    vset_high_in
    dec     bx
    jnz     vset_high
vset_expired:
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    stc
    ret
vset_seen:
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    clc
    ret

/* vs_count_frames: CX = number of VSYNC edges to count -> vs_frames. */
vs_count_frames:
    push    ax
    push    dx
    mov     word ptr [vs_frames], 0
vs_cf_loop:
    call    vs_wait_edge
    inc     word ptr [vs_frames]
    loop    vs_cf_loop
    pop     dx
    pop     ax
    ret

/* vs_arm_sync: arm 0064, wait for one rising edge and let everything that lands
 * before the window land, then zero the delivery count and return with IF set.
 * AX = those pre-window deliveries: 1 is the sync edge itself (the normal value)
 * and 2 is a request the DOS session had already left latched in IRR bit 2 (a
 * driver that armed 0064 with IRQ2 masked), which clearing the mask releases.
 *
 * The sync is what makes a phase's count crisp: the window then starts on a fresh
 * rise with the handler's own re-arm as its only pending source, so a delivery
 * cannot drift in between the arm write and the frame loop (which would show up
 * as an extra IRQ in a phase that had none). With vs_noeoi set, the sync edge is
 * also what puts IRQ2 in service for phase C. */
vs_arm_sync:
    mov     word ptr [vs_count], 0
    mov     dx, 0x0064
    mov     al, 0x00
    out     dx, al              /* arm: any value, the port is a one-shot trigger */
    sti
    call    vs_wait_edge
    call    vs_settle
    cli
    mov     ax, [vs_count]
    mov     word ptr [vs_count], 0
    sti
    ret

/* vs_count_frames_load: as vs_count_frames, with one memory burst per poll, so
 * the delivery count is taken with the CPU and the bus busy (the load phase). */
vs_count_frames_load:
    push    ax
    push    dx
    mov     word ptr [vs_frames], 0
vs_cfl_loop:
    call    vs_wait_edge_load
    inc     word ptr [vs_frames]
    loop    vs_cfl_loop
    pop     dx
    pop     ax
    ret

/* vs_wait_edge_load: vs_wait_edge with vs_load_chunk between polls. One burst is
 * 512 words (~20 us at 33 MHz) against a VSYNC pulse of 8 raster lines (~320 us
 * at 24.83 kHz), so the pulse is still sampled many times per frame: the load
 * cannot itself make the poll miss an edge and turn into a false f_drop. */
vs_wait_edge_load:
    push    ax
    push    dx
vs_wel_low:
    call    vs_load_chunk
    mov     dx, 0x00A0
    in      al, dx
    test    al, 0x20
    jnz     vs_wel_low
vs_wel_high:
    call    vs_load_chunk
    mov     dx, 0x00A0
    in      al, dx
    test    al, 0x20
    jz      vs_wel_high
    pop     dx
    pop     ax
    ret

/* vs_load_chunk: one bounded memory-traffic burst, run inside this program's own
 * PSP block (CS = DS = ES = the .COM's 64 KiB), so the load phase writes no
 * machine latch and no VRAM/TRAM cell. CX is preserved: the frame loop drives
 * it with `loop`. */
vs_load_chunk:
    push    ax
    push    cx
    push    si
    push    di
    push    ds
    push    es
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     si, offset vs_load_src
    mov     di, offset vs_load_dst
    mov     cx, VS_LOAD_WORDS
    cld
    rep     movsw
    pop     es
    pop     ds
    pop     di
    pop     si
    pop     cx
    pop     ax
    ret

/* vs_settle: a bounded pause (~140 us at 33 MHz) with interrupts left as the
 * caller set them. It is long enough for a request the 8259 already holds to be
 * taken as soon as IF is set, and far shorter than a frame (17.7 ms), so no
 * VSYNC edge lands inside it and moves a count by itself. */
vs_settle:
    push    cx
    mov     cx, VS_SETTLE
vs_settle_loop:
    loop    vs_settle_loop
    pop     cx
    ret

sec_vsync:
    mov     si, offset msg_begin_vsyncsec
    call    puts
    mov     si, offset msg_vsyncsec_hdr
    call    puts

    /* As-found: the arm port, the master IMR, the PIC's own read port and the
     * vector. 0000 is the 8259 read port, which answers the IRR while OCW3 has
     * RR/RIS clear (the reset state) and the ISR if a driver set RIS - so the
     * line prints the byte, not a decode of it. 0064 reads a constant (see the
     * header), so that byte is a record of the port answering, not of any state. */
    mov     dx, 0x0064
    in      al, dx
    mov     [vs_64], al
    mov     dx, 0x0002
    in      al, dx
    mov     [vs_imr], al
    mov     dx, 0x0000
    in      al, dx
    mov     [vs_00], al
    xor     ax, ax
    mov     es, ax
    mov     ax, es:[0x0028]
    mov     [vs_old_off], ax
    mov     ax, es:[0x002A]
    mov     [vs_old_seg], ax

    mov     si, offset msg_vsyncsec_af64
    call    puts
    mov     al, [vs_64]
    call    puthex8
    mov     si, offset msg_vsyncsec_afimr
    call    puts
    mov     al, [vs_imr]
    call    puthex8
    mov     al, [vs_imr]
    test    al, 0x04
    jz      vs_bit2_clear
    mov     si, offset msg_vsyncsec_bit2m
    call    puts
    jmp     vs_bit2_done
vs_bit2_clear:
    mov     si, offset msg_vsyncsec_bit2u
    call    puts
vs_bit2_done:
    mov     si, offset msg_vsyncsec_afpic
    call    puts
    mov     al, [vs_00]
    call    puthex8
    mov     si, offset msg_vsyncsec_afv
    call    puts
    mov     ax, [vs_old_seg]
    call    puthex16
    mov     si, offset msg_vsyncsec_colon
    call    puts
    mov     ax, [vs_old_off]
    call    puthex16
    call    putnl

    /* Install the handler and clear master IMR bit 2 (NP2kai pic_o02: the bits
     * a write CLEARS are the ones that become unmasked) for the window. The
     * write goes through write_byte, whose ledger entry carries the as-found
     * byte, so RESTORE's row 0002=7D -> 7D is the restore's proof. */
    cli
    xor     ax, ax
    mov     es, ax
    mov     ax, offset vs_isr
    mov     es:[0x0028], ax
    push    cs
    pop     ax
    mov     es:[0x002A], ax

    mov     dx, 0x0002
    mov     al, [vs_imr]
    and     al, 0xFB            /* bit 2 = 0: IRQ2 (CRTV/VSYNC) unmasked */
    mov     [vs_imr_win], al
    call    write_byte          /* DX = port, AL = value; records the as-found */
    mov     dx, 0x0002
    in      al, dx
    mov     [vs_imr_back], al   /* must equal vs_imr_win: the mask took */

    mov     byte ptr [vs_noeoi], 0
    mov     byte ptr [vs_rearm], 1

    /* Phase A: idle, fast handler (count + re-arm 0064 + EOI). One delivery per
     * polled edge is the 1:1 result; a short count is f_drop at idle. */
    call    vs_arm_sync
    mov     [vs_stale], ax      /* 1 = the sync edge; 2 = a drained latched request */
    mov     cx, VS_FRAMES
    call    vs_count_frames
    cli
    mov     ax, [vs_count]
    mov     [vs_cntA], ax
    mov     ax, [vs_frames]
    mov     [vs_frA], ax

    /* Phase B: the same, with a bounded memory burst between polls. */
    call    vs_arm_sync
    mov     cx, VS_FRAMES
    call    vs_count_frames_load
    cli
    mov     ax, [vs_count]
    mov     [vs_cntB], ax
    mov     ax, [vs_frames]
    mov     [vs_frB], ax

    /* Phase C: the forced edge-during-in-service case. vs_noeoi makes
     * the handler count and re-arm but NOT send an EOI, so the sync edge itself
     * leaves IRQ2 in service. The main loop is not suspended by that (the 8259
     * blocks bit 2 while it is in service - the condition under test), so it
     * keeps polling and counts the edges that arrive inside the window.
     *
     * The release is then measured at two points, because NP2kai does not hold an
     * in-service request for the EOI at all: it re-arms it for the next frame
     * (io/pic.c:254-259 + pccore.c:1647-1649). vs_rearm goes to 0 BEFORE the EOI,
     * so nothing this section writes can arm 0064 again: whatever the next edge
     * delivers can only be a request the machine itself kept from the window.
     *   held:        post = pre+1 and next == post   (the 8259 IRR latched it)
     *   deferred:    post = pre   and next = post+1  (NP2kai's re-arm)
     *   not at all:  post = pre   and next == post   (re-run a 0/0/0 before calling it a
     *                genuine discard: the next-edge count is taken VS_SETTLE (~150 us)
     *                after the polled rise, so a slower deferral would look the same)
     *   both:        post = pre+1 and next = post+1  (delivered at the EOI AND again at
     *                the next edge - report it; no write here can arm 0064 by then)
     * pre > 0 is its own finding: the machine delivers in-service edges with no
     * EOI, one per window edge, so pre = VS_HOLD_EDGES would be no blocking. */
    mov     byte ptr [vs_noeoi], 1
    call    vs_arm_sync
    mov     cx, VS_HOLD_EDGES
    call    vs_count_frames     /* these edges arrive while IRQ2 is in service */
    cli
    mov     ax, [vs_frames]
    mov     [vs_edC], ax
    mov     ax, [vs_count]
    mov     [vs_preC], ax
    mov     byte ptr [vs_rearm], 0  /* from here the handler cannot arm 0064 */
    mov     byte ptr [vs_noeoi], 0  /* the released handler EOIs itself */
    mov     dx, 0x0000
    mov     al, 0x62
    out     dx, al              /* release the in-service condition */
    sti
    call    vs_settle
    cli
    mov     ax, [vs_count]
    mov     [vs_postC], ax

    /* One more edge. A request the window latched and the EOI did not deliver has
     * nowhere else to appear, so this separates NP2kai's one-frame deferral from a
     * request that never comes back. With vs_rearm still 0 it also leaves 0064
     * unarmed, so restoring the masked IMR cannot strand a latched request in the
     * IRR for the rest of the session. Bounded (vs_wait_edge_to): this is the last
     * wait before the restore, so it must not spin forever on a stopped raster. */
    sti
    call    vs_wait_edge_to
    jc      vs_next_expired
    call    vs_settle
    cli
    mov     ax, [vs_count]
    mov     [vs_nextC], ax
    jmp     vs_next_doneC
vs_next_expired:
    cli
    mov     byte ptr [vs_next_to], 1
    mov     ax, [vs_count]
    mov     [vs_nextC], ax
vs_next_doneC:

    /* Restore the vector and the IMR, and read both back. */
    xor     ax, ax
    mov     es, ax
    mov     ax, [vs_old_off]
    mov     es:[0x0028], ax
    mov     ax, [vs_old_seg]
    mov     es:[0x002A], ax
    mov     dx, 0x0002
    mov     al, [vs_imr]
    call    write_byte          /* the ledger's 0002 row proves this went back */
    mov     dx, 0x0002
    in      al, dx
    mov     [vs_imr_final], al
    mov     dx, 0x0000
    in      al, dx
    mov     [vs_00_after], al
    mov     dx, 0x0064
    in      al, dx
    mov     [vs_64_after], al
    xor     ax, ax
    mov     es, ax
    mov     ax, es:[0x0028]
    mov     [vs_new_off], ax
    mov     ax, es:[0x002A]
    mov     [vs_new_seg], ax
    mov     byte ptr [vs_used], 1
    sti

    mov     word ptr [pd_w], 0
    mov     si, offset msg_vsyncsec_win
    call    puts
    mov     al, [vs_imr_win]
    call    puthex8
    mov     si, offset msg_vsyncsec_rb
    call    puts
    mov     al, [vs_imr_back]
    call    puthex8
    mov     al, [vs_imr_win]
    cmp     al, [vs_imr_back]
    jne     vs_win_bad
    mov     si, offset msg_vsyncsec_winok
    call    puts
    jmp     vs_win_done
vs_win_bad:
    mov     si, offset msg_vsyncsec_winbad
    call    puts
vs_win_done:
    mov     si, offset msg_vsyncsec_stale
    call    puts
    mov     ax, [vs_stale]
    call    putdec16
    call    putnl

    mov     si, offset msg_vsyncsec_A
    call    puts
    mov     ax, [vs_frA]
    call    putdec16
    mov     si, offset msg_vsyncsec_irqs
    call    puts
    mov     ax, [vs_cntA]
    call    putdec16
    mov     si, offset msg_vsyncsec_delta
    call    puts
    mov     ax, [vs_cntA]
    sub     ax, [vs_frA]
    call    putsdelta
    call    putnl

    mov     si, offset msg_vsyncsec_B
    call    puts
    mov     ax, [vs_frB]
    call    putdec16
    mov     si, offset msg_vsyncsec_irqs
    call    puts
    mov     ax, [vs_cntB]
    call    putdec16
    mov     si, offset msg_vsyncsec_delta
    call    puts
    mov     ax, [vs_cntB]
    sub     ax, [vs_frB]
    call    putsdelta
    call    putnl

    mov     si, offset msg_vsyncsec_C
    call    puts
    mov     ax, [vs_edC]
    call    putdec16
    mov     si, offset msg_vsyncsec_pre
    call    puts
    mov     ax, [vs_preC]
    call    putdec16
    mov     si, offset msg_vsyncsec_post
    call    puts
    mov     ax, [vs_postC]
    call    putdec16
    mov     si, offset msg_vsyncsec_next
    call    puts
    cmp     byte ptr [vs_next_to], 0
    je      vs_next_pr
    mov     si, offset msg_vsyncsec_timeout
    call    puts
    jmp     vs_next_prdone
vs_next_pr:
    mov     ax, [vs_nextC]
    call    putdec16
vs_next_prdone:
    call    putnl

    mov     si, offset msg_vsyncsec_after
    call    puts
    mov     al, [vs_imr_final]
    call    puthex8
    mov     si, offset msg_vsyncsec_afv
    call    puts
    mov     ax, [vs_new_seg]
    call    puthex16
    mov     si, offset msg_vsyncsec_colon
    call    puts
    mov     ax, [vs_new_off]
    call    puthex16
    mov     si, offset msg_vsyncsec_afpic
    call    puts
    mov     al, [vs_00_after]
    call    puthex8
    mov     si, offset msg_vsyncsec_064
    call    puts
    mov     al, [vs_64_after]
    call    puthex8
    call    putnl

    mov     si, offset msg_vsyncsec_interpret
    call    puts

    mov     si, offset msg_end_vsyncsec
    call    puts
    ret

/* ------------------------------------------------------------------ */
/* section: /WIPE - the C-Lab logo's wipe step, replicated             */
/* ------------------------------------------------------------------ */
/* THE QUESTION. CLABLOGO.EXE's logo runs 99 straight-line wipe steps (CS:0x2C0,
 * called from the loop at 0x4A1-0x4C4). The steps have NO gate at all: the step
 * body and all four callees contain zero device reads (from the disassembly), yet the run's un-synchronised
 * T_draw exceeds every priced term on BOTH machines (machine 2.04 s derived vs
 * 0.20-0.38 s priced; core 1.09 s derived vs 0.30-0.47 s priced). The step's own
 * walk replays at 22,508 clk_sys = 450 us on the core (a bench replay of the
 * step), so the core is not walk-bound. This section measures the
 * missing machine-side terms in the game's own 640x400 16-colour mode, so one
 * machine trip prices the step.
 *
 * WHAT IT REPLICATES (from the disassembly; every deviation is listed below):
 *   per step: GRCG RMW on (0x7C=0xC0), one tile load (4x out 0x7E), a rep stosw
 *   fill of 4000 words of 0xFFFF at 0xA800:0x2EE0, then 100 rows each with the row
 *   body's arithmetic (imul ax,0xff, a 16-bit idiv with a memory operand, a 32-bit
 *   multiply chain, the Turbo Pascal 33-iteration shift-subtract divide), a
 *   per-row tile load, and a rep movsw of 20 words from a DS buffer into the GVRAM
 *   row; then GRCG off (0x7C=0), the page-pair swap, and out 0xA4 + out 0xA6.
 *   Per step: 6000 GVRAM word stores, 408 I/O writes, 100 tile loads. x99 =
 *   594k stores / 40,392 writes.
 *
 * DEVIATIONS from the game's image (deliberate, and stated rather than hidden):
 *   - the row body's operands are safe constants: the divisor is the constant
 *     [wp_div] = 0xC4 and the index is masked with 0x7F. The mask is a NO-OP for
 *     the game's 0..99 row index; it exists because W1 reuses the same body with a
 *     larger counter, where an unmasked imul would make the idiv overflow and #DE
 *     the machine. The game's divisor is [bp+6] = (0x63-i)*2, a per-row value.
 *   - the 32-bit helpers are OUR code in the helper's instruction SHAPE (three
 *     mul-adds; a 33-iteration rcl/cmc shift-subtract divide), not the game's
 *     image: its far calls 0x51:0x4DC/0x4F7 cannot be reproduced without it.
 *   - the tile datum is the constant 0xFF (the game lodsb's it from its own table).
 *   - the blit rows sit at 0x2EE0 + row*80; the game's exact target arithmetic
 *     (imul di,ax,0xfa0 / imul di,ax,0x50) is not reproduced. The access count,
 *     the 20-word shape and the 80-byte row stride are; every address stays inside
 *     the 0xA8000 window.
 *   - the page pair starts at 0xA4=0 / 0xA6=1 (a double buffer, as the game runs
 *     one); the value the game's own init left is its business.
 *   - our step is bracketed by our own ARTIC reads (2 per phase, ~5 us of bracket
 *     bias per phase, ~2.5 us per phase boundary): the game has none.
 *   - the game's DS table lookup (mov al,[di+0x3c6c]) becomes a DS table read of
 *     the same class (one byte from a 256-byte table in this program's PSP block).
 *
 * THE EXPERIMENTS (each prints its hypothesis as a HYP row):
 *   W1  the CPU term, MEASURED instead of derived (the report's section 5.5 called
 *       this its only soft number): a known-instruction-mix loop and the row body
 *       itself, ns/iteration. Run in text mode AND in the game's graphics mode, so
 *       the instruction-fetch side of display contention shows up too.
 *   W2  THE STEP REPLAY: 10 steps in the game's mode, display ON, each phase (fill /
 *       100-row loop / GRCG-off+flip) bracketed AND the whole step. First step vs
 *       steady state, in ARTIC ticks, against the core's 22,508 clk_sys/step.
 *   W3  DISPLAY CONTENTION: the same arm with the display blanked (0x68 bit 7, MODE
 *       FF1's DISP - a readable latch) and then enabled again as a drift control.
 *       The blanked-vs-enabled difference IS the display's GVRAM fetch contention,
 *       which the core's arbiter does not model (its own policy is not the
 *       machine's).
 *   W4  INTERRUPT COST: the same arm with IF=0; with IF=1 and the as-found IMR (the
 *       machine's normal state - IMR 7D masks IRQ2); and with IRQ2 unmasked and a
 *       counting ISR installed. The item-11 discipline: master IMR and INT 0Ah
 *       saved, restored from the save and read back, the last 0x64 arm consumed.
 *       The IRQ count says how many VSYNC deliveries landed inside the arms.
 *   W5  THE RASTER PERIOD during the logo: the 0xA0 bit-5 VSYNC edge period over 64
 *       frames in the game's mode, plus every 0xA0 bit-6 rising edge in the same
 *       window (the blanking flag) - so the line count, and therefore the implied
 *       vertical total, is measured and not assumed. A y=525 raster makes the
 *       logo's 281 edges 5.94 s instead of 4.98 s: the entire defect.
 *   W6  THE BIOS MODE-SET TIMELINE: ARTIC stamps on the game's own AH=41h/42h/40h +
 *       0x6A mode sequence and on the restore pair. The 0x5F write is 1621 ns on
 *       the machine vs 600 ns in the core, so this is the largest priced non-wipe
 *       term.
 *
 * SAFETY. Every latch it writes is saved first and restored from the save, with an
 * as-found -> read-back row in the RESTORE line and in the global ledger: 0x68
 * (the blank arm), 0x6A (analog 16-colour), 0x7C (GRCG mode; left OFF), and master
 * IMR 0x0002 (W4C, written through write_byte so the footer carries the row). INT
 * 0Ah is saved, restored and read back. The video mode is restored with the BIOS's
 * own AH=41h + AH=0Ch pair. 0xA4/0xA6 are left at 0 by the
 * graphics-probe convention (as gfxbenc2 does): their as-found bytes are
 * printed, but they are not state this probe claims to restore. The disk is never
 * touched; the only memory written is GVRAM (by design, scribbled), the GRCG tile
 * registers (left loaded, inert with 0x7C=0 - the game leaves them loaded too) and
 * this program's own PSP block. Every timed window is `cli`, so no DOS call sits
 * inside one, EXCEPT W4's live arms - which are the measurement. RUN IT REDIRECTED:
 * the console is in graphics mode for most of the section.
 *
 * CORE-SIDE COMPARISON (what wipe_decode.py diffs against):
 *   step, walk only     22,508 clk_sys = 450.16 us, 16,400 array accesses
 *   fill 11,999 clk = 240.0 us; blit 9,997 clk = 199.9 us; I/O 1,624 clk = 32.5 us
 *   frame period 5445 ARTIC ticks = 17.7232 ms / 440 lines (FLIP.TXT, same mode)
 *   CPU term per run: 9900 row bodies, derived ~740 clk/row (machine) / ~890
 *   clk_sys/row (core) before this probe runs.
 */
sec_wipe:
    mov     byte ptr [wp_used], 1
    mov     byte ptr [inline_used], 1
    mov     si, offset msg_begin_wipe
    call    puts
    mov     si, offset msg_w_intro
    call    puts
    mov     si, offset msg_w_hyp1
    call    puts
    mov     si, offset msg_w_hyp2
    call    puts
    mov     si, offset msg_w_hyp3
    call    puts
    mov     si, offset msg_w_hyp4
    call    puts
    mov     si, offset msg_w_hyp5
    call    puts
    mov     si, offset msg_w_hyp6
    call    puts
    mov     si, offset msg_w_anchor
    call    puts
    mov     word ptr [pd_w], 0

    /* as-found reads, before any write of this section (the first-touch rule) */
    call    wp_snap

    /* W1: the CPU term, in text mode (the CPU-side calibration) */
    call    wp_w1

    /* W6 + the mode set the game itself uses (AH=41h/42h/40h + 0x6A) */
    call    wp_modeset

    /* W1 again: the row body in the game's graphics mode (display ON), so the
     * instruction-fetch side of display contention is measured separately from the
     * GVRAM side W3 isolates. */
    call    wp_w1b

    /* W5: the raster period in the game's own mode, display ON */
    call    wp_w5

    /* W2: the step replay, display ON (the game's condition) */
    mov     byte ptr [wp_irq_on], 0
    mov     word ptr [wp_arm_id], WP_ARM_W2
    mov     word ptr [wp_mode_id], WP_MODE_DISPON
    call    wp_run_arm

    /* W3: the same arm with the display blanked (MODE FF1 DISP cleared) */
    call    wp_disp_blank
    mov     word ptr [wp_arm_id], WP_ARM_W3
    mov     word ptr [wp_mode_id], WP_MODE_BLANK
    call    wp_run_arm
    call    wp_disp_restore

    /* W3B: display ON again - the drift control for W2 vs W3 */
    mov     word ptr [wp_arm_id], WP_ARM_W3B
    mov     word ptr [wp_mode_id], WP_MODE_DISPON2
    call    wp_run_arm

    /* W4A: IF=0 (every interrupt masked, IF as a DOS prompt never leaves it) */
    mov     word ptr [wp_arm_id], WP_ARM_W4A
    mov     word ptr [wp_mode_id], WP_MODE_IRQMASK
    call    wp_run_arm

    /* W4B: IF=1 with the as-found IMR - the machine's normal state */
    sti
    mov     byte ptr [wp_irq_on], 1
    mov     word ptr [wp_arm_id], WP_ARM_W4B
    mov     word ptr [wp_mode_id], WP_MODE_IRQNORM
    call    wp_run_arm

    /* W4C: IRQ2 unmasked, a counting ISR installed (the forced condition) */
    call    wp_irq_begin
    cmp     byte ptr [wp_irq_bad], 0
    jne     wp_w4c_done
    mov     word ptr [wp_arm_id], WP_ARM_W4C
    mov     word ptr [wp_mode_id], WP_MODE_IRQ2
    call    wp_run_arm
    call    wp_irq_end
wp_w4c_done:
    mov     byte ptr [wp_irq_on], 0

    /* restore the mode (W6's restore rows) and every latch, and report */
    call    wp_unmodeset
    call    wp_restore

    mov     si, offset msg_end_wipe
    call    puts
    ret

/* ------------------------------------------------------------------ */
/* /WIPE helpers                                                       */
/* ------------------------------------------------------------------ */

/* wp_snap: the as-found bytes, read before anything is written, and printed. */
wp_snap:
    mov     dx, 0x0068
    in      al, dx
    mov     [wp_68_was], al
    mov     dx, 0x006A
    in      al, dx
    mov     [wp_6a_was], al
    mov     dx, 0x007C
    in      al, dx
    mov     [wp_7c_was], al
    mov     dx, 0x00A4
    in      al, dx
    mov     [wp_a4_was], al
    mov     dx, 0x00A6
    in      al, dx
    mov     [wp_a6_was], al
    mov     dx, 0x0002
    in      al, dx
    mov     [wp_imr_was], al
    xor     ax, ax
    mov     es, ax
    mov     ax, es:[0x0028]
    mov     [wp_old_off], ax
    mov     ax, es:[0x002A]
    mov     [wp_old_seg], ax

    mov     si, offset msg_w_asfound
    call    puts
    mov     dx, 0x0068
    mov     al, [wp_68_was]
    call    putport
    call    putsp
    mov     dx, 0x006A
    mov     al, [wp_6a_was]
    call    putport
    call    putsp
    mov     dx, 0x007C
    mov     al, [wp_7c_was]
    call    putport
    call    putsp
    mov     dx, 0x00A4
    mov     al, [wp_a4_was]
    call    putport
    call    putsp
    mov     dx, 0x00A6
    mov     al, [wp_a6_was]
    call    putport
    call    putsp
    mov     dx, 0x0002
    mov     al, [wp_imr_was]
    call    putport
    call    putnl
    ret

/* wp_w1: the text-mode CPU calibration.
 *   W1 MIX=alu: 4 ALU ops + dec + jnz per iteration (a 6-instruction body), so the
 *   machine's raw instruction rate is measured with no memory or I/O in the loop.
 *   W1 MIX=rowbody: the step's own row body (wp_row_arith), run 9900 times = the
 *   count 99 steps of 100 rows need, so the CPU part of the wipe is measured. */
wp_w1:
    cli
    call    artic_read
    mov     [wp_t0], eax
    mov     word ptr [wp_i], WIPE_ALU_OUTER
w1a_outer:
    mov     cx, WIPE_ALU_INNER
w1a_inner:
    add     al, 1
    add     bl, 1
    add     ah, 1
    add     bh, 1
    dec     cx
    jnz     w1a_inner
    dec     word ptr [wp_i]
    jnz     w1a_outer
    call    artic_read
    mov     [wp_t1], eax
    sti
    mov     si, offset msg_w_w1
    call    puts
    mov     si, offset msg_w_mixalu
    call    puts
    mov     si, offset msg_w_w1a
    call    puts
    mov     si, offset msg_w_iters
    call    puts
    mov     eax, WIPE_ALU_OUTER * WIPE_ALU_INNER
    mov     word ptr [pd_w], 0
    call    putdec32
    mov     si, offset msg_w_artic
    call    puts
    mov     eax, [wp_t1]
    sub     eax, [wp_t0]
    call    putdec32
    call    putnl

    cli
    call    artic_read
    mov     [wp_t0], eax
    mov     word ptr [wp_i], WIPE_W1_ROWS
w1b_loop:
    mov     ax, [wp_i]
    call    wp_row_arith
    dec     word ptr [wp_i]
    jnz     w1b_loop
    call    artic_read
    mov     [wp_t1], eax
    sti
    mov     si, offset msg_w_w1
    call    puts
    mov     si, offset msg_w_mixrow
    call    puts
    mov     si, offset msg_w_iters
    call    puts
    mov     eax, WIPE_W1_ROWS
    mov     word ptr [pd_w], 0
    call    putdec32
    mov     si, offset msg_w_artic
    call    puts
    mov     eax, [wp_t1]
    sub     eax, [wp_t0]
    call    putdec32
    call    putnl
    ret

/* wp_w1b: the row-body mix again, now in the game's graphics mode with the display
 * ON. Compared with W1 MIX=rowbody it isolates the instruction-fetch half of
 * display contention (W3 isolates the GVRAM half). */
wp_w1b:
    cli
    call    artic_read
    mov     [wp_t0], eax
    mov     word ptr [wp_i], WIPE_W1_ROWS
w1c_loop:
    mov     ax, [wp_i]
    call    wp_row_arith
    dec     word ptr [wp_i]
    jnz     w1c_loop
    call    artic_read
    mov     [wp_t1], eax
    sti
    mov     si, offset msg_w_w1
    call    puts
    mov     si, offset msg_w_mixrowg
    call    puts
    mov     si, offset msg_w_iters
    call    puts
    mov     eax, WIPE_W1_ROWS
    mov     word ptr [pd_w], 0
    call    putdec32
    mov     si, offset msg_w_artic
    call    puts
    mov     eax, [wp_t1]
    sub     eax, [wp_t0]
    call    putdec32
    call    putnl
    ret

/* wp_row_arith: the step's row body, in AX = the row index. Clobbers ax,bx,cx,dx,si,di.
 * The replay's row loop and W1's calibration call the SAME routine, so W1 measures the
 * replay's own CPU work and not a proxy. */
wp_row_arith:
    and     ax, WIPE_ARITH_MASK     /* a no-op for the game's 0..99 index (see header) */
    imul    ax, 0xFF                /* the game's imul ax,[bp-4],0xff */
    cwd
    idiv    word ptr [wp_div]       /* the game's 16-bit idiv with a MEMORY operand */
    mov     bl, al
    mov     al, [wp_tab+bx]         /* the game's DS table lookup, same access class */
    mov     ah, 0
    mov     bx, 0x2E1F              /* the 32-bit multiply helper's shape: three muls */
    mul     bx
    mov     cx, ax
    mov     si, dx
    mov     ax, cx
    mov     bx, 0x0101
    mul     bx
    add     ax, cx
    adc     dx, si
    mov     [wp_acc], ax
    mov     [wp_acc+2], dx
    call    wp_div32                /* the Pascal 32-bit divide helper's shape */
    ret

/* wp_div32: the Turbo Pascal 32-bit divide helper (0xA07) in shape: 33 iterations of
 * rcl / sub / sbb / jae / add / adc / cmc / rcl, on the 32-bit value in [wp_acc] with a
 * fixed divisor. Deviations: constants instead of the helper's operands, no sign
 * fixups, DI instead of BP as the counter - all instruction-count-neutral. */
wp_div32:
    push    ax
    push    cx
    push    dx
    push    si
    push    di
    mov     ax, [wp_acc]
    mov     dx, [wp_acc+2]
    mov     bx, 0xFFFF
    xor     cx, cx
    xor     si, si
    mov     di, 33
wd_loop:
    rcl     ax, 1
    rcl     dx, 1
    rcl     cx, 1
    rcl     si, 1
    sub     cx, bx
    sbb     si, 0
    jae     wd_keep
    add     cx, bx
    adc     si, 0
    cmc
wd_keep:
    rcl     ax, 1
    rcl     dx, 1
    dec     di
    jne     wd_loop
    mov     [wp_acc], ax
    mov     [wp_acc+2], dx
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     ax
    ret

/* wp_stamp_now: SI = a label. Reads ARTIC, prints the ARTIC delta since the previous
 * stamp (`WIPE W6 CALL=<label> ARTIC=<n>`) and makes this read the next base. */
wp_stamp_now:
    push    eax
    push    ebx
    call    artic_read
    mov     ebx, eax
    sub     eax, [wp_t0]
    mov     [wp_t0], ebx
    call    wp_stamp
    pop     ebx
    pop     eax
    ret

/* wp_stamp: SI = a label, EAX = the ARTIC ticks a call took. Prints
 * `WIPE W6 CALL=<label> ARTIC=<n>`. */
wp_stamp:
    push    eax
    push    si
    mov     si, offset msg_w_w6
    call    puts
    pop     si
    call    puts
    mov     si, offset msg_w_artic
    call    puts
    mov     word ptr [pd_w], 0
    call    putdec32
    call    putnl
    pop     eax
    ret

/* wp_modeset: the mode set the game itself issues - INT 18h AH=41h (graphics display
 * off), AH=42h CH=0xC0 (640x400, first page), the FF2 num 0 write (0x6A = 1, analog
 * 16-colour) and AH=40h (graphics display on) - each ARTIC-stamped (W6). The caller
 * keeps IF enabled: the BIOS handlers wait on VSYNC. */
wp_modeset:
    call    artic_read
    mov     [wp_t0], eax
    mov     ax, 0x4100
    int     0x18
    mov     si, offset s_w6_41
    call    wp_stamp_now
    mov     ax, 0x4200
    mov     ch, 0xC0
    int     0x18
    mov     si, offset s_w6_42
    call    wp_stamp_now
    mov     dx, 0x006A
    mov     al, 1
    out     dx, al
    mov     si, offset s_w6_6a
    call    wp_stamp_now
    mov     ax, 0x4000
    int     0x18
    mov     si, offset s_w6_40
    call    wp_stamp_now
    /* the page pair the step flips: display page 0, access page 1 (a double buffer) */
    mov     dx, 0x00A4
    xor     al, al
    out     dx, al
    mov     dx, 0x00A6
    mov     al, 1
    out     dx, al
    mov     word ptr [wp_pg_a4], 0
    mov     word ptr [wp_pg_a6], 1
    /* the post-mode-set MODE FF1 byte, so the blank arm can clear DISP from the value
     * the mode set actually left (the as-found byte is the text-mode 0x18) */
    mov     dx, 0x0068
    in      al, dx
    mov     [wp_68_mode], al
    ret

/* wp_unmodeset: the game's own return to the text screen (W6 restore rows). */
wp_unmodeset:
    call    artic_read
    mov     [wp_t0], eax
    mov     ax, 0x4100
    int     0x18
    mov     si, offset s_w6_41r
    call    wp_stamp_now
    mov     ax, 0x0C00
    int     0x18
    mov     si, offset s_w6_0cr
    call    wp_stamp_now
    ret

/* wp_disp_blank / wp_disp_restore: W3's display blank, MODE FF1 bit 7 (DISP) cleared,
 * restored from the byte the mode set left - each with its own read-back row. */
wp_disp_blank:
    mov     dx, 0x0068
    mov     al, [wp_68_mode]
    and     al, 0x7F
    mov     [wp_68_blank], al
    out     dx, al
    mov     si, offset msg_w_w3blk
    call    puts
    mov     dx, 0x0068
    mov     al, [wp_68_mode]
    call    putport
    mov     si, offset msg_w_blankarrow
    call    puts
    mov     al, [wp_68_blank]
    call    puthex8
    mov     si, offset msg_w_readback
    call    puts
    mov     dx, 0x0068
    in      al, dx
    call    puthex8
    call    putnl
    ret

wp_disp_restore:
    mov     dx, 0x0068
    mov     al, [wp_68_mode]
    out     dx, al
    mov     si, offset msg_w_w3unblk
    call    puts
    mov     dx, 0x0068
    mov     al, [wp_68_blank]
    call    putport
    mov     si, offset msg_w_blankarrow
    call    puts
    mov     al, [wp_68_mode]
    call    puthex8
    mov     si, offset msg_w_readback
    call    puts
    mov     dx, 0x0068
    in      al, dx
    call    puthex8
    call    putnl
    ret

/* wp_w5: the raster period in the game's mode. Counts WIPE_RASTER_FRAMES 0xA0 bit-5
 * rising edges and every bit-6 rising edge (the blanking flag) in the same window,
 * ARTIC-bracketed, so the line count comes out of the capture. IF stays enabled (it is
 * a poll loop with a DOS-free body); the poll body is one port read, ~845 ns, far
 * shorter than the VSYNC pulse (8 lines, ~320 us) or the blank interval it counts. */
wp_w5:
    mov     dword ptr [wp_lines], 0
    mov     word ptr [wp_frames], 0
    mov     dx, 0x00A0
    in      al, dx
    mov     [wp_stat_prev], al
    call    artic_read
    mov     [wp_t0], eax
w5_loop:
    mov     dx, 0x00A0
    in      al, dx
    mov     bl, al
    mov     ah, [wp_stat_prev]
    test    ah, 0x20
    jnz     w5_no_vs
    test    bl, 0x20
    jz      w5_no_vs
    inc     word ptr [wp_frames]
w5_no_vs:
    test    ah, 0x40
    jnz     w5_no_ln
    test    bl, 0x40
    jz      w5_no_ln
    inc     dword ptr [wp_lines]
w5_no_ln:
    mov     [wp_stat_prev], bl
    cmp     word ptr [wp_frames], WIPE_RASTER_FRAMES
    jb      w5_loop
    call    artic_read
    mov     [wp_t1], eax
    mov     si, offset msg_w_w5
    call    puts
    mov     si, offset msg_w_frames
    call    puts
    mov     ax, [wp_frames]
    mov     word ptr [pd_w], 0
    call    putdec16
    mov     si, offset msg_w_lines
    call    puts
    mov     eax, [wp_lines]
    call    putdec32
    mov     si, offset msg_w_artic
    call    puts
    mov     eax, [wp_t1]
    sub     eax, [wp_t0]
    call    putdec32
    call    putnl
    ret

/* wp_run_arm: WIPE_STEPS steps of the replica, one printed row per step, each phase
 * and the whole step bracketed. wp_irq_on = 1 leaves IF as it found it (W4's live
 * arms); otherwise the whole window is `cli` so no DOS call can sit inside it. */
wp_run_arm:
    mov     word ptr [wp_i], 0
wra_loop:
    mov     ax, [wp_i]
    mov     [wp_idx], ax
    cmp     byte ptr [wp_irq_on], 0
    jne     wra_live
    cli
wra_live:
    call    artic_read
    mov     [wp_t0], eax
    call    wipe_p_fill
    call    artic_read
    mov     [wp_t1], eax
    call    wipe_p_rows
    call    artic_read
    mov     [wp_t2], eax
    call    wipe_p_tail
    call    artic_read
    mov     [wp_t3], eax
    cmp     byte ptr [wp_irq_on], 0
    jne     wra_nosti
    sti
wra_nosti:
    mov     eax, [wp_t1]
    sub     eax, [wp_t0]
    mov     [wp_d_fill], eax
    mov     eax, [wp_t2]
    sub     eax, [wp_t1]
    mov     [wp_d_rows], eax
    mov     eax, [wp_t3]
    sub     eax, [wp_t2]
    mov     [wp_d_flip], eax
    mov     eax, [wp_t3]
    sub     eax, [wp_t0]
    mov     [wp_d_tot], eax
    call    wp_print_step
    inc     word ptr [wp_i]
    cmp     word ptr [wp_i], WIPE_STEPS
    jb      wra_loop
    ret

wp_print_step:
    mov     si, offset msg_w_step
    call    puts
    mov     ax, [wp_arm_id]
    shl     ax, 1
    mov     bx, ax
    mov     si, [wp_arm_tab+bx]
    call    puts
    mov     si, offset msg_w_mode
    call    puts
    mov     ax, [wp_mode_id]
    shl     ax, 1
    mov     bx, ax
    mov     si, [wp_mode_tab+bx]
    call    puts
    mov     word ptr [pd_w], 0
    mov     si, offset msg_w_idx
    call    puts
    mov     ax, [wp_idx]
    call    putdec16
    mov     si, offset msg_w_fill
    call    puts
    mov     eax, [wp_d_fill]
    call    putdec32
    mov     si, offset msg_w_rows
    call    puts
    mov     eax, [wp_d_rows]
    call    putdec32
    mov     si, offset msg_w_flip
    call    puts
    mov     eax, [wp_d_flip]
    call    putdec32
    mov     si, offset msg_w_total
    call    puts
    mov     eax, [wp_d_tot]
    call    putdec32
    call    putnl
    ret

/* wipe_p_fill: the step's first phase (the game's 0x2C4-0x2E1): GRCG RMW on, one tile
 * load, the 4000-word 0xFFFF fill at 0xA800:0x2EE0. */
wipe_p_fill:
    push    ax
    push    cx
    push    di
    push    es
    mov     dx, 0x007C
    mov     al, 0xC0
    out     dx, al
    call    wipe_tile_load
    mov     ax, 0xA800
    mov     es, ax
    mov     di, WIPE_BLIT_BASE
    mov     ax, 0xFFFF
    mov     cx, WIPE_FILL_WORDS
    cld
    rep stosw
    pop     es
    pop     di
    pop     cx
    pop     ax
    ret

/* wipe_tile_load: the game's call 0x5C - four out 0x7E writes (its lodsb loop's shape
 * with a constant datum). Called once per step AND once per row, as the game does. */
wipe_tile_load:
    push    ax
    push    dx
    mov     dx, 0x007E
    mov     al, [wp_tile+0]
    out     dx, al
    mov     al, [wp_tile+1]
    out     dx, al
    mov     al, [wp_tile+2]
    out     dx, al
    mov     al, [wp_tile+3]
    out     dx, al
    pop     dx
    pop     ax
    ret

/* wipe_p_rows: the step's second phase (the game's 0x2E9-0x376): 100 rows of the row
 * body's arithmetic, a per-row tile load, and a 20-word rep movsw into the GVRAM row. */
wipe_p_rows:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    bp
    mov     word ptr [wp_r], 0
wpr_loop:
    mov     ax, [wp_r]
    call    wp_row_arith
    call    wipe_tile_load
    call    wipe_blit_row
    inc     word ptr [wp_r]
    cmp     word ptr [wp_r], WIPE_ROWS
    jb      wpr_loop
    pop     bp
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

wipe_blit_row:
    push    ax
    push    bx
    push    cx
    push    si
    push    di
    push    es
    mov     ax, [wp_r]
    mov     bx, WIPE_ROW_STRIDE
    mul     bx
    add     ax, WIPE_BLIT_BASE
    mov     di, ax
    mov     ax, 0xA800
    mov     es, ax
    mov     si, offset wp_src
    mov     cx, WIPE_BLIT_WORDS
    cld
    rep movsw
    pop     es
    pop     di
    pop     si
    pop     cx
    pop     bx
    pop     ax
    ret

/* wipe_p_tail: the step's third phase (the game's 0x37F-0x39E): GRCG off, the page-pair
 * swap, then call 0x15's two writes (0xA4 display page, then 0xA6 access page). */
wipe_p_tail:
    push    ax
    push    dx
    mov     dx, 0x007C
    xor     al, al
    out     dx, al
    mov     al, [wp_pg_a4]
    xchg    al, [wp_pg_a6]
    mov     [wp_pg_a4], al
    mov     dx, 0x00A4
    mov     al, [wp_pg_a4]
    out     dx, al
    mov     dx, 0x00A6
    mov     al, [wp_pg_a6]
    out     dx, al
    pop     dx
    pop     ax
    ret

/* wp_isr: the W4C handler: count the delivery, re-arm 0x64 while wp_rearm is set, EOI
 * unless wp_noeoi says the main loop owns the EOI (the /VSYNC discipline). No DOS call
 * and no memory outside this program's PSP block. */
wp_isr:
    push    ax
    push    dx
    push    ds
    push    cs
    pop     ds
    inc     dword ptr [wp_irqs]
    cmp     byte ptr [wp_rearm], 0
    je      wp_isr_noarm
    mov     dx, 0x0064
    xor     al, al
    out     dx, al
wp_isr_noarm:
    cmp     byte ptr [wp_noeoi], 0
    jne     wp_isr_done
    mov     dx, 0x0000
    mov     al, 0x62
    out     dx, al
wp_isr_done:
    pop     ds
    pop     dx
    pop     ax
    iret

/* wp_irq_begin: save the INT 0Ah vector, install wp_isr, clear master IMR bit 2 (IRQ2
 * unmasked - bits a write CLEARS are the ones that become unmasked), then arm 0x64 and
 * take one sync edge so the count window starts on a fresh rise. The IMR write goes
 * through write_byte, so the global ledger carries `0002 = as-found -> as-found`. */
wp_irq_begin:
    cli
    xor     ax, ax
    mov     es, ax
    mov     ax, offset wp_isr
    mov     es:[0x0028], ax
    push    cs
    pop     ax
    mov     es:[0x002A], ax
    mov     byte ptr [wp_rearm], 1
    mov     byte ptr [wp_noeoi], 0
    mov     dword ptr [wp_irqs], 0
    mov     dx, 0x0002
    mov     al, [wp_imr_was]
    and     al, 0xFB
    mov     [wp_imr_win], al
    call    write_byte
    mov     dx, 0x0002
    in      al, dx
    mov     [wp_imr_back], al
    mov     dx, 0x0064
    xor     al, al
    out     dx, al              /* arm the one-shot before the sync edge */
    sti
    /* The DOS calls (the IMR row) sit OUTSIDE the cli: a cli window in this
     * program never contains an INT 21h. The row's values are already latched. */
    mov     si, offset msg_w_w4imr
    call    puts
    mov     dx, 0x0002
    mov     al, [wp_imr_was]
    call    putport
    mov     si, offset msg_w_w4win
    call    puts
    mov     al, [wp_imr_win]
    call    puthex8
    mov     si, offset msg_w_readback
    call    puts
    mov     al, [wp_imr_back]
    call    puthex8
    call    putnl
    call    vs_wait_edge_to      /* the sync edge: the count window starts here */
    jc      wp_irq_begin_to
    call    vs_settle
    cli
    mov     dword ptr [wp_irqs], 0
    sti
    ret

/* wp_irq_begin_to: no VSYNC edge inside the bound, so the raster is not running where
 * this section expects it. Undo the mask and the vector AT ONCE - a W4C arm that ran
 * anyway would be a W4A arm with a stale vector installed, and a program must never
 * leave INT 0Ah pointing at itself. wp_irq_bad tells the caller to skip the arm. */
wp_irq_begin_to:
    mov     byte ptr [wp_irq_bad], 1
    mov     byte ptr [wp_irq_on], 0
    call    wp_irq_end
    ret

/* wp_irq_end: release, consume the last arm, restore the masked IMR and the vector and
 * read both back. The re-arm is cleared BEFORE the release EOI, so the last arm fires
 * inside the window (the /VSYNC consume step) and nothing this section writes can leave
 * a request armed. */
wp_irq_end:
    cli
    mov     byte ptr [wp_rearm], 0
    mov     byte ptr [wp_noeoi], 0
    mov     dx, 0x0000
    mov     al, 0x62
    out     dx, al
    sti
    call    vs_settle
    call    vs_wait_edge_to
    jc      wp_irq_end_to
    call    vs_settle
wp_irq_end_to:
    cli
    xor     ax, ax
    mov     es, ax
    mov     ax, [wp_old_off]
    mov     es:[0x0028], ax
    mov     ax, [wp_old_seg]
    mov     es:[0x002A], ax
    mov     dx, 0x0002
    mov     al, [wp_imr_was]
    call    write_byte
    mov     dx, 0x0002
    in      al, dx
    mov     [wp_imr_final], al
    xor     ax, ax
    mov     es, ax
    mov     ax, es:[0x0028]
    mov     [wp_new_off], ax
    mov     ax, es:[0x002A]
    mov     [wp_new_seg], ax
    sti
    mov     si, offset msg_w_w4done
    call    puts
    mov     dx, 0x0002
    mov     al, [wp_imr_was]
    call    putport
    mov     si, offset msg_w_now
    call    puts
    mov     al, [wp_imr_final]
    call    puthex8
    mov     si, offset msg_w_vec
    call    puts
    mov     ax, [wp_new_seg]
    call    puthex16
    mov     si, offset msg_w_colon
    call    puts
    mov     ax, [wp_new_off]
    call    puthex16
    mov     si, offset msg_w_irqs
    call    puts
    mov     eax, [wp_irqs]
    mov     word ptr [pd_w], 0
    call    putdec32
    call    putnl
    ret

/* wp_rchk: DX = port, AL = the as-found value. Writes it back, re-reads the port and
 * prints `PPPP=WW -> NN` (WW = as-found, NN = the read-back). */
wp_rchk:
    push    ax
    push    bx
    push    dx
    mov     bh, al
    out     dx, al
    in      al, dx
    mov     bl, al
    mov     al, bh
    call    putport
    mov     si, offset msg_arrow
    call    puts
    mov     al, bl
    call    puthex8
    pop     dx
    pop     bx
    pop     ax
    ret

/* wp_restore: put every latch this section wrote back from its save and print the
 * as-found -> read-back row. 0xA4/0xA6 are left at 0 by the graphics-probe convention
 * (their as-found bytes are in the ASFOUND row; see the header). */
wp_restore:
    mov     si, offset msg_w_restore
    call    puts
    mov     dx, 0x0068
    mov     al, [wp_68_was]
    call    wp_rchk
    mov     al, [wp_68_was]
    call    note_restore
    call    putsp
    mov     dx, 0x006A
    mov     al, [wp_6a_was]
    call    wp_rchk
    mov     al, [wp_6a_was]
    call    note_restore
    call    putsp
    mov     dx, 0x007C
    mov     al, [wp_7c_was]
    call    wp_rchk
    mov     al, [wp_7c_was]
    call    note_restore
    call    putsp
    mov     dx, 0x00A4
    xor     al, al
    call    wp_rchk
    call    putsp
    mov     dx, 0x00A6
    xor     al, al
    call    wp_rchk
    call    putsp
    mov     dx, 0x0002
    mov     al, [wp_imr_was]
    call    wp_rchk
    call    putnl
    /* the INT 0Ah vector, read back after the restore */
    xor     ax, ax
    mov     es, ax
    mov     ax, es:[0x0028]
    mov     [wp_new_off], ax
    mov     ax, es:[0x002A]
    mov     [wp_new_seg], ax
    mov     si, offset msg_w_restvec
    call    puts
    mov     ax, [wp_old_seg]
    call    puthex16
    mov     si, offset msg_w_colon
    call    puts
    mov     ax, [wp_old_off]
    call    puthex16
    mov     si, offset msg_arrow
    call    puts
    mov     ax, [wp_new_seg]
    call    puthex16
    mov     si, offset msg_w_colon
    call    puts
    mov     ax, [wp_new_off]
    call    puthex16
    call    putnl
    ret

/* ------------------------------------------------------------------ */
/* section: ATA soft reset signature (leave this section last)         */
/* ------------------------------------------------------------------ */
sec_srst:
    mov     si, offset msg_begin_srst
    call    puts
    mov     dx, 0x074C
    mov     al, 0x06            /* SRST */
    call    write_byte
    /* Hold it long enough for any drive: the spec's minimum is 10 us and a
     * 486 at this loop's speed is far slower than that. */
    push    cx
    mov     cx, 0x4000
1:  in      al, dx
    loop    1b
    pop     cx
    mov     dx, 0x074C
    mov     al, 0x00
    call    write_byte
    /* Wait for BSY to clear, bounded. */
    mov     cx, 0xFFFF
2:  mov     dx, 0x064E
    in      al, dx
    test    al, 0x80
    jz      3f
    loop    2b
3:  mov     si, offset msg_srst_state
    call    puts
    mov     si, offset tab_ata
    call    dump_port_table
    mov     si, offset msg_end_srst
    call    puts
    ret

/* ------------------------------------------------------------------ */
/* INT 23h / 24h: iret only, so a ^C or a critical error cannot kill  */
/* the probe in the middle of a restore                               */
/* ------------------------------------------------------------------ */
install_handlers:
    push    ax
    push    dx
    push    ds
    mov     dx, offset handler_iret
    mov     ax, 0x2523
    int     0x21
    mov     dx, offset handler_int24
    mov     ax, 0x2524
    int     0x21
    pop     ds
    pop     dx
    pop     ax
    ret

handler_iret:
    iret

handler_int24:
    mov     al, 3               /* fail the operation rather than retrying */
    iret

/* ------------------------------------------------------------------ */
/* data                                                               */
/* ------------------------------------------------------------------ */

flags:          .byte 0
all_seen:       .byte 0
flags2:         .byte 0
flags3:         .byte 0
flags4:         .byte 0
flags5:         .byte 0
run_fail:       .byte 0     /* a self-check failed: exit 1 so a capture cannot look good */
hist_sel:       .byte 0
vram_seg:       .word 0
restore_n:      .word 0
restore_dropped: .word 0
restore_tab:    .space RESTORE_MAX * 4

tram_buf:       .space 320
tram_tail_buf:  .space 32   /* 0xA3FE0..0xA3FFF: row counter + switch cells */
cg_head_buf:    .space 16   /* 0xA4000..0xA400F: across the TRAM/CG boundary */
wa_buf:         .space 512
id_buf:         .space 512
rd_buf:         .space 512
ata_blk:        .space 16
ata_bank_arg:   .byte 0
ata_bank_save:  .byte 0
pci_cf8_was:    .space 4
vram_save:      .space 8
vram_pat:       .byte 0x00, 0xFF, 0x55, 0xAA, 0x00, 0x00, 0x00, 0x00
vram_got:       .space 8
hist_bits:      .space 32
cal_bits:       .space 16

msg_banner:     .asciz "PROBE2 BEGIN\r\n"
msg_done:       .asciz "PROBE2 END\r\n"
msg_runfail:    .asciz "  ** RUN FAILED (exit code 1): the PIT divisor above is outside the documented\r\n     mode-3 band, so this capture's ABSOLUTE PIT figures are not trustworthy - the\r\n     xBASE ratios are. Read the divisor line's `coherent pairs = ACC/TRY`: ~1/1 means\r\n     the value is what the MACHINE returns (a hardware reading to report, not a probe\r\n     fault), a low ratio means the latch read tore. Neither case makes the capture\r\n     unusable - it only stops the absolute PIT columns being quoted. **\r\n"
msg_restore:    .asciz "RESTORE (port=original -> now):\r\n"
msg_none:       .asciz "  none (no writes were made)\r\n"
msg_inline_note: .asciz "  none registered here - but do NOT read this footer as 'no writes were made':\r\n  sections that write and restore INLINE are not in this table. /RDBACK wrote every\r\n  latch it tested and put it back itself (its per-port back= values are the proof;\r\n  0x43D was restored by search), and /PIT reprogrammed channel 0 and restored it to\r\n  the measured divisor. Their own rows are the evidence; see their sections.\r\n"
msg_arrow:      .asciz " -> "
msg_mute:       .asciz " (write-only port: read-back is not the written state; not replayed)\r\n"
msg_restore_full: .asciz "  WARNING: restore table full; writes not recorded: "
/* 0x43F/0x461/0x463/0x53D answer from a strap, so a restore cannot be proven
 * by reading them back: the value read is fixed state, not the byte written. */
msg_strap:      .asciz "  note: 043F/0461/0463/053D read back a strap, not a mirror of the write;\r\n        their 'now' byte cannot prove or disprove a restore.\r\n"
msg_port_note:  .asciz "  (-- = consume-on-read port, not sampled: 0041 keyboard data, 0062 GDC1 data, 0640/0740 ATA data)\r\n"

msg_begin_snap: .asciz "BEGIN:SNAPSHOT\r\n"
msg_end_snap:   .asciz "END:SNAPSHOT\r\n"
msg_wa:         .asciz "WORKAREA 0000:0400..05FF (16 per line):\r\n"
msg_tram:       .asciz "TRAM A0000/A2000 first 160 cells (read before any output):\r\n"
msg_tram_tail:  .asciz "TRAM TAIL A3FE0..A3FFF (ITF row counter + 8 memory-switch cells):\r\n"
msg_cg_head:    .asciz "A4000..A400F (CG window, across the TRAM boundary):\r\n"
msg_ata_block:  .asciz "ATA BLOCK as left by POST/DOS (port=value, and its odd partner):\r\n"
msg_window:     .asciz "ROM WINDOW\r\n"
msg_43d:        .asciz "  043D="
msg_43f:        .asciz " 043F="
msg_f8000:      .asciz "  F8000:0000="
msg_f8e90:      .asciz "  F8E90 (IDE option-ROM drive bitmap) byte/byte+1/word="

msg_begin_ports: .asciz "BEGIN:PORTS\r\n"
msg_end_ports:  .asciz "END:PORTS\r\n"
msg_sdip:       .asciz "SDIP 841E + n*100 (n=0..15):\r\n"

msg_begin_pci:  .asciz "BEGIN:PCI\r\n"
msg_end_pci:    .asciz "END:PCI\r\n"
msg_pci0:       .asciz "  CF8<-80000000 CF C="
msg_pci_r:      .asciz "  CF8<-0        CF C="
msg_pci_was:    .asciz "  CF8 first-touch (restored at end)="

msg_begin_gdc:  .asciz "BEGIN:GDC\r\n"
msg_end_gdc:    .asciz "END:GDC\r\n"
msg_port:       .asciz "  PORT " 
msg_bit:        .asciz "    bit"
msg_count:      .asciz " count="

msg_begin_cal:  .asciz "BEGIN:CAL\r\n"
msg_end_cal:    .asciz "END:CAL\r\n"
msg_cal_mode:   .asciz "  mode 0022 first touch="
msg_cal_stream: .asciz "  raw 52-bit stream (stream order, then nibbles):\r\n  "

msg_begin_ata:  .asciz "BEGIN:ATA\r\n"
msg_end_ata:    .asciz "END:ATA\r\n"
msg_ata_before: .asciz "  block before any selection:\r\n"
msg_432_before: .asciz "  0432 first touch="
msg_430_first:  .asciz "  0430 first touch="
msg_ata_banked: .asciz "  block with 0432=0x"
msg_430_bank1:  .asciz "  0430 with bank 1="
msg_430_w55:    .asciz "  0430 after writing 55="
msg_ata_sel:    .asciz "  block with 064C=0xA0 (master, CHS):\r\n"
msg_identify:   .asciz "  IDENTIFY 0xEC, all 256 words:\r\n"
msg_id_fail:    .asciz "  IDENTIFY failed (ERR or timeout)\r\n"
msg_ata_after:  .asciz "  block after IDENTIFY:\r\n"
msg_read_chs:   .asciz "  READ 0x20 LBA0 via CHS (064C=0xA0), first 128 bytes:\r\n"
msg_read_lba:   .asciz "  READ 0x20 LBA0 via LBA28 (064C=0xE0), first 128 bytes:\r\n"
msg_read_fail:  .asciz "  READ failed (ERR or timeout)\r\n"

msg_begin_vram: .asciz "BEGIN:VRAM\r\n"
msg_end_vram:   .asciz "END:VRAM\r\n"
msg_vram_row:   .asciz "  "
msg_wrote:      .asciz "wrote= "
msg_got:        .asciz "got=   "

msg_begin_srst: .asciz "BEGIN:SRST\r\n"
msg_end_srst:   .asciz "END:SRST\r\n"
msg_srst_state: .asciz "  block after SRST release:\r\n"

/* Port tables. Every entry is read as a byte, and its odd partner is read too,
 * so a 16-bit register with a live high byte can be told from two byte-wide
 * registers and from open bus. */
tab_latches:
    .word 0x0020, 0x0022, 0x0031, 0x0033, 0x0035, 0x0037
    .word 0x0041, 0x0043, 0x005C, 0x005E, 0x0060, 0x0062, 0x0064
    .word 0x0068, 0x006A, 0x006E
    .word 0x0070, 0x0072, 0x0074, 0x0076, 0x0078, 0x007A, 0x007C, 0x007E
    .word 0x0090, 0x0092, 0x0094, 0x0096, 0x0098, 0x009A, 0x009C, 0x009E
    .word 0x00A0, 0x00A2, 0x00A4, 0x00A6, 0x00A8, 0x00AA, 0x00AC, 0x00AE
    .word 0x0128, 0x0430, 0x0432, 0x0433, 0x0435, 0x043B, 0x053D, 0x063C
    .word 0x09A0, 0x09A8, 0x0EE0, 0x1E8E
    .word 0x04A0, 0x04A2, 0x04A4, 0x04A6, 0x04A8, 0x04AA, 0x04AC, 0x04AE
    .word 0xFFFF

tab_ata:
    .word 0x0640, 0x0642, 0x0644, 0x0646, 0x0648, 0x064A, 0x064C, 0x064E
    .word 0x074C, 0x074E
    .word 0xFFFF

tab_pci:
    .word 0x0CF8, 0x0CFC, 0x0CFE
    .word 0xFFFF

tab_vram:
    .word 0xA000, 0xA200, 0xA400, 0xA600, 0xA800, 0xB000, 0xB800, 0xE000
    .word 0xFFFF

/* The wide scan: one read per port, no writes, covering the decoded surface
 * both references agree on plus the ports our own RTL answers from a guess. */
tab_ports:
    .word 0x0000, 0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0x0006, 0x0007
    .word 0x0008, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x000E, 0x000F
    .word 0x0010, 0x0012, 0x0014, 0x0016, 0x0018, 0x001A, 0x001C, 0x001E
    .word 0x0021, 0x0023, 0x0025, 0x0027, 0x0029, 0x002B, 0x002D, 0x002F
    .word 0x0030, 0x0032, 0x0034, 0x0036, 0x0038, 0x003A, 0x003C, 0x003E
    .word 0x0040, 0x0042, 0x0044, 0x0046, 0x0048, 0x004A, 0x004C, 0x004E
    .word 0x0050, 0x0052, 0x0054, 0x0056, 0x0058, 0x005A, 0x00F0, 0x00F1
    .word 0x00F2, 0x00F3, 0x00F4, 0x00F6, 0x00F8, 0x00FA, 0x00FC, 0x00FE
    .word 0x0120, 0x0122, 0x0124, 0x0126, 0x012A, 0x0130, 0x0132, 0x0134
    .word 0x0140, 0x0142, 0x0144, 0x0146, 0x0148, 0x014A
    .word 0x0180, 0x0182, 0x0188, 0x018A
    .word 0x01F0, 0x01F2, 0x01F4, 0x01F6, 0x01F8, 0x01FA, 0x01FC, 0x01FE
    .word 0x0431, 0x0434, 0x0436, 0x0438, 0x043A, 0x043C, 0x043E
    .word 0x053C, 0x053E, 0x063D, 0x063E, 0x063F
    .word 0x0740, 0x0742, 0x0744, 0x0746, 0x0748, 0x074A
    .word 0x0F40, 0x0F42, 0x0F44, 0x0F45
    .word 0x841E
    .word 0xFFFF

/* /MODE: the 0x989x block first (0x9894 before 0x9892, because the firmware
 * reads 0x9894 with no setup at POST and 0x9892 is a data port whose read
 * safety is unproven), then the 0x98D7 register and the software-DIP straps.
 * 0x98E8 is deliberately absent: it is a segment value in the firmware
 * (mov es,ax at BANK4@0xF99DA), not a port. */
tab_mode:
    .word 0x9894, 0x9892, 0x9890, 0x9896, 0x98E0, 0x98D7
    .word 0x8C1E, 0x8D1E, 0x8E1E, 0x8F1E, 0x8F1F
    .word 0xFFFF

/* ---- round-10 section state ------------------------------------- */
win_was461:     .byte 0
win_was463:     .byte 0
win_was43f:     .byte 0
win_was43b:     .byte 0
win_was63c:     .byte 0
win_was63d:     .byte 0
win_was63e:     .byte 0
win_bit0:       .byte 0
win_after80:    .word 0
win_after90:    .word 0
win_ro80:       .word 0
win_ro90:       .word 0
win_roA0:       .word 0
win_roB0:       .word 0
win_rb461:      .byte 0
win_rb463:      .byte 0
sw_port:        .word 0
sw_base:        .word 0
sw_ident:       .byte 0
sw_own_lo:      .byte 0
sw_own_hi:      .byte 0
sw_cands:       .word 0
sw_res:         .word 0
sw_n:           .word 0
win_cand0:      .byte 0x00, 0x01, 0x08, 0x0A, 0x0C, 0x0E, 0x0F, 0x10, 0x41, 0x7F
win_cand1:      .byte 0x00, 0x08, 0x0A, 0x0C, 0x0E, 0x0F, 0x10, 0x41
win_pages:      .byte 0,1,2,3,4,5,6,7,8,9,0x0A,0x0B,0x0C,0x0D,0x0E,0x0F,0xFF
win_res0:       .space 80
win_res1:       .space 64

ems_was:        .byte 0
ems_rb20:       .byte 0
ems_rb20b:      .byte 0
ems_rb80:       .byte 0
ems_rb82:       .byte 0
ems_rb_was:     .byte 0
ems_itf:        .word 0
ems_p20:        .word 0
ems_p22:        .word 0
ems_p24:        .word 0
ems_p20c:       .word 0
ems_f8_80:      .word 0
ems_f8_82:      .word 0
ems_save:       .space 16
ems_ext_save:   .space 16
ems_ext20:      .space 16
ems_ext22:      .space 16

d8_was:         .byte 0
f8e90_b:        .byte 0
f8e90_b1:       .byte 0
f8e90_w:        .word 0
d8_first:       .space 34
d8_state_tab:   .byte 0x00, 0x02, 0x10
d8_blk:         .space 108

joy_a0:         .byte 0
joy_a1:         .byte 0
joy_a2:         .byte 0
joy_188a:       .byte 0
joy_188b:       .byte 0

mode_r1:        .byte 0
mode_r2:        .byte 0

rc_words:       .word 0
rc_bytes:       .long 0
rc_s16:         .word 0
rc_lo:          .byte 0
rc_hi:          .byte 0
rc_min:         .byte 0
rc_max:         .byte 0
rc_e90:         .byte 0
rc_f800:        .byte 0
rc_first:       .space 8
rc_last:        .space 8

/* ---- /MEMSW section state --------------------------------------- */
msw_530a:       .byte 0
msw_530b:       .byte 0
msw_531a:       .byte 0
msw_531b:       .byte 0
msw_a1:         .byte 0
msw_a3:         .byte 0
msw_a5:         .byte 0
msw_tram:       .space 32
msw_cg:         .space 24   /* 8 entries x {A1 code high, row, A9 value} */
msw_codes:      .byte 0x71, 0x72
msw_rows:       .byte 0x27, 0x2D, 0x2E, 0x2F

/* ---- /MEMCNT section state -------------------------------------- */
mcnt_530a:      .byte 0
mcnt_530b:      .byte 0
mcnt_531a:      .byte 0
mcnt_531b:      .byte 0
mcnt_a1:        .byte 0
mcnt_a3:        .byte 0
mcnt_a5:        .byte 0
mcnt_530_was:   .byte 0
mcnt_rb00:      .byte 0
mcnt_rb55:      .byte 0
mcnt_rbaa:      .byte 0
mcnt_col:       .byte 0
mcnt_cg:        .space 27   /* 9 entries x {A1 code high, row, A9 value} */
mcnt_sweepv:    .space 256  /* the 0x531 data at 0x530 = 00..FF */

/* /MEMRW: six indices, 0x79 FIRST, then the ends and the
 * interior of the range the ITF's own copy block reads (BANK4@0xF8DC8 reads
 * 0..9 and 0x80..0x89). 0xFF is outside that range on purpose - a register the
 * firmware never touches is the cleanest control for the write test. */
mrw_idx:        .byte 0x79, 0x00, 0x09, 0x80, 0x89, 0xFF
mrw_530_was:    .byte 0
mrw_531_was:    .byte 0
mrw_was:        .byte 0
mrw_rd:         .space MRW_N * 2    /* {index, 0x531 value} */
mrw_mkres:      .space MRW_N * 5    /* {index, as found, after 5A, after A5, put back} */
/* The (code high, row) pairs the ITF reads through A1/A3/A5 -> A9. The code
 * low byte is always 0x57. Sites, from BANK4.BIN: code 0x7157 row 0x27 at
 * 0xF8BC0/0xF8A54/0xF8E3F, code 0x7157 rows 0x2D/0x2E/0x2F at 0xF8EBD, code
 * 0x7257 row 0x27 at 0xF8A54, code 0x7257 row 0x28 at 0xF8A7E (the one row
 * /MEMSW does not read). */
mcnt_cg_pairs:
    .byte 0x71, 0x27, 0x71, 0x2D, 0x71, 0x2E, 0x71, 0x2F
    .byte 0x72, 0x27, 0x72, 0x28, 0x72, 0x2D, 0x72, 0x2E, 0x72, 0x2F

/* ---- /SHADOW section state -------------------------------------- */
sh_if_was:      .byte 0
sh_was43d:      .byte 0
sh_was43f:      .byte 0
sh_was461:      .byte 0
sh_was53d:      .byte 0
sh_was1e8e:     .byte 0
sh_1e8e_b:      .byte 0
sh_gate_on:     .byte 0
sh_gate_off:    .byte 0
sh_gate_now:    .byte 0
sh_rd_id:       .byte 0
sh_rd_e8f:      .byte 0
sh_rd_e90:      .byte 0
sh_rd_e91:      .byte 0
sh_rd_ew:       .word 0
sh_mark_was:    .byte 0
sh_mark_now:    .byte 0
sh_mb_was:      .byte 0
sh_mb_now:      .byte 0
sh_alias:       .byte 0
sh_wseg:        .word 0
sh_woff:        .word 0
sh_bank_ok:     .byte 0
sh_43d_restored: .byte 0
sh_ver_id:      .byte 0
sh_ver_e90:     .byte 0
/* The flat physical 0x98E90 discriminator: the byte DOS has there before the
 * marker write, the byte after, and the identity value of 0x0461 (0x08 maps the
 * 80000-9FFFF window to itself, so reading 98E8:0010 is a true flat read). */
sh_98e90_was:   .byte 0
sh_98e90:       .byte 0
sh_blk:         .space 128  /* 8 states x 16 bytes */
/* 0x043D's read-back is a strap, so the restore searches for a value that
 * reproduces the bank byte found at F8000:0000: the four the firmware and the
 * references use, in the order the ITF would have left them. */
sh_43d_cands:   .byte 0x02, 0x00, 0x10, 0x12, 0x18, 0xFF
/* /SHADOW state table: {id, 0x043D value (0xFF = leave), 0x043F value
 * (0xFF = leave), gate (1 = bit 1 set, 0 = bit 1 clear)}, 0xFF terminated.
 * Every state writes the latches it names, so no state depends on the one
 * before it; only states 1 and 2 leave 0x043F, and they run first, so it is
 * still the firmware's own value there. */
sh_tab:
    .byte 0x01, 0x02, 0xFF, 1   /* BIOS-top bank, 0x043F as the firmware left it */
    .byte 0x02, 0x00, 0xFF, 1   /* the ITF bank: the state the ITF's own store ran in */
    .byte 0x03, 0x02, 0xEE, 1   /* 0x043D=BIOS-top and 0x043F=bank 7 agree */
    .byte 0x04, 0x00, 0xE8, 1   /* 0x043D=ITF and 0x043F=bank 4 agree */
    .byte 0x05, 0x00, 0xEE, 1   /* 0x043D=ITF but 0x043F=bank 7 (conflict) */
    .byte 0x06, 0x02, 0xE8, 1   /* 0x043D=BIOS-top but 0x043F=bank 4 (conflict) */
    .byte 0x07, 0x02, 0xEE, 0   /* bank 7, writable-copy gate clear */
    .byte 0x08, 0x00, 0xE8, 0   /* bank 4 (the ITF image), writable-copy gate clear */
    .byte 0xFF

/* ---- /SHADOW 0xDA000 work-RAM state ----------------------------- */
sh_work_was:    .space 16
sh_work_80:     .space 16
sh_work_81:     .space 16
sh_work_end:    .space 16
sh_work_80w:    .word 0
sh_work_81w:    .word 0
sh_g80:         .byte 0
sh_g81:         .byte 0
sh_g_end:       .byte 0

/* ---- region scan + MEM: report state ---------------------------- */
rr_label:       .word 0
rr_seg:         .word 0
rr_blocks:      .word 0
rr_off:         .word 0
rr_min:         .byte 0
rr_max:         .byte 0
rr_ffcur:       .byte 0
rr_ffblk:       .word 0
rr_fccb:        .word 0
rr_line:        .space 8
mr_label:       .word 0
mr_was:         .word 0
mr_now:         .word 0
mr_len:         .word 0

/* ---- /XPORT section state --------------------------------------- */
xp_skip:        .byte 0
xp_havew:       .byte 0
xp_v1:          .byte 0
xp_v2:          .byte 0
xp_w:           .word 0
xp_tag:         .word 0
xp_hdr:         .word 0
xp_tab:         .word 0

/* ---- /XP0BR state ----------------------------------------------- */
xbr_idx_was:    .word 0             /* the as-found 0B00 index word */
xbr_dat_was:    .byte 0             /* the as-found 0B02 data byte */
xbr_idx:        .byte 0x69, 0x50, 0x55, 0x59, 0x5C, 0x00
xbr_res:        .space XBR_N * 6    /* {index, B02, B00lo, B01, B03, B02|80} */

/* One table per family: the six the firmware evidences but no reference models,
 * each behind its own keyword so a hang is attributable,
 * then the ports the machine answers and the core floats (section 2) plus the
 * 0x09A0-0x09AE graphics block whose 0x09A2 bit 7 the main BIOS polls
 * (section 6): the same defect class, and its fix needs the same measurement. */
tab_xp411:
    .word 0x0411, 0x0412, 0x0413, 0x0414
    .word 0xFFFF
tab_xp0b0:
    .word 0x0B00, 0x0B01, 0x0B02, 0x0B03
    .word 0xFFFF
tab_xp467:
    .word 0x0467
    .word 0xFFFF
tab_xp535:
    .word 0x0535
    .word 0xFFFF
tab_xp238:
    .word 0x0238, 0x0239, 0x023A, 0x023B, 0x023C
    .word 0xFFFF
tab_xp18f:
    .word 0x18F0, 0x18F1, 0x18F2, 0x18F3
    .word 0xFFFF
tab_xpflt:
    .word 0x09A0, 0x09A2, 0x09A4, 0x09A6, 0x09A8, 0x09AA, 0x09AC, 0x09AE
    .word 0x0010, 0x0011, 0x0012, 0x0013, 0x0014, 0x0015, 0x0016, 0x0017
    .word 0x0018, 0x0019, 0x001A, 0x001B, 0x001C, 0x001D, 0x001E, 0x001F
    .word 0x0020, 0x0021, 0x0022, 0x0023, 0x0024, 0x0025, 0x0026, 0x0027
    .word 0x0028, 0x0029, 0x002A, 0x002B, 0x002C, 0x002D, 0x002E, 0x002F
    .word 0x0040
    .word 0x0740, 0x0741, 0x0742, 0x0743, 0x0744, 0x0745
    .word 0x0746, 0x0747, 0x0748, 0x0749, 0x074A, 0x074B
    .word 0x98D7
    .word 0xFFFF

i1_vec_off:     .word 0
i1_vec_seg:     .word 0
i1_4AC:         .word 0
i1_4AE:         .word 0
i1_584:         .byte 0
i1_584_orig:    .byte 0
i1_456:         .byte 0
i1_55D:         .byte 0
i1_55F:         .byte 0
i1_4AC_orig:    .word 0
i1_4AE_orig:    .word 0
i1_in_ax:       .word 0
i1_in_bx:       .word 0
i1_in_cx:       .word 0
i1_in_dx:       .word 0
i1_in_si:       .word 0
i1_out:         .space 16
i1_blk:         .space 80
i1_4B0:         .space 8
i1_460:         .space 32
i1_b0buf:       .space 16

msg_begin_win:  .asciz "BEGIN:WIN\r\n"
msg_end_win:    .asciz "END:WIN\r\n"
msg_win_was:    .asciz "  WIN first-touch 461/463/43F/43B/63C/63D/63E: "
msg_win_ro:     .asciz "  window now (80000/90000/A0000/B0000): "
msg_win_rrb:    .asciz "  461/463 read-back="
msg_win_inert:  .asciz "  read-only: 461/463 not moved (add WRITE to sweep the window)\r\n"
msg_win_write:  .asciz "  sweeping 461/463 (opt-in) ... p/q=FD means not written (page 0/1 or the probe's own page)\r\n"
msg_win_bit0:   .asciz "  461 read-back after (first-touch|1): "
msg_win_after:  .asciz "  after restore 80000/90000: "
msg_win_rb:     .asciz " rb="
msg_win_b:      .asciz " b="
msg_win_a:      .asciz " a="
msg_win_p:      .asciz " p="
msg_win_q:      .asciz " q="

msg_begin_ems:  .asciz "BEGIN:EMS\r\n"
msg_end_ems:    .asciz "END:EMS\r\n"
msg_ems_was:    .asciz "  EMS first-touch 43F: "
msg_ems_itf:    .asciz "  ITF: 22 wrote AA55 at B0000, 20 read: "
msg_ems_rb20:   .asciz "  43F read-back after 20/20/80/82/restore: "
msg_ems_pages:  .asciz "  B0000 under 20/22/24: "
msg_ems_p21:    .asciz "  B0000 under 20 after 21 wrote FF21: "
msg_ems_f8:     .asciz "  F8000 word under 80/82: "
msg_ems_ext20:  .asciz "  B0000..BE000 under 20: "
msg_ems_ext22:  .asciz "  B0000..BE000 under 22: "

msg_begin_d8:   .asciz "BEGIN:D8\r\n"
msg_end_d8:     .asciz "END:D8\r\n"
msg_d8_was:     .asciz "  D8 first-touch 53D: "
msg_d8_first:   .asciz "  D8000 first touch sig@9/32 bytes: "
msg_d8_state:   .asciz "  53D="
msg_d8_rb:      .asciz " rb="
msg_d8_sig:     .asciz " sig="
msg_d8_inert:   .asciz "  read-only: no 53D write at all (WRITE can hang a machine with the IDE driver loaded)\r\n"
msg_d8_write:   .asciz "  writing 53D 00/02/10 (opt-in; closes the D8000 window the loaded IDE driver runs from - can hang) ...\r\n"

msg_begin_joy:  .asciz "BEGIN:JOY\r\n"
msg_end_joy:    .asciz "END:JOY\r\n"
msg_joy_bare:   .asciz "  bare 18A/188: "
msg_joy_seq:    .asciz "  after 188<-0F,188<-0E: 18A/18A/188: "

msg_begin_int1b: .asciz "BEGIN:INT1B\r\n"
msg_end_int1b:  .asciz "END:INT1B\r\n"
msg_int1b_vec:  .asciz "  INT 1Bh vector: "
msg_int1b_dev:  .asciz "  [0x584]: "
msg_int1b_ptr:  .asciz "  4AC:4AE entry: "
msg_int1b_wa:   .asciz "  work-area 0456/055D/055F: "
msg_int1b_4b0:  .asciz "  work-area 04B0..04B7 (class -> option-ROM segment): "
msg_int1b_460:  .asciz "  work-area 0460..047F: "
msg_int1b_inert: .asciz "  read-only: no INT 1Bh issued (add CALL to enter the option ROM)\r\n"
msg_int1b_call: .asciz "  issuing INT 1Bh AH=84/8E/14/B0/24 (opt-in) ...\r\n"
msg_int1b_refuse: .asciz "  refusing to call: no live INT 1Bh vector or no hard-disk device\r\n"
msg_int1b_ah:   .asciz "  INT 1B AH="
msg_int1b_ax:   .asciz " AX="
msg_int1b_bx:   .asciz " BX="
msg_int1b_cx:   .asciz " CX="
msg_int1b_dx:   .asciz " DX="
msg_int1b_f:    .asciz " F="
msg_int1b_4ac:  .asciz " entry="
msg_int1b_b0:   .asciz "  0xB0 handshake buffer: "

msg_begin_mode: .asciz "BEGIN:MODE\r\n"
msg_end_mode:   .asciz "END:MODE\r\n"
msg_mode_hdr:   .asciz "MODE 9894/9892/9890/9896/98E0/98D7 + SDIP straps, read twice each (port=V1 V2, no writes):\r\n"
msg_mode_hint:  .asciz "  CPU MODE strap: 8F1E bit2=0 -> High, bit2=1 -> Low (BANK4@0xFA7EB); 8E1E bit4 is the other strap input\r\n"
msg_mode_ro:    .asciz "  read-only: no port writes at all, so there is nothing to restore\r\n"

msg_begin_romck: .asciz "BEGIN:ROMCK\r\n"
msg_end_romck:   .asciz "END:ROMCK\r\n"
msg_romck_hdr:   .asciz "ROMCK: the two ROM windows the ITF's stage-1C RAM code checksums (F8000 at BANK4@0x0198, E8000 at BANK4@0x01B6).\r\n"
msg_romck_pass:  .asciz "  PASS condition: the low-byte 8-bit sum AND the high-byte 8-bit sum must both be 00 (the ITF's `or dx,dx`); otherwise it halts at ROM SUM ERROR (BANK4@0xF8278).\r\n"
msg_romck_43d:   .asciz "  043D read (F8000 window bank gate; read-back is a strap, not the bank)="
msg_romck_f8:    .asciz "  F8000 window, 32 KiB, firmware path `out 043D,02` then DS=F800 CX=4000 words (main-BIOS top bank). READ-ONLY: 043D not written.\r\n"
msg_romck_e8:    .asciz "  E8000 window, 64 KiB, firmware path DS=E800 CX=8000 words (fixed ROM view BANK5|BANK6, no gate).\r\n"
msg_romck_words: .asciz "  words="
msg_romck_bytes: .asciz " bytes="
msg_romck_s8:    .asciz "  sum8  (all bytes, mod 256) = "
msg_romck_s16:   .asciz "  sum16 (all little-endian words, mod 65536) = "
msg_romck_itf:   .asciz "  ITF lo hi (add dl,al; add dh,ah) = "
msg_romck_first: .asciz "  first8: "
msg_romck_last:  .asciz "  last8 : "
msg_romck_e90:   .asciz "  window+0xE90 (BANK7.BIN=00 raw ROM, BIOS.ROM=04 runtime; BANK4@0x19D4 writes the ITF byte here) = "
msg_romck_shadow: .asciz "  NOTE: 0xE90=04 is the ITF's own POST write (BANK4@0x19D4), so this window is the writable BIOS copy (the ITF's runtime image), not the raw ROM its stage-1C checksum sums (the checksum runs before that write).\r\n"
msg_romck_na:    .asciz "  -> the raw-ROM pass condition cannot be read from here: this is the ITF's post-write runtime image.\r\n"
msg_romck_zero:  .asciz "  -> lo=00 hi=00: matches the ITF's pass condition.\r\n"
msg_romck_nonzero: .asciz "  -> lo or hi non-zero: the ITF's pass condition is not met by this window.\r\n"
msg_romck_const1: .asciz "  WARNING: this window reads a single repeated byte "
msg_romck_const2: .asciz " (open bus / not decoded through this path): its sums are not a checksum.\r\n"
msg_romck_ro:    .asciz "  read-only: /ROMCK made no port writes; 043D was only read and the F8000 bank is summed as the machine left it.\r\n"

msg_begin_memsw:  .asciz "BEGIN:MEMSW\r\n"
msg_end_memsw:    .asciz "END:MEMSW\r\n"
msg_memsw_hdr:    .asciz "MEMSW: the machine's own memory-switch view - the 0530/0531 pair (read-only), the CG-window rows the ITF reads through A1/A3/A5 -> A9, and the TRAM tail switch cells A3FE2+4i.\r\n"
msg_memsw_530:    .asciz "  0530 (read-only, deliberately never written): "
msg_memsw_531:    .asciz "  0531 (read-only, deliberately never written): "
msg_memsw_stab:   .asciz " -> "
msg_memsw_same:   .asciz "stable (V1==V2)"
msg_memsw_changed: .asciz "CHANGED between the two reads"
msg_memsw_tram:   .asciz "TRAM TAIL A3FE0..A3FFF (row counter + 8 memory-switch cells, read-only):\r\n"
msg_memsw_cells:  .asciz "  switch cells A3FE2+4i, i=0..7: "
msg_memsw_cg_hdr: .asciz "  CG window rows the ITF reads (A1=code high, A3=0x57, A5=row, read A9; BANK4@0x8BC0/0x8E3F/0x8EBD):\r\n"
msg_memsw_cg_code: .asciz "    code "
msg_memsw_cg_row: .asciz " row "
msg_memsw_cg_a9:  .asciz " A9="
msg_memsw_ronote: .asciz "  read-only 0530/0531: this probe never writes the memory-switch pair; only the ordinary CG code/line registers 0A1/0A3/0A5 were written, and they were put back (see RESTORE).\r\n"
msg_memsw_latch:  .asciz "  A stable 0530/0531 read is the state DOS left there; because the pair is never written, a read-only probe cannot by itself tell a latch from a strap. Compare it with the A3FE2+4i cells above.\r\n"

msg_begin_memcnt: .asciz "BEGIN:MEMCNT\r\n"
msg_end_memcnt:   .asciz "END:MEMCNT\r\n"
msg_memcnt_hdr:   .asciz "MEMCNT: the memory-count lane's instrument - the 0530/0531 pair and the user-CG rows the ITF decodes for its extended-size belief (r11/06 section 2.3). Read-only by default; /MEMCNT WRITE dumps 0531 across the 0530 index range.\r\n"
msg_memcnt_530:   .asciz "  0530 (resting, read twice; the ITF's own address latch, BANK4@0xF8DC8): "
msg_memcnt_531:   .asciz "  0531 (resting, read twice; the data at the resting 0530 index): "
msg_memcnt_cg_hdr: .asciz "  CG rows the ITF decodes (A1=code high, A3=0x57, A5=row, read A9; BANK4@0xF8BC0/0xF8A54/0xF8A7E/0xF8E3F/0xF8EBD):\r\n"
msg_memcnt_ro:    .asciz "  read-only: the 0530 index was not moved. Add WRITE to dump 0531 at every 0530 index (that writes only the 0530 address latch - never a 0531 data byte - and puts the index back).\r\n"
msg_memcnt_sweep: .asciz "  sweeping 0530 = 00..FF and reading 0531 at each index (opt-in WRITE; cli from here to the index restore; only the 0530 address latch is written, no 0531 data byte) ...\r\n"
msg_memcnt_dump:  .asciz "  0531 data at 0530 = 00..FF (16 per line):\r\n"
msg_memcnt_rb:    .asciz "  0530 read-back after writing 00/55/AA (a latch returns the last index; a strap returns a constant; the as-found index is then put back) = "

/* /MEMRW: the 0530/0531 pair's read/write test. */
msg_begin_memrw:  .asciz "BEGIN:MEMRW\r\n"
msg_end_memrw:    .asciz "END:MEMRW\r\n"
msg_memrw_hdr:    .asciz "MEMRW: is the 0530/0531 pair a writable register file or a read-only strap? Read-only by default; /MEMRW WRITE adds the marker test. The firmware cannot tell the two apart (it writes the pair at BANK4@0x8C12 and 0x9146 and reads it back at 0x8DC8), so only a write followed by a read-back at the same index discriminates."
msg_memrw_rd_hdr: .asciz "  0531 read at six 0530 indices, 0x79 first: a strap returns the same byte everywhere, an indexed register file does not"
msg_memrw_idx:    .asciz "    0530="
msg_memrw_val:    .asciz " 0531="
msg_memrw_ro:     .asciz "  read-only: no 0531 data byte was written and no 0530 index was left changed. Add WRITE for the marker test (it writes 0531 DATA - the most invasive write in this probe set - reads every byte back first, and restores each index)."
msg_memrw_mk_hdr: .asciz "  marker test (opt-in WRITE; cli around each index; 0531 goes to 5A, then A5, then back): a strap ignores the writes and returns one byte, a writable register returns each marker"
msg_memrw_was_s:  .asciz " was="
msg_memrw_after:  .asciz " after 5A/A5="
msg_memrw_put:    .asciz " put back="
msg_memrw_howto:  .asciz "  read it as: put back = was in every row means the machine is as it was found. A row whose after column follows 5A then A5 is a WRITABLE register (a latch the firmware programmes, so no seed is needed); a row where both markers read back as `was` is a READ-ONLY STRAP. 0x79 is the decisive index - r12/69 section 2 reads the machine's resting 1E there as the extended size in MiB."

msg_begin_shadow: .asciz "BEGIN:SHADOW\r\n"
msg_end_shadow:   .asciz "END:SHADOW\r\n"
msg_shadow_hdr:   .asciz "SHADOW: the writable BIOS copy under the F8000-FFFFF window, the absent C0000-D7FFF ROM area and the DA000 work-RAM window (r11/17 section 5 Q1 and Q5).\r\n"
msg_shadow_was:   .asciz "  first-touch 043D/043F/0461/053D/1E8E: "
msg_shadow_gate:  .asciz "  053D bytes this section may write (bit 4 kept as found): gate-on/gate-off = "
msg_shadow_if:    .asciz "  IF on entry (bit 1 of AH after pushf/pop ax; the writing form restores exactly this)="
msg_shadow_found: .asciz "  as found: F8000:0000 / F8E8F / F8E90 / F8E91 / word = "
msg_shadow_id_itf: .asciz "  -> F8000:0000 = EB = BANK4.BIN[0]: the window shows the ITF image (the reset-time selection).\r\n"
msg_shadow_id_bios: .asciz "  -> F8000:0000 = A1 = BANK7.BIN[0] = BIOS.ROM[0x10000]: the window shows the main BIOS's top bank (the selection the ITF hands over with, and the one BANK3@0x078E reads the drive bitmap under).\r\n"
msg_shadow_rc:    .asciz "  REGION C0000..D7FFF: on a non-PCI machine an ABSENT ROM area (QEMU fills it FF,CB at every 2 KiB so a spurious probe call returns at once). 48 blocks of 2 KiB, offset + first 8 bytes:\r\n"
msg_shadow_rd:    .asciz "  REGION DA000..DFFFF: the IDE option ROM's work RAM, paged by 0x1E8E. 12 blocks of 2 KiB, offset + first 8 bytes:\r\n"
msg_rr_off:       .asciz "    +"
msg_rr_sum:       .asciz "    summary: blocks="
msg_rr_bytes:     .asciz " bytes="
msg_rr_min:       .asciz " min="
msg_rr_max:       .asciz " max="
msg_rr_ffb:       .asciz " ffblocks="
msg_rr_fccb:      .asciz " fccb="
msg_shadow_1e8e:  .asciz "  1E8E read twice (the 0xDA000 gate): "
msg_shadow_ro:    .asciz "  read-only: no port write, no memory write at all (add WRITE for the marker sweep). The 0xF8E90 control value on this machine is 0x04 (the ITF's own store, BANK4@0x19D4).\r\n"
msg_shadow_write: .asciz "  sweeping (opt-in WRITE; cli from here to the restore below):\r\n"
msg_shadow_mark1: .asciz "  MARK F8E90 as found "
msg_shadow_mark2: .asciz " -> wrote A5 through "
msg_shadow_alias: .asciz "the ITF's own path (0461=0E, ES=98E8:0010 -> physical F8E90, BANK4@0x19D4) with the ITF bank selected and the writable-copy gate set"
msg_shadow_direct: .asciz "the flat segment F8E8:0010 (physical F8E90; 0461 was NOT moved because the 80000-9FFFF window would have hidden this program's own pages) with the ITF bank selected and the writable-copy gate set"
msg_shadow_mark3: .asciz " -> now "
msg_shadow_flat:  .asciz "  FLAT 98E90 (0461=identity, the write path used 98E8:0010): was "
msg_shadow_flat2: .asciz " -> now "
msg_shadow_flat_note: .asciz "   (now=A5: the 0x0461 window bias did NOT apply to the write, so the marker landed at flat physical 98E90 and the write rule is the open question. Any other value: the store reached F8E90, so the marker is captured only in a state that selects the write's own bank. This line is also the flat put-back's proof.)\r\n"
msg_shadow_state: .asciz "    st"
msg_shadow_s43d:  .asciz " 043D="
msg_shadow_s43f:  .asciz " 043F="
msg_shadow_s53d:  .asciz " 053D="
msg_shadow_sid:   .asciz " F8000:0000="
msg_shadow_se90:  .asciz " F8E8F/90="
msg_shadow_sew:   .asciz " word="
msg_shadow_statenote: .asciz "    (st01/st02 leave 043F at the firmware's value; st03-st06 select a bank through 043F as well; st07/st08 are the same two banks with the writable-copy gate cleared. F8000:0000 identifies the bank actually shown; a marker A5 in the 053D=gate-on rows is the answer to Q1.)\r\n"
msg_shadow_work:  .asciz "  1E8E read-back after 80/81/restore = "
msg_shadow_workm: .asciz "  DA000 word read back after the 80 and the 81 marker write = "
msg_shadow_mem0:  .asciz "MEM: F8E90 (the marker byte; the put-back below uses the flat segment F8E8:0010, the same physical address) "
msg_shadow_mem80: .asciz "MEM: DA000..DA00F after the restore under 1E8E=80 "
msg_shadow_mem81: .asciz "MEM: DA000..DA00F after the restore under 1E8E=81 "
msg_shadow_memend: .asciz "MEM: DA000..DA00F with the as-found 1E8E back "
msg_shadow_verify: .asciz "  VERIFY as found -> now: F8000:0000 "
msg_shadow_bank:  .asciz "  BANK restore: 043D left at "
msg_shadow_bank_ok: .asciz " (reproduces the as-found bank byte)"
msg_shadow_bank_bad: .asciz " WARNING: no 043D candidate reproduced the as-found bank byte; 02 left in place, check the window before using this machine."
msg_shadow_ifback: .asciz "  the interrupt flag found on entry is back, and no DOS call was made between cli and the restore. IF=00 in the line above means the program itself was entered with interrupts off, which is not how a DOS prompt enters it.\r\n"
msg_mem_was:      .asciz "was "
msg_mem_arrow:    .asciz "-> now "

msg_begin_colon:  .asciz "BEGIN:"
msg_end_colon:    .asciz "END:"
msg_xp411_hdr:    .asciz "XPORT: 0411/0412/0413/0414 - the ITF's index/data pair. It writes 0411=00 then READS 0413 four times, expecting `and al,0xF8` = 10/50/90/D0 (BANK4@0xFC267-0xFC27D); a mismatch jumps to the stage-4 path at FC2EF. 0413 IS THE BRANCH OPERAND. Each port prints its address before its first read, so the port that hangs is the last PPPP printed.\r\n"
msg_xp0b0_hdr:    .asciz "XPORT: 0B00/0B01/0B02/0B03 - the 0xB0000 window programmer. The ITF writes 0B00 with a 16-bit out dx,ax (12 direct sites at BANK4@0xFC1FA-0xFC238 and 0xF847B) and read-modify-writes 0B02 with OR 80 (0xF9BE3, 0xFCA12). No write here, so this is the cold value only.\r\n"
msg_begin_xp0br:   .asciz "BEGIN:XP0BR\r\n"
msg_end_xp0br:     .asciz "END:XP0BR\r\n"
msg_xp0br_hdr:     .asciz "XPORT: 0B00/0B02 write-then-read-back - the branch operand /XP0B0's cold read cannot see. The ITF writes the index word (out 0B00,ax) then reads 0B02 and branches on bit 3: BANK4@0xF9E50-0xF9E5D (index 0x69, test al,8). This replicates that for the six indices the ITF writes (69 50 55 59 5C 00), reads back 0B02 plus the neighbours 0B00/0B01/0B03, then the ITF's 0B02 bit-7 RMW (or al,80) and its read-back. The as-found 0B00 word and 0B02 byte are put back.\r\n"
msg_xp0br_cold:    .asciz "  as-found 0B00 word="
msg_xp0br_cold_dat: .asciz " 0B02="
msg_xp0br_idx:     .asciz "  idx "
msg_xp0br_b02:     .asciz " B02="
msg_xp0br_b3:      .asciz " bit3="
msg_xp0br_b3_0:    .asciz "0"
msg_xp0br_b3_1:    .asciz "1"
msg_xp0br_near:    .asciz " B00/B01/B03="
msg_xp0br_or80:    .asciz " B02|80="
msg_xp467_hdr:    .asciz "XPORT: 0467 - READ once at BANK4@0xFC597 (not al / and al,2 / shl al,1 / and al,4) and used as a branch operand. (0535, its init-table neighbour, has its own keyword.)\r\n"
msg_xp535_hdr:    .asciz "XPORT: 0535 - written 0xFF by the stage-05 init table (BANK4@0xFCA46, pair bytes 35 05 FF 00; r10/01 section 4.2 lists 0x00 and is wrong there). The firmware never reads it, so a cold read cannot tell a latch from a strap.\r\n"
msg_xp238_hdr:    .asciz "XPORT: 0238-023C - an 8250 register sequence (23B=LCR with DLAB, 238/239=divisor, 23C=MCR, 239=IER) at BANK4@0xFC2B8-0xFC2EA. Five ports, not one.\r\n"
msg_xp18f_hdr:    .asciz "XPORT: 18F0-18F3 - the ITF's 16-bit out dx,ax pairs (r11/14 section 2.5; BANK4@0xF8067/0xF806E and 13 sites). r5/03 calls 18F0 the PCI configuration address and 18F2 the configuration data (in ax,0x18F2 at BANK4@0xFD48F-0xFD527), so this family is the strongest INFERRED candidate for the read that hung the last /XPORT; that is inference, not a measurement.\r\n"
msg_xpflt_hdr:    .asciz "XPORT: the ports the machine is measured to answer and the core floats (r12/04 section 2), plus the 09A0-09AE graphics block the main BIOS polls (section 6): 09A8=00, the DMA block 0010-002F, 0040=00, the ATA mirror 0740-074A=0F, 98D7=0D.\r\n"
msg_xport_ro:     .asciz "  per port: PPPP=V1 V2 W=WWWW - the address is printed before the first read, so a hang names the port. Two byte reads (V1 != V2 = the port consumed state or auto-incremented) and one 16-bit read (a live high byte = a wide register). W=---- = the 16-bit read was skipped. read-only: no port write at all (nothing to restore).\r\n"
tag_xp411:        .asciz "XP411"
tag_xp0b0:        .asciz "XP0B0"
tag_xp467:        .asciz "XP467"
tag_xp535:        .asciz "XP535"
tag_xp238:        .asciz "XP238"
tag_xp18f:        .asciz "XP18F"
tag_xpflt:        .asciz "XPFLT"
msg_xp_w:         .asciz "W="
msg_xp_dashes:    .asciz "----"

arg_all:    .asciz "ALL"
arg_ports:  .asciz "PORTS"
arg_ata:    .asciz "ATA"
arg_cal:    .asciz "CAL"
arg_gdc:    .asciz "GDC"
arg_pci:    .asciz "PCI"
arg_vram:   .asciz "VRAM"
arg_srst:   .asciz "SRST"
arg_win:    .asciz "WIN"
arg_ems:    .asciz "EMS"
arg_d8:     .asciz "D8"
arg_joy:    .asciz "JOY"
arg_int1b:  .asciz "INT1B"
arg_call:   .asciz "CALL"
arg_write:  .asciz "WRITE"
arg_mode:   .asciz "MODE"
arg_romck:  .asciz "ROMCK"
arg_memsw:  .asciz "MEMSW"
arg_memcnt: .asciz "MEMCNT"
arg_memrw:  .asciz "MEMRW"
arg_rdback: .asciz "RDBACK"
arg_pit:    .asciz "PIT"
arg_vsync:  .asciz "VSYNC"
arg_wipe:   .asciz "WIPE"
arg_shadow: .asciz "SHADOW"
arg_xport:  .asciz "XPORT"
arg_xp411:  .asciz "XP411"
arg_xp0b0:  .asciz "XP0B0"
arg_xp0br:  .asciz "XP0BR"
arg_xp467:  .asciz "XP467"
arg_xp535:  .asciz "XP535"
arg_xp238:  .asciz "XP238"
arg_xp18f:  .asciz "XP18F"
arg_xpflt:  .asciz "XPFLT"
arg_time:   .asciz "TIME"
arg_timeref: .asciz "TIMEREF"
arg_timeset: .asciz "TIMESET"

/* ------------------------------------------------------------------ */
/* /TIME and /TIMEREF state and output                                */
/* ------------------------------------------------------------------ */
pd_w:           .word 0
pd_zero:        .word 0
dec_buf:        .space 12

tm_used:        .byte 0     /* /TIME ran: the RESTORE block prints the latch note */
tr_used:        .byte 0     /* /TIMEREF ran: the RESTORE block prints the 0020 note */
inline_used:    .byte 0     /* /RDBACK or /PIT ran: they write and restore inline */
tm_divok:       .byte 0     /* the coherent-pair divisor scan was confident */
tm_dtry:        .word 0
tm_daccept:     .word 0
tm_n:           .word 1024  /* accesses per timed class */
tm_batch:       .word 32    /* PIT samples between two calendar reads in the window */
tm_rticks:      .long 614400    /* the raster window: ~2 s at the documented 307200 Hz */
tm_cputicks:    .long 307200    /* the CPU-rate window: ~1 s at the documented rate */
tm_guard:       .word 0
tm_port:        .word 0
tm_kind:        .byte 0
tm_a0:          .long 0
tm_a1:          .long 0
tm_ad:          .long 0
tm_p0:          .word 0
tm_p1:          .word 0
tm_pd:          .long 0
tm_div:         .word 0
tm_dimax:       .word 0
tm_divbad:      .byte 0     /* the measured divisor is not a mode-3 count (tm_div_check) */
pit_cal_ok:     .byte 0     /* the byte-order calibration has run */
pit_swap:       .byte 0     /* 1 when 0071 returns MSB first on this run */
pit_b1:         .byte 0     /* the first byte 0071 returned in the last pair */
pit_b2:         .byte 0     /* and the second */
pit_pb1:        .byte 0
pit_pb2:        .byte 0
pit_d1:         .word 0     /* how often pit_b1 fell over the calibration */
pit_d2:         .word 0
tm_art0:        .long 0
tm_art1:        .long 0
tm_pit1:        .word 0
tm_pit2:        .word 0
tm_pit3:        .word 0
tm_basea:       .long 0
tm_basep:       .long 0
tm_have_base:   .word 0
tm_idx:         .word 0
tm_cur:         .word 0
tm_print:       .word 0
tm_rerun:       .byte 1
tm_ns:          .long 0
tm_ns_a:        .long 0     /* ns in one ARTIC tick */
tm_ns_p:        .long 0     /* ns in one PIT count */
tm_rowa:        .space 32 * 4     /* 15 classes + 16 interleaved BASE rows (31 used), rounded up */
tm_rowc:        .space 32 * 4
tm_bmin:        .long 0xFFFFFFFF  /* smallest BASE delta seen this run */
tm_bmax:        .long 0         /* and largest: their spread is the run's own stability check */
tm_bcount:      .word 0         /* BASE rows measured; a run with one has no spread to report */
tm_waitp:       .long 0         /* the 005F row's own delta, for the absolute scale check */
tm_scale:       .long 0         /* scratch: the scale check's own intermediate */
tm_n5:          .long 0
tm_n6:          .long 0
tm_epolls:      .long 0
tm_prev5:       .byte 0
tm_prev6:       .byte 0
tm_ed:          .long 0
tm_cpu_iters:   .long 0
tm_cpu_ad:      .long 0

/* the OPNA Timer B reference. tb_clocks is the nanoseconds in (256 - tb_nb)
 * Timer B counts: 2304 / 7.9872e6 s per count = 288462 ns, so the period is
 * TB_COUNTS * 288462 ns. */
    .equ TB_NB, 0
tb_id:          .byte 0
tb_ssg7:        .byte 0
tb_nb:          .byte TB_NB
tb_tmo:         .byte 0
tb_ok:          .byte 0
tb_novf:        .word 12            /* Timer B overflows the window counts */
tb_batch:       .word 32            /* PIT samples between two flag polls */
tb_ovf:         .word 0
tb_guard:       .word 0
tb_pv:          .word 0
tb_p0:          .word 0
tb_p1:          .word 0
    .balign 4
tb_tmax:        .long 921600        /* the window watchdog: 3 s of ARTIC ticks */
tb_clocks:      .long (256 - TB_NB) * 288462
tb_dur:         .long 0
tb_a0:          .long 0
tb_artic:       .long 0
tb_reloads:     .long 0
tb_fpit:        .long 0
tb_fartic:      .long 0
tb_nspit:       .long 0
tb_nsartic:     .long 0

cal_align:      .byte 0xFF  /* 0/4 = the payload offset; 0xFF = not yet decided */
cal_str:        .space 56   /* 52 bits as ASCII, NUL terminated */
cal_n0:         .byte 0
cal_n4:         .byte 0
cal_b0:         .byte 0
cal_b4:         .byte 0
cal_have:       .byte 0
cal_hit:        .byte 0
cal_fld0:       .space 6
cal_fld4:       .space 6
cal_f0ok:       .byte 0
cal_f4ok:       .byte 0
cal_m0:         .byte 0
cal_m4:         .byte 0
cal_a0:         .long 0
cal_ticks:      .long 0
cal_secs:       .word 5
cal_reloads:    .long 0
cal_counts:     .long 0
cal_guard:      .word 0
cal_tmax:       .long 614400    /* the liveness poll's bound */
cal_pv:         .word 0
cal_p0:         .word 0
cal_p1:         .word 0
cal_count:      .word 0
cal_tmo:        .byte 0
/* The TIMESET pattern, in wire order seconds..year: 01:05:30 on day 02, month 1
 * (weekday nibble 0), year 00. Valid BCD and non-palindromic, so a read-back
 * that matches proves the path and one that does not is visible. */
cal_setpat:     .byte 0x30, 0x05, 0x01, 0x02, 0x10, 0x00
f_pit:          .long 0
f_artic:        .long 0
ns_pit:         .long 0
ns_artic:       .long 0

/* The port classes. Each entry is {port word, kind byte, pad, label word}.
 * kind 0 = the baseline (no bus access), 1 = in al,dx, 2 = out dx,al,
 * 3 = a memory read (ES:DI, the entry's word is the segment).
 * Every read here is safe to repeat: 0043 is the 8251 status register, 043B a
 * chipset strap, 0060/00A0 the two GDC status registers, 0188/018A the sound
 * board's register-select pair (the /JOY section reads them), 064E the ATA
 * status register (never its data port), 0071 the PIT data port, 0EE0 a port
 * this machine is measured to leave open (probes/PORTS.TXT reads FF there), and
 * A000 is text VRAM - a MEMORY class, for contrast, because the RTL's wait model
 * covers both buses. 005F is the documented I/O-wait port, the one class that
 * writes: it has no state on any reference.
 *
 * THE BASELINE IS INTERLEAVED, one TM_BASE_ROW between every pair of classes and
 * one after the last, so a class's control is measured immediately beside it.
 * A single BASE row measured once at the start cannot tell "the machine warmed
 * up" from "this class is slow". The three 2026-09-14 captures show why that
 * matters: between runs the same classes moved by up to 9x while the BASE row
 * moved with them (8x), and GDC/TRAM moved by ~70x. The first is a run-varying
 * SCALE, which a ratio against an adjacent BASE cancels; the second is not, and
 * the ratio is what shows the difference. See docs/probes/README.md. */
.macro TM_BASE_ROW
    .word 0x0000
    .byte 0, 0
    .word lbl_tm_base
.endm
/* Every port iobus gives its own io_access_cycles class has a row here, so the
 * class table (0x5F=74, 0x640/0x641=30, 0x60/0x62=1006, 0xA0/0xA2=1191, default 186)
 * can be authenticated class by class. The data lane of each pair is timed too, not just
 * the status lane: 0062 and 0640/0641 are consume-on-read, but the read is harmless at an
 * idle DOS prompt (no GDC read command, no ATA transfer in flight) and no DOS call runs
 * inside the cli window. 0188/018A time the -86 sound-board ports' default class. */
tm_tab:
    TM_BASE_ROW
    .word 0x005f
    .byte 2, 0
    .word lbl_tm_wait
    TM_BASE_ROW
    .word 0x0043
    .byte 1, 0
    .word lbl_tm_sys
    TM_BASE_ROW
    .word 0x043b
    .byte 1, 0
    .word lbl_tm_chip
    TM_BASE_ROW
    .word 0x0060
    .byte 1, 0
    .word lbl_tm_gdc
    TM_BASE_ROW
    .word 0x0062
    .byte 1, 0
    .word lbl_tm_gdcd
    TM_BASE_ROW
    .word 0x00a0
    .byte 1, 0
    .word lbl_tm_gdc2
    TM_BASE_ROW
    .word 0x00a2
    .byte 1, 0
    .word lbl_tm_gdc2d
    TM_BASE_ROW
    .word 0x0188
    .byte 1, 0
    .word lbl_tm_sb
    TM_BASE_ROW
    .word 0x018a
    .byte 1, 0
    .word lbl_tm_sbj
    TM_BASE_ROW
    .word 0x0640
    .byte 1, 0
    .word lbl_tm_ided0
    TM_BASE_ROW
    .word 0x0641
    .byte 1, 0
    .word lbl_tm_ided1
    TM_BASE_ROW
    .word 0x064e
    .byte 1, 0
    .word lbl_tm_ata
    TM_BASE_ROW
    .word 0x0071
    .byte 1, 0
    .word lbl_tm_pitd
    TM_BASE_ROW
    .word 0x0ee0
    .byte 1, 0
    .word lbl_tm_open
    TM_BASE_ROW
    .word 0xa000
    .byte 3, 0
    .word lbl_tm_mem
    TM_BASE_ROW
    .word 0xFFFF

lbl_tm_base:    .asciz "BASE    "
lbl_tm_wait:    .asciz "WAIT    "
lbl_tm_sys:     .asciz "SYSTEM  "
lbl_tm_chip:    .asciz "CHIPSET "
lbl_tm_gdc:     .asciz "GDC1    "
lbl_tm_gdcd:    .asciz "GDC1DATA"
lbl_tm_gdc2:    .asciz "GDC2    "
lbl_tm_gdc2d:   .asciz "GDC2DATA"
lbl_tm_sb:      .asciz "SOUND188"
lbl_tm_sbj:     .asciz "SOUND18A"
lbl_tm_ided0:   .asciz "IDEDATA0"
lbl_tm_ided1:   .asciz "IDEDATA1"
lbl_tm_ata:     .asciz "ATA     "
lbl_tm_pitd:    .asciz "PITDATA "
lbl_tm_open:    .asciz "OPENBUS "
lbl_tm_mem:     .asciz "TRAM    "

msg_begin_time: .asciz "BEGIN:TIME\r\n"
msg_end_time:   .asciz "END:TIME\r\n"
msg_timeset_alone: .asciz "  /TIMESET does nothing on its own: it is the opt-in word for /TIMEREF (it lets\r\n  /TIMEREF write the calendar's own counters, for a machine whose backup battery is dead).\r\n"
msg_time_hdr:   .asciz "TIME: the timing ladder. Every figure is a RATIO against two counters a 486 can read: the\r\n  free-running counter at 005C (low word) / 005F (high byte; 005D and 005E mirror cnt[15:8]), and the PIT's channel 0 read\r\n  through its own counter-latch command. /TIMEREF measures both counters against the\r\n  calendar's second and converts these rows to Hz, nanoseconds and 50 MHz core cycles.\r\n"
msg_time_writes: .asciz "  READ-ONLY as far as live state goes. The only writes /TIME makes are 0077 <- 00 (the PIT\r\n  counter-latch command: it copies the counter into the latch register and changes no state,\r\n  and it is deliberately NOT in the RESTORE table, because 0077's read-back is FF and\r\n  replaying FF would write a PIT MODE word) and 005F (the documented I/O-wait port, a\r\n  write-only delay generator, recorded in RESTORE). Every other access is a read.\r\n"
msg_time_artic: .asciz "  ARTIC 005C/005F = "
msg_time_artic2: .asciz "\r\n  ARTIC again after the PIT samples below = "
msg_time_artic3: .asciz " (delta = "
msg_time_artic4: .asciz " ticks)\r\n"
msg_time_strap: .asciz "  work-area 0501 bit 7 (the byte the BIOS's own PIT setup tests at BANK7@0x5DE7) = "
msg_time_strapb: .asciz "\r\n    -> the BIOS's own divisor here is "
msg_time_div6000: .asciz "0x6000 = 24576, so it expects a 2.4576 MHz counter"
msg_time_div4e00: .asciz "0x4E00 = 19968, so it expects a 1.9968 MHz counter"
msg_time_pits:  .asciz "\r\n  PIT channel 0 latch/read, three samples = "
msg_time_pitmax: .asciz "\r\n    measured divisor = "
msg_time_pitd:  .asciz " (largest count over a 20 ms scan; mode 3 sweeps divisor..0 in steps of 2)\r\n"
msg_time_divzero: .asciz " ** the counter never changed over 20 ms: the PIT read is not working on this machine,\r\n    so every PIT column below (and in /TIMEREF) is meaningless **"
msg_divbad:     .asciz " ** PIT DIVISOR OUT OF RANGE: not a documented mode-3 count (0x6000 = 2.4576 MHz,\r\n    0x4E00 = 1.9968 MHz at BANK7@0x5DE3, so the band is 0x4000..0x7000). The xBASE\r\n    ratios below stay valid; every ABSOLUTE PIT figure is only as good as this word.\r\n    A value at the very top of the 16-bit range with the scan's pairs coherent is a\r\n    MACHINE reading to report (item 10), NOT proof the latch read is broken; a low\r\n    coherent ratio means the read tore. THE RUN EXITS 1 ON THIS EITHER WAY. **\r\n"
/* Read the divisor line's own `coherent pairs = ACC/TRY`: ACC/TRY == 1 means the
 * scan's sampled pairs agreed, so the value is what the machine returns (item 10's
 * open hardware question - the 2026-09-25 captures return ~0xFFEx, one pair-spacing
 * below a 16-bit reload), while a low ratio means the latch read itself tore. */
msg_divbad_note: .asciz "    The coherent pairs = ACC/TRY on the line above says which: ACC/TRY = 1 means the "
    .asciz "pairs agreed and the value is what the machine returns (report it, do not "
    .asciz "read it as the BIOS's divisor); a low ratio means the latch read itself tore.\r\n"
msg_time_54d:   .asciz "  work-area 054D bit 2 (the GDC clock the BIOS published: 0 = 2.5 MHz, 1 = 5 MHz) = "
msg_time_cls:   .asciz "  I/O access time: "
msg_time_clsn:  .asciz " back-to-back accesses per class, cli across each class's window, no DOS call inside it.\r\n  BASE is the same loop with the bus access replaced by a same-length register move; it is\r\n  INTERLEAVED, measured between every pair of classes, so each class's control sits beside it.\r\n  xBASE is the class's own PIT delta over that neighbouring control, as a ratio x100: a run\r\n  whose time base is wrong cancels in it, so xBASE compares between runs where nanoseconds do\r\n  not. exc_ns(pit) is the excess over the control, and carries an upper bound - a 486 cannot\r\n  separate the instruction's own cost from bus time. artic_d is printed for diagnosis only:\r\n  the ARTIC-DERIVED figure is dropped, because the ARTIC check fails on this machine and every\r\n  ARTIC-derived number from such a run is unusable (see the README). The ns columns use the\r\n  DOCUMENTED rates (PIT 2.4576 MHz); /TIMEREF measures the rate and reprints them corrected.\r\n"
msg_time_cols:  .asciz "    class    port  artic_d  pit_c    xBASE  exc_ns(pit)\r\n"
msg_time_scale: .asciz "  SCALE CHECK: the 005F wait port is the machine's documented 0.6 us - the one class\r\n  with a value known independently of this probe - so it is the run's time base. wait="
msg_time_scale2: .asciz " ns/access = "
msg_time_scale3: .asciz " percent of the documented 600 ns  (100 = agrees; the xBASE column is unaffected)\r\n"
msg_time_scalefail: .asciz "  SCALE CHECK FAIL: this run's time base is at least twice the documented 0x5F wait, so\r\n  EVERY exc_ns and cycles figure above is off by roughly that factor and must not be\r\n  quoted. Re-run before using magnitudes; the xBASE ratios still compare between runs.\r\n"
msg_time_bspread: .asciz "  SCALE CHECK (baseline): the control row was measured "
msg_time_bspread2: .asciz " times; largest/smallest = "
msg_time_bspread3: .asciz " percent  (100 = the run was steady)\r\n"
msg_time_bsfail: .asciz "  SCALE CHECK FAIL (baseline): the control row moved by 2x or more WITHIN this run, so\r\n  this run has no usable scale at all, whatever the ratios say. Do not quote it.\r\n"
msg_tm_dashes:  .asciz "----"
msg_time_latch: .asciz "  note: /TIME issued the PIT counter-latch command (0077 <- 00) without a restore entry:\r\n        it changes no state, and replaying 0077's read-back (FF) would write a PIT mode word.\r\n"
msg_time_raster: .asciz "  raster: 00A0 polled in a tight loop for "
msg_time_raster2: .asciz " ARTIC ticks:\r\n"
msg_time_rast5:  .asciz "    bit5 rising edges = "
msg_time_rast6:  .asciz " ; bit6 rising edges = "
msg_time_rastd:  .asciz " ; polls = "
msg_time_rastd2: .asciz "\r\n    (00A0 is the graphics GDC's status register; the machine's own GDC.TXT histogram has bit5\r\n     high 1.7% of the time and bit6 23.4%, so one of these rates is a vertical sync pulse and\r\n     the other a horizontal blanking interval - the rates themselves say which.)\r\n"
msg_time_cpu:   .asciz "  CPU loop rate: a loop of four 1-byte adds, dec and jnz (six instructions, no memory write)\r\n  repeated in 4096-iteration batches:\r\n    iterations = "
msg_time_cpu2:  .asciz " ; ARTIC ticks = "
msg_time_cpu3:  .asciz "\r\n    (an EFFECTIVE rate, not a clock: the 486's own instruction timing and any wait states are\r\n     inside it. The body is listed in tools/hwprobe/README.md.)\r\n"

msg_begin_timeref: .asciz "BEGIN:TIMEREF\r\n"
msg_end_timeref:   .asciz "END:TIMEREF\r\n"
msg_timeref_hdr:   .asciz "TIMEREF: the calendar (uPD4990A) as an absolute reference. Its 32.768 kHz crystal is\r\n  independent of the PIT's oscillator, whose value - 2.4576 MHz or 1.9968 MHz, 23% apart - is an\r\n  unmeasured premise (r12/02 P1-4) that every time base in this core inherits. This section\r\n  writes the calendar's command latch at 0020 exactly as the ITF's own INT 1Ah reader does\r\n  (BANK7@0x5D22: TIMEREAD, SHIFT, then clocks on 0033 bit 0, leaving the latch at 07); it\r\n  writes the calendar's COUNTERS only when /TIMESET is given. cli covers each bit sequence.\r\n"
/* The OPNA Timer B reference, printed by /TIMEREF before the calendar block. It
 * is the RTC-independent absolute reference this machine needs. */
msg_tb_hdr:     .asciz "  OPNA Timer B (the PC-9801-86 YM2608) - the RTC-independent reference. The machine's\r\n  calendar does not run, so Timer B is the independent clock. Register sequence (NP2kai\r\n  cbus/board86.c): 0188 <- 26 ; 018A <- NB (period); 0188 <- 27 ; 018A <- 2a (bit1 run B,\r\n  bit3 IRQ B enable - the flag reads only while it is on - and bit5 clear flag B); 0188 read\r\n  bit1 = flag B; 0188 <- 27 ; 018A <- 30 (stop+clear).\r\n  Period = (256-NB) * 2304 / 7987200 s = 288.46 us per count.\r\n"
msg_tb_id:      .asciz "    018A with 0188=ff (the -86 chip ID, expect 01) = "
msg_tb_ssg:     .asciz " ; SSG reg 7 (expect bf) = "
msg_tb_id_unread: .asciz "    -> 018A does not answer the -86 chip ID (01). R10.TXT /PORTS still sees a device at the\r\n       0188/018A pair, so this is \"the chip-ID register is not readable\", NOT \"no card\": the\r\n       Timer B period window below is measured regardless, and its flag B decides.\r\n"
msg_tb_per:     .asciz "    Timer B: NB="
msg_tb_per2:    .asciz " ; flag B overflows counted = "
msg_tb_per3:    .asciz " ; window = "
msg_tb_ns:      .asciz " ns at the documented 7.9872 MHz OPNA clock\r\n"
msg_tb_dead:    .asciz "    -> the flag never moved: Timer B is not running (no -86 card, or its timer is dead),\r\n       so this machine has no absolute time reference.\r\n"
msg_tb_ran:     .asciz "    -> the flag moved: Timer B is RUNNING, and its period is the absolute reference below.\r\n"
msg_tb_fpit:    .asciz "    RESULT (measured against Timer B, not the calendar's second):\r\n      PIT channel-0 oscillator = "
msg_tb_fpit2:   .asciz " Hz  [divisor "
msg_tb_fartic:  .asciz "]\r\n      ARTIC 005c/005f counter = "
msg_tb_fartic2: .asciz " Hz  [documented 307200; this measurement is "
msg_tb_fartic3: .asciz " per-mille off it]\r\n      1 PIT count = "
msg_tb_nspit:   .asciz " ns ; 1 ARTIC tick = "
msg_tb_nsartic: .asciz " ns\r\n"
msg_tr_tbfallback: .asciz "    -> the calendar is dead, so the DERIVED rows below use the Timer B rates measured above.\r\n"
msg_tr_latch:   .asciz "  note: /TIMEREF wrote the calendar's command latch at 0020 and left it at 07, the state\r\n        the ITF's own reader leaves (BANK7@0x5D5A). It is not in the restore table because\r\n        0020's read-back is FF and replaying FF would pulse STB with DATA=1 - a command.\r\n        It also wrote the OPNA timer registers 0188 <- 26 / 018A <- NB and 0188 <- 27 /\r\n        018A <- 30 (Timer B stopped, flags cleared). NP2kai's board model does not read those registers back,\r\n        so they cannot be restored; a DOS prompt leaves the card's timers stopped anyway.\r\n"
msg_tr_mode:    .asciz "  0022 mode latch (first touch) = "
msg_vs_latch:   .asciz "  note: /VSYNC's only latch write is the master IMR (0002): bit 2 was cleared for the\r\n        window and put back from the save, so it is the first row of this table. Its other\r\n        writes are stateless and are not replayed: 0064 (the one-shot VSYNC IRQ arm) and\r\n        0000 <- 0x62 (the master specific EOI for level 2 - write-only, and an EOI to nothing\r\n        is a no-op). The handler's re-arm is cleared before the release EOI (vs_rearm), so\r\n        the last arm fires inside the window; the extra edge taken before the masked IMR\r\n        goes back can only consume a request the machine kept, and nothing is left armed.\r\n        It also writes its own memory: the load phase's two 1 KiB buffers\r\n        (vs_load_src/vs_load_dst) inside this program's PSP block - no machine latch and no\r\n        VRAM/TRAM cell. INT 0Ah is restored and read back.\r\n"
msg_tr_128:     .asciz "  0128 = "
msg_tr_128b:    .asciz " (calendar tick rate, 0x80|rate; this read also clears a pending tick)\r\n"
msg_tr_read1:   .asciz "  full read: 52 bits from 0033 bit 0, then the six fields decoded both ways - the uPD4993A\r\n  four-bit prefix question (r6/08 C19) is what separates the two lines:\r\n    "
msg_tr_at0:     .asciz "    payload at bit 0: "
msg_tr_at4:     .asciz "\r\n    payload at bit 4: "
msg_tr_set:     .asciz "  /TIMESET given: writing the calendar's own counters with the ITF's own sequence\r\n  (BANK7@0x5D62: opcode 1, 48 data bits, opcode 2 time set, opcode 0 hold) ...\r\n"
msg_tr_set2:    .asciz "  NOTE: RTC counters set to 01:05:30 on day 02, month 1, year 00 - NOT RESTORABLE. To put\r\n        the machine's clock back: TIME 01:05:30 and then DATE.\r\n  set read-back: "
msg_tr_setat0:  .asciz "    payload at bit 0: "
msg_tr_setat4:  .asciz "\r\n    payload at bit 4: "
msg_tr_match:   .asciz "  fields matching the written pattern (bit0/bit4) = "
msg_tr_match2:  .asciz " of 6\r\n"
msg_tr_set_nomatch: .asciz "  WARNING: neither decoding equals the pattern written, so the set did not take or the\r\n  hardware's payload is neither of these alignments; the ticking test below still decides.\r\n"
msg_tr_align_none: .asciz "  (no /TIMESET: the payload alignment is left to the ticking test itself)\r\n"
msg_tr_align:   .asciz "  seconds-field alignment = "
msg_tr_align_0: .asciz "payload at bit 0 (no prefix)"
msg_tr_align_4: .asciz "payload at bit 4 (four-bit prefix present)"
msg_tr_align_unk: .asciz "UNDECIDED (run /TIMEREF /TIMESET, or repeat)"
msg_tr_live:    .asciz "  liveness: polling the seconds field for up to 2 s of ARTIC ticks ...\r\n"
msg_tr_live_ok: .asciz "    -> the seconds field CHANGED: the calendar's counters are RUNNING, so its second is an absolute reference.\r\n"
msg_tr_dead:    .asciz "    -> the seconds field did NOT move: the calendar's counters are not running (a dead backup\r\n       battery, or counters left held). The OPNA Timer B block above is the fallback reference\r\n       when it ran; /TIMEREF /TIMESET writes a known time into the calendar's counters, which is\r\n       not restorable.\r\n"
msg_tr_sync:    .asciz "  synchronised to a seconds-field change; the field reads "
msg_tr_win:     .asciz "  window: counting "
msg_tr_win2:    .asciz " calendar seconds, with the PIT counter sampled between every pair of seconds reads\r\n  (32 samples per read, ~70 us apart - one reload is ~10 ms, so every reload is seen) ...\r\n"
msg_tr_wline:   .asciz "    seconds="
msg_tr_wart:    .asciz " ; ARTIC ticks="
msg_tr_wrel:    .asciz " ; PIT reloads="
msg_tr_wcnt:    .asciz " ; PIT oscillator counts="
msg_tr_wdiv:    .asciz " ; divisor="
msg_tr_res:     .asciz "  RESULT (measured against the calendar's second, not assumed):\r\n"
msg_tr_fpit:    .asciz "    PIT channel-0 oscillator = "
msg_tr_fpit2:   .asciz " Hz  [divisor "
msg_tr_fpit3:   .asciz " counts; the documented values are 2457600 and 1996800, 23% apart]\r\n"
msg_tr_fartic:  .asciz "    ARTIC 005C/005F counter  = "
msg_tr_fartic2: .asciz " Hz  [documented 307200; this measurement is "
msg_tr_fartic3: .asciz " per-mille off it]\r\n"
msg_tr_nst:     .asciz "    1 ARTIC tick = "
msg_tr_nst2:    .asciz " ns ; 1 PIT count = "
msg_tr_nst3:    .asciz " ns\r\n"
msg_tr_warn:    .asciz "    WARNING: the ARTIC rate is not within 30% of the documented 307200 Hz. Either the ARTIC is\r\n    not that counter, or the field being counted is not a one-second field (a four-bit-shifted\r\n    field advances once per 10 s). Quote the PIT line, which uses no ARTIC, and re-run with\r\n    /TIMESET if the alignment is in doubt.\r\n"
msg_tr_der:     .asciz "  DERIVED from /TIME's own rows, with the MEASURED PIT rate substituted (this is the column\r\n  the RTL's IO_ACCESS_CYCLES parameter wants - core cycles at 50 MHz, one cycle = 20 ns):\r\n"
msg_tdr_ns:     .asciz ": "
msg_tdr_cyc:    .asciz " ns = "
msg_tdr_cycend: .asciz " cycles @50MHz"
msg_tr_ras:     .asciz "    raster (from /TIME's edge counts, with the measured ARTIC rate):\r\n"
msg_tr_ras5:    .asciz "      00A0 bit5 = "
msg_tr_ras6:    .asciz " Hz ; bit6 = "
msg_tr_rasend:  .asciz " Hz\r\n    (one of the two is the vertical rate and the other the horizontal: the values say which.)\r\n"
msg_tr_cpu:     .asciz "    CPU: the /TIME baseline loop = "
msg_tr_cpuend:  .asciz " iterations/s\r\n"
msg_tr_norows:  .asciz "  DERIVED: /TIME did not run in this invocation, so there are no rows to convert.\r\n  Run PROBE2 /TIME /TIMEREF.\r\n"
msg_tr_notes:   .asciz "  notes: the PIT line is the strong one - it uses no CPU timing, only the PIT reload count,\r\n  the divisor and the reference period (the calendar's second, or the Timer B block above when\r\n  the calendar is dead). If the ARTIC line disagrees with the documented 307200 Hz, the ARTIC\r\n  is not the clean timestamp source the tree's other reports assume, and the PIT-derived\r\n  columns are the ones to quote. The CPU line is an effective rate, not a clock.\r\n"

msg_cf_sec:     .asciz "sec="
msg_cf_min:     .asciz " min="
msg_cf_hour:    .asciz " hour="
msg_cf_day:     .asciz " day="
msg_cf_mon:     .asciz " mon/wday="
msg_cf_year:    .asciz " year="
msg_cf_ok:      .asciz "  (valid BCD)"
msg_cf_bad:     .asciz "  (NOT valid BCD - the counters were never set, or the other alignment is the real one)"

/* r13/hwprobe-followups: /RDBACK, /PIT, /VSYNC */
msg_begin_rdback: .asciz "BEGIN:RDBACK\r\n"
msg_rdback_hdr:   .asciz "  write-then-read round-trips. port=addr before=XX wrote=YY after=ZZ back=WW\r\n  (back is the re-read after the original byte was put back; after==back proves restore for\r\n  a latch, and a strap/constant port shows after==back==strap.)\r\n"
msg_end_rdback:   .asciz "END:RDBACK\r\n"
msg_rb2_mode:     .asciz "  mode bytes (0068 FF1, 006A FF2) = "
msg_rb2_port:     .asciz "  port="
msg_rb2_before:   .asciz " before="
msg_rb2_wrote:    .asciz " wrote="
msg_rb2_after:    .asciz " after="
msg_rb2_back:     .asciz " back="
msg_rb2_19:       .asciz "  0019 clear-byte-pointer before/after = "
msg_rb2_29:       .asciz "  0029 bound selector before="
msg_rb2_29c:      .asciz " after 04/08/0C = "
msg_rb2_43d_before: .asciz "  043D strap before = "
msg_rb2_43d_hdr:  .asciz "  043D wrote=V -> F8000:0000=XX (bank byte):\r\n"
msg_rb2_43d_wrote: .asciz "    043D wrote="
msg_rb2_43d_f8:   .asciz " F8000:0000="
msg_rb2_43d_restored: .asciz "  043D restored with (search) = "
msg_rb2_m_hdr:    .asciz "  GDC master 0x62 LPEN: 0060 status before arm = "
msg_rb2_m_st1:    .asciz " ; after arm = "
msg_rb2_m_pops:   .asciz " ; 0062 pops = "
msg_rb2_s_hdr:    .asciz "  GDC slave 0xA2 CSRR: 00A0 status before arm = "
msg_rb2_s_st1:    .asciz " ; after 0xE0 arm = "
msg_rb2_s_pops:   .asciz " ; 00A2 pops = "
msg_rb2_s_st2:    .asciz "  GDC slave 0xA2 LPEN: 00A0 status after 0xC0 arm = "

msg_begin_pitsec: .asciz "BEGIN:PIT\r\n"
msg_pitsec_hdr:   .asciz "  PIT (uPD71054 at 0071/0073/0075/0077) read byte-phase and byte-only count writes.\r\n  Note: the PC-9821 PIT data ports are 0071/0073/0075, NOT the IBM-PC 0040-0042 set.\r\n"
msg_pitsec_swap:  .asciz "  calibration: 0071 returns "
msg_pitsec_swap2: .asciz " first (0 = low byte first, 1 = high byte first).\r\n"
msg_pitsec_swap3: .asciz "  calibration after the half word read (the raw read moved the phase): 0071 returns "
msg_pitsec_n1:    .asciz "  latch after a half word read (one byte consumed from the measured phase): first/second = "
msg_pitsec_div:   .asciz "  measured channel-0 divisor = "
msg_pitsec_divslash: .asciz "/"
msg_pitsec_divacc: .asciz " coherent pairs = "
msg_pitsec_cw:    .asciz "  after control word 0036 + same divisor (does it reset phase?): first/second = "
msg_pitsec_lsb:   .asciz "  LSB-only control 0014 + write 56, latched pair = "
msg_pitsec_msb:   .asciz "  MSB-only control 0024 + write 56, latched pair = "
msg_pitsec_restored: .asciz "  channel 0 restored to mode-3 word at the STRAP divisor "
msg_pitsec_restored2: .asciz " (work-area 0501 bit 7 ->
    0x6000/0x4E00), never the measured value: the measured divisor can be a tear. The
    DOS tick is back to the BIOS's rate.\r\n"
msg_pitsec_skip:  .asciz "  -> the divisor scan was not coherent, or failed the mode-3 range check;\r\n     skipping the reprogramming tests. Experiment 2 is the one write here that stops the\r\n     DOS tick (cli) and loads channel 0 with the MEASURED divisor, so it stays gated on a\r\n     scan that is coherent AND in range: a torn word must never be written back. The exit\r\n     code and the RUN FAILED line at the end still stand - they mark the time base.\r\n"
msg_end_pitsec:   .asciz "END:PIT\r\n"

msg_begin_vsyncsec: .asciz "BEGIN:VSYNC\r\n"
msg_vsyncsec_hdr: .asciz "  VSYNC/IRQ2 delivery and the dropped-frame count f_drop. Clears master IMR bit 2 (IRQ2)\r\n  for the window, puts it back from the save, and restores INT 0Ah. Its own boot: it\r\n  reprograms interrupt state. sync_irqs=1 (the sync edge) is normal, 2 means a driver\r\n  had a request latched when the mask cleared.\r\n"
msg_vsyncsec_af64:  .asciz "  as-found 0064="
msg_vsyncsec_064:   .asciz " 0064="
msg_vsyncsec_afimr: .asciz " imr="
msg_vsyncsec_bit2m: .asciz " bit2=1(masked)"
msg_vsyncsec_bit2u: .asciz " bit2=0(unmasked)"
msg_vsyncsec_afpic: .asciz " 0000="
msg_vsyncsec_afv:   .asciz " int0ah="
msg_vsyncsec_colon: .asciz ":"
msg_vsyncsec_win:   .asciz "  window imr="
msg_vsyncsec_rb:    .asciz " readback="
msg_vsyncsec_winok: .asciz " (bit2 clear -> IRQ2 unmasked)"
msg_vsyncsec_winbad: .asciz " ** READBACK MISMATCH: the window mask did not take - do not trust the counts below **\r\n"
msg_vsyncsec_stale: .asciz " sync_irqs="
msg_vsyncsec_A:     .asciz "  VA idle  frames="
msg_vsyncsec_B:     .asciz "  VB load  frames="
msg_vsyncsec_C:     .asciz "  VC hold  edges="
msg_vsyncsec_irqs:  .asciz " irqs="
msg_vsyncsec_delta: .asciz " delta="
msg_vsyncsec_pre:   .asciz " irqs_pre_eoi="
msg_vsyncsec_post:  .asciz " irqs_post_eoi="
msg_vsyncsec_next:  .asciz " irqs_next_edge="
msg_vsyncsec_timeout: .asciz "TIMEOUT (no edge inside the bound - is the raster stopped?)"
msg_vsyncsec_after: .asciz "  after: imr="
msg_vsyncsec_interpret:
    .asciz "  -> VA is the baseline with IRQ2 unmasked: delta=+0 is the 1:1 delivery, one INT 0Ah per\r\n"
    .asciz "     polled 0xA0 edge. A VA delta of -1 is one frame not delivered (the dropped-frame f_drop =\r\n"
    .asciz "     -delta/frames); a lone -1 can also be the last edge's delivery landing just after the\r\n"
    .asciz "     count read. A +1 has no mechanism here (it would need a delivered edge the poll did not\r\n"
    .asciz "     count) - report it rather than reading it as noise. VB repeats VA with a bounded memory\r\n"
    .asciz "     burst between polls, so its delta is f_drop under load.\r\n"
    .asciz "     VC is the forced edge-during-in-service case: the handler counts and re-arms 0064 but\r\n"
    .asciz "     sends no EOI, so the sync edge leaves IRQ2 in service while the main loop counts the\r\n"
    .asciz "     edges that arrive inside that window. One EOI releases it, and because the handler is\r\n"
    .asciz "     no longer arming 0064 by then, what the NEXT edge delivers can only be a request the\r\n"
    .asciz "     machine itself kept. With pre=0:\r\n"
    .asciz "       post = pre+1 and next = post   -> HELD: the 8259's one-bit IRR retained the edge and\r\n"
    .asciz "                                         the EOI delivered it (this core's ir_latch model).\r\n"
    .asciz "       post = pre   and next = post+1 -> NOT delivered at the EOI but deferred to the next\r\n"
    .asciz "                                         frame: exactly NP2kai (its in-service arm is a\r\n"
    .asciz "                                         SIBLING of the imr test, io/pic.c:254-259, and\r\n"
    .asciz "                                         re-arms gdc.vsyncint; pccore.c:1633-1636/:1647-1649).\r\n"
    .asciz "       post = pre   and next = post   -> the edge never came back at all. Re-run a 0/0/0 before\r\n"
    .asciz "                                         reading it as a genuine discard: the next-edge count is\r\n"
    .asciz "                                         taken ~150 us (VS_SETTLE) after the polled rise, so a\r\n"
    .asciz "                                         deferral slower than that would look the same.\r\n"
    .asciz "       post = pre+1 and next = post+1 -> delivered AT the EOI and a SECOND delivery at the next\r\n"
    .asciz "                                         edge: report it - no write in this section can arm 0064\r\n"
    .asciz "                                         by then, so both deliveries are the machine's.\r\n"
    .asciz "     pre > 0 is its own finding: the machine delivers in-service edges with no EOI, one per\r\n"
    .asciz "     window edge (pre = VS_HOLD_EDGES would be no in-service blocking at all) - read the tail\r\n"
    .asciz "     only when pre = 0. VA and VB irqs=0 with the readback line showing bit 2 clear means\r\n"
    .asciz "     IRQ2's delivery path is not the mask - send the capture and say so. next_edge=TIMEOUT\r\n"
    .asciz "     means no VSYNC edge arrived inside the bound (VS_EDGE_TIMEOUT) - report the raster state;\r\n"
    .asciz "     the IMR and the vector were still restored.\r\n"
msg_end_vsyncsec: .asciz "END:VSYNC\r\n"

/* /RDBACK variables */
rb2_port:       .word 0
rb2_after:      .byte 0
rb2_back:       .byte 0
rb2_68:         .byte 0
rb2_6a:         .byte 0
rb2_19_before:  .byte 0
rb2_19_after:   .byte 0
rb2_29_before:  .byte 0
rb2_29_a:       .byte 0
rb2_29_b:       .byte 0
rb2_29_c:       .byte 0
rb2_43d_before: .byte 0
rb2_f8_before:  .byte 0
rb2_43d_cand:   .byte 0
rb2_43d_n:      .word 0
rb2_43d_restored: .byte 0
rb2_43d_cands:  .byte 0x00, 0x02, 0x18, 0x10, 0x12, 0xFF
rb2_43d_res:    .space 5 * 2
rb2_m_st0:      .byte 0
rb2_m_st1:      .byte 0
rb2_m_b0:       .byte 0
rb2_m_b1:       .byte 0
rb2_m_b2:       .byte 0
rb2_s_st0:      .byte 0
rb2_s_st1:      .byte 0
rb2_s_st2:      .byte 0
rb2_s_e0b0:     .byte 0
rb2_s_e0b1:     .byte 0
rb2_s_e0b2:     .byte 0
rb2_s_e0b3:     .byte 0
rb2_s_e0b4:     .byte 0
rb2_s_c0b0:     .byte 0
rb2_s_c0b1:     .byte 0
rb2_s_c0b2:     .byte 0

/* /PIT variables */
p2_div:         .word 0
p2_strap:       .word 0     /* the strap-derived divisor the restore writes */
p2_n1_b1:       .byte 0
p2_n1_b2:       .byte 0
p2_cw_b1:       .byte 0
p2_cw_b2:       .byte 0
p2_lsb_b1:      .byte 0
p2_lsb_b2:      .byte 0
p2_msb_b1:      .byte 0
p2_msb_b2:      .byte 0

/* /VSYNC variables */
vs_used:        .byte 0     /* sec_vsync ran: gates the footer's ledger paragraph */
vs_64:          .byte 0
vs_64_after:    .byte 0
vs_imr:         .byte 0     /* as-found master IMR (0002) */
vs_imr_win:     .byte 0     /* IMR written for the window: as-found with bit 2 cleared */
vs_imr_back:    .byte 0     /* read-back right after that write */
vs_imr_final:   .byte 0     /* read-back after the inline restore */
vs_00:          .byte 0     /* 0000 as found: IRR with the default OCW3, ISR if RIS is set */
vs_00_after:    .byte 0
vs_old_off:     .word 0
vs_old_seg:     .word 0
vs_new_off:     .word 0     /* the vector read back after the restore */
vs_new_seg:     .word 0
vs_count:       .word 0
vs_frames:      .word 0
vs_noeoi:       .byte 0     /* 1 = the handler leaves IRQ2 in service (phase C) */
vs_rearm:       .byte 0     /* 0 = the handler does not re-arm 0064 (arm consume) */
vs_stale:       .word 0     /* deliveries drained between the mask write and phase A */
vs_cntA:        .word 0
vs_frA:         .word 0
vs_cntB:        .word 0
vs_frB:         .word 0
vs_edC:         .word 0     /* edges counted inside the in-service window */
vs_preC:        .word 0     /* deliveries before the releasing EOI */
vs_postC:       .word 0     /* deliveries after it (at the EOI) */
vs_nextC:       .word 0     /* deliveries at the next edge (a deferral shows here) */
vs_next_to:     .byte 0     /* that edge wait expired (vs_wait_edge_to) */
    .balign 2
vs_load_src:    .space VS_LOAD_WORDS * 2
vs_load_dst:    .space VS_LOAD_WORDS * 2

/* ------------------------------------------------------------------ */
/* /WIPE data                                                          */
/* ------------------------------------------------------------------ */
wp_used:        .byte 0     /* sec_wipe ran: gates the footer's ledger paragraph */
wp_68_was:      .byte 0     /* MODE FF1 as found (text mode: DISP clear) */
wp_68_mode:     .byte 0     /* MODE FF1 as the mode set left it (DISP set) */
wp_68_blank:    .byte 0     /* the blank arm's byte (DISP cleared) */
wp_6a_was:      .byte 0
wp_7c_was:      .byte 0     /* GRCG mode as found */
wp_a4_was:      .byte 0     /* display page as found (recorded, not replayed) */
wp_a6_was:      .byte 0     /* access page as found (recorded, not replayed) */
wp_imr_was:     .byte 0
wp_imr_win:     .byte 0     /* as-found with bit 2 cleared */
wp_imr_back:    .byte 0
wp_imr_final:   .byte 0
wp_irq_on:      .byte 0     /* 1 = do not cli/sti around the arm (W4's live arms) */
wp_irq_bad:     .byte 0     /* wp_irq_begin found no edge: the W4C arm was skipped */
wp_rearm:       .byte 0
wp_noeoi:       .byte 0
wp_stat_prev:   .byte 0     /* the previous 0xA0 byte, for W5's edge detection */
    .balign 2
wp_old_off:     .word 0
wp_old_seg:     .word 0
wp_new_off:     .word 0
wp_new_seg:     .word 0
wp_t0:          .long 0
wp_t1:          .long 0
wp_t2:          .long 0
wp_t3:          .long 0
wp_d_fill:      .long 0
wp_d_rows:      .long 0
wp_d_flip:      .long 0
wp_d_tot:       .long 0
wp_irqs:        .long 0
wp_lines:       .long 0
wp_acc:         .long 0     /* the row body's 32-bit result (a real store, as the game writes it) */
wp_i:           .word 0
wp_r:           .word 0
wp_idx:         .word 0
wp_frames:      .word 0
wp_arm_id:      .word 0
wp_mode_id:     .word 0
wp_pg_a4:       .word 0
wp_pg_a6:       .word 0
wp_div:         .word WIPE_DIV
wp_arm_tab:     .word s_arm_w2, s_arm_w3, s_arm_w3b, s_arm_w4a, s_arm_w4b, s_arm_w4c
wp_mode_tab:    .word s_mode_on, s_mode_blk, s_mode_on2, s_mode_masked, s_mode_normal, s_mode_irq2
wp_tile:        .byte 0xFF, 0xFF, 0xFF, 0xFF
    .balign 2
wp_src:         .space WIPE_BLIT_WORDS * 2
wp_tab:         .space 256  /* the row body's DS table lookup (the game's [di+0x3c6c]) */

msg_begin_wipe:  .asciz "BEGIN:WIPE\r\n"
msg_end_wipe:    .asciz "END:WIPE\r\n"
msg_w_intro:     .asciz "WIPE: the C-Lab logo's 99-step wipe, replicated in the game's 640x400 mode\r\nWIPE: (CS:0x2C0; the probe source header lists the shapes and every deviation)\r\n"
msg_w_hyp1:      .asciz "WIPE HYP W1: a known instruction mix gives ns/iteration, so the CPU term is MEASURED not derived\r\n"
msg_w_hyp2:      .asciz "WIPE HYP W2: the replica prices the machine's per-step work; the core twin is 22508 clk_sys = 450.16 us\r\n"
msg_w_hyp3:      .asciz "WIPE HYP W3: blanking the display (0x68 DISP) removes GVRAM fetch contention; the difference IS its cost\r\n"
msg_w_hyp4:      .asciz "WIPE HYP W4: a VSYNC IRQ2 landing inside a step is real machine time the core may deliver differently\r\n"
msg_w_hyp5:      .asciz "WIPE HYP W5: the 0xA0 bit-5 period and the line count decide the vertical total; y=525 makes the logo 5.94 s not 4.98 s\r\n"
msg_w_hyp6:      .asciz "WIPE HYP W6: the mode set's AH=41h/42h/40h is the largest priced non-wipe term (0x5F = 1621 ns vs 600 ns in the core)\r\n"
msg_w_anchor:    .asciz "WIPE ANCHOR ARTIC=307200 (3255.208 ns/tick, 162.7604 clk50/tick); core frame = 5445 ticks / 440 lines (FLIP.TXT)\r\n"
msg_w_asfound:   .asciz "WIPE ASFOUND "
msg_w_restore:   .asciz "WIPE RESTORE "
msg_w_restvec:   .asciz "WIPE RESTVEC "
msg_w_w1:        .asciz "WIPE W1 "
msg_w_mixalu:    .asciz "MIX=alu "
msg_w_mixrow:    .asciz "MIX=rowbody "
msg_w_mixrowg:   .asciz "MIX=rowbody-gfx "
msg_w_w1a:       .asciz "OPS=6 "
msg_w_iters:     .asciz "ITERS="
msg_w_artic:     .asciz " ARTIC="
msg_w_w6:        .asciz "WIPE W6 CALL="
msg_w_w3blk:     .asciz "WIPE W3 DISPLAY "
msg_w_w3unblk:   .asciz "WIPE W3 DISPLAY "
msg_w_blankarrow: .asciz " -> blank "
msg_w_readback:  .asciz " readback="
msg_w_w5:        .asciz "WIPE W5 "
msg_w_frames:    .asciz "FRAMES="
msg_w_lines:     .asciz " LINES="
msg_w_step:      .asciz "WIPE STEP ARM="
msg_w_mode:      .asciz " MODE="
msg_w_idx:       .asciz " IDX="
msg_w_fill:      .asciz " FILL="
msg_w_rows:      .asciz " ROWS="
msg_w_flip:      .asciz " FLIP="
msg_w_total:     .asciz " TOTAL="
msg_w_w4imr:     .asciz "WIPE W4 IMR "
msg_w_w4win:     .asciz " window="
msg_w_w4done:    .asciz "WIPE W4 IMR restored "
msg_w_now:       .asciz " now="
msg_w_vec:       .asciz " vector="
msg_w_irqs:      .asciz " IRQS="
msg_w_colon:     .asciz ":"
s_w6_41:         .asciz "41"
s_w6_42:         .asciz "42"
s_w6_6a:         .asciz "6a"
s_w6_40:         .asciz "40"
s_w6_41r:        .asciz "41R"
s_w6_0cr:        .asciz "0CR"
s_arm_w2:        .asciz "W2"
s_arm_w3:        .asciz "W3"
s_arm_w3b:       .asciz "W3B"
s_arm_w4a:       .asciz "W4A"
s_arm_w4b:       .asciz "W4B"
s_arm_w4c:       .asciz "W4C"
s_mode_on:       .asciz "disp-on"
s_mode_blk:      .asciz "disp-blank"
s_mode_on2:      .asciz "disp-on2"
s_mode_masked:   .asciz "irq-masked"
s_mode_normal:   .asciz "irq-normal"
s_mode_irq2:     .asciz "irq2-unmasked"
msg_wp_latch:    .asciz "  note: /WIPE's ledger rows are 0068 (the blank arm's DISP clear, put back from the\r\n        mode-set byte through note_restore), 006A (analog 16-colour), 007C (the GRCG mode:\r\n        written 0xC0/0x00 every step, left at the as-found byte with the GRCG off) and, for\r\n        W4C only, master IMR 0002 through write_byte (bit 2 cleared for the window, put back\r\n        from the save). Its stateless writes are NOT replayed: 007E x404 per arm (the GRCG\r\n        tile datum - left loaded and inert with 007C = 0, as the game leaves it), 0064 (the\r\n        one-shot VSYNC arm, re-armed by wp_isr and consumed by the bounded extra edge before\r\n        the restore) and 0000 <- 0x62 (the master specific EOI for level 2). 0xA4/0xA6 are\r\n        left at 0 by the graphics-probe convention (their as-found bytes are in the ASFOUND\r\n        row; they are not state this probe claims to restore). The video mode goes back with\r\n        the BIOS's own AH=41h + AH=0Ch pair. It writes GVRAM (scribbled by design), the GRCG\r\n        tile registers and this program's own PSP block (wp_src/wp_tab/wp_acc). INT 0Ah is\r\n        restored and read back.\r\n"

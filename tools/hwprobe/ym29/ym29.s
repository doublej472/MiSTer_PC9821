/* ym29.s (v3) - does YM2608 register 0x29 (the IRQ enable) gate the Timer A and Timer B
 * interrupts, bit by bit?
 *
 * v1 (Timer A only, 0x29 in {1F, 03, 02, 00}) read NO-GATE on the Xe10 with its -86 board
 * (docs/probes/YM29-XE10.TXT): 21 Timer A interrupts per window at 0x29 = 00, like 1F. v2
 * adds Timer B and 0x29 = 01, so each bit is tested against each timer on its own: bit 0
 * against Timer A (0x29 = 02 and 00 clear it) and bit 1 against Timer B (01 and 00 clear
 * it), the other timer's bit set beside it as the control (03, 02, 01). v1's IRQ/POLL lines
 * are unchanged (they are Timer A); Timer B prints IRQB/POLLB lines of the same layout.
 *
 *   YM29 > YM29.TXT          (or RUNYM29.BAT)
 *
 * WHY. NEC's PC-9801-86 SOUND.ROM (the sound BIOS at 0xCC000) clears every OPNA register
 * from 0x00 to 0xB1 in its music init, 0x29 included (0x29 <- 00), then starts Timer A
 * (0x27 <- 0F), unmasks IRQ12 and waits for the Timer A interrupt. Cybernetic Hi-School's
 * opening (B:O.EXE) calls that init, and on the core it never gets the interrupt: the
 * screen stays black (the Xe10 answered NO-GATE: docs/probes/YM29-XE10.TXT). The references disagree on whether 0x29 = 00 stops
 * a Timer A/B interrupt:
 *   YM2608-LLE fmopna_impl.c (die level): `reg_irq[0] = (data_bus2 & 31) ^ 31` on a 0x29
 *     write (data_bus2 is the inverted bus, so reg_irq = data & 31), reset 31; the IRQ pin
 *     pulls for Timer A only `if (chip->reg_irq[1] & 1)`. 00 stops it.
 *   qemu-pc98 hw/audio/fmopn.c YM2608IRQMaskWrite: irqmask = v & 0x1f, reset 0x1f. Stops it.
 *   MAME ymfm ymfm_opn.cpp ym2608::write_data: m_irq_enable = data, reset 0x1f. Stops it.
 *   NP2kai sound/opntimer.c fmport_a: only 0x27 bit 2 gates the request. Does NOT stop it.
 *   The core (src/opna/jt12/hdl/jt12_top.v irq_n, irq_mask from jt12_mmr.v REG_IRQMASK)
 *     follows the die: 00 stops it.
 * This probe asks the machine.
 *
 * METHOD. The board is found as xe10t's /OPNA2 finds it: the status at 0x188 and 0x288
 * (0xFF = nothing there), then register 0xFF (the chip ID: YM2608 01, YMF288 02, a YM2203
 * answers no ID) and the 0x0E/0x0F/0x29 data-port reads of each answering base. The first
 * base whose ID reads 01 is tested (else the first answering base, with a NOTE). 0xA460 is
 * read, never written: the extension stays as found, as it is when SOUND.ROM runs.
 * TIMER B (v2): NB = 0xE0, 32 counts; a Timer B count is 16 Timer A counts (ymfm
 * ymfm_fm.ipp: Timer B is clocked every 16th Timer A tick; NP2kai sound/opntimer.c
 * set_fmtimerbevent `(256 - reg[0x26]) * 1152` against Timer A's `(1024 - NA) * 72`), so
 * NB = 0xE0 gives the same 512-unit period as NA = 0x200 (~9.5 ms) and the same ~21 counts
 * per window. Timer B starts with 0x27 <- 0A (load + enable B), its flag (status bit 1) is
 * reset with 0x27 <- 2A, the handler counts it exactly as Timer A's.
 * For each 0x29 value in the list 1F (the chip's reset value: the control), 03, 02, 01, 00,
 * the as-found 0x29 read if it is none of those and not FF or 29 (a YM2608 register is
 * not readable; NP2kai answers the select latch, 29), and 1F again (recovery), two
 * windows of Timer A (NA = 0x200: 0x24 <- 80, 0x25 <- 00) and then the same two windows of
 * Timer B (0x26 <- E0, the other timer stopped), each exactly 61440 ARTIC ticks
 * (0.2 s of the 307200 Hz device counter at 0x5C/0x5F; never a CPU loop):
 *   IRQ  window: INT 14h (IRQ12, the -86's factory INT5) points at this probe's handler,
 *        the slave IMR opens IR4 only, the master IMR is as found with IR7 (the cascade)
 *        open, 0x27 <- 05 (load + enable A), STI, and the main loop reads only the ARTIC.
 *        The handler counts, ORs the status into st_isr, writes 0x27 <- 15 (reset flag A,
 *        keep A loaded and enabled), EOIs the slave and, if the slave ISR is then empty,
 *        the master (SOUND.ROM's own sequence, cee0:0BE0-0BF4). At the end: the count, the
 *        status left behind (bit 0 set with count 0 = the flag rose but no interrupt came),
 *        the OR of the slave IRR read at the end.
 *   POLL window: CLI throughout, the slave IMR fully masked, 0x27 <- 05; every pass reads
 *        the status and the slave IRR (OCW3 0A). A set flag bit 0 is counted and reset
 *        (0x27 <- 15). Recorded: the flags seen, the number of passes that saw slave IRR
 *        bit 4 (the IRQ12 request line latched while masked; read before the status, as
 *        the flag reset can drop the line), the pass count, the OR of every IRR read. This shows the timer runs at every 0x29 value, and whether the
 *        chip's IRQ pin moved at all with the interrupt masked at the PIC.
 * Each window also latches PIT channel 0 (0x77 <- 00, read 0x71 twice) at its start and
 * end, raw, as a second time reference beside the ARTIC (crt24k explains why the PIT's
 * modulus needs measuring before it can be the primary clock).
 *
 * The windows below describe Timer A; Timer B's are the same with 0A/2A/status bit 1.
 *
 * WHAT IT WRITES, AND THE RESTORE. OPNA 0x24, 0x25, 0x26, 0x27, 0x29 at the tested base; the
 * INT 14h vector (0000:0050); both IMRs; the slave OCW3 read select. At the end: 0x27 <- 30
 * (timers stopped, flags reset, as irqwd/xe10t leave it), 0x24/0x25/0x26 <- 00 (their reset
 * values), 0x29 <- 1F (its reset value: the as-found 0x29 cannot be read back on a YM2608,
 * so REBOOT after the probe if the sound BIOS's own setting matters), the vector and both
 * IMRs from their saved copies, OCW3 left at ISR (0B, as irqwd leaves it). The RESTORE block
 * prints every one of them as saved -> now.
 *
 * SAFETY. No disk access except DOS stdout (run it redirected to a file); no memory write
 * outside this program but the one vector. Every spin is bounded by the ARTIC, every BUSY
 * wait by a count. The handler masks IRQ12 itself after 4000 entries in one window (a line
 * that will not drop) and the row says so. Nothing is printed until all windows ran.
 *
 * OUTPUT (decode with ym29_decode.py):
 *   BEGIN:YM29
 *   YM29 v2: ...                                                   (the version line)
 *   TIMERS A NA=200 B NB=E0 win=61440
 *   BASE b=0188 st=xx st2=xx a460=xx id=xx r0e=xx r0f=xx r29=xx    (one per base; st=FF -> no more)
 *   USE b=0188 id=01 irq=12
 *   IRQ  v29=xx n=NNNNN st_end=xx st_isr=xx irr_end=xx ticks=NNNNNNNN pit0=xxxx pit1=xxxx sat=x
 *   POLL v29=xx flags=NNNNN ir4=NNNNN polls=NNNNN irr_or=xx ticks=NNNNNNNN pit0=xxxx pit1=xxxx
 *   IRQB v29=xx ...  (Timer B, the IRQ line's fields)
 *   POLLB v29=xx ... (Timer B, the POLL line's fields)
 *   RESTORE ...
 *   END:YM29
 *
 * v3 (the 2026-11 kit) adds, the v2 windows unchanged:
 *   READMAP b=0188 r00= <16> r10= <16> r20= <16> rFF=xx   the base-bank data-port read of every
 *        register 0x00..0x2F and 0xFF (select only, no write): which registers read back
 *        (the SSG 0x00-0x0F on a YM2608), and what the others answer (follow-up (a): the Xe10
 *        reads 0x29 as FF where the core answers 29, docs/probes/YM29B-XE10.TXT BASE line)
 *   RD29 v29=xx pre=xx post=xx   0x29 read just before and just after each value's write
 *   IRRH <M|S> <MASKED|FOUND> n=<samples> b0=.. b7=.. or=xx and=xx   2 s of master and slave
 *        IRR samples (OCW3 0x0A), per-bit set counts: MASKED with IF = 0 and both IMRs = FF,
 *        FOUND with IF = 1 and the IMRs as found (the BIOS's handlers run). The 8259A latches IRR
 *        whatever the IMR (Intel 8259A datasheet, "Interrupt Mask Register"), so MASKED is the
 *        raw request lines. Follow-up (b): v1's slave IRR at a window's end read 88 on the Xe10
 *        (YM29-XE10.TXT irr_end), v2 80, the core 00/80 - irr_end is the SLAVE's IRR (port 0x08)
 *   The OCW3 read select is left at ISR (0B) on both PICs, as irqwd leaves it.
 *
 * BUILD: make -C tools/hwprobe ym29/ym29.com
 */
    .code16
    .intel_syntax noprefix

    .section .text
    .global _start

    .equ MPIC_CMD, 0x0000
    .equ MPIC_IMR, 0x0002
    .equ SPIC_CMD, 0x0008
    .equ SPIC_IMR, 0x000A
    .equ VEC14,    0x0050               /* INT 14h = IRQ12 (slave IR4) */
    .equ WIN_TICKS, 61440               /* ARTIC ticks per window: 0.2 s */
    .equ ISR_SAT,  4000
    .equ MAXV,     8
    .equ HALFSZ,   32                   /* one timer's record, see the R_* offsets */
    .equ ROWSZ,    64                   /* per value: Timer A's half, then Timer B's */
    .equ R_V,      0
    .equ R_N,      2
    .equ R_STE,    4
    .equ R_STI,    5
    .equ R_IRRE,   6
    .equ R_SAT,    7
    .equ R_TICK,   8
    .equ R_P0,     12
    .equ R_P1,     14
    .equ R_FL,     16
    .equ R_IR4,    18
    .equ R_POLLS,  20
    .equ R_IRROR,  22
    .equ R_PTICK,  24
    .equ R_PP0,    28
    .equ R_PP1,    30
    .equ HIST_SZ,  4 + 64 + 4           /* v3: one IRR-histogram phase record (hist_run) */

_start:
    push    cs
    pop     ds
    push    cs
    pop     es
    cld

    /* ------------- identity: 0x188, 0x288 ------------- */
    mov     dx, 0xA460
    in      al, dx
    mov     [a460], al
    xor     bx, bx
id_loop:
    mov     ax, [bases + bx]
    mov     [base], ax
    mov     dx, ax
    in      al, dx
    mov     [id_st + bx], al
    out     0x5F, al
    in      al, dx
    mov     [id_st2 + bx], al
    cmp     byte ptr [id_st + bx], 0xFF
    je      id_next
    mov     al, 0xFF
    call    opn_get
    mov     [id_id + bx], al
    mov     al, 0x0E
    call    opn_get
    mov     [id_0e + bx], al
    mov     al, 0x0F
    call    opn_get
    mov     [id_0f + bx], al
    mov     al, 0x29
    call    opn_get
    mov     [id_29 + bx], al
id_next:
    add     bx, 2
    cmp     bx, 4
    jb      id_loop

    /* pick the base: first ID 01, else first answering */
    mov     word ptr [base], 0
    xor     bx, bx
pk1:
    cmp     byte ptr [id_st + bx], 0xFF
    je      pk1n
    cmp     byte ptr [id_id + bx], 0x01
    jne     pk1n
    jmp     pk_take
pk1n:
    add     bx, 2
    cmp     bx, 4
    jb      pk1
    mov     byte ptr [no_ym2608], 1
    xor     bx, bx
pk2:
    cmp     byte ptr [id_st + bx], 0xFF
    jne     pk_take
    add     bx, 2
    cmp     bx, 4
    jb      pk2
    jmp     report                      /* nothing answers: print identity only */
pk_take:
    mov     ax, [bases + bx]
    mov     [base], ax
    mov     [use_bx], bx

    /* the value list: 1F 03 02 01 00 [as-found] 1F */
    mov     di, offset vlist
    mov     al, 0x1F
    stosb
    mov     al, 0x03
    stosb
    mov     al, 0x02
    stosb
    mov     al, 0x01
    stosb
    mov     al, 0x00
    stosb
    mov     al, [id_29 + bx]
    cmp     al, 0xFF
    je      vl_skip
    cmp     al, 0x29                    /* the select latch echoed: not a read of 0x29 */
    je      vl_skip
    cmp     al, 0x1F
    je      vl_skip
    cmp     al, 0x03
    je      vl_skip
    cmp     al, 0x02
    je      vl_skip
    cmp     al, 0x01
    je      vl_skip
    cmp     al, 0x00
    je      vl_skip
    stosb
vl_skip:
    mov     al, 0x1F
    stosb
    mov     ax, di
    sub     ax, offset vlist
    mov     [nv], ax


    /* save what the windows change */
    cli
    in      al, MPIC_IMR
    mov     [m_imr_found], al
    in      al, SPIC_IMR
    mov     [s_imr_found], al
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     ax, [VEC14]
    mov     dx, [VEC14 + 2]
    pop     ds
    mov     [vec_off], ax
    mov     [vec_seg], dx
    sti

    xor     si, si                      /* value index */
    mov     di, offset rows
v_loop:
    cmp     si, [nv]
    jae     v_done
    mov     al, [vlist + si]
    mov     [cur_v], al
    mov     [di + R_V], al
    mov     [di + HALFSZ + R_V], al
    call    sel_timer_a
    call    win_irq
    call    win_poll
    add     di, HALFSZ
    call    sel_timer_b
    call    win_irq
    call    win_poll
    add     di, HALFSZ
    inc     si
    jmp     v_loop
v_done:
    call    restore_all
    mov     byte ptr [restored], 1
    /* v3: the base-bank read map and the 0x29 pre/post reads, AFTER the v2 windows (so those
     * run exactly as in v2: on the core a read map taken first left the 1F control rows
     * without interrupts), then 0x29 <- 1F again (its reset value, as restore_all leaves it) */
    cli
    xor     bx, bx
rm_loop:
    mov     al, bl
    call    opn_get
    mov     [readmap + bx], al
    inc     bx
    cmp     bx, 0x30
    jb      rm_loop
    mov     al, 0xFF
    call    opn_get
    mov     [readmap + 0x30], al
    xor     si, si
rd_loop:
    cmp     si, [nv]
    jae     rd_done
    mov     al, 0x29
    call    opn_get
    mov     bx, si
    shl     bx, 1
    mov     [rd29 + bx], al
    mov     ah, [vlist + si]
    mov     al, 0x29
    call    opn_put
    mov     al, 0x29
    call    opn_get
    mov     [rd29 + bx + 1], al
    inc     si
    jmp     rd_loop
rd_done:
    mov     ax, 0x1F29
    call    opn_put
    sti
    call    irr_hist

report:
    mov     si, offset msg_begin
    call    puts
    mov     si, offset msg_timers
    call    puts
    xor     bx, bx
rp_id:
    mov     si, offset msg_base
    call    puts
    mov     ax, [bases + bx]
    call    puthex16
    mov     si, offset msg_st
    call    puts
    mov     al, [id_st + bx]
    call    puthex8
    mov     si, offset msg_st2
    call    puts
    mov     al, [id_st2 + bx]
    call    puthex8
    mov     si, offset msg_a460
    call    puts
    mov     al, [a460]
    call    puthex8
    cmp     byte ptr [id_st + bx], 0xFF
    je      rp_id_nl
    mov     si, offset msg_id
    call    puts
    mov     al, [id_id + bx]
    call    puthex8
    mov     si, offset msg_r0e
    call    puts
    mov     al, [id_0e + bx]
    call    puthex8
    mov     si, offset msg_r0f
    call    puts
    mov     al, [id_0f + bx]
    call    puthex8
    mov     si, offset msg_r29
    call    puts
    mov     al, [id_29 + bx]
    call    puthex8
rp_id_nl:
    call    crlf
    add     bx, 2
    cmp     bx, 4
    jb      rp_id

    cmp     word ptr [base], 0
    jne     rp_use
    mov     si, offset msg_none
    call    puts
    jmp     rp_end
rp_use:
    mov     si, offset msg_use
    call    puts
    mov     ax, [base]
    call    puthex16
    mov     si, offset msg_id
    call    puts
    mov     bx, [use_bx]
    mov     al, [id_id + bx]
    call    puthex8
    mov     si, offset msg_irq12
    call    puts
    cmp     byte ptr [no_ym2608], 0
    je      rp_rows
    mov     si, offset msg_noym
    call    puts

rp_rows:
    call    rp_v3a
    xor     cx, cx
    mov     di, offset rows
rp_row:
    cmp     cx, [nv]
    jae     rp_rest
    mov     word ptr [rp_irq], offset msg_irq
    mov     word ptr [rp_poll], offset msg_poll
    call    rp_half
    add     di, HALFSZ
    mov     word ptr [rp_irq], offset msg_irqb
    mov     word ptr [rp_poll], offset msg_pollb
    call    rp_half
    add     di, HALFSZ
    inc     cx
    jmp     rp_row

/* rp_half: DI = one timer's record; prints its IRQ line and its POLL line */
rp_half:
    /* IRQ row */
    mov     si, [rp_irq]
    call    puts
    mov     al, [di + R_V]
    call    puthex8
    mov     si, offset msg_n
    call    puts
    movzx   eax, word ptr [di + R_N]
    call    putdec32
    mov     si, offset msg_ste
    call    puts
    mov     al, [di + R_STE]
    call    puthex8
    mov     si, offset msg_sti
    call    puts
    mov     al, [di + R_STI]
    call    puthex8
    mov     si, offset msg_irre
    call    puts
    mov     al, [di + R_IRRE]
    call    puthex8
    mov     si, offset msg_ticks
    call    puts
    mov     eax, [di + R_TICK]
    call    putdec32
    mov     si, offset msg_p0
    call    puts
    mov     ax, [di + R_P0]
    call    puthex16
    mov     si, offset msg_p1
    call    puts
    mov     ax, [di + R_P1]
    call    puthex16
    mov     si, offset msg_sat
    call    puts
    mov     al, [di + R_SAT]
    add     al, '0'
    mov     dl, al
    call    putc
    call    crlf
    /* POLL row */
    mov     si, [rp_poll]
    call    puts
    mov     al, [di + R_V]
    call    puthex8
    mov     si, offset msg_fl
    call    puts
    movzx   eax, word ptr [di + R_FL]
    call    putdec32
    mov     si, offset msg_ir4
    call    puts
    movzx   eax, word ptr [di + R_IR4]
    call    putdec32
    mov     si, offset msg_polls
    call    puts
    movzx   eax, word ptr [di + R_POLLS]
    call    putdec32
    mov     si, offset msg_irror
    call    puts
    mov     al, [di + R_IRROR]
    call    puthex8
    mov     si, offset msg_ticks
    call    puts
    mov     eax, [di + R_PTICK]
    call    putdec32
    mov     si, offset msg_p0
    call    puts
    mov     ax, [di + R_PP0]
    call    puthex16
    mov     si, offset msg_p1
    call    puts
    mov     ax, [di + R_PP1]
    call    puthex16
    call    crlf
    ret

rp_rest:
    call    rp_v3b
    /* RESTORE proof: saved -> now */
    mov     si, offset msg_rest_m
    call    puts
    mov     al, [m_imr_found]
    call    puthex8
    mov     si, offset msg_arrow
    call    puts
    in      al, MPIC_IMR
    call    puthex8
    mov     si, offset msg_rest_s
    call    puts
    mov     al, [s_imr_found]
    call    puthex8
    mov     si, offset msg_arrow
    call    puts
    in      al, SPIC_IMR
    call    puthex8
    mov     si, offset msg_rest_v
    call    puts
    mov     ax, [vec_seg]
    call    puthex16
    mov     dl, ':'
    call    putc
    mov     ax, [vec_off]
    call    puthex16
    mov     si, offset msg_arrow
    call    puts
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     bx, [VEC14]
    mov     ax, [VEC14 + 2]
    pop     ds
    call    puthex16
    mov     dl, ':'
    call    putc
    mov     ax, bx
    call    puthex16
    mov     si, offset msg_rest_o
    call    puts
    call    crlf
rp_end:
    mov     si, offset msg_end
    call    puts
    mov     ax, 0x4C00
    int     0x21
    hlt

/* ------------------------------------------------------------------
 * win_irq: DI = the row. The INT 14h window.
 * ------------------------------------------------------------------ */
win_irq:
    cli
    call    timer_setup                 /* 0x27 <- 30, NA, 0x29 <- cur_v */
    mov     word ptr [isr_n], 0
    mov     byte ptr [isr_st], 0
    mov     byte ptr [isr_sat], 0
    /* vector -> isr12 */
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     word ptr [VEC14], offset isr12
    mov     [VEC14 + 2], cs
    pop     ds
    /* IMRs: slave IR4 only, master as found with the cascade open */
    mov     al, 0xEF
    out     SPIC_IMR, al
    out     0x5F, al
    mov     al, [m_imr_found]
    and     al, 0x7F
    out     MPIC_IMR, al
    out     0x5F, al
    call    pit_latch
    mov     [di + R_P0], ax
    call    artic_read
    mov     [t0], eax
    mov     ah, [ctl_start]             /* load + enable the timer under test */
    mov     al, 0x27
    call    opn_put
    sti
wi_spin:
    call    artic_read
    sub     eax, [t0]
    and     eax, 0x00FFFFFF
    cmp     eax, WIN_TICKS
    jb      wi_spin
    cli
    mov     [di + R_TICK], eax
    call    pit_latch
    mov     [di + R_P1], ax
    mov     dx, [base]
    in      al, dx
    mov     [di + R_STE], al
    mov     al, 0x0A                    /* OCW3: read IRR */
    out     SPIC_CMD, al
    out     0x5F, al
    in      al, SPIC_CMD
    mov     [di + R_IRRE], al
    mov     al, 0x0B                    /* back to ISR, as the handler expects */
    out     SPIC_CMD, al
    mov     ax, 0x3027                  /* stop, reset both flags */
    call    opn_put
    /* everything masked again, vector back */
    mov     al, [s_imr_found]
    or      al, 0x10
    out     SPIC_IMR, al
    out     0x5F, al
    mov     al, [m_imr_found]
    out     MPIC_IMR, al
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     ax, cs:[vec_off]
    mov     [VEC14], ax
    mov     ax, cs:[vec_seg]
    mov     [VEC14 + 2], ax
    pop     ds
    mov     ax, [isr_n]
    mov     [di + R_N], ax
    mov     al, [isr_st]
    mov     [di + R_STI], al
    mov     al, [isr_sat]
    mov     [di + R_SAT], al
    sti
    ret

/* ------------------------------------------------------------------
 * win_poll: DI = the row. CLI throughout, IRQ12 masked, flag polled.
 * ------------------------------------------------------------------ */
win_poll:
    cli
    call    timer_setup
    mov     al, [s_imr_found]
    or      al, 0x10
    out     SPIC_IMR, al
    out     0x5F, al
    mov     word ptr [di + R_FL], 0
    mov     word ptr [di + R_IR4], 0
    mov     word ptr [di + R_POLLS], 0
    mov     byte ptr [di + R_IRROR], 0
    call    pit_latch
    mov     [di + R_PP0], ax
    call    artic_read
    mov     [t0], eax
    mov     ah, [ctl_start]
    mov     al, 0x27
    call    opn_put
wp_spin:
    inc     word ptr [di + R_POLLS]
    jnz     1f
    dec     word ptr [di + R_POLLS]     /* saturate */
1:  mov     al, 0x0A                    /* the IRR first: the flag reset below may drop it */
    out     SPIC_CMD, al
    out     0x5F, al
    in      al, SPIC_CMD
    or      [di + R_IRROR], al
    test    al, 0x10
    jz      wp_st
    inc     word ptr [di + R_IR4]
wp_st:
    mov     dx, [base]
    in      al, dx
    test    al, [ctl_flag]
    jz      wp_t
    inc     word ptr [di + R_FL]
    mov     ah, [ctl_reset]             /* reset the flag, keep the timer running */
    mov     al, 0x27
    call    opn_put
wp_t:
    call    artic_read
    sub     eax, [t0]
    and     eax, 0x00FFFFFF
    cmp     eax, WIN_TICKS
    jb      wp_spin
    mov     [di + R_PTICK], eax
    call    pit_latch
    mov     [di + R_PP1], ax
    mov     al, 0x0B
    out     SPIC_CMD, al
    mov     ax, 0x3027
    call    opn_put
    mov     al, [s_imr_found]
    out     SPIC_IMR, al
    sti
    ret

/* sel_timer_a / sel_timer_b: the 0x27 start and flag-reset bytes and the status flag bit */
sel_timer_a:
    mov     byte ptr [ctl_start], 0x05  /* load A + enable A */
    mov     byte ptr [ctl_reset], 0x15  /* reset A + load A + enable A */
    mov     byte ptr [ctl_flag], 0x01
    ret
sel_timer_b:
    mov     byte ptr [ctl_start], 0x0A  /* load B + enable B */
    mov     byte ptr [ctl_reset], 0x2A  /* reset B + load B + enable B */
    mov     byte ptr [ctl_flag], 0x02
    ret

/* timer_setup (IF=0): stop and reset, NA = 0x200, NB = 0xE0, 0x29 <- cur_v */
timer_setup:
    mov     ax, 0x3027
    call    opn_put
    mov     ax, 0x8024
    call    opn_put
    mov     ax, 0x0025
    call    opn_put
    mov     ax, 0xE026                  /* NB = 0xE0: 32 x 16 = 512 Timer A units */
    call    opn_put
    mov     ah, [cur_v]
    mov     al, 0x29
    call    opn_put
    ret

/* restore_all: the OPNA end state, the vector, the IMRs */
restore_all:
    cli
    mov     ax, 0x3027
    call    opn_put
    mov     ax, 0x0024
    call    opn_put
    mov     ax, 0x0025
    call    opn_put
    mov     ax, 0x0026
    call    opn_put
    mov     ax, 0x1F29
    call    opn_put
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     ax, cs:[vec_off]
    mov     [VEC14], ax
    mov     ax, cs:[vec_seg]
    mov     [VEC14 + 2], ax
    pop     ds
    mov     al, 0x0B
    out     SPIC_CMD, al
    out     0x5F, al
    mov     al, [s_imr_found]
    out     SPIC_IMR, al
    out     0x5F, al
    mov     al, [m_imr_found]
    out     MPIC_IMR, al
    sti
    ret

/* ------------------------------------------------------------------
 * isr12: INT 14h. Counts, resets flag A, EOIs (slave, then master if the slave is idle).
 * ------------------------------------------------------------------ */
isr12:
    push    ax
    push    dx
    push    ds
    push    cs
    pop     ds
    inc     word ptr [isr_n]
    mov     dx, [base]
    in      al, dx
    or      [isr_st], al
    mov     ah, [ctl_reset]
    mov     al, 0x27
    call    opn_put
    cmp     word ptr [isr_n], ISR_SAT
    jb      isr_eoi
    mov     byte ptr [isr_sat], 1
    in      al, SPIC_IMR
    or      al, 0x10
    out     SPIC_IMR, al
isr_eoi:
    mov     al, 0x20
    out     SPIC_CMD, al
    out     0x5F, al
    mov     al, 0x0B
    out     SPIC_CMD, al
    out     0x5F, al
    in      al, SPIC_CMD
    test    al, al
    jnz     isr_out
    mov     al, 0x20
    out     MPIC_CMD, al
isr_out:
    pop     ds
    pop     dx
    pop     ax
    iret

/* ------------------------------------------------------------------
 * OPNA access at [base]: opn_put AL = register, AH = data; opn_get AL = register -> AL.
 * BUSY (status bit 7) is waited for before each access, bounded.
 * ------------------------------------------------------------------ */
opn_wait:
    push    cx
    push    ax
    mov     cx, 0x4000
1:  in      al, dx
    test    al, 0x80
    jz      2f
    loop    1b
2:  pop     ax
    pop     cx
    ret

opn_put:
    push    dx
    mov     dx, [base]
    call    opn_wait
    out     dx, al
    out     0x5F, al
    call    opn_wait
    add     dx, 2
    xchg    al, ah
    out     dx, al
    xchg    al, ah
    sub     dx, 2
    call    opn_wait
    pop     dx
    ret

opn_get:
    push    dx
    mov     dx, [base]
    call    opn_wait
    out     dx, al
    out     0x5F, al
    out     0x5F, al
    call    opn_wait
    add     dx, 2
    in      al, dx
    pop     dx
    ret

/* pit_latch: AX = PIT channel 0's latched count (0x77 <- 00, 0x71 low then high) */
pit_latch:
    push    dx
    mov     dx, 0x0077
    xor     al, al
    out     dx, al
    out     0x5F, al
    mov     dx, 0x0071
    in      al, dx
    mov     ah, al
    out     0x5F, al
    in      al, dx
    xchg    al, ah
    pop     dx
    ret

/* artic_read: EAX = the 24-bit ARTIC count (0x5C word, 0x5F high byte), as crt24k */
artic_read:
    push    dx
    push    ebx
    push    ecx
    mov     dx, 0x005f
    in      al, dx
    movzx   ebx, al
    mov     dx, 0x005c
    in      ax, dx
    movzx   ecx, ax
    mov     dx, 0x005f
    in      al, dx
    movzx   eax, al
    cmp     eax, ebx
    je      1f
    cmp     ecx, 0x8000
    jb      1f
    mov     eax, ebx
1:  shl     eax, 16
    or      eax, ecx
    pop     ecx
    pop     ebx
    pop     dx
    ret

/* ------------------------------------------------------------------ output */
putc:                                   /* DL */
    push    ax
    mov     ah, 0x02
    int     0x21
    pop     ax
    ret

crlf:
    push    si
    mov     si, offset msg_crlf
    call    puts
    pop     si
    ret

puts:                                   /* DS:SI, NUL terminated */
    push    ax
    push    dx
    push    si
1:  mov     al, [si]
    test    al, al
    jz      2f
    mov     dl, al
    call    putc
    inc     si
    jmp     1b
2:  pop     si
    pop     dx
    pop     ax
    ret

puthex8:                                /* AL */
    push    ax
    push    dx
    push    ax
    shr     al, 4
    call    ph_nib
    pop     ax
    and     al, 0x0F
    call    ph_nib
    pop     dx
    pop     ax
    ret
ph_nib:
    add     al, '0'
    cmp     al, '9'
    jbe     1f
    add     al, 'A' - '9' - 1
1:  mov     dl, al
    call    putc
    ret

puthex16:                               /* AX */
    push    ax
    mov     al, ah
    call    puthex8
    pop     ax
    call    puthex8
    ret

putdec32:                               /* EAX unsigned */
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     ebx, 10
    xor     ecx, ecx
1:  xor     edx, edx
    div     ebx
    push    dx
    inc     ecx
    test    eax, eax
    jnz     1b
2:  pop     dx
    add     dl, '0'
    call    putc
    dec     ecx
    jnz     2b
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret


/* ------------------------------------------------------------------
 * v3: irr_hist - 2 s of IRR samples, masked (IF = 0, IMRs FF) then as found (IF = 1)
 * ------------------------------------------------------------------ */
    .equ HIST_TICKS, 614400             /* 2 s of the 307200 Hz ARTIC */
irr_hist:
    mov     di, offset hist             /* phase 0: MASKED */
    cli
    mov     al, 0xFF
    out     MPIC_IMR, al
    out     0x5F, al
    out     SPIC_IMR, al
    call    hist_run
    mov     al, [m_imr_found]
    out     MPIC_IMR, al
    out     0x5F, al
    mov     al, [s_imr_found]
    out     SPIC_IMR, al
    sti
    mov     di, offset hist + HIST_SZ   /* phase 1: FOUND */
    call    hist_run
    cli
    mov     al, 0x0B
    out     MPIC_CMD, al
    out     0x5F, al
    out     SPIC_CMD, al
    sti
    ret
/* hist_run: DI = the phase record: n (4), then master b0..b7 (4 each), slave b0..b7, m_or, m_and,
 * s_or, s_and. Each sample reads both IRRs (the OCW3 0x0A select is written once; the
 * handlers that run in the FOUND phase may move it, so it is rewritten every sample). */
hist_run:
    push    di
    mov     cx, HIST_SZ
    xor     al, al
    rep     stosb
    pop     di
    mov     byte ptr [di + 69], 0xFF
    mov     byte ptr [di + 71], 0xFF
    call    artic_read
    mov     [t0], eax
hr_loop:
    pushf
    cli
    mov     al, 0x0A
    out     MPIC_CMD, al
    out     SPIC_CMD, al
    out     0x5F, al
    in      al, MPIC_CMD
    mov     dl, al
    in      al, SPIC_CMD
    mov     dh, al
    popf
    inc     dword ptr [di]
    or      [di + 68], dl
    and     [di + 69], dl
    or      [di + 70], dh
    and     [di + 71], dh
    mov     bx, di
    xor     si, si
hr_bit:
    shr     dl, 1
    jnc     1f
    inc     dword ptr [bx + si + 4]
1:  shr     dh, 1
    jnc     2f
    inc     dword ptr [bx + si + 36]
2:  add     si, 4
    cmp     si, 32
    jb      hr_bit
    call    artic_read
    sub     eax, [t0]
    and     eax, 0x00FFFFFF
    cmp     eax, HIST_TICKS
    jb      hr_loop
    ret

/* rp_v3a: READMAP and RD29 lines */
rp_v3a:
    push    cx
    push    di
    mov     si, offset msg_rmap
    call    puts
    mov     ax, [base]
    call    puthex16
    xor     bx, bx
ra_row:
    mov     si, offset msg_rmr
    call    puts
    mov     al, bl
    call    puthex8
    mov     dl, '='
    call    putc
    mov     cx, 16
ra_b:
    mov     dl, ' '
    call    putc
    mov     al, [readmap + bx]
    call    puthex8
    inc     bx
    loop    ra_b
    cmp     bx, 0x30
    jb      ra_row
    mov     si, offset msg_rmff
    call    puts
    mov     al, [readmap + 0x30]
    call    puthex8
    call    crlf
    xor     si, si
ra_rd:
    cmp     si, [nv]
    jae     ra_done
    push    si
    mov     si, offset msg_rd29
    call    puts
    pop     si
    mov     al, [vlist + si]
    call    puthex8
    push    si
    mov     si, offset msg_pre
    call    puts
    pop     si
    mov     bx, si
    shl     bx, 1
    mov     al, [rd29 + bx]
    call    puthex8
    push    si
    mov     si, offset msg_post
    call    puts
    pop     si
    mov     al, [rd29 + bx + 1]
    call    puthex8
    call    crlf
    inc     si
    jmp     ra_rd
ra_done:
    pop     di
    pop     cx
    ret

/* rp_v3b: the IRRH lines */
rp_v3b:
    mov     di, offset hist
    mov     word ptr [hph], 0
rb_phase:
    mov     word ptr [hpic], 0
rb_pic:
    mov     si, offset msg_irrh
    call    puts
    mov     dl, 'M'
    cmp     word ptr [hpic], 0
    je      1f
    mov     dl, 'S'
1:  call    putc
    mov     si, offset msg_masked
    cmp     word ptr [hph], 0
    je      2f
    mov     si, offset msg_found
2:  call    puts
    mov     eax, [di]
    call    putdec32
    mov     bx, [hpic]
    shl     bx, 5                       /* 0 or 32 */
    add     bx, 4
    xor     cx, cx
rb_bit:
    mov     si, offset msg_b
    call    puts
    mov     al, cl
    add     al, '0'
    mov     dl, al
    call    putc
    mov     dl, '='
    call    putc
    push    bx
    add     bx, di
    mov     eax, [bx]
    pop     bx
    call    putdec32
    add     bx, 4
    inc     cx
    cmp     cx, 8
    jb      rb_bit
    mov     si, offset msg_or
    call    puts
    mov     bx, [hpic]
    shl     bx, 1
    add     bx, di
    mov     al, [bx + 68]
    call    puthex8
    mov     si, offset msg_and
    call    puts
    mov     al, [bx + 69]
    call    puthex8
    call    crlf
    inc     word ptr [hpic]
    cmp     word ptr [hpic], 2
    jb      rb_pic
    add     di, HIST_SZ
    inc     word ptr [hph]
    cmp     word ptr [hph], 2
    jb      rb_phase
    ret
/* ------------------------------------------------------------------ data */
bases:      .word 0x0188, 0x0288
base:       .word 0
use_bx:     .word 0
nv:         .word 0
a460:       .byte 0
no_ym2608:  .byte 0
restored:   .byte 0
cur_v:      .byte 0
ctl_start:  .byte 0x05
ctl_reset:  .byte 0x15
ctl_flag:   .byte 0x01
rp_irq:     .word 0
rp_poll:    .word 0
m_imr_found: .byte 0
s_imr_found: .byte 0
vec_off:    .word 0
vec_seg:    .word 0
t0:         .long 0
isr_n:      .word 0
isr_st:     .byte 0
isr_sat:    .byte 0
id_st:      .byte 0xFF, 0, 0xFF, 0      /* indexed by bx = 0, 2 */
id_st2:     .byte 0, 0, 0, 0
id_id:      .byte 0, 0, 0, 0
id_0e:      .byte 0, 0, 0, 0
id_0f:      .byte 0, 0, 0, 0
id_29:      .byte 0, 0, 0, 0
vlist:      .byte 0, 0, 0, 0, 0, 0, 0, 0

msg_begin:  .ascii "BEGIN:YM29\r\n"
            .ascii "YM29 v3: does YM2608 reg 0x29 (IRQ enable) gate the Timer A and B IRQs? windows of 61440 ARTIC ticks (0.2 s); + READMAP, RD29, IRRH\r\n\0"
msg_timers: .asciz "TIMERS A NA=200 B NB=E0 win=61440\r\n"
msg_base:   .asciz "BASE b="
msg_st:     .asciz " st="
msg_st2:    .asciz " st2="
msg_a460:   .asciz " a460="
msg_id:     .asciz " id="
msg_r0e:    .asciz " r0e="
msg_r0f:    .asciz " r0f="
msg_r29:    .asciz " r29="
msg_none:   .asciz "NONE no base answers (status FF at 0188 and 0288)\r\n"
msg_use:    .asciz "USE b="
msg_irq12:  .asciz " irq=12\r\n"
msg_noym:   .asciz "NOTE no base answered id=01 (YM2608); the first answering base was tested\r\n"
msg_irq:    .asciz "IRQ  v29="
msg_n:      .asciz " n="
msg_ste:    .asciz " st_end="
msg_sti:    .asciz " st_isr="
msg_irre:   .asciz " irr_end="
msg_ticks:  .asciz " ticks="
msg_p0:     .asciz " pit0="
msg_p1:     .asciz " pit1="
msg_sat:    .asciz " sat="
msg_poll:   .asciz "POLL v29="
msg_irqb:   .asciz "IRQB v29="
msg_pollb:  .asciz "POLLB v29="
msg_fl:     .asciz " flags="
msg_ir4:    .asciz " ir4="
msg_polls:  .asciz " polls="
msg_irror:  .asciz " irr_or="
msg_rest_m: .asciz "RESTORE m_imr="
msg_rest_s: .asciz " s_imr="
msg_rest_v: .asciz " vec14="
msg_rest_o: .asciz " opna: 27=30 24=00 25=00 26=00 29=1F (reset values; reboot to restore the sound BIOS's own 0x29)"
msg_arrow:  .asciz "->"
msg_crlf:   .asciz "\r\n"
msg_end:    .asciz "END:YM29\r\n"
msg_rmap:   .asciz "READMAP b="
msg_rmr:    .asciz " r"
msg_rmff:   .asciz " rFF="
msg_rd29:   .asciz "RD29 v29="
msg_pre:    .asciz " pre="
msg_post:   .asciz " post="
msg_irrh:   .asciz "IRRH "
msg_masked: .asciz " MASKED n="
msg_found:  .asciz " FOUND n="
msg_b:      .asciz " b"
msg_or:     .asciz " or="
msg_and:    .asciz " and="
hph:        .word 0
hpic:       .word 0
readmap:    .space 0x31
rd29:       .space MAXV * 2
    .balign 4
hist:       .space HIST_SZ * 2

    .balign 2
rows:       .space ROWSZ * MAXV

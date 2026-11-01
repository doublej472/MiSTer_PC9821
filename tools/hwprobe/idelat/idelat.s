/* idelat.s - the real-machine IDE/ATA READ latency probe (th5-ide targets).
 *
 * WHY. A parallel lane (th5-ide) is fixing Touhou 5's slow text-box loads: the
 * game reads speech/dialogue data through the IDE, and the core needs "what to
 * aim for" from the real Xe10.  This probe measures the latency set:
 *   - command issue -> first DRQ (the fixed command overhead),
 *   - per-sector PIO read time (the 256-word transfer block),
 *   - single- vs multi-sector READ SECTORS (one command, count=1 vs count=N),
 *   - word-transfer throughput (per-word cost of the data-port read),
 *   - the status-poll cost shape (one bare status read vs one full poll-loop
 *     iteration, so the poll overhead can be netted out of every DRQ window).
 * It also carries the instrument fixes the record demands: PIT
 * deltas are used RAW (the machine's channel 0 counts once per oscillator
 * clock; the old mode-3 /2 halving was 2x wrong), the absolute latch word is
 * never used for timing (it tears - the divisor scan is diagnostic only, with
 * its raw byte pairs printed so the tear can be studied), and every window
 * carries BOTH the PIT and the ARTIC delta so the decoder can referee each row
 * by the machine-measured 8 raw PIT counts per ARTIC tick.
 *
 * TIME BASES (device clocks, no run-local scale - this is what makes the run
 * comparable with every other run):
 *   PIT channel-0 count rate  2 457 600 counts/s (1 count = 406.9 ns):
 *       the documented 2.4576 MHz oscillator (probe2 tm_div_check),
 *       machine-confirmed by a raster check on the machine - 8 raw counts per ARTIC
 *       tick, 0.5% over three windows on two programs.
 *   ARTIC counter  307 200 Hz (1 tick = 3255.2 ns): the documented rate
 *       (ideprobe.s), machine-confirmed by a raster check on the machine (the VSYNC/
 *       raster edge counts give 56.5 Hz / 24.83 kHz = the PC-98 raster only
 *       at 307 200 Hz).
 * A row's two columns must agree at 8 raw PIT counts per ARTIC tick; a window
 * whose PIT delta wraps (window > one 16-bit period, 26.8 ms) or tears shows
 * up as a disagreement and the ARTIC column serves (the decoder enforces this
 * and drops PIT for ARTIC windows over 26 000 ticks).
 *
 * STRAP ASSUMPTION: 8:1 is the 2.4576 MHz PIT strap's ratio (the 0x6000 divisor
 * the BIOS picks here).  On the 1.9968 MHz strap (0x4E00, work-area 0501 bit 7)
 * the ratio is 6.5:1, so chk_pair would flag EVERY window and the run would look
 * like a total instrument failure.  The SETUP PITDIV line names the strap the
 * scan read, so check it before believing a SELFCHECK failure - and a PIT delta
 * that wrapped its 16-bit period (the longest window here, CAL TSTAMP, is tens
 * of thousands of counts) reads as a failure too, since the check sees only the
 * truncated delta.
 *
 * SIGN CONVENTION (the defect the first capture exposed).  PIT channel 0 counts
 * DOWN and the ARTIC counter counts UP, so a window's PIT delta is start - end
 * and its ARTIC delta is end - start.  The first shipped build used the PIT
 * operand order for the ARTIC column too, so every READ row printed a negative
 * ARTIC delta (IDELAT.TXT drq_art=FFFFFECD) which the decoder read as 1.4e10
 * us.  The CAL rows (tm_finish) always had it right.  chk_pair asserts the 8:1
 * agreement per window from here on, so neither order can slip again.
 *
 * SAFETY - this probe NEVER writes disk data.
 *   - The only ATA commands issued are IDENTIFY DEVICE 0xEC and READ SECTORS
 *     0x20.  No write command exists anywhere in this file.  READ SECTORS on
 *     the scratch CHS range (cylinder 0, head 0, sectors 1..S) is read-only
 *     and safe on the real drive; S is clamped to one track (IDENTIFY word 6)
 *     so long as IDENTIFY is honest and its sectors-per-track >= 4 (the spt<4
 *     fallback floors at 4).  A lying or absent IDENTIFY can therefore make a
 *     read cross a track boundary - still read-only, but such a window's timing
 *     may include a reposition.
 *   - SET MULTIPLE / READ MULTIPLE are deliberately NOT used: they would
 *     change the drive's block-mode state.  The multi-sector form is one READ
 *     SECTORS with the sector-count register > 1, which is the same command.
 *   - Port writes: 0432 bank select (as-found byte restored in RESTORE), the
 *     task-file setup registers 0644/0646/0648/064A/064C, the command
 *     register 064E (0xEC/0x20 only), 0077 <- 00 (the PIT counter-latch
 *     command, stateless), 005F (the documented write-only I/O delay port,
 *     written 1024 times by CAL WAIT5F), and 000A (the slave IMR, saved at
 *     each command window and restored from the save).  The RESTORE footer is
 *     the complete ledger.
 *   - IRQ9 (slave bit 1) is masked around every command window so a resident
 *     driver's ISR cannot touch the task file mid-command; each command is
 *     completed (final status read) before interrupts come back, and a timed-
 *     out or errored trial drains any pending DRQ block first so the drive is
 *     never left with data pending.
 *   - DOS is called (puts/putc) only OUTSIDE the cli windows.
 *
 * OUTPUT.  One BEGIN:<name>/END:<name> section per block (SETUP, CAL, READN,
 * READ1, SELFCHECK, RESTORE), fixed row shapes inside (see idelat_decode.py):
 *   CAL <label> port=PPPP mode=X pit=HHHH base=HHHH artic=HHHHHHHH bartic=HHHHHHHH
 *   R1  t=H sec=HH warm=H st0=HH st1=HH polls=HHHHHHHH to=H ck=HHHH drq_pit=HHHH drq_art=HHHHHHHH xfer_pit=HHHH xfer_art=HHHHHHHH
 *   RN  t=H k=HH sec=HH st=HH polls=HHHHHHHH to=H ck=HHHH drq_pit=HHHH drq_art=HHHHHHHH xfer_pit=HHHH xfer_art=HHHHHHHH
 *   RNEND t=H st=HH polls=HHHHHHHH to=H done_pit=HHHH done_art=HHHHHHHH sum_ck=HHHH fst=HH
 *   SELFCHECK windows=NN ok=NN fail=NN sub=NN (10% band)
 * A hang leaves its BEGIN: with no END:, so the capture before it stays valid.
 *
 * SELF-CHECK.  Every window the probe prints is checked against the 8:1 law
 * (PIT delta = 8 x ARTIC delta, 10% of the expected counts, floored at 16
 * counts).  A window that fails prints its own `** SELFCHECK FAIL ... **` line
 * directly under its row, the SELFCHECK section counts them, and the run exits
 * 1 - so a capture whose two columns disagree cannot be quoted as data.
 *
 * Built by tools/hwprobe/Makefile: GNU as --32, linked at 0x100, .text only.
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

    .equ TM_N,        1024          /* CAL iterations per row */
    .equ POLL_HI,     16            /* DRQ poll bound: 16 x 65536 iterations */
    .equ DIV_TICKS,   9216          /* divisor scan window: 30 ms of ARTIC ticks */
    .equ DIV_GUARD,   0x4000
    .equ COHERENT,    64            /* max count step between two back-to-back latched words */

_start:
    push    cs
    pop     ds
    push    cs
    pop     es

    mov     dx, offset msg_banner
    call    puts

    call    sec_setup
    call    sec_cal
    call    sec_readn
    call    sec_read1
    call    sec_check
    call    sec_restore

    mov     dx, offset msg_done
    call    puts
    mov     al, [run_fail]      /* 1 = a self-check rejected this capture */
    mov     ah, 0x4C
    int     0x21
    hlt

/* ==================================================================
 * section: SETUP - bank, PIT telemetry, IDENTIFY geometry, scratch range
 * ================================================================== */
sec_setup:
    mov     dx, offset msg_begin_setup
    call    puts

    /* 0432 bank: save the as-found byte, select the built-in IDE (value 1,
     * bit 7 clear - the value the machine's own option ROM uses). */
    mov     dx, 0x0432
    in      al, dx
    mov     [bank_save], al
    push    ax
    mov     dx, offset msg_bank_found
    call    puts
    pop     ax
    call    puthex8
    call    putnl
    cli
    mov     dx, 0x0432
    mov     al, 0x01
    out     dx, al
    sti

    /* PIT byte-order calibration and raw pair telemetry: the absolute latch
     * word is known to tear; the raw pairs are printed
     * so the tear itself is evidence next time. */
    call    pit_cal
    mov     dx, offset msg_pitcal
    call    puts
    mov     al, [pit_swap]
    call    puthex8
    call    putnl
    mov     cx, 8
setup_pairs:
    push    cx
    call    pit_bytes
    mov     dx, offset msg_pitpair
    call    puts
    mov     al, [pit_b1]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [pit_b2]
    call    puthex8
    call    putnl
    pop     cx
    loop    setup_pairs

    /* The divisor scan (coherent-pair filtered): DIAGNOSTIC ONLY.  No timing
     * in this probe uses the divisor. */
    call    tm_div_probe
    mov     dx, offset msg_pitdiv
    call    puts
    mov     ax, [tm_div]
    call    puthex16
    mov     dx, offset msg_pitdiv_n
    call    puts
    mov     ax, [tm_daccept]
    call    puthex16
    mov     dl, '/'
    call    putc
    mov     ax, [tm_dtry]
    call    puthex16
    call    putnl

    /* IDENTIFY DEVICE 0xEC (read-only): geometry words for the scratch range. */
    call    irq9_mask
    cli
    mov     dx, 0x064C
    mov     al, 0xA0            /* master, CHS, head 0 */
    out     dx, al
    call    ata_settle
    mov     dx, 0x064E
    in      al, dx              /* status read also acknowledges any stale IRQ */
    mov     [setup_st0], al
    mov     dx, 0x064E
    mov     al, 0xEC
    out     dx, al
    call    ata_settle
    mov     byte ptr [w_kind], 1
    call    wq_poll
    mov     [setup_polls], eax
    test    byte ptr [w_hit], 0x08
    jz      setup_noid
    mov     dx, 0x0640
    mov     di, offset id_buf
    mov     cx, 256
    cld
setup_idrd:
    in      ax, dx
    stosw
    loop    setup_idrd
setup_noid:
    mov     dx, 0x064E
    in      al, dx
    mov     [setup_st1], al
    sti
    call    irq9_unmask

    mov     dx, offset msg_ident
    call    puts
    mov     al, [setup_st0]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [setup_st1]
    call    puthex8
    mov     dx, offset msg_ident_p
    call    puts
    mov     eax, [setup_polls]
    call    puthex32
    call    putnl

    mov     dx, offset msg_geo
    call    puts
    mov     ax, [id_buf+2]      /* word 1: cylinders */
    call    puthex16
    mov     dl, ' '
    call    putc
    mov     ax, [id_buf+6]      /* word 3: heads */
    call    puthex16
    mov     dl, ' '
    call    putc
    mov     ax, [id_buf+12]     /* word 6: sectors per track */
    call    puthex16
    mov     dl, ' '
    call    putc
    mov     ax, [id_buf+98]     /* word 49: capabilities */
    call    puthex16
    mov     dl, ' '
    call    putc
    mov     ax, [id_buf+120]    /* word 60: LBA total (low) */
    call    puthex16
    mov     dl, ' '
    call    putc
    mov     ax, [id_buf+122]    /* word 61: LBA total (high) */
    call    puthex16
    call    putnl

    /* nsec = min(8, max(1, spt-3)): READN uses sectors 1..nsec and READ1
     * walks nsec+1..nsec+3, so the whole scratch layout stays inside
     * cylinder 0 / head 0 / one track and no read crosses a boundary. */
    mov     ax, [id_buf+12]
    cmp     ax, 4
    jae     setup_spt_ok
    mov     ax, 4
setup_spt_ok:
    sub     ax, 3
    cmp     ax, 8
    jbe     setup_ns_ok
    mov     ax, 8
setup_ns_ok:
    mov     [r_nsec], ax

    mov     dx, offset msg_range
    call    puts
    mov     ax, [r_nsec]
    call    putdec16
    mov     dx, offset msg_range_spt
    call    puts
    mov     ax, [id_buf+12]
    call    putdec16
    call    putnl

    mov     dx, offset msg_rates
    call    puts

    mov     dx, offset msg_end_setup
    call    puts
    ret

/* ==================================================================
 * section: CAL - the poll-cost shape and the anchor cross-check
 *
 * Each row is TM_N iterations of one access shape in a cli window, with an
 * interleaved control row of the same loop minus the access, exactly the
 * ioprobe.s method.  The rows:
 *   BASE    the control (register move)
 *   WAIT5F  005F write (the documented 600 ns / 30 clk I/O-wait anchor: the
 *           cross-check of the anchor question this run also settles)
 *   POLLSTA bare `in al,064E` (the marginal cost of one status read)
 *   POLLALT bare `in al,074C` (alternate status: same device, no IRQ ack)
 *   POLLLP  one iteration of the REAL DRQ poll loop used by READN/READ1
 *           (in + inc + test + jnz + loop) - the per-poll cost to net out
 *   DATWORD bare `in ax,0640` (the per-word transfer cost floor; only run
 *           when no data is pending)
 *   TSTAMP  one timestamp pair (pit_read + artic_read): the window-bracket
 *           overhead, so the decoder can bound its bias on small windows
 * ================================================================== */
sec_cal:
    mov     dx, offset msg_begin_cal
    call    puts

    call    cal_base
    mov     dx, 0x005F
    mov     bl, 2
    mov     si, offset lbl_wait5f
    call    tm_run
    call    cal_row

    call    cal_base
    mov     dx, 0x064E
    mov     bl, 1
    mov     si, offset lbl_pollsta
    call    tm_run
    call    cal_row

    call    cal_base
    mov     dx, 0x074C
    mov     bl, 1
    mov     si, offset lbl_pollalt
    call    tm_run
    call    cal_row

    call    cal_base
    mov     si, offset lbl_polllp
    call    cal_poll_run
    call    cal_row

    /* DATWORD: skip (and say so) when BSY or DRQ is set, because a data-port
     * read with data pending drains a word. */
    call    cal_base
    cli
    mov     dx, 0x064E
    in      al, dx
    sti
    test    al, 0x88
    jnz     cal_skipword
    mov     dx, 0x0640
    mov     bl, 3
    mov     si, offset lbl_datword
    call    tm_run
    call    cal_row
    jmp     cal_word_done
cal_skipword:
    mov     dx, offset msg_cal_skip
    call    puts
cal_word_done:

    call    cal_base
    mov     si, offset lbl_tstamp
    call    cal_ts_run
    call    cal_row

    /* the trailing control, so the last class's base is also beside it */
    call    cal_base
    mov     dx, offset msg_end_cal
    call    puts
    ret

/* cal_base: run the control window and park its deltas in tm_base_pd/tm_base_ad. */
cal_base:
    push    ax
    push    dx
    push    si
    xor     dx, dx
    mov     bl, 0
    mov     si, offset lbl_base
    call    tm_run
    mov     ax, [tm_pd]
    mov     [tm_base_pd], ax
    mov     eax, [tm_ad]
    mov     [tm_base_ad], eax
    pop     si
    pop     dx
    pop     ax
    ret

/* cal_row: print the last window as one fixed CAL row (label in tm_label,
 * mode char in tm_mode, both set by the run routine), then self-check both of
 * its windows: the row's own pit/artic pair and the interleaved control's. */
cal_row:
    push    ax
    push    dx
    mov     dx, offset msg_cal_pre
    call    puts
    mov     dx, [tm_label]
    call    puts
    mov     dx, offset msg_r_port
    call    puts
    mov     ax, [tm_port]
    call    puthex16
    mov     dx, offset msg_r_mode
    call    puts
    mov     dl, [tm_mode]
    call    putc
    mov     dx, offset msg_r_pit
    call    puts
    mov     ax, [tm_pd]
    call    puthex16
    mov     dx, offset msg_r_base
    call    puts
    mov     ax, [tm_base_pd]
    call    puthex16
    mov     dx, offset msg_r_artic
    call    puts
    mov     eax, [tm_ad]
    call    puthex32
    mov     dx, offset msg_r_bartic
    call    puts
    mov     eax, [tm_base_ad]
    call    puthex32
    call    putnl
    mov     eax, [tm_ad]
    mov     dx, [tm_pd]
    call    chk_pair
    mov     eax, [tm_base_ad]
    mov     dx, [tm_base_pd]
    call    chk_pair
    pop     dx
    pop     ax
    ret

/* tm_run: one bracketed window of TM_N iterations.  DX = port, BL = kind
 * (0 base / 1 in al / 2 out al,al=0 / 3 in ax), SI = label.  Leaves the raw
 * PIT counts moved in [tm_pd] (16-bit mod 65536) and the ARTIC delta in
 * [tm_ad].  NO halving and NO divisor correction: a raster check on the machine found
 * the machine's channel 0 counts once per oscillator clock, and the ARTIC
 * column is the wrap/tear referee. */
tm_run:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    mov     [tm_port], dx
    /* tm_mode stores the printable mode char, not the raw kind byte (kind
     * 0-3 would print as control characters): 0 base
     * -> 'B', 1 in al -> 'R', 2 out al -> 'W', 3 in ax -> 'Q'. */
    mov     al, 'B'
    cmp     bl, 0
    je      tm_mode_set
    mov     al, 'R'
    cmp     bl, 1
    je      tm_mode_set
    mov     al, 'W'
    cmp     bl, 2
    je      tm_mode_set
    mov     al, 'Q'
tm_mode_set:
    mov     [tm_mode], al
    mov     [tm_label], si
    xor     al, al
    cli
    call    ts_mark
    mov     eax, [ts_a]
    mov     [tm_a0], eax
    mov     ax, [ts_p]
    mov     [tm_p0], ax
    mov     cx, TM_N
tmr_loop:
    test    bl, bl
    jz      tmr_base
    cmp     bl, 2
    je      tmr_out
    cmp     bl, 3
    je      tmr_word
    in      al, dx
    jmp     tmr_next
tmr_out:
    out     dx, al
    jmp     tmr_next
tmr_word:
    in      ax, dx
    jmp     tmr_next
tmr_base:
    mov     al, 0
tmr_next:
    dec     cx
    jnz     tmr_loop
    call    ts_mark
    mov     eax, [ts_a]
    mov     [tm_a1], eax
    mov     ax, [ts_p]
    mov     [tm_p1], ax
    sti
    call    tm_finish
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* cal_poll_run: one bracketed window of TM_N iterations of the REAL DRQ poll
 * loop's instruction shape (wq_loop: in + inc + test + jnz + loop, with the
 * test mask 0x00 so the loop always runs its course and both paths take the
 * same branch directions as an early real poll).  Per-poll cost = window /
 * TM_N, status read and loop overhead included: this is the number to net
 * out of the drq windows. */
cal_poll_run:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    mov     dx, 0x064E
    mov     [tm_port], dx
    mov     byte ptr [tm_mode], 'P'
    mov     [tm_label], si
    cli
    call    ts_mark
    mov     eax, [ts_a]
    mov     [tm_a0], eax
    mov     ax, [ts_p]
    mov     [tm_p0], ax
    mov     cx, TM_N
cpr_loop:
    in      al, dx
    inc     dword ptr [tm_polldummy]
    test    al, byte ptr [cal_zero]
    jnz     cpr_hit
    loop    cpr_loop
    jmp     cpr_done
cpr_hit:
cpr_done:
    call    ts_mark
    mov     eax, [ts_a]
    mov     [tm_a1], eax
    mov     ax, [ts_p]
    mov     [tm_p1], ax
    sti
    call    tm_finish
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* cal_ts_run: one bracketed window of TM_N timestamp pairs (ts_mark), the
 * window-bracket overhead itself. */
cal_ts_run:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    xor     dx, dx
    mov     [tm_port], dx
    mov     byte ptr [tm_mode], 'T'
    mov     [tm_label], si
    cli
    call    ts_mark
    mov     eax, [ts_a]
    mov     [tm_a0], eax
    mov     ax, [ts_p]
    mov     [tm_p0], ax
    mov     cx, TM_N
ctr_loop:
    call    ts_mark
    loop    ctr_loop
    call    ts_mark
    mov     eax, [ts_a]
    mov     [tm_a1], eax
    mov     ax, [ts_p]
    mov     [tm_p1], ax
    sti
    call    tm_finish
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* tm_finish: the shared tail of the three window runners: raw PIT counts
 * moved (16-bit mod 65536) and the ARTIC delta (32-bit), no corrections.  The
 * PIT counts down and the ARTIC counts up, so the two subtractions take their
 * operands in opposite order (see the SIGN CONVENTION header note). */
tm_finish:
    mov     eax, [tm_a1]
    sub     eax, [tm_a0]
    mov     [tm_ad], eax
    mov     ax, [tm_p0]
    sub     ax, [tm_p1]         /* 16-bit mod: one reload shows as a wrapped delta */
    mov     [tm_pd], ax
    ret

/* chk_pair: the row self-check.  EAX = a window's ARTIC ticks, DX = the same
 * window's raw PIT counts.  One window has ONE duration, so the two columns
 * MUST agree at 8 raw PIT counts per ARTIC tick (0.5%
 * over three windows on two programs), and a sign or operand-order slip in
 * either subtraction - the defect that printed the first capture's READ rows
 * with a negative ARTIC column - shows up here as an impossible ratio rather
 * than as a plausible-looking number.  Tolerance: 10% of the expected counts,
 * floored at 16 counts (a window's ends are quantised by one count per side
 * and its ARTIC pair by one tick, so small windows cannot resolve 10%).
 * Anything below one ARTIC tick has no second base and is counted as sub.
 * A failure prints its own line - the row directly above it - and the run
 * exits 1 from the SELFCHECK section.  cli-free: it only prints.
 *
 * THE PIT COUNT MUST NOT RIDE IN AX.  The two values need two registers, and
 * the first shipped version passed (EAX = ARTIC, AX = PIT) believing `mov ax,`
 * only touched the low half: it does, but the ARTIC delta is a 16-bit-sized
 * number, so EAX became the PIT value and the scaled operand was the PIT
 * (IDELAT-fixed.TXT: `PIT delta=112D but 8 x ARTIC delta=00008968`, i.e.
 * 8 x 112D, on all 58 windows - the data was fine).  DX carries the PIT.
 * A disassembly of the built image's call sites confirmed which field is
 * scaled.
 * ASSUMES THE 2.4576 MHz STRAP (8:1).  See the header: on a 0x4E00 machine the
 * law is 6.5:1 and this check flags every window, so read the PITDIV strap line
 * before diagnosing a failure as a sign or operand-order defect. */
chk_pair:
    push    eax
    push    ebx
    push    ecx
    push    edx
    movzx   ebx, dx                 /* EBX = the measured PIT counts */
    inc     word ptr [chk_win]
    cmp     eax, 1
    jae     cp_have_art
    inc     word ptr [chk_sub]      /* sub-tick: PIT is the only base */
    jmp     cp_out
cp_have_art:
    shl     eax, 3                  /* EAX = 8 x ticks = the expected counts */
    mov     ecx, ebx
    sub     ecx, eax
    jns     cp_abs
    neg     ecx
cp_abs:
    inc     word ptr [chk_ok]
    cmp     ecx, 16                 /* the quantisation floor, in counts */
    jbe     cp_out
    lea     edx, [ecx+ecx*4]
    add     edx, edx                /* EDX = 10 x |difference| */
    cmp     edx, eax                /* 10% of the expected counts? */
    jbe     cp_out
    dec     word ptr [chk_ok]
    inc     word ptr [chk_fail]
    mov     byte ptr [run_fail], 1
    push    eax
    mov     dx, offset msg_chk_fail
    call    puts
    mov     ax, bx
    call    puthex16
    mov     dx, offset msg_chk_vs
    call    puts
    pop     eax
    call    puthex32
    call    putnl
cp_out:
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

/* ==================================================================
 * sections: READN (count=N) and READ1 (count=1) - the latency set
 * ================================================================== */
/* sec_readn: two multi-sector trials of N=nsec sectors on (cyl 0, head 0):
 * t=1 sectors 1..nsec (first-touch this probe), t=2 the same range again
 * (immediate re-read = the drive's own cache warm).  One RN row per block
 * plus one RNEND completion row per trial. */
sec_readn:
    mov     dx, offset msg_begin_readn
    call    puts
    mov     ax, [r_nsec]
    mov     [r_count], ax
    mov     word ptr [r_sec], 1
    mov     byte ptr [r_warm], 0
    mov     byte ptr [r_t], 1
    call    cmd_read
    call    rn_print
    mov     byte ptr [r_warm], 1
    mov     byte ptr [r_t], 2
    call    cmd_read
    call    rn_print
    mov     dx, offset msg_end_readn
    call    puts
    ret

/* sec_read1: three single-sector trials walking sectors nsec+1..nsec+3
 * (first-touch this probe), then three immediate re-reads of sector nsec+1
 * (warm). */
sec_read1:
    mov     dx, offset msg_begin_read1
    call    puts
    mov     word ptr [r_count], 1
    mov     ax, [r_nsec]
    inc     ax
    mov     [r_sec], ax
    mov     byte ptr [r_warm], 0
    mov     byte ptr [r_t], 1
    call    cmd_read
    call    r1_print
    mov     byte ptr [r_t], 2
    inc     word ptr [r_sec]
    call    cmd_read
    call    r1_print
    mov     byte ptr [r_t], 3
    inc     word ptr [r_sec]
    call    cmd_read
    call    r1_print
    mov     ax, [r_nsec]
    inc     ax
    mov     [r_sec], ax
    mov     byte ptr [r_warm], 1
    mov     byte ptr [r_t], 4
    call    cmd_read
    call    r1_print
    mov     byte ptr [r_t], 5
    call    cmd_read
    call    r1_print
    mov     byte ptr [r_t], 6
    call    cmd_read
    call    r1_print
    mov     dx, offset msg_end_read1
    call    puts
    ret

/* cmd_read: one READ SECTORS trial.  [r_count] sectors from [r_sec] on
 * (cylinder 0, head 0, master).  Per block k=1..count the DRQ window and the
 * 256-word transfer window are timestamped into rt_*[k]; then the completion
 * window (until BSY and DRQ are both clear).  rt_to: 0 = ok, 1 = poll
 * timeout, 2 = ERR.  A failed trial drains any pending block first. */
cmd_read:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    call    irq9_mask
    cli

    mov     word ptr [rt_k], 0
    mov     byte ptr [rt_to], 0
    mov     word ptr [rt_cksum], 0

    /* task-file setup: head first, then count/sector/cylinder (all zero but
     * the sector), then the command. */
    mov     dx, 0x064C
    mov     al, 0xA0            /* master, CHS, head 0 */
    out     dx, al
    call    ata_settle
    mov     dx, 0x0644
    mov     ax, [r_count]
    out     dx, al
    mov     dx, 0x0646
    mov     ax, [r_sec]
    out     dx, al
    mov     dx, 0x0648
    xor     al, al
    out     dx, al
    mov     dx, 0x064A
    xor     al, al
    out     dx, al
    call    ata_settle

    /* window 0 boundary: right before the command write, so the k=1 drq
     * window IS "command issue -> first DRQ" including the out itself. */
    call    ts_mark
    mov     eax, [ts_a]
    mov     [rt_da0], eax
    mov     ax, [ts_p]
    mov     [rt_dp0], ax

    mov     dx, 0x064E
    mov     al, 0x20            /* READ SECTORS (read-only; the ONLY command) */
    out     dx, al

cr_blocks:
    /* DRQ wait for block [rt_k] (0-based); its window start is rt_dp0/rt_da0
     * (before the command for k=0, the previous transfer end after that). */
    mov     byte ptr [w_kind], 1
    call    wq_poll
    movzx   ebx, word ptr [rt_k]
    mov     dword ptr [rt_polls+ebx*4], eax
    mov     al, [w_hit]
    mov     [rt_st+ebx], al
    cmp     byte ptr [w_to], 0
    jne     cr_timeout
    test    byte ptr [w_hit], 0x08
    jnz     cr_have_drq
    mov     byte ptr [rt_to], 2     /* ERR without DRQ */
    jmp     cr_fail
cr_timeout:
    mov     byte ptr [rt_to], 1
    jmp     cr_fail
cr_have_drq:
    call    ts_mark
    mov     eax, [ts_a]
    mov     [rt_da1+ebx*4], eax
    mov     ax, [ts_p]
    mov     [rt_dp1+ebx*2], ax
    mov     ax, [rt_dp0]
    sub     ax, [rt_dp1+ebx*2]  /* PIT counts DOWN: start - end */
    mov     [rt_dpd+ebx*2], ax
    mov     eax, [rt_da1+ebx*4] /* ARTIC counts UP: end - start. The operands
                                 * were inverted here in the first shipped
                                 * build, which printed every READ row's ARTIC
                                 * column negative (IDELAT.TXT drq_art=
                                 * FFFFFECD); the self-check below catches it. */
    sub     eax, [rt_da0]
    mov     [rt_dad+ebx*4], eax

    /* the 256-word PIO transfer block */
    mov     dx, 0x0640
    mov     cx, 256
    xor     di, di
    call    ts_mark
    mov     eax, [ts_a]
    mov     [rt_xa0], eax
    mov     ax, [ts_p]
    mov     [rt_xp0], ax
cr_words:
    in      ax, dx
    add     di, ax
    loop    cr_words
    call    ts_mark
    mov     eax, [ts_a]
    mov     [rt_xa1+ebx*4], eax
    mov     ax, [ts_p]
    mov     [rt_xp1+ebx*2], ax
    mov     ax, [rt_xp0]
    sub     ax, [rt_xp1+ebx*2]  /* PIT counts DOWN */
    mov     [rt_xpd+ebx*2], ax
    mov     eax, [rt_xa1+ebx*4] /* ARTIC counts UP (see cr_have_drq) */
    sub     eax, [rt_xa0]
    mov     [rt_xad+ebx*4], eax
    mov     [rt_ck+ebx*2], di
    add     [rt_cksum], di

    /* the transfer end mark is the next block's drq-window start */
    mov     eax, [rt_xa1+ebx*4]
    mov     [rt_da0], eax
    mov     ax, [rt_xp1+ebx*2]
    mov     [rt_dp0], ax

    inc     word ptr [rt_k]
    mov     ax, [rt_k]
    cmp     ax, [r_count]
    jb      cr_blocks

    /* completion: until BSY and DRQ are both clear */
    mov     byte ptr [w_kind], 2
    call    wq_poll
    mov     [rt_cpolls], eax
    mov     al, [w_hit]
    mov     [rt_cst], al
    call    ts_mark
    mov     eax, [ts_a]
    mov     [rt_da1], eax
    mov     ax, [ts_p]
    mov     [rt_dp1], ax
    mov     ax, [rt_dp0]
    sub     ax, [rt_dp1]        /* PIT counts DOWN */
    mov     [rt_cpd], ax
    mov     eax, [rt_da1]       /* ARTIC counts UP (see cr_have_drq) */
    sub     eax, [rt_da0]
    mov     [rt_cad], eax
    cmp     byte ptr [w_to], 0
    je      cr_done
    mov     byte ptr [rt_to], 1
    jmp     cr_fail

cr_fail:
    call    ata_drain

cr_done:
    /* final status read acknowledges the interrupt; leave nothing pending */
    mov     dx, 0x064E
    in      al, dx
    mov     [rt_fst], al
    sti
    call    irq9_unmask
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* rn_print: one RN row per transferred block, then the RNEND row.  BX is the
 * block index (0-based); k prints as BX+1 and sec as r_sec+BX. */
rn_print:
    push    ax
    push    bx
    push    cx
    push    dx
    push    ebx
    xor     ebx, ebx
rnp_loop:
    cmp     bx, [rt_k]
    jae     rnp_end
    mov     dx, offset msg_rn_pre
    call    puts
    mov     al, [r_t]
    call    putdec8
    mov     dx, offset msg_rn_k
    call    puts
    mov     ax, bx
    inc     ax
    call    putdec16
    mov     dx, offset msg_rn_sec
    call    puts
    mov     ax, [r_sec]
    add     ax, bx
    call    putdec16
    mov     dx, offset msg_rn_st
    call    puts
    mov     al, [rt_st+ebx]
    call    puthex8
    mov     dx, offset msg_rn_polls
    call    puts
    mov     eax, [rt_polls+ebx*4]
    call    puthex32
    mov     dx, offset msg_rn_to
    call    puts
    mov     al, [rt_to]
    call    putdec8
    mov     dx, offset msg_rn_ck
    call    puts
    mov     ax, [rt_ck+ebx*2]
    call    puthex16
    mov     dx, offset msg_rn_dpit
    call    puts
    mov     ax, [rt_dpd+ebx*2]
    call    puthex16
    mov     dx, offset msg_rn_dart
    call    puts
    mov     eax, [rt_dad+ebx*4]
    call    puthex32
    mov     dx, offset msg_rn_xpit
    call    puts
    mov     ax, [rt_xpd+ebx*2]
    call    puthex16
    mov     dx, offset msg_rn_xart
    call    puts
    mov     eax, [rt_xad+ebx*4]
    call    puthex32
    call    putnl
    mov     eax, [rt_dad+ebx*4]
    mov     dx, [rt_dpd+ebx*2]
    call    chk_pair
    mov     eax, [rt_xad+ebx*4]
    mov     dx, [rt_xpd+ebx*2]
    call    chk_pair
    inc     ebx
    jmp     rnp_loop
rnp_end:
    mov     dx, offset msg_rnend_pre
    call    puts
    mov     al, [r_t]
    call    putdec8
    mov     dx, offset msg_rn_st
    call    puts
    mov     al, [rt_cst]
    call    puthex8
    mov     dx, offset msg_rn_polls
    call    puts
    mov     eax, [rt_cpolls]
    call    puthex32
    mov     dx, offset msg_rn_to
    call    puts
    mov     al, [rt_to]
    call    putdec8
    mov     dx, offset msg_rnend_dpit
    call    puts
    mov     ax, [rt_cpd]
    call    puthex16
    mov     dx, offset msg_rnend_dart
    call    puts
    mov     eax, [rt_cad]
    call    puthex32
    mov     dx, offset msg_rnend_sck
    call    puts
    mov     ax, [rt_cksum]
    call    puthex16
    mov     dx, offset msg_rnend_fst
    call    puts
    mov     al, [rt_fst]
    call    puthex8
    call    putnl
    /* The completion window is only meaningful on a trial that completed its
     * poll (a timeout leaves rt_cpd/rt_cad stale). */
    cmp     byte ptr [rt_to], 0
    jne     rnp_ckdone
    mov     eax, [rt_cad]
    mov     dx, [rt_cpd]
    call    chk_pair
rnp_ckdone:
    pop     ebx
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* r1_print: the same buffers as one R1 row (count 1, block index 0). */
r1_print:
    push    ax
    push    dx
    mov     dx, offset msg_r1_pre
    call    puts
    mov     al, [r_t]
    call    putdec8
    mov     dx, offset msg_rn_sec
    call    puts
    mov     ax, [r_sec]
    call    putdec16
    mov     dx, offset msg_r1_warm
    call    puts
    mov     al, [r_warm]
    call    putdec8
    mov     dx, offset msg_r1_st0
    call    puts
    mov     al, [rt_st]
    call    puthex8
    mov     dx, offset msg_r1_st1
    call    puts
    mov     al, [rt_fst]
    call    puthex8
    mov     dx, offset msg_rn_polls
    call    puts
    mov     eax, [rt_polls]
    call    puthex32
    mov     dx, offset msg_rn_to
    call    puts
    mov     al, [rt_to]
    call    putdec8
    mov     dx, offset msg_rn_ck
    call    puts
    mov     ax, [rt_ck]
    call    puthex16
    mov     dx, offset msg_rn_dpit
    call    puts
    mov     ax, [rt_dpd]
    call    puthex16
    mov     dx, offset msg_rn_dart
    call    puts
    mov     eax, [rt_dad]
    call    puthex32
    mov     dx, offset msg_rn_xpit
    call    puts
    mov     ax, [rt_xpd]
    call    puthex16
    mov     dx, offset msg_rn_xart
    call    puts
    mov     eax, [rt_xad]
    call    puthex32
    call    putnl
    /* rt_dpd/rt_dad/rt_xpd/rt_xad hold a completed block's windows; on a
     * timeout or ERR they are stale, so only a clean trial is checked. */
    cmp     byte ptr [rt_to], 0
    jne     r1p_ckdone
    mov     eax, [rt_dad]
    mov     dx, [rt_dpd]
    call    chk_pair
    mov     eax, [rt_xad]
    mov     dx, [rt_xpd]
    call    chk_pair
r1p_ckdone:
    pop     dx
    pop     ax
    ret

/* ==================================================================
 * section: SELFCHECK - the pit:artic 8:1 verdict over every window printed
 * ================================================================== */
/* Every window the probe printed was checked by chk_pair as it was printed;
 * this section is the tally.  fail > 0 means the capture's own columns
 * disagree and MUST NOT be quoted; the run also exits 1 (probe2's habit), so
 * a harness can see it without reading the text. */
sec_check:
    mov     dx, offset msg_begin_check
    call    puts
    mov     dx, offset msg_chk_line
    call    puts
    mov     ax, [chk_win]
    call    putdec16
    mov     dx, offset msg_chk_oklb
    call    puts
    mov     ax, [chk_ok]
    call    putdec16
    mov     dx, offset msg_chk_faillb
    call    puts
    mov     ax, [chk_fail]
    call    putdec16
    mov     dx, offset msg_chk_sublb
    call    puts
    mov     ax, [chk_sub]
    call    putdec16
    call    putnl
    cmp     byte ptr [run_fail], 0
    je      chk_out
    mov     dx, offset msg_chk_bad
    call    puts
chk_out:
    mov     dx, offset msg_end_check
    call    puts
    ret

/* ==================================================================
 * section: RESTORE - the bank byte back, and the honest write ledger
 * ================================================================== */
sec_restore:
    mov     dx, offset msg_begin_restore
    call    puts
    cli
    mov     dx, 0x0432
    mov     al, [bank_save]
    out     dx, al
    mov     dx, 0x0432
    in      al, dx
    mov     [bank_now], al
    sti
    mov     dx, offset msg_restore_432
    call    puts
    mov     al, [bank_save]
    call    puthex8
    mov     dx, offset msg_restore_arrow
    call    puts
    mov     al, [bank_now]
    call    puthex8
    call    putnl
    mov     dx, offset msg_writes
    call    puts
    mov     dx, offset msg_end_restore
    call    puts
    ret

/* ==================================================================
 * time-stamp and counter helpers
 * ================================================================== */
/* ts_mark: [ts_p] = PIT channel-0's latched count (measured byte order),
 * [ts_a] = the ARTIC free-running counter.  PIT is read first at every
 * boundary, so a PIT window is narrower than its ARTIC window by one counter
 * read per side (the TSTAMP row measures that overhead).  Read-only. */
ts_mark:
    push    ax
    call    pit_read
    mov     [ts_p], ax
    call    artic_read
    mov     [ts_a], eax
    pop     ax
    ret

/* wq_poll: the DRQ/completion poll loop.  [w_kind] 1 = until (status &
 * 0x09) != 0 (DRQ or ERR), 2 = until (status & 0x88) == 0 (not BSY, no DRQ).
 * Out: EAX = polls taken, [w_hit] = the status byte that satisfied the test,
 * [w_to] = 1 when the bound expired first.  wq_loop's instruction shape is
 * EXACTLY cal_poll_run's (same access, same memory-operand test, same branch
 * directions), which is what makes the POLLLP row the real per-poll cost.
 * Runs under the caller's cli. */
wq_poll:
    push    bx
    push    cx
    push    dx
    push    bp
    mov     dword ptr [w_polls], 0
    mov     byte ptr [w_to], 0
    mov     dx, 0x064E
    mov     bp, POLL_HI
    mov     bl, [w_kind]
    cmp     bl, 2
    je      wq2_outer
    mov     byte ptr [w_mask], 0x09
wq_outer:
    mov     cx, 0
wq_loop:
    in      al, dx
    inc     dword ptr [w_polls]
    test    al, byte ptr [w_mask]
    jnz     wq_hit
    loop    wq_loop
    dec     bp
    jnz     wq_outer
    mov     byte ptr [w_to], 1
    jmp     wq_hit
wq2_outer:
    mov     byte ptr [w_mask], 0x88
    mov     cx, 0
wq2_loop:
    in      al, dx
    inc     dword ptr [w_polls]
    test    al, byte ptr [w_mask]
    jz      wq_hit
    loop    wq2_loop
    dec     bp
    jnz     wq2_outer
    mov     byte ptr [w_to], 1
wq_hit:
    mov     [w_hit], al
    mov     eax, [w_polls]
    pop     bp
    pop     dx
    pop     cx
    pop     bx
    ret

/* ata_drain: after a failed trial, leave the drive with nothing pending.  A
 * completion timeout can end with BSY still set and no DRQ ever raised, so:
 * first a bounded wait for BSY to clear (a data-port read while BSY is an
 * error on some drives and would consume the next block's first word), then
 * consume any pending DRQ blocks (bounded), then the bounded BSY-clear wait
 * once at exit so the next trial's setup cannot race a busy drive. */
ata_drain:
    push    ax
    push    cx
    push    dx
    call    ad_wait_bsy
    mov     cx, 32
ad_block:
    push    cx
    mov     dx, 0x064E
    in      al, dx
    test    al, 0x08
    jz      ad_done
    mov     dx, 0x0640
    mov     cx, 256
ad_words:
    in      ax, dx
    loop    ad_words
    pop     cx
    loop    ad_block
    jmp     ad_out
ad_done:
    pop     cx
ad_out:
    call    ad_wait_bsy
    pop     dx
    pop     cx
    pop     ax
    ret

/* ad_wait_bsy: bounded poll of 064E until BSY (bit 7) clears.  At most
 * 16 x 65536 polls; a drive that stays busy is not fought with here. */
ad_wait_bsy:
    push    bx
    push    cx
    push    dx
    mov     bx, 16
awb_outer:
    mov     cx, 0
awb_inner:
    mov     dx, 0x064E
    in      al, dx
    test    al, 0x80
    jz      awb_done
    loop    awb_inner
    dec     bx
    jnz     awb_outer
awb_done:
    pop     dx
    pop     cx
    pop     bx
    ret

/* ata_settle: a short settle after a register write (a few I/O reads). */
ata_settle:
    push    ax
    push    cx
    push    dx
    mov     cx, 20
asl_loop:
    mov     dx, 0x0060
    in      al, dx
    loop    asl_loop
    pop     dx
    pop     cx
    pop     ax
    ret

/* irq9_mask / irq9_unmask: mask or restore the slave 8259's IRQ9 line (bit 1)
 * around a command window (ideprobe.s's rule). */
irq9_mask:
    push    ax
    push    dx
    mov     dx, 0x000A
    in      al, dx
    mov     [imr_s_save], al
    or      al, 0x02
    out     dx, al
    pop     dx
    pop     ax
    ret

irq9_unmask:
    push    ax
    push    dx
    mov     dx, 0x000A
    mov     al, [imr_s_save]
    out     dx, al
    pop     dx
    pop     ax
    ret

/* artic_read: EAX = the free-running counter at 005C (bits 15:0) / 005F
 * (bits 23:16).  005D and 005E both mirror cnt[15:8]; 005F is cnt[23:16].
 * The low word wraps every 213 ms at the documented 307200 Hz and the 24-bit
 * value every 54.6 s, so it is read again after the high byte and a low-word
 * wrap bumps the high byte.  Read-only. */
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

/* pit_latch: the PIT counter-latch command, 0077 <- 00. Stateless. */
pit_latch:
    push    dx
    push    ax
    mov     dx, 0x0077
    mov     al, 0x00
    out     dx, al
    pop     ax
    pop     dx
    ret

/* pit_read: AX = channel 0's latched count, in the byte order pit_cal
 * measured.  cli covers the latch, the two reads and the calibration. */
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

/* pit_word: one latched pair -> AX, in the byte order pit_cal decided. */
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

/* pit_cal: set pit_swap by watching which of the two bytes 0071 returns
 * moves.  The machine counts once per oscillator clock,
 * so over 32 paired reads the LSB falls on almost every sample and the MSB on
 * almost none; the byte that falls more often is the LSB.  The latch command
 * does not restore the read pointer on this machine, so the order is measured,
 * not assumed. */
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

/* tm_div_probe: DIAGNOSTIC ONLY - this probe's timing never uses the divisor.
 * The absolute latch word is known to tear (scans have
 * returned 0xFFFA/0xD12E-class words that cannot be a count of the BIOS's
 * 0x6000 divisor), so each candidate is now sampled TWICE back to back and
 * only a coherent pair (words within COHERENT counts) is accepted; the scan
 * runs 30 ms of ARTIC ticks (9216), which covers any possible 16-bit period,
 * and prints accepted/attempted so a still-broken run is visible at a glance. */
tm_div_probe:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     word ptr [tm_div], 0
    mov     word ptr [tm_dtry], 0
    mov     word ptr [tm_daccept], 0
    cli
    call    artic_read
    mov     [tm_a0], eax
    mov     word ptr [tm_guard], DIV_GUARD
tdp_loop:
    call    pit_word
    mov     bx, ax
    call    pit_word
    mov     cx, ax
    inc     word ptr [tm_dtry]
    mov     ax, bx
    sub     ax, cx
    jns     tdp_d1
    neg     ax
tdp_d1:
    cmp     ax, COHERENT
    ja      tdp_next
    inc     word ptr [tm_daccept]
    cmp     bx, [tm_div]
    jbe     tdp_next
    mov     [tm_div], bx
tdp_next:
    call    artic_read
    sub     eax, [tm_a0]
    cmp     eax, DIV_TICKS
    jae     tdp_done
    dec     word ptr [tm_guard]
    jnz     tdp_loop
tdp_done:
    sti
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* ==================================================================
 * Output helpers (the ideprobe.s set)
 * ================================================================== */
putc:                           /* DL = character */
    push    ax
    push    bx
    push    cx
    push    dx
    mov     ah, 0x02
    int     0x21
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

puts:                           /* DX = '$'-terminated string */
    push    ax
    push    dx
    mov     ah, 0x09
    int     0x21
    pop     dx
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

puthexdig:                      /* AL = 0..15 -> one ASCII hex digit */
    push    ax
    push    dx
    and     al, 0x0F
    cmp     al, 10
    jb      phd_lo
    add     al, 'A' - 10
    jmp     phd_out
phd_lo:
    add     al, '0'
phd_out:
    mov     dl, al
    call    putc
    pop     dx
    pop     ax
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

putdec8:                        /* AL, unsigned decimal */
    push    ax
    movzx   ax, al
    call    putdec16
    pop     ax
    ret

putdec16:                       /* AX, unsigned decimal */
    push    ax
    push    bx
    push    cx
    push    dx
    mov     bx, 10
    xor     cx, cx
pd_loop:
    xor     dx, dx
    div     bx
    push    dx
    inc     cx
    test    ax, ax
    jnz     pd_loop
pd_out:
    pop     dx
    add     dl, '0'
    call    putc
    loop    pd_out
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* ==================================================================
 * Data
 * ================================================================== */
/* Row labels are '$'-terminated like every other printed string, NOT .asciz:
 * the only string printer is puts (DOS AH=09), which runs on to the next '$'. */
lbl_base:       .ascii "BASE    $"
lbl_wait5f:     .ascii "WAIT5F  $"
lbl_pollsta:    .ascii "POLLSTA $"
lbl_pollalt:    .ascii "POLLALT $"
lbl_polllp:     .ascii "POLLLP  $"
lbl_datword:    .ascii "DATWORD $"
lbl_tstamp:     .ascii "TSTAMP  $"

msg_banner:
    .ascii "IDELAT - PC-9821 real-machine IDE READ latency probe (tools/hwprobe/idelat.s)\r\n"
    .ascii "Measures command issue -> first DRQ, per-sector PIO transfer, single- vs\r\n"
    .ascii "multi-sector READ SECTORS, word throughput and the status-poll cost shape.\r\n"
    .ascii "READ-ONLY on disk: the only ATA commands are IDENTIFY 0xEC and READ SECTORS\r\n"
    .ascii "0x20 on cylinder 0 / head 0 / sectors 1..S (one track). Time bases are the\r\n"
    .ascii "device counters: PIT 2457600 counts/s (406.9 ns) and ARTIC 307200 Hz (3255.2\r\n"
    .ascii "ns); the two must agree at 8 raw PIT counts per ARTIC tick (r13/215).\r\n"
    .ascii "Sections are BEGIN:/END: bracketed: a hang leaves a BEGIN: with no END:.\r\n$"
msg_done:       .ascii "IDELAT DONE\r\n$"

msg_begin_setup: .ascii "BEGIN:SETUP\r\n$"
msg_bank_found: .ascii "  BANK 0432 as found = $"
msg_pitcal:     .ascii "  PITCAL swap=$"
msg_pitpair:    .ascii "  PITPAIR $"
msg_pitdiv:     .ascii "  PITDIV (diagnostic only) coherent max=$"
msg_pitdiv_n:   .ascii " accepted=$"
msg_ident:      .ascii "  IDENTIFY 0xEC st0 st1 = $"
msg_ident_p:    .ascii " polls=$"
msg_geo:        .ascii "  GEO w1 w3 w6 w49 w60 w61 = $"
msg_range:      .ascii "  RANGE cyl=0000 head=00 nsec=$"
msg_range_spt:  .ascii " spt=$"
msg_rates:
    .ascii "  RATES pit_hz=2457600 artic_hz=307200 (r13/215 8:1, r13/219, raster-checked)\r\n$"
msg_end_setup:  .ascii "END:SETUP\r\n$"

msg_begin_cal:  .ascii "BEGIN:CAL\r\n$"
msg_cal_pre:    .ascii "CAL $"
msg_cal_skip:   .ascii "CAL SKIPPED DATWORD (BSY/DRQ set: a data read would drain a word)\r\n$"
msg_end_cal:    .ascii "END:CAL\r\n$"

msg_begin_readn: .ascii "BEGIN:READN\r\n$"
msg_end_readn:  .ascii "END:READN\r\n$"
msg_begin_read1: .ascii "BEGIN:READ1\r\n$"
msg_end_read1:  .ascii "END:READ1\r\n$"

msg_begin_check: .ascii "BEGIN:SELFCHECK\r\n$"
msg_end_check:   .ascii "END:SELFCHECK\r\n$"
msg_chk_line:    .ascii "  SELFCHECK windows=$"
msg_chk_oklb:    .ascii " ok=$"
msg_chk_faillb:  .ascii " fail=$"
msg_chk_sublb:   .ascii " sub=$"
msg_chk_fail:
    .ascii "  ** SELFCHECK FAIL (the row above): PIT delta=$"
msg_chk_vs:      .ascii " but 8 x ARTIC delta=$"
msg_chk_bad:
    .ascii "  ** SELF-CHECK FAILED: this capture's PIT and ARTIC columns disagree at the\r\n"
    .ascii "     8:1 law (r13/215), so neither column can be quoted. DO NOT USE THIS\r\n"
    .ascii "     CAPTURE; re-run the probe (exit code 1). **\r\n$"

msg_rn_pre:     .ascii "RN t=$"
msg_r1_pre:     .ascii "R1 t=$"
msg_rn_k:       .ascii " k=$"
msg_rn_sec:     .ascii " sec=$"
msg_r1_warm:    .ascii " warm=$"
msg_r1_st0:     .ascii " st0=$"
msg_r1_st1:     .ascii " st1=$"
msg_rn_st:      .ascii " st=$"
msg_rn_polls:   .ascii " polls=$"
msg_rn_to:      .ascii " to=$"
msg_rn_ck:      .ascii " ck=$"
msg_rn_dpit:    .ascii " drq_pit=$"
msg_rn_dart:    .ascii " drq_art=$"
msg_rn_xpit:    .ascii " xfer_pit=$"
msg_rn_xart:    .ascii " xfer_art=$"
msg_rnend_pre:  .ascii "RNEND t=$"
msg_rnend_dpit: .ascii " done_pit=$"
msg_rnend_dart: .ascii " done_art=$"
msg_rnend_sck:  .ascii " sum_ck=$"
msg_rnend_fst:  .ascii " fst=$"

msg_begin_restore: .ascii "BEGIN:RESTORE\r\n$"
msg_restore_432: .ascii "  0432 was $"
msg_restore_arrow: .ascii " -> now $"
msg_writes:
    .ascii "  writes made by this probe: 0432 bank (restored above), task-file setup\r\n"
    .ascii "  0644/0646/0648/064A/064C, 064E commands 0xEC IDENTIFY and 0x20 READ SECTORS\r\n"
    .ascii "  only, 0077<-00 (the PIT counter-latch command, stateless), 005F (the\r\n"
    .ascii "  documented write-only I/O delay port, written 1024 times by CAL WAIT5F),\r\n"
    .ascii "  and 000A (the slave IMR: saved at each command window and restored from\r\n"
    .ascii "  the save). No disk data was written: READ SECTORS is read-only and the\r\n"
    .ascii "  scratch range is cylinder 0 / head 0 / sectors 1..S - one track while\r\n"
    .ascii "  IDENTIFY word 6 is honest and >= 4; a lying/absent IDENTIFY can make a\r\n"
    .ascii "  read cross a track boundary (still read-only, the timing may include a\r\n"
    .ascii "  reposition).\r\n$"
msg_end_restore: .ascii "END:RESTORE\r\n$"

msg_r_port:     .ascii " port=$"
msg_r_mode:     .ascii " mode=$"
msg_r_pit:      .ascii " pit=$"
msg_r_base:     .ascii " base=$"
msg_r_artic:    .ascii " artic=$"
msg_r_bartic:   .ascii " bartic=$"

/* ==================================================================
 * Variables
 * ================================================================== */
bank_save:      .byte 0
bank_now:       .byte 0
imr_s_save:     .byte 0

setup_st0:      .byte 0
setup_st1:      .byte 0
setup_polls:    .long 0

pit_cal_ok:     .byte 0
pit_swap:       .byte 0
pit_b1:         .byte 0
pit_b2:         .byte 0
pit_pb1:        .byte 0
pit_pb2:        .byte 0
pit_d1:         .word 0
pit_d2:         .word 0

ts_p:           .word 0
ts_a:           .long 0

run_fail:       .byte 0
chk_win:        .word 0
chk_ok:         .word 0
chk_fail:       .word 0
chk_sub:        .word 0

tm_port:        .word 0
tm_mode:        .byte 0
tm_label:       .word 0
tm_p0:          .word 0
tm_p1:          .word 0
tm_a0:          .long 0
tm_a1:          .long 0
tm_pd:          .word 0
tm_ad:          .long 0
tm_base_pd:     .word 0
tm_base_ad:     .long 0
tm_polldummy:   .long 0
tm_div:         .word 0
tm_dtry:        .word 0
tm_daccept:     .word 0
tm_guard:       .word 0

cal_zero:       .byte 0
w_kind:         .byte 0
w_mask:         .byte 0
w_to:           .byte 0
w_hit:          .byte 0
w_polls:        .long 0

r_count:        .word 0
r_sec:          .word 0
r_nsec:         .word 0
r_warm:         .byte 0
r_t:            .byte 0

rt_k:           .word 0
rt_to:          .byte 0
rt_st:          .space 16
rt_polls:       .space 64
rt_dpd:         .space 32
rt_xpd:         .space 32
rt_ck:          .space 32
rt_dad:         .space 64
rt_xad:         .space 64
rt_dp0:         .word 0
rt_dp1:         .space 32
rt_xp0:         .word 0
rt_xp1:         .space 32
rt_da0:         .long 0
rt_da1:         .space 64
rt_xa0:         .long 0
rt_xa1:         .space 64
rt_cksum:       .word 0
rt_cpolls:      .long 0
rt_cst:         .byte 0
rt_fst:         .byte 0
rt_cpd:         .word 0
rt_cad:         .long 0

id_buf:         .space 512

/* sec_audit.inc - /AUDIT (opt-in): read-side and interrupt-line facts no capture has. Raw
 * values only; xe10t_decode.py classifies them. Run it on the core first, then on the Xe10
 * with the same binary (tools/hwprobe/README.md). Every row that touches a device is behind
 * a flushed `ROW AUDIT <tag> port=<p>` line, so the last line on disk names a row that hangs.
 *
 * 1. W<port>: word (and, where flagged, dword) IN on 8-bit ports, against two byte reads of
 *    the same ports: `b0`/`b1` = in al,P / in al,P+1, `w1`/`w2` = in ax,P twice, `d` = in
 *    eax,P (or -), `b2` = in al,P again. EAX holds A55AC33C before every wide read, so an
 *    untouched high byte reads back C3 (AX) or A55A (EAX). One port per class of NP2kai's
 *    word-read table (io/iocore16.tbl: word_term `0x01,0x03,...` -> 0x2588 without touching
 *    the port, active_term 0xD0.. -> the old AH, plus_term 0x30/0x40/0x71/0xAD -> AH = FF,
 *    minus_term 0x60/0x70/0xA0 -> AH = 00, ext08_term 0x20/0x22 -> AH = 08; io/iocore.c
 *    iocore_inp16 `case TERM_WORD: return(WORD_TERMINATE);`), plus the ports a guest reads
 *    as words. Side-effect rows:
 *    P0070/P0071: ch0 loaded in mode 0 with AU_PITKNOWN (0x80F0: the count reads 80xx,
 *      xx >= A0, while the row runs, so its bytes differ), latched (0x77 <- 00) and read
 *      (a0 a1 = v0), latched again, `in ax,P`, then 0x71 read twice (x1, x2); the control
 *      word is written again (it resets the read sequence) and v1 read. x1 = the LSB (xx):
 *      the word read left 0x71 alone; x1 = 80 (the MSB): it consumed the latch's first byte.
 *      Refused (with the IRQ0 rows) when IRQ0 is unmasked as found.
 *    D0001/D0000: DMA channel 2 masked, its address loaded with C33C (r0 r1 = 3C C3), the
 *      byte-pointer flip-flop cleared (0x19), `in ax,P`, then 0x09 read twice (x1, x2):
 *      x1 = 3C means the word read left the flip-flop alone, C3 that it toggled it once.
 *      The address is written back (was=) and checked; the channel stays masked.
 * 2. B<port>: plain byte reads (v, v2) of ports no capture has a value for: the -118 game
 *    port 0x1480-0x1487, 0x0534, the -86 spare ports 0xA462/A464/A46C/A46E, 0x043B (after the
 *    BIOS's own writes: the power-up byte is out of reach), 0x0EE0, and the MPU-PC98II status
 *    0xE0D2 (FF = no card; nothing is written to it).
 * 3. IRQ0: PIT ch0 in mode 3, period AU_PITCNT counts (1024 ARTIC ticks at CAL's 8.000).
 *    IRQ0WD_M / IRQ0WD_U: IF=0, IRQ0 masked / UNMASKED, the master IRR (OCW3 0Ah, then reads
 *    of 0x00 only) sampled for 100 ms: samples, ones, rises, falls. A request that is held
 *    once latched shows rises=1 falls=0; a request withdrawn when OUT0 falls shows one rise
 *    and one fall per period. IRQ0OUT: the OUT0 pin by read-back status (0x77 <- E2), the
 *    control that OUT0 toggles. IRQ0SLOW: a handler that EOIs (specific, 0x60) on entry and
 *    then keeps IF=0 for dly ARTIC ticks; the deliveries n in an art-tick window against
 *    art*8/AU_PITCNT periods. dly 0 and 0.6P deliver every period; at 1.6P and 1.8P a held
 *    request is taken at the handler's IRET (n = periods/1.6, /1.8), a request withdrawn at
 *    OUT0's fall half a period after the rise is lost (n = periods/2). The handler masks
 *    IRQ0 itself when the window ends (a held request delivered back to back would starve
 *    the main loop). n0f = master spurious IR7 (INT 0Fh) in the window.
 * 4. CAL: the calendar interval interrupt (IRQ15, INT 17h; undoc98 io_cal.txt I/O 0128h
 *    "読み出しによって割り込み要求を下げる"). CALBDA: the BIOS's 1/32 s counter at 0:04F1
 *    over 0.25 s as found (its INT 17h increments it; undoc98 memsys.txt 0000:04F1h). CAL128:
 *    the as-found 0x128 byte. CAL rows: per configuration (as found; 0x128 <- 81/80/83/82/
 *    00/01; TP = the BIOS's own power-on sequence, uPD4993A serial command 4 "TP = 64 Hz" on
 *    0x20 then 0x128 <- 81, Xe10 BANK4 0x0037-0x005C), the INT 17h deliveries in 0.5 s with
 *    a handler that reads 0x128 (mode=R) and one that does not (mode=N), both EOI the slave
 *    and the master (specific, 0x67). NP2kai raises IRQ15 on every tick whatever was read
 *    (io/upd4990.c upd4990_hrtimer_proc `pic_setirq(15);`).
 * 5. CASC: the master's IR7 (the slave's INT) when a slave request goes away. OPNA timer B
 *    (0x26 <- FF, 0x27 <- 2A) raises IRQ12 and is stopped with its flag kept (0x27 <- 08),
 *    IF=0 throughout. CASC_CTL: slave IMR <- EF, STI: the real INT 14h (n14 = 1; the
 *    handler resets the flags). CASC: slave IMR <- EF (m_on = master IRR), then FF (m_off
 *    at once, m_off2 after 100 us, s_irr1 = slave IRR), STI 10 ms: n17/n0f count INT 17h
 *    (the slave's spurious IR7, its ISR bits in isr_s/isr_m) and INT 0Fh. CASC_DEV: the
 *    same with IRQ12 left unmasked and the flags reset at the chip (0x27 <- 30) instead.
 *    Refused when the OPNA is absent or a sound driver holds INT 60h.
 *
 * Writes (restored at the exit, every one listed by a RESTORE line): IVT 08 0F 14 17 (self),
 * both IMRs (read-back), PIT ch0 (mode 0 with CAL's modulus, as /IRQ: default), 0x128 (the
 * as-found byte, read-back), the uPD4993A TP command (TP = 64 Hz, the power-on default),
 * OPNA 0x26 <- FF and 0x27 <- 30 (timers stopped, flags clear: default), both PICs' OCW3
 * left at IRR (default), the 8237 flip-flop cleared and channel 2 masked (default), its
 * address written back (read-back).
 */
    .equ AU_PITCNT, 0x2000              /* PIT ch0 mode-3 period of the IRQ0 rows */
    .equ AU_PER,    1024                /* that period in ARTIC ticks at 8.000 counts/tick */
    .equ AU_WIN,    153600              /* 0.5 s delivery window */
    .equ AU_SAMP,   30720               /* 100 ms IRR sampling */
    .equ AU_MAGIC,  0xA55AC33C
    .equ AU_PITKNOWN, 0x80F0            /* the PIT rows' count: distinct bytes (au_pitload) */
    .equ AU_DMAKNOWN, 0xC33C            /* the DMA rows' ch2 address: distinct bytes */

tc_audit:   .asciz "R: word/dword IN at the listed ports, bytes 1480-1487 534 A462 A464 A46C A46E 43B EE0 E0D2; W: 77/71 (ch0 mode 0 80F0, mode 3, then mode 0), 15 (DMA ch2 mask) 09 (ch2 address, written back) 19 (flip-flop clear), 128 (rates, restored), 20 (TP=64Hz, power-on), 188/18A 26 27, OCW3 00/08, IMRs, IVT 08 0F 14 17"
nm_audit:   .asciz "AUDIT"
kw_audit:   .asciz "AUDIT"
rs_au_irq0: .asciz "irq0_in_use"
to_au_opn:  .asciz "opna_timer_b_flag"
n_au_v08:   .asciz "VEC08"
n_au_v0f:   .asciz "VEC0F"
n_au_v14:   .asciz "VEC14"
n_au_v17:   .asciz "VEC17"
n_au_imrm:  .asciz "IMR_M"
n_au_imrs:  .asciz "IMR_S"
n_au_pit:   .asciz "PIT_CH0_MODE0"
n_au_128:   .asciz "P128_TICK"
n_au_tp:    .asciz "CAL_TP64"
n_au_opn:   .asciz "OPNA_27_TIMERS_OFF"
n_au_ocw3:  .asciz "OCW3_IRR"
n_au_dma:   .asciz "DMA_FF_CLEAR_CH2_MASKED"
n_au_dma2:  .asciz "DMA_CH2_ADDR"
tg_au_wd_m: .asciz "IRQ0WD_M"
tg_au_wd_u: .asciz "IRQ0WD_U"
tg_au_out:  .asciz "IRQ0OUT"
tg_au_slow: .asciz "IRQ0SLOW"
tg_au_bda:  .asciz "CALBDA"
tg_au_128:  .asciz "CAL128"
tg_au_cal:  .asciz "CAL"
tg_au_cctl: .asciz "CASC_CTL"
tg_au_casc: .asciz "CASC"
tg_au_cdev: .asciz "CASC_DEV"
tg_au_irq:  .asciz "IRQ"

/* word rows: port, flags (bit 0 = also in eax). 0xFFFF ends. */
au_wlist:
    .word 0x0015, 0                     /* word_term (DMA single mask) */
    .word 0x0021, 0                     /* word_term (DMA bank) */
    .word 0x00F2, 0                     /* word_term */
    .word 0x00F6, 0                     /* word_term */
    .word 0x00D0, 0                     /* active_term */
    .word 0x0030, 1                     /* plus_term (8251 data) */
    .word 0x0032, 0                     /* plus_term */
    .word 0x0040, 1                     /* plus_term (printer) */
    .word 0x0042, 0                     /* plus_term */
    .word 0x00AD, 0                     /* plus_term */
    .word 0x00AF, 0                     /* plus_term */
    .word 0x0060, 1                     /* minus_term (text GDC) */
    .word 0x0064, 0
    .word 0x0068, 0
    .word 0x006A, 0
    .word 0x006C, 0
    .word 0x007A, 0
    .word 0x007C, 0                     /* minus_term (GRCG) */
    .word 0x00A0, 0                     /* minus_term (graphics GDC) */
    .word 0x00A4, 1
    .word 0x00A6, 0
    .word 0x00A8, 0
    .word 0x00AC, 0
    .word 0x0020, 1                     /* ext08_term (calendar) */
    .word 0x0022, 0                     /* ext08_term */
    .word 0x0031, 0                     /* system 8255 */
    .word 0x0033, 0
    .word 0x0035, 0
    .word 0x0041, 0                     /* keyboard data / status */
    .word 0x0043, 0
    .word 0x0090, 0                     /* FDC status */
    .word 0x00F0, 1
    .word 0x0188, 1                     /* OPNA */
    .word 0x018A, 0
    .word 0x043B, 0
    .word 0x0642, 0                     /* IDE error */
    .word 0x7FD9, 0                     /* mouse 8255 port A */
    .word 0xA460, 0                     /* -86 ID (0xA461 never read on the machine) */
    .word 0x0640, 0                     /* IDE data, last: no DRQ */
    .word 0xFFFF

au_blist:
    .word 0x1480, 0x1481, 0x1482, 0x1483, 0x1484, 0x1485, 0x1486, 0x1487
    .word 0x0534, 0xA462, 0xA464, 0xA46C, 0xA46E, 0x043B, 0x0EE0, 0xE0D2
    .word 0xFFFF

/* the IRQ0SLOW handler delays, ARTIC ticks: 0, 0.6, 1.2, 1.6, 1.8 periods */
au_dlys:    .word 0, 614, 1229, 1638, 1843, 0xFFFF
/* CAL configurations: 0xFF = as found, 0xFE = TP (the power-on sequence), else the byte */
au_ctab:    .byte 0xFF, 0x81, 0x80, 0x83, 0x82, 0x00, 0x01, 0xFE, 0xFD
/* the BIOS's TP = 64 Hz sequence on 0x20 (Xe10 BANK4 0x004D table, three outs per word) */
au_tpseq:   .byte 0x07, 0x17, 0x07, 0x07, 0x17, 0x07, 0x27, 0x37, 0x27, 0x07, 0x17, 0x07
            .byte 0x07, 0x0F, 0x07

/* ---------------------------------------------------------------- helpers */
/* au_mktag: AL = prefix letter, DX = port -> [au_tag] = "<L><4 hex>" */
au_mktag:
    push    ax
    push    bx
    mov     bx, offset au_tag
    mov     byte ptr [bx], al
    mov     al, dh
    shr     al, 4
    call    nib_ch
    mov     byte ptr [bx+1], al
    mov     al, dh
    call    nib_ch
    mov     byte ptr [bx+2], al
    mov     al, dl
    shr     al, 4
    call    nib_ch
    mov     byte ptr [bx+3], al
    mov     al, dl
    call    nib_ch
    mov     byte ptr [bx+4], al
    mov     byte ptr [bx+5], 0
    pop     bx
    pop     ax
    ret

/* au_mark: the flushed ROW line for [au_tag], AX = port */
au_mark:
    push    si
    mov     si, offset au_tag
    call    row_mark
    pop     si
    ret

/* au_x: start `X AUDIT <SI tag>` */
au_x:
    push    si
    mov     si, offset k_X
    call    row_start
    pop     si
    jmp     out_s

/* au_opw: OPNA register AL <- AH at 0x188/0x18A, BUSY polled (bounded by a count: also used
 * inside the INT 14h handler, where the deadline library is not). Registers kept. */
au_opw:
    push    cx
    push    dx
    push    ax
    mov     dx, 0x188
    mov     cx, 0xFFFF
1:  in      al, dx
    test    al, 0x80
    loopnz  1b
    pop     ax
    out     dx, al
    push    ax
    mov     cx, 0xFFFF
2:  in      al, dx
    test    al, 0x80
    loopnz  2b
    pop     ax
    mov     dx, 0x18A
    xchg    al, ah
    out     dx, al
    xchg    al, ah
    pop     dx
    pop     cx
    ret

/* au_irr_m / au_irr_s: AL = the master / slave IRR (OCW3 0Ah first) */
au_irr_m:
    mov     al, 0x0A
    out     0x00, al
    in      al, 0x00
    ret
au_irr_s:
    mov     al, 0x0A
    out     0x08, al
    in      al, 0x08
    ret

/* au_wait: EAX = ARTIC ticks to spin (the watchdog runs) */
au_wait:
    call    dl_start
1:  call    dl_check
    jnc     1b
    ret

/* au_pitpair: CL, CH = two bytes in read order -> AX = the count (CAL's byte order) */
au_pitpair:
    mov     al, cl
    mov     ah, ch
    cmp     byte ptr [pit_swap], 0
    je      1f
    xchg    al, ah
1:  ret

/* ---------------------------------------------------------------- the ISRs */
/* INT 08h: EOI at once; an entry at or past the window's end ([au_wt0] + AU_WIN), or past
 * 4000 entries, masks IRQ0 and is not counted (a held request delivered back to back would
 * starve the main loop); otherwise count it and keep IF=0 for [au_dly] ARTIC ticks. */
au_i08:
    push    ax
    mov     al, 0x60
    out     0x00, al
    push    ds
    push    cs
    pop     ds
    push    eax
    push    cx
    mov     eax, dword ptr [au_wt0]
    call    artic_since
    cmp     eax, AU_WIN
    jae     3f
    cmp     word ptr [au_n08], 4000
    jae     3f
    inc     word ptr [au_n08]
    cmp     word ptr [au_dly], 0
    je      4f
    call    artic_read
    mov     dword ptr [au_it0], eax
    mov     cx, 20000
1:  mov     eax, dword ptr [au_it0]
    call    artic_since
    cmp     ax, word ptr [au_dly]
    jae     4f
    loop    1b
    jmp     4f
3:  in      al, 0x02
    or      al, 0x01
    out     0x02, al
4:  pop     cx
    pop     eax
    pop     ds
    pop     ax
    iret

/* INT 0Fh: the master's spurious IR7 (no ISR bit, no EOI) */
au_i0f:
    inc     word ptr cs:[au_n0f]
    iret

/* INT 14h (IRQ12): count, reset the OPNA flags, EOI slave IR4 and master IR7 */
au_i14:
    push    ax
    push    ds
    push    cs
    pop     ds
    inc     word ptr [au_n14]
    mov     ax, 0x3027
    call    au_opw
    mov     al, 0x64
    out     0x08, al
    mov     al, 0x67
    out     0x00, al
    pop     ds
    pop     ax
    iret

/* INT 17h (IRQ15, or the slave's spurious IR7): count; on the first entry snapshot both
 * ISRs; read 0x128 when [au_mode] bit 0; EOI slave and master IR7 (specific). Masks IRQ15
 * itself after 3000 entries (a level storm). */
au_i17:
    push    ax
    push    dx
    push    ds
    push    cs
    pop     ds
    inc     word ptr [au_n17]
    cmp     word ptr [au_n17], 1
    jne     1f
    mov     al, 0x0B
    out     0x08, al
    in      al, 0x08
    mov     byte ptr [au_isrs], al
    mov     al, 0x0A
    out     0x08, al
    mov     al, 0x0B
    out     0x00, al
    in      al, 0x00
    mov     byte ptr [au_isrm], al
    mov     al, 0x0A
    out     0x00, al
1:  test    byte ptr [au_mode], 1
    jz      2f
    mov     dx, 0x0128
    in      al, dx
2:  mov     al, 0x67
    out     0x08, al
    out     0x00, al
    cmp     word ptr [au_n17], 3000
    jb      3f
    in      al, 0x0A
    or      al, 0x80
    out     0x0A, al
3:  pop     ds
    pop     dx
    pop     ax
    iret

au_vecs:    .byte 0x08, 0x0F, 0x14, 0x17
au_isrs_t:  .word au_i08, au_i0f, au_i14, au_i17

/* au_hook: save and replace the four vectors; IRQ15 masked outside its windows */
au_hook:
    push    es
    xor     ax, ax
    mov     es, ax
    cli
    xor     bx, bx
1:  movzx   di, byte ptr [au_vecs + bx]
    shl     di, 2
    mov     eax, dword ptr es:[di]
    push    bx
    shl     bx, 2
    mov     dword ptr [au_vsave + bx], eax
    shr     bx, 1
    mov     ax, word ptr [au_isrs_t + bx]
    pop     bx
    mov     word ptr es:[di], ax
    mov     word ptr es:[di+2], cs
    inc     bx
    cmp     bx, 4
    jb      1b
    mov     byte ptr [au_hooked], 1
    in      al, 0x0A
    or      al, 0x80
    out     0x0A, al
    sti
    pop     es
    ret

/* ---------------------------------------------------------------- 1, 2: reads */
au_words:
    mov     si, offset au_wlist
au_words_l:                             /* SI = a port list (XE10U /AUDIT2) */
1:  mov     dx, word ptr [si]
    cmp     dx, 0xFFFF
    je      9f
    mov     al, 'W'
    call    au_mktag
    mov     ax, dx
    call    au_mark
    mov     cl, byte ptr [si+2]
    cli
    in      al, dx
    mov     byte ptr [au_b0], al
    inc     dx
    in      al, dx
    mov     byte ptr [au_b1], al
    dec     dx
    mov     eax, AU_MAGIC
    in      ax, dx
    mov     word ptr [au_w1], ax
    mov     eax, AU_MAGIC
    in      ax, dx
    mov     word ptr [au_w2], ax
    test    cl, 1
    jz      2f
    mov     eax, AU_MAGIC
    in      eax, dx
    mov     dword ptr [au_d], eax
2:  in      al, dx
    mov     byte ptr [au_b2], al
    sti
    push    si
    mov     si, offset au_tag
    call    au_x
    PS      " b0="
    mov     al, byte ptr [au_b0]
    call    out_x2
    PS      " b1="
    mov     al, byte ptr [au_b1]
    call    out_x2
    PS      " w1="
    mov     ax, word ptr [au_w1]
    call    out_x4
    PS      " w2="
    mov     ax, word ptr [au_w2]
    call    out_x4
    PS      " d="
    test    cl, 1
    jnz     3f
    PS      "-"
    jmp     4f
3:  mov     eax, dword ptr [au_d]
    call    out_x8
4:  PS      " b2="
    mov     al, byte ptr [au_b2]
    call    out_x2
    call    out_nl
    pop     si
    add     si, 4
    jmp     1b
9:  ret

/* au_pitw: DX = 0x70 or 0x71 (the PIT row, see the header) */
au_pitw:
    mov     al, 'P'
    call    au_mktag
    test    byte ptr [imr_m_save], 1    /* ch0 is reprogrammed: not under a timer user */
    jnz     1f
    mov     si, offset rs_au_irq0
    jmp     skip_line
1:  mov     ax, dx
    call    au_mark
    cli
    mov     byte ptr [au_pit], 1
    call    au_pitload                  /* ch0 <- mode 0, AU_PITKNOWN; flip-flop reset */
    xor     al, al
    out     0x77, al
    in      al, 0x71
    mov     byte ptr [au_a0], al
    in      al, 0x71
    mov     byte ptr [au_a1], al
    xor     al, al
    out     0x77, al
    mov     eax, AU_MAGIC
    in      ax, dx
    mov     word ptr [au_w1], ax
    in      al, 0x71
    mov     byte ptr [au_b0], al
    in      al, 0x71
    mov     byte ptr [au_b1], al
    call    au_pitload                  /* the control word puts the flip-flop back */
    xor     al, al
    out     0x77, al
    in      al, 0x71
    mov     cl, al
    in      al, 0x71
    mov     ch, al
    call    au_pitpair
    mov     word ptr [au_v1], ax
    mov     byte ptr [au_sync], 0
    sti
    mov     si, offset au_tag
    call    au_x
    PS      " a0="
    mov     al, byte ptr [au_a0]
    call    out_x2
    PS      " a1="
    mov     al, byte ptr [au_a1]
    call    out_x2
    PS      " w="
    mov     ax, word ptr [au_w1]
    call    out_x4
    PS      " x1="
    mov     al, byte ptr [au_b0]
    call    out_x2
    PS      " x2="
    mov     al, byte ptr [au_b1]
    call    out_x2
    call    au_pitsync_out
    call    out_nl
    ret

au_pitsync_out:
    PS      " v1="
    mov     ax, word ptr [au_v1]
    call    out_x4
    PS      " sync="
    movzx   eax, byte ptr [au_sync]
    call    out_d
    ret

/* au_pitload: PIT ch0 <- mode 0, LSB then MSB, count AU_PITKNOWN (0x80F0: for the ~50
 * counts the row takes the count reads 80xx with xx >= 0xA0, so its two bytes differ and the
 * byte the next 0x71 read returns names the flip-flop's state). A control word resets the
 * LSB/MSB read sequence (8254 data sheet: writing the control word resets the read/write
 * logic). Interrupts are the caller's (off); IRQ0 is masked as found (checked). */
au_pitload:
    push    ax
    mov     al, 0x30
    out     0x77, al
    mov     ax, AU_PITKNOWN
    out     0x71, al
    xchg    al, ah
    out     0x71, al
    pop     ax
    ret

/* au_dmaff: DX = 0x01 or 0x00 (the DMA flip-flop row). Channel 2 (the FDC's, idle at a DOS
 * prompt; DMAROUTE-XE10.TXT leaves it the same way) is masked (0x15 <- 06), its current
 * address read (r0 r1) and loaded with AU_DMAKNOWN, so its two bytes differ; then the flip-
 * flop is cleared (0x19), `in ax,P`, and 0x09 read twice (x1 x2): x1 = 3C (the LSB) = the
 * word read left the flip-flop alone, x1 = C3 = it toggled it once. The address is written
 * back (base and current both take it) and the channel is left masked, as the BIOS leaves it
 * between transfers. q = 09 names the register. */
au_dmaff:
    mov     al, 'D'
    call    au_mktag
    mov     ax, dx
    call    au_mark
    mov     byte ptr [au_dma], 1
    cli
    mov     al, 0x06                    /* single mask: set, channel 2 */
    out     0x15, al
    out     0x19, al
    in      al, 0x09
    mov     byte ptr [au_a0], al
    in      al, 0x09
    mov     byte ptr [au_a1], al
    mov     al, byte ptr [au_a0]
    mov     ah, byte ptr [au_a1]
    mov     word ptr [au_dsave], ax
    out     0x19, al
    mov     ax, AU_DMAKNOWN
    out     0x09, al
    xchg    al, ah
    out     0x09, al
    out     0x19, al
    mov     eax, AU_MAGIC
    in      ax, dx
    mov     word ptr [au_w1], ax
    in      al, 0x09
    mov     byte ptr [au_b0], al
    in      al, 0x09
    mov     byte ptr [au_b1], al
    out     0x19, al
    mov     al, byte ptr [au_a0]
    out     0x09, al
    mov     al, byte ptr [au_a1]
    out     0x09, al
    out     0x19, al
    sti
    mov     si, offset au_tag
    call    au_x
    PS      " q=09 r0=3C r1=C3 w="
    mov     ax, word ptr [au_w1]
    call    out_x4
    PS      " x1="
    mov     al, byte ptr [au_b0]
    call    out_x2
    PS      " x2="
    mov     al, byte ptr [au_b1]
    call    out_x2
    PS      " was="
    mov     al, byte ptr [au_a1]
    call    out_x2
    mov     al, byte ptr [au_a0]
    call    out_x2
    call    out_nl
    ret

au_bytes:
    mov     si, offset au_blist
1:  mov     dx, word ptr [si]
    cmp     dx, 0xFFFF
    je      9f
    mov     al, 'B'
    call    au_mktag
    mov     ax, dx
    call    au_mark
    in      al, dx
    mov     cl, al
    in      al, dx
    mov     ch, al
    push    si
    mov     si, offset au_tag
    call    au_x
    PS      " v="
    mov     al, cl
    call    out_x2
    PS      " v2="
    mov     al, ch
    call    out_x2
    call    out_nl
    pop     si
    add     si, 2
    jmp     1b
9:  ret

/* ---------------------------------------------------------------- 3: IRQ0 */
au_irq0:
    test    byte ptr [imr_m_save], 1
    jnz     1f
    mov     si, offset rs_au_irq0
    jmp     skip_line
1:  mov     si, offset tg_au_irq
    mov     ax, 0x0071
    call    row_mark
    cli
    mov     byte ptr [au_pit], 1
    mov     al, 0x36                    /* ch0, LSB then MSB, mode 3, binary */
    out     0x77, al
    mov     ax, AU_PITCNT
    out     0x71, al
    xchg    al, ah
    out     0x71, al
    sti
    mov     eax, T_10MS
    call    au_wait
    mov     si, offset tg_au_wd_m
    xor     bl, bl
    call    au_irrsamp
    mov     si, offset tg_au_wd_u
    mov     bl, 1
    call    au_irrsamp
    call    au_outsamp
    mov     si, offset au_dlys
2:  mov     ax, word ptr [si]
    cmp     ax, 0xFFFF
    je      3f
    push    si
    call    au_slow1
    pop     si
    add     si, 2
    jmp     2b
3:  ret

au_zero4:
    mov     dword ptr [au_cs], 0
    mov     dword ptr [au_c1], 0
    mov     dword ptr [au_cr], 0
    mov     dword ptr [au_cf], 0
    ret

/* au_irrsamp: SI = tag, BL = 1 to unmask IRQ0 (IF stays 0): the master IRR bit 0 for 100 ms */
au_irrsamp:
    call    au_zero4
    cli
    in      al, 0x02
    or      al, 0x01
    test    bl, bl
    jz      1f
    and     al, 0xFE
1:  out     0x02, al
    mov     al, 0x0A
    out     0x00, al
    in      al, 0x00
    and     al, 0x01
    mov     bh, al
    mov     byte ptr [au_b0], al
    mov     eax, AU_SAMP
    call    dl_start
2:  mov     cx, 256
3:  in      al, 0x00
    and     al, 0x01
    jz      4f
    inc     dword ptr [au_c1]
    cmp     bh, 0
    jne     5f
    inc     dword ptr [au_cr]
    jmp     5f
4:  cmp     bh, 0
    je      5f
    inc     dword ptr [au_cf]
5:  mov     bh, al
    loop    3b
    add     dword ptr [au_cs], 256
    call    dl_check
    jnc     2b
    in      al, 0x02
    or      al, 0x01
    out     0x02, al
    sti
    jmp     au_print4

/* au_print4: `X AUDIT <SI> first=<au_b0> samples= ones= rises= falls=` */
au_print4:
    call    au_x
    PS      " first="
    movzx   eax, byte ptr [au_b0]
    call    out_d
    PS      " samples="
    mov     eax, dword ptr [au_cs]
    call    out_d
    PS      " ones="
    mov     eax, dword ptr [au_c1]
    call    out_d
    PS      " rises="
    mov     eax, dword ptr [au_cr]
    call    out_d
    PS      " falls="
    mov     eax, dword ptr [au_cf]
    call    out_d
    PS      " cnt="
    mov     eax, AU_PITCNT
    call    out_d
    jmp     out_nl

/* au_outsamp: the OUT0 pin (read-back status 0x77 <- E2, bit 7) for 100 ms, IRQ0 masked;
 * ch0 is reloaded in mode 3 after, which resets the 0x71 read sequence */
au_outsamp:
    call    au_zero4
    cli
    mov     al, 0xE2
    out     0x77, al
    in      al, 0x71
    mov     byte ptr [au_b2], al
    shr     al, 7
    mov     bh, al
    mov     byte ptr [au_b0], al
    mov     eax, AU_SAMP
    call    dl_start
2:  mov     cx, 256
3:  mov     al, 0xE2
    out     0x77, al
    in      al, 0x71
    shr     al, 7
    jz      4f
    inc     dword ptr [au_c1]
    cmp     bh, 0
    jne     5f
    inc     dword ptr [au_cr]
    jmp     5f
4:  cmp     bh, 0
    je      5f
    inc     dword ptr [au_cf]
5:  mov     bh, al
    loop    3b
    add     dword ptr [au_cs], 256
    call    dl_check
    jnc     2b
    mov     al, 0x36                    /* mode 3 again: the control word also resets the */
    out     0x77, al                    /* read sequence, whatever an 8253 made of E2 */
    mov     ax, AU_PITCNT
    out     0x71, al
    xchg    al, ah
    out     0x71, al
    sti
    mov     si, offset tg_au_out
    call    au_x
    PS      " status="
    mov     al, byte ptr [au_b2]
    call    out_x2
    PS      " samples="
    mov     eax, dword ptr [au_cs]
    call    out_d
    PS      " ones="
    mov     eax, dword ptr [au_c1]
    call    out_d
    PS      " rises="
    mov     eax, dword ptr [au_cr]
    call    out_d
    PS      " falls="
    mov     eax, dword ptr [au_cf]
    call    out_d
    jmp     out_nl

/* au_slow1: AX = the handler's IF=0 time (ARTIC ticks): deliveries in one AU_WIN window */
au_slow1:
    mov     word ptr [au_dly], ax
    call    au_cnt0
    cli
    call    artic_read
    mov     dword ptr [au_wt0], eax
    mov     eax, AU_WIN + T_100MS
    call    dl_start
    in      al, 0x02
    and     al, 0xFE
    out     0x02, al
    sti
1:  call    dl_check
    jnc     1b
    cli
    in      al, 0x02
    or      al, 0x01
    out     0x02, al
    sti
    mov     si, offset tg_au_slow
    call    au_x
    PS      " dly="
    movzx   eax, word ptr [au_dly]
    call    out_d
    PS      " n="
    movzx   eax, word ptr [au_n08]
    call    out_d
    PS      " n0f="
    movzx   eax, word ptr [au_n0f]
    call    out_d
    PS      " win="
    mov     eax, AU_WIN
    call    out_d
    PS      " cnt="
    mov     eax, AU_PITCNT
    call    out_d
    jmp     out_nl

au_cnt0:
    mov     word ptr [au_n08], 0
    mov     word ptr [au_n0f], 0
    mov     word ptr [au_n14], 0
    mov     word ptr [au_n17], 0
    mov     byte ptr [au_isrs], 0
    mov     byte ptr [au_isrm], 0
    ret

/* ---------------------------------------------------------------- 4: the calendar tick */
/* au_calbda: the BIOS's 1/32 s counter over 0.25 s, before INT 17h is hooked */
au_calbda:
    push    es
    xor     ax, ax
    mov     es, ax
    mov     eax, dword ptr es:[0x04F1]
    and     eax, 0x00FFFFFF
    mov     dword ptr [au_bda0], eax
    mov     eax, 76800
    call    au_wait
    mov     eax, dword ptr es:[0x04F1]
    pop     es
    sub     eax, dword ptr [au_bda0]
    and     eax, 0x00FFFFFF
    mov     si, offset tg_au_bda
    call    au_x
    PS      " d="
    call    out_d
    PS      " art=76800 imr_s="
    in      al, 0x0A
    call    out_x2
    PS      " imr_m="
    in      al, 0x02
    call    out_x2
    jmp     out_nl

au_cal:
    mov     si, offset tg_au_cal
    mov     ax, 0x0128
    call    row_mark
    mov     dx, 0x0128
    in      al, dx
    mov     byte ptr [au_v128], al
    mov     byte ptr [au_calw], 1
    mov     si, offset tg_au_128
    call    au_x
    PS      " v="
    mov     al, byte ptr [au_v128]
    call    out_x2
    call    out_nl
    mov     si, offset au_ctab
1:  mov     al, byte ptr [si]
    cmp     al, 0xFD
    je      9f
    push    si
    mov     byte ptr [au_cfg], al
    cmp     al, 0xFF
    je      3f
    cmp     al, 0xFE
    jne     2f
    call    au_tp64
    mov     al, 0x81
2:  mov     dx, 0x0128
    out     dx, al
3:  mov     byte ptr [au_mode], 1
    call    au_calwin
    mov     byte ptr [au_mode], 0
    call    au_calwin
    pop     si
    inc     si
    jmp     1b
9:  ret

/* au_tp64: the BIOS's power-on TP = 64 Hz command, byte for byte (two 0x5F waits each) */
au_tp64:
    push    bx
    push    cx
    mov     byte ptr [au_tpw], 1
    mov     bx, offset au_tpseq
    mov     cx, 15
1:  mov     al, byte ptr [bx]
    out     0x20, al
    out     0x5F, al
    out     0x5F, al
    inc     bx
    loop    1b
    pop     cx
    pop     bx
    ret

/* au_calwin: one 0.5 s window with IRQ15 open, [au_mode] = the handler's 0x128 read */
au_calwin:
    call    au_cnt0
    cli
    mov     dx, 0x0128
    in      al, dx                      /* a pending tick is dropped first */
    in      al, 0x02
    and     al, 0x7F
    out     0x02, al
    in      al, 0x0A
    and     al, 0x7F
    out     0x0A, al
    mov     eax, AU_WIN
    call    dl_start
    sti
1:  call    dl_check
    jnc     1b
    cli
    in      al, 0x0A
    or      al, 0x80
    out     0x0A, al
    mov     dx, 0x0128
    in      al, dx
    mov     byte ptr [au_b0], al
    sti
    mov     si, offset tg_au_cal
    call    au_x
    PS      " cfg="
    mov     al, byte ptr [au_cfg]
    cmp     al, 0xFF
    jne     2f
    PS      "AF"
    jmp     4f
2:  cmp     al, 0xFE
    jne     3f
    PS      "TP"
    jmp     4f
3:  call    out_x2
4:  PS      " mode="
    mov     al, 'N'
    test    byte ptr [au_mode], 1
    jz      5f
    mov     al, 'R'
5:  call    out_c
    PS      " n="
    movzx   eax, word ptr [au_n17]
    call    out_d
    PS      " win="
    mov     eax, AU_WIN
    call    out_d
    PS      " v="
    mov     al, byte ptr [au_b0]
    call    out_x2
    PS      " isr_s="
    mov     al, byte ptr [au_isrs]
    call    out_x2
    jmp     out_nl

/* ---------------------------------------------------------------- 5: the cascade */
/* au_flagb: OPNA timer B flag up (1 count = 288 us), the timer then stopped with the flag
 * and its enable kept. CF = 1 when the flag never came (10 ms). */
au_flagb:
    mov     ax, 0x3027
    call    au_opw
    mov     ax, 0xFF26
    call    au_opw
    mov     ax, 0x2A27
    call    au_opw
    mov     eax, T_10MS
    call    dl_start
1:  mov     dx, 0x0188
    in      al, dx
    test    al, 0x02
    jnz     2f
    call    dl_check
    jnc     1b
    stc
    ret
2:  mov     ax, 0x0827
    call    au_opw
    clc
    ret

au_wait100us:
    push    eax
    mov     eax, 31
    call    dl_start
1:  call    dl_check
    jnc     1b
    pop     eax
    ret

/* au_cascrow: SI = tag: the X row of a cascade trial */
au_cascrow:
    call    au_x
    PS      " s_irr="
    mov     al, byte ptr [au_a0]
    call    out_x2
    PS      " m_on="
    mov     al, byte ptr [au_a1]
    call    out_x2
    PS      " m_off="
    mov     al, byte ptr [au_b0]
    call    out_x2
    PS      " m_off2="
    mov     al, byte ptr [au_b1]
    call    out_x2
    PS      " s_irr1="
    mov     al, byte ptr [au_b2]
    call    out_x2
    PS      " n14="
    movzx   eax, word ptr [au_n14]
    call    out_d
    PS      " n17="
    movzx   eax, word ptr [au_n17]
    call    out_d
    PS      " n0f="
    movzx   eax, word ptr [au_n0f]
    call    out_d
    PS      " isr_s="
    mov     al, byte ptr [au_isrs]
    call    out_x2
    PS      " isr_m="
    mov     al, byte ptr [au_isrm]
    call    out_x2
    jmp     out_nl

au_casc:
    mov     dx, 0x0188
    in      al, dx
    cmp     al, 0xFF
    jne     1f
    mov     si, offset rs_absent
    jmp     skip_line
1:  call    opna_drvchk
    jnc     2f
    mov     si, offset rs_tsr
    jmp     skip_line
2:  mov     si, offset tg_au_casc
    mov     ax, 0x0188
    call    row_mark
    mov     byte ptr [au_opn], 1
    mov     byte ptr [au_mode], 0
    cli                                 /* every slave line shut while the flag is raised */
    mov     al, 0xFF
    out     0x0A, al
    sti
    /* CASC_CTL: the request delivered through the cascade */
    call    au_flagb
    jc      8f
    cli
    call    au_irr_s
    mov     byte ptr [au_a0], al
    mov     al, 0xEF
    out     0x0A, al
    call    au_irr_m
    mov     byte ptr [au_a1], al
    mov     byte ptr [au_b0], 0
    mov     byte ptr [au_b1], 0
    mov     byte ptr [au_b2], 0
    call    au_cnt0
    sti
    mov     eax, T_10MS
    call    au_wait
    cli
    mov     al, 0xFF
    out     0x0A, al
    sti
    mov     si, offset tg_au_cctl
    call    au_cascrow
    /* CASC: the slave request masked away with IF=0, then STI */
    call    au_flagb
    jc      8f
    cli
    call    au_irr_s
    mov     byte ptr [au_a0], al
    mov     al, 0xEF
    out     0x0A, al
    call    au_irr_m
    mov     byte ptr [au_a1], al
    mov     al, 0xFF
    out     0x0A, al
    call    au_irr_m
    mov     byte ptr [au_b0], al
    call    au_wait100us
    call    au_irr_m
    mov     byte ptr [au_b1], al
    call    au_irr_s
    mov     byte ptr [au_b2], al
    call    au_cnt0
    sti
    mov     eax, T_10MS
    call    au_wait
    cli
    mov     ax, 0x3027
    call    au_opw
    sti
    mov     si, offset tg_au_casc
    call    au_cascrow
    /* CASC_DEV: IRQ12 left open, the flags reset at the chip with IF=0, then STI */
    call    au_flagb
    jc      8f
    cli
    call    au_irr_s
    mov     byte ptr [au_a0], al
    mov     al, 0xEF
    out     0x0A, al
    call    au_irr_m
    mov     byte ptr [au_a1], al
    mov     ax, 0x3027
    call    au_opw
    call    au_irr_m
    mov     byte ptr [au_b0], al
    call    au_wait100us
    call    au_irr_m
    mov     byte ptr [au_b1], al
    call    au_irr_s
    mov     byte ptr [au_b2], al
    call    au_cnt0
    sti
    mov     eax, T_10MS
    call    au_wait
    cli
    mov     al, 0xFF
    out     0x0A, al
    sti
    mov     si, offset tg_au_cdev
    jmp     au_cascrow
8:  mov     si, offset to_au_opn
    call    timeout_line
    cli
    mov     al, 0xFF
    out     0x0A, al
    sti
    ret

/* ---------------------------------------------------------------- the section */
sec_audit:
    mov     si, offset nm_audit
    mov     eax, WD_60S
    mov     bx, offset au_exit
    call    sec_begin
    xor     al, al
    mov     byte ptr [au_hooked], al
    mov     byte ptr [au_pit], al
    mov     byte ptr [au_calw], al
    mov     byte ptr [au_tpw], al
    mov     byte ptr [au_opn], al
    mov     byte ptr [au_dma], al
    mov     word ptr [tag_sfx], 0
    mov     si, offset k_STATE
    call    info_start
    PS      "imr_m="
    in      al, 0x02
    call    out_x2
    PS      " imr_s="
    in      al, 0x0A
    call    out_x2
    PS      " pit_order="
    movzx   eax, byte ptr [pit_swap]
    call    out_d
    PS      " magic=A55AC33C"
    call    out_nl
    call    au_bytes
    call    au_words
    mov     dx, 0x0070
    call    au_pitw
    mov     dx, 0x0071
    call    au_pitw
    mov     dx, 0x0001
    call    au_dmaff
    mov     dx, 0x0000
    call    au_dmaff
    call    au_calbda
    call    au_hook
    call    au_irq0
    call    au_cal
    call    au_casc
au_exit:
    call    sec_disarm
    cli
    in      al, 0x02
    or      al, 0x01
    out     0x02, al
    cmp     byte ptr [au_pit], 0
    je      1f
    mov     eax, dword ptr [pit_mod]
    call    pit0_mode0                  /* 65536 -> count 0, as /IRQ leaves it */
1:  cmp     byte ptr [au_opn], 0
    je      2f
    mov     ax, 0x3027
    call    au_opw
2:  cmp     byte ptr [au_calw], 0
    je      3f
    mov     dx, 0x0128
    mov     al, byte ptr [au_v128]
    out     dx, al
3:  cmp     byte ptr [au_dma], 0
    je      4f
    out     0x19, al
4:  mov     al, 0x0A
    out     0x00, al
    out     0x08, al
    cmp     byte ptr [au_hooked], 0
    je      6f
    push    es
    xor     ax, ax
    mov     es, ax
    xor     bx, bx
5:  movzx   di, byte ptr [au_vecs + bx]
    shl     di, 2
    push    bx
    shl     bx, 2
    mov     eax, dword ptr [au_vsave + bx]
    pop     bx
    mov     dword ptr es:[di], eax
    inc     bx
    cmp     bx, 4
    jb      5b
    pop     es
6:  mov     al, byte ptr [imr_m_save]
    out     0x02, al
    mov     al, byte ptr [imr_s_save]
    out     0x0A, al
    sti
    cmp     byte ptr [au_hooked], 0
    je      8f
    push    es
    xor     ax, ax
    mov     es, ax
    xor     bx, bx
7:  movzx   di, byte ptr [au_vecs + bx]
    shl     di, 2
    mov     edx, dword ptr es:[di]
    push    bx
    shl     bx, 1
    mov     si, word ptr [au_vnames + bx]
    shl     bx, 1
    mov     eax, dword ptr [au_vsave + bx]
    mov     cx, 0x0208
    mov     bl, 3
    call    rs_line
    pop     bx
    inc     bx
    cmp     bx, 4
    jb      7b
    pop     es
8:  mov     dx, 0x02
    mov     al, byte ptr [imr_m_save]
    mov     si, offset n_au_imrm
    call    rs_port8
    mov     dx, 0x0A
    mov     al, byte ptr [imr_s_save]
    mov     si, offset n_au_imrs
    call    rs_port8
    cmp     byte ptr [au_pit], 0
    je      9f
    mov     si, offset n_au_pit
    mov     eax, dword ptr [pit_mod]
    call    rs_default
9:  cmp     byte ptr [au_calw], 0
    je      10f
    mov     dx, 0x0128
    mov     al, byte ptr [au_v128]
    mov     si, offset n_au_128
    call    rs_port8
10: cmp     byte ptr [au_tpw], 0
    je      11f
    mov     si, offset n_au_tp
    mov     eax, 4
    call    rs_default
11: cmp     byte ptr [au_opn], 0
    je      12f
    mov     si, offset n_au_opn
    mov     eax, 0x30
    call    rs_default
12: mov     si, offset n_au_ocw3
    mov     eax, 0x0A
    call    rs_default
    cmp     byte ptr [au_dma], 0
    je      13f
    mov     si, offset n_au_dma
    mov     eax, 6
    call    rs_default
    cli
    out     0x19, al
    in      al, 0x09
    mov     dl, al
    in      al, 0x09
    mov     dh, al
    out     0x19, al
    sti
    movzx   edx, dx
    movzx   eax, word ptr [au_dsave]
    mov     si, offset n_au_dma2
    mov     cx, 0x0004
    mov     bl, 3
    call    rs_line
13: call    sec_end
    ret

au_vnames:  .word n_au_v08, n_au_v0f, n_au_v14, n_au_v17

    VARS
    .p2align 2
au_d:       .long 0
au_it0:     .long 0
au_wt0:     .long 0
au_cs:      .long 0
au_c1:      .long 0
au_cr:      .long 0
au_cf:      .long 0
au_bda0:    .long 0
au_vsave:   .space 16
au_w1:      .word 0
au_dsave:   .word 0
au_w2:      .word 0
au_v1:      .word 0
au_dly:     .word 0
au_n08:     .word 0
au_n0f:     .word 0
au_n14:     .word 0
au_n17:     .word 0
au_tag:     .space 8
au_b0:      .byte 0
au_b1:      .byte 0
au_b2:      .byte 0
au_a0:      .byte 0
au_a1:      .byte 0
au_q:       .byte 0
au_sync:    .byte 0
au_mode:    .byte 0
au_isrs:    .byte 0
au_isrm:    .byte 0
au_v128:    .byte 0
au_cfg:     .byte 0
au_hooked:  .byte 0
au_pit:     .byte 0
au_calw:    .byte 0
au_tpw:     .byte 0
au_opn:     .byte 0
au_dma:     .byte 0
    ENDVARS

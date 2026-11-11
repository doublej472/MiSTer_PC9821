/* sec_audit2.inc - /AUDIT2 (opt-in, XE10U.COM only): what XE10T /AUDIT left open (todo items
 * 114 and 42). Raw values; xe10t_decode.py classifies them. Every row behind a flushed ROW
 * line. Uses /AUDIT's helpers (sec_audit.inc: au_x, au_mktag, au_mark, au_words_l, the
 * au_* counters), so XE10U carries both sections.
 *
 * 1. CALIRR (item 114): the calendar's interval request line, IRQ15, as the slave PIC's IRR
 *    bit 7 sees it with IR7 MASKED (slave IMR bit 7 set) and IF=0, sampled for 100 ms
 *    (AU_SAMP), as /AUDIT's IRQ0WD rows sample IRQ0. For 0x128 as found (cfg=FF) and
 *    0x128 <- 81 (32 Hz), 80 (64 Hz), 83 (16 Hz) (the rates /AUDIT's CAL rows measured on the
 *    Xe10, docs/probes/XE10T-XE10-AUDIT.TXT `cfg=81 mode=N n=16`, `cfg=80 ... n=32`,
 *    `cfg=83 ... n=8` in 0.5 s), in two modes: N (nothing read) and R (0x128 read once at
 *    every rise, undoc98 io_cal.txt I/O 0128h "読み出しによって割り込み要求を下げる"). Printed:
 *    first (bit 7 at the start), samples, ones, rises, falls, the first 12 edges as ARTIC
 *    ticks from the start (+ rise, - fall) and r128 (the first 0x128 read at a rise). A line
 *    that stays up until read shows duty near 1 in N and short highs in R; a line that falls
 *    by itself shows the same highs in both. 0x128 is read once before each window (a
 *    pending tick dropped) and restored at the exit.
 * 2. Word OUT (item 42 (a)); each under cli, everything written put back at once:
 *    WO0009 (NP2kai word_term: the write is dropped): DMA channel 2 masked (0x15 <- 06), its
 *      address loaded with C33C, the flip-flop cleared, the slave IMR (0x0A) read (i0), then
 *      `out 09h,ax` with AX = FF5A; the slave IMR read (i1: FF = the high byte reached 0x0A),
 *      the flip-flop cleared, 0x09 read twice (x1 x2: 5A C3 = the low byte landed alone at 09,
 *      3C C3 = nothing at 09, 5A FF = both bytes at 09). Address and IMR written back.
 *    WO000A (no NP2kai term: both bytes, 0x0A then 0x0B): channel 2's count loaded with C33C,
 *      `out 0Ah,ax` with AX = 5AFF; i1 = the slave IMR (FF = the low byte landed), x1 x2 =
 *      0x0B read twice (5A C3 = the high byte reached 0x0B). Count and IMR written back.
 *    WO006C (NP2kai minus_term: the low byte only): 0x6C and 0x6D read (b0 b1), `out 6Ch,ax`
 *      with AL = 70 and AH = the 0x6D byte just read, 0x6C/0x6D read again (a0 a1); 0x6C <-
 *      b0. On the Xe10 0x6C latches bits 7-4 (docs/probes/KIT1-XE10-CFGWR.TXT `w70->70`).
 * 3. Word IN shapes (item 42 (b), (d)): /AUDIT's W rows (b0 b1 w1 w2 d b2) for the ports its
 *    capture did not take: 0x24 0x26 0x34 0x36 0x44 0x46 0x72 0x74 0x76 0xA2 0x75 0x79 0xAF,
 *    and above 0x3FF (NP2kai terminates only `!(port & 0x0c00)`): 0x0C24 and 0x0422.
 * 4. T<port> (item 42 (c)): does a word IN fetch P + 1? 1024 `in al,dx` (b) against 1024
 *    `in ax,dx` (w), PIT counts, best of 3, under cli. A word read that takes two bus cycles
 *    costs one more bus cycle than b. Ports 0x7C, 0x20, 0x22 (the question), 0x0A (no term:
 *    split, the two-cycle control) and 0x60 (minus_term, measured one byte: the one-cycle
 *    control); the decoder places each port's w - b nearer one control or the other.
 *
 * Writes (all restored, listed by RESTORE lines): 0x128 (read-back), slave IMR (read-back),
 * DMA channel 2 address and count (read-back; the channel left masked, the flip-flop clear,
 * as /AUDIT leaves it), 0x6C (its as-read byte).
 */
tc_audit2:  .asciz "W: 128 (81/80/83, restored), 0A (IMR_S), 15 (ch2 mask) 19 (flip-flop) 09/0B (ch2 address/count, written back), word OUT 09/0A/6C; R: word IN 24 26 34 36 44 46 72 74 75 76 79 A2 AF 0C24 0422, timing 7C 20 22 0A 60"
nm_audit2:  .asciz "AUDIT2"
kw_audit2:  .asciz "AUDIT2"
tg_a2_cal:  .asciz "CALIRR"
tg_a2_w09:  .asciz "WO0009"
tg_a2_w0a:  .asciz "WO000A"
tg_a2_w6c:  .asciz "WO006C"
n_a2_dmaa:  .asciz "DMA_CH2_ADDR"
n_a2_dmac:  .asciz "DMA_CH2_COUNT"
n_a2_6c:    .asciz "P6C"
a2_ctab:    .byte 0xFF, 0x81, 0x80, 0x83, 0xFD
a2_wlist:
    .word 0x0024, 0, 0x0026, 0, 0x0034, 0, 0x0036, 0, 0x0044, 0, 0x0046, 0
    .word 0x0072, 0, 0x0074, 0, 0x0076, 0, 0x00A2, 0, 0x0075, 0, 0x0079, 0
    .word 0x00AF, 0, 0x0C24, 0, 0x0422, 0
    .word 0xFFFF
a2_tlist:   .word 0x007C, 0x0020, 0x0022, 0x000A, 0x0060, 0xFFFF

/* ---------------------------------------------------------------- 1. CALIRR */
/* a2_edge: record an edge, AH = 0x80 rise / 0 fall. Clobbers AX, BX, DX. */
a2_edge:
    movzx   bx, byte ptr [a2_ne]
    cmp     bx, 12
    jae     1f
    push    ax
    push    bx
    call    artic_lo
    mov     ax, bx
    pop     bx
    sub     ax, word ptr [a2_t0]
    and     ax, 0x7FFF
    pop     dx
    test    dh, 0x80
    jz      2f
    or      ax, 0x8000
2:  shl     bx, 1
    mov     word ptr [a2_edges + bx], ax
    inc     byte ptr [a2_ne]
1:  ret

/* a2_calirr: AL = cfg (FF as found), [a2_rmode] = 1 to read 0x128 at each rise */
a2_calirr:
    mov     byte ptr [a2_cfg], al
    mov     si, offset tg_a2_cal
    mov     ax, 0x0128
    call    row_mark
    call    au_zero4
    mov     byte ptr [a2_ne], 0
    mov     byte ptr [a2_r128], 0xEE
    mov     byte ptr [a2_calw], 1
    cli
    in      al, 0x0A
    or      al, 0x80                    /* IR7 (IRQ15) masked: the line is only sampled */
    out     0x0A, al
    mov     dx, 0x0128
    mov     al, byte ptr [a2_cfg]
    cmp     al, 0xFF
    je      1f
    out     dx, al
1:  in      al, dx                      /* a pending tick dropped */
    mov     al, 0x0A
    out     0x08, al
    call    artic_lo
    mov     word ptr [a2_t0], bx
    in      al, 0x08
    and     al, 0x80
    mov     byte ptr [au_b0], al
    movzx   bp, al
    mov     eax, AU_SAMP
    call    dl_start
2:  mov     cx, 256
3:  in      al, 0x08
    and     al, 0x80
    jz      4f
    inc     dword ptr [au_c1]
    test    bp, bp
    jnz     5f
    /* a rise */
    inc     dword ptr [au_cr]
    mov     bp, 0x80
    mov     ah, 0x80
    call    a2_edge
    cmp     byte ptr [a2_rmode], 0
    je      5f
    mov     dx, 0x0128
    in      al, dx
    cmp     byte ptr [a2_r128], 0xEE
    jne     5f
    mov     byte ptr [a2_r128], al
    jmp     5f
4:  test    bp, bp
    jz      5f
    inc     dword ptr [au_cf]
    xor     bp, bp
    xor     ah, ah
    call    a2_edge
5:  loop    3b
    add     dword ptr [au_cs], 256
    call    dl_check
    jnc     2b
    sti
    mov     si, offset tg_a2_cal
    call    au_x
    PS      " cfg="
    mov     al, byte ptr [a2_cfg]
    call    out_x2
    PS      " mode="
    mov     al, 'N'
    cmp     byte ptr [a2_rmode], 0
    je      6f
    mov     al, 'R'
6:  call    out_c
    PS      " first="
    movzx   eax, byte ptr [au_b0]
    shr     eax, 7
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
    PS      " r128="
    mov     al, byte ptr [a2_r128]
    call    out_x2
    PS      " e="
    xor     bx, bx
7:  cmp     bl, byte ptr [a2_ne]
    jae     9f
    test    bx, bx
    jz      71f
    mov     al, ','
    call    out_c
71: push    bx
    shl     bx, 1
    mov     ax, word ptr [a2_edges + bx]
    pop     bx
    push    ax
    mov     al, '+'
    test    ah, 0x80
    jnz     72f
    mov     al, '-'
72: call    out_c
    pop     ax
    and     eax, 0x7FFF
    call    out_d
    inc     bx
    jmp     7b
9:  jmp     out_nl

a2_cal:
    mov     si, offset a2_ctab
1:  mov     al, byte ptr [si]
    cmp     al, 0xFD
    je      2f
    push    si
    push    ax
    mov     byte ptr [a2_rmode], 0
    call    a2_calirr
    pop     ax
    mov     byte ptr [a2_rmode], 1
    call    a2_calirr
    pop     si
    inc     si
    jmp     1b
2:  ret

/* ---------------------------------------------------------------- 2. word OUT */
/* a2_dmaload: BL = register port (0x09 address / 0x0B count): save it to a2_dsave, load
 * AU_DMAKNOWN, flip-flop cleared after. IF=0, channel 2 masked by the caller. */
a2_dmaload:
    movzx   dx, bl
    out     0x19, al
    in      al, dx
    mov     byte ptr [a2_dsave], al
    in      al, dx
    mov     byte ptr [a2_dsave + 1], al
    out     0x19, al
    mov     ax, AU_DMAKNOWN
    out     dx, al
    xchg    al, ah
    out     dx, al
    out     0x19, al
    ret

/* a2_dmaread: DX = register port -> x1, x2 in a2_x; then the saved value written back */
a2_dmaread:
    out     0x19, al
    in      al, dx
    mov     byte ptr [a2_x], al
    in      al, dx
    mov     byte ptr [a2_x + 1], al
    out     0x19, al
    mov     al, byte ptr [a2_dsave]
    out     dx, al
    mov     al, byte ptr [a2_dsave + 1]
    out     dx, al
    out     0x19, al
    ret

/* a2_dmaproof: DX = register port, SI = name: re-read it and print a RESTORE line */
a2_dmaproof:
    cli
    out     0x19, al
    in      al, dx
    mov     bl, al
    in      al, dx
    mov     bh, al
    out     0x19, al
    sti
    movzx   edx, bx
    movzx   eax, word ptr [a2_dsave]
    mov     cx, 0x0004
    mov     bl, 3
    jmp     rs_line

/* a2_wout: one word-OUT row. AL = 0x09 / 0x0A (the DMA rows) */
a2_wo09:
    mov     si, offset tg_a2_w09
    mov     ax, 0x0009
    call    row_mark
    mov     byte ptr [au_dma], 1
    cli
    mov     al, 0x06
    out     0x15, al
    mov     bl, 0x09
    call    a2_dmaload
    in      al, 0x0A
    mov     byte ptr [a2_i0], al
    mov     ax, 0xFF5A
    out     0x09, ax
    in      al, 0x0A
    mov     byte ptr [a2_i1], al
    mov     al, byte ptr [a2_i0]
    out     0x0A, al
    mov     dx, 0x09
    call    a2_dmaread
    sti
    mov     si, offset tg_a2_w09
    call    au_x
    PS      " ax=FF5A r=C33C i0="
    call    a2_pdma
    mov     dx, 0x09
    mov     si, offset n_a2_dmaa
    call    a2_dmaproof
    mov     dx, 0x0A
    mov     al, byte ptr [a2_i0]
    mov     si, offset n_au_imrs
    jmp     rs_port8

a2_pdma:
    mov     al, byte ptr [a2_i0]
    call    out_x2
    PS      " i1="
    mov     al, byte ptr [a2_i1]
    call    out_x2
    PS      " x1="
    mov     al, byte ptr [a2_x]
    call    out_x2
    PS      " x2="
    mov     al, byte ptr [a2_x + 1]
    call    out_x2
    jmp     out_nl

a2_wo0a:
    mov     si, offset tg_a2_w0a
    mov     ax, 0x000A
    call    row_mark
    mov     byte ptr [au_dma], 1
    cli
    mov     al, 0x06
    out     0x15, al
    mov     bl, 0x0B
    call    a2_dmaload
    in      al, 0x0A
    mov     byte ptr [a2_i0], al
    mov     ax, 0x5AFF
    out     0x0A, ax
    in      al, 0x0A
    mov     byte ptr [a2_i1], al
    mov     al, byte ptr [a2_i0]
    out     0x0A, al
    mov     dx, 0x0B
    call    a2_dmaread
    sti
    mov     si, offset tg_a2_w0a
    call    au_x
    PS      " ax=5AFF r=C33C i0="
    call    a2_pdma
    mov     dx, 0x0B
    mov     si, offset n_a2_dmac
    call    a2_dmaproof
    mov     dx, 0x0A
    mov     al, byte ptr [a2_i0]
    mov     si, offset n_au_imrs
    jmp     rs_port8

a2_wo6c:
    mov     si, offset tg_a2_w6c
    mov     ax, 0x006C
    call    row_mark
    cli
    in      al, 0x6C
    mov     byte ptr [a2_x], al
    in      al, 0x6D
    mov     byte ptr [a2_x + 1], al
    mov     ah, al
    mov     al, 0x70
    out     0x6C, ax
    in      al, 0x6C
    mov     byte ptr [a2_i0], al
    in      al, 0x6D
    mov     byte ptr [a2_i1], al
    mov     al, byte ptr [a2_x]
    out     0x6C, al
    sti
    mov     si, offset tg_a2_w6c
    call    au_x
    PS      " b0="
    mov     al, byte ptr [a2_x]
    call    out_x2
    PS      " b1="
    mov     al, byte ptr [a2_x + 1]
    call    out_x2
    PS      " ax="
    mov     al, byte ptr [a2_x + 1]
    call    out_x2
    PS      "70 a0="
    mov     al, byte ptr [a2_i0]
    call    out_x2
    PS      " a1="
    mov     al, byte ptr [a2_i1]
    call    out_x2
    call    out_nl
    mov     dx, 0x6C
    mov     al, byte ptr [a2_x]
    mov     si, offset n_a2_6c
    jmp     rs_port8

/* ---------------------------------------------------------------- 4. word IN timing */
/* a2_t1: DX = port, BL = 0 byte / 1 word -> EAX = PIT counts for 1024 reads (best of 3) */
a2_t1:
    mov     dword ptr [a2_best], 0xFFFFFFFF
    mov     di, 3
1:  cli
    call    pit_read
    mov     si, ax
    mov     cx, 128
    test    bl, bl
    jnz     3f
2:  in      al, dx
    in      al, dx
    in      al, dx
    in      al, dx
    in      al, dx
    in      al, dx
    in      al, dx
    in      al, dx
    loop    2b
    jmp     4f
3:  in      ax, dx
    in      ax, dx
    in      ax, dx
    in      ax, dx
    in      ax, dx
    in      ax, dx
    in      ax, dx
    in      ax, dx
    loop    3b
4:  push    dx
    call    pit_read
    movzx   edx, ax
    movzx   eax, si
    call    pit_sub
    pop     dx
    sti
    cmp     eax, dword ptr [a2_best]
    jae     5f
    mov     dword ptr [a2_best], eax
5:  dec     di
    jnz     1b
    mov     eax, dword ptr [a2_best]
    ret

a2_tw:
    mov     si, offset a2_tlist
1:  mov     dx, word ptr [si]
    cmp     dx, 0xFFFF
    je      9f
    push    si
    mov     al, 'T'
    call    au_mktag                    /* T<port> */
    mov     ax, dx
    call    au_mark
    call    wd_check
    xor     bl, bl
    call    a2_t1
    mov     dword ptr [a2_tb], eax
    mov     bl, 1
    call    a2_t1
    mov     dword ptr [a2_tw0], eax
    mov     si, offset au_tag
    call    au_x
    PS      " n=1024 b="
    mov     eax, dword ptr [a2_tb]
    call    out_d
    PS      " w="
    mov     eax, dword ptr [a2_tw0]
    call    out_d
    call    out_nl
    pop     si
    add     si, 2
    jmp     1b
9:  ret

/* ---------------------------------------------------------------- the section */
sec_audit2:
    mov     si, offset nm_audit2
    mov     eax, WD_60S
    mov     bx, offset a2_exit
    call    sec_begin
    xor     al, al
    mov     byte ptr [a2_calw], al
    mov     byte ptr [au_dma], al
    mov     word ptr [tag_sfx], 0
    mov     dx, 0x0128
    in      al, dx
    mov     byte ptr [a2_v128], al
    mov     si, offset k_STATE
    call    info_start
    PS      "imr_m="
    in      al, 0x02
    call    out_x2
    PS      " imr_s="
    in      al, 0x0A
    call    out_x2
    PS      " p128="
    mov     al, byte ptr [a2_v128]
    call    out_x2
    PS      " pit_order="
    movzx   eax, byte ptr [pit_swap]
    call    out_d
    call    out_nl
    call    a2_cal
    cli
    mov     al, byte ptr [imr_s_save]   /* IR7 open again as found before the word-OUT rows */
    out     0x0A, al
    sti
    call    a2_wo09
    call    a2_wo0a
    call    a2_wo6c
    mov     si, offset a2_wlist
    call    au_words_l
    call    a2_tw
a2_exit:
    call    sec_disarm
    cli
    cmp     byte ptr [a2_calw], 0
    je      1f
    mov     dx, 0x0128
    mov     al, byte ptr [a2_v128]
    out     dx, al
    in      al, dx                      /* the tick flag the write may leave */
1:  cmp     byte ptr [au_dma], 0
    je      2f
    out     0x19, al
2:  mov     al, 0x0A
    out     0x00, al
    out     0x08, al
    mov     al, byte ptr [imr_s_save]
    out     0x0A, al
    sti
    mov     dx, 0x0A
    mov     al, byte ptr [imr_s_save]
    mov     si, offset n_au_imrs
    call    rs_port8
    cmp     byte ptr [a2_calw], 0
    je      3f
    mov     dx, 0x0128
    mov     al, byte ptr [a2_v128]
    mov     si, offset n_au_128
    call    rs_port8
3:  mov     si, offset n_au_ocw3
    mov     eax, 0x0A
    call    rs_default
    cmp     byte ptr [au_dma], 0
    je      4f
    mov     si, offset n_au_dma
    mov     eax, 6
    call    rs_default
4:  call    sec_end
    ret

    VARS
    .p2align 2
a2_best:    .long 0
a2_tb:      .long 0
a2_tw0:     .long 0
a2_edges:   .space 24
a2_t0:      .word 0
a2_dsave:   .word 0
a2_x:       .word 0
a2_cfg:     .byte 0
a2_rmode:   .byte 0
a2_ne:      .byte 0
a2_r128:    .byte 0
a2_calw:    .byte 0
a2_v128:    .byte 0
a2_i0:      .byte 0
a2_i1:      .byte 0
    ENDVARS

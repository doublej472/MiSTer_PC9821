/* sec_opna2.inc - /OPNA2 (opt-in, outside /ALL): how the Xe10's sound chip behaves.
 *
 * WHY. The core's OPNA model (lane opna-5f) posts writes through a queue: BUSY (0x188 bit
 * 7) is queue back-pressure, the timer flag resets act at the guest's write, and a status
 * read is held while a queued 0x29 / ADPCM-B write is still pending (todo item 155). /OPNA
 * only says that the first status poll after a write reads BUSY clear in most of 32
 * trials. This section records, raw, what settles the rest. Nothing is interpreted on the
 * machine; xe10t_decode.py states what each record means.
 *
 * THE MACHINE (owner, 2026-11-01): a PC-9801-86 board (YM2608) and the Xe10's built-in
 * YM2203 (26K-style), the built-in one DISABLED in the BIOS setup for these runs. Where each
 * can answer: the 86 board at 0x188 or (jumper) 0x288 (NP2kai cbus/board86.c board86_reset:
 * `s.base = (snd86opt & 0x01) ? 0x000 : 0x100`, bound at 0x188 + base); a 26K at 0x188 or
 * 0x088 (cbus/board26k.c board26k_reset: `s.base = (snd26opt & 0x10) ? 0x000 : 0x100`, bound
 * at 0x188 - base), and with both boards NP2kai puts the OPN at 0x088 and the OPNA at 0x188
 * (cbus/boardx2.c: `cbuscore_attachsndex(0x088, opn_o, opn_i)` / `(0x188, opna_o, opna_i)`).
 * No capture has read 0x088 or 0x288; each base's first access is a status read behind a
 * flushed ROW line, and a base whose status reads 0xFF (no device: a YM2608/YM2203 status
 * has bits 6-2 clear) gets no write. NP2kai models no PC-9821 built-in sound control port,
 * so the BIOS setting cannot be read: the run notes must record it.
 *
 * 1. IDENTITY (every base 0x188, 0x288, 0x088): `X ID` the as-found reads of base+0 (twice),
 *    +2, +4, +6. For an answering base, `X IDC` twice, with 0xA460 bit 0 (the 86 board's
 *    extension enable, NP2kai cbus/pcm86io.c pcm86_oa460 -> fmboard_extenable) cleared and
 *    set: register 0xFF (the ID: YM2608 01, YMF288 02, YM2203 none - ymfm ym2608/ymf288/
 *    ym2203::read_data; NP2kai's 86 glue answers 1, its 26K glue the last byte written),
 *    registers 0x0E/0x0F (the I/O ports), 0x10/0x20 (no read-back on either chip), an SSG
 *    register written and read back (0x0B <- 5A, A5), the status at +0/+4/+6 and the
 *    extended data port after an extended select of 00 and FF. Then, at a base other than
 *    0x188, a reduced BUSY trial (16 FM 0x30 writes) and a reduced timer-A start (4 trials).
 * 2. BUSY (0x188, extension open, 128 trials per class): address only; FM 0x30/0x40/0xA0/
 *    0xB0, key 0x28 (key-off), SSG 0x08, rhythm 0x10 (no drum keyed) and 0x11, ADPCM-B 0x100
 *    and extended FM 0x130 (silent values). Trial i waits (i * 37) mod 128 `out 5Fh` before
 *    its write, so writes land at many phases of the chip's sample cycle; then the status is
 *    polled until bit 7 clears. A `T` row, a histogram (`i=H`) and the first 32 raw trials.
 *    Then back-to-back writes with no BUSY poll between: an SSG pair read back, and timer A's
 *    two load bytes (0x24 <- FE, 0x25 <- 02: 6 counts; a lost 0x25 leaves 8 counts, a lost
 *    0x24 leaves 1022) timed to the flag.
 * 3. FLAG RESET (32 trials each): timer A (NA 0x3E8) and timer B (NB 0xFE) run with their
 *    flags enabled; once the flag is up, 0x27 is written with the reset bit and the status
 *    is read in a tight loop until it clears; the slave PIC IRR (IR4 = INT5, the 86 board's
 *    IRQ12) is read just before, right after, and polled until bit 4 drops. IRQ12 is masked
 *    in the slave IMR for the whole section, so no handler runs. (IRQWD.TXT IRQ12 read the
 *    slave IRR as 10 both before and after a 0x27 <- 30 write.)
 * 4. WRITE TO EFFECT (8 trials each): timer A at 1, 4, 16, 64 counts and timer B at 1 and 4,
 *    PIT time from the 0x27 start write to the flag; the decoder fits time against counts
 *    (slope = the period per count, intercept = the start latency plus the poll).
 * 5. ADPCM-B (0x188, extension open): 0x110 <- 00 (unmask), 0x100 <- 01 (reset), a 0x110 <- 80
 *    flag reset timed, then a memory-write setup (0x100 <- 60, 0x101 <- 02, start = stop = 0,
 *    limit FFFF) and 40 data bytes through 0x108, each followed by a BRDY (0x18C bit 3) poll;
 *    then 8 timed 0x110 <- 80 resets of EOS/BRDY. It writes 40 bytes at the start of the
 *    board's ADPCM RAM. A chip without ADPCM-B shows the polls running to their bound.
 *
 * RESTORE: on every base it wrote, 0x27 <- 30 (timers stopped, both flags reset), timer
 * loads and SSG 0x0B/0x0C <- 0, FM 0x30 <- 0; on 0x188 key-off of all six FM channels, the
 * rhythm dump 0x10 <- BF, the /OPNA silent values, ADPCM-B reset (0x100 <- 01, 00), its flags
 * reset (0x110 <- 80) and the flag mask 0x110 <- 1C (ymfm ym2608::reset `m_flag_control =
 * 0x1c`: EOS/BRDY/ZERO kept off the IRQ); 0xA460 from its read-back; the slave IMR from its
 * read-back; the slave PIC's read register left at ISR (OCW3 0B, as IRQWD leaves it).
 * Register 0x29 (the IRQ enable) is never written.
 */
    .equ O2_POLL,  SECBUF               /* 128 dwords each */
    .equ O2_PIT,   SECBUF + 0x200
    .equ O2_AUX,   SECBUF + 0x400
    .equ O2_AUX2,  SECBUF + 0x600
    .equ O2_N,     128

tc_opna2:   .asciz "OPNA 0x188/0x288/0x088 (+2/+4/+6) FM 24-28 30 40 A0 B0, SSG 08 0B 0C, RHY 10 11, ext 00-05 08 0C 0D 10 30, ADPCM RAM 0-39, 0xA460 bit 0, IMR_S bit 4, OCW3 slave"
n_opna2r:   .asciz "OPNA2_REGS"
n_a460:     .asciz "PA460"
to_o2:      .asciz "opna2_poll"
f_spit:     .asciz "start_pit"
f_reads:    .asciz "reads"
f_irrn:     .asciz "irr_reads"
f_irrpit:   .asciz "irr_pit"
tg_o2id:    .asciz "ID"
tg_o2idc:   .asciz "IDC"
tg_b2bs:    .asciz "B2B_SSG"
tg_b2bt:    .asciz "B2B_TMR"
tg_b2bt3:   .asciz "B2B_TMR3"
tg_fra:     .asciz "FR_TMRA"
tg_frb:     .asciz "FR_TMRB"
tg_adbs:    .asciz "ADB_SETUP"
tg_adbw:    .asciz "ADB_W"
tg_adbe:    .asciz "ADB_END"
tg_fradb:   .asciz "FR_ADB"
sfx_288:    .asciz "_288"
sfx_088:    .asciz "_088"
o2_bases:   .word 0x188, 0x288, 0x088
o2_sfx:     .word 0, sfx_288, sfx_088

/* the BUSY classes: tag, register, data, mode (0 address only, 1 base data, 2 extended) */
    .macro O2C tag, reg, dat, mode
    .word   903f
    .byte   \reg, \dat, \mode, 0
    .pushsection .text, 1
903: .asciz "\tag"
    .popsection
    .endm
o2_cls:
    O2C "BUSY_ADDR",   0x30, 0x00, 0
    O2C "BUSY_FM30",   0x30, 0x00, 1
    O2C "BUSY_FM40",   0x40, 0x7F, 1
    O2C "BUSY_FMA0",   0xA0, 0x00, 1
    O2C "BUSY_FMB0",   0xB0, 0x00, 1
    O2C "BUSY_KEY28",  0x28, 0x00, 1
    O2C "BUSY_SSG08",  0x08, 0x00, 1
    O2C "BUSY_RHY10",  0x10, 0x00, 1
    O2C "BUSY_RHY11",  0x11, 0x00, 1
    O2C "BUSY_ADB100", 0x00, 0x00, 2
    O2C "BUSY_EXT130", 0x30, 0x00, 2
    .word   0
o2_fm30:
    O2C "BUSY_FM30",   0x30, 0x00, 1

/* the write-to-effect loads: tag, value (A: NA, B: NB), kind (0 A, 1 B) */
    .macro O2T tag, val, kind
    .word   904f
    .word   \val
    .byte   \kind, 0
    .pushsection .text, 1
904: .asciz "\tag"
    .popsection
    .endm
o2_tms:
    O2T "TMRA_3FF", 0x3FF, 0
    O2T "TMRA_3FC", 0x3FC, 0
    O2T "TMRA_3F0", 0x3F0, 0
    O2T "TMRA_3C0", 0x3C0, 0
    O2T "TMRB_FF",  0xFF,  1
    O2T "TMRB_FC",  0xFC,  1
    .word   0
o2_tm1:
    O2T "TMRA_3F0", 0x3F0, 0

/* ---------------------------------------------------------------- port helpers */
/* o2_wait: poll [o2_base] until bit 7 clears; CF = 1 at the 10 ms deadline (counted). */
o2_wait:
    push    eax
    push    dx
    mov     dx, word ptr [o2_base]
    in      al, dx
    test    al, 0x80
    jz      2f
    mov     eax, T_10MS
    call    dl_start
1:  in      al, dx
    test    al, 0x80
    jz      2f
    call    dl_check
    jnc     1b
    inc     word ptr [o2_to]
    pop     dx
    pop     eax
    stc
    ret
2:  pop     dx
    pop     eax
    clc
    ret

/* o2_put / o2_putx: AL = register, AH = data, through base+0/+2 or base+4/+6, BUSY-polled
 * before the select and before the data. Registers kept. */
o2_put:
    push    dx
    mov     dx, word ptr [o2_base]
    jmp     1f
o2_putx:
    push    dx
    mov     dx, word ptr [o2_base]
    add     dx, 4
1:  call    o2_wait
    out     dx, al
    call    o2_wait
    xchg    al, ah
    add     dx, 2
    out     dx, al
    xchg    al, ah
    pop     dx
    ret

/* o2_get: AL = register -> AL = base+2 after the select (BUSY-polled). */
o2_get:
    push    dx
    call    o2_wait
    mov     dx, word ptr [o2_base]
    out     dx, al
    call    o2_wait
    add     dx, 2
    in      al, dx
    pop     dx
    ret

/* o2_in: AL = offset (0/2/4/6) -> AL = in from base+offset. */
o2_in:
    push    dx
    movzx   dx, al
    add     dx, word ptr [o2_base]
    in      al, dx
    pop     dx
    ret

o2_a460w:                               /* AL -> 0xA460 */
    push    dx
    mov     dx, 0xA460
    out     dx, al
    pop     dx
    ret

/* o2_irr: AL = the slave PIC's IRR (OCW3 0Ah to 0x08, then read 0x08) */
o2_irr:
    mov     al, 0x0A
    out     0x08, al
    in      al, 0x08
    ret

/* o2_x: start an X row: `X OPNA2 <SI tag><sfx>` */
o2_x:
    push    si
    mov     si, offset k_X
    call    row_start
    pop     si
o2_tag:
    call    out_s
    push    si
    mov     si, word ptr [tag_sfx]
    test    si, si
    jz      1f
    call    out_s
1:  pop     si
    ret

/* o2_kx: SI = key, AL = byte: " key=xx" */
o2_kx:
    call    out_sp
    call    out_s
    push    ax
    mov     al, '='
    call    out_c
    pop     ax
    jmp     out_x2

/* o2_mmm: SI = field name, BX = dword array, CX = count: sorts it, prints " f=min/med/max" */
o2_mmm:
    push    word ptr [reps]
    mov     word ptr [reps], cx
    call    sort_arr
    call    out_sp
    call    out_s
    push    ax
    mov     al, '='
    call    out_c
    pop     ax
    call    out_mmm
    pop     word ptr [reps]
    ret

/* o2_store: DI = trial index, EAX -> [BX + 4*DI] */
o2_store:
    push    di
    shl     di, 2
    mov     dword ptr [bx + di], eax
    pop     di
    ret

/* ---------------------------------------------------------------- 1. identity */
k_st:   .asciz "st"
k_st2:  .asciz "st2"
k_d:    .asciz "d"
k_e:    .asciz "e"
k_f:    .asciz "f"
k_a460: .asciz "a460"
k_id:   .asciz "id"
k_id2:  .asciz "id2"
k_r0e:  .asciz "r0e"
k_r0f:  .asciz "r0f"
k_r10:  .asciz "r10"
k_r20:  .asciz "r20"
k_w5a:  .asciz "w5a"
k_wa5:  .asciz "wa5"
k_s4:   .asciz "s4"
k_s6:   .asciz "s6"
k_x00:  .asciz "x00"
k_xff:  .asciz "xff"
k_st0:  .asciz "st0"
k_st1:  .asciz "st1"
k_stl:  .asciz "stl"
k_irr0: .asciz "irr0"
k_irr1: .asciz "irr1"
k_r0b:  .asciz "r0b"
k_r0c:  .asciz "r0c"
k_srst: .asciz "s_rst"
k_sset: .asciz "s_set"
k_sb:   .asciz "sb"
k_b:    .asciz "b"
k_ext:  .asciz "ext"
k_i:    .asciz "i"
k_dly:  .asciz "dly"
k_pit:  .asciz "pit"
k_art:  .asciz "art"
k_polls: .asciz "polls"
k_irrn: .asciz "irrn"
k_irrp: .asciz "irrpit"
k_trials2: .asciz "trials"

/* o2_ident: [o2_base], [o2_bi] = base index. The as-found reads, then (if the base answers)
 * the IDC pair with the extension closed and open; 0xA460 restored to as found after. */
o2_ident:
    mov     si, offset tg_o2id
    mov     ax, word ptr [o2_base]
    call    row_mark
    mov     si, offset tg_o2id
    call    o2_x
    PS      " b="
    mov     ax, word ptr [o2_base]
    call    out_x4
    mov     al, 0
    call    o2_in
    mov     bx, word ptr [o2_bi]
    mov     byte ptr [o2_sts + bx], al
    mov     si, offset k_st
    call    o2_kx
    mov     al, 0
    call    o2_in
    mov     si, offset k_st2
    call    o2_kx
    mov     al, 2
    call    o2_in
    mov     si, offset k_d
    call    o2_kx
    mov     al, 4
    call    o2_in
    mov     si, offset k_e
    call    o2_kx
    mov     al, 6
    call    o2_in
    mov     si, offset k_f
    call    o2_kx
    call    out_nl
    mov     bx, word ptr [o2_bi]
    cmp     byte ptr [o2_sts + bx], 0xFF
    jne     1f
    ret
1:  mov     al, byte ptr [o2_a460]
    and     al, 0xFE
    call    o2_a460w
    xor     bl, bl
    call    o2_idc
    mov     al, byte ptr [o2_a460]
    or      al, 1
    call    o2_a460w
    mov     bl, 1
    call    o2_idc
    mov     al, byte ptr [o2_a460]
    call    o2_a460w
    ret

/* o2_idc: BL = the extension bit written. Reads under cli into o2_v, printed after. */
o2_idc:
    cli
    mov     dx, 0xA460
    in      al, dx
    mov     byte ptr [o2_v + 0], al
    mov     al, 0xFF
    call    o2_get
    mov     byte ptr [o2_v + 1], al
    mov     al, 2
    call    o2_in                       /* the ID again, no new select */
    mov     byte ptr [o2_v + 2], al
    mov     al, 0x0E
    call    o2_get
    mov     byte ptr [o2_v + 3], al
    mov     al, 0x0F
    call    o2_get
    mov     byte ptr [o2_v + 4], al
    mov     al, 0x10
    call    o2_get
    mov     byte ptr [o2_v + 5], al
    mov     al, 0x20
    call    o2_get
    mov     byte ptr [o2_v + 6], al
    mov     ax, 0x5A0B
    call    o2_put
    mov     al, 0x0B
    call    o2_get
    mov     byte ptr [o2_v + 7], al
    mov     ax, 0xA50B
    call    o2_put
    mov     al, 0x0B
    call    o2_get
    mov     byte ptr [o2_v + 8], al
    mov     ax, 0x000B
    call    o2_put
    call    o2_wait
    mov     al, 0
    call    o2_in
    mov     byte ptr [o2_v + 9], al
    mov     al, 4
    call    o2_in
    mov     byte ptr [o2_v + 10], al
    mov     al, 6
    call    o2_in
    mov     byte ptr [o2_v + 11], al
    mov     dx, word ptr [o2_base]
    add     dx, 4
    call    o2_wait
    mov     al, 0x00
    out     dx, al                      /* extended select 00 (no data write) */
    call    o2_wait
    add     dx, 2
    in      al, dx
    mov     byte ptr [o2_v + 12], al
    sub     dx, 2
    mov     al, 0xFF
    out     dx, al                      /* extended select FF */
    call    o2_wait
    add     dx, 2
    in      al, dx
    mov     byte ptr [o2_v + 13], al
    sti
    mov     si, offset tg_o2idc
    call    o2_x
    PS      " b="
    mov     ax, word ptr [o2_base]
    call    out_x4
    PS      " ext="
    movzx   eax, bl
    call    out_d
    mov     di, offset o2_idkeys
    xor     bx, bx
2:  mov     si, word ptr [di]
    test    si, si
    jz      3f
    mov     al, byte ptr [o2_v + bx]
    call    o2_kx
    inc     bx
    add     di, 2
    jmp     2b
3:  call    out_nl
    ret
o2_idkeys:  .word k_a460, k_id, k_id2, k_r0e, k_r0f, k_r10, k_r20, k_w5a, k_wa5
            .word k_st, k_s4, k_s6, k_x00, k_xff, 0

/* ---------------------------------------------------------------- 2. BUSY */
/* o2_busy: SI = class descriptor (O2C), CX = trials ([o2_base], [tag_sfx] set). */
o2_busy:
    pushad
    mov     word ptr [o2_n], cx
    mov     ax, word ptr [si + 2]
    mov     word ptr [o2_reg], ax
    mov     al, byte ptr [si + 4]
    mov     byte ptr [o2_mode], al
    mov     si, word ptr [si]
    mov     word ptr [o2_tg], si
    mov     ax, word ptr [o2_base]
    cmp     byte ptr [o2_mode], 2
    jne     1f
    add     ax, 4
1:  call    row_mark
    xor     di, di
2:  call    wd_check
    call    o2_btrial
    inc     di
    cmp     di, word ptr [o2_n]
    jb      2b
    call    o2_bprint
    popad
    ret

/* o2_btrial: DI = trial index. Interrupts off for the trial. */
o2_btrial:
    pushad
    cli
    call    o2_wait
    jc      9f
    mov     ax, word ptr [o2_reg]
    mov     dx, word ptr [o2_base]
    cmp     byte ptr [o2_mode], 0
    je      1f
    cmp     byte ptr [o2_mode], 2
    jne     11f
    add     dx, 4
11: out     dx, al                      /* the select (untimed) */
    call    o2_wait
    jc      9f
    add     dx, 2
    mov     al, ah
1:  mov     bl, al                      /* DX = the port written, BL = the byte */
    mov     cx, di
    imul    cx, cx, 37
    and     cx, 127
    jcxz    3f
2:  out     0x5F, al                    /* the phase delay: (i * 37) mod 128 wait-port writes */
    loop    2b
3:  call    pit_read
    mov     si, ax
    mov     al, bl
    out     dx, al                      /* the timed write */
    xor     cx, cx
    mov     dx, word ptr [o2_base]
4:  in      al, dx
    inc     cx
    test    al, 0x80
    jz      5f
    cmp     cx, 0xFFFF
    jb      4b
    inc     word ptr [o2_to]
5:  call    pit_read
    movzx   edx, ax
    movzx   eax, si
    call    pit_sub
    mov     bx, O2_PIT
    call    o2_store
    movzx   eax, cx
    mov     bx, O2_POLL
    call    o2_store
    jmp     8f
9:  mov     eax, 0xFFFF
    mov     bx, O2_PIT
    call    o2_store
    mov     bx, O2_POLL
    call    o2_store
8:  sti
    popad
    ret

/* o2_bprint: the first 32 raw trials, the histograms, then the T row. Poll bins: 1, 2, 3, 4,
 * 5-8, 9-16, 17-32, 33-64, 65+ (a timed-out trial, 65535, lands in the last); busy_pit bins
 * are 8 PIT counts wide, 16 bins, the last one 120+. */
o2_bprint:
    pushad
    xor     di, di
1:  cmp     di, word ptr [o2_n]
    jae     2f
    cmp     di, 32
    jae     2f
    mov     si, word ptr [o2_tg]
    call    o2_x
    movzx   eax, di
    mov     si, offset k_i
    call    out_kd
    mov     ax, di
    imul    ax, ax, 37
    and     ax, 127
    movzx   eax, ax
    mov     si, offset k_dly
    call    out_kd
    mov     bx, di
    shl     bx, 2
    mov     eax, dword ptr [O2_POLL + bx]
    mov     si, offset k_polls
    call    out_kd
    mov     eax, dword ptr [O2_PIT + bx]
    mov     si, offset k_pit
    call    out_kd
    call    out_nl
    inc     di
    jmp     1b
2:  /* histograms */
    mov     di, offset o2_hp
    mov     cx, 25
    xor     ax, ax
    push    es
    push    cs
    pop     es
    rep     stosw
    pop     es
    xor     di, di
3:  cmp     di, word ptr [o2_n]
    jae     6f
    mov     bx, di
    shl     bx, 2
    mov     eax, dword ptr [O2_POLL + bx]
    xor     bx, bx
    cmp     eax, 4
    ja      31f
    mov     bx, ax
    dec     bx                          /* 1..4 -> bins 0..3 */
    jmp     35f
31: mov     bx, 4
    mov     edx, 8
32: cmp     eax, edx
    jbe     35f
    inc     bx
    shl     edx, 1
    cmp     bx, 8
    jb      32b
35: shl     bx, 1
    inc     word ptr [o2_hp + bx]
    mov     bx, di
    shl     bx, 2
    mov     eax, dword ptr [O2_PIT + bx]
    shr     eax, 3
    cmp     eax, 15
    jbe     36f
    mov     eax, 15
36: mov     bx, ax
    shl     bx, 1
    inc     word ptr [o2_ht + bx]
    inc     di
    jmp     3b
6:  mov     si, word ptr [o2_tg]
    call    o2_x
    PS      " i=H polls_h="
    mov     si, offset o2_hp
    mov     cx, 9
    call    o2_hlist
    PS      " pit_h="
    mov     si, offset o2_ht
    mov     cx, 16
    call    o2_hlist
    call    out_nl
    /* the T row */
    mov     si, offset k_T
    call    row_start
    mov     si, word ptr [o2_tg]
    call    o2_tag
    movzx   eax, word ptr [o2_n]
    mov     si, offset k_trials
    call    out_kd
    mov     cx, word ptr [o2_n]
    mov     bx, O2_PIT
    mov     si, offset f_busy
    call    o2_mmm
    mov     bx, O2_POLL
    mov     si, offset f_polls
    call    o2_mmm
    call    out_nl
    popad
    ret

/* o2_hlist: SI = word array, CX = count -> "a,b,c" */
o2_hlist:
    push    eax
1:  lodsw
    movzx   eax, ax
    call    out_d
    dec     cx
    jz      2f
    mov     al, ','
    call    out_c
    jmp     1b
2:  pop     eax
    ret

/* o2_b2b: back-to-back writes with no BUSY poll between them, 8 trials each. */
o2_b2b:
    mov     si, offset tg_b2bs
    mov     ax, word ptr [o2_base]
    call    row_mark
    xor     di, di
1:  call    wd_check
    cli
    mov     ax, 0x000B
    call    o2_put
    mov     ax, 0x000C
    call    o2_put
    call    o2_wait
    mov     dx, word ptr [o2_base]
    mov     bx, di
    mov     al, 0x0B
    out     dx, al
    add     dx, 2
    mov     al, bl
    add     al, 0x11
    out     dx, al
    sub     dx, 2
    mov     al, 0x0C
    out     dx, al
    add     dx, 2
    mov     al, bl
    add     al, 0x22
    out     dx, al
    sub     dx, 2
    in      al, dx                      /* the status right after the burst */
    mov     byte ptr [o2_v + 0], al
    mov     al, 0x0B
    call    o2_get
    mov     byte ptr [o2_v + 1], al
    mov     al, 0x0C
    call    o2_get
    mov     byte ptr [o2_v + 2], al
    sti
    mov     si, offset tg_b2bs
    call    o2_x
    movzx   eax, di
    mov     si, offset k_i
    call    out_kd
    PS      " v1="
    mov     al, bl
    add     al, 0x11
    call    out_x2
    PS      " v2="
    mov     al, bl
    add     al, 0x22
    call    out_x2
    mov     al, byte ptr [o2_v + 0]
    mov     si, offset k_st
    call    o2_kx
    mov     al, byte ptr [o2_v + 1]
    mov     si, offset k_r0b
    call    o2_kx
    mov     al, byte ptr [o2_v + 2]
    mov     si, offset k_r0c
    call    o2_kx
    call    out_nl
    inc     di
    cmp     di, 8
    jb      1b
    mov     ax, 0x000B
    call    o2_put
    mov     ax, 0x000C
    call    o2_put
    /* timer A's load pair unpolled (B2B_TMR), then the pair and the start unpolled (B2B_TMR3) */
    mov     byte ptr [o2_mode], 0
    mov     si, offset tg_b2bt
    call    o2_b2bt
    mov     byte ptr [o2_mode], 1
    mov     si, offset tg_b2bt3
    call    o2_b2bt
    ret

/* o2_b2bt: SI = tag, [o2_mode] 1 = the 0x27 start unpolled too. 8 trials. */
o2_b2bt:
    push    si
    mov     ax, word ptr [o2_base]
    call    row_mark
    pop     si
    xor     di, di
1:  call    wd_check
    push    si
    cli
    mov     ax, 0x3027
    call    o2_put
    mov     ax, 0x0024
    call    o2_put
    mov     ax, 0x0025
    call    o2_put
    call    o2_wait
    mov     dx, word ptr [o2_base]
    call    pit_read
    mov     si, ax
    call    artic_read
    mov     dword ptr [o2_t0], eax
    mov     al, 0x24
    out     dx, al
    add     dx, 2
    mov     al, 0xFE
    out     dx, al
    sub     dx, 2
    mov     al, 0x25
    out     dx, al
    add     dx, 2
    mov     al, 0x02
    out     dx, al
    sub     dx, 2
    cmp     byte ptr [o2_mode], 0
    jne     2f
    call    o2_wait
2:  mov     al, 0x27
    out     dx, al
    cmp     byte ptr [o2_mode], 0
    jne     3f
    call    o2_wait
3:  add     dx, 2
    mov     al, 0x15                    /* reset A, enable A's flag, load (start) A */
    out     dx, al
    sub     dx, 2
    xor     ecx, ecx
4:  in      al, dx
    inc     ecx
    test    al, 0x01
    jnz     5f
    test    cx, 0xFF
    jnz     4b
    mov     eax, dword ptr [o2_t0]
    call    artic_since
    cmp     eax, T_10MS * 3
    jb      4b
    inc     word ptr [o2_to]
    in      al, dx
5:  mov     byte ptr [o2_v], al
    call    pit_read
    movzx   edx, ax
    movzx   eax, si
    call    pit_sub
    mov     dword ptr [o2_v + 4], eax
    mov     eax, dword ptr [o2_t0]
    call    artic_since
    mov     dword ptr [o2_v + 8], eax
    mov     ax, 0x3027
    call    o2_put
    sti
    pop     si
    call    o2_x
    movzx   eax, di
    push    si
    mov     si, offset k_i
    call    out_kd
    mov     eax, ecx
    mov     si, offset k_reads
    call    out_kd
    mov     eax, dword ptr [o2_v + 4]
    mov     si, offset k_pit
    call    out_kd
    mov     eax, dword ptr [o2_v + 8]
    mov     si, offset k_art
    call    out_kd
    mov     al, byte ptr [o2_v]
    mov     si, offset k_st
    call    o2_kx
    call    out_nl
    pop     si
    inc     di
    cmp     di, 8
    jb      1b
    ret
k_reads:    .asciz "reads"

/* ---------------------------------------------------------------- 3. flag reset */
/* o2_frl: SI = tag, DL = 0 timer A / 1 timer B. 32 trials, each printed raw, then a T row. */
o2_frl:
    pushad
    mov     word ptr [o2_tg], si
    mov     ax, word ptr [o2_base]
    call    row_mark
    cli
    mov     ax, 0x3027
    call    o2_put
    mov     byte ptr [o2_msk], 0x01
    mov     byte ptr [o2_ctl], 0x15
    test    dl, dl
    jnz     1f
    mov     ax, 0xFA24                  /* NA = 0x3E8: 24 counts */
    call    o2_put
    mov     ax, 0x0025
    call    o2_put
    jmp     2f
1:  mov     byte ptr [o2_msk], 0x02
    mov     byte ptr [o2_ctl], 0x2A
    mov     ax, 0xFE26                  /* NB = 0xFE: 2 counts */
    call    o2_put
2:  mov     al, 0x27
    mov     ah, byte ptr [o2_ctl]
    call    o2_put
    sti
    xor     di, di
3:  call    wd_check
    call    o2_frtrial
    inc     di
    cmp     di, 32
    jb      3b
    cli
    mov     ax, 0x3027
    call    o2_put
    sti
    mov     si, offset k_T
    call    row_start
    mov     si, word ptr [o2_tg]
    call    o2_tag
    mov     eax, 32
    mov     si, offset k_trials
    call    out_kd
    mov     cx, 32
    mov     bx, O2_POLL
    mov     si, offset f_reads
    call    o2_mmm
    mov     bx, O2_PIT
    mov     si, offset f_busy
    call    o2_mmm
    mov     bx, O2_AUX
    mov     si, offset f_irrn
    call    o2_mmm
    mov     bx, O2_AUX2
    mov     si, offset f_irrpit
    call    o2_mmm
    call    out_nl
    popad
    ret

/* o2_frtrial: DI = index. Wait for the flag (5 ms), then the timed reset and polls. */
o2_frtrial:
    pushad
    cli
    mov     eax, T_1MS * 5
    call    dl_start
    mov     dx, word ptr [o2_base]
1:  in      al, dx
    test    al, byte ptr [o2_msk]
    jnz     2f
    call    dl_check
    jnc     1b
    inc     word ptr [o2_to]
2:  mov     byte ptr [o2_v + 0], al     /* st0 */
    call    o2_irr
    mov     byte ptr [o2_v + 2], al     /* irr0 */
    call    o2_wait
    mov     al, 0x27
    out     dx, al
    call    o2_wait
    call    pit_read
    mov     si, ax
    add     dx, 2
    mov     al, byte ptr [o2_ctl]       /* the reset bit, the timer kept running */
    out     dx, al
    sub     dx, 2
    xor     cx, cx
3:  in      al, dx
    inc     cx
    cmp     cx, 1
    jne     31f
    mov     byte ptr [o2_v + 1], al     /* st1: the first read after the write */
31: test    al, byte ptr [o2_msk]
    jz      4f
    cmp     cx, 4096
    jb      3b
4:  mov     byte ptr [o2_v + 4], al     /* stl */
    call    pit_read
    mov     word ptr [o2_v + 6], ax
    call    o2_irr
    mov     byte ptr [o2_v + 3], al     /* irr1 */
    xor     bp, bp
5:  inc     bp
    test    al, 0x10
    jz      6f
    cmp     bp, 4096
    jae     6f
    call    o2_irr
    jmp     5b
6:  call    pit_read
    movzx   edx, ax
    movzx   eax, si
    call    pit_sub
    mov     bx, O2_AUX2
    call    o2_store
    movzx   edx, word ptr [o2_v + 6]
    movzx   eax, si
    call    pit_sub
    mov     bx, O2_PIT
    call    o2_store
    movzx   eax, cx
    mov     bx, O2_POLL
    call    o2_store
    movzx   eax, bp
    mov     bx, O2_AUX
    call    o2_store
    sti
    mov     si, word ptr [o2_tg]
    call    o2_x
    movzx   eax, di
    mov     si, offset k_i
    call    out_kd
    mov     al, byte ptr [o2_v + 0]
    mov     si, offset k_st0
    call    o2_kx
    mov     al, byte ptr [o2_v + 1]
    mov     si, offset k_st1
    call    o2_kx
    mov     al, byte ptr [o2_v + 4]
    mov     si, offset k_stl
    call    o2_kx
    movzx   eax, cx
    mov     si, offset k_reads
    call    out_kd
    mov     bx, di
    shl     bx, 2
    mov     eax, dword ptr [O2_PIT + bx]
    mov     si, offset k_pit
    call    out_kd
    mov     al, byte ptr [o2_v + 2]
    mov     si, offset k_irr0
    call    o2_kx
    mov     al, byte ptr [o2_v + 3]
    mov     si, offset k_irr1
    call    o2_kx
    movzx   eax, bp
    mov     si, offset k_irrn
    call    out_kd
    mov     eax, dword ptr [O2_AUX2 + bx]
    mov     si, offset k_irrp
    call    out_kd
    call    out_nl
    popad
    ret

/* ---------------------------------------------------------------- 4. write to effect */
/* o2_tmr: SI = O2T descriptor, CX = trials. PIT time from the 0x27 start write to the flag. */
o2_tmr:
    pushad
    mov     word ptr [o2_n], cx
    mov     ax, word ptr [si + 2]
    mov     word ptr [o2_reg], ax
    mov     al, byte ptr [si + 4]
    mov     byte ptr [o2_mode], al
    mov     si, word ptr [si]
    mov     word ptr [o2_tg], si
    mov     ax, word ptr [o2_base]
    call    row_mark
    xor     di, di
1:  call    wd_check
    cli
    mov     ax, 0x3027
    call    o2_put
    mov     cx, word ptr [o2_reg]
    mov     byte ptr [o2_msk], 0x01
    mov     byte ptr [o2_ctl], 0x15
    cmp     byte ptr [o2_mode], 0
    jne     2f
    mov     ah, cl
    shr     cx, 2
    and     ah, 3
    mov     al, 0x25
    push    ax
    mov     al, 0x24
    mov     ah, cl
    call    o2_put
    pop     ax
    call    o2_put
    jmp     3f
2:  mov     byte ptr [o2_msk], 0x02
    mov     byte ptr [o2_ctl], 0x2A
    mov     al, 0x26
    mov     ah, cl
    call    o2_put
3:  call    o2_wait
    mov     dx, word ptr [o2_base]
    mov     al, 0x27
    out     dx, al
    call    o2_wait
    call    pit_read
    mov     si, ax
    add     dx, 2
    mov     al, byte ptr [o2_ctl]
    out     dx, al
    sub     dx, 2
    xor     cx, cx
4:  in      al, dx
    inc     cx
    test    al, byte ptr [o2_msk]
    jnz     5f
    cmp     cx, 0xFFFF
    jb      4b
    inc     word ptr [o2_to]
5:  call    pit_read
    movzx   edx, ax
    movzx   eax, si
    call    pit_sub
    mov     bx, O2_PIT
    call    o2_store
    movzx   eax, cx
    mov     bx, O2_POLL
    call    o2_store
    mov     ax, 0x3027
    call    o2_put
    sti
    mov     si, word ptr [o2_tg]
    call    o2_x
    movzx   eax, di
    mov     si, offset k_i
    call    out_kd
    movzx   eax, cx
    mov     si, offset k_reads
    call    out_kd
    mov     bx, di
    shl     bx, 2
    mov     eax, dword ptr [O2_PIT + bx]
    mov     si, offset k_pit
    call    out_kd
    call    out_nl
    inc     di
    cmp     di, word ptr [o2_n]
    jb      1b
    mov     si, offset k_T
    call    row_start
    mov     si, word ptr [o2_tg]
    call    o2_tag
    movzx   eax, word ptr [o2_n]
    mov     si, offset k_trials
    call    out_kd
    mov     cx, word ptr [o2_n]
    mov     bx, O2_PIT
    mov     si, offset f_spit
    call    o2_mmm
    mov     bx, O2_POLL
    mov     si, offset f_reads
    call    o2_mmm
    call    out_nl
    popad
    ret

/* ---------------------------------------------------------------- 5. ADPCM-B */
/* o2_xfr: the timed 0x110 <- 80 flag reset. -> o2_v+0 = status before, +1 = first read after,
 * +2 = last read, CX = reads until bits 3-2 (BRDY, EOS) read clear (bound 4096), EAX = pit. */
o2_xfr:
    push    dx
    push    si
    mov     dx, word ptr [o2_base]
    add     dx, 4
    call    o2_wait
    mov     al, 0x10
    out     dx, al
    call    o2_wait
    in      al, dx
    mov     byte ptr [o2_v + 0], al
    call    pit_read
    mov     si, ax
    add     dx, 2
    mov     al, 0x80
    out     dx, al
    sub     dx, 2
    xor     cx, cx
1:  in      al, dx
    inc     cx
    cmp     cx, 1
    jne     2f
    mov     byte ptr [o2_v + 1], al
2:  test    al, 0x0C
    jz      3f
    cmp     cx, 4096
    jb      1b
3:  mov     byte ptr [o2_v + 2], al
    call    pit_read
    movzx   edx, ax
    movzx   eax, si
    call    pit_sub
    pop     si
    pop     dx
    ret

/* o2_xpr: print " sb= st1= stl= reads= pit=" from o2_xfr's results (EAX = pit, CX = reads) */
o2_xpr:
    push    eax
    mov     al, byte ptr [o2_v + 0]
    mov     si, offset k_sb
    call    o2_kx
    mov     al, byte ptr [o2_v + 1]
    mov     si, offset k_st1
    call    o2_kx
    mov     al, byte ptr [o2_v + 2]
    mov     si, offset k_stl
    call    o2_kx
    movzx   eax, cx
    mov     si, offset k_reads
    call    out_kd
    pop     eax
    mov     si, offset k_pit
    jmp     out_kd

o2_adpcmb:
    mov     si, offset tg_adbs
    mov     ax, word ptr [o2_base]
    add     ax, 4
    call    row_mark
    cli
    mov     al, 4
    call    o2_in
    mov     byte ptr [o2_v + 8], al     /* as entered */
    mov     ax, 0x0010                  /* 0x110 <- 00: no flag masked */
    call    o2_putx
    mov     ax, 0x0100                  /* 0x100 <- 01: reset */
    call    o2_putx
    call    o2_wait
    mov     al, 4
    call    o2_in
    mov     byte ptr [o2_v + 9], al
    call    o2_xfr
    mov     dword ptr [o2_v + 12], eax
    mov     word ptr [o2_v + 10], cx
    mov     ax, 0x6000                  /* 0x100 <- 60: memory write (REC, external) */
    call    o2_putx
    mov     ax, 0x0201                  /* 0x101 <- 02: RAM, 8-bit access */
    call    o2_putx
    mov     ax, 0x0002
    call    o2_putx
    mov     ax, 0x0003
    call    o2_putx
    mov     ax, 0x0004
    call    o2_putx
    mov     ax, 0x0005
    call    o2_putx
    mov     ax, 0xFF0C
    call    o2_putx
    mov     ax, 0xFF0D
    call    o2_putx
    call    o2_wait
    mov     al, 4
    call    o2_in
    mov     byte ptr [o2_v + 3], al
    sti
    mov     si, offset tg_adbs
    call    o2_x
    mov     al, byte ptr [o2_v + 8]
    mov     si, offset k_st0
    call    o2_kx
    mov     al, byte ptr [o2_v + 9]
    mov     si, offset k_srst
    call    o2_kx
    mov     cx, word ptr [o2_v + 10]
    mov     eax, dword ptr [o2_v + 12]
    call    o2_xpr
    mov     al, byte ptr [o2_v + 3]
    mov     si, offset k_sset
    call    o2_kx
    call    out_nl
    /* 40 data bytes, each followed by a BRDY poll */
    xor     di, di
1:  call    wd_check
    cli
    mov     dx, word ptr [o2_base]
    add     dx, 4
    call    o2_wait
    mov     al, 0x08
    out     dx, al
    call    o2_wait
    call    pit_read
    mov     si, ax
    add     dx, 2
    mov     al, 0x80
    out     dx, al
    sub     dx, 2
    xor     cx, cx
2:  in      al, dx
    inc     cx
    test    al, 0x08
    jnz     3f
    cmp     cx, 4096
    jb      2b
3:  mov     bl, al
    call    pit_read
    movzx   edx, ax
    movzx   eax, si
    call    pit_sub
    sti
    push    eax
    mov     si, offset tg_adbw
    call    o2_x
    movzx   eax, di
    mov     si, offset k_i
    call    out_kd
    movzx   eax, cx
    mov     si, offset k_reads
    call    out_kd
    pop     eax
    mov     si, offset k_pit
    call    out_kd
    mov     al, bl
    mov     si, offset k_st
    call    o2_kx
    call    out_nl
    inc     di
    cmp     di, 40
    jb      1b
    mov     si, offset tg_adbe
    call    o2_x
    mov     al, 4
    call    o2_in
    mov     si, offset k_st
    call    o2_kx
    mov     al, 6
    call    o2_in
    mov     si, offset k_s6
    call    o2_kx
    call    out_nl
    /* 8 timed flag resets */
    xor     di, di
4:  call    wd_check
    cli
    call    o2_xfr
    sti
    mov     si, offset tg_fradb
    call    o2_x
    push    eax
    movzx   eax, di
    mov     si, offset k_i
    call    out_kd
    pop     eax
    call    o2_xpr
    call    out_nl
    inc     di
    cmp     di, 8
    jb      4b
    cli
    mov     ax, 0x0100
    call    o2_putx
    mov     ax, 0x0000
    call    o2_putx
    sti
    ret

/* ---------------------------------------------------------------- the section */
sec_opna2:
    mov     si, offset nm_opna2
    mov     eax, WD_20S
    mov     bx, offset o2_exit
    call    sec_begin
    mov     byte ptr [o2_ran], 0
    mov     word ptr [tag_sfx], 0
    call    opna_drvchk
    jnc     1f
    mov     si, offset rs_tsr
    call    skip_line
    mov     si, offset k_I
    call    info_start
    PS      "vec60="
    mov     eax, dword ptr [op_v60]
    call    out_x8
    call    out_nl
    jmp     o2_end
1:  mov     dx, 0xA460
    in      al, dx
    mov     byte ptr [o2_a460], al
    in      al, 0x0A
    mov     byte ptr [o2_imrs], al
    mov     dword ptr [o2_sts], 0xFFFFFFFF
    mov     si, offset k_STATE
    call    info_start
    PS      "a460="
    mov     al, byte ptr [o2_a460]
    call    out_x2
    PS      " imr_s="
    mov     al, byte ptr [o2_imrs]
    call    out_x2
    PS      " imr_m="
    in      al, 0x02
    call    out_x2
    PS      " vec60="
    mov     eax, dword ptr [op_v60]
    call    out_x8
    PS      " builtin=see-run-notes"
    call    out_nl
    mov     byte ptr [o2_ran], 1
    mov     word ptr [o2_to], 0
    cli
    mov     al, byte ptr [o2_imrs]
    or      al, 0x10                    /* IRQ12 (slave IR4) masked for the section */
    out     0x0A, al
    sti
    /* 1. identity on every base */
    xor     bx, bx
2:  mov     word ptr [o2_bi], bx
    shl     bx, 1
    mov     ax, word ptr [o2_bases + bx]
    mov     word ptr [o2_base], ax
    call    o2_ident
    mov     bx, word ptr [o2_bi]
    test    bx, bx
    jz      3f
    cmp     byte ptr [o2_sts + bx], 0xFF
    je      3f
    shl     bx, 1
    mov     ax, word ptr [o2_sfx + bx]
    mov     word ptr [tag_sfx], ax
    mov     si, offset o2_fm30
    mov     cx, 16
    call    o2_busy
    mov     si, offset o2_tm1
    mov     cx, 4
    call    o2_tmr
    mov     word ptr [tag_sfx], 0
3:  mov     bx, word ptr [o2_bi]
    inc     bx
    cmp     bx, 3
    jb      2b
    mov     word ptr [o2_base], 0x188
    cmp     byte ptr [o2_sts], 0xFF
    jne     4f
    mov     si, offset rs_absent
    call    skip_line
    jmp     o2_exit
4:  /* 2-5 on 0x188 with the extension open */
    mov     al, byte ptr [o2_a460]
    or      al, 1
    call    o2_a460w
    mov     si, offset o2_cls
5:  cmp     word ptr [si], 0
    je      6f
    mov     cx, O2_N
    call    o2_busy
    add     si, 6
    jmp     5b
6:  call    o2_b2b
    mov     si, offset tg_fra
    mov     dl, 0
    call    o2_frl
    mov     si, offset tg_frb
    mov     dl, 1
    call    o2_frl
    mov     si, offset o2_tms
7:  cmp     word ptr [si], 0
    je      8f
    mov     cx, 8
    call    o2_tmr
    add     si, 6
    jmp     7b
8:  call    o2_adpcmb
    cmp     word ptr [o2_to], 0
    je      o2_exit
    mov     si, offset to_o2
    call    timeout_line
o2_exit:
    call    sec_disarm
    mov     word ptr [tag_sfx], 0
    cmp     byte ptr [o2_ran], 0
    je      o2_end
    cli
    /* every base that answered: timers stopped, loads and the scratch registers cleared */
    xor     bx, bx
9:  cmp     byte ptr [o2_sts + bx], 0xFF
    je      10f
    push    bx
    shl     bx, 1
    mov     ax, word ptr [o2_bases + bx]
    mov     word ptr [o2_base], ax
    mov     si, offset o2_rs_all
    call    o2_putlist
    pop     bx
10: inc     bx
    cmp     bx, 3
    jb      9b
    mov     word ptr [o2_base], 0x188
    cmp     byte ptr [o2_sts], 0xFF
    je      11f
    mov     si, offset o2_rs_188
    call    o2_putlist
    mov     al, byte ptr [o2_a460]
    or      al, 1
    call    o2_a460w
    mov     si, offset o2_rs_ext
    call    o2_putlistx
11: mov     al, 0x0B                    /* the slave PIC's read register: ISR (IRQWD's end state) */
    out     0x08, al
    sti
    mov     al, byte ptr [o2_a460]
    call    o2_a460w
    mov     dx, 0xA460
    mov     si, offset n_a460
    call    rs_port8
    cli
    mov     al, byte ptr [o2_imrs]
    out     0x0A, al
    sti
    mov     dx, 0x0A
    mov     si, offset n_imrs2
    call    rs_port8
    mov     si, offset n_opna2r
    xor     eax, eax
    call    rs_default
o2_end:
    call    sec_end
    ret

/* o2_putlist / o2_putlistx: SI = a word list of (data << 8 | register), 0xFFFF ends it */
o2_putlist:
1:  lodsw
    cmp     ax, 0xFFFF
    je      2f
    call    o2_put
    jmp     1b
2:  ret
o2_putlistx:
1:  lodsw
    cmp     ax, 0xFFFF
    je      2f
    call    o2_putx
    jmp     1b
2:  ret
o2_rs_all:  .word 0x3027, 0x0024, 0x0025, 0x0026, 0x000B, 0x000C, 0x0030, 0xFFFF
o2_rs_188:  .word 0x0028, 0x0128, 0x0228, 0x0428, 0x0528, 0x0628, 0xBF10, 0x0011
            .word 0x7F40, 0x00A0, 0x00B0, 0x0008, 0xFFFF
o2_rs_ext:  .word 0x0100, 0x0000, 0x8010, 0x1C10, 0x0030, 0xFFFF

    VARS
    .p2align 2
o2_t0:      .long 0
o2_sts:     .byte 0xFF, 0xFF, 0xFF, 0xFF
o2_v:       .space 16
o2_hp:      .space 18                   /* 9 poll bins */
o2_ht:      .space 32                   /* 16 pit bins (contiguous with o2_hp: cleared together) */
o2_base:    .word 0x188
o2_bi:      .word 0
o2_n:       .word 0
o2_reg:     .word 0
o2_tg:      .word 0
o2_to:      .word 0
o2_a460:    .byte 0
o2_imrs:    .byte 0
o2_mode:    .byte 0
o2_msk:     .byte 0
o2_ctl:     .byte 0
o2_ran:     .byte 0
    ENDVARS

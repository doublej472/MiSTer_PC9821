/* sec_opna3.inc - /OPNA3 (opt-in, outside /ALL): the YM2608's rhythm registers written back to
 * back, the way MDRV2 writes them.
 *
 * WHY. Touhou 1's music driver (MDRV2 3.4F) sets the six rhythm instrument levels at song
 * start back to back, each write behind one BUSY poll: poll 0x188 bit 7, select, data, next
 * (`0x11=36, 0x18=DF, 0x19=DE, 0x1A=DF, 0x1B=DA, 0x1C=DF, 0x1D=DD`, logged from MDRV98.COM
 * running REIMU.MDT under an x86 emulator). On the YM2608 die the rhythm levels go through
 * ONE pending data word that the rhythm unit takes when its slot comes round (YM2608-LLE
 * `rss_18`); the vendored jt12 model keeps one pending level word the same way (jt12_mmr
 * `lracl`/`up_lracl`, applied when jt08_adpcm_gain's ring reaches the drum), so a write that
 * lands before the previous one was taken overwrites it. NP2kai (sound/rhythmc.c
 * rhythm_setreg applies every 0x18-0x1D write at once) and ymfm (adpcm_a_engine::write stores
 * every register) keep every write. Which the real chip does depends on how long it holds
 * BUSY after a level write; /OPNA2 measured BUSY only after FM/SSG/rhythm 0x10/0x11 writes,
 * one write at a time. This section records, raw, BUSY after each of MDRV2's back-to-back
 * level writes, and (with /LISTEN only) plays the bass drum so an ear can tell whether the
 * first of six back-to-back level writes survived. Nothing is interpreted on the machine.
 *
 * Every row runs on 0x188 with the 86 board's extension open (0xA460 bit 0 set; NP2kai
 * cbus/board86.c extendchannel dumps the rhythm `rhythm_setreg(..., 0x10, 0xff)` when it is
 * closed), the rhythm dumped (0x10 <- BF) and the rhythm total level 0x11 <- 00 first.
 *
 * 1. BUSY_RHY18 (128 trials): one level write 0x18 <- 00 (pan off: silent) at the swept
 *    phase delay (i * 37) mod 128 `out 5Fh`, exactly as /OPNA2's BUSY_RHY10: a T row, a
 *    histogram (i=H) and the first 32 raw trials (sec_opna2.inc o2_busy).
 * 2. B2B_RHYLVL (32 trials): MDRV2's six level writes 0x18..0x1D <- DF DE DF DA DF DD back to
 *    back: one BUSY poll before the first select, then per write select, data, and the status
 *    polled until bit 7 clears (that poll is the next write's BUSY poll, as in MDRV2). Each
 *    trial starts after (i * 37) mod 128 `out 5Fh`. Per write: the polls of the wait after the
 *    data write, its PIT time (stamped between the select and the data write, as /OPNA2) and
 *    `dd`, the PIT time from the previous data write's stamp (the write spacing). Level writes
 *    with no key-on make no sound. Raw rows for every trial, one histogram per write position
 *    (w=0..5) and one over all writes (w=all), a T row over all writes.
 * 3. B2B_RHYKEY (32 trials): the same with six key writes 0x10 <- BF 01 BF 08 BF 3F (dump/key
 *    pairs) after the six levels are set to 00 (pan off, written one at a time): keyed drums
 *    are routed to neither output, so they are silent.
 * 4. /LISTEN only (audible, about 14 s): 0x11 <- 36 (MDRV2's REIMU value), then three phases,
 *    each labelled on the screen, each keying the bass drum alone (0x10 <- 01, 200 ms, dump
 *    0x10 <- 81, 50 ms) 8 times, starting 50 ms after its level writes (so a level word still
 *    pending at the last write has been taken by the first key), with a 2 s pause after it:
 *      PHASE 1 SLOW     0x18 <- DF (L+R, level 1F), 0x19..0x1D <- C0 (L+R, level 0), each
 *                       write followed by a 200 us wait;
 *      PHASE 2 B2B      all six <- C0 slowly first (a lost write leaves the bass drum at level
 *                       0, about 23 dB quieter), then 0x18 <- DF, 0x19..0x1D <- C0 back to back
 *                       (BUSY polls only);
 *      PHASE 3 B2B-REV  all six <- C0 slowly, then 0x1D..0x19 <- C0 back to back and
 *                       0x18 <- DF LAST.
 *    A row per phase logs the polls and PIT times of its level writes. If phase 2 is as loud
 *    as phase 1, the chip keeps every back-to-back level write; if phase 2 is quiet and phase
 *    3 loud, it holds one pending level word as jt12 does.
 * 5. /SWEEP only (instead of 1-4; audible, about 45 s for all 20 steps): 0x11 <- 36, then per
 *    step 0x18 <- DF, a set gap, 0x19 <- C0, and 4 bass-drum hits; the screen names each step
 *    and its measured gap before its hits, and the ear finds the shortest gap at which the
 *    0x18 write survives (o3_sweep below has the method). /STEP n and /TO n pick the steps.
 *
 * RESTORE: the rhythm dumped (0x10 <- BF), its total level 0x11 <- 00 (/OPNA2's silent value),
 * the six levels 0x18-0x1D <- DF (write-only; ymfm adpcm_a_registers::reset "initialize the
 * pans to on by default, and max instrument volume" `= 0xdf`), 0xA460 from its read-back.
 * Nothing else is written: no timer, no 0x27, no 0x29, no IMR.
 */
    .equ O3_POLL,  SECBUF               /* 192 dwords: polls per write */
    .equ O3_PIT,   SECBUF + 0x300       /* 192 dwords: PIT counts of the wait after the data */
    .equ O3_DD,    SECBUF + 0x600       /* 192 words: PIT counts since the previous data write */
    .equ O3_N,     32                   /* back-to-back trials */
    .equ O3_W,     6                    /* writes per trial */
    .equ O3_T200US, 63                  /* ARTIC ticks >= 200 us (61.44 ticks) */
/* O3_SD5F: `out 5Fh` between every register select and its data write. The YM2608 takes a
 * select through a two-phase synchronizer on its internal clock (YM2608-LLE fmopna_impl.c
 * `write0_en`, 1-2 clocks of 0.75 us) and latches the address from the last byte on its bus
 * input: a data write that arrives first becomes the address. Yamaha's wait after an address
 * write is 17 master clocks (2.1 us). One I/O access (0.84 us on the Xe10, XE10T-XE10.TXT
 * W8_0188) is too short; one posted `out 5Fh` makes the next access wait 1744 ns after it
 * (XE10T-XE10.TXT /IO W8_005F), so the data follows its select by about 2.6 us. MDRV2 3.4F
 * waits 28 `out 5Fh` there. Binaries before this constant (no `sd5f=` on the STATE line)
 * wrote the SWEEP pair's data one access after its select, and lost the select. */
    .equ O3_SD5F,  1

tc_opna3:   .asciz "OPNA 0x188/0x18A rhythm 10 11 18-1D (silent values; /LISTEN: bass drum keyed 24 times, 0x11=36; /SWEEP: 4 per step), 0xA460 bit 0, 0x5F (gap)"
n_opna3r:   .asciz "OPNA3_REGS"
to_o3:      .asciz "opna3_poll"
tg_b2brl:   .asciz "B2B_RHYLVL"
tg_b2brk:   .asciz "B2B_RHYKEY"
tg_lslow:   .asciz "LISTEN_SLOW"
tg_lb2b:    .asciz "LISTEN_B2B"
tg_lrev:    .asciz "LISTEN_B2B_REV"
k_w:        .asciz "w"
k_reg:      .asciz "reg"
k_dd:       .asciz "dd"
k_pre:      .asciz "pre_polls"
k_regs:     .asciz "regs"
k_slow:     .asciz "slow"
k_keys:     .asciz "keys"
k_writes:   .asciz "writes"
con_lhead:  .asciz "\r\nOPNA3 LISTEN: three phases of 8 bass-drum hits. Compare phase 2 with phase 1.\r\n"
con_l1:     .asciz "PHASE 1 SLOW (levels written 200 us apart)\r\n"
con_l2:     .asciz "PHASE 2 B2B (levels back to back, bass drum first)\r\n"
con_l3:     .asciz "PHASE 3 B2B-REV (levels back to back, bass drum last)\r\n"

o3_rhy18:
    O2C "BUSY_RHY18",  0x18, 0x00, 1

/* write lists: six words (data << 8 | register) */
o3_mdrv:    .word 0xDF18, 0xDE19, 0xDF1A, 0xDA1B, 0xDF1C, 0xDD1D   /* MDRV2 / REIMU.MDT */
o3_off:     .word 0x0018, 0x0019, 0x001A, 0x001B, 0x001C, 0x001D   /* pan off */
o3_keyl:    .word 0xBF10, 0x0110, 0xBF10, 0x0810, 0xBF10, 0x3F10   /* dump/key pairs */
o3_c0:      .word 0xC018, 0xC019, 0xC01A, 0xC01B, 0xC01C, 0xC01D   /* L+R, level 0 */
o3_fwd:     .word 0xDF18, 0xC019, 0xC01A, 0xC01B, 0xC01C, 0xC01D   /* bass drum first */
o3_rev:     .word 0xC01D, 0xC01C, 0xC01B, 0xC01A, 0xC019, 0xDF18   /* bass drum last */
o3_rs:      .word 0xBF10, 0x0011, 0xDF18, 0xDF19, 0xDF1A, 0xDF1B, 0xDF1C, 0xDF1D, 0xFFFF

/* ---------------------------------------------------------------- helpers */
/* o3_spin: EAX = ARTIC ticks to wait (the watchdog checked on every pass). */
o3_spin:
    push    eax
    push    ebx
    push    ecx
    mov     ecx, eax
    call    artic_read
    mov     ebx, eax
1:  call    wd_check
    mov     eax, ebx
    call    artic_since
    cmp     eax, ecx
    jb      1b
    pop     ecx
    pop     ebx
    pop     eax
    ret

/* o3_burst: SI = six-word write list, DI = first array index, CX = phase-delay `out 5Fh`
 * count, [o3_slow] = 1 for a 200 us wait after each write's BUSY wait. MDRV2's sequence:
 * one BUSY poll, then per write select, O3_SD5F `out 5Fh`, data, and the status polled until
 * bit 7 clears.
 * Per write k (index DI + k): O3_POLL = the polls, O3_PIT = PIT counts from the stamp
 * before the data write to the clear read, O3_DD = PIT counts from the previous write's
 * stamp (0 for the first). Interrupts off for the burst. All registers kept. */
o3_burst:
    pushad
    pushf
    cli
    call    o2_wait
    jcxz    2f
1:  out     0x5F, al                    /* the phase delay */
    loop    1b
2:  mov     dx, word ptr [o2_base]
    mov     bp, O3_W                    /* writes left; O3_W = the first write */
3:  lodsw                               /* AL = register, AH = data */
    out     dx, al                      /* the select */
    mov     bl, ah
    mov     cx, O3_SD5F
11: out     0x5F, al                    /* select-to-data spacing (O3_SD5F) */
    loop    11b
    call    pit_read
    mov     word ptr [o3_t0], ax
    add     dx, 2
    mov     al, bl
    out     dx, al                      /* the data write */
    sub     dx, 2
    xor     cx, cx
4:  in      al, dx
    inc     cx
    test    al, 0x80
    jz      5f
    cmp     cx, 0xFFFF
    jb      4b
    inc     word ptr [o2_to]
5:  call    pit_read
    push    dx
    movzx   edx, ax
    movzx   eax, word ptr [o3_t0]
    call    pit_sub
    mov     bx, di
    shl     bx, 2
    mov     dword ptr [O3_PIT + bx], eax
    movzx   eax, cx
    mov     dword ptr [O3_POLL + bx], eax
    xor     eax, eax
    cmp     bp, O3_W
    je      6f                          /* the first write: no previous stamp */
    movzx   edx, word ptr [o3_t0]
    movzx   eax, word ptr [o3_prev]
    call    pit_sub
6:  mov     bx, di
    shl     bx, 1
    mov     word ptr [O3_DD + bx], ax
    mov     ax, word ptr [o3_t0]
    mov     word ptr [o3_prev], ax
    pop     dx
    cmp     byte ptr [o3_slow], 0
    je      7f
    mov     eax, O3_T200US
    call    o3_spin
7:  inc     di
    dec     bp
    jnz     3b
    popf
    popad
    ret

/* o3_six: SI = key, BX = array (dwords, or words when [o3_wd] = 1), DI = first index:
 * " key=a,b,c,d,e,f" */
o3_six:
    pushad
    call    out_sp
    call    out_s
    mov     al, '='
    call    out_c
    mov     cx, O3_W
1:  mov     si, di
    cmp     byte ptr [o3_wd], 0
    jne     2f
    shl     si, 2
    mov     eax, dword ptr [bx + si]
    jmp     3f
2:  shl     si, 1
    movzx   eax, word ptr [bx + si]
3:  call    out_d
    inc     di
    dec     cx
    jz      4f
    mov     al, ','
    call    out_c
    jmp     1b
4:  popad
    ret

/* o3_regs: SI = write list -> " regs=18,19,..." (the registers in write order) */
o3_regs:
    pushad
    PS      " regs="
    mov     cx, O3_W
1:  lodsw
    call    out_x2
    dec     cx
    jz      2f
    mov     al, ','
    call    out_c
    jmp     1b
2:  popad
    ret

/* o3_hist: DI = first index, CX = count, BP = index step: fills o2_hp/o2_ht from O3_POLL
 * and O3_PIT with /OPNA2's bins (polls 1, 2, 3, 4, 5-8, 9-16, 17-32, 33-64, 65+; PIT 8
 * counts wide, 16 bins, the last 120+) and prints " polls_h=... pit_h=...". */
o3_hist:
    pushad
    push    di
    push    cx
    mov     di, offset o2_hp
    mov     cx, 25
    xor     ax, ax
    push    es
    push    cs
    pop     es
    rep     stosw
    pop     es
    pop     cx
    pop     di
1:  mov     bx, di
    shl     bx, 2
    mov     eax, dword ptr [O3_POLL + bx]
    xor     bx, bx
    cmp     eax, 4
    ja      2f
    mov     bx, ax
    dec     bx                          /* 1..4 -> bins 0..3 */
    jmp     4f
2:  mov     bx, 4
    mov     edx, 8
3:  cmp     eax, edx
    jbe     4f
    inc     bx
    shl     edx, 1
    cmp     bx, 8
    jb      3b
4:  shl     bx, 1
    inc     word ptr [o2_hp + bx]
    mov     bx, di
    shl     bx, 2
    mov     eax, dword ptr [O3_PIT + bx]
    shr     eax, 3
    cmp     eax, 15
    jbe     5f
    mov     eax, 15
5:  mov     bx, ax
    shl     bx, 1
    inc     word ptr [o2_ht + bx]
    add     di, bp
    dec     cx
    jnz     1b
    PS      " polls_h="
    mov     si, offset o2_hp
    mov     cx, 9
    call    o2_hlist
    PS      " pit_h="
    mov     si, offset o2_ht
    mov     cx, 16
    call    o2_hlist
    popad
    ret

/* ---------------------------------------------------------------- back to back */
/* o3_b2b: SI = write list, BX = tag. O3_N trials, then the rows. */
o3_b2b:
    pushad
    mov     word ptr [o2_tg], bx
    mov     word ptr [o3_lst], si
    push    si
    mov     si, bx
    mov     ax, word ptr [o2_base]
    call    row_mark
    pop     si
    mov     byte ptr [o3_slow], 0
    xor     bx, bx                      /* trial */
1:  call    wd_check
    mov     cx, bx
    imul    cx, cx, 37
    and     cx, 127
    mov     di, bx
    imul    di, di, O3_W
    mov     si, word ptr [o3_lst]
    call    o3_burst
    inc     bx
    cmp     bx, O3_N
    jb      1b
    /* raw rows: every trial */
    xor     bx, bx
2:  mov     si, word ptr [o2_tg]
    call    o2_x
    movzx   eax, bx
    mov     si, offset k_i
    call    out_kd
    mov     ax, bx
    imul    ax, ax, 37
    and     ax, 127
    movzx   eax, ax
    mov     si, offset k_dly
    call    out_kd
    mov     di, bx
    imul    di, di, O3_W
    push    bx
    mov     byte ptr [o3_wd], 0
    mov     si, offset k_polls
    mov     bx, O3_POLL
    call    o3_six
    mov     si, offset k_pit
    mov     bx, O3_PIT
    call    o3_six
    mov     byte ptr [o3_wd], 1
    mov     si, offset k_dd
    mov     bx, O3_DD
    call    o3_six
    mov     byte ptr [o3_wd], 0
    pop     bx
    call    out_nl
    inc     bx
    cmp     bx, O3_N
    jb      2b
    /* a histogram per write position, then over every write */
    xor     bx, bx
3:  mov     si, word ptr [o2_tg]
    call    o2_x
    PS      " i=H"
    movzx   eax, bx
    mov     si, offset k_w
    call    out_kd
    push    bx
    mov     di, bx
    shl     di, 1
    mov     bx, word ptr [o3_lst]
    mov     al, byte ptr [bx + di]      /* the position's register */
    pop     bx
    mov     si, offset k_reg
    call    o2_kx
    mov     di, bx
    mov     cx, O3_N
    mov     bp, O3_W
    call    o3_hist
    call    out_nl
    inc     bx
    cmp     bx, O3_W
    jb      3b
    mov     si, word ptr [o2_tg]
    call    o2_x
    PS      " i=H w=all"
    xor     di, di
    mov     cx, O3_N * O3_W
    mov     bp, 1
    call    o3_hist
    call    out_nl
    /* the T row over every write (sorts the arrays: last) */
    mov     si, offset k_T
    call    row_start
    mov     si, word ptr [o2_tg]
    call    o2_tag
    mov     eax, O3_N
    mov     si, offset k_trials
    call    out_kd
    mov     eax, O3_N * O3_W
    mov     si, offset k_writes
    call    out_kd
    mov     cx, O3_N * O3_W
    mov     bx, O3_PIT
    mov     si, offset f_busy
    call    o2_mmm
    mov     bx, O3_POLL
    mov     si, offset f_polls
    call    o2_mmm
    call    out_nl
    popad
    ret

/* ---------------------------------------------------------------- /LISTEN */
/* o3_phase: SI = the phase's level list, BX = tag, DX = console label, AL = 1 for the slow
 * phase (no back-to-back burst). Prints the label, writes the levels, logs a row, waits
 * 50 ms, keys the bass drum 8 times (key 200 ms, dump 50 ms), then pauses 2 s. */
o3_phase:
    pushad
    push    si
    mov     si, dx
    call    con_s
    mov     si, bx
    mov     word ptr [o2_tg], bx
    push    ax
    mov     ax, word ptr [o2_base]
    call    row_mark
    pop     ax
    pop     si
    xor     cx, cx
    cmp     al, 0
    jne     1f
    /* the six levels to C0 one at a time, then the list back to back */
    push    si
    mov     byte ptr [o3_slow], 1
    mov     si, offset o3_c0
    mov     di, O3_W
    call    o3_burst
    pop     si
    mov     byte ptr [o3_slow], 0
    xor     di, di
    call    o3_burst
    jmp     2f
1:  mov     byte ptr [o3_slow], 1
    xor     di, di
    call    o3_burst
2:  mov     byte ptr [o3_slow], 0
    push    ax
    push    si
    mov     si, word ptr [o2_tg]
    call    o2_x
    pop     si
    call    o3_regs
    pop     ax
    push    ax
    movzx   eax, al
    mov     si, offset k_slow
    call    out_kd
    xor     di, di
    mov     si, offset k_polls
    mov     bx, O3_POLL
    call    o3_six
    mov     si, offset k_pit
    mov     bx, O3_PIT
    call    o3_six
    mov     byte ptr [o3_wd], 1
    mov     si, offset k_dd
    mov     bx, O3_DD
    call    o3_six
    mov     byte ptr [o3_wd], 0
    pop     ax
    cmp     al, 0
    jne     3f
    mov     di, O3_W
    mov     si, offset k_pre
    mov     bx, O3_POLL
    call    o3_six
3:  mov     eax, 8
    mov     si, offset k_keys
    call    out_kd
    call    out_nl
    call    out_flush
    mov     eax, T_10MS * 5             /* every level write taken before the first key */
    call    o3_spin
    mov     cx, 8
4:  mov     ax, 0x0110                  /* key the bass drum */
    call    o2_put
    mov     eax, T_100MS * 2
    call    o3_spin
    mov     ax, 0x8110                  /* dump it */
    call    o2_put
    mov     eax, T_10MS * 5
    call    o3_spin
    loop    4b
    mov     eax, T_1S * 2
    call    o3_spin
    popad
    ret

/* ---------------------------------------------------------------- /SWEEP */
/* The gap sweep. The /LISTEN capture on the Xe10 (OPNA3L.TXT: PHASE 1 loud, PHASE 2 quiet,
 * PHASE 3 loud) says the first of two level writes is lost when the next follows about
 * 24 PIT counts (9.8 us) later. Each step writes 0x18 <- DF and, a set gap later, 0x19 <- C0,
 * then keys the bass drum 4 times; the ear finds the first gap at which the drum is loud.
 *
 * The gap is the time from the 0x18 data write to the 0x19 data write. Each data write is
 * followed by the same two instructions, `mov al, 0` and `out 77h` (latch PIT ch0), so the two
 * latched counts are exactly one gap apart (to one PIT count). The gap itself holds the first
 * latch's two reads, N `out 5Fh`, the BUSY poll, the 0x19 select and its O3_SD5F `out 5Fh`
 * (the select-to-data spacing): no timer is read inside
 * it but the latched one, so the smallest gap is the N = 0 path. N is found per step by
 * measuring: every attempt first sets all six levels to C0 200 us apart (a lost 0x18 write
 * then leaves the drum at level 0, not at an earlier value), runs the pair, and the step
 * keeps the fewest N whose measured gap reaches the target (an attempt short of it is
 * repeated with more `out 5Fh`, so the target is a minimum). Level writes make no sound
 * without a key, so the attempts are silent; the last attempt's writes are the ones heard.
 * An attempt whose BUSY poll before the 0x19 select read BUSY was lengthened by the chip:
 * it is repeated with the same N, and after four such the step keeps it (fit=2). */
    .equ O3_SW,    SECBUF + 0x100       /* per step: gap us, gap PIT, tries, fit, ran */
    .equ O3_LN,    SECBUF + 0x200       /* the console line being built (<= 160 bytes) */
    .equ O3_NMAX,  4000                 /* the most `out 5Fh` in one gap */
    .equ O3_TRY,   32                   /* attempts per step */
    .equ O3_TOL,   2                    /* PIT counts an accepted gap may pass its target by */
    .equ O3_NSTEP, 20

/* the targets in us; 0 = the smallest gap the program makes (N = 0) */
o3_gaps:    .word 0, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 27, 30, 35, 40, 50, 60, 80, 100
tg_sweep:   .asciz "SWEEP"
k_step:     .asciz "step"
k_gapus:    .asciz "gap_us"
k_tgt:      .asciz "tgt"
k_n5f:      .asciz "n5f"
k_tries:    .asciz "tries"
k_btries:   .asciz "busy_tries"
k_fit:      .asciz "fit"
k_p18:      .asciz "p18"
k_p19:      .asciz "p19"
k_pa:       .asciz "pa"
k_papit:    .asciz "pa_pit"
k_from:     .asciz "from"
k_rt:       .asciz "ratio_x1000"
con_shead:  .ascii "\033[2J\r\nOPNA3 SWEEP: per step 0x18 <- DF (bass drum, level 1F), the gap, 0x19 <- C0,\r\n"
            .ascii "then 4 bass-drum hits. A lost 0x18 write leaves the drum QUIET (level 0).\r\n\r\n"
            .asciz "\033[7m  Listen for the step where the drum turns LOUD  \033[0m\r\n"
s_step:     .asciz "STEP "
s_gap:      .asciz "  GAP "
s_min:      .asciz "MIN   "
s_us:       .asciz " us"
s_act:      .asciz " (actual "
s_actc:     .asciz " us)"
s_busy:     .asciz " BUSY"
s_nofit:    .asciz " NO-FIT"
s_inv:      .asciz "\r\n\033[7m "
s_norm:     .asciz " \033[0m\r\n"
s_pit:      .asciz "  pit "
s_try:      .asciz " try "
s_crlf:     .asciz "\r\n"
s_shead:    .asciz "\r\nOPNA3 SWEEP done (gap = 0x18 data write to 0x19 data write). Which STEP turned LOUD?\r\n"

/* o3_bs: SI = asciz appended at [DI] (no NUL); DI advanced */
o3_bs:
    push    ax
    push    si
1:  lodsb
    test    al, al
    jz      2f
    mov     byte ptr [di], al
    inc     di
    jmp     1b
2:  pop     si
    pop     ax
    ret

/* o3_bd: EAX decimal appended at [DI], at least CL characters (padded with CH); DI advanced */
o3_bd:
    push    eax
    push    ebx
    push    cx
    push    edx
    push    si
    mov     ebx, 10
    xor     si, si
1:  xor     edx, edx
    div     ebx
    push    dx
    inc     si
    test    eax, eax
    jnz     1b
2:  movzx   ax, cl
    cmp     ax, si
    jbe     3f
    mov     byte ptr [di], ch
    inc     di
    dec     cl
    jmp     2b
3:  pop     dx
    add     dl, '0'
    mov     byte ptr [di], dl
    inc     di
    dec     si
    jnz     3b
    pop     si
    pop     edx
    pop     cx
    pop     ebx
    pop     eax
    ret

/* o3_x10: EAX = PIT counts -> EAX = us x 10, rounded ([o3_rt] = PIT/ARTIC ratio x 1000, the
 * ARTIC being 307200 Hz: us = counts * 10^7 / (ratio_x1000 * 3072)) */
o3_x10:
    push    ecx
    push    edx
    mov     ecx, 100000000
    mul     ecx
    mov     ecx, dword ptr [o3_rt]
    imul    ecx, ecx, 3072
    push    ecx
    shr     ecx, 1
    add     eax, ecx
    adc     edx, 0
    pop     ecx
    div     ecx
    pop     edx
    pop     ecx
    ret

/* o3_fmt: AX = step (1-based), BX = its O3_SW record, DI = buffer:
 * "STEP 07  GAP  16 us (actual  16.3 us)" [" BUSY" | " NO-FIT"]; DI advanced */
o3_fmt:
    push    eax
    push    cx
    push    edx
    push    si
    mov     si, offset s_step
    call    o3_bs
    movzx   eax, ax
    mov     cx, 0x3002                  /* two digits, zero padded */
    call    o3_bd
    mov     si, offset s_gap
    call    o3_bs
    movzx   eax, word ptr [bx]
    test    eax, eax
    jnz     1f
    mov     si, offset s_min
    call    o3_bs
    jmp     2f
1:  mov     cx, 0x2003
    call    o3_bd
    mov     si, offset s_us
    call    o3_bs
2:  mov     si, offset s_act
    call    o3_bs
    movzx   eax, word ptr [bx+2]
    call    o3_x10
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    mov     cx, 0x2003
    call    o3_bd
    mov     byte ptr [di], '.'
    inc     di
    add     dl, '0'
    mov     byte ptr [di], dl
    inc     di
    mov     si, offset s_actc
    call    o3_bs
    cmp     byte ptr [bx+6], 1
    je      4f
    mov     si, offset s_busy
    cmp     byte ptr [bx+6], 2
    je      3f
    mov     si, offset s_nofit
3:  call    o3_bs
4:  pop     si
    pop     edx
    pop     cx
    pop     eax
    ret

/* o3_preset: the six levels <- C0 (L+R, level 0), each write then 200 us */
o3_preset:
    pushad
    mov     si, offset o3_c0
    xor     di, di
    xor     cx, cx
    mov     byte ptr [o3_slow], 1
    call    o3_burst
    mov     byte ptr [o3_slow], 0
    popad
    ret

/* o3_pair: BX = N. Poll, select 0x18, O3_SD5F `out 5Fh`, DATA 0x18 <- DF, latch (L0), read
 * L0, N `out 5Fh`, poll, select 0x19, O3_SD5F `out 5Fh`, DATA 0x19 <- C0, latch (L1), read L1,
 * poll until BUSY clears, PIT.
 * Out: [o3_a] = L0 - L1 (the data-to-data gap, PIT counts), [o3_p18] [o3_p19] = the polls
 * before each select, [o3_pa] = the polls after the 0x19 data write, [o3_tpa] = PIT counts
 * from L1 to the read that saw BUSY clear. Interrupts off. All registers kept. */
o3_pair:
    pushad
    pushf
    cli
    mov     dx, word ptr [o2_base]
    xor     cx, cx
1:  in      al, dx
    inc     cx
    test    al, 0x80
    jz      2f
    cmp     cx, 0xFFFF
    jb      1b
    inc     word ptr [o2_to]
2:  mov     word ptr [o3_p18], cx
    mov     al, 0x18
    out     dx, al                      /* select 0x18 */
    mov     di, O3_SD5F
12: out     0x5F, al                    /* select-to-data spacing (O3_SD5F) */
    dec     di
    jnz     12b
    add     dx, 2
    mov     al, 0xDF
    out     dx, al                      /* DATA 0x18 <- DF */
    mov     al, 0x00
    out     0x77, al                    /* L0: latch PIT ch0 */
    in      al, 0x71
    mov     cl, al
    in      al, 0x71
    mov     ch, al
    sub     dx, 2
    mov     si, bx
    test    si, si
    jz      4f
3:  out     0x5F, al                    /* the gap */
    dec     si
    jnz     3b
4:  xor     di, di
5:  in      al, dx                      /* BUSY before the 0x19 select */
    inc     di
    test    al, 0x80
    jz      6f
    cmp     di, 0xFFFF
    jb      5b
    inc     word ptr [o2_to]
6:  mov     al, 0x19
    out     dx, al                      /* select 0x19 */
    mov     si, O3_SD5F
13: out     0x5F, al                    /* select-to-data spacing (O3_SD5F) */
    dec     si
    jnz     13b
    add     dx, 2
    mov     al, 0xC0
    out     dx, al                      /* DATA 0x19 <- C0 */
    mov     al, 0x00
    out     0x77, al                    /* L1: the same two instructions after the data */
    in      al, 0x71
    mov     bl, al
    in      al, 0x71
    mov     bh, al
    sub     dx, 2
    xor     si, si
7:  in      al, dx                      /* BUSY after the 0x19 data write */
    inc     si
    test    al, 0x80
    jz      8f
    cmp     si, 0xFFFF
    jb      7b
    inc     word ptr [o2_to]
8:  call    pit_read                    /* the byte order pit_cal measured */
    cmp     byte ptr [pit_swap], 0
    je      9f
    xchg    cl, ch
    xchg    bl, bh
9:  mov     word ptr [o3_p19], di
    mov     word ptr [o3_pa], si
    movzx   edx, ax
    movzx   eax, bx
    call    pit_sub                     /* L1 - the clear read */
    mov     word ptr [o3_tpa], ax
    movzx   eax, cx
    movzx   edx, bx
    call    pit_sub                     /* L0 - L1 (PIT ch0 counts down) */
    mov     word ptr [o3_a], ax
    popf
    popad
    ret

/* o3_fit: [o3_tgt] = target PIT counts, [o3_nn] = the first N to try. Attempts (preset,
 * pair) until the fewest N whose gap reaches the target is found: [o3_fitv] = 1 found,
 * 2 kept after four BUSY-lengthened attempts, 0 out of attempts (the last one stands).
 * [o3_nn] = the last attempt's N, [o3_try] / [o3_btry] = attempts / BUSY-lengthened ones. */
o3_fit:
    pushad
    mov     word ptr [o3_lo], -1        /* the largest N seen short of the target */
    mov     word ptr [o3_hi], O3_NMAX + 1   /* the smallest N seen reaching it */
    mov     word ptr [o3_try], 0
    mov     word ptr [o3_btry], 0
    mov     byte ptr [o3_fitv], 0
1:  call    wd_check
    inc     word ptr [o3_try]
    call    o3_preset
    mov     bx, word ptr [o3_nn]
    call    o3_pair
    mov     ax, word ptr [o3_a]
    cmp     ax, word ptr [o3_tgt]
    jb      3f
    cmp     word ptr [o3_p19], 1
    ja      2f
    cmp     bx, word ptr [o3_hi]
    jae     11f
    mov     word ptr [o3_hi], bx
11: mov     dx, word ptr [o3_tgt]
    add     dx, O3_TOL
    cmp     ax, dx
    jbe     10f                         /* within the tolerance */
    test    bx, bx
    jz      10f                         /* N = 0: the smallest gap there is */
    mov     dx, bx
    dec     dx
    cmp     dx, word ptr [o3_lo]
    je      10f                         /* N - 1 fell short: N is the fewest */
    jmp     4f
2:  inc     word ptr [o3_btry]          /* BUSY lengthened it: the same N again */
    cmp     word ptr [o3_btry], 4
    jb      5f
    mov     byte ptr [o3_fitv], 2
    jmp     9f
3:  cmp     bx, word ptr [o3_lo]        /* short (signed: lo starts at -1) */
    jle     31f
    mov     word ptr [o3_lo], bx
31: mov     dx, word ptr [o3_hi]
    cmp     dx, word ptr [o3_lo]
    jg      4f
    mov     word ptr [o3_hi], O3_NMAX + 1   /* a jittered reading: forget the bound */
4:  cmp     word ptr [o3_try], O3_TRY
    jae     9f
    /* the next N: about 1.5 PIT counts per `out 5Fh` (0.6 us), kept inside (lo, hi) */
    mov     ax, word ptr [o3_tgt]
    inc     ax                          /* aim at target + O3_TOL / 2 */
    sub     ax, word ptr [o3_a]
    imul    ax, ax, 2
    cwd
    mov     cx, 3
    idiv    cx
    test    ax, ax
    jnz     41f
    mov     ax, 1
    mov     dx, word ptr [o3_a]
    cmp     dx, word ptr [o3_tgt]
    jb      41f
    mov     ax, -1
41: add     ax, bx
    mov     dx, word ptr [o3_hi]
    sub     dx, word ptr [o3_lo]
    cmp     dx, 1
    jg      42f
    mov     ax, word ptr [o3_hi]
    jmp     44f
42: cmp     ax, word ptr [o3_lo]
    jle     43f
    cmp     ax, word ptr [o3_hi]
    jl      44f
43: mov     ax, word ptr [o3_lo]
    add     ax, word ptr [o3_hi]
    sar     ax, 1
44: cmp     ax, 0
    jge     45f
    xor     ax, ax
45: cmp     ax, O3_NMAX
    jle     46f
    mov     ax, O3_NMAX
46: mov     word ptr [o3_nn], ax
5:  cmp     word ptr [o3_try], O3_TRY
    jb      1b
    jmp     9f
10: mov     byte ptr [o3_fitv], 1
9:  popad
    ret

/* o3_sweep: the steps [o3_from]..[o3_to] (1-based, defaults 1..O3_NSTEP), then the summary */
o3_sweep:
    pushad
    mov     si, offset con_shead
    call    con_s
    mov     eax, dword ptr [c_ratio]    /* CAL's PIT:ARTIC ratio; 8.000 when CAL had none */
    cmp     eax, 1000
    jae     1f
    mov     eax, 8000
1:  mov     dword ptr [o3_rt], eax
    mov     ax, word ptr [o3_from]
    test    ax, ax
    jnz     2f
    inc     ax
2:  cmp     ax, O3_NSTEP
    jbe     3f
    mov     ax, O3_NSTEP
3:  mov     word ptr [o3_from], ax
    mov     ax, word ptr [o3_to]
    test    ax, ax
    jnz     4f
    mov     ax, O3_NSTEP
4:  cmp     ax, O3_NSTEP
    jbe     5f
    mov     ax, O3_NSTEP
5:  cmp     ax, word ptr [o3_from]
    jae     6f
    mov     ax, word ptr [o3_from]
6:  mov     word ptr [o3_to], ax
    /* the plan */
    mov     si, offset k_I
    call    info_start
    PS      "SWEEP_PLAN"
    mov     eax, dword ptr [o3_rt]
    mov     si, offset k_rt
    call    out_kd
    movzx   eax, word ptr [o3_from]
    mov     si, offset k_from
    call    out_kd
    movzx   eax, word ptr [o3_to]
    mov     si, offset k_to
    call    out_kd
    PS      " gaps_us="
    xor     bx, bx
7:  movzx   eax, word ptr [o3_gaps + bx]
    call    out_d
    add     bx, 2
    cmp     bx, O3_NSTEP * 2
    jae     8f
    mov     al, ','
    call    out_c
    jmp     7b
8:  call    out_nl
    mov     di, O3_SW
    mov     cx, O3_NSTEP * 4
    xor     ax, ax
9:  mov     word ptr [di], ax
    add     di, 2
    loop    9b
    mov     ax, 0x3611                  /* rhythm total level 36 (MDRV2's REIMU value) */
    call    o2_put
    mov     word ptr [o3_nn], 0
    mov     cx, word ptr [o3_from]
sw_step:
    call    artic_read                  /* the watchdog budget counts per step */
    mov     dword ptr [wd_t0], eax
    mov     bx, cx
    dec     bx
    shl     bx, 1
    mov     dx, word ptr [o3_gaps + bx]
    shl     bx, 2
    add     bx, O3_SW
    mov     word ptr [bx], dx
    movzx   eax, dx                     /* target = ceil(us * 3072 * ratio / 10^7) */
    imul    eax, eax, 3072
    mul     dword ptr [o3_rt]
    add     eax, 9999999
    adc     edx, 0
    push    ecx
    mov     ecx, 10000000
    div     ecx
    pop     ecx
    mov     word ptr [o3_tgt], ax
    push    bx
    mov     si, offset tg_sweep
    mov     word ptr [o2_tg], si
    mov     ax, word ptr [o2_base]
    call    row_mark
    pop     bx
    call    o3_fit
    mov     ax, word ptr [o3_a]
    mov     word ptr [bx+2], ax
    mov     ax, word ptr [o3_try]
    mov     word ptr [bx+4], ax
    mov     al, byte ptr [o3_fitv]
    mov     byte ptr [bx+6], al
    mov     byte ptr [bx+7], 1
    /* the screen, before the hits */
    mov     di, O3_LN
    mov     si, offset s_inv
    call    o3_bs
    mov     ax, cx
    call    o3_fmt
    mov     si, offset s_norm
    call    o3_bs
    mov     byte ptr [di], 0
    mov     si, O3_LN
    call    con_s
    /* the row */
    mov     si, offset tg_sweep
    call    o2_x
    movzx   eax, cx
    mov     si, offset k_step
    call    out_kd
    movzx   eax, word ptr [bx]
    mov     si, offset k_gapus
    call    out_kd
    movzx   eax, word ptr [o3_tgt]
    mov     si, offset k_tgt
    call    out_kd
    movzx   eax, word ptr [o3_a]
    mov     si, offset k_pit
    call    out_kd
    movzx   eax, word ptr [o3_nn]
    mov     si, offset k_n5f
    call    out_kd
    movzx   eax, word ptr [o3_try]
    mov     si, offset k_tries
    call    out_kd
    movzx   eax, word ptr [o3_btry]
    mov     si, offset k_btries
    call    out_kd
    movzx   eax, byte ptr [o3_fitv]
    mov     si, offset k_fit
    call    out_kd
    movzx   eax, word ptr [o3_p18]
    mov     si, offset k_p18
    call    out_kd
    movzx   eax, word ptr [o3_p19]
    mov     si, offset k_p19
    call    out_kd
    movzx   eax, word ptr [o3_pa]
    mov     si, offset k_pa
    call    out_kd
    movzx   eax, word ptr [o3_tpa]
    mov     si, offset k_papit
    call    out_kd
    mov     eax, 4
    mov     si, offset k_keys
    call    out_kd
    call    out_nl
    /* 50 ms, then 4 hits 250 ms apart (key 200 ms, dump 50 ms) */
    mov     eax, T_10MS * 5
    call    o3_spin
    push    cx
    mov     cx, 4
10: mov     ax, 0x0110
    call    o2_put
    mov     eax, T_100MS * 2
    call    o3_spin
    mov     ax, 0x8110
    call    o2_put
    mov     eax, T_10MS * 5
    call    o3_spin
    loop    10b
    pop     cx
    call    out_flush
    mov     eax, T_1S
    call    o3_spin
    inc     cx
    cmp     cx, word ptr [o3_to]
    jbe     sw_step
    /* the summary */
    mov     si, offset s_shead
    call    con_s
    mov     cx, word ptr [o3_from]
11: mov     bx, cx
    dec     bx
    shl     bx, 3
    add     bx, O3_SW
    mov     di, O3_LN
    mov     ax, cx
    call    o3_fmt
    mov     si, offset s_pit
    call    o3_bs
    push    cx
    movzx   eax, word ptr [bx+2]
    mov     cx, 0x2003
    call    o3_bd
    mov     si, offset s_try
    call    o3_bs
    movzx   eax, word ptr [bx+4]
    mov     cx, 0x2002
    call    o3_bd
    pop     cx
    mov     si, offset s_crlf
    call    o3_bs
    mov     byte ptr [di], 0
    mov     si, O3_LN
    call    con_s
    inc     cx
    cmp     cx, word ptr [o3_to]
    jbe     11b
    popad
    ret

/* ---------------------------------------------------------------- the section */
sec_opna3:
    mov     si, offset nm_opna3
    mov     eax, WD_60S
    mov     bx, offset o3_exit
    call    sec_begin
    mov     byte ptr [o3_ran], 0
    mov     word ptr [tag_sfx], 0
    mov     word ptr [o2_base], 0x188
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
    jmp     o3_end
1:  mov     dx, 0xA460
    in      al, dx
    mov     byte ptr [o2_a460], al
    mov     dx, 0x188
    in      al, dx
    mov     byte ptr [o3_st], al
    mov     si, offset k_STATE
    call    info_start
    PS      "a460="
    mov     al, byte ptr [o2_a460]
    call    out_x2
    PS      " st="
    mov     al, byte ptr [o3_st]
    call    out_x2
    PS      " listen="
    movzx   eax, byte ptr [m_listen]
    call    out_d
    PS      " sweep="
    movzx   eax, byte ptr [m_sweep]
    call    out_d
    PS      " sd5f="
    mov     eax, O3_SD5F
    call    out_d
    PS      " vec60="
    mov     eax, dword ptr [op_v60]
    call    out_x8
    call    out_nl
    cmp     byte ptr [o3_st], 0xFF
    jne     2f
    mov     si, offset rs_absent
    call    skip_line
    jmp     o3_end
2:  mov     byte ptr [o3_ran], 1
    mov     word ptr [o2_to], 0
    mov     al, byte ptr [o2_a460]
    or      al, 1
    call    o2_a460w
    cli
    mov     ax, 0xBF10                  /* every drum dumped */
    call    o2_put
    mov     ax, 0x0011                  /* rhythm total level 0 */
    call    o2_put
    sti
    cmp     byte ptr [m_sweep], 0
    je      21f
    call    o3_sweep                    /* /SWEEP: the gap sweep only */
    jmp     22f
21:
    /* 1. one level write at swept phases */
    mov     si, offset o3_rhy18
    mov     cx, O2_N
    call    o2_busy
    /* 2. MDRV2's six level writes back to back */
    mov     si, offset o3_mdrv
    mov     bx, offset tg_b2brl
    call    o3_b2b
    /* 3. key writes back to back, every drum routed nowhere */
    mov     byte ptr [o3_slow], 1
    mov     si, offset o3_off
    xor     di, di
    xor     cx, cx
    call    o3_burst
    mov     si, offset o3_keyl
    mov     bx, offset tg_b2brk
    call    o3_b2b
    cli
    mov     ax, 0xBF10
    call    o2_put
    sti
22: cmp     word ptr [o2_to], 0
    je      3f
    mov     si, offset to_o3
    call    timeout_line
3:  cmp     byte ptr [m_sweep], 0
    jne     o3_exit
    /* 4. the audible phases */
    cmp     byte ptr [m_listen], 0
    je      o3_exit
    mov     si, offset con_lhead
    call    con_s
    mov     ax, 0x3611                  /* rhythm total level 36 (MDRV2's REIMU value) */
    call    o2_put
    mov     si, offset o3_fwd
    mov     bx, offset tg_lslow
    mov     dx, offset con_l1
    mov     al, 1
    call    o3_phase
    mov     si, offset o3_fwd
    mov     bx, offset tg_lb2b
    mov     dx, offset con_l2
    mov     al, 0
    call    o3_phase
    mov     si, offset o3_rev
    mov     bx, offset tg_lrev
    mov     dx, offset con_l3
    mov     al, 0
    call    o3_phase
o3_exit:
    call    sec_disarm
    cmp     byte ptr [o3_ran], 0
    je      o3_end
    mov     word ptr [o2_base], 0x188
    cli
    mov     si, offset o3_rs
    call    o2_putlist
    sti
    mov     al, byte ptr [o2_a460]
    call    o2_a460w
    mov     dx, 0xA460
    mov     si, offset n_a460
    call    rs_port8
    mov     si, offset n_opna3r
    xor     eax, eax
    call    rs_default
o3_end:
    call    sec_end
    ret

    VARS
    .p2align 1
o3_t0:      .word 0
o3_prev:    .word 0
o3_lst:     .word 0
o3_st:      .byte 0
o3_slow:    .byte 0
o3_wd:      .byte 0
o3_ran:     .byte 0
    .p2align 1
o3_from:    .word 0
o3_to:      .word 0
o3_nn:      .word 0
o3_lo:      .word 0
o3_hi:      .word 0
o3_try:     .word 0
o3_btry:    .word 0
o3_tgt:     .word 0
o3_a:       .word 0
o3_p18:     .word 0
o3_p19:     .word 0
o3_pa:      .word 0
o3_tpa:     .word 0
o3_rt:      .long 0
o3_fitv:    .byte 0
    ENDVARS

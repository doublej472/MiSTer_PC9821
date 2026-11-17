/* pcm86ovf.s - PCMOVF, what the PC-9801-86 PCM FIFO (0xA460-0xA46E, built into the PC-9821Xe10)
 * does when it is written past full. Stage 1: status flags and timing only, no audio recording.
 * Run on the core first, then on the real machine (the tools/hwprobe rule: the SAME binary on
 * both sides, raw capture kept).
 *
 *   PCMOVF > PCMOVF.TXT        stage 1 (no arguments; about 30 s; plain DOS, no sound driver)
 *   PCMOVF /A > PCMAUD.TXT     stage 2: the audio run for a line-out recording (about 60 s; see
 *                              "STAGE 2" below and pcm86ovf_audio.py). Stage 1 does not run.
 *
 * THE PORTS (NP2kai cbus/pcm86io.c; the core src/pcm86/pc9821_pcm86.sv):
 *   0xA466 read   bit 7 FIFO full, bit 6 FIFO empty (fewer bytes than one sample frame), bit 0
 *                 the sample-rate phase. Never written here (its write is the DAC volume).
 *   0xA468        bit 7 playback, bit 5 FIFO interrupt enable, bit 4 read: the interrupt flag,
 *                 write 0: clear it; bit 3 FIFO reset (its 0->1 edge in NP2kai and the core; the
 *                 firmware leaves it SET, docs/probes/KIT1-XE10-CFG0.TXT `PORT A468=08 08`);
 *                 bits 2:0 the rate (0 = 44100 Hz).
 *   0xA46A        with 0xA468 bit 5 clear: the DAC format (bits 6:4: 8-bit, left, right), read
 *                 back verbatim; with bit 5 set: the IRQ threshold, (v + 1) * 128 bytes, FF =
 *                 0x7FFC. The firmware leaves B0 (16-bit stereo; KIT1-XE10-CFG0.TXT).
 *   0xA46C        the FIFO data port (write only).
 * Every run uses 8-bit LEFT-only mono (0xA46A = 0x60 | (as-found & 0x8F)): one byte per sample
 * frame, so a drain time resolves single bytes, and the data bytes are 00 (signed-8-bit silence).
 * The FIFO reset is written 00, 08, 00 (an edge in either an edge or a level reading of bit 3).
 *
 * SECTIONS (BEGIN:x ... END:x; a hang is a BEGIN with no END; the capture is committed to disk
 * after every section, INT 21h AH=68h on the redirected stdout):
 *   FILL   playback stopped, after a reset: writes 00 one byte at a time and reads 0xA466 after
 *          each; the byte count at which bit 7 (full) first reads 1 and bit 6 (empty) first
 *          reads 0, the flags at n = 0, 1, 32767, 32768. Bounded by 40000 writes and 2 s.
 *          Its full count is CAP; without one every later section is skipped.
 *   WCOST  the cost of the overflow loop body (out 0xA46C, in 0xA466, log) on an empty FIFO:
 *          1024 iterations, ARTIC ticks. The reference for PLAY's stall check.
 *   CAL    the drain rate: a fresh reset, n bytes written with playback stopped, then playback
 *          started at 44100 Hz and 0xA466 polled until bit 6 (empty); n = 4096, 16384, 24576
 *          (two trials each), and n = 16384 in the as-found format (frame size check).
 *   THR    the IRQ threshold around full: IRQ enabled (bit 5), threshold v = 7F (16384), FE
 *          (32640), FF (NP2kai 0x7FFC); the FIFO filled to CAP with playback stopped, and at
 *          every byte count within 4 of the threshold and within 4 below CAP: 0xA468 read
 *          (raw), a flag clear (0xA468 <- 20), 0xA468 read again (clr), the slave IRR (IR12,
 *          masked in the IMR throughout) and 0xA466.
 *   PLAY   the overflow with playback RUNNING: filled to CAP, playback started, then 2048 more
 *          bytes written as fast as the loop goes (well above the 44100 B/s drain), 0xA466 read
 *          after each, then the drain timed from the last write. If the burst's per-write cost
 *          is over 3x WCOST's (a write that waits for room), OVF is skipped: with playback
 *          stopped such a write could wait for ever.
 *   OVF    the overflow with playback STOPPED: for depth d = 0, 1, 2, 3, 4, 5, 8, 64 (two trials
 *          each, a fresh reset and fill to CAP every time): d extra bytes, 0xA466 after each,
 *          then playback started and the time to empty measured.
 * Every drain (CAL, PLAY, OVF) runs with the FIFO interrupt enabled at threshold 3F (8192
 * bytes) and records the first poll at which 0xA466 bit 7 reads 0 (nf), 0xA468 bit 4 reads 1
 * (irq), slave IRR bit 4 reads 1 (irr), and 0xA466 bit 6 reads 1 (empty), in ARTIC ticks from
 * the playback-start write; a drain is bounded by 3 s (tmo=1). If the first CAL drain times
 * out, the later drains are skipped.
 *
 * RESTORE: playback stopped, FIFO reset, interrupt disabled and cleared, the threshold set to
 * 00 (128 bytes, the reset value of NP2kai and the core; the as-found threshold cannot be
 * read), 0xA46A and then 0xA468 put back as found, the slave IMR put back, OCW3 back to ISR
 * reads; RESTORE lines compare the read-backs. The DAC volume (0xA466 write) is not touched.
 *
 * EXPECTED (tools/hwprobe/pcm86ovf/pcm86ovf_decode.py states each row's prediction):
 *   the core   full at 32768; each byte past full drops the oldest 4-byte group, so the count
 *              goes 32765, 32766, 32767, 32768, 32765, ... (full reads 1 only on every 4th
 *              extra byte) and OVF d >= 1 drains 32765 + (d - 1) % 4 bytes
 *   NP2kai     full at 32768 and STAYS full (virbuf saturates at 0x8000); every drain empties
 *              after 32768 bytes; the extra bytes sit in its rescue margin, invisible to the flags
 *
 * TIMING: the ARTIC free-running counter (0x5C/0x5F, 307200 Hz), crt31k.s's reader; every wait
 * is an ARTIC deadline or a bounded count. Interrupts are off (cli) for each fill+drain run.
 *
 * BUILD: make -C tools/hwprobe pcm86ovf/pcmovf.com
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

    .equ P_ID,      0xA460
    .equ P_STAT,    0xA466
    .equ P_CTL,     0xA468
    .equ P_DAC,     0xA46A
    .equ P_DATA,    0xA46C
    .equ SPIC_CMD,  0x0008
    .equ SPIC_IMR,  0x000A
    .equ DL_FILL,   614400          /* 2 s of ARTIC */
    .equ DL_DRAIN,  921600          /* 3 s */
    .equ FILL_MAX,  40000
    .equ DRAIN_THR, 0x3F            /* (0x3F + 1) * 128 = 8192 bytes */
    .equ PLAY_W,    2048
    .equ C_PLAY,    0xB0            /* playback, IRQ enable, bit 4 = 1 (no clear), 44100 Hz */
    .equ C_IRQEN,   0x20            /* stopped, IRQ enable, flag clear */
    .equ LOGMAX,    64

_start:
    push    cs
    pop     ds
    push    cs
    pop     es
    cld
    /* the argument: /A selects stage 2 (the audio run); anything else, or none, is stage 1 */
    mov     si, 0x81
    mov     cl, [0x80]
    xor     ch, ch
    jcxz    12f
11: lodsb
    cmp     al, '/'
    jne     13f
    mov     al, [si]
    and     al, 0xDF
    cmp     al, 'A'
    jne     13f
    mov     byte ptr [mode_a], 1
13: loop    11b
12: mov     dx, offset s_hdr
    cmp     byte ptr [mode_a], 0
    je      14f
    mov     dx, offset s_hdr_a
14: call    puts
    mov     dx, P_ID
    in      al, dx
    mov     [f_a460], al
    mov     dx, P_STAT
    in      al, dx
    mov     [f_a466], al
    mov     dx, P_CTL
    in      al, dx
    mov     [f_a468], al
    mov     dx, P_DAC
    in      al, dx
    mov     [f_a46a], al
    in      al, SPIC_IMR
    mov     [f_imrs], al
    /* the 8-bit mono format: 0x60 with the as-found bit 7 and low nibble (a low nibble F is one
     * NP2kai refuses, pcm86io.c `(val & 0xf) == 0xf`, so it is cleared) */
    mov     al, [f_a46a]
    and     al, 0x8F
    mov     ah, al
    and     ah, 0x0F
    cmp     ah, 0x0F
    jne     1f
    and     al, 0xF0
1:  or      al, 0x60
    mov     [dac8], al
    mov     [dac_cur], al
    mov     dx, offset s_state
    call    puts
    mov     al, [f_a460]
    call    puthex8
    mov     dx, offset s_a466
    call    puts
    mov     al, [f_a466]
    call    puthex8
    mov     dx, offset s_a468
    call    puts
    mov     al, [f_a468]
    call    puthex8
    mov     dx, offset s_a46a
    call    puts
    mov     al, [f_a46a]
    call    puthex8
    mov     dx, offset s_imrs
    call    puts
    mov     al, [f_imrs]
    call    puthex8
    mov     dx, offset s_dac8
    call    puts
    mov     al, [dac8]
    call    puthex8
    call    putnl
    cmp     byte ptr [f_a460], 0xFF
    jne     2f
    mov     dx, offset s_absent
    call    puts
    jmp     9f
2:  test    byte ptr [f_a468], 0x80
    jz      3f
    mov     dx, offset s_playing
    call    puts
    jmp     9f
3:  cmp     byte ptr [mode_a], 0
    je      31f
    call    audio_main              /* stage 2 (/A) */
    jmp     81f
31: mov     al, [f_imrs]           /* IR12 (INT5: the OPNA and this FIFO) masked throughout */
    or      al, 0x10
    out     SPIC_IMR, al
    call    commit
    call    sec_fill
    call    commit
    cmp     dword ptr [cap], 0
    je      8f
    call    sec_wcost
    call    commit
    call    sec_cal
    call    commit
    call    sec_thr
    call    commit
    call    sec_play
    call    commit
    call    sec_ovf
    call    commit
    jmp     81f
8:  mov     dx, offset s_nofull
    call    puts
81: call    restore
9:  mov     dx, offset s_done
    call    puts
    call    commit
    mov     ax, 0x4C00
    int     0x21

/* ======================================================================================== */
/* FILL                                                                                      */
/* ======================================================================================== */
sec_fill:
    mov     dx, offset s_b_fill
    call    puts
    mov     ax, 0xFFFF
    mov     di, offset fsnap
    mov     cx, 8
    rep     stosw
    mov     dword ptr [cap], 0
    mov     dword ptr [f_ne], 0
    mov     byte ptr [f_tmo], 0
    cli
    call    pcm_reset
    mov     dx, P_STAT
    in      al, dx
    mov     [fsnap + 0], al
    mov     dx, P_CTL
    in      al, dx
    mov     [fsnap + 1], al
    call    artic_read
    mov     [t0], eax
    xor     ecx, ecx
1:  mov     dx, P_DATA
    xor     al, al
    out     dx, al
    inc     ecx
    mov     dx, P_STAT
    in      al, dx
    mov     bl, al
    test    bl, 0x40
    jnz     2f
    cmp     dword ptr [f_ne], 0
    jne     2f
    mov     [f_ne], ecx
2:  mov     si, 2
    cmp     ecx, 1
    je      3f
    mov     si, 4
    cmp     ecx, 32767
    je      3f
    mov     si, 6
    cmp     ecx, 32768
    jne     4f
3:  mov     [fsnap + si], bl
    mov     dx, P_CTL
    in      al, dx
    mov     [fsnap + si + 1], al
4:  test    bl, 0x80
    jz      5f
    mov     [cap], ecx
    jmp     7f
5:  cmp     ecx, FILL_MAX
    jae     7f
    test    cx, 255
    jnz     1b
    call    artic_read
    sub     eax, [t0]
    and     eax, 0xFFFFFF
    cmp     eax, DL_FILL
    jb      1b
    mov     byte ptr [f_tmo], 1
7:  call    artic_read
    sub     eax, [t0]
    and     eax, 0xFFFFFF
    mov     [t_el], eax
    mov     [f_n], ecx
    call    pcm_reset
    sti
    /* the four snapshots */
    xor     bx, bx
71: mov     dx, offset s_fill_n
    call    puts
    mov     eax, [fsn_n + bx]
    call    putdec
    mov     dx, offset s_a466
    call    puts
    mov     si, bx
    shr     si, 1
    mov     ax, [fsnap + si]
    call    puthex8_or
    mov     dx, offset s_a468
    call    puts
    mov     al, ah
    call    puthex8_or_ff
    call    putnl
    add     bx, 4
    cmp     bx, 16
    jb      71b
    mov     dx, offset s_fill_ff
    call    puts
    mov     eax, [cap]
    call    putdec
    mov     dx, offset s_fne
    call    puts
    mov     eax, [f_ne]
    call    putdec
    mov     dx, offset s_writes
    call    puts
    mov     eax, [f_n]
    call    putdec
    mov     dx, offset s_art
    call    puts
    mov     eax, [t_el]
    call    putdec
    mov     dx, offset s_tmo
    call    puts
    mov     al, [f_tmo]
    call    puthex8
    call    putnl
    mov     dx, offset s_e_fill
    call    puts
    ret

/* a snapshot byte pair AX (AL a466, AH a468) = FFFF when its count was never reached */
puthex8_or:
    cmp     ax, 0xFFFF
    jne     puthex8
    push    dx
    mov     dx, offset s_dash
    call    puts
    pop     dx
    ret
puthex8_or_ff:
    cmp     word ptr [fsnap + si], 0xFFFF
    jne     puthex8
    push    dx
    mov     dx, offset s_dash
    call    puts
    pop     dx
    ret

/* ======================================================================================== */
/* WCOST                                                                                     */
/* ======================================================================================== */
sec_wcost:
    mov     dx, offset s_b_wcost
    call    puts
    cli
    call    pcm_reset
    mov     ecx, 1024
    call    wloop
    call    pcm_reset
    sti
    mov     eax, [w_art]
    mov     [wcost], eax
    mov     dx, offset s_wcost
    call    puts
    mov     eax, [w_art]
    call    putdec
    mov     dx, offset s_full
    call    puts
    mov     eax, [w_full]
    call    putdec
    call    putnl
    mov     dx, offset s_e_wcost
    call    puts
    ret

/* ======================================================================================== */
/* CAL                                                                                       */
/* ======================================================================================== */
sec_cal:
    mov     dx, offset s_b_cal
    call    puts
    mov     byte ptr [nodrain], 0
    mov     si, offset cal_tab
1:  mov     ecx, [si]
    test    ecx, ecx
    jz      9f
    mov     al, [dac8]
    cmp     byte ptr [si + 4], 0
    je      2f
    mov     al, [f_a46a]
2:  mov     [dac_cur], al
    mov     byte ptr [trial], 1
3:  mov     [run_n], ecx
    mov     dword ptr [run_d], 0
    push    si
    cmp     byte ptr [nodrain], 0
    je      4f
    mov     dx, offset s_dr_cal
    call    puts
    call    drain_ids
    mov     dx, offset s_skip
    call    puts
    jmp     5f
4:  cli
    call    pcm_reset
    mov     ecx, [run_n]
    call    fastfill
    call    drain_arm
    call    drain_start
    call    drain_poll
    call    pcm_reset
    sti
    mov     dx, offset s_dr_cal
    call    drain_print
    cmp     byte ptr [d_tmo], 0
    je      5f
    mov     byte ptr [nodrain], 1
5:  pop     si
    call    commit
    mov     ecx, [si]
    inc     byte ptr [trial]
    cmp     byte ptr [trial], 2
    jbe     3b
    add     si, 5
    jmp     1b
9:  mov     al, [dac8]
    mov     [dac_cur], al
    mov     dx, offset s_e_cal
    call    puts
    ret

/* ======================================================================================== */
/* THR                                                                                       */
/* ======================================================================================== */
sec_thr:
    mov     dx, offset s_b_thr
    call    puts
    mov     si, offset thr_tab
1:  cmp     byte ptr [si], 0
    je      9f
    mov     al, [si + 1]
    mov     [thr_v], al
    mov     eax, [si + 2]
    mov     [thr_t], eax
    push    si
    mov     di, offset thr_log
    mov     word ptr [thr_cnt], 0
    cli
    call    pcm_reset
    mov     dx, P_CTL
    mov     al, C_IRQEN
    out     dx, al
    call    iodly
    mov     dx, P_DAC
    mov     al, [thr_v]
    out     dx, al
    call    iodly
    mov     al, 0x0A                /* OCW3: read IRR */
    out     SPIC_CMD, al
    xor     ecx, ecx
2:  mov     dx, P_DATA
    xor     al, al
    out     dx, al
    inc     ecx
    /* in a window: |n - T| <= 4, or CAP - 4 <= n */
    mov     eax, ecx
    sub     eax, [thr_t]
    jns     3f
    neg     eax
3:  cmp     eax, 4
    jbe     4f
    mov     eax, [cap]
    sub     eax, 4
    cmp     ecx, eax
    jb      6f
4:  cmp     word ptr [thr_cnt], 24
    jae     6f
    mov     [di], cx                /* n (all n <= 40000 fit a word) */
    mov     dx, P_CTL
    in      al, dx
    mov     [di + 2], al            /* raw */
    mov     al, C_IRQEN             /* bit 4 = 0: clear the flag */
    out     dx, al
    in      al, dx
    mov     [di + 3], al            /* clr */
    in      al, SPIC_CMD
    mov     [di + 4], al            /* irr */
    mov     dx, P_STAT
    in      al, dx
    mov     [di + 5], al
    add     di, 6
    inc     word ptr [thr_cnt]
6:  cmp     ecx, [cap]
    jb      2b
    mov     al, 0x0B
    out     SPIC_CMD, al
    mov     dx, P_CTL               /* IRQ off before the reset */
    xor     al, al
    out     dx, al
    call    pcm_reset
    sti
    mov     si, offset thr_log
    mov     cx, [thr_cnt]
7:  jcxz    8f
    mov     dx, offset s_thr
    call    puts
    mov     al, [thr_v]
    call    puthex8
    mov     dx, offset s_thr_t
    call    puts
    mov     eax, [thr_t]
    call    putdec
    mov     dx, offset s_n
    call    puts
    movzx   eax, word ptr [si]
    call    putdec
    mov     dx, offset s_a466
    call    puts
    mov     al, [si + 5]
    call    puthex8
    mov     dx, offset s_raw
    call    puts
    mov     al, [si + 2]
    call    puthex8
    mov     dx, offset s_clr
    call    puts
    mov     al, [si + 3]
    call    puthex8
    mov     dx, offset s_irrs
    call    puts
    mov     al, [si + 4]
    call    puthex8
    call    putnl
    add     si, 6
    dec     cx
    jmp     7b
8:  call    commit
    pop     si
    add     si, 6
    jmp     1b
9:  mov     dx, offset s_e_thr
    call    puts
    ret

/* ======================================================================================== */
/* PLAY                                                                                      */
/* ======================================================================================== */
sec_play:
    mov     dx, offset s_b_play
    call    puts
    mov     byte ptr [stall], 0
    cmp     byte ptr [nodrain], 0
    je      1f
    mov     dx, offset s_play_skip
    call    puts
    jmp     9f
1:  mov     dword ptr [run_n], 0
    mov     eax, [cap]
    mov     [run_n], eax
    mov     dword ptr [run_d], PLAY_W
    mov     byte ptr [trial], 1
    cli
    call    pcm_reset
    mov     ecx, [cap]
    call    fastfill
    mov     dx, P_STAT
    in      al, dx
    mov     [pre], al
    call    drain_arm
    call    drain_start
    mov     ecx, PLAY_W
    call    wloop
    mov     dx, P_CTL
    in      al, dx
    mov     [ovf_c], al
    call    artic_read              /* the drain is timed from the burst's last write */
    mov     [d_t0], eax
    call    drain_poll
    call    pcm_reset
    sti
    mov     dx, offset s_play
    call    puts
    call    ovf_print
    mov     dx, offset s_dr_play
    call    drain_print
    /* the stall check: the burst's ticks against WCOST's per 1024 writes, scaled to PLAY_W */
    mov     eax, [wcost]
    imul    eax, eax, 3 * PLAY_W / 1024
    cmp     [w_art], eax
    jbe     9f
    mov     byte ptr [stall], 1
    mov     dx, offset s_stall
    call    puts
9:  mov     dx, offset s_e_play
    call    puts
    ret

/* ======================================================================================== */
/* OVF                                                                                       */
/* ======================================================================================== */
sec_ovf:
    mov     dx, offset s_b_ovf
    call    puts
    cmp     byte ptr [stall], 0
    je      1f
    mov     dx, offset s_ovf_stall
    call    puts
    jmp     9f
1:  mov     si, offset ovf_tab
2:  movzx   ecx, byte ptr [si]
    cmp     cl, 0xFF
    je      9f
    mov     [run_d], ecx
    mov     eax, [cap]
    mov     [run_n], eax
    mov     byte ptr [trial], 1
3:  push    si
    mov     dx, offset s_ovf
    call    puts
    mov     dx, offset s_rowmark
    call    puts
    mov     eax, [run_d]
    call    putdec
    call    putnl
    call    commit                  /* the row is on disk before the writes past full */
    cli
    call    pcm_reset
    mov     ecx, [cap]
    call    fastfill
    mov     dx, P_STAT
    in      al, dx
    mov     [pre], al
    mov     ecx, [run_d]
    call    wloop
    mov     dx, P_CTL
    in      al, dx
    mov     [ovf_c], al
    cmp     byte ptr [nodrain], 0
    jne     4f
    call    drain_arm
    call    drain_start
    call    drain_poll
4:  call    pcm_reset
    sti
    mov     dx, offset s_ovf
    call    puts
    call    ovf_print
    mov     dx, offset s_dr_ovf
    cmp     byte ptr [nodrain], 0
    je      5f
    call    puts
    call    drain_ids
    mov     dx, offset s_skip
    call    puts
    jmp     6f
5:  call    drain_print
6:  call    commit
    pop     si
    inc     byte ptr [trial]
    cmp     byte ptr [trial], 2
    jbe     3b
    inc     si
    jmp     2b
9:  mov     dx, offset s_e_ovf
    call    puts
    ret

/* ovf_print: the rest of a PLAY/OVF row: d, trial, pre, the burst, statuses (first LOGMAX) */
ovf_print:
    mov     dx, offset s_d
    call    puts
    mov     eax, [run_d]
    call    putdec
    mov     dx, offset s_tr
    call    puts
    movzx   eax, byte ptr [trial]
    call    putdec
    mov     dx, offset s_pre
    call    puts
    mov     al, [pre]
    call    puthex8
    mov     dx, offset s_c
    call    puts
    mov     al, [ovf_c]
    call    puthex8
    mov     dx, offset s_art
    call    puts
    mov     eax, [w_art]
    call    putdec
    mov     dx, offset s_full
    call    puts
    mov     eax, [w_full]
    call    putdec
    mov     dx, offset s_fnf
    call    puts
    mov     eax, [w_fnf]
    call    putdec
    mov     dx, offset s_st
    call    puts
    mov     si, offset wlog
    mov     cx, [w_logn]
    jcxz    2f
1:  lodsb
    call    puthex8
    dec     cx
    jz      2f
    call    putsp
    jmp     1b
2:  call    putnl
    ret

/* ======================================================================================== */
/* the run primitives (called with interrupts off)                                           */
/* ======================================================================================== */
/* pcm_reset: playback stopped, IRQ off, flag cleared, FIFO reset (00, 08, 00), the DAC format
 * [dac_cur] written with bit 5 clear */
pcm_reset:
    push    ax
    push    dx
    mov     dx, P_CTL
    xor     al, al
    out     dx, al
    call    iodly
    mov     al, 0x08
    out     dx, al
    call    iodly
    xor     al, al
    out     dx, al
    call    iodly
    mov     dx, P_DAC
    mov     al, [dac_cur]
    out     dx, al
    call    iodly
    pop     dx
    pop     ax
    ret

/* fastfill: ECX (> 0) bytes of 00 to the FIFO, no status reads */
fastfill:
    push    dx
    mov     dx, P_DATA
    xor     al, al
1:  out     dx, al
    dec     ecx
    jnz     1b
    pop     dx
    ret

/* wloop: ECX (>= 0) bytes (wpat[i & 7]: 00 in stage 1, the markers in stage 2), each followed by an 0xA466 read. The first LOGMAX statuses go
 * to wlog ([w_logn] of them); [w_full] counts the statuses with bit 7 set, [w_fnf] is the first
 * 1-based write after which bit 7 read 0 (0: none); [w_art] the loop's ARTIC ticks. */
wloop:
    mov     dword ptr [w_full], 0
    mov     dword ptr [w_fnf], 0
    mov     word ptr [w_logn], 0
    mov     di, offset wlog
    push    ecx
    call    artic_read
    mov     [w_t0], eax
    pop     ecx
    xor     ebx, ebx
    test    ecx, ecx
    jz      8f
1:  mov     si, bx                  /* the byte: wpat[index & 7] (stage 1: all 00) */
    and     si, 7
    mov     al, [wpat + si]
    mov     dx, P_DATA
    out     dx, al
    mov     dx, P_STAT
    in      al, dx
    inc     ebx
    cmp     di, offset wlog + LOGMAX
    jae     2f
    stosb
    inc     word ptr [w_logn]
2:  test    al, 0x80
    jz      3f
    inc     dword ptr [w_full]
    jmp     4f
3:  cmp     dword ptr [w_fnf], 0
    jne     4f
    mov     [w_fnf], ebx
4:  dec     ecx
    jnz     1b
8:  call    artic_read
    sub     eax, [w_t0]
    and     eax, 0xFFFFFF
    mov     [w_art], eax
    ret

/* drain_arm: (playback stopped) IRQ enabled and its flag cleared, threshold DRAIN_THR, OCW3 IRR */
drain_arm:
    mov     dx, P_CTL
    mov     al, C_IRQEN
    out     dx, al
    call    iodly
    mov     dx, P_DAC
    mov     al, DRAIN_THR
    out     dx, al
    call    iodly
    mov     al, 0x0A
    out     SPIC_CMD, al
    ret

/* drain_start: [d_st0] = 0xA466 just before, [d_t0] = the ARTIC just before the start write */
drain_start:
    mov     dx, P_STAT
    in      al, dx
    mov     [d_st0], al
    call    artic_read
    mov     [d_t0], eax
    mov     dx, P_CTL
    mov     al, C_PLAY
    out     dx, al
    ret

/* drain_poll: poll until 0xA466 bit 6 or DL_DRAIN from [d_t0]; first-seen times (FFFFFFFF =
 * never) of bit 7 = 0 [d_nf], 0xA468 bit 4 [d_irq], slave IRR bit 4 [d_irr], bit 6 [d_emp];
 * [d_polls], [d_tmo]. Then playback stopped with the IRQ off and OCW3 back to ISR. */
drain_poll:
    mov     eax, 0xFFFFFFFF
    mov     [d_nf], eax
    mov     [d_irq], eax
    mov     [d_irr], eax
    mov     [d_emp], eax
    mov     dword ptr [d_polls], 0
    mov     byte ptr [d_tmo], 0
1:  mov     dx, P_STAT
    in      al, dx
    mov     bl, al
    mov     dx, P_CTL
    in      al, dx
    mov     bh, al
    in      al, SPIC_CMD
    mov     cl, al
    call    artic_read
    sub     eax, [d_t0]
    and     eax, 0xFFFFFF
    mov     edi, eax
    inc     dword ptr [d_polls]
    test    bl, 0x80
    jnz     2f
    cmp     dword ptr [d_nf], 0xFFFFFFFF
    jne     2f
    mov     [d_nf], edi
2:  test    bh, 0x10
    jz      3f
    cmp     dword ptr [d_irq], 0xFFFFFFFF
    jne     3f
    mov     [d_irq], edi
3:  test    cl, 0x10
    jz      4f
    cmp     dword ptr [d_irr], 0xFFFFFFFF
    jne     4f
    mov     [d_irr], edi
4:  test    bl, 0x40
    jz      5f
    mov     [d_emp], edi
    jmp     9f
5:  cmp     edi, DL_DRAIN
    jb      1b
    mov     byte ptr [d_tmo], 1
9:  mov     dx, P_CTL
    xor     al, al
    out     dx, al
    mov     al, 0x0B
    out     SPIC_CMD, al
    ret

/* drain_print: DX = the row's tag string; the DRAIN row */
drain_print:
    call    puts
    call    drain_ids
    mov     dx, offset s_st0
    call    puts
    mov     al, [d_st0]
    call    puthex8
    mov     dx, offset s_nf
    call    puts
    mov     eax, [d_nf]
    call    putdec_or
    mov     dx, offset s_irq
    call    puts
    mov     eax, [d_irq]
    call    putdec_or
    mov     dx, offset s_irr
    call    puts
    mov     eax, [d_irr]
    call    putdec_or
    mov     dx, offset s_empty
    call    puts
    mov     eax, [d_emp]
    call    putdec_or
    mov     dx, offset s_polls
    call    puts
    mov     eax, [d_polls]
    call    putdec
    mov     dx, offset s_tmo
    call    puts
    mov     al, [d_tmo]
    call    puthex8
    call    putnl
    ret

/* drain_ids: " dac=xx n=N d=D tr=T" */
drain_ids:
    mov     dx, offset s_dac
    call    puts
    mov     al, [dac_cur]
    call    puthex8
    mov     dx, offset s_n
    call    puts
    mov     eax, [run_n]
    call    putdec
    mov     dx, offset s_d
    call    puts
    mov     eax, [run_d]
    call    putdec
    mov     dx, offset s_tr
    call    puts
    movzx   eax, byte ptr [trial]
    call    putdec
    ret

/* ======================================================================================== */
/* STAGE 2 (/A): the audio run                                                               */
/* ======================================================================================== */
/* What the FIFO PLAYS after an overflow, for a line-out recording (pcm86ovf_audio.py decodes
 * the WAV). 16-bit stereo (0xA46A = 0x30 | (as-found & 0x8F)), rate index 7 (33075 / 8 =
 * 4134 Hz: a frame is 10.7 recorded samples at 44.1 kHz), DAC volume 0xA466 <- A0 (attenuation
 * 0; the volume is write-only, so it is left there). Each frame is big-endian (high byte first):
 *   S, frame i of 8192 (the fill): L = 0x3008 / 0xD0F8 (bytes 30 08 / D0 F8), R = 0x4040 /
 *     0xC0C0 (bytes 40 40 / C0 C0). R alternates every frame (+ on even i). L alternates too,
 *     except in the first 48 and last 48 frames, where its sign is the 96-bit table a_prbs
 *     (bit = 1: minus; LSB first), so the first and last frames played name their own index. A
 *     1-, 2- or 3-byte slip moves the low bytes into the high bytes: a 1-byte slip makes L
 *     +/-0x08xx (L's sign pattern at 1/6 of its level), a 3-byte slip makes R +/-0x08xx, a
 *     2-byte slip swaps L and R.
 *   the markers, the d bytes written past full: 70 00 90 00 90 00 70 00 repeating (L and R in
 *     ANTI-phase at 0x7000, unlike S).
 *   the sync: three bursts of 1024 frames, L = R = +/-0x7000 alternating (in phase), 0.5 s
 *     apart.
 * One rep: the sync at 0, 0.5, 1.0 s from its start, then the nine cases (d = 0 1 2 3 4 5 8
 * 64 0), case k in the slot 2.0 + 3.0 k s: reset, fill S (cli; the full flag's count checked:
 * a case is skipped unless it is 32768), d marker bytes, playback started at slot + 0.5 s and
 * stopped 0.1 s after the empty flag (or at slot + 2.8 s). Two reps, about 58 s.
 * AUD rows: rep, case, d, the full count, the statuses after each marker byte, the time from
 * the start to the empty flag (ARTIC ticks). */
    .equ A_CTL,     0x07            /* stopped, 4134 Hz */
    .equ A_PLAY,    0x87
    .equ A_SFRAMES, 8192
    .equ A_HEAD,    48
    .equ T_HALF,    153600          /* 0.5 s */
    .equ T_SLOT,    921600          /* 3.0 s */
    .equ T_CASE0,   614400          /* 2.0 s */
    .equ T_STOP,    860160          /* 2.8 s */
    .equ T_TAIL,    30720           /* 0.1 s */
    .equ T_REP,     8908800         /* 29 s */

audio_main:
    mov     al, [f_a46a]
    and     al, 0x8F
    mov     ah, al
    and     ah, 0x0F
    cmp     ah, 0x0F
    jne     1f
    and     al, 0xF0
1:  or      al, 0x30
    mov     [dac_cur], al
    mov     dx, offset s_a_dac
    call    puts
    call    puthex8
    call    putnl
    mov     dx, P_STAT              /* the DAC volume, attenuation 0 */
    mov     al, 0xA0
    out     dx, al
    mov     si, offset a_mk         /* the marker bytes for wloop */
    mov     di, offset wpat
    mov     cx, 8
    rep     movsb
    call    commit
    mov     byte ptr [a_rep], 1
2:  call    artic_read
    mov     [a_base], eax
    /* the sync */
    xor     ebx, ebx
3:  mov     eax, ebx
    imul    eax, eax, T_HALF
    call    a_wait
    push    ebx
    call    a_burst
    pop     ebx
    inc     ebx
    cmp     ebx, 3
    jb      3b
    /* the cases */
    mov     byte ptr [a_k], 0
4:  movzx   eax, byte ptr [a_k]
    imul    eax, eax, T_SLOT
    add     eax, T_CASE0
    mov     [a_slot], eax
    call    a_wait
    call    a_case
    call    commit
    inc     byte ptr [a_k]
    cmp     byte ptr [a_k], 9
    jb      4b
    mov     eax, T_REP
    call    a_wait
    inc     byte ptr [a_rep]
    cmp     byte ptr [a_rep], 2
    jbe     2b
    mov     dx, P_CTL
    mov     al, A_CTL
    out     dx, al
    ret

/* a_wait: until EAX ARTIC ticks after [a_base] (interrupts on) */
a_wait:
    push    ebx
    mov     ebx, eax
1:  call    artic_read
    sub     eax, [a_base]
    and     eax, 0xFFFFFF
    cmp     eax, ebx
    jb      1b
    pop     ebx
    ret

/* a_reset: stopped at 4134 Hz, FIFO reset (07, 0F, 07), the 16-bit stereo format */
a_reset:
    mov     dx, P_CTL
    mov     al, A_CTL
    out     dx, al
    call    iodly
    mov     al, A_CTL | 0x08
    out     dx, al
    call    iodly
    mov     al, A_CTL
    out     dx, al
    call    iodly
    mov     dx, P_DAC
    mov     al, [dac_cur]
    out     dx, al
    call    iodly
    ret

/* a_burst: one sync burst: 1024 frames 70 00 70 00 / 90 00 90 00, played to empty (0.4 s bound) */
a_burst:
    cli
    call    a_reset
    mov     dx, P_DATA
    mov     cx, 1024
1:  mov     al, 0x70
    test    cl, 1
    jz      2f
    mov     al, 0x90
2:  out     dx, al
    mov     ah, al
    xor     al, al
    out     dx, al
    mov     al, ah
    out     dx, al
    xor     al, al
    out     dx, al
    loop    1b
    sti
    mov     dx, P_CTL
    mov     al, A_PLAY
    out     dx, al
    call    artic_read
    mov     ebx, eax
3:  mov     dx, P_STAT
    in      al, dx
    test    al, 0x40
    jnz     4f
    call    artic_read
    sub     eax, ebx
    and     eax, 0xFFFFFF
    cmp     eax, 122880
    jb      3b
4:  call    a_reset
    ret

/* a_case: case [a_k] in the slot [a_slot] */
a_case:
    movzx   si, byte ptr [a_k]
    movzx   ecx, byte ptr [a_dtab + si]
    mov     [run_d], ecx
    mov     word ptr [w_logn], 0
    mov     dword ptr [d_emp], 0xFFFFFFFF
    cli
    call    a_reset
    /* S, with 0xA466 read after every byte: [cap] = the count after which bit 7 first read 1 */
    mov     dword ptr [cap], 0
    xor     ebx, ebx                /* the frame */
1:  call    a_frame                 /* EDX = the four bytes, the first in DL */
    mov     cx, 4
2:  mov     al, dl
    push    dx
    mov     dx, P_DATA
    out     dx, al
    mov     dx, P_STAT
    in      al, dx
    pop     dx
    test    al, 0x80
    jz      3f
    cmp     dword ptr [cap], 0
    jne     3f
    lea     eax, [ebx * 4 + 5]
    sub     ax, cx                  /* the 1-based byte count: 4 i + (5 - cx) */
    movzx   eax, ax
    mov     [cap], eax
3:  shr     edx, 8
    loop    2b
    inc     ebx
    cmp     ebx, A_SFRAMES
    jb      1b
    mov     dx, P_STAT
    in      al, dx
    mov     [pre], al
    cmp     dword ptr [cap], 32768
    je      4f
    sti
    call    a_reset
    mov     dx, offset s_a_skip
    call    a_row
    ret
4:  mov     ecx, [run_d]
    call    wloop
    sti
    mov     eax, [a_slot]
    add     eax, T_HALF
    call    a_wait
    call    artic_read
    mov     [d_t0], eax
    mov     dx, P_CTL
    mov     al, A_PLAY
    out     dx, al
5:  mov     dx, P_STAT
    in      al, dx
    test    al, 0x40
    jnz     6f
    call    artic_read
    sub     eax, [a_base]
    and     eax, 0xFFFFFF
    mov     ebx, [a_slot]
    add     ebx, T_STOP
    cmp     eax, ebx
    jb      5b
    jmp     7f
6:  call    artic_read
    sub     eax, [d_t0]
    and     eax, 0xFFFFFF
    mov     [d_emp], eax
    add     eax, T_TAIL             /* play on 0.1 s past the flag */
    mov     ebx, eax
61: call    artic_read
    sub     eax, [d_t0]
    and     eax, 0xFFFFFF
    cmp     eax, ebx
    jb      61b
7:  call    a_reset
    mov     dx, offset s_a_row
    call    a_row
    ret

/* a_frame: EBX = frame i of S -> EDX = its bytes, the first (L high) in DL */
a_frame:
    push    ax
    push    bx
    push    cx
    mov     ax, bx
    and     ax, 1                   /* the alternation: 1 on odd frames */
    mov     cx, bx
    cmp     bx, A_HEAD
    jb      1f
    cmp     bx, A_SFRAMES - A_HEAD
    jb      2f
    sub     cx, A_SFRAMES - 2 * A_HEAD  /* the tail: table bits 48..95 */
1:  mov     bx, cx                  /* the table bit: 1 = minus */
    shr     bx, 3
    mov     al, [a_prbs + bx]
    and     cl, 7
    shr     al, cl
    and     al, 1
2:  pop     cx
    pop     bx
    push    bx
    push    cx
    mov     ah, 0x30                /* L high */
    test    al, al
    jz      3f
    mov     ah, 0xD0
3:  mov     cl, 0x40                /* R high = R low */
    test    bl, 1
    jz      4f
    mov     cl, 0xC0
4:  xor     edx, edx
    mov     dl, cl
    mov     dh, cl
    shl     edx, 16
    mov     dl, ah                  /* L high */
    mov     dh, 0x08                /* L low: 08 / F8 with L's sign */
    test    al, al
    jz      5f
    mov     dh, 0xF8
5:
    pop     cx
    pop     bx
    pop     ax
    ret

/* a_row: DX = the tag; "AUD<tag> rep=R k=K d=D cap=N pre=xx empty=T st=..." */
a_row:
    call    puts
    mov     dx, offset s_a_rep
    call    puts
    movzx   eax, byte ptr [a_rep]
    call    putdec
    mov     dx, offset s_a_k
    call    puts
    movzx   eax, byte ptr [a_k]
    call    putdec
    mov     dx, offset s_d
    call    puts
    mov     eax, [run_d]
    call    putdec
    mov     dx, offset s_a_cap
    call    puts
    mov     eax, [cap]
    call    putdec
    mov     dx, offset s_pre
    call    puts
    mov     al, [pre]
    call    puthex8
    mov     dx, offset s_empty
    call    puts
    mov     eax, [d_emp]
    call    putdec_or
    mov     dx, offset s_st
    call    puts
    mov     si, offset wlog
    mov     cx, [w_logn]
    jcxz    2f
1:  lodsb
    call    puthex8
    dec     cx
    jz      2f
    call    putsp
    jmp     1b
2:  call    putnl
    ret

/* ======================================================================================== */
/* RESTORE                                                                                   */
/* ======================================================================================== */
restore:
    cli
    mov     al, [f_a46a]
    mov     [dac_cur], al
    call    pcm_reset               /* stopped, IRQ off, FIFO reset, 0xA46A as found */
    mov     dx, P_CTL
    mov     al, C_IRQEN
    out     dx, al
    call    iodly
    mov     dx, P_DAC               /* threshold 00 = 128 bytes */
    xor     al, al
    out     dx, al
    call    iodly
    mov     dx, P_CTL
    xor     al, al
    out     dx, al
    call    iodly
    mov     dx, P_DAC
    mov     al, [f_a46a]
    out     dx, al
    call    iodly
    mov     dx, P_CTL
    mov     al, [f_a468]
    and     al, 0xEF                /* bit 4 written 0: no flag left set */
    out     dx, al
    call    iodly
    mov     al, 0x0B
    out     SPIC_CMD, al
    mov     al, [f_imrs]
    out     SPIC_IMR, al
    sti
    mov     dx, offset s_rs_a468
    call    puts
    mov     al, [f_a468]
    call    puthex8
    mov     dx, offset s_now
    call    puts
    mov     dx, P_CTL
    in      al, dx
    mov     bl, al
    call    puthex8
    mov     al, [f_a468]
    xor     al, bl
    and     al, 0xEF
    call    put_okdiff
    mov     dx, offset s_rs_a46a
    call    puts
    mov     al, [f_a46a]
    call    puthex8
    mov     dx, offset s_now
    call    puts
    mov     dx, P_DAC
    in      al, dx
    mov     bl, al
    call    puthex8
    mov     al, [f_a46a]
    xor     al, bl
    call    put_okdiff
    mov     dx, offset s_rs_imrs
    call    puts
    mov     al, [f_imrs]
    call    puthex8
    mov     dx, offset s_now
    call    puts
    in      al, SPIC_IMR
    mov     bl, al
    call    puthex8
    mov     al, [f_imrs]
    xor     al, bl
    call    put_okdiff
    mov     dx, offset s_rs_a466
    call    puts
    mov     dx, P_STAT
    in      al, dx
    call    puthex8
    call    putnl
    ret

put_okdiff:
    mov     dx, offset s_ok
    test    al, al
    jz      1f
    mov     dx, offset s_diff
1:  call    puts
    ret

/* ======================================================================================== */
/* common                                                                                    */
/* ======================================================================================== */
/* commit: INT 21h AH=68h on stdout, so a capture redirected to a file reaches the disk (a
 * character device answers an error, harmlessly) */
commit:
    push    ax
    push    bx
    mov     ah, 0x68
    mov     bx, 1
    int     0x21
    pop     bx
    pop     ax
    ret

iodly:
    push    ax
    xor     al, al
    out     0x5F, al
    out     0x5F, al
    pop     ax
    ret

artic_read:                     /* EAX = 24-bit ARTIC count (crt31k.s's reader) */
    push    dx
    push    ebx
    push    ecx
    mov     dx, 0x005F
    in      al, dx
    movzx   ebx, al
    mov     dx, 0x005C
    in      ax, dx
    movzx   ecx, ax
    mov     dx, 0x005F
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

/* putdec_or: EAX decimal, or "-" for FFFFFFFF */
putdec_or:
    cmp     eax, 0xFFFFFFFF
    jne     putdec
    push    dx
    mov     dx, offset s_dash
    call    puts
    pop     dx
    ret
/* putdec: EAX unsigned decimal */
putdec:
    push    eax
    push    ebx
    push    cx
    push    edx
    mov     ebx, 10
    xor     cx, cx
1:  xor     edx, edx
    div     ebx
    push    dx
    inc     cx
    test    eax, eax
    jnz     1b
2:  pop     dx
    add     dl, '0'
    call    putc
    loop    2b
    pop     edx
    pop     cx
    pop     ebx
    pop     eax
    ret

puthex8:
    push    ax
    push    dx
    push    ax
    shr     al, 4
    call    1f
    pop     ax
    and     al, 0x0F
    call    1f
    pop     dx
    pop     ax
    ret
1:  add     al, '0'
    cmp     al, '9'
    jbe     2f
    add     al, 7
2:  mov     dl, al
putc:
    push    ax
    mov     ah, 0x02
    int     0x21
    pop     ax
    ret
putsp:
    push    dx
    mov     dl, ' '
    call    putc
    pop     dx
    ret
putnl:
    push    dx
    mov     dx, offset s_nl
    call    puts
    pop     dx
    ret
puts:
    push    ax
    mov     ah, 0x09
    int     0x21
    pop     ax
    ret

/* ======================================================================================== */
/* data                                                                                      */
/* ======================================================================================== */
s_hdr:      .ascii "PCMOVF v1 rate=44100 thr_drain=3F play_w=2048 artic=307200\r\n$"
s_hdr_a:    .ascii "PCMAUD v1 stage 2: rate=4134 fmt=16-bit-stereo vol=A0 reps=2 slot=3.0s artic=307200\r\n$"
s_a_dac:    .ascii "AUD dac=$"
s_a_row:    .ascii "AUD$"
s_a_skip:   .ascii "AUD SKIP cap$"
s_a_rep:    .ascii " rep=$"
s_a_k:      .ascii " k=$"
s_a_cap:    .ascii " cap=$"
s_state:    .ascii "STATE a460=$"
s_a466:     .ascii " a466=$"
s_a468:     .ascii " a468=$"
s_a46a:     .ascii " a46a=$"
s_imrs:     .ascii " imrs=$"
s_dac8:     .ascii " dac8=$"
s_absent:   .ascii "PCMOVF SKIP absent (A460 reads FF)\r\n$"
s_playing:  .ascii "PCMOVF SKIP playing (A468 bit 7 set: a driver is active)\r\n$"
s_nofull:   .ascii "PCMOVF SKIP nofull (FILL never read full)\r\n$"
s_done:     .ascii "PCMOVF DONE\r\n$"
s_nl:       .ascii "\r\n$"
s_dash:     .ascii "-$"
s_b_fill:   .ascii "BEGIN:FILL\r\n$"
s_e_fill:   .ascii "END:FILL\r\n$"
s_fill_n:   .ascii "FILL n=$"
s_fill_ff:  .ascii "FILL first_full=$"
s_fne:      .ascii " first_notempty=$"
s_writes:   .ascii " writes=$"
s_art:      .ascii " art=$"
s_tmo:      .ascii " tmo=$"
s_b_wcost:  .ascii "BEGIN:WCOST\r\n$"
s_e_wcost:  .ascii "END:WCOST\r\n$"
s_wcost:    .ascii "WCOST n=1024 art=$"
s_full:     .ascii " full=$"
s_b_cal:    .ascii "BEGIN:CAL\r\n$"
s_e_cal:    .ascii "END:CAL\r\n$"
s_dr_cal:   .ascii "DRAIN CAL$"
s_dr_play:  .ascii "DRAIN PLAY$"
s_dr_ovf:   .ascii "DRAIN OVF$"
s_skip:     .ascii " SKIP nodrain\r\n$"
s_dac:      .ascii " dac=$"
s_n:        .ascii " n=$"
s_d:        .ascii " d=$"
s_tr:       .ascii " tr=$"
s_st0:      .ascii " st0=$"
s_nf:       .ascii " nf=$"
s_irq:      .ascii " irq=$"
s_irr:      .ascii " irr=$"
s_empty:    .ascii " empty=$"
s_polls:    .ascii " polls=$"
s_b_thr:    .ascii "BEGIN:THR\r\n$"
s_e_thr:    .ascii "END:THR\r\n$"
s_thr:      .ascii "THR v=$"
s_thr_t:    .ascii " t=$"
s_raw:      .ascii " raw=$"
s_clr:      .ascii " clr=$"
s_irrs:     .ascii " irr=$"
s_b_play:   .ascii "BEGIN:PLAY\r\n$"
s_e_play:   .ascii "END:PLAY\r\n$"
s_play:     .ascii "PLAY$"
s_play_skip: .ascii "PLAY SKIP nodrain\r\n$"
s_stall:    .ascii "PLAY STALL (a write past full waits: OVF skipped)\r\n$"
s_b_ovf:    .ascii "BEGIN:OVF\r\n$"
s_e_ovf:    .ascii "END:OVF\r\n$"
s_ovf:      .ascii "OVF$"
s_rowmark:  .ascii " ROW d=$"
s_ovf_stall: .ascii "OVF SKIP stall\r\n$"
s_pre:      .ascii " pre=$"
s_c:        .ascii " a468=$"
s_fnf:      .ascii " fnf=$"
s_st:       .ascii " st=$"
s_rs_a468:  .ascii "RESTORE A468 was=$"
s_rs_a46a:  .ascii "RESTORE A46A was=$"
s_rs_imrs:  .ascii "RESTORE IMRS was=$"
s_rs_a466:  .ascii "RESTORE A466 now=$"
s_now:      .ascii " now=$"
s_ok:       .ascii " OK\r\n$"
s_diff:     .ascii " DIFF\r\n$"

    .balign 4
fsn_n:      .long 0, 1, 32767, 32768
/* CAL: .long n, .byte 0 = the 8-bit mono format / 1 = the as-found format; 0 ends */
cal_tab:    .long 4096
            .byte 0
            .long 16384
            .byte 0
            .long 24576
            .byte 0
            .long 16384
            .byte 1
            .long 0
            .byte 0
/* THR: .byte 1, v; .long T (the threshold in bytes, NP2kai's (v + 1) << 7, FF = 0x7FFC); 0 ends */
thr_tab:    .byte 1, 0x7F
            .long 16384
            .byte 1, 0xFE
            .long 32640
            .byte 1, 0xFF
            .long 32764
            .byte 0
ovf_tab:    .byte 0, 1, 2, 3, 4, 5, 8, 64, 0xFF
/* stage 2: the cases' depths; the marker bytes; the L sign table (pcm86ovf_audio.py PRBS) */
a_dtab:     .byte 0, 1, 2, 3, 4, 5, 8, 64, 0
a_mk:       .byte 0x70, 0x00, 0x90, 0x00, 0x90, 0x00, 0x70, 0x00
a_prbs:     .byte 0x1B, 0x4B, 0x77, 0xA6, 0xFA, 0x03, 0xC1, 0x50, 0x3C, 0xD1, 0x5C, 0xF9

    .balign 4
cap:        .long 0
a_base:     .long 0
a_slot:     .long 0
f_ne:       .long 0
f_n:        .long 0
t0:         .long 0
t_el:       .long 0
wcost:      .long 0
run_n:      .long 0
run_d:      .long 0
thr_t:      .long 0
w_t0:       .long 0
w_art:      .long 0
w_full:     .long 0
w_fnf:      .long 0
d_t0:       .long 0
d_nf:       .long 0
d_irq:      .long 0
d_irr:      .long 0
d_emp:      .long 0
d_polls:    .long 0
w_logn:     .word 0
thr_cnt:    .word 0
fsnap:      .word 0, 0, 0, 0, 0, 0, 0, 0
f_a460:     .byte 0
f_a466:     .byte 0
f_a468:     .byte 0
f_a46a:     .byte 0
f_imrs:     .byte 0
dac8:       .byte 0
dac_cur:    .byte 0
f_tmo:      .byte 0
d_tmo:      .byte 0
d_st0:      .byte 0
nodrain:    .byte 0
stall:      .byte 0
trial:      .byte 0
pre:        .byte 0
ovf_c:      .byte 0
thr_v:      .byte 0
mode_a:     .byte 0
a_rep:      .byte 0
a_k:        .byte 0
wpat:       .fill 8, 1, 0
wlog:       .fill LOGMAX, 1, 0
thr_log:    .fill 24 * 6, 1, 0

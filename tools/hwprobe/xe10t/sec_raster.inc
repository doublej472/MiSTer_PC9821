/* sec_raster.inc - /RASTER (opt-in, VISUAL): when a palette write reaches the screen.
 *
 * The palette registers are not a timing the CPU can read back: the answer is on the
 * screen. This section paints a picture for a camera or a capture card and logs, per phase,
 * where in the frame its writes landed (ARTIC ticks after the master GDC's VSYNC rising
 * edge) and how long its write bursts took, so xe10t_decode.py can say which raster line and
 * how many dots each feature should span. Run it on its own (`XE10T /RASTER`), from a clean
 * screen (`CLS`), and photograph or capture the screen during each 5-second phase.
 *
 * Setup: EGC/GRCG off, both GVRAM pages cleared to index 0 (all four planes), graphics GDC
 * START (0xA2 <- 0x0D). Every graphics dot is then palette entry 0, so entry 0's colour is
 * the whole graphics area; the text plane is left as it is (CLS first).
 *
 * Phases, each 5 s of frames; every frame: cli, wait for the VSYNC rising edge (0x60 bit 5),
 * the frame's writes, sti.
 *   SPLIT   (16-colour analogue, 0x6A <- 01). At the edge entry 0 = red (0xA8=0, G=0, R=F,
 *           B=0); RAS_SPLIT ticks later (about half a frame) entry 0 = green, written G=F
 *           first, then R=0, then B=0. The screen: red above the split line, green below
 *           (Lemmings' briefing shape). A frame-latched palette shows ONE colour for the
 *           whole screen instead. Between the G and the R write entry 0 is yellow for one
 *           `out` time, so a DAC that takes a write at once shows a short yellow dash on the
 *           split line, where one that takes it at a line boundary shows a clean edge.
 *   TOGGLE  (analogue). At the edge entry 0 = grey (4,4,4); RAS_TSTART ticks later the blue
 *           channel alone is toggled F/0 RAS_TOGGLES times (`out 0xAE`), then put back to 4.
 *           The screen, inside a band of lines: a dot-immediate DAC shows short dashes of
 *           (4,4,F) and (4,4,0) along each line, each dash one `out` long (the decoder gives
 *           the length in dots) and staggered from line to line; a palette taken at each
 *           line boundary shows whole lines of one or the other; a frame-latched palette
 *           shows no band at all (plain grey).
 *   DTOGGLE (8-colour digital, 0x6A <- 00). The same band with 0xAE toggled 0x14/0x04
 *           (digital entry 0 blue/black, entry 4 green kept): the same three pictures for the
 *           digital palette.
 *
 * Restore: analogue entry 0 to the ITF power-on 000, the digital bytes to their defaults
 * 37/15/26/04, the colour mode to the as-found 0x9A0 query 0x04 bit (readback). The graphics
 * GDC is left started over the cleared, entry-0-black GVRAM (invisible); GVRAM is not saved:
 * reboot afterwards if its picture matters.
 */
    .equ RAS_PHASE,    1536000          /* 5 s of frames per phase, ARTIC ticks */
    .equ RAS_SPLIT,    2722             /* the split write, ticks after the VSYNC edge (half a frame) */
    .equ RAS_TSTART,   1800             /* the toggle band's start, ticks after the VSYNC edge */
    .equ RAS_TOGGLES,  512              /* out pairs per band: 1024 writes */

tc_raster:  .asciz "GVRAM-B/R/G/E pages 0,1(cleared) 0xA6=01/00 0xA2=0D(START) 0x6A=01,00(as found after) 0xA8-0xAE(entry 0; 000 and 37/15/26/04 after) VISUAL 15 s"
n_rasq04:   .asciz "q04_colour_mode"
n_rasent0:  .asciz "PAL_ANALOG_ENTRY0"
n_rasdig:   .asciz "PAL_DIGITAL"
n_rasgdc:   .asciz "GDC2_START"
tg_split:   .asciz "SPLIT"
tg_toggle:  .asciz "TOGGLE"
tg_dtoggle: .asciz "DTOGGLE"
k_frames:   .asciz "frames"
k_rto:      .asciz "to"
k_atmin:    .asciz "at_min"
k_atmax:    .asciz "at_max"
k_atsum:    .asciz "at_sum"
k_dmin:     .asciz "dur_min"
k_dmax:     .asciz "dur_max"
k_dsum:     .asciz "dur_sum"
k_outs:     .asciz "outs"
k_target:   .asciz "target"

sec_raster:
    mov     si, offset nm_raster
    mov     eax, WD_60S
    mov     bx, offset ras_exit
    call    sec_begin
    call    gfx_off
    mov     al, 0x04
    call    query9a0
    mov     byte ptr [ras_q04], al
    mov     byte ptr [ras_on], 1
    mov     si, offset k_STATE
    call    info_start
    PS      "visual q04="
    mov     al, byte ptr [ras_q04]
    call    out_x2
    PS      " lines_per_frame=440 vsync_line=407"
    call    out_nl
    call    ras_clear
    mov     al, 0x0D                    /* graphics GDC START */
    out     0xA2, al

    /* SPLIT, analogue */
    mov     al, 0x01
    out     0x6A, al
    mov     word ptr [ras_fn], offset ras_split
    mov     word ptr [ras_tag], offset tg_split
    mov     dword ptr [ras_tgt], RAS_SPLIT
    call    ras_phase
    /* TOGGLE, analogue */
    mov     word ptr [ras_fn], offset ras_toggle
    mov     word ptr [ras_tag], offset tg_toggle
    mov     dword ptr [ras_tgt], RAS_TSTART
    call    ras_phase
    /* DTOGGLE, digital */
    mov     al, 0x00
    out     0x6A, al
    mov     word ptr [ras_fn], offset ras_dtoggle
    mov     word ptr [ras_tag], offset tg_dtoggle
    call    ras_phase
ras_exit:
    call    sec_disarm
    cmp     byte ptr [ras_on], 0
    je      1f
    mov     byte ptr [ras_on], 0
    mov     al, 0x01                    /* analogue: entry 0 back to the ITF 000 */
    out     0x6A, al
    xor     al, al
    out     0xA8, al
    out     0xAA, al
    out     0xAC, al
    out     0xAE, al
    mov     al, 0x00                    /* digital: the power-on bytes */
    out     0x6A, al
    mov     al, 0x37
    out     0xA8, al
    mov     al, 0x15
    out     0xAA, al
    mov     al, 0x26
    out     0xAC, al
    mov     al, 0x04
    out     0xAE, al
    mov     al, byte ptr [ras_q04]
    and     al, 1
    out     0x6A, al                    /* FF2 num 0 back to the as-found colour mode */
1:  mov     si, offset n_rasent0
    xor     eax, eax
    call    rs_default
    mov     si, offset n_rasdig
    push    bx
    push    cx
    push    edx
    mov     eax, 0x37152604
    mov     edx, eax
    mov     cx, 0x0108
    mov     bl, 2
    call    rs_line
    pop     edx
    pop     cx
    pop     bx
    mov     si, offset n_rasgdc
    mov     eax, 0x0D
    call    rs_default
    mov     al, 0x04
    call    query9a0
    movzx   edx, al
    movzx   eax, byte ptr [ras_q04]
    mov     si, offset n_rasq04
    mov     cx, 0x0002
    mov     bl, 3
    call    rs_line
    call    gfx_restore_common
    call    sec_end
    ret

/* ras_clear: GVRAM pages 0 and 1, planes B/R/G/E, to zero (index 0 everywhere). */
ras_clear:
    push    es
    mov     al, 0
1:  out     0xA6, al
    push    ax
    mov     bx, offset ras_segs
2:  mov     ax, word ptr [bx]
    test    ax, ax
    jz      3f
    mov     es, ax
    xor     di, di
    xor     ax, ax
    mov     cx, 16384
    rep     stosw
    add     bx, 2
    jmp     2b
3:  pop     ax
    inc     al
    cmp     al, 2
    jb      1b
    mov     al, 0
    out     0xA6, al
    pop     es
    ret
ras_segs:   .word 0xA800, 0xB000, 0xB800, 0xE000, 0

/* ras_vsync: wait for the master GDC's VSYNC (0x60 bit 5) low, then its rising edge, each
 * poll bounded by 8 x 65535 reads; [ras_v] = the ARTIC just after the edge. CF = timeout. */
ras_vsync:
    push    cx
    push    dx
    mov     dx, 8
1:  mov     cx, 0xFFFF
2:  in      al, 0x60
    test    al, 0x20
    jz      3f
    loop    2b
    dec     dx
    jnz     1b
    jmp     8f
3:  mov     dx, 8
4:  mov     cx, 0xFFFF
5:  in      al, 0x60
    test    al, 0x20
    jnz     6f
    loop    5b
    dec     dx
    jnz     4b
    jmp     8f
6:  call    artic_read
    mov     dword ptr [ras_v], eax
    clc
    jmp     9f
8:  stc
9:  pop     dx
    pop     cx
    ret

/* ras_until: spin until [ras_tgt] ticks have passed since [ras_v]; EAX = the ticks at exit. */
ras_until:
1:  mov     eax, dword ptr [ras_v]
    call    artic_since
    cmp     eax, dword ptr [ras_tgt]
    jb      1b
    ret

/* ras_stat: EAX = the frame's write offset, EBX = its burst duration (0: none). */
ras_stat:
    cmp     eax, dword ptr [ras_atmin]
    jae     1f
    mov     dword ptr [ras_atmin], eax
1:  cmp     eax, dword ptr [ras_atmax]
    jbe     2f
    mov     dword ptr [ras_atmax], eax
2:  add     dword ptr [ras_atsum], eax
    cmp     ebx, dword ptr [ras_dmin]
    jae     3f
    mov     dword ptr [ras_dmin], ebx
3:  cmp     ebx, dword ptr [ras_dmax]
    jbe     4f
    mov     dword ptr [ras_dmax], ebx
4:  add     dword ptr [ras_dsum], ebx
    ret

/* ras_phase: [ras_fn] once per frame for RAS_PHASE ticks, then its P row. */
ras_phase:
    xor     eax, eax
    mov     dword ptr [ras_frames], eax
    mov     dword ptr [ras_to], eax
    mov     dword ptr [ras_atsum], eax
    mov     dword ptr [ras_atmax], eax
    mov     dword ptr [ras_dsum], eax
    mov     dword ptr [ras_dmax], eax
    dec     eax
    mov     dword ptr [ras_atmin], eax
    mov     dword ptr [ras_dmin], eax
    mov     si, word ptr [ras_tag]
    call    con_s
    mov     si, offset con_sp
    call    con_s
    call    artic_read
    mov     dword ptr [ras_t0], eax
1:  call    wd_check
    cli
    call    ras_vsync
    jc      2f
    call    word ptr [ras_fn]
    call    ras_stat
    inc     dword ptr [ras_frames]
    jmp     3f
2:  inc     dword ptr [ras_to]
3:  sti
    nop
    mov     eax, dword ptr [ras_t0]
    call    artic_since
    cmp     eax, RAS_PHASE
    jb      1b
    mov     si, offset k_P
    call    row_start
    mov     si, word ptr [ras_tag]
    call    out_s
    mov     eax, dword ptr [ras_frames]
    mov     si, offset k_frames
    call    out_kd
    mov     eax, dword ptr [ras_to]
    mov     si, offset k_rto
    call    out_kd
    mov     eax, dword ptr [ras_tgt]
    mov     si, offset k_target
    call    out_kd
    mov     eax, dword ptr [ras_atmin]
    mov     si, offset k_atmin
    call    out_kd
    mov     eax, dword ptr [ras_atmax]
    mov     si, offset k_atmax
    call    out_kd
    mov     eax, dword ptr [ras_atsum]
    mov     si, offset k_atsum
    call    out_kd
    mov     eax, dword ptr [ras_dmin]
    mov     si, offset k_dmin
    call    out_kd
    mov     eax, dword ptr [ras_dmax]
    mov     si, offset k_dmax
    call    out_kd
    mov     eax, dword ptr [ras_dsum]
    mov     si, offset k_dsum
    call    out_kd
    mov     eax, RAS_TOGGLES * 2
    mov     si, offset k_outs
    call    out_kd
    call    out_nl
    ret

/* The per-frame bodies: EAX = the write offset (ticks after the edge), EBX = the burst. */
ras_split:
    xor     al, al                      /* entry 0 = red */
    out     0xA8, al
    out     0xAA, al
    mov     al, 0x0F
    out     0xAC, al
    xor     al, al
    out     0xAE, al
    call    ras_until
    push    eax
    call    artic_read
    mov     ebx, eax
    xor     al, al                      /* entry 0 = green: G first, then R, then B */
    out     0xA8, al
    mov     al, 0x0F
    out     0xAA, al
    xor     al, al
    out     0xAC, al
    out     0xAE, al
    mov     eax, ebx
    call    artic_since
    mov     ebx, eax
    pop     eax
    ret

ras_toggle:
    xor     al, al                      /* entry 0 = grey (4,4,4) */
    out     0xA8, al
    mov     al, 0x04
    out     0xAA, al
    out     0xAC, al
    out     0xAE, al
    call    ras_until
    push    eax
    call    artic_read
    mov     ebx, eax
    mov     cx, RAS_TOGGLES
1:  mov     al, 0x0F
    out     0xAE, al
    xor     al, al
    out     0xAE, al
    loop    1b
    mov     al, 0x04
    out     0xAE, al
    mov     eax, ebx
    call    artic_since
    mov     ebx, eax
    pop     eax
    ret

ras_dtoggle:
    mov     al, 0x04                    /* digital entry 0 black, entry 4 green */
    out     0xAE, al
    call    ras_until
    push    eax
    call    artic_read
    mov     ebx, eax
    mov     cx, RAS_TOGGLES
1:  mov     al, 0x14
    out     0xAE, al
    mov     al, 0x04
    out     0xAE, al
    loop    1b
    mov     eax, ebx
    call    artic_since
    mov     ebx, eax
    pop     eax
    ret

    VARS
    .p2align 2
ras_v:      .long 0
ras_t0:     .long 0
ras_tgt:    .long 0
ras_frames: .long 0
ras_to:     .long 0
ras_atmin:  .long 0
ras_atmax:  .long 0
ras_atsum:  .long 0
ras_dmin:   .long 0
ras_dmax:   .long 0
ras_dsum:   .long 0
ras_fn:     .word 0
ras_tag:    .word 0
ras_q04:    .byte 0
ras_on:     .byte 0
    ENDVARS

/* txtmode.s - the text plane's row geometry: 20/25/30 lines, display partitions, smooth scroll.
 *
 * THE QUESTION. The master GDC (0x60/0x62) and the CRTC (0x70-0x7A) together decide which TRAM
 * row each raster line shows and which line of the glyph: the GDC's LR (CSRFORM byte 0) and its
 * four PRAM display partitions, the CRTC's PL/BL/CL row geometry and its SSL/SUR/SDR smooth
 * scroll. This probe puts the SAME fixed pattern on the screen under seven settings and waits
 * for a key in each, so a photograph or capture of each state on a real PC-9821 can be laid
 * next to the core's screenshot of the same state. It measures nothing itself; the pictures
 * are the result.
 *
 * THE PATTERN. TRAM rows 0-49 (words 0-3999) each hold: "Rnn " (the row number), the kanji pair
 * 0x3441 0x3B7A (two double-width characters), a column ruler 0-9 repeated over columns 9-58,
 * ten underlined 'U' cells (60-69) and ten reverse-video 'V' cells (70-79), in one of seven
 * colours by row. Row 0, columns 40-58, carries the state's name. The reverse cells make a
 * row's blank lines visible (they fill solid), the underline marks a row's last line.
 *
 * THE STATES (a key advances; every state is set up the same way each run):
 *   1  25 lines     INT 18h AH=0Ah AL=00h, one partition (PRAM start 0, 400 lines)
 *   2  20 lines     INT 18h AH=0Ah AL=01h, the same partition
 *   3  30 lines     the 25-line CRTC rows, a 480-line master SYNC block (defsyncm24 with lf =
 *                   480: 10 4E 07 25 07 07 E0 65, 520 lines, ~47.7 Hz - NOT a BIOS mode on the
 *                   24 kHz Xe10; a real monitor may not lock to it), one 480-line partition
 *   4  2 partitions rows 0-9 of TRAM (160 lines), then TRAM rows 25-39 (from word 2000)
 *   5  4 partitions TRAM row 0 (80 lines) / word 2000 (100 lines, ends mid-row) / word 800
 *                   (120 lines) / word 2800 (100 lines)
 *   6  smooth scroll SUR 0, SDR 24, one partition; animated at VSYNC through 55 steps (SSL
 *                   0..15, then the start word +80 per row) and left at start word 240, SSL 7
 *   7  scroll region SUR 29 (3 fixed rows), SDR 9, SSL 6, start word 0
 * Then it restores: the CRTC registers as found, the default SYNC block (state 3 only), 25
 * lines and one partition through the BIOS, a blank screen, and prints its log to stdout.
 *
 * Build: make -C tools/hwprobe txtmode/txtmode.com
 * Run:   TXTMODE > TXTMODE.TXT     (from a freshly booted DOS prompt; press a key per state)
 *        TXTMODE /T                (timed: each state held 450 VSYNCs, ~8 s, for unattended
 *                                   screenshots - the core's regression runner uses this)
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

_start:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    cld
    /* "/T" anywhere in the command tail: timed states instead of keys. */
    mov     si, 0x81
    xor     ch, ch
    mov     cl, [0x80]
    jcxz    0f
18: lodsb
    cmp     al, '/'
    jne     19f
    mov     al, [si]
    and     al, 0xDF
    cmp     al, 'T'
    jne     19f
    mov     byte ptr [timed], 1
19: loop    18b
0:
    /* The CRTC render registers as found (they read back on the Xe10, RDBACK.TXT:82-87). */
    mov     si, offset crtc_ports
    mov     di, offset crtc_found
    mov     cx, 6
1:  lodsb
    mov     dl, al
    xor     dh, dh
    in      al, dx
    stosb
    loop    1b

    call    fill_pattern

    /* ---- 1: 25 lines ---- */
    mov     al, 0x00
    call    bios_mode
    call    one_partition_400
    mov     si, offset t_s1
    call    title
    call    waitkey

    /* ---- 2: 20 lines ---- */
    mov     al, 0x01
    call    bios_mode
    call    one_partition_400
    mov     si, offset t_s2
    call    title
    call    waitkey

    /* ---- 3: 30 lines ---- */
    mov     al, 0x00
    call    bios_mode
    mov     si, offset sync480
    call    gdc_sync
    mov     si, offset pram_480
    call    gdc_pram
    mov     si, offset t_s3
    call    title
    call    waitkey
    mov     si, offset sync400          /* the default block back before anything else */
    call    gdc_sync

    /* ---- 4: two partitions ---- */
    mov     al, 0x00
    call    bios_mode
    mov     si, offset pram_two
    call    gdc_pram
    mov     si, offset t_s4
    call    title
    call    waitkey

    /* ---- 5: four partitions ---- */
    mov     si, offset pram_four
    call    gdc_pram
    mov     si, offset t_s5
    call    title
    call    waitkey

    /* ---- 6: smooth scroll, animated, then held ---- */
    call    one_partition_400
    mov     si, offset t_s6
    call    title
    mov     al, 0
    out     0x76, al                    /* SSL 0 */
    out     0x78, al                    /* SUR 0 */
    mov     al, 24
    out     0x7A, al                    /* SDR 24: rows 0-24 scroll */
    xor     bx, bx                      /* step 0 .. 55 */
2:  call    waitvsync
    mov     al, bl
    and     al, 0x0F
    out     0x76, al                    /* SSL = step & 15 */
    mov     ax, bx
    shr     ax, 4
    mov     cx, 80
    mul     cx                          /* start word = (step >> 4) * 80 */
    mov     [pram_scr0], ax
    mov     si, offset pram_scr
    call    gdc_pram
    inc     bx
    cmp     bx, 56                      /* last step 55: start word 240, SSL 7 */
    jb      2b
    call    waitkey

    /* ---- 7: a scroll region under a fixed band ---- */
    mov     word ptr [pram_scr0], 0
    mov     si, offset pram_scr
    call    gdc_pram
    mov     al, 29
    out     0x78, al                    /* SUR 29: 32 - 29 = 3 rows above the region */
    mov     al, 9
    out     0x7A, al                    /* SDR 9 */
    mov     al, 6
    out     0x76, al                    /* SSL 6 */
    mov     si, offset t_s7
    call    title
    call    waitkey

    /* ---- restore ---- */
    mov     si, offset crtc_ports
    mov     di, offset crtc_found
    mov     cx, 6
3:  lodsb
    mov     dl, al
    xor     dh, dh
    mov     al, [di]
    inc     di
    out     dx, al
    loop    3b
    mov     al, 0x00
    call    bios_mode
    call    one_partition_400
    call    clear_tram

    /* ---- the log (stdout) ---- */
    mov     dx, offset s_banner
    call    puts
    mov     dx, offset s_found
    call    puts
    mov     si, offset crtc_found
    mov     cx, 6
4:  lodsb
    call    puthex8
    mov     dl, ' '
    call    putc
    loop    4b
    call    putnl
    mov     dx, offset s_done
    call    puts
    mov     ax, 0x4C00
    int     0x21

/* ---- INT 18h AH=0Ah: AL = mode (bit 0 = 20 lines); then AH=0Ch (text display on) ---- */
bios_mode:
    mov     ah, 0x0A
    int     0x18
    mov     ah, 0x0C
    int     0x18
    ret

/* ---- one partition at word 0, 400 lines, the others zero ---- */
one_partition_400:
    mov     word ptr [pram_scr0], 0
    mov     si, offset pram_scr
    jmp     gdc_pram

/* ---- the master GDC: wait for room in its FIFO (status bit 1 = full), then write ---- */
gdc_wait:
    push    ax
5:  in      al, 0x60
    test    al, 0x02
    jnz     5b
    pop     ax
    ret
gdc_cmd:                                /* AL = command */
    call    gdc_wait
    out     0x62, al
    ret
gdc_par:                                /* AL = parameter */
    call    gdc_wait
    out     0x60, al
    ret
/* SI = 8 SYNC bytes: command 0x0F (SYNC, display on), then START (0x0D). */
gdc_sync:
    mov     al, 0x0F
    call    gdc_cmd
    mov     cx, 8
6:  lodsb
    call    gdc_par
    loop    6b
    mov     al, 0x0D
    jmp     gdc_cmd
/* SI = 16 PRAM bytes: command 0x70 (PRAM from byte 0), all four partitions. */
gdc_pram:
    mov     al, 0x70
    call    gdc_cmd
    mov     cx, 16
7:  lodsb
    call    gdc_par
    loop    7b
    ret

/* ---- wait for the start of a VSYNC pulse (master GDC status bit 5) ---- */
waitvsync:
    push    ax
8:  in      al, 0x60
    test    al, 0x20
    jnz     8b
9:  in      al, 0x60
    test    al, 0x20
    jz      9b
    pop     ax
    ret

/* ---- INT 18h AH=00h: wait for a key; or, timed, 450 VSYNCs ---- */
waitkey:
    cmp     byte ptr [timed], 0
    jne     20f
    mov     ah, 0x00
    int     0x18
    ret
20: push    cx
    mov     cx, 450
21: call    waitvsync
    loop    21b
    pop     cx
    ret

/* ---- the pattern: TRAM rows 0-49 ---- */
fill_pattern:
    push    es
    xor     bx, bx                      /* row */
10: /* attribute: colour (row % 7) + 1 in bits 7-5, visible */
    mov     ax, bx
    mov     cl, 7
    div     cl                          /* ah = row % 7 */
    mov     al, ah
    inc     al
    shl     al, 5
    or      al, 0x01
    mov     [rattr], al
    /* di = row * 160 (bytes) */
    mov     ax, bx
    mov     cx, 160
    mul     cx
    mov     di, ax
    /* "Rnn " */
    mov     ax, bx
    mov     cl, 10
    div     cl                          /* al = tens, ah = ones */
    add     ax, 0x3030
    mov     [rdig], ax
    mov     al, 'R'
    call    put_ank
    mov     al, [rdig]
    call    put_ank
    mov     al, [rdig + 1]
    call    put_ank
    mov     al, ' '
    call    put_ank
    /* the kanji pair: left/right cells of JIS 0x3441 and 0x3B7A (low byte = row - 0x20,
       right cell's low byte | 0x80; high byte = the column byte) */
    mov     ax, 0x4114
    call    put_word
    mov     ax, 0x4194
    call    put_word
    mov     ax, 0x7A1B
    call    put_word
    mov     ax, 0x7A9B
    call    put_word
    mov     al, ' '
    call    put_ank
    /* ruler, columns 9-58 */
    mov     cx, 50
    xor     dl, dl
11: mov     al, dl
    add     al, '0'
    call    put_ank
    inc     dl
    cmp     dl, 10
    jb      12f
    xor     dl, dl
12: loop    11b
    mov     al, ' '
    call    put_ank
    /* 'U' x10 underlined, 'V' x10 reverse */
    mov     al, [rattr]
    push    ax
    or      byte ptr [rattr], 0x08
    mov     cx, 10
13: mov     al, 'U'
    call    put_ank
    loop    13b
    pop     ax
    or      al, 0x04
    mov     [rattr], al
    mov     cx, 10
14: mov     al, 'V'
    call    put_ank
    loop    14b
    inc     bx
    cmp     bx, 50
    jb      10b
    pop     es
    ret
/* AL = ANK code at TRAM byte di (code plane), attribute [rattr]; di += 2 */
put_ank:
    xor     ah, ah
put_word:                               /* AX = code word */
    push    es
    push    ax
    mov     ax, 0xA000
    mov     es, ax
    pop     ax
    mov     es:[di], ax
    mov     ax, 0xA200
    mov     es, ax
    mov     al, [rattr]
    mov     es:[di], al
    pop     es
    add     di, 2
    ret

/* SI = 19-character state name, at row 0 columns 40-58 (white) */
title:
    push    bx
    mov     byte ptr [rattr], 0xE1
    mov     di, 80
    mov     cx, 19
15: lodsb
    call    put_ank
    loop    15b
    pop     bx
    ret

/* the whole TRAM plane to spaces, white */
clear_tram:
    mov     byte ptr [rattr], 0xE1
    xor     di, di
    mov     cx, 4000
16: mov     al, ' '
    call    put_ank
    loop    16b
    ret

putc:                                   /* DL = character */
    push    ax
    mov     ah, 0x02
    int     0x21
    pop     ax
    ret
puts:                                   /* DX = '$'-terminated string */
    push    ax
    mov     ah, 0x09
    int     0x21
    pop     ax
    ret
putnl:
    push    dx
    mov     dl, 13
    call    putc
    mov     dl, 10
    call    putc
    pop     dx
    ret
puthexdig:                              /* AL = 0..15 */
    push    ax
    push    dx
    and     al, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     17f
    add     al, 7
17: mov     dl, al
    call    putc
    pop     dx
    pop     ax
    ret
puthex8:                                /* AL */
    push    ax
    push    ax
    shr     al, 4
    call    puthexdig
    pop     ax
    call    puthexdig
    pop     ax
    ret

s_banner:   .ascii "TXTMODE text row geometry states 1-7 (tools/hwprobe/txtmode)\r\n$"
s_found:    .ascii "CRTC 70 72 74 76 78 7A as found: $"
s_done:     .ascii "TXTMODE done: CRTC restored, 25 lines, one partition\r\n$"
t_s1:       .ascii "STATE 1: 25 LINES  "
t_s2:       .ascii "STATE 2: 20 LINES  "
t_s3:       .ascii "STATE 3: 30 LINES  "
t_s4:       .ascii "STATE 4: 2 PARTS   "
t_s5:       .ascii "STATE 5: 4 PARTS   "
t_s6:       .ascii "STATE 6: SCROLL3+7 "
t_s7:       .ascii "STATE 7: SUR29 SSL6"
crtc_ports: .byte 0x70, 0x72, 0x74, 0x76, 0x78, 0x7A
crtc_found: .byte 0, 0, 0, 0, 0, 0
/* SYNC blocks: NP2kai defsyncm24 (io/gdc.c:42) and the same with lf = 480 */
sync400:    .byte 0x10, 0x4E, 0x07, 0x25, 0x07, 0x07, 0x90, 0x65
sync480:    .byte 0x10, 0x4E, 0x07, 0x25, 0x07, 0x07, 0xE0, 0x65
/* PRAM images, four partitions of {start lo, start hi, (lines << 4) lo, (lines << 4) hi} */
pram_scr:
pram_scr0:  .word 0
            .word 400 << 4
            .word 0, 0, 0, 0, 0, 0
pram_480:   .word 0, 480 << 4, 0, 0, 0, 0, 0, 0
pram_two:   .word 0, 160 << 4, 2000, 240 << 4, 0, 0, 0, 0
pram_four:  .word 0, 80 << 4, 2000, 100 << 4, 800, 120 << 4, 2800, 100 << 4
rattr:      .byte 0
timed:      .byte 0
rdig:       .word 0

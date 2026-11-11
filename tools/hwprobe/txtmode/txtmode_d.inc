/* txtmode_d.inc - TXTMODE /D: the pitch questions, then the text geometry states with the pitch
 * held at 80, then an SSL sweep; no keys; a log of every step (todo item 128).
 *
 * WHY. Kit 1's film of `TXTMODE /T` (docs/probes/KIT1-XE10-TXTMODE.TXT is its log) showed every
 * display row starting 2 cells right of the one above from state 3 on: the row advance was 78
 * words after the probe's own SYNC (NP2kai's defsyncm24 block, C/R byte 0x4E) with no PITCH,
 * and it persisted through INT 18h AH=0Ah. The Xe10 BIOS follows each of its SYNC tables with
 * PITCH 0x47,0x50 (BANK7.BIN 0x615E `09 0E 10 4E 07 25 07 07 90 65` then `02 47 50`), MAME
 * upd7220.cpp:1251 loads the pitch from AW on SYNC (`m_pitch = m_aw;`), NP2kai never does.
 * The video lane's KIT 2 REQUEST (.build reports, video-xe10, "KIT 2 REQUEST (item 128)") asks
 * for P1-P7 below first, then kit 1's states 3-7 with PITCH 80 after every SYNC block, then the
 * state-7 SSL sweep.
 *
 * THE STEPS (all from the same TRAM pattern as /T; the step's name is written into rows 0 and 3,
 * columns 40-58, row 3 so that it shows in S6, which starts at row 3):
 *   P1  SYNC 0x0F, defsyncm24 (10 4E 07 25 07 07 90 65), START, no PITCH          10 s
 *   P2  PITCH 0x47,0x50                                                            10 s
 *   P3  SYNC 0x0F with C/R 0x4C (AW 78), START, no PITCH                           10 s
 *   P4  SYNC 0x0F with C/R 0x3E (AW 64), START, no PITCH                           10 s
 *   P5  SYNC 0x0E (display off) with C/R 0x4E, START, no PITCH                     10 s
 *   P6  PITCH 0x50, THEN SYNC 0x0F C/R 0x4E, START                                 10 s
 *   P7  SYNC 0x0F C/R 0x4E, START, PITCH 0x50, then INT 18h AH=0Ah AL=00 (+0Ch)    10 s
 *   S3  /T state 3: AH=0Ah 25 lines, the 480-line SYNC block + PITCH, one 480-line partition
 *   S4  /T state 4: the 400-line block + PITCH back first (as /T), AH=0Ah, two partitions
 *   S5  /T state 5: four partitions                                                10 s each
 *   S6  /T state 6: SUR 0 / SDR 24, animated to start word 240 + SSL 7, held
 *   S7  /T state 7: SUR 29, SDR 9, SSL 6, start word 0
 *   W1-W8  S7's SUR 29 / SDR 9 with SSL 0, 1, 2, 4, 6, 8, 12, 15                   2 s each
 *   W9  SUR 0 / SDR 24 (the whole screen) at SSL 6                                 2 s
 * Each step is preceded by a 2 s card with its label in large block letters (d_begin). About 3 min. Restore: CRTC as found, SYNC 0x0F defsyncm24 + START + PITCH 0x50, AH=0Ah,
 * one partition, a blank TRAM (reboot after anyway).
 *
 * THE LOG (stdout, written after the restore, so nothing reaches the screen while a step shows):
 *   STEP nn <name>
 *   OUT    every byte this program sent since the previous step: Cxx a master-GDC command (0x62),
 *          Pxx its parameter (0x60; the SYNC's 8 bytes and the PRAM's 16 follow their command),
 *          76=xx/78=xx/7A=xx the CRTC writes; S6 keeps only the held step's writes (the log is
 *          cleared before animation step 55). INT 18h's own writes are not in it.
 *   CRTC   0x70-0x7A read back, and 0x68
 *   BDA    0000:053C-053F | 0000:0710-071F
 *   STAT   eight master-GDC status reads at the step's start
 *   CSRR   the 5 bytes the master GDC returns for CSRR (0xE0) once (-- : no byte in time)
 *   FRAME  16 VSYNC periods in ARTIC ticks (307.2 kHz), then for one frame the lines (GDC status
 *          bit 6 rises from one VSYNC rise to the next) and the lines inside VSYNC
 *   TRAM   CRC-16 (CCITT) of the code words 0-3999 and of their attribute bytes; then of row 0
 * txtmode_decode.py checks the TRAM CRCs against the pattern and prints the rates.
 * Usage: TXTMODE /D > TXTD.TXT from a freshly booted prompt, CLS first; reboot after.
 */
    .equ    LOGBUF, 0x6000              /* the log, up to 0xF000 in this segment */
    .equ    HOLD10, 3072000             /* 10 s of ARTIC */
    .equ    HOLD2,  614400
    .equ    SETTLE1, 307200             /* 1 s before the measurement */
    .equ    SETTLE0, 61440              /* 0.2 s */
dmode_run:
    mov     word ptr [lbp], LOGBUF
    mov     si, offset d_banner
    call    lb_s
    mov     si, offset d_found
    call    lb_s
    mov     si, offset crtc_found
    mov     cx, 6
1:  lodsb
    call    lb_hex8
    call    lb_sp
    loop    1b
    call    lb_nl
    call    fill_pattern
    mov     al, 0x00
    call    bios_mode
    call    one_partition_400
    mov     byte ptr [dmode_log], 1
    /* P1 */
    call    d_begin
    mov     al, 0x0F
    mov     si, offset sync400
    call    d_sync
    mov     si, offset tP1
    call    d_step10
    /* P2 */
    call    d_begin
    call    d_pitch
    mov     si, offset tP2
    call    d_step10
    /* P3 */
    call    d_begin
    mov     al, 0x0F
    mov     si, offset sync4c
    call    d_sync
    mov     si, offset tP3
    call    d_step10
    /* P4 */
    call    d_begin
    mov     al, 0x0F
    mov     si, offset sync3e
    call    d_sync
    mov     si, offset tP4
    call    d_step10
    /* P5 */
    call    d_begin
    mov     al, 0x0E
    mov     si, offset sync400
    call    d_sync
    mov     si, offset tP5
    call    d_step10
    /* P6 */
    call    d_begin
    call    d_pitch
    mov     al, 0x0F
    mov     si, offset sync400
    call    d_sync
    mov     si, offset tP6
    call    d_step10
    /* P7 */
    call    d_begin
    mov     al, 0x0F
    mov     si, offset sync400
    call    d_sync
    call    d_pitch
    mov     al, 0x00
    call    bios_mode
    mov     si, offset tP7
    call    d_step10
    /* S3 */
    call    d_begin
    mov     al, 0x00
    call    bios_mode
    mov     al, 0x0F
    mov     si, offset sync480
    call    d_sync
    call    d_pitch
    mov     si, offset pram_480
    call    gdc_pram
    mov     si, offset tS3
    call    d_step10
    /* S4: the default block back first, as /T does after state 3 */
    call    d_begin
    mov     al, 0x0F
    mov     si, offset sync400
    call    d_sync
    call    d_pitch
    mov     al, 0x00
    call    bios_mode
    mov     si, offset pram_two
    call    gdc_pram
    mov     si, offset tS4
    call    d_step10
    /* S5 */
    call    d_begin
    mov     si, offset pram_four
    call    gdc_pram
    mov     si, offset tS5
    call    d_step10
    /* S6 */
    call    d_begin
    call    one_partition_400
    mov     si, offset tS6
    call    d_title
    xor     al, al
    mov     dx, 0x76
    call    d_out
    mov     dx, 0x78
    call    d_out
    mov     al, 24
    mov     dx, 0x7A
    call    d_out
    xor     bx, bx
2:  call    waitvsync
    cmp     bx, 55
    jne     3f
    mov     word ptr [olp], 0           /* the log keeps the held step's writes */
3:  mov     al, bl
    and     al, 0x0F
    mov     dx, 0x76
    call    d_out
    mov     ax, bx
    shr     ax, 4
    mov     cx, 80
    mul     cx
    mov     [pram_scr0], ax
    mov     si, offset pram_scr
    call    gdc_pram
    inc     bx
    cmp     bx, 56
    jb      2b
    mov     si, offset tS6
    call    d_step10
    /* S7 */
    call    d_begin
    mov     word ptr [pram_scr0], 0
    mov     si, offset pram_scr
    call    gdc_pram
    mov     al, 29
    mov     dx, 0x78
    call    d_out
    mov     al, 9
    mov     dx, 0x7A
    call    d_out
    mov     al, 6
    mov     dx, 0x76
    call    d_out
    mov     si, offset tS7
    call    d_step10
    /* W1-W8: the SSL sweep under SUR 29 / SDR 9 */
    xor     bx, bx
4:  push    bx
    call    d_begin
    pop     bx
    push    bx
    mov     al, [sweep+bx]
    mov     dx, 0x76
    call    d_out
    mov     ax, bx
    mov     cx, 19
    mul     cx
    mov     si, offset tW1
    add     si, ax
    call    d_step2
    pop     bx
    inc     bx
    cmp     bx, 8
    jb      4b
    /* W9: the whole screen at SSL 6 */
    call    d_begin
    xor     al, al
    mov     dx, 0x78
    call    d_out
    mov     al, 24
    mov     dx, 0x7A
    call    d_out
    mov     al, 6
    mov     dx, 0x76
    call    d_out
    mov     si, offset tW9
    call    d_step2
    /* restore */
    mov     byte ptr [dmode_log], 0
    mov     si, offset crtc_ports
    mov     di, offset crtc_found
    mov     cx, 6
5:  lodsb
    mov     dl, al
    xor     dh, dh
    mov     al, [di]
    inc     di
    out     dx, al
    loop    5b
    mov     al, 0x0F
    mov     si, offset sync400
    call    d_sync
    call    d_pitch
    mov     al, 0x00
    call    bios_mode
    call    one_partition_400
    call    clear_tram
    mov     si, offset d_done
    call    lb_s
    mov     si, offset d_end
    call    lb_s
    mov     bx, 1                       /* the log to stdout */
    mov     dx, LOGBUF
    mov     cx, [lbp]
    sub     cx, dx
    mov     ah, 0x40
    int     0x21
    mov     ax, 0x4C00
    int     0x21

/* every step starts with a CARD: the TRAM cleared and the step's label (P1 .. W9, the first two
 * characters of its name) drawn as 5 x 7 block letters of reverse-video cells, 3 cells x 2 rows
 * per dot, in TRAM rows 4-17 and again in rows 29-42 (so a second partition from word 2000
 * shows one too), held 2 s, then the pattern back. The card writes TRAM only: no GDC command, no
 * CRTC or BIOS call, so it is shown in the geometry the previous step left and changes nothing
 * the next step tests. */
d_begin:
    mov     word ptr [olp], 0
    inc     byte ptr [dstep]
    call    clear_tram
    mov     al, [dstep]
    dec     al
    xor     ah, ah
    mov     cx, 19
    mul     cx
    mov     si, offset tP1
    add     si, ax
    mov     al, [si]
    mov     [lab], al
    mov     al, [si+1]
    mov     [lab+1], al
    mov     word ptr [gbase], 4 * 160
    call    d_label
    mov     word ptr [gbase], 29 * 160
    call    d_label
    call    artic24
    mov     [t_start], eax
    mov     eax, HOLD2
    call    wait_from
    jmp     fill_pattern
d_label:                                /* both characters of [lab] at [gbase], columns 22 and 40 */
    mov     al, [lab]
    mov     bx, 44
    call    d_glyph
    mov     al, [lab+1]
    mov     bx, 80
d_glyph:                                /* AL = character, BX = byte column, [gbase] = row byte offset */
    mov     ah, 12
    cmp     al, 'W'
    je      1f
    mov     ah, 11
    cmp     al, 'S'
    je      1f
    mov     ah, 10
    cmp     al, 'P'
    je      1f
    mov     ah, al
    sub     ah, '0'
1:  mov     al, ah
    xor     ah, ah
    mov     cx, 7
    mul     cx
    mov     si, offset d_font
    add     si, ax
    mov     byte ptr [rattr], 0xE5      /* white, reverse */
    xor     dx, dx                      /* font row 0-6 */
2:  mov     ah, [si]
    inc     si
    mov     cx, 2                       /* two text rows per dot row */
3:  push    cx
    push    dx
    mov     ax, dx
    shl     ax, 1
    add     ax, cx
    dec     ax
    mov     cx, 160
    mul     cx
    add     ax, [gbase]
    add     ax, bx
    mov     di, ax
    pop     dx
    push    dx
    mov     al, [si-1]
    mov     dh, 0x10
4:  test    al, dh
    jz      5f
    push    ax
    mov     cx, 3
6:  mov     al, ' '
    call    put_ank
    loop    6b
    pop     ax
    jmp     7f
5:  add     di, 6
7:  shr     dh, 1
    jnz     4b
    pop     dx
    pop     cx
    loop    3b
    inc     dx
    cmp     dx, 7
    jb      2b
    ret
/* AL = SYNC command (0x0F or 0x0E), SI = its 8 parameters; then START 0x0D */
d_sync:
    call    gdc_cmd
    mov     cx, 8
1:  lodsb
    call    gdc_par
    loop    1b
    mov     al, 0x0D
    jmp     gdc_cmd
d_pitch:                                /* PITCH 0x47, 0x50 (80 words) */
    mov     al, 0x47
    call    gdc_cmd
    mov     al, 0x50
    jmp     gdc_par
/* the step's name (SI, 19 characters) into rows 0 and 3, columns 40-58 */
d_title:
    push    si
    call    title
    pop     si
    push    bx
    mov     byte ptr [rattr], 0xE1
    mov     di, 3 * 160 + 80
    mov     cx, 19
1:  lodsb
    call    put_ank
    loop    1b
    pop     bx
    ret
d_step10:
    mov     dword ptr [t_hold], HOLD10
    mov     dword ptr [t_settle], SETTLE1
    jmp     d_step
d_step2:
    mov     dword ptr [t_hold], HOLD2
    mov     dword ptr [t_settle], SETTLE0
/* SI = the step's name: title, the start status, settle, measure, CSRR, hold, record */
d_step:
    mov     [d_name], si
    call    d_title
    call    artic24
    mov     [t_start], eax
    mov     di, offset statbuf
    mov     cx, 8
1:  in      al, 0x60
    mov     [di], al
    inc     di
    loop    1b
    mov     eax, [t_settle]
    call    wait_from
    call    d_measure
    call    d_csrr
    mov     eax, [t_hold]
    call    wait_from
    jmp     d_record

/* a CRTC write, logged as pp=vv. DX = port, AL = value. */
d_out:
    out     dx, al
    cmp     byte ptr [dmode_log], 0
    je      1f
    push    ax
    mov     al, dl
    call    ol_put
    pop     ax
    call    ol_put
1:  ret
/* the OUT log: pairs of {tag, value}; tag C = GDC command, P = parameter, else a CRTC port */
ol_put:
    push    bx
    mov     bx, [olp]
    cmp     bx, 254
    jae     1f
    mov     [olog+bx], al
    inc     word ptr [olp]
1:  pop     bx
    ret

/* CSRR (0xE0): 5 bytes from the master GDC's data port (0x62 read), each after status bit 0 */
d_csrr:
    mov     byte ptr [dmode_log], 0
    mov     al, 0xE0
    call    gdc_cmd
    mov     byte ptr [dmode_log], 1
    mov     di, offset csrrbuf
    mov     cx, 5
1:  push    cx
    mov     cx, 0xFFFF
2:  in      al, 0x60
    test    al, 0x01
    jnz     3f
    loop    2b
    mov     byte ptr [di + 5], 0        /* no byte */
    jmp     4f
3:  in      al, 0x62
    mov     [di], al
    mov     byte ptr [di + 5], 1
4:  inc     di
    pop     cx
    loop    1b
    ret

/* the record of the held step */
d_record:
    mov     si, offset d_stepn
    call    lb_s
    mov     al, [dstep]
    call    lb_hex8
    call    lb_sp
    mov     si, [d_name]
    mov     cx, 19
1:  lodsb
    call    lb_c
    loop    1b
    call    lb_nl
    /* OUT */
    mov     si, offset d_outs
    call    lb_s
    xor     bx, bx
2:  cmp     bx, [olp]
    jae     5f
    mov     al, [olog+bx]
    cmp     al, 'C'
    je      3f
    cmp     al, 'P'
    je      3f
    call    lb_hex8                     /* a CRTC port: pp=vv */
    mov     al, '='
    call    lb_c
    jmp     4f
3:  call    lb_c
4:  mov     al, [olog+bx+1]
    call    lb_hex8
    call    lb_sp
    add     bx, 2
    jmp     2b
5:  call    lb_nl
    /* CRTC + 0x68 */
    mov     si, offset d_crtc
    call    lb_s
    mov     si, offset crtc_ports
    mov     cx, 6
6:  lodsb
    mov     dl, al
    xor     dh, dh
    in      al, dx
    call    lb_hex8
    call    lb_sp
    loop    6b
    mov     si, offset d_68
    call    lb_s
    in      al, 0x68
    call    lb_hex8
    call    lb_nl
    /* BDA */
    mov     si, offset d_bda
    call    lb_s
    mov     si, 0x053C
    mov     cx, 4
    call    d_bdabytes
    mov     al, '|'
    call    lb_c
    call    lb_sp
    mov     si, 0x0710
    mov     cx, 16
    call    d_bdabytes
    call    lb_nl
    /* STAT */
    mov     si, offset d_stat
    call    lb_s
    mov     si, offset statbuf
    mov     cx, 8
7:  lodsb
    call    lb_hex8
    call    lb_sp
    loop    7b
    call    lb_nl
    /* CSRR */
    mov     si, offset d_csrrs
    call    lb_s
    xor     bx, bx
8:  cmp     byte ptr [csrrbuf+bx+5], 0
    jne     9f
    mov     al, '-'
    call    lb_c
    call    lb_c
    jmp     10f
9:  mov     al, [csrrbuf+bx]
    call    lb_hex8
10: call    lb_sp
    inc     bx
    cmp     bx, 5
    jb      8b
    call    lb_nl
    /* FRAME */
    mov     si, offset d_frame
    call    lb_s
    mov     eax, [m_ticks]
    call    lb_hex32
    mov     si, offset d_lines
    call    lb_s
    mov     ax, [m_lines]
    call    lb_hex16
    mov     si, offset d_vsl
    call    lb_s
    mov     ax, [m_vsl]
    call    lb_hex16
    call    lb_nl
    /* TRAM: the whole plane (words 0-3999), then row 0 */
    mov     si, offset d_tram
    call    lb_s
    mov     cx, 4000
    call    d_tramcrc
    mov     si, offset d_tram0
    call    lb_s
    mov     cx, 80
    call    d_tramcrc
    ret
d_bdabytes:                             /* CX bytes of 0000:SI as hex */
    push    es
    xor     ax, ax
    mov     es, ax
1:  mov     al, es:[si]
    inc     si
    call    lb_hex8
    call    lb_sp
    loop    1b
    pop     es
    ret
d_tramcrc:                              /* CX words from TRAM word 0: code CRC, attribute CRC */
    push    es
    push    cx
    mov     ax, 0xA000
    mov     es, ax
    xor     di, di
    mov     word ptr [crc], 0xFFFF
1:  mov     al, es:[di]
    call    crc_b
    mov     al, es:[di+1]
    call    crc_b
    add     di, 2
    loop    1b
    mov     ax, [crc]
    call    lb_hex16
    call    lb_sp
    pop     cx
    mov     ax, 0xA200
    mov     es, ax
    xor     di, di
    mov     word ptr [crc], 0xFFFF
2:  mov     al, es:[di]
    call    crc_b
    add     di, 2
    loop    2b
    mov     ax, [crc]
    call    lb_hex16
    call    lb_nl
    pop     es
    ret

/* the measurements (interrupts off only for the one-frame line count) */
d_measure:
    call    waitvsync
    call    artic24
    mov     [t_a], eax
    mov     cx, 16
3:  call    waitvsync
    loop    3b
    call    artic24
    sub     eax, [t_a]
    and     eax, 0x00FFFFFF
    mov     [m_ticks], eax
    cli
    call    waitvsync
    xor     bx, bx                      /* lines */
    xor     dx, dx                      /* lines with VSYNC high */
    mov     ah, 0x60                    /* the last status: VSYNC high, HBLANK high */
4:  in      al, 0x60
    test    al, 0x40
    jz      5f
    test    ah, 0x40
    jnz     5f
    inc     bx                          /* an HBLANK rise */
    test    al, 0x20
    jz      5f
    inc     dx
5:  test    al, 0x20
    jz      6f
    test    ah, 0x20
    jnz     6f
    cmp     bx, 8                       /* the next VSYNC rise ends the frame */
    jae     7f
6:  mov     ah, al
    cmp     bx, 0x4000
    jb      4b
7:  sti
    mov     [m_lines], bx
    mov     [m_vsl], dx
    ret

/* ARTIC: EAX = the 24-bit count, read 5F 5D 5C 5D 5F until the two reads of each agree */
artic24:
    push    bx
    push    dx
1:  in      al, 0x5F
    mov     bh, al
    in      al, 0x5D
    mov     bl, al
    in      al, 0x5C
    mov     dl, al
    in      al, 0x5D
    cmp     al, bl
    jne     1b
    in      al, 0x5F
    cmp     al, bh
    jne     1b
    xor     eax, eax
    mov     al, bh
    shl     eax, 16
    mov     ah, bl
    mov     al, dl
    pop     dx
    pop     bx
    ret
/* wait until EAX ticks after [t_start] */
wait_from:
    push    ebx
    mov     ebx, eax
1:  call    artic24
    sub     eax, [t_start]
    and     eax, 0x00FFFFFF
    cmp     eax, ebx
    jb      1b
    pop     ebx
    ret

crc_b:                                  /* CRC-16/CCITT-FALSE over AL into [crc] */
    push    ax
    push    cx
    push    dx
    mov     dx, [crc]
    xor     dh, al
    mov     cx, 8
1:  shl     dx, 1
    jnc     2f
    xor     dx, 0x1021
2:  loop    1b
    mov     [crc], dx
    pop     dx
    pop     cx
    pop     ax
    ret

/* the log buffer (LOGBUF up to 0xF000, in this program's own segment) */
lb_c:
    push    bx
    mov     bx, [lbp]
    cmp     bx, 0xF000
    jae     1f
    mov     [bx], al
    inc     word ptr [lbp]
1:  pop     bx
    ret
lb_s:
    push    ax
1:  lodsb
    test    al, al
    jz      2f
    call    lb_c
    jmp     1b
2:  pop     ax
    ret
lb_sp:
    push    ax
    mov     al, ' '
    call    lb_c
    pop     ax
    ret
lb_nl:
    push    ax
    mov     al, 13
    call    lb_c
    mov     al, 10
    call    lb_c
    pop     ax
    ret
lb_hexd:
    push    ax
    and     al, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     1f
    add     al, 7
1:  call    lb_c
    pop     ax
    ret
lb_hex8:
    push    ax
    push    ax
    shr     al, 4
    call    lb_hexd
    pop     ax
    call    lb_hexd
    pop     ax
    ret
lb_hex16:
    push    ax
    xchg    al, ah
    call    lb_hex8
    xchg    al, ah
    call    lb_hex8
    pop     ax
    ret
lb_hex32:
    push    eax
    ror     eax, 16
    call    lb_hex16
    rol     eax, 16
    call    lb_hex16
    pop     eax
    ret

d_banner:  .asciz "TXTMODE /D v2 text pitch and row geometry: P1-P7, S3-S7 (PITCH 80), SSL sweep W1-W9, no keys (tools/hwprobe/txtmode)\r\n"
d_found:   .asciz "CRTC 70 72 74 76 78 7A as found: "
d_stepn:   .asciz "STEP "
d_outs:    .asciz "OUT "
d_crtc:    .asciz "CRTC 70-7A "
d_68:      .asciz "68="
d_bda:     .asciz "BDA 053C-053F "
d_stat:    .asciz "STAT "
d_csrrs:   .asciz "CSRR "
d_frame:   .asciz "FRAME 16 VSYNC ticks="
d_lines:   .asciz " lines="
d_vsl:     .asciz " vsync_lines="
d_tram:    .asciz "TRAM 0-3999 "
d_tram0:   .asciz "TRAM0 "
d_done:    .asciz "TXTMODE done: CRTC restored, SYNC + PITCH 80, 25 lines, one partition\r\n"
d_end:     .asciz "END:TXTMODE\r\n"
/* the step names, 19 characters each */
tP1:       .ascii "P1 SYNC 4E NOPITCH "
tP2:       .ascii "P2 +PITCH 50       "
tP3:       .ascii "P3 SYNC 4C NOPITCH "
tP4:       .ascii "P4 SYNC 3E NOPITCH "
tP5:       .ascii "P5 SYNC0E 4E START "
tP6:       .ascii "P6 PITCH THEN SYNC "
tP7:       .ascii "P7 SYNC PITCH INT18"
tS3:       .ascii "S3 30 LINES +PITCH "
tS4:       .ascii "S4 2 PARTS +PITCH  "
tS5:       .ascii "S5 4 PARTS         "
tS6:       .ascii "S6 SCROLL 240 SSL7 "
tS7:       .ascii "S7 SUR29 SDR9 SSL6 "
tW1:       .ascii "W1 SUR29 SDR9 SSL0 "
           .ascii "W2 SUR29 SDR9 SSL1 "
           .ascii "W3 SUR29 SDR9 SSL2 "
           .ascii "W4 SUR29 SDR9 SSL4 "
           .ascii "W5 SUR29 SDR9 SSL6 "
           .ascii "W6 SUR29 SDR9 SSL8 "
           .ascii "W7 SUR29 SDR9 SSL12"
           .ascii "W8 SUR29 SDR9 SSL15"
tW9:       .ascii "W9 SUR0 SDR24 SSL6 "
sweep:     .byte 0, 1, 2, 4, 6, 8, 12, 15
/* 5 x 7 glyphs, bits 4-0 = the dots left to right: 0-9, P, S, W */
d_font:
    .byte 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E
    .byte 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E
    .byte 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F
    .byte 0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E
    .byte 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02
    .byte 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E
    .byte 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E
    .byte 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08
    .byte 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E
    .byte 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C
    .byte 0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10
    .byte 0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E
    .byte 0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A
/* SYNC blocks with C/R 0x4C (AW 78) and 0x3E (AW 64); the rest as defsyncm24 */
sync4c:    .byte 0x10, 0x4C, 0x07, 0x25, 0x07, 0x07, 0x90, 0x65
sync3e:    .byte 0x10, 0x3E, 0x07, 0x25, 0x07, 0x07, 0x90, 0x65
    .balign 4
t_start:   .long 0
t_a:       .long 0
t_hold:    .long 0
t_settle:  .long 0
m_ticks:   .long 0
m_lines:   .word 0
m_vsl:     .word 0
crc:       .word 0
lbp:       .word 0
olp:       .word 0
d_name:    .word 0
dmode_log: .byte 0
dstep:     .byte 0
lab:       .byte 0, 0
gbase:     .word 0
statbuf:   .space 8
csrrbuf:   .space 10
olog:      .space 256

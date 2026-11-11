/* stamp.s - a time stamp for the kit's boot log: boot time without a stopwatch (todo item 181).
 *
 *   STAMP tag          append `STAMP tag ...` to BOOTLOG.TXT (in the current directory)
 *   STAMP tag /R       the same, then print PRESS THE RESET BUTTON NOW and wait for it; Esc
 *                      instead logs `STAMP tag-ESC` and exits with ERRORLEVEL 1 (the batch then
 *                      reboots in software)
 *
 * THE TIME. The calendar (INT 1Ch AH=00h: six BCD bytes year, month<<4|weekday, day, hour,
 * minute, second; the uPD4990A behind it counts whole seconds) is read, then read again until
 * its second changes (bounded: 2 s of the ARTIC), so every stamp is taken AT a second edge. The
 * 307200 Hz ARTIC (0x5C word, 0x5F high byte; 24 bits) is latched on arrival and at the edge,
 * so the decoder (stamp_decode.py) can put the arrival inside the second:
 *   arrival = edge - (edge_artic - arrive_artic) / 307200 s.
 * A boot's time is then the next boot's arrival minus this stamp's edge (taken just before the
 * software reboot or the RESET prompt). The ARTIC value on arrival is printed raw too: if the
 * counter restarts at RESET it is itself the time since the reset.
 *
 * The line is written by this program (open/append/close, INT 21h 3Dh/3Ch, 42h, 40h, 3Eh), so
 * it is on the disk before the RESET. No other port is written; nothing else is touched.
 *
 * LINE: STAMP <tag> rtc=YYMMDDhhmmss edge=xxxxxx arrive=xxxxxx
 *
 * BUILD: make -C tools/hwprobe stamp/stamp.com
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

_start:
    push    cs
    pop     ds
    push    cs
    pop     es
    cld
    call    artic_read
    mov     [arrive], eax
    /* the tag: the first word of the tail, at most 12 characters; /R anywhere */
    mov     si, 0x81
    mov     cl, [0x80]
    xor     ch, ch
    add     cx, si
    mov     di, offset tag
1:  cmp     si, cx
    jae     3f
    lodsb
    cmp     al, ' '
    je      1b
2:  cmp     al, '/'
    je      4f
    cmp     di, offset tag + 12
    jae     5f
    stosb
5:  cmp     si, cx
    jae     3f
    lodsb
    cmp     al, ' '
    jne     2b
    jmp     1b
4:  cmp     si, cx
    jae     3f
    lodsb
    and     al, 0xDF
    cmp     al, 'R'
    jne     1b
    mov     byte ptr [rmode], 1
    jmp     1b
3:  mov     [tag_end], di
    /* the second edge */
    mov     bx, offset rtc0
    call    rtc_read
    call    artic_read
    mov     ebx, eax
6:  push    bx
    mov     bx, offset rtc1
    call    rtc_read
    pop     bx
    mov     al, [rtc1 + 5]
    cmp     al, [rtc0 + 5]
    jne     7f
    call    artic_read
    sub     eax, ebx
    and     eax, 0x00FFFFFF
    cmp     eax, 614400
    jb      6b
7:  call    artic_read
    mov     [edge], eax
    call    log_line
    cmp     byte ptr [rmode], 0
    je      done
    mov     dx, offset s_reset
    mov     ah, 0x09
    int     0x21
8:  mov     ah, 0x06            /* direct console input, no wait */
    mov     dl, 0xFF
    int     0x21
    jz      8b
    cmp     al, 0x1B
    jne     8b
    mov     si, offset s_esc    /* Esc: log it, ERRORLEVEL 1 */
    mov     di, [tag_end]
9:  lodsb
    stosb
    test    al, al
    jnz     9b
    dec     di
    mov     [tag_end], di
    mov     bx, offset rtc1
    call    rtc_read
    call    artic_read
    mov     [edge], eax
    mov     [arrive], eax
    call    log_line
    mov     ax, 0x4C01
    int     0x21
done:
    mov     ax, 0x4C00
    int     0x21

/* log_line: build the line in lbuf and append it to BOOTLOG.TXT */
log_line:
    mov     di, offset lbuf
    mov     si, offset s_stamp
    call    cpy
    mov     si, offset tag
    mov     cx, [tag_end]
    sub     cx, si
    rep     movsb
    mov     si, offset s_rtc
    call    cpy
    mov     si, offset rtc1
    mov     al, [si]            /* year */
    call    hex8
    mov     al, [si + 1]        /* month in the high nibble */
    shr     al, 4
    mov     ah, al
    mov     al, '0'
    cmp     ah, 10
    jb      1f
    mov     al, '1'
    sub     ah, 10
1:  stosb
    mov     al, ah
    add     al, '0'
    stosb
    mov     al, [si + 2]
    call    hex8
    mov     al, [si + 3]
    call    hex8
    mov     al, [si + 4]
    call    hex8
    mov     al, [si + 5]
    call    hex8
    mov     si, offset s_edge
    call    cpy
    mov     eax, [edge]
    call    hex24
    mov     si, offset s_arr
    call    cpy
    mov     eax, [arrive]
    call    hex24
    mov     al, 13
    stosb
    mov     al, 10
    stosb
    mov     [lend], di
    /* open or create, seek to the end, write, close */
    mov     ax, 0x3D02
    mov     dx, offset fname
    int     0x21
    jnc     2f
    mov     ah, 0x3C
    xor     cx, cx
    mov     dx, offset fname
    int     0x21
    jc      3f
2:  mov     bx, ax
    mov     ax, 0x4202
    xor     cx, cx
    xor     dx, dx
    int     0x21
    mov     ah, 0x40
    mov     cx, [lend]
    sub     cx, offset lbuf
    mov     dx, offset lbuf
    int     0x21
    mov     ah, 0x3E
    int     0x21
3:  ret

cpy:                            /* NUL string DS:SI -> ES:DI (no NUL) */
    lodsb
    test    al, al
    jz      1f
    stosb
    jmp     cpy
1:  ret
hex8:                           /* AL -> two hex digits at ES:DI */
    push    ax
    shr     al, 4
    call    1f
    pop     ax
    and     al, 0x0F
1:  add     al, '0'
    cmp     al, '9'
    jbe     2f
    add     al, 7
2:  stosb
    ret
hex24:                          /* EAX low 24 bits */
    push    eax
    shr     eax, 16
    call    hex8
    pop     eax
    push    ax
    mov     al, ah
    call    hex8
    pop     ax
    call    hex8
    ret

/* rtc_read: INT 1Ch AH=00h into DS:BX (6 bytes) */
rtc_read:
    push    es
    push    ax
    push    cs
    pop     es
    mov     ah, 0x00
    int     0x1C
    pop     ax
    pop     es
    ret

artic_read:                     /* EAX = the 24-bit ARTIC, as ym29 */
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

fname:      .asciz "BOOTLOG.TXT"
s_stamp:    .asciz "STAMP "
s_rtc:      .asciz " rtc="
s_edge:     .asciz " edge="
s_arr:      .asciz " arrive="
s_esc:      .asciz "-ESC"
s_reset:    .ascii "\r\n\r\n   **********************************************\r\n"
            .ascii "   ***   PRESS THE RESET BUTTON NOW            ***\r\n"
            .ascii "   **********************************************\r\n"
            .ascii "   (only if RESET is impossible: press Esc for a software reboot)\r\n$"
rmode:      .byte 0
    .balign 4
arrive:     .long 0
edge:       .long 0
tag_end:    .word 0
lend:       .word 0
rtc0:       .space 6
rtc1:       .space 6
tag:        .space 20
lbuf:       .space 96

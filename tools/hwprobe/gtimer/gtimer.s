/* gtimer.s - a resident reboot timer for the kit's game steps (not a probe).
 *
 *   GTIMER n [/N] [/D]  stay resident; n seconds (1-3600) of ARTIC time after this, at the first
 *                  hooked call made while DOS is not busy, do the software reboot RBOOT does
 *
 * /D shows, for each wrapped vector in the order 08h 0Ah 15h 18h 21h 33h 1Bh, the low hex digit
 * of its call count in text row 0, columns 72-78 (a test aid for the core run: which sources a
 * game leaves running).
 *
 * WHY. The kit starts a game, the game never returns to DOS, and the owner films it without a
 * stopwatch. The kit's state machine (RUN.BAT, a flag file per step, written before the step)
 * moves on at the next boot, so ending a game is a reboot. GTIMER makes that reboot itself.
 *
 * HOW. Its own source is a tick: PIT channel 0 free-running, IR0 unmasked, INT 08h taken over
 * (the core run showed that at a DOS prompt and in a game's attract none of the wrapped vectors
 * below is called for minutes). It also wraps vectors the game and its drivers drive -
 * 0Ah (VSYNC, IR2), 15h (the mouse timer, IR13), 18h (the keyboard/CRT
 * BIOS), 1Bh (the disk BIOS), 21h (DOS) and 33h (the mouse driver; hooked only when one is
 * installed). Each wrapper runs the check and then jumps to the vector it replaced, so the
 * handler underneath sees the same registers, flags and stack. A game that installs its own
 * handler on one of these vectors without chaining stops that source; the others still run.
 * If no source runs at all the game stays up, and the owner's instructions say to press RESET.
 *
 * THE CHECK (interrupts off): the 307200 Hz ARTIC (0x5C word, 0x5F high byte; 24 bits, read as
 * stamp.s does) is read, the 24-bit difference from the last read is added to a 32-bit sum (so
 * the counter's 54.6 s wrap does not matter as long as some source runs at least that often),
 * and once the sum reaches n * 307200 the reboot is made - unless DOS is busy (the InDOS byte
 * from INT 21h AH=34h is not 0) or a disk BIOS call is in progress (a depth count kept by the
 * INT 1Bh wrapper), which defers it to the next check, so no file write is cut. DOS also counts
 * as busy while it waits for a key (a PAUSE, a prompt: seen on the core), so 20 s after the due
 * time InDOS is no longer asked, and 40 s after it nothing is (a game's own disk calls can keep
 * the count up: seen on the core).
 *
 * /N leaves the PIT and IR0 alone (INT 08h is then wrapped like the others): for a game whose
 * behaviour a running IR0 tick could change.
 *
 * THE REBOOT is RBOOT's (rboot.s, WIN.COM 4.00.950's stub): 8255 mode word 0x92 and the port C
 * bit set/reset bytes 07/0B/0F/08 to 0x37 (buzzer off, SHUT1, SHUT0, memory check off), NMI off
 * (0x50), both GDCs blanked (0x05 to 0xA2 and 0x62), a settle loop, 0x00 to 0xF0.
 *
 * BUILD: make -C tools/hwprobe gtimer/gtimer.com
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

_start:
    jmp     install

/* ---- resident part --------------------------------------------------------------------- */
    .balign 4
sum:        .long 0
last:       .long 0
target:     .long 0
indos:      .long 0                     /* far pointer to the InDOS byte */
fired:      .byte 0
disk_depth: .byte 0
debug:      .byte 0
imr0:       .byte 0
notick:     .byte 0
cnt:        .space 8
sig:        .ascii "GT"
old08:      .long 0
old0a:      .long 0
old15:      .long 0
old18:      .long 0
old1b:      .long 0
old21:      .long 0
old33:      .long 0

/* check: preserves every register and the flags */
check:
    pushf
    cli
    push    eax
    push    ebx
    push    dx
    push    ds
    push    cs
    pop     ds
    cmp     byte ptr [debug], 0
    je      1f
    /* /D: one hex digit per source (its call count, low nibble) on text row 0, columns 72-78 */
    push    es
    push    bx
    inc     byte ptr [cnt + si]
    mov     al, [cnt + si]
    and     al, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     2f
    add     al, 7
2:  mov     bx, 0xA000
    mov     es, bx
    mov     bx, si
    shl     bx, 1
    mov     es:[bx + 144], al
    mov     byte ptr es:[bx + 145], 0
    pop     bx
    pop     es
1:  call    artic_read
    mov     ebx, eax
    sub     eax, [last]
    and     eax, 0x00FFFFFF
    mov     [last], ebx
    add     [sum], eax
    mov     eax, [sum]
    cmp     eax, [target]
    jb      9f
    sub     eax, [target]
    cmp     eax, 40 * 307200            /* 40 s past due: reboot whatever is in progress */
    jae     reboot
    cmp     byte ptr [disk_depth], 0
    jne     9f
    cmp     eax, 20 * 307200            /* 20 s past due: DOS waits on the console, not a write */
    jae     reboot
    push    es
    les     bx, [indos]
    cmp     byte ptr es:[bx], 0
    pop     es
    jne     9f
    jmp     reboot
9:  pop     ds
    pop     dx
    pop     ebx
    pop     eax
    popf
    ret

artic_read:                             /* EAX = the 24-bit ARTIC (stamp.s) */
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
    ret

/* The reboot can be made from inside the tick's INT 08h, before its EOI. The CPU reset does not
 * reset the 8259s, so an IR0 left in service blocks the POST's own timer test ("TIMER INTERRUPT
 * ERROR" on the core's first run): a specific EOI for every level of both PICs first (one for a
 * level not in service does nothing), and IR0's mask bit put back as the install found it. */
reboot:
    cli
    mov     al, 0x60
1:  out     0x00, al
    out     0x08, al
    inc     al
    cmp     al, 0x68
    jb      1b
    in      al, 0x02
    or      al, cs:[imr0]
    out     0x02, al
    mov     al, 0x92
    out     0x37, al
    mov     al, 0x07
    out     0x37, al
    mov     al, 0x0B
    out     0x37, al
    mov     al, 0x0F
    out     0x37, al
    mov     al, 0x08
    out     0x37, al
    out     0x50, al
    mov     al, 0x05
    out     0xA2, al
    out     0x62, al
    mov     ecx, 0x40000
1:  loop    1b
    mov     al, 0x00
    out     0xF0, al
2:  jmp     2b

/* INT 08h is GTIMER's own tick (PIT channel 0, set up by the install): the check, a specific
 * EOI for IR0, and back - not chained, because the BIOS handler underneath serves only its
 * own interval-timer requests (INT 1Ch AH=02h) and none is pending. */
h08: push   si
    mov     si, 0
    call    check
    pop     si
    cmp     byte ptr cs:[notick], 0
    je      1f
    jmp     dword ptr cs:[old08]
1:  push    ax
    mov     al, 0x60
    out     0x00, al
    pop     ax
    iret
h0a: push   si
    mov     si, 1
    call    check
    pop     si
    jmp     dword ptr cs:[old0a]
h15: push   si
    mov     si, 2
    call    check
    pop     si
    jmp     dword ptr cs:[old15]
h18: push   si
    mov     si, 3
    call    check
    pop     si
    jmp     dword ptr cs:[old18]
h21: push   si
    mov     si, 4
    call    check
    pop     si
    jmp     dword ptr cs:[old21]
h33: push   si
    mov     si, 5
    call    check
    pop     si
    jmp     dword ptr cs:[old33]
/* the disk BIOS: the check first, then the call with a depth count around it. The call is
 * made as an interrupt (flags pushed with IF set, entered with IF clear, as a caller with
 * interrupts on would make it), and the flags it returns (CF = error) are handed back with
 * retf 2. */
h1b: push   si
    mov     si, 6
    call    check
    pop     si
    inc     byte ptr cs:[disk_depth]
    sti
    pushf
    cli
    call    dword ptr cs:[old1b]
    pushf
    dec     byte ptr cs:[disk_depth]
    popf
    retf    2
resident_end:

/* ---- transient part -------------------------------------------------------------------- */
install:
    push    cs
    pop     ds
    cld
    /* n: decimal from the command tail */
    mov     si, 0x81
    mov     cl, [0x80]
    xor     ch, ch
    add     cx, si
    xor     ebx, ebx
    xor     di, di                      /* digits seen */
1:  cmp     si, cx
    jae     2f
    lodsb
    cmp     al, ' '
    je      1b
    cmp     al, '/'
    jne     5f
    cmp     si, cx
    jae     2f
    lodsb
    and     al, 0xDF
    cmp     al, 'N'
    jne     6f
    mov     byte ptr [notick], 1        /* /N: no PIT tick, the wrapped vectors only */
    jmp     1b
6:  mov     byte ptr [debug], 1         /* /D: show the per-source counts */
    jmp     1b
5:  sub     al, '0'
    cmp     al, 9
    ja      2f
    imul    ebx, ebx, 10
    movzx   eax, al
    add     ebx, eax
    inc     di
    jmp     1b
2:  test    di, di
    jz      usage
    test    ebx, ebx
    jz      usage
    cmp     ebx, 3600
    ja      usage
    mov     [secs], bx
    imul    ebx, ebx, 307200
    mov     [target], ebx
    /* already installed? the INT 21h vector's offset and a signature word before it */
    mov     ax, 0x3521
    int     0x21
    cmp     bx, offset h21
    jne     3f
    cmp     word ptr es:[sig], 0x5447   /* "GT" */
    jne     3f
    mov     dx, offset s_twice
    mov     ah, 0x09
    int     0x21
    mov     ax, 0x4C01
    int     0x21
3:  mov     ah, 0x34
    int     0x21
    mov     [indos], bx
    mov     [indos + 2], es
    push    dx
    call    artic_read
    pop     dx
    mov     [last], eax
    mov     dword ptr [sum], 0
    /* hook */
    mov     al, 0x08
    mov     bx, offset old08
    mov     dx, offset h08
    call    hook
    mov     al, 0x0A
    mov     bx, offset old0a
    mov     dx, offset h0a
    call    hook
    mov     al, 0x15
    mov     bx, offset old15
    mov     dx, offset h15
    call    hook
    mov     al, 0x18
    mov     bx, offset old18
    mov     dx, offset h18
    call    hook
    mov     al, 0x1B
    mov     bx, offset old1b
    mov     dx, offset h1b
    call    hook
    /* INT 33h only when a mouse driver is there (a non-zero vector that is not an iret) */
    mov     ax, 0x3533
    int     0x21
    mov     ax, es
    or      ax, bx
    jz      4f
    cmp     byte ptr es:[bx], 0xCF
    je      4f
    mov     byte ptr [m33], 'y'
    mov     al, 0x33
    mov     bx, offset old33
    mov     dx, offset h33
    call    hook
4:  cmp     byte ptr [notick], 0
    jne     7f
    /* the tick: PIT channel 0 in mode 3 with the full count (37.5 Hz at 2.4576 MHz, 30 Hz at
     * 1.9968 MHz: only the ARTIC measures time), IR0 unmasked. Plain DOS leaves IR0 masked and the
     * counter unused; a game that takes over the PIT or INT 08h stops this source, not the others. */
    cli
    mov     al, 0x36
    out     0x77, al
    xor     al, al
    out     0x71, al
    out     0x71, al
    in      al, 0x02
    mov     ah, al
    and     ah, 1
    mov     [imr0], ah
    and     al, 0xFE
    out     0x02, al
    sti
7:  mov     al, 0x21                    /* last, so the install's own DOS calls above are plain */
    mov     bx, offset old21
    mov     dx, offset h21
    call    hook
    /* the message */
    mov     ax, [secs]
    mov     di, offset s_n
    call    dec4
    mov     dx, offset s_ok
    mov     ah, 0x09
    int     0x21
    /* free the environment, stay resident */
    mov     es, [0x2C]
    mov     ah, 0x49
    int     0x21
    mov     dx, offset resident_end + 15
    shr     dx, 4
    mov     ax, 0x3100
    int     0x21

/* hook: vector AL -> DS:BX (old), new = CS:DX */
hook:
    push    ax
    push    dx
    push    bx
    mov     ah, 0x35
    int     0x21
    mov     ax, bx
    pop     bx
    mov     [bx], ax
    mov     [bx + 2], es
    pop     dx
    pop     ax
    mov     ah, 0x25
    int     0x21
    ret

dec4:                                   /* AX -> 4 decimal digits at DS:DI (leading blanks) */
    mov     cx, 4
    add     di, 3
    mov     bx, 10
1:  xor     dx, dx
    div     bx
    add     dl, '0'
    mov     [di], dl
    dec     di
    test    ax, ax
    loopnz  1b
    jcxz    3f
2:  mov     byte ptr [di], ' '
    dec     di
    loop    2b
3:  ret

usage:
    mov     dx, offset s_use
    mov     ah, 0x09
    int     0x21
    mov     ax, 0x4C02
    int     0x21

secs:       .word 0
s_ok:       .ascii "GTIMER: software reboot in "
s_n:        .ascii "0000 s (mouse driver hooked: "
m33:        .ascii "n)\r\n$"
s_use:      .ascii "GTIMER n : reboot n (1-3600) seconds from now, resident\r\n$"
s_twice:    .ascii "GTIMER: already resident\r\n$"

/* opnax.s - OPNAX, two YM2608 questions of the built-in PC-9801-86 sound (base 0x188) no capture
 * answers yet. Run on the core first, then on the real PC-9821Xe10 (the same binary).
 *
 *   OPNAX /G > OPNAXG.TXT      the 0x29 gate of the ADPCM flags (about 2 s, no input)
 *   OPNAX /J > OPNAXJ.TXT      0x0E (the pad) against 0x0F = 80 C0 00 40 (INTERACTIVE: prompts on
 *                              the screen; Esc at a prompt skips the rest)
 *
 * /G  (the ym29 method, tools/hwprobe/ym29/ym29.s, on the ADPCM-B flags instead of the timers;
 *     the ADPCM-B memory write is xe10t sec_opna2.inc o2_adpcmb's, which on the Xe10 sets EOS
 *     after the 32nd byte, docs/probes/XE10T-XE10-OPNA2.TXT ADB_W i=32 `st=0C`). The extension
 *     is OPENED (0xA460 bit 0 set; ADPCM-B answers only then, and 0x29 reads FF with it closed),
 *     and for 0x29 = 00, 04 (EOS), 08 (BRDY), 10 (ZERO), 1F: flags reset (0x110 <- 80) and
 *     unmasked (0x110 <- 00), ADPCM-B reset, memory-write mode (0x100 <- 60, 0x101 <- 02, start
 *     = stop = 0, limit FFFF), INT 14h hooked and IR12 unmasked, then 40 bytes of 80 through
 *     0x108 (each under cli, BRDY polled after it, bounded 4096 reads), then 20 ms. The handler
 *     counts, ORs the extended status (0x18C) it sees, resets the flags (0x110 <- 80, so every
 *     new flag is a new request) and EOIs. Then IR12 masked: the status, the slave IRR, a flag
 *     reset, the IRR again. Restore: ADPCM-B reset and stopped, 0x110 <- 00, 0x29 <- its read
 *     (1F when it read FF), 0xA460, the vector and both IMRs as found.
 * /J  SSG register 7 set to port A in, port B out ((reg 7 & 3F) | 80), then for each prompt (no
 *     button, then one pad button held) 0x0F <- 80, C0, 00, 40 with 0x0E read after each (twice).
 *     Registers 7 and 0x0F are put back. A prompt waits for a key (INT 21h AH=08h); Esc skips.
 *
 * BUILD: make -C tools/hwprobe opnax/opnax.com
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

    .equ MPIC_CMD,  0x0000
    .equ MPIC_IMR,  0x0002
    .equ SPIC_CMD,  0x0008
    .equ SPIC_IMR,  0x000A
    .equ BASE,      0x0188
    .equ DL_20MS,   6144

_start:
    push    cs
    pop     ds
    push    cs
    pop     es
    cld
    mov     si, 0x81
    movzx   cx, byte ptr [0x80]
    jcxz    2f
1:  lodsb
    cmp     al, '/'
    jne     3f
    mov     al, [si]
    and     al, 0xDF
    mov     [mode], al
3:  loop    1b
2:  mov     dx, offset s_hdr
    call    puts
    mov     dx, BASE
    in      al, dx
    mov     [st_found], al
    mov     dx, 0xA460
    in      al, dx
    mov     [a460], al
    in      al, SPIC_IMR
    mov     [imrs], al
    in      al, MPIC_IMR
    mov     [imrm], al
    mov     dx, offset s_state
    call    puts
    mov     al, [st_found]
    call    puthex8
    mov     dx, offset s_a460
    call    puts
    mov     al, [a460]
    call    puthex8
    mov     dx, offset s_imrs
    call    puts
    mov     al, [imrs]
    call    puthex8
    mov     dx, offset s_imrm
    call    puts
    mov     al, [imrm]
    call    puthex8
    call    putnl
    cmp     byte ptr [st_found], 0xFF
    jne     4f
    mov     dx, offset s_absent
    call    puts
    jmp     9f
4:  cmp     byte ptr [mode], 'G'
    jne     5f
    call    sec_gate
    jmp     9f
5:  cmp     byte ptr [mode], 'J'
    jne     6f
    call    sec_joy
    jmp     9f
6:  mov     dx, offset s_usage
    call    puts
9:  mov     dx, offset s_done
    call    puts
    call    commit
    mov     ax, 0x4C00
    int     0x21

/* ======================================================================================== */
/* /G                                                                                        */
/* ======================================================================================== */
sec_gate:
    mov     dx, offset s_b_gate
    call    puts
    cli
    mov     al, [a460]
    or      al, 0x01
    mov     dx, 0xA460
    out     dx, al
    out     0x5F, al
    mov     al, 0x29
    call    opn_get
    mov     [r29], al
    mov     al, 0xFF
    call    opn_get
    mov     [chipid], al
    sti
    mov     dx, offset s_open
    call    puts
    mov     dx, 0xA460
    in      al, dx
    call    puthex8
    mov     dx, offset s_r29
    call    puts
    mov     al, [r29]
    call    puthex8
    mov     dx, offset s_id
    call    puts
    mov     al, [chipid]
    call    puthex8
    call    putnl
    mov     ax, 0x3514
    int     0x21
    mov     [v14], bx
    mov     [v14 + 2], es
    push    cs
    pop     es
    mov     ax, 0x2514
    mov     dx, offset isr12
    int     0x21
    call    commit
    mov     si, offset g_vals
1:  lodsb
    cmp     al, 0xEE
    je      8f
    push    si
    mov     [g_v], al
    call    gate_row
    call    gate_print
    call    commit
    pop     si
    jmp     1b
8:  /* restore */
    cli
    mov     al, [imrs]
    or      al, 0x10
    out     SPIC_IMR, al
    mov     ax, 0x0100              /* ADPCM-B reset, then stopped */
    call    ext_put
    mov     ax, 0x0000
    call    ext_put
    mov     ax, 0x8010              /* flags reset, then none masked */
    call    ext_put
    mov     ax, 0x0010
    call    ext_put
    mov     ah, [r29]
    cmp     ah, 0xFF
    jne     81f
    mov     ah, 0x1F
81: mov     [r29_put], ah
    mov     al, 0x29
    call    opn_put
    mov     al, [a460]
    mov     dx, 0xA460
    out     dx, al
    out     0x5F, al
    mov     al, [imrs]
    out     SPIC_IMR, al
    mov     al, [imrm]
    out     MPIC_IMR, al
    sti
    push    ds
    lds     dx, [v14]
    mov     ax, 0x2514
    int     0x21
    pop     ds
    mov     dx, offset s_rest
    call    puts
    mov     al, [r29_put]
    call    puthex8
    mov     dx, offset s_a460
    call    puts
    mov     dx, 0xA460
    in      al, dx
    call    puthex8
    mov     dx, offset s_imrs
    call    puts
    in      al, SPIC_IMR
    call    puthex8
    mov     dx, offset s_imrm
    call    puts
    in      al, MPIC_IMR
    call    puthex8
    call    putnl
    mov     dx, offset s_e_gate
    call    puts
    ret

/* gate_row: one 0x29 value [g_v] */
gate_row:
    cli
    mov     al, [imrs]
    or      al, 0x10
    out     SPIC_IMR, al
    mov     word ptr [isr_n], 0
    mov     byte ptr [isr_st], 0
    mov     byte ptr [g_brdy_to], 0
    mov     ah, [g_v]
    mov     al, 0x29
    call    opn_put
    mov     ax, 0x8010              /* 0x110 <- 80: flags reset */
    call    ext_put
    mov     ax, 0x0010              /* 0x110 <- 00: no flag masked */
    call    ext_put
    mov     ax, 0x0100              /* ADPCM-B reset */
    call    ext_put
    mov     ax, 0x6000              /* memory write (o2_adpcmb's sequence) */
    call    ext_put
    mov     ax, 0x0201
    call    ext_put
    mov     ax, 0x0002
    call    ext_put
    mov     ax, 0x0003
    call    ext_put
    mov     ax, 0x0004
    call    ext_put
    mov     ax, 0x0005
    call    ext_put
    mov     ax, 0xFF0C
    call    ext_put
    mov     ax, 0xFF0D
    call    ext_put
    mov     dx, BASE + 4
    call    opn_wait
    in      al, dx
    mov     [g_st0], al
    mov     dx, SPIC_CMD            /* a request left from the setup is dropped by the mask */
    mov     al, [imrs]
    and     al, 0xEF
    out     SPIC_IMR, al
    mov     al, [imrm]
    and     al, 0x7F
    out     MPIC_IMR, al
    sti
    xor     di, di
1:  cli
    mov     dx, BASE + 4
    call    opn_wait
    mov     al, 0x08
    out     dx, al
    call    opn_wait
    add     dx, 2
    mov     al, 0x80
    out     dx, al
    sub     dx, 2
    mov     cx, 4096
2:  in      al, dx
    test    al, 0x08
    jnz     3f
    loop    2b
    inc     byte ptr [g_brdy_to]
3:  sti
    nop
    nop
    inc     di
    cmp     di, 40
    jb      1b
    call    artic_read
    mov     ebx, eax
4:  call    artic_read
    sub     eax, ebx
    and     eax, 0xFFFFFF
    cmp     eax, DL_20MS
    jb      4b
    cli
    mov     al, [imrs]
    or      al, 0x10
    out     SPIC_IMR, al
    mov     dx, BASE + 4
    in      al, dx
    mov     [g_st1], al
    mov     al, 0x0A
    out     SPIC_CMD, al
    in      al, SPIC_CMD
    mov     [g_irr1], al
    mov     ax, 0x8010
    call    ext_put
    mov     al, 0x0A
    out     SPIC_CMD, al
    in      al, SPIC_CMD
    mov     [g_irr2], al
    mov     al, 0x0B
    out     SPIC_CMD, al
    mov     ax, 0x0100
    call    ext_put
    mov     ax, 0x0000
    call    ext_put
    mov     al, [imrs]
    out     SPIC_IMR, al
    mov     al, [imrm]
    out     MPIC_IMR, al
    sti
    ret

gate_print:
    mov     dx, offset s_grow
    call    puts
    mov     al, [g_v]
    call    puthex8
    mov     dx, offset s_irqs
    call    puts
    mov     ax, [isr_n]
    call    puthex16
    mov     dx, offset s_isrst
    call    puts
    mov     al, [isr_st]
    call    puthex8
    mov     dx, offset s_st0
    call    puts
    mov     al, [g_st0]
    call    puthex8
    mov     dx, offset s_st1
    call    puts
    mov     al, [g_st1]
    call    puthex8
    mov     dx, offset s_irr1
    call    puts
    mov     al, [g_irr1]
    call    puthex8
    mov     dx, offset s_irr2
    call    puts
    mov     al, [g_irr2]
    call    puthex8
    mov     dx, offset s_bto
    call    puts
    mov     al, [g_brdy_to]
    call    puthex8
    call    putnl
    ret

/* isr12: INT 14h (IR12): count, OR the extended status, reset the flags, EOI (ym29's isr12).
 * The main loop makes its extended-port accesses under cli, so the address latch is free here. */
isr12:
    push    ax
    push    dx
    push    ds
    push    cs
    pop     ds
    inc     word ptr [isr_n]
    mov     dx, BASE + 4
    in      al, dx
    or      [isr_st], al
    mov     ax, 0x8010
    call    ext_put
    cmp     word ptr [isr_n], 200
    jb      1f
    in      al, SPIC_IMR            /* saturated: masked until the row ends */
    or      al, 0x10
    out     SPIC_IMR, al
1:  mov     al, 0x20
    out     SPIC_CMD, al
    out     0x5F, al
    mov     al, 0x0B
    out     SPIC_CMD, al
    out     0x5F, al
    in      al, SPIC_CMD
    test    al, al
    jnz     2f
    mov     al, 0x20
    out     MPIC_CMD, al
2:  pop     ds
    pop     dx
    pop     ax
    iret

/* ======================================================================================== */
/* /J                                                                                        */
/* ======================================================================================== */
sec_joy:
    mov     dx, offset s_b_joy
    call    puts
    cli
    mov     al, 0x07
    call    opn_get
    mov     [r07], al
    mov     al, 0x0F
    call    opn_get
    mov     [r0f], al
    mov     al, 0x0E
    call    opn_get
    mov     [r0e], al
    sti
    mov     dx, offset s_jstate
    call    puts
    mov     al, [r07]
    call    puthex8
    mov     dx, offset s_r0f
    call    puts
    mov     al, [r0f]
    call    puthex8
    mov     dx, offset s_r0e
    call    puts
    mov     al, [r0e]
    call    puthex8
    call    putnl
    call    commit
    mov     byte ptr [j_hold], 0
1:  /* the prompt, on the screen (stderr, handle 2), not in the capture */
    mov     dx, offset p_none
    cmp     byte ptr [j_hold], 0
    je      2f
    mov     dx, offset p_btn
2:  call    eputs
    mov     ah, 0x08
    int     0x21
    cmp     al, 0x1B
    jne     3f
    mov     dx, offset s_jskip
    call    puts
    jmp     8f
3:  cli
    mov     ah, [r07]
    and     ah, 0x3F
    or      ah, 0x80
    mov     al, 0x07
    call    opn_put
    mov     si, offset j_sel
    mov     di, offset j_res
4:  lodsb
    cmp     al, 0xEE
    je      5f
    mov     ah, al
    mov     al, 0x0F
    call    opn_put
    call    iodly
    mov     al, 0x0E
    call    opn_get
    stosb
    mov     al, 0x0E
    call    opn_get
    stosb
    jmp     4b
5:  mov     ah, [r0f]
    mov     al, 0x0F
    call    opn_put
    mov     ah, [r07]
    mov     al, 0x07
    call    opn_put
    sti
    mov     si, offset j_sel
    mov     di, offset j_res
6:  lodsb
    cmp     al, 0xEE
    je      7f
    mov     dx, offset s_jrow
    call    puts
    push    ax
    mov     al, [j_hold]
    call    puthex8
    mov     dx, offset s_jsel
    call    puts
    pop     ax
    call    puthex8
    mov     dx, offset s_jr0e
    call    puts
    mov     al, [di]
    call    puthex8
    call    putsp
    mov     al, [di + 1]
    call    puthex8
    call    putnl
    add     di, 2
    jmp     6b
7:  call    commit
    inc     byte ptr [j_hold]
    cmp     byte ptr [j_hold], 2
    jb      1b
8:  mov     dx, offset s_e_joy
    call    puts
    mov     dx, offset p_end
    call    eputs
    ret

/* ======================================================================================== */
/* common                                                                                    */
/* ======================================================================================== */
opn_wait:                       /* DX = a status port: until BUSY (bit 7) clears, bounded */
    push    cx
    push    ax
    mov     cx, 0x4000
1:  in      al, dx
    test    al, 0x80
    jz      2f
    loop    1b
2:  pop     ax
    pop     cx
    ret
opn_put:                        /* AL = register, AH = data (FM/SSG side, 0x188/0x18A) */
    push    dx
    mov     dx, BASE
    call    opn_wait
    out     dx, al
    out     0x5F, al
    call    opn_wait
    add     dx, 2
    xchg    al, ah
    out     dx, al
    xchg    al, ah
    sub     dx, 2
    call    opn_wait
    pop     dx
    ret
opn_get:                        /* AL = register -> AL */
    push    dx
    mov     dx, BASE
    call    opn_wait
    out     dx, al
    out     0x5F, al
    out     0x5F, al
    call    opn_wait
    add     dx, 2
    in      al, dx
    pop     dx
    ret
ext_put:                        /* AL = register - 0x100, AH = data (the extended side, 0x18C/0x18E) */
    push    dx
    mov     dx, BASE + 4
    call    opn_wait
    out     dx, al
    out     0x5F, al
    call    opn_wait
    add     dx, 2
    xchg    al, ah
    out     dx, al
    xchg    al, ah
    sub     dx, 2
    call    opn_wait
    pop     dx
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

commit:
    push    ax
    push    bx
    mov     ah, 0x68
    mov     bx, 1
    int     0x21
    pop     bx
    pop     ax
    ret

/* eputs: DX = a '$' string, to stderr (the screen even with stdout redirected) */
eputs:
    push    ax
    push    bx
    push    cx
    push    di
    mov     di, dx
    xor     cx, cx
1:  cmp     byte ptr [di], '$'
    je      2f
    inc     di
    inc     cx
    jmp     1b
2:  mov     ah, 0x40
    mov     bx, 2
    int     0x21
    pop     di
    pop     cx
    pop     bx
    pop     ax
    ret

puthex16:
    push    ax
    mov     al, ah
    call    puthex8
    pop     ax
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
    push    ax
    mov     ah, 0x02
    int     0x21
    pop     ax
    ret
putsp:
    push    ax
    push    dx
    mov     dl, ' '
    mov     ah, 0x02
    int     0x21
    pop     dx
    pop     ax
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

s_hdr:      .ascii "OPNAX v1: the built-in OPNA at 0x188 (/G the 0x29 gate of the ADPCM flags, /J 0x0E against 0x0F)\r\n$"
s_state:    .ascii "STATE st188=$"
s_a460:     .ascii " a460=$"
s_imrs:     .ascii " imrs=$"
s_imrm:     .ascii " imrm=$"
s_absent:   .ascii "OPNAX SKIP: 0x188 reads FF (no OPNA)\r\n$"
s_usage:    .ascii "OPNAX: give /G or /J\r\n$"
s_done:     .ascii "OPNAX DONE\r\n$"
s_nl:       .ascii "\r\n$"
s_b_gate:   .ascii "BEGIN:GATE\r\n$"
s_e_gate:   .ascii "END:GATE\r\n$"
s_open:     .ascii "GATE open a460=$"
s_r29:      .ascii " r29=$"
s_id:       .ascii " id=$"
s_grow:     .ascii "GATE r29=$"
s_irqs:     .ascii " irqs=$"
s_isrst:    .ascii " isr_st=$"
s_st0:      .ascii " st0=$"
s_st1:      .ascii " st_end=$"
s_irr1:     .ascii " irr_end=$"
s_irr2:     .ascii " irr_rst=$"
s_bto:      .ascii " brdy_to=$"
s_rest:     .ascii "RESTORE r29=$"
s_b_joy:    .ascii "BEGIN:JOY\r\n$"
s_e_joy:    .ascii "END:JOY\r\n$"
s_jstate:   .ascii "JOY r07=$"
s_r0f:      .ascii " r0f=$"
s_r0e:      .ascii " r0e=$"
s_jskip:    .ascii "JOY SKIP (Esc at the prompt)\r\n$"
s_jrow:     .ascii "JOY hold=$"
s_jsel:     .ascii " r0f<-$"
s_jr0e:     .ascii " r0e=$"
p_none:     .ascii "\r\nOPNAX: RELEASE every button and the stick of the pad in joystick port 1,\r\n        then press SPACE on the keyboard (Esc = no pad: skip).\r\n$"
p_btn:      .ascii "\r\nOPNAX: HOLD pad button A (trigger 1) down and keep holding it,\r\n        then press SPACE on the keyboard with the other hand (Esc = skip).\r\n$"
p_end:      .ascii "OPNAX: done, you can let go.\r\n$"

g_vals:     .byte 0x00, 0x04, 0x08, 0x10, 0x1F, 0xEE
j_sel:      .byte 0x80, 0xC0, 0x00, 0x40, 0xEE

    .balign 4
v14:        .long 0
isr_n:      .word 0
mode:       .byte 0
st_found:   .byte 0
a460:       .byte 0
imrs:       .byte 0
imrm:       .byte 0
r29:        .byte 0
r29_put:    .byte 0
chipid:     .byte 0
g_v:        .byte 0
g_st0:      .byte 0
g_st1:      .byte 0
g_irr1:     .byte 0
g_irr2:     .byte 0
g_brdy_to:  .byte 0
isr_st:     .byte 0
r07:        .byte 0
r0f:        .byte 0
r0e:        .byte 0
j_hold:     .byte 0
j_res:      .fill 8, 1, 0

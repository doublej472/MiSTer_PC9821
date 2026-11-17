/* picrot.s - PICROT, what OCW2 0x80 ("rotate in automatic EOI mode, set") does to the master
 * 8259's priority pointer, the question the references split on (irqwd's style: one line at a
 * time, every register put back). Run on the core first, then on the real PC-9821Xe10.
 *
 *   PICROT > PICROT.TXT        (no arguments; about 2 s; plain DOS)
 *
 * THE RACE. With every master line masked, IR0 (the PIT, channel 0) and IR2 (the CRTC VSYNC) are
 * both made to request: PIT channel 0 is given a one-shot (mode 0, count 0400h; only when the
 * firmware left it in a one-shot mode - a periodic channel is left alone and its next tick is
 * the request) and 0x64 is written (it arms the next VSYNC interrupt). When the IRR (OCW3 0Ah)
 * shows bits 0 and 2 both set (bounded by 200 ms of ARTIC), IMR = FA (only IR0 and IR2 open) and
 * STI: the handlers this program puts on INT 08h and INT 0Ah record the order the two vectors
 * arrive in and send a specific EOI (60h | level), so neither ever rotates. The first vector is
 * the line the priority pointer ranks higher: IR0 for pry = 0, IR2 for pry = 1 or 2.
 *
 * THE ROWS (each starts with OCW2 00h then C7h: the AEOI-rotate mode cleared and pry = 0, which
 * every reference agrees C7h means; three trials each):
 *   R0    nothing else: the control (IR0 first everywhere)
 *   RA    OCW2 80h with the ISR empty: IR0 first = the pointer did not move (the 8259A data
 *         sheet, QEMU i8259.c, NP2kai io/pic.c:296 `if (!picp->isr) { break; }`, this RTL); IR2
 *         first = it stepped (MAME pic8259.cpp:305 `m_prio = (m_prio + 1) & 7;`)
 *   RB    IR0 IN SERVICE: IR0 is let in alone (IMR = FE) to a handler that does not EOI; inside it,
 *         with IF = 0, OCW2 80h and then the specific EOI 60h; then the race. IR2 first = pry 1
 *         (NP2kai :305 `picp->pry = (level + 1) & 7;`, MAME, this RTL); IR0 first = pry 0 (the
 *         data sheet, QEMU `s->rotate_on_auto_eoi = cmd >> 2;` only)
 *   RC0   OCW2 C1h (pry = 2): the control (IR2 first everywhere)
 *   RC    OCW2 C1h, then OCW2 00h: IR0 first = 00h resets the pointer (MAME :285 `m_prio = 0;`);
 *         IR2 first = it does not (the data sheet, QEMU, NP2kai, this RTL)
 *
 * SAFETY: the master IMR, both vectors and OCW3 are saved and put back; the pointer is left at
 * pry = 0 with the AEOI-rotate mode cleared (00h, C7h); every wait is an ARTIC deadline; no DOS
 * call is made while lines are masked; interrupts are on again after every row. PIT channel 0's
 * mode is never changed from a periodic one; a one-shot channel is left one-shot and expired (a
 * BIOS timer in flight at the start would be lost: run at a quiet DOS prompt).
 *
 * BUILD: make -C tools/hwprobe picrot/picrot.com
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

    .equ MPIC_CMD,  0x0000
    .equ MPIC_IMR,  0x0002
    .equ PIT0,      0x0071
    .equ PITC,      0x0077
    .equ DL_200MS,  61440
    .equ NTRIAL,    3

_start:
    push    cs
    pop     ds
    push    cs
    pop     es
    cld
    mov     dx, offset s_hdr
    call    puts
    cli
    in      al, MPIC_IMR
    mov     [imr_was], al
    mov     al, 0x0A
    out     MPIC_CMD, al
    in      al, MPIC_CMD
    mov     [irr_was], al
    mov     al, 0x0B
    out     MPIC_CMD, al
    in      al, MPIC_CMD
    mov     [isr_was], al
    mov     al, 0xE2                /* 8254 read-back: status only, counter 0 */
    out     PITC, al
    call    iodly
    in      al, PIT0
    mov     [pit_st], al
    sti
    mov     al, [pit_st]
    shr     al, 1
    and     al, 3                   /* modes 2/3 (and 6/7) are periodic */
    cmp     al, 2
    jb      1f
    mov     byte ptr [periodic], 1
1:  mov     dx, offset s_state
    call    puts
    mov     al, [imr_was]
    call    puthex8
    mov     dx, offset s_isr
    call    puts
    mov     al, [isr_was]
    call    puthex8
    mov     dx, offset s_irr
    call    puts
    mov     al, [irr_was]
    call    puthex8
    mov     dx, offset s_pit
    call    puts
    mov     al, [pit_st]
    call    puthex8
    mov     dx, offset s_per
    call    puts
    mov     al, [periodic]
    call    puthex8
    call    putnl
    cmp     byte ptr [isr_was], 0
    je      2f
    mov     dx, offset s_busy
    call    puts
    jmp     99f
2:  /* the vectors */
    mov     ax, 0x3508
    int     0x21
    mov     [v08], bx
    mov     [v08 + 2], es
    mov     ax, 0x350A
    int     0x21
    mov     [v0a], bx
    mov     [v0a + 2], es
    push    cs
    pop     es
    mov     ax, 0x2508
    mov     dx, offset h_ir0
    int     0x21
    mov     ax, 0x250A
    mov     dx, offset h_ir2
    int     0x21
    call    commit
    mov     si, offset rows
3:  cmp     byte ptr [si], 0
    je      90f
    mov     byte ptr [trial], 1
4:  push    si
    call    run_row
    pop     si
    push    si
    call    print_row
    call    commit
    pop     si
    inc     byte ptr [trial]
    cmp     byte ptr [trial], NTRIAL
    jbe     4b
    add     si, 3
    jmp     3b
90: cli
    mov     al, 0x00
    out     MPIC_CMD, al
    mov     al, 0xC7
    out     MPIC_CMD, al
    mov     al, 0x0B
    out     MPIC_CMD, al
    mov     al, [imr_was]
    out     MPIC_IMR, al
    push    ds
    lds     dx, [v08]
    mov     ax, 0x2508
    int     0x21
    pop     ds
    push    ds
    lds     dx, [v0a]
    mov     ax, 0x250A
    int     0x21
    pop     ds
    sti
    mov     dx, offset s_rest
    call    puts
    mov     al, [imr_was]
    call    puthex8
    mov     dx, offset s_now
    call    puts
    in      al, MPIC_IMR
    call    puthex8
    mov     ax, 0x3508
    int     0x21
    mov     dx, offset s_vok
    cmp     bx, [v08]
    jne     91f
    mov     ax, es
    cmp     ax, [v08 + 2]
    jne     91f
    mov     ax, 0x350A
    int     0x21
    cmp     bx, [v0a]
    jne     91f
    mov     ax, es
    cmp     ax, [v0a + 2]
    je      92f
91: mov     dx, offset s_vbad
92: push    cs
    pop     es
    call    puts
99: mov     dx, offset s_done
    call    puts
    call    commit
    mov     ax, 0x4C00
    int     0x21

/* run_row: SI = the row {.byte kind; .word name}. Fills r_irr, r_ord[0..3], r_n, r_tmo, r_pre. */
run_row:
    mov     byte ptr [r_tmo], 0
    mov     byte ptr [r_pre], 0xFF
    mov     byte ptr [hmode], 0
    cli
    mov     al, 0xFF
    out     MPIC_IMR, al
    mov     al, 0x00                /* the prelude: AEOI-rotate cleared, pry = 0 */
    out     MPIC_CMD, al
    mov     al, 0xC7
    out     MPIC_CMD, al
    mov     al, [si]
    cmp     al, 'A'
    jne     1f
    mov     al, 0x80
    out     MPIC_CMD, al
    jmp     5f
1:  cmp     al, 'B'
    jne     2f
    /* IR0 alone, to the handler that writes 80h then 60h with IR0 in service */
    mov     byte ptr [hmode], 1
    mov     byte ptr [hflag], 0
    call    arm_ir0
    mov     al, 0xFE
    out     MPIC_IMR, al
    call    artic_read
    mov     [t0], eax
    sti
11: cmp     byte ptr [hflag], 0
    jne     12f
    call    artic_read
    sub     eax, [t0]
    and     eax, 0xFFFFFF
    cmp     eax, DL_200MS
    jb      11b
    mov     byte ptr [r_tmo], 1
12: cli
    mov     al, 0xFF
    out     MPIC_IMR, al
    mov     byte ptr [hmode], 0
    mov     al, [hflag]
    mov     [r_pre], al
    cmp     byte ptr [r_tmo], 0
    je      5f
    jmp     8f
2:  cmp     al, 'D'                 /* RC0: C1h */
    jne     3f
    mov     al, 0xC1
    out     MPIC_CMD, al
    jmp     5f
3:  cmp     al, 'C'                 /* RC: C1h then 00h */
    jne     5f
    mov     al, 0xC1
    out     MPIC_CMD, al
    mov     al, 0x00
    out     MPIC_CMD, al
5:  call    race
8:  mov     al, 0xFF
    out     MPIC_IMR, al
    mov     al, 0x00
    out     MPIC_CMD, al
    mov     al, 0xC7
    out     MPIC_CMD, al
    mov     al, [imr_was]
    out     MPIC_IMR, al
    sti
    ret

/* race: (cli, IMR = FF) both requests made, IRR waited for, then IMR = FA and STI */
race:
    mov     byte ptr [r_n], 0
    mov     dword ptr [r_ord], 0
    call    arm_ir0
    out     0x64, al                /* the next VSYNC interrupt */
    call    artic_read
    mov     [t0], eax
    mov     al, 0x0A
    out     MPIC_CMD, al
1:  in      al, MPIC_CMD
    mov     [r_irr], al
    and     al, 0x05
    cmp     al, 0x05
    je      2f
    call    artic_read
    sub     eax, [t0]
    and     eax, 0xFFFFFF
    cmp     eax, DL_200MS
    jb      1b
    mov     byte ptr [r_tmo], 2
2:  mov     al, 0x0B
    out     MPIC_CMD, al
    mov     al, 0xFA
    out     MPIC_IMR, al
    call    artic_read
    mov     [t0], eax
    sti
3:  cmp     byte ptr [r_n], 2
    jae     4f
    call    artic_read
    sub     eax, [t0]
    and     eax, 0xFFFFFF
    cmp     eax, DL_200MS
    jb      3b
    or      byte ptr [r_tmo], 4
4:  cli
    mov     al, 0xFF
    out     MPIC_IMR, al
    ret

/* arm_ir0: a one-shot on PIT channel 0 (mode 0, LSB/MSB, count 0400h) unless it is periodic */
arm_ir0:
    cmp     byte ptr [periodic], 0
    jne     1f
    push    ax
    mov     al, 0x30
    out     PITC, al
    call    iodly
    mov     al, 0x00
    out     PIT0, al
    call    iodly
    mov     al, 0x04
    out     PIT0, al
    pop     ax
1:  ret

/* the handlers: record the vector, then a specific EOI (hmode 1, IR0: OCW2 80h first, the EOI
 * after it, and the flag) */
h_ir0:
    push    ax
    push    bx
    push    ds
    push    cs
    pop     ds
    cmp     byte ptr [hmode], 1
    jne     1f
    mov     al, 0x80                /* IR0 is in service here */
    out     MPIC_CMD, al
    mov     al, 0x60
    out     MPIC_CMD, al
    mov     byte ptr [hflag], 1
    jmp     9f
1:  mov     al, 0x08
    call    h_rec
    mov     al, 0x60
    out     MPIC_CMD, al
9:  pop     ds
    pop     bx
    pop     ax
    iret
h_ir2:
    push    ax
    push    bx
    push    ds
    push    cs
    pop     ds
    mov     al, 0x0A
    call    h_rec
    mov     al, 0x62
    out     MPIC_CMD, al
    pop     ds
    pop     bx
    pop     ax
    iret
h_rec:
    movzx   bx, byte ptr [r_n]
    cmp     bx, 4
    jae     1f
    mov     [r_ord + bx], al
    inc     byte ptr [r_n]
1:  ret

/* print_row: SI = the row */
print_row:
    mov     dx, offset s_row
    call    puts
    mov     dx, [si + 1]
    call    puts
    mov     dx, offset s_tr
    call    puts
    mov     al, [trial]
    call    puthex8
    mov     dx, offset s_irr
    call    puts
    mov     al, [r_irr]
    call    puthex8
    mov     dx, offset s_ord
    call    puts
    mov     cl, [r_n]
    xor     bx, bx
1:  cmp     bl, cl
    jae     2f
    cmp     bl, 4
    jae     2f
    mov     al, [r_ord + bx]
    call    puthex8
    call    putsp
    inc     bx
    jmp     1b
2:  mov     dx, offset s_n
    call    puts
    mov     al, [r_n]
    call    puthex8
    mov     dx, offset s_pre
    call    puts
    mov     al, [r_pre]
    call    puthex8
    mov     dx, offset s_tmo
    call    puts
    mov     al, [r_tmo]
    call    puthex8
    call    putnl
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

s_hdr:      .ascii "PICROT v1: OCW2 80h and the master 8259's priority pointer (IR0 = INT 08h vs IR2 = INT 0Ah)\r\n$"
s_state:    .ascii "STATE imr=$"
s_isr:      .ascii " isr=$"
s_irr:      .ascii " irr=$"
s_pit:      .ascii " pit0st=$"
s_per:      .ascii " periodic=$"
s_busy:     .ascii "PICROT SKIP: a master ISR bit is set at entry\r\n$"
s_row:      .ascii "ROW $"
s_tr:       .ascii " tr=$"
s_ord:      .ascii " order= $"
s_n:        .ascii "n=$"
s_pre:      .ascii " pre=$"
s_tmo:      .ascii " tmo=$"
s_rest:     .ascii "RESTORE IMR was=$"
s_now:      .ascii " now=$"
s_vok:      .ascii " vectors OK\r\n$"
s_vbad:     .ascii " vectors DIFF\r\n$"
s_done:     .ascii "PICROT DONE\r\n$"
s_nl:       .ascii "\r\n$"
n_r0:       .ascii "R0 $"
n_ra:       .ascii "RA $"
n_rb:       .ascii "RB $"
n_rc0:      .ascii "RC0$"
n_rc:       .ascii "RC $"

/* rows: .byte kind ('0' control, 'A', 'B', 'D' = RC0, 'C' = RC); .word name */
rows:
    .byte '0'
    .word n_r0
    .byte 'A'
    .word n_ra
    .byte 'B'
    .word n_rb
    .byte 'D'
    .word n_rc0
    .byte 'C'
    .word n_rc
    .byte 0

    .balign 4
t0:         .long 0
r_ord:      .long 0
v08:        .long 0
v0a:        .long 0
imr_was:    .byte 0
irr_was:    .byte 0
isr_was:    .byte 0
pit_st:     .byte 0
periodic:   .byte 0
trial:      .byte 0
r_irr:      .byte 0
r_n:        .byte 0
r_tmo:      .byte 0
r_pre:      .byte 0
hmode:      .byte 0
hflag:      .byte 0

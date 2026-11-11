/* selfmod.s - a store into the prefetch window: which immediate executes? (todo item 141)
 *
 *   SELFMOD > SELFMOD.TXT        (or RUNSM.BAT)
 *   SELFMOD /2 > SM2.TXT         kit 2: the other store forms (the cpu-xe10 lane's rows):
 *        A2D  A2 disp16          mov [disp16],al          (disp only, 3 bytes)
 *        BI8  C6 07 imm8         mov byte [bx],imm8       (imm only, 3 bytes)
 *        BD8  C6 47 10 imm8      mov byte [bx+0x10],imm8  (disp8 + imm, 4 bytes)
 *        W16  C7 06 disp16 imm16 mov word [disp16],0xC322 (6 bytes; the high byte rewrites the
 *                                ret with itself)
 *        P1I/P2I/P3I  the IMM form after 1/2/3 register-only `89 D9` (mov cx,bx) at the CALL
 *                     target (A is still the routine's start; D still counts from the store's end)
 *
 * WHY. Star Cruiser's drawing routine patches an immediate 18-20 bytes ahead of the
 * executing instruction with no jump in between (0060:0D40 writes into 0060:0D54). The game
 * plays on hardware at 90 MHz and stays black in the 50 MHz userdisk simulation: the likely
 * cause is that z486 executes the old immediate at one clock ratio and the new one at the
 * other. A real i486 does not snoop its prefetch queue (Intel486 Microprocessor Family
 * Programmer's Reference Manual, "self-modifying code": a store into code already fetched is
 * not seen without a jump), so the authentic answer depends on how far ahead the queue has
 * fetched. This probe asks the machine, and the core at each clock ratio, with one binary.
 *
 * METHOD. For each store FORM, ALIGNment A (0..15: the buffer's start inside a 16-byte line)
 * and distance D (1..40), a routine is generated at CS:0x4000 + A:
 *     IMM form:  C6 06 lo hi 22    mov byte [imm], 0x22    (5 bytes, DS = CS)
 *     REG form:  88 27             mov [bx], ah  (BX = imm, AH = 0x22; 2 bytes)
 *     D-1 x 90   nop
 *     B0 11      mov al, 0x11      <- imm is this instruction's immediate byte
 *     C3         ret
 * so the patched byte lies D bytes past the end of the store instruction. It runs with
 * interrupts off through `call` (a jump: the queue starts empty at the routine), and AL says
 * which immediate executed: 11 = OLD (the store was not seen), 22 = NEW. Each case runs twice:
 * run 1 straight after the routine was written, run 2 after the immediate was put back to 11
 * by a store from outside the routine (the routine is then warm in the cache).
 *
 * OUTPUT
 *   BEGIN:SELFMOD
 *   SELFMOD v1 ...
 *   ROW IMM A=0 R1=<40 chars> R2=<40 chars>    O = old, N = new, ? = neither (D = 1 first)
 *   ...                                          (16 alignments per form)
 *   END:SELFMOD
 * selfmod_decode.py prints the first D at which N appears, per row, and the summary.
 * Expected: NP2kai (i386c, no prefetch-queue model) N for every D; a real i486 O for D below
 * the bytes it has prefetched when the store executes (a 32-byte queue, filled 16 bytes at a
 * time), N beyond it.
 *
 * SAFETY. No I/O except DOS stdout; it writes only its own buffer. CPU only, ~10 ms.
 *
 * BUILD: make -C tools/hwprobe selfmod/selfmod.com
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

    .equ BUF,  0x4000
    .equ DMAX, 40
    .equ OLDV, 0x11
    .equ NEWV, 0x22

_start:
    push    cs
    pop     ds
    push    cs
    pop     es
    cld
    /* any argument containing '2' selects the kit-2 forms (2..8) */
    mov     byte ptr [form], 0
    mov     byte ptr [flast], 2
    mov     si, 0x81
    mov     cl, [0x80]
    xor     ch, ch
    jcxz    9f
8:  lodsb
    cmp     al, '2'
    jne     7f
    mov     byte ptr [form], 2
    mov     byte ptr [flast], 9
7:  loop    8b
9:  mov     dx, offset s_begin
    call    puts
f_loop:
    mov     byte ptr [algn], 0
a_loop:
    mov     byte ptr [dist], 1
d_loop:
    call    gen
    call    run
    mov     bl, [dist]
    xor     bh, bh
    mov     [r1 - 1 + bx], al
    /* run 2: the immediate put back from outside, then again */
    mov     di, [immp]
    mov     byte ptr [di], OLDV
    call    run
    mov     bl, [dist]
    xor     bh, bh
    mov     [r2 - 1 + bx], al
    inc     byte ptr [dist]
    cmp     byte ptr [dist], DMAX
    jbe     d_loop
    call    print_row
    inc     byte ptr [algn]
    cmp     byte ptr [algn], 16
    jb      a_loop
    inc     byte ptr [form]
    mov     al, [form]
    cmp     al, [flast]
    jb      f_loop
    mov     dx, offset s_end
    call    puts
    mov     ax, 0x4C00
    int     0x21

/* gen: build the routine for form/algn/dist at BUF + algn; [immp] = the immediate's address */
gen:
    mov     di, BUF
    mov     cx, 96
    mov     al, 0x90
    rep     stosb
    mov     di, BUF
    mov     al, [algn]
    xor     ah, ah
    add     di, ax
    mov     [entry], di
    /* forms 6/7/8: 1/2/3 register-only instructions (89 D9, mov cx,bx) before the IMM store */
    mov     al, [form]
    cmp     al, 6
    jb      4f
    sub     al, 5
    mov     cl, al
    xor     ch, ch
5:  mov     ax, 0xD989
    stosw
    loop    5b
4:  /* the store */
    mov     word ptr [modrm_p], 0
    mov     al, [form]
    cmp     al, 1
    je      1f
    cmp     al, 2
    je      10f
    cmp     al, 3
    je      11f
    cmp     al, 4
    je      12f
    cmp     al, 5
    je      13f
    /* 0, 6, 7, 8: C6 06 disp16 imm8 */
    mov     al, 0xC6
    stosb
    mov     al, 0x06
    stosb
    mov     [modrm_p], di       /* the disp16 is filled in below */
    add     di, 2
    mov     al, NEWV
    stosb
    jmp     2f
1:  mov     al, 0x88            /* 88 27: mov [bx],ah */
    stosb
    mov     al, 0x27
    stosb
    jmp     2f
10: mov     al, 0xA2            /* A2 disp16: mov [disp16],al (AL = NEWV) */
    stosb
    mov     [modrm_p], di
    add     di, 2
    jmp     2f
11: mov     ax, 0x07C6          /* C6 07 imm8: mov byte [bx],imm8 */
    stosw
    mov     al, NEWV
    stosb
    jmp     2f
12: mov     ax, 0x47C6          /* C6 47 10 imm8: mov byte [bx+0x10],imm8 (BX = imm - 0x10) */
    stosw
    mov     al, 0x10
    stosb
    mov     al, NEWV
    stosb
    jmp     2f
13: mov     ax, 0x06C7          /* C7 06 disp16 imm16: mov word [disp16],0xC322 (the ret kept) */
    stosw
    mov     [modrm_p], di
    add     di, 2
    mov     ax, 0xC300 + NEWV
    stosw
2:  /* D-1 nops */
    mov     cl, [dist]
    xor     ch, ch
    dec     cx
    mov     al, 0x90
    rep     stosb
    mov     al, 0xB0
    stosb
    mov     [immp], di
    mov     al, OLDV
    stosb
    mov     al, 0xC3
    stosb
    mov     bx, [modrm_p]
    test    bx, bx
    jz      3f
    mov     ax, [immp]
    mov     [bx], ax
3:  ret

/* run: call the routine with IF = 0; AL = 'O', 'N' or '?' */
run:
    pushf
    cli
    mov     bx, [immp]
    cmp     byte ptr [form], 4
    jne     1f
    sub     bx, 0x10
1:  mov     ah, NEWV
    mov     al, NEWV            /* form 2 stores AL; the routine's mov al overwrites it */
    call    word ptr [entry]
    popf
    cmp     al, OLDV
    jne     1f
    mov     al, 'O'
    ret
1:  cmp     al, NEWV
    jne     2f
    mov     al, 'N'
    ret
2:  mov     al, '?'
    ret

print_row:
    mov     dx, offset s_row
    call    puts
    mov     bl, [form]
    xor     bh, bh
    shl     bx, 1
    mov     dx, [fnames + bx]
    call    puts
    mov     dx, offset s_a
    call    puts
    mov     al, [algn]
    call    puthex8
    mov     dx, offset s_r1
    call    puts
    mov     si, offset r1
    call    putn
    mov     dx, offset s_r2
    call    puts
    mov     si, offset r2
    call    putn
    mov     dx, offset s_crlf
    call    puts
    ret
putn:                           /* DMAX chars at SI */
    mov     cx, DMAX
1:  mov     dl, [si]
    call    putc
    inc     si
    loop    1b
    ret

putc:                           /* DL */
    push    ax
    mov     ah, 0x02
    int     0x21
    pop     ax
    ret
puts:                           /* DX = '$' string */
    push    ax
    mov     ah, 0x09
    int     0x21
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
    call    putc
    ret

s_begin:    .ascii "BEGIN:SELFMOD\r\n"
            .ascii "SELFMOD v1: a store D bytes ahead (D=1..40) into a mov al,imm8; O = old immediate ran, N = new; R1 fresh, R2 warm\r\n$"
s_end:      .ascii "END:SELFMOD\r\n$"
s_row:      .ascii "ROW $"
s_imm:      .ascii "IMM$"
s_reg:      .ascii "REG$"
s_f2:       .ascii "A2D$"
s_f3:       .ascii "BI8$"
s_f4:       .ascii "BD8$"
s_f5:       .ascii "W16$"
s_f6:       .ascii "P1I$"
s_f7:       .ascii "P2I$"
s_f8:       .ascii "P3I$"
    .balign 2
fnames:     .word s_imm, s_reg, s_f2, s_f3, s_f4, s_f5, s_f6, s_f7, s_f8
s_a:        .ascii " A=$"
s_r1:       .ascii " R1=$"
s_r2:       .ascii " R2=$"
s_crlf:     .ascii "\r\n$"
form:       .byte 0
flast:      .byte 0
algn:       .byte 0
dist:       .byte 0
    .balign 2
entry:      .word 0
immp:       .word 0
modrm_p:    .word 0
r1:         .space DMAX
r2:         .space DMAX

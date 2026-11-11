/* rstdtr.s - IDTR/GDTR (and EDX, CR0) straight after a CPU-only reset (todo item 53)
 *
 *   RSTDTR > RSTDTR.TXT
 *
 * WHY. The machine reads IDTR/GDTR limit FFFF at the DOS prompt (docs/probes/KIT1-XE10-CFG0.TXT:78),
 * the core 03FF; the 486 manuals give 03FF for IDTR after reset. The DOS-prompt value went through
 * the whole POST. This reads them after a reset WITHOUT the POST: the PC-98 CPU-only reset (out
 * 0xF0) with SHUT0 clear, whose firmware entry returns through the SS:SP stored at 0000:0404
 * (cpusuite.asm "THE RETURN": BANK7.BIN@0x5804-0x5817, FD80:0004 `mov ss,[0x406] / mov sp,[0x404]`
 * ... FD80:0780 rewrites CR0, `retf`; no LIDT/LGDT on that path per the cpu-xe10 lane's ROM scan).
 * SIDT and SGDT are the first instructions at the landing (after one store of EDX, the reset's
 * component ID).
 *
 * RESTORE. Before the reset: IDTR, GDTR, CR0, both 8259 masks, port C (0x35, for SHUT0) and the A20
 * state (a wrap test of 0000:0500 against FFFF:0510) are saved; after it they are put back (LIDT,
 * LGDT, CR0, the masks, out 0x35, A20 enabled through 0xF2 only if it was enabled), then STI.
 *
 * LINE: RSTDTR pre idt=llll:bbbbbbbb gdt=... cr0=xxxxxxxx | reset idt=... gdt=... cr0=... edx=...
 *       END:RSTDTR
 *
 * BUILD: make -C tools/hwprobe rstdtr/rstdtr.com
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
    mov     dx, offset s_begin
    call    puts
    cli
    sidt    [pre_idt]
    sgdt    [pre_gdt]
    mov     eax, cr0
    mov     [pre_cr0], eax
    in      al, 0x02
    mov     [imr_m], al
    in      al, 0x0A
    mov     [imr_s], al
    in      al, 0x35
    mov     [portc], al
    /* A20: is FFFF:0510 the same byte as 0000:0500? flip a byte at 0000:0500 and look */
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     bl, [0x500]
    mov     ax, 0xFFFF
    mov     es, ax
    mov     al, bl
    not     al
    mov     [0x500], al
    cmp     al, es:[0x510]
    mov     [0x500], bl
    pop     ds
    push    cs
    pop     es
    setne   byte ptr [a20on]
    mov     [save_ss], ss
    mov     [save_sp], sp
    /* the return: SS:SP at 0000:0404 point at a far pointer to `landing` */
    mov     word ptr [land_stk], offset landing
    mov     [land_stk + 2], cs
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     word ptr [0x404], offset land_stk
    mov     ax, cs
    mov     [0x406], ax
    pop     ds
    mov     al, 0x0E
    out     0x37, al            /* SHUT0 = 0 */
    out     0xF0, al            /* the CPU-only reset */
1:  jmp     1b

landing:
    mov     cs:[r_edx], edx
    sidt    cs:[r_idt]
    sgdt    cs:[r_gdt]
    cli
    mov     eax, cr0
    mov     cs:[r_cr0], eax
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     ss, [save_ss]
    mov     sp, [save_sp]
    lidt    [pre_idt]
    lgdt    [pre_gdt]
    mov     eax, [pre_cr0]
    mov     cr0, eax
    mov     al, [imr_m]
    out     0x02, al
    mov     al, [imr_s]
    out     0x0A, al
    mov     al, [portc]
    out     0x35, al
    cmp     byte ptr [a20on], 0
    je      2f
    out     0xF2, al
2:  sti
    mov     dx, offset s_pre
    call    puts
    mov     si, offset pre_idt
    call    put_dtr
    mov     dx, offset s_gdt
    call    puts
    mov     si, offset pre_gdt
    call    put_dtr
    mov     dx, offset s_cr0
    call    puts
    mov     eax, [pre_cr0]
    call    puthex32
    mov     dx, offset s_rst
    call    puts
    mov     si, offset r_idt
    call    put_dtr
    mov     dx, offset s_gdt
    call    puts
    mov     si, offset r_gdt
    call    put_dtr
    mov     dx, offset s_cr0
    call    puts
    mov     eax, [r_cr0]
    call    puthex32
    mov     dx, offset s_edx
    call    puts
    mov     eax, [r_edx]
    call    puthex32
    mov     dx, offset s_a20
    call    puts
    mov     dl, [a20on]
    add     dl, '0'
    call    putc
    mov     dx, offset s_end
    call    puts
    mov     ax, 0x4C00
    int     0x21

put_dtr:                        /* [si] limit16, [si+2] base32 -> llll:bbbbbbbb */
    mov     ax, [si]
    call    puthex16
    mov     dl, ':'
    call    putc
    mov     eax, [si + 2]
    call    puthex32
    ret
puthex32:
    push    eax
    shr     eax, 16
    call    puthex16
    pop     eax
puthex16:
    push    ax
    mov     al, ah
    call    puthex8
    pop     ax
puthex8:
    push    ax
    shr     al, 4
    call    1f
    pop     ax
    and     al, 0x0F
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
puts:
    push    ax
    mov     ah, 0x09
    int     0x21
    pop     ax
    ret

s_begin:    .ascii "BEGIN:RSTDTR\r\n$"
s_pre:      .ascii "RSTDTR pre idt=$"
s_gdt:      .ascii " gdt=$"
s_cr0:      .ascii " cr0=$"
s_rst:      .ascii " | reset idt=$"
s_edx:      .ascii " edx=$"
s_a20:      .ascii " a20=$"
s_end:      .ascii "\r\nEND:RSTDTR\r\n$"
    .balign 4
pre_idt:    .space 8
pre_gdt:    .space 8
r_idt:      .space 8
r_gdt:      .space 8
pre_cr0:    .long 0
r_cr0:      .long 0
r_edx:      .long 0
save_ss:    .word 0
save_sp:    .word 0
imr_m:      .byte 0
imr_s:      .byte 0
portc:      .byte 0
a20on:      .byte 0
    .balign 2
            .space 64           /* the firmware pushes/pops EAX below SP */
land_stk:   .word 0, 0
            .space 16

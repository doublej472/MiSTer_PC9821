/* ide640.s - IDE640, what IDE ports 0x0640 and 0x0641 read on each bank (0x0432) with device 0
 * and device 1 selected and no command pending. Read-only except the bank select (0x0432) and the
 * drive/head register (0x064C), both put back. Run on the core first, then on the Xe10.
 *
 *   IDE640 > IDE640.TXT        (no arguments; instant; plain DOS)
 *
 * The bank select is ideprobe's (tools/hwprobe/ideprobe/ideprobe.s pm_bank): 0x0432 read as
 * found, written, put back, all under cli with no BIOS call between. For bank 00 (the as-found
 * idle bank at a DOS prompt, docs/probes/KIT1-XE10-IDEPROBE.TXT `0432=00`) and bank 01 (the
 * live bank, `task file with 0432=01 (live bank)`): the task file read as found, then with
 * 0x064C <- A0 (device 0) and <- B0 (device 1); each row reads 0x0640, 0x0641 (twice), 0x064E
 * (status) and 0x064C. 0x064C goes back to its as-found read before the bank is left; 0x0432
 * last. No command register is ever written.
 *
 * EXPECTED (ide640_decode.py): 0x0641 on the idle bank: the core 00, the machine as found FF
 * (KIT1-XE10-IDEPROBE.TXT:8 `0640=06 0641=FF`); on the live bank, device 0, BSY/DRQ clear: FF
 * (:21 `0640=50 0641=FF`) on both.
 *
 * BUILD: make -C tools/hwprobe ide640/ide640.com
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
    mov     dx, offset s_hdr
    call    puts
    cli
    mov     dx, 0x0432
    in      al, dx
    mov     [bank_was], al
    mov     di, offset res
    mov     si, offset banks
1:  lodsb
    cmp     al, 0xEE
    je      5f
    mov     dx, 0x0432
    out     dx, al
    call    iodly
    mov     dx, 0x064C
    in      al, dx
    mov     [dh_was], al
    mov     al, 0xFF                /* the as-found row: no 064C write */
    call    one
    mov     al, 0xA0
    call    one
    mov     al, 0xB0
    call    one
    mov     dx, 0x064C
    mov     al, [dh_was]
    out     dx, al
    call    iodly
    jmp     1b
5:  mov     dx, 0x0432
    mov     al, [bank_was]
    out     dx, al
    call    iodly
    in      al, dx
    mov     [bank_now], al
    sti
    /* print */
    mov     si, offset res
    mov     cx, 6
6:  mov     dx, offset s_row
    call    puts
    mov     al, [si]
    call    puthex8
    mov     dx, offset s_dh
    call    puts
    mov     al, [si + 1]
    cmp     al, 0xFF
    jne     7f
    mov     dx, offset s_asf
    call    puts
    jmp     8f
7:  call    puthex8
8:  mov     dx, offset s_640
    call    puts
    mov     al, [si + 2]
    call    puthex8
    mov     dx, offset s_641
    call    puts
    mov     al, [si + 3]
    call    puthex8
    call    putsp
    mov     al, [si + 4]
    call    puthex8
    mov     dx, offset s_64e
    call    puts
    mov     al, [si + 5]
    call    puthex8
    mov     dx, offset s_64c
    call    puts
    mov     al, [si + 6]
    call    puthex8
    call    putnl
    add     si, 8
    loop    6b
    mov     dx, offset s_rest
    call    puts
    mov     al, [bank_was]
    call    puthex8
    mov     dx, offset s_now
    call    puts
    mov     al, [bank_now]
    call    puthex8
    call    putnl
    mov     dx, offset s_done
    call    puts
    mov     ax, 0x4C00
    int     0x21

/* one: AL = the 0x064C value (FF = none); stores {bank, dh, 640, 641, 641, 64E, 64C, 0} at DI */
one:
    push    ax
    mov     dx, 0x0432
    in      al, dx
    stosb
    pop     ax
    stosb
    cmp     al, 0xFF
    je      1f
    mov     dx, 0x064C
    out     dx, al
    call    iodly
1:  mov     dx, 0x0640
    in      al, dx
    stosb
    mov     dx, 0x0641
    in      al, dx
    stosb
    in      al, dx
    stosb
    mov     dx, 0x064E
    in      al, dx
    stosb
    mov     dx, 0x064C
    in      al, dx
    stosb
    xor     al, al
    stosb
    ret

iodly:
    push    ax
    push    cx
    mov     cx, 8
1:  out     0x5F, al
    loop    1b
    pop     cx
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

s_hdr:      .ascii "IDE640 v1: 0x0640/0x0641 per bank (0x0432) and device (0x064C), no command\r\n$"
s_row:      .ascii "IDE bank=$"
s_dh:       .ascii " dh=$"
s_asf:      .ascii "--$"
s_640:      .ascii " r640=$"
s_641:      .ascii " r641=$"
s_64e:      .ascii " r64E=$"
s_64c:      .ascii " r64C=$"
s_rest:     .ascii "RESTORE 0432 was=$"
s_now:      .ascii " now=$"
s_done:     .ascii "IDE640 DONE\r\n$"
s_nl:       .ascii "\r\n$"
banks:      .byte 0x00, 0x01, 0xEE
bank_was:   .byte 0
bank_now:   .byte 0
dh_was:     .byte 0
res:        .fill 48, 1, 0

/* fdmode.s - the floppy interface-mode state the BIOS leaves after boot, and whether the
 * 640 KB (DA/UA 0x7x) interface answers.
 *
 * THE QUESTION. The Xe10 BIOS initialises the 640 KB window (0xC8/0xCA/0xCC) at POST when
 * port 0x00BE bit 2 reads 0 (BANK7@0x7CAE), waiting on the 0xC8 MSR while bit 0 still selects
 * the 1 MB window. NP2kai answers 0xFF on the inactive window (io/fdc.c fdc_i90), MAME maps
 * the controller at both windows: the two references decide whether that wait times out,
 * IRQ10 stays masked and INT 1Bh DA/UA 0x7x answers AH = 0x40. This probe records what the
 * machine does.
 *
 * METHOD (read-only except two INT 1Bh SENSE calls): print the ports 0x02, 0x0A (PIC IMRs),
 * 0x90, 0x94, 0xBE, 0xBF, 0x04BE, 0xC8, 0xCC (no data port is read, so no FDC phase is
 * disturbed), the BIOS work bytes 0x480, 0x494, 0x500, 0x501, 0x55C-0x55F, 0x584, 0x5CA,
 * 0x5CB, 0x5D7, then INT 1Bh AH=04h (SENSE) for DA/UA 0x90 and 0x70 with the returned AH and
 * carry, then the IMRs and 0xBE again.
 *
 * Build: make -C tools/hwprobe fdmode/fdmode.com
 * Run:   FDMODE > FDMODE.TXT     (from a freshly booted DOS prompt)
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

_start:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     dx, offset s_banner
    call    puts
    call    dump_ports
    /* the BIOS work bytes */
    mov     si, offset memtab
1:  mov     bx, [si]
    cmp     bx, 0xFFFF
    je      2f
    mov     dx, offset s_mem
    call    puts
    mov     ax, bx
    call    puthex16
    mov     dl, '='
    call    putc
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     al, [bx]
    pop     ds
    call    puthex8
    call    putnl
    add     si, 2
    jmp     1b
2:
    mov     al, 0x90
    call    sense
    mov     al, 0x70
    call    sense
    mov     dx, offset s_after
    call    puts
    call    dump_ports
    mov     ax, 0x4C00
    int     0x21

/* INT 1Bh AH=04h for DA/UA AL; prints "SENSE da AH=xx CF=n" */
sense:
    push    ax
    mov     dx, offset s_sense
    call    puts
    call    puthex8
    pop     ax
    mov     ah, 0x04
    int     0x1B
    pushf
    push    ax
    mov     dx, offset s_ah
    call    puts
    pop     ax
    mov     al, ah
    call    puthex8
    mov     dx, offset s_cf
    call    puts
    popf
    mov     al, 0
    adc     al, 0
    call    puthexdig
    call    putnl
    ret

dump_ports:
    mov     si, offset porttab
1:  mov     dx, [si]
    cmp     dx, 0xFFFF
    je      2f
    push    dx
    mov     dx, offset s_port
    call    puts
    pop     dx
    mov     ax, dx
    call    puthex16
    mov     dl, '='
    call    putc
    mov     dx, [si]
    in      al, dx
    call    puthex8
    call    putnl
    add     si, 2
    jmp     1b
2:  ret

putc:                           /* DL = character */
    push    ax
    mov     ah, 0x02
    int     0x21
    pop     ax
    ret
puts:                           /* DX = '$'-terminated string */
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
puthexdig:                      /* AL = 0..15 */
    push    ax
    push    dx
    and     al, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     6f
    add     al, 7
6:  mov     dl, al
    call    putc
    pop     dx
    pop     ax
    ret
puthex8:                        /* AL */
    push    ax
    push    ax
    shr     al, 4
    call    puthexdig
    pop     ax
    call    puthexdig
    pop     ax
    ret
puthex16:                       /* AX */
    push    ax
    mov     al, ah
    call    puthex8
    pop     ax
    call    puthex8
    ret

s_banner:   .ascii "FDMODE floppy interface mode after boot (tools/hwprobe/fdmode)\r\n$"
s_port:     .ascii "PORT $"
s_mem:      .ascii "MEM $"
s_sense:    .ascii "SENSE DA=$"
s_ah:       .ascii " AH=$"
s_cf:       .ascii " CF=$"
s_after:    .ascii "AFTER SENSE\r\n$"
porttab:    .word 0x0002, 0x000A, 0x0090, 0x0094, 0x00BE, 0x00BF, 0x04BE, 0x00C8, 0x00CC, 0xFFFF
memtab:     .word 0x0480, 0x0494, 0x0500, 0x0501, 0x055C, 0x055D, 0x055E, 0x055F, 0x0584
            .word 0x05CA, 0x05CB, 0x05D7, 0xFFFF

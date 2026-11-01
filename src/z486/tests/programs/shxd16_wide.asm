; shxd16_wide.asm - SHLD/SHRD r16 with a count of 17..31 (pre-P6 silicon:
;   SHLD shifts dest:src:src, SHRD src:src:dest; Bochs shld/shrd BX_CPU_LEVEL<6)
; Expected values computed for dest=1234h, src=A5C3h.
; Results: port 0xE0 status (0x01 pass / 0xFF fail), port 0xE4 fail code (count<<16 | 1 shld / 2 shrd).
BITS 16
org 0
start:
    mov si, table
    mov cl, 17
.loop:
    mov ax, 0x1234
    mov bx, 0xA5C3
    shld ax, bx, cl
    cmp ax, [cs:si]
    jne .fail_l
    mov ax, 0x1234
    mov bx, 0xA5C3
    shrd ax, bx, cl
    cmp ax, [cs:si+2]
    jne .fail_r
    add si, 4
    inc cl
    cmp cl, 32
    jne .loop
    mov al, 1
    out 0xE0, al
    hlt
.fail_l:
    movzx eax, cl
    shl eax, 16
    or al, 1
    jmp .fail
.fail_r:
    movzx eax, cl
    shl eax, 16
    or al, 2
.fail:
    out 0xE4, eax
    mov al, 0xFF
    out 0xE0, al
    hlt
align 2
table:
    dw 0x4B87, 0xD2E1   ; count 17
    dw 0x970E, 0xE970   ; count 18
    dw 0x2E1D, 0x74B8   ; count 19
    dw 0x5C3A, 0x3A5C   ; count 20
    dw 0xB874, 0x1D2E   ; count 21
    dw 0x70E9, 0x0E97   ; count 22
    dw 0xE1D2, 0x874B   ; count 23
    dw 0xC3A5, 0xC3A5   ; count 24
    dw 0x874B, 0xE1D2   ; count 25
    dw 0x0E97, 0x70E9   ; count 26
    dw 0x1D2E, 0xB874   ; count 27
    dw 0x3A5C, 0x5C3A   ; count 28
    dw 0x74B8, 0x2E1D   ; count 29
    dw 0xE970, 0x970E   ; count 30
    dw 0xD2E1, 0x4B87   ; count 31

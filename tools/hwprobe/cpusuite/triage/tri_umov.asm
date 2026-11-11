; tri_umov - triage probe: what UMOV (0F 10-13) does on the part. Each form runs once; a #UD is
; caught (IVT 6) and recorded. data (E4) = bit n: form n raised #UD | (byte stored by form 0 << 16)
; | (BL after form 1 << 24). trap EAX[31:8] = AX loaded by form 3 (low 16 of [BUF+8]=0x8899 expected).
;   form 0: 0F 10 /r  umov [bx+1], dl (DL=11h)     form 1: 0F 10 mod=11  umov bl, ah (AH=99h)
;   form 2: 0F 11 /r  umov [bx+4], cx (3344h)      form 3: 0F 13 /r  umov ax, [bx+8]
BITS 16
org 0
BUF equ 0x6000
start:
    cli
    xor ax, ax
    mov ss, ax
    mov ds, ax
    mov sp, 0x8000
    mov word [6*4], ud_handler
    mov [6*4+2], cs
    xor bp, bp
    mov dword [BUF], 0
    mov dword [BUF+4], 0
    mov word [BUF+8], 0x8899
    mov bx, BUF
    mov si, 1
    mov dl, 0x11
    mov word [cs:resume], .f1
    db 0x0f, 0x10, 0x57, 0x01
.f1:
    mov si, 2
    mov ah, 0x99
    mov bl, 0
    mov word [cs:resume], .f2
    db 0x0f, 0x10, 0xe3
.f2:
    mov dh, bl
    mov bx, BUF
    mov si, 4
    mov cx, 0x3344
    mov word [cs:resume], .f3
    db 0x0f, 0x11, 0x4f, 0x04
.f3:
    mov si, 8
    mov ax, 0x5555
    mov word [cs:resume], .f4
    db 0x0f, 0x13, 0x47, 0x08
.f4:
    mov di, ax
    movzx eax, dh
    shl eax, 8
    mov al, [BUF+1]
    shl eax, 16
    or ax, bp
    out 0xE4, eax
    movzx eax, di
    shl eax, 8
    mov al, 0xFF
    out 0xE0, al
    hlt
ud_handler:
    or bp, si
    push bp
    mov bp, sp
    push ax
    mov ax, [cs:resume]
    mov [bp+2], ax
    pop ax
    pop bp
    iret
resume: dw 0

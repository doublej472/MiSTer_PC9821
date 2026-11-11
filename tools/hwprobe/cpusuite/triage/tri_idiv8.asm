; tri_idiv8 - triage probe (not a contract test): IDIV r8 cases the Xe10 completed without #DE.
; data (E4) = AX after case A (741Eh / 98h) | AX after case B (7F81h / 81h) << 16
; trap EAX[31:24] = bit 1: case A raised #DE, bit 0: case B raised #DE; a #DE leaves AX = dividend.
BITS 16
org 0
start:
    cli
    xor ax, ax
    mov ss, ax
    mov sp, 0x8000
    mov es, ax
    mov word [es:0], de_handler
    mov [es:2], cs
    mov ax, cs
    mov ds, ax
    xor bp, bp
    mov word [resume], .a_done
    mov ax, 0x741E
    mov cl, 0x98
    idiv cl
.a_done:
    mov si, ax
    shl bp, 1
    mov word [resume], .b_done
    mov ax, 0x7F81
    mov cl, 0x81
    idiv cl
.b_done:
    mov di, ax
    movzx eax, di
    shl eax, 16
    mov ax, si
    out 0xE4, eax
    ; bit0 = case B, bit1 = case A (bp shifted once after A)
    mov ax, bp
    shl eax, 24
    mov al, 0xFF
    out 0xE0, al
    hlt
de_handler:
    or bp, 1
    push bp
    mov bp, sp
    push ax
    mov ax, [cs:resume]
    mov [bp+2], ax
    pop ax
    pop bp
    iret
resume: dw 0

; tri_idiv1632 - triage probe (not a contract test): IDIV r16/r32 overflows that the 386/486
; non-restoring divider's 7F..F -> 80..0 quotient ripple (US 5,689,721) would complete, the wider
; analogue of the IDIV r8 cases the Xe10 completed (741Eh/98h, 7F81h/81h).  The loop model predicts
; for every case below: A-D complete with quotient 8000h / 80000000h, E-F raise #DE.
;   A: r16  DX:AX = 7FFF8001h        / 8001h      (div_edges case 569)  model AX=8000h DX=0001h
;   B: r16  DX:AX = BFCBFFE2h        / 0068h      (negative dividend)   model AX=8000h DX=FFE2h
;   C: r32  EDX:EAX = 7FFFFFFF80000001h / 80000001h (div_edges case 927) model EAX=80000000h EDX=1
;   D: r32  EDX:EAX = BFFFFFCBFFFFFFE2h / 00000068h (negative dividend)  model EAX=80000000h EDX=FFFFFFE2h
;   E: r16  DX:AX = BFCC0000h        / 0068h      (negative, remainder 0: model #DE)
;   F: r16  DX:AX = 40340068h        / FF98h      (remainder = |divisor|: model #DE)
; data (E4) = remainder (DX/EDX) low byte of A<<24 | B<<16 | C<<8 | D   (model 01E201E2h)
; trap EAX[31:24] = bits 0-3: A-D raised #DE; bits 4-7: A-D quotient is exactly 8000h/80000000h
;   (model F0h; z486 today, the documented rule: 0Fh)
; trap EAX[23:16] = bit 0: E raised #DE, bit 1: F raised #DE (model 03h)
; A #DE leaves the dividend registers unchanged (remainder byte = the dividend's DX/EDX low byte).
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
    xor ebx, ebx                ; bl: #DE bits (A=0..F=5), bh: exact-quotient bits (A=4..D=7)
    xor esi, esi                ; remainder bytes

    mov byte [bit], 0x01        ; A
    mov word [resume], .a_done
    mov dx, 0x7FFF
    mov ax, 0x8001
    mov cx, 0x8001
    idiv cx
.a_done:
    cmp ax, 0x8000
    jne .a_q
    or bh, 0x10
.a_q:
    shl esi, 8
    mov [rbyte], dl
    or si, [rbyte]

    mov byte [bit], 0x02        ; B
    mov word [resume], .b_done
    mov dx, 0xBFCB
    mov ax, 0xFFE2
    mov cx, 0x0068
    idiv cx
.b_done:
    cmp ax, 0x8000
    jne .b_q
    or bh, 0x20
.b_q:
    shl esi, 8
    mov [rbyte], dl
    or si, [rbyte]

    mov byte [bit], 0x04        ; C
    mov word [resume], .c_done
    mov edx, 0x7FFFFFFF
    mov eax, 0x80000001
    mov ecx, 0x80000001
    idiv ecx
.c_done:
    cmp eax, 0x80000000
    jne .c_q
    or bh, 0x40
.c_q:
    shl esi, 8
    mov [rbyte], dl
    or si, [rbyte]

    mov byte [bit], 0x08        ; D
    mov word [resume], .d_done
    mov edx, 0xBFFFFFCB
    mov eax, 0xFFFFFFE2
    mov ecx, 0x00000068
    idiv ecx
.d_done:
    cmp eax, 0x80000000
    jne .d_q
    or bh, 0x80
.d_q:
    shl esi, 8
    mov [rbyte], dl
    or si, [rbyte]

    mov byte [bit], 0x10        ; E
    mov word [resume], .e_done
    mov dx, 0xBFCC
    xor ax, ax
    mov cx, 0x0068
    idiv cx
.e_done:
    mov byte [bit], 0x20        ; F
    mov word [resume], .f_done
    mov dx, 0x4034
    mov ax, 0x0068
    mov cx, 0xFF98
    idiv cx
.f_done:
    mov eax, esi
    out 0xE4, eax
    ; EAX[31:24] = {exact bits (bh[7:4]), #DE bits A-D (bl[3:0])}, EAX[23:16] = #DE bits E-F
    xor eax, eax
    mov al, bh
    and al, 0xF0
    mov ah, bl
    and ah, 0x0F
    or al, ah
    shl eax, 24
    mov dl, bl
    shr dl, 4
    and edx, 0x03
    shl edx, 16
    or eax, edx
    mov al, 0xFF
    out 0xE0, al
    hlt
de_handler:
    push bp
    mov bp, sp
    push ax
    mov al, [cs:bit]
    or bl, al
    mov ax, [cs:resume]
    mov [bp+2], ax
    pop ax
    pop bp
    iret
resume: dw 0
bit:    db 0
align 2
rbyte:  dw 0

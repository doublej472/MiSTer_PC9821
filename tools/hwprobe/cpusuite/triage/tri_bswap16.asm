; tri_bswap16 - triage probe: BSWAP with a 16-bit operand size (0F C9 in 16-bit code, no 66h).
; data (E4) = ECX after BSWAP CX with ECX = 89ABCDEFh (z486 today: EFCDAB89h; Bochs: 89AB0000h)
; trap EAX[31:16] = FLAGS before XOR FLAGS after (0 = flags unchanged)
BITS 16
org 0
start:
    cli
    xor ax, ax
    mov ss, ax
    mov sp, 0x8000
    mov ecx, 0x89abcdef
    pushf
    pop si
    db 0x0f, 0xc9
    pushf
    pop di
    mov eax, ecx
    out 0xE4, eax
    xor si, di
    movzx eax, si
    shl eax, 16
    mov al, 0xFF
    out 0xE0, al
    hlt

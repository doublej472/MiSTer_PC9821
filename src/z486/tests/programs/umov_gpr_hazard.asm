; umov_gpr_hazard.asm - 486 UMOV (0F 10-13, the 80386 CROM's MOV aliases)
; right after a write to its source or address register, alone and behind a
; fall-through Jcc, so the next-instruction GPR read mask must name the
; source register (store and register forms) or the pending write is missed.
; NASM has no UMOV mnemonic: each form is spelled with db.
; UMOV outside an ICE behaves as MOV on the 486: R. Collins, "Undocumented
; OpCodes: UMOV": "Available on all 80386/80486 processors", "If UMOV is
; executed by a user program, it will appear it is a alias for MOV".  A real
; Am486DX4 executes every form without #UD and its register form moves the
; byte (CPUSUITE-XE10-triage: tri_umov data=99000000h, umov bl,ah = 99h);
; its memory forms did not reach normal memory there (store not landing,
; load 0079h), which no source explains, so z486 keeps them plain MOV and
; this program checks memory forms against MOV.
BITS 16
org 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
BUF         equ 0x6000

%macro CHECK8 2                 ; CHECK8 byte-at-BUF, expected
    cmp byte [%1], %2
    jne fail
%endmacro

start:
    cli
    xor ax, ax
    mov ss, ax
    mov ds, ax
    mov sp, 0x8000
    mov bx, BUF
    mov dword [BUF], 0
    mov dword [BUF+4], 0

    ; 1. UMOV r/m8,r8 store (0F 10 /r, [bx+1]) right after the DL write.
    mov dl, 0x11
    db 0x0f, 0x10, 0x57, 0x01           ; umov [bx+1], dl
    CHECK8 BUF+1, 0x11

    ; 2. The same store behind a fall-through Jcc (the predecoded successor).
    xor cx, cx                          ; ZF=1
    mov dl, 0x22
    jnz fail
    db 0x0f, 0x10, 0x57, 0x02           ; umov [bx+2], dl
    CHECK8 BUF+2, 0x22

    ; 3. UMOV r/m16,r16 store (0F 11 /r) behind a Jcc after the CX write.
    xor ax, ax
    mov cx, 0x3344
    jnz fail
    db 0x0f, 0x11, 0x4f, 0x04           ; umov [bx+4], cx
    cmp word [BUF+4], 0x3344
    jne fail

    ; 4. UMOV r/m32,r32 store behind a Jcc after the EDI write.
    xor ax, ax
    mov edi, 0x55667788
    jnz fail
    db 0x66, 0x0f, 0x11, 0x7f, 0x00     ; umov [bx], edi
    cmp dword [BUF], 0x55667788
    jne fail

    ; 5. UMOV r/m8,r8 register form (0F 10 /r, mod=11): BL <- AH.
    xor cx, cx
    mov ah, 0x99
    jnz fail
    db 0x0f, 0x10, 0xe3                 ; umov bl, ah
    cmp bl, 0x99
    jne fail
    mov bx, BUF

    ; 6. UMOV r/m16,r16 register form (0F 11 /r): SI <- DX.
    xor cx, cx
    mov dx, 0xabcd
    jnz fail
    db 0x0f, 0x11, 0xd6                 ; umov si, dx
    cmp si, 0xabcd
    jne fail

    ; 7. UMOV r8,r/m8 register form (0F 12 /r, mod=11): CH <- DH.
    xor ax, ax
    mov dh, 0x5a
    jnz fail
    db 0x0f, 0x12, 0xee                 ; umov ch, dh
    cmp ch, 0x5a
    jne fail

    ; 8. UMOV r16,r/m16 register form (0F 13 /r): BP <- AX.
    xor cx, cx
    mov ax, 0x1357
    jnz fail
    db 0x0f, 0x13, 0xe8                 ; umov bp, ax
    cmp bp, 0x1357
    jne fail

    ; 9. UMOV r32,r/m32 register form behind a Jcc: EDX <- ESI.
    xor cx, cx
    mov esi, 0x2468ace0
    jnz fail
    db 0x66, 0x0f, 0x13, 0xd6           ; umov edx, esi
    cmp edx, 0x2468ace0
    jne fail

    ; 10. UMOV r8,r/m8 and r16,r/m16 memory forms (loads) right after the
    ;     address register write.
    mov byte [BUF+6], 0x77
    mov word [BUF+2], 0x8899
    xor cx, cx
    mov bx, BUF+4
    jnz fail
    db 0x0f, 0x12, 0x47, 0x02           ; umov al, [bx+2]
    cmp al, 0x77
    jne fail
    mov bx, BUF
    db 0x0f, 0x13, 0x4f, 0x02           ; umov cx, [bx+2]
    cmp cx, 0x8899
    jne fail

    ; 11. A store form right after the address register write.
    mov dl, 0xc3
    mov bx, BUF+4
    db 0x0f, 0x10, 0x57, 0x03           ; umov [bx+3], dl
    CHECK8 BUF+7, 0xc3

    mov al, 0x01
    mov dx, STATUS_PORT
    out dx, al
    hlt

fail:
    mov dx, DATA_PORT
    out dx, ax
    mov al, 0xFF
    mov dx, STATUS_PORT
    out dx, al
    hlt

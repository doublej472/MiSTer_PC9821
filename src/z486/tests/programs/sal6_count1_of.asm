; sal6_count1_of.asm - group-2 /6 (the undocumented SAL encoding) by a count of
; one sets OF = MSB(result) XOR CF, exactly as /4 (SHL) does.
;
; Reference: Intel486 Programmer's Reference Manual, SAL/SAR/SHL/SHR: "SAL and
; SHL perform the same operation"; the OF flag "is affected only for single-bit
; shifts".  /6 is the reserved encoding of the same instruction: NP2kai's group-2
; tables map it to SHL (i386c/ia32/inst_table.c insttable_G2Eb[] row 6
; `SHL_Eb,`), and every SingleStepTests 80386 real-mode capture for D0 /6 and
; D1 /6 (2434 and 2421 non-faulting cases, 386EX silicon) ends with
; OF == CF ^ SF, the SHL rule, while OF changes in about half of them.
;
; Each case first forces OF to the opposite of its expected value, so a /6 that
; leaves OF untouched fails.  Covers D0/D1 /6 (count 1), C0/C1 /6 with an
; immediate 1 and D2/D3 /6 with CL=1, register and memory operands, byte, word
; and dword.  On failure, port 0xE4 gets BL = case number, AX = (OF|CF) seen.
BITS 16
org 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
MEMOP       equ 0x4000

%macro OF_SET 0                 ; OF=1 (0x7F + 1 overflows)
    mov ah, 0x7F
    add ah, 1
%endmacro
%macro OF_CLR 0                 ; OF=0, CF=0
    xor ah, ah
%endmacro
; CHECK want: the case's expected (OF|CF) in EFLAGS bits 11 and 0
%macro CHECK 1
    pushf
    pop ax
    and ax, 0x0801
    cmp ax, %1
    jne fail
    inc bl
%endmacro

start:
    cli
    xor ax, ax
    mov ss, ax
    mov ds, ax
    mov sp, 0x8000
    mov bl, 1

    ; 1: D0 /6 AL: 0x40 -> 0x80, CF=0, OF=1
    OF_CLR
    mov al, 0x40
    db 0xD0, 0xF0               ; sal al, 1
    CHECK 0x0800
    ; 2: D0 /6 AL: 0xC0 -> 0x80, CF=1, OF=0
    OF_SET
    mov al, 0xC0
    db 0xD0, 0xF0
    CHECK 0x0001
    ; 3: D0 /6 AL: 0x80 -> 0x00, CF=1, OF=1
    OF_CLR
    mov al, 0x80
    db 0xD0, 0xF0
    CHECK 0x0801
    ; 4: D1 /6 BX: 0x4000 -> 0x8000, CF=0, OF=1
    OF_CLR
    mov bx, 0x4000
    db 0xD1, 0xF3               ; sal bx, 1
    mov bx, 4                   ; BX was the operand: restore the case number
    CHECK 0x0800
    ; 5: D1 /6 DX: 0xC000 -> 0x8000, CF=1, OF=0
    OF_SET
    mov dx, 0xC000
    db 0xD1, 0xF2               ; sal dx, 1
    CHECK 0x0001
    ; 6: 66 D1 /6 EDX: 0x40000000 -> 0x80000000, CF=0, OF=1
    OF_CLR
    mov edx, 0x40000000
    db 0x66, 0xD1, 0xF2         ; sal edx, 1
    CHECK 0x0800
    ; 7: 66 D1 /6 EDX: 0xC0000000 -> 0x80000000, CF=1, OF=0
    OF_SET
    mov edx, 0xC0000000
    db 0x66, 0xD1, 0xF2
    CHECK 0x0001
    ; 8: C0 /6 ib 1 AL: 0x40 -> 0x80, CF=0, OF=1
    OF_CLR
    mov al, 0x40
    db 0xC0, 0xF0, 0x01         ; sal al, 1 (imm8)
    CHECK 0x0800
    ; 9: C1 /6 ib 1 DX: 0xC000 -> 0x8000, CF=1, OF=0
    OF_SET
    mov dx, 0xC000
    db 0xC1, 0xF2, 0x01         ; sal dx, 1 (imm8)
    CHECK 0x0001
    ; 10: D2 /6 AL, CL=1: 0x40 -> 0x80, CF=0, OF=1
    mov cl, 1
    OF_CLR
    mov al, 0x40
    db 0xD2, 0xF0               ; sal al, cl
    CHECK 0x0800
    ; 11: D3 /6 DX, CL=1: 0xC000 -> 0x8000, CF=1, OF=0
    OF_SET
    mov dx, 0xC000
    db 0xD3, 0xF2               ; sal dx, cl
    CHECK 0x0001
    ; 12: D0 /6 byte [MEMOP]: 0x40 -> 0x80, CF=0, OF=1
    mov byte [MEMOP], 0x40
    OF_CLR
    db 0xD0, 0x36
    dw MEMOP                    ; sal byte [MEMOP], 1
    CHECK 0x0800
    cmp byte [MEMOP], 0x80
    jne fail
    ; 13: D1 /6 word [MEMOP]: 0xC000 -> 0x8000, CF=1, OF=0
    mov word [MEMOP], 0xC000
    OF_SET
    db 0xD1, 0x36
    dw MEMOP                    ; sal word [MEMOP], 1
    CHECK 0x0001
    cmp word [MEMOP], 0x8000
    jne fail
    ; 14: 66 D1 /6 dword [MEMOP]: 0x40000000 -> 0x80000000, CF=0, OF=1
    mov dword [MEMOP], 0x40000000
    OF_CLR
    db 0x66, 0xD1, 0x36
    dw MEMOP                    ; sal dword [MEMOP], 1
    CHECK 0x0800
    cmp dword [MEMOP], 0x80000000
    jne fail
    ; 15: the result of a register /6 matches /4: AL 0x40 -> 0x80
    mov al, 0x40
    db 0xD0, 0xF0
    cmp al, 0x80
    jne fail

    mov al, 0x01
    mov dx, STATUS_PORT
    out dx, al
    hlt

fail:
    mov dx, DATA_PORT
    out dx, ax
    mov al, bl
    out dx, al
    mov al, 0xFF
    mov dx, STATUS_PORT
    out dx, al
    hlt

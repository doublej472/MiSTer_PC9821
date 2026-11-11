; idiv_quotient_bounds.asm - IDIV signed-quotient range at every width.
;
; Intel486 PRM, IDIV: "#DE if the quotient is too large for the designated
; register".  The signed range is asymmetric, so the most negative quotient
; (-80h, -8000h, -80000000h) is a valid result while +80h, +8000h and
; +80000000h overflow.  Each width checks:
;   - a valid -max-1 quotient from a positive and from a negative dividend,
;     with its remainder;
;   - a +max+1 quotient (negative / -1 and positive / 2), which faults and
;     leaves the dividend registers unchanged;
;   - a quotient far below -max-1 that the 386/486 divider does NOT fault
;     (byte cases here; the word and dword forms below).  Its non-restoring loop leaves an unadjusted quotient of 7Fh,
;     which the sign correction ripples to 80h (US 5,689,721, "Detecting
;     overflow conditions for negative quotients in nonrestoring two's
;     complement division": the anomalous overflows "occur in 386- and
;     486-type microprocessors manufactured by Intel").  The real Am486DX4
;     (CPUSUITE-XE10 run 1, idiv_quotient_bounds data=00001E07) completes
;     AX=741Eh / CL=98h with AH=1Eh and no #DE, as the 80386EX does
;     (SingleStepTests 67F6.7 idx 375: AX=1E80h).  Every such 386 capture
;     leaves AL=80h and AH = (dividend + 80h * divisor) mod 100h.  The
;     loop is width-generic and the Am486DX4 completes the word and dword
;     forms the same way (CPUSUITE-XE10 triage run, tri_idiv1632
;     data=01E201E2 eax=F00300FF: cases 15h, 16h, 25h, 26h below complete
;     with quotient 8000h / 80000000h and remainder low byte 01h, E2h, 01h,
;     E2h; 17h and 18h, just outside the pattern, raise #DE).
;   - a quotient just below -max-1, which faults on every width.
; The #DE handler counts faults and resumes at [resume]; an unexpected #DE
; reports the case number with bit 7 set.

BITS 16
org 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4

%macro EXPECT_DE 1              ; next IDIV must fault, resume at %1
    mov word [cs:resume], %1
%endmacro

start:
    cli
    cld
    mov ax, cs
    mov ds, ax
    mov ss, ax
    mov sp, 0x0F00
    xor ax, ax
    mov es, ax
    mov word [es:0x00], de_handler
    mov [es:0x02], cs
    mov word [de_count], 0
    mov word [resume], unexpected_de

    ;=== byte: AX / r/m8 -> AL quotient, AH remainder ===
    mov bl, 1
    mov ax, 0xFF00              ; -256 / 2 = -128 r 0
    mov cl, 2
    idiv cl
    cmp ax, 0x0080
    jne fail
    inc bl
    mov ax, 0x0080              ; 128 / -1 = -128 r 0
    mov cl, 0xFF
    idiv cl
    cmp ax, 0x0080
    jne fail
    inc bl
    mov ax, 0xFE7F              ; -385 / 3 = -128 r -1
    mov byte [mem8], 3
    idiv byte [mem8]
    cmp ax, 0xFF80
    jne fail
    inc bl
    mov ax, 0x017F              ; 383 / -3 = -127 r 2
    mov cl, 0xFD
    idiv cl
    cmp ax, 0x0281
    jne fail
    inc bl                      ; 5: -128 / -1 = +128 -> #DE
    EXPECT_DE .b5
    mov ax, 0xFF80
    mov cl, 0xFF
    idiv cl
    jmp fail
.b5:
    cmp ax, 0xFF80
    jne fail
    inc bl                      ; 6: 256 / 2 = +128 -> #DE
    EXPECT_DE .b6
    mov ax, 0x0100
    mov byte [mem8], 2
    idiv byte [mem8]
    jmp fail
.b6:
    cmp ax, 0x0100
    jne fail
    inc bl                      ; 7: 29726 / -104 = -285 -> AX=1E80h, no #DE
    mov ax, 0x741E              ;    (Xe10: AH=1Eh; 386EX 67F6.7 idx 375: 1E80h)
    mov cl, 0x98
    idiv cl
    cmp ax, 0x1E80
    jne fail
    inc bl                      ; 8: -258 / 2 = -129 -> #DE
    EXPECT_DE .b8
    mov ax, 0xFEFE
    mov cl, 2
    idiv cl
    jmp fail
.b8:
    cmp ax, 0xFEFE
    jne fail
    ; 9-15: more 386EX captures that complete out of range (SingleStepTests
    ; real mode; the operands are the capture's AX and r/m8).
    inc bl                      ; 9: F6.7 idx 469: 648Ch / B7h -> 0C80h
    mov ax, 0x648C
    mov cl, 0xB7
    idiv cl
    cmp ax, 0x0C80
    jne fail
    inc bl                      ; 10: F6.7 idx 516: 9C71h / 47h -> F180h
    mov ax, 0x9C71
    mov byte [mem8], 0x47
    idiv byte [mem8]
    cmp ax, 0xF180
    jne fail
    inc bl                      ; 11: F6.7 idx 850: 8947h / 6Dh -> C780h
    mov ax, 0x8947
    mov cl, 0x6D
    idiv cl
    cmp ax, 0xC780
    jne fail
    inc bl                      ; 12: F6.7 idx 1265: 4800h / F0h -> 0080h
    mov ax, 0x4800
    mov cl, 0xF0
    idiv cl
    cmp ax, 0x0080
    jne fail
    inc bl                      ; 13: F6.7 idx 1754: ACE8h / 26h -> E880h
    mov ax, 0xACE8
    mov cl, 0x26
    idiv cl
    cmp ax, 0xE880
    jne fail
    inc bl                      ; 14: F6.7 idx 2348: 7DBDh / 85h -> 3D80h
    mov ax, 0x7DBD
    mov cl, 0x85
    idiv cl
    cmp ax, 0x3D80
    jne fail
    inc bl                      ; 15: 67F6.7 idx 460: 6180h / BDh -> 0080h
    mov ax, 0x6180
    mov cl, 0xBD
    idiv cl
    cmp ax, 0x0080
    jne fail
    inc bl                      ; 16: US 5,689,721's worked example,
    mov ax, 0xB0F8              ;     -20232 / 30 (quotient -674): "adjustment
    mov cl, 0x1E                ;     ripples it to 10000000", no overflow
    idiv cl
    cmp al, 0x80
    jne fail
    inc bl                      ; 17: Xe10 div_edges case 231: 7F81h / 81h
    mov ax, 0x7F81              ;     (quotient -257) completes, no #DE
    mov cl, 0x81
    idiv cl
    cmp al, 0x80
    jne fail
    cmp word [de_count], 3
    jne fail

    ;=== word: DX:AX / r/m16 ===
    mov bl, 0x11
    mov dx, 0xFFFF              ; -65536 / 2 = -32768 r 0
    xor ax, ax
    mov cx, 2
    idiv cx
    cmp ax, 0x8000
    jne fail
    test dx, dx
    jne fail
    inc bl
    xor dx, dx                  ; 32768 / -1 = -32768
    mov ax, 0x8000
    mov word [mem16], 0xFFFF
    idiv word [mem16]
    cmp ax, 0x8000
    jne fail
    test dx, dx
    jne fail
    inc bl                      ; 13: -32768 / -1 = +32768 -> #DE
    EXPECT_DE .w3
    mov dx, 0xFFFF
    mov ax, 0x8000
    mov cx, 0xFFFF
    idiv cx
    jmp fail
.w3:
    cmp dx, 0xFFFF
    jne fail
    cmp ax, 0x8000
    jne fail
    inc bl                      ; 14: 65536 / 2 = +32768 -> #DE
    EXPECT_DE .w4
    mov dx, 1
    xor ax, ax
    mov cx, 2
    idiv cx
    jmp fail
.w4:
    cmp dx, 1
    jne fail
    test ax, ax
    jne fail
    ; 15h-18h: the 7FFFh -> 8000h ripple at r16 (Xe10 tri_idiv1632 A, B, E, F).
    ; It completes a signs-differ divide with |dividend| = 40000000h +
    ; 8000h * |divisor| + r, 0 <= r < |divisor| (r > 0 for a negative
    ; dividend), as AX=8000h, DX = (dividend + 8000h * divisor) mod 10000h.
    inc bl                      ; 15h: 7FFF8001h / 8001h (div_edges 569)
    mov dx, 0x7FFF
    mov ax, 0x8001
    mov cx, 0x8001
    idiv cx
    cmp ax, 0x8000
    jne fail
    cmp dx, 0x0001
    jne fail
    inc bl                      ; 16h: BFCBFFE2h / 68h (negative dividend)
    mov dx, 0xBFCB
    mov ax, 0xFFE2
    mov cx, 0x0068
    idiv cx
    cmp ax, 0x8000
    jne fail
    cmp dx, 0xFFE2
    jne fail
    inc bl                      ; 17h: BFCC0000h / 68h: r = 0 for a negative
    EXPECT_DE .w7               ;      dividend, outside the pattern -> #DE
    mov dx, 0xBFCC
    xor ax, ax
    mov cx, 0x0068
    idiv cx
    jmp fail
.w7:
    cmp dx, 0xBFCC
    jne fail
    test ax, ax
    jne fail
    inc bl                      ; 18h: 40340068h / FF98h: r = |divisor|,
    EXPECT_DE .w8               ;      outside the pattern -> #DE
    mov dx, 0x4034
    mov ax, 0x0068
    mov cx, 0xFF98
    idiv cx
    jmp fail
.w8:
    cmp dx, 0x4034
    jne fail
    cmp ax, 0x0068
    jne fail
    cmp word [de_count], 7
    jne fail

    ;=== dword: EDX:EAX / r/m32 ===
    mov bl, 0x21
    mov edx, 0xFFFFFFFF         ; -2^32 / 2 = -2^31 r 0
    xor eax, eax
    mov ecx, 2
    idiv ecx
    cmp eax, 0x80000000
    jne fail
    test edx, edx
    jne fail
    inc bl
    xor edx, edx                ; 2^31 / -1 = -2^31
    mov eax, 0x80000000
    mov dword [mem32], 0xFFFFFFFF
    idiv dword [mem32]
    cmp eax, 0x80000000
    jne fail
    test edx, edx
    jne fail
    inc bl                      ; 0x23: -2^31 / -1 = +2^31 -> #DE
    EXPECT_DE .d3
    mov edx, 0xFFFFFFFF
    mov eax, 0x80000000
    mov ecx, 0xFFFFFFFF
    idiv ecx
    jmp fail
.d3:
    cmp edx, 0xFFFFFFFF
    jne fail
    cmp eax, 0x80000000
    jne fail
    inc bl                      ; 0x24: 2^32 / 2 = +2^31 -> #DE
    EXPECT_DE .d4
    mov edx, 1
    xor eax, eax
    mov ecx, 2
    idiv ecx
    jmp fail
.d4:
    cmp edx, 1
    jne fail
    test eax, eax
    jne fail
    ; 25h-26h: the ripple at r32 (Xe10 tri_idiv1632 C, D): EAX=80000000h,
    ; EDX = (dividend + 80000000h * divisor) mod 2^32.
    inc bl                      ; 25h: 7FFFFFFF80000001h / 80000001h (div_edges 927)
    mov edx, 0x7FFFFFFF
    mov eax, 0x80000001
    mov ecx, 0x80000001
    idiv ecx
    cmp eax, 0x80000000
    jne fail
    cmp edx, 0x00000001
    jne fail
    inc bl                      ; 26h: BFFFFFCBFFFFFFE2h / 68h (negative dividend)
    mov edx, 0xBFFFFFCB
    mov eax, 0xFFFFFFE2
    mov ecx, 0x00000068
    idiv ecx
    cmp eax, 0x80000000
    jne fail
    cmp edx, 0xFFFFFFE2
    jne fail
    cmp word [de_count], 9
    jne fail

    mov al, 0x01
    out STATUS_PORT, al
    hlt

unexpected_de:
    or bl, 0x80                 ; a valid quotient raised #DE
fail:
    mov al, bl
    out DATA_PORT, al
    mov al, 0xFF
    out STATUS_PORT, al
    hlt

de_handler:
    push bp
    push si
    mov bp, sp
    mov si, [cs:resume]
    mov [bp+4], si              ; frame IP -> resume point
    mov word [cs:resume], unexpected_de
    inc word [cs:de_count]
    pop si
    pop bp
    iret

align 4
resume:   dw 0
de_count: dw 0
mem8:     db 0
align 2
mem16:    dw 0
align 4
mem32:    dd 0

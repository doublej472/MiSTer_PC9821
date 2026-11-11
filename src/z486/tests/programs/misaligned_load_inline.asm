; misaligned_load_inline.asm - direct loads that cross a dword boundary inside
; one 16-byte line, and loads from lines that also hold executed code.
;
; An i486 cache hit on a misaligned operand runs as two cache cycles (Intel
; i486 Microprocessor data book, instruction timing assumptions: misaligned
; operands add 3 clocks), so such a load costs about 4 clocks, not the
; ~10.5 that paging's crossing path took (measured with the XE10T CPU probe
; replica: every unaligned 32-bit load, whether its line held code or not).
;
; Values: every crossing shape (word at byte 3, dword at bytes 1..3, MOVSX,
; ALU-with-memory, POP with an unaligned SP, back to back, a pointer load
; feeding the next EA, a store to either dword just before the load, a line
; crossing that still takes paging) is checked against the bytes read one by
; one.  Code lines: an aligned and an unaligned load of an executed routine's
; bytes return its encoding (load after execute), and a store into that
; routine is what the next call executes (store after execute).
; Timing: 32 warm unaligned loads, and 32 warm aligned loads from a code
; line, each read against the testbench cycle counter (port 0xFC).
;
; Port 0xE0: status (0x01 pass, 0xFF fail); port 0xE4: failure code.
BITS 16
org 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
CYCLE_PORT  equ 0xFC

DATA        equ 0x8000
; 32 loads plus the two port reads.  Aligned: 2 clocks each.  Unaligned in a
; line: about 4.5 each with the two-dword probe, about 10.5 through paging.
MAX_MIS     equ 200
MAX_ALN     equ 100

%macro FAILIF 2
    j%1 near fail_%2
%endmacro

; ebx <- the dword at %1 assembled from its four bytes
%macro BYTES32 1
    movzx ebx, byte [%1+3]
    shl ebx, 8
    mov bl, [%1+2]
    shl ebx, 8
    mov bl, [%1+1]
    shl ebx, 8
    mov bl, [%1]
%endmacro

%macro CHECKD 2
    mov eax, [%1]
    BYTES32 %1
    cmp eax, ebx
    FAILIF ne, %2
%endmacro

start:
    cli
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xF000
    cld

    ; DATA[k] = k*0x3B + 0x91 (every byte distinct over 64)
    mov di, DATA
    mov cx, 64
    mov al, 0x91
.fill:
    stosb
    add al, 0x3B
    loop .fill

    ; dwords at byte 1, 2, 3 of a dword, in each word of a line but the last
    CHECKD DATA+0x01, 1
    CHECKD DATA+0x02, 2
    CHECKD DATA+0x03, 3
    CHECKD DATA+0x05, 4
    CHECKD DATA+0x0A, 5
    CHECKD DATA+0x13, 6
    ; a dword crossing the 16-byte line (paging's crossing path)
    CHECKD DATA+0x0E, 7
    CHECKD DATA+0x1D, 8

    ; word at byte 3, zero- and sign-extended
    mov ax, [DATA+0x07]
    BYTES32 DATA+0x07
    cmp ax, bx
    FAILIF ne, 9
    movsx eax, word [DATA+0x17]
    movsx ebx, bx
    BYTES32 DATA+0x17
    movsx ebx, bx
    cmp eax, ebx
    FAILIF ne, 10

    ; ALU with an unaligned memory operand
    mov ecx, 0x01020304
    add ecx, [DATA+0x21]
    BYTES32 DATA+0x21
    add ebx, 0x01020304
    cmp ecx, ebx
    FAILIF ne, 11

    ; back to back, then both checked
    mov eax, [DATA+0x25]
    mov edx, [DATA+0x26]
    mov esi, [DATA+0x27]
    BYTES32 DATA+0x25
    cmp eax, ebx
    FAILIF ne, 12
    BYTES32 DATA+0x26
    cmp edx, ebx
    FAILIF ne, 13
    BYTES32 DATA+0x27
    cmp esi, ebx
    FAILIF ne, 14

    ; an unaligned pointer load feeding the next EA
    mov word [DATA+0x33], DATA+0x29
    mov si, [DATA+0x33]
    mov eax, [si]
    BYTES32 DATA+0x29
    cmp eax, ebx
    FAILIF ne, 15

    ; a store to the low dword, then to the high dword, just before the load
    mov dword [DATA+0x30], 0xA1B2C3D4
    mov eax, [DATA+0x31]
    BYTES32 DATA+0x31
    cmp eax, ebx
    FAILIF ne, 16
    mov byte [DATA+0x34], 0x5A
    mov eax, [DATA+0x32]
    BYTES32 DATA+0x32
    cmp eax, ebx
    FAILIF ne, 17
    cmp eax, 0xC85AA1B2      ; D4 C3 [B2 A1] 5A [C8]: DATA+0x35 = 0x35*0x3B+0x91
    FAILIF ne, 18

    ; POP with an unaligned stack pointer
    mov bp, sp
    mov sp, DATA+0x39
    pop eax
    pop cx
    mov dx, sp
    mov sp, bp
    BYTES32 DATA+0x39
    cmp eax, ebx
    FAILIF ne, 19
    BYTES32 DATA+0x3D
    cmp cx, bx
    FAILIF ne, 20
    cmp dx, DATA+0x3F
    FAILIF ne, 21

    ; load after execute: the routine's own bytes, aligned and not
    call routine
    cmp ax, 0x1111
    FAILIF ne, 22
    mov eax, [routine]
    cmp eax, 0xC31111B8
    FAILIF ne, 23
    mov eax, [routine+1]
    cmp eax, 0x90C31111
    FAILIF ne, 24
    ; store after execute: the next call runs the new immediate
    mov word [routine+1], 0x2222
    call routine
    cmp ax, 0x2222
    FAILIF ne, 25
    mov eax, [routine+1]
    cmp eax, 0x90C32222
    FAILIF ne, 26

    ; timing: 32 unaligned loads in one line (second pass warm)
    mov di, 2
.tmis:
    in eax, CYCLE_PORT
    mov ebp, eax
%rep 32
    mov ebx, [DATA+0x01]
%endrep
    in eax, CYCLE_PORT
    sub eax, ebp
    dec di
    jnz .tmis
    out DATA_PORT, eax
    cmp eax, MAX_MIS
    FAILIF a, 27

    ; timing: 32 aligned loads from an executed code line
    mov di, 2
.taln:
    in eax, CYCLE_PORT
    mov ebp, eax
%rep 32
    mov ebx, [routine]
%endrep
    in eax, CYCLE_PORT
    sub eax, ebp
    dec di
    jnz .taln
    out DATA_PORT, eax
    cmp eax, MAX_ALN
    FAILIF a, 28

    mov al, 0x01
    out STATUS_PORT, al
    hlt

%assign k 1
%rep 28
fail_%[k]:
    mov ax, k
    jmp fail
%assign k k+1
%endrep
fail:
    out DATA_PORT, ax
    mov al, 0xFF
    out STATUS_PORT, al
    hlt

    align 16
routine:
    mov ax, 0x1111      ; B8 11 11
    ret                 ; C3
    nop                 ; 90
    nop

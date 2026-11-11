; real_far_tail.asm - real-mode far transfers through the shared CS-load tail
; (ucode 2EB..2F3: CALL/JMP ptr16:16 and m16:16, RETF, RETF imm16, IRET).
;
; Each transfer goes to a routine through a DIFFERENT selector for the same
; code (CS+1 with the offset 16 lower), so a CS base the tail failed to load
; lands 16 bytes off and the routine's own check fails; every return checks
; CS and the stack.  The CS limit the tail keeps is checked by running a
; routine at offset 0xFFF0 of a segment whose code sits right below the 64 KiB
; limit.  Timing: 16 CALL m16:16 + RETF pairs, warm, against the testbench
; cycle counter (port 0xFC).  The i486 takes 17 + 13 clocks (MAME cycles.h,
; 486 column); the 386 tail z486 inherited restored the unchanged CS limit
; through three more words (41 clocks a pair, 35 without them).
;
; Port 0xE0: status (0x01 pass, 0xFF fail); port 0xE4: failure code.
BITS 16
org 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
CYCLE_PORT  equ 0xFC
MAX_PAIRS   equ 16*38

%macro FAILIF 2
    j%1 near fail_%2
%endmacro

start:
    cli
    mov ax, cs
    mov ds, ax
    mov ss, ax
    mov sp, 0xF000
    mov [cs0], ax
    inc ax
    mov [cs1], ax               ; the alias selector: base 16 higher
    ; far pointers to the alias entry points (offset - 16)
    mov word [p_rtn], rtn - 16
    mov [p_rtn+2], ax
    mov word [p_rtn_imm], rtn_imm - 16
    mov [p_rtn_imm+2], ax
    mov word [p_jmp], jmp_target - 16
    mov [p_jmp+2], ax
    mov word [jmp_ptr], jmp_back
    mov ax, [cs0]
    mov [jmp_ptr+2], ax

    ; CALL m16:16 to the alias, RETF back
    xor bx, bx
    call far [p_rtn]
    cmp bx, 0x1111
    FAILIF ne, 1
    mov ax, cs
    cmp ax, [cs0]
    FAILIF ne, 2
    cmp sp, 0xF000
    FAILIF ne, 3

    ; CALL ptr16:16 (patched immediate) to the alias, RETF imm16 back
    mov ax, [cs1]
    mov [call_ptr+3], ax
    mov word [call_ptr+1], rtn_imm - 16
    push word 0x5555
    push word 0x6666
    xor bx, bx
    jmp short call_ptr          ; leave the patched line for a refetch
call_ptr:
    call 0:0
    cmp bx, 0x2222
    FAILIF ne, 4
    cmp sp, 0xF000              ; RETF 4 dropped the two words
    FAILIF ne, 5
    mov ax, cs
    cmp ax, [cs0]
    FAILIF ne, 6

    ; JMP m16:16 to the alias; it comes back with JMP ptr16:16
    xor bx, bx
    jmp far [p_jmp]
jmp_back:
    cmp bx, 0x3333
    FAILIF ne, 7
    mov ax, cs
    cmp ax, [cs0]
    FAILIF ne, 8

    ; IRET to the alias (and an IRET-built frame back)
    xor bx, bx
    pushf
    push word [cs1]
    push word iret_target - 16
    iret
iret_back:
    cmp bx, 0x4444
    FAILIF ne, 9
    mov ax, cs
    cmp ax, [cs0]
    FAILIF ne, 10
    cmp sp, 0xF000
    FAILIF ne, 11

    ; the kept 64 KiB limit: edge_rtn, reached as offset 0xFFF0 of the
    ; segment whose base lies 0xFFF0 below it, runs and RETFs back
    mov ax, cs
    add ax, (edge_rtn - $$) / 16 - 0x0FFF
    mov [p_edge+2], ax
    mov word [p_edge], 0xFFF0
    xor bx, bx
    call far [p_edge]
    cmp bx, 0x5A5A
    FAILIF ne, 12

    ; timing: 16 CALL m16:16 + RETF pairs (second pass warm)
    mov word [p_rtn], rtn_fast
    mov ax, cs
    mov [p_rtn+2], ax
    mov di, 2
.again:
    in eax, CYCLE_PORT
    mov ebp, eax
%rep 16
    call far [p_rtn]
%endrep
    in eax, CYCLE_PORT
    sub eax, ebp
    dec di
    jnz .again
    out DATA_PORT, eax
    cmp eax, MAX_PAIRS
    FAILIF a, 13

    mov al, 0x01
    out STATUS_PORT, al
    hlt

; the routines run through the alias selector CS1 (CS0+1): their offsets are
; 16 below the labels.  Data is read through DS (CS0), so a wrong base shows as
; a wrong landing, not a wrong value.
    align 16
rtn:
    mov ax, cs
    cmp ax, [cs1]
    jne .bad
    mov bx, 0x1111
    retf
.bad:
    mov bx, 0xBAD1
    retf
rtn_imm:
    mov ax, cs
    cmp ax, [cs1]
    jne .bad
    cmp sp, 0xF000 - 8          ; two pushed words + the return address
    jne .bad
    mov bx, 0x2222
    retf 4
.bad:
    mov bx, 0xBAD2
    retf 4
jmp_target:
    mov ax, cs
    cmp ax, [cs1]
    jne .bad
    mov bx, 0x3333
.bad:
    jmp 0:0                     ; patched below to CS0:jmp_back
jmp_ptr equ $ - 4
iret_target:
    mov ax, cs
    cmp ax, [cs1]
    jne .bad
    mov bx, 0x4444
.bad:
    pushf
    push word [cs0]
    push word iret_back
    iret
rtn_fast:
    retf
    align 16
edge_rtn:
    mov bx, 0x5A5A
    retf

%assign k 1
%rep 13
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

align 4
cs0:       dw 0
cs1:       dw 0
p_rtn:     dd 0
p_rtn_imm: dd 0
p_jmp:     dd 0
p_edge:    dd 0

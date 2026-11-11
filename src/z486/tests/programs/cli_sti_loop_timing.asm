; cli_sti_loop_timing.asm - issue rate of CLI, STI and a LOOP that falls
; through, against the testbench cycle counter (port 0xFC).
;
; i486 clocks (MAME src/devices/cpu/i386/cycles.h, 486 column): CLI 5,
; STI 5, LOOP not taken 6.  The 386 microcode z486 inherits flushed and
; refetched the next sequential instruction after CLI/STI (8 clocks) and
; after a LOOP that falls through (about 10.9).  Each phase runs 32 copies
; twice (the second pass is measured, warm) and bounds the total.
;
; Port 0xE0: status (0x01 pass, 0xFF fail); port 0xE4: the measured counts,
; then the failure code.
BITS 16
org 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
CYCLE_PORT  equ 0xFC

; 32 instructions plus the two port reads (about 10 clocks)
MAX_CLI     equ 32*6
MAX_STICLI  equ 32*12
MAX_LOOPNT  equ 32*8

%macro TIMED 3          ; body, bound, failure code
    mov di, 2
%%again:
    in eax, CYCLE_PORT
    mov ebp, eax
%rep 32
    %1
%endrep
    in eax, CYCLE_PORT
    sub eax, ebp
    dec di
    jnz %%again
    out DATA_PORT, eax
    cmp eax, %2
    ja %%fail
    jmp %%ok
%%fail:
    mov ax, %3
    jmp fail
%%ok:
%endmacro

%macro STICLI 0
    sti
    cli
%endmacro
%macro LOOPNT 0
    mov cx, 1
    loop $+2
%endmacro
%macro MOVCX 0
    mov cx, 1
    nop
    nop
%endmacro

start:
    cli
    mov ax, cs
    mov ds, ax
    mov ss, ax
    mov sp, 0xF000

    TIMED cli, MAX_CLI, 1
    TIMED STICLI, MAX_STICLI, 2
    ; the LOOP phase carries a MOV CX,1 per LOOP: measure it alone and
    ; bound the difference
    TIMED MOVCX, 0x7FFFFFFF, 3
    mov esi, eax
    TIMED LOOPNT, 0x7FFFFFFF, 4
    sub eax, esi
    add eax, 32*2           ; MOVCX's two NOPs, about 1 clock each
    out DATA_PORT, eax
    cmp eax, MAX_LOOPNT
    ja .loop_fail
    cmp cx, 0
    jne .loop_fail
    mov al, 0x01
    out STATUS_PORT, al
    hlt
.loop_fail:
    mov ax, 5
fail:
    out DATA_PORT, ax
    mov al, 0xFF
    out STATUS_PORT, al
    hlt

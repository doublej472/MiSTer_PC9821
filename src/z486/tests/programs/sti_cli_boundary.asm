; sti_cli_boundary.asm - the exact boundary at which INTR is taken around STI
; and CLI.
;
; i486 PRM (STI): after STI sets IF, the processor responds to external
; interrupts after executing the NEXT instruction; (CLI): external interrupts
; are not recognized once CLI has executed.  So a request pending across STI
; is taken with the return address after the instruction following STI, never
; between STI and that instruction, and STI;CLI opens no window at all.  A
; request that is taken around CLI is taken with the return address AT the
; CLI (before it), never after it.
;
; Each case records the ISR's return IP.  The cycle sweeps raise INTR at
; every delay from 1 to 24 cycles after the request so it lands on each
; boundary of the STI/CLI sequences (the instruction after STI is hardwired
; in one sweep and microcoded in another).
;
; Port 0xE0: status (0x01 pass, 0xFF fail); port 0xE4: failure code.
BITS 16
org 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
SIGNAL_PORT equ 0xE8
SIGNAL_CYCLES_PORT equ 0xEC
SIGNAL_INSTR_PORT  equ 0xF0
SIGNAL_VECTOR_PORT equ 0xF4
INTR_VECTOR equ 0x20
SWEEP       equ 24

%macro FAILIF 2
    j%1 near fail_%2
%endmacro

; request INTR %1 cycles from now (mode 3: IF may be clear)
%macro REQ 1
    mov ax, %1
    out SIGNAL_CYCLES_PORT, ax
    mov al, 3
    out SIGNAL_PORT, al
%endmacro

start:
    cli
    cld
    mov ax, cs
    mov ds, ax
    mov ss, ax
    mov sp, 0xF000
    xor ax, ax
    mov es, ax
    mov word [es:INTR_VECTOR*4], isr
    mov [es:INTR_VECTOR*4+2], cs
    mov al, INTR_VECTOR
    out SIGNAL_VECTOR_PORT, al
    xor ax, ax
    out SIGNAL_INSTR_PORT, ax       ; cycle-delay mode

    ; A: pending across STI, a hardwired store after it
    mov word [count], 0
    REQ 1
    times 8 nop
    cmp word [count], 0
    FAILIF ne, 1                    ; taken with IF clear
    sti
    mov byte [m1], 1
..@a_after:
    mov byte [m2], 1
    cli
    cmp word [count], 1
    FAILIF ne, 2
    cmp word [ret_ip], ..@a_after
    FAILIF ne, 3

    ; B: pending across STI, a microcoded instruction after it
    mov word [count], 0
    REQ 1
    times 8 nop
    sti
    cld
..@b_after:
    nop
    cli
    cmp word [count], 1
    FAILIF ne, 4
    cmp word [ret_ip], ..@b_after
    FAILIF ne, 5

    ; C: STI;CLI opens no window; the request stays pending until STI;NOP
    mov word [count], 0
    REQ 1
    times 8 nop
    sti
    cli
    times 8 nop
    cmp word [count], 0
    FAILIF ne, 6
    sti
    nop
..@c_after:
    nop
    cli
    cmp word [count], 1
    FAILIF ne, 7
    cmp word [ret_ip], ..@c_after
    FAILIF ne, 8

    ; D: INTR raised 1..SWEEP cycles after a request, IF set, then CLI:
    ; taken (if at all) at the CLI, never after it.
    mov si, 1
.d_loop:
    mov word [count], 0
    mov word [ret_ip], 0
    sti
    REQ si
    cli
..@d_cli_end:
    times 12 nop
    cmp word [count], 0
    je .d_none
    cmp word [count], 1
    FAILIF ne, 9
    cmp word [ret_ip], ..@d_cli_end
    FAILIF ae, 10                   ; returned after the CLI
    jmp .d_next
.d_none:
    sti                             ; drain the pending request
    nop
    nop
    cli
    cmp word [count], 1
    FAILIF ne, 11
.d_next:
    inc si
    cmp si, SWEEP
    jbe .d_loop

    ; E: INTR raised 1..SWEEP cycles after a request with IF clear, then
    ; STI, a hardwired store, more instructions: never taken between STI and
    ; the store.
    mov si, 1
.e_loop:
    mov word [count], 0
    mov word [ret_ip], 0
    REQ si
    sti
..@e_sti_end:
    mov byte [m1], 1
    times 40 nop
    cli
    cmp word [count], 1
    FAILIF ne, 12
    cmp word [ret_ip], ..@e_sti_end
    FAILIF e, 13                    ; taken inside the shadow
    inc si
    cmp si, SWEEP
    jbe .e_loop

    ; F: the same with a microcoded instruction after STI
    mov si, 1
.f_loop:
    mov word [count], 0
    mov word [ret_ip], 0
    REQ si
    sti
..@f_sti_end:
    cld
    times 40 nop
    cli
    cmp word [count], 1
    FAILIF ne, 14
    cmp word [ret_ip], ..@f_sti_end
    FAILIF e, 15
    inc si
    cmp si, SWEEP
    jbe .f_loop

    mov al, 0x01
    out STATUS_PORT, al
    hlt

isr:
    push bp
    mov bp, sp
    push ax
    mov ax, [bp+2]
    mov [cs:ret_ip], ax
    inc word [cs:count]
    pop ax
    pop bp
    iret

%assign k 1
%rep 15
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

align 2
count:  dw 0
ret_ip: dw 0
m1:     db 0
m2:     db 0

; int_real_entry_timing.asm - real-mode INT n runs its own delivery tail, and
; delivers through the right vector.
;
; Real-mode delivery clears AC through its own copy of the 386 EFLAGS mask pair
; (ucode_optimize.py REAL_INT_FLAGS; ac_int_real pins the flag).  The copy
; long-jumped back to the shared tail at 8D7, one cycle more than the 386; it
; now carries the tail itself.  The i486 takes 30 clocks for INT n and 15 for
; IRET (MAME cycles.h, 486 column).
; Values: INT 41h and INT 42h land in their own handlers (each returns its
; vector's mark in BX) with the return address and FLAGS restored, and a store
; to the IVT is seen by the next INT.
; Timing: 16 INT 41h + IRET, warm, against the testbench cycle counter.
;
; Port 0xE0: status (0x01 pass, 0xFF fail); port 0xE4: failure code.
BITS 16
org 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
CYCLE_PORT  equ 0xFC
MAX_INT     equ 1015            ; 16 pairs: 1023 with the long jump back, 1007 without

%macro FAILIF 2
    j%1 near fail_%2
%endmacro

start:
    cli
    mov ax, cs
    mov ds, ax
    mov ss, ax
    mov sp, 0xF000
    xor ax, ax
    mov es, ax
    mov word [es:0x41*4], isr41
    mov [es:0x41*4+2], cs
    mov word [es:0x42*4], isr42
    mov [es:0x42*4+2], cs

    xor bx, bx
    int 0x41
    cmp bx, 0x4141
    FAILIF ne, 1
    int 0x42
    cmp bx, 0x4242
    FAILIF ne, 2
    cmp sp, 0xF000
    FAILIF ne, 3
    ; a store to the IVT is seen by the next INT
    mov word [es:0x41*4], isr42
    int 0x41
    cmp bx, 0x4242
    FAILIF ne, 4
    mov word [es:0x41*4], isr41

    mov di, 2
.again:
    in eax, CYCLE_PORT
    mov ebp, eax
%rep 16
    int 0x41
%endrep
    in eax, CYCLE_PORT
    sub eax, ebp
    dec di
    jnz .again
    out DATA_PORT, eax
    cmp eax, MAX_INT
    FAILIF a, 5
    mov al, 0x01
    out STATUS_PORT, al
    hlt

isr41:
    mov bx, 0x4141
    iret
isr42:
    mov bx, 0x4242
    iret

%assign k 1
%rep 5
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

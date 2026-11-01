; ac_int_real.asm - real-address-mode interrupt delivery clears the 486 AC flag
;
; Intel SDM INT n, real-address mode: "IF <- 0; TF <- 0; AC <- 0" (the
; protected-mode gates keep AC, ac_int_keep). The fork's AC-keeping mask at
; 8D5 is shared with the real-mode path (8AE long-jumps to it), so a real-mode
; INT, or a fault delivered through the IVT, kept AC. SingleStepTests 80386
; real mode (486 expectation) caught it on a #GP through the IVT (F6.4[46]).
; The pushed FLAGS image is 16 bits either way, and a real-mode IRET restores
; only those, so AC stays clear after the handler returns.
;
; Results: port 0xE0 status (0x01 pass / 0xFF fail), port 0xE4 fail code.

BITS 16
org 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
AC_FLAG     equ 0x40000

start:
    cli
    xor ax, ax
    mov ds, ax
    mov word [0x60*4], int60_handler
    mov word [0x60*4+2], cs
    mov ax, cs
    mov ds, ax
    mov ss, ax
    mov sp, 0x700

    ; Set AC (CR0.AM clear; real mode never checks alignment) and read it back.
    pushfd
    pop eax
    or eax, AC_FLAG
    push eax
    popfd
    pushfd
    pop eax
    mov ax, 1
    test eax, AC_FLAG
    jz fail                         ; 1: POPFD did not set AC

    int 0x60

    mov ax, 2
    cmp word [hits], 1
    jne fail                        ; 2: the handler did not run once
    mov ax, 3
    test dword [handler_flags], AC_FLAG
    jnz fail                        ; 3: the handler saw AC set
    pushfd
    pop eax
    mov ax, 4
    test eax, AC_FLAG
    jnz fail                        ; 4: AC set after IRET (it restores FLAGS only)

    mov al, 0x01
    out STATUS_PORT, al
    hlt

int60_handler:
    push eax
    pushfd
    pop eax
    mov [handler_flags], eax
    inc word [hits]
    pop eax
    iret

fail:
    out DATA_PORT, ax
    mov al, 0xff
    out STATUS_PORT, al
    hlt

align 4
handler_flags: dd 0
hits:          dw 0

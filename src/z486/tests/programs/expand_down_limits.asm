; expand_down_limits.asm - limit checks on expand-down data segments
;
; An expand-down data segment allows offsets limit+1 up to 0xFFFF (B=0) or
; 0xFFFFFFFF (B=1). Windows 95 KRNL386 loads FS with an expand-down B=1
; selector (base 0, limit 0xC7A0) and dereferences linear pointers through
; it; z486 checked every segment as expand-up and raised #GP.
; Each case records whether it took #GP; the handler skips the instruction.

BITS 16
ORG 0

STATUS_PORT equ 0xE0
CODE_BASE   equ 0x10000

align 8
gdt:
    dq 0
    dq 0x00009b010000ffff           ; 0x08: 16-bit code, base 0x10000
    dq 0x000093010000ffff           ; 0x10: 16-bit data, base 0x10000
    dq 0x00cf93000000ffff           ; 0x18: flat 4 GB data
    dq 0x004097000000c7a0           ; 0x20: expand-down, B=1, limit 0xC7A0
    dq 0x0000970300000fff           ; 0x28: expand-down, B=0, limit 0x0FFF, base 0x30000
    dq 0x8040970030000000           ; 0x30: expand-down, B=1, limit 0, base 0x80003000
gdt_end:

gdt_desc:
    dw gdt_end - gdt - 1
    dd CODE_BASE + gdt

align 8
idt:
    times 13 dq 0
    dw gp_handler                   ; 0x0D
    dw 0x08
    db 0
    db 0x86                         ; 286 interrupt gate (16-bit handler)
    dw 0
idt_end:

idt_desc:
    dw idt_end - idt - 1
    dd CODE_BASE + idt

faults: db 0
resume: dw 0

gp_handler:
    add sp, 2                       ; error code
    inc byte [faults]
    push bp
    mov bp, sp
    push ax
    mov ax, [resume]
    mov [bp + 2], ax                ; return IP
    pop ax
    pop bp
    iret

%macro CASE 2
    mov byte [faults], 0
    mov word [resume], %%after
    %2
%%after:
    cmp byte [faults], %1
    jne fail
%endmacro

times 0x200 - ($ - $$) db 0x90
start:
    cli
    o32 lgdt [cs:gdt_desc]
    o32 lidt [cs:idt_desc]
    mov ax, 0x10
    mov ds, ax
    mov ss, ax
    mov sp, 0x8000
    mov ax, 0x20
    mov fs, ax
    mov ax, 0x28
    mov gs, ax
    mov ax, 0x30
    mov es, ax

    ; B=1, limit 0xC7A0: the Windows 95 FS
    CASE 0, {mov eax, [fs:dword 0xC7A1]}
    CASE 1, {mov eax, [fs:dword 0xC7A0]}
    CASE 1, {mov al, [fs:dword 0xC79F]}
    CASE 1, {mov eax, [fs:dword 0x8000]}
    CASE 0, {mov eax, [fs:dword 0x20000]}
    CASE 0, {inc dword [fs:dword 0x20000]}
    CASE 0, {mov ebx, 0x20000}
    CASE 0, {inc dword [fs:ebx + 0x28]}
    ; B=1 upper bound 0xFFFFFFFF, limit 0 (base 0x80003000)
    CASE 1, {mov al, [es:dword 0]}
    CASE 0, {mov al, [es:dword 1]}
    CASE 0, {mov eax, [es:dword 0xFFFFFFFC]}
    CASE 1, {mov eax, [es:dword 0xFFFFFFFD]}
    CASE 0, {mov al, [es:dword 0xFFFFFFFF]}
    CASE 1, {mov ax, [es:dword 0xFFFFFFFF]}
    ; B=0 upper bound 0xFFFF, limit 0x0FFF
    CASE 0, {mov ax, [gs:0xFFFE]}
    CASE 1, {mov ax, [gs:0xFFFF]}
    CASE 0, {mov al, [gs:0x1000]}
    CASE 1, {mov al, [gs:0x0FFF]}
    CASE 1, {mov ax, [gs:0x0FFF]}
    CASE 1, {mov al, [gs:dword 0x10000]}
    CASE 0, {mov word [gs:0x2000], 0x1234}
    ; The read-back: CASE ends on its own fault-count compare, so the data
    ; compare is made after it, on a register.
    CASE 0, {mov ax, [gs:0x2000]}
    cmp ax, 0x1234
    jne fail
    ; expand-up checks unchanged
    mov ax, 0x18
    mov fs, ax
    CASE 0, {mov eax, [fs:dword 0x8000]}

    mov al, 1
    out STATUS_PORT, al
    hlt

fail:
    mov al, 0xff
    out STATUS_PORT, al
    hlt

times 0x600 - ($ - $$) db 0

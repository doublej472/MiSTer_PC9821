; debug_task_ibp - a global instruction breakpoint on the first instruction
; of a task entered by a task switch faults before it runs (#DB, DR6.B0,
; saved EIP = the task's entry), then RF lets it run (Intel486 PRM 11.3.1.1).
; The #DB pushes RF=0 (a real Am486DX4, CPUSUITE-XE10, locks up on this
; program's original handler, which relied on a pushed RF=1; Intel SDM vol. 3
; 17.3.1.1), so the handler sets RF in the frame itself.
BITS 16
org 0
STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
SEL_CODE0   equ 0x08
SEL_DATA0   equ 0x10
SEL_TSS_OLD equ 0x18
SEL_TSS_NEW equ 0x20

start:
    cli
    lgdt [cs:gdt_desc]
    lidt [cs:idt_desc]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp dword SEL_CODE0:pm_entry

BITS 32
pm_entry:
    mov ax, SEL_DATA0
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x3000
    mov ax, SEL_TSS_OLD
    ltr ax
    xor ebp, ebp
    xor eax, eax
    mov dr6, eax
    mov eax, task_entry + 0x10000
    mov dr0, eax
    mov eax, 0x00000002               ; G0, RW0=00 (execute)
    mov dr7, eax
    jmp SEL_TSS_NEW:0
    mov eax, 0x10
    jmp fail

task_entry:
    cmp ebp, 1                        ; the #DB came first
    jne fail_1
    mov eax, [db_dr6]
    and eax, 0xf00f
    cmp eax, 0x0001                   ; B0 only (T bit clear)
    jne fail_2
    mov eax, [db_eip]
    cmp eax, task_entry
    jne fail_3
    mov eax, [db_eflags]
    test eax, 0x10000                 ; the fault frame carries RF=0
    jnz fail_4
    mov al, 1
    out STATUS_PORT, al
    hlt

db_handler:
    push eax
    mov eax, dr6
    mov [db_dr6], eax
    mov eax, [esp + 4]
    mov [db_eip], eax
    mov eax, [esp + 12]
    mov [db_eflags], eax
    or dword [esp + 12], 0x10000      ; RF: run the breakpointed instruction
    xor eax, eax
    mov dr6, eax
    inc ebp
    pop eax
    iretd

fail_1:
    mov eax, 1
    jmp fail
fail_2:
    mov eax, 2
    jmp fail
fail_3:
    mov eax, 3
    jmp fail
fail_4:
    mov eax, 4
fail:
    out DATA_PORT, eax
    mov al, 0xff
    out STATUS_PORT, al
    hlt

align 4
db_dr6: dd 0
db_eip: dd 0
db_eflags: dd 0

align 8
gdt:
    dq 0
    dq 0x00CF9B010000FFFF       ; 08: 32-bit code, base 10000h
    dq 0x00CF93010000FFFF       ; 10: 32-bit data, base 10000h
    dw 0x0067                   ; 18: available 386 TSS (old)
    dw tss_old
    db 0x01
    db 10001001b
    db 0
    db 0
    dw 0x0067                   ; 20: available 386 TSS (new)
    dw tss_new
    db 0x01
    db 10001001b
    db 0
    db 0
gdt_end:
gdt_desc:
    dw gdt_end - gdt - 1
    dd gdt + 0x10000

align 8
idt:
    dq 0
    dw db_handler, SEL_CODE0
    db 0, 0x8e
    dw 0
idt_end:
idt_desc:
    dw idt_end - idt - 1
    dd idt + 0x10000

align 4
tss_old:
    times 26 dd 0
align 4
tss_new:
    dd 0, 0, 0, 0, 0, 0, 0
    dd 0                        ; 1C CR3 (paging disabled)
    dd task_entry               ; 20 EIP
    dd 0x00000002               ; 24 EFLAGS
    dd 0, 0, 0, 0               ; EAX ECX EDX EBX
    dd 0x4000                   ; 38 ESP
    dd 0                        ; 3C EBP
    dd 0, 0                     ; ESI EDI
    dd SEL_DATA0                ; 48 ES
    dd SEL_CODE0                ; 4C CS
    dd SEL_DATA0                ; 50 SS
    dd SEL_DATA0                ; 54 DS
    dd 0, 0                     ; FS GS
    dd 0                        ; 60 LDTR
    dw 0                        ; 64 T clear
    dw 0x0068                   ; 66 I/O bitmap beyond TSS limit

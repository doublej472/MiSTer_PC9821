; errcode_word_push - an exception's error code is a 16-bit write into a
; dword slot on a 32-bit stack: ESP moves by 4, the slot's upper half keeps
; what memory held.
;
; Intel SDM vol. 3, Architecture Compatibility, "Error Code Pushes": "The
; Intel486 processor implements the error code pushed on the stack as a
; 16-bit value.  When pushed onto a 32-bit stack, the Intel486 processor only
; pushes 2 bytes and updates ESP by 4."  A real Am486DX4 pushes a dword whose
; low word is the error code and whose upper half is not zero (CPUSUITE-XE10-
; triage: callgate_newstack_ss data=55000038h, an #SS through a task gate).
;
; Each phase plants A5A5A5A5h in the error-code slot, raises a fault with an
; error code and checks ESP, the return EIP and the slot (A5A5h:error code):
;   1: #GP(1230h) (MOV DS, a selector past the GDT limit) at CPL0 through a
;      32-bit interrupt gate, same privilege;
;   2: #GP(0) (HLT at CPL3) through the same gate, onto TSS.ESP0;
;   3: #GP(1230h) at CPL0 through a task gate, onto the new task's stack.
; Fail (port E4): (phase << 8) | check, then the value seen.
BITS 16
org 0
STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
SEL_CODE0   equ 0x08
SEL_DATA0   equ 0x10
SEL_CODE3   equ 0x18
SEL_DATA3   equ 0x20
SEL_TSS     equ 0x28
SEL_TSS2    equ 0x30
BAD_SEL     equ 0x1230              ; GDT index 246h, past the limit
PHASE       equ 0x00020000
STK_A       equ 0x00014000
STK_B       equ 0x00018000          ; TSS.ESP0
STK_C       equ 0x00005000          ; TSS2.ESP
R3_STACK    equ 0x00003000
PLANT       equ 0xA5A5A5A5

start:
    cli
    cld
    mov ax, cs
    mov ds, ax
    lgdt [gdt_desc]
    lidt [idt_desc]
    mov eax, cr0
    or  al, 1
    mov cr0, eax
    jmp SEL_CODE0:pm

BITS 32
pm:
    mov ax, SEL_DATA0
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov ax, SEL_TSS
    ltr ax

    ; Phase 1: same-privilege fault, 32-bit interrupt gate.
    mov dword [PHASE], 1
    mov esp, STK_A
    mov dword [STK_A - 16], PLANT
    mov ax, BAD_SEL
fault_1:
    mov ds, ax
    mov eax, 0x0100
    jmp report_fail

gp_handler:                         ; IDT[13], ring-0 32-bit interrupt gate
    mov ax, SEL_DATA0
    mov ds, ax
    cmp dword [PHASE], 1
    je phase_1_check
    cmp dword [PHASE], 2
    je phase_2_check
    mov eax, 0x0000
    jmp report_fail

phase_1_check:
    mov ebx, 0x0101
    mov eax, esp
    cmp eax, STK_A - 16
    jne report_fail_v
    mov ebx, 0x0102
    mov eax, [esp + 4]
    cmp eax, fault_1
    jne report_fail_v
    mov ebx, 0x0103
    mov eax, [esp]
    cmp eax, (PLANT & 0xFFFF0000) | BAD_SEL
    jne report_fail_v

    ; Phase 2: CPL3 -> CPL0 through the same gate, onto TSS.ESP0.
    mov dword [PHASE], 2
    mov dword [STK_B - 24], PLANT
    push dword SEL_DATA3 | 3
    push dword R3_STACK
    push dword 0x0002
    push dword SEL_CODE3 | 3
    push dword fault_2
    iretd
fault_2:
    hlt                             ; CPL3: #GP(0)
    mov eax, 0x0200
    jmp report_fail

phase_2_check:
    mov ebx, 0x0201
    mov eax, esp
    cmp eax, STK_B - 24
    jne report_fail_v
    mov ebx, 0x0202
    mov eax, [esp + 4]
    cmp eax, fault_2
    jne report_fail_v
    mov ebx, 0x0203
    mov eax, [esp]
    cmp eax, PLANT & 0xFFFF0000
    jne report_fail_v

    ; Phase 3: IDT[13] becomes a task gate to TSS2.
    mov dword [idt + 0x10000 + 13*8], SEL_TSS2 << 16
    mov dword [idt + 0x10000 + 13*8 + 4], 0x00008500
    mov dword [PHASE], 3
    mov dword [STK_C - 4], PLANT
    mov ax, BAD_SEL
fault_3:
    mov ds, ax
    mov eax, 0x0300
    jmp report_fail

task_handler:                       ; TSS2: [esp] = error code
    mov ebx, 0x0301
    mov eax, esp
    cmp eax, STK_C - 4
    jne report_fail_v
    mov ebx, 0x0302
    mov eax, [tss + 0x10000 + 0x20] ; the faulting task's saved EIP
    cmp eax, fault_3
    jne report_fail_v
    mov ebx, 0x0303
    mov eax, [esp]
    cmp eax, (PLANT & 0xFFFF0000) | BAD_SEL
    jne report_fail_v
    mov al, 1
    out STATUS_PORT, al
    hlt

report_fail_v:                      ; ebx = code, eax = value seen
    xchg eax, ebx
    out DATA_PORT, eax
    mov eax, ebx
report_fail:
    out DATA_PORT, eax
    mov al, 0xff
    out STATUS_PORT, al
    hlt
other_handler:
    mov eax, [esp]
    mov ebx, 0x0000FFFF
    jmp report_fail_v

align 8
gdt:
    dq 0
    dq 0x00cf9b010000ffff       ; 08 code0, base 10000h
    dq 0x00cf93000000ffff       ; 10 data0 flat
    dq 0x00cffb010000ffff       ; 18 code3, base 10000h
    dq 0x00cff3000000ffff       ; 20 data3 flat
tss_desc:                       ; 28
    dw 0x0067
    dw tss
    db 0x01, 0x89, 0x00, 0x00
tss2_desc:                      ; 30 the #GP task
    dw 0x0067
    dw tss2
    db 0x01, 0x89, 0x00, 0x00
gdt_end:
gdt_desc:
    dw gdt_end - gdt - 1
    dd gdt + 0x10000

%macro GATE 1
    dw %1
    dw SEL_CODE0
    db 0, 0x8e
    dw 0
%endmacro
align 8
idt:
%rep 13
    GATE other_handler
%endrep
    GATE gp_handler             ; 13
%rep 0x20-14
    GATE other_handler
%endrep
idt_end:
idt_desc:
    dw idt_end - idt - 1
    dd idt + 0x10000

align 4
tss:
    dd 0, STK_B, SEL_DATA0, 0, 0, 0, 0, 0
    dd 0, 0, 0, 0, 0, 0, 0, 0
    dd 0, 0, 0, 0, 0, 0, 0, 0
    dw 0, 104
    dd 0
align 4
tss2:
    dd 0, 0, 0, 0, 0, 0, 0, 0       ; 00-1C
    dd task_handler, 0x2, 0, 0, 0, 0, STK_C, 0   ; 20 EIP, EFLAGS, EAX..EBX, ESP, EBP
    dd 0, 0, SEL_DATA0, SEL_CODE0, SEL_DATA0, SEL_DATA0, 0, 0   ; ESI EDI ES CS SS DS FS GS
    dd 0
    dw 0, 104

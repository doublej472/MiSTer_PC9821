; int_newstack_ss - INT n from CPL3 through a DPL3 interrupt gate whose
; ring-0 stack (TSS.ESP0 = 10h) cannot hold the 20-byte frame raises
; #SS(new SS selector) with EXT=0 (software interrupt): error code 38h.
; A real Am486DX4 reports 38h (CPUSUITE-XE10 run 1: this program's FAIL
; data 55000038h); Intel SDM INT n Operation, "IF new stack does not have
; room for 24 bytes (error code pushed) or 20 bytes (no error code pushed)
; THEN #SS(error_code(NewSS,0,EXT))".  (The 486 PRM pseudocode's
; "#SS(0)" is not what the part does.)  #SS is a task gate so its delivery
; does not need ESP0.
; (derived from callgate_newstack_ss)
; Fail (port E4): 0x5500xxxx = #SS with a wrong error code (low word = error
; code; only the low word is compared), 0x66xxxxxx = wrong vector/EIP,
; 0x77 = the call completed.
BITS 16
org 0
STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
SEL_CODE0   equ 0x08
SEL_DATA0   equ 0x10
SEL_CODE3   equ 0x18
SEL_DATA3   equ 0x20
SEL_TSS     equ 0x28
SEL_GATE    equ 0x30
SEL_SMALLSS equ 0x38
SEL_TSS2    equ 0x40
R3_STACK    equ 0x00003000
R0_STACK    equ 0x00014000

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
    mov esp, R0_STACK
    mov ax, SEL_TSS
    ltr ax
    push dword SEL_DATA3 | 3
    push dword R3_STACK
    push dword 0x3002
    push dword SEL_CODE3 | 3
    push dword ring3_entry
    iretd

ring3_entry:
    mov ax, SEL_DATA3 | 3
    mov ds, ax
%rep 8
    push dword 0x11111111
%endrep
call_site:
    int 0x30
    mov eax, 0x77
    jmp report_fail

gate_target:
    mov eax, 0x77
    jmp report_fail

ss_handler:                     ; runs as a task: [esp] = error code
    movzx eax, word [esp]       ; low word only: the error code's upper 16 bits are
                                ; reserved (Intel SDM vol. 3 6.13, "Error Code") and an
                                ; Am486DX4 pushes them nonzero (CPUSUITE-XE10-triage:
                                ; callgate_newstack_ss data=55000038h, low word right)
    cmp eax, SEL_SMALLSS        ; #SS(new SS selector), EXT=0
    jne .bad_err
    cmp dword [tss+0x10000+0x20], call_site ; the interrupted task's saved EIP
    jne .bad_eip
    mov al, 1
    out STATUS_PORT, al
    hlt
.bad_err:
    and eax, 0xffff
    or eax, 0x55000000
    jmp report_fail
.bad_eip:
    mov eax, [tss+0x10000+0x20]             ; report the saved EIP
    or eax, 0x66000000
    jmp report_fail
other_handler:
    mov eax, 0x66000000
report_fail:
    out DATA_PORT, eax
    mov al, 0xff
    out STATUS_PORT, al
    hlt
gp_handler:
    mov eax, [esp]
    and eax, 0xffff
    or eax, 0x660d0000
    jmp report_fail
ts_handler:
    mov eax, [esp]
    and eax, 0xffff
    or eax, 0x660a0000
    jmp report_fail

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
gate:                           ; 30 386 call gate, DPL3, 8 params
    dw gate_target
    dw SEL_CODE0
    db 8, 0xec
    dw 0
    dq 0x00409305000000ff       ; 38 ring-0 stack, base 50000h, byte limit FFh, B=1
tss2_desc:                      ; 40 #SS task
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
%rep 10
    GATE other_handler
%endrep
    GATE ts_handler             ; 10
    GATE other_handler          ; 11
    dw 0, SEL_TSS2              ; 12: task gate
    db 0, 0x85
    dw 0
    GATE gp_handler             ; 13
%rep 0x30-14
    GATE other_handler
%endrep
    dw gate_target, SEL_CODE0   ; 30h: DPL3 interrupt gate
    db 0, 0xee
    dw 0
idt_end:
idt_desc:
    dw idt_end - idt - 1
    dd idt + 0x10000

align 4
tss:
    dd 0, 0x10, SEL_SMALLSS, 0, 0, 0, 0, 0
    dd 0, 0, 0, 0, 0, 0, 0, 0
    dd 0, 0, 0, 0, 0, 0, 0, 0
    dw 0, 104
    dd 0
align 4
tss2:
    dd 0, 0, 0, 0, 0, 0, 0, 0       ; 00-1C
    dd ss_handler, 0x2, 0, 0, 0, 0, 0x5000, 0   ; 20 EIP, EFLAGS, EAX..EBX, ESP, EBP
    dd 0, 0, SEL_DATA0, SEL_CODE0, SEL_DATA0, SEL_DATA0, 0, 0   ; ESI EDI ES CS SS DS FS GS
    dd 0
    dw 0, 104

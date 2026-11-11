; ac_v86_iret - IRETD to virtual-8086 mode from a misaligned ring-0 stack with
; AC=1 in the popped EFLAGS must not raise #AC   (BUG REPRODUCER, fails on
; 3df4a0f: TIMEOUT, #AC handler re-entered forever)
;
; CR0.AM=1.  The TSS ESP0 is 2 mod 4.  V86 code (EFLAGS.AC=1, IOPL=3) runs
; INT 21h; the ring-0 handler returns with IRETD, which pops the 9-dword V86
; frame from the misaligned ring-0 stack.  IRETD executes at CPL0 and its pops
; are privilege-0 references (i486 PRM 9.9.16; #AC only at CPL3), but the core
; loads EFLAGS (VM=1, AC=1) before popping ESP/SS/ES/DS/FS/GS and then checks
; those pops (align_priv_stack excludes VM=1 unless descsw_mode): #AC with the
; IRETD as the faulting instruction, and the handler's restart repeats it.
; Then a misaligned V86 PUSH must raise exactly one #AC.
; Fail codes (port E4): 0x11xx/0x22xx #AC count, 0x33xx INT 21h count,
; 0x44xx bad #AC error code.
BITS 16
org 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
SEL_CODE0   equ 0x08
SEL_DATA0   equ 0x10
SEL_TSS     equ 0x18
STACK0_TOP  equ 0x7000
VM86_SEG    equ 0x1000
VM86_SP     equ 0xE100

start:
    cli
    cld
    mov ax, cs
    mov ds, ax
    lgdt [gdt_desc]
    lidt [idt_desc]
    mov eax, cr0
    or  eax, 0x00040001              ; PE, AM
    mov cr0, eax
    jmp SEL_CODE0:pm16_entry

pm16_entry:
    mov ax, SEL_DATA0
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, STACK0_TOP
    mov word [ac_count], 0
    mov word [int21_count], 0
    mov ax, SEL_TSS
    ltr ax
    push dword VM86_SEG              ; GS
    push dword VM86_SEG              ; FS
    push dword VM86_SEG              ; DS
    push dword VM86_SEG              ; ES
    push dword VM86_SEG              ; SS
    push dword VM86_SP               ; ESP
    push dword 0x00063202            ; EFLAGS: AC, VM, IOPL=3, IF
    push dword VM86_SEG              ; CS
    push dword vm86_entry            ; EIP
    iretd

vm86_entry:
    mov ax, cs
    mov ds, ax
    mov ss, ax
    mov sp, VM86_SP
    int 0x21                         ; frame onto the misaligned ESP0
    cmp word [ac_count], 0
    mov ax, 0x1100
    jne v86_fail
    cmp word [int21_count], 1
    mov ax, 0x3300
    jne v86_fail
    mov sp, VM86_SP - 1              ; misaligned V86 stack
    push ax                          ; #AC(0), then completes with AC=0
    mov sp, VM86_SP
    cmp word [ac_count], 1
    mov ax, 0x2200
    jne v86_fail
    int 0x22                         ; pass
v86_fail:
    or  ax, [ac_count]
    int 0x23

int21_handler:
    push ax
    mov ax, SEL_DATA0
    mov ds, ax
    inc word [int21_count]
    pop ax
    iretd

ac_handler:
    mov bp, sp
    mov ax, SEL_DATA0
    mov ds, ax
    cmp word [bp], 0                 ; error code 0, its low word only: the
                                     ; 486 writes 2 bytes of the dword slot
                                     ; (Intel SDM vol. 3, Architecture
                                     ; Compatibility, "Error Code Pushes"),
                                     ; the upper half is what the stack held
                                     ; (a real Am486DX4: CPUSUITE-XE10-
                                     ; triage ac_v86_iret data=00004400h)
    jne .bad
    inc word [ac_count]
    and dword [bp+12], ~0x40000      ; clear AC in the saved EFLAGS
    add sp, 4
    iretd
.bad:
    mov ax, 0x4400
    jmp fail16

pass_handler:
    mov al, 1
    out STATUS_PORT, al
    hlt
fail_handler:
fail16:
    movzx eax, ax
    out DATA_PORT, eax
    mov al, 0xff
    out STATUS_PORT, al
    hlt

align 8
gdt:
    dq 0
    dw 0xffff, 0x0000                ; ring-0 USE16 code, base 0x10000
    db 0x01, 10011011b, 0, 0
    dw 0xffff, 0x0000                ; ring-0 USE16 data, base 0x10000
    db 0x01, 10010011b, 0, 0
    dw tss_end - tss - 1, tss        ; 32-bit TSS
    db 0x01, 10001001b, 0, 0
gdt_end:
gdt_desc:
    dw gdt_end - gdt - 1
    dd gdt + 0x00010000

%macro GATE 1
    dw %1
    dw SEL_CODE0
    db 0, 11101110b
    dw 0
%endmacro
align 8
idt:
    times 17 dq 0
    GATE ac_handler                  ; 17 #AC
    times (0x21 - 18) dq 0
    GATE int21_handler
    GATE pass_handler
    GATE fail_handler
idt_end:
idt_desc:
    dw idt_end - idt - 1
    dd idt + 0x00010000

align 4
tss:
    dd 0, STACK0_TOP - 2, SEL_DATA0, 0, 0, 0, 0, 0
    dd 0, 0, 0, 0, 0, 0, 0, 0
    dd 0, 0, 0, 0, 0, 0, 0, 0
    dw 0, tss_end - tss
tss_end:

ac_count:    dw 0
int21_count: dw 0

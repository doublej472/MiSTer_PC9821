; debug_bn_disabled_clear - DR6.B0-B3 stay clear for a breakpoint whose
; DR/LEN/RW condition matches but which DR7 does not enable (L/G clear)
;
; AMD APM 24593 rev. 3.38 13.1.1.3 (Debug-Status Register DR6), B3-B0: "A bit
; is set to 1 if the corresponding address-breakpoint register detects an
; enabled breakpoint condition, as specified by the DR7 Ln, Gn, R/Wn and LENn
; controls".  A real Am486DX4 (the Xe10's) leaves the bit clear
; (CPUSUITE-XE10-triage: debug_bn_noenable data=00004000h, BS only, for case
; 2 below; debug_bn_noenable_dr123 data=00004000h for DR1).  Intel SDM vol.
; 3 (DR6) allows it ("They may or may not be set if the breakpoint is not
; enabled by the Ln or the Gn flags"); the Intel486 PRM 11.2.3 sets it.
; debug_bn_noenable(_dr123) accept either; this program holds z486's choice.
;
; Each case single-steps (TF) one write to 0x9000 and reads DR6 in the #DB
; handler; DR6 & F00Fh must equal the expected value:
;   1-4: DRn = 0x9000, RWn=01 (write), LENn=11, no L/G bits: BS only.
;   5:   the same for DR0 with L1 enabled on DR1 = 0x9800 (execute, no
;        match): BS only.
;   6:   DR1 enabled (L1) and DR3 disabled, both write breakpoints on
;        0x9000: BS | B1, not B3.
; Port 0xE4: case number, then the DR6 seen.
BITS 32
ORG 0
CODE_BASE equ 0x10000
align 8
gdt:
    dq 0
    dq 0x00cf9b010000ffff
    dq 0x00cf93000000ffff
gdt_end:
gdtr: dw gdt_end-gdt-1
      dd CODE_BASE+gdt
align 8
idt:
    dq 0
    dw db_handler, 8
    db 0, 0x8e
    dw 0
idt_end:
idtr: dw idt_end-idt-1
      dd CODE_BASE+idt

db_handler:
    push eax
    cmp ebp, 0
    jne .s
    mov eax, dr6
    mov [0x5000], eax
.s:
    inc ebp
    and dword [esp + 12], ~0x100      ; stop stepping
    pop eax
    iretd

times 0x200-($-$$) db 0x90
start:
    cli
    mov esp, 0x8000
    lgdt [cs:gdtr]
    lidt [cs:idtr]

    mov ebx, 1
    mov edx, 0x9000                   ; DR0
    mov edi, 0x9800                   ; DR1..DR3 elsewhere
    mov eax, 0x000d0000               ; RW0=01 LEN0=11, no L/G bits
    mov ecx, 0x00004000
    call run
    mov ebx, 2
    mov edx, 0x9800
    mov edi, 0x9000
    mov eax, 0x00d00000               ; RW1=01 LEN1=11
    call run
    mov ebx, 3
    mov eax, 0x0d000000               ; RW2=01 LEN2=11
    call run
    mov ebx, 4
    mov eax, 0xd0000000               ; RW3=01 LEN3=11
    call run
    mov ebx, 5                        ; DR0 matches, L1 on DR1 (exec, 0x9800)
    mov edx, 0x9000
    mov edi, 0x9800
    mov eax, 0x000d0004
    call run
    mov ebx, 6                        ; DR1 (L1) and DR3 (disabled) on 0x9000
    mov edx, 0x9800
    mov edi, 0x9000
    mov eax, 0xd0d00004
    mov ecx, 0x00004002               ; BS | B1
    call run
    mov al, 1
    out 0xe0, al
    hlt

run:                                  ; eax = DR7, edx = DR0, edi = DR1-DR3
    mov dr7, eax
    xor eax, eax
    mov dr6, eax
    mov dr0, edx
    mov dr1, edi
    mov dr2, edi
    mov dr3, edi
    xor ebp, ebp
    mov dword [0x5000], 0
    pushfd
    or dword [esp], 0x100
    popfd
    mov dword [0x9000], 1             ; stepped: #DB after this instruction
    nop
    xor eax, eax
    mov dr7, eax
    mov eax, [0x5000]
    and eax, 0x0000f00f
    cmp eax, ecx
    jne fail
    ret
fail:
    xchg eax, ebx
    out 0xe4, eax
    mov eax, ebx
    out 0xe4, eax
    mov al, 0xff
    out 0xe0, al
    hlt

; debug_bn_noenable - DR6.B0-B3 for matching breakpoints when NO breakpoint
; is enabled in DR7
;
; Intel486 PRM 11.2.3: "The B bit is set if the condition described by the
; DR, LEN, and R/W bits is true, even if the breakpoint is not enabled by the
; L and G bits.  The processor sets the B bits for all breakpoints which
; match the conditions present at the time the debug exception is generated,
; whether or not they are enabled."
; DR6.Bn for a match that DR7 does not enable is vendor-variant: the
; Intel486 PRM 11.2.3 sets it; Intel SDM vol. 3 (DR6): "They may or may not
; be set if the breakpoint is not enabled by the Ln or the Gn flags in
; register DR7"; AMD APM 24593 13.1.1.3 sets a B bit only if its register
; "detects an enabled breakpoint condition", and a real Am486DX4 leaves it
; clear (CPUSUITE-XE10-triage: debug_bn_noenable data=00004000h,
; debug_bn_noenable_dr123 data=00004000h).  Either value passes; z486 leaves
; it clear (debug_bn_disabled_clear holds that).
;
; Case 1: DR0 = 0x9000, RW0=01 (write), LEN0=11, L0=G0=0.  A single-step
; (TF) #DB after a write to 0x9000 must report DR6 = BS | B0 or BS alone.
; Case 2 (control): the same with L1 enabled on an unrelated DR1 address
; (the core's breakpoint mode is on) - also BS | B0 or BS alone.
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

    ; case 2 first (control): DR1 enabled elsewhere
    mov ebx, 2
    mov eax, 0x9800
    mov dr1, eax
    mov eax, 0x000d0004               ; RW0=01 LEN0=11, L1 (DR1 RW=00 exec, no match)
    call run
    ; case 1: nothing enabled
    mov ebx, 1
    mov eax, 0x000d0000               ; RW0=01 LEN0=11, no L/G bits
    call run
    mov al, 1
    out 0xe0, al
    hlt

run:
    mov dr7, eax
    xor eax, eax
    mov dr6, eax
    mov eax, 0x9000
    mov dr0, eax
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
    cmp eax, 0x00004000               ; BS alone (AMD APM, Am486DX4, z486)
    je .ok
    cmp eax, 0x00004001               ; BS | B0 (Intel486 PRM 11.2.3)
    jne fail
.ok:
    ret
fail:
    xchg eax, ebx
    out 0xe4, eax
    mov eax, ebx
    out 0xe4, eax
    mov al, 0xff
    out 0xe0, al
    hlt

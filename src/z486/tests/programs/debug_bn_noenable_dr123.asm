; debug_bn_noenable_dr123 - DR6.B1-B3 for matching data breakpoints when NO
; breakpoint is enabled in DR7 (debug_bn_noenable covers DR0 only)
;
; Intel486 PRM 11.2.3: B bits are set for every breakpoint whose DR/LEN/RW
; condition matches when a #DB is generated, enabled or not.
; DR6.Bn for a match that DR7 does not enable is vendor-variant: the
; Intel486 PRM 11.2.3 sets it; Intel SDM vol. 3 (DR6): "They may or may not
; be set if the breakpoint is not enabled by the Ln or the Gn flags in
; register DR7"; AMD APM 24593 13.1.1.3 sets a B bit only if its register
; "detects an enabled breakpoint condition", and a real Am486DX4 leaves it
; clear (CPUSUITE-XE10-triage: debug_bn_noenable data=00004000h,
; debug_bn_noenable_dr123 data=00004000h).  Either value passes; z486 leaves
; it clear (debug_bn_disabled_clear holds that).
; For n = 1, 2, 3: DRn = 0x9000, RWn=01 (write), LENn=11, DR0 = 0 / RW0 = 00,
; no L/G bits.  A single-step (TF) #DB after a write to 0x9000 must report
; DR6 = BS | Bn or BS alone.
; Port 0xE4: case number n, then the DR6 seen.
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

    xor eax, eax
    mov dr0, eax
    mov ebx, 1
    mov ecx, 0x00004002               ; BS | B1
    mov eax, 0x00d00000               ; RW1=01 LEN1=11, no L/G bits
    call run
    mov ebx, 2
    mov ecx, 0x00004004               ; BS | B2
    mov eax, 0x0d000000
    call run
    mov ebx, 3
    mov ecx, 0x00004008               ; BS | B3
    mov eax, 0xd0000000
    call run
    mov al, 1
    out 0xe0, al
    hlt

run:
    mov dr7, eax
    xor eax, eax
    mov dr6, eax
    mov eax, 0x9000
    mov dr1, eax
    mov dr2, eax
    mov dr3, eax
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
    cmp eax, ecx                      ; BS | Bn (Intel486 PRM 11.2.3)
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

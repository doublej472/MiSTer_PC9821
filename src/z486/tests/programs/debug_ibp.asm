; debug_ibp - 486 instruction breakpoints: prefixes, mid-instruction
; addresses, exception-handler entry, IRET/POPFD with RF, TF interaction.
; Each case prints (case << 16) | (#DB count << 8) | flags to port 0xE4 with
; flags bit0 = first #DB EIP was the expected one, bit1 = B0 in its DR6,
; bit2 = BS in its DR6.  The pass/fail decision is in the CHECK lines.
; An instruction-breakpoint #DB pushes RF=0 (a real Am486DX4, CPUSUITE-XE10;
; Intel SDM vol. 3 17.3.1.1), so the handler sets RF in the frame when DR6
; reports a breakpoint (every DRn here is an execute breakpoint), as a
; debugger does; a single-step trap returns with RF as pushed.
BITS 32
ORG 0
CODE_BASE equ 0x10000
LOG       equ 0x5000
CNT       equ 0x5810
FAILS     equ 0x5800
%macro DR7SET 1
    mov eax, %1
    mov dr7, eax
%endmacro
%macro ARM 1                 ; arm DR0 = CODE_BASE + label
    mov esp, 0x8000
    xor eax, eax
    mov dr6, eax
    mov dword [CNT], 0
    mov dword [LOG], 0
    mov dword [LOG+4], 0
    mov eax, CODE_BASE + %1
    mov dr0, eax
    DR7SET 0x00000001
%endmacro
; REPORT case, expected-eip-label, expected count, expected flags
%macro REPORT 4
    DR7SET 0
    mov esp, 0x8000
    mov ecx, %1
    mov edx, %2
    mov ebx, (%3 << 8) | %4
    call report
%endmacro

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
    times 4 dq 0
    dw ud_handler, 8
    db 0, 0x8e
    dw 0
idt_end:
idtr: dw idt_end-idt-1
      dd CODE_BASE+idt

db_handler:
    push eax
    push ebx
    mov eax, dr6
    test eax, 0xf
    jz .no_rf
    or dword [esp + 16], 0x10000       ; RF: resume the breakpointed instruction
.no_rf:
    mov ebx, [CNT]
    cmp ebx, 4
    jae .skip
    shl ebx, 3
    mov [LOG + ebx], eax
    mov eax, [esp + 8]
    mov [LOG + ebx + 4], eax
.skip:
    inc dword [CNT]
    xor eax, eax
    mov dr6, eax
    cmp dword [CNT], 4
    jb .r
    mov dr7, eax                       ; runaway guard
.r:
    pop ebx
    pop eax
    iretd

ud_handler_bp:
ud_handler:
    add dword [esp], 2
    iretd

; ecx case, edx expected EIP, ebx expected (count<<8 | flags)
report:
    xor eax, eax
    cmp [LOG + 4], edx
    jne .a
    or eax, 1
.a:
    test dword [LOG], 1
    jz .b
    or eax, 2
.b:
    test dword [LOG], 0x4000
    jz .c
    or eax, 4
.c:
    mov edi, [CNT]
    shl edi, 8
    or eax, edi
    cmp eax, ebx
    je .ok
    inc dword [FAILS]
    shl ecx, 16
    or eax, ecx
    out 0xe4, eax
    mov eax, [LOG+4]
    or eax, 0x80000000
    out 0xe4, eax
    ret
.ok:
    ret

times 0x300-($-$$) db 0x90
start:
    cli
    mov esp, 0x8000
    lgdt [cs:gdtr]
    lidt [cs:idtr]
    mov dword [FAILS], 0

    ; 1: breakpoint on the first prefix of 66 B8 imm16
    ARM c1
c1: db 0x66
    mov ax, 1
    REPORT 1, c1, 1, 3

    ; 2: breakpoint on the opcode byte after a prefix: never recognized
    ARM c2+1
c2: db 0x66
    mov ax, 1
    REPORT 2, 0, 0, 1

    ; 3: two prefixes (seg override + operand size), bp on the first
    ARM c3
c3: db 0x2e, 0x66
    mov ax, [cs:0]
    REPORT 3, c3, 1, 3

    ; 4: breakpoint in an instruction's immediate: never recognized
    ARM c4+1
c4: mov eax, 0x90909090
    REPORT 4, 0, 0, 1

    ; 5: far jump target
    ARM c5
    jmp 8:c5
c5: nop
    REPORT 5, c5, 1, 3

    ; 6: exception handler entry (#UD delivery lands on the breakpoint)
    ARM ud_handler_bp
    ud2
    REPORT 6, ud_handler_bp, 1, 3

    ; 7: IRET to the breakpoint with RF=1 in the image: suppressed once
    ARM c7
    push dword 0x10002
    push dword 8
    push dword c7
    iretd
c7: nop
    REPORT 7, 0, 0, 1

    ; 8: IRET to the breakpoint with RF=0: fault
    ARM c8
    push dword 0x2
    push dword 8
    push dword c8
    iretd
c8: nop
    REPORT 8, c8, 1, 3

    ; 9: POPFD with RF=1 in the image: POPF/POPFD do not load RF (486 PRM
    ; POPF reference page; the 11.3.1.1 text disagrees), so the bp faults
    ARM c9
    push dword 0x10002
    popfd
c9: nop
    REPORT 9, c9, 1, 3

    ; 10: TF single step lands on a breakpointed instruction.  Expected two
    ; #DBs: the BS trap (EIP c10), then the B0 fault on c10, then BS traps
    ; after c10, PUSHFD, AND and POPFD: six in all, the first with BS.
    ARM c10
    pushfd
    or dword [esp], 0x100
    popfd
    nop
c10: nop
    pushfd
    and dword [esp], ~0x100
    popfd
    REPORT 10, c10, 6, 5

    ; 11: breakpoint on the instruction after MOV SS (informational)
    ARM c11
    mov ax, 0x10
    mov ss, ax
c11: nop
    REPORT 11, c11, 1, 3                 ; observed; 486 behaviour not documented

    ; 12: breakpoint on a REP MOVSB itself (fault before the first iteration)
    ARM c12
    mov esi, 0x9000
    mov edi, 0x9100
    mov ecx, 3
    cld
c12: rep movsb
    REPORT 12, c12, 1, 3

    ; 13: G0 instead of L0
    mov esp, 0x8000
    xor eax, eax
    mov dr6, eax
    mov dword [CNT], 0
    mov eax, CODE_BASE + c13
    mov dr0, eax
    DR7SET 0x00000002
c13: nop
    REPORT 13, c13, 1, 3

    ; 14: DR3 with B3 only
    mov esp, 0x8000
    xor eax, eax
    mov dr6, eax
    mov dword [CNT], 0
    mov eax, CODE_BASE + c14
    mov dr3, eax
    DR7SET 0x00000040
c14: nop
    DR7SET 0
    mov eax, [LOG]
    and eax, 0xf
    cmp eax, 8
    je .ok14
    inc dword [FAILS]
    or eax, 0x140000
    out 0xe4, eax
.ok14:

    cmp dword [FAILS], 0
    jne bad
    mov al, 1
    out 0xe0, al
    hlt
bad:
    mov eax, [FAILS]
    or eax, 0x10000000
    out 0xe4, eax
    mov al, 0xff
    out 0xe0, al
    hlt

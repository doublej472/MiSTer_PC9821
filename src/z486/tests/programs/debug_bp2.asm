; debug_bp2 - breakpoints with REP strings, branch targets and page faults
;
;  - A data breakpoint inside REP STOSD traps after the iteration that wrote
;    the location: the saved EIP is the REP instruction, ECX/EDI show the
;    remaining iterations, and IRET resumes the string.
;  - An instruction breakpoint on a branch target faults when the branch lands.
;  - An instruction breakpoint on an instruction that then page-faults: the
;    #PF frame carries RF=1, so restarting after the fault does not re-break.
;  The instruction-breakpoint #DB pushes RF=0 (a real Am486DX4, CPUSUITE-XE10:
;  a handler that does not set RF re-breaks forever; Intel SDM vol. 3
;  17.3.1.1), so the #DB handler sets RF in its frame.
BITS 32
ORG 0
CODE_BASE equ 0x10000
PT0       equ 0x1000
LOG       equ 0x6000
%macro EXPECT 3
    cmp %1, %2
    jne fail_%3
%endmacro
%macro DR7SET 1
    mov eax, %1
    mov dr7, eax
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
    times 12 dq 0
    dw pf_handler, 8
    db 0, 0x8e
    dw 0
idt_end:
idtr: dw idt_end-idt-1
      dd CODE_BASE+idt

db_handler:
    push eax
    push ebx
    mov ebx, ebp
    shl ebx, 4
    mov eax, dr6
    mov [LOG + ebx], eax
    mov eax, [esp + 8]
    mov [LOG + ebx + 4], eax
    mov [LOG + ebx + 8], ecx
    mov [LOG + ebx + 12], edi
    xor eax, eax
    mov dr6, eax
    inc ebp
    or dword [esp + 16], 0x10000      ; RF: resume a breakpointed instruction
    pop ebx
    pop eax
    iretd

; Map the faulting page and retry; record the saved EFLAGS.
pf_handler:
    push eax
    mov eax, [esp + 16]               ; saved EFLAGS (above eax, code, EIP, CS)
    mov [LOG + 0x100], eax
    mov dword [PT0 + (0x28000 >> 12) * 4], 0x00028063
    invlpg [0x28000]
    inc esi
    pop eax
    add esp, 4
    iretd

times 0x200-($-$$) db 0x90
start:
    cli
    mov esp, 0x8000
    lgdt [cs:gdtr]
    lidt [cs:idtr]
    xor ebp, ebp
    xor esi, esi
    xor eax, eax
    mov dr6, eax

    ; 1: REP STOSD over a write breakpoint on 0x9008.
    mov eax, 0x9008
    mov dr0, eax
    DR7SET 0x000d0001                 ; L0, RW0=01, LEN0=11
    cld
    mov edi, 0x9000
    mov ecx, 6
    mov eax, 0xa5a5a5a5
rep_site:
    rep stosd
    DR7SET 0
    EXPECT ebp, 1, 1
    mov eax, [LOG]
    and eax, 0xf
    EXPECT eax, 1, 2
    mov eax, [LOG + 4]
    EXPECT eax, rep_site, 3           ; resumes the string
    mov eax, [LOG + 8]
    EXPECT eax, 3, 4                  ; three dwords left
    mov eax, [LOG + 12]
    EXPECT eax, 0x900c, 5
    EXPECT ecx, 0, 6
    EXPECT edi, 0x9018, 7
    EXPECT dword [0x9014], 0xa5a5a5a5, 8

    ; 2: instruction breakpoint on a branch target.
    xor ebp, ebp
    mov eax, CODE_BASE + jmp_target
    mov dr1, eax
    DR7SET 0x00000004                 ; L1 exec
    jmp jmp_target
    nop
jmp_target:
    mov ebx, 0x1234
    DR7SET 0
    EXPECT ebp, 1, 9
    mov eax, [LOG + 4]
    EXPECT eax, jmp_target, 10
    EXPECT ebx, 0x1234, 11

    ; 3: breakpoint, then a page fault on the same instruction.
    xor ebp, ebp
    mov dword [PT0 + (0x28000 >> 12) * 4], 0  ; unmap 0x28000
    invlpg [0x28000]
    mov eax, CODE_BASE + pf_site
    mov dr2, eax
    DR7SET 0x00000010                 ; L2 exec
pf_site:
    mov dword [0x28000], 0x55667788
    DR7SET 0
    EXPECT ebp, 1, 12                 ; one #DB, not one per restart
    EXPECT esi, 1, 13                 ; one #PF
    mov eax, [LOG + 0x100]
    test eax, 0x10000                 ; the #PF frame carries RF
    jz fail_14
    EXPECT dword [0x28000], 0x55667788, 15

    mov al, 1
    out 0xe0, al
    hlt

%assign c 1
%rep 15
fail_ %+ c:
    mov eax, c
    jmp fail
%assign c c+1
%endrep
fail:
    out 0xe4, eax
    mov al, 0xff
    out 0xe0, al
    hlt

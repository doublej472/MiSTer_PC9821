; debug_bp - 486 hardware breakpoints (DR0-DR3, DR6, DR7)
;
; Instruction breakpoints are faults: #DB is taken before the instruction,
; with RF=0 in the saved EFLAGS; the handler sets RF in the frame so the IRET
; resumes it once (a real Am486DX4 pushes RF=0 and re-breaks forever on a
; handler that does not, CPUSUITE-XE10; Intel SDM vol. 3 17.3.1.1, the RF
; set for every fault "except a debug exception generated in response to an
; instruction breakpoint"; AMD APM 24593 8.2.2).  Data
; breakpoints are traps after the accessing instruction.  DR6.B0-B3 report
; every matching enabled breakpoint; LEN masks the address; a breakpoint
; matches any byte of an access, including a dword-crossing one.
; DR6.Bn for a match that DR7 does not enable is vendor-variant (see
; debug_bn_noenable): the Intel486 PRM 11.2.3 sets it, AMD APM 24593
; 13.1.1.3 and a real Am486DX4 do not (CPUSUITE-XE10-triage), Intel SDM
; vol. 3 (DR6) says "may or may not".  Either value passes.
BITS 32
ORG 0
CODE_BASE equ 0x10000
LOG       equ 0x6000                 ; per-#DB records: DR6, EIP, EFLAGS
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
idt_end:
idtr: dw idt_end-idt-1
      dd CODE_BASE+idt

; Log DR6 and the frame; clear DR6.  EBP counts #DB entries.
db_handler:
    push eax
    push ebx
    mov ebx, ebp
    shl ebx, 4
    mov eax, dr6
    mov [LOG + ebx], eax
    mov eax, [esp + 8]
    mov [LOG + ebx + 4], eax
    mov eax, [esp + 16]
    mov [LOG + ebx + 8], eax
    xor eax, eax
    mov dr6, eax
    inc ebp
    or dword [esp + 16], 0x10000      ; RF: resume a breakpointed instruction
    pop ebx
    pop eax
    iretd

%macro LOGCHK 4    ; entry, dr6 low bits, eip, code
    mov eax, [LOG + %1*16]
    and eax, 0xe00f
    EXPECT eax, %2, %4
    mov eax, [LOG + %1*16 + 4]
    EXPECT eax, %3, %4
%endmacro

times 0x200-($-$$) db 0x90
start:
    cli
    mov esp, 0x8000
    lgdt [cs:gdtr]
    lidt [cs:idtr]
    xor ebp, ebp
    xor eax, eax
    mov dr6, eax

    ; 1: instruction breakpoint DR0 on bp_insn (fault, RF resumes it once).
    mov eax, CODE_BASE + bp_insn
    mov dr0, eax
    DR7SET 0x00000001                 ; L0, RW0=00, LEN0=00
    xor ecx, ecx
    mov edx, 2
bp_loop:
    nop
bp_insn:
    inc ecx
    dec edx
    jnz bp_loop
    DR7SET 0
    EXPECT ecx, 2, 1                  ; executed once per pass
    EXPECT ebp, 2, 2                  ; one fault per pass
    LOGCHK 0, 0x0001, bp_insn, 3
    mov eax, [LOG + 8]
    test eax, 0x10000                 ; the pushed EFLAGS has RF=0
    jnz fail_4

    ; 2: write breakpoint DR1 on dword 0x9000 (trap after the write).
    xor ebp, ebp
    mov eax, 0x9000
    mov dr1, eax
    mov eax, 0x0000004
    mov dr3, eax                      ; DR3 matches nothing here
    DR7SET 0x00d00004                 ; L1, RW1=01, LEN1=11
    mov eax, [0x9000]                 ; read: no trap
    mov dword [0x9000], 0x11223344
wr1_next:
    mov byte [0x9002], 0x55           ; byte inside the dword
wr2_next:
    mov byte [0x9004], 0x66           ; next dword: no trap
    DR7SET 0
    EXPECT ebp, 2, 5
    LOGCHK 0, 0x0002, wr1_next, 6
    LOGCHK 1, 0x0002, wr2_next, 7
    EXPECT dword [0x9000], 0x11553344, 8

    ; 3: read/write breakpoint DR2 on word 0x9104 (LEN=01).
    xor ebp, ebp
    mov eax, 0x9105                   ; low bit masked by LEN
    mov dr2, eax
    DR7SET 0x07000010                 ; L2, RW2=11, LEN2=01
    mov eax, [0x9100]                 ; bytes 9100-9103: no trap
    mov al, [0x9106]                  ; no trap
    mov eax, [0x9102]                 ; crosses into 9104: trap
rd1_next:
    mov eax, [0x9103]                 ; dword-crossing access: trap
rd2_next:
    DR7SET 0
    EXPECT ebp, 2, 9
    LOGCHK 0, 0x0004, rd1_next, 10
    LOGCHK 1, 0x0004, rd2_next, 11

    ; 4: disabled breakpoints never trap; B3 for the disabled match may be
    ; set or clear (vendor-variant, see the header).
    xor ebp, ebp
    mov eax, 0x9200
    mov dr1, eax
    mov dr3, eax
    DR7SET 0xd0d00004                 ; L1 only; DR3 RW/LEN set, L3 clear
    mov eax, [0x9200]                 ; read: neither traps (RW=01)
    DR7SET 0xf0f00004                 ; RW=11 for both, only L1 enabled
    mov eax, [0x9200]
both_next:
    DR7SET 0xf0f00000                 ; nothing enabled
    mov eax, [0x9200]
    DR7SET 0
    EXPECT ebp, 1, 12
    mov eax, [LOG]
    and eax, 0xe00f
    cmp eax, 0x0002                   ; B1 only (AMD APM, Am486DX4, z486)
    je bp_case4_b3_either
    EXPECT eax, 0x000a, 13            ; B1 and the disabled B3 (Intel486 PRM)
bp_case4_b3_either:
    mov eax, [LOG + 4]
    EXPECT eax, both_next, 13

    ; 5: TF and a data breakpoint report together (BS + B1).
    xor ebp, ebp
    DR7SET 0x00d00004                 ; L1 write on 0x9200
    pushfd
    or dword [esp], 0x100
    popfd                             ; TF from the next instruction
    mov dword [0x9200], 1
tf_next:
    pushfd
    and dword [esp], ~0x100
    popfd
    DR7SET 0
    LOGCHK 0, 0x4002, tf_next, 14

    ; 6: a stack push hits a write breakpoint.
    xor ebp, ebp
    mov eax, 0x7ffc
    mov dr0, eax
    DR7SET 0x000d0001                 ; L0, RW0=01, LEN0=11
    push eax
push_next:
    pop eax
    DR7SET 0
    EXPECT ebp, 1, 15
    LOGCHK 0, 0x0001, push_next, 16

    mov al, 1
    out 0xe0, al
    hlt

%assign c 1
%rep 16
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

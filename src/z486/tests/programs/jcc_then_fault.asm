; jcc_then_fault.asm - A Jcc that has been issued (and, when taken, is already
; redirecting the front end) must not disturb the delivery of a fault raised by
; the instruction that follows it.  Each case faults with the absent data
; selector 0x30, and the #GP handler checks that the reported EIP is exactly the
; faulting instruction's address, so a Jcc that "wins" the race and makes the
; fault land elsewhere (or swallows it) shows up here.
;
; Cases:
;   1. Jcc not taken, fault on the fall-through instruction.
;   2. Jcc taken forward, fault at the target.
;   3. Jcc whose condition comes from the immediately preceding instruction
;      (forwarded flags), taken, fault at the target.
;   4. Jcc taken backward (loop) into a faulting iteration.
;
; Protocol: port 0xE0 0x01 = pass, 0xFF = fail; on failure port 0xE4 carries
; 1 = a case did not fault, 2 = wrong EIP, 0x10 + n = only n cases faulted.
BITS 32
ORG 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
STATUS_PASS equ 0x01
STATUS_FAIL equ 0xFF
ES_SELECTOR equ 0x30

align 8
gdt:
    dq 0
    dq 0x00cf9b010000ffff    ; 0x08: code,  base 0x00010000, limit 0xFFFFF
    dq 0x00cf93000000ffff    ; 0x10: data,  base 0x00000000, limit 0xFFFFF
    dq 0x00cf93010000ffff    ; 0x18: data,  base 0x00010000, limit 0xFFFFF (DS: the image)
    dq 0                     ; 0x20
    dq 0                     ; 0x28
    dq 0                     ; 0x30: the selector under test -- ABSENT
gdt_end:
gdt_desc:
    dw gdt_end - gdt - 1
    dd 0x00010000 + gdt

align 8
idt:
    times 13 dq 0            ; vectors 0..12 absent
    dw gp_handler            ; vector 13: #GP, present
    dw 0x0008
    db 0
    db 0x8e
    dw 0
idt_end:
idt_desc:
    dw idt_end - idt - 1
    dd 0x00010000 + idt

; #GP frame at ring 0: [esp]=error code, [esp+4]=EIP, [esp+8]=CS, [esp+12]=EFLAGS
gp_handler:
    mov eax, [ss:esp + 4]
    cmp eax, [case_expected]
    jne report_bad_eip
    mov eax, [ss:esp]              ; the #GP error code must name the selector
    cmp eax, (ES_SELECTOR & 0xfff8)
    jne report_bad_eip
    add dword [ss:esp + 4], 2      ; skip `mov es, ax` (2 bytes)
    add esp, 4                     ; drop the error code
    inc dword [cases_ok]
    iret

times 0x200 - ($ - $$) db 0x90

start:
    cli
    lgdt [cs:gdt_desc]
    lidt [cs:idt_desc]
    mov ax, 0x18                     ; DS addresses the variables in the image
    mov ds, ax
    mov ax, 0x10
    mov ss, ax
    mov esp, 0x2ff0
    mov dword [zero], 0
    mov dword [cases_ok], 0

    ; --- case 1: Jcc NOT taken, fault on the fall-through instruction ---
    mov ax, ES_SELECTOR
    mov dword [case_expected], case1_es
    cmp dword [zero], 1              ; ZF=0 -> je falls through
    je  short case1_skip
case1_es:
    mov es, ax                       ; #GP(0x30); the handler resumes after it
    jmp case2
case1_skip:
    jmp fail_no_fault                ; the Jcc must not have been taken

    ; --- case 2: Jcc taken forward, fault at the target ---
case2:
    mov ax, ES_SELECTOR
    mov dword [case_expected], case2_es
    cmp dword [zero], 0              ; ZF=1 -> je is taken
    je  short case2_es
    jmp fail_no_fault
case2_es:
    mov es, ax                       ; #GP(0x30)
    jmp case3

    ; --- case 3: condition from the immediately preceding instruction ---
case3:
    mov ax, ES_SELECTOR
    mov ecx, 5
    mov dword [case_expected], case3_es
    cmp ecx, 5                       ; ZF=1, set one instruction earlier
    je  short case3_es
    jmp fail_no_fault
case3_es:
    mov es, ax                       ; #GP(0x30)
    jmp case4

    ; --- case 4: the fault repeats with a TAKEN backward Jcc immediately
    ;     before it (the handler skips the faulting instruction, so the second
    ;     and third faults follow the `jnz` redirect) ---
case4:
    mov ax, ES_SELECTOR
    mov edx, 3
case4_loop:
    mov dword [case_expected], case4_es
case4_es:
    mov es, ax                       ; #GP(0x30)
    dec edx
    jnz short case4_loop
    jmp case_done

case_done:
    cmp dword [cases_ok], 6          ; 1 + 1 + 1 + 3
    jne fail_too_few
    mov al, STATUS_PASS
    mov dx, STATUS_PORT
    out dx, al
    hlt

fail_no_fault:
    mov eax, 1
    jmp fail
; A wrong EIP is the interesting failure, so report the EIP the core pushed.
report_bad_eip:
    mov eax, [ss:esp + 4]
    mov dx, DATA_PORT
    out dx, eax
    mov al, STATUS_FAIL
    mov dx, STATUS_PORT
    out dx, al
    hlt
fail_too_few:
    mov eax, [cases_ok]
    add eax, 0x10
fail:
    mov dx, DATA_PORT
    out dx, eax
    mov al, STATUS_FAIL
    mov dx, STATUS_PORT
    out dx, al
    hlt

zero:     dd 0
cases_ok: dd 0
case_expected: dd 0

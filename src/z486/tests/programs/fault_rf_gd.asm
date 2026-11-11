; fault_rf_gd - the #DB general-detect fault pushes RF=0 (site 1; derived
; from fault_rf_classes)
;
; Every fault but a debug exception pushes RF=1.  A real Am486DX4 pushes RF=0
; for the general-detect #DB (CPUSUITE-XE10 run 1, fault_rf_gd FAIL
; F0000002: site 1's vector, error code and EIP right, RF wrong); AMD APM
; 24593 8.2.2, "When a #DB exception occurs, the processor clears RFLAGS.RF
; to 0 in the rFLAGS image that is pushed".  The PRM text below is the rule
; for the other faults:
;
; Intel486 PRM 11.3.1.1: "The processor sets the RF flag in the copy of the
; EFLAGS register pushed on the stack before entry into any fault handler",
; and "clears the RF flag at the successful completion of every instruction"
; (so INT n / INTO, which are traps, push RF=0).  fault_rf covers #DE/#UD/INT3;
; this program covers #GP(0), #GP(sel), #NP, #SS(0), #SS(sel), #TS (IRET
; back link, before the commit point), #BR,
; #NM (EM and TS+MP), #DF, a contributory fault raised while delivering a
; benign one, INTO and INT n.  Each FAULT site also checks vector, error
; code and the pushed EIP.
; Fail code (port E4): err[7:0]<<24 | vector<<16 | site*16 + 1 vector,
; 2 error code, 4 EIP.  RF mismatches are collected: at the end the program
; fails with F0000000h | (1 << site) for every site whose pushed RF was wrong.
BITS 32
ORG 0
RF equ 0x10000
SEL_CODE  equ 0x08
SEL_DATA  equ 0x10
SEL_STACK equ 0x18
SEL_RO    equ 0x20
SEL_NP    equ 0x28
SEL_TSS   equ 0x40
SEL_TSSSH equ 0x48

align 8
gdt:
    dq 0
    dq 0x00CF9B010000FFFF       ; 08 code, base 10000h
    dq 0x00CF93010000FFFF       ; 10 data, base 10000h
    dq 0x004093010000FFFF       ; 18 stack, base 10000h, byte limit FFFFh, B=1
    dq 0x00CF91010000FFFF       ; 20 read-only data
    dq 0x00CF13010000FFFF       ; 28 data, not present
    dq 0
    dq 0
tss_desc:                       ; 40 available 386 TSS
    dw 0x0067
    dw tss_a
    db 0x01, 0x89, 0x00, 0x00
tss_short:                      ; 48 386 TSS, available (not busy)
    dw 0x0067
    dw tss_b
    db 0x01, 0x89, 0x00, 0x00
gdt_end:
gdtr: dw gdt_end-gdt-1
      dd 0x10000+gdt

align 8
idt:
%assign v 0
%rep 34
    dw stub_ %+ v, SEL_CODE
    db 0, 0x8e
    dw 0
%assign v v+1
%endrep
idt_end:
idtr: dw idt_end-idt-1
      dd 0x10000+idt

%assign v 0
%rep 34
stub_ %+ v:
    push dword v
    jmp hcommon
%assign v v+1
%endrep

; vectors with an error code: 8, 10-14, 17
errmask: dd (1<<8)|(1<<10)|(1<<11)|(1<<12)|(1<<13)|(1<<14)|(1<<17)
last_vec: dd 0
last_err: dd 0
last_eip: dd 0
last_efl: dd 0
rf_bad: dd 0
bnds: dd 0, 10

hcommon:
    push eax
    push ebx
    mov eax, [ss:esp+8]
    mov [ss:last_vec], eax
    bt [ss:errmask], eax
    jc .err
    mov dword [ss:last_err], -1
    mov eax, [ss:esp+12]
    mov [ss:last_eip], eax
    mov [ss:esp+12], esi
    mov eax, [ss:esp+20]
    mov [ss:last_efl], eax
    pop ebx
    pop eax
    add esp, 4
    iretd
.err:
    mov eax, [ss:esp+12]
    mov [ss:last_err], eax
    mov eax, [ss:esp+16]
    mov [ss:last_eip], eax
    mov [ss:esp+16], esi
    mov eax, [ss:esp+24]
    mov [ss:last_efl], eax
    pop ebx
    pop eax
    add esp, 8
    iretd

fail:
    ; E4 = last_err[7:0] << 24 | last_vec[7:0] << 16 | code
    mov ebx, [ss:last_vec]
    shl ebx, 16
    or eax, ebx
    mov ebx, [ss:last_err]
    shl ebx, 24
    or eax, ebx
    out 0xe4, eax
    mov al, 0xff
    out 0xe0, al
    hlt

; SITE n, vector, errcode (-1 none), fault (1) or trap (0), expect_rf, insn...
%macro SITE 6+
    mov esi, %%resume
    mov dword [ss:last_vec], 0xff
    nop
%%site:
    %6
%%resume:
    mov eax, %1*16+1
    cmp dword [ss:last_vec], %2
    jne fail
    mov eax, %1*16+2
    cmp dword [ss:last_err], %3
    jne fail
    mov eax, %1*16+4
%if %4
    cmp dword [ss:last_eip], %%site      ; fault: EIP names the instruction
%else
    cmp dword [ss:last_eip], %%resume    ; trap: EIP names the next one
%endif
    jne fail
    mov eax, [ss:last_efl]
    and eax, RF
    mov ebx, %5*RF
    cmp eax, ebx
    je %%rf_ok
    or dword [ss:rf_bad], 1 << %1    ; RF mismatches are collected, not fatal
%%rf_ok:
%endmacro

times 0x400-($-$$) db 0x90
start:
    cli
    lgdt [cs:gdtr]
    lidt [cs:idtr]
    mov ax, SEL_DATA
    mov ds, ax
    mov es, ax
    mov ax, SEL_STACK
    mov ss, ax
    mov esp, 0xF000
    jmp SEL_CODE:.cs
.cs:
    mov ax, SEL_TSS
    ltr ax
    push dword 0x2
    popfd

    ; 1: #DB general detect (DR7.GD=1, MOV r32,DR0): a fault
    mov eax, 0x2000
    mov dr7, eax
    SITE 1, 1, -1, 1, 0, mov eax, dr0
    mov eax, dr6
    mov ebx, 1*16+6
    test eax, 0x2000             ; DR6.BD
    jz .bd_bad
    mov eax, [ss:rf_bad]
    test eax, eax
    jz pass
    or eax, 0xF0000000           ; F0000000 | bitmask of sites whose RF was wrong
    out 0xe4, eax
    mov al, 0xff
    out 0xe0, al
    hlt
.bd_bad:
    mov eax, ebx
    jmp fail
pass:
    mov al, 1
    out 0xe0, al
    hlt

align 4
tss_a: times 26 dd 0
tss_b: times 26 dd 0
    dd 0

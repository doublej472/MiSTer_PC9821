; tri_0f07_pm - triage probe: what 0F 07 does at CPL0 in protected mode (loadall_ud's setup, but every
; IDT vector 0-31 is caught). data (E4) = vector << 24 | 0x00AA0000 | (pushed EIP - site) & FFFFh,
; with the error code (if the vector pushes one) in trap EAX[31:8]. Completing without a fault
; reports data = 0x00CC0000 | AX (EAX was 11223344h). ES:EDI = 20000h:1 as in loadall_ud.
BITS 32
ORG 0
align 8
gdt:
    dq 0
    dq 0x00cf9b010000ffff     ; 08: code, base 0x10000
    dq 0x00cf93020000ffff     ; 10: data, base 0x20000
    dq 0x00cf93030000ffff     ; 18: stack, base 0x30000
gdt_end:
gdtr: dw gdt_end-gdt-1
      dd 0x10000+gdt
align 8
idt:
%assign v 0
%rep 32
    dw stub_ %+ v, 8
    db 0, 0x8e
    dw 0
%assign v v+1
%endrep
idt_end:
idtr: dw idt_end-idt-1
      dd 0x10000+idt
%assign v 0
%rep 32
stub_ %+ v:
 %if v == 8 || (v >= 10 && v <= 14) || v == 17
    pop edx                    ; error code
 %else
    xor edx, edx
 %endif
    mov ebx, v
    jmp catch_all
%assign v v+1
%endrep
catch_all:
    pop eax                    ; EIP
    sub eax, site
    and eax, 0xFFFF
    or eax, 0x00AA0000
    shl ebx, 24
    or eax, ebx
    out 0xe4, eax
    mov eax, edx
    shl eax, 8
    mov al, 0xff
    out 0xe0, al
    hlt
times 0x400-($-$$) db 0x90
start:
    cli
    mov esp, 0xf00
    lgdt [cs:gdtr]
    lidt [cs:idtr]
    mov eax, 0x11223344
    mov ebx, 0x55667788
    mov esi, 0x800
    mov edi, 1
site:
    db 0x0f, 0x07
    and eax, 0xFFFF
    or eax, 0x00CC0000
    out 0xe4, eax
    mov al, 0xff
    out 0xe0, al
    hlt

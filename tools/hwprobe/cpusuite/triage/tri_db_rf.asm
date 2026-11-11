; tri_db_rf - triage probe: the RF bit a #DB FAULT pushes (instruction breakpoint, then general
; detect). The handler records the pushed EFLAGS and then sets RF in the frame itself (as a real
; debugger does), so an RF=0 push cannot loop. data (E4) = EFLAGS pushed by the instruction-
; breakpoint #DB (bit 16 = RF). trap EAX[31:24] = instruction-breakpoint #DB count (1 = no
; re-break), EAX[23:16] = bits 23:16 of the EFLAGS pushed by the GD #DB (bit 16 of EAX = RF),
; EAX[15:8] = DR6[15:8] seen by the GD #DB (bit 13 = BD).
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
    mov eax, [esp + 12]          ; pushed EFLAGS
    mov [0x5000 + ebp*4], eax
    mov eax, dr6
    mov [0x5100 + ebp*4], eax
    xor eax, eax
    mov dr6, eax
    or dword [esp + 12], 0x10000 ; set RF in the frame
    inc ebp
    pop eax
    iretd
times 0x200-($-$$) db 0x90
start:
    cli
    mov esp, 0x8000
    lgdt [cs:gdtr]
    lidt [cs:idtr]
    xor ebp, ebp
    xor eax, eax
    mov dr6, eax
    mov eax, CODE_BASE + bp_insn
    mov dr0, eax
    mov eax, 0x00000001          ; L0 execute
    mov dr7, eax
    nop
bp_insn:
    inc ecx
    xor eax, eax
    mov dr7, eax
    mov edi, ebp                 ; instruction-breakpoint #DB count
    ; general detect
    mov eax, 0x2000
    mov dr7, eax
    mov eax, dr0                 ; #DB (GD), the CPU clears GD on entry
    xor eax, eax
    mov dr7, eax
    mov eax, [0x5000]
    out 0xe4, eax
    mov eax, edi
    shl eax, 8
    mov al, [0x5000 + 4*1 + 2]   ; GD frame EFLAGS[23:16] (entry 1 when the ibp count was 1)
    cmp edi, 1
    je .one
    mov al, 0xEE                 ; ibp count != 1: the GD entry index is not 1
.one:
    shl eax, 8
    mov al, [0x5100 + 4*1 + 1]   ; GD DR6[15:8]
    shl eax, 8
    mov al, 0xff
    out 0xe0, al
    hlt

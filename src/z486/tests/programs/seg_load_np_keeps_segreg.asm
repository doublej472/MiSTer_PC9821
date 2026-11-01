; seg_load_np_keeps_segreg - LFS/LGS (and LES/LDS/MOV/POP as controls) with a
; not-present selector raise #NP(selector) and leave the destination segment
; register's selector and the offset register unchanged (Intel486 PRM: a fault
; restores the state the instruction started with; MOV/POP/LxS list #NP(sel) for a
; not-present descriptor and load the register only once every check passed).
; Windows 95's GDI demand-loads discarded segments through exactly this #NP from
; `lfs si, es:[disp16]`; VMM saves the client FS in the fault frame and reloads it
; on the way back, so a clobbered FS (0xFFFF here) becomes a ring-0 #PF on the
; LDT's uncommitted top page and a fatal "Windows protection error".
; Fail code (port E4): selector-seen-by-handler << 16 | site*16 + check
; (1 vector, 2 error code, 3 handler's view of the register, 4 the register after
; IRET, 5 offset register).
BITS 32
ORG 0
SEL_CODE  equ 0x08
SEL_DATA  equ 0x10
SEL_STACK equ 0x18
SEL_NP    equ 0x28
SEL_DATA2 equ 0x30

align 8
gdt:
    dq 0
    dq 0x00CF9B010000FFFF       ; 08 code, base 10000h
    dq 0x00CF93010000FFFF       ; 10 data, base 10000h
    dq 0x004093010000FFFF       ; 18 stack
    dq 0x00CF93010000FFFF       ; 20 data
    dq 0x00CF13010000FFFF       ; 28 data, not present
    dq 0x00CF93010000FFFF       ; 30 data (a second valid selector)
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
last_vec: dd 0
last_err: dd 0
h_fs: dd 0
h_gs: dd 0
h_ds: dd 0
h_es: dd 0
farp: dw 0x5678, SEL_NP
farp32: dd 0x5678
        dw SEL_NP
hcommon:
    push eax
    mov eax, [ss:esp+4]
    mov [ss:last_vec], eax
    mov eax, [ss:esp+8]
    mov [ss:last_err], eax
    mov ax, fs
    mov [ss:h_fs], ax
    mov ax, gs
    mov [ss:h_gs], ax
    mov ax, ds
    mov [ss:h_ds], ax
    mov ax, es
    mov [ss:h_es], ax
    mov [ss:esp+12], esi       ; resume at esi
    pop eax
    add esp, 8
    iretd
fail:
    out 0xe4, eax
    mov al, 0xff
    out 0xe0, al
    hlt

%macro LFS16 0
    db 0x26, 0x66, 0x67, 0x0F, 0xB4, 0x1E
    dw farp
%endmacro
%macro LGS16 0
    db 0x66, 0x67, 0x0F, 0xB5, 0x1E
    dw farp
%endmacro
%macro SITE 3+
    ; site, seg-name-to-check (fs/gs/ds/es), insn
    mov esi, %%resume
    mov dword [ss:last_vec], 0xff
    mov ebx, 0xA5A5A5A5
    mov ecx, 0xA5A5A5A5
%%site:
    %3
%%resume:
    mov eax, %1*16+1
    cmp dword [ss:last_vec], 11
    jne fail
    mov eax, %1*16+2
    cmp word [ss:last_err], SEL_NP
    jne fail
    movzx eax, word [ss:h_%2]
    shl eax, 16
    or eax, %1*16+3
    cmp word [ss:h_%2], SEL_DATA2     ; the handler saw the OLD selector
    jne fail
    mov eax, %1*16+4
    mov dx, %2
    cmp dx, SEL_DATA2                 ; and it is still there after IRET
    jne fail
    mov eax, %1*16+5
    cmp ebx, 0xA5A5A5A5               ; the offset register is untouched
    jne fail
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
    mov ax, SEL_DATA2
    mov fs, ax
    mov gs, ax
    ; 1: Win95 GDI's form: 16-bit operand and address size, ES override:
    ;    (GDI: 26 0F B4 36 disp16 = lfs si, es:[disp16]; here the bx form, 0x1E)
    SITE 1, fs, LFS16
    ; 2: plain 32-bit LFS
    SITE 2, fs, lfs ebx, [es:farp32]
    ; 3: LGS 16-bit
    SITE 3, gs, LGS16
    ; 4: LES (es is the reload target; access through ds)
    mov ax, SEL_DATA2
    mov es, ax
    SITE 4, es, les ebx, [ds:farp32]
    ; 5: LDS
    mov ax, SEL_DATA2
    mov ds, ax
    SITE 5, ds, lds ebx, [ss:farp32]
    mov ax, SEL_DATA
    mov ds, ax
    mov es, ax
    ; 6: MOV FS, r16 with a not-present selector
    mov ax, SEL_DATA2
    mov fs, ax
    mov ax, SEL_NP
    SITE 6, fs, mov fs, ax
    ; 7: POP GS of a not-present selector
    mov ax, SEL_DATA2
    mov gs, ax
    push dword SEL_NP
    SITE 7, gs, pop gs
    add esp, 4
    ; pass
    mov al, 0x01
    out 0xe0, al
    hlt

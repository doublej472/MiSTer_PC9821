; ed_seg_limit_check.asm - an expand-down data segment must fault offsets
; <= limit and admit offsets > limit (valid range limit+1 .. max).
BITS 32
ORG 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4

STATUS_PASS equ 0x01
STATUS_FAIL equ 0xFF

CODE_LINEAR  equ 0x00010000
VALID_OFF    equ 0x00001000     ; > 0x0FFF: legal in an expand-down segment
INVALID_OFF  equ 0x00000800     ; <= 0x0FFF: illegal in an expand-down segment
EXPECTED     equ 0xA5A5A5A5

MARK_VALID   equ 0x00000F00
MARK_INVALID equ 0x00000F04
MARK_DATA    equ 0x00000F08
MARK_OTHER   equ 0x00000F0C

align 8
gdt:
    dq 0
    dq 0x00cf9b010000ffff    ; 0x08: code,  base 0x00010000, limit 0xFFFFF
    dq 0x00cf93040000ffff    ; 0x10: data,  base 0x00040000, limit 0xFFFFF (DS)
    dq 0x0040960400000fff    ; 0x18: data,  base 0x00040000, limit 0x0FFF, type 0110
                             ;       (expand-down, writable), byte granularity
gdt_end:

gdt_desc:
    dw gdt_end - gdt - 1
    dd CODE_LINEAR + gdt

; #GP handler.  Only the two probes can fault; each is a segment-limit
; violation, so record which one and resume after it.
gp_handler:
    mov eax, [ss:esp]           ; error code
    mov edx, [ss:esp + 4]       ; faulting EIP
    add esp, 4                  ; drop the error code so [esp] is the EIP slot
    cmp edx, probe_valid
    je gp_valid
    cmp edx, probe_invalid
    je gp_invalid
    mov dword [ds:MARK_OTHER], 1        ; stray fault: flag as unexpected
    mov dword [ss:esp], unexpected_after
    iretd
gp_valid:
    mov dword [ds:MARK_VALID], 1
    mov dword [ss:esp], valid_after
    iretd
gp_invalid:
    mov dword [ds:MARK_INVALID], 1
    mov dword [ss:esp], invalid_after
    iretd

align 8
idt:
    times 13 dq 0           ; vectors 0..12 absent
    dw gp_handler           ; vector 13: #GP
    dw 0x0008
    db 0
    db 0x8e                 ; present DPL0 386 interrupt gate
    dw 0
idt_end:

idt_desc:
    dw idt_end - idt - 1
    dd CODE_LINEAR + idt

times 0x200 - ($ - $$) db 0x90
start:
    cli
    lgdt [cs:gdt_desc]
    lidt [cs:idt_desc]

    mov esp, 0x00000F00

    mov dword [ds:MARK_VALID], 0
    mov dword [ds:MARK_INVALID], 0
    mov dword [ds:MARK_DATA], 0
    mov dword [ds:MARK_OTHER], 0

    ; Preload the target through the normal (expand-up) DS descriptor.
    mov dword [ds:VALID_OFF], EXPECTED

    ; Install the expand-down descriptor in ES.
    mov ax, 0x18
    mov es, ax

    mov ebx, VALID_OFF
probe_valid:
    mov eax, [es:ebx]           ; valid expand-down range -> must NOT fault
valid_after:
    ; If no fault was taken, EAX holds the preloaded pattern.  A core that
    ; faults here resumes from the handler with EAX clobbered; MARK_VALID then
    ; fails the test.
    cmp eax, EXPECTED
    je .data_ok
    mov dword [ds:MARK_DATA], 1
.data_ok:
    mov ebx, INVALID_OFF
probe_invalid:
    mov eax, [es:ebx]           ; invalid expand-down range -> must #GP
invalid_after:
unexpected_after:
    xor ebx, ebx

    ; Expect VALID did not fault, INVALID did fault, data matched.
    mov eax, [ds:MARK_VALID]
    test eax, eax
    jnz fail_valid
    mov eax, [ds:MARK_DATA]
    test eax, eax
    jnz fail_data
    mov eax, [ds:MARK_INVALID]
    test eax, eax
    jz fail_invalid
    mov eax, [ds:MARK_OTHER]
    test eax, eax
    jnz fail_other

    mov al, STATUS_PASS
    mov dx, STATUS_PORT
    out dx, al
    hlt

fail_valid:
    mov eax, 1
    jmp fail
fail_invalid:
    mov eax, 2
    jmp fail
fail_data:
    mov eax, 3
    jmp fail
fail_other:
    mov eax, 4

fail:
    shl eax, 8
    mov edx, [ds:MARK_VALID]
    or eax, edx
    mov edx, [ds:MARK_INVALID]
    shl edx, 1
    or eax, edx
    mov edx, [ds:MARK_DATA]
    shl edx, 2
    or eax, edx
    mov dx, DATA_PORT
    out dx, eax
    mov al, STATUS_FAIL
    mov dx, STATUS_PORT
    out dx, al
    hlt

times 0x800 - ($ - $$) db 0

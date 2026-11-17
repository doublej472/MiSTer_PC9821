; gp_double_fault_deliver.asm - a delivery that cannot complete must escalate to
; #DF, and #DF must be DELIVERED through a valid #DF gate, not turned into a
; processor reset.
;
; A real 486: the null-descriptor load of ES raises #GP(0x0030); fetching gate
; 13 finds no gate, which is a fault while delivering #GP, so the processor
; raises #DF; fetching gate 8 finds the handler below, and #DF is delivered.
; Reset only happens when the #DF gate is unusable too.
;
; z486 used to reset here. The RTL selects UADDR_DOUBLE_FAULT for a second
; fault only from an RTL fault source (seq_fault_redirect for gp_fault_r, and
; div_redirect_target for div_overflow, both under double_fault_start); a
; delivery the MICROCODE starts -- which is what the segment-load routine's
; default LJUMP (uc=0x5D1 -> 0x85D) and the delivery body's own "this IDT entry
; is not a usable gate" redirect (uc=0x8BE, test constant 0x2A JMP_GFAULT_INT
; -> uc=0x865) produce -- has no such source, so the re-entry into the
; exception-entry cluster only counted as a delivery start. z486 now redirects
; that re-entry to UADDR_DOUBLE_FAULT.
;
; The other half, a #GP delivered normally through intact tables, is what every
; other #GP program in this directory exercises (the companion payload this
; program was written beside was not carried into the tree).
;
; Result protocol:
;   Port 0xE0: 0x01 = pass, 0xFF = fail
;   Port 0xE4: on pass (saved CS << 16) | error code; on failure 1 = the main
;              flow continued, 2 = the #DF frame was not a #DF frame

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
    dq 0x00cf93010000ffff    ; 0x18: stack, base 0x00010000, limit 0xFFFFF
    dq 0x00cf93000000ffff    ; 0x20: data alias of 0x10
    dq 0                     ; 0x28
    dq 0                     ; 0x30: the selector under test -- ABSENT
    dq 0x00cf9b010000ffff    ; 0x38: code alias of 0x08
gdt_end:

gdt_desc:
    dw gdt_end - gdt - 1
    dd 0x00010000 + gdt

; Vector 8 (#DF) present; vector 13 (#GP) ABSENT, so the #GP delivery cannot
; complete and the processor must escalate to #DF through this gate.
align 8
idt:
    times 8 dq 0            ; vectors 0..7 absent
    dw df_handler           ; vector 8: #DF
    dw 0x0008
    db 0
    db 0x8e
    dw 0
    times 5 dq 0            ; vectors 9..13 absent
idt_end:

idt_desc:
    dw idt_end - idt - 1
    dd 0x00010000 + idt

df_handler:
    ; #DF pushes a zero error code and the faulting instruction's EIP and CS, so
    ; the frame pins that this really is a double fault and not a stray #GP.
    mov eax, [ss:esp + 8]           ; saved CS
    cmp eax, 0x0008
    jne fail_bad_frame
    mov eax, [ss:esp]               ; error code: #DF pushes zero
    test eax, eax
    jnz fail_bad_frame
    mov eax, [ss:esp + 4]           ; faulting EIP: the null-descriptor load
    cmp eax, es_load
    jne fail_bad_frame

    mov eax, [ss:esp + 8]
    shl eax, 16
    mov edx, [ss:esp]
    and edx, 0xffff
    or eax, edx
    mov dx, DATA_PORT
    out dx, eax
    mov al, STATUS_PASS
    mov dx, STATUS_PORT
    out dx, al
    hlt

fail_bad_frame:
    mov eax, 2
    mov dx, DATA_PORT
    out dx, eax
    mov al, STATUS_FAIL
    mov dx, STATUS_PORT
    out dx, al
    hlt

times 0x200 - ($ - $$) db 0x90

start:
    cli
    mov esp, 0x8000                 ; SS base 0x10000: the frame lands at 0x17FF4
    lgdt [cs:gdt_desc]
    lidt [cs:idt_desc]

    mov ax, ES_SELECTOR
es_load:
    mov es, ax                      ; #GP -> gate 13 absent -> #DF -> gate 8

    mov eax, 1
    mov dx, DATA_PORT
    out dx, eax
    mov al, STATUS_FAIL
    mov dx, STATUS_PORT
    out dx, al
    hlt

times 0x400 - ($ - $$) db 0

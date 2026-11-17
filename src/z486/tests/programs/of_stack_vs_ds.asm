; of_stack_vs_ds.asm - the same 1-bit SHL (0x80000000 -> 0, CF=1 OF=1 ZF=1)
; with a DS-based operand and with an ESP-based operand, and then with the value
; pushed on the stack so the microcode chains the stack op with the shift.
; Each case prints raw EFLAGS then the stored result, and checks them: OF, SF,
; ZF, PF and CF must read 1,0,1,1,1 (AF is undefined after a shift and is not
; compared) and every result 0.  On a failure port 0xE4 last gets the case
; number (1-3) in BL, after the raw flags or result that failed.
BITS 32
org 0
STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
D1 equ 0x4000
start:
    mov esp, 0x3000
    mov bl, 1

    ; 1: DS-based operand
    mov dword [D1], 0x80000000
    shl dword [D1], 1
    pushfd
    pop eax
    mov dx, DATA_PORT
    out dx, eax
    call check_flags
    mov eax, [D1]
    out dx, eax
    test eax, eax
    jnz fail
    inc bl

    ; 2: ESP-based operand
    mov dword [esp+8], 0x80000000
    shl dword [esp+8], 1
    pushfd
    pop eax
    out dx, eax
    call check_flags
    mov eax, [esp+8]
    out dx, eax
    test eax, eax
    jnz fail
    inc bl

    ; 3: value pushed, shift on [esp], then pop it back
    push dword 0x80000000
    shl dword [esp], 1
    pushfd
    pop eax
    out dx, eax
    call check_flags
    pop eax
    out dx, eax
    test eax, eax
    jnz fail
    cmp esp, 0x3000
    jne fail

    mov al, 0x01
    mov dx, STATUS_PORT
    out dx, al
    hlt
; EAX = EFLAGS: OF SF ZF PF CF = 1 0 1 1 1 (mask 0x8C5)
check_flags:
    and eax, 0x8C5
    cmp eax, 0x845
    jne fail
    ret

fail:
    mov al, bl
    mov dx, DATA_PORT
    out dx, al
    mov al, 0xFF
    mov dx, STATUS_PORT
    out dx, al
    hlt

; fpu_detect.asm - Test ESC instruction decode with modrm displacement
;
; Test 1 (EM=1): an ESC with a memory operand raises #NM (CR0.EM=1) with the
; ESC's own address as the return IP, exactly once; the handler records both
; and skips the 3-byte instruction.
;
; Test 2 (EM=0, DOS4GW-style): Replicates DOS/4GW's FPU detection sequence:
; FNINIT + FNSTSW [BP-2] + check status. With no FPU and EM=0, the ESC
; instructions execute via microcode (JPEREQ must be taken). FNSTSW must
; complete without hanging and leave [BP-2] either at its pre-set 0xFFFF (no
; FPU writes it) or 0x0000 (the x87 build's status word after FNINIT); any
; other value is a wrong-width or misaddressed store.  The instructions after
; it run only if FNSTSW was decoded as 3 bytes.
;
; Test 3 (EM=0, SPEED600-style FLD TBYTE): detects only a hang.

BITS 16
org 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
STATUS_PASS equ 0x01
STATUS_FAIL equ 0xFF

start:
    cli
    cld

    mov ax, cs
    mov ds, ax
    mov ss, ax
    mov sp, 0x200
    mov bp, sp

    ; Set up IVT entry for INT 7 (#NM)
    xor ax, ax
    mov es, ax
    mov word [es:0x1C], nm_handler
    mov word [es:0x1E], 0x1000

    ;=== Test 1: EM=1, ESC decode length ===
    smsw ax
    or al, 0x04          ; CR0.EM=1
    lmsw ax

    xor ax, ax
    mov [cs:nm_count], ax
.esc1:
    db 0xDD, 0x7E, 0xFE  ; FNSTSW [BP-2] → #NM, handler skips 3 bytes
    cmp word [cs:nm_count], 1
    jne .fail1
    cmp word [cs:nm_ip], .esc1
    jne .fail1

    ; Clear EM
    smsw ax
    and al, 0xFB          ; CR0.EM=0
    lmsw ax

    ;=== Test 2: EM=0, DOS4GW-style FPU detection ===
    ; Pre-fill [BP-2] with 0xFFFF — a real FNSTSW would write 0
    mov bp, sp
    push word 0xFFFF      ; [BP-2] = 0xFFFF

    db 0xDB, 0xE3         ; FNINIT — must not hang (JPEREQ taken)
    db 0xDD, 0x7E, 0xFE   ; FNSTSW [BP-2] — must not hang, must be 3 bytes

    mov ax, [bp-2]
    cmp ax, 0xFFFF        ; no FPU: the slot is untouched
    je .t2_ok
    test ax, ax           ; an FPU: the status word after FNINIT is 0
    jnz .fail2
.t2_ok:

    ; Verify we didn't hang — reaching here means JPEREQ worked
    pop ax                ; clean stack

    ;=== Test 3: EM=0, FLD TBYTE (SPEED600-style FPU detection) ===
    ; FLD uses FPU_LOAD_CORWA (uc 503) which has a JPEREQ self-loop.
    ; With no FPU, the self-loop must NOT be taken (fall through).
    db 0x9B, 0xDB, 0xE3   ; FINIT
    db 0xDB, 0x2E          ; FLD TBYTE PTR [imm16]
    dw fpu_tbyte_data      ;   address of 80-bit data
    ; If FLD hangs in the JPEREQ self-loop, we never reach here
    db 0xD8, 0xC0          ; FADD ST0, ST0
    db 0x9B, 0xDF, 0xE0   ; FSTSW AX
    ; Reaching here means the FPU data transfer loop didn't hang
    nop

    mov al, STATUS_PASS
    mov dx, STATUS_PORT
    out dx, al
    hlt
    jmp $

.fail1:
    smsw ax
    and al, 0xFB
    lmsw ax
    mov eax, 0x00000001   ; error code 1: EM=1 #NM count or return IP
    mov dx, DATA_PORT
    out dx, eax
    mov al, STATUS_FAIL
    mov dx, STATUS_PORT
    out dx, al
    hlt
    jmp $

.fail2:
    mov eax, 0x00000002   ; error code 2: EM=0 FNSTSW store
    mov dx, DATA_PORT
    out dx, eax
    mov al, STATUS_FAIL
    mov dx, STATUS_PORT
    out dx, al
    hlt
    jmp $

; 80-bit FPU test data (10 bytes)
fpu_tbyte_data:
    dd 0x00000000
    dd 0x80000000
    dw 0x3FFF          ; 1.0 in 80-bit extended precision

nm_count: dw 0
nm_ip:    dw 0

; #NM handler: record the return IP, skip the 3-byte ESC instruction
nm_handler:
    push bp
    mov bp, sp
    inc word [cs:nm_count]
    push ax
    mov ax, [bp+2]
    mov [cs:nm_ip], ax
    pop ax
    add word [bp+2], 3
    pop bp
    iret

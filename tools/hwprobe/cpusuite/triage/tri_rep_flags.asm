; tri_rep_flags - triage variant of rep_string_fault_progress: every mismatch as a bit (slot*4+field-1), the slot-5 FLAGS and ECX
; rep_string_fault_progress - a REP string fault keeps completed elements
;
; Intel486 PRM, "REP/REPE/REPZ/REPNE/REPNZ": a repeated string instruction
; that faults is restartable - the registers point at the faulting element and
; everything the completed iterations did (ECX count, index registers, the
; flags of the last completed CMPS/SCAS comparison) is architectural.  The
; real-mode limit is 0FFFFh, so an a32 index stepping to 10000h raises
; interrupt 13 on the *second* element.
;
; Each slot runs one REP string op whose first element completes and whose
; second faults; the #GP handler counts the fault and resumes after the
; instruction with the pushed FLAGS, and the slot then records ECX, EDI and
; FLAGS (arithmetic flags compared).  Slot 3 is a non-faulting control.  Port
; 0xE4 reports (slot << 8) | field for every mismatch.
BITS 16
ORG 0
CUR   equ 0x08f0
R_ECX equ 0x0900                ; dword per slot
R_EDI equ 0x0940                ; dword per slot
R_FLG equ 0x0980                ; word per slot
R_FLT equ 0x09a0                ; #GP count per slot
DSEG  equ 0x3000                ; data segment for DS and ES
AFLAGS equ 0x08d5               ; OF SF ZF AF PF CF

%macro SLOT 2                   ; n, instruction bytes...
    mov word [cs:CUR], %1
    mov word [cs:CONT + %1*2], %%c
    db %2
%%c:
    ; The handler IRETs the pushed FLAGS, so the live state here is the
    ; fault-time state for a faulting slot and the final one otherwise.
    mov [cs:R_ECX + %1*4], ecx
    mov [cs:R_EDI + %1*4], edi
    pushf
    pop word [cs:R_FLG + %1*2]
%endmacro

start:
    cli
    cld
    xor ax, ax
    mov ss, ax
    mov sp, 0x7000
    mov ds, ax
    mov word [13*4], gp_handler
    mov word [13*4+2], cs
    mov ax, cs
    mov ds, ax
    mov ax, DSEG
    mov es, ax
    xor ax, ax
    mov di, R_FLT
    mov cx, 8
.clr:
    mov [di], al
    inc di
    loop .clr

    ; Slot 0: a32 REPNE STOSB at ES:FFFF, ECX=5.  F2 STOS repeats like F3;
    ; one byte is stored, then ES:10000 faults with ECX=4, EDI=10000h.
    mov eax, 0x000000a5
    mov edi, 0xffff
    mov ecx, 5
    xor dx, dx                  ; ZF=1 PF=1: STOS leaves flags alone
    SLOT 0, {0xf2, 0x67, 0xaa}

    ; Slot 1: a32 REP STOSB (F3), same geometry, as the reference.
    mov edi, 0xffff
    mov ecx, 5
    xor dx, dx
    SLOT 1, {0xf3, 0x67, 0xaa}

    ; Slot 2: a32 REPNE SCASB at ES:FFFF (the A5 stored above) against AL=03:
    ; 03h-A5h = 5Eh leaves CF=1 AF=1, ZF=SF=PF=OF=0 (0011h), the loop continues
    ; and ES:10000 faults.  Start from ZF=1 CF=0 so stale flags are visible.
    mov al, 0x03
    mov edi, 0xffff
    mov ecx, 5
    xor dx, dx                  ; ZF=1 PF=1 CF=0 SF=0
    SLOT 2, {0xf2, 0x67, 0xae}

    ; Slot 3: a32 REPE CMPSB, DS:ESI=[byte 03] vs ES:EDI=FFFF (A5): the first
    ; element compares 03h-A5h (0011h, ZF=0), so REPE stops normally with
    ; ECX=4: a non-fault control for the flag path.
    mov esi, src_byte
    mov edi, 0xffff
    mov ecx, 5
    xor dx, dx
    SLOT 3, {0xf3, 0x67, 0xa6}

    ; Slot 4: a32 REPNE CMPSB, same operands: ZF=0 so the loop continues and
    ; ES:10000 faults after one element.
    mov esi, src_byte
    mov edi, 0xffff
    mov ecx, 5
    xor dx, dx
    SLOT 4, {0xf2, 0x67, 0xa6}

    ; Slot 5: a32 REPNE SCASD with DF=1: dword at ES:0000 (zero) vs EAX=1
    ; compares 1-0 (flags 0000h), EDI steps to FFFFFFFCh and faults.
    std
    mov eax, 1
    xor edi, edi
    mov dword [es:0], 0
    mov ecx, 3
    xor dx, dx
    SLOT 5, {0xf2, 0x67, 0x66, 0xaf}
    cld

    ; ---- check ----
    xor bx, bx
    xor si, si
    xor di, di
    xor ebp, ebp
.loop:
    mov ax, si
    shl ax, 2
    mov di, ax
    mov eax, [R_ECX + di]
    cmp eax, [X_ECX + di]
    je .e1
    mov dl, 1
    call report
.e1:
    mov eax, [R_EDI + di]
    cmp eax, [X_EDI + di]
    je .e2
    mov dl, 2
    call report
.e2:
    mov ax, si
    shl ax, 1
    mov di, ax
    mov ax, [R_FLG + di]
    and ax, AFLAGS
    cmp ax, [X_FLG + di]
    je .e3
    mov dl, 3
    call report
.e3:
    mov al, [R_FLT + si]
    cmp al, [X_FLT + si]
    je .e5
    mov dl, 5
    call report
.e5:
    inc si
    cmp si, 6
    jb .loop
    cmp byte [es:0xffff], 0xa5
    je .e4
    mov si, 0x0f
    mov dl, 4
    call report
.e4:
    mov eax, ebp                ; TRIAGE: data = mismatch bitmask, trap EAX[31:16] = slot 5 FLAGS, [15:8] slot 5 ECX
    out 0xe4, eax
    mov ax, [R_FLG + 10]
    shl eax, 16
    mov ah, [R_ECX + 20]
    jmp bad                     ; TRIAGE: always report
    mov al, 1
    out 0xe0, al
    hlt
bad:
    mov al, 0xff                ; (EAX upper bits set above)
    out 0xe0, al
    hlt

report:                         ; si = slot, dl = field   TRIAGE: bit (slot*4 + field-1) of ebp
    inc bx
    push eax
    push cx
    mov cx, si
    cmp cx, 6
    jb .s
    mov cx, 6
.s: shl cx, 2
    add cl, dl
    dec cl
    mov eax, 1
    shl eax, cl
    or ebp, eax
    pop cx
    pop eax
    ret

gp_handler:
    push bp
    mov bp, sp
    push si
    push ax
    mov si, [cs:CUR]
    inc byte [cs:R_FLT + si]
    add si, si
    mov ax, [cs:CONT + si]
    mov [bp+2], ax
    pop ax
    pop si
    pop bp
    iret

src_byte: db 0x03
align 4
CONT:  times 8 dw 0
;                slot0     slot1     slot2     slot3     slot4     slot5
X_ECX: dd        4,        4,        4,        4,        4,        2
X_EDI: dd  0x10000,  0x10000,  0x10000,  0x10000,  0x10000, 0xfffffffc
X_FLG: dw   0x0044,   0x0044,   0x0011,   0x0011,   0x0011,   0x0000
X_FLT: db        1,        1,        1,        0,        1,        1

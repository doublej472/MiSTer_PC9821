; tri_0f05_rm - triage probe: what 0F 05 does in real mode (CPL0). Every IVT vector 0-31 is caught.
; data (E4) = vector << 24 | faulting IP - site (0 = the 0F 05 itself) & FFFFh | 0x00AA0000 marker
; If 0F 05 neither faults nor completes (a 386-style LOADALL from ES:EDI = 0:7000h, a zeroed
; buffer, loads CR0=0 and CS:EIP=0:0), the program never reports: the row has no verdict / a reset.
; Completing without a fault reports data = 0x00CC0000 | low word of EAX (EAX was 11223344h).
BITS 16
org 0
start:
    cli
    xor ax, ax
    mov ss, ax
    mov ds, ax
    mov es, ax
    mov sp, 0x8000
    xor si, si
.fill:
    mov ax, si
    imul ax, ax, 5
    add ax, stubs
    mov bx, si
    add bx, bx
    mov [bx], ax            ; compact table; spread to 4-byte IVT entries below
    inc si
    cmp si, 32
    jb .fill
    ; spread the offsets into 4-byte entries (backwards so nothing is overwritten early)
    mov si, 31
.spread:
    mov bx, si
    add bx, bx
    mov ax, [bx]
    add bx, bx
    mov [bx], ax
    mov [bx+2], cs
    dec si
    jns .spread
    mov edi, 0x7000
    mov eax, 0x11223344
site:
    db 0x0f, 0x05
    and eax, 0xFFFF
    or eax, 0x00CC0000
    out 0xE4, eax
    mov al, 0xFF
    out 0xE0, al
    hlt
stubs:
%assign v 0
%rep 32
    mov bl, v
    jmp near catch_all
%assign v v+1
%endrep
catch_all:
    pop ax                  ; IP
    sub ax, site
    movzx eax, ax
    or eax, 0x00AA0000
    movzx ebx, bl
    shl ebx, 24
    or eax, ebx
    out 0xE4, eax
    mov al, 0xFF
    out 0xE0, al
    hlt

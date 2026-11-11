; tri_pg_grace0 - triage probe: how many bytes after the MOV CR0 that sets PG still come from the
; untranslated (prefetched) stream. Linear 10000h (this code page) maps to physical 30000h once
; paging is on; 30000h holds a copy of this page whose 64-byte sled after MOV CR0 is INC ECX
; (41h) instead of NOP (90h). data (E4) = ECX = sled bytes executed from the TRANSLATED copy
; (0: the whole sled ran untranslated; 64: translation at once). The sled starts 0 bytes into a
; 16-byte line. trap EAX[31:8] = 0.
BITS 32
ORG 0
SLED equ 64
start:
    cli
    mov esp, 0x8000
    cld
    mov esi, 0x10000
    mov edi, 0x30000
    mov ecx, 0x1000 / 4
    rep movsd
    mov edi, 0x30000 + sled
    mov ecx, SLED
    mov al, 0x41
    rep stosb
    xor ecx, ecx
    mov eax, cr0
    or eax, 0x80000000
    jmp pre
    align 16
    times 16 + 0 - 3 db 0x90
pre:
    mov cr0, eax                 ; 3 bytes: the sled starts 0 bytes into a line
sled:
    times SLED db 0x90
    mov eax, ecx
    out 0xe4, eax
    mov eax, 0 << 8
    mov al, 0xff
    out 0xe0, al
    hlt

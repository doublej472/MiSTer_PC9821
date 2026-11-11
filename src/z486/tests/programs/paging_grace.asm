; paging_grace - after MOV CR0 sets PG, the bytes already in the prefetch queue
; still run untranslated.  EMM386's switch page is not identity-mapped, so the
; instruction behind MOV CR0 must come from the page it was prefetched from.
;
; Linear 10000h (this code page) maps to physical 30000h once paging is on;
; 30000h holds a copy of this page whose 64-byte sled after MOV CR0 is INC ECX
; (41h) instead of NOP (90h).  ECX afterwards = the sled bytes executed from
; the TRANSLATED copy: 64 means translation took effect at once (fail).
;
; How long the grace lasts is accepted at either of two lengths, the sled
; starting 8 bytes into a 16-byte line:
;   - the rest of that 16-byte line, 16 - 8 = 8 bytes untranslated, ECX = 56:
;     the Xe10's Am486DX4 (CPUSUITE-XE10-triage: tri_pg_grace0/8/13 data
;     00000030h/00000038h/0000003Dh, i.e. 16 - offset untranslated for a sled
;     at line offset 0/8/13);
;   - one more line, 32 - 8 = 24 bytes untranslated, ECX = 40: z486 (it keeps
;     32 - offset).
; The program used to assume "untranslated until the next branch"; the Xe10
; reset on it (CPUSUITE-XE10 run 4), its byte after the line came translated.
; Failure data = ECX.
BITS 32
ORG 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
SLED        equ 64

start:
    cli
    mov esp, 0x00008000
    cld
    mov esi, 0x10000                     ; the translated view: a copy of this
    mov edi, 0x30000                     ; page with the sled made of INC ECX
    mov ecx, 0x1000 / 4
    rep movsd
    mov edi, 0x30000 + sled
    mov ecx, SLED
    mov al, 0x41
    rep stosb
    xor ecx, ecx
    mov eax, cr0
    or  eax, 0x80000000
    jmp pre
    align 16
    times 16 + 8 - 3 db 0x90
pre:
    mov cr0, eax                         ; 3 bytes: the sled starts 8 bytes into a line
sled:
    times SLED db 0x90
    cmp ecx, SLED - (16 - 8)             ; the Am486DX4: the rest of the line
    je pass
    cmp ecx, SLED - (32 - 8)             ; z486: one line more
    jne fail
pass:
    mov al, 1
    mov dx, STATUS_PORT
    out dx, al
    hlt

fail:
    mov eax, ecx
    mov dx, DATA_PORT
    out dx, eax
    mov al, 0xff
    mov dx, STATUS_PORT
    out dx, al
    hlt

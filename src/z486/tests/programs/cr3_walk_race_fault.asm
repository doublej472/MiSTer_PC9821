; cr3_walk_race_fault.asm - a prefetch walk that starts under A (where the next
; page N_j is absent) and finishes after MOV CR3 to B (where N_j is present)
; must not deliver the fault computed from A's tables.
;
; Each trial runs "mov cr3,eax" in the last bytes of P_j and falls through into
; N_j, which B maps to T_j. T_j's stub records a marker and returns.
;
; Real silicon: the Xe10's Am486DX4 DOES deliver A's #PF.  The CPUSUITE triage
; run of tri_cr3_race (this program with the stack below fixed and CR2/EIP
; reported) gave data=00012000h: CR2 = N_0, pushed EIP = N_0's first byte, the
; fault from A's walk for the prefetch of N_0, taken after MOV CR3 switched to
; B.  z486 keeps this program's expectation (no fault) pending an owner
; decision; this program checks z486's behaviour, not the part's.
BITS 32
ORG 0

STATUS_PORT equ 0xE0
DATA_PORT   equ 0xE4
CSBASE      equ 0x10000
NTRIALS     equ 8
PFLAGS      equ 0x23

%define P(j)  (0x11000 + (j)*0x2000)
%define N(j)  (P(j) + 0x1000)
%define T(j)  (0x21000 + (j)*0x1000)

PD_B   equ 0x2000
PT_B   equ 0x3000

start:
    cli
    mov esp, 0x0003FF00        ; inside the one mapped stack page (3F000h): at
                               ; 3F000h the first push landed in unmapped 3E000h
    lgdt [cs:gdt_desc]
    lidt [cs:idt_desc]

    ; Address space B (PD_B) is a copy of A's page table (PT_A at 0x1000) with
    ; each N_j redirected to T_j.  A keeps N_j absent.
    cld
    mov esi, 0x1000
    mov edi, PT_B
    mov ecx, 1024
    rep movsd
    mov edi, PD_B
    xor eax, eax
    mov ecx, 1024
    rep stosd
    mov dword [PD_B], PT_B | PFLAGS
%assign j 0
%rep NTRIALS
    mov dword [PT_B + (N(j) >> 12)*4], T(j) | PFLAGS
%assign j j+1
%endrep

    ; Each trial: jump to the end of P_j, switch A -> B, fall into N_j (B maps
    ; it to T_j), the stub records the marker and returns to cont_j.
%assign j 0
%rep NTRIALS
    mov eax, PD_B
    jmp p_end_ %+ j
cont_ %+ j:
    xor eax, eax
    mov cr3, eax               ; back to A for the next trial
%assign j j+1
%endrep

    mov al, 0x01
    mov dx, STATUS_PORT
    out dx, al
    hlt

fail:
    mov dx, DATA_PORT
    out dx, eax
    mov al, 0xFF
    mov dx, STATUS_PORT
    out dx, al
    hlt

pf_handler:
    mov eax, cr2
    jmp fail

align 8
gdt:
    dq 0
    dq 0x00cf9b010000ffff     ; flat 32-bit code, base 0x10000
    dq 0x00cf93010000ffff     ; flat 32-bit data, base 0x10000
gdt_end:

gdt_desc:
    dw gdt_end - gdt - 1
    dd CSBASE + gdt

align 8
idt:
    times 14 dq 0
    dw pf_handler
    dw 0x0008
    db 0
    db 0x8e                    ; present DPL0 386 interrupt gate
    dw 0
idt_end:

idt_desc:
    dw idt_end - idt - 1
    dd CSBASE + idt

; Pad so "mov cr3,eax" occupies the last 3 bytes of each P_j and execution
; falls through into N_j.
%assign j 0
%rep NTRIALS
    times (P(j) + 0x1000 - CSBASE) - ($ - $$) - 3 db 0x90
p_end_ %+ j:
    mov cr3, eax
%assign j j+1
%endrep

; T_j stubs: only reachable through B's mapping of N_j.
%assign j 0
%rep NTRIALS
    times (T(j) - CSBASE) - ($ - $$) db 0
t_stub_ %+ j:
    mov al, j + 2
    mov dx, DATA_PORT
    out dx, al
    mov edx, cont_ %+ j
    jmp edx
%assign j j+1
%endrep

; tri_desc_cr2 - triage variant of desc_ro_gdt_pf: data = CR2 of the A-bit #PF, trap EAX[31:8] = error code
; desc_ro_gdt_pf - a segment load that must set a clear A bit in a read-only
; GDT faults cleanly
;
; The GDT sits in a read-only page and CR0.WP=1.  MOV DS from a descriptor
; with A=0 needs the locked A-bit write, which takes #PF: CR2 names the
; descriptor's high dword, the error code is a supervisor write to a present
; page, and DS - selector and descriptor cache - is still the old one.
; (derived from desc_ro_gdt)
BITS 32
ORG 0
GDT_RW  equ 0x20800          ; RW alias of the GDT page (linear 0x9800)
GDT     equ 0x9800
IDT     equ 0xB000
MARK    equ 0xA100
start:
    mov esp, 0x8000
    mov dword [GDT_RW+0], 0
    mov dword [GDT_RW+4], 0
    mov dword [GDT_RW+8], 0x0000ffff     ; 0x08: code, base 0x10000, A=1
    mov dword [GDT_RW+12], 0x00cf9b01
    mov dword [GDT_RW+16], 0x0000ffff    ; 0x10: flat data, A=1
    mov dword [GDT_RW+20], 0x00cf9300
    mov dword [GDT_RW+24], 0x1000ffff    ; 0x18: data, base 0x1000, A=0
    mov dword [GDT_RW+28], 0x00cf9200
    mov word [0xA000], 31
    mov dword [0xA002], GDT
    lgdt [0xA000]
    mov eax, pf_handler                  ; IDT[14] -> pf_handler
    mov word [IDT+14*8+0], ax
    mov word [IDT+14*8+2], 0x08
    mov word [IDT+14*8+4], 0x8e00
    shr eax, 16
    mov word [IDT+14*8+6], ax
    mov word [0xA010], 0x7ff
    mov dword [0xA012], IDT
    lidt [0xA010]
    mov ax, 0x10
    mov ds, ax
    mov dword [MARK], 0x5a5aa5a5
    mov ax, 0x18
fault_site:
    mov ds, ax                           ; A=0 in a read-only GDT: #PF
    mov eax, 0x11                        ; the load completed
    jmp fail
pf_handler:
    mov eax, 0x21
    cmp dword [ss:esp], 3                ; supervisor write, present
    jne fail
    mov eax, 0x22
    cmp dword [ss:esp+4], fault_site
    jne fail
    mov eax, cr2                         ; TRIAGE: report CR2, error code in trap EAX[31:8]
    out 0xe4, eax
    mov eax, [ss:esp]
    shl eax, 8
    mov al, 0xff
    out 0xe0, al
    hlt
    mov ebx, cr2
    cmp ebx, GDT+0x1c
    jne fail
    mov eax, 0x24
    mov bx, ds
    cmp bx, 0x10
    jne fail
    mov eax, 0x25                        ; DS still has base 0
    cmp dword [MARK], 0x5a5aa5a5
    jne fail
    mov eax, 0x26                        ; the descriptor is unchanged
    cmp dword [es:GDT+0x1c], 0x00cf9200
    jne fail
    mov al, 1
    out 0xe0, al
    hlt
fail:
    out 0xe4, eax
    mov al, 0xff
    out 0xe0, al
    hlt

; pc98_store_post - under the PC-98 memory-map template, stores to plain RAM
; post through the direct store port (+expect_store_post / _unpaged: the
; testbench counts data_access st_take), while stores to every device window
; and to window 0 while it is moved take the classifying demand path
; (cache_unit asserts no direct-port store is ever outside cacheable RAM).
; Each store is read back at once and again after the others, so a store that
; is lost, merged or reordered against a later read fails the program.
; Phase A runs unpaged, phase B paged (identity map), phase C again unpaged
; with A20 masked (a page whose number the mask changes must not post).
; pc98_store_post_win0 runs it with window 0 moved (+win0_unmapped): its
; range is then a device-class window and must not post either.
BITS 32
ORG 0
start:
    mov esp, 0x7F00
    call body                     ; paging off
    ; paging on: CR3 = 0 (the runner's page tables), PG = 1
    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax
    jmp short .pg
.pg:
    call body
    ; the paged verdict is the FRAME's: linear 0x200000 maps the GVRAM E-plane
    ; at 0xE0000 (must not post; outside the TLB's own VGA bit, A0000-BFFFF),
    ; linear 0x201000 maps RAM at 0x38000 (posts)
    ; (a load walks the page into the TLB and the sidecar; the first store sets
    ; the PTE's D bit through the demand path; the later stores may post)
    mov eax, [0x200020]
    mov dword [0x200020], 0x5A5A1234
    mov dword [0x200024], 0x5A5A1234
    mov dword [0x200028], 0x5A5A1234
    cmp dword [0xE0024], 0x5A5A1234
    jne fail
    mov eax, [0x201040]
    mov dword [0x201040], 0x0F0F1234
    mov dword [0x201044], 0x0F0F1234
    mov dword [0x201048], 0x0F0F1234
    cmp dword [0x38048], 0x0F0F1234
    jne fail
    mov eax, cr0
    and eax, 0x7FFFFFFF
    mov cr0, eax
    jmp short .nopg
.nopg:
    ; A20 masked (tb port 0xF0): a store to 0x108000 lands on RAM at 0x8000,
    ; one to 0x1A8000 on GVRAM at 0xA8000 - its page is RAM by its own number,
    ; so the verdict must see the mask (it must not post).
    out 0xF0, al
    mov dword [0x8000], 0
    mov dword [0x108000], 0x13579BDF
    cmp dword [0x8000], 0x13579BDF
    jne fail
    mov dword [0x1A8010], 0x2468ACE0
    cmp dword [0xA8010], 0x2468ACE0
    jne fail
    out 0xF4, al                  ; A20 on again
    mov al, 1
    out 0xe0, al
    hlt

body:
    mov ebx, 0x11223344
    ; plain RAM below window 0, dword / word / byte
    mov dword [0x30000], ebx
    mov word [0x30006], bx
    mov byte [0x3000B], bl
    push ebx
    pop ecx
    cmp ecx, ebx
    jne fail
    cmp dword [0x30000], 0x11223344
    jne fail
    cmp word [0x30006], 0x3344
    jne fail
    cmp byte [0x3000B], 0x44
    jne fail
    ; window 0's range while it is RAM
    mov dword [0x9F000], ebx
    cmp dword [0x9F000], ebx
    jne fail
    ; text VRAM, GVRAM, E-plane, BIOS shadow: device windows
    mov dword [0xA0000], 0xA0A0A0A0
    cmp dword [0xA0000], 0xA0A0A0A0
    jne fail
    mov byte [0xA8001], 0x5A
    mov byte [0xA8002], 0xA5
    cmp word [0xA8001], 0xA55A
    jne fail
    mov dword [0xE0000], ebx
    mov dword [0xE0004], ebx
    cmp dword [0xE0004], ebx
    jne fail
    mov dword [0xD0000], ebx
    cmp dword [0xD0000], ebx
    jne fail
    ; back-to-back byte stores to one VRAM dword then a read: the four bytes
    ; must all arrive (a merged or lost store reads back wrong)
    mov byte [0xB0000], 0x01
    mov byte [0xB0001], 0x02
    mov byte [0xB0002], 0x03
    mov byte [0xB0003], 0x04
    cmp dword [0xB0000], 0x04030201
    jne fail
    ret
fail:
    mov al, 0xff
    out 0xe0, al
    hlt

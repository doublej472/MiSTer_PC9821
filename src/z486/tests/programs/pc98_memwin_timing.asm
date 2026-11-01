; pc98_memwin_timing - CPU-side cycle counts of stores and loads to plain RAM and
; to the PC-98 device windows, under the PC-98 memory-map template.  Each phase
; reads the testbench cycle counter (port 0xFC) before and after and reports
; the difference on port 0xE4 (+trace_io prints it); phase 0 is the empty
; measurement, the overhead to subtract (T0/T1 clobber EAX and EBP).  The program also checks every value
; it stored reads back, so a store that did not reach its window fails it.
; Run with paging on (pc98_memwin_timing.json) and off (..._nopg.json).
BITS 32
ORG 0

%macro T0 0
    in eax, 0xFC
    mov ebp, eax
%endmacro
%macro T1 0
    in eax, 0xFC
    sub eax, ebp
    out 0xE4, eax
%endmacro

start:
    mov esp, 0x7F00
    cld
    ; P0: empty
    T0
    T1
    ; P1: push eax x64
    T0
%rep 64
    push eax
%endrep
    T1
    ; P2: pop eax x64
    T0
%rep 64
    pop eax
%endrep
    T1
    ; P3: mov [edi+k], eax x64 to RAM
    mov edi, 0x30000
    mov ebx, 0x12345678
    T0
%assign k 0
%rep 64
    mov [edi+k], ebx
%assign k k+4
%endrep
    T1
    ; P4: mov eax,[esi+k] x64 from RAM (the lines P3 did not fill: cold)
    mov esi, 0x30000
    T0
%assign k 0
%rep 64
    mov ecx, [esi+k]
%assign k k+4
%endrep
    T1
    cmp ecx, 0x12345678
    jne fail
    ; P5: the same loads warm
    T0
%assign k 0
%rep 64
    mov ecx, [esi+k]
%assign k k+4
%endrep
    T1
    ; P6: rep movsb 64 B RAM -> RAM (warm source)
    mov esi, 0x30000
    mov edi, 0x31000
    mov ecx, 64
    T0
    rep movsb
    T1
    ; P7: rep movsd 256 B RAM -> RAM
    mov esi, 0x30000
    mov edi, 0x31000
    mov ecx, 64
    T0
    rep movsd
    T1
    cmp dword [0x310FC], 0x12345678
    jne fail
    ; P8: text VRAM word stores x32
    mov dx, 0x4142
    T0
%assign k 0
%rep 32
    mov [0xA0000+k], dx
%assign k k+2
%endrep
    T1
    ; P9: text VRAM word loads x32
    T0
%assign k 0
%rep 32
    mov cx, [0xA0000+k]
%assign k k+2
%endrep
    T1
    cmp cx, 0x4142
    jne fail
    ; P10: GVRAM (A8000) dword stores x32
    mov ebx, 0x55AA33CC
    T0
%assign k 0
%rep 32
    mov [0xA8000+k], ebx
%assign k k+4
%endrep
    T1
    ; P11: GVRAM dword loads x32
    T0
%assign k 0
%rep 32
    mov ecx, [0xA8000+k]
%assign k k+4
%endrep
    T1
    cmp ecx, 0x55AA33CC
    jne fail
    ; P12: GVRAM E-plane (E0000) dword stores x32
    T0
%assign k 0
%rep 32
    mov [0xE0000+k], ebx
%assign k k+4
%endrep
    T1
    ; P13: GVRAM byte stores x32 (a GRCG tile-write loop's shape)
    mov dl, 0xFF
    T0
%assign k 0
%rep 32
    mov [0xB0000+k], dl
%assign k k+1
%endrep
    T1
    ; P14: rep movsd 256 B RAM -> GVRAM
    mov esi, 0x30000
    mov edi, 0xA9000
    mov ecx, 64
    T0
    rep movsd
    T1
    ; P15: rep movsd 256 B GVRAM -> RAM
    mov esi, 0xA9000
    mov edi, 0x32000
    mov ecx, 64
    T0
    rep movsd
    T1
    cmp dword [0x320FC], 0x12345678
    jne fail
    ; P16: stores to RAM in window 0's range (0x80000-0x9FFFF) x64
    mov edi, 0x90000
    T0
%assign k 0
%rep 64
    mov [edi+k], ebx
%assign k k+4
%endrep
    T1
    cmp dword [0x900FC], 0x55AA33CC
    jne fail
    ; P17: call/ret pairs x16 (each call pushes its return address)
    T0
%rep 16
    call leaf
%endrep
    T1
    ; P18: a store then an immediate load of the same VRAM dword, x16
    T0
%assign k 0
%rep 16
    mov [0xA8100+k], ebx
    mov ecx, [0xA8100+k]
%assign k k+4
%endrep
    T1
    cmp ecx, 0x55AA33CC
    jne fail
    ; P19: interleaved RAM store and VRAM store x32
    mov edi, 0x33000
    T0
%assign k 0
%rep 32
    mov [edi+k], ebx
    mov [0xA8200+k], ebx
%assign k k+4
%endrep
    T1
    cmp dword [0xA827C], 0x55AA33CC
    jne fail
    cmp dword [0x3307C], 0x55AA33CC
    jne fail
    ; P20: sparse RAM stores: one store and three register ops, x32
    mov edi, 0x34000
    T0
%assign k 0
%rep 32
    mov [edi+k], ebx
    add ecx, edx
    add esi, edx
    add ecx, esi
%assign k k+4
%endrep
    T1
    ; P21: sparse pushes: one push and three register ops, x32
    T0
%rep 32
    push ebx
    add ecx, edx
    add esi, edx
    add ecx, esi
%endrep
    T1
    add esp, 128
    ; P22: sparse GVRAM stores: one store and three register ops, x32
    T0
%assign k 0
%rep 32
    mov [0xA8400+k], ebx
    add ecx, edx
    add esi, edx
    add ecx, esi
%assign k k+4
%endrep
    T1
    cmp dword [0x3407C], 0x55AA33CC
    jne fail
    cmp dword [0xA847C], 0x55AA33CC
    jne fail
    mov al, 1
    out 0xe0, al
    hlt
leaf:
    ret
fail:
    mov al, 0xff
    out 0xe0, al
    hlt

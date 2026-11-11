; dr_regs.asm - 486 debug-register file (DR0-DR7)
;
; DR0-DR3 hold four linear breakpoint addresses.  The original 386 microcode
; reaches them through an internal-register-file index (0x70) that this core
; aliased onto general register 0, so MOV DRn,ECX overwrote EAX and DRn read
; back as an unrelated descriptor base.  DR4/DR5 are reserved encodings that
; alias DR6/DR7 on the 486.  DR6 bits 31-16 and 11-4 read as one and bit 12
; keeps what was written: Intel SDM vol. 3, Architecture Compatibility,
; "Differences in Debug Register DR6": "it is possible to write a 1 in this
; bit on the Intel486 processor"; Bochs
; cpu/crregs.cc MOV_DdRd, BX_CPU_LEVEL <= 4, "On 386/486 bit12 is settable";
; a real Am486DX4 reads FFFFFFFFh back after writing FFFFFFFFh
; (CPUSUITE-XE10-triage: tri_dr6dr7 data=FFFFFFFFh).  DR7 bit 10 reads as one
; and bits 15-14 and 12-11 as zero.
;
; Results: port 0xE0 status (0x01 pass / 0xFF fail), port 0xE4 fail code.
BITS 32
ORG 0
%macro EXPECT 3
    cmp %1, %2
    jne fail_%3
%endmacro

start:
    mov esp, 0x0F00
    mov eax, 0xA5A5A5A5
    mov ecx, 0x11111111
    mov edx, 0x22222222
    mov ebx, 0x33333333
    mov esi, 0x44444444
    mov edi, 0x55555555
    mov ebp, 0x66666666
    mov dr0, ecx
    mov dr1, edx
    mov dr2, ebx
    mov dr3, esi
    EXPECT eax, 0xA5A5A5A5, 1          ; writes must not touch EAX
    EXPECT ecx, 0x11111111, 2
    EXPECT edx, 0x22222222, 2
    EXPECT ebx, 0x33333333, 2
    EXPECT esi, 0x44444444, 2
    EXPECT edi, 0x55555555, 2
    EXPECT ebp, 0x66666666, 2
    mov edi, dr0
    EXPECT eax, 0xA5A5A5A5, 3          ; reads must not touch EAX either
    EXPECT edi, 0x11111111, 4
    mov edi, dr1
    EXPECT edi, 0x22222222, 5
    mov edi, dr2
    EXPECT edi, 0x33333333, 6
    mov edi, dr3
    EXPECT edi, 0x44444444, 7
    mov eax, dr3
    EXPECT eax, 0x44444444, 8
    EXPECT ecx, 0x11111111, 8

    ; DR6 fixed bits.
    xor eax, eax
    mov dr6, eax
    mov ebx, dr6
    EXPECT ebx, 0xFFFF0FF0, 9
    mov eax, 0xFFFFFFFF
    mov dr6, eax
    mov ebx, dr6
    EXPECT ebx, 0xFFFFFFFF, 10         ; bit 12 written as one reads as one
    mov eax, 0x0000400F                ; BS and B3-B0; bit 12 written as zero
    mov dr6, eax
    mov ebx, dr6
    EXPECT ebx, 0xFFFF4FFF, 11

    ; DR7 fixed bits; GD (bit 13) stays clear here.
    xor eax, eax
    mov dr7, eax
    mov ebx, dr7
    EXPECT ebx, 0x00000400, 12
    mov eax, 0xFFFFFF00                ; RW/LEN, LE/GE, GD; no L/G enables
    and eax, ~0x2000                   ; GD would fault the next access
    mov dr7, eax
    mov ebx, dr7
    EXPECT ebx, 0xFFFF0700, 13

    ; DR4/DR5 alias DR6/DR7.
    xor eax, eax
    mov dr6, eax
    mov eax, 0x00000001
    db 0x0f, 0x23, 0xe0                ; mov dr4, eax
    mov ebx, dr6
    EXPECT ebx, 0xFFFF0FF1, 14
    db 0x0f, 0x21, 0xe2                ; mov edx, dr4
    EXPECT edx, 0xFFFF0FF1, 15
    mov eax, 0x00110000                ; RW0/LEN0 fields only
    db 0x0f, 0x23, 0xe8                ; mov dr5, eax
    mov ebx, dr7
    EXPECT ebx, 0x00110400, 16
    db 0x0f, 0x21, 0xea                ; mov edx, dr5
    EXPECT edx, 0x00110400, 17
    xor eax, eax
    mov dr7, eax

    mov al, 0x01
    out 0xE0, al
    hlt

%assign c 1
%rep 17
fail_ %+ c:
    mov eax, c
    jmp fail
%assign c c+1
%endrep
fail:
    out 0xE4, eax
    mov al, 0xFF
    out 0xE0, al
    hlt

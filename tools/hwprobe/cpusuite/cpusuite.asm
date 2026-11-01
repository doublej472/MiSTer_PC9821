; cpusuite.asm - CPUSUITE.COM: run z486's own self-checking CPU test programs on a PC-98, from DOS.
;
; WHAT IT RUNS. The pack CPUSUITE.BIN that tools/hwprobe/cpusuite/gen_cpusuite.py builds from
; src/z486/tests/programs/: each program re-assembled with prelude.inc, its memory image (page
; tables + code, exactly the bench's layout) and the state tb_protected_mode.sv starts it in.
;
; HOW ONE PROGRAM RUNS. The program owns physical 0-0x7FFFF (the bench's 512 KiB), so all of DOS
; that lives below 0x9F000 is moved out of the way first and put back afterwards:
;   1. the COM masks both 8259s, saves port C (0x35), and moves the engine page 0x9F000-0x9FFFF to
;      the save block (XMS), copies the ENGINE (section .eng below) there and jumps to it;
;   2. the engine (protected mode, flat) saves 0-0x9EFFF to the save block, zeroes 0-0x7FFFF,
;      copies the program's image in, stores the CPU-reset return SS:SP at 0000:0404, clears
;      SHUT0 (port 0x37 BSR 0x0E), and enters the program in the bench's start state;
;   3. the program's verdict write is THE TRAP (prelude.inc): ~AL into the slave 8259's mask
;      (port 0x0A), then `out 0xF0` - the PC-98 CPU-only reset;
;   4. THE RETURN: with SHUT0 clear the firmware's reset entry (BIOS-top bank, F000:FFF0 ->
;      FD80:0000) does `mov ss,[0x406] / mov sp,[0x404]` and RETFs (0x43F/CR0 cache handling in
;      between), which lands in the engine; it reads the mask, restores 0-0x9EFFF from the save
;      block and returns to the COM, which restores the engine page, the masks, port C, and
;      writes the verdict. A program that triple-faults returns the same way, with the mask
;      still 0xFF: that is the verdict of the two programs the bench expects to triple-fault.
;   A program that hangs (a HLT with IF=0, a loop) hangs the machine: the line naming it is
;   already in the result file (committed before the program starts) with no verdict.
;
; USAGE    CPUSUITE [/P:n] [name]
;   /P:n   run the whole pack n times (a stress loop; default 1); /Pn is the same
;   name   run only the program of that name
; Writes CPUSUITE.TXT in the current directory: "<name> PASS|FAIL <why>" per program and a final
; "CPUSUITE END PASSES=n RUN=r PASS=p FAIL=f". Needs an XMS driver (HIMEM.SYS) and NO EMM386
; (virtual 8086 mode cannot run a program that enters protected mode itself).
;
; PACK FORMAT (little-endian; gen_cpusuite.py record()):
;   0   "CPUSUIT1"   8   u32 count   12  u32 offset of the first record (16)
;   records, 128 bytes each:
;     0  name (NUL-padded, 40)   40 u32 data offset  44 u32 data length  48 u8 mode (0 real, 1 prot)
;     49 u8 flags (bit 0: passes by triple-faulting)  50 u16 null-selector mask (bit = sreg number)
;     52 u32 CR0  56 u32 CR3  60 u32 EIP  64 u16 selectors ES,CS,SS,DS,FS,GS  76 6 descriptors
;   data: {u32 physical address, u32 length, bytes, pad to 4}..., {0, 0}
;
; Build: make -C tools/hwprobe cpusuite/cpusuite.com (nasm; the z486 suite's own assembler).

        cpu 486
        org 0x100

ENG             equ 0x9F000             ; the engine page (gen_cpusuite.py ENG_PHYS)
ENGSEG          equ ENG >> 4
SAVE_BYTES      equ 0xA0000             ; 0-0x9FFFF
SEL_C32         equ 0x08                ; the engine's GDT
SEL_D32         equ 0x10
SEL_C16         equ 0x18
SEL_D16         equ 0x20
REC_SIZE        equ 128
; STAGE MARKS: each step of one program's run writes a letter into text VRAM, row 0, columns
; 72-78 (cleared by the COM before each program), so a screenshot or the userdisk tier's TRAM dump
; of a machine that did not come back shows how far it got:
;   E engine entered   S DOS saved   I image loaded   J jumping into the program
;   L landed after the CPU reset   R DOS restored   B back in the COM
TVRAM           equ 0xA0000
STG_COL         equ 72 * 2
%macro STAGE16 2        ; column, letter (real mode; uses the stack)
        push    es
        push    word TVRAM >> 4
        pop     es
        mov     word [es:STG_COL + 2 * %1], %2
        mov     byte [es:0x2000 + STG_COL + 2 * %1], 0xE1
        pop     es
%endmacro
%macro STAGE32 2        ; column, letter (flat DS)
        mov     word [TVRAM + STG_COL + 2 * %1], %2
        mov     byte [TVRAM + 0x2000 + STG_COL + 2 * %1], 0xE1
%endmacro
R_MODE          equ 48
R_FLAGS         equ 49
R_NULL          equ 50
R_CR0           equ 52
R_CR3           equ 56
R_EIP           equ 60
R_SEL           equ 64
R_DESC          equ 76

section .text

start:
        cld
        mov     dx, s_banner
        call    puts
        ; the COM's 64 KiB must lie below the engine page
        mov     ax, cs
        cmp     ax, ENGSEG - 0x1000
        jb      .low_ok
        mov     dx, s_toohigh
        jmp     die
.low_ok:
        call    parse_args
        ; ---- XMS
        mov     ax, 0x4300
        int     0x2F
        cmp     al, 0x80
        je      .xms_ok
        mov     dx, s_noxms
        jmp     die
.xms_ok:
        push    es
        mov     ax, 0x4310
        int     0x2F
        mov     [xms_entry], bx
        mov     [xms_entry+2], es
        pop     es
        ; ---- V86 mode (EMM386) cannot run the programs
        smsw    ax
        test    al, 1
        jz      .real_ok
        mov     dx, s_v86
        jmp     die
.real_ok:
        ; ---- the pack: open, size, read into XMS
        mov     ax, 0x3D00
        mov     dx, s_packname
        int     0x21
        jnc     .open_ok
        mov     dx, s_nopack
        jmp     die
.open_ok:
        mov     [fh_pack], ax
        mov     bx, ax
        mov     ax, 0x4202              ; size = seek to end
        xor     cx, cx
        xor     dx, dx
        int     0x21
        mov     [pack_size], ax
        mov     [pack_size+2], dx
        mov     ax, 0x4200
        mov     bx, [fh_pack]
        xor     cx, cx
        xor     dx, dx
        int     0x21
        ; allocate: the pack (KiB, rounded up) and the 640 KiB save block
        mov     eax, [pack_size]
        add     eax, 1023
        shr     eax, 10
        mov     dx, ax
        call    xms_alloc
        mov     [h_pack], dx
        mov     [lin_pack], eax
        mov     dx, SAVE_BYTES >> 10
        call    xms_alloc
        mov     [h_save], dx
        mov     [lin_save], eax
        ; read the file in 32 KiB pieces, each moved into the pack block
        mov     dword [rd_off], 0       ; offset in the pack
.rd:
        mov     ah, 0x3F
        mov     bx, [fh_pack]
        mov     cx, 0x8000
        mov     dx, iobuf
        int     0x21
        jc      .rd_err
        test    ax, ax
        jz      .rd_done
        movzx   ecx, ax
        inc     ecx
        and     cl, 0xFE                ; XMS moves an even length
        mov     [xm_len], ecx
        mov     word [xm_sh], 0
        mov     word [xm_so], iobuf
        mov     [xm_so+2], ds
        mov     ax, [h_pack]
        mov     [xm_dh], ax
        mov     eax, [rd_off]
        mov     [xm_do], eax
        call    xms_move
        movzx   eax, word [xm_len]
        add     [rd_off], eax
        jmp     .rd
.rd_err:
        mov     dx, s_readerr
        jmp     die
.rd_done:
        mov     ah, 0x3E
        mov     bx, [fh_pack]
        int     0x21
        ; header
        xor     eax, eax
        mov     ebx, rec
        mov     ecx, 16
        call    pack_get
        cmp     dword [rec], 'CPUS'
        jne     .badpack
        cmp     dword [rec+4], 'UIT1'
        je      .pack_ok
.badpack:
        mov     dx, s_badpack
        jmp     die
.pack_ok:
        mov     eax, [rec+8]
        mov     [count], eax
        ; ---- A20: on now (DOS=HIGH) if 0000:0000 and FFFF:0010 differ
        push    ds
        push    es
        xor     si, si
        mov     ds, si
        mov     di, 0x10
        mov     ax, 0xFFFF
        mov     es, ax
        mov     cx, 32
        repe    cmpsw
        pop     es
        pop     ds
        setne   byte [a20_on]
        ; DOS's CR0, restored after every program
        mov     eax, cr0
        mov     [dos_cr0], eax
        ; ---- the result file
        mov     ah, 0x3C
        xor     cx, cx
        mov     dx, s_outname
        int     0x21
        jnc     .out_ok
        mov     dx, s_noout
        jmp     die
.out_ok:
        mov     [fh_out], ax
        mov     si, s_hdr
        call    out_str
        mov     eax, [count]
        call    out_dec
        mov     si, s_hdr2
        call    out_str
        movzx   eax, word [passes]
        call    out_dec
        mov     si, s_crlf
        call    out_str

; ================================================================ the loop
        mov     word [pass_no], 0
.pass:
        mov     dword [idx], 0
.next:
        mov     eax, [idx]
        cmp     eax, [count]
        jae     .pass_done
        shl     eax, 7                  ; * REC_SIZE
        add     eax, 16
        mov     ebx, rec
        mov     ecx, REC_SIZE
        call    pack_get
        cmp     byte [want], 0
        je      .take
        mov     si, rec
        mov     di, want
.cmpname:
        lodsb
        mov     ah, [di]
        inc     di
        cmp     al, ah
        jne     .skip
        test    al, al
        jnz     .cmpname
.take:
        ; the name, then commit: if the program hangs the machine, the file ends on its name
        mov     si, rec
        call    out_str
        mov     si, s_sp
        call    out_str
        mov     ah, 0x68
        mov     bx, [fh_out]
        int     0x21
        call    run_one                 ; -> AL = the slave 8259 mask after the program
        call    verdict
        inc     dword [ran]
.skip:
        inc     dword [idx]
        jmp     .next
.pass_done:
        inc     word [pass_no]
        mov     ax, [pass_no]
        cmp     ax, [passes]
        jb      .pass

; ================================================================ the end
        mov     si, s_end
        call    out_str
        movzx   eax, word [pass_no]
        call    out_dec
        mov     si, s_end_run
        call    out_str
        mov     eax, [ran]
        call    out_dec
        mov     si, s_end_pass
        call    out_str
        mov     eax, [npass]
        call    out_dec
        mov     si, s_end_fail
        call    out_str
        mov     eax, [nfail]
        call    out_dec
        mov     si, s_crlf
        call    out_str
        mov     ah, 0x3E
        mov     bx, [fh_out]
        int     0x21
        call    xms_release
        mov     ax, 0x4C00
        cmp     dword [nfail], 0
        je      .x
        mov     al, 1
.x:     int     0x21

; ---------------------------------------------------------------- run one program
; In: rec = its record. Out: AL = the slave 8259's mask after it ran.
run_one:
        push    es
        push    word TVRAM >> 4
        pop     es
        mov     di, STG_COL
        mov     ax, ' '
        mov     cx, 7
        rep     stosw
        pop     es
        cli
        in      al, 0x02
        mov     [imr_m], al
        in      al, 0x0A
        mov     [imr_s], al
        mov     al, 0xFF
        out     0x02, al
        out     0x0A, al
        in      al, 0x35
        mov     [portc], al
        ; the engine page -> save block + 0x9F000
        mov     dword [xm_len], 0x1000
        mov     word [xm_sh], 0
        mov     dword [xm_so], ENGSEG << 16
        mov     ax, [h_save]
        mov     [xm_dh], ax
        mov     dword [xm_do], ENG
        call    xms_move
        cli
        ; the engine -> 9F00:0000
        push    es
        mov     ax, ENGSEG
        mov     es, ax
        mov     si, eng_image
        xor     di, di
        mov     cx, ENG_SIZE
        rep     movsb
        ; its parameters
        mov     si, rec
        mov     di, p_rec
        mov     cx, REC_SIZE
        rep     movsb
        mov     eax, [lin_pack]
        add     eax, [rec+40]
        mov     [es:p_data], eax
        mov     eax, [lin_save]
        mov     [es:p_save], eax
        mov     word [es:p_ret], .back
        mov     [es:p_ret+2], cs
        mov     [es:p_retss], ss
        mov     ax, sp
        add     ax, 2                   ; the SP of the far jump below, after `pop es`
        mov     [es:p_retsp], ax
        mov     eax, [dos_cr0]
        mov     [es:p_cr0], eax
        mov     al, [portc]
        mov     [es:p_portc], al
        mov     al, [a20_on]
        mov     [es:p_a20], al
        pop     es
        jmp     ENGSEG:0
.back:
        ; SS:SP are ours again; everything below 0x9F000 is as it was at the jump
        cli
        cld
        mov     bx, cs
        mov     ds, bx
        mov     es, bx
        mov     [last_imr], al
        mov     dword [xm_len], 0x1000
        mov     ax, [h_save]
        mov     [xm_sh], ax
        mov     dword [xm_so], ENG
        mov     word [xm_dh], 0
        mov     dword [xm_do], ENGSEG << 16
        call    xms_move
        cli
        STAGE16 6, 'B'
        mov     al, [imr_m]
        out     0x02, al
        mov     al, [imr_s]
        out     0x0A, al
        sti
        mov     al, [last_imr]
        ret

; ---------------------------------------------------------------- the verdict
; In: AL = mask. The trap latched ~verdict (prelude.inc); 0xFF = no trap ran (a reset without a
; verdict: a triple fault, or another reset).
verdict:
        mov     bl, al
        test    byte [rec+R_FLAGS], 1
        jz      .normal
        cmp     bl, 0xFF
        jne     .tf_trapped
        mov     si, s_pass_tf
        jmp     .pass
.tf_trapped:
        mov     si, s_fail_tf
        jmp     .fail_v
.normal:
        cmp     bl, 0xFE
        jne     .n1
        mov     si, s_pass
.pass:
        inc     dword [npass]
        call    out_str
        jmp     .eol
.n1:
        cmp     bl, 0xFF
        jne     .n2
        mov     si, s_fail_reset
        inc     dword [nfail]
        call    out_str
        jmp     .eol
.n2:
        mov     si, s_fail
.fail_v:
        inc     dword [nfail]
        call    out_str
        mov     al, [last_imr]
        not     al
        call    out_hex2
.eol:
        mov     si, s_crlf
        call    out_str
        ret

; ---------------------------------------------------------------- XMS
; DX = KiB -> DX = handle, EAX = its locked linear address
xms_alloc:
        mov     ah, 0x09
        call    far [xms_entry]
        test    ax, ax
        jz      .err
        push    dx
        mov     ah, 0x0C
        call    far [xms_entry]
        test    ax, ax
        pop     ax                      ; the handle
        jz      .err
        push    dx
        push    bx
        pop     ebx                     ; DX:BX
        mov     dx, ax
        mov     eax, ebx
        ret
.err:
        mov     dx, s_xmserr
        jmp     die

xms_move:
        mov     ah, 0x0B
        mov     si, xm_len
        call    far [xms_entry]
        test    ax, ax
        jnz     .ok
        mov     dx, s_xmserr
        jmp     die
.ok:    ret

xms_release:
        mov     dx, [h_pack]
        call    .one
        mov     dx, [h_save]
.one:
        test    dx, dx
        jz      .r
        push    dx
        mov     ah, 0x0D
        call    far [xms_entry]
        pop     dx
        mov     ah, 0x0A
        call    far [xms_entry]
.r:     ret

; EAX = pack offset, EBX = near destination, ECX = length (even) -> bytes copied from the pack
pack_get:
        mov     [xm_len], ecx
        mov     dx, [h_pack]
        mov     [xm_sh], dx
        mov     [xm_so], eax
        mov     word [xm_dh], 0
        mov     [xm_do], bx
        mov     [xm_do+2], ds
        jmp     xms_move

; ---------------------------------------------------------------- output
; out_str: SI = NUL-terminated string -> the result file and the screen
out_str:
        push    si
        xor     cx, cx
.len:   cmp     byte [si], 0
        je      .go
        inc     si
        inc     cx
        jmp     .len
.go:    pop     dx
        jcxz    .r
        push    cx
        push    dx
        mov     ah, 0x40
        mov     bx, [fh_out]
        int     0x21
        pop     dx
        pop     cx
        mov     ah, 0x40
        mov     bx, 1
        int     0x21
.r:     ret

; EAX -> decimal
out_dec:
        mov     di, numbuf + 11
        mov     byte [di], 0
        mov     ebx, 10
.d:     xor     edx, edx
        div     ebx
        add     dl, '0'
        dec     di
        mov     [di], dl
        test    eax, eax
        jnz     .d
        mov     si, di
        jmp     out_str

; AL -> two hex digits
out_hex2:
        mov     ah, al
        shr     al, 4
        call    .nib
        mov     [numbuf], al
        mov     al, ah
        and     al, 15
        call    .nib
        mov     [numbuf+1], al
        mov     byte [numbuf+2], 0
        mov     si, numbuf
        jmp     out_str
.nib:   add     al, '0'
        cmp     al, '9'
        jbe     .n
        add     al, 7
.n:     ret

; DX = '$'-terminated message, screen only
puts:
        mov     ah, 0x09
        int     0x21
        ret

die:
        call    puts
        call    xms_release
        mov     ax, 0x4C02
        int     0x21

; ---------------------------------------------------------------- arguments: [/P:n] [name]
parse_args:
        mov     word [passes], 1
        mov     si, 0x81
.sk:    lodsb
        cmp     al, ' '
        je      .sk
        cmp     al, 9
        je      .sk
        cmp     al, 13
        je      .done
        cmp     al, '/'
        jne     .name
        lodsb
        and     al, 0xDF
        cmp     al, 'P'
        jne     .bad
        lodsb                           ; /P:n or /Pn (a typed ':' is not safe on every keymap)
        cmp     al, ':'
        je      .pnum
        dec     si
.pnum:  xor     bx, bx
.num:   lodsb
        sub     al, '0'
        cmp     al, 9
        ja      .numend
        imul    bx, bx, 10
        movzx   ax, al
        add     bx, ax
        jmp     .num
.numend:
        dec     si
        test    bx, bx
        jz      .bad
        mov     [passes], bx
        jmp     .sk
.name:
        mov     di, want
        mov     cx, 39
.nc:    cmp     al, ' '
        jbe     .nend
        cmp     al, 'A'
        jb      .st
        cmp     al, 'Z'
        ja      .st
        or      al, 0x20                ; program names are lower case
.st:    stosb
        lodsb
        loop    .nc
.nend:  mov     byte [di], 0
        dec     si
        jmp     .sk
.bad:
        mov     dx, s_usage
        jmp     die
.done:  ret

; ---------------------------------------------------------------- data
s_banner        db "CPUSUITE: z486 CPU test programs on the PC-98", 13, 10, "$"
s_toohigh       db "CPUSUITE: loaded too high (must be below 0x8F000)", 13, 10, "$"
s_noxms         db "CPUSUITE: no XMS driver (HIMEM.SYS)", 13, 10, "$"
s_v86           db "CPUSUITE: the CPU is in virtual 8086 mode (EMM386?) - boot without it", 13, 10, "$"
s_nopack        db "CPUSUITE: cannot open CPUSUITE.BIN", 13, 10, "$"
s_readerr       db "CPUSUITE: read error", 13, 10, "$"
s_badpack       db "CPUSUITE: CPUSUITE.BIN is not a CPUSUITE pack", 13, 10, "$"
s_noout         db "CPUSUITE: cannot create CPUSUITE.TXT", 13, 10, "$"
s_xmserr        db "CPUSUITE: XMS call failed", 13, 10, "$"
s_usage         db "usage: CPUSUITE [/P:n] [name]", 13, 10, "$"
s_packname      db "CPUSUITE.BIN", 0
s_outname       db "CPUSUITE.TXT", 0
s_hdr           db "CPUSUITE BEGIN V1 PROGRAMS=", 0
s_hdr2          db " PASSES=", 0
s_sp            db " ", 0
s_crlf          db 13, 10, 0
s_pass          db "PASS", 0
s_pass_tf       db "PASS triple fault", 0
s_fail          db "FAIL verdict=", 0
s_fail_tf       db "FAIL no triple fault, verdict=", 0
s_fail_reset    db "FAIL reset without a verdict", 0
s_end           db "CPUSUITE END PASSES=", 0
s_end_run       db " RUN=", 0
s_end_pass      db " PASS=", 0
s_end_fail      db " FAIL=", 0

        align 4
xms_entry       dd 0
pack_size       dd 0
lin_pack        dd 0
lin_save        dd 0
count           dd 0
idx             dd 0
ran             dd 0
npass           dd 0
nfail           dd 0
dos_cr0         dd 0
rd_off          dd 0
; the XMS move structure (function 0Bh)
xm_len          dd 0
xm_sh           dw 0
xm_so           dd 0
xm_dh           dw 0
xm_do           dd 0
h_pack          dw 0
h_save          dw 0
fh_pack         dw 0
fh_out          dw 0
passes          dw 1
pass_no         dw 0
imr_m           db 0
imr_s           db 0
portc           db 0
a20_on          db 0
last_imr        db 0
numbuf          times 12 db 0
want            times 40 db 0
rec             times REC_SIZE db 0

        align 16                        ; = the .eng section's file alignment below
eng_image:      ; the engine's bytes follow (section .eng)

; ================================================================ THE ENGINE
; Runs at physical ENG (real-mode CS = ENGSEG); every label below is an offset into that page.
section .eng vstart=0 follows=.text align=16

        bits 16
eng_base:
        jmp     eng_entry
        ; THE RETURN's stack, at a FIXED offset (prelude.inc CPUS_LAND_SP): the firmware's
        ; CPU-reset return loads SS:SP from 0000:0404, PUSHes and POPs EAX below SP (FDF80),
        ; then RETFs: [SP] = IP, [SP+2] = CS. The trap re-stores this SS:SP itself when it runs
        ; in real mode, so a program that used 0000:0404 as scratch still comes back.
        times 0x10 - ($ - eng_base) db 0
land_stack:
        dw      landing, ENGSEG
        align 4
p_rec           times REC_SIZE db 0     ; the program's record
p_data          dd 0                    ; linear: its chunk list
p_save          dd 0                    ; linear: the save block
p_ret           dw 0, 0                 ; the COM's continuation
p_retss         dw 0
p_retsp         dw 0
p_cr0           dd 0                    ; DOS's CR0
p_portc         db 0                    ; DOS's port C
p_a20           db 0                    ; 1: leave A20 enabled
r_imr           db 0

        align 8
gdt_eng:
        dq      0
        dq      0x00CF9B000000FFFF      ; 0x08 code, flat 32-bit
        dq      0x00CF93000000FFFF      ; 0x10 data, flat 32-bit
        dw      0xFFFF, ENG & 0xFFFF    ; 0x18 code, 16-bit, base ENG, 64 KiB
        db      (ENG >> 16) & 0xFF, 0x9B, 0x00, ENG >> 24
        dq      0x000093000000FFFF      ; 0x20 data, 16-bit, base 0, 64 KiB: DOS's real-mode cache
gdt_eng_end:
gdtr_eng:
        dw      gdt_eng_end - gdt_eng - 1
        dd      ENG + gdt_eng
idtr_0:                                 ; the bench's GDTR and IDTR: base 0, limit 0x3FF
        dw      0x3FF
        dd      0

        align 8
; Staging tables: for a protected-mode start, table k (sreg k) holds the program's descriptor k
; at the program's selector index k, so `mov sreg, sel` loads exactly the bench's cache even when
; two registers share a selector with different caches. Table 6 is the real-mode start's.
stg:    times 7 * 64 db 0
stg_gdtr:
%assign k 0
%rep 7
        dw      63
        dd      ENG + stg + 64 * k
%assign k k + 1
%endrep
pm_jmp: dd      0                       ; the program's EIP
        dw      0                       ; and CS


        align 4
        times 256 db 0
eng_stack_top:

; ---------------------------------------------------------------- entry (real mode)
eng_entry:
        cli
        cld
        mov     ax, cs
        mov     ds, ax
        mov     ss, ax
        mov     sp, eng_stack_top
        STAGE16 0, 'E'
        out     0xF2, al                ; A20 on (PC-98: any write to 0xF2)
        o32 lgdt [gdtr_eng]
        mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        jmp     dword SEL_C32:(ENG + pm_entry)

        bits 32
pm_entry:
        mov     ax, SEL_D32
        mov     ds, ax
        mov     es, ax
        mov     fs, ax
        mov     gs, ax
        mov     ss, ax
        mov     esp, ENG + eng_stack_top
        ; 0-0x9EFFF -> the save block
        mov     edi, [ENG + p_save]
        xor     esi, esi
        mov     ecx, ENG / 4
        rep     movsd
        STAGE32 1, 'S'
        ; the bench's memory starts zeroed
        xor     eax, eax
        xor     edi, edi
        mov     ecx, 0x80000 / 4
        rep     stosd
        ; the program's image
        mov     esi, [ENG + p_data]
.chunk:
        lodsd
        mov     edi, eax
        lodsd
        mov     ecx, eax
        jecxz   .img_done
        rep     movsb
        add     esi, 3
        and     esi, ~3
        jmp     .chunk
.img_done:
        STAGE32 2, 'I'
        ; THE RETURN: SS:SP for the firmware's CPU-reset entry, and SHUT0 = 0 so it takes it
        mov     word [0x404], land_stack
        mov     word [0x406], ENGSEG
        mov     al, 0x0E
        out     0x37, al
        STAGE32 3, 'J'
        cmp     byte [ENG + p_rec + R_MODE], 0
        je      real_start
        ; the staging tables (protected-mode start)
        mov     ebx, 0
.stg:
        movzx   edi, word [ENG + p_rec + R_SEL + ebx * 2]
        and     edi, 0xFFF8
        jnz     .stg_idx
        mov     edi, 8                  ; a null selector: the detour loads it through 0x08
.stg_idx:
        mov     eax, ebx
        shl     eax, 6
        lea     edi, [ENG + stg + edi + eax]
        lea     esi, [ENG + p_rec + R_DESC + ebx * 8]
        movsd
        movsd
        inc     ebx
        cmp     ebx, 6
        jb      .stg

; ---------------------------------------------------------------- protected-mode start
pm_start:
        mov     eax, [ENG + p_rec + R_EIP]
        mov     [ENG + pm_jmp], eax
        mov     ax, [ENG + p_rec + R_SEL + 2]
        mov     [ENG + pm_jmp + 4], ax
        xor     eax, eax
        lldt    ax                      ; the bench's LDTR is 0
        ; a register whose selector is null but whose cache is valid (the bench writes caches
        ; directly) cannot be loaded in protected mode: load the cache through 0x08, drop to real
        ; mode, load selector 0 there (base 0, attributes kept), and come back. Its MOV below
        ; becomes NOPs.
        movzx   ebx, word [ENG + p_rec + R_NULL]
        test    ebx, ebx
        jz      pm_loads
        ; the NOP patches are written before the loads (DS may be one of them)
        bt      ebx, 0
        jnc     .p0
        mov     word [ENG + ld_es], 0x9090
.p0:    bt      ebx, 2
        jnc     .p2
        mov     word [ENG + ld_ss], 0x9090
.p2:    bt      ebx, 3
        jnc     .p3
        mov     word [ENG + ld_ds], 0x9090
.p3:    bt      ebx, 4
        jnc     .p4
        mov     word [ENG + ld_fs], 0x9090
.p4:    bt      ebx, 5
        jnc     .p5
        mov     word [ENG + ld_gs], 0x9090
.p5:
%macro DETOUR 2
        bt      ebx, %1
        jnc     %%n
        lgdt    [cs:ENG + stg_gdtr + 6 * %1]
        mov     ax, 8
        mov     %2, ax
%%n:
%endmacro
        DETOUR  0, es
        DETOUR  2, ss
        DETOUR  3, ds
        DETOUR  4, fs
        DETOUR  5, gs
        lgdt    [cs:ENG + gdtr_eng]
        jmp     SEL_C16:detour16
        bits 16
detour16:
        mov     eax, cr0
        and     al, 0xFE
        mov     cr0, eax
        jmp     ENGSEG:detour_rm
detour_rm:
        xor     ax, ax
        test    bl, 1 << 0
        jz      .d2
        mov     es, ax
.d2:    test    bl, 1 << 2
        jz      .d3
        mov     ss, ax
.d3:    test    bl, 1 << 3
        jz      .d4
        mov     ds, ax
.d4:    test    bl, 1 << 4
        jz      .d5
        mov     fs, ax
.d5:    test    bl, 1 << 5
        jz      .d6
        mov     gs, ax
.d6:    mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        jmp     dword SEL_C32:(ENG + pm_loads)
        bits 32
pm_loads:
        ; EFLAGS = 2 (the bench's); nothing below writes a flag
        push    dword 2
        popfd
        ; ES, FS, GS, DS, SS through their staging tables (SS last: no stack is used after it)
        lgdt    [cs:ENG + stg_gdtr + 6 * 0]
        mov     ax, [cs:ENG + p_rec + R_SEL + 0]
ld_es:  mov     es, eax
        lgdt    [cs:ENG + stg_gdtr + 6 * 4]
        mov     ax, [cs:ENG + p_rec + R_SEL + 8]
ld_fs:  mov     fs, eax
        lgdt    [cs:ENG + stg_gdtr + 6 * 5]
        mov     ax, [cs:ENG + p_rec + R_SEL + 10]
ld_gs:  mov     gs, eax
        lgdt    [cs:ENG + stg_gdtr + 6 * 3]
        mov     ax, [cs:ENG + p_rec + R_SEL + 6]
ld_ds:  mov     ds, eax
        lgdt    [cs:ENG + stg_gdtr + 6 * 2]
        mov     ax, [cs:ENG + p_rec + R_SEL + 4]
ld_ss:  mov     ss, eax
        ; CS's table stays loaded: the far jump reads it (GDTR is the bench's 0/0x3FF only in
        ; the bench; every program loads its own GDT before it needs one)
        lgdt    [cs:ENG + stg_gdtr + 6 * 1]
        lidt    [cs:ENG + idtr_0]
        mov     eax, [cs:ENG + p_rec + R_CR3]
        mov     cr3, eax
        mov     eax, 0
        mov     cr2, eax
        mov     eax, [cs:ENG + p_rec + R_CR0]
        mov     cr0, eax                ; paging may start here: this page has an identity PTE
        mov     eax, 0
        mov     ebx, 0
        mov     ecx, 0
        mov     edx, 0
        mov     esi, 0
        mov     edi, 0
        mov     ebp, 0
        mov     esp, 0xFF00
        jmp     far [cs:ENG + pm_jmp]

; ---------------------------------------------------------------- real-mode start
; Every register gets its cache attributes from a protected-mode load (descriptor = the bench's
; cache; CS's with base ENG so this code keeps running in it), then drops to real mode, where a
; selector load sets only the base (z486 segmentation_unit.sv SEG_CMD_SBRM: "Limit and
; granularity are NOT reset") and the far jump into the program sets CS's base and clears D.
real_start:
        mov     esi, ENG + p_rec + R_DESC
        mov     edi, ENG + stg + 6 * 64 + 8
        mov     ecx, 12
        rep     movsd
        mov     word [ENG + stg + 6 * 64 + 2 * 8 + 2], ENG & 0xFFFF
        mov     byte [ENG + stg + 6 * 64 + 2 * 8 + 4], (ENG >> 16) & 0xFF
        mov     byte [ENG + stg + 6 * 64 + 2 * 8 + 7], ENG >> 24
        mov     ax, [ENG + p_rec + R_EIP]
        mov     [ENG + rm_jmp + 1], ax
        mov     ax, [ENG + p_rec + R_SEL + 2]
        mov     [ENG + rm_jmp + 3], ax
        push    dword 2
        popfd                           ; EFLAGS = 2; nothing below writes a flag
        lgdt    [ENG + stg_gdtr + 6 * 6]
        mov     ax, 0x08
        mov     es, ax
        mov     ax, 0x18
        mov     ss, ax
        mov     ax, 0x28
        mov     fs, ax
        mov     ax, 0x30
        mov     gs, ax
        mov     ax, 0x20
        mov     ds, ax
        jmp     0x10:rm_stage16
        bits 16
rm_stage16:
        mov     eax, [cs:p_rec + R_CR3]
        mov     cr3, eax
        mov     eax, [cs:p_rec + R_CR0]
        mov     cr0, eax                ; real mode
        mov     ax, [cs:p_rec + R_SEL + 0]
        mov     es, ax
        mov     ax, [cs:p_rec + R_SEL + 4]
        mov     ss, ax
        mov     ax, [cs:p_rec + R_SEL + 6]
        mov     ds, ax
        mov     ax, [cs:p_rec + R_SEL + 8]
        mov     fs, ax
        mov     ax, [cs:p_rec + R_SEL + 10]
        mov     gs, ax
        o32 lidt [cs:idtr_0]
        o32 lgdt [cs:idtr_0]
        mov     esp, 0xFF00
        mov     eax, 0
        mov     ebx, 0
        mov     ecx, 0
        mov     edx, 0
        mov     esi, 0
        mov     edi, 0
        mov     ebp, 0
rm_jmp: jmp     0:0                     ; patched: the program's CS:IP

; ---------------------------------------------------------------- THE RETURN (real mode)
; The firmware's RETF lands here after the trap's `out 0xF0` (or any other CPU reset).
landing:
        cli
        in      al, 0x0A                ; the verdict, before anything touches the 8259
        mov     [cs:r_imr], al
        cld
        mov     ax, cs
        mov     ds, ax
        mov     ss, ax
        mov     sp, eng_stack_top
        STAGE16 4, 'L'
        out     0xF2, al                ; `out 0xF0` cleared A20
        o32 lgdt [gdtr_eng]
        mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        jmp     dword SEL_C32:(ENG + restore32)
        bits 32
restore32:
        mov     ax, SEL_D32
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     esp, ENG + eng_stack_top
        mov     esi, [ENG + p_save]
        xor     edi, edi
        mov     ecx, ENG / 4
        rep     movsd
        STAGE32 5, 'R'
        mov     ax, SEL_D16             ; DOS's real-mode caches
        mov     ds, ax
        mov     es, ax
        mov     fs, ax
        mov     gs, ax
        mov     ss, ax
        jmp     SEL_C16:back16
        bits 16
back16:
        mov     eax, [cs:p_cr0]
        mov     cr0, eax
        jmp     ENGSEG:back_rm
back_rm:
        mov     ax, cs
        mov     ds, ax
        mov     al, [p_portc]
        out     0x35, al                ; SHUT0 back
        xor     eax, eax
        mov     cr3, eax
        o32 lidt [idtr_0]               ; the real-mode IVT (0/0x3FF)
        cmp     byte [p_a20], 0
        jne     .a20
        mov     al, 0x03
        out     0xF6, al                ; mask A20 again
.a20:
        mov     ss, [p_retss]
        mov     sp, [p_retsp]
        mov     al, [r_imr]
        jmp     far [p_ret]

eng_end:
ENG_SIZE        equ eng_end - eng_base
%if ENG_SIZE > 0x1000
 %error the engine must fit its page
%endif

section .text
iobuf   equ     ($ - $$ + 0x100 + ENG_SIZE + 15) & ~15
